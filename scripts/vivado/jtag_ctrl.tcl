# -----------------------------------------------------------------------------
# jtag_ctrl.tcl
#
# Замена OpenCL-хоста для Vivado-флоу: конфигурирует ядра и читает счётчики
# через JTAG-to-AXI Master вместо XRT.
#
# Соответствие с Vitis-версией (host/hls_ouch_krnl/host.cpp):
#     setArg(i, v)      -> запись в s_axi_control по смещению аргумента
#     enqueueTask(k)    -> запись ap_start=1 (только для ap_ctrl_hs ядер!)
#     чтение счётчиков  -> чтение s_axi_control (OpenCL так не умел вовсе)
#
# Запускать в Hardware Manager после программирования устройства:
#     open_hw_manager; connect_hw_server; open_hw_target
#     current_hw_device [lindex [get_hw_devices] 0]
#     source scripts/vivado/jtag_ctrl.tcl
#     ouch_bringup 7001 "0a01d498" "000a35029de5"
#
# -----------------------------------------------------------------------------
# ВАЖНО про два разных протокола управления:
#
#   network_krnl объявлен ap_ctrl_hs (см. kernel/network_krnl/network_krnl.xml,
#   hwControlProtocol="ap_ctrl_hs"). Ему НУЖЕН ap_start, иначе стек не
#   запустится и всё будет молча стоять. В Vitis это делал enqueueTask().
#
#   hls_ouch_krnl объявлен ap_ctrl_none (#pragma HLS INTERFACE ap_ctrl_none
#   port=return). У него нет регистра ap_start вообще — ядро "течёт" всё время,
#   пока подан клок. Поэтому его enable-аргумент и служит разрешением начать
#   работу: см. комментарий у ouch_listen в hls_ouch_krnl.cpp про гонку.
# -----------------------------------------------------------------------------

# Базовые адреса s_axi_control. Должны совпадать с тем, что назначил address
# editor в BD — сверить после build_bd.tcl командой:
#     puts [get_property OFFSET [get_bd_addr_segs -of_objects \
#           [get_bd_addr_spaces jtag_axi_0/Data]]]
set ::OUCH_BASE_NETWORK 0x00000000
set ::OUCH_BASE_USER    0x00010000

# Смещения регистров network_krnl — взяты из network_krnl.xml (атрибут offset
# у каждого <arg>), не угаданы.
set ::NET_OFF_AP_CTRL   0x000
set ::NET_OFF_IP_ADDR   0x010
set ::NET_OFF_MAC_ADDR  0x018
set ::NET_OFF_ARP       0x024
set ::NET_OFF_AXI00_PTR 0x02c
set ::NET_OFF_AXI01_PTR 0x038

# Смещения регистров hls_ouch_krnl.
#
# ВНИМАНИЕ: это значения по умолчанию для текущей сигнатуры ядра. HLS
# раскладывает s_axilite-аргументы сам, и порядок в C++ НЕ определяет
# смещения напрямую. После export_design проверить фактические значения:
#
#     grep -A2 "listenPort" <hls_proj>/impl/ip/hdl/verilog/*_control_s_axi.v
#
# либо в отчёте <hls_proj>/impl/ip/drivers/*/src/*_hw.h — там смещения
# перечислены как XHLS_OUCH_KRNL_CONTROL_ADDR_*.
#
# Поскольку ядро ap_ctrl_none, регистра 0x000 у него нет, и первый аргумент
# начинается с 0x010.
set ::USR_OFF_LISTEN_PORT   0x010
set ::USR_OFF_RX_BYTE_LO    0x018
set ::USR_OFF_RX_BYTE_HI    0x01c
set ::USR_OFF_RX_PKT        0x024
set ::USR_OFF_ENABLE        0x02c

# --- низкоуровневый доступ -----------------------------------------------------

proc _jtag_axi_name {} {
     # Имя AXI-мастера в Hardware Manager: обычно hw_axi_1, но зависит от того,
     # как назван jtag_axi в BD.
     set axis [get_hw_axis -quiet]
     if {[llength $axis] == 0} {
          error "JTAG-to-AXI мастер не найден. Устройство запрограммировано? В дизайне есть jtag_axi IP?"
     }
     return [lindex $axis 0]
}

proc axi_write32 {addr value} {
     set hw_axi [_jtag_axi_name]
     set addr_hex [format %08x $addr]
     set data_hex [format %08x $value]

     # Транзакции переиспользуются, поэтому старую с тем же именем удаляем —
     # иначе create_hw_axi_txn падает на дубликате.
     set txn "wr_$addr_hex"
     if {[llength [get_hw_axi_txns -quiet $txn]] > 0} {
          delete_hw_axi_txn [get_hw_axi_txns $txn]
     }

     create_hw_axi_txn $txn $hw_axi -type write -address $addr_hex -data $data_hex -len 1
     run_hw_axi -quiet [get_hw_axi_txns $txn]
}

