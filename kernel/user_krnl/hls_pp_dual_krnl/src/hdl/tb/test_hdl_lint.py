#!/usr/bin/env python3
# =============================================================================
# test_hdl_lint.py -- дешёвые проверки HDL, которые ловят молчаливые дефекты
# =============================================================================
#
# ЗАЧЕМ. Три прогона pack падали с одним и тем же бесполезным сообщением:
#
#     CRITICAL WARNING [filemgmt 20-742] top can not be validated
#     -> Vivado взял: lat_fifo
#
# Настоящая причина оказалась в одной строке:
#
#     our_rdata <= 32'hBADA_DDR5;
#
# Это НЕ ЧИСЛО: R не шестнадцатеричная цифра. Vivado обрывал разбор обёртки,
# выбирал другой модуль как top и молча упаковывал его. Ни синтез HLS, ни
# четыре модели поведения такое поймать не могли -- они проверяют логику, а не
# лексику.
#
# Проверки здесь -- те, что можно сделать без симулятора и которые ловят
# ИМЕННО молчаливые отказы: невалидную константу, использование до объявления,
# параметр в размерности, дубликат объявления.
#
# ЗАПУСК:  python3 test_hdl_lint.py

import glob
import os
import re
import sys

HDL = sorted(glob.glob(os.path.join(os.path.dirname(__file__), "..", "*.v")) +
             glob.glob(os.path.join(os.path.dirname(__file__), "..", "*.sv")))

fails = 0


def check(cond, what):
    global fails
    print(("  [ OK ] " if cond else "  [FAIL] ") + what)
    if not cond:
        fails += 1


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


# ---------------------------------------------------------------------------
print("[1] hex/bin-константы валидны")
#
# Ровно тот дефект, что стоил трёх прогонов pack. Ошибка молчаливая: Vivado
# не пишет "невалидное число", он пишет "syntax error near 'R5'" -- и то
# только если попросить check_syntax.
VALID = {"h": set("0123456789abcdefABCDEF_xzXZ?"),
         "b": set("01_xzXZ?"),
         "d": set("0123456789_"),
         "o": set("01234567_xzXZ?")}
bad = []
for f in HDL:
    for n, line in enumerate(open(f), 1):
        code = strip_comments(line)
        for m in re.finditer(r"(\d+)'([hbdo])([0-9a-zA-Z_?]*)", code):
            _, base, digits = m.groups()
            wrong = [c for c in digits if c not in VALID[base]]
            if wrong or not digits:
                bad.append(f"{os.path.basename(f)}:{n} {m.group(0)} ({wrong or 'пусто'})")
check(not bad, "невалидных констант нет" + ("" if not bad else ": " + "; ".join(bad)))

# ---------------------------------------------------------------------------
print("\n[2] у модулей нет ВЕКТОРНЫХ параметров")
#
# ЗАПРЕТ ИМЕННО НА ВЕКТОРНЫЕ, а не на все, и это выяснилось дорого.
#
# parameter [47:0] PP_MARKER ломал разбор обёртки целиком: три прогона pack
# показывали "top can not be validated" без объяснения. ipx не разворачивает
# выражения над векторными параметрами.
#
# Но убрать параметры ПОЛНОСТЬЮ оказалось хуже: без
# C_S_AXI_CONTROL_ADDR_WIDTH ipx не выводит РАЗМЕР memory map для
# s_axi_control, сегмент в BD не создаётся, и user-ядро читается по случайному
# адресу как 0xDEC0DEE3 (прогон на плате 25.08). network_krnl при этом
# отвечает нормально -- то есть отказ выглядит как "наше ядро мёртвое".
#
# integer ipx понимает: так у probe (C_S_AXI_CONTROL_ADDR_WIDTH = 12) и у
# network_krnl (C_S_AXI_ADDR_WIDTH), то есть у всех, кто читается по JTAG.
bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    m = re.search(r"module\s+(\w+)\s*#\s*\((.*?)\)\s*\(", src, re.S)
    if not m:
        continue
    mod, plist = m.groups()
    for pm in re.finditer(r"parameter\s+(\S+)\s+(\w+)", plist):
        typ, name = pm.groups()
        if typ != "integer":
            bad.append(f"{os.path.basename(f)}: {mod}, parameter {typ} {name}")
check(not bad, "векторных параметров нет"
      + ("" if not bad else ": " + "; ".join(bad)))

print("\n[3] нет дубликатов объявлений")
#
# Vivado на это даёт WARNING 9-3395 и "second declaration is ignored" -- то
# есть работает с первым, а вы правите второе и не понимаете, почему нет
# эффекта.
bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    seen = {}
    for m in re.finditer(r"^\s*(?:reg|wire|logic)\s+(?:\[[^\]]+\]\s+)?(\w+)", src, re.M):
        name = m.group(1)
        if name in seen:
            bad.append(f"{os.path.basename(f)}: {name} объявлен дважды")
        seen[name] = True
check(not bad, "дубликатов нет" + ("" if not bad else ": " + "; ".join(bad)))

