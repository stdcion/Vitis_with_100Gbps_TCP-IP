# -----------------------------------------------------------------------------
# package_hls_pp_dual_krnl.tcl — упаковать HDL-обёртку + HLS-ядро в один IP
#
# Скопирован с package_hls_dual_echo_krnl.tcl — ядра, которое этим путём прошло
# упаковку, BD и имплементацию (WNS=+0.0167, битстрим собран). Отличия только в
# имени ядра; двусторонняя сверка портов перенесена как есть и здесь особенно
# нужна: у обёртки 160 сигналов ядра плюс своя врезка в axis_net.
#
# ЗАЧЕМ ЭТОТ ШАГ. Остальные HLS-ядра этого репозитория идут в BD напрямую:
# export_hls_ip.tcl делает из .cpp готовый IP, и build_bd.tcl его находит.
# Здесь так нельзя. hls_pp_dual_krnl объявлен ap_ctrl_none и не имеет
# s_axilite (иначе HLS молча защёлкивает скаляры один раз после сброса — см.
# шапку hls_pp_dual_krnl.cpp), поэтому регистры управления держит
# HDL-обёртка. В BD должен попасть IP, содержащий И то, И другое.
#
# Схема ровно как у iperf_krnl (package_iperf_krnl.tcl): создаём проект,
# добавляем HDL, инстанцируем HLS-IP из ip_repo, упаковываем всё как RTL-ядро.
#
# ПОРЯДОК ЗАПУСКА (шаг 2.5, между HLS и BD):
#     make -f Makefile.vivado user_ip   USER_KRNL=hls_pp_dual_krnl BOARD=u200
#     vivado -mode batch -source kernel/user_krnl/hls_pp_dual_krnl/package_hls_pp_dual_krnl.tcl \
#            -tclargs u200
#     make -f Makefile.vivado bd        USER_KRNL=hls_pp_dual_krnl BOARD=u200
#
# ИМЯ IP. Упаковываем под именем hls_pp_dual_krnl, чтобы _find_ipdef в
# build_bd.tcl нашёл его первым же кандидатом (см. proc _find_ipdef —
# он принимает имя ядра или родовое "user_krnl").
#
# ВАЖНО ПРО ДУБЛИКАТЫ. После этого шага в ip_repo_paths оказываются ДВА IP:
# сырое HLS-ядро (hls_pp_dual_krnl из export_hls_ip.tcl) и эта обёртка. Если
# назвать обёртку тем же именем, _find_ipdef честно упадёт с "разрешается
# неоднозначно" — он для этого и написан. Поэтому HLS-ядро внутри
# переименовано в hls_pp_dual_krnl_ip (create_ip -module_name), а наружу
# выставлено имя hls_pp_dual_krnl только у обёртки.
# -----------------------------------------------------------------------------

if {$::argc < 1} {
     puts "ОШИБКА: не задана плата."
     puts "  vivado -mode batch -source package_hls_pp_dual_krnl.tcl -tclargs u200"
     exit 1
}

set BOARD [lindex $::argv 0]
set KRNL  "hls_pp_dual_krnl"

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

# Инстанцируем HLS-ядро под именем hls_pp_dual_krnl_ip — так его называет
# wrapper, и так оно не конфликтует по имени с самой обёрткой.
#
# VLNV задан export_hls_ip.tcl: -vendor user -library kernel -version 1.0.
create_ip -name $KRNL -vendor user -library kernel -version 1.0 \
     -module_name ${KRNL}_ip

# ОБЯЗАТЕЛЬНО: create_ip создаёт только .xci, а RTL модуля — нет. Без генерации
# output products обёртка не эластируется:
#     ERROR: [Synth 8-439] module 'hls_pp_dual_krnl_ip' not found
# (перед этим Vivado предупреждает "IPs are missing output products").
set ip_xci [get_files -all ${KRNL}_ip.xci]
generate_target {synthesis instantiation_template} $ip_xci
export_ip_user_files -of_objects $ip_xci -no_script -sync -force -quiet
puts "output products для ${KRNL}_ip сгенерированы"

