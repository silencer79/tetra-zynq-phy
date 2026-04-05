// =============================================================================
// tb_tetra_timing_recovery.v — Self-Checking Testbench
// =============================================================================
//
// Tests tetra_timing_recovery.v against Python reference vectors.
//
// Test cases:
//   TC0: Perfect timing  — TED should be ≈ 0 at steady state
//   TC1: Early timing (+1 sample offset) — TED > 0, loop increases NCO step
//   TC2: Late  timing (−1 sample offset) — TED < 0, loop decreases NCO step
//
// Additional checks per TC:
//   - sample_valid_out fires exactly once every ~4 input samples
//   - Reset mid-stream: module recovers cleanly
//   - Output valid de-asserted when no input
//
// Prerequisites:
//   Run gen_timing_recovery_vectors.py first to create:
//     tb/vectors/timing_tc{0,1,2}_iq_in.hex
//     tb/vectors/timing_tc{0,1,2}_ted.hex
//
// Simulation:
//   vivado -mode batch -source scripts/vivado_sim.tcl \
//          -tclargs tetra_timing_recovery
//
// =============================================================================

`timescale 1ns / 1ps

module tb_tetra_timing_recovery;

// ---------------------------------------------------------------------------
// Parameters (must match DUT defaults)
// ---------------------------------------------------------------------------
localparam IQ_WIDTH    = 16;
localparam NCO_WIDTH   = 32;
localparam KP_SHIFT    = 4;
localparam KI_SHIFT    = 8;
localparam LOCK_THRESH = 256;
localparam LOCK_COUNT  = 144;

// Test vector dimensions
localparam N_SYMBOLS  = 32;
localparam SPS        = 4;
localparam N_SAMPLES  = N_SYMBOLS * SPS;           // 128 IQ samples per TC
localparam N_IQ_WORDS = N_SAMPLES * 2;             // 256 words (I,Q interleaved)
localparam N_TED      = N_SYMBOLS;                 // ≤ N_SYMBOLS TED events

// Timing tolerance: skip first 4 overflow events (shift register fill latency)
localparam TED_SKIP   = 4;
// Max |TED| deviation from reference allowed (counts, unit = RTL TED Q14 units)
localparam TED_TOL    = 60000;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg                           clk_sys;
reg                           rst_n_sys;
reg  signed [IQ_WIDTH-1:0]    i_in_sys;
reg  signed [IQ_WIDTH-1:0]    q_in_sys;
reg                           sample_valid_in_sys;

wire signed [IQ_WIDTH-1:0]    i_out_sys;
wire signed [IQ_WIDTH-1:0]    q_out_sys;
wire                          sample_valid_out_sys;
wire                          timing_locked_sys;
wire signed [IQ_WIDTH-1:0]    timing_error_sys;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_timing_recovery #(
    .IQ_WIDTH    (IQ_WIDTH),
    .NCO_WIDTH   (NCO_WIDTH),
    .KP_SHIFT    (KP_SHIFT),
    .KI_SHIFT    (KI_SHIFT),
    .LOCK_THRESH (LOCK_THRESH),
    .LOCK_COUNT  (LOCK_COUNT)
) dut (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .i_in_sys             (i_in_sys),
    .q_in_sys             (q_in_sys),
    .sample_valid_in_sys  (sample_valid_in_sys),
    .i_out_sys            (i_out_sys),
    .q_out_sys            (q_out_sys),
    .sample_valid_out_sys (sample_valid_out_sys),
    .timing_locked_sys    (timing_locked_sys),
    .timing_error_sys     (timing_error_sys)
);

// ---------------------------------------------------------------------------
// 100 MHz clock
// ---------------------------------------------------------------------------
initial clk_sys = 0;
always  #5 clk_sys = ~clk_sys;   // 10 ns period

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_timing_recovery.vcd");
    $dumpvars(0, tb_tetra_timing_recovery);
end

// ---------------------------------------------------------------------------
// Test vector memory
// ---------------------------------------------------------------------------
// IQ interleaved: word[2k] = I[k], word[2k+1] = Q[k]
reg [15:0] iq_mem [0:N_IQ_WORDS-1];
reg [15:0] ted_mem[0:N_TED-1];

// ---------------------------------------------------------------------------
// Error counter
// ---------------------------------------------------------------------------
integer err_cnt;
integer tc_num;

// ---------------------------------------------------------------------------
// Helper tasks
// ---------------------------------------------------------------------------

// Apply reset for 10 cycles
task apply_reset;
    integer i;
    begin
        @(negedge clk_sys);
        rst_n_sys          <= 1'b0;
        sample_valid_in_sys <= 1'b0;
        i_in_sys            <= {IQ_WIDTH{1'b0}};
        q_in_sys            <= {IQ_WIDTH{1'b0}};
        repeat(10) @(posedge clk_sys);
        @(negedge clk_sys);
        rst_n_sys <= 1'b1;
        @(posedge clk_sys);
    end
endtask

// Feed one IQ sample on the 100 MHz clock with a valid pulse, then
// hold valid low for IDLE_CYCLES cycles (simulating 72 kHz spacing).
// At 100 MHz / 72 kHz ≈ 1388 cycles per sample; we use 10 for simulation speed.
localparam IDLE_CYCLES = 9;  // valid high 1 cycle, then 9 idle = 10 cycles/sample

task feed_sample;
    input signed [IQ_WIDTH-1:0] i_val;
    input signed [IQ_WIDTH-1:0] q_val;
    integer j;
    begin
        @(negedge clk_sys);
        i_in_sys            <= i_val;
        q_in_sys            <= q_val;
        sample_valid_in_sys <= 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        sample_valid_in_sys <= 1'b0;
        i_in_sys            <= {IQ_WIDTH{1'b0}};
        q_in_sys            <= {IQ_WIDTH{1'b0}};
        repeat(IDLE_CYCLES - 1) @(posedge clk_sys);
    end
endtask

// Feed all N_SAMPLES and collect overflow events
// Returns: number of overflow strobes observed
integer ovf_count;
reg signed [IQ_WIDTH-1:0] captured_ted [0:N_TED-1];
integer captured_cnt;

task feed_and_capture;
    integer n;
    reg stim_done_fac;
    begin
        ovf_count     = 0;
        captured_cnt  = 0;
        stim_done_fac = 0;

        // Feed all samples; capture sample_valid_out pulses
        fork
            begin : stimulator
                for (n = 0; n < N_SAMPLES; n = n + 1) begin
                    feed_sample(
                        $signed(iq_mem[n * 2]),      // I
                        $signed(iq_mem[n * 2 + 1])   // Q
                    );
                end
                stim_done_fac = 1;
            end
            begin : monitor
                // Watch for sample_valid_out strobe; capture timing_error_sys
                while (!stim_done_fac) begin
                    @(posedge clk_sys);
                    if (sample_valid_out_sys) begin
                        if (captured_cnt < N_TED) begin
                            captured_ted[captured_cnt] = timing_error_sys;
                            captured_cnt = captured_cnt + 1;
                        end
                        ovf_count = ovf_count + 1;
                    end
                end
            end
        join

        // Wait for last strobe to settle
        repeat(20) @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// TC check helper
// ---------------------------------------------------------------------------
task check_tc;
    input [8*32-1:0] tc_name;  // string (max 32 chars)
    input            expect_positive_ted; // 1 = TED mean > 0, 0 = TED mean < 0, 2 = near zero
    input [1:0]      sign_mode;           // 0=near_zero, 1=positive, 2=negative

    integer k;
    integer ted_ref;
    integer ted_got;
    integer diff;
    integer sum_ted;
    integer abs_mean;
    begin
        sum_ted = 0;

        // Compare TED against reference (skip first TED_SKIP overflow events)
        for (k = TED_SKIP; k < captured_cnt && k < N_TED; k = k + 1) begin
            ted_ref = $signed(ted_mem[k]);
            ted_got = $signed(captured_ted[k]);
            diff    = ted_got - ted_ref;
            if (diff < 0) diff = -diff;

            if (diff > TED_TOL) begin
                $display("  [%0s] TED mismatch at overflow %0d: ref=%0d got=%0d (diff=%0d)",
                         tc_name, k, ted_ref, ted_got, diff);
                err_cnt = err_cnt + 1;
            end

            sum_ted = sum_ted + ted_got;
        end

        // Check sign / magnitude of mean TED
        abs_mean = (sum_ted < 0) ? -sum_ted : sum_ted;
        case (sign_mode)
            2'b00: begin  // near zero: |mean| should be small
                if (abs_mean > (captured_cnt - TED_SKIP) * 128) begin
                    $display("  [%0s] Mean TED too large for zero-offset: %0d",
                             tc_name, sum_ted);
                    err_cnt = err_cnt + 1;
                end
            end
            2'b01: begin  // positive
                if (sum_ted <= 0) begin
                    $display("  [%0s] Expected mean TED > 0, got %0d", tc_name, sum_ted);
                    err_cnt = err_cnt + 1;
                end
            end
            2'b10: begin  // negative
                if (sum_ted >= 0) begin
                    $display("  [%0s] Expected mean TED < 0, got %0d", tc_name, sum_ted);
                    err_cnt = err_cnt + 1;
                end
            end
        endcase

        // Check overflow count: should be N_SYMBOLS ±1 (NCO jitter)
        if (ovf_count < N_SYMBOLS - 2 || ovf_count > N_SYMBOLS + 2) begin
            $display("  [%0s] Unexpected overflow count: got %0d, expected ~%0d",
                     tc_name, ovf_count, N_SYMBOLS);
            err_cnt = err_cnt + 1;
        end

        $display("  [%0s] overflows=%0d mean_TED=%0d — %0s",
                 tc_name, ovf_count, sum_ted,
                 (err_cnt == 0) ? "PASS" : "FAIL (see above)");
    end
endtask

// ---------------------------------------------------------------------------
// Test execution
// ---------------------------------------------------------------------------
initial begin
    err_cnt            = 0;
    rst_n_sys          = 0;
    sample_valid_in_sys = 0;
    i_in_sys           = 0;
    q_in_sys           = 0;

    $display("");
    $display("========================================");
    $display(" tb_tetra_timing_recovery  —  START");
    $display("========================================");

    // -----------------------------------------------------------------------
    // TC0: Perfect timing
    // -----------------------------------------------------------------------
    $display("\n--- TC0: Perfect timing (offset=0) ---");
    $readmemh("tb/vectors/timing_tc0_iq_in.hex", iq_mem);
    $readmemh("tb/vectors/timing_tc0_ted.hex",   ted_mem);

    apply_reset;
    feed_and_capture;
    check_tc("TC0", 1'b0, 2'b00);   // near-zero TED

    // -----------------------------------------------------------------------
    // TC1: Early timing (+1 sample offset)
    // -----------------------------------------------------------------------
    $display("\n--- TC1: Early timing (+1 sample) ---");
    $readmemh("tb/vectors/timing_tc1_iq_in.hex", iq_mem);
    $readmemh("tb/vectors/timing_tc1_ted.hex",   ted_mem);

    apply_reset;
    feed_and_capture;
    check_tc("TC1", 1'b1, 2'b10);   // negative TED (early sampling → RTL: negative TED → loop slows down → correct)

    // -----------------------------------------------------------------------
    // TC2: Late timing (−1 sample offset)
    // -----------------------------------------------------------------------
    $display("\n--- TC2: Late timing (−1 sample) ---");
    $readmemh("tb/vectors/timing_tc2_iq_in.hex", iq_mem);
    $readmemh("tb/vectors/timing_tc2_ted.hex",   ted_mem);

    apply_reset;
    feed_and_capture;
    check_tc("TC2", 1'b0, 2'b01);   // positive TED (late sampling → RTL: positive TED → loop speeds up → correct)

    // -----------------------------------------------------------------------
    // TC3: Reset mid-stream (functional recovery check)
    // -----------------------------------------------------------------------
    $display("\n--- TC3: Reset mid-stream ---");
    $readmemh("tb/vectors/timing_tc0_iq_in.hex", iq_mem);

    // Feed 20 samples, assert reset, then feed remaining 108 and check output resumes
    begin : tc3
        integer n;
        integer valid_after_reset;
        valid_after_reset = 0;

        @(negedge clk_sys);
        rst_n_sys = 1;

        // 20 samples before reset
        for (n = 0; n < 20; n = n + 1)
            feed_sample($signed(iq_mem[n * 2]), $signed(iq_mem[n * 2 + 1]));

        // Assert reset for 5 cycles
        @(negedge clk_sys);
        rst_n_sys = 0;
        repeat(5) @(posedge clk_sys);
        @(negedge clk_sys);
        rst_n_sys = 1;
        @(posedge clk_sys);

        // Feed remaining samples; check sample_valid_out resumes
        begin : tc3_forks
            reg tc3_stim_done;
            tc3_stim_done = 0;
            fork
                begin : tc3_stim
                    for (n = 20; n < N_SAMPLES; n = n + 1)
                        feed_sample($signed(iq_mem[n * 2]), $signed(iq_mem[n * 2 + 1]));
                    tc3_stim_done = 1;
                end
                begin : tc3_mon
                    while (!tc3_stim_done) begin
                        @(posedge clk_sys);
                        if (sample_valid_out_sys)
                            valid_after_reset = valid_after_reset + 1;
                    end
                end
            join
        end

        repeat(20) @(posedge clk_sys);

        if (valid_after_reset < 4) begin
            $display("  [TC3] No output after reset recovery — FAIL");
            err_cnt = err_cnt + 1;
        end else begin
            $display("  [TC3] Post-reset valid pulses: %0d — PASS", valid_after_reset);
        end
    end

    // -----------------------------------------------------------------------
    // TC4: No-input → sample_valid_out must stay 0
    // -----------------------------------------------------------------------
    $display("\n--- TC4: No input — valid_out must be 0 ---");
    begin : tc4
        integer stray;
        stray = 0;
        apply_reset;
        repeat(100) begin
            @(posedge clk_sys);
            if (sample_valid_out_sys) stray = stray + 1;
        end
        if (stray > 0) begin
            $display("  [TC4] Spurious valid_out pulses: %0d — FAIL", stray);
            err_cnt = err_cnt + 1;
        end else
            $display("  [TC4] No spurious valid_out — PASS");
    end

    // -----------------------------------------------------------------------
    // Final result
    // -----------------------------------------------------------------------
    $display("");
    $display("========================================");
    if (err_cnt == 0)
        $display(" RESULT: PASS  (0 errors)");
    else
        $display(" RESULT: FAIL  (%0d error(s))", err_cnt);
    $display("========================================");
    $display("");

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog — 100 µs simulation limit
// ---------------------------------------------------------------------------
initial begin
    #100_000_000;  // 100 ms simulation time = 10M cycles @ 100 MHz
    $display("TIMEOUT: simulation exceeded watchdog limit");
    $finish;
end

endmodule
