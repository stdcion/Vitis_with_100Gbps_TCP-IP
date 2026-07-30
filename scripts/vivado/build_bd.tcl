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

# DDR4 IP конфигурируется через board interfaces (C0_CLOCK_BOARD_INTERFACE,
# C0_DDR4_BOARD_INTERFACE): так он сам берёт ~150 пинов DDR4 и параметры чипа
# из board file, вместо того чтобы прописывать их вручную в XDC.
#
# Board file лежит в репозитории (scripts/vivado/board_files/au200/1.3),
# поэтому сборка не зависит от того, установлены ли board files в Vivado —
# в этой установке их нет. Файлы взяты из hw.xsa платформы
# xilinx_u200_gen3x16_xdma_2_202110_1 (каталог board/1.3).
set_param board.repoPaths [list "$REPO_ROOT/scripts/vivado/board_files"]

set board_hits [get_board_parts -quiet -filter {NAME =~ *au200*}]
if {[llength $board_hits] == 0} {
     error "board part au200 не найден даже в $REPO_ROOT/scripts/vivado/board_files —\
            проверь, что там лежит au200/1.3/board.xml"
}

# Берём максимальную версию, если их несколько (репозиторий + системная).
set BOARD_PART [lindex [lsort -decreasing $board_hits] 0]
puts "board part: $BOARD_PART"
set_property board_part $BOARD_PART [current_project]

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
# сами из 300 МГц входа:
#   clk_out1 = 200 МГц — ap_clk ядер. Ровно та частота, с которой ядро
#              собиралось в Vitis-флоу (Makefile: --kernel_frequency 200) и на
#              которую рассчитан export_hls_ip.tcl.
#   clk_out2 = 100 МГц — free-running для CMAC; в шелле это был
#              ulp_m_aclk_freerun_ref_00 (см. ветку frc1 в post_sys_link.tcl.in).

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
     CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
     CONFIG.PRIM_IN_FREQ {300.000} \
     CONFIG.CLKOUT1_USED {true} \
     CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
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
# Воспроизводим ровно то, что делала XRT-сборка, а не подбираем свой вариант.
# CMakeLists.txt для FDEV_NAME=u200 задаёт:
#     NETWORK_KRNL_MEM = DDR[3]      -> банк ddr4_sdram_c3
#     CMAC_SLR         = SLR2
# и scripts/network_krnl_mem.txt.in привязывал ОБА мастера (m00_axi и m01_axi)
# к одному и тому же банку. board.xml подтверждает: ddr4_sdram_c3 — 16 ГБ,
# SLR2, тактируется от default_300mhz_clk3. То есть память и CMAC жили в одном
# SLR — сохраняем и это.
#
# Оба мастера идут в один контроллер через smartconnect, как и при sp= на один
# банк в Vitis-флоу.

create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_c3
set_property -dict [list \
     CONFIG.C0_CLOCK_BOARD_INTERFACE {default_300mhz_clk3} \
     CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c3} \
     CONFIG.RESET_BOARD_INTERFACE {resetn} \
     CONFIG.C0.DDR4_AxiDataWidth {512} \
     CONFIG.C0.DDR4_AxiAddressWidth {34} \
     CONFIG.C0.DDR4_AxiSelection {true} \
] [get_bd_cells ddr4_c3]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 mem_interconnect
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells mem_interconnect]

connect_bd_intf_net [get_bd_intf_pins network_krnl_1/m00_axi] \
                    [get_bd_intf_pins mem_interconnect/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins network_krnl_1/m01_axi] \
                    [get_bd_intf_pins mem_interconnect/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_interconnect/M00_AXI] \
                    [get_bd_intf_pins ddr4_c3/C0_DDR4_S_AXI]

# Мастера network_krnl тактируются ap_clk (200 МГц), а контроллер отдаёт свой
# ui_clk (обычно 300 МГц): smartconnect разводит домены сам, но клоки ему нужно
# подать оба.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins mem_interconnect/aclk]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins mem_interconnect/aresetn]
connect_bd_net [get_bd_pins ddr4_c3/c0_ddr4_ui_clk] [get_bd_pins mem_interconnect/aclk1]

