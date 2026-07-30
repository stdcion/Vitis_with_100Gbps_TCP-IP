# -----------------------------------------------------------------------------
# build_bd.tcl — блок-дизайн для Vivado-флоу (без XRT-шелла)
#
# Заменяет то, что в Vitis делал линковщик v++: инстанцирует ядра, соединяет
# их, добавляет обвязку, которую раньше давал шелл (клоки, сбросы, память,
# GT-порты), и управление через JTAG вместо PCIe/XRT.
#
# Запуск:
#     vivado -mode batch -source scripts/vivado/build_bd.tcl
#
# Что должно быть готово до запуска:
#   1. packaged_kernel_cmac_krnl_hw_*    — IP от make (Vitis-флоу его уже собрал)
#   2. packaged_kernel_network_krnl_hw_* — то же
#   3. IP пользовательского ядра из vitis_hls export_design -format ip_catalog
#      (Vitis-флоу его НЕ создаёт — там v++ -c делает сразу .xo)
#
# ВАЖНО: скрипт доводит дизайн до валидного BD с управлением по JTAG, но
# участки, помеченные TODO, требуют решений, которые нельзя принять, не видя
# поведения железа: параметры CMAC (какой GT-квад, FEC), конфигурация DDR4 и
# распределение по SLR. Они помечены явно, а не оставлены молча.
# -----------------------------------------------------------------------------

set PART        "xcu200-fsgd2104-2-e"
set PROJ_NAME   "ouch_vivado"
set PROJ_DIR    "./build_vivado"
set BD_NAME     "ouch_bd"

# Имя user-ядра. Меняется вместе с USER_KRNL в Makefile.
set USER_KRNL   "hls_ouch_krnl"

set REPO_ROOT   [file normalize [file dirname [info script]]/../..]
set CONFIG_SP   "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/config_sp_$USER_KRNL.txt"
set PINS_XDC    "$REPO_ROOT/scripts/vivado/u200_pins.xdc"

source "$REPO_ROOT/scripts/vivado/gen_axis_connect.tcl"

# --- проект -------------------------------------------------------------------

create_project $PROJ_NAME $PROJ_DIR -part $PART -force

# Каталоги с IP: и packaged_kernel_* от make, и ip_repo, и то, что положил HLS.
set ip_repos {}
foreach d [glob -nocomplain "$REPO_ROOT/packaged_kernel_*"] {
     lappend ip_repos $d
}
foreach d [glob -nocomplain "$REPO_ROOT/build/ip_repo"] {
     lappend ip_repos $d
}
# IP пользовательского ядра от export_hls_ip.tcl.
foreach d [glob -nocomplain "$REPO_ROOT/build_hls/$USER_KRNL/*/impl/ip"] {
     lappend ip_repos $d
}

if {[llength $ip_repos] == 0} {
     error "Не найдено ни одного каталога с IP. Сначала собери ядра (см. заголовок)."
}

puts "IP repos:"
foreach d $ip_repos { puts "  $d" }

set_property ip_repo_paths $ip_repos [current_project]
update_ip_catalog -rebuild

# --- BD -----------------------------------------------------------------------

create_bd_design $BD_NAME

# Разрешаем VLNV явно: create_bd_cell без него выдаёт лишь "Please specify
# VLNV", по которому не понять, какого именно IP не хватает.
proc _find_ipdef {name args} {
     # Фактические VLNV в этом репозитории (проверено на component.xml):
     #   xilinx.com:RTLKernel:cmac_krnl:1.0
     #   xilinx.com:RTLKernel:network_krnl:1.0
     # HLS-ядра при упаковке через package_*.tcl получают родовое имя
     # "user_krnl", а не имя ядра — поэтому принимаем список альтернатив.
     set candidates [concat [list $name] $args]

     foreach cand $candidates {
          set hits [get_ipdefs -all -filter "NAME == $cand"]
          if {[llength $hits] == 0} {
               set hits [get_ipdefs -all -filter "VLNV =~ *:${cand}:*"]
          }
          if {[llength $hits] > 0} {
               set vlnv [lindex $hits 0]
               puts "  $name -> $vlnv"
               return $vlnv
          }
     }

     puts ""
     puts "Доступные user-IP в каталоге:"
     foreach d [get_ipdefs -all] {
          if {![string match "xilinx.com:ip:*" $d]} { puts "  $d" }
     }
     error "IP '$name' не найден (искал: $candidates). Собран ли он? См. заголовок скрипта."
}

