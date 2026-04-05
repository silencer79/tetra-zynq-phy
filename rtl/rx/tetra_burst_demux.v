// =============================================================================
// tetra_burst_demux.v — TDMA Burst Field Extractor
// =============================================================================
//
// Extracts Block1, Block2, and BB (AACH) fields from the demodulated TETRA
// NDB downlink burst stream.  Driven by tetra_sync_detect outputs.
//
// NDB field positions (EN 300 392-2 §9.4.4.3.1), 255 symbols per timeslot:
//   abs  0–  1 : FreqCorr     (2 symbols)
//   abs  2– 109: Block1      (108 symbols = 216 bits)
//   abs 110– 131: Training Seq (22 symbols) ← sync fires at abs 131
//   abs 132– 146: BB / AACH   (15 symbols = 30 bits)
//   abs 147– 254: Block2      (108 symbols = 216 bits)
//
// slot_position convention (from tetra_sync_detect):
//   slot_position=0 is the CURRENT value when the first BB symbol arrives,
//   i.e., sync fires at slot_position_prev=254 → slot_position→0 on same edge.
//
// Capture windows (slot_position = registered value BEFORE clock edge):
//   pos  0 – 14  : BB   (15 symbols)
//   pos 15 – 122 : Block2 (108 symbols)
//   pos 123      : emit_burst pulse (first FreqCorr of next slot, Block2 done)
//   pos 125 – 232: Block1 of the NEXT slot (108 symbols)
//
// A complete burst (block1+block2+bb) is available on slot_valid after TWO
// sync events: first sync captures Block1, second sync provides BB+Block2.
//
// Note on slot_number input:
//   tetra_sync_detect slot_number does not increment when sync fires at
//   slot_position=254 (design limitation: !sync_fire guard).  This module
//   maintains its own slot counter (slot_cnt_sample) incremented on sync_found.
//
// Clock domain: _sample (100 MHz sys clock; dibit_valid strobe at ~18 kHz)
//
// Resource estimate: LUT ~120  FF ~580  DSP 0  BRAM 0
//
// Pipeline / Latency:
//   slot_valid fires 1 cycle after emit_burst_sample (pos=123+1=124).
//   Output registers (block1_data, block2_data, bb_data, slot_num_out,
//   burst_type) are stable one cycle BEFORE slot_valid (latched at pos=123).
//
// =============================================================================

