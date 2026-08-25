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

module hls_pp_dual_krnl_wrapper #(
     // Порог длины кадра в 512-битных словах и маркер -- см. net_frame_filter.v.
     // Значение маркера должно совпадать с тем, что пишет ppclient в
     // payload[4..9] (host/hls_pp_dual_krnl/main.go, var marker).
     parameter [47:0] PP_MARKER = 48'h5A3C96E1B7D2
)(
     input  wire         ap_clk,
     input  wire         ap_rst_n,

     // ── AXI-Lite: регистры ядра ПЛЮС наши. Адреса ядра идут насквозь в
     //    control_s_axi HLS, наши перехватываются здесь (см. ниже).
     input  wire [11:0]  s_axi_control_awaddr,
     input  wire         s_axi_control_awvalid,
     output wire         s_axi_control_awready,
     input  wire [31:0]  s_axi_control_wdata,
     input  wire [3:0]   s_axi_control_wstrb,
     input  wire         s_axi_control_wvalid,
     output wire         s_axi_control_wready,
     output wire [1:0]   s_axi_control_bresp,
     output wire         s_axi_control_bvalid,
     input  wire         s_axi_control_bready,
     input  wire [11:0]  s_axi_control_araddr,
     input  wire         s_axi_control_arvalid,
     output wire         s_axi_control_arready,
     output wire [31:0]  s_axi_control_rdata,
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
logic [31:0] cycle_counter = 32'b0;
always_ff @(posedge ap_clk) begin
     if (~ap_rst_n) cycle_counter <= 32'b0;
     else           cycle_counter <= cycle_counter + 32'd1;
end

// ── регистры управления, доступные хосту ────────────────────────────────────
logic [31:0] min_words_r = 32'd2;   // порог фильтра, по умолчанию 2 слова
logic        fifo_clear;
logic        fifo_pop;

// ── фильтр «наш кадр» на обеих точках axis_net ──────────────────────────────
//
// Обоснование в шапке net_frame_filter.v; коротко: на axis_net идёт весь
// трафик стека, служебные кадры (ARP, чистый ACK, ICMP) укладываются в одно
// 512-битное слово, а SYN с опциями отсекается маркером.
//
// tready берём со стороны МАСТЕРА -- считается передача, а не предъявление.
wire        net_rx_ours, net_tx_ours;
wire [31:0] nf_cnt_rx, nf_cnt_tx, nf_drp_rx, nf_drp_tx;

net_frame_filter #(.EPD_MARKER(PP_MARKER)) flt_rx (
     .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
     .tvalid(s_axis_net_rx_a_tvalid), .tready(m_axis_net_rx_a_tready),
     .tlast(s_axis_net_rx_a_tlast),   .tdata(s_axis_net_rx_a_tdata),
     .min_words(min_words_r),
     .frame_ours(net_rx_ours),
     .count_ours(nf_cnt_rx), .count_drop(nf_drp_rx)
);

net_frame_filter #(.EPD_MARKER(PP_MARKER)) flt_tx (
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
typedef enum logic [1:0] {WAIT_T2, WAIT_t2, WAIT_t1, WAIT_T1} pp_state_t;
pp_state_t st = WAIT_T2;

logic [31:0] ts_T2, ts_t2, ts_t1;
logic        meas_valid;          // строб записи в FIFO
logic [31:0] meas_dropped;        // сколько измерений порвалось на полпути

always_ff @(posedge ap_clk) begin
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

