#!/usr/bin/env bash
# =============================================================================
# run_sim_core.sh -- проверка барьера ap_sync_done у probe под xsim
# =============================================================================
#
#     source /tools/Xilinx/Vivado/2022.1/settings64.sh
#     cd kernel/user_krnl/hls_echo_probe_dual_krnl/src/hdl/tb
#     ./run_sim_core.sh
#
# ЧТО ПРОВЕРЯЕТ. Инстанцирует ВЕСЬ epd_core со всеми стадиями и считает, сколько
# раз каждая половина обращается к стеку за 3 млн тактов. Отвечает на один
# вопрос: срабатывает ли барьер ap_sync_done -- логическое И по ap_done всех
# стадий региона.
#
# ЗАЧЕМ ЭТО probe. Симптом на плате идентичен тому, что был у hls_dual_echo_krnl:
#
#     epd[1]: connAttempts=0 sent=0 echoRx=0 echoes=0 recv=0 timeouts=0
#     epd[1]: server listen: attempts=0 state=0(no-request)
#
# ВСЕ счётчики нули, включая timeouts. Это важно: если бы ядро работало, а пакет
# не доходил, timeoutCount РОС БЫ. Ноль означает, что epd_client_traffic не
# сделала ни одного прохода -- то есть ядро не стартовало, а не «измерение не
# сошлось».
#
# На dual_echo та же причина найдена и измерена: writes 1/1 при ap_ctrl_none ->
# 10/10 после перехода на s_axilite + ap_ctrl_hs. Ядра построены по одному
# шаблону, поэтому проверяем тем же тестом ДО правки.
#
# Тестбенч генерируется скриптом из сгенерированного RTL:
#
#     make -f Makefile.vivado user_ip USER_KRNL=hls_echo_probe_dual_krnl BOARD=u200
#     python3 gen_tb_core.py > tb_core_ap_done.sv
#     ./run_sim_core.sh core
#
# ОТДЕЛЬНОЕ ИМЯ ФАЙЛА. В этом же каталоге лежит run_sim.sh, который гоняет
# тестбенчи ВРЕЗОК (net_frame_filter, taps, ctrl) -- он про обёртку и остаётся
# валидным. Здесь про HLS-ядро, поэтому run_sim_core.sh.
#
# КОД ВОЗВРАТА: 0 если все прогнанные тестбенчи напечатали «ALL GREEN», иначе 1.

set -u

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDL_DIR="$(cd "$TB_DIR/.." && pwd)"
KRNL_DIR="$(cd "$TB_DIR/../../.." && pwd)"
KRNL="hls_echo_probe_dual_krnl"
WORK="$TB_DIR/xsim_work"

which xvlog >/dev/null 2>&1 || {
     echo "*** xvlog не найден. Подгрузите окружение Vivado:"
     echo "      source /tools/Xilinx/Vivado/2022.1/settings64.sh"
     exit 1
}

WHICH="${1:-all}"

# Сгенерированный RTL: тестбенч симулирует то железо, которое уходит в битстрим.
SYN_DIR=""
if [ "$WHICH" = "all" ] || [ "$WHICH" = "core" ] || [ "$WHICH" = "top" ] \
     || [ "$WHICH" = "stack" ]; then
     # Путь задаётся export_hls_ip.tcl: проект <ядро>_ip_proj, решение sol1.
     # Глоб по решению -- чтобы не ломаться при смене его имени.
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

fi

