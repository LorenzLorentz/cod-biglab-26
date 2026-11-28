module sv32_wb_channel #(
    parameter bit INSTRUCTION = 1'b0
) (
    input logic clk_i,
    input logic rst_i,
    input logic [31:0] satp_i,
    input logic [1:0] priv_i,
    input logic sum_i,
    input logic mxr_i,

    input logic req_i,
    input logic [31:0] vaddr_i,
    input logic we_i,
    input logic [3:0]  sel_i,
    input logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic ready_o,
    output logic page_fault_o,
    output logic access_fault_o,
    output logic idle_o,
    input logic cpu_step_i,

    output logic wb_req_o,
    output logic [31:0] wb_adr_o,
    output logic wb_we_o,
    output logic [3:0] wb_sel_o,
    output logic [31:0] wb_dat_o,
    input logic [31:0] wb_dat_i,
    input logic wb_ack_i,
    input logic wb_err_i
);
    typedef enum logic [2:0] {
        IDLE,
        READ_PTE,
        CHECK_PTE,
        ACCESS,
        DONE,
        PAGE_FAULT,
        ACCESS_FAULT
    } state_t;
    state_t state;

    // 锁存
    logic [31:0] vaddr_q;
    logic [31:0] wdata_q;
    logic [31:0] pte_q;
    logic [3:0] sel_q;
    logic we_q;
    logic user_q;
    logic sum_q;
    logic mxr_q;
    logic root_level_q;
    logic [33:0] paddr_q;

    // pte 解析
    logic pte_v;
    logic pte_r;
    logic pte_w;
    logic pte_x;
    logic pte_u;
    logic leaf;

    always_comb begin
        pte_v = pte_q[0];
        pte_r = pte_q[1];
        pte_w = pte_q[2];
        pte_x = pte_q[3];
        pte_u = pte_q[4];
        leaf  = pte_r || pte_x;
    end

    // 权限检查
    logic privilege_ok;
    logic access_ok;
    logic misaligned_superpage;

    always_comb begin
        privilege_ok = user_q ? pte_u : (!pte_u || (sum_q && !INSTRUCTION));
        access_ok   = INSTRUCTION ? pte_x : (we_q ? pte_w : (pte_r || (mxr_q && pte_x)));
        misaligned_superpage = root_level_q && (pte_q[19:10] != 10'b0);
    end

    // 总线信号
    assign wb_req_o = (state == READ_PTE) || (state == ACCESS);
    assign wb_adr_o = paddr_q[31:0];
    assign wb_we_o = (state == ACCESS) && we_q;
    assign wb_sel_o = (state == ACCESS) ? sel_q : 4'b1111;
    assign wb_dat_o = wdata_q;

    assign page_fault_o = (state == PAGE_FAULT);
    assign access_fault_o = (state == ACCESS_FAULT);
    assign ready_o = !req_i || (state == DONE) || page_fault_o || access_fault_o;
    assign idle_o = (state == IDLE);

    // 状态机
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state <= IDLE;
            rdata_o <= '0;
        end else begin
            case (state)
                IDLE: if (req_i) begin
                    vaddr_q <= vaddr_i;
                    wdata_q <= wdata_i;
                    sel_q <= sel_i;
                    we_q <= we_i;
                    user_q <= (priv_i == 2'b00);
                    sum_q <= sum_i;
                    mxr_q <= mxr_i;
                    rdata_o <= '0;
                    if (satp_i[31] && priv_i != 2'b11) begin
                        root_level_q <= 1'b1;
                        paddr_q <= {satp_i[21:0], vaddr_i[31:22], 2'b00};
                        state <= READ_PTE;
                    end else begin
                        paddr_q <= {2'b00, vaddr_i};
                        state <= ACCESS;
                    end
                end

                READ_PTE: begin
                    if (wb_err_i) begin
                        state <= ACCESS_FAULT;
                    end else if (wb_ack_i) begin
                        pte_q <= wb_dat_i;
                        state <= CHECK_PTE;
                    end
                end

                CHECK_PTE: begin
                    if (!pte_v || (pte_w && !pte_r)) begin
                        state <= PAGE_FAULT;
                    end else if (leaf) begin
                        if (!privilege_ok || !access_ok || misaligned_superpage) begin
                            state <= PAGE_FAULT;
                        end else begin
                            paddr_q <= root_level_q ? {pte_q[31:20], vaddr_q[21:0]} :
                                                     {pte_q[31:10], vaddr_q[11:0]};
                            state <= ACCESS;
                        end
                    end else if (!root_level_q || pte_u) begin
                        state <= PAGE_FAULT;
                    end else begin
                        root_level_q <= 1'b0;
                        paddr_q <= {pte_q[31:10], vaddr_q[21:12], 2'b00};
                        state <= READ_PTE;
                    end
                end

                ACCESS: begin
                    if (wb_err_i) begin
                        state <= ACCESS_FAULT;
                    end else if (wb_ack_i) begin
                        rdata_o <= wb_dat_i;
                        state <= DONE;
                    end
                end

                DONE, PAGE_FAULT, ACCESS_FAULT: if (cpu_step_i) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
