// =============================================================================
// tb_listen_start -- почему стадия listen не открывает порт
// =============================================================================
//
// ЧТО ЭТО ПРОВЕРЯЕТ. Ровно одно утверждение:
//
//     стадия dual_echo_listen делает конечное число проходов и замирает,
//     если ap_start подан КОНСТАНТОЙ 1'b1, и работает непрерывно,
//     если ap_start подан ИМПУЛЬСАМИ (как это делает auto_restart).
//
// Симулируется СГЕНЕРИРОВАННЫЙ HLS-RTL (hls_dual_echo_krnl_dual_echo_listen.v),
// а не наша модель замысла. Поэтому результат -- свойство того железа, которое
// прошивается в плату, а не наших рассуждений о нём.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ ТЕСТБЕНЧ, А НЕ csim. csim гоняет C++ и про ap_start не знает
// вообще: в C++ вызов функции просто происходит. Механизм ap_start/ap_ready/
// ap_sync появляется только при синтезе, поэтому дефект в нём НЕВИДИМ для csim
// -- ядро проходило csim зелёным и не работало на плате. Здесь он виден.
//
// ПОЧЕМУ НЕ ИНСТАНЦИРУЕТСЯ dual_echo_core. У него 221 порт, из них измеряемых
// три. Вместо этого берётся сама стадия, а логика ap_sync вокруг неё
// ВОСПРОИЗВЕДЕНА ниже по сгенерированному RTL дословно (см. ap_sync_reg) --
// с указанием строк оригинала, чтобы расхождение было видно при сверке.
//
// ЧЕГО НЕ ПРОВЕРЯЕТ: тайминг (это impl) и поведение стека (это плата).
//
// Сообщения на латинице -- $display в xsim 2024.1 портит многобайтовые
// символы, см. пояснение в src/hdl/tb/run_sim.sh соседнего ядра.

`timescale 1ns / 1ps
`default_nettype none

module tb_listen_start;

// ── тактирование ─────────────────────────────────────────────────────────────
logic ap_clk = 1'b0;
always #2.5 ap_clk = ~ap_clk;          // 200 МГц, период не важен для логики

logic ap_rst = 1'b1;                   // HLS-стадия ждёт АКТИВНЫЙ-ВЫСОКИЙ сброс

// ── общие входы стадии ───────────────────────────────────────────────────────
//
// enableB и listenPortB держим ВКЛЮЧЁННЫМИ с самого начала теста -- то есть
// ставим ядро в условия ЛУЧШИЕ, чем на плате. На плате JTAG записывает enable
// через десятки секунд после снятия сброса; если стадия молчит даже когда
// enable=1 стоял всегда, то дело точно не в моменте записи.
logic [31:0] enableB    = 32'd1;
logic [15:0] listenPortB = 16'd5001;

// Стек всегда готов принять запрос и никогда не отвечает статусом. Это
// НАМЕРЕННО: нас интересует, сколько раз стадия ПОПЫТАЕТСЯ записать порт, а
// не что будет после ответа. Отсутствие ответа -- то же, что на плате, где
// listenAttempts остался нулём.
logic m_axis_tcp_listen_port_b_TREADY  = 1'b1;
logic s_axis_tcp_port_status_b_TVALID  = 1'b0;
logic [7:0] s_axis_tcp_port_status_b_TDATA = 8'd0;
logic [0:0] s_axis_tcp_port_status_b_TKEEP = 1'b1;
logic [0:0] s_axis_tcp_port_status_b_TSTRB = 1'b1;
logic [0:0] s_axis_tcp_port_status_b_TLAST = 1'b1;
logic ap_ce = 1'b1;

// ── управление, которое и является предметом теста ───────────────────────────
logic ap_start_drive = 1'b0;
logic ap_continue    = 1'b1;

wire ap_done, ap_idle, ap_ready;

