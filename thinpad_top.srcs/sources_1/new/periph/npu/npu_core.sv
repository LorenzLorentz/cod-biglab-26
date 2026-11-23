// npu_core.sv - NPU 计算核心
//
// 其功能如下：
// 1. 包含 L0A/L0B/L0C 三块片上存储（BlockRAM）与一个 NxN 脉动阵列，
//    负责执行 LDTILE 与 TMUL 两条指令。
// 2. LDTILE 指令：把 L0B 中的一个 NxN B 子块载入脉动阵列。
//    B 矩阵的 int8 元素从阵列顶部从最后一行开始到第一行结束的顺序逐拍注入一行，
//    注入的每一行从顶部向下逐行流动，第 N 拍时，所有 PE 同时收到自己的 B 元素，
//    计算期间 b_ld_en 为 0，b_reg 保持不变（即 B 驻留在 PE 当中）。
// 3. TMUL 指令：C(MxN) += A(MxN) x B(NxN)，M 由指令参数动态指定。
//    执行期间，A 矩阵的 int8 元素按行从 L0A 读出，经过一系列打拍寄存器
//    （对第 j 行的元素打 j 拍）后从阵列左边缘斜入（第 j 行在第 i+j 拍收到 A[i][j]）；
//    int32 部分和从阵列顶部注入（恒为零），沿列向下累加 b_reg * a_in；
//    底部每拍斜出一个对角（C[i][j] 在拍 i+j+N 从列 j 出来），经过一系列打拍寄存器
//    （对列 j 打 N-1-j 拍）对齐后，每拍把对齐好的一行 C（N 个 int32）累加到 L0C；
//    为了实现累加，先读 L0C 旧值，按列加新值后再写回。
//    从发出指令到完成共 M+2N+1 拍（先花费 1 拍取 A 的第 0 行并清空斜入寄存器，
//    实际矩阵运算部分即 TS_MUL 状态耗费 M+2N-1 拍，外加状态转移 1 拍）。
// 4. L0C 读端口仲裁（ready-valid）：L0C 累加逻辑需要占用读端口时 cr_ready 拉低，
//    CPU 读 L0C 挂起等待（wishbone 握手），见 npu_wb.sv。

