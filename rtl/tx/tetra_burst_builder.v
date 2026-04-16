// =============================================================================
// Module: tetra_burst_builder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_builder.v
//
// Description:
// Assembles TETRA Continuous Downlink Bursts (NDB, SDB) and streams them
// out as a sequential dibit (2-bit symbol) stream at ~18 kHz symbol rate.
//
// Implements ETSI EN 300 392-2 §9.4.4.2.5 (Normal Continuous Downlink Burst)
// and §9.4.4.2.6 (Synchronization Continuous Downlink Burst).
//
// Architecture: single 510-bit shift register loaded with the complete
// pre-assembled burst on build_req, then shifted out MSB-first at the
// symbol rate.  This replaces the previous multi-state FSM with a trivial
// IDLE → SHIFT → DONE state machine.
//
// SDB structure (§9.4.4.2.6, 255 symbols = 510 bits):
// ┌───────┬────┬─────────┬──────┬─────┬────┬───────┬────┬───────┐
// │ Tail1 │ HC │ FreqCor │ sb1  │ STS │ bb │ bkn2  │ HD │ Tail2 │
// │ 6 sym │ 1  │ 40 sym  │60sym │19sym│15s │108 sym│ 1  │ 5 sym │
// └───────┴────┴─────────┴──────┴─────┴────┴───────┴────┴───────┘
//
// NDB structure (§9.4.4.2.5, 255 symbols = 510 bits):
// ┌───────┬────┬─────────┬──────┬─────┬──────┬─────────┬────┬───────┐
// │ Tail1 │ HA │  blk1   │ bb1  │ NTS │ bb2  │  blk2   │ HB │ Tail2 │
// │ 6 sym │ 1  │ 108 sym │ 7sym │11sym│ 8sym │ 108 sym │ 1  │ 5 sym │
// └───────┴────┴─────────┴──────┴─────┴──────┴─────────┴────┴───────┘
//
// Tail symbols: from NTS q-sequence (§9.4.4.3.2) for inter-slot continuity.
// Phase adjustment bits (HA/HB/HC/HD): set to 00 (placeholder).
// Frequency correction: 40-symbol pattern (§9.4.4.3.1).
//
// Interfaces:
// - build_req_sys: one-cycle pulse, triggers assembly of one burst
// - block1/block2_data_sys: 216-bit NDB payload (108 symbols each)
// - sb1_data_sys: 120-bit SDB sb1 payload (60 symbols)
// - bb_data_sys: 30-bit BB/AACH field (15 symbols, shared NDB/SDB)
// - tx_dibit_sys + tx_dibit_valid_sys: sequential output stream
// - tx_done_sys: one-cycle pulse on last output symbol
// - tx_busy_sys: HIGH from build_req until tx_done
//
// Pipeline: 1-cycle latency. tx_dibit_valid goes HIGH one cycle after
// the first sym_en_w; tx_done aligns with last valid symbol.
//
// Clock domain: _sys (100 MHz system clock)
// Reset: Active-low asynchronous rst_n_sys
//
// Resource estimate: LUT ~180 FF ~530 DSP 0 BRAM 0
// (510-bit shift register + assembly MUX + sym_div counter)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//
// Ref: ETSI EN 300 392-2 §9.4.4.2.5 (NDB cont.), §9.4.4.2.6 (SDB cont.)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_builder #(
 parameter BLOCK_BITS = 216, // bits per NDB block (108 symbols × 2)
 parameter BB_BITS = 30, // BB/AACH field bits (15 symbols × 2)
 parameter SB1_BITS = 120, // SDB sb1 field bits (60 symbols × 2)
 parameter SYM_DIV = 13'd5554 // counter wraps 0..5554 = 5555 cycles/symbol
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // NDB payload inputs (latched on build_req_sys pulse)
 input wire [BLOCK_BITS-1:0] block1_data_sys, // Block 1 (NDB), MSB = first symbol
 input wire [BLOCK_BITS-1:0] block2_data_sys, // Block 2 (NDB/SDB bkn2), MSB = first symbol
 input wire [BB_BITS-1:0] bb_data_sys, // BB/AACH (shared NDB/SDB), MSB = first symbol

 // SDB payload input (latched on build_req_sys pulse)
 input wire [SB1_BITS-1:0] sb1_data_sys, // sb1 (SDB), MSB = first symbol

 input wire burst_type_sys, // 0=NDB, 1=SDB

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

