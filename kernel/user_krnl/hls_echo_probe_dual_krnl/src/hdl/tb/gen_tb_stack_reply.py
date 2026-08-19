#!/usr/bin/env python3
# =============================================================================
# gen_tb_stack_reply.py -- генератор tb_stack_reply.sv
# =============================================================================
#
# ДЫРА, КОТОРУЮ ЭТОТ ТЕСТ ЗАКРЫВАЕТ.
#
# Пять существующих тестбенчей дают «76 проверок ALL GREEN», и НИ ОДИН из них не
# поднимает TVALID на входах от стека. Проверено grep'ом по всем .sv:
#
#     tb_probe_ctrl        ответов стека: 0
#     tb_probe_taps        ответов стека: 0
#     tb_net_frame_filter  ответов стека: 0
#     tb_core_ap_done      ответов стека: 0
#     tb_listen_start      ответов стека: 0
#
# То есть всё, что измерено за неделю, описывает поведение при МОЛЧАЩЕМ стеке.
# А на плате стек ОТВЕЧАЕТ: portState=2 получен из настоящего port_status, значит
# TOE подтвердил listen. Именно здесь симуляция и железо расходятся, и здесь
# единственное непроверенное место.
#
# ЧТО ИМЕННО ПОДОЗРЕВАЕТСЯ. В epd_client_connect ветка IDLE пишет в
# m_axis_tcp_open_connection БЕЗ проверки full() (.cpp:215; всего таких записей
# девять). Блокирующая запись в стадии с PIPELINE II=1 останавливает стадию, пока
# приёмник не возьмёт слово.
#
# ВАЖНО: само отсутствие full() -- НЕ дефект. У апстрима 46 таких записей, и он
# работает. Разница в форме: upstream пишет внутри `for` с PIPELINE (см.
# listen_port_handler), то есть блокировка задерживает ЦИКЛ, стадия остаётся
# живой. У нас write стоит в switch внутри стадии, вызываемой заново каждый
# проход, и блокировка приходится на границу прохода. Так ли это -- измеряет
# ЭТОТ тест, а не рассуждение.
#
# ЧТО ДЕЛАЕТ ТЕСТ. Инстанцирует epd_core и МОДЕЛИРУЕТ СТЕК четырьмя способами,
# от самого доброго к самому злому:
#
#   phase 1  стек молчит, TREADY=1        -- воспроизводит прежние тесты (базис)
#   phase 2  отвечает open_status УСПЕХ   -- путь, которого не было НИКОГДА
#   phase 3  отвечает open_status ОТКАЗ   -- ветка RETRY_WAIT, тоже не проверялась
#   phase 4  TREADY=0 на open_connection  -- блокирующая запись под нагрузкой
#   phase 5  port_status УСПЕХ серверу    -- воспроизводит portState=2 с платы
#
# ПРЕДСКАЗАНИЯ, записанные ДО прогона (иначе тест можно подогнать):
#   phase 2: получив успех, клиент уходит в DONE и БОЛЬШЕ НЕ ПИШЕТ open_connection.
#            Значит writes перестают расти, а sessionFifo получает ровно 1 слово.
#            Если writes продолжают расти -- succ читается неверно (не тот бит).
#   phase 3: получив отказ, клиент ждёт retryDelay и повторяет. writes растут с
#            темпом retryDelay, как в phase 1.
#   phase 4: если стадия ВСТАЁТ на блокирующей записи -- ap_done стадии перестаёт
#            тикать. Если она живёт -- ap_done тикает, а writes стоят. РАЗЛИЧИЕ
#            МЕЖДУ ЭТИМИ ДВУМЯ И ЕСТЬ ГЛАВНЫЙ РЕЗУЛЬТАТ ТЕСТА.
#   phase 5: portState должен стать 2 -- то же, что на плате. Если не станет,
#            расхождение с железом здесь, и дальше искать в HLS, а не в стеке.
#
# Тест ДИАГНОСТИЧЕСКИЙ: печатает ALL GREEN в любом исходе, а вывод -- в строках
# VERDICT/RAZBOR. Регрессией он станет после того, как дефект найден и исправлен.
#
# Запуск:
#     python3 gen_tb_stack_reply.py > tb_stack_reply.sv
#     ./run_sim_core.sh stack
#
# Сообщения на латинице: $display в xsim 2024.1 портит многобайтовые символы.

import re
import sys
from pathlib import Path

KRNL = "hls_echo_probe_dual_krnl"
CORE_SUFFIX = "_epd_core"

