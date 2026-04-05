// =============================================================================
// tb_tetra_scrambler.v — Self-Checking Testbench for tetra_scrambler
// =============================================================================
//
// Test cases:
//   TC1: Basic scramble — known init, check output bit-by-bit vs reference LFSR
//   TC2: Symmetry — scramble then descramble recovers original data
//   TC3: load_init — new init value resets sequence mid-stream
//   TC4: Backpressure — data_valid deasserted mid-block, sequence must resume
//   TC5: All-zeros data — output equals pure LFSR sequence
//   TC6: Consecutive load_init — no spurious output on load cycle
//   TC7: Block-length — 216 bits (NDB) and 432 bits (SCH/F) pass cleanly
//
// Reference model:
//   Galois LFSR implemented directly in Verilog (same polynomial as DUT).
//   DUT and reference run in lockstep; outputs compared each valid cycle.
//
// Polynomial (ETSI EN 300 392-2 §8.2.5):
//   p(x) = x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11
//         + x^10 + x^8  + x^7  + x^5  + x^4  + x^2  + x + 1
//   Galois mask: 32'h04C11DB7
//
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_scrambler;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD  = 10;             // 10 ns → 100 MHz
localparam LFSR_WIDTH  = 32;
localparam [31:0] POLY_MASK = 32'h04C11DB7;

// Typical TETRA test init:  CC=0x01, MCC=0x001, MNC=0x0001, TN=0
// lfsr_init = TN[1:0]<<30 | MNC[13:0]<<16 | MCC[9:0]<<6 | CC[5:0]
// lfsr_init = {TN[1:0], MNC[13:0], MCC[9:0], CC[5:0]}
// INIT_A: CC=0x01, MCC=0x001, MNC=0x0001, TN=0
//   = 0x01 | (1<<6) | (1<<16) | (0<<30) = 0x00010041
localparam [31:0] INIT_A = 32'h00010041;
// INIT_B: CC=0x15, MCC=0x123, MNC=0x0ABC, TN=0
//   = 0x15 | (0x123<<6) | (0x0ABC<<16) | (0<<30) = 0x0ABC48D5
localparam [31:0] INIT_B = 32'h0ABC48D5;
// INIT_C: CC=0x3F, MCC=0x3FF, MNC=0x3FFF, TN=3 → all bits = 1
//   = 0x3F | (0x3FF<<6) | (0x3FFF<<16) | (3<<30) = 0xFFFFFFFF
localparam [31:0] INIT_C = 32'hFFFFFFFF;

localparam NDB_BITS  = 216;
localparam SCHF_BITS = 432;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg          clk_sys;
reg          rst_n_sys;
reg  [31:0]  lfsr_init;
reg          load_init;
reg          data_in;
reg          data_valid;

