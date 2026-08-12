# Сборка: два флоу

В репозитории **два независимых способа** получить прошивку. Они пересекаются
только на первом шаге (HLS-IP сетевого стека), дальше расходятся полностью.

|                               | Vitis/XRT                | Vivado                        |
|-------------------------------|--------------------------|-------------------------------|
| Результат                     | `.xclbin`                | `.bit`                        |
| Нужен XRT-шелл на плате       | **да**                   | нет                           |
| Загрузка                      | `xbutil` / OpenCL-хост   | JTAG из Vivado                |
| Управление ядрами             | OpenCL-хост (`host.cpp`) | JTAG-to-AXI (`jtag_ctrl.tcl`) |
| Смена платы                   | параметр `-DFDEV_NAME`   | правка `build_bd.tcl` + XDC   |
| Частота при недоборе тайминга | v++ снижает сам          | остаётся отрицательный WNS    |

**Vivado-флоу существует потому, что на нашей плате нет XRT-шелла** — в flash
записана заводская прошивка, которую мы не трогаем. См.
[bringup_windows.md](bringup_windows.md).

---

## Шаг 0 (общий): HLS-IP сетевого стека

Оба флоу требуют, чтобы TCP/IP-стек был собран из HLS в IP-каталог. Это делает
**cmake**, а не make.

### 0.1. Окружение

В каждой новой сессии, до всего остального:

```bash
source /opt/xilinx/xrt/setup.sh
source /opt/Xilinx/Vitis/2024.1/settings64.sh
export PATH=/usr/bin:$PATH
export XILINXD_LICENSE_FILE=$HOME/.Xilinx
```

Порядок строк имеет значение:

**`export PATH=/usr/bin:$PATH` — после `settings64.sh`, не до.** `settings64.sh`
ставит свои `cmake`, `gcc` и прочее в начало PATH, и ксайлинксовский `cmake`
слинкован с `libidn.so.11`, которой в Ubuntu 22.04 нет:

```
cmake: error while loading shared libraries: libidn.so.11:
cannot open shared object file
```

Строка с `/usr/bin` возвращает системные утилиты вперёд, а `vivado` и
`vitis_hls` остаются доступны — они лежат в других каталогах PATH и не
конфликтуют. Проверить, что сработало: `which cmake` должен дать
`/usr/bin/cmake`.

**`XILINXD_LICENSE_FILE`** нужен для CMAC IP — это лицензируемое ядро, без
лицензии `build_bd.tcl` упадёт уже на генерации BD, но только на шаге 3, а не
здесь.

**`xrt/setup.sh`** для Vivado-флоу формально не нужен (XRT мы не используем), но
он безвреден и держит окружение одинаковым для обоих флоу.

### 0.2. cmake

```bash
mkdir -p build && cd build
cmake .. -DFDEV_NAME=u200 -DTCP_STACK_EN=1
cd ..
```

Быстро, секунды. Что делает:

**Готовит цель `ip`** — её в Makefile в корне нет вовсе. Она генерируется
cmake'ом в [FindVitis.cmake:445](../fpga-network-stack/xilinx-cmake/FindVitis.cmake#L445)
и агрегирует `ip.toe`, `ip.ip_handler`, `ip.mac_ip_encode`, `ip.arp_server_subnet`,
`ip.icmp_server`, `ip.ipv4`, `ip.udp`, `ip.hash_table`,
`ip.ethernet_frame_padding`.

