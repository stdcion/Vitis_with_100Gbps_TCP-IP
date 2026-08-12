// =============================================================================
// probe_control_s_axi -- AXI4-Lite регистры управления hls_echo_probe_dual_krnl
// =============================================================================
//
// ЗАЧЕМ ЭТОТ ФАЙЛ. HLS-ядро объявлено ap_ctrl_none (free-running), а UG1393
// (Free-Running Kernels) прямо запрещает при этом иметь s_axilite: "The kernel
// interface should not have any #pragma HLS interface s_axilite". HLS при этом
// не выдаёт ошибку, а молча защёлкивает входные скаляры один раз в state2
// автомата -- сразу после снятия сброса, когда хост по JTAG ещё ничего не
// записал. Симптом на плате: регистр читается верно, а логика видит 0.
//
// Этот файл -- копия dual_echo_control_s_axi.v, приведённая под набор
// параметров probe-ядра. Схема та же, что в iperf_krnl (iperf_role.sv:369) и
// network_krnl, то есть в ядрах, которые на этом железе работают.
//
// ЧТО ЗДЕСЬ ОСОБЕННОГО ПО СРАВНЕНИЮ С dual_echo:
//
//   * 6 входных параметров вместо 3 и 12 выходных значений вместо 6;
//   * СРЕДИ ВХОДОВ ЕСТЬ triggerGo, который меняется МНОГОКРАТНО во время
//     работы -- в отличие от остальных, записываемых один раз до enable.
//     Именно из-за него обёртка здесь не роскошь, а единственный работающий
//     вариант: при s_axilite + ap_ctrl_none защёлка происходит однажды, и
//     второй замер не запустится НИКОГДА. В .cpp это описано как "оговорка
//     про triggerGo" (hls_echo_probe_dual_krnl.cpp:1146) с резервным планом
//     "убрать DATAFLOW" -- обёртка решает ту же задачу, не трогая логику.
//
// ПРО triggerGo И ФРОНТ. Ядро детектирует изменение само:
//     if (triggerGo != prevGo) { prevGo = triggerGo; ready = false; }
// (epd_latch, hls_echo_probe_dual_krnl.cpp:809). Поэтому здесь нужен ОБЫЧНЫЙ
// регистр-провод, без всякой обработки фронта: хост пишет инкремент, ядро
// видит новое значение на следующем такте и реагирует. Сбрасывать в ноль не
// надо.
//
// АДРЕСНАЯ КАРТА ЗАДАНА ЗДЕСЬ ЯВНО. Это главное преимущество перед s_axilite:
// раньше смещения приходилось брать из сгенерированного драйверного заголовка
// (HLS ставит ap_vld-регистр после каждого выходного значения, поэтому шаг у
// входов 8 байт, а у выходов 16 -- по порядку аргументов их не вычислить).
// Теперь карта -- вот эта таблица.
//
//   0x00  ap_ctrl        RW  bit0=ap_start bit1=ap_done bit7=auto_restart
//   0x04  GIE            RW  global interrupt enable
//   0x08  IER            RW  ip interrupt enable
//   0x0c  ISR            RW  ip interrupt status (toggle-on-write)
//   -- параметры (пишутся до enable) --
//   0x10  enable         RW  разрешение работы (0 = стек не трогать)
//   0x18  serverIp       RW  IP серверной половины
//   0x20  serverPort     RW  порт, куда подключается клиент
//   0x28  listenPort     RW  порт, который слушает сервер (= serverPort)
//   0x30  msgBytes       RW  размер сообщения, байты
//   0x38  triggerGo      RW  запись нового значения = один замер
//   -- счётчики (RO) --
//   0x40  connAttempts   RO  попыток открыть соединение
//   0x44  sentCount      RO  отправлено запросов
//   0x48  recvCount      RO  получено ответов
//   0x4c  timeoutCount   RO  ответ не пришёл за таймаут
//   0x50  echoCount      RO  сообщений отражено сервером
//   0x54  listenAttempts RO  сколько раз просили порт у стека
//   0x58  portState      RO  0=ждём enable 1=запрос отправлен 2=порт открыт
//   -- таймстемпы последнего круга (RO), такты ap_clk --
//   0x60  tsRequest      RO  t1'
//   0x64  tsEchoIn       RO  t2'
//   0x68  tsEchoOut      RO  t1
//   0x6c  tsReply        RO  t2
//   0x70  sampleReady    RO  1 = четвёрка выше готова и не запрашивалась
//
// Шаг 8 байт у RW-регистров сохранён нарочно -- он совпадает с раскладкой,
// которую даёт HLS для входных скаляров. RO-регистры идут подряд по 4 байта:
// ap_vld-полей у них нет, потому что это просто провода из ядра.
//
// ПОЧЕМУ ТАЙМСТЕМПЫ ЧИТАЮТСЯ ПРЯМО С ПРОВОДОВ. Гонки чтения нет по построению
// режима: пока хост не записал triggerGo, новый пакет не отправится, значит
// четвёрка не изменится (см. "СОГЛАСОВАННОСТЬ" в .cpp:770). Поэтому не нужны
// ни теневые регистры здесь, ни номер набора -- достаточно sampleReady.
// Порядок на хосте: дождаться sampleReady=1, прочитать четвёрку, записать
// новый triggerGo (эта же запись снимает sampleReady).
//
// AXI-машины (wstate/rstate, wmask, aw_hs/w_hs) скопированы дословно из
// iperf_role_control_s_axi.v -- это сгенерированный HLS код, проверенный в
// работе; переписывать его своими словами значило бы получить свои же баги.
// =============================================================================

