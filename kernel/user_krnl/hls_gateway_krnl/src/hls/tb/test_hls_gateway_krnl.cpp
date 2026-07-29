/************************************************
C-симуляция для hls_gateway_krnl.

Тестбенч подменяет собой TCP/IP-стек: он подаёт ядру уведомления и
данные так, как это делал бы стек, и проверяет, что ядро отправляет
в ответ.

Ядро объявлено с ap_ctrl_none и работает вечно, поэтому в csim его
нельзя вызвать «до завершения» — вместо этого тестбенч вызывает его
в цикле по одному такту (kernel_tick) и между тактами
подкладывает/забирает данные.

ОТЛИЧИЕ ОТ ПРЕДЫДУЩЕЙ ВЕРСИИ. Раньше тестбенч сам отвечал tx_status
сразу после чтения tx_meta, и всегда успехом. Из-за этого ветки
error==1 / error==2 и состояние DISCARD были мёртвым кодом, а
backpressure не возникал никогда (FIFO глубиной 1024 не заполнялись
глубже 2 слов).

Теперь стек — независимый процесс stack_tick(), который вызывается
на каждом такте вместе с ядром и ведёт себя настраиваемо:
  - задержка ответа tx_status (statusDelay),
  - произвольный код ошибки на N-й транзакции,
  - опциональная приостановка выдачи (stall) для проверки
    заполнения FIFO и корректности backpressure.

ГРАНИЦЫ ПРИМЕНИМОСТИ. Тест [10] проверяет, что при остановленном
получателе данные не теряются и не склеиваются. Но он НЕ доказывает
отсутствие дедлока по заполнению FIFO: в C-симуляции hls::stream не
имеет ограниченной глубины, блокирующая запись никогда не блокируется,
и прагмы depth игнорируются. Проверки full() перед записью (см.
gw_rx_handshake) обязательны для железа, но их эффект виден только в
co-simulation (cosim_design) или на плате. Мутационная проверка это
подтвердила: снятие guard'ов в csim не роняет ни один тест.

Сценарии:
  1. Открытие listen-порта и подключение к upstream-серверу
  2. Uplink:   клиент -> сервер
  3. Downlink: сервер -> клиент
  4. Неполное слово (length не кратна 64) — проверка keep
  5. Реконнект клиента (новый sessionID)
  6. Обрыв upstream и автоматическое переподключение
  7. tx_status error==2 (нет места) — повтор tx_meta
  8. tx_status error==1 (обрыв) — сброс порции, DISCARD
  9. Оба направления одновременно — round-robin и запрет
     переключения в середине транзакции
 10. Backpressure: много пакетов подряд без немедленного слива
 11. Лишняя клиентская сессия — закрывается через close_connection
 12. error==2 с постоянно закрытым окном — второе направление не
     блокируется, а повтор идёт с паузой (регрессия на head-of-line
     blocking и busy-wait)

Сборка (на машине с Vitis HLS):
    vitis_hls -f run_csim.tcl
************************************************/
#include "ap_axi_sdata.h"
#include "ap_int.h"
#include "hls_stream.h"

#include <iostream>
#include <vector>
#include <deque>
#include <string>

typedef ap_axiu<512, 0, 0, 0> pkt512;
typedef ap_axiu<256, 0, 0, 0> pkt256;
typedef ap_axiu<128, 0, 0, 0> pkt128;
typedef ap_axiu<64, 0, 0, 0>  pkt64;
typedef ap_axiu<32, 0, 0, 0>  pkt32;
typedef ap_axiu<16, 0, 0, 0>  pkt16;
typedef ap_axiu<8, 0, 0, 0>   pkt8;

// GW_COSIM_TOP — сборка против обёртки без скалярных портов.
// Cosim не поддерживает ap_ctrl_none-дизайн со скалярами:
//   [COSIM 212-345] Cosim only supports ... (3) designs with array
//   streaming or hls_stream or AXI4 stream ports
// Значения параметров в обёртке зашиты и должны совпадать с
// константами ниже (LISTEN_PORT / SERVER_IP / SERVER_PORT /
// RECONNECT_DELAY).
#ifdef GW_COSIM_TOP
extern "C" void hls_gateway_krnl_cosim(
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
     hls::stream<pkt64>& s_axis_tcp_tx_status);
