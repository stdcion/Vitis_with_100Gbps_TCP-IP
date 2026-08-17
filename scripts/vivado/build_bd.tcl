# -----------------------------------------------------------------------------
# build_bd.tcl — блок-дизайн для Vivado-флоу (без XRT-шелла)
#
# Заменяет то, что в Vitis делал линковщик v++: инстанцирует ядра, соединяет
# их, добавляет обвязку, которую раньше давал шелл (клоки, сбросы, память,
# GT-порты), и управление через JTAG вместо PCIe/XRT.
#
# Запуск (проще через make, см. Makefile.vivado):
#     vivado -mode batch -source scripts/vivado/build_bd.tcl -tclargs <user_krnl> <плата> [num_qsfp]
#
# Первые два аргумента ОБЯЗАТЕЛЬНЫ. Дефолтов нет намеренно: забытый аргумент
# собирал бы не то ядро молча, а следом шла бы часовая имплементация.
# Третий аргумент (num_qsfp, по умолчанию 2) — сколько независимых каналов
# cmac_krnl/network_krnl инстанцировать (QSFP0, QSFP1, ...).
#
# USER_KRNL инстанцируется в одном из двух режимов, определяется автоматически
# по наличию kernel/user_krnl/<user_krnl>/config_sp_<user_krnl>_dual.txt:
#   - per-port (файла нет): N экземпляров ${USER_KRNL}_1..N, по одному на
#     каждый network_krnl_N — независимые каналы без связи между собой
#     (hls_echo_krnl, iperf_krnl, ...);
#   - dual (файл есть): РОВНО ОДИН экземпляр ${USER_KRNL}_1 с портами _a/_b,
#     подключёнными к network_krnl_1 и network_krnl_2 — для ядер, которым
#     нужно видеть оба канала сразу (relay/gateway между портами). Требует
#     NUM_QSFP>=2.
#
# Что должно быть готово до запуска:
#   1. build/devices/<плата>/device.tcl — параметры платы, генерирует cmake
#      (cd build && cmake .. -DFDEV_NAME=u200 -DTCP_STACK_EN=1)
#   2. packaged_kernel_cmac_krnl_hw_*    — IP от make (Vitis-флоу его уже собрал)
#   3. packaged_kernel_network_krnl_hw_* — то же
#   4. IP пользовательского ядра из vitis_hls export_design -format ip_catalog
#      (Vitis-флоу его НЕ создаёт — там v++ -c делает сразу .xo)
#
# ВАЖНО: скрипт доводит дизайн до валидного BD с управлением по JTAG, но
# участки, помеченные TODO, требуют решений, которые нельзя принять, не видя
# поведения железа: параметры CMAC (какой GT-квад, FEC), конфигурация DDR4 и
# распределение по SLR. Они помечены явно, а не оставлены молча.
# -----------------------------------------------------------------------------

if {$::argc < 2} {
     puts "ОШИБКА: нужно два аргумента: <user_krnl> <плата>"
     puts ""
     puts "  vivado -mode batch -source scripts/vivado/build_bd.tcl \\"
     puts "         -tclargs hls_echo_krnl u200"
     puts ""
     puts "Проще: make -f Makefile.vivado bd USER_KRNL=hls_echo_krnl BOARD=u200"
     exit 1
}

set USER_KRNL [lindex $::argv 0]
set BOARD     [lindex $::argv 1]

# Сколько независимых QSFP+CMAC+network_krnl+USER_KRNL каналов собирать.
# Дефолт 2 — конечная цель дизайна (двупортовый гейтвей), см. заголовок Makefile.vivado.
# NUM_QSFP=1 воспроизводит старое поведение (только QSFP0).
set NUM_QSFP 2
if {$::argc >= 3} {
     set NUM_QSFP [lindex $::argv 2]
}
if {$NUM_QSFP != 1 && $NUM_QSFP != 2} {
     error "NUM_QSFP=$NUM_QSFP не поддержан: package_cmac_krnl.tcl знает только\
            координаты GT-квадов для QSFP0/QSFP1 (0..1) на u200. См. задачу\
            расширения в kernel/cmac_krnl/package_cmac_krnl.tcl, если нужно больше."
}

set REPO_ROOT   [file normalize [file dirname [info script]]/../..]
set CONFIG_SP   "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/config_sp_$USER_KRNL.txt"

# Режим USER_KRNL определяется по наличию config_sp_<user_krnl>_dual.txt:
#   dual (один инстанс ${USER_KRNL}_1, порты _a/_b -> оба network_krnl) —
#     для ядер, которым нужно видеть оба канала одновременно (реальный
#     гейтвей/relay между портами, см. dual-qsfp-gateway-architecture);
#   per-port (N инстансов ${USER_KRNL}_1..N, как раньше) — для ядер без
#     связи между каналами (hls_echo_krnl, iperf_krnl и т.п.), а также
#     единственный вариант, поддерживающий NUM_QSFP=1.
set CONFIG_SP_DUAL "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/config_sp_${USER_KRNL}_dual.txt"
set USER_KRNL_DUAL [file exists $CONFIG_SP_DUAL]

