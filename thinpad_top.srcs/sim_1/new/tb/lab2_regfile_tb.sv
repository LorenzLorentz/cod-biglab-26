`timescale 1ns / 1ps
module lab2_regfile_tb;
    logic clk = 0;
    logic rst = 1;
    logic we = 0;
    logic [4:0] waddr = 5'd0;
    logic [4:0] raddr_a = 5'd0;
    logic [4:0] raddr_b = 5'd0;
    logic [15:0] wdata = 16'h0;
    logic [15:0] rdata_a;
    logic [15:0] rdata_b;

    // 测试模块
    reg_file dut (
        .clk(clk),
        .rst(rst),
        .raddr_a(raddr_a),
        .rdata_a(rdata_a),
        .raddr_b(raddr_b),
        .rdata_b(rdata_b),
        .waddr(waddr),
        .wdata(wdata),
        .we(we)
    );

    // 生成时钟
    always #50 clk = ~clk;

    wire [15:0] x0 = dut.rf[0];
    wire [15:0] x2 = dut.rf[2];
    wire [15:0] x4 = dut.rf[4];
    wire [15:0] x26 = dut.rf[26];
    wire [15:0] x31 = dut.rf[31];
    logic [15:0] model[32];

    int errors = 0;

    // 写端口给 we=w, waddr=wa, wdata=wd, 读端口给 ra 和 rb
    task automatic cycle(logic w, logic [4:0] wa, logic [15:0] wd, logic [4:0] ra, logic [4:0] rb);
        @(negedge clk);
        we = w;
        waddr = wa;
        wdata = wd;
        raddr_a = ra;
        raddr_b = rb;
        #10;
        if (rdata_a !== model[ra] || rdata_b !== model[rb]) begin // 验证读到的值
            errors++;
            $display(
                "FAIL t=%0t x%0d=%h (want %h)  x%0d=%h (want %h)", $time, ra, rdata_a,
                model[ra], rb, rdata_b, model[rb]
            );
        end
        @(posedge clk);
        if (w && wa != 5'd0) model[wa] = wd; // 如果写入, 更新写入的值
    endtask

    task automatic reset();
        @(negedge clk);
        rst = 1;
        we = 0;
        @(posedge clk);
        foreach (model[i])
            model[i] = 16'h0;
        @(negedge clk);
        rst = 0;
    endtask

    // 测试
    initial begin
        // 1. 上电复位: 复位后全部为 0
        reset();
        cycle(0, 5'd0, 16'h0, 5'd1, 5'd31);

        // 2. 文档里的例子
        cycle(1, 5'd2, 16'h0012, 5'd2, 5'd4); // 写 x2: A 口读 x2, 上升沿前是旧值 0, 之后变成 0012
        cycle(1, 5'd4, 16'h0034, 5'd2, 5'd4); // 写 x4: B 口读 x4, 上升沿后变成 0034
        cycle(0, 5'd0, 16'h0, 5'd26, 5'd4); // 读 x26 = 0000, x4 = 0034
        cycle(1, 5'd26, 16'h0056, 5'd26, 5'd2); // 写 x26 = 0056
        cycle(1, 5'd2, 16'h0078, 5'd26, 5'd2); // 写 x2 = 0078
        cycle(0, 5'd0, 16'h0, 5'd4, 5'd2); // 读 x4 = 0034, x2 = 0078

        // 3. we = 0 时 waddr / wdata 再怎么变也不写入
        cycle(0, 5'd4, 16'hffff, 5'd4, 5'd4);
        cycle(0, 5'd0, 16'h0, 5'd4, 5'd4); // x4 仍是 0034

        // 4. 写 0 号寄存器被忽略, 读 x0 恒为 0
        cycle(1, 5'd0, 16'hdead, 5'd0, 5'd0);
        cycle(0, 5'd0, 16'h0, 5'd0, 5'd0);

        // 5. 最大地址 x31
        cycle(1, 5'd31, 16'hffff, 5'd31, 5'd26);
        cycle(0, 5'd0, 16'h0, 5'd31, 5'd2);

        // 6. 再次复位, 写过的寄存器全部清零
        reset();
        cycle(0, 5'd0, 16'h0, 5'd2, 5'd31);

        if (errors == 0) begin
            $display("lab2_regfile_tb: PASS");
        end else begin
            $fatal(1, "lab2_regfile_tb: %0d FAILED", errors);
        end
        #50 $finish;
    end
endmodule
