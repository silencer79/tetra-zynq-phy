// =============================================================================
// Module:  tetra_burst_mux
// Project: tetra-zynq-phy
// File:    rtl/tx/tetra_burst_mux.v
//
// Description:
//   TDMA Burst Multiplexer — selects the burst payload for the current TX
//   timeslot and forwards it to tetra_burst_builder.
//
//   4 independently configurable TX timeslots (0–3). On each tx_slot_pulse_sys
//   the mux samples the slot number, selects the corresponding payload from the
//   flat input buses, and asserts build_req_sys to the burst builder.
//
//   Idle slots (slot_en bit = 0) still produce a burst (burst_type_sys = 2'd2
//   = Idle), ensuring the TX carrier is continuous as required by TETRA.
//
// Input buses (flat, R3 compliant — no arrays):
//   Slot indexing convention (same for block1/block2/bb):
//     bits [(N-1)*W +: W] = slot N data, e.g. block1_in_sys[863:648] = slot 3
//
// Timing:
//   tx_slot_pulse_sys must arrive at least 2 clk_sys cycles before the burst
//   must begin.  build_req_sys is asserted 1 cycle after the pulse if the
//   builder is idle, or deferred until builder_busy_sys deasserts.
//
// FSM: S_IDLE → S_PENDING (latch slot) → S_REQ (assert build_req for 1 cycle)
//      → S_WAIT (wait for tx_done from builder) → S_IDLE
//
// Resource estimate: ~50 LUT, ~200 FF, 0 DSP, 0 BRAM
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// Ref: ETSI EN 300 392-2 §4.2 (TDMA Frame Structure)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_mux #(
    parameter BLOCK_BITS   = 216,    // bits per NDB block (108 symbols × 2 bit)
    parameter BB_BITS      = 30,     // BB/AACH field bits  (15 symbols × 2 bit)
    parameter TS_PER_FRAME = 4       // timeslots per frame (fixed for TETRA V+D)
)(
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // -------------------------------------------------------------------------
    // Slot payload inputs — flat bus (R3: no arrays)
    // slot N occupies bits [N*BLOCK_BITS +: BLOCK_BITS]
    // slot 0 at [BLOCK_BITS-1:0], slot 3 at [4*BLOCK_BITS-1:3*BLOCK_BITS]
    // -------------------------------------------------------------------------
    input  wire [4*BLOCK_BITS-1:0] block1_in_sys,
    input  wire [4*BLOCK_BITS-1:0] block2_in_sys,
    input  wire [4*BB_BITS-1:0]    bb_in_sys,

    // Per-slot enable: bit N = 1 → transmit NDB; bit N = 0 → transmit Idle
    input  wire [3:0]              slot_en_sys,

    // -------------------------------------------------------------------------
    // TX frame timing (driven by frame_counter / scheduler)
    // -------------------------------------------------------------------------
    input  wire [1:0]              tx_slot_num_sys,   // Current TX slot (0–3)
    input  wire                    tx_slot_pulse_sys, // 1-cycle pulse: start slot

    // -------------------------------------------------------------------------
    // Burst builder interface
    // -------------------------------------------------------------------------
    output reg  [BLOCK_BITS-1:0]   build_block1_sys,
    output reg  [BLOCK_BITS-1:0]   build_block2_sys,
    output reg  [BB_BITS-1:0]      build_bb_sys,
    output reg  [1:0]              build_burst_type_sys,
    output reg                     build_req_sys,

    // Feedback from burst_builder
    input  wire                    builder_busy_sys,  // burst_builder.tx_busy_sys

    // -------------------------------------------------------------------------
    // Status
    // -------------------------------------------------------------------------
    output wire                    mux_ready_sys      // HIGH when mux can accept new slot pulse
);

// =============================================================================
// FSM States
// =============================================================================
localparam [1:0] S_IDLE    = 2'd0;  // Waiting for tx_slot_pulse_sys
localparam [1:0] S_PENDING = 2'd1;  // Slot latched; waiting for builder idle
localparam [1:0] S_REQ     = 2'd2;  // Assert build_req for 1 cycle
localparam [1:0] S_WAIT    = 2'd3;  // Wait for builder to go busy, then idle