# Сторона, чей КЛИЕНТ открывает соединение. У probe это половина a
# (epd_client_connect), сервер -- b. Определяется по драйверу шины ниже, здесь
# только значения скаляров.
SCAL_IN = {
    "serverIp":      "32'h0a01d499",
    "serverPort":    "32'd7001",
    "listenPort":    "32'd7001",
    "msgBytes":      "32'd64",
    "triggerGo":     "32'd0",
    "enableConn":    "32'd1",
    "enableTraffic": "32'd1",
    "enableListen":  "32'd1",
    "listenPortA":   "32'd7001",
    "listenPortB":   "32'd7002",
    "enableA":       "32'd1",
    "enableB":       "32'd1",
}


def find_core_v(explicit=None):
    if explicit:
        p = Path(explicit)
        if p.is_file():
            return p
        cand = p / (KRNL + CORE_SUFFIX + ".v")
        if cand.is_file():
            return cand
        sys.exit("*** не найден %s в %s" % (KRNL + CORE_SUFFIX + ".v", p))
    here = Path(__file__).resolve().parent
    krnl_dir = here.parents[2]
    hits = sorted(krnl_dir.glob("src/hls/%s_ip_proj/*/syn/verilog/%s%s.v"
                                % (KRNL, KRNL, CORE_SUFFIX)))
    if not hits:
        sys.exit("*** не найден сгенерированный RTL. Сначала:\n"
                 "      make -f Makefile.vivado user_ip USER_KRNL=%s BOARD=u200" % KRNL)
    if len(hits) > 1:
        sys.exit("*** несколько решений HLS:\n  " + "\n  ".join(str(h) for h in hits))
    return hits[0]


def width(w):
    mm = re.match(r"\[(\d+)\s*:\s*(\d+)\]", w)
    return int(mm.group(1)) - int(mm.group(2)) + 1 if mm else 1


core_v = find_core_v(sys.argv[1] if len(sys.argv) > 1 else None)
src = core_v.read_text()

m = re.search(r"module\s+(\w*_core)\s*\((.*?)\);", src, re.S)
if not m:
    sys.exit("*** не разобрать список портов в %s" % core_v)
core_module, names = m.group(1), [p.strip() for p in m.group(2).split(",") if p.strip()]

decl = {}
for mm in re.finditer(r"^(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*;", src, re.M):
    d, w, n = mm.groups()
    decl[n] = (d, (w or "").strip())

missing = [n for n in names if n not in decl]
if missing:
    sys.exit("*** нет объявлений для портов: %s" % missing)

# Инстансы стадий -- нужны для иерархического чтения ap_done: без него нельзя
# отличить «стадия встала на блокирующей записи» от «стадия жива, шина закрыта».
stages = re.findall(r"^\w+ (\w+_U0)\(", src, re.M)
real_stages = [s for s in stages if not s.startswith("tie_off")]
if not real_stages:
    sys.exit("*** не найдено ни одной рабочей стадии (все tie_off?)")

# Кто на какой половине -- строго по ДРАЙВЕРУ шины, не по наличию порта.
# Неиспользуемые шины заглушены tie_off_*, и счётчик на заглушке однажды уже дал
# ложную победу (см. урок метода в docs/kernel_scheme_handoff.md).
def driver_of(bus):
    mm = re.search(r"assign\s+%s_TVALID\s*=\s*(\w+)" % re.escape(bus), src)
    return mm.group(1) if mm else None


def stage_driven(bus):
    d = driver_of(bus)
    return bool(d) and not d.startswith("tie_off")


CLIENT_SIDE = None
SERVER_SIDE = None
for side in ("a", "b"):
    if stage_driven("m_axis_tcp_open_connection_%s" % side):
        CLIENT_SIDE = side
    if stage_driven("m_axis_tcp_listen_port_%s" % side):
        SERVER_SIDE = side
if CLIENT_SIDE is None:
    sys.exit("*** ни одна половина не ведёт open_connection стадией -- нечего проверять")
if SERVER_SIDE is None:
    sys.exit("*** ни одна половина не ведёт listen_port стадией")

OPEN_BUS = "m_axis_tcp_open_connection_%s" % CLIENT_SIDE
OPEN_ST_BUS = "s_axis_tcp_open_status_%s" % CLIENT_SIDE
LISTEN_BUS = "m_axis_tcp_listen_port_%s" % SERVER_SIDE
PORT_ST_BUS = "s_axis_tcp_port_status_%s" % SERVER_SIDE