// =============================================================================
// Symbol rate divider — generates sym_en_w at ~18 kHz from 100 MHz clk_sys
// =============================================================================
reg [12:0] sym_div_sys;
wire       sym_en_w;

// R1: symbol-rate divider counter — runs only while tx_busy
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  sym_div_sys <= 13'd0;
 else if (!tx_busy_sys)
  sym_div_sys <= 13'd0;
 else if (sym_div_sys == SYM_DIV)
  sym_div_sys <= 13'd0;
 else
  sym_div_sys <= sym_div_sys + 13'd1;
end

assign sym_en_w = tx_busy_sys && (sym_div_sys == 13'd0);

// =============================================================================
// FSM state and symbol counter
// =============================================================================
reg [1:0] state_sys;
reg [7:0] sym_cnt_sys;

// build_req_pending_sys: latches build_req_sys so next_state sees it at the
// first sym_en_w pulse.  Clears when sym_en_w fires in S_IDLE.
reg build_req_pending_sys;

// R1: build_req_pending
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_req_pending_sys <= 1'b0;
 else if (build_req_sys)
  build_req_pending_sys <= 1'b1;
 else if (sym_en_w && state_sys == S_IDLE)
  build_req_pending_sys <= 1'b0;
end

// =============================================================================
// 510-bit burst shift register
// Loaded on build_req_sys; shifted left 2 on each sym_en_w during S_SHIFT.
// burst_sreg[509:508] = current output dibit (MSB = first transmitted).
// =============================================================================
reg [BURST_BITS-1:0] burst_sreg_sys;

// Combinatorial: assemble NDB or SDB burst pattern
// Both patterns are exactly 510 bits:
//   SDB: TAIL1(12) + HC(2) + FC(80) + sb1(120) + STS(38) + bb(30) + bkn2(216) + HD(2) + TAIL2(10)
//   NDB: TAIL1(12) + HA(2) + blk1(216) + bb1(14) + NTS(22) + bb2(16) + blk2(216) + HA(2) + TAIL2(10)
wire [BURST_BITS-1:0] sdb_burst_w;
wire [BURST_BITS-1:0] ndb_burst_w;

assign sdb_burst_w = {TAIL1, PADJ, FC_PAT, sb1_data_sys, STS_REF,
                      bb_data_sys, block2_data_sys, PADJ, TAIL2};

assign ndb_burst_w = {TAIL1, PADJ, block1_data_sys, bb_data_sys[BB_BITS-1:16],
                      NTS1_REF, bb_data_sys[15:0], block2_data_sys, PADJ, TAIL2};

// R1: burst_sreg_sys — load on build_req, shift during S_SHIFT
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  burst_sreg_sys <= {BURST_BITS{1'b0}};
 else if (state_sys == S_IDLE && build_req_sys) begin
  if (burst_type_sys)
   burst_sreg_sys <= sdb_burst_w;
  else
   burst_sreg_sys <= ndb_burst_w;
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
 S_SHIFT: if (sym_cnt_sys == SYM_LAST) next_state_sys = S_DONE;
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
// Resets on state transition; increments on sym_en_w while shifting.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  sym_cnt_sys <= 8'd0;
 else if (sym_en_w) begin
  if (state_sys != next_state_sys)
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
  tx_done_sys <= sym_en_w && (next_state_sys == S_DONE);
end

// =============================================================================
// R1: tx_busy_sys — HIGH while burst in progress
// Set immediately on build_req; cleared on S_DONE (no sym_en gate).
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
