// =============================================================================
// hls_dual_echo_krnl_wrapper -- HDL-обёртка вокруг free-running HLS-ядра
// =============================================================================
//
// ЗАЧЕМ. HLS-функция hls_dual_echo_krnl объявлена ap_ctrl_none и не имеет ни
// одного s_axilite (иначе HLS молча защёлкивает скаляры один раз после
// сброса — см. шапку hls_dual_echo_krnl.cpp). Значит регистры управления
// должен держать кто-то снаружи. Это и делает данный модуль:
//
//   * инстанцирует dual_echo_control_s_axi.v  -- регистры AXI4-Lite;
//   * отдаёт enable/listenPortA/listenPortB в ядро ПРОВОДАМИ;
//   * принимает телеметрию из ядра проводами и отдаёт её на чтение;
//   * реализует блочный протокол ap_ctrl_hs, который ждёт BD/XRT.
//
// Это дословно та же схема, что в iperf_krnl (iperf_role.sv:369) и
// network_krnl (network_stack.sv + network_control_s_axi.sv) — двух ядрах
// этого проекта, работающих на данном железе.
//
// ПРО ap_done И auto_restart. Ядро внутри бесконечное: оно никогда не
// «заканчивает» и ap_done само выставить не может. Поэтому обёртка
// объявляет его завершённым сразу после старта:
//
//     assign ap_done = ap_start_pulse;
//
// Ровно та же уловка, что в network_krnl, только там ap_done дёргается по
// таймеру раз в секунду (network_stack.sv:921). Смысл один: дать хосту
// корректный handshake, не останавливая логику. Работа ядра от ap_done НЕ
// зависит вообще — оно течёт с первого такта после снятия сброса, потому
// что ap_ctrl_none. ap_start здесь нужен только чтобы:
//
//   1. хост мог отличить «битстрим жив, регистры отвечают» от тишины;
//   2. существовал ap_start_pulse — программный сброс счётчиков;
//   3. BD видел ожидаемый ap_ctrl_hs-интерфейс.
//
// Разрешение работы даёт НЕ ap_start, а регистр enable. Это сознательно
// иначе, чем в iperf (там runExperiment = ap_start_pulse): отдельный
// регистр позволяет выключить и включить половины, не передёргивая ap_ctrl,
// что при отладке на плате с ограниченным доступом заметно удобнее.
//
// ИМЕНА AXI-STREAM ПОРТОВ НЕ МЕНЯТЬ. Они дословно совпадают с
// config_sp_hls_dual_echo_krnl_dual.txt (s_axis_*_a / m_axis_*_b и т.д.).
// Обёртка их только пробрасывает: сигнатура снаружи остаётся такой же,
// какой её видел BD до появления обёртки, поэтому build_bd.tcl и config_sp
// править не нужно.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module hls_dual_echo_krnl_wrapper #(
     parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32,
     parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 12
)(
     input  wire                                    ap_clk,
     input  wire                                    ap_rst_n,

     // ── AXI4-Lite: управление и телеметрия ────────────────────────────────
     input  wire                                    s_axi_control_awvalid,
     output wire                                    s_axi_control_awready,
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_awaddr,
     input  wire                                    s_axi_control_wvalid,
     output wire                                    s_axi_control_wready,
     input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_wdata,
     input  wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_wstrb,
     input  wire                                    s_axi_control_arvalid,
     output wire                                    s_axi_control_arready,
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_araddr,
     output wire                                    s_axi_control_rvalid,
     input  wire                                    s_axi_control_rready,
     output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_rdata,
     output wire [1:0]                              s_axi_control_rresp,
     output wire                                    s_axi_control_bvalid,
     input  wire                                    s_axi_control_bready,
     output wire [1:0]                              s_axi_control_bresp,
     output wire                                    interrupt,

     // ── половина a -> network_krnl_1 (QSFP0) ──────────────────────────────
     input  wire        s_axis_udp_rx_a_tvalid,
     output wire        s_axis_udp_rx_a_tready,
     input  wire [511:0] s_axis_udp_rx_a_tdata,
     input  wire [63:0] s_axis_udp_rx_a_tkeep,
     input  wire        s_axis_udp_rx_a_tlast,

     output wire        m_axis_udp_tx_a_tvalid,
     input  wire        m_axis_udp_tx_a_tready,
     output wire [511:0] m_axis_udp_tx_a_tdata,
     output wire [63:0] m_axis_udp_tx_a_tkeep,
     output wire        m_axis_udp_tx_a_tlast,

     input  wire        s_axis_udp_rx_meta_a_tvalid,
     output wire        s_axis_udp_rx_meta_a_tready,
     input  wire [255:0] s_axis_udp_rx_meta_a_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_a_tkeep,
     input  wire        s_axis_udp_rx_meta_a_tlast,

     output wire        m_axis_udp_tx_meta_a_tvalid,
     input  wire        m_axis_udp_tx_meta_a_tready,
     output wire [255:0] m_axis_udp_tx_meta_a_tdata,
     output wire [31:0] m_axis_udp_tx_meta_a_tkeep,
     output wire        m_axis_udp_tx_meta_a_tlast,

     output wire        m_axis_tcp_listen_port_a_tvalid,
     input  wire        m_axis_tcp_listen_port_a_tready,
     output wire [15:0] m_axis_tcp_listen_port_a_tdata,
     output wire [1:0]  m_axis_tcp_listen_port_a_tkeep,
     output wire        m_axis_tcp_listen_port_a_tlast,

     input  wire        s_axis_tcp_port_status_a_tvalid,
     output wire        s_axis_tcp_port_status_a_tready,
     input  wire [7:0]  s_axis_tcp_port_status_a_tdata,
     input  wire [0:0]  s_axis_tcp_port_status_a_tkeep,
     input  wire        s_axis_tcp_port_status_a_tlast,

     output wire        m_axis_tcp_open_connection_a_tvalid,
     input  wire        m_axis_tcp_open_connection_a_tready,
     output wire [63:0] m_axis_tcp_open_connection_a_tdata,
     output wire [7:0]  m_axis_tcp_open_connection_a_tkeep,
     output wire        m_axis_tcp_open_connection_a_tlast,

     input  wire        s_axis_tcp_open_status_a_tvalid,
     output wire        s_axis_tcp_open_status_a_tready,
     input  wire [127:0] s_axis_tcp_open_status_a_tdata,
     input  wire [15:0] s_axis_tcp_open_status_a_tkeep,
     input  wire        s_axis_tcp_open_status_a_tlast,

     output wire        m_axis_tcp_close_connection_a_tvalid,
     input  wire        m_axis_tcp_close_connection_a_tready,
     output wire [15:0] m_axis_tcp_close_connection_a_tdata,
     output wire [1:0]  m_axis_tcp_close_connection_a_tkeep,
     output wire        m_axis_tcp_close_connection_a_tlast,

     input  wire        s_axis_tcp_notification_a_tvalid,
     output wire        s_axis_tcp_notification_a_tready,
     input  wire [127:0] s_axis_tcp_notification_a_tdata,
     input  wire [15:0] s_axis_tcp_notification_a_tkeep,
     input  wire        s_axis_tcp_notification_a_tlast,

     output wire        m_axis_tcp_read_pkg_a_tvalid,
     input  wire        m_axis_tcp_read_pkg_a_tready,
     output wire [31:0] m_axis_tcp_read_pkg_a_tdata,
     output wire [3:0]  m_axis_tcp_read_pkg_a_tkeep,
     output wire        m_axis_tcp_read_pkg_a_tlast,

     input  wire        s_axis_tcp_rx_meta_a_tvalid,
     output wire        s_axis_tcp_rx_meta_a_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_a_tdata,
     input  wire [1:0]  s_axis_tcp_rx_meta_a_tkeep,
     input  wire        s_axis_tcp_rx_meta_a_tlast,

     input  wire        s_axis_tcp_rx_data_a_tvalid,
     output wire        s_axis_tcp_rx_data_a_tready,
     input  wire [511:0] s_axis_tcp_rx_data_a_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_a_tkeep,
     input  wire        s_axis_tcp_rx_data_a_tlast,

     output wire        m_axis_tcp_tx_meta_a_tvalid,
     input  wire        m_axis_tcp_tx_meta_a_tready,
     output wire [31:0] m_axis_tcp_tx_meta_a_tdata,
     output wire [3:0]  m_axis_tcp_tx_meta_a_tkeep,
     output wire        m_axis_tcp_tx_meta_a_tlast,

     output wire        m_axis_tcp_tx_data_a_tvalid,
     input  wire        m_axis_tcp_tx_data_a_tready,
     output wire [511:0] m_axis_tcp_tx_data_a_tdata,
     output wire [63:0] m_axis_tcp_tx_data_a_tkeep,
     output wire        m_axis_tcp_tx_data_a_tlast,

     input  wire        s_axis_tcp_tx_status_a_tvalid,
     output wire        s_axis_tcp_tx_status_a_tready,
     input  wire [63:0] s_axis_tcp_tx_status_a_tdata,
     input  wire [7:0]  s_axis_tcp_tx_status_a_tkeep,
     input  wire        s_axis_tcp_tx_status_a_tlast,

     // ── половина b -> network_krnl_2 (QSFP1) ──────────────────────────────
     input  wire        s_axis_udp_rx_b_tvalid,
     output wire        s_axis_udp_rx_b_tready,
     input  wire [511:0] s_axis_udp_rx_b_tdata,
     input  wire [63:0] s_axis_udp_rx_b_tkeep,
     input  wire        s_axis_udp_rx_b_tlast,

     output wire        m_axis_udp_tx_b_tvalid,
     input  wire        m_axis_udp_tx_b_tready,
     output wire [511:0] m_axis_udp_tx_b_tdata,
     output wire [63:0] m_axis_udp_tx_b_tkeep,
     output wire        m_axis_udp_tx_b_tlast,

     input  wire        s_axis_udp_rx_meta_b_tvalid,
     output wire        s_axis_udp_rx_meta_b_tready,
     input  wire [255:0] s_axis_udp_rx_meta_b_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_b_tkeep,
     input  wire        s_axis_udp_rx_meta_b_tlast,

     output wire        m_axis_udp_tx_meta_b_tvalid,
     input  wire        m_axis_udp_tx_meta_b_tready,
     output wire [255:0] m_axis_udp_tx_meta_b_tdata,
     output wire [31:0] m_axis_udp_tx_meta_b_tkeep,
     output wire        m_axis_udp_tx_meta_b_tlast,

     output wire        m_axis_tcp_listen_port_b_tvalid,
     input  wire        m_axis_tcp_listen_port_b_tready,
     output wire [15:0] m_axis_tcp_listen_port_b_tdata,
     output wire [1:0]  m_axis_tcp_listen_port_b_tkeep,
     output wire        m_axis_tcp_listen_port_b_tlast,

     input  wire        s_axis_tcp_port_status_b_tvalid,
     output wire        s_axis_tcp_port_status_b_tready,
     input  wire [7:0]  s_axis_tcp_port_status_b_tdata,
     input  wire [0:0]  s_axis_tcp_port_status_b_tkeep,
     input  wire        s_axis_tcp_port_status_b_tlast,

     output wire        m_axis_tcp_open_connection_b_tvalid,
     input  wire        m_axis_tcp_open_connection_b_tready,
     output wire [63:0] m_axis_tcp_open_connection_b_tdata,
     output wire [7:0]  m_axis_tcp_open_connection_b_tkeep,
     output wire        m_axis_tcp_open_connection_b_tlast,

     input  wire        s_axis_tcp_open_status_b_tvalid,
     output wire        s_axis_tcp_open_status_b_tready,
     input  wire [127:0] s_axis_tcp_open_status_b_tdata,
     input  wire [15:0] s_axis_tcp_open_status_b_tkeep,
     input  wire        s_axis_tcp_open_status_b_tlast,

     output wire        m_axis_tcp_close_connection_b_tvalid,
     input  wire        m_axis_tcp_close_connection_b_tready,
     output wire [15:0] m_axis_tcp_close_connection_b_tdata,
     output wire [1:0]  m_axis_tcp_close_connection_b_tkeep,
     output wire        m_axis_tcp_close_connection_b_tlast,

     input  wire        s_axis_tcp_notification_b_tvalid,
     output wire        s_axis_tcp_notification_b_tready,
     input  wire [127:0] s_axis_tcp_notification_b_tdata,
     input  wire [15:0] s_axis_tcp_notification_b_tkeep,
     input  wire        s_axis_tcp_notification_b_tlast,

     output wire        m_axis_tcp_read_pkg_b_tvalid,
     input  wire        m_axis_tcp_read_pkg_b_tready,
     output wire [31:0] m_axis_tcp_read_pkg_b_tdata,
     output wire [3:0]  m_axis_tcp_read_pkg_b_tkeep,
     output wire        m_axis_tcp_read_pkg_b_tlast,

     input  wire        s_axis_tcp_rx_meta_b_tvalid,
     output wire        s_axis_tcp_rx_meta_b_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_b_tdata,
     input  wire [1:0]  s_axis_tcp_rx_meta_b_tkeep,
     input  wire        s_axis_tcp_rx_meta_b_tlast,

     input  wire        s_axis_tcp_rx_data_b_tvalid,
     output wire        s_axis_tcp_rx_data_b_tready,
     input  wire [511:0] s_axis_tcp_rx_data_b_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_b_tkeep,
     input  wire        s_axis_tcp_rx_data_b_tlast,

     output wire        m_axis_tcp_tx_meta_b_tvalid,
     input  wire        m_axis_tcp_tx_meta_b_tready,
     output wire [31:0] m_axis_tcp_tx_meta_b_tdata,
     output wire [3:0]  m_axis_tcp_tx_meta_b_tkeep,
     output wire        m_axis_tcp_tx_meta_b_tlast,

     output wire        m_axis_tcp_tx_data_b_tvalid,
     input  wire        m_axis_tcp_tx_data_b_tready,
     output wire [511:0] m_axis_tcp_tx_data_b_tdata,
     output wire [63:0] m_axis_tcp_tx_data_b_tkeep,
     output wire        m_axis_tcp_tx_data_b_tlast,

     input  wire        s_axis_tcp_tx_status_b_tvalid,
     output wire        s_axis_tcp_tx_status_b_tready,
     input  wire [63:0] s_axis_tcp_tx_status_b_tdata,
     input  wire [7:0]  s_axis_tcp_tx_status_b_tkeep,
     input  wire        s_axis_tcp_tx_status_b_tlast
);

