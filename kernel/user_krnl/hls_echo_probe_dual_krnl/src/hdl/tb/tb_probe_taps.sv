// =============================================================================
// tb_probe_taps -- врезки axis_net_* в обёртке: прозрачность, каналы, регистры
// =============================================================================
//
// ЗАЧЕМ. Это единственная проверка того, что ФИЗИЧЕСКИ подключено, а не того,
// как задумано. Она ловит три класса ошибок, которых не видит ни одна модель и
// ни один grep:
//
//   1. ВРЕЗКА НЕ ПРОЗРАЧНА. passthrough — это 20 assign'ов; перепутанный или
//      забытый означает потерянный/искажённый трафик на боевом пути между
//      network_krnl и cmac_krnl. Симптом на плате — «линк есть, а соединение не
//      открывается», и искать это будут в стеке, а не во врезке.
//
//   2. ПЕРЕПУТАНЫ КАНАЛЫ. Если T1' и T1 (или каналы a/b) поменять местами, BD
//      соберётся, замер пройдёт, а числа будут выглядеть как «асимметрия
//      тракта». Проект врезок прямо называет это худшим исходом: он обманет.
//
//   3. ТАЙМСТЕМП НЕ ТУДА. Все четыре T читаются из соседних регистров
//      (0x78..0x84); перепутанные местами дают правдоподобную чушь.
//
// КАК ПРОВЕРЯЕТСЯ ПУНКТ 2/3. Каждая из четырёх врезок получает кадр СВОЕЙ
// длины, в РАЗНЫЕ моменты времени. Тогда по разности таймстемпов однозначно
// видно, какой регистр к какой врезке относится, — совпадение было бы
// случайностью.
//
// ЧЕГО ЭТОТ ТЕСТБЕНЧ НЕ ДЕЛАЕТ. Он НЕ инстанцирует HLS-ядро: его RTL появляется
// только после csynth+export, а обёртка ссылается на него по имени
// hls_echo_probe_dual_krnl_ip. Поэтому здесь стоит ЗАГЛУШКА (см. ниже) — этого
// достаточно, потому что axis_net_* в ядро не идут вообще, врезки живут целиком
// в обёртке. Логику ядра проверяет csim.
//
// ЗАПУСК: src/hdl/tb/run_sim.sh

`timescale 1ns / 1ps
`default_nettype none

