// =============================================================================
// Module: tetra_burst_builder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_builder.v
//
// Description:
// Assembles TETRA bursts (NDB, SB, Idle) from payload data and
// streams them out as a sequential dibit (2-bit symbol) stream.
//
// Supported burst types (burst_type_sys input):
// - 2'b00: NDB (Normal Downlink Burst)
// - 2'b01: SB (Synchronization Burst)
// - 2'b10: Idle Burst
//
// NDB structure (ETSI EN 300 392-2 §9.4.4.3.1):
// ┌─────────┬─────────┬──────────────┬─────────┬───────────────┐
// │ FreqCor │ Block 1 │ Training Seq │ BB/AACH │ Block 2 │
// │ 2 sym │ 108 sym │ 22 sym NTS │ 15 sym │ 108 sym │
// └─────────┴─────────┴──────────────┴─────────┴───────────────┘
// Total: 2 + 108 + 22 + 15 + 108 = 255 symbols per timeslot
//
// SB structure (ETSI EN 300 392-2 §9.4.4.4.2):
// ┌─────────┬─────────┬──────────────┬─────────┬───────────────┐
// │ FreqCor │ bkn1 │ STS │ bb │ bkn2 │
// │ 2 sym │ 120 sym │ 11 sym STS │ 14 sym │ 108 sym │
// └─────────┴─────────┴──────────────┴─────────┴───────────────┘
// Total: 2 + 120 + 11 + 14 + 108 = 255 symbols per timeslot
//
// FreqCorr: fixed pattern 2'b01, 2'b01 (reference phase)
// NTS: Normal Training Sequence (Table 9.11) — same pattern as
// tetra_sync_detect.v NTS_REF for RX/TX symbol alignment.
// STS: Synchronization Training Sequence (Table 9.12) — 11 symbols
//
// Interfaces:
// - build_req_sys: one-cycle pulse, triggers assembly of one burst
// - block1/block2_data_sys: 216-bit payload (NDB: 108 symbols)
// - bkn1_sb_data_sys: 240-bit payload (SB: 120 symbols)
// - bb_data_sys: 30-bit BB/AACH field (NDB: 15 symbols)
// - bb_sb_data_sys: 28-bit BB field (SB: 14 symbols)
// - tx_dibit_sys + tx_dibit_valid_sys: sequential output stream
// - tx_done_sys: one-cycle pulse on last output symbol
// - tx_busy_sys: HIGH from build_req until tx_done
//
// Pipeline: 1-cycle latency. tx_dibit_valid goes HIGH one cycle after
// entering S_FREQCOR; tx_done aligns with last valid symbol.
//
// Clock domain: _sys (100 MHz system clock)
// Reset: Active-low asynchronous rst_n_sys
//
// FSM: 3-block structure per R5 (state reg, next-state comb, output reg)
//
// Resource estimate: LUT ~80 FF ~520 DSP 0 BRAM 0
// (Shift registers: FC 4-bit, Block1 216/240-bit, Train 22/44-bit, BB 28/30-bit, Block2 216-bit)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//
// Ref: ETSI EN 300 392-2 §9.4.4.3.1 (NDB), §9.4.4.4.2 (SB), §9.4.4.4.3 (NTS/STS Tables)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_builder #(
 parameter BLOCK_BITS = 216, // bits per NDB block (108 symbols × 2)
 parameter BB_BITS = 30, // BB/AACH field bits (15 symbols × 2) for NDB
 parameter BB_SB_BITS = 28, // BB field bits (14 symbols × 2) for SB
 parameter BKN1_SB_BITS = 240 // bkn1 field bits (120 symbols × 2) for SB
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // Payload inputs for NDB (latched on build_req_sys pulse)
 input wire [BLOCK_BITS-1:0] block1_data_sys, // Block 1 (NDB), MSB = first symbol
 input wire [BLOCK_BITS-1:0] block2_data_sys, // Block 2 (NDB/SB), MSB = first symbol
 input wire [BB_BITS-1:0] bb_data_sys, // BB/AACH (NDB), MSB = first symbol

 // Payload inputs for SB (latched on build_req_sys pulse)
 input wire [BKN1_SB_BITS-1:0] bkn1_sb_data_sys, // bkn1 (SB), MSB = first symbol
 input wire [BB_SB_BITS-1:0] bb_sb_data_sys, // bb (SB), MSB = first symbol

 input wire [1:0] burst_type_sys, // 0=NDB, 1=SB, 2=Idle

 // Control
 input wire build_req_sys, // 1-cycle pulse: start burst

 // Output symbol stream (one dibit per clock when tx_dibit_valid_sys = 1)
 output reg [1:0] tx_dibit_sys,
 output reg tx_dibit_valid_sys,
 output reg tx_done_sys, // 1-cycle pulse on last symbol
 output reg tx_busy_sys // HIGH while burst in progress
);