if {$USER_KRNL_DUAL && $NUM_QSFP < 2} {
     error "$USER_KRNL — dual-ядро (найден $CONFIG_SP_DUAL), а NUM_QSFP=$NUM_QSFP.\
            Dual-ядру нужны оба network_krnl (порты _a/_b) — собери с NUM_QSFP>=2\
            либо используй per-port ядро для отладки одного линка."
}

# Артефакты — по плате и ядру: .bit жёстко привязан к part, а HLS-IP ядра ещё и
# к периоду. Без разделения сборка под другую плату затирала бы предыдущую, и в
# ls было бы не видно, для какой платы лежит битстрим.
#
# Внутри build/, а не рядом: снос build/ (cmake-кеш) обязан уносить и битстримы.
# После пересборки ip_repo прежний битстрим собран из другого стека — он выглядит
# валидным, но им нельзя пользоваться.
set PROJ_NAME   "net_vivado"
set PROJ_DIR    "$REPO_ROOT/build/vivado/$BOARD/$USER_KRNL"
set BD_NAME     "net_bd"

puts "user-ядро: $USER_KRNL"

# --- параметры платы ----------------------------------------------------------
#
# Всё, что зависит от платы, приходит из devices/<плата>/device.tcl.in через
# cmake: part, board part, банк памяти, SLR для CMAC, частота. Часть значений
# cmake подставляет из блока FDEV_NAME в CMakeLists.txt, то есть реестр плат
# один и Vivado-флоу не может разъехаться с XRT-флоу.
#
# Сгенерированный файл лежит в build/, а не рядом с шаблоном.
set DEVICE_DIR "$REPO_ROOT/devices/$BOARD"
set DEVICE_TCL "$REPO_ROOT/build/devices/$BOARD/device.tcl"

if {![file exists $DEVICE_TCL]} {
     error "нет $DEVICE_TCL\n\
            Его генерирует cmake. Прогони:\n\
            \    cd build && cmake .. -DFDEV_NAME=$BOARD -DTCP_STACK_EN=1\n\
            Если платы '$BOARD' нет в devices/ — см. devices/README.md"
}
source $DEVICE_TCL

# device.tcl обязан задать всё из этого списка. Проверяем разом, а не по факту
# обращения: иначе неполный шаблон проявится где-нибудь в середине сборки
# невнятной ошибкой Vivado.
foreach v {DEV_PART DEV_BOARD_PART DEV_BOARD_DIR DEV_MEM_TYPE DEV_MEM_IF
           DEV_MEM_CLK DEV_CMAC_SLR DEV_FREQ_MHZ DEV_PINS_XDC} {
     if {![info exists $v]} {
          error "device.tcl не задаёт $v — проверь devices/$BOARD/device.tcl.in"
     }
}

# HBM (u280/u50/u55c) требует другого IP с другими портами — это отдельная
# ветка кода, а не другое значение параметра. Лучше сказать сразу.
if {$DEV_MEM_TYPE ne "ddr4"} {
     error "DEV_MEM_TYPE=$DEV_MEM_TYPE не поддержан: build_bd.tcl умеет только ddr4.\
            Для HBM нужна отдельная ветка инстанцирования памяти."
}

set PART        $DEV_PART
set BOARD_PART  $DEV_BOARD_PART
set PINS_XDC    "$DEVICE_DIR/$DEV_PINS_XDC"
set BOARD_REPO  "$DEVICE_DIR/board_files"

puts "плата:     $BOARD ($DEV_PART)"
puts "память:    $DEV_MEM_IF, клок $DEV_MEM_CLK"
puts "CMAC SLR:  $DEV_CMAC_SLR"
puts "частота:   $DEV_FREQ_MHZ МГц"

foreach f [list $PINS_XDC "$BOARD_REPO/$DEV_BOARD_DIR/board.xml"] {
     if {![file exists $f]} { error "нет файла платы: $f" }
}

source "$REPO_ROOT/scripts/vivado/gen_axis_connect.tcl"

# --- проект -------------------------------------------------------------------

# DDR4 IP конфигурируется через board interfaces (C0_CLOCK_BOARD_INTERFACE,
# C0_DDR4_BOARD_INTERFACE): так он сам берёт ~150 пинов DDR4 и параметры чипа
# из board file, вместо того чтобы прописывать их вручную в XDC.
#
# Board file лежит в репозитории (devices/<плата>/board_files), поэтому сборка
# не зависит от того, установлены ли board files в Vivado — в этой установке их
# нет. Файлы извлечены из hw.xsa платформы; см. devices/README.md.
#
# repoPaths задаётся ДО create_project — иначе плата не попадёт в каталог
# проекта.
set_param board.repoPaths [list $BOARD_REPO]

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
            Проверь, что $BOARD_REPO/$DEV_BOARD_DIR/board.xml на месте."
}
puts "board part: [get_property board_part [current_project]]"

