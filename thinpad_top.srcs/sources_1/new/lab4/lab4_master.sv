module lab4_master #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
) (
    input wire clk_i,
    input wire rst_i,

    // TODO: 添加需要的控制信号，例如按键开关？
    input logic [ADDR_WIDTH-1:0] base_addr_i,

    // wishbone master
    output reg wb_cyc_o,
    output reg wb_stb_o,
    input wire wb_ack_i,
    output reg [ADDR_WIDTH-1:0] wb_adr_o,
    output reg [DATA_WIDTH-1:0] wb_dat_o,
    input wire [DATA_WIDTH-1:0] wb_dat_i,
    output reg [DATA_WIDTH/8-1:0] wb_sel_o,
    output reg wb_we_o
);

    // TODO: 实现实验 5 的内存+串口 Master
    // 内部状态
    // logic [ADDR_WIDTH-1:0] addr_inner;
    localparam logic [ADDR_WIDTH-1:0] UART_STATUS_ADDR = 32'h1000_0005; // 状态寄存器
    localparam logic [ADDR_WIDTH-1:0] UART_DATA_ADDR = 32'h1000_0000; // 数据寄存器

    logic [ADDR_WIDTH-1:0] base_addr_reg;
    logic [7:0] data_buf;
    logic [3:0] cnt; // 0-9

    // 状态定义
    typedef enum logic [3:0] { // 10个状态, 4位宽
        ST_IDLE = 4'b0000,

        // 读
        ST_READ_WAIT_ACTION = 4'b0001, // 正在读取状态寄存器
        ST_READ_WAIT_CHECK = 4'b0010, // 读取了状态寄存器当前的取值, 判断是否可以读取新的值
        ST_READ_DATA_ACTION = 4'b0011, // 正在读取数据寄存器
        ST_READ_DATA_DONE = 4'b0100, // 完成读取数据寄存器, 进入下面的操作

        // 写内存
        ST_WRITE_SRAM_ACTION = 4'b0101, // 正在写入 SRAM
        ST_WRITE_SRAM_DONE = 4'b0110, // 写入 SRAM 完成，进入下面的操作

        // 写串口
        ST_WRITE_WAIT_ACTION = 4'b0111, // 正在读取状态寄存器
        ST_WRITE_WAIT_CHECK = 4'b1000, // 读取了状态寄存器当前的取值, 判断是否可以写入新的值
        ST_WRITE_DATA_ACTION = 4'b1001, // 正在写入数据寄存器
        ST_WRITE_DATA_DONE = 4'b1010, // 完成写入数据寄存器，进入下面的操作

        // 结束
        ST_FINISH = 4'b1011 // 10 次完成，停在这里直到复位
    } state_t;

    state_t state;
    state_t next_state;

    // 三段式状态机
    // stage1: 状态更新
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state <= ST_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // stage2: 次态逻辑
    always_comb begin
        next_state = state;

        case (state)
            ST_IDLE: begin
                next_state = ST_READ_WAIT_ACTION;
            end

            // 读
            ST_READ_WAIT_ACTION: begin
                next_state = ST_READ_WAIT_CHECK;
            end

            ST_READ_WAIT_CHECK: begin
                if (wb_ack_i) begin
                    if (wb_dat_i[8]) begin
                        next_state = ST_READ_DATA_ACTION;
                    end else begin
                        next_state = ST_READ_WAIT_ACTION;
                    end
                end
            end

            ST_READ_DATA_ACTION: begin
                next_state = ST_READ_DATA_DONE;
            end

            ST_READ_DATA_DONE: begin
                if (wb_ack_i) begin
                    next_state = ST_WRITE_SRAM_ACTION;
                end
            end

            // 写内存
            ST_WRITE_SRAM_ACTION: begin
                next_state = ST_WRITE_SRAM_DONE;
            end

            ST_WRITE_SRAM_DONE: begin
                if (wb_ack_i) begin
                    next_state = ST_WRITE_WAIT_ACTION;
                end
            end

            // 写串口
            ST_WRITE_WAIT_ACTION: begin
                next_state = ST_WRITE_WAIT_CHECK;
            end

            ST_WRITE_WAIT_CHECK: begin
                if (wb_ack_i) begin
                    if (wb_dat_i[13]) begin
                        next_state = ST_WRITE_DATA_ACTION;
                    end else begin
                        next_state = ST_WRITE_WAIT_ACTION;
                    end
                end
            end

            ST_WRITE_DATA_ACTION: begin
                next_state = ST_WRITE_DATA_DONE;
            end

            ST_WRITE_DATA_DONE: begin
                if (wb_ack_i) begin
                    if (cnt==4'd9) begin
                        next_state = ST_FINISH;
                    end else begin
                        next_state = ST_READ_WAIT_ACTION;
                    end
                end
            end

            ST_FINISH: begin
                next_state = ST_FINISH; // 结束后保持不动, 不再发起总线请求
            end

            default: begin
                next_state = ST_IDLE;
            end
        endcase
    end

    // stage3: 输出逻辑
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            // 内部状态
            base_addr_reg <= '0;
            data_buf <= 8'b0;
            cnt <= 4'b0;

            // 输出
            wb_cyc_o <= 1'b0;
            wb_stb_o <= 1'b0;
            wb_adr_o <= '0;
            wb_dat_o <= '0;
            wb_sel_o <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    // 释放
                    wb_cyc_o <= 1'b0;
                    wb_stb_o <= 1'b0;

                    cnt <= 4'b0;
                    base_addr_reg <= base_addr_i;
                end

                // 读
                ST_READ_WAIT_ACTION: begin
                    // 读
                    wb_cyc_o <= 1'b1;
                    wb_stb_o <= 1'b1;
                    wb_we_o <= 1'b0;
                    wb_sel_o <= 4'b0010;

                    wb_adr_o <= UART_STATUS_ADDR;
                end

                ST_READ_WAIT_CHECK: begin
                    if (wb_ack_i) begin
                        // 释放
                        wb_cyc_o <= 1'b0;
                        wb_stb_o <= 1'b0;
                    end
                end

                ST_READ_DATA_ACTION: begin
                    // 读
                    wb_cyc_o <= 1'b1;
                    wb_stb_o <= 1'b1;
                    wb_we_o <= 1'b0;
                    wb_sel_o <= 4'b0001;

                    wb_adr_o <= UART_DATA_ADDR;
                end

                ST_READ_DATA_DONE: begin
                    if (wb_ack_i) begin
                        // 释放
                        wb_cyc_o  <= 1'b0;
                        wb_stb_o  <= 1'b0;

                        // 锁存
                        data_buf <= wb_dat_i[7:0];
                    end
                end

                // 写内存
                ST_WRITE_SRAM_ACTION: begin
                    // 写
                    wb_cyc_o <= 1'b1;
                    wb_stb_o <= 1'b1;
                    wb_we_o <= 1'b1;
                    wb_sel_o <= 4'b0001;

                    wb_adr_o <= base_addr_reg + (ADDR_WIDTH'(cnt) << 2);
                    wb_dat_o <= {24'b0, data_buf};
                end

                ST_WRITE_SRAM_DONE: begin
                    if (wb_ack_i) begin
                        // 释放
                        wb_cyc_o  <= 1'b0;
                        wb_stb_o  <= 1'b0;
                    end
                end

                // 写串口
                ST_WRITE_WAIT_ACTION: begin
                    // 写
                    wb_cyc_o <= 1'b1;
                    wb_stb_o <= 1'b1;
                    wb_we_o <= 1'b0;
                    wb_sel_o <= 4'b0010;

                    wb_adr_o <= UART_STATUS_ADDR;
                end

                ST_WRITE_WAIT_CHECK: begin
                    if (wb_ack_i) begin
                        // 释放
                        wb_cyc_o <= 1'b0;
                        wb_stb_o <= 1'b0;
                    end
                end

                ST_WRITE_DATA_ACTION: begin
                    // 写
                    wb_cyc_o <= 1'b1;
                    wb_stb_o <= 1'b1;
                    wb_we_o <= 1'b1;
                    wb_sel_o <= 4'b0001;

                    wb_adr_o <= UART_DATA_ADDR;
                    wb_dat_o <= {24'b0, data_buf};
                end

                ST_WRITE_DATA_DONE: begin
                    if (wb_ack_i) begin
                        // 释放
                        wb_cyc_o <= 1'b0;
                        wb_stb_o <= 1'b0;

                        cnt <= cnt + 1'b1; // 计数
                    end
                end

                default: ;
            endcase
        end
    end
endmodule
