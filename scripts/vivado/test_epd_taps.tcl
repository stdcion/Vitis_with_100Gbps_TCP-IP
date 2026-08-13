# =============================================================================
# test_epd_taps.tcl -- прогон epd_* на модели железа, без Vivado и без платы
# =============================================================================
#
#     tclsh scripts/vivado/test_epd_taps.tcl
#
# ЧТО ПРОВЕРЯЕТ. Арифметику и раскладку хостовой части измерения задержки:
# порог фильтра кадров, восемь таймстемпов, семь интервалов, вычитание по модулю
# 2^32 на обороте счётчика, ширину CSV, поведение на битстриме БЕЗ врезок.
#
# ЧЕГО НЕ ПРОВЕРЯЕТ. Транспорт: create_hw_axi_txn/run_hw_axi заменены
# заглушками, регистровый файл живёт в массиве Tcl. Реальный JTAG, наличие
# hw_axi_1 и ответы устройства -- только на плате. Верилог тоже не проверяется:
# net_frame_filter.v и обёртка здесь не участвуют, их модель -- proc hw_round.
#
# ЗАЧЕМ ОН ЕСТЬ. Поймал реальный дефект при написании: строка TIMEOUT в epd_raw
# была на один столбец короче заголовка. Короткая строка сдвигает все столбцы
# после себя, то есть таблица читает net_rev как echo, и числа остаются
# правдоподобными -- ровно тот класс ошибки, который на глаз не виден.
#
# МОДЕЛЬ ЗАДАЁТ СЕМЬ РАЗНЫХ задержек намеренно: при одинаковых перепутанные
# местами регистры дали бы те же суммы, и тест прошёл бы на неверной раскладке.
# Она же воспроизводит сдвиг штамповки t против T (T_SHIFT) -- без него residual
# в тесте всегда ноль и проверка ничего не значит.

set REPO [file normalize [file dirname [info script]]/../..]

# ── модель железа ─────────────────────────────────────────────────────────────
# Регистровый файл + генератор круга. Задержки заданы так, чтобы каждый из семи
# интервалов был РАЗНЫМ — иначе перепутанные местами регистры не поймать.
array set ::HW {}
set ::HW(0x74) 2   ;# minWords по сбросу

# истинные задержки в тактах
set ::D(s0tx) 40
set ::D(extA) 22
set ::D(s1rx) 55
set ::D(echo) 7
set ::D(s1tx) 44
set ::D(extB) 25
set ::D(s0rx) 51

# Сдвиг штамповки t относительно T: точки t идут через ap_vld
# зарегистрированного выхода HLS, точки T — прямо с шины. Модель обязана его
# воспроизводить, иначе residual в тесте всегда ноль и проверка ничего не даёт.
set ::T_SHIFT 1

set ::HW_CLOCK 4294967200   ;# около границы 2^32 — проверяем оборот

proc hw_round {} {
     # Круг: t1' -> T1' -> T2' -> t2' -> t1 -> T1 -> T2 -> t2
     set c $::HW_CLOCK
     set t1p $c
     set T1p [expr {($t1p + $::D(s0tx) - $::T_SHIFT) & 0xFFFFFFFF}]
     set T2p [expr {($T1p + $::D(extA)) & 0xFFFFFFFF}]
     set t2p [expr {($T2p + $::D(s1rx) + $::T_SHIFT) & 0xFFFFFFFF}]
     set t1  [expr {($t2p + $::D(echo)) & 0xFFFFFFFF}]
     set T1  [expr {($t1  + $::D(s1tx) - $::T_SHIFT) & 0xFFFFFFFF}]
     set T2  [expr {($T1  + $::D(extB)) & 0xFFFFFFFF}]
     set t2  [expr {($T2  + $::D(s0rx) + $::T_SHIFT) & 0xFFFFFFFF}]

     set ::HW(0x60) $t1p
     set ::HW(0x64) $t2p
     set ::HW(0x68) $t1
     set ::HW(0x6c) $t2
     set ::HW(0x78) $T1p
     set ::HW(0x7c) $T2p
     set ::HW(0x80) $T1
     set ::HW(0x84) $T2
     set ::HW(0x70) 1
     # счётчики кадров: наши прошли, служебные отсеяны
     foreach a {0x88 0x8c} { set ::HW($a) [expr {[info exists ::HW($a)] ? $::HW($a)+2 : 2}] }
     foreach a {0x90 0x94} { set ::HW($a) [expr {[info exists ::HW($a)] ? $::HW($a)+3 : 3}] }
     # шкала уходит вперёд между замерами
     set ::HW_CLOCK [expr {($t2 + 900) & 0xFFFFFFFF}]
}

# ── заглушки транспорта ──────────────────────────────────────────────────────
proc ouch_base_user {n} { return 0 }
proc _hex2int {s} { scan $s %x v ; return $v }

