// =============================================================================
// tb_core_ap_done -- КТО из 14 стадий не выдаёт ap_done
// =============================================================================
//
// ЧТО ЭТО ПРОВЕРЯЕТ. tb_listen_start доказал МЕХАНИЗМ отказа: ap_continue стадии
// в dual_echo_core равен ap_sync_done -- логическому И по ap_done ВСЕХ 14 стадий
// (core.v:1337). Одна стадия, не выставившая ap_done, замораживает остальные
// после единственного прохода, и при позднем enable порт не запрашивается вообще
// (фаза 7 там воспроизвела лог платы дословно: att=0, state=0).
//
// Но виновная стадия там НЕ БЫЛА НАЗВАНА: ap_continue подавался моделью
// (ap_done & other_stages_done), а не настоящей логикой региона. Здесь
// инстанцируется ВЕСЬ dual_echo_core со всеми 14 стадиями, и ap_done каждой
// читается иерархически. Тест печатает таблицу «кто готов, кто нет».
//
// ПОЧЕМУ ЭТО НЕ ПОВТОРЕНИЕ. tb_listen_start отвечал «что ломает», этот отвечает
// «кто ломает» -- то есть что именно править в .cpp.
//
// СГЕНЕРИРОВАН СКРИПТОМ (см. историю коммита): 219 портов, из них
// осмысленных для теста около двадцати. Руками такой список не поддерживается, а
// ошибка в имени порта дала бы молча неподключённый вход.
//
// УСЛОВИЯ -- ЛУЧШЕ, ЧЕМ НА ПЛАТЕ, И ЭТО НАМЕРЕННО:
//   * enable=1 и listenPort заданы с нулевого такта (на плате -- через десятки
//     секунд по JTAG);
//   * все m_axis_*_TREADY = 1: стек принимает всё немедленно;
//   * все s_axis_*_TVALID = 0: стек молчит -- как на плате, где порт не открылся.
// Если при таких условиях регион встаёт, то на плате тем более.
//
// ЧЕГО НЕ ПРОВЕРЯЕТ: тайминг (это impl) и поведение TOE (это плата).
//
// Сообщения на латинице: $display в xsim 2024.1 портит многобайтовые символы.

`timescale 1ns / 1ps
`default_nettype none

module tb_core_ap_done;

logic ap_clk = 1'b0;
always #2.5 ap_clk = ~ap_clk;

logic ap_rst = 1'b1;          // core ждёт АКТИВНЫЙ-ВЫСОКИЙ сброс

// ── управление региона: как в топе ───────────────────────────────────────────
// hls_dual_echo_krnl.v:777-779 -- ap_start и ap_continue региона зашиты в 1'b1,
// потому что ядро объявлено ap_ctrl_none. Воспроизводим буквально.
logic ap_start    = 1'b1;
logic ap_continue = 1'b1;
wire  ap_done, ap_idle, ap_ready;

// ── скаляры ──────────────────────────────────────────────────────────────────
logic [31:0] enableA     = 32'd1;
logic [31:0] enableB     = 32'd1;
logic [31:0] listenPortA = 32'd7001;
logic [31:0] listenPortB = 32'd7002;

