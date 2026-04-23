// =============================================================================
// tb_dl_signal_integration.v — end-to-end queue + scheduler + slot_content_mux
//
// Stimulus emits queue-writes on the MLE producer port (since that is the
// only real producer in MVP; CMCE/SDS are tied off in top-level).  The
// scheduler pops at tn==3 slot_pulse and drives the override bundle into
// the mux.  We verify that the target TN's BKN1/BKN2 outputs register the
// pushed 432-bit SCH/F pattern for the whole NEXT frame.
//
// Coverage:
//   T1 No queue traffic → target TN shows schedule payload (NULL_PDU)
//   T2 Push SCH/F @ target_tn=1, target=1, target_tn=2, and verify:
//        - override_active=1 from tn==3 trigger through next frame
//        - tx_blk1_slot2 and tx_blk2_slot2 contain the pushed half
//        - other slots unaffected
//        - slot_ndb2[2]=0 (SCH/F = NTS1)
//   T3 Push SCH/HD → only blk1 of target TN replaced, slot_ndb2[tgt]=1
//   T4 Drain to empty → next tn==3 trigger clears override
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_signal_integration;
    localparam integer BLOCK_BITS = 216;
    localparam integer BB_BITS    = 30;
    localparam integer SB1_BITS   = 120;

    // -------------------------------------------------------------------------
    // Clock + reset
    // -------------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Timebase
    // -------------------------------------------------------------------------
    reg [1:0] tn = 2'd0;
    reg [4:0] fn = 5'd0;
    reg [5:0] mn = 6'd0;
    reg       slot_pulse = 1'b0;
    reg       tdma_tick  = 1'b0;

    // Schedule stub — NULL_PDU everywhere so BKN1 is deterministic.
    // Encoding (see tetra_slot_content_mux.v bus layout):
    //   [15:12]=class, [11:6]=idx, [5:4]=sdb, [3]=ndb2, [2]=enable.
    //   NULL_PDU (class=1, idx=0) enabled, ndb2=1 → 16'h100C.
    wire [8:0]  sched_addr;
    wire [15:0] sched_data = 16'h100C;

    // Static SW payloads — distinctive so we can verify the override replaced
    // schedule content.  NULL_PDU takes its bits from null_pdu_bits_sys.
    wire [BLOCK_BITS-1:0] ndb1 = {27{8'hA1}};
    wire [BLOCK_BITS-1:0] ndb2 = {27{8'hB2}};
    wire [BLOCK_BITS-1:0] mcch1= {27{8'hC3}};
    wire [BLOCK_BITS-1:0] mcch2= {27{8'hD4}};
    wire [BLOCK_BITS-1:0] bnch1= {27{8'hE5}};
    wire [BLOCK_BITS-1:0] bnch2= {27{8'hF6}};
    wire [BLOCK_BITS-1:0] sbkn2= {27{8'h17}};
    wire [BLOCK_BITS-1:0] nullp= {27{8'h28}};

    // -------------------------------------------------------------------------
    // Queue producer stimulus (MLE port)
    // -------------------------------------------------------------------------
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

    // Scheduler → mux
    wire         ov_active;
    wire [1:0]   ov_target_tn;
    wire         ov_use_blk1;
    wire         ov_use_blk2;
    wire         ov_ndb2;
    wire [215:0] ov_blk1;
    wire [215:0] ov_blk2;
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
        .wr_cmce_valid    (1'b0),
        .wr_cmce_coded    (432'd0),
        .wr_cmce_pdu_type (2'd0),
        .wr_cmce_target_tn(2'd0),
        .wr_sds_valid     (1'b0),
        .wr_sds_coded     (432'd0),
        .wr_sds_pdu_type  (2'd0),
        .wr_sds_target_tn (2'd0),
        .pop              (sched_pop),
        .head_valid       (queue_head_valid),
        .head_coded       (queue_head_coded),
        .head_pdu_type    (queue_head_pdu_type),
        .head_target_tn   (queue_head_target_tn),
        .head_prio        (queue_head_prio),
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
        .override_active_sys   (ov_active),
        .override_target_tn_sys(ov_target_tn),
        .override_use_blk1_sys (ov_use_blk1),
        .override_use_blk2_sys (ov_use_blk2),
        .override_ndb2_sys     (ov_ndb2),
        .override_blk1_sys     (ov_blk1),
        .override_blk2_sys     (ov_blk2),
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
        .null_pdu_bits_sys    (nullp),
        .override_active_sys    (ov_active),
        .override_target_tn_sys (ov_target_tn),
        .override_use_blk1_sys  (ov_use_blk1),
        .override_use_blk2_sys  (ov_use_blk2),
        .override_ndb2_sys      (ov_ndb2),
        .override_blk1_sys      (ov_blk1),
        .override_blk2_sys      (ov_blk2),
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

    // Advance one slot — fire slot_pulse for 1 cycle at negedge→posedge,
    // then run 20 more cycles to let schedule refresh+capture ripple.
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

    // Run a full frame starting at tn=0 — this triggers the pop at tn==3.
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

        // Distinctive SCH/F pattern — MSB half 0xDEAD..., LSB half 0xBEEF...
        coded_schf  = {216'hDEAD_0001_0002_0003_0004_0005_0006_0007_0008_0009_000A_000B_000C,
                       216'hBEEF_A001_A002_A003_A004_A005_A006_A007_A008_A009_A00A_A00B_A00C};
        coded_schhd = {216'hCAFE_0101_0202_0303_0404_0505_0606_0707_0808_0909_0A0A_0B0B_0C0C,
                       216'h0};  // LSB unused for SCH_HD

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Prime: drive a couple of full frames with schedule refresh so that
        // internal sched_entry registers for all 4 TNs latch.
        full_frame();
        full_frame();

        // -----------------------------------------------------------------
        // T1 — no queue traffic, override inactive, target TN shows NULL_PDU
        // -----------------------------------------------------------------
        check_eq_int({31'd0, ov_active}, 1'b0, "T1.ov_inactive");

        // -----------------------------------------------------------------
        // T2 — push SCH/F targeting TN=2, run one frame to trigger pop,
        // then during next frame verify TN=2 halves contain the pushed bits.
        // -----------------------------------------------------------------
        push_mle(coded_schf, 2'd0, 2'd2);  // SCH_F, target TN=2
        // Run to TN=3 of the current frame — pop fires there.
        full_frame();
        // After tn==3 trigger, override bundle is registered.  Check.
        check_eq_int({31'd0, ov_active},    1'b1, "T2.ov_active");
        check_eq_int({30'd0, ov_target_tn}, 2'd2, "T2.ov_tgt");
        check_eq_int({31'd0, ov_use_blk1},  1'b1, "T2.use_blk1");
        check_eq_int({31'd0, ov_use_blk2},  1'b1, "T2.use_blk2");
        check_eq_int({31'd0, ov_ndb2},      1'b0, "T2.ndb2_nts1");

        // Now walk through the next frame — at TN=2 the mux outputs must
        // carry the pushed payload.  Mux outputs tx_blkX_slotN_sys are
        // combinational over the latched schedule + override, so check
        // after each advance_slot.
        advance_slot(2'd0);
        check_eq_blk(tx_blk1_slot2, coded_schf[431:216], "T2.tn2_blk1_stable");
        check_eq_blk(tx_blk2_slot2, coded_schf[215:  0], "T2.tn2_blk2_stable");
        // Other TNs still schedule (NULL_PDU → nullp bits)
        check_eq_blk(tx_blk1_slot0, nullp, "T2.tn0_nullp");
        check_eq_blk(tx_blk1_slot1, nullp, "T2.tn1_nullp");
        check_eq_blk(tx_blk1_slot3, nullp, "T2.tn3_nullp");
        // slot_ndb2[2] must be 0 (SCH/F = NTS1).  Other TNs keep schedule's 1.
        check_eq_int({28'd0, slot_ndb2}, 4'b1011, "T2.slot_ndb2_mask");

        // -----------------------------------------------------------------
        // T3 — push SCH/HD targeting TN=1, then run another frame.
        // (queue is already empty after T2's pop, so this is the only entry.)
        // -----------------------------------------------------------------
        push_mle(coded_schhd, 2'd1, 2'd1);  // SCH_HD, target TN=1
        full_frame();   // triggers pop at tn==3
        check_eq_int({31'd0, ov_active},    1'b1, "T3.ov_active");
        check_eq_int({30'd0, ov_target_tn}, 2'd1, "T3.ov_tgt");
        check_eq_int({31'd0, ov_use_blk1},  1'b1, "T3.use_blk1");
        check_eq_int({31'd0, ov_use_blk2},  1'b0, "T3.no_blk2");
        check_eq_int({31'd0, ov_ndb2},      1'b1, "T3.ndb2_nts2");

        advance_slot(2'd0);
        check_eq_blk(tx_blk1_slot1, coded_schhd[431:216], "T3.tn1_blk1");
        // tn1 blk2 must remain schedule-driven since SCH/HD only overrides
        // blk1.  For NULL_PDU (class=1, ndb2=1) the mux sources blk2 from
        // the NDB2 bank, not from null_pdu_bits.
        check_eq_blk(tx_blk2_slot1, ndb2, "T3.tn1_blk2_unchanged");
        // slot_ndb2[1] must be 1 now (NTS2); schedule NULL_PDU also has ndb2=1
        check_eq_int({28'd0, slot_ndb2}, 4'b1111, "T3.slot_ndb2_all1");

        // -----------------------------------------------------------------
        // T4 — queue drained now (only one entry, popped).  Next frame
        // triggers the "empty at tn==3" path → override clears.
        // -----------------------------------------------------------------
        full_frame();
        check_eq_int({31'd0, ov_active}, 1'b0, "T4.ov_cleared");

        // Final stats — scheduler should have popped 2 PDUs total
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
