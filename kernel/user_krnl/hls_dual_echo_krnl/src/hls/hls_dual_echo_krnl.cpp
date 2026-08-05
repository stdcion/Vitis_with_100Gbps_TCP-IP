/************************************************
Отладка механики "один HLS-инстанс, два физических QSFP-порта" на
максимально простой логике — той же, что уже проверена в hls_echo_krnl.

ЗАЧЕМ ЭТО ОТДЕЛЬНОЕ ЯДРО. hls_echo_krnl при NUM_QSFP=2 собирается ДВУМЯ
экземплярами одного и того же IP (hls_echo_krnl_1 -> network_krnl_1,
hls_echo_krnl_2 -> network_krnl_2, см. build_bd.tcl) — экземпляры
RTL-идентичны и ничего не знают друг о друге. Для тестового эха этого
достаточно. Но настоящий гейтвей (см. заметку в памяти
dual-qsfp-gateway-architecture) должен быть ОДНИМ инстансом, видящим порты
ОБОИХ network_krnl одновременно — иначе логике перекладки данных между
портами буквально не за что зацепиться. Это ядро проверяет именно эту
механику подключения (32 AXI-Stream порта на один инстанс, config_sp и
build_bd.tcl под него), НЕ добавляя relay-логику: каждая половина (a и b)
делает то же самое, что и hls_echo_krnl — слушает свой порт и глушит
данные. Как только эта механика подтверждена на живом железе, боевой
hls_ouch_krnl получает такую же форму интерфейса и настоящую логику
перекладки внутри.

КРИТЕРИЙ УСПЕХА — снаружи, без хоста и без JTAG:

    nc <ip_qsfp0> 7001    подключается и не отваливается
    nc <ip_qsfp1> 7001    подключается и не отваливается, НЕЗАВИСИМО от a

Обе половины работают одновременно и не влияют друг на друга: разные
статические переменные состояния, разные AXI-Stream порты, никакого
общего состояния между ними в этом ядре нет.

ОТЛИЧИЯ ОТ hls_echo_krnl: вместо одного набора из 16 портов network_krnl
здесь два набора (суффиксы _a и _b), подключаемые в build_bd.tcl к
network_krnl_1 и network_krnl_2 соответственно. Порт слушания у обеих
половин один и тот же LISTEN_PORT — это безопасно, потому что они сидят
на разных network_krnl (разные IP/MAC, см. jtag_ctrl.tcl echo_bringup_dual),
конфликта портов внутри одного TCP-стека здесь нет.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Порт, который слушают обе половины (на разных network_krnl — см. выше).
#define LISTEN_PORT 7001

/*
 * Открывает listen-порт и держит его. Идентична echo_listen из
 * hls_echo_krnl.cpp; продублирована (а не переиспользована из другого
 * файла), потому что вызывается дважды с независимым состоянием —
 * static-переменные внутри принадлежат КОНКРЕТНОМУ вызову в дизайне, а
 * не функции как таковой, так что общий код тут ничего бы не сэкономил
 * по железу, только по числу строк.
 */
void dual_echo_listen(hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
#pragma HLS RESET variable=portRequested
     static bool portOpened = false;
#pragma HLS RESET variable=portOpened

     if (!portRequested)
     {
          pkt16 listen_port_pkt;
          listen_port_pkt.data = 0;
          listen_port_pkt.data(15, 0) = LISTEN_PORT;
          m_axis_tcp_listen_port.write(listen_port_pkt);
          portRequested = true;
     }
     else if (!portOpened && !s_axis_tcp_port_status.empty())
     {
          pkt8 status_pkt = s_axis_tcp_port_status.read();
          bool success = status_pkt.data(0, 0);
          if (success)
          {
               portOpened = true;
          }
          else
          {
               // не открылось — просим снова на следующем такте
               portRequested = false;
          }
     }
}

/*
 * Приём уведомлений: см. echo_rx_notify в hls_echo_krnl.cpp — логика
 * без изменений, продублирована по той же причине, что и listen выше.
 */
void dual_echo_rx_notify(hls::stream<pkt128>& s_axis_tcp_notification,
                         hls::stream<pkt32>& m_axis_tcp_read_pkg,
                         hls::stream<ap_uint<16> >& rxSessionFifo,
                         hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     if (s_axis_tcp_notification.empty())
          return;

     if (rxSessionFifo.full() || rxLengthFifo.full())
          return;

     pkt128 notification_pkt = s_axis_tcp_notification.read();
     ap_uint<16> sessionID = notification_pkt.data(15, 0);
     ap_uint<16> length    = notification_pkt.data(31, 16);

     if (length != 0)
     {
          pkt32 readRequest_pkt;
          readRequest_pkt.data = 0;
          readRequest_pkt.data(15, 0)  = sessionID;
          readRequest_pkt.data(31, 16) = length;
          m_axis_tcp_read_pkg.write(readRequest_pkt);

          rxSessionFifo.write(sessionID);
          rxLengthFifo.write(length);
     }
}