# Проверяем, что интерфейсы платы реально видны: без них DDR4 придётся
# конфигурировать вручную (~150 пинов + параметры чипа), и лучше узнать об этом
# здесь, а не по невнятной ошибке DDR4 IP.
foreach need [list $DEV_MEM_IF $DEV_MEM_CLK] {
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
# IP пользовательского ядра.
#
# Сырое HLS-IP от export_hls_ip.tcl нужно ВСЕГДА. Проект HLS лежит в каталоге
# исходников ядра (HLS резолвит пути от каталога проекта — см. комментарий в
# export_hls_ip.tcl).
set raw_hls [glob -nocomplain "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/src/hls/*/*/impl/ip"]
foreach d $raw_hls {
     lappend ip_repos $d
}

# Ядро с HDL-обёрткой (есть src/hdl/ и package_<krnl>.tcl) даёт ВТОРОЙ IP —
# саму обёртку, и в BD инстанцируется именно она (см. _find_ipdef ниже, где
# ${USER_KRNL}_wrapper стоит первым кандидатом).
#
# Зачем обёртка: free-running ядро (ap_ctrl_none) не может иметь s_axilite —
# UG1393 это запрещает, а HLS молча защёлкивает скаляры один раз после сброса,
# и запись по JTAG до логики не доходит. Регистры поэтому живут в HDL (как в
# iperf_krnl), а сюда попадает обёртка вокруг HLS-ядра.
#
# ВАЖНО: сырое HLS-IP из ip_repos убирать НЕЛЬЗЯ, хотя соблазн есть — кажется,
# что обёртка самодостаточна. Она не самодостаточна: внутри неё лежит ССЫЛКА на
# subcore user:kernel:$USER_KRNL:1.0, а не его копия. Без этого пути BD
# собирается и даже соединяет все интерфейсы, но генерация IP падает:
#     CRITICAL WARNING [IP_Flow 19-4065] The definition for subcore dependency
#                      'user:kernel:hls_dual_echo_krnl:1.0' is not available
#     ERROR [IP_Flow 19-98] Generation of the IP CORE failed
# (а ещё раньше, на create_bd_cell, проскакивает IP_Flow 19-3571 "IP ...
# is restricted" — единственный признак на шаге 3, легко пропустить).
#
# Конфликта имён при этом нет: обёртка упакована как ${USER_KRNL}_wrapper
# именно для того, чтобы оба IP сосуществовали в каталоге.
set USER_PACKAGED "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/build_pack/packaged"
if {[file exists "$USER_PACKAGED/component.xml"]} {
     puts "user-ядро: HDL-обёртка (build_pack/packaged) + HLS-IP как subcore"
     lappend ip_repos $USER_PACKAGED
} elseif {[llength [glob -nocomplain \
               "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/src/hdl/*.v" \
               "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/src/hdl/*.sv"]] > 0} {
     # Обёртка нужна, но не собрана — падаем здесь, а не через час на плате,
     # где симптомом будет "ядро не видит регистры управления".
     #
     # ПРОВЕРКА ПО ФАЙЛАМ, А НЕ ПО КАТАЛОГУ. Раньше стояло
     # `file isdirectory .../src/hdl`, и это ломалось: у hls_dual_echo_krnl
     # обёртку удалили (ядро перешло на s_axilite + ap_ctrl_hs, регистры
     # генерирует HLS), но в src/hdl/ осталась tb/ с тестбенчами. Скрипт считал
     # обёртку обязательной и валил шаг bd на ядре, которому она не нужна.
     #
     # Глоб только по верхнему уровню src/hdl/, без tb/ — тестбенчи в BD не идут.
     # То же исправление в Makefile.vivado, переменная HAS_WRAPPER.
     puts ""
     error "у $USER_KRNL есть src/hdl/*.v или *.sv, но нет\
            build_pack/packaged/component.xml. Пропущен шаг 2.5 (упаковка обёртки):\
            make -f Makefile.vivado pack USER_KRNL=$USER_KRNL BOARD=$BOARD\
            Без него в BD попадёт сырое HLS-ядро без регистров управления,\
            и хост не сможет задать порты."
} else {
     puts "user-ядро: сырое HLS-IP (обёртки нет)"
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
          if {[llength $hits] > 1} {
               # Раньше здесь молча бралось [lindex $hits 0]. Именно так
               # два пакета cmac_krnl (QSFP0 и QSFP1) с одинаковым VLNV
               # сводились к одному IP: Vivado печатал "Duplicate IP found"
               # предупреждением, а BD получал координаты GT-квада порта 0
               # для ОБОИХ каналов. Неоднозначность здесь — всегда ошибка
               # сборки, а не повод угадывать.
               puts ""
               puts "Кандидаты для '$cand':"
               foreach h $hits { puts "  $h" }
               error "IP '$cand' разрешается неоднозначно ([llength $hits] совпадений).\
                      Обычно это два пакета с одинаковым VLNV в ip_repo_paths —\
                      проверь, что каждый QSFP-порт упакован под своим именем\
                      (см. kernel/cmac_krnl/package_cmac_krnl.tcl). Старые\
                      packaged_kernel_* от прошлых сборок тоже дают дубликаты:\
                      удали их и пересобери."
          }
          if {[llength $hits] == 1} {
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

# У каждого QSFP-порта СВОЙ cmac_krnl: core_selection/group_selection (какой
# CMACE4 и какие GT-каналы) зашиты в XDC упакованного IP, параметром их не
# переопределить. Порт 0 — "cmac_krnl", порт N>0 — "cmac_krnl_qsfpN"
# (см. kernel/cmac_krnl/package_cmac_krnl.tcl).
#
# network_krnl, наоборот, к физическим сайтам не привязан, поэтому один VLNV
# на все каналы — это правильно, а не недосмотр.
set VLNV_CMAC [list]
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     set qsfp_idx [expr {$n - 1}]
     if {$qsfp_idx == 0} {
          lappend VLNV_CMAC [_find_ipdef cmac_krnl]
     } else {
          lappend VLNV_CMAC [_find_ipdef cmac_krnl_qsfp${qsfp_idx}]
     }
}
set VLNV_NET  [_find_ipdef network_krnl]
# Кандидаты по порядку:
#   ${USER_KRNL}_wrapper — упакованная HDL-обёртка (шаг 2.5). ПЕРВЫМ, потому что
#        когда обёртка есть, в BD должна идти именно она, а не сырое ядро.
#        Имя с суффиксом, а не $USER_KRNL: у HLS-IP внутри обёртки тот же VLNV,
#        и совпадение имён дало бы circular reference при упаковке
#        (IP_Flow 19-907).
#   $USER_KRNL           — сырое HLS-IP для ядер без обёртки (hls_echo_krnl).
#   user_krnl            — родовое имя, под которым упакованы апстримные ядра
#        (iperf_krnl, scatter_krnl) через package_*.tcl.
set VLNV_USER [_find_ipdef ${USER_KRNL}_wrapper $USER_KRNL user_krnl]

# Разные каналы обязаны прийти из разных пакетов — иначе два CMAC снова
# нацелятся на один GT-квад. Проверяем явно: молчаливое совпадение здесь
# стоит часа имплементации и нерабочего второго порта.
if {[llength [lsort -unique $VLNV_CMAC]] != [llength $VLNV_CMAC]} {
     error "cmac_krnl для разных QSFP разрешился в один и тот же VLNV: $VLNV_CMAC.\
            Пересобери ядра (make -f Makefile.vivado xo) — пакеты портов должны\
            иметь разные имена."
}

# cmac_krnl_N/network_krnl_N — всегда по одному на канал (N=1..NUM_QSFP).
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     create_bd_cell -type ip -vlnv [lindex $VLNV_CMAC [expr {$n - 1}]] cmac_krnl_$n
     create_bd_cell -type ip -vlnv $VLNV_NET  network_krnl_$n
}

# ${USER_KRNL} — режим зависит от USER_KRNL_DUAL (см. определение выше):
#   dual: РОВНО ОДИН экземпляр ${USER_KRNL}_1, config_sp_..._dual.txt сам
#         содержит sc= для обоих network_krnl (порты _a/_b на стороне ядра).
#   per-port: N экземпляров ${USER_KRNL}_1..N, под них написаны
#         config_sp_${USER_KRNL}.txt (N=1) и config_sp_${USER_KRNL}_N.txt (N>=2).
if {$USER_KRNL_DUAL} {
     create_bd_cell -type ip -vlnv $VLNV_USER ${USER_KRNL}_1

     puts ""
     puts "=== AXI-Stream соединения (dual) из [file tail $CONFIG_SP_DUAL] ==="
     axis_connect_from_config $CONFIG_SP_DUAL
} else {
     for {set n 1} {$n <= $NUM_QSFP} {incr n} {
          create_bd_cell -type ip -vlnv $VLNV_USER ${USER_KRNL}_$n
     }

     for {set n 1} {$n <= $NUM_QSFP} {incr n} {
          if {$n == 1} {
               set cfg $CONFIG_SP
          } else {
               set cfg "$REPO_ROOT/kernel/user_krnl/$USER_KRNL/config_sp_${USER_KRNL}_$n.txt"
          }
          puts ""
          puts "=== AXI-Stream соединения из [file tail $cfg] ==="
          axis_connect_from_config $cfg
     }
}

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
# hls_echo_krnl/hls_dual_echo_krnl обходятся без них — порт слушания зашит
# константой, управлять нечем. Проверяем по ${USER_KRNL}_1 — при per-port все
# каналы инстанцированы из одного VLNV, наличие порта одинаково для всех N;
# при dual это и есть единственный экземпляр.
set USER_HAS_CTRL [expr {[llength [get_bd_intf_pins -quiet ${USER_KRNL}_1/s_axi_control]] > 0}]

# Сколько экземпляров ${USER_KRNL} претендуют на s_axi_control: при dual —
# всегда 1 (единственный инстанс), при per-port — NUM_QSFP.
set n_user_instances [expr {$USER_KRNL_DUAL ? 1 : $NUM_QSFP}]

# Мастера: по network_krnl_N на каждый канал, ECC-регистры DDR4
# (C0_DDR4_S_AXI_CTRL, см. секцию памяти ниже) и, если есть, s_axi_control
# каждого экземпляра ${USER_KRNL}.
set n_mi [expr {$NUM_QSFP + ($USER_HAS_CTRL ? $n_user_instances : 0) + 1}]
if {$USER_HAS_CTRL} {
     set user_ctrl_desc "$n_user_instances x ${USER_KRNL}"
} else {
     set user_ctrl_desc "без ${USER_KRNL}"
}
puts "ctrl_interconnect: $n_mi мастеров ($NUM_QSFP x network_krnl, $user_ctrl_desc s_axi_control, DDR4 ECC)"

# NUM_CLKS=2: управляющие порты ядер на ap_clk, ECC-регистры DDR4 — на ui_clk
# контроллера.
set_property -dict [list \
     CONFIG.NUM_SI {1} \
     CONFIG.NUM_MI $n_mi \
     CONFIG.NUM_CLKS {2} \
] [get_bd_cells ctrl_interconnect]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] \
                    [get_bd_intf_pins ctrl_interconnect/S00_AXI]

