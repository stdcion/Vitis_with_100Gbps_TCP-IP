// =============================================================================
// hls_echo_probe_dual_krnl_wrapper -- HDL-обёртка вокруг free-running HLS-ядра
// =============================================================================
//
// ЗАЧЕМ. HLS-функция hls_echo_probe_dual_krnl объявлена ap_ctrl_none и не имеет
// ни одного s_axilite (иначе HLS молча защёлкивает скаляры один раз после
// сброса -- см. шапку probe_control_s_axi.v). Значит регистры управления должен
// держать кто-то снаружи. Это и делает данный модуль:
//
//   * инстанцирует probe_control_s_axi.v -- регистры AXI4-Lite;
//   * отдаёт 6 параметров в ядро ПРОВОДАМИ;
//   * принимает 12 значений телеметрии из ядра проводами и отдаёт на чтение;
//   * реализует блочный протокол ap_ctrl_hs, который ждёт BD/XRT.
//
// Обёртка скопирована с hls_dual_echo_krnl_wrapper.sv -- ядра, которое на этом
// железе прошло имплементацию (WNS=+0.0167, WHS=+0.0097) и собрало битстрим.
// Набор AXI-Stream портов у двух ядер ИДЕНТИЧЕН (32 потока, те же имена),
// поэтому эта часть перенесена без изменений; отличается только состав
// скаляров: 6 входов вместо 3 и 12 выходов вместо 6.
//
// ЧЕМ probe ОТЛИЧАЕТСЯ ПРИНЦИПИАЛЬНО. Среди входов есть triggerGo, который
// меняется МНОГОКРАТНО во время работы -- по разу на каждый замер. Для
// dual_echo обёртка была правильным решением; здесь она ЕДИНСТВЕННОЕ рабочее:
// при s_axilite + ap_ctrl_none защёлка происходит однажды после сброса, и
// второй замер не запустился бы НИКОГДА. В .cpp это описано как "оговорка про
// triggerGo" (hls_echo_probe_dual_krnl.cpp:1146) с резервным планом "убрать
// DATAFLOW с верхнего уровня" -- обёртка решает ту же задачу, не трогая логику
// и не теряя II=1.
//
// ПРО ap_done И auto_restart -- ПЕРЕПИСАНО 17.08.2026.
//
// Раньше ядро было ap_ctrl_none, и обёртка ПОДДЕЛЫВАЛА завершение:
//     assign ap_done = ap_start_pulse;
// В само ядро ap_start не шёл -- у ap_ctrl_none таких портов нет.
//
// ЭТО И БЫЛО ПРИЧИНОЙ ОТКАЗА НА ПЛАТЕ. Внутри epd_core барьер ap_sync_done (И по
// ap_done всех стадий) требует готовности всех в ОДИН такт; при разном II это не
// наступает, и регион встаёт после первого прохода -- а тот случается сразу после
// сброса, когда хост ещё ничего не записал. Симптом: все счётчики нули,
// state=0(no-request), timeouts=0 тоже. Снять барьер может только импульс
// ap_start, которого не было.
//
// ТЕПЕРЬ ядро ap_ctrl_hs, порты настоящие и соединены с probe_control_s_axi
// напрямую. Непрерывность даёт auto_restart (бит 7 регистра ap_ctrl, отсюда
// запись 0x81): ap_start опускается на ap_ready и сразу поднимается обратно,
// каждый импульс снимает барьер. Так же работает hls_recv_krnl на этом железе.
//
// РЕГИСТРЫ ОСТАЛИСЬ В ОБЁРТКЕ, s_axilite у HLS-ядра нет. Иначе получилось бы два
// AXI-Lite на одном IP, а BD подключает один s_axi_control. Плата за это --
// xhls_*_hw.h не генерируется, карту (EPD_OFF_* в jtag_ctrl.tcl против localparam
// здесь) держим синхронно вручную.
//
// Регистр enable больше не нужен: ядро стоит в ap_idle, пока хост не записал
// ap_ctrl, поэтому listen физически не может уйти в стек раньше network_start.
//
// ИМЕНА AXI-STREAM ПОРТОВ НЕ МЕНЯТЬ. Они дословно совпадают с
// config_sp_hls_echo_probe_dual_krnl_dual.txt (s_axis_*_a / m_axis_*_b и т.д.).
// Обёртка их только пробрасывает: сигнатура снаружи остаётся такой же, какой её
// видел BD до появления обёртки, поэтому build_bd.tcl и config_sp править не
// нужно.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module hls_echo_probe_dual_krnl_wrapper #(
     parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32,
     parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 12
)(
     input  wire                                    ap_clk,
     input  wire                                    ap_rst_n,

     // ── AXI4-Lite: управление и телеметрия ────────────────────────────────
     input  wire                                    s_axi_control_awvalid,
     output wire                                    s_axi_control_awready,
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_awaddr,
     input  wire                                    s_axi_control_wvalid,
     output wire                                    s_axi_control_wready,
     input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_wdata,
     input  wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_wstrb,
     input  wire                                    s_axi_control_arvalid,
     output wire                                    s_axi_control_arready,
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_araddr,
     output wire                                    s_axi_control_rvalid,
     input  wire                                    s_axi_control_rready,
     output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_rdata,
     output wire [1:0]                              s_axi_control_rresp,
     output wire                                    s_axi_control_bvalid,
     input  wire                                    s_axi_control_bready,
     output wire [1:0]                              s_axi_control_bresp,
     output wire                                    interrupt,

     // ── половина a -> network_krnl_1 (QSFP0) ──────────────────────────────
     input  wire        s_axis_udp_rx_a_tvalid,
     output wire        s_axis_udp_rx_a_tready,
     input  wire [511:0] s_axis_udp_rx_a_tdata,
     input  wire [63:0] s_axis_udp_rx_a_tkeep,
     input  wire        s_axis_udp_rx_a_tlast,

     output wire        m_axis_udp_tx_a_tvalid,
     input  wire        m_axis_udp_tx_a_tready,
     output wire [511:0] m_axis_udp_tx_a_tdata,
     output wire [63:0] m_axis_udp_tx_a_tkeep,
     output wire        m_axis_udp_tx_a_tlast,

     input  wire        s_axis_udp_rx_meta_a_tvalid,
     output wire        s_axis_udp_rx_meta_a_tready,
     input  wire [255:0] s_axis_udp_rx_meta_a_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_a_tkeep,
     input  wire        s_axis_udp_rx_meta_a_tlast,

     output wire        m_axis_udp_tx_meta_a_tvalid,
     input  wire        m_axis_udp_tx_meta_a_tready,
     output wire [255:0] m_axis_udp_tx_meta_a_tdata,
     output wire [31:0] m_axis_udp_tx_meta_a_tkeep,
     output wire        m_axis_udp_tx_meta_a_tlast,

     output wire        m_axis_tcp_listen_port_a_tvalid,
     input  wire        m_axis_tcp_listen_port_a_tready,
     output wire [15:0] m_axis_tcp_listen_port_a_tdata,
     output wire [1:0]  m_axis_tcp_listen_port_a_tkeep,
     output wire        m_axis_tcp_listen_port_a_tlast,

     input  wire        s_axis_tcp_port_status_a_tvalid,
     output wire        s_axis_tcp_port_status_a_tready,
     input  wire [7:0]  s_axis_tcp_port_status_a_tdata,
     input  wire [0:0]  s_axis_tcp_port_status_a_tkeep,
     input  wire        s_axis_tcp_port_status_a_tlast,

     output wire        m_axis_tcp_open_connection_a_tvalid,
     input  wire        m_axis_tcp_open_connection_a_tready,
     output wire [63:0] m_axis_tcp_open_connection_a_tdata,
     output wire [7:0]  m_axis_tcp_open_connection_a_tkeep,
     output wire        m_axis_tcp_open_connection_a_tlast,

     input  wire        s_axis_tcp_open_status_a_tvalid,
     output wire        s_axis_tcp_open_status_a_tready,
     input  wire [127:0] s_axis_tcp_open_status_a_tdata,
     input  wire [15:0] s_axis_tcp_open_status_a_tkeep,
     input  wire        s_axis_tcp_open_status_a_tlast,

     output wire        m_axis_tcp_close_connection_a_tvalid,
     input  wire        m_axis_tcp_close_connection_a_tready,
     output wire [15:0] m_axis_tcp_close_connection_a_tdata,
     output wire [1:0]  m_axis_tcp_close_connection_a_tkeep,
     output wire        m_axis_tcp_close_connection_a_tlast,

     input  wire        s_axis_tcp_notification_a_tvalid,
     output wire        s_axis_tcp_notification_a_tready,
     input  wire [127:0] s_axis_tcp_notification_a_tdata,
     input  wire [15:0] s_axis_tcp_notification_a_tkeep,
     input  wire        s_axis_tcp_notification_a_tlast,

     output wire        m_axis_tcp_read_pkg_a_tvalid,
     input  wire        m_axis_tcp_read_pkg_a_tready,
     output wire [31:0] m_axis_tcp_read_pkg_a_tdata,
     output wire [3:0]  m_axis_tcp_read_pkg_a_tkeep,
     output wire        m_axis_tcp_read_pkg_a_tlast,

     input  wire        s_axis_tcp_rx_meta_a_tvalid,
     output wire        s_axis_tcp_rx_meta_a_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_a_tdata,
     input  wire [1:0]  s_axis_tcp_rx_meta_a_tkeep,
     input  wire        s_axis_tcp_rx_meta_a_tlast,

     input  wire        s_axis_tcp_rx_data_a_tvalid,
     output wire        s_axis_tcp_rx_data_a_tready,
     input  wire [511:0] s_axis_tcp_rx_data_a_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_a_tkeep,
     input  wire        s_axis_tcp_rx_data_a_tlast,

     output wire        m_axis_tcp_tx_meta_a_tvalid,
     input  wire        m_axis_tcp_tx_meta_a_tready,
     output wire [31:0] m_axis_tcp_tx_meta_a_tdata,
     output wire [3:0]  m_axis_tcp_tx_meta_a_tkeep,
     output wire        m_axis_tcp_tx_meta_a_tlast,

     output wire        m_axis_tcp_tx_data_a_tvalid,
     input  wire        m_axis_tcp_tx_data_a_tready,
     output wire [511:0] m_axis_tcp_tx_data_a_tdata,
     output wire [63:0] m_axis_tcp_tx_data_a_tkeep,
     output wire        m_axis_tcp_tx_data_a_tlast,

     input  wire        s_axis_tcp_tx_status_a_tvalid,
     output wire        s_axis_tcp_tx_status_a_tready,
     input  wire [63:0] s_axis_tcp_tx_status_a_tdata,
     input  wire [7:0]  s_axis_tcp_tx_status_a_tkeep,
     input  wire        s_axis_tcp_tx_status_a_tlast,

     // ── половина b -> network_krnl_2 (QSFP1) ──────────────────────────────
     input  wire        s_axis_udp_rx_b_tvalid,
     output wire        s_axis_udp_rx_b_tready,
     input  wire [511:0] s_axis_udp_rx_b_tdata,
     input  wire [63:0] s_axis_udp_rx_b_tkeep,
     input  wire        s_axis_udp_rx_b_tlast,

     output wire        m_axis_udp_tx_b_tvalid,
     input  wire        m_axis_udp_tx_b_tready,
     output wire [511:0] m_axis_udp_tx_b_tdata,
     output wire [63:0] m_axis_udp_tx_b_tkeep,
     output wire        m_axis_udp_tx_b_tlast,

     input  wire        s_axis_udp_rx_meta_b_tvalid,
     output wire        s_axis_udp_rx_meta_b_tready,
     input  wire [255:0] s_axis_udp_rx_meta_b_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_b_tkeep,
     input  wire        s_axis_udp_rx_meta_b_tlast,

     output wire        m_axis_udp_tx_meta_b_tvalid,
     input  wire        m_axis_udp_tx_meta_b_tready,
     output wire [255:0] m_axis_udp_tx_meta_b_tdata,
     output wire [31:0] m_axis_udp_tx_meta_b_tkeep,
     output wire        m_axis_udp_tx_meta_b_tlast,

     output wire        m_axis_tcp_listen_port_b_tvalid,
     input  wire        m_axis_tcp_listen_port_b_tready,
     output wire [15:0] m_axis_tcp_listen_port_b_tdata,
     output wire [1:0]  m_axis_tcp_listen_port_b_tkeep,
     output wire        m_axis_tcp_listen_port_b_tlast,

     input  wire        s_axis_tcp_port_status_b_tvalid,
     output wire        s_axis_tcp_port_status_b_tready,
     input  wire [7:0]  s_axis_tcp_port_status_b_tdata,
     input  wire [0:0]  s_axis_tcp_port_status_b_tkeep,
     input  wire        s_axis_tcp_port_status_b_tlast,

     output wire        m_axis_tcp_open_connection_b_tvalid,
     input  wire        m_axis_tcp_open_connection_b_tready,
     output wire [63:0] m_axis_tcp_open_connection_b_tdata,
     output wire [7:0]  m_axis_tcp_open_connection_b_tkeep,
     output wire        m_axis_tcp_open_connection_b_tlast,

     input  wire        s_axis_tcp_open_status_b_tvalid,
     output wire        s_axis_tcp_open_status_b_tready,
     input  wire [127:0] s_axis_tcp_open_status_b_tdata,
     input  wire [15:0] s_axis_tcp_open_status_b_tkeep,
     input  wire        s_axis_tcp_open_status_b_tlast,

     output wire        m_axis_tcp_close_connection_b_tvalid,
     input  wire        m_axis_tcp_close_connection_b_tready,
     output wire [15:0] m_axis_tcp_close_connection_b_tdata,
     output wire [1:0]  m_axis_tcp_close_connection_b_tkeep,
     output wire        m_axis_tcp_close_connection_b_tlast,

     input  wire        s_axis_tcp_notification_b_tvalid,
     output wire        s_axis_tcp_notification_b_tready,
     input  wire [127:0] s_axis_tcp_notification_b_tdata,
     input  wire [15:0] s_axis_tcp_notification_b_tkeep,
     input  wire        s_axis_tcp_notification_b_tlast,

     output wire        m_axis_tcp_read_pkg_b_tvalid,
     input  wire        m_axis_tcp_read_pkg_b_tready,
     output wire [31:0] m_axis_tcp_read_pkg_b_tdata,
     output wire [3:0]  m_axis_tcp_read_pkg_b_tkeep,
     output wire        m_axis_tcp_read_pkg_b_tlast,

     input  wire        s_axis_tcp_rx_meta_b_tvalid,
     output wire        s_axis_tcp_rx_meta_b_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_b_tdata,
     input  wire [1:0]  s_axis_tcp_rx_meta_b_tkeep,
     input  wire        s_axis_tcp_rx_meta_b_tlast,

     input  wire        s_axis_tcp_rx_data_b_tvalid,
     output wire        s_axis_tcp_rx_data_b_tready,
     input  wire [511:0] s_axis_tcp_rx_data_b_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_b_tkeep,
     input  wire        s_axis_tcp_rx_data_b_tlast,

     output wire        m_axis_tcp_tx_meta_b_tvalid,
     input  wire        m_axis_tcp_tx_meta_b_tready,
     output wire [31:0] m_axis_tcp_tx_meta_b_tdata,
     output wire [3:0]  m_axis_tcp_tx_meta_b_tkeep,
     output wire        m_axis_tcp_tx_meta_b_tlast,

     output wire        m_axis_tcp_tx_data_b_tvalid,
     input  wire        m_axis_tcp_tx_data_b_tready,
     output wire [511:0] m_axis_tcp_tx_data_b_tdata,
     output wire [63:0] m_axis_tcp_tx_data_b_tkeep,
     output wire        m_axis_tcp_tx_data_b_tlast,

     input  wire        s_axis_tcp_tx_status_b_tvalid,
     output wire        s_axis_tcp_tx_status_b_tready,
     input  wire [63:0] s_axis_tcp_tx_status_b_tdata,
     input  wire [7:0]  s_axis_tcp_tx_status_b_tkeep,
     input  wire        s_axis_tcp_tx_status_b_tlast,

     // ── ВРЕЗКИ НА axis_net_*: СКВОЗНОЙ ПРОХОД МИМО HLS-ЯДРА ───────────────
     //
     // Эти восемь интерфейсов в HLS-ядро НЕ ИДУТ ВООБЩЕ. Обёртка пробрасывает
     // их проводами и подглядывает за tvalid&tready&tlast, чтобы поставить
     // четыре больших T на той же шкале, что и маленькие t.
     //
     // ПОЧЕМУ ЗДЕСЬ, А НЕ ОТДЕЛЬНЫМ ЯДРОМ-СНИФФЕРОМ. Требование -- читать по
     // JTAG и на ТОЙ ЖЕ шкале времени, что четыре существующие точки. Счётчик
     // cycle_counter уже живёт здесь, регистры тоже. Отдельное ядро потребовало
     // бы либо тянуть счётчик наружу проводом BD, либо завести второй -- а
     // второй счётчик это ровно та ошибка, которую уже исправляли: расхождение
     // шкал завышает один интервал настолько, насколько занижает другой, и ни
     // одна проверка на хосте этого не видит.
     //
     // ПОЧЕМУ ЭТО БЕЗОПАСНО ПО КЛОКУ. axis_net_* на границе cmac_krnl уже в
     // домене ap_clk: внутри CMAC стоит network_clk_cross (cmac_krnl.sv:116),
     // переводящий 322 МГц GT в aclk, плюс axis_register_slice_512. А
     // network_krnl держит весь стек на том же клоке -- network_top.sv:238:
     // .net_clk(aclk). Проверено по коду, не предположение. Значит врезка не
     // добавляет CDC и живёт на той же шкале, что cycle_counter.
     //
     // РЕГИСТРА В ТРАКТЕ НЕТ, И ЭТО НАМЕРЕННО. Он добавил бы такт в измеряемый
     // путь, то есть исказил бы то, что мерим; а граница для тайминга там уже
     // есть -- axis_register_slice_512 внутри CMAC.
     //
     // В САМ ТРАКТ ЛОГИКА НЕ ДОБАВЛЕНА ВООБЩЕ: tdata/tvalid/tready/tkeep/tlast
     // идут насквозь чистыми assign. Фильтр висит на шине ОТВЕТВЛЕНИЕМ -- он
     // читает три бита управления и сравнивает 48 бит tdata[511:464] с
     // константой, а результат кладёт в свой регистр, не возвращая ничего в
     // тракт. То есть длина комбинационного пути между network_krnl и
     // cmac_krnl не изменилась; добавилась только нагрузка на эти провода
     // (fanout) и отдельный путь до триггера фильтра. При запасе WNS +0.0858 нс
     // это всё равно надо проверить на impl, а не считать доказанным.
     //
     // Ширина 512 бит -- C_AXIS_NET_{RX,TX}_TDATA_WIDTH (cmac_krnl.sv:10-11).
     //
     // Канал A (QSFP0): network_krnl_1.axis_net_tx -> сюда -> cmac_krnl_1
     input  wire         s_axis_net_tx_a_tvalid,
     output wire         s_axis_net_tx_a_tready,
     input  wire [511:0] s_axis_net_tx_a_tdata,
     input  wire [63:0]  s_axis_net_tx_a_tkeep,
     input  wire         s_axis_net_tx_a_tlast,

     output wire         m_axis_net_tx_a_tvalid,
     input  wire         m_axis_net_tx_a_tready,
     output wire [511:0] m_axis_net_tx_a_tdata,
     output wire [63:0]  m_axis_net_tx_a_tkeep,
     output wire         m_axis_net_tx_a_tlast,

     // Канал A: cmac_krnl_1.axis_net_rx -> сюда -> network_krnl_1
     input  wire         s_axis_net_rx_a_tvalid,
     output wire         s_axis_net_rx_a_tready,
     input  wire [511:0] s_axis_net_rx_a_tdata,
     input  wire [63:0]  s_axis_net_rx_a_tkeep,
     input  wire         s_axis_net_rx_a_tlast,

     output wire         m_axis_net_rx_a_tvalid,
     input  wire         m_axis_net_rx_a_tready,
     output wire [511:0] m_axis_net_rx_a_tdata,
     output wire [63:0]  m_axis_net_rx_a_tkeep,
     output wire         m_axis_net_rx_a_tlast,

     // Канал B (QSFP1): network_krnl_2.axis_net_tx -> сюда -> cmac_krnl_2
     input  wire         s_axis_net_tx_b_tvalid,
     output wire         s_axis_net_tx_b_tready,
     input  wire [511:0] s_axis_net_tx_b_tdata,
     input  wire [63:0]  s_axis_net_tx_b_tkeep,
     input  wire         s_axis_net_tx_b_tlast,

     output wire         m_axis_net_tx_b_tvalid,
     input  wire         m_axis_net_tx_b_tready,
     output wire [511:0] m_axis_net_tx_b_tdata,
     output wire [63:0]  m_axis_net_tx_b_tkeep,
     output wire         m_axis_net_tx_b_tlast,

     // Канал B: cmac_krnl_2.axis_net_rx -> сюда -> network_krnl_2
     input  wire         s_axis_net_rx_b_tvalid,
     output wire         s_axis_net_rx_b_tready,
     input  wire [511:0] s_axis_net_rx_b_tdata,
     input  wire [63:0]  s_axis_net_rx_b_tkeep,
     input  wire         s_axis_net_rx_b_tlast,

     output wire         m_axis_net_rx_b_tvalid,
     input  wire         m_axis_net_rx_b_tready,
     output wire [511:0] m_axis_net_rx_b_tdata,
     output wire [63:0]  m_axis_net_rx_b_tkeep,
     output wire         m_axis_net_rx_b_tlast
);

