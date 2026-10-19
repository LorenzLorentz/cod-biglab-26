module alu (
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [1:0] op,

    output logic [31:0] result
);
    always_comb begin
        case (op)
            2'd0: result = a + b; // ADD
            2'd1: result = a & b; // AND
            2'd2: result = b; // pass b
            default: result = 32'b0;
        endcase
    end
endmodule
