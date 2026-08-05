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

```bash
mkdir -p build && cd build
cmake .. -DFDEV_NAME=u200 -DTCP_STACK_EN=1
make ip
cd ..
```

### Что здесь важно

**`-DTCP_STACK_EN=1` обязателен.** По умолчанию в
[CMakeLists.txt:53](../CMakeLists.txt#L53) стоит `TCP_STACK_EN 0`, а
`UDP_STACK_EN 1` — то есть без флага соберётся только UDP, и TCP-дизайн потом
молча не заработает.

**`make ip`** — это не цель из Makefile в корне (там её нет). Она генерируется
cmake'ом в [FindVitis.cmake:445](../fpga-network-stack/xilinx-cmake/FindVitis.cmake#L445)
и агрегирует `ip.toe`, `ip.ip_handler`, `ip.mac_ip_encode`, `ip.arp_server_subnet`,
`ip.icmp_server`, `ip.ipv4`, `ip.udp`, `ip.hash_table`,
`ip.ethernet_frame_padding` — каждая прогоняет `vitis_hls` и делает
`export_design`.

**Результат:** `build/ip_repo/` — на него потом ссылаются оба флоу.

**Что ещё делает `cmake`, кроме подготовки цели `ip`** — генерирует четыре файла
из шаблонов (`configure_file` в [CMakeLists.txt:82-85](../CMakeLists.txt#L82)):

| Генерируется                            | Из шаблона | Кто использует               |
|-----------------------------------------|------------|------------------------------|
| `scripts/network_krnl_mem.txt`          | `.txt.in`  | v++ (`sp=` для банка памяти) |
| `scripts/cmac_krnl_slr.txt`             | `.txt.in`  | v++ (`slr=` для CMAC)        |
| `scripts/post_sys_link.tcl`             | `.tcl.in`  | v++ (пины, refclk)           |
| `kernel/common/types/network_types.svh` | `.svh.in`  | **оба флоу** — RTL стека     |

Последний — причина, по которой Vivado-флоу тоже требует прогона cmake: без
`network_types.svh` RTL не соберётся.

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

Это то, чем мы пользуемся. Три шага.

```bash
# 0. шаг выше (cmake + make ip) — нужен ip_repo и network_types.svh

# 1. RTL-ядра в .xo (переиспользуются из XRT-флоу: там же лежат packaged_kernel_*)
make cmac_krnl    DEVICE=<путь к .xpfm>
make network_krnl DEVICE=<путь к .xpfm>

# 2. user-ядро из HLS в IP-каталог (не .xo!)
USER_KRNL=hls_echo_krnl BOARD=u200 vitis_hls -f scripts/vivado/export_hls_ip.tcl

# 3. блок-дизайн + синтез + имплементация + битстрим
vivado -mode batch -source scripts/vivado/build_bd.tcl -tclargs hls_echo_krnl u200
vivado -mode batch -source /tmp/impl.tcl   # см. ниже
```

`BOARD` / второй `-tclargs` можно опустить — по умолчанию `u200`. Оба скрипта
читают `build/devices/<плата>/device.tcl` и падают с подсказкой, если его нет
(то есть если шаг 0 не прогнан).

### Про шаг 2

Имя ядра передаётся **переменной окружения**, не `-tclargs`: `vitis_hls` кладёт
в `$argv` всё, включая `-f` и путь к скрипту, поэтому `[lindex $argv 0]` даёт
`-f`. У `vivado` поведение другое — там `-tclargs` работает нормально, что видно
по шагу 3.

Скрипт печатает в конце **смещения регистров** из `*_hw.h`. Их надо перенести в
`USR_OFF_*` в [jtag_ctrl.tcl](../scripts/vivado/jtag_ctrl.tcl) — HLS назначает
их сам, порядок аргументов в C++ адреса не задаёт.

Результат: `kernel/user_krnl/<krnl>/src/hls/<krnl>_ip_proj/sol1/impl/ip`.

### Про шаг 3

`build_bd.tcl` создаёт проект в `./build_vivado`, собирает BD, запускает синтез
и имплементацию. Битстрим:
`build_vivado/ouch_vivado.runs/impl_1/ouch_bd_wrapper.bit`.

Отдельный запуск имплементации (если BD уже собран) — тот скрипт, который мы
гоняли:

```bash
cat > /tmp/impl.tcl <<'EOF'
open_project build_vivado/ouch_vivado.xpr
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
puts "@@@ IMPL:     [get_property STATUS   [get_runs impl_1]]"
puts "@@@ PROGRESS: [get_property PROGRESS [get_runs impl_1]]"
puts "@@@ WNS:      [get_property STATS.WNS [get_runs impl_1]]"
puts "@@@ WHS:      [get_property STATS.WHS [get_runs impl_1]]"
puts "@@@ BIT:      [glob -nocomplain build_vivado/ouch_vivado.runs/impl_1/*.bit]"
EOF
vivado -mode batch -source /tmp/impl.tcl 2>&1 | tee ~/impl.log
```

**`-jobs 2`, не больше.** На 8 vCPU / 30 ГБ восемь параллельных синтезов
съедали всю память и подвешивали инстанс так, что не работал ни ssh, ни
AWS-консоль. При `-jobs 2` пик ~10 ГБ.

**WNS обязан быть положительным.** Vivado, в отличие от v++, при недоборе
тайминга не снижает частоту, а выдаёт битстрим с нарушенным таймингом. Такой
битстрим грузится и работает нестабильно. Текущая сборка: WNS +0.123 нс,
WHS +0.0096 нс на 170 МГц.

### Почему приходится удалять build_vivado

`build_bd.tcl` вызывает `create_project -force`, так что проект перезаписывается
сам. Но есть два случая, когда каталог надо снести руками:

1. **Изменился user-ядро или его IP** — Vivado кеширует IP в
   `build_vivado/ouch_vivado.gen` и может подхватить старую версию.
2. **Остались чужие IP-репозитории** — если в `ip_repo_paths` попал старый
   `<krnl>_ip_proj`, Vivado ругается `Duplicate IP found`. Мы это ловили: старый
   каталог `ouch_ip_proj` конфликтовал с `hls_echo_krnl_ip_proj`.

Во втором случае удалять надо не `build_vivado`, а **старый `*_ip_proj` рядом с
исходником ядра**.

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
| `build/`                                 | cmake                           | да, но потом заново `cmake + make ip` (долго) |
| `build/ip_repo/`                         | `make ip`                       | вместе с `build/`                             |
| `_x.hw.<xsa>/`                           | `make cmac_krnl`/`network_krnl` | да, `.xo` пересоберутся                       |
| `packaged_kernel_*`                      | те же цели                      | да                                            |
| `tmp_kernel_pack_*`                      | те же цели                      | да, это временное                             |
| `build_dir.hw.<xsa>/`                    | `make all` (XRT)                | да                                            |
| `build_vivado/`                          | `build_bd.tcl`                  | да                                            |
| `<krnl>_ip_proj/` рядом с HLS-исходником | `export_hls_ip.tcl`             | **да, и следить за старыми**                  |

`make clean` убирает мелочь, `make cleanall` — плюс `build_dir*`, `_x.*`,
`packaged_kernel*`, `tmp_kernel_pack*`. **Ни один из них не трогает `build/` и
`build_vivado/`** — их только вручную.

---

## Проверка кода без FPGA

Тестбенч user-ядра гоняется нативно, без Vitis HLS — через шим `ap_int`/
`hls_stream`. Полезно на машине, где Vivado нет вовсе:

```bash
# см. run_csim.tcl рядом с исходником ядра
```
