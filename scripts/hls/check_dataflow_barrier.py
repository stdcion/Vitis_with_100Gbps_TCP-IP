#!/usr/bin/env python3
# =============================================================================
# check_dataflow_barrier.py -- кто в барьере DATAFLOW и нужен ли ему перезапуск
# =============================================================================
#
# ЗАЧЕМ. Отказ pp_dual на плате 25-26.08 объяснялся так: стадии-автоматы
# (switch + return, один шаг за вызов) не могут делить регион со стадиями,
# которые не завершаются -- барьер ap_sync_done не даст автоматам
# перезапуститься.
#
# Скрипт проверяет это на СГЕНЕРИРОВАННОМ RTL плюс исходниках, то есть на том,
# что реально идёт в битстрим.
#
# ПОЧЕМУ НЕ ХВАТАЕТ ОДНОГО RTL. Первая версия судила по форме ap_start
# (barrier / free-running) и дала бы неверный ответ: у РАБОТАЮЩЕГО recv_krnl
# все шесть стадий под барьером, включая висящий recvData. То есть барьер там
# тоже не срабатывает, и ядро работает. Решает не форма ap_start, а СКОЛЬКО
# РАБОТЫ СТАДИЯ ДЕЛАЕТ ЗА ОДИН ВЫЗОВ -- а это видно только в исходнике.
#
# ПОЧЕМУ НУЖНА РЕКУРСИЯ. Вторая версия искала цикл прямо в теле стадии и снова
# соврала: recvData сам циклов не имеет, он ВЫЗЫВАЕТ recvData_handshake и
# recvData_consumeData, и do-while уже в них. Поэтому обход идёт по вызовам
# вглубь.
#
# ЗАПУСК на сборочной машине, после make user_ip:
#     python3 scripts/hls/check_dataflow_barrier.py hls_pp_dual_krnl

import os
import re
import sys

if len(sys.argv) < 2:
    print("usage: %s <kernel-name>" % sys.argv[0])
    sys.exit(2)

KRNL = sys.argv[1]
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SYN = os.path.join(ROOT, "kernel/user_krnl", KRNL, "src/hls",
                   KRNL + "_ip_proj/sol1/syn/verilog")
TOP = os.path.join(SYN, KRNL + ".v")

if not os.path.isfile(TOP):
    print("*** нет %s" % TOP)
    print("    Сначала: make -f Makefile.vivado user_ip USER_KRNL=%s BOARD=u200" % KRNL)
    sys.exit(1)

top_src = open(TOP).read()

# ── исходники, в которых ищем тела функций ──
SOURCES = []
for p in [os.path.join(ROOT, "kernel/user_krnl", KRNL, "src/hls", KRNL + ".cpp"),
          os.path.join(ROOT, "kernel/common/include/communication.hpp")]:
    if os.path.isfile(p):
        SOURCES.append((os.path.basename(p), open(p).read()))


def body_of(fn):
    """Тело функции fn из любого исходника. None если не найдена."""
    for name, src in SOURCES:
        m = re.search(r"^(?:void|static void|template[^\n]*\nvoid)\s+" +
                      re.escape(fn) + r"\s*\(", src, re.M)
        if not m:
            continue
        # от начала до строки, где закрывающая скоба в нулевой колонке
        rest = src[m.start():]
        end = re.search(r"\n\}", rest)
        return rest[:end.end()] if end else rest
    return None


def has_unbounded_loop(fn, depth=0, seen=None):
    """Есть ли в fn (или в том, что она вызывает) цикл по ВНЕШНЕМУ условию.

    Такой цикл означает: стадия работает внутри одного вызова и перезапуск
    ей не нужен. Ограниченный `for (i = 0; i < N; ++i)` не считается -- он
    завершается.
    """
    if seen is None:
        seen = set()
    if fn in seen or depth > 4:
        return False, []
    seen.add(fn)

    body = body_of(fn)
    if body is None:
        return False, []

    # while / do-while по внешнему условию
    if re.search(r"\b(while|do)\b", body):
        return True, [fn]

    # вглубь по вызовам
    for callee in set(re.findall(r"^\s+(\w+)\s*\(", body, re.M)):
        if callee in ("if", "for", "while", "return", "switch", "printf"):
            continue
        found, chain = has_unbounded_loop(callee, depth + 1, seen)
        if found:
            return True, [fn] + chain
    return False, []


