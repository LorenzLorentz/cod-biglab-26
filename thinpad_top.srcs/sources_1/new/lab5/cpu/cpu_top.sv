module cpu_top (
    input logic clk,
    input logic rst,

    // 指令总线
    output logic inst_req,
    output logic [31:0] inst_addr,
    input [31:0] inst_data,
    input inst_ready,

    // 数据总线
    output logic mem_req,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    input [31:0] mem_rdata,
    output logic mem_we,
    output logic [3:0] mem_sel,
    input mem_ready
);
    // 内部状态
    // 1. IF 阶段
    logic [31:0] pc; // 当前 PC 寄存器值
    logic [31:0] next_pc; // 下一个周期 PC 的候选值
    logic [31:0] pc_plus_4; // pc + 4 的顺序加法结果

    // 2.1 ID 阶段
    // 数据
    logic [31:0] inst; // 当前执行的指令
    logic [6:0] opcode;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rd;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [2:0] imm_type;
    logic [31:0] imm;

    // 信号
    logic rf_w_en; // reg file 写使能
    // logic mem_rw; // mem 读写使能, 0 读 1 写
    // logic mem_width; // mem 读写位宽, 0 表示 byte, 1 表示 word
    logic alu_a_sel; // alu_a 选择
    logic alu_b_sel; // alu_b 选择
    logic [1:0] pc_sel; // pc 信号选择
    logic [1:0] wb_sel; // 写回选择

    // 状态
    logic is_load;
    logic is_store;
    logic is_mem_access;
    logic rf_commit_en;

    // 2.2 RF 阶段
    logic [31:0] rf_rdata1; // 从 RegFile 读出的 rs1 数据
    logic [31:0] rf_rdata2; // 从 RegFile 读出的 rs2 数据

    // 3. EX 阶段
    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic [1:0] alu_op;
    logic [31:0] alu_result;
    logic br_eq;

    // 4. MEM 阶段
    logic [31:0] rf_wdata; // 最终准备写回 RegFile 的数据

    // 执行
    // decode
    inst_decoder u_inst_decoder (
        .inst(inst),
        .opcode(opcode),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .imm_type(imm_type),
        .funct3(funct3),
        .funct7(funct7)
    );

    assign is_load = (opcode == 7'b0000011);
    assign is_store = (opcode == 7'b0100011);
    assign is_mem_access = is_load || is_store;

    // sig gen
    sig_gen u_sig_gen (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .rf_w_en(rf_w_en),
        .mem_req(mem_req),
        .mem_we(mem_we),
        .mem_sel(mem_sel),
        .alu_a_sel(alu_a_sel),
        .alu_b_sel(alu_b_sel),
        .alu_op(alu_op),
        .pc_sel(pc_sel),
        .wb_sel(wb_sel)
    );

    // imm gen
    imm_gen u_imm_gen (
        .inst(inst),
        .imm_type(imm_type),
        .imm(imm)
    );

    // rf
    reg_file u_reg_file (
        .clk(clk),
        .rst(rst),
        .raddr_a(rs1),
        .rdata_a(rf_rdata1),
        .raddr_b(rs2),
        .rdata_b(rf_rdata2),
        .waddr(rd),
        .wdata(rf_wdata),
        .we(rf_commit_en)
    );

    // alu
    // alu_a: 0 -> data; 1 -> pc
    // alu_b: 0 -> data; 1 -> imm
    assign alu_a = alu_a_sel ? pc : rf_rdata1;
    assign alu_b = alu_b_sel ? imm : rf_rdata2;

    alu u_alu (
        .a(alu_a),
        .b(alu_b),
        .op(alu_op),
        .result(alu_result)
    );

    // br
    branch_comp u_branch_comp (
        .a(rf_rdata1),
        .b(rf_rdata2),
        .breq(br_eq)
    );

    // mem
    assign mem_addr = alu_result;
    assign mem_wdata = rf_rdata2;

    // wb
    // wb_sel: 0 -> mem_rdata (符号扩展); 1 -> alu_result; 2 -> pc + 4
    assign rf_wdata = (wb_sel == 2'b00) ? {{24{mem_rdata[7]}}, mem_rdata} :
        (wb_sel == 2'b01) ? alu_result : pc_plus_4;

    // next pc
    // pc_sel: 0 -> pc + 4; 1 -> alu result; 2 -> mem_rdata
    assign next_pc = (pc_sel == 2'b00 || !br_eq) ? pc_plus_4 :
        (pc_sel == 2'b01) ? alu_result : mem_rdata;
endmodule
