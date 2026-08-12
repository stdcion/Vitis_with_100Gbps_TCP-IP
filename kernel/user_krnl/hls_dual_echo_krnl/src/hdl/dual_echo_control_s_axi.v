// =============================================================================
// dual_echo_control_s_axi -- AXI4-Lite регистры управления hls_dual_echo_krnl
// =============================================================================
//
// ЗАЧЕМ ЭТОТ ФАЙЛ. HLS-ядро объявлено ap_ctrl_none (free-running), а
// документация Xilinx прямо запрещает при этом иметь s_axilite: "The kernel
// interface should not have any #pragma HLS interface s_axilite (as there
// should not be any memory or control port)" (UG1393, Free-Running Kernels).
// Попытка сделать иначе уже была: HLS не выдал ошибку, а молча защёлкнул
// входные скаляры один раз в state2 автомата -- сразу после снятия сброса,
// когда хост по JTAG ещё ничего не записал. Симптом на плате: enable в
// регистре читается 1, а логика видит 0.
//
// Поэтому регистры живут ЗДЕСЬ, в HDL, а в HLS-ядро значения приходят
// обычными проводами -- видимыми каждый такт, без защёлок. Ровно так это
// сделано в iperf_krnl (src/hdl/iperf_role_control_s_axi.v +
// iperf_role.sv:369) и в network_krnl (network_control_s_axi.sv), то есть в
// двух ядрах этого проекта, которые на этом железе работают.
//
// ОТЛИЧИЕ ОТ iperf_role_control_s_axi.v: там все регистры входные (хост
// только пишет). Здесь добавлен путь ЧТЕНИЯ телеметрии -- listenAttempts,
// portState, notifyCount на каждую половину приходят из ядра проводами и
// читаются хостом. Это то, что отличает "порт не открылся" от "порт открыт,
// но никто не подключился" -- на плате единственный способ увидеть разницу.
//
// АДРЕСНАЯ КАРТА ЗАДАНА ЗДЕСЬ ЯВНО. Это главное преимущество перед
// s_axilite в HLS: раньше смещения приходилось брать из сгенерированного
// драйверного заголовка (HLS ставит ap_vld-регистр после каждого выходного
// значения, поэтому шаг у входов 8 байт, а у выходов 16 -- по порядку
// аргументов их не вычислить). В jtag_ctrl.tcl они так и стояли
// placeholder'ами с пометкой "must be replaced". Теперь карта -- вот эта
// таблица, и DE_OFF_* в jtag_ctrl.tcl сверены с ней построчно.
//
//   0x00  ap_ctrl      RW  bit0=ap_start bit1=ap_done bit7=auto_restart
//   0x04  GIE          RW  global interrupt enable
//   0x08  IER          RW  ip interrupt enable
//   0x0c  ISR          RW  ip interrupt status (toggle-on-write)
//   0x10  enable       RW  разрешение работы (0 = стек не трогать)
//   0x18  listenPortA  RW  порт слушания половины a (QSFP0)
//   0x20  listenPortB  RW  порт слушания половины b (QSFP1)
//   0x30  listenAtt_a  RO  сколько раз половина a просила listen
//   0x34  portState_a  RO  0=ждём enable 1=запрос отправлен 2=порт открыт
//   0x38  notify_a     RO  уведомлений о данных на половине a
//   0x40  listenAtt_b  RO
//   0x44  portState_b  RO
//   0x48  notify_b     RO
//
// Шаг 8 байт у RW-регистров сохранён нарочно -- он совпадает с раскладкой,
// которую даёт HLS для входных скаляров, так что старые смещения
// listenPortA/B в скриптах остаются в силе. RO-регистры идут подряд по 4
// байта: ap_vld-полей у них нет, потому что это просто провода из ядра.
//
// AXI-машины (wstate/rstate, wmask, aw_hs/w_hs) скопированы дословно из
// iperf_role_control_s_axi.v -- это сгенерированный HLS код, проверенный в
// работе; переписывать его своими словами значило бы получить свои же баги.
// =============================================================================