`default_nettype none

module tetra_burst_demux #(
    parameter BLOCK_BITS   = 216,   // bits per NDB block (108 symbols x 2)
    parameter BB_BITS      = 30,    // BB (AACH) field bits (15 symbols x 2)
    parameter TS_PER_FRAME = 4      // timeslots per frame (informational)
)(
    input  wire                      clk_sample,
    input  wire                      rst_n_sample,

    // Demodulated symbol stream (from tetra_pi4dqpsk_demod)
    input  wire [1:0]                dibit_in,
    input  wire                      dibit_valid,

    // Sync detector outputs (from tetra_sync_detect)
    input  wire                      sync_found,      // one-cycle pulse, sync'd with slot_position→0
    input  wire                      sync_locked,
    input  wire [7:0]                slot_position,   // 0-254; 0 = first BB symbol cycle
    input  wire [1:0]                slot_number,     // from sync_detect (informational only)

    // AXI-Lite configuration
    input  wire [1:0]                seq_select,      // 0=NTS,1=ETS,2=STS → burst_type tag

    // Burst outputs (valid for one cycle when slot_valid pulses)
    output reg  [BLOCK_BITS-1:0]     block1_data,     // Block1 of completed burst (MSB=first rx'd)
    output reg  [BLOCK_BITS-1:0]     block2_data,     // Block2 of completed burst
    output reg  [BB_BITS-1:0]        bb_data,         // BB (AACH) of completed burst
    output reg  [1:0]                slot_num_out,    // slot index (0-3) of this burst
    output reg                       slot_valid,      // one-cycle pulse: burst data ready
    output reg  [1:0]                burst_type       // 0=NDB(NTS),1=NDB(ETS),2=SB(STS)
);

// ---------------------------------------------------------------------------
// Capture window localparams
// (slot_position value BEFORE clock edge when dibit is sampled)
// ---------------------------------------------------------------------------
localparam [7:0] BB_POS_START  = 8'd0;    // first BB symbol
localparam [7:0] BB_POS_END    = 8'd14;   // last  BB symbol
localparam [7:0] B2_POS_START  = 8'd15;   // first Block2 symbol
localparam [7:0] B2_POS_END    = 8'd122;  // last  Block2 symbol
localparam [7:0] EMIT_POS      = 8'd123;  // emit after Block2 complete
localparam [7:0] B1_POS_START  = 8'd125;  // first Block1 (next slot)
localparam [7:0] B1_POS_END    = 8'd232;  // last  Block1 (next slot)

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [1:0] S_HUNT = 2'd0,
                 S_RUN  = 2'd1;

// ---------------------------------------------------------------------------
// Internal registers (R1: one always block per register)
// ---------------------------------------------------------------------------

reg [1:0]              state_sample;          // FSM state
reg [1:0]              next_state_sample;     // next-state (combo, not a reg)

reg [1:0]              slot_cnt_sample;       // own slot counter
reg [BLOCK_BITS-1:0]   block1_pend_sample;    // Block1 shift (pending, captured pos 125-232)
reg [BB_BITS-1:0]      bb_shift_sample;       // BB shift (captured pos 0-14)
reg [BLOCK_BITS-1:0]   block2_shift_sample;   // Block2 shift (captured pos 15-122)
reg [BLOCK_BITS-1:0]   block1_lat_sample;     // Block1 latched at sync_found
reg [1:0]              slot_at_sync_sample;   // slot_cnt latched (pre-increment) at sync
reg [1:0]              btype_at_sync_sample;  // seq_select latched at sync
reg                    block1_captured_sample;// Block1 fully captured since last reset
reg                    block1_ready_sample;   // Block1 valid for output (set at sync)

// ---------------------------------------------------------------------------
// Capture enable wires (combinatorial)
// ---------------------------------------------------------------------------

wire capture_bb_sample = (slot_position >= BB_POS_START) &&
                         (slot_position <= BB_POS_END)   &&
                         dibit_valid && (state_sample == S_RUN);

wire capture_b2_sample = (slot_position >= B2_POS_START) &&
                         (slot_position <= B2_POS_END)   &&
                         dibit_valid && (state_sample == S_RUN);

wire capture_b1_sample = (slot_position >= B1_POS_START) &&
                         (slot_position <= B1_POS_END)   &&
                         dibit_valid && (state_sample == S_RUN);

// Emit when Block2 is complete and Block1 from previous cycle is ready
wire emit_burst_sample = (slot_position == EMIT_POS) &&
                         dibit_valid                   &&
                         block1_ready_sample            &&
                         (state_sample == S_RUN);

// ---------------------------------------------------------------------------
// FSM — State Register  (R4: async active-low reset)
// ---------------------------------------------------------------------------
// Pipeline Stage 0: lock/hunt state
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        state_sample <= S_HUNT;
    else
        state_sample <= next_state_sample;
end

// FSM — Next-State Logic (combinatorial, R5)
always @(*) begin
    next_state_sample = state_sample;
    case (state_sample)
        S_HUNT: if (sync_locked)  next_state_sample = S_RUN;
        S_RUN:  if (!sync_locked) next_state_sample = S_HUNT;
        default: next_state_sample = S_HUNT;
    endcase
end

// ---------------------------------------------------------------------------
// Slot counter — increments on every sync_found while running
// Pipeline Stage 1: burst identity
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_cnt_sample <= 2'd0;
    else if (state_sample == S_HUNT)
        slot_cnt_sample <= 2'd0;
    else if (sync_found)
        slot_cnt_sample <= slot_cnt_sample + 2'd1;
end

// ---------------------------------------------------------------------------
// BB shift register — captures dibits at pos 0..14
// Pipeline Stage 2a: BB field assembly
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        bb_shift_sample <= {BB_BITS{1'b0}};
    else if (capture_bb_sample)
        bb_shift_sample <= {bb_shift_sample[BB_BITS-3:0], dibit_in};
end

// ---------------------------------------------------------------------------
// Block2 shift register — captures dibits at pos 15..122
// Pipeline Stage 2b: Block2 field assembly
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block2_shift_sample <= {BLOCK_BITS{1'b0}};
    else if (capture_b2_sample)
        block2_shift_sample <= {block2_shift_sample[BLOCK_BITS-3:0], dibit_in};
end

// ---------------------------------------------------------------------------
// Block1 pending shift register — captures dibits at pos 125..232
// This block belongs to the NEXT slot (relative to current sync).
// Pipeline Stage 2c: Block1 field assembly
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block1_pend_sample <= {BLOCK_BITS{1'b0}};
    else if (capture_b1_sample)
        block1_pend_sample <= {block1_pend_sample[BLOCK_BITS-3:0], dibit_in};
end

// ---------------------------------------------------------------------------
// block1_captured flag — set when Block1 window is complete (pos=232)
// Cleared when returning to S_HUNT.
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block1_captured_sample <= 1'b0;
    else if (state_sample == S_HUNT)
        block1_captured_sample <= 1'b0;
    else if ((slot_position == B1_POS_END) && dibit_valid)
        block1_captured_sample <= 1'b1;
end

// ---------------------------------------------------------------------------
// At sync_found: latch Block1, slot info, burst type, and block1_ready flag
// Pipeline Stage 3: sync-time latching
// ---------------------------------------------------------------------------

// Block1 latch — captures pending Block1 for use after next sync
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block1_lat_sample <= {BLOCK_BITS{1'b0}};
    else if (sync_found && (state_sample == S_RUN))
        block1_lat_sample <= block1_pend_sample;
end

// Slot number at sync (post-increment value: slot_cnt after this sync)
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_at_sync_sample <= 2'd0;
    else if (sync_found && (state_sample == S_RUN))
        slot_at_sync_sample <= slot_cnt_sample + 2'd1;
end

// Burst type at sync
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        btype_at_sync_sample <= 2'd0;
    else if (sync_found && (state_sample == S_RUN))
        btype_at_sync_sample <= seq_select;
end

// block1_ready — promoted from block1_captured at sync
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block1_ready_sample <= 1'b0;
    else if (state_sample == S_HUNT)
        block1_ready_sample <= 1'b0;
    else if (sync_found && (state_sample == S_RUN))
        block1_ready_sample <= block1_captured_sample;
end

// ---------------------------------------------------------------------------
// Output registers — latched at emit_burst_sample (pos=123)
// Pipeline Stage 4: output
// ---------------------------------------------------------------------------

// block1_data output
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block1_data <= {BLOCK_BITS{1'b0}};
    else if (emit_burst_sample)
        block1_data <= block1_lat_sample;
end

// block2_data output
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        block2_data <= {BLOCK_BITS{1'b0}};
    else if (emit_burst_sample)
        block2_data <= block2_shift_sample;
end

// bb_data output
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        bb_data <= {BB_BITS{1'b0}};
    else if (emit_burst_sample)
        bb_data <= bb_shift_sample;
end

// slot_num_out output
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_num_out <= 2'd0;
    else if (emit_burst_sample)
        slot_num_out <= slot_at_sync_sample;
end

// burst_type output
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        burst_type <= 2'd0;
    else if (emit_burst_sample)
        burst_type <= btype_at_sync_sample;
end

// slot_valid — one-cycle pulse, registered from emit_burst_sample
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_valid <= 1'b0;
    else
        slot_valid <= emit_burst_sample;
end

endmodule

`default_nettype wire
