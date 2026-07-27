/************************************************
C-симуляция для hls_gateway_krnl.

Тестбенч подменяет собой TCP/IP-стек: он подаёт ядру уведомления и
данные так, как это делал бы стек, и проверяет, что ядро отправляет
в ответ.

Ядро объявлено с ap_ctrl_none и работает вечно, поэтому в csim его
нельзя вызвать «до завершения» — вместо этого тестбенч вызывает его
в цикле по одному такту (kernel_tick) и между тактами
подкладывает/забирает данные.

Сценарии:
  1. Открытие listen-порта и подключение к upstream-серверу
  2. Uplink:   клиент -> сервер
  3. Downlink: сервер -> клиент
  4. Неполное слово (length не кратна 64) — проверка keep
  5. Реконнект клиента (новый sessionID)
  6. Обрыв upstream и автоматическое переподключение

Сборка (на машине с Vitis HLS):
    vitis_hls -f run_csim.tcl
или вручную:
    g++ -std=c++14 -I$XILINX_HLS/include \
        test_hls_gateway_krnl.cpp hls_gateway_krnl.cpp -o tb && ./tb
************************************************/
#include "ap_axi_sdata.h"
#include "ap_int.h"
#include "hls_stream.h"

#include <iostream>
#include <vector>
#include <string>

typedef ap_axiu<512, 0, 0, 0> pkt512;
typedef ap_axiu<256, 0, 0, 0> pkt256;
typedef ap_axiu<128, 0, 0, 0> pkt128;
typedef ap_axiu<64, 0, 0, 0>  pkt64;
typedef ap_axiu<32, 0, 0, 0>  pkt32;
typedef ap_axiu<16, 0, 0, 0>  pkt16;
typedef ap_axiu<8, 0, 0, 0>   pkt8;

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
     int serverPort);

// ---------------------------------------------------------------
// Параметры теста
// ---------------------------------------------------------------
static const int LISTEN_PORT   = 5001;
static const int SERVER_IP     = 0xC0A80114;  // 192.168.1.20
static const int SERVER_PORT   = 8080;

static const ap_uint<16> SESSION_SERVER  = 7;   // выдаём при open
static const ap_uint<16> SESSION_CLIENT  = 3;   // первый клиент
static const ap_uint<16> SESSION_CLIENT2 = 9;   // после реконнекта

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

// Один такт работы ядра
static void kernel_tick()
{
     hls_gateway_krnl(s_axis_udp_rx, m_axis_udp_tx,
                      s_axis_udp_rx_meta, m_axis_udp_tx_meta,
                      m_axis_tcp_listen_port, s_axis_tcp_port_status,
                      m_axis_tcp_open_connection, s_axis_tcp_open_status,
                      m_axis_tcp_close_connection,
                      s_axis_tcp_notification, m_axis_tcp_read_pkg,
                      s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                      m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                      s_axis_tcp_tx_status,
                      LISTEN_PORT, SERVER_IP, SERVER_PORT);
}

static void run(int cycles)
{
     for (int i = 0; i < cycles; i++) kernel_tick();
}

// ---------------------------------------------------------------
// Хелперы: имитация поведения TCP-стека
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

// Стек подтверждает готовность принять tx (error = 0)
static void push_tx_status_ok(ap_uint<16> sessionID, ap_uint<16> length)
{
     pkt64 s;
     s.data = 0;
     s.data(15, 0)  = sessionID;
     s.data(31, 16) = length;
     s.data(61, 32) = 60000;
     s.data(63, 62) = 0;
     s_axis_tcp_tx_status.write(s);
}