print("=" * 62)
print("RTL: %s" % TOP)
print("=" * 62)

# ── 1. вложенные регионы ──
nested = [f for f in os.listdir(SYN)
          if re.match(r"^%s_.*_core\.v$" % re.escape(KRNL), f)]
print("\n--- 1. ВЛОЖЕННЫЕ РЕГИОНЫ ---")
if nested:
    for f in nested:
        print("    " + f)
    print("    У dual_echo вложенный регион был отдельным дефектом:")
    print("    барьер внутри core работает свой, независимо от верхнего.")
else:
    print("    нет -- регион плоский, как у работающего recv_krnl")

# ── 2. барьер ──
m = re.search(r"assign ap_sync_done = \(([^;]*)\)", top_src)
stages = []
print("\n--- 2. БАРЬЕР ap_sync_done ---")
if m:
    for part in m.group(1).split("&"):
        part = part.strip()
        if part.endswith("_ap_done"):
            inst = part[:-len("_ap_done")]
            fn = re.sub(r"_U0$", "", inst)
            fn = re.sub(r"_\d+$", "", fn)      # tie_off_udp_2 -> tie_off_udp
            stages.append((inst, fn))
            print("    " + inst)
else:
    print("    не найден -- в регионе одна стадия или барьера нет")

# ── 3. кому нужен перезапуск ──
print("\n--- 3. ЧТО СТАДИЯ ДЕЛАЕТ ЗА ОДИН ВЫЗОВ ---")
print("    Решающий признак, и из RTL он НЕ виден. Ищем в исходнике,")
print("    рекурсивно по вызовам: recvData сам циклов не имеет, а")
print("    recvData_handshake внутри -- имеет.\n")

self_loop, need_restart, unknown = [], [], []
for inst, fn in stages:
    found, chain = has_unbounded_loop(fn)
    if body_of(fn) is None:
        unknown.append(fn)
        print("    %-32s ?? тело не найдено" % fn)
    elif found:
        self_loop.append(fn)
        where = " -> ".join(chain)
        print("    %-32s цикл (%s)" % (fn, where))
    else:
        need_restart.append(fn)
        print("    %-32s без цикла -- НУЖЕН перезапуск" % fn)

# ── 4. вывод ──
print("\n--- 4. ВЫВОД ---")
print("    работают внутри вызова:  %d" % len(self_loop))
print("    нуждаются в перезапуске: %d" % len(need_restart))
if unknown:
    print("    не определено:           %d (%s)" % (len(unknown), ", ".join(unknown)))
print()

if self_loop and need_restart:
    print("    *** ОПАСНАЯ СМЕСЬ.")
    print("        Стадии с циклом не завершаются -> барьер не срабатывает")
    print("        -> стадии без цикла делают ОДИН шаг и встают.")
    print("        Так отказал pp_dual 25.08: pp_listen успел записать порт,")
    print("        pp_echo проверил уведомления один раз и замолчал.")
    print("        Апстрим такой смеси не допускает нигде: у всех 8 стадий")
    print("        iperf_client циклов ноль, а в recv_krnl висящий recvData")
    print("        соседствует только с tie_off, которым работы не дано.")
    sys.exit(1)
elif self_loop:
    print("    все стадии работают внутри вызова -- перезапуск не нужен,")
    print("    висящий барьер не мешает. Так устроен recv_krnl (фаза 3).")
elif need_restart:
    print("    все стадии нуждаются в перезапуске, и все его получат:")
    print("    барьер срабатывает, регион крутится. Это то, что нужно")
    print("    автоматам pp_listen/pp_echo.")
print("=" * 62)
