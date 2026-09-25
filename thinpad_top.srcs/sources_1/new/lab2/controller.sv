module controller (
    input logic clk,
    input logic rst,

    // 控制信号
    input logic step,
    input logic [31:0] dip_sw,
    output logic [15:0] leds,

    // 连接寄存器堆模块的信号
    output logic [4:0] rf_raddr_a,
    input logic [15:0] rf_rdata_a,
    output logic [4:0] rf_raddr_b,
    input logic [15:0] rf_rdata_b,
    output logic [4:0] rf_waddr,
    output logic [15:0] rf_wdata,
    output logic rf_we,

    // 连接alu模块的信号
    output logic [15:0] alu_a,
    output logic [15:0] alu_b,
    output logic [3:0] alu_op,
    input logic [15:0] alu_y
);
    // 内部信号: 指令
    logic [31:0] inst_reg;

    // 组合逻辑: 解析指令
    logic is_rtype, is_itype, is_peek, is_poke;
    logic [15:0] imm;
    logic [4:0] rd, rs1, rs2;
    logic [3:0] opcode;

    always_comb begin
        is_rtype = (inst_reg[2:0] == 3'b001);
        is_itype = (inst_reg[2:0] == 3'b010);
        is_peek = is_itype && (inst_reg[6:3] == 4'b0010);
        is_poke = is_itype && (inst_reg[6:3] == 4'b0001);

        imm = inst_reg[31:16];
        rd = inst_reg[11:7];
        rs1 = inst_reg[19:15];
        rs2 = inst_reg[24:20];
        opcode = inst_reg[6:3];
    end

    // 状态定义
    typedef enum logic [2:0] { // 5个状态 => 3位
        ST_INIT = 3'b000,
        ST_DECODE = 3'b001,
        ST_CALC = 3'b010,
        ST_WRITE_REG = 3'b011,
        ST_READ_REG = 3'b100
    } state_t;

    state_t state;
    state_t next_state;

    // 三段式状态机
    // stage1: 状态更新
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_INIT;
        end else begin
            state <= next_state;
        end
    end

    // stage2: 次态逻辑
    always_comb begin
        next_state = state;

        case (state)
            ST_INIT: begin
                if (step) begin
                    next_state = ST_DECODE;
                end else
                    next_state = ST_INIT;
            end

            ST_DECODE: begin
                if (is_rtype) begin
                    next_state = ST_CALC;
                end else if (is_poke) begin
                    next_state = ST_WRITE_REG;
                end else if (is_peek) begin
                    next_state = ST_READ_REG;
                end else begin
                    next_state = ST_INIT;
                end
            end

            ST_CALC: begin
                next_state = ST_WRITE_REG;
            end

            ST_WRITE_REG: begin
                if (is_poke) begin
                    next_state = ST_INIT;
                end else begin
                    next_state = ST_READ_REG;
                end
            end

            ST_READ_REG: begin
                next_state = ST_INIT;
            end

            default: begin
                next_state = ST_INIT;
            end
        endcase
    end

    // stage3: 输出逻辑
    always_ff @(posedge clk) begin
        if (rst) begin
            // 内部状态
            inst_reg <= 32'b0;

            // 输出
            // 控制
            leds <= 16'b0;
            rf_we <= 1'b0;

            // rf模块
            rf_raddr_a <= 5'b0;
            rf_raddr_b <= 5'b0;
            rf_waddr <= 5'b0;
            rf_wdata <= 16'b0;
            rf_we <= 1'b0;

            // alu模块
            alu_a <= 16'b0;
            alu_b <= 16'b0;
            alu_op <= 4'b0;
        end else begin
            rf_we <= 1'b0;

            case (state)
                ST_INIT: begin
                    if (step) begin
                        inst_reg <= dip_sw;
                    end
                end

                ST_DECODE: begin
                    if (is_peek) begin
                        rf_raddr_a <= rd;
                    end else if (is_rtype) begin
                        rf_raddr_a <= rs1;
                        rf_raddr_b <= rs2;
                    end
                end

                ST_CALC: begin
                    alu_a <= rf_rdata_a;
                    alu_b <= rf_rdata_b;
                    alu_op <= opcode;
                end

                ST_WRITE_REG: begin
                    rf_we <= 1'b1;
                    if (is_poke) begin
                        rf_waddr <= rd;
                        rf_wdata <= imm;
                    end else begin
                        rf_waddr <= rd;
                        rf_wdata <= alu_y;
                    end
                end

                ST_READ_REG: begin
                    if (is_peek) begin
                        leds <= rf_rdata_a;
                    end else begin
                        leds <= alu_y;
                    end
                end

                default: ;
            endcase
        end
    end
endmodule
