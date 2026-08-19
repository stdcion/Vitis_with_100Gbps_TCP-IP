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
