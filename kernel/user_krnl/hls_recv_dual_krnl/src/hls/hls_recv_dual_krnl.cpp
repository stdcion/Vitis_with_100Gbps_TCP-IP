/*
 * Copyright (c) 2020, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 * 3. Neither the name of the copyright holder nor the names of its contributors
 * may be used to endorse or promote products derived from this software
 * without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
/************************************************
ШАГ 3 ЛЕСТНИЦЫ: listenPorts + recvData НА ОБЕИХ ПОЛОВИНАХ.

Отличие от шага 1 -- РОВНО ОДНО: шесть заглушек канала b заменены на те же
listenPorts() и recvData() из communication.hpp, что стоят на канале a.
Портов столько же (32), схема та же, BD тот же. Меняется только то, ЧТО
подключено к портам канала b: вместо tie_off_* -- рабочая логика эталона.

ЭТО ЦЕЛЬ ВСЕЙ ЛЕСТНИЦЫ: dual-QSFP ядро БЕЗ ЕДИНОЙ СВОЕЙ СТАДИИ. Если оно
работает, значит два QSFP на upstream-логике достижимы, и остаётся выяснить,
какая из пяти своих стадий dual_echo ломает дело (шаг 4).

ПОЧЕМУ ДВА ВЫЗОВА ОДНИХ И ТЕХ ЖЕ ФУНКЦИЙ БЕЗОПАСНЫ. Проверено по коду, а не
предположено: ни в listen_port_handler, ни в port_status_handler, ни в
recvData_handshake, ни в recvData_consumeData НЕТ ни одной static-переменной.
Единственный static в listenPorts закомментирован (communication.hpp:728),
живой success_open_port -- обычный int. FIFO nextRxPacketLength внутри
recvData объявлен БЕЗ static, то есть на каждый вызов создаётся свой.

Это важно: static в функции, вызванной дважды в DATAFLOW, дал бы
HLS 200-471 feedback dependence -- ровно то, на чём мы спотыкались в
dual_echo_publish. Здесь этого нет по построению.

ПОРТЫ И ПАРАМЕТРЫ. basePort/useConn/expectedRxByteCnt -- ОБЩИЕ на оба
канала, отдельных регистров для b не добавлено. Значит обе половины слушают
ОДИН И ТОТ ЖЕ порт basePort, но на РАЗНЫХ network_krnl, то есть на разных
IP -- конфликта нет, это две независимые сессии.

  оба канала соединяются  -> dual-QSFP на upstream РАБОТАЕТ, идём на шаг 4
  a работает, b молчит    -> дефект в самом факте двух слушающих половин,
                             а не в нашей логике: сравнить с шагом 1, где
                             b был на заглушках и a работал
  оба молчат              -> регион с 12 живыми стадиями встал; сверить
                             ap_sync_done: если в списке есть recvData_U0,
                             барьер мёртв и причина в другом

ВТОРОЙ network_krnl В BD СТАВИТСЯ, НО НЕ СТАРТУЕТ, и кабель в QSFP1 не
втыкается (ресурс перетыканий ограничен, см. ограничения стенда). Для
вопроса "сломали или нет" активный второй канал не нужен -- нужно, чтобы он
физически присутствовал в дизайне.

ЛОВУШКА, ПРО КОТОРУЮ НАДО ЗНАТЬ ЗАРАНЕЕ. Заглушки -- это ТОЖЕ стадии
DATAFLOW-региона. Было 6, стало 11. Если шаг 1 даст тишину, это ещё не
приговор схеме: причиной может быть разросшийся регион, потому что
ap_sync_done -- это И по ap_done ВСЕХ стадий (видно в
hls_dual_echo_krnl_dual_echo_core.v:1347). Различается одной командой на
сгенерированном RTL:

    grep -n "_U0_ap_continue = " \
      src/hls/hls_recv_dual_krnl_ip_proj/sol1/syn/verilog/hls_recv_dual_krnl.v

Единица (как у dual_echo) -> барьер никого не держит, обвинение схемы честное.

ИМЕНА ПОРТОВ: канал a БЕЗ суффикса -- чтобы диff с hls_recv_krnl оставался
минимальным и config_sp канала a совпадал с рабочим построчно. Канал b с
суффиксом _b, как у dual_echo.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h" 
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"


extern "C" {
void hls_recv_dual_krnl(
               // Internal Stream
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
               // ── канал b -> network_krnl_2 (QSFP1): ТОЛЬКО заглушки ──
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
               ap_uint<64> expectedRxByteCnt
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
#pragma HLS INTERFACE s_axilite port = return bundle = control

static hls::stream<ap_uint<512> >    s_data_out;
#pragma HLS STREAM variable=s_data_out depth=512

#pragma HLS dataflow

          ap_uint<16> sessionTable [32];
          int pkgWordCount = 16;
          
          listenPorts (basePort, useConn, m_axis_tcp_listen_port, 
               s_axis_tcp_port_status);

          recvData(expectedRxByteCnt, 
               s_axis_tcp_notification, 
               m_axis_tcp_read_pkg, 
               s_axis_tcp_rx_meta, 
               s_axis_tcp_rx_data);

          tie_off_tcp_open_connection(m_axis_tcp_open_connection, 
               s_axis_tcp_open_status);


          tie_off_tcp_tx(m_axis_tcp_tx_meta, 
                         m_axis_tcp_tx_data, 
                         s_axis_tcp_tx_status);

          tie_off_udp(s_axis_udp_rx, 
               m_axis_udp_tx, 
               s_axis_udp_rx_meta, 
               m_axis_udp_tx_meta);
    
          tie_off_tcp_close_con(m_axis_tcp_close_connection);

          // ── канал b: ТЕ ЖЕ стадии, что на канале a ─────────────────
          //
          // Заглушек здесь больше нет у listen/rx: канал b теперь слушает и
          // принимает сам. Остались только те tie_off_*, что и на канале a --
          // open_connection, tx и close_con: recv никогда не подключается сам
          // и ничего не отправляет, это чистый приёмник.
          //
          // Аргументы -- порты с суффиксом _b, всё остальное дословно как
          // выше. Никаких "b-специфичных" параметров нет намеренно: чем
          // меньше различий между половинами, тем однозначнее результат.
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