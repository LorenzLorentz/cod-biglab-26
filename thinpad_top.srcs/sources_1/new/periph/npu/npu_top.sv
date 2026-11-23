// npu_top.sv - NPU 顶层
//
// 其功能如下：
// 1. 例化 npu_wb（Wishbone Slave 封装）与 npu_core（计算核心）。
// 2. 以 Wishbone 从机形式挂到 CPU 总线上，地址范围 0x2000_0000（掩码 0xFFFF_0000）。

module npu_top #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter PE_N       = 4,    // 脉动阵列大小
    parameter L0A_DEPTH  = 64,
    parameter L0B_DEPTH  = 4,
    parameter L0C_DEPTH  = 64,
    localparam L0A_AW = $clog2(L0A_DEPTH),
    localparam L0B_AW = $clog2(L0B_DEPTH),
    localparam L0C_AW = $clog2(L0C_DEPTH),
    localparam M_MAX  = (L0A_DEPTH < L0C_DEPTH) ? L0A_DEPTH : L0C_DEPTH,
    localparam MM1_W  = $clog2(M_MAX)    // 行数 M-1 位宽
) (
    input  wire [ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [DATA_WIDTH-1:0] wb_dat_i,
    output wire [DATA_WIDTH-1:0] wb_dat_o,
    input  wire                  wb_we_i,
    input  wire [DATA_WIDTH/8-1:0] wb_sel_i,
    input  wire                  wb_stb_i,
    output wire                  wb_ack_o,
    input  wire                  wb_cyc_i,
    output wire                  wb_err_o,
    output wire                  wb_rty_o,

    input  wire                  clk_i,
    input  wire                  rst_i
);

  // npu_wb <-> npu_core 连线
  wire              ldtile_valid, tmul_valid, tmul_acc;
  wire              core_busy, core_done, core_cr_ready;
  wire              aw_valid, bw_valid, cr_valid;
  wire [L0B_AW-1:0] ldtile_base;
  wire [L0A_AW-1:0] tmul_a_base;
  wire [MM1_W-1:0]  tmul_m_m1;
  wire [L0C_AW-1:0] tmul_c_base;
  wire [L0A_AW-1:0] aw_addr;
  wire [L0B_AW-1:0] bw_addr;
  wire [L0C_AW-1:0] cr_addr;                 // L0C 字地址
  wire [PE_N*8-1:0] aw_data, bw_data;   // A/B 一行 PE_N 个 int8
  wire [PE_N*32-1:0] cr_data;           // L0C 完整一行（PE_N 个 int32）

  npu_wb #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .PE_N      (PE_N),
      .L0A_DEPTH (L0A_DEPTH),
      .L0B_DEPTH (L0B_DEPTH),
      .L0C_DEPTH (L0C_DEPTH)
  ) u_npu_wb (
      .clk_i     (clk_i),
      .rst_i     (rst_i),

      .wb_adr_i  (wb_adr_i),
      .wb_dat_i  (wb_dat_i),
      .wb_dat_o  (wb_dat_o),
      .wb_we_i   (wb_we_i),
      .wb_sel_i  (wb_sel_i),
      .wb_stb_i  (wb_stb_i),
      .wb_ack_o  (wb_ack_o),
      .wb_cyc_i  (wb_cyc_i),
      .wb_err_o  (wb_err_o),
      .wb_rty_o  (wb_rty_o),

      .ldtile_valid(ldtile_valid),
      .ldtile_base (ldtile_base),
      .tmul_valid   (tmul_valid),
      .tmul_a_base  (tmul_a_base),
      .tmul_m_m1    (tmul_m_m1),
      .tmul_c_base  (tmul_c_base),
      .tmul_acc     (tmul_acc),
      .core_busy   (core_busy),
      .core_done   (core_done),
      .core_cr_ready   (core_cr_ready),

      .aw_valid  (aw_valid),
      .aw_addr   (aw_addr),
      .aw_data   (aw_data),
      .bw_valid  (bw_valid),
      .bw_addr   (bw_addr),
      .bw_data   (bw_data),
      .cr_valid  (cr_valid),
      .cr_addr   (cr_addr),
      .cr_data   (cr_data)
  );

  npu_core #(
      .PE_N     (PE_N),
      .L0A_DEPTH(L0A_DEPTH),
      .L0B_DEPTH(L0B_DEPTH),
      .L0C_DEPTH(L0C_DEPTH)
  ) u_npu_core (
      .clk       (clk_i),
      .rst       (rst_i),

      .ldtile_valid(ldtile_valid),
      .ldtile_base (ldtile_base),
      .tmul_valid   (tmul_valid),
      .tmul_a_base  (tmul_a_base),
      .tmul_m_m1    (tmul_m_m1),
      .tmul_c_base  (tmul_c_base),
      .tmul_acc     (tmul_acc),
      .cmd_ready   (),
      .busy        (core_busy),
      .done        (core_done),
      .cr_ready    (core_cr_ready),

      .aw_valid  (aw_valid),
      .aw_addr   (aw_addr),
      .aw_data   (aw_data),
      .bw_valid  (bw_valid),
      .bw_addr   (bw_addr),
      .bw_data   (bw_data),
      .cr_valid  (cr_valid),
      .cr_addr   (cr_addr),
      .cr_data   (cr_data)
  );

endmodule