# Мастера нумеруются по порядку: сначала все network_krnl_N, потом (если есть)
# экземпляры ${USER_KRNL} — так адреса, которые сверяются с jtag_ctrl.tcl
# ниже, предсказуемы и не зависят от порядка обхода BD.
set mi_idx 0
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/[format "M%02d_AXI" $mi_idx]] \
                         [get_bd_intf_pins network_krnl_$n/s_axi_control]
     incr mi_idx
}
if {$USER_HAS_CTRL} {
     for {set n 1} {$n <= $n_user_instances} {incr n} {
          connect_bd_intf_net [get_bd_intf_pins ctrl_interconnect/[format "M%02d_AXI" $mi_idx]] \
                              [get_bd_intf_pins ${USER_KRNL}_$n/s_axi_control]
          incr mi_idx
     }
}
# Оставшийся мастер (mi_idx) — DDR4 ECC, подключается в секции памяти ниже.
set MI_DDR4_ECC $mi_idx

# --- клоки и сбросы -----------------------------------------------------------
#
# Шелл давал ap_clk (kernel clock) и free-running clock готовыми. Здесь строим
# сами из 300 МГц входа:
#   clk_out1 = ap_clk ядер, DEV_FREQ_MHZ из devices/<плата>/device.tcl.in.
#              НЕ 200 из Makefile: те 200 МГц никогда не достигались, v++ сам
#              снижал частоту до 192.9. На 5 нс вышло WNS=-0.616 (критический
#              путь — finalize_ipv4_checksum_32 внутри network_krnl), предел
#              ~178 МГц. export_hls_ip.tcl берёт DEV_PERIOD_NS из того же файла,
#              так что частота задана в одном месте и разойтись не может.
#   clk_out2 = 100 МГц — free-running для CMAC; в шелле это был
#              ulp_m_aclk_freerun_ref_00 (см. ветку frc1 в post_sys_link.tcl.in).

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
     CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
     CONFIG.PRIM_IN_FREQ {300.000} \
     CONFIG.CLKOUT1_USED {true} \
     CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $DEV_FREQ_MHZ \
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

