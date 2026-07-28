# C-симуляция и синтез hls_gateway_krnl
#
# Запуск (из этого каталога):
#     vitis_hls -f run_csim.tcl
#
# Скрипт делает две вещи:
#   1. csim   — проверяет логику релея на модели TCP-стека
#   2. csynth — проверяет, что ядро вообще синтезируется
#              (прагмы, отсутствие конфликтов доступа к потокам)
#
# Синтез здесь занимает минуты, в отличие от полной сборки
# TARGET=hw, которая идёт часами.
#
# ВАЖНО: csim и csynth собирают ОДИН И ТОТ ЖЕ код — никаких -D,
# меняющих поведение ядра. Пауза реконнекта передаётся аргументом
# reconnectDelay через AXI-lite, поэтому тестбенч просто подставляет
# малое значение, а в железо идёт ровно то, что протестировано.
# (Раньше csim шла с -DGW_RECONNECT_DELAY=100, синтез — без него,
# а проверка реконнекта вообще была под #ifdef GW_FAST_RECONNECT.)

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset gateway_csim_proj
set_top hls_gateway_krnl

add_files hls_gateway_krnl.cpp -cflags $CFLAGS
add_files -tb test_hls_gateway_krnl.cpp -cflags $CFLAGS

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

puts "=========== C SIMULATION ==========="
csim_design

puts "=========== C SYNTHESIS ==========="
csynth_design

# --- Co-simulation ---
# ЕДИНСТВЕННЫЙ способ проверить поведение при заполнении FIFO:
# в csim hls::stream неограничен, поэтому проверки full() и
# устойчивость к backpressure там не проявляются вообще.
# Здесь глубины из прагм STREAM реальны, и дедлок (если он есть)
# проявится как зависание или таймаут.
#
# ВНИМАНИЕ: ядро объявлено с ap_ctrl_none и не завершается, поэтому
# cosim не остановится сам — тестбенч вызывает ядро в цикле, а RTL
# работает вечно. Ожидайте либо таймаут, либо ручного прерывания;
# осмысленный результат здесь — ЗАВИСАНИЕ как признак дедлока против
# нормального протекания данных в логе.
#
# Поэтому шаг ВЫКЛЮЧЕН по умолчанию. Включить:
#     vitis_hls -f run_csim.tcl -tclargs cosim
set do_cosim 0
foreach a $argv { if {$a eq "cosim"} { set do_cosim 1 } }

if {$do_cosim} {
    puts "=========== CO-SIMULATION ==========="
    cosim_design -trace_level none
} else {
    puts "=========== CO-SIMULATION SKIPPED (-tclargs cosim to enable) ==========="
}

exit
