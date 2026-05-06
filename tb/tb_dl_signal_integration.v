// =============================================================================
// tb_dl_signal_integration.v — end-to-end queue + scheduler + slot_content_mux
//                              (BRAM prefetch) + tetra_burst_dispatcher
//
// Phase Y.3 (2026-05-05): the post-pop pipeline collapsed from 8 stages to 3.
// tetra_slot_content_mux is now BRAM-prefetch only; tetra_burst_dispatcher
// captures body/burst_type/ndb2/bb/sb1 in a single mux + flop driven by
// tx_slot_pulse_sys.  This TB verifies the queue/scheduler still drive the
// dispatcher correctly across the same body + ndb2 cases the old TB covered.
//
// Schedule stub drives class=SIGNALLING (16'h100C) for every slot so that
// the dispatcher's per-slot mux always takes the scheduler-bundle path.
//
// Coverage (per-slot, after a full frame primes the BRAM prefetch):
//   T1 No queue traffic → every TN, when pulsed, gets NULL-PDU body
//        (build_block1 = null_pdu_bits, build_block2 = sig_companion,
//         build_ndb2 = 1).
//   T2 Push SCH/F @ target_tn=2 → pulse on TN=2 yields
//        build_block1 = coded[431:216], build_block2 = coded[215:0],
//        build_ndb2 = 0; pulses on other TNs still get NULL-PDU idle.
//   T3 Pop fires on slot_pulse@target_tn → next pulse on TN=2 reverts to
//        NULL-PDU idle.
//   T4 Push SCH/HD @ target_tn=1 → pulse on TN=1 yields
//        build_block1 = coded[431:216], build_block2 = sig_companion,
//        build_ndb2 = 1.
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
    // enable=1) → 16'h100C for every slot so that all TN paths reflect the
    // scheduler's per-TN bundle directly.
    wire [8:0]  sched_addr;
    wire [15:0] sched_data = 16'h100C;

    // Static SW payloads — distinctive but unused on signalling slots.
    wire [BLOCK_BITS-1:0] ndb1 = {27{8'hA1}};
    wire [BLOCK_BITS-1:0] ndb2v= {27{8'hB2}};
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

    // Scheduler → mux/dispatcher (per-TN bundle)
    wire [215:0] s_blk1_tn0, s_blk2_tn0;
    wire [215:0] s_blk1_tn1, s_blk2_tn1;
    wire [215:0] s_blk1_tn2, s_blk2_tn2;
    wire [215:0] s_blk1_tn3, s_blk2_tn3;
    wire [3:0]   s_ndb2;
    wire [3:0]   s_active;
    wire [15:0]  ov_pop_cnt;
    wire [15:0]  ov_override_cnt;

    // BRAM-prefetch outputs (latched schedule entries)
    wire [15:0] ent0, ent1, ent2, ent3;
    wire [15:0] dbg0, dbg1, dbg2, dbg3;

    // Dispatcher outputs (the new "tx_blk1_slot*" equivalent — captured at
    // the pulse for the slot being driven)
    wire [BLOCK_BITS-1:0] build_block1, build_block2;
    wire [BB_BITS-1:0]    build_bb;
    wire [SB1_BITS-1:0]   build_sb1;
    wire                  build_burst_type, build_ndb2, build_req;

    // -------------------------------------------------------------------------
    // DUT: queue + scheduler + slot_content_mux (prefetch) + burst_dispatcher
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

    tetra_slot_content_mux u_mux (
        .clk_sys              (clk),
        .rst_n_sys            (rst_n),
        .tn_sys               (tn),
        .fn_sys               (fn),
        .mn_sys               (mn),
        .slot_pulse_sys       (slot_pulse),
        .tdma_tick_sys        (tdma_tick),
        .sched_addr_sys       (sched_addr),
        .sched_data_sys       (sched_data),
        .sched_entry_reg_sys0 (ent0),
        .sched_entry_reg_sys1 (ent1),
        .sched_entry_reg_sys2 (ent2),
        .sched_entry_reg_sys3 (ent3),
        .dbg_sched_entry0_sys (dbg0),
        .dbg_sched_entry1_sys (dbg1),
        .dbg_sched_entry2_sys (dbg2),
        .dbg_sched_entry3_sys (dbg3)
    );

    tetra_burst_dispatcher #(
        .BLOCK_BITS(BLOCK_BITS),
        .BB_BITS   (BB_BITS),
        .SB1_BITS  (SB1_BITS)
    ) u_disp (
        .clk_sys              (clk),
        .rst_n_sys            (rst_n),
        .tx_slot_pulse_sys    (slot_pulse),
        .tx_slot_num_sys      (tn),
        .sched_blk1_tn0_sys   (s_blk1_tn0),
        .sched_blk2_tn0_sys   (s_blk2_tn0),
        .sched_blk1_tn1_sys   (s_blk1_tn1),
        .sched_blk2_tn1_sys   (s_blk2_tn1),
        .sched_blk1_tn2_sys   (s_blk1_tn2),
        .sched_blk2_tn2_sys   (s_blk2_tn2),
        .sched_blk1_tn3_sys   (s_blk1_tn3),
        .sched_blk2_tn3_sys   (s_blk2_tn3),
        .sched_active_sys     (s_active),
        .sched_ndb2_sys       (s_ndb2),
        .sched_entry_reg_sys0 (ent0),
        .sched_entry_reg_sys1 (ent1),
        .sched_entry_reg_sys2 (ent2),
        .sched_entry_reg_sys3 (ent3),
        .ndb_block1_sw_sys    (ndb1),
        .ndb_block2_sw_sys    (ndb2v),
        .mcch_block1_sw_sys   (mcch1),
        .mcch_block2_sw_sys   (mcch2),
        .bnch_block1_sw_sys   (bnch1),
        .bnch_block2_sw_sys   (bnch2),
        .sb_bkn2_sw_sys       (sbkn2),
        .bb_in_sys            ({BB_BITS{1'b0}}),
        .sb_sb1_in_sys        ({SB1_BITS{1'b0}}),
        .tx_busy_sys          (1'b0),
        .build_block1_sys     (build_block1),
        .build_block2_sys     (build_block2),
        .build_bb_sys         (build_bb),
        .build_sb1_sys        (build_sb1),
        .build_burst_type_sys (build_burst_type),
        .build_ndb2_sys       (build_ndb2),
        .build_req_sys        (build_req)
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

    // Drive a slot_pulse for slot new_tn.  The dispatcher captures
    // build_*_sys at posedge clk_sys with slot_pulse high.  After the
    // edge those outputs are stable until the next pulse.
    task automatic pulse_slot(input [1:0] new_tn);
        begin
            @(negedge clk);
            tn         = new_tn;
            slot_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            slot_pulse = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // tn=3 slot triggers the BRAM-prefetch refresh inside u_mux; needs
    // ~10 cycles for S_RD0..S_CAP3 to populate ent0..ent3.
    task automatic prefetch_frame;
        integer w;
        begin
            @(negedge clk);
            tn         = 2'd3;
            fn         = 5'd0;
            mn         = 6'd0;
            slot_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            slot_pulse = 1'b0;
            for (w = 0; w < 12; w = w + 1) @(posedge clk);
            #1;
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

        // Prime: run a tn=3 prefetch so all 4 schedule entries land in ent0..3.
        prefetch_frame();

        // -----------------------------------------------------------------
        // T1 — no queue traffic.  Pulse each TN; expect NULL-PDU idle.
        // -----------------------------------------------------------------
        $display("=== T1: idle on every TN ===");
        pulse_slot(2'd0);
        check_eq_blk(build_block1, nullp,   "T1.tn0_blk1_idle");
        check_eq_blk(build_block2, sigcomp, "T1.tn0_blk2_idle");
        check_eq_int({31'd0, build_ndb2}, 32'd1, "T1.tn0_ndb2");

        pulse_slot(2'd1);
        check_eq_blk(build_block1, nullp,   "T1.tn1_blk1_idle");
        check_eq_blk(build_block2, sigcomp, "T1.tn1_blk2_idle");

        pulse_slot(2'd2);
        check_eq_blk(build_block1, nullp,   "T1.tn2_blk1_idle");
        check_eq_blk(build_block2, sigcomp, "T1.tn2_blk2_idle");

        pulse_slot(2'd3);
        check_eq_blk(build_block1, nullp,   "T1.tn3_blk1_idle");
        check_eq_blk(build_block2, sigcomp, "T1.tn3_blk2_idle");

        // -----------------------------------------------------------------
        // T2 — push SCH/F @ target_tn=2.  Pulse TN=0/1: still idle (head
        // routes only to its target).  Pulse TN=2: scheduler bundle wins.
        // -----------------------------------------------------------------
        $display("=== T2: push SCH/F target_tn=2 ===");
        push_mle(coded_schf, 2'd0, 2'd2);
        // Pop fires only on slot_pulse@tn==2; pulses on other TNs leave
        // the queue head intact.
        pulse_slot(2'd0);
        check_eq_blk(build_block1, nullp,   "T2.tn0_blk1_idle");
        check_eq_blk(build_block2, sigcomp, "T2.tn0_blk2_idle");

        pulse_slot(2'd1);
        check_eq_blk(build_block1, nullp,   "T2.tn1_blk1_idle");

        pulse_slot(2'd2);
        check_eq_blk(build_block1, coded_schf[431:216], "T2.tn2_blk1_coded");
        check_eq_blk(build_block2, coded_schf[215:  0], "T2.tn2_blk2_coded");
        check_eq_int({31'd0, build_ndb2}, 32'd0, "T2.tn2_ndb2_zero");

        // -----------------------------------------------------------------
        // T3 — pulse TN=2 popped the queue.  Next pulse on TN=2 reverts.
        // -----------------------------------------------------------------
        $display("=== T3: post-pop revert ===");
        @(posedge clk); #1;     // settle queue.entry_valid clear
        pulse_slot(2'd2);
        check_eq_blk(build_block1, nullp,   "T3.tn2_revert_idle");
        check_eq_blk(build_block2, sigcomp, "T3.tn2_revert_companion");

        // -----------------------------------------------------------------
        // T4 — push SCH/HD @ target_tn=1.  Pulse TN=1 captures coded.
        // -----------------------------------------------------------------
        $display("=== T4: push SCH/HD target_tn=1 ===");
        push_mle(coded_schhd, 2'd1, 2'd1);
        pulse_slot(2'd1);
        check_eq_blk(build_block1, coded_schhd[431:216], "T4.tn1_blk1_coded");
        // SCH/HD: blk2 = sig_companion
        check_eq_blk(build_block2, sigcomp,              "T4.tn1_blk2_companion");
        check_eq_int({31'd0, build_ndb2}, 32'd1,         "T4.tn1_ndb2_one");

        // Final stats — scheduler popped 2 PDUs total
        check_eq_int({16'd0, ov_pop_cnt},     16'd2, "TF.pop_cnt");
        check_eq_int({16'd0, queue_drop_cnt}, 16'd0, "TF.no_drops");

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
