# -----------------------------------------------------------------------------
# report_placement.tcl — что и куда легло после имплементации
#
# Открывает УЖЕ посчитанный impl_1 (ничего не пересобирает, ~минута на открытие
# checkpoint) и печатает то, что в GUI приходится собирать по трём разным окнам:
#
#   1. утилизация по SLR (сколько занято LUT/FF/BRAM/URAM/DSP в каждом SLR)
#   2. пересечения SLR (SLL) — главный источник проблем с таймингом на u200
#   3. куда сел каждый CMAC/network_krnl/user-ядро: SLR + физический сайт
#   4. GT-квады и CMACE4-сайты — проверка, что порты НЕ подрались за один квад
#   5. утилизация по иерархии — какое ядро сколько съело
#
# Запуск (проще через make, см. Makefile.vivado):
#     vivado -mode batch -source scripts/vivado/report_placement.tcl \
#            -tclargs <путь-к-проекту>
#
# Аргумент — каталог проекта (тот, где net_vivado.xpr), например:
#     build/vivado/u200/hls_dual_echo_krnl
# -----------------------------------------------------------------------------

if {$::argc < 1} {
     puts "ОШИБКА: нужен путь к каталогу проекта (где net_vivado.xpr)"
     puts ""
     puts "  vivado -mode batch -source scripts/vivado/report_placement.tcl \\"
     puts "         -tclargs build/vivado/u200/hls_dual_echo_krnl"
     puts ""
     puts "Проще: make -f Makefile.vivado report USER_KRNL=<ядро> BOARD=u200"
     exit 1
}

set PROJ_DIR [lindex $::argv 0]
set XPR      "$PROJ_DIR/net_vivado.xpr"

if {![file exists $XPR]} {
     error "нет проекта $XPR — сначала прогони шаги bd/impl"
}

open_project $XPR

# Открываем именно результат имплементации: report_design_analysis и
# отчёт по SLR имеют смысл только на размещённом дизайне, до place_design
# они либо пустые, либо врут.
set run [get_runs impl_1]
if {[get_property PROGRESS $run] != "100%"} {
     error "impl_1 не завершён (PROGRESS = [get_property PROGRESS $run]).\
            Сначала: make -f Makefile.vivado impl ..."
}

open_run impl_1 -name impl_1

set line "========================================================================"

# --- 1. по SLR ----------------------------------------------------------------
# Ключевой отчёт для u200 (3 SLR): -slr разбивает утилизацию по кристаллам.
puts ""
puts $line
puts "1. УТИЛИЗАЦИЯ ПО SLR"
puts $line
report_utilization -slr

# --- 2. пересечения SLR -------------------------------------------------------
# SLL — провода между SLR, их конечное число (u200: ~23k на границу). Если
# дизайн гоняет данные через границу, это и лимит, и главный риск по таймингу.
puts ""
puts $line
puts "2. ПЕРЕСЕЧЕНИЯ ГРАНИЦ SLR (SLL)"
puts $line
report_design_analysis -show_all -extend

# --- 3. где какое ядро --------------------------------------------------------
# Ради этого и писался скрипт: связь «имя ячейки BD -> физический SLR».
puts ""
puts $line
puts "3. РАЗМЕЩЕНИЕ ЯДЕР ПО SLR"
puts $line

