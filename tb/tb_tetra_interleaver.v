// =============================================================================
// tb_tetra_interleaver.v — Self-Checking Testbench for tetra_interleaver
// =============================================================================
//
// Test cases:
//   TC1: NDB interleave (K=216) — output matches reference step permutation
//   TC2: NDB deinterleave (K=216) — inverse step permutation
//   TC3: Roundtrip NDB — interleave then deinterleave recovers original data
//   TC4: SCH/F interleave (K=432) — larger block size
//   TC5: SCH/F roundtrip
//   TC6: All-zeros / all-ones — uniform data permutes to itself
//   TC7: Backpressure — data_in_valid gaps during fill, output correct
//   TC8: Consecutive blocks — back-to-back NDB blocks processed correctly
//
// Timing convention:
//   fill_and_collect sends K bits (one per clock, data_in_valid=1) and
//   captures ALL drain outputs into a flat register.  Comparison is done
//   after collection, not cycle-by-cycle.
//
// Bit ordering convention (throughout testbench):
//   flat_reg[K-1] = first bit  (sent/received first, t=0)
//   flat_reg[0]   = last bit   (sent/received last,  t=K-1)
//   This matches the send loop: data_in = flat[K-1-i] at cycle i.
//
// Reference model (step_permute):
//   out[K-1-j] = in[(j*STEP mod K)] for j=0..K-1
//   (stores with same MSB-first convention)
//
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_interleaver;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD     = 10;
localparam MAX_BLOCK_SIZE = 432;
localparam [8:0] STEP_TX      = 9'd11;
localparam [8:0] STEP_RX_NDB  = 9'd59;
localparam [8:0] STEP_RX_SCHF = 9'd275;
localparam [8:0] K_NDB  = 9'd216;
localparam [8:0] K_SCHF = 9'd432;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg          clk_sys;
reg          rst_n_sys;
reg          mode;
reg  [8:0]   block_size;
reg          data_in;
reg          data_in_valid;
wire         data_out;
wire         data_out_valid;
wire         block_done;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
tetra_interleaver #(
    .MAX_BLOCK_SIZE (MAX_BLOCK_SIZE)
) dut (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .mode           (mode),
    .block_size     (block_size),
    .data_in        (data_in),
    .data_in_valid  (data_in_valid),
    .data_out       (data_out),
    .data_out_valid (data_out_valid),
    .block_done     (block_done)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_interleaver.vcd");
    $dumpvars(0, tb_tetra_interleaver);
end

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// Error counter
// ---------------------------------------------------------------------------
integer err_count;
initial err_count = 0;

// ---------------------------------------------------------------------------
// Reference model: step permutation (Verilog function)
//
// Computes out[K-1-j] = in[j*step mod K] for j=0..K-1.
// Both in and out use MSB-first convention: index K-1 = first bit.
//
// This mirrors the DUT DRAIN phase:
//   rd_addr starts at 0, steps by `step`, output j reads buf[j*step mod K].
//   buf[k] = k-th fill bit = in[K-1-k] (MSB first).
//   So: drain output j = buf[j*step mod K] = in[K-1 - (j*step mod K)].
//   Stored as out[K-1-j] to maintain MSB-first ordering.
// ---------------------------------------------------------------------------
task step_permute;
    input  [MAX_BLOCK_SIZE-1:0] in_data;
    input  [8:0]                K;
    input  [8:0]                step;
    output [MAX_BLOCK_SIZE-1:0] out_data;
    integer j;
    reg [9:0] addr10;
    reg [8:0] addr;
    begin
        out_data = {MAX_BLOCK_SIZE{1'b0}};
        addr = 9'd0;
        for (j = 0; j < MAX_BLOCK_SIZE; j = j + 1) begin
            if (j < K) begin
                // buf[addr] = in[K-1-addr] (MSB-first: index K-1 = first bit)
                out_data[K-1-j] = in_data[K-1-addr];
                // Next address: (addr + step) mod K
                addr10 = {1'b0, addr} + {1'b0, step};
                addr   = (addr10 >= {1'b0, K}) ? addr10[8:0] - K : addr10[8:0];
            end
        end
    end
endtask

// Compute expected interleaved output
task ref_interleave;
    input  [MAX_BLOCK_SIZE-1:0] in_data;
    input  [8:0]                K;
    output [MAX_BLOCK_SIZE-1:0] out_data;
    begin
        step_permute(in_data, K, STEP_TX, out_data);
    end
endtask

// Compute expected deinterleaved output
task ref_deinterleave;
    input  [MAX_BLOCK_SIZE-1:0] in_data;
    input  [8:0]                K;
    output [MAX_BLOCK_SIZE-1:0] out_data;
    reg [8:0] step_rx;
    begin
        step_rx = (K == K_SCHF) ? STEP_RX_SCHF : STEP_RX_NDB;
        step_permute(in_data, K, step_rx, out_data);
    end
endtask

// ---------------------------------------------------------------------------
// Task: apply reset
// ---------------------------------------------------------------------------
task do_reset;
    begin
        rst_n_sys     = 1'b0;
        mode          = 1'b0;
        block_size    = K_NDB;
        data_in       = 1'b0;
        data_in_valid = 1'b0;
        repeat (4) @(posedge clk_sys);
        rst_n_sys = 1'b1;
        @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Task: fill_and_collect
//
// Sends K bits from 'pattern' (MSB first), then collects K drain outputs
// into 'captured_out' (MSB first).
//
// Timing:
//   - Fill:  sends bit i at the posedge FOLLOWING the @posedge+#1 in cycle i.
//            Bit i is captured by DUT at the NEXT posedge (N+i+1).
//   - Last fill bit captured at posedge N+K+1.  State→S_DRAIN at N+K+1.
//   - First drain output registered at posedge N+K+2:
//       data_out = buf[0], data_out_valid = 1.
//   - Drain outputs: posedges N+K+2 through N+K+1+K.
//   - block_done = 1 at posedge N+K+1+K (last drain posedge).
//   - data_out_valid = 0 from posedge N+K+2+K onward.
//
// The task advances clock after setting up, then polls data_out_valid on
// each posedge to collect exactly K drain bits.
// ---------------------------------------------------------------------------
task fill_and_collect;
    input        mode_in;
    input [8:0]  K_in;
    input [MAX_BLOCK_SIZE-1:0] pattern;
    output [MAX_BLOCK_SIZE-1:0] captured_out;
    integer i;
    integer out_cnt;
    integer watchdog;
    begin
        mode       = mode_in;
        block_size = K_in;

        // --- FILL ---
        for (i = 0; i < K_in; i = i + 1) begin
            @(posedge clk_sys); #1;
            data_in       = pattern[K_in - 1 - i];   // MSB first
            data_in_valid = 1'b1;
        end
        // Advance past last fill posedge (state→S_DRAIN happens here)
        @(posedge clk_sys); #1;
        data_in_valid = 1'b0;

        // --- COLLECT DRAIN outputs ---
        // First drain output is registered at the NEXT posedge (already happened above
        // for the fill→drain transition). We need one more posedge to see it.
        @(posedge clk_sys); #1;   // first drain output now available

        out_cnt  = 0;
        watchdog = K_in + 5;
        captured_out = {MAX_BLOCK_SIZE{1'b0}};

        // Collect bits while data_out_valid is high (exactly K cycles)
        while (out_cnt < K_in && watchdog > 0) begin
            if (data_out_valid) begin
                // MSB-first: first collected = index K-1
                captured_out[K_in - 1 - out_cnt] = data_out;
                out_cnt = out_cnt + 1;
            end
            if (out_cnt < K_in) begin
                @(posedge clk_sys); #1;
            end
            watchdog = watchdog - 1;
        end

        if (out_cnt !== K_in) begin
            $error("fill_and_collect: timeout, only %0d/%0d bits collected", out_cnt, K_in);
            err_count = err_count + 1;
        end

        // block_done fires at the last drain posedge (registered drain_done_sys).
        // The loop exits WITHOUT advancing the clock after the last bit, so
        // block_done=1 is already visible here at last_drain_posedge+#1.
        if (!block_done) begin
            $error("fill_and_collect: block_done not asserted at last drain edge");
            err_count = err_count + 1;
        end

        // Advance one clock: block_done clears, data_out_valid goes LOW
        @(posedge clk_sys); #1;

        // data_out_valid should be LOW now (state back to S_FILL)
        if (data_out_valid !== 1'b0) begin
            $error("fill_and_collect: data_out_valid still HIGH after drain");
            err_count = err_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Task: compare two flat registers bit-by-bit within [0..K-1]
// ---------------------------------------------------------------------------
task compare_blocks;
    input [MAX_BLOCK_SIZE-1:0] got;
    input [MAX_BLOCK_SIZE-1:0] exp;
    input [8:0]                K;
    input [63:0]               tc_label;
    integer i;
    begin
        for (i = 0; i < K; i = i + 1) begin
            if (got[K-1-i] !== exp[K-1-i]) begin
                $error("[%s] bit %0d: got=%b, expected=%b",
                       tc_label, i, got[K-1-i], exp[K-1-i]);
                err_count = err_count + 1;
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// Main test body
// ---------------------------------------------------------------------------
initial begin
    do_reset;

    // -----------------------------------------------------------------------
    // TC1: NDB interleave (K=216)
    // -----------------------------------------------------------------------
    $display("TC1: NDB interleave K=216");
    begin : tc1
        reg [MAX_BLOCK_SIZE-1:0] data216;
        reg [MAX_BLOCK_SIZE-1:0] got;
        reg [MAX_BLOCK_SIZE-1:0] exp;
        integer i;
        data216 = {MAX_BLOCK_SIZE{1'b0}};
        for (i = 0; i < 216; i = i + 1)
            data216[K_NDB - 1 - i] = i % 2;   // alternating, MSB-first
        fill_and_collect(1'b0, K_NDB, data216, got);
        ref_interleave(data216, K_NDB, exp);
        compare_blocks(got, exp, K_NDB, "TC1_NDB_");
        $display("TC1: PASS");
    end

    // -----------------------------------------------------------------------
    // TC2: NDB deinterleave (K=216)
    // -----------------------------------------------------------------------
    $display("TC2: NDB deinterleave K=216");
    begin : tc2
        reg [MAX_BLOCK_SIZE-1:0] data216;
        reg [MAX_BLOCK_SIZE-1:0] got;
        reg [MAX_BLOCK_SIZE-1:0] exp;
        integer i;
        data216 = {MAX_BLOCK_SIZE{1'b0}};
        for (i = 0; i < 216; i = i + 1)
            data216[K_NDB - 1 - i] = (i * 3 + 1) % 2;
        fill_and_collect(1'b1, K_NDB, data216, got);
        ref_deinterleave(data216, K_NDB, exp);
        compare_blocks(got, exp, K_NDB, "TC2_NDB_");
        $display("TC2: PASS");
    end

    // -----------------------------------------------------------------------
    // TC3: Roundtrip NDB — interleave then deinterleave recovers original
    // -----------------------------------------------------------------------
    $display("TC3: Roundtrip NDB K=216");
    begin : tc3
        reg [MAX_BLOCK_SIZE-1:0] original;
        reg [MAX_BLOCK_SIZE-1:0] interleaved;
        reg [MAX_BLOCK_SIZE-1:0] recovered;
        integer i;
        original = {MAX_BLOCK_SIZE{1'b0}};
        for (i = 0; i < 216; i = i + 1)
            original[K_NDB - 1 - i] = (i * 7 + 3) % 2;
        // Interleave
        fill_and_collect(1'b0, K_NDB, original, interleaved);
        // Deinterleave
        fill_and_collect(1'b1, K_NDB, interleaved, recovered);
        // Compare recovered to original
        compare_blocks(recovered, original, K_NDB, "TC3_RT__");
        $display("TC3: PASS");
    end

    // -----------------------------------------------------------------------
    // TC4: SCH/F interleave (K=432)
    // -----------------------------------------------------------------------
    $display("TC4: SCH/F interleave K=432");
    begin : tc4
        reg [MAX_BLOCK_SIZE-1:0] data432;
        reg [MAX_BLOCK_SIZE-1:0] got;
        reg [MAX_BLOCK_SIZE-1:0] exp;
        integer i;
        for (i = 0; i < 432; i = i + 1)
            data432[K_SCHF - 1 - i] = (i * 7 ^ (i >> 3)) % 2;
        fill_and_collect(1'b0, K_SCHF, data432, got);
        ref_interleave(data432, K_SCHF, exp);
        compare_blocks(got, exp, K_SCHF, "TC4_SCHF");
        $display("TC4: PASS");
    end

    // -----------------------------------------------------------------------
    // TC5: SCH/F roundtrip (K=432)
    // -----------------------------------------------------------------------
    $display("TC5: SCH/F roundtrip K=432");
    begin : tc5
        reg [MAX_BLOCK_SIZE-1:0] original;
        reg [MAX_BLOCK_SIZE-1:0] interleaved;
        reg [MAX_BLOCK_SIZE-1:0] recovered;
        integer i;
        for (i = 0; i < 432; i = i + 1)
            original[K_SCHF - 1 - i] = (i * 13 + 1) % 2;
        fill_and_collect(1'b0, K_SCHF, original, interleaved);
        fill_and_collect(1'b1, K_SCHF, interleaved, recovered);
        compare_blocks(recovered, original, K_SCHF, "TC5_RT__");
        $display("TC5: PASS");
    end

    // -----------------------------------------------------------------------
    // TC6: All-zeros and all-ones — permutation of uniform data = same data
    // -----------------------------------------------------------------------
    $display("TC6: All-zeros/ones K=216");
    begin : tc6
        reg [MAX_BLOCK_SIZE-1:0] zeros;
        reg [MAX_BLOCK_SIZE-1:0] ones;
        reg [MAX_BLOCK_SIZE-1:0] got;
        integer i;
        zeros = {MAX_BLOCK_SIZE{1'b0}};
        ones  = {MAX_BLOCK_SIZE{1'b1}};
        fill_and_collect(1'b0, K_NDB, zeros, got);
        for (i = 0; i < K_NDB; i = i + 1) begin
            if (got[K_NDB-1-i] !== 1'b0) begin
                $error("TC6: all-zeros bit %0d ≠ 0", i);
                err_count = err_count + 1;
            end
        end
        fill_and_collect(1'b0, K_NDB, ones, got);
        for (i = 0; i < K_NDB; i = i + 1) begin
            if (got[K_NDB-1-i] !== 1'b1) begin
                $error("TC6: all-ones bit %0d ≠ 1", i);
                err_count = err_count + 1;
            end
        end
        $display("TC6: PASS");
    end

    // -----------------------------------------------------------------------
    // TC7: Backpressure — data_in_valid gaps during fill
    // Result must be identical to gap-free fill with same data.
    // -----------------------------------------------------------------------
    $display("TC7: Backpressure during fill K=216");
    begin : tc7
        reg [MAX_BLOCK_SIZE-1:0] data216;
        reg [MAX_BLOCK_SIZE-1:0] got_clean;    // reference: no gaps
        reg [MAX_BLOCK_SIZE-1:0] got_bp;       // with backpressure
        reg [MAX_BLOCK_SIZE-1:0] exp;
        integer i;
        integer out_cnt;
        integer watchdog;

        data216 = {MAX_BLOCK_SIZE{1'b0}};
        for (i = 0; i < 216; i = i + 1)
            data216[K_NDB-1-i] = (i + 1) % 2;

        // Clean reference fill
        fill_and_collect(1'b0, K_NDB, data216, got_clean);

        // Fill with gaps every 8 bits
        mode       = 1'b0;
        block_size = K_NDB;
        for (i = 0; i < 216; i = i + 1) begin
            if (i > 0 && (i % 8 == 0)) begin
                // Insert 3-cycle gap
                @(posedge clk_sys); #1;
                data_in_valid = 1'b0;
                repeat (2) @(posedge clk_sys);
                #1;
            end
            @(posedge clk_sys); #1;
            data_in       = data216[K_NDB-1-i];
            data_in_valid = 1'b1;
        end
        @(posedge clk_sys); #1;
        data_in_valid = 1'b0;
        @(posedge clk_sys); #1;   // transition to drain

        // Collect drain output
        out_cnt = 0;
        watchdog = K_NDB + 5;
        got_bp = {MAX_BLOCK_SIZE{1'b0}};
        while (out_cnt < K_NDB && watchdog > 0) begin
            if (data_out_valid) begin
                got_bp[K_NDB-1-out_cnt] = data_out;
                out_cnt = out_cnt + 1;
            end
            if (out_cnt < K_NDB) begin
                @(posedge clk_sys); #1;
            end
            watchdog = watchdog - 1;
        end
        if (out_cnt !== K_NDB) begin
            $error("TC7: timeout collecting drain outputs");
            err_count = err_count + 1;
        end
        // Wait for block_done
        @(posedge clk_sys); #1;

        // Compare: gap fill should give same result as clean fill
        compare_blocks(got_bp, got_clean, K_NDB, "TC7_BP__");
        $display("TC7: PASS");
    end

    // -----------------------------------------------------------------------
    // TC8: Consecutive blocks — two back-to-back NDB blocks
    // -----------------------------------------------------------------------
    $display("TC8: Consecutive NDB blocks");
    begin : tc8
        reg [MAX_BLOCK_SIZE-1:0] blk1, blk2, got1, got2, exp1, exp2;
        integer i;
        blk1 = {MAX_BLOCK_SIZE{1'b0}};
        blk2 = {MAX_BLOCK_SIZE{1'b0}};
        for (i = 0; i < 216; i = i + 1) begin
            blk1[K_NDB-1-i] = i % 2;
            blk2[K_NDB-1-i] = (i + 1) % 2;
        end
        fill_and_collect(1'b0, K_NDB, blk1, got1);
        fill_and_collect(1'b0, K_NDB, blk2, got2);
        ref_interleave(blk1, K_NDB, exp1);
        ref_interleave(blk2, K_NDB, exp2);
        compare_blocks(got1, exp1, K_NDB, "TC8_BLK1");
        compare_blocks(got2, exp2, K_NDB, "TC8_BLK2");
        $display("TC8: PASS");
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
    #50_000_000;
    $fatal(1, "TIMEOUT — simulation exceeded 50 ms simulated time");
end

endmodule

`default_nettype wire
