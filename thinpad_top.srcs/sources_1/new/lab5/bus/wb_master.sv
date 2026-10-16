module wb_master (
    input logic clk_i,
    input logic rst_i,

    // 指令总线
    input logic inst_req_i,
    input logic [31:0] inst_addr_i,
    output logic [31:0] inst_rdata_o,
    output logic inst_ready_o,

    // 数据总线
    input logic data_req_i,
    input logic data_we_i,
    input logic [3:0] data_sel_i,
    input logic [31:0] data_addr_i,
    input logic [31:0] data_wdata_i,
    output logic [31:0] data_rdata_o,
    output logic data_ready_o,

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
endmodule
