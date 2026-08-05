# /*******************************************************************************
# (c) Copyright 2019 Xilinx, Inc. All rights reserved.
# This file contains confidential and proprietary information 
# of Xilinx, Inc. and is protected under U.S. and
# international copyright and other intellectual property 
# laws.
# 
# DISCLAIMER
# This disclaimer is not a license and does not grant any 
# rights to the materials distributed herewith. Except as 
# otherwise provided in a valid license issued to you by 
# Xilinx, and to the maximum extent permitted by applicable
# law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
# WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES 
# AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING 
# BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
# INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and 
# (2) Xilinx shall not be liable (whether in contract or tort, 
# including negligence, or under any other theory of 
# liability) for any loss or damage of any kind or nature 
# related to, arising under or in connection with these 
# materials, including for any direct, or any indirect, 
# special, incidental, or consequential loss or damage 
# (including loss of data, profits, goodwill, or any type of 
# loss or damage suffered as a result of any action brought 
# by a third party) even if such damage or loss was 
# reasonably foreseeable or Xilinx had been advised of the 
# possibility of the same.
# 
# CRITICAL APPLICATIONS
# Xilinx products are not designed or intended to be fail-
# safe, or for use in any application requiring fail-safe
# performance, such as life-support or safety devices or 
# systems, Class III medical devices, nuclear facilities, 
# applications related to the deployment of airbags, or any 
# other applications that could lead to death, personal 
# injury, or severe property or environmental damage 
# (individually and collectively, "Critical 
# Applications"). Customer assumes the sole risk and 
# liability of any use of Xilinx products in Critical 
# Applications, subject only to applicable laws and 
# regulations governing limitations on product liability.
# 
# THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS 
# PART OF THIS FILE AT ALL TIMES.
# 
# *******************************************************************************/
set path_to_hdl "./kernel/cmac_krnl/src"
set path_to_packaged "./packaged_kernel_${suffix}"
set path_to_tmp_project "./tmp_kernel_pack_${suffix}"
set path_to_common "./kernel/common"

set words [split $device "_"]
set board [lindex $words 1]

# qsfp_idx выбирает физический QSFP-разъём (GT-квад), а не плату — cmake про
# него не знает и не должен: CMAC_SLR/NETWORK_KRNL_MEM в CMakeLists.txt общие
# для платы независимо от того, какой порт собирается. Переменную задаёт
# gen_xo.tcl из необязательного 8-го аргумента; при прямом source без неё
# (старые вызовы) сохраняем текущее поведение — порт 0.
if {![info exists qsfp_idx]} {
    set qsfp_idx 0
}

if {[string compare -nocase $board "u200"] == 0} {
    set projPart "xcu200-fsgd2104-2-e"
} elseif {[string compare -nocase $board "u280"] == 0} {
    set projPart "xcu280-fsvh2892-2L-e"
} elseif {[string compare -nocase $board "u250"] == 0} {
  	set projPart "xcu250-figd2104-2L-e"
} elseif {[string compare -nocase $board "u50"] == 0} {
  	set projPart "xcu50-fsvh2104-2-e"
} elseif {[string compare -nocase $board "u55c"] == 0} {
  	set projPart "xcu55c-fsvh2892-2L-e"
} else {
    puts "Unknown board $board"
    exit 
}

set projName kernel_pack
create_project -force $projName $path_to_tmp_project -part $projPart

# --- имя внутреннего cmac_usplus IP: СВОЁ у каждого порта ---------------------
#
# Так делает и официальный OpenNIC от AMD: у него на каждый порт отдельный
# скрипт с отдельным module_name (src/cmac_subsystem/vivado_ip/
# cmac_usplus_{0,1}_au200.tcl, имена cmac_usplus_0 / cmac_usplus_1) и своими
# CMAC_CORE_SELECT/GT_GROUP_SELECT. Это не наша выдумка, а штатный способ
# держать два CMAC в одном дизайне.
#
# ЗАЧЕМ. Vivado привязывает XDC сгенерированного IP через SCOPED_TO_REF, то есть
# по ИМЕНИ МОДУЛЯ. При общем имени XDC каждого порта матчил ОБА CMAC (LOC там
# задан шаблоном get_cells -hierarchical по всему дизайну), из-за чего:
#     CRITICAL WARNING [Vivado 12-2285] can not be placed in CMACE4 ... occupied
#     CRITICAL WARNING [Common 17-55]   'set_property' expects at least one object
#     WARNING          [Place 30-1241]  large block is missing its placement
# Последнее означает CMAC вообще без LOC — placer ставит его куда попало, и порт
# на плате не поднимает линк. Разные имена разводят SCOPED_TO_REF, и каждый XDC
# применяется только к своему экземпляру.
#
# Порт 0 сохраняет прежнее имя — на него смотрят Vitis-флоу и cmac_krnl.xml.
if {$qsfp_idx == 0} {
    set cmac_ip_name "cmac_usplus_axis"
} else {
    set cmac_ip_name "cmac_usplus_axis_qsfp${qsfp_idx}"
}
puts "INFO: внутренний cmac_usplus IP: $cmac_ip_name (qsfp_idx=$qsfp_idx)"

