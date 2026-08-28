// =============================================================================
// hls_pp_dual_krnl_wrapper -- четыре врезки времени на половине a
// =============================================================================
//
// ЧТО ИЗМЕРЯЕТ. Четыре точки на пути одного пакета через QSFP0:
//
//     T2   кадр пришёл на axis_net_rx_a   край CMAC -> стек
//     t2   payload дошёл до ядра          rx_data_a.tlast
//     t1   ядро отдало payload            tx_data_a.tlast
//     T1   кадр ушёл на axis_net_tx_a     стек -> край CMAC
//
// Три интервала, которые из них считаются НА ХОСТЕ, не здесь:
//
//     t2 - T2   приём стеком (TOE RX + DDR)
//     t1 - t2   наше ядро (pp_echo: store-and-forward)
//     T1 - t1   передача стеком (TOE TX + сегментация + CRC)
//
// ПОЧЕМУ ВЫЧИТАНИЕ НА ХОСТЕ. Сырые метки позволяют проверить согласованность:
// если (t2-T2)+(t1-t2)+(T1-t1) != (T1-T2), значит метки от разных пакетов.
// С готовыми дельтами такой проверки нет -- их сумма сойдётся всегда. Тот же
// приём в epd_raw у probe (колонка status с флагом TORN).
//
// ОДИН СЧЁТЧИК НА ВСЕ ЧЕТЫРЕ ТОЧКИ. Отдельные счётчики на стадию совпадали бы
// только при II=1 у всех, а у нас смешанный II, и csim такое не поймал бы.
// Здесь один cycle_counter в HDL -- см. память shared-timebase-across-dataflow.
//
// СТРОБЫ -- tvalid & tready & tlast, НЕ ap_vld. ap_vld срабатывает на ap_done
// стадии, а не на передаче слова, и метки разъезжались бы невидимо
// (timestamp-strobes-from-bus-not-ap-vld). Здесь везде фронт передачи
// ПОСЛЕДНЕГО слова: для payload это конец сообщения, для кадра -- конец кадра.
//
// axis_net ИДЁТ НАСКВОЗЬ. Обёртка врезается в шину между cmac_krnl и
// network_krnl, но данные не трогает: провода assign-ом, tready обратно.
// Регистров в тракте нет, задержки не добавляется. Фильтр и защёлки только
// подсматривают.
//
// ЧТО ЗДЕСЬ НЕ ИЗМЕРЯЕТСЯ: CMAC (~150-200 нс на сторону) и кабель. Они за
// врезкой, со стороны провода. Для задачи это и не нужно -- интересна
// задержка, которой мы управляем.
`timescale 1ns / 1ps
`default_nettype none

