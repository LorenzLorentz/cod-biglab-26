// npu_wb.sv - NPU 的 Wishbone 从机封装
//
// 其功能如下：
// 1. 把 CPU 对 0x2000_0000 的 Wishbone 访问翻译成指令与 L0 读写：
//    写 CMD 寄存器触发 LDTILE / TMUL；写 A_BASE / B_BASE / C_BASE / m_m1
//    配置指令参数；写 L0A / L0B 数据端口填充暂存；读 L0C 取回结果。
// 2. 寄存器映射（基地址 0x2000_0000，掩码 0xFFFF_0000）：
//    0x00 CMD       W  [0] LDTILE；[1] TMUL；[2] acc
//    0x04 STATUS    R  [0] busy；[1] done（W1C）
//    0x08 A_BASE    W  TMUL 的 A 基址
//    0x0C B_BASE    W  LDTILE 的 B 基址
//    0x10 C_BASE    W  TMUL 的 C 基址
//    0x14 M_M1      W  TMUL 的 A/C 行数 M-1（0..M_MAX-1 -> M=1..M_MAX）
// 3. L0 地址空间（各段独立固定基址，容量参数化）：
//    0x100..0x1FF   L0A：64 x 4 x int8
//    0x200..0x20F   L0B：4 x 4 x int8
//    0x300..0x6FF   L0C：64 x 4 x int32

