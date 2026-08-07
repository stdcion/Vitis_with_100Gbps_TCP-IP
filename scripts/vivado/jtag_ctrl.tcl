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
#
#     hls_ouch_krnl (есть s_axi_control — listenPort/enable/счётчики):
#         ouch_bringup 7001 "0a01d498" "000a35029de5"
#         NUM_QSFP=2: ouch_bringup_dual 7001 "0a01d498" "000a35029de5" \
#                                       7002 "0a01d499" "000a35029de6"
#
#     hls_echo_krnl (порт зашит константой, БЕЗ s_axi_control — только сеть):
#         echo_bringup "0a01d498" "000a35029de5"
#         NUM_QSFP=2: echo_bringup_dual "0a01d498" "000a35029de5" \
#                                        "0a01d499" "000a35029de6"
#
#     Любую процедуру ниже можно вызвать и по отдельности через последний
#     аргумент n (1=QSFP0, 2=QSFP1).
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

# Базовые адреса s_axi_control. build_bd.tcl задаёт их явно (_addr_network/
# _addr_user, шаг 0x20000 между каналами) и проверяет результат, поэтому здесь
# просто та же формула. Канал N=1 — QSFP0, N=2 — QSFP1, и т.д. Если менять —
# менять в обоих файлах.
proc ouch_base_network {{n 1}} { return [expr {($n - 1) * 0x20000}] }
proc ouch_base_user    {{n 1}} { return [expr {($n - 1) * 0x20000 + 0x10000}] }

# Оставлены для обратной совместимости со старыми вызовами (один канал,
# N=1) — новый код должен использовать ouch_base_network N/ouch_base_user N.
set ::OUCH_BASE_NETWORK [ouch_base_network 1]
set ::OUCH_BASE_USER    [ouch_base_user 1]

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
# Взяты из xhls_ouch_krnl_hw.h, который сгенерировал export_design
# (ouch_ip_proj/sol1/impl/ip/drivers/hls_ouch_krnl_v1_0/src/) — не угаданы.
# export_hls_ip.tcl печатает их в конце прогона; при изменении сигнатуры ядра
# сверить заново.
#
# Порядок в C++ смещения НЕ задаёт: между аргументами HLS вставляет
# ap_vld-регистры для выходных значений (0x20 для rxByteCount, 0x34 для
# rxPacketCount), поэтому enable оказался на 0x40, а не сразу за счётчиками.
#
# Ядро ap_ctrl_none, поэтому регистра ap_ctrl (0x00) у него нет вовсе.
set ::USR_OFF_LISTEN_PORT   0x10
set ::USR_OFF_RX_BYTE_LO    0x18
set ::USR_OFF_RX_BYTE_HI    0x1c
set ::USR_OFF_RX_PKT        0x30
set ::USR_OFF_ENABLE        0x40

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
     # scan, а не expr {0x$data}: в фигурных скобках подстановки нет, и
     # выражение «0x$data» падает с "invalid bareword x". Без скобок
     # работало бы, но scan надёжнее — он не зависит от того, как Tcl
     # разберёт строку, и корректен для 32-битных значений со старшим
     # битом (0xFFFFFFFF даёт -1 при expr, но 4294967295 при %x).
     set v 0
     scan $data %x v
     return $v
}

# --- network_krnl -------------------------------------------------------------

