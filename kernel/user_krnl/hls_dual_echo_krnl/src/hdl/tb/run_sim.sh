#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- прогон тестбенчей hls_dual_echo_krnl под xsim
# =============================================================================
#
#     source /tools/Xilinx/Vivado/2022.1/settings64.sh
#     cd kernel/user_krnl/hls_dual_echo_krnl/src/hdl/tb
#     ./run_sim.sh
#
# ДВА ТЕСТБЕНЧА, ДВА РАЗНЫХ ПРЕДМЕТА: одна стадия отдельно и весь регион целиком.
# Разделение существенно -- стадия может быть исправна, а регион всё равно стоять,
# и наоборот. Именно так и вышло: tb_listen_start месяц показывал зелёное, пока
# tb_core_ap_done не назвал причиной барьер ap_sync_done.
#
#   ./run_sim.sh listen   tb_listen_start    -- СГЕНЕРИРОВАННЫЙ HLS-RTL, одна
#                                              стадия: механизм отказа
#   ./run_sim.sh core     tb_core_ap_done    -- ВЕСЬ dual_echo_core, 14 стадий:
#                                              КТО не выдаёт ap_done
#   ./run_sim.sh top      tb_top_start       -- ВЕРХНИЙ модуль: доходит ли
#                                              импульс ap_start до *_core, или
#                                              внешний DATAFLOW его съедает
#   ./run_sim.sh          (то же, что all)   -- все
#
# РЕЖИМ ctrl УДАЛЁН вместе с HDL-обёрткой. Он проверял путь enable от AXI-Lite до
# порта ядра -- у ядра больше нет ни обёртки, ни enable: регистры генерирует HLS
# (s_axilite), а роль enable выполняет ap_start. Проверять стало нечего.
#
# tb_listen_start берёт RTL не из репозитория, а из каталога HLS-проекта, то есть
# ровно то железо, которое уходит в битстрим. Его надо сначала создать:
#
#     make -f Makefile.vivado user_ip USER_KRNL=hls_dual_echo_krnl BOARD=u200
#
#
# СОСТОЯНИЕ НА 17.08.2026: tb_core_ap_done -- ALL GREEN на s_axilite + ap_ctrl_hs.
# 10 повторов listen за 3 млн тактов, portState=1, listenAttempts совпадает с
# числом записей на шине, обе половины идентичны.
#
# tb_listen_start написан под прежнюю схему (ap_ctrl_none, аргумент enable, вечный
# цикл) и на текущем ядре НЕ ЭЛАБОРИРУЕТСЯ: у стадии больше нет порта enableB.
# Оставлен как история разбора; актуальная проверка -- core.
#
# КОД ВОЗВРАТА: 0 если все прогнанные тестбенчи напечатали «ALL GREEN», иначе 1.

set -u

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDL_DIR="$(cd "$TB_DIR/.." && pwd)"
KRNL_DIR="$(cd "$TB_DIR/../../.." && pwd)"
KRNL="hls_dual_echo_krnl"
WORK="$TB_DIR/xsim_work"

which xvlog >/dev/null 2>&1 || {
     echo "*** xvlog не найден. Подгрузите окружение Vivado:"
     echo "      source /tools/Xilinx/Vivado/2022.1/settings64.sh"
     exit 1
}

WHICH="${1:-all}"

# Сгенерированный RTL нужен обоим тестбенчам: они симулируют то железо, которое
# уходит в битстрим.
SYN_DIR=""
if [ "$WHICH" = "all" ] || [ "$WHICH" = "listen" ] || [ "$WHICH" = "core" ] \
     || [ "$WHICH" = "top" ]; then
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

     LISTEN_V="$SYN_DIR/${KRNL}_dual_echo_listen.v"
     if [ ! -f "$LISTEN_V" ]; then
          echo "*** нет $LISTEN_V"
          echo "    Похоже, csynth прошёл, но стадия названа иначе. Содержимое:"
          ls "$SYN_DIR" | head -20
          exit 1
     fi
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

# tb_listen_start -- СГЕНЕРИРОВАННЫЙ HLS-RTL: работает ли сама стадия listen.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "listen" ]; then
     run_one tb_listen_start "${SRCS_V[*]} $TB_DIR/tb_listen_start.sv"
fi

# tb_core_ap_done -- ВЕСЬ dual_echo_core со всеми 14 стадиями: КТО из них не
# выдаёт ap_done и тем самым блокирует ap_continue всех остальных.
# tb_listen_start показывает МЕХАНИЗМ (фазы 6-7), этот -- ВИНОВНИКА.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "core" ]; then
     # Тестбенч подключает 219 портов dual_echo_core ПОИМЕННО, поэтому он
     # привязан к текущему набору портов. Стоит правке в .cpp изменить состав
     # скаляров -- элаборация упадёт с «cannot find port». Это не ложное
     # срабатывание, а сигнал перегенерировать тестбенч (см. его шапку: он
     # создаётся скриптом из hls_dual_echo_krnl_dual_echo_core.v).
     #
     # Проверяем состав заранее и говорим прямо, что делать: иначе десяток
     # ошибок xelab читается как поломка теста, а не как устаревший список.
     core_v="$SYN_DIR/${KRNL}_dual_echo_core.v"
     if [ -f "$core_v" ]; then
          n_ports_rtl=$(sed -n '/^module .*_dual_echo_core/,/^);/p' "$core_v" \
                        | grep -cE "^\s+[a-zA-Z_][a-zA-Z0-9_]*,?\s*$")
          n_ports_tb=$(grep -cE "^\s+\.[a-zA-Z_][a-zA-Z0-9_]*\(" \
                        "$TB_DIR/tb_core_ap_done.sv")
          if [ "$n_ports_rtl" -ne "$n_ports_tb" ]; then
               echo ""
               echo "*** tb_core_ap_done устарел: в RTL $n_ports_rtl портов, в тестбенче $n_ports_tb."
               echo "    Состав портов dual_echo_core изменился после правки .cpp."
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

# tb_top_start -- ВЕРХНИЙ модуль. Предмет: доходит ли импульс ap_start до
# внутреннего *_core, или внешний DATAFLOW-регион съедает его.
#
# Отдельный тестбенч, а не фаза в core, потому что предмет ДРУГОЙ: core проверяет
# внутренний регион, получив ap_start напрямую, и по построению не может увидеть
# путь снаружи внутрь. Именно этот слепой участок и дал ложную уверенность 17.08.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "top" ]; then
     TOP_TB="$TB_DIR/tb_top_start.sv"
     if [ ! -f "$TOP_TB" ]; then
          echo ""
          echo "*** нет $TOP_TB -- сначала сгенерируйте:"
          echo "      cd $TB_DIR && python3 gen_tb_top_start.py > tb_top_start.sv"
          fails=$((fails+1))
     else
          # Тестбенч ссылается на инстанс core ИЕРАРХИЧЕСКИ (dut.<inst>.ap_start).
          # Если правка .cpp убрала вложенный регион, инстанса не станет, xelab
          # упадёт с «cannot find» -- и это ОЖИДАЕМЫЙ результат, означающий, что
          # дефект устранён, а тест больше не нужен. Говорим об этом прямо.
          run_one tb_top_start "${SRCS_V[*]} $TOP_TB"
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
     echo "      listen   стадия dual_echo_listen на сгенерированном RTL"
     echo "      core     весь dual_echo_core, все 14 стадий"
     echo "      top      ВЕРХНИЙ модуль: доходит ли ap_start до core"
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
