// pe.sv - 脉动阵列中的处理单元（PE，Processing Element）
//
// 其功能如下：
// 1. PE 的功能是进行 int8（来自 A 矩阵）x int8（来自 B 矩阵）计算，乘积累加到 int32（C 矩阵）。
// 2. B 矩阵的 int8 元素保存在 PE 内部的 b_reg 寄存器，通过 LDTILE 指令加载：
//    从 B 的最后一行开始到第一行结束，倒序读取，从阵列顶部每拍注入一行，
//    元素从上方 PE（或阵列顶部）通过 b_in 流入，b_reg 每拍写入 b_in 并向下传播
//    （b_reg 通过 b_out 直接输出）；注入 N 拍后，所有 PE 保存了对应的 B 矩阵元素。
//    计算期间 b_ld_en 为 0，b_reg 保持不变（即 B 驻留在 PE 当中）。
// 3. 执行 TMUL 指令时，A 矩阵的 int8 元素从左方 PE（或左边缘）通过 a_in 流入，
//    在 a_out_reg 中延迟一拍后，通过 a_out 传给右方 PE。
// 4. 同时 int32 部分和 sum_in 从上方 PE（或阵列顶部，此时 sum_in 恒为零）流入，
//    累加 b_reg * a_in 后，下一拍通过 sum_out 传给下方 PE。

module pe #(
    parameter A_DW = 8,     // 输入数据位宽（A/B 元素）
    parameter C_DW = 32     // 输出数据位宽（C 元素）
) (
    input  wire                   clk,
    input  wire                   rst,

    // B 元素：从上方 PE（或阵列顶部）流入，向下传播
    input  wire                   b_ld_en, // LDTILE 写入使能
    input  wire signed [A_DW-1:0] b_in,    // 来自上方 PE（或阵列顶部）的 B 元素
    output wire signed [A_DW-1:0] b_out,   // 传给下方 PE（1 拍延迟）

    // A 元素：从左方 PE（或左边缘）流入，向右传播
    input  wire signed [A_DW-1:0] a_in,    // 来自左方 PE（或左边缘）的 A 元素
    output wire signed [A_DW-1:0] a_out,   // 传给右方 PE（1 拍延迟）

    // 部分和：从上方 PE（或阵列顶部）流入，向下传播
    input  wire signed [C_DW-1:0] sum_in,  // 来自上方 PE（或阵列顶部）的部分和
    output wire signed [C_DW-1:0] sum_out  // 传给下方 PE
);

  // B 元素寄存器：加载 B 矩阵元素期间（b_ld_en 为真）每拍写入 b_in，同时向下流动；
  // 之后 b_ld_en 为 0，b_reg 保持不变
  reg signed [A_DW-1:0] b_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      b_reg <= '0;
    end else begin
      if (b_ld_en) b_reg <= b_in;     // 写入并向下流动
    end
  end
  assign b_out = b_reg;               // 向下传播

  // A 元素右传寄存器：实现 A 元素从左到右的流动
  reg signed [A_DW-1:0] a_out_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      a_out_reg <= '0;
    end else begin
      a_out_reg <= a_in;              // A 向右流动，1 拍延迟
    end
  end
  assign a_out = a_out_reg;

  // 部分和寄存器：实现乘加运算，从上方流入 sum_in，计算 sum_in + b_reg * a_in 向下流动
  reg signed [C_DW-1:0] sum_out_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      sum_out_reg <= '0;
    end else begin
      // 乘加：sum_in + b_reg * a_in，1 拍延迟
      sum_out_reg <= sum_in + b_reg * a_in;
    end
  end
  assign sum_out = sum_out_reg;
endmodule
