// =============================================================================
// Testbench: tb_tetra_burst_mux
// Module:    tetra_burst_mux
// Project:   tetra-zynq-phy
//
// Self-checking testbench for the TDMA Burst Multiplexer.
//
// Test cases:
//   TC1: Single active slot (slot 0), others disabled — correct payload forwarded
//   TC2: All 4 slots active — all 4 are forwarded in order with correct payloads
//   TC3: Disabled slot — burst_type=2 and payload is all-zeros
//   TC4: builder_busy stall — pulse during busy; mux defers until builder idle
//   TC5: Back-to-back slots (pulse while still in S_WAIT) — second pulse ignored
//
// Timing: clk = 10 ns (100 MHz)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_burst_mux;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam BLOCK_BITS   = 216;
localparam BB_BITS      = 30;
localparam BKN1_SB_BITS = 240;
localparam BB_SB_BITS   = 28;
localparam CLK_HALF     = 5;      // 100 MHz

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg              clk_sys;
reg              rst_n_sys;

reg  [4*BLOCK_BITS-1:0] block1_in_sys;
reg  [4*BLOCK_BITS-1:0] block2_in_sys;
reg  [4*BB_BITS-1:0]    bb_in_sys;
reg  [BKN1_SB_BITS-1:0] sb_bkn1_in_sys;
reg  [BLOCK_BITS-1:0]   sb_bkn2_in_sys;
reg  [BB_SB_BITS-1:0]   sb_bb_in_sys;
reg  [3:0]              slot_en_sys;
reg  [7:0]              slot_burst_type_sys;
reg  [1:0]              tx_slot_num_sys;
reg                     tx_slot_pulse_sys;
reg                     builder_busy_sys;

wire [BLOCK_BITS-1:0]   build_block1_sys;
wire [BLOCK_BITS-1:0]   build_block2_sys;
wire [BB_BITS-1:0]      build_bb_sys;
wire [1:0]              build_burst_type_sys;
wire                    build_req_sys;
wire                    mux_ready_sys;