// =============================================================================
// Constants
// =============================================================================
// FSM states (shared for NDB and SB, different counter limits)
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_FREQCOR = 3'd1; // 2 symbols (NDB and SB)
localparam [2:0] S_BLOCK1 = 3'd2; // NDB: 108 symbols, SB: 120 symbols
localparam [2:0] S_TRAIN = 3'd3; // NDB: 22 symbols (NTS), SB: 38 symbols (STS)
localparam [2:0] S_BB = 3'd4; // NDB: 15 symbols, SB: 14 symbols
localparam [2:0] S_BLOCK2 = 3'd5; // 108 symbols (NDB and SB)
localparam [2:0] S_DONE = 3'd6;

// Symbol count thresholds for NDB (count from 0 to MAX inclusive)
localparam [7:0] CNT_FC_MAX = 8'd1; // 2 symbols: 0..1
localparam [7:0] CNT_BLK1_NDB_MAX = 8'd107; // 108 symbols: 0..107
localparam [7:0] CNT_NTS_MAX = 8'd21; // 22 symbols: 0..21
localparam [7:0] CNT_BB_NDB_MAX = 8'd14; // 15 symbols: 0..14

// Symbol count thresholds for SB
localparam [7:0] CNT_BKN1_SB_MAX = 8'd119; // 120 symbols: 0..119
localparam [7:0] CNT_STS_MAX = 8'd37; // 38 symbols: 0..37
localparam [7:0] CNT_BLK2_SB_MAX = 8'd80; // SB bkn2: 81 symbols: 0..80
localparam [7:0] CNT_BB_SB_MAX = 8'd13; // 14 symbols: 0..13

// Common counter limit (BLOCK2 is 108 symbols in both NDB and SB)
localparam [7:0] CNT_BLK2_MAX = 8'd107; // 108 symbols: 0..107

// Symbol rate divider: 100 MHz / 5555 cycles = 18.004 kHz (< 0.025% error)
// 255 symbols × 5555 cycles = 1,416,525 cycles < TX_SLOT_CYCLES=1,416,667 → fits in one slot
localparam [12:0] SYM_DIV = 13'd5554;   // counter wraps 0..5554 = 5555 cycles/symbol

// Frequency correction pattern — 2 symbols of dibit 01 (reference phase 0)
localparam [3:0] FC_PAT = 4'b01_01;

// Normal Training Sequence — Table 9.11, 22 symbols (44 bits)
// Bit ordering: [43:42] = symbol 0 (first transmitted, oldest)
// [1:0] = symbol 21 (last transmitted, newest)
// MUST match tetra_sync_detect.v NTS_REF for correct RX correlation.
localparam [43:0] NTS_REF = {
 2'b00, 2'b11, 2'b01, 2'b10, 2'b01, 2'b11, 2'b10, 2'b10,
 2'b00, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01, 2'b10, 2'b00,
 2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b01
};

// Synchronization Training Sequence — Table 9.14, 38 symbols (76 bits)
// Bit ordering: [75:74] = symbol 0 (first transmitted, oldest)
// [1:0]  = symbol 37 (last transmitted, newest)
// MUST match tetra_sync_detect.v STS_REF for correct loopback correlation.
// SB structure: FC(2) + bkn1(120) + STS(38) + bb(14) + bkn2(81) = 255
localparam [75:0] STS_REF = {
 2'b01, 2'b11, 2'b10, 2'b10, 2'b00, 2'b11, 2'b01, 2'b00,
 2'b10, 2'b01, 2'b10, 2'b11, 2'b01, 2'b00, 2'b10, 2'b11,
 2'b01, 2'b00, 2'b10, 2'b01, 2'b10, 2'b11, 2'b00, 2'b10,
 2'b01, 2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b10, 2'b10,
 2'b01, 2'b11, 2'b01, 2'b00, 2'b10, 2'b11
};

