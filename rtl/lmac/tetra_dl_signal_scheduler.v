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
// the schedule-BRAM refresh in slot_content_mux.  Registers update once
// per frame; consumers in tn=0..3 of the next frame see a stable bundle.
//
// Block bundle per TN (k = 0..3):
//   sched_blk1_tn_k    BKN1 payload, 216 bits SCH/HD-coded
//   sched_blk2_tn_k    BKN2 payload, 216 bits
//   sched_ndb2[k]      NTS bit: 0 = SCH/F (NTS1), 1 = SCH/HD (NTS2)
//
// Per-TN content rules:
//   queue head valid AND head_target_tn == k:
//     SCH_F   blk1 = coded[431:216], blk2 = coded[215:0],   ndb2[k] = 0
//     SCH_HD  blk1 = coded[431:216], blk2 = sig_companion,  ndb2[k] = 1
//   otherwise (queue empty or different target):
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
    // Per-TN signalling block bundle — always valid.  Consumer treats these
    // as the authoritative source for any schedule slot with class=SIGNALLING.
    // -------------------------------------------------------------------------
    output reg  [215:0] sched_blk1_tn0_sys,
    output reg  [215:0] sched_blk2_tn0_sys,
    output reg  [215:0] sched_blk1_tn1_sys,
    output reg  [215:0] sched_blk2_tn1_sys,
    output reg  [215:0] sched_blk1_tn2_sys,
    output reg  [215:0] sched_blk2_tn2_sys,
    output reg  [215:0] sched_blk1_tn3_sys,
    output reg  [215:0] sched_blk2_tn3_sys,
    output reg  [3:0]   sched_ndb2_sys,
    output reg  [3:0]   sched_active_sys,

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
    wire head_is_f    = (head_pdu_type_sys == 2'd0);
    wire head_is_hd   = (head_pdu_type_sys == 2'd1);
    wire have_pdu     = pop_trigger && head_valid_sys;

    // Combinational per-TN "next" values — mux between target-PDU content
    // and the NULL-PDU/companion idle default, driven from the queue head.
    // All four TNs see the same `have_pdu`; only one of target==k flags is
    // set per frame.
    wire tgt_tn0 = have_pdu && (head_target_tn_sys == 2'd0);
    wire tgt_tn1 = have_pdu && (head_target_tn_sys == 2'd1);
    wire tgt_tn2 = have_pdu && (head_target_tn_sys == 2'd2);
    wire tgt_tn3 = have_pdu && (head_target_tn_sys == 2'd3);

    wire [215:0] next_blk1_tn0 = tgt_tn0 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    wire [215:0] next_blk2_tn0 = (tgt_tn0 && head_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    wire         next_ndb2_tn0 = tgt_tn0 ? head_is_hd : 1'b1;

    wire [215:0] next_blk1_tn1 = tgt_tn1 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    wire [215:0] next_blk2_tn1 = (tgt_tn1 && head_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    wire         next_ndb2_tn1 = tgt_tn1 ? head_is_hd : 1'b1;

    wire [215:0] next_blk1_tn2 = tgt_tn2 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    wire [215:0] next_blk2_tn2 = (tgt_tn2 && head_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    wire         next_ndb2_tn2 = tgt_tn2 ? head_is_hd : 1'b1;

    wire [215:0] next_blk1_tn3 = tgt_tn3 ? head_coded_sys[431:216] : null_pdu_bits_sys;
    wire [215:0] next_blk2_tn3 = (tgt_tn3 && head_is_f) ? head_coded_sys[215:0] : sig_companion_sys;
    wire         next_ndb2_tn3 = tgt_tn3 ? head_is_hd : 1'b1;

    // -------------------------------------------------------------------------
    // pop_sys — 1-cycle strobe on the trigger when a PDU is available.
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) pop_sys <= 1'b0;
        else            pop_sys <= have_pdu;
    end

    // -------------------------------------------------------------------------
    // Per-TN output registers — one always block per register (R1).
    // Latched only on pop_trigger; the entire next frame observes a
    // stable bundle.  No intermediate combinational mux at the consumer.
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk1_tn0_sys <= 216'd0;
        else if (pop_trigger)    sched_blk1_tn0_sys <= next_blk1_tn0;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk2_tn0_sys <= 216'd0;
        else if (pop_trigger)    sched_blk2_tn0_sys <= next_blk2_tn0;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk1_tn1_sys <= 216'd0;
        else if (pop_trigger)    sched_blk1_tn1_sys <= next_blk1_tn1;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk2_tn1_sys <= 216'd0;
        else if (pop_trigger)    sched_blk2_tn1_sys <= next_blk2_tn1;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk1_tn2_sys <= 216'd0;
        else if (pop_trigger)    sched_blk1_tn2_sys <= next_blk1_tn2;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk2_tn2_sys <= 216'd0;
        else if (pop_trigger)    sched_blk2_tn2_sys <= next_blk2_tn2;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk1_tn3_sys <= 216'd0;
        else if (pop_trigger)    sched_blk1_tn3_sys <= next_blk1_tn3;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)          sched_blk2_tn3_sys <= 216'd0;
        else if (pop_trigger)    sched_blk2_tn3_sys <= next_blk2_tn3;
    end

    // 4-bit ndb2 bundle — concatenated update = one R1 register.
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            sched_ndb2_sys <= 4'b1111;    // idle = all NTS2 (NULL-PDU is SCH/HD)
        else if (pop_trigger)
            sched_ndb2_sys <= {next_ndb2_tn3, next_ndb2_tn2,
                               next_ndb2_tn1, next_ndb2_tn0};
    end

    // One-hot "real signalling PDU present in this frame" marker.  Used by
    // the AACH encoder so TN0 advertises Unalloc/Unalloc only on addressed
    // reply slots, while idle signalling slots keep Common/Random.
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            sched_active_sys <= 4'b0000;
        else if (pop_trigger)
            sched_active_sys <= have_pdu ? {tgt_tn3, tgt_tn2, tgt_tn1, tgt_tn0}
                                         : 4'b0000;
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
