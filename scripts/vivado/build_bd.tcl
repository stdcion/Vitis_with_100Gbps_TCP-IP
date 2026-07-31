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

# Board part задаётся строкой: DDR4 IP берёт из него пины и параметры чипа
# памяти. Версия 1.3 — та, что лежит в scripts/vivado/board_files (из hw.xsa
# платформы). При обновлении board file поменять и здесь.
set BOARD_PART  "xilinx.com:au200:part0:1.3"
set PROJ_NAME   "ouch_vivado"
set PROJ_DIR    "./build_vivado"
set BD_NAME     "ouch_bd"

# Имя user-ядра. Первым аргументом -tclargs, иначе hls_ouch_krnl:
#     vivado -mode batch -source scripts/vivado/build_bd.tcl -tclargs hls_echo_krnl
#
# То же имя надо передать export_hls_ip.tcl — иначе соберётся IP одного
# ядра, а BD будет искать другое.
set USER_KRNL [expr {$::argc > 0 ? [lindex $::argv 0] : "hls_ouch_krnl"}]
puts "user-ядро: $USER_KRNL"

set REPO_ROOT   [file normalize [file dirname [info script]]/../..]
set CONFIG_SP   "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/config_sp_$USER_KRNL.txt"
set PINS_XDC    "$REPO_ROOT/scripts/vivado/u200_pins.xdc"

source "$REPO_ROOT/scripts/vivado/gen_axis_connect.tcl"

# --- проект -------------------------------------------------------------------

# DDR4 IP конфигурируется через board interfaces (C0_CLOCK_BOARD_INTERFACE,
# C0_DDR4_BOARD_INTERFACE): так он сам берёт ~150 пинов DDR4 и параметры чипа
# из board file, вместо того чтобы прописывать их вручную в XDC.
#
# Board file лежит в репозитории (scripts/vivado/board_files/au200/1.3),
# поэтому сборка не зависит от того, установлены ли board files в Vivado —
# в этой установке их нет. Файлы взяты из hw.xsa платформы
# xilinx_u200_gen3x16_xdma_2_202110_1 (каталог board/1.3).
#
# repoPaths задаётся ДО create_project — иначе плата не попадёт в каталог
# проекта.
set_param board.repoPaths [list "$REPO_ROOT/scripts/vivado/board_files"]

create_project $PROJ_NAME $PROJ_DIR -part $PART -force

# board_part задаём ИМЕНЕМ (строкой), а не объектом из get_board_parts,
# полученным до create_project: такой объект принадлежит другому контексту,
# set_property тихо не применяется, board_part остаётся пустым — и дальше
# у DDR4 IP нет ни одного board interface (единственное допустимое значение
# C0_*_BOARD_INTERFACE становится "Custom"), что выглядит как проблема с
# board file, хотя дело только в способе присваивания.
set_property board_part $BOARD_PART [current_project]

if {[get_property board_part [current_project]] ne $BOARD_PART} {
     error "board_part не применился (пусто вместо $BOARD_PART).\
            Проверь, что $REPO_ROOT/scripts/vivado/board_files/au200/1.3/board.xml на месте."
}
puts "board part: [get_property board_part [current_project]]"

# Проверяем, что интерфейсы платы реально видны: без них DDR4 придётся
# конфигурировать вручную (~150 пинов + параметры чипа), и лучше узнать об этом
# здесь, а не по невнятной ошибке DDR4 IP.
foreach need {ddr4_sdram_c3 default_300mhz_clk3} {
     if {[llength [get_board_part_interfaces -quiet -filter "NAME == $need"]] == 0} {
          error "board interface '$need' не найден — DDR4 не сконфигурировать из board file"
     }
}

