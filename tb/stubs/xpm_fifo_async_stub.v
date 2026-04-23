// =============================================================================
// xpm_fifo_async_stub.v — minimal behavioural stub for lint-only iverilog elab.
// Not functionally accurate — only exists so that tetra_zynq_top.v can be
// elaborated by `iverilog -g2012` for syntax/connectivity checks.
// Never included in Vivado synthesis (the real XPM primitive is picked up
// from the unisim lib).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module xpm_fifo_async #(
    parameter FIFO_MEMORY_TYPE      = "auto",
    parameter FIFO_WRITE_DEPTH      = 16,
    parameter WRITE_DATA_WIDTH      = 32,
    parameter READ_DATA_WIDTH       = 32,
    parameter READ_MODE             = "std",
    parameter CDC_SYNC_STAGES       = 2,
    parameter RELATED_CLOCKS        = 0,
    parameter USE_ADV_FEATURES      = "0707",
    parameter WAKEUP_TIME           = 0,
    parameter FULL_RESET_VALUE      = 0,
    parameter ECC_MODE              = "no_ecc",
    parameter DOUT_RESET_VALUE      = "0",
    parameter WR_DATA_COUNT_WIDTH   = 1,
    parameter RD_DATA_COUNT_WIDTH   = 1,
    parameter PROG_EMPTY_THRESH     = 3,
    parameter PROG_FULL_THRESH      = 3,
    parameter FIFO_READ_LATENCY     = 0,
    parameter SIM_ASSERT_CHK        = 0
)(
    input  wire rst,
    input  wire wr_clk,
    input  wire wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0] din,
    output wire full,
    output wire wr_ack,
    output wire almost_full,
    output wire overflow,
    output wire prog_full,
    output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output wire wr_rst_busy,
    input  wire rd_clk,
    input  wire rd_en,
    output wire [READ_DATA_WIDTH-1:0] dout,
    output wire empty,
    output wire almost_empty,
    output wire data_valid,
    output wire underflow,
    output wire prog_empty,
    output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output wire rd_rst_busy,
    input  wire injectsbiterr,
    input  wire injectdbiterr,
    output wire sbiterr,
    output wire dbiterr,
    input  wire sleep
);
    assign full          = 1'b0;
    assign wr_ack        = 1'b0;
    assign almost_full   = 1'b0;
    assign overflow      = 1'b0;
    assign prog_full     = 1'b0;
    assign wr_data_count = {WR_DATA_COUNT_WIDTH{1'b0}};
    assign wr_rst_busy   = 1'b0;
    assign dout          = {READ_DATA_WIDTH{1'b0}};
    assign empty         = 1'b1;
    assign almost_empty  = 1'b1;
    assign data_valid    = 1'b0;
    assign underflow     = 1'b0;
    assign prog_empty    = 1'b1;
    assign rd_data_count = {RD_DATA_COUNT_WIDTH{1'b0}};
    assign rd_rst_busy   = 1'b0;
    assign sbiterr       = 1'b0;
    assign dbiterr       = 1'b0;
endmodule

`default_nettype wire
