/************************************************
Измерение задержки TCP-стека: клиент и сервер в одном ядре, оба QSFP
закольцованы кабелем «сам на себя».

ЧТО ИЗМЕРЯЕМ. Боевой OUCH-гейтвей будет выглядеть так:
    n клиентов -> FPGA (серверный сокет) -> мукс -> FPGA (клиентский
    сокет) -> биржа, и обратно.
То есть каждое сообщение проходит стек ДВАЖДЫ: на приём с одного порта
и на передачу в другой. Сколько это стоит по времени — неизвестно, а
без этого числа нельзя оценить бюджет гейтвея. Здесь мы его получаем.

СХЕМА. Половина _a (порт 0) — КЛИЕНТ: открывает соединение к серверу и
шлёт пакет по триггеру от хоста. Половина _b (порт 1) — СЕРВЕР: принимает
соединение и отвечает тем же пакетом в то же соединение (эхо). Пакет
уходит с порта 0, идёт по кабелю на порт 1, возвращается и приходит
назад на порт 0. Замкнутый круг, всё внутри FPGA на одном ap_clk.

ПОЧЕМУ LOOPBACK, А НЕ ГЕНЕРАТОР НА PC. Оба CMAC тактируются от одного
refclk, вся логика на одном ap_clk. Значит таймстемпы с одного счётчика
сопоставимы напрямую — без синхронизации часов, без PTP, с точностью до
такта. Через PC мерилось бы round-trip вместе с джиттером прерываний
драйвера, а он в разы больше измеряемой величины.

ТОЧКИ ИЗМЕРЕНИЯ. Доступны даром четыре — это порты самого ядра:
    t1' = tx_data_a  запрос уходит в стек порта 0
    t2' = rx_data_b  запрос пришёл из стека порта 1 (в эхо)
    t1  = tx_data_b  ответ уходит в стек порта 1
    t2  = rx_data_a  ответ пришёл из стека порта 0 (в измеритель)
Отсюда:
    RTT      = t2  - t1'   весь круг: оба стека дважды, оба CMAC, кабель
    ECHO     = t1  - t2'   время эха внутри ядра (должно быть ~единицы тактов)
    NET_FWD  = t2' - t1'   запрос: стек 0 tx + CMAC + кабель + CMAC + стек 1 rx
    NET_REV  = t2  - t1    ответ: то же в обратную сторону
И проверка: NET_FWD + ECHO + NET_REV = RTT. Не сходится в пределах
пары тактов — значит в тракте оказалось больше одного пакета.

Разложить NET_* на «стек» и «CMAC» отдельно эти четыре точки НЕ дают:
для этого нужны врезки на axis_net_* (точки T), они делаются потом.
Здесь сознательно первый шаг — без врезок, чтобы получить цифру не
трогая тракт CMAC.

РЕЖИМ: ОДИН ПАКЕТ ПО ЯВНОМУ ТРИГГЕРУ. Пакет уходит только когда хост
записал triggerGo. Готовность результата хост видит по sampleReady.
Цикл замера:

    write triggerGo   -> снимает sampleReady и отправляет пакет
    poll  sampleReady -> ждём, пока круг замкнётся
    read  4 регистра  -> сырые таймстемпы, гонки нет
    write triggerGo   -> следующий замер

Шесть транзакций JTAG на замер. Почему так, а не поток по таймеру:

  * СОГЛАСОВАННОСТЬ БЕСПЛАТНО. Пока хост не дёрнул триггер, новый пакет
    физически не появится, значит четвёрку можно читать спокойно — не
    нужны ни сверка номера набора, ни теневые регистры.
  * «Один пакет в тракте» выполняется по построению, а не потому что
    интервал подобран с запасом.
  * ОТЛАДКА ПО ШАГАМ. Дёрнул один пакет, посмотрел счётчики: sent вырос,
    echoes нет — значит запрос не дошёл до порта 1. При потоке пришлось
    бы угадывать по растущим числам.

Цена — скорость: замер стоит ~6 JTAG-транзакций вместо нуля. Для десятков
и сотен замеров это неважно, а больше на этом шаге и не нужно: мы
измеряем ПОЛ (стек без логики гейтвея), и для ответа «единицы микросекунд
или сотни наносекунд» хватает десятка точек. Хвост распределения и замер
под нагрузкой — отдельная задача, туда понадобится поток и seq_id в
payload.

ПАРАМЕТРЫ ЧЕРЕЗ s_axi_control, а не константами: один битстрим, много
экспериментов. Доступ к плате ограничен, а пересборка — час, поэтому
IP/порт/размер сообщения меняются по JTAG без пересборки.

ЧЕГО В ЭТОМ ЯДРЕ НЕТ И ПОЧЕМУ. Собственных IP/MAC у него нет: адрес
интерфейса — свойство стека, его задаёт network_krnl через
s_axi_control (echo_bringup_dual в jtag_ctrl.tcl), у каждого порта свой.
Ядро знает только КУДА подключаться (serverIp/serverPort). MAC получателя
резолвит стек через ARP, порт источника выбирает стек.

ОГРАНИЧЕНИЕ СТЕКА, о котором надо помнить при выборе адресов.
ARP-таблица в arp_server_subnet.cpp — это arpTable[256], индексируемая
ОДНИМ октетом адреса:

    arpTable[query_ip(31,24)]

Адреса внутри стека лежат LSB-first (автор прямо пишет это в
network_stack.sv:38 «LSB first», и IP_SUBNET_MASK там же записана как
32'h00FFFFFF, то есть /24 перевёрнутая). Значит разряды (31,24) — это
ПОСЛЕДНИЙ октет IP. Для нашей пары 10.1.212.152 / .153 индексы 152 и 153
различаются, коллизии нет.

Но для боевого гейтвея с n клиентами правило такое: у клиентов ДОЛЖНЫ
различаться последние октеты IP. Совпал последний октет — вторая запись
затирает первую, разрешения коллизий в таблице нет. Плюс маска /24 зашита
параметром, а IP_DEFAULT_GATEWAY = 0, поэтому все участники обязаны быть
в одной подсети.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Максимальный размер сообщения в 64-байтных словах.
// 64 слова = 4096 байт — с запасом на свипы до 1500 байт.
// Степень двойки: маска используется как защита от выхода за BRAM.
#define EPD_MAX_WORDS 64
static_assert((EPD_MAX_WORDS & (EPD_MAX_WORDS - 1)) == 0,
              "EPD_MAX_WORDS должен быть степенью двойки (см. маску в TX)");

// Таймаут ожидания ответа, такты. Если ответ не пришёл — клиент считает
// пакет потерянным и шлёт следующий, иначе тест встал бы навсегда на
// первой же потере. 165 МГц * 1 мс ≈ 165000; берём с запасом.
#define EPD_RX_TIMEOUT 1000000

// Таймаут ожидания ответа стека на запрос listen, такты. Нужен по той же
// причине: молчание стека не должно останавливать тест навсегда. См.
// пояснение в epd_server_listen.
#define EPD_LISTEN_TIMEOUT 1000000

// ─────────────────────────────────────────────────────────────────────────────
// ПОЧЕМУ СТАДИИ ОБМЕНИВАЮТСЯ ПОТОКАМИ, А НЕ ССЫЛКАМИ НА СКАЛЯРЫ
//
// Верхняя функция помечена DATAFLOW, то есть стадии становятся независимыми
// процессами. В таком регионе связь между процессами должна идти через
// hls::stream (или PIPO-массивы) — скаляр, переданный по ссылке между двумя
// стадиями, HLS либо отвергнет, либо разложит непредсказуемо. В csim это
// молча «работает», потому что там обычный C++, и ошибка проявилась бы только
// на csynth.
//
// Так сделано и в проверенных ядрах репозитория: hls_ouch_krnl передаёт между
// стадиями rxSessionFifo/rxLengthFifo, а наружу пишет только выходные
// регистры s_axilite. Повторяем эту идиому.
//
// Отсюда конструкция ниже:
//   * ВРЕМЯ ЯДРО НЕ ИЗМЕРЯЕТ ВООБЩЕ. Оно только считает события и отдаёт
//     счётчики наружу; таймстемпы по их ap_vld ставит HDL-обёртка, где живёт
//     единственный счётчик тактов. Так шкала одна ФИЗИЧЕСКИ, а не по свойству
//     расписания HLS. Две предыдущие попытки сделать иначе — по счётчику на
//     стадию, затем общий счётчик проводом внутрь — обе давали две разные
//     шкалы; подробный разбор там, где раньше была стадия epd_latch;
//   * sessionID от connect к traffic — потоком (скаляр по ссылке между
//     стадиями HLS не разрешает).
//
// 32 бита при 165 МГц переполняются за 26 секунд; разности берутся по модулю
// 2^32, а измеряемые интервалы — микросекунды, так что это не мешает.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// КЛИЕНТ (половина _a, порт 0)
// ─────────────────────────────────────────────────────────────────────────────

/*
 * Открывает TCP-соединение к серверу и держит sessionID.
 *
 * ПОЧЕМУ НЕ openConnections() из communication.hpp: та функция
 * блокирующая — читает openStatus в for-цикле. У нас ap_ctrl_none, тело
 * исполняется каждый такт, блокирующее чтение означало бы залипание
 * всего ядра. Нужен автомат.
 *
 * ПРО enable: как и в ppp_listen, до разрешения хоста регистры
 * serverIp/serverPort могут быть ещё не записаны. Пока enable=0 не
 * трогаем ни один порт стека. Порядок записи на хосте: сначала
 * параметры, потом enable.
 *
 * Повтор при неудаче: стек отвечает success=0, если сервер ещё не поднял
 * listen. Это нормальная ситуация на старте — обе половины запускаются
 * одновременно, и клиент может успеть раньше сервера. Поэтому при
 * отказе ждём retryDelay тактов и пробуем снова, а не сдаёмся.
 */
