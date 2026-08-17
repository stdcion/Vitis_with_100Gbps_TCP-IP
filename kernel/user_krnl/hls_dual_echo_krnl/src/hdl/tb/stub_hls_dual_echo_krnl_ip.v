// =============================================================================
// stub_hls_dual_echo_krnl_ip -- заглушка HLS-ядра для тестбенча ОБЁРТКИ
// =============================================================================
//
// ЗАЧЕМ. Проверяется путь enable: AXI-Lite -> dual_echo_control_s_axi ->
// enable_reg -> порт enableA/enableB инстанса ядра. Само ядро для этого не
// нужно -- нужен свидетель, который скажет, что пришло на его входы.
//
// СГЕНЕРИРОВАНО СКРИПТОМ из сгенерированного HLS-RTL (hls_dual_echo_krnl.v), а
// не написано руками: 210 портов, и любое расхождение имени с настоящим IP дало
// бы либо ошибку элаборации, либо -- хуже -- молча неподключённый порт, то есть
// ровно тот класс дефекта, который здесь и ищется.
//
// ЧТО ДЕЛАЕТ. Входные скаляры защёлкивает в регистры seen_*, чтобы тестбенч
// читал их иерархическим обращением. Начальное значение 32'hDEADBEEF, а не
// ноль: иначе «скаляр не пришёл» не отличить от «пришёл ноль».
//
// portState_a/b повторяет логику стадии listen в самом грубом виде: как только
// enable != 0, состояние уходит с нуля. Именно этого на плате НЕ происходило
// (state=0 при enable=1), поэтому проверка «portState стал 1» и есть проверка
// «enable дошёл до ядра».
//
// ЧЕГО НЕ ДЕЛАЕТ. Не реализует ни стадий, ни AXI-Stream протокола: здесь
// проверяется ОБЁРТКА, а стадии проверены отдельно в tb_listen_start.
// =============================================================================