# ip_str  — IP в hex без префикса, порядок как в host.cpp (там local_IP
#           собирается как 0x0A01D498 для 10.1.212.152)
# mac_str — MAC в hex, 48 бит
# n       — номер канала (1 = QSFP0, 2 = QSFP1, ...), см. ouch_base_network.
proc network_configure {ip_str mac_str {arp 1} {n 1}} {
     set base [ouch_base_network $n]

     # scan вместо expr {0x$...}: см. пояснение в axi_read32. MAC 48 бит,
     # поэтому %llx — на 32-битном %x старшие байты потерялись бы.
     set ip 0
     set mac 0
     scan $ip_str  %x   ip
     scan $mac_str %llx mac

     puts "network_krnl: ip=0x[format %08x $ip] mac=0x[format %012x $mac]"

     axi_write32 [expr {$base + $::NET_OFF_IP_ADDR}] $ip

     # mac_addr — 64-битный аргумент, s_axilite отдаёт его двумя словами.
     axi_write32 [expr {$base + $::NET_OFF_MAC_ADDR}]       [expr {$mac & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_MAC_ADDR + 4}]   [expr {($mac >> 32) & 0xffffffff}]

     axi_write32 [expr {$base + $::NET_OFF_ARP}] $arp

     # Читаем обратно. Регистры ip_addr/mac_addr/arp в network_control_s_axi —
     # обычные read/write, поэтому прочитанное значение подтверждает, что запись
     # по JTAG дошла. Без этой проверки "стек не отвечает" не отличить от
     # "адреса не записались".
     set rd_ip  [axi_read32 [expr {$base + $::NET_OFF_IP_ADDR}]]
     set rd_lo  [axi_read32 [expr {$base + $::NET_OFF_MAC_ADDR}]]
     set rd_hi  [axi_read32 [expr {$base + $::NET_OFF_MAC_ADDR + 4}]]
     set rd_mac [expr {($rd_hi << 32) | $rd_lo}]

     puts "  прочитано:  ip=0x[format %08x $rd_ip] mac=0x[format %012x $rd_mac]"

     if {$rd_ip != $ip || $rd_mac != $mac} {
          puts "  *** ЗАПИСЬ НЕ ПОДТВЕРДИЛАСЬ — проверь ouch_base_network $n и что"
          puts "      устройство запрограммировано этим битстримом"
          return 0
     }
     puts "  запись подтверждена"

     # ВАЖНО: сами адреса стек защёлкивает не сейчас, а по фронту ap_start —
     # в network_stack.sv это
     #     assign set_ip_addr_valid  = ap_start_pulse;
     #     assign set_mac_addr_valid = ap_start_pulse;
     # Поэтому network_configure ОБЯЗАТЕЛЬНО вызывать ДО network_start.
     return 1
}

# Буферы для TCP session tables. В Vitis это были cl::Buffer, которые XRT
# размещал в DDR сам (host.cpp: buffer_r1/buffer_r2 по 8 КБ каждый); здесь
# адреса задаём вручную.
#
# Значения по умолчанию — начало и середина диапазона DDR4 c3 (16 ГБ, банк
# DDR[3] — тот же, что задавал NETWORK_KRNL_MEM в CMakeLists.txt для u200).
# Точный базовый адрес печатает build_bd.tcl в карте адресов; если он не 0,
# сдвинуть оба значения.
# n — номер канала. Оба network_krnl делят один DDR4-банк (первая итерация,
# см. build_bd.tcl), поэтому у разных каналов буферы ДОЛЖНЫ смотреть в разные
# диапазоны — иначе session tables обоих стеков затрут друг друга. Дефолты
# ниже валидны только для n=1; для n=2 передавай непересекающийся диапазон
# (например 0x80000000/0xC0000000).
proc network_set_buffers {{ptr0 0x00000000} {ptr1 0x40000000} {n 1}} {
     set base [ouch_base_network $n]

     puts "network_krnl\[$n\]: axi00_ptr0=0x[format %08x $ptr0] axi01_ptr0=0x[format %08x $ptr1]"

     axi_write32 [expr {$base + $::NET_OFF_AXI00_PTR}]     [expr {$ptr0 & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI00_PTR + 4}] [expr {($ptr0 >> 32) & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI01_PTR}]     [expr {$ptr1 & 0xffffffff}]
     axi_write32 [expr {$base + $::NET_OFF_AXI01_PTR + 4}] [expr {($ptr1 >> 32) & 0xffffffff}]
}

# Аналог enqueueTask(network_kernel). Только для ap_ctrl_hs.
proc network_start {{n 1}} {
     set addr [expr {[ouch_base_network $n] + $::NET_OFF_AP_CTRL}]

     # ap_start(бит0) + auto_restart(бит7): стек должен работать непрерывно,
     # а не отработать один раз и встать.
     axi_write32 $addr 0x81

     set ctrl [axi_read32 $addr]
     puts "network_krnl\[$n\]: ap_ctrl=0x[format %02x $ctrl] (ap_start=[expr {$ctrl & 1}] ap_done=[expr {($ctrl >> 1) & 1}])"
}

# --- hls_ouch_krnl ------------------------------------------------------------

