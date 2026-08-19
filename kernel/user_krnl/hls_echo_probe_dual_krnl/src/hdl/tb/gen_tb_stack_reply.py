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
#   phase 4b ответ ПОСЛЕ таймаута        -- как реальный TOE (микросекунды)
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
#   phase 4b: клиент должен ПОДХВАТИТЬ ответ, пришедший позже таймаута. Если
#            writes продолжают расти -- слово потеряно, потому что шина читается
#            только в WAIT_STATUS. Сравнение с iperf_client (РАБОТАЕТ на этом
#            железе) показало: у него openStatus_handler -- ОТДЕЛЬНАЯ стадия,
#            опустошающая шину каждый проход в свой FIFO, независимо от FSM.
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


# ── ВХОДЫ БЛОЧНОГО ПРОТОКОЛА: ЗАДАЮТСЯ ЯВНО, А НЕ ПО ОСТАТОЧНОМУ ПРИНЦИПУ ───
# Значения -- те, что подаёт настоящий верхний модуль. ap_continue=1 критичен:
# ноль на нём запирает регион (см. пояснение в генерации сигналов ниже).
BLOCK_PROTO_IN = {
    "ap_continue": "1'b1",
    "ap_ce":       "1'b1",
}

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

# Любой вход вида ap_* обязан быть либо в таблице, либо известным (clk/rst/start).
# Иначе он получит 0 по остаточному принципу -- ровно та ошибка, что дала
# ложный FAIL в первой версии этого теста.
KNOWN_AP_IN = {"ap_clk", "ap_rst", "ap_rst_n", "ap_start"} | set(BLOCK_PROTO_IN)
unknown_ap = [n for n in names
              if n.startswith("ap_") and decl[n][0] == "input"
              and n not in KNOWN_AP_IN]
if unknown_ap:
    sys.exit("*** входы блочного протокола не описаны: %s\n"
             "    Добавьте их в BLOCK_PROTO_IN с ПРАВИЛЬНЫМ значением: по остаточному\n"
             "    принципу они получат 0, а нуль на ap_continue запирает регион."
             % ", ".join(unknown_ap))

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
        elif n in BLOCK_PROTO_IN:
            # ── ПОЧЕМУ ЭТО ОТДЕЛЬНОЙ ВЕТКОЙ ────────────────────────────────
            # ap_continue попал бы в общий else и получил 0 -- а нуль на нём
            # ДЕРЖИТ ap_done_reg каждой стадии поднятым, то есть намертво
            # запирает регион. Первая версия теста так и сделала: ap_done
            # «тикал» 1000000 раз за 1M тактов (то есть стоял в единице), шина
            # молчала во ВСЕХ фазах, включая базис, и тест обвинил ядро в том,
            # чего оно не делает -- при том что tb_top_start на том же RTL
            # давал writes += 2.
            # В настоящем дизайне верхний модуль подаёт 1'b1 (проверено:
            # hls_echo_probe_dual_krnl.v:823 assign ..._ap_continue = 1'b1).
            init = " = %s" % BLOCK_PROTO_IN[n]
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
add("            $display(\"    (!) open_status NOT ACCEPTED within 100k cycles -- TREADY=0\");")
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
add("            $display(\"    (!) port_status NOT ACCEPTED within 100k cycles -- TREADY=0\");")
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
add("    $display(\"=== tb_stack_reply: the STACK REPLIES (no earlier test did this) ===\");")
add("    $display(\"  client: half %s, stage %s\", \"" + CLIENT_SIDE + "\", \"" + CLIENT_INST + "\");")
add("    $display(\"  server: half %s, stage %s\", \"" + SERVER_SIDE + "\", \"" + SERVER_INST + "\");")
add("    $display(\"  RETRY_DELAY=%0d stage passes\", RETRY_DELAY);")
add("    $display(\"\");")
add("")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (10) @(posedge ap_clk);")
add("")

