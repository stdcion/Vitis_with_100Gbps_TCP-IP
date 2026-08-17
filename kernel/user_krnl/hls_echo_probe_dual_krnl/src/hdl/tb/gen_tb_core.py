#!/usr/bin/env python3
"""Генератор tb_core_ap_done.sv для hls_echo_probe_dual_krnl.

Копия скрипта из hls_dual_echo_krnl/src/hdl/tb, отличаются только KRNL и
CORE_SUFFIX. Логика общая: у probe тот же барьер ap_sync_done, и симптом на
плате был идентичным -- все счётчики нули, state=0(no-request), timeouts=0.

ЗАЧЕМ. dual_echo_core имеет ~219 портов, и тестбенч подключает их поимённо.
Руками такой список не поддерживается: любая правка состава скаляров в .cpp
делает тестбенч неэлаборируемым (ошибки «cannot find port»), а опечатка в имени
даёт молча неподключённый вход -- ровно тот класс дефекта, который этот тест и
должен ловить.

ЗАПУСК (из каталога tb):
    python3 gen_tb_core.py > tb_core_ap_done.sv

Каталог с RTL находится сам; можно указать путь первым аргументом.
"""

import re
import sys
from pathlib import Path

# Ядро и имя core-функции задаются аргументами: тот же дефект (барьер
# ap_sync_done) есть у hls_echo_probe_dual_krnl, и проверять его надо тем же
# тестом, а не копией скрипта.
#
#     python3 gen_tb_core.py                       # dual_echo, путь ищется сам
#     python3 gen_tb_core.py <путь к *_core.v>     # любое ядро
KRNL = "hls_echo_probe_dual_krnl"
CORE_SUFFIX = "_epd_core"

CTRL = {"ap_clk", "ap_rst", "ap_start", "ap_done", "ap_idle", "ap_ready",
        "ap_continue"}

# Скаляры, которые ведёт тестбенч, и их значения. Всё остальное на входах --
# потоки: TVALID=0 (стек молчит), TREADY=1 (стек принимает), данные нули.
# Значения для входных скаляров. Перечислены ВСЕ, что встречаются у обоих ядер;
# подставляются только те, которые реально есть в этом RTL -- остальные молча
# пропускаются. Так один скрипт обслуживает dual_echo и probe.
SCAL_IN = {
    # dual_echo
    "enableA":       "32'd1",
    "enableB":       "32'd1",
    "listenPortA":   "32'd7001",
    "listenPortB":   "32'd7002",
    # probe: enable разделён на три (у каждого ОДИН читатель, см. .cpp)
    "enableConn":    "32'd1",
    "enableTraffic": "32'd1",
    "enableListen":  "32'd1",
    "serverIp":      "32'h0a01d499",
    "serverPort":    "32'd7001",
    "listenPort":    "32'd7001",
    "msgBytes":      "32'd64",
    "triggerGo":     "32'd0",   # меняется тестом: см. фазу trigger ниже
}


def find_core_v(explicit=None):
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else p / (KRNL + CORE_SUFFIX + ".v")
    here = Path(__file__).resolve().parent
    krnl_dir = here.parents[2]          # .../hls_dual_echo_krnl
    pattern = ("src/hls/%s_ip_proj/*/syn/verilog/%s%s.v"
               % (KRNL, KRNL, CORE_SUFFIX))
    hits = sorted(krnl_dir.glob(pattern))
    if not hits:
        sys.exit("*** не найден сгенерированный RTL. Сначала:\n"
                 "      make -f Makefile.vivado user_ip USER_KRNL=%s BOARD=u200"
                 % KRNL)
    if len(hits) > 1:
        sys.exit("*** несколько решений HLS:\n  "
                 + "\n  ".join(str(h) for h in hits))
    return hits[0]


def width(w):
    mm = re.match(r"\[(\d+)\s*:\s*(\d+)\]", w)
    return int(mm.group(1)) - int(mm.group(2)) + 1 if mm else 1


def default_for(name, w):
    if name.endswith("TVALID"):
        return "1'b0"
    if name.endswith("TREADY"):
        return "1'b1"
    return "%d'd0" % width(w)


core_v = find_core_v(sys.argv[1] if len(sys.argv) > 1 else None)
src = core_v.read_text()

# Ищем ЛЮБОЙ *_core: у probe модуль называется ..._epd_core.
m = re.search(r"module\s+(\w*_core)\s*\((.*?)\);", src, re.S)
if not m:
    sys.exit("*** не разобрать список портов в %s" % core_v)
