# -----------------------------------------------------------------------------
# u200_pins.xdc — физические пины Alveo U200 для bare-metal (без XRT-шелла)
#
# Источник: tcl_hooks/postopt.tcl из hw.xsa платформы
# xilinx_u200_gen3x16_xdma_2_202110_1, сверено с board/1.3/part0_pins.xml.
# Это не подобранные значения — ровно те, с которыми работал шелл.
#
# Имена портов здесь — наши собственные (см. build_bd.tcl); в платформе они
# назывались io_gt_qsfp_00_* и т.п., но те имена были частью её интерфейса,
# а не свойством платы.
#
# Refclk: берём 156.25 МГц вход (в part0_pins.xml он назван qsfp{0,1}_156mhz,
# в постопте платформы — refclka). Для 100GbE CMAC это правильный вход;
# 161.13 МГц (refclkb, K10/K11 и P10/P11) нужен для OTN-режимов и здесь
# не используется.
# -----------------------------------------------------------------------------

# ============================ QSFP0 ==========================================

# refclk 156.25 MHz
set_property PACKAGE_PIN M11 [get_ports {qsfp0_refclk_p}]
set_property PACKAGE_PIN M10 [get_ports {qsfp0_refclk_n}]

# GT lanes: rx
set_property PACKAGE_PIN N4  [get_ports {qsfp0_grx_p[0]}]
set_property PACKAGE_PIN N3  [get_ports {qsfp0_grx_n[0]}]
set_property PACKAGE_PIN M2  [get_ports {qsfp0_grx_p[1]}]
set_property PACKAGE_PIN M1  [get_ports {qsfp0_grx_n[1]}]
set_property PACKAGE_PIN L4  [get_ports {qsfp0_grx_p[2]}]
set_property PACKAGE_PIN L3  [get_ports {qsfp0_grx_n[2]}]
set_property PACKAGE_PIN K2  [get_ports {qsfp0_grx_p[3]}]
set_property PACKAGE_PIN K1  [get_ports {qsfp0_grx_n[3]}]

# GT lanes: tx
set_property PACKAGE_PIN N9  [get_ports {qsfp0_gtx_p[0]}]
set_property PACKAGE_PIN N8  [get_ports {qsfp0_gtx_n[0]}]
set_property PACKAGE_PIN M7  [get_ports {qsfp0_gtx_p[1]}]
set_property PACKAGE_PIN M6  [get_ports {qsfp0_gtx_n[1]}]
set_property PACKAGE_PIN L9  [get_ports {qsfp0_gtx_p[2]}]
set_property PACKAGE_PIN L8  [get_ports {qsfp0_gtx_n[2]}]
set_property PACKAGE_PIN K7  [get_ports {qsfp0_gtx_p[3]}]
set_property PACKAGE_PIN K6  [get_ports {qsfp0_gtx_n[3]}]

# ============================ QSFP1 ==========================================
# Второй порт: используется при NUM_QSFP=2 (дефолт) — cmac_krnl_2/network_krnl_2
# в build_bd.tcl. Пины идентичны QSFP0 по структуре, координаты другие
# (GT-квад CMACE4_X0Y7, см. kernel/cmac_krnl/package_cmac_krnl.tcl).

set_property PACKAGE_PIN T11 [get_ports {qsfp1_refclk_p}]
set_property PACKAGE_PIN T10 [get_ports {qsfp1_refclk_n}]

set_property PACKAGE_PIN U4  [get_ports {qsfp1_grx_p[0]}]
set_property PACKAGE_PIN U3  [get_ports {qsfp1_grx_n[0]}]
set_property PACKAGE_PIN T2  [get_ports {qsfp1_grx_p[1]}]
set_property PACKAGE_PIN T1  [get_ports {qsfp1_grx_n[1]}]
set_property PACKAGE_PIN R4  [get_ports {qsfp1_grx_p[2]}]
set_property PACKAGE_PIN R3  [get_ports {qsfp1_grx_n[2]}]
set_property PACKAGE_PIN P2  [get_ports {qsfp1_grx_p[3]}]
set_property PACKAGE_PIN P1  [get_ports {qsfp1_grx_n[3]}]