# Каталоги с IP: и packaged_kernel_* от make, и ip_repo, и то, что положил HLS.
set ip_repos {}
foreach d [glob -nocomplain "$REPO_ROOT/packaged_kernel_*"] {
     lappend ip_repos $d
}
foreach d [glob -nocomplain "$REPO_ROOT/build/ip_repo"] {
     lappend ip_repos $d
}
# IP пользовательского ядра от export_hls_ip.tcl. Проект лежит в каталоге
# исходников ядра (HLS резолвит пути от каталога проекта — см. комментарий
# в export_hls_ip.tcl).
foreach d [glob -nocomplain "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/src/hls/*/*/impl/ip"] {
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

# У user-ядра s_axi_control есть НЕ всегда: hls_ouch_krnl объявляет
# s_axilite-аргументы (listenPort/enable/счётчики) и получает порт, а
# hls_echo_krnl обходится без них — порт слушания зашит константой, управлять
# нечем. Поэтому число мастеров зависит от ядра.
set USER_HAS_CTRL [expr {[llength [get_bd_intf_pins -quiet ${USER_KRNL}_1/s_axi_control]] > 0}]

# Мастера: network_krnl, ECC-регистры DDR4 (C0_DDR4_S_AXI_CTRL, см. секцию
# памяти ниже) и, если есть, s_axi_control user-ядра.
set n_mi [expr {$USER_HAS_CTRL ? 3 : 2}]
puts "ctrl_interconnect: $n_mi мастеров (user-ядро [expr {$USER_HAS_CTRL ? {со} : {без}}] s_axi_control)"

# NUM_CLKS=2: управляющие порты ядер на ap_clk, ECC-регистры DDR4 — на ui_clk
# контроллера.
set_property -dict [list \
     CONFIG.NUM_SI {1} \
     CONFIG.NUM_MI $n_mi \
     CONFIG.NUM_CLKS {2} \
] [get_bd_cells ctrl_interconnect]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] \
                    [get_bd_intf_pins ctrl_interconnect/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/M00_AXI] \
                    [get_bd_intf_pins network_krnl_1/s_axi_control]
if {$USER_HAS_CTRL} {
     connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/M01_AXI] \
                         [get_bd_intf_pins ${USER_KRNL}_1/s_axi_control]
}

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

# ext_reset_in обязателен: без него proc_sys_reset выдаёт сброс ТОЛЬКО при подаче
# питания ("Core will generate resets only on POWER ON"). После JTAG-перепрошивки
# логика не сбросилась бы — на отладке это выглядит как случайные залипания,
# причину которых искать долго.
#
# Берём кнопку CPU_RESET с платы (board interface resetn, пин AL20, активный
# низкий). Здесь она уместна, в отличие от sys_rst контроллера памяти: нажатие
# кнопки — это осознанный ресет дизайна, а не условие старта.
create_bd_port -dir I -type rst resetn
set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports resetn]
connect_bd_net [get_bd_ports resetn] [get_bd_pins rst_gen/ext_reset_in]

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

# Всё, что описывает саму память (деталь, тип, тайминги, ~150 пинов), приходит
# из board interface — так же, как это делает Block Automation в GUI. Своих
# значений не подставляем: board file для au200 уже содержит верные (сверено с
# ulp.bd платформы: MTA18ASF2G72PZ-2G3, RDIMM, 72 бита, TIMEPERIOD_PS=833).
#
# Если board_part не применился, эти два параметра принимают только "Custom",
# контроллер остаётся в конфигурации по умолчанию и требует подключить
# C0_DDR4_S_AXI_CTRL. Поэтому board_part проверяется выше явной ошибкой.
set_property -dict [list \
     CONFIG.C0_CLOCK_BOARD_INTERFACE {default_300mhz_clk3} \
     CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c3} \
     CONFIG.C0.DDR4_AxiSelection {true} \
     CONFIG.C0.DDR4_AxiDataWidth {512} \
] [get_bd_cells ddr4_c3]

# Внешние порты контроллера: CONFIG.*_BOARD_INTERFACE задаёт, ОТКУДА брать
# пины и параметры памяти, но сами порты и их подключение — отдельный шаг
# (иначе validate жалуется "C0_SYS_CLK is not connected to a valid clock
# source").
#
# make_bd_intf_pins_external сам создаёт порт нужного режима и переносит
# привязку к board interface. Это важно: атрибут BOARD_INTERFACE живёт в
# hdl_attributes порта, а не в CONFIG.* — попытка задать его через
# set_property CONFIG.BOARD_INTERFACE даёт "It is read-only".
# (В ulp.bd платформы у порта io_ddr4_00 он тоже в hdl_attributes.)
make_bd_intf_pins_external [get_bd_intf_pins ddr4_c3/C0_SYS_CLK]
make_bd_intf_pins_external [get_bd_intf_pins ddr4_c3/C0_DDR4]