// =============================================================================
// Internal registers
// =============================================================================
reg [1:0] state_sys;
reg [1:0] next_state_sys;

// Latched slot number and enable flag (set in S_IDLE on pulse)
reg [1:0] slot_lat_sys;
reg       slot_en_lat_sys;

// =============================================================================
// R5 — Next-state logic (combinatorial)
// =============================================================================
always @(*) begin
    next_state_sys = state_sys;
    case (state_sys)
        S_IDLE:    if (tx_slot_pulse_sys)              next_state_sys = S_PENDING;
        S_PENDING: if (!builder_busy_sys)              next_state_sys = S_REQ;
        S_REQ:                                         next_state_sys = S_WAIT;
        S_WAIT:    if (!builder_busy_sys)              next_state_sys = S_IDLE;
        default:                                       next_state_sys = S_IDLE;
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
// Combinatorial payload MUX — selects from flat buses using slot_lat_sys
// slot N → bits [N*WIDTH +: WIDTH]
// R3: unrolled case MUX (no arrays, no variable part-selects in this block)
// =============================================================================
reg [BLOCK_BITS-1:0] sel_block1_w;
reg [BLOCK_BITS-1:0] sel_block2_w;
reg [BB_BITS-1:0]    sel_bb_w;

always @(*) begin
    case (slot_lat_sys)
        2'd0: begin
            sel_block1_w = block1_in_sys[  0*BLOCK_BITS +: BLOCK_BITS];
            sel_block2_w = block2_in_sys[  0*BLOCK_BITS +: BLOCK_BITS];
            sel_bb_w     = bb_in_sys    [  0*BB_BITS    +: BB_BITS   ];
        end
        2'd1: begin
            sel_block1_w = block1_in_sys[  1*BLOCK_BITS +: BLOCK_BITS];
            sel_block2_w = block2_in_sys[  1*BLOCK_BITS +: BLOCK_BITS];
            sel_bb_w     = bb_in_sys    [  1*BB_BITS    +: BB_BITS   ];
        end
        2'd2: begin
            sel_block1_w = block1_in_sys[  2*BLOCK_BITS +: BLOCK_BITS];
            sel_block2_w = block2_in_sys[  2*BLOCK_BITS +: BLOCK_BITS];
            sel_bb_w     = bb_in_sys    [  2*BB_BITS    +: BB_BITS   ];
        end
        2'd3: begin
            sel_block1_w = block1_in_sys[  3*BLOCK_BITS +: BLOCK_BITS];
            sel_block2_w = block2_in_sys[  3*BLOCK_BITS +: BLOCK_BITS];
            sel_bb_w     = bb_in_sys    [  3*BB_BITS    +: BB_BITS   ];
        end
        default: begin
            sel_block1_w = {BLOCK_BITS{1'b0}};
            sel_block2_w = {BLOCK_BITS{1'b0}};
            sel_bb_w     = {BB_BITS{1'b0}};
        end
    endcase
end

// =============================================================================
// R1 — build_block1_sys: latch payload on transition to S_REQ
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        build_block1_sys <= {BLOCK_BITS{1'b0}};
    else if (next_state_sys == S_REQ && state_sys == S_PENDING)
        build_block1_sys <= slot_en_lat_sys ? sel_block1_w : {BLOCK_BITS{1'b0}};
end

// =============================================================================
// R1 — build_block2_sys
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        build_block2_sys <= {BLOCK_BITS{1'b0}};
    else if (next_state_sys == S_REQ && state_sys == S_PENDING)
        build_block2_sys <= slot_en_lat_sys ? sel_block2_w : {BLOCK_BITS{1'b0}};
end

// =============================================================================
// R1 — build_bb_sys
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        build_bb_sys <= {BB_BITS{1'b0}};
    else if (next_state_sys == S_REQ && state_sys == S_PENDING)
        build_bb_sys <= slot_en_lat_sys ? sel_bb_w : {BB_BITS{1'b0}};
end

// =============================================================================
// R1 — build_burst_type_sys: 0=NDB (active slot), 2=Idle (disabled slot)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        build_burst_type_sys <= 2'd0;
    else if (next_state_sys == S_REQ && state_sys == S_PENDING)
        build_burst_type_sys <= slot_en_lat_sys ? 2'd0 : 2'd2;
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