// ПАРАМЕТРЫ ЕСТЬ, НО ТОЛЬКО integer -- И ОБА НУЖНЫ.
//
// C_S_AXI_CONTROL_ADDR_WIDTH обязателен: из него ipx выводит РАЗМЕР memory map
// для s_axi_control. Без параметра размер неизвестен, memory map не создаётся,
// и в BD у ячейки НЕТ адресного сегмента.
//
// Симптом на плате (прогон 25.08): network_krnl отвечает нормально, а user-ядро
// читается как 0xDEC0DEE3 -- то есть по этому адресу вообще ничего нет.
// assign_bd_address не нашёл сегмента, проверка адреса в build_bd.tcl молча
// пропустилась (там `if {[llength $seg_user] > 0}`), и адрес остался случайным.
//
// Так же у probe (C_S_AXI_CONTROL_ADDR_WIDTH = 12) и у network_krnl
// (C_S_AXI_ADDR_WIDTH) -- то есть у всех, кто на этой плате читается по JTAG.
//
// ВЕКТОРНЫЕ параметры при этом по-прежнему запрещены: parameter [47:0]
// PP_MARKER ломал разбор обёртки целиком (три прогона pack без объяснения).
// integer ipx понимает, вектор -- нет. Ограничение в test_hdl_lint именно на
// векторные, не на все.
//
// ЧТО БЫЛО ДО ЭТОГО:
//
// Здесь стоял parameter [47:0] PP_MARKER -- 48-битный вектор. Именно на нём
// Vivado не разбирал обёртку: три прогона pack показывали
//
//     CRITICAL WARNING [filemgmt 20-742] top can not be validated
//     -> Vivado взял: lat_fifo
//
// без единой строки о причине. У probe, который через этот путь прошёл,
// параметры ТОЛЬКО integer (C_S_AXI_CONTROL_DATA_WIDTH и подобные) --
// векторных нет вовсе. Та же ловушка, что была в lat_fifo.v с DEPTH: ipx
// разбирает integer, а выражения над векторами -- нет.
//
// Маркер теперь localparam внутри модуля. Параметризация не нужна: инстанс
// один, значение задано в трёх местах (здесь, net_frame_filter.v, main.go) и
// сверяется тестом host/hls_pp_dual_krnl/marker_test.go.
module hls_pp_dual_krnl_wrapper #(
     parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32,
     parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 12
)(
     input  wire         ap_clk,
     input  wire         ap_rst_n,

     // ── AXI-Lite: регистры ядра ПЛЮС наши. Адреса ядра идут насквозь в
     //    control_s_axi HLS, наши перехватываются здесь (см. ниже).
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0] s_axi_control_awaddr,
     input  wire         s_axi_control_awvalid,
     output wire         s_axi_control_awready,
     input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0] s_axi_control_wdata,
     input  wire [3:0]   s_axi_control_wstrb,
     input  wire         s_axi_control_wvalid,
     output wire         s_axi_control_wready,
     output wire [1:0]   s_axi_control_bresp,
     output wire         s_axi_control_bvalid,
     input  wire         s_axi_control_bready,
     input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0] s_axi_control_araddr,
     input  wire         s_axi_control_arvalid,
     output wire         s_axi_control_arready,
     output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0] s_axi_control_rdata,
     output wire [1:0]   s_axi_control_rresp,
     output wire         s_axi_control_rvalid,
     input  wire         s_axi_control_rready,
     output wire         interrupt,

     // ── врезка в axis_net половины a: cmac_krnl_1 <-> network_krnl_1 ──
     //
     // RX: приходит от CMAC, уходит в стек.
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
     // TX: приходит от стека, уходит в CMAC.
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

     // ── 32 AXI-Stream ядра: идут НАСКВОЗЬ в инстанс ядра ниже.
     //
     // Список сгенерирован из .cpp (INTERFACE axis port), а не набран руками:
     // 160 сигналов, и опечатка в одном давала бы либо ошибку элаборации,
     // либо -- хуже -- молча висящий провод. Двусторонняя сверка портов
     // делается в package_*.tcl (память: wrapper-port-check-both-ways).
     input  wire         s_axis_udp_rx_tvalid,
     output wire         s_axis_udp_rx_tready,
     input  wire [511:0] s_axis_udp_rx_tdata,
     input  wire [63:0] s_axis_udp_rx_tkeep,
     input  wire         s_axis_udp_rx_tlast,
     output wire         m_axis_udp_tx_tvalid,
     input  wire         m_axis_udp_tx_tready,
     output wire [511:0] m_axis_udp_tx_tdata,
     output wire [63:0] m_axis_udp_tx_tkeep,
     output wire         m_axis_udp_tx_tlast,
     input  wire         s_axis_udp_rx_meta_tvalid,
     output wire         s_axis_udp_rx_meta_tready,
     input  wire [255:0] s_axis_udp_rx_meta_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_tkeep,
     input  wire         s_axis_udp_rx_meta_tlast,
     output wire         m_axis_udp_tx_meta_tvalid,
     input  wire         m_axis_udp_tx_meta_tready,
     output wire [255:0] m_axis_udp_tx_meta_tdata,
     output wire [31:0] m_axis_udp_tx_meta_tkeep,
     output wire         m_axis_udp_tx_meta_tlast,
     output wire         m_axis_tcp_listen_port_tvalid,
     input  wire         m_axis_tcp_listen_port_tready,
     output wire [15:0] m_axis_tcp_listen_port_tdata,
     output wire [1:0] m_axis_tcp_listen_port_tkeep,
     output wire         m_axis_tcp_listen_port_tlast,
     input  wire         s_axis_tcp_port_status_tvalid,
     output wire         s_axis_tcp_port_status_tready,
     input  wire [7:0] s_axis_tcp_port_status_tdata,
     input  wire [0:0] s_axis_tcp_port_status_tkeep,
     input  wire         s_axis_tcp_port_status_tlast,
     output wire         m_axis_tcp_open_connection_tvalid,
     input  wire         m_axis_tcp_open_connection_tready,
     output wire [63:0] m_axis_tcp_open_connection_tdata,
     output wire [7:0] m_axis_tcp_open_connection_tkeep,
     output wire         m_axis_tcp_open_connection_tlast,
     input  wire         s_axis_tcp_open_status_tvalid,
     output wire         s_axis_tcp_open_status_tready,
     input  wire [127:0] s_axis_tcp_open_status_tdata,
     input  wire [15:0] s_axis_tcp_open_status_tkeep,
     input  wire         s_axis_tcp_open_status_tlast,
     output wire         m_axis_tcp_close_connection_tvalid,
     input  wire         m_axis_tcp_close_connection_tready,
     output wire [15:0] m_axis_tcp_close_connection_tdata,
     output wire [1:0] m_axis_tcp_close_connection_tkeep,
     output wire         m_axis_tcp_close_connection_tlast,
     input  wire         s_axis_tcp_notification_tvalid,
     output wire         s_axis_tcp_notification_tready,
     input  wire [127:0] s_axis_tcp_notification_tdata,
     input  wire [15:0] s_axis_tcp_notification_tkeep,
     input  wire         s_axis_tcp_notification_tlast,
     output wire         m_axis_tcp_read_pkg_tvalid,
     input  wire         m_axis_tcp_read_pkg_tready,
     output wire [31:0] m_axis_tcp_read_pkg_tdata,
     output wire [3:0] m_axis_tcp_read_pkg_tkeep,
     output wire         m_axis_tcp_read_pkg_tlast,
     input  wire         s_axis_tcp_rx_meta_tvalid,
     output wire         s_axis_tcp_rx_meta_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_tdata,
     input  wire [1:0] s_axis_tcp_rx_meta_tkeep,
     input  wire         s_axis_tcp_rx_meta_tlast,
     input  wire         s_axis_tcp_rx_data_tvalid,
     output wire         s_axis_tcp_rx_data_tready,
     input  wire [511:0] s_axis_tcp_rx_data_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_tkeep,
     input  wire         s_axis_tcp_rx_data_tlast,
     output wire         m_axis_tcp_tx_meta_tvalid,
     input  wire         m_axis_tcp_tx_meta_tready,
     output wire [31:0] m_axis_tcp_tx_meta_tdata,
     output wire [3:0] m_axis_tcp_tx_meta_tkeep,
     output wire         m_axis_tcp_tx_meta_tlast,
     output wire         m_axis_tcp_tx_data_tvalid,
     input  wire         m_axis_tcp_tx_data_tready,
     output wire [511:0] m_axis_tcp_tx_data_tdata,
     output wire [63:0] m_axis_tcp_tx_data_tkeep,
     output wire         m_axis_tcp_tx_data_tlast,
     input  wire         s_axis_tcp_tx_status_tvalid,
     output wire         s_axis_tcp_tx_status_tready,
     input  wire [63:0] s_axis_tcp_tx_status_tdata,
     input  wire [7:0] s_axis_tcp_tx_status_tkeep,
     input  wire         s_axis_tcp_tx_status_tlast,
     input  wire         s_axis_udp_rx_b_tvalid,
     output wire         s_axis_udp_rx_b_tready,
     input  wire [511:0] s_axis_udp_rx_b_tdata,
     input  wire [63:0] s_axis_udp_rx_b_tkeep,
     input  wire         s_axis_udp_rx_b_tlast,
     output wire         m_axis_udp_tx_b_tvalid,
     input  wire         m_axis_udp_tx_b_tready,
     output wire [511:0] m_axis_udp_tx_b_tdata,
     output wire [63:0] m_axis_udp_tx_b_tkeep,
     output wire         m_axis_udp_tx_b_tlast,
     input  wire         s_axis_udp_rx_meta_b_tvalid,
     output wire         s_axis_udp_rx_meta_b_tready,
     input  wire [255:0] s_axis_udp_rx_meta_b_tdata,
     input  wire [31:0] s_axis_udp_rx_meta_b_tkeep,
     input  wire         s_axis_udp_rx_meta_b_tlast,
     output wire         m_axis_udp_tx_meta_b_tvalid,
     input  wire         m_axis_udp_tx_meta_b_tready,
     output wire [255:0] m_axis_udp_tx_meta_b_tdata,
     output wire [31:0] m_axis_udp_tx_meta_b_tkeep,
     output wire         m_axis_udp_tx_meta_b_tlast,
     output wire         m_axis_tcp_listen_port_b_tvalid,
     input  wire         m_axis_tcp_listen_port_b_tready,
     output wire [15:0] m_axis_tcp_listen_port_b_tdata,
     output wire [1:0] m_axis_tcp_listen_port_b_tkeep,
     output wire         m_axis_tcp_listen_port_b_tlast,
     input  wire         s_axis_tcp_port_status_b_tvalid,
     output wire         s_axis_tcp_port_status_b_tready,
     input  wire [7:0] s_axis_tcp_port_status_b_tdata,
     input  wire [0:0] s_axis_tcp_port_status_b_tkeep,
     input  wire         s_axis_tcp_port_status_b_tlast,
     output wire         m_axis_tcp_open_connection_b_tvalid,
     input  wire         m_axis_tcp_open_connection_b_tready,
     output wire [63:0] m_axis_tcp_open_connection_b_tdata,
     output wire [7:0] m_axis_tcp_open_connection_b_tkeep,
     output wire         m_axis_tcp_open_connection_b_tlast,
     input  wire         s_axis_tcp_open_status_b_tvalid,
     output wire         s_axis_tcp_open_status_b_tready,
     input  wire [127:0] s_axis_tcp_open_status_b_tdata,
     input  wire [15:0] s_axis_tcp_open_status_b_tkeep,
     input  wire         s_axis_tcp_open_status_b_tlast,
     output wire         m_axis_tcp_close_connection_b_tvalid,
     input  wire         m_axis_tcp_close_connection_b_tready,
     output wire [15:0] m_axis_tcp_close_connection_b_tdata,
     output wire [1:0] m_axis_tcp_close_connection_b_tkeep,
     output wire         m_axis_tcp_close_connection_b_tlast,
     input  wire         s_axis_tcp_notification_b_tvalid,
     output wire         s_axis_tcp_notification_b_tready,
     input  wire [127:0] s_axis_tcp_notification_b_tdata,
     input  wire [15:0] s_axis_tcp_notification_b_tkeep,
     input  wire         s_axis_tcp_notification_b_tlast,
     output wire         m_axis_tcp_read_pkg_b_tvalid,
     input  wire         m_axis_tcp_read_pkg_b_tready,
     output wire [31:0] m_axis_tcp_read_pkg_b_tdata,
     output wire [3:0] m_axis_tcp_read_pkg_b_tkeep,
     output wire         m_axis_tcp_read_pkg_b_tlast,
     input  wire         s_axis_tcp_rx_meta_b_tvalid,
     output wire         s_axis_tcp_rx_meta_b_tready,
     input  wire [15:0] s_axis_tcp_rx_meta_b_tdata,
     input  wire [1:0] s_axis_tcp_rx_meta_b_tkeep,
     input  wire         s_axis_tcp_rx_meta_b_tlast,
     input  wire         s_axis_tcp_rx_data_b_tvalid,
     output wire         s_axis_tcp_rx_data_b_tready,
     input  wire [511:0] s_axis_tcp_rx_data_b_tdata,
     input  wire [63:0] s_axis_tcp_rx_data_b_tkeep,
     input  wire         s_axis_tcp_rx_data_b_tlast,
     output wire         m_axis_tcp_tx_meta_b_tvalid,
     input  wire         m_axis_tcp_tx_meta_b_tready,
     output wire [31:0] m_axis_tcp_tx_meta_b_tdata,
     output wire [3:0] m_axis_tcp_tx_meta_b_tkeep,
     output wire         m_axis_tcp_tx_meta_b_tlast,
     output wire         m_axis_tcp_tx_data_b_tvalid,
     input  wire         m_axis_tcp_tx_data_b_tready,
     output wire [511:0] m_axis_tcp_tx_data_b_tdata,
     output wire [63:0] m_axis_tcp_tx_data_b_tkeep,
     output wire         m_axis_tcp_tx_data_b_tlast,
     input  wire         s_axis_tcp_tx_status_b_tvalid,
     output wire         s_axis_tcp_tx_status_b_tready,
     input  wire [63:0] s_axis_tcp_tx_status_b_tdata,
     input  wire [7:0] s_axis_tcp_tx_status_b_tkeep,
     input  wire         s_axis_tcp_tx_status_b_tlast,

     // Метки t2/t1 берём с шин rx_data/tx_data половины a. Отдельных
     // tap-портов не нужно: шины и так проходят через обёртку, подсматриваем
     // их прямо здесь.
     output wire         dbg_unused
);

