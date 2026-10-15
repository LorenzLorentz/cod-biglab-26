`timescale 1ns / 1ps
module lab2_alu_tb;
    typedef enum logic [3:0] {
        ADD = 4'd1,
        SUB = 4'd2,
        AND = 4'd3,
        OR = 4'd4,
        XOR = 4'd5,
        NOT = 4'd6,
        SLL = 4'd7,
        SRL = 4'd8,
        SRA = 4'd9,
        ROL = 4'd10
    } op_t;

    op_t op = ADD;
    logic [15:0] a = 16'h0, b = 16'h0;
    logic [15:0] expect_y = 16'h0;
    logic [15:0] y;

    // 测试模块
    alu dut (
        .a(a),
        .b(b),
        .op(op),
        .y(y)
    );

    int errors = 0;

    task automatic apply(op_t o, logic [15:0] x, logic [15:0] s, logic [15:0] want);
        op = o;
        a = x;
        b = s;
        expect_y = want;
        #10;
        if (y !== want) begin
            errors++;
            $display("FAIL t=%0t %-3s a=%h b=%h: y=%h, want %h", $time, o.name(), x, s, y, want);
        end else begin
            $display("ok   %-3s a=%h b=%h: y=%h", o.name(), x, s, y);
        end
        #10;
    endtask

    // 测试
    initial begin
        // 1. 测试算术和逻辑运算
        apply(ADD, 16'h9a5c, 16'h0f34, 16'ha990);
        apply(SUB, 16'h9a5c, 16'h0f34, 16'h8b28);
        apply(AND, 16'h9a5c, 16'h0f34, 16'h0a14);
        apply(OR, 16'h9a5c, 16'h0f34, 16'h9f7c);
        apply(XOR, 16'h9a5c, 16'h0f34, 16'h9568);
        apply(NOT, 16'h9a5c, 16'h0f34, 16'h65a3);

        // 2. 测试移位结果
        apply(SLL, 16'h9a5c, 16'h0004, 16'ha5c0);
        apply(SRL, 16'h9a5c, 16'h0004, 16'h09a5);
        apply(SRA, 16'h9a5c, 16'h0004, 16'hf9a5);
        apply(ROL, 16'h9a5c, 16'h0004, 16'ha5c9);

        // 3. 测试边界情况: 加减溢出回绕、移 15 位、正数算术右移补 0、循环移 0 位
        apply(ADD, 16'hffff, 16'h0001, 16'h0000);
        apply(SUB, 16'h0000, 16'h0001, 16'hffff);
        apply(SLL, 16'h0001, 16'h000f, 16'h8000);
        apply(SRL, 16'h8000, 16'h000f, 16'h0001);
        apply(SRA, 16'h8000, 16'h000f, 16'hffff);
        apply(SRA, 16'h7000, 16'h0004, 16'h0700);
        apply(ROL, 16'h8001, 16'h0001, 16'h0003);
        apply(ROL, 16'h8001, 16'h0000, 16'h8001);

        if (errors == 0) begin
            $display("lab2_alu_tb: PASS");
        end else begin
            $fatal(1, "lab2_alu_tb: %0d FAILED", errors);
        end
        $finish;
    end
endmodule
