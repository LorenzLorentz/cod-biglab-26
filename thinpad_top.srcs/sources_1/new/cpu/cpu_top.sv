module cpu_top (
    input logic clk,
    input logic rst,

    // 指令总线
    output logic inst_req,
    output logic [31:0] inst_addr,
    input [31:0] inst_data,
    input inst_ready,
    input inst_page_fault,
    input inst_access_fault,

    // 数据总线
    output logic mem_req,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    input [31:0] mem_rdata,
    output logic mem_we,
    output logic [3:0] mem_sel,
    input mem_ready,
    input mem_page_fault,
    input mem_access_fault,

    output logic [31:0] satp,
    output logic [1:0] inst_priv,
    output logic [1:0] mem_priv,
    output logic mstatus_sum,
    output logic mstatus_mxr,

    input logic timer_irq
);
    // 流水线寄存器
    // IF -> ID
    typedef struct packed {
        // ID 需要
        logic [31:0] inst;
        logic valid;

        // 后续需要
        logic [31:0] pc; // EX 需要
        logic [31:0] pc_plus_4; // WB 需要
        logic fetch_exc_valid;
        logic [4:0] fetch_exc_cause;

        // 分支预测
        logic pred_taken;
        logic [31:0] pred_target;
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
        logic [2:0] br_type; // 条件分支类型, 0 表示不是条件分支
        logic is_jalr; // JALR 的目标地址要清最低位
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

        logic [31:0] inst;
        logic [1:0] csr_op; // CSR 操作
        logic csr_use_imm; // 写输入选择
        logic csr_w_en; // CSR 写使能
        logic is_mret;
        logic is_sfence_vma;
        logic exc_valid;
        logic [4:0] exc_cause;

        // 分支预测
        logic pred_taken;
        logic [31:0] pred_target;
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

        logic [31:0] pc;
        logic [31:0] inst;
        logic [1:0] csr_op;
        logic csr_w_en;
        logic [31:0] csr_wsrc; // CSR 写入源数据
        logic is_mret;
        logic is_sfence_vma;
        logic exc_valid;
        logic [4:0] exc_cause;
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

    typedef enum logic [1:0] {
        PRIV_U = 2'b00,
        PRIV_M = 2'b11
    } priv_mode_t;

    typedef enum logic [4:0] {
        EXC_INST_MISALIGN = 5'd0,
        EXC_INST_ACCESS = 5'd1,
        EXC_ILLEGAL_INST = 5'd2,
        EXC_BREAKPOINT = 5'd3,
        EXC_LOAD_MISALIGN = 5'd4,
        EXC_LOAD_ACCESS = 5'd5,
        EXC_STORE_MISALIGN = 5'd6,
        EXC_STORE_ACCESS = 5'd7,
        EXC_ECALL_U = 5'd8,
        EXC_ECALL_M = 5'd11,
        EXC_INST_PAGE = 5'd12,
        EXC_LOAD_PAGE = 5'd13,
        EXC_STORE_PAGE = 5'd15
    } exc_cause_t;

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
    logic ex_mem_flush;

    logic [1:0] priv_mode;
    logic irq_valid;
    logic [3:0] irq_cause;
    logic mem_redirect_taken;
    logic [31:0] mem_redirect_target;

    assign inst_priv = priv_mode;

    // 执行
    // 1. IF阶段
    // 内部状态
    logic [31:0] pc;
    logic [31:0] pc_plus_4;
    logic [31:0] pc_next;

    // 分支预测
    logic if_pred_taken;
    logic [31:0] if_pred_target;
    logic redirect_mispredict;
    logic [31:0] redirect_actual_target;
    logic bpu_update_valid;

    assign pc_plus_4 = pc + 4;
    // 优先级: MEM 重定向 > 预测错误重定向 > 预测的下一条 PC > pc + 4
    assign pc_next = mem_redirect_taken ? mem_redirect_target
        : redirect_mispredict ? redirect_actual_target
        : if_pred_taken ? if_pred_target : pc_plus_4;

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
        if_id_next.valid = 1'b1;
        if_id_next.pc = pc;
        if_id_next.pc_plus_4 = pc_plus_4;
        if_id_next.fetch_exc_valid = inst_page_fault || inst_access_fault;
        if_id_next.fetch_exc_cause = inst_access_fault
            ? EXC_INST_ACCESS : EXC_INST_PAGE;
        if_id_next.pred_taken = if_pred_taken;
        if_id_next.pred_target = if_pred_target;
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
    logic is_ecall;
    logic is_ebreak;
    logic is_mret;
    logic is_sfence_vma;
    logic illegal;
    logic id_exc_valid;
    logic [4:0] id_exc_cause;

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
        .rs1(rs1),
        .rd(if_id.inst[11:7]),
        .rf_w_en(id_ex_next.rf_w_en),
        .mem_req(id_ex_next.mem_req),
        .mem_we(id_ex_next.mem_we),
        .mem_sel(id_ex_next.mem_sel),
        // .mem_load_is_unsigned(id_ex_next.mem_load_is_unsigned),
        .alu_a_sel(id_ex_next.alu_a_sel),
        .alu_b_sel(id_ex_next.alu_b_sel),
        .alu_op(id_ex_next.alu_op),
        .pc_sel(id_ex_next.pc_sel),
        .br_type(id_ex_next.br_type),
        .is_jalr(id_ex_next.is_jalr),
        .wb_sel(id_ex_next.wb_sel),
        .use_rs1(use_rs1),
        .use_rs2(use_rs2),
        .csr_op(id_ex_next.csr_op),
        .csr_use_imm(id_ex_next.csr_use_imm),
        .csr_w_en(id_ex_next.csr_w_en),
        .is_ecall(is_ecall),
        .is_ebreak(is_ebreak),
        .is_mret(is_mret),
        .is_sfence_vma(is_sfence_vma),
        .illegal(illegal)
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
    assign pc_stall = load_use_hazard && !mem_redirect_taken;
    assign if_id_stall = pc_stall;

    // 异常处理
    always_comb begin
        id_exc_valid = 1'b0;
        id_exc_cause = 5'd0;

        if (if_id.valid && if_id.fetch_exc_valid) begin
            id_exc_valid = 1'b1;
            id_exc_cause = if_id.fetch_exc_cause;
        end else if (if_id.valid && irq_valid) begin
            id_exc_valid = 1'b1;
            id_exc_cause = {1'b1, irq_cause};
        end else if (if_id.valid
            && (illegal || ((is_mret || is_sfence_vma) && (priv_mode != PRIV_M)))) begin
            id_exc_valid = 1'b1;
            id_exc_cause = EXC_ILLEGAL_INST;
        end else if (if_id.valid && is_ebreak) begin
            id_exc_valid = 1'b1;
            id_exc_cause = EXC_BREAKPOINT;
        end else if (if_id.valid && is_ecall) begin
            id_exc_valid = 1'b1;
            id_exc_cause = (priv_mode == PRIV_M) ? EXC_ECALL_M : EXC_ECALL_U;
        end
    end

    // 传递
    always_comb begin
        id_ex_next.rs1 = rs1;
        id_ex_next.rs2 = rs2;
        id_ex_next.use_rs1 = use_rs1;
        id_ex_next.use_rs2 = use_rs2;
        id_ex_next.pc = if_id.pc;
        id_ex_next.pc_plus_4 = if_id.pc_plus_4;
        id_ex_next.inst = if_id.inst;
        id_ex_next.is_mret = is_mret;
        id_ex_next.is_sfence_vma = is_sfence_vma;
        id_ex_next.exc_valid = id_exc_valid;
        id_ex_next.exc_cause = id_exc_cause;
        id_ex_next.pred_taken = if_id.pred_taken;
        id_ex_next.pred_target = if_id.pred_target;
    end

    // 3. EX 阶段
    // 内部状态
    // alu
    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic [31:0] rf_rdata1_with_forwarding_considered;
    logic [31:0] rf_rdata2_with_forwarding_considered;

    // br
    logic br_eq;
    logic br_lt;
    logic br_ltu;
    logic branch_cond;
    logic redirect_cond;
    logic redirect_taken;
    logic [31:0] redirect_target;

    // 异常
    logic ex_exc_valid;
    logic [4:0] ex_exc_cause;
    logic jump_misalign;
    logic mem_misalign;

    // alu
    // forwarding
    always_comb begin
        rf_rdata1_with_forwarding_considered = id_ex.rf_rdata1;
        rf_rdata2_with_forwarding_considered = id_ex.rf_rdata2;

        if (id_ex.use_rs1 && ex_mem.rf_w_en
            && (ex_mem.rd != 5'b0) && (ex_mem.rd == id_ex.rs1)) begin // 要写回但还没有
            case (ex_mem.wb_sel)
                2'b01: rf_rdata1_with_forwarding_considered = ex_mem.alu_result;
                2'b10: rf_rdata1_with_forwarding_considered = ex_mem.pc_plus_4;
                default:; // load: MEM 级才拿到数据, 紧跟的指令已被 load-use 暂停
            endcase
        end else if (id_ex.use_rs1 && mem_wb.rf_w_en
            && (mem_wb.rd != 5'b0) && (mem_wb.rd == id_ex.rs1)) begin
            rf_rdata1_with_forwarding_considered = mem_wb.wb_data;
        end

        if (id_ex.use_rs2 && ex_mem.rf_w_en
            && (ex_mem.rd != 5'b0) && (ex_mem.rd == id_ex.rs2)) begin
            case (ex_mem.wb_sel)
                2'b01: rf_rdata2_with_forwarding_considered = ex_mem.alu_result;
                2'b10: rf_rdata2_with_forwarding_considered = ex_mem.pc_plus_4;
                default:; // load: MEM 级才拿到数据, 紧跟的指令已被 load-use 暂停
            endcase
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
        .br_eq(br_eq),
        .br_lt(br_lt),
        .br_ltu(br_ltu)
    );

    // br_type: 0 -> 不是条件分支; branch_cond: 1 -> 条件分支跳转
    always_comb begin
        case (id_ex.br_type)
            3'd0: branch_cond = 1'b0;
            3'd1: branch_cond = br_eq; // BEQ
            3'd2: branch_cond = !br_eq; // BNE
            3'd3: branch_cond = br_lt; // BLT
            3'd4: branch_cond = !br_lt; // BGE
            3'd5: branch_cond = br_ltu; // BLTU
            3'd6: branch_cond = !br_ltu; // BGEU
            default: branch_cond = 1'b0;
        endcase
    end

    // 跳转
    assign redirect_cond = (id_ex.pc_sel == 2'b01) && ((id_ex.br_type == 3'd0) || branch_cond);
    assign redirect_target = id_ex.is_jalr
        ? {ex_mem_next.alu_result[31:1], 1'b0}
        : ex_mem_next.alu_result;
    assign redirect_taken = redirect_cond && !id_ex.exc_valid && !jump_misalign;

    // 异常处理
    assign jump_misalign = redirect_cond && redirect_target[1];
    assign mem_misalign = id_ex.mem_req && (id_ex.mem_sel == 4'b1111)
        && (ex_mem_next.alu_result[1:0] != 2'b00);
    always_comb begin
        ex_exc_valid = id_ex.exc_valid;
        ex_exc_cause = id_ex.exc_cause;

        if (!id_ex.exc_valid && jump_misalign) begin
            ex_exc_valid = 1'b1;
            ex_exc_cause = EXC_INST_MISALIGN;
        end else if (!id_ex.exc_valid && mem_misalign) begin
            ex_exc_valid = 1'b1;
            ex_exc_cause = id_ex.mem_we ? EXC_STORE_MISALIGN : EXC_LOAD_MISALIGN;
        end
    end

    // 实际分支预测结果
    assign redirect_actual_target = redirect_taken ? redirect_target : id_ex.pc_plus_4;
    assign redirect_mispredict = (id_ex.pred_taken != redirect_taken) // 不需要跳转
        || (redirect_taken && (id_ex.pred_target != redirect_target)); // 跳转错位置
    assign bpu_update_valid = (id_ex.pc_sel == 2'b01)
        && !id_ex.exc_valid
        && !mem_redirect_taken
        && !jump_misalign
        && !global_stall; // 避免同一条指令被重复训练

    // flush; 预测正确时不冲刷
    assign if_id_flush = redirect_mispredict || mem_redirect_taken;
    assign id_ex_flush = redirect_mispredict || load_use_hazard || mem_redirect_taken;
    assign ex_mem_flush = mem_redirect_taken;

    // 分支预测器
    branch_predictor u_branch_predictor (
        .clk(clk),
        .rst(rst),
        .fetch_pc(pc),
        .pred_taken(if_pred_taken),
        .pred_target(if_pred_target),
        .update_valid(bpu_update_valid),
        .update_pc(id_ex.pc),
        .update_taken(redirect_taken),
        .update_target(redirect_target)
    );

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
        ex_mem_next.pc = id_ex.pc;
        ex_mem_next.inst = id_ex.inst;
        ex_mem_next.csr_op = id_ex.csr_op;
        ex_mem_next.csr_w_en = id_ex.csr_w_en;
        ex_mem_next.csr_wsrc = id_ex.csr_use_imm
            ? {27'b0, id_ex.rs1}
            : rf_rdata1_with_forwarding_considered;
        ex_mem_next.is_mret = id_ex.is_mret;
        ex_mem_next.is_sfence_vma = id_ex.is_sfence_vma;
        ex_mem_next.exc_valid = ex_exc_valid;
        ex_mem_next.exc_cause = ex_exc_cause;
    end

    // 4. MEM 阶段
    // 内部状态
    logic [31:0] mem_rdata_with_alignment_considered;

    // 异常处理
    logic [31:0] csr_rdata;
    logic csr_illegal;
    logic csr_taken;
    logic mem_exc_valid;
    logic [4:0] mem_exc_cause;
    logic [31:0] mem_exc_tval;
    logic trap_taken;
    logic [31:0] trap_target;
    logic mret_taken;
    logic sfence_taken;
    logic [31:0] mret_target;

    assign mem_req = ex_mem.mem_req && !ex_mem.exc_valid;
    // LW/SW 必须 4 字节对齐: 低 2 位不参与寻址
    assign mem_addr = (ex_mem.mem_sel == 4'b1111)
        ? {ex_mem.alu_result[31:2], 2'b00}
        : ex_mem.alu_result; // <- 只支持 LB 和 SB 的非对齐访问
    assign mem_wdata = (ex_mem.mem_sel == 4'b0001)
        ? (ex_mem.rf_rdata2 << (8 * ex_mem.alu_result[1:0]))
        : ex_mem.rf_rdata2; // <- 只支持 LB 和 SB 的非对齐访问
    assign mem_we = ex_mem.mem_we;
    assign mem_sel = (ex_mem.mem_sel == 4'b0001)
        ? (ex_mem.mem_sel << ex_mem.alu_result[1:0])
        : ex_mem.mem_sel; // <- 只支持 LB 和 SB 的非对齐访问

    // wb_sel: 0 -> mem_rdata (LB 符号扩展 / LW 整字); 1 -> alu_result; 2 -> pc + 4; 3 -> csr_rdata
    // LB 情形, 处理对齐
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
        ((ex_mem.mem_sel == 4'b1111) ? mem_rdata : // 1. 4 Bytes; 2. 1 Byte
        {{24{mem_rdata_with_alignment_considered[7]}}, mem_rdata_with_alignment_considered[7:0]}) :
        (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result :
        (ex_mem.wb_sel == 2'b10) ? ex_mem.pc_plus_4 : csr_rdata;

    // 异常处理
    always_comb begin
        mem_exc_valid = ex_mem.exc_valid;
        mem_exc_cause = ex_mem.exc_cause;

        if (!ex_mem.exc_valid && (ex_mem.csr_op != 2'b00) && csr_illegal) begin
            mem_exc_valid = 1'b1;
            mem_exc_cause = EXC_ILLEGAL_INST;
        end else if (!ex_mem.exc_valid && ex_mem.mem_req && mem_page_fault) begin
            mem_exc_valid = 1'b1;
            mem_exc_cause = ex_mem.mem_we ? EXC_STORE_PAGE : EXC_LOAD_PAGE;
        end else if (!ex_mem.exc_valid && ex_mem.mem_req && mem_access_fault) begin
            mem_exc_valid = 1'b1;
            mem_exc_cause = ex_mem.mem_we ? EXC_STORE_ACCESS : EXC_LOAD_ACCESS;
        end
    end

    // 异常附加值
    always_comb begin
        case (mem_exc_cause)
            EXC_INST_MISALIGN: mem_exc_tval = {ex_mem.alu_result[31:1], 1'b0};
            EXC_INST_ACCESS,
            EXC_INST_PAGE: mem_exc_tval = ex_mem.pc;
            EXC_ILLEGAL_INST: mem_exc_tval = ex_mem.inst;
            EXC_BREAKPOINT: mem_exc_tval = ex_mem.pc;
            EXC_LOAD_MISALIGN,
            EXC_STORE_MISALIGN,
            EXC_LOAD_ACCESS,
            EXC_STORE_ACCESS,
            EXC_LOAD_PAGE,
            EXC_STORE_PAGE: mem_exc_tval = ex_mem.alu_result;
            default: mem_exc_tval = 32'b0;
        endcase
    end

    assign trap_taken = mem_exc_valid;
    assign mret_taken = ex_mem.is_mret && !mem_exc_valid;
    assign sfence_taken = ex_mem.is_sfence_vma && !mem_exc_valid;
    assign csr_taken = (ex_mem.csr_op != 2'b00) && !mem_exc_valid;

    // 异常相关强行跳转
    assign mem_redirect_taken = trap_taken || mret_taken || sfence_taken || csr_taken;
    assign mem_redirect_target = trap_taken ? trap_target
        : mret_taken ? mret_target : ex_mem.pc_plus_4;

    cpu_csr u_csr (
        .clk(clk),
        .rst(rst),
        .csr_addr(ex_mem.inst[31:20]),
        .csr_op(ex_mem.csr_op),
        .csr_wsrc(ex_mem.csr_wsrc),
        .csr_w_en(ex_mem.csr_w_en),
        .csr_commit(csr_taken && !global_stall),
        .csr_rdata(csr_rdata),
        .csr_illegal(csr_illegal),
        .trap_commit(trap_taken && !global_stall),
        .trap_pc(ex_mem.pc),
        .trap_cause(mem_exc_cause),
        .trap_tval(mem_exc_tval),
        .trap_target(trap_target),
        .mret_commit(mret_taken && !global_stall),
        .mret_target(mret_target),
        .timer_irq(timer_irq),
        .irq_valid(irq_valid),
        .irq_cause(irq_cause),
        .priv_mode(priv_mode),
        .mem_priv(mem_priv),
        .mstatus_sum(mstatus_sum),
        .mstatus_mxr(mstatus_mxr),
        .satp(satp)
    );

    // 传递
    always_comb begin
        mem_wb_next.rd = ex_mem.rd;
        mem_wb_next.rf_w_en = ex_mem.rf_w_en && !trap_taken;
    end

    // 状态更新
    // nop: addi x0, x0, 0
    // verilog_lint: waive-start parameter-name-style
    localparam if_id_t IF_ID_NOP = '{
        inst: 32'h0000_0013, valid: 1'b0, pc: '0, pc_plus_4: '0,
        fetch_exc_valid: 1'b0, fetch_exc_cause: '0,
        pred_taken: 1'b0, pred_target: '0
    };
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

            if (ex_mem_flush) begin
                ex_mem <= '0;
            end else begin
                ex_mem <= ex_mem_next;
            end

            mem_wb <= mem_wb_next;
        end
    end
endmodule
