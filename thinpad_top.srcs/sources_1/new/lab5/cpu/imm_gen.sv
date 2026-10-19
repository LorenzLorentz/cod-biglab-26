module imm_gen(
    input logic [31:0] inst,
    input logic [2:0] imm_type,

    output logic [31:0] imm
);
    // type:
    // 前三个一类
    // 0 -> I: imm[11:0] -> [funct7, rs2]
    // 1 -> S: imm[11:5] -> funct7, imm[4:0] -> rd
    // 2 -> B: imm[12, 10:5] -> funct7, imm[4:1, 11] -> rs2
    // 后两个一类
    // 3 -> U: imm[20, 10:1, 11, 19:12] -> [funct7, rs2, rs1, funct3]
    // 4 -> J: imm[31:12] -> [funct7, rs2, rs1, funct3]

    always_comb begin
        case (imm_type[2])
            1'b0: begin
                imm[10:5] = inst[30:24];
                case (imm_type[1:0])
                    2'b00: begin
                        imm[11] = inst[31];
                        imm[4:0] = inst[23:19];
                    end

                    2'b01: begin
                        imm[11] = inst[31];
                        imm[4:0] = inst[11:7];
                    end

                    2'b10: begin
                        imm[12] = inst[31];
                        imm[11] = inst[7];
                        imm[4:1] = inst[11:8];
                        imm[0] = 0;
                    end

                    default:;
                endcase
            end

            1'b1: begin
                imm[19:12] = inst[19:12];

                case (imm_type[1])
                    1'b0: begin
                        imm[20] = inst[31];
                        imm[10:1] = inst[30:21];
                        imm[11] = inst[20];
                        imm[0] = 0;
                    end

                    1'b1: begin
                        imm[31:20] = inst[31:20];
                    end

                    default:;
                endcase
            end

            default:;
        endcase
    end
endmodule
