module cpu_csr (
    input logic clk,
    input logic rst,

    input logic [11:0] csr_addr,
    input logic [1:0] csr_op,
    input logic [31:0] csr_wsrc,
    input logic csr_w_en,
    input logic csr_commit,
    output logic [31:0] csr_rdata,
    output logic csr_illegal,

    input logic trap_commit,
    input logic [31:0] trap_pc,
    input logic [4:0] trap_cause,
    input logic [31:0] trap_tval,
    output logic [31:0] trap_target,

    input logic mret_commit,
    output logic [31:0] mret_target,

    input logic timer_irq,
    output logic irq_valid,
    output logic [3:0] irq_cause,

    output logic [1:0] priv_mode,
    output logic [31:0] satp
);
    typedef enum logic [11:0] {
        CSR_SATP = 12'h180,
        CSR_MSTATUS = 12'h300,
        CSR_MISA = 12'h301,
        CSR_MIE = 12'h304,
        CSR_MTVEC = 12'h305,
        CSR_MCOUNTEREN = 12'h306,
        CSR_MENVCFG = 12'h30A,
        CSR_MSTATUSH = 12'h310,
        CSR_MENVCFGH = 12'h31A,
        CSR_MSCRATCH = 12'h340,
        CSR_MEPC = 12'h341,
        CSR_MCAUSE = 12'h342,
        CSR_MTVAL = 12'h343,
        CSR_MIP = 12'h344,
        CSR_MVENDORID = 12'hF11,
        CSR_MARCHID = 12'hF12,
        CSR_MIMPID = 12'hF13,
        CSR_MHARTID = 12'hF14,
        CSR_MCONFIGPTR = 12'hF15
    } csr_addr_t;

    typedef enum logic [1:0] {
        CSR_OP_NONE = 2'b00,
        CSR_OP_RW = 2'b01,
        CSR_OP_RS = 2'b10,
        CSR_OP_RC = 2'b11
    } csr_op_t;

    typedef enum logic [1:0] {
        PRIV_U = 2'b00,
        PRIV_M = 2'b11
    } priv_mode_t;

    typedef enum logic [3:0] {
        IRQ_M_TIMER = 4'd7
    } irq_cause_t;

    typedef enum logic [31:0] {
        MISA_RV32IU = 32'h4010_0100
    } misa_t;

    typedef struct packed {
        logic [18:0] zero_31_13;
        logic [1:0] mpp;
        logic [2:0] zero_10_8;
        logic mpie;
        logic [2:0] zero_6_4;
        logic mie;
        logic [2:0] zero_2_0;
    } mstatus_t;

    typedef struct packed {
        logic [23:0] zero_31_8;
        logic mti;
        logic [6:0] zero_6_0;
    } mint_t;

    typedef struct packed {
        logic [29:0] base;
        logic [1:0] mode;
    } mtvec_t;

    typedef struct packed {
        logic mode;
        logic [8:0] asid;
        logic [21:0] ppn;
    } satp_t;

    logic [1:0] mstatus_mpp;
    logic mstatus_mpie;
    logic mstatus_mie;
    logic mie_mti;
    logic [29:0] mtvec_base;
    logic mtvec_mode;
    logic [31:0] mscratch;
    logic [29:0] mepc;
    logic [31:0] mcause;
    logic [31:0] mtval;
    logic satp_mode;
    logic [21:0] satp_ppn;

    mstatus_t mstatus;
    mint_t mie;
    mint_t mip;
    mtvec_t mtvec;

    logic csr_exist;
    logic [31:0] csr_wdata;
    mstatus_t mstatus_wdata;
    mint_t mie_wdata;
    mtvec_t mtvec_wdata;
    satp_t satp_wdata;

    assign mstatus = {19'b0, mstatus_mpp, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
    assign mie = {24'b0, mie_mti, 7'b0};
    assign mip = {24'b0, timer_irq, 7'b0};
    assign mtvec = {mtvec_base, 1'b0, mtvec_mode};
    assign satp = {satp_mode, 9'b0, satp_ppn};

    always_comb begin
        csr_exist = 1'b1;
        csr_rdata = 32'b0;

        case (csr_addr)
            CSR_SATP: csr_rdata = satp;
            CSR_MSTATUS: csr_rdata = mstatus;
            CSR_MISA: csr_rdata = MISA_RV32IU;
            CSR_MIE: csr_rdata = mie;
            CSR_MTVEC: csr_rdata = mtvec;
            CSR_MSCRATCH: csr_rdata = mscratch;
            CSR_MEPC: csr_rdata = {mepc, 2'b00};
            CSR_MCAUSE: csr_rdata = mcause;
            CSR_MTVAL: csr_rdata = mtval;
            CSR_MIP: csr_rdata = mip;
            CSR_MCOUNTEREN,
            CSR_MENVCFG,
            CSR_MSTATUSH,
            CSR_MENVCFGH,
            CSR_MVENDORID,
            CSR_MARCHID,
            CSR_MIMPID,
            CSR_MHARTID,
            CSR_MCONFIGPTR:
                csr_rdata = 32'b0;
            default:
                csr_exist = (csr_addr[11:4] >= 8'h3A) && (csr_addr[11:4] <= 8'h3E);
        endcase
    end

    assign csr_illegal = !csr_exist
        || (csr_addr[9:8] > priv_mode)
        || (csr_w_en && (csr_addr[11:10] == 2'b11));

    always_comb begin
        case (csr_op)
            CSR_OP_RS: csr_wdata = csr_rdata | csr_wsrc;
            CSR_OP_RC: csr_wdata = csr_rdata & ~csr_wsrc;
            default: csr_wdata = csr_wsrc;
        endcase
    end

    assign mstatus_wdata = csr_wdata;
    assign mie_wdata = csr_wdata;
    assign mtvec_wdata = csr_wdata;
    assign satp_wdata = csr_wdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            priv_mode <= PRIV_M;
            mstatus_mpp <= PRIV_U;
            mstatus_mpie <= 1'b0;
            mstatus_mie <= 1'b0;
            mie_mti <= 1'b0;
            mtvec_base <= 30'b0;
            mtvec_mode <= 1'b0;
            mscratch <= 32'b0;
            mepc <= 30'b0;
            mcause <= 32'b0;
            mtval <= 32'b0;
            satp_mode <= 1'b0;
            satp_ppn <= 22'b0;
        end else if (trap_commit) begin
            priv_mode <= PRIV_M;
            mstatus_mpp <= priv_mode;
            mstatus_mpie <= mstatus_mie;
            mstatus_mie <= 1'b0;
            mepc <= trap_pc[31:2];
            mcause <= {trap_cause[4], 27'b0, trap_cause[3:0]};
            mtval <= trap_tval;
        end else if (mret_commit) begin
            priv_mode <= mstatus_mpp;
            mstatus_mpp <= PRIV_U;
            mstatus_mpie <= 1'b1;
            mstatus_mie <= mstatus_mpie;
        end else if (csr_commit && csr_w_en) begin
            case (csr_addr)
                CSR_SATP: begin
                    satp_mode <= satp_wdata.mode;
                    satp_ppn <= satp_wdata.ppn;
                end

                CSR_MSTATUS: begin
                    mstatus_mpie <= mstatus_wdata.mpie;
                    mstatus_mie <= mstatus_wdata.mie;
                    if ((mstatus_wdata.mpp == PRIV_M) || (mstatus_wdata.mpp == PRIV_U)) begin
                        mstatus_mpp <= mstatus_wdata.mpp;
                    end
                end

                CSR_MIE: mie_mti <= mie_wdata.mti;

                CSR_MTVEC: begin
                    if (!mtvec_wdata.mode[1]) begin
                        mtvec_base <= mtvec_wdata.base;
                        mtvec_mode <= mtvec_wdata.mode[0];
                    end
                end

                CSR_MSCRATCH: mscratch <= csr_wdata;
                CSR_MEPC: mepc <= csr_wdata[31:2];
                CSR_MCAUSE: mcause <= csr_wdata;
                CSR_MTVAL: mtval <= csr_wdata;
                default:;
            endcase
        end
    end

    assign trap_target = (mtvec_mode && trap_cause[4])
        ? {mtvec_base, 2'b00} + {26'b0, trap_cause[3:0], 2'b00}
        : {mtvec_base, 2'b00};
    assign mret_target = {mepc, 2'b00};

    assign irq_valid = mip.mti && mie.mti && ((priv_mode != PRIV_M) || mstatus.mie);
    assign irq_cause = IRQ_M_TIMER;
endmodule