#endif

// Прототип тестируемого ядра
extern "C" void hls_gateway_krnl(
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
     int listenPort,
     int serverIpAddress,
     int serverPort,
     int reconnectDelay);

// ---------------------------------------------------------------
// Параметры теста
// ---------------------------------------------------------------
static const int LISTEN_PORT   = 5001;
static const int SERVER_IP     = 0xC0A80114;  // 192.168.1.20
static const int SERVER_PORT   = 8080;

// Пауза реконнекта — теперь обычный аргумент, а не -D.
// Малое значение, чтобы симуляция не ждала 250e6 тактов.
static const int RECONNECT_DELAY = 100;

#ifdef GW_COSIM_TOP
// Обёртка hls_gateway_krnl_cosim зашивает эти же значения внутри себя
// (скалярных портов у неё нет). Если константы разойдутся, cosim будет
// падать непонятным образом — поэтому проверяем на этапе компиляции.
// Значения дублируются намеренно: заголовка, общего с ядром, здесь нет.
static_assert(LISTEN_PORT      == 5001,       "разошлось с GW_COSIM_LISTEN_PORT");
static_assert(SERVER_IP        == 0xC0A80114, "разошлось с GW_COSIM_SERVER_IP");
static_assert(SERVER_PORT      == 8080,       "разошлось с GW_COSIM_SERVER_PORT");
static_assert(RECONNECT_DELAY  == 100,        "разошлось с GW_COSIM_RECONNECT_DELAY");
#endif

static const ap_uint<16> SESSION_SERVER  = 7;   // выдаём при open
static const ap_uint<16> SESSION_CLIENT  = 3;   // первый клиент
static const ap_uint<16> SESSION_CLIENT2 = 9;   // после реконнекта
static const ap_uint<16> SESSION_STRAY   = 11;  // лишний клиент

// ---------------------------------------------------------------
// Потоки между тестбенчем и ядром
// ---------------------------------------------------------------
static hls::stream<pkt512> s_axis_udp_rx;
static hls::stream<pkt512> m_axis_udp_tx;
static hls::stream<pkt256> s_axis_udp_rx_meta;
static hls::stream<pkt256> m_axis_udp_tx_meta;
static hls::stream<pkt16>  m_axis_tcp_listen_port;
static hls::stream<pkt8>   s_axis_tcp_port_status;
static hls::stream<pkt64>  m_axis_tcp_open_connection;
static hls::stream<pkt128> s_axis_tcp_open_status;
static hls::stream<pkt16>  m_axis_tcp_close_connection;
static hls::stream<pkt128> s_axis_tcp_notification;
static hls::stream<pkt32>  m_axis_tcp_read_pkg;
static hls::stream<pkt16>  s_axis_tcp_rx_meta;
static hls::stream<pkt512> s_axis_tcp_rx_data;
static hls::stream<pkt32>  m_axis_tcp_tx_meta;
static hls::stream<pkt512> m_axis_tcp_tx_data;
static hls::stream<pkt64>  s_axis_tcp_tx_status;

static int failures = 0;

static void check(bool cond, const std::string& what)
{
     if (cond)
     {
          std::cout << "  [ OK ] " << what << std::endl;
     }
     else
     {
          std::cout << "  [FAIL] " << what << std::endl;
          failures++;
     }
}

// ---------------------------------------------------------------
// Модель TCP-стека: независимый процесс, тикает вместе с ядром
// ---------------------------------------------------------------

// Захваченная стеком транзакция (meta + собранные слова)
struct TxCapture
{
     ap_uint<16> sessionID;
     ap_uint<16> length;
     int         words;
     ap_uint<64> lastKeep;
};

static std::deque<TxCapture>  captured;      // завершённые транзакции
static std::deque<ap_uint<16> > closedByGw;  // сессии, закрытые ядром

// Настройки поведения стека
static int  stk_statusDelay   = 0;      // тактов между meta и status
static int  stk_forceErrorOn  = -1;     // номер транзакции с ошибкой
static int  stk_forceErrorCode= 0;      // 1 = обрыв, 2 = нет места
static bool stk_stallData     = false;  // не принимать tx_data

