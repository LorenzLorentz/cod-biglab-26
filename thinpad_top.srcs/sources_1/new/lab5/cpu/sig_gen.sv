module sig_gen(
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,

    output logic rf_w_en, // reg file 写使能
    output logic mem_req, // mem 请求使能
    output logic mem_we, // mem 写使能
    output logic [3:0] mem_sel, // mem 读写位宽, 0 表示 byte, 1 表示 word
    output logic alu_a_sel, // alu_a 选择
    output logic alu_b_sel, // alu_b 选择
    output logic [1:0] alu_op, // alu_op 选择
    output logic [1:0] pc_sel, // pc 信号选择
    output logic [1:0] wb_sel // 写回选择
);
    // 只用看 opcode 和 funct3
    always_comb begin
        // 默认情况
        mem_req = 0; // 默认不请求, 不写入
        mem_we = 0;
        mem_sel = 4'b0000;
        alu_a = 0;
        alu_b = 0;
        alu_op = 0;
        pc_sel = 0; // 默认走pc+4
        rf_w_en = 0; // 默认不写入
        wb_sel = 0;

        case (opcode[6:2])
            // R-type
            5'b01100: begin // ADD
                alu_a_sel = 1; // reg_rdata1
                alu_b_sel = 1; // reg_rdata2
                alu_op = 0; // ADD
                rf_w_en = 1;
                wb_sel = 1; // alu result
            end

            // I-type
            5'b00100: begin // ADDI / ANDI
                alu_a_sel = 1; // reg_rdata1
                alu_b_sel = 0; // imm
                case (funct3)
                    3'b000:
                        alu_op = 0; // ADD
                    3'b111:
                        alu_op = 1; // AND
                    default:;
                endcase
                rf_w_en = 1;
                wb_sel = 1; // alu result
            end

            5'b00000: begin// LB
                alu_a_sel = 1; // reg_rdata1
                alu_b_sel = 0; // imm
                alu_op = 0; // ADD
                mem_req = 1;
                mem_we = 0;
                mem_sel = 4'b0001; // 一个字节
                rf_w_en = 1;
                wb_sel = 0; // mem_rdata
            end

            // S-type
            5'b01000: begin// SB, SW
                alu_a_sel = 1; // reg_rdata1
                alu_b_sel = 0; // imm
                alu_op = 0; // ADD
                mem_req = 1;
                case (funct3)
                    3'b000:
                        mem_sel = 4'b0001; // 1 byte
                    3'b010:
                        mem_sel = 4'b1111; // 1 word
                    default:;
                endcase
            end

            // B-type:
            5'b11000: begin// BEQ
                alu_a_sel = 0; // pc
                alu_b_sel = 0; // imm
                alu_op = 0; // ADD
                pc_sel = 1; // alu result
            end

            // U-type:
            5'b01101: begin // LUI
                alu_b_sel = 0; // imm
                alu_op = 2; // pass b
                rf_w_en = 1;
                wb_sel = 1; // alu result
            end

            default:;
        endcase
    end
endmodule