module npu_core #(
    parameter PE_N      = 4,    // 脉动阵列大小
    parameter L0A_DEPTH = 64,   // L0A 深度
    parameter L0B_DEPTH = 4,    // L0B 深度
    parameter L0C_DEPTH = 64,   // L0C 深度
    localparam L0A_DW = PE_N * 8,     // L0A 宽度（A 一行 PE_N 个 int8）
    localparam L0B_DW = PE_N * 8,     // L0B 宽度（B 一行 PE_N 个 int8）
    localparam L0C_DW = PE_N * 32,    // L0C 宽度（C 一行 PE_N 个 int32）
    localparam L0A_AW = $clog2(L0A_DEPTH),
    localparam L0B_AW = $clog2(L0B_DEPTH),
    localparam L0C_AW = $clog2(L0C_DEPTH),
    localparam M_MAX  = (L0A_DEPTH < L0C_DEPTH) ? L0A_DEPTH : L0C_DEPTH,
    localparam MM1_W  = $clog2(M_MAX)    // 行数 M-1 的位宽（一次 TMUL 最多 L0A/L0C 深度较小者）
) (
    input  wire                   clk,
    input  wire                   rst,

    // 指令接口
    input  wire                   ldtile_valid,   // LDTILE：B 子块载入阵列
    input  wire [L0B_AW-1:0]      ldtile_base,    // B 子块基址（L0B 字地址）

    input  wire                   tmul_valid,     // TMUL：C += A x B（B 已驻留阵列，无需 B 基址）
    input  wire [L0A_AW-1:0]      tmul_a_base,    // A 子块基址
    input  wire [MM1_W-1:0]       tmul_m_m1,      // 行数 M-1（0..M_MAX-1 -> M=1..M_MAX）
    input  wire [L0C_AW-1:0]      tmul_c_base,    // C 子块基址
    input  wire                   tmul_acc,       // 累加标志

    output wire                   cmd_ready,      // 可以处理新的 LDTILE/TMUL 指令
    output wire                   busy,           // 正在执行指令
    output wire                   done,           // 上条指令已执行完成

    // L0A 写（软件），一次写入 A 的一行（PE_N 个 int8）
    input  wire                   aw_valid,
    input  wire [L0A_AW-1:0]      aw_addr,
    input  wire [L0A_DW-1:0]      aw_data,
    // L0B 写（软件），一次写入 B 的一行（PE_N 个 int8）
    input  wire                   bw_valid,
    input  wire [L0B_AW-1:0]      bw_addr,
    input  wire [L0B_DW-1:0]      bw_data,
    // L0C 读（软件）：一次读取 C 的一行（PE_N 个 int32）
    input  wire                   cr_valid,
    input  wire [L0C_AW-1:0]      cr_addr,
    output wire [L0C_DW-1:0]      cr_data,
    output wire                   cr_ready        // L0C 读端口 ready（高=可接受 CPU 读；累加时拉低）
);

  // ============ 脉动阵列 ============
  wire [PE_N*8-1:0]   a_left;       // A 左边缘（斜入）
  wire [PE_N*32-1:0]  sum_bottom;   // 底部部分和（C 斜出）
  wire                b_ld_en;      // B 写入使能
  wire [PE_N*8-1:0]   b_ld_data;    // 逆序从阵列顶部注入一行 B

  systolic_array #(
      .PE_N  (PE_N),
      .A_DW  (8),
      .C_DW  (32)
  ) u_array (
      .clk       (clk),
      .rst       (rst),
      .b_ld_en   (b_ld_en),
      .b_ld_data (b_ld_data),
      .a_left    (a_left),
      .sum_bottom(sum_bottom)
  );


  // ============ L0A/L0B/L0C RAM ============
  wire [L0A_DW-1:0] l0a_rdata;          // L0A 读数据（A 的一行，PE_N 个 int8）
  wire [L0B_DW-1:0] l0b_rdata;          // L0B 读数据（B 的一行，PE_N 个 int8）
  wire [L0C_DW-1:0] l0c_rdata;          // L0C 读数据（C 的一行，PE_N 个 int32）
  wire          l0a_ren, l0b_ren, l0c_ren;
  wire [L0A_AW-1:0] l0a_raddr;
  wire [L0B_AW-1:0] l0b_raddr;
  wire [L0C_AW-1:0] l0c_raddr, l0c_waddr;
  wire          l0c_wen;
  wire [L0C_DW-1:0] l0c_wdata;

  blockram_1r1w #(.DEPTH(L0A_DEPTH), .DATA_W(L0A_DW)) u_l0a (
      .clk(clk), .rst(rst),
      .wea(aw_valid), .addra(aw_addr), .dina(aw_data),
      .enb(l0a_ren), .addrb(l0a_raddr), .doutb(l0a_rdata)
  );

  blockram_1r1w #(.DEPTH(L0B_DEPTH), .DATA_W(L0B_DW)) u_l0b (
      .clk(clk), .rst(rst),
      .wea(bw_valid), .addra(bw_addr), .dina(bw_data),
      .enb(l0b_ren), .addrb(l0b_raddr), .doutb(l0b_rdata)
  );

  blockram_1r1w #(.DEPTH(L0C_DEPTH), .DATA_W(L0C_DW)) u_l0c (
      .clk(clk), .rst(rst),
      .wea(l0c_wen), .addra(l0c_waddr), .dina(l0c_wdata),
      .enb(l0c_ren), .addrb(l0c_raddr), .doutb(l0c_rdata)
  );

  // ============ LDTILE：B 顶部逐行注入 ============
  // B 从阵列顶部以从最后一行开始到第一行结束的顺序，逐拍注入一行，逐行向下流动（每级 1 拍延迟）；
  // 注入 N 次后，所有 PE 同时收到自己的 B 元素。

  // LDTILE 状态机
  // 只有 LOAD 一个工作状态：注入 PE_N 拍后回到 IDLE。
  localparam [1:0] LS_IDLE = 2'd0, LS_LOAD = 2'd1;
  reg [1:0] ldtile_state;
  reg [1:0] ldtile_state_next;      // 组合次态
  always_ff @(posedge clk) begin
    if (rst) ldtile_state <= LS_IDLE;
    else     ldtile_state <= ldtile_state_next;
  end

  // LDTILE 拍号（范围是 0..PE_N）：LS_IDLE 接受指令时清 0，LS_LOAD 内每拍 +1
  localparam RCNT_W = $clog2(PE_N + 1);                         // LDTILE 拍号位宽
  reg [RCNT_W-1:0]       r_cnt;                                 // LDTILE 拍号
  always_ff @(posedge clk) begin
    if (rst) r_cnt <= '0;
    else if (ldtile_state == LS_IDLE && ldtile_valid) r_cnt <= '0;
    else if (ldtile_state == LS_LOAD)                 r_cnt <= r_cnt + 1;
  end

  // 次态：LDTILE 注入 PE_N 拍后完成（LS_LOAD 拍 0 发读、拍 1..PE_N 注入）
  localparam [RCNT_W-1:0] LDTILE_LAST = RCNT_W'(PE_N);          // LDTILE 注入末拍（r_cnt 同宽）
  always_comb begin
    ldtile_state_next = ldtile_state;
    case (ldtile_state)
      LS_IDLE: if (ldtile_valid) ldtile_state_next = LS_LOAD;
      LS_LOAD: if (r_cnt == LDTILE_LAST) ldtile_state_next = LS_IDLE;   // 注入 PE_N 拍（PE_N 行 B）
      default: ;
    endcase
  end

  // 逆序读通过递减计数器实现：LDTILE 开始时计算 B 子块末行地址 ldtile_base + PE_N - 1，
  // 装入 l0b_addr_reg 寄存器，之后每周期减一。
  localparam L0B_LAST = PE_N - 1;               // 子块末行偏移
  reg [L0B_AW-1:0] l0b_addr_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      l0b_addr_reg <= '0;
    end else if (ldtile_state == LS_IDLE && ldtile_valid) begin
      l0b_addr_reg <= ldtile_base + L0B_LAST[L0B_AW-1:0];   // 装入子块末行地址
    end else if (ldtile_state == LS_LOAD) begin
      l0b_addr_reg <= l0b_addr_reg - 1;           // 每周期减一（逆序）
    end
  end

  assign l0b_ren    = (ldtile_state == LS_LOAD) && (r_cnt < LDTILE_LAST);
  assign l0b_raddr  = l0b_addr_reg;
  // b_ld_en 在注入期（拍 1..PE_N）都为真：PE 每拍写入 b_in（向下流动），最后一拍锁存自己的 B
  assign b_ld_en    = (ldtile_state == LS_LOAD) && (r_cnt >= 1);
  assign b_ld_data  = l0b_rdata;                                // 顶部注入一行 B

  // ============ TMUL 状态机（矩阵计算） ============
  // PRE 1 拍（预取 A 第 0 行 + 清空斜入寄存器）-> MUL（M+2N-1 拍）-> IDLE。
  localparam [2:0] TS_IDLE = 3'd0, TS_PRE = 3'd1, TS_MUL = 3'd2;
  reg [2:0] tmul_state;
  reg [2:0] tmul_state_next;
  always_ff @(posedge clk) begin
    if (rst) tmul_state <= TS_IDLE;
    else     tmul_state <= tmul_state_next;
  end

  // 保存 TMUL 参数：A/C 基址、行数 M-1、累加标志
  reg [L0A_AW-1:0] a_base;
  reg [MM1_W-1:0]  m_m1;           // M-1, m1 代表 minus 1
  reg [L0C_AW-1:0] c_base;
  reg              acc;
  always_ff @(posedge clk) begin
    if (rst) begin
      a_base <= '0; m_m1 <= '0; c_base <= '0; acc <= 1'b0;
    end else if (tmul_state == TS_IDLE && tmul_valid) begin
      a_base <= tmul_a_base;
      m_m1   <= tmul_m_m1;
      c_base <= tmul_c_base;
      acc    <= tmul_acc;
    end
  end

  // TMUL 拍号（范围是 0..M+2N-2）：TS_IDLE 接受指令时清 0，TS_MUL 内每拍 +1
  localparam TCNT_W = $clog2(M_MAX + 2 * PE_N - 1);  // TMUL 拍号位宽（最多能数到 M_MAX+2N-2）
  reg [TCNT_W-1:0]       t_cnt;                                 // TMUL 拍号
  always_ff @(posedge clk) begin
    if (rst) t_cnt <= '0;
    else if (tmul_state == TS_IDLE && tmul_valid) t_cnt <= '0;
    else if (tmul_state == TS_MUL)                t_cnt <= t_cnt + 1;
  end

  // 次态：TMUL 在 t_cnt == m_m1+2*PE_N-1 时结束（最后一行 C 已写入，共 M+2*PE_N-1 拍）
  localparam [TCNT_W-1:0] TMUL_LAST = TCNT_W'(2 * PE_N - 1);  // 最后一行 C 写出的拍号偏移（m_m1 + 2*PE_N-1）
  always_comb begin
    tmul_state_next = tmul_state;
    case (tmul_state)
      TS_IDLE: if (tmul_valid) tmul_state_next = TS_PRE;
      TS_PRE:  tmul_state_next = TS_MUL;   // 1 拍预取（读第 0 行）后进入计算
      TS_MUL:  if (t_cnt == {{(TCNT_W-MM1_W){1'b0}}, m_m1} + TMUL_LAST) tmul_state_next = TS_IDLE;   // 最后一行 C 已写入
      default: ;
    endcase
  end

  // done：LDTILE 和 TMUL 的完成脉冲（1 拍）
  reg ldtile_done_reg;
  always_ff @(posedge clk) begin
    if (rst) ldtile_done_reg <= 1'b0;
    else     ldtile_done_reg <= (ldtile_state == LS_LOAD) && (ldtile_state_next == LS_IDLE);
  end
  reg tmul_done_reg;
  always_ff @(posedge clk) begin
    if (rst) tmul_done_reg <= 1'b0;
    else     tmul_done_reg <= (tmul_state == TS_MUL) && (tmul_state_next == TS_IDLE);
  end
  assign done = ldtile_done_reg | tmul_done_reg;

  // 目前的实现下，LDTILE 和 TMUL 指令是串行的（cmd_ready 需两个状态机都空闲）
  // 未来可改造为允许并行执行
  assign cmd_ready = (ldtile_state == LS_IDLE) && (tmul_state == TS_IDLE);
  assign busy = (ldtile_state == LS_LOAD) || (tmul_state != TS_IDLE);

  // ============ TMUL：A 斜入 ============
  // L0A 行优先，每拍读出 A 的一行；读出的 PE_N 个 int8 元素分别经过一个 shift_register
  // （对行 k 的元素打 k 拍，行 0 打 0 拍直通）后，从阵列左边缘斜入，行 j 在拍 i+j 收到 A[i][j]。
  // L0A 地址用寄存器保存：指令开始时装入 a_base，之后每拍加一。
  reg [L0A_AW-1:0] l0a_addr_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      l0a_addr_reg <= '0;
    end else if (tmul_state == TS_IDLE && tmul_valid) begin
      l0a_addr_reg <= tmul_a_base;                // 装入 A 行块基址
    end else if (tmul_state == TS_PRE || tmul_state == TS_MUL) begin
      l0a_addr_reg <= l0a_addr_reg + 1;           // 每拍加一，读下一行
    end
  end

  assign l0a_ren   = (tmul_state == TS_PRE) ||    // 预取拍读第 0 行
                     ((tmul_state == TS_MUL) && (t_cnt + 1 <= m_m1));
  assign l0a_raddr = l0a_addr_reg;

  // A 的 PE_N 路 8bit 各经一个 shift_register（对行 k 的元素打 k 拍，行 0 打 0 拍直通），
  // 打拍深度由 generate 按 PE_N 展开
  wire [PE_N*8-1:0] a_cols;
  genvar i;
  generate
    for (i = 0; i < PE_N; i++) begin : gen_a_shift
      shift_register #(.DATA_W(8), .DEPTH(i)) u_sr_a (
          .clk(clk), .rst(rst),
          .din(l0a_rdata[i*8 +: 8]), .dout(a_cols[i*8 +: 8]));
    end
  endgenerate

  // A 矩阵从脉动阵列左侧斜入，从第 0 拍到第 M+N-2（即 m_m1+1+N-2）拍
  localparam [TCNT_W-1:0] A_LAST    = TCNT_W'(PE_N - 1);  // 最后一个 A 元素进入的拍号偏移（m + PE_N-1）
  assign a_left = (tmul_state == TS_MUL && t_cnt <= {{(TCNT_W-MM1_W){1'b0}}, m_m1} + A_LAST)
      ? a_cols
      : '0;

  // ============ TMUL：C 斜出对齐 ============
  // 阵列底部每拍斜出一个对角（C[i][j] 在拍 i+j+PE_N 出列 j）；PE_N 列结果分别经过
  // 一个 shift_register（对列 j 打 PE_N-1-j 拍，列 PE_N-1 打 0 拍直通）对齐后，
  // 每拍得到一行 C（PE_N 个 int32），写入 L0C。
  wire [PE_N*32-1:0] c_cols;
  genvar j;
  generate
    for (j = 0; j < PE_N; j++) begin : gen_c_shift
      shift_register #(.DATA_W(32), .DEPTH(PE_N-1-j)) u_sr_c (
          .clk(clk), .rst(rst),
          .din(sum_bottom[j*32 +: 32]), .dout(c_cols[j*32 +: 32]));
    end
  endgenerate

  // ============ TMUL：L0C 写============
  // 对齐好的一行 C 写入 L0C：前一拍读 L0C 旧值，读取旧值后，按列加新值再写回。
  // 从第 N 拍到第 M+2N-2 拍：阵列输出 C 矩阵的时间范围。
  // 经过移位寄存器对齐后，实际写入是第 2N-1 拍到第 M+2N-2 拍，共 M 拍。
  // 因此读取旧值的时间是第 2N-2 拍到第 M+2N-3 拍，比对应的写入早一拍。
  localparam [TCNT_W-1:0] l0c_rdata_START = TCNT_W'(2 * PE_N - 2);  // L0C 读窗口起点（t_cnt 偏移）
  reg [L0C_AW-1:0] l0c_raddr_reg;
  reg [L0C_AW-1:0] l0c_waddr_reg;
  always_ff @(posedge clk) begin
    if (rst) begin
      l0c_raddr_reg <= '0; l0c_waddr_reg <= '0;
    end else if (tmul_state == TS_IDLE && tmul_valid) begin
      l0c_raddr_reg <= tmul_c_base;                // 装入 C 行块基址（行 0 地址）
    end else if ((tmul_state == TS_MUL) && (t_cnt >= l0c_rdata_START) && (t_cnt <= {{(TCNT_W-MM1_W){1'b0}}, m_m1} + l0c_rdata_START)) begin
      l0c_raddr_reg <= l0c_raddr_reg + 1;         // 每拍加 1（连续存放），下一行
      l0c_waddr_reg <= l0c_raddr_reg;             // 下一拍写地址 = 本拍读地址
    end
  end

  // L0C 读端口仲裁（ready-valid）：core 的 acc 读改写占用读端口（发读拍）时 cr_ready 拉低，
  // CPU 读 L0C 挂起等待；acc 读改写的发读拍提前一拍（raddr = 下一拍写地址）
  wire l0c_rdata_used = acc && (tmul_state == TS_MUL) && (t_cnt >= l0c_rdata_START) && (t_cnt <= {{(TCNT_W-MM1_W){1'b0}}, m_m1} + l0c_rdata_START);
  // ready-valid 握手： 只有 valid & ready 同时为 1（握手 cr_hs）才真正读 CPU 地址。
  // acc 读改写优先使用读端口，不因 CPU 请求而被打断。
  wire cr_hs = cr_valid && cr_ready;              // ready-valid 握手
  assign cr_ready  = !l0c_rdata_used;             // ready 只依赖端口空闲
  assign l0c_ren   = l0c_rdata_used | cr_hs;      // acc 读改写或握手拍才发读
  assign l0c_raddr = cr_hs ? cr_addr : l0c_raddr_reg;
  assign l0c_waddr = l0c_waddr_reg;

  localparam [TCNT_W-1:0] L0C_WR_START = TCNT_W'(2 * PE_N - 1);  // L0C 写窗口起点（t_cnt 偏移）
  assign l0c_wen   = (tmul_state == TS_MUL) && (t_cnt >= L0C_WR_START) && (t_cnt <= {{(TCNT_W-MM1_W){1'b0}}, m_m1} + L0C_WR_START);

  // 累加按 lane 独立相加
  genvar k;
  generate
    for (k = 0; k < PE_N; k++) begin : gen_l0c_lane
      assign l0c_wdata[k*32 +: 32] = acc
          ? (l0c_rdata[k*32 +: 32] + c_cols[k*32 +: 32])
          : c_cols[k*32 +: 32];
    end
  endgenerate

  // 软件读 L0C
  assign cr_data = l0c_rdata;
endmodule