proc axi_read32 {addr} {
     set hw_axi [_jtag_axi_name]
     set addr_hex [format %08x $addr]

     set txn "rd_$addr_hex"
     if {[llength [get_hw_axi_txns -quiet $txn]] > 0} {
          delete_hw_axi_txn [get_hw_axi_txns $txn]
     }

     create_hw_axi_txn $txn $hw_axi -type read -address $addr_hex -len 1
     run_hw_axi -quiet [get_hw_axi_txns $txn]

     set data [get_property DATA [get_hw_axi_txns $txn]]
     return [expr {0x$data}]
}

# --- network_krnl -------------------------------------------------------------

# ip_str  — IP в hex без префикса, порядок как в host.cpp (там local_IP
#           собирается как 0x0A01D498 для 10.1.212.152)
# mac_str — MAC в hex, 48 бит
proc network_configure {ip_str mac_str {arp 1}} {
     set base $::OUCH_BASE_NETWORK

     set ip  [expr {0x$ip_str}]
     set mac [expr {0x$mac_str}]

     puts "network_krnl: ip=0x[format %08x $ip] mac=0x[format %012x $mac]"

     axi_write32 [expr {$base + $::NET_OFF_IP_ADDR}] $ip

     # mac_addr — 64-битный аргумент, s_axilite отдаёт его двумя словами.
     axi_write32 [expr {$base + $::NET_OFF_MAC_ADDR}]       [expr {$mac & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_MAC_ADDR + 4}]   [expr {($mac >> 32) & 0xffffffff}]

     axi_write32 [expr {$base + $::NET_OFF_ARP}] $arp
}

# Буферы для TCP session tables. В Vitis это были cl::Buffer, которые XRT
# размещал в DDR сам; здесь адреса задаём вручную — они должны попадать в
# диапазон, который address editor отвёл под DDR4 для m00_axi/m01_axi.
proc network_set_buffers {{ptr0 0x00000000} {ptr1 0x40000000}} {
     set base $::OUCH_BASE_NETWORK

     puts "network_krnl: axi00_ptr0=0x[format %08x $ptr0] axi01_ptr0=0x[format %08x $ptr1]"

     axi_write32 [expr {$base + $::NET_OFF_AXI00_PTR}]     [expr {$ptr0 & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI00_PTR + 4}] [expr {($ptr0 >> 32) & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI01_PTR}]     [expr {$ptr1 & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI01_PTR + 4}] [expr {($ptr1 >> 32) & 0xffffffff}]
}

# Аналог enqueueTask(network_kernel). Только для ap_ctrl_hs.
proc network_start {} {
     set addr [expr {$::OUCH_BASE_NETWORK + $::NET_OFF_AP_CTRL}]

     # ap_start(бит0) + auto_restart(бит7): стек должен работать непрерывно,
     # а не отработать один раз и встать.
     axi_write32 $addr 0x81

     set ctrl [axi_read32 $addr]
     puts "network_krnl: ap_ctrl=0x[format %02x $ctrl] (ap_start=[expr {$ctrl & 1}] ap_done=[expr {($ctrl >> 1) & 1}])"
}

# --- hls_ouch_krnl ------------------------------------------------------------

proc ouch_configure {listen_port} {
     set base $::OUCH_BASE_USER
     puts "hls_ouch_krnl: listenPort=$listen_port"
     axi_write32 [expr {$base + $::USR_OFF_LISTEN_PORT}] $listen_port
}

# enable пишется последним — это разрешение начать работу. См. комментарий
# про гонку с ap_ctrl_none в hls_ouch_krnl.cpp.
proc ouch_enable {{v 1}} {
     puts "hls_ouch_krnl: enable=$v"
     axi_write32 [expr {$::OUCH_BASE_USER + $::USR_OFF_ENABLE}] $v
}

# То, чего не мог OpenCL-хост: прочитать выходные счётчики.
proc ouch_counters {} {
     set base $::OUCH_BASE_USER

     set lo  [axi_read32 [expr {$base + $::USR_OFF_RX_BYTE_LO}]]
     set hi  [axi_read32 [expr {$base + $::USR_OFF_RX_BYTE_HI}]]
     set pkt [axi_read32 [expr {$base + $::USR_OFF_RX_PKT}]]

     set bytes [expr {($hi << 32) | $lo}]

     puts "rxByteCount   = $bytes"
     puts "rxPacketCount = $pkt"

     return [list $bytes $pkt]
}

# Периодический опрос — удобно, чтобы видеть, что трафик идёт.
proc ouch_watch {{iterations 10} {delay_ms 1000}} {
     for {set i 0} {$i < $iterations} {incr i} {
          set c [ouch_counters]
          puts "  \[$i\] bytes=[lindex $c 0] pkts=[lindex $c 1]"
          after $delay_ms
     }
}

# --- всё вместе ---------------------------------------------------------------

# Порядок важен и повторяет host.cpp: сначала сконфигурировать сеть, запустить
# стек, потом настроить user-ядро и только в конце разрешить ему работу.
proc ouch_bringup {listen_port ip_str mac_str} {
     puts "=== bringup ==="
     network_configure $ip_str $mac_str
     network_set_buffers
     network_start

     ouch_configure $listen_port
     ouch_enable 1

     puts "=== готово, слушаем порт $listen_port ==="
     ouch_counters
}