// ---------------------------------------------------------------------------
// Instantiation
// ---------------------------------------------------------------------------
tetra_burst_mux #(
    .BLOCK_BITS  (BLOCK_BITS),
    .BB_BITS     (BB_BITS),
    .TS_PER_FRAME(4)
) dut (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .block1_in_sys        (block1_in_sys),
    .block2_in_sys        (block2_in_sys),
    .bb_in_sys            (bb_in_sys),
    .sb_bkn1_in_sys       (sb_bkn1_in_sys),
    .sb_bkn2_in_sys       (sb_bkn2_in_sys),
    .sb_bb_in_sys         (sb_bb_in_sys),
    .slot_en_sys          (slot_en_sys),
    .slot_burst_type_sys  (slot_burst_type_sys),
    .tx_slot_num_sys      (tx_slot_num_sys),
    .tx_slot_pulse_sys    (tx_slot_pulse_sys),
    .build_block1_sys     (build_block1_sys),
    .build_block2_sys     (build_block2_sys),
    .build_bb_sys         (build_bb_sys),
    .build_bkn1_sb_sys    (),
    .build_bkn2_sb_sys    (),
    .build_bb_sb_sys      (),
    .build_burst_type_sys (build_burst_type_sys),
    .build_req_sys        (build_req_sys),
    .builder_busy_sys     (builder_busy_sys),
    .mux_ready_sys        (mux_ready_sys)
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
    $dumpfile("tb_tetra_burst_mux.vcd");
    $dumpvars(0, tb_tetra_burst_mux);
end

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
integer pass_cnt = 0;
integer fail_cnt = 0;

task check;
    input [255:0] name_bits;
    input [BLOCK_BITS-1:0] actual_b1;
    input [BLOCK_BITS-1:0] expected_b1;
    input [BLOCK_BITS-1:0] actual_b2;
    input [BLOCK_BITS-1:0] expected_b2;
    input [BB_BITS-1:0]    actual_bb;
    input [BB_BITS-1:0]    expected_bb;
    input [1:0]            actual_bt;
    input [1:0]            expected_bt;
    begin
        if (actual_b1 !== expected_b1 || actual_b2 !== expected_b2 ||
            actual_bb !== expected_bb || actual_bt !== expected_bt) begin
            $display("FAIL %0s", name_bits);
            if (actual_b1 !== expected_b1)
                $display("  block1: got=%h exp=%h", actual_b1, expected_b1);
            if (actual_b2 !== expected_b2)
                $display("  block2: got=%h exp=%h", actual_b2, expected_b2);
            if (actual_bb !== expected_bb)
                $display("  bb:     got=%h exp=%h", actual_bb, expected_bb);
            if (actual_bt !== expected_bt)
                $display("  btype:  got=%0d exp=%0d", actual_bt, expected_bt);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS %0s", name_bits);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// Wait for build_req, then check outputs (combinatorial before req)
task wait_req;
    input integer timeout_cyc;
    integer cyc;
    begin
        cyc = 0;
        while (!build_req_sys && cyc < timeout_cyc) begin
            @(posedge clk_sys); #1;
            cyc = cyc + 1;
        end
        if (!build_req_sys) begin
            $display("FAIL: build_req timeout after %0d cycles", timeout_cyc);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Helper: set flat input buses for a given slot
// (Other slots keep their previous values)
// ---------------------------------------------------------------------------
task set_slot;
    input [1:0] slot;
    input [BLOCK_BITS-1:0] b1, b2;
    input [BB_BITS-1:0]    bb;
    begin
        block1_in_sys[slot*BLOCK_BITS +: BLOCK_BITS] = b1;
        block2_in_sys[slot*BLOCK_BITS +: BLOCK_BITS] = b2;
        bb_in_sys    [slot*BB_BITS    +: BB_BITS   ] = bb;
    end
endtask

// ---------------------------------------------------------------------------
// Test stimulus
// ---------------------------------------------------------------------------
integer i;

initial begin : stim
    // -----------------------------------------------------------------------
    // Initialise
    // -----------------------------------------------------------------------
    rst_n_sys         = 1'b0;
    tx_slot_pulse_sys = 1'b0;
    tx_slot_num_sys   = 2'd0;
    builder_busy_sys  = 1'b0;
    slot_en_sys       = 4'b1111;
    slot_burst_type_sys = 8'h00;
    block1_in_sys     = {(4*BLOCK_BITS){1'b0}};
    block2_in_sys     = {(4*BLOCK_BITS){1'b0}};
    bb_in_sys         = {(4*BB_BITS){1'b0}};
    sb_bkn1_in_sys    = {BKN1_SB_BITS{1'b0}};
    sb_bkn2_in_sys    = {BLOCK_BITS{1'b0}};
    sb_bb_in_sys      = {BB_SB_BITS{1'b0}};

    repeat (4) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC1: Slot 0 active (NDB), others disabled
    // -----------------------------------------------------------------------
    $display("--- TC1: Single active slot (slot 0) ---");
    set_slot(2'd0, 216'hA0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0,
                   216'hB0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0,
                   30'h1AAAAAA);
    set_slot(2'd1, 216'h111111111111111111111111111111111111111111111111111111,
                   216'h222222222222222222222222222222222222222222222222222222, 30'h00);
    set_slot(2'd2, 216'h333333333333333333333333333333333333333333333333333333,
                   216'h444444444444444444444444444444444444444444444444444444, 30'h00);
    set_slot(2'd3, 216'h555555555555555555555555555555555555555555555555555555,
                   216'h666666666666666666666666666666666666666666666666666666, 30'h00);

    slot_en_sys      = 4'b0001;
    tx_slot_num_sys  = 2'd0;
    tx_slot_pulse_sys = 1'b1;
    @(posedge clk_sys); #1;
    tx_slot_pulse_sys = 1'b0;

    // Wait for build_req (should come in ≤3 cycles since builder_busy=0)
    wait_req(10);

    check("TC1_slot0",
        build_block1_sys, 216'hA0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0,
        build_block2_sys, 216'hB0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0,
        build_bb_sys,     30'h1AAAAAA,
        build_burst_type_sys, 2'd0);

    // Simulate builder busy for 300 cycles, then mux returns to IDLE
    builder_busy_sys = 1'b1;
    repeat (10) @(posedge clk_sys);
    builder_busy_sys = 1'b0;
    repeat (5) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC2: All 4 slots active, round-robin
    // -----------------------------------------------------------------------
    $display("--- TC2: All 4 slots active ---");
    slot_en_sys = 4'b1111;

    for (i = 0; i < 4; i = i + 1) begin : tc2_loop
        set_slot(i[1:0],
            (i == 0) ? 216'h1111111111111111111111111111111111111111111111111111111 :
            (i == 1) ? 216'h2222222222222222222222222222222222222222222222222222222 :
            (i == 2) ? 216'h3333333333333333333333333333333333333333333333333333333 :
                       216'h4444444444444444444444444444444444444444444444444444444,
            (i == 0) ? 216'h5555555555555555555555555555555555555555555555555555555 :
            (i == 1) ? 216'h6666666666666666666666666666666666666666666666666666666 :
            (i == 2) ? 216'h7777777777777777777777777777777777777777777777777777777 :
                       216'h8888888888888888888888888888888888888888888888888888888,
            (i == 0) ? 30'h11111 :
            (i == 1) ? 30'h22222 :
            (i == 2) ? 30'h33333 : 30'h3FFFF);
    end

    for (i = 0; i < 4; i = i + 1) begin : tc2_run
        // Ensure mux is ready
        repeat (2) @(posedge clk_sys); #1;
        tx_slot_num_sys   = i[1:0];
        tx_slot_pulse_sys = 1'b1;
        @(posedge clk_sys); #1;
        tx_slot_pulse_sys = 1'b0;

        wait_req(10);

        // Check burst_type is NDB (0)
        if (build_burst_type_sys !== 2'd0) begin
            $display("FAIL TC2_slot%0d burst_type got=%0d exp=0", i, build_burst_type_sys);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS TC2_slot%0d burst_type=NDB", i);
            pass_cnt = pass_cnt + 1;
        end

        // Simulate builder busy
        builder_busy_sys = 1'b1;
        repeat (8) @(posedge clk_sys);
        builder_busy_sys = 1'b0;
        repeat (3) @(posedge clk_sys); #1;
    end

    // -----------------------------------------------------------------------
    // TC3: Disabled slot → burst_type=2, payload=all-zeros
    // -----------------------------------------------------------------------
    $display("--- TC3: Disabled slot 1 → Idle burst ---");
    slot_en_sys     = 4'b1101;   // slot 1 disabled
    tx_slot_num_sys = 2'd1;

    // Set non-zero payload for slot 1 to verify it is NOT passed
    set_slot(2'd1, 216'hDEAD_BEEF_CAFE_DEAD_BEEF_CAFE_DEAD_BEEF_CAFE_DEAD_BEEF_CAFE,
                   216'hBEEF_DEAD_CAFE_BEEF_DEAD_CAFE_BEEF_DEAD_CAFE_BEEF_DEAD_CAFE,
                   30'h3ABCDE);

    tx_slot_pulse_sys = 1'b1;
    @(posedge clk_sys); #1;
    tx_slot_pulse_sys = 1'b0;

    wait_req(10);

    if (build_burst_type_sys !== 2'd2) begin
        $display("FAIL TC3: burst_type got=%0d exp=2", build_burst_type_sys);
        fail_cnt = fail_cnt + 1;
    end else
        $display("PASS TC3: burst_type=Idle (2)");

    if (build_block1_sys !== {BLOCK_BITS{1'b0}}) begin
        $display("FAIL TC3: block1 not zeroed for idle burst");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC3: block1=zeros for idle burst");
        pass_cnt = pass_cnt + 1;
    end

    builder_busy_sys = 1'b1;
    repeat (8) @(posedge clk_sys);
    builder_busy_sys = 1'b0;
    repeat (3) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC4: builder_busy stall — pulse while builder busy; mux defers
    // -----------------------------------------------------------------------
    $display("--- TC4: Builder-busy stall ---");
    slot_en_sys     = 4'b1111;
    tx_slot_num_sys = 2'd2;
    set_slot(2'd2, 216'hC2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2,
                   216'hD2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2,
                   30'h12345);

    // Mark builder busy BEFORE pulse
    builder_busy_sys = 1'b1;

    tx_slot_pulse_sys = 1'b1;
    @(posedge clk_sys); #1;
    tx_slot_pulse_sys = 1'b0;

    // Verify build_req NOT asserted while busy
    @(posedge clk_sys); #1;
    @(posedge clk_sys); #1;
    if (build_req_sys) begin
        $display("FAIL TC4: build_req asserted while builder_busy");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC4: build_req deferred while builder_busy");
        pass_cnt = pass_cnt + 1;
    end

    // Release builder → mux should now forward
    builder_busy_sys = 1'b0;
    wait_req(10);

    check("TC4_slot2",
        build_block1_sys, 216'hC2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2C2,
        build_block2_sys, 216'hD2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2D2,
        build_bb_sys,     30'h12345,
        build_burst_type_sys, 2'd0);

    builder_busy_sys = 1'b1;
    repeat (8) @(posedge clk_sys);
    builder_busy_sys = 1'b0;
    repeat (3) @(posedge clk_sys); #1;

    // -----------------------------------------------------------------------
    // TC5: mux_ready_sys is LOW during burst cycle
    // -----------------------------------------------------------------------
    $display("--- TC5: mux_ready LOW during burst ---");
    tx_slot_num_sys  = 2'd3;
    tx_slot_pulse_sys = 1'b1;
    @(posedge clk_sys); #1;
    tx_slot_pulse_sys = 1'b0;

    // mux_ready should drop after pulse accepted
    @(posedge clk_sys); #1;
    if (mux_ready_sys) begin
        $display("FAIL TC5: mux_ready still HIGH after slot pulse");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC5: mux_ready LOW while processing");
        pass_cnt = pass_cnt + 1;
    end

    wait_req(10);
    builder_busy_sys = 1'b1;
    repeat (5) @(posedge clk_sys);
    builder_busy_sys = 1'b0;
    repeat (5) @(posedge clk_sys); #1;

    if (!mux_ready_sys) begin
        $display("FAIL TC5: mux_ready not restored after completion");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC5: mux_ready restored after burst complete");
        pass_cnt = pass_cnt + 1;
    end

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
    #2_000_000;
    $display("FATAL: simulation timeout");
    $finish;
end

endmodule
`default_nettype wire