# ap_clk всех ядер (во всех каналах) + управляющая шина — на DEV_FREQ_MHZ.
foreach pin {jtag_axi_0/aclk ctrl_interconnect/aclk} {
     connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $pin]
}
foreach pin {jtag_axi_0/aresetn ctrl_interconnect/aresetn} {
     connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins $pin]
}
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     # ${USER_KRNL}_$n при dual-режиме существует только для n=1 (см.
     # n_user_instances выше) — остальные каналы дают ему клок отдельным
     # проходом ниже не нужно, его ap_clk уже подключён на n=1.
     set cells [list cmac_krnl_$n network_krnl_$n]
     if {$n <= $n_user_instances} {
          lappend cells ${USER_KRNL}_$n
     }
     foreach cell $cells {
          connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]             [get_bd_pins $cell/ap_clk]
          connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn]     [get_bd_pins $cell/ap_rst_n]
     }
     # free-running clock для CMAC — имя пина взято из scripts/post_sys_link.tcl.in,
     # где шелл подключал к нему ulp_m_aclk_freerun_ref_00. Общий clk_wiz_0/clk_out2
     # на все каналы — это не отдельный клок на порт, а один и тот же 100 МГц.
     connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins cmac_krnl_$n/clk_gt_freerun]
}

