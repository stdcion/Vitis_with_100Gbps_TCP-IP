// =============================================================================
// hls_echo_probe_dual_krnl_wrapper -- HDL-обёртка вокруг free-running HLS-ядра
// =============================================================================
//
// ЗАЧЕМ. HLS-функция hls_echo_probe_dual_krnl объявлена ap_ctrl_none и не имеет
// ни одного s_axilite (иначе HLS молча защёлкивает скаляры один раз после
// сброса -- см. шапку probe_control_s_axi.v). Значит регистры управления должен
// держать кто-то снаружи. Это и делает данный модуль:
//
//   * инстанцирует probe_control_s_axi.v -- регистры AXI4-Lite;
//   * отдаёт 6 параметров в ядро ПРОВОДАМИ;
//   * принимает 12 значений телеметрии из ядра проводами и отдаёт на чтение;
//   * реализует блочный протокол ap_ctrl_hs, который ждёт BD/XRT.
//
// Обёртка скопирована с hls_dual_echo_krnl_wrapper.sv -- ядра, которое на этом
// железе прошло имплементацию (WNS=+0.0167, WHS=+0.0097) и собрало битстрим.
// Набор AXI-Stream портов у двух ядер ИДЕНТИЧЕН (32 потока, те же имена),
// поэтому эта часть перенесена без изменений; отличается только состав
// скаляров: 6 входов вместо 3 и 12 выходов вместо 6.
//
// ЧЕМ probe ОТЛИЧАЕТСЯ ПРИНЦИПИАЛЬНО. Среди входов есть triggerGo, который
// меняется МНОГОКРАТНО во время работы -- по разу на каждый замер. Для
// dual_echo обёртка была правильным решением; здесь она ЕДИНСТВЕННОЕ рабочее:
// при s_axilite + ap_ctrl_none защёлка происходит однажды после сброса, и
// второй замер не запустился бы НИКОГДА. В .cpp это описано как "оговорка про
// triggerGo" (hls_echo_probe_dual_krnl.cpp:1146) с резервным планом "убрать
// DATAFLOW с верхнего уровня" -- обёртка решает ту же задачу, не трогая логику
// и не теряя II=1.
//
// ПРО ap_done И auto_restart. Ядро внутри бесконечное: оно никогда не
// «заканчивает» и ap_done само выставить не может. Поэтому обёртка объявляет
// его завершённым сразу после старта:
//
//     assign ap_done = ap_start_pulse;
//
// Ровно та же уловка, что в network_krnl, только там ap_done дёргается по
// таймеру раз в секунду (network_stack.sv:921). Смысл один: дать хосту
// корректный handshake, не останавливая логику. Работа ядра от ap_done НЕ
// зависит вообще -- оно течёт с первого такта после снятия сброса, потому что
// ap_ctrl_none. ap_start здесь нужен только чтобы:
//
//   1. хост мог отличить «битстрим жив, регистры отвечают» от тишины;
//   2. существовал ap_start_pulse -- программный сброс счётчиков;
//   3. BD видел ожидаемый ap_ctrl_hs-интерфейс.
//
// Разрешение работы даёт НЕ ap_start, а регистр enable.
//
// ИМЕНА AXI-STREAM ПОРТОВ НЕ МЕНЯТЬ. Они дословно совпадают с
// config_sp_hls_echo_probe_dual_krnl_dual.txt (s_axis_*_a / m_axis_*_b и т.д.).
// Обёртка их только пробрасывает: сигнатура снаружи остаётся такой же, какой её
// видел BD до появления обёртки, поэтому build_bd.tcl и config_sp править не
// нужно.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module hls_echo_probe_dual_krnl_wrapper #(
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

