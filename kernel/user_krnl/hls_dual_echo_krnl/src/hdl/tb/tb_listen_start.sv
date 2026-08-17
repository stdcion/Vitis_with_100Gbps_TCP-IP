// =============================================================================
// tb_listen_start -- доходит ли до стадии listen поздно записанный enable
// =============================================================================
//
// ЧТО ЭТО ПРОВЕРЯЕТ. Один вопрос, ровно тот, что стоит на плате:
//
//     стадия dual_echo_listen отработала при enable=0 (сразу после сброса,
//     когда JTAG ещё ничего не записал). Заметит ли она enable=1, записанный
//     через много тактов после этого?
//
// На плате наблюдается listenAttempts=0 при enable=1, читаемом обратно верно.
// Значит либо стадия не видит enable, либо её больше не запускают. Здесь это
// различается напрямую.
//
// Симулируется СГЕНЕРИРОВАННЫЙ HLS-RTL (hls_dual_echo_krnl_dual_echo_listen.v),
// то есть железо из битстрима, а не модель замысла.
//
// ЧЕГО НЕ ПРОВЕРЯЕТ csim: механизм ap_start/ap_ready/ap_sync появляется только
// при синтезе. В C++ вызов функции просто происходит, поэтому дефект в запуске
// стадии для csim НЕВИДИМ -- ядро проходило csim зелёным и не работало на плате.
//
// ─────────────────────────────────────────────────────────────────────────────
// ИСТОРИЯ ЭТОГО ФАЙЛА -- ЧТОБЫ НЕ ПОВТОРИТЬ ОШИБКУ.
//
// Первая версия сравнивала ap_start константой против ap_start импульсами
// (гипотеза: константа 1'b1 не даёт сбросить ap_sync_reg, поэтому стадия делает
// один проход). Оба сценария дали ОДНУ запись, гипотеза опровергнута.
//
// Но опровергнута она была НЕ ПОТОМУ, что неверна, а потому что тестбенч был
// слепым: он крутил 4000 тактов, а стадия ждёт ответа стека
//
//     dual_echo_listen.v:678
//         assign icmp_ln250_fu_230_p2 = ((st_b_waitTimer > 20'd999999) ? 1 : 0);
//
// то есть МИЛЛИОН тактов (LISTEN_TIMEOUT в .cpp). За 4000 тактов повторный
// запрос не наступает ни при какой схеме запуска -- измерялся штатный интервал
// ожидания, а не дефект. Отсюда правило: длительность прогона проверять против
// констант в СГЕНЕРИРОВАННОМ RTL, а не против интуиции.
//
// Заодно первая версия держала enable=1 с нулевого такта -- «условия лучше, чем
// на плате». Это и убило проверку: на плате enable приходит ПОЗДНО, и весь
// вопрос именно в этом. Теперь сценарий платы воспроизводится буквально.
// ─────────────────────────────────────────────────────────────────────────────
//
// ПОЧЕМУ НЕ ИНСТАНЦИРУЕТСЯ dual_echo_core. У него 221 порт, из них измеряемых
// три. Берётся сама стадия, а логика ap_sync вокруг неё воспроизведена ниже по
// сгенерированному RTL дословно, со ссылками на строки оригинала.
//
// Сообщения на латинице -- $display в xsim 2024.1 портит многобайтовые символы.

`timescale 1ns / 1ps
`default_nettype none

module tb_listen_start;

// ── тактирование ─────────────────────────────────────────────────────────────
logic ap_clk = 1'b0;
always #2.5 ap_clk = ~ap_clk;          // 200 МГц; период на логику не влияет

logic ap_rst = 1'b1;                   // стадия ждёт АКТИВНЫЙ-ВЫСОКИЙ сброс

// ── входы стадии ─────────────────────────────────────────────────────────────
logic [31:0] enableB     = 32'd0;      // НАЧИНАЕМ С НУЛЯ -- как на плате
logic [15:0] listenPortB = 16'd5001;

// Стек готов принять запрос, но статусом не отвечает НИКОГДА. Это сценарий
// платы: там listenAttempts остался нулём, то есть до ответа дело не дошло.
// Молчащий стек заставляет стадию идти по ветке waitTimer -> LISTEN_TIMEOUT,
// которая и должна повторить запрос.
logic       m_axis_tcp_listen_port_b_TREADY  = 1'b1;
logic       s_axis_tcp_port_status_b_TVALID  = 1'b0;
logic [7:0] s_axis_tcp_port_status_b_TDATA   = 8'd0;
logic [0:0] s_axis_tcp_port_status_b_TKEEP   = 1'b1;
logic [0:0] s_axis_tcp_port_status_b_TSTRB   = 1'b1;
logic [0:0] s_axis_tcp_port_status_b_TLAST   = 1'b1;
logic       ap_ce = 1'b1;

// ── управление ───────────────────────────────────────────────────────────────
//
// ap_start подаётся КОНСТАНТОЙ 1'b1 -- ровно как в собранном битстриме:
//     hls_dual_echo_krnl.v:779  assign dual_echo_core_U0_ap_start = 1'b1;
// Сравнение с импульсным вариантом убрано: оно проверяло опровергнутую
// гипотезу и при верной длительности прогона ничего не различает.
logic ap_start_drive = 1'b0;
logic ap_continue    = 1'b1;

wire ap_done, ap_idle, ap_ready;

