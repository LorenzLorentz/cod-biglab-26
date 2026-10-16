module alu (
    input logic [15:0] a,
    input logic [15:0] b,
    input logic [3:0] op,

    output logic [15:0] result
);
    always_comb begin
        case (op)
            4'd1: result = a + b; // 加
            4'd2: result = a - b; // 减
            4'd3: result = a & b; // 按位与
            4'd4: result = a | b; // 按位或
            4'd5: result = a ^ b; // 按位异或
            4'd6: result = ~a; // 按位取非
            4'd7: result = a << b[3:0]; // 逻辑左移
            4'd8: result = a >> b[3:0]; // 逻辑右移
            4'd9: result = $signed(a) >>> b[3:0]; // 算术右移
            4'd10: result = (a << b[3:0]) | (a >> (16 - b[3:0])); // 循环左移
            default: result = 16'b0;
        endcase
    end
endmodule
