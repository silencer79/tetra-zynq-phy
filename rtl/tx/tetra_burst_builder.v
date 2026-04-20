// =============================================================================
// Module: tetra_burst_builder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_builder.v
//
// Description:
// Continuous Downlink Burst Builder — assembles 255-symbol TETRA bursts
// (NDB or SDB) and streams dibits to the pi4dqpsk modulator.
//
// Supports seamless burst chaining: build_req can arrive while the current
// burst is still transmitting.  The new burst data is latched into shadow
// registers and automatically loaded when the current burst completes,
// producing a gap-free continuous symbol stream.
//
// Burst format (510 bits = 255 symbols × 2):
//   SDB: TAIL1(6) + HC(1) + FC(40) + sb1(60) + STS(19) + bb(15)
//        + bkn2(108) + HD(1) + TAIL2(5)
//   NDB: TAIL1(6) + HA(1) + blk1(108) + bb1(7) + NTS(11) + bb2(8)
//        + blk2(108) + HA(1) + TAIL2(5)
//
// Symbol enable (sym_en_ext_sys):
// Derived from AD9361 DATA_CLK (18.432 MHz ÷ 1024 = exact 18,000 Hz),
// synchronized to clk_sys in tetra_zynq_top.  Zero jitter, zero drift.
//
// Burst chaining:
// When build_req_sys fires while tx_busy_sys is HIGH, the new payload is
// latched into shadow registers.  At sym_cnt=254, if a chain is pending,
// the shift register reloads and sym_cnt wraps to 0 — tx_busy stays HIGH,
// the first sym_en_w pulse.  tx_done aligns with last valid symbol.
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_builder #(
 parameter BLOCK_BITS = 216, // bits per NDB block (108 symbols × 2)
 parameter BB_BITS = 30, // BB/AACH field bits (15 symbols × 2)
 parameter SB1_BITS = 120  // SDB sb1 field bits (60 symbols × 2)
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // Symbol enable — exact 18,000 Hz from clk_lvds ÷ 1024, synced to clk_sys
 input wire sym_en_ext_sys,

 // NDB payload inputs (latched on build_req_sys pulse)
 input wire [BLOCK_BITS-1:0] block1_data_sys, // Block 1 (NDB), MSB = first symbol
 input wire [BLOCK_BITS-1:0] block2_data_sys, // Block 2 (NDB/SDB bkn2), MSB = first symbol
 input wire [BB_BITS-1:0] bb_data_sys, // BB/AACH (shared NDB/SDB), MSB = first symbol

 // SDB payload input (latched on build_req_sys pulse)
 input wire [SB1_BITS-1:0] sb1_data_sys, // sb1 (SDB), MSB = first symbol

 input wire burst_type_sys, // 0=NDB, 1=SDB
 input wire burst_ndb2_sys, // 0=NDB1 (NTS1, SCH/F), 1=NDB2 (NTS2, SCH/HD)

 // Control
 input wire build_req_sys, // 1-cycle pulse: start burst

 // Output symbol stream
 output reg [1:0] tx_dibit_sys,
 output reg tx_dibit_valid_sys,
 output reg tx_done_sys, // 1-cycle pulse on last symbol
 output reg tx_busy_sys // HIGH while burst in progress
);

// =============================================================================
// Constants — Continuous Downlink Burst
// =============================================================================

localparam BURST_BITS = 510; // 255 symbols × 2 bits
localparam [7:0] SYM_LAST = 8'd254; // last symbol index (0..254)

// FSM states
localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_SHIFT = 2'd1;
localparam [1:0] S_DONE = 2'd2;

