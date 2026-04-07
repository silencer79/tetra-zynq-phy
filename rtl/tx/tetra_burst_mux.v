// =============================================================================
// Module: tetra_burst_mux
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_mux.v
//
// Description:
// TDMA Burst Multiplexer — selects the burst payload for the current TX
// timeslot and forwards it to tetra_burst_builder.
//
// Supports NDB (Normal Downlink Burst), SB (Synchronization Burst), and Idle.
// 4 independently configurable TX timeslots (0–3). On each tx_slot_pulse_sys
// the mux samples the slot number, selects the corresponding payload from the
// flat input buses, and asserts build_req_sys to the burst builder.
//
// Burst type per slot (slot_burst_type_sys input):
// - 2'b00: NDB — uses block1/block2/bb inputs
// - 2'b01: SB — uses sb_bkn1/sb_bkn2/sb_bb inputs
// - 2'b10: Idle — all zeros
//
// Input buses (flat, R3 compliant — no arrays):
// Slot indexing convention (same for block1/block2/bb):
// bits [(N-1)*W +: W] = slot N data, e.g. block1_in_sys[863:648] = slot 3
//
// Timing:
// tx_slot_pulse_sys must arrive at least 2 clk_sys cycles before the burst
// must begin. build_req_sys is asserted 1 cycle after the pulse if the
// builder is idle, or deferred until builder_busy_sys deasserts.
//
// FSM: S_IDLE → S_PENDING (latch slot) → S_REQ (assert build_req for 1 cycle)
// → S_WAIT (wait for tx_done from builder) → S_IDLE
//
// Resource estimate: ~70 LUT, ~220 FF, 0 DSP, 0 BRAM
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// Ref: ETSI EN 300 392-2 §4.2 (TDMA Frame Structure), §9.4.4.4.2 (SB Structure)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_mux #(
 parameter BLOCK_BITS = 216, // bits per NDB block (108 symbols × 2 bit)
 parameter BB_BITS = 30, // BB/AACH field bits (15 symbols × 2 bit)
 parameter BKN1_SB_BITS = 240, // bkn1 bits for SB (120 symbols × 2)
 parameter BB_SB_BITS = 28, // bb bits for SB (14 symbols × 2)
 parameter TS_PER_FRAME = 4 // timeslots per frame (fixed for TETRA V+D)
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // Slot payload inputs (NDB) — flat bus (R3: no arrays)
 // slot N occupies bits [N*BLOCK_BITS +: BLOCK_BITS]
 // -------------------------------------------------------------------------
 input wire [4*BLOCK_BITS-1:0] block1_in_sys,
 input wire [4*BLOCK_BITS-1:0] block2_in_sys,
 input wire [4*BB_BITS-1:0] bb_in_sys,

 // -------------------------------------------------------------------------
 // SB payload inputs (shared across all slots — BS sends same SB on all)
 // -------------------------------------------------------------------------
 input wire [BKN1_SB_BITS-1:0] sb_bkn1_in_sys,
 input wire [BLOCK_BITS-1:0] sb_bkn2_in_sys,
 input wire [BB_SB_BITS-1:0] sb_bb_in_sys,

 // Per-slot enable: bit N = 1 → transmit; bit N = 0 → transmit Idle
 input wire [3:0] slot_en_sys,

 // Per-slot burst type: byte with 2 bits per slot [1:0]=slot0, [3:2]=slot1, ...
 // 0=NDB, 1=SB, 2=Idle, 3=reserved
 input wire [7:0] slot_burst_type_sys,

 // -------------------------------------------------------------------------
 // TX frame timing (driven by frame_counter / scheduler)
 // -------------------------------------------------------------------------
 input wire [1:0] tx_slot_num_sys, // Current TX slot (0–3)
 input wire tx_slot_pulse_sys, // 1-cycle pulse: start slot

 // -------------------------------------------------------------------------
 // Burst builder interface (NDB outputs)
 // -------------------------------------------------------------------------
 output reg [BLOCK_BITS-1:0] build_block1_sys,
 output reg [BLOCK_BITS-1:0] build_block2_sys,
 output reg [BB_BITS-1:0] build_bb_sys,

 // SB outputs
 output reg [BKN1_SB_BITS-1:0] build_bkn1_sb_sys,
 output reg [BLOCK_BITS-1:0] build_bkn2_sb_sys,
 output reg [BB_SB_BITS-1:0] build_bb_sb_sys,

 output reg [1:0] build_burst_type_sys,
 output reg build_req_sys,

 // Feedback from burst_builder
 input wire builder_busy_sys, // burst_builder.tx_busy_sys

 // -------------------------------------------------------------------------
 // Status
 // -------------------------------------------------------------------------
 output wire mux_ready_sys // HIGH when mux can accept new slot pulse
);

