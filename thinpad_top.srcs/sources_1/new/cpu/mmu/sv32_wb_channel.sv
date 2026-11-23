`timescale 1ns/1ps

// One outstanding CPU request. Walks use this channel's physical Wishbone
// port, and CHECK_PTE releases the port between consecutive transactions.
module sv32_wb_channel #(
    parameter bit INSTRUCTION = 1'b0
) (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [31:0] satp_i,
    input  wire [1:0]  priv_i,  // effective privilege for this access
    input  wire        sum_i,
    input  wire        mxr_i,

    input  wire        req_i,
    input  wire [31:0] vaddr_i,
    input  wire        we_i,
    input  wire [3:0]  sel_i,
    input  wire [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output wire        ready_o,
    output wire        page_fault_o,
    output wire        access_fault_o,
    input  wire        cpu_step_i,

    output wire        wb_req_o,  // classic cycle, drives both CYC and STB
    output wire [31:0] wb_adr_o,
    output wire        wb_we_o,
    output wire [3:0]  wb_sel_o,
    output wire [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    input  wire        wb_err_i
);
    typedef enum logic [2:0] {
        IDLE, READ_PTE, CHECK_PTE, ACCESS, DONE, PAGE_FAULT, ACCESS_FAULT
    } state_t;
    state_t state;

    logic [31:0] vaddr_q, wdata_q, pte_q;
    logic [3:0] sel_q;
    logic we_q, user_q, sum_q, mxr_q, root_level_q;
    logic [33:0] paddr_q;

    wire pte_v = pte_q[0];
    wire pte_r = pte_q[1];
    wire pte_w = pte_q[2];
    wire pte_x = pte_q[3];
    wire pte_u = pte_q[4];
    wire leaf = pte_r || pte_x;
    // SUM permits S-mode data accesses to U pages. S-mode fetches from U
    // pages always fault. MXR applies only to loads.
    wire privilege_ok = user_q ? pte_u : (!pte_u || (sum_q && !INSTRUCTION));
    wire access_ok = INSTRUCTION ? pte_x :
                     we_q ? pte_w : (pte_r || (mxr_q && pte_x));
    wire misaligned_superpage = root_level_q && (pte_q[19:10] != 10'b0);

    assign wb_req_o = (state == READ_PTE) || (state == ACCESS);
    assign wb_adr_o = paddr_q[31:0];  // ThinPAD exposes 32 of Sv32's 34 PA bits
    assign wb_we_o  = (state == ACCESS) && we_q;
    assign wb_sel_o = (state == ACCESS) ? sel_q : 4'b1111;
    assign wb_dat_o = wdata_q;

    assign page_fault_o   = (state == PAGE_FAULT);
    assign access_fault_o = (state == ACCESS_FAULT);
    assign ready_o = !req_i || (state == DONE) || page_fault_o || access_fault_o;

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

                // The course omits A/D updates and ignores G and RSW.
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
                        state <= PAGE_FAULT;  // exhausted levels or reserved non-leaf U
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
