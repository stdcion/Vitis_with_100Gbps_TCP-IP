# C-симуляция и синтез hls_echo_probe_dual_krnl
#
# Запуск (из этого каталога, на машине с Vitis HLS):
#     vitis_hls -f run_csim.tcl
#
# Делает две вещи, и вторая важнее первой:
#
#   1. csim   — проверяет ЛОГИКУ на модели двух стеков, соединённых
#               кабелем: круг замыкается, таймстемпы соответствуют
#               заданным задержкам, баланс участков сходится.
#
#   2. csynth — проверяет СИНТЕЗИРУЕМОСТЬ, II и тайминг. Это то, чего
#               csim принципиально не видит. Здесь же выяснится, не
#               разъехались ли стадии DATAFLOW: если между ними
#               остался скаляр по ссылке, csynth скажет об этом, а
#               csim молча отработает (там обычный C++).
#
# csim и csynth собирают ОДИН И ТОТ ЖЕ код — никаких -D, меняющих
# поведение ядра, чтобы в железо шло ровно то, что протестировано.
#
# ПРО ПЕРИОД ТАКТА. 6.061 нс = 165 МГц — ровно та частота, на которой идёт
# сборка (DEV_FREQ_MHZ в devices/u200/device.tcl.in). В отличие от
# hls_pingpong_krnl, где стоит 4 нс «с запасом», здесь берём фактическую:
# у dual-дизайна запас по WNS крошечный, и знать реальный запас важнее, чем
# иметь абстрактную страховку.
#
# БЫЛО 5.882 (170 МГц) — устарело. Частоту снизили до 165 МГц 11.08.2026, когда
# тайминг перестал закрываться, но здесь это не поправили, и csynth оценивал
# запас по НЕВЕРНОМУ периоду — жёстче реального, то есть пугал зря. Если менять
# частоту снова, править надо ЧЕТЫРЕ места:
#     devices/u200/device.tcl.in   DEV_FREQ_MHZ   — источник истины для сборки
#     scripts/vivado/jtag_ctrl.tcl EPD_CLK_NS     — перевод тактов в нс на хосте
#     docs/latency_experiment_windows.md          — число в «Схеме эксперимента»
#     этот файл                    create_clock   — оценка запаса в csynth

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset epd_csim_proj
set_top hls_echo_probe_dual_krnl

add_files hls_echo_probe_dual_krnl.cpp -cflags $CFLAGS
add_files -tb tb/test_hls_echo_probe_dual_krnl.cpp -cflags $CFLAGS

# flow_target vivado, А НЕ vitis — И ЭТО ВАЖНО.
#
# При -flow_target vitis HLS принудительно навешивает s_axilite на ВСЕ скаляры:
# для Vitis-потока ядро обязано иметь control-интерфейс под XRT. В логе это
# видно как
#     INFO: [HLS 200-777] Using interface defaults for 'Vitis' flow target.
#     Setting interface mode on port '.../enable' to 's_axilite & ap_none'
#     Bundling port 'serverIp', ... and 'cycleCount' to AXI-Lite port control.
# То есть ровно та конструкция, которую UG1393 запрещает при ap_ctrl_none и
# которая молча защёлкивает скаляры один раз после сброса. Наш
# #pragma HLS INTERFACE ap_none register при этом не отвергается — он даёт
# ap_none второй половиной режима, но бандл остаётся.
#
# Сборочный путь (scripts/vivado/export_hls_ip.tcl) использует
# -flow_target vivado и даёт чистый ap_none — это видно в 1208_full.txt для
# hls_dual_echo_krnl. Здесь берём тот же target, чтобы этот скрипт проверял ТО
# ЖЕ, что попадёт в железо. Иначе он показывает интерфейс, которого в сборке не
# будет, и пункт 1 проверок ниже не выполнялся бы никогда.
#
# Остальные run_csim.tcl репозитория стоят на vitis — для проверки одной логики
# это безвредно, но выводу про форму интерфейса там верить нельзя.
open_solution -reset "solution1" -flow_target vivado
set_part {xcu200-fsgd2104-2-e}
create_clock -period 6.061 -name default

puts "=========== C SIMULATION ==========="
csim_design

puts "=========== C SYNTHESIS ==========="
csynth_design

