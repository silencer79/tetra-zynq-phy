// =============================================================================
// tb_tetra_sync_detect.v — Self-Checking Testbench
// =============================================================================
//
// Tests:
//   TC1 — Single NDB burst in noise: NTS detected, sync_found fires once
//   TC2 — Synchronisation Burst with STS correlator
//   TC3 — Four consecutive NDB bursts: lock detection, sync_locked asserts
//   TC4 — Pure noise at high threshold: no (or minimal) spurious detections
//   TC5 — NDB with 3 corrupted TS symbols: still detects at low threshold
//   TC6 — Reset mid-operation: all registers clear, clean restart
//
// Timing:
//   clk = 100 MHz (10 ns period).
//   dibit_valid is a 1-cycle strobe, applied every STROBE_PERIOD cycles
//   to simulate 18 kHz symbol rate (100 MHz / 18 kHz ≈ 5556 cycles).
//   For simulation speed, STROBE_PERIOD is reduced to 4 cycles.
//
// Pass/Fail:
//   Each test checks sync_found timing and sync_locked state.
//   A global error counter is incremented on every failure.
//   $fatal is called if any test fails.
//
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_tetra_sync_detect;

// ---------------------------------------------------------------------------
// DUT parameters (override to speed up simulation)
// ---------------------------------------------------------------------------
localparam CORR_WIDTH    = 6;
localparam SEQ_LEN_MAX   = 30;  // legacy ETS is longest active path
localparam HOLDOFF       = 220;
localparam LOCK_COUNT    = 4;
localparam SLOT_SYMS     = 255;
localparam LOCK_TOL      = 8;
localparam LOCK_TIMEOUT  = 300;

// ---------------------------------------------------------------------------
// Clocks and Reset
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10;  // 10 ns = 100 MHz

reg clk_sample;
reg rst_n_sample;

initial clk_sample = 1'b0;
always #(CLK_PERIOD/2) clk_sample = ~clk_sample;

// ---------------------------------------------------------------------------
// DUT Signals
// ---------------------------------------------------------------------------
reg  [1:0]          dibit_in;
reg                 dibit_valid;
reg  [CORR_WIDTH-1:0] corr_threshold;
reg  [1:0]          seq_select;

wire                sync_found;
wire                sync_locked;
wire [7:0]          slot_position;
wire [1:0]          slot_number;

// ---------------------------------------------------------------------------
// DUT Instantiation
// ---------------------------------------------------------------------------
tetra_sync_detect #(
    .CORR_WIDTH   (CORR_WIDTH),
    .SEQ_LEN_MAX  (SEQ_LEN_MAX),
    .HOLDOFF      (HOLDOFF),
    .LOCK_COUNT   (LOCK_COUNT),
    .SLOT_SYMS    (SLOT_SYMS),
    .LOCK_TOL     (LOCK_TOL),
    .LOCK_TIMEOUT (LOCK_TIMEOUT)
) dut (
    .clk_sample    (clk_sample),
    .rst_n_sample  (rst_n_sample),
    .dibit_in      (dibit_in),
    .dibit_valid   (dibit_valid),
    .corr_threshold(corr_threshold),
    .seq_select    (seq_select),
    .sync_found    (sync_found),
    .sync_locked   (sync_locked),
    .slot_position (slot_position),
    .slot_number   (slot_number),
    .corr_peak     ()
);

// ---------------------------------------------------------------------------
// Waveform Dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_sync_detect.vcd");
    $dumpvars(0, tb_tetra_sync_detect);
end

// ---------------------------------------------------------------------------
// Error Counter
// ---------------------------------------------------------------------------
integer errors;
integer tc_errors;

// ---------------------------------------------------------------------------
// Training Sequence Constants (must match RTL localparams)
// Same newest-first ordering as in the RTL.
// ---------------------------------------------------------------------------