void epd_client_connect(int enable,
                        int serverIp,
                        int serverPort,
                        ap_uint<32>& connAttempts,
                        hls::stream<ap_uint<16> >& sessionFifo,
                        hls::stream<pkt64>& m_axis_tcp_open_connection,
                        hls::stream<pkt128>& s_axis_tcp_open_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum connState {IDLE, WAIT_STATUS, RETRY_WAIT, DONE};
     static connState st = IDLE;
#pragma HLS RESET variable=st
     static ap_uint<32> retryTimer = 0;
#pragma HLS RESET variable=retryTimer
     static ap_uint<32> attempts = 0;
#pragma HLS RESET variable=attempts

     // Пауза между попытками: даём серверной половине время открыть
     // listen-порт. 100000 тактов ≈ 0.6 мс на 165 МГц.
     const ap_uint<32> retryDelay = 100000;

     if (!enable)
          return;

     switch (st)
     {
     case IDLE:
     {
          pkt64 open_pkt;
          open_pkt.data = 0;
          open_pkt.data(31, 0)  = serverIp;
          open_pkt.data(47, 32) = serverPort;
          m_axis_tcp_open_connection.write(open_pkt);
          attempts++;
          connAttempts = attempts;
          st = WAIT_STATUS;
          break;
     }

     case WAIT_STATUS:
          if (!s_axis_tcp_open_status.empty())
          {
               pkt128 status_pkt = s_axis_tcp_open_status.read();
               ap_uint<16> sid  = status_pkt.data(15, 0);
               ap_uint<1>  succ = status_pkt.data(16, 16);

               if (succ)
               {
                    // sessionID уходит потоком: traffic-стадия ждёт его
                    // как признак «соединение готово». Пишем ровно один
                    // раз — дальше st=DONE, повторно не открываем.
                    sessionFifo.write(sid);
                    st = DONE;
               }
               else
               {
                    retryTimer = 0;
                    st = RETRY_WAIT;
               }
          }
          break;

     case RETRY_WAIT:
          retryTimer++;
          if (retryTimer >= retryDelay)
               st = IDLE;
          break;

     case DONE:
          // Соединение установлено. Повторно не открываем: тест
          // измеряет steady-state одной сессии.
          break;
     }
}

/*
 * Отправляет ОДИН пакет по фронту triggerGo и принимает ответ.
 *
 * Здесь снимаются две точки: t1' (запрос ушёл) и t2 (ответ пришёл).
 *
 * ФРОНТ ПО ИЗМЕНЕНИЮ ЗНАЧЕНИЯ, а не по единице: тогда хосту не нужно
 * сбрасывать регистр в ноль между замерами — достаточно писать
 * инкрементирующееся число. Одна транзакция вместо двух.
 *
 * ПОЧЕМУ tx_status ЧИТАЕТСЯ ДО отправки данных: стек требует сначала
 * tx_meta (заявку на длину), затем подтверждение, и только потом
 * данные. Если писать данные раньше подтверждения, стек их отбросит.
 * Порядок взят из hls_pingpong_krnl, где он проверен тестбенчем.
 */
void epd_client_traffic(int enable,
                        int msgBytes,
                        int triggerGo,
                        hls::stream<ap_uint<16> >& sessionFifo,
                        ap_uint<32>& sentCount,
                        ap_uint<32>& recvCount,
                        ap_uint<32>& timeoutCount,
                        hls::stream<pkt32>& m_axis_tcp_tx_meta,
                        hls::stream<pkt512>& m_axis_tcp_tx_data,
                        hls::stream<pkt64>& s_axis_tcp_tx_status,
                        hls::stream<pkt128>& s_axis_tcp_notification,
                        hls::stream<pkt32>& m_axis_tcp_read_pkg,
                        hls::stream<pkt16>& s_axis_tcp_rx_meta,
                        hls::stream<pkt512>& s_axis_tcp_rx_data)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum txState {WAIT_TRIGGER, REQ_META, WAIT_TXSTATUS, SEND_DATA,
                   WAIT_NOTIF, RX_META, RX_DATA};
     static txState st = WAIT_TRIGGER;
#pragma HLS RESET variable=st

     // Предыдущее значение triggerGo: фронт ловим по изменению.
     static int prevGo = 0;
#pragma HLS RESET variable=prevGo
     static ap_uint<32> waitTimer = 0;
