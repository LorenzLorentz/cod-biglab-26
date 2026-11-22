module branch_comp (
    input logic [31:0] a,
    input logic [31:0] b,

    output logic br_eq
);
    assign br_eq = (a==b);
endmodule
