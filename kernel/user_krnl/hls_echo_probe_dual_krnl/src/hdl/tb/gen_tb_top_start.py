#!/usr/bin/env python3
# =============================================================================
# gen_tb_top_start.py -- генератор tb_top_start.sv
# =============================================================================
#
# ЗАЧЕМ ЕЩЁ ОДИН ТЕСТ, ЕСЛИ tb_core_ap_done ЗЕЛЁНЫЙ.
#
# Потому что tb_core_ap_done инстанцирует *_core и подаёт ap_start ПРЯМО В НЕГО,
# минуя верхний уровень. Он доказал, что внутренний регион оживает от импульса --
# и не мог заметить, доходит ли импульс до него в реальном дизайне. На плате не
# доходит: probe 18.08 дал ap_ctrl=0x83 (ap_done=1, финишировал и залип),
# connAttempts=1 вместо ожидаемых ~4700 за 10 с, timeouts=0.
#
# Причина под проверкой: #pragma HLS DATAFLOW стоит ДВАЖДЫ -- на top-функции и
# внутри *_core. Регион вложенный, *_core сам стадия внешнего региона.
#
# ЧТО ДЕЛАЕТ ЭТОТ ТЕСТ. Инстанцирует ВЕРХНИЙ модуль (hls_<krnl>_krnl.v), дёргает
# ap_start ровно так, как это делает control_s_axi при записи 0x81, и смотрит
# ИЕРАРХИЧЕСКИ на внутренний core:
#
#     dut.<core>_U0_ap_start     -- дошёл ли импульс до внутреннего региона
#     dut.<core>_U0_ap_done      -- финиширует ли он
#     dut.ap_done                -- залипает ли top в done (подпись с платы)
#     плюс счётчик записей на живой шине -- работают ли стадии
#
# ПРЕДСКАЗАНИЕ (записано ДО прогона, чтобы тест нельзя было подогнать):
#   ЕСЛИ вложенность виновата -- writes останется единицами, а ap_done top
#   поднимется и не опустится, повторив 0x83 с платы.
#   ЕСЛИ импульс доходит нормально -- writes будет расти с каждым импульсом
#   ap_start, и гипотезу надо отбросить, а причину искать в другом.
#
# Тест НЕ ПРАВИТ .cpp и должен быть прогнан на ТЕКУЩЕМ RTL -- том самом, что
# лежит в неработающем битстриме. Только тогда он что-то доказывает.
#
# Запуск:
#     python3 gen_tb_top_start.py > tb_top_start.sv
#     ./run_sim.sh top
#
# Сообщения на латинице: $display в xsim 2024.1 портит многобайтовые символы.

import re
import sys
from pathlib import Path

# Настройки на ядро. У probe те же вопросы и тот же дефект, поэтому скрипт
# копируется в его tb/ с заменой этих двух строк (так же, как gen_tb_core.py).
KRNL = "hls_echo_probe_dual_krnl"
CORE_SUFFIX = "_epd_core"

# Значения скаляров. При s_axilite это внутренние регистры, а не порты top, и
# писать их надо было бы по AXI -- поэтому здесь только те, что реально торчат
# наружу (probe: регистры в своей обёртке, top их принимает портами).
SCAL_IN = {
    "enableA":       "32'd1",
    "enableB":       "32'd1",
    "listenPortA":   "32'd7001",
    "listenPortB":   "32'd7002",
    "enableConn":    "32'd1",
    "enableTraffic": "32'd1",
    "enableListen":  "32'd1",
    "serverIp":      "32'h0a01d499",
    "serverPort":    "32'd7001",
    "listenPort":    "32'd7001",
    "msgBytes":      "32'd64",
    "triggerGo":     "32'd0",
}