puts ""
puts "=== разрешение VLNV ==="
set VLNV_CMAC [_find_ipdef cmac_krnl]
set VLNV_NET  [_find_ipdef network_krnl]
set VLNV_USER [_find_ipdef $USER_KRNL user_krnl]

# Имена экземпляров ДОЛЖНЫ быть <kernel>_1: под них написан config_sp_*.txt,
# из которого генерируются соединения.
create_bd_cell -type ip -vlnv $VLNV_CMAC cmac_krnl_1
create_bd_cell -type ip -vlnv $VLNV_NET  network_krnl_1
create_bd_cell -type ip -vlnv $VLNV_USER ${USER_KRNL}_1

# --- 18 stream-соединений из config_sp ----------------------------------------
# Это ровно то, что v++ делал по тому же файлу.

puts ""
puts "=== AXI-Stream соединения из [file tail $CONFIG_SP] ==="
axis_connect_from_config $CONFIG_SP

# --- управление: JTAG вместо PCIe/XRT ----------------------------------------
#
# jtag_axi даёт AXI-Lite мастер, доступный из Hardware Manager по тому же
# USB-кабелю, которым грузится битстрим. Никакого PCIe в дизайне нет — значит
# JTAG-прошивка не может уронить хост через исчезновение endpoint'а.

create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0
set_property CONFIG.PROTOCOL {2} [get_bd_cells jtag_axi_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_interconnect
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells ctrl_interconnect]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] \
                    [get_bd_intf_pins ctrl_interconnect/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/M00_AXI] \
                    [get_bd_intf_pins network_krnl_1/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/M01_AXI] \
                    [get_bd_intf_pins ${USER_KRNL}_1/s_axi_control]

# --- клоки и сбросы -----------------------------------------------------------
#
# Шелл давал ap_clk (kernel clock) и free-running clock готовыми. Здесь строим
# сами из 300 МГц входа: 250 МГц для ядер (столько же было в шелле по
# умолчанию) и 100 МГц free-running для CMAC.

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
     CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
     CONFIG.PRIM_IN_FREQ {300.000} \
     CONFIG.CLKOUT1_USED {true} \
     CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {250.000} \
     CONFIG.CLKOUT2_USED {true} \
     CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
     CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_0]

create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 default_300mhz_clk0
set_property CONFIG.FREQ_HZ {300000000} [get_bd_intf_ports default_300mhz_clk0]
connect_bd_intf_net [get_bd_intf_ports default_300mhz_clk0] [get_bd_intf_pins clk_wiz_0/CLK_IN1_D]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_gen
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]   [get_bd_pins rst_gen/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]     [get_bd_pins rst_gen/dcm_locked]

# ap_clk всех ядер + управляющая шина — на 250 МГц.
foreach pin {cmac_krnl_1/ap_clk network_krnl_1/ap_clk jtag_axi_0/aclk
             ctrl_interconnect/aclk} {
     connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $pin]
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ${USER_KRNL}_1/ap_clk]

foreach pin {cmac_krnl_1/ap_rst_n network_krnl_1/ap_rst_n jtag_axi_0/aresetn
             ctrl_interconnect/aresetn} {
     connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins $pin]
}
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins ${USER_KRNL}_1/ap_rst_n]

# free-running clock для CMAC — имя пина взято из scripts/post_sys_link.tcl.in,
# где шелл подключал к нему ulp_m_aclk_freerun_ref_00.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins cmac_krnl_1/clk_gt_freerun]

