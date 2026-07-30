# -----------------------------------------------------------------------------
# gen_axis_connect.tcl
#
# Переносит соединения из Vitis-формата (config_sp_*.txt, строки "sc=") в
# вызовы connect_bd_intf_net для блок-дизайна Vivado.
#
# Зачем: в Vitis-флоу линковщик v++ читал config_sp_*.txt и соединял ядра сам.
# В Vivado-флоу этого шага нет, соединения нужно сделать руками. Файл
# config_sp_* остаётся единственным описанием топологии, поэтому берём его как
# источник истины, а не переписываем список портов заново — иначе он разъедется
# с Vitis-сборкой, которая продолжает работать.
#
# Формат строки Vitis:
#     sc=<ядро>_<N>.<порт>:<ядро>_<N>.<порт>
# Имена экземпляров совпадают с именами ячеек в BD, если инстанцировать их
# как <kernel>_1 (см. build_bd.tcl).
#
# Использование:
#     source gen_axis_connect.tcl
#     axis_connect_from_config ./kernel/user_krnl/hls_ouch_krnl/config_sp_hls_ouch_krnl.txt
#
# Проверить без изменения дизайна (печатает команды, ничего не соединяет):
#     axis_connect_from_config <файл> -dry_run
# -----------------------------------------------------------------------------

proc axis_connect_from_config {cfg_file args} {
     set dry_run [expr {[lsearch $args "-dry_run"] >= 0}]

     if {![file exists $cfg_file]} {
          error "config_sp файл не найден: $cfg_file"
     }

     set fh [open $cfg_file r]
     set lines [split [read $fh] "\n"]
     close $fh

     set n_ok 0
     set n_skip 0
     set failed {}

     foreach line $lines {
          set line [string trim $line]

          # Пропускаем пустые строки, комментарии и заголовок [connectivity].
          if {$line eq "" || [string match "#*" $line] || [string match "\[*" $line]} {
               continue
          }

          # Интересуют только stream-connect. Строки sp= (привязка мастеров к
          # памяти) в BD решаются иначе — через address editor, см. build_bd.tcl.
          if {![regexp {^sc=(.+)$} $line -> body]} {
               if {[string match "sp=*" $line] || [string match "slr=*" $line]} {
                    puts "  SKIP (не stream, обрабатывается отдельно): $line"
                    incr n_skip
               }
               continue
          }

          set halves [split $body ":"]
          if {[llength $halves] != 2} {
               puts "  WARN не разобрал строку: $line"
               incr n_skip
               continue
          }

          # "network_krnl_1.m_axis_udp_rx" -> ячейка "network_krnl_1", пин "m_axis_udp_rx"
          set src [string trim [lindex $halves 0]]
          set dst [string trim [lindex $halves 1]]

          set src_pin [_axis_pin_path $src]
          set dst_pin [_axis_pin_path $dst]

          if {$dry_run} {
               puts "connect_bd_intf_net \[get_bd_intf_pins $src_pin\] \[get_bd_intf_pins $dst_pin\]"
               incr n_ok
               continue
          }

          # Соединяем по одному и продолжаем при ошибке: так за один проход
          # видно все несостыковки имён, а не только первую.
          if {[catch {
               connect_bd_intf_net [get_bd_intf_pins $src_pin] [get_bd_intf_pins $dst_pin]
          } err]} {
               puts "  FAIL $src_pin -> $dst_pin"
               puts "       $err"
               lappend failed "$src_pin -> $dst_pin"
          } else {
               puts "  OK   $src_pin -> $dst_pin"
               incr n_ok
          }
     }

     puts ""
     puts "Соединено: $n_ok, пропущено: $n_skip, ошибок: [llength $failed]"

     if {[llength $failed] > 0} {
          puts ""
          puts "Не соединилось — проверь имена ячеек в BD и имена портов IP:"
          foreach f $failed { puts "  $f" }
          error "остались несоединённые интерфейсы ([llength $failed])"
     }
}

# "network_krnl_1.m_axis_udp_rx" -> "network_krnl_1/m_axis_udp_rx"
proc _axis_pin_path {spec} {
     set dot [string first "." $spec]
     if {$dot < 0} {
          error "ожидал вид <ячейка>.<порт>, получил: $spec"
     }
     set cell [string range $spec 0 [expr {$dot - 1}]]
     set pin  [string range $spec [expr {$dot + 1}] end]
     return "$cell/$pin"
}
