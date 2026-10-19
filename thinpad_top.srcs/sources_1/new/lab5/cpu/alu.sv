module alu (
    input logic [15:0] a,
    input logic [15:0] b,
    input logic [2:0] op,

    output logic [15:0] result
);
    always_comb begin
        case (op)
            3'd0: result = a + b; // ADD
            3'd1: result = a & b; // AND
            3'd2: result = b; // pass b
            default: result = 16'b0;
        endcase
    end
endmodule
