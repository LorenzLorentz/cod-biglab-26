module cpu_alu (
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [3:0] op,

    output logic [31:0] result
);
    function automatic logic [31:0] count_leading_zeros(input logic [31:0] x);
        count_leading_zeros = 32'd32;
        for (int i = 0; i < 32; i++) begin
            if (x[31-i] && (count_leading_zeros == 32'd32)) begin
                count_leading_zeros = 32'(i);
            end
        end
    endfunction

    always_comb begin
        case (op)
            4'd0: result = a + b; // ADD
            4'd1: result = a - b; // SUB
            4'd2: result = a & b; // AND
            4'd3: result = a | b; // OR
            4'd4: result = a ^ b; // XOR
            4'd5: result = {31'b0, $signed(a) < $signed(b)}; // SLT
            4'd6: result = {31'b0, a < b}; // SLTU
            4'd7: result = a << b[4:0]; // SLL
            4'd8: result = a >> b[4:0]; // SRL
            4'd9: result = $signed(a) >>> b[4:0]; // SRA
            4'd10: result = count_leading_zeros(a); // CLZ
            4'd11: result = b; // pass b
            4'd12: result = a & ~b; // ANDN
            4'd13: result = ~(a ^ b); // XNOR
            default: result = 32'b0;
        endcase
    end
endmodule