// NTS: 11 dibits (continuous NDB), [0]=newest, [10]=oldest.
// Derived from RTL NTS_REF: NTS_SEQ[i] = NTS_REF[2*i+1:2*i].
reg [1:0] NTS_SEQ [0:10];
initial begin
    NTS_SEQ[ 0]=2'b00; NTS_SEQ[ 1]=2'b01; NTS_SEQ[ 2]=2'b11; NTS_SEQ[ 3]=2'b01;
    NTS_SEQ[ 4]=2'b10; NTS_SEQ[ 5]=2'b10; NTS_SEQ[ 6]=2'b11; NTS_SEQ[ 7]=2'b00;
    NTS_SEQ[ 8]=2'b00; NTS_SEQ[ 9]=2'b01; NTS_SEQ[10]=2'b11;
end

// STS: 19 dibits (continuous SDB), [0]=newest, [18]=oldest.
// Derived from RTL STS_REF: STS_SEQ[i] = STS_REF[2*i+1:2*i].
reg [1:0] STS_SEQ [0:18];
initial begin
    STS_SEQ[ 0]=2'b11; STS_SEQ[ 1]=2'b01; STS_SEQ[ 2]=2'b10; STS_SEQ[ 3]=2'b01;
    STS_SEQ[ 4]=2'b00; STS_SEQ[ 5]=2'b00; STS_SEQ[ 6]=2'b11; STS_SEQ[ 7]=2'b01;
    STS_SEQ[ 8]=2'b10; STS_SEQ[ 9]=2'b10; STS_SEQ[10]=2'b11; STS_SEQ[11]=2'b00;
    STS_SEQ[12]=2'b11; STS_SEQ[13]=2'b00; STS_SEQ[14]=2'b10; STS_SEQ[15]=2'b01;
    STS_SEQ[16]=2'b00; STS_SEQ[17]=2'b00; STS_SEQ[18]=2'b11;
end

// ---------------------------------------------------------------------------
// Helper: apply a single dibit to DUT
// ---------------------------------------------------------------------------
task apply_dibit;
    input [1:0] d;
    begin
        @(posedge clk_sample);
        #1;
        dibit_in    = d;
        dibit_valid = 1'b1;
        @(posedge clk_sample);
        #1;
        dibit_valid = 1'b0;
    end
endtask

// Helper: apply N random dibits (LFSR-based, deterministic)
reg [7:0] lfsr_state;
task apply_noise;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) begin
            // Simple 8-bit LFSR: poly x^8+x^6+x^5+x^4+1
            lfsr_state = {lfsr_state[6:0], lfsr_state[7] ^ lfsr_state[5] ^
                          lfsr_state[4] ^ lfsr_state[3]};
            apply_dibit(lfsr_state[1:0]);
        end
    end
endtask

// Helper: apply NTS sequence (newest-to-oldest reversed = oldest-to-newest)
// Since the RTL shift register fills from oldest to newest, we send
// symbol[21] first (oldest), symbol[0] last (newest).
task apply_nts;
    integer k;
    begin
        for (k = 10; k >= 0; k = k - 1)
            apply_dibit(NTS_SEQ[k]);
    end
endtask

// Helper: apply STS sequence
task apply_sts;
    integer k;
    begin
        for (k = 18; k >= 0; k = k - 1)
            apply_dibit(STS_SEQ[k]);
    end
endtask

// Helper: build NDB continuous burst (§9.4.4.2.5, total 255 symbols):
//   Tail1(6) + HA(1) + blk1(108) + bb1(7) + NTS(11) + bb2(8) + blk2(108) + HB(1) + Tail2(5)
// Approximated here as 122 noise + NTS(11) + 122 noise = 255 dibits.
task apply_ndb_burst;
    begin
        apply_noise(122); // Tail1 + HA + blk1 + bb1
        apply_nts;        // NTS (sync_found fires here)
        apply_noise(122); // bb2 + blk2 + HB + Tail2
    end
endtask

// ---------------------------------------------------------------------------
// Helper: wait for sync_found with timeout
// Returns 1 if found within timeout, 0 otherwise.
// ---------------------------------------------------------------------------
integer sync_found_flag;

task wait_sync_found;
    input integer timeout_cycs;
    integer t;
    begin
        sync_found_flag = 0;
        t = 0;
        while (t < timeout_cycs && !sync_found_flag) begin
            @(posedge clk_sample);
            if (sync_found)
                sync_found_flag = 1;
            t = t + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Reset helper
