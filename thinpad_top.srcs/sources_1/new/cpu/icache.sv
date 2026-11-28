module icache #(
    parameter int INDEX_BITS = 6
) (
    input logic clk,
    input logic rst,

    input logic [31:0] satp_i,
    input logic flush_i,

    // CPU 侧
    input logic req_i, // 取指请求
    input logic [31:0] addr_i, // 取指虚拟地址
    output logic [31:0] rdata_o, // 取到的指令
    output logic ready_o,
    output logic page_fault_o,
    output logic access_fault_o,

    // 总线侧
    output logic wb_req_o,
    output logic [31:0] wb_addr_o,
    input logic [31:0] wb_rdata_i,
    input logic wb_ready_i,
    input logic wb_idle_i,
    input logic wb_page_fault_i,
    input logic wb_access_fault_i,
    output logic busy_o,

    // store buffer 侧的 forwarding
    output logic [31:0] merge_addr_o,
    output logic [31:0] merge_data_o,
    input logic [31:0] merge_data_i,

    // store 入队时失效对应指令行
    input logic st_req_i,
    input logic [31:0] st_addr_i
);
    // 内部状态
    localparam int ENTRIES = 1 << INDEX_BITS;
    localparam int TAG_W = 32 - INDEX_BITS - 2;
    logic [31:0] data_arr[ENTRIES];
    logic [TAG_W-1:0] tag_arr[ENTRIES];
    logic [ENTRIES-1:0] valid;

    // 内存类型
    logic [31:0] satp_q;
    logic bypass;
    assign bypass = satp_i[31]; // 不支持虚存
    logic flush_all;
    assign flush_all = flush_i || (satp_i != satp_q);

    // 内部状态
    logic [INDEX_BITS-1:0] line_idx;
    logic [TAG_W-1:0] line_tag;
    logic hit;

    // 取指请求
    always_comb begin
        line_idx = addr_i[INDEX_BITS+1:2];
        line_tag = addr_i[31:INDEX_BITS+2];

        hit = valid[line_idx]
            && (tag_arr[line_idx] == line_tag)
            && !bypass;
    end

    // store 入队时的失效请求
    logic [INDEX_BITS-1:0] st_idx;
    logic [TAG_W-1:0] st_tag;
    logic st_hit;
    always_comb begin
        st_idx = st_addr_i[INDEX_BITS+1:2];
        st_tag = st_addr_i[31:INDEX_BITS+2];
        st_hit = st_req_i
            && valid[st_idx]
            && (tag_arr[st_idx] == st_tag);
    end

    // 总线请求
    // FSM
    logic if_start; // 是否需要开启
    logic is_finished; // 是否已经完成

    logic [31:0] miss_addr_q; // 需要请求的地址锁存, 用于 refill
    logic [INDEX_BITS-1:0] miss_idx;
    logic [TAG_W-1:0] miss_tag;

    assign if_start = req_i && !hit && !is_finished && wb_idle_i;
    assign busy_o = is_finished;
    assign miss_idx = miss_addr_q[INDEX_BITS+1:2];
    assign miss_tag = miss_addr_q[31:INDEX_BITS+2];

    always_comb begin
        wb_req_o = if_start || is_finished;
        wb_addr_o = is_finished ? miss_addr_q : addr_i;
    end

    // 返回结果
    logic [31:0] fetch_raw;
    always_comb begin
        fetch_raw = hit ? data_arr[line_idx] : wb_rdata_i;
        merge_addr_o = addr_i;
        merge_data_o = fetch_raw;
        rdata_o = merge_data_i; // 过一遍 store buffer 转发; 注意 store 有部分修改

        ready_o = !req_i || hit || (is_finished && wb_ready_i);
        page_fault_o = is_finished && !hit && wb_page_fault_i;
        access_fault_o = is_finished && !hit && wb_access_fault_i;
    end

    // cache 写入
    logic fill;
    assign fill = is_finished
        && wb_ready_i
        && !wb_page_fault_i
        && !wb_access_fault_i
        && !bypass;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            satp_q <= '0;
            is_finished <= 1'b0;
            miss_addr_q <= '0;
        end else begin
            satp_q <= satp_i;

            // 状态转移逻辑
            if (if_start) begin
                is_finished <= 1'b1;
                miss_addr_q <= addr_i;
            end else if (wb_ready_i) begin
                is_finished <= 1'b0;
            end

            // 执行逻辑
            if (flush_all) begin
                valid <= '0;
            end else begin
                if (st_hit) begin
                    valid[st_idx] <= 1'b0; // 直接 invalidate
                end

                if (fill && !(st_hit && (st_idx == miss_idx))) begin
                    valid[miss_idx] <= 1'b1;
                    tag_arr[miss_idx] <= miss_tag;
                    data_arr[miss_idx] <= merge_data_i;
                end
            end
        end
    end
endmodule
