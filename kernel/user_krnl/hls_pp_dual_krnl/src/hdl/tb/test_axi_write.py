#!/usr/bin/env python3
# =============================================================================
# test_axi_write.py -- автомат записи AXI-Lite обёртки
# =============================================================================
#
# ЗАЧЕМ. pp_raw делает ЧЕТЫРЕ записи POP подряд на каждое измерение. Если
# автомат принимает новый адрес, не отдав ответ на предыдущую запись, ответы
# схлопываются и хост ждёт bvalid вечно -- JTAG-транзакция виснет, и выглядит
# это как "плата не отвечает", неотличимо от мёртвого битстрима.
#
# Первая версия обёртки ровно так и висла. Нашлось СРАВНЕНИЕМ С ЭТАЛОНОМ
# dual_echo_control_s_axi.v -- обёрткой, которая работала на этой плате: там
# автомат записи трёхсостоянийный, и BVALID -- отдельное состояние.
#
# ЗАПУСК:  python3 test_axi_write.py

import sys

WRIDLE, WRDATA, WRRESP = range(3)


class AxiWrite:
    """Копия always_ff записи из hls_pp_dual_krnl_wrapper.sv."""

    def __init__(self):
        self.st = WRIDLE
        self.addr = 0
        self.pop = False
        self.clear = False
        self.minwords = 2
        self.pops = 0          # сколько раз строб реально сработал

    @property
    def awready(self):
        return self.st == WRIDLE

    @property
    def wready(self):
        return self.st == WRDATA

    @property
    def bvalid(self):
        return self.st == WRRESP

    def tick(self, awvalid=False, awaddr=0, wvalid=False, wdata=0, bready=False):
        # Условия -- по состоянию ДО такта, как в HDL.
        aw_hs = awvalid and self.awready
        w_hs = wvalid and self.wready
        b_hs = bready and self.bvalid

        if self.pop:
            self.pops += 1
        self.pop = False        # строб на один такт
        self.clear = False

        if self.st == WRIDLE:
            if aw_hs:
                self.addr = awaddr
                self.st = WRDATA
        elif self.st == WRDATA:
            if w_hs:
                if self.addr == 0x104:
                    self.pop = True
                elif self.addr == 0x128:
                    self.clear = True
                elif self.addr == 0x110:
                    self.minwords = wdata
                self.st = WRRESP
        elif self.st == WRRESP:
            if b_hs:
                self.st = WRIDLE


fails = 0


def check(cond, what):
    global fails
    print(("  [ OK ] " if cond else "  [FAIL] ") + what)
    if not cond:
        fails += 1


# ---------------------------------------------------------------------------
print("[1] одна запись: адрес, данные, ответ")
a = AxiWrite()
check(a.awready and not a.wready and not a.bvalid, "в покое готов принять адрес")
a.tick(awvalid=True, awaddr=0x104)
check(a.wready and not a.awready, "адрес принят, ждём данные, новый адрес НЕ берём")
a.tick(wvalid=True, wdata=1)
check(a.bvalid and not a.wready, "данные приняты, отдаём ответ")
check(not a.awready, "КЛЮЧЕВОЕ: пока ответ не отдан, адрес не принимаем")
a.tick(bready=True)
check(a.awready and not a.bvalid, "ответ отдан, снова готовы")

# ---------------------------------------------------------------------------
print("\n[2] ГЛАВНОЕ: четыре POP подряд, как делает pp_raw")
#
# Сценарий, на котором первая версия висла. Хост шлёт адрес+данные, ждёт
# bvalid, подтверждает -- и так четыре раза.
a = AxiWrite()
for i in range(4):
    a.tick(awvalid=True, awaddr=0x104)
    a.tick(wvalid=True, wdata=1)
    check(a.bvalid, f"запись {i}: ответ поднят")
    a.tick(bready=True)
a.tick()   # дать последнему стробу досчитаться
check(a.pops == 4, f"РОВНО четыре строба pop (получено {a.pops})")

# ---------------------------------------------------------------------------
print("\n[3] хост шлёт новый адрес, НЕ подтвердив предыдущий ответ")
#
# Именно так вёл себя мой первый вариант -- и принимал вторую запись, теряя
# ответ на первую. Теперь адрес должен быть проигнорирован.
a = AxiWrite()
a.tick(awvalid=True, awaddr=0x104)
a.tick(wvalid=True, wdata=1)
assert a.bvalid
# хост (ошибочно или из-за конвейеризации) шлёт следующий адрес
a.tick(awvalid=True, awaddr=0x110, wdata=99)
check(a.bvalid, "ответ ВСЁ ЕЩЁ висит -- не потерян")
check(not a.awready, "адрес НЕ принят: awready опущен")
check(a.minwords == 2, "и данные второй записи не применились")
# теперь по-честному
a.tick(bready=True)
a.tick(awvalid=True, awaddr=0x110)
a.tick(wvalid=True, wdata=7)
a.tick(bready=True)
check(a.minwords == 7, "после подтверждения вторая запись прошла")

# ---------------------------------------------------------------------------
print("\n[4] bready задержан на много тактов")
a = AxiWrite()
a.tick(awvalid=True, awaddr=0x128)
a.tick(wvalid=True, wdata=1)
for _ in range(20):
    a.tick()          # bready не приходит
    if not a.bvalid:
        break
check(a.bvalid, "ответ держится, пока хост не подтвердит")
a.tick(bready=True)
check(a.awready, "после подтверждения освободился")

# ---------------------------------------------------------------------------
print("\n[5] строб живёт РОВНО один такт")
#
# fifo_pop дольше одного такта сдвинул бы указатель дважды, и хост потерял бы
# слово, ничего не заметив.
a = AxiWrite()
a.tick(awvalid=True, awaddr=0x104)
a.tick(wvalid=True, wdata=1)
check(a.pop, "строб поднят в такте приёма данных")
a.tick(bready=True)
check(not a.pop, "и снят в следующем такте")
check(a.pops == 1, "сработал ровно один раз")

# ---------------------------------------------------------------------------
print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