// ── входы-стримы ─────────────────────────────────────────────────────────────
// TVALID=0: стек молчит. TREADY=1: стек принимает всё немедленно.
// Данные -- нули: они не читаются, потому что TVALID=0.
logic [511:0] s_axis_udp_rx_a_TDATA = 512'd0;
logic [63:0] s_axis_udp_rx_a_TKEEP = 64'd0;
logic [63:0] s_axis_udp_rx_a_TSTRB = 64'd0;
logic [0:0] s_axis_udp_rx_a_TLAST = 1'd0;
logic [255:0] s_axis_udp_rx_meta_a_TDATA = 256'd0;
logic [31:0] s_axis_udp_rx_meta_a_TKEEP = 32'd0;
logic [31:0] s_axis_udp_rx_meta_a_TSTRB = 32'd0;
logic [0:0] s_axis_udp_rx_meta_a_TLAST = 1'd0;
logic [7:0] s_axis_tcp_port_status_a_TDATA = 8'd0;
logic [0:0] s_axis_tcp_port_status_a_TKEEP = 1'd0;
logic [0:0] s_axis_tcp_port_status_a_TSTRB = 1'd0;
logic [0:0] s_axis_tcp_port_status_a_TLAST = 1'd0;
logic [127:0] s_axis_tcp_open_status_a_TDATA = 128'd0;
logic [15:0] s_axis_tcp_open_status_a_TKEEP = 16'd0;
logic [15:0] s_axis_tcp_open_status_a_TSTRB = 16'd0;
logic [0:0] s_axis_tcp_open_status_a_TLAST = 1'd0;
logic [127:0] s_axis_tcp_notification_a_TDATA = 128'd0;
logic [15:0] s_axis_tcp_notification_a_TKEEP = 16'd0;
logic [15:0] s_axis_tcp_notification_a_TSTRB = 16'd0;
logic [0:0] s_axis_tcp_notification_a_TLAST = 1'd0;
logic [15:0] s_axis_tcp_rx_meta_a_TDATA = 16'd0;
logic [1:0] s_axis_tcp_rx_meta_a_TKEEP = 2'd0;
logic [1:0] s_axis_tcp_rx_meta_a_TSTRB = 2'd0;
logic [0:0] s_axis_tcp_rx_meta_a_TLAST = 1'd0;
logic [511:0] s_axis_tcp_rx_data_a_TDATA = 512'd0;
logic [63:0] s_axis_tcp_rx_data_a_TKEEP = 64'd0;
logic [63:0] s_axis_tcp_rx_data_a_TSTRB = 64'd0;
logic [0:0] s_axis_tcp_rx_data_a_TLAST = 1'd0;
logic [63:0] s_axis_tcp_tx_status_a_TDATA = 64'd0;
logic [7:0] s_axis_tcp_tx_status_a_TKEEP = 8'd0;
logic [7:0] s_axis_tcp_tx_status_a_TSTRB = 8'd0;
logic [0:0] s_axis_tcp_tx_status_a_TLAST = 1'd0;
logic [511:0] s_axis_udp_rx_b_TDATA = 512'd0;
logic [63:0] s_axis_udp_rx_b_TKEEP = 64'd0;
logic [63:0] s_axis_udp_rx_b_TSTRB = 64'd0;
logic [0:0] s_axis_udp_rx_b_TLAST = 1'd0;
logic [255:0] s_axis_udp_rx_meta_b_TDATA = 256'd0;
logic [31:0] s_axis_udp_rx_meta_b_TKEEP = 32'd0;
logic [31:0] s_axis_udp_rx_meta_b_TSTRB = 32'd0;
logic [0:0] s_axis_udp_rx_meta_b_TLAST = 1'd0;
logic [7:0] s_axis_tcp_port_status_b_TDATA = 8'd0;
logic [0:0] s_axis_tcp_port_status_b_TKEEP = 1'd0;
logic [0:0] s_axis_tcp_port_status_b_TSTRB = 1'd0;
logic [0:0] s_axis_tcp_port_status_b_TLAST = 1'd0;
logic [127:0] s_axis_tcp_open_status_b_TDATA = 128'd0;
logic [15:0] s_axis_tcp_open_status_b_TKEEP = 16'd0;
logic [15:0] s_axis_tcp_open_status_b_TSTRB = 16'd0;
logic [0:0] s_axis_tcp_open_status_b_TLAST = 1'd0;
logic [127:0] s_axis_tcp_notification_b_TDATA = 128'd0;
logic [15:0] s_axis_tcp_notification_b_TKEEP = 16'd0;
logic [15:0] s_axis_tcp_notification_b_TSTRB = 16'd0;
logic [0:0] s_axis_tcp_notification_b_TLAST = 1'd0;
logic [15:0] s_axis_tcp_rx_meta_b_TDATA = 16'd0;
logic [1:0] s_axis_tcp_rx_meta_b_TKEEP = 2'd0;
logic [1:0] s_axis_tcp_rx_meta_b_TSTRB = 2'd0;
logic [0:0] s_axis_tcp_rx_meta_b_TLAST = 1'd0;
logic [511:0] s_axis_tcp_rx_data_b_TDATA = 512'd0;
logic [63:0] s_axis_tcp_rx_data_b_TKEEP = 64'd0;
logic [63:0] s_axis_tcp_rx_data_b_TSTRB = 64'd0;
logic [0:0] s_axis_tcp_rx_data_b_TLAST = 1'd0;
logic [63:0] s_axis_tcp_tx_status_b_TDATA = 64'd0;
logic [7:0] s_axis_tcp_tx_status_b_TKEEP = 8'd0;
logic [7:0] s_axis_tcp_tx_status_b_TSTRB = 8'd0;
logic [0:0] s_axis_tcp_tx_status_b_TLAST = 1'd0;
logic m_axis_tcp_listen_port_a_TREADY = 1'b1;
logic s_axis_tcp_port_status_a_TVALID = 1'b0;
logic s_axis_tcp_notification_a_TVALID = 1'b0;
logic m_axis_tcp_read_pkg_a_TREADY = 1'b1;
logic s_axis_tcp_rx_meta_a_TVALID = 1'b0;
logic s_axis_tcp_rx_data_a_TVALID = 1'b0;
logic m_axis_tcp_listen_port_b_TREADY = 1'b1;
logic s_axis_tcp_port_status_b_TVALID = 1'b0;
logic s_axis_tcp_notification_b_TVALID = 1'b0;
logic m_axis_tcp_read_pkg_b_TREADY = 1'b1;
logic s_axis_tcp_rx_meta_b_TVALID = 1'b0;
logic s_axis_tcp_rx_data_b_TVALID = 1'b0;
logic s_axis_udp_rx_a_TVALID = 1'b0;
logic m_axis_udp_tx_a_TREADY = 1'b1;
logic s_axis_udp_rx_meta_a_TVALID = 1'b0;
logic m_axis_udp_tx_meta_a_TREADY = 1'b1;
logic m_axis_tcp_open_connection_a_TREADY = 1'b1;
logic s_axis_tcp_open_status_a_TVALID = 1'b0;
logic m_axis_tcp_close_connection_a_TREADY = 1'b1;
logic m_axis_tcp_tx_meta_a_TREADY = 1'b1;
logic m_axis_tcp_tx_data_a_TREADY = 1'b1;
logic s_axis_tcp_tx_status_a_TVALID = 1'b0;
logic s_axis_udp_rx_b_TVALID = 1'b0;
logic m_axis_udp_tx_b_TREADY = 1'b1;
logic s_axis_udp_rx_meta_b_TVALID = 1'b0;
logic m_axis_udp_tx_meta_b_TREADY = 1'b1;
logic m_axis_tcp_open_connection_b_TREADY = 1'b1;
logic s_axis_tcp_open_status_b_TVALID = 1'b0;
logic m_axis_tcp_close_connection_b_TREADY = 1'b1;
logic m_axis_tcp_tx_meta_b_TREADY = 1'b1;
logic m_axis_tcp_tx_data_b_TREADY = 1'b1;
logic s_axis_tcp_tx_status_b_TVALID = 1'b0;

