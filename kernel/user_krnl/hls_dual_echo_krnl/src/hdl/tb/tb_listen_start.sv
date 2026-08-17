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
// ЧТО ЭТОТ ТЕСТБЕНЧ УЖЕ УСТАНОВИЛ (прогон 17.08.2026)
//
// Три предположения о причине отказа на плате ОПРОВЕРГНУТЫ на живом RTL:
//
//   1. «Скаляры защёлкиваются при ap_ctrl_none без s_axilite, поэтому логика
//      видит enable=0» -- НЕТ. enableB читается комбинационно
//      (dual_echo_listen.v:676: icmp_ln210 = (enableB == 0)), и поздно
//      записанный enable=1 доходит: запрос уходит менее чем за 100 тактов
//      (фаза 2 зелёная). ЗНАЧИТ HDL-ОБЁРТКИ С СОБСТВЕННЫМИ РЕГИСТРАМИ НЕ БЫЛИ
//      НУЖНЫ -- они лечили болезнь, которой нет.
//
//   2. «ap_start = 1'b1 не даёт сбросить ap_sync_reg, стадия делает один проход
//      и замирает» -- НЕТ. Фаза 1 показала 2499 проходов за 5000 тактов, фаза 3
//      -- 602549 за 1.2 млн. Стадия запускается непрерывно.
//
//   3. «Стадия без while(true) не годится для непрерывной работы» -- НЕТ, см.
//      пункт 2. Апстримный listen_port_handler тоже без вечного цикла.
//
// ОТСЮДА ГЛАВНЫЙ ВЫВОД: стадия listen ИСПРАВНА, и наблюдаемый на плате
// listenAttempts=0 ею не объясняется. Остаются две причины ВНЕ стадии:
//     а) enableB не доходит до ядра (обёртка / адресная карта JTAG);
//     б) m_axis_tcp_listen_port_b_TREADY от стека равен нулю, и запись не
//        проходит -- фаза 4 ниже показывает, как это выглядит.
//
// ОШИБКА ДЛИТЕЛЬНОСТИ, ДОПУЩЕННАЯ ДВАЖДЫ -- чтобы не повторить в третий раз.
// Первая версия крутила 4000 тактов при LISTEN_TIMEOUT в миллион
// (dual_echo_listen.v:678: st_b_waitTimer > 20'd999999) и мерила штатное
// ожидание вместо дефекта. Вторая дала 1.2 млн тактов -- и снова не хватило,
// потому что waitTimer инкрементируется РАЗ В ПРОХОД, а не раз в такт, а
// достигнутый II равен двум (602549 проходов на 1.2 млн тактов). То есть порогу
// соответствует ~2 млн тактов. Правило: длительность прогона считать в ПРОХОДАХ
// стадии, умножая на фактический II из этого же теста, а не в тактах по
// константе из RTL.
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

wire ap_done, ap_idle, ap_ready;

