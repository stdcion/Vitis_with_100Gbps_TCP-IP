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
print("\n[2] у модулей нет параметров")
#
# Векторный parameter у модуля -- то, на чём ipx-парсер спотыкался в обёртке
# (parameter [47:0] PP_MARKER) и в lat_fifo (parameter DEPTH_LOG2, из которого
# выводился localparam в размерности массива). У probe, который через pack
# прошёл, параметры только integer.
#
# Здесь запрет полный: инстанс каждого модуля один, параметризация не нужна,
# а цена ошибки -- упакованный не тот модуль.
bad = []
for f in HDL:
    src = strip_comments(open(f).read())
    for m in re.finditer(r"module\s+(\w+)\s*#\s*\(", src):
        bad.append(f"{os.path.basename(f)}: module {m.group(1)} с параметрами")
check(not bad, "параметров у модулей нет" + ("" if not bad else ": " + "; ".join(bad)))

# ---------------------------------------------------------------------------
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

print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
