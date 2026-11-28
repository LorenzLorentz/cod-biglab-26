module branch_predictor #(
    parameter int INDEX_BITS = 6
) (
    input logic clk,
    input logic rst,

    // prediction
    input logic [31:0] fetch_pc,
    output logic pred_taken,
    output logic [31:0] pred_target,

    // update
    input logic update_valid,
    input logic [31:0] update_pc,
    input logic update_taken,
    input logic [31:0] update_target
);
    localparam int ENTRIES = 1 << INDEX_BITS;
    localparam int TAG_W = 32 - INDEX_BITS - 2;

    // 计数器
    logic [31:0] target_arr[ENTRIES];
    logic [TAG_W-1:0] tag_arr[ENTRIES];
    logic [1:0] counter_arr[ENTRIES];
    logic [ENTRIES-1:0] valid;

    // prediction
    logic [INDEX_BITS-1:0] fetch_idx;
    logic [TAG_W-1:0] fetch_tag;
    logic fetch_hit;
    always_comb begin
        fetch_idx = fetch_pc[INDEX_BITS+1:2];
        fetch_tag = fetch_pc[31:INDEX_BITS+2];

        fetch_hit = valid[fetch_idx]
            && (tag_arr[fetch_idx] == fetch_tag);

        pred_taken = fetch_hit && counter_arr[fetch_idx][1];
        pred_target = target_arr[fetch_idx];
    end

    // update
    logic [INDEX_BITS-1:0] update_idx;
    logic [TAG_W-1:0] update_tag;
    logic update_alloc;
    always_comb begin
        update_idx = update_pc[INDEX_BITS+1:2];
        update_tag = update_pc[31:INDEX_BITS+2];
        update_alloc = !(valid[update_idx] && (tag_arr[update_idx] == update_tag));
    end

    // 执行更新
    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
        end else if (update_valid) begin
            valid[update_idx] <= 1'b1;
            tag_arr[update_idx] <= update_tag;
            target_arr[update_idx] <= update_target;

            if (update_alloc) begin
                counter_arr[update_idx] <= update_taken ? 2'b10 : 2'b01; // 弱方向计数器
            end else if (update_taken) begin
                counter_arr[update_idx] <= (counter_arr[update_idx] == 2'b11)
                    ? 2'b11 : counter_arr[update_idx] + 2'b01;
            end else begin
                counter_arr[update_idx] <= (counter_arr[update_idx] == 2'b00)
                    ? 2'b00 : counter_arr[update_idx] - 2'b01;
            end
        end
    end
endmodule