// ── блочный протокол ─────────────────────────────────────────────────────────
wire        ap_start;
wire        ap_done;
wire        ap_ready;
wire        ap_idle;

logic       ap_start_r = 1'b0;
logic       ap_idle_r  = 1'b1;
wire        ap_start_pulse;

always @(posedge ap_clk) begin
     ap_start_r <= ap_start;
end

assign ap_start_pulse = ap_start & ~ap_start_r;

// Ядро бесконечное и ap_done само не выставит — завершаем транзакцию сразу
// после старта. См. пояснение в шапке: работа ядра от этого не зависит,
// ap_ctrl_none гонит логику независимо от блочного протокола.
assign ap_done  = ap_start_pulse;
assign ap_ready = ap_done;

always @(posedge ap_clk) begin
     if (~ap_rst_n)
          ap_idle_r <= 1'b1;
     else
          ap_idle_r <= ap_done ? 1'b1 : (ap_start_pulse ? 1'b0 : ap_idle_r);
end

assign ap_idle = ap_idle_r;

// ── регистры <-> провода ─────────────────────────────────────────────────────
wire [31:0] enable_reg;
wire [31:0] listenPortA_reg;
wire [31:0] listenPortB_reg;

wire [31:0] listenAttempts_a;
wire [31:0] portState_a;
wire [31:0] notifyCount_a;
wire [31:0] listenAttempts_b;
wire [31:0] portState_b;
wire [31:0] notifyCount_b;