def find_v(name_suffix, explicit=None):
    """Ищет сгенерированный HLS-верилог. Без аргумента -- в ip_proj этого ядра."""
    if explicit:
        p = Path(explicit)
        if p.is_file():
            return p
        cand = p / (KRNL + name_suffix + ".v")
        if cand.is_file():
            return cand
        sys.exit("*** не найден %s в %s" % (KRNL + name_suffix + ".v", p))
    here = Path(__file__).resolve().parent
    krnl_dir = here.parents[2]
    pattern = ("src/hls/%s_ip_proj/*/syn/verilog/%s%s.v"
               % (KRNL, KRNL, name_suffix))
    hits = sorted(krnl_dir.glob(pattern))
    if not hits:
        sys.exit("*** не найден сгенерированный RTL (%s). Сначала:\n"
                 "      make -f Makefile.vivado user_ip USER_KRNL=%s BOARD=u200"
                 % (KRNL + name_suffix + ".v", KRNL))
    if len(hits) > 1:
        sys.exit("*** несколько решений HLS:\n  "
                 + "\n  ".join(str(h) for h in hits))
    return hits[0]


def width(w):
    mm = re.match(r"\[(\d+)\s*:\s*(\d+)\]", w)
    return int(mm.group(1)) - int(mm.group(2)) + 1 if mm else 1


arg = sys.argv[1] if len(sys.argv) > 1 else None
top_v = find_v("", arg)
core_v = find_v(CORE_SUFFIX, arg)
top_src = top_v.read_text()
core_src = core_v.read_text()

# ── разбор ВЕРХНЕГО модуля ───────────────────────────────────────────────────
m = re.search(r"module\s+(%s)\s*\((.*?)\);" % re.escape(KRNL), top_src, re.S)
if not m:
    sys.exit("*** не найден module %s в %s" % (KRNL, top_v))
top_module = m.group(1)
names = [p.strip() for p in m.group(2).split(",") if p.strip()]

decl = {}
for mm in re.finditer(r"^(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*;", top_src, re.M):
    d, w, n = mm.groups()
    decl[n] = (d, (w or "").strip())

missing = [n for n in names if n not in decl]
if missing:
    sys.exit("*** нет объявлений для портов top: %s" % missing)

# Есть ли у top блочный протокол. При s_axilite HLS делает s_axi_control и
# ap_start НАРУЖУ не выводит -- тогда импульс надо подавать иерархически, в
# регистр control_s_axi. Различаем это здесь, а не догадками.
HAS_AP_START_PORT = "ap_start" in decl and decl["ap_start"][0] == "input"
HAS_AXILITE = any(n.startswith("s_axi_control") for n in decl)

# ── как называется инстанс core внутри top ──────────────────────────────────
# Ищем инстанс модуля <KRNL><CORE_SUFFIX>. Имя инстанса нужно для иерархических
# ссылок: именно на нём проверяется, дошёл ли ap_start.
core_module = KRNL + CORE_SUFFIX
mi = re.search(r"\b%s\s+(?:#\([^)]*\)\s*)?(\w+)\s*\(" % re.escape(core_module),
               top_src)
if not mi:
    sys.exit("*** не найден инстанс %s внутри %s.\n"
             "    Возможно, вложенного региона уже нет -- тогда этот тест не нужен."
             % (core_module, top_module))
core_inst = mi.group(1)

# ── шина, по которой видно работу (тот же приём, что в gen_tb_core.py) ───────
# Различать надо по ДРАЙВЕРУ, а не по наличию порта: неиспользуемые шины
# заглушены tie_off_*, и счётчик на заглушке однажды уже дал ложную победу.
def driven_by_stage(bus):
    mm = re.search(r"assign\s+%s_TVALID\s*=\s*(\w+)" % re.escape(bus), core_src)
    return bool(mm) and not mm.group(1).startswith("tie_off")


def pick_active_bus(side):
    cands = ["m_axis_tcp_listen_port_%s" % side,
             "m_axis_tcp_open_connection_%s" % side]
    for c in cands:
        if driven_by_stage(c):
            return c
    for c in cands:
        if (c + "_TVALID") in decl:
            return c
    sys.exit("*** не найдена шина активности для половины %s" % side)


