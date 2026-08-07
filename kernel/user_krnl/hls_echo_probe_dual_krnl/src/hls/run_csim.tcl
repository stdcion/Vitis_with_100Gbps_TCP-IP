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
# ПРО ПЕРИОД ТАКТА. 5.882 нс = 170 МГц — ровно та частота, на которой
# идёт сборка (DEV_FREQ_MHZ в devices/u200/device.tcl). В отличие от
# hls_pingpong_krnl, где стоит 4 нс «с запасом», здесь берём фактическую:
# у dual-дизайна WNS всего +0.011 нс, и знать реальный запас важнее, чем
# иметь абстрактную страховку.

set CFLAGS "-std=c++14 -I../../../../common/include"

open_project -reset epd_csim_proj
set_top hls_echo_probe_dual_krnl

add_files hls_echo_probe_dual_krnl.cpp -cflags $CFLAGS
add_files -tb tb/test_hls_echo_probe_dual_krnl.cpp -cflags $CFLAGS

open_solution -reset "solution1" -flow_target vitis
set_part {xcu200-fsgd2104-2-e}
create_clock -period 5.882 -name default

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
#      ([COSIM 212-345]); у нас таких портов десяток;
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

# Смещения регистров s_axi_control нужны для jtag_ctrl.tcl. HLS кладёт их
# в заголовок драйвера — печатаем путь, чтобы не искать вручную.
set hdr [glob -nocomplain epd_csim_proj/solution1/impl/ip/drivers/*/src/*_hw.h]
puts ""
puts "=========== СМЕЩЕНИЯ РЕГИСТРОВ ==========="
if {[llength $hdr] > 0} {
    puts "Файл: [lindex $hdr 0]"
    puts "Сверить с EPD_OFF_* в scripts/vivado/jtag_ctrl.tcl:"
    set fh [open [lindex $hdr 0] r]
    foreach line [split [read $fh] "\n"] {
        if {[string match "*_ADDR_*" $line]} { puts "  $line" }
    }
    close $fh
} else {
    puts "Заголовок драйвера не найден — он появляется после export_design."
    puts "Смещения можно взять из scripts/vivado/export_hls_ip.tcl."
}

exit