// ── AXI-Lite: наши регистры поверх регистров ядра ───────────────────────────
//
// РАЗДЕЛЕНИЕ ПО АДРЕСУ. Ядро (HLS) занимает 0x00..0x5F -- см.
// xhls_pp_dual_krnl_hw.h. Наши регистры ставим с 0x100, с запасом: если у
// ядра появятся новые скаляры, карта не наедет.
//
//   0x100  R   fifo_rd_data   текущее слово FIFO (чтение НЕ сдвигает)
//   0x104  W   fifo_pop       запись любого значения -- сдвинуть указатель
//   0x108  R   fifo_count     слов в FIFO (измерений = /4)
//   0x10c  R   fifo_overflow  потеряно измерений из-за полного FIFO
//   0x110  RW  min_words      порог длины кадра для фильтра
//   0x114  R   nf_cnt_rx      кадров прошло фильтр на RX
//   0x118  R   nf_drp_rx      отсеяно на RX
//   0x11c  R   nf_cnt_tx      прошло на TX
//   0x120  R   nf_drp_tx      отсеяно на TX
//   0x124  R   meas_dropped   измерений порвалось на полпути
//   0x128  W   fifo_clear     запись -- очистить FIFO (overflow не трогает)
//
// ПОЧЕМУ ЧТЕНИЕ НЕ СДВИГАЕТ УКАЗАТЕЛЬ. Read-to-pop экономил бы одну
// транзакцию на слово, но делал бы чтение разрушающим: любой повторный
// доступ (а Vivado при отладке читает регистры сам) съедал бы данные. Явный
// pop дороже, зато не теряет.
localparam logic [11:0] A_RD       = 12'h100;
localparam logic [11:0] A_POP      = 12'h104;
localparam logic [11:0] A_COUNT    = 12'h108;
localparam logic [11:0] A_OVF      = 12'h10c;
localparam logic [11:0] A_MINWORDS = 12'h110;
localparam logic [11:0] A_CNT_RX   = 12'h114;
localparam logic [11:0] A_DRP_RX   = 12'h118;
localparam logic [11:0] A_CNT_TX   = 12'h11c;
localparam logic [11:0] A_DRP_TX   = 12'h120;
localparam logic [11:0] A_MEAS_DRP = 12'h124;
localparam logic [11:0] A_CLEAR    = 12'h128;

// Наш диапазон -- всё, что от 0x100. Ниже отдаём ядру.
wire aw_ours = s_axi_control_awaddr[11:8] != 4'h0;
wire ar_ours = s_axi_control_araddr[11:8] != 4'h0;

// ── запись: автомат из ТРЁХ состояний, как в эталоне ────────────────────────
//
// ФОРМА ВЗЯТА ИЗ dual_echo_control_s_axi.v -- обёртки, которая РАБОТАЛА на
// этой плате (удалена в 9dd815a, когда ядро перешло на s_axilite). Там
// автомат записи имеет три состояния:
//
//     WRIDLE  ждём адрес     AWREADY=1
//     WRDATA  ждём данные    WREADY=1
//     WRRESP  отдаём ответ   BVALID=1, новый адрес НЕ принимаем
//
// ПЕРВАЯ ВЕРСИЯ ЗДЕСЬ ВИСЛА, И ЭТО НАШЛОСЬ СРАВНЕНИЕМ С ЭТАЛОНОМ. Она
// поднимала bvalid отдельным регистром, а awready возвращала сразу после
// приёма данных -- то есть принимала СЛЕДУЮЩУЮ запись, не отдав ответ на
// предыдущую. Два ответа схлопывались в один, хост ждал второй bvalid вечно.
//
// Для pp_raw это было бы фатально: она делает ЧЕТЫРЕ записи POP подряд на
// каждое измерение, ровно тот сценарий. JTAG-транзакция повисла бы на первом
// же измерении, и выглядело бы это как "плата не отвечает" -- то есть
// неотличимо от мёртвого битстрима.
typedef enum logic [1:0] {WRIDLE, WRDATA, WRRESP} wstate_t;
wstate_t wstate = WRIDLE;
logic [11:0] wr_addr;

