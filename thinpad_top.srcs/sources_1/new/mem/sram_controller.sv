module sram_controller #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32,

    parameter int SRAM_ADDR_WIDTH = 20,
    parameter int SRAM_DATA_WIDTH = 32,

    localparam int SRAM_BYTES = SRAM_DATA_WIDTH / 8,
    localparam int SRAM_BYTE_WIDTH = $clog2(SRAM_BYTES)
) (
    // clk and reset
    input wire clk_i,
    input wire rst_i,

    // wishbone slave interface
    input wire wb_cyc_i,
    input wire wb_stb_i, // master想要发送请求
    output logic wb_ack_o, // slave完成请求
    input wire [ADDR_WIDTH-1:0] wb_adr_i, // master想要读写的地址
    input wire [DATA_WIDTH-1:0] wb_dat_i, // master想要写入的数据
    output logic [DATA_WIDTH-1:0] wb_dat_o, // master从slave读取的数据
    input wire [DATA_WIDTH/8-1:0] wb_sel_i, // 字节使能, 和sram相同
    input wire wb_we_i, // master想要读还是写, 0代表读, 1代表写

    // sram interface
    output logic [SRAM_ADDR_WIDTH-1:0] sram_addr,
    inout wire [SRAM_DATA_WIDTH-1:0] sram_data,
    output logic sram_ce_n, // 使用 SRAM 时, 需要保证 base_ram_ce_n=0
    output logic sram_oe_n, // 输出使能, 对于读操作, 需要保证 base_ram_oe_n=0; 对于写操作, 需要保证 base_ram_oe_n=1
    output logic sram_we_n, // 写入使能, 读操作对应 base_ram_we_n=1, 写操作对应 base_ram_we_n=0
    output logic [SRAM_BYTES-1:0] sram_be_n // 字节使能, 目的是实现部分写入, 例如只想写入四个字节其中一个, 就把相应位设置为 0
);

    // TODO: 实现 SRAM 控制器
    // 内部状态
    logic [SRAM_DATA_WIDTH-1:0] sram_data_i;
    logic [SRAM_DATA_WIDTH-1:0] sram_data_o;
    logic sram_data_t; // 1 表示高阻(读模式), 0 表示驱动(写模式)

    assign sram_data = sram_data_t ? 'z : sram_data_o;
    assign sram_data_i = sram_data;

    // 状态定义
    typedef enum logic [2:0] {
        ST_IDLE = 3'b000,
        ST_READ = 3'b001,
        ST_WRITE = 3'b010,
        ST_WRITE_2 = 3'b011,
        ST_WRITE_3 = 3'b100
    } state_t;

    state_t state;
    state_t next_state;

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
                if (wb_stb_i && wb_cyc_i && wb_we_i) begin
                    next_state = ST_WRITE;
                end else if (wb_stb_i && wb_cyc_i && !wb_we_i) begin
                    next_state = ST_READ;
                end
            end

            ST_READ: begin
                next_state = ST_IDLE;
            end

            ST_WRITE: begin
                next_state = ST_WRITE_2;
            end

            ST_WRITE_2: begin
                next_state = ST_WRITE_3;
            end

            ST_WRITE_3: begin
                next_state = ST_IDLE;
            end

            default: begin
                next_state = ST_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            sram_addr <= '0;
        end else if (next_state == ST_READ || next_state == ST_WRITE) begin
            sram_addr <= wb_adr_i[SRAM_ADDR_WIDTH+SRAM_BYTE_WIDTH-1:SRAM_BYTE_WIDTH];
        end
    end

    // stage3: 输出逻辑
    always_comb begin
        sram_ce_n = 1'b1;
        sram_oe_n = 1'b1;
        sram_we_n = 1'b1;
        sram_be_n = '0;
        sram_data_t = 1'b1;
        sram_data_o = wb_dat_i;
        wb_ack_o = 1'b0;
        wb_dat_o = '0;

        case (state)
            ST_READ: begin
                sram_ce_n = 1'b0;
                sram_oe_n = 1'b0;
                sram_we_n = 1'b1;
                sram_be_n = ~wb_sel_i;
                sram_data_t = 1'b1;
                wb_dat_o = sram_data_i;
                wb_ack_o = 1'b1;
            end

            ST_WRITE, ST_WRITE_2: begin
                sram_ce_n = 1'b0;
                sram_oe_n = 1'b1;
                sram_we_n = (state == ST_WRITE_2) ? 1'b0 : 1'b1;
                sram_be_n = ~wb_sel_i;
                sram_data_t = 1'b0;
                sram_data_o = wb_dat_i;
            end

            ST_WRITE_3: begin
                wb_ack_o = 1'b1;
            end

            default: begin
                // ST_IDLE
            end
        endcase
    end
endmodule
