#!/usr/bin/env python3
"""Проверяет, что все ВЫВОДИМЫЕ строки Tcl-скриптов -- чистый ASCII.

ЗАЧЕМ. Кодировка в консоли Vivado на этой машине сломана: русские буквы в puts
выводятся мусором, и диагностическое сообщение становится нечитаемым именно
тогда, когда оно нужнее всего -- у платы, в 10-минутном окне.

Комментарии НЕ проверяются: они не печатаются, а объясняют код тому, кто его
читает, и по-русски объясняют лучше.

Проверяются любые не-ASCII, а не только кириллица: длинное тире и
кавычки-лапки ломают вывод так же, а глазами в диффе незаметны.

Запуск:
    python3 scripts/vivado/check_ascii_output.py [файлы...]
По умолчанию -- jtag_ctrl.tcl. Код возврата 1, если что-то найдено.
"""
import re
import sys
from pathlib import Path

DEFAULT = [Path(__file__).resolve().parent / "jtag_ctrl.tcl"]


def check(path):
    bad = []
    for i, line in enumerate(path.read_text().split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if "puts" not in line and "_ec_line" not in line:
            continue
        # хвостовой комментарий вида ";# ..." отбрасываем
        code = line.split(";#")[0]
        for lit in re.findall(r'"([^"]*)"', code):
            offenders = sorted({c for c in lit if ord(c) > 127})
            if offenders:
                bad.append((i, "".join(offenders), lit[:70]))
    return bad


def main(argv):
    paths = [Path(a) for a in argv[1:]] or DEFAULT
    total = 0
    for p in paths:
        if not p.is_file():
            print("*** нет файла: %s" % p)
            return 1
        bad = check(p)
        total += len(bad)
        for i, chars, text in bad:
            print("%s:%d: не-ASCII [%s] в выводимой строке: %s" % (p.name, i, chars, text))
    if total:
        print("")
        print("*** %d выводимых строк с не-ASCII." % total)
        print("    Консоль Vivado здесь ломает кодировку -- сообщение станет мусором.")
        print("    Перепишите ТЕКСТ СТРОКИ на латиницу; комментарии можно оставить.")
        return 1
    print("все выводимые строки -- ASCII (%d файлов проверено)" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))


# ── ВТОРАЯ ПРОВЕРКА: ТРАНСЛИТ ────────────────────────────────────────────────
#
# ASCII мало. Русские слова латиницей ("stadija zhiva pri molchaschem steke")
# формально ASCII, но читаются хуже и русского, и английского: не помогают ни
# тому, кто знает русский, ни тому, кто нет. Отзыв пользователя 19.08:
# "такое в скриптах тяжело читать".
#
# Правило: текст выводимых строк -- ПО-АНГЛИЙСКИ. Комментарии -- по-русски,
# они не печатаются.
#
# Список корней, а не словарь: транслит узнаётся по русским корням, записанным
# латиницей, и полный словарь тут не нужен -- хватает частых.
TRANSLIT = re.compile(
    r"\b(rabota\w*|stek\w*|prohod\w*|otvet\w*|zapis\w+|stadij\w*|shina|shinu|"
    r"taktov|takta|defekt\w*|slovo|klient\w*|impuls\w*|dohodit|vlozhen\w*|nado|"
    r"ozhida\w+|molcha\w*|zhiv\w+|uspeh\w*|otkaz\w*|podhvach\w*|poterjan|razbor|"
    r"arifmetika|sosed\w*|vstal\w*|vzjal|zamerl\w*|barjer|lechenie|sbros\w*|"
    r"dolzhn\w*|bylo|vyshe|zanovo|povtor\w*|tajmaut\w*|pozdn\w+|prinjat|zapert|"
    r"sootvet\w*|nichego|provereno|nedejstv\w*|gipotez\w*|prichin\w*|iskat|"
    r"smotret|proverte|delajte|govorj\w*|ispravn\w*|edinic\w*|redko)\b",
    re.I)


def check_translit(path):
    """Ищет транслит в литералах add("...") генераторов и в puts Tcl.

    ЛОЖНОЕ СРАБАТЫВАНИЕ, из-за которого нужен этот фильтр: генератор часто
    печатает СИ-комментарий внутрь тестбенча, и в нём цитируется старое
    сообщение с транслитом -- например пояснение, почему фаза 5 была зелёной
    случайно. Это комментарий в СГЕНЕРИРОВАННОМ файле, он никуда не выводится.
    Отличаем по началу литерала: "// ..." -- комментарий, а не сообщение.
    """
    bad = []
    for i, line in enumerate(path.read_text().split("\n"), 1):
        if line.strip().startswith("#"):
            continue
        # Python-генераторы пишут строки как add("\"текст\"") -- экранированные
        # кавычки; Tcl пишет puts "текст".
        lits = re.findall(r'\\"([^"]*?)\\"', line) + re.findall(r'"([^"]*)"', line)
        for lit in lits:
            if lit.lstrip().startswith("//"):
                continue
            m = TRANSLIT.search(lit)
            if m:
                bad.append((i, m.group(0), lit.strip()[:70]))
    return bad
