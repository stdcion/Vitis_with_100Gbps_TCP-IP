# C-симуляция и синтез hls_pp_dual_krnl
#
# Запуск (из этого каталога):
#     vitis_hls -f run_csim.tcl
#
# Без Vitis HLS -- через шим, см. kernel/common/csim_shim/README.md:
#     SHIM=$PWD/kernel/common/csim_shim
#     g++ -std=c++14 -I$SHIM -o /tmp/tb hls_pp_dual_krnl.cpp \
#         tb/test_hls_pp_dual_krnl.cpp && /tmp/tb
# (нужно зеркало дерева -- ядро включает communication.hpp на четыре
#  уровня вверх; готовые команды в README шима)
#
# ЧТО ЗДЕСЬ НЕОБЫЧНО: set_top -- ТОП-ФУНКЦИЯ, А ТЕСТБЕНЧ ВЫЗЫВАЕТ СТАДИИ.
#
# csim обычно дёргает то, что стоит в set_top. Здесь не так, и намеренно:
#
#   csim    вызывает pp_listen и pp_echo напрямую -- потому что топ-функция
#           в csim НЕ ВОЗВРАЩАЕТСЯ. На половине b она вызывает апстримные
#           listenPorts и recvData, а у обеих внутри цикл, не завершающийся
#           без данных (communication.hpp:746 и :1239). На плате это верно
#           -- стадии независимое железо; в csim это зависание, и подложить
#           данные между тактами нельзя, потому что такта не будет.
#
#   csynth  синтезирует ТОП-функцию целиком, включая половину b. Именно
#           здесь проверяется, что DATAFLOW-регион из 8 стадий собирается,
#           что static в pp_echo не даёт HLS 200-471, и какой выходит II.
#
# То есть два шага проверяют разное и оба нужны. Логика -- csim, форма
# региона -- csynth.
#
# ГРАНИЦЫ. csim НЕ проверяет: что половина b не мешает эху, что скаляры
# доезжают через s_axilite, что регион живёт под ap_ctrl_hs. Первое -- за
# cosim или платой, остальное только плата.
#
# ПРО ПЕРИОД. 4 нс (250 МГц) -- частота, на которую рассчитан стек по
# README. Фактическая сборка идёт на 200 МГц, то есть csynth здесь строже
# на 25%: осознанный запас перед разводкой. Для оценки ровно под сборку --
# -period 5.

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset pp_dual_csim_proj
set_top hls_pp_dual_krnl

add_files hls_pp_dual_krnl.cpp -cflags $CFLAGS
add_files -tb tb/test_hls_pp_dual_krnl.cpp -cflags $CFLAGS

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 4 -name default

puts "=========== C SIMULATION ==========="
csim_design

puts "=========== C SYNTHESIS ==========="
csynth_design

# --- Co-simulation ---
#
# Выключена по умолчанию, и вот почему -- проверено на родственных ядрах:
#
#   1) Скалярные порты при ap_ctrl_none несовместимы с cosim
#      ([COSIM] found non-self-synchronizing top I/O). У нас ap_ctrl_hs и
#      s_axilite, так что этот пункт может и не сработать -- но:
#
#   2) У hls_gateway_krnl cosim ЗАВИС на 212-й транзакции из 1501:
#      тестбенч вызывает функцию в цикле по такту, а cosim трактует каждый
#      вызов как отдельную транзакцию со своим протоколом старта. Детектор
#      дедлока не срабатывал, расхождений C/RTL не было -- ограничение
#      методики, не дефект ядра.
#
#   3) Здесь добавляется третье: тестбенч вызывает СТАДИИ, а не топ. Для
#      cosim это значит, что проверяться будет RTL стадий по отдельности,
#      без региона -- то есть не то, что идёт в железо.
#
# Включить всё равно можно:
#     vitis_hls -f run_csim.tcl -tclargs cosim
# Под timeout, иначе снимать процесс вручную.
set do_cosim 0
foreach a $argv { if {$a eq "cosim"} { set do_cosim 1 } }

if {$do_cosim} {
    puts "=========== CO-SIMULATION ==========="
    cosim_design -trace_level none
} else {
    puts "=========== CO-SIMULATION SKIPPED (-tclargs cosim to enable) ==========="
}

exit