// ── ВОСПРОИЗВЕДЕНИЕ ap_sync ИЗ dual_echo_core.v ──────────────────────────────
//
//   core.v:1373  assign ..._ap_start = ((ap_sync_reg_..._ap_ready ^ 1'b1) & ap_start);
//   core.v:1341  assign ap_sync_..._ap_ready = (..._ap_ready | ap_sync_reg_...);
//   core.v:1179  if (ap_rst) ap_sync_reg <= 0;
//                else if ((ap_sync_ready & ap_start) == 1) ap_sync_reg <= 0;
//                else ap_sync_reg <= ap_sync_..._ap_ready;
//
// ap_sync_ready в оригинале -- И по ВСЕМ 14 стадиям (core.v:1347). Здесь стадия
// одна, поэтому берётся её собственная готовность. Модель ОПТИМИСТИЧНЕЕ железа:
// в настоящем core сброс ap_sync_reg требует согласия всех 14 стадий, то есть
// происходит РЕЖЕ. Если стадия замирает даже здесь -- на плате тем более.
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
// Считаем ПЕРЕДАЧИ на m_axis_tcp_listen_port_b: «ядро попросило стек открыть
// порт». Именно этот счётчик на плате читается как listenAttempts и был нулём.
int unsigned port_writes = 0;

always @(posedge ap_clk) begin
     if (!ap_rst)
          if (m_axis_tcp_listen_port_b_TVALID && m_axis_tcp_listen_port_b_TREADY)
               port_writes <= port_writes + 1;
end

// Проход стадии = импульс ap_ready. Отдельный счётчик отвечает на вопрос
// «стадию ещё запускают, или она замерла?» -- без него «нет записи» не
// отличить от «нет запусков».
int unsigned ready_pulses = 0;

always @(posedge ap_clk) begin
     if (!ap_rst)
          if (ap_ready)
               ready_pulses <= ready_pulses + 1;
end

// ── прогон ───────────────────────────────────────────────────────────────────
int unsigned fails = 0;

task automatic check(string what, bit cond);
     if (cond) $display("  ok   %s", what);
     else begin
          $display("  FAIL %s", what);
          fails++;
     end
endtask

// LISTEN_TIMEOUT из сгенерированного RTL: st_b_waitTimer > 20'd999999
// (dual_echo_listen.v:678). Прогон ПОСЛЕ enable должен заведомо перекрыть его,
// иначе повторный запрос не наступит и тест снова окажется слепым.
localparam int LISTEN_TIMEOUT = 1_000_000;
localparam int AFTER_ENABLE   = LISTEN_TIMEOUT + 200_000;

// Сколько тактов ядро крутится при enable=0 -- имитация задержки JTAG. На плате
// это десятки секунд; здесь достаточно тысяч, потому что вопрос качественный:
// стадия уже отработала проход при enable=0 и ушла в ap_done.
localparam int BEFORE_ENABLE = 5_000;

int unsigned writes_before, ready_before;

initial begin
     $display("=== tb_listen_start: does a late enable reach the stage? ===");
     $display("");

     // ── сброс ────────────────────────────────────────────────────────────
     ap_rst         = 1'b1;
     ap_start_drive = 1'b0;
     repeat (4) @(posedge ap_clk);
     ap_rst         = 1'b0;
     @(posedge ap_clk);
     ap_start_drive = 1'b1;              // как 1'b1 в битстриме

     // ── фаза 1: enable=0, ядро живёт само по себе ────────────────────────
     $display("--- phase 1: enable=0 (JTAG has not written yet) ---");
     repeat (BEFORE_ENABLE) @(posedge ap_clk);
     writes_before = port_writes;
     ready_before  = ready_pulses;
     $display("  port writes  : %0d", writes_before);
     $display("  ready pulses : %0d", ready_before);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);

     // При enable=0 стадия обязана молчать: в .cpp это ветка
     // if (!enable) { portState = 0; return; }
     check("phase 1: no port request while disabled", writes_before == 0);

     // Стадию ДОЛЖНЫ запускать повторно. Если проходов ноль или один -- она
     // замерла, и тогда никакой enable её уже не разбудит. ЭТО ГЛАВНАЯ
     // ПРОВЕРКА: именно она отвечает на вопрос платы.
     check("phase 1: stage is still being restarted (ready pulses > 1)",
           ready_before > 1);

     // ── фаза 2: JTAG записал enable=1 ────────────────────────────────────
     $display("");
     $display("--- phase 2: enable=1 written late ---");
     enableB = 32'd1;

     // Ждём немного: первый запрос должен уйти почти сразу после enable.
     repeat (100) @(posedge ap_clk);
     $display("  after 100 cycles: port writes=%0d portState=%0d listenAttempts=%0d",
              port_writes, portState_b, listenAttempts_b);
     check("phase 2: first port request goes out right after enable",
           port_writes >= 1);

     // ── фаза 3: молчащий стек -> повтор по таймауту ──────────────────────
     //
     // Стек не отвечает, значит через LISTEN_TIMEOUT тактов стадия обязана
     // сбросить portRequested и попросить снова. Прогон с запасом.
     $display("");
     $display("--- phase 3: stack stays silent, retry after LISTEN_TIMEOUT ---");
     repeat (AFTER_ENABLE) @(posedge ap_clk);
     $display("  port writes  : %0d", port_writes);
     $display("  ready pulses : %0d", ready_pulses);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);
     check("phase 3: request is retried (more than one write)", port_writes > 1);
     check("phase 3: listenAttempts follows the writes",
           listenAttempts_b == port_writes);

     $display("");
     if (fails == 0)
          $display("=== ALL GREEN ===");
     else
          $display("=== FAILED: %0d ===", fails);
     $finish;
end

// Страховка. Прогон длинный (>1.2 млн тактов при 5 нс = ~6 мс модельного
// времени), поэтому лимит с запасом.
initial begin
     #20_000_000;
     $display("*** TIMEOUT -- testbench did not finish");
     $finish;
end

endmodule

`default_nettype wire
