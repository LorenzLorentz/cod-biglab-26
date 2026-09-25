module controller (
    input logic clk,
    input logic rst,

    // 控制信号
    input logic step,
    input logic [31:0] dip_sw,
    output logic [15:0] leds,

    // 连接寄存器堆模块的信号
    output logic [4:0] rf_raddr_a,
    input logic [15:0] rf_data_a,
    output logic [4:0] rf_raddr_b,
    input logic [15:0] rf_data_b,
    output logic [4:0] rf_waddr,
    output logic [15:0] rf_wdata,
    output logic rf_we,

    // 连接alu模块的信号
    output logic [15:0] alu_a,
    output logic [15:0] alu_b,
    output logic [15:0] alu_op,
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
        ST_CALC = 3'b100,
        ST_DISPLAY = 3'b010
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
                if (step)
                    next_state = ST_DECODE;
                else
                    next_state = ST_INIT;
            end

            ST_DECODE: begin
                if (is_rtype) begin
                    next_state = ST_CALC;
                end else if (is_peek) begin
                    next_state = ST_DISPLAY;
                end else if (is_poke) begin
                    next_state = ST_INIT;
                end else begin
                    next_state = ST_INIT;
                end
            end

            ST_CALC: begin
                next_state = ST_DISPLAY;
            end

            ST_DISPLAY: begin
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
            is_rtype <= 1'b0;
            is_itype <= 1'b0;
            is_peek <= 1'b0;
            is_poke <= 1'b0;

            imm <= 16'b0;
            rd <= 5'b0;
            rs1 <= 5'b0;
            rs2 <= 5'b0;
            opcode <= 4'b0;
        end else begin
            rf_we <= 1'b0;

            case (state)
                ST_INIT: begin
                    if (step) begin
                        inst_reg <= dip_sw;
                    end
                end

                ST_DECODE: begin
                    if (is_poke) begin
                        rf_we <= 1'b1;
                        rf_waddr <= rd;
                        rf_wdata <= imm;
                    end else if (is_peek) begin
                        rf_raddr_a <= rd;
                    end else begin
                        rf_raddr_a <= rs1;
                        rf_raddr_b <= rs2;
                    end
                end

                ST_CALC: begin
                    alu_a <= rf_rdata_a;
                    alu_b <= rf_rdata_b;
                    alu_op <= opcode;
                end

                ST_DISPLAY: begin
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