// ---- Tail symbols from q-sequence (ETSI §9.4.4.3.2) ----
// q = [1,0,1,1,0,1,1,1,0,0,0,0,0,1,1,0,1,0,1,1,0,1]
//      0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21
//
// Tail1 = q[10..21] = 6 symbols: (00)(01)(10)(10)(11)(01)
localparam [11:0] TAIL1 = {2'b00, 2'b01, 2'b10, 2'b10, 2'b11, 2'b01};
// Tail2 = q[0..9] = 5 symbols: (10)(11)(01)(11)(00)
localparam [9:0] TAIL2 = {2'b10, 2'b11, 2'b01, 2'b11, 2'b00};

// ---- Phase adjustment placeholder (00 = no adjustment) ----
localparam [1:0] PADJ = 2'b00;

// ---- Frequency correction field (40 symbols, §9.4.4.3.1) ----
// f = [1,1,1,1,1,1,1,1, 0×64, 1,1,1,1,1,1,1,1] → 80 bits
// Dibits: 4×(11), 32×(00), 4×(11)
localparam [79:0] FC_PAT = {8'hFF, 64'h0000_0000_0000_0000, 8'hFF};

// ---- Synchronization Training Sequence (19 symbols, §9.4.4.3.4) ----
// y = [1,1,0,0,0,0,0,1,1,0,0,1,1,1,0,0,1,1,1,0,1,0,0,1,1,1,0,0,0,0,0,1,1,0,0,1,1,1]
// Dibits: (11)(00)(00)(01)(10)(01)(11)(00)(11)(10)(10)(01)(11)(00)(00)(01)(10)(01)(11)
localparam [37:0] STS_REF = {
 2'b11, 2'b00, 2'b00, 2'b01, 2'b10, 2'b01, 2'b11, 2'b00,
 2'b11, 2'b10, 2'b10, 2'b01, 2'b11, 2'b00, 2'b00, 2'b01,
 2'b10, 2'b01, 2'b11
};

// ---- Normal Training Sequence 1 (11 symbols, §9.4.4.3.2) ----
// n = [1,1,0,1,0,0,0,0,1,1,1,0,1,0,0,1,1,1,0,1,0,0]
// Dibits: (11)(01)(00)(00)(11)(10)(10)(01)(11)(01)(00)
localparam [21:0] NTS1_REF = {
 2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b10,
 2'b10, 2'b01, 2'b11, 2'b01, 2'b00
};

// ---- Normal Training Sequence 2 (11 symbols, §9.4.4.3.3) ----
// p = [0,1,1,1,1,0,1,0,0,1,0,0,0,0,1,1,1,0,1,1,1,0]  (osmo-tetra p_bits)
// Dibits: (01)(11)(10)(10)(01)(00)(00)(11)(01)(11)(10)
localparam [21:0] NTS2_REF = {
 2'b01, 2'b11, 2'b10, 2'b10, 2'b01, 2'b00,
 2'b00, 2'b11, 2'b01, 2'b11, 2'b10
};

// =============================================================================
// Symbol rate enable — derived from external sym_en_ext_sys
//
// The symbol clock is generated in tetra_zynq_top from clk_lvds (AD9361
// DATA_CLK = 18.432 MHz) with a divide-by-1024 counter, giving exactly
// 18,000.000 Hz with zero jitter.  The pulse is synchronized to clk_sys
// before arriving here as sym_en_ext_sys.
// =============================================================================
wire sym_en_w = tx_busy_sys && sym_en_ext_sys;

// =============================================================================
// FSM state and symbol counter
// =============================================================================
reg [1:0] state_sys;
reg [7:0] sym_cnt_sys;

// =============================================================================
// Burst chaining — shadow registers for next burst
//
// When build_req fires while tx_busy is HIGH, the payload is latched into
// shadow registers and chain_pending is set.  At sym_cnt=254 the builder
// reloads from the shadow burst and continues without going idle.
// =============================================================================
reg        chain_pending_sys;
reg [BURST_BITS-1:0] chain_burst_sys;

// build_req_pending_sys: for cold start (first burst from S_IDLE)
reg build_req_pending_sys;

// Select NTS based on NDB2 flag
wire [21:0] nts_sel_w = burst_ndb2_sys ? NTS2_REF : NTS1_REF;

// R1: build_req handling — cold start vs chain
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
  build_req_pending_sys <= 1'b0;
  chain_pending_sys <= 1'b0;
  chain_burst_sys <= {BURST_BITS{1'b0}};
 end else if (build_req_sys) begin
  if (tx_busy_sys) begin
   // Builder is active: latch into shadow for seamless chain
   chain_pending_sys <= 1'b1;
   if (burst_type_sys)
    chain_burst_sys <= {TAIL1, PADJ, FC_PAT, sb1_data_sys, STS_REF,
                        bb_data_sys, block2_data_sys, PADJ, TAIL2};
   else
    chain_burst_sys <= {TAIL1, PADJ, block1_data_sys, bb_data_sys[BB_BITS-1:16],
                        nts_sel_w, bb_data_sys[15:0], block2_data_sys, PADJ, TAIL2};
  end else begin
   // Builder is idle: cold start
   build_req_pending_sys <= 1'b1;
  end
 end else begin
  if (sym_en_w && state_sys == S_IDLE)
   build_req_pending_sys <= 1'b0;
  // chain_pending clears when shift register reloads at sym_cnt=254
  if (sym_en_w && state_sys == S_SHIFT && sym_cnt_sys == SYM_LAST && chain_pending_sys)
   chain_pending_sys <= 1'b0;
 end
end

// =============================================================================
// 510-bit burst shift register
// Loaded on build_req (cold start) or from chain shadow at sym_cnt=254.
// burst_sreg[509:508] = current output dibit (MSB = first transmitted).
// =============================================================================
reg [BURST_BITS-1:0] burst_sreg_sys;

// Combinatorial: assemble burst pattern for cold start
wire [BURST_BITS-1:0] sdb_burst_w;
wire [BURST_BITS-1:0] ndb_burst_w;

assign sdb_burst_w = {TAIL1, PADJ, FC_PAT, sb1_data_sys, STS_REF,
                      bb_data_sys, block2_data_sys, PADJ, TAIL2};

assign ndb_burst_w = {TAIL1, PADJ, block1_data_sys, bb_data_sys[BB_BITS-1:16],
                      nts_sel_w, bb_data_sys[15:0], block2_data_sys, PADJ, TAIL2};

// R1: burst_sreg_sys — load on cold start, chain reload, or shift
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  burst_sreg_sys <= {BURST_BITS{1'b0}};
 else if (state_sys == S_IDLE && build_req_sys) begin
  // Cold start: load directly
  if (burst_type_sys)
   burst_sreg_sys <= sdb_burst_w;
  else
   burst_sreg_sys <= ndb_burst_w;
 end else if (sym_en_w && state_sys == S_SHIFT && sym_cnt_sys == SYM_LAST && chain_pending_sys) begin
  // Chain reload: seamless transition to next burst
  burst_sreg_sys <= chain_burst_sys;
 end else if (state_sys == S_SHIFT && sym_en_w)
  burst_sreg_sys <= {burst_sreg_sys[BURST_BITS-3:0], 2'b00};
end

// =============================================================================
// R5: next-state logic (combinatorial)
// =============================================================================
reg [1:0] next_state_sys;

always @(*) begin
 next_state_sys = state_sys;
 case (state_sys)
 S_IDLE: if (build_req_pending_sys) next_state_sys = S_SHIFT;
 S_SHIFT: begin
  if (sym_cnt_sys == SYM_LAST) begin
   if (chain_pending_sys)
    next_state_sys = S_SHIFT; // Stay in S_SHIFT, reload from chain
   else
    next_state_sys = S_DONE;  // No next burst, stop
  end
 end
 S_DONE: next_state_sys = S_IDLE;
 default: next_state_sys = S_IDLE;
 endcase
end

// =============================================================================
// R1: state register
// S_DONE exits immediately (no sym_en gate) so tx_busy deasserts fast.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  state_sys <= S_IDLE;
 else if (state_sys == S_DONE)
  state_sys <= S_IDLE;
 else if (sym_en_w)
  state_sys <= next_state_sys;
end

// =============================================================================
// R1: symbol counter — counts 0..254 during S_SHIFT
// Wraps to 0 on chain reload (sym_cnt=254 + chain_pending).
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  sym_cnt_sys <= 8'd0;
 else if (sym_en_w) begin
  if (state_sys == S_SHIFT && sym_cnt_sys == SYM_LAST && chain_pending_sys)
   sym_cnt_sys <= 8'd0; // Chain: wrap to 0
  else if (state_sys != next_state_sys)
   sym_cnt_sys <= 8'd0;
  else if (state_sys == S_SHIFT)
   sym_cnt_sys <= sym_cnt_sys + 8'd1;
 end
end

// =============================================================================
// R1: tx_dibit_sys — registered output dibit
// Updated on sym_en_w from the shift register MSBs.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_dibit_sys <= 2'b00;
 else if (sym_en_w)
  tx_dibit_sys <= burst_sreg_sys[BURST_BITS-1:BURST_BITS-2];
end

// =============================================================================
// R1: tx_dibit_valid_sys — fires 1 cycle after sym_en_w during S_SHIFT
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_dibit_valid_sys <= 1'b0;
 else
  tx_dibit_valid_sys <= sym_en_w && (state_sys == S_SHIFT);
end

// =============================================================================
// R1: tx_done_sys — 1-cycle pulse on last output symbol
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_done_sys <= 1'b0;
 else
  tx_done_sys <= sym_en_w && (sym_cnt_sys == SYM_LAST) && (state_sys == S_SHIFT);
end

// =============================================================================
// R1: tx_busy_sys — HIGH while burst in progress
// Set on build_req (cold or chain); cleared on S_DONE only.
// During chained bursts, tx_busy stays HIGH continuously.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_busy_sys <= 1'b0;
 else if (state_sys == S_IDLE && build_req_sys)
  tx_busy_sys <= 1'b1;
 else if (state_sys == S_DONE)
  tx_busy_sys <= 1'b0;
end

endmodule
`default_nettype wire
