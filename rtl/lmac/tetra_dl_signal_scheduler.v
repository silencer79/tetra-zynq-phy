// =============================================================================
// tetra_dl_signal_scheduler.v
//
// Downlink signalling scheduler — one-frame-ahead arbiter that pops a
// single PDU from tetra_dl_signal_queue on each slot_pulse at TN=3 and
// exposes a per-frame override bundle to tetra_slot_content_mux.
//
// Why one PDU per frame (not per slot)?  Signalling bandwidth is tiny —
// D-LOC-UPDATE-ACCEPT is ~50 bytes, a whole frame is 85 ms.  Popping at
// the same trigger as the schedule-BRAM refresh (slot_pulse && tn==3)
// means the override is fully registered and stable for all 4 slots of
// the next frame by the time slot_pulse fires — zero race against the
// burst_mux capture edge.
//
// Output semantics (all outputs registered, change only at tn==3):
//   override_active        1 if this frame has a signalling override
//   override_target_tn     which TN (0..3) the override applies to
//   override_use_blk1/2    which of the two 216-bit halves to override
//                          (SCH/F uses both, SCH/HD only blk1)
//   override_ndb2          NTS bit to force on the target TN: 0=NTS1
//                          (SCH/F), 1=NTS2 (SCH/HD)
//   override_blk1          coded_bits[431:216]
//   override_blk2          coded_bits[215:  0]
//
// Coverage: one PDU per frame.  If the queue holds multiple PDUs they
// drain at 1/frame (~85 ms per registration response).  An MS timeout is
// ~1 s so we have headroom for 11-12 backlog entries before the MS retries
// — well above the queue depth of 4.  Not an issue in practice.
//
// Coding rules: Verilog-2001 strict
//   R1  one always block per register
//   R4  async active-low reset
//   R9  no initial blocks
//   R10 @(*) for combinatorial
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_dl_signal_scheduler (
    input  wire         clk_sys,
    input  wire         rst_n_sys,

    // -------------------------------------------------------------------------
    // Timebase — slot_pulse is a 1-cycle strobe at the START of each slot
    // -------------------------------------------------------------------------
    input  wire [1:0]   tn_sys,
    input  wire         slot_pulse_sys,

    // -------------------------------------------------------------------------
    // Queue pop interface (combinational head view, 1-cycle pop pulse)
    // -------------------------------------------------------------------------
    output reg          pop_sys,
    input  wire         head_valid_sys,
    input  wire [431:0] head_coded_sys,
    input  wire [1:0]   head_pdu_type_sys,   // 00=SCH_F, 01=SCH_HD
    input  wire [1:0]   head_target_tn_sys,
    input  wire [1:0]   head_prio_sys,

    // -------------------------------------------------------------------------
    // Per-frame override bundle to slot_content_mux
    // -------------------------------------------------------------------------
    output reg          override_active_sys,
    output reg  [1:0]   override_target_tn_sys,
    output reg          override_use_blk1_sys,
    output reg          override_use_blk2_sys,
    output reg          override_ndb2_sys,
    output reg  [215:0] override_blk1_sys,
    output reg  [215:0] override_blk2_sys,

    // -------------------------------------------------------------------------
    // Stats (to AXI regs)
    // -------------------------------------------------------------------------
    output reg  [15:0]  override_cnt_sys,     // number of frames with override
    output reg  [15:0]  pop_cnt_sys           // number of queue pops issued
);

    // -------------------------------------------------------------------------
    // Trigger — identical edge to tetra_slot_content_mux's schedule refresh.
    // At this edge the BRAM refresh FSM is already kicking off reads for the
    // next frame; our override latches become visible simultaneously with
    // the next frame's schedule entries.
    // -------------------------------------------------------------------------
    wire pop_trigger = slot_pulse_sys && (tn_sys == 2'd3);

    // head_pdu_type == SCH_F ⇒ override both halves, NTS1.
    // head_pdu_type == SCH_HD ⇒ override only BKN1, NTS2.  The mux falls
    // back to the schedule entry for BKN2 (SYSINFO / BNCH filler).
    wire head_is_sch_f  = (head_pdu_type_sys == 2'd0);
    wire head_is_sch_hd = (head_pdu_type_sys == 2'd1);

    // -------------------------------------------------------------------------
    // pop_sys — fires exactly one cycle on the trigger when the queue has
    // something to give.
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pop_sys <= 1'b0;
        else
            pop_sys <= pop_trigger && head_valid_sys;
    end

    // -------------------------------------------------------------------------
    // Override registers — latched on trigger edge.  If the queue is empty,
    // override_active drops to 0 (no PDU → normal schedule governs).
    //
    // Critical property: these registers only change at tn==3.  The next
    // frame's tn=0..3 consumers observe a fully stable override bundle.
    // This is the whole point of the architecture — zero race with burst_mux.
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            override_active_sys     <= 1'b0;
            override_target_tn_sys  <= 2'd0;
            override_use_blk1_sys   <= 1'b0;
            override_use_blk2_sys   <= 1'b0;
            override_ndb2_sys       <= 1'b0;
            override_blk1_sys       <= 216'd0;
            override_blk2_sys       <= 216'd0;
        end else if (pop_trigger) begin
            if (head_valid_sys) begin
                override_active_sys    <= 1'b1;
                override_target_tn_sys <= head_target_tn_sys;
                override_use_blk1_sys  <= 1'b1;
                override_use_blk2_sys  <= head_is_sch_f;
                override_ndb2_sys      <= head_is_sch_hd;
                override_blk1_sys      <= head_coded_sys[431:216];
                override_blk2_sys      <= head_coded_sys[215:  0];
            end else begin
                override_active_sys    <= 1'b0;
                override_use_blk1_sys  <= 1'b0;
                override_use_blk2_sys  <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stats counters (saturating at 16'hFFFF)
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pop_cnt_sys <= 16'd0;
        else if (pop_trigger && head_valid_sys && pop_cnt_sys != 16'hFFFF)
            pop_cnt_sys <= pop_cnt_sys + 16'd1;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            override_cnt_sys <= 16'd0;
        else if (pop_trigger && head_valid_sys && override_cnt_sys != 16'hFFFF)
            override_cnt_sys <= override_cnt_sys + 16'd1;
    end

    // -------------------------------------------------------------------------
    // Unused input keepalive — head_prio_sys is informational (scheduler
    // doesn't make decisions from it; the queue already honored prio at
    // head selection).  Silence unused-net warnings.
    // -------------------------------------------------------------------------
    // synthesis translate_off
    wire _unused_sys = |head_prio_sys;
    // synthesis translate_on

endmodule

`default_nettype wire
