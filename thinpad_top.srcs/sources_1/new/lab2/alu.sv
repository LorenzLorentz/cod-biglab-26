module alu (
    input logic [15:0] a,
    input logic [15:0] b,
    input logic [3:0] op,

    output logic [15:0] y
);
    always_comb begin
        case (op)
            4'd1: y = a + b; // 加
            4'd2: y = a - b; // 减
            4'd3: y = a & b; // 按位与
            4'd4: y = a | b; // 按位或
            4'd5: y = a ^ b; // 按位异或
            4'd6: y = ~a; // 按位取非
            4'd7: y = a << b[3:0]; // 逻辑左移
            4'd8: y = a >> b[3:0]; // 逻辑右移
            4'd9: y = $signed(a) >>> b[3:0]; // 算术右移
            4'd10: y = (a << b[3:0]) | (a >> (16 - b[3:0])); // 循环左移
            default: y = 16'b0;
        endcase
    end
endmodule
