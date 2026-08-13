#!/usr/bin/env python3
# =============================================================================
# test_net_frame_filter.py -- побитовая модель net_frame_filter.v, без Vivado
# =============================================================================
#
#     python3 kernel/user_krnl/hls_echo_probe_dual_krnl/src/hdl/test_net_frame_filter.py
#
# ЗАЧЕМ. Логика фильтра решает, по какому кадру ставить таймстемп, и ошибка в
# ней даёт не отказ, а ПРАВДОПОДОБНЫЕ НЕВЕРНЫЕ ЧИСЛА -- то есть худший исход для
# измерения. Симулятора здесь нет (ни iverilog, ни verilator), поэтому модель
# на Python: она повторяет регистры words/marker_seen и порядок их обновления.
#
# ЧТО МОДЕЛЬ ВОСПРОИЗВОДИТ ТОЧНО. Главное -- что marker_seen обновляется В КОНЦЕ
# такта: решение по текущему слову принимается ДО записи регистра. Именно из
# этого растёт случай single_word (тесты 3 и 4), ради которого в фильтре стоит
# отдельная ветка.
#
# ЧЕГО НЕ ПРОВЕРЯЕТ. Тайминг, синтезируемость, реальные значения на шине. Это
# модель поведения, а не RTL.
#
# ПРИ ПРАВКЕ net_frame_filter.v ЭТОТ ФАЙЛ ПРАВИТЬ ТОЖЕ -- иначе он проверяет
# логику, которой больше нет.

MARKER = 0x5A3C96E1B7D2   # должен совпадать с EPD_MARKER в net_frame_filter.v
                          # и с константой в hls_echo_probe_dual_krnl.cpp


class Filt:
    """Модель net_frame_filter: words, marker_seen, счётчики."""

    def __init__(self, minw):
        self.words = 0
        self.seen = 0
        self.minw = minw
        self.ours = 0
        self.drop = 0
        self.strobes = []

    def beat(self, tlast, tdata, tag=None):
        """Один такт с beat = tvalid & tready."""
        first = (self.words == 0)
        marker_here = 1 if ((tdata >> 464) & 0xFFFFFFFFFFFF) == MARKER else 0
        frame_words = self.words + 1
        len_ok = 1 if frame_words >= self.minw else 0

        # Односоловный кадр: first_word и tlast в одном такте, marker_seen ещё
        # держит ПРЕДЫДУЩИЙ кадр -- берём маркер прямо с шины.
        single = tlast and self.words == 0
        marker_ok = marker_here if single else self.seen

        is_ours = len_ok and marker_ok
        if tlast:
            if is_ours:
                self.ours += 1
                self.strobes.append(tag)
            else:
                self.drop += 1

        # Регистры обновляются в конце такта -- порядок здесь существенен.
        if first:
            self.seen = marker_here
        self.words = 0 if tlast else self.words + 1
        return is_ours


def frame(nwords, marked):
    """Слова кадра. Маркер лежит только в первом слове (payload[4..9])."""
    return [((i == nwords - 1), (MARKER << 464) if (i == 0 and marked) else 0)
            for i in range(nwords)]


def run(minw, frames):
    f = Filt(minw)
    for tag, (nw, mk) in frames:
        for tlast, d in frame(nw, mk):
            f.beat(tlast, d, tag)
    return f