// Заглушка выхода: нужна, чтобы синтез не выбросил обёртку целиком, если
// s_axi_control окажется неподключённым на раннем этапе отладки BD.
assign dbg_unused = 1'b0;

// Маркер задан localparam-ом ВНУТРИ net_frame_filter.v -- туда же смотрит
// тест marker_test.go. Передавать его сверху параметром нельзя: векторный
// параметр и есть то, на чём Vivado не разбирал обёртку.

// ── passthrough axis_net: провода насквозь, ни одного регистра ───────────────
assign m_axis_net_rx_a_tvalid = s_axis_net_rx_a_tvalid;
assign m_axis_net_rx_a_tdata  = s_axis_net_rx_a_tdata;
assign m_axis_net_rx_a_tkeep  = s_axis_net_rx_a_tkeep;
assign m_axis_net_rx_a_tlast  = s_axis_net_rx_a_tlast;
assign s_axis_net_rx_a_tready = m_axis_net_rx_a_tready;

assign m_axis_net_tx_a_tvalid = s_axis_net_tx_a_tvalid;
assign m_axis_net_tx_a_tdata  = s_axis_net_tx_a_tdata;
assign m_axis_net_tx_a_tkeep  = s_axis_net_tx_a_tkeep;
assign m_axis_net_tx_a_tlast  = s_axis_net_tx_a_tlast;
assign s_axis_net_tx_a_tready = m_axis_net_tx_a_tready;

// ── общая шкала времени ──────────────────────────────────────────────────────
//
// 32 бита при 165 МГц -- 26 секунд до переполнения. Разность 32-битных
// значений верна и через переход, поэтому сбрасывать не нужно и переполнение
// не мешает: (T1 - T2) считается по модулю 2^32.
reg [31:0] cycle_counter = 32'b0;
always @(posedge ap_clk) begin
     if (~ap_rst_n) cycle_counter <= 32'b0;
     else           cycle_counter <= cycle_counter + 32'd1;
