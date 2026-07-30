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

set KRNL      "hls_ouch_krnl"
set PART      "xcu200-fsgd2104-2-e"

# 200 МГц — ровно то, с чем ядро собиралось в Vitis-флоу
# (Makefile: CLFLAGS += --kernel_frequency 200). Держим ту же частоту, чтобы
# результат синтеза был сопоставим с рабочей сборкой; clk_wiz в build_bd.tcl
# настроен на неё же.
set PERIOD_NS 5.0

set REPO_ROOT [file normalize [file dirname [info script]]/../..]
set SRC_DIR   "$REPO_ROOT/kernel/user_krnl/$KRNL/src/hls"
set PROJ_DIR  "$REPO_ROOT/build_hls"

open_project -reset "$PROJ_DIR/$KRNL"
set_top $KRNL

# Единственный внешний заголовок ядра — communication.hpp, и он подключается
# относительным путём от самого .cpp ("../../../../common/include/..."), так что
# -I не нужен: v++ в Vitis-флоу тоже собирал это ядро без -I (см. config_hls.mk).
#
# Файлы добавляем по абсолютному пути. Относительный путь HLS резолвит от
# каталога решения, а не от cwd, и файл "теряется": сначала
# "Cannot find source file ../kernel/...", потом "Cannot find any design unit
# to elaborate" — именно на этом упал первый прогон.
foreach f [glob -nocomplain "$SRC_DIR/*.cpp"] {
     # Тестбенч в синтез не идёт — он живёт в tb/ и собирается нативно
     # (см. run_csim.tcl и ap_int/hls_stream шим).
     if {[string match "*/tb/*" $f]} { continue }
     set f [file normalize $f]
     puts "add_files: $f"
     add_files $f
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

puts ""
puts "=========================================================="
puts "IP: $PROJ_DIR/$KRNL/sol1/impl/ip"
puts ""
puts "ТЕПЕРЬ обязательно перенеси смещения регистров в jtag_ctrl.tcl."
puts "Они здесь:"
puts "  grep -E 'ADDR_(LISTENPORT|ENABLE|RXBYTE|RXPACKET)' \\"
puts "    $PROJ_DIR/$KRNL/sol1/impl/ip/drivers/*/src/*_hw.h"
puts "=========================================================="

exit