core_module = m.group(1)
names = [p.strip() for p in m.group(2).split(",") if p.strip()]

decl = {}
for mm in re.finditer(r"^(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*;", src, re.M):
    d, w, n = mm.groups()
    decl[n] = (d, (w or "").strip())

missing = [n for n in names if n not in decl]
if missing:
    sys.exit("*** нет объявлений для портов: %s" % missing)

stages = re.findall(r"^\w+ (\w+_U0)\(", src, re.M)
if not stages:
    sys.exit("*** не найдено ни одного инстанса стадии (*_U0)")

# Присутствует ли в этой ревизии RTL телеметрия наружу. После правок в .cpp она
# может исчезнуть (HLS выбрасывает выходные скаляры незавершающейся функции),
# и тогда тестбенч не должен на них ссылаться.
# Шины, по которым видно, что половина ядра работает. Первый найденный вариант
# из списка -- у dual_echo это listen_port на обеих половинах, у probe на a стоит
# open_connection (клиент открывает соединение, а не слушает).
def pick_bus(cands, side):
    for c in cands:
        n = c % side
        if (n + "_TVALID") in decl:
            return n
    sys.exit("*** не найдена шина активности для половины %s (искал: %s)"
             % (side, [c % side for c in cands]))


BUS_A = pick_bus(["m_axis_tcp_listen_port_%s", "m_axis_tcp_open_connection_%s"], "a")
BUS_B = pick_bus(["m_axis_tcp_listen_port_%s", "m_axis_tcp_open_connection_%s"], "b")

have_state = all(n in decl and decl[n][0] == "output"
                 for n in ("portState_a", "portState_b"))
have_att = all(n in decl and decl[n][0] == "output"
               for n in ("listenAttempts_a", "listenAttempts_b"))

L = []
add = L.append

add("// =============================================================================")
add("// tb_core_ap_done -- СГЕНЕРИРОВАН gen_tb_core.py, НЕ ПРАВИТЬ РУКАМИ")
add("// =============================================================================")
add("//")
add("// Источник портов: %s" % core_v.name)
add("// Портов: %d, стадий: %d" % (len(names), len(stages)))
add("//")
add("// ЧТО ПРОВЕРЯЕТ. Инстанцирует ВЕСЬ dual_echo_core со всеми стадиями и читает")
add("// ap_done каждой иерархически. Отвечает на вопрос «кто держит барьер")
add("// ap_sync_done» -- логическое И по ap_done всех стадий региона. Пока хотя бы")
add("// одна стадия не завершается, барьер не срабатывает и ap_continue никого не")
add("// блокирует; если завершаются все -- регион встаёт после первого прохода.")
add("//")
add("// УСЛОВИЯ ЛУЧШЕ, ЧЕМ НА ПЛАТЕ, И ЭТО НАМЕРЕННО: enable=1 и listenPort заданы с")
add("// нулевого такта, все m_axis_*_TREADY=1 (стек принимает мгновенно), все")
add("// s_axis_*_TVALID=0 (стек молчит, как при неоткрытом порте). Если регион встаёт")
add("// в таких условиях -- на плате тем более.")
add("//")
add("// ПЕРЕГЕНЕРАЦИЯ после правки .cpp:")
add("//     python3 gen_tb_core.py > tb_core_ap_done.sv")
add("//")
add("// Сообщения на латинице: $display в xsim 2024.1 портит многобайтовые символы.")
add("")
add("`timescale 1ns / 1ps")
add("`default_nettype none")
add("")
add("module tb_core_ap_done;")
add("")
add("logic ap_clk = 1'b0;")
add("always #2.5 ap_clk = ~ap_clk;")
add("")
add("logic ap_rst = 1'b1;          // core ждёт АКТИВНЫЙ-ВЫСОКИЙ сброс")
add("")
add("// ── ap_start: КОНСТАНТА ИЛИ ИМПУЛЬСЫ -- ПРЕДМЕТ ЭТОГО ТЕСТА ──────────────────")
add("//")
add("// Сейчас ядро ap_ctrl_none, и в топе оба сигнала зашиты в единицу:")
add("//     assign dual_echo_core_U0_ap_start    = 1'b1;")
add("//     assign dual_echo_core_U0_ap_continue = 1'b1;")
add("//")
add("// ВОПРОС, НА КОТОРЫЙ ОТВЕЧАЕТ ТЕСТ: снимет ли барьер ap_sync_done переход на")
add("// ap_ctrl_hs + auto_restart, то есть на штатную схему upstream. Там ap_start")
add("// ИМПУЛЬСНЫЙ, и именно импульс сбрасывает регистры готовности стадий")
add("// (core.v: if ((ap_sync_ready & ap_start) == 1'b1) ap_sync_reg <= 0).")
add("//")
add("// Логика импульса взята ДОСЛОВНО из сгенерированного HLS control_s_axi")
add("// работающего hls_recv_krnl (control_s_axi.v:278-288):")
add("//")
add("//     if (w_hs && waddr == ADDR_AP_CTRL && WSTRB[0] && WDATA[0])")
add("//          int_ap_start <= 1'b1;")
add("//     else if (ap_ready)")
add("//          int_ap_start <= int_auto_restart;   // clear on handshake/auto restart")
add("//")
add("// То есть ap_start опускается на ap_ready и сразу поднимается обратно, пока")
add("// auto_restart (бит 7 регистра ap_ctrl, отсюда запись 0x81) взведён.")
add("//")
add("// AP_START_MODE выбирает режим:")
add("//   0 -- как сейчас: константа 1'b1 (ap_ctrl_none). Ожидаемо: барьер срабатывает.")
add("//   1 -- как у recv: импульсы по ap_ready (ap_ctrl_hs + auto_restart).")
add("// Прогоняются ОБА, и результаты печатаются рядом: разница в одном сигнале, всё")
add("// остальное идентично, поэтому вывод однозначен.")
add("logic ap_start    = 1'b1;")
add("logic ap_continue = 1'b1;")
add("wire  ap_done, ap_idle, ap_ready;")
add("")
add("logic auto_restart = 1'b0;   // бит 7 ap_ctrl; 0 в режиме ap_ctrl_none")
add("logic pulse_mode   = 1'b0;   // 1 = моделируем control_s_axi")
add("")
add("always @(posedge ap_clk) begin")
add("     if (ap_rst) begin")
add("          if (!pulse_mode) ap_start <= 1'b1;   // ap_ctrl_none: единица всегда")
add("     end else if (pulse_mode) begin")
add("          if (ap_ready) ap_start <= auto_restart;")
add("          else if (!ap_start && auto_restart) ap_start <= 1'b1;")
add("     end")
add("end")
add("")