end

// ── регистры управления, доступные хосту ────────────────────────────────────
//
// ОБЪЯВЛЕНЫ ЗДЕСЬ, ДО ПЕРВОГО ИСПОЛЬЗОВАНИЯ. Первая версия объявляла их ниже,
// рядом с автоматом AXI-Lite, а min_words_r читается инстансами фильтра
// выше -- то есть использование до объявления. Синтез это иногда прощает,
// парсер IP нет (память: xvlog-stricter-than-synth).
reg [31:0] min_words_r = 32'd2;   // порог фильтра, по умолчанию 2 слова
reg        fifo_clear;
reg        fifo_pop;

// ── фильтр «наш кадр» на обеих точках axis_net ──────────────────────────────
//
// Обоснование в шапке net_frame_filter.v; коротко: на axis_net идёт весь
// трафик стека, служебные кадры (ARP, чистый ACK, ICMP) укладываются в одно
// 512-битное слово, а SYN с опциями отсекается маркером.
//
// tready берём со стороны МАСТЕРА -- считается передача, а не предъявление.
wire        net_rx_ours, net_tx_ours;
wire [31:0] nf_cnt_rx, nf_cnt_tx, nf_drp_rx, nf_drp_tx;

net_frame_filter flt_rx (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_rx_a_tvalid), .tready(m_axis_net_rx_a_tready),
     .tlast(s_axis_net_rx_a_tlast),   .tdata(s_axis_net_rx_a_tdata),
     .min_words(min_words_r),
     .frame_ours(net_rx_ours),
     .count_ours(nf_cnt_rx), .count_drop(nf_drp_rx)
);

net_frame_filter flt_tx (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_tx_a_tvalid), .tready(m_axis_net_tx_a_tready),
     .tlast(s_axis_net_tx_a_tlast),   .tdata(s_axis_net_tx_a_tdata),
     .min_words(min_words_r),
     .frame_ours(net_tx_ours),
     .count_ours(nf_cnt_tx), .count_drop(nf_drp_tx)
);

// ── четыре строба ───────────────────────────────────────────────────────────
//
// Форма всюду одна: tvalid & tready & tlast. Не ap_vld -- он срабатывает на
// ap_done стадии, а не на передаче слова, и метки разъехались бы невидимо.
//
// На axis_net дополнительно требуется frame_ours: без него защёлка сработала
// бы на первом же ARP или ACK.
wire strobe_T2 = net_rx_ours;   // фильтр уже включает beat & tlast
wire strobe_T1 = net_tx_ours;
// Половина a: rx_data -- вход ядра (s_axis), tx_data -- выход (m_axis).
// tready берём тот же провод, что видит ядро: считается передача слова.
wire strobe_t2 = s_axis_tcp_rx_data_tvalid & s_axis_tcp_rx_data_tready
                                          & s_axis_tcp_rx_data_tlast;
wire strobe_t1 = m_axis_tcp_tx_data_tvalid & m_axis_tcp_tx_data_tready
                                          & m_axis_tcp_tx_data_tlast;

// ── сбор одного измерения ───────────────────────────────────────────────────
//
// СОСТОЯНИЕ, А НЕ ПРОСТЫЕ ЗАЩЁЛКИ. Простые регистры (как у probe) отдали бы
// хосту последний пакет, а нам нужна серия. Значит измерение надо собрать
// целиком и отдать в FIFO одним куском.
//
// ПОРЯДОК СОБЫТИЙ ЖЁСТКИЙ: T2 -> t2 -> t1 -> T1. Автомат идёт по нему и на
// любом отклонении начинает заново, а не склеивает метки разных пакетов.
//
// Отклонения, которые реально бывают:
//   * T2 пришёл повторно до t2 -- второй пакет догнал первый. Берём новый T2
//     (старое измерение потеряно, и это честнее склейки);
//   * t1/T1 без предшествующего T2 -- метка от пакета, чей T2 мы пропустили
//     (например, фильтр его не узнал). Игнорируем.
// БЕЗ typedef enum -- localparam, как в обёртке probe и в
// network_control_s_axi.sv. Причина: прогон pack 25.08 показал, что Vivado не
// разобрал обёртку и молча упаковал другой модуль. У probe, который через этот
// путь прошёл, НИ ОДНОГО typedef enum и ни одного always_ff -- только
// localparam и always @(posedge). Возвращаюсь к проверенной форме, а не
// выясняю, какая из конструкций виновата.
localparam [1:0] WAIT_T2 = 2'd0,
                 WAIT_t2 = 2'd1,
                 WAIT_t1 = 2'd2,
                 WAIT_T1 = 2'd3;
reg [1:0] st = WAIT_T2;

reg [31:0] ts_T2, ts_t2, ts_t1;
reg        meas_valid;          // строб записи в FIFO
reg [31:0] meas_dropped;        // сколько измерений порвалось на полпути

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          st           <= WAIT_T2;
          ts_T2        <= 32'b0;
          ts_t2        <= 32'b0;
          ts_t1        <= 32'b0;
          meas_valid   <= 1'b0;
          meas_dropped <= 32'b0;
     end else begin
          meas_valid <= 1'b0;      // строб на один такт

          case (st)
          WAIT_T2:
               if (strobe_T2) begin
                    ts_T2 <= cycle_counter;
                    st    <= WAIT_t2;
               end

          WAIT_t2:
               // Новый T2 раньше t2 -- пакеты пошли конвейером. Берём новый и
               // считаем прошлый порванным: склеить t2 второго пакета с T2
               // первого дало бы правдоподобное, но ложное число.
               if (strobe_T2) begin
                    ts_T2        <= cycle_counter;
                    meas_dropped <= meas_dropped + 32'd1;
               end else if (strobe_t2) begin
                    ts_t2 <= cycle_counter;
                    st    <= WAIT_t1;
               end

          WAIT_t1:
               if (strobe_T2) begin
                    ts_T2        <= cycle_counter;
                    st           <= WAIT_t2;
                    meas_dropped <= meas_dropped + 32'd1;
               end else if (strobe_t1) begin
                    ts_t1 <= cycle_counter;
                    st    <= WAIT_T1;
               end

          WAIT_T1:
               // T1 нашего кадра -- измерение готово.
               //
               // Тонкость: strobe_T2 и strobe_T1 могут прийти в одном такте
               // (следующий запрос уже входит, пока наш ответ выходит). Тогда
               // сначала закрываем текущее измерение, а новый T2 подхватываем
               // сразу же -- иначе он потерялся бы.
               if (strobe_T1) begin
                    meas_valid <= 1'b1;
                    if (strobe_T2) begin
                         ts_T2 <= cycle_counter;
                         st    <= WAIT_t2;
                    end else begin
                         st <= WAIT_T2;
                    end
               end else if (strobe_T2) begin
                    ts_T2        <= cycle_counter;
                    st           <= WAIT_t2;
                    meas_dropped <= meas_dropped + 32'd1;
               end
          endcase
     end
