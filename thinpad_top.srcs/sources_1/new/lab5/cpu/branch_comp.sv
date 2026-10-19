module branch_comp (
    input logic [31:0] a,
    input logic [31:0] b,

    output logic breq
);
    assign breq = (a==b);
endmodule