// Сессия, которой стек ПОСТОЯННО отвечает error==2 (нет места), т.е.
// получатель с закрытым окном приёма. Остальные сессии обслуживаются
// нормально. Нужно для теста [12]: одно застрявшее направление не
// должно блокировать второе. 0 = выключено.
static ap_uint<16> stk_refuseSession = 0;

// Внутреннее состояние стека
static int         stk_txCount     = 0;   // сколько meta принято всего
static int         stk_strayWords  = 0;   // слова вне разрешённой транзакции
static bool        stk_haveMeta    = false;
static ap_uint<16> stk_metaSession = 0;
static ap_uint<16> stk_metaLength  = 0;
static int         stk_delayLeft   = 0;
static bool         stk_awaitData  = false;
static TxCapture   stk_cur;

static void stack_reset_cfg()
{
     stk_statusDelay    = 0;
     stk_forceErrorOn   = -1;
     stk_forceErrorCode = 0;
     stk_stallData      = false;
     stk_refuseSession  = 0;
}

// Один такт работы модели стека
static void stack_tick()
{
     // 1. Приём tx_meta
     if (!stk_haveMeta && !stk_awaitData && !m_axis_tcp_tx_meta.empty())
     {
          pkt32 meta = m_axis_tcp_tx_meta.read();
          stk_metaSession = meta.data(15, 0);
          stk_metaLength  = meta.data(31, 16);
          stk_haveMeta    = true;
          stk_delayLeft   = stk_statusDelay;
          stk_txCount++;
     }

     // 2. Ответ tx_status после задержки
     if (stk_haveMeta)
     {
          if (stk_delayLeft > 0)
          {
               stk_delayLeft--;
          }
          else
          {
               int err = 0;
               if (stk_forceErrorOn == stk_txCount)
                    err = stk_forceErrorCode;
               // Получатель с наглухо закрытым окном приёма
               if (stk_refuseSession != 0
                   && stk_metaSession == stk_refuseSession)
                    err = 2;

               pkt64 s;
               s.data = 0;
               s.data(15, 0)  = stk_metaSession;
               s.data(31, 16) = stk_metaLength;
               s.data(61, 32) = 60000;
               s.data(63, 62) = err;
               s_axis_tcp_tx_status.write(s);

               stk_haveMeta = false;

               if (err == 0)
               {
                    // ждём данные этой транзакции
                    stk_awaitData      = true;
                    stk_cur.sessionID  = stk_metaSession;
                    stk_cur.length     = stk_metaLength;
                    stk_cur.words      = 0;
                    stk_cur.lastKeep   = 0;
               }
               // err==2: ядро должно повторить tx_meta (данные не идут)
               // err==1: ядро сбрасывает порцию (данные не идут)
          }
     }

     // 3. Приём tx_data
     if (stk_awaitData && !stk_stallData && !m_axis_tcp_tx_data.empty())
     {
          pkt512 w = m_axis_tcp_tx_data.read();
          stk_cur.words++;
          stk_cur.lastKeep = w.keep;
          if (w.last)
          {
               captured.push_back(stk_cur);
               stk_awaitData = false;
          }
     }
     // Слова, пришедшие когда транзакция НЕ разрешена (после error==1
     // или error==2, где данные идти не должны) — это нарушение
     // протокола. Раньше они просто оставались в потоке и тест их не
     // видел, из-за чего мутация DISCARD проходила незамеченной.
     else if (!stk_awaitData && !stk_stallData && !m_axis_tcp_tx_data.empty())
     {
          m_axis_tcp_tx_data.read();
          stk_strayWords++;
     }

     // 4. Забираем close_connection
     if (!m_axis_tcp_close_connection.empty())
     {
          pkt16 c = m_axis_tcp_close_connection.read();
          closedByGw.push_back(c.data(15, 0));
     }
}

