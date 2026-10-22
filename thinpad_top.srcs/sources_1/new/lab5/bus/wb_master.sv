module wb_master (
    input logic clk_i,
    input logic rst_i,

    // 指令总线
    input logic inst_req_i,
    input logic [31:0] inst_addr_i,
    output logic [31:0] inst_rdata_o,
    output logic inst_ready_o,

    // 数据总线
    input logic mem_req_i,
    input logic mem_we_i,
    input logic [3:0] mem_sel_i,
    input logic [31:0] mem_addr_i,
    input logic [31:0] mem_wdata_i,
    output logic [31:0] mem_rdata_o,
    output logic mem_ready_o,

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
    // 请求锁存
    logic [31:0] inst_addr_q;
    logic [31:0] mem_addr_q;
    logic [31:0] mem_wdata_q;
    logic [3:0] mem_sel_q;
    logic mem_we_q;

    // 返回锁存
    logic [31:0] inst_rdata_a;
    logic inst_ack_a;
    logic inst_err_a;
    logic [31:0] mem_rdata_a;
    logic mem_ack_a;
    logic mem_err_a;

    // 状态定义
    // CPU 侧的 req 表示持续需求；Wishbone 的 cyc/stb 表示一笔正在
    // 进行的事务。两路状态机负责把持续请求拆成单次总线访问。
    typedef enum logic [1:0] {
        REQ_IDLE,
        REQ_BUSY,
        REQ_DONE
    } req_state_t;

    req_state_t inst_state;
    req_state_t mem_state;

    // ready 信号
    always_comb begin
        inst_ready_o = !inst_req_i || (inst_state == REQ_DONE);
        mem_ready_o = !mem_req_i || (mem_state == REQ_DONE);
    end

    wire is_cpu_step_done = inst_ready_o && mem_ready_o;

    // 状态机
    // inst
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            inst_state <= REQ_IDLE;
        end else if (is_cpu_step_done) begin
            inst_state <= REQ_IDLE;
        end else begin
            case (inst_state)
                REQ_IDLE: begin
                    if (inst_req_i) begin
                        inst_addr_q <= inst_addr_i;
                        inst_state <= REQ_BUSY;
                    end
                end

                REQ_BUSY: begin
                    if (inst_ack_a) begin
                        inst_rdata_o <= inst_rdata_a;
                        inst_state <= REQ_DONE;
                    end else if (inst_err_a) begin
                        inst_rdata_o <= 32'b0;
                        inst_state <= REQ_DONE;
                    end
                end

                REQ_DONE: inst_state <= REQ_DONE;
                default: inst_state <= REQ_IDLE;
            endcase
        end
    end

    // mem
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mem_state <= REQ_IDLE;
        end else if (is_cpu_step_done) begin
            mem_state <= REQ_IDLE;
        end else begin
            case (mem_state)
                REQ_IDLE: begin
                    if (mem_req_i) begin
                        mem_addr_q <= mem_addr_i;
                        mem_wdata_q <= mem_wdata_i;
                        mem_sel_q <= mem_sel_i;
                        mem_state <= REQ_BUSY;
                    end
                end

                REQ_BUSY: begin
                    if (mem_ack_a) begin
                        mem_rdata_o <= mem_rdata_a;
                        mem_state <= REQ_DONE;
                    end else if (mem_err_a) begin
                        mem_rdata_o <= 32'b0;
                        mem_state <= REQ_DONE;
                    end
                end

                REQ_DONE: mem_state <= REQ_DONE;
                default: mem_state <= REQ_IDLE;
            endcase
        end
    end

    // 执行
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
        .wbm0_adr_i(inst_addr_q),
        .wbm0_dat_i(32'b0),
        .wbm0_dat_o(inst_rdata_a),
        .wbm0_we_i(1'b0),
        .wbm0_sel_i(4'b1111),
        .wbm0_stb_i(inst_state == REQ_BUSY),
        .wbm0_ack_o(inst_ack_a),
        .wbm0_err_o(inst_err_a),
        .wbm0_rty_o(),
        .wbm0_cyc_i(inst_state == REQ_BUSY),

        // wm1; mem
        .wbm1_adr_i(mem_addr_q),
        .wbm1_dat_i(mem_wdata_q),
        .wbm1_dat_o(mem_rdata_a),
        .wbm1_we_i(mem_we_q),
        .wbm1_sel_i(mem_sel_q),
        .wbm1_stb_i(mem_state == REQ_BUSY),
        .wbm1_ack_o(mem_ack_a),
        .wbm1_err_o(mem_err_a),
        .wbm1_rty_o(),
        .wbm1_cyc_i(mem_state == REQ_BUSY),

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
