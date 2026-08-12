/************************************************
Тестбенч hls_dual_echo_krnl — проверка последовательности bringup БЕЗ ПЛАТЫ.

ЗАЧЕМ ИМЕННО ЭТОТ ТЕСТ. Доступ к железу ограничен, а две предыдущие попытки
были потеряны на одной и той же ошибке: параметры от хоста не доходили до
логики. Здесь проверяется то, что можно проверить на хосте — сама логика
автомата и её реакция на порядок операций. Тайминг, упаковку IP и
разводку BD это НЕ проверяет (для них нужен Vivado).

Ядро объявлено ap_ctrl_none и работает вечно, поэтому вызывается в цикле:
один вызов = один такт. Состояние живёт в static внутри стадий, как на
железе.

ЧТО ПРОВЕРЯЕТСЯ:

  1. ДО enable ядро не трогает стек ВООБЩЕ. Это та самая гонка: TOE получает
     IP только по фронту ap_start network_krnl, а сбрасывается лишь по
     net_aresetn, поэтому listen, запрошенный до подъёма стека, ничего не
     гарантирует.
  2. ПОСЛЕ enable оба порта запрашиваются — каждый со своим номером.
  3. Половины НЕЗАВИСИМЫ: успех на a при молчании b не открывает b, и
     наоборот. Это главный критерий: ровно здесь ломался бы общий static,
     если бы HLS свёл два вызова dual_echo_listen к одному экземпляру.
  4. Повтор по таймауту: если стек молчит дольше LISTEN_TIMEOUT, запрос
     уходит снова, а listenAttempts растёт. Прежняя версия залипала здесь
     навсегда без единого признака снаружи.
  5. Телеметрия различает состояния: 0=ждём enable, 1=запрос, 2=открыт.

Сборка нативно (без Vitis HLS), через шим kernel/common/csim_shim:

    g++ -std=c++14 -I kernel/common/csim_shim -I kernel/common/include \
        kernel/user_krnl/hls_dual_echo_krnl/src/hls/hls_dual_echo_krnl.cpp \
        kernel/user_krnl/hls_dual_echo_krnl/src/hls/tb/test_hls_dual_echo_krnl.cpp \
        -o /tmp/test_dual_echo && /tmp/test_dual_echo
************************************************/
#include <cstdio>
#include "ap_int.h"
#include "ap_axi_sdata.h"
#include "hls_stream.h"
// ВНИМАНИЕ: communication.hpp здесь НЕ подключается. Функции в нём объявлены
// без inline, поэтому включение его и в ядро, и в тестбенч даёт duplicate
// symbol при линковке. Тестбенчу нужны только типы pkt*, а они — простые
// typedef над ap_axiu, поэтому объявляем их локально теми же строками, что в
// communication.hpp:18-24.
typedef ap_axiu<512, 0, 0, 0> pkt512;
typedef ap_axiu<256, 0, 0, 0> pkt256;
typedef ap_axiu<128, 0, 0, 0> pkt128;
typedef ap_axiu<64, 0, 0, 0>  pkt64;
typedef ap_axiu<32, 0, 0, 0>  pkt32;
typedef ap_axiu<16, 0, 0, 0>  pkt16;
typedef ap_axiu<8, 0, 0, 0>   pkt8;

// LISTEN_TIMEOUT в ядре — миллион тактов. Гонять столько в тесте незачем,
// поэтому таймаутный сценарий проверяется отдельным быстрым способом: мы
// убеждаемся, что до таймаута повтора НЕТ, а сам факт повтора проверяем,
// прокрутив ровно нужное число тактов (это быстро — тело простое).
#define TB_LISTEN_TIMEOUT 1000000