// ── блочный протокол: ТЕПЕРЬ НАСТОЯЩИЙ, А НЕ ПОДДЕЛКА ────────────────────────
//
// РАНЬШЕ ЗДЕСЬ БЫЛО:
//     assign ap_done  = ap_start_pulse;      // «закончил сразу после старта»
//     assign ap_ready = ap_done;
//
// Обёртка отвечала control_s_axi сама, а в HLS-ядро ap_start НЕ ШЁЛ ВООБЩЕ: у
// ядра с ap_ctrl_none таких портов нет, только ap_clk и ap_rst_n. Это работало
// как рукопожатие для BD, но означало, что запустить ядро невозможно -- оно
// «течёт» с момента снятия сброса и остановить/перезапустить его нечем.
//
// ИМЕННО ЭТО И БЫЛО ПРИЧИНОЙ ОТКАЗА. Барьер ap_sync_done внутри epd_core -- И по
// ap_done всех стадий -- требует готовности всех В ОДИН такт; при разном II это
// не наступает, и регион встаёт после первого прохода (он случается сразу после
// сброса, когда хост ещё ничего не записал). Снять барьер может только импульс
// ap_start, сбрасывающий ap_sync_reg стадий, -- а его не было.
//
// ТЕПЕРЬ ядро объявлено ap_ctrl_hs, у него появились настоящие
// ap_start/ap_done/ap_ready/ap_idle, и они соединены напрямую с
// probe_control_s_axi. Там уже лежит логика auto_restart, скопированная из
// сгенерированного HLS (probe_control_s_axi.v:500-509):
//
//     if (w_hs && waddr == ADDR_AP_CTRL && WSTRB[0] && WDATA[0])
//          int_ap_start <= 1'b1;
//     else if (ap_ready)
//          int_ap_start <= int_auto_restart;   // clear on handshake/auto restart
//
// То есть при записи 0x81 ap_start опускается на ap_ready и сразу поднимается
// обратно -- получается непрерывная последовательность импульсов, каждый из
// которых снимает барьер. Точно так же работает hls_recv_krnl на этом железе.
//
// ap_start_pulse БОЛЬШЕ НЕ НУЖЕН: он служил программным сбросом счётчиков
// обёртки, но счётчики (кадры врезок, таймстемпы) сбрасываются по ap_rst_n, а
// подделка ap_done ушла вместе с ним.
wire        ap_start;
wire        ap_done;
wire        ap_ready;
wire        ap_idle;

