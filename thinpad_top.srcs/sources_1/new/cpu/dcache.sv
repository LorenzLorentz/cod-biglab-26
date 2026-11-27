module dcache #(
    parameter int INDEX_BITS = 8
) (
    input logic clk,
    input logic rst,

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
    input logic wb_page_fault_i,
    input logic wb_access_fault_i
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
    assign bypass = satp_i[31]; // cache 不翻译地址, 分页时直接绕过
    logic flush_all;
    assign flush_all = satp_i != satp_q;

    // 内部状态
    logic [INDEX_BITS-1:0] line_idx;
    logic [TAG_W-1:0] line_tag;
    logic cacheable;
    logic hit;
    logic hit_load;
    // 只有 RAM 可以缓存: 0x8000_0000 - 0x807f_ffff
    assign cacheable = !bypass && (addr_i[31:23] == 9'h100);

    // CPU 请求解析
    always_comb begin
        line_idx = addr_i[INDEX_BITS+1:2];
        line_tag = addr_i[31:INDEX_BITS+2];

        hit = valid[line_idx]
            && (tag_arr[line_idx] == line_tag)
            && cacheable;

        hit_load = hit && !we_i;
    end

    // 总线请求
    always_comb begin
        wb_req_o = req_i && (we_i || !hit); // store 一律写, load 只在 miss 时读
        wb_we_o = we_i;
        wb_sel_o = we_i ? sel_i : 4'b1111;
        wb_addr_o = addr_i;
        wb_wdata_o = wdata_i;
    end

    // 返回结果
    always_comb begin
        rdata_o = hit_load ? data_arr[line_idx] : wb_rdata_i;
        ready_o = !req_i || hit_load || wb_ready_i; // 没有请求/load, 命中时不阻塞
        page_fault_o = wb_req_o && wb_page_fault_i;
        access_fault_o = wb_req_o && wb_access_fault_i;
    end

    // cache 写入与更新
    logic fill;
    logic update;
    logic [31:0] byte_mask;

    assign fill = wb_req_o && !we_i && wb_ready_i
        && !wb_page_fault_i
        && !wb_access_fault_i
        && cacheable;

    assign update = wb_req_o && we_i && hit && wb_ready_i
        && !wb_page_fault_i
        && !wb_access_fault_i;

    always_comb begin
        byte_mask = {{8{sel_i[3]}}, {8{sel_i[2]}}, {8{sel_i[1]}}, {8{sel_i[0]}}};
    end

    // 执行写入
    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            satp_q <= '0;
        end else begin
            satp_q <= satp_i;

            if (flush_all) begin
                valid <= '0;
            end else begin
                if (fill) begin
                    valid[line_idx] <= 1'b1;
                    tag_arr[line_idx] <= line_tag;
                    data_arr[line_idx] <= wb_rdata_i;
                end else if (update) begin
                    data_arr[line_idx] <= (data_arr[line_idx] & ~byte_mask) | (wdata_i & byte_mask);
                end
            end
        end
    end
endmodule