`timescale 1ns / 1ps

module hls_dual_echo_krnl_ip (
    s_axis_udp_rx_a_TDATA,
    s_axis_udp_rx_a_TKEEP,
    s_axis_udp_rx_a_TSTRB,
    s_axis_udp_rx_a_TLAST,
    m_axis_udp_tx_a_TDATA,
    m_axis_udp_tx_a_TKEEP,
    m_axis_udp_tx_a_TSTRB,
    m_axis_udp_tx_a_TLAST,
    s_axis_udp_rx_meta_a_TDATA,
    s_axis_udp_rx_meta_a_TKEEP,
    s_axis_udp_rx_meta_a_TSTRB,
    s_axis_udp_rx_meta_a_TLAST,
    m_axis_udp_tx_meta_a_TDATA,
    m_axis_udp_tx_meta_a_TKEEP,
    m_axis_udp_tx_meta_a_TSTRB,
    m_axis_udp_tx_meta_a_TLAST,
    m_axis_tcp_listen_port_a_TDATA,
    m_axis_tcp_listen_port_a_TKEEP,
    m_axis_tcp_listen_port_a_TSTRB,
    m_axis_tcp_listen_port_a_TLAST,
    s_axis_tcp_port_status_a_TDATA,
    s_axis_tcp_port_status_a_TKEEP,
    s_axis_tcp_port_status_a_TSTRB,
    s_axis_tcp_port_status_a_TLAST,
    m_axis_tcp_open_connection_a_TDATA,
    m_axis_tcp_open_connection_a_TKEEP,
    m_axis_tcp_open_connection_a_TSTRB,
    m_axis_tcp_open_connection_a_TLAST,
    s_axis_tcp_open_status_a_TDATA,
    s_axis_tcp_open_status_a_TKEEP,
    s_axis_tcp_open_status_a_TSTRB,
    s_axis_tcp_open_status_a_TLAST,
    m_axis_tcp_close_connection_a_TDATA,
    m_axis_tcp_close_connection_a_TKEEP,
    m_axis_tcp_close_connection_a_TSTRB,
    m_axis_tcp_close_connection_a_TLAST,
    s_axis_tcp_notification_a_TDATA,
    s_axis_tcp_notification_a_TKEEP,
    s_axis_tcp_notification_a_TSTRB,
    s_axis_tcp_notification_a_TLAST,
    m_axis_tcp_read_pkg_a_TDATA,
    m_axis_tcp_read_pkg_a_TKEEP,
    m_axis_tcp_read_pkg_a_TSTRB,
    m_axis_tcp_read_pkg_a_TLAST,
    s_axis_tcp_rx_meta_a_TDATA,
    s_axis_tcp_rx_meta_a_TKEEP,
    s_axis_tcp_rx_meta_a_TSTRB,
    s_axis_tcp_rx_meta_a_TLAST,
    s_axis_tcp_rx_data_a_TDATA,
    s_axis_tcp_rx_data_a_TKEEP,
    s_axis_tcp_rx_data_a_TSTRB,
    s_axis_tcp_rx_data_a_TLAST,
    m_axis_tcp_tx_meta_a_TDATA,
    m_axis_tcp_tx_meta_a_TKEEP,
    m_axis_tcp_tx_meta_a_TSTRB,
    m_axis_tcp_tx_meta_a_TLAST,
    m_axis_tcp_tx_data_a_TDATA,
    m_axis_tcp_tx_data_a_TKEEP,
    m_axis_tcp_tx_data_a_TSTRB,
    m_axis_tcp_tx_data_a_TLAST,
    s_axis_tcp_tx_status_a_TDATA,
    s_axis_tcp_tx_status_a_TKEEP,
    s_axis_tcp_tx_status_a_TSTRB,
    s_axis_tcp_tx_status_a_TLAST,
    s_axis_udp_rx_b_TDATA,
    s_axis_udp_rx_b_TKEEP,
    s_axis_udp_rx_b_TSTRB,
    s_axis_udp_rx_b_TLAST,
    m_axis_udp_tx_b_TDATA,
    m_axis_udp_tx_b_TKEEP,
    m_axis_udp_tx_b_TSTRB,
    m_axis_udp_tx_b_TLAST,
    s_axis_udp_rx_meta_b_TDATA,
    s_axis_udp_rx_meta_b_TKEEP,
    s_axis_udp_rx_meta_b_TSTRB,
    s_axis_udp_rx_meta_b_TLAST,
    m_axis_udp_tx_meta_b_TDATA,
    m_axis_udp_tx_meta_b_TKEEP,
    m_axis_udp_tx_meta_b_TSTRB,
    m_axis_udp_tx_meta_b_TLAST,
    m_axis_tcp_listen_port_b_TDATA,
    m_axis_tcp_listen_port_b_TKEEP,
    m_axis_tcp_listen_port_b_TSTRB,
    m_axis_tcp_listen_port_b_TLAST,
    s_axis_tcp_port_status_b_TDATA,
    s_axis_tcp_port_status_b_TKEEP,
    s_axis_tcp_port_status_b_TSTRB,
    s_axis_tcp_port_status_b_TLAST,
    m_axis_tcp_open_connection_b_TDATA,
    m_axis_tcp_open_connection_b_TKEEP,
    m_axis_tcp_open_connection_b_TSTRB,
    m_axis_tcp_open_connection_b_TLAST,
    s_axis_tcp_open_status_b_TDATA,
    s_axis_tcp_open_status_b_TKEEP,
    s_axis_tcp_open_status_b_TSTRB,
    s_axis_tcp_open_status_b_TLAST,
    m_axis_tcp_close_connection_b_TDATA,
    m_axis_tcp_close_connection_b_TKEEP,
    m_axis_tcp_close_connection_b_TSTRB,
    m_axis_tcp_close_connection_b_TLAST,
    s_axis_tcp_notification_b_TDATA,
    s_axis_tcp_notification_b_TKEEP,
    s_axis_tcp_notification_b_TSTRB,
    s_axis_tcp_notification_b_TLAST,
    m_axis_tcp_read_pkg_b_TDATA,
    m_axis_tcp_read_pkg_b_TKEEP,
    m_axis_tcp_read_pkg_b_TSTRB,
    m_axis_tcp_read_pkg_b_TLAST,
    s_axis_tcp_rx_meta_b_TDATA,
    s_axis_tcp_rx_meta_b_TKEEP,
    s_axis_tcp_rx_meta_b_TSTRB,
    s_axis_tcp_rx_meta_b_TLAST,
    s_axis_tcp_rx_data_b_TDATA,
    s_axis_tcp_rx_data_b_TKEEP,
    s_axis_tcp_rx_data_b_TSTRB,
    s_axis_tcp_rx_data_b_TLAST,
    m_axis_tcp_tx_meta_b_TDATA,
    m_axis_tcp_tx_meta_b_TKEEP,
    m_axis_tcp_tx_meta_b_TSTRB,
    m_axis_tcp_tx_meta_b_TLAST,
    m_axis_tcp_tx_data_b_TDATA,
    m_axis_tcp_tx_data_b_TKEEP,
    m_axis_tcp_tx_data_b_TSTRB,
    m_axis_tcp_tx_data_b_TLAST,
    s_axis_tcp_tx_status_b_TDATA,
    s_axis_tcp_tx_status_b_TKEEP,
    s_axis_tcp_tx_status_b_TSTRB,
    s_axis_tcp_tx_status_b_TLAST,
    listenPortA,
    listenPortB,
    listenAttempts_a,
    portState_a,
    notifyCount_a,
    listenAttempts_b,
    portState_b,
    notifyCount_b,
    enableA,
    enableB,
    ap_clk,
    ap_rst_n,
    s_axis_udp_rx_a_TVALID,
    s_axis_udp_rx_a_TREADY,
    m_axis_udp_tx_a_TVALID,
    m_axis_udp_tx_a_TREADY,
    s_axis_udp_rx_meta_a_TVALID,
    s_axis_udp_rx_meta_a_TREADY,
    m_axis_udp_tx_meta_a_TVALID,
    m_axis_udp_tx_meta_a_TREADY,
    m_axis_tcp_listen_port_a_TVALID,
    m_axis_tcp_listen_port_a_TREADY,
    s_axis_tcp_port_status_a_TVALID,
    s_axis_tcp_port_status_a_TREADY,
    m_axis_tcp_open_connection_a_TVALID,
    m_axis_tcp_open_connection_a_TREADY,
    s_axis_tcp_open_status_a_TVALID,
    s_axis_tcp_open_status_a_TREADY,
    m_axis_tcp_close_connection_a_TVALID,
    m_axis_tcp_close_connection_a_TREADY,
    s_axis_tcp_notification_a_TVALID,
    s_axis_tcp_notification_a_TREADY,
    m_axis_tcp_read_pkg_a_TVALID,
    m_axis_tcp_read_pkg_a_TREADY,
    s_axis_tcp_rx_meta_a_TVALID,
    s_axis_tcp_rx_meta_a_TREADY,
    s_axis_tcp_rx_data_a_TVALID,
    s_axis_tcp_rx_data_a_TREADY,
    m_axis_tcp_tx_meta_a_TVALID,
    m_axis_tcp_tx_meta_a_TREADY,
    m_axis_tcp_tx_data_a_TVALID,
    m_axis_tcp_tx_data_a_TREADY,
    s_axis_tcp_tx_status_a_TVALID,
    s_axis_tcp_tx_status_a_TREADY,
    s_axis_udp_rx_b_TVALID,
    s_axis_udp_rx_b_TREADY,
    m_axis_udp_tx_b_TVALID,
    m_axis_udp_tx_b_TREADY,
    s_axis_udp_rx_meta_b_TVALID,
    s_axis_udp_rx_meta_b_TREADY,
    m_axis_udp_tx_meta_b_TVALID,
    m_axis_udp_tx_meta_b_TREADY,
    m_axis_tcp_listen_port_b_TVALID,
    m_axis_tcp_listen_port_b_TREADY,
    s_axis_tcp_port_status_b_TVALID,
    s_axis_tcp_port_status_b_TREADY,
    m_axis_tcp_open_connection_b_TVALID,
    m_axis_tcp_open_connection_b_TREADY,
    s_axis_tcp_open_status_b_TVALID,
    s_axis_tcp_open_status_b_TREADY,
    m_axis_tcp_close_connection_b_TVALID,
    m_axis_tcp_close_connection_b_TREADY,
    s_axis_tcp_notification_b_TVALID,
    s_axis_tcp_notification_b_TREADY,
    m_axis_tcp_read_pkg_b_TVALID,
    m_axis_tcp_read_pkg_b_TREADY,
    s_axis_tcp_rx_meta_b_TVALID,
    s_axis_tcp_rx_meta_b_TREADY,
    s_axis_tcp_rx_data_b_TVALID,
    s_axis_tcp_rx_data_b_TREADY,
    m_axis_tcp_tx_meta_b_TVALID,
    m_axis_tcp_tx_meta_b_TREADY,
    m_axis_tcp_tx_data_b_TVALID,
    m_axis_tcp_tx_data_b_TREADY,
    s_axis_tcp_tx_status_b_TVALID,
    s_axis_tcp_tx_status_b_TREADY,
    listenAttempts_a_ap_vld,
    portState_a_ap_vld,
    notifyCount_a_ap_vld,
    listenAttempts_b_ap_vld,
    portState_b_ap_vld,
    notifyCount_b_ap_vld
);

input [511:0] s_axis_udp_rx_a_TDATA;
input [63:0] s_axis_udp_rx_a_TKEEP;
input [63:0] s_axis_udp_rx_a_TSTRB;
input [0:0] s_axis_udp_rx_a_TLAST;
output [511:0] m_axis_udp_tx_a_TDATA;
output [63:0] m_axis_udp_tx_a_TKEEP;
output [63:0] m_axis_udp_tx_a_TSTRB;
output [0:0] m_axis_udp_tx_a_TLAST;
input [255:0] s_axis_udp_rx_meta_a_TDATA;
input [31:0] s_axis_udp_rx_meta_a_TKEEP;
input [31:0] s_axis_udp_rx_meta_a_TSTRB;
input [0:0] s_axis_udp_rx_meta_a_TLAST;
output [255:0] m_axis_udp_tx_meta_a_TDATA;
output [31:0] m_axis_udp_tx_meta_a_TKEEP;
output [31:0] m_axis_udp_tx_meta_a_TSTRB;
output [0:0] m_axis_udp_tx_meta_a_TLAST;
output [15:0] m_axis_tcp_listen_port_a_TDATA;
output [1:0] m_axis_tcp_listen_port_a_TKEEP;
output [1:0] m_axis_tcp_listen_port_a_TSTRB;
output [0:0] m_axis_tcp_listen_port_a_TLAST;
input [7:0] s_axis_tcp_port_status_a_TDATA;
input [0:0] s_axis_tcp_port_status_a_TKEEP;
input [0:0] s_axis_tcp_port_status_a_TSTRB;
input [0:0] s_axis_tcp_port_status_a_TLAST;
output [63:0] m_axis_tcp_open_connection_a_TDATA;
output [7:0] m_axis_tcp_open_connection_a_TKEEP;
output [7:0] m_axis_tcp_open_connection_a_TSTRB;
output [0:0] m_axis_tcp_open_connection_a_TLAST;
input [127:0] s_axis_tcp_open_status_a_TDATA;
input [15:0] s_axis_tcp_open_status_a_TKEEP;
input [15:0] s_axis_tcp_open_status_a_TSTRB;
input [0:0] s_axis_tcp_open_status_a_TLAST;
output [15:0] m_axis_tcp_close_connection_a_TDATA;
output [1:0] m_axis_tcp_close_connection_a_TKEEP;
output [1:0] m_axis_tcp_close_connection_a_TSTRB;
output [0:0] m_axis_tcp_close_connection_a_TLAST;
input [127:0] s_axis_tcp_notification_a_TDATA;
input [15:0] s_axis_tcp_notification_a_TKEEP;
input [15:0] s_axis_tcp_notification_a_TSTRB;
input [0:0] s_axis_tcp_notification_a_TLAST;
output [31:0] m_axis_tcp_read_pkg_a_TDATA;
output [3:0] m_axis_tcp_read_pkg_a_TKEEP;
output [3:0] m_axis_tcp_read_pkg_a_TSTRB;
output [0:0] m_axis_tcp_read_pkg_a_TLAST;
input [15:0] s_axis_tcp_rx_meta_a_TDATA;
input [1:0] s_axis_tcp_rx_meta_a_TKEEP;
input [1:0] s_axis_tcp_rx_meta_a_TSTRB;
input [0:0] s_axis_tcp_rx_meta_a_TLAST;
input [511:0] s_axis_tcp_rx_data_a_TDATA;
input [63:0] s_axis_tcp_rx_data_a_TKEEP;
input [63:0] s_axis_tcp_rx_data_a_TSTRB;
input [0:0] s_axis_tcp_rx_data_a_TLAST;
output [31:0] m_axis_tcp_tx_meta_a_TDATA;
output [3:0] m_axis_tcp_tx_meta_a_TKEEP;
output [3:0] m_axis_tcp_tx_meta_a_TSTRB;
output [0:0] m_axis_tcp_tx_meta_a_TLAST;
output [511:0] m_axis_tcp_tx_data_a_TDATA;
output [63:0] m_axis_tcp_tx_data_a_TKEEP;
output [63:0] m_axis_tcp_tx_data_a_TSTRB;
output [0:0] m_axis_tcp_tx_data_a_TLAST;
input [63:0] s_axis_tcp_tx_status_a_TDATA;
input [7:0] s_axis_tcp_tx_status_a_TKEEP;
input [7:0] s_axis_tcp_tx_status_a_TSTRB;
input [0:0] s_axis_tcp_tx_status_a_TLAST;
input [511:0] s_axis_udp_rx_b_TDATA;
input [63:0] s_axis_udp_rx_b_TKEEP;
input [63:0] s_axis_udp_rx_b_TSTRB;
input [0:0] s_axis_udp_rx_b_TLAST;
output [511:0] m_axis_udp_tx_b_TDATA;
output [63:0] m_axis_udp_tx_b_TKEEP;
output [63:0] m_axis_udp_tx_b_TSTRB;
output [0:0] m_axis_udp_tx_b_TLAST;
input [255:0] s_axis_udp_rx_meta_b_TDATA;
input [31:0] s_axis_udp_rx_meta_b_TKEEP;
input [31:0] s_axis_udp_rx_meta_b_TSTRB;
input [0:0] s_axis_udp_rx_meta_b_TLAST;
output [255:0] m_axis_udp_tx_meta_b_TDATA;
output [31:0] m_axis_udp_tx_meta_b_TKEEP;
output [31:0] m_axis_udp_tx_meta_b_TSTRB;
output [0:0] m_axis_udp_tx_meta_b_TLAST;
output [15:0] m_axis_tcp_listen_port_b_TDATA;
output [1:0] m_axis_tcp_listen_port_b_TKEEP;
output [1:0] m_axis_tcp_listen_port_b_TSTRB;
output [0:0] m_axis_tcp_listen_port_b_TLAST;
input [7:0] s_axis_tcp_port_status_b_TDATA;
input [0:0] s_axis_tcp_port_status_b_TKEEP;
input [0:0] s_axis_tcp_port_status_b_TSTRB;
input [0:0] s_axis_tcp_port_status_b_TLAST;
output [63:0] m_axis_tcp_open_connection_b_TDATA;
output [7:0] m_axis_tcp_open_connection_b_TKEEP;
output [7:0] m_axis_tcp_open_connection_b_TSTRB;
output [0:0] m_axis_tcp_open_connection_b_TLAST;
input [127:0] s_axis_tcp_open_status_b_TDATA;
input [15:0] s_axis_tcp_open_status_b_TKEEP;
input [15:0] s_axis_tcp_open_status_b_TSTRB;
input [0:0] s_axis_tcp_open_status_b_TLAST;
output [15:0] m_axis_tcp_close_connection_b_TDATA;
output [1:0] m_axis_tcp_close_connection_b_TKEEP;
output [1:0] m_axis_tcp_close_connection_b_TSTRB;
output [0:0] m_axis_tcp_close_connection_b_TLAST;
input [127:0] s_axis_tcp_notification_b_TDATA;
input [15:0] s_axis_tcp_notification_b_TKEEP;
input [15:0] s_axis_tcp_notification_b_TSTRB;
input [0:0] s_axis_tcp_notification_b_TLAST;
output [31:0] m_axis_tcp_read_pkg_b_TDATA;
output [3:0] m_axis_tcp_read_pkg_b_TKEEP;
output [3:0] m_axis_tcp_read_pkg_b_TSTRB;
output [0:0] m_axis_tcp_read_pkg_b_TLAST;
input [15:0] s_axis_tcp_rx_meta_b_TDATA;
input [1:0] s_axis_tcp_rx_meta_b_TKEEP;
input [1:0] s_axis_tcp_rx_meta_b_TSTRB;
input [0:0] s_axis_tcp_rx_meta_b_TLAST;
input [511:0] s_axis_tcp_rx_data_b_TDATA;
input [63:0] s_axis_tcp_rx_data_b_TKEEP;
input [63:0] s_axis_tcp_rx_data_b_TSTRB;
input [0:0] s_axis_tcp_rx_data_b_TLAST;
output [31:0] m_axis_tcp_tx_meta_b_TDATA;
output [3:0] m_axis_tcp_tx_meta_b_TKEEP;
output [3:0] m_axis_tcp_tx_meta_b_TSTRB;
output [0:0] m_axis_tcp_tx_meta_b_TLAST;
output [511:0] m_axis_tcp_tx_data_b_TDATA;
output [63:0] m_axis_tcp_tx_data_b_TKEEP;
output [63:0] m_axis_tcp_tx_data_b_TSTRB;
output [0:0] m_axis_tcp_tx_data_b_TLAST;
input [63:0] s_axis_tcp_tx_status_b_TDATA;
input [7:0] s_axis_tcp_tx_status_b_TKEEP;
input [7:0] s_axis_tcp_tx_status_b_TSTRB;
input [0:0] s_axis_tcp_tx_status_b_TLAST;
input [31:0] listenPortA;
input [31:0] listenPortB;
output [31:0] listenAttempts_a;
output [31:0] portState_a;
output [31:0] notifyCount_a;
output [31:0] listenAttempts_b;
output [31:0] portState_b;
output [31:0] notifyCount_b;
input [31:0] enableA;
input [31:0] enableB;
input ap_clk;
input ap_rst_n;
input s_axis_udp_rx_a_TVALID;
output s_axis_udp_rx_a_TREADY;
output m_axis_udp_tx_a_TVALID;
input m_axis_udp_tx_a_TREADY;
input s_axis_udp_rx_meta_a_TVALID;
output s_axis_udp_rx_meta_a_TREADY;
output m_axis_udp_tx_meta_a_TVALID;
input m_axis_udp_tx_meta_a_TREADY;
output m_axis_tcp_listen_port_a_TVALID;
input m_axis_tcp_listen_port_a_TREADY;
input s_axis_tcp_port_status_a_TVALID;
output s_axis_tcp_port_status_a_TREADY;
output m_axis_tcp_open_connection_a_TVALID;
input m_axis_tcp_open_connection_a_TREADY;
input s_axis_tcp_open_status_a_TVALID;
output s_axis_tcp_open_status_a_TREADY;
output m_axis_tcp_close_connection_a_TVALID;
input m_axis_tcp_close_connection_a_TREADY;
input s_axis_tcp_notification_a_TVALID;
output s_axis_tcp_notification_a_TREADY;
output m_axis_tcp_read_pkg_a_TVALID;
input m_axis_tcp_read_pkg_a_TREADY;
input s_axis_tcp_rx_meta_a_TVALID;
output s_axis_tcp_rx_meta_a_TREADY;
input s_axis_tcp_rx_data_a_TVALID;
output s_axis_tcp_rx_data_a_TREADY;
output m_axis_tcp_tx_meta_a_TVALID;
input m_axis_tcp_tx_meta_a_TREADY;
output m_axis_tcp_tx_data_a_TVALID;
input m_axis_tcp_tx_data_a_TREADY;
input s_axis_tcp_tx_status_a_TVALID;
output s_axis_tcp_tx_status_a_TREADY;
input s_axis_udp_rx_b_TVALID;
output s_axis_udp_rx_b_TREADY;
output m_axis_udp_tx_b_TVALID;
input m_axis_udp_tx_b_TREADY;
input s_axis_udp_rx_meta_b_TVALID;
output s_axis_udp_rx_meta_b_TREADY;
output m_axis_udp_tx_meta_b_TVALID;
input m_axis_udp_tx_meta_b_TREADY;
output m_axis_tcp_listen_port_b_TVALID;
input m_axis_tcp_listen_port_b_TREADY;
input s_axis_tcp_port_status_b_TVALID;
output s_axis_tcp_port_status_b_TREADY;
output m_axis_tcp_open_connection_b_TVALID;
input m_axis_tcp_open_connection_b_TREADY;
input s_axis_tcp_open_status_b_TVALID;
output s_axis_tcp_open_status_b_TREADY;
output m_axis_tcp_close_connection_b_TVALID;
input m_axis_tcp_close_connection_b_TREADY;
input s_axis_tcp_notification_b_TVALID;
output s_axis_tcp_notification_b_TREADY;
output m_axis_tcp_read_pkg_b_TVALID;
input m_axis_tcp_read_pkg_b_TREADY;
input s_axis_tcp_rx_meta_b_TVALID;
output s_axis_tcp_rx_meta_b_TREADY;
input s_axis_tcp_rx_data_b_TVALID;
output s_axis_tcp_rx_data_b_TREADY;
output m_axis_tcp_tx_meta_b_TVALID;
input m_axis_tcp_tx_meta_b_TREADY;
output m_axis_tcp_tx_data_b_TVALID;
input m_axis_tcp_tx_data_b_TREADY;
input s_axis_tcp_tx_status_b_TVALID;
output s_axis_tcp_tx_status_b_TREADY;
output listenAttempts_a_ap_vld;
output portState_a_ap_vld;
output notifyCount_a_ap_vld;
output listenAttempts_b_ap_vld;
output portState_b_ap_vld;
output notifyCount_b_ap_vld;

// ── свидетели: что реально пришло на входные скаляры ─────────────────────
reg [31:0] seen_enableA = 32'hDEAD_BEEF;
reg [31:0] seen_enableB = 32'hDEAD_BEEF;
reg [31:0] seen_listenPortA = 32'hDEAD_BEEF;
reg [31:0] seen_listenPortB = 32'hDEAD_BEEF;

always @(posedge ap_clk) begin
     if (!ap_rst_n) begin
          seen_enableA <= 32'hDEAD_BEEF;
          seen_enableB <= 32'hDEAD_BEEF;
          seen_listenPortA <= 32'hDEAD_BEEF;
          seen_listenPortB <= 32'hDEAD_BEEF;
     end else begin
          seen_enableA <= enableA;
          seen_enableB <= enableB;
          seen_listenPortA <= listenPortA;
          seen_listenPortB <= listenPortB;
     end
end

// ── эхо телеметрии ───────────────────────────────────────────────────────
assign portState_a      = (enableA != 32'd0) ? 32'd1 : 32'd0;
assign portState_b      = (enableB != 32'd0) ? 32'd1 : 32'd0;
assign listenAttempts_a = seen_listenPortA;   // эхо: дошёл ли порт тоже
assign listenAttempts_b = seen_listenPortB;
assign notifyCount_a    = 32'd0;
assign notifyCount_b    = 32'd0;

// ── остальные выходы: нули нужной разрядности ────────────────────────────
assign m_axis_udp_tx_a_TDATA = 512'd0;
assign m_axis_udp_tx_a_TKEEP = 64'd0;
assign m_axis_udp_tx_a_TSTRB = 64'd0;
assign m_axis_udp_tx_a_TLAST = 1'd0;
assign m_axis_udp_tx_meta_a_TDATA = 256'd0;
assign m_axis_udp_tx_meta_a_TKEEP = 32'd0;
assign m_axis_udp_tx_meta_a_TSTRB = 32'd0;
assign m_axis_udp_tx_meta_a_TLAST = 1'd0;
assign m_axis_tcp_listen_port_a_TDATA = 16'd0;
assign m_axis_tcp_listen_port_a_TKEEP = 2'd0;
assign m_axis_tcp_listen_port_a_TSTRB = 2'd0;
assign m_axis_tcp_listen_port_a_TLAST = 1'd0;
assign m_axis_tcp_open_connection_a_TDATA = 64'd0;
assign m_axis_tcp_open_connection_a_TKEEP = 8'd0;
assign m_axis_tcp_open_connection_a_TSTRB = 8'd0;
assign m_axis_tcp_open_connection_a_TLAST = 1'd0;
assign m_axis_tcp_close_connection_a_TDATA = 16'd0;
assign m_axis_tcp_close_connection_a_TKEEP = 2'd0;
assign m_axis_tcp_close_connection_a_TSTRB = 2'd0;
assign m_axis_tcp_close_connection_a_TLAST = 1'd0;
assign m_axis_tcp_read_pkg_a_TDATA = 32'd0;
assign m_axis_tcp_read_pkg_a_TKEEP = 4'd0;
assign m_axis_tcp_read_pkg_a_TSTRB = 4'd0;
assign m_axis_tcp_read_pkg_a_TLAST = 1'd0;
assign m_axis_tcp_tx_meta_a_TDATA = 32'd0;
assign m_axis_tcp_tx_meta_a_TKEEP = 4'd0;
assign m_axis_tcp_tx_meta_a_TSTRB = 4'd0;
assign m_axis_tcp_tx_meta_a_TLAST = 1'd0;
assign m_axis_tcp_tx_data_a_TDATA = 512'd0;
assign m_axis_tcp_tx_data_a_TKEEP = 64'd0;
assign m_axis_tcp_tx_data_a_TSTRB = 64'd0;
assign m_axis_tcp_tx_data_a_TLAST = 1'd0;
assign m_axis_udp_tx_b_TDATA = 512'd0;
assign m_axis_udp_tx_b_TKEEP = 64'd0;
assign m_axis_udp_tx_b_TSTRB = 64'd0;
assign m_axis_udp_tx_b_TLAST = 1'd0;
assign m_axis_udp_tx_meta_b_TDATA = 256'd0;
assign m_axis_udp_tx_meta_b_TKEEP = 32'd0;
assign m_axis_udp_tx_meta_b_TSTRB = 32'd0;
assign m_axis_udp_tx_meta_b_TLAST = 1'd0;
assign m_axis_tcp_listen_port_b_TDATA = 16'd0;
assign m_axis_tcp_listen_port_b_TKEEP = 2'd0;
assign m_axis_tcp_listen_port_b_TSTRB = 2'd0;
assign m_axis_tcp_listen_port_b_TLAST = 1'd0;
assign m_axis_tcp_open_connection_b_TDATA = 64'd0;
assign m_axis_tcp_open_connection_b_TKEEP = 8'd0;
assign m_axis_tcp_open_connection_b_TSTRB = 8'd0;
assign m_axis_tcp_open_connection_b_TLAST = 1'd0;
assign m_axis_tcp_close_connection_b_TDATA = 16'd0;
assign m_axis_tcp_close_connection_b_TKEEP = 2'd0;
assign m_axis_tcp_close_connection_b_TSTRB = 2'd0;
assign m_axis_tcp_close_connection_b_TLAST = 1'd0;
assign m_axis_tcp_read_pkg_b_TDATA = 32'd0;
assign m_axis_tcp_read_pkg_b_TKEEP = 4'd0;
assign m_axis_tcp_read_pkg_b_TSTRB = 4'd0;
assign m_axis_tcp_read_pkg_b_TLAST = 1'd0;
assign m_axis_tcp_tx_meta_b_TDATA = 32'd0;
assign m_axis_tcp_tx_meta_b_TKEEP = 4'd0;
assign m_axis_tcp_tx_meta_b_TSTRB = 4'd0;
assign m_axis_tcp_tx_meta_b_TLAST = 1'd0;
assign m_axis_tcp_tx_data_b_TDATA = 512'd0;
assign m_axis_tcp_tx_data_b_TKEEP = 64'd0;
assign m_axis_tcp_tx_data_b_TSTRB = 64'd0;
assign m_axis_tcp_tx_data_b_TLAST = 1'd0;
assign s_axis_udp_rx_a_TREADY = 1'b0;
assign m_axis_udp_tx_a_TVALID = 1'b0;
assign s_axis_udp_rx_meta_a_TREADY = 1'b0;
assign m_axis_udp_tx_meta_a_TVALID = 1'b0;
assign m_axis_tcp_listen_port_a_TVALID = 1'b0;
assign s_axis_tcp_port_status_a_TREADY = 1'b0;
assign m_axis_tcp_open_connection_a_TVALID = 1'b0;
assign s_axis_tcp_open_status_a_TREADY = 1'b0;
assign m_axis_tcp_close_connection_a_TVALID = 1'b0;
assign s_axis_tcp_notification_a_TREADY = 1'b0;
assign m_axis_tcp_read_pkg_a_TVALID = 1'b0;
assign s_axis_tcp_rx_meta_a_TREADY = 1'b0;
assign s_axis_tcp_rx_data_a_TREADY = 1'b0;
assign m_axis_tcp_tx_meta_a_TVALID = 1'b0;
assign m_axis_tcp_tx_data_a_TVALID = 1'b0;
assign s_axis_tcp_tx_status_a_TREADY = 1'b0;
assign s_axis_udp_rx_b_TREADY = 1'b0;
assign m_axis_udp_tx_b_TVALID = 1'b0;
assign s_axis_udp_rx_meta_b_TREADY = 1'b0;
assign m_axis_udp_tx_meta_b_TVALID = 1'b0;
assign m_axis_tcp_listen_port_b_TVALID = 1'b0;
assign s_axis_tcp_port_status_b_TREADY = 1'b0;
assign m_axis_tcp_open_connection_b_TVALID = 1'b0;
assign s_axis_tcp_open_status_b_TREADY = 1'b0;
assign m_axis_tcp_close_connection_b_TVALID = 1'b0;
assign s_axis_tcp_notification_b_TREADY = 1'b0;
assign m_axis_tcp_read_pkg_b_TVALID = 1'b0;
assign s_axis_tcp_rx_meta_b_TREADY = 1'b0;
assign s_axis_tcp_rx_data_b_TREADY = 1'b0;
assign m_axis_tcp_tx_meta_b_TVALID = 1'b0;
assign m_axis_tcp_tx_data_b_TVALID = 1'b0;
assign s_axis_tcp_tx_status_b_TREADY = 1'b0;
assign listenAttempts_a_ap_vld = 1'b1;
assign portState_a_ap_vld = 1'b1;
assign notifyCount_a_ap_vld = 1'b1;
assign listenAttempts_b_ap_vld = 1'b1;
assign portState_b_ap_vld = 1'b1;
assign notifyCount_b_ap_vld = 1'b1;

endmodule