// ПОЧЕМУ МАКРОС, А НЕ task check(input string name, ...).
//
// Сначала было `input [255:0] name` -- вектор на 32 байта, и сообщения на
// кириллице (2 байта на символ в UTF-8) обрезались посередине: прогон 13.08
// печатал «ok   М (tag=6  SYN» вместо полной строки. Замена на `input string`
// НЕ ПОМОГЛА -- xvlog 2024.1 всё равно приводит аргумент задачи к вектору.
//
// Макрос решает это тем, что строка НИКУДА НЕ ПЕРЕДАЁТСЯ: литерал
// подставляется прямо в $display на месте вызова, где длина ничем не
// ограничена.
//
// Тело обёрнуто в begin/end намеренно: голый if/else в макросе присоединил бы
// чужой else, если вызов окажется внутри незаскобленного if. Здесь таких мест
// нет, но макрос переживёт правку тестбенча.
`define check(NAME, COND) \
     begin \
          if (COND) $display("  ok   %0s", NAME); \
          else begin $display("  FAIL %0s", NAME); errors = errors + 1; end \
     end


// ─────────────────────────────────────────────────────────────────────────────
// Заглушка HLS-ядра.
//
// Обёртка инстанцирует hls_echo_probe_dual_krnl_ip. Настоящий RTL этого модуля
// генерируется csynth'ом и здесь недоступен, но для проверки ВРЕЗОК он и не
// нужен: axis_net_* в ядро не заходят. Заглушка держит все выходы в нуле и
// принимает всё, что ей дают.
//
// ВАЖНО: список портов должен совпадать с тем, что подключает обёртка. Если
// обёртка изменится, xelab упадёт с «port not found» — и это правильно, лучше
// падение здесь, чем расхождение в BD.
// ─────────────────────────────────────────────────────────────────────────────
module hls_echo_probe_dual_krnl_ip (
     input  wire ap_clk,
     input  wire ap_rst_n,

     // Половины a и b: 16 потоков на каждую. Объявлены обобщённо через
     // директиву -- см. ниже, здесь просто перечислены все сигналы.
     // (Verilog не умеет генерировать порты, поэтому руками.)
     input  wire s_axis_udp_rx_a_TVALID,              output wire s_axis_udp_rx_a_TREADY,
     input  wire [511:0] s_axis_udp_rx_a_TDATA,       input  wire [63:0] s_axis_udp_rx_a_TKEEP,
     input  wire s_axis_udp_rx_a_TLAST,
     output wire m_axis_udp_tx_a_TVALID,              input  wire m_axis_udp_tx_a_TREADY,
     output wire [511:0] m_axis_udp_tx_a_TDATA,       output wire [63:0] m_axis_udp_tx_a_TKEEP,
     output wire m_axis_udp_tx_a_TLAST,
     input  wire s_axis_udp_rx_meta_a_TVALID,         output wire s_axis_udp_rx_meta_a_TREADY,
     input  wire [255:0] s_axis_udp_rx_meta_a_TDATA,  input  wire [31:0] s_axis_udp_rx_meta_a_TKEEP,
     input  wire s_axis_udp_rx_meta_a_TLAST,
     output wire m_axis_udp_tx_meta_a_TVALID,         input  wire m_axis_udp_tx_meta_a_TREADY,
     output wire [255:0] m_axis_udp_tx_meta_a_TDATA,  output wire [31:0] m_axis_udp_tx_meta_a_TKEEP,
     output wire m_axis_udp_tx_meta_a_TLAST,
     output wire m_axis_tcp_listen_port_a_TVALID,     input  wire m_axis_tcp_listen_port_a_TREADY,
     output wire [15:0] m_axis_tcp_listen_port_a_TDATA, output wire [1:0] m_axis_tcp_listen_port_a_TKEEP,
     output wire m_axis_tcp_listen_port_a_TLAST,
     input  wire s_axis_tcp_port_status_a_TVALID,     output wire s_axis_tcp_port_status_a_TREADY,
     input  wire [7:0] s_axis_tcp_port_status_a_TDATA, input wire [0:0] s_axis_tcp_port_status_a_TKEEP,
     input  wire s_axis_tcp_port_status_a_TLAST,
     output wire m_axis_tcp_open_connection_a_TVALID, input  wire m_axis_tcp_open_connection_a_TREADY,
     output wire [63:0] m_axis_tcp_open_connection_a_TDATA, output wire [7:0] m_axis_tcp_open_connection_a_TKEEP,
     output wire m_axis_tcp_open_connection_a_TLAST,
     input  wire s_axis_tcp_open_status_a_TVALID,     output wire s_axis_tcp_open_status_a_TREADY,
     input  wire [127:0] s_axis_tcp_open_status_a_TDATA, input wire [15:0] s_axis_tcp_open_status_a_TKEEP,
     input  wire s_axis_tcp_open_status_a_TLAST,
     output wire m_axis_tcp_close_connection_a_TVALID, input wire m_axis_tcp_close_connection_a_TREADY,
     output wire [15:0] m_axis_tcp_close_connection_a_TDATA, output wire [1:0] m_axis_tcp_close_connection_a_TKEEP,
     output wire m_axis_tcp_close_connection_a_TLAST,
     input  wire s_axis_tcp_notification_a_TVALID,    output wire s_axis_tcp_notification_a_TREADY,
     input  wire [127:0] s_axis_tcp_notification_a_TDATA, input wire [15:0] s_axis_tcp_notification_a_TKEEP,
     input  wire s_axis_tcp_notification_a_TLAST,
     output wire m_axis_tcp_read_pkg_a_TVALID,        input  wire m_axis_tcp_read_pkg_a_TREADY,
     output wire [31:0] m_axis_tcp_read_pkg_a_TDATA,  output wire [3:0] m_axis_tcp_read_pkg_a_TKEEP,
     output wire m_axis_tcp_read_pkg_a_TLAST,
     input  wire s_axis_tcp_rx_meta_a_TVALID,         output wire s_axis_tcp_rx_meta_a_TREADY,
     input  wire [15:0] s_axis_tcp_rx_meta_a_TDATA,   input  wire [1:0] s_axis_tcp_rx_meta_a_TKEEP,
     input  wire s_axis_tcp_rx_meta_a_TLAST,
     input  wire s_axis_tcp_rx_data_a_TVALID,         output wire s_axis_tcp_rx_data_a_TREADY,
     input  wire [511:0] s_axis_tcp_rx_data_a_TDATA,  input  wire [63:0] s_axis_tcp_rx_data_a_TKEEP,
     input  wire s_axis_tcp_rx_data_a_TLAST,
     output wire m_axis_tcp_tx_meta_a_TVALID,         input  wire m_axis_tcp_tx_meta_a_TREADY,
     output wire [31:0] m_axis_tcp_tx_meta_a_TDATA,   output wire [3:0] m_axis_tcp_tx_meta_a_TKEEP,
     output wire m_axis_tcp_tx_meta_a_TLAST,
     output wire m_axis_tcp_tx_data_a_TVALID,         input  wire m_axis_tcp_tx_data_a_TREADY,
     output wire [511:0] m_axis_tcp_tx_data_a_TDATA,  output wire [63:0] m_axis_tcp_tx_data_a_TKEEP,
     output wire m_axis_tcp_tx_data_a_TLAST,
     input  wire s_axis_tcp_tx_status_a_TVALID,       output wire s_axis_tcp_tx_status_a_TREADY,
     input  wire [63:0] s_axis_tcp_tx_status_a_TDATA, input  wire [7:0] s_axis_tcp_tx_status_a_TKEEP,
     input  wire s_axis_tcp_tx_status_a_TLAST,

     input  wire s_axis_udp_rx_b_TVALID,              output wire s_axis_udp_rx_b_TREADY,
     input  wire [511:0] s_axis_udp_rx_b_TDATA,       input  wire [63:0] s_axis_udp_rx_b_TKEEP,
     input  wire s_axis_udp_rx_b_TLAST,
     output wire m_axis_udp_tx_b_TVALID,              input  wire m_axis_udp_tx_b_TREADY,
     output wire [511:0] m_axis_udp_tx_b_TDATA,       output wire [63:0] m_axis_udp_tx_b_TKEEP,
     output wire m_axis_udp_tx_b_TLAST,
     input  wire s_axis_udp_rx_meta_b_TVALID,         output wire s_axis_udp_rx_meta_b_TREADY,
     input  wire [255:0] s_axis_udp_rx_meta_b_TDATA,  input  wire [31:0] s_axis_udp_rx_meta_b_TKEEP,
     input  wire s_axis_udp_rx_meta_b_TLAST,
     output wire m_axis_udp_tx_meta_b_TVALID,         input  wire m_axis_udp_tx_meta_b_TREADY,
     output wire [255:0] m_axis_udp_tx_meta_b_TDATA,  output wire [31:0] m_axis_udp_tx_meta_b_TKEEP,
     output wire m_axis_udp_tx_meta_b_TLAST,
     output wire m_axis_tcp_listen_port_b_TVALID,     input  wire m_axis_tcp_listen_port_b_TREADY,
     output wire [15:0] m_axis_tcp_listen_port_b_TDATA, output wire [1:0] m_axis_tcp_listen_port_b_TKEEP,
     output wire m_axis_tcp_listen_port_b_TLAST,
     input  wire s_axis_tcp_port_status_b_TVALID,     output wire s_axis_tcp_port_status_b_TREADY,
     input  wire [7:0] s_axis_tcp_port_status_b_TDATA, input wire [0:0] s_axis_tcp_port_status_b_TKEEP,
     input  wire s_axis_tcp_port_status_b_TLAST,
     output wire m_axis_tcp_open_connection_b_TVALID, input  wire m_axis_tcp_open_connection_b_TREADY,
     output wire [63:0] m_axis_tcp_open_connection_b_TDATA, output wire [7:0] m_axis_tcp_open_connection_b_TKEEP,
     output wire m_axis_tcp_open_connection_b_TLAST,
     input  wire s_axis_tcp_open_status_b_TVALID,     output wire s_axis_tcp_open_status_b_TREADY,
     input  wire [127:0] s_axis_tcp_open_status_b_TDATA, input wire [15:0] s_axis_tcp_open_status_b_TKEEP,
     input  wire s_axis_tcp_open_status_b_TLAST,
     output wire m_axis_tcp_close_connection_b_TVALID, input wire m_axis_tcp_close_connection_b_TREADY,
     output wire [15:0] m_axis_tcp_close_connection_b_TDATA, output wire [1:0] m_axis_tcp_close_connection_b_TKEEP,
     output wire m_axis_tcp_close_connection_b_TLAST,
     input  wire s_axis_tcp_notification_b_TVALID,    output wire s_axis_tcp_notification_b_TREADY,
     input  wire [127:0] s_axis_tcp_notification_b_TDATA, input wire [15:0] s_axis_tcp_notification_b_TKEEP,
     input  wire s_axis_tcp_notification_b_TLAST,
     output wire m_axis_tcp_read_pkg_b_TVALID,        input  wire m_axis_tcp_read_pkg_b_TREADY,
     output wire [31:0] m_axis_tcp_read_pkg_b_TDATA,  output wire [3:0] m_axis_tcp_read_pkg_b_TKEEP,
     output wire m_axis_tcp_read_pkg_b_TLAST,
     input  wire s_axis_tcp_rx_meta_b_TVALID,         output wire s_axis_tcp_rx_meta_b_TREADY,
     input  wire [15:0] s_axis_tcp_rx_meta_b_TDATA,   input  wire [1:0] s_axis_tcp_rx_meta_b_TKEEP,
     input  wire s_axis_tcp_rx_meta_b_TLAST,
     input  wire s_axis_tcp_rx_data_b_TVALID,         output wire s_axis_tcp_rx_data_b_TREADY,
     input  wire [511:0] s_axis_tcp_rx_data_b_TDATA,  input  wire [63:0] s_axis_tcp_rx_data_b_TKEEP,
     input  wire s_axis_tcp_rx_data_b_TLAST,
     output wire m_axis_tcp_tx_meta_b_TVALID,         input  wire m_axis_tcp_tx_meta_b_TREADY,
     output wire [31:0] m_axis_tcp_tx_meta_b_TDATA,   output wire [3:0] m_axis_tcp_tx_meta_b_TKEEP,
     output wire m_axis_tcp_tx_meta_b_TLAST,
     output wire m_axis_tcp_tx_data_b_TVALID,         input  wire m_axis_tcp_tx_data_b_TREADY,
     output wire [511:0] m_axis_tcp_tx_data_b_TDATA,  output wire [63:0] m_axis_tcp_tx_data_b_TKEEP,
     output wire m_axis_tcp_tx_data_b_TLAST,
     input  wire s_axis_tcp_tx_status_b_TVALID,       output wire s_axis_tcp_tx_status_b_TREADY,
     input  wire [63:0] s_axis_tcp_tx_status_b_TDATA, input  wire [7:0] s_axis_tcp_tx_status_b_TKEEP,
     input  wire s_axis_tcp_tx_status_b_TLAST,

     // скаляры
     input  wire [31:0] serverIp,
     input  wire [31:0] serverPort,
     input  wire [31:0] listenPort,
     input  wire [31:0] msgBytes,
     input  wire [31:0] triggerGo,
     input  wire [31:0] enableConn,
     input  wire [31:0] enableTraffic,
     input  wire [31:0] enableListen,

     output wire [31:0] connAttempts,
     output wire [31:0] sentCount,       output wire sentCount_ap_vld,
     output wire [31:0] recvCount,       output wire recvCount_ap_vld,
     output wire [31:0] timeoutCount,
     output wire [31:0] echoRxCount,     output wire echoRxCount_ap_vld,
     output wire [31:0] echoCount,       output wire echoCount_ap_vld,
     output wire [31:0] listenAttempts,
     output wire [31:0] portState
);
     // Всё в ноль: врезки от ядра не зависят.
     assign {s_axis_udp_rx_a_TREADY, s_axis_udp_rx_meta_a_TREADY,
             s_axis_tcp_port_status_a_TREADY, s_axis_tcp_open_status_a_TREADY,
             s_axis_tcp_notification_a_TREADY, s_axis_tcp_rx_meta_a_TREADY,
             s_axis_tcp_rx_data_a_TREADY, s_axis_tcp_tx_status_a_TREADY,
             s_axis_udp_rx_b_TREADY, s_axis_udp_rx_meta_b_TREADY,
             s_axis_tcp_port_status_b_TREADY, s_axis_tcp_open_status_b_TREADY,
             s_axis_tcp_notification_b_TREADY, s_axis_tcp_rx_meta_b_TREADY,
             s_axis_tcp_rx_data_b_TREADY, s_axis_tcp_tx_status_b_TREADY} = {16{1'b1}};

     assign {m_axis_udp_tx_a_TVALID, m_axis_udp_tx_meta_a_TVALID,
             m_axis_tcp_listen_port_a_TVALID, m_axis_tcp_open_connection_a_TVALID,
             m_axis_tcp_close_connection_a_TVALID, m_axis_tcp_read_pkg_a_TVALID,
             m_axis_tcp_tx_meta_a_TVALID, m_axis_tcp_tx_data_a_TVALID,
             m_axis_udp_tx_b_TVALID, m_axis_udp_tx_meta_b_TVALID,
             m_axis_tcp_listen_port_b_TVALID, m_axis_tcp_open_connection_b_TVALID,
             m_axis_tcp_close_connection_b_TVALID, m_axis_tcp_read_pkg_b_TVALID,
             m_axis_tcp_tx_meta_b_TVALID, m_axis_tcp_tx_data_b_TVALID} = {16{1'b0}};

     assign m_axis_udp_tx_a_TDATA = 512'b0; assign m_axis_udp_tx_a_TKEEP = 64'b0; assign m_axis_udp_tx_a_TLAST = 1'b0;
     assign m_axis_udp_tx_meta_a_TDATA = 256'b0; assign m_axis_udp_tx_meta_a_TKEEP = 32'b0; assign m_axis_udp_tx_meta_a_TLAST = 1'b0;
     assign m_axis_tcp_listen_port_a_TDATA = 16'b0; assign m_axis_tcp_listen_port_a_TKEEP = 2'b0; assign m_axis_tcp_listen_port_a_TLAST = 1'b0;
     assign m_axis_tcp_open_connection_a_TDATA = 64'b0; assign m_axis_tcp_open_connection_a_TKEEP = 8'b0; assign m_axis_tcp_open_connection_a_TLAST = 1'b0;
     assign m_axis_tcp_close_connection_a_TDATA = 16'b0; assign m_axis_tcp_close_connection_a_TKEEP = 2'b0; assign m_axis_tcp_close_connection_a_TLAST = 1'b0;
     assign m_axis_tcp_read_pkg_a_TDATA = 32'b0; assign m_axis_tcp_read_pkg_a_TKEEP = 4'b0; assign m_axis_tcp_read_pkg_a_TLAST = 1'b0;
     assign m_axis_tcp_tx_meta_a_TDATA = 32'b0; assign m_axis_tcp_tx_meta_a_TKEEP = 4'b0; assign m_axis_tcp_tx_meta_a_TLAST = 1'b0;
     assign m_axis_tcp_tx_data_a_TDATA = 512'b0; assign m_axis_tcp_tx_data_a_TKEEP = 64'b0; assign m_axis_tcp_tx_data_a_TLAST = 1'b0;
     assign m_axis_udp_tx_b_TDATA = 512'b0; assign m_axis_udp_tx_b_TKEEP = 64'b0; assign m_axis_udp_tx_b_TLAST = 1'b0;
     assign m_axis_udp_tx_meta_b_TDATA = 256'b0; assign m_axis_udp_tx_meta_b_TKEEP = 32'b0; assign m_axis_udp_tx_meta_b_TLAST = 1'b0;
     assign m_axis_tcp_listen_port_b_TDATA = 16'b0; assign m_axis_tcp_listen_port_b_TKEEP = 2'b0; assign m_axis_tcp_listen_port_b_TLAST = 1'b0;
     assign m_axis_tcp_open_connection_b_TDATA = 64'b0; assign m_axis_tcp_open_connection_b_TKEEP = 8'b0; assign m_axis_tcp_open_connection_b_TLAST = 1'b0;
     assign m_axis_tcp_close_connection_b_TDATA = 16'b0; assign m_axis_tcp_close_connection_b_TKEEP = 2'b0; assign m_axis_tcp_close_connection_b_TLAST = 1'b0;
     assign m_axis_tcp_read_pkg_b_TDATA = 32'b0; assign m_axis_tcp_read_pkg_b_TKEEP = 4'b0; assign m_axis_tcp_read_pkg_b_TLAST = 1'b0;
     assign m_axis_tcp_tx_meta_b_TDATA = 32'b0; assign m_axis_tcp_tx_meta_b_TKEEP = 4'b0; assign m_axis_tcp_tx_meta_b_TLAST = 1'b0;
     assign m_axis_tcp_tx_data_b_TDATA = 512'b0; assign m_axis_tcp_tx_data_b_TKEEP = 64'b0; assign m_axis_tcp_tx_data_b_TLAST = 1'b0;

     assign connAttempts = 32'b0; assign sentCount = 32'b0; assign sentCount_ap_vld = 1'b0;
     assign recvCount = 32'b0; assign recvCount_ap_vld = 1'b0; assign timeoutCount = 32'b0;
     assign echoRxCount = 32'b0; assign echoRxCount_ap_vld = 1'b0;
     assign echoCount = 32'b0; assign echoCount_ap_vld = 1'b0;
     assign listenAttempts = 32'b0; assign portState = 32'b0;
endmodule


// ─────────────────────────────────────────────────────────────────────────────
module tb_probe_taps;

     localparam [47:0] MARKER = 48'h5A3C96E1B7D2;

     // адресная карта — из probe_control_s_axi.v
     localparam [11:0] A_MINWORDS = 12'h074;
     localparam [11:0] A_TS_TX_A  = 12'h078;   // T1'
     localparam [11:0] A_TS_RX_B  = 12'h07c;   // T2'
     localparam [11:0] A_TS_TX_B  = 12'h080;   // T1
     localparam [11:0] A_TS_RX_A  = 12'h084;   // T2
     localparam [11:0] A_NF_CNT_A = 12'h088;
     localparam [11:0] A_NF_CNT_B = 12'h08c;
     localparam [11:0] A_NF_DRP_A = 12'h090;
     localparam [11:0] A_NF_DRP_B = 12'h094;

     reg clk = 1'b0, rst_n = 1'b0;
     always #5 clk = ~clk;

     integer errors = 0;

     // ── AXI-Lite ─────────────────────────────────────────────────────────
     reg         awvalid = 1'b0, wvalid = 1'b0, arvalid = 1'b0;
     reg  [11:0] awaddr = 12'b0, araddr = 12'b0;
     reg  [31:0] wdata = 32'b0;
     reg  [3:0]  wstrb = 4'hF;
     reg         bready = 1'b1, rready = 1'b1;
     wire        awready, wready, arready, rvalid, bvalid;
     wire [31:0] rdata;

     // ── врезки: вход обёртки (s_) и её выход (m_) ─────────────────────────
     reg         net_tx_a_tv = 1'b0, net_tx_a_tl = 1'b0;   reg [511:0] net_tx_a_td = 512'b0;
     reg  [63:0] net_tx_a_tk = 64'hFFFF_FFFF_FFFF_FFFF;
     reg         net_rx_a_tv = 1'b0, net_rx_a_tl = 1'b0;   reg [511:0] net_rx_a_td = 512'b0;
     reg  [63:0] net_rx_a_tk = 64'hFFFF_FFFF_FFFF_FFFF;
     reg         net_tx_b_tv = 1'b0, net_tx_b_tl = 1'b0;   reg [511:0] net_tx_b_td = 512'b0;
     reg  [63:0] net_tx_b_tk = 64'hFFFF_FFFF_FFFF_FFFF;
     reg         net_rx_b_tv = 1'b0, net_rx_b_tl = 1'b0;   reg [511:0] net_rx_b_td = 512'b0;
     reg  [63:0] net_rx_b_tk = 64'hFFFF_FFFF_FFFF_FFFF;

     // приёмники (имитируют cmac_krnl / network_krnl за врезкой)
     reg         sink_tx_a_tr = 1'b1, sink_rx_a_tr = 1'b1;
     reg         sink_tx_b_tr = 1'b1, sink_rx_b_tr = 1'b1;

     wire        o_tx_a_tv, o_tx_a_tl, i_tx_a_tr;  wire [511:0] o_tx_a_td; wire [63:0] o_tx_a_tk;
     wire        o_rx_a_tv, o_rx_a_tl, i_rx_a_tr;  wire [511:0] o_rx_a_td; wire [63:0] o_rx_a_tk;
     wire        o_tx_b_tv, o_tx_b_tl, i_tx_b_tr;  wire [511:0] o_tx_b_td; wire [63:0] o_tx_b_tk;
     wire        o_rx_b_tv, o_rx_b_tl, i_rx_b_tr;  wire [511:0] o_rx_b_td; wire [63:0] o_rx_b_tk;

     hls_echo_probe_dual_krnl_wrapper dut (
          .ap_clk(clk), .ap_rst_n(rst_n),
          .s_axi_control_awvalid(awvalid), .s_axi_control_awready(awready),
          .s_axi_control_awaddr(awaddr),
          .s_axi_control_wvalid(wvalid), .s_axi_control_wready(wready),
          .s_axi_control_wdata(wdata), .s_axi_control_wstrb(wstrb),
          .s_axi_control_arvalid(arvalid), .s_axi_control_arready(arready),
          .s_axi_control_araddr(araddr),
          .s_axi_control_rvalid(rvalid), .s_axi_control_rready(rready),
          .s_axi_control_rdata(rdata), .s_axi_control_rresp(),
          .s_axi_control_bvalid(bvalid), .s_axi_control_bready(bready),
          .s_axi_control_bresp(), .interrupt(),

          // все прочие потоки заглушены нулями
          .s_axis_udp_rx_a_tvalid(1'b0), .s_axis_udp_rx_a_tready(),
          .s_axis_udp_rx_a_tdata(512'b0), .s_axis_udp_rx_a_tkeep(64'b0), .s_axis_udp_rx_a_tlast(1'b0),
          .m_axis_udp_tx_a_tvalid(), .m_axis_udp_tx_a_tready(1'b1),
          .m_axis_udp_tx_a_tdata(), .m_axis_udp_tx_a_tkeep(), .m_axis_udp_tx_a_tlast(),
          .s_axis_udp_rx_meta_a_tvalid(1'b0), .s_axis_udp_rx_meta_a_tready(),
          .s_axis_udp_rx_meta_a_tdata(256'b0), .s_axis_udp_rx_meta_a_tkeep(32'b0), .s_axis_udp_rx_meta_a_tlast(1'b0),
          .m_axis_udp_tx_meta_a_tvalid(), .m_axis_udp_tx_meta_a_tready(1'b1),
          .m_axis_udp_tx_meta_a_tdata(), .m_axis_udp_tx_meta_a_tkeep(), .m_axis_udp_tx_meta_a_tlast(),
          .m_axis_tcp_listen_port_a_tvalid(), .m_axis_tcp_listen_port_a_tready(1'b1),
          .m_axis_tcp_listen_port_a_tdata(), .m_axis_tcp_listen_port_a_tkeep(), .m_axis_tcp_listen_port_a_tlast(),
          .s_axis_tcp_port_status_a_tvalid(1'b0), .s_axis_tcp_port_status_a_tready(),
          .s_axis_tcp_port_status_a_tdata(8'b0), .s_axis_tcp_port_status_a_tkeep(1'b0), .s_axis_tcp_port_status_a_tlast(1'b0),
          .m_axis_tcp_open_connection_a_tvalid(), .m_axis_tcp_open_connection_a_tready(1'b1),
          .m_axis_tcp_open_connection_a_tdata(), .m_axis_tcp_open_connection_a_tkeep(), .m_axis_tcp_open_connection_a_tlast(),
          .s_axis_tcp_open_status_a_tvalid(1'b0), .s_axis_tcp_open_status_a_tready(),
          .s_axis_tcp_open_status_a_tdata(128'b0), .s_axis_tcp_open_status_a_tkeep(16'b0), .s_axis_tcp_open_status_a_tlast(1'b0),
          .m_axis_tcp_close_connection_a_tvalid(), .m_axis_tcp_close_connection_a_tready(1'b1),
          .m_axis_tcp_close_connection_a_tdata(), .m_axis_tcp_close_connection_a_tkeep(), .m_axis_tcp_close_connection_a_tlast(),
          .s_axis_tcp_notification_a_tvalid(1'b0), .s_axis_tcp_notification_a_tready(),
          .s_axis_tcp_notification_a_tdata(128'b0), .s_axis_tcp_notification_a_tkeep(16'b0), .s_axis_tcp_notification_a_tlast(1'b0),
          .m_axis_tcp_read_pkg_a_tvalid(), .m_axis_tcp_read_pkg_a_tready(1'b1),
          .m_axis_tcp_read_pkg_a_tdata(), .m_axis_tcp_read_pkg_a_tkeep(), .m_axis_tcp_read_pkg_a_tlast(),
          .s_axis_tcp_rx_meta_a_tvalid(1'b0), .s_axis_tcp_rx_meta_a_tready(),
          .s_axis_tcp_rx_meta_a_tdata(16'b0), .s_axis_tcp_rx_meta_a_tkeep(2'b0), .s_axis_tcp_rx_meta_a_tlast(1'b0),
          .s_axis_tcp_rx_data_a_tvalid(1'b0), .s_axis_tcp_rx_data_a_tready(),
          .s_axis_tcp_rx_data_a_tdata(512'b0), .s_axis_tcp_rx_data_a_tkeep(64'b0), .s_axis_tcp_rx_data_a_tlast(1'b0),
          .m_axis_tcp_tx_meta_a_tvalid(), .m_axis_tcp_tx_meta_a_tready(1'b1),
          .m_axis_tcp_tx_meta_a_tdata(), .m_axis_tcp_tx_meta_a_tkeep(), .m_axis_tcp_tx_meta_a_tlast(),
          .m_axis_tcp_tx_data_a_tvalid(), .m_axis_tcp_tx_data_a_tready(1'b1),
          .m_axis_tcp_tx_data_a_tdata(), .m_axis_tcp_tx_data_a_tkeep(), .m_axis_tcp_tx_data_a_tlast(),
          .s_axis_tcp_tx_status_a_tvalid(1'b0), .s_axis_tcp_tx_status_a_tready(),
          .s_axis_tcp_tx_status_a_tdata(64'b0), .s_axis_tcp_tx_status_a_tkeep(8'b0), .s_axis_tcp_tx_status_a_tlast(1'b0),

          .s_axis_udp_rx_b_tvalid(1'b0), .s_axis_udp_rx_b_tready(),
          .s_axis_udp_rx_b_tdata(512'b0), .s_axis_udp_rx_b_tkeep(64'b0), .s_axis_udp_rx_b_tlast(1'b0),
          .m_axis_udp_tx_b_tvalid(), .m_axis_udp_tx_b_tready(1'b1),
          .m_axis_udp_tx_b_tdata(), .m_axis_udp_tx_b_tkeep(), .m_axis_udp_tx_b_tlast(),
          .s_axis_udp_rx_meta_b_tvalid(1'b0), .s_axis_udp_rx_meta_b_tready(),
          .s_axis_udp_rx_meta_b_tdata(256'b0), .s_axis_udp_rx_meta_b_tkeep(32'b0), .s_axis_udp_rx_meta_b_tlast(1'b0),
          .m_axis_udp_tx_meta_b_tvalid(), .m_axis_udp_tx_meta_b_tready(1'b1),
          .m_axis_udp_tx_meta_b_tdata(), .m_axis_udp_tx_meta_b_tkeep(), .m_axis_udp_tx_meta_b_tlast(),
          .m_axis_tcp_listen_port_b_tvalid(), .m_axis_tcp_listen_port_b_tready(1'b1),
          .m_axis_tcp_listen_port_b_tdata(), .m_axis_tcp_listen_port_b_tkeep(), .m_axis_tcp_listen_port_b_tlast(),
          .s_axis_tcp_port_status_b_tvalid(1'b0), .s_axis_tcp_port_status_b_tready(),
          .s_axis_tcp_port_status_b_tdata(8'b0), .s_axis_tcp_port_status_b_tkeep(1'b0), .s_axis_tcp_port_status_b_tlast(1'b0),
          .m_axis_tcp_open_connection_b_tvalid(), .m_axis_tcp_open_connection_b_tready(1'b1),
          .m_axis_tcp_open_connection_b_tdata(), .m_axis_tcp_open_connection_b_tkeep(), .m_axis_tcp_open_connection_b_tlast(),
          .s_axis_tcp_open_status_b_tvalid(1'b0), .s_axis_tcp_open_status_b_tready(),
          .s_axis_tcp_open_status_b_tdata(128'b0), .s_axis_tcp_open_status_b_tkeep(16'b0), .s_axis_tcp_open_status_b_tlast(1'b0),
          .m_axis_tcp_close_connection_b_tvalid(), .m_axis_tcp_close_connection_b_tready(1'b1),
          .m_axis_tcp_close_connection_b_tdata(), .m_axis_tcp_close_connection_b_tkeep(), .m_axis_tcp_close_connection_b_tlast(),
          .s_axis_tcp_notification_b_tvalid(1'b0), .s_axis_tcp_notification_b_tready(),
          .s_axis_tcp_notification_b_tdata(128'b0), .s_axis_tcp_notification_b_tkeep(16'b0), .s_axis_tcp_notification_b_tlast(1'b0),
          .m_axis_tcp_read_pkg_b_tvalid(), .m_axis_tcp_read_pkg_b_tready(1'b1),
          .m_axis_tcp_read_pkg_b_tdata(), .m_axis_tcp_read_pkg_b_tkeep(), .m_axis_tcp_read_pkg_b_tlast(),
          .s_axis_tcp_rx_meta_b_tvalid(1'b0), .s_axis_tcp_rx_meta_b_tready(),
          .s_axis_tcp_rx_meta_b_tdata(16'b0), .s_axis_tcp_rx_meta_b_tkeep(2'b0), .s_axis_tcp_rx_meta_b_tlast(1'b0),
          .s_axis_tcp_rx_data_b_tvalid(1'b0), .s_axis_tcp_rx_data_b_tready(),
          .s_axis_tcp_rx_data_b_tdata(512'b0), .s_axis_tcp_rx_data_b_tkeep(64'b0), .s_axis_tcp_rx_data_b_tlast(1'b0),
          .m_axis_tcp_tx_meta_b_tvalid(), .m_axis_tcp_tx_meta_b_tready(1'b1),
          .m_axis_tcp_tx_meta_b_tdata(), .m_axis_tcp_tx_meta_b_tkeep(), .m_axis_tcp_tx_meta_b_tlast(),
          .m_axis_tcp_tx_data_b_tvalid(), .m_axis_tcp_tx_data_b_tready(1'b1),
          .m_axis_tcp_tx_data_b_tdata(), .m_axis_tcp_tx_data_b_tkeep(), .m_axis_tcp_tx_data_b_tlast(),
          .s_axis_tcp_tx_status_b_tvalid(1'b0), .s_axis_tcp_tx_status_b_tready(),
          .s_axis_tcp_tx_status_b_tdata(64'b0), .s_axis_tcp_tx_status_b_tkeep(8'b0), .s_axis_tcp_tx_status_b_tlast(1'b0),

          // ── ВРЕЗКИ ────────────────────────────────────────────────────
          .s_axis_net_tx_a_tvalid(net_tx_a_tv), .s_axis_net_tx_a_tready(i_tx_a_tr),
          .s_axis_net_tx_a_tdata(net_tx_a_td), .s_axis_net_tx_a_tkeep(net_tx_a_tk),
          .s_axis_net_tx_a_tlast(net_tx_a_tl),
          .m_axis_net_tx_a_tvalid(o_tx_a_tv), .m_axis_net_tx_a_tready(sink_tx_a_tr),
          .m_axis_net_tx_a_tdata(o_tx_a_td), .m_axis_net_tx_a_tkeep(o_tx_a_tk),
          .m_axis_net_tx_a_tlast(o_tx_a_tl),

          .s_axis_net_rx_a_tvalid(net_rx_a_tv), .s_axis_net_rx_a_tready(i_rx_a_tr),
          .s_axis_net_rx_a_tdata(net_rx_a_td), .s_axis_net_rx_a_tkeep(net_rx_a_tk),
          .s_axis_net_rx_a_tlast(net_rx_a_tl),
          .m_axis_net_rx_a_tvalid(o_rx_a_tv), .m_axis_net_rx_a_tready(sink_rx_a_tr),
          .m_axis_net_rx_a_tdata(o_rx_a_td), .m_axis_net_rx_a_tkeep(o_rx_a_tk),
          .m_axis_net_rx_a_tlast(o_rx_a_tl),

          .s_axis_net_tx_b_tvalid(net_tx_b_tv), .s_axis_net_tx_b_tready(i_tx_b_tr),
          .s_axis_net_tx_b_tdata(net_tx_b_td), .s_axis_net_tx_b_tkeep(net_tx_b_tk),
          .s_axis_net_tx_b_tlast(net_tx_b_tl),
          .m_axis_net_tx_b_tvalid(o_tx_b_tv), .m_axis_net_tx_b_tready(sink_tx_b_tr),
          .m_axis_net_tx_b_tdata(o_tx_b_td), .m_axis_net_tx_b_tkeep(o_tx_b_tk),
          .m_axis_net_tx_b_tlast(o_tx_b_tl),

          .s_axis_net_rx_b_tvalid(net_rx_b_tv), .s_axis_net_rx_b_tready(i_rx_b_tr),
          .s_axis_net_rx_b_tdata(net_rx_b_td), .s_axis_net_rx_b_tkeep(net_rx_b_tk),
          .s_axis_net_rx_b_tlast(net_rx_b_tl),
          .m_axis_net_rx_b_tvalid(o_rx_b_tv), .m_axis_net_rx_b_tready(sink_rx_b_tr),
          .m_axis_net_rx_b_tdata(o_rx_b_td), .m_axis_net_rx_b_tkeep(o_rx_b_tk),
          .m_axis_net_rx_b_tlast(o_rx_b_tl)
     );

     // ── ПРОЗРАЧНОСТЬ: проверяется НЕПРЕРЫВНО, каждый такт ────────────────
     //
     // Это главная проверка боевого пути: врезка стоит между network_krnl и
     // cmac_krnl, и любое расхождение здесь — потерянный или искажённый трафик
     // на живой плате.
     integer pass_err = 0;
     always @(posedge clk) if (rst_n) begin
          if (o_tx_a_tv !== net_tx_a_tv || o_tx_a_td !== net_tx_a_td ||
              o_tx_a_tk !== net_tx_a_tk || o_tx_a_tl !== net_tx_a_tl ||
              i_tx_a_tr !== sink_tx_a_tr) pass_err = pass_err + 1;
          if (o_rx_a_tv !== net_rx_a_tv || o_rx_a_td !== net_rx_a_td ||
              o_rx_a_tk !== net_rx_a_tk || o_rx_a_tl !== net_rx_a_tl ||
              i_rx_a_tr !== sink_rx_a_tr) pass_err = pass_err + 1;
          if (o_tx_b_tv !== net_tx_b_tv || o_tx_b_td !== net_tx_b_td ||
              o_tx_b_tk !== net_tx_b_tk || o_tx_b_tl !== net_tx_b_tl ||
              i_tx_b_tr !== sink_tx_b_tr) pass_err = pass_err + 1;
          if (o_rx_b_tv !== net_rx_b_tv || o_rx_b_td !== net_rx_b_td ||
              o_rx_b_tk !== net_rx_b_tk || o_rx_b_tl !== net_rx_b_tl ||
              i_rx_b_tr !== sink_rx_b_tr) pass_err = pass_err + 1;
     end

     // ── задачи AXI-Lite ──────────────────────────────────────────────────
     task axi_write(input [11:0] addr, input [31:0] data);
          begin
               @(negedge clk); awaddr = addr; awvalid = 1'b1;
               wait (awready); @(negedge clk); awvalid = 1'b0;
               wdata = data; wvalid = 1'b1;
               wait (wready); @(negedge clk); wvalid = 1'b0;
               wait (bvalid); @(negedge clk);
          end
     endtask

     task axi_read(input [11:0] addr, output [31:0] data);
          begin
               @(negedge clk); araddr = addr; arvalid = 1'b1;
               wait (arready); @(negedge clk); arvalid = 1'b0;
               wait (rvalid); data = rdata; @(negedge clk);
          end
     endtask

     // ── подача кадра в конкретную врезку ─────────────────────────────────
     // ch: 0=tx_a(T1') 1=rx_b(T2') 2=tx_b(T1) 3=rx_a(T2)
     task send(input integer ch, input integer nwords, input marked);
          integer i;
          reg [511:0] d;
          begin
               for (i = 0; i < nwords; i = i + 1) begin
                    d = 512'b0;
                    if (i == 0) begin
                         d[31:0] = 32'hDEADC0DE;
                         d[511:464] = marked ? MARKER : 48'h0102030405AA;
                    end
                    @(negedge clk);
                    case (ch)
                      0: begin net_tx_a_tv=1'b1; net_tx_a_td=d; net_tx_a_tl=(i==nwords-1); end
                      1: begin net_rx_b_tv=1'b1; net_rx_b_td=d; net_rx_b_tl=(i==nwords-1); end
                      2: begin net_tx_b_tv=1'b1; net_tx_b_td=d; net_tx_b_tl=(i==nwords-1); end
                      3: begin net_rx_a_tv=1'b1; net_rx_a_td=d; net_rx_a_tl=(i==nwords-1); end
                    endcase
               end
               @(negedge clk);
               net_tx_a_tv=1'b0; net_tx_a_tl=1'b0;
               net_rx_b_tv=1'b0; net_rx_b_tl=1'b0;
               net_tx_b_tv=1'b0; net_tx_b_tl=1'b0;
               net_rx_a_tv=1'b0; net_rx_a_tl=1'b0;
          end
     endtask

     reg [31:0] v, t1p, t2p, t1, t2, ca, cb, da, db;

     initial begin
          $display("=== tb_probe_taps ===");
          repeat (4) @(negedge clk);
          rst_n = 1'b1;
          repeat (4) @(negedge clk);

          // ── 1. minWords: сброс в 2, RW ───────────────────────────────────
          $display("\n[1] регистр minWords");
          axi_read(A_MINWORDS, v);
          `check("сброс в 2 (не 0 -- иначе фильтр пропускал бы ARP/ACK)", v == 32'd2);
          axi_write(A_MINWORDS, 32'd5);
          axi_read(A_MINWORDS, v);
          `check("записывается и читается", v == 32'd5);
          axi_write(A_MINWORDS, 32'd2);

          // ── 2. таймстемпы нулевые до трафика ─────────────────────────────
          $display("\n[2] до трафика таймстемпы нулевые");
          axi_read(A_TS_TX_A, t1p); axi_read(A_TS_RX_B, t2p);
          axi_read(A_TS_TX_B, t1);  axi_read(A_TS_RX_A, t2);
          `check("все четыре = 0", (t1p==0)&&(t2p==0)&&(t1==0)&&(t2==0));

          // ── 3. ГЛАВНОЕ: каждый T приходит от СВОЕЙ врезки ────────────────
          //
          // Кадры разной длины в разные врезки, с паузами. Если каналы
          // перепутаны местами, порядок таймстемпов не совпадёт.
          // Круг: T1'(tx_a) -> T2'(rx_b) -> T1(tx_b) -> T2(rx_a).
          $display("\n[3] соответствие врезка -> регистр (круг T1'->T2'->T1->T2)");
          send(0, 2, 1'b1); repeat (10) @(negedge clk);   // T1'
          send(1, 3, 1'b1); repeat (10) @(negedge clk);   // T2'
          send(2, 4, 1'b1); repeat (10) @(negedge clk);   // T1
          send(3, 5, 1'b1); repeat (10) @(negedge clk);   // T2

          axi_read(A_TS_TX_A, t1p); axi_read(A_TS_RX_B, t2p);
          axi_read(A_TS_TX_B, t1);  axi_read(A_TS_RX_A, t2);
          $display("     T1'=%0d T2'=%0d T1=%0d T2=%0d", t1p, t2p, t1, t2);
          `check("все четыре ненулевые", (t1p!=0)&&(t2p!=0)&&(t1!=0)&&(t2!=0));
          `check("T1' < T2' (запрос ушёл раньше, чем пришёл)", t1p < t2p);
          `check("T2' < T1  (пришёл раньше, чем ответ ушёл)",  t2p < t1);
          `check("T1  < T2  (ответ ушёл раньше, чем вернулся)", t1  < t2);
          `check("все четыре РАЗНЫЕ (иначе один регистр на всех)", (t1p!=t2p)&&(t2p!=t1)&&(t1!=t2)&&(t1p!=t2));

          // ── 4. счётчики кадров по каналам ────────────────────────────────
          $display("\n[4] счётчики кадров: канал A = tx_a+rx_a, B = tx_b+rx_b");
          axi_read(A_NF_CNT_A, ca); axi_read(A_NF_CNT_B, cb);
          $display("     countA=%0d countB=%0d", ca, cb);
          `check("A = 2 (по одному кадру на tx_a и rx_a)", ca == 32'd2);
          `check("B = 2 (по одному кадру на tx_b и rx_b)", cb == 32'd2);

          // ── 5. чужой кадр: drop растёт, таймстемп НЕ меняется ────────────
          $display("\n[5] чужой кадр (без маркера) не сдвигает таймстемп");
          axi_read(A_TS_TX_A, t1p);
          axi_read(A_NF_DRP_A, da);
          send(0, 2, 1'b0);              // SYN-подобный: 2 слова, маркера нет
          repeat (10) @(negedge clk);
          axi_read(A_TS_TX_A, v);
          `check("таймстемп T1' не изменился", v == t1p);
          axi_read(A_NF_DRP_A, db);
          `check("dropA вырос", db == da + 1);

          // ── 6. односоловный кадр после нашего (ловушка single_word) ──────
          $display("\n[6] ловушка: односоловный кадр после нашего, minWords=1");
          axi_write(A_MINWORDS, 32'd1);
          send(2, 2, 1'b1);              // наш в tx_b
          repeat (6) @(negedge clk);
          axi_read(A_TS_TX_B, t1);
          send(2, 1, 1'b0);              // односоловный чужой туда же
          repeat (6) @(negedge clk);
          axi_read(A_TS_TX_B, v);
          `check("таймстемп T1 не сдвинулся чужим односоловным", v == t1);
          axi_write(A_MINWORDS, 32'd2);

          // ── 7. прозрачность за весь прогон ───────────────────────────────
          $display("\n[7] прозрачность врезок (проверялась каждый такт)");
          `check("passthrough ни разу не исказил шину", pass_err == 0);

          // ── 8. backpressure проходит насквозь ────────────────────────────
          $display("\n[8] tready от приёмника доходит до источника");
          @(negedge clk); sink_tx_a_tr = 1'b0;
          @(negedge clk);
          `check("tready=0 виден на входе врезки", i_tx_a_tr == 1'b0);
          @(negedge clk); sink_tx_a_tr = 1'b1;
          @(negedge clk);
          `check("tready=1 виден на входе врезки", i_tx_a_tr == 1'b1);

          $display("");
          if (errors == 0 && pass_err == 0)
               $display("=== tb_probe_taps: ВСЁ ЗЕЛЁНОЕ ===");
          else
               $display("=== tb_probe_taps: ОТКАЗОВ %0d (прозрачность: %0d) ===",
                        errors, pass_err);
          $finish;
     end

     initial begin
          #2000000;
          $display("*** TIMEOUT: тестбенч не завершился");
          $finish;
     end

endmodule

`default_nettype wire
