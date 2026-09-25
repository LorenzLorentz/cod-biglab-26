module reg_file (
    input logic clk,
    input logic rst,

    input logic [4:0] raddr_a,
    output logic [15:0] rdata_a,
    input logic [4:0] raddr_b,
    output logic [15:0] rdata_b,

    input logic [4:0] waddr,
    input logic [15:0] wdata,
    input logic we
);
    // 内部信号: 寄存器堆
    logic [15:0] rf [32];

    // 组合逻辑: 读操作
    assign rdata_a = (raddr_a == 5'd0) ? 16'h0 : rf[raddr_a];
    assign rdata_b = (raddr_b == 5'd0) ? 16'h0 : rf[raddr_b];

    // 时序逻辑: 写操作
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) begin
                rf[i] <= 16'h0;
            end
        end else if (we && (waddr != 5'd0)) begin // 0 号寄存器的数据恒为 0, 而对其的写入操作将被忽略
            rf[waddr] <= wdata;
        end
    end
endmodule