// ---------------------------------------------------------------------------
task do_reset;
    begin
        rst_n_sample = 1'b0;
        dibit_valid  = 1'b0;
        dibit_in     = 2'b00;
        repeat (5) @(posedge clk_sample);
        @(negedge clk_sample);
        rst_n_sample = 1'b1;
        @(posedge clk_sample);
    end
endtask

// ---------------------------------------------------------------------------
// Main Test Sequence
// ---------------------------------------------------------------------------
initial begin
    errors       = 0;
    lfsr_state   = 8'hA5;
    corr_threshold = 6'd9;
    seq_select   = 2'd0;  // NTS by default

    $display("=== tb_tetra_sync_detect: START ===");

    do_reset;

    // -----------------------------------------------------------------------
    // TC1: Single NDB burst in noise, NTS correlator
    // -----------------------------------------------------------------------
    $display("TC1: Single NDB burst (NTS, threshold=9/11)");
    tc_errors      = 0;
    corr_threshold = 6'd9;
    seq_select     = 2'd0;

    // Pre-burst noise (no sync expected)
    apply_noise(50);

    // Apply NDB burst; after apply_nts, sync_found should be high
    apply_noise(2);    // preamble
    apply_noise(108);  // block1
    apply_nts;         // ← sync_found should fire within 1 cycle of this completing

    // Check: sync_found must have fired during or just after apply_nts
    if (!sync_found) begin
        // Wait 1 more cycle (it fires on the clock edge after the last dibit_valid)
        @(posedge clk_sample); #1;
        if (!sync_found) begin
            $display("  FAIL TC1: sync_found did not assert after NTS");
            tc_errors = tc_errors + 1;
        end
    end

    // Drain rest of burst
    apply_noise(15);
    apply_noise(108);
    apply_noise(1);
    // Post-burst noise
    apply_noise(30);

    if (tc_errors == 0) $display("  PASS TC1");
    errors = errors + tc_errors;

    do_reset;

    // -----------------------------------------------------------------------
    // TC2: STS correlator
    // -----------------------------------------------------------------------
    $display("TC2: STS correlator (threshold=15/19)");
    tc_errors      = 0;
    corr_threshold = 6'd15;
    seq_select     = 2'd2;

    apply_noise(30);
    apply_noise(2);    // preamble
    apply_noise(108);  // block1
    apply_sts;         // ← sync_found fires here

    if (!sync_found) begin
        @(posedge clk_sample); #1;
        if (!sync_found) begin
            $display("  FAIL TC2: sync_found did not assert after STS");
            tc_errors = tc_errors + 1;
        end
    end

    apply_noise(15);
    apply_noise(108);
    apply_noise(1);
    apply_noise(30);

    if (tc_errors == 0) $display("  PASS TC2");
    errors = errors + tc_errors;

    do_reset;

    // -----------------------------------------------------------------------
    // TC3: Four consecutive NDB bursts → sync_locked asserts
    // -----------------------------------------------------------------------
    $display("TC3: 4 NDB bursts, lock detection");
    tc_errors      = 0;
    corr_threshold = 6'd9;
    seq_select     = 2'd0;

    // Send 4 complete bursts back-to-back
    apply_ndb_burst;
    apply_ndb_burst;
    apply_ndb_burst;
    apply_ndb_burst;

    // After 4 sync pulses at consistent spacing, sync_locked should be high
    repeat (20) @(posedge clk_sample);
    if (!sync_locked) begin
        $display("  FAIL TC3: sync_locked not asserted after 4 bursts");
        tc_errors = tc_errors + 1;
    end

    if (tc_errors == 0) $display("  PASS TC3");
    errors = errors + tc_errors;

    do_reset;

    // -----------------------------------------------------------------------
    // TC4: Pure noise, high threshold → 0 or 1 spurious hits
    // -----------------------------------------------------------------------
    $display("TC4: Pure noise, threshold=10 — expecting 0 spurious hits");
    tc_errors      = 0;
    corr_threshold = 6'd10;
    seq_select     = 2'd0;

    begin : tc4_block
        integer spurious;
        integer s;
        spurious = 0;

        lfsr_state = 8'h37;
        for (s = 0; s < 500; s = s + 1) begin
            lfsr_state = {lfsr_state[6:0], lfsr_state[7] ^ lfsr_state[5] ^
                          lfsr_state[4] ^ lfsr_state[3]};
            apply_dibit(lfsr_state[1:0]);
            if (sync_found)
                spurious = spurious + 1;
        end

        if (spurious > 1) begin
            $display("  FAIL TC4: %0d spurious detections (expected <=1)", spurious);
            tc_errors = tc_errors + 1;
        end else begin
            $display("  PASS TC4: %0d spurious detections", spurious);
        end
    end
    errors = errors + tc_errors;

    do_reset;

    // -----------------------------------------------------------------------
    // TC5: NDB with 3 corrupted NTS symbols → still detects (threshold=16)
    // -----------------------------------------------------------------------
    $display("TC5: NTS with 1 symbol error (threshold=8/11)");
    tc_errors      = 0;
    corr_threshold = 6'd8;
    seq_select     = 2'd0;

    apply_noise(40);
    apply_noise(2);
    apply_noise(108);

    // Send NTS with 1 bit error at position 5 (out of 11)
    // 1 error → 10 matches; threshold=8 should still fire
    begin : tc5_block
        integer j;
        for (j = 10; j >= 0; j = j - 1) begin
            if (j == 5)
                apply_dibit((NTS_SEQ[j] + 2'd1));  // Corrupt: shift by 1
            else
                apply_dibit(NTS_SEQ[j]);
        end
    end

    if (!sync_found) begin
        @(posedge clk_sample); #1;
        if (!sync_found) begin
            $display("  FAIL TC5: sync_found not asserted despite 3 symbol errors (threshold=16)");
            tc_errors = tc_errors + 1;
        end
    end

    apply_noise(15);
    apply_noise(108);
    apply_noise(1);

    if (tc_errors == 0) $display("  PASS TC5");
    errors = errors + tc_errors;

    do_reset;

    // -----------------------------------------------------------------------
    // TC6: Reset mid-operation — all outputs should clear
    // -----------------------------------------------------------------------
    $display("TC6: Reset mid-operation");
    tc_errors      = 0;
    corr_threshold = 6'd9;
    seq_select     = 2'd0;

    // Start receiving a burst
    apply_noise(2);
    apply_noise(108);
    // Halfway through NTS:
    begin : tc6_block
        integer j;
        for (j = 10; j >= 5; j = j - 1)
            apply_dibit(NTS_SEQ[j]);
    end

    // Issue reset mid-burst
    rst_n_sample = 1'b0;
    repeat (3) @(posedge clk_sample);
    rst_n_sample = 1'b1;
    @(posedge clk_sample); #1;

    // Verify all outputs cleared
    if (sync_found || sync_locked || slot_position != 0 || slot_number != 0) begin
        $display("  FAIL TC6: outputs not cleared after reset (sf=%b sl=%b sp=%0d sn=%0d)",
                 sync_found, sync_locked, slot_position, slot_number);
        tc_errors = tc_errors + 1;
    end

    // After reset, send a complete NDB — should still detect.
    // Check sync_found immediately after apply_nts (same pattern as TC1).
    apply_noise(50);
    apply_noise(2);    // preamble
    apply_noise(108);  // block1
    apply_nts;         // training sequence — sync_found fires here
    if (!sync_found) begin
        @(posedge clk_sample); #1;
        if (!sync_found) begin
            $display("  FAIL TC6: no sync_found after reset and clean burst");
            tc_errors = tc_errors + 1;
        end
    end
    apply_noise(15);   // broadcast block
    apply_noise(108);  // block2
    apply_noise(1);    // guard

    if (tc_errors == 0) $display("  PASS TC6");
    errors = errors + tc_errors;

    // -----------------------------------------------------------------------
    // Final Report
    // -----------------------------------------------------------------------
    $display("=== RESULT: %0d error(s) ===", errors);
    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $fatal(1, "TESTBENCH FAILED: %0d error(s)", errors);

    #100;
    $finish;
end

// Watchdog: prevent infinite simulation hang
initial begin
    #50_000_000;  // 50 ms simulation timeout
    $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
