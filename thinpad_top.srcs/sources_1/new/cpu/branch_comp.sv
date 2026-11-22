module branch_comp (
    input logic [31:0] a,
    input logic [31:0] b,

    output logic br_eq,
    output logic br_lt,
    output logic br_ltu
);
    assign br_eq = (a == b);
    assign br_lt = ($signed(a) < $signed(b));
    assign br_ltu = (a < b);
endmodule