#pragma HLS RESET variable=waitTimer
     static ap_uint<16> txWordsLeft = 0;
     static ap_uint<16> txBytesLeft = 0;
     static ap_uint<16> txWordIdx = 0;
     static ap_uint<16> rxLength = 0;
     static ap_uint<32> sent = 0;
     static ap_uint<32> recv = 0;
     static ap_uint<32> timeouts = 0;

     // sessionID приходит один раз от connect-стадии и дальше хранится.
     static ap_uint<16> sessionID = 0;
     static bool connected = false;
#pragma HLS RESET variable=connected
     if (!connected && !sessionFifo.empty())
     {
          sessionID = sessionFifo.read();
          connected = true;
     }

     if (!enable || !connected)
          return;

     // Число слов для сообщения: ceil(msgBytes / 64), с ограничением.
     ap_uint<16> wantBytes = (ap_uint<16>)msgBytes;
     if (wantBytes == 0) wantBytes = 64;
     const ap_uint<16> maxBytes = EPD_MAX_WORDS * 64;
     if (wantBytes > maxBytes) wantBytes = maxBytes;
     ap_uint<16> wantWords = (wantBytes + 63) >> 6;

     switch (st)
     {
     case WAIT_TRIGGER:
          // Фронт по изменению значения. Хост пишет инкремент, поэтому
          // сбрасывать регистр между замерами не нужно.
          if (triggerGo != prevGo)
          {
               prevGo = triggerGo;
               st = REQ_META;
          }
          break;

     case REQ_META:
     {
          pkt32 meta;
          meta.data = 0;
          meta.data(15, 0)  = sessionID;
          meta.data(31, 16) = wantBytes;
          m_axis_tcp_tx_meta.write(meta);
          st = WAIT_TXSTATUS;
          break;
     }

     case WAIT_TXSTATUS:
          if (!s_axis_tcp_tx_status.empty())
          {
               pkt64 status = s_axis_tcp_tx_status.read();
               ap_uint<2> error = status.data(63, 62);

               if (error == 0)
               {
                    txWordIdx   = 0;
                    txWordsLeft = wantWords;
                    txBytesLeft = wantBytes;
                    st = SEND_DATA;
               }
               else if (error == 1)
               {
                    // Нет места в буфере стека — подождём и повторим
                    // заявку. Не считаем это потерей.
                    st = WAIT_TRIGGER;
               }
               else
               {
                    // Прочие ошибки: повторяем заявку сразу.
                    st = REQ_META;
               }
          }
          break;

     case SEND_DATA:
     {
          pkt512 word;
          word.data = 0;
          if (txWordIdx == 0)
          {
               // payload[0..3] — номер отправки. Не для сопоставления
               // (в тракте один пакет), а чтобы эхо было отличимо от мусора
               // при отладке в ILA. Он же станет seq_id, когда дойдём до
               // замера под нагрузкой, где пакетов в тракте будет много.
               word.data(31, 0) = sent;

               // payload[4..9] — МАРКЕР ДЛЯ ФИЛЬТРА ВРЕЗОК на axis_net_*.
               //
               // Зачем он нужен. На axis_net_* идёт весь трафик стека, и наш
               // кадр там ничем не выделен. Фильтр по одной длине (число слов)
               // не отличает наш кадр от TCP SYN с опциями — оба двухсловные
               // при msgBytes=64. Маркер закрывает эту дырку: у SYN на тех же
               // битах лежат опции MSS/SACK/WS, а не эта константа.
               //
               // ПОЧЕМУ ИМЕННО payload[4..9], А НЕ payload[0..3]. Смещение
               // должно быть фиксированным, а payload[0..3] занят `sent`,
               // который меняется каждый замер — как константу его не сравнить.
               //
               // ПОЧЕМУ ЭТО ПОПАДАЕТ В ПЕРВОЕ СЛОВО НА ПРОВОДЕ. Заголовки перед
               // payload — Ethernet 14 + IP 20 + TCP 20 = 54 байта, и это
               // ФИКСИРОВАННО: опции TCP (TCP_OPTIONAL_HEADER_SIZE) стек
               // добавляет только в SYN, у кадров с данными заголовок ровно 20
               // байт (TCP_HEADER_SIZE=160 бит, toe_internals.hpp:426).
               // Значит payload[k] на проводе лежит на байте 54+k, а маркер
               // payload[4..9] — на байтах 58..63 КАДРА, то есть на битах
               // 464..511 ПЕРВОГО 512-битного слова, при любом msgBytes.
               //
               // ВНИМАНИЕ: ЗДЕСЬ ДРУГАЯ НУМЕРАЦИЯ БИТОВ, ЧЕМ В ФИЛЬТРЕ, и это
               // не описка. Здесь слово PAYLOAD (бит 8k = payload-байт k), а
               // фильтр смотрит слово КАДРА (бит 8k = байт кадра k, где payload
               // сдвинут заголовками на 54 байта). Одни и те же payload-байты
               // 4..9 записываются здесь как (79,32), а проверяются там как
               // [511:464]; числа ОБЯЗАНЫ различаться на 54*8 = 432 бита.
               //
               // Если написать здесь (511,464) «для симметрии» с фильтром —
               // маркер уедет в payload-байты 58..63, то есть во ВТОРОЕ слово
               // кадра (а при msgBytes<58 исчезнет вовсе). Фильтр его никогда
               // не увидит, и симптом будет обманчивым: passed=0 при растущем
               // dropped, то есть неотличимо от «minWords завышен».
               //
               // Значение должно совпадать с EPD_MARKER в net_frame_filter.v.
               // Выбрано не «красивым» (0xDEADBEEF и подобные слишком часто
               // встречаются в чужих дампах и тестовых паттернах), а таким,
               // какое не появится в заголовках и паддинге: не 0x00 и не 0xFF
               // ни в одном байте, не ASCII, не похоже на адрес или длину.
               word.data(79, 32) = ap_uint<48>(0x5A3C96E1B7D2ULL);
          }

          ap_uint<7> validBytes = (txBytesLeft >= 64) ? (ap_uint<7>)64
                                                     : (ap_uint<7>)txBytesLeft;
          for (int b = 0; b < 64; b++)
          {
          #pragma HLS UNROLL
               word.keep(b, b) = (b < validBytes) ? 1 : 0;
          }
          txBytesLeft = (txBytesLeft >= 64) ? (ap_uint<16>)(txBytesLeft - 64)
                                            : (ap_uint<16>)0;

          txWordIdx++;
          word.last = (txWordIdx == txWordsLeft);
          m_axis_tcp_tx_data.write(word);

          if (word.last)
          {
               // СОБЫТИЕ t1': последнее слово запроса отдано стеку.
               // Берём последнее, а не первое, чтобы измерение не
               // зависело от размера сообщения на стороне отправки.
               // Время по ap_vld этого счётчика штампует обёртка.
               sent++;
               sentCount = sent;
               waitTimer = 0;
               st = WAIT_NOTIF;
          }
          break;
     }

     case WAIT_NOTIF:
          waitTimer++;
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notif = s_axis_tcp_notification.read();
               ap_uint<16> len = notif.data(31, 16);
               ap_uint<16> sid = notif.data(15, 0);

               if (len != 0)
               {
                    rxLength = len;
                    pkt32 rd;
                    rd.data = 0;
                    rd.data(15, 0)  = sid;
                    rd.data(31, 16) = len;
                    m_axis_tcp_read_pkg.write(rd);
                    st = RX_META;
               }
          }
          else if (waitTimer >= (ap_uint<32>)EPD_RX_TIMEOUT)
          {
               // Ответ не пришёл — не залипаем, идём к следующему пакету.
               timeouts++;
               timeoutCount = timeouts;
               st = WAIT_TRIGGER;
          }
          break;

     case RX_META:
          if (!s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               st = RX_DATA;
          }
          break;

     case RX_DATA:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 word = s_axis_tcp_rx_data.read();
               if (word.last)
               {
                    // СОБЫТИЕ t2: последнее слово ответа получено.
                    // Симметрично t1' — тоже последнее слово, поэтому
                    // RTT не зависит от размера сообщения.
                    recv++;
                    recvCount = recv;
                    st = WAIT_TRIGGER;
               }
          }
          break;
     }
}

