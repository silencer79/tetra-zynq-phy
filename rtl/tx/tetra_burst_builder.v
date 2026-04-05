// =============================================================================
// Module:  tetra_burst_builder
// Project: tetra-zynq-phy
// File:    rtl/tx/tetra_burst_builder.v
//
// Description:
//   Assembles a full TETRA Normal Downlink Burst (NDB) from payload data and
//   streams it out as a sequential dibit (2-bit symbol) stream.
//
//   NDB structure (ETSI EN 300 392-2 §9.4.4.3.1):
//   ┌─────────┬─────────┬──────────────┬─────────┬───────────────┐
//   │ FreqCor │ Block 1 │ Training Seq │ BB/AACH │    Block 2    │
//   │ 2 sym   │ 108 sym │  22 sym NTS  │ 15 sym  │   108 sym     │
//   └─────────┴─────────┴──────────────┴─────────┴───────────────┘
//   Total: 2 + 108 + 22 + 15 + 108 = 255 symbols per timeslot
//
//   FreqCorr: fixed pattern 2'b01, 2'b01 (reference phase)
//   NTS: Normal Training Sequence (Table 9.11) — same pattern as
//        tetra_sync_detect.v NTS_REF for RX/TX symbol alignment.
//
// Interfaces:
//   - build_req_sys: one-cycle pulse, triggers assembly of one burst
//   - block1/block2_data_sys: 216-bit payload (108 symbols MSB-first)
//   - bb_data_sys: 30-bit BB/AACH field (15 symbols MSB-first)
//   - tx_dibit_sys + tx_dibit_valid_sys: sequential output stream
//   - tx_done_sys: one-cycle pulse on last output symbol
//   - tx_busy_sys: HIGH from build_req until tx_done
//
// Pipeline: 1-cycle latency. tx_dibit_valid goes HIGH one cycle after
//           entering S_FREQCOR; tx_done aligns with last valid symbol.
//
// Clock domain: _sys (100 MHz system clock)
// Reset:        Active-low asynchronous rst_n_sys
//
// FSM: 3-block structure per R5 (state reg, next-state comb, output reg)
//
// Resource estimate: LUT ~50  FF ~510  DSP 0  BRAM 0
//   (2×216-bit + 44-bit + 30-bit + 4-bit shift registers)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//
// Ref: ETSI EN 300 392-2 §9.4.4.3.1 (NDB), §9.4.4.4.3 (NTS Table 9.11)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_builder #(
    parameter BLOCK_BITS = 216,    // bits per NDB block  (108 symbols × 2)
    parameter BB_BITS    = 30      // BB/AACH field bits  ( 15 symbols × 2)
)(
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // Payload inputs (latched on build_req_sys pulse)
    input  wire [BLOCK_BITS-1:0] block1_data_sys,   // Block 1, MSB = first symbol
    input  wire [BLOCK_BITS-1:0] block2_data_sys,   // Block 2, MSB = first symbol
    input  wire [BB_BITS-1:0]    bb_data_sys,        // BB/AACH, MSB = first symbol
    input  wire [1:0]            burst_type_sys,     // 0=NDB, 1=SB (reserved), 2=Idle

    // Control
    input  wire                  build_req_sys,     // 1-cycle pulse: start burst

    // Output symbol stream (one dibit per clock when tx_dibit_valid_sys = 1)
    output reg  [1:0]            tx_dibit_sys,
    output reg                   tx_dibit_valid_sys,
    output reg                   tx_done_sys,       // 1-cycle pulse on last symbol
    output reg                   tx_busy_sys        // HIGH while burst in progress
);

// =============================================================================
// Constants
// =============================================================================
// FSM states
localparam [2:0] S_IDLE    = 3'd0;
localparam [2:0] S_FREQCOR = 3'd1;   // 2 symbols
localparam [2:0] S_BLOCK1  = 3'd2;   // 108 symbols
localparam [2:0] S_TRAIN   = 3'd3;   // 22 symbols (NTS)
localparam [2:0] S_BB      = 3'd4;   // 15 symbols
localparam [2:0] S_BLOCK2  = 3'd5;   // 108 symbols
localparam [2:0] S_DONE    = 3'd6;