for b in (OPEN_ST_BUS, PORT_ST_BUS):
    if (b + "_TVALID") not in decl:
        sys.exit("*** нет входа %s_TVALID -- тест не применим к этому RTL" % b)

# Стадия клиента: её ap_done отвечает на главный вопрос phase 4.
CLIENT_STAGE = driver_of(OPEN_BUS)
SERVER_STAGE = driver_of(LISTEN_BUS)
# assign даёт имя вида epd_client_connect_U0_m_axis_..._TVALID -- нужен инстанс.
def inst_of(sig):
    for st in real_stages:
        if sig and sig.startswith(st):
            return st
    return None


CLIENT_INST = inst_of(CLIENT_STAGE)
SERVER_INST = inst_of(SERVER_STAGE)

# Без имени инстанса тестбенч сослался бы на dut.None.ap_done и упал на
# элаборации с невнятной ошибкой. Падаем здесь и говорим, что именно не сошлось:
# иерархическое чтение ap_done -- основа phase 4, без него тест бессмыслен.
if CLIENT_INST is None or SERVER_INST is None:
    sys.exit("*** не сопоставить драйвер шины с инстансом стадии:\n"
             "      open_connection ведёт '%s' -> инстанс %s\n"
             "      listen_port     ведёт '%s' -> инстанс %s\n"
             "    Известные рабочие стадии: %s"
             % (CLIENT_STAGE, CLIENT_INST, SERVER_STAGE, SERVER_INST,
                ", ".join(real_stages)))

# Таймаут повтора из .cpp -- ожидаемый темп записей зависит от него линейно.
# Дублировать значение в тестбенче нельзя: разойдясь, дало бы ложный вывод.
def find_retry_delay():
    cpp = Path(__file__).resolve().parents[2] / "hls" / (KRNL + ".cpp")
    if not cpp.is_file():
        return 0
    txt = cpp.read_text()
    for pat in (r"retryDelay\s*=\s*(\d+)",
                r"#define\s+LISTEN_TIMEOUT\s+(\d+)",
                r"LISTEN_TIMEOUT\s*=\s*(\d+)"):
        mm = re.search(pat, txt)
        if mm:
            return int(mm.group(1))
    return 0


RETRY_DELAY = find_retry_delay()

# Ширина данных потоков статуса -- берём из RTL, а не предполагаем.
OPEN_ST_W = width(decl.get(OPEN_ST_BUS + "_TDATA", ("input", ""))[1])
PORT_ST_W = width(decl.get(PORT_ST_BUS + "_TDATA", ("input", ""))[1])

L = []
add = L.append

add("// =============================================================================")
add("// tb_stack_reply -- СГЕНЕРИРОВАН gen_tb_stack_reply.py, НЕ ПРАВИТЬ РУКАМИ")
add("// =============================================================================")
add("//")
add("// Источник: %s (портов %d, стадий %d, из них рабочих %d)"
    % (core_v.name, len(names), len(stages), len(real_stages)))
add("// Клиент  : половина %s, стадия %s" % (CLIENT_SIDE, CLIENT_INST))
add("// Сервер  : половина %s, стадия %s" % (SERVER_SIDE, SERVER_INST))
add("// RETRY_DELAY из .cpp: %d проходов" % RETRY_DELAY)
add("//")
add("// ЗАКРЫВАЕТ ДЫРУ: ни один из пяти прежних тестбенчей не поднимал TVALID на")
add("// входах от стека. Всё измеренное за неделю -- поведение при МОЛЧАЩЕМ стеке,")
add("// а на плате стек отвечает (portState=2 из настоящего port_status).")
add("")
add("`timescale 1ns / 1ps")
add("`default_nettype none")
add("")
add("module tb_stack_reply;")
add("")
add("localparam int unsigned RETRY_DELAY = %d;" % RETRY_DELAY)
add("")
add("logic ap_clk = 1'b0;")
add("always #2.5 ap_clk = ~ap_clk;")
add("logic ap_rst = 1'b1;          // core ждёт АКТИВНЫЙ-ВЫСОКИЙ сброс")
add("logic ap_start = 1'b1;")
add("")
add("int unsigned open_writes = 0, listen_writes = 0;")
add("int unsigned client_done = 0, server_done = 0;")
add("int unsigned fails = 0, checks = 0;")
add("")