# Какие порты блочного протокола реально есть у core. Не предполагаем: ссылка на
# несуществующий порт валит элаборацию, и это читалось бы как поломка теста.
core_ports = set()
mcore = re.search(r"module\s+%s\s*\((.*?)\);" % re.escape(core_module), core_src, re.S)
if mcore:
    core_ports = {p.strip() for p in mcore.group(1).split(",") if p.strip()}
if "ap_start" not in core_ports:
    sys.exit("*** у %s нет порта ap_start -- проверять нечего" % core_module)
CORE_HAS_DONE = "ap_done" in core_ports
CORE_HAS_IDLE = "ap_idle" in core_ports

BUS_A = pick_active_bus("a")
BUS_B = pick_active_bus("b")

L = []
add = L.append

add("// =============================================================================")
add("// tb_top_start -- СГЕНЕРИРОВАН gen_tb_top_start.py, НЕ ПРАВИТЬ РУКАМИ")
add("// =============================================================================")
add("//")
add("// Источник: %s (портов %d)" % (top_v.name, len(names)))
add("//           %s" % core_v.name)
add("// Инстанс внутреннего региона: %s" % core_inst)
add("// ap_start портом: %s, s_axi_control: %s"
    % ("да" if HAS_AP_START_PORT else "НЕТ", "да" if HAS_AXILITE else "нет"))
add("//")
add("// ЧЕМ ОТЛИЧАЕТСЯ ОТ tb_core_ap_done. Тот подаёт ap_start ПРЯМО в *_core и")
add("// доказал, что внутренний регион оживает от импульса. Он не мог увидеть,")
add("// доходит ли импульс до core в реальном дизайне -- а на плате не доходит.")
add("// Здесь DUT -- ВЕРХНИЙ модуль, а внутренний core проверяется иерархически.")
add("//")
add("// ПРЕДСКАЗАНИЕ, записанное ДО прогона:")
add("//   вложенность виновата  -> writes единицы, ap_done top залипает в 1")
add("//   импульс доходит       -> writes растёт с каждым импульсом; гипотеза мертва")
add("")
add("`timescale 1ns / 1ps")
add("`default_nettype none")
add("")
add("module tb_top_start;")
add("")
add("logic ap_clk = 1'b0;")
add("always #2.5 ap_clk = ~ap_clk;")
add("logic ap_rst_n = 1'b0;        // top ждёт АКТИВНЫЙ-НИЗКИЙ сброс")
add("")
add("int unsigned writes_a = 0, writes_b = 0;")
add("int unsigned core_start_seen = 0, core_done_seen = 0, top_done_seen = 0;")
add("int unsigned fails = 0, checks = 0;")
add("")
add("// Импульс ap_start: ровно то, что делает control_s_axi при записи 0x81 --")
add("// поднять на такт и снять. auto_restart потом поднимает его снова сам.")
add("logic ap_start_q = 1'b0;")
add("")

# ── сигналы для портов top ──────────────────────────────────────────────────
add("// ── сигналы портов DUT ──────────────────────────────────────────────────────")
for n in names:
    d, w = decl[n]
    if n in ("ap_clk", "ap_rst_n", "ap_rst"):
        continue
    if n == "ap_start":
        continue
    kind = "wire" if d == "output" else "logic"
    ws = (w + " ") if w else ""
    init = ""
    if d == "input":
        if n in SCAL_IN:
            init = " = %s" % SCAL_IN[n]
        elif n.endswith("TVALID"):
            init = " = 1'b0"
        elif n.endswith("TREADY"):
            init = " = 1'b1"
        elif n.startswith("s_axi_control"):
            init = " = %d'd0" % width(w)
        else:
            init = " = %d'd0" % width(w)
    add("%s %s%s%s;" % (kind, ws, n, init))