proc ouch_configure {listen_port {n 1}} {
     set base [ouch_base_user $n]
     puts "hls_ouch_krnl\[$n\]: listenPort=$listen_port"
     axi_write32 [expr {$base + $::USR_OFF_LISTEN_PORT}] $listen_port
}

# enable пишется последним — это разрешение начать работу. См. комментарий
# про гонку с ap_ctrl_none в hls_ouch_krnl.cpp.
proc ouch_enable {{v 1} {n 1}} {
     puts "hls_ouch_krnl\[$n\]: enable=$v"
     axi_write32 [expr {[ouch_base_user $n] + $::USR_OFF_ENABLE}] $v
}

# То, чего не мог OpenCL-хост: прочитать выходные счётчики.
proc ouch_counters {{n 1}} {
     set base [ouch_base_user $n]

     set lo  [axi_read32 [expr {$base + $::USR_OFF_RX_BYTE_LO}]]
     set hi  [axi_read32 [expr {$base + $::USR_OFF_RX_BYTE_HI}]]
     set pkt [axi_read32 [expr {$base + $::USR_OFF_RX_PKT}]]

     set bytes [expr {($hi << 32) | $lo}]

     puts "\[$n\] rxByteCount   = $bytes"
     puts "\[$n\] rxPacketCount = $pkt"

     return [list $bytes $pkt]
}

# Периодический опрос — удобно, чтобы видеть, что трафик идёт.
proc ouch_watch {{iterations 10} {delay_ms 1000} {n 1}} {
     for {set i 0} {$i < $iterations} {incr i} {
          set c [ouch_counters $n]
          puts "  \[$i\] bytes=[lindex $c 0] pkts=[lindex $c 1]"
          after $delay_ms
     }
}

# --- всё вместе ---------------------------------------------------------------

# Общая часть bringup: сеть (IP/MAC/буферы/ap_start) для канала n.
# n — номер канала (1 = QSFP0, 2 = QSFP1, ...).
proc _network_bringup {ip_str mac_str n} {
     network_configure $ip_str $mac_str 1 $n
     # ptr0/ptr1 по умолчанию валидны только для n=1 — при двух каналах на
     # одном DDR4-банке (см. build_bd.tcl) второй канал должен получить
     # непересекающийся диапазон, иначе session tables затрут друг друга.
     if {$n == 1} {
          network_set_buffers 0x00000000 0x40000000 $n
     } else {
          network_set_buffers 0x80000000 0xC0000000 $n
     }
     network_start $n
}

# Порядок важен и повторяет host.cpp: сначала сконфигурировать сеть, запустить
# стек, потом настроить user-ядро и только в конце разрешить ему работу.
#
# ТОЛЬКО для ядер с s_axi_control (hls_ouch_krnl). Для hls_echo_krnl используй
# echo_bringup ниже — у него нет ни listenPort, ни enable регистров, запись
# по несуществующему адресу в ctrl_interconnect уйдёт в DECERR.
proc ouch_bringup {listen_port ip_str mac_str {n 1}} {
     puts "=== bringup канал $n (ouch) ==="
     _network_bringup $ip_str $mac_str $n

     ouch_configure $listen_port $n
     ouch_enable 1 $n

     puts "=== готово, канал $n слушает порт $listen_port ==="
     ouch_counters $n
}

# Поднять сразу оба канала гейтвея одним вызовом (hls_ouch_krnl).
#   ouch_bringup_dual 7001 "0a01d498" "000a35029de5" 7002 "0a01d499" "000a35029de6"
proc ouch_bringup_dual {listen_port1 ip_str1 mac_str1 listen_port2 ip_str2 mac_str2} {
     ouch_bringup $listen_port1 $ip_str1 $mac_str1 1
     puts ""
     ouch_bringup $listen_port2 $ip_str2 $mac_str2 2
}

# Аналог ouch_bringup для hls_echo_krnl: у него нет s_axi_control (порт
# слушания зашит константой LISTEN_PORT в hls_echo_krnl.cpp), поэтому только
# сеть — IP/MAC/ap_start. n — номер канала (1 = QSFP0, 2 = QSFP1, ...).
proc echo_bringup {ip_str mac_str {n 1}} {
     puts "=== bringup канал $n (echo) ==="
     _network_bringup $ip_str $mac_str $n
     puts "=== готово, канал $n слушает порт, зашитый в hls_echo_krnl.cpp (LISTEN_PORT) ==="
}