set_property PACKAGE_PIN U9  [get_ports {qsfp1_gtx_p[0]}]
set_property PACKAGE_PIN U8  [get_ports {qsfp1_gtx_n[0]}]
set_property PACKAGE_PIN T7  [get_ports {qsfp1_gtx_p[1]}]
set_property PACKAGE_PIN T6  [get_ports {qsfp1_gtx_n[1]}]
set_property PACKAGE_PIN R9  [get_ports {qsfp1_gtx_p[2]}]
set_property PACKAGE_PIN R8  [get_ports {qsfp1_gtx_n[2]}]
set_property PACKAGE_PIN P7  [get_ports {qsfp1_gtx_p[3]}]
set_property PACKAGE_PIN P6  [get_ports {qsfp1_gtx_n[3]}]

# ==================== сайдбенд QSFP (low-speed IO) ===========================
#
# Три выхода на порт, которыми надо УДЕРЖИВАТЬ трансивер во включённом
# состоянии. В XRT-шелле они висели на axi_gpio (hw.xsa: board/1.3/board.xml,
# интерфейсы qsfp{0,1}_lowspeed, пины qsfp{N}_lowspeed_0..4); в bare-metal их
# не драйвит никто, и модуль остаётся в состоянии подтяжек платы — а они не
# описаны ни в UG1289, ни в board file, ни в официальном XDC. Поэтому задаём
# явно, константами из BD (см. build_bd.tcl).
#
# Полярности — из официального alveo XDC (страница продукта U200/U250):
#     LPMODE  active high -> 0 = полная мощность (оптика включена)
#     RESETL  active low  -> 1 = не в сбросе
#     MODSELL active low  -> 1 = НЕ выбран для I2C
# LPMODE/RESETL совпадают с преcетом заводского шелла (hw.xsa:
# board/1.3/preset.xml, C_TRI_DEFAULT=0xFFFFFFF8, C_DOUT_DEFAULT=0x2).
# MODSELL у нас 1, а в шелле 0 — на линк он не влияет (только I2C-адресация),
# и без I2C-обвязки пассивное состояние правильнее; подробности в build_bd.tcl.
#
# Пины сверены по ТРЁМ независимым источникам и совпадают:
#   devices/u200/board_files/au200/1.3/part0_pins.xml (qsfp{N}_lowspeed_0..4),
#   официальный alveo XDC, OpenNIC constr/au200/pins.xdc.
#
# MODPRSL (BE20 / BC19) и INTL (BE21 / AV21) СОЗНАТЕЛЬНО не заведены: это
# входы, их драйвит трансивер (в шелле TRI=1). Объявить их выходами — два
# драйвера на линии; читать без I2C-обвязки нечего.
#
# DRIVE 8 — как в part0_pins.xml. Банк 64, VCCO = VCC1V2, отсюда LVCMOS12.

set_property -dict {PACKAGE_PIN BD18 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp0_lpmode}]
set_property -dict {PACKAGE_PIN BE17 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp0_resetl}]
set_property -dict {PACKAGE_PIN BE16 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp0_modsell}]

# Как и все остальные qsfp1_*-строки в этом файле, при NUM_QSFP=1 они не найдут
# портов: BD их не создаёт. Это даёт предупреждение и Common 17-55 на
# set_property, но не ошибку — пины отсутствующего порта и не должны
# назначаться. Все сборки идут с NUM_QSFP=2, где порты есть.
set_property -dict {PACKAGE_PIN AV22 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp1_lpmode}]
set_property -dict {PACKAGE_PIN BC18 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp1_resetl}]
set_property -dict {PACKAGE_PIN AY20 IOSTANDARD LVCMOS12 DRIVE 8} [get_ports {qsfp1_modsell}]

