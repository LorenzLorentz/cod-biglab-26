module sig_gen(
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,
    input [4:0] funct5, // 即 rs2
    input [4:0] rs1,
    input [4:0] rd,

    output logic rf_w_en, // reg file 写使能
    output logic mem_req, // mem 请求使能
    output logic mem_we, // mem 写使能
    output logic [3:0] mem_sel, // mem 读写位宽, 0 表示 byte, 1 表示 word
    // output logic mem_load_is_unsigned, // mem load 的时候是否是signed
    output logic alu_a_sel, // alu_a 选择
    output logic alu_b_sel, // alu_b 选择
    output logic [3:0] alu_op, // alu_op 选择
    output logic [1:0] pc_sel, // pc 信号选择
    output logic [2:0] br_type, // 条件分支类型: 0 表示不是条件分支, 1..6 = BEQ..BGEU
    output logic is_jalr, // JALR 的目标地址要清最低位
    output logic [1:0] wb_sel, // 写回选择
    output logic use_rs1, // 是否真的读 rs1
    output logic use_rs2, // 是否真的读 rs2
    output logic [1:0] csr_op,
    output logic csr_use_imm,
    output logic csr_w_en,
    output logic is_ecall,
    output logic is_ebreak,
    output logic is_mret,
    output logic is_sfence_vma,
    output logic is_fence_i,
    output logic illegal
);
    always_comb begin
        // 默认情况
        mem_req = 0; // 默认不请求, 不写入
        mem_we = 0;
        mem_sel = 4'b0000;
        alu_a_sel = 0;
        alu_b_sel = 0;
        alu_op = 0;
        pc_sel = 0; // 默认走pc+4
        br_type = 0;
        is_jalr = 0;
        rf_w_en = 0; // 默认不写入
        wb_sel = 0;
        use_rs1 = 0; // 默认不读
        use_rs2 = 0; // 默认不读
        csr_op = 0;
        csr_use_imm = 0;
        csr_w_en = 0;
        is_ecall = 0;
        is_ebreak = 0;
        is_mret = 0;
        is_sfence_vma = 0;
        is_fence_i = 0;
        illegal = 0;

        case (opcode[6:2])
            // R-type
            5'b01100: begin
                alu_a_sel = 0; // reg_rdata1
                alu_b_sel = 0; // reg_rdata2
                use_rs1 = 1;
                use_rs2 = 1;
                rf_w_en = 1;
                wb_sel = 1; // alu result
                case ({funct7, funct3})
                    {7'b0000000, 3'b000}: alu_op = 4'd0; // ADD
                    {7'b0100000, 3'b000}: alu_op = 4'd1; // SUB
                    {7'b0000000, 3'b111}: alu_op = 4'd2; // AND
                    {7'b0000000, 3'b110}: alu_op = 4'd3; // OR
                    {7'b0000000, 3'b100}: alu_op = 4'd4; // XOR
                    {7'b0000000, 3'b010}: alu_op = 4'd5; // SLT
                    {7'b0000000, 3'b011}: alu_op = 4'd6; // SLTU
                    {7'b0100000, 3'b111}: alu_op = 4'd12; // ANDN
                    {7'b0100000, 3'b100}: alu_op = 4'd13; // XNOR
                    default: begin // 不认识的编码不写寄存器
                        rf_w_en = 0;
                        illegal = 1;
                    end
                endcase
            end

            // I-type
            5'b00100: begin
                alu_a_sel = 0; // reg_rdata1
                alu_b_sel = 1; // imm
                use_rs1 = 1;
                rf_w_en = 1;
                wb_sel = 1; // alu result
                case (funct3)
                    3'b000:
                        alu_op = 4'd0; // ADDI
                    3'b111:
                        alu_op = 4'd2; // ANDI
                    3'b110:
                        alu_op = 4'd3; // ORI
                    3'b010:
                        alu_op = 4'd5; // SLTI
                    3'b011:
                        alu_op = 4'd6; // SLTIU
                    3'b001: begin
                        if (funct7 == 7'b0000000) alu_op = 4'd7; // SLLI
                        else if (funct7 == 7'b0110000 && funct5 == 5'd0) alu_op = 4'd10; // CLZ
                        else begin
                            rf_w_en = 0;
                            illegal = 1;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) alu_op = 4'd8; // SRLI
                        else if (funct7 == 7'b0100000) alu_op = 4'd9; // SRAI
                        else begin
                            rf_w_en = 0;
                            illegal = 1;
                        end
                    end
                    default: begin
                        rf_w_en = 0;
                        illegal = 1;
                    end
                endcase
            end

            5'b00000: begin // LB, LW
                alu_a_sel = 0; // reg_rdata1
                alu_b_sel = 1; // imm
                alu_op = 0; // ADD
                use_rs1 = 1;
                mem_req = 1;
                mem_we = 0;
                rf_w_en = 1;
                wb_sel = 0; // mem_rdata
                case (funct3)
                    3'b000:
                        mem_sel = 4'b0001; // 1 byte
                    3'b010:
                        mem_sel = 4'b1111; // 1 word
                    default: begin
                        mem_req = 0;
                        rf_w_en = 0;
                        illegal = 1;
                    end
                endcase
            end

            // S-type
            5'b01000: begin // SB, SW
                alu_a_sel = 0; // reg_rdata1
                alu_b_sel = 1; // imm
                alu_op = 0; // ADD
                use_rs1 = 1; // 基址
                use_rs2 = 1; // 写入数据
                mem_req = 1;
                mem_we = 1; // 写入
                case (funct3)
                    3'b000:
                        mem_sel = 4'b0001; // 1 byte
                    3'b010:
                        mem_sel = 4'b1111; // 1 word
                    default: begin
                        mem_req = 0;
                        mem_we = 0;
                        illegal = 1;
                    end
                endcase
            end

            // B-type:
            5'b11000: begin
                alu_a_sel = 1; // pc
                alu_b_sel = 1; // imm
                alu_op = 0; // ADD
                use_rs1 = 1;
                use_rs2 = 1;
                case (funct3)
                    3'b000: begin br_type = 3'd1; pc_sel = 1; end // BEQ
                    3'b001: begin br_type = 3'd2; pc_sel = 1; end // BNE
                    3'b100: begin br_type = 3'd3; pc_sel = 1; end // BLT
                    3'b101: begin br_type = 3'd4; pc_sel = 1; end // BGE
                    3'b110: begin br_type = 3'd5; pc_sel = 1; end // BLTU
                    3'b111: begin br_type = 3'd6; pc_sel = 1; end // BGEU
                    default: begin // 不是合法的条件分支: 不跳, 也不读操作数
                        use_rs1 = 0;
                        use_rs2 = 0;
                        illegal = 1;
                    end
                endcase
            end

            // U-type:
            5'b01101: begin // LUI
                alu_b_sel = 1; // imm
                alu_op = 4'd11; // pass b
                rf_w_en = 1;
                wb_sel = 1; // alu result
            end

            5'b00101: begin // AUIPC
                alu_a_sel = 1; // pc
                alu_b_sel = 1; // imm
                alu_op = 4'd0; // ADD
                rf_w_en = 1;
                wb_sel = 1; // alu result
            end

            // J-type:
            5'b11011: begin // JAL
                alu_a_sel = 1; // pc
                alu_b_sel = 1; // imm
                alu_op = 0; // ADD
                pc_sel = 1; // 无条件跳转到 alu result
                rf_w_en = 1;
                wb_sel = 2; // pc + 4
            end

            5'b11001: begin // JALR
                if (funct3 == 3'b000) begin
                    alu_a_sel = 0; // reg_rdata1
                    alu_b_sel = 1; // imm
                    alu_op = 0; // ADD
                    pc_sel = 1; // 无条件跳转到 alu result
                    is_jalr = 1;
                    use_rs1 = 1;
                    rf_w_en = 1;
                    wb_sel = 2; // pc + 4
                end else begin
                    illegal = 1;
                end
            end

            5'b00011: begin
                // FENCE (000) 解码为 NOP, FENCE.I (001) 做取指屏障
                if (funct3 == 3'b001) is_fence_i = 1;
                else if (funct3 != 3'b000) illegal = 1;
            end

            5'b11100: begin
                case (funct3)
                    3'b000: begin
                        if (rs1 == 5'd0 && rd == 5'd0 && {funct7, funct5} == 12'h000) is_ecall = 1;
                        else if (rs1 == 5'd0 && rd == 5'd0 && {funct7, funct5} == 12'h001) is_ebreak = 1;
                        else if (rs1 == 5'd0 && rd == 5'd0 && {funct7, funct5} == 12'h302) is_mret = 1;
                        else if (rd == 5'd0 && funct7 == 7'b0001001) is_sfence_vma = 1;
                        else illegal = 1;
                    end
                    3'b100:
                        illegal = 1;
                    default: begin
                        csr_op = funct3[1:0];
                        csr_use_imm = funct3[2];
                        csr_w_en = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
                        use_rs1 = !funct3[2];
                        rf_w_en = 1;
                        wb_sel = 3;
                    end
                endcase
            end

            default:
                illegal = 1;
        endcase

        if (opcode[1:0] != 2'b11) illegal = 1;
    end
endmodule
