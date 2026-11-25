module uart_controller #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,

    parameter CLK_FREQ = 50_000_000,
    parameter BAUD = 115200
) (
    // clk and reset
    input wire clk_i,
    input wire rst_i,

    // wishbone slave interface
    input wire wb_cyc_i,
    input wire wb_stb_i,
    output reg wb_ack_o,
    input wire [ADDR_WIDTH-1:0] wb_adr_i,
    input wire [DATA_WIDTH-1:0] wb_dat_i,
    output reg [DATA_WIDTH-1:0] wb_dat_o,
    input wire [DATA_WIDTH/8-1:0] wb_sel_i,
    input wire wb_we_i,

    // uart interface
    output reg uart_txd_o,
    input  wire uart_rxd_i
);

  localparam REG_DATA = 8'h00;
  localparam REG_STATUS = 8'h05;

  // uart transmitter
  logic txd_start;
  logic txd_busy;
  logic [7:0] txd_data;

  async_transmitter #(
      .ClkFrequency(CLK_FREQ),
      .Baud        (BAUD)
  ) u_async_transmitter (
      .clk      (clk_i),
      .TxD_start(txd_start),
      .TxD_data (txd_data),
      .TxD      (uart_txd_o),
      .TxD_busy (txd_busy)
  );

  // uart receiver
  logic rxd_data_ready;
  logic [7:0] rxd_data;
  wire rxd_clear = rst_i || rxd_data_ready;

  async_receiver #(
      .ClkFrequency(CLK_FREQ),
      .Baud        (BAUD)
  ) u_async_receiver (
      .clk           (clk_i),
      .RxD           (uart_rxd_i),
      .RxD_data_ready(rxd_data_ready),
      .RxD_clear     (rxd_clear),
      .RxD_data      (rxd_data)
  );

  /*-- internal registers --*/
  logic [7:0] rx_byte;
  logic rx_valid;
  wire wb_req = wb_cyc_i && wb_stb_i && !wb_ack_o;
  wire read_data = wb_req && !wb_we_i && wb_adr_i[7:0] == REG_DATA && (|wb_sel_i);
  wire [7:0] reg_status = {2'b0, ~txd_busy, 4'b0, rx_valid};

  /*-- wishbone fsm --*/
  always_ff @(posedge clk_i) begin
    if (rst_i)
      wb_ack_o <= 0;
    else
      // every request get ACK-ed immediately
      if (wb_ack_o) begin
        wb_ack_o <= 0;
      end else begin
        wb_ack_o <= wb_cyc_i && wb_stb_i;
      end
  end

  // write logic
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      txd_start <= 0;
    end else if(wb_req && wb_we_i) begin
      case (wb_adr_i[7:0])
        REG_DATA: begin
          if(wb_sel_i[0]) begin
            txd_data  <= wb_dat_i[7:0];
            txd_start <= 1;
          end
        end

        default: ;  // do nothing
      endcase
    end else begin
      txd_start <= 0;
    end
  end

  // read logic
  always_ff @(posedge clk_i) begin
    if(rst_i) begin
      rx_valid <= 0;  // clear rxd to initialize dataready
      rx_byte <= '0;
    end else if (rxd_data_ready && (!rx_valid || read_data)) begin
      rx_byte <= rxd_data;
      rx_valid <= 1;
    end else if (read_data) begin
      rx_valid <= 0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_i && wb_req && !wb_we_i) begin
      case (wb_adr_i[7:0])
        REG_DATA: begin
          for (int i = 0; i < DATA_WIDTH/8; i++) begin
            if (wb_sel_i[i]) wb_dat_o[i*8 +: 8] <= rx_byte;
          end
        end

        REG_STATUS: begin
          for (int i = 0; i < DATA_WIDTH/8; i++) begin
            if (wb_sel_i[i]) wb_dat_o[i*8 +: 8] <= reg_status;
          end
        end

        default: ;  // do nothing
      endcase
    end
  end

endmodule