# ── phase 1: базис ──────────────────────────────────────────────────────────
add("    // ── phase 1: СТЕК МОЛЧИТ. Базис -- воспроизводит прежние тесты. ────────")
add("    $display(\"-- phase 1: stack silent (baseline) --\");")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    check(\"client stage alive with silent stack\", (client_done - d0) > 1000,")
add("          $sformatf(\"ap_done += %0d\", client_done - d0));")
add("    check(\"timeout retries happen\", (open_writes - w0) >= 1,")
add("          $sformatf(\"open_writes += %0d\", open_writes - w0));")
add("")

# ── phase 2: успех ──────────────────────────────────────────────────────────
add("    // ── phase 2: ОТВЕТ УСПЕХ. Путь, которого не было НИКОГДА. ──────────────")
add("    //")
add("    // ПРЕДСКАЗАНИЕ: клиент уходит в DONE и больше НЕ пишет open_connection.")
add("    // Если writes продолжат расти -- succ читается не из того бита.")
add("    $display(\"\");")
add("    $display(\"-- phase 2: open_status = SUCCESS (sid=7) --\");")
add("    reply_open_status(1'b1, 7);")
add("    repeat (200) @(posedge ap_clk);")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    after success: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
if have_state:
    add("    $display(\"    portState=%0d\", portState);")
add("    check(\"after success client does NOT reopen\", (open_writes - w0) == 0,")
add("          $sformatf(\"open_writes += %0d (need 0)\", open_writes - w0));")
add("    check(\"stage still alive\", (client_done - d0) > 1000,")
add("          $sformatf(\"ap_done += %0d\", client_done - d0));")
add("")

# ── phase 3: отказ ──────────────────────────────────────────────────────────
add("    // ── phase 3: ОТВЕТ ОТКАЗ -- ветka RETRY_WAIT, ne proverjalas nikogda. ──")
add("    //")
add("    // Сброс нужен: после phase 2 клиент в DONE и на отказ не отреагирует.")
add("    $display(\"\");")
add("    $display(\"-- phase 3: open_status = REFUSED (after reset) --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    reply_open_status(1'b0, 0);")
add("    w0 = open_writes; d0 = client_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    after refusal: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    check(\"after refusal client RETRIES\", (open_writes - w0) >= 1,")
add("          $sformatf(\"open_writes += %0d (need >= 1)\", open_writes - w0));")
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
add("    $display(\"-- phase 4: TREADY=0 on open_connection (KEY PHASE) --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    %s_TREADY = 1'b0;" % OPEN_BUS)
add("    w0 = open_writes; d0 = client_done; w1 = listen_writes; d1 = server_done;")
add("    repeat (1000000) @(posedge ap_clk);")
add("    $display(\"    with TREADY=0: open_writes += %0d, client ap_done += %0d\",")
add("             open_writes - w0, client_done - d0);")
add("    $display(\"    neighbour (server): listen_writes += %0d, server ap_done += %0d\",")
add("             listen_writes - w1, server_done - d1);")
add("")
add("    if ((client_done - d0) < 100) begin")
add("        $display(\"    ANALYSIS: client stage STALLED on the blocking write.\");")
add("        $display(\"            ap_done += %0d over 1M cycles -- essentially frozen.\",")
add("                 client_done - d0);")
add("        $display(\"            This explains connAttempts=1 on the board: network_krnl\");")
add("        $display(\"            never took the word and the stage froze forever.\");")
add("        if ((server_done - d1) < 100)")
add("            $display(\"            THE OTHER HALF STALLED TOO -- ap_sync_done barrier\");")
add("        else")
add("            $display(\"            The other half is alive -- the barrier is not involved\");")
add("    end else begin")
add("        $display(\"    ANALYSIS: stage ALIVE with TREADY closed (ap_done += %0d).\",")
add("                 client_done - d0);")
add("        $display(\"            The blocking write is NOT the cause -- look further.\");")
add("    end")
add("    check(\"stage alive with TREADY=0\", (client_done - d0) >= 100,")
add("          $sformatf(\"client ap_done += %0d\", client_done - d0));")
add("    %s_TREADY = 1'b1;" % OPEN_BUS)
add("")