// extern "C" — как в самом ядре, иначе не сойдётся при линковке.
extern "C" void hls_dual_echo_krnl(
     hls::stream<pkt512>& s_axis_udp_rx_a, hls::stream<pkt512>& m_axis_udp_tx_a,
     hls::stream<pkt256>& s_axis_udp_rx_meta_a, hls::stream<pkt256>& m_axis_udp_tx_meta_a,
     hls::stream<pkt16>& m_axis_tcp_listen_port_a, hls::stream<pkt8>& s_axis_tcp_port_status_a,
     hls::stream<pkt64>& m_axis_tcp_open_connection_a, hls::stream<pkt128>& s_axis_tcp_open_status_a,
     hls::stream<pkt16>& m_axis_tcp_close_connection_a,
     hls::stream<pkt128>& s_axis_tcp_notification_a, hls::stream<pkt32>& m_axis_tcp_read_pkg_a,
     hls::stream<pkt16>& s_axis_tcp_rx_meta_a, hls::stream<pkt512>& s_axis_tcp_rx_data_a,
     hls::stream<pkt32>& m_axis_tcp_tx_meta_a, hls::stream<pkt512>& m_axis_tcp_tx_data_a,
     hls::stream<pkt64>& s_axis_tcp_tx_status_a,
     hls::stream<pkt512>& s_axis_udp_rx_b, hls::stream<pkt512>& m_axis_udp_tx_b,
     hls::stream<pkt256>& s_axis_udp_rx_meta_b, hls::stream<pkt256>& m_axis_udp_tx_meta_b,
     hls::stream<pkt16>& m_axis_tcp_listen_port_b, hls::stream<pkt8>& s_axis_tcp_port_status_b,
     hls::stream<pkt64>& m_axis_tcp_open_connection_b, hls::stream<pkt128>& s_axis_tcp_open_status_b,
     hls::stream<pkt16>& m_axis_tcp_close_connection_b,
     hls::stream<pkt128>& s_axis_tcp_notification_b, hls::stream<pkt32>& m_axis_tcp_read_pkg_b,
     hls::stream<pkt16>& s_axis_tcp_rx_meta_b, hls::stream<pkt512>& s_axis_tcp_rx_data_b,
     hls::stream<pkt32>& m_axis_tcp_tx_meta_b, hls::stream<pkt512>& m_axis_tcp_tx_data_b,
     hls::stream<pkt64>& s_axis_tcp_tx_status_b,
     int listenPortA, int listenPortB,
     ap_uint<32>& listenAttempts_a, ap_uint<32>& portState_a, ap_uint<32>& notifyCount_a,
     ap_uint<32>& listenAttempts_b, ap_uint<32>& portState_b, ap_uint<32>& notifyCount_b,
     int enable);

// Все порты стека в одном месте: тест дёргает только те, что нужны, но
// передавать нужно все.
struct stackPorts
{
     hls::stream<pkt512> udp_rx_a, udp_tx_a, rx_data_a, tx_data_a;
     hls::stream<pkt256> udp_rx_meta_a, udp_tx_meta_a;
     hls::stream<pkt16>  listen_port_a, close_con_a, rx_meta_a;
     hls::stream<pkt8>   port_status_a;
     hls::stream<pkt64>  open_con_a, tx_status_a;
     hls::stream<pkt128> open_status_a, notification_a;
     hls::stream<pkt32>  read_pkg_a, tx_meta_a;

     hls::stream<pkt512> udp_rx_b, udp_tx_b, rx_data_b, tx_data_b;
     hls::stream<pkt256> udp_rx_meta_b, udp_tx_meta_b;
     hls::stream<pkt16>  listen_port_b, close_con_b, rx_meta_b;
     hls::stream<pkt8>   port_status_b;
     hls::stream<pkt64>  open_con_b, tx_status_b;
     hls::stream<pkt128> open_status_b, notification_b;
     hls::stream<pkt32>  read_pkg_b, tx_meta_b;
};

struct telemetry
{
     ap_uint<32> att_a, state_a, notify_a;
     ap_uint<32> att_b, state_b, notify_b;
};

static void tick(stackPorts& p, telemetry& t, int portA, int portB, int enable)
{
     hls_dual_echo_krnl(
          p.udp_rx_a, p.udp_tx_a, p.udp_rx_meta_a, p.udp_tx_meta_a,
          p.listen_port_a, p.port_status_a, p.open_con_a, p.open_status_a,
          p.close_con_a, p.notification_a, p.read_pkg_a,
          p.rx_meta_a, p.rx_data_a, p.tx_meta_a, p.tx_data_a, p.tx_status_a,
          p.udp_rx_b, p.udp_tx_b, p.udp_rx_meta_b, p.udp_tx_meta_b,
          p.listen_port_b, p.port_status_b, p.open_con_b, p.open_status_b,
          p.close_con_b, p.notification_b, p.read_pkg_b,
          p.rx_meta_b, p.rx_data_b, p.tx_meta_b, p.tx_data_b, p.tx_status_b,
          portA, portB,
          t.att_a, t.state_a, t.notify_a,
          t.att_b, t.state_b, t.notify_b,
          enable);
}