# Сброс AXI-интерфейса контроллера — в его собственном домене ui_clk,
# отпускается по его же ui_clk_sync_rst.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ddr4
connect_bd_net [get_bd_pins ddr4_c3/c0_ddr4_ui_clk]          [get_bd_pins rst_ddr4/slowest_sync_clk]
connect_bd_net [get_bd_pins ddr4_c3/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_ddr4/ext_reset_in]
connect_bd_net [get_bd_pins rst_ddr4/peripheral_aresetn]     [get_bd_pins ddr4_c3/c0_ddr4_aresetn]

# --- адреса -------------------------------------------------------------------
#
# Базовые адреса задаём явно, а не полагаемся на assign_bd_address: тот
# распределяет по порядку обхода и уже один раз выдал network_krnl по 0x10000,
# а user-ядро по 0x0 — то есть наоборот относительно jtag_ctrl.tcl. Молчаливое
# расхождение здесь означает запись параметров не в те регистры, поэтому
# фиксируем адреса и сверяем их в конце.

set ADDR_NETWORK 0x00000000
set ADDR_USER    0x00010000

# Сначала — автоматически всё, что не назначено (память для m0*_axi).
assign_bd_address -quiet

# Затем принудительно переназначаем control-сегменты на нужные адреса.
set seg_net  [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                  -filter "NAME =~ *network_krnl*"]
set seg_user [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                  -filter "NAME =~ *${USER_KRNL}*"]

set_property offset $ADDR_NETWORK $seg_net
set_property offset $ADDR_USER    $seg_user

puts ""
puts "=== карта адресов ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data]] {
     puts [format "  %-52s %s" $seg [get_property OFFSET $seg]]
}

# Проверяем, что получилось именно то, что прописано в jtag_ctrl.tcl —
# иначе управление пойдёт не в те регистры, а на железе это выглядит как
# "ядро не реагирует", без всякой диагностики.
if {[get_property OFFSET $seg_net] ne $ADDR_NETWORK ||
    [get_property OFFSET $seg_user] ne $ADDR_USER} {
     error "адреса не совпали с ожидаемыми — сверь OUCH_BASE_* в scripts/vivado/jtag_ctrl.tcl"
}
puts ""
puts "  network_krnl s_axi_control -> $ADDR_NETWORK  (OUCH_BASE_NETWORK)"
puts "  ${USER_KRNL} s_axi_control -> $ADDR_USER  (OUCH_BASE_USER)"

# --- финал --------------------------------------------------------------------

validate_bd_design
save_bd_design

make_wrapper -files [get_files "$PROJ_DIR/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/$BD_NAME.bd"] -top
add_files -norecurse "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"
set_property top ${BD_NAME}_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse $PINS_XDC

# CMAC в SLR2 — как задавал scripts/cmac_krnl_slr.txt.in в Vitis-флоу
# (CMakeLists.txt: CMAC_SLR=SLR2 для u200). Это не косметика: GT-квады QSFP0
# физически в SLR2, и размещение ядра в другом SLR ломает timing на GT-путях.
# DDR4 c3 по board.xml тоже в SLR2, так что весь сетевой путь остаётся локальным.
set slr_xdc "$PROJ_DIR/cmac_slr.xdc"
set fh [open $slr_xdc w]
puts $fh "# сгенерировано build_bd.tcl из CMAC_SLR=SLR2 (CMakeLists.txt, u200)"
puts $fh "create_pblock pblock_cmac"
puts $fh "resize_pblock \[get_pblocks pblock_cmac\] -add {SLR2}"
puts $fh "add_cells_to_pblock \[get_pblocks pblock_cmac\] \[get_cells -hierarchical -filter {NAME =~ *cmac_krnl_1*}\]"
close $fh
add_files -fileset constrs_1 -norecurse $slr_xdc

puts ""
puts "BD собран. Дальше:"
puts "  launch_runs impl_1 -to_step write_bitstream -jobs 8"
puts "  wait_on_run impl_1"
puts ""
puts "Битстрим: $PROJ_DIR/$PROJ_NAME.runs/impl_1/${BD_NAME}_wrapper.bit"
puts "Грузить: Hardware Manager -> Program Device (flash НЕ трогается)"