// ── ВОСПРОИЗВЕДЕНИЕ ap_sync ИЗ dual_echo_core.v ─────────────────────────────
//
// Дословно по сгенерированному RTL:
//
//   dual_echo_core.v:1373
//       assign dual_echo_listen_U0_ap_start =
//              ((ap_sync_reg_dual_echo_listen_U0_ap_ready ^ 1'b1) & ap_start);
//
//   dual_echo_core.v:1341
//       assign ap_sync_dual_echo_listen_U0_ap_ready =
//              (dual_echo_listen_U0_ap_ready | ap_sync_reg_..._ap_ready);
//
//   dual_echo_core.v:1179-1184  (регистр)
//       if (ap_rst) ap_sync_reg <= 1'b0;
//       else if ((ap_sync_ready & ap_start) == 1'b1) ap_sync_reg <= 1'b0;
//       else ap_sync_reg <= ap_sync_..._ap_ready;
//
// ap_sync_ready в оригинале -- И по ВСЕМ 14 стадиям (core.v:1347). Здесь стадия
// одна, поэтому берём её собственную готовность. Это делает модель ОПТИМИСТИЧНЕЕ
// настоящего железа: в реальном core сброс ap_sync_reg требует согласия всех 14
// стадий, то есть случается РЕЖЕ, чем здесь. Если даже в оптимистичной модели
// стадия замирает -- на плате тем более.
logic ap_sync_reg = 1'b0;
wire  ap_sync_ap_ready = ap_ready | ap_sync_reg;
wire  ap_sync_ready    = ap_sync_ap_ready;
wire  stage_ap_start   = (~ap_sync_reg) & ap_start_drive;