static void portStatus(hls::stream<pkt8>& s, bool success)
{
     pkt8 pkt;
     pkt.data = success ? 1 : 0;
     pkt.keep = 1;
     pkt.last = 1;
     s.write(pkt);
}

static int failures = 0;

static void check(bool cond, const char* what)
{
     if (cond)
     {
          printf("  OK   %s\n", what);
     }
     else
     {
          printf("  FAIL %s\n", what);
          failures++;
     }
}

/*
 * ВАЖНО ПРО ПОРЯДОК СЦЕНАРИЕВ.
 *
 * Состояние автомата живёт в static внутри стадий — так же, как регистры на
 * железе. Программа запускается ОДИН раз, значит "перезагрузить" ядро между
 * сценариями нельзя: новый stackPorts даёт чистые потоки, но st_a/st_b
 * сохраняют то, что было. Это не дефект ядра (на плате состояние сбрасывается
 * по ap_rst_n), а свойство нативного csim.
 *
 * Поэтому сценарии идут в порядке НАРАСТАНИЯ состояния: сначала всё, что
 * требует закрытого порта (отказ, таймаут), потом успешное открытие, и лишь
 * затем приём данных. Первая версия теста шла в обратном порядке, и проверки
 * повтора падали — не потому, что повтор сломан (изолированно он работает),
 * а потому что порт был уже открыт с предыдущего сценария.
 */
