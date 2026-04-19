// =============================================================================
// Module: tetra_burst_mux
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_mux.v
//
// Description:
// TDMA Burst Multiplexer — selects the burst payload for the current TX
// timeslot and forwards it to tetra_burst_builder.
//
// Supports NDB (Normal Downlink Burst) and SDB (Synchronization Burst).
// 4 independently configurable TX timeslots (0–3).  On each tx_slot_pulse_sys
// the mux samples the slot number, selects the corresponding payload from the
// flat input buses, and asserts build_req_sys to the burst builder.
//
// Burst type per slot (slot_burst_type_sys input):
// - 1'b0: NDB — uses block1/block2/bb inputs
// - 1'b1: SDB — uses sb1/block2(bkn2)/bb inputs
//
// Idle slots: configured as NDB with zero block data; the continuous burst
// format ensures uninterrupted RF output with tail/training symbols.
//
// BB/AACH is shared across all burst types (same register source).
//
// FSM: S_IDLE → S_PENDING → S_REQ → S_WAIT → S_IDLE
//
// Resource estimate: ~60 LUT, ~200 FF, 0 DSP, 0 BRAM
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// Ref: ETSI EN 300 392-2 §4.2 (TDMA Frame Structure)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_mux #(
 parameter BLOCK_BITS = 216, // bits per NDB block (108 symbols × 2)
 parameter BB_BITS = 30, // BB/AACH bits (15 symbols × 2)
 parameter SB1_BITS = 120, // SDB sb1 bits (60 symbols × 2)
 parameter TS_PER_FRAME = 4 // timeslots per frame
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // NDB payload inputs — flat bus (R3: no arrays)
 // slot N occupies bits [N*BLOCK_BITS +: BLOCK_BITS]
 // -------------------------------------------------------------------------
 input wire [4*BLOCK_BITS-1:0] block1_in_sys,
 input wire [4*BLOCK_BITS-1:0] block2_in_sys,

 // -------------------------------------------------------------------------
 // BB/AACH — shared across all burst types (broadcast on every slot)
 // -------------------------------------------------------------------------
 input wire [BB_BITS-1:0] bb_in_sys,

 // -------------------------------------------------------------------------
 // SDB payload inputs (shared across all slots — BS sends same SDB)
 // -------------------------------------------------------------------------
 input wire [SB1_BITS-1:0] sb_sb1_in_sys, // sb1 (60 symbols)
 input wire [BLOCK_BITS-1:0] sb_bkn2_in_sys, // bkn2 (108 symbols)

 // Per-slot enable: bit N = 1 → transmit data; bit N = 0 → transmit NDB zeros
 input wire [3:0] slot_en_sys,

 // Per-slot burst type: 1 bit per slot, packed [3:0]
 // bit N: 0=NDB, 1=SDB
 input wire [3:0] slot_burst_type_sys,

 // Per-slot NDB2 flag: bit N = 1 → NDB2 (NTS2, SCH/HD) on slot N
 input wire [3:0] slot_ndb2_sys,

 // -------------------------------------------------------------------------
 // TX frame timing
 // -------------------------------------------------------------------------
 input wire [1:0] tx_slot_num_sys,
 input wire tx_slot_pulse_sys,

 // -------------------------------------------------------------------------
 // Burst builder interface
 // -------------------------------------------------------------------------
 output reg [BLOCK_BITS-1:0] build_block1_sys,
 output reg [BLOCK_BITS-1:0] build_block2_sys,
 output reg [BB_BITS-1:0] build_bb_sys,
 output reg [SB1_BITS-1:0] build_sb1_sys,
 output reg build_burst_type_sys, // 0=NDB, 1=SDB
 output reg build_ndb2_sys,      // 0=NDB1, 1=NDB2 (NTS2/SCH/HD)
 output reg build_req_sys,

 // Feedback from burst_builder
 input wire builder_busy_sys,

 // Status
 output wire mux_ready_sys
);

// =============================================================================
// FSM States
// =============================================================================
localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_PENDING = 2'd1;
localparam [1:0] S_REQ = 2'd2;
localparam [1:0] S_WAIT = 2'd3;

// =============================================================================
// Internal registers
// =============================================================================
reg [1:0] state_sys;
reg [1:0] next_state_sys;

reg [1:0] slot_lat_sys;
reg slot_en_lat_sys;
reg burst_type_lat_sys;
reg ndb2_lat_sys;

