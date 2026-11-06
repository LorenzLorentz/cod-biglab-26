module cpu_reg_file (
    input logic clk,
    input logic rst,

    input logic [4:0] raddr_a,
    output logic [31:0] rdata_a,
    input logic [4:0] raddr_b,
    output logic [31:0] rdata_b,

    input logic [4:0] waddr,
    input logic [31:0] wdata,
    input logic we
);
    // 内部信号: 寄存器堆
    logic [31:0] rf [32];

    // 组合逻辑: 读操作
    assign rdata_a = (raddr_a == 5'd0) ? 32'b0 :
        (we && waddr == raddr_a) ? wdata : rf[raddr_a];
    assign rdata_b = (raddr_b == 5'd0) ? 32'h0 :
        (we && waddr == raddr_b) ? wdata : rf[raddr_b];

    // 时序逻辑: 写操作
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) begin
                rf[i] <= 32'h0;
            end
        end else if (we && (waddr != 5'd0)) begin // 0 号寄存器的数据恒为 0, 而对其的写入操作将被忽略
            rf[waddr] <= wdata;
        end
    end
endmodule
