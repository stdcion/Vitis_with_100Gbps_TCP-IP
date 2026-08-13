#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- прогон HDL-тестбенчей врезок под xsim (идёт с Vivado)
# =============================================================================
#
#     cd kernel/user_krnl/hls_echo_probe_dual_krnl/src/hdl/tb
#     ./run_sim.sh
#
# Ничего ставить не надо: xvlog/xelab/xsim входят в Vivado. Нужен только
# settings64.sh в окружении (тот же, что для сборки).
#
# ЗАПУСТИТЬ ОДИН ТЕСТБЕНЧ:
#     ./run_sim.sh filter    -- только net_frame_filter
#     ./run_sim.sh taps      -- только врезки в обёртке
#
# ЧТО ЭТО ПРОВЕРЯЕТ, ЧЕГО НЕ ПРОВЕРЯЕТ csim:
#
#   csim гоняет C++ ЯДРА. Ни обёртки, ни фильтра, ни врезок он не видит вообще
#   -- они на Verilog. То есть вся логика, добавленная для больших T, сейчас
#   НЕ покрыта ничем, кроме моделей на Python/Tcl, а модели проверяют замысел,
#   а не написанный код.
#
#   Здесь симулируется НАСТОЯЩИЙ .v/.sv, поэтому ловятся: опечатка в индексе
#   бита, неверная разрядность, забытый сброс, перепутанные каналы врезок,
#   непрозрачный passthrough.
#
# ЧЕГО НЕ ПРОВЕРЯЕТ И ЭТОТ ПРОГОН: тайминг (WNS -- это impl) и HLS-ядро (это
# csim). Врезки от ядра не зависят: axis_net_* в него не заходят, поэтому в
# tb_probe_taps.sv стоит заглушка вместо ядра.
#
# ПОЧЕМУ СООБЩЕНИЯ ТЕСТБЕНЧЕЙ НА ЛАТИНИЦЕ. $display в xsim 2024.1 портит
# многобайтовые символы: строка «строба НЕТ -- отсечён МАРКЕРОМ» печаталась как
# «Т --». Ни [255:0], ни string, ни макрос вместо задачи это не лечат -- дело в
# самом выводе. Чисто ASCII-строки печатаются верно всегда, поэтому сообщения
# англоязычные. КОММЕНТАРИИ в тестбенчах остаются русскими: их читают в файле,
# а не через симулятор.
#
# КОД ВОЗВРАТА: 0 если все тестбенчи напечатали «ALL GREEN», иначе 1 --
# чтобы можно было ставить в цепочку.

set -u

HDL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TB_DIR="$HDL_DIR/tb"
WORK="$TB_DIR/xsim_work"

which xvlog >/dev/null 2>&1 || {
     echo "*** xvlog не найден. Подгрузите окружение Vivado:"
     echo "      source /tools/Xilinx/Vivado/2022.1/settings64.sh"
     exit 1
}

WHICH="${1:-all}"

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

     # -sv: тестбенчи и обёртка на SystemVerilog; фильтр и регистры на Verilog,
     # xvlog разберёт их и в sv-режиме.
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
     # Печатаем всё, что напечатал тестбенч (строки с ok/FAIL и заголовки),
     # отбрасывая шапку самого xsim.
     sed -n '/^=== /,$p' "$tb.sim.log"

     if grep -q "ALL GREEN" "$tb.sim.log"; then
          :
     else
          echo "*** $tb НЕ ПРОШЁЛ. Полный лог: $WORK/$tb.sim.log"
          fails=$((fails+1))
     fi
}

if [ "$WHICH" = "all" ] || [ "$WHICH" = "filter" ]; then
     run_one tb_net_frame_filter \
          "$HDL_DIR/net_frame_filter.v $TB_DIR/tb_net_frame_filter.sv"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "taps" ]; then
     # Обёртка тянет за собой probe_control_s_axi.v и net_frame_filter.v;
     # HLS-ядро заменено заглушкой внутри самого тестбенча.
     run_one tb_probe_taps \
          "$HDL_DIR/net_frame_filter.v $HDL_DIR/probe_control_s_axi.v \
           $HDL_DIR/hls_echo_probe_dual_krnl_wrapper.sv $TB_DIR/tb_probe_taps.sv"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "ctrl" ]; then
     # tb_probe_ctrl использует ТУ ЖЕ заглушку ядра, что объявлена в
     # tb_probe_taps.sv, поэтому оба файла компилируются вместе. Дублировать
     # заглушку (182 порта) во втором файле значило бы завести второе место,
     # которое надо править при каждом изменении обёртки.
     run_one tb_probe_ctrl \
          "$HDL_DIR/net_frame_filter.v $HDL_DIR/probe_control_s_axi.v \
           $HDL_DIR/hls_echo_probe_dual_krnl_wrapper.sv \
           $TB_DIR/tb_probe_taps.sv $TB_DIR/tb_probe_ctrl.sv"
fi

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