// =============================================================================
// R5 — Next-state logic (combinatorial)
// =============================================================================
always @(*) begin
 next_state_sys = state_sys;
 case (state_sys)
 S_IDLE: if (tx_slot_pulse_sys) next_state_sys = S_PENDING;
 S_PENDING: next_state_sys = S_REQ; // No wait — builder accepts req while busy (chain)
 S_REQ: next_state_sys = S_IDLE;    // Done — builder latches data immediately
 default: next_state_sys = S_IDLE;
 endcase
end

// R1 — State register
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  state_sys <= S_IDLE;
 else
  state_sys <= next_state_sys;
end

// R1 — slot_lat_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  slot_lat_sys <= 2'd0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
  slot_lat_sys <= tx_slot_num_sys;
end

// R1 — slot_en_lat_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  slot_en_lat_sys <= 1'b0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
  slot_en_lat_sys <= slot_en_sys[tx_slot_num_sys];
end

// R1 — burst_type_lat_sys: 1-bit burst type for current slot
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  burst_type_lat_sys <= 1'b0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
  burst_type_lat_sys <= slot_burst_type_sys[tx_slot_num_sys];
end

// R1 — ndb2_lat_sys: NDB2 flag for current slot
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  ndb2_lat_sys <= 1'b0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
  ndb2_lat_sys <= slot_ndb2_sys[tx_slot_num_sys];
end

// =============================================================================
// Combinatorial payload MUX — selects NDB block data from flat buses
// =============================================================================
reg [BLOCK_BITS-1:0] sel_block1_w;
reg [BLOCK_BITS-1:0] sel_block2_w;

always @(*) begin
 case (slot_lat_sys)
 2'd0: begin
  sel_block1_w = block1_in_sys[ 0*BLOCK_BITS +: BLOCK_BITS];
  sel_block2_w = block2_in_sys[ 0*BLOCK_BITS +: BLOCK_BITS];
 end
 2'd1: begin
  sel_block1_w = block1_in_sys[ 1*BLOCK_BITS +: BLOCK_BITS];
  sel_block2_w = block2_in_sys[ 1*BLOCK_BITS +: BLOCK_BITS];
 end
 2'd2: begin
  sel_block1_w = block1_in_sys[ 2*BLOCK_BITS +: BLOCK_BITS];
  sel_block2_w = block2_in_sys[ 2*BLOCK_BITS +: BLOCK_BITS];
 end
 2'd3: begin
  sel_block1_w = block1_in_sys[ 3*BLOCK_BITS +: BLOCK_BITS];
  sel_block2_w = block2_in_sys[ 3*BLOCK_BITS +: BLOCK_BITS];
 end
 default: begin
  sel_block1_w = {BLOCK_BITS{1'b0}};
  sel_block2_w = {BLOCK_BITS{1'b0}};
 end
 endcase
end

// =============================================================================
// R1 — build_block1_sys (NDB Block 1, only for NDB)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_block1_sys <= {BLOCK_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
  build_block1_sys <= slot_en_lat_sys ? sel_block1_w : {BLOCK_BITS{1'b0}};
end

// =============================================================================
// R1 — build_block2_sys (shared: NDB Block 2 / SDB bkn2)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_block2_sys <= {BLOCK_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING) begin
  if (burst_type_lat_sys) // SDB
   build_block2_sys <= slot_en_lat_sys ? sb_bkn2_in_sys : {BLOCK_BITS{1'b0}};
  else // NDB
   build_block2_sys <= slot_en_lat_sys ? sel_block2_w : {BLOCK_BITS{1'b0}};
 end
end

// =============================================================================
// R1 — build_bb_sys (BB/AACH — always from shared register, broadcast on all)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_bb_sys <= {BB_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
  build_bb_sys <= bb_in_sys;
end

// =============================================================================
// R1 — build_sb1_sys (SDB sb1 — shared across slots)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_sb1_sys <= {SB1_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
  build_sb1_sys <= slot_en_lat_sys ? sb_sb1_in_sys : {SB1_BITS{1'b0}};
end

// =============================================================================
// R1 — build_burst_type_sys
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_burst_type_sys <= 1'b0;
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
  build_burst_type_sys <= burst_type_lat_sys;
end

// =============================================================================
// R1 — build_ndb2_sys: NDB2 flag to burst builder
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_ndb2_sys <= 1'b0;
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
  build_ndb2_sys <= ndb2_lat_sys;
end

// =============================================================================
// R1 — build_req_sys: 1-cycle pulse in S_REQ
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  build_req_sys <= 1'b0;
 else
  build_req_sys <= (next_state_sys == S_REQ);
end

// =============================================================================
// mux_ready_sys: HIGH when in S_IDLE
// =============================================================================
assign mux_ready_sys = (state_sys == S_IDLE);

endmodule
`default_nettype wire