// ── выходы ───────────────────────────────────────────────────────────────────
wire [511:0] m_axis_udp_tx_a_TDATA;
wire [63:0] m_axis_udp_tx_a_TKEEP;
wire [63:0] m_axis_udp_tx_a_TSTRB;
wire [0:0] m_axis_udp_tx_a_TLAST;
wire [255:0] m_axis_udp_tx_meta_a_TDATA;
wire [31:0] m_axis_udp_tx_meta_a_TKEEP;
wire [31:0] m_axis_udp_tx_meta_a_TSTRB;
wire [0:0] m_axis_udp_tx_meta_a_TLAST;
wire [15:0] m_axis_tcp_listen_port_a_TDATA;
wire [1:0] m_axis_tcp_listen_port_a_TKEEP;
wire [1:0] m_axis_tcp_listen_port_a_TSTRB;
wire [0:0] m_axis_tcp_listen_port_a_TLAST;
wire [63:0] m_axis_tcp_open_connection_a_TDATA;
wire [7:0] m_axis_tcp_open_connection_a_TKEEP;
wire [7:0] m_axis_tcp_open_connection_a_TSTRB;
wire [0:0] m_axis_tcp_open_connection_a_TLAST;
wire [15:0] m_axis_tcp_close_connection_a_TDATA;
wire [1:0] m_axis_tcp_close_connection_a_TKEEP;
wire [1:0] m_axis_tcp_close_connection_a_TSTRB;
wire [0:0] m_axis_tcp_close_connection_a_TLAST;
wire [31:0] m_axis_tcp_read_pkg_a_TDATA;
wire [3:0] m_axis_tcp_read_pkg_a_TKEEP;
wire [3:0] m_axis_tcp_read_pkg_a_TSTRB;
wire [0:0] m_axis_tcp_read_pkg_a_TLAST;
wire [31:0] m_axis_tcp_tx_meta_a_TDATA;
wire [3:0] m_axis_tcp_tx_meta_a_TKEEP;
wire [3:0] m_axis_tcp_tx_meta_a_TSTRB;
wire [0:0] m_axis_tcp_tx_meta_a_TLAST;
wire [511:0] m_axis_tcp_tx_data_a_TDATA;
wire [63:0] m_axis_tcp_tx_data_a_TKEEP;
wire [63:0] m_axis_tcp_tx_data_a_TSTRB;
wire [0:0] m_axis_tcp_tx_data_a_TLAST;
wire [511:0] m_axis_udp_tx_b_TDATA;
wire [63:0] m_axis_udp_tx_b_TKEEP;
wire [63:0] m_axis_udp_tx_b_TSTRB;
wire [0:0] m_axis_udp_tx_b_TLAST;
wire [255:0] m_axis_udp_tx_meta_b_TDATA;
wire [31:0] m_axis_udp_tx_meta_b_TKEEP;
wire [31:0] m_axis_udp_tx_meta_b_TSTRB;
wire [0:0] m_axis_udp_tx_meta_b_TLAST;
wire [15:0] m_axis_tcp_listen_port_b_TDATA;
wire [1:0] m_axis_tcp_listen_port_b_TKEEP;
wire [1:0] m_axis_tcp_listen_port_b_TSTRB;
wire [0:0] m_axis_tcp_listen_port_b_TLAST;
wire [63:0] m_axis_tcp_open_connection_b_TDATA;
wire [7:0] m_axis_tcp_open_connection_b_TKEEP;
wire [7:0] m_axis_tcp_open_connection_b_TSTRB;
wire [0:0] m_axis_tcp_open_connection_b_TLAST;
wire [15:0] m_axis_tcp_close_connection_b_TDATA;
wire [1:0] m_axis_tcp_close_connection_b_TKEEP;
wire [1:0] m_axis_tcp_close_connection_b_TSTRB;
wire [0:0] m_axis_tcp_close_connection_b_TLAST;
wire [31:0] m_axis_tcp_read_pkg_b_TDATA;
wire [3:0] m_axis_tcp_read_pkg_b_TKEEP;
wire [3:0] m_axis_tcp_read_pkg_b_TSTRB;
wire [0:0] m_axis_tcp_read_pkg_b_TLAST;
wire [31:0] m_axis_tcp_tx_meta_b_TDATA;
wire [3:0] m_axis_tcp_tx_meta_b_TKEEP;
wire [3:0] m_axis_tcp_tx_meta_b_TSTRB;
wire [0:0] m_axis_tcp_tx_meta_b_TLAST;
wire [511:0] m_axis_tcp_tx_data_b_TDATA;
wire [63:0] m_axis_tcp_tx_data_b_TKEEP;
wire [63:0] m_axis_tcp_tx_data_b_TSTRB;
wire [0:0] m_axis_tcp_tx_data_b_TLAST;
wire m_axis_tcp_listen_port_a_TVALID;
wire s_axis_tcp_port_status_a_TREADY;
wire s_axis_tcp_notification_a_TREADY;
wire m_axis_tcp_read_pkg_a_TVALID;
wire s_axis_tcp_rx_meta_a_TREADY;
wire s_axis_tcp_rx_data_a_TREADY;
wire m_axis_tcp_listen_port_b_TVALID;
wire s_axis_tcp_port_status_b_TREADY;
wire s_axis_tcp_notification_b_TREADY;
wire m_axis_tcp_read_pkg_b_TVALID;
wire s_axis_tcp_rx_meta_b_TREADY;
wire s_axis_tcp_rx_data_b_TREADY;
wire s_axis_udp_rx_a_TREADY;
wire m_axis_udp_tx_a_TVALID;
wire s_axis_udp_rx_meta_a_TREADY;
wire m_axis_udp_tx_meta_a_TVALID;
wire m_axis_tcp_open_connection_a_TVALID;
wire s_axis_tcp_open_status_a_TREADY;
wire m_axis_tcp_close_connection_a_TVALID;
wire m_axis_tcp_tx_meta_a_TVALID;
wire m_axis_tcp_tx_data_a_TVALID;
wire s_axis_tcp_tx_status_a_TREADY;
wire s_axis_udp_rx_b_TREADY;
wire m_axis_udp_tx_b_TVALID;
wire s_axis_udp_rx_meta_b_TREADY;
wire m_axis_udp_tx_meta_b_TVALID;
wire m_axis_tcp_open_connection_b_TVALID;
wire s_axis_tcp_open_status_b_TREADY;
wire m_axis_tcp_close_connection_b_TVALID;
wire m_axis_tcp_tx_meta_b_TVALID;
wire m_axis_tcp_tx_data_b_TVALID;
wire s_axis_tcp_tx_status_b_TREADY;
wire [31:0] listenAttempts_a;
wire [31:0] portState_a;
wire [31:0] notifyCount_a;
wire [31:0] listenAttempts_b;
wire [31:0] portState_b;
wire [31:0] notifyCount_b;
wire listenAttempts_a_ap_vld;
wire portState_a_ap_vld;
wire notifyCount_a_ap_vld;
wire listenAttempts_b_ap_vld;
wire portState_b_ap_vld;
wire notifyCount_b_ap_vld;

