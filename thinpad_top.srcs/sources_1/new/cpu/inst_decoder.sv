module inst_decoder(
    input logic [31:0] inst,

    output logic [6:0] opcode,
    output logic [4:0] rs1,
    output logic [4:0] rs2,
    output logic [4:0] rd,
    output logic [2:0] imm_type, // 共5种 -> 3位
    output logic [2:0] funct3,
    output logic [6:0] funct7
);
    assign opcode = inst[6:0]; // 7位
    assign rd = inst[11:7]; // 5位
    assign rs1 = inst[19:15]; // 5位
    assign rs2 = inst[24:20]; // 5位
    assign funct3 = inst[14:12]; // 3位
    assign funct7 = inst[31:25]; // 7位

    // verilog_lint: waive-start parameter-name-style
    localparam logic [2:0] IMM_I = 3'b000; // 共5个, 3位
    localparam logic [2:0] IMM_S = 3'b001;
    localparam logic [2:0] IMM_B = 3'b010;
    localparam logic [2:0] IMM_U = 3'b011;
    localparam logic [2:0] IMM_J = 3'b100;
    localparam logic [2:0] IMM_X = 3'd0;
    // verilog_lint: waive-stop parameter-name-style
    always_comb begin
        case (opcode[6:2])
            // I-type
            5'b00100,
            5'b00000:
                imm_type = IMM_I;

            // S-type
            5'b01000:
                imm_type = IMM_S;

            // B-type:
            5'b11000:
                imm_type = IMM_B;

            // U-type:
            5'b01101,
            5'b00101:
                imm_type = IMM_U;

            default:
                imm_type = IMM_X;
        endcase
    end
endmodule
