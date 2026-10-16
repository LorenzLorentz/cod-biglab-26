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
    logic mem_rw; // mem 读写使能, 0 读 1 写
    logic mem_width; // mem 读写位宽, 0 表示 byte, 1 表示 word
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
    logic [15:0] alu_op;
    logic [31:0] alu_result;
    logic br_eq;

    // 4. MEM 阶段
    logic [31:0] rf_wdata; // 最终准备写回 RegFile 的数据

    // 执行

    // 总线
    // 状态定义
    typedef enum logic [1:0] {
        ST_FETCH,
        ST_EXEC,
        ST_MEM
    } state_t;

    state_t state_reg;
    state_t next_state;

    // 锁存
    logic [31:0] pc_reg;
    logic [31:0] inst_data_reg;
    logic [31:0] mem_addr_reg;
    logic [31:0] mem_wdata_reg;
    logic mem_we_reg;
    logic [3:0] mem_sel_reg;

    // 待锁存数据
    logic [31:0] mem_wdata_value;
    logic [3:0] mem_sel_value;

    // 三段式状态机
    // 1. 次态逻辑
    always_comb begin
        next_state = state_reg;

        case (state_reg)
            ST_FETCH: begin
                if (inst_ready) begin
                    next_state = ST_EXEC;
                end
            end
            ST_EXEC: begin
                next_state = is_mem_access ? ST_MEM : ST_FETCH;
            end
            ST_MEM: begin
                if (mem_ready) begin
                    next_state = ST_FETCH;
                end
            end
            default: begin
                next_state = ST_FETCH;
            end
        endcase
    end

    // 2. 时序逻辑
    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= ST_FETCH;
            pc_reg <= 32'h0;
            inst_data_reg <= 32'h0000_0013; // nop: addi x0, x0, 0
            mem_addr_reg <= 32'h0;
            mem_wdata_reg <= 32'h0;
            mem_we_reg <= 1'b0;
            mem_sel_reg <= 4'b0000;
        end else begin
            state_reg <= next_state;

            case (state_reg)
                ST_FETCH: begin
                    if (inst_ready) begin
                        inst_data_reg <= inst_data;
                    end
                end

                ST_EXEC: begin
                    if (is_mem_access) begin
                        mem_addr_reg <= alu_result;
                        mem_wdata_reg <= mem_wdata_value;
                        mem_we_reg <= is_store;
                        mem_sel_reg <= mem_sel_value;
                    end else begin
                        pc_reg <= next_pc;
                    end
                end

                ST_MEM: begin
                    if (mem_ready) begin
                        pc_reg <= next_pc;
                    end
                end

                default: begin
                end
            endcase
        end
    end

    // 3. 输出逻辑
    always_comb begin
        inst_req = 1'b0;
        mem_req = 1'b0;
        rf_commit_en = 1'b0;

        case (funct3[1:0])
            2'b00: begin // byte
                mem_sel_value = 4'b0001 << alu_result[1:0];
                mem_wdata_value = rf_rdata2 << {alu_result[1:0], 3'b000};
            end
            2'b01: begin // word
                mem_sel_value = alu_result[1] ? 4'b1100 : 4'b0011;
                mem_wdata_value = alu_result[1] ? (rf_rdata2 << 16) : rf_rdata2;
            end
            default: begin // full
                mem_sel_value = 4'b1111;
                mem_wdata_value = rf_rdata2;
            end
        endcase

        case (state_reg)
            ST_FETCH: begin
                inst_req = 1'b1;
            end
            ST_EXEC: begin
                rf_commit_en = rf_w_en && !is_mem_access;
            end
            ST_MEM: begin
                mem_req = 1'b1;
                rf_commit_en = rf_w_en && is_load && mem_ready;
            end
            default: begin
            end
        endcase
    end

    // 4. 状态绑定
    assign pc = pc_reg;
    assign inst = inst_data_reg;
    assign pc_plus_4 = pc + 4;

    assign inst_addr = pc;
    assign mem_addr = mem_addr_reg;
    assign mem_wdata = mem_wdata_reg;
    assign mem_we = mem_we_reg;
    assign mem_sel = mem_sel_reg;

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
        .mem_rw(mem_rw),
        .mem_width(mem_width),
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
    assign alu_a = alu_a_sel ? pc : rf_rdata1;
    assign alu_b = alu_b_sel ? imm : rf_rdata2;

    alu u_alu (
        .a(alu_a),
        .b(alu_b),
        .op(alu_op),
        .y(alu_result)
    );

    // br
    branch_comp u_branch_comp (
        .a(rf_rdata1),
        .b(rf_rdata2),
        .breq(br_eq)
    );

    // wb
    assign rf_wdata = (wb_sel == 2'b00) ? mem_rdata :
        (wb_sel == 2'b01) ? alu_result : pc_plus_4;

    // next pc
    assign next_pc = (pc_sel == 2'b00 || !br_eq) ? pc_plus_4 :
        (pc_sel == 2'b01) ? alu_result : mem_rdata;
endmodule
