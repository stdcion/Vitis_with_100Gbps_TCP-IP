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
//   * шкала времени ОДНА на всё ядро: 32-битный счётчик живёт в HDL-обёртке и
//     приходит в обе половины проводом cycleCount. Раньше каждая стадия держала
//     свой счётчик, и разности между стадиями были осмысленны лишь пока HLS
//     давал обеим II=1 — то есть по свойству расписания, а не кода. Разбор,
//     что именно ломалось (NET_FWD завышался ровно настолько, насколько
//     занижался NET_REV, при верных RTT/ECHO и сходящемся балансе), — в шапке
//     cycle_counter в src/hdl/hls_echo_probe_dual_krnl_wrapper.sv;
//   * таймстемпы передаются измерителю потоками tsFifo*;
//   * sessionID от connect к traffic — тоже потоком.
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
                        ap_uint<32> cycleCount,
                        hls::stream<ap_uint<16> >& sessionFifo,
                        // таймстемпы наружу: пара (t1', t2) на каждый
                        // завершённый круг
                        hls::stream<ap_uint<32> >& tsRequestFifo,   // t1'
                        hls::stream<ap_uint<32> >& tsReplyFifo,     // t2
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
     static ap_uint<32> tRequest = 0;

     // Шкала времени приходит ПРОВОДОМ из HDL-обёртки (cycle_counter в
     // hls_echo_probe_dual_krnl_wrapper.sv) и та же самая, что у epd_server_echo.
     //
     // Раньше здесь был свой static cyc с комментарием «шкалы синхронны, потому
     // что оба счётчика тикают от ap_clk и стартуют с одного сброса». При
     // Final II = 1 это верно, но это свойство РАСПИСАНИЯ, а не кода: при II=2
     // счётчики расходятся линейно, и тогда NET_FWD завышается ровно настолько,
     // насколько NET_REV занижается (t2'−t1' и t2−t1 вычитают точки РАЗНЫХ
     // половин). RTT и ECHO при этом остаются верными, а баланс сходится всегда,
     // поэтому ни одна проверка на хосте такую ошибку не поймала бы. Подробный
     // разбор — в шапке счётчика в обёртке.
     const ap_uint<32> cyc = cycleCount;

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
          // Пишем в payload номер отправки — не для сопоставления
          // (в тракте один пакет), а чтобы эхо было отличимо от мусора
          // при отладке в ILA.
          if (txWordIdx == 0)
               word.data(31, 0) = sent;

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
               // ТОЧКА t1': последнее слово запроса отдано стеку.
               // Берём последнее, а не первое, чтобы измерение не
               // зависело от размера сообщения на стороне отправки.
               tRequest = cyc;
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
                    // ТОЧКА t2: последнее слово ответа получено.
                    // Симметрично t1' — тоже последнее слово, поэтому
                    // RTT не зависит от размера сообщения.
                    //
                    // Пара таймстемпов уходит измерителю вместе: так он
                    // не может рассинхронизироваться и посчитать t2
                    // одного пакета с t1' другого.
                    tsRequestFifo.write(tRequest);
                    tsReplyFifo.write(cyc);
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
void epd_server_echo(ap_uint<32> cycleCount,
                     hls::stream<ap_uint<32> >& tsEchoInFifo,   // t2'
                     hls::stream<ap_uint<32> >& tsEchoOutFifo,  // t1
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
     static ap_uint<32> tEchoIn = 0;

     // Та же шкала, что у epd_client_traffic — провод из обёртки. См. пояснение
     // там и в шапке счётчика в hls_echo_probe_dual_krnl_wrapper.sv.
     const ap_uint<32> cyc = cycleCount;

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
                    // ТОЧКА t2': последнее слово запроса получено эхом.
                    // Симметрично t1' на клиенте — оба по последнему слову.
                    tEchoIn = cyc;
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
               tsEchoInFifo.write(tEchoIn);
               tsEchoOutFifo.write(cyc);
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
 * Отдаёт хосту СЫРЫЕ значения четырёх точек, а не посчитанные интервалы.
 *
 * ПОЧЕМУ СЫРЫЕ, А НЕ min/max/sum:
 *
 *   1. Гибкость. Из четвёрки на PC считается любой интервал, в том числе
 *      тот, о котором мы сейчас не думаем (скажем, t2'-t1 — эхо плюс
 *      обратная сеть). Зашитые в логику агрегаты пришлось бы менять
 *      пересборкой, а это час.
 *
 *   2. Отладка. Если бы min оказался абсурдным (3 такта на весь круг),
 *      по агрегату не понять, что сломалось. По сырым t1'=1000, t2'=1200,
 *      t1=1205, t2=1400 видно сразу.
 *
 *   3. Место и тайминг. Четыре компаратора min/max плюс четыре
 *      64-битных аккумулятора — это площадь и лишние длинные пути при
 *      WNS +0.011 нс. Четыре регистра-защёлки почти бесплатны.
 *
 *   4. Главное: 64-БИТНЫЕ СУММЫ НЕЛЬЗЯ БЫЛО БЫ ЧИТАТЬ КОРРЕКТНО.
 *      s_axi_control отдаёт 32 бита за транзакцию, значит 64-битный
 *      регистр читается двумя обращениями, а между ними ядро успевает
 *      обновить значение: получилось бы младшее слово от одного замера,
 *      старшее от другого. При переносе через границу 2^32 — мусор,
 *      редко и невоспроизводимо. Все регистры здесь 32-битные и
 *      читаются одной транзакцией.
 *
 * СОГЛАСОВАННОСТЬ. Гонки чтения нет по построению режима: пока хост не
 * записал triggerGo, новый пакет не отправится, значит четвёрка не
 * изменится. Поэтому не нужны ни номер набора, ни теневые регистры —
 * достаточно флага sampleReady «результат готов».
 *
 * sampleReady снимается тем же фронтом triggerGo, который пускает
 * следующий пакет: триггер и подтверждение чтения — одна транзакция.
 *
 * ПОЧЕМУ СБРОС ЗАПИСЬЮ, А НЕ ЧТЕНИЕМ: s_axilite не даёт ядру узнать,
 * что регистр прочитали — читающая транзакция для логики невидима.
 * Поэтому «сбрасывается при чтении» в HLS не реализуемо, и сброс
 * привязан к записи triggerGo.
 *
 * Защёлкиваем ВСЕ ЧЕТЫРЕ в момент t2 (круг завершён) — тогда они по
 * построению принадлежат одному пакету.
 */
void epd_latch(int triggerGo,
               hls::stream<ap_uint<32> >& tsRequestFifo,  // t1'
               hls::stream<ap_uint<32> >& tsReplyFifo,    // t2
               hls::stream<ap_uint<32> >& tsEchoInFifo,   // t2'
               hls::stream<ap_uint<32> >& tsEchoOutFifo,  // t1
               ap_uint<32>& tsRequestOut,   // t1'
               ap_uint<32>& tsEchoInOut,    // t2'
               ap_uint<32>& tsEchoOutOut,   // t1
               ap_uint<32>& tsReplyOut,     // t2
               ap_uint<32>& sampleReady)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool ready = false;
#pragma HLS RESET variable=ready
     static int prevGo = 0;
#pragma HLS RESET variable=prevGo
     static ap_uint<32> t1p = 0, t2p = 0, t1 = 0, t2 = 0;

     // Новый триггер снимает флаг: результат предыдущего замера хост уже
     // прочитал, иначе он бы не дёрнул следующий.
     if (triggerGo != prevGo)
     {
          prevGo = triggerGo;
          ready = false;
     }

     // Ждём все четыре значения одного круга. Клиент пишет пару
     // (t1', t2) по приёму ответа, эхо — пару (t2', t1) по отправке.
     // Эхо физически успевает раньше, но полагаться на это нельзя:
     // проверяем наличие всех четырёх.
     //
     // Потери не сбивают соответствие: пара пишется только на успешном
     // круге. Если эхо не сработало, клиент уйдёт по таймауту и в его
     // потоки ничего не запишет.
     bool haveAll = !tsRequestFifo.empty() && !tsReplyFifo.empty()
                 && !tsEchoInFifo.empty()  && !tsEchoOutFifo.empty();

     if (haveAll)
     {
          t1p = tsRequestFifo.read();
          t2  = tsReplyFifo.read();
          t2p = tsEchoInFifo.read();
          t1  = tsEchoOutFifo.read();
          ready = true;
     }

     tsRequestOut = t1p;
     tsEchoInOut  = t2p;
     tsEchoOutOut = t1;
     tsReplyOut   = t2;
     sampleReady  = ready ? (ap_uint<32>)1 : (ap_uint<32>)0;
}

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
     int enable, int serverIp, int serverPort, int listenPort,
     int msgBytes, int triggerGo,
     // единая шкала времени для обеих половин (провод из обёртки)
     ap_uint<32> cycleCount,
     // счётчики
     ap_uint<32>& connAttempts, ap_uint<32>& sentCount,
     ap_uint<32>& recvCount, ap_uint<32>& timeoutCount,
     ap_uint<32>& echoCount,
     ap_uint<32>& listenAttempts, ap_uint<32>& portState,
     // сырые таймстемпы последнего завершённого круга + номер набора
     ap_uint<32>& tsRequest, ap_uint<32>& tsEchoIn,
     ap_uint<32>& tsEchoOut, ap_uint<32>& tsReply,
     ap_uint<32>& sampleReady)
{
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

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
     // внутри дизайна их не пишет никто, включая cycleCount: его источник —
     // счётчик в HDL-обёртке, вне ядра. Предупреждение HLS 200-991 ловит именно
     // запись stable-скаляра, и в наших логах его нет.
     //
     // То, что cycleCount меняется каждый такт, ограничением не является — см.
     // clock() в iperf_client.cpp:479, где точно так же читается timeInCycles.
#pragma HLS stable variable = enable
#pragma HLS stable variable = serverIp
#pragma HLS stable variable = serverPort
#pragma HLS stable variable = listenPort
#pragma HLS stable variable = msgBytes
#pragma HLS stable variable = triggerGo
#pragma HLS stable variable = cycleCount

     // ── каналы между стадиями ──
     // Глубина 2 достаточна: в тракте один пакет, значит в каждом канале
     // не бывает больше одной записи одновременно. Двойка — запас на
     // такт рассинхрона между стадиями.
     static hls::stream<ap_uint<16> > sessionFifo("sessionFifo");
     #pragma HLS STREAM variable=sessionFifo depth=2

     static hls::stream<ap_uint<32> > tsRequestFifo("tsRequestFifo");
     #pragma HLS STREAM variable=tsRequestFifo depth=2
     static hls::stream<ap_uint<32> > tsReplyFifo("tsReplyFifo");
     #pragma HLS STREAM variable=tsReplyFifo depth=2
     static hls::stream<ap_uint<32> > tsEchoInFifo("tsEchoInFifo");
     #pragma HLS STREAM variable=tsEchoInFifo depth=2
     static hls::stream<ap_uint<32> > tsEchoOutFifo("tsEchoOutFifo");
     #pragma HLS STREAM variable=tsEchoOutFifo depth=2

     // --- клиент (порт 0) ---
     epd_client_connect(enable, serverIp, serverPort, connAttempts,
                        sessionFifo,
                        m_axis_tcp_open_connection_a, s_axis_tcp_open_status_a);

     epd_client_traffic(enable, msgBytes, triggerGo, cycleCount,
                        sessionFifo,
                        tsRequestFifo, tsReplyFifo,
                        sentCount, recvCount, timeoutCount,
                        m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
                        s_axis_tcp_tx_status_a,
                        s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                        s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a);

     // --- сервер-эхо (порт 1) ---
     epd_server_listen(enable, listenPort, listenAttempts, portState,
                       m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b);

     // ТОТ ЖЕ cycleCount, что у клиента — в этом весь смысл правки: NET_FWD и
     // NET_REV вычитают точки разных половин, поэтому шкала обязана быть одна.
     epd_server_echo(cycleCount, tsEchoInFifo, tsEchoOutFifo, echoCount,
                     s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                     s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b,
                     m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
                     s_axis_tcp_tx_status_b);

     // --- защёлка сырых таймстемпов ---
     epd_latch(triggerGo, tsRequestFifo, tsReplyFifo, tsEchoInFifo, tsEchoOutFifo,
               tsRequest, tsEchoIn, tsEchoOut, tsReply, sampleReady);

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
               ap_uint<32>& echoCount,      // сообщений отражено сервером

               // Состояние listen серверной половины. Без этого «замер не
               // удался» не отличить от «сервер вообще не слушает»:
               //   listenAttempts — сколько раз просили порт у стека;
               //   portState      — 0=ждём enable, 1=запрос отправлен,
               //                    2=порт открыт.
               // Растущий listenAttempts при portState=1 означает, что стек
               // не отвечает на запрос listen.
               ap_uint<32>& listenAttempts,
               ap_uint<32>& portState,

               // ── СЫРЫЕ таймстемпы последнего завершённого круга ──
               //
               // Такты ap_clk (6.06 нс на 165 МГц). Все четыре
               // защёлкиваются вместе в момент t2, поэтому принадлежат
               // одному пакету. Интервалы считает хост:
               //     RTT      = tsReply   - tsRequest
               //     NET_FWD  = tsEchoIn  - tsRequest
               //     ECHO     = tsEchoOut - tsEchoIn
               //     NET_REV  = tsReply   - tsEchoOut
               // Вычитание беззнаковое по модулю 2^32 — переполнение
               // счётчика (раз в 26 с на 165 МГц) измерение не портит.
               ap_uint<32>& tsRequest,      // t1'
               ap_uint<32>& tsEchoIn,       // t2'
               ap_uint<32>& tsEchoOut,      // t1
               ap_uint<32>& tsReply,        // t2

               // Флаг готовности: 1 = четвёрка выше принадлежит
               // завершённому кругу и ещё не запрашивалась. Снимается
               // записью triggerGo (см. пояснение у epd_latch).
               ap_uint<32>& sampleReady,

               // enable — разрешение начать работу. Пока 0, ядро не трогает
               // ни один порт стека: до этого момента параметры в регистрах
               // могут быть не записаны.
               //
               // Раньше здесь стояло «ВСЕГДА последний»: при s_axilite
               // смещения регистров зависели от порядка аргументов, и сдвиг
               // enable молча ломал jtag_ctrl.tcl. Теперь адресная карта
               // задана руками в probe_control_s_axi.v, и порядок аргументов
               // на смещения не влияет вообще.
               int enable,

               // Единая шкала времени для обеих половин — провод из счётчика
               // в HDL-обёртке. НЕ регистр управления: хост его не пишет и не
               // читает, в адресной карте его нет.
               //
               // Почему счётчик снаружи, а не два static внутри стадий:
               // NET_FWD = t2'−t1' и NET_REV = t2−t1 вычитают точки РАЗНЫХ
               // половин, поэтому шкала обязана быть физически одна. Раздельные
               // счётчики совпадают лишь пока HLS даёт обеим стадиям II=1 —
               // это свойство расписания, а не кода. Подробный разбор с
               // разложением, что именно ломается, — в шапке cycle_counter в
               // hls_echo_probe_dual_krnl_wrapper.sv.
               ap_uint<32> cycleCount
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
// Блочный протокол ap_ctrl_hs, который ждёт от ядра XRT/BD, реализует обёртка —
// ровно как iperf_krnl.xml заявляет ap_ctrl_hs при ap_ctrl_none у самой
// HLS-функции.
// ─────────────────────────────────────────────────────────────────────────────
#pragma HLS INTERFACE ap_ctrl_none port = return

// DATAFLOW, а не PIPELINE — как в hls_pingpong_krnl: половины и
// измеритель работают как независимые процессы.
#pragma HLS DATAFLOW disable_start_propagation

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
// Так что меняющийся каждый такт cycleCount — не трейдофф и не костыль, а
// документированная штатная конструкция.
//
// register: значение защёлкивается на входе порта, что даёт чистую границу для
// таймингового анализа и снимает длинный комбинационный путь от регистра в
// обёртке до логики стадии.
#pragma HLS INTERFACE ap_none register port = enable
#pragma HLS INTERFACE ap_none register port = serverIp
#pragma HLS INTERFACE ap_none register port = serverPort
#pragma HLS INTERFACE ap_none register port = listenPort
#pragma HLS INTERFACE ap_none register port = msgBytes
#pragma HLS INTERFACE ap_none register port = triggerGo
#pragma HLS INTERFACE ap_none register port = cycleCount
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

              enable, serverIp, serverPort, listenPort,
              msgBytes, triggerGo, cycleCount,

              connAttempts, sentCount, recvCount, timeoutCount, echoCount,
              listenAttempts, portState,
              tsRequest, tsEchoIn, tsEchoOut, tsReply, sampleReady);
}
}
