// =============================================================================
// tetra_rx_iq_capture.v — Raw post-RRC RX IQ capture buffer (debug/measurement)
// =============================================================================
//
// Purpose:
//   Capture the SDR's OWN receive-chain output (post-CIC/RRC I/Q at 72 kHz) into
//   a BRAM ring buffer so it can be read out over AXI-Lite and analysed offline.
//   This is the only valid basis for evaluating/improving the SDR's receiver —
//   external recordings (RTL-SDR) say nothing about THIS RX chain.
//
//   Free-running circular buffer: while not frozen, every valid sample is written
//   at wr_addr (wrapping). Software sets `freeze` to stop capture, reads `wr_ptr`
//   (where it stopped = newest sample), then drains `mem` via rd_addr/rd_data.
//   The buffer then holds the last DEPTH samples ending at wr_ptr.
//
// Clocking: write port runs in clk_sys (fe_valid), read/control in clk_axi.
//   True-dual-port BRAM handles the CDC for the data. `freeze` is 2-FF synced
//   into clk_sys; `wr_ptr` is 2-FF synced into clk_axi and is only meaningful
//   once frozen (stable), which is exactly how software uses it.
//
// Resource: 1 sample = 32 bit ({I[15:0], Q[15:0]}). DEPTH=8192 → 256 Kbit ≈
//   8 × BRAM36. Control logic is a few FF/LUT — slice-light (BRAM has headroom).
// =============================================================================

`default_nettype none

module tetra_rx_iq_capture #(
 parameter integer IQ_WIDTH = 16,
 parameter integer DEPTH    = 8192,
 parameter integer ADDR_W   = 13   // ceil(log2(DEPTH))
)(
 // ---- capture side (clk_sys) ----
 input wire                       clk_sys,
 input wire                       rst_n_sys,
 input wire signed [IQ_WIDTH-1:0] i_in_sys,
 input wire signed [IQ_WIDTH-1:0] q_in_sys,
 input wire                       valid_in_sys,

 // ---- control/read side (clk_axi) ----
 input wire                       clk_axi,
 input wire                       rst_n_axi,
 input wire                       freeze_axi,    // 1 = stop capture (freeze buffer)
 input wire  [ADDR_W-1:0]         rd_addr_axi,
 output reg  [31:0]               rd_data_axi,   // {I[15:0], Q[15:0]} at rd_addr
 output wire [ADDR_W-1:0]         wr_ptr_axi     // write pointer (newest+1); valid when frozen
);

 // ---------------------------------------------------------------------------
 // freeze: clk_axi -> clk_sys (2-FF synchroniser)
 // ---------------------------------------------------------------------------
 (* ASYNC_REG = "true" *) reg freeze_meta_sys, freeze_sync_sys;
 always @(posedge clk_sys or negedge rst_n_sys) begin
  if (!rst_n_sys) begin
   freeze_meta_sys <= 1'b0;
   freeze_sync_sys <= 1'b0;
  end else begin
   freeze_meta_sys <= freeze_axi;
   freeze_sync_sys <= freeze_meta_sys;
  end
 end

 // ---------------------------------------------------------------------------
 // Write address + circular write (clk_sys). Stops advancing while frozen.
 // ---------------------------------------------------------------------------
 reg [ADDR_W-1:0] wr_addr_sys;
 wire             wr_en_sys = valid_in_sys & ~freeze_sync_sys;

 always @(posedge clk_sys or negedge rst_n_sys) begin
  if (!rst_n_sys)
   wr_addr_sys <= {ADDR_W{1'b0}};
  else if (wr_en_sys)
   wr_addr_sys <= (wr_addr_sys == DEPTH-1) ? {ADDR_W{1'b0}}
                                           : wr_addr_sys + 1'b1;
 end

 // ---------------------------------------------------------------------------
 // True-dual-port BRAM: write @ clk_sys, read @ clk_axi
 // ---------------------------------------------------------------------------
 (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];

 always @(posedge clk_sys) begin
  if (wr_en_sys)
   mem[wr_addr_sys] <= {i_in_sys, q_in_sys};
 end

 always @(posedge clk_axi) begin
  rd_data_axi <= mem[rd_addr_axi];
 end

 // ---------------------------------------------------------------------------
 // wr_addr: clk_sys -> clk_axi (2-FF). Multi-bit CDC is safe here because SW
 // reads wr_ptr only after asserting freeze, by which point wr_addr is static.
 // ---------------------------------------------------------------------------
 (* ASYNC_REG = "true" *) reg [ADDR_W-1:0] wr_ptr_meta_axi, wr_ptr_sync_axi;
 always @(posedge clk_axi or negedge rst_n_axi) begin
  if (!rst_n_axi) begin
   wr_ptr_meta_axi <= {ADDR_W{1'b0}};
   wr_ptr_sync_axi <= {ADDR_W{1'b0}};
  end else begin
   wr_ptr_meta_axi <= wr_addr_sys;
   wr_ptr_sync_axi <= wr_ptr_meta_axi;
  end
 end
 assign wr_ptr_axi = wr_ptr_sync_axi;

endmodule

`default_nettype wire