always @(posedge ap_clk) begin
     if (ap_rst)
          ap_sync_reg <= 1'b0;
     else if ((ap_sync_ready & ap_start_drive) == 1'b1)
          ap_sync_reg <= 1'b0;
     else
          ap_sync_reg <= ap_sync_ap_ready;
end

// ── стадия ───────────────────────────────────────────────────────────────────
wire [31:0] listenAttempts_b;
wire        listenAttempts_b_ap_vld;
wire [31:0] portState_b;
wire        portState_b_ap_vld;
wire [15:0] m_axis_tcp_listen_port_b_TDATA;
wire        m_axis_tcp_listen_port_b_TVALID;
wire [1:0]  m_axis_tcp_listen_port_b_TKEEP;
wire [1:0]  m_axis_tcp_listen_port_b_TSTRB;
wire [0:0]  m_axis_tcp_listen_port_b_TLAST;
wire        s_axis_tcp_port_status_b_TREADY;

hls_dual_echo_krnl_dual_echo_listen dut (
     .ap_clk    (ap_clk),
     .ap_rst    (ap_rst),
     .ap_start  (stage_ap_start),
     .ap_done   (ap_done),
     .ap_continue(ap_continue),
     .ap_idle   (ap_idle),
     .ap_ready  (ap_ready),
     .ap_ce     (ap_ce),
     .enableB   (enableB),
     .listenPortB(listenPortB),
     .listenAttempts_b        (listenAttempts_b),
     .listenAttempts_b_ap_vld (listenAttempts_b_ap_vld),
     .portState_b             (portState_b),
     .portState_b_ap_vld      (portState_b_ap_vld),
     .m_axis_tcp_listen_port_b_TDATA (m_axis_tcp_listen_port_b_TDATA),
     .m_axis_tcp_listen_port_b_TVALID(m_axis_tcp_listen_port_b_TVALID),
     .m_axis_tcp_listen_port_b_TKEEP (m_axis_tcp_listen_port_b_TKEEP),
     .m_axis_tcp_listen_port_b_TSTRB (m_axis_tcp_listen_port_b_TSTRB),
     .m_axis_tcp_listen_port_b_TLAST (m_axis_tcp_listen_port_b_TLAST),
     .m_axis_tcp_listen_port_b_TREADY(m_axis_tcp_listen_port_b_TREADY),
     .s_axis_tcp_port_status_b_TDATA (s_axis_tcp_port_status_b_TDATA),
     .s_axis_tcp_port_status_b_TVALID(s_axis_tcp_port_status_b_TVALID),
     .s_axis_tcp_port_status_b_TREADY(s_axis_tcp_port_status_b_TREADY),
     .s_axis_tcp_port_status_b_TKEEP (s_axis_tcp_port_status_b_TKEEP),
     .s_axis_tcp_port_status_b_TSTRB (s_axis_tcp_port_status_b_TSTRB),
     .s_axis_tcp_port_status_b_TLAST (s_axis_tcp_port_status_b_TLAST)
);

// ── измерение ────────────────────────────────────────────────────────────────
//
// Считаем ПЕРЕДАЧИ на m_axis_tcp_listen_port_b -- это и есть «ядро попросило
// стек открыть порт». Именно этот счётчик на плате читается как listenAttempts
// и был нулём.
int unsigned port_writes = 0;
int unsigned cycles      = 0;

always @(posedge ap_clk) begin
     if (!ap_rst) begin
          cycles <= cycles + 1;
          if (m_axis_tcp_listen_port_b_TVALID && m_axis_tcp_listen_port_b_TREADY)
               port_writes <= port_writes + 1;
     end
end

task automatic reset_all();
     ap_rst = 1'b1;
     ap_start_drive = 1'b0;
     @(posedge ap_clk); @(posedge ap_clk);
     port_writes = 0;
     cycles      = 0;
     ap_rst = 1'b0;
     @(posedge ap_clk);
endtask

// ── прогон ───────────────────────────────────────────────────────────────────
int unsigned fails = 0;
int unsigned writes_const, writes_pulse;

task automatic check(string what, bit cond);
     if (cond) $display("  ok   %s", what);
     else begin
          $display("  FAIL %s", what);
          fails++;
     end
endtask

localparam int RUN_CYCLES = 4000;

initial begin
     $display("=== tb_listen_start: ap_start const vs pulsed ===");
     $display("");

     // ── СЦЕНАРИЙ A: ap_start = 1'b1 навсегда ────────────────────────────
     //
     // Это ТОЧНО то, что стоит в собранном битстриме:
     //     hls_dual_echo_krnl.v:779  assign dual_echo_core_U0_ap_start = 1'b1;
     $display("--- A: ap_start tied to 1'b1 (what the bitstream has) ---");
     reset_all();
     ap_start_drive = 1'b1;
     repeat (RUN_CYCLES) @(posedge ap_clk);
     writes_const = port_writes;
     $display("  listen_port writes in %0d cycles: %0d", RUN_CYCLES, writes_const);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);

     // Стадия обязана слать запрос ПОВТОРНО, пока стек не подтвердил порт: в
     // dual_echo_listen на это есть ветка LISTEN_TIMEOUT, которая сбрасывает
     // portRequested. Если запись всего одна -- значит конвейер встал, и ветка
     // таймаута никогда не исполнится.
     check("A: stage keeps retrying (more than 1 write)", writes_const > 1);

     // ── СЦЕНАРИЙ B: ap_start импульсами, как делает auto_restart ─────────
     //
     // control_s_axi.v:284-286 (сгенерированный HLS для hls_recv_krnl):
     //     if (WDATA[0])      int_ap_start <= 1'b1;
     //     else if (ap_ready) int_ap_start <= int_auto_restart;
     // То есть ap_start опускается на ap_ready и снова поднимается. Здесь это
     // воспроизведено буквально.
     $display("");
     $display("--- B: ap_start pulsed on ap_ready (what auto_restart does) ---");
     reset_all();
     fork
          begin : pulse_driver
               ap_start_drive = 1'b1;
               forever begin
                    @(posedge ap_clk);
                    if (ap_ready) begin
                         ap_start_drive = 1'b0;   // спад -- как int_ap_start
                         @(posedge ap_clk);
                         ap_start_drive = 1'b1;   // auto_restart поднимает снова
                    end
               end
          end
          begin : run_b
               repeat (RUN_CYCLES) @(posedge ap_clk);
          end
     join_any
     disable fork;
     writes_pulse = port_writes;
     $display("  listen_port writes in %0d cycles: %0d", RUN_CYCLES, writes_pulse);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);

     check("B: stage keeps retrying (more than 1 write)", writes_pulse > 1);

     // ── ГЛАВНОЕ СРАВНЕНИЕ ───────────────────────────────────────────────
     $display("");
     $display("--- verdict ---");
     $display("  const ap_start : %0d writes", writes_const);
     $display("  pulsed ap_start: %0d writes", writes_pulse);
     check("pulsed ap_start produces strictly more writes than const",
           writes_pulse > writes_const);

     $display("");
     if (fails == 0) begin
          $display("=== ALL GREEN ===");
     end else begin
          $display("=== FAILED: %0d ===", fails);
     end
     $finish;
end

// Страховка от вечного прогона, если стадия почему-то залипнет в X.
initial begin
     #200000;
     $display("*** TIMEOUT -- testbench did not finish");
     $finish;
end

endmodule

`default_nettype wire
