/************************************************
TCP ping-pong ядро С ИЗМЕРЕНИЕМ ЗАДЕРЖКИ (probe-вариант).

Отличие от hls_pingpong_krnl: ядро вписывает в первые 4 байта эха
число тактов, которое само потратило на обработку сообщения.

ЗАЧЕМ ОТДЕЛЬНОЕ ЯДРО. Основное hls_pingpong_krnl байт-прозрачно —
отражает ровно то, что получило, и именно поэтому годится как эталон
задержки (не интерпретирует данные, не добавляет логики в путь).
Probe-вариант это свойство нарушает, поэтому существует рядом, а не
вместо. В работу идёт основное ядро; probe — для одного эксперимента,
чтобы измерить вклад ядра вместо оценки на бумаге.

ЧТО ИМЕННО СЧИТАЕТСЯ (вариант «полный»):
    от такта, в котором пришло уведомление (NOTIFY),
    до такта, в котором отправлено последнее слово эха (TX).

То есть в счётчик входит ВСЁ, что делает ядро, включая ожидания:
  - реакция стека на read request (NOTIFY -> META -> RX),
  - приём wordCount слов,
  - рукопожатие tx_meta/tx_status (REQ -> STATUS),
  - отправка wordCount слов.

Расчётный минимум (при мгновенном стеке): 4 такта фиксированных
(NOTIFY, META, REQ, TX-переход) + 2*wordCount на приём и отправку.
Для 64 байт это ~6 тактов; всё, что сверху, — ожидание стека.

ФОРМАТ СЧЁТЧИКА В ПАКЕТЕ:
  - первые 4 байта payload заменяются на счётчик тактов;
  - порядок байт — network byte order (big-endian), клиенту нужен
    ntohl(). Проверено: запись по байтам через w(7,0)=MSB даёт на
    проводе 11 22 33 44 для значения 0x11223344.
  - если счётчик переполнил 32 бита (не должно случаться: 2^32 тактов
    при 195.9 МГц это ~22 секунды), пишется 0xFFFFFFFF как признак.

ТРЕБОВАНИЕ К РАЗМЕРУ: сообщение должно быть не меньше 4 байт, иначе
счётчик не влезает. Для осмысленных замеров используйте >= 8 байт.

ОГРАНИЧЕНИЕ. Счётчик меряет ОДНО сообщение за раз — то, которое
сейчас в обработке. Ядро обслуживает сообщения строго последовательно
(один буфер, одна активная сессия), поэтому неоднозначности нет.
Если стек разобьёт большое сообщение на несколько уведомлений, каждый
кусок получит свой счётчик — это отдельные проходы автомата.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Максимальный размер сообщения в 64-байтных словах (64 * 64 = 4096 байт).
// Должно быть степенью двойки: в TX используется маска как защита от
// выхода за границу BRAM.
#define PP_MAX_WORDS 64
static_assert((PP_MAX_WORDS & (PP_MAX_WORDS - 1)) == 0,
              "PP_MAX_WORDS должен быть степенью двойки (см. маску в TX)");

/*
 * Открывает listen-порт, повторяя запрос до подтверждения стека.
 *
 * ПРО enable. Ядро объявлено с ap_ctrl_none, то есть у него нет
 * ap_start: оно исполняет своё тело каждый такт. Открытым остаётся
 * вопрос, с какого момента — с загрузки битстрима или после того, как
 * XRT снимет reset при enqueueTask. Если с загрузки, то возникает
 * гонка: хост записывает listenPort через setArg на миллионы тактов
 * позже, а ядро к тому времени уже запросило порт по нулевому
 * регистру и защёлкнуло portRequested. Слушался бы порт 0, а клиент
 * не смог бы подключиться.
 *
 * НА ПЛАТЕ ЭТО НЕ ПРОВЕРЕНО — поведение зависит от shell и версии XRT,
 * из кода его не видно. Поэтому вопрос закрывается явным разрешением:
 * пока хост не выставил enable=1, ядро не трогает ни один порт. Так
 * правильно при любом ответе, и проверять ничего не нужно.
 *
 * Порядок записи на хосте: сначала listenPort, потом enable.
 */
void ppp_listen(int enable,
                int listenPort,
                hls::stream<pkt16>& m_axis_tcp_listen_port,
                hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
#pragma HLS RESET variable=portRequested
     static bool portOpened = false;
#pragma HLS RESET variable=portOpened

     // До разрешения хоста listenPort в регистре может быть ещё не
     // записан — не начинаем.
     if (!enable)
          return;

     if (!portRequested)
     {
          pkt16 listen_port_pkt;
          listen_port_pkt.data(15, 0) = listenPort;
          m_axis_tcp_listen_port.write(listen_port_pkt);
          portRequested = true;
     }
     else if (!portOpened && !s_axis_tcp_port_status.empty())
     {
          pkt8 status_pkt = s_axis_tcp_port_status.read();
          bool success = status_pkt.data(0, 0);
          if (success) portOpened = true;
          else         portRequested = false;
     }
}