always_ff @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          wstate      <= WRIDLE;
          wr_addr     <= 12'b0;
          fifo_pop    <= 1'b0;
          fifo_clear  <= 1'b0;
          min_words_r <= 32'd2;
     end else begin
          fifo_pop   <= 1'b0;      // стробы на один такт
          fifo_clear <= 1'b0;

          case (wstate)
          WRIDLE:
               if (s_axi_control_awvalid && aw_ours) begin
                    wr_addr <= s_axi_control_awaddr;
                    wstate  <= WRDATA;
               end

          WRDATA:
               if (s_axi_control_wvalid) begin
                    case (wr_addr)
                    A_POP:      fifo_pop    <= 1'b1;
                    A_CLEAR:    fifo_clear  <= 1'b1;
                    A_MINWORDS: min_words_r <= s_axi_control_wdata;
                    default: ;   // запись в R-регистр игнорируется молча
                    endcase
                    wstate <= WRRESP;
               end

          WRRESP:
               // Ответ отдан -- только теперь готовы к новому адресу.
               if (s_axi_control_bready)
                    wstate <= WRIDLE;
          endcase
     end
end

// ── чтение ──
logic [31:0] rd_data_r;
logic        rd_valid_r;
always_ff @(posedge ap_clk) begin
     if (~ap_rst_n) begin
          rd_data_r  <= 32'b0;
          rd_valid_r <= 1'b0;
     end else begin
          if (s_axi_control_arvalid && ar_ours && !rd_valid_r) begin
               rd_valid_r <= 1'b1;
               case (s_axi_control_araddr)
               A_RD:       rd_data_r <= fifo_rd_data;
               A_COUNT:    rd_data_r <= fifo_count;
               A_OVF:      rd_data_r <= fifo_overflow;
               A_MINWORDS: rd_data_r <= min_words_r;
               A_CNT_RX:   rd_data_r <= nf_cnt_rx;
               A_DRP_RX:   rd_data_r <= nf_drp_rx;
               A_CNT_TX:   rd_data_r <= nf_cnt_tx;
               A_DRP_TX:   rd_data_r <= nf_drp_tx;
               A_MEAS_DRP: rd_data_r <= meas_dropped;
               // Неописанный адрес в нашем диапазоне -- ЯВНЫЙ МАРКЕР, а не
               // нуль: нуль читался бы как "счётчик пуст", то есть
               // правдоподобно и неверно (defaults-that-fail-loudly).
               default:    rd_data_r <= 32'hBADA_DDR5;
               endcase
          end else if (rd_valid_r && s_axi_control_rready) begin
               rd_valid_r <= 1'b0;
          end
     end
end

// ── арбитраж AXI-Lite: 0x000..0x0FF ядру, 0x100+ нам ────────────────────────
//
// РАЗДЕЛЕНИЕ ПО СТАРШИМ БИТАМ АДРЕСА, без декодера диапазонов. У ядра карта
// 0x00..0x50 (xhls_pp_dual_krnl_hw.h), у нас с 0x100 -- значит достаточно
// проверить addr[11:8]: ноль -- ядро, иначе мы. Запас в четыре с лишним раза,
// так что новые скаляры ядра карту не сдвинут.
//
// ПОЧЕМУ НЕ ОДИН smartconnect В BD. Он потребовал бы второй AXI-Lite порт у
// обёртки и правки build_bd.tcl -- скрипта, на котором держатся все ядра
// репозитория. Здесь мультиплекс на десяток строк и ничего снаружи не
// меняется: BD видит один s_axi_control, как у любого HLS-ядра.

// Сигналы к control_s_axi ядра: пропускаем только свой диапазон.
wire k_awvalid = s_axi_control_awvalid & ~aw_ours;
wire k_wvalid  = s_axi_control_wvalid  & ~aw_ours;
wire k_arvalid = s_axi_control_arvalid & ~ar_ours;
wire k_bready  = s_axi_control_bready  & ~aw_ours;
wire k_rready  = s_axi_control_rready  & ~ar_ours;

wire        k_awready, k_wready, k_bvalid, k_arready, k_rvalid;
wire [1:0]  k_bresp, k_rresp;
wire [31:0] k_rdata;
wire        k_interrupt;

