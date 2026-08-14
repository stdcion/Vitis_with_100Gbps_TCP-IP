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

# ═════════════════════════════════════════════════════════════════════════════
# ОТЛАДОЧНЫЙ VIO — ВРЕМЕННЫЙ, УДАЛИТЬ ВМЕСТЕ С vio_dbg_inst В ОБЁРТКЕ
# ═════════════════════════════════════════════════════════════════════════════
#
# Восемь проб: четыре 32-битные и четыре однобитные. Обоснование каждой — в
# шапке инстанса в hls_dual_echo_krnl_wrapper.sv; коротко: они различают, где
# именно рвётся цепочка «регистр -> провод -> ядро -> запрос в стек», потому что
# по сгенерированному RTL это уже не различить.
#
# Конфигурация скопирована с vio_network (kernel/network_krnl/network_stack.tcl:238)
# — VIO, который на этом железе читается через vio_dump. Читаться будет так же:
# vio_dump находит все VIO сам, править jtag_ctrl.tcl не нужно.
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
     -module_name vio_dual_echo_dbg
set_property -dict [list \
     CONFIG.C_NUM_PROBE_IN     {8} \
     CONFIG.C_NUM_PROBE_OUT    {0} \
     CONFIG.C_PROBE_IN0_WIDTH  {32} \
     CONFIG.C_PROBE_IN1_WIDTH  {32} \
     CONFIG.C_PROBE_IN2_WIDTH  {32} \
     CONFIG.C_PROBE_IN3_WIDTH  {32} \
     CONFIG.C_PROBE_IN4_WIDTH  {1} \
     CONFIG.C_PROBE_IN5_WIDTH  {1} \
     CONFIG.C_PROBE_IN6_WIDTH  {1} \
     CONFIG.C_PROBE_IN7_WIDTH  {1} \
     CONFIG.Component_Name     {vio_dual_echo_dbg} \
] [get_ips vio_dual_echo_dbg]

set vio_xci [get_files -all vio_dual_echo_dbg.xci]
generate_target {synthesis instantiation_template} $vio_xci
export_ip_user_files -of_objects $vio_xci -no_script -sync -force -quiet
puts "output products для vio_dual_echo_dbg сгенерированы"

set_property top hls_dual_echo_krnl_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Проверяем, что имена портов в обёртке совпадают с портами HLS-IP.
#
# ЗАЧЕМ НЕ synth_design. Сначала здесь стоял `synth_design -rtl`, и он давал
# ЛОЖНЫЙ отказ: "module 'hls_dual_echo_krnl_ip' not found" даже после
# generate_target. В режиме -rtl (elaborate-only) Vivado не разворачивает IP из
# .xci, поэтому чёрный ящик остаётся ненайденным независимо от того, верна
# обёртка или нет. Апстримный package_iperf_krnl.tcl синтез вообще не гоняет.
#
# Вместо этого сверяем имена портов напрямую: список портов IP берём из
# component.xml (источник истины — там же, откуда их видит BD), список
# подключённых портов — из инстанса в обёртке. Это ловит ровно ту ошибку, ради
# которой затевалась проверка, и делает это за секунды вместо минут.
#
# СВЕРКА ДВУСТОРОННЯЯ, И ЭТО ВАЖНО. Сначала проверялось только одно
# направление — «каждый порт, который подключает обёртка, есть у IP». Проверка
# печатала «все 209 портов IP сходятся с обёрткой» и была формально права, но
# фраза вводила в заблуждение: обёртка подключает 171 порт из 209, а про
# остальные 38 проверка молчала, потому что смотрела не в ту сторону.
#
# В этом ядре те 38 оказались безобидны (32 x TSTRB + 6 x _ap_vld, см.
# ALLOW_UNCONNECTED ниже), но опираться на эту проверку предстоит при клонировании
# обёртки под hls_echo_probe_dual_krnl — а там 18 скаляров вместо 3, включая
# triggerGo и четыре таймстемпа. Незамеченный неподключённый порт там — это
# молча неработающая функция, которую на плате будет не отличить от «ядро не
# реагирует». Поэтому теперь проверяются ОБА направления, а сознательно
# неподключаемые порты перечислены явно.
puts ""
puts "=== сверка имён портов: обёртка против HLS-IP ==="

set ip_ports {}
foreach p [ipx::get_ports -of_objects \
               [ipx::open_core -quiet "$HLS_IP_DIR/component.xml"]] {
     lappend ip_ports [get_property NAME $p]
}
ipx::unload_core -quiet "$HLS_IP_DIR/component.xml"

