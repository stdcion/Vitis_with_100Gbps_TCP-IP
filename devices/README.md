# devices/ — параметры плат для Vivado-флоу

Всё, что зависит от конкретной платы Alveo и нужно для сборки **без XRT-шелла**.
XRT-флоу этот каталог не использует: там пины, SLR и refclk приходят из шелла
платформы.

```
devices/u200/
├── device.tcl.in     ← шаблон параметров, cmake генерирует из него device.tcl
├── pins.xdc          ← PACKAGE_PIN для QSFP, clk, reset, LED
├── board_files/      ← board file для Vivado (board.repoPaths)
│   └── au200/1.3/{board,part0_pins,preset}.xml
└── meta/             ← остальное из распакованного hw.xsa платформы
    ├── ext_metadata.json
    ├── xsa.xml
    └── tcl_hooks/{postopt,preopt,postlink,pre_create_project}.tcl, impl.xdc
```

`meta/` — не полная копия `hw.xsa`: каталог `board/` оттуда убран, потому что
это те же три файла, что в `board_files/au200/1.3/` (проверено `diff`).
Отличается только раскладка: Vivado требует
`<repo>/<плата>/<версия>/board.xml`, а в `.xsa` она лежит как `board/<версия>/`.

## Проверенное окружение

|                                   |                                                                       |
|-----------------------------------|-----------------------------------------------------------------------|
| Vivado                            | 2024.1, SW Build 5076996 (2022-05-22)                                 |
| Vitis HLS                         | 2024.1                                                                |
| v++                               | 2024.1 (только для XRT-флоу)                                          |
| Источник board files и пинов u200 | платформа `xilinx_u200_gen3x16_xdma_2_202110_1`, `hw/hw.xsa` (271 МБ) |

Board files для Alveo в этой установке Vivado **не установлены** — отсюда
необходимость держать их в репозитории.

## Что откуда берётся

**`device.tcl`** генерируется cmake'ом в `build/devices/<плата>/device.tcl`.
Часть значений подставляется из блока `FDEV_NAME` в
[CMakeLists.txt](../CMakeLists.txt) — `@FPGA_PART@`, `@CMAC_SLR@`,
`@NETWORK_KRNL_MEM@`. Это сделано, чтобы реестр плат был один и Vivado-флоу не
разъехался с XRT-флоу. Остальное задано прямо в шаблоне.

**`board_files/`** — извлечено из `hw.xsa` платформы, каталог `board/1.3`.
Нужно потому, что в нашей установке Vivado board files для Alveo не
установлены, а DDR4 IP без них требует прописывать ~150 пинов вручную.

**`meta/`** — тот же `hw.xsa`, распакованный целиком. Из него взяты пины
(`tcl_hooks/postopt.tcl`) и board files. Держится в репозитории как
первоисточник: без него при добавлении платы неоткуда взять пины.

**`probe/`** — текстовые снимки с машины, где стоит плата. Восстанавливать
дорого (нужен физический доступ), весит килобайты.

## Как добавить плату

Порядок именно такой: пины — самая трудоёмкая часть, и она определяет,
осмысленно ли остальное.

### 1. Проверить, что плата есть в CMakeLists

Блок `FDEV_NAME` в [CMakeLists.txt](../CMakeLists.txt) уже знает `u200`,
`u280`, `u250`, `u50`, `u55c`. Если платы там нет — добавить, взяв part и
платформу из установленного шелла.

### 2. Распаковать hw.xsa платформы

```bash
mkdir -p devices/<плата>/meta && cd devices/<плата>/meta
unzip /opt/xilinx/platforms/<платформа>/hw/<платформа>.xsa
```

`.xsa` — обычный zip. Нужны `board/`, `tcl_hooks/`, `ext_metadata.json`.

### 3. Разложить board files под структуру Vivado

`.xsa` кладёт их как `board/<версия>/`, а Vivado ждёт
`<repo>/<плата>/<версия>/` — то есть каталог надо переименовать, иначе плата
будет называться `board`:

```bash
mkdir -p devices/<плата>/board_files/<имя_платы>
mv devices/<плата>/meta/board/<версия> \
   devices/<плата>/board_files/<имя_платы>/<версия>
```