add("")

# ── инстанс DUT ─────────────────────────────────────────────────────────────
add("// ── DUT: ВЕРХНИЙ модуль, не core ───────────────────────────────────────────")
add("%s dut (" % top_module)
conn = []
for n in names:
    if n == "ap_clk":
        conn.append("    .ap_clk(ap_clk)")
    elif n == "ap_rst_n":
        conn.append("    .ap_rst_n(ap_rst_n)")
    elif n == "ap_rst":
        conn.append("    .ap_rst(~ap_rst_n)")
    elif n == "ap_start":
        conn.append("    .ap_start(ap_start_q)")
    else:
        conn.append("    .%s(%s)" % (n, n))
add(",\n".join(conn))
add(");")
add("")

# ── иерархические ссылки на внутренний регион ───────────────────────────────
add("// ── ИЕРАРХИЧЕСКИ: что видит внутренний регион ──────────────────────────────")
add("//")
add("// Здесь и есть предмет теста. Если ap_start до core не доходит, эти сигналы")
add("// покажут это прямо, без домыслов.")
add("wire core_ap_start = dut.%s.ap_start;" % core_inst)
if CORE_HAS_DONE:
    add("wire core_ap_done  = dut.%s.ap_done;" % core_inst)
if CORE_HAS_IDLE:
    add("wire core_ap_idle  = dut.%s.ap_idle;" % core_inst)
add("")

add("// ── счётчики ───────────────────────────────────────────────────────────────")
add("always @(posedge ap_clk) begin")
add("    if (ap_rst_n) begin")
add("        if (%s_TVALID && %s_TREADY) writes_a <= writes_a + 1;" % (BUS_A, BUS_A))
add("        if (%s_TVALID && %s_TREADY) writes_b <= writes_b + 1;" % (BUS_B, BUS_B))
add("        if (core_ap_start) core_start_seen <= core_start_seen + 1;")
if CORE_HAS_DONE:
    add("        if (core_ap_done)  core_done_seen  <= core_done_seen  + 1;")
if "ap_done" in decl and decl["ap_done"][0] == "output":
    add("        if (ap_done)       top_done_seen   <= top_done_seen   + 1;")
add("    end")
add("end")
add("")

add("task automatic check(input string what, input bit ok, input string detail);")
add("    checks++;")
add("    if (ok) $display(\"  ok   : %s (%s)\", what, detail);")
add("    else begin fails++; $display(\"  FAIL : %s (%s)\", what, detail); end")
add("endtask")
add("")

add("initial begin")
add("    $display(\"\");")
add("    $display(\"=== tb_top_start: dohodit li ap_start do vnutrennego regiona ===\");")
add("    $display(\"  DUT      : %s\", \"" + top_module + "\");")
add("    $display(\"  core inst: %s\", \"" + core_inst + "\");")
add("    $display(\"  bus a/b  : %s / %s\", \"" + BUS_A + "\", \"" + BUS_B + "\");")
add("    $display(\"\");")
add("")
add("    // сброс")
add("    ap_rst_n = 1'b0;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst_n = 1'b1;")
add("    repeat (10) @(posedge ap_clk);")
add("")

if not HAS_AP_START_PORT:
    add("    // ── ap_start НЕ ПОРТ (s_axilite): импульс подаём force ────────────────")
    add("    //")
    add("    // ЧТО ИМЕННО ФОРСИМ И ПОЧЕМУ ЭТО ЧЕСТНО. dut.ap_start -- внутренний")
    add("    // провод, который ведёт control_s_axi при записи 0x81. force в xsim")
    add("    // перебивает этот драйвер, то есть подаёт РОВНО тот же импульс, что дал")
    add("    // бы хост. Писать по AXI-Lite незачем: предмет теста -- не декодер")
    add("    // адресов (он проверен на плате, ap_ctrl читается обратно), а доходит ли")
    add("    // импульс ОТСЮДА до стадий внутри core.")
    add("    //")
    add("    // ВАЖНО: форсим вход top-региона, а НЕ dut.%s.ap_start." % \
        "<core>")
    add("    // Форс прямо на входе core обошёл бы внешний регион и повторил бы")
    add("    // слепоту tb_core_ap_done -- ту самую, из-за которой 17.08 тест был")
    add("    // зелёным, а плата мёртвой.")
    add("    $display(\"-- phase 1: odin impuls ap_start (kak zapis 0x81) --\");")
    add("    force dut.ap_start = 1'b1;")
    add("    @(posedge ap_clk);")
    add("    release dut.ap_start;")
