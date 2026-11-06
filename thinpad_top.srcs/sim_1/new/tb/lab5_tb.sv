`timescale 1ns / 1ps
// lab5 仿真：thinpad_top 运行实验文档的测试程序 lab5_test.s。
// 程序计算 1+2+...+100，把 5050 = 0x13ba 写到 0x80000100，再从直连串口依次输出 "done!"。
// 检查：串口收到 "done!"；BaseRAM 的 0x80000100 处为 5050。
//
// 程序的机器码（PROG）直接写进 BaseRAM 模型，不读 .bin 文件（xsim 和 Verilator 的工作目录不同，相对路径不好写）。
// PROG 由 lab5_test.s 汇编得到；make lab5-bin LAB=5 生成云平台用的 .bin，并核对它和 PROG 一致。
module lab5_tb;

    wire clk_50M, clk_11M0592;

    reg push_btn;   // BTN5 按钮开关，带消抖电路，按下时为 1
    reg reset_btn;  // BTN6 复位按钮，带消抖电路，按下时为 1

    reg [3:0] touch_btn; // BTN1~BTN4，按钮开关，按下时为 1
    reg [31:0] dip_sw;   // 32 位拨码开关，拨到“ON”时为 1

    wire [15:0] leds;  // 16 位 LED，输出时 1 点亮
    wire [7:0] dpy0;   // 数码管低位信号，包括小数点，输出 1 点亮
    wire [7:0] dpy1;   // 数码管高位信号，包括小数点，输出 1 点亮

    wire [31:0] base_ram_data;  // BaseRAM 数据，低 8 位与 CPLD 串口控制器共享
    wire [19:0] base_ram_addr;  // BaseRAM 地址
    wire [3:0] base_ram_be_n;    // BaseRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
    wire base_ram_ce_n;  // BaseRAM 片选，低有效
    wire base_ram_oe_n;  // BaseRAM 读使能，低有效
    wire base_ram_we_n;  // BaseRAM 写使能，低有效

    wire [31:0] ext_ram_data;  // ExtRAM 数据
    wire [19:0] ext_ram_addr;  // ExtRAM 地址
    wire [3:0] ext_ram_be_n;    // ExtRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
    wire ext_ram_ce_n;  // ExtRAM 片选，低有效
    wire ext_ram_oe_n;  // ExtRAM 读使能，低有效
    wire ext_ram_we_n;  // ExtRAM 写使能，低有效

    wire txd;  // 直连串口发送端
    wire rxd;  // 直连串口接收端

    // 测试程序
    localparam int N_PROG = 36;
    localparam logic [31:0] PROG[N_PROG] = '{
        32'h00000293,  // 00: addi t0, zero, 0
        32'h06400313,  // 04: addi t1, zero, 100
        32'h00000393,  // 08: addi t2, zero, 0
        32'h00128293,  // 0c: loop: addi t0, t0, 1
        32'h007283b3,  // 10: add t2, t0, t2
        32'h00628463,  // 14: beq t0, t1, next
        32'hfe000ae3,  // 18: beq zero, zero, loop
        32'h800002b7,  // 1c: next: lui  t0, 0x80000
        32'h1072a023,  // 20: sw t2, 0x100(t0)
        32'h100002b7,  // 24: lui t0, 0x10000
        32'h00528303,  // 28: TESTW1: lb  t1, 5(t0)
        32'h02037313,  // 2c: andi t1, t1, 0x20
        32'hfe030ce3,  // 30: beq t1, zero, .TESTW1
        32'h06400513,  // 34: addi a0, zero, 'd'
        32'h00a28023,  // 38: sb a0, 0(t0)
        32'h00528303,  // 3c: TESTW2
        32'h02037313,
        32'hfe030ce3,
        32'h06f00513,  // 48: addi a0, zero, 'o'
        32'h00a28023,
        32'h00528303,  // 50: TESTW3
        32'h02037313,
        32'hfe030ce3,
        32'h06e00513,  // 5c: addi a0, zero, 'n'
        32'h00a28023,
        32'h00528303,  // 64: TESTW4
        32'h02037313,
        32'hfe030ce3,
        32'h06500513,  // 70: addi a0, zero, 'e'
        32'h00a28023,
        32'h00528303,  // 78: TESTW5
        32'h02037313,
        32'hfe030ce3,
        32'h02100513,  // 84: addi a0, zero, '!'
        32'h00a28023,  // 88: sb   a0, 0(t0)
        32'h00000063   // 8c: end: beq  zero, zero, end
    };

    // 流水线各级指令的 PC 和 ID 级的指令字
    wire [31:0] if_pc = dut.u_cpu.pc;
    wire [31:0] id_pc = dut.u_cpu.if_id.pc;
    wire [31:0] id_inst = dut.u_cpu.if_id.inst;
    wire [31:0] ex_pc = dut.u_cpu.id_ex.pc;
    wire [31:0] mem_pc = dut.u_cpu.ex_mem.pc_plus_4 == 32'b0 ? 32'b0 :
        dut.u_cpu.ex_mem.pc_plus_4 - 32'd4;

    // 串口收到的每个字节
    reg [7:0] uart_rx[$];
    always @(posedge uart.rxd_data_ready) begin 
        uart_rx.push_back(uart.rxd_data);
    end

    initial begin
        string s;
        logic [31:0] sum;

        // 1. 初始输入
        dip_sw = 32'h0;
        touch_btn = 0;
        reset_btn = 0;
        push_btn = 0;
        #10;

    `ifndef VERILATOR
        base1.WE_dly = 1'b1;
        base2.WE_dly = 1'b1;
        ext1.WE_dly  = 1'b1;
        ext2.WE_dly  = 1'b1;
    `endif

        // 2. 装填程序: 一个字拆成 4 个字节, 小端, 低 16 位在 base1、高 16 位在 base2
        for (int i = 0; i < N_PROG; i++) begin
            base1.mem_array0[i] = PROG[i][7:0];
            base1.mem_array1[i] = PROG[i][15:8];
            base2.mem_array0[i] = PROG[i][23:16];
            base2.mem_array1[i] = PROG[i][31:24];
        end

        // 3. 复位
        #90;
        reset_btn = 1;
        #100;
        reset_btn = 0;

        // 4. 等串口收到 5 个字节, 再多等约两个字节的时间, 确认没有多余输出
        wait (uart_rx.size() == 5);
        #200us;

        // 5. 检查串口输出和 0x80000100
        s = "";
        foreach (uart_rx[i]) s = {s, $sformatf("%c", uart_rx[i])};
        sum = {base2.mem_array1['h40], base2.mem_array0['h40],
            base1.mem_array1['h40], base1.mem_array0['h40]};
        $display("UART: \"%s\", [0x80000100] = %0d", s, sum);
        if (s != "done!") $fatal(1, "lab5_tb: 串口输出应为 \"done!\"");
        if (sum != 32'd5050) $fatal(1, "lab5_tb: 0x80000100 处应为 5050");
        $display("lab5_tb: PASS at %0d ns", $time);
        $finish;
    end

    // 超时：3ms 还没跑完就报错
    initial begin
        #3ms;
        $fatal(1, "lab5_tb: timeout, UART received %0d bytes", uart_rx.size());
    end

    // 待测试用户设计
    thinpad_top dut (
        .clk_50M(clk_50M),
        .clk_11M0592(clk_11M0592),
        .push_btn(push_btn),
        .reset_btn(reset_btn),
        .touch_btn(touch_btn),
        .dip_sw(dip_sw),
        .leds(leds),
        .dpy1(dpy1),
        .dpy0(dpy0),
        .txd(txd),
        .rxd(rxd),
        .uart_rdn(),  // 不用 CPLD 串口
        .uart_wrn(),
        .uart_dataready(1'b0),
        .uart_tbre(1'b0),
        .uart_tsre(1'b0),
        .base_ram_data(base_ram_data),
        .base_ram_addr(base_ram_addr),
        .base_ram_ce_n(base_ram_ce_n),
        .base_ram_oe_n(base_ram_oe_n),
        .base_ram_we_n(base_ram_we_n),
        .base_ram_be_n(base_ram_be_n),
        .ext_ram_data(ext_ram_data),
        .ext_ram_addr(ext_ram_addr),
        .ext_ram_ce_n(ext_ram_ce_n),
        .ext_ram_oe_n(ext_ram_oe_n),
        .ext_ram_we_n(ext_ram_we_n),
        .ext_ram_be_n(ext_ram_be_n),
        .flash_d(),
        .flash_a(),
        .flash_rp_n(),
        .flash_vpen(),
        .flash_oe_n(),
        .flash_ce_n(),
        .flash_byte_n(),
        .flash_we_n(),
        .sl811_a0(),
        .sl811_wr_n(),
        .sl811_rd_n(),
        .sl811_cs_n(),
        .sl811_rst_n(),
        .sl811_dack_n(),
        .sl811_intrq(1'b0),
        .sl811_drq_n(1'b1),
        .dm9k_cmd(),
        .dm9k_sd(),
        .dm9k_iow_n(),
        .dm9k_ior_n(),
        .dm9k_cs_n(),
        .dm9k_pwrst_n(),
        .dm9k_int(1'b0),
        .video_red(),
        .video_green(),
        .video_blue(),
        .video_hsync(),
        .video_vsync(),
        .video_clk(),
        .video_de()
    );

    // 时钟源
    clock osc (
        .clk_11M0592(clk_11M0592),
        .clk_50M    (clk_50M)
    );

    // 直连串口仿真模型
    uart_model uart (
        .rxd (txd),
        .txd (rxd)
    );
    // BaseRAM 仿真模型
    sram_model base1 (
        .DataIO(base_ram_data[15:0]),
        .Address(base_ram_addr[19:0]),
        .OE_n(base_ram_oe_n),
        .CE_n(base_ram_ce_n),
        .WE_n(base_ram_we_n),
        .LB_n(base_ram_be_n[0]),
        .UB_n(base_ram_be_n[1])
    );
    sram_model base2 (
        .DataIO(base_ram_data[31:16]),
        .Address(base_ram_addr[19:0]),
        .OE_n(base_ram_oe_n),
        .CE_n(base_ram_ce_n),
        .WE_n(base_ram_we_n),
        .LB_n(base_ram_be_n[2]),
        .UB_n(base_ram_be_n[3])
    );
    // ExtRAM 仿真模型
    sram_model ext1 (
        .DataIO(ext_ram_data[15:0]),
        .Address(ext_ram_addr[19:0]),
        .OE_n(ext_ram_oe_n),
        .CE_n(ext_ram_ce_n),
        .WE_n(ext_ram_we_n),
        .LB_n(ext_ram_be_n[0]),
        .UB_n(ext_ram_be_n[1])
    );
    sram_model ext2 (
        .DataIO(ext_ram_data[31:16]),
        .Address(ext_ram_addr[19:0]),
        .OE_n(ext_ram_oe_n),
        .CE_n(ext_ram_ce_n),
        .WE_n(ext_ram_we_n),
        .LB_n(ext_ram_be_n[2]),
        .UB_n(ext_ram_be_n[3])
    );
endmodule