int main()
{
     const int PORT_A = 7001;
     const int PORT_B = 7002;

     stackPorts p;
     telemetry  t = {0, 0, 0, 0, 0, 0};

     // ── 1. До enable стек не трогаем ─────────────────────────────────────
     printf("\n1. enable=0: ядро не должно трогать стек\n");
     for (int i = 0; i < 100; ++i)
          tick(p, t, PORT_A, PORT_B, 0);

     check(p.listen_port_a.empty(), "порт слушания a не запрашивался");
     check(p.listen_port_b.empty(), "порт слушания b не запрашивался");
     check(p.open_con_a.empty() && p.open_con_b.empty(),
           "соединения не открывались");
     check(t.state_a == 0 && t.state_b == 0, "portState=0 на обеих половинах");
     check(t.att_a == 0 && t.att_b == 0, "listenAttempts=0 на обеих половинах");

     // ── 2. enable=1: запрашиваются оба порта, каждый со своим номером ────
     printf("\n2. enable=1: оба порта запрошены со своими номерами\n");
     tick(p, t, PORT_A, PORT_B, 1);

     check(!p.listen_port_a.empty(), "половина a отправила запрос listen");
     check(!p.listen_port_b.empty(), "половина b отправила запрос listen");

     if (!p.listen_port_a.empty() && !p.listen_port_b.empty())
     {
          pkt16 req_a = p.listen_port_a.read();
          pkt16 req_b = p.listen_port_b.read();
          int got_a = (int)req_a.data(15, 0);
          int got_b = (int)req_b.data(15, 0);
          printf("       a запросила порт %d, b запросила порт %d\n", got_a, got_b);
          check(got_a == PORT_A, "половина a просит именно listenPortA");
          check(got_b == PORT_B, "половина b просит именно listenPortB");
     }
     check(t.state_a == 1 && t.state_b == 1, "portState=1 (запрос отправлен)");
     check(t.att_a == 1 && t.att_b == 1, "listenAttempts=1");

     // Запросы прочитаны, дальше сценарии идут на том же состоянии
     // (порты ещё НЕ открыты — см. пояснение о порядке выше).

     // ── 3. Отказ стека -> повтор запроса ─────────────────────────────────
     printf("\n3. отказ стека -> повторный запрос\n");
     portStatus(p.port_status_a, false);   // стек отказал половине a
     for (int i = 0; i < 5; ++i)
          tick(p, t, PORT_A, PORT_B, 1);

     check(!p.listen_port_a.empty(), "после отказа запрос повторён");
     check(t.att_a == 2, "listenAttempts=2 на половине a");
     check(t.state_a == 1, "portState=1 (снова ждём ответа)");
     check(t.att_b == 1, "половина b не затронута отказом на a");
     if (!p.listen_port_a.empty()) p.listen_port_a.read();

     // ── 4. Молчание стека дольше таймаута -> тоже повтор ─────────────────
     printf("\n4. молчание стека дольше LISTEN_TIMEOUT -> повтор\n");
     {
          ap_uint<32> att_before = t.att_a;

          // Чуть меньше таймаута: повтора быть НЕ должно.
          for (int i = 0; i < TB_LISTEN_TIMEOUT - 10; ++i)
               tick(p, t, PORT_A, PORT_B, 1);
          check(p.listen_port_a.empty(), "до истечения таймаута повтора нет");
          check(t.att_a == att_before, "listenAttempts не вырос раньше времени");

          // Переходим таймаут: должен уйти повторный запрос.
          for (int i = 0; i < 50; ++i)
               tick(p, t, PORT_A, PORT_B, 1);
          check(!p.listen_port_a.empty(),
                "после таймаута запрос повторён (нет вечного залипания)");
          check(t.att_a > att_before,
                "listenAttempts вырос — видно снаружи по JTAG");
          if (!p.listen_port_a.empty()) p.listen_port_a.read();
     }

     // ── 5. Независимость: a открылась, b молчит ──────────────────────────
     printf("\n5. независимость половин: успех на a, молчание на b\n");
     portStatus(p.port_status_a, true);
     for (int i = 0; i < 10; ++i)
          tick(p, t, PORT_A, PORT_B, 1);

     check(t.state_a == 2, "половина a: порт открыт (portState=2)");
     check(t.state_b == 1, "половина b: всё ещё ждёт ответа (portState=1)");
     check(p.listen_port_a.empty(),
           "половина a не повторяет запрос после успеха");

     // ── 6. Теперь открывается b — не задев a ─────────────────────────────
     printf("\n6. затем открывается b\n");
     portStatus(p.port_status_b, true);
     for (int i = 0; i < 10; ++i)
          tick(p, t, PORT_A, PORT_B, 1);

     check(t.state_b == 2, "половина b: порт открыт");
     check(t.state_a == 2, "половина a осталась открытой");
     printf("       att_b=%u (ожидаемо >1: половина b тоже ждала весь таймаут)\n", (unsigned)t.att_b);
     check(t.att_b >= 1, "половина b открылась (число попыток не важно)");

     // ── 7. Приём данных: уведомление -> read request, счётчик растёт ─────
     printf("\n7. уведомление о данных -> запрос чтения\n");
     {
          // Уведомление: сессия 3, длина 64 байта — только на половину a.
          pkt128 note;
          note.data = 0;
          note.data(15, 0)  = 3;
          note.data(31, 16) = 64;
          note.keep = -1;
          note.last = 1;
          p.notification_a.write(note);

          for (int i = 0; i < 10; ++i)
               tick(p, t, PORT_A, PORT_B, 1);

          check(!p.read_pkg_a.empty(), "половина a запросила чтение данных");
          if (!p.read_pkg_a.empty())
          {
               pkt32 rr = p.read_pkg_a.read();
               check((int)rr.data(15, 0) == 3, "sessionID в запросе верный");
               check((int)rr.data(31, 16) == 64, "длина в запросе верная");
          }
          check(t.notify_a == 1, "notifyCount_a=1");
          check(t.notify_b == 0, "notifyCount_b=0 — половина b не затронута");
          check(p.read_pkg_b.empty(), "половина b чтение не запрашивала");
     }

     // ── 8. enable=0 снова: телеметрия возвращается в 0 ───────────────────
     //
     // Проверяем, что enable действительно управляет логикой в любой момент,
     // а не только на старте. Это то, чего НЕ давал s_axilite при
     // ap_ctrl_none: там значение защёлкивалось однажды и больше не менялось.
     printf("\n8. enable=0 в любой момент -> portState снова 0\n");
     for (int i = 0; i < 5; ++i)
          tick(p, t, PORT_A, PORT_B, 0);
     check(t.state_a == 0 && t.state_b == 0,
           "portState=0 на обеих половинах при enable=0");

     printf("\n");
     if (failures == 0)
     {
          printf("=== ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ ===\n");
          printf("Проверена ЛОГИКА: порядок bringup, независимость половин,\n");
          printf("повтор по отказу и по таймауту, телеметрия.\n");
          printf("НЕ проверено (нужен Vivado): тайминг, упаковка IP, разводка BD.\n");
          return 0;
     }

     printf("=== ОШИБОК: %d ===\n", failures);
     return 1;
}
