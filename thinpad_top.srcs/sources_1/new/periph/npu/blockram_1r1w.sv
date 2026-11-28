// blockram_1r1w.sv - 简单双口块 RAM（SDP，Simple Dual Port RAM）封装
//
// 其功能如下：
// 1. 写端口 A（同步写）、读端口 B（同步读，1 拍延迟，与 BRAM 语义一致）。
// 2. 每周期最多 1 次写和 1 次读，读写可同时进行（不同地址）。
// 3. 用于 NPU 的 L0A/L0B/L0C 三块片上存储。

module blockram_1r1w #(
    parameter DEPTH  = 64,    // 深度
    parameter DATA_W = 32,    // 位宽
    localparam A_W = $clog2(DEPTH)
) (
    input  wire clk,
    input  wire rst,

    // 写端口 A
    input  wire                wea,
    input  wire [A_W-1:0]      addra,
    input  wire [DATA_W-1:0]   dina,

    // 读端口 B
    input  wire                enb,
    input  wire [A_W-1:0]      addrb,
    output wire [DATA_W-1:0]   doutb
);

  // 行为模型，与 BRAM 语义一致
  reg [DATA_W-1:0] mem [0:DEPTH-1];
  reg [DATA_W-1:0] doutb_reg;

  // 写：wea 时写入；读：enb 时下一拍输出
  always_ff @(posedge clk) begin
    if (wea) mem[addra] <= dina;
    if (enb) doutb_reg <= mem[addrb];
  end
  assign doutb = doutb_reg;

endmodule