`mv`, а не `cp`: копия в `meta/` не нужна и была бы дубликатом.

Имя платы (`au200`, `au250`) и версия видны в `board.xml` в атрибутах
`<board name=... vendor=... version=...>` — из них же складывается
`DEV_BOARD_PART` вида `xilinx.com:au200:part0:1.3`.

### 4. Собрать pins.xdc

**Это не копипаста из даташита.** Источник — `meta/tcl_hooks/postopt.tcl`: там
лежат `set_property PACKAGE_PIN` для GT-каналов QSFP и refclk ровно в том виде,
в котором с ними работал шелл.

Нужны:

| Что                      | Где искать                                           |
|--------------------------|------------------------------------------------------|
| QSFP refclk (156.25 МГц) | `postopt.tcl`, имена вида `refclka` / `qsfp*_156mhz` |
| QSFP rx/tx, 4 линии      | `postopt.tcl`, `gt_rxp/gt_rxn/gt_txp/gt_txn`         |
| 300 МГц clk для MMCM     | `part0_pins.xml`, `default_300mhz_clk*`              |
| reset (кнопка)           | `part0_pins.xml`, `resetn`                           |

Сверить с `board_files/<плата>/<версия>/part0_pins.xml` — там те же пины в
машинночитаемом виде.

Две грабли, на которых мы уже спотыкались:

- **Имена портов diff_clock разворачиваются с инфиксом `_clk_`.** Порт
  интерфейса `default_300mhz_clk0` даёт в wrapper'е
  `default_300mhz_clk0_clk_p` / `_clk_n`. Без суффикса пины молча не
  назначаются, и получается DRC `NSTD-1`/`UCIO-1` уже на `write_bitstream`.
  Проверять по сгенерированному `*_wrapper.v`.
- **GT refclk объявлять `create_clock` НЕ надо** — `cmac_usplus_axis.xdc`
  внутри CMAC IP уже создаёт этот клок. Второй `create_clock` даёт
  `completely overrides clock`.

### 5. Написать device.tcl.in

Скопировать [u200/device.tcl.in](u200/device.tcl.in) и заменить значения.
Что нужно выяснить отдельно:

| Переменная                       | Где взять                                                                                         |
|----------------------------------|---------------------------------------------------------------------------------------------------|
| `DEV_BOARD_PART`                 | `board.xml`, атрибуты `vendor:name:part0:version`                                                 |
| `DEV_MEM_IF`, `DEV_MEM_CLK`      | `board.xml` — соответствие `NETWORK_KRNL_MEM` из CMakeLists банку платы                           |
| `DEV_CMAC_CORE`, `DEV_CMAC_QUAD` | комментарий в [package_cmac_krnl.tcl](../kernel/cmac_krnl/package_cmac_krnl.tcl) или `preset.xml` |
| `DEV_FREQ_MHZ`                   | подбирается по WNS первым прогоном; начать с 170                                                  |

### 6. Прогнать сборку

```bash
cd build && cmake .. -DFDEV_NAME=<плата> -DTCP_STACK_EN=1
```

Cmake скажет, нашёл ли `device.tcl.in`. Дальше обычный Vivado-флоу — см.
[docs/building.md](../docs/building.md).

## Чего эта структура НЕ решает

**HBM-платы.** У `u280`, `u50`, `u55c` в CMakeLists стоит
`NETWORK_KRNL_MEM "HBM[15]"`. HBM — другой IP, с другими портами и другой
конфигурацией; `DEV_MEM_TYPE "hbm"` в `build_bd.tcl` сейчас не поддержан. Это
отдельная ветка кода, а не другое значение параметра.

Из поддерживаемых плат DDR4 только у `u200` и `u250`.

## Лицензионная оговорка

`board_files/` и `meta/` извлечены из установки AMD/Xilinx Vitis. Это их
материалы, распространяются по условиям их лицензии. Держим в репозитории для
воспроизводимости сборки; при публикации проекта вопрос требует отдельного
решения. Подробнее — [board_files/README.md](u200/board_files/README.md).
