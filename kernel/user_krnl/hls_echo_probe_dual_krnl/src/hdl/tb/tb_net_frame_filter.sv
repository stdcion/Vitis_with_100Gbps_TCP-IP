// =============================================================================
// tb_net_frame_filter -- тестбенч НАСТОЯЩЕГО net_frame_filter.v под xsim
// =============================================================================
//
// ЗАЧЕМ ОН, ЕСЛИ ЕСТЬ test_net_frame_filter.py. Питоновская модель проверяет
// ИДЕЮ логики (порядок обновления регистров, какие признаки нужны). Она НЕ
// видит того, что написано в .v: опечатку в индексе бита, неверную разрядность
// счётчика, забытый сброс, неверную ширину сравнения. Здесь симулируется сам
// исходник, поэтому эти ошибки ловятся.
//
// Модель и этот тестбенч проверяют одно и то же поведение РАЗНЫМИ путями --
// если они разойдутся, ошибка в одном из двух, и это само по себе сигнал.
//
// ЗАПУСК: см. kernel/user_krnl/hls_echo_probe_dual_krnl/src/hdl/tb/run_sim.sh
//
// ЧЕГО НЕ ПРОВЕРЯЕТ: тайминг (это к impl) и то, что фильтр правильно подключён
// в обёртке (это tb_probe_taps.sv).

`timescale 1ns / 1ps
`default_nettype none

