`default_nettype none

module thinpad_top (
    input wire clk_50M,     // 50MHz 时钟输入
    input wire clk_11M0592, // 11.0592MHz 时钟输入（备用，可不用）

    input wire push_btn,  // BTN5 按钮开关，带消抖电路，按下时为 1
    input wire reset_btn, // BTN6 复位按钮，带消抖电路，按下时为 1

    input  wire [ 3:0] touch_btn,  // BTN1~BTN4，按钮开关，按下时为 1
    input  wire [31:0] dip_sw,     // 32 位拨码开关，拨到“ON”时为 1
    output wire [15:0] leds,       // 16 位 LED，输出时 1 点亮
    output wire [ 7:0] dpy0,       // 数码管低位信号，包括小数点，输出 1 点亮
    output wire [ 7:0] dpy1,       // 数码管高位信号，包括小数点，输出 1 点亮

    // CPLD 串口控制器信号
    output wire uart_rdn,        // 读串口信号，低有效
    output wire uart_wrn,        // 写串口信号，低有效
    input  wire uart_dataready,  // 串口数据准备好
    input  wire uart_tbre,       // 发送数据标志
    input  wire uart_tsre,       // 数据发送完毕标志

    // BaseRAM 信号
    inout wire [31:0] base_ram_data,  // BaseRAM 数据，低 8 位与 CPLD 串口控制器共享
    output wire [19:0] base_ram_addr,  // BaseRAM 地址
    output wire [3:0] base_ram_be_n,  // BaseRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
    output wire base_ram_ce_n,  // BaseRAM 片选，低有效
    output wire base_ram_oe_n,  // BaseRAM 读使能，低有效
    output wire base_ram_we_n,  // BaseRAM 写使能，低有效

    // ExtRAM 信号
    inout wire [31:0] ext_ram_data,  // ExtRAM 数据
    output wire [19:0] ext_ram_addr,  // ExtRAM 地址
    output wire [3:0] ext_ram_be_n,  // ExtRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
    output wire ext_ram_ce_n,  // ExtRAM 片选，低有效
    output wire ext_ram_oe_n,  // ExtRAM 读使能，低有效
    output wire ext_ram_we_n,  // ExtRAM 写使能，低有效

    // 直连串口信号
    output wire txd,  // 直连串口发送端
    input  wire rxd,  // 直连串口接收端

    // Flash 存储器信号，参考 JS28F640 芯片手册
    output wire [22:0] flash_a,  // Flash 地址，a0 仅在 8bit 模式有效，16bit 模式无意义
    inout wire [15:0] flash_d,  // Flash 数据
    output wire flash_rp_n,  // Flash 复位信号，低有效
    output wire flash_vpen,  // Flash 写保护信号，低电平时不能擦除、烧写
    output wire flash_ce_n,  // Flash 片选信号，低有效
    output wire flash_oe_n,  // Flash 读使能信号，低有效
    output wire flash_we_n,  // Flash 写使能信号，低有效
    output wire flash_byte_n, // Flash 8bit 模式选择，低有效。在使用 flash 的 16 位模式时请设为 1

    // USB 控制器信号，参考 SL811 芯片手册
    output wire sl811_a0,
    // inout  wire [7:0] sl811_d,     // USB 数据线与网络控制器的 dm9k_sd[7:0] 共享
    output wire sl811_wr_n,
    output wire sl811_rd_n,
    output wire sl811_cs_n,
    output wire sl811_rst_n,
    output wire sl811_dack_n,
    input  wire sl811_intrq,
    input  wire sl811_drq_n,

    // 网络控制器信号，参考 DM9000A 芯片手册
    output wire dm9k_cmd,
    inout wire [15:0] dm9k_sd,
    output wire dm9k_iow_n,
    output wire dm9k_ior_n,
    output wire dm9k_cs_n,
    output wire dm9k_pwrst_n,
    input wire dm9k_int,

    // 图像输出信号
    output wire [2:0] video_red,    // 红色像素，3 位
    output wire [2:0] video_green,  // 绿色像素，3 位
    output wire [1:0] video_blue,   // 蓝色像素，2 位
    output wire       video_hsync,  // 行同步（水平同步）信号
    output wire       video_vsync,  // 场同步（垂直同步）信号
    output wire       video_clk,    // 像素时钟输出
    output wire       video_de      // 行数据有效信号，用于区分消隐区
);

    /* =========== Demo code begin =========== */

    // PLL 分频示例
    logic locked, clk_10M, clk_20M;
    pll_example clock_gen (
        // Clock in ports
        .clk_in1(clk_50M),  // 外部时钟输入
        // Clock out ports
        .clk_out1(clk_10M),  // 时钟输出 1，频率在 IP 配置界面中设置
        .clk_out2(clk_20M),  // 时钟输出 2，频率在 IP 配置界面中设置
        // Status and control signals
        .reset(reset_btn),  // PLL 复位输入
        .locked(locked)  // PLL 锁定指示输出，"1"表示时钟稳定，
                        // 后级电路复位信号应当由它生成（见下）
    );

    logic reset_of_clk10M;
    // 异步复位，同步释放，将 locked 信号转为后级电路的复位 reset_of_clk10M
    always_ff @(posedge clk_10M or negedge locked) begin
        if (~locked) reset_of_clk10M <= 1'b1;
        else reset_of_clk10M <= 1'b0;
    end

    /* =========== Demo code end =========== */

    // 时钟和重置信号
    wire sys_clk = clk_10M;
    wire sys_rst = reset_of_clk10M;

    // cpu
    logic cpu_inst_req;
    logic [31:0] cpu_inst_addr;
    logic [31:0] cpu_inst_data;
    logic cpu_inst_ready;

    logic cpu_mem_req;
    logic [31:0] cpu_mem_addr;
    logic [31:0] cpu_mem_wdata;
    logic [31:0] cpu_mem_rdata;
    logic cpu_mem_we;
    logic [3:0] cpu_mem_sel;
    logic cpu_mem_ready;

    logic timer_irq;

    cpu_top u_cpu (
        .clk(sys_clk),
        .rst(sys_rst),
        .inst_req(cpu_inst_req),
        .inst_addr(cpu_inst_addr),
        .inst_data(cpu_inst_data),
        .inst_ready(cpu_inst_ready),
        .mem_req(cpu_mem_req),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_rdata(cpu_mem_rdata),
        .mem_we(cpu_mem_we),
        .mem_sel(cpu_mem_sel),
        .mem_ready(cpu_mem_ready),
        .timer_irq(timer_irq)
    );

    // 总线
    logic wbm_cyc_o; // master -> slave: 占用总线
    logic wbm_stb_o; // master -> slave: 当前信号有效
    logic wbm_ack_i; // slave -> master: 访问成功
    logic wbm_err_i; // slave -> master: 访问失败
    logic [31:0] wbm_adr_o; // master -> slave: 访问地址
    logic [31:0] wbm_wdata_o; // master -> slave: 写入数据
    logic [31:0] wbm_rdata_i; // slave -> master: 读到的数据
    logic [3:0] wbm_sel_o; // master -> slave: 哪些字节有效
    logic wbm_we_o; // master -> slave: 读写使能, 1 写 0 读

    wb_master u_wb_master (
        .clk_i(sys_clk),
        .rst_i(sys_rst),
        .inst_req_i(cpu_inst_req),
        .inst_addr_i(cpu_inst_addr),
        .inst_rdata_o(cpu_inst_data),
        .inst_ready_o(cpu_inst_ready),
        .mem_req_i(cpu_mem_req),
        .mem_we_i(cpu_mem_we),
        .mem_sel_i(cpu_mem_sel),
        .mem_addr_i(cpu_mem_addr),
        .mem_wdata_i(cpu_mem_wdata),
        .mem_rdata_o(cpu_mem_rdata),
        .mem_ready_o(cpu_mem_ready),
        .wb_cyc_o(wbm_cyc_o),
        .wb_stb_o(wbm_stb_o),
        .wb_ack_i(wbm_ack_i),
        .wb_err_i(wbm_err_i),
        .wb_adr_o(wbm_adr_o),
        .wb_dat_o(wbm_wdata_o),
        .wb_dat_i(wbm_rdata_i),
        .wb_sel_o(wbm_sel_o),
        .wb_we_o(wbm_we_o)
    );

    /* =========== lab4 MUX begin =========== */
    // Wishbone MUX (Masters) => bus slaves
    logic wbs0_cyc_o;
    logic wbs0_stb_o;
    logic wbs0_ack_i;
    logic [31:0] wbs0_adr_o;
    logic [31:0] wbs0_dat_o;
    logic [31:0] wbs0_dat_i;
    logic [3:0] wbs0_sel_o;
    logic wbs0_we_o;

    logic wbs1_cyc_o;
    logic wbs1_stb_o;
    logic wbs1_ack_i;
    logic [31:0] wbs1_adr_o;
    logic [31:0] wbs1_dat_o;
    logic [31:0] wbs1_dat_i;
    logic [3:0] wbs1_sel_o;
    logic wbs1_we_o;

    logic wbs2_cyc_o;
    logic wbs2_stb_o;
    logic wbs2_ack_i;
    logic [31:0] wbs2_adr_o;
    logic [31:0] wbs2_dat_o;
    logic [31:0] wbs2_dat_i;
    logic [3:0] wbs2_sel_o;
    logic wbs2_we_o;

    logic wbs3_cyc_o;
    logic wbs3_stb_o;
    logic wbs3_ack_i;
    logic [31:0] wbs3_adr_o;
    logic [31:0] wbs3_dat_o;
    logic [31:0] wbs3_dat_i;
    logic [3:0] wbs3_sel_o;
    logic wbs3_we_o;

    wb_mux_4 wb_mux (
        .clk(sys_clk),
        .rst(sys_rst),

        // Master interface (to lab4 master)
        .wbm_adr_i(wbm_adr_o),
        .wbm_dat_i(wbm_wdata_o),
        .wbm_dat_o(wbm_rdata_i),
        .wbm_we_i (wbm_we_o),
        .wbm_sel_i(wbm_sel_o),
        .wbm_stb_i(wbm_stb_o),
        .wbm_ack_o(wbm_ack_i),
        .wbm_err_o(wbm_err_i),
        .wbm_rty_o(),
        .wbm_cyc_i(wbm_cyc_o),

        // Slave interface 0 (to BaseRAM controller)
        // Address range: 0x8000_0000 ~ 0x803F_FFFF
        .wbs0_addr    (32'h8000_0000),
        .wbs0_addr_msk(32'hFFC0_0000),

        .wbs0_adr_o(wbs0_adr_o),
        .wbs0_dat_i(wbs0_dat_i),
        .wbs0_dat_o(wbs0_dat_o),
        .wbs0_we_o (wbs0_we_o),
        .wbs0_sel_o(wbs0_sel_o),
        .wbs0_stb_o(wbs0_stb_o),
        .wbs0_ack_i(wbs0_ack_i),
        .wbs0_err_i('0),
        .wbs0_rty_i('0),
        .wbs0_cyc_o(wbs0_cyc_o),

        // Slave interface 1 (to ExtRAM controller)
        // Address range: 0x8040_0000 ~ 0x807F_FFFF
        .wbs1_addr    (32'h8040_0000),
        .wbs1_addr_msk(32'hFFC0_0000),

        .wbs1_adr_o(wbs1_adr_o),
        .wbs1_dat_i(wbs1_dat_i),
        .wbs1_dat_o(wbs1_dat_o),
        .wbs1_we_o (wbs1_we_o),
        .wbs1_sel_o(wbs1_sel_o),
        .wbs1_stb_o(wbs1_stb_o),
        .wbs1_ack_i(wbs1_ack_i),
        .wbs1_err_i('0),
        .wbs1_rty_i('0),
        .wbs1_cyc_o(wbs1_cyc_o),

        // Slave interface 2 (to UART controller)
        // Address range: 0x1000_0000 ~ 0x1000_FFFF
        .wbs2_addr    (32'h1000_0000),
        .wbs2_addr_msk(32'hFFFF_0000),

        .wbs2_adr_o(wbs2_adr_o),
        .wbs2_dat_i(wbs2_dat_i),
        .wbs2_dat_o(wbs2_dat_o),
        .wbs2_we_o (wbs2_we_o),
        .wbs2_sel_o(wbs2_sel_o),
        .wbs2_stb_o(wbs2_stb_o),
        .wbs2_ack_i(wbs2_ack_i),
        .wbs2_err_i('0),
        .wbs2_rty_i('0),
        .wbs2_cyc_o(wbs2_cyc_o),

        .wbs3_addr    (32'h0200_0000),
        .wbs3_addr_msk(32'hFFFF_0000),

        .wbs3_adr_o(wbs3_adr_o),
        .wbs3_dat_i(wbs3_dat_i),
        .wbs3_dat_o(wbs3_dat_o),
        .wbs3_we_o (wbs3_we_o),
        .wbs3_sel_o(wbs3_sel_o),
        .wbs3_stb_o(wbs3_stb_o),
        .wbs3_ack_i(wbs3_ack_i),
        .wbs3_err_i('0),
        .wbs3_rty_i('0),
        .wbs3_cyc_o(wbs3_cyc_o)
    );

    /* =========== lab4 MUX end =========== */

    /* =========== lab4 Slaves begin =========== */
    sram_controller #(
        .SRAM_ADDR_WIDTH(20),
        .SRAM_DATA_WIDTH(32)
    ) sram_controller_base (
        .clk_i(sys_clk),
        .rst_i(sys_rst),

        // Wishbone slave (to MUX)
        .wb_cyc_i(wbs0_cyc_o),
        .wb_stb_i(wbs0_stb_o),
        .wb_ack_o(wbs0_ack_i),
        .wb_adr_i(wbs0_adr_o),
        .wb_dat_i(wbs0_dat_o),
        .wb_dat_o(wbs0_dat_i),
        .wb_sel_i(wbs0_sel_o),
        .wb_we_i (wbs0_we_o),

        // To SRAM chip
        .sram_addr(base_ram_addr),
        .sram_data(base_ram_data),
        .sram_ce_n(base_ram_ce_n),
        .sram_oe_n(base_ram_oe_n),
        .sram_we_n(base_ram_we_n),
        .sram_be_n(base_ram_be_n)
    );

    sram_controller #(
        .SRAM_ADDR_WIDTH(20),
        .SRAM_DATA_WIDTH(32)
    ) sram_controller_ext (
        .clk_i(sys_clk),
        .rst_i(sys_rst),

        // Wishbone slave (to MUX)
        .wb_cyc_i(wbs1_cyc_o),
        .wb_stb_i(wbs1_stb_o),
        .wb_ack_o(wbs1_ack_i),
        .wb_adr_i(wbs1_adr_o),
        .wb_dat_i(wbs1_dat_o),
        .wb_dat_o(wbs1_dat_i),
        .wb_sel_i(wbs1_sel_o),
        .wb_we_i (wbs1_we_o),

        // To SRAM chip
        .sram_addr(ext_ram_addr),
        .sram_data(ext_ram_data),
        .sram_ce_n(ext_ram_ce_n),
        .sram_oe_n(ext_ram_oe_n),
        .sram_we_n(ext_ram_we_n),
        .sram_be_n(ext_ram_be_n)
    );

    // 串口控制器模块
    // NOTE: 如果修改系统时钟频率，也需要修改此处的时钟频率参数
    uart_controller #(
        .CLK_FREQ(10_000_000),
        .BAUD    (115200)
    ) uart_controller (
        .clk_i(sys_clk),
        .rst_i(sys_rst),

        .wb_cyc_i(wbs2_cyc_o),
        .wb_stb_i(wbs2_stb_o),
        .wb_ack_o(wbs2_ack_i),
        .wb_adr_i(wbs2_adr_o),
        .wb_dat_i(wbs2_dat_o),
        .wb_dat_o(wbs2_dat_i),
        .wb_sel_i(wbs2_sel_o),
        .wb_we_i (wbs2_we_o),

        // to UART pins
        .uart_txd_o(txd),
        .uart_rxd_i(rxd)
    );

    clint u_clint (
        .clk_i(sys_clk),
        .rst_i(sys_rst),

        .wb_cyc_i(wbs3_cyc_o),
        .wb_stb_i(wbs3_stb_o),
        .wb_ack_o(wbs3_ack_i),
        .wb_adr_i(wbs3_adr_o),
        .wb_dat_i(wbs3_dat_o),
        .wb_dat_o(wbs3_dat_i),
        .wb_sel_i(wbs3_sel_o),
        .wb_we_i (wbs3_we_o),

        .timer_irq_o(timer_irq)
    );

    /* =========== lab4 Slaves end =========== */

    // The direct UART is used; keep the CPLD UART disconnected from the
    // shared low byte of BaseRAM.
    assign uart_rdn = 1'b1;
    assign uart_wrn = 1'b1;

    // Unused peripherals are put into inactive states.
    assign leds          = 16'b0;
    assign dpy0          = 8'b0;
    assign dpy1          = 8'b0;
    assign flash_a       = 23'b0;
    assign flash_d       = 16'hzzzz;
    assign flash_rp_n    = 1'b1;
    assign flash_vpen    = 1'b0;
    assign flash_ce_n    = 1'b1;
    assign flash_oe_n    = 1'b1;
    assign flash_we_n    = 1'b1;
    assign flash_byte_n  = 1'b1;
    assign sl811_a0      = 1'b0;
    assign sl811_wr_n    = 1'b1;
    assign sl811_rd_n    = 1'b1;
    assign sl811_cs_n    = 1'b1;
    assign sl811_rst_n   = 1'b1;
    assign sl811_dack_n  = 1'b1;
    assign dm9k_cmd      = 1'b0;
    assign dm9k_sd       = 16'hzzzz;
    assign dm9k_iow_n    = 1'b1;
    assign dm9k_ior_n    = 1'b1;
    assign dm9k_cs_n     = 1'b1;
    assign dm9k_pwrst_n  = 1'b1;
    assign video_red     = 3'b0;
    assign video_green   = 3'b0;
    assign video_blue    = 2'b0;
    assign video_hsync   = 1'b0;
    assign video_vsync   = 1'b0;
    assign video_clk     = 1'b0;
    assign video_de      = 1'b0;
endmodule
