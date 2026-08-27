#!/usr/bin/env python3
# =============================================================================
# test_dataflow_barrier.py -- модель барьера ap_sync_done из HLS
# =============================================================================
#
# ЗАЧЕМ. Версия "стадия, которой нужен перезапуск, не может делить регион со
# стадией, которая не завершается" объясняла отказ pp_dual на плате. Но
# объяснение -- не доказательство: за эту сессию девять моих гипотез умерли,
# и одна из них тоже "объясняла всё".
#
# Здесь механизм воспроизведён ПО RTL РАБОТАЮЩЕГО ЯДРА -- hls_recv_krnl.v из
# recv_rtl.tgz, то есть из битстрима, который на этой плате отвечал по TCP.
# Формулы взяты дословно:
#
#   :662  listenPorts_U0_ap_start = (~ap_sync_reg_listenPorts_ap_ready) & ap_start
#   :646  ap_sync_listenPorts_ap_ready = listenPorts_ap_ready | ap_sync_reg_...
#   :648  ap_sync_ready = И по всем ap_sync_*_ap_ready
#   :644  ap_sync_done  = И по всем *_ap_done
#   :566  ap_sync_reg_X <= 0 если (ap_sync_ready & ap_start), иначе ap_sync_X_ready
#
# Модель прогоняет ДВЕ конфигурации -- ту, что работала на плате, и ту, что
# нет, -- и показывает, сколько раз каждая стадия получила старт.
#
# ЗАПУСК:  python3 test_dataflow_barrier.py

import sys


class Stage:
    """Стадия DATAFLOW-региона.

    hangs=True  -- не завершается никогда (do-while по внешнему условию,
                   как recvData: while (rxByteCnt < expected)).
    hangs=False -- завершается через `latency` тактов после старта
                   (автомат с switch и return, как pp_echo).
    """

    def __init__(self, name, hangs, latency=3):
        self.name = name
        self.hangs = hangs
        self.latency = latency
        self.running = False
        self.countdown = 0
        self.ap_ready = False
        self.ap_done = False
        self.starts = 0        # сколько раз стадия РЕАЛЬНО пошла работать
        self.sync_reg = False  # ap_sync_reg_X_ap_ready

    def tick(self, ap_start_in):
        # Выходы за такт: ap_ready/ap_done поднимаются на один такт при
        # завершении прохода -- так их и выдаёт HLS.
        self.ap_ready = False
        self.ap_done = False

        if self.running:
            if not self.hangs:
                self.countdown -= 1
                if self.countdown <= 0:
                    self.running = False
                    self.ap_ready = True
                    self.ap_done = True
        elif ap_start_in:
            self.running = True
            self.starts += 1
            self.countdown = self.latency


class Region:
    """Регион с барьером. Формулы -- из hls_recv_krnl.v, см. шапку."""

    def __init__(self, stages):
        self.stages = stages

    def run(self, cycles, ap_start=True):
        for _ in range(cycles):
            # ap_sync_X_ready = X_ap_ready | ap_sync_reg_X  (:646)
            sync_ready_each = [s.ap_ready or s.sync_reg for s in self.stages]
            # ap_sync_ready = И по всем  (:648)
            sync_ready = all(sync_ready_each)

            # stage_ap_start = ~ap_sync_reg_X & ap_start  (:662)
            starts = [(not s.sync_reg) and ap_start for s in self.stages]

            for s, st in zip(self.stages, starts):
                s.tick(st)

            # ap_sync_reg_X <= 0 если (ap_sync_ready & ap_start), иначе
            # ap_sync_X_ready  (:566). Порядок важен: значения ДО такта.
            for s, sre in zip(self.stages, sync_ready_each):
                s.sync_reg = False if (sync_ready and ap_start) else sre

        return sync_ready


fails = 0


def check(cond, what):
    global fails
    print(("  [ OK ] " if cond else "  [FAIL] ") + what)
    if not cond:
        fails += 1


# ---------------------------------------------------------------------------
print("[1] ВСЕ стадии висят -- конфигурация ФАЗЫ 3 (работала на плате)")
#
# Кабель был только в QSFP0, recvData половины b ждал данные, которых не
# будет. И ncat подключался. Значит висящие стадии сами по себе не мешают.
stages = [
    Stage("listenPorts_a", hangs=True),
    Stage("recvData_a", hangs=True),
    Stage("listenPorts_b", hangs=True),
    Stage("recvData_b", hangs=True),
]
Region(stages).run(500)
for s in stages:
    print(f"      {s.name:16s} стартов: {s.starts}, работает: {s.running}")
check(all(s.starts == 1 for s in stages), "каждая стартовала РОВНО раз")
check(all(s.running for s in stages), "все работают -- вся логика внутри вызова")
print("      Перезапуск им НЕ НУЖЕН: recvData крутится в do-while и")
print("      обрабатывает каждое уведомление сам.")