# Стадия инстанцирует регистровые слайсы на своих AXI-Stream портах
# (regslice_both_m_axis_tcp_listen_port_b_V_data_V_U и т.п.), поэтому один
# файл стадии не элаборируется:
#     ERROR: [VRFC 10-2063] Module <..._regslice_both> not found
# Добавляем ВСЕ .v решения: лишние модули не мешают -- xelab берёт только те,
# что достижимы от указанного top, а перечислять зависимости вручную значило бы
# править этот список при каждом изменении портов ядра.
#
# Массив заполняется только когда SYN_DIR найден: иначе глоб дал бы литерал
# "/*.v", который xvlog принял бы за имя файла.
SRCS_V=()
if [ -n "$SYN_DIR" ]; then
     SRCS_V=( "$SYN_DIR"/*.v )
fi

mkdir -p "$WORK"
cd "$WORK" || exit 1

fails=0
ran=0        # сколько тестбенчей реально запущено -- см. проверку в конце

run_one () {
     local tb="$1" ; shift
     local srcs="$*"

     ran=$((ran+1))

     # Файл тестбенча должен существовать: при опечатке в пути xvlog падает с
     # невнятной ошибкой, а сам тестбенч молча не проверяет ничего.
     #
     # ВНИМАНИЕ НА РАЗБОР. Список файлов приходит ОДНОЙ строкой в $1 (вызовы ниже
     # передают многострочный литерал), поэтому "${@: -1}" -- последний АРГУМЕНТ --
     # это вся строка целиком, а не последний файл. Первая версия так и делала и
     # ломала прогон: `[ ! -f "<все 19 путей>" ]` истинно всегда. Берём последнее
     # СЛОВО через разбиение по пробелам.
     local -a srcs_arr=( $srcs )
     local tb_file="${srcs_arr[${#srcs_arr[@]}-1]}"
     if [ ! -f "$tb_file" ]; then
          echo ""
          echo "*** нет файла тестбенча: $tb_file"
          fails=$((fails+1)); return
     fi

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

# tb_core_ap_done -- ВЕСЬ epd_core: КТО из стадий не выдаёт ap_done и тем самым
# блокирует ap_continue всех остальных.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "core" ]; then
     # Тестбенч подключает порты epd_core ПОИМЕННО, поэтому он
     # привязан к текущему набору портов. Стоит правке в .cpp изменить состав
     # скаляров -- элаборация упадёт с «cannot find port». Это не ложное
     # срабатывание, а сигнал перегенерировать тестбенч (см. его шапку: он
     # создаётся скриптом из ${KRNL}_epd_core.v).
     #
     # Проверяем состав заранее и говорим прямо, что делать: иначе десяток
     # ошибок xelab читается как поломка теста, а не как устаревший список.
     core_v="$SYN_DIR/${KRNL}_epd_core.v"
     if [ -f "$core_v" ]; then
          n_ports_rtl=$(sed -n '/^module .*_epd_core/,/^);/p' "$core_v" \
                        | grep -cE "^\s+[a-zA-Z_][a-zA-Z0-9_]*,?\s*$")
          n_ports_tb=$(grep -cE "^\s+\.[a-zA-Z_][a-zA-Z0-9_]*\(" \
                        "$TB_DIR/tb_core_ap_done.sv")
          if [ "$n_ports_rtl" -ne "$n_ports_tb" ]; then
               echo ""
               echo "*** tb_core_ap_done устарел: в RTL $n_ports_rtl портов, в тестбенче $n_ports_tb."
               echo "    Состав портов epd_core изменился после правки .cpp."
               echo "    Тестбенч генерируется скриптом из"
               echo "      $core_v"
               echo "    -- см. шапку tb_core_ap_done.sv. Перегенерируйте его."
               fails=$((fails+1))
          else
               run_one tb_core_ap_done "${SRCS_V[*]} $TB_DIR/tb_core_ap_done.sv"
          fi
     else
          run_one tb_core_ap_done "${SRCS_V[*]} $TB_DIR/tb_core_ap_done.sv"
     fi
fi

# tb_top_start -- ВЕРХНИЙ модуль. Предмет: доходит ли импульс ap_start до epd_core.
#
# tb_core_ap_done подаёт ap_start ПРЯМО в epd_core и потому не видит путь снаружи
# внутрь. Плата 18.08 показала, что дефект именно там: ap_ctrl=0x83 (ap_done=1),
# connAttempts=1 вместо ~4700 за 10 с, timeouts=0.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "top" ]; then
     TOP_TB="$TB_DIR/tb_top_start.sv"
     if [ ! -f "$TOP_TB" ]; then
          echo ""
          echo "*** нет $TOP_TB -- сначала сгенерируйте:"
          echo "      cd $TB_DIR && python3 gen_tb_top_start.py > tb_top_start.sv"
          fails=$((fails+1))
     else
          run_one tb_top_start "${SRCS_V[*]} $TOP_TB"
     fi
fi

# tb_stack_reply -- СТЕК ОТВЕЧАЕТ. Закрывает дыру всех прежних тестбенчей: ни один
# из пяти не поднимал TVALID на входах от стека, то есть всё измеренное описывало
# поведение при МОЛЧАЩЕМ стеке. На плате стек отвечает -- portState=2 получен из
# настоящего port_status.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "stack" ]; then
     ST_TB="$TB_DIR/tb_stack_reply.sv"
     if [ ! -f "$ST_TB" ]; then
          echo ""
          echo "*** нет $ST_TB -- сначала сгенерируйте:"
          echo "      cd $TB_DIR && python3 gen_tb_stack_reply.py > tb_stack_reply.sv"
          fails=$((fails+1))
     else
          run_one tb_stack_reply "${SRCS_V[*]} $ST_TB"
     fi
fi


echo ""
echo "============================================================"

# НИ ОДИН ТЕСТБЕНЧ НЕ ЗАПУСТИЛСЯ -- ЭТО ОШИБКА, А НЕ УСПЕХ.
#
# Раньше скрипт в этом случае печатал «всё зелёное» и возвращал 0: `fails`
# оставался нулём просто потому, что считать было нечего. Так и случилось при
# опечатке в имени режима -- прогон отрапортовал успех, ничего не проверив.
# Молчаливый зелёный результат хуже падения: он выглядит как доказательство.
if [ "$ran" -eq 0 ]; then
     echo "  ИТОГ: НЕ ЗАПУЩЕНО НИ ОДНОГО ТЕСТБЕНЧА"
     echo ""
     echo "  Аргумент '$WHICH' не совпал ни с одним режимом. Допустимые:"
     echo "      core     весь epd_core: кто из стадий не выдаёт ap_done"
     echo "      top      ВЕРХНИЙ модуль: доходит ли ap_start до epd_core"
     echo "      stack    СТЕК ОТВЕЧАЕТ: open_status, port_status, TREADY=0"
     echo "      all      всё перечисленное (значение по умолчанию)"
     echo "============================================================"
     exit 1
fi

if [ "$fails" -eq 0 ]; then
     echo "  ИТОГ: всё зелёное ($ran тестбенчей)"
     echo "============================================================"
     exit 0
else
     echo "  ИТОГ: НЕ ПРОШЛО тестбенчей: $fails из $ran"
     echo "  Логи: $WORK/*.log"
     echo "============================================================"
     exit 1
fi