// ── регистры <-> провода ─────────────────────────────────────────────────────
//
// ОБЪЯВЛЕНИЯ СТОЯТ ЗДЕСЬ, ДО ПЕРВОГО ИСПОЛЬЗОВАНИЯ, И ЭТО НЕ ВКУСОВЩИНА.
// Раньше этот блок лежал ниже, рядом с инстансом probe_control_s_axi, а
// защёлка таймстемпов и фильтры выше уже читали sentCount_ap_vld и
// minWords_reg. Vivado Synthesis это принимает (Verilog-2001 разрешает
// использовать wire уровня модуля до объявления, и probe с таким кодом прошёл
// имплементацию), но xvlog в режиме SystemVerilog -- нет:
//
//     ERROR: [VRFC 10-3380] identifier 'sentCount_ap_vld' is used before its
//                           declaration
//
// То есть код собирался, но не симулировался, а расхождение между
// инструментами -- плохая опора. Держим объявления выше всех читателей.
wire [31:0] enable_reg;
wire [31:0] serverIp_reg;
wire [31:0] serverPort_reg;
wire [31:0] listenPort_reg;
wire [31:0] msgBytes_reg;
wire [31:0] triggerGo_reg;
// Порог фильтра кадров на axis_net_*. В HLS-ядро НЕ идёт: врезки живут целиком
// в обёртке. Хост пишет его вместе с msgBytes, поэтому свип по размерам не
// требует пересборки, а порог всегда соответствует тому, что отправляется.
wire [31:0] minWords_reg;

// Счётчики событий из ядра. ap_vld — строб «изменилось в этом такте», по нему
// защёлкиваются таймстемпы ниже. Сами значения читаются хостом как телеметрия;
// держать их между обновлениями — забота HLS (теневой регистр *_preg).
wire [31:0] connAttempts;
wire [31:0] sentCount;
wire        sentCount_ap_vld;
wire [31:0] recvCount;
wire        recvCount_ap_vld;
wire [31:0] timeoutCount;
wire [31:0] echoRxCount;
wire        echoRxCount_ap_vld;
wire [31:0] echoCount;
wire        echoCount_ap_vld;
wire [31:0] listenAttempts;
wire [31:0] portState;