/*
 * Echo-конвейер со счётчиком тактов.
 *
 * Отличия от pp_echo:
 *   - freeCounter тикает каждый такт (свободнобегущий);
 *   - в NOTIFY запоминается tStart;
 *   - в TX на ПЕРВОМ слове первые 4 байта подменяются счётчиком.
 *
 * Почему счётчик пишется на первом слове, а не на последнем: клиент
 * читает начало сообщения, и так значение попадает в фиксированное
 * место независимо от размера. Но значение на первом слове ещё не
 * включает отправку остальных слов — поэтому к нему добавляется
 * ПРЕДСКАЗАННОЕ время отправки (wordCount тактов), а не измеренное.
 * Для 64 байт (одно слово) предсказание точно: остаётся 0 слов.
 */
void ppp_echo(hls::stream<pkt128>& s_axis_tcp_notification,
              hls::stream<pkt32>& m_axis_tcp_read_pkg,
              hls::stream<pkt16>& s_axis_tcp_rx_meta,
              hls::stream<pkt512>& s_axis_tcp_rx_data,
              hls::stream<pkt32>& m_axis_tcp_tx_meta,
              hls::stream<pkt512>& m_axis_tcp_tx_data,
              hls::stream<pkt64>& s_axis_tcp_tx_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum ppStateType {NOTIFY, META, RX, REQ, STATUS, TX};
     static ppStateType ppState = NOTIFY;
#pragma HLS RESET variable=ppState

     static ap_uint<512> payload[PP_MAX_WORDS];
#pragma HLS BIND_STORAGE variable=payload type=RAM_2P impl=BRAM

     static ap_uint<16> sessionID = 0;
     static ap_uint<16> msgLength = 0;
     static ap_uint<16> txLength = 0;
     static ap_uint<16> wordCount = 0;
     static ap_uint<16> wordIdx = 0;
     static ap_uint<16> bytesRemaining = 0;

     // --- измерение ---
     // Свободнобегущий счётчик тактов. Тикает всегда, поэтому не
     // требует сброса между сообщениями: разность корректна и при
     // переполнении 32 бит (арифметика по модулю 2^32).
     static ap_uint<32> freeCounter = 0;
     static ap_uint<32> tStart = 0;
     static ap_uint<32> elapsed = 0;

     freeCounter++;

     switch (ppState)
     {
     case NOTIFY:
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notification_pkt = s_axis_tcp_notification.read();
               ap_uint<16> notifLength = notification_pkt.data(31, 16);

               if (notifLength != 0)
               {
                    // ЗДЕСЬ начинается отсчёт: ядро узнало о данных
                    tStart = freeCounter;

                    sessionID = notification_pkt.data(15, 0);

                    const ap_uint<16> maxBytes = PP_MAX_WORDS * 64;
                    msgLength = (notifLength > maxBytes) ? maxBytes : notifLength;

                    pkt32 readRequest_pkt;
                    readRequest_pkt.data(15, 0) = sessionID;
                    readRequest_pkt.data(31, 16) = msgLength;
                    m_axis_tcp_read_pkg.write(readRequest_pkt);

                    wordCount = 0;
                    ppState = META;
               }
          }
          break;

     case META:
          if (!s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               ppState = RX;
          }
          break;

     case RX:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();
               if (wordCount < PP_MAX_WORDS)
               {
                    payload[wordCount] = rx_word.data;
                    wordCount++;
               }
               if (rx_word.last)
               {
                    ppState = REQ;
               }
          }
          break;

     case REQ:
     {
          ap_uint<16> wordBytes = (ap_uint<16>)(wordCount * 64);
          txLength = (msgLength < wordBytes) ? msgLength : wordBytes;

          pkt32 tx_meta_pkt;
          tx_meta_pkt.data(15, 0) = sessionID;
          tx_meta_pkt.data(31, 16) = txLength;
          m_axis_tcp_tx_meta.write(tx_meta_pkt);
          ppState = STATUS;
          break;
     }

     case STATUS:
          if (!s_axis_tcp_tx_status.empty())
          {
               pkt64 status_pkt = s_axis_tcp_tx_status.read();
               ap_uint<2> error = status_pkt.data(63, 62);

               if (error == 0)
               {
                    wordIdx = 0;
                    bytesRemaining = txLength;
                    // Фиксируем прошедшее время и добавляем ещё
                    // wordCount тактов — столько уйдёт на отправку
                    // слов. Иначе счётчик, записанный в первое слово,
                    // не учитывал бы саму отправку.
                    elapsed = (freeCounter - tStart) + (ap_uint<32>)wordCount;
                    ppState = TX;
               }
               else if (error == 1)
               {
                    ppState = NOTIFY;
               }
               else
               {
                    ppState = REQ;
               }
          }
          break;

     case TX:
     {
          pkt512 tx_word;
          tx_word.data = payload[wordIdx & (PP_MAX_WORDS - 1)];

          // В ПЕРВОЕ слово вписываем счётчик тактов, big-endian.
          // Проверено на модели: запись старшего байта в w(7,0) даёт
          // на проводе 11 22 33 44 для 0x11223344, то есть network
          // byte order — клиент читает через ntohl().
          if (wordIdx == 0)
          {
               ap_uint<32> v = elapsed;
               // защита от переполнения: 0xFFFFFFFF как признак
               if (elapsed == (ap_uint<32>)0xFFFFFFFF) v = 0xFFFFFFFE;
               tx_word.data(7, 0)   = v(31, 24);
               tx_word.data(15, 8)  = v(23, 16);
               tx_word.data(23, 16) = v(15, 8);
               tx_word.data(31, 24) = v(7, 0);
          }

          ap_uint<7> validBytes = (bytesRemaining >= 64) ? (ap_uint<7>)64
                                                         : (ap_uint<7>)bytesRemaining;
          for (int b = 0; b < 64; b++)
          {
          #pragma HLS UNROLL
               tx_word.keep(b, b) = (b < validBytes) ? 1 : 0;
          }
          bytesRemaining = (bytesRemaining >= 64) ? (ap_uint<16>)(bytesRemaining - 64)
                                                  : (ap_uint<16>)0;

          wordIdx++;
          tx_word.last = (wordIdx == wordCount);
          m_axis_tcp_tx_data.write(tx_word);

          if (tx_word.last)
          {
               ppState = NOTIFY;
          }
          break;
     }
     }
}

