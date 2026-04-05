// =============================================================================
// tb_tetra_pi4dqpsk_demod.v — Self-checking testbench for tetra_pi4dqpsk_demod
// =============================================================================
//
// Test structure:
//   Test 1 — Scenario A: 7 IQ samples → 6 dibit checks (all 4 symbol values).
//             First sample initialises phase_prev; dibits 00, 01, 10, 11, 00, 01
//             are expected from samples 1-6.
//
//   Test 2 — Scenario B: 5 IQ samples → 4 dibit checks (boundary angles).
//             Module is reset between Scenario A and B.
//             Dibits 00, 01, 11, 10 are expected from samples B1-B4.
//
//   Test 3 — Reset mid-computation: Assert reset 8 cycles into S_ITER.
//             After release and re-application of a single sample, no dibit_valid
//             should appear (phase_locked=0 suppresses output on first symbol).
//
// Clock: 100 MHz (10 ns period)
// Reset: active-low async, deasserted after 5 clock cycles
// Latency: 18 clk_sample cycles per symbol (1 S_INIT + 16 S_ITER + 1 S_DECIDE)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_pi4dqpsk_demod;

// =============================================================================
// Parameters
// =============================================================================

localparam IQ_WIDTH    = 16;
localparam PHASE_WIDTH = 16;
localparam CORDIC_ITER = 16;

// Timing
localparam CLK_HALF = 5;       // 5 ns half-period → 100 MHz
localparam LATENCY  = 25;      // Conservative wait for 18-cycle pipeline

// =============================================================================
// DUT signal declarations
// =============================================================================

reg                              clk_tb;
reg                              rst_n_tb;
reg  signed [IQ_WIDTH-1:0]       i_in_tb;
reg  signed [IQ_WIDTH-1:0]       q_in_tb;
reg                              sample_valid_tb;

wire [1:0]                       dibit_out_tb;
wire                             dibit_valid_tb;
wire signed [PHASE_WIDTH-1:0]    phase_error_tb;

// =============================================================================
// DUT instantiation
// =============================================================================

tetra_pi4dqpsk_demod #(
    .IQ_WIDTH    (IQ_WIDTH),
    .PHASE_WIDTH (PHASE_WIDTH),
    .CORDIC_ITER (CORDIC_ITER)
) dut (
    .clk_sample    (clk_tb),
    .rst_n_sample  (rst_n_tb),
    .i_in          (i_in_tb),
    .q_in          (q_in_tb),
    .sample_valid  (sample_valid_tb),
    .dibit_out     (dibit_out_tb),
    .dibit_valid   (dibit_valid_tb),
    .phase_error   (phase_error_tb)
);

// =============================================================================
// Test vector arrays (OK in testbench — R9 exception for initial blocks)
// =============================================================================

// 12 IQ samples total: 7 Scenario A + 5 Scenario B
// Format: [31:16]=Q, [15:0]=I
reg [31:0] iq_in_vectors [0:11];

// 10 expected dibits total: 6 Scenario A + 4 Scenario B
reg [7:0]  dibit_exp_vectors [0:9];

// Test counters
integer error_count;
integer timeout;

// =============================================================================
// Clock generation
// =============================================================================

initial clk_tb = 1'b0;

always #CLK_HALF clk_tb = ~clk_tb;

// =============================================================================
// Task: apply_sample
// Apply one IQ sample with sample_valid high for exactly 1 clock cycle.
// =============================================================================

task apply_sample;
    input [31:0] iq_word;   // [31:16]=Q, [15:0]=I
    begin
        i_in_tb          <= $signed(iq_word[15:0]);
        q_in_tb          <= $signed(iq_word[31:16]);
        sample_valid_tb  <= 1'b1;
        @(posedge clk_tb);
        #1;
        sample_valid_tb <= 1'b0;
    end
endtask

// =============================================================================
// Task: wait_and_check
// Wait for dibit_valid (timeout=50 cycles), compare to expected, log result.
// =============================================================================

task wait_and_check;
    input [1:0]   expected_dibit;
    input integer scenario;
    input integer sample_num;
    reg [1:0]   got_dibit;
    begin
        timeout = 0;
        while (!dibit_valid_tb && timeout < 50) begin
            @(posedge clk_tb);
            #1;
            timeout = timeout + 1;
        end
        got_dibit = dibit_out_tb;
        if (timeout >= 50) begin
            $display("FAIL: Scenario %0d Sample %0d — TIMEOUT waiting for dibit_valid",
                     scenario, sample_num);
            error_count = error_count + 1;
        end else if (got_dibit !== expected_dibit) begin
            $display("FAIL: Scenario %0d Sample %0d — got dibit=%02b, expected=%02b",
                     scenario, sample_num, got_dibit, expected_dibit);
            error_count = error_count + 1;
        end else begin
            $display("PASS: Scenario %0d Sample %0d — dibit=%02b correct",
                     scenario, sample_num, got_dibit);
        end
        @(posedge clk_tb);
        #1;
    end
endtask

// =============================================================================
// Main test sequence
// =============================================================================

integer i;
integer valid_count;