// ── ЕДИНАЯ ШКАЛА ВРЕМЕНИ ДЛЯ ОБЕИХ ПОЛОВИН ───────────────────────────────────
//
// Все четыре таймстемпа замера обязаны быть в ОДНОЙ шкале, иначе NET_FWD и
// NET_REV считаются неправильно. Смотрите, какие точки откуда берутся:
//
//     t1' = tx_data_a   клиент  (половина a)
//     t2' = rx_data_b   эхо     (половина b)
//     t1  = tx_data_b   эхо     (половина b)
//     t2  = rx_data_a   клиент  (половина a)
//
//     NET_FWD = t2' - t1'   <- ВЫЧИТАЕТ ЭХО МИНУС КЛИЕНТ
//     NET_REV = t2  - t1    <- ВЫЧИТАЕТ КЛИЕНТ МИНУС ЭХО
//
// Раньше каждая половина держала свой static ap_uint<32> cyc внутри HLS
// (epd_client_traffic и epd_server_echo). Комментарий там утверждал, что шкалы
// синхронны, потому что оба счётчика тикают от ap_clk и стартуют с одного
// сброса. При Final II = 1 это действительно так — но это свойство РАСПИСАНИЯ
// HLS, а не свойство кода. Стоит одной стадии получить II=2 (probe-ядро плотнее
// dual_echo, depth у обеих стадий уже 3), и счётчики начинают расходиться
// линейно.
//
// ЧЕМ ЭТО ОПАСНО ИМЕННО ЗДЕСЬ. Расхождение на N тактов завышает NET_FWD ровно
// на N и занижает NET_REV ровно на N. При этом:
//   * RTT  = t2 - t1'  (оба от клиента) — ОСТАЁТСЯ ВЕРНЫМ;
//   * ECHO = t1 - t2'  (оба от эха)     — ОСТАЁТСЯ ВЕРНЫМ;
//   * баланс NET_FWD + ECHO + NET_REV == RTT — СХОДИТСЯ ВСЕГДА, смещение
//     взаимно уничтожается.
// То есть ни одна проверка на хосте этого не увидит: epd_raw пометит замер
// как ok. Симптом — стабильная асимметрия NET_FWD против NET_REV на физически
// симметричном тракте, которую легко списать на «асимметрию стека».
//
// Поэтому счётчик ОДИН и живёт здесь, в HDL. Он идёт в ядро проводом и
// раздаётся обеим половинам, так что единая шкала — свойство схемы, а не
// свойство того, что решил планировщик.
//
// Разрядность 32 бита, как и было: на 165 МГц оборот раз в ~26 с. Измерению
// это не мешает, вычитание беззнаковое по модулю 2^32 (см. пояснение к
// таймстемпам в hls_echo_probe_dual_krnl.cpp).
//
// Сброс — по ap_rst_n, тому же, что сбрасывает логику ядра, поэтому шкала
// начинается там же, где начинается работа. От ap_start НЕ зависит: ядро
// ap_ctrl_none и течёт с первого такта после снятия сброса.
logic [31:0] cycle_counter = 32'b0;

always @(posedge ap_clk) begin
     if (~ap_rst_n)
          cycle_counter <= 32'b0;
     else
          cycle_counter <= cycle_counter + 32'd1;
end

// ── ЗАЩЁЛКА ТАЙМСТЕМПОВ ──────────────────────────────────────────────────────
//
// Ядро время НЕ измеряет: оно считает события, а штампует их здесь.
//
// СТРОБЫ БЕРУТСЯ С ШИНЫ, а не из ap_vld счётчиков ядра -- подробное обоснование
// у объявления tap_* ниже. Коротко: ap_vld поднимается, когда стадия отдаёт
// значение наружу, и при ap_ctrl_hs это на несколько тактов позже самого
// события. Внутри одной половины смещение сокращается в разности, а между
// половинами (NET_FWD, NET_REV) -- нет, и даёт систематическую ошибку, которую
// хост не увидит: баланс всё равно сходится.
//
// Счётчики sentCount/recvCount/echoCount/echoRxCount остаются как телеметрия
// «сколько событий было», их ap_vld в измерении больше не участвует.
//
//     t1' <- m_axis_tcp_tx_data_a  tvalid&tready&tlast
//     t2' <- s_axis_tcp_rx_data_b  tvalid&tready&tlast
//     t1  <- m_axis_tcp_tx_data_b  tvalid&tready&tlast
//     t2  <- s_axis_tcp_rx_data_a  tvalid&tready&tlast
//
// ПОЧЕМУ ЗДЕСЬ, А НЕ В ЯДРЕ. Две попытки измерять время внутри HLS провалились:
//
//   1. По счётчику тактов на стадию. Совпадали лишь пока HLS давал обеим
//      стадиям Final II = 1 — свойство расписания, не кода.
//   2. Общий счётчик проводом внутрь (скаляр cycleCount). HLS раздал его
//      НЕСИММЕТРИЧНО: epd_server_echo получил провод, а epd_client_traffic —
//      FIFO-канал глубины 3. Плюс пустой канал блокировал стадию клиента
//      (ap_block_state1_pp0_stage0_iter0 включал cycleCount_c_empty_n == 0), то
//      есть к перекошенным шкалам добавлялся риск вечного ожидания.
//
// В обоих случаях NET_FWD = t2'-t1' и NET_REV = t2-t1 вычитали точки из РАЗНЫХ
// шкал: одна завышалась ровно настолько, насколько занижалась другая, при
// верных RTT и ECHO и сходящемся балансе. То есть ни одна проверка на хосте
// этого не увидела бы — только стабильная асимметрия NET_FWD против NET_REV,
// которую легко списать на асимметрию тракта.
//
// Здесь шкала одна ФИЗИЧЕСКИ: один регистр cycle_counter, четыре читателя, один
// тактовый домен. Обёртка узнаёт о событии на такт позже самого события (ap_vld
// приходит из зарегистрированного выхода ядра), но ОДИНАКОВО для всех четырёх
// точек — значит разности точны. Абсолютные значения нигде не используются.
logic [31:0] ts_request_r = 32'b0;   // t1'
logic [31:0] ts_echo_in_r = 32'b0;   // t2'
logic [31:0] ts_echo_out_r = 32'b0;  // t1
logic [31:0] ts_reply_r   = 32'b0;   // t2

// ── СТРОБЫ СНИМАЮТСЯ С ШИНЫ, А НЕ ИЗ ap_vld ЯДРА ────────────────────────────
//
// РАНЬШЕ ЗДЕСЬ БЫЛО:
//     if (sentCount_ap_vld)   ts_request_r <= cycle_counter;
//     ... и так для четырёх точек, по ap_vld счётчиков событий.
//
// ЭТО ДАВАЛО НЕЧЕСТНЫЕ ЗАДЕРЖКИ. ap_vld выходного скаляра HLS поднимается не в
// такте самого события, а когда стадия отдаёт значение наружу. При ap_ctrl_none
// это было близко к событию, но при ap_ctrl_hs выход отдаётся на ap_done прохода,
// а проход занимает несколько тактов (у dual_echo измерено ровно 3).
//
// В разностях внутри одной половины смещение сокращается:
//     RTT  = t2 - t1'   оба от клиента  -- верно
//     ECHO = t1 - t2'   оба от эха      -- верно
// А вот NET_FWD = t2' - t1' и NET_REV = t2 - t1 вычитают точки из РАЗНЫХ
// половин. Если их проходы не синхронны, появляется систематическая ошибка в
// единицы тактов (6-18 нс при 165 МГц) -- невидимая для хоста, потому что баланс
// NET_FWD + ECHO + NET_REV == RTT всё равно сходится: одно завышается ровно
// настолько, насколько занижается другое. Ровно та же ловушка, из-за которой
// шкалу времени в своё время вынесли из ядра в эту обёртку.
//
// ТЕПЕРЬ СТРОБ -- ФИЗИЧЕСКОЕ СОБЫТИЕ НА ШИНЕ: последнее слово сообщения принято
// или отдано, то есть tvalid & tready & tlast. Ни ap_vld, ни расписание HLS в
// измерении не участвуют, и точность не зависит от того, какой II выбрал
// инструмент.
//
//     t1' <- m_axis_tcp_tx_data_a   клиент отдал последнее слово запроса
//     t2' <- s_axis_tcp_rx_data_b   эхо приняло последнее слово запроса
//     t1  <- m_axis_tcp_tx_data_b   эхо отдало последнее слово ответа
//     t2  <- s_axis_tcp_rx_data_a   клиент принял последнее слово ответа
//
// ПОЧЕМУ tlast, А НЕ ПЕРВОЕ СЛОВО. Измеряем момент, когда сообщение целиком
// пересекло границу: для 64 байт это одно слово и разницы нет, но при свипе до
// 1500 байт (24 слова) выбор точки внутри пакета сдвигал бы результат на длину
// сообщения, а не на задержку тракта.
//
// ПОЧЕМУ ЭТО ТЕ ЖЕ ПРОВОДА, ЧТО У ЯДРА. Обёртка их только пробрасывает
// (см. инстанс hls_echo_probe_dual_krnl_ip ниже): tvalid/tready/tlast идут
// насквозь чистыми assign, поэтому строб берётся ровно там, где данные покидают
// или входят в ядро, без добавленного такта.
wire tap_t1_pre  = m_axis_tcp_tx_data_a_tvalid & m_axis_tcp_tx_data_a_tready
                                              & m_axis_tcp_tx_data_a_tlast;
wire tap_t2_pre  = s_axis_tcp_rx_data_b_tvalid & s_axis_tcp_rx_data_b_tready
                                              & s_axis_tcp_rx_data_b_tlast;
wire tap_t1_echo = m_axis_tcp_tx_data_b_tvalid & m_axis_tcp_tx_data_b_tready
                                              & m_axis_tcp_tx_data_b_tlast;