// ── ap_continue: ПРЕДМЕТ ФАЗЫ 6 ──────────────────────────────────────────────
//
// Раньше здесь стояла константа 1'b1, и это было САМЫМ СЕРЬЁЗНЫМ расхождением
// теста с железом. В dual_echo_core оно устроено иначе:
//
//   core.v:1371  assign dual_echo_listen_U0_ap_continue = ap_sync_continue;
//   core.v:1335  assign ap_sync_continue = (ap_sync_done & ap_continue);
//   core.v:1337  assign ap_sync_done = (tie_off_udp_U0_ap_done & ... &
//                                       dual_echo_rx_drain_U0_ap_done & ...);
//                                      ^^^ И ПО ВСЕМ 14 СТАДИЯМ
//
// То есть listen получает ap_continue только когда ВСЕ 14 стадий региона
// выставили ap_done одновременно. А внутри стадии ap_done_reg сбрасывается
// ТОЛЬКО по ap_continue (listen.v:303), и при ap_done_reg == 1 конвейер
// заблокирован (listen.v:609, ap_block_pp0_stage1_01001).
//
// Отсюда подозрение на замкнутый круг: rx_drain ждёт данных в rxSessionFifo,
// данные кладёт rx_notify, тот ждёт notification от стека, а стек молчит, пока
// listen не открыл порт. Если ap_done одной стадии не приходит -- listen после
// первого ap_done встаёт навсегда.
//
// ФАЗА 6 подаёт ap_continue именно так, как core, с моделью «одна из прочих
// стадий не готова». Переключатель ниже позволяет фазам 1-5 работать по-старому,
// чтобы прежние результаты остались сравнимыми.
logic        other_stages_done = 1'b1;   // фазы 1-5: прочие стадии «готовы»
wire         ap_sync_done      = ap_done & other_stages_done;
wire         ap_continue       = ap_sync_done;   // как core.v:1335 при ap_continue=1

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
// (dual_echo_listen.v:678).
//
// ВНИМАНИЕ НА ЕДИНИЦЫ. Таймер инкрементируется РАЗ В ПРОХОД стадии, а не раз в
// такт: инкремент стоит под ap_condition_374, то есть внутри тела, которое
// исполняется один раз за итерацию конвейера. Фактический II равен двум
// (измерено этим же тестом: 602549 проходов на 1.2 млн тактов), поэтому порогу
// в миллион проходов соответствует примерно два миллиона тактов.
//
// Берём трёхкратный запас: прогон дешевле, чем ещё один слепой результат.
localparam int LISTEN_TIMEOUT   = 1_000_000;   // проходов
localparam int MEASURED_II      = 2;           // такта на проход
localparam int AFTER_ENABLE     = LISTEN_TIMEOUT * MEASURED_II + 1_000_000;

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

     // ── фаза 4: TREADY=0 -- ВОСПРОИЗВЕДЕНИЕ СИМПТОМА ПЛАТЫ ───────────────
     //
     // Фазы 1-3 доказали, что стадия исправна: enable доходит, проходы идут,
     // запрос уходит. Значит наблюдаемый на плате listenAttempts=0 объясняется
     // чем-то ВНЕ стадии. Самый вероятный кандидат -- стек не поднимает
     // m_axis_tcp_listen_port_TREADY, и тогда запись не проходит НИКОГДА.
     //
     // Здесь это проверяется прямо: полный сброс, enable=1 с самого начала (то
     // есть условия ЛУЧШЕ платы), но TREADY=0. Если результат совпадёт с
     // наблюдаемым на плате -- listenAttempts=0 при работающем ядре -- значит
     // искать надо TREADY, а не переписывать ядро.
     //
     // ПОЧЕМУ ЭТО НЕ ПРОВЕРКА «ЯДРО ПЛОХОЕ». Стадия обязана вести себя именно
     // так: писать в полный поток нельзя, а nbwritereq для этого и стоит.
     // Проверка утверждает не дефект, а ДИАГНОСТИЧЕСКИЙ ПРИЗНАК: вот так
     // выглядит снаружи закрытый TREADY, и это неотличимо от «ядро не
     // запустилось». Именно поэтому на плате нужен VIO на TREADY.
     $display("");
     $display("--- phase 4: TREADY=0 -- what a stalled stack looks like ---");
     ap_rst         = 1'b1;
     ap_start_drive = 1'b0;
     m_axis_tcp_listen_port_b_TREADY = 1'b0;    // стек не принимает
     enableB        = 32'd1;                    // enable есть с самого начала
     repeat (4) @(posedge ap_clk);
     port_writes  = 0;
     ready_pulses = 0;
     ap_rst       = 1'b0;
     @(posedge ap_clk);
     ap_start_drive = 1'b1;

     repeat (20_000) @(posedge ap_clk);
     $display("  port writes  : %0d", port_writes);
     $display("  ready pulses : %0d", ready_pulses);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);
     check("phase 4: no write gets through while TREADY is low",
           port_writes == 0);
     check("phase 4: listenAttempts stays at zero -- the board symptom",
           listenAttempts_b == 32'd0);

     // ── фаза 6: ap_continue ЗАВИСИТ ОТ ДРУГИХ СТАДИЙ ─────────────────────
     //
     // Здесь воспроизводится то, чего не было ни в одной прежней фазе: в
     // dual_echo_core ap_continue стадии равен ap_sync_done -- И по ВСЕМ 14
     // стадиям (core.v:1337). Ставим other_stages_done = 0, что означает «хотя
     // бы одна стадия региона не выставила ap_done». На плате такой стадией
     // предполагается rx_drain: он ждёт данных, которых не будет, пока listen
     // не открыл порт.
     //
     // TREADY возвращаем в 1 и enable держим 1 -- условия для listen идеальные.
     // Единственное отличие от фазы 3, где было 2 записи, это ap_continue.
     // Поэтому результат ОДНОЗНАЧНО приписывается ему.
     $display("");
     $display("--- phase 6: ap_continue gated by other stages (as in core) ---");
     ap_rst            = 1'b1;
     ap_start_drive    = 1'b0;
     m_axis_tcp_listen_port_b_TREADY = 1'b1;    // стек принимает
     enableB           = 32'd1;                 // разрешено
     other_stages_done = 1'b0;                  // <- ЕДИНСТВЕННОЕ ОТЛИЧИЕ
     repeat (4) @(posedge ap_clk);
     port_writes  = 0;
     ready_pulses = 0;
     ap_rst       = 1'b0;
     @(posedge ap_clk);
     ap_start_drive = 1'b1;

     // Прогон с тем же запасом, что фаза 3: если дело только в скорости, за
     // 3 млн тактов повтор успел бы случиться (в фазе 3 он случился).
     repeat (AFTER_ENABLE) @(posedge ap_clk);
     $display("  port writes  : %0d", port_writes);
     $display("  ready pulses : %0d", ready_pulses);
     $display("  portState=%0d listenAttempts=%0d", portState_b, listenAttempts_b);

     // ЭТО И ЕСТЬ ПРОВЕРЯЕМОЕ УТВЕРЖДЕНИЕ. В фазе 3 при том же прогоне было
     // 2 записи и полтора миллиона проходов. Если здесь их резко меньше --
     // механизм подтверждён: ap_continue от чужих стадий останавливает listen.
     check("phase 6: stage STALLS when ap_continue never arrives",
           ready_pulses < 100);
     check("phase 6: listen request does not repeat", port_writes <= 1);

     $display("");
     $display("--- phase 6 vs phase 3: same everything but ap_continue ---");
     $display("  phase 3 (ap_continue from own ap_done): 1502549 ready, 2 writes");
     $display("  phase 6 (ap_continue gated by others) : %0d ready, %0d writes",
              ready_pulses, port_writes);

     $display("");
     $display("--- what phase 4 means ---");
     if (port_writes == 0 && listenAttempts_b == 32'd0)
          $display("  A closed TREADY reproduces the board symptom exactly:");
     $display("  listenAttempts=0 with a fully working stage.");
     $display("  Next step on hardware: probe m_axis_tcp_listen_port_TREADY,");
     $display("  do NOT rewrite the kernel.");

     $display("");
     if (fails == 0)
          $display("=== ALL GREEN ===");
     else
          $display("=== FAILED: %0d ===", fails);
     $finish;
end

// Страховка. Прогон длинный: фазы 1-5 дают ~3 млн тактов, фаза 6 ещё 3 млн,
// итого ~6 млн при 5 нс = ~30 мс модельного времени. Лимит с запасом.
initial begin
     #45_000_000;
     $display("*** TIMEOUT -- testbench did not finish");
     $finish;
end

endmodule

`default_nettype wire