extern "C" {
void hls_pingpong_probe_krnl(
               // UDP (не используется, но интерфейс обязателен)
               hls::stream<pkt512>& s_axis_udp_rx,
               hls::stream<pkt512>& m_axis_udp_tx,
               hls::stream<pkt256>& s_axis_udp_rx_meta,
               hls::stream<pkt256>& m_axis_udp_tx_meta,

               // TCP control
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status,
               hls::stream<pkt64>& m_axis_tcp_open_connection,
               hls::stream<pkt128>& s_axis_tcp_open_status,
               hls::stream<pkt16>& m_axis_tcp_close_connection,

               // TCP rx
               hls::stream<pkt128>& s_axis_tcp_notification,
               hls::stream<pkt32>& m_axis_tcp_read_pkg,
               hls::stream<pkt16>& s_axis_tcp_rx_meta,
               hls::stream<pkt512>& s_axis_tcp_rx_data,

               // TCP tx
               hls::stream<pkt32>& m_axis_tcp_tx_meta,
               hls::stream<pkt512>& m_axis_tcp_tx_data,
               hls::stream<pkt64>& s_axis_tcp_tx_status,

               // ---- Скалярные аргументы (задаются с хоста) ----
               // setArg() адресует аргументы ПОЗИЦИЕЙ в этой сигнатуре,
               // считая с нуля и включая все 16 потоков:
               //   listenPort -> 16,  enable -> 17.
               // Новые параметры добавлять только между ними, иначе
               // индексы на хосте молча разъедутся.
               int listenPort,

               // enable ВСЕГДА последний — разрешение начать работу,
               // см. пояснение у ppp_listen.
               int enable
                      ) {

#pragma HLS INTERFACE axis port = s_axis_udp_rx
#pragma HLS INTERFACE axis port = m_axis_udp_tx
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection
#pragma HLS INTERFACE axis port = s_axis_tcp_notification
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status
#pragma HLS INTERFACE s_axilite port = listenPort bundle = control
#pragma HLS INTERFACE s_axilite port = enable bundle = control
#pragma HLS INTERFACE ap_ctrl_none port = return

// DATAFLOW, а не PIPELINE — см. пояснение в hls_pingpong_krnl.cpp
#pragma HLS DATAFLOW disable_start_propagation

     // Неиспользуемые интерфейсы
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx, s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection, s_axis_tcp_open_status);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);

     ppp_listen(enable, listenPort,
                m_axis_tcp_listen_port, s_axis_tcp_port_status);

     ppp_echo(s_axis_tcp_notification, m_axis_tcp_read_pkg,
              s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
              m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
              s_axis_tcp_tx_status);
}
}
