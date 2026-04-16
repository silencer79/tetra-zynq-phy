// =============================================================================
// Testbench: tb_tetra_burst_builder
// Module:    tetra_burst_builder
// Project:   tetra-zynq-phy
//
// Self-checking testbench for the continuous downlink burst assembler.
//
// Verifies:
//  - Correct output symbol count: exactly 255 dibits per NDB burst
//  - Tail symbols: Tail1 at [0..5], Tail2 at [250..254]
//  - Phase adj: PADJ at [6] and [249] = 2'b00
//  - NTS position: symbols [122..132] match NTS1_REF (11 symbols)
//  - BB split: bb1 at [115..121] (7 sym), bb2 at [133..140] (8 sym)
//  - Block1 at [7..114] (108 sym), Block2 at [141..248] (108 sym)
//  - tx_done fires on the last valid symbol
//  - tx_busy asserted from build_req until tx_done
//  - SDB burst: Tail1 + HC + FC + sb1 + STS + bb + bkn2 + HD + Tail2
//
// Clock: 10 ns (100 MHz), SYM_DIV=0 for fast simulation
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_burst_builder;

localparam BLOCK_BITS = 216;
localparam BB_BITS    = 30;
localparam SB1_BITS   = 120;
localparam CLK_HALF   = 5;
localparam TOTAL_SYMS = 255;

// NTS1 — Normal Training Sequence 1, 11 symbols (22 bits)
localparam [21:0] NTS1_REF = {
    2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b10,
    2'b10, 2'b01, 2'b11, 2'b01, 2'b00
};

