module wb_master (
    input logic clk_i,
    input logic rst_i,

    // satp 和特权级
    input logic [31:0] satp_i,
    input logic [1:0] inst_priv_i,
    input logic [1:0] mem_priv_i,
    input logic sum_i,
    input logic mxr_i,

    // 指令总线
    input logic inst_req_i,
    input logic [31:0] inst_addr_i,
    output logic [31:0] inst_rdata_o,
    output logic inst_ready_o,
    output logic inst_page_fault_o,
    output logic inst_access_fault_o,

    // 数据总线
    input logic mem_req_i,
    input logic mem_we_i,
    input logic [3:0] mem_sel_i,
    input logic [31:0] mem_addr_i,
    input logic [31:0] mem_wdata_i,
    output logic [31:0] mem_rdata_o,
    output logic mem_ready_o,
    output logic mem_page_fault_o,
    output logic mem_access_fault_o,

    // wb
    output logic wb_cyc_o,
    output logic wb_stb_o,
    input logic wb_ack_i,
    input logic wb_err_i,
    output logic [31:0] wb_adr_o,
    output logic [31:0] wb_dat_o,
    input logic [31:0] wb_dat_i,
    output logic [3:0] wb_sel_o,
    output logic wb_we_o
);
    // 内部状态
    logic cpu_step = inst_ready_o && mem_ready_o;

    // 指令
    logic inst_bus_req;
    logic inst_bus_ack;
    logic inst_bus_err;
    logic [31:0] inst_bus_addr;
    logic [31:0] inst_bus_rdata;

    // 内存
    logic mem_bus_req;
    logic mem_bus_ack;
    logic mem_bus_err;
    logic mem_bus_we;
    logic [31:0] mem_bus_addr;
    logic [31:0] mem_bus_wdata;
    logic [31:0] mem_bus_rdata;
    logic [3:0] mem_bus_sel;

    sv32_wb_channel #(.INSTRUCTION(1'b1)) u_inst_channel (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .satp_i(satp_i),
        .priv_i(inst_priv_i),
        .sum_i(sum_i),
        .mxr_i(mxr_i),
        .req_i(inst_req_i),
        .vaddr_i(inst_addr_i),
        .we_i(1'b0),
        .sel_i(4'b1111),
        .wdata_i(32'b0),
        .rdata_o(inst_rdata_o),
        .ready_o(inst_ready_o),
        .page_fault_o(inst_page_fault_o),
        .access_fault_o(inst_access_fault_o),
        .cpu_step_i(cpu_step),
        .wb_req_o(inst_bus_req),
        .wb_adr_o(inst_bus_addr),
        .wb_we_o(),
        .wb_sel_o(),
        .wb_dat_o(),
        .wb_dat_i(inst_bus_rdata),
        .wb_ack_i(inst_bus_ack),
        .wb_err_i(inst_bus_err)
    );

    sv32_wb_channel u_mem_channel (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .satp_i(satp_i),
        .priv_i(mem_priv_i),
        .sum_i(sum_i),
        .mxr_i(mxr_i),
        .req_i(mem_req_i),
        .vaddr_i(mem_addr_i),
        .we_i(mem_we_i),
        .sel_i(mem_sel_i),
        .wdata_i(mem_wdata_i),
        .rdata_o(mem_rdata_o),
        .ready_o(mem_ready_o),
        .page_fault_o(mem_page_fault_o),
        .access_fault_o(mem_access_fault_o),
        .cpu_step_i(cpu_step),
        .wb_req_o(mem_bus_req),
        .wb_adr_o(mem_bus_addr),
        .wb_we_o(mem_bus_we),
        .wb_sel_o(mem_bus_sel),
        .wb_dat_o(mem_bus_wdata),
        .wb_dat_i(mem_bus_rdata),
        .wb_ack_i(mem_bus_ack),
        .wb_err_i(mem_bus_err)
    );

    // 仲裁器
    wb_arbiter_2 #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32),
        .SELECT_WIDTH(4),
        .ARB_TYPE_ROUND_ROBIN(1), // 轮询
        .ARB_LSB_HIGH_PRIORITY(1)
    ) u_wb_arbiter_2 (
        .clk(clk_i),
        .rst(rst_i),

        // wm0; inst
        .wbm0_adr_i(inst_bus_addr),
        .wbm0_dat_i(32'b0),
        .wbm0_dat_o(inst_bus_rdata),
        .wbm0_we_i(1'b0),
        .wbm0_sel_i(4'b1111),
        .wbm0_stb_i(inst_bus_req),
        .wbm0_ack_o(inst_bus_ack),
        .wbm0_err_o(inst_bus_err),
        .wbm0_rty_o(),
        .wbm0_cyc_i(inst_bus_req),

        // wm1; mem
        .wbm1_adr_i(mem_bus_addr),
        .wbm1_dat_i(mem_bus_wdata),
        .wbm1_dat_o(mem_bus_rdata),
        .wbm1_we_i(mem_bus_we),
        .wbm1_sel_i(mem_bus_sel),
        .wbm1_stb_i(mem_bus_req),
        .wbm1_ack_o(mem_bus_ack),
        .wbm1_err_o(mem_bus_err),
        .wbm1_rty_o(),
        .wbm1_cyc_i(mem_bus_req),

        // ws
        .wbs_adr_o(wb_adr_o),
        .wbs_dat_i(wb_dat_i),
        .wbs_dat_o(wb_dat_o),
        .wbs_we_o(wb_we_o),
        .wbs_sel_o(wb_sel_o),
        .wbs_stb_o(wb_stb_o),
        .wbs_ack_i(wb_ack_i),
        .wbs_err_i(wb_err_i),
        .wbs_rty_i(1'b0),
        .wbs_cyc_o(wb_cyc_o)
    );
endmodule
