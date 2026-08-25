/************************************************
TCP-эхо на половине a, приёмник на половине b.

ЧТО ЭТО И ЗАЧЕМ.

Первое ядро, которое ОТДАЁТ данные обратно в сеть. До него на этой плате
работали только приёмники: фазы 1-3 лестницы hls_recv_dual_krnl прошли
зелёными, но TX-путь стека в них стоял на tie_off_tcp_tx и не проверялся
ни разу.

Ядро собрано так, чтобы новый код был только там, где без него нельзя:

  обвязка, порты, pragma, половина b  -- дословно из hls_recv_dual_krnl
                                         (фаза 3, коммит 4e45d13, зелёная
                                         на плате 25.08)
  pp_echo                             -- дословно из hls_pingpong_krnl
                                         плюс два выходных скаляра
  pp_listen                           -- оттуда же, с двумя правками

Всё остальное -- копия того, что уже работало.

ПОЧЕМУ ЭХО ТРЕБУЕТ ИМЕННО ТАКОЙ ПОСЛЕДОВАТЕЛЬНОСТИ.

Прочитано в tx_app_stream_if.cpp: tasi_metaLoader на каждый tx_meta
отвечает одним словом в appTxDataRsp (наш s_axis_tcp_tx_status) и ТОЛЬКО
при NO_ERROR выдаёт tasi_meta2pkgPushCmd -- команду, по которой данные
вообще начнут читаться.

При TCP_NODELAY=1 (значение по умолчанию, наша сборка его не меняет)
toe_duplicate_stream кладёт каждое слово в ДВА потока по 1024 слова:
tasi_dataFifo и txApp2txEng_data_stream. Оба читаются автоматами, которые
ждут команду. Если tx_meta получил ошибку, команды нет НИ ДЛЯ ОДНОГО из
них, а залитые слова остаются в обоих FIFO навсегда. Следующий успешный
tx_meta выдаст команду -- и автомат отправит СТАРЫЕ слова. Это не потеря
пакета, а сдвиг всего потока на одно сообщение, без восстановления.

Отсюда порядок, отступать от которого нельзя:

    tx_meta -> ЖДАТЬ tx_status -> только при error==0 лить данные

Store-and-forward здесь не осторожность, а требование протокола: данные
надо где-то держать, пока ждём ответа. Поэтому payload[] в BRAM.

ЧТО ИЗМЕРЯЕМ ЭТИМ ЗАПУСКОМ.

Только одно: работает ли эхо. Врезки времени намеренно нет -- она
требует правки axis_net между network_krnl и CMAC, то есть риска задеть
то, что уже работает. Задержка меряется вторым заходом, когда эхо
подтверждено. RTT этого запуска снимается tcpdump'ом на хосте.

ТЕЛЕМЕТРИЯ: ТРИ СКАЛЯРА, НЕ БОЛЬШЕ.

Их отсутствие -- ровно то, что стоило недели на dual_echo: ядро молчало,
и по молчанию нельзя было понять, на каком шаге оно встало.

  portState   0 = не запрашивали, 1 = запрос отправлен, 2 = порт открыт
  ppState     сырое состояние FSM эха: на каком шаге стоит
  notifyCount сколько уведомлений о данных дошло до ядра

ppState -- главный из трёх. Он не проверяет гипотезу, а прямо показывает
шаг: STATUS = стек не ответил на tx_meta, RX = данные не пришли,
NOTIFY = уведомления нет. Каждое значение -- однозначный вывод.

Скаляры отдаются присваиванием в конце стадии. Что это работает при
ap_ctrl_hs, проверено на dual_echo: listenAttempts и portState читались
с платы, когда всё остальное молчало.

СХЕМА ЗАПУСКА: кабель в QSFP0, половина a слушает 7001 и отражает,
половина b -- как в фазе 3 (listenPorts + recvData), кабель в неё НЕ
включён. Половина b здесь только чтобы отличие от фазы 3 было
минимальным: если эхо не заработает, причина не в том, что мы заодно
убрали вторую половину.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Максимальный размер сообщения в 64-байтных словах (64 * 64 = 4096 байт).
// Совпадает с MSS стека по умолчанию (FNS_TCP_STACK_MSS=4096), поэтому
// один TCP-сегмент всегда влезает в буфер целиком.
//
// ДОЛЖНО БЫТЬ СТЕПЕНЬЮ ДВОЙКИ: в TX используется маска
// (wordIdx & (PP_MAX_WORDS-1)) как защита от выхода за границу BRAM.
#define PP_MAX_WORDS 64
static_assert((PP_MAX_WORDS & (PP_MAX_WORDS - 1)) == 0,
              "PP_MAX_WORDS must be a power of two (see mask in TX)");

/*
 * Открывает listen-порт, повторяя запрос до подтверждения стека.
 *
 * ОДНА ПРАВКА ОТНОСИТЕЛЬНО pp_listen ИЗ hls_pingpong_krnl: portState
 * наружу. Без него "соединение не устанавливается" не отличить от "порт не
 * открылся", а это первое, что надо знать с платы.
 *
 * ЗАПИСЬ БЛОКИРУЮЩАЯ, БЕЗ full() -- И ЭТО СОЗНАТЕЛЬНО.
 *
 * Сначала я поставил здесь проверку full(), считая её бесплатной
 * страховкой. csynth показал цену: II Violation 200-880, carried
 * dependence между full() и write() по одному порту, Final II = 2 вместо 1.
 *
 * Сравнение с логом csynth РАБОТАЮЩЕГО hls_recv_dual_krnl (25.08, фаза 3
 * зелёная на плате) показало, что это ЕДИНСТВЕННОЕ расхождение с эталоном:
 *
 *   Fmax               259.20 МГц   ==   259.20 МГц
 *   HLS 200-471        2 issue(s)   ==   2 issue(s)   (оба в апстримных
 *                                                     sendDataPtr/recvDataPtr,
 *                                                     которые не вызываются)
 *   HLS 200-656        есть         ==   есть         (на апстримном
 *                                                     port_status_handler тоже)
 *   ap_ctrl            s_axilite+hs ==   s_axilite+hs
 *   II Violation       НЕТ          !=   1 (pp_listen)   <-- только у нас
 *
 * Смешанный II в DATAFLOW-регионе -- ровно то, что убивало регион раньше:
 * ap_sync_done требует ap_done всех стадий в ОДНОМ такте. Под ap_ctrl_hs
 * это не должно мешать, но проверять такое на плате при одной попытке в
 * сутки -- плохая сделка, когда цена устранения три строки.
 *
 * Риск блокирующей записи здесь минимальный: pp_listen пишет ОДИН пакет за
 * всю жизнь ядра, и FIFO listen-порта к этому моменту пуст. Апстримный
 * server() в iperf_client.cpp:405 пишет так же и работает на этом железе.
 *
 * ФОРМА СТАДИИ -- КАК У АПСТРИМА. iperf_client.cpp:386 server(): тот же
 * автомат, PIPELINE II=1, INLINE off, неблокирующее чтение через empty(),
 * и после открытия порта шина port_status больше не читается.
 */
