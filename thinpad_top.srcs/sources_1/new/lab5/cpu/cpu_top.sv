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
        logic [1:0] alu_op;
        // bc op
        logic [1:0] bc_op; // 暂时不需要
        // pc_sel
        logic [1:0] pc_sel;

        // 后续需要
        logic mem_req; // MEM 需要
        logic mem_we; // MEM 需要
        logic [3:0] mem_sel; // MEM 需要
        logic mem_load_is_unsigned;// MEM 需要
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
        logic mem_load_is_unsigned;

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
    logic id_ex_stall;
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
    assign pc_next = pc_plus_4;

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
        if_id_next.valid = 1'b1;
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
        .rf_w_en(id_ex_next.rf_w_en),
        .mem_req(id_ex_next.mem_req),
        .mem_we(id_ex_next.mem_we),
        .mem_sel(id_ex_next.mem_sel),
        .mem_load_is_unsigned(id_ex_next.mem_load_is_unsigned),
        .alu_a_sel(id_ex_next.alu_a_sel),
        .alu_b_sel(id_ex_next.alu_b_sel),
        .alu_op(id_ex_next.alu_op),
        .pc_sel(id_ex_next.pc_sel),
        .wb_sel(id_ex_next.wb_sel)
    );

    // imm gen
    imm_gen u_imm_gen (
        .inst(if_id.inst),
        .imm_type(imm_type),
        .imm(id_ex_next.imm)
    );

    // rf & 5. WB 阶段
    reg_file u_reg_file (
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
    assign load_use_hazard = (id_ex.wb_sel == 2'b00 && id_ex.mem_req)
        && ((id_ex.rd == rs1) || (id_ex.rd == rs2));
    assign pc_stall = load_use_hazard;
    assign if_id_stall = pc_stall;
    assign id_ex_flush = pc_stall;

    // 传递
    always_comb begin
        id_ex_next.valid = if_id.valid;
        id_ex_next.rs1 = rs1;
        id_ex_next.rs2 = rs2;
        id_ex_next.pc = if_id.pc;
        id_ex_next.pc_plus_4 = if_id.pc_plus_4;
    end

    // 3. EX 阶段
    // 内部状态
    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic br_eq;
    logic [31:0] data1_with_forwarding_considered;
    logic [31:0] data2_with_forwarding_considered;

    // alu
    // forwarding
    always_comb begin
        data1_with_forwarding_considered = id_ex.rf_rdata1;
        data2_with_forwarding_considered = id_ex.rf_rdata2;

        if (ex_mem.rf_w_en && (ex_mem.rd == id_ex.rs1)) begin // 要写回但还没有
            data1_with_forwarding_considered = (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result
                : ex_mem.pc_plus_4;
        end else if (mem_wb.rf_w_en && (mem_wb.rd == id_ex.rs1)) begin
            data1_with_forwarding_considered = mem_wb.wb_data;
        end

        if (ex_mem.rf_w_en && (ex_mem.rd == id_ex.rs2)) begin
            data2_with_forwarding_considered = (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result
                : ex_mem.pc_plus_4;
        end else if (mem_wb.rf_w_en && (mem_wb.rd == id_ex.rs2)) begin
            data2_with_forwarding_considered = mem_wb.wb_data;
        end
    end

    // alu_a: 0 -> data; 1 -> pc
    // alu_b: 0 -> data; 1 -> imm
    assign alu_a = id_ex.alu_a_sel ? id_ex.pc : data1_with_forwarding_considered;
    assign alu_b = id_ex.alu_b_sel ? id_ex.imm : data2_with_forwarding_considered;

    alu u_alu (
        .a(alu_a),
        .b(alu_b),
        .op(id_ex.alu_op),
        .result(ex_mem_next.alu_result)
    );

    // br
    branch_comp u_branch_comp (
        .a(id_ex.rf_rdata1),
        .b(id_ex.rf_rdata2),
        .br_eq(br_eq)
    );

    // flush
    assign if_id_flush = br_eq;
    assign id_ex_flush = br_eq;

    // 传递
    always_comb begin
        ex_mem_next.valid = id_ex.valid;
        ex_mem_next.rf_rdata2 = id_ex.rf_rdata2;
        ex_mem_next.mem_req = id_ex.mem_req;
        ex_mem_next.mem_we = id_ex.mem_we;
        ex_mem_next.mem_sel = id_ex.mem_sel;
        ex_mem_next.mem_load_is_unsigned = id_ex.mem_load_is_unsigned;
        ex_mem_next.rd = id_ex.rd;
        ex_mem_next.pc_plus_4 = id_ex.pc_plus_4;
        ex_mem_next.rf_w_en = id_ex.rf_w_en;
        ex_mem_next.wb_sel = id_ex.wb_sel;
    end

    // 4. MEM 阶段
    assign mem_req = ex_mem.mem_req;
    assign mem_addr = ex_mem.alu_result;
    assign mem_wdata = ex_mem.rf_rdata2;
    assign mem_we = ex_mem.mem_we;
    assign mem_sel = ex_mem.mem_sel;

    // wb_sel: 0 -> mem_rdata (符号扩展); 1 -> alu_result; 2 -> pc + 4
    assign mem_wb_next.wb_data = (ex_mem.wb_sel == 2'b00) ? {{24{mem_rdata[7]}}, mem_rdata[7:0]} :
        (ex_mem.wb_sel == 2'b01) ? ex_mem.alu_result : ex_mem.pc_plus_4;

    // 传递
    always_comb begin
        mem_wb_next.valid = ex_mem.valid;
        mem_wb_next.rd = ex_mem.rd;
        mem_wb_next.rf_w_en = ex_mem.rf_w_en;
    end

    // 状态更新
    always_ff @(posedge clk) begin
        if (rst) begin
            if_id <= '0;
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
                if_id <= '0; // flush
            end else if (if_id_stall) begin
                if_id <= if_id; // stall
            end else begin
                if_id <= if_id_next;
            end

            if (id_ex_flush) begin
                id_ex <= '0; // flush
            end else if (id_ex_stall) begin
                id_ex <= id_ex; // stall
            end else begin
                id_ex <= id_ex_next;
            end

            ex_mem <= ex_mem_next;
            mem_wb <= mem_wb_next;
        end
    end
endmodule