initial begin
    // -------------------------------------------------------------------------
    // Initialise signals
    // -------------------------------------------------------------------------
    error_count     = 0;
    i               = 0;
    valid_count     = 0;
    rst_n_tb        = 1'b0;
    i_in_tb         = {IQ_WIDTH{1'b0}};
    q_in_tb         = {IQ_WIDTH{1'b0}};
    sample_valid_tb = 1'b0;

    // -------------------------------------------------------------------------
    // Load test vectors from hex files generated by gen_pi4dqpsk_vectors.py
    // -------------------------------------------------------------------------
    $readmemh("vectors/pi4dqpsk_iq_in.hex",    iq_in_vectors);
    $readmemh("vectors/pi4dqpsk_dibit_out.hex", dibit_exp_vectors);

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    $dumpfile("tb_tetra_pi4dqpsk_demod.vcd");
    $dumpvars(0, tb_tetra_pi4dqpsk_demod);

    // -------------------------------------------------------------------------
    // Reset: hold for 5 cycles, then release
    // -------------------------------------------------------------------------
    repeat (5) @(posedge clk_tb);
    #1;
    rst_n_tb = 1'b1;
    repeat (2) @(posedge clk_tb);
    #1;

    // =========================================================================
    // TEST 1 — Scenario A: all four dibit values
    // =========================================================================
    $display("\n=== TEST 1: Scenario A (dibits 00,01,10,11,00,01) ===");

    // Sample A0: initialise phase_prev — no dibit expected
    apply_sample(iq_in_vectors[0]);
    // Wait for S_DECIDE to complete (18 cycles pipeline)
    repeat (LATENCY) @(posedge clk_tb);
    #1;

    // Samples A1-A6: each produces one dibit
    for (i = 1; i <= 6; i = i + 1) begin
        apply_sample(iq_in_vectors[i]);
        wait_and_check(dibit_exp_vectors[i-1][1:0], 1, i);
    end

    // =========================================================================
    // TEST 2 — Scenario B: boundary angles, after reset
    // =========================================================================
    $display("\n=== TEST 2: Scenario B (dibits 00,01,11,10) — after reset ===");

    // Assert reset for 3 cycles
    rst_n_tb = 1'b0;
    repeat (3) @(posedge clk_tb);
    #1;
    rst_n_tb = 1'b1;
    // Allow reset propagation
    repeat (5) @(posedge clk_tb);
    #1;

    // Sample B0: initialise phase_prev — no dibit expected
    // iq_in_vectors[7] = Scenario B sample 0 (index 7 in the 12-entry array)
    apply_sample(iq_in_vectors[7]);
    repeat (LATENCY) @(posedge clk_tb);
    #1;

    // Samples B1-B4: each produces one dibit
    // dibit_exp_vectors[6..9] = Scenario B expected dibits (after 6 from A)
    for (i = 1; i <= 4; i = i + 1) begin
        apply_sample(iq_in_vectors[7 + i]);
        wait_and_check(dibit_exp_vectors[6 + (i-1)][1:0], 2, i);
    end

    // =========================================================================
    // TEST 3 — Reset mid-computation
    // Verify that after a reset during S_ITER, the next symbol does NOT produce
    // a dibit_valid (phase_locked = 0 on first symbol post-reset).
    // =========================================================================
    $display("\n=== TEST 3: Reset mid-computation (no dibit_valid expected) ===");

    // Full reset first
    rst_n_tb = 1'b0;
    repeat (3) @(posedge clk_tb);
    #1;
    rst_n_tb = 1'b1;
    repeat (3) @(posedge clk_tb);
    #1;

    // Apply one sample to start computation
    // Use I=20000, Q=10000 (arbitrary point inside unit circle)
    i_in_tb         <= $signed(16'd20000);
    q_in_tb         <= $signed(16'd10000);
    sample_valid_tb <= 1'b1;
    @(posedge clk_tb);
    #1;
    sample_valid_tb <= 1'b0;

    // Wait 8 cycles into S_ITER, then assert reset
    repeat (8) @(posedge clk_tb);
    #1;
    rst_n_tb = 1'b0;
    repeat (3) @(posedge clk_tb);
    #1;
    rst_n_tb = 1'b1;
    repeat (5) @(posedge clk_tb);
    #1;

    // Apply the same sample again — this is the FIRST symbol post-reset.
    // phase_locked = 0, so after S_DECIDE no dibit_valid should appear.
    i_in_tb         <= $signed(16'd20000);
    q_in_tb         <= $signed(16'd10000);
    sample_valid_tb <= 1'b1;
    @(posedge clk_tb);
    #1;
    sample_valid_tb <= 1'b0;

    // Monitor for 30 cycles; count any dibit_valid pulses
    valid_count = 0;
    repeat (30) begin
        @(posedge clk_tb);
        #1;
        if (dibit_valid_tb)
            valid_count = valid_count + 1;
    end

    if (valid_count == 0)
        $display("PASS: Test 3 — no dibit_valid after reset (phase_locked=0 correct)");
    else begin
        $display("FAIL: Test 3 — %0d unexpected dibit_valid pulse(s) after reset",
                 valid_count);
        error_count = error_count + 1;
    end

    // =========================================================================
    // Final report
    // =========================================================================
    $display("\n=== FINAL REPORT ===");
    if (error_count == 0)
        $display("ALL TESTS PASSED — 10/10 dibit checks correct");
    else
        $display("TESTS FAILED — %0d errors", error_count);

    $finish;
end

// =============================================================================
// Watchdog: terminate if simulation runs too long
// =============================================================================

initial begin
    #500000;
    $display("WATCHDOG: Simulation timeout at 500 us");
    $finish;
end

endmodule

`default_nettype wire