// Symbol count thresholds (count from 0 to MAX inclusive)
localparam [7:0] CNT_FC_MAX  = 8'd1;   // 2 symbols:  0..1
localparam [7:0] CNT_BLK_MAX = 8'd107; // 108 symbols: 0..107
localparam [7:0] CNT_NTS_MAX = 8'd21;  // 22 symbols:  0..21
localparam [7:0] CNT_BB_MAX  = 8'd14;  // 15 symbols:  0..14

// Frequency correction pattern — 2 symbols of dibit 01 (reference phase 0)
localparam [3:0] FC_PAT = 4'b01_01;

// Normal Training Sequence — Table 9.11, 22 symbols (44 bits)
// Bit ordering: [43:42] = symbol 0 (first transmitted, oldest)
//               [1:0]   = symbol 21 (last transmitted, newest)
// MUST match tetra_sync_detect.v NTS_REF for correct RX correlation.
localparam [43:0] NTS_REF = {
    2'b00, 2'b11, 2'b01, 2'b10, 2'b01, 2'b11, 2'b10, 2'b10,
    2'b00, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01, 2'b10, 2'b00,
    2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b01
};

// =============================================================================
// FSM state and counter
// =============================================================================
reg [2:0] state_sys;
reg [2:0] next_state_sys;
reg [7:0] sym_cnt_sys;

// =============================================================================
// Shift registers (flat, no arrays — R3)
// All loaded at build_req_sys pulse; each shifts during its active state.
// MSB pair [N-1:N-2] = current output symbol; shift left 2 each clock.
// =============================================================================
reg  [3:0]            fc_sreg_sys;
reg  [BLOCK_BITS-1:0] block1_sreg_sys;
reg  [43:0]           train_sreg_sys;
reg  [BB_BITS-1:0]    bb_sreg_sys;
reg  [BLOCK_BITS-1:0] block2_sreg_sys;

// =============================================================================
// Combinatorial: dibit mux (R5 — output logic block)
// =============================================================================
reg [1:0] mux_dibit_w;

always @(*) begin
    case (state_sys)
        S_FREQCOR: mux_dibit_w = fc_sreg_sys[3:2];
        S_BLOCK1:  mux_dibit_w = block1_sreg_sys[BLOCK_BITS-1:BLOCK_BITS-2];
        S_TRAIN:   mux_dibit_w = train_sreg_sys[43:42];
        S_BB:      mux_dibit_w = bb_sreg_sys[BB_BITS-1:BB_BITS-2];
        S_BLOCK2:  mux_dibit_w = block2_sreg_sys[BLOCK_BITS-1:BLOCK_BITS-2];
        default:   mux_dibit_w = 2'b00;
    endcase
end

// =============================================================================
// Combinatorial: next-state logic (R5 — next-state block)
// =============================================================================
always @(*) begin
    next_state_sys = state_sys;
    case (state_sys)
        S_IDLE:    if (build_req_sys)                    next_state_sys = S_FREQCOR;
        S_FREQCOR: if (sym_cnt_sys == CNT_FC_MAX)        next_state_sys = S_BLOCK1;
        S_BLOCK1:  if (sym_cnt_sys == CNT_BLK_MAX)       next_state_sys = S_TRAIN;
        S_TRAIN:   if (sym_cnt_sys == CNT_NTS_MAX)       next_state_sys = S_BB;
        S_BB:      if (sym_cnt_sys == CNT_BB_MAX)        next_state_sys = S_BLOCK2;
        S_BLOCK2:  if (sym_cnt_sys == CNT_BLK_MAX)       next_state_sys = S_DONE;
        S_DONE:                                           next_state_sys = S_IDLE;
        default:                                          next_state_sys = S_IDLE;
    endcase
end

// =============================================================================
// R1: state register (R5 — state register block)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_IDLE;
    else
        state_sys <= next_state_sys;