// ── ЕДИНАЯ ШКАЛА ВРЕМЕНИ ДЛЯ ОБЕИХ ПОЛОВИН ───────────────────────────────────
//
// Все четыре таймстемпа замера обязаны быть в ОДНОЙ шкале, иначе NET_FWD и
// NET_REV считаются неправильно. Смотрите, какие точки откуда берутся:
//
//     t1' = tx_data_a   клиент  (половина a)
//     t2' = rx_data_b   эхо     (половина b)
//     t1  = tx_data_b   эхо     (половина b)
//     t2  = rx_data_a   клиент  (половина a)
//
//     NET_FWD = t2' - t1'   <- ВЫЧИТАЕТ ЭХО МИНУС КЛИЕНТ
//     NET_REV = t2  - t1    <- ВЫЧИТАЕТ КЛИЕНТ МИНУС ЭХО
//
// Раньше каждая половина держала свой static ap_uint<32> cyc внутри HLS
// (epd_client_traffic и epd_server_echo). Комментарий там утверждал, что шкалы
// синхронны, потому что оба счётчика тикают от ap_clk и стартуют с одного
// сброса. При Final II = 1 это действительно так — но это свойство РАСПИСАНИЯ
// HLS, а не свойство кода. Стоит одной стадии получить II=2 (probe-ядро плотнее
// dual_echo, depth у обеих стадий уже 3), и счётчики начинают расходиться
// линейно.
//
// ЧЕМ ЭТО ОПАСНО ИМЕННО ЗДЕСЬ. Расхождение на N тактов завышает NET_FWD ровно
// на N и занижает NET_REV ровно на N. При этом:
//   * RTT  = t2 - t1'  (оба от клиента) — ОСТАЁТСЯ ВЕРНЫМ;
//   * ECHO = t1 - t2'  (оба от эха)     — ОСТАЁТСЯ ВЕРНЫМ;
//   * баланс NET_FWD + ECHO + NET_REV == RTT — СХОДИТСЯ ВСЕГДА, смещение
//     взаимно уничтожается.
// То есть ни одна проверка на хосте этого не увидит: epd_raw пометит замер
// как ok. Симптом — стабильная асимметрия NET_FWD против NET_REV на физически
// симметричном тракте, которую легко списать на «асимметрию стека».
//
// Поэтому счётчик ОДИН и живёт здесь, в HDL. Он идёт в ядро проводом и
// раздаётся обеим половинам, так что единая шкала — свойство схемы, а не
// свойство того, что решил планировщик.
//
// Разрядность 32 бита, как и было: на 165 МГц оборот раз в ~26 с. Измерению
// это не мешает, вычитание беззнаковое по модулю 2^32 (см. пояснение к
// таймстемпам в hls_echo_probe_dual_krnl.cpp).
//
// Сброс — по ap_rst_n, тому же, что сбрасывает логику ядра, поэтому шкала
// начинается там же, где начинается работа. От ap_start НЕ зависит: ядро
// ap_ctrl_none и течёт с первого такта после снятия сброса.
logic [31:0] cycle_counter = 32'b0;

always @(posedge ap_clk) begin
     if (~ap_rst_n)
          cycle_counter <= 32'b0;
     else
          cycle_counter <= cycle_counter + 32'd1;
end

// ── регистры <-> провода ─────────────────────────────────────────────────────
wire [31:0] enable_reg;
wire [31:0] serverIp_reg;
wire [31:0] serverPort_reg;
wire [31:0] listenPort_reg;
wire [31:0] msgBytes_reg;
wire [31:0] triggerGo_reg;

wire [31:0] connAttempts;
wire [31:0] sentCount;
wire [31:0] recvCount;
wire [31:0] timeoutCount;
wire [31:0] echoCount;
wire [31:0] listenAttempts;
wire [31:0] portState;
wire [31:0] tsRequest;
wire [31:0] tsEchoIn;
wire [31:0] tsEchoOut;
wire [31:0] tsReply;
wire [31:0] sampleReady;