proc axi_write32 {addr val} {
     set key [format 0x%x $addr]
     set ::HW($key) $val
     if {$key eq "0x38"} { hw_round }   ;# triggerGo запускает круг
}
proc axi_read32 {addr} {
     set key [format 0x%x $addr]
     if {[info exists ::HW($key)]} { return $::HW($key) }
     return 0
}
proc epd_status {{n 1}} { puts "  (epd_status stub)" }
proc vio_dump {args} {}

# ── подгружаем только epd-часть скрипта ──────────────────────────────────────
# Целиком source не выйдет: файл содержит вызовы Vivado на верхнем уровне.
# Берём диапазон от определения смещений до конца epd_collect.
set fh [open $REPO/scripts/vivado/jtag_ctrl.tcl r]
set src [split [read $fh] "\n"]
close $fh

set from -1 ; set to -1
for {set i 0} {$i < [llength $src]} {incr i} {
     set l [lindex $src $i]
     if {$from < 0 && [string match "set ::EPD_OFF_ENABLE*" $l]} { set from $i }
     if {[string match "*For per-sample raw counters*" $l]} { set to [expr {$i+2}] }
}
if {$from < 0 || $to < 0} { puts "FAIL: не нашёл границы epd-блока ($from..$to)"; exit 1 }
set chunk [join [lrange $src $from $to] "\n"]
# epd_status уже заглушен выше — переопределение из файла нам не мешает,
# оно всё равно только печатает.
if {[catch {eval $chunk} err]} { puts "FAIL eval: $err"; exit 1 }
puts "epd-блок загружен: строки [expr {$from+1}]..[expr {$to+1}]"

# ── проверки ─────────────────────────────────────────────────────────────────
set fails 0
proc ok {name cond} {
     if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; incr ::fails }
}

puts "\n=== 1. epd_configure: порог и отказ на мелких кадрах ==="
ok "msgBytes=8 отвергнут"  [expr {[epd_configure 0a01d499 7001 8] == 0}]
ok "msgBytes=31 отвергнут" [expr {[epd_configure 0a01d499 7001 31] == 0}]
ok "msgBytes=32 принят"    [expr {[epd_configure 0a01d499 7001 32] == 1}]
ok "minWords(32)=2"        [expr {[axi_read32 0x74] == 2}]
foreach {mb want} {32 2 64 2 128 3 256 5 512 9 1024 17 1500 25} {
     epd_configure 0a01d499 7001 $mb
     ok "minWords($mb)=$want" [expr {[axi_read32 0x74] == $want}]
}

puts "\n=== 2. epd_sample: восемь значений ==="
epd_configure 0a01d499 7001 64
# Ставим шкалу вплотную к границе 2^32 ПЕРЕД замером: обороты нужны именно в
# том круге, интервалы которого проверяем ниже. Настройка выше уже прогнала
# несколько кругов и увела счётчик вперёд.
set ::HW_CLOCK 4294967200
set s [epd_sample]
ok "восемь стемпов" [expr {[llength $s] == 8}]
puts "     $s"

puts "\n=== 3. epd_intervals: семь интервалов совпали с моделью ==="
set iv [epd_intervals $s]
ok "десять полей" [expr {[llength $iv] == 10}]
lassign $iv rtt fwd ech rev s0tx extA s1rx s1tx extB s0rx
# T-точки штампуются на T_SHIFT раньше, значит STACK_*_TX занижены на сдвиг,
# а STACK_*_RX завышены. Модель это и воспроизводит.
ok "EXT_A  == $::D(extA)"  [expr {$extA == $::D(extA)}]
ok "EXT_B  == $::D(extB)"  [expr {$extB == $::D(extB)}]
ok "ECHO   == $::D(echo)"  [expr {$ech  == $::D(echo)}]
ok "STACK_0_TX == s0tx-сдвиг" [expr {$s0tx == $::D(s0tx) - $::T_SHIFT}]
ok "STACK_1_RX == s1rx+сдвиг" [expr {$s1rx == $::D(s1rx) + $::T_SHIFT}]
ok "STACK_1_TX == s1tx-сдвиг" [expr {$s1tx == $::D(s1tx) - $::T_SHIFT}]
ok "STACK_0_RX == s0rx+сдвиг" [expr {$s0rx == $::D(s0rx) + $::T_SHIFT}]
set want_fwd [expr {$::D(s0tx)+$::D(extA)+$::D(s1rx)}]
set want_rev [expr {$::D(s1tx)+$::D(extB)+$::D(s0rx)}]
ok "NET_FWD == сумма трёх" [expr {$fwd == $want_fwd}]
ok "NET_REV == сумма трёх" [expr {$rev == $want_rev}]
ok "RTT == сумма семи" [expr {$rtt == $want_fwd + $::D(echo) + $want_rev}]
ok "баланс fwd+echo+rev == rtt" [expr {$fwd+$ech+$rev == $rtt}]
# СЕМЬ слагаемых тоже обязаны складываться в RTT — это тождество, но если бы
# я перепутал знак в одном из вычитаний, оно бы развалилось.
ok "семь слагаемых == RTT" \
     [expr {$s0tx+$extA+$s1rx+$ech+$s1tx+$extB+$s0rx == $rtt}]
