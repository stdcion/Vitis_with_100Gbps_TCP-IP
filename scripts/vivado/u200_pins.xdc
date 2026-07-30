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
# Второй порт — пины наготове, но в дизайне пока не используется: для него
# нужен второй cmac_krnl + второй network_krnl (в репозитории нет параметра
# числа интерфейсов, config_sp описывает по одному экземпляру).
# Раскомментировать вместе с инстанцированием второго стека.

# set_property PACKAGE_PIN T11 [get_ports {qsfp1_refclk_p}]
# set_property PACKAGE_PIN T10 [get_ports {qsfp1_refclk_n}]
#
# set_property PACKAGE_PIN U4  [get_ports {qsfp1_grx_p[0]}]
# set_property PACKAGE_PIN U3  [get_ports {qsfp1_grx_n[0]}]
# set_property PACKAGE_PIN T2  [get_ports {qsfp1_grx_p[1]}]
# set_property PACKAGE_PIN T1  [get_ports {qsfp1_grx_n[1]}]
# set_property PACKAGE_PIN R4  [get_ports {qsfp1_grx_p[2]}]
# set_property PACKAGE_PIN R3  [get_ports {qsfp1_grx_n[2]}]
# set_property PACKAGE_PIN P2  [get_ports {qsfp1_grx_p[3]}]
# set_property PACKAGE_PIN P1  [get_ports {qsfp1_grx_n[3]}]
#
# set_property PACKAGE_PIN U9  [get_ports {qsfp1_gtx_p[0]}]
# set_property PACKAGE_PIN U8  [get_ports {qsfp1_gtx_n[0]}]
# set_property PACKAGE_PIN T7  [get_ports {qsfp1_gtx_p[1]}]
# set_property PACKAGE_PIN T6  [get_ports {qsfp1_gtx_n[1]}]
# set_property PACKAGE_PIN R9  [get_ports {qsfp1_gtx_p[2]}]
# set_property PACKAGE_PIN R8  [get_ports {qsfp1_gtx_n[2]}]
# set_property PACKAGE_PIN P7  [get_ports {qsfp1_gtx_p[3]}]
# set_property PACKAGE_PIN P6  [get_ports {qsfp1_gtx_n[3]}]

# ==================== free-running clock =====================================
# В шелле cmac_krnl получал clk_gt_freerun с ulp_m_aclk_freerun_ref_00 (100 МГц,
# см. ветку frc1 в scripts/post_sys_link.tcl.in). Здесь берём 300 МГц с пина
# и делим MMCM до 100 МГц — источника на 100 МГц на плате нет.
#
# clk0 (AY37/AY38) — для нашей clk_wiz. DDR4-контроллер тактируется отдельно от
# default_300mhz_clk3 (J16/H16), но его пины приходят из board interface
# (CONFIG.C0_CLOCK_BOARD_INTERFACE), поэтому здесь их прописывать не нужно —
# иначе получим двойное назначение.

set_property PACKAGE_PIN AY37 [get_ports {default_300mhz_clk0_p}]
set_property PACKAGE_PIN AY38 [get_ports {default_300mhz_clk0_n}]
set_property IOSTANDARD LVDS  [get_ports {default_300mhz_clk0_p}]
set_property IOSTANDARD LVDS  [get_ports {default_300mhz_clk0_n}]

create_clock -period 3.333 -name default_300mhz_clk0 [get_ports {default_300mhz_clk0_p}]

# GT refclk объявляем как часовой вход; CMAC внутри строит из него свои домены.
create_clock -period 6.400 -name qsfp0_refclk [get_ports {qsfp0_refclk_p}]
