/************************************************
C-симуляция для hls_ouch_krnl.

Растёт вместе с ядром. Сейчас проверяется только ШАГ 1 — открытие
listen-порта.

Ядро объявлено с ap_ctrl_none и работает вечно, поэтому в csim его
нельзя вызвать «до завершения»: тестбенч вызывает его в цикле по одному
такту (tick) и между тактами подкладывает/забирает данные, изображая
собой TCP-стек.

Именно из-за этой конструкции тестбенч непригоден для co-simulation:
там ядро — RTL-модуль, который тикает сам, и понятия «вызвать на один
такт» не существует. Cosim для этого ядра не используется вовсе, см.
пояснение в hls_ouch_krnl.cpp.

ГРАНИЦА ПРИМЕНИМОСТИ: в csim hls::stream неограничен, поэтому проверки
full() и устойчивость к backpressure здесь не проявляются в принципе.
Пока стадия одна и FIFO между стадиями нет, это неважно; при их
появлении понадобятся ограниченные потоки (см. там же).

Сценарии:
  0. До enable ядро не трогает порты (гонка с ap_ctrl_none)
  1. Ядро само запрашивает listen-порт, и именно тот, что задан
  2. Отказ стека -> ядро повторяет запрос
  3. После успеха ядро не спамит запросами

Сборка (на машине с Vitis HLS), из каталога src/hls:
    vitis_hls -f run_csim.tcl
************************************************/
#include "ap_axi_sdata.h"
#include "ap_int.h"
#include "hls_stream.h"

#include <iostream>
#include <string>

typedef ap_axiu<512, 0, 0, 0> pkt512;
typedef ap_axiu<256, 0, 0, 0> pkt256;
typedef ap_axiu<128, 0, 0, 0> pkt128;
typedef ap_axiu<64, 0, 0, 0>  pkt64;
typedef ap_axiu<32, 0, 0, 0>  pkt32;
typedef ap_axiu<16, 0, 0, 0>  pkt16;
typedef ap_axiu<8, 0, 0, 0>   pkt8;

extern "C" void hls_ouch_krnl(
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
     int enable);

// ---------------------------------------------------------------
// Порт приходит в ядро обычным аргументом (AXI-lite), поэтому здесь его
// можно задать как угодно — никакой второй копии значения в ядре нет.
static const int LISTEN_PORT = 7001;

// Изображает регистр enable: на плате его выставляет хост после записи
// всех остальных параметров. Тесты меняют его, чтобы проверить, что до
// разрешения ядро не трогает порты (см. пояснение в ядре про гонку).
static int enable = 0;

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

// Один такт ядра
static void tick()
{
     hls_ouch_krnl(s_axis_udp_rx, m_axis_udp_tx,
                   s_axis_udp_rx_meta, m_axis_udp_tx_meta,
                   m_axis_tcp_listen_port, s_axis_tcp_port_status,
                   m_axis_tcp_open_connection, s_axis_tcp_open_status,
                   m_axis_tcp_close_connection,
                   s_axis_tcp_notification, m_axis_tcp_read_pkg,
                   s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                   m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                   s_axis_tcp_tx_status,
                   LISTEN_PORT, enable);
}

static void run(int cycles) { for (int i = 0; i < cycles; i++) tick(); }

// Стек отвечает на запрос listen-порта
static void push_port_status(bool success)
{
     pkt8 ps;
     ps.data = success ? 1 : 0;
     s_axis_tcp_port_status.write(ps);
}

// Забрать ВСЕ накопившиеся запросы порта. Возвращает их количество, а в
// portOut — значение последнего.
//
// Именно «все», а не один: если читать по одному, то лишние запросы
// остаются в потоке, и следующая проверка вычитывает старый пакет вместо
// нового. Мутационная проверка (убрать повтор при отказе) показала, что с
// чтением по одному тест [2] проходит даже на сломанном ядре.
static int drain_listen_requests(ap_uint<16>& portOut)
{
     int n = 0;
     while (!m_axis_tcp_listen_port.empty())
     {
          pkt16 lp = m_axis_tcp_listen_port.read();
          portOut = lp.data(15, 0);
          n++;
     }
     return n;
}

// ---------------------------------------------------------------
int main()
{
     std::cout << "=== hls_ouch_krnl C-simulation (шаг 1: listen) ==="
               << std::endl;

     // -----------------------------------------------------------
     std::cout << "\n[0] Без enable ядро не трогает порты" << std::endl;

     // Изображаем реальную последовательность на плате: битстрим уже
     // загружен и ядро тикает, а хост ещё не записал ни параметры, ни
     // enable. Ядро обязано молчать — иначе оно запросит порт по
     // мусорному (нулевому) значению регистра и защёлкнет своё
     // состояние до того, как хост успеет что-то сказать.
     enable = 0;
     run(500);

     ap_uint<16> ignored = 0;
     check(drain_listen_requests(ignored) == 0,
           "до enable запросов listen-порта нет");

     // -----------------------------------------------------------
     std::cout << "\n[1] Ядро запрашивает listen-порт" << std::endl;

     // Хост записал параметры, теперь разрешает работу
     enable = 1;
     run(5);

     ap_uint<16> port = 0;
     int nFirst = drain_listen_requests(port);
     check(nFirst == 1, "ядро запросило listen-порт ровно один раз");
     if (nFirst > 0)
          check(port == LISTEN_PORT, "запрошен именно заданный порт");

     // -----------------------------------------------------------
     std::cout << "\n[2] Отказ стека -> повторный запрос" << std::endl;

     // Стек говорит «не открылось». Ядро обязано попробовать снова,
     // иначе оно молча останется без listen-порта.
     //
     // Поток запросов здесь уже пуст (вычитан выше), поэтому любой
     // найденный запрос — именно ответ на отказ.
     push_port_status(false);
     run(10);

     ap_uint<16> retryPort = 0;
     int nRetry = drain_listen_requests(retryPort);
     check(nRetry >= 1, "после отказа ядро повторило запрос");
     if (nRetry > 0)
          check(retryPort == LISTEN_PORT, "повторный запрос с тем же портом");

     // -----------------------------------------------------------
     std::cout << "\n[3] После успеха ядро не спамит запросами"
               << std::endl;

     push_port_status(true);
     run(200);

     ap_uint<16> extra = 0;
     check(drain_listen_requests(extra) == 0,
           "после успешного открытия новых запросов нет");

     // Успех должен быть ЗАФИКСИРОВАН (portOpened), а не просто «сейчас
     // нечего просить». Проверяем это по наблюдаемому признаку: открыв
     // порт, ядро больше не вычитывает port_status. Если бы флаг не
     // фиксировался, ядро продолжало бы читать этот поток.
     //
     // Без такой проверки мутация «никогда не выставлять portOpened»
     // проходила тест незамеченной: запросов она тоже не порождает,
     // потому что portRequested остаётся true.
     push_port_status(true);
     run(200);
     check(!s_axis_tcp_port_status.empty(),
           "открыв порт, ядро перестало читать port_status");

     // Порт открыт один раз и остаётся открытым: повторные подключения
     // клиентов принимает стек, ядру для этого ничего делать не нужно.

     // -----------------------------------------------------------
     std::cout << "\n=== Итог: " << (failures == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ"
                                                   : "ЕСТЬ ОШИБКИ")
               << " (failures=" << failures << ") ===" << std::endl;
     return failures == 0 ? 0 : 1;
}