# Поднять сразу оба канала для hls_echo_krnl.
#   echo_bringup_dual "0a01d498" "000a35029de5" "0a01d499" "000a35029de6"
proc echo_bringup_dual {ip_str1 mac_str1 ip_str2 mac_str2} {
     echo_bringup $ip_str1 $mac_str1 1
     puts ""
     echo_bringup $ip_str2 $mac_str2 2
}

# =============================================================================
# hls_echo_probe_dual_krnl — измерение задержки TCP-стека
# =============================================================================
#
# Ядро содержит клиент (порт 0) и сервер-эхо (порт 1). Пакет уходит по
# триггеру, обходит круг через кабель и возвращается; ядро защёлкивает
# четыре сырых таймстемпа, хост считает интервалы.
#
# Порядок работы:
#     echo_bringup_dual 0a01d498 000a35029de5 0a01d499 000a35029de6
#     epd_configure 0a01d499 7001 64
#     epd_enable 1
#     epd_status                  ; # проверить, что соединение открылось
#     epd_collect 20              ; # 20 замеров со статистикой
#
# СМЕЩЕНИЯ взяты из сгенерированного HLS заголовка драйвера:
#     .../hls_echo_probe_dual_krnl_ip_proj/sol1/impl/misc/drivers/
#         hls_echo_probe_dual_krnl_v1_0/src/xhls_echo_probe_dual_krnl_hw.h
# Их печатает export_hls_ip.tcl в конце прогона.
#
# ВАЖНО ПРО ШАГ. У входных параметров шаг 8 байт, у выходных — 16: HLS
# вставляет ap_vld-регистр после каждого выходного значения. Поэтому
# смещения нельзя вычислить по порядку аргументов, только взять из
# заголовка. При любой правке сигнатуры ядра — сверить заново.
set ::EPD_OFF_SERVER_IP     0x10
set ::EPD_OFF_SERVER_PORT   0x18
set ::EPD_OFF_LISTEN_PORT   0x20
set ::EPD_OFF_MSG_BYTES     0x28
set ::EPD_OFF_TRIGGER_GO    0x30
set ::EPD_OFF_CONN_ATTEMPTS 0x38
set ::EPD_OFF_SENT          0x48
set ::EPD_OFF_RECV          0x58
set ::EPD_OFF_TIMEOUTS      0x68
set ::EPD_OFF_ECHOES        0x78
set ::EPD_OFF_TS_REQUEST    0x88
set ::EPD_OFF_TS_ECHO_IN    0x98
set ::EPD_OFF_TS_ECHO_OUT   0xa8
set ::EPD_OFF_TS_REPLY      0xb8
set ::EPD_OFF_SAMPLE_READY  0xc8
set ::EPD_OFF_ENABLE        0xd8

# Период такта ap_clk, нс. Должен совпадать с DEV_FREQ_MHZ в
# devices/<плата>/device.tcl (170 МГц -> 5.882 нс). Если частоту меняли,
# поправить здесь, иначе пересчёт в наносекунды соврёт.
set ::EPD_CLK_NS 5.882

# Счётчик триггеров: фронт ловится по ИЗМЕНЕНИЮ значения, поэтому
# сбрасывать регистр в ноль между замерами не нужно.
set ::EPD_TRIG 0

# Параметры. serverIp — в hex без префикса, как в network_configure.
# listenPort всегда равен serverPort: клиент подключается туда, где
# слушает сервер.
proc epd_configure {serverIp serverPort msgBytes {n 1}} {
     set base [ouch_base_user $n]

     puts "epd\[$n\]: server=0x$serverIp:$serverPort msg=$msgBytes байт"

     set sip 0
     scan $serverIp %x sip
     axi_write32 [expr {$base + $::EPD_OFF_SERVER_IP}]   $sip
     axi_write32 [expr {$base + $::EPD_OFF_SERVER_PORT}] $serverPort
     axi_write32 [expr {$base + $::EPD_OFF_LISTEN_PORT}] $serverPort
     axi_write32 [expr {$base + $::EPD_OFF_MSG_BYTES}]   $msgBytes

     # Проверяем чтением: без этого «ядро не отвечает» не отличить от
     # «параметры не записались».
     set rd [axi_read32 [expr {$base + $::EPD_OFF_MSG_BYTES}]]
     if {$rd != $msgBytes} {
          puts "  *** ЗАПИСЬ НЕ ПОДТВЕРДИЛАСЬ (msgBytes=$rd, ждали $msgBytes)"
          puts "      проверь ouch_base_user $n и что загружен этот битстрим"
          return 0
     }
     puts "  запись подтверждена"
     return 1
}

