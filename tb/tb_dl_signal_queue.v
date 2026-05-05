// =============================================================================
// tb_dl_signal_queue.v — unit test for tetra_dl_signal_queue.v
//
// Coverage:
//   T1 reset → depth=0, head_valid=0
//   T2 single MLE insert + pop → head observed, depth 0 after pop
//   T3 fill to DEPTH=4, 5th insert rejected → drop_cnt++ (drop-newest)
//   T4 strict priority: SDS first, then MLE → MLE head observed despite
//      SDS being inserted earlier
//   T5 same-cycle MLE + CMCE + SDS → MLE survives, drop_cnt += 2
//   T6 tie within same prio: two MLE writes on consecutive cycles → lower
//      slot index (first installed) wins head arbitration
//   T7 depth counters (depth_count, depth_valid_mask) track the state
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_signal_queue;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg          clk   = 1'b0;
    reg          rst_n = 1'b0;

    reg          wr_mle_valid     = 1'b0;
    reg  [431:0] wr_mle_coded     = 432'd0;
    reg  [1:0]   wr_mle_pdu_type  = 2'd0;
    reg  [1:0]   wr_mle_target_tn = 2'd0;
    reg  [29:0]  wr_mle_aach_coded = 30'd0;     // Phase Z.12

    reg          wr_cmce_valid     = 1'b0;
    reg  [431:0] wr_cmce_coded     = 432'd0;
    reg  [1:0]   wr_cmce_pdu_type  = 2'd0;
    reg  [1:0]   wr_cmce_target_tn = 2'd0;

    reg          wr_sds_valid     = 1'b0;
    reg  [431:0] wr_sds_coded     = 432'd0;
    reg  [1:0]   wr_sds_pdu_type  = 2'd0;
    reg  [1:0]   wr_sds_target_tn = 2'd0;

    reg          pop = 1'b0;

    wire         head_valid;
    wire [431:0] head_coded;
    wire [1:0]   head_pdu_type;
    wire [1:0]   head_target_tn;
    wire [1:0]   head_prio;
    wire [29:0]  head_aach_coded;            // Phase Z.12

    wire [3:0]   depth_valid_mask;
    wire [2:0]   depth_count;
    wire [15:0]  drop_cnt;
    wire [7:0]   drop_cnt_mle;
    wire [7:0]   drop_cnt_cmce;
    wire [7:0]   drop_cnt_sds;

    integer      errors = 0;

    always #5 clk = ~clk;

    tetra_dl_signal_queue #(.DEPTH(4)) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .wr_mle_valid     (wr_mle_valid),
        .wr_mle_coded     (wr_mle_coded),
        .wr_mle_pdu_type  (wr_mle_pdu_type),
        .wr_mle_target_tn (wr_mle_target_tn),
        .wr_mle_aach_pattern (14'd0),
        .wr_mle_aach_coded   (wr_mle_aach_coded),
        .wr_mle_second_pdu_present (1'b0),
        .wr_mle_second_pdu_nr      (1'b0),
        .wr_cmce_valid    (wr_cmce_valid),
        .wr_cmce_coded    (wr_cmce_coded),
        .wr_cmce_pdu_type (wr_cmce_pdu_type),
        .wr_cmce_target_tn(wr_cmce_target_tn),
        .wr_cmce_aach_pattern (14'd0),
        .wr_cmce_aach_coded   (30'd0),
        .wr_sds_valid     (wr_sds_valid),
        .wr_sds_coded     (wr_sds_coded),
        .wr_sds_pdu_type  (wr_sds_pdu_type),
        .wr_sds_target_tn (wr_sds_target_tn),
        .wr_sds_aach_pattern (14'd0),
        .wr_sds_aach_coded   (30'd0),
        .pop              (pop),
        .head_valid       (head_valid),
        .head_coded       (head_coded),
        .head_pdu_type    (head_pdu_type),
        .head_target_tn   (head_target_tn),
        .head_prio        (head_prio),
        .head_aach_pattern (),
        .head_aach_coded   (head_aach_coded),
        .head_second_pdu_present (),
        .head_second_pdu_nr      (),
        .depth_valid_mask (depth_valid_mask),
        .depth_count      (depth_count),
        .drop_cnt         (drop_cnt),
        .drop_cnt_mle     (drop_cnt_mle),
        .drop_cnt_cmce    (drop_cnt_cmce),
        .drop_cnt_sds     (drop_cnt_sds)
    );

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic clear_writes;
        begin
            wr_mle_valid  = 1'b0;
            wr_cmce_valid = 1'b0;
            wr_sds_valid  = 1'b0;
        end
    endtask

    task automatic mle_push(input [431:0] coded, input [1:0] tn);
        begin
            @(negedge clk);
            wr_mle_valid     = 1'b1;
            wr_mle_coded     = coded;
            wr_mle_pdu_type  = 2'd0;
            wr_mle_target_tn = tn;
            wr_mle_aach_coded = 30'd0;
            @(posedge clk);
            @(negedge clk);
            wr_mle_valid = 1'b0;
        end
    endtask

    task automatic mle_push_with_aach(input [431:0] coded,
                                      input [1:0] tn,
                                      input [29:0] aach_coded);
        begin
            @(negedge clk);
            wr_mle_valid      = 1'b1;
            wr_mle_coded      = coded;
            wr_mle_pdu_type   = 2'd0;
            wr_mle_target_tn  = tn;
            wr_mle_aach_coded = aach_coded;
            @(posedge clk);
            @(negedge clk);
            wr_mle_valid      = 1'b0;
            wr_mle_aach_coded = 30'd0;
        end
    endtask

    task automatic cmce_push(input [431:0] coded, input [1:0] tn);
        begin
            @(negedge clk);
            wr_cmce_valid     = 1'b1;
            wr_cmce_coded     = coded;
            wr_cmce_pdu_type  = 2'd0;
            wr_cmce_target_tn = tn;
            @(posedge clk);
            @(negedge clk);
            wr_cmce_valid = 1'b0;
        end
    endtask

    task automatic sds_push(input [431:0] coded, input [1:0] tn);
        begin
            @(negedge clk);
            wr_sds_valid     = 1'b1;
            wr_sds_coded     = coded;
            wr_sds_pdu_type  = 2'd0;
            wr_sds_target_tn = tn;
            @(posedge clk);
            @(negedge clk);
            wr_sds_valid = 1'b0;
        end
    endtask

    task automatic do_pop;
        begin
            @(negedge clk);
            pop = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pop = 1'b0;
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

    task automatic check_eq_coded(input [431:0] got, input [431:0] exp,
                                   input [511:0] msg);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got=%h exp=%h", msg, got[31:0], exp[31:0]);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("[tb_dl_signal_queue] start");

        // Release reset after a few cycles
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // -----------------------------------------------------------------
        // T1 — reset state
        // -----------------------------------------------------------------
        @(negedge clk);
        check_eq_int({29'd0, depth_count},     3'd0, "T1.depth");
        check_eq_int({31'd0, head_valid},      1'b0, "T1.head_valid");
        check_eq_int({16'd0, drop_cnt},        16'd0, "T1.drop_cnt");
        check_eq_int({24'd0, drop_cnt_mle},    8'd0, "T1.drop_cnt_mle");
        check_eq_int({24'd0, drop_cnt_cmce},   8'd0, "T1.drop_cnt_cmce");
        check_eq_int({24'd0, drop_cnt_sds},    8'd0, "T1.drop_cnt_sds");

        // -----------------------------------------------------------------
        // T2 — single MLE insert, check head, pop, depth returns to 0
        // -----------------------------------------------------------------
        mle_push(432'hA5A5_DEAD_BEEF_CAFE, 2'd1);
        @(negedge clk);
        check_eq_int({31'd0, head_valid},    1'b1,  "T2.head_valid");
        check_eq_coded(head_coded, 432'hA5A5_DEAD_BEEF_CAFE, "T2.head_coded");
        check_eq_int({30'd0, head_prio},     2'd0,  "T2.head_prio");
        check_eq_int({30'd0, head_target_tn},2'd1,  "T2.head_tn");
        check_eq_int({29'd0, depth_count},   3'd1,  "T2.depth_after_ins");

        do_pop();
        @(negedge clk);
        check_eq_int({31'd0, head_valid},    1'b0,  "T2.head_valid_after_pop");
        check_eq_int({29'd0, depth_count},   3'd0,  "T2.depth_after_pop");

        // -----------------------------------------------------------------
        // T3 — fill to 4, 5th write must increment drop_cnt
        // -----------------------------------------------------------------
        mle_push(432'h1111_0000_0000_0000, 2'd0);
        mle_push(432'h2222_0000_0000_0000, 2'd1);
        mle_push(432'h3333_0000_0000_0000, 2'd2);
        mle_push(432'h4444_0000_0000_0000, 2'd3);
        @(negedge clk);
        check_eq_int({29'd0, depth_count},   3'd4,  "T3.depth_full");
        check_eq_int({28'd0, depth_valid_mask}, 4'b1111, "T3.mask_full");

        mle_push(432'h5555_0000_0000_0000, 2'd0);
        @(negedge clk);
        check_eq_int({29'd0, depth_count},   3'd4,   "T3.depth_still_full");
        check_eq_int({16'd0, drop_cnt},      16'd1,  "T3.drop_cnt");
        // queue-full drop attributed to the only attempting producer (MLE)
        check_eq_int({24'd0, drop_cnt_mle},  8'd1,   "T3.drop_cnt_mle");
        check_eq_int({24'd0, drop_cnt_cmce}, 8'd0,   "T3.drop_cnt_cmce");
        check_eq_int({24'd0, drop_cnt_sds},  8'd0,   "T3.drop_cnt_sds");

        // Drain — head should be the first-inserted entry (lower idx wins ties)
        check_eq_coded(head_coded, 432'h1111_0000_0000_0000, "T3.head_is_first");
        do_pop(); @(negedge clk);
        check_eq_coded(head_coded, 432'h2222_0000_0000_0000, "T3.head_is_second");
        do_pop(); do_pop(); do_pop();
        @(negedge clk);
        check_eq_int({29'd0, depth_count},   3'd0, "T3.depth_drained");

        // -----------------------------------------------------------------
        // T4 — strict priority: push SDS first, then MLE; MLE must be head
        // -----------------------------------------------------------------
        sds_push(432'hDEAD_05D5_CAFE_0000, 2'd0);
        @(negedge clk);
        check_eq_int({30'd0, head_prio}, 2'd2, "T4.sds_head");

        mle_push(432'hBEEF_0111_CAFE_0000, 2'd2);
        @(negedge clk);
        check_eq_int({30'd0, head_prio}, 2'd0, "T4.mle_head_after_insert");
        check_eq_coded(head_coded, 432'hBEEF_0111_CAFE_0000, "T4.mle_head_payload");

        // Drain both
        do_pop();
        @(negedge clk);
        check_eq_int({30'd0, head_prio}, 2'd2, "T4.sds_head_after_mle_pop");
        do_pop();
        @(negedge clk);
        check_eq_int({31'd0, head_valid}, 1'b0, "T4.drained");

        // -----------------------------------------------------------------
        // T5 — concurrent writes: MLE + CMCE + SDS same cycle → MLE wins
        // -----------------------------------------------------------------
        @(negedge clk);
        wr_mle_valid     = 1'b1; wr_mle_coded    = 432'hBEEF_C0DE_A501_0000;
        wr_mle_pdu_type  = 2'd0; wr_mle_target_tn = 2'd1;
        wr_cmce_valid    = 1'b1; wr_cmce_coded   = 432'hCAFE_C0DE_A502_0000;
        wr_cmce_pdu_type = 2'd0; wr_cmce_target_tn = 2'd2;
        wr_sds_valid     = 1'b1; wr_sds_coded    = 432'hDEAD_C0DE_A503_0000;
        wr_sds_pdu_type  = 2'd0; wr_sds_target_tn = 2'd3;
        @(posedge clk);
        @(negedge clk);
        clear_writes();
        @(negedge clk);
        check_eq_int({29'd0, depth_count},   3'd1,  "T5.depth_one_survivor");
        check_eq_int({30'd0, head_prio},     2'd0,  "T5.mle_won");
        check_eq_coded(head_coded, 432'hBEEF_C0DE_A501_0000, "T5.payload");
        // drop_cnt should now be 1 (from T3) + 2 (losers) = 3
        check_eq_int({16'd0, drop_cnt},      16'd3,  "T5.drop_cnt_plus2");
        // Per-producer attribution: T3 → MLE drop=1; T5 → CMCE+SDS drop=1 each.
        check_eq_int({24'd0, drop_cnt_mle},  8'd1,   "T5.drop_cnt_mle");
        check_eq_int({24'd0, drop_cnt_cmce}, 8'd1,   "T5.drop_cnt_cmce");
        check_eq_int({24'd0, drop_cnt_sds},  8'd1,   "T5.drop_cnt_sds");

        do_pop();
        @(negedge clk);
        check_eq_int({31'd0, head_valid}, 1'b0, "T5.drained");

        // -----------------------------------------------------------------
        // T6 — tie within same prio: first insert wins
        // -----------------------------------------------------------------
        mle_push(432'hAAAA_01E1_0000_0000, 2'd0);
        mle_push(432'hBBBB_01E2_0000_0000, 2'd1);
        @(negedge clk);
        check_eq_coded(head_coded, 432'hAAAA_01E1_0000_0000, "T6.first_wins");
        do_pop();
        @(negedge clk);
        check_eq_coded(head_coded, 432'hBBBB_01E2_0000_0000, "T6.second_after_pop");
        do_pop();

        // -----------------------------------------------------------------
        // T8 — Phase Z.12 aach_coded storage
        //   Push a body with a non-zero aach_coded and verify the head
        //   exposes the same value (proves coded AACH is delivered atomically
        //   with the body, no race).
        // -----------------------------------------------------------------
        // Drain any residual head from T6
        do_pop();
        do_pop();
        @(negedge clk);
        check_eq_int({31'd0, head_valid}, 1'b0, "T8.start_drained");

        mle_push_with_aach(432'h7733_BABE_5151_0000, 2'd2,
                           30'h12345678);
        @(negedge clk);
        check_eq_coded(head_coded, 432'h7733_BABE_5151_0000, "T8.head_coded");
        check_eq_int({2'd0, head_aach_coded}, 32'h12345678, "T8.head_aach_coded");
        do_pop();

        // After pop, push a second entry with a different coded AACH —
        // verify head reflects the new value (per-entry storage, not a
        // single shared latch).
        mle_push_with_aach(432'h0011_2233_4455_6677, 2'd1,
                           30'h0DEAD000);
        @(negedge clk);
        check_eq_int({2'd0, head_aach_coded}, 32'h0DEAD000, "T8.head_aach_coded_2");
        do_pop();
        @(negedge clk);
        check_eq_int({31'd0, head_valid}, 1'b0, "T8.drained");

        // -----------------------------------------------------------------
        // Done
        // -----------------------------------------------------------------
        @(negedge clk);
        if (errors == 0)
            $display("[tb_dl_signal_queue] PASS");
        else
            $display("[tb_dl_signal_queue] FAIL — %0d errors", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #100000;
        $display("[tb_dl_signal_queue] WATCHDOG timeout");
        $fatal;
    end

endmodule

`default_nettype wire
