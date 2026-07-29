# C-симуляция и синтез hls_ouch_krnl
#
# Запуск (ИЗ ЭТОГО КАТАЛОГА — пути внутри относительные):
#     vitis_hls -f run_csim.tcl
#
# Делает две вещи:
#   1. csim   — проверяет логику
#   2. csynth — проверяет, что ядро синтезируется (прагмы, отсутствие
#              конфликтов доступа к потокам) и укладывается в тайминг
#
# Синтез здесь занимает секунды, в отличие от полной сборки TARGET=hw.
#
# csim и csynth собирают ОДИН И ТОТ ЖЕ код — никаких -D, меняющих
# поведение ядра. Параметры приходят аргументами через AXI-lite, поэтому
# тестбенч просто подставляет нужные значения.

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset ouch_csim_proj
set_top hls_ouch_krnl

add_files hls_ouch_krnl.cpp -cflags $CFLAGS
add_files -tb tb/test_hls_ouch_krnl.cpp -cflags $CFLAGS

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

# Ниже каждый шаг обёрнут в catch и завершает скрипт с кодом 1 при
# ошибке. Без этого vitis_hls возвращает 0 почти всегда, и
#     vitis_hls -f run_csim.tcl && echo OK
# печатало бы OK даже при упавших тестах — то есть в CI (или просто в
# наспех набранной команде) провал остался бы незамеченным.
#
# csim_design бросает ошибку Tcl, если main() тестбенча вернул не ноль.
# Именно поэтому тестбенч возвращает число ошибок, а не всегда 0.

puts "=========== C SIMULATION ==========="
if {[catch {csim_design} err]} {
     puts "*** CSIM FAILED: $err"
     exit 1
}

puts "=========== C SYNTHESIS ==========="
if {[catch {csynth_design} err]} {
     puts "*** CSYNTH FAILED: $err"
     exit 1
}

# --- Проверка тайминга ---
#
# csynth_design НЕ считает провал по таймингу ошибкой: он выдаёт
# предупреждение [HLS 200-871] и завершается успешно. То есть ядро,
# которое не влезает в 250 МГц, молча проходит сборку и всплывает уже
# на этапе implementation, часы спустя.
#
# Поэтому достаём достигнутый период из отчёта и сравниваем с целевым.
# Отчёт лежит в <solution>/syn/report/<top>_csynth.rpt; путь берём от
# каталога проекта, чтобы не зависеть от места запуска.
set rpt "ouch_csim_proj/solution1/syn/report/hls_ouch_krnl_csynth.rpt"
if {![file exists $rpt]} {
     puts "*** ОТЧЁТ НЕ НАЙДЕН: $rpt"
     exit 1
}

set fh [open $rpt r]
set rptText [read $fh]
close $fh

# Строка отчёта вида: |ap_clk|4.00 ns|2.717 ns|1.08 ns|
# то есть Clock | Target | Estimated | Uncertainty.
#
# ВАЖНО: сравнивать Estimated надо НЕ с Target, а с (Target -
# Uncertainty). Именно так считает сам HLS:
#   [HLS 200-871] Estimated clock period (3.248 ns) exceeds the target
#   (target clock period: 4.000 ns, clock uncertainty: 1.080 ns,
#    effective delay budget: 2.920 ns)
# 3.248 меньше 4.000, но больше бюджета 2.920 — и это предупреждение.
# Сравнение с Target пропустило бы такой случай.
if {[regexp {\|\s*ap_clk\s*\|\s*([0-9.]+)\s*ns\s*\|\s*([0-9.]+)\s*ns\s*\|\s*([0-9.]+)\s*ns} \
          $rptText -> targetPeriod estimatedPeriod uncertainty]} {
     set budget [expr {$targetPeriod - $uncertainty}]
     puts [format "тайминг: цель %s ns, неопределённость %s ns, бюджет %.3f ns, достигнуто %s ns" \
               $targetPeriod $uncertainty $budget $estimatedPeriod]
     if {$estimatedPeriod > $budget} {
          puts [format "*** ТАЙМИНГ НЕ СОШЁЛСЯ: %s ns > бюджета %.3f ns" \
                    $estimatedPeriod $budget]
          puts "*** ищите 200-871 и 200-1016 выше — там разобран критический путь"
          exit 1
     }
} else {
     # Не смогли разобрать отчёт — это не провал сборки, но и молчать
     # нельзя: проверка тайминга в этом прогоне не выполнена.
     puts "ПРЕДУПРЕЖДЕНИЕ: не удалось разобрать тайминг из отчёта"
}

puts "=========== ВСЁ ПРОШЛО ==========="

# --- Про co-simulation ---
#
# Здесь её НЕТ, и это осознанно. Cosim подаёт входные векторы, ждёт
# ЗАВЕРШЕНИЯ транзакции и сравнивает выходы. Ядро с ap_ctrl_none,
# собранное из бесконечных стадий, не завершается никогда, поэтому
# cosim на нём просто зависает. Vitis предупреждает об этом сам:
#   [HLS 200-656] Deadlocks can occur since process ... is instantiated
#   in a dataflow region with ap_ctrl_none ... and contains an
#   auto-rewind pipeline
# Плюс тестбенч устроен как «вызов ядра на один такт», а в RTL такого
# понятия нет.
#
# ЧТО ЭТО ЗНАЧИТ НА ПРАКТИКЕ: достаточность глубин FIFO и корректность
# проверок full() здесь не проверяются ничем — в csim hls::stream
# неограничен, а прагмы depth игнорируются (UG1448, Data FIFO Sizing).
# Когда между стадиями появятся FIFO, для этого понадобятся
# ограниченные потоки в тестбенче или телеметрия на плате.

exit
