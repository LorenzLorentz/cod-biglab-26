// systolic_array.sv - 脉动阵列（N x N 个 PE）
//
// 其功能如下：
// 1. 执行 LDTILE 指令时，B 矩阵的 int8 元素从脉动阵列顶部，
//    以从 B 矩阵的最后一行开始，到第一行结束的顺序，逐拍通过 b_ld_data 注入一行数据，
//    逐行向下流动；注入 N 拍后，所有 PE 内部保存了对应的 int8 元素。
// 2. 执行 TMUL 指令时，A 矩阵的元素从左边斜入（a_left），
//    A[i][j] 在拍 i+j 从行 j 进入阵列，逐列向右流动。
// 3. 部分和从阵列顶部注入（恒为零），沿列向下累加 b_reg * a_in，完整结果从底部
//    （sum_bottom）斜出：C[i][j] 在拍 i+j+N 从列 j 离开阵列。

module systolic_array #(
    parameter PE_N = 4,    // 阵列大小（N x N）
    parameter A_DW = 8,    // A/B 元素位宽
    parameter C_DW = 32    // C 元素位宽（部分和）
) (
    input  wire                        clk,
    input  wire                        rst,

    // B 元素：从顶部逐拍注入一行（LDTILE）
    input  wire                        b_ld_en,     // 写入使能
    input  wire signed [PE_N*A_DW-1:0] b_ld_data,   // 从顶部注入的一行 B

    // A 元素：从左边斜入（TMUL）
    input  wire signed [PE_N*A_DW-1:0] a_left,      // A[i][j] 在拍 i+j 从行 j 进入阵列

    // 部分和：从底部斜出（TMUL）
    output wire signed [PE_N*C_DW-1:0] sum_bottom   // C[i][j] 在拍 i+j+N 从列 j 离开阵列
);

  // PE 阵列连线
  wire signed [PE_N-1:0][PE_N-1:0][A_DW-1:0] pe_a_in, pe_a_out;
  wire signed [PE_N-1:0][PE_N-1:0][C_DW-1:0] pe_sum_in, pe_sum_out;
  wire signed [PE_N-1:0][PE_N-1:0][A_DW-1:0] pe_b_in, pe_b_out;

  // 例化 N x N 个 PE
  generate
    for (genvar i = 0; i < PE_N; i++) begin : gen_row
      for (genvar j = 0; j < PE_N; j++) begin : gen_col
        pe #(
            .A_DW  (A_DW),
            .C_DW  (C_DW)
        ) u_pe (
            .clk      (clk),
            .rst      (rst),
            .b_ld_en  (b_ld_en),
            .b_in     (pe_b_in[i][j]),
            .b_out    (pe_b_out[i][j]),
            .a_in     (pe_a_in[i][j]),
            .sum_in   (pe_sum_in[i][j]),
            .a_out    (pe_a_out[i][j]),
            .sum_out  (pe_sum_out[i][j])
        );
      end
    end
  endgenerate

  // B 矩阵
  // 第 0 行 PE 从顶部注入 b_ld_data 数据用于 LDTILE
  for (genvar j = 0; j < PE_N; j++) begin : gen_b_top
    assign pe_b_in[0][j] = b_ld_data[j*A_DW +: A_DW];
  end
  // 从第 i 行 PE 向下传播 B 元素到第 i+1 行 PE
  for (genvar i = 1; i < PE_N; i++) begin : gen_b_mid
    for (genvar j = 0; j < PE_N; j++) begin : gen_b_mid_j
      assign pe_b_in[i][j] = pe_b_out[i-1][j];
    end
  end

  // A 矩阵
  // 第 0 列 PE 注入 a_left 数据用于 TMUL
  for (genvar i = 0; i < PE_N; i++) begin : gen_a_left
    assign pe_a_in[i][0] = a_left[i*A_DW +: A_DW];
  end
  // 从第 i 列 PE 向右传播 A 元素到第 i+1 列 PE
  for (genvar j = 1; j < PE_N; j++) begin : gen_a_mid
    for (genvar i = 0; i < PE_N; i++) begin : gen_a_mid_i
      assign pe_a_in[i][j] = pe_a_out[i][j-1];
    end
  end

  // 部分和
  // 第 0 行，顶部恒为零
  for (genvar j = 0; j < PE_N; j++) begin : gen_sum_top
    assign pe_sum_in[0][j] = '0;
  end
  // 第 i 行 PE 向下传播部分和到 第 i+1 行 PE
  for (genvar i = 1; i < PE_N; i++) begin : gen_sum_mid
    for (genvar j = 0; j < PE_N; j++) begin : gen_sum_mid_j
      assign pe_sum_in[i][j] = pe_sum_out[i-1][j];
    end
  end

  // 底部从最后一行 PE 输出
  for (genvar j = 0; j < PE_N; j++) begin : gen_sum_bottom
    assign sum_bottom[j*C_DW +: C_DW] = pe_sum_out[PE_N-1][j];
  end

endmodule
