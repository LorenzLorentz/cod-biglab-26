// shift_register.sv - 可配置深度的打拍移位寄存器
//
// 其功能如下：
// 1. 把 din 延迟 DEPTH 拍后从 dout 输出（内部 DEPTH 级寄存器链）。
// 2. DEPTH = 0 时直通（dout = din，组合逻辑），用于不需要打拍的路径。
// 3. 用于脉动阵列的斜入/斜出：A 按行读出后经一系列打拍寄存器实现斜入
//    （从阵列左边缘传入），C 从底部逐渐斜出后经一系列寄存器对齐，
//    使原本错开一拍的数据在同一拍对齐。

module shift_register #(
    parameter DATA_W = 32,   // 数据位宽
    parameter DEPTH   = 4    // 打拍数（寄存器个数，0 = 直通）
) (
    input  wire clk,
    input  wire rst,
    input  wire [DATA_W-1:0] din,
    output wire [DATA_W-1:0] dout
);

generate
  if (DEPTH == 0) begin : gen_direct
    assign dout = din;
  end else begin : gen_shift
    // DEPTH 级打拍寄存器链
    reg [DATA_W-1:0] regs [0:DEPTH-1];
    always_ff @(posedge clk) begin
      if (rst) begin
        for (int i = 0; i < DEPTH; i++) regs[i] <= '0;
      end else begin
        regs[0] <= din;
        for (int i = 1; i < DEPTH; i++) regs[i] <= regs[i-1];
      end
    end
    assign dout = regs[DEPTH-1];
  end
endgenerate

endmodule