if {[llength $ip_ports] == 0} {
     puts "  ПРЕДУПРЕЖДЕНИЕ: не удалось прочитать порты из component.xml,"
     puts "  сверка пропущена. Несовпадение всплывёт на синтезе BD."
} else {
     # Порты, которые обёртка подключает к инстансу HLS-ядра: строки вида
     #     .s_axis_udp_rx_a_tvalid ( ... ),
     # внутри блока hls_dual_echo_krnl_ip ... );
     set fh [open "$HDL_DIR/hls_dual_echo_krnl_wrapper.sv" r]
     set wrapper_src [read $fh]
     close $fh

     set in_inst 0
     set wired {}
     set missing {}
     foreach line [split $wrapper_src "\n"] {
          if {[regexp {hls_dual_echo_krnl_ip\s+\w+\s*\(} $line]} { set in_inst 1 ; continue }
          if {$in_inst && [regexp {^\s*\);} $line]}              { set in_inst 0 ; continue }
          if {!$in_inst} { continue }
          if {![regexp {^\s*\.(\w+)\s*\(} $line -> port]} { continue }
          lappend wired $port
          if {[lsearch -exact $ip_ports $port] < 0} {
               lappend missing $port
          }
     }

     # ── направление 1: обёртка подключает порт, которого у IP нет ───────────
     #
     # Классическая опечатка в имени. Ловилось и раньше.
     if {[llength $missing] > 0} {
          puts ""
          puts "  Портов нет у IP ([llength $missing]):"
          foreach p $missing { puts "    .$p" }
          puts ""
          puts "  Реальные порты IP (первые 40 из [llength $ip_ports]):"
          foreach p [lrange $ip_ports 0 39] { puts "    $p" }
          puts ""
          error "имена портов в обёртке не совпадают с HLS-IP — правь\
                 src/hdl/hls_dual_echo_krnl_wrapper.sv по списку выше"
     }

     # ── направление 2: у IP есть порт, который обёртка не подключает ────────
     #
     # Это направление раньше не проверялось вовсе. Сознательно неподключаемые
     # порты — здесь, с обоснованием на каждый шаблон; всё остальное считается
     # ошибкой.
     #
     #   *_TSTRB   — pkt512 это ap_axiu<512,0,0,0>, HLS выдаёт strb на каждый
     #               из 32 потоков. TOE его не смотрит, апстримный iperf_role.sv
     #               тоже не подключает. Вход останется висеть, синтез его
     #               оптимизирует.
     #   *_ap_vld  — строб «значение записано в этом такте» у телеметрии. Читать
     #               его не нужно: HLS держит значение в теневом регистре
     #               *_preg и переигрывает его в остальных такстах (проверено в
     #               сгенерированном RTL: dual_echo_listen.v:345,348 для
     #               portState, :292 для listenAttempts, rx_notify.v:318 для
     #               notifyCount). Поэтому обёртка читает провод данных
     #               напрямую, и это корректно.
     set ALLOW_UNCONNECTED {
          {_TSTRB$}
          {_ap_vld$}
     }

     set unconnected {}
     set allowed_cnt 0
     foreach p $ip_ports {
          if {[lsearch -exact $wired $p] >= 0} { continue }
          set ok 0
          foreach pat $ALLOW_UNCONNECTED {
               if {[regexp $pat $p]} { set ok 1 ; break }
          }
          if {$ok} { incr allowed_cnt } else { lappend unconnected $p }
     }

     if {[llength $unconnected] > 0} {
          puts ""
          puts "  У IP есть порты, которые обёртка НЕ подключает ([llength $unconnected]):"
          foreach p $unconnected { puts "    $p" }
          puts ""
          puts "  Каждый такой порт — это либо забытый провод (функция молча не"
          puts "  работает, а на плате это выглядит как «ядро не реагирует»),"
          puts "  либо порт, который не нужен сознательно. Во втором случае"
          puts "  добавь шаблон в ALLOW_UNCONNECTED выше — С ОБОСНОВАНИЕМ,"
          puts "  почему его можно не подключать."
          puts ""
          error "обёртка не подключает [llength $unconnected] портов HLS-IP —\
                 правь src/hdl/hls_dual_echo_krnl_wrapper.sv или ALLOW_UNCONNECTED\
                 в этом скрипте"
     }

     puts "  портов у IP:            [llength $ip_ports]"
     puts "  подключено обёрткой:    [llength $wired]"
     puts "  сознательно не нужны:   $allowed_cnt (TSTRB, _ap_vld)"
     puts "  сверка двусторонняя: лишних и забытых портов нет"
}

ipx::package_project -root_dir $PACKAGE_DIR -vendor user -library kernel \
     -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $PACKAGE_DIR/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
     -directory $PACKAGE_DIR $PACKAGE_DIR/component.xml

# ИМЯ ОБЁРТКИ ДОЛЖНО ОТЛИЧАТЬСЯ ОТ ИМЕНИ HLS-IP.
#
# Сначала здесь стояло просто $KRNL, и упаковка падала:
#     ERROR: [IP_Flow 19-907] Component circularly references subcore
#                             "user:kernel:hls_dual_echo_krnl:1.0"
# HLS-IP внутри обёртки имеет ровно этот VLNV (его задал export_hls_ip.tcl:
# -vendor user -library kernel), поэтому присвоить то же имя обёртке — значит
# объявить, что она ссылается на саму себя. Переименования внутреннего МОДУЛЯ
# (create_ip -module_name ..._ip) для этого недостаточно: конфликтует VLNV
# ядра, а не имя инстанса.
#
# Суффикс _wrapper. build_bd.tcl найдёт его без правок: _find_ipdef принимает
# список альтернатив и вызывается как [_find_ipdef $USER_KRNL user_krnl] —
# добавляем сюда третьим кандидатом (см. правку в build_bd.tcl).
set WRAP_NAME "${KRNL}_wrapper"

set_property name        $WRAP_NAME [ipx::current_core]
set_property display_name $WRAP_NAME [ipx::current_core]
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
puts "  имя IP: $WRAP_NAME  (build_bd.tcl ищет его первым кандидатом)"
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