# --- Co-simulation ---
#
# По умолчанию ВЫКЛЮЧЕНО, и это не лень: на родственных ядрах этого
# репозитория cosim не проходит по двум причинам, обе зафиксированы в
# run_csim.tcl для hls_pingpong_krnl:
#
#   1) скалярные порты s_axilite несовместимы с cosim при ap_ctrl_none
#      ([COSIM 212-345]). У нас таких портов БОЛЬШЕ НЕТ — все 18 s_axilite
#      убраны, регистры держит HDL-обёртка — так что эта причина снята.
#      Остаётся вторая, и её достаточно;
#   2) даже с обёрткой без скаляров cosim у hls_gateway_krnl ЗАВИС на
#      212-й транзакции из 1501 — тестбенч вызывает top в цикле по
#      такту, а cosim трактует каждый вызов как отдельную транзакцию со
#      своим протоколом старта, которого у ap_ctrl_none-дизайна нет.
#      Расхождений C/RTL при этом не было — то есть ограничение
#      методики, а не дефект ядра.
#
# Включить (только если понадобится проверить дедлок по FIFO, чего csim
# не умеет), обязательно под timeout:
#     timeout 600 vitis_hls -f run_csim.tcl -tclargs cosim
set do_cosim 0
foreach a $argv { if {$a eq "cosim"} { set do_cosim 1 } }

if {$do_cosim} {
    puts "=========== CO-SIMULATION ==========="
    cosim_design -trace_level none
} else {
    puts "=========== CO-SIMULATION SKIPPED (-tclargs cosim to enable) ==========="
}

# ЧТО ПРОВЕРИТЬ ПОСЛЕ ЭТОГО ПРОГОНА.
#
# Раньше здесь печатались смещения регистров из сгенерированного драйверного
# заголовка *_hw.h. Этого файла БОЛЬШЕ НЕ БУДЕТ: s_axilite убраны, регистры
# держит HDL-обёртка, а адресная карта задана руками в
# src/hdl/probe_control_s_axi.v и уже сверена с EPD_OFF_* в jtag_ctrl.tcl.
# Блок заменён на проверки, которые теперь действительно нужны.
puts ""
puts "=========== ЧТО ПРОВЕРИТЬ В ВЫВОДЕ ВЫШЕ ==========="
puts ""
puts "1. ФОРМА СКАЛЯРОВ. Ждём у enable/serverIp/serverPort/listenPort/"
puts "   msgBytes/triggerGo/cycleCount:"
puts "       Setting interface mode on port '.../<имя>' to 'ap_none'"
puts "   и у функции:"
puts "       Setting interface mode on function '...' to 'ap_ctrl_none'"
puts "   Любое упоминание s_axilite у скаляра = защёлка после сброса,"
puts "   ядро не увидит записи по JTAG (UG1393, Free-Running Kernels)."
puts "   Проверить, что target тот же, что в сборке:"
puts "       Using interface defaults for 'Vivado' flow target"
puts "   Если написано 'Vitis' — s_axilite навесится принудительно, и"
puts "   этот прогон покажет НЕ то, что попадёт в железо (см. коммент"
puts "   к open_solution выше)."
puts ""
puts "2. II СТАДИЙ. Ждём 'Final II = 1' у epd_client_traffic и"
puts "   epd_server_echo. II=2 измерение больше НЕ ломает (шкала времени"
puts "   одна, приходит проводом из обёртки), но пропускная способность"
puts "   просядет — стоит знать."
puts ""
puts "3. sampleReady И ТЕНЕВОЙ РЕГИСТР. Единственное значение, которое"
puts "   пишется в ДВУХ ветках epd_latch, поэтому проверять надо отдельно:"
puts "       grep -n \"_preg\" epd_csim_proj/solution1/syn/verilog/*epd_latch*.v"
puts "   (syn/verilog, а не impl/ip — csynth без export_design каталог"
puts "    impl не создаёт)"
puts "   Ждём sampleReady_preg. Если его НЕТ — значение транзиентное, и"
puts "   обёртке нужен латч, иначе epd_measure будет печатать"
puts "   'sample failed' на исправном ядре."
puts ""
puts "4. ЗАПАС ПО ТАЙМИНГУ. Estimated Fmax против 165 МГц (6.061 нс)."
puts "   Это лишь оценка HLS; настоящий WNS даёт только impl."
puts ""

exit