wire tap_t2_reply = s_axis_tcp_rx_data_a_tvalid & s_axis_tcp_rx_data_a_tready
                                               & s_axis_tcp_rx_data_a_tlast;

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          ts_request_r  <= 32'b0;
          ts_echo_in_r  <= 32'b0;
          ts_echo_out_r <= 32'b0;
          ts_reply_r    <= 32'b0;
     end else begin
          if (tap_t1_pre)    ts_request_r  <= cycle_counter;
          if (tap_t2_pre)    ts_echo_in_r  <= cycle_counter;
          if (tap_t1_echo)   ts_echo_out_r <= cycle_counter;
          if (tap_t2_reply)  ts_reply_r    <= cycle_counter;
     end
end

// ── ВРЕЗКИ НА axis_net_*: ЧЕТЫРЕ БОЛЬШИХ T ───────────────────────────────────
//
// Сквозной проход. Никакой логики в тракте: комбинационное соединение, ноль
// добавленных тактов. Именно поэтому измеряемый путь остаётся тем же, каким
// был бы без врезки, -- а мы им же и меряем.
assign m_axis_net_tx_a_tvalid = s_axis_net_tx_a_tvalid;
assign m_axis_net_tx_a_tdata  = s_axis_net_tx_a_tdata;
assign m_axis_net_tx_a_tkeep  = s_axis_net_tx_a_tkeep;
assign m_axis_net_tx_a_tlast  = s_axis_net_tx_a_tlast;
assign s_axis_net_tx_a_tready = m_axis_net_tx_a_tready;

assign m_axis_net_rx_a_tvalid = s_axis_net_rx_a_tvalid;
assign m_axis_net_rx_a_tdata  = s_axis_net_rx_a_tdata;
assign m_axis_net_rx_a_tkeep  = s_axis_net_rx_a_tkeep;
assign m_axis_net_rx_a_tlast  = s_axis_net_rx_a_tlast;
assign s_axis_net_rx_a_tready = m_axis_net_rx_a_tready;

assign m_axis_net_tx_b_tvalid = s_axis_net_tx_b_tvalid;
assign m_axis_net_tx_b_tdata  = s_axis_net_tx_b_tdata;
assign m_axis_net_tx_b_tkeep  = s_axis_net_tx_b_tkeep;
assign m_axis_net_tx_b_tlast  = s_axis_net_tx_b_tlast;
assign s_axis_net_tx_b_tready = m_axis_net_tx_b_tready;

assign m_axis_net_rx_b_tvalid = s_axis_net_rx_b_tvalid;
assign m_axis_net_rx_b_tdata  = s_axis_net_rx_b_tdata;
assign m_axis_net_rx_b_tkeep  = s_axis_net_rx_b_tkeep;
assign m_axis_net_rx_b_tlast  = s_axis_net_rx_b_tlast;
assign s_axis_net_rx_b_tready = m_axis_net_rx_b_tready;

// Фильтр кадров по числу слов. Четыре инстанса, по одному на измеряемую точку.
// Обоснование фильтра целиком -- в шапке net_frame_filter.v; коротко: на
// axis_net_* идёт весь трафик стека, наш кадр там ничем не выделен, а служебные
// (ARP, чистый ACK, ICMP) укладываются в одно 512-битное слово.
//
// min_words читают все четыре инстанса с одного провода minWords_reg. В HLS
// такое размножение скаляра было бы дефектом (часть читателей получила бы
// FIFO-канал с блокировкой -- см. enableConn/enableTraffic/enableListen выше),
// но это HDL: один wire на четыре потребителя -- обычное дело.
//
// ВНИМАНИЕ НА tready. Смотрим сигналы со стороны, куда данные УХОДЯТ:
// s_axis_*_tvalid/tlast и m_axis_*_tready. Через passthrough это одни и те же
// провода, но брать tready именно от мастера правильнее по смыслу -- считается
// передача, а не предъявление, и при backpressure таймстемп не уедет.
wire        net_tx_a_ours, net_rx_a_ours, net_tx_b_ours, net_rx_b_ours;
wire [31:0] nf_cnt_tx_a, nf_cnt_rx_a, nf_cnt_tx_b, nf_cnt_rx_b;
wire [31:0] nf_drp_tx_a, nf_drp_rx_a, nf_drp_tx_b, nf_drp_rx_b;

net_frame_filter flt_tx_a (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_tx_a_tvalid), .tready(m_axis_net_tx_a_tready),
     .tlast(s_axis_net_tx_a_tlast), .tdata(s_axis_net_tx_a_tdata),
     .min_words(minWords_reg),
     .frame_ours(net_tx_a_ours),
     .count_ours(nf_cnt_tx_a), .count_drop(nf_drp_tx_a)
);

net_frame_filter flt_rx_a (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_rx_a_tvalid), .tready(m_axis_net_rx_a_tready),
     .tlast(s_axis_net_rx_a_tlast), .tdata(s_axis_net_rx_a_tdata),
     .min_words(minWords_reg),
     .frame_ours(net_rx_a_ours),
     .count_ours(nf_cnt_rx_a), .count_drop(nf_drp_rx_a)
);

net_frame_filter flt_tx_b (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_tx_b_tvalid), .tready(m_axis_net_tx_b_tready),
     .tlast(s_axis_net_tx_b_tlast), .tdata(s_axis_net_tx_b_tdata),
     .min_words(minWords_reg),
     .frame_ours(net_tx_b_ours),
     .count_ours(nf_cnt_tx_b), .count_drop(nf_drp_tx_b)
);

net_frame_filter flt_rx_b (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_rx_b_tvalid), .tready(m_axis_net_rx_b_tready),
     .tlast(s_axis_net_rx_b_tlast), .tdata(s_axis_net_rx_b_tdata),
     .min_words(minWords_reg),
     .frame_ours(net_rx_b_ours),
     .count_ours(nf_cnt_rx_b), .count_drop(nf_drp_rx_b)
);

// Таймстемпы больших T -- ТОТ ЖЕ cycle_counter, что и у маленьких t. В этом
// весь смысл размещения врезки здесь: разности T-t осмысленны только на одной
// шкале.
//
//     T1' <- tx на канале A   запрос ушёл в провод (порт 0)
//     T2' <- rx на канале B   запрос пришёл из провода (порт 1)
//     T1  <- tx на канале B   ответ ушёл в провод (порт 1)
//     T2  <- rx на канале A   ответ пришёл из провода (порт 0)
//
// Круг: t1' -> T1' -> T2' -> t2' -> [эхо] -> t1 -> T1 -> T2 -> t2.
logic [31:0] ts_net_tx_a_r = 32'b0;   // T1'
logic [31:0] ts_net_rx_b_r = 32'b0;   // T2'
logic [31:0] ts_net_tx_b_r = 32'b0;   // T1
logic [31:0] ts_net_rx_a_r = 32'b0;   // T2

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          ts_net_tx_a_r <= 32'b0;
          ts_net_rx_b_r <= 32'b0;
          ts_net_tx_b_r <= 32'b0;
          ts_net_rx_a_r <= 32'b0;
     end else begin
          if (net_tx_a_ours) ts_net_tx_a_r <= cycle_counter;
          if (net_rx_b_ours) ts_net_rx_b_r <= cycle_counter;
          if (net_tx_b_ours) ts_net_tx_b_r <= cycle_counter;
          if (net_rx_a_ours) ts_net_rx_a_r <= cycle_counter;
     end
end

// Счётчики кадров наружу: на канал приходится ДВА фильтра (tx и rx), а регистра
// в карте по одному на канал. Складываем -- отладочному счётчику этого хватает:
// вопрос, на который он отвечает, звучит «врезка на этом канале вообще живая?»,
// а не «сколько именно кадров на каждом направлении». Раздельные счётчики
// стоили бы ещё четырёх адресов ради различия, которое видно и так: если сумма
// растёт, а один из таймстемпов канала стоит -- мёртвое как раз то направление.
wire [31:0] netFrameCountA = nf_cnt_tx_a + nf_cnt_rx_a;
wire [31:0] netFrameCountB = nf_cnt_tx_b + nf_cnt_rx_b;
wire [31:0] netFrameDropA  = nf_drp_tx_a + nf_drp_rx_a;
wire [31:0] netFrameDropB  = nf_drp_tx_b + nf_drp_rx_b;

