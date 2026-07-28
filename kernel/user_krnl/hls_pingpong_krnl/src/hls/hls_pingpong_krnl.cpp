/************************************************
TCP ping-pong (echo) kernel.

Слушает порт и отражает обратно всё, что получил, в ту же сессию.

Назначение — измерение задержки: клиент шлёт сообщение, замеряет
время до получения эха. Полученный RTT покрывает весь путь

    клиент -> NIC -> провод -> CMAC -> стек RX ->
    ЭТО ЯДРО -> стек TX -> CMAC -> провод -> NIC -> клиент

Ядро намеренно максимально простое, чтобы его вклад в задержку был
минимальным и вся измеренная величина относилась к стеку и сети.

Работает бесконечно (ap_ctrl_none), обслуживая одно подключение за
другим: sessionID берётся из каждого уведомления, поэтому переподключения
клиента подхватываются автоматически.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Максимальный размер сообщения в 64-байтных словах (64 * 64 = 4096 байт)
#define PP_MAX_WORDS 64

/*
 * Открывает listen-порт, повторяя запрос до подтверждения стека.
 */
void pp_listen(int listenPort,
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status)
{
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
}

/*
 * Echo-конвейер одним FSM.
 *
 * NOTIFY : пришло уведомление -> выставляем read request
 * META   : забираем rx_meta
 * RX     : читаем слова в буфер до флага last
 * REQ    : выставляем tx_meta на ту же длину и ту же сессию
 * STATUS : ждём подтверждения стека
 * TX     : отдаём буфер обратно
 *
 * Store-and-forward: сообщение принимается целиком, потом
 * отправляется. Иначе нельзя — стек требует знать длину до передачи.
 */
void pp_echo(hls::stream<pkt128>& s_axis_tcp_notification,
             hls::stream<pkt32>& m_axis_tcp_read_pkg,
             hls::stream<pkt16>& s_axis_tcp_rx_meta,
             hls::stream<pkt512>& s_axis_tcp_rx_data,
             hls::stream<pkt32>& m_axis_tcp_tx_meta,
             hls::stream<pkt512>& m_axis_tcp_tx_data,
             hls::stream<pkt64>& s_axis_tcp_tx_status)
{
#pragma HLS INLINE off

     enum ppStateType {NOTIFY, META, RX, REQ, STATUS, TX};
     static ppStateType ppState = NOTIFY;
#pragma HLS RESET variable=ppState

     static ap_uint<512> payload[PP_MAX_WORDS];
#pragma HLS BIND_STORAGE variable=payload type=RAM_2P impl=BRAM

     static ap_uint<16> sessionID = 0;
     static ap_uint<16> length = 0;
     static ap_uint<16> wordCount = 0;
     static ap_uint<16> wordIdx = 0;
     static ap_uint<16> bytesRemaining = 0;

     switch (ppState)
     {
     case NOTIFY:
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notification_pkt = s_axis_tcp_notification.read();
               ap_uint<16> notifLength = notification_pkt.data(31, 16);

               if (notifLength != 0)
               {
                    // sessionID берём из уведомления — так реконнекты
                    // клиента подхватываются без дополнительной логики
                    sessionID = notification_pkt.data(15, 0);
                    length = notifLength;

                    pkt32 readRequest_pkt;
                    readRequest_pkt.data(15, 0) = sessionID;
                    readRequest_pkt.data(31, 16) = length;
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
               }
               wordCount++;
               if (rx_word.last)
               {
                    ppState = REQ;
               }
          }
          break;

     case REQ:
     {
          pkt32 tx_meta_pkt;
          tx_meta_pkt.data(15, 0) = sessionID;
          tx_meta_pkt.data(31, 16) = length;
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
                    bytesRemaining = length;
                    ppState = TX;
               }
               else if (error == 1)
               {
                    // соединение разорвано — ждём следующего сообщения
                    ppState = NOTIFY;
               }
               else
               {
                    // нет места в буфере получателя — повторяем запрос
                    ppState = REQ;
               }
          }
          break;

     case TX:
     {
          pkt512 tx_word;
          tx_word.data = payload[wordIdx];

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
}

extern "C" {
void hls_pingpong_krnl(
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

               // Порт, который слушаем
               int listenPort
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
#pragma HLS INTERFACE ap_ctrl_none port = return

#pragma HLS PIPELINE II=1

     // Неиспользуемые интерфейсы
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx, s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection, s_axis_tcp_open_status);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);

     pp_listen(listenPort, m_axis_tcp_listen_port, s_axis_tcp_port_status);

     pp_echo(s_axis_tcp_notification, m_axis_tcp_read_pkg,
             s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
             m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
             s_axis_tcp_tx_status);
}
}
