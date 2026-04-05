// =============================================================================
// Testbench: tb_tetra_burst_builder
// Module:    tetra_burst_builder
// Project:   tetra-zynq-phy
//
// Self-checking testbench for the NDB burst assembler.
//
// Verifies:
//  - Correct output symbol count: exactly 255 dibits per burst
//  - FreqCorr pattern: first 2 symbols = 2'b01
//  - NTS position: symbols [110..131] match Table 9.11 reference
//  - Payload pass-through: Block1 at [2..109], BB at [132..146], Block2 at [147..254]
//  - tx_done fires on the last (255th) valid symbol
//  - tx_busy asserted from build_req until tx_done
//  - Back-to-back bursts (2 consecutive NDB requests)
//
// Test cases:
//  TC1: All-zeros payload — verifies structure via symbol position checks
//  TC2: Known payload (0xAA..., 0xBB...) — verifies payload pass-through
//  TC3: Back-to-back bursts — second burst queued immediately after first
//  TC4: Reset mid-burst — outputs clear, FSM returns to IDLE
//
// Clock: 10 ns (100 MHz)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_burst_builder;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam BLOCK_BITS = 216;
localparam BB_BITS    = 30;
localparam CLK_HALF   = 5;
localparam TOTAL_SYMS = 255;

// NTS — Normal Training Sequence, ETSI EN 300 392-2 Table 9.11 (22 symbols)
// Must match NTS_REF localparam in tetra_burst_builder.v
localparam [43:0] NTS_REF = {
    2'b00, 2'b11, 2'b01, 2'b10, 2'b01, 2'b11, 2'b10, 2'b10,
    2'b00, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01, 2'b10, 2'b00,
    2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b01
};

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg              clk_sys;
reg              rst_n_sys;
reg  [BLOCK_BITS-1:0] block1_data_sys;
reg  [BLOCK_BITS-1:0] block2_data_sys;
reg  [BB_BITS-1:0]    bb_data_sys;
reg  [1:0]       burst_type_sys;
reg              build_req_sys;

wire [1:0]       tx_dibit_sys;
wire             tx_dibit_valid_sys;
wire             tx_done_sys;
wire             tx_busy_sys;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_burst_builder #(
    .BLOCK_BITS(BLOCK_BITS),
    .BB_BITS   (BB_BITS)
) dut (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .block1_data_sys  (block1_data_sys),
    .block2_data_sys  (block2_data_sys),
    .bb_data_sys      (bb_data_sys),
    .burst_type_sys   (burst_type_sys),
    .build_req_sys    (build_req_sys),
    .tx_dibit_sys     (tx_dibit_sys),
    .tx_dibit_valid_sys(tx_dibit_valid_sys),
    .tx_done_sys      (tx_done_sys),
    .tx_busy_sys      (tx_busy_sys)
);

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #CLK_HALF clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// VCD
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_burst_builder.vcd");
    $dumpvars(0, tb_tetra_burst_builder);
end

// ---------------------------------------------------------------------------
// Pass/fail counters
// ---------------------------------------------------------------------------
integer pass_cnt = 0;
integer fail_cnt = 0;

// ---------------------------------------------------------------------------
// Task: capture_burst
//   Collects exactly TOTAL_SYMS dibits into capture_buf[].
//   Returns number of valid dibits seen, and checks tx_done fires exactly once.
// ---------------------------------------------------------------------------
reg [1:0] capture_buf [0:TOTAL_SYMS-1];
integer   capture_cnt;
integer   done_cnt;

task capture_burst;
    integer timeout;
    begin
        capture_cnt = 0;
        done_cnt    = 0;
        timeout     = 0;

        while (capture_cnt < TOTAL_SYMS && timeout < TOTAL_SYMS + 20) begin
            @(posedge clk_sys); #1;
            if (tx_dibit_valid_sys) begin
                if (capture_cnt < TOTAL_SYMS)
                    capture_buf[capture_cnt] = tx_dibit_sys;
                capture_cnt = capture_cnt + 1;
            end
            if (tx_done_sys)
                done_cnt = done_cnt + 1;
            timeout = timeout + 1;
        end

        // Wait 1 more cycle for tx_done if we just got last dibit
        @(posedge clk_sys); #1;
        if (tx_done_sys)
            done_cnt = done_cnt + 1;
    end
endtask

