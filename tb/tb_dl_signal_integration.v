// =============================================================================
// tb_dl_signal_integration.v — end-to-end queue + scheduler + slot_content_mux
//
// Phase Z.13 (2026-05-04): the scheduler is now a pure combinational fan-out
// of queue.head — no bundle latch.  Pop fires at slot_pulse@target_tn (the
// slot that actually transmits the popped PDU), not at slot_pulse@tn==3.
// The slot_content_mux's tx_blk1_slotK_sys outputs continuously follow
// the queue.head combinationally (via blk1_mux_tnK_sys), with one cycle
// of clock latency.  As long as queue.head stays valid, tx_blk1_slot2 =
// head_coded[431:216].
//
// Schedule stub drives class=SIGNALLING (16'h100C) for every slot so that
// mux outputs tx_blk*_slot* equal the scheduler's per-TN outputs.
//
// Coverage:
//   T1 No queue traffic → every TN carries NULL-PDU idle default
//        (tx_blk1 = null_pdu_bits, tx_blk2 = sig_companion, slot_ndb2 = 1111)
//   T2 Push SCH/F @ target_tn=2 → tx_blk1_slot2/blk2_slot2 carry coded;
//        other TNs stay on NULL-PDU idle; slot_ndb2[2]=0, others=1
//   T3 Push SCH/HD @ target_tn=1 → TN=1 blk1=coded[431:216], blk2=companion,
//        slot_ndb2[1]=1; others idle
//   T4 After slot_pulse@target_tn pops the queue, next frame reverts to idle
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_signal_integration;
    localparam integer BLOCK_BITS = 216;
    localparam integer BB_BITS    = 30;
    localparam integer SB1_BITS   = 120;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg [1:0] tn = 2'd0;
    reg [4:0] fn = 5'd0;
    reg [5:0] mn = 6'd0;
    reg       slot_pulse = 1'b0;
    reg       tdma_tick  = 1'b0;

    // Schedule stub — class=SIGNALLING (class=1, idx=0, sdb=00, ndb2=1,
    // enable=1) → 16'h100C for every slot so that all TN outputs reflect
    // the scheduler's per-TN bundle directly.
    wire [8:0]  sched_addr;
    wire [15:0] sched_data = 16'h100C;

    // Static SW payloads — distinctive.  For class=SIGNALLING slots these
    // are ignored (the scheduler drives blk1/blk2).  Kept for bank wiring.
    wire [BLOCK_BITS-1:0] ndb1 = {27{8'hA1}};
    wire [BLOCK_BITS-1:0] ndb2 = {27{8'hB2}};
    wire [BLOCK_BITS-1:0] mcch1= {27{8'hC3}};
    wire [BLOCK_BITS-1:0] mcch2= {27{8'hD4}};
    wire [BLOCK_BITS-1:0] bnch1= {27{8'hE5}};
    wire [BLOCK_BITS-1:0] bnch2= {27{8'hF6}};
    wire [BLOCK_BITS-1:0] sbkn2= {27{8'h17}};

    // Scheduler idle-default sources
    wire [BLOCK_BITS-1:0] nullp   = {27{8'h28}};
    wire [BLOCK_BITS-1:0] sigcomp = {27{8'h39}};

    // Queue producer stimulus (MLE port)
    reg          q_wr_valid     = 1'b0;
    reg  [431:0] q_wr_coded     = 432'd0;
    reg  [1:0]   q_wr_pdu_type  = 2'd0;
    reg  [1:0]   q_wr_target_tn = 2'd0;

    // Queue → scheduler
    wire         queue_head_valid;
    wire [431:0] queue_head_coded;
    wire [1:0]   queue_head_pdu_type;
    wire [1:0]   queue_head_target_tn;
    wire [1:0]   queue_head_prio;
    wire         sched_pop;
    wire [3:0]   queue_depth_mask;
    wire [2:0]   queue_depth_count;
    wire [15:0]  queue_drop_cnt;

    // Scheduler → mux (per-TN bundle)
    wire [215:0] s_blk1_tn0, s_blk2_tn0;
    wire [215:0] s_blk1_tn1, s_blk2_tn1;
    wire [215:0] s_blk1_tn2, s_blk2_tn2;
    wire [215:0] s_blk1_tn3, s_blk2_tn3;
    wire [3:0]   s_ndb2;
    wire [15:0]  ov_pop_cnt;
    wire [15:0]  ov_override_cnt;

    // Mux outputs
    wire [3:0]   slot_burst_type;
    wire [3:0]   slot_en;
    wire [3:0]   slot_ndb2;
    wire [BLOCK_BITS-1:0] tx_blk1_slot0, tx_blk1_slot1, tx_blk1_slot2, tx_blk1_slot3;
    wire [BLOCK_BITS-1:0] tx_blk2_slot0, tx_blk2_slot1, tx_blk2_slot2, tx_blk2_slot3;
    wire [SB1_BITS-1:0]   sb_sb1_data;
    wire [BB_BITS-1:0]    sb_bb_data;
    wire [15:0]           dbg0, dbg1, dbg2, dbg3;

    // -------------------------------------------------------------------------
    // DUT: queue + scheduler + mux
    // -------------------------------------------------------------------------
    tetra_dl_signal_queue #(.DEPTH(4)) u_q (
        .clk              (clk),
        .rst_n            (rst_n),
        .wr_mle_valid     (q_wr_valid),
        .wr_mle_coded     (q_wr_coded),
        .wr_mle_pdu_type  (q_wr_pdu_type),
        .wr_mle_target_tn (q_wr_target_tn),
        .wr_mle_aach_pattern (14'd0),
        .wr_mle_second_pdu_present (1'b0),
        .wr_mle_second_pdu_nr      (1'b0),
        .wr_cmce_valid    (1'b0),
        .wr_cmce_coded    (432'd0),
        .wr_cmce_pdu_type (2'd0),
        .wr_cmce_target_tn(2'd0),
        .wr_cmce_aach_pattern (14'd0),
        .wr_sds_valid     (1'b0),
        .wr_sds_coded     (432'd0),
        .wr_sds_pdu_type  (2'd0),
        .wr_sds_target_tn (2'd0),
        .wr_sds_aach_pattern (14'd0),
        .pop              (sched_pop),
        .head_valid       (queue_head_valid),
        .head_coded       (queue_head_coded),
        .head_pdu_type    (queue_head_pdu_type),
        .head_target_tn   (queue_head_target_tn),
        .head_prio        (queue_head_prio),
        .head_aach_pattern       (),
        .head_second_pdu_present (),
        .head_second_pdu_nr      (),
        .depth_valid_mask (queue_depth_mask),
        .depth_count      (queue_depth_count),
        .drop_cnt         (queue_drop_cnt)
    );

    // Phase Z.13 — sched_active_sys is now a real output (combinational
    // one-hot from head_target_tn).  We need it locally to drive
    // slot_content_mux's dynamic-class lift, since the schedule stub
    // already declares class=SIGNALLING for every slot but the mux
    // input still needs to be tied properly.
    wire [3:0] s_active;

    tetra_dl_signal_scheduler u_s (
        .clk_sys               (clk),
        .rst_n_sys             (rst_n),
        .tn_sys                (tn),
        .slot_pulse_sys        (slot_pulse),
        .pop_sys               (sched_pop),
        .head_valid_sys        (queue_head_valid),
        .head_coded_sys        (queue_head_coded),
        .head_pdu_type_sys     (queue_head_pdu_type),
        .head_target_tn_sys    (queue_head_target_tn),
        .head_prio_sys         (queue_head_prio),
        .head_second_pdu_present_sys (1'b0),
        .head_second_pdu_nr_sys      (1'b0),
        .popped_second_pdu_present_sys (),
        .popped_second_pdu_nr_sys      (),
        .null_pdu_bits_sys     (nullp),
        .sig_companion_sys     (sigcomp),
        .sched_blk1_tn0_sys    (s_blk1_tn0),
        .sched_blk2_tn0_sys    (s_blk2_tn0),
        .sched_blk1_tn1_sys    (s_blk1_tn1),
        .sched_blk2_tn1_sys    (s_blk2_tn1),
        .sched_blk1_tn2_sys    (s_blk1_tn2),
        .sched_blk2_tn2_sys    (s_blk2_tn2),
        .sched_blk1_tn3_sys    (s_blk1_tn3),
        .sched_blk2_tn3_sys    (s_blk2_tn3),
        .sched_ndb2_sys        (s_ndb2),
        .sched_active_sys      (s_active),
        .override_cnt_sys      (ov_override_cnt),
        .pop_cnt_sys           (ov_pop_cnt)
    );

    tetra_slot_content_mux #(
        .BLOCK_BITS(BLOCK_BITS),
        .BB_BITS   (BB_BITS),
        .SB1_BITS  (SB1_BITS)
    ) u_mux (
        .clk_sys              (clk),
        .rst_n_sys            (rst_n),
        .tn_sys               (tn),
        .fn_sys               (fn),
        .mn_sys               (mn),
        .slot_pulse_sys       (slot_pulse),
        .tdma_tick_sys        (tdma_tick),
        .sched_addr_sys       (sched_addr),
        .sched_data_sys       (sched_data),
        .sb1_coded_sys        ({SB1_BITS{1'b0}}),
        .sb1_valid_sys        (1'b0),
        .aach_coded_sys       ({BB_BITS{1'b0}}),
        .aach_valid_sys       (1'b0),
        .ndb_block1_sw_sys    (ndb1),
        .ndb_block2_sw_sys    (ndb2),
        .mcch_block1_sw_sys   (mcch1),
        .mcch_block2_sw_sys   (mcch2),
        .bnch_block1_sw_sys   (bnch1),
        .bnch_block2_sw_sys   (bnch2),
        .sb_bkn2_sw_sys       (sbkn2),
        .sched_blk1_tn0_sys   (s_blk1_tn0),
        .sched_blk2_tn0_sys   (s_blk2_tn0),
        .sched_blk1_tn1_sys   (s_blk1_tn1),
        .sched_blk2_tn1_sys   (s_blk2_tn1),
        .sched_blk1_tn2_sys   (s_blk1_tn2),
        .sched_blk2_tn2_sys   (s_blk2_tn2),
        .sched_blk1_tn3_sys   (s_blk1_tn3),
        .sched_blk2_tn3_sys   (s_blk2_tn3),
        .sched_ndb2_sys       (s_ndb2),
        .sched_active_sys     (s_active),
        .slot_burst_type_sys  (slot_burst_type),
        .slot_en_sys          (slot_en),
        .slot_ndb2_sys        (slot_ndb2),
        .tx_blk1_slot0_sys    (tx_blk1_slot0),
        .tx_blk1_slot1_sys    (tx_blk1_slot1),
        .tx_blk1_slot2_sys    (tx_blk1_slot2),
        .tx_blk1_slot3_sys    (tx_blk1_slot3),
        .tx_blk2_slot0_sys    (tx_blk2_slot0),
        .tx_blk2_slot1_sys    (tx_blk2_slot1),
        .tx_blk2_slot2_sys    (tx_blk2_slot2),
        .tx_blk2_slot3_sys    (tx_blk2_slot3),
        .sb_sb1_data_sys      (sb_sb1_data),
        .sb_bb_data_sys       (sb_bb_data),
        .dbg_sched_entry0_sys (dbg0),
        .dbg_sched_entry1_sys (dbg1),
        .dbg_sched_entry2_sys (dbg2),
        .dbg_sched_entry3_sys (dbg3)
    );

    integer errors = 0;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic push_mle(input [431:0] coded, input [1:0] ptype,
                            input [1:0] tgt_tn);
        begin
            @(negedge clk);
            q_wr_valid     = 1'b1;
            q_wr_coded     = coded;
            q_wr_pdu_type  = ptype;
            q_wr_target_tn = tgt_tn;
            @(posedge clk);
            @(negedge clk);
            q_wr_valid = 1'b0;
        end
    endtask

    task automatic advance_slot(input [1:0] new_tn);
        begin
            @(negedge clk);
            tn         = new_tn;
            slot_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            slot_pulse = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    task automatic full_frame;
        begin
            advance_slot(2'd0);
            advance_slot(2'd1);
            advance_slot(2'd2);
            advance_slot(2'd3);
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

    task automatic check_eq_blk(input [BLOCK_BITS-1:0] got,
                                input [BLOCK_BITS-1:0] exp,
                                input [511:0] msg);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s:\n    got=%054h\n    exp=%054h",
                         msg, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    reg [431:0] coded_schf;
    reg [431:0] coded_schhd;

    initial begin
        $display("[tb_dl_signal_integration] start");

        coded_schf  = {216'hDEAD_0001_0002_0003_0004_0005_0006_0007_0008_0009_000A_000B_000C,
                       216'hBEEF_A001_A002_A003_A004_A005_A006_A007_A008_A009_A00A_A00B_A00C};
        coded_schhd = {216'hCAFE_0101_0202_0303_0404_0505_0606_0707_0808_0909_0A0A_0B0B_0C0C,
                       216'h0};

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Prime: let schedule BRAM refresh latch all 4 TNs.
        full_frame();
        full_frame();

        // -----------------------------------------------------------------
        // T1 — no queue traffic.  All 4 TNs carry NULL-PDU idle defaults.
        // -----------------------------------------------------------------
        check_eq_blk(tx_blk1_slot0, nullp,   "T1.tn0_blk1_idle");
        check_eq_blk(tx_blk2_slot0, sigcomp, "T1.tn0_blk2_idle");
        check_eq_blk(tx_blk1_slot1, nullp,   "T1.tn1_blk1_idle");
        check_eq_blk(tx_blk2_slot1, sigcomp, "T1.tn1_blk2_idle");
        check_eq_blk(tx_blk1_slot2, nullp,   "T1.tn2_blk1_idle");
        check_eq_blk(tx_blk2_slot2, sigcomp, "T1.tn2_blk2_idle");
        check_eq_blk(tx_blk1_slot3, nullp,   "T1.tn3_blk1_idle");
        check_eq_blk(tx_blk2_slot3, sigcomp, "T1.tn3_blk2_idle");
        check_eq_int({28'd0, slot_ndb2}, 4'b1111, "T1.ndb2_all_idle");

        // -----------------------------------------------------------------
        // T2 — push SCH/F targeting TN=2.  Queue.head is valid combinationally;
        // tx_blk1_slot2 follows it through blk1_mux_tn2 (1 clock latency).
        // We check BEFORE the pop fires (i.e. on slot_pulses for TN!=2).
        // -----------------------------------------------------------------
        push_mle(coded_schf, 2'd0, 2'd2);
        // Step a tn=0 slot_pulse so the registered tx_blk1_slot2 picks up
        // the head value (1 clock for the mux register to settle).
        advance_slot(2'd0);
        // Target TN=2 carries PDU content (registered from queue.head)
        check_eq_blk(tx_blk1_slot2, coded_schf[431:216], "T2.tn2_blk1");
        check_eq_blk(tx_blk2_slot2, coded_schf[215:  0], "T2.tn2_blk2");
        // Other TNs hold NULL-PDU idle default
        check_eq_blk(tx_blk1_slot0, nullp,   "T2.tn0_blk1_idle");
        check_eq_blk(tx_blk2_slot0, sigcomp, "T2.tn0_blk2_idle");
        check_eq_blk(tx_blk1_slot1, nullp,   "T2.tn1_blk1_idle");
        check_eq_blk(tx_blk2_slot1, sigcomp, "T2.tn1_blk2_idle");
        check_eq_blk(tx_blk1_slot3, nullp,   "T2.tn3_blk1_idle");
        check_eq_blk(tx_blk2_slot3, sigcomp, "T2.tn3_blk2_idle");
        // slot_ndb2 — TN=2 bit is 0 (NTS1 for SCH/F), others 1
        check_eq_int({28'd0, slot_ndb2}, 4'b1011, "T2.slot_ndb2_mask");
        // Now fire slot_pulse@tn=2 → pop fires.
        advance_slot(2'd1);
        advance_slot(2'd2);          // pops the queue
        advance_slot(2'd3);          // mux refresh trigger; head=0 by now → defaults
        // After the pop fires, the next frame reverts to idle.
        advance_slot(2'd0);
        check_eq_blk(tx_blk1_slot2, nullp,   "T2.reverts_after_pop_tn2");

        // -----------------------------------------------------------------
        // T3 — push SCH/HD targeting TN=1 (queue empty after T2 pop)
        // -----------------------------------------------------------------
        push_mle(coded_schhd, 2'd1, 2'd1);
        advance_slot(2'd0);          // tn=0 doesn't pop; tx_blk1_slot1 settles
        // SCH/HD: TN=1 blk1 = coded[431:216], blk2 = sig_companion
        check_eq_blk(tx_blk1_slot1, coded_schhd[431:216], "T3.tn1_blk1");
        check_eq_blk(tx_blk2_slot1, sigcomp,              "T3.tn1_blk2_companion");
        // Other TNs idle
        check_eq_blk(tx_blk1_slot0, nullp,   "T3.tn0_idle");
        check_eq_blk(tx_blk1_slot2, nullp,   "T3.tn2_idle");
        check_eq_blk(tx_blk1_slot3, nullp,   "T3.tn3_idle");
        // slot_ndb2 all 1 (SCH/HD on TN=1 is NTS2; others idle NTS2)
        check_eq_int({28'd0, slot_ndb2}, 4'b1111, "T3.slot_ndb2_all1");
        // Pop fires on slot_pulse@tn=1.
        advance_slot(2'd1);          // pops
        advance_slot(2'd2);
        advance_slot(2'd3);
        advance_slot(2'd0);
        check_eq_blk(tx_blk1_slot1, nullp,   "T3.reverts_after_pop_tn1");

        // -----------------------------------------------------------------
        // T4 — queue drained, next full frame → idle re-latches everywhere
        // -----------------------------------------------------------------
        full_frame();
        advance_slot(2'd0);
        check_eq_blk(tx_blk1_slot1, nullp, "T4.reverts_idle_tn1");

        // Final stats — scheduler popped 2 PDUs total
        check_eq_int({16'd0, ov_pop_cnt},      16'd2, "T4.pop_cnt");
        check_eq_int({16'd0, ov_override_cnt}, 16'd2, "T4.override_cnt");
        check_eq_int({16'd0, queue_drop_cnt},  16'd0, "T4.no_drops");

        if (errors == 0)
            $display("[tb_dl_signal_integration] PASS");
        else
            $display("[tb_dl_signal_integration] FAIL — %0d errors", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("[tb_dl_signal_integration] WATCHDOG timeout");
        $fatal;
    end

endmodule

`default_nettype wire
