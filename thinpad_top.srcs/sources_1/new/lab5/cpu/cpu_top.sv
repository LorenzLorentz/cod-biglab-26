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
    // 流水线寄存器
    // IF -> ID
    typedef struct packed {
        // 是否有效
        logic valid;

        // ID 需要
        logic [31:0] inst;

        // 后续需要
        logic [31:0] pc; // EX 需要
        logic [31:0] pc_plus_4; // WB 需要
    } if_id_t;

    // ID -> EX
    typedef struct packed {
        // 是否有效
        logic valid;

        // EX 需要
        // alu_a
        logic [31:0] rf_rdata1; // 从 RegFile 读出的 rs1 数据; sel = 0
        logic [31:0] pc; // sel = 1
        logic alu_a_sel; // alu_a 选择
        // alu_b
        logic [31:0] rf_rdata2; // 从 RegFile 读出的 rs2 数据; sel = 0
        logic [31:0] imm; // sel = 1
        logic alu_b_sel; // alu_b 选择
        // alu_op
        logic [1:0] alu_op;
        // bc op
        logic [1:0] bc_op; // 暂时不需要
        // pc_sel
        logic [1:0] pc_sel;

        // 后续需要
        logic mem_req; // MEM 需要
        logic mem_we; // MEM 需要
        logic [3:0] mem_sel; // MEM 需要
        logic mem_load_is_signed;// MEM 需要
        logic [4:0] rd; // WB 需要
        logic [31:0] pc_plus_4; // WB 需要
        logic rf_w_en; // WB 需要
        logic wb_sel; // WB 需要
    } id_ex_t;

    // EX -> MEM
    typedef struct packed {
        // 是否有效
        logic valid;

        // MEM 需要
        // 访问地址
        logic [31:0] alu_result;
        // 写入内容
        logic [31:0] rf_rdata2;
        // 相关使能
        logic mem_req;
        logic mem_we;
        logic [3:0] mem_sel;
        logic mem_load_is_signed;

        // 后续需要
        logic [4:0] rd; // WB 需要
        logic [31:0] pc_plus_4; // WB 需要
        logic rf_w_en; // WB 需要
        logic wb_sel; // WB 需要
    } ex_mem_t;

    // MEM -> WB
    typedef struct packed {
        // 是否有效
        logic valid;

        // WB 需要
        // 访问地址
        logic [4:0] rd;
        // 写入内容
        logic [31:0] wb_data; // 注意根据 mem_sel 和 mem_load_is_signed 做扩展
        // 相关使能
        logic rf_w_en;
        // logic [1:0] wb_sel;
    } mem_wb_t;

    if_id_t if_id;
    id_ex_t id_ex;
    ex_mem_t ex_mem;
    mem_wb_t mem_wb;

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
    assign rf_wdata = (wb_sel == 2'b00) ? {{24{mem_rdata[7]}}, mem_rdata[7:0]} :
        (wb_sel == 2'b01) ? alu_result : pc_plus_4;

    // next pc
    // pc_sel: 0 -> pc + 4; 1 -> alu result; 2 -> mem_rdata
    assign next_pc = (pc_sel == 2'b00 || !br_eq) ? pc_plus_4 :
        (pc_sel == 2'b01) ? alu_result : mem_rdata;
endmodule