// Стек сообщает об обрыве при попытке передачи (error = 1)
static void push_tx_status_torn(ap_uint<16> sessionID)
{
     pkt64 s;
     s.data = 0;
     s.data(15, 0)  = sessionID;
     s.data(63, 62) = 1;
     s_axis_tcp_tx_status.write(s);
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

// Забрать tx-транзакцию: meta + данные. Возвращает false, если meta нет.
static bool pop_tx(ap_uint<16>& sessionID, ap_uint<16>& length,
                   int& wordsSeen, ap_uint<64>& lastKeep)
{
     if (m_axis_tcp_tx_meta.empty()) return false;

     pkt32 meta = m_axis_tcp_tx_meta.read();
     sessionID = meta.data(15, 0);
     length    = meta.data(31, 16);

     // Стек подтверждает готовность, после чего ядро шлёт данные
     push_tx_status_ok(sessionID, length);

     wordsSeen = 0;
     lastKeep = 0;
     bool sawLast = false;
     for (int guard = 0; guard < 2000 && !sawLast; guard++)
     {
          kernel_tick();
          while (!m_axis_tcp_tx_data.empty())
          {
               pkt512 w = m_axis_tcp_tx_data.read();
               wordsSeen++;
               lastKeep = w.keep;
               if (w.last) { sawLast = true; break; }
          }
     }
     return sawLast;
}

// Ждём появления tx_meta в течение limit тактов
static bool wait_tx_meta(int limit)
{
     for (int i = 0; i < limit; i++)
     {
          if (!m_axis_tcp_tx_meta.empty()) return true;
          kernel_tick();
     }
     return false;
}

// Подсчёт единиц в keep
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

     ap_uint<16> sid, len;
     int words;
     ap_uint<64> keep;

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

     // Стек подтверждает: порт открыт, соединение установлено
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
     run(20);

     check(wait_tx_meta(50), "появилась tx-транзакция");
     if (pop_tx(sid, len, words, keep))
     {
          check(sid == SESSION_SERVER, "данные ушли в сессию СЕРВЕРА");
          check(len == 128, "длина сохранена");
          check(words == 2, "передано 2 слова");
     }
     else check(false, "uplink-транзакция не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[3] Downlink: сервер -> клиент" << std::endl;

     push_notification(SESSION_SERVER, 64);
     run(5);
     if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
     push_rx_payload(SESSION_SERVER, 1, 0xBB00);
     run(20);

     check(wait_tx_meta(50), "появилась downlink-транзакция");
     if (pop_tx(sid, len, words, keep))
     {
          check(sid == SESSION_CLIENT, "данные ушли в сессию КЛИЕНТА");
          check(len == 64, "длина сохранена");
          check(words == 1, "передано 1 слово");
     }
     else check(false, "downlink-транзакция не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[4] Неполное слово: length = 100 байт" << std::endl;

     push_notification(SESSION_CLIENT, 100);   // 1 полное + 36 байт
     run(5);
     if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
     push_rx_payload(SESSION_CLIENT, 2, 0xCC00);
     run(20);

     check(wait_tx_meta(50), "появилась транзакция с неполным словом");
     if (pop_tx(sid, len, words, keep))
     {
          check(len == 100, "длина 100 сохранена");
          check(words == 2, "передано 2 слова");
          check(count_keep(keep) == 36, "keep последнего слова = 36 байт");
     }
     else check(false, "транзакция с неполным словом не завершилась");

     // -----------------------------------------------------------
     std::cout << "\n[5] Реконнект клиента (новый sessionID)" << std::endl;

     push_closed(SESSION_CLIENT);
     run(20);

     // Новый клиент шлёт данные — ядро должно подхватить новый sessionID
     push_notification(SESSION_CLIENT2, 64);
     run(5);
     if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
     push_rx_payload(SESSION_CLIENT2, 1, 0xDD00);
     run(20);

     check(wait_tx_meta(50), "uplink нового клиента прошёл");
     if (pop_tx(sid, len, words, keep))
          check(sid == SESSION_SERVER, "данные нового клиента ушли на сервер");
     else check(false, "uplink нового клиента не завершился");

     // Ответ сервера должен уйти уже НОВОМУ клиенту
     push_notification(SESSION_SERVER, 64);
     run(5);
     if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
     push_rx_payload(SESSION_SERVER, 1, 0xEE00);
     run(20);

     check(wait_tx_meta(50), "downlink после реконнекта прошёл");
     if (pop_tx(sid, len, words, keep))
          check(sid == SESSION_CLIENT2, "ответ ушёл НОВОМУ клиенту");
     else check(false, "downlink после реконнекта не завершился");

     // -----------------------------------------------------------
     std::cout << "\n[6] Обрыв upstream и переподключение" << std::endl;

     // Очищаем возможный мусор
     while (!m_axis_tcp_open_connection.empty()) m_axis_tcp_open_connection.read();

     push_closed(SESSION_SERVER);
     run(50);

     // Ядро выдерживает паузу GW_RECONNECT_DELAY (~250e6 тактов).
     // Для симуляции это слишком долго, поэтому проверяем факт
     // переподключения только если задержка уменьшена.
     // Пересоберите с -DGW_RECONNECT_DELAY=100 для этой проверки.
#ifdef GW_FAST_RECONNECT
     bool reconnected = false;
     for (int i = 0; i < 5000 && !reconnected; i++)
     {
          kernel_tick();
          if (!m_axis_tcp_open_connection.empty()) reconnected = true;
     }
     check(reconnected, "ядро переоткрыло соединение с сервером");
     if (reconnected)
     {
          pkt64 oc = m_axis_tcp_open_connection.read();
          check(oc.data(31, 0) == (ap_uint<32>)SERVER_IP, "IP при переподключении верный");
          push_open_status(SESSION_SERVER, true);
          run(20);

          // После восстановления релей должен снова работать
          push_notification(SESSION_CLIENT2, 64);
          run(5);
          if (!m_axis_tcp_read_pkg.empty()) m_axis_tcp_read_pkg.read();
          push_rx_payload(SESSION_CLIENT2, 1, 0xFF00);
          run(20);

          check(wait_tx_meta(100), "релей работает после переподключения");
          if (pop_tx(sid, len, words, keep))
               check(sid == SESSION_SERVER, "данные снова идут на сервер");
     }
#else
     std::cout << "  [SKIP] проверка переподключения — пересоберите с "
               << "-DGW_FAST_RECONNECT -DGW_RECONNECT_DELAY=100" << std::endl;
#endif

     // -----------------------------------------------------------
     std::cout << "\n=== Итог: " << (failures == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ"
                                                   : "ЕСТЬ ОШИБКИ")
               << " (failures=" << failures << ") ===" << std::endl;
     return failures == 0 ? 0 : 1;
}
