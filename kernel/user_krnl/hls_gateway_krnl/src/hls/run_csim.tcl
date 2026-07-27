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

open_project -reset gateway_csim_proj
set_top hls_gateway_krnl

# GW_RECONNECT_DELAY укорачивает паузу переподключения, иначе
# симуляция ждала бы 250e6 тактов. Define нужен И ядру, И тестбенчу.
# GW_FAST_RECONNECT включает в тестбенче саму проверку переподключения.
#
# ВНИМАНИЕ: укороченная задержка — только для csim. Для реального
# синтеза используйте отдельный запуск без этих -D (см. хвост файла).
set SIM_FLAGS "-std=c++14 -I../../../../common/include -DGW_RECONNECT_DELAY=100"

add_files hls_gateway_krnl.cpp -cflags $SIM_FLAGS
add_files -tb test_hls_gateway_krnl.cpp -cflags "$SIM_FLAGS -DGW_FAST_RECONNECT"

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

puts "=========== C SIMULATION ==========="
csim_design

close_project

# --- Синтез: отдельный проект, БЕЗ укороченной задержки ---
# Проверяет прагмы и отсутствие конфликтов доступа к потокам
# на том коде, который реально пойдёт в железо.

puts "=========== C SYNTHESIS ==========="

open_project -reset gateway_synth_proj
set_top hls_gateway_krnl
add_files hls_gateway_krnl.cpp -cflags "-std=c++14 -I../../../../common/include"

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

csynth_design

exit