probe_control_s_axi #(
     .C_S_AXI_ADDR_WIDTH ( C_S_AXI_CONTROL_ADDR_WIDTH ),
     .C_S_AXI_DATA_WIDTH ( C_S_AXI_CONTROL_DATA_WIDTH )
) inst_control_s_axi (
     .ACLK           ( ap_clk                 ),
     .ARESET         ( ~ap_rst_n              ),
     .ACLK_EN        ( 1'b1                   ),
     .AWVALID        ( s_axi_control_awvalid  ),
     .AWREADY        ( s_axi_control_awready  ),
     .AWADDR         ( s_axi_control_awaddr   ),
     .WVALID         ( s_axi_control_wvalid   ),
     .WREADY         ( s_axi_control_wready   ),
     .WDATA          ( s_axi_control_wdata    ),
     .WSTRB          ( s_axi_control_wstrb    ),
     .ARVALID        ( s_axi_control_arvalid  ),
     .ARREADY        ( s_axi_control_arready  ),
     .ARADDR         ( s_axi_control_araddr   ),
     .RVALID         ( s_axi_control_rvalid   ),
     .RREADY         ( s_axi_control_rready   ),
     .RDATA          ( s_axi_control_rdata    ),
     .RRESP          ( s_axi_control_rresp    ),
     .BVALID         ( s_axi_control_bvalid   ),
     .BREADY         ( s_axi_control_bready   ),
     .BRESP          ( s_axi_control_bresp    ),
     .interrupt      ( interrupt              ),
     .ap_start       ( ap_start               ),
     .ap_done        ( ap_done                ),
     .ap_ready       ( ap_ready               ),
     .ap_idle        ( ap_idle                ),
     .enable         ( enable_reg             ),
     .serverIp       ( serverIp_reg           ),
     .serverPort     ( serverPort_reg         ),
     .listenPort     ( listenPort_reg         ),
     .msgBytes       ( msgBytes_reg           ),
     .triggerGo      ( triggerGo_reg          ),
     .connAttempts   ( connAttempts           ),
     .sentCount      ( sentCount              ),
     .recvCount      ( recvCount              ),
     .timeoutCount   ( timeoutCount           ),
     .echoCount      ( echoCount              ),
     .listenAttempts ( listenAttempts         ),
     .portState      ( portState              ),
     .tsRequest      ( tsRequest              ),
     .tsEchoIn       ( tsEchoIn               ),
     .tsEchoOut      ( tsEchoOut              ),
     .tsReply        ( tsReply                ),
     .sampleReady    ( sampleReady            )
);

// ── HLS-ядро ─────────────────────────────────────────────────────────────────
//
// Имя модуля задаётся при упаковке IP (create_ip -module_name
// hls_echo_probe_dual_krnl_ip, см. package_hls_echo_probe_dual_krnl.tcl).
//
// Скаляры идут ПРОВОДАМИ: ap_ctrl_none-ядро видит их каждый такт, поэтому
// момент записи по JTAG не важен. Для triggerGo это не удобство, а условие
// работы — см. шапку.
hls_echo_probe_dual_krnl_ip hls_echo_probe_dual_krnl_inst (
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
     .serverIp       ( serverIp_reg   ),
     .serverPort     ( serverPort_reg ),
     .listenPort     ( listenPort_reg ),
     .msgBytes       ( msgBytes_reg   ),
     .triggerGo      ( triggerGo_reg  ),
     .enable         ( enable_reg     ),

     // Единая шкала времени для обеих половин — см. пояснение выше.
     // НЕ регистр управления: хост его не пишет и не читает, в
     // probe_control_s_axi.v его нет. Это провод из счётчика в этой обёртке.
     .cycleCount     ( cycle_counter  ),

     .connAttempts   ( connAttempts   ),
     .sentCount      ( sentCount      ),
     .recvCount      ( recvCount      ),
     .timeoutCount   ( timeoutCount   ),
     .echoCount      ( echoCount      ),
     .listenAttempts ( listenAttempts ),
     .portState      ( portState      ),
     .tsRequest      ( tsRequest      ),
     .tsEchoIn       ( tsEchoIn       ),
     .tsEchoOut      ( tsEchoOut      ),
     .tsReply        ( tsReply        ),
     .sampleReady    ( sampleReady    )
);

endmodule

`default_nettype wire