// ── sampleReady ──────────────────────────────────────────────────────────────
//
// Тоже переехал из ядра. Здесь он проще, чем был в epd_latch: там надо было
// ждать все четыре значения из четырёх FIFO, а тут достаточно факта «t2 пришёл
// после последнего triggerGo» — остальные три точки к этому моменту уже
// защёлкнуты по построению круга (t1' -> t2' -> t1 -> t2).
//
// СТРОБ -- tap_t2_reply, ТОТ ЖЕ, ЧТО ЗАЩЁЛКИВАЕТ t2. Раньше здесь стоял
// recvCount_ap_vld, то есть флаг поднимался, когда ядро отдало счётчик наружу, а
// не когда ответ физически пришёл. При ap_ctrl_hs это расходится на длину
// прохода: хост мог прочитать таймстемпы РАНЬШЕ, чем поднялся ap_vld, и увидеть
// значения от предыдущего замера при sampleReady=0. Теперь готовность и сами
// таймстемпы приходят от одного события -- рассинхрона между ними нет по
// построению.
//
// Снимается записью triggerGo: триггер и подтверждение чтения — одна
// транзакция. Фронт ловим по изменению значения регистра (хост пишет
// инкремент), а не по единице, поэтому сбрасывать регистр между замерами не
// надо.
//
// Гонки чтения нет по построению режима: пока хост не записал triggerGo, новый
// пакет не отправится, значит четвёрка не изменится.
// ПРИОРИТЕТ У УСТАНОВКИ, НЕ У СБРОСА — и это не вкусовщина.
//
// Сначала было наоборот:
//     if      (triggerGo_reg != trigger_r) sample_ready_r <= 1'b0;
//     else if (recvCount_ap_vld)           sample_ready_r <= 1'b1;
// Условие смены triggerGo истинно ровно один такт, и в этот такт оно подавляло
// установку. Смоделировано: при совпадении recvCount_ap_vld с тактом смены
// triggerGo флаг НЕ встаёт вообще, и замер зависает до таймаута. Окно
// однотактовое, то есть на плате это редкий невоспроизводимый `sample failed` —
// худший вид дефекта.
//
// Здесь установка выиграет всегда. Потерять из-за этого нечего: `recvCount`
// растёт только когда круг реально замкнулся, а хост между записью triggerGo и
// первым чтением sampleReady тратит миллисекунды (JTAG), то есть тысячи тактов —
// сброс успевает случиться задолго до опроса.
logic [31:0] trigger_r      = 32'b0;
logic        sample_ready_r = 1'b0;

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          trigger_r      <= 32'b0;
          sample_ready_r <= 1'b0;
     end else begin
          trigger_r <= triggerGo_reg;
          if (tap_t2_reply)
               sample_ready_r <= 1'b1;      // круг замкнулся
          else if (triggerGo_reg != trigger_r)
               sample_ready_r <= 1'b0;      // новый замер начат
     end
end

