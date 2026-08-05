# -----------------------------------------------------------------------------
# export_hls_ip.tcl — собрать user-ядро в Vivado IP вместо .xo
#
# В Vitis-флоу ядро собирал v++ -c, сразу в .xo (см. config_hls.mk). Для
# Vivado-флоу нужен обычный IP из каталога, поэтому тот же исходник прогоняем
# через vitis_hls с export_design -format ip_catalog.
#
# Исходник, pragma и интерфейсы не меняются — меняется только формат упаковки.
#
# Запуск:
#     vitis_hls -f scripts/vivado/export_hls_ip.tcl
#
# Результат:
#     build_hls/<krnl>/impl/ip           — каталог IP для ip_repo_paths
#     build_hls/<krnl>/impl/ip/drivers/*/src/*_hw.h  — СМЕЩЕНИЯ РЕГИСТРОВ
#
# Второе важнее, чем кажется: смещения s_axilite HLS назначает сам, порядок
# аргументов в C++ их не задаёт. Значения из *_hw.h нужно перенести в
# USR_OFF_* в scripts/vivado/jtag_ctrl.tcl.
# -----------------------------------------------------------------------------

# Имя ядра. Через переменную окружения, иначе hls_ouch_krnl:
#     USER_KRNL=hls_echo_krnl vitis_hls -f scripts/vivado/export_hls_ip.tcl
#
# Не -tclargs: vitis_hls кладёт в $argv ВСЁ, включая "-f" и путь к скрипту,
# поэтому [lindex $argv 0] даёт "-f". (У vivado поведение другое — там
# -tclargs отсекает свои аргументы, и build_bd.tcl читает их напрямую.)
set KRNL [expr {[info exists ::env(USER_KRNL)] ? $::env(USER_KRNL) : "hls_ouch_krnl"}]
puts "ядро: $KRNL"

# Плата — тоже через окружение, по той же причине.
set BOARD [expr {[info exists ::env(BOARD)] ? $::env(BOARD) : "u200"}]

set REPO_ROOT [file normalize [file dirname [info script]]/../..]

# --- параметры платы ----------------------------------------------------------
#
# Part и частота приходят из того же devices/<плата>/device.tcl, который читает
# build_bd.tcl. Раньше период жил здесь отдельным числом (5.88) и мог разойтись
# с CLKOUT1_REQUESTED_OUT_FREQ у clk_wiz — тогда HLS синтезировал бы под одну
# частоту, а дизайн тактировался другой.
#
# Про сами 170 МГц: в Makefile стоит --kernel_frequency 200, но 200 МГц там
# НИКОГДА не достигались — v++ при недоборе сам снижает kernel clock:
#     "timing paths failed targeting 200 MHz ... frequency is being
#      automatically changed to 192.9 MHz"
# то есть рабочая XRT-сборка шла на 192.9 МГц.
#
# Vivado так не делает: он оставляет отрицательный WNS и выдаёт битстрим с
# нарушенным таймингом — а такой битстрим грузится и работает НЕСТАБИЛЬНО
# (случайная порча пакетов, залипания стека). Поэтому в device.tcl должна стоять
# заведомо достижимая частота.
#
# Оценка достижимого: на 5 нс получили WNS=-0.616, значит реальный предел
# около 5.62 нс (~178 МГц). Критический путь — finalize_ipv4_checksum_32 внутри
# network_krnl, HLS-логика стека. На 170 МГц достигнуто WNS=+0.123.
# (192.9 МГц у v++ достигались, вероятно, за счёт floorplanning шелла, которого
# в этом флоу нет.)
set DEVICE_TCL "$REPO_ROOT/build/devices/$BOARD/device.tcl"
if {![file exists $DEVICE_TCL]} {
     puts "*** нет $DEVICE_TCL"
     puts "    Его генерирует cmake:"
     puts "        cd build && cmake .. -DFDEV_NAME=$BOARD -DTCP_STACK_EN=1"
     exit 1
}
source $DEVICE_TCL

