# -----------------------------------------------------------------------------
# package_hls_dual_echo_krnl.tcl — упаковать HDL-обёртку + HLS-ядро в один IP
#
# ЗАЧЕМ ЭТОТ ШАГ. Остальные HLS-ядра этого репозитория идут в BD напрямую:
# export_hls_ip.tcl делает из .cpp готовый IP, и build_bd.tcl его находит.
# Здесь так нельзя. hls_dual_echo_krnl объявлен ap_ctrl_none и не имеет
# s_axilite (иначе HLS молча защёлкивает скаляры один раз после сброса — см.
# шапку hls_dual_echo_krnl.cpp), поэтому регистры управления держит
# HDL-обёртка. В BD должен попасть IP, содержащий И то, И другое.
#
# Схема ровно как у iperf_krnl (package_iperf_krnl.tcl): создаём проект,
# добавляем HDL, инстанцируем HLS-IP из ip_repo, упаковываем всё как RTL-ядро.
#
# ПОРЯДОК ЗАПУСКА (шаг 2.5, между HLS и BD):
#     make -f Makefile.vivado user_ip   USER_KRNL=hls_dual_echo_krnl BOARD=u200
#     vivado -mode batch -source kernel/user_krnl/hls_dual_echo_krnl/package_hls_dual_echo_krnl.tcl \
#            -tclargs u200
#     make -f Makefile.vivado bd        USER_KRNL=hls_dual_echo_krnl BOARD=u200
#
# ИМЯ IP. Упаковываем под именем hls_dual_echo_krnl, чтобы _find_ipdef в
# build_bd.tcl нашёл его первым же кандидатом (см. proc _find_ipdef —
# он принимает имя ядра или родовое "user_krnl").
#
# ВАЖНО ПРО ДУБЛИКАТЫ. После этого шага в ip_repo_paths оказываются ДВА IP:
# сырое HLS-ядро (hls_dual_echo_krnl из export_hls_ip.tcl) и эта обёртка. Если
# назвать обёртку тем же именем, _find_ipdef честно упадёт с "разрешается
# неоднозначно" — он для этого и написан. Поэтому HLS-ядро внутри
# переименовано в hls_dual_echo_krnl_ip (create_ip -module_name), а наружу
# выставлено имя hls_dual_echo_krnl только у обёртки.
# -----------------------------------------------------------------------------

if {$::argc < 1} {
     puts "ОШИБКА: не задана плата."
     puts "  vivado -mode batch -source package_hls_dual_echo_krnl.tcl -tclargs u200"
     exit 1
}

set BOARD [lindex $::argv 0]
set KRNL  "hls_dual_echo_krnl"

set REPO_ROOT [file normalize [file dirname [info script]]/../../..]

# Part берём из того же device.tcl, что build_bd.tcl и export_hls_ip.tcl —
# чтобы часть/частота не разошлись между шагами.
set DEVICE_TCL "$REPO_ROOT/build/devices/$BOARD/device.tcl"
if {![file exists $DEVICE_TCL]} {
     puts "*** нет $DEVICE_TCL"
     puts "    Его генерирует cmake:"
     puts "        cd build && cmake .. -DFDEV_NAME=$BOARD -DTCP_STACK_EN=1"
     exit 1
}
source $DEVICE_TCL

set KRNL_DIR   "$REPO_ROOT/kernel/user_krnl/$KRNL"
set HDL_DIR    "$KRNL_DIR/src/hdl"
set TMP_PROJ   "$KRNL_DIR/build_pack/pack_proj"
set PACKAGE_DIR "$KRNL_DIR/build_pack/packaged"

# HLS-IP от export_hls_ip.tcl. Путь тот же, что build_bd.tcl добавляет в
# ip_repo_paths (проект лежит в каталоге исходников — HLS резолвит пути от
# каталога проекта).
set HLS_IP_DIRS [glob -nocomplain "$KRNL_DIR/src/hls/*/*/impl/ip"]
if {[llength $HLS_IP_DIRS] == 0} {
     puts "*** не найден IP HLS-ядра."
     puts "    Сначала: make -f Makefile.vivado user_ip USER_KRNL=$KRNL BOARD=$BOARD"
     exit 1
}
if {[llength $HLS_IP_DIRS] > 1} {
     puts "*** найдено несколько каталогов IP HLS-ядра:"
     foreach d $HLS_IP_DIRS { puts "      $d" }
     puts "    Это остатки прошлых сборок — удали лишние и повтори,"
     puts "    иначе неясно, какое ядро попадёт в обёртку."
     exit 1
}
set HLS_IP_DIR [lindex $HLS_IP_DIRS 0]
puts "HLS IP: $HLS_IP_DIR"