# ==================== free-running clock =====================================
# В шелле cmac_krnl получал clk_gt_freerun с ulp_m_aclk_freerun_ref_00 (100 МГц,
# см. ветку frc1 в scripts/post_sys_link.tcl.in). Здесь берём 300 МГц с пина
# и делим MMCM до 100 МГц — источника на 100 МГц на плате нет.
#
# clk0 (AY37/AY38) — для нашей clk_wiz. DDR4-контроллер тактируется отдельно от
# default_300mhz_clk3 (J16/H16), но его пины приходят из board interface
# (CONFIG.C0_CLOCK_BOARD_INTERFACE), поэтому здесь их прописывать не нужно —
# иначе получим двойное назначение.

# Имена с суффиксом _clk_: это интерфейсный порт (diff_clock_rtl), и Vivado
# разворачивает его в <имя>_clk_p / <имя>_clk_n. Без суффикса пины молча не
# назначаются ("No ports matched 'default_300mhz_clk0_p'"), а MMCM остаётся без
# входа — сверено с ouch_bd_wrapper.v.
set_property PACKAGE_PIN AY37 [get_ports {default_300mhz_clk0_clk_p}]
set_property PACKAGE_PIN AY38 [get_ports {default_300mhz_clk0_clk_n}]
set_property IOSTANDARD LVDS  [get_ports {default_300mhz_clk0_clk_p}]
set_property IOSTANDARD LVDS  [get_ports {default_300mhz_clk0_clk_n}]

# create_clock на этот порт НЕ ставим — по той же причине, что и для GT refclk
# ниже: clk_wiz создаёт клок сам, из CONFIG.PRIM_IN_FREQ (300.000).
#
# Здесь стояло `create_clock -period 3.333 -name default_300mhz_clk0`, и это
# давало CRITICAL WARNING [Constraints 18-1055]:
#     Clock 'default_300mhz_clk0' completely overrides clock
#     'default_300mhz_clk0_clk_p' ... Any constraints that refer to the
#     overridden clock will be ignored.
# Период совпадал (3.333 в обоих), так что MMCM видел правильные 300 МГц, и
# сборка проходила: WNS +0.108, WHS +0.0096, 0 failed nets. Опасность не в
# частоте, а в последней фразе — clk_wiz описывает через свой входной клок
# производные (clk_out1 170 МГц, clk_out2 100 МГц), и его уточняющие
# ограничения молча отбрасывались. Тайминг считался по неполной модели.

# GT refclk НЕ объявляем: cmac_usplus_axis.xdc внутри CMAC IP уже создаёт этот
# клок с тем же периодом 6.4 нс, и второй create_clock даёт
# "Clock 'qsfp0_refclk' completely overrides clock 'qsfp0_refclk_p'".

# ==================== ресет дизайна ==========================================
# Кнопка CPU_RESET (board.xml: "CPU Reset Push Button, Active Low"). Нужна для
# ext_reset_in у proc_sys_reset — иначе сброс происходит только при подаче
# питания, и после JTAG-перепрошивки логика остаётся в неопределённом состоянии.
#
# Пины DDR4 и её sys_clk здесь НЕ прописаны: они приходят из board interface
# (C0_DDR4_BOARD_INTERFACE / C0_CLOCK_BOARD_INTERFACE), и дублировать их в XDC
# нельзя — получим двойное назначение.

set_property PACKAGE_PIN AL20    [get_ports {resetn}]
set_property IOSTANDARD LVCMOS12 [get_ports {resetn}]

# ==================== индикация ==============================================
# GPIO_LED_0 = калибровка DDR4 завершена. Единственная наблюдаемость этого
# сигнала: c0_init_calib_complete — пин, а не регистр, через JTAG его не
# прочитать. Если светодиод не горит, разбираться со стеком бессмысленно.

set_property PACKAGE_PIN BC21    [get_ports {ddr4_calib_done}]
set_property IOSTANDARD LVCMOS12 [get_ports {ddr4_calib_done}]