probe_control_s_axi #(
     .C_S_AXI_ADDR_WIDTH ( C_S_AXI_CONTROL_ADDR_WIDTH ),
     .C_S_AXI_DATA_WIDTH ( C_S_AXI_CONTROL_DATA_WIDTH )
) inst_control_s_axi (
     .ACLK           ( ap_clk                 ),
     .ARESET         ( ~ap_rst_n              ),
     .ACLK_EN        ( 1'b1                   ),
     .AWVALID        ( s_axi_control_awvalid  ),
     .AWREADY        ( s_axi_control_awready  ),
     .AWADDR         ( s_axi_control_awaddr   ),
     .WVALID         ( s_axi_control_wvalid   ),
     .WREADY         ( s_axi_control_wready   ),
     .WDATA          ( s_axi_control_wdata    ),
     .WSTRB          ( s_axi_control_wstrb    ),
     .ARVALID        ( s_axi_control_arvalid  ),
     .ARREADY        ( s_axi_control_arready  ),
     .ARADDR         ( s_axi_control_araddr   ),
     .RVALID         ( s_axi_control_rvalid   ),
     .RREADY         ( s_axi_control_rready   ),
     .RDATA          ( s_axi_control_rdata    ),
     .RRESP          ( s_axi_control_rresp    ),
     .BVALID         ( s_axi_control_bvalid   ),
     .BREADY         ( s_axi_control_bready   ),
     .BRESP          ( s_axi_control_bresp    ),
     .interrupt      ( interrupt              ),
     .ap_start       ( ap_start               ),
     .ap_done        ( ap_done                ),
     .ap_ready       ( ap_ready               ),
     .ap_idle        ( ap_idle                ),
     .enable         ( enable_reg             ),
     .serverIp       ( serverIp_reg           ),
     .serverPort     ( serverPort_reg         ),
     .listenPort     ( listenPort_reg         ),
     .msgBytes       ( msgBytes_reg           ),
     .triggerGo      ( triggerGo_reg          ),
     .connAttempts   ( connAttempts           ),
     .sentCount      ( sentCount              ),
     .recvCount      ( recvCount              ),
     .timeoutCount   ( timeoutCount           ),
     .echoRxCount    ( echoRxCount            ),
     .echoCount      ( echoCount              ),
     .listenAttempts ( listenAttempts         ),
     .portState      ( portState              ),
     // таймстемпы и готовность — из обёртки, а не из ядра
     .tsRequest      ( ts_request_r           ),
     .tsEchoIn       ( ts_echo_in_r           ),
     .tsEchoOut      ( ts_echo_out_r          ),
     .tsReply        ( ts_reply_r             ),
     .sampleReady    ( {31'b0, sample_ready_r} ),
     // врезки на axis_net_*: порог фильтра наружу, таймстемпы и счётчики внутрь
     .minWords       ( minWords_reg           ),
     .tsNetTxA       ( ts_net_tx_a_r          ),
     .tsNetRxB       ( ts_net_rx_b_r          ),
     .tsNetTxB       ( ts_net_tx_b_r          ),
     .tsNetRxA       ( ts_net_rx_a_r          ),
     .netFrameCountA ( netFrameCountA         ),
     .netFrameCountB ( netFrameCountB         ),
     .netFrameDropA  ( netFrameDropA          ),
     .netFrameDropB  ( netFrameDropB          )
);

// ── HLS-ядро ─────────────────────────────────────────────────────────────────
//
// Имя модуля задаётся при упаковке IP (create_ip -module_name
// hls_echo_probe_dual_krnl_ip, см. package_hls_echo_probe_dual_krnl.tcl).
//
// Скаляры идут ПРОВОДАМИ: ap_ctrl_none-ядро видит их каждый такт, поэтому
// момент записи по JTAG не важен. Для triggerGo это не удобство, а условие
// работы — см. шапку.
hls_echo_probe_dual_krnl_ip hls_echo_probe_dual_krnl_inst (
     .ap_clk   ( ap_clk   ),
     .ap_rst_n ( ap_rst_n ),

     // Блочный протокол -- напрямую от probe_control_s_axi. При ap_ctrl_none этих
     // портов у ядра не было вообще, и запустить его было нечем; см. пояснение
     // выше, где раньше подделывался ap_done.
     .ap_start ( ap_start ),
     .ap_done  ( ap_done  ),
     .ap_ready ( ap_ready ),
     .ap_idle  ( ap_idle  ),

     // половина a
     .s_axis_udp_rx_a_TVALID              ( s_axis_udp_rx_a_tvalid              ),
     .s_axis_udp_rx_a_TREADY              ( s_axis_udp_rx_a_tready              ),
     .s_axis_udp_rx_a_TDATA               ( s_axis_udp_rx_a_tdata               ),
     .s_axis_udp_rx_a_TKEEP               ( s_axis_udp_rx_a_tkeep               ),
     .s_axis_udp_rx_a_TLAST               ( s_axis_udp_rx_a_tlast               ),

     .m_axis_udp_tx_a_TVALID              ( m_axis_udp_tx_a_tvalid              ),
     .m_axis_udp_tx_a_TREADY              ( m_axis_udp_tx_a_tready              ),
     .m_axis_udp_tx_a_TDATA               ( m_axis_udp_tx_a_tdata               ),
     .m_axis_udp_tx_a_TKEEP               ( m_axis_udp_tx_a_tkeep               ),
     .m_axis_udp_tx_a_TLAST               ( m_axis_udp_tx_a_tlast               ),

     .s_axis_udp_rx_meta_a_TVALID         ( s_axis_udp_rx_meta_a_tvalid         ),
     .s_axis_udp_rx_meta_a_TREADY         ( s_axis_udp_rx_meta_a_tready         ),
     .s_axis_udp_rx_meta_a_TDATA          ( s_axis_udp_rx_meta_a_tdata          ),
     .s_axis_udp_rx_meta_a_TKEEP          ( s_axis_udp_rx_meta_a_tkeep          ),
     .s_axis_udp_rx_meta_a_TLAST          ( s_axis_udp_rx_meta_a_tlast          ),

     .m_axis_udp_tx_meta_a_TVALID         ( m_axis_udp_tx_meta_a_tvalid         ),
     .m_axis_udp_tx_meta_a_TREADY         ( m_axis_udp_tx_meta_a_tready         ),
     .m_axis_udp_tx_meta_a_TDATA          ( m_axis_udp_tx_meta_a_tdata          ),
     .m_axis_udp_tx_meta_a_TKEEP          ( m_axis_udp_tx_meta_a_tkeep          ),
     .m_axis_udp_tx_meta_a_TLAST          ( m_axis_udp_tx_meta_a_tlast          ),

     .m_axis_tcp_listen_port_a_TVALID     ( m_axis_tcp_listen_port_a_tvalid     ),
     .m_axis_tcp_listen_port_a_TREADY     ( m_axis_tcp_listen_port_a_tready     ),
     .m_axis_tcp_listen_port_a_TDATA      ( m_axis_tcp_listen_port_a_tdata      ),
     .m_axis_tcp_listen_port_a_TKEEP      ( m_axis_tcp_listen_port_a_tkeep      ),
     .m_axis_tcp_listen_port_a_TLAST      ( m_axis_tcp_listen_port_a_tlast      ),

     .s_axis_tcp_port_status_a_TVALID     ( s_axis_tcp_port_status_a_tvalid     ),
     .s_axis_tcp_port_status_a_TREADY     ( s_axis_tcp_port_status_a_tready     ),
     .s_axis_tcp_port_status_a_TDATA      ( s_axis_tcp_port_status_a_tdata      ),
     .s_axis_tcp_port_status_a_TKEEP      ( s_axis_tcp_port_status_a_tkeep      ),
     .s_axis_tcp_port_status_a_TLAST      ( s_axis_tcp_port_status_a_tlast      ),

     .m_axis_tcp_open_connection_a_TVALID ( m_axis_tcp_open_connection_a_tvalid ),
     .m_axis_tcp_open_connection_a_TREADY ( m_axis_tcp_open_connection_a_tready ),
     .m_axis_tcp_open_connection_a_TDATA  ( m_axis_tcp_open_connection_a_tdata  ),
     .m_axis_tcp_open_connection_a_TKEEP  ( m_axis_tcp_open_connection_a_tkeep  ),
     .m_axis_tcp_open_connection_a_TLAST  ( m_axis_tcp_open_connection_a_tlast  ),

     .s_axis_tcp_open_status_a_TVALID     ( s_axis_tcp_open_status_a_tvalid     ),
     .s_axis_tcp_open_status_a_TREADY     ( s_axis_tcp_open_status_a_tready     ),
     .s_axis_tcp_open_status_a_TDATA      ( s_axis_tcp_open_status_a_tdata      ),
     .s_axis_tcp_open_status_a_TKEEP      ( s_axis_tcp_open_status_a_tkeep      ),
     .s_axis_tcp_open_status_a_TLAST      ( s_axis_tcp_open_status_a_tlast      ),

     .m_axis_tcp_close_connection_a_TVALID( m_axis_tcp_close_connection_a_tvalid),
     .m_axis_tcp_close_connection_a_TREADY( m_axis_tcp_close_connection_a_tready),
     .m_axis_tcp_close_connection_a_TDATA ( m_axis_tcp_close_connection_a_tdata ),
     .m_axis_tcp_close_connection_a_TKEEP ( m_axis_tcp_close_connection_a_tkeep ),
     .m_axis_tcp_close_connection_a_TLAST ( m_axis_tcp_close_connection_a_tlast ),

     .s_axis_tcp_notification_a_TVALID    ( s_axis_tcp_notification_a_tvalid    ),
     .s_axis_tcp_notification_a_TREADY    ( s_axis_tcp_notification_a_tready    ),
     .s_axis_tcp_notification_a_TDATA     ( s_axis_tcp_notification_a_tdata     ),
     .s_axis_tcp_notification_a_TKEEP     ( s_axis_tcp_notification_a_tkeep     ),
     .s_axis_tcp_notification_a_TLAST     ( s_axis_tcp_notification_a_tlast     ),

     .m_axis_tcp_read_pkg_a_TVALID        ( m_axis_tcp_read_pkg_a_tvalid        ),
     .m_axis_tcp_read_pkg_a_TREADY        ( m_axis_tcp_read_pkg_a_tready        ),
     .m_axis_tcp_read_pkg_a_TDATA         ( m_axis_tcp_read_pkg_a_tdata         ),
     .m_axis_tcp_read_pkg_a_TKEEP         ( m_axis_tcp_read_pkg_a_tkeep         ),
     .m_axis_tcp_read_pkg_a_TLAST         ( m_axis_tcp_read_pkg_a_tlast         ),

     .s_axis_tcp_rx_meta_a_TVALID         ( s_axis_tcp_rx_meta_a_tvalid         ),
     .s_axis_tcp_rx_meta_a_TREADY         ( s_axis_tcp_rx_meta_a_tready         ),
     .s_axis_tcp_rx_meta_a_TDATA          ( s_axis_tcp_rx_meta_a_tdata          ),
     .s_axis_tcp_rx_meta_a_TKEEP          ( s_axis_tcp_rx_meta_a_tkeep          ),
     .s_axis_tcp_rx_meta_a_TLAST          ( s_axis_tcp_rx_meta_a_tlast          ),

     .s_axis_tcp_rx_data_a_TVALID         ( s_axis_tcp_rx_data_a_tvalid         ),
     .s_axis_tcp_rx_data_a_TREADY         ( s_axis_tcp_rx_data_a_tready         ),
     .s_axis_tcp_rx_data_a_TDATA          ( s_axis_tcp_rx_data_a_tdata          ),
     .s_axis_tcp_rx_data_a_TKEEP          ( s_axis_tcp_rx_data_a_tkeep          ),
     .s_axis_tcp_rx_data_a_TLAST          ( s_axis_tcp_rx_data_a_tlast          ),

     .m_axis_tcp_tx_meta_a_TVALID         ( m_axis_tcp_tx_meta_a_tvalid         ),
     .m_axis_tcp_tx_meta_a_TREADY         ( m_axis_tcp_tx_meta_a_tready         ),
     .m_axis_tcp_tx_meta_a_TDATA          ( m_axis_tcp_tx_meta_a_tdata          ),
     .m_axis_tcp_tx_meta_a_TKEEP          ( m_axis_tcp_tx_meta_a_tkeep          ),
     .m_axis_tcp_tx_meta_a_TLAST          ( m_axis_tcp_tx_meta_a_tlast          ),

     .m_axis_tcp_tx_data_a_TVALID         ( m_axis_tcp_tx_data_a_tvalid         ),
     .m_axis_tcp_tx_data_a_TREADY         ( m_axis_tcp_tx_data_a_tready         ),
     .m_axis_tcp_tx_data_a_TDATA          ( m_axis_tcp_tx_data_a_tdata          ),
     .m_axis_tcp_tx_data_a_TKEEP          ( m_axis_tcp_tx_data_a_tkeep          ),
     .m_axis_tcp_tx_data_a_TLAST          ( m_axis_tcp_tx_data_a_tlast          ),

     .s_axis_tcp_tx_status_a_TVALID       ( s_axis_tcp_tx_status_a_tvalid       ),
     .s_axis_tcp_tx_status_a_TREADY       ( s_axis_tcp_tx_status_a_tready       ),
     .s_axis_tcp_tx_status_a_TDATA        ( s_axis_tcp_tx_status_a_tdata        ),
     .s_axis_tcp_tx_status_a_TKEEP        ( s_axis_tcp_tx_status_a_tkeep        ),
     .s_axis_tcp_tx_status_a_TLAST        ( s_axis_tcp_tx_status_a_tlast        ),

     // половина b
     .s_axis_udp_rx_b_TVALID              ( s_axis_udp_rx_b_tvalid              ),
     .s_axis_udp_rx_b_TREADY              ( s_axis_udp_rx_b_tready              ),
     .s_axis_udp_rx_b_TDATA               ( s_axis_udp_rx_b_tdata               ),
     .s_axis_udp_rx_b_TKEEP               ( s_axis_udp_rx_b_tkeep               ),
     .s_axis_udp_rx_b_TLAST               ( s_axis_udp_rx_b_tlast               ),

     .m_axis_udp_tx_b_TVALID              ( m_axis_udp_tx_b_tvalid              ),
     .m_axis_udp_tx_b_TREADY              ( m_axis_udp_tx_b_tready              ),
     .m_axis_udp_tx_b_TDATA               ( m_axis_udp_tx_b_tdata               ),
     .m_axis_udp_tx_b_TKEEP               ( m_axis_udp_tx_b_tkeep               ),
     .m_axis_udp_tx_b_TLAST               ( m_axis_udp_tx_b_tlast               ),

     .s_axis_udp_rx_meta_b_TVALID         ( s_axis_udp_rx_meta_b_tvalid         ),
     .s_axis_udp_rx_meta_b_TREADY         ( s_axis_udp_rx_meta_b_tready         ),
     .s_axis_udp_rx_meta_b_TDATA          ( s_axis_udp_rx_meta_b_tdata          ),
     .s_axis_udp_rx_meta_b_TKEEP          ( s_axis_udp_rx_meta_b_tkeep          ),
     .s_axis_udp_rx_meta_b_TLAST          ( s_axis_udp_rx_meta_b_tlast          ),

     .m_axis_udp_tx_meta_b_TVALID         ( m_axis_udp_tx_meta_b_tvalid         ),
     .m_axis_udp_tx_meta_b_TREADY         ( m_axis_udp_tx_meta_b_tready         ),
     .m_axis_udp_tx_meta_b_TDATA          ( m_axis_udp_tx_meta_b_tdata          ),
     .m_axis_udp_tx_meta_b_TKEEP          ( m_axis_udp_tx_meta_b_tkeep          ),
     .m_axis_udp_tx_meta_b_TLAST          ( m_axis_udp_tx_meta_b_tlast          ),

     .m_axis_tcp_listen_port_b_TVALID     ( m_axis_tcp_listen_port_b_tvalid     ),
     .m_axis_tcp_listen_port_b_TREADY     ( m_axis_tcp_listen_port_b_tready     ),
     .m_axis_tcp_listen_port_b_TDATA      ( m_axis_tcp_listen_port_b_tdata      ),
     .m_axis_tcp_listen_port_b_TKEEP      ( m_axis_tcp_listen_port_b_tkeep      ),
     .m_axis_tcp_listen_port_b_TLAST      ( m_axis_tcp_listen_port_b_tlast      ),

     .s_axis_tcp_port_status_b_TVALID     ( s_axis_tcp_port_status_b_tvalid     ),
     .s_axis_tcp_port_status_b_TREADY     ( s_axis_tcp_port_status_b_tready     ),
     .s_axis_tcp_port_status_b_TDATA      ( s_axis_tcp_port_status_b_tdata      ),
     .s_axis_tcp_port_status_b_TKEEP      ( s_axis_tcp_port_status_b_tkeep      ),
     .s_axis_tcp_port_status_b_TLAST      ( s_axis_tcp_port_status_b_tlast      ),

     .m_axis_tcp_open_connection_b_TVALID ( m_axis_tcp_open_connection_b_tvalid ),
     .m_axis_tcp_open_connection_b_TREADY ( m_axis_tcp_open_connection_b_tready ),
     .m_axis_tcp_open_connection_b_TDATA  ( m_axis_tcp_open_connection_b_tdata  ),
     .m_axis_tcp_open_connection_b_TKEEP  ( m_axis_tcp_open_connection_b_tkeep  ),
     .m_axis_tcp_open_connection_b_TLAST  ( m_axis_tcp_open_connection_b_tlast  ),

     .s_axis_tcp_open_status_b_TVALID     ( s_axis_tcp_open_status_b_tvalid     ),
     .s_axis_tcp_open_status_b_TREADY     ( s_axis_tcp_open_status_b_tready     ),
     .s_axis_tcp_open_status_b_TDATA      ( s_axis_tcp_open_status_b_tdata      ),
     .s_axis_tcp_open_status_b_TKEEP      ( s_axis_tcp_open_status_b_tkeep      ),
     .s_axis_tcp_open_status_b_TLAST      ( s_axis_tcp_open_status_b_tlast      ),

     .m_axis_tcp_close_connection_b_TVALID( m_axis_tcp_close_connection_b_tvalid),
     .m_axis_tcp_close_connection_b_TREADY( m_axis_tcp_close_connection_b_tready),
     .m_axis_tcp_close_connection_b_TDATA ( m_axis_tcp_close_connection_b_tdata ),
     .m_axis_tcp_close_connection_b_TKEEP ( m_axis_tcp_close_connection_b_tkeep ),
     .m_axis_tcp_close_connection_b_TLAST ( m_axis_tcp_close_connection_b_tlast ),

     .s_axis_tcp_notification_b_TVALID    ( s_axis_tcp_notification_b_tvalid    ),
     .s_axis_tcp_notification_b_TREADY    ( s_axis_tcp_notification_b_tready    ),
     .s_axis_tcp_notification_b_TDATA     ( s_axis_tcp_notification_b_tdata     ),
     .s_axis_tcp_notification_b_TKEEP     ( s_axis_tcp_notification_b_tkeep     ),
     .s_axis_tcp_notification_b_TLAST     ( s_axis_tcp_notification_b_tlast     ),

     .m_axis_tcp_read_pkg_b_TVALID        ( m_axis_tcp_read_pkg_b_tvalid        ),
     .m_axis_tcp_read_pkg_b_TREADY        ( m_axis_tcp_read_pkg_b_tready        ),
     .m_axis_tcp_read_pkg_b_TDATA         ( m_axis_tcp_read_pkg_b_tdata         ),
     .m_axis_tcp_read_pkg_b_TKEEP         ( m_axis_tcp_read_pkg_b_tkeep         ),
     .m_axis_tcp_read_pkg_b_TLAST         ( m_axis_tcp_read_pkg_b_tlast         ),

     .s_axis_tcp_rx_meta_b_TVALID         ( s_axis_tcp_rx_meta_b_tvalid         ),
     .s_axis_tcp_rx_meta_b_TREADY         ( s_axis_tcp_rx_meta_b_tready         ),
     .s_axis_tcp_rx_meta_b_TDATA          ( s_axis_tcp_rx_meta_b_tdata          ),
     .s_axis_tcp_rx_meta_b_TKEEP          ( s_axis_tcp_rx_meta_b_tkeep          ),
     .s_axis_tcp_rx_meta_b_TLAST          ( s_axis_tcp_rx_meta_b_tlast          ),

     .s_axis_tcp_rx_data_b_TVALID         ( s_axis_tcp_rx_data_b_tvalid         ),
     .s_axis_tcp_rx_data_b_TREADY         ( s_axis_tcp_rx_data_b_tready         ),
     .s_axis_tcp_rx_data_b_TDATA          ( s_axis_tcp_rx_data_b_tdata          ),
     .s_axis_tcp_rx_data_b_TKEEP          ( s_axis_tcp_rx_data_b_tkeep          ),
     .s_axis_tcp_rx_data_b_TLAST          ( s_axis_tcp_rx_data_b_tlast          ),

     .m_axis_tcp_tx_meta_b_TVALID         ( m_axis_tcp_tx_meta_b_tvalid         ),
     .m_axis_tcp_tx_meta_b_TREADY         ( m_axis_tcp_tx_meta_b_tready         ),
     .m_axis_tcp_tx_meta_b_TDATA          ( m_axis_tcp_tx_meta_b_tdata          ),
     .m_axis_tcp_tx_meta_b_TKEEP          ( m_axis_tcp_tx_meta_b_tkeep          ),
     .m_axis_tcp_tx_meta_b_TLAST          ( m_axis_tcp_tx_meta_b_tlast          ),

     .m_axis_tcp_tx_data_b_TVALID         ( m_axis_tcp_tx_data_b_tvalid         ),
     .m_axis_tcp_tx_data_b_TREADY         ( m_axis_tcp_tx_data_b_tready         ),
     .m_axis_tcp_tx_data_b_TDATA          ( m_axis_tcp_tx_data_b_tdata          ),
     .m_axis_tcp_tx_data_b_TKEEP          ( m_axis_tcp_tx_data_b_tkeep          ),
     .m_axis_tcp_tx_data_b_TLAST          ( m_axis_tcp_tx_data_b_tlast          ),

     .s_axis_tcp_tx_status_b_TVALID       ( s_axis_tcp_tx_status_b_tvalid       ),
     .s_axis_tcp_tx_status_b_TREADY       ( s_axis_tcp_tx_status_b_tready       ),
     .s_axis_tcp_tx_status_b_TDATA        ( s_axis_tcp_tx_status_b_tdata        ),
     .s_axis_tcp_tx_status_b_TKEEP        ( s_axis_tcp_tx_status_b_tkeep        ),
     .s_axis_tcp_tx_status_b_TLAST        ( s_axis_tcp_tx_status_b_tlast        ),

     // ── скаляры: провода, а не регистры ──────────────────────────────────
     .serverIp       ( serverIp_reg   ),
     .serverPort     ( serverPort_reg ),
     .listenPort     ( listenPort_reg ),
     .msgBytes       ( msgBytes_reg   ),
     .triggerGo      ( triggerGo_reg  ),
     // ОДИН регистр enable (0x10) на ТРИ порта ядра. Снаружи по-прежнему один
     // enable — адресная карта не менялась.
     //
     // Раздельные порты нужны потому, что при одном аргументе его читали три
     // стадии, и HLS раздавал такой скаляр несимметрично: часть читателей
     // получала провод, часть — FIFO-канал с блокировкой. Заблокированная
     // стадия останавливала весь DATAFLOW-регион. Именно так сломался
     // hls_dual_echo_krnl на плате: enable=1 читался обратно, а ядро не
     // исполнялось вовсе.
     // enableConn/enableTraffic/enableListen БОЛЬШЕ НЕ ПОДКЛЮЧАЮТСЯ: у ядра нет
     // таких портов. Их роль взял ap_start -- ядро ap_ctrl_hs и стоит в ap_idle,
     // пока хост не записал ap_ctrl, поэтому раньше network_start к стеку не
     // обратится. Регистр 0x10 в probe_control_s_axi оставлен: он читается
     // обратно и служит признаком «битстрим жив, регистры отвечают», а
     // jtag_ctrl.tcl и адресная карта не меняются.

     // ── счётчики событий наружу ──
     //
     // ap_vld каждого — строб для защёлки таймстемпа (см. выше). Таймстемпов и
     // sampleReady у ядра больше нет: передать в него единую шкалу времени не
     // получается, HLS размножает такой скаляр несимметрично.
     .connAttempts       ( connAttempts       ),
     .sentCount          ( sentCount          ),
     .sentCount_ap_vld   ( sentCount_ap_vld   ),
     .recvCount          ( recvCount          ),
     .recvCount_ap_vld   ( recvCount_ap_vld   ),
     .timeoutCount       ( timeoutCount       ),
     .echoRxCount        ( echoRxCount        ),
     .echoRxCount_ap_vld ( echoRxCount_ap_vld ),
     .echoCount          ( echoCount          ),
     .echoCount_ap_vld   ( echoCount_ap_vld   ),
     .listenAttempts     ( listenAttempts     ),
     .portState          ( portState          )
);

endmodule

`default_nettype wire