# --- GT / QSFP0, QSFP1, ... ----------------------------------------------------
#
# Соответствие пинов cmac_krnl и портов платформы — из post_sys_link.tcl.in,
# ветка io_clk_gt2 (U200): io_gt_qsfp<n>_00 + io_clk_qsfp<n>_refclka_00.
# Пины кристалла — в u200_pins.xdc (qsfp0_* и qsfp1_*).
#
# Индексация портов платы (qsfp0, qsfp1, ...) начинается с 0, а имена ячеек
# BD (cmac_krnl_1, cmac_krnl_2, ...) — с 1: канал N использует физический
# порт qsfp<N-1>, что совпадает с QSFP_IDX в package_cmac_krnl.tcl/gen_xo.tcl.
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     set qsfp_idx [expr {$n - 1}]
     set qsfp_port "qsfp${qsfp_idx}"

     create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 $qsfp_port
     connect_bd_intf_net [get_bd_intf_ports $qsfp_port] \
                         [get_bd_intf_pins cmac_krnl_$n/gt_serial_port]

     create_bd_port -dir I ${qsfp_port}_refclk_p
     create_bd_port -dir I ${qsfp_port}_refclk_n
     connect_bd_net [get_bd_ports ${qsfp_port}_refclk_p] [get_bd_pins cmac_krnl_$n/gt_refclk0_p]
     connect_bd_net [get_bd_ports ${qsfp_port}_refclk_n] [get_bd_pins cmac_krnl_$n/gt_refclk0_n]

     # --- сайдбенд QSFP: держим трансивер во включённом состоянии -------------
     #
     # Без этого модуль остаётся в том состоянии, которое задают подтяжки платы,
     # а они не описаны НИ В ОДНОМ доступном документе (UG1289 только называет
     # сигналы, board file и официальный XDC дают пины и полярности, но не
     # подтяжки). Симптом при неудачных подтяжках — stat_rx_aligned = 0 при
     # полностью исправной прошивке, то есть худший вид отказа: ищешь в логике,
     # а причина в том, что оптика выключена.
     #
     #     LPMODE  = 0  -> полная мощность (оптика включена)
     #     RESETL  = 1  -> НЕ в сбросе
     #     MODSELL = 0  -> модуль выбран для I2C
     #
     # ВНИМАНИЕ: по LPMODE документация AMD сама себе противоречит, и цена
     # ошибки — не поднявшийся линк на исправной прошивке. Поэтому источники
     # разобраны здесь целиком, чтобы никто (включая нас) не «исправил» обратно:
     #
     #   * SFF-8679 (стандарт QSFP, на него ссылается сам UG1289): LPMode —
     #     "input signal from the host operating with ACTIVE HIGH logic ...
     #     put modules into a low power mode WHEN HIGH", внутри модуля подтянут
     #     к Vcc. То есть на разъёме: 1 = low-power, 0 = полная мощность.
     #
     #   * Официальный alveo XDC (страница продукта U200/U250): "Active High
     #     Control output ... to put the device in low power mode (Optics Off)" —
     #     совпадает со стандартом.
     #
     #   * Преcет заводского шелла (hw.xsa: board/1.3/preset.xml,
     #     qsfp{0,1}_lowspeed_preset, C_DOUT_DEFAULT=0x2): LPMODE=0.
     #
     #   * Живое железо: у коллеги на рабочей прошивке LPMODE=0.
     #
     #   * UG1289 Table 10 — ЕДИНСТВЕННЫЙ источник, говорящий иначе:
     #     "Active-Low, Low Power Mode Enable. Must be High for normal
     #     operation." Эта строка противоречит сама себе (если enable
     #     active-low, то High как раз и есть нормальный режим — но тогда
     #     "Active-Low" описывает не то, что подразумевает стандарт).
     #     Вероятна опечатка в документе; 4:1 не в его пользу.
     #
     # RESETL и MODSELL расхождений не имеют: active-low во всех источниках.
     #     RESETL  = 1 -> не в сбросе
     #     MODSELL = 0 -> модуль выбран
     # UG1289 Table 10 называет MODSELL просто "Module Select" без пояснений;
     # что именно он выбирает, написано в официальном alveo XDC: "Active Low
     # Enable output from FPGA to QSFP Module to select device for I2C Sideband
     # Communication". По стандарту QSFP это и есть выбор модуля для
     # двухпроводного интерфейса управления, когда на шине их несколько.
     #
     # Значение 0 взято НЕ из этого рассуждения, а с рабочего железа коллеги.
     # Рассуждение приведено только чтобы понимать, что делает сигнал.
     #
     # Пины сверены по четырём источникам и совпадают везде: UG1289 Table 10,
     # part0_pins.xml (qsfp{N}_lowspeed_0..2), официальный alveo XDC,
     # OpenNIC constr/au200/pins.xdc.
     #
     # MODPRSL (BE20) и INTL (BE21) НЕ подключаем: по UG1289 это Input, их
     # драйвит трансивер (в шелле TRI=1). Объявить выходами — два драйвера на
     # линии; читать без I2C-обвязки незачем.
     foreach {sig val} {lpmode 0 resetl 1 modsell 0} {
          set cell "${qsfp_port}_${sig}_const"
          create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 $cell
          set_property -dict [list \
               CONFIG.CONST_WIDTH {1} \
               CONFIG.CONST_VAL   $val \
          ] [get_bd_cells $cell]

          create_bd_port -dir O ${qsfp_port}_${sig}
          connect_bd_net [get_bd_pins $cell/dout] [get_bd_ports ${qsfp_port}_${sig}]
     }
     puts "  ${qsfp_port}: lpmode=0 resetl=1 modsell=0 (SFF-8679 + шелл + железо)"
}

# --- память для TCP session tables -------------------------------------------
#
# network_krnl имеет два мастера m00_axi/m01_axi (512 бит) — это таблицы сессий
# стека, они обязательны. В Vitis их привязывал sp= из
# scripts/network_krnl_mem.txt.in; шелл предоставлял memory subsystem.
#
# Воспроизводим ровно то, что делала XRT-сборка, а не подбираем свой вариант.
# CMakeLists.txt задаёт NETWORK_KRNL_MEM и CMAC_SLR, device.tcl переводит банк
# в имя board interface (для u200: DDR[3] -> ddr4_sdram_c3), и
# scripts/network_krnl_mem.txt.in привязывал ОБА мастера (m00_axi и m01_axi)
# к одному и тому же банку. board.xml подтверждает: ddr4_sdram_c3 — 16 ГБ,
# SLR2, тактируется от default_300mhz_clk3. То есть память и CMAC жили в одном
# SLR — сохраняем и это.
#
# Оба мастера идут в один контроллер через smartconnect, как и при sp= на один
# банк в Vitis-флоу.

