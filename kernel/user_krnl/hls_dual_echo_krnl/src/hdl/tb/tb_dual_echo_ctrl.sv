// =============================================================================
// tb_dual_echo_ctrl -- доходит ли enable от AXI-Lite до порта HLS-ядра
// =============================================================================
//
// ЧТО ЭТО ПРОВЕРЯЕТ. Единственное звено цепочки, которое до сих пор не было
// проверено ничем:
//
//     JTAG/AXI-Lite -> dual_echo_control_s_axi -> enable_reg -> порт enableA/B
//                                                              инстанса ядра
//
// НА ПЛАТЕ НАБЛЮДАЛОСЬ: enable записан по 0x10 и читается обратно как 1, а
// portState остаётся 0, то есть логика ядра его не видит. Все остальные
// объяснения этого симптома проверены и опровергнуты:
//
//   * скаляры НЕ защёлкиваются -- enableB читается комбинационно
//     (dual_echo_listen.v:676), поздняя запись доходит за <100 тактов;
//   * ap_start=1'b1 стадию НЕ блокирует -- 602549 проходов за 1.2 млн тактов;
//   * static внутри DATAFLOW не теряется -- внутри стадии это регистры со
//     сбросом только по ap_rst;
//   * ap_ctrl=0x81 пишется (jtag_ctrl.tcl), и на enable он не влияет;
//   * в BD стоит именно hls_dual_echo_krnl_1 по адресу 0x10000, что совпадает
//     с ouch_base_user 1 -- то есть пишем в правильное ядро;
//   * ACLK_EN=1'b1, int_enable пишется, enable_reg идёт в оба входа напрямую.
//
// Все звенья по отдельности исправны. Здесь проверяется цепочка ЦЕЛИКОМ -- на
// настоящих dual_echo_control_s_axi.v и hls_dual_echo_krnl_wrapper.sv, с
// заглушкой вместо HLS-ядра (stub_hls_dual_echo_krnl_ip.v, сгенерирована из
// того же RTL, что уходит в битстрим).
//
// ЧТО ЗАМЕНЕНО ЗАГЛУШКОЙ И ПОЧЕМУ ЭТО НЕ ПОДЛОГ. Ядро здесь не нужно: вопрос
// не «работают ли стадии» (это tb_listen_start), а «видит ли ядро enable».
// Заглушка -- свидетель: она защёлкивает то, что пришло на её входы, в регистры
// seen_*, и тестбенч читает их иерархически. Плюс отдаёт portState = (enable !=
// 0), имитируя ровно то, чего на плате не происходило.
//
// ЧЕГО НЕ ПРОВЕРЯЕТ: тайминг (это impl) и поведение стека (это плата). Если
// этот тестбенч зелёный, обёртка исправна целиком, и остаётся только то, что
// видно на железе -- для этого в обёртке уже стоит VIO.
//
// Сообщения на латинице: $display в xsim 2024.1 портит многобайтовые символы.

`timescale 1ns / 1ps
`default_nettype none

module tb_dual_echo_ctrl;

// ── тактирование и сброс ─────────────────────────────────────────────────────
logic ap_clk = 1'b0;
always #2.5 ap_clk = ~ap_clk;          // 200 МГц

logic ap_rst_n = 1'b0;                 // обёртка ждёт АКТИВНЫЙ-НИЗКИЙ

// ── AXI4-Lite мастер ─────────────────────────────────────────────────────────
logic        awvalid = 1'b0;
wire         awready;
logic [11:0] awaddr  = 12'h0;
logic        wvalid  = 1'b0;
wire         wready;
logic [31:0] wdata   = 32'h0;
logic [3:0]  wstrb   = 4'hF;
logic        arvalid = 1'b0;
wire         arready;
logic [11:0] araddr  = 12'h0;
wire         rvalid;
logic        rready  = 1'b0;
wire  [31:0] rdata;
wire  [1:0]  rresp;
wire         bvalid;
logic        bready  = 1'b0;
wire  [1:0]  bresp;
wire         interrupt;