**Генерирует пять файлов из шаблонов** (`configure_file` в
[CMakeLists.txt:82-85](../CMakeLists.txt#L82) и блок ниже):

| Генерируется                             | Из шаблона  | Кто использует               |
|------------------------------------------|-------------|------------------------------|
| `scripts/network_krnl_mem.txt`            | `.txt.in`   | v++ (`sp=` для банка памяти) |
| `scripts/cmac_krnl_slr.txt`               | `.txt.in`   | v++ (`slr=` для CMAC)        |
| `scripts/post_sys_link.tcl`               | `.tcl.in`   | v++ (пины, refclk)           |
| `kernel/common/types/network_types.svh`   | `.svh.in`   | **оба флоу** — RTL стека     |
| `build/devices/<плата>/device.tcl`        | `.tcl.in`   | Vivado-флоу, шаги 2 и 3      |

Последние два — причина, по которой Vivado-флоу тоже требует прогона cmake:
без `network_types.svh` не соберётся RTL стека, без `device.tcl` упадут с
подсказкой `export_hls_ip.tcl` и `build_bd.tcl`.

**`-DTCP_STACK_EN=1` обязателен.** По умолчанию в
[CMakeLists.txt:53](../CMakeLists.txt#L53) стоит `TCP_STACK_EN 0`, а
`UDP_STACK_EN 1` — без флага соберётся только UDP, и TCP-дизайн потом молча не
заработает. Проверить, что флаг подхватился, можно позже в логе `make ip`: у
`toe` в `add_files` должно быть `-DTCP_NODELAY=1 -DTCP_MSS=4096
-DTCP_STACK_MAX_SESSIONS=1000 -DRX_DDR_BYPASS=1 -DFAST_RETRANSMIT=1
-DWINDOW_SCALE=1`.

Проверить, что `device.tcl` сгенерировался:

```bash
grep -vE "^\s*#|^\s*$" build/devices/u200/device.tcl
```

Должно быть 13 переменных `DEV_*`, включая `DEV_PART "xcu200-fsgd2104-2-e"` и
`DEV_CMAC_SLR "SLR2"` — эти две cmake подставляет из блока `FDEV_NAME`, поэтому
их правильность заодно подтверждает, что `-DFDEV_NAME` сработал.

### 0.3. make ip

```bash
cd build && make ip
```

**~8 минут** с нуля (замерено: 09:29:30 → 09:37:09 на 8 vCPU). Прогоняет
`vitis_hls` (csynth + export_design) для девяти модулей стека и двух user-ядер
(`iperf_client`, `scatter`).

Больше половины времени уходит на два модуля: `toe` — 1:45 на csynth плюс 0:42
на export (он один даёт 178 verilog- и 156 vhdl-файлов), и `hash_table` — 1:01
на export из-за полностью развёрнутых таблиц табуляционного хеша (1016 verilog-
файлов). Остальные девять — по 5–20 секунд каждый.

Держать ssh необязательно, но и не мешает:

```bash
cd ~/easynet/build && nohup make ip > ~/make_ip.log 2>&1 &
tail -f ~/make_ip.log
```

**Результат:** `build/ip_repo/` — на него потом ссылаются оба флоу.

Проверить:

```bash
ls build/ip_repo/ && grep -icE "^ERROR" ~/make_ip.log
```

Ждём девять `.zip` + распакованные каталоги и `0` ошибок. В конце лога должно
быть `[100%] Built target ip`.

#### Что в логе можно игнорировать

Их много, и все они штатные для этого стека:

| Сообщение                                       | Почему нормально                                                        |
|-------------------------------------------------|-------------------------------------------------------------------------|
| `HLS 200-656` deadlocks can occur               | Все модули стека — `ap_ctrl_none`, это архитектура fpga-network-stack    |
| `RTGEN 206-101` power-on initialization         | Статические переменные в HLS; на FPGA инициализируются битстримом        |
| `HLS 214-52` false inter dependency             | Анализатор не видит, что обращения к таблице не пересекаются             |
| `HLS 200-657` channel flows backwards           | Обратные связи в dataflow-регионе, так стек и устроен                    |
| `HLS 200-1020/1018` increasing depth of FIFO    | HLS сам увеличивает глубину, это информационное                          |
| `HLS 200-2053` vitis_hls is deprecated          | 2024.1 предлагает `vitis-run`; работает и так                            |
| `SYN 201-103` legalizing function name           | Шаблонные имена вида `toe<512>` в HDL                                   |

#### На что смотреть: Fmax

В конце каждого модуля есть строка `Estimated Fmax`. На последней сборке:

| модуль                 | Fmax  |
|------------------------|-------|
| ip_handler             | 137.2 |
| mac_ip_encode          | 137.2 |
| **toe**                | 137.2 |
| ethernet_frame_padding | 137.3 |
| hash_table             | 141.8 |
| ipv4_top               | 206.4 |
| icmp_server            | 210.5 |
| dhcp_client            | 263.0 |
| udp_top                | 317.6 |
| arp_server_subnet      | 331.4 |

Три модуля упираются в ~137 МГц, и это **не блокер**: HLS синтезирует их под
период 10 нс и не видит retiming, который потом делает Vivado. Проверенная
сборка закрылась на 170 МГц с WNS +0.1226. Но это объясняет, почему заявленные
в Makefile 200 МГц никогда не достигались.

#### Когда нужен rerun

| Что изменилось                              | Что перезапускать                     |
|---------------------------------------------|---------------------------------------|
| `-DFDEV_NAME` (другая плата)                | `cmake` + **`make ip`** целиком       |
| `-DTCP_STACK_EN` / параметры стека          | `cmake` + **`make ip`** целиком       |
| `.cpp`/`.hpp` в `fpga-network-stack/hls/`   | `make ip` (пересоберёт только своё)   |
| `devices/*/device.tcl.in`                   | только `cmake`                        |
| `devices/*/pins.xdc`                        | ничего — читается на шаге 3 напрямую  |
| user-ядро `hls_*_krnl`                      | ничего — оно идёт через шаг 2         |

Смена платы и параметров стека требуют полного `make ip`, потому что part и
`-D`-флаги входят в командную строку `vitis_hls` для каждого модуля — cmake
перегенерирует `*_synthesis.tcl`, и все девять модулей становятся stale.

Правки в HLS-исходниках стека — дешевле: make отслеживает зависимости и трогает
только затронутые модули. Один `toe` — около двух минут.

`cmake` можно перезапускать в том же `build/` — он не требует чистого каталога.
Полный снос (`rm -rf build`) нужен только если что-то разъехалось необъяснимо;
цена — снова ~8 минут.

### Параметры платы

`-DFDEV_NAME` выбирает один из блоков в [CMakeLists.txt:11-46](../CMakeLists.txt#L11).
Поддерживаются `u200`, `u280`, `u250`, `u50`, `u55c`. Каждый задаёт part,
платформу, банк памяти для стека и SLR для CMAC:

| FDEV_NAME | part                 | память стека | CMAC SLR |
|-----------|----------------------|--------------|----------|
| u200      | xcu200-fsgd2104-2-e  | `DDR[3]`     | SLR2     |
| u280      | xcu280-fsvh2892-2L-e | `HBM[15]`    | SLR2     |
| u250      | xcu250-figd2104-2L-e | `DDR[2]`     | SLR2     |
| u50       | xcu50-fsvh2104-2-e   | `HBM[15]`    | SLR1     |
| u55c      | xcu55c-fsvh2892-2L-e | `HBM[15]`    | SLR1     |

Прочие полезные параметры стека (дефолты из CMakeLists):
`-DFNS_TCP_STACK_MAX_SESSIONS=1000`, `-DFNS_TCP_STACK_MSS=4096`,
`-DFNS_TCP_STACK_RX_DDR_BYPASS_EN=1`, `-DFNS_TCP_STACK_WINDOW_SCALING_EN=1`.

---

## Флоу A: Vitis/XRT → `.xclbin`

Требует XRT-шелл на плате. **На нашей U200 не применим**, оставлен как
референс и для машин с шеллом.

```bash
# 0. шаг выше (cmake + make ip)

# 1. RTL-ядра в .xo
make cmac_krnl    DEVICE=<путь к .xpfm>
make network_krnl DEVICE=<путь к .xpfm>

# 2. всё вместе: user-ядро, линковка, хост
make all TARGET=hw DEVICE=<путь к .xpfm> \
         USER_KRNL=hls_ouch_krnl USER_KRNL_MODE=hls
```

`DEVICE` — полный путь к `.xpfm`, например
`/opt/xilinx/platforms/xilinx_u200_gen3x16_xdma_2_202110_1/xilinx_u200_gen3x16_xdma_2_202110_1.xpfm`.
Он должен соответствовать `-DFDEV_NAME` из шага 0.

`USER_KRNL_MODE`: `rtl` для `iperf_krnl`/`scatter_krnl`, `hls` для `hls_*_krnl`.
Определяет, какой `config_*.mk` подключится
([Makefile:61](../Makefile#L61)).

**Результат:** `build_dir.hw.<xsa>/network.xclbin` и `host/host`.

### Замечания

- **Заявленная частота 200 МГц не достигается.** В
  [Makefile:88](../Makefile#L88) стоит `--kernel_frequency 200`, но v++ при
  недоборе тайминга снижает её сам и пишет в лог
  `frequency is being automatically changed to 192.9 MHz`. То есть рабочая
  XRT-сборка шла на 192.9 МГц.
- **`NETH` в README проекта не существует.** Строка
  `make all ... NETH=4` в [README.md:75](../README.md#L75) — единственное
  упоминание во всём репозитории; в коде параметра нет и никогда не было
  (проверено `git log -S`). Многопортовость не реализована.

---

## Флоу B: Vivado → `.bit`

Это то, чем мы пользуемся. После шага 0 — ещё **пять** шагов, строго по
порядку: шаг 3 собирает BD из того, что положили шаги 1, 2 и 2.5, и падает,
если чего-то нет.

Обёрнуто в [Makefile.vivado](../Makefile.vivado):

```bash
make -f Makefile.vivado list                                     # что есть и что собрано
make -f Makefile.vivado all USER_KRNL=hls_echo_krnl BOARD=u200   # шаги 1-4
```

или по шагам:

```bash
make -f Makefile.vivado xo      BOARD=u200                            # ~1 мин
make -f Makefile.vivado user_ip USER_KRNL=hls_echo_krnl BOARD=u200    # ~20 сек
make -f Makefile.vivado pack    USER_KRNL=hls_echo_krnl BOARD=u200    # ~1 мин
make -f Makefile.vivado bd      USER_KRNL=hls_echo_krnl BOARD=u200    # ~25 сек
make -f Makefile.vivado impl    USER_KRNL=hls_echo_krnl BOARD=u200    # ~1 час
```

### Шаг 2.5 (`pack`): зачем он и каким ядрам нужен

**Ядру с параметрами от хоста нужна HDL-обёртка.** Причина не в удобстве, а в
запрете: free-running ядро (`ap_ctrl_none`) **не может** иметь `s_axilite` —
UG1393 ([Free-Running Kernels](https://docs.amd.com/r/2022.2-English/ug1393-vitis-application-acceleration/Free-Running-Kernels))
пишет прямо: «The kernel interface should not have any `#pragma HLS interface
s_axilite`».

Опасность в том, что **HLS не выдаёт ошибку**. Он молча защёлкивает входные
скаляры один раз, в `state2` автомата верхнего модуля — то есть сразу после
снятия сброса, когда хост по JTAG ещё ничего не записал:

```verilog
always @ (posedge ap_clk)
    if ((1'b1 == ap_CS_fsm_state2))
        enable_read_reg_738 <= enable;      // защёлка, а не провод
```

Симптом на плате: `enable` в регистре читается `1`, а логика видит `0` —
`portState=0`, `listenAttempts=0`, порт слушания не открывается. На это ушло
две сессии с платой.

Лечение — то же, что в апстримном `iperf_krnl`: регистры держит HDL, а в
HLS-ядро значения приходят **проводами**, видимыми каждый такт.

| | HLS-ядро | Регистры | Шаг `pack` |
|---|---|---|---|
| `hls_dual_echo_krnl` | `ap_ctrl_none`, без `s_axilite` | `src/hdl/dual_echo_control_s_axi.v` | **нужен** |
| `hls_echo_krnl` | `ap_ctrl_none`, порт зашит константой | нет | пропускается |

**Признак — наличие `src/hdl/` у ядра.** `make` определяет это сам, поэтому
`all` работает одинаково для обоих типов, а `pack` для ядра без обёртки просто
печатает, что пропущен. Проверка автоматическая, а не по списку имён: со
списком новое ядро молча собралось бы без обёртки, и симптом выглядел бы как баг
в HLS, а не как пропущенный шаг.

Если обёртка есть, а `pack` не прогнан, **шаг 3 падает сразу** с указанием, что
делать — раньше в BD ушло бы сырое HLS-IP без регистров, и это выяснилось бы
только на плате.

Результат: `kernel/user_krnl/<krnl>/build_pack/packaged/`. Внутри — обёртка
вместе с HLS-IP, поэтому в `ip_repo_paths` попадает **только** она: два IP с
одним именем дали бы неоднозначность, на которой `_find_ipdef` в
`build_bd.tcl` падает намеренно.

Скрипт упаковки прогоняет `synth_design -rtl` — несовпадение имён портов между
обёрткой и HLS-IP всплывает там за минуту, а не через час на синтезе BD.

**`USER_KRNL` и `BOARD` обязательны везде, дефолтов нет.** Это осознанно: с
дефолтом забытый параметр собирал бы не то ядро молча, а следом шла бы часовая
имплементация. Без параметра make печатает список доступных ядер и плат.

Артефакты — в `build/vivado/<плата>/<ядро>/`, то есть сборки под разные платы и
ядра не затирают друг друга. `.bit` жёстко привязан к part, а HLS-IP ядра ещё и
к периоду, поэтому разделение по обоим.

То же вручную, если нужно:

```bash
# 1. RTL-ядра: cmac_krnl и network_krnl → packaged_kernel_*
make cmac_krnl    DEVICE=<путь к .xpfm>
make network_krnl DEVICE=<путь к .xpfm>

# 2. user-ядро из HLS в IP-каталог (не .xo!)
USER_KRNL=hls_echo_krnl BOARD=u200 vitis_hls -f scripts/vivado/export_hls_ip.tcl

# 2.5. ТОЛЬКО для ядра с src/hdl/ — упаковать HLS-IP в HDL-обёртку
vivado -mode batch \
     -source kernel/user_krnl/hls_dual_echo_krnl/package_hls_dual_echo_krnl.tcl \
     -tclargs u200

# 3. блок-дизайн
vivado -mode batch -source scripts/vivado/build_bd.tcl -tclargs hls_echo_krnl u200

# 4. имплементация — см. ниже, скрипт генерируется из путей проекта
```

Все скрипты читают `build/devices/<плата>/device.tcl` и падают с подсказкой,
если его нет (то есть если шаг 0 не прогнан).

**Инкрементальности в `Makefile.vivado` нет.** Каждая цель делает работу всегда.
Три из четырёх шагов — меньше минуты, а отслеживать устаревание каталогов
(`packaged_kernel_*`, `*_ip_proj`) make не умеет: пришлось бы вводить
stamp-файлы, которые легко разъезжаются с реальностью. Врущая инкрементальность
хуже её отсутствия, когда ошибка стоит час.

**Как выглядит нарушение порядка.** Если запустить шаг 3, пропустив 1 и 2, он
упадёт через 4 секунды, и по логу это видно сразу — в блоке `IP repos:` будет
один путь вместо трёх:

```
IP repos:
  /home/ubuntu/easynet/build/ip_repo        ← только стек
...
IP 'cmac_krnl' не найден (искал: cmac_krnl). Собран ли он?
```

Ожидаются три: `packaged_kernel_*` (шаг 1), `build/ip_repo` (шаг 0),
`<krnl>_ip_proj/.../impl/ip` (шаг 2).

### Про шаг 1

**Требует `DEVICE=<путь к .xpfm>` — то есть установленную XRT-платформу.** Это
выглядит противоречием с таблицей вверху («Нужен XRT-шелл на плате: нет»), но
противоречия нет: платформа нужна на **машине сборки**, для `package_xo`. На
плате шелл не нужен — прошивка грузится по JTAG.

```bash
ls -d /opt/xilinx/platforms/*/          # найти свою
```

По ~25 секунд каждое. `.xo` при этом нам не нужен вовсе: Vivado-флоу берёт
`packaged_kernel_<krnl>_hw_<xsa>/` — каталог IP, который `package_xo` создаёт
попутно. Сам `.xo` в `_x.hw.<xsa>/` остаётся неиспользованным.

Что должно быть в логе `cmac_krnl`:

```
Generating IPI for u200 cmac_usplus_axis with GT clock running at 156250000 Hz
```

Это подтверждает, что CMAC инстанцирован под нужную плату с refclk 156.25 МГц.

Что должно быть в логе `network_krnl` — блок `Inferred bus interface` на 18
TCP/UDP-стримов плюс `m00_axi`, `m01_axi`, `s_axi_control`. По этим именам шаг 3
потом соединяет BD из `config_sp_*.txt`, так что их отсутствие означало бы
проблему на шаге 3, а не здесь.

#### Что в логах шага 1 можно игнорировать

Их сотни, и это нормально:

| Сообщение | Почему нормально |
|---|---|
| `Vivado 12-3523` attempt to change 'Component_Name' from 'X' to 'X' | Имя уже такое; скрипты упаковки задают его повторно |
| `IP_Flow 19-3833` unreferenced file is not packaged | В проекте больше IP, чем использует топ-модуль (ILA, RoCE-фифо) |
| `IP_Flow 19-3158` FREQ_HZ missing / `19-11770` no FREQ_HZ | Частота приходит из BD на шаге 3, а не из упаковки |
| `Vivado 12-12407` VLNV in kernel.xml does not match | `ethz.ch:kernel:...` в xml против `xilinx.com:RTLKernel:...` в IP. Для v++ важно, для нас нет: `build_bd.tcl` ищет по имени, не по полному VLNV |
| `Vivado 12-4404` CPU emulation flow requires C-model | `sw_emu` мы не гоняем |
| `IP_Flow 19-3569` dhcp_client:1.05 not found, using 1.5 | Версия в `package_network_krnl.tcl` разошлась с тем, что экспортировал HLS; Vivado подставляет сам |
| `IP_Flow 19-3507` axis_interconnect:1.1 is not the latest | Стек использует 1.1 осознанно |
| `IP_Flow 19-5101` SystemVerilog top is not fully supported | Топ-модули ядер на SV |

### Про шаг 2

Имя ядра передаётся **переменной окружения**, не `-tclargs`: `vitis_hls` кладёт
в `$argv` всё, включая `-f` и путь к скрипту, поэтому `[lindex $argv 0]` даёт
`-f`. У `vivado` поведение другое — там `-tclargs` работает нормально, что видно
по шагу 3.

`USER_KRNL` опускать нельзя: дефолт — `hls_ouch_krnl`, а не то ядро, которое
собирали в прошлый раз.

Первая содержательная строка должна подтвердить, что `device.tcl` подхватился:

```
плата: u200 (xcu200-fsgd2104-2-e), период 5.882 нс (170.000 МГц)
```

Скрипт печатает в конце **смещения регистров** из `*_hw.h`. Это относится
только к ядрам, которые держат `s_axilite` в самом HLS (`hls_ouch_krnl`,
`hls_echo_probe_dual_krnl`): у них смещения назначает HLS, порядок аргументов в
C++ адреса не задаёт, и значения надо переносить в `USR_OFF_*` в
[jtag_ctrl.tcl](../scripts/vivado/jtag_ctrl.tcl). Без правки запись через JTAG
уйдёт не туда — молча, без ошибки.

**У ядра с HDL-обёрткой это не так, и гадать больше не нужно.** Адресную карту
задаёт `src/hdl/*_control_s_axi.v` в блоке `localparam` — она и есть источник
истины, а `DE_OFF_*` в `jtag_ctrl.tcl` скопированы из неё. Ровно поэтому
обёртка удобнее ещё и в отладке: раньше смещения в скрипте стояли
placeholder'ами с пометкой «must be replaced» и ни с чем не сверялись.

Результат: `kernel/user_krnl/<krnl>/src/hls/<krnl>_ip_proj/sol1/impl/ip`.

### Когда что перезапускать

Шаг 4 (имплементация) нужен всегда, если менялось что-либо из списка — он и есть
основное время.

| Что изменилось | Шаг 1 | Шаг 2 | Шаг 3 |
|---|---|---|---|
| `.cpp` user-ядра | — | **да** | **да** |
| другое user-ядро (`USER_KRNL=`) | — | **да** | **да** |
| `.sv`/`.svh` в `kernel/network_krnl/` | **да** (network) | — | **да** |
| `kernel/cmac_krnl/*` | **да** (cmac) | — | **да** |
| `build/ip_repo` (то есть `make ip`) | **да**, оба | — | **да** |
| `devices/*/pins.xdc` | — | — | **да** |
| `devices/*/device.tcl.in` (+ `cmake`) | — | **да** | **да** |
| `DEV_FREQ_MHZ` | — | **да** | **да** |
| `config_sp_*.txt` | — | — | **да** |

`DEV_FREQ_MHZ` требует шага 2, потому что HLS синтезирует user-ядро под
конкретный период — если пересобрать только BD, ядро останется под старую
частоту.

Шаг 1 зависит от `build/ip_repo`: `network_krnl` тянет туда девять IP стека при
упаковке. То есть после `make ip` его надо пересобрать, иначе в BD попадёт
network_krnl со старым стеком.

### Про шаг 3

**`build_bd.tcl` собирает только BD и на этом останавливается** — синтез и
имплементацию он не запускает, а печатает команды для них. Это отдельный шаг 4,
см. ниже. Сам BD — 24 секунды.

Что скрипт делает и что проверять в логе:

| Этап | Что должно быть в логе |
|---|---|
| Чтение `device.tcl` | `плата: u200 (...)`, `память: ddr4_sdram_c3`, `CMAC SLR: SLR2`, `частота: 170.000 МГц` |
| board file | `board part: xilinx.com:au200:part0:1.3` |
| IP-каталоги | `IP repos:` — **четыре** пути (два `packaged_kernel_*`, `build/ip_repo`, `*_ip_proj/.../impl/ip`) |
| VLNV | три строки: `cmac_krnl -> xilinx.com:RTLKernel:...`, `network_krnl -> ...`, `<krnl> -> user:kernel:...` |
| Соединения | `Соединено: 18, пропущено: 0, ошибок: 0` |
| Управляющая шина | `ctrl_interconnect: N мастеров (user-ядро со/без s_axi_control)` |
| DDR4 | `DDR4 sys_clk: порт /C0_SYS_CLK_0, 300120048 Hz` |
| Карта адресов | `SEG_network_krnl_1_reg0  0x00000000` |

Скрипт падает с внятным сообщением на каждом из этих этапов, если что-то не
сошлось, — то есть до синтеза дело не дойдёт при неправильной конфигурации.

#### Ядро без `s_axi_control`

`build_bd.tcl` определяет это сам и подстраивает `ctrl_interconnect` — 2 мастера
вместо 3. У `hls_echo_krnl` AXI-Lite нет вовсе (порт зашит константой
`LISTEN_PORT`, см. шапку
[hls_echo_krnl.cpp](../kernel/user_krnl/hls_echo_krnl/src/hls/hls_echo_krnl.cpp)),
поэтому в конце скрипт печатает:

```
  hls_echo_krnl: без s_axi_control — управлять нечем,
               порт слушания зашит в ядре. Из jtag_ctrl.tcl нужны
               только network_configure и network_start.
```

Для такого ядра `USR_OFF_*` в `jtag_ctrl.tcl` не применяются, а на шаге 2
предупреждение «не найден `*_hw.h`» — норма, а не сбой: регистров нет, генерить
нечего.

#### Что скрипт генерирует помимо BD

`build/vivado/<плата>/<ядро>/cmac_slr.xdc` — pblock, приколачивающий `cmac_krnl_1` к
`DEV_CMAC_SLR`. Файл собирается на ходу из `device.tcl`, поэтому в
`devices/*/pins.xdc` про SLR ничего нет и быть не должно.

#### Что в логе шага 3 можно игнорировать

| Сообщение | Почему нормально |
|---|---|
| `BD 5-699` No address segments matched `/ilmb_cntlr/...`, `/microblaze_I` | Внутри DDR4 IP есть опциональный микроблейз для калибровки; мы его не используем |
| `filemgmt 56-443` ECC Algorithm string is empty | ECC у DDR4 не включён |
| `BD 5-943` Reserving offset range | Информационное, smartconnect распределяет адреса |

Ещё одна деталь из карты адресов: `SEG_ddr4_c3_C0_REG` на `0x00080000` — регистры
MIG видны с JTAG. То есть статус калибровки DDR4 читается через `hw_axi`, не
только по светодиоду.

### Шаг 4: синтез, имплементация, битстрим

Отдельно от шага 3, чтобы можно было пересобрать BD за полминуты, не запуская
час имплементации.

```bash
make -f Makefile.vivado impl USER_KRNL=hls_echo_krnl BOARD=u200 2>&1 | tee ~/impl.log
```

Tcl-скрипт для этого не лежит в `scripts/` — он генерируется в
`build/vivado/<плата>/<ядро>/impl.tcl`, потому что на треть состоит из путей к
проекту. Файлом его держать значило бы передавать `USER_KRNL` и `BOARD` дважды.

Час с лишним. Обрыв ssh убивает процесс вместе с `tee` — если сессия ненадёжная
(termux, мобильная сеть), запускать под `tmux` или через `nohup`.

**`JOBS=2` по умолчанию, больше не надо.** На 8 vCPU / 30 ГБ восемь параллельных
синтезов съедали всю память и подвешивали инстанс так, что не работал ни ssh, ни
AWS-консоль. При двух пик ~10 ГБ. Имплементация всё равно последовательная, по
времени теряется мало. Переопределяется через `JOBS=`.

**WNS обязан быть положительным.** Vivado, в отличие от v++, при недоборе
тайминга не снижает частоту, а выдаёт битстрим с нарушенным таймингом. Такой
битстрим грузится и работает нестабильно.

Проверенная сборка (`hls_ouch_krnl`, 170 МГц): WNS +0.1226 нс, WHS +0.0096 нс,
0 failed nets, 0 DRC. Post-route WHS был -0.377 и починился роутером в Phase 7 —
то есть промежуточные отрицательные значения по ходу лога ещё ничего не значат,
смотреть надо итог.

Критический путь — `finalize_ipv4_checksum_32` внутри `network_krnl`, то есть
HLS-логика стека, а не user-ядро. Отсюда следствие: смена user-ядра почти не
меняет тайминг. На 5 нс (200 МГц) WNS был -0.616, реальный предел ~178 МГц.

### Когда каталог проекта надо снести руками

`build_bd.tcl` вызывает `create_project -force`, так что проект перезаписывается
сам, и разные ядра больше не пересекаются — каждое в своём
`build/vivado/<плата>/<ядро>/`. Но два случая остались:

1. **Пересобран IP того же ядра** — Vivado кеширует IP в
   `<проект>.gen` и может подхватить старую версию.
2. **Остались чужие IP-репозитории.** `build_bd.tcl` подставляет в
   `ip_repo_paths` всё, что нашлось по маске
   `kernel/user_krnl/<krnl>/src/hls/*/*/impl/ip`. Если рядом с исходником лежит
   старый `*_ip_proj` от другого прогона, Vivado ругается `Duplicate IP found`.
   Мы это ловили: `ouch_ip_proj` конфликтовал с `hls_echo_krnl_ip_proj`.

Оба лечит `clean-krnl` — он убирает и проект, и HLS-каталог ядра:

```bash
make -f Makefile.vivado clean-krnl USER_KRNL=hls_echo_krnl BOARD=u200
```

### Частота задаётся в одном месте

`DEV_FREQ_MHZ` в [devices/u200/device.tcl.in](../devices/u200/device.tcl.in).
Оттуда её берут оба потребителя:

- `build_bd.tcl` → `CONFIG.CLKOUT1_REQUESTED_OUT_FREQ` у clk_wiz,
- `export_hls_ip.tcl` → `DEV_PERIOD_NS`, посчитанный как `1000/DEV_FREQ_MHZ`.

Раньше это были два независимых числа (170.000 и 5.88), которые могли
разойтись — тогда HLS синтезировал бы под одну частоту, а дизайн тактировался
другой.

Побочный эффект перехода: `1000/170 = 5.882`, а не 5.88 — на 0.002 нс строже,
чем в проверенной сборке. Влияет в сторону запаса, но это не то же число.

### Смена платы в Vivado-флоу

Всё, что зависит от платы, лежит в `devices/<плата>/`. В `build_bd.tcl` и
`export_hls_ip.tcl` захардкоженных значений платы больше нет — они читают
`build/devices/<плата>/device.tcl`, который cmake генерирует из
`devices/<плата>/device.tcl.in`.

Часть значений (part, банк памяти, SLR) cmake подставляет из блока `FDEV_NAME`
в [CMakeLists.txt](../CMakeLists.txt) — то есть реестр плат один, и Vivado-флоу
не может разъехаться с XRT-флоу.

Что нужно для новой платы:

| | |
|---|---|
| `devices/<плата>/device.tcl.in` | 13 параметров, копируется с u200 |
| `devices/<плата>/pins.xdc` | **самая трудоёмкая часть**, из `hw.xsa` платформы |
| `devices/<плата>/board_files/` | оттуда же |

Пошагово — [devices/README.md](../devices/README.md).

**HBM-платы (u280, u50, u55c) не поддержаны.** `build_bd.tcl` проверяет
`DEV_MEM_TYPE` и падает с внятной ошибкой: HBM — другой IP с другими портами,
это отдельная ветка кода, а не другое значение параметра. Из платформ с DDR4
остаются `u200` и `u250`.

---

## Что где лежит

| Каталог                                  | Кто создаёт                     | Можно ли удалять                              |
|------------------------------------------|---------------------------------|-----------------------------------------------|
| `build/`                                 | cmake                           | да, но потом заново `cmake + make ip` (~8 мин) |
| `build/ip_repo/`                         | `make ip`                       | вместе с `build/`                             |
| `build/devices/<плата>/`                 | cmake                           | вместе с `build/`                             |
| `build/vivado/<плата>/<ядро>/`           | шаг 3 (`build_bd.tcl`)          | да, `clean-krnl`                              |
| `_x.hw.<xsa>/`                           | `make cmac_krnl`/`network_krnl` | да, `.xo` пересоберутся                       |
| `packaged_kernel_*`                      | те же цели                      | да, но тогда нужен шаг 1 заново               |
| `tmp_kernel_pack_*`                      | те же цели                      | да, это временное                             |
| `build_dir.hw.<xsa>/`                    | `make all` (XRT)                | да                                            |
| `<krnl>_ip_proj/` рядом с HLS-исходником | шаг 2 (`export_hls_ip.tcl`)     | да, `clean-krnl`                              |
| `<krnl>/build_pack/`                     | шаг 2.5 (`package_<krnl>.tcl`)  | да, `clean-krnl`                              |

**Снос `build/` уносит и битстримы** — они лежат в `build/vivado/`. Это не
неудобство, а нужное поведение: после пересборки `ip_repo` прежний битстрим
собран из другого стека. Он выглядит валидным, но пользоваться им нельзя.

Убрать артефакты одной пары плата+ядро, не задевая остальные и cmake-кеш:

```bash
make -f Makefile.vivado clean-krnl USER_KRNL=hls_echo_krnl BOARD=u200
```

`make clean` убирает мелочь, `make cleanall` — плюс `build_dir*`, `_x.*`,
`packaged_kernel*`, `tmp_kernel_pack*`. **Ни один из них не трогает `build/`** —
только вручную.

### HLS-проект шага 2 пока в дереве исходников

`export_hls_ip.tcl` создаёт проект в `kernel/user_krnl/<krnl>/src/hls/<krnl>_ip_proj/`,
а не в `build/vivado/`. Причина в шапке скрипта: HLS резолвит пути к файлам
относительно каталога **проекта**, и проект в стороне давал
`Cannot find source file`.

Следствие: при смене платы проект перезаписывается молча, хотя синтезирован под
конкретный part и период. Пока это не мешает (одна плата), но перенести стоит —
тогда per-board изоляция будет полной.

---

## Проверка кода без FPGA

Тестбенч user-ядра гоняется нативно, без Vitis HLS — через шим `ap_int`/
`hls_stream` в `kernel/common/csim_shim/`. Полезно на машине, где Vivado нет
вовсе, и **обязательно перед каждой прошивкой**, если доступ к плате
ограничен.

Для `hls_dual_echo_krnl`:

```bash
g++ -std=c++14 -I kernel/common/csim_shim -I kernel/common/include kernel/user_krnl/hls_dual_echo_krnl/src/hls/hls_dual_echo_krnl.cpp kernel/user_krnl/hls_dual_echo_krnl/src/hls/tb/test_hls_dual_echo_krnl.cpp -o /tmp/test_dual_echo && /tmp/test_dual_echo
```

Ожидается `=== ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ ===`. Восемь сценариев: порядок bringup
(до `enable` стек не трогается), раздельные номера портов на половинах,
независимость половин, повтор запроса по отказу и по таймауту, приём данных,
и `enable=0` в любой момент.

Последний сценарий — прямая проверка того самого бага: он подтверждает, что
`enable` читается **каждый такт**, а не защёлкивается один раз.

Чего этот тест **не** проверяет: тайминг, упаковку IP, разводку BD. Для них
нужен Vivado.

> В `communication.hpp` функции объявлены без `inline`, поэтому подключать его и
> в ядро, и в тестбенч нельзя — будет duplicate symbol при линковке. Тестбенчу
> нужны только типы `pkt*`, и он объявляет их локально.

---

## Сборка начисто

После смены фазы работы (например, переход ядра на HDL-обёртку) надёжнее
собрать с нуля: старые `packaged_*` и `build_pack/` дают дубликаты IP, на
которых `build_bd.tcl` падает — или, хуже, собирается не из того, что вы
думаете.

```bash
make -f Makefile.vivado clean-krnl USER_KRNL=hls_dual_echo_krnl BOARD=u200
```

Это уносит проект BD, HLS-проект и `build_pack` одного ядра, не задевая
`build/ip_repo` (то есть 8 минут `make ip` заново не нужны).

Если нужно совсем всё, включая стек:

```bash
rm -rf build packaged_kernel_* tmp_kernel_pack_* _x.hw.* && mkdir -p build && cd build && cmake .. -DFDEV_NAME=u200 -DTCP_STACK_EN=1 && make ip
```

Дальше обычный прогон (~1 час, почти весь — шаг 4):

```bash
make -f Makefile.vivado all USER_KRNL=hls_dual_echo_krnl BOARD=u200
```

### Контрольные точки

Что должно быть видно в логе, чтобы не ждать час напрасно:

| Шаг | Признак, что всё верно |
|---|---|
| 0 | `[100%] Built target ip`, девять `.zip` в `build/ip_repo/` |
| 1 | `GT clock running at 156250000 Hz` для **каждого** QSFP-индекса |
| 2 | `плата: u200 (xcu200-fsgd2104-2-e), период 5.882 нс` |
| 2.5 | `=== иерархия сходится ===`, затем адресная карта |
| 3 | `user-ядро: HDL-обёртка (build_pack/packaged)` и **три** пути в `IP repos:` |
| 4 | `@@@ WNS:` и `@@@ WHS:` — **оба положительные** |

Строка на шаге 3 — самая полезная. `сырое HLS-IP (обёртки нет)` для
`hls_dual_echo_krnl` означает, что `pack` не прогнан, и ядро не увидит
регистров; теперь на этом падает сборка, а не сессия с платой.

Отрицательный WNS на шаге 4 — **не** повод грузить битстрим. Vivado, в отличие
от `v++`, частоту сам не снижает: он отдаёт битстрим с нарушенным таймингом, и
тот грузится и работает нестабильно (случайная порча пакетов, залипания стека).
Лечится снижением `DEV_FREQ_MHZ` в `devices/u200/device.tcl.in` и повтором с
шага 2.