// ── регион целиком ───────────────────────────────────────────────────────────
hls_dual_echo_krnl_dual_echo_core dut (
     .s_axis_udp_rx_a_TDATA(s_axis_udp_rx_a_TDATA),
     .s_axis_udp_rx_a_TKEEP(s_axis_udp_rx_a_TKEEP),
     .s_axis_udp_rx_a_TSTRB(s_axis_udp_rx_a_TSTRB),
     .s_axis_udp_rx_a_TLAST(s_axis_udp_rx_a_TLAST),
     .m_axis_udp_tx_a_TDATA(m_axis_udp_tx_a_TDATA),
     .m_axis_udp_tx_a_TKEEP(m_axis_udp_tx_a_TKEEP),
     .m_axis_udp_tx_a_TSTRB(m_axis_udp_tx_a_TSTRB),
     .m_axis_udp_tx_a_TLAST(m_axis_udp_tx_a_TLAST),
     .s_axis_udp_rx_meta_a_TDATA(s_axis_udp_rx_meta_a_TDATA),
     .s_axis_udp_rx_meta_a_TKEEP(s_axis_udp_rx_meta_a_TKEEP),
     .s_axis_udp_rx_meta_a_TSTRB(s_axis_udp_rx_meta_a_TSTRB),
     .s_axis_udp_rx_meta_a_TLAST(s_axis_udp_rx_meta_a_TLAST),
     .m_axis_udp_tx_meta_a_TDATA(m_axis_udp_tx_meta_a_TDATA),
     .m_axis_udp_tx_meta_a_TKEEP(m_axis_udp_tx_meta_a_TKEEP),
     .m_axis_udp_tx_meta_a_TSTRB(m_axis_udp_tx_meta_a_TSTRB),
     .m_axis_udp_tx_meta_a_TLAST(m_axis_udp_tx_meta_a_TLAST),
     .m_axis_tcp_listen_port_a_TDATA(m_axis_tcp_listen_port_a_TDATA),
     .m_axis_tcp_listen_port_a_TKEEP(m_axis_tcp_listen_port_a_TKEEP),
     .m_axis_tcp_listen_port_a_TSTRB(m_axis_tcp_listen_port_a_TSTRB),
     .m_axis_tcp_listen_port_a_TLAST(m_axis_tcp_listen_port_a_TLAST),
     .s_axis_tcp_port_status_a_TDATA(s_axis_tcp_port_status_a_TDATA),
     .s_axis_tcp_port_status_a_TKEEP(s_axis_tcp_port_status_a_TKEEP),
     .s_axis_tcp_port_status_a_TSTRB(s_axis_tcp_port_status_a_TSTRB),
     .s_axis_tcp_port_status_a_TLAST(s_axis_tcp_port_status_a_TLAST),
     .m_axis_tcp_open_connection_a_TDATA(m_axis_tcp_open_connection_a_TDATA),
     .m_axis_tcp_open_connection_a_TKEEP(m_axis_tcp_open_connection_a_TKEEP),
     .m_axis_tcp_open_connection_a_TSTRB(m_axis_tcp_open_connection_a_TSTRB),
     .m_axis_tcp_open_connection_a_TLAST(m_axis_tcp_open_connection_a_TLAST),
     .s_axis_tcp_open_status_a_TDATA(s_axis_tcp_open_status_a_TDATA),
     .s_axis_tcp_open_status_a_TKEEP(s_axis_tcp_open_status_a_TKEEP),
     .s_axis_tcp_open_status_a_TSTRB(s_axis_tcp_open_status_a_TSTRB),
     .s_axis_tcp_open_status_a_TLAST(s_axis_tcp_open_status_a_TLAST),
     .m_axis_tcp_close_connection_a_TDATA(m_axis_tcp_close_connection_a_TDATA),
     .m_axis_tcp_close_connection_a_TKEEP(m_axis_tcp_close_connection_a_TKEEP),
     .m_axis_tcp_close_connection_a_TSTRB(m_axis_tcp_close_connection_a_TSTRB),
     .m_axis_tcp_close_connection_a_TLAST(m_axis_tcp_close_connection_a_TLAST),
     .s_axis_tcp_notification_a_TDATA(s_axis_tcp_notification_a_TDATA),
     .s_axis_tcp_notification_a_TKEEP(s_axis_tcp_notification_a_TKEEP),
     .s_axis_tcp_notification_a_TSTRB(s_axis_tcp_notification_a_TSTRB),
     .s_axis_tcp_notification_a_TLAST(s_axis_tcp_notification_a_TLAST),
     .m_axis_tcp_read_pkg_a_TDATA(m_axis_tcp_read_pkg_a_TDATA),
     .m_axis_tcp_read_pkg_a_TKEEP(m_axis_tcp_read_pkg_a_TKEEP),
     .m_axis_tcp_read_pkg_a_TSTRB(m_axis_tcp_read_pkg_a_TSTRB),
     .m_axis_tcp_read_pkg_a_TLAST(m_axis_tcp_read_pkg_a_TLAST),
     .s_axis_tcp_rx_meta_a_TDATA(s_axis_tcp_rx_meta_a_TDATA),
     .s_axis_tcp_rx_meta_a_TKEEP(s_axis_tcp_rx_meta_a_TKEEP),
     .s_axis_tcp_rx_meta_a_TSTRB(s_axis_tcp_rx_meta_a_TSTRB),
     .s_axis_tcp_rx_meta_a_TLAST(s_axis_tcp_rx_meta_a_TLAST),
     .s_axis_tcp_rx_data_a_TDATA(s_axis_tcp_rx_data_a_TDATA),
     .s_axis_tcp_rx_data_a_TKEEP(s_axis_tcp_rx_data_a_TKEEP),
     .s_axis_tcp_rx_data_a_TSTRB(s_axis_tcp_rx_data_a_TSTRB),
     .s_axis_tcp_rx_data_a_TLAST(s_axis_tcp_rx_data_a_TLAST),
     .m_axis_tcp_tx_meta_a_TDATA(m_axis_tcp_tx_meta_a_TDATA),
     .m_axis_tcp_tx_meta_a_TKEEP(m_axis_tcp_tx_meta_a_TKEEP),
     .m_axis_tcp_tx_meta_a_TSTRB(m_axis_tcp_tx_meta_a_TSTRB),
     .m_axis_tcp_tx_meta_a_TLAST(m_axis_tcp_tx_meta_a_TLAST),
     .m_axis_tcp_tx_data_a_TDATA(m_axis_tcp_tx_data_a_TDATA),
     .m_axis_tcp_tx_data_a_TKEEP(m_axis_tcp_tx_data_a_TKEEP),
     .m_axis_tcp_tx_data_a_TSTRB(m_axis_tcp_tx_data_a_TSTRB),
     .m_axis_tcp_tx_data_a_TLAST(m_axis_tcp_tx_data_a_TLAST),
     .s_axis_tcp_tx_status_a_TDATA(s_axis_tcp_tx_status_a_TDATA),
     .s_axis_tcp_tx_status_a_TKEEP(s_axis_tcp_tx_status_a_TKEEP),
     .s_axis_tcp_tx_status_a_TSTRB(s_axis_tcp_tx_status_a_TSTRB),
     .s_axis_tcp_tx_status_a_TLAST(s_axis_tcp_tx_status_a_TLAST),
     .s_axis_udp_rx_b_TDATA(s_axis_udp_rx_b_TDATA),
     .s_axis_udp_rx_b_TKEEP(s_axis_udp_rx_b_TKEEP),
     .s_axis_udp_rx_b_TSTRB(s_axis_udp_rx_b_TSTRB),
     .s_axis_udp_rx_b_TLAST(s_axis_udp_rx_b_TLAST),
     .m_axis_udp_tx_b_TDATA(m_axis_udp_tx_b_TDATA),
     .m_axis_udp_tx_b_TKEEP(m_axis_udp_tx_b_TKEEP),
     .m_axis_udp_tx_b_TSTRB(m_axis_udp_tx_b_TSTRB),
     .m_axis_udp_tx_b_TLAST(m_axis_udp_tx_b_TLAST),
     .s_axis_udp_rx_meta_b_TDATA(s_axis_udp_rx_meta_b_TDATA),
     .s_axis_udp_rx_meta_b_TKEEP(s_axis_udp_rx_meta_b_TKEEP),
     .s_axis_udp_rx_meta_b_TSTRB(s_axis_udp_rx_meta_b_TSTRB),
     .s_axis_udp_rx_meta_b_TLAST(s_axis_udp_rx_meta_b_TLAST),
     .m_axis_udp_tx_meta_b_TDATA(m_axis_udp_tx_meta_b_TDATA),
     .m_axis_udp_tx_meta_b_TKEEP(m_axis_udp_tx_meta_b_TKEEP),
     .m_axis_udp_tx_meta_b_TSTRB(m_axis_udp_tx_meta_b_TSTRB),
     .m_axis_udp_tx_meta_b_TLAST(m_axis_udp_tx_meta_b_TLAST),
     .m_axis_tcp_listen_port_b_TDATA(m_axis_tcp_listen_port_b_TDATA),
     .m_axis_tcp_listen_port_b_TKEEP(m_axis_tcp_listen_port_b_TKEEP),
     .m_axis_tcp_listen_port_b_TSTRB(m_axis_tcp_listen_port_b_TSTRB),
     .m_axis_tcp_listen_port_b_TLAST(m_axis_tcp_listen_port_b_TLAST),
     .s_axis_tcp_port_status_b_TDATA(s_axis_tcp_port_status_b_TDATA),
     .s_axis_tcp_port_status_b_TKEEP(s_axis_tcp_port_status_b_TKEEP),
     .s_axis_tcp_port_status_b_TSTRB(s_axis_tcp_port_status_b_TSTRB),
     .s_axis_tcp_port_status_b_TLAST(s_axis_tcp_port_status_b_TLAST),
     .m_axis_tcp_open_connection_b_TDATA(m_axis_tcp_open_connection_b_TDATA),
     .m_axis_tcp_open_connection_b_TKEEP(m_axis_tcp_open_connection_b_TKEEP),
     .m_axis_tcp_open_connection_b_TSTRB(m_axis_tcp_open_connection_b_TSTRB),
     .m_axis_tcp_open_connection_b_TLAST(m_axis_tcp_open_connection_b_TLAST),
     .s_axis_tcp_open_status_b_TDATA(s_axis_tcp_open_status_b_TDATA),
     .s_axis_tcp_open_status_b_TKEEP(s_axis_tcp_open_status_b_TKEEP),
     .s_axis_tcp_open_status_b_TSTRB(s_axis_tcp_open_status_b_TSTRB),
     .s_axis_tcp_open_status_b_TLAST(s_axis_tcp_open_status_b_TLAST),
     .m_axis_tcp_close_connection_b_TDATA(m_axis_tcp_close_connection_b_TDATA),
     .m_axis_tcp_close_connection_b_TKEEP(m_axis_tcp_close_connection_b_TKEEP),
     .m_axis_tcp_close_connection_b_TSTRB(m_axis_tcp_close_connection_b_TSTRB),
     .m_axis_tcp_close_connection_b_TLAST(m_axis_tcp_close_connection_b_TLAST),
     .s_axis_tcp_notification_b_TDATA(s_axis_tcp_notification_b_TDATA),
     .s_axis_tcp_notification_b_TKEEP(s_axis_tcp_notification_b_TKEEP),
     .s_axis_tcp_notification_b_TSTRB(s_axis_tcp_notification_b_TSTRB),
     .s_axis_tcp_notification_b_TLAST(s_axis_tcp_notification_b_TLAST),
     .m_axis_tcp_read_pkg_b_TDATA(m_axis_tcp_read_pkg_b_TDATA),
     .m_axis_tcp_read_pkg_b_TKEEP(m_axis_tcp_read_pkg_b_TKEEP),
     .m_axis_tcp_read_pkg_b_TSTRB(m_axis_tcp_read_pkg_b_TSTRB),
     .m_axis_tcp_read_pkg_b_TLAST(m_axis_tcp_read_pkg_b_TLAST),
     .s_axis_tcp_rx_meta_b_TDATA(s_axis_tcp_rx_meta_b_TDATA),
     .s_axis_tcp_rx_meta_b_TKEEP(s_axis_tcp_rx_meta_b_TKEEP),
     .s_axis_tcp_rx_meta_b_TSTRB(s_axis_tcp_rx_meta_b_TSTRB),
     .s_axis_tcp_rx_meta_b_TLAST(s_axis_tcp_rx_meta_b_TLAST),
     .s_axis_tcp_rx_data_b_TDATA(s_axis_tcp_rx_data_b_TDATA),
     .s_axis_tcp_rx_data_b_TKEEP(s_axis_tcp_rx_data_b_TKEEP),
     .s_axis_tcp_rx_data_b_TSTRB(s_axis_tcp_rx_data_b_TSTRB),
     .s_axis_tcp_rx_data_b_TLAST(s_axis_tcp_rx_data_b_TLAST),
     .m_axis_tcp_tx_meta_b_TDATA(m_axis_tcp_tx_meta_b_TDATA),
     .m_axis_tcp_tx_meta_b_TKEEP(m_axis_tcp_tx_meta_b_TKEEP),
     .m_axis_tcp_tx_meta_b_TSTRB(m_axis_tcp_tx_meta_b_TSTRB),
     .m_axis_tcp_tx_meta_b_TLAST(m_axis_tcp_tx_meta_b_TLAST),
     .m_axis_tcp_tx_data_b_TDATA(m_axis_tcp_tx_data_b_TDATA),
     .m_axis_tcp_tx_data_b_TKEEP(m_axis_tcp_tx_data_b_TKEEP),
     .m_axis_tcp_tx_data_b_TSTRB(m_axis_tcp_tx_data_b_TSTRB),
     .m_axis_tcp_tx_data_b_TLAST(m_axis_tcp_tx_data_b_TLAST),
     .s_axis_tcp_tx_status_b_TDATA(s_axis_tcp_tx_status_b_TDATA),
     .s_axis_tcp_tx_status_b_TKEEP(s_axis_tcp_tx_status_b_TKEEP),
     .s_axis_tcp_tx_status_b_TSTRB(s_axis_tcp_tx_status_b_TSTRB),
     .s_axis_tcp_tx_status_b_TLAST(s_axis_tcp_tx_status_b_TLAST),
     .enableA(enableA),
     .enableB(enableB),
     .listenPortA(listenPortA),
     .listenPortB(listenPortB),
     .listenAttempts_a(listenAttempts_a),
     .portState_a(portState_a),
     .notifyCount_a(notifyCount_a),
     .listenAttempts_b(listenAttempts_b),
     .portState_b(portState_b),
     .notifyCount_b(notifyCount_b),
     .ap_clk(ap_clk),
     .ap_rst(ap_rst),
     .enableA_ap_vld(1'b1),
     .listenPortA_ap_vld(1'b1),
     .listenAttempts_a_ap_vld(listenAttempts_a_ap_vld),
     .portState_a_ap_vld(portState_a_ap_vld),
     .m_axis_tcp_listen_port_a_TVALID(m_axis_tcp_listen_port_a_TVALID),
     .m_axis_tcp_listen_port_a_TREADY(m_axis_tcp_listen_port_a_TREADY),
     .s_axis_tcp_port_status_a_TVALID(s_axis_tcp_port_status_a_TVALID),
     .s_axis_tcp_port_status_a_TREADY(s_axis_tcp_port_status_a_TREADY),
     .ap_start(ap_start),
     .ap_done(ap_done),
     .notifyCount_a_ap_vld(notifyCount_a_ap_vld),
     .s_axis_tcp_notification_a_TVALID(s_axis_tcp_notification_a_TVALID),
     .s_axis_tcp_notification_a_TREADY(s_axis_tcp_notification_a_TREADY),
     .m_axis_tcp_read_pkg_a_TVALID(m_axis_tcp_read_pkg_a_TVALID),
     .m_axis_tcp_read_pkg_a_TREADY(m_axis_tcp_read_pkg_a_TREADY),
     .s_axis_tcp_rx_meta_a_TVALID(s_axis_tcp_rx_meta_a_TVALID),
     .s_axis_tcp_rx_meta_a_TREADY(s_axis_tcp_rx_meta_a_TREADY),
     .s_axis_tcp_rx_data_a_TVALID(s_axis_tcp_rx_data_a_TVALID),
     .s_axis_tcp_rx_data_a_TREADY(s_axis_tcp_rx_data_a_TREADY),
     .enableB_ap_vld(1'b1),
     .listenPortB_ap_vld(1'b1),
     .listenAttempts_b_ap_vld(listenAttempts_b_ap_vld),
     .portState_b_ap_vld(portState_b_ap_vld),
     .m_axis_tcp_listen_port_b_TVALID(m_axis_tcp_listen_port_b_TVALID),
     .m_axis_tcp_listen_port_b_TREADY(m_axis_tcp_listen_port_b_TREADY),
     .s_axis_tcp_port_status_b_TVALID(s_axis_tcp_port_status_b_TVALID),
     .s_axis_tcp_port_status_b_TREADY(s_axis_tcp_port_status_b_TREADY),
     .notifyCount_b_ap_vld(notifyCount_b_ap_vld),
     .s_axis_tcp_notification_b_TVALID(s_axis_tcp_notification_b_TVALID),
     .s_axis_tcp_notification_b_TREADY(s_axis_tcp_notification_b_TREADY),
     .m_axis_tcp_read_pkg_b_TVALID(m_axis_tcp_read_pkg_b_TVALID),
     .m_axis_tcp_read_pkg_b_TREADY(m_axis_tcp_read_pkg_b_TREADY),
     .s_axis_tcp_rx_meta_b_TVALID(s_axis_tcp_rx_meta_b_TVALID),
     .s_axis_tcp_rx_meta_b_TREADY(s_axis_tcp_rx_meta_b_TREADY),
     .s_axis_tcp_rx_data_b_TVALID(s_axis_tcp_rx_data_b_TVALID),
     .s_axis_tcp_rx_data_b_TREADY(s_axis_tcp_rx_data_b_TREADY),
     .s_axis_udp_rx_a_TVALID(s_axis_udp_rx_a_TVALID),
     .s_axis_udp_rx_a_TREADY(s_axis_udp_rx_a_TREADY),
     .m_axis_udp_tx_a_TVALID(m_axis_udp_tx_a_TVALID),
     .m_axis_udp_tx_a_TREADY(m_axis_udp_tx_a_TREADY),
     .s_axis_udp_rx_meta_a_TVALID(s_axis_udp_rx_meta_a_TVALID),
     .s_axis_udp_rx_meta_a_TREADY(s_axis_udp_rx_meta_a_TREADY),
     .m_axis_udp_tx_meta_a_TVALID(m_axis_udp_tx_meta_a_TVALID),
     .m_axis_udp_tx_meta_a_TREADY(m_axis_udp_tx_meta_a_TREADY),
     .m_axis_tcp_open_connection_a_TVALID(m_axis_tcp_open_connection_a_TVALID),
     .m_axis_tcp_open_connection_a_TREADY(m_axis_tcp_open_connection_a_TREADY),
     .s_axis_tcp_open_status_a_TVALID(s_axis_tcp_open_status_a_TVALID),
     .s_axis_tcp_open_status_a_TREADY(s_axis_tcp_open_status_a_TREADY),
     .m_axis_tcp_close_connection_a_TVALID(m_axis_tcp_close_connection_a_TVALID),
     .m_axis_tcp_close_connection_a_TREADY(m_axis_tcp_close_connection_a_TREADY),
     .m_axis_tcp_tx_meta_a_TVALID(m_axis_tcp_tx_meta_a_TVALID),
     .m_axis_tcp_tx_meta_a_TREADY(m_axis_tcp_tx_meta_a_TREADY),
     .m_axis_tcp_tx_data_a_TVALID(m_axis_tcp_tx_data_a_TVALID),
     .m_axis_tcp_tx_data_a_TREADY(m_axis_tcp_tx_data_a_TREADY),
     .s_axis_tcp_tx_status_a_TVALID(s_axis_tcp_tx_status_a_TVALID),
     .s_axis_tcp_tx_status_a_TREADY(s_axis_tcp_tx_status_a_TREADY),
     .s_axis_udp_rx_b_TVALID(s_axis_udp_rx_b_TVALID),
     .s_axis_udp_rx_b_TREADY(s_axis_udp_rx_b_TREADY),
     .m_axis_udp_tx_b_TVALID(m_axis_udp_tx_b_TVALID),
     .m_axis_udp_tx_b_TREADY(m_axis_udp_tx_b_TREADY),
     .s_axis_udp_rx_meta_b_TVALID(s_axis_udp_rx_meta_b_TVALID),
     .s_axis_udp_rx_meta_b_TREADY(s_axis_udp_rx_meta_b_TREADY),
     .m_axis_udp_tx_meta_b_TVALID(m_axis_udp_tx_meta_b_TVALID),
     .m_axis_udp_tx_meta_b_TREADY(m_axis_udp_tx_meta_b_TREADY),
     .m_axis_tcp_open_connection_b_TVALID(m_axis_tcp_open_connection_b_TVALID),
     .m_axis_tcp_open_connection_b_TREADY(m_axis_tcp_open_connection_b_TREADY),
     .s_axis_tcp_open_status_b_TVALID(s_axis_tcp_open_status_b_TVALID),
     .s_axis_tcp_open_status_b_TREADY(s_axis_tcp_open_status_b_TREADY),
     .m_axis_tcp_close_connection_b_TVALID(m_axis_tcp_close_connection_b_TVALID),
     .m_axis_tcp_close_connection_b_TREADY(m_axis_tcp_close_connection_b_TREADY),
     .m_axis_tcp_tx_meta_b_TVALID(m_axis_tcp_tx_meta_b_TVALID),
     .m_axis_tcp_tx_meta_b_TREADY(m_axis_tcp_tx_meta_b_TREADY),
     .m_axis_tcp_tx_data_b_TVALID(m_axis_tcp_tx_data_b_TVALID),
     .m_axis_tcp_tx_data_b_TREADY(m_axis_tcp_tx_data_b_TREADY),
     .s_axis_tcp_tx_status_b_TVALID(s_axis_tcp_tx_status_b_TVALID),
     .s_axis_tcp_tx_status_b_TREADY(s_axis_tcp_tx_status_b_TREADY),
     .ap_ready(ap_ready),
     .ap_idle(ap_idle),
     .ap_continue(ap_continue)
);

// ── наблюдение ───────────────────────────────────────────────────────────────
int unsigned port_writes_a = 0, port_writes_b = 0, cycles = 0;

always @(posedge ap_clk) begin
     if (!ap_rst) begin
          cycles <= cycles + 1;
          if (m_axis_tcp_listen_port_a_TVALID && m_axis_tcp_listen_port_a_TREADY)
               port_writes_a <= port_writes_a + 1;
          if (m_axis_tcp_listen_port_b_TVALID && m_axis_tcp_listen_port_b_TREADY)
               port_writes_b <= port_writes_b + 1;
     end
end

// ── ЧТО ДЕРЖИТ ap_sync_done: ap_done каждой из 14 стадий ─────────────────────
//
// Имена инстансов взяты из core.v. Считаем, сколько тактов каждая стадия
// ПРОДЕРЖАЛА ap_done -- нулевой счётчик означает «не выставила ни разу», то есть
// именно она блокирует ap_sync_done и, через него, ap_continue всех остальных.
localparam int N_STAGES = 14;
string stage_name [N_STAGES];
int unsigned done_cnt [N_STAGES];
wire [N_STAGES-1:0] stage_done = {
     dut.tie_off_tcp_tx_U0_ap_done,
     dut.tie_off_tcp_close_con_U0_ap_done,
     dut.tie_off_tcp_open_connection_U0_ap_done,
     dut.tie_off_udp_U0_ap_done,
     dut.tie_off_tcp_tx_5_U0_ap_done,
     dut.tie_off_tcp_close_con_4_U0_ap_done,
     dut.tie_off_tcp_open_connection_3_U0_ap_done,
     dut.tie_off_udp_2_U0_ap_done,
     dut.dual_echo_rx_drain_7_U0_ap_done,
     dut.dual_echo_rx_notify_6_U0_ap_done,
     dut.dual_echo_listen_U0_ap_done,
     dut.dual_echo_rx_drain_U0_ap_done,
     dut.dual_echo_rx_notify_U0_ap_done,
     dut.dual_echo_listen_1_U0_ap_done
};

initial begin
     stage_name[0] = "dual_echo_listen_1_U0";
     stage_name[1] = "dual_echo_rx_notify_U0";
     stage_name[2] = "dual_echo_rx_drain_U0";
     stage_name[3] = "dual_echo_listen_U0";
     stage_name[4] = "dual_echo_rx_notify_6_U0";
     stage_name[5] = "dual_echo_rx_drain_7_U0";
     stage_name[6] = "tie_off_udp_2_U0";
     stage_name[7] = "tie_off_tcp_open_connection_3_U0";
     stage_name[8] = "tie_off_tcp_close_con_4_U0";
     stage_name[9] = "tie_off_tcp_tx_5_U0";
     stage_name[10] = "tie_off_udp_U0";
     stage_name[11] = "tie_off_tcp_open_connection_U0";
     stage_name[12] = "tie_off_tcp_close_con_U0";
     stage_name[13] = "tie_off_tcp_tx_U0";
end

always @(posedge ap_clk) begin
     if (!ap_rst)
          for (int i = 0; i < N_STAGES; i++)
               if (stage_done[i]) done_cnt[i] <= done_cnt[i] + 1;
end

// ── прогон ───────────────────────────────────────────────────────────────────
int unsigned fails = 0;
int unsigned n_never = 0;

task automatic check(string what, bit cond);
     if (cond) $display("  ok   %s", what);
     else begin $display("  FAIL %s", what); fails++; end
endtask

// LISTEN_TIMEOUT = 1e6 ПРОХОДОВ (dual_echo_listen.v:678), при II=2 это ~2 млн
// тактов. Берём с запасом -- см. урок метода в docs/kernel_scheme_handoff.md.
localparam int RUN = 3_000_000;

initial begin
     $display("=== tb_core_ap_done: which of the 14 stages never asserts ap_done ===");
     $display("");
     for (int i = 0; i < N_STAGES; i++) done_cnt[i] = 0;

     repeat (8) @(posedge ap_clk);
     ap_rst = 1'b0;

     repeat (RUN) @(posedge ap_clk);

     $display("--- after %0d cycles with enable=1, TREADY=1, stack silent ---", RUN);
     $display("  listen_port writes: a=%0d b=%0d", port_writes_a, port_writes_b);
     $display("  portState_a=%0d listenAttempts_a=%0d", portState_a, listenAttempts_a);
     $display("  portState_b=%0d listenAttempts_b=%0d", portState_b, listenAttempts_b);
     $display("  region ap_done=%0b ap_idle=%0b ap_ready=%0b", ap_done, ap_idle, ap_ready);

     $display("");
     $display("--- ap_done cycles per stage (0 = NEVER, blocks everyone) ---");
     for (int i = 0; i < N_STAGES; i++) begin
          $display("  %-34s %0d", stage_name[i], done_cnt[i]);
          if (done_cnt[i] == 0) n_never++;
     end

     $display("");
     $display("--- verdict ---");
     if (n_never == 0) begin
          $display("  Every stage asserts ap_done at some point.");
          $display("  So ap_sync_done is not permanently stuck -- the freeze must");
          $display("  come from them never being done in the SAME cycle.");
     end else begin
          $display("  %0d stage(s) NEVER assert ap_done. Those are the cause:", n_never);
          for (int i = 0; i < N_STAGES; i++)
               if (done_cnt[i] == 0)
                    $display("      %s", stage_name[i]);
          $display("  Fix those in the .cpp so they finish on empty inputs, or");
          $display("  take them out of this dataflow region.");
     end

     // Утверждение теста: listen ОБЯЗАН повторять запрос при молчащем стеке.
     // Если нет -- регион заморожен, что и наблюдается на плате.
     $display("");
     check("listen half a retries the request (>1 write)", port_writes_a > 1);
     check("listen half b retries the request (>1 write)", port_writes_b > 1);

     $display("");
     if (fails == 0) $display("=== ALL GREEN ===");
     else            $display("=== FAILED: %0d ===", fails);
     $finish;
end

initial begin
     #40_000_000;
     $display("*** TIMEOUT -- testbench did not finish");
     $finish;
end

endmodule

`default_nettype wire