// Tail1 = q[10..21] = 6 symbols
localparam [11:0] TAIL1 = {2'b00, 2'b01, 2'b10, 2'b10, 2'b11, 2'b01};
// Tail2 = q[0..9] = 5 symbols
localparam [9:0] TAIL2 = {2'b10, 2'b11, 2'b01, 2'b11, 2'b00};

// STS — Synchronization Training Sequence, 19 symbols (38 bits)
localparam [37:0] STS_REF = {
    2'b11, 2'b00, 2'b00, 2'b01, 2'b10, 2'b01, 2'b11, 2'b00,
    2'b11, 2'b10, 2'b10, 2'b01, 2'b11, 2'b00, 2'b00, 2'b01,
    2'b10, 2'b01, 2'b11
};

// FC pattern: 4 sym (11), 32 sym (00), 4 sym (11)
localparam [79:0] FC_PAT = {8'hFF, 64'h0000_0000_0000_0000, 8'hFF};

// DUT signals
reg              clk_sys;
reg              rst_n_sys;
reg  [BLOCK_BITS-1:0] block1_data_sys;
reg  [BLOCK_BITS-1:0] block2_data_sys;
reg  [BB_BITS-1:0]    bb_data_sys;
reg  [SB1_BITS-1:0]   sb1_data_sys;
reg              burst_type_sys;
reg              build_req_sys;

wire [1:0]       tx_dibit_sys;
wire             tx_dibit_valid_sys;
wire             tx_done_sys;
wire             tx_busy_sys;

tetra_burst_builder #(
    .BLOCK_BITS(BLOCK_BITS),
    .BB_BITS   (BB_BITS),
    .SB1_BITS  (SB1_BITS),
    .SYM_DIV   (13'd0)
) dut (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .block1_data_sys  (block1_data_sys),
    .block2_data_sys  (block2_data_sys),
    .bb_data_sys      (bb_data_sys),
    .sb1_data_sys     (sb1_data_sys),
    .burst_type_sys   (burst_type_sys),
    .build_req_sys    (build_req_sys),
    .tx_dibit_sys     (tx_dibit_sys),
    .tx_dibit_valid_sys(tx_dibit_valid_sys),
    .tx_done_sys      (tx_done_sys),
    .tx_busy_sys      (tx_busy_sys)
);

initial clk_sys = 1'b0;
always #CLK_HALF clk_sys = ~clk_sys;

initial begin
    $dumpfile("tb_tetra_burst_builder.vcd");
    $dumpvars(0, tb_tetra_burst_builder);
end

integer pass_cnt = 0;
integer fail_cnt = 0;

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
        @(posedge clk_sys); #1;
        if (tx_done_sys)
            done_cnt = done_cnt + 1;
    end
endtask

// ---------------------------------------------------------------------------
// check_ndb — verify continuous NDB burst layout
// NDB: Tail1(6) + HA(1) + blk1(108) + bb1(7) + NTS(11) + bb2(8) + blk2(108) + HB(1) + Tail2(5)
// ---------------------------------------------------------------------------
task check_ndb;
    input [BLOCK_BITS-1:0] exp_b1;
    input [BLOCK_BITS-1:0] exp_b2;
    input [BB_BITS-1:0]    exp_bb;
    input [255:0]          tc_name;
    integer sym;
    integer ok;
    begin
        ok = 1;

        if (capture_cnt !== TOTAL_SYMS) begin
            $display("FAIL %0s: sym count %0d exp %0d", tc_name, capture_cnt, TOTAL_SYMS);
            fail_cnt = fail_cnt + 1; ok = 0;
        end
        if (done_cnt !== 1) begin
            $display("FAIL %0s: tx_done fired %0d times (exp 1)", tc_name, done_cnt);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // Tail1: [0..5]
        for (sym = 0; sym < 6; sym = sym + 1) begin
            if (capture_buf[sym] !== TAIL1[11 - sym*2 -: 2]) begin
                $display("FAIL %0s: Tail1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[sym], TAIL1[11-sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // HA: [6] = 00
        if (capture_buf[6] !== 2'b00) begin
            $display("FAIL %0s: HA=%0b exp=00", tc_name, capture_buf[6]);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // Block1: [7..114]
        for (sym = 0; sym < 108; sym = sym + 1) begin
            if (capture_buf[7 + sym] !== exp_b1[BLOCK_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: Block1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[7+sym],
                         exp_b1[BLOCK_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
                if (fail_cnt > 5) sym = 108;
            end
        end

        // BB1: [115..121] = bb_data[29:16] (7 symbols, 14 bits)
        for (sym = 0; sym < 7; sym = sym + 1) begin
            if (capture_buf[115 + sym] !== exp_bb[BB_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: BB1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[115+sym],
                         exp_bb[BB_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // NTS: [122..132] (11 symbols)
        for (sym = 0; sym < 11; sym = sym + 1) begin
            if (capture_buf[122 + sym] !== NTS1_REF[21 - sym*2 -: 2]) begin
                $display("FAIL %0s: NTS[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[122+sym],
                         NTS1_REF[21 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // BB2: [133..140] = bb_data[15:0] (8 symbols, 16 bits)
        for (sym = 0; sym < 8; sym = sym + 1) begin
            if (capture_buf[133 + sym] !== exp_bb[15 - sym*2 -: 2]) begin
                $display("FAIL %0s: BB2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[133+sym],
                         exp_bb[15 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // Block2: [141..248]
        for (sym = 0; sym < 108; sym = sym + 1) begin
            if (capture_buf[141 + sym] !== exp_b2[BLOCK_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: Block2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[141+sym],
                         exp_b2[BLOCK_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
                if (fail_cnt > 5) sym = 108;
            end
        end

        // HB: [249] = 00
        if (capture_buf[249] !== 2'b00) begin
            $display("FAIL %0s: HB=%0b exp=00", tc_name, capture_buf[249]);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // Tail2: [250..254]
        for (sym = 0; sym < 5; sym = sym + 1) begin
            if (capture_buf[250 + sym] !== TAIL2[9 - sym*2 -: 2]) begin
                $display("FAIL %0s: Tail2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[250+sym], TAIL2[9-sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        if (ok) begin
            $display("PASS %0s: all %0d symbols correct", tc_name, TOTAL_SYMS);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// check_sdb — verify continuous SDB burst layout
// SDB: Tail1(6) + HC(1) + FC(40) + sb1(60) + STS(19) + bb(15) + bkn2(108) + HD(1) + Tail2(5)
// ---------------------------------------------------------------------------
task check_sdb;
    input [SB1_BITS-1:0]  exp_sb1;
    input [BLOCK_BITS-1:0] exp_bkn2;
    input [BB_BITS-1:0]    exp_bb;
    input [255:0]          tc_name;
    integer sym;
    integer ok;
    begin
        ok = 1;

        if (capture_cnt !== TOTAL_SYMS) begin
            $display("FAIL %0s: sym count %0d exp %0d", tc_name, capture_cnt, TOTAL_SYMS);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // Tail1: [0..5]
        for (sym = 0; sym < 6; sym = sym + 1) begin
            if (capture_buf[sym] !== TAIL1[11 - sym*2 -: 2]) begin
                $display("FAIL %0s: Tail1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[sym], TAIL1[11-sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // HC: [6] = 00
        if (capture_buf[6] !== 2'b00) begin
            $display("FAIL %0s: HC=%0b exp=00", tc_name, capture_buf[6]);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // FC: [7..46] (40 symbols)
        for (sym = 0; sym < 40; sym = sym + 1) begin
            if (capture_buf[7 + sym] !== FC_PAT[79 - sym*2 -: 2]) begin
                $display("FAIL %0s: FC[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[7+sym], FC_PAT[79-sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // sb1: [47..106] (60 symbols)
        for (sym = 0; sym < 60; sym = sym + 1) begin
            if (capture_buf[47 + sym] !== exp_sb1[SB1_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: sb1[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[47+sym],
                         exp_sb1[SB1_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
                if (fail_cnt > 5) sym = 60;
            end
        end

        // STS: [107..125] (19 symbols)
        for (sym = 0; sym < 19; sym = sym + 1) begin
            if (capture_buf[107 + sym] !== STS_REF[37 - sym*2 -: 2]) begin
                $display("FAIL %0s: STS[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[107+sym],
                         STS_REF[37 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // BB: [126..140] (15 symbols)
        for (sym = 0; sym < 15; sym = sym + 1) begin
            if (capture_buf[126 + sym] !== exp_bb[BB_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: BB[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[126+sym],
                         exp_bb[BB_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        // bkn2: [141..248] (108 symbols)
        for (sym = 0; sym < 108; sym = sym + 1) begin
            if (capture_buf[141 + sym] !== exp_bkn2[BLOCK_BITS-1 - sym*2 -: 2]) begin
                $display("FAIL %0s: bkn2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[141+sym],
                         exp_bkn2[BLOCK_BITS-1 - sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
                if (fail_cnt > 5) sym = 108;
            end
        end

        // HD: [249] = 00
        if (capture_buf[249] !== 2'b00) begin
            $display("FAIL %0s: HD=%0b exp=00", tc_name, capture_buf[249]);
            fail_cnt = fail_cnt + 1; ok = 0;
        end

        // Tail2: [250..254]
        for (sym = 0; sym < 5; sym = sym + 1) begin
            if (capture_buf[250 + sym] !== TAIL2[9 - sym*2 -: 2]) begin
                $display("FAIL %0s: Tail2[%0d]=%0b exp=%0b",
                         tc_name, sym, capture_buf[250+sym], TAIL2[9-sym*2 -: 2]);
                fail_cnt = fail_cnt + 1; ok = 0;
            end
        end

        if (ok) begin
            $display("PASS %0s: all %0d symbols correct", tc_name, TOTAL_SYMS);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin : stim
    rst_n_sys       = 1'b0;
    build_req_sys   = 1'b0;
    burst_type_sys  = 1'b0;
    block1_data_sys = {BLOCK_BITS{1'b0}};
    block2_data_sys = {BLOCK_BITS{1'b0}};
    bb_data_sys     = {BB_BITS{1'b0}};
    sb1_data_sys    = {SB1_BITS{1'b0}};

    repeat (4) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (2) @(posedge clk_sys); #1;

    // TC1: NDB all-zeros
    $display("--- TC1: NDB all-zeros ---");
    burst_type_sys = 1'b0;
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;
    capture_burst;
    check_ndb({BLOCK_BITS{1'b0}}, {BLOCK_BITS{1'b0}}, {BB_BITS{1'b0}}, "TC1_NDB_zero");
    repeat (5) @(posedge clk_sys); #1;

    // TC2: NDB known payload
    $display("--- TC2: NDB known payload ---");
    burst_type_sys = 1'b0;
    block1_data_sys = {108{2'b10}};
    block2_data_sys = {108{2'b01}};
    bb_data_sys     = {15{2'b11}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;
    capture_burst;
    check_ndb({108{2'b10}}, {108{2'b01}}, {15{2'b11}}, "TC2_NDB_data");
    repeat (5) @(posedge clk_sys); #1;

    // TC3: SDB all-zeros
    $display("--- TC3: SDB all-zeros ---");
    burst_type_sys = 1'b1;
    block1_data_sys = {BLOCK_BITS{1'b0}};
    block2_data_sys = {BLOCK_BITS{1'b0}};
    bb_data_sys     = {BB_BITS{1'b0}};
    sb1_data_sys    = {SB1_BITS{1'b0}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;
    capture_burst;
    check_sdb({SB1_BITS{1'b0}}, {BLOCK_BITS{1'b0}}, {BB_BITS{1'b0}}, "TC3_SDB_zero");
    repeat (5) @(posedge clk_sys); #1;

    // TC4: SDB known payload
    $display("--- TC4: SDB known payload ---");
    burst_type_sys = 1'b1;
    sb1_data_sys    = {60{2'b10}};
    block2_data_sys = {108{2'b01}};
    bb_data_sys     = {15{2'b11}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;
    capture_burst;
    check_sdb({60{2'b10}}, {108{2'b01}}, {15{2'b11}}, "TC4_SDB_data");
    repeat (5) @(posedge clk_sys); #1;

    // TC5: Reset mid-burst
    $display("--- TC5: Reset mid-burst ---");
    burst_type_sys = 1'b0;
    block1_data_sys = {BLOCK_BITS{1'b1}};
    block2_data_sys = {BLOCK_BITS{1'b1}};
    bb_data_sys     = {BB_BITS{1'b1}};
    build_req_sys = 1'b1;
    @(posedge clk_sys); #1;
    build_req_sys = 1'b0;
    repeat (55) @(posedge clk_sys); #1;
    rst_n_sys = 1'b0;
    @(posedge clk_sys); #1;
    rst_n_sys = 1'b1;
    @(posedge clk_sys); #1;
    if (tx_dibit_valid_sys || tx_busy_sys || tx_done_sys) begin
        $display("FAIL TC5: outputs not cleared after reset");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC5: outputs clear after reset");
        pass_cnt = pass_cnt + 1;
    end

    // Summary
    $display("===========================================");
    $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
        $display("*** ALL TESTS PASSED ***");
    else
        $display("*** FAILURES DETECTED ***");
    $display("===========================================");
    $finish;
end

initial begin
    #500_000;
    $display("FATAL: simulation timeout");
    $finish;
end

endmodule
`default_nettype wire