// Все AXI-Stream входы обёртки держим в покое: тракт данных здесь не проверяется.
// Именованные подключения ниже перечисляют только то, что нужно; остальные входы
// оставлены неподключёнными намеренно -- xelab подтянет их к нулю, а обёртка
// гонит их в заглушку, которая на них не смотрит.
hls_dual_echo_krnl_wrapper dut (
     .ap_clk  (ap_clk),
     .ap_rst_n(ap_rst_n),

     .s_axi_control_awvalid(awvalid),
     .s_axi_control_awready(awready),
     .s_axi_control_awaddr (awaddr),
     .s_axi_control_wvalid (wvalid),
     .s_axi_control_wready (wready),
     .s_axi_control_wdata  (wdata),
     .s_axi_control_wstrb  (wstrb),
     .s_axi_control_arvalid(arvalid),
     .s_axi_control_arready(arready),
     .s_axi_control_araddr (araddr),
     .s_axi_control_rvalid (rvalid),
     .s_axi_control_rready (rready),
     .s_axi_control_rdata  (rdata),
     .s_axi_control_rresp  (rresp),
     .s_axi_control_bvalid (bvalid),
     .s_axi_control_bready (bready),
     .s_axi_control_bresp  (bresp),
     .interrupt            (interrupt)
);

// ── адресная карта: те же значения, что DE_OFF_* в jtag_ctrl.tcl ─────────────
//
// Если эти константы разойдутся с dual_echo_control_s_axi.v, тест это покажет:
// запись не подтвердится при чтении. Именно этого не могло проверить ничто
// раньше -- *_hw.h для ядра без s_axilite не генерируется, о чём предупреждает
// шаг user_ip в логе сборки.
localparam [11:0] ADDR_AP_CTRL    = 12'h000;
localparam [11:0] ADDR_ENABLE     = 12'h010;
localparam [11:0] ADDR_PORT_A     = 12'h018;
localparam [11:0] ADDR_PORT_B     = 12'h020;
localparam [11:0] ADDR_ATT_A      = 12'h030;
localparam [11:0] ADDR_STATE_A    = 12'h034;
localparam [11:0] ADDR_ATT_B      = 12'h040;
localparam [11:0] ADDR_STATE_B    = 12'h044;

// ── транзакции ───────────────────────────────────────────────────────────────
task automatic axi_write(input [11:0] addr, input [31:0] data);
     @(posedge ap_clk);
     awvalid <= 1'b1; awaddr <= addr;
     wvalid  <= 1'b1; wdata  <= data; wstrb <= 4'hF;
     bready  <= 1'b1;
     // Ждём оба рукопожатия независимо: порядок awready/wready не задан.
     fork
          begin while (!(awvalid && awready)) @(posedge ap_clk); awvalid <= 1'b0; end
          begin while (!(wvalid  && wready )) @(posedge ap_clk); wvalid  <= 1'b0; end
     join
     while (!bvalid) @(posedge ap_clk);
     @(posedge ap_clk);
     bready <= 1'b0;
endtask

task automatic axi_read(input [11:0] addr, output [31:0] data);
     @(posedge ap_clk);
     arvalid <= 1'b1; araddr <= addr; rready <= 1'b1;
     while (!(arvalid && arready)) @(posedge ap_clk);
     arvalid <= 1'b0;
     while (!rvalid) @(posedge ap_clk);
     data = rdata;
     @(posedge ap_clk);
     rready <= 1'b0;
endtask

// ── проверки ─────────────────────────────────────────────────────────────────
int unsigned fails = 0;

task automatic check(string what, bit cond);
     if (cond) $display("  ok   %s", what);
     else begin
          $display("  FAIL %s", what);
          fails++;
     end
endtask

task automatic check_eq(string what, logic [31:0] got, logic [31:0] want);
     if (got === want) $display("  ok   %s (=%08x)", what, got);
     else begin
          $display("  FAIL %s: got %08x, want %08x", what, got, want);
          fails++;
     end
endtask

logic [31:0] rd;

