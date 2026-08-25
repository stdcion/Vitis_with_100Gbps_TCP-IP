#!/usr/bin/env python3
# =============================================================================
# test_lat_fifo.py -- модель lat_fifo.v и проверка её поведения
# =============================================================================
#
# ЗАЧЕМ МОДЕЛЬ, А НЕ SystemVerilog-тестбенч. Локального xvlog нет (Vitis стоит
# на сборочной машине), а логика FIFO -- это указатели и счётчик, то есть
# ровно то, что модель воспроизводит точно. Тем же способом проверялся
# net_frame_filter (test_net_frame_filter.py у probe-ядра).
#
# ЧТО МОДЕЛЬ НЕ ЛОВИТ: тайминги, ширину сигналов, ошибки синтеза. Для них --
# csynth и tb на сборочной машине. Здесь проверяется ЛОГИКА ветвей always,
# и именно в ней сидели два дефекта, найденные этим тестом (см. ниже).
#
# ЗАПУСК:  python3 test_lat_fifo.py

import sys

DEPTH = 512          # слов; измерений = DEPTH/4 = 128
WORDS_PER_SAMPLE = 4


class LatFifo:
    """Побитовая копия always-блока из lat_fifo.v.

    Ветви идут в ТОМ ЖЕ порядке и с теми же условиями -- иначе тест проверял
    бы не тот код. При правке .v правится и здесь.
    """

    def __init__(self, depth=DEPTH):
        self.depth = depth
        self.mem = [0] * depth
        self.wr = 0
        self.rd = 0
        self.cnt = 0
        self.ovf = 0
        self.shift = []
        self.wr_left = 0

    @property
    def empty(self):
        return self.cnt == 0

    @property
    def full(self):
        return self.cnt == self.depth

    def rd_data(self):
        # Асинхронное чтение по указателю: значение готово до rd_pop.
        return self.mem[self.rd]

    def clear(self):
        # ovf НЕ сбрасывается -- как в .v: потери прошлого прогона должны
        # пережить чистку данных.
        self.wr = self.rd = self.cnt = 0
        self.wr_left = 0
        self.shift = []

    @property
    def room4(self):
        return self.cnt <= self.depth - WORDS_PER_SAMPLE

    @property
    def busy(self):
        return self.wr_left != 0

    def tick(self, wr_en=False, stamps=None, rd_pop=False):
        """Один такт. stamps -- четвёрка (T2, t2, t1, T1) или None.

        ВСЕ УСЛОВИЯ ВЫЧИСЛЯЮТСЯ ДО ИЗМЕНЕНИЯ СОСТОЯНИЯ: в HDL правая часть
        неблокирующего присваивания берёт значение регистра ДО такта.
        Первая версия читала room4 повторно после изменения cnt и получала
        новое значение -- тест ловил "потерю", которой в железе нет.

        ЗАПИСЬ РАСТЯНУТА НА ЧЕТЫРЕ ТАКТА. Измерение принимается в регистр за
        один такт, потом выгружается в память по слову. Причина -- в .v:
        четыре порта записи плюс асинхронное чтение это пять портов к одному
        массиву, а BRAM даёт два.
        """
        room4 = self.room4
        busy = self.busy
        was_empty = self.empty

        accept = wr_en and room4 and not busy
        reject = wr_en and (not room4 or busy)

        if accept:
            self.shift = list(stamps)      # младшее вперёд
            self.wr_left = 4

        if busy:
            self.mem[self.wr] = self.shift.pop(0)
            self.wr = (self.wr + 1) % self.depth
            self.wr_left -= 1

        if busy and rd_pop and not was_empty:
            pass                            # +1 -1
        elif busy:
            self.cnt += 1
        elif rd_pop and not was_empty:
            self.cnt -= 1

        if rd_pop and not was_empty:
            self.rd = (self.rd + 1) % self.depth

        if reject:
            self.ovf += 1

    def push(self, stamps):
        """Подать измерение и дать выгрузке завершиться -- как это происходит
        на плате, где между пакетами сотни тактов."""
        self.tick(wr_en=True, stamps=stamps)
        for _ in range(4):
            self.tick()


fails = 0


def check(cond, what):
    global fails
    if cond:
        print("  [ OK ] " + what)
    else:
        print("  [FAIL] " + what)
        fails += 1