`timescale 1ns/1ps

module probe_control_s_axi
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
    output wire [31:0]                   serverIp,
    output wire [31:0]                   serverPort,
    output wire [31:0]                   listenPort,
    output wire [31:0]                   msgBytes,
    output wire [31:0]                   triggerGo,

    // телеметрия <- из ядра проводами
    input  wire [31:0]                   connAttempts,
    input  wire [31:0]                   sentCount,
    input  wire [31:0]                   recvCount,
    input  wire [31:0]                   timeoutCount,
    input  wire [31:0]                   echoCount,
    input  wire [31:0]                   listenAttempts,
    input  wire [31:0]                   portState,
    input  wire [31:0]                   tsRequest,
    input  wire [31:0]                   tsEchoIn,
    input  wire [31:0]                   tsEchoOut,
    input  wire [31:0]                   tsReply,
    input  wire [31:0]                   sampleReady
);

//------------------------Address Info-------------------
localparam
    ADDR_AP_CTRL          = 12'h000,
    ADDR_GIE              = 12'h004,
    ADDR_IER              = 12'h008,
    ADDR_ISR              = 12'h00c,
    ADDR_ENABLE_DATA_0    = 12'h010,
    ADDR_ENABLE_CTRL      = 12'h014,
    ADDR_SERVERIP_DATA_0  = 12'h018,
    ADDR_SERVERIP_CTRL    = 12'h01c,
    ADDR_SRVPORT_DATA_0   = 12'h020,
    ADDR_SRVPORT_CTRL     = 12'h024,
    ADDR_LSNPORT_DATA_0   = 12'h028,
    ADDR_LSNPORT_CTRL     = 12'h02c,
    ADDR_MSGBYTES_DATA_0  = 12'h030,
    ADDR_MSGBYTES_CTRL    = 12'h034,
    ADDR_TRIGGER_DATA_0   = 12'h038,
    ADDR_TRIGGER_CTRL     = 12'h03c,
    ADDR_CONNATT_DATA_0   = 12'h040,
    ADDR_SENT_DATA_0      = 12'h044,
    ADDR_RECV_DATA_0      = 12'h048,
    ADDR_TIMEOUT_DATA_0   = 12'h04c,
    ADDR_ECHO_DATA_0      = 12'h050,
    ADDR_LSNATT_DATA_0    = 12'h054,
    ADDR_PORTSTATE_DATA_0 = 12'h058,
    ADDR_TSREQ_DATA_0     = 12'h060,
    ADDR_TSECHOIN_DATA_0  = 12'h064,
    ADDR_TSECHOOUT_DATA_0 = 12'h068,
    ADDR_TSREPLY_DATA_0   = 12'h06c,
    ADDR_SMPREADY_DATA_0  = 12'h070,
    WRIDLE                = 2'd0,
    WRDATA                = 2'd1,
    WRRESP                = 2'd2,
    WRRESET               = 2'd3,
    RDIDLE                = 2'd0,
    RDDATA                = 2'd1,
    RDRESET               = 2'd2,
    ADDR_BITS             = 12;

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
    reg  [31:0]                   int_serverIp = 32'b0;
    reg  [31:0]                   int_serverPort = 32'b0;
    reg  [31:0]                   int_listenPort = 32'b0;
    reg  [31:0]                   int_msgBytes = 32'b0;
    reg  [31:0]                   int_triggerGo = 32'b0;

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
// Телеметрия и таймстемпы читаются ПРЯМО С ПРОВОДОВ из ядра, без
// промежуточного регистра: значение всегда актуально на момент чтения.
//
// Держать значение между обновлениями -- забота HLS, и он это делает: у
// ap_vld-выходов он завёл теневой регистр *_preg и переигрывает его во всех
// такстах, когда записи нет (проверено в сгенерированном RTL dual_echo, где
// та же конструкция: dual_echo_listen.v:345,348). Поэтому строб *_ap_vld
// обёртка не подключает -- он не несёт информации, нужной для чтения.
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
                ADDR_SERVERIP_DATA_0: begin
                    rdata <= int_serverIp;
                end
                ADDR_SRVPORT_DATA_0: begin
                    rdata <= int_serverPort;
                end
                ADDR_LSNPORT_DATA_0: begin
                    rdata <= int_listenPort;
                end
                ADDR_MSGBYTES_DATA_0: begin
                    rdata <= int_msgBytes;
                end
                ADDR_TRIGGER_DATA_0: begin
                    rdata <= int_triggerGo;
                end
                ADDR_CONNATT_DATA_0: begin
                    rdata <= connAttempts;
                end
                ADDR_SENT_DATA_0: begin
                    rdata <= sentCount;
                end
                ADDR_RECV_DATA_0: begin
                    rdata <= recvCount;
                end
                ADDR_TIMEOUT_DATA_0: begin
                    rdata <= timeoutCount;
                end
                ADDR_ECHO_DATA_0: begin
                    rdata <= echoCount;
                end
                ADDR_LSNATT_DATA_0: begin
                    rdata <= listenAttempts;
                end
                ADDR_PORTSTATE_DATA_0: begin
                    rdata <= portState;
                end
                ADDR_TSREQ_DATA_0: begin
                    rdata <= tsRequest;
                end
                ADDR_TSECHOIN_DATA_0: begin
                    rdata <= tsEchoIn;
                end
                ADDR_TSECHOOUT_DATA_0: begin
                    rdata <= tsEchoOut;
                end
                ADDR_TSREPLY_DATA_0: begin
                    rdata <= tsReply;
                end
                ADDR_SMPREADY_DATA_0: begin
                    rdata <= sampleReady;
                end
                default: begin
                    rdata <= 32'b0;
                end
            endcase
        end
    end
end

//------------------------Register logic-----------------
assign interrupt  = int_gie & (|int_isr);
assign ap_start   = int_ap_start;
assign enable     = int_enable;
assign serverIp   = int_serverIp;
assign serverPort = int_serverPort;
assign listenPort = int_listenPort;
assign msgBytes   = int_msgBytes;
assign triggerGo  = int_triggerGo;

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
// не трогает ни один порт стека -- защита от гонки со стеком: TOE защёлкивает
// IP только по фронту ap_start network_krnl (network_stack.sv:946), а
// сбрасывается лишь по net_aresetn (network_stack.sv:656), так что listen,
// запрошенный до подъёма стека, ничего не гарантирует.
always @(posedge ACLK) begin
    if (ARESET)
        int_enable <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_ENABLE_DATA_0)
            int_enable <= (WDATA[31:0] & wmask) | (int_enable & ~wmask);
    end
end

// int_serverIp
always @(posedge ACLK) begin
    if (ARESET)
        int_serverIp <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_SERVERIP_DATA_0)
            int_serverIp <= (WDATA[31:0] & wmask) | (int_serverIp & ~wmask);
    end
end

// int_serverPort
always @(posedge ACLK) begin
    if (ARESET)
        int_serverPort <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_SRVPORT_DATA_0)
            int_serverPort <= (WDATA[31:0] & wmask) | (int_serverPort & ~wmask);
    end
end

// int_listenPort
always @(posedge ACLK) begin
    if (ARESET)
        int_listenPort <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_LSNPORT_DATA_0)
            int_listenPort <= (WDATA[31:0] & wmask) | (int_listenPort & ~wmask);
    end
end

// int_msgBytes
always @(posedge ACLK) begin
    if (ARESET)
        int_msgBytes <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_MSGBYTES_DATA_0)
            int_msgBytes <= (WDATA[31:0] & wmask) | (int_msgBytes & ~wmask);
    end
end

// int_triggerGo
//
// ЕДИНСТВЕННЫЙ регистр, который хост дёргает МНОГОКРАТНО во время работы: по
// разу на каждый замер. Никакой обработки фронта здесь нет и не нужно -- ядро
// сравнивает значение с прошлым само (epd_latch: triggerGo != prevGo), поэтому
// достаточно, чтобы новое значение доехало до логики проводом. Именно этого не
// умеет s_axilite при ap_ctrl_none: там значение защёлкивается однажды после
// сброса, и второй замер не запустился бы никогда.
always @(posedge ACLK) begin
    if (ARESET)
        int_triggerGo <= 32'b0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_TRIGGER_DATA_0)
            int_triggerGo <= (WDATA[31:0] & wmask) | (int_triggerGo & ~wmask);
    end
end

endmodule
