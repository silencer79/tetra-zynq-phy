// =============================================================================
// tetra_frame_counter.v — TDMA Frame / Multiframe / Hyperframe Counter
// =============================================================================
//
// Tracks the TETRA TDMA timing hierarchy (ETSI EN 300 392-2 §18.4):
//
//   Timeslot:   0–3      (255 symbols = 14.167 ms each)
//   Frame:      1–18     (4 timeslots = 56.667 ms)
//   Multiframe: 1–60     (18 frames   = 1.020 s)
//   Hyperframe: 0–65535  (60 multiframes = 61.2 s, wraps freely)
//
// Input timing:
//   slot_pulse = tetra_burst_demux.slot_valid — one pulse per completed
//   timeslot.  The counter updates on the posedge that carries slot_pulse.
//
// timeslot_num semantics:
//   timeslot_num holds the PRE-update value at the moment slot_pulse arrives;
//   i.e. timeslot_num == N when the Nth timeslot (0-based) just completed.
//   After the clock edge timeslot_num increments to N+1 (mod 4).
//   Example: first slot_pulse → timeslot_num was 0 → becomes 1.
//
// Frame numbering: ETSI 1-based (1–18).  frame_num resets to 1.
//   Frame 18 is the TETRA control frame carrying BNCH/BSCH/BNCH on
//   timeslots 1, 2, 3 (0-based); see ETSI EN 300 392-2 §18.4.3.
//
// is_control_frame:
//   Goes HIGH on the same posedge that frame_num transitions to 18
//   (i.e., when ts3 of frame 17 completes).  Goes LOW on the posedge
//   that frame_num transitions from 18 to 1 (ts3 of frame 18 completes).
//   Implemented via next_frame_sample wire — no extra pipeline cycle.
//
// frame_18_slot1:
//   One-cycle pulse, registered one cycle after the slot_pulse for
//   timeslot 1 (0-based) of frame 18.  Used by upper layers to trigger
//   BNCH decoding.  timeslot_num == 1 (pre-update) selects slot 1.
//
// Reset / sync loss:
//   Asynchronous active-low reset (rst_n_sample) clears all counters.
//   Synchronous sync_locked deassertion also clears all counters, so
//   they restart cleanly at the next sync acquisition.
//
// Resource estimate: LUT ~25  FF ~36  DSP 0  BRAM 0
//
// Clock domain: _sample (clk_sys 100 MHz; slot_pulse strobe ~70.6 Hz,
//   i.e. 18 000 symbol/s ÷ 255 symbols/timeslot)
//
// =============================================================================

`default_nettype none

module tetra_frame_counter (
    input  wire        clk_sample,
    input  wire        rst_n_sample,

    // Sync status (from tetra_sync_detect)
    input  wire        sync_locked,

    // Slot timing pulse (= slot_valid from tetra_burst_demux, one pulse/timeslot)
    input  wire        slot_pulse,

    // TDMA counter outputs (updated on each slot_pulse posedge)
    output reg [1:0]   timeslot_num,     // last-completed timeslot (0–3, pre-update value)
    output reg [4:0]   frame_num,        // current frame in multiframe (1–18, ETSI 1-based)
    output reg [5:0]   multiframe_num,   // current multiframe in hyperframe (1–60)
    output reg [15:0]  hyperframe_num,   // absolute hyperframe counter (0-based, free-running)

    // Decoded timing flags
    output reg         is_control_frame, // HIGH while current frame_num == 18
    output reg         frame_18_slot1    // one-cycle pulse: timeslot 1 of frame 18 complete
);

// ---------------------------------------------------------------------------
// Boundary detection — combinatorial, uses PRE-update register values
// ---------------------------------------------------------------------------
// frame_edge:       timeslot 3 just completed → end of current frame
// multiframe_edge:  frame 18, timeslot 3 → end of current multiframe
// hyperframe_edge:  multiframe 60, frame 18, timeslot 3 → end of hyperframe
wire frame_edge_sample      = slot_pulse && (timeslot_num == 2'd3);
wire multiframe_edge_sample = frame_edge_sample && (frame_num == 5'd18);
wire hyperframe_edge_sample = multiframe_edge_sample && (multiframe_num == 6'd60);

// Next frame_num value (combinatorial look-ahead for is_control_frame)
//   At frame_edge:      frame_num wraps 18→1 (multiframe_edge) or increments
//   Otherwise:          unchanged
wire [4:0] next_frame_sample = frame_edge_sample ?
                                   (multiframe_edge_sample ? 5'd1 : frame_num + 5'd1) :
                                   frame_num;

// ---------------------------------------------------------------------------
// timeslot_num — modular counter 0→1→2→3→0
// Pre-update value identifies the just-completed timeslot at slot_pulse.
// Reset to 0 on rst or sync loss.
// Pipeline Stage 0: timeslot counter
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        timeslot_num <= 2'd0;
    else if (!sync_locked)
        timeslot_num <= 2'd0;
    else if (slot_pulse)
        timeslot_num <= timeslot_num + 2'd1;   // natural 2-bit wrap mod 4
end

// ---------------------------------------------------------------------------
// frame_num — counts 1–18 (ETSI 1-based); increments at each frame boundary
// Reset to 1 on rst or sync loss.
// Pipeline Stage 1: frame counter
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        frame_num <= 5'd1;
    else if (!sync_locked)
        frame_num <= 5'd1;
    else if (frame_edge_sample) begin
        if (frame_num == 5'd18)
            frame_num <= 5'd1;
        else
            frame_num <= frame_num + 5'd1;
    end
end

// ---------------------------------------------------------------------------
// multiframe_num — counts 1–60; increments at each multiframe boundary
// Reset to 1 on rst or sync loss.
// Pipeline Stage 2: multiframe counter
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        multiframe_num <= 6'd1;
    else if (!sync_locked)
        multiframe_num <= 6'd1;
    else if (multiframe_edge_sample) begin
        if (multiframe_num == 6'd60)
            multiframe_num <= 6'd1;
        else
            multiframe_num <= multiframe_num + 6'd1;
    end
end

// ---------------------------------------------------------------------------
// hyperframe_num — free-running; increments at each hyperframe boundary
// Reset to 0 on rst or sync loss.
// Pipeline Stage 3: hyperframe counter
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        hyperframe_num <= 16'd0;
    else if (!sync_locked)
        hyperframe_num <= 16'd0;
    else if (hyperframe_edge_sample)
        hyperframe_num <= hyperframe_num + 16'd1;
end

// ---------------------------------------------------------------------------
// is_control_frame — HIGH when frame_num == 18
// Updated on every slot_pulse using next_frame_sample look-ahead, so it
// transitions on the same posedge as frame_num itself.
// Pipeline Stage 4: control frame flag
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        is_control_frame <= 1'b0;
    else if (!sync_locked)
        is_control_frame <= 1'b0;
    else if (slot_pulse)
        is_control_frame <= (next_frame_sample == 5'd18);
end

// ---------------------------------------------------------------------------
// frame_18_slot1 — one-cycle pulse when timeslot 1 of frame 18 completes
// timeslot_num == 1 (pre-update) AND frame_num == 18 AND slot_pulse.
// Registered one cycle after the relevant slot_pulse.
// Used by upper layers (LMAC) to trigger BNCH block decoding.
// Pipeline Stage 5: BNCH timing indicator
// ---------------------------------------------------------------------------
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        frame_18_slot1 <= 1'b0;
    else
        frame_18_slot1 <= slot_pulse && (frame_num == 5'd18) && (timeslot_num == 2'd1);
end

endmodule

`default_nettype wire