end

// Метка T1 берётся ПРЯМО с счётчика в такте strobe_T1, а не из регистра:
// meas_valid поднимается в том же такте, и FIFO защёлкивает всё четыре
// значения одновременно.
wire [127:0] meas_word = {cycle_counter, ts_t1, ts_t2, ts_T2};

// ── FIFO измерений ──────────────────────────────────────────────────────────
wire [31:0] fifo_rd_data, fifo_count, fifo_overflow;
wire        fifo_empty, fifo_full;

lat_fifo u_fifo (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .wr_en(meas_valid), .wr_data(meas_word),
     .clear(fifo_clear),
     .rd_pop(fifo_pop), .rd_data(fifo_rd_data),
     .count(fifo_count), .overflow(fifo_overflow),
     .empty(fifo_empty), .full(fifo_full)
);

// ── AXI-Lite: ОДИН автомат, разделение ПОСЛЕ рукопожатия ────────────────────
//
// ТРИ ДЕФЕКТА ПЕРВОЙ ВЕРСИИ, И ВСЕ ОТ ОДНОЙ ОШИБКИ -- решать, кому адрес,
// ДО того как адрес захвачен:
//
//   1. awready зависел от awaddr, а тот действителен ТОЛЬКО при awvalid.
//      До рукопожатия на шине мусор, и awready дребезжал между нашим
//      состоянием и k_awready ядра. Мастер мог увидеть готовность, подать
//      адрес -- и адрес уйти не туда. Правило нарушено прямо: zipcpu,
//      "The most common AXI mistake" -- условия приёма не должны зависеть
//      ни от чего, кроме VALID и READY.
//
//   2. awready поднимался сразу после приёма данных, не дожидаясь bready.
//      pp_raw делает четыре записи POP подряд -- два ответа схлопывались,
//      хост ждал bvalid вечно, JTAG висел. Спецификация: слейв НЕ готов
//      принимать новый адрес, пока BVALID высокий и BREADY низкий.
//
//   3. К ядру шли awaddr[5:0] -- шесть бит, а карта ядра доходит до 0x50.
//      Регистры с 0x40 читались бы как 0x00: ppState вернул бы ap_ctrl.
//      Самый тихий из трёх: всё отвечает, числа неверные.
//
// РЕШЕНИЕ: рукопожатие делает ОДИН автомат, ничего не зная про адрес.
// Адрес защёлкивается по aw_hs, и только потом решается, кому данные --
// нам или ядру. Форма автомата -- как в network_control_s_axi.sv, который
// работает на этой плате (ADDR_BITS=7, три состояния записи, два чтения).

// ── регистры управления, доступные хосту ────────────────────────────────────
// АДРЕСНАЯ КАРТА. У ядра 0x00..0x50 (сборка 25.08, xhls_pp_dual_krnl_hw.h).
// Наши регистры с 0x80: адрес умещается в 8 бит, ADDR_BITS=8 против 7 у
// network_krnl -- разница ровно в этом бите, он и различает.
// ШИРИНА АДРЕСА -- ЛИТЕРАЛОМ В КАЖДОМ МЕСТЕ, а не через параметр.
// Та же ловушка, что была в lat_fifo.v: parameter/localparam в размерности
// порта или константы -- и ipx-парсер не разворачивает выражение, модуль не
// собирается, а Vivado молча выбирает другой top.
// 8 бит: у ядра карта до 0x50, наши регистры с 0x80.
localparam [7:0] A_RD       = 8'h80;
localparam [7:0] A_POP      = 8'h84;
localparam [7:0] A_COUNT    = 8'h88;
localparam [7:0] A_OVF      = 8'h8c;
localparam [7:0] A_MINWORDS = 8'h90;
localparam [7:0] A_CNT_RX   = 8'h94;
localparam [7:0] A_DRP_RX   = 8'h98;
localparam [7:0] A_CNT_TX   = 8'h9c;
localparam [7:0] A_DRP_TX   = 8'ha0;
localparam [7:0] A_MEAS_DRP = 8'ha4;
localparam [7:0] A_CLEAR    = 8'ha8;

// ── запись: три состояния, как в network_control_s_axi ──────────────────────
localparam [1:0] WRIDLE = 2'd0, WRDATA = 2'd1, WRRESP = 2'd2;
reg [1:0] wstate = WRIDLE;
reg [7:0] waddr;

// ГОТОВНОСТЬ ЗАВИСИТ ТОЛЬКО ОТ СОСТОЯНИЯ. Ни awaddr, ни k_awready здесь
// нет -- иначе вернулись бы дефекты 1 и 2.
wire aw_hs = s_axi_control_awvalid & (wstate == WRIDLE);
wire w_hs  = s_axi_control_wvalid  & (wstate == WRDATA);
wire b_hs  = s_axi_control_bready  & (wstate == WRRESP);

// Кому адресована ЗАХВАЧЕННАЯ запись. Читается из waddr, который уже
// защёлкнут -- то есть после рукопожатия, когда адрес действителен.
wire wr_ours = (waddr >= A_RD);

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          wstate      <= WRIDLE;
          waddr       <= 8'b0;
          fifo_pop    <= 1'b0;
          fifo_clear  <= 1'b0;
          min_words_r <= 32'd2;
     end else begin
          fifo_pop   <= 1'b0;      // стробы ровно на один такт
          fifo_clear <= 1'b0;

          if (aw_hs) waddr <= s_axi_control_awaddr[7:0];

          case (wstate)
          WRIDLE:  if (aw_hs) wstate <= WRDATA;
          WRDATA:  if (w_hs) begin
                        if (wr_ours) begin
                             case (waddr)
                             A_POP:      fifo_pop    <= 1'b1;
                             A_CLEAR:    fifo_clear  <= 1'b1;
                             A_MINWORDS: min_words_r <= s_axi_control_wdata;
                             default: ;  // запись в R-регистр игнорируется
                             endcase
                        end
                        wstate <= WRRESP;
                   end
          WRRESP:  if (b_hs) wstate <= WRIDLE;
          endcase
     end