# ---------------------------------------------------------------------------
print("\n[4] нет использования до объявления")
#
# Синтез это иногда прощает, парсер IP нет (память проекта:
# xvlog-stricter-than-synth). Проверяем только сигналы, объявленные на уровне
# модуля -- внутри always порядок не важен.
bad = []
for f in HDL:
    lines = open(f).read().split("\n")
    decl, use = {}, {}
    for i, raw in enumerate(lines, 1):
        if raw.strip().startswith("//"):
            continue
        line = strip_comments(raw)
        m = re.match(r"^\s*(?:reg|wire)\s+(?:\[[^\]]+\]\s+)?(\w+)", line)
        if m:
            decl.setdefault(m.group(1), i)
            continue
        for name in decl:
            pass
    # второй проход: где сигнал впервые упомянут не в объявлении
    for name, dline in decl.items():
        for i, raw in enumerate(lines, 1):
            if raw.strip().startswith("//"):
                continue
            line = strip_comments(raw)
            if re.match(r"^\s*(?:reg|wire)\s+(?:\[[^\]]+\]\s+)?" + name + r"\b", line):
                continue
            if re.search(r"\b" + name + r"\b", line):
                if i < dline:
                    bad.append(f"{os.path.basename(f)}: {name} использован в {i}, объявлен в {dline}")
                break
check(not bad, "порядок объявлений верный" + ("" if not bad else ": " + "; ".join(bad)))

# ---------------------------------------------------------------------------
print("\n[5] баланс begin/end, module/endmodule, case/endcase")
bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    for a, b in [("begin", "end"), ("module", "endmodule"), ("case", "endcase")]:
        na = len(re.findall(r"\b" + a + r"\b", src))
        nb = len(re.findall(r"\bend\b" if a == "begin" else r"\b" + b + r"\b", src))
        if na != nb:
            bad.append(f"{os.path.basename(f)}: {a}={na} {b}={nb}")
check(not bad, "баланс сходится" + ("" if not bad else ": " + "; ".join(bad)))

# ---------------------------------------------------------------------------
print("\n[6] SystemVerilog-конструкций нет")
#
# У probe, который через pack прошёл, нет ни typedef enum, ни always_ff.
# Держимся его формы -- Verilog-2001.
bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    for kw in ["typedef", "always_ff", "always_comb", "logic"]:
        if re.search(r"\b" + kw + r"\b", src):
            bad.append(f"{os.path.basename(f)}: {kw}")
check(not bad, "чистый Verilog-2001" + ("" if not bad else ": " + "; ".join(bad)))

print("\n[7] все сигналы объявлены")
#
# ЭТО НАШЛОСЬ НЕ ЗДЕСЬ, А В pack 14:57 -- двенадцать сообщений
# "'k_awvalid' is not declared". Блок объявлений k_* пропал при переписывании
# арбитража, а использование в инстансе ядра осталось.
#
# И это худший класс дефекта: Vivado РАЗОБРАЛ модуль, упаковал IP, integrity
# check прошёл. Без check_syntax дефект дошёл бы до синтеза BD, где
# неподключённые провода стали бы нулями -- ядро не отвечало бы на AXI-Lite
# вообще, а выглядело бы это как "регистры не пишутся".
#
# Проверка простая: каждый идентификатор, похожий на сигнал и используемый в
# правой части или в списке подключений, должен быть либо объявлен, либо быть
# портом, либо localparam.
KEYWORDS = set("""
module endmodule input output inout wire reg logic assign always begin end
case endcase default if else posedge negedge or and not xor localparam
parameter integer generate endgenerate for while function endfunction task
endtask initial timescale default_nettype none ifdef ifndef endif define
signed unsigned genvar real time
""".split())

bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    # объявленные имена: порты, wire/reg, localparam
    declared = set()
    for m in re.finditer(r"\b(?:input|output|inout)\s+(?:wire|reg|logic)?\s*(?:\[[^\]]+\]\s*)?(\w+)", src):
        declared.add(m.group(1))
    for m in re.finditer(r"\b(?:wire|reg|logic)\s+(?:\[[^\]]+\]\s*)?([\w\s,]+?)\s*(?:=|;)", src):
        for name in m.group(1).split(","):
            declared.add(name.strip())
    for m in re.finditer(r"\blocalparam\b[^;]*?(\w+)\s*=", src):
        declared.add(m.group(1))
    for m in re.finditer(r"localparam\s+(?:\[[^\]]+\]\s+)?([\w\s,=\'hbdo0-9_]+);", src):
        for part in m.group(1).split(","):
            nm = part.split("=")[0].strip()
            if nm: declared.add(nm)
    # имена модулей и инстансов -- не сигналы
    for m in re.finditer(r"^\s*(\w+)\s+(\w+)\s*\(", src, re.M):
        declared.add(m.group(1)); declared.add(m.group(2))

    # использования: в списках подключений .port ( signal )
    for m in re.finditer(r"\.\w+\s*\(\s*([A-Za-z_]\w*)", src):
        name = m.group(1)
        if name in KEYWORDS or name in declared: continue
        bad.append(f"{os.path.basename(f)}: {name} использован, не объявлен")

check(not bad, "необъявленных сигналов нет"
      + ("" if not bad else ": " + "; ".join(sorted(set(bad))[:6])))

print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
