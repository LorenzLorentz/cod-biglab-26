module button_in(
    input logic clk,
    input logic rst,
    input logic push_btn,
    output logic trigger
);
    logic [1:0] btn_sync;
    logic button_in;

    always_ff @(posedge clk) begin
        if (rst) begin
            btn_sync <= 2'b00;
            button_in <= 1'b0;
            trigger <= 1'b0;
        end else begin
            btn_sync <= {btn_sync[0], push_btn};
            button_in <= btn_sync[1];
            trigger <= btn_sync[1] & ~btn_sync[0];
        end
    end
endmodule