end

// ── чтение: два состояния ───────────────────────────────────────────────────
localparam RDIDLE = 1'd0, RDDATA = 1'd1;
reg rstate = RDIDLE;
reg [7:0] raddr;
reg [31:0] our_rdata;

wire ar_hs = s_axi_control_arvalid & (rstate == RDIDLE);
wire r_hs  = s_axi_control_rready  & (rstate == RDDATA);
wire rd_ours = (raddr >= A_RD);

always @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          rstate    <= RDIDLE;
          raddr     <= 8'b0;
          our_rdata <= 32'b0;
     end else begin
          if (ar_hs) begin
               raddr <= s_axi_control_araddr[7:0];
               // Защёлкиваем значение в том же такте, что и адрес: к моменту
               // RDDATA оно готово, лишнего такта не нужно.
               case (s_axi_control_araddr[7:0])
               A_RD:       our_rdata <= fifo_rd_data;
               A_COUNT:    our_rdata <= fifo_count;
               A_OVF:      our_rdata <= fifo_overflow;
               A_MINWORDS: our_rdata <= min_words_r;
               A_CNT_RX:   our_rdata <= nf_cnt_rx;
               A_DRP_RX:   our_rdata <= nf_drp_rx;
               A_CNT_TX:   our_rdata <= nf_cnt_tx;
               A_DRP_TX:   our_rdata <= nf_drp_tx;
               A_MEAS_DRP: our_rdata <= meas_dropped;
               // Неописанный адрес в НАШЕМ диапазоне -- явный маркер, а не
               // нуль: нуль читался бы как "счётчик пуст", то есть
               // правдоподобно и неверно.
               // Неописанный адрес -- ЯВНЫЙ МАРКЕР, а не нуль: нуль читался
               // бы как "счётчик пуст", то есть правдоподобно и неверно.
               //
               // Было 32'hBADA_DDR5 -- и это НЕ ЧИСЛО: R не шестнадцатеричная
               // цифра. Именно на этой строке Vivado обрывал разбор обёртки
               // (Syntax error near 'R5'), выбирал lat_fifo как top и молча
               // упаковывал его. Три прогона pack, и ни одного намёка на
               // причину, пока не добавил check_syntax.
               default:    our_rdata <= 32'hBADC0DE5;
               endcase
          end

          case (rstate)
          RDIDLE: if (ar_hs) rstate <= RDDATA;
          RDDATA: if (r_hs)  rstate <= RDIDLE;
          endcase
     end
end

// ── проброс к control_s_axi ядра ────────────────────────────────────────────
//
// БЛОК ПРОПАЛ ПРИ ПЕРЕПИСЫВАНИИ АРБИТРАЖА, и это нашёл check_syntax в прогоне
// 14:57: двенадцать сообщений "'k_awvalid' is not declared". Использование в
// инстансе осталось, объявления удалились вместе со старой логикой.
//
// Vivado при этом РАЗОБРАЛ модуль (top определился верно) и упаковал IP --
// то есть без check_syntax дефект дошёл бы до синтеза BD, где неподключённые
// провода превратились бы в постоянные нули: ядро не отвечало бы на AXI-Lite
// вообще, и выглядело бы это как "регистры не пишутся".
//
// КЛЮЧЕВОЕ: рукопожатия делает НАШ автомат, а ядру транзакция передаётся
// только если адрес его. Ответы ядра не ждём -- хосту уже ответили.
//
// Почему так можно: control_s_axi от HLS это обычные регистры. Запись
// применяется в такте w_hs, чтение отдаёт значение в такте ar_hs. Свои
// BVALID/RVALID он поднимает сам, но наружу они не идут, а BREADY/RREADY ему
// подаётся константной единицей -- иначе застрянет в WRRESP.
wire        k_awready, k_wready, k_bvalid, k_arready, k_rvalid;
wire [1:0]  k_bresp, k_rresp;
wire [31:0] k_rdata;
wire        k_interrupt;

// Отдаём ядру валидные строб-сигналы только на ЕГО транзакциях. Признак --
// адрес ниже нашего диапазона; на такте рукопожатия берём его с шины, дальше
// из защёлкнутого waddr/raddr.
wire k_awvalid = aw_hs & (s_axi_control_awaddr[7:0] < A_RD);
wire k_wvalid  = w_hs  & ~wr_ours;
wire k_arvalid = ar_hs & (s_axi_control_araddr[7:0] < A_RD);

// ── ответы хосту: полностью от НАШЕГО автомата ──────────────────────────────
//
// Ни awready, ни bvalid не зависят ни от адреса, ни от ядра -- ровно то, что
// требует спецификация AXI: условия приёма только от VALID/READY.
assign s_axi_control_awready = (wstate == WRIDLE);
assign s_axi_control_wready  = (wstate == WRDATA);
assign s_axi_control_bvalid  = (wstate == WRRESP);
assign s_axi_control_bresp   = 2'b00;   // OKAY всегда
assign s_axi_control_arready = (rstate == RDIDLE);
assign s_axi_control_rvalid  = (rstate == RDDATA);
assign s_axi_control_rresp   = 2'b00;
assign interrupt             = k_interrupt;

// Данные чтения: наш регистр или то, что отдало ядро. Выбор по raddr, который
// уже защёлкнут.
assign s_axi_control_rdata = rd_ours ? our_rdata : k_rdata;