// ─────────────────────────────────────────────────────────────────────────────
// СЕРВЕР-ЭХО (половина _b, порт 1)
// ─────────────────────────────────────────────────────────────────────────────

/*
 * Открывает listen-порт, повторяя запрос до подтверждения.
 * Структура повторяет ppp_listen из hls_pingpong_probe_krnl — там она
 * продумана и снабжена пояснением про гонку с enable.
 */
void epd_server_listen(int enable,
                       int listenPort,
                       ap_uint<32>& listenAttempts,
                       ap_uint<32>& portState,
                       hls::stream<pkt16>& m_axis_tcp_listen_port,
                       hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
#pragma HLS RESET variable=portRequested
     static bool portOpened = false;
#pragma HLS RESET variable=portOpened
     static ap_uint<32> waitTimer = 0;
#pragma HLS RESET variable=waitTimer
     static ap_uint<32> attempts = 0;
#pragma HLS RESET variable=attempts

     if (!enable)
     {
          // Не затираем 2, если порт уже был открыт: enable=0 не закрывает
          // listen в стеке, так что рапортовать "ждём enable" было бы
          // неправдой. Ноль показываем только до первого запроса.
          if (!portRequested)
               portState = 0;
          return;
     }

     if (!portRequested)
     {
          pkt16 listen_pkt;
          listen_pkt.data = 0;
          listen_pkt.data(15, 0) = listenPort;
          m_axis_tcp_listen_port.write(listen_pkt);
          portRequested = true;
          waitTimer = 0;
          attempts++;
          listenAttempts = attempts;
          portState = 1;
     }
     else if (!portOpened)
     {
          if (!s_axis_tcp_port_status.empty())
          {
               pkt8 status = s_axis_tcp_port_status.read();
               ap_uint<1> success = status.data(0, 0);
               if (success)
               {
                    portOpened = true;
                    portState = 2;
               }
               else
               {
                    portRequested = false;
               }
          }
          else if (waitTimer >= (ap_uint<32>)EPD_LISTEN_TIMEOUT)
          {
               // Стек промолчал. Без этой ветки автомат остался бы в
               // "запрос отправлен, ответа ждём" НАВСЕГДА, и снаружи это
               // выглядит как вечный таймаут epd_measure без объяснения:
               // клиент исправно повторяет попытки соединения (connAttempts
               // растёт), а сервер молча не слушает.
               //
               // Такая же дыра есть во всех родственных ядрах репозитория и
               // в апстримных iperf_client/scatter. Там она не всплывала,
               // потому что под XRT хост конфигурировал стек ДО старта
               // user-ядра. У нас ap_ctrl_none плюс JTAG через десятки
               // секунд — порядок обратный, и дыра стала достижимой.
               portRequested = false;
          }
          else
          {
               waitTimer++;
          }
     }
}

/*
 * Эхо: принимает сообщение и отправляет его обратно в ту же сессию.
 *
 * Здесь снимаются точки t2' (запрос пришёл в эхо) и t1 (ответ ушёл).
 * Разность даёт ECHO — время обработки внутри ядра. В боевом гейтвее на
 * этом месте будет мукс с OUCH-логикой, и ECHO станет её ценой; сейчас
 * он должен быть в единицы тактов, что и подтвердит корректность
 * измерения.
 *
 * Автомат повторяет ppp_echo, проверенный тестбенчем hls_pingpong_krnl
 * на 11 сценариях (усечённые сообщения, разбиение на два уведомления,
 * backpressure). Отличие: таймстемпы вместо записи счётчика в payload —
 * измеритель у нас внутри, гонять значение через данные незачем.
 */
void epd_server_echo(ap_uint<32>& echoRxCount,
                     ap_uint<32>& echoCount,
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

     enum echoState {NOTIFY, META, RX, REQ, STATUS, TX};
     static echoState st = NOTIFY;
#pragma HLS RESET variable=st

     static ap_uint<512> payload[EPD_MAX_WORDS];
#pragma HLS BIND_STORAGE variable=payload type=RAM_2P impl=BRAM

     static ap_uint<16> sessionID = 0;
     static ap_uint<16> msgLength = 0;
     static ap_uint<16> txLength = 0;
     static ap_uint<16> wordCount = 0;
     static ap_uint<16> wordIdx = 0;
     static ap_uint<16> bytesRemaining = 0;
     static ap_uint<32> echoes = 0;
     static ap_uint<32> rxDone = 0;

     switch (st)
     {
     case NOTIFY:
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notif = s_axis_tcp_notification.read();
               ap_uint<16> notifLength = notif.data(31, 16);

               if (notifLength != 0)
               {
                    sessionID = notif.data(15, 0);

                    const ap_uint<16> maxBytes = EPD_MAX_WORDS * 64;
                    msgLength = (notifLength > maxBytes) ? maxBytes : notifLength;

                    pkt32 rd;
                    rd.data = 0;
                    rd.data(15, 0)  = sessionID;
                    rd.data(31, 16) = msgLength;
                    m_axis_tcp_read_pkg.write(rd);

                    wordCount = 0;
                    st = META;
               }
          }
          break;

     case META:
          if (!s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               st = RX;
          }
          break;

     case RX:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 word = s_axis_tcp_rx_data.read();
               if (wordCount < EPD_MAX_WORDS)
               {
                    payload[wordCount] = word.data;
                    wordCount++;
               }
               if (word.last)
               {
                    // СОБЫТИЕ t2': последнее слово запроса получено эхом.
                    // Симметрично t1' на клиенте — оба по последнему слову.
                    //
                    // Раньше здесь ставился таймстемп (tEchoIn = cyc). Теперь
                    // инкрементируется счётчик, а время по его ap_vld штампует
                    // обёртка — см. пояснение выше про epd_latch.
                    //
                    // Счётчик полезен и сам по себе: без него echoes=0 не
                    // отличить от «запрос до эха не дошёл». Та же причина, по
                    // которой существуют listenAttempts и portState.
                    rxDone++;
                    echoRxCount = rxDone;
                    st = REQ;
               }
          }
          break;

     case REQ:
     {
          ap_uint<16> wordBytes = (ap_uint<16>)(wordCount * 64);
          txLength = (msgLength < wordBytes) ? msgLength : wordBytes;

          pkt32 meta;
          meta.data = 0;
          meta.data(15, 0)  = sessionID;
          meta.data(31, 16) = txLength;
          m_axis_tcp_tx_meta.write(meta);
          st = STATUS;
          break;
     }

     case STATUS:
          if (!s_axis_tcp_tx_status.empty())
          {
               pkt64 status = s_axis_tcp_tx_status.read();
               ap_uint<2> error = status.data(63, 62);

               if (error == 0)
               {
                    wordIdx = 0;
                    bytesRemaining = txLength;
                    st = TX;
               }
               else if (error == 1)
               {
                    // Нет места — сообщение теряем, ждём следующего.
                    // Так делает и ppp_echo: лучше пропустить, чем
                    // залипнуть на повторах.
                    st = NOTIFY;
               }
               else
               {
                    st = REQ;
               }
          }
          break;

     case TX:
     {
          pkt512 word;
          word.data = payload[wordIdx & (EPD_MAX_WORDS - 1)];

          ap_uint<7> validBytes = (bytesRemaining >= 64) ? (ap_uint<7>)64
                                                         : (ap_uint<7>)bytesRemaining;
          for (int b = 0; b < 64; b++)
          {
          #pragma HLS UNROLL
               word.keep(b, b) = (b < validBytes) ? 1 : 0;
          }
          bytesRemaining = (bytesRemaining >= 64) ? (ap_uint<16>)(bytesRemaining - 64)
                                                  : (ap_uint<16>)0;

          wordIdx++;
          word.last = (wordIdx == wordCount);
          m_axis_tcp_tx_data.write(word);

          if (word.last)
          {
               // ТОЧКА t1: последнее слово ответа отдано стеку.
               // Пара (t2', t1) уходит измерителю вместе — по той же
               // причине, что и на клиенте: чтобы нельзя было сложить
               // точки разных пакетов.
               // СОБЫТИЕ t1: последнее слово ответа отдано стеку.
               echoes++;
               echoCount = echoes;
               st = NOTIFY;
          }
          break;
     }
     }
}