set_property top hls_pp_dual_krnl_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Проверяем, что имена портов в обёртке совпадают с портами HLS-IP.
#
# ЗАЧЕМ НЕ synth_design. Сначала здесь стоял `synth_design -rtl`, и он давал
# ЛОЖНЫЙ отказ: "module 'hls_pp_dual_krnl_ip' not found" даже после
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
# обёртки. Здесь 32 AXI-Stream ядра плюс врезка в axis_net -- 160 сигналов,
# и незамеченный неподключённый порт означает молча неработающую шину, которую
# на плате не отличить от «ядро не отвечает». Поэтому проверяются ОБА
# направления, а сознательно неподключаемые порты перечислены явно.
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
     # внутри блока hls_pp_dual_krnl_ip ... );
     set fh [open "$HDL_DIR/hls_pp_dual_krnl_wrapper.sv" r]
     set wrapper_src [read $fh]
     close $fh

     set in_inst 0
     set wired {}
     set missing {}
     foreach line [split $wrapper_src "\n"] {
          if {[regexp {hls_pp_dual_krnl_ip\s+\w+\s*\(} $line]} { set in_inst 1 ; continue }
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
                 src/hdl/hls_pp_dual_krnl_wrapper.sv по списку выше"
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
                 правь src/hdl/hls_pp_dual_krnl_wrapper.sv или ALLOW_UNCONNECTED\
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
#                             "user:kernel:hls_pp_dual_krnl:1.0"
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
set_property description "TCP echo kernel with axis_net timing taps (HLS core + HDL wrapper)" \
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

# ── восемь интерфейсов врезки обязаны быть распознаны ────────────────────────
#
# axis_net_* -- единственные AXI-Stream порты обёртки, которые НЕ идут в
# HLS-ядро (сквозной проход мимо него, см. шапку обёртки). Значит двусторонняя
# сверка портов выше их не касается вовсе: она смотрит только на инстанс
# HLS-ядра. Если Vivado не выведет из имён шинный интерфейс, порты останутся
# отдельными сигналами, connect_bd_intf_net в build_bd.tcl не найдёт пин, и BD
# упадёт -- но упадёт далеко отсюда и с невнятным сообщением про несуществующий
# интерфейс.
#
# Проверяем здесь, где понятно, что случилось. Ждём ровно 8: s/m x tx/rx x a/b.
set net_bifs {}
foreach nm $busifs {
     if {[string match "*axis_net_*" $nm]} { lappend net_bifs $nm }
}
if {[llength $net_bifs] != 8} {
     puts ""
     puts "  Найдено интерфейсов axis_net_*: [llength $net_bifs], ждали 8"
     foreach nm [lsort $net_bifs] { puts "    $nm" }
     puts ""
     puts "  Vivado выводит шинный интерфейс из имён портов:"
     puts "  <имя>_tvalid/_tready/_tdata/_tkeep/_tlast. Если суффиксы не те или"
     puts "  какой-то из пяти отсутствует, интерфейс не соберётся, а порты"
     puts "  останутся россыпью сигналов."
     error "не все врезки axis_net_* распознаны как AXI-Stream — правь имена\
            портов в src/hdl/hls_pp_dual_krnl_wrapper.sv"
}
puts "врезки axis_net_*: все 8 интерфейсов распознаны"

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
puts "АДРЕСНАЯ КАРТА -- ДВЕ ЧАСТИ, И ЭТО ВАЖНО."
puts ""
puts "  0x00..0x50  РЕГИСТРЫ ЯДРА, генерирует HLS."
puts "              Источник истины -- xhls_pp_dual_krnl_hw.h в"
puts "              src/hls/*_ip_proj/sol1/impl/ip/drivers/*/src/."
puts "              Сборка 25.08 дала:"
puts "                0x00 ap_ctrl   0x10 useConn   0x18 basePort"
puts "                0x20 expectedRxByteCnt (64 бита, 0x20+0x24)"
puts "                0x2c portState  0x3c ppState  0x4c notifyCount"
puts "              Руками их не переносить: pp_dual_offsets в jtag_ctrl.tcl"
puts "              читает заголовок сам."
puts ""
puts "  0x100+      РЕГИСТРЫ ОБЁРТКИ, заданы localparam в"
puts "              src/hdl/hls_pp_dual_krnl_wrapper.sv:"
puts "                0x100 fifoRead(R)   0x104 fifoPop(W)"
puts "                0x108 fifoCount(R)  0x10c fifoOverflow(R)"
puts "                0x110 minWords(RW)  0x114 nfCountRx(R)"
puts "                0x118 nfDropRx(R)   0x11c nfCountTx(R)"
puts "                0x120 nfDropTx(R)   0x124 measDropped(R)"
puts "                0x128 fifoClear(W)"
puts ""
puts "  Разделение по addr\[11:8\]: ноль -- ядру, иначе обёртке. Запас"
puts "  четырёхкратный, новые скаляры ядра карту не сдвинут."
puts "=========================================================="