# enable ПОСЛЕДНИМ: до него ядро не трогает порты стека, потому что
# параметры в регистрах могут быть ещё не записаны.
proc epd_enable {{v 1} {n 1}} {
     puts "epd\[$n\]: enable=$v"
     axi_write32 [expr {[ouch_base_user $n] + $::EPD_OFF_ENABLE}] $v
}

# Счётчики: по ним видно, на каком этапе встало.
proc epd_status {{n 1}} {
     set base [ouch_base_user $n]
     set att [axi_read32 [expr {$base + $::EPD_OFF_CONN_ATTEMPTS}]]
     set snt [axi_read32 [expr {$base + $::EPD_OFF_SENT}]]
     set ech [axi_read32 [expr {$base + $::EPD_OFF_ECHOES}]]
     set rcv [axi_read32 [expr {$base + $::EPD_OFF_RECV}]]
     set tmo [axi_read32 [expr {$base + $::EPD_OFF_TIMEOUTS}]]
     set rdy [axi_read32 [expr {$base + $::EPD_OFF_SAMPLE_READY}]]

     puts "epd\[$n\]: попыток соединения=$att отправлено=$snt эхо=$ech получено=$rcv таймаутов=$tmo ready=$rdy"

     # Диагностика: где именно оборвалась цепочка.
     if {$att == 0} {
          puts "  -> клиент не пытался открыть соединение: enable=0?"
     } elseif {$snt == 0 && $att > 3} {
          puts "  -> соединение не открылось. Сервер не поднял listen, либо"
          puts "     нет линка между портами (проверь ping и stat_rx_aligned в VIO)"
     } elseif {$snt > 0 && $ech == 0} {
          puts "  -> запрос не дошёл до порта 1: линк, кабель или размещение CMAC"
     } elseif {$ech > 0 && $rcv == 0} {
          puts "  -> эхо ответило, но ответ не вернулся: обратный путь"
     }
     return [list $att $snt $ech $rcv $tmo $rdy]
}

# Один замер: дёрнуть триггер, дождаться sampleReady, прочитать четвёрку.
#
# Гонки чтения нет по построению: пока не дёрнем триггер снова, новый
# пакет не отправится и регистры не изменятся.
#
# Возвращает {t1p t2p t1 t2} либо пустой список при таймауте.
proc epd_sample {{n 1} {timeout_ms 500}} {
     set base [ouch_base_user $n]

     # Запись triggerGo снимает sampleReady и пускает пакет — одна
     # транзакция на два действия.
     incr ::EPD_TRIG
     axi_write32 [expr {$base + $::EPD_OFF_TRIGGER_GO}] $::EPD_TRIG

     set t0 [clock milliseconds]
     while {1} {
          if {[axi_read32 [expr {$base + $::EPD_OFF_SAMPLE_READY}]] == 1} break
          if {[expr {[clock milliseconds] - $t0}] > $timeout_ms} {
               return {}
          }
     }

     set t1p [axi_read32 [expr {$base + $::EPD_OFF_TS_REQUEST}]]
     set t2p [axi_read32 [expr {$base + $::EPD_OFF_TS_ECHO_IN}]]
     set t1  [axi_read32 [expr {$base + $::EPD_OFF_TS_ECHO_OUT}]]
     set t2  [axi_read32 [expr {$base + $::EPD_OFF_TS_REPLY}]]

     return [list $t1p $t2p $t1 $t2]
}

# Вычитание по модулю 2^32 — так же, как в железе. Нужно, потому что
# счётчик тактов оборачивается каждые ~25 с на 170 МГц, и разность через
# границу должна остаться правильной.
proc _epd_sub32 {a b} { return [expr {($a - $b) & 0xFFFFFFFF}] }