# cmac_usplus_axis_wrapper.sv инстанцирует этот IP ПО ИМЕНИ, а имя модуля в
# Verilog не параметризуется. Через `define это не решается: файл попадает в
# пакет как исходник и синтезируется уже в проекте BD, где никаких наших
# define нет (проверено — синтез падал с "[Synth 8-439] module
# 'cmac_usplus_axis' not found"), причём оба пакета кладут .sv в ОДИН общий
# ipshared/<hash>/src/, так что одного файла на два имени не хватит.
#
# Поэтому для портов N>0 работаем с КОПИЕЙ дерева исходников, где имя модуля
# подставлено. Оригинал в kernel/cmac_krnl/src не трогаем: он остаётся валидным
# сам по себе (порт 0, Vitis-флоу, чтение глазами).
if {$qsfp_idx != 0} {
    set path_to_hdl_staged "./tmp_hdl_cmac_krnl_${suffix}"
    file delete -force $path_to_hdl_staged
    file mkdir $path_to_hdl_staged
    file copy -force "$path_to_hdl/hdl" "$path_to_hdl_staged/hdl"

    set wrapper_sv "$path_to_hdl_staged/hdl/cmac_usplus_axis_wrapper.sv"
    set fh [open $wrapper_sv r]
    set body [read $fh]
    close $fh

    # Заменяем ровно инстанцирование ("cmac_usplus_axis cmac_axis_inst"), а не
    # все вхождения строки: имя встречается ещё в комментариях и в имени самого
    # файла-обёртки, и слепой replace их бы тоже задел.
    set needle "cmac_usplus_axis cmac_axis_inst"
    set n_repl [regsub -all "cmac_usplus_axis\\s+cmac_axis_inst" $body \
                     "$cmac_ip_name cmac_axis_inst" body]
    if {$n_repl != 1} {
        error "ожидал РОВНО одно инстанцирование '$needle' в\
               cmac_usplus_axis_wrapper.sv, нашёл $n_repl. Если обёртку\
               переименовали — поправь эту подстановку в package_cmac_krnl.tcl,\
               иначе порт $qsfp_idx соберётся с CMAC от порта 0."
    }

    set fh [open $wrapper_sv w]
    puts -nonewline $fh $body
    close $fh
    puts "INFO: staged RTL: $path_to_hdl_staged (имя модуля -> $cmac_ip_name)"
} else {
    set path_to_hdl_staged $path_to_hdl
}