wire         data_out;
wire         data_out_valid;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
tetra_scrambler #(
    .LFSR_WIDTH (LFSR_WIDTH)
) dut (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .lfsr_init      (lfsr_init),
    .load_init      (load_init),
    .data_in        (data_in),
    .data_valid     (data_valid),
    .data_out       (data_out),
    .data_out_valid (data_out_valid)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_scrambler.vcd");
    $dumpvars(0, tb_tetra_scrambler);
end

// ---------------------------------------------------------------------------
// Clock generation
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// Reference LFSR model (Galois, mirrors DUT)
// Driven as a register, updated manually in test tasks.
// ---------------------------------------------------------------------------
reg [31:0] ref_lfsr;

// One step of reference LFSR: returns (next_state, output_bit)
// Implemented via task that modifies ref_lfsr and stores out in ref_bit.
reg ref_bit;
task ref_lfsr_step;
    begin
        ref_bit = ref_lfsr[0];
        ref_lfsr = {1'b0, ref_lfsr[31:1]} ^ ({32{ref_lfsr[0]}} & POLY_MASK);
    end
endtask

// ---------------------------------------------------------------------------
// Error counter
// ---------------------------------------------------------------------------
integer err_count;
initial err_count = 0;

// ---------------------------------------------------------------------------
// Task: apply reset
// ---------------------------------------------------------------------------
task do_reset;
    begin
        rst_n_sys  = 1'b0;
        load_init  = 1'b0;
        data_valid = 1'b0;
        data_in    = 1'b0;
        lfsr_init  = 32'h0;
        repeat (4) @(posedge clk_sys);
        rst_n_sys = 1'b1;
        @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Task: load LFSR init value (one cycle)
// Simultaneously primes the reference model.
// ---------------------------------------------------------------------------
task do_load_init;
    input [31:0] init;
    begin
        @(posedge clk_sys); #1;
        lfsr_init = init;
        load_init = 1'b1;
        data_valid = 1'b0;
        @(posedge clk_sys); #1;
        load_init = 1'b0;
        // Prime reference model: ref_lfsr will be used starting NEXT step
        ref_lfsr = init;
    end
endtask

// ---------------------------------------------------------------------------
// Task: send one bit, check output against reference
// ref_lfsr must already be loaded with correct state.
// ---------------------------------------------------------------------------
task send_bit_check;
    input         din;
    input [63:0]  tc_label;
    input integer bit_idx;
    begin
        // Compute expected output BEFORE the DUT processes this bit
        ref_lfsr_step;   // advances ref_lfsr, stores output in ref_bit
        // Apply to DUT
        @(posedge clk_sys); #1;
        data_in    = din;
        data_valid = 1'b1;
        @(posedge clk_sys); #1;
        data_valid = 1'b0;
        // data_out / data_out_valid should now be valid
        if (!data_out_valid) begin
            $error("[%s] bit %0d: data_out_valid LOW (expected HIGH)",
                   tc_label, bit_idx);
            err_count = err_count + 1;
        end
        if (data_out !== (din ^ ref_bit)) begin
            $error("[%s] bit %0d: data_out=%b, expected=%b (data_in=%b, lfsr_q=%b)",
                   tc_label, bit_idx, data_out, din ^ ref_bit, din, ref_bit);
            err_count = err_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Task: send N bits from a flat reg, check all against reference
// ---------------------------------------------------------------------------
task send_bits_check;
    input [511:0] data_flat;   // up to 512 bits; bit [N-1] is first sent
    input integer n_bits;
    input [63:0]  tc_label;
    integer i;
    reg     bit_i;
    begin
        for (i = 0; i < n_bits; i = i + 1) begin
            bit_i = data_flat[n_bits - 1 - i];   // MSB first
            send_bit_check(bit_i, tc_label, i);
        end
    end
endtask

// ---------------------------------------------------------------------------
// Main test body
// ---------------------------------------------------------------------------
initial begin
    do_reset;

    // -----------------------------------------------------------------------
    // TC1: Basic scramble — 32 bits against reference LFSR
    // -----------------------------------------------------------------------
    $display("TC1: basic scramble, 32 bits, INIT_A");
    begin : tc1
        integer i;
        reg [31:0] test_data;
        test_data = 32'hA5C3_96F1;
        do_load_init(INIT_A);
        for (i = 0; i < 32; i = i + 1)
            send_bit_check(test_data[31 - i], "TC1_____", i);
        $display("TC1: PASS");
    end

    // -----------------------------------------------------------------------
    // TC2: Symmetry — scramble produces X, descramble of X produces original
    // A single load_init followed by 2× the same bit stream:
    //   first pass: scramble (data → X)
    //   second pass: descramble (X → data) — same LFSR sequence
    // -----------------------------------------------------------------------
    $display("TC2: symmetry (scramble then descramble), 64 bits");
    begin : tc2
        integer i;
        reg [63:0] original;
        reg [63:0] scrambled_bits;
        reg        expected_bit;
        original = 64'hDEAD_BEEF_1234_5678;

        // --- First pass: scramble ---
        do_load_init(INIT_B);
        scrambled_bits = 64'h0;
        for (i = 0; i < 64; i = i + 1) begin
            // capture DUT output
            @(posedge clk_sys); #1;
            data_in    = original[63 - i];
            data_valid = 1'b1;
            @(posedge clk_sys); #1;
            data_valid = 1'b0;
            scrambled_bits[63 - i] = data_out;  // collect scrambled stream
        end

        // --- Second pass: descramble (reload same init) ---
        do_load_init(INIT_B);
        for (i = 0; i < 64; i = i + 1) begin
            ref_lfsr_step;
            @(posedge clk_sys); #1;
            data_in    = scrambled_bits[63 - i];
            data_valid = 1'b1;
            @(posedge clk_sys); #1;
            data_valid = 1'b0;
            expected_bit = original[63 - i];
            if (data_out !== expected_bit) begin
                $error("TC2: bit %0d: descramble got %b, expected %b",
                       i, data_out, expected_bit);
                err_count = err_count + 1;
            end
        end
        $display("TC2: PASS");
    end

    // -----------------------------------------------------------------------
    // TC3: load_init — new init resets sequence mid-stream; no output on
    //      the load cycle (data_out_valid must be LOW during load_init=1)
    // -----------------------------------------------------------------------
    $display("TC3: load_init suppresses output, sequence restarts");
    begin : tc3
        integer i;
        // Send 8 bits with INIT_A
        do_load_init(INIT_A);
        for (i = 0; i < 8; i = i + 1)
            send_bit_check(i[0], "TC3_prea", i);

        // Apply load_init — check data_out_valid goes LOW on that cycle
        @(posedge clk_sys); #1;
        lfsr_init  = INIT_C;
        load_init  = 1'b1;
        data_valid = 1'b1;   // attempt data_valid simultaneously — must be suppressed
        data_in    = 1'b1;
        @(posedge clk_sys); #1;
        if (data_out_valid !== 1'b0) begin
            $error("TC3: data_out_valid should be LOW during load_init cycle");
            err_count = err_count + 1;
        end
        load_init  = 1'b0;
        data_valid = 1'b0;
        ref_lfsr   = INIT_C;  // resync reference

        // Send 8 more bits with INIT_C — should follow new sequence
        for (i = 0; i < 8; i = i + 1)
            send_bit_check(1'b0, "TC3_post", i);
        $display("TC3: PASS");
    end

    // -----------------------------------------------------------------------
    // TC4: Backpressure — data_valid deasserted for several cycles mid-block
    //      LFSR must NOT advance during invalid cycles.
    //      Sequence resumes at exact point where it paused.
    // -----------------------------------------------------------------------
    $display("TC4: backpressure (data_valid gaps), 20 bits");
    begin : tc4
        integer i;
        reg din;
        do_load_init(INIT_A);
        for (i = 0; i < 20; i = i + 1) begin
            din = ^i[3:0];  // some test pattern
            // Insert gap every 5 bits
            if ((i % 5) == 4) begin
                @(posedge clk_sys); #1;
                data_valid = 1'b0;
                repeat (3) @(posedge clk_sys);
                #1;
            end
            send_bit_check(din, "TC4_____", i);
        end
        $display("TC4: PASS");
    end

    // -----------------------------------------------------------------------
    // TC5: All-zeros data — output = pure LFSR sequence
    // Verify first 32 bits of scrambling sequence for INIT_A
    // -----------------------------------------------------------------------
    $display("TC5: all-zeros data = pure LFSR sequence");
    begin : tc5
        integer i;
        do_load_init(INIT_A);
        for (i = 0; i < 32; i = i + 1)
            send_bit_check(1'b0, "TC5_____", i);
        // DUT output matches ref_bit (LFSR sequence) — verified inside send_bit_check
        $display("TC5: PASS");
    end

    // -----------------------------------------------------------------------
    // TC6: Consecutive load_init pulses — no data corruption
    // -----------------------------------------------------------------------
    $display("TC6: consecutive load_init pulses");
    begin : tc6
        integer i;
        // Load INIT_A
        do_load_init(INIT_A);
        // Immediately load INIT_B (no data between)
        do_load_init(INIT_B);
        // Immediately load INIT_C
        do_load_init(INIT_C);
        // Now send 8 bits — should follow INIT_C
        for (i = 0; i < 8; i = i + 1)
            send_bit_check(1'b1, "TC6_____", i);
        $display("TC6: PASS");
    end

    // -----------------------------------------------------------------------
    // TC7: Full NDB block (216 bits) and SCH/F block (432 bits)
    // Uses a counter-driven data pattern; checks every output bit.
    // -----------------------------------------------------------------------
    $display("TC7: NDB block (216 bits)");
    begin : tc7_ndb
        integer i;
        do_load_init(INIT_A);
        for (i = 0; i < NDB_BITS; i = i + 1)
            send_bit_check((i * 3 + 7) % 2, "TC7_NDB_", i);
        $display("TC7-NDB: PASS");
    end

    $display("TC7: SCH/F block (432 bits)");
    begin : tc7_schf
        integer i;
        do_load_init(INIT_B);
        for (i = 0; i < SCHF_BITS; i = i + 1)
            send_bit_check((i ^ (i >> 2)) % 2, "TC7_SCHF", i);
        $display("TC7-SCHF: PASS");
    end

    // -----------------------------------------------------------------------
    // Final report
    // -----------------------------------------------------------------------
    #100;
    if (err_count == 0) begin
        $display("===========================================");
        $display("TESTBENCH PASSED — 0 errors");
        $display("===========================================");
    end else begin
        $display("===========================================");
        $display("TESTBENCH FAILED — %0d error(s)", err_count);
        $display("===========================================");
        $fatal(1, "Simulation terminated with errors.");
    end

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #10_000_000;
    $fatal(1, "TIMEOUT — simulation exceeded 10 ms simulated time");
end

endmodule

`default_nettype wire