initial begin
     $display("=== tb_dual_echo_ctrl: does enable reach the kernel port? ===");
     $display("");

     repeat (10) @(posedge ap_clk);
     ap_rst_n = 1'b1;
     repeat (10) @(posedge ap_clk);

     // ── фаза 0: до записи ────────────────────────────────────────────────
     //
     // seen_* инициализированы DEADBEEF и должны стать нулями после сброса:
     // обёртка держит на enable_reg ноль, пока хост не записал.
     $display("--- phase 0: after reset, before any write ---");
     $display("  seen_enableA = %08x", dut.hls_dual_echo_krnl_inst.seen_enableA);
     check_eq("enableA at kernel port is zero",
              dut.hls_dual_echo_krnl_inst.seen_enableA, 32'd0);
     axi_read(ADDR_STATE_A, rd);
     check_eq("portState_a reads 0", rd, 32'd0);

     // ── фаза 1: порты, как это делает dual_echo_configure ────────────────
     $display("");
     $display("--- phase 1: dual_echo_configure 7001 7002 ---");
     axi_write(ADDR_PORT_A, 32'd7001);
     axi_write(ADDR_PORT_B, 32'd7002);
     axi_read(ADDR_PORT_A, rd);
     check_eq("portA reads back", rd, 32'd7001);
     axi_read(ADDR_PORT_B, rd);
     check_eq("portB reads back", rd, 32'd7002);

     repeat (4) @(posedge ap_clk);
     check_eq("listenPortA reached the kernel port",
              dut.hls_dual_echo_krnl_inst.seen_listenPortA, 32'd7001);
     check_eq("listenPortB reached the kernel port",
              dut.hls_dual_echo_krnl_inst.seen_listenPortB, 32'd7002);

     // ── фаза 2: ГЛАВНОЕ -- enable ────────────────────────────────────────
     //
     // Ровно то, что делалось на плате: axi_write32 base+0x10 1.
     $display("");
     $display("--- phase 2: write enable=1 at 0x10 (what the board did) ---");
     axi_write(ADDR_ENABLE, 32'd1);
     axi_read(ADDR_ENABLE, rd);
     check_eq("enable reads back as 1", rd, 32'd1);

     repeat (4) @(posedge ap_clk);
     $display("  seen_enableA = %08x", dut.hls_dual_echo_krnl_inst.seen_enableA);
     $display("  seen_enableB = %08x", dut.hls_dual_echo_krnl_inst.seen_enableB);

     // ЭТО И ЕСТЬ ВОПРОС. Если здесь FAIL -- дефект в HDL-обёртке, и он найден.
     // Если ok -- обёртка исправна, enable доходит, и причину на плате надо
     // искать в том, что симуляция не видит.
     check_eq("enableA reached the kernel port",
              dut.hls_dual_echo_krnl_inst.seen_enableA, 32'd1);
     check_eq("enableB reached the kernel port",
              dut.hls_dual_echo_krnl_inst.seen_enableB, 32'd1);

     // ── фаза 3: телеметрия обратно ───────────────────────────────────────
     //
     // Заглушка отдаёт portState = 1 при enable != 0. Проверяем, что обёртка
     // доносит это до хоста: на плате здесь был стабильный ноль.
     $display("");
     $display("--- phase 3: telemetry back to the host ---");
     axi_read(ADDR_STATE_A, rd);
     check_eq("portState_a now reads 1", rd, 32'd1);
     axi_read(ADDR_STATE_B, rd);
     check_eq("portState_b now reads 1", rd, 32'd1);

     // listenAttempts у заглушки -- эхо listenPort. Проверяет обратный путь
     // счётчиков, по которому на плате приходили нули.
     axi_read(ADDR_ATT_A, rd);
     check_eq("listenAttempts_a carries the echo", rd, 32'd7001);
     axi_read(ADDR_ATT_B, rd);
     check_eq("listenAttempts_b carries the echo", rd, 32'd7002);

     // ── фаза 4: ap_ctrl -- влияет ли он на enable ────────────────────────
     //
     // Обёртка утверждает (шапка wrapper.sv), что работу разрешает enable, а
     // ap_start нужен лишь для рукопожатия с BD. Проверяем буквально: enable
     // уже дошёл БЕЗ записи ap_ctrl. Затем пишем 0x81, как dual_echo_enable,
     // и убеждаемся, что ничего не сломалось.
     $display("");
     $display("--- phase 4: ap_ctrl=0x81, as dual_echo_enable does ---");
     axi_write(ADDR_AP_CTRL, 32'h81);
     repeat (8) @(posedge ap_clk);
     check_eq("enableA still at the kernel port after ap_start",
              dut.hls_dual_echo_krnl_inst.seen_enableA, 32'd1);
     axi_read(ADDR_STATE_A, rd);
     check_eq("portState_a still 1 after ap_start", rd, 32'd1);

     // ── фаза 5: выключение ───────────────────────────────────────────────
     $display("");
     $display("--- phase 5: enable=0 stops it ---");
     axi_write(ADDR_ENABLE, 32'd0);
     repeat (4) @(posedge ap_clk);
     check_eq("enableA back to zero",
              dut.hls_dual_echo_krnl_inst.seen_enableA, 32'd0);
     axi_read(ADDR_STATE_A, rd);
     check_eq("portState_a back to 0", rd, 32'd0);

     $display("");
     if (fails == 0)
          $display("=== ALL GREEN ===");
     else
          $display("=== FAILED: %0d ===", fails);
     $finish;
end

initial begin
     #500_000;
     $display("*** TIMEOUT -- testbench did not finish");
     $display("    An AXI handshake never completed: check awready/wready/bvalid.");
     $finish;
end

endmodule

`default_nettype wire
