`timescale 1ns / 1ps
module lab2_tb;
    wire clk_50M, clk_11M0592;

    reg push_btn;   // BTN5 按钮开关，带消抖电路，按下时为 1
    reg reset_btn;  // BTN6 复位按钮，带消抖电路，按下时为 1

    reg [3:0] touch_btn; // BTN1~BTN4，按钮开关，按下时为 1
    reg [31:0] dip_sw;   // 32 位拨码开关，拨到“ON”时为 1

    wire [15:0] leds;  // 16 位 LED，输出时 1 点亮
    wire [7:0] dpy0;   // 数码管低位信号，包括小数点，输出 1 点亮
    wire [7:0] dpy1;   // 数码管高位信号，包括小数点，输出 1 点亮

    // 实验 3 用到的指令格式
    `define inst_rtype(rd, rs1, rs2, op) \
        {7'b0, rs2, rs1, 3'b0, rd, op, 3'b001}

    `define inst_itype(rd, imm, op) \
        {imm, 4'b0, rd, op, 3'b010}

    `define inst_poke(rd, imm) `inst_itype(rd, imm, 4'b0001)
    `define inst_peek(rd, imm) `inst_itype(rd, imm, 4'b0010)

    // opcode table
    typedef enum logic [3:0] {
        ADD = 4'b0001,
        SUB = 4'b0010,
        AND = 4'b0011,
        OR  = 4'b0100,
        XOR = 4'b0101,
        NOT = 4'b0110,
        SLL = 4'b0111,
        SRL = 4'b1000,
        SRA = 4'b1001,
        ROL = 4'b1010
    } opcode_t;

    logic is_rtype, is_itype, is_load, is_store, is_unknown;
    logic [15:0] imm;
    logic [4:0] rd, rs1, rs2;
    logic [3:0] opcode;

    int errors = 0;

    // 执行一条指令: 拨好开关 -> 按下 push_btn 500ns（clk_10M 的 5 个周期, 同时检验长按只执行一条）-> 松开, 再等 1000ns 让状态机走完.
    task automatic exec(input logic [31:0] inst, input string text);
        dip_sw = inst;
        $display("dip_sw = 32'h%h  %s", inst, text);
        #200;
        push_btn = 1;
        #500;
        push_btn = 0;
        #1000;
    endtask

    // PEEK 并检查 LED
    task automatic peek(input logic [4:0] r, input logic [15:0] want);
        exec(`inst_peek(r, 16'h0), $sformatf("PEEK x%0d", r));
        if (leds !== want) begin
            errors++;
            $display("FAIL: PEEK x%0d: leds = %h, want %h", r, leds, want);
        end else begin
            $display("ok:  PEEK x%0d: leds = %h", r, leds);
        end
    endtask

    // 测试
    initial begin
        dip_sw = 32'h0;
        touch_btn = 0;
        reset_btn = 0;
        push_btn = 0;

        // 等复位结束
        #100;
        reset_btn = 1;
        #100;
        reset_btn = 0;
        wait (dut.locked === 1'b1);
        wait (dut.reset_of_clk10M === 1'b0);
        #300;

        // POKE 两个操作数 -> 两条计算指令 -> PEEK 读回结果
        exec(`inst_poke(5'd1, 16'h1234), "POKE x1, 0x1234");
        exec(`inst_poke(5'd2, 16'h0f0f), "POKE x2, 0x0f0f");
        exec(`inst_rtype(5'd3, 5'd1, 5'd2, ADD), "ADD x3, x1, x2");  // 1234 + 0f0f = 2143
        exec(`inst_rtype(5'd4, 5'd1, 5'd2, XOR), "XOR x4, x1, x2");  // 1234 ^ 0f0f = 1d3b
        peek(5'd3, 16'h2143);
        peek(5'd4, 16'h1d3b);
        peek(5'd1, 16'h1234);

        if (errors == 0) begin
            $display("lab2_tb: PASS");
        end else begin
            $fatal(1, "lab2_tb: %0d FAILED", errors);
        end
        #500 $finish;
    end

    // 待测试用户设计
    lab2_top dut (
        .clk_50M(clk_50M),
        .clk_11M0592(clk_11M0592),
        .push_btn(push_btn),
        .reset_btn(reset_btn),
        .touch_btn(touch_btn),
        .dip_sw(dip_sw),
        .leds(leds),
        .dpy1(dpy1),
        .dpy0(dpy0),

        .txd(),
        .rxd(1'b1),
        .uart_rdn(),
        .uart_wrn(),
        .uart_dataready(1'b0),
        .uart_tbre(1'b0),
        .uart_tsre(1'b0),
        .base_ram_data(),
        .base_ram_addr(),
        .base_ram_ce_n(),
        .base_ram_oe_n(),
        .base_ram_we_n(),
        .base_ram_be_n(),
        .ext_ram_data(),
        .ext_ram_addr(),
        .ext_ram_ce_n(),
        .ext_ram_oe_n(),
        .ext_ram_we_n(),
        .ext_ram_be_n(),
        .flash_d(),
        .flash_a(),
        .flash_rp_n(),
        .flash_vpen(),
        .flash_oe_n(),
        .flash_ce_n(),
        .flash_byte_n(),
        .flash_we_n()
    );

    // 时钟源
    clock osc (
        .clk_11M0592(clk_11M0592),
        .clk_50M(clk_50M)
    );
endmodule