# Частоту на созданном порте задаём явно: make_bd_intf_pins_external оставляет
# FREQ_HZ по умолчанию (100 МГц), а контроллер ждёт свои ~300.12 МГц
# ("Clock frequency of the connected clock is 100.000000 MHz while Reference
# Input Clock Speed is 300.120 MHz"). С неверной частотой DDR не откалибруется.
#
# Имя порта ищем по факту — через сеть, которой он соединён с пином C0_SYS_CLK.
# make_bd_intf_pins_external имя не возвращает (даёт пустую строку) и добавляет
# суффикс к имени пина, так что ни угадывать, ни брать из результата нельзя.
set sys_clk_net [get_bd_intf_nets -of_objects [get_bd_intf_pins ddr4_c3/C0_SYS_CLK]]
set sys_clk_port [get_bd_intf_ports -of_objects $sys_clk_net]
if {[llength $sys_clk_port] != 1} {
     error "не нашёл внешний порт для ddr4_c3/C0_SYS_CLK (получил: '$sys_clk_port')"
}

# Значение считаем из DDR4_InputClockPeriod самого IP: 300.12 МГц — не круглое
# число, оно следует из периода в пикосекундах, и расхождение снова даст warning.
set ddr4_ref_ps [get_property CONFIG.C0.DDR4_InputClockPeriod [get_bd_cells ddr4_c3]]
set ddr4_ref_hz [expr {round(1.0e12 / $ddr4_ref_ps)}]
puts "DDR4 sys_clk: порт $sys_clk_port, $ddr4_ref_hz Hz (период $ddr4_ref_ps пс)"
set_property CONFIG.FREQ_HZ $ddr4_ref_hz $sys_clk_port

# sys_rst НЕ берём из board interface resetn: по board.xml это "CPU Reset Push
# Button, Active Low" — физическая кнопка на пине AL20. Плата в корпусе, кнопку
# никто не нажмёт, и контроллер остался бы в сбросе.
#
# Держим контроллер в сбросе, пока не поднялся MMCM. Полярность sys_rst у
# ddr4:2.2 фиксированная (активный ВЫСОКИЙ; параметра SYSTEM_RESET_POLARITY у
# IP нет — проверено), поэтому locked нужно инвертировать: locked=1 -> sys_rst=0.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 ddr4_rst_inv
set_property -dict [list \
     CONFIG.C_SIZE {1} \
     CONFIG.C_OPERATION {not} \
] [get_bd_cells ddr4_rst_inv]

connect_bd_net [get_bd_pins clk_wiz_0/locked]  [get_bd_pins ddr4_rst_inv/Op1]
connect_bd_net [get_bd_pins ddr4_rst_inv/Res]  [get_bd_pins ddr4_c3/sys_rst]

# C0_DDR4_S_AXI_CTRL — AXI-Lite для ECC-регистров контроллера. Появляется
# штатно, потому что банк ddr4_sdram_c3 на U200 — ECC-память (в ulp.bd
# платформы DATA_WIDTH=72, деталь MTA18ASF2G72PZ-2G3), и контроллер с ECC
# обязан отдавать этот интерфейс. Отключать ECC не станем: XRT-сборка работала
# с ним, а расхождение с рабочей конфигурацией — лишний источник отказа.
#
# Вешаем его на тот же управляющий интерконнект: ECC-статус (счётчики
# исправленных/неисправимых ошибок) будет читаться через JTAG, как и остальные
# регистры. Домен здесь ui_clk контроллера, отсюда NUM_CLKS=2 у ctrl_interconnect.
# Номер мастера зависит от того, занял ли M01 user-ядро (см. USER_HAS_CTRL).
set mi_ddr [format "M%02d_AXI" [expr {$USER_HAS_CTRL ? 2 : 1}]]
connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/$mi_ddr] \
                    [get_bd_intf_pins ddr4_c3/C0_DDR4_S_AXI_CTRL]