end

// =============================================================================
// R1: symbol counter
//   Resets to 0 on any state transition; increments while in active states.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sym_cnt_sys <= 8'd0;
    else if (state_sys != next_state_sys)
        sym_cnt_sys <= 8'd0;
    else if (state_sys != S_IDLE && state_sys != S_DONE)
        sym_cnt_sys <= sym_cnt_sys + 8'd1;
end

// =============================================================================
// R1: fc_sreg_sys
//   Loads FC_PAT on build_req; shifts MSB-first during S_FREQCOR.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        fc_sreg_sys <= 4'b0000;
    else if (state_sys == S_IDLE && build_req_sys)
        fc_sreg_sys <= FC_PAT;
    else if (state_sys == S_FREQCOR)
        fc_sreg_sys <= {fc_sreg_sys[1:0], 2'b00};
end

// =============================================================================
// R1: block1_sreg_sys
//   Loads Block 1 on build_req; shifts MSB-first during S_BLOCK1.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        block1_sreg_sys <= {BLOCK_BITS{1'b0}};
    else if (state_sys == S_IDLE && build_req_sys)
        block1_sreg_sys <= block1_data_sys;
    else if (state_sys == S_BLOCK1)
        block1_sreg_sys <= {block1_sreg_sys[BLOCK_BITS-3:0], 2'b00};
end

// =============================================================================
// R1: train_sreg_sys
//   Loads NTS_REF on build_req; shifts MSB-first during S_TRAIN.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        train_sreg_sys <= 44'd0;
    else if (state_sys == S_IDLE && build_req_sys)
        train_sreg_sys <= NTS_REF;
    else if (state_sys == S_TRAIN)
        train_sreg_sys <= {train_sreg_sys[41:0], 2'b00};
end

// =============================================================================
// R1: bb_sreg_sys
//   Loads BB data on build_req; shifts MSB-first during S_BB.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        bb_sreg_sys <= {BB_BITS{1'b0}};
    else if (state_sys == S_IDLE && build_req_sys)
        bb_sreg_sys <= bb_data_sys;
    else if (state_sys == S_BB)
        bb_sreg_sys <= {bb_sreg_sys[BB_BITS-3:0], 2'b00};
end

// =============================================================================
// R1: block2_sreg_sys
//   Loads Block 2 on build_req; shifts MSB-first during S_BLOCK2.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        block2_sreg_sys <= {BLOCK_BITS{1'b0}};
    else if (state_sys == S_IDLE && build_req_sys)
        block2_sreg_sys <= block2_data_sys;
    else if (state_sys == S_BLOCK2)
        block2_sreg_sys <= {block2_sreg_sys[BLOCK_BITS-3:0], 2'b00};
end

// =============================================================================
// R1: tx_dibit_sys — registered output dibit (1-cycle latency from state)
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        tx_dibit_sys <= 2'b00;
    else
        tx_dibit_sys <= mux_dibit_w;
end

// =============================================================================
// R1: tx_dibit_valid_sys
//   HIGH when state (before posedge) is an active output state.
//   Registered from state_sys → 1-cycle latency, aligned with tx_dibit_sys.
//   Total 255 cycles of valid=1, exactly one per output symbol.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        tx_dibit_valid_sys <= 1'b0;
    else
        tx_dibit_valid_sys <= (state_sys == S_FREQCOR) || (state_sys == S_BLOCK1) ||
                              (state_sys == S_TRAIN)   || (state_sys == S_BB)     ||
                              (state_sys == S_BLOCK2);
end

// =============================================================================
// R1: tx_done_sys — 1-cycle pulse when LAST symbol is registered
//   Fires in the same output cycle as the last valid dibit (last BLOCK2 symbol).
//   next_state_sys == S_DONE means we are on the last BLOCK2 cycle.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        tx_done_sys <= 1'b0;
    else
        tx_done_sys <= (next_state_sys == S_DONE);
end

// =============================================================================
// R1: tx_busy_sys — HIGH while burst in progress
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
