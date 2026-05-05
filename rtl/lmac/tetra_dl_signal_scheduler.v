// =============================================================================
// tetra_dl_signal_scheduler.v — Phase Z.13 single-path slot encoder
//
// Downlink signalling scheduler — combinational head-fan-out + pop strobe.
//
// Phase Z.13 (2026-05-04) refactor — clean architectural rewrite:
//
//   The previous Z.11/Z.12 design used a single-bundle latch on each
//   slot_pulse@tn==3 (~451 FFs of latch-stage) that captured the queue
//   head, plus a per-TN aach_override and per-TN aach_coded bundle (~56
//   FFs).  This created a stale view of the queue when the slot_content_
//   mux refreshed the next-frame entries during the SAME slot_pulse@tn==3
//   that triggered the latch — a single-cycle race that the live decode
//   exposed as "AACH greift 1 frame zu spät" on Pre-Reply slots.
//
//   The fix is structural, not patchy: the scheduler no longer latches
//   anything.  All per-TN block bundle outputs are combinational fan-outs
//   of the queue.head signals — they are stable as long as the queue
//   doesn't pop.  The new pop trigger is `slot_pulse_sys && (tn_sys ==
//   head_target_tn) && head_valid` — fires only on the slot that actually
//   carries the popped PDU, AFTER the slot_content_mux has already
//   sampled the head into its tx_blkX_slotK_sys output registers (the
//   sample happens during the next-frame refresh that ran at the prior
//   slot_pulse@tn==3, when the head was still stable).
//
//   The AACH atomic-bundle bypass (`sched_aach_coded_tnK`, `sched_aach_
//   active`) is removed.  AACH is now produced by a SINGLE shared
//   tetra_aach_rm_encoder instance at the top-level slot-encoder side,
//   driven by head_aach_pattern when head_target_tn matches the slot
//   being encoded.  The default AACH path (idle 0x0249/0x3000, F18
//   anchor, grant_pending) lives entirely in tetra_aach_encoder.v with
//   no override inputs.
//
// Outputs (all combinational from head_*_sys):
//   sched_blk1_tnK  body upper-half for TN=K (queued or NULL-PDU idle)
//   sched_blk2_tnK  body lower-half (SCH/F coded; SCH/HD or idle = sig_companion)
//   sched_ndb2[K]   1 = NTS2 (SCH/HD or idle NULL-PDU), 0 = NTS1 (SCH/F)
//   sched_active[K] one-hot — head valid && head_target_tn == K
//
// Stats (registered):
//   pop_cnt_sys       counts pops issued (one per popped PDU)
//   override_cnt_sys  same as pop_cnt_sys (kept for AXI back-compat)
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
    // Queue head (combinational) + 1-cycle pop strobe
    // -------------------------------------------------------------------------
    output wire         pop_sys,
    input  wire         head_valid_sys,
    input  wire [431:0] head_coded_sys,
    input  wire [1:0]   head_pdu_type_sys,   // 00=SCH_F, 01=SCH_HD
    input  wire [1:0]   head_target_tn_sys,
    input  wire [1:0]   head_prio_sys,
    input  wire         head_second_pdu_present_sys,
    input  wire         head_second_pdu_nr_sys,

    output reg          popped_second_pdu_present_sys,
    output reg          popped_second_pdu_nr_sys,

    // -------------------------------------------------------------------------
    // Idle default sources
    //   null_pdu_bits  216-bit SCH/HD-coded NULL-PDU (signalling filler)
    //   sig_companion  216-bit companion half for SCH/HD slots
    //                  (SYSINFO / BNCH broadcast, SW-driven)
    // -------------------------------------------------------------------------
    input  wire [215:0] null_pdu_bits_sys,
    input  wire [215:0] sig_companion_sys,

    // -------------------------------------------------------------------------
    // Per-TN signalling block bundle — combinational fan-out of head_*_sys.
    // Stable as long as the queue head doesn't change.  Slot_content_mux
    // samples these into tx_blkX_slotK_sys registers during its
    // next-frame refresh window.
    // -------------------------------------------------------------------------
    output wire [215:0] sched_blk1_tn0_sys,
    output wire [215:0] sched_blk2_tn0_sys,
    output wire [215:0] sched_blk1_tn1_sys,
    output wire [215:0] sched_blk2_tn1_sys,
    output wire [215:0] sched_blk1_tn2_sys,
    output wire [215:0] sched_blk2_tn2_sys,
    output wire [215:0] sched_blk1_tn3_sys,
    output wire [215:0] sched_blk2_tn3_sys,
    output wire [3:0]   sched_ndb2_sys,
    output wire [3:0]   sched_active_sys,

    // -------------------------------------------------------------------------
    // Stats (to AXI regs)
    // -------------------------------------------------------------------------
    output reg  [15:0]  override_cnt_sys,    // # frames carrying a popped PDU
    output reg  [15:0]  pop_cnt_sys          // # queue pops issued
);

    // -------------------------------------------------------------------------
    // Pop trigger — Phase Z.13 semantic.  Fires on the slot_pulse for the
    // TN that actually carries the popped PDU.  By the time this trigger
    // fires, slot_content_mux's prefetch (which ran at the prior slot
    // wrap) has already registered the body into tx_blkX_slotK_sys, so
    // popping the entry here does not lose data.
    //
    // Edge cases:
    //   * slot_content_mux's prefetch reads queue.head combinationally
    //     during the previous frame's tn==3 wrap — head must be stable
    //     across that ~10-cycle refresh window.  A prior pop that fired
    //     at slot_pulse@target_tn of frame N-1 happened at a strictly
    //     EARLIER edge than the prefetch trigger (slot_pulse@tn==3), so
    //     the head we observe at the prefetch is the new one (or empty).
    //
    //   * If head_target_tn == 3, pop fires AT THE SAME edge that the
    //     prefetch trigger fires.  That's still safe because the prefetch
    //     is a multi-cycle FSM (S_RD0..S_CAP3) that latches the head into
    //     its own registers before it advances; the pop only updates the
    //     queue's entry_valid mask on the NEXT posedge, by which time
    //     the slot_content_mux has already started its FSM (S_RD0 is
    //     already entered) and is no longer reading the head's body.
    //     The only signal that needs to stay stable across S_RD0..S_CAP3
    //     is sched_active[k] — which depends on head_valid + head_target_tn.
    //     For target_tn=3 the head clears in the same cycle, sched_active
    //     for tn==3 goes to 0 → but the prefetch at tn==3 reads TN=3's
    //     entry from the BRAM, NOT from sched_*; so this is harmless.
    //     The body for TN=3 was sampled into blk1_mux_tn3 → tx_blk1_slot3
    //     in slot_content_mux during the prior frame's prefetch (when
    //     head was still valid).
    // -------------------------------------------------------------------------
    wire have_pdu_for_this_tn = head_valid_sys
                              && (head_target_tn_sys == tn_sys);
    wire pop_trigger          = slot_pulse_sys && have_pdu_for_this_tn;

    assign pop_sys = pop_trigger;

    // -------------------------------------------------------------------------
    // Per-TN combinational fan-out from queue.head.
    //   tgt_tnK = head_valid && head_target_tn == K
    //   blk1[K] = head_coded[431:216] when tgt_tnK, else null_pdu_bits
    //   blk2[K] = head_coded[215:0]   when tgt_tnK && SCH/F, else sig_companion
    //   ndb2[K] = SCH/HD bit when tgt_tnK (1=HD,0=F), else 1 (idle NULL-PDU=HD)
    //   active[K] = tgt_tnK
    // -------------------------------------------------------------------------
    wire b_is_f  = (head_pdu_type_sys == 2'd0);
    wire b_is_hd = (head_pdu_type_sys == 2'd1);

    wire tgt_tn0 = head_valid_sys && (head_target_tn_sys == 2'd0);
    wire tgt_tn1 = head_valid_sys && (head_target_tn_sys == 2'd1);
    wire tgt_tn2 = head_valid_sys && (head_target_tn_sys == 2'd2);
    wire tgt_tn3 = head_valid_sys && (head_target_tn_sys == 2'd3);

    assign sched_blk1_tn0_sys = tgt_tn0 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn0_sys = (tgt_tn0 && b_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn1_sys = tgt_tn1 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn1_sys = (tgt_tn1 && b_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn2_sys = tgt_tn2 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn2_sys = (tgt_tn2 && b_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn3_sys = tgt_tn3 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn3_sys = (tgt_tn3 && b_is_f) ? head_coded_sys[215:0] : sig_companion_sys;

    // ndb2 bit per TN: 1 = NTS2 (SCH/HD or idle NULL-PDU), 0 = NTS1 (SCH/F)
    wire ndb2_tn0 = tgt_tn0 ? b_is_hd : 1'b1;
    wire ndb2_tn1 = tgt_tn1 ? b_is_hd : 1'b1;
    wire ndb2_tn2 = tgt_tn2 ? b_is_hd : 1'b1;
    wire ndb2_tn3 = tgt_tn3 ? b_is_hd : 1'b1;
    assign sched_ndb2_sys = {ndb2_tn3, ndb2_tn2, ndb2_tn1, ndb2_tn0};

    // One-hot "real signalling PDU present for this TN" — used by
    // slot_content_mux to lift class=STATIC_BROADCAST → SIGNALLING for
    // the addressed TN, and at top-level for the AACH info-source mux
    // (head_aach_pattern vs default-encoder).
    assign sched_active_sys = {tgt_tn3, tgt_tn2, tgt_tn1, tgt_tn0};

    // -------------------------------------------------------------------------
    // Stats counters (saturating at 16'hFFFF).  override_cnt counts frames
    // that carried a real signalling PDU (= same as pop_cnt — kept as a
    // separate name for AXI back-compat).
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)                                  pop_cnt_sys <= 16'd0;
        else if (pop_trigger && pop_cnt_sys != 16'hFFFF) pop_cnt_sys <= pop_cnt_sys + 16'd1;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)                                       override_cnt_sys <= 16'd0;
        else if (pop_trigger && override_cnt_sys != 16'hFFFF) override_cnt_sys <= override_cnt_sys + 16'd1;
    end

    // Option B telemetry pass-through — latched on each pop so the value
    // stays stable across the frame that carries the SCH/F block.
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            popped_second_pdu_present_sys <= 1'b0;
        else if (pop_trigger)
            popped_second_pdu_present_sys <= head_second_pdu_present_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            popped_second_pdu_nr_sys <= 1'b0;
        else if (pop_trigger)
            popped_second_pdu_nr_sys <= head_second_pdu_nr_sys;
    end

    // -------------------------------------------------------------------------
    // Unused-input keepalive
    // -------------------------------------------------------------------------
    // synthesis translate_off
    wire _unused_sys = |head_prio_sys;
    // synthesis translate_on

endmodule

`default_nettype wire