else:
    add("    $display(\"-- phase 1: odin impuls ap_start (kak zapis 0x81) --\");")
    add("    ap_start_q = 1'b1;")
    add("    @(posedge ap_clk);")
    add("    ap_start_q = 1'b0;")

add("")
add("    repeat (200000) @(posedge ap_clk);")
add("    $display(\"    posle 200k taktov: writes a=%0d b=%0d\", writes_a, writes_b);")
add("    $display(\"    core: ap_start seen=%0d ap_done seen=%0d\",")
add("             core_start_seen, core_done_seen);")
if CORE_HAS_IDLE:
    add("    $display(\"    core: ap_idle=%0b\", core_ap_idle);")
if "ap_done" in decl and decl["ap_done"][0] == "output":
    add("    $display(\"    top : ap_done seen=%0d (sejchas %0b)\", top_done_seen, ap_done);")
add("")
add("    check(\"impuls doshel do core\", core_start_seen > 0,")
add("          $sformatf(\"core ap_start seen=%0d\", core_start_seen));")
add("")

add("    // ── phase 2: auto_restart. Держим ap_start поднятым -- так ведёт себя")
add("    // control_s_axi с установленным битом 7: он не даёт региону простаивать.")
add("    $display(\"\");")
add("    $display(\"-- phase 2: auto_restart (ap_start derzhim podnjatym) --\");")
add("    begin")
add("        int unsigned wa0 = writes_a, wb0 = writes_b;")
add("        int unsigned cs0 = core_start_seen, cd0 = core_done_seen;")
if not HAS_AP_START_PORT:
    add("        force dut.ap_start = 1'b1;")
else:
    add("        ap_start_q = 1'b1;")
add("        repeat (1000000) @(posedge ap_clk);")
if not HAS_AP_START_PORT:
    add("        release dut.ap_start;")
else:
    add("        ap_start_q = 1'b0;")
add("        $display(\"    za 1M taktov pri podnjatom ap_start: writes a += %0d b += %0d\",")
add("                 writes_a - wa0, writes_b - wb0);")
add("        $display(\"    core: ap_start seen += %0d, ap_done seen += %0d\",")
add("                 core_start_seen - cs0, core_done_seen - cd0);")
if CORE_HAS_IDLE:
    add("        $display(\"    core: ap_idle=%0b (pri podnjatom ap_start)\", core_ap_idle);")