// ─────────────────────────────────────────────────────────────────────────────
// ЗАЩЁЛКА СЫРЫХ ТАЙМСТЕМПОВ
// ─────────────────────────────────────────────────────────────────────────────

/*
 * ЗАЩЁЛКА ТАЙМСТЕМПОВ ПЕРЕЕХАЛА В HDL-ОБЁРТКУ.
 *
 * Здесь была стадия epd_latch: она собирала четыре таймстемпа из FIFO и
 * выставляла sampleReady. Убрана целиком, вместе с четырьмя tsFifo* и входным
 * скаляром cycleCount. Причина — не стиль, а обнаруженный на сгенерированном
 * RTL дефект.
 *
 * ЧТО БЫЛО НЕ ТАК. Шкалу времени пробовали передать в ядро скаляром
 * cycleCount (провод из счётчика в обёртке), чтобы обе половины штампевали
 * время из одного источника. HLS раздал этот скаляр НЕСИММЕТРИЧНО:
 *
 *   epd_server_echo  — получил его проводом:
 *       input [31:0] cycleCount;   tEchoIn <= cycleCount;
 *   epd_client_traffic — получил его FIFO-каналом глубины 3:
 *       input cycleCount_c_empty_n;  output cycleCount_c_read;
 *       tRequest <= cycleCount_c_dout;
 *
 * (проверено в syn/verilog: entry_proc пишет в канал cycleCount_c_U, клиент
 * читает из него, эхо читает провод). Значит t1'/t2 брались из значения,
 * задержанного каналом, а t2'/t1 — с провода: те же две шкалы, только этажом
 * выше. NET_FWD завышался ровно настолько, насколько занижался NET_REV, при
 * верных RTT и ECHO и сходящемся балансе — то есть невидимо для хоста.
 *
 * Хуже: пустой канал БЛОКИРУЕТ стадию клиента
 * (ap_block_state1_pp0_stage0_iter0 включает cycleCount_c_empty_n == 0), а
 * писатель ограничен ap_start. При ap_ctrl_none это прямой путь к вечному
 * ожиданию после исчерпания FIFO глубины 3 — те самые предупреждения
 * HLS 200-656 про дедлоки, но с конкретным механизмом. Симптом на плате был
 * бы «sentCount замер на единице», неотличимый от «соединение не открылось».
 *
 * ВЫВОД: скаляр, меняющийся каждый такт и читаемый ДВУМЯ стадиями, передавать
 * в HLS нельзя — размножение остаётся на усмотрение инструмента. (iperf не
 * опровержение: там timeInCycles читает одна стадия.)
 *
 * КАК СДЕЛАНО ТЕПЕРЬ. Ядро наружу отдаёт только СЧЁТЧИКИ СОБЫТИЙ, а время
 * штампует обёртка — у неё один счётчик и один тактовый домен:
 *
 *     t1' <- sentCount_ap_vld     (клиент отдал последнее слово запроса)
 *     t2' <- echoRxCount_ap_vld   (эхо приняло последнее слово запроса)
 *     t1  <- echoCount_ap_vld     (эхо отдало последнее слово ответа)
 *     t2  <- recvCount_ap_vld     (клиент принял последнее слово ответа)
 *
 * ap_vld у этих выходов — готовый строб «значение изменилось в этом такте»,
 * его выдаёт HLS сам (проверено в epd_core.v: sentCount_ap_vld и т.д.).
 * Обёртке не нужен ни детектор изменения, ни канал.
 *
 * Шкала стала одна ФИЗИЧЕСКИ: один регистр, четыре читателя в том же домене.
 * Обёртка видит событие на такт позже самого события, но ОДИНАКОВО для всех
 * четырёх точек, поэтому разности точны — а абсолютные значения нигде не
 * используются.
 *
 * sampleReady тоже переехал в обёртку: там он становится простым флагом
 * «t2 пришёл после последнего triggerGo».
 *
 * Соображения про сырые значения вместо агрегатов (гибкость, отладка, место, и
 * главное — невозможность корректно прочитать 64-битную сумму двумя
 * AXI-транзакциями) остаются в силе; они теперь относятся к регистрам обёртки.
 */

// ─────────────────────────────────────────────────────────────────────────────
// ВЕРХНИЙ УРОВЕНЬ
// ─────────────────────────────────────────────────────────────────────────────

