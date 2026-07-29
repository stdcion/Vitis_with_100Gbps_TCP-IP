# C-симуляция и синтез hls_pingpong_krnl
#
# Запуск (из этого каталога):
#     vitis_hls -f run_csim.tcl
#
# Делает две вещи:
#   1. csim   — проверяет логику эха на модели TCP-стека
#   2. csynth — проверяет синтезируемость, II и тайминг
#
# csim и csynth собирают ОДИН И ТОТ ЖЕ код: никаких -D, меняющих
# поведение ядра, чтобы в железо шло ровно то, что протестировано.
#
# ПРО ПЕРИОД ТАКТА. Здесь 4 нс (250 МГц) — это частота, на которую
# рассчитан стек по README ("network kernel ... clocked at 250 MHz",
# 512 бит x 250 МГц = 128 Гбит/с, чтобы насытить 100G). При этом
# фактическая сборка идёт на 200 МГц (Makefile: --kernel_frequency 200).
# То есть csynth здесь строже реальной сборки на 25% — это осознанный
# запас перед разводкой в Vivado. Если нужна оценка ровно под текущую
# сборку, поставьте -period 5.

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset pingpong_csim_proj
set_top hls_pingpong_krnl

add_files hls_pingpong_krnl.cpp -cflags $CFLAGS
add_files -tb tb/test_hls_pingpong_krnl.cpp -cflags $CFLAGS

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

puts "=========== C SIMULATION ==========="
csim_design

puts "=========== C SYNTHESIS ==========="
csynth_design

# --- Co-simulation ---
#
# ВНИМАНИЕ: для этого ядра cosim, скорее всего, НЕ пройдёт, и это
# проверено на родственном hls_gateway_krnl:
#
#   1) Скалярный порт listenPort (s_axilite) несовместим с cosim при
#      ap_ctrl_none:
#        [COSIM] found non-self-synchronizing top I/O listenPort
#        [COSIM 212-345] Cosim only supports ... (3) designs with array
#        streaming or hls_stream or AXI4 stream ports
#      Обходится обёрткой без скалярных портов (как gw_core в gateway).
#
#   2) Даже с обёрткой cosim у gateway ЗАВИС на 212-й транзакции из
#      1501: тестбенч вызывает top в цикле по такту, а cosim трактует
#      каждый вызов как отдельную транзакцию со своим протоколом
#      старта/завершения, которого у ap_ctrl_none-дизайна нет.
#      Детектор дедлока при этом НЕ срабатывал, расхождений C/RTL не
#      было — то есть это ограничение методики, а не дефект ядра.
#
# Поэтому шаг выключен по умолчанию. Включить:
#     vitis_hls -f run_csim.tcl -tclargs cosim
# Запускайте под timeout, иначе придётся снимать процесс вручную:
#     timeout 300 vitis_hls -f run_csim.tcl -tclargs cosim
set do_cosim 0
foreach a $argv { if {$a eq "cosim"} { set do_cosim 1 } }

if {$do_cosim} {
    puts "=========== CO-SIMULATION ==========="
    cosim_design -trace_level none
} else {
    puts "=========== CO-SIMULATION SKIPPED (-tclargs cosim to enable) ==========="
}

exit
