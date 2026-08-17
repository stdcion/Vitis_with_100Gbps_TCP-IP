// =============================================================================
// tb_probe_ctrl -- управляющая механика обёртки: регистры, sampleReady, ap_ctrl
// =============================================================================
//
// ЗАЧЕМ ЕЩЁ ОДИН ТЕСТБЕНЧ. tb_probe_taps проверяет ВРЕЗКИ и трогает только
// девять адресов из тридцати восьми -- все новые. Вся ИСХОДНАЯ адресная карта
// (0x10..0x70) не проверена ничем, а именно она нужна для bringup: enable,
// triggerGo, четыре маленьких t, sampleReady. Этот код уже лежит в собранном
// битстриме probe и до сих пор подтверждался только рассуждениями в
// комментариях.
//
// ТРИ ВЕЩИ, РАДИ КОТОРЫХ ОН НАПИСАН -- все про поведение ВО ВРЕМЕНИ, которого
// не видят ни csim (там C++, регистров нет), ни модели на Python/Tcl:
//
//   1. sampleReady и ОДНОТАКТОВАЯ ГОНКА. В шапке обёртки описано, что сначала
//      приоритет был у сброса, и при совпадении строба t2 с тактом смены
//      triggerGo флаг НЕ вставал вовсе -- замер зависал до таймаута. Окно в
//      один такт, то есть на плате это редкий невоспроизводимый `sample failed`.
//      Дефект нашли моделированием и исправили приоритетом установки, но на RTL
//      это НИКОГДА не проверялось. Здесь проверяется, причём именно в тот такт.
//
//   2. ap_ctrl_hs. РАНЬШЕ ядро было ap_ctrl_none и ap_done подделывала обёртка
//      обёртка объявляет транзакцию завершённой сразу после старта
//      (ap_done = ap_start_pulse). BD/XRT ждёт корректного рукопожатия; если
//      ap_done не придёт, хост повиснет на ap_start. Тоже ни разу не
//      симулировалось.
//
//   3. Вся адресная карта СКВОЗНО: записал -> прочитал обратно -> увидел на
//      проводе в ядро. Именно эта цепочка ломалась при s_axilite+ap_ctrl_none
//      (регистр читается верно, а логика видит ноль) -- см. пять дефектов HLS
//      в docs/latency_session_handoff.md. Здесь регистры в HDL и этой болезни
//      быть не должно, но проверить дешевле, чем предполагать.
//
// ЧЕГО НЕ ПРОВЕРЯЕТ: тайминг (impl), логику HLS-ядра (csim), сами врезки
// (tb_probe_taps). Ядро здесь -- заглушка из tb_probe_taps.sv, поэтому этот
// файл компилируется ВМЕСТЕ с ним (см. run_sim.sh).
//
// ЗАПУСК: ./run_sim.sh ctrl

`timescale 1ns / 1ps
`default_nettype none