dual_echo_control_s_axi #(
     .C_S_AXI_ADDR_WIDTH ( C_S_AXI_CONTROL_ADDR_WIDTH ),
     .C_S_AXI_DATA_WIDTH ( C_S_AXI_CONTROL_DATA_WIDTH )
) inst_control_s_axi (
     .ACLK             ( ap_clk                 ),
     .ARESET           ( ~ap_rst_n              ),
     .ACLK_EN          ( 1'b1                   ),
     .AWVALID          ( s_axi_control_awvalid  ),
     .AWREADY          ( s_axi_control_awready  ),
     .AWADDR           ( s_axi_control_awaddr   ),
     .WVALID           ( s_axi_control_wvalid   ),
     .WREADY           ( s_axi_control_wready   ),
     .WDATA            ( s_axi_control_wdata    ),
     .WSTRB            ( s_axi_control_wstrb    ),
     .ARVALID          ( s_axi_control_arvalid  ),
     .ARREADY          ( s_axi_control_arready  ),
     .ARADDR           ( s_axi_control_araddr   ),
     .RVALID           ( s_axi_control_rvalid   ),
     .RREADY           ( s_axi_control_rready   ),
     .RDATA            ( s_axi_control_rdata    ),
     .RRESP            ( s_axi_control_rresp    ),
     .BVALID           ( s_axi_control_bvalid   ),
     .BREADY           ( s_axi_control_bready   ),
     .BRESP            ( s_axi_control_bresp    ),
     .interrupt        ( interrupt              ),
     .ap_start         ( ap_start               ),
     .ap_done          ( ap_done                ),
     .ap_ready         ( ap_ready               ),
     .ap_idle          ( ap_idle                ),
     .enable           ( enable_reg             ),
     .listenPortA      ( listenPortA_reg        ),
     .listenPortB      ( listenPortB_reg        ),
     .listenAttempts_a ( listenAttempts_a       ),
     .portState_a      ( portState_a            ),
     .notifyCount_a    ( notifyCount_a          ),
     .listenAttempts_b ( listenAttempts_b       ),
     .portState_b      ( portState_b            ),
     .notifyCount_b    ( notifyCount_b          )
);

// ── HLS-ядро ─────────────────────────────────────────────────────────────────
//
// Имя модуля задаётся при упаковке IP (create_ip -module_name
// hls_dual_echo_krnl_ip, см. package_hls_dual_echo_krnl.tcl).
//
// Скаляры идут ПРОВОДАМИ: ap_ctrl_none-ядро видит их каждый такт, поэтому
// момент записи по JTAG не важен — важен лишь порядок «сначала порты, потом
// enable», который обеспечивает jtag_ctrl.tcl.
hls_dual_echo_krnl_ip hls_dual_echo_krnl_inst (
     .ap_clk   ( ap_clk   ),
     .ap_rst_n ( ap_rst_n ),

     // половина a
     .s_axis_udp_rx_a_TVALID              ( s_axis_udp_rx_a_tvalid              ),
     .s_axis_udp_rx_a_TREADY              ( s_axis_udp_rx_a_tready              ),
     .s_axis_udp_rx_a_TDATA               ( s_axis_udp_rx_a_tdata               ),
     .s_axis_udp_rx_a_TKEEP               ( s_axis_udp_rx_a_tkeep               ),
     .s_axis_udp_rx_a_TLAST               ( s_axis_udp_rx_a_tlast               ),

     .m_axis_udp_tx_a_TVALID              ( m_axis_udp_tx_a_tvalid              ),
     .m_axis_udp_tx_a_TREADY              ( m_axis_udp_tx_a_tready              ),
     .m_axis_udp_tx_a_TDATA               ( m_axis_udp_tx_a_tdata               ),
     .m_axis_udp_tx_a_TKEEP               ( m_axis_udp_tx_a_tkeep               ),
     .m_axis_udp_tx_a_TLAST               ( m_axis_udp_tx_a_tlast               ),

     .s_axis_udp_rx_meta_a_TVALID         ( s_axis_udp_rx_meta_a_tvalid         ),
     .s_axis_udp_rx_meta_a_TREADY         ( s_axis_udp_rx_meta_a_tready         ),
     .s_axis_udp_rx_meta_a_TDATA          ( s_axis_udp_rx_meta_a_tdata          ),
     .s_axis_udp_rx_meta_a_TKEEP          ( s_axis_udp_rx_meta_a_tkeep          ),
     .s_axis_udp_rx_meta_a_TLAST          ( s_axis_udp_rx_meta_a_tlast          ),

     .m_axis_udp_tx_meta_a_TVALID         ( m_axis_udp_tx_meta_a_tvalid         ),
     .m_axis_udp_tx_meta_a_TREADY         ( m_axis_udp_tx_meta_a_tready         ),
     .m_axis_udp_tx_meta_a_TDATA          ( m_axis_udp_tx_meta_a_tdata          ),
     .m_axis_udp_tx_meta_a_TKEEP          ( m_axis_udp_tx_meta_a_tkeep          ),
     .m_axis_udp_tx_meta_a_TLAST          ( m_axis_udp_tx_meta_a_tlast          ),

     .m_axis_tcp_listen_port_a_TVALID     ( m_axis_tcp_listen_port_a_tvalid     ),
     .m_axis_tcp_listen_port_a_TREADY     ( m_axis_tcp_listen_port_a_tready     ),
     .m_axis_tcp_listen_port_a_TDATA      ( m_axis_tcp_listen_port_a_tdata      ),
     .m_axis_tcp_listen_port_a_TKEEP      ( m_axis_tcp_listen_port_a_tkeep      ),
     .m_axis_tcp_listen_port_a_TLAST      ( m_axis_tcp_listen_port_a_tlast      ),

     .s_axis_tcp_port_status_a_TVALID     ( s_axis_tcp_port_status_a_tvalid     ),
     .s_axis_tcp_port_status_a_TREADY     ( s_axis_tcp_port_status_a_tready     ),
     .s_axis_tcp_port_status_a_TDATA      ( s_axis_tcp_port_status_a_tdata      ),
     .s_axis_tcp_port_status_a_TKEEP      ( s_axis_tcp_port_status_a_tkeep      ),
     .s_axis_tcp_port_status_a_TLAST      ( s_axis_tcp_port_status_a_tlast      ),

     .m_axis_tcp_open_connection_a_TVALID ( m_axis_tcp_open_connection_a_tvalid ),
     .m_axis_tcp_open_connection_a_TREADY ( m_axis_tcp_open_connection_a_tready ),
     .m_axis_tcp_open_connection_a_TDATA  ( m_axis_tcp_open_connection_a_tdata  ),
     .m_axis_tcp_open_connection_a_TKEEP  ( m_axis_tcp_open_connection_a_tkeep  ),
     .m_axis_tcp_open_connection_a_TLAST  ( m_axis_tcp_open_connection_a_tlast  ),

     .s_axis_tcp_open_status_a_TVALID     ( s_axis_tcp_open_status_a_tvalid     ),
     .s_axis_tcp_open_status_a_TREADY     ( s_axis_tcp_open_status_a_tready     ),
     .s_axis_tcp_open_status_a_TDATA      ( s_axis_tcp_open_status_a_tdata      ),
     .s_axis_tcp_open_status_a_TKEEP      ( s_axis_tcp_open_status_a_tkeep      ),
     .s_axis_tcp_open_status_a_TLAST      ( s_axis_tcp_open_status_a_tlast      ),

     .m_axis_tcp_close_connection_a_TVALID( m_axis_tcp_close_connection_a_tvalid),
     .m_axis_tcp_close_connection_a_TREADY( m_axis_tcp_close_connection_a_tready),
     .m_axis_tcp_close_connection_a_TDATA ( m_axis_tcp_close_connection_a_tdata ),
     .m_axis_tcp_close_connection_a_TKEEP ( m_axis_tcp_close_connection_a_tkeep ),
     .m_axis_tcp_close_connection_a_TLAST ( m_axis_tcp_close_connection_a_tlast ),

     .s_axis_tcp_notification_a_TVALID    ( s_axis_tcp_notification_a_tvalid    ),
     .s_axis_tcp_notification_a_TREADY    ( s_axis_tcp_notification_a_tready    ),
     .s_axis_tcp_notification_a_TDATA     ( s_axis_tcp_notification_a_tdata     ),
     .s_axis_tcp_notification_a_TKEEP     ( s_axis_tcp_notification_a_tkeep     ),
     .s_axis_tcp_notification_a_TLAST     ( s_axis_tcp_notification_a_tlast     ),

     .m_axis_tcp_read_pkg_a_TVALID        ( m_axis_tcp_read_pkg_a_tvalid        ),
     .m_axis_tcp_read_pkg_a_TREADY        ( m_axis_tcp_read_pkg_a_tready        ),
     .m_axis_tcp_read_pkg_a_TDATA         ( m_axis_tcp_read_pkg_a_tdata         ),
     .m_axis_tcp_read_pkg_a_TKEEP         ( m_axis_tcp_read_pkg_a_tkeep         ),
     .m_axis_tcp_read_pkg_a_TLAST         ( m_axis_tcp_read_pkg_a_tlast         ),

     .s_axis_tcp_rx_meta_a_TVALID         ( s_axis_tcp_rx_meta_a_tvalid         ),
     .s_axis_tcp_rx_meta_a_TREADY         ( s_axis_tcp_rx_meta_a_tready         ),
     .s_axis_tcp_rx_meta_a_TDATA          ( s_axis_tcp_rx_meta_a_tdata          ),
     .s_axis_tcp_rx_meta_a_TKEEP          ( s_axis_tcp_rx_meta_a_tkeep          ),
     .s_axis_tcp_rx_meta_a_TLAST          ( s_axis_tcp_rx_meta_a_tlast          ),

     .s_axis_tcp_rx_data_a_TVALID         ( s_axis_tcp_rx_data_a_tvalid         ),
     .s_axis_tcp_rx_data_a_TREADY         ( s_axis_tcp_rx_data_a_tready         ),
     .s_axis_tcp_rx_data_a_TDATA          ( s_axis_tcp_rx_data_a_tdata          ),
     .s_axis_tcp_rx_data_a_TKEEP          ( s_axis_tcp_rx_data_a_tkeep          ),
     .s_axis_tcp_rx_data_a_TLAST          ( s_axis_tcp_rx_data_a_tlast          ),

     .m_axis_tcp_tx_meta_a_TVALID         ( m_axis_tcp_tx_meta_a_tvalid         ),
     .m_axis_tcp_tx_meta_a_TREADY         ( m_axis_tcp_tx_meta_a_tready         ),
     .m_axis_tcp_tx_meta_a_TDATA          ( m_axis_tcp_tx_meta_a_tdata          ),
     .m_axis_tcp_tx_meta_a_TKEEP          ( m_axis_tcp_tx_meta_a_tkeep          ),
     .m_axis_tcp_tx_meta_a_TLAST          ( m_axis_tcp_tx_meta_a_tlast          ),

     .m_axis_tcp_tx_data_a_TVALID         ( m_axis_tcp_tx_data_a_tvalid         ),
     .m_axis_tcp_tx_data_a_TREADY         ( m_axis_tcp_tx_data_a_tready         ),
     .m_axis_tcp_tx_data_a_TDATA          ( m_axis_tcp_tx_data_a_tdata          ),
     .m_axis_tcp_tx_data_a_TKEEP          ( m_axis_tcp_tx_data_a_tkeep          ),
     .m_axis_tcp_tx_data_a_TLAST          ( m_axis_tcp_tx_data_a_tlast          ),

     .s_axis_tcp_tx_status_a_TVALID       ( s_axis_tcp_tx_status_a_tvalid       ),
     .s_axis_tcp_tx_status_a_TREADY       ( s_axis_tcp_tx_status_a_tready       ),
     .s_axis_tcp_tx_status_a_TDATA        ( s_axis_tcp_tx_status_a_tdata        ),
     .s_axis_tcp_tx_status_a_TKEEP        ( s_axis_tcp_tx_status_a_tkeep        ),
     .s_axis_tcp_tx_status_a_TLAST        ( s_axis_tcp_tx_status_a_tlast        ),

     // половина b
     .s_axis_udp_rx_b_TVALID              ( s_axis_udp_rx_b_tvalid              ),
     .s_axis_udp_rx_b_TREADY              ( s_axis_udp_rx_b_tready              ),
     .s_axis_udp_rx_b_TDATA               ( s_axis_udp_rx_b_tdata               ),
     .s_axis_udp_rx_b_TKEEP               ( s_axis_udp_rx_b_tkeep               ),
     .s_axis_udp_rx_b_TLAST               ( s_axis_udp_rx_b_tlast               ),

     .m_axis_udp_tx_b_TVALID              ( m_axis_udp_tx_b_tvalid              ),
     .m_axis_udp_tx_b_TREADY              ( m_axis_udp_tx_b_tready              ),
     .m_axis_udp_tx_b_TDATA               ( m_axis_udp_tx_b_tdata               ),
     .m_axis_udp_tx_b_TKEEP               ( m_axis_udp_tx_b_tkeep               ),
     .m_axis_udp_tx_b_TLAST               ( m_axis_udp_tx_b_tlast               ),

     .s_axis_udp_rx_meta_b_TVALID         ( s_axis_udp_rx_meta_b_tvalid         ),
     .s_axis_udp_rx_meta_b_TREADY         ( s_axis_udp_rx_meta_b_tready         ),
     .s_axis_udp_rx_meta_b_TDATA          ( s_axis_udp_rx_meta_b_tdata          ),
     .s_axis_udp_rx_meta_b_TKEEP          ( s_axis_udp_rx_meta_b_tkeep          ),
     .s_axis_udp_rx_meta_b_TLAST          ( s_axis_udp_rx_meta_b_tlast          ),

     .m_axis_udp_tx_meta_b_TVALID         ( m_axis_udp_tx_meta_b_tvalid         ),
     .m_axis_udp_tx_meta_b_TREADY         ( m_axis_udp_tx_meta_b_tready         ),
     .m_axis_udp_tx_meta_b_TDATA          ( m_axis_udp_tx_meta_b_tdata          ),
     .m_axis_udp_tx_meta_b_TKEEP          ( m_axis_udp_tx_meta_b_tkeep          ),
     .m_axis_udp_tx_meta_b_TLAST          ( m_axis_udp_tx_meta_b_tlast          ),

     .m_axis_tcp_listen_port_b_TVALID     ( m_axis_tcp_listen_port_b_tvalid     ),
     .m_axis_tcp_listen_port_b_TREADY     ( m_axis_tcp_listen_port_b_tready     ),
     .m_axis_tcp_listen_port_b_TDATA      ( m_axis_tcp_listen_port_b_tdata      ),
     .m_axis_tcp_listen_port_b_TKEEP      ( m_axis_tcp_listen_port_b_tkeep      ),
     .m_axis_tcp_listen_port_b_TLAST      ( m_axis_tcp_listen_port_b_tlast      ),

     .s_axis_tcp_port_status_b_TVALID     ( s_axis_tcp_port_status_b_tvalid     ),
     .s_axis_tcp_port_status_b_TREADY     ( s_axis_tcp_port_status_b_tready     ),
     .s_axis_tcp_port_status_b_TDATA      ( s_axis_tcp_port_status_b_tdata      ),
     .s_axis_tcp_port_status_b_TKEEP      ( s_axis_tcp_port_status_b_tkeep      ),
     .s_axis_tcp_port_status_b_TLAST      ( s_axis_tcp_port_status_b_tlast      ),

     .m_axis_tcp_open_connection_b_TVALID ( m_axis_tcp_open_connection_b_tvalid ),
     .m_axis_tcp_open_connection_b_TREADY ( m_axis_tcp_open_connection_b_tready ),
     .m_axis_tcp_open_connection_b_TDATA  ( m_axis_tcp_open_connection_b_tdata  ),
     .m_axis_tcp_open_connection_b_TKEEP  ( m_axis_tcp_open_connection_b_tkeep  ),
     .m_axis_tcp_open_connection_b_TLAST  ( m_axis_tcp_open_connection_b_tlast  ),

     .s_axis_tcp_open_status_b_TVALID     ( s_axis_tcp_open_status_b_tvalid     ),
     .s_axis_tcp_open_status_b_TREADY     ( s_axis_tcp_open_status_b_tready     ),
     .s_axis_tcp_open_status_b_TDATA      ( s_axis_tcp_open_status_b_tdata      ),
     .s_axis_tcp_open_status_b_TKEEP      ( s_axis_tcp_open_status_b_tkeep      ),
     .s_axis_tcp_open_status_b_TLAST      ( s_axis_tcp_open_status_b_tlast      ),

     .m_axis_tcp_close_connection_b_TVALID( m_axis_tcp_close_connection_b_tvalid),
     .m_axis_tcp_close_connection_b_TREADY( m_axis_tcp_close_connection_b_tready),
     .m_axis_tcp_close_connection_b_TDATA ( m_axis_tcp_close_connection_b_tdata ),
     .m_axis_tcp_close_connection_b_TKEEP ( m_axis_tcp_close_connection_b_tkeep ),
     .m_axis_tcp_close_connection_b_TLAST ( m_axis_tcp_close_connection_b_tlast ),

     .s_axis_tcp_notification_b_TVALID    ( s_axis_tcp_notification_b_tvalid    ),
     .s_axis_tcp_notification_b_TREADY    ( s_axis_tcp_notification_b_tready    ),
     .s_axis_tcp_notification_b_TDATA     ( s_axis_tcp_notification_b_tdata     ),
     .s_axis_tcp_notification_b_TKEEP     ( s_axis_tcp_notification_b_tkeep     ),
     .s_axis_tcp_notification_b_TLAST     ( s_axis_tcp_notification_b_tlast     ),

     .m_axis_tcp_read_pkg_b_TVALID        ( m_axis_tcp_read_pkg_b_tvalid        ),
     .m_axis_tcp_read_pkg_b_TREADY        ( m_axis_tcp_read_pkg_b_tready        ),
     .m_axis_tcp_read_pkg_b_TDATA         ( m_axis_tcp_read_pkg_b_tdata         ),
     .m_axis_tcp_read_pkg_b_TKEEP         ( m_axis_tcp_read_pkg_b_tkeep         ),
     .m_axis_tcp_read_pkg_b_TLAST         ( m_axis_tcp_read_pkg_b_tlast         ),

     .s_axis_tcp_rx_meta_b_TVALID         ( s_axis_tcp_rx_meta_b_tvalid         ),
     .s_axis_tcp_rx_meta_b_TREADY         ( s_axis_tcp_rx_meta_b_tready         ),
     .s_axis_tcp_rx_meta_b_TDATA          ( s_axis_tcp_rx_meta_b_tdata          ),
     .s_axis_tcp_rx_meta_b_TKEEP          ( s_axis_tcp_rx_meta_b_tkeep          ),
     .s_axis_tcp_rx_meta_b_TLAST          ( s_axis_tcp_rx_meta_b_tlast          ),

     .s_axis_tcp_rx_data_b_TVALID         ( s_axis_tcp_rx_data_b_tvalid         ),
     .s_axis_tcp_rx_data_b_TREADY         ( s_axis_tcp_rx_data_b_tready         ),
     .s_axis_tcp_rx_data_b_TDATA          ( s_axis_tcp_rx_data_b_tdata          ),
     .s_axis_tcp_rx_data_b_TKEEP          ( s_axis_tcp_rx_data_b_tkeep          ),
     .s_axis_tcp_rx_data_b_TLAST          ( s_axis_tcp_rx_data_b_tlast          ),

     .m_axis_tcp_tx_meta_b_TVALID         ( m_axis_tcp_tx_meta_b_tvalid         ),
     .m_axis_tcp_tx_meta_b_TREADY         ( m_axis_tcp_tx_meta_b_tready         ),
     .m_axis_tcp_tx_meta_b_TDATA          ( m_axis_tcp_tx_meta_b_tdata          ),
     .m_axis_tcp_tx_meta_b_TKEEP          ( m_axis_tcp_tx_meta_b_tkeep          ),
     .m_axis_tcp_tx_meta_b_TLAST          ( m_axis_tcp_tx_meta_b_tlast          ),

     .m_axis_tcp_tx_data_b_TVALID         ( m_axis_tcp_tx_data_b_tvalid         ),
     .m_axis_tcp_tx_data_b_TREADY         ( m_axis_tcp_tx_data_b_tready         ),
     .m_axis_tcp_tx_data_b_TDATA          ( m_axis_tcp_tx_data_b_tdata          ),
     .m_axis_tcp_tx_data_b_TKEEP          ( m_axis_tcp_tx_data_b_tkeep          ),
     .m_axis_tcp_tx_data_b_TLAST          ( m_axis_tcp_tx_data_b_tlast          ),

     .s_axis_tcp_tx_status_b_TVALID       ( s_axis_tcp_tx_status_b_tvalid       ),
     .s_axis_tcp_tx_status_b_TREADY       ( s_axis_tcp_tx_status_b_tready       ),
     .s_axis_tcp_tx_status_b_TDATA        ( s_axis_tcp_tx_status_b_tdata        ),
     .s_axis_tcp_tx_status_b_TKEEP        ( s_axis_tcp_tx_status_b_tkeep        ),
     .s_axis_tcp_tx_status_b_TLAST        ( s_axis_tcp_tx_status_b_tlast        ),

     // ── скаляры: провода, а не регистры ──────────────────────────────────
     .listenPortA      ( listenPortA_reg  ),
     .listenPortB      ( listenPortB_reg  ),

     // ОДИН регистр enable (0x10) на ДВА порта ядра. Снаружи это по-прежнему
     // один enable — адресная карта не менялась.
     //
     // Раздельные порты нужны потому, что при одном аргументе его читали обе
     // половины, и HLS раздал их несимметрично: половине a провод, половине b
     // FIFO-канал p_c_U с блокировкой по empty_n. Половина b вставала на пустом
     // канале, а через ap_ready/ap_continue DATAFLOW-региона вставала и a.
     // На плате это выглядело так: регистры живые, enable=1 читается обратно,
     // а listenAttempts=0 и вся телеметрия нули навсегда.
     .enableA          ( enable_reg       ),
     .enableB          ( enable_reg       ),

     .listenAttempts_a ( listenAttempts_a ),
     .portState_a      ( portState_a      ),
     .notifyCount_a    ( notifyCount_a    ),
     .listenAttempts_b ( listenAttempts_b ),
     .portState_b      ( portState_b      ),
     .notifyCount_b    ( notifyCount_b    )
);

endmodule

`default_nettype wire