void pp_listen(int listenPort,
               ap_uint<32>& portState,
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
     static bool portOpened = false;

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

     portState = portOpened ? (ap_uint<32>)2
                            : (portRequested ? (ap_uint<32>)1 : (ap_uint<32>)0);
}

/*
 * Echo-конвейер одним FSM. Из hls_pingpong_krnl БЕЗ ИЗМЕНЕНИЙ логики;
 * добавлены только ppState и notifyCount наружу.
 *
 * NOTIFY : пришло уведомление -> выставляем read request
 * META   : забираем rx_meta
 * RX     : читаем слова в буфер до флага last
 * REQ    : выставляем tx_meta на ту же длину и ту же сессию
 * STATUS : ждём подтверждения стека
 * TX     : отдаём буфер обратно
 *
 * Store-and-forward: сообщение принимается целиком, потом отправляется.
 * Иначе нельзя -- см. разбор tx_app_stream_if в шапке файла.
 *
 * static-переменные здесь безопасны: функция вызывается ОДИН раз. Когда
 * в dual_echo такую же стадию вызвали дважды в одном DATAFLOW-регионе,
 * HLS отказался синтезировать (HLS 200-471, feedback dependence on
 * static). Половина b использует апстримный recvData, своего эха у неё
 * нет, поэтому выносить состояние в структуру не требуется.
 */