proc _slr_of_cell {cell} {
     # У иерархической ячейки своего сайта нет — берём SLR по её листьям.
     # Если листья разъехались по разным SLR, это само по себе интересно,
     # поэтому возвращаем весь список, а не первый попавшийся.
     set leaves [get_cells -quiet -hier -filter "PRIMITIVE_LEVEL != INTERNAL" $cell/*]
     if {[llength $leaves] == 0} { return "" }
     set slrs {}
     foreach s [get_slrs -quiet -of_objects $leaves] {
          lappend slrs [get_property NAME $s]
     }
     return [lsort -unique $slrs]
}

foreach pat {cmac_krnl_* network_krnl_* *_krnl_1 *_krnl_2} {
     foreach c [get_cells -quiet -hier -filter "NAME =~ net_bd_i/$pat && IS_PRIMITIVE == 0"] {
          set nm   [get_property NAME $c]
          set slrs [_slr_of_cell $nm]
          if {[llength $slrs] == 0} { continue }
          set n_leaf [llength [get_cells -quiet -hier $nm/*]]
          puts [format "  %-34s SLR: %-14s (ячеек: %s)" \
                    [string map {net_bd_i/ ""} $nm] [join $slrs ","] $n_leaf]
     }
}

# --- 4. CMAC и GT -------------------------------------------------------------
# Прямая проверка бага с одинаковым VLNV у двух cmac_krnl: если оба порта
# упакованы одним IP, здесь будет ОДИН CMACE4-сайт на оба ядра (или второй
# ядро вовсе без LOC — Vivado снимает конфликтующий констрейнт молча).
puts ""
puts $line
puts "4. CMAC / GT — ФИЗИЧЕСКИЕ САЙТЫ"
puts $line

set cmacs [get_cells -quiet -hier -filter "REF_NAME =~ CMACE4*"]
if {[llength $cmacs] == 0} {
     puts "  CMACE4 не найдено (дизайн без CMAC?)"
} else {
     foreach c $cmacs {
          set site [get_property SITE $c]
          set loc  [get_property LOC  $c]
          if {$site eq ""} { set site "<НЕ РАЗМЕЩЁН>" }
          if {$loc  eq ""} { set loc  "<БЕЗ LOC>" }
          set slr [get_slrs -quiet -of_objects $c]
          set slrn [expr {$slr eq "" ? "?" : [get_property NAME $slr]}]
          puts [format "  %-58s" [get_property NAME $c]]
          puts [format "      site=%-16s LOC=%-16s SLR=%s" $site $loc $slrn]
     }
     set n_site [llength [lsort -unique [get_property SITE $cmacs]]]
     puts ""
     puts "  CMACE4 всего: [llength $cmacs], различных сайтов: $n_site"
     if {[llength $cmacs] > 1 && $n_site < [llength $cmacs]} {
          puts "  !! ДВА CMAC НА ОДНОМ САЙТЕ ИЛИ БЕЗ LOC — порты подрались за квад."
          puts "  !! Обычно это один VLNV на оба QSFP; см. package_cmac_krnl.tcl."
     }
}

# GT-каналы: по 4 на 100G-порт. Разные порты обязаны быть в разных квадах.
puts ""
set gts [get_cells -quiet -hier -filter "REF_NAME =~ GTYE4_CHANNEL*"]
puts "  GTYE4_CHANNEL: [llength $gts]"
foreach g $gts {
     set site [get_property SITE $g]
     if {$site eq ""} { set site "<НЕ РАЗМЕЩЁН>" }
     puts [format "      %-22s  %s" $site [string map {net_bd_i/ ""} [get_property NAME $g]]]
}

# --- 5. по иерархии -----------------------------------------------------------
puts ""
puts $line
puts "5. УТИЛИЗАЦИЯ ПО ИЕРАРХИИ (глубина 2)"
puts $line
report_utilization -hierarchical -hierarchical_depth 2

# --- итог ---------------------------------------------------------------------
puts ""
puts $line
puts "ИТОГ"
puts $line
puts "  WNS: [get_property STATS.WNS $run]   WHS: [get_property STATS.WHS $run]"
puts "  (оба обязаны быть положительными)"
puts ""
puts "  На что смотреть:"
puts "    - раздел 1: если какой-то SLR под 80%+ по LUT — жди проблем с таймингом"
puts "    - раздел 2: SLL близко к лимиту (u200: ~23k на границу) — тоже риск"
puts "    - раздел 4: у каждого QSFP свой CMACE4 и своя четвёрка GTYE4_CHANNEL"
puts ""

close_project