add("// ── скаляры, которые ведёт тестбенч ──────────────────────────────────────────")
for n, val in SCAL_IN.items():
    if n in decl and decl[n][0] == "input":
        w = decl[n][1]
        add("logic %s%s = %s;" % (w + " " if w else "", n, val))

add("")
add("// ── входы-потоки: стек молчит и всё принимает ────────────────────────────────")
for n in names:
    d, w = decl[n]
    if d != "input" or n in CTRL or n in SCAL_IN or n.endswith("_ap_vld"):
        continue
    add("logic %s%s = %s;" % (w + " " if w else "", n, default_for(n, w)))

add("")
add("// ── выходы ───────────────────────────────────────────────────────────────────")
for n in names:
    d, w = decl[n]
    if d != "output" or n in CTRL:
        continue
    add("wire %s%s;" % (w + " " if w else "", n))

add("")
add("// ── регион целиком ───────────────────────────────────────────────────────────")
add("%s dut (" % core_module)
conn = []
for n in names:
    d, w = decl[n]
    if n.endswith("_ap_vld") and d == "input":
        conn.append("     .%s(1'b1)" % n)      # скаляр всегда действителен
    else:
        conn.append("     .%s(%s)" % (n, n))
add(",\n".join(conn))
add(");")
add("")

add("// ── наблюдение ───────────────────────────────────────────────────────────────")
# ЧТО СЧИТАЕМ КАК «ЯДРО НАЧАЛО РАБОТАТЬ». У ядер это разные шины:
#   dual_echo -- обе половины слушают порт: m_axis_tcp_listen_port_a и _b;
#   probe     -- половина b слушает (listen_port_b), а половина a ОТКРЫВАЕТ
#                соединение (m_axis_tcp_open_connection_a).
# Выбираем по факту наличия в этом RTL, а не по имени ядра: так один скрипт
# обслуживает оба, и добавление третьего ядра не потребует правки.
add("int unsigned port_writes_a = 0, port_writes_b = 0;")
add("")
add("// ЗАЩЁЛКА ТЕЛЕМЕТРИИ ПО ap_vld -- ТАК ЖЕ, КАК ЭТО ДЕЛАЕТ ОБЁРТКА НА ПЛАТЕ.")
add("//")
add("// Выходной скаляр HLS с формой ap_vld действителен ТОЛЬКО в такте, когда")
add("// поднят соответствующий *_ap_vld. Между обновлениями значение на шине не")
add("// определено: внутри стадии его держит теневой регистр *_preg, но наружу")
add("// отдаётся комбинационный выход.")
add("//")
add("// Первая версия теста читала portState_a напрямую в конце прогона и получала")
add("// нули при исправном ядре -- то есть тест сам создавал тот ложный симптом,")
add("// который мы искали в железе. Ловушка ровно та же, что на плате: там значения")
add("// защёлкивает dual_echo_control_s_axi по ap_vld, и читать надо защёлку.")
for nm in ("listenAttempts_a", "portState_a", "listenAttempts_b", "portState_b"):
    if nm in decl and decl[nm][0] == "output" and (nm + "_ap_vld") in decl:
        add("logic [31:0] lat_%s = 32'hDEAD_BEEF;   // не 0: «не приходило» != «пришёл 0»" % nm)