# ── сигналы ─────────────────────────────────────────────────────────────────
add("// ── сигналы портов DUT ──────────────────────────────────────────────────────")
for n in names:
    d, w = decl[n]
    if n in ("ap_clk", "ap_rst", "ap_start"):
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
        else:
            init = " = %d'd0" % width(w)
    add("%s %s%s%s;" % (kind, ws, n, init))
add("")

add("// ── DUT ─────────────────────────────────────────────────────────────────────")
add("%s dut (" % core_module)
conn = []
for n in names:
    if n == "ap_clk":
        conn.append("    .ap_clk(ap_clk)")
    elif n == "ap_rst":
        conn.append("    .ap_rst(ap_rst)")
    elif n == "ap_start":
        conn.append("    .ap_start(ap_start)")
    else:
        conn.append("    .%s(%s)" % (n, n))
add(",\n".join(conn))
add(");")
add("")

add("// ── ИЕРАРХИЧЕСКИ: ap_done стадий ───────────────────────────────────────────")
add("//")
add("// Это ключ к phase 4. Если стадия ВСТАЁТ на блокирующей записи, её ap_done")
add("// перестаёт тикать. Если живёт -- ap_done тикает, а шина стоит. Без этого")
add("// различить два случая невозможно, а правка у них разная.")
add("wire client_ap_done = dut.%s.ap_done;" % CLIENT_INST)
add("wire server_ap_done = dut.%s.ap_done;" % SERVER_INST)
add("")

add("always @(posedge ap_clk) begin")
add("    if (!ap_rst) begin")
add("        if (%s_TVALID && %s_TREADY) open_writes   <= open_writes + 1;" % (OPEN_BUS, OPEN_BUS))
add("        if (%s_TVALID && %s_TREADY) listen_writes <= listen_writes + 1;" % (LISTEN_BUS, LISTEN_BUS))
add("        if (client_ap_done) client_done <= client_done + 1;")
add("        if (server_ap_done) server_done <= server_done + 1;")
add("    end")
add("end")
add("")

add("task automatic check(input string what, input bit ok, input string detail);")
add("    checks++;")
add("    if (ok) $display(\"  ok   : %s (%s)\", what, detail);")
add("    else begin fails++; $display(\"  FAIL : %s (%s)\", what, detail); end")
add("endtask")
add("")

# ── подача одного слова ответа стека ────────────────────────────────────────
add("// ── ОТВЕТ СТЕКА: одно слово на нужную шину ─────────────────────────────────")
add("//")
add("// Рукопожатие честное: держим TVALID, пока DUT не поднимет TREADY, и только")
add("// потом снимаем. Подача на один такт без ожидания TREADY потерялась бы, и")
add("// тест показал бы «стадия не реагирует» там, где она просто не успела.")
add("task automatic reply_open_status(input bit success, input int unsigned sid);")
add("    // pkt128: биты 15:0 = sessionID, бит 16 = success (см. .cpp:225-228).")
add("    %s_TDATA  = '0;" % OPEN_ST_BUS)
add("    %s_TDATA[15:0] = sid[15:0];" % OPEN_ST_BUS)
add("    %s_TDATA[16]   = success;" % OPEN_ST_BUS)
if (OPEN_ST_BUS + "_TKEEP") in decl:
    add("    %s_TKEEP  = '1;" % OPEN_ST_BUS)
if (OPEN_ST_BUS + "_TLAST") in decl:
    add("    %s_TLAST  = 1'b1;" % OPEN_ST_BUS)
add("    %s_TVALID = 1'b1;" % OPEN_ST_BUS)
add("    // ждём приёма, но не вечно: таймаут отличает «не взяли» от подвисшего теста")
add("    begin : wait_open_ack")
add("        int unsigned guard = 0;")
add("        while (!%s_TREADY && guard < 100000) begin" % OPEN_ST_BUS)
add("            @(posedge ap_clk); guard++;")
add("        end")
add("        if (guard >= 100000)")
add("            $display(\"    (!) open_status NE PRINJAT za 100k taktov -- TREADY=0\");")
add("    end")
add("    @(posedge ap_clk);")
add("    %s_TVALID = 1'b0;" % OPEN_ST_BUS)
add("endtask")
add("")
add("task automatic reply_port_status(input bit success);")
add("    // pkt8: бит 0 = success (см. .cpp:590-591).")
add("    %s_TDATA  = '0;" % PORT_ST_BUS)
add("    %s_TDATA[0] = success;" % PORT_ST_BUS)
if (PORT_ST_BUS + "_TKEEP") in decl:
    add("    %s_TKEEP  = '1;" % PORT_ST_BUS)
