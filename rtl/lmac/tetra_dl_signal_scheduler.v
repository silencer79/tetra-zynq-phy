// =============================================================================
// tetra_dl_signal_scheduler.v
//
// Downlink signalling scheduler — one-frame-ahead arbiter that pops one PDU
// from tetra_dl_signal_queue on each slot_pulse at TN=3 and drives the four
// per-TN signalling block bundles consumed by tetra_slot_content_mux.
//
// No override / no conditional mux downstream: the scheduler is THE source
// for every SIGNALLING-class slot.  When the queue is empty the outputs
// carry the NULL-PDU idle default; when a PDU is queued, its target TN's
// outputs carry the PDU and the other three TNs carry the idle default.
// slot_content_mux then dispatches class=SIGNALLING straight to these regs
// without any "if override else schedule" pattern.
//
// Trigger timing: slot_pulse_sys && (tn_sys == 2'd3) — identical edge to
// the schedule-BRAM refresh in slot_content_mux.  At that edge the popped
// head bundle is latched into ONE single-bundle register set (not 4×216
// per-TN registers).  The next frame's per-TN block-bundle outputs are
// combinational mux outputs from that single latched bundle, so all four
// per-TN block outputs AND the per-TN AACH override pattern are derived
// from the SAME atomic bundle each frame — no off-by-one possible between
// slot-mux input and AACH-encoder input.
//
// Phase Z.11 refactor (2026-05-04):
//   Old design had 8×216 (blk1/blk2 per TN) + 4 (ndb2) + 4 (active) +
//   4×14 (aach-override per TN) = ~1796 FFs of latch-stage.  These all
//   moved values from "queue head at pop_trigger" → "stable bundle for
//   next frame", but the latch happened TWICE (once per consumer-TN), so
//   slot-mux and AACH-encoder could in principle pick up different
//   capture cycles if their consumer logic differed.  Live decode showed
//   AACH override greift 1 frame zu spät vs the carrier slot — root
//   cause was this multi-latch fan-out.
//
//   New design: ONE bundle latch (head_coded 432b + target_tn 2b +
//   pdu_type 2b + aach_pattern 14b + valid 1b) — net savings ≈ 1340 FFs.
//   All eight blk1/blk2/ndb2/active/aach-override outputs are combinational
//   muxes off this latched bundle.  Atomic per-frame view is guaranteed.
//
// Block bundle per TN (k = 0..3):
//   sched_blk1_tn_k    BKN1 payload, 216 bits SCH/HD-coded
//   sched_blk2_tn_k    BKN2 payload, 216 bits
//   sched_ndb2[k]      NTS bit: 0 = SCH/F (NTS1), 1 = SCH/HD (NTS2)
//
// Per-TN content rules (using the latched bundle, valid only on its
// captured target TN):
//   bundle valid AND bundle_target_tn == k:
//     SCH_F   blk1 = coded[431:216], blk2 = coded[215:0],   ndb2[k] = 0
//     SCH_HD  blk1 = coded[431:216], blk2 = sig_companion,  ndb2[k] = 1
//   otherwise (bundle invalid or different target):
//     blk1 = null_pdu_bits,          blk2 = sig_companion,  ndb2[k] = 1
//
// NULL-PDU is SCH/HD-coded (216 bits) → idle slots are NDB2 with NTS2.
// `sig_companion` is the SYSINFO/BNCH static broadcast companion half
// (same source the schedule-BRAM would have routed to BKN2).
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
    // Phase Z.2 — AACH override pattern attached to the queued PDU.
    // 14'h0009 (signalling-active) lifts TN!=0 default 0x32CB CapAlloc /
    // TN=0 default 0x0249 Common-Random to 0x0009 Unalloc/Unalloc on the
    // frame that carries the popped PDU.  14'h0000 means "use AACH-encoder
    // default-logic path" — preserves pre-Z.2 behaviour.
    input  wire [13:0]  head_aach_pattern_sys,
    // Option B telemetry (commit 5) — 1 iff the popped SCH/F block
    // carries a concatenated auto-BL-ACK after the D-LOC-UPDATE-ACCEPT
    // (see tetra_dl_signal_queue.v).  Mirrored to the per-pop output
    // `popped_second_pdu_*` below for top-level ILA probes.
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
    // Per-TN signalling block bundle — combinational from the single
    // latched bundle below.  Stable across an entire frame because the
    // bundle is only updated on pop_trigger (slot_pulse && tn==3).
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
    // Phase Z.2 — per-TN AACH override pattern.  Same atomic source as
    // the block-bundle outputs above (single latched bundle).  Only the
    // TN matching the latched bundle's target_tn carries the queued
    // pattern; others reset to 0 (= "use default-logic" sentinel).
    output wire [13:0]  sched_aach_override_tn0_sys,
    output wire [13:0]  sched_aach_override_tn1_sys,
    output wire [13:0]  sched_aach_override_tn2_sys,
    output wire [13:0]  sched_aach_override_tn3_sys,

    // -------------------------------------------------------------------------
    // Stats (to AXI regs)
    // -------------------------------------------------------------------------
    output reg  [15:0]  override_cnt_sys,    // number of frames carrying a PDU
    output reg  [15:0]  pop_cnt_sys          // number of queue pops issued
);

    // -------------------------------------------------------------------------
    // Trigger — identical edge to slot_content_mux's schedule refresh.
    // -------------------------------------------------------------------------
    wire pop_trigger  = slot_pulse_sys && (tn_sys == 2'd3);
    wire have_pdu     = pop_trigger && head_valid_sys;

    // -------------------------------------------------------------------------
    // Single-bundle latch — captures the queue head on pop_trigger and
    // holds it stable for the entire next frame.  All per-TN combinational
    // outputs below mux from this single bundle, so the slot-content-mux
    // and AACH-encoder always see an atomic view.
    //
    // R1 — one always block per register.
    // -------------------------------------------------------------------------
    reg [431:0] bundle_coded_sys;
    reg [1:0]   bundle_pdu_type_sys;
    reg [1:0]   bundle_target_tn_sys;
    reg [13:0]  bundle_aach_pattern_sys;
    reg         bundle_valid_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)        bundle_valid_sys <= 1'b0;
        else if (pop_trigger)  bundle_valid_sys <= head_valid_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)        bundle_coded_sys <= 432'd0;
        else if (pop_trigger)  bundle_coded_sys <= head_coded_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)        bundle_pdu_type_sys <= 2'd0;
        else if (pop_trigger)  bundle_pdu_type_sys <= head_pdu_type_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)        bundle_target_tn_sys <= 2'd0;
        else if (pop_trigger)  bundle_target_tn_sys <= head_target_tn_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)        bundle_aach_pattern_sys <= 14'd0;
        else if (pop_trigger)  bundle_aach_pattern_sys <= head_aach_pattern_sys;
    end

    // -------------------------------------------------------------------------
    // Per-TN combinational mux from the latched bundle.
    // -------------------------------------------------------------------------
    wire b_is_f  = (bundle_pdu_type_sys == 2'd0);
    wire b_is_hd = (bundle_pdu_type_sys == 2'd1);

    wire tgt_tn0 = bundle_valid_sys && (bundle_target_tn_sys == 2'd0);
    wire tgt_tn1 = bundle_valid_sys && (bundle_target_tn_sys == 2'd1);
    wire tgt_tn2 = bundle_valid_sys && (bundle_target_tn_sys == 2'd2);
    wire tgt_tn3 = bundle_valid_sys && (bundle_target_tn_sys == 2'd3);

    assign sched_blk1_tn0_sys = tgt_tn0 ? bundle_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn0_sys = (tgt_tn0 && b_is_f) ? bundle_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn1_sys = tgt_tn1 ? bundle_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn1_sys = (tgt_tn1 && b_is_f) ? bundle_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn2_sys = tgt_tn2 ? bundle_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn2_sys = (tgt_tn2 && b_is_f) ? bundle_coded_sys[215:0] : sig_companion_sys;
    assign sched_blk1_tn3_sys = tgt_tn3 ? bundle_coded_sys[431:216] : null_pdu_bits_sys;
    assign sched_blk2_tn3_sys = (tgt_tn3 && b_is_f) ? bundle_coded_sys[215:0] : sig_companion_sys;

    // ndb2 bit per TN: 1 = NTS2 (SCH/HD or idle NULL-PDU), 0 = NTS1 (SCH/F)
    wire ndb2_tn0 = tgt_tn0 ? b_is_hd : 1'b1;
    wire ndb2_tn1 = tgt_tn1 ? b_is_hd : 1'b1;
    wire ndb2_tn2 = tgt_tn2 ? b_is_hd : 1'b1;
    wire ndb2_tn3 = tgt_tn3 ? b_is_hd : 1'b1;
    assign sched_ndb2_sys = {ndb2_tn3, ndb2_tn2, ndb2_tn1, ndb2_tn0};

    // One-hot "real signalling PDU present in this frame" marker.  Used
    // by slot_content_mux to lift class=STATIC_BROADCAST → SIGNALLING on
    // the addressed TN, and by the AACH encoder so TN0 advertises
    // Unalloc/Unalloc only on addressed reply slots while idle signalling
    // slots keep Common/Random.
    assign sched_active_sys = {tgt_tn3, tgt_tn2, tgt_tn1, tgt_tn0};

    // Per-TN AACH override pattern — only the addressed TN gets the
    // bundle's pattern; other TNs see 14'd0 = "use AACH-encoder default".
    assign sched_aach_override_tn0_sys = tgt_tn0 ? bundle_aach_pattern_sys : 14'd0;
    assign sched_aach_override_tn1_sys = tgt_tn1 ? bundle_aach_pattern_sys : 14'd0;
    assign sched_aach_override_tn2_sys = tgt_tn2 ? bundle_aach_pattern_sys : 14'd0;
    assign sched_aach_override_tn3_sys = tgt_tn3 ? bundle_aach_pattern_sys : 14'd0;

    // -------------------------------------------------------------------------
    // pop_sys — 1-cycle strobe on the trigger when a PDU is available.
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) pop_sys <= 1'b0;
        else            pop_sys <= have_pdu;
    end

    // -------------------------------------------------------------------------
    // Stats counters (saturating at 16'hFFFF).  override_cnt counts frames
    // that carried a real signalling PDU (not idle NULL-PDU filler).
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)                                  pop_cnt_sys <= 16'd0;
        else if (have_pdu && pop_cnt_sys != 16'hFFFF)    pop_cnt_sys <= pop_cnt_sys + 16'd1;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)                                       override_cnt_sys <= 16'd0;
        else if (have_pdu && override_cnt_sys != 16'hFFFF)    override_cnt_sys <= override_cnt_sys + 16'd1;
    end

    // Option B telemetry pass-through — latched on each pop so the value
    // stays stable across the frame that carries the SCH/F block.
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            popped_second_pdu_present_sys <= 1'b0;
        else if (have_pdu)
            popped_second_pdu_present_sys <= head_second_pdu_present_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            popped_second_pdu_nr_sys <= 1'b0;
        else if (have_pdu)
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