module npu_wb #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter PE_N       = 4,    // 脉动阵列大小（与 npu_core 一致）
    parameter L0A_DEPTH  = 64,
    parameter L0B_DEPTH  = 4,
    parameter L0C_DEPTH  = 64,
    localparam L0A_DW = PE_N * 8,     // L0A 字宽（A 一行 PE_N 个 int8）
    localparam L0B_DW = PE_N * 8,     // L0B 字宽（B 一行 PE_N 个 int8）
    localparam L0C_DW = PE_N * 32,    // L0C 字宽（C 一行 PE_N 个 int32）
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
    input  wire                  rst_i,

    // 到 npu_core 的接口
    output wire                  ldtile_valid,
    output wire [L0B_AW-1:0]     ldtile_base,
    output wire                  tmul_valid,
    output wire [L0A_AW-1:0]     tmul_a_base,
    output wire [MM1_W-1:0]      tmul_m_m1,
    output wire [L0C_AW-1:0]     tmul_c_base,
    output wire                  tmul_acc,
    input  wire                  core_busy,
    input  wire                  core_done,
    input  wire                  core_cr_ready,      // L0C 读端口 ready（高=可读；acc 读改写时低）

    output wire                  aw_valid,
    output wire [L0A_AW-1:0]     aw_addr,
    output wire [L0A_DW-1:0]     aw_data,
    output wire                  bw_valid,
    output wire [L0B_AW-1:0]     bw_addr,
    output wire [L0B_DW-1:0]     bw_data,
    output wire                  cr_valid,
    output wire [L0C_AW-1:0]     cr_addr,        // L0C 字地址（外部换算，lane 选择在 wb 侧）
    input  wire [L0C_DW-1:0]     cr_data         // L0C 完整一行（PE_N 个 int32）
);

  // L0 地址空间：各段独立固定基址，范围由容量参数展开
  localparam [15:0] L0A_BASE = 16'h0100;
  localparam [15:0] L0B_BASE = 16'h0200;
  localparam [15:0] L0C_BASE = 16'h0300;
  localparam [15:0] L0A_END  = L0A_BASE + L0A_DEPTH * PE_N;
  localparam [15:0] L0B_END  = L0B_BASE + L0B_DEPTH * PE_N;
  localparam [15:0] L0C_END  = L0C_BASE + L0C_DEPTH * PE_N * 4;

  // ============ Wishbone 握手 ============
  reg  stb_prev;
  wire req = wb_cyc_i & wb_stb_i & ~stb_prev;
  always_ff @(posedge clk_i) begin
    if (rst_i) stb_prev <= 1'b0;
    else       stb_prev <= wb_stb_i;
  end

  // 指令参数寄存器
  reg [L0A_AW-1:0] a_base;
  reg [L0B_AW-1:0] b_base;
  reg [L0C_AW-1:0] c_base;
  reg [MM1_W-1:0]  m_m1;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      a_base <= '0; b_base <= '0; c_base <= '0; m_m1 <= '0;
    end else if (req && wb_we_i) begin
      case (wb_adr_i[15:0])
        16'h0008: if (wb_sel_i[0]) a_base <= wb_dat_i[L0A_AW-1:0];
        16'h000C: if (wb_sel_i[0]) b_base <= wb_dat_i[L0B_AW-1:0];
        16'h0010: if (wb_sel_i[0]) c_base <= wb_dat_i[L0C_AW-1:0];
        16'h0014: if (wb_sel_i[0]) m_m1 <= wb_dat_i[MM1_W-1:0];
        default: ;
      endcase
    end
  end

  // done 状态寄存器：core 完成时置位，软件 W1C 清除
  reg status_done;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      status_done <= 1'b0;
    end else begin
      if (core_done) status_done <= 1'b1;
      if (req && wb_we_i) begin
        case (wb_adr_i[15:0])
          16'h0004: if (wb_dat_i[1]) status_done <= 1'b0;   // STATUS W1C
          default: ;
        endcase
      end
    end
  end

  // ============ 指令译码 ============
  assign ldtile_valid = req & wb_we_i & (wb_adr_i[15:0] == 16'h0000) & wb_dat_i[0];
  assign tmul_valid    = req & wb_we_i & (wb_adr_i[15:0] == 16'h0000) & wb_dat_i[1];
  assign tmul_acc      = req & wb_we_i & (wb_adr_i[15:0] == 16'h0000) & wb_dat_i[2];
  assign ldtile_base  = b_base;
  assign tmul_a_base   = a_base;
  assign tmul_m_m1     = m_m1;
  assign tmul_c_base   = c_base;

  // L0 地址译码
  wire [15:0] l0a_off = wb_adr_i[15:0] - L0A_BASE;
  wire [15:0] l0b_off = wb_adr_i[15:0] - L0B_BASE;
  wire [15:0] l0c_off = wb_adr_i[15:0] - L0C_BASE;
  wire in_l0a = (wb_adr_i[15:0] >= L0A_BASE) & (wb_adr_i[15:0] < L0A_END);
  wire in_l0b = (wb_adr_i[15:0] >= L0B_BASE) & (wb_adr_i[15:0] < L0B_END);
  wire in_l0c = (wb_adr_i[15:0] >= L0C_BASE) & (wb_adr_i[15:0] < L0C_END);

  // L0A/L0B 写入
  // 注：此处的实现假设了 PE_N 等于 4；
  // 当 PE_N 大于 4 时，一次只能写入 A/B 一行的一部分，这里的逻辑需要修改
  assign aw_valid = req & wb_we_i & in_l0a;
  assign aw_addr  = l0a_off[L0A_AW+1:2];
  assign aw_data  = wb_dat_i;
  assign bw_valid = req & wb_we_i & in_l0b;
  assign bw_addr  = l0b_off[L0B_AW+1:2];
  assign bw_data  = wb_dat_i;

  // ============ L0C 读仲裁 ============
  // CPU 读 L0C 时，若 core 正在 acc 读改写（占用读端口），请求挂起；
  // core 空闲拍才发读，wishbone 的 ACK 同步延迟（CPU 忙等）。
  // L0C 每字 = PE_N*4 字节：字地址 = 字节偏移 >> (2+clog2(PE_N))，lane = 偏移的低位
  wire [L0C_AW-1:0] l0c_word_off = l0c_off[$clog2(PE_N)+L0C_AW+1 : $clog2(PE_N)+2];
  wire [$clog2(PE_N)-1:0] l0c_lane = l0c_off[$clog2(PE_N)+1 : 2];

  reg l0c_rd_pend;
  reg [L0C_AW-1:0] l0c_rd_addr;               // 挂起时的字地址
  reg [$clog2(PE_N)-1:0] l0c_rd_lane;         // 挂起/发读时的 lane（读数据取 32 位用）

  // ready-valid 协议：cr_valid 独立（请求即置位并保持，直到握手），不依赖 cr_ready；
  // 握手 = cr_valid & cr_ready（core 空闲）才真正发读。未握手期间 core 的
  // acc 读改写照常使用读端口（core 内仲裁，见 npu_core）。
  wire l0c_rd_req = req & ~wb_we_i & in_l0c;
  assign cr_valid = l0c_rd_pend || l0c_rd_req;   // valid 独立（请求即有效，挂起时保持）
  wire l0c_rd_hs  = cr_valid && core_cr_ready;   // ready-valid 握手（同时为 1 才生效）
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      l0c_rd_pend <= 1'b0;
      l0c_rd_addr <= '0;
      l0c_rd_lane <= '0;
    end else if (l0c_rd_req) begin
      l0c_rd_addr <= l0c_word_off;            // 锁存字地址（挂起或握手都用它）
      l0c_rd_lane <= l0c_lane;                // 锁存 lane（读数据取 32 位）
      if (!core_cr_ready) l0c_rd_pend <= 1'b1;   // 未握手：挂起（valid 保持）
    end else if (l0c_rd_hs) begin
      l0c_rd_pend <= 1'b0;                    // 握手完成
    end
  end

  assign cr_addr  = l0c_rd_pend ? l0c_rd_addr : l0c_word_off;

  // ============ ACK ============
  // 读执行拍：STATUS 读 = req；L0C 读 = l0c_rd_hs（可能因仲裁挂起而延迟）
  wire is_status_rd = req & ~wb_we_i & (wb_adr_i[15:0] == 16'h0004);
  wire rd_exec = wb_we_i ? 1'b0 : (is_status_rd ? req : l0c_rd_hs);   // L0C 读 = 握手拍

  reg rd_exec_reg;
  always_ff @(posedge clk_i) begin
    if (rst_i) rd_exec_reg <= 1'b0;
    else       rd_exec_reg <= rd_exec;
  end

  reg ack_reg;
  always_ff @(posedge clk_i) begin
    if (rst_i) ack_reg <= 1'b0;
    else if (wb_we_i) ack_reg <= wb_cyc_i & wb_stb_i;   // 写事务寄存 1 拍
    else ack_reg <= rd_exec_reg;                         // 读事务（L0C 读含仲裁延迟）
  end
  assign wb_ack_o = ack_reg;
  assign wb_err_o = 1'b0;
  assign wb_rty_o = 1'b0;

  // ============ 读数据 ============
  // L0C 读结果取 32 位 lane
  wire [L0C_DW-1:0] cr_lane_shift = cr_data >> ({l0c_rd_lane,5'b0});

  reg [DATA_WIDTH-1:0] dat_reg;
  always_ff @(posedge clk_i) begin
    if (rd_exec_reg) begin
      if (wb_adr_i[15:0] == 16'h0004)
        dat_reg <= {30'b0, status_done, core_busy};
      else
        dat_reg <= cr_lane_shift[31:0];   // L0C 读结果（发读后 1 拍有效）
    end
  end
  assign wb_dat_o = dat_reg;

endmodule
