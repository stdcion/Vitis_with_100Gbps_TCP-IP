#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- прогон тестбенчей hls_dual_echo_krnl под xsim
# =============================================================================
#
#     source /tools/Xilinx/Vivado/2022.1/settings64.sh
#     cd kernel/user_krnl/hls_dual_echo_krnl/src/hdl/tb
#     ./run_sim.sh
#
# ДВА ТЕСТБЕНЧА, ДВА РАЗНЫХ ПРЕДМЕТА -- и это разделение существенно, потому что
# симптом на плате (enable записан и читается, а portState=0) может дать и то, и
# другое:
#
#   ./run_sim.sh listen   tb_listen_start    -- СГЕНЕРИРОВАННЫЙ HLS-RTL, одна
#                                              стадия: механизм отказа
#   ./run_sim.sh core     tb_core_ap_done    -- ВЕСЬ dual_echo_core, 14 стадий:
#                                              КТО не выдаёт ap_done
#   ./run_sim.sh ctrl     tb_dual_echo_ctrl  -- НАША HDL-ОБЁРТКА: доходит ли
#                                              enable от AXI-Lite до порта ядра
#   ./run_sim.sh          (то же, что all)   -- все три
#
# tb_listen_start берёт RTL не из репозитория, а из каталога HLS-проекта, то есть
# ровно то железо, которое уходит в битстрим. Его надо сначала создать:
#
#     make -f Makefile.vivado user_ip USER_KRNL=hls_dual_echo_krnl BOARD=u200
#
# tb_dual_echo_ctrl HLS-проект не требует -- ему нужны только src/hdl/*.v и две
# заглушки в tb/. Но заглушка ядра СГЕНЕРИРОВАНА из того же HLS-RTL, поэтому при
# изменении портов ядра её надо перегенерировать (см. её шапку).
#
# ЧТО УЖЕ ВЫЯСНЕНО tb_listen_start (прогон 17.08.2026): стадия listen ИСПРАВНА.
# enable доходит, поздняя запись работает, ap_start=1'b1 не блокирует (602549
# проходов), ветка таймаута повторяет запрос. Значит симптом платы этой стадией
# не объясняется -- откуда и взялся второй тестбенч.
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

# Сгенерированный RTL нужен tb_listen_start и tb_core_ap_done. tb_dual_echo_ctrl
# работает от src/hdl/*.v и заглушек, поэтому при `run_sim.sh ctrl` отсутствие
# HLS-проекта не должно останавливать прогон: иначе проверку обёртки нельзя было бы
# сделать без csynth, а она от ядра не зависит.
SYN_DIR=""
if [ "$WHICH" = "all" ] || [ "$WHICH" = "listen" ] || [ "$WHICH" = "core" ]; then
     # Путь задаётся export_hls_ip.tcl: проект <ядро>_ip_proj, решение sol1.
     # Глоб по решению -- чтобы не ломаться при смене его имени.
     SYN_DIRS=( $(ls -d "$KRNL_DIR/src/hls/${KRNL}_ip_proj"/*/syn/verilog 2>/dev/null) )
     if [ "${#SYN_DIRS[@]}" -eq 0 ]; then
          echo "*** не найден сгенерированный RTL HLS-ядра."
          echo "    Ожидался каталог: $KRNL_DIR/src/hls/${KRNL}_ip_proj/*/syn/verilog"
          echo "    Сначала выполните:"
          echo "      make -f Makefile.vivado user_ip USER_KRNL=$KRNL BOARD=u200"
          echo ""
          echo "    Либо прогоните только проверку обёртки, ей csynth не нужен:"
          echo "      ./run_sim.sh ctrl"
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
# Массив заполняется только когда SYN_DIR найден: при `run_sim.sh ctrl` его нет,
# и глоб дал бы литерал "/*.v", который xvlog принял бы за имя файла.
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
     run_one tb_core_ap_done "${SRCS_V[*]} $TB_DIR/tb_core_ap_done.sv"
fi

# tb_dual_echo_ctrl -- НАША HDL-ОБЁРТКА: доходит ли enable от AXI-Lite до порта
# ядра. Здесь настоящие wrapper.sv и dual_echo_control_s_axi.v, а HLS-ядро и VIO
# заменены заглушками: проверяется путь управления, а не логика ядра.
#
# Заглушка ядра сгенерирована из того же hls_dual_echo_krnl.v, что уходит в
# битстрим (см. её шапку), поэтому расхождение имён портов невозможно по
# построению -- а именно такое расхождение дало бы молча неподключённый порт.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "ctrl" ]; then
     run_one tb_dual_echo_ctrl \
          "$HDL_DIR/dual_echo_control_s_axi.v \
           $HDL_DIR/hls_dual_echo_krnl_wrapper.sv \
           $TB_DIR/stub_hls_dual_echo_krnl_ip.v \
           $TB_DIR/stub_vio_dual_echo_dbg.v \
           $TB_DIR/tb_dual_echo_ctrl.sv"
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
     echo "      ctrl     HDL-обёртка и путь enable от AXI-Lite"
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