# ── phase 5: port_status серверу ────────────────────────────────────────────
add("    // ── phase 4b: ОТВЕТ С ЗАДЕРЖКОЙ -- ГЛАВНОЕ ОТЛИЧИЕ ОТ ПЛАТЫ ─────────────")
add("    //")
add("    // ВСЕ прежние фазы отвечали МГНОВЕННО, и это скрывало целый класс")
add("    // дефектов. На плате TOE отвечает через микросекунды, за которые автомат")
add("    // успевает уйти из WAIT_STATUS -- в RETRY_WAIT по таймауту или в DONE.")
add("    //")
add("    // ПОЧЕМУ ЭТО ПОДОЗРИТЕЛЬНО ИМЕННО ЗДЕСЬ. Сравнение с iperf_client, который")
add("    // РАБОТАЕТ на этом железе, показало структурное различие:")
add("    //")
add("    //   iperf: openStatus_handler -- ОТДЕЛЬНАЯ стадия, опустошает шину КАЖДЫЙ")
add("    //          проход в свой FIFO; FSM читает из FIFO, шину не трогает")
add("    //   probe: epd_client_connect читает шину САМ и ТОЛЬКО в WAIT_STATUS")
add("    //")
add("    // Если слово придёт, когда автомат не в WAIT_STATUS, у iperf оно всё равно")
add("    // будет прочитано, а у нас останется в шине.")
add("    //")
add("    // ПРЕДСКАЗАНИЕ: клиент должен ПОДХВАТИТЬ ответ, пришедший позже таймаута --")
add("    // либо в этом проходе, либо на следующей попытке. Если writes встанут")
add("    // навсегда, а слово останется непрочитанным -- дефект найден.")
add("    $display(\"\");")
add("    $display(\"-- phase 4b: reply AFTER the timeout (like the real TOE) --\");")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
add("    repeat (100) @(posedge ap_clk);")
add("    begin : delayed_reply")
add("        int unsigned w_before, d_before, w_after;")
add("        // Ждём, пока автомат ГАРАНТИРОВАННО уйдёт из WAIT_STATUS: таймаут")
add("        // RETRY_DELAY проходов, проход ~2.33 такта -> с запасом x1.5.")
add("        int unsigned settle = (RETRY_DELAY > 0) ? RETRY_DELAY * 4 : 400000;")
add("        repeat (settle) @(posedge ap_clk);")
add("        w_before = open_writes; d_before = client_done;")
add("        $display(\"    after %0d cycles of waiting: open_writes=%0d\",")
add("                 settle, open_writes);")
add("")
add("        // ТЕПЕРЬ отвечаем -- заведомо не в тот момент, когда автомат ждал.")
add("        reply_open_status(1'b1, 9);")
add("        repeat (200000) @(posedge ap_clk);")
add("        w_after = open_writes;")
add("        $display(\"    after the late reply: open_writes += %0d, ap_done += %0d\",")
add("                 w_after - w_before, client_done - d_before);")
add("")
add("        // Слово принято? TREADY поднимался -- это видно по тому, что")
add("        // reply_open_status не напечатал предупреждение о непринятом слове.")
add("        check(\"stage alive after the late reply\",")
add("              (client_done - d_before) > 1000,")
add("              $sformatf(\"ap_done += %0d\", client_done - d_before));")
add("")
add("        // ГЛАВНОЕ: если ответ ПОДХВАЧЕН, клиент уходит в DONE и перестаёт")
add("        // писать. Если ответ ПОТЕРЯН, он продолжает повторять по таймауту.")
add("        // Оба исхода допустимы логически -- важно РАЗЛИЧИТЬ их и напечатать.")
add("        if ((w_after - w_before) == 0) begin")
add("            $display(\"    ANALYSIS: writes stopped -> late reply WAS PICKED UP\");")
add("            $display(\"            The late reply is handled correctly; the defect is elsewhere.\");")
add("        end else begin")
add("            $display(\"    ANALYSIS: writes CONTINUE (+%0d) -> late reply WAS LOST.\",")
add("                     w_after - w_before);")
add("            $display(\"            The word arrived outside WAIT_STATUS and nobody took it.\");")
add("            $display(\"            Fix: a separate handler stage, the way iperf does it --\");")
add("            $display(\"            it drains the bus into its own FIFO every pass.\");")
add("        end")
add("    end")
add("")
add("    // ── phase 5: port_status УСПЕХ -- воспроизводим portState=2 s platy. ───")
add("    //")
add("    // СНИМОК СЧЁТЧИКА -- ДО СНЯТИЯ СБРОСА, А НЕ ПОСЛЕ.")
add("    //")
add("    // Первая версия брала w1 через repeat(100) после ap_rst=0 и печатала")
add("    // «server ne poprosil port za 2M taktov», хотя portState тут же был 2.")
add("    // Противоречие объясняется просто: после сброса portRequested=0, и запрос")
add("    // уходит в ПЕРВЫЕ ЖЕ такты -- внутри тех ста тактов, то есть до снимка. Проверка")
add("    // portState==2 проходила по причине, НЕ ЗАВИСЯЩЕЙ от reply_port_status:")
add("    // зелёная случайно. Теперь окно наблюдения открыто с самого сброса.")
add("    //")
add("    // И portState проверяется ДВАЖДЫ -- до ответа и после. Без замера «до»")
add("    // нельзя утверждать, что двойку сделал именно ответ стека.")
add("    $display(\"\");")
add("    $display(\"-- phase 5: port_status = SUCCESS to the server --\");")
add("    w1 = listen_writes;              // снимок ДО сброса")
add("    ap_rst = 1'b1;")
add("    repeat (20) @(posedge ap_clk);")
add("    ap_rst = 1'b0;")
if have_state:
    add("    repeat (50) @(posedge ap_clk);")
    add("    $display(\"    portState right after reset = %0d (expected 0 or 1)\", portState);")
    add("    check(\"port NOT open before the stack replies\", portState != 2,")
    add("          $sformatf(\"portState=%0d before reply_port_status\", portState));")
