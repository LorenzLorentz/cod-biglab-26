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
        // ID 需要
        logic [31:0] inst;

        // 后续需要
        logic [31:0] pc; // EX 需要
        logic [31:0] pc_plus_4; // WB 需要
    } if_id_t;

    // ID -> EX
    typedef struct packed {
        // forwarding
        logic [4:0] rs1;
        logic [4:0] rs2;

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
        logic [3:0] alu_op;
        // 操作数是否真的被使用
        logic use_rs1;
        logic use_rs2;
        // bc op
        // logic [1:0] bc_op; // 暂时不需要
        // pc_sel
        logic [1:0] pc_sel;

        // 后续需要
        logic mem_req; // MEM 需要
        logic mem_we; // MEM 需要
        logic [3:0] mem_sel; // MEM 需要
        // logic mem_load_is_unsigned;// MEM 需要
        logic [4:0] rd; // WB 需要
        logic [31:0] pc_plus_4; // WB 需要
        logic rf_w_en; // WB 需要
        logic [1:0] wb_sel; // WB 需要
    } id_ex_t;

    // EX -> MEM
    typedef struct packed {
        // MEM 需要
        // 访问地址
        logic [31:0] alu_result;
        // 写入内容
        logic [31:0] rf_rdata2;
        // 相关使能
        logic mem_req;
        logic mem_we;
        logic [3:0] mem_sel;
        // logic mem_load_is_unsigned;

        // 后续需要
        logic [4:0] rd; // WB 需要
        logic [31:0] pc_plus_4; // WB 需要
        logic rf_w_en; // WB 需要
        logic [1:0] wb_sel; // WB 需要
    } ex_mem_t;

    // MEM -> WB
    typedef struct packed {
        // WB 需要
        // 访问地址
        logic [4:0] rd;
        // 写入内容
        logic [31:0] wb_data; // 注意根据 mem_sel 和 mem_load_is_unsigned 做扩展
        // 相关使能
        logic rf_w_en;
    } mem_wb_t;

    if_id_t if_id, if_id_next;
    id_ex_t id_ex, id_ex_next;
    ex_mem_t ex_mem, ex_mem_next;
    mem_wb_t mem_wb, mem_wb_next;

    // 控制信号
    // stall
    logic pc_stall;
    logic if_id_stall;
    logic global_stall;
    assign global_stall = (inst_req && !inst_ready) || (mem_req  && !mem_ready);

    // flush
    logic if_id_flush;
    logic id_ex_flush;

    // 执行
    // 1. IF阶段
    // 内部状态
    logic [31:0] pc;
    logic [31:0] pc_plus_4;
    logic [31:0] pc_next;

    assign pc_plus_4 = pc + 4;
    // pc_sel: 0 -> pc_plus_4; 1 -> alu_result (pc + offset)
    assign pc_next = branch_taken ? ex_mem_next.alu_result : pc_plus_4;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= 32'h8000_0000;
        end else if (global_stall || pc_stall) begin
            pc <= pc;
        end else begin
            pc <= pc_next;
        end
    end

    assign inst_req = 1'b1;
    assign inst_addr = pc;

    // 传递
    always_comb begin
        if_id_next.inst = inst_data;
        if_id_next.pc = pc;
        if_id_next.pc_plus_4 = pc_plus_4;
    end

    // 2. ID阶段
    // 内部状态
    logic [6:0] opcode;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [2:0] imm_type;
    logic use_rs1;
    logic use_rs2;

    // inst decode
    inst_decoder u_inst_decoder (
        .inst(if_id.inst),
        .opcode(opcode),
        .rs1(rs1),
        .rs2(rs2),
        .rd(id_ex_next.rd),
        .imm_type(imm_type),
        .funct3(funct3),
        .funct7(funct7)
    );

    // sig gen
    sig_gen u_sig_gen (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .funct5(rs2),
        .rf_w_en(id_ex_next.rf_w_en),
        .mem_req(id_ex_next.mem_req),
        .mem_we(id_ex_next.mem_we),
        .mem_sel(id_ex_next.mem_sel),
        // .mem_load_is_unsigned(id_ex_next.mem_load_is_unsigned),
        .alu_a_sel(id_ex_next.alu_a_sel),
        .alu_b_sel(id_ex_next.alu_b_sel),
        .alu_op(id_ex_next.alu_op),
        .pc_sel(id_ex_next.pc_sel),
        .wb_sel(id_ex_next.wb_sel),
        .use_rs1(use_rs1),
        .use_rs2(use_rs2)
    );

    // imm gen
    imm_gen u_imm_gen (
        .inst(if_id.inst),
        .imm_type(imm_type),
        .imm(id_ex_next.imm)
    );

    // rf & 5. WB 阶段
    cpu_reg_file u_reg_file (
        .clk(clk),
        .rst(rst),
        .raddr_a(rs1),
        .rdata_a(id_ex_next.rf_rdata1),
        .raddr_b(rs2),
        .rdata_b(id_ex_next.rf_rdata2),
        .waddr(mem_wb.rd),
        .wdata(mem_wb.wb_data),
        .we(mem_wb.rf_w_en)
    );

    // stall
    logic load_use_hazard;
    assign load_use_hazard = (id_ex.mem_req && !id_ex.mem_we && id_ex.rf_w_en)
        && (id_ex.rd != 5'b0)
        && ((use_rs1 && (id_ex.rd == rs1)) || (use_rs2 && (id_ex.rd == rs2)));
    assign pc_stall = load_use_hazard;
    assign if_id_stall = pc_stall;

    // 传递
    always_comb begin
        id_ex_next.rs1 = rs1;
        id_ex_next.rs2 = rs2;
        id_ex_next.use_rs1 = use_rs1;
        id_ex_next.use_rs2 = use_rs2;
        id_ex_next.pc = if_id.pc;
        id_ex_next.pc_plus_4 = if_id.pc_plus_4;
    end

    // 3. EX 阶段
    // 内部状态
    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic br_eq;
    logic branch_taken;
    logic [31:0] rf_rdata1_with_forwarding_considered;
    logic [31:0] rf_rdata2_with_forwarding_considered;

    // alu
    // forwarding
    always_comb begin
        rf_rdata1_with_forwarding_considered = id_ex.rf_rdata1;
        rf_rdata2_with_forwarding_considered = id_ex.rf_rdata2;

        if (id_ex.use_rs1 && ex_mem.rf_w_en
            && (ex_mem.rd != 5'b0) && (ex_mem.rd == id_ex.rs1)) begin // 要写回但还没有
            rf_rdata1_with_forwarding_considered = (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result
                : ex_mem.pc_plus_4;
        end else if (id_ex.use_rs1 && mem_wb.rf_w_en
            && (mem_wb.rd != 5'b0) && (mem_wb.rd == id_ex.rs1)) begin
            rf_rdata1_with_forwarding_considered = mem_wb.wb_data;
        end

        if (id_ex.use_rs2 && ex_mem.rf_w_en
            && (ex_mem.rd != 5'b0) && (ex_mem.rd == id_ex.rs2)) begin
            rf_rdata2_with_forwarding_considered = (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result
                : ex_mem.pc_plus_4;
        end else if (id_ex.use_rs2 && mem_wb.rf_w_en
            && (mem_wb.rd != 5'b0) && (mem_wb.rd == id_ex.rs2)) begin
            rf_rdata2_with_forwarding_considered = mem_wb.wb_data;
        end
    end

    // alu_a: 0 -> data; 1 -> pc
    // alu_b: 0 -> data; 1 -> imm
    assign alu_a = id_ex.alu_a_sel ? id_ex.pc : rf_rdata1_with_forwarding_considered;
    assign alu_b = id_ex.alu_b_sel ? id_ex.imm : rf_rdata2_with_forwarding_considered;

    cpu_alu u_alu (
        .a(alu_a),
        .b(alu_b),
        .op(id_ex.alu_op),
        .result(ex_mem_next.alu_result)
    );

    // br
    branch_comp u_branch_comp (
        .a(rf_rdata1_with_forwarding_considered),
        .b(rf_rdata2_with_forwarding_considered),
        .br_eq(br_eq)
    );

    assign branch_taken = (id_ex.pc_sel == 2'b01) && br_eq;

    // flush
    assign if_id_flush = branch_taken;
    assign id_ex_flush = branch_taken || load_use_hazard;

    // 传递
    always_comb begin
        ex_mem_next.rf_rdata2 = rf_rdata2_with_forwarding_considered;
        ex_mem_next.mem_req = id_ex.mem_req;
        ex_mem_next.mem_we = id_ex.mem_we;
        ex_mem_next.mem_sel = id_ex.mem_sel;
        // ex_mem_next.mem_load_is_unsigned = id_ex.mem_load_is_unsigned;
        ex_mem_next.rd = id_ex.rd;
        ex_mem_next.pc_plus_4 = id_ex.pc_plus_4;
        ex_mem_next.rf_w_en = id_ex.rf_w_en;
        ex_mem_next.wb_sel = id_ex.wb_sel;
    end

    // 4. MEM 阶段
    // 内部状态
    logic [31:0] mem_rdata_with_alignment_considered;

    assign mem_req = ex_mem.mem_req;
    assign mem_addr = ex_mem.alu_result;
    assign mem_wdata = (ex_mem.mem_sel == 4'b0001)
        ? (ex_mem.rf_rdata2 << (8 * ex_mem.alu_result[1:0]))
        : ex_mem.rf_rdata2; // <- 只支持 LB 和 SB 的非对齐访问
    assign mem_we = ex_mem.mem_we;
    assign mem_sel = (ex_mem.mem_sel == 4'b0001)
        ? (ex_mem.mem_sel << ex_mem.alu_result[1:0])
        : ex_mem.mem_sel; // <- 只支持 LB 和 SB 的非对齐访问

    // wb_sel: 0 -> mem_rdata (符号扩展); 1 -> alu_result; 2 -> pc + 4
    always_comb begin
        mem_rdata_with_alignment_considered = '0;
        case (ex_mem.alu_result[1:0])
            2'b00: mem_rdata_with_alignment_considered[7:0] = mem_rdata[7:0];
            2'b01: mem_rdata_with_alignment_considered[7:0] = mem_rdata[15:8];
            2'b10: mem_rdata_with_alignment_considered[7:0] = mem_rdata[23:16];
            2'b11: mem_rdata_with_alignment_considered[7:0] = mem_rdata[31:24];
            default:;
        endcase
    end

    assign mem_wb_next.wb_data = (ex_mem.wb_sel == 2'b00) ?
        {{24{mem_rdata_with_alignment_considered[7]}}, mem_rdata_with_alignment_considered[7:0]} :
        (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result : ex_mem.pc_plus_4; // <- 只处理 signed 情况

    // 传递
    always_comb begin
        mem_wb_next.rd = ex_mem.rd;
        mem_wb_next.rf_w_en = ex_mem.rf_w_en;
    end

    // 状态更新
    // nop: addi x0, x0, 0
    // verilog_lint: waive-start parameter-name-style
    localparam if_id_t IF_ID_NOP = '{inst: 32'h0000_0013, pc: '0, pc_plus_4: '0};
    // verilog_lint: waive-stop parameter-name-style
    always_ff @(posedge clk) begin
        if (rst) begin
            if_id <= IF_ID_NOP;
            id_ex <= '0;
            ex_mem <= '0;
            mem_wb <= '0;
        end else if (global_stall) begin
            if_id <= if_id;
            id_ex <= id_ex;
            ex_mem <= ex_mem;
            mem_wb <= mem_wb;
        end else begin
            if (if_id_flush) begin
                if_id <= IF_ID_NOP; // flush
            end else if (if_id_stall) begin
                if_id <= if_id; // stall
            end else begin
                if_id <= if_id_next;
            end

            if (id_ex_flush) begin
                id_ex <= '0; // flush
            end else begin
                id_ex <= id_ex_next;
            end

            ex_mem <= ex_mem_next;
            mem_wb <= mem_wb_next;
        end
    end
endmodule