void pp_echo(ap_uint<32>& ppStateOut,
             ap_uint<32>& notifyCount,
             hls::stream<pkt128>& s_axis_tcp_notification,
             hls::stream<pkt32>& m_axis_tcp_read_pkg,
             hls::stream<pkt16>& s_axis_tcp_rx_meta,
             hls::stream<pkt512>& s_axis_tcp_rx_data,
             hls::stream<pkt32>& m_axis_tcp_tx_meta,
             hls::stream<pkt512>& m_axis_tcp_tx_data,
             hls::stream<pkt64>& s_axis_tcp_tx_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     // ПОРЯДОК ЭТОГО enum -- ЧИСЛА, КОТОРЫЕ ЧИТАЮТСЯ С ПЛАТЫ.
     //
     // ppState отдаётся наружу как есть, поэтому значения зашиты ещё в ДВУХ
     // местах, и при правке порядка их надо менять вместе:
     //
     //   scripts/vivado/jtag_ctrl.tcl   proc _pp_state_name  -- расшифровка
     //                                  в pp_dual_dump
     //   host/hls_pp_dual_krnl/main.go  подсказка при "эхо не пришло"
     //
     // Разъехавшись, они будут называть НЕ ТОТ шаг, а именно по этому числу
     // мы и решаем, где искать дефект. Проверка на согласованность --
     // сравнить руками, автоматической нет.
     enum ppStateType {NOTIFY, META, RX, REQ, STATUS, TX};
     static ppStateType ppState = NOTIFY;
#pragma HLS RESET variable=ppState

     static ap_uint<512> payload[PP_MAX_WORDS];
#pragma HLS BIND_STORAGE variable=payload type=RAM_2P impl=BRAM

     static ap_uint<16> sessionID = 0;
     static ap_uint<16> msgLength = 0;    // обещано уведомлением
     static ap_uint<16> txLength = 0;     // фактически отражаем
     static ap_uint<16> wordCount = 0;    // сохранено в payload[]
     static ap_uint<16> wordIdx = 0;
     static ap_uint<16> bytesRemaining = 0;
     static ap_uint<32> notifications = 0;

     switch (ppState)
     {
     case NOTIFY:
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notification_pkt = s_axis_tcp_notification.read();
               ap_uint<16> notifLength = notification_pkt.data(31, 16);

               notifications++;

               if (notifLength != 0)
               {
                    // sessionID берём из уведомления -- так реконнекты
                    // клиента подхватываются без дополнительной логики
                    sessionID = notification_pkt.data(15, 0);

                    // Запрашиваем не больше, чем вмещает буфер.
                    //
                    // Раньше запрашивалась вся notifLength, а RX молча
                    // отбрасывал слова за PP_MAX_WORDS, продолжая
                    // считать wordCount. В TX индекс уходил за границу
                    // payload[], и эхо содержало мусор при заявленной
                    // полной длине (проверено: слова 64,65 отдавались
                    // как 0x101 вместо данных).
                    //
                    // Остаток стек отдаст следующим уведомлением --
                    // read request только подтверждает то, что заберём.
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
               // Слова сверх буфера отбрасываем, но и НЕ засчитываем:
               // wordCount задаёт, сколько слов отдаст TX, поэтому он
               // не должен превышать число реально сохранённых.
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
          // Отражаем ровно то, что реально приняли и сохранили.
          //
          // msgLength пришла из уведомления, wordCount -- факт приёма.
          // Если стек отдал меньше слов, чем обещал (или больше, чем
          // вместил буфер), доверять надо факту: иначе tx_meta заявит
          // длину, под которую нет данных, и стек будет ждать слова,
          // которых ядро не отдаст.
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
                    ppState = TX;
               }
               else if (error == 1)
               {
                    // соединение разорвано -- ждём следующего сообщения
                    ppState = NOTIFY;
               }
               else
               {
                    // нет места в буфере получателя -- повторяем запрос.
                    // Данные ЛИТЬ НЕЛЬЗЯ: команды pkgPush стек не выдал,
                    // слова осели бы в двух FIFO и сдвинули весь поток.
                    ppState = REQ;
               }
          }
          break;

     case TX:
     {
          pkt512 tx_word;
          // Индекс не может выйти за буфер: wordCount ограничен
          // PP_MAX_WORDS в RX. Маска -- страховка на случай будущих
          // правок, чтобы чтение за границей BRAM не появилось снова.
          tx_word.data = payload[wordIdx & (PP_MAX_WORDS - 1)];

          // в последнем слове валидны только оставшиеся байты
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

     // Телеметрия -- безусловно, каждый проход: так HLS создаёт теневой
     // регистр *_preg и держит значение между обновлениями.
     ppStateOut  = (ap_uint<32>)ppState;
     notifyCount = notifications;
}


extern "C" {
void hls_pp_dual_krnl(
               // ── канал a -> network_krnl_1 (QSFP0): ЭХО ──
               hls::stream<pkt512>& s_axis_udp_rx,
               hls::stream<pkt512>& m_axis_udp_tx,
               hls::stream<pkt256>& s_axis_udp_rx_meta,
               hls::stream<pkt256>& m_axis_udp_tx_meta,

               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status,
               hls::stream<pkt64>& m_axis_tcp_open_connection,
               hls::stream<pkt128>& s_axis_tcp_open_status,
               hls::stream<pkt16>& m_axis_tcp_close_connection,
               hls::stream<pkt128>& s_axis_tcp_notification,
               hls::stream<pkt32>& m_axis_tcp_read_pkg,
               hls::stream<pkt16>& s_axis_tcp_rx_meta,
               hls::stream<pkt512>& s_axis_tcp_rx_data,
               hls::stream<pkt32>& m_axis_tcp_tx_meta,
               hls::stream<pkt512>& m_axis_tcp_tx_data,
               hls::stream<pkt64>& s_axis_tcp_tx_status,
               // ── канал b -> network_krnl_2 (QSFP1): как в фазе 3 ──
               hls::stream<pkt512>& s_axis_udp_rx_b,
               hls::stream<pkt512>& m_axis_udp_tx_b,
               hls::stream<pkt256>& s_axis_udp_rx_meta_b,
               hls::stream<pkt256>& m_axis_udp_tx_meta_b,
               hls::stream<pkt16>& m_axis_tcp_listen_port_b,
               hls::stream<pkt8>& s_axis_tcp_port_status_b,
               hls::stream<pkt64>& m_axis_tcp_open_connection_b,
               hls::stream<pkt128>& s_axis_tcp_open_status_b,
               hls::stream<pkt16>& m_axis_tcp_close_connection_b,
               hls::stream<pkt128>& s_axis_tcp_notification_b,
               hls::stream<pkt32>& m_axis_tcp_read_pkg_b,
               hls::stream<pkt16>& s_axis_tcp_rx_meta_b,
               hls::stream<pkt512>& s_axis_tcp_rx_data_b,
               hls::stream<pkt32>& m_axis_tcp_tx_meta_b,
               hls::stream<pkt512>& m_axis_tcp_tx_data_b,
               hls::stream<pkt64>& s_axis_tcp_tx_status_b,

               int useConn,
               int basePort,
               ap_uint<64> expectedRxByteCnt,
               ap_uint<32>& portState,
               ap_uint<32>& ppState,
               ap_uint<32>& notifyCount
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

#pragma HLS INTERFACE axis port = s_axis_udp_rx_b
#pragma HLS INTERFACE axis port = m_axis_udp_tx_b
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta_b
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta_b
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port_b
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status_b
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection_b
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status_b
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection_b
#pragma HLS INTERFACE axis port = s_axis_tcp_notification_b
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg_b
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta_b
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data_b
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta_b
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data_b
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status_b
#pragma HLS INTERFACE s_axilite port=useConn bundle = control
#pragma HLS INTERFACE s_axilite port=basePort bundle = control
#pragma HLS INTERFACE s_axilite port=expectedRxByteCnt bundle = control
#pragma HLS INTERFACE s_axilite port=portState bundle = control
#pragma HLS INTERFACE s_axilite port=ppState bundle = control
#pragma HLS INTERFACE s_axilite port=notifyCount bundle = control
#pragma HLS INTERFACE s_axilite port = return bundle = control

#pragma HLS dataflow

          // ── канал a: ЭХО. basePort как listenPort -- одна половина
          // слушает один порт, useConn на канале a не применяется.
          pp_listen(basePort, portState,
               m_axis_tcp_listen_port,
               s_axis_tcp_port_status);

          pp_echo(ppState, notifyCount,
               s_axis_tcp_notification,
               m_axis_tcp_read_pkg,
               s_axis_tcp_rx_meta,
               s_axis_tcp_rx_data,
               m_axis_tcp_tx_meta,
               m_axis_tcp_tx_data,
               s_axis_tcp_tx_status);

          tie_off_tcp_open_connection(m_axis_tcp_open_connection,
               s_axis_tcp_open_status);

          tie_off_udp(s_axis_udp_rx,
               m_axis_udp_tx,
               s_axis_udp_rx_meta,
               m_axis_udp_tx_meta);

          tie_off_tcp_close_con(m_axis_tcp_close_connection);

          // ── канал b: дословно как в фазе 3 hls_recv_dual_krnl ──
          //
          // Зачем он здесь, если кабель в него не включён: чтобы отличие
          // от зелёной фазы 3 было минимальным. Уберём половину b -- и
          // при отказе эха придётся выяснять, не в этом ли дело.
          listenPorts (basePort, useConn, m_axis_tcp_listen_port_b,
               s_axis_tcp_port_status_b);

          recvData(expectedRxByteCnt,
               s_axis_tcp_notification_b,
               m_axis_tcp_read_pkg_b,
               s_axis_tcp_rx_meta_b,
               s_axis_tcp_rx_data_b);

          tie_off_udp(s_axis_udp_rx_b,
               m_axis_udp_tx_b,
               s_axis_udp_rx_meta_b,
               m_axis_udp_tx_meta_b);

          tie_off_tcp_open_connection(m_axis_tcp_open_connection_b,
               s_axis_tcp_open_status_b);

          tie_off_tcp_tx(m_axis_tcp_tx_meta_b,
               m_axis_tcp_tx_data_b,
               s_axis_tcp_tx_status_b);

          tie_off_tcp_close_con(m_axis_tcp_close_connection_b);

     }
}