void epd_core(
     // половина a — клиент, порт 0 (network_krnl_1)
     hls::stream<pkt512>& s_axis_udp_rx_a,
     hls::stream<pkt512>& m_axis_udp_tx_a,
     hls::stream<pkt256>& s_axis_udp_rx_meta_a,
     hls::stream<pkt256>& m_axis_udp_tx_meta_a,
     hls::stream<pkt16>& m_axis_tcp_listen_port_a,
     hls::stream<pkt8>& s_axis_tcp_port_status_a,
     hls::stream<pkt64>& m_axis_tcp_open_connection_a,
     hls::stream<pkt128>& s_axis_tcp_open_status_a,
     hls::stream<pkt16>& m_axis_tcp_close_connection_a,
     hls::stream<pkt128>& s_axis_tcp_notification_a,
     hls::stream<pkt32>& m_axis_tcp_read_pkg_a,
     hls::stream<pkt16>& s_axis_tcp_rx_meta_a,
     hls::stream<pkt512>& s_axis_tcp_rx_data_a,
     hls::stream<pkt32>& m_axis_tcp_tx_meta_a,
     hls::stream<pkt512>& m_axis_tcp_tx_data_a,
     hls::stream<pkt64>& s_axis_tcp_tx_status_a,
     // половина b — сервер-эхо, порт 1 (network_krnl_2)
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
     // параметры
     // enableConn/Traffic/Listen — одно значение из обёртки, раздельные
     // аргументы, чтобы у каждого был ОДИН читатель (см. шапку топ-функции).
     int enableConn, int enableTraffic, int enableListen,
     int serverIp, int serverPort, int listenPort,
     int msgBytes, int triggerGo,
     // счётчики событий. Время по их ap_vld штампует HDL-обёртка — таймстемпов
     // и sampleReady здесь больше нет, см. пояснение выше (было epd_latch).
     ap_uint<32>& connAttempts, ap_uint<32>& sentCount,
     ap_uint<32>& recvCount, ap_uint<32>& timeoutCount,
     ap_uint<32>& echoRxCount, ap_uint<32>& echoCount,
     ap_uint<32>& listenAttempts, ap_uint<32>& portState)
{
#pragma HLS INLINE off

// disable_start_propagation убран и здесь -- по той же причине, что на топе: он не
// даёт импульсу ap_start дойти до стадий, и барьер ap_sync_done остаётся
// взведённым. См. подробное пояснение у ap_ctrl_hs в топ-функции.
#pragma HLS DATAFLOW

     // ЗДЕСЬ stable ОСТАЁТСЯ, И ЭТО НЕ ПРОТИВОРЕЧИТ ap_none ВЫШЕ.
     //
     // epd_core — ВЛОЖЕННЫЙ dataflow-регион, а не топ-функция. Форма интерфейса
     // задаётся только на границе ядра, поэтому #pragma HLS INTERFACE здесь
     // неприменим: у внутренней функции нет RTL-портов, есть аргументы региона.
     // Единственный способ снять их синхронизацию со стартом региона — stable.
     //
     // Разделение обязанностей получается такое:
     //   * на границе ядра (топ-функция) — ap_none register: «это провод»;
     //   * на границе вложенного региона — stable: «не синхронизируй меня
     //     со стартом, значение приходит асинхронно».
     //
     // Требование stable при этом соблюдено буквально: UG1399 требует, чтобы
     // читаемые ячейки не перезаписывались ДРУГИМ ПРОЦЕССОМ ИЛИ ВЫЗЫВАЮЩИМ
     // КОНТЕКСТОМ во время исполнения региона. Все эти скаляры — внешние входы,
     // внутри дизайна их не пишет никто. Предупреждение HLS 200-991 ловит
     // именно запись stable-скаляра, и в наших логах его нет.
     //
     // triggerGo меняется во время работы, и это не ограничение: он только
     // читается и сравнивается с прошлым значением. Скаляр, меняющийся КАЖДЫЙ
     // такт, здесь больше не передаётся — попытка так сделать (cycleCount)
     // кончилась несимметричным размножением через FIFO, см. пояснение выше.
#pragma HLS stable variable = enableConn
#pragma HLS stable variable = enableTraffic
#pragma HLS stable variable = enableListen
#pragma HLS stable variable = serverIp
#pragma HLS stable variable = serverPort
#pragma HLS stable variable = listenPort
#pragma HLS stable variable = msgBytes
#pragma HLS stable variable = triggerGo

     // ── каналы между стадиями ──
     // Глубина 2 достаточна: в тракте один пакет, значит в каждом канале
     // не бывает больше одной записи одновременно. Двойка — запас на
     // такт рассинхрона между стадиями.
     static hls::stream<ap_uint<16> > sessionFifo("sessionFifo");
     #pragma HLS STREAM variable=sessionFifo depth=2

     // tsRequestFifo/tsReplyFifo/tsEchoInFifo/tsEchoOutFifo убраны вместе с
     // epd_latch: таймстемпы больше не ходят внутри ядра, их ставит обёртка по
     // ap_vld счётчиков событий.

     // --- клиент (порт 0) ---
     epd_client_connect(enableConn, serverIp, serverPort, connAttempts,
                        sessionFifo,
                        m_axis_tcp_open_connection_a, s_axis_tcp_open_status_a);

     epd_client_traffic(enableTraffic, msgBytes, triggerGo,
                        sessionFifo,
                        sentCount, recvCount, timeoutCount,
                        m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
                        s_axis_tcp_tx_status_a,
                        s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                        s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a);

     // --- сервер-эхо (порт 1) ---
     epd_server_listen(enableListen, listenPort, listenAttempts, portState,
                       m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b);

     epd_server_echo(echoRxCount, echoCount,
                     s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                     s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b,
                     m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
                     s_axis_tcp_tx_status_b);

     // --- заглушки на неиспользуемое ---
     // Клиент не слушает порт, сервер не открывает соединений.
     tie_off_tcp_listen_port(m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection_b,
                                 s_axis_tcp_open_status_b);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_a);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_b);
     tie_off_udp(s_axis_udp_rx_a, m_axis_udp_tx_a,
                 s_axis_udp_rx_meta_a, m_axis_udp_tx_meta_a);
     tie_off_udp(s_axis_udp_rx_b, m_axis_udp_tx_b,
                 s_axis_udp_rx_meta_b, m_axis_udp_tx_meta_b);
}