# --- GT / QSFP0 ---------------------------------------------------------------
#
# Соответствие пинов cmac_krnl и портов платформы — из post_sys_link.tcl.in,
# ветка io_clk_gt2 (U200): io_gt_qsfp0_00 + io_clk_qsfp0_refclka_00.
# Пины кристалла — в u200_pins.xdc.

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp0
connect_bd_intf_net [get_bd_intf_ports qsfp0] \
                    [get_bd_intf_pins cmac_krnl_1/gt_serial_port]

create_bd_port -dir I qsfp0_refclk_p
create_bd_port -dir I qsfp0_refclk_n
connect_bd_net [get_bd_ports qsfp0_refclk_p] [get_bd_pins cmac_krnl_1/gt_refclk0_p]
connect_bd_net [get_bd_ports qsfp0_refclk_n] [get_bd_pins cmac_krnl_1/gt_refclk0_n]

# --- память для TCP session tables -------------------------------------------
#
# network_krnl имеет два мастера m00_axi/m01_axi (512 бит) — это таблицы сессий
# стека, они обязательны. В Vitis их привязывал sp= из
# scripts/network_krnl_mem.txt.in; шелл предоставлял memory subsystem.
#
# TODO: выбрать между DDR4 MIG и BRAM/URAM.
#   - DDR4 MIG: как в шелле, полный объём, но требует конфигурации MIG под
#     U200 (пины c0_ddr4_* / c1_ddr4_* есть в board/1.3/part0_pins.xml) и
#     заметно усложняет timing closure.
#   - axi_bram_ctrl: сильно проще поднять и достаточно для первого bring-up,
#     если число одновременных сессий невелико. Начать разумно с этого:
#     цель первого шага — увидеть, что порт слушается и счётчики растут.
#
# Ниже — вариант на BRAM как стартовый. Объём заведомо меньше, чем DDR;
# при упоре в лимит сессий заменить на MIG.

foreach {idx port} {0 m00_axi 1 m01_axi} {
     create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bram_ctrl_$idx
     set_property -dict [list \
          CONFIG.DATA_WIDTH {512} \
          CONFIG.SINGLE_PORT_BRAM {1} \
     ] [get_bd_cells bram_ctrl_$idx]

     create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bram_$idx
     set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM}] [get_bd_cells bram_$idx]

     connect_bd_intf_net [get_bd_intf_pins network_krnl_1/$port] \
                         [get_bd_intf_pins bram_ctrl_$idx/S_AXI]
     connect_bd_intf_net [get_bd_intf_pins bram_ctrl_$idx/BRAM_PORTA] \
                         [get_bd_intf_pins bram_$idx/BRAM_PORTA]

     connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins bram_ctrl_$idx/s_axi_aclk]
     connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins bram_ctrl_$idx/s_axi_aresetn]
}

# --- адреса -------------------------------------------------------------------
# Смещения должны совпасть с OUCH_BASE_* в jtag_ctrl.tcl.

assign_bd_address

puts ""
puts "=== карта адресов (сверить с jtag_ctrl.tcl) ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data]] {
     puts [format "  %-52s %s" $seg [get_property OFFSET $seg]]
}

# --- финал --------------------------------------------------------------------

validate_bd_design
save_bd_design

make_wrapper -files [get_files "$PROJ_DIR/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/$BD_NAME.bd"] -top
add_files -norecurse "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"
set_property top ${BD_NAME}_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse $PINS_XDC

puts ""
puts "BD собран. Дальше:"
puts "  launch_runs impl_1 -to_step write_bitstream -jobs 8"
puts "  wait_on_run impl_1"
puts ""
puts "Битстрим: $PROJ_DIR/$PROJ_NAME.runs/impl_1/${BD_NAME}_wrapper.bit"
puts "Грузить: Hardware Manager -> Program Device (flash НЕ трогается)"