add("")
add("always @(posedge ap_clk) begin")
add("     if (!ap_rst) begin")
for nm in ("listenAttempts_a", "portState_a", "listenAttempts_b", "portState_b"):
    if nm in decl and decl[nm][0] == "output" and (nm + "_ap_vld") in decl:
        add("          if (%s_ap_vld) lat_%s <= %s;" % (nm, nm, nm))
add("     end")
add("end")
add("")
add("always @(posedge ap_clk) begin")
add("     if (!ap_rst) begin")
add("          if (%s_TVALID && %s_TREADY)" % (BUS_A, BUS_A))
add("               port_writes_a <= port_writes_a + 1;")
add("          if (%s_TVALID && %s_TREADY)" % (BUS_B, BUS_B))
add("               port_writes_b <= port_writes_b + 1;")
add("     end")
add("end")
add("")
add("localparam int N_STAGES = %d;" % len(stages))
add("string stage_name [N_STAGES];")
add("int unsigned done_cnt [N_STAGES];")
add("wire [N_STAGES-1:0] stage_done = {")
add(",\n".join("     dut.%s_ap_done" % s for s in reversed(stages)))
add("};")
add("")
add("initial begin")
for i, s in enumerate(stages):
    add('     stage_name[%d] = "%s";' % (i, s))
add("end")
add("")
add("always @(posedge ap_clk) begin")
add("     if (!ap_rst)")
add("          for (int i = 0; i < N_STAGES; i++)")
add("               if (stage_done[i]) done_cnt[i] <= done_cnt[i] + 1;")
add("end")
add("")
add("// ap_done РЕГИОНА -- он же ap_sync_done. Ноль означает, что барьер не")
add("// срабатывает ни разу, то есть ap_continue никого не блокирует.")
add("int unsigned region_done_cnt = 0;")
add("")
add("always @(posedge ap_clk) begin")
add("     if (!ap_rst && ap_done) region_done_cnt <= region_done_cnt + 1;")
add("end")
add("")
add("int unsigned fails = 0;")
add("int unsigned n_never = 0;")
add("")
add("task automatic check(string what, bit cond);")
add('     if (cond) $display("  ok   %s", what);')
add('     else begin $display("  FAIL %s", what); fails++; end')
add("endtask")
add("")
add("// LISTEN_TIMEOUT = 1e6 ПРОХОДОВ стадии; при II=2 это ~2 млн тактов. Берём с")
add("// запасом: длительность считается в проходах x II, а не в тактах по константе")
add("// из .cpp -- на этом дважды обожглись, см. docs/kernel_scheme_handoff.md.")
add("localparam int RUN = 3_000_000;")
add("")
add("// Итоги прогонов, чтобы сравнить режимы в конце.")
add("int unsigned res_writes_a [2];")
add("int unsigned res_writes_b [2];")
add("int unsigned res_region_done [2];")
add("")
add("// Один прогон в заданном режиме ap_start. Всё, кроме ap_start, идентично.")
add("task automatic run_once(input int mode);")
add("     ap_rst      = 1'b1;")
add("     pulse_mode  = (mode == 1);")
add("     auto_restart = (mode == 1);")
add("     ap_start    = 1'b1;")
add("     repeat (4) @(posedge ap_clk);")
add("     port_writes_a   = 0;")
add("     port_writes_b   = 0;")
add("     region_done_cnt = 0;")
add("     for (int i = 0; i < N_STAGES; i++) done_cnt[i] = 0;")
add("     repeat (4) @(posedge ap_clk);")
add("     ap_rst = 1'b0;")
add("     repeat (RUN) @(posedge ap_clk);")
add("     res_writes_a[mode]    = port_writes_a;")
add("     res_writes_b[mode]    = port_writes_b;")
add("     res_region_done[mode] = region_done_cnt;")
add("endtask")
add("")
add("initial begin")
add('     $display("=== tb_core_ap_done: who holds the ap_sync_done barrier ===");')
add('     $display("");')
add("")
add("     // Режим 0: ap_start = 1'b1, как в текущем битстриме (ap_ctrl_none).")
add('     $display("--- mode 0: ap_start tied to 1 (ap_ctrl_none, what we have) ---");')
add("     run_once(0);")
add('     $display("  writes a=%0d b=%0d   region ap_done cycles=%0d",')
add("              res_writes_a[0], res_writes_b[0], res_region_done[0]);")
add("")
add("     // Режим 1: ap_start импульсами, как control_s_axi у recv с auto_restart.")
add('     $display("");')
add('     $display("--- mode 1: ap_start pulsed on ap_ready (ap_ctrl_hs + auto_restart) ---");')
add("     run_once(1);")
add('     $display("  writes a=%0d b=%0d   region ap_done cycles=%0d",')
add("              res_writes_a[1], res_writes_b[1], res_region_done[1]);")
add("")
add('     $display("");')
add('     $display("--- detail of mode 1 (%0d cycles, enable=1, TREADY=1, silent stack) ---", RUN);')
add('     $display("  listen_port writes: a=%0d b=%0d", port_writes_a, port_writes_b);')
if have_state:
    add('     $display("  portState      a=%0d b=%0d  (latched on ap_vld)",')
    add("              lat_portState_a, lat_portState_b);")