/*
 * Вычитывает пришедшие данные и выбрасывает. См. echo_rx_drain в
 * hls_echo_krnl.cpp — логика без изменений.
 */
void dual_echo_rx_drain(hls::stream<pkt16>& s_axis_tcp_rx_meta,
                        hls::stream<pkt512>& s_axis_tcp_rx_data,
                        hls::stream<ap_uint<16> >& rxSessionFifo,
                        hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum drainStateType {IDLE, FORWARD};
     static drainStateType drainState = IDLE;
#pragma HLS RESET variable=drainState

     switch (drainState)
     {
     case IDLE:
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty()
              && !s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               rxSessionFifo.read();
               rxLengthFifo.read();
               drainState = FORWARD;
          }
          break;

     case FORWARD:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();
               if (rx_word.last)
               {
                    drainState = IDLE;
               }
          }
          break;
     }
}

/*
 * Одна половина: слушает порт, поглощает данные на своём наборе
 * портов network_krnl. Вызывается два раза с независимыми именами
 * static-потоков (см. HLS STREAM variable= — влияет на итоговое имя
 * сигнала в RTL, поэтому суффикс _a/_b обязателен, иначе два вызова
 * получили бы одинаковые внутренние имена и синтез перепутал бы их
 * FIFO друг с другом).
 */
void dual_echo_half_a(hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status,
                      hls::stream<pkt128>& s_axis_tcp_notification,
                      hls::stream<pkt32>& m_axis_tcp_read_pkg,
                      hls::stream<pkt16>& s_axis_tcp_rx_meta,
                      hls::stream<pkt512>& s_axis_tcp_rx_data)
{
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     static hls::stream<ap_uint<16> > rxSessionFifo_a("rxSessionFifo_a");
     #pragma HLS STREAM variable=rxSessionFifo_a depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_a("rxLengthFifo_a");
     #pragma HLS STREAM variable=rxLengthFifo_a depth=512

     dual_echo_listen(m_axis_tcp_listen_port, s_axis_tcp_port_status);

     dual_echo_rx_notify(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                        rxSessionFifo_a, rxLengthFifo_a);

     dual_echo_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                       rxSessionFifo_a, rxLengthFifo_a);
}

void dual_echo_half_b(hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status,
                      hls::stream<pkt128>& s_axis_tcp_notification,
                      hls::stream<pkt32>& m_axis_tcp_read_pkg,
                      hls::stream<pkt16>& s_axis_tcp_rx_meta,
                      hls::stream<pkt512>& s_axis_tcp_rx_data)
{
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     static hls::stream<ap_uint<16> > rxSessionFifo_b("rxSessionFifo_b");
     #pragma HLS STREAM variable=rxSessionFifo_b depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_b("rxLengthFifo_b");
     #pragma HLS STREAM variable=rxLengthFifo_b depth=512

     dual_echo_listen(m_axis_tcp_listen_port, s_axis_tcp_port_status);

     dual_echo_rx_notify(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                        rxSessionFifo_b, rxLengthFifo_b);

     dual_echo_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                       rxSessionFifo_b, rxLengthFifo_b);
}

void dual_echo_core(
     // половина a (-> network_krnl_1, QSFP0)
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
     // половина b (-> network_krnl_2, QSFP1)
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
     hls::stream<pkt64>& s_axis_tcp_tx_status_b)
{
// INLINE ставить нельзя — HLS 214-272, как и в hls_echo_krnl.cpp.
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     dual_echo_half_a(m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a,
                      s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                      s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a);

     dual_echo_half_b(m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b,
                      s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                      s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b);

     // Заглушки на всё, что не используется — по одной на каждую
     // половину, неподключённый порт стека ломает сборку hw.
     tie_off_udp(s_axis_udp_rx_a, m_axis_udp_tx_a,
                 s_axis_udp_rx_meta_a, m_axis_udp_tx_meta_a);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection_a,
                                 s_axis_tcp_open_status_a);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_a);
     tie_off_tcp_tx(m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
                    s_axis_tcp_tx_status_a);

     tie_off_udp(s_axis_udp_rx_b, m_axis_udp_tx_b,
                 s_axis_udp_rx_meta_b, m_axis_udp_tx_meta_b);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection_b,
                                 s_axis_tcp_open_status_b);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_b);
     tie_off_tcp_tx(m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
                    s_axis_tcp_tx_status_b);
}

extern "C" {
void hls_dual_echo_krnl(
               // половина a — подключается к network_krnl_1 (QSFP0)
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

               // половина b — подключается к network_krnl_2 (QSFP1)
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
               hls::stream<pkt64>& s_axis_tcp_tx_status_b)
{
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

#pragma HLS INTERFACE ap_ctrl_none port = return

     dual_echo_core(s_axis_udp_rx_a, m_axis_udp_tx_a,
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
                    s_axis_tcp_tx_status_b);
}
}