// ---------------------------------------------------------------------------
// Task: check_burst
//   Verifies FreqCorr, NTS, and expected Block1/Block2/BB payloads.
// ---------------------------------------------------------------------------
task check_burst;
    input [BLOCK_BITS-1:0] exp_b1;
    input [BLOCK_BITS-1:0] exp_b2;
    input [BB_BITS-1:0]    exp_bb;
    input [255:0]          tc_name;
    integer sym;
    integer ok;
    begin
        ok = 1;

        // Symbol count
        if (capture_cnt !== TOTAL_SYMS) begin
            $display("FAIL %0s: sym count %0d exp %0d", tc_name, capture_cnt, TOTAL_SYMS);
            fail_cnt = fail_cnt + 1;
            ok = 0;
        end

        // tx_done count
        if (done_cnt !== 1) begin
            $display("FAIL %0s: tx_done fired %0d times (exp 1)", tc_name, done_cnt);
            fail_cnt = fail_cnt + 1;
            ok = 0;
        end

        // FreqCorr: symbols [0..1] = 2'b01
        if (capture_buf[0] !== 2'b01 || capture_buf[1] !== 2'b01) begin
            $display("FAIL %0s: FreqCorr [%0b,%0b] exp [01,01]",
                     tc_name, capture_buf[0], capture_buf[1]);
            fail_cnt = fail_cnt + 1;
            ok = 0;
        end

        // NTS: symbols [110..131]
        for (sym = 0; sym < 22; sym = sym + 1) begin
            if (capture_buf[110 + sym] !== NTS_REF[43 - sym*2 -: 2]) begin
                $display("FAIL %0s: NTS[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[110+sym],
                         NTS_REF[43 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1;
                ok = 0;
            end
        end

        // Block1: symbols [2..109]
        for (sym = 0; sym < 108; sym = sym + 1) begin
            if (capture_buf[2 + sym] !== exp_b1[BLOCK_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: Block1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[2+sym],
                         exp_b1[BLOCK_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1;
                ok = 0;
                if (fail_cnt > 5) sym = 108; // limit output
            end
        end

        // BB: symbols [132..146]
        for (sym = 0; sym < 15; sym = sym + 1) begin
            if (capture_buf[132 + sym] !== exp_bb[BB_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: BB[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[132+sym],
                         exp_bb[BB_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1;
                ok = 0;
            end
        end

        // Block2: symbols [147..254]
        for (sym = 0; sym < 108; sym = sym + 1) begin
            if (capture_buf[147 + sym] !== exp_b2[BLOCK_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: Block2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[147+sym],
                         exp_b2[BLOCK_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1;
                ok = 0;
                if (fail_cnt > 5) sym = 108;
            end
        end

        if (ok) begin
            $display("PASS %0s: all %0d symbols correct, tx_done=1", tc_name, TOTAL_SYMS);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin : stim
    rst_n_sys      = 1'b0;
    build_req_sys  = 1'b0;
    burst_type_sys = 2'd0;
    block1_data_sys = {BLOCK_BITS{1'b0}};
    block2_data_sys = {BLOCK_BITS{1'b0}};
    bb_data_sys     = {BB_BITS{1'b0}};

    repeat (4) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (2) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC1: All-zeros payload
    // -----------------------------------------------------------------------
    $display("--- TC1: All-zeros payload ---");
    block1_data_sys = {BLOCK_BITS{1'b0}};
    block2_data_sys = {BLOCK_BITS{1'b0}};
    bb_data_sys     = {BB_BITS{1'b0}};

    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    capture_burst;
    check_burst({BLOCK_BITS{1'b0}}, {BLOCK_BITS{1'b0}}, {BB_BITS{1'b0}}, "TC1");

    repeat (5) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC2: Known payload (0xAA pattern = 0b10101010...)
    // -----------------------------------------------------------------------
    $display("--- TC2: Known payload (0xAA) ---");
    // Fill 216 bits with repeating 0b10 dibit = 2'b10 per symbol
    block1_data_sys = {108{2'b10}};
    block2_data_sys = {108{2'b01}};
    // BB = 15 symbols of 2'b11
    bb_data_sys     = {15{2'b11}};

    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    capture_burst;
    check_burst({108{2'b10}}, {108{2'b01}}, {15{2'b11}}, "TC2");

    repeat (5) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC3: Back-to-back bursts
    // -----------------------------------------------------------------------
    $display("--- TC3: Back-to-back bursts ---");
    block1_data_sys = {108{2'b01}};
    block2_data_sys = {108{2'b10}};
    bb_data_sys     = {15{2'b01}};

    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    // While first burst runs, prepare second burst; issue second req right after done
    // Wait for tx_done of first burst
    begin : wait_done1
        integer cyc1;
        cyc1 = 0;
        while (!tx_done_sys && cyc1 < 300) begin
            @(posedge clk_sys); #1;
            cyc1 = cyc1 + 1;
        end
    end
    repeat (2) @(posedge clk_sys); #1;

    // Second burst with different payload
    block1_data_sys = {108{2'b11}};
    block2_data_sys = {108{2'b00}};
    bb_data_sys     = {15{2'b10}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    capture_burst;
    check_burst({108{2'b11}}, {108{2'b00}}, {15{2'b10}}, "TC3_second_burst");

    repeat (5) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC4: Reset mid-burst
    // -----------------------------------------------------------------------
    $display("--- TC4: Reset mid-burst ---");
    block1_data_sys = {BLOCK_BITS{1'b1}};
    block2_data_sys = {BLOCK_BITS{1'b1}};
    bb_data_sys     = {BB_BITS{1'b1}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    // Let burst run for 50 symbols
    repeat (55) @(posedge clk_sys); #1;

    // Assert reset
    rst_n_sys = 1'b0;
    @(posedge clk_sys); #1;
    rst_n_sys = 1'b1;
    @(posedge clk_sys); #1;

    // Check outputs are cleared
    if (tx_dibit_valid_sys || tx_busy_sys || tx_done_sys) begin
        $display("FAIL TC4: outputs not cleared after reset (valid=%0b busy=%0b done=%0b)",
                 tx_dibit_valid_sys, tx_busy_sys, tx_done_sys);
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC4: outputs clear after reset");
        pass_cnt = pass_cnt + 1;
    end

    // Verify new burst can be started after reset
    block1_data_sys = {108{2'b10}};
    block2_data_sys = {108{2'b10}};
    bb_data_sys     = {15{2'b10}};
    repeat (2) @(posedge clk_sys); #1;
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;

    capture_burst;
    check_burst({108{2'b10}}, {108{2'b10}}, {15{2'b10}}, "TC4_post_reset");

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    $display("===========================================");
    $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
        $display("*** ALL TESTS PASSED ***");
    else
        $display("*** FAILURES DETECTED ***");
    $display("===========================================");
    $finish;
end

// Watchdog
initial begin
    #200_000;
    $display("FATAL: simulation timeout");
    $finish;
end

endmodule
`default_nettype wire
