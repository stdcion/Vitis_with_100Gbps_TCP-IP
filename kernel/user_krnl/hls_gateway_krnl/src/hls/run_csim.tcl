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
add_files -tb tb/test_hls_gateway_krnl.cpp -cflags $CFLAGS

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
# --- Co-simulation ---
#
# Cosim НЕ работает на основном top'е: у hls_gateway_krnl есть
# скалярные AXI-lite порты, а cosim их не поддерживает при ap_ctrl_none:
#   [COSIM] found non-self-synchronizing top I/O listenPort
#   [COSIM 212-345] Cosim only supports the following 'ap_ctrl_none'
#   designs: ... (3) designs with array streaming or hls_stream or
#   AXI4 stream ports
#
# Поэтому cosim гоняется на отдельном top'е hls_gateway_krnl_cosim —
# та же логика (общий gw_core), но параметры зашиты константами, так
# что все порты потоковые. Проверяем именно то, что csim проверить не
# может принципиально: достаточность глубин FIFO и отсутствие дедлока
# при ap_ctrl_none + auto-rewind (UG1448, "Data FIFO Sizing", 200-656).
#
# Выключено по умолчанию, включить:
#     vitis_hls -f run_csim.tcl -tclargs cosim
set do_cosim 0
foreach a $argv { if {$a eq "cosim"} { set do_cosim 1 } }

if {$do_cosim} {
    puts "=========== CO-SIMULATION (wrapper top) ==========="
    close_project

    open_project -reset gateway_cosim_proj
    set_top hls_gateway_krnl_cosim

    set COSIM_FLAGS "$CFLAGS -DGW_COSIM_TOP"
    add_files hls_gateway_krnl.cpp -cflags $COSIM_FLAGS
    add_files -tb tb/test_hls_gateway_krnl.cpp -cflags $COSIM_FLAGS

    open_solution -reset "solution1" -flow_target vitis
    set_part {xcu200-fsgd2104-2-e}
    create_clock -period 4 -name default

    csynth_design
    cosim_design -trace_level none
} else {
    puts "=========== CO-SIMULATION SKIPPED (-tclargs cosim to enable) ==========="
}

exit