// ── ЗАГЛУШКИ НЕИСПОЛЬЗУЕМЫХ ПОРТОВ: КОНСТАНТЫ, А НЕ HLS-СТАДИИ ──────────────
//
// Ядро больше не принимает эти потоки: из его сигнатуры удалены 23 порта,
// вместе с шестью tie_off_* из communication.hpp. Здесь они закрыты так, как
// это делает работающий iperf_krnl в src/hdl/user_krnl.sv:239 --
//
//     assign s_axis_udp_rx_tready = 1'b1;   // принимай и выбрасывай
//     assign m_axis_udp_tx_tvalid = 1'b0;   // не передавай НИКОГДА
//
// ПОЧЕМУ КОНСТАНТА, А НЕ ЗАГЛУШКА В HLS. tie_off_* были стадиями DATAFLOW:
// они участвовали в барьере, перезапускались вместе с pp_listen/pp_echo, и на
// каждом перезапуске исполняли `if (!localStream.empty())`, где HLS схлопнул
// empty_n в константу 1 (проверено по RTL: assign openConnection_empty_n =
// 1'b1, dout = 48'd0). Итог на плате 27.08: 3000 SYN к 0.0.0.0 и 513 ARP,
// TOE утонул в мусорных сессиях и настоящий SYN от ПК обслужить не смог.
//
// tvalid = 1'b0 -- провод на землю. В барьере не участвует, перезапускать
// нечего, отправить пакет физически невозможно.
//
// TDATA/TKEEP/TLAST у master-портов заданы нулями осознанно: при tvalid=0
// они не считываются, но оставлять их неподключёнными нельзя -- Vivado
// выведет предупреждение, а в BD получится плавающий вход.

assign m_axis_tcp_close_connection_tvalid = 1'b0;
assign m_axis_tcp_close_connection_tdata  = 16'b0;
assign m_axis_tcp_close_connection_tkeep  = 2'b0;
assign m_axis_tcp_close_connection_tlast  = 1'b0;

assign m_axis_tcp_close_connection_b_tvalid = 1'b0;
assign m_axis_tcp_close_connection_b_tdata  = 16'b0;
assign m_axis_tcp_close_connection_b_tkeep  = 2'b0;
assign m_axis_tcp_close_connection_b_tlast  = 1'b0;

assign m_axis_tcp_listen_port_b_tvalid = 1'b0;
assign m_axis_tcp_listen_port_b_tdata  = 16'b0;
assign m_axis_tcp_listen_port_b_tkeep  = 2'b0;
assign m_axis_tcp_listen_port_b_tlast  = 1'b0;

assign m_axis_tcp_open_connection_tvalid = 1'b0;
assign m_axis_tcp_open_connection_tdata  = 64'b0;
assign m_axis_tcp_open_connection_tkeep  = 8'b0;
assign m_axis_tcp_open_connection_tlast  = 1'b0;

assign m_axis_tcp_open_connection_b_tvalid = 1'b0;
assign m_axis_tcp_open_connection_b_tdata  = 64'b0;
assign m_axis_tcp_open_connection_b_tkeep  = 8'b0;
assign m_axis_tcp_open_connection_b_tlast  = 1'b0;

assign m_axis_tcp_read_pkg_b_tvalid = 1'b0;
assign m_axis_tcp_read_pkg_b_tdata  = 32'b0;
assign m_axis_tcp_read_pkg_b_tkeep  = 4'b0;
assign m_axis_tcp_read_pkg_b_tlast  = 1'b0;

assign m_axis_tcp_tx_data_b_tvalid = 1'b0;
assign m_axis_tcp_tx_data_b_tdata  = 512'b0;
assign m_axis_tcp_tx_data_b_tkeep  = 64'b0;
assign m_axis_tcp_tx_data_b_tlast  = 1'b0;

assign m_axis_tcp_tx_meta_b_tvalid = 1'b0;
assign m_axis_tcp_tx_meta_b_tdata  = 32'b0;
assign m_axis_tcp_tx_meta_b_tkeep  = 4'b0;
assign m_axis_tcp_tx_meta_b_tlast  = 1'b0;

assign m_axis_udp_tx_tvalid = 1'b0;
assign m_axis_udp_tx_tdata  = 512'b0;
assign m_axis_udp_tx_tkeep  = 64'b0;
assign m_axis_udp_tx_tlast  = 1'b0;

assign m_axis_udp_tx_b_tvalid = 1'b0;
assign m_axis_udp_tx_b_tdata  = 512'b0;
assign m_axis_udp_tx_b_tkeep  = 64'b0;
assign m_axis_udp_tx_b_tlast  = 1'b0;

assign m_axis_udp_tx_meta_tvalid = 1'b0;
assign m_axis_udp_tx_meta_tdata  = 256'b0;
assign m_axis_udp_tx_meta_tkeep  = 32'b0;
assign m_axis_udp_tx_meta_tlast  = 1'b0;

assign m_axis_udp_tx_meta_b_tvalid = 1'b0;
assign m_axis_udp_tx_meta_b_tdata  = 256'b0;
assign m_axis_udp_tx_meta_b_tkeep  = 32'b0;
assign m_axis_udp_tx_meta_b_tlast  = 1'b0;

assign s_axis_tcp_notification_b_tready = 1'b1;

assign s_axis_tcp_open_status_tready = 1'b1;

assign s_axis_tcp_open_status_b_tready = 1'b1;

assign s_axis_tcp_port_status_b_tready = 1'b1;

assign s_axis_tcp_rx_data_b_tready = 1'b1;

assign s_axis_tcp_rx_meta_b_tready = 1'b1;

assign s_axis_tcp_tx_status_b_tready = 1'b1;

assign s_axis_udp_rx_tready = 1'b1;

assign s_axis_udp_rx_b_tready = 1'b1;

assign s_axis_udp_rx_meta_tready = 1'b1;

assign s_axis_udp_rx_meta_b_tready = 1'b1;

