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

DEPTH = 128


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

    def tick(self, wr_en=False, wr_data=0, rd_pop=False):
        if wr_en and not self.full and rd_pop and not self.empty:
            self.mem[self.wr] = wr_data
            self.wr = (self.wr + 1) % self.depth
            self.rd = (self.rd + 1) % self.depth
        elif wr_en and not self.full:
            self.mem[self.wr] = wr_data
            self.wr = (self.wr + 1) % self.depth
            self.cnt += 1
        elif rd_pop and not self.empty:
            self.rd = (self.rd + 1) % self.depth
            self.cnt -= 1
            # full && rd_pop: запись отбрасывается, но ЗАСЧИТЫВАЕТСЯ.
            if wr_en:
                self.ovf += 1
        elif wr_en:
            self.ovf += 1


fails = 0


def check(cond, what):
    global fails
    if cond:
        print("  [ OK ] " + what)
    else:
        print("  [FAIL] " + what)
        fails += 1


# ---------------------------------------------------------------------------
print("[1] пустое FIFO")
f = LatFifo()
check(f.empty and not f.full and f.cnt == 0, "после сброса пусто")
check(f.ovf == 0, "overflow ноль")

# ---------------------------------------------------------------------------
print("\n[2] запись и чтение по одному")
f = LatFifo()
f.tick(wr_en=True, wr_data=0xAAA)
check(f.cnt == 1 and not f.empty, "одна запись легла")
check(f.rd_data() == 0xAAA, "читается то, что записали")
f.tick(rd_pop=True)
check(f.cnt == 0 and f.empty, "после pop снова пусто")

# ---------------------------------------------------------------------------
print("\n[3] порядок FIFO сохраняется")
f = LatFifo()
for i in range(10):
    f.tick(wr_en=True, wr_data=0x100 + i)
got = []
for _ in range(10):
    got.append(f.rd_data())
    f.tick(rd_pop=True)
check(got == [0x100 + i for i in range(10)], "порядок первый-вошёл-первый-вышел")

# ---------------------------------------------------------------------------
print("\n[4] заполнение до края")
f = LatFifo()
for i in range(DEPTH):
    f.tick(wr_en=True, wr_data=i)
check(f.cnt == DEPTH and f.full, "ровно DEPTH записей, full поднят")
check(f.ovf == 0, "ни одной потери до края")

# ---------------------------------------------------------------------------
print("\n[5] ПЕРЕПОЛНЕНИЕ: старое цело, новое отброшено")
#
# Это главное требование: "чтобы фифо нормально сработало, без переключений".
# Проверяем ИМЕННО ЭТО -- что первые DEPTH записей не пострадали.
f = LatFifo()
for i in range(DEPTH + 50):
    f.tick(wr_en=True, wr_data=0x1000 + i)
check(f.ovf == 50, "потерь ровно 50 (лишние записи)")
check(f.cnt == DEPTH, "в FIFO по-прежнему DEPTH записей")
got = []
for _ in range(DEPTH):
    got.append(f.rd_data())
    f.tick(rd_pop=True)
expect = [0x1000 + i for i in range(DEPTH)]
check(got == expect, "СТАРЫЕ записи целы -- лежат ПЕРВЫЕ DEPTH, без затирания")

# ---------------------------------------------------------------------------
print("\n[6] одновременные wr_en и rd_pop: cnt не меняется")
f = LatFifo()
for i in range(10):
    f.tick(wr_en=True, wr_data=i)
before = f.cnt
val = f.rd_data()
f.tick(wr_en=True, wr_data=0x999, rd_pop=True)
check(f.cnt == before, "cnt тот же: одна вошла, одна вышла")
check(val == 0, "прочитали старейшую (0)")
check(f.ovf == 0, "потерь нет")

# ---------------------------------------------------------------------------
print("\n[7] край: full + wr_en + rd_pop одновременно")
#
# При полном FIFO и одновременном rd_pop место освобождается в этом же такте.
# Первая ветвь always требует !full, поэтому управление уходит в ветвь rd_pop:
# чтение проходит, а ЗАПИСЬ ОТБРАСЫВАЕТСЯ, хотя место появилось.
#
# ЭТО ОСОЗНАННОЕ ПОВЕДЕНИЕ, А НЕ ДЕФЕКТ. Пропустить запись в этом такте
# означало бы читать и писать одну ячейку одновременно при wr_ptr == rd_ptr --
# на BRAM это чтение неопределённого значения. Отбросить проще и безопаснее.
#
# Цена: одна потерянная запись на такое совпадение. Наступить оно может только
# если хост читает FIFO, пока идут пакеты, -- а порядок работы обратный
# (прогон, потом чтение). И даже наступив, потеря ВИДНА в overflow, а не
# молчит.
#
# Проверяем ФАКТ, а не желаемое: запись отбрасывается, чтение проходит,
# счётчик потерь растёт на 1.
f = LatFifo()
for i in range(DEPTH):
    f.tick(wr_en=True, wr_data=i)
assert f.full
ovf_before, cnt_before = f.ovf, f.cnt
oldest = f.rd_data()
f.tick(wr_en=True, wr_data=0xDEAD, rd_pop=True)
check(oldest == 0, "чтение отдало старейшую запись")
check(f.cnt == cnt_before - 1, "cnt уменьшился: чтение прошло, запись нет")
check(f.ovf == ovf_before + 1, "потеря ЗАСЧИТАНА в overflow, а не молча")

# ---------------------------------------------------------------------------
print("\n[8] clear чистит данные, но НЕ счётчик потерь")
f = LatFifo()
for i in range(DEPTH + 7):
    f.tick(wr_en=True, wr_data=i)
ovf_was = f.ovf
f.clear()
check(f.cnt == 0 and f.empty, "после clear данных нет")
check(f.ovf == ovf_was, "overflow пережил clear -- потери прошлого прогона видны")

# ---------------------------------------------------------------------------
print("\n[9] pop из пустого ничего не ломает")
f = LatFifo()
for _ in range(5):
    f.tick(rd_pop=True)
check(f.cnt == 0 and f.rd == 0, "указатель не поехал")
f.tick(wr_en=True, wr_data=0x55)
check(f.rd_data() == 0x55, "запись после лишних pop читается верно")

# ---------------------------------------------------------------------------
print("\n[10] реальный сценарий: 100 измерений, потом чтение")
#
# Ровно то, как это будет работать: ppclient -count 100, затем хост
# вычитывает FIFO целиком.
f = LatFifo()
for i in range(100):
    f.tick(wr_en=True, wr_data=(i << 10) | 0x40000000)
check(f.cnt == 100, "100 измерений в FIFO")
check(f.ovf == 0, "ни одной потери -- 100 < DEPTH")
out = []
while not f.empty:
    out.append(f.rd_data())
    f.tick(rd_pop=True)
check(len(out) == 100, "вычитано 100 слов")
# МАСКА ОБЯЗАТЕЛЬНА. Первая версия проверки писала (w >> 10) == i и падала:
# бит 30 (valid_all) после сдвига остаётся в слове, поэтому сравнение с i
# ложно при любом целом FIFO. Дефект был в ТЕСТЕ, не в железе -- ровно тот
# случай, когда красный тест обвиняет невиновного.
check(all(((w >> 10) & 0x3FF) == i for i, w in enumerate(out)),
      "все измерения на месте и по порядку")

# ---------------------------------------------------------------------------
print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
