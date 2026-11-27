module dcache #(
    parameter int INDEX_BITS = 8,
    parameter int SB_DEPTH = 8
) (
    input logic clk,
    input logic rst,

    input logic cpu_step_i,
    input logic [31:0] satp_i,

    // CPU 侧
    input logic req_i,
    input logic we_i,
    input logic [3:0] sel_i,
    input logic [31:0] addr_i,
    input logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic ready_o,
    output logic page_fault_o,
    output logic access_fault_o,

    // 总线侧
    output logic wb_req_o,
    output logic wb_we_o,
    output logic [3:0] wb_sel_o,
    output logic [31:0] wb_addr_o,
    output logic [31:0] wb_wdata_o,
    input logic [31:0] wb_rdata_i,
    input logic wb_ready_i,
    input logic wb_idle_i,
    input logic wb_page_fault_i,
    input logic wb_access_fault_i,

    // I-Cache 侧
    output logic sb_empty_o,
    output logic snoop_valid_o,
    output logic [31:0] snoop_addr_o,

    // store buffer forwarding
    input logic [31:0] merge_addr_i,
    input logic [31:0] merge_data_i,
    output logic [31:0] merge_data_o
);
    // 三部分之间的接口信号
    // cache <-> bus
    logic [31:0] fill_addr;
    logic [31:0] fill_data;
    logic fill_valid;
    // store buffer <-> bus
    logic sb_empty;
    logic sb_drain_done;

    // 1. Cache 部分
    localparam int ENTRIES = 1 << INDEX_BITS;
    localparam int TAG_W = 32 - INDEX_BITS - 2;
    logic [31:0] data_arr[ENTRIES];
    logic [TAG_W-1:0] tag_arr[ENTRIES];
    logic [ENTRIES-1:0] valid;

    // 内存类型
    logic [31:0] satp_q;
    logic bypass;
    assign bypass = satp_i[31]; // cache 不翻译地址, 分页时直接绕过
    logic flush_all;
    assign flush_all = satp_i != satp_q;

    // CPU 请求解析
    logic [INDEX_BITS-1:0] line_idx;
    logic [TAG_W-1:0] line_tag;
    logic cacheable;
    logic hit;
    logic hit_load;
    // 只有 RAM 可以缓存: 0x8000_0000 - 0x807f_ffff
    assign cacheable = !bypass && (addr_i[31:23] == 9'h100);
    always_comb begin
        line_idx = addr_i[INDEX_BITS+1:2];
        line_tag = addr_i[31:INDEX_BITS+2];

        hit = valid[line_idx]
            && (tag_arr[line_idx] == line_tag)
            && cacheable;

        hit_load = hit && !we_i;
    end

    // 总线返回结果解析
    logic [INDEX_BITS-1:0] fill_idx;
    logic [TAG_W-1:0] fill_tag;
    assign fill_idx = fill_addr[INDEX_BITS+1:2];
    assign fill_tag = fill_addr[31:INDEX_BITS+2];

    // cache 写入与更新
    logic [31:0] byte_mask;
    logic [31:0] line_merged;
    always_comb begin
        byte_mask = {{8{sel_i[3]}}, {8{sel_i[2]}}, {8{sel_i[1]}}, {8{sel_i[0]}}};
        line_merged = (data_arr[line_idx] & ~byte_mask) | (wdata_i & byte_mask);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            satp_q <= '0;
        end else begin
            satp_q <= satp_i;

            if (flush_all) begin
                valid <= '0;
            end else begin
                if (sb_enque && hit) begin
                    data_arr[line_idx] <= line_merged;
                end

                if (fill_valid) begin
                    valid[fill_idx] <= 1'b1;
                    tag_arr[fill_idx] <= fill_tag;
                    data_arr[fill_idx] <= fill_data;
                end
            end
        end
    end

    // 2. Store Buffer 部分
    // 内部状态
    localparam int SB_PTR_W = (SB_DEPTH > 1) ? $clog2(SB_DEPTH) : 1;
    logic [31:0] sb_addr[SB_DEPTH];
    logic [31:0] sb_wdata[SB_DEPTH];
    logic [3:0] sb_sel[SB_DEPTH];
    logic [SB_PTR_W-1:0] sb_head;
    logic [SB_PTR_W-1:0] sb_tail;
    logic [31:0] sb_count;

    assign sb_empty = (sb_count == 0);
    assign sb_empty_o = sb_empty;

    // enque/deque
    // 内部状态
    logic sb_enque;
    logic sb_deque;
    logic sb_store_ready;

    assign sb_store_ready = ((sb_count < SB_DEPTH) || sb_drain_done);
    assign sb_deque = sb_drain_done;
    assign sb_enque = req_i && we_i && cacheable // 需要 store
        && sb_store_ready // 有空间
        && cpu_step_i; // cpu 步进

    assign snoop_valid_o = sb_enque;
    assign snoop_addr_o = addr_i;

    // 将要写入内存的数据
    logic [31:0] sb_oldest_addr;
    logic [31:0] sb_oldest_wdata;
    logic [3:0] sb_oldest_sel;
    assign sb_oldest_addr = sb_addr[sb_head];
    assign sb_oldest_wdata = sb_wdata[sb_head];
    assign sb_oldest_sel = sb_sel[sb_head];

    // 计数更新
    logic [31:0] sb_count_next;
    always_comb begin
        sb_count_next = sb_count;

        if (sb_deque) begin
            sb_count_next = sb_count_next - 1'b1;
        end

        if (sb_enque) begin
            sb_count_next = sb_count_next + 1'b1;
        end
    end

    // 执行 enque/deque
    always_ff @(posedge clk) begin
        if (rst) begin
            sb_head <= '0;
            sb_tail <= '0;
            sb_count <= '0;
        end else begin
            sb_count <= sb_count_next;

            if (sb_deque) begin
                sb_head <= sb_head + 1'b1;
            end

            if (sb_enque) begin
                sb_addr[sb_tail] <= addr_i;
                sb_wdata[sb_tail] <= wdata_i;
                sb_sel[sb_tail] <= sel_i;
                sb_tail <= sb_tail + 1'b1;
            end
        end
    end

    // store buffer forwarding 接口
    function automatic logic [31:0] merge_word(input logic [31:0] a, input logic [31:0] d);
        logic [31:0] m;
        logic [31:0] mask;
        logic [SB_PTR_W-1:0] idx;
        m = d;
        for (int i = 0; i < SB_DEPTH; i++) begin
            if (i < sb_count) begin
                idx = sb_head + SB_PTR_W'(i);
                if (sb_addr[idx][31:2] == a[31:2]) begin
                    mask = {{8{sb_sel[idx][3]}}, {8{sb_sel[idx][2]}},
                            {8{sb_sel[idx][1]}}, {8{sb_sel[idx][0]}}};
                    m = (m & ~mask) | (sb_wdata[idx] & mask);
                end
            end
        end
        return m;
    endfunction

    assign merge_data_o = merge_word(merge_addr_i, merge_data_i);

    // 3. 总线部分
    // 状态
    typedef enum logic [1:0] {
        BUS_IDLE, // 等待新请求
        BUS_OP, // 总线执行操作
        BUS_DONE // 等待 CPU 消费
    } bus_state_t;
    bus_state_t bus_state;

    typedef enum logic [1:0] {
        BUS_OP_FILL,
        BUS_OP_SYNC,
        BUS_OP_DRAIN
    } bus_op_t;
    bus_op_t bus_op;

    // 当前操作锁存
    logic [31:0] bus_addr_q;
    logic [31:0] bus_wdata_q;
    logic [3:0] bus_sel_q;
    logic bus_we_q;

    // 开始
    logic bus_start;
    bus_op_t bus_start_op;
    logic [31:0] bus_start_addr;
    logic [31:0] bus_start_wdata;
    logic [3:0] bus_start_sel;
    logic bus_start_we;

    // 状态更新
    always_ff @(posedge clk) begin
        if (rst) begin
            bus_state <= BUS_IDLE;
            bus_op <= BUS_OP_FILL;
            bus_addr_q <= '0;
            bus_wdata_q <= '0;
            bus_sel_q <= '0;
            bus_we_q <= 1'b0;
        end else begin
            if (bus_start) begin
                bus_state <= BUS_OP;
                bus_op <= bus_start_op;
                bus_addr_q <= bus_start_addr;
                bus_wdata_q <= bus_start_wdata;
                bus_sel_q <= bus_start_sel;
                bus_we_q <= bus_start_we;
            end else if (bus_finish) begin
                if (bus_op == BUS_OP_DRAIN) begin
                    bus_state <= BUS_IDLE;
                end else if (cpu_step_i) begin
                    bus_state <= BUS_IDLE;
                end else begin
                    bus_state <= BUS_DONE;
                end
            end else if ((bus_state == BUS_DONE) && cpu_step_i) begin
                bus_state <= BUS_IDLE;
            end
        end
    end

    // 操作选择
    // 优先级 fill > sync > drain
    logic bus_need_fill;
    logic bus_need_sync;

    assign bus_need_fill = req_i && !we_i && cacheable && !hit;
    assign bus_need_sync = req_i && !cacheable && sb_empty;

    always_comb begin
        bus_start = 1'b0;
        bus_start_op = BUS_OP_FILL;
        bus_start_addr = addr_i;
        bus_start_wdata = wdata_i;
        bus_start_sel = we_i ? sel_i : 4'b1111;
        bus_start_we = we_i;

        if ((bus_state == BUS_IDLE) && wb_idle_i) begin
            if (bus_need_fill) begin
                bus_start = 1'b1;
                bus_start_op = BUS_OP_FILL;
                bus_start_addr = addr_i;
                bus_start_wdata = wdata_i;
                bus_start_sel = 4'b1111;
                bus_start_we = 1'b0;
            end else if (bus_need_sync) begin
                bus_start = 1'b1;
                bus_start_op = BUS_OP_SYNC;
                bus_start_addr = addr_i;
                bus_start_wdata = wdata_i;
                bus_start_sel = we_i ? sel_i : 4'b1111;
                bus_start_we = we_i;
            end else if (!sb_empty) begin
                bus_start = 1'b1;
                bus_start_op = BUS_OP_DRAIN;
                bus_start_addr = sb_oldest_addr;
                bus_start_wdata = sb_oldest_wdata;
                bus_start_sel = sb_oldest_sel;
                bus_start_we = 1'b1;
            end
        end
    end

    // 完成操作
    logic bus_finish;
    logic fill_finish;
    logic sync_finish;
    logic fill_avail;
    logic sync_avail;
    always_comb begin
        bus_finish = (bus_state == BUS_OP) && wb_ready_i;
        fill_finish = bus_finish && (bus_op == BUS_OP_FILL);
        sync_finish = bus_finish && (bus_op == BUS_OP_SYNC);
        sb_drain_done = bus_finish && (bus_op == BUS_OP_DRAIN);

        fill_avail = fill_finish || ((bus_state == BUS_DONE) && (bus_op == BUS_OP_FILL));
        sync_avail = sync_finish || ((bus_state == BUS_DONE) && (bus_op == BUS_OP_SYNC));
    end

    // FILL返回
    always_comb begin
        fill_addr = bus_addr_q;
        fill_data = merge_word(bus_addr_q, wb_rdata_i);
        fill_valid = fill_finish && !wb_page_fault_i && !wb_access_fault_i;
    end

    // 总线输出
    always_comb begin
        wb_req_o = bus_start || (bus_state == BUS_OP);

        if (bus_state == BUS_OP) begin
            wb_we_o = bus_we_q;
            wb_sel_o = bus_we_q ? bus_sel_q : 4'b1111;
            wb_addr_o = bus_addr_q;
            wb_wdata_o = bus_wdata_q;
        end else begin
            wb_we_o = bus_start_we;
            wb_sel_o = bus_start_we ? bus_start_sel : 4'b1111;
            wb_addr_o = bus_start_addr;
            wb_wdata_o = bus_start_wdata;
        end
    end

    // CPU 返回
    // 内部变量
    logic bus_resp;
    logic [31:0] bus_resp_rdata_now;
    assign bus_resp = fill_finish || sync_finish;
    assign bus_resp_rdata_now = (bus_op == BUS_OP_FILL) ? fill_data : wb_rdata_i;

    // 返回数据锁存
    logic [31:0] bus_resp_rdata_q;
    logic bus_resp_pf_q;
    logic bus_resp_af_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            bus_resp_rdata_q <= '0;
            bus_resp_pf_q <= 1'b0;
            bus_resp_af_q <= 1'b0;
        end else if (bus_resp) begin
            bus_resp_rdata_q <= bus_resp_rdata_now;
            bus_resp_pf_q <= wb_page_fault_i;
            bus_resp_af_q <= wb_access_fault_i;
        end
    end

    // 结果返回
    logic bus_resp_valid;
    logic [31:0] bus_resp_rdata;
    logic bus_resp_pf;
    logic bus_resp_af;
    always_comb begin
        bus_resp_valid = bus_resp || (bus_state == BUS_DONE);

        if (bus_state == BUS_DONE) begin
            bus_resp_rdata = bus_resp_rdata_q;
            bus_resp_pf = bus_resp_pf_q;
            bus_resp_af = bus_resp_af_q;
        end else begin
            bus_resp_rdata = bus_resp_rdata_now;
            bus_resp_pf = wb_page_fault_i;
            bus_resp_af = wb_access_fault_i;
        end
    end

    // 4. CPU 返回
    always_comb begin
        ready_o = !req_i || hit_load || sb_store_ready || bus_resp_valid;
        rdata_o = hit_load ? data_arr[line_idx] : bus_resp_rdata;
        page_fault_o = bus_resp_valid && bus_resp_pf;
        access_fault_o = bus_resp_valid && bus_resp_af;
    end
endmodule
