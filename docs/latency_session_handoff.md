# Передача контекста: latency-эксперимент после перехода на HDL-обёртку

Файл для нового диалога. Описывает, что изменилось 2026-08-12, почему это
напрямую касается ядра измерения задержки, и что делать дальше.

Предыдущий контекст (цель эксперимента, схема стенда, точки измерения) —
[latency_experiment_context.md](latency_experiment_context.md) и
[latency_experiment_windows.md](latency_experiment_windows.md). Они всё ещё
верны по сути эксперимента, но **устарели в части управления ядром** — см.
ниже.

---

## Главное, что нужно знать

**Найден и исправлен баг, из-за которого хост не мог управлять
free-running HLS-ядром.** Он стоил двух-трёх сессий на плате, и он же
присутствует в `hls_echo_probe_dual_krnl` — ядре, которым планируется мерить
задержку. То есть **до эксперимента ядро измерения нужно починить тем же
способом**, иначе `triggerGo` не дойдёт до логики и замеров не будет.

### Суть бага

Ядро объявлено `ap_ctrl_none` (free-running) и одновременно имеет
`#pragma HLS INTERFACE s_axilite` на скалярах. UG1393
([Free-Running Kernels](https://docs.amd.com/r/2022.2-English/ug1393-vitis-application-acceleration/Free-Running-Kernels))
это прямо запрещает: «The kernel interface should not have any `#pragma HLS
interface s_axilite`».

**HLS не выдаёт ошибку.** Он молча защёлкивает входные скаляры один раз, в
`state2` автомата верхнего модуля — то есть сразу после снятия сброса, когда
хост по JTAG ещё ничего не записал:

```verilog
always @ (posedge ap_clk)
    if ((1'b1 == ap_CS_fsm_state2))
        enable_read_reg_738 <= enable;      // защёлка, а не провод
```

Симптом на плате: регистр читается обратно верно (`enable=1`), а логика видит
`0`. Наблюдалось как `portState=0`, `listenAttempts=0` при успешной записи —
то есть «ядро не реагирует» без единого признака причины.

Диагностический признак: **входные** регистры (`listenPortA/B`) читаются
обратно правильно, потому что их читает AXI, минуя логику. А **выходные**
(телеметрия) остаются нулевыми, потому что их пишет логика, которая видит
`enable=0`. Эта асимметрия — и есть отпечаток бага.

### Что НЕ помогает (проверено csynth, не догадки)

* `#pragma HLS stable` на скалярах — pragma принимается молча, защёлка
  остаётся. `stable` снимает синхронизацию МЕЖДУ процессами dataflow, а не
  защёлкивание аргумента на входе региона.
* Убрать `DATAFLOW` из вызывающей функции — автомат создаёт сама топ-функция.
* **Перейти на `ap_ctrl_hs`** — соблазнительно (появляется `ap_start`, скаляры
  защёлкиваются по фронту), но неверно. Стадии в этих ядрах — тела функций БЕЗ
  цикла, за один проход. При `ap_ctrl_hs` один `ap_start` = один проход, и
  непрерывность получается только через `auto_restart`, то есть на каденции
  перезапусков вместо `II=1`. Тогда счётчики таймаутов тикают раз на
  перезапуск, а не раз на такт, и приём не успевает за 100G.
  `network_krnl` с `ap_ctrl_hs` — **не образец**: он рукописный SystemVerilog и
  подделывает `ap_done` таймером на секунду ([network_stack.sv:921](../kernel/network_krnl/src/hdl/network_stack.sv#L921)).

### Правильное решение: регистры в HDL-обёртке

Образец — апстримный `iperf_krnl`, работающий на этом железе:
HLS-функция `ap_ctrl_none` без единого `s_axilite`
([iperf_client.cpp:546](../kernel/user_krnl/iperf_krnl/src/hls/iperf_client.cpp#L546)),
скаляры приходят проводами, регистры держит
[iperf_role.sv:369](../kernel/user_krnl/iperf_krnl/src/hdl/iperf_role.sv#L369).
При этом `iperf_krnl.xml` заявляет `hwControlProtocol="ap_ctrl_hs"` —
противоречия нет: `ap_ctrl_hs` реализует обёртка, а логика внутри свободно
течёт с `II=1`.

---

## Что сделано для hls_dual_echo_krnl (готовый образец)

Всё закоммичено, рабочее дерево чистое. Ядро прошло `csynth`, упаковку и BD;
имплементация запущена.

### Новые файлы

| Файл | Что делает |
|---|---|
| [dual_echo_control_s_axi.v](../kernel/user_krnl/hls_dual_echo_krnl/src/hdl/dual_echo_control_s_axi.v) | Регистры AXI4-Lite. Адресная карта задана явно в `localparam` — **это источник истины**, из него скопированы `DE_OFF_*` в `jtag_ctrl.tcl`. AXI-машины скопированы дословно из сгенерированного HLS `iperf_role_control_s_axi.v`. Добавлен путь ЧТЕНИЯ телеметрии — у апстрима только запись. |
| [hls_dual_echo_krnl_wrapper.sv](../kernel/user_krnl/hls_dual_echo_krnl/src/hdl/hls_dual_echo_krnl_wrapper.sv) | Инстанцирует HLS-IP + регистры, реализует `ap_ctrl_hs` наружу. Имена AXI-Stream портов сохранены дословно из `config_sp` — BD и `config_sp` править не пришлось. |
| [package_hls_dual_echo_krnl.tcl](../kernel/user_krnl/hls_dual_echo_krnl/package_hls_dual_echo_krnl.tcl) | Шаг 2.5: упаковывает обёртку + HLS-IP в один IP. |
| [test_hls_dual_echo_krnl.cpp](../kernel/user_krnl/hls_dual_echo_krnl/src/hls/tb/test_hls_dual_echo_krnl.cpp) | Нативный тестбенч, 8 сценариев. Гоняется без Vitis HLS. |

### Изменённые

* [hls_dual_echo_krnl.cpp](../kernel/user_krnl/hls_dual_echo_krnl/src/hls/hls_dual_echo_krnl.cpp)
  — `ap_ctrl_none`, ноль `s_axilite`; состояние автомата `listen` вынесено из
  `static` в структуру `listenState` (см. ниже, почему);
* [build_bd.tcl](../scripts/vivado/build_bd.tcl) — берёт обёртку, если она
  есть, и падает с подсказкой, если нужна но не собрана;
* [jtag_ctrl.tcl](../scripts/vivado/jtag_ctrl.tcl) — смещения `DE_OFF_*`
  скопированы из HDL, больше не placeholder'ы;
* [Makefile.vivado](../Makefile.vivado) — цель `pack` (шаг 2.5), встроена в
  `all`, автодетект по наличию `src/hdl/`;
* [building.md](building.md) — раздел про шаг 2.5 и «Сборка начисто».

### Второй баг, исправленный попутно

`dual_echo_listen` имела состояние в `static`, но вызывается **дважды** (по
разу на половину). Работало это лишь потому, что `INLINE off` + `DATAFLOW`
заставляют HLS создать две копии железа. Это не гарантия, а наблюдаемое
поведение инструмента: если HLS переиспользует один экземпляр, половины делят
`portRequested` и откроется РОВНО ОДИН порт. Состояние вынесено в структуру,
передаваемую по ссылке → независимость стала свойством кода.

`csynth` подтвердил: в RTL два раздельных набора регистров, `st_a_*` и
`st_b_*`.

---

## Подтверждённые факты (что проверено инструментом, а не рассуждением)

Из `csynth` на сборочном сервере (Vitis HLS 2024.1):

```
Setting interface mode on port 'hls_dual_echo_krnl/enable' to 'ap_none'
Setting interface mode on function 'hls_dual_echo_krnl' to 'ap_ctrl_none'
**** Estimated Fmax: 235.52 MHz
```

* `grep enable_read_reg ... hls_dual_echo_krnl.v` → **пусто** (защёлки нет);
* `grep -c s_axi_control ... hls_dual_echo_krnl.v` → **0**;
* `input [31:0] enable;` — провод, читается каждый такт;
* `st_a_portRequested` / `st_b_portRequested` — раздельные регистры.

Из упаковки: `все 209 портов IP сходятся с обёрткой`,
`check_integrity: Integrity check passed`.

Из BD: `Соединено: 36, пропущено: 0, ошибок: 0`;
`cmac_krnl -> cmac_krnl:1.0` и `cmac_krnl_qsfp1 -> cmac_krnl_qsfp1:1.0`
(разные VLNV → CMAC'и не сольются на один GT-квад);
адреса `network_krnl_1 → 0`, `hls_dual_echo_krnl_1 → 0x10000`,
`network_krnl_2 → 0x20000` — совпали с `jtag_ctrl.tcl`.

Из нативного теста — 8 сценариев зелёные, включая ключевой:
`enable=0` в любой момент → `portState` возвращается в 0, то есть значение
читается каждый такт, а не защёлкивается однажды.

### Чего НЕ проверено

* **Тайминг.** Имплементация была запущена, результат неизвестен. `WNS`/`WHS`
  обязаны быть положительными. Частота снижена до **165 МГц** (было 170) в
  `devices/u200/device.tcl.in`.
* **Живое железо.** Битстрим с обёрткой на плате не проверялся.
* **Физическое размещение CMAC.** Разные VLNV гарантируют разные IP, но
  `report_placement` после сборки ещё не смотрели.

---

## Что делать с ядром измерения

`hls_echo_probe_dual_krnl` — то, чем мерить задержку. Его состояние:

```
ap_ctrl_none port = return          <- строка 1119
18 x #pragma HLS INTERFACE s_axilite
нет src/hdl/                         <- обёртки НЕТ
```

**То есть у него ровно тот баг, который мы только что исправили.** Его
`triggerGo` (по фронту которого отправляется пакет) не дойдёт до логики, и
`sampleReady` никогда не поднимется. При `ap_ctrl_none` защёлка происходит
один раз после сброса — а `triggerGo` по замыслу должен меняться многократно,
на каждый замер.

### План

1. **Дождаться результата имплементации `hls_dual_echo_krnl`** и проверить
   `WNS`/`WHS`. Если отрицательный — снижать `DEV_FREQ_MHZ` и повторять с
   шага 2; на плату отрицательный WNS не грузить (Vivado, в отличие от `v++`,
   частоту сам не снижает и отдаёт битстрим с нарушенным таймингом, который
   работает нестабильно).
2. **Проверить dual_echo на плате** — это подтверждает механику обёртки на
   живом железе, прежде чем тиражировать её на ядро измерения. Порядок:

   ```
   echo_bringup_dual <ip1> <mac1> <ip2> <mac2>
   dual_echo_configure 7001 7002
   dual_echo_enable 1
   dual_echo_status          ; # ждём state=2(OPEN) на ОБЕИХ половинах
   ```

   Затем `ncat <ip1> 7001` и `ncat <ip2> 7002` — оба подключаются и держатся
   независимо. Оба кабеля должны быть воткнуты (в прошлый раз на QSFP1 кабеля
   не было, и нулевой приём был именно из-за этого).
3. **Сделать обёртку для `hls_echo_probe_dual_krnl`** по образцу
   `hls_dual_echo_krnl`: убрать все 18 `s_axilite`, оставить скаляры
   аргументами, написать `probe_control_s_axi.v` + `..._wrapper.sv` +
   `package_hls_echo_probe_dual_krnl.tcl`. Обёртка копируется и правится под
   его набор параметров (`serverIp`, `serverPort`, `listenPort`, `msgBytes`,
   `triggerGo`, плюс телеметрия и 4 таймстемпа), а не пишется с нуля.
   Автодетект в `Makefile.vivado` подхватит `src/hdl/` сам.
4. Прогнать нативный тест для probe-ядра (у него уже есть
   `tb/test_hls_echo_probe_dual_krnl.cpp`) — до сборки, чтобы не тратить
   попытку на плате.

---

## Ловушки, стоившие времени (чтобы не наступить снова)

**VIO-пробы MAC обманывают.** `mie_mac_address` объявлен `[47:0]`, а проба в
`vio_network` — 32-битная ([network_stack.tcl:239](../kernel/network_krnl/network_stack.tcl#L239)).
VIO показывает биты `[47:16]` и **байты в обратном порядке**. Записанный
`000a35029de5` выглядит как `02350a00`. Проверяется на IP, где ответ известен:
записали `c0a80a0a`, VIO показал `0a0aa8c0` — те же байты наоборот.

**`tcp_tx_pkg_counter` — не отправка в сеть.** Он считает внутренний интерфейс
TOE (`axis_toe_to_toe_slice`,
[network_stack.sv:1140](../kernel/network_krnl/src/hdl/network_stack.sv#L1140)),
до merge и CMAC. Реально ушедшее в провод — `tx_pkg_counter`. Сверять надо
так: `tx_pkg_counter ≈ arp_tx + icmp_tx + tcp_tx + udp_tx`. В наблюдённом
дампе `tx=94`, а `arp+icmp=95` при `tcp_tx=84` — то есть TCP до провода не
дошёл. Одинаковый `tcp_tx=0x54` на исправном канале и на канале с
невоткнутым кабелем — сам по себе признак, что счётчик не про провод.

**Смещения регистров при `s_axilite` в HLS нельзя вычислить по порядку
аргументов** — HLS вставляет `ap_vld`-регистр после каждого выходного
значения, поэтому шаг у входов 8 байт, а у выходов 16. Их надо брать из
`*_hw.h`, который печатает `export_hls_ip.tcl`. **С обёрткой этой проблемы
нет** — карта задана руками в `localparam`.

**`synth_design -rtl` не проверяет обёртку.** В режиме elaborate-only Vivado
не разворачивает IP из `.xci`, и модуль всегда «not found» независимо от
корректности. Апстримный `package_iperf_krnl.tcl` синтез не гоняет вовсе.
Вместо этого в нашем скрипте сверяются списки портов из `component.xml` и из
инстанса в обёртке.

**Имя обёртки должно отличаться от имени HLS-IP.** Иначе
`ipx::check_integrity` падает: `IP_Flow 19-907 Component circularly references
subcore`. Переименования внутреннего модуля через `create_ip -module_name`
недостаточно — конфликтует VLNV ядра. Обёртка пакуется как `${KRNL}_wrapper`.

**Сырое HLS-IP нужно оставить в `ip_repo_paths`.** Обёртка ссылается на него
как на subcore, а не содержит копию. Без него BD собирается и соединяет все
интерфейсы, но генерация IP падает: `IP_Flow 19-4065 subcore dependency not
available`. Единственный ранний признак — `IP_Flow 19-3571 IP is restricted`
на шаге 3, легко пропустить среди прочих предупреждений.

---

## Порядок сборки (актуальный)

Пять шагов вместо четырёх — добавился `pack`:

```bash
make -f Makefile.vivado all USER_KRNL=hls_dual_echo_krnl BOARD=u200
```

или по шагам: `xo` → `user_ip` → `pack` → `bd` → `impl`. `pack` сам
пропускается для ядер без `src/hdl/`.

Контрольные точки по шагам и раздел «Сборка начисто» — в
[building.md](building.md).

Нативный тест (обязательно перед каждой прошивкой, доступ к плате ограничен):

```bash
g++ -std=c++14 -I kernel/common/csim_shim -I kernel/common/include kernel/user_krnl/hls_dual_echo_krnl/src/hls/hls_dual_echo_krnl.cpp kernel/user_krnl/hls_dual_echo_krnl/src/hls/tb/test_hls_dual_echo_krnl.cpp -o /tmp/test_dual_echo && /tmp/test_dual_echo
```

---

## Адресная карта dual_echo (для справки)

Источник истины — `localparam` в `dual_echo_control_s_axi.v`.

| Смещение | Регистр | Доступ |
|---|---|---|
| `0x00` | `ap_ctrl` (bit0=ap_start, bit1=ap_done, bit7=auto_restart) | RW |
| `0x10` | `enable` — то, что реально разрешает работу | RW |
| `0x18` | `listenPortA` | RW |
| `0x20` | `listenPortB` | RW |
| `0x30` / `0x34` / `0x38` | `listenAttempts_a` / `portState_a` / `notifyCount_a` | RO |
| `0x40` / `0x44` / `0x48` | `listenAttempts_b` / `portState_b` / `notifyCount_b` | RO |

`portState`: 0 = ждём enable, 1 = запрос отправлен, 2 = порт открыт.

Работу разрешает **`enable`**, не `ap_start`. Ядро внутри `ap_ctrl_none` и
работает с момента снятия сброса; `ap_start` пишется только ради блочного
протокола, который ждёт BD, и как программный сброс счётчиков.