# residual: то, ради чего сдвиг вообще смоделирован. Он должен быть НУЛЁМ,
# потому что сдвиг сокращается внутри тройки (−1 у TX, +1 у RX).
set res_f [expr {($s0tx+$extA+$s1rx) - $fwd}]
ok "residual fwd == 0 (сдвиг сокращается внутри тройки)" [expr {$res_f == 0}]

puts "\n=== 4. оборот счётчика 2^32 ==="
# Модель стартовала около границы, значит хотя бы один интервал пересёк её.
ok "все интервалы положительны и малы" \
     [expr {$rtt > 0 && $rtt < 1000 && $extA > 0 && $s0rx > 0}]
ok "оборот действительно был" [expr {[lindex $s 3] < [lindex $s 0]}]

puts "\n=== 5. epd_measure печатает и возвращает 18 полей ==="
set m [epd_measure]
ok "18 полей (8 стемпов + 10 интервалов)" [expr {[llength $m] == 18}]

puts "\n=== 6. epd_raw: заголовок и строки одной ширины ==="
set csv [epd_raw 3]
set lines [split $csv "\n"]
set ncol [llength [split [lindex $lines 0] ","]]
ok "21 столбец в заголовке" [expr {$ncol == 21}]
set widths_ok 1
foreach l [lrange $lines 1 end] {
     if {[llength [split $l ","]] != $ncol} { set widths_ok 0 ; puts "     ширина: [llength [split $l ,]] в '$l'" }
}
ok "все строки той же ширины" $widths_ok

puts "\n=== 7. epd_raw: строка TIMEOUT выравнена ==="
# Ломаем sampleReady, чтобы получить TIMEOUT.
rename epd_sample epd_sample_real
proc epd_sample {{n 1} {timeout_ms 500}} { return {} }
set csv2 [epd_raw 1]
set tl [lindex [split $csv2 "\n"] 1]
ok "TIMEOUT-строка в 21 столбец" [expr {[llength [split $tl ","]] == 21}]
ok "последнее поле = TIMEOUT" [expr {[lindex [split $tl ","] end] eq "TIMEOUT"}]
rename epd_sample {}
rename epd_sample_real epd_sample

puts "\n=== 8. epd_collect: статистика по десяти сериям ==="
set ::EPD_WARMUP 1
epd_collect 5

puts "\n=== 9. битстрим БЕЗ врезок: T читаются нулями ==="
# Модель без врезок: круг ставит только четыре t, T остаются нулями.
proc hw_round {} {
     set c $::HW_CLOCK
     set t1p $c
     set t2p [expr {($t1p + 117) & 0xFFFFFFFF}]
     set t1  [expr {($t2p + 7)   & 0xFFFFFFFF}]
     set t2  [expr {($t1  + 120) & 0xFFFFFFFF}]
     set ::HW(0x60) $t1p ; set ::HW(0x64) $t2p
     set ::HW(0x68) $t1  ; set ::HW(0x6c) $t2
     set ::HW(0x78) 0 ; set ::HW(0x7c) 0 ; set ::HW(0x80) 0 ; set ::HW(0x84) 0
     set ::HW(0x70) 1
     set ::HW_CLOCK [expr {($t2 + 900) & 0xFFFFFFFF}]
}
set s0 [epd_sample]
set iv0 [epd_intervals $s0]
lassign $iv0 r0 f0 e0 v0 x0
ok "четыре классических интервала целы" [expr {$r0 == 244 && $f0 == 117 && $e0 == 7 && $v0 == 120}]
ok "шесть полей врезок пустые" [expr {$x0 eq "" && [lindex $iv0 9] eq ""}]
ok "нет фабрикации из нулей (не ~2^32)" [expr {$r0 < 1000}]
puts "  -- epd_measure на таком битстриме:"
epd_measure
puts "  -- epd_collect на таком битстриме:"
epd_collect 3

puts "\n=== 10. epd_net_status: три состояния ==="
proc chk_net {label ca cb da db mw} {
     set ::HW(0x88) $ca ; set ::HW(0x8c) $cb
     set ::HW(0x90) $da ; set ::HW(0x94) $db ; set ::HW(0x74) $mw
     puts "  -- $label"
     epd_net_status
}
chk_net "норма" 20 20 35 35 2
chk_net "фильтр режет всё (minWords завышен)" 0 0 60 60 25
chk_net "врезка мертва" 0 0 0 0 2

puts ""
if {$fails == 0} { puts "ВСЁ ЗЕЛЁНОЕ" } else { puts "ОТКАЗОВ: $fails" ; exit 1 }
