module sig_gen(
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,

    output logic rf_w_en, // reg file 写使能
    output logic mem_rw, // mem 读写使能, 0 读 1 写
    output logic mem_width, // mem 读写位宽, 0 表示 byte, 1 表示 word
    output logic alu_a_sel, // alu_a 选择
    output logic alu_b_sel, // alu_b 选择
    output logic alu_op, // alu_b 选择
    output logic [1:0] pc_sel, // pc 信号选择
    output logic [1:0] wb_sel // 写会选择
);

endmodule