def sample(base):
    """Правдоподобная четвёрка меток: T2 < t2 < t1 < T1.

    Числа взяты из бюджета задержки (docs/toe-latency-budget-estimate):
    приём стека ~40 тактов, ядро ~10, передача ~40. Абсолютные значения не
    важны -- важно, что дельты положительны и сумма сходится.
    """
    T2 = base
    t2 = base + 40
    t1 = base + 50
    T1 = base + 90
    return (T2, t2, t1, T1)


def drain(f):
    """Вычитывает FIFO целиком и собирает четвёрки, как это сделает хост."""
    words = []
    while not f.empty:
        words.append(f.rd_data())
        f.tick(rd_pop=True)
    return [tuple(words[i:i + 4]) for i in range(0, len(words), 4)]


# ---------------------------------------------------------------------------
print("[1] пустое FIFO")
f = LatFifo()
check(f.empty and not f.full and f.cnt == 0, "после сброса пусто")
check(f.ovf == 0, "overflow ноль")

# ---------------------------------------------------------------------------
print("\n[2] одно измерение: четыре слова, порядок T2,t2,t1,T1")
f = LatFifo()
f.push(sample(1000))
check(f.cnt == 4, "легло РОВНО четыре слова")
got = drain(f)
check(len(got) == 1, "вычитана одна четвёрка")
check(got[0] == (1000, 1040, 1050, 1090), "метки в порядке T2,t2,t1,T1")

# ---------------------------------------------------------------------------
print("\n[3] СОГЛАСОВАННОСТЬ: суммa интервалов равна полному")
#
# Главная проверка, ради которой метки хранятся сырыми. Хост считает
# (t2-T2) + (t1-t2) + (T1-t1) и сверяет с (T1-T2). Не сойдётся -- значит
# метки от разных пакетов, и такую строку надо помечать, а не усреднять.
# Тот же приём в epd_raw: колонка status с флагом TORN.
f = LatFifo()
for i in range(10):
    f.push(sample(5000 + i * 200))
bad = 0
for (T2, t2, t1, T1) in drain(f):
    if (t2 - T2) + (t1 - t2) + (T1 - t1) != (T1 - T2):
        bad += 1
check(bad == 0, "все 10 четвёрок согласованы")

# ---------------------------------------------------------------------------
print("\n[4] порядок измерений сохраняется")
f = LatFifo()
for i in range(20):
    f.push(sample(i * 1000))
got = drain(f)
check([g[0] for g in got] == [i * 1000 for i in range(20)],
      "измерения вышли в порядке записи")