# Считает четыре интервала из сырых таймстемпов.
# Возвращает {rtt fwd echo rev} в тактах.
proc epd_intervals {sample} {
     lassign $sample t1p t2p t1 t2
     set rtt [_epd_sub32 $t2  $t1p]
     set fwd [_epd_sub32 $t2p $t1p]
     set ech [_epd_sub32 $t1  $t2p]
     set rev [_epd_sub32 $t2  $t1]
     return [list $rtt $fwd $ech $rev]
}

# Один замер с печатью. Заодно проверяет баланс: сумма участков обязана
# совпасть с полным кругом, иначе таймстемпы от разных пакетов.
proc epd_measure {{n 1}} {
     set s [epd_sample $n]
     if {[llength $s] == 0} {
          puts "epd: замер не удался (нет sampleReady за таймаут)"
          epd_status $n
          return {}
     }
     lassign [epd_intervals $s] rtt fwd ech rev
     set ns $::EPD_CLK_NS

     puts [format "  RTT     %6d тактов  %9.1f нс" $rtt [expr {$rtt*$ns}]]
     puts [format "  NET_FWD %6d           %9.1f" $fwd [expr {$fwd*$ns}]]
     puts [format "  ECHO    %6d           %9.1f" $ech [expr {$ech*$ns}]]
     puts [format "  NET_REV %6d           %9.1f" $rev [expr {$rev*$ns}]]

     set sum [expr {$fwd + $ech + $rev}]
     if {$sum != $rtt} {
          puts "  *** БАЛАНС НЕ СХОДИТСЯ: $fwd+$ech+$rev=$sum, а RTT=$rtt"
          puts "      значит таймстемпы от разных пакетов — числа выбросить"
     }
     return [list $rtt $fwd $ech $rev]
}

# Сколько стоит одна JTAG-транзакция. Полезно знать до сбора статистики:
# от этого зависит, сколько замеров реально успеть.
proc epd_calibrate {{n 1} {iters 100}} {
     set base [ouch_base_user $n]
     set t0 [clock milliseconds]
     for {set i 0} {$i < $iters} {incr i} {
          axi_read32 [expr {$base + $::EPD_OFF_SAMPLE_READY}]
     }
     set dt [expr {[clock milliseconds] - $t0}]
     set per [expr {double($dt)/$iters}]
     puts [format "JTAG: %d чтений за %d мс = %.2f мс на транзакцию" $iters $dt $per]
     puts [format "      один замер (~6 транзакций) ≈ %.0f мс" [expr {$per*6}]]
     return $per
}

# Серия замеров со сводкой. count в пределах десятков-сотен: этого
# достаточно, чтобы увидеть порядок величины и разброс. Тысячи нужны
# только для хвоста распределения, а он относится к замеру под
# нагрузкой — там понадобится другой режим.
proc epd_collect {count {n 1}} {
     set names {RTT NET_FWD ECHO NET_REV}
     set data  {{} {} {} {}}
     set bad 0

     for {set i 0} {$i < $count} {incr i} {
          set s [epd_sample $n]
          if {[llength $s] == 0} { incr bad; continue }
          set iv [epd_intervals $s]
          lassign $iv rtt fwd ech rev
          # Отбрасываем несогласованные наборы вместо того, чтобы
          # портить ими статистику.
          if {[expr {$fwd + $ech + $rev}] != $rtt} { incr bad; continue }
          for {set k 0} {$k < 4} {incr k} {
               lset data $k [concat [lindex $data $k] [lindex $iv $k]]
          }
     }

     set got [llength [lindex $data 0]]
     puts ""
     puts "=== $got замеров из $count (отброшено: $bad) ==="
     if {$got == 0} { epd_status $n; return }

     puts [format "%-9s %8s %8s %9s   %s" "" "min" "max" "среднее" "нс (сред.)"]
     for {set k 0} {$k < 4} {incr k} {
          set v [lindex $data $k]
          set mn [lindex [lsort -integer $v] 0]
          set mx [lindex [lsort -integer $v] end]
          set sum 0
          foreach x $v { incr sum $x }
          set avg [expr {double($sum)/$got}]
          puts [format "%-9s %8d %8d %9.1f   %9.1f" \
                    [lindex $names $k] $mn $mx $avg [expr {$avg*$::EPD_CLK_NS}]]
     }
}