if (PORT_ST_BUS + "_TLAST") in decl:
    add("    %s_TLAST  = 1'b1;" % PORT_ST_BUS)
add("    %s_TVALID = 1'b1;" % PORT_ST_BUS)
add("    begin : wait_port_ack")
add("        int unsigned guard = 0;")
add("        while (!%s_TREADY && guard < 100000) begin" % PORT_ST_BUS)
add("            @(posedge ap_clk); guard++;")
add("        end")
add("        if (guard >= 100000)")
add("            $display(\"    (!) port_status NE PRINJAT za 100k taktov -- TREADY=0\");")
add("    end")
add("    @(posedge ap_clk);")
add("    %s_TVALID = 1'b0;" % PORT_ST_BUS)
add("endtask")
add("")

have_state = "portState" in decl and decl["portState"][0] == "output"
have_conn = "connAttempts" in decl and decl["connAttempts"][0] == "output"

add("initial begin")
add("    int unsigned w0, d0, w1, d1;")
add("")
add("    $display(\"\");")
add("    $display(\"=== tb_stack_reply: stek OTVECHAET (chego ne delal ni odin test) ===\");")
add("    $display(\"  client: half %s, stage %s\", \"" + CLIENT_SIDE + "\", \"" + CLIENT_INST + "\");")
add("    $display(\"  server: half %s, stage %s\", \"" + SERVER_SIDE + "\", \"" + SERVER_INST + "\");")
add("    $display(\"  RETRY_DELAY=%0d prohodov\", RETRY_DELAY);")
add("    $display(\"\");")
add("")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (10) @(posedge ap_clk);")
add("")

# ── phase 1: базис ──────────────────────────────────────────────────────────
add("    // ── phase 1: СТЕК МОЛЧИТ. Базис -- воспроизводит прежние тесты. ────────")
add("    $display(\"-- phase 1: stek molchit (bazis) --\");")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    check(\"stadija klienta zhiva pri molchaschem steke\", (client_done - d0) > 1000,")
add("          $sformatf(\"ap_done += %0d\", client_done - d0));")
add("    check(\"povtory po tajmautu idut\", (open_writes - w0) >= 1,")
add("          $sformatf(\"open_writes += %0d\", open_writes - w0));")
add("")

# ── phase 2: успех ──────────────────────────────────────────────────────────
add("    // ── phase 2: ОТВЕТ УСПЕХ. Путь, которого не было НИКОГДА. ──────────────")
add("    //")
add("    // ПРЕДСКАЗАНИЕ: клиент уходит в DONE и больше НЕ пишет open_connection.")
add("    // Если writes продолжат расти -- succ читается не из того бита.")
add("    $display(\"\");")
add("    $display(\"-- phase 2: open_status = USPEH (sid=7) --\");")
add("    reply_open_status(1'b1, 7);")
add("    repeat (200) @(posedge ap_clk);")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    posle uspeha: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
if have_state:
    add("    $display(\"    portState=%0d\", portState);")
add("    check(\"posle uspeha klient NE otkryvaet zanovo\", (open_writes - w0) == 0,")
add("          $sformatf(\"open_writes += %0d (nado 0)\", open_writes - w0));")
add("    check(\"stadija ostalas zhiva\", (client_done - d0) > 1000,")
add("          $sformatf(\"ap_done += %0d\", client_done - d0));")
add("")

# ── phase 3: отказ ──────────────────────────────────────────────────────────
add("    // ── phase 3: ОТВЕТ ОТКАЗ -- ветka RETRY_WAIT, ne proverjalas nikogda. ──")
add("    //")
add("    // Сброс нужен: после phase 2 клиент в DONE и на отказ не отреагирует.")
add("    $display(\"\");")
add("    $display(\"-- phase 3: open_status = OTKAZ (posle sbrosa) --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    reply_open_status(1'b0, 0);")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    posle otkaza: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    check(\"posle otkaza klient POVTORJAET\", (open_writes - w0) >= 1,")
add("          $sformatf(\"open_writes += %0d (nado >= 1)\", open_writes - w0));")
add("")

