# Board file для Alveo U200

Нужен `build_bd.tcl`, чтобы DDR4 IP взял пины и параметры памяти из board
interface (`CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c3}`) вместо ручного
описания ~150 пинов в XDC.

## Откуда взято

Каталог `board/1.3` из `hw.xsa` платформы
`xilinx_u200_gen3x16_xdma_2_202110_1`:

```
/opt/xilinx/platforms/xilinx_u200_gen3x16_xdma_2_202110_1/hw/hw.xsa
```

`.xsa` — это zip, файлы просто распакованы (`unzip`), ничего не менялось.

Плата: `xilinx.com:au200:1.3`.

## Зачем в репозитории

В целевой установке Vivado 2024.1 board files для au200 не установлены
(`get_board_parts -filter {NAME =~ *au200*}` возвращает пусто), а в
`Xilinx/XilinxBoardStore` каталога `boards/Xilinx/au200` нет. Хранение рядом
с проектом убирает зависимость сборки от состояния системы.

`build_bd.tcl` подключает их сам:

```tcl
set_param board.repoPaths [list "$REPO_ROOT/scripts/vivado/board_files"]
```

## Лицензия

Файлы принадлежат AMD/Xilinx и распространяются с их инструментами. В исходном
каталоге платформы рядом лежал `LICENSE`, сюда он не переносился. Если этот
репозиторий публикуется, условия распространения стоит проверить отдельно —
как вариант, не коммитить каталог, а документировать извлечение из `hw.xsa`.

## Какие данные отсюда используются

- `part0_pins.xml` — привязки пинов; из него же сверялись QSFP-пины для
  [../u200_pins.xdc](../u200_pins.xdc)
- `board.xml` — интерфейсы; подтверждает, что `ddr4_sdram_c3` это 16 ГБ в SLR2
  с тактированием от `default_300mhz_clk3`
- `preset.xml` — предустановки параметров IP