create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_c3

# Всё, что описывает саму память (деталь, тип, тайминги, ~150 пинов), приходит
# из board interface — так же, как это делает Block Automation в GUI. Своих
# значений не подставляем: board file платы уже содержит верные (для u200
# сверено с ulp.bd платформы: MTA18ASF2G72PZ-2G3, RDIMM, 72 бита,
# TIMEPERIOD_PS=833).
#
# Если board_part не применился, эти два параметра принимают только "Custom",
# контроллер остаётся в конфигурации по умолчанию и требует подключить
# C0_DDR4_S_AXI_CTRL. Поэтому board_part проверяется выше явной ошибкой.
set_property -dict [list \
     CONFIG.C0_CLOCK_BOARD_INTERFACE $DEV_MEM_CLK \
     CONFIG.C0_DDR4_BOARD_INTERFACE $DEV_MEM_IF \
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
# Номер мастера — MI_DDR4_ECC, вычислен выше (последний, после всех
# network_krnl_N и, если есть, всех ${USER_KRNL}_N).
set mi_ddr [format "M%02d_AXI" $MI_DDR4_ECC]
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
#
# NUM_SI = 2 * NUM_QSFP: оба network_krnl (session tables для TCP) делят один
# ddr4_c3 (первая итерация, см. решение в задаче #5) — не отдельный банк на
# канал. Каждый network_krnl_N даёт два мастера (m00_axi/m01_axi), как и при
# одном порте.
set n_mem_si [expr {2 * $NUM_QSFP}]
set_property -dict [list \
     CONFIG.NUM_SI $n_mem_si \
     CONFIG.NUM_MI {1} \
     CONFIG.NUM_CLKS {2} \
] [get_bd_cells mem_interconnect]

set si_idx 0
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     connect_bd_intf_net [get_bd_intf_pins network_krnl_$n/m00_axi] \
                         [get_bd_intf_pins mem_interconnect/[format "S%02d_AXI" $si_idx]]
     incr si_idx
     connect_bd_intf_net [get_bd_intf_pins network_krnl_$n/m01_axi] \
                         [get_bd_intf_pins mem_interconnect/[format "S%02d_AXI" $si_idx]]
     incr si_idx
}
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

# Каждый канал N получает свою пару базовых адресов, шаг 0x10000 (размер
# адресного пространства s_axi_control с запасом — оба ядра используют
# считанные КБ, см. смещения в jtag_ctrl.tcl). network_krnl_N и ${USER_KRNL}_N
# чередуются по каналам, а не блоками — так адрес по индексу N совпадает и
# здесь, и в jtag_ctrl.tcl (OUCH_BASE_NETWORK(N)/OUCH_BASE_USER(N)):
#   network_krnl_1 -> 0x00000000   ${USER_KRNL}_1 -> 0x00010000
#   network_krnl_2 -> 0x00020000   ${USER_KRNL}_2 -> 0x00030000
proc _addr_network {n} { return [expr {($n - 1) * 0x20000}] }
proc _addr_user    {n} { return [expr {($n - 1) * 0x20000 + 0x10000}] }

# Сначала — автоматически всё, что не назначено (память для m0*_axi).
assign_bd_address -quiet

puts ""
puts "=== адреса s_axi_control ==="

# Переназначение идёт ДВУМЯ ПОЛНЫМИ ПРОХОДАМИ по всем сегментам, а не двумя
# шагами внутри одного цикла по каналам.
#
# Почему так. Автораспределение раскладывает сегменты в порядке обхода BD, и
# порядок зависит от состава дизайна: стоит user-ядру получить s_axi_control
# (как только у него появляются s_axilite-аргументы), и число сегментов
# меняется, а вместе с ним — кто куда попал. Если целевой адрес одного
# сегмента занят ДРУГИМ сегментом, который ещё не переехал, то
# set_property offset молча не применяется, и проверка ниже падает.
#
# Смешанный порядок (увести сеть канала 1, поставить сеть канала 1, увести
# сеть канала 2, ...) от этого не защищает: к моменту расстановки канала 1
# сегменты канала 2 всё ещё стоят там, куда их положило автораспределение.
# Поэтому сперва уводим В СТОРОНУ ВСЕ сегменты и только потом ставим их на
# целевые адреса — тогда целевая область гарантированно пуста.
set segs_net  {}
set segs_user {}
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     lappend segs_net [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                            -filter "NAME =~ *network_krnl_${n}*"]
     lappend segs_user [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces jtag_axi_0/Data] \
                            -filter "NAME =~ *${USER_KRNL}_${n}*"]
}

# Проход 1: все сегменты уходят в заведомо свободную область. Диапазоны
# 0x10000000+ и 0x20000000+ выбраны выше границы, куда попадают целевые
# адреса s_axi_control (максимум NUM_QSFP * 0x20000), и не пересекаются
# между собой.
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     set seg_net  [lindex $segs_net  [expr {$n - 1}]]
     set seg_user [lindex $segs_user [expr {$n - 1}]]

     set_property offset [expr {0x10000000 + $n * 0x1000000}] $seg_net
     if {[llength $seg_user] > 0} {
          set_property offset [expr {0x20000000 + $n * 0x1000000}] $seg_user
     }
}