if have_att:
    add('     $display("  listenAttempts a=%0d b=%0d  (latched on ap_vld)",')
    add("              lat_listenAttempts_a, lat_listenAttempts_b);")
if not (have_state and have_att):
    add('     $display("  NOTE: telemetry outputs are ABSENT in this RTL revision.");')
    add('     $display("        HLS drops output scalars of a function that never returns.");')
add('     $display("  region ap_done=%0b ap_idle=%0b ap_ready=%0b", ap_done, ap_idle, ap_ready);')
add('     $display("  region ap_done cycles: %0d", region_done_cnt);')
add("")
add('     $display("");')
add('     $display("--- ap_done cycles per stage (0 = NEVER -> holds the barrier) ---");')
add("     for (int i = 0; i < N_STAGES; i++) begin")
add('          $display("  %-34s %0d", stage_name[i], done_cnt[i]);')
add("          if (done_cnt[i] == 0) n_never++;")
add("     end")
add("")
add('     $display("");')
add('     $display("--- verdict ---");')
add("     if (n_never == 0) begin")
add('          $display("  Every stage finishes, so ap_sync_done is evaluated every");')
add('          $display("  cycle and needs all stages ready in the SAME cycle. With");')
add('          $display("  mixed II that never happens -> region freezes after one pass.");')
add("     end else begin")
add('          $display("  %0d stage(s) never finish -> the barrier never fires,", n_never);')
add('          $display("  which is exactly what upstream relies on. Holding it:");')
add("          for (int i = 0; i < N_STAGES; i++)")
add('               if (done_cnt[i] == 0) $display("      %s", stage_name[i]);')
add("     end")
add("")
add("     // ── ГЛАВНОЕ СРАВНЕНИЕ: СНИМАЕТ ЛИ ИМПУЛЬСНЫЙ ap_start БАРЬЕР ───────")
add("     //")
add("     // Между режимами отличается РОВНО ОДИН сигнал -- ap_start. Всё остальное")
add("     // (enable, TREADY, длительность, стадии) идентично, поэтому разница в")
add("     // числе записей однозначно приписывается схеме управления.")
add('     $display("");')
add('     $display("--- ap_ctrl_none vs ap_ctrl_hs+auto_restart ---");')
add('     $display("  mode 0 (const 1) : writes a=%0d b=%0d, region ap_done=%0d",')
add("              res_writes_a[0], res_writes_b[0], res_region_done[0]);")
add('     $display("  mode 1 (pulsed)  : writes a=%0d b=%0d, region ap_done=%0d",')
add("              res_writes_a[1], res_writes_b[1], res_region_done[1]);")
add('     $display("");')
add("     if (res_writes_a[1] >= res_writes_a[0] && res_writes_b[1] >= res_writes_b[0])")
add('          $display("  Pulsed ap_start is NOT worse -> ap_ctrl_hs + auto_restart is safe");')
add('     else  $display("  *** Pulsed ap_start is WORSE -> ap_ctrl_hs would REGRESS behaviour");')
add("")
add("     // При молчащем стеке listen ОБЯЗАН повторять запрос по таймауту в ЛЮБОМ")
add("     // режиме. Одна запись за прогон = регион заморожен.")
add('     $display("");')
add('     check("mode 0: half a retries (>1 write)", res_writes_a[0] > 1);')
add('     check("mode 0: half b retries (>1 write)", res_writes_b[0] > 1);')
add('     check("mode 1: half a retries (>1 write)", res_writes_a[1] > 1);')
add('     check("mode 1: half b retries (>1 write)", res_writes_b[1] > 1);')
add("")
add("     // ТЕЛЕМЕТРИЯ ДОЛЖНА ДОХОДИТЬ ДО ПОРТА, а не только считаться внутри.")
add("     // HLS отдаёт выходной скаляр на пути к возврату из функции, поэтому")
add("     // записи только внутри тела цикла до порта НЕ доходят: порт либо")
add("     // выбрасывается совсем (dangling в логе csynth), либо держит значение,")
add("     // записанное до входа в цикл. На плате это выглядит как «ядро молчит»")
add("     // при работающем ядре -- ровно тот ложный симптом, из-за которого")
add("     // причину искали месяц. Проверяем прямо, потому что csynth про это")
add("     // предупреждает не всегда.")
add("")
add("     // ap_vld ДОЛЖЕН ПОДНЯТЬСЯ ХОТЯ БЫ РАЗ. Защёлки инициализированы")
add("     // 32'hDEADBEEF, и это НЕ ноль -- поэтому проверка «!= 0» проходила")
add("     // ложно-зелёной, пока ap_vld не поднимался ни разу. Сначала убеждаемся,")
add("     // что строб вообще был, и только потом смотрим на значение.")
if have_state:
    add('     check("portState a: ap_vld fired at least once",')
    add("           lat_portState_a !== 32'hDEAD_BEEF);")
    add('     check("portState b: ap_vld fired at least once",')
    add("           lat_portState_b !== 32'hDEAD_BEEF);")
    add('     check("portState a reflects work done inside the loop (!=0)",')
    add("           lat_portState_a !== 32'hDEAD_BEEF && lat_portState_a != 32'd0);")
    add('     check("portState b reflects work done inside the loop (!=0)",')
    add("           lat_portState_b !== 32'hDEAD_BEEF && lat_portState_b != 32'd0);")