// Один такт: ядро + стек
static void tick()
{
#ifdef GW_COSIM_TOP
     // Обёртка без скалярных портов — параметры зашиты внутри неё
     hls_gateway_krnl_cosim(s_axis_udp_rx, m_axis_udp_tx,
                            s_axis_udp_rx_meta, m_axis_udp_tx_meta,
                            m_axis_tcp_listen_port, s_axis_tcp_port_status,
                            m_axis_tcp_open_connection, s_axis_tcp_open_status,
                            m_axis_tcp_close_connection,
                            s_axis_tcp_notification, m_axis_tcp_read_pkg,
                            s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                            m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                            s_axis_tcp_tx_status);
#else
     hls_gateway_krnl(s_axis_udp_rx, m_axis_udp_tx,
                      s_axis_udp_rx_meta, m_axis_udp_tx_meta,
                      m_axis_tcp_listen_port, s_axis_tcp_port_status,
                      m_axis_tcp_open_connection, s_axis_tcp_open_status,
                      m_axis_tcp_close_connection,
                      s_axis_tcp_notification, m_axis_tcp_read_pkg,
                      s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                      m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                      s_axis_tcp_tx_status,
                      LISTEN_PORT, SERVER_IP, SERVER_PORT,
                      RECONNECT_DELAY);
#endif
     stack_tick();
}

static void run(int cycles)
{
     for (int i = 0; i < cycles; i++) tick();
}

// Ждём появления N завершённых транзакций
static bool wait_captured(size_t n, int limit)
{
     for (int i = 0; i < limit && captured.size() < n; i++) tick();
     return captured.size() >= n;
}

static bool pop_captured(TxCapture& out, int limit = 400)
{
     if (!wait_captured(1, limit)) return false;
     out = captured.front();
     captured.pop_front();
     return true;
}

// ---------------------------------------------------------------
// Хелперы: стек -> ядро
// ---------------------------------------------------------------

// Стек сообщает: в сессии sessionID пришло length байт
static void push_notification(ap_uint<16> sessionID, ap_uint<16> length)
{
     pkt128 n;
     n.data = 0;
     n.data(15, 0)  = sessionID;
     n.data(31, 16) = length;
     n.data(63, 32) = 0x0A0A0A0A;
     n.data(79, 64) = 1234;
     n.data(80, 80) = 0;
     s_axis_tcp_notification.write(n);
}

// Стек сообщает: сессия закрыта
static void push_closed(ap_uint<16> sessionID)
{
     pkt128 n;
     n.data = 0;
     n.data(15, 0)  = sessionID;
     n.data(31, 16) = 0;
     n.data(80, 80) = 1;
     s_axis_tcp_notification.write(n);
}

// Стек отдаёт тело пакета в ответ на read request
static void push_rx_payload(ap_uint<16> sessionID, int numWords, ap_uint<32> seed)
{
     pkt16 meta;
     meta.data = 0;
     meta.data(15, 0) = sessionID;
     s_axis_tcp_rx_meta.write(meta);

     for (int i = 0; i < numWords; i++)
     {
          pkt512 w;
          w.data = 0;
          for (int k = 0; k < 16; k++)
               w.data(k * 32 + 31, k * 32) = seed + i;
          w.keep = ~ap_uint<64>(0);
          w.last = (i == numWords - 1);
          s_axis_tcp_rx_data.write(w);
     }
}

// Ответ стека на запрос открыть соединение
static void push_open_status(ap_uint<16> sessionID, bool success)
{
     pkt128 st;
     st.data = 0;
     st.data(15, 0)  = sessionID;
     st.data(16, 16) = success ? 1 : 0;
     s_axis_tcp_open_status.write(st);
}

// Полный цикл «пришли данные»: уведомление + read request + тело
static void deliver(ap_uint<16> sessionID, ap_uint<16> length, int numWords,
                    ap_uint<32> seed)
{
     push_notification(sessionID, length);
     run(5);
     if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
     push_rx_payload(sessionID, numWords, seed);
}

static int count_keep(ap_uint<64> keep)
{
     int n = 0;
     for (int i = 0; i < 64; i++) if (keep[i]) n++;
     return n;
}