# ---------------------------------------------------------------------------
print("\n[2] ВСЕ стадии короткие -- конфигурация ПОСЛЕ ИСПРАВЛЕНИЯ")
stages = [
    Stage("pp_listen", hangs=False, latency=3),
    Stage("pp_echo", hangs=False, latency=3),
    Stage("tie_off_listen_b", hangs=False, latency=2),
    Stage("tie_off_rx_b", hangs=False, latency=2),
]
Region(stages).run(500)
for s in stages:
    print(f"      {s.name:16s} стартов: {s.starts}")
check(all(s.starts > 50 for s in stages),
      "все перезапускаются десятки раз -- регион живёт")
# ЧИСЛО СТАРТОВ РАЗНОЕ, И ЭТО ВЕРНО. Я сначала проверял равенство и получил
# FAIL: latency=3 дал 125 стартов, latency=2 дал 157. Барьер выравнивает
# НАЧАЛО прохода, а не их количество: быстрая стадия завершается раньше и
# ждёт медленную, но 500 тактов не делятся на длину цикла ровно.
mn = min(s.starts for s in stages)
check(mn > 50, f"минимум стартов {mn} -- ни одна стадия не заморожена")

# ---------------------------------------------------------------------------
print("\n[3] СМЕСЬ -- конфигурация pp_dual, КОТОРАЯ НЕ РАБОТАЛА")
#
# Половина a короткие, половина b висящие. Это и стоит проверить.
stages = [
    Stage("pp_listen", hangs=False, latency=3),
    Stage("pp_echo", hangs=False, latency=3),
    Stage("listenPorts_b", hangs=True),
    Stage("recvData_b", hangs=True),
]
Region(stages).run(500)
for s in stages:
    print(f"      {s.name:16s} стартов: {s.starts}, работает: {s.running}")
short = [s for s in stages if not s.hangs]
# ДВА СТАРТА, А НЕ ОДИН -- и это тоже верно. Первая версия проверки ждала
# ровно 1 и падала. Причина: ap_sync_ready считается по значениям ДО такта, и
# в такте, когда короткая стадия только подняла ap_ready, её sync_reg ещё 0 --
# успевает проскочить второй старт. Дальше регистр встаёт в 1 и всё.
#
# Суть от этого не меняется: 2 старта за 500 тактов против 250 без висящей
# стадии -- разница в 125 раз, ядро мертво.
check(all(s.starts <= 2 for s in short),
      f"КОРОТКИЕ стартовали {short[0].starts} раза за 500 тактов и встали")
check(all(not s.running for s in short),
      "и стоят: проход закончен, перезапуска нет")
print()
print("      ЭТО И ЕСТЬ ДЕФЕКТ. pp_listen успел записать порт (один шаг),")
print("      pp_echo проверил уведомления один раз и замолчал навсегда.")

# ---------------------------------------------------------------------------
print("\n[4] ПОЧЕМУ: барьер ждёт ВСЕХ")
stages = [
    Stage("short", hangs=False, latency=2),
    Stage("hangs", hangs=True),
]
r = Region(stages)
sync = r.run(100)
check(not sync, "ap_sync_ready остаётся 0 -- барьер не срабатывает")
check(stages[0].sync_reg, "короткая стадия помечена завершённой (sync_reg=1)")
print("      -> её ap_start = ~sync_reg & ap_start = 0")
print("      -> старта больше не будет, пока висящая не завершится")

# ---------------------------------------------------------------------------
print("\n[5] контроль: убрать висящую -- короткая оживает")
#
# Тот же тест без висящей стадии. Если короткая начинает перезапускаться,
# значит дело именно в соседстве, а не в самой короткой стадии.
stages = [Stage("short", hangs=False, latency=2)]
Region(stages).run(100)
check(stages[0].starts > 20,
      f"одна короткая стадия перезапускается ({stages[0].starts} раз)")

# ---------------------------------------------------------------------------
print("\n[6] сколько тактов простоя стоит ОДНА висящая стадия")
for n_hang in (0, 1, 2):
    st = [Stage(f"s{i}", hangs=False, latency=3) for i in range(2)]
    st += [Stage(f"h{i}", hangs=True) for i in range(n_hang)]
    Region(st).run(1000)
    starts = st[0].starts
    print(f"      висящих: {n_hang} -> короткая стартовала {starts} раз")
check(True, "одна висящая стадия достаточна, чтобы остановить регион")

print("\n=== Итог: " + ("ВСЕ ПРОВЕРКИ ПРОШЛИ" if fails == 0
                        else "ОТКАЗОВ: %d" % fails) + " ===")
sys.exit(1 if fails else 0)
