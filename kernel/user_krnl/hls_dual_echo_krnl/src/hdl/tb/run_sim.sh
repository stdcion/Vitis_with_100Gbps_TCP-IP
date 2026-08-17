#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- прогон тестбенчей hls_dual_echo_krnl под xsim
# =============================================================================
#
#     source /tools/Xilinx/Vivado/2022.1/settings64.sh
#     cd kernel/user_krnl/hls_dual_echo_krnl/src/hdl/tb
#     ./run_sim.sh
#
# ЧЕМ ЭТОТ ПРОГОН ОТЛИЧАЕТСЯ ОТ СОСЕДНЕГО (probe). Там симулируется НАША
# обёртка. Здесь -- СГЕНЕРИРОВАННЫЙ HLS-RTL, то есть ровно то железо, которое
# уходит в битстрим. Поэтому файл берётся не из репозитория, а из каталога
# HLS-проекта, и его надо сначала создать:
#
#     make -f Makefile.vivado user_ip USER_KRNL=hls_dual_echo_krnl BOARD=u200
#
# КОД ВОЗВРАТА: 0 если напечатано «ALL GREEN», иначе 1.
#
# ВНИМАНИЕ. На НЕИСПРАВЛЕННОМ ядре этот тестбенч ДОЛЖЕН УПАСТЬ -- в этом его
# смысл. Он падает на проверке «стадия повторяет запрос», потому что при
# ap_start=1'b1 стадия делает конечное число проходов и замирает. Зелёный
# результат до правки означал бы, что тестбенч ничего не проверяет.

set -u

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KRNL_DIR="$(cd "$TB_DIR/../../.." && pwd)"
KRNL="hls_dual_echo_krnl"
WORK="$TB_DIR/xsim_work"

which xvlog >/dev/null 2>&1 || {
     echo "*** xvlog не найден. Подгрузите окружение Vivado:"
     echo "      source /tools/Xilinx/Vivado/2022.1/settings64.sh"
     exit 1
}

# Сгенерированный RTL. Путь задаётся export_hls_ip.tcl: проект <ядро>_ip_proj,
# решение sol1. Ищем глобом, чтобы не ломаться при смене имени решения.
SYN_DIRS=( $(ls -d "$KRNL_DIR/src/hls/${KRNL}_ip_proj"/*/syn/verilog 2>/dev/null) )
if [ "${#SYN_DIRS[@]}" -eq 0 ]; then
     echo "*** не найден сгенерированный RTL HLS-ядра."
     echo "    Ожидался каталог: $KRNL_DIR/src/hls/${KRNL}_ip_proj/*/syn/verilog"
     echo "    Сначала выполните:"
     echo "      make -f Makefile.vivado user_ip USER_KRNL=$KRNL BOARD=u200"
     exit 1
fi
if [ "${#SYN_DIRS[@]}" -gt 1 ]; then
     echo "*** найдено несколько решений HLS -- неясно, какое симулировать:"
     for d in "${SYN_DIRS[@]}"; do echo "      $d"; done
     echo "    Удалите лишние и повторите."
     exit 1
fi
SYN_DIR="${SYN_DIRS[0]}"
echo "HLS RTL: $SYN_DIR"

LISTEN_V="$SYN_DIR/${KRNL}_dual_echo_listen.v"
if [ ! -f "$LISTEN_V" ]; then
     echo "*** нет $LISTEN_V"
     echo "    Похоже, csynth прошёл, но стадия названа иначе. Содержимое:"
     ls "$SYN_DIR" | head -20
     exit 1
fi

# Стадия инстанцирует регистровые слайсы на своих AXI-Stream портах
# (regslice_both_m_axis_tcp_listen_port_b_V_data_V_U и т.п.), поэтому один
# файл стадии не элаборируется:
#     ERROR: [VRFC 10-2063] Module <..._regslice_both> not found
# Добавляем ВСЕ .v решения: лишние модули не мешают -- xelab берёт только те,
# что достижимы от указанного top, а перечислять зависимости вручную значило бы
# править этот список при каждом изменении портов ядра.
SRCS_V=( "$SYN_DIR"/*.v )

mkdir -p "$WORK"
cd "$WORK" || exit 1

fails=0

run_one () {
     local tb="$1" ; shift
     local srcs="$*"

     echo ""
     echo "============================================================"
     echo "  $tb"
     echo "============================================================"

     if ! xvlog -sv $srcs > "$tb.vlog.log" 2>&1; then
          echo "*** РАЗБОР НЕ ПРОШЁЛ -- xvlog. Полный лог: $WORK/$tb.vlog.log"
          grep -E "ERROR|error" "$tb.vlog.log" | head -20
          fails=$((fails+1)); return
     fi

     if ! xelab -debug typical "$tb" -s "${tb}_sim" > "$tb.elab.log" 2>&1; then
          echo "*** ЭЛАБОРАЦИЯ НЕ ПРОШЛА -- xelab. Полный лог: $WORK/$tb.elab.log"
          grep -E "ERROR|error" "$tb.elab.log" | head -20
          fails=$((fails+1)); return
     fi

     xsim "${tb}_sim" -runall > "$tb.sim.log" 2>&1
     sed -n '/^=== /,$p' "$tb.sim.log"

     if grep -q "ALL GREEN" "$tb.sim.log"; then
          :
     else
          echo "*** $tb НЕ ПРОШЁЛ. Полный лог: $WORK/$tb.sim.log"
          fails=$((fails+1))
     fi
}

run_one tb_listen_start "${SRCS_V[*]} $TB_DIR/tb_listen_start.sv"

echo ""
echo "============================================================"
if [ "$fails" -eq 0 ]; then
     echo "  ИТОГ: всё зелёное"
     echo "============================================================"
     exit 0
else
     echo "  ИТОГ: НЕ ПРОШЛО тестбенчей: $fails"
     echo "  Логи: $WORK/*.log"
     echo "============================================================"
     exit 1
fi