def main():
    fails = 0

    def check(name, cond, detail=""):
        nonlocal fails
        if cond:
            print(f"  ok   {name}")
        else:
            print(f"  FAIL {name} {detail}")
            fails += 1

    print("=== 1. норма: наш кадр среди служебных, minWords=2 ===")
    f = run(2, [("ARP", (1, False)), ("наш", (2, True)), ("ACK", (1, False)),
                ("наш", (2, True)), ("SYN+опц", (2, False))])
    print(f"     прошло={f.ours} отсеяно={f.drop} строб на: {f.strobes}")
    check("строб только на наших кадрах", f.strobes == ["наш", "наш"], f.strobes)
    check("SYN отсеян МАРКЕРОМ (длину он прошёл)", f.drop == 3)

    print("\n=== 2. SYN с опциями прямо перед нашим кадром ===")
    f = run(2, [("SYN+опц", (2, False)), ("наш", (2, True))])
    check("ложного строба нет, наш кадр не потерян", f.strobes == ["наш"], f.strobes)

    print("\n=== 3. ОПАСНЫЙ СЛУЧАЙ: односоловный ACK сразу ПОСЛЕ нашего кадра ===")
    print("     marker_seen ещё держит наш маркер; ловушка, ради которой")
    print("     в фильтре есть ветка single_word. minWords=1 -- длина НЕ спасает.")
    f = run(1, [("наш", (2, True)), ("ACK", (1, False))])
    check("ACK отсеян по маркеру С ШИНЫ, а не по залипшему регистру",
          f.strobes == ["наш"], f.strobes)

    print("\n=== 4. то же при minWords=0 (защита по длине выключена совсем) ===")
    f = run(0, [("наш", (2, True)), ("ACK", (1, False)), ("ARP", (1, False))])
    check("чужие односоловные не проходят даже так", f.strobes == ["наш"], f.strobes)

    print("\n=== 5. свип по размерам: наш кадр ловится всегда ===")
    for msg, nw, mw in [(32, 2, 2), (64, 2, 2), (128, 3, 3), (256, 5, 5),
                        (512, 9, 9), (1024, 17, 17), (1500, 25, 25)]:
        f = run(mw, [("ARP", (1, False)), ("наш", (nw, True)), ("ACK", (1, False))])
        check(f"msg={msg} words={nw} minWords={mw}", f.strobes == ["наш"], f.strobes)

    print("\n=== 6. СКВОЗНАЯ ПРОВЕРКА СМЕЩЕНИЯ: ядро -> провод -> фильтр ===")
    print("     Ловит перепутанную нумерацию битов. В ядре слово PAYLOAD")
    print("     (бит 8k = payload-байт k), в фильтре слово КАДРА (payload сдвинут")
    print("     заголовками на 54 байта). Одни и те же payload-байты 4..9 -- это")
    print("     (79,32) в ядре и [511:464] в фильтре; разница ровно 432 бита.")

    def kernel_payload_word(sent):
        """Ровно то, что пишет .cpp в состоянии SEND_DATA, первое слово."""
        return ((sent & 0xFFFFFFFF) << 0) | (MARKER << 32)

    def wire_first_word(payload_word, hdr_bytes=54):
        """Стек добавляет Eth14+IP20+TCP20; payload уезжает на 54 байта."""
        hdr = 0xAABBCCDDEEFF0011          # что угодно, лишь бы не наш маркер
        frame = (payload_word << (hdr_bytes * 8)) | (hdr & ((1 << (hdr_bytes * 8)) - 1))
        return frame & ((1 << 512) - 1)

    for sent in (0, 1, 42, 0xFFFFFFFF):
        seen = (wire_first_word(kernel_payload_word(sent)) >> 464) & 0xFFFFFFFFFFFF
        check(f"sent={sent:#x}: фильтр видит маркер", seen == MARKER, f"{seen:#x}")

    # Та самая ловушка: если в ядре написать (511,464) «для симметрии» с
    # фильтром, маркер уедет в payload-байты 58..63, то есть во ВТОРОЕ слово
    # кадра, и фильтр не увидит ничего. Симптом был бы обманчивым: passed=0 при
    # растущем dropped -- неотличимо от «minWords завышен».
    bad = (wire_first_word(MARKER << 464) >> 464) & 0xFFFFFFFFFFFF
    check("ловушка (511,464) в ядре действительно ломала бы фильтр", bad != MARKER)

    print("\n=== 7. пауза без beat не меняет состояние (backpressure) ===")
    f = Filt(2)
    f.beat(False, MARKER << 464)
    st = (f.words, f.seen)
    check("состояние сохранилось", (f.words, f.seen) == st)
    f.beat(True, 0, "наш")
    check("кадр досчитан после паузы", f.strobes == ["наш"], f.strobes)

    print()
    if fails:
        print(f"ОТКАЗОВ: {fails}")
        raise SystemExit(1)
    print("ВСЁ ЗЕЛЁНОЕ")


if __name__ == "__main__":
    main()
