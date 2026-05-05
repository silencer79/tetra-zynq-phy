// =============================================================================
// tb_dl_signal_scheduler.v — unit test for tetra_dl_signal_scheduler.v
//
// The scheduler drives per-TN signalling block bundles:
//   * When queue is empty → all 4 TNs show the NULL-PDU idle default
//     (blk1 = null_pdu_bits, blk2 = sig_companion, ndb2 = 1 = NTS2).
//   * When a PDU is queued for TN=k → TN=k carries the coded PDU content,
//     the other three TNs keep the NULL-PDU idle default.
//
// Coverage:
//   T1 reset → sched_ndb2 = 4'b1111 idle
//   T2 queue empty at tn==3 trigger → all TNs carry NULL-PDU/companion
//   T3 SCH/F PDU for target TN=1 → TN1 blk1=coded[431:216], TN1 blk2=coded[215:0],
//      TN1 ndb2=0 (NTS1); other TNs hold NULL-PDU/companion, ndb2=1
//   T4 SCH/HD PDU for target TN=2 → TN2 blk1=coded[431:216], TN2 blk2=sig_companion,
//      TN2 ndb2=1 (NTS2); other TNs hold NULL-PDU
//   T5 head_valid drops before next tn==3 → idle defaults re-latch
//   T6 pop never fires on tn != 3 even with valid head
//   T7 stats counters advance correctly
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_signal_scheduler;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg          clk   = 1'b0;
    reg          rst_n = 1'b0;
    reg  [1:0]   tn_sys = 2'd0;
    reg          slot_pulse_sys = 1'b0;
    reg          head_valid_sys = 1'b0;
    reg  [431:0] head_coded_sys = 432'd0;
    reg  [1:0]   head_pdu_type_sys = 2'd0;
    reg  [1:0]   head_target_tn_sys = 2'd0;
    reg  [1:0]   head_prio_sys = 2'd0;
    reg  [215:0] null_pdu_bits_sys;
    reg  [215:0] sig_companion_sys;

    reg  [29:0]  head_aach_coded_sys = 30'd0;     // Phase Z.12

    wire         pop_sys;
    wire [215:0] sched_blk1_tn0_sys, sched_blk2_tn0_sys;
    wire [215:0] sched_blk1_tn1_sys, sched_blk2_tn1_sys;
    wire [215:0] sched_blk1_tn2_sys, sched_blk2_tn2_sys;
    wire [215:0] sched_blk1_tn3_sys, sched_blk2_tn3_sys;
    wire [3:0]   sched_ndb2_sys;
    wire [29:0]  sched_aach_coded_tn0_sys, sched_aach_coded_tn1_sys;
    wire [29:0]  sched_aach_coded_tn2_sys, sched_aach_coded_tn3_sys;
    wire [3:0]   sched_aach_active_sys;
    wire [15:0]  override_cnt_sys;
    wire [15:0]  pop_cnt_sys;

    integer      errors = 0;
    integer      pop_observed = 0;

    always #5 clk = ~clk;

    tetra_dl_signal_scheduler dut (
        .clk_sys               (clk),
        .rst_n_sys             (rst_n),
        .tn_sys                (tn_sys),
        .slot_pulse_sys        (slot_pulse_sys),
        .pop_sys               (pop_sys),
        .head_valid_sys        (head_valid_sys),
        .head_coded_sys        (head_coded_sys),
        .head_pdu_type_sys     (head_pdu_type_sys),
        .head_target_tn_sys    (head_target_tn_sys),
        .head_prio_sys         (head_prio_sys),
        .head_aach_pattern_sys (14'd0),
        .head_aach_coded_sys   (head_aach_coded_sys),
        .head_second_pdu_present_sys (1'b0),
        .head_second_pdu_nr_sys      (1'b0),
        .popped_second_pdu_present_sys (),
        .popped_second_pdu_nr_sys      (),
        .null_pdu_bits_sys     (null_pdu_bits_sys),
        .sig_companion_sys     (sig_companion_sys),
        .sched_blk1_tn0_sys    (sched_blk1_tn0_sys),
        .sched_blk2_tn0_sys    (sched_blk2_tn0_sys),
        .sched_blk1_tn1_sys    (sched_blk1_tn1_sys),
        .sched_blk2_tn1_sys    (sched_blk2_tn1_sys),
        .sched_blk1_tn2_sys    (sched_blk1_tn2_sys),
        .sched_blk2_tn2_sys    (sched_blk2_tn2_sys),
        .sched_blk1_tn3_sys    (sched_blk1_tn3_sys),
        .sched_blk2_tn3_sys    (sched_blk2_tn3_sys),
        .sched_ndb2_sys        (sched_ndb2_sys),
        .sched_active_sys      (),
        .sched_aach_override_tn0_sys (),
        .sched_aach_override_tn1_sys (),
        .sched_aach_override_tn2_sys (),
        .sched_aach_override_tn3_sys (),
        .sched_aach_coded_tn0_sys    (sched_aach_coded_tn0_sys),
        .sched_aach_coded_tn1_sys    (sched_aach_coded_tn1_sys),
        .sched_aach_coded_tn2_sys    (sched_aach_coded_tn2_sys),
        .sched_aach_coded_tn3_sys    (sched_aach_coded_tn3_sys),
        .sched_aach_active_sys       (sched_aach_active_sys),
        .override_cnt_sys      (override_cnt_sys),
        .pop_cnt_sys           (pop_cnt_sys)
    );

    always @(posedge clk) begin
        if (pop_sys) pop_observed <= pop_observed + 1;
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic tick_slot(input [1:0] new_tn);
        begin
            @(negedge clk);
            tn_sys         = new_tn;
            slot_pulse_sys = 1'b1;
            @(posedge clk);
            @(negedge clk);
            slot_pulse_sys = 1'b0;
        end
    endtask

    task automatic check_eq_int(input [31:0] got, input [31:0] exp,
                                input [511:0] msg);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got=%0d exp=%0d", msg, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_eq_h(input [215:0] got, input [215:0] exp,
                              input [511:0] msg);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got[31:0]=%h exp[31:0]=%h",
                         msg, got[31:0], exp[31:0]);
                errors = errors + 1;
            end
        end
    endtask

    // Check all non-target TNs carry the NULL-PDU idle default.
    task automatic check_idle_except(input [1:0] target_tn, input [511:0] tag);
        begin
            if (target_tn !== 2'd0) begin
                check_eq_h(sched_blk1_tn0_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn0"});
                check_eq_h(sched_blk2_tn0_sys, sig_companion_sys, {tag,".idle_blk2_tn0"});
                check_eq_int({31'd0, sched_ndb2_sys[0]}, 1'b1, {tag,".idle_ndb2_tn0"});
            end
            if (target_tn !== 2'd1) begin
                check_eq_h(sched_blk1_tn1_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn1"});
                check_eq_h(sched_blk2_tn1_sys, sig_companion_sys, {tag,".idle_blk2_tn1"});
                check_eq_int({31'd0, sched_ndb2_sys[1]}, 1'b1, {tag,".idle_ndb2_tn1"});
            end
            if (target_tn !== 2'd2) begin
                check_eq_h(sched_blk1_tn2_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn2"});
                check_eq_h(sched_blk2_tn2_sys, sig_companion_sys, {tag,".idle_blk2_tn2"});
                check_eq_int({31'd0, sched_ndb2_sys[2]}, 1'b1, {tag,".idle_ndb2_tn2"});
            end
            if (target_tn !== 2'd3) begin
                check_eq_h(sched_blk1_tn3_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn3"});
                check_eq_h(sched_blk2_tn3_sys, sig_companion_sys, {tag,".idle_blk2_tn3"});
                check_eq_int({31'd0, sched_ndb2_sys[3]}, 1'b1, {tag,".idle_ndb2_tn3"});
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        $display("[tb_dl_signal_scheduler] start");

        // Distinctive 216-bit patterns — byte-repeat to fill exactly 216 bits.
        null_pdu_bits_sys = {27{8'hDE}};
        sig_companion_sys = {27{8'hCA}};

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // -----------------------------------------------------------------
        // T1 — reset state: sched_ndb2 defaults to 4'b1111 idle
        // -----------------------------------------------------------------
        @(negedge clk);
        check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T1.ndb2_all_idle");

        // -----------------------------------------------------------------
        // T2 — empty queue at tn==3 trigger → all TNs idle-defaulted
        // -----------------------------------------------------------------
        head_valid_sys = 1'b0;
        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);
        @(negedge clk);
        check_eq_int({31'd0, pop_sys}, 1'b0, "T2.no_pop");
        // Use target_tn=3 such that none match; all TNs should be idle.
        // Pass an impossible value (0..3 range — use target_tn=3 means TN3 is
        // exempt from idle check).  Easiest: check all 4 idle explicitly.
        check_eq_h(sched_blk1_tn0_sys, null_pdu_bits_sys, "T2.idle_blk1_tn0");
        check_eq_h(sched_blk2_tn0_sys, sig_companion_sys, "T2.idle_blk2_tn0");
        check_eq_h(sched_blk1_tn1_sys, null_pdu_bits_sys, "T2.idle_blk1_tn1");
        check_eq_h(sched_blk2_tn1_sys, sig_companion_sys, "T2.idle_blk2_tn1");
        check_eq_h(sched_blk1_tn2_sys, null_pdu_bits_sys, "T2.idle_blk1_tn2");
        check_eq_h(sched_blk2_tn2_sys, sig_companion_sys, "T2.idle_blk2_tn2");
        check_eq_h(sched_blk1_tn3_sys, null_pdu_bits_sys, "T2.idle_blk1_tn3");
        check_eq_h(sched_blk2_tn3_sys, sig_companion_sys, "T2.idle_blk2_tn3");
        check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T2.ndb2_all_idle");

        // -----------------------------------------------------------------
        // T3 — SCH/F PDU for target TN=1
        // -----------------------------------------------------------------
        head_valid_sys    = 1'b1;
        head_coded_sys    = {{27{8'hA5}}, {27{8'h5A}}};  // top half A5s, bottom half 5As
        head_pdu_type_sys = 2'd0;  // SCH_F
        head_target_tn_sys= 2'd1;

        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);
        @(negedge clk);
        // Target TN=1 carries PDU content
        check_eq_h(sched_blk1_tn1_sys, head_coded_sys[431:216], "T3.tgt_blk1");
        check_eq_h(sched_blk2_tn1_sys, head_coded_sys[215:  0], "T3.tgt_blk2");
        check_eq_int({31'd0, sched_ndb2_sys[1]}, 1'b0, "T3.tgt_ndb2_nts1");
        // Other TNs hold NULL-PDU idle default
        check_idle_except(2'd1, "T3");

        // Drop head (simulate queue now empty)
        head_valid_sys = 1'b0;

        // Stability — walk through next frame; registered values must hold
        tick_slot(2'd0);
        check_eq_h(sched_blk1_tn1_sys, head_coded_sys[431:216], "T3.stable_tn0");
        tick_slot(2'd1);
        check_eq_h(sched_blk1_tn1_sys, head_coded_sys[431:216], "T3.stable_tn1");
        tick_slot(2'd2);
        check_eq_h(sched_blk1_tn1_sys, head_coded_sys[431:216], "T3.stable_tn2");
        // tn==3 with empty head → idle re-latches
        tick_slot(2'd3);
        @(negedge clk);
        check_eq_h(sched_blk1_tn1_sys, null_pdu_bits_sys, "T3.reverts_empty");
        check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T3.ndb2_idle_all");

        // -----------------------------------------------------------------
        // T4 — SCH/HD PDU for target TN=2
        // -----------------------------------------------------------------
        head_valid_sys    = 1'b1;
        head_coded_sys    = {{27{8'h3C}}, {27{8'h00}}};  // SCH/HD: top half used
        head_pdu_type_sys = 2'd1;  // SCH_HD
        head_target_tn_sys= 2'd2;

        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);
        @(negedge clk);
        // SCH/HD: only blk1 is coded; blk2 falls back to sig_companion
        check_eq_h(sched_blk1_tn2_sys, head_coded_sys[431:216], "T4.tgt_blk1");
        check_eq_h(sched_blk2_tn2_sys, sig_companion_sys,       "T4.tgt_blk2_companion");
        check_eq_int({31'd0, sched_ndb2_sys[2]}, 1'b1, "T4.tgt_ndb2_nts2");
        check_idle_except(2'd2, "T4");

        head_valid_sys = 1'b0;
        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);
        @(negedge clk);
        check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T4.cleared");

        // -----------------------------------------------------------------
        // T6 — pop never fires on tn != 3 even with valid head
        // -----------------------------------------------------------------
        head_valid_sys    = 1'b1;
        head_coded_sys    = {216'hFACE, 216'hFACE};
        head_pdu_type_sys = 2'd0;
        head_target_tn_sys= 2'd0;
        pop_observed = 0;
        tick_slot(2'd0);
        tick_slot(2'd1);
        tick_slot(2'd2);
        check_eq_int(pop_observed, 0, "T6.no_pop_on_0_1_2");
        tick_slot(2'd3);
        @(posedge clk);
        @(negedge clk);
        check_eq_int(pop_observed, 1, "T6.pop_on_3");

        // -----------------------------------------------------------------
        // T_Z12 — atomic bundle: pre-coded AACH delivered alongside body.
        //
        // Push a head with a distinguishing aach_coded value, fire pop_trigger
        // (slot_pulse && tn==3), then check that the addressed-TN's coded AACH
        // output equals the head's aach_coded AND sched_aach_active_sys[k]=1.
        // Other TNs must show sched_aach_active_sys[k]=0.
        // -----------------------------------------------------------------
        head_valid_sys      = 1'b1;
        head_coded_sys      = {{27{8'h7E}}, {27{8'h11}}};
        head_pdu_type_sys   = 2'd0;          // SCH_F
        head_target_tn_sys  = 2'd2;
        head_aach_coded_sys = 30'h0CAFEBAB;  // distinctive

        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);
        @(negedge clk);
        // After the tn==3 trigger the bundle is latched.
        check_eq_int({2'd0, sched_aach_coded_tn2_sys}, 32'h0CAFEBAB, "TZ12.coded_target");
        check_eq_int({28'd0, sched_aach_active_sys}, 4'b0100,         "TZ12.active_only_tn2");
        // Drain
        head_valid_sys = 1'b0;
        tick_slot(2'd0); tick_slot(2'd1); tick_slot(2'd2); tick_slot(2'd3);

        // -----------------------------------------------------------------
        // T7 — stats counters: 4 pops so far (T3, T4, T6, TZ12)
        // -----------------------------------------------------------------
        check_eq_int({16'd0, pop_cnt_sys},      16'd4, "T7.pop_cnt");
        check_eq_int({16'd0, override_cnt_sys}, 16'd4, "T7.override_cnt");

        if (errors == 0)
            $display("[tb_dl_signal_scheduler] PASS");
        else
            $display("[tb_dl_signal_scheduler] FAIL — %0d errors", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[tb_dl_signal_scheduler] WATCHDOG timeout");
        $fatal;
    end

endmodule

`default_nettype wire