// Ответы мультиплексируем по тому же признаку. Наш путь -- регистры выше.
assign s_axi_control_awready = aw_ours ? (wstate == WRIDLE) : k_awready;
assign s_axi_control_wready  = aw_ours ? (wstate == WRDATA) : k_wready;
assign s_axi_control_arready = ar_ours ? !rd_valid_r  : k_arready;

// bvalid берётся из состояния автомата, а не отдельного регистра -- так
// невозможно принять новый адрес, не отдав предыдущий ответ.
wire our_bvalid = (wstate == WRRESP);

assign s_axi_control_bvalid = our_bvalid | k_bvalid;
assign s_axi_control_bresp  = our_bvalid ? 2'b00 : k_bresp;
assign s_axi_control_rvalid = rd_valid_r | k_rvalid;
assign s_axi_control_rdata  = rd_valid_r ? rd_data_r : k_rdata;
assign s_axi_control_rresp  = rd_valid_r ? 2'b00    : k_rresp;
assign interrupt            = k_interrupt;

// ── инстанс HLS-ядра ────────────────────────────────────────────────────────
//
// Имя модуля -- hls_pp_dual_krnl_ip: так его переименовывает create_ip в
// package_*.tcl. Порты AXI-Stream в верхнем регистре (_TVALID и т.п.) --
// так их генерирует HLS.
hls_pp_dual_krnl_ip u_krnl (
     .ap_clk   ( ap_clk   ),
     .ap_rst_n ( ap_rst_n ),

     .s_axis_udp_rx_TVALID ( s_axis_udp_rx_tvalid ),
     .s_axis_udp_rx_TREADY ( s_axis_udp_rx_tready ),
     .s_axis_udp_rx_TDATA  ( s_axis_udp_rx_tdata  ),
     .s_axis_udp_rx_TKEEP  ( s_axis_udp_rx_tkeep  ),
     .s_axis_udp_rx_TLAST  ( s_axis_udp_rx_tlast  ),
     .m_axis_udp_tx_TVALID ( m_axis_udp_tx_tvalid ),
     .m_axis_udp_tx_TREADY ( m_axis_udp_tx_tready ),
     .m_axis_udp_tx_TDATA  ( m_axis_udp_tx_tdata  ),
     .m_axis_udp_tx_TKEEP  ( m_axis_udp_tx_tkeep  ),
     .m_axis_udp_tx_TLAST  ( m_axis_udp_tx_tlast  ),
     .s_axis_udp_rx_meta_TVALID ( s_axis_udp_rx_meta_tvalid ),
     .s_axis_udp_rx_meta_TREADY ( s_axis_udp_rx_meta_tready ),
     .s_axis_udp_rx_meta_TDATA  ( s_axis_udp_rx_meta_tdata  ),
     .s_axis_udp_rx_meta_TKEEP  ( s_axis_udp_rx_meta_tkeep  ),
     .s_axis_udp_rx_meta_TLAST  ( s_axis_udp_rx_meta_tlast  ),
     .m_axis_udp_tx_meta_TVALID ( m_axis_udp_tx_meta_tvalid ),
     .m_axis_udp_tx_meta_TREADY ( m_axis_udp_tx_meta_tready ),
     .m_axis_udp_tx_meta_TDATA  ( m_axis_udp_tx_meta_tdata  ),
     .m_axis_udp_tx_meta_TKEEP  ( m_axis_udp_tx_meta_tkeep  ),
     .m_axis_udp_tx_meta_TLAST  ( m_axis_udp_tx_meta_tlast  ),
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
     .m_axis_tcp_open_connection_TVALID ( m_axis_tcp_open_connection_tvalid ),
     .m_axis_tcp_open_connection_TREADY ( m_axis_tcp_open_connection_tready ),
     .m_axis_tcp_open_connection_TDATA  ( m_axis_tcp_open_connection_tdata  ),
     .m_axis_tcp_open_connection_TKEEP  ( m_axis_tcp_open_connection_tkeep  ),
     .m_axis_tcp_open_connection_TLAST  ( m_axis_tcp_open_connection_tlast  ),
     .s_axis_tcp_open_status_TVALID ( s_axis_tcp_open_status_tvalid ),
     .s_axis_tcp_open_status_TREADY ( s_axis_tcp_open_status_tready ),
     .s_axis_tcp_open_status_TDATA  ( s_axis_tcp_open_status_tdata  ),
     .s_axis_tcp_open_status_TKEEP  ( s_axis_tcp_open_status_tkeep  ),
     .s_axis_tcp_open_status_TLAST  ( s_axis_tcp_open_status_tlast  ),
     .m_axis_tcp_close_connection_TVALID ( m_axis_tcp_close_connection_tvalid ),
     .m_axis_tcp_close_connection_TREADY ( m_axis_tcp_close_connection_tready ),
     .m_axis_tcp_close_connection_TDATA  ( m_axis_tcp_close_connection_tdata  ),
     .m_axis_tcp_close_connection_TKEEP  ( m_axis_tcp_close_connection_tkeep  ),
     .m_axis_tcp_close_connection_TLAST  ( m_axis_tcp_close_connection_tlast  ),
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
     .s_axis_udp_rx_b_TVALID ( s_axis_udp_rx_b_tvalid ),
     .s_axis_udp_rx_b_TREADY ( s_axis_udp_rx_b_tready ),
     .s_axis_udp_rx_b_TDATA  ( s_axis_udp_rx_b_tdata  ),
     .s_axis_udp_rx_b_TKEEP  ( s_axis_udp_rx_b_tkeep  ),
     .s_axis_udp_rx_b_TLAST  ( s_axis_udp_rx_b_tlast  ),
     .m_axis_udp_tx_b_TVALID ( m_axis_udp_tx_b_tvalid ),
     .m_axis_udp_tx_b_TREADY ( m_axis_udp_tx_b_tready ),
     .m_axis_udp_tx_b_TDATA  ( m_axis_udp_tx_b_tdata  ),
     .m_axis_udp_tx_b_TKEEP  ( m_axis_udp_tx_b_tkeep  ),
     .m_axis_udp_tx_b_TLAST  ( m_axis_udp_tx_b_tlast  ),
     .s_axis_udp_rx_meta_b_TVALID ( s_axis_udp_rx_meta_b_tvalid ),
     .s_axis_udp_rx_meta_b_TREADY ( s_axis_udp_rx_meta_b_tready ),
     .s_axis_udp_rx_meta_b_TDATA  ( s_axis_udp_rx_meta_b_tdata  ),
     .s_axis_udp_rx_meta_b_TKEEP  ( s_axis_udp_rx_meta_b_tkeep  ),
     .s_axis_udp_rx_meta_b_TLAST  ( s_axis_udp_rx_meta_b_tlast  ),
     .m_axis_udp_tx_meta_b_TVALID ( m_axis_udp_tx_meta_b_tvalid ),
     .m_axis_udp_tx_meta_b_TREADY ( m_axis_udp_tx_meta_b_tready ),
     .m_axis_udp_tx_meta_b_TDATA  ( m_axis_udp_tx_meta_b_tdata  ),
     .m_axis_udp_tx_meta_b_TKEEP  ( m_axis_udp_tx_meta_b_tkeep  ),
     .m_axis_udp_tx_meta_b_TLAST  ( m_axis_udp_tx_meta_b_tlast  ),
     .m_axis_tcp_listen_port_b_TVALID ( m_axis_tcp_listen_port_b_tvalid ),
     .m_axis_tcp_listen_port_b_TREADY ( m_axis_tcp_listen_port_b_tready ),
     .m_axis_tcp_listen_port_b_TDATA  ( m_axis_tcp_listen_port_b_tdata  ),
     .m_axis_tcp_listen_port_b_TKEEP  ( m_axis_tcp_listen_port_b_tkeep  ),
     .m_axis_tcp_listen_port_b_TLAST  ( m_axis_tcp_listen_port_b_tlast  ),
     .s_axis_tcp_port_status_b_TVALID ( s_axis_tcp_port_status_b_tvalid ),
     .s_axis_tcp_port_status_b_TREADY ( s_axis_tcp_port_status_b_tready ),
     .s_axis_tcp_port_status_b_TDATA  ( s_axis_tcp_port_status_b_tdata  ),
     .s_axis_tcp_port_status_b_TKEEP  ( s_axis_tcp_port_status_b_tkeep  ),
     .s_axis_tcp_port_status_b_TLAST  ( s_axis_tcp_port_status_b_tlast  ),
     .m_axis_tcp_open_connection_b_TVALID ( m_axis_tcp_open_connection_b_tvalid ),
     .m_axis_tcp_open_connection_b_TREADY ( m_axis_tcp_open_connection_b_tready ),
     .m_axis_tcp_open_connection_b_TDATA  ( m_axis_tcp_open_connection_b_tdata  ),
     .m_axis_tcp_open_connection_b_TKEEP  ( m_axis_tcp_open_connection_b_tkeep  ),
     .m_axis_tcp_open_connection_b_TLAST  ( m_axis_tcp_open_connection_b_tlast  ),
     .s_axis_tcp_open_status_b_TVALID ( s_axis_tcp_open_status_b_tvalid ),
     .s_axis_tcp_open_status_b_TREADY ( s_axis_tcp_open_status_b_tready ),
     .s_axis_tcp_open_status_b_TDATA  ( s_axis_tcp_open_status_b_tdata  ),
     .s_axis_tcp_open_status_b_TKEEP  ( s_axis_tcp_open_status_b_tkeep  ),
     .s_axis_tcp_open_status_b_TLAST  ( s_axis_tcp_open_status_b_tlast  ),
     .m_axis_tcp_close_connection_b_TVALID ( m_axis_tcp_close_connection_b_tvalid ),
     .m_axis_tcp_close_connection_b_TREADY ( m_axis_tcp_close_connection_b_tready ),
     .m_axis_tcp_close_connection_b_TDATA  ( m_axis_tcp_close_connection_b_tdata  ),
     .m_axis_tcp_close_connection_b_TKEEP  ( m_axis_tcp_close_connection_b_tkeep  ),
     .m_axis_tcp_close_connection_b_TLAST  ( m_axis_tcp_close_connection_b_tlast  ),
     .s_axis_tcp_notification_b_TVALID ( s_axis_tcp_notification_b_tvalid ),
     .s_axis_tcp_notification_b_TREADY ( s_axis_tcp_notification_b_tready ),
     .s_axis_tcp_notification_b_TDATA  ( s_axis_tcp_notification_b_tdata  ),
     .s_axis_tcp_notification_b_TKEEP  ( s_axis_tcp_notification_b_tkeep  ),
     .s_axis_tcp_notification_b_TLAST  ( s_axis_tcp_notification_b_tlast  ),
     .m_axis_tcp_read_pkg_b_TVALID ( m_axis_tcp_read_pkg_b_tvalid ),
     .m_axis_tcp_read_pkg_b_TREADY ( m_axis_tcp_read_pkg_b_tready ),
     .m_axis_tcp_read_pkg_b_TDATA  ( m_axis_tcp_read_pkg_b_tdata  ),
     .m_axis_tcp_read_pkg_b_TKEEP  ( m_axis_tcp_read_pkg_b_tkeep  ),
     .m_axis_tcp_read_pkg_b_TLAST  ( m_axis_tcp_read_pkg_b_tlast  ),
     .s_axis_tcp_rx_meta_b_TVALID ( s_axis_tcp_rx_meta_b_tvalid ),
     .s_axis_tcp_rx_meta_b_TREADY ( s_axis_tcp_rx_meta_b_tready ),
     .s_axis_tcp_rx_meta_b_TDATA  ( s_axis_tcp_rx_meta_b_tdata  ),
     .s_axis_tcp_rx_meta_b_TKEEP  ( s_axis_tcp_rx_meta_b_tkeep  ),
     .s_axis_tcp_rx_meta_b_TLAST  ( s_axis_tcp_rx_meta_b_tlast  ),
     .s_axis_tcp_rx_data_b_TVALID ( s_axis_tcp_rx_data_b_tvalid ),
     .s_axis_tcp_rx_data_b_TREADY ( s_axis_tcp_rx_data_b_tready ),
     .s_axis_tcp_rx_data_b_TDATA  ( s_axis_tcp_rx_data_b_tdata  ),
     .s_axis_tcp_rx_data_b_TKEEP  ( s_axis_tcp_rx_data_b_tkeep  ),
     .s_axis_tcp_rx_data_b_TLAST  ( s_axis_tcp_rx_data_b_tlast  ),
     .m_axis_tcp_tx_meta_b_TVALID ( m_axis_tcp_tx_meta_b_tvalid ),
     .m_axis_tcp_tx_meta_b_TREADY ( m_axis_tcp_tx_meta_b_tready ),
     .m_axis_tcp_tx_meta_b_TDATA  ( m_axis_tcp_tx_meta_b_tdata  ),
     .m_axis_tcp_tx_meta_b_TKEEP  ( m_axis_tcp_tx_meta_b_tkeep  ),
     .m_axis_tcp_tx_meta_b_TLAST  ( m_axis_tcp_tx_meta_b_tlast  ),
     .m_axis_tcp_tx_data_b_TVALID ( m_axis_tcp_tx_data_b_tvalid ),
     .m_axis_tcp_tx_data_b_TREADY ( m_axis_tcp_tx_data_b_tready ),
     .m_axis_tcp_tx_data_b_TDATA  ( m_axis_tcp_tx_data_b_tdata  ),
     .m_axis_tcp_tx_data_b_TKEEP  ( m_axis_tcp_tx_data_b_tkeep  ),
     .m_axis_tcp_tx_data_b_TLAST  ( m_axis_tcp_tx_data_b_tlast  ),
     .s_axis_tcp_tx_status_b_TVALID ( s_axis_tcp_tx_status_b_tvalid ),
     .s_axis_tcp_tx_status_b_TREADY ( s_axis_tcp_tx_status_b_tready ),
     .s_axis_tcp_tx_status_b_TDATA  ( s_axis_tcp_tx_status_b_tdata  ),
     .s_axis_tcp_tx_status_b_TKEEP  ( s_axis_tcp_tx_status_b_tkeep  ),
     .s_axis_tcp_tx_status_b_TLAST  ( s_axis_tcp_tx_status_b_tlast  ),

     // AXI-Lite ядра: только свой диапазон адресов.
     .s_axi_control_AWADDR  ( s_axi_control_awaddr[5:0] ),
     .s_axi_control_AWVALID ( k_awvalid                 ),
     .s_axi_control_AWREADY ( k_awready                 ),
     .s_axi_control_WDATA   ( s_axi_control_wdata       ),
     .s_axi_control_WSTRB   ( s_axi_control_wstrb       ),
     .s_axi_control_WVALID  ( k_wvalid                  ),
     .s_axi_control_WREADY  ( k_wready                  ),
     .s_axi_control_BRESP   ( k_bresp                   ),
     .s_axi_control_BVALID  ( k_bvalid                  ),
     .s_axi_control_BREADY  ( k_bready                  ),
     .s_axi_control_ARADDR  ( s_axi_control_araddr[5:0] ),
     .s_axi_control_ARVALID ( k_arvalid                 ),
     .s_axi_control_ARREADY ( k_arready                 ),
     .s_axi_control_RDATA   ( k_rdata                   ),
     .s_axi_control_RRESP   ( k_rresp                   ),
     .s_axi_control_RVALID  ( k_rvalid                  ),
     .s_axi_control_RREADY  ( k_rready                  ),
     .interrupt             ( k_interrupt               )
);

endmodule

`default_nettype wire