# ---------------------------------------------------------------------------
print("\n[5] заполнение до края: ровно DEPTH/4 измерений")
f = LatFifo()
for i in range(DEPTH // 4):
    f.push(sample(i * 100))
check(f.cnt == DEPTH and f.full, "%d слов, full поднят" % DEPTH)
check(f.ovf == 0, "ни одной потери до края")

# ---------------------------------------------------------------------------
print("\n[6] ПЕРЕПОЛНЕНИЕ: старое цело, новое отброшено ЦЕЛИКОМ")
#
# Требование было: "чтобы фифо нормально сработало, без переключений".
# Проверяем два свойства сразу:
#   * первые DEPTH/4 измерений не пострадали;
#   * отброшенные ушли ЧЕТВЁРКАМИ -- ни одного склеенного из двух пакетов.
f = LatFifo()
total = DEPTH // 4 + 37
for i in range(total):
    f.push(sample(i * 100))
check(f.ovf == 37, "потеряно ровно 37 ИЗМЕРЕНИЙ (не слов)")
check(f.cnt == DEPTH, "в FIFO по-прежнему полно")
got = drain(f)
check(len(got) == DEPTH // 4, "вычитано %d измерений" % (DEPTH // 4))
check([g[0] for g in got] == [i * 100 for i in range(DEPTH // 4)],
      "СТАРЫЕ измерения целы: первые %d, без затирания" % (DEPTH // 4))
bad = sum(1 for (T2, t2, t1, T1) in got
          if (t2 - T2) + (t1 - t2) + (T1 - t1) != (T1 - T2))
check(bad == 0, "ни одного склеенного измерения после переполнения")

# ---------------------------------------------------------------------------
print("\n[7] места на ТРИ слова недостаточно -- запись не начинается")
#
# Ключ к согласованности. Если бы проверялось место под одно слово, при трёх
# свободных легли бы T2,t2,t1 -- а T1 от СЛЕДУЮЩЕГО пакета. Хост увидел бы
# правдоподобную четвёрку из двух разных измерений.
f = LatFifo()
for i in range(DEPTH // 4 - 1):
    f.push(sample(i * 100))
# освобождаем ровно три слова
for _ in range(1):
    f.tick(rd_pop=True)
f.tick(rd_pop=True)
f.tick(rd_pop=True)
free = DEPTH - f.cnt
check(free == 7, "свободно 7 слов (4 хвост + 3 освобождённых)")
# теперь забиваем так, чтобы осталось ровно 3
f.push(sample(90000))
free = DEPTH - f.cnt
check(free == 3, "осталось ровно 3 свободных слова")
ovf_was = f.ovf
f.push(sample(99999))
check(f.ovf == ovf_was + 1, "запись при 3 свободных ОТБРОШЕНА и засчитана")
check(DEPTH - f.cnt == 3, "частичной записи не произошло: свободно всё те же 3")

# ---------------------------------------------------------------------------
print("\n[8] чтение хостом, пока идёт выгрузка измерения")
#
# Реальная ситуация: хост читает FIFO, а в это время приходит пакет. Выгрузка
# занимает четыре такта, и чтение может попасть в любой из них.
#
# Проверка не "cnt += 4 за такт" (так было в первой версии, когда все четыре
# слова писались одновременно), а что за полный цикл счёт сходится: четыре
# слова вошли, одно вышло.
f = LatFifo()
for i in range(10):
    f.push(sample(i * 100))
before = f.cnt
first = f.rd_data()

# подаём измерение и читаем ОДНОВРЕМЕННО с выгрузкой
f.tick(wr_en=True, stamps=sample(77000), rd_pop=True)
for _ in range(4):
    f.tick(rd_pop=True)

check(f.cnt == before + 4 - 5, "счёт сошёлся: 4 слова вошли, 5 вышли")
check(first == 0, "прочитано первое слово старейшего измерения")
check(f.ovf == 0, "потерь нет -- место было, выгрузка не была занята")

# И отдельно: приём ВО ВРЕМЯ выгрузки отбрасывается и считается.
f2 = LatFifo()
f2.tick(wr_en=True, stamps=sample(1000))      # начали выгрузку
ovf_was = f2.ovf
f2.tick(wr_en=True, stamps=sample(2000))      # второе измерение в тот же момент
check(f2.ovf == ovf_was + 1, "приём во время выгрузки отброшен И засчитан")

# ---------------------------------------------------------------------------
print("\n[9] clear чистит данные, но НЕ счётчик потерь")
f = LatFifo()
for i in range(DEPTH // 4 + 5):
    f.push(sample(i * 100))
ovf_was = f.ovf
f.clear()
check(f.cnt == 0 and f.empty, "после clear данных нет")
check(f.ovf == ovf_was, "overflow пережил clear -- потери прошлого прогона видны")

# ---------------------------------------------------------------------------
print("\n[10] pop из пустого ничего не ломает")
f = LatFifo()
for _ in range(5):
    f.tick(rd_pop=True)
check(f.cnt == 0 and f.rd == 0, "указатель не поехал")
f.push(sample(4242))
check(f.rd_data() == 4242, "запись после лишних pop читается верно")

# ---------------------------------------------------------------------------
print("\n[11] реальный сценарий: 100 измерений, потом чтение")
#
# Ровно как это будет работать: ppclient -count 100, затем хост вычитывает
# FIFO целиком в файл.
f = LatFifo()
for i in range(100):
    f.push(sample(10000 + i * 500))
check(f.cnt == 400, "100 измерений = 400 слов")
check(f.ovf == 0, "ни одной потери: 100 < %d" % (DEPTH // 4))
got = drain(f)
check(len(got) == 100, "вычитано 100 измерений")
bad = sum(1 for (T2, t2, t1, T1) in got
          if (t2 - T2) + (t1 - t2) + (T1 - t1) != (T1 - T2))
check(bad == 0, "все 100 согласованы")
check(all(g[0] == 10000 + i * 500 for i, g in enumerate(got)),
      "все на месте и по порядку")

# ---------------------------------------------------------------------------
print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
