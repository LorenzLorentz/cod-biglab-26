module imm_gen(
    input logic [31:0] inst,
    input logic [2:0] imm_type,

    output logic [31:0] imm
);
    // type:
    // 0 -> I: imm[11:0] -> [funct7, rs2]
    // 1 -> S: imm[11:5] -> funct7, imm[4:0] -> rd
    // 2 -> B: imm[12, 10:5] -> funct7, imm[4:1, 11] -> rs2
    // 3 -> U: imm[31:12] -> [funct7, rs2, rs1, funct3]
    // 4 -> J: imm[20, 10:1, 11, 19:12] -> [funct7, rs2, rs1, funct3]

    always_comb begin
        case (imm_type)
            3'b000: imm = {{20{inst[31]}}, inst[31:20]};
            3'b001: imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
            3'b010: imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
            3'b011: imm = {inst[31:12], 12'b0};
            3'b100: imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end
endmodule
