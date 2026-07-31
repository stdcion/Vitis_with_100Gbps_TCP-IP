/************************************************
Минимальное ядро для проверки, что TCP на плате вообще работает.

ЗАЧЕМ. Прежде чем отлаживать логику гейтвея, надо убедиться в
работоспособности всей цепочки: CMAC поднял 100G-линк, стек ответил на
ARP, принял SYN и открыл сессию. Ядро для этого делает ровно одно —
слушает фиксированный порт и поглощает всё, что пришло.

КРИТЕРИЙ УСПЕХА — снаружи, без хоста и без JTAG:

    nc <ip> 7001      подключается и не отваливается
    ping <ip>         отвечает (ARP + ICMP обрабатывает стек сам)

Если nc соединяется — работают CMAC, ARP, TCP-handshake и таблица
сессий в DDR. Этого достаточно, чтобы переходить к настоящему ядру.

ОТЛИЧИЯ ОТ hls_ouch_krnl:
  - порт зашит константой (LISTEN_PORT), s_axilite-аргументов нет;
  - нет enable: ядро начинает работать сразу после сброса;
  - нет счётчиков: наблюдаемость — сам факт установленного соединения.

Отсутствие s_axilite здесь осознанно. У ouch-ядра параметры приходят с
хоста, и порядок их записи важен (см. комментарий про гонку с
ap_ctrl_none). Здесь записывать нечего, поэтому и гонки нет: ядро
самодостаточно с первого такта.

ЧТО ВСЁ РАВНО НАДО ЗАДАТЬ СНАРУЖИ: MAC и IP. Они живут не здесь, а в
network_krnl (регистры ip_addr/mac_addr/arp его s_axi_control), и зашить
их в это ядро нельзя — стек их читает из своих регистров. Записываются
один раз через JTAG, см. scripts/vivado/jtag_ctrl.tcl (network_configure).

НАБОР ПОРТОВ полный, как у ouch-ядра, и это обязательно: config_sp
перечисляет соединения со всеми портами network_krnl, а неподключённый
порт стека ломает сборку. Неиспользуемое заглушено через tie_off_*.

Идиомы те же, что в hls_ouch_krnl (проверены синтезом, II=1):
топ вызывает *_core с DATAFLOW, каждая стадия — отдельная функция с
PIPELINE II=1 и INLINE off, состояние в static с RESET, в каждый
выходной поток пишет ровно одна функция.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Порт, который слушаем. Менять здесь и пересобирать — на то оно и
// минимальное ядро.
#define LISTEN_PORT 7001

/*
 * Открывает listen-порт и держит его.
 *
 * Пишет номер порта в m_axis_tcp_listen_port и ждёт подтверждения в
 * s_axis_tcp_port_status. Если стек ответил неуспехом — пробует снова.
 */
void echo_listen(hls::stream<pkt16>& m_axis_tcp_listen_port,
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
 * Приём уведомлений: стек сообщает, что в сессии появились данные.
 * В ответ выставляем read request и передаём следующей стадии, сколько
 * слов предстоит вычитать.
 *
 * Две стадии, а не одна: пока идёт передача, уведомления копятся, и если
 * совместить их приём с чтением данных, стек упрётся в backpressure.
 *
 * Уведомление ЗАБИРАЕТСЯ из потока только когда оба FIFO готовы принять
 * запись — иначе стадия встанет на блокирующем write и получится дедлок.
 */
void echo_rx_notify(hls::stream<pkt128>& s_axis_tcp_notification,
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
 * Вычитывает пришедшие данные и выбрасывает.
 *
 * Выбрасывать ОБЯЗАТЕЛЬНО: если запросить данные read-request'ом и не
 * вычитать их из rx_data, шина заполнится и стек встанет — соединение
 * повиснет, и проверка ничего не покажет. То есть «слив» здесь не
 * заглушка, а необходимая работа.
 *
 * Выйти из FORWARD на полпути нельзя: слова одной порции идут непрерывно
 * до last, и чтение следующей порции сместит границы.
 */
void echo_rx_drain(hls::stream<pkt16>& s_axis_tcp_rx_meta,
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
          // rx_meta приходит на каждую порцию; здесь он не нужен, но
          // вычитать его обязательно, иначе поток забьётся.
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

void echo_core(hls::stream<pkt512>& s_axis_udp_rx,
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
               hls::stream<pkt64>& s_axis_tcp_tx_status)
{
// INLINE ставить нельзя — HLS 214-272: INLINE и DATAFLOW на одной
// функции допустимы только при инлайне во внешний dataflow-регион.
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     static hls::stream<ap_uint<16> > rxSessionFifo("rxSessionFifo");
     #pragma HLS STREAM variable=rxSessionFifo depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo("rxLengthFifo");
     #pragma HLS STREAM variable=rxLengthFifo depth=512

     echo_listen(m_axis_tcp_listen_port, s_axis_tcp_port_status);

     echo_rx_notify(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                    rxSessionFifo, rxLengthFifo);

     echo_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                   rxSessionFifo, rxLengthFifo);

     // Заглушки на всё, что не используется: неподключённый порт стека
     // ломает сборку hw.
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx,
                 s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection,
                                 s_axis_tcp_open_status);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);
     tie_off_tcp_tx(m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                    s_axis_tcp_tx_status);
}

extern "C" {
void hls_echo_krnl(
               // UDP — не используется, но интерфейс обязателен
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
               hls::stream<pkt64>& s_axis_tcp_tx_status)
{
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
#pragma HLS INTERFACE ap_ctrl_none port = return

     echo_core(s_axis_udp_rx, m_axis_udp_tx,
               s_axis_udp_rx_meta, m_axis_udp_tx_meta,
               m_axis_tcp_listen_port, s_axis_tcp_port_status,
               m_axis_tcp_open_connection, s_axis_tcp_open_status,
               m_axis_tcp_close_connection,
               s_axis_tcp_notification, m_axis_tcp_read_pkg,
               s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
               m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
               s_axis_tcp_tx_status);
}
}