// ---------------------------------------------------------------
int main()
{
     std::cout << "=== hls_gateway_krnl C-simulation ===" << std::endl;

     TxCapture tx;
     stack_reset_cfg();

     // -----------------------------------------------------------
     std::cout << "\n[1] Инициализация: listen-порт и upstream" << std::endl;

     run(5);

     bool gotListen = !m_axis_tcp_listen_port.empty();
     check(gotListen, "ядро запросило listen-порт");
     if (gotListen)
     {
          pkt16 lp = m_axis_tcp_listen_port.read();
          check(lp.data(15, 0) == LISTEN_PORT, "listen-порт равен заданному");
     }

     bool gotOpen = !m_axis_tcp_open_connection.empty();
     check(gotOpen, "ядро запросило соединение с upstream");
     if (gotOpen)
     {
          pkt64 oc = m_axis_tcp_open_connection.read();
          check(oc.data(31, 0) == (ap_uint<32>)SERVER_IP, "IP сервера верный");
          check(oc.data(47, 32) == SERVER_PORT, "порт сервера верный");
     }

     pkt8 ps; ps.data = 1;
     s_axis_tcp_port_status.write(ps);
     push_open_status(SESSION_SERVER, true);
     run(10);

     // -----------------------------------------------------------
     std::cout << "\n[2] Uplink: клиент -> сервер" << std::endl;

     push_notification(SESSION_CLIENT, 128);   // 2 полных слова
     run(5);

     bool gotRead = !m_axis_tcp_read_pkg.empty();
     check(gotRead, "ядро выставило read request");
     if (gotRead)
     {
          pkt32 rr = m_axis_tcp_read_pkg.read();
          check(rr.data(15, 0) == SESSION_CLIENT, "read request для сессии клиента");
          check(rr.data(31, 16) == 128, "запрошенная длина верна");
     }

     push_rx_payload(SESSION_CLIENT, 2, 0xAA00);

     if (pop_captured(tx))
     {
          check(tx.sessionID == SESSION_SERVER, "данные ушли в сессию СЕРВЕРА");
          check(tx.length == 128, "длина сохранена");
          check(tx.words == 2, "передано 2 слова");
     }
     else check(false, "uplink-транзакция не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[3] Downlink: сервер -> клиент" << std::endl;

     deliver(SESSION_SERVER, 64, 1, 0xBB00);

     if (pop_captured(tx))
     {
          check(tx.sessionID == SESSION_CLIENT, "данные ушли в сессию КЛИЕНТА");
          check(tx.length == 64, "длина сохранена");
          check(tx.words == 1, "передано 1 слово");
     }
     else check(false, "downlink-транзакция не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[4] Неполное слово: length = 100 байт" << std::endl;

     deliver(SESSION_CLIENT, 100, 2, 0xCC00);   // 1 полное + 36 байт

     if (pop_captured(tx))
     {
          check(tx.length == 100, "длина 100 сохранена");
          check(tx.words == 2, "передано 2 слова");
          check(count_keep(tx.lastKeep) == 36, "keep последнего слова = 36 байт");
     }
     else check(false, "транзакция с неполным словом не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[5] Реконнект клиента (новый sessionID)" << std::endl;

     push_closed(SESSION_CLIENT);
     run(20);

     deliver(SESSION_CLIENT2, 64, 1, 0xDD00);
     if (pop_captured(tx))
          check(tx.sessionID == SESSION_SERVER, "данные нового клиента ушли на сервер");
     else check(false, "uplink нового клиента не завершился");

     deliver(SESSION_SERVER, 64, 1, 0xEE00);
     if (pop_captured(tx))
          check(tx.sessionID == SESSION_CLIENT2, "ответ ушёл НОВОМУ клиенту");
     else check(false, "downlink после реконнекта не завершился");

     // -----------------------------------------------------------
     std::cout << "\n[6] Обрыв upstream и переподключение" << std::endl;

     while (!m_axis_tcp_open_connection.empty()) m_axis_tcp_open_connection.read();

     push_closed(SESSION_SERVER);
     run(50);

     // Пауза реконнекта задана аргументом RECONNECT_DELAY, поэтому
     // проверка идёт всегда — без #ifdef и без пересборки.
     bool reconnected = false;
     for (int i = 0; i < 5000 && !reconnected; i++)
     {
          tick();
          if (!m_axis_tcp_open_connection.empty()) reconnected = true;
     }
     check(reconnected, "ядро переоткрыло соединение с сервером");
     if (reconnected)
     {
          pkt64 oc = m_axis_tcp_open_connection.read();
          check(oc.data(31, 0) == (ap_uint<32>)SERVER_IP, "IP при переподключении верный");
          push_open_status(SESSION_SERVER, true);
          run(20);

          deliver(SESSION_CLIENT2, 64, 1, 0xFF00);
          if (pop_captured(tx))
               check(tx.sessionID == SESSION_SERVER, "данные снова идут на сервер");
          else check(false, "релей не заработал после переподключения");
     }

     // -----------------------------------------------------------
     std::cout << "\n[7] tx_status error==2: нет места, повтор tx_meta" << std::endl;

     // Ошибка на СЛЕДУЮЩЕЙ транзакции
     stk_forceErrorOn   = stk_txCount + 1;
     stk_forceErrorCode = 2;

     deliver(SESSION_CLIENT2, 64, 1, 0x1100);

     // Ядро должно повторить tx_meta; второй раз стек ответит успехом
     if (pop_captured(tx, 800))
     {
          check(tx.sessionID == SESSION_SERVER, "после error==2 данные ушли на сервер");
          check(tx.length == 64, "длина не потерялась при повторе");
          check(tx.words == 1, "данные переданы ровно один раз");
     }
     else check(false, "ядро не повторило tx_meta после error==2");

     stack_reset_cfg();

     // -----------------------------------------------------------
     std::cout << "\n[8] tx_status error==1: обрыв, порция сбрасывается" << std::endl;

     stk_forceErrorOn   = stk_txCount + 1;
     stk_forceErrorCode = 1;

     stk_strayWords = 0;
     deliver(SESSION_CLIENT2, 128, 2, 0x2200);
     run(200);

     check(captured.empty(), "порция при error==1 не отправлена");
     // Ключевая проверка: слова должны быть ВЫЧИТАНЫ из внутренних
     // FIFO и выброшены, а НЕ отправлены в tx_data.
     check(stk_strayWords == 0, "ни одно слово не ушло в tx_data после error==1");

     stack_reset_cfg();

     // Сессия сервера помечена невалидной -> ядро переподключается
     bool reopened = false;
     for (int i = 0; i < 5000 && !reopened; i++)
     {
          tick();
          if (!m_axis_tcp_open_connection.empty()) reopened = true;
     }
     check(reopened, "после error==1 ядро переоткрыло upstream");
     if (reopened)
     {
          m_axis_tcp_open_connection.read();
          push_open_status(SESSION_SERVER, true);
          run(20);

          // Релей снова жив, и очередь не рассинхронизирована
          deliver(SESSION_CLIENT2, 64, 1, 0x3300);
          if (pop_captured(tx, 800))
          {
               check(tx.sessionID == SESSION_SERVER, "релей жив после error==1");
               check(tx.length == 64, "границы пакетов не сдвинулись");
          }
          else check(false, "релей не восстановился после error==1");
     }

     // -----------------------------------------------------------
     std::cout << "\n[9] Оба направления одновременно" << std::endl;

     // Подаём uplink и downlink подряд, не давая слить первый
     deliver(SESSION_CLIENT2, 64, 1, 0x4400);
     deliver(SESSION_SERVER,  64, 1, 0x5500);

     bool got2 = wait_captured(2, 2000);
     check(got2, "обе транзакции завершились");
     if (got2)
     {
          TxCapture a = captured.front(); captured.pop_front();
          TxCapture b = captured.front(); captured.pop_front();

          // Порядок не фиксируем (round-robin), но адресаты должны
          // быть разными: одна порция серверу, одна клиенту.
          bool oneEach = (a.sessionID != b.sessionID)
                         && (a.sessionID == SESSION_SERVER || a.sessionID == SESSION_CLIENT2)
                         && (b.sessionID == SESSION_SERVER || b.sessionID == SESSION_CLIENT2);
          check(oneEach, "каждое направление обслужено ровно один раз");
          check(a.words == 1 && b.words == 1,
                "транзакции не перемешались (по 1 слову каждая)");
     }

     // -----------------------------------------------------------
     std::cout << "\n[10] Backpressure: серия пакетов без слива" << std::endl;

     // Стек перестаёт принимать данные -> FIFO заполняются,
     // ядро обязано применить backpressure, а не потерять данные.
     stk_stallData = true;

     const int BURST = 24;
     for (int i = 0; i < BURST; i++)
          deliver(SESSION_CLIENT2, 64, 1, 0x6000 + i);

     run(500);   // ядро упирается в остановленный стек

     stk_stallData = false;

     bool allDrained = wait_captured(BURST, 40000);
     check(allDrained, "все пакеты дошли после снятия backpressure");
     if (allDrained)
     {
          bool lengthsOk = true;
          int  n = 0;
          while (!captured.empty())
          {
               TxCapture c = captured.front(); captured.pop_front();
               if (c.length != 64 || c.words != 1) lengthsOk = false;
               n++;
          }
          check(lengthsOk, "ни одна порция не потеряна и не склеена");
          check(n == BURST, "число транзакций совпало с числом пакетов");
     }

     // -----------------------------------------------------------
     std::cout << "\n[11] Лишняя клиентская сессия закрывается" << std::endl;

     closedByGw.clear();

     // Второй клиент шлёт данные, хотя SESSION_CLIENT2 ещё жив
     deliver(SESSION_STRAY, 64, 1, 0x7700);
     run(300);

     bool closedStray = false;
     for (size_t i = 0; i < closedByGw.size(); i++)
          if (closedByGw[i] == SESSION_STRAY) closedStray = true;
     check(closedStray, "лишняя сессия закрыта через close_connection");

     // Основной клиент не пострадал
     deliver(SESSION_SERVER, 64, 1, 0x8800);
     if (pop_captured(tx, 800))
          check(tx.sessionID == SESSION_CLIENT2,
                "основной клиент сохранён, ответ ушёл ему");
     else check(false, "основной клиент потерян после лишней сессии");

     // -----------------------------------------------------------
     std::cout << "\n[12] error==2 не блокирует второе направление"
               << std::endl;

     // Регрессия на head-of-line blocking. Раньше при закрытом окне
     // получателя передатчик повторял tx_meta на полной скорости
     // (измерено: 1000 запросов за 2000 такта) и НИКОГДА не возвращался
     // в SELECT, поэтому второе направление — с полностью исправным
     // получателем — не обслуживалось вообще.
     //
     // Здесь окно сервера закрыто навсегда, а клиент здоров: порция в
     // сторону клиента обязана дойти.
     {
          stack_reset_cfg();
          captured.clear();

          stk_refuseSession = SESSION_SERVER;   // uplink отвергается всегда

          deliver(SESSION_CLIENT2, 64, 1, 0x9900);  // uplink  -> отвергается
          run(20);
          deliver(SESSION_SERVER, 64, 1, 0x9A00);   // downlink -> жив

          const int WINDOW = 3000;
          int metaBefore = stk_txCount;

          bool downlinkServed = false;
          for (int i = 0; i < WINDOW; i++)
          {
               tick();
               for (size_t k = 0; k < captured.size(); k++)
                    if (captured[k].sessionID == SESSION_CLIENT2)
                         downlinkServed = true;
          }
          int metas = stk_txCount - metaBefore;

          check(downlinkServed,
                "downlink обслужен, хотя uplink отвергается постоянно");
          // Повтор должен быть с паузой, а не каждые два такта.
          check(metas < WINDOW / 10,
                "повтор tx_meta с паузой, а не busy-wait");

          std::cout << "        запросов tx_meta за " << WINDOW
                    << " такта: " << metas << std::endl;

          stack_reset_cfg();
          run(500);
          captured.clear();
     }

     // -----------------------------------------------------------
     std::cout << "\n=== Итог: " << (failures == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ"
                                                   : "ЕСТЬ ОШИБКИ")
               << " (failures=" << failures << ") ===" << std::endl;
     return failures == 0 ? 0 : 1;
}