set PART      $DEV_PART
set PERIOD_NS $DEV_PERIOD_NS
puts "плата: $BOARD ($PART), период $PERIOD_NS нс ($DEV_FREQ_MHZ МГц)"

set SRC_DIR   "$REPO_ROOT/kernel/user_krnl/$KRNL/src/hls"

# Проект создаём В каталоге исходников и оттуда же работаем — ровно как рабочий
# run_csim.tcl.
#
# Это не косметика. HLS резолвит пути файлов относительно каталога ПРОЕКТА, а не
# cwd. Проект в build_hls/ + файл hls_ouch_krnl.cpp давали
# build_hls/hls_ouch_krnl/../kernel/... — мимо, отсюда "Cannot find source file"
# и следом "Cannot find any design unit to elaborate". Абсолютный путь в
# add_files это тоже не лечит: HLS всё равно приводит его к относительному.
set PROJ_NAME "${KRNL}_ip_proj"

cd $SRC_DIR

open_project -reset $PROJ_NAME
set_top $KRNL

# Те же cflags, что в run_csim.tcl: communication.hpp лежит вне каталога ядра.
# (В самом .cpp include записан относительным путём, но HLS ищет его от
# каталога компиляции, поэтому -I всё равно нужен.)
set CFLAGS "-std=c++14 -I../../../../common/include"

# Тестбенч в синтез не идёт — он в tb/ и собирается нативно (см. run_csim.tcl
# и ap_int/hls_stream шим).
foreach f [glob -nocomplain "*.cpp"] {
     puts "add_files: $f"
     add_files $f -cflags $CFLAGS
}

open_solution -reset "sol1" -flow_target vivado
set_part $PART
create_clock -period $PERIOD_NS -name default

# Vitis-режим интерфейсов: нужен, чтобы hls::stream отображались в AXI-Stream,
# а s_axilite-аргументы — в control-регистры, как это делал v++.
config_interface -m_axi_addr64

csynth_design

# ip_catalog вместо .xo — это и есть вся разница с Vitis-флоу.
export_design -format ip_catalog -rtl verilog \
     -display_name "$KRNL" \
     -description "OUCH gateway kernel (Vivado flow, no XRT)" \
     -vendor "user" -library "kernel" -version "1.0"

set IP_DIR "$SRC_DIR/$PROJ_NAME/sol1/impl/ip"

if {![file isdirectory $IP_DIR]} {
     puts "*** export_design не создал каталог IP: $IP_DIR"
     exit 1
}

puts ""
puts "=========================================================="
puts "IP готов: $IP_DIR"
puts ""

# Смещения регистров печатаем сразу: их всё равно нужно перенести в
# jtag_ctrl.tcl (USR_OFF_*), а искать их потом по дереву проекта неудобно.
# HLS назначает их сам, порядок аргументов в C++ адреса НЕ задаёт — поэтому
# значения в jtag_ctrl.tcl без этой сверки остаются догадкой.
set hw_headers [glob -nocomplain "$IP_DIR/drivers/*/src/*_hw.h"]
if {[llength $hw_headers] == 0} {
     puts "ПРЕДУПРЕЖДЕНИЕ: не найден *_hw.h — смещения регистров придётся искать вручную в"
     puts "  $IP_DIR/hdl/verilog/*_control_s_axi.v"
} else {
     set hdr [lindex $hw_headers 0]
     puts "СМЕЩЕНИЯ РЕГИСТРОВ (перенести в USR_OFF_* в scripts/vivado/jtag_ctrl.tcl):"
     puts "  источник: $hdr"
     puts ""
     set fh [open $hdr r]
     foreach line [split [read $fh] "\n"] {
          if {[regexp -nocase {(listenport|enable|rxbyte|rxpacket|ap_ctrl)} $line]} {
               puts "  [string trim $line]"
          }
     }
     close $fh
}
puts "=========================================================="

exit
