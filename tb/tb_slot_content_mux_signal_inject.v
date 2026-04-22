// =============================================================================
// tb_slot_content_mux_signal_inject.v
//
// Focused test for the MLE-signalling injection path in
// tetra_slot_content_mux.  The override targets RTL tn=0 (= ETSI Slot 1
// = MCCH), the slot where the MS actually listens during registration.
//
// Verifies:
//   1. Before any injection, TN=0 BKN1 follows the scheduled NULL_PDU
//      payload (class=1, idx=0 → null_pdu_bits).
//   2. After a `dl_signal_valid_sys` pulse, `dl_signal_pending_sys` goes
//      HIGH and on the next TN=0 slot_pulse `tx_blk1_slot0_sys` registers
//      the injected bits.
//   3. Pending clears on the slot_pulse for TN=1 (one slot after TN=0
//      transmits) so the next TN=0 cycle returns to the scheduled value.
//   4. Valid pulses arriving AFTER a TN=0 slot_pulse survive TN=1/2/3
//      and are consumed only by the NEXT TN=0 capture.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_slot_content_mux_signal_inject;
    localparam integer BLOCK_BITS = 216;
    localparam integer BB_BITS    = 30;
    localparam integer SB1_BITS   = 120;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // Timebase stimulus
    reg [1:0]  tn = 2'd0;
    reg [4:0]  fn = 5'd0;
    reg [5:0]  mn = 6'd0;
    reg        slot_pulse = 1'b0;
    reg        tdma_tick  = 1'b0;

    // Schedule BRAM stub — return NULL_PDU (class=1, idx=0, enable=1).
    // Bit layout (see tetra_slot_content_mux.v bus_class/bus_idx/bus_is_*):
    //   [15:12]=class, [11:6]=idx, [5:4]=sdb, [3]=ndb2, [2]=enable.
    //   NULL_PDU enabled = 16'b0001_000000_00_0_1_00 = 0x1004.
    wire [8:0]  sched_addr;
    wire [15:0] sched_data = 16'h1004;

    // Static SW payloads — distinctive patterns so we can tell them apart
    wire [BLOCK_BITS-1:0] ndb1 = {27{8'hA1}};
    wire [BLOCK_BITS-1:0] ndb2 = {27{8'hB2}};
    wire [BLOCK_BITS-1:0] mcch1= {27{8'hC3}};
    wire [BLOCK_BITS-1:0] mcch2= {27{8'hD4}};
    wire [BLOCK_BITS-1:0] bnch1= {27{8'hE5}};
    wire [BLOCK_BITS-1:0] bnch2= {27{8'hF6}};
    wire [BLOCK_BITS-1:0] sbkn2= {27{8'h17}};
    wire [BLOCK_BITS-1:0] nullp= {27{8'h28}};

    // Injection inputs
    reg  [BLOCK_BITS-1:0] dl_signal_bits  = {BLOCK_BITS{1'b0}};
    reg                   dl_signal_valid = 1'b0;
    wire                  dl_signal_pending;

    // Outputs
    wire [3:0]            slot_burst_type;
    wire [3:0]            slot_en;
    wire [3:0]            slot_ndb2;
    wire [BLOCK_BITS-1:0] tx_blk1_slot0, tx_blk1_slot1, tx_blk1_slot2, tx_blk1_slot3;
    wire [BLOCK_BITS-1:0] tx_blk2_slot0, tx_blk2_slot1, tx_blk2_slot2, tx_blk2_slot3;
    wire [SB1_BITS-1:0]   sb_sb1_data;
    wire [BB_BITS-1:0]    sb_bb_data;
    wire [15:0]           dbg0, dbg1, dbg2, dbg3;

    tetra_slot_content_mux #(
        .BLOCK_BITS(BLOCK_BITS),
        .BB_BITS   (BB_BITS),
        .SB1_BITS  (SB1_BITS)
    ) dut (
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
        .dl_signal_bits_sys   (dl_signal_bits),
        .dl_signal_valid_sys  (dl_signal_valid),
        .dl_signal_pending_sys(dl_signal_pending),
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

    integer fail_count = 0;
    integer test_count = 0;

    task automatic check_bits(input [BLOCK_BITS-1:0] got,
                          input [BLOCK_BITS-1:0] expected,
                          input [127:0]         tag);
        begin
            test_count = test_count + 1;
            if (got !== expected) begin
                $display("[T%0d %0s] FAIL", test_count, tag);
                $display("  got = %054h", got);
                $display("  exp = %054h", expected);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS bits=%054h", test_count, tag, got);
            end
        end
    endtask

    // Fire a slot_pulse at the given TN and advance the timebase one slot
    task automatic advance_slot(input [1:0] new_tn);
        begin
            @(posedge clk);
            tn         <= new_tn;
            slot_pulse <= 1'b1;
            @(posedge clk);
            slot_pulse <= 1'b0;
            // let combinational + registered outputs settle
            repeat (10) @(posedge clk);
        end
    endtask

    // Run the schedule refresh cycle once so all 4 entries latch
    task automatic prime_schedule;
        begin
            advance_slot(2'd3);           // triggers a schedule refresh
            repeat (12) @(posedge clk);   // let 4 BRAM reads complete
        end
    endtask

    localparam [BLOCK_BITS-1:0] INJECT_PATTERN = {27{8'h99}};

    initial begin
        $dumpfile("sim_out/tb_slot_content_mux_signal_inject.vcd");
        $dumpvars(0, tb_slot_content_mux_signal_inject);

        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        prime_schedule;

        // ----- T1: no injection — TN=0 BKN1 should be NULL_PDU payload -----
        advance_slot(2'd0);
        check_bits(tx_blk1_slot0, nullp, "no_inject");
        if (dl_signal_pending !== 1'b0) begin
            $display("[T* no_inject] FAIL pending should be 0, got %0b",
                     dl_signal_pending);
            fail_count = fail_count + 1;
        end

        // ----- T2: fire injection, verify pending = 1 ----------------------
        @(posedge clk);
        dl_signal_bits  <= INJECT_PATTERN;
        dl_signal_valid <= 1'b1;
        @(posedge clk);
        dl_signal_valid <= 1'b0;
        repeat (4) @(posedge clk);
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b1) begin
            $display("[T%0d pending_set] FAIL pending should be 1", test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d pending_set] PASS", test_count);
        end

        // ----- T3: advance to TN=0 slot_pulse → tx_blk1_slot0 == INJECT ----
        advance_slot(2'd0);
        check_bits(tx_blk1_slot0, INJECT_PATTERN, "inject_bkn1");

        // ----- T4: blk2 should still be NDB2 (NULL_PDU schedule → ndb2) ---
        check_bits(tx_blk2_slot0, ndb2, "blk2_unchanged");

        // ----- T5: advance to TN=1 → pending clears ------------------------
        advance_slot(2'd1);
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b0) begin
            $display("[T%0d pending_clr] FAIL pending still 1", test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d pending_clr] PASS", test_count);
        end

        // ----- T6: next TN=0 should be back to scheduled NULL_PDU ----------
        advance_slot(2'd2);
        advance_slot(2'd3);
        advance_slot(2'd0);
        check_bits(tx_blk1_slot0, nullp, "post_clear");

        // =================================================================
        // Case 2: valid pulses AFTER the TN=0 slot_pulse (the real-world
        // race that was silently dropping injections).  The payload must
        // survive until the NEXT TN=0 slot_pulse and only be consumed once
        // a TN=0 capture has actually happened.
        // =================================================================

        // Park at TN=1 (one past TN=0) and fire the valid pulse there.
        advance_slot(2'd1);
        @(posedge clk);
        dl_signal_bits  <= INJECT_PATTERN;
        dl_signal_valid <= 1'b1;
        @(posedge clk);
        dl_signal_valid <= 1'b0;
        repeat (4) @(posedge clk);

        // ----- T7: pending must be HIGH right after the valid pulse -------
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b1) begin
            $display("[T%0d case2_pending_after_tn0] FAIL pending should be 1",
                     test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d case2_pending_after_tn0] PASS", test_count);
        end

        // ----- T8: pending must SURVIVE TN=2 (no consume before TN=0 seen)-
        advance_slot(2'd2);
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b1) begin
            $display("[T%0d case2_survive_tn2] FAIL pending dropped early",
                     test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d case2_survive_tn2] PASS", test_count);
        end

        // ----- T9: pending must SURVIVE TN=3 ------------------------------
        advance_slot(2'd3);
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b1) begin
            $display("[T%0d case2_survive_tn3] FAIL pending dropped early",
                     test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d case2_survive_tn3] PASS", test_count);
        end

        // ----- T10: advance to TN=0 → tx_blk1_slot0 gets the INJECT -------
        advance_slot(2'd0);
        check_bits(tx_blk1_slot0, INJECT_PATTERN, "case2_capture_tn0");

        // ----- T11: advance to TN=1 → pending finally clears --------------
        advance_slot(2'd1);
        test_count = test_count + 1;
        if (dl_signal_pending !== 1'b0) begin
            $display("[T%0d case2_pending_clr] FAIL pending still 1",
                     test_count);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d case2_pending_clr] PASS", test_count);
        end

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_slot_content_mux_signal_inject: PASS (%0d/%0d)",
                     test_count, test_count);
        else
            $display("tb_slot_content_mux_signal_inject: FAIL (%0d/%0d failures)",
                     fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #500000;
        $display("tb_slot_content_mux_signal_inject: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