`timescale 1ns/1ps

module dual_echo_control_s_axi
#(parameter
    C_S_AXI_ADDR_WIDTH = 12,
    C_S_AXI_DATA_WIDTH = 32
)(
    input  wire                          ACLK,
    input  wire                          ARESET,
    input  wire                          ACLK_EN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] AWADDR,
    input  wire                          AWVALID,
    output wire                          AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] WSTRB,
    input  wire                          WVALID,
    output wire                          WREADY,
    output wire [1:0]                    BRESP,
    output wire                          BVALID,
    input  wire                          BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] ARADDR,
    input  wire                          ARVALID,
    output wire                          ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0] RDATA,
    output wire [1:0]                    RRESP,
    output wire                          RVALID,
    input  wire                          RREADY,
    output wire                          interrupt,

    // блочный протокол: реализуется обёрткой, не HLS-ядром
    output wire                          ap_start,
    input  wire                          ap_done,
    input  wire                          ap_ready,
    input  wire                          ap_idle,

    // параметры -> в ядро проводами
    output wire [31:0]                   enable,
    output wire [31:0]                   listenPortA,
    output wire [31:0]                   listenPortB,

    // телеметрия <- из ядра проводами
    input  wire [31:0]                   listenAttempts_a,
    input  wire [31:0]                   portState_a,
    input  wire [31:0]                   notifyCount_a,
    input  wire [31:0]                   listenAttempts_b,
    input  wire [31:0]                   portState_b,
    input  wire [31:0]                   notifyCount_b
);

//------------------------Address Info-------------------
localparam
    ADDR_AP_CTRL        = 12'h000,
    ADDR_GIE            = 12'h004,
    ADDR_IER            = 12'h008,
    ADDR_ISR            = 12'h00c,
    ADDR_ENABLE_DATA_0  = 12'h010,
    ADDR_ENABLE_CTRL    = 12'h014,
    ADDR_PORT_A_DATA_0  = 12'h018,
    ADDR_PORT_A_CTRL    = 12'h01c,
    ADDR_PORT_B_DATA_0  = 12'h020,
    ADDR_PORT_B_CTRL    = 12'h024,
    ADDR_ATT_A_DATA_0   = 12'h030,
    ADDR_STATE_A_DATA_0 = 12'h034,
    ADDR_NOTIFY_A_DATA_0= 12'h038,
    ADDR_ATT_B_DATA_0   = 12'h040,
    ADDR_STATE_B_DATA_0 = 12'h044,
    ADDR_NOTIFY_B_DATA_0= 12'h048,
    WRIDLE              = 2'd0,
    WRDATA              = 2'd1,
    WRRESP              = 2'd2,
    WRRESET             = 2'd3,
    RDIDLE              = 2'd0,
    RDDATA              = 2'd1,
    RDRESET             = 2'd2,
    ADDR_BITS           = 12;

//------------------------Local signal-------------------
    reg  [1:0]                    wstate = WRRESET;
    reg  [1:0]                    wnext;
    reg  [ADDR_BITS-1:0]          waddr;
    wire [31:0]                   wmask;
    wire                          aw_hs;
    wire                          w_hs;
    reg  [1:0]                    rstate = RDRESET;
    reg  [1:0]                    rnext;
    reg  [31:0]                   rdata;
    wire                          ar_hs;
    wire [ADDR_BITS-1:0]          raddr;
    // internal registers
    reg                           int_ap_idle;
    reg                           int_ap_ready;
    reg                           int_ap_done = 1'b0;
    reg                           int_ap_start = 1'b0;
    reg                           int_auto_restart = 1'b0;
    reg                           int_gie = 1'b0;
    reg  [1:0]                    int_ier = 2'b0;
    reg  [1:0]                    int_isr = 2'b0;
    reg  [31:0]                   int_enable = 32'b0;
    reg  [31:0]                   int_listenPortA = 32'b0;
    reg  [31:0]                   int_listenPortB = 32'b0;

//------------------------Instantiation------------------
// нет

//------------------------AXI write fsm------------------
assign AWREADY = (wstate == WRIDLE);
assign WREADY  = (wstate == WRDATA);
assign BRESP   = 2'b00;  // OKAY
assign BVALID  = (wstate == WRRESP);
assign wmask   = { {8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}} };
assign aw_hs   = AWVALID & AWREADY;
assign w_hs    = WVALID & WREADY;

// wstate
always @(posedge ACLK) begin
    if (ARESET)
        wstate <= WRRESET;
    else if (ACLK_EN)
        wstate <= wnext;
end

// wnext
always @(*) begin
    case (wstate)
        WRIDLE:
            if (AWVALID)
                wnext = WRDATA;
            else
                wnext = WRIDLE;
        WRDATA:
            if (WVALID)
                wnext = WRRESP;
            else
                wnext = WRDATA;
        WRRESP:
            if (BREADY)
                wnext = WRIDLE;
            else
                wnext = WRRESP;
        default:
            wnext = WRIDLE;
    endcase
end

// waddr
always @(posedge ACLK) begin
    if (ACLK_EN) begin
        if (aw_hs)
            waddr <= AWADDR[ADDR_BITS-1:0];
    end
end

//------------------------AXI read fsm-------------------
assign ARREADY = (rstate == RDIDLE);
assign RDATA   = rdata;
assign RRESP   = 2'b00;  // OKAY
assign RVALID  = (rstate == RDDATA);
assign ar_hs   = ARVALID & ARREADY;
assign raddr   = ARADDR[ADDR_BITS-1:0];

// rstate
always @(posedge ACLK) begin
    if (ARESET)
        rstate <= RDRESET;
    else if (ACLK_EN)
        rstate <= rnext;
end

// rnext
always @(*) begin
    case (rstate)
        RDIDLE:
            if (ARVALID)
                rnext = RDDATA;
            else
                rnext = RDIDLE;
        RDDATA:
            if (RREADY & RVALID)
                rnext = RDIDLE;
            else
                rnext = RDDATA;
        default:
            rnext = RDIDLE;
    endcase
end

// rdata
//
// Телеметрия читается ПРЯМО С ПРОВОДОВ из ядра (portState_a и т.д.), без
// промежуточного регистра: значение всегда актуально на момент чтения. Ради
// этого вся конструкция и делалась -- при s_axilite в HLS выходные значения
// сопровождались ap_vld и обновлялись только когда ядро их записывало.
always @(posedge ACLK) begin
    if (ACLK_EN) begin
        if (ar_hs) begin
            rdata <= 32'b0;
            case (raddr)
                ADDR_AP_CTRL: begin
                    rdata[0] <= int_ap_start;
                    rdata[1] <= int_ap_done;
                    rdata[2] <= int_ap_idle;
                    rdata[3] <= int_ap_ready;
                    rdata[7] <= int_auto_restart;
                end
                ADDR_GIE: begin
                    rdata <= int_gie;
                end
                ADDR_IER: begin
                    rdata <= int_ier;
                end
                ADDR_ISR: begin
                    rdata <= int_isr;
                end
                ADDR_ENABLE_DATA_0: begin
                    rdata <= int_enable;
                end
                ADDR_PORT_A_DATA_0: begin
                    rdata <= int_listenPortA;
                end
                ADDR_PORT_B_DATA_0: begin
                    rdata <= int_listenPortB;
                end
                ADDR_ATT_A_DATA_0: begin
                    rdata <= listenAttempts_a;
                end
                ADDR_STATE_A_DATA_0: begin
                    rdata <= portState_a;
                end
                ADDR_NOTIFY_A_DATA_0: begin
                    rdata <= notifyCount_a;
                end
                ADDR_ATT_B_DATA_0: begin
                    rdata <= listenAttempts_b;
                end
                ADDR_STATE_B_DATA_0: begin
                    rdata <= portState_b;
                end
                ADDR_NOTIFY_B_DATA_0: begin
                    rdata <= notifyCount_b;
                end
                default: begin
                    rdata <= 32'b0;
                end
            endcase
        end
    end
end

//------------------------Register logic-----------------
assign interrupt   = int_gie & (|int_isr);
assign ap_start    = int_ap_start;
assign enable      = int_enable;
assign listenPortA = int_listenPortA;
assign listenPortB = int_listenPortB;

// int_ap_start
always @(posedge ACLK) begin
    if (ARESET)
        int_ap_start <= 1'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_AP_CTRL && WSTRB[0] && WDATA[0])
            int_ap_start <= 1'b1;
        else if (ap_ready)
            int_ap_start <= int_auto_restart; // clear on handshake/auto restart
    end
end

// int_ap_done
always @(posedge ACLK) begin
    if (ARESET)
        int_ap_done <= 1'b0;
    else if (ACLK_EN) begin
        if (ap_done)
            int_ap_done <= 1'b1;
        else if (ar_hs && raddr == ADDR_AP_CTRL)
            int_ap_done <= 1'b0; // clear on read
    end
end

// int_ap_idle
always @(posedge ACLK) begin
    if (ARESET)
        int_ap_idle <= 1'b0;
    else if (ACLK_EN) begin
        int_ap_idle <= ap_idle;
    end
end

// int_ap_ready
always @(posedge ACLK) begin
    if (ARESET)
        int_ap_ready <= 1'b0;
    else if (ACLK_EN) begin
        int_ap_ready <= ap_ready;
    end
end

// int_auto_restart
always @(posedge ACLK) begin
    if (ARESET)
        int_auto_restart <= 1'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_AP_CTRL && WSTRB[0])
            int_auto_restart <=  WDATA[7];
    end
end

// int_gie
always @(posedge ACLK) begin
    if (ARESET)
        int_gie <= 1'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_GIE && WSTRB[0])
            int_gie <= WDATA[0];
    end
end

// int_ier
always @(posedge ACLK) begin
    if (ARESET)
        int_ier <= 1'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_IER && WSTRB[0])
            int_ier <= WDATA[1:0];
    end
end

// int_isr
always @(posedge ACLK) begin
    if (ARESET)
        int_isr <= 1'b0;
    else if (ACLK_EN) begin
        if (int_ier[0] & ap_done)
            int_isr[0] <= 1'b1;
        else if (w_hs && waddr == ADDR_ISR && WSTRB[0])
            int_isr[0] <= int_isr[0] ^ WDATA[0]; // toggle on write
    end
end

// int_enable
//
// Это тот самый "хост разрешил" флаг. До его записи ядро видит на проводе 0 и
// не трогает ни один порт стека -- ровно та защита от гонки, ради которой
// enable и появился: TOE защёлкивает IP только по фронту ap_start
// network_krnl (network_stack.sv:946), а сбрасывается лишь по net_aresetn
// (network_stack.sv:656), так что listen, запрошенный до подъёма стека,
// ничего не гарантирует.
always @(posedge ACLK) begin
    if (ARESET)
        int_enable <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_ENABLE_DATA_0)
            int_enable <= (WDATA[31:0] & wmask) | (int_enable & ~wmask);
    end
end

// int_listenPortA
always @(posedge ACLK) begin
    if (ARESET)
        int_listenPortA <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_PORT_A_DATA_0)
            int_listenPortA <= (WDATA[31:0] & wmask) | (int_listenPortA & ~wmask);
    end
end

// int_listenPortB
always @(posedge ACLK) begin
    if (ARESET)
        int_listenPortB <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_PORT_B_DATA_0)
            int_listenPortB <= (WDATA[31:0] & wmask) | (int_listenPortB & ~wmask);
    end
end

endmodule