add_files -norecurse [glob $path_to_hdl_staged/hdl/*.v $path_to_hdl_staged/hdl/*.sv $path_to_hdl_staged/hdl/*.svh ]
add_files -norecurse [glob $path_to_common/types/*.v $path_to_common/types/*.sv $path_to_common/types/*.svh ]

set_property top cmac_krnl [current_fileset]

update_compile_order -fileset sources_1

set __ip_list [get_property ip_repo_paths [current_project]]

lappend __ip_list ./build/ip_repo
set_property ip_repo_paths $__ip_list [current_project]
update_ip_catalog

create_ip -name axis_register_slice -vendor xilinx.com -library ip -module_name axis_register_slice_512 
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.Component_Name {axis_register_slice_512}] [get_ips axis_register_slice_512]

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -module_name axis_pkg_fifo_512 
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.FIFO_MODE {2} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.Component_Name {axis_pkg_fifo_512}] [get_ips axis_pkg_fifo_512]

create_ip -name ethernet_frame_padding -vendor ethz.systems.fpga -library hls -version 0.2 -module_name ethernet_frame_padding_ip 

# Default GT reference frequency
set gt_ref_clk 156.25
set freerunningclock 100

# $cmac_ip_name задан выше (общий для всех портов) — там же объяснение, почему
# развести его по портам нельзя и что из этого следует для размещения CMAC.
# Переменная, а не литерал: имя фигурирует в трёх местах, и расхождение между
# ними даёт невнятную ошибку "IP not found" вместо понятной.
create_ip -name cmac_usplus -vendor xilinx.com -library ip -module_name $cmac_ip_name
if {[string compare -nocase $board "u280"] == 0} {
	if {$qsfp_idx != 0} {
		error "u280: для QSFP_IDX=$qsfp_idx координаты GT-квада не проверены — правь эту ветку осознанно, а не угадывай"
	}
	set freerunningclock 50
	# Possible core_selection CMACE4_X0Y5; CMACE4_X0Y6 and CMACE4_X0Y7
	set core_selection  CMACE4_X0Y5
	set group_selection X0Y40~X0Y43
	set gt_clk_freq [expr int(${gt_ref_clk} * 1000000)]
	puts "Generating IPI for u280 cmac_usplus_axis with GT clock running at ${gt_clk_freq} Hz"

} elseif {[string compare -nocase $board "u200"] == 0} {
	# QSFP0 -> CMACE4_X0Y6 (X1Y48~X1Y51); QSFP1 -> CMACE4_X0Y7 (X1Y44~X1Y47).
	# Оба квада в SLR2 (см. devices/u200/device.tcl.in) — второй порт не требует
	# другого pblock.
	#
	# Значения сверены с официальным OpenNIC от AMD для этой же платы
	# (src/cmac_subsystem/vivado_ip/cmac_usplus_{0,1}_au200.tcl) — совпадают.
	# Оттуда же взяты lane_loc и pll_type ниже.
	if {$qsfp_idx == 0} {
		set core_selection  CMACE4_X0Y6
		set group_selection X1Y48~X1Y51
		set lane_loc        [list X1Y48 X1Y49 X1Y50 X1Y51]
		# QPLL0 — дефолт IP, задаём явно для симметрии с портом 1.
		set pll_type        QPLL0
	} elseif {$qsfp_idx == 1} {
		set core_selection  CMACE4_X0Y7
		set group_selection X1Y44~X1Y47
		set lane_loc        [list X1Y44 X1Y45 X1Y46 X1Y47]
		# КРИТИЧНО: второму CMAC нужен ДРУГОЙ QPLL.
		#
		# Квады X1Y44~47 и X1Y48~47 сидят в одном GT-банке, а QPLL там общий на
		# банк. Если оба порта возьмут QPLL0, второй не получит тактирования и
		# линк не поднимется — при этом сборка пройдёт без ошибок, потому что
		# конфликт не виден ни DRC, ни placer'у.
		#
		# OpenNIC ставит QPLL1 ровно для порта 1 на au200 — берём то же.
		set pll_type        QPLL1
	} else {
		error "u200 поддерживает только QSFP_IDX 0 или 1, получено: $qsfp_idx"
	}
	set gt_clk_freq [expr int(${gt_ref_clk} * 1000000)]
	puts "Generating IPI for u200 cmac_usplus_axis (QSFP${qsfp_idx}) with GT clock running at ${gt_clk_freq} Hz"
	puts "  core=$core_selection quad=$group_selection lanes=$lane_loc pll=$pll_type"

} elseif {[string compare -nocase $board "u250"] == 0} {
	if {$qsfp_idx != 0} {
		error "u250: для QSFP_IDX=$qsfp_idx координаты GT-квада не проверены — правь эту ветку осознанно, а не угадывай"
	}
  	set core_selection  CMACE4_X0Y7
    set group_selection X1Y44~X1Y47
	set gt_clk_freq [expr int(${gt_ref_clk} * 1000000)]
	puts "Generating IPI for u250 cmac_usplus_axis with GT clock running at ${gt_clk_freq} Hz"
	
} elseif {[string compare -nocase $board "u50"] == 0} {
	if {$qsfp_idx != 0} {
		error "u50: для QSFP_IDX=$qsfp_idx координаты GT-квада не проверены — правь эту ветку осознанно, а не угадывай"
	}
	# Possible core_selection CMACE4_X0Y3 and CMACE4_X0Y4
	set gt_ref_clk 161.1328125
	set core_selection  CMACE4_X0Y3
	set group_selection X0Y28~X0Y31
  	set gt_clk_freq [expr int(${gt_ref_clk} * 1000000)]
	puts "Generating IPI for u50 cmac_usplus_axis with GT clock running at ${gt_clk_freq} Hz"

} elseif {[string compare -nocase $board "u55c"] == 0} {
	if {$qsfp_idx != 0} {
		error "u55c: для QSFP_IDX=$qsfp_idx координаты GT-квада не проверены — правь эту ветку осознанно, а не угадывай"
	}
	set gt_ref_clk 161.1328125
	# Possible core_selection CMACE4_X0Y2; CMACE4_X0Y3; CMACE4_X0Y4
	set core_selection  CMACE4_X0Y2
	set group_selection X0Y24~X0Y27
  	set gt_clk_freq [expr int(${gt_ref_clk} * 1000000)]
	puts "Generating IPI for u55c cmac_usplus_axis with GT clock running at ${gt_clk_freq} Hz"

} else {
    puts "Unknown board $board"
    exit 
}

set_property -dict [list \
	CONFIG.CMAC_CAUI4_MODE             {1} \
	CONFIG.NUM_LANES                   {4x25} \
	CONFIG.GT_REF_CLK_FREQ             $gt_ref_clk \
	CONFIG.CMAC_CORE_SELECT            $core_selection \
	CONFIG.GT_GROUP_SELECT             $group_selection \
	CONFIG.GT_DRP_CLK                  $freerunningclock \
	CONFIG.USER_INTERFACE              {AXIS} \
	CONFIG.TX_FLOW_CONTROL             {0} \
	CONFIG.RX_FLOW_CONTROL             {0} \
	CONFIG.ENABLE_PIPELINE_REG         {1} \
	CONFIG.Component_Name              $cmac_ip_name
]  [get_ips $cmac_ip_name]

# --- сайты GT-каналов и QPLL — параметрами IP, а не через XDC ------------------
#
# LANE{1..4}_GT_LOC задаёт физический сайт каждого канала. Без них IP сам
# раскладывает каналы внутри GT_GROUP_SELECT и пишет LOC в свой
# cmac_usplus_axis_gt.xdc через шаблон gen_channel_container[NN] — при двух
# CMAC в дизайне такой шаблон лезет и в чужое IP (см. Common 17-55 в логе impl).
# Заданные параметром, координаты попадают в IP явно и от XDC не зависят.
#
# PLL_TYPE: два CMAC в одном GT-банке не могут делить один QPLL. Порт 0 —
# QPLL0, порт 1 — QPLL1.
#
# Оба набора значений — из официального OpenNIC для au200
# (src/cmac_subsystem/vivado_ip/cmac_usplus_{0,1}_au200.tcl).
#
# Задаётся только там, где значения проверены (сейчас u200 с двумя портами).
# Для остальных плат ветки выше lane_loc/pll_type не выставляют — оставляем
# поведение IP по умолчанию, как было до этой правки.
if {[info exists lane_loc] && [info exists pll_type]} {
	set lane_dict [list]
	for {set l 0} {$l < [llength $lane_loc]} {incr l} {
		lappend lane_dict "CONFIG.LANE[expr {$l + 1}]_GT_LOC" [lindex $lane_loc $l]
	}
	# Каналы 5..10 существуют только для CAUI-10; в режиме 4x25 их надо явно
	# погасить, иначе IP оставляет прежние значения от предыдущей конфигурации.
	for {set l 5} {$l <= 10} {incr l} {
		lappend lane_dict "CONFIG.LANE${l}_GT_LOC" {NA}
	}
	lappend lane_dict CONFIG.PLL_TYPE $pll_type

	set_property -dict $lane_dict [get_ips $cmac_ip_name]
	puts "INFO: LANE*_GT_LOC = $lane_loc, PLL_TYPE = $pll_type"
}

## Crossings
create_ip -name axis_data_fifo -vendor xilinx.com -library ip -module_name axis_data_fifo_cc_udp_data
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.FIFO_DEPTH {256} CONFIG.IS_ACLK_ASYNC {1} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.Component_Name {axis_data_fifo_cc_udp_data}] [get_ips axis_data_fifo_cc_udp_data]
update_compile_order -fileset sources_1

##ila
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_cmac
set_property -dict [list CONFIG.C_PROBE0_WIDTH {4}  CONFIG.C_PROBE8_WIDTH {4} CONFIG.C_PROBE9_WIDTH {6} CONFIG.C_PROBE12_WIDTH {4} CONFIG.C_NUM_OF_PROBES {14} CONFIG.C_EN_STRG_QUAL {1} CONFIG.C_ADV_TRIGGER {true} CONFIG.C_INPUT_PIPE_STAGES {1}] [get_ips ila_cmac]
update_compile_order -fileset sources_1

create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
set_property -dict [list CONFIG.C_NUM_OF_PROBES {1} CONFIG.C_EN_STRG_QUAL {1} CONFIG.C_ADV_TRIGGER {true} CONFIG.C_INPUT_PIPE_STAGES {1}] [get_ips ila_0]
update_compile_order -fileset sources_1



update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
ipx::package_project -root_dir $path_to_packaged -vendor xilinx.com -library RTLKernel -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $path_to_packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $path_to_packaged $path_to_packaged/component.xml
set_property core_revision 1 [ipx::current_core]

# ВАЖНО: у каждого QSFP-порта должен быть СВОЙ VLNV.
#
# core_selection/group_selection выше зашиваются в XDC упакованного IP, то есть
# порт 0 и порт 1 — физически разные IP, а не один IP с параметром. Пока имя
# ядра было общим ("cmac_krnl"), оба пакета получали VLNV
# xilinx.com:RTLKernel:cmac_krnl:1.0, Vivado при загрузке каталога сообщал
# "Duplicate IP found ... will take precedence" и молча брал ТОЛЬКО пакет
# порта 0. В результате cmac_krnl_2 в BD получал координаты порта 0
# (CMACE4_X0Y6/X1Y48~X1Y51), Vivado снимал конфликтующий LOC ([Place 30-1241])
# и размещал второй CMAC мимо квада QSFP1 — сборка проходила без ошибок, но
# второй порт на плате не поднял бы линк.
#
# Разводим имена: порт 0 остаётся "cmac_krnl" (совместимость с Vitis-флоу и
# cmac_krnl.xml), порт N>0 получает "cmac_krnl_qsfpN". Парная правка —
# _find_ipdef в scripts/vivado/build_bd.tcl, который резолвит VLNV per-канал.
if {$qsfp_idx != 0} {
    set_property name "cmac_krnl_qsfp${qsfp_idx}" [ipx::current_core]
    set_property display_name "cmac_krnl_qsfp${qsfp_idx}" [ipx::current_core]
    set_property description "CMAC kernel for QSFP${qsfp_idx} (${core_selection}, ${group_selection})" [ipx::current_core]
}
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] [ipx::current_core]
}
set_property sdx_kernel true [ipx::current_core]
set_property sdx_kernel_type rtl [ipx::current_core]
ipx::create_xgui_files [ipx::current_core]
ipx::add_bus_interface ap_clk [ipx::current_core]
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:signal:clock:1.0 [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
ipx::add_port_map CLK [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
set_property physical_name ap_clk [ipx::get_port_maps CLK -of_objects [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]]

ipx::add_bus_interface gt_serial_port [ipx::current_core]
set_property interface_mode master [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:gt_rtl:1.0 [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:interface:gt:1.0 [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
ipx::add_port_map GRX_P [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property physical_name gt_rxp_in [ipx::get_port_maps GRX_P -of_objects [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]]
ipx::add_port_map GTX_N [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property physical_name gt_txn_out [ipx::get_port_maps GTX_N -of_objects [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]]
ipx::add_port_map GRX_N [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property physical_name gt_rxn_in [ipx::get_port_maps GRX_N -of_objects [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]]
ipx::add_port_map GTX_P [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]
set_property physical_name gt_txp_out [ipx::get_port_maps GTX_P -of_objects [ipx::get_bus_interfaces gt_serial_port -of_objects [ipx::current_core]]]

ipx::add_bus_interface axis_net_rx [ipx::current_core]
set_property interface_mode master [ipx::get_bus_interfaces axis_net_rx -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 [ipx::get_bus_interfaces axis_net_rx -of_objects [ipx::current_core]]
ipx::associate_bus_interfaces -busif axis_net_rx -clock ap_clk [ipx::current_core]

ipx::add_bus_interface axis_net_tx [ipx::current_core]
set_property interface_mode slave [ipx::get_bus_interfaces axis_net_tx -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 [ipx::get_bus_interfaces axis_net_tx -of_objects [ipx::current_core]]
ipx::associate_bus_interfaces -busif axis_net_tx -clock ap_clk [ipx::current_core]

puts "TEMPORARY: Not packaging reference clock as diff clock due to post-System Linker validate error"


set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} [ipx::current_core]
set_property supported_families { } [ipx::current_core]
set_property auto_family_support_level level_2 [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::save_core [ipx::current_core]
close_project -delete