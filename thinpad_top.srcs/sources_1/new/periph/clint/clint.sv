module clint (
    input wire clk_i,
    input wire rst_i,

    input wire wb_cyc_i,
    input wire wb_stb_i,
    output reg wb_ack_o,
    input wire [31:0] wb_adr_i,
    input wire [31:0] wb_dat_i,
    output reg [31:0] wb_dat_o,
    input wire [3:0] wb_sel_i,
    input wire wb_we_i,

    output reg timer_irq_o
);
    typedef enum logic [15:0] {
        REG_MTIMECMP_LO = 16'h4000,
        REG_MTIMECMP_HI = 16'h4004,
        REG_MTIME_LO = 16'hBFF8,
        REG_MTIME_HI = 16'hBFFC
    } reg_addr_t;

    logic [63:0] mtime;
    logic [63:0] mtime_next;
    logic [63:0] mtimecmp;
    logic [63:0] mtimecmp_next;

    logic wb_req;
    logic [15:0] reg_addr;
    logic [31:0] wb_mask;

    assign wb_req = wb_cyc_i && wb_stb_i && !wb_ack_o;
    assign reg_addr = {wb_adr_i[15:2], 2'b00};
    assign wb_mask = {{8{wb_sel_i[3]}}, {8{wb_sel_i[2]}}, {8{wb_sel_i[1]}}, {8{wb_sel_i[0]}}};

    always_comb begin
        mtime_next = mtime + 64'd1;
        mtimecmp_next = mtimecmp;

        if (wb_req && wb_we_i) begin
            case (reg_addr)
                REG_MTIMECMP_LO: mtimecmp_next[31:0] = (mtimecmp[31:0] & ~wb_mask) | (wb_dat_i & wb_mask);
                REG_MTIMECMP_HI: mtimecmp_next[63:32] = (mtimecmp[63:32] & ~wb_mask) | (wb_dat_i & wb_mask);
                REG_MTIME_LO: mtime_next[31:0] = (mtime[31:0] & ~wb_mask) | (wb_dat_i & wb_mask);
                REG_MTIME_HI: mtime_next[63:32] = (mtime[63:32] & ~wb_mask) | (wb_dat_i & wb_mask);
                default:;
            endcase
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mtime <= 64'b0;
            mtimecmp <= '1;
            timer_irq_o <= 1'b0;
        end else begin
            mtime <= mtime_next;
            mtimecmp <= mtimecmp_next;
            timer_irq_o <= (mtime >= mtimecmp);
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'b0;
        end else begin
            wb_ack_o <= wb_req;

            if (wb_req && !wb_we_i) begin
                case (reg_addr)
                    REG_MTIMECMP_LO: wb_dat_o <= mtimecmp[31:0];
                    REG_MTIMECMP_HI: wb_dat_o <= mtimecmp[63:32];
                    REG_MTIME_LO: wb_dat_o <= mtime[31:0];
                    REG_MTIME_HI: wb_dat_o <= mtime[63:32];
                    default: wb_dat_o <= 32'b0;
                endcase
            end
        end
    end
endmodule