file delete -force $TMP_PROJ $PACKAGE_DIR

create_project -force pack_proj $TMP_PROJ -part $DEV_PART

# HDL обёртки: регистры + сам wrapper.
add_files -norecurse [glob "$HDL_DIR/*.v" "$HDL_DIR/*.sv"]

set_property ip_repo_paths [list $HLS_IP_DIR] [current_project]
update_ip_catalog -rebuild

# Инстанцируем HLS-ядро под именем hls_dual_echo_krnl_ip — так его называет
# wrapper, и так оно не конфликтует по имени с самой обёрткой.
#
# VLNV задан export_hls_ip.tcl: -vendor user -library kernel -version 1.0.
create_ip -name $KRNL -vendor user -library kernel -version 1.0 \
     -module_name ${KRNL}_ip

# ОБЯЗАТЕЛЬНО: create_ip создаёт только .xci, а RTL модуля — нет. Без генерации
# output products обёртка не эластируется:
#     ERROR: [Synth 8-439] module 'hls_dual_echo_krnl_ip' not found
# (перед этим Vivado предупреждает "IPs are missing output products").
set ip_xci [get_files -all ${KRNL}_ip.xci]
generate_target {synthesis instantiation_template} $ip_xci
export_ip_user_files -of_objects $ip_xci -no_script -sync -force -quiet
puts "output products для ${KRNL}_ip сгенерированы"

set_property top hls_dual_echo_krnl_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Проверяем, что обёртка действительно эластируется поверх HLS-IP: без этого
# несовпадение имён портов всплыло бы только на этапе синтеза BD, через час.
puts ""
puts "=== проверка иерархии обёртки ==="
synth_design -rtl -name rtl_check -top hls_dual_echo_krnl_wrapper
puts "=== иерархия сходится ==="

ipx::package_project -root_dir $PACKAGE_DIR -vendor user -library kernel \
     -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $PACKAGE_DIR/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
     -directory $PACKAGE_DIR $PACKAGE_DIR/component.xml

set_property name        $KRNL [ipx::current_core]
set_property display_name $KRNL [ipx::current_core]
set_property description "dual-QSFP echo kernel (HLS core + HDL control wrapper)" \
     [ipx::current_core]
set_property core_revision 1 [ipx::current_core]

foreach up [ipx::get_user_parameters] {
     ipx::remove_user_parameter [get_property NAME $up] [ipx::current_core]
}

set_property sdx_kernel true [ipx::current_core]
set_property sdx_kernel_type rtl [ipx::current_core]

ipx::create_xgui_files [ipx::current_core]

# ap_clk / ap_rst_n как clock/reset-интерфейсы, иначе BD не свяжет их
# автоматически и не проставит ASSOCIATED_BUSIF.
ipx::add_bus_interface ap_clk [ipx::current_core]
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 \
     [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:signal:clock:1.0 \
     [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
ipx::add_port_map CLK [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]
set_property physical_name ap_clk [ipx::get_port_maps CLK \
     -of_objects [ipx::get_bus_interfaces ap_clk -of_objects [ipx::current_core]]]

ipx::infer_bus_interface ap_rst_n xilinx.com:signal:reset_rtl:1.0 [ipx::current_core]

# Все AXI-Stream и AXI-Lite интерфейсы должны быть привязаны к ap_clk.
set clkbif [ipx::get_bus_interfaces -of [ipx::current_core] ap_clk]
set assoc  [ipx::add_bus_parameter ASSOCIATED_BUSIF $clkbif]
set busifs {}
foreach bif [ipx::get_bus_interfaces -of_objects [ipx::current_core]] {
     set nm [get_property NAME $bif]
     if {[string match "*axis*" $nm] || [string match "s_axi_control" $nm]} {
          lappend busifs $nm
     }
}
set_property value [join $busifs ":"] $assoc
puts "ASSOCIATED_BUSIF: [join $busifs :]"

ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]

close_project -delete

puts ""
puts "=========================================================="
puts "IP обёртки готов: $PACKAGE_DIR"
puts ""
puts "Дальше:"
puts "  make -f Makefile.vivado bd USER_KRNL=$KRNL BOARD=$BOARD"
puts ""
puts "АДРЕСНАЯ КАРТА (уже сверена с DE_OFF_* в scripts/vivado/jtag_ctrl.tcl,"
puts "источник истины — dual_echo_control_s_axi.v):"
puts "  0x00 ap_ctrl      0x10 enable       0x18 listenPortA  0x20 listenPortB"
puts "  0x30 listenAtt_a  0x34 portState_a  0x38 notify_a"
puts "  0x40 listenAtt_b  0x44 portState_b  0x48 notify_b"
puts "=========================================================="
