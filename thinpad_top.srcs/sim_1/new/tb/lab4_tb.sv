`timescale 1ns / 1ps
module lab4_tb;

  wire clk_50M, clk_11M0592;

  reg push_btn;   // BTN5 按钮开关，带消抖电路，按下时为 1
  reg reset_btn;  // BTN6 复位按钮，带消抖电路，按下时为 1

  reg [3:0] touch_btn; // BTN1~BTN4，按钮开关，按下时为 1
  reg [31:0] dip_sw;   // 32 位拨码开关，拨到“ON”时为 1

  wire [15:0] leds;  // 16 位 LED，输出时 1 点亮
  wire [7:0] dpy0;   // 数码管低位信号，包括小数点，输出 1 点亮
  wire [7:0] dpy1;   // 数码管高位信号，包括小数点，输出 1 点亮

  wire [31:0] base_ram_data;  // BaseRAM 数据，低 8 位与 CPLD 串口控制器共享
  wire [19:0] base_ram_addr;  // BaseRAM 地址
  wire[3:0] base_ram_be_n;    // BaseRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
  wire base_ram_ce_n;  // BaseRAM 片选，低有效
  wire base_ram_oe_n;  // BaseRAM 读使能，低有效
  wire base_ram_we_n;  // BaseRAM 写使能，低有效

  wire [31:0] ext_ram_data;  // ExtRAM 数据
  wire [19:0] ext_ram_addr;  // ExtRAM 地址
  wire[3:0] ext_ram_be_n;    // ExtRAM 字节使能，低有效。如果不使用字节使能，请保持为 0
  wire ext_ram_ce_n;  // ExtRAM 片选，低有效
  wire ext_ram_oe_n;  // ExtRAM 读使能，低有效
  wire ext_ram_we_n;  // ExtRAM 写使能，低有效

  wire txd;  // 直连串口发送端
  wire rxd;  // 直连串口接收端

  // CPLD 串口
  wire uart_rdn;  // 读串口信号，低有效
  wire uart_wrn;  // 写串口信号，低有效
  wire uart_dataready;  // 串口数据准备好
  wire uart_tbre;  // 发送数据标志
  wire uart_tsre;  // 数据发送完毕标志

  // Windows 需要注意路径分隔符的转义，例如 "D:\\foo\\bar.bin"
  parameter BASE_RAM_INIT_FILE = "/tmp/main.bin"; // BaseRAM 初始化文件，请修改为实际的绝对路径
  parameter EXT_RAM_INIT_FILE = "/tmp/eram.bin";  // ExtRAM 初始化文件，请修改为实际的绝对路径

  // 串口发送的 10 个随机字节（固定下来，含 0x00 / 0xff 两个边界值），以及 FPGA 回显的字节
  reg [7:0] sent[0:9] = '{8'h3a, 8'h00, 8'hff, 8'h5c, 8'h81, 8'h12, 8'he7, 8'h40, 8'h9d, 8'h7b};
  reg [7:0] echoed[$];
  always @(posedge uart.rxd_data_ready) echoed.push_back(uart.rxd_data);

  initial begin
    integer errors;
    reg [7:0] sram_byte;

    // 在这里可以自定义测试输入序列，例如：
    dip_sw = 32'h8000_1000;  // 起始地址 Addr：BaseRAM 的第 0x1000 字节
    touch_btn = 0;
    reset_btn = 0;
    push_btn = 0;

    #100;
    reset_btn = 1;
    #100;
    reset_btn = 0;

    // 等待复位结束，lab4_master 在复位结束时记下 dip_sw
    wait (dut.sys_rst == 1'b0);
    #2000;

    // 模拟 PC 通过串口，向 FPGA 依次发送 10 个字节
    for (integer i = 0; i < 10; i = i + 1) begin
      uart.pc_send_byte(sent[i]);
    end

    // PC 接收到数据后，会在仿真窗口中打印出数据；等 10 个回显都收到
    wait (echoed.size() == 10);
    #2000;

    // 比较回显和 SRAM 中的数据：第 i 个字节应在 Addr + 4i 的最低 8 位
    errors = 0;
    for (integer i = 0; i < 10; i = i + 1) begin
      sram_byte = base1.mem_array0[dip_sw[21:2] + i];
      $display("byte %0d: sent %02x, echoed %02x, SRAM[%08h] = %02x", i, sent[i], echoed[i], dip_sw + 4 * i,
               sram_byte);
      if (echoed[i] !== sent[i] || sram_byte !== sent[i]) errors = errors + 1;
    end
    if (errors == 0) $display("lab4_tb: PASS at %0d ns", $time);
    else $display("lab4_tb: FAIL, %0d errors", errors);
    $finish;
  end

  // 待测试用户设计
  lab4_top dut (
      .clk_50M(clk_50M),
      .clk_11M0592(clk_11M0592),
      .push_btn(push_btn),
      .reset_btn(reset_btn),
      .touch_btn(touch_btn),
      .dip_sw(dip_sw),
      .leds(leds),
      .dpy1(dpy1),
      .dpy0(dpy0),
      .txd(txd),
      .rxd(rxd),
      .uart_rdn(uart_rdn),
      .uart_wrn(uart_wrn),
      .uart_dataready(uart_dataready),
      .uart_tbre(uart_tbre),
      .uart_tsre(uart_tsre),
      .base_ram_data(base_ram_data),
      .base_ram_addr(base_ram_addr),
      .base_ram_ce_n(base_ram_ce_n),
      .base_ram_oe_n(base_ram_oe_n),
      .base_ram_we_n(base_ram_we_n),
      .base_ram_be_n(base_ram_be_n),
      .ext_ram_data(ext_ram_data),
      .ext_ram_addr(ext_ram_addr),
      .ext_ram_ce_n(ext_ram_ce_n),
      .ext_ram_oe_n(ext_ram_oe_n),
      .ext_ram_we_n(ext_ram_we_n),
      .ext_ram_be_n(ext_ram_be_n),
      .flash_d(),
      .flash_a(),
      .flash_rp_n(),
      .flash_vpen(),
      .flash_oe_n(),
      .flash_ce_n(),
      .flash_byte_n(),
      .flash_we_n()
  );

  // 时钟源
  clock osc (
      .clk_11M0592(clk_11M0592),
      .clk_50M    (clk_50M)
  );

  // CPLD 串口仿真模型
  cpld_model cpld (
      .clk_uart(clk_11M0592),
      .uart_rdn(uart_rdn),
      .uart_wrn(uart_wrn),
      .uart_dataready(uart_dataready),
      .uart_tbre(uart_tbre),
      .uart_tsre(uart_tsre),
      .data(base_ram_data[7:0])
  );
  // 直连串口仿真模型
  uart_model uart (
    .rxd (txd),
    .txd (rxd)
  );
  // BaseRAM 仿真模型
  sram_model base1 (
      .DataIO(base_ram_data[15:0]),
      .Address(base_ram_addr[19:0]),
      .OE_n(base_ram_oe_n),
      .CE_n(base_ram_ce_n),
      .WE_n(base_ram_we_n),
      .LB_n(base_ram_be_n[0]),
      .UB_n(base_ram_be_n[1])
  );
  sram_model base2 (
      .DataIO(base_ram_data[31:16]),
      .Address(base_ram_addr[19:0]),
      .OE_n(base_ram_oe_n),
      .CE_n(base_ram_ce_n),
      .WE_n(base_ram_we_n),
      .LB_n(base_ram_be_n[2]),
      .UB_n(base_ram_be_n[3])
  );
  // ExtRAM 仿真模型
  sram_model ext1 (
      .DataIO(ext_ram_data[15:0]),
      .Address(ext_ram_addr[19:0]),
      .OE_n(ext_ram_oe_n),
      .CE_n(ext_ram_ce_n),
      .WE_n(ext_ram_we_n),
      .LB_n(ext_ram_be_n[0]),
      .UB_n(ext_ram_be_n[1])
  );
  sram_model ext2 (
      .DataIO(ext_ram_data[31:16]),
      .Address(ext_ram_addr[19:0]),
      .OE_n(ext_ram_oe_n),
      .CE_n(ext_ram_ce_n),
      .WE_n(ext_ram_we_n),
      .LB_n(ext_ram_be_n[2]),
      .UB_n(ext_ram_be_n[3])
  );

  // 从文件加载 BaseRAM
  initial begin
    reg [31:0] tmp_array[0:1048575];
    integer n_File_ID, n_Init_Size;
    n_File_ID = $fopen(BASE_RAM_INIT_FILE, "rb");
    if (!n_File_ID) begin
      n_Init_Size = 0;
      $display("Failed to open BaseRAM init file");
    end else begin
      n_Init_Size = $fread(tmp_array, n_File_ID);
      n_Init_Size /= 4;
      $fclose(n_File_ID);
    end
    $display("BaseRAM Init Size(words): %d", n_Init_Size);
    for (integer i = 0; i < n_Init_Size; i++) begin
      base1.mem_array0[i] = tmp_array[i][24+:8];
      base1.mem_array1[i] = tmp_array[i][16+:8];
      base2.mem_array0[i] = tmp_array[i][8+:8];
      base2.mem_array1[i] = tmp_array[i][0+:8];
    end
  end

  // 从文件加载 ExtRAM
  initial begin
    reg [31:0] tmp_array[0:1048575];
    integer n_File_ID, n_Init_Size;
    n_File_ID = $fopen(EXT_RAM_INIT_FILE, "rb");
    if (!n_File_ID) begin
      n_Init_Size = 0;
      $display("Failed to open ExtRAM init file");
    end else begin
      n_Init_Size = $fread(tmp_array, n_File_ID);
      n_Init_Size /= 4;
      $fclose(n_File_ID);
    end
    $display("ExtRAM Init Size(words): %d", n_Init_Size);
    for (integer i = 0; i < n_Init_Size; i++) begin
      ext1.mem_array0[i] = tmp_array[i][24+:8];
      ext1.mem_array1[i] = tmp_array[i][16+:8];
      ext2.mem_array0[i] = tmp_array[i][8+:8];
      ext2.mem_array1[i] = tmp_array[i][0+:8];
    end
  end
endmodule
