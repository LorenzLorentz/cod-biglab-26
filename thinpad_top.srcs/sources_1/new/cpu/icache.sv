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
    input logic [31:0] wb_data_i,
    input logic wb_ready_i,
    input logic wb_page_fault_i,
    input logic wb_access_fault_i,

    // store 导致失效
    input logic st_req_i,
    input logic st_we_i,
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
        line_idx = vaddr_i[INDEX_BITS+1:2];
        line_tag = vaddr_i[31:INDEX_BITS+2];

        hit = valid[line_idx]
            && (tag_arr[line_idx] == line_tag)
            && !bypass;
    end

    // store 请求
    logic [INDEX_BITS-1:0] st_idx;
    logic [TAG_W-1:0] st_tag;
    logic st_hit;
    always_comb begin
        st_idx = st_addr_i[INDEX_BITS+1:2];
        st_tag = st_addr_i[31:INDEX_BITS+2];

        st_hit = st_req_i
            && st_we_i
            && valid[st_idx]
            && (tag_arr[st_idx] == st_tag);
    end

    // 总线请求
    always_comb begin
        wb_req_o = req_i && !hit;
        wb_adr_o = vaddr_i;
    end

    // 返回结果
    always_comb begin
        rdata_o = hit ? data_arr[line_idx] : wb_dat_i;
        ready_o = !req_i || hit || wb_ready_i; // 没有请求时不阻塞
        page_fault_o = hit ? 1'b0 : wb_page_fault_i;
        access_fault_o = hit ? 1'b0 : wb_access_fault_i;
    end

    // cache 写入
    logic fill;
    assign fill = wb_req_o
        && wb_ready_i
        && !wb_page_fault_i
        && !wb_access_fault_i
        && !bypass;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            satp_q <= '0;
        end else begin
            satp_q <= satp_i;

            if (flush_all) begin
                valid <= '0;
            end else begin
                if (st_hit) begin
                    valid[st_idx] <= 1'b0; // 直接 invalidate
                end

                if (fill && !(st_hit && (st_idx == line_idx))) begin
                    valid[line_idx] <= 1'b1;
                    tag_arr[line_idx] <= line_tag;
                    data_arr[line_idx] <= wb_dat_i;
                end
            end
        end
    end
endmodule