// Макрос называется chk, а не check, НАМЕРЕННО: этот файл компилируется в одной
// единице с tb_probe_taps.sv (оттуда берётся заглушка ядра), а там уже есть
// `define check. Одинаковые имена дали бы переопределение -- сейчас тела
// совпадают, но при правке одного из файлов они молча разойдутся.
//
// Про латиницу в сообщениях: $display в xsim 2024.1 портит многобайтовые
// символы, см. шапку run_sim.sh.
`define chk(NAME, COND) \
     begin \
          if (COND) $display("  ok   %0s", NAME); \
          else begin $display("  FAIL %0s", NAME); errors = errors + 1; end \
     end

module tb_probe_ctrl;

     // адресная карта -- из probe_control_s_axi.v
     localparam [11:0] A_AP_CTRL   = 12'h000;
     localparam [11:0] A_ENABLE    = 12'h010;
     localparam [11:0] A_SERVERIP  = 12'h018;
     localparam [11:0] A_SRVPORT   = 12'h020;
     localparam [11:0] A_LSNPORT   = 12'h028;
     localparam [11:0] A_MSGBYTES  = 12'h030;
     localparam [11:0] A_TRIGGER   = 12'h038;
     localparam [11:0] A_CONNATT   = 12'h040;
     localparam [11:0] A_SENT      = 12'h044;
     localparam [11:0] A_RECV      = 12'h048;
     localparam [11:0] A_TIMEOUT   = 12'h04c;
     localparam [11:0] A_ECHO      = 12'h050;
     localparam [11:0] A_LSNATT    = 12'h054;
     localparam [11:0] A_PORTSTATE = 12'h058;
     localparam [11:0] A_ECHORX    = 12'h05c;
     localparam [11:0] A_TSREQ     = 12'h060;
     localparam [11:0] A_TSECHOIN  = 12'h064;
     localparam [11:0] A_TSECHOOUT = 12'h068;
     localparam [11:0] A_TSREPLY   = 12'h06c;
     localparam [11:0] A_SMPREADY  = 12'h070;

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

     // ── провода, которые обёртка отдаёт В ядро ───────────────────────────
     //
     // Заглушка ядра их игнорирует, но нам важно ВИДЕТЬ их: именно здесь
     // ломалась цепочка при s_axilite -- регистр читался верно, а на провод
     // приходил ноль. Подсматриваем прямо в инстанс обёртки иерархическим
     // именем: так проверяется то, что реально доедет до ядра.
     // Проводов enable в ядро больше нет: их роль взял ap_start. Регистр 0x10
     // остался и проверяется чтением -- см. фазу 3.
     wire [31:0] w_serverIp      = dut.hls_echo_probe_dual_krnl_inst.serverIp;
     wire [31:0] w_serverPort    = dut.hls_echo_probe_dual_krnl_inst.serverPort;
     wire [31:0] w_listenPort    = dut.hls_echo_probe_dual_krnl_inst.listenPort;
     wire [31:0] w_msgBytes      = dut.hls_echo_probe_dual_krnl_inst.msgBytes;
     wire [31:0] w_triggerGo     = dut.hls_echo_probe_dual_krnl_inst.triggerGo;

     // ── телеметрия из «ядра»: тут мы ею управляем сами ───────────────────
     //
     // Заглушка держит счётчики в нуле, а нам надо дёргать ap_vld, чтобы
     // проверить защёлку таймстемпов и sampleReady. Поэтому подменяем сигналы
     // через force/release в самих проверках (см. ниже).

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

          // врезки не участвуют: их проверяет tb_probe_taps
          .s_axis_net_tx_a_tvalid(1'b0), .s_axis_net_tx_a_tready(),
          .s_axis_net_tx_a_tdata(512'b0), .s_axis_net_tx_a_tkeep(64'b0), .s_axis_net_tx_a_tlast(1'b0),
          .m_axis_net_tx_a_tvalid(), .m_axis_net_tx_a_tready(1'b1),
          .m_axis_net_tx_a_tdata(), .m_axis_net_tx_a_tkeep(), .m_axis_net_tx_a_tlast(),
          .s_axis_net_rx_a_tvalid(1'b0), .s_axis_net_rx_a_tready(),
          .s_axis_net_rx_a_tdata(512'b0), .s_axis_net_rx_a_tkeep(64'b0), .s_axis_net_rx_a_tlast(1'b0),
          .m_axis_net_rx_a_tvalid(), .m_axis_net_rx_a_tready(1'b1),
          .m_axis_net_rx_a_tdata(), .m_axis_net_rx_a_tkeep(), .m_axis_net_rx_a_tlast(),
          .s_axis_net_tx_b_tvalid(1'b0), .s_axis_net_tx_b_tready(),
          .s_axis_net_tx_b_tdata(512'b0), .s_axis_net_tx_b_tkeep(64'b0), .s_axis_net_tx_b_tlast(1'b0),
          .m_axis_net_tx_b_tvalid(), .m_axis_net_tx_b_tready(1'b1),
          .m_axis_net_tx_b_tdata(), .m_axis_net_tx_b_tkeep(), .m_axis_net_tx_b_tlast(),
          .s_axis_net_rx_b_tvalid(1'b0), .s_axis_net_rx_b_tready(),
          .s_axis_net_rx_b_tdata(512'b0), .s_axis_net_rx_b_tkeep(64'b0), .s_axis_net_rx_b_tlast(1'b0),
          .m_axis_net_rx_b_tvalid(), .m_axis_net_rx_b_tready(1'b1),
          .m_axis_net_rx_b_tdata(), .m_axis_net_rx_b_tkeep(), .m_axis_net_rx_b_tlast()
     );

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

     reg [31:0] v;
     integer    i;

     initial begin
          $display("=== tb_probe_ctrl ===");
          repeat (4) @(negedge clk);
          rst_n = 1'b1;
          repeat (4) @(negedge clk);

          // ── 1. ap_ctrl_hs: рукопожатие завершается ───────────────────────
          //
          // Ядро бесконечное; если ap_done не придёт, BD/XRT повиснет на
          // ap_start. Здесь: пишем ap_start=1, ждём, читаем ap_ctrl обратно.
          // Бит1 (ap_done) очищается ЧТЕНИЕМ, поэтому он должен быть виден в
          // первом же чтении после старта.
          $display("\n[1] ap_ctrl_hs: transaction completes");
          axi_write(A_AP_CTRL, 32'h1);
          repeat (4) @(negedge clk);
          axi_read(A_AP_CTRL, v);
          `chk("ap_done seen after ap_start", v[1] === 1'b1);
          axi_read(A_AP_CTRL, v);
          `chk("ap_done cleared on read", v[1] === 1'b0);
          `chk("ap_idle back to 1 (kernel is free-running)", v[2] === 1'b1);

          // ── 2. параметры: запись -> чтение -> ПРОВОД В ЯДРО ──────────────
          //
          // Третий шаг здесь главный. Именно он ломался при s_axilite +
          // ap_ctrl_none: регистр читался верно, а логика видела ноль. Тот
          // дефект стоил недель поисков (см. handoff), поэтому проверяем не
          // только readback, но и то, что доехало до порта ядра.
          $display("\n[2] parameters: write -> readback -> wire into the kernel");
          axi_write(A_SERVERIP,  32'h0a01d499);
          axi_write(A_SRVPORT,   32'd7001);
          axi_write(A_LSNPORT,   32'd7001);
          axi_write(A_MSGBYTES,  32'd64);
          repeat (2) @(negedge clk);

          axi_read(A_SERVERIP, v);  `chk("serverIp readback",   v === 32'h0a01d499);
          axi_read(A_SRVPORT, v);   `chk("serverPort readback", v === 32'd7001);
          axi_read(A_LSNPORT, v);   `chk("listenPort readback", v === 32'd7001);
          axi_read(A_MSGBYTES, v);  `chk("msgBytes readback",   v === 32'd64);

          `chk("serverIp   reaches the kernel port", w_serverIp   === 32'h0a01d499);
          `chk("serverPort reaches the kernel port", w_serverPort === 32'd7001);
          `chk("listenPort reaches the kernel port", w_listenPort === 32'd7001);
          `chk("msgBytes   reaches the kernel port", w_msgBytes   === 32'd64);

          // ── 3. enable: ОДИН регистр -> ТРИ порта ядра ────────────────────
          //
          // Разделение на enableConn/enableTraffic/enableListen сделано из-за
          // дефекта HLS (скаляр, читаемый тремя стадиями, размножается
          // несимметрично и вешает регион). Снаружи по-прежнему один регистр
          // 0x10, и вот это здесь и проверяется: все три порта идут от него.
          // ── 3. enable: РЕГИСТР ОСТАЛСЯ, В ЯДРО НЕ ИДЁТ ──────────────────
          //
          // Раньше здесь проверялось, что enable_reg доходит до трёх портов ядра
          // (enableConn/enableTraffic/enableListen). Этих портов больше нет: их
          // роль взял ap_start -- ядро ap_ctrl_hs и стоит в ap_idle, пока хост не
          // записал ap_ctrl, поэтому обратиться к стеку раньше network_start
          // физически не может. Ровно та гонка, ради которой enable и вводился.
          //
          // Сам регистр 0x10 оставлен намеренно: он читается обратно и служит
          // признаком «битстрим жив, регистры отвечают», а адресная карта и
          // jtag_ctrl.tcl не меняются. Проверяем именно это -- запись и чтение.
          $display("\n[3] enable register: readable, no longer wired to the kernel");
          axi_write(A_ENABLE, 32'd1);
          repeat (2) @(negedge clk);
          axi_read(A_ENABLE, v);
          `chk("enable readback", v === 32'd1);
          axi_write(A_ENABLE, 32'd0);
          repeat (2) @(negedge clk);
          axi_read(A_ENABLE, v);
          `chk("enable clears", v === 32'd0);
          axi_write(A_ENABLE, 32'd1);
          repeat (2) @(negedge clk);

          // ── 4. triggerGo меняется МНОГОКРАТНО ────────────────────────────
          //
          // Ровно то, чего не умеет s_axilite при ap_ctrl_none: там значение
          // защёлкивается однажды после сброса, и ВТОРОЙ замер не запустился бы
          // никогда. Пишем пять раз подряд и смотрим на провод каждый раз.
          $display("\n[4] triggerGo changes on every measurement");
          for (i = 1; i <= 5; i = i + 1) begin
               axi_write(A_TRIGGER, i[31:0]);
               repeat (2) @(negedge clk);
               `chk("triggerGo reaches the kernel port", w_triggerGo === i[31:0]);
          end

          // ── 5. sampleReady: ОДНОТАКТОВАЯ ГОНКА ───────────────────────────
          //
          // ГЛАВНАЯ ПРОВЕРКА ЭТОГО ФАЙЛА.
          //
          // Обёртка ставит sample_ready_r по tap_t2_reply -- тому же строб, что
          // защёлкивает t2 -- и снимает по смене triggerGo. Раньше приоритет был у
          // СБРОСА, и когда оба события попадали в один такт, флаг не вставал
          // вовсе: замер зависал до таймаута. На плате это выглядело бы как редкий
          // невоспроизводимый `sample failed`.
          //
          // Дефект нашли моделированием и вылечили приоритетом установки, но на RTL
          // это не проверялось ни разу. Проверяем: force'ом поднимаем строб РОВНО в
          // тот такт, когда меняется triggerGo.
          //
          // СТРОБ ТЕПЕРЬ ШИННЫЙ, а не recvCount_ap_vld: готовность и сами
          // таймстемпы приходят от ОДНОГО события, поэтому хост не может прочитать
          // значения предыдущего замера при sampleReady=0. Раньше ap_vld мог
          // подняться позже фактического прихода ответа.
          $display("\n[5] sampleReady: the one-cycle race");

          // сначала нормальный случай: круг замкнулся -> флаг встал
          force dut.tap_t2_reply = 1'b1;
          @(negedge clk);
          release dut.tap_t2_reply;
          repeat (2) @(negedge clk);
          axi_read(A_SMPREADY, v);
          `chk("sampleReady set when the loop closes", v === 32'd1);

          // новый триггер снимает флаг
          axi_write(A_TRIGGER, 32'd100);
          repeat (2) @(negedge clk);
          axi_read(A_SMPREADY, v);
          `chk("sampleReady cleared by a new trigger", v === 32'd0);

          // А ТЕПЕРЬ САМА ГОНКА.
          //
          // Условие сброса (triggerGo_reg != trigger_r) истинно РОВНО ОДИН
          // такт: triggerGo_reg меняется по w_hs, а trigger_r догоняет его на
          // следующем фронте. Надо поднять recvCount_ap_vld именно на нём.
          //
          // ПОЧЕМУ НЕЛЬЗЯ «СНАЧАЛА ЗАПИСЬ, ПОТОМ ПОИСК». Первая версия делала
          // axi_write, а потом искала такт с расхождением -- и не находила
          // никогда (прогон 13.08: «the racing cycle was actually hit» = FAIL).
          // Причина: axi_write возвращает управление только после bvalid, то
          // есть на 1-2 такта ПОЗЖЕ w_hs, а окно к тому моменту уже закрыто.
          // Ловить надо ВО ВРЕМЯ транзакции, а не после неё.
          //
          // Поэтому здесь отдельный процесс следит за triggerGo_reg параллельно
          // записи и стреляет стробом в тот же такт, когда значение изменилось.
          // guard ограничивает ожидание: при неверном допущении тестбенч
          // ОТКАЗЫВАЕТ, а не висит до глобального таймаута.
          begin : race
               integer      guard;
               reg          hit;
               reg [31:0]   prev;
               hit  = 1'b0;
               prev = dut.triggerGo_reg;

               fork
                    axi_write(A_TRIGGER, 32'd101);
                    begin
                         for (guard = 0; guard < 40 && !hit; guard = guard + 1) begin
                              @(posedge clk);
                              // Смотрим СРАЗУ после фронта: triggerGo_reg уже
                              // обновился, а trigger_r ещё держит старое --
                              // это и есть тот единственный такт.
                              if (dut.triggerGo_reg !== prev) begin
                                   force dut.tap_t2_reply = 1'b1;
                                   @(posedge clk);
                                   release dut.tap_t2_reply;
                                   hit = 1'b1;
                              end
                         end
                    end
               join
               `chk("the racing cycle was actually hit", hit === 1'b1);
          end

          repeat (3) @(negedge clk);
          axi_read(A_SMPREADY, v);
          `chk("SET WINS over clear in the same cycle (no hung sample)",
               v === 32'd1);

          // ── 6. защёлка таймстемпов ПО ШИНЕ ──────────────────────────────
          //
          // Обёртка штампует cycle_counter по физическому событию на шине:
          // tvalid & tready & tlast там, где сообщение пересекает границу ядра.
          // Проверяем, что каждый строб попадает в СВОЙ регистр и что все четыре
          // различны (иначе один общий регистр на всех).
          //
          // РАНЬШЕ ЗДЕСЬ ФОРСИЛИСЬ *_ap_vld СЧЁТЧИКОВ ЯДРА. Стробы переведены на
          // шину, потому что ap_vld поднимается не в такте события, а когда стадия
          // отдаёт значение наружу -- при ap_ctrl_hs это на ap_done прохода, то
          // есть на несколько тактов позже. Внутри одной половины смещение
          // сокращается (RTT, ECHO остаются верными), а NET_FWD = t2'-t1' и
          // NET_REV = t2-t1 вычитают точки из РАЗНЫХ половин, и там оно даёт
          // систематическую ошибку в единицы тактов. Хост её не увидит: баланс
          // NET_FWD + ECHO + NET_REV == RTT сходится всегда.
          //
          // tlast обязателен: для 64 байт это одно слово, но при свипе до 1500
          // (24 слова) без него точка уехала бы на длину сообщения.
          $display("\n[6] timestamp latch: each bus event hits its own register");

          // ФОРСИМ tap_*, А НЕ ПОРТЫ ОБЁРТКИ, И ЭТО НЕ УПРОЩЕНИЕ.
          //
          // AXI-Stream входы обёртки подключены в этом тестбенче к КОНСТАНТАМ
          // (.s_axis_tcp_rx_data_b_tvalid(1'b0) и т.п. -- см. инстанс выше): здесь
          // проверяется тракт управления, а не данных. force на порт с
          // константным драйвером не даёт ожидаемого эффекта, и первая версия
          // фазы 6 получала t2'=130 вместо 118 -- значение от ЧЕТВЁРТОГО форса,
          // потому что второй не защёлкивал ничего.
          //
          // tap_t1_pre..tap_t2_reply -- это внутренние провода обёртки, ровно те,
          // по которым штампуются регистры. Форсить их корректно и проверяется
          // именно то, что нужно: попадает ли каждый строб в СВОЙ регистр и одна
          // ли у них шкала. Само вычисление tap из tvalid&tready&tlast проверяет
          // tb_probe_taps на настоящем трафике -- там врезки подключены к шине.
          force dut.tap_t1_pre = 1'b1;   @(negedge clk);
          release dut.tap_t1_pre;        repeat (5) @(negedge clk);
          force dut.tap_t2_pre = 1'b1;   @(negedge clk);
          release dut.tap_t2_pre;        repeat (5) @(negedge clk);
          force dut.tap_t1_echo = 1'b1;  @(negedge clk);
          release dut.tap_t1_echo;       repeat (5) @(negedge clk);
          force dut.tap_t2_reply = 1'b1; @(negedge clk);
          release dut.tap_t2_reply;      repeat (5) @(negedge clk);

          begin : ts_check
               reg [31:0] t1p, t2p, t1, t2;
               axi_read(A_TSREQ, t1p);
               axi_read(A_TSECHOIN, t2p);
               axi_read(A_TSECHOOUT, t1);
               axi_read(A_TSREPLY, t2);
               $display("     t1'=%0d t2'=%0d t1=%0d t2=%0d", t1p, t2p, t1, t2);
               `chk("all four are non-zero", (t1p!=0)&&(t2p!=0)&&(t1!=0)&&(t2!=0));
               `chk("t1' < t2' (stamped in order)", t1p < t2p);
               `chk("t2' < t1  (stamped in order)", t2p < t1);
               `chk("t1  < t2  (stamped in order)", t1  < t2);
               // Шкала ОДНА: между стробами ровно 6 тактов (1 + repeat 5),
               // значит разности обязаны быть равны. Разные счётчики на
               // половины дали бы расхождение -- та самая ошибка, из-за которой
               // счётчик переехал в HDL.
               `chk("equal gaps -- one shared timebase",
                    ((t2p - t1p) == (t1 - t2p)) && ((t1 - t2p) == (t2 - t1)));
          end

          // ── 7. телеметрия читается с проводов ────────────────────────────
          //
          // Заглушка держит счётчики в нуле, поэтому здесь проверяется только
          // то, что адреса отвечают и не возвращают мусор. Значения из живого
          // ядра проверяет csim.
          $display("\n[7] telemetry addresses respond");
          axi_read(A_CONNATT, v);   `chk("connAttempts reads 0",   v === 32'b0);
          axi_read(A_SENT, v);      `chk("sentCount reads 0",      v === 32'b0);
          axi_read(A_RECV, v);      `chk("recvCount reads 0",      v === 32'b0);
          axi_read(A_TIMEOUT, v);   `chk("timeoutCount reads 0",   v === 32'b0);
          axi_read(A_ECHO, v);      `chk("echoCount reads 0",      v === 32'b0);
          axi_read(A_LSNATT, v);    `chk("listenAttempts reads 0", v === 32'b0);
          axi_read(A_PORTSTATE, v); `chk("portState reads 0",      v === 32'b0);
          axi_read(A_ECHORX, v);    `chk("echoRxCount reads 0",    v === 32'b0);

          // ── 8. неизвестный адрес не вешает шину ──────────────────────────
          //
          // jtag_ctrl.tcl обращается по смещениям из своей таблицы; если она
          // разойдётся с картой, чтение уйдёт в никуда. Транзакция обязана
          // завершиться (иначе Tcl повиснет), а данные -- быть нулём.
          $display("\n[8] unmapped address completes and reads 0");
          axi_read(12'h0f0, v);
          `chk("unmapped read returns 0 and does not hang", v === 32'b0);

          // ── 9. сброс возвращает всё в исходное ───────────────────────────
          $display("\n[9] reset restores defaults");
          @(negedge clk); rst_n = 1'b0;
          repeat (4) @(negedge clk); rst_n = 1'b1;
          repeat (4) @(negedge clk);
          axi_read(A_ENABLE, v);   `chk("enable cleared by reset",  v === 32'b0);
          axi_read(A_TRIGGER, v);  `chk("triggerGo cleared",        v === 32'b0);
          axi_read(A_SMPREADY, v); `chk("sampleReady cleared",      v === 32'b0);
          // Проводов enable в ядро больше нет -- проверяем сам регистр.
          axi_read(A_ENABLE, v);
          `chk("enable register cleared by reset", v === 32'd0);

          $display("");
          if (errors == 0) $display("=== tb_probe_ctrl: ALL GREEN ===");
          else             $display("=== tb_probe_ctrl: FAILURES %0d ===", errors);
          $finish;
     end

     initial begin
          #2000000;
          $display("*** TIMEOUT: testbench did not finish");
          $finish;
     end

endmodule

`default_nettype wire