# ── phase 4: ГЛАВНАЯ -- блокирующая запись ──────────────────────────────────
add("    // ── phase 4: TREADY=0 -- БЛОКИРУЮЩАЯ ЗАПИСЬ. ГЛАВНАЯ ФАЗА. ─────────────")
add("    //")
add("    // В .cpp запись в open_connection идёт БЕЗ проверки full() (девять таких")
add("    // мест). Здесь измеряется, что делает стадия, когда приёмник не берёт:")
add("    //")
add("    //   ap_done ПЕРЕСТАЛ тикать -> стадия ВСТАЛА, нужен full() или иная форма")
add("    //   ap_done тикает, шина стоит -> стадия жива, блокировки нет")
add("    //")
add("    // На плате network_krnl может не принимать (его входной FIFO полон или")
add("    // стек занят), и тогда поведение здесь -- это поведение там.")
add("    $display(\"\");")
add("    $display(\"-- phase 4: TREADY=0 na open_connection (GLAVNAJA) --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    %s_TREADY = 1'b0;" % OPEN_BUS)
add("    w0 = open_writes; d0 = client_done; w1 = listen_writes; d1 = server_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    pri TREADY=0: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    $display(\"    sosed (server): listen_writes += %0d, server ap_done += %0d\",")
add("             listen_writes - w1, server_done - d1);")
add("")
add("    if ((client_done - d0) < 100) begin")
add("        $display(\"    RAZBOR: stadija klienta VSTALA na blokirujuschej zapisi.\");")
add("        $display(\"            ap_done += %0d za 1M taktov -- prakticheski ne tikaet.\",")
add("                 client_done - d0);")
add("        $display(\"            Eto ob'jasnjaet connAttempts=1 na plate: network_krnl\");")
add("        $display(\"            ne vzjal slovo, i stadija zamerla naveki.\");")
add("        if ((server_done - d1) < 100)")
add("            $display(\"            I SOSEDNJAJA POLOVINA TOZHE VSTALA -- barjer ap_sync_done\");")
add("        else")
add("            $display(\"            Sosednjaja polovina zhiva -- barjer ne pri chem\");")
add("    end else begin")
add("        $display(\"    RAZBOR: stadija ZHIVA pri zakrytom TREADY (ap_done += %0d).\",")
add("                 client_done - d0);")
add("        $display(\"            Blokirujuschaja zapis NE vinovata -- iskat dalshe.\");")
add("    end")
add("    check(\"stadija zhiva pri TREADY=0\", (client_done - d0) >= 100,")
add("          $sformatf(\"client ap_done += %0d\", client_done - d0));")
add("    %s_TREADY = 1'b1;" % OPEN_BUS)
add("")

# ── phase 5: port_status серверу ────────────────────────────────────────────
add("    // ── phase 5: port_status УСПЕХ -- воспроизводим portState=2 s platy. ───")
add("    $display(\"\");")
add("    $display(\"-- phase 5: port_status = USPEH serveru --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    // Ждём, пока сервер попросит порт: отвечать раньше запроса бессмысленно.")
add("    begin : wait_listen_req")
add("        int unsigned guard = 0;")
add("        w1 = listen_writes;")
add("        while (listen_writes == w1 && guard < 2000000) begin")
add("            @(posedge ap_clk); guard++;")
add("        end")
add("        if (listen_writes == w1)")
add("            $display(\"    (!) server ne poprosil port za 2M taktov\");")
add("        else")
add("            $display(\"    server poprosil port cherez %0d taktov\", guard);")
add("    end")
add("    reply_port_status(1'b1);")
add("    repeat (1000) @(posedge ap_clk);")
if have_state:
    add("    $display(\"    portState=%0d (na plate bylo 2)\", portState);")
    add("    check(\"portState stal 2 (kak na plate)\", portState == 2,")
    add("          $sformatf(\"portState=%0d\", portState));")
else:
    add("    $display(\"    (portState ne vyveden naruzhu -- proverka propuschena)\");")
add("")

add("    $display(\"\");")
add("    $display(\"=== itogo: checks=%0d fails=%0d ===\", checks, fails);")
add("    if (checks == 0) begin")
add("        $display(\"*** NICHEGO NE PROVERENO -- test nedejstvitelen\");")
add("        $fatal(1);")
add("    end")
add("    $display(\"\");")
add("    if (fails != 0)")
add("        $display(\"VERDICT: est rashozhdenija -- sm. RAZBOR i FAIL vyshe.\");")
add("    else")
add("        $display(\"VERDICT: stek-otvety obrabotany verno vo vseh 5 fazah.\");")
add("    $display(\"ALL GREEN\");")
add("    $finish;")
add("end")
add("")
add("initial begin")
add("    repeat (12000000) @(posedge ap_clk);")
add("    $display(\"*** TIMEOUT\");")
add("    $fatal(1);")
add("end")
add("")
add("endmodule")
add("`default_nettype wire")

print("\n".join(L))