connect_bd_net [get_bd_pins ddr4_c3/c0_ddr4_ui_clk] [get_bd_pins ctrl_interconnect/aclk1]

# Калибровка памяти на светодиод. На bring-up это главный диагностический
# сигнал: если DDR не откалибровалась, network_krnl не сможет держать сессии, и
# без этого индикатора "стек молчит из-за памяти" не отличить от "стек молчит
# из-за CMAC". Читать через JTAG нельзя — это не регистр, а пин.
create_bd_port -dir O ddr4_calib_done
connect_bd_net [get_bd_pins ddr4_c3/c0_init_calib_complete] [get_bd_ports ddr4_calib_done]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 mem_interconnect

# NUM_CLKS=2 обязателен: мастера network_krnl работают на ap_clk (200 МГц), а
# контроллер отдаёт свой ui_clk (300 МГц). Без этого параметра у smartconnect
# просто нет пина aclk1, и подключение падает с "No pins matched .../aclk1" —
# число тактовых входов задаётся конфигурацией, а не появляется само при
# подключении разнодоменных портов.
set_property -dict [list \
     CONFIG.NUM_SI {2} \
     CONFIG.NUM_MI {1} \
     CONFIG.NUM_CLKS {2} \
] [get_bd_cells mem_interconnect]

connect_bd_intf_net [get_bd_intf_pins network_krnl_1/m00_axi] \
                    [get_bd_intf_pins mem_interconnect/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins network_krnl_1/m01_axi] \
                    [get_bd_intf_pins mem_interconnect/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_interconnect/M00_AXI] \
                    [get_bd_intf_pins ddr4_c3/C0_DDR4_S_AXI]

# aclk — домен слейв-портов (ap_clk ядер), aclk1 — домен мастер-порта (ui_clk
# контроллера). Пересечение доменов smartconnect берёт на себя.
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

set seg_net  [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                  -filter "NAME =~ *network_krnl*"]
set seg_user [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                  -filter "NAME =~ *${USER_KRNL}*"]

# Переназначаем в два прохода: сперва уводим сегменты в свободную область,
# потом ставим на целевые адреса.
#
# В один проход нельзя: автораспределение раскладывает сегменты в порядке
# обхода, и он зависит от состава дизайна. Если целевой адрес занят другим
# сегментом, set_property offset молча не применяется, и проверка ниже падает.
set_property offset 0x10000000 $seg_net
if {[llength $seg_user] > 0} {
     set_property offset 0x20000000 $seg_user
}

set_property offset $ADDR_NETWORK $seg_net
if {[llength $seg_user] > 0} {
     set_property offset $ADDR_USER $seg_user
}

puts ""
puts "=== карта адресов ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data]] {
     puts [format "  %-52s %s" $seg [get_property OFFSET $seg]]
}

# Проверяем, что получилось именно то, что прописано в jtag_ctrl.tcl —
# иначе управление пойдёт не в те регистры, а на железе это выглядит как
# "ядро не реагирует", без всякой диагностики.
set got_net [get_property OFFSET $seg_net]
if {$got_net ne $ADDR_NETWORK} {
     error "адрес network_krnl=$got_net, ждали $ADDR_NETWORK.\
            Либо он занят другим сегментом, либо правь OUCH_BASE_NETWORK\
            в scripts/vivado/jtag_ctrl.tcl."
}
puts ""
puts "  network_krnl s_axi_control -> $ADDR_NETWORK  (OUCH_BASE_NETWORK)"

if {[llength $seg_user] > 0} {
     set got_user [get_property OFFSET $seg_user]
     if {$got_user ne $ADDR_USER} {
          error "адрес ${USER_KRNL}=$got_user, ждали $ADDR_USER —\
                 сверь OUCH_BASE_USER в scripts/vivado/jtag_ctrl.tcl."
     }
     puts "  ${USER_KRNL} s_axi_control -> $ADDR_USER  (OUCH_BASE_USER)"
} else {
     puts "  ${USER_KRNL}: без s_axi_control — управлять нечем,"
     puts "               порт слушания зашит в ядре. Из jtag_ctrl.tcl нужны"
     puts "               только network_configure и network_start."
}

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