// ── инстанс HLS-ядра ────────────────────────────────────────────────────────
//
// Имя модуля -- hls_pp_dual_krnl_ip: так его переименовывает create_ip в
// package_*.tcl. Порты AXI-Stream в верхнем регистре (_TVALID и т.п.) --
// так их генерирует HLS.
hls_pp_dual_krnl_ip u_krnl (
     .ap_clk   ( ap_clk   ),
     .ap_rst_n ( ap_rst_n ),

     .m_axis_tcp_listen_port_TVALID ( m_axis_tcp_listen_port_tvalid ),
     .m_axis_tcp_listen_port_TREADY ( m_axis_tcp_listen_port_tready ),
     .m_axis_tcp_listen_port_TDATA  ( m_axis_tcp_listen_port_tdata  ),
     .m_axis_tcp_listen_port_TKEEP  ( m_axis_tcp_listen_port_tkeep  ),
     .m_axis_tcp_listen_port_TLAST  ( m_axis_tcp_listen_port_tlast  ),
     .s_axis_tcp_port_status_TVALID ( s_axis_tcp_port_status_tvalid ),
     .s_axis_tcp_port_status_TREADY ( s_axis_tcp_port_status_tready ),
     .s_axis_tcp_port_status_TDATA  ( s_axis_tcp_port_status_tdata  ),
     .s_axis_tcp_port_status_TKEEP  ( s_axis_tcp_port_status_tkeep  ),
     .s_axis_tcp_port_status_TLAST  ( s_axis_tcp_port_status_tlast  ),
     .s_axis_tcp_notification_TVALID ( s_axis_tcp_notification_tvalid ),
     .s_axis_tcp_notification_TREADY ( s_axis_tcp_notification_tready ),
     .s_axis_tcp_notification_TDATA  ( s_axis_tcp_notification_tdata  ),
     .s_axis_tcp_notification_TKEEP  ( s_axis_tcp_notification_tkeep  ),
     .s_axis_tcp_notification_TLAST  ( s_axis_tcp_notification_tlast  ),
     .m_axis_tcp_read_pkg_TVALID ( m_axis_tcp_read_pkg_tvalid ),
     .m_axis_tcp_read_pkg_TREADY ( m_axis_tcp_read_pkg_tready ),
     .m_axis_tcp_read_pkg_TDATA  ( m_axis_tcp_read_pkg_tdata  ),
     .m_axis_tcp_read_pkg_TKEEP  ( m_axis_tcp_read_pkg_tkeep  ),
     .m_axis_tcp_read_pkg_TLAST  ( m_axis_tcp_read_pkg_tlast  ),
     .s_axis_tcp_rx_meta_TVALID ( s_axis_tcp_rx_meta_tvalid ),
     .s_axis_tcp_rx_meta_TREADY ( s_axis_tcp_rx_meta_tready ),
     .s_axis_tcp_rx_meta_TDATA  ( s_axis_tcp_rx_meta_tdata  ),
     .s_axis_tcp_rx_meta_TKEEP  ( s_axis_tcp_rx_meta_tkeep  ),
     .s_axis_tcp_rx_meta_TLAST  ( s_axis_tcp_rx_meta_tlast  ),
     .s_axis_tcp_rx_data_TVALID ( s_axis_tcp_rx_data_tvalid ),
     .s_axis_tcp_rx_data_TREADY ( s_axis_tcp_rx_data_tready ),
     .s_axis_tcp_rx_data_TDATA  ( s_axis_tcp_rx_data_tdata  ),
     .s_axis_tcp_rx_data_TKEEP  ( s_axis_tcp_rx_data_tkeep  ),
     .s_axis_tcp_rx_data_TLAST  ( s_axis_tcp_rx_data_tlast  ),
     .m_axis_tcp_tx_meta_TVALID ( m_axis_tcp_tx_meta_tvalid ),
     .m_axis_tcp_tx_meta_TREADY ( m_axis_tcp_tx_meta_tready ),
     .m_axis_tcp_tx_meta_TDATA  ( m_axis_tcp_tx_meta_tdata  ),
     .m_axis_tcp_tx_meta_TKEEP  ( m_axis_tcp_tx_meta_tkeep  ),
     .m_axis_tcp_tx_meta_TLAST  ( m_axis_tcp_tx_meta_tlast  ),
     .m_axis_tcp_tx_data_TVALID ( m_axis_tcp_tx_data_tvalid ),
     .m_axis_tcp_tx_data_TREADY ( m_axis_tcp_tx_data_tready ),
     .m_axis_tcp_tx_data_TDATA  ( m_axis_tcp_tx_data_tdata  ),
     .m_axis_tcp_tx_data_TKEEP  ( m_axis_tcp_tx_data_tkeep  ),
     .m_axis_tcp_tx_data_TLAST  ( m_axis_tcp_tx_data_tlast  ),
     .s_axis_tcp_tx_status_TVALID ( s_axis_tcp_tx_status_tvalid ),
     .s_axis_tcp_tx_status_TREADY ( s_axis_tcp_tx_status_tready ),
     .s_axis_tcp_tx_status_TDATA  ( s_axis_tcp_tx_status_tdata  ),
     .s_axis_tcp_tx_status_TKEEP  ( s_axis_tcp_tx_status_tkeep  ),
     .s_axis_tcp_tx_status_TLAST  ( s_axis_tcp_tx_status_tlast  ),

     // AXI-Lite ядра: только свой диапазон адресов.
     // ШИРИНА АДРЕСА -- ПОЛНАЯ, а не [5:0]. Первая версия резала до шести
     // бит, а карта ядра доходит до 0x50: регистры с 0x40 читались бы как
     // 0x00, то есть ppState возвращал бы ap_ctrl. Дефект тихий -- всё
     // отвечает, числа неверные. Сколько бит у порта на самом деле, знает
     // сгенерированный IP; передаём весь адрес, лишнее Vivado обрежет по
     // объявленной ширине -- и предупредит, если не хватит.
     .s_axi_control_AWADDR  ( s_axi_control_awaddr ),
     .s_axi_control_AWVALID ( k_awvalid            ),
     .s_axi_control_AWREADY ( k_awready            ),
     .s_axi_control_WDATA   ( s_axi_control_wdata  ),
     .s_axi_control_WSTRB   ( s_axi_control_wstrb  ),
     .s_axi_control_WVALID  ( k_wvalid             ),
     .s_axi_control_WREADY  ( k_wready             ),
     .s_axi_control_BRESP   ( k_bresp              ),
     .s_axi_control_BVALID  ( k_bvalid             ),
     // BREADY и RREADY ядру -- ПОСТОЯННАЯ ЕДИНИЦА. Его ответы наружу не
     // идут (хосту отвечает наш автомат), но канал нельзя оставить
     // висящим: иначе control_s_axi ядра застрянет в WRRESP и следующую
     // запись не примет.
     .s_axi_control_BREADY  ( 1'b1                 ),
     .s_axi_control_ARADDR  ( s_axi_control_araddr ),
     .s_axi_control_ARVALID ( k_arvalid            ),
     .s_axi_control_ARREADY ( k_arready            ),
     .s_axi_control_RDATA   ( k_rdata              ),
     .s_axi_control_RRESP   ( k_rresp              ),
     .s_axi_control_RVALID  ( k_rvalid             ),
     .s_axi_control_RREADY  ( 1'b1                 ),
     .interrupt             ( k_interrupt          )
);

endmodule

`default_nettype wire