if have_att:
    add('     check("listenAttempts a matches the writes counted on the bus",')
    add("           lat_listenAttempts_a == port_writes_a);")
    add('     check("listenAttempts b matches the writes counted on the bus",')
    add("           lat_listenAttempts_b == port_writes_b);")
add("")
add("     // АСИММЕТРИЯ ПОЛОВИН -- отдельная проверка, а не следствие двух выше.")
add("     // Половины сидят на РАЗНЫХ network_krnl и должны вести себя одинаково;")
add("     // расхождение означает, что что-то в дизайне их различает, и это тот")
add("     // класс дефекта, который легко не заметить (ср. два CMAC на одном GT-")
add("     // квадре: сборка зелёная, а работает только один канал).")
add('     check("both halves behave identically (writes)",')
add("           port_writes_a == port_writes_b);")
if have_state:
    add('     check("both halves behave identically (portState)",')
    add("           lat_portState_a == lat_portState_b);")
if not (have_state and have_att):
    add('     $display("");')
    add('     $display("  *** TELEMETRY LOST: outputs dropped by HLS. Writes to an");')
    add('     $display("      output scalar must exist OUTSIDE the loop body too,");')
    add('     $display("      otherwise the port is unreachable from the return path.");')
    add("     fails++;")
add("")
add('     $display("");')
add('     if (fails == 0) $display("=== ALL GREEN ===");')
add('     else            $display("=== FAILED: %0d ===", fails);')
add("     $finish;")
add("end")
add("")
add("initial begin")
add("     #40_000_000;")
add('     $display("*** TIMEOUT -- testbench did not finish");')
add("     $finish;")
add("end")
add("")
add("endmodule")
add("")
add("`default_nettype wire")

print("\n".join(L))