// =============================================================================
// Symbol rate divider — generates sym_en_w at ~18 kHz from 100 MHz clk_sys
// sym_en_w fires once every SYM_DIV+1 = 5555 cycles while tx_busy_sys = 1.
// All FSM state advances, counter increments, and SR shifts are gated on sym_en_w
// so the output dibit stream is rate-limited to ~18 kHz regardless of build_req
// timing.  tx_busy_sys is set immediately on build_req (for burst_mux handshake)
// and cleared immediately when state reaches S_DONE (no sym_en gate on DONE exit).
// =============================================================================
reg [12:0] sym_div_sys;
wire       sym_en_w;

// R1: symbol-rate divider counter — runs only while tx_busy
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  sym_div_sys <= 13'd0;
 else if (!tx_busy_sys)
  sym_div_sys <= 13'd0;  // reset when idle
 else if (sym_div_sys == SYM_DIV)
  sym_div_sys <= 13'd0;  // wrap
 else
  sym_div_sys <= sym_div_sys + 13'd1;
end

// sym_en_w: HIGH for exactly 1 clk_sys cycle per symbol period
assign sym_en_w = tx_busy_sys && (sym_div_sys == 13'd0);

// =============================================================================
// FSM state, counter, and burst type latch
// =============================================================================
reg [2:0] state_sys;
reg [2:0] next_state_sys;
reg [7:0] sym_cnt_sys;
reg [1:0] burst_type_latched_sys; // Latch burst_type on build_req

// build_req_pending_sys: latches build_req_sys so next_state_sys sees it at the
// first sym_en_w pulse (which fires 1 cycle after build_req, when build_req=0).
// Clears when sym_en_w grants the S_IDLE→S_FREQCOR transition.
reg build_req_pending_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_req_pending_sys <= 1'b0;
 else if (build_req_sys)
  build_req_pending_sys <= 1'b1;
 else if (sym_en_w && state_sys == S_IDLE)
  build_req_pending_sys <= 1'b0;
end

// =============================================================================
// Shift registers (flat, no arrays — R3)
// All loaded at build_req_sys pulse; each shifts during its active state.
// MSB pair [N-1:N-2] = current output symbol; shift left 2 each clock.
// =============================================================================
reg [3:0] fc_sreg_sys;
reg [BKN1_SB_BITS-1:0] block1_sreg_sys; // 240-bit max for SB, upper bits unused for NDB
reg [75:0] train_sreg_sys; // 76-bit max for STS (NTS is 44-bit, zero-extended)
reg [BB_BITS-1:0] bb_sreg_sys; // 30-bit max for NDB (SB is 28-bit, zero-extended)
reg [BLOCK_BITS-1:0] block2_sreg_sys;

// =============================================================================
// Combinatorial: dibit mux (R5 — output logic block)
// =============================================================================
reg [1:0] mux_dibit_w;

always @(*) begin
 case (state_sys)
 S_FREQCOR: mux_dibit_w = fc_sreg_sys[3:2];
 S_BLOCK1: begin
 if (burst_type_latched_sys == 2'b01) // SB
 mux_dibit_w = block1_sreg_sys[BKN1_SB_BITS-1:BKN1_SB_BITS-2];
 else // NDB
 mux_dibit_w = block1_sreg_sys[BKN1_SB_BITS-1:BKN1_SB_BITS-2];
 end
 S_TRAIN: mux_dibit_w = train_sreg_sys[75:74];
 S_BB: begin
 if (burst_type_latched_sys == 2'b01) // SB
 mux_dibit_w = bb_sreg_sys[BB_SB_BITS-1:BB_SB_BITS-2];
 else // NDB
 mux_dibit_w = bb_sreg_sys[BB_BITS-1:BB_BITS-2];
 end
 S_BLOCK2: mux_dibit_w = block2_sreg_sys[BLOCK_BITS-1:BLOCK_BITS-2];
 default: mux_dibit_w = 2'b00;
 endcase
end

// =============================================================================
// Combinatorial: next-state logic (R5 — next-state block)
// Conditional on burst_type — different counter limits for NDB vs SB
// =============================================================================
always @(*) begin
 next_state_sys = state_sys;
 case (state_sys)
 S_IDLE: if (build_req_pending_sys) next_state_sys = S_FREQCOR;
 S_FREQCOR: if (sym_cnt_sys == CNT_FC_MAX) next_state_sys = S_BLOCK1;
 S_BLOCK1: begin
 if (burst_type_latched_sys == 2'b01) begin // SB
 if (sym_cnt_sys == CNT_BKN1_SB_MAX) next_state_sys = S_TRAIN;
 end else begin // NDB
 if (sym_cnt_sys == CNT_BLK1_NDB_MAX) next_state_sys = S_TRAIN;
 end
 end
 S_TRAIN: begin
 if (burst_type_latched_sys == 2'b01) begin // SB (STS)
 if (sym_cnt_sys == CNT_STS_MAX) next_state_sys = S_BB;
 end else begin // NDB (NTS)
 if (sym_cnt_sys == CNT_NTS_MAX) next_state_sys = S_BB;
 end
 end
 S_BB: begin
 if (burst_type_latched_sys == 2'b01) begin // SB
 if (sym_cnt_sys == CNT_BB_SB_MAX) next_state_sys = S_BLOCK2;
 end else begin // NDB
 if (sym_cnt_sys == CNT_BB_NDB_MAX) next_state_sys = S_BLOCK2;
 end
 end
 S_BLOCK2: begin
 if (burst_type_latched_sys == 2'b01) begin // SB: bkn2 = 81 symbols
 if (sym_cnt_sys == CNT_BLK2_SB_MAX) next_state_sys = S_DONE;
 end else begin // NDB: block2 = 108 symbols
 if (sym_cnt_sys == CNT_BLK2_MAX) next_state_sys = S_DONE;
 end
 end
 S_DONE: next_state_sys = S_IDLE;
 default: next_state_sys = S_IDLE;
 endcase
end

// =============================================================================
// R1: state register (R5 — state register block)
// Advances on sym_en_w (≈18 kHz) except S_DONE which exits to S_IDLE
// immediately (no sym_en gate) so tx_busy_sys deasserts quickly for burst_mux.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  state_sys <= S_IDLE;
 else if (state_sys == S_DONE)
  state_sys <= S_IDLE;        // immediate — clears tx_busy fast
 else if (sym_en_w)
  state_sys <= next_state_sys;
end

// =============================================================================
// R1: burst type latch
// Latches burst_type_sys on build_req to keep it stable during burst assembly.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 burst_type_latched_sys <= 2'b00;
 else if (state_sys == S_IDLE && build_req_sys)
 burst_type_latched_sys <= burst_type_sys;
end

// =============================================================================
// R1: symbol counter
// Resets to 0 on any state transition; increments while in active states.
// Gated on sym_en_w so it advances at ≈18 kHz only.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  sym_cnt_sys <= 8'd0;
 else if (sym_en_w) begin
  if (state_sys != next_state_sys)
   sym_cnt_sys <= 8'd0;
  else if (state_sys != S_IDLE && state_sys != S_DONE)
   sym_cnt_sys <= sym_cnt_sys + 8'd1;
 end
end

// =============================================================================
// R1: fc_sreg_sys
// Loads FC_PAT on build_req; shifts MSB-first during S_FREQCOR.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 fc_sreg_sys <= 4'b0000;
 else if (state_sys == S_IDLE && build_req_sys)
 fc_sreg_sys <= FC_PAT;
 else if (state_sys == S_FREQCOR && sym_en_w)
 fc_sreg_sys <= {fc_sreg_sys[1:0], 2'b00};
end

// =============================================================================
// R1: block1_sreg_sys
// Loads Block 1 (NDB) or bkn1 (SB) on build_req; shifts MSB-first during S_BLOCK1.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 block1_sreg_sys <= {BKN1_SB_BITS{1'b0}};
 else if (state_sys == S_IDLE && build_req_sys) begin
 if (burst_type_sys == 2'b01) // SB
 block1_sreg_sys <= bkn1_sb_data_sys;
 else // NDB or Idle
 block1_sreg_sys <= {{BKN1_SB_BITS-BLOCK_BITS{1'b0}}, block1_data_sys};
 end else if (state_sys == S_BLOCK1 && sym_en_w) begin
 block1_sreg_sys <= {block1_sreg_sys[BKN1_SB_BITS-3:0], 2'b00};
 end
end

// =============================================================================
// R1: train_sreg_sys
// Loads NTS_REF or STS_REF on build_req; shifts MSB-first during S_TRAIN.
// NTS is zero-extended to 76 bits for uniform shifting.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 train_sreg_sys <= 76'd0;
 else if (state_sys == S_IDLE && build_req_sys) begin
 if (burst_type_sys == 2'b01) // SB: STS (38 symbols, 76 bits)
 train_sreg_sys <= STS_REF;
 else // NDB: NTS (22 symbols) zero-extended to 76 bits
 train_sreg_sys <= {{32{1'b0}}, NTS_REF};
 end else if (state_sys == S_TRAIN && sym_en_w)
 train_sreg_sys <= {train_sreg_sys[73:0], 2'b00};
end

// =============================================================================
// R1: bb_sreg_sys
// Loads BB data on build_req; shifts MSB-first during S_BB.
// SB bb is zero-extended to 30 bits for uniform shifting.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 bb_sreg_sys <= {BB_BITS{1'b0}};
 else if (state_sys == S_IDLE && build_req_sys) begin
 if (burst_type_sys == 2'b01) // SB: 14 symbols (28 bits)
 bb_sreg_sys <= {{BB_BITS-BB_SB_BITS{1'b0}}, bb_sb_data_sys};
 else // NDB: 15 symbols (30 bits)
 bb_sreg_sys <= bb_data_sys;
 end else if (state_sys == S_BB && sym_en_w)
 bb_sreg_sys <= {bb_sreg_sys[BB_BITS-3:0], 2'b00};
end

// =============================================================================
// R1: block2_sreg_sys
// Loads Block 2 on build_req; shifts MSB-first during S_BLOCK2.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 block2_sreg_sys <= {BLOCK_BITS{1'b0}};
 else if (state_sys == S_IDLE && build_req_sys)
 block2_sreg_sys <= block2_data_sys;
 else if (state_sys == S_BLOCK2 && sym_en_w)
 block2_sreg_sys <= {block2_sreg_sys[BLOCK_BITS-3:0], 2'b00};
end

// =============================================================================
// R1: tx_dibit_sys — registered output dibit
// Updated only on sym_en_w so the held value is stable for the full symbol period.
// Downstream modulator samples dibit_in on the cycle that dibit_valid fires
// (1 cycle after sym_en), at which point tx_dibit_sys holds the correct value.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_dibit_sys <= 2'b00;
 else if (sym_en_w)
  tx_dibit_sys <= mux_dibit_w;
end

// =============================================================================
// R1: tx_dibit_valid_sys
// Fires 1 cycle after sym_en_w when state is an active output state.
// Total 255 pulses per burst at ≈18 kHz, exactly one per output symbol.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_dibit_valid_sys <= 1'b0;
 else
  tx_dibit_valid_sys <= sym_en_w && ((state_sys == S_FREQCOR) ||
                                     (state_sys == S_BLOCK1)  ||
                                     (state_sys == S_TRAIN)   ||
                                     (state_sys == S_BB)      ||
                                     (state_sys == S_BLOCK2));
end

// =============================================================================
// R1: tx_done_sys — 1-cycle pulse on last output symbol
// Fires 1 cycle after the sym_en_w that triggers the S_DONE transition.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  tx_done_sys <= 1'b0;
 else
  tx_done_sys <= sym_en_w && (next_state_sys == S_DONE);
end

// =============================================================================
// R1: tx_busy_sys — HIGH while burst in progress
// Set immediately on build_req (1-cycle pulse) so burst_mux enters S_WAIT.
// Cleared immediately when state reaches S_DONE (no sym_en gate) so burst_mux
// returns to S_IDLE without waiting an extra symbol period.
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
