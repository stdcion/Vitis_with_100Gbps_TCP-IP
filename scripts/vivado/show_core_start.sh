#!/usr/bin/env bash
# =============================================================================
# show_core_start.sh -- чем управляется ap_start внутреннего DATAFLOW-региона
# =============================================================================
#
# Три строки RTL, которые отвечают на вопрос точнее любой симуляции: транслирует
# ли верхний модуль импульс ap_start внутрь, или внутренний регион получает его
# от барьера внешнего.
#
# ЗАЧЕМ. tb_top_start (18.08) показал на probe: импульс доходит ОДИН раз
# (ap_start seen=1), дальше core стоит в ap_idle=1 даже при поднятом ap_start,
# а половины ведут себя по-разному (writes a += 2, b += 0). Симуляция говорит
# ЧТО происходит; эта выборка говорит ПОЧЕМУ -- видно имя сигнала-драйвера.
#
# ЧТО ИСКАТЬ В ВЫВОДЕ:
#
#   .ap_start(ap_start)              -- импульс идёт напрямую, вложенность НЕ виновата
#   .ap_start(ap_sync_continue)      -- барьер внешнего региона: вложенность
#   .ap_start(<...>_ap_start_reg)    -- регистр внешнего региона, смотреть его сброс
#
# Запуск на сборочной машине:
#     ./scripts/vivado/show_core_start.sh hls_echo_probe_dual_krnl _epd_core
#     ./scripts/vivado/show_core_start.sh hls_dual_echo_krnl _dual_echo_core

set -u
KRNL="${1:-hls_echo_probe_dual_krnl}"
SUFFIX="${2:-_epd_core}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYN=$(ls -d "$REPO/kernel/user_krnl/$KRNL/src/hls/${KRNL}_ip_proj"/*/syn/verilog 2>/dev/null | head -1)

if [ -z "$SYN" ]; then
     echo "*** не найден сгенерированный RTL для $KRNL"
     echo "    Сначала: make -f Makefile.vivado user_ip USER_KRNL=$KRNL BOARD=u200"
     exit 1
fi
TOP="$SYN/$KRNL.v"
CORE="$SYN/${KRNL}${SUFFIX}.v"
echo "RTL: $SYN"
echo ""

echo "=== 1. инстанс ${KRNL}${SUFFIX} внутри $KRNL.v: чем питается ap_start ==="
# Печатаем блок инстанса целиком: важен не только ap_start, но и ap_continue.
awk -v mod="${KRNL}${SUFFIX}" '
     index($0, mod) && /\(/ {inst=1}
     inst {print}
     inst && /\);/ {inst=0}
' "$TOP" | head -40
echo ""

echo "=== 2. откуда берётся этот сигнал (assign/always в $KRNL.v) ==="
# Имена, которыми HLS обычно связывает вложенные регионы.
grep -nE "ap_sync_continue|ap_sync_done|ap_start_reg|ap_continue|ap_idle_reg" "$TOP" | head -20
echo ""

echo "=== 3. внутри core: ap_continue стадий -- барьер или единица ==="
grep -nE "assign\s+\w+_ap_continue\s*=" "$CORE" | head -8
echo ""

echo "=== 4. есть ли в core собственный ap_sync_done (признак ВЛОЖЕННОГО барьера) ==="
grep -nE "assign\s+ap_sync_done\s*=" "$CORE" | head -3
echo ""
echo "ЧИТАТЬ ТАК: если в п.1 у .ap_start(...) стоит не ap_start, а сигнал из п.2 --"
echo "импульс перехватывает внешний регион, и внутренний pragma HLS DATAFLOW лишний."