module tb_net_frame_filter;

     localparam [47:0] MARKER = 48'h5A3C96E1B7D2;

     reg          clk = 1'b0;
     reg          rst_n = 1'b0;
     reg          tvalid = 1'b0;
     reg          tready = 1'b1;
     reg          tlast = 1'b0;
     reg  [511:0] tdata = 512'b0;
     reg  [31:0]  min_words = 32'd2;

     wire         frame_ours;
     wire [31:0]  count_ours, count_drop;

     integer errors = 0;
     integer strobes = 0;          // сколько раз frame_ours поднялся
     integer last_strobe_tag = -1; // на каком кадре был последний строб

     // тег текущего кадра, чтобы знать, НА КАКОМ кадре сработал строб
     integer cur_tag = -1;

     always #5 clk = ~clk;         // 100 МГц, период здесь роли не играет

     net_frame_filter dut (
          .ap_clk     (clk),
          .ap_rst_n   (rst_n),
          .tvalid     (tvalid),
          .tready     (tready),
          .tlast      (tlast),
          .tdata      (tdata),
          .min_words  (min_words),
          .frame_ours (frame_ours),
          .count_ours (count_ours),
          .count_drop (count_drop)
     );

     // Ловим строб непрерывно: frame_ours -- комбинационный импульс на один
     // такт, и проверять его «потом» нельзя.
     always @(posedge clk) begin
          if (rst_n && frame_ours) begin
               strobes         <= strobes + 1;
               last_strobe_tag <= cur_tag;
          end
     end

     // name -- string, а НЕ [255:0]: вектор вмещает 32 байта, и сообщения
     // на кириллице (2 байта на символ в UTF-8) обрезались посередине.
     // Прогон 13.08 печатал «ok   М (tag=6  SYN» вместо полной строки.
     task check(input string name, input cond);
          begin
               if (cond) $display("  ok   %0s", name);
               else begin $display("  FAIL %0s", name); errors = errors + 1; end
          end
     endtask

     // Один кадр: nwords слов, маркер кладём только в ПЕРВОЕ слово.
     // marked=0 имитирует чужой кадр (ARP/ACK/SYN) -- там на битах 511:464
     // лежит что угодно, но не наша константа.
     task send_frame(input integer tag, input integer nwords, input marked);
          integer i;
          begin
               cur_tag = tag;
               for (i = 0; i < nwords; i = i + 1) begin
                    @(negedge clk);
                    tvalid = 1'b1;
                    tlast  = (i == nwords - 1);
                    tdata  = 512'b0;
                    if (i == 0) begin
                         tdata[31:0] = 32'hDEADC0DE;      // «sent», меняется
                         if (marked) tdata[511:464] = MARKER;
                         else        tdata[511:464] = 48'h0102030405AA; // чужое
                    end
               end
               @(negedge clk);
               tvalid = 1'b0;
               tlast  = 1'b0;
          end
     endtask

     // Кадр с паузами внутри (tvalid снимается между словами) и с
     // backpressure (tready снимается). Проверяет, что счёт слов не уезжает.
     task send_frame_stalled(input integer tag, input integer nwords, input marked);
          integer i;
          begin
               cur_tag = tag;
               for (i = 0; i < nwords; i = i + 1) begin
                    // пауза: valid снят
                    @(negedge clk); tvalid = 1'b0; tlast = 1'b0;
                    // backpressure: valid есть, ready нет -- beat НЕ должен
                    // засчитаться, иначе счёт слов и маркер уедут
                    @(negedge clk);
                    tvalid = 1'b1;
                    tready = 1'b0;
                    tlast  = (i == nwords - 1);
                    tdata  = 512'b0;
                    if (i == 0) begin
                         tdata[31:0] = 32'hDEADC0DE;
                         if (marked) tdata[511:464] = MARKER;
                         else        tdata[511:464] = 48'h0102030405AA;
                    end
                    @(negedge clk);
                    tready = 1'b1;   // теперь beat проходит
               end
               @(negedge clk);
               tvalid = 1'b0; tlast = 1'b0;
          end
     endtask

     integer s0, d0;

     initial begin
          $display("=== tb_net_frame_filter ===");

          repeat (4) @(negedge clk);
          rst_n = 1'b1;
          repeat (2) @(negedge clk);

          check("после сброса счётчики нулевые",
                (count_ours == 0) && (count_drop == 0));

          // ── 1. норма: minWords=2 ────────────────────────────────────────
          $display("\n[1] наш кадр среди служебных, minWords=2");
          min_words = 32'd2;
          s0 = strobes;
          send_frame(1, 1, 1'b0);   // ARP     -- 1 слово
          send_frame(2, 2, 1'b1);   // НАШ     -- 2 слова + маркер
          send_frame(3, 1, 1'b0);   // ACK     -- 1 слово
          repeat (2) @(negedge clk);
          check("ровно один строб", (strobes - s0) == 1);
          check("строб на НАШЕМ кадре (tag=2)", last_strobe_tag == 2);
          check("count_ours=1", count_ours == 1);
          check("count_drop=2", count_drop == 2);

          // ── 2. SYN с опциями: длину проходит, маркер нет ─────────────────
          $display("\n[2] TCP SYN с опциями (2 слова, без маркера)");
          s0 = strobes; d0 = count_drop;
          send_frame(4, 2, 1'b0);
          repeat (2) @(negedge clk);
          check("строба НЕТ -- отсечён МАРКЕРОМ", (strobes - s0) == 0);
          check("посчитан как отброшенный", count_drop == d0 + 1);

          // ── 3. SYN прямо перед нашим кадром ──────────────────────────────
          $display("\n[3] SYN, сразу за ним наш кадр");
          s0 = strobes;
          send_frame(5, 2, 1'b0);
          send_frame(6, 2, 1'b1);
          repeat (2) @(negedge clk);
          check("ровно один строб", (strobes - s0) == 1);
          check("строб на НАШЕМ (tag=6), не на SYN", last_strobe_tag == 6);

          // ── 4. ЛОВУШКА: односоловный кадр сразу ПОСЛЕ нашего ────────────
          //
          // marker_seen ещё держит наш маркер. При minWords=1 длина не
          // спасает, и без ветки single_word чужой ACK дал бы ложный строб.
          $display("\n[4] ЛОВУШКА: односоловный ACK после нашего, minWords=1");
          min_words = 32'd1;
          s0 = strobes;
          send_frame(7, 2, 1'b1);   // наш
          send_frame(8, 1, 1'b0);   // ACK, БЕЗ маркера
          repeat (2) @(negedge clk);
          check("ровно один строб", (strobes - s0) == 1);
          check("строб на НАШЕМ (tag=7), ACK не просочился",
                last_strobe_tag == 7);

          // ── 5. то же при minWords=0 ──────────────────────────────────────
          $display("\n[5] то же при minWords=0 (длина выключена совсем)");
          min_words = 32'd0;
          s0 = strobes;
          send_frame(9, 2, 1'b1);
          send_frame(10, 1, 1'b0);
          send_frame(11, 1, 1'b0);
          repeat (2) @(negedge clk);
          check("ровно один строб", (strobes - s0) == 1);
          check("строб на НАШЕМ (tag=9)", last_strobe_tag == 9);

          // ── 6. свип по размерам ──────────────────────────────────────────
          $display("\n[6] свип: minWords по формуле, наш кадр всегда ловится");
          // msgBytes 32,64->2  128->3  256->5  512->9  1024->17  1500->25
          min_words = 32'd2;  s0 = strobes; send_frame(20, 2,  1'b1);
          repeat (2) @(negedge clk); check("msg<=64  (2 слова)",  (strobes-s0)==1);
          min_words = 32'd3;  s0 = strobes; send_frame(21, 3,  1'b1);
          repeat (2) @(negedge clk); check("msg=128  (3 слова)",  (strobes-s0)==1);
          min_words = 32'd5;  s0 = strobes; send_frame(22, 5,  1'b1);
          repeat (2) @(negedge clk); check("msg=256  (5 слов)",   (strobes-s0)==1);
          min_words = 32'd9;  s0 = strobes; send_frame(23, 9,  1'b1);
          repeat (2) @(negedge clk); check("msg=512  (9 слов)",   (strobes-s0)==1);
          min_words = 32'd17; s0 = strobes; send_frame(24, 17, 1'b1);
          repeat (2) @(negedge clk); check("msg=1024 (17 слов)",  (strobes-s0)==1);
          min_words = 32'd25; s0 = strobes; send_frame(25, 25, 1'b1);
          repeat (2) @(negedge clk); check("msg=1500 (25 слов)",  (strobes-s0)==1);

          // ── 7. порог завышен: режет ВСЁ, включая наш кадр ────────────────
          $display("\n[7] minWords завышен -- фильтр режет всё");
          min_words = 32'd25;
          s0 = strobes; d0 = count_drop;
          send_frame(30, 2, 1'b1);   // наш, но всего 2 слова
          repeat (2) @(negedge clk);
          check("строба нет", (strobes - s0) == 0);
          check("ушёл в drop (это и видно как passed=0 при растущем dropped)",
                count_drop == d0 + 1);

          // ── 8. backpressure и паузы ──────────────────────────────────────
          //
          // ГЛАВНОЕ, ЧЕГО НЕ ВИДИТ ПИТОНОВСКАЯ МОДЕЛЬ: там beat подаётся
          // вызовом функции, а здесь tready реально снимается. Если бы в .v
          // tready забыли в условии beat, счёт слов уехал бы именно тут.
          $display("\n[8] паузы и backpressure не ломают счёт слов");
          min_words = 32'd3;
          s0 = strobes;
          send_frame_stalled(40, 3, 1'b1);
          repeat (2) @(negedge clk);
          check("наш 3-словный кадр опознан несмотря на паузы",
                (strobes - s0) == 1);
          check("строб на нём (tag=40)", last_strobe_tag == 40);

          // ── 9. сброс обнуляет счётчики ───────────────────────────────────
          $display("\n[9] сброс обнуляет счётчики");
          @(negedge clk); rst_n = 1'b0;
          repeat (3) @(negedge clk); rst_n = 1'b1;
          @(negedge clk);
          check("count_ours=0 после сброса", count_ours == 0);
          check("count_drop=0 после сброса", count_drop == 0);
          // и логика жива после сброса
          min_words = 32'd2; s0 = strobes;
          send_frame(50, 2, 1'b1);
          repeat (2) @(negedge clk);
          check("после сброса фильтр работает", (strobes - s0) == 1);

          $display("");
          if (errors == 0) $display("=== tb_net_frame_filter: ВСЁ ЗЕЛЁНОЕ ===");
          else             $display("=== tb_net_frame_filter: ОТКАЗОВ %0d ===", errors);
          $finish;
     end

     // Страховка от зависания: если тестбенч не дойдёт до $finish, симуляция
     // не будет крутиться вечно на сборочной машине.
     initial begin
          #500000;
          $display("*** TIMEOUT: тестбенч не завершился");
          $finish;
     end

endmodule

`default_nettype wire