# Проход 2: расстановка на целевые адреса и проверка.
for {set n 1} {$n <= $NUM_QSFP} {incr n} {
     set seg_net  [lindex $segs_net  [expr {$n - 1}]]
     set seg_user [lindex $segs_user [expr {$n - 1}]]

     set addr_net  [_addr_network $n]
     set addr_user [_addr_user $n]

     set_property offset $addr_net $seg_net
     if {[llength $seg_user] > 0} {
          set_property offset $addr_user $seg_user
     }

     # Проверяем, что получилось именно то, что прописано в jtag_ctrl.tcl —
     # иначе управление пойдёт не в те регистры, а на железе это выглядит как
     # "ядро не реагирует", без всякой диагностики.
     #
     # Сравнение ЧИСЛОВОЕ (!=), а не строковое (ne): get_property OFFSET
     # возвращает hex-строку вида "0x00000000", а _addr_network/_addr_user —
     # результат expr в десятичном виде ("0", "131072", ...). Строковое
     # сравнение этих двух представлений одного и того же числа считает их
     # разными всегда, кроме случайных совпадений вида "0" — эта проверка
     # валилась бы на every канале, кроме n=1 с нулевым адресом.
     set got_net [get_property OFFSET $seg_net]
     if {$got_net != $addr_net} {
          error "адрес network_krnl_$n=$got_net, ждали $addr_net.\
                 Либо он занят другим сегментом, либо правь OUCH_BASE_NETWORK($n)\
                 в scripts/vivado/jtag_ctrl.tcl."
     }
     puts "  network_krnl_$n s_axi_control -> $addr_net"

     if {[llength $seg_user] > 0} {
          set got_user [get_property OFFSET $seg_user]
          if {$got_user != $addr_user} {
               error "адрес ${USER_KRNL}_$n=$got_user, ждали $addr_user —\
                      сверь OUCH_BASE_USER($n) в scripts/vivado/jtag_ctrl.tcl."
          }
          puts "  ${USER_KRNL}_$n s_axi_control -> $addr_user"
     } elseif {$USER_KRNL_DUAL && $n > $n_user_instances} {
          # Ожидаемо: при dual-режиме экземпляра ${USER_KRNL}_$n для n>1
          # просто не существует (см. n_user_instances выше) — это не
          # "ядро без s_axi_control", а "этого инстанса нет вовсе".
          puts "  ${USER_KRNL}_$n: не инстанцирован (dual-режим — один экземпляр\
                на оба network_krnl, см. ${USER_KRNL}_1 выше)"
     } else {
          puts "  ${USER_KRNL}_$n: без s_axi_control — управлять нечем,"
          puts "               порт слушания зашит в ядре. Из jtag_ctrl.tcl нужны"
          puts "               только network_configure и network_start."
     }
}

# --- финал --------------------------------------------------------------------

validate_bd_design
save_bd_design

make_wrapper -files [get_files "$PROJ_DIR/$PROJ_NAME.srcs/sources_1/bd/$BD_NAME/$BD_NAME.bd"] -top
add_files -norecurse "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/$BD_NAME/hdl/${BD_NAME}_wrapper.v"
set_property top ${BD_NAME}_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse $PINS_XDC

# CMAC в свой SLR — как задавал scripts/cmac_krnl_slr.txt.in в Vitis-флоу
# (CMakeLists.txt: CMAC_SLR). Это не косметика: GT-квады QSFP физически в этом
# SLR, и размещение ядра в другом ломает timing на GT-путях. Для u200 в этом же
# SLR2 находятся ОБА GT-квада (CMACE4_X0Y6 и CMACE4_X0Y7, см.
# kernel/cmac_krnl/package_cmac_krnl.tcl) и DDR4 c3 по board.xml, так что весь
# сетевой путь для каждого канала остаётся локальным — один общий pblock на
# все cmac_krnl_N, а не по pblock-у на канал.
set slr_xdc "$PROJ_DIR/cmac_slr.xdc"
set fh [open $slr_xdc w]
puts $fh "# сгенерировано build_bd.tcl из DEV_CMAC_SLR=$DEV_CMAC_SLR (devices/$BOARD/device.tcl)"
puts $fh "create_pblock pblock_cmac"
puts $fh "resize_pblock \[get_pblocks pblock_cmac\] -add {$DEV_CMAC_SLR}"
puts $fh "add_cells_to_pblock \[get_pblocks pblock_cmac\] \[get_cells -hierarchical -filter {NAME =~ *cmac_krnl_*}\]"
close $fh
add_files -fileset constrs_1 -norecurse $slr_xdc

puts ""
puts "BD собран: $PROJ_DIR/$PROJ_NAME.xpr"
puts ""
puts "Дальше — синтез и имплементация (час с лишним):"
puts "  make -f Makefile.vivado impl USER_KRNL=$USER_KRNL BOARD=$BOARD"
puts ""
puts "Битстрим будет здесь:"
puts "  $PROJ_DIR/$PROJ_NAME.runs/impl_1/${BD_NAME}_wrapper.bit"
puts "Грузить: Hardware Manager -> Program Device (flash НЕ трогается)"