// =============================================================================
// FSM States
// =============================================================================
localparam [1:0] S_IDLE = 2'd0; // Waiting for tx_slot_pulse_sys
localparam [1:0] S_PENDING = 2'd1; // Slot latched; waiting for builder idle
localparam [1:0] S_REQ = 2'd2; // Assert build_req for 1 cycle
localparam [1:0] S_WAIT = 2'd3; // Wait for builder to go busy, then idle

// =============================================================================
// Internal registers
// =============================================================================
reg [1:0] state_sys;
reg [1:0] next_state_sys;

// Latched slot number, enable flag, and burst type (set in S_IDLE on pulse)
reg [1:0] slot_lat_sys;
reg slot_en_lat_sys;
reg [1:0] burst_type_lat_sys;

// =============================================================================
// R5 — Next-state logic (combinatorial)
// =============================================================================
always @(*) begin
 next_state_sys = state_sys;
 case (state_sys)
 S_IDLE: if (tx_slot_pulse_sys) next_state_sys = S_PENDING;
 S_PENDING: if (!builder_busy_sys) next_state_sys = S_REQ;
 S_REQ: next_state_sys = S_WAIT;
 S_WAIT: if (!builder_busy_sys) next_state_sys = S_IDLE;
 default: next_state_sys = S_IDLE;
 endcase
end

// =============================================================================
// R1 — State register
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 state_sys <= S_IDLE;
 else
 state_sys <= next_state_sys;
end

// =============================================================================
// R1 — slot_lat_sys: latch slot number on tx_slot_pulse_sys
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 slot_lat_sys <= 2'd0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
 slot_lat_sys <= tx_slot_num_sys;
end

// =============================================================================
// R1 — slot_en_lat_sys: latch slot-enable flag on tx_slot_pulse_sys
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 slot_en_lat_sys <= 1'b0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys)
 slot_en_lat_sys <= slot_en_sys[tx_slot_num_sys];
end

// =============================================================================
// R1 — burst_type_lat_sys: extract 2-bit burst type for current slot
// slot_burst_type_sys byte layout: [1:0]=slot0, [3:2]=slot1, [5:4]=slot2, [7:6]=slot3
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 burst_type_lat_sys <= 2'd0;
 else if (state_sys == S_IDLE && tx_slot_pulse_sys) begin
 case (tx_slot_num_sys)
 2'd0: burst_type_lat_sys <= slot_burst_type_sys[1:0];
 2'd1: burst_type_lat_sys <= slot_burst_type_sys[3:2];
 2'd2: burst_type_lat_sys <= slot_burst_type_sys[5:4];
 2'd3: burst_type_lat_sys <= slot_burst_type_sys[7:6];
 default: burst_type_lat_sys <= 2'd0;
 endcase
 end
end

// =============================================================================
// Combinatorial payload MUX — selects from flat buses using slot_lat_sys
// slot N → bits [N*WIDTH +: WIDTH]
// R3: unrolled case MUX
// =============================================================================
reg [BLOCK_BITS-1:0] sel_block1_w;
reg [BLOCK_BITS-1:0] sel_block2_w;
reg [BB_BITS-1:0] sel_bb_w;