extern "C" {
void hls_echo_probe_dual_krnl(
               // ── половина a: КЛИЕНТ, порт 0 (network_krnl_1) ──
               hls::stream<pkt512>& s_axis_udp_rx_a,
               hls::stream<pkt512>& m_axis_udp_tx_a,
               hls::stream<pkt256>& s_axis_udp_rx_meta_a,
               hls::stream<pkt256>& m_axis_udp_tx_meta_a,
               hls::stream<pkt16>& m_axis_tcp_listen_port_a,
               hls::stream<pkt8>& s_axis_tcp_port_status_a,
               hls::stream<pkt64>& m_axis_tcp_open_connection_a,
               hls::stream<pkt128>& s_axis_tcp_open_status_a,
               hls::stream<pkt16>& m_axis_tcp_close_connection_a,
               hls::stream<pkt128>& s_axis_tcp_notification_a,
               hls::stream<pkt32>& m_axis_tcp_read_pkg_a,
               hls::stream<pkt16>& s_axis_tcp_rx_meta_a,
               hls::stream<pkt512>& s_axis_tcp_rx_data_a,
               hls::stream<pkt32>& m_axis_tcp_tx_meta_a,
               hls::stream<pkt512>& m_axis_tcp_tx_data_a,
               hls::stream<pkt64>& s_axis_tcp_tx_status_a,

               // ── половина b: СЕРВЕР-ЭХО, порт 1 (network_krnl_2) ──
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

               // ── Параметры (пишутся по JTAG до enable) ──
               //
               // ВАЖНО: смещения регистров в s_axi_control зависят от
               // ПОРЯДКА в этой сигнатуре. Новые параметры добавлять
               // только перед enable, иначе смещения в jtag_ctrl.tcl
               // молча разъедутся. Фактические смещения печатает
               // export_hls_ip.tcl — сверять после каждой правки.
               int serverIp,       // IP серверной половины, hex как в network_configure
               int serverPort,     // порт, куда подключается клиент
               int listenPort,     // порт, который слушает сервер (= serverPort)
               int msgBytes,       // размер сообщения, байты (свип 64…1500)
               // Триггер: запись ЛЮБОГО нового значения отправляет один
               // пакет. Фронт по изменению, поэтому сбрасывать в ноль не
               // надо — хост пишет инкремент. Эта же запись снимает
               // sampleReady, то есть триггер и подтверждение чтения —
               // одна транзакция.
               int triggerGo,

               // ── Счётчики (только чтение), для отладки ──
               ap_uint<32>& connAttempts,   // попыток открыть соединение
               ap_uint<32>& sentCount,      // отправлено запросов
               ap_uint<32>& recvCount,      // получено ответов
               ap_uint<32>& timeoutCount,   // ответ не пришёл за таймаут
               ap_uint<32>& echoRxCount,    // запросов ПРИНЯТО эхом (событие t2')
               ap_uint<32>& echoCount,      // сообщений отражено сервером (t1)

               // Состояние listen серверной половины. Без этого «замер не
               // удался» не отличить от «сервер вообще не слушает»:
               //   listenAttempts — сколько раз просили порт у стека;
               //   portState      — 0=ждём enable, 1=запрос отправлен,
               //                    2=порт открыт.
               // Растущий listenAttempts при portState=1 означает, что стек
               // не отвечает на запрос listen.
               ap_uint<32>& listenAttempts,
               ap_uint<32>& portState,

               // ── ТАЙМСТЕМПОВ ЗДЕСЬ БОЛЬШЕ НЕТ ──
               //
               // Были tsRequest/tsEchoIn/tsEchoOut/tsReply и sampleReady. Их
               // ставит HDL-обёртка по ap_vld счётчиков событий выше, потому что
               // передать в ядро единую шкалу времени не получается: HLS
               // размножает такой скаляр несимметрично (одной стадии провод,
               // другой FIFO с блокировкой). Подробный разбор — там, где раньше
               // была стадия epd_latch.
               //
               // Интервалы считает хост, как и прежде:
               //     RTT      = tsReply   - tsRequest
               //     NET_FWD  = tsEchoIn  - tsRequest
               //     ECHO     = tsEchoOut - tsEchoIn
               //     NET_REV  = tsReply   - tsEchoOut
               // Вычитание беззнаковое по модулю 2^32 — переполнение счётчика
               // (раз в 26 с на 165 МГц) измерение не портит.

               // enable — разрешение начать работу. Пока 0, ядро не трогает
               // ни один порт стека: до этого момента параметры в регистрах
               // могут быть не записаны.
               //
               // Раньше здесь стояло «ВСЕГДА последний»: при s_axilite
               // смещения регистров зависели от порядка аргументов, и сдвиг
               // enable молча ломал jtag_ctrl.tcl. Теперь адресная карта
               // задана руками в probe_control_s_axi.v, и порядок аргументов
               // на смещения не влияет вообще.
               // ── enable: ТРИ аргумента на одно значение ──
               //
               // Обёртка подаёт на все три один и тот же регистр (0x10), так что
               // снаружи это по-прежнему ОДИН enable: адресная карта и
               // jtag_ctrl.tcl не меняются.
               //
               // ЗАЧЕМ РАЗДЕЛЕНО. Пока это был один аргумент, его читали ТРИ
               // стадии (epd_client_connect, epd_client_traffic,
               // epd_server_listen), и HLS раздавал такой скаляр
               // НЕСИММЕТРИЧНО: часть читателей получала провод, часть —
               // FIFO-канал с блокировкой по empty_n. Стадия на канале
               // вставала, а через ap_ready/ap_continue DATAFLOW-региона
               // вставал весь регион.
               //
               // Это НЕ теория: ровно так сломался hls_dual_echo_krnl на плате
               // (dual_echo_core.v: половине a достался .enable(empty_176),
               // половине b — .enable_dout/.enable_empty_n/.enable_read через
               // FIFO p_c_U). Симптом: регистры живые, enable=1 читается
               // обратно, а вся телеметрия нули навсегда и ядро не исполняется.
               // csynth при этом был чистый — видно только в syn/verilog.
               //
               // Теперь у каждого аргумента ОДИН читатель. Тот же приём, что с
               // cycleCount: не давать HLS решать, как размножить скаляр.
               int enableConn,
               int enableTraffic,
               int enableListen
                      ) {

#pragma HLS INTERFACE axis port = s_axis_udp_rx_a
#pragma HLS INTERFACE axis port = m_axis_udp_tx_a
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta_a
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta_a
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port_a
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status_a
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection_a
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status_a
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection_a
#pragma HLS INTERFACE axis port = s_axis_tcp_notification_a
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg_a
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta_a
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data_a
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta_a
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data_a
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status_a

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

// ─────────────────────────────────────────────────────────────────────────────
// НИ ОДНОГО s_axilite — это обязательное условие ap_ctrl_none.
//
// Здесь было 18 штук #pragma HLS INTERFACE s_axilite. Они убраны, потому что
// UG1393 (Free-Running Kernels) запрещает их при ap_ctrl_none: "The kernel
// interface should not have any #pragma HLS interface s_axilite". HLS при этом
// не выдаёт ошибку, а молча защёлкивает входные скаляры ОДИН РАЗ в state2
// автомата верхнего модуля — сразу после снятия сброса, когда хост по JTAG ещё
// ничего не записал:
//
//     always @ (posedge ap_clk)
//         if ((1'b1 == ap_CS_fsm_state2))
//             enable_read_reg_862 <= enable;      // защёлка, а не провод
//
// Симптом: регистр читается обратно верно, а логика видит 0. Этот баг стоил
// нескольких сессий на плате в hls_dual_echo_krnl и был там исправлен ровно
// так же — переносом регистров в HDL.
//
// ДЛЯ ЭТОГО ЯДРА ЭТО КРИТИЧНЕЕ, ЧЕМ ДЛЯ dual_echo. Там все скаляры пишутся
// один раз до enable, и защёлка ломала только запуск. Здесь есть triggerGo,
// который по замыслу меняется МНОГОКРАТНО — по разу на каждый замер. С
// защёлкой второй замер не запустился бы НИКОГДА, а sampleReady не поднялся
// бы ни разу. Прежняя оговорка ниже («формальная гарантия stable для
// triggerGo нарушена... резервный план — убрать DATAFLOW») теперь неактуальна:
// обёртка решает эту задачу, не трогая DATAFLOW и не теряя II=1.
//
// Скаляры остаются обычными аргументами и становятся портами RTL — проводами,
// видимыми каждый такт. Регистры и адресную карту держит
// src/hdl/probe_control_s_axi.v, подключает src/hdl/*_wrapper.sv.
//
// ─────────────────────────────────────────────────────────────────────────────
// ap_ctrl_hs БЕЗ s_axilite: РЕГИСТРЫ ОСТАЮТСЯ В ОБЁРТКЕ, А ap_start ПРИХОДИТ
// ПОРТОМ.
//
// ЗАЧЕМ МЕНЯЛИ. При ap_ctrl_none регион не работал: барьер ap_sync_done -- И по
// ap_done ВСЕХ стадий (epd_core.v) -- требует, чтобы все были готовы В ОДИН
// такт. У стадий разный II, совпадения не наступает, и каждая встаёт после
// ПЕРВОГО прохода. На плате это давало
//
//     connAttempts=0 sent=0 echoRx=0 echoes=0 recv=0 timeouts=0
//     server listen: attempts=0 state=0(no-request)
//
// ВСЕ счётчики нули, включая timeouts -- то есть ядро не стартовало, а не
// «измерение не сошлось». На hls_dual_echo_krnl та же причина измерена
// тестбенчем на полном регионе: writes 1/1 при ap_ctrl_none против 10/10 после
// перехода на ap_ctrl_hs с auto_restart. Импульсный ap_start сбрасывает
// ap_sync_reg стадий, и барьер перестаёт держать.
//
// ПОЧЕМУ БЕЗ s_axilite. Регистры управления и все восемь таймстемпов уже живут в
// probe_control_s_axi.v, и там же логика auto_restart, скопированная из
// сгенерированного HLS (int_ap_start <= int_auto_restart на ap_ready). Дать ядру
// ещё и свой s_axilite значило бы два AXI-Lite на одном IP -- BD подключает
// ОДИН s_axi_control, пришлось бы писать адресный декодер. Вместо этого
// ap_start/ap_done/ap_ready/ap_idle становятся обычными портами RTL, и обёртка
// соединяет их со своими регистрами. Так устроен network_krnl: рукописный
// SystemVerilog с ap_ctrl_hs и внешними регистрами.
//
// ЧТО ЭТО НЕ ДАЁТ, в отличие от dual_echo: xhls_*_hw.h не генерируется, карта
// регистров остаётся рукописной (EPD_OFF_* в jtag_ctrl.tcl против localparam в
// probe_control_s_axi.v -- менять обе). Плата за то, что врезки, шкала времени и
// 51 проверка тестбенчей остаются нетронутыми.
// ─────────────────────────────────────────────────────────────────────────────
#pragma HLS INTERFACE ap_ctrl_hs port = return

// DATAFLOW, а не PIPELINE — как в hls_pingpong_krnl: половины и
// измеритель работают как независимые процессы.
//
// disable_start_propagation УБРАН: он означает «не раздавать ap_start стадиям»,
// и при ap_ctrl_hs ломает ровно то, ради чего затевалась правка -- импульс до
// стадий не доходит, ap_sync_reg не сбрасывается, барьер остаётся взведённым.
// Измерено на dual_echo: writes 1/1 с этим pragma, 10/10 без него.
#pragma HLS DATAFLOW

// ─────────────────────────────────────────────────────────────────────────────
// СКАЛЯРЫ — ЯВНО ПРОВОДА: ap_none register.
//
// Это прямое утверждение «порт есть провод, читай каждый такт». Ровно так
// объявлены скаляры в iperf_krnl — ядре, которое на этом железе работает
// (iperf_client.cpp:572-582):
//
//     #pragma HLS INTERFACE ap_none register port=runExperiment
//     #pragma HLS INTERFACE ap_none register port=timeInCycles
//
// ЗДЕСЬ РАНЬШЕ СТОЯЛ #pragma HLS stable, И ЭТО БЫЛО НЕВЕРНО. stable появился
// как попытка вылечить защёлку скаляров, НЕ убирая s_axilite. Он не помогал:
// csynth на hls_dual_echo_krnl показал, что pragma принимается молча, а
// защёлка на входе dataflow-региона остаётся. Защёлку убирает отсутствие
// s_axilite, то есть перенос регистров в HDL-обёртку (см. блок выше). После
// этого stable стал лечением уже вылеченной болезни — и тянул за собой
// оговорку про то, что для меняющихся скаляров его гарантия якобы нарушена.
//
// Оговорка была основана на неверном чтении UG1399. Требование stable — не
// «значение не меняется», а «читаемые ячейки не перезаписываются ДРУГИМ
// ПРОЦЕССОМ ИЛИ ВЫЗЫВАЮЩИМ КОНТЕКСТОМ пока регион исполняется». Это про то,
// кто пишет внутри дизайна, а не про то, меняется ли внешний провод. Отдельное
// предупреждение HLS 200-991 ("The stable scalar argument is written in a
// dataflow region") ловит именно ЗАПИСЬ stable-скаляра; мы их только читаем.
//
// Но правильный ответ проще: для «провода, читаемого каждый такт» есть штатный
// ap_none register, и никакой оговорки он не требует. У апстрима есть точный
// аналог нашей задачи — функция clock() (iperf_client.cpp:479): та же
// PIPELINE II=1 + INLINE off стадия внутри того же
// DATAFLOW disable_start_propagation, читающая скаляр timeInCycles каждый такт.
// А runExperiment — прямой аналог triggerGo: меняется во время работы, и на нём
// тоже ap_none register.
//
// ПОПЫТКА ПЕРЕДАТЬ ШКАЛУ ВРЕМЕНИ СКАЛЯРОМ БЫЛА И ПРОВАЛИЛАСЬ. Скаляр
// cycleCount, меняющийся каждый такт, HLS раздал двум стадиям несимметрично:
// одной проводом, другой FIFO-каналом с блокировкой. Разбор — там, где раньше
// была epd_latch. Мораль: ap_none register корректен для скаляра, который
// читает ОДНА стадия (так в iperf), но не гарантирует broadcast, когда
// читателей несколько. Поэтому время штампует обёртка.
//
// register: значение защёлкивается на входе порта, что даёт чистую границу для
// таймингового анализа и снимает длинный комбинационный путь от регистра в
// обёртке до логики стадии.
#pragma HLS INTERFACE ap_none register port = enableConn
#pragma HLS INTERFACE ap_none register port = enableTraffic
#pragma HLS INTERFACE ap_none register port = enableListen
#pragma HLS INTERFACE ap_none register port = serverIp
#pragma HLS INTERFACE ap_none register port = serverPort
#pragma HLS INTERFACE ap_none register port = listenPort
#pragma HLS INTERFACE ap_none register port = msgBytes
#pragma HLS INTERFACE ap_none register port = triggerGo
// ─────────────────────────────────────────────────────────────────────────────

     epd_core(s_axis_udp_rx_a, m_axis_udp_tx_a,
              s_axis_udp_rx_meta_a, m_axis_udp_tx_meta_a,
              m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a,
              m_axis_tcp_open_connection_a, s_axis_tcp_open_status_a,
              m_axis_tcp_close_connection_a,
              s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
              s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a,
              m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
              s_axis_tcp_tx_status_a,

              s_axis_udp_rx_b, m_axis_udp_tx_b,
              s_axis_udp_rx_meta_b, m_axis_udp_tx_meta_b,
              m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b,
              m_axis_tcp_open_connection_b, s_axis_tcp_open_status_b,
              m_axis_tcp_close_connection_b,
              s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
              s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b,
              m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
              s_axis_tcp_tx_status_b,

              enableConn, enableTraffic, enableListen,
              serverIp, serverPort, listenPort,
              msgBytes, triggerGo,

              connAttempts, sentCount, recvCount, timeoutCount,
              echoRxCount, echoCount,
              listenAttempts, portState);
}
}