add("")
add("        // ── ЧТО ИМЕННО СЛОМАНО: РАЗЛИЧАЕМ ТРИ СЛУЧАЯ ───────────────────────")
add("        //")
add("        // Одних writes мало. Регион может стоять по разным причинам, и правка")
add("        // у них разная -- поэтому печатаем разбор, а не только вердикт.")
add("        if ((core_start_seen - cs0) == 0) begin")
add("            $display(\"    RAZBOR: core ap_start bolshe NE PODAETSJA.\");")
add("            $display(\"            Vneshnij region ne transliruet impuls povtorno --\");")
add("            $display(\"            eto vlozhennost: core est stadija vneshnego regiona.\");")
add("        end else if ((core_start_seen - cs0) > 10) begin")
add("            $display(\"    RAZBOR: core startuet mnogo raz, no shina molchit --\");")
add("            $display(\"            impuls dohodit, stadii vnutri ne rabotajut.\");")
add("            $display(\"            Smotret barjer ap_sync_done VNUTRI core i early return.\");")
add("        end else begin")
add("            $display(\"    RAZBOR: core startuet edinicy raz za 1M taktov --\");")
add("            $display(\"            impuls prohodit, no redko. Vneshnij region uspevaet\");")
add("            $display(\"            zavershitsja i perezapuskaetsja, a ne techet nepreryvno.\");")
add("        end")
add("")
add("        // ГЛАВНАЯ ПРОВЕРКА. Порог 10 -- заведомо ниже любого разумного числа")
add("        // проходов за миллион тактов (стадия с II=1..3 успела бы сотни тысяч),")
add("        // но заведомо выше единицы, которую даёт замороженный регион.")
add("        check(\"region rabotaet nepreryvno\", (writes_a - wa0) > 10,")
add("              $sformatf(\"writes_a += %0d za 1M taktov (nado > 10)\", writes_a - wa0));")
add("    end")
add("")

add("    $display(\"\");")
add("    $display(\"=== itogo: checks=%0d fails=%0d ===\", checks, fails);")
add("    if (checks == 0) begin")
add("        $display(\"*** NICHEGO NE PROVERENO -- test nedejstvitelen\");")
add("        $fatal(1);")
add("    end")
add("    // ── ЧТО СЧИТАТЬ УСПЕХОМ ЭТОГО ТЕСТА ────────────────────────────────────")
add("    //")
add("    // Тест ДИАГНОСТИЧЕСКИЙ, а не регрессионный: он проверяет гипотезу, а не")
add("    // требует от текущего RTL быть исправным. На неисправленном ядре он ОБЯЗАН")
add("    // показать дефект -- и это его нормальная работа, а не поломка.")
add("    //")
add("    // Поэтому \"ALL GREEN\" печатается в ОБОИХ исходах: важно, что тест")
add("    // отработал и дал определённый ответ. Какой именно -- в строке VERDICT.")
add("    // Иначе run_sim.sh назвал бы успешную диагностику падением, и разница")
add("    // между \"тест сломался\" и \"дефект подтверждён\" потерялась бы.")
add("    if (fails != 0) begin")
add("        $display(\"\");")
add("        $display(\"VERDICT: VLOZHENNYJ DATAFLOW PODTVERZHDEN.\");")
add("        $display(\"  Impuls ap_start ne ozhivljaet stadii vnutri %s.\",")
add("                 \"" + core_inst + "\");")
add("        $display(\"  Eto vosproizvodit platu: ap_ctrl=0x83, connAttempts=1, timeouts=0.\");")
add("        $display(\"  PRAVKA: ubrat VNUTRENNIJ #pragma HLS DATAFLOW iz %s.\",")
add("                 \"" + core_module.replace(KRNL + "_", "") + "\");")
add("        $display(\"  Posle pravki etot test dolzhen perestat elaborirovatsja\");")
add("        $display(\"  (instansa vlozhennogo regiona ne stanet) -- eto ozhidaemo.\");")
add("        $display(\"ALL GREEN\");")
add("        $finish;")
add("    end")
add("    $display(\"\");")
add("    $display(\"VERDICT: gipoteza o vlozhennosti MERTVA.\");")
add("    $display(\"  Impuls dohodit i region rabotaet nepreryvno. Prichina v drugom;\");")
add("    $display(\"  sledujuschij kandidat -- early return v rx_notify (sm. handoff).\");")
add("    $display(\"ALL GREEN\");")
add("    $finish;")
add("end")
add("")
add("// страховка от вечного прогона")
add("initial begin")
add("    repeat (3000000) @(posedge ap_clk);")
add("    $display(\"*** TIMEOUT\");")
add("    $fatal(1);")
add("end")
add("")
add("endmodule")
add("`default_nettype wire")

print("\n".join(L))