always @(*) begin
 case (slot_lat_sys)
 2'd0: begin
 sel_block1_w = block1_in_sys[ 0*BLOCK_BITS +: BLOCK_BITS];
 sel_block2_w = block2_in_sys[ 0*BLOCK_BITS +: BLOCK_BITS];
 sel_bb_w = bb_in_sys [ 0*BB_BITS +: BB_BITS ];
 end
 2'd1: begin
 sel_block1_w = block1_in_sys[ 1*BLOCK_BITS +: BLOCK_BITS];
 sel_block2_w = block2_in_sys[ 1*BLOCK_BITS +: BLOCK_BITS];
 sel_bb_w = bb_in_sys [ 1*BB_BITS +: BB_BITS ];
 end
 2'd2: begin
 sel_block1_w = block1_in_sys[ 2*BLOCK_BITS +: BLOCK_BITS];
 sel_block2_w = block2_in_sys[ 2*BLOCK_BITS +: BLOCK_BITS];
 sel_bb_w = bb_in_sys [ 2*BB_BITS +: BB_BITS ];
 end
 2'd3: begin
 sel_block1_w = block1_in_sys[ 3*BLOCK_BITS +: BLOCK_BITS];
 sel_block2_w = block2_in_sys[ 3*BLOCK_BITS +: BLOCK_BITS];
 sel_bb_w = bb_in_sys [ 3*BB_BITS +: BB_BITS ];
 end
 default: begin
 sel_block1_w = {BLOCK_BITS{1'b0}};
 sel_block2_w = {BLOCK_BITS{1'b0}};
 sel_bb_w = {BB_BITS{1'b0}};
 end
 endcase
end

// =============================================================================
// R1 — build_block1_sys / build_block2_sys / build_bb_sys (NDB data)
// Latch on transition to S_REQ
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_block1_sys <= {BLOCK_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_block1_sys <= slot_en_lat_sys ? sel_block1_w : {BLOCK_BITS{1'b0}};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_block2_sys <= {BLOCK_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_block2_sys <= slot_en_lat_sys ? sel_block2_w : {BLOCK_BITS{1'b0}};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_bb_sys <= {BB_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_bb_sys <= slot_en_lat_sys ? sel_bb_w : {BB_BITS{1'b0}};
end

// =============================================================================
// R1 — build_bkn1_sb_sys / build_bkn2_sb_sys / build_bb_sb_sys (SB data)
// Latch on transition to S_REQ (SB data is shared across slots)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_bkn1_sb_sys <= {BKN1_SB_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_bkn1_sb_sys <= slot_en_lat_sys ? sb_bkn1_in_sys : {BKN1_SB_BITS{1'b0}};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_bkn2_sb_sys <= {BLOCK_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_bkn2_sb_sys <= slot_en_lat_sys ? sb_bkn2_in_sys : {BLOCK_BITS{1'b0}};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_bb_sb_sys <= {BB_SB_BITS{1'b0}};
 else if (next_state_sys == S_REQ && state_sys == S_PENDING)
 build_bb_sb_sys <= slot_en_lat_sys ? sb_bb_in_sys : {BB_SB_BITS{1'b0}};
end

// =============================================================================
// R1 — build_burst_type_sys: 0=NDB, 1=SB, 2=Idle
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 build_burst_type_sys <= 2'd0;
 else if (next_state_sys == S_REQ && state_sys == S_PENDING) begin
 if (!slot_en_lat_sys)
 build_burst_type_sys <= 2'd2; // Idle
 else
 build_burst_type_sys <= burst_type_lat_sys; // NDB or SB
 end
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
// mux_ready_sys: combinatorial — HIGH when in S_IDLE
// =============================================================================
assign mux_ready_sys = (state_sys == S_IDLE);

endmodule
`default_nettype wire