add("    // Ждём запрос порта. Окно открыто с сброса, поэтому запрос не потеряется.")
add("    begin : wait_listen_req")
add("        int unsigned guard = 0;")
add("        while (listen_writes == w1 && guard < 2000000) begin")
add("            @(posedge ap_clk); guard++;")
add("        end")
add("        if (listen_writes == w1)")
add("            $display(\"    (!) server did not request a port within 2M cycles\");")
add("        else")
add("            $display(\"    server requested a port (listen_writes %0d -> %0d)\",")
add("                     w1, listen_writes);")
add("        check(\"server requested the listen port\", listen_writes != w1,")
add("              $sformatf(\"listen_writes %0d -> %0d\", w1, listen_writes));")
add("    end")
add("    reply_port_status(1'b1);")
add("    repeat (1000) @(posedge ap_clk);")
if have_state:
    add("    $display(\"    portState=%0d (board showed 2)\", portState);")
    add("    check(\"portState became 2 (as on the board)\", portState == 2,")
    add("          $sformatf(\"portState=%0d\", portState));")
else:
    add("    $display(\"    (portState ne vyveden naruzhu -- proverka propuschena)\");")
add("")

add("    $display(\"\");")
add("    $display(\"=== total: checks=%0d fails=%0d ===\", checks, fails);")
add("    if (checks == 0) begin")
add("        $display(\"*** NOTHING WAS CHECKED -- this run is invalid\");")
add("        $fatal(1);")
add("    end")
add("    $display(\"\");")
add("    if (fails != 0)")
add("        $display(\"VERDICT: discrepancies found -- see ANALYSIS and FAIL above.\");")
add("    else")
add("        $display(\"VERDICT: stack replies handled correctly in all phases.\");")
add("    $display(\"ALL GREEN\");")
add("    $finish;")
add("end")
add("")
add("initial begin")
add("    repeat (16000000) @(posedge ap_clk);")   # +фаза 4b: 400k+200k
add("    $display(\"*** TIMEOUT\");")
add("    $fatal(1);")
add("end")
add("")
add("endmodule")
add("`default_nettype wire")

print("\n".join(L))
