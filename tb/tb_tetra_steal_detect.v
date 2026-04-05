// =============================================================================
// Testbench: tb_tetra_steal_detect
// Project:   tetra-zynq-phy
// File:      tb/tb_tetra_steal_detect.v
//
// Self-checking testbench for tetra_steal_detect.v
//
// Test cases:
//   TC1: Reset — all outputs zero, no steal flags
//   TC2: TCH/A (normal voice, access_code=6'b000001) → steal_active = 0
//   TC3: STCH  (stolen,        access_code=6'b001000) → steal_active = 1
//   TC4: STCH+ACCH (dual steal, access_code=6'b001001) → steal_active = 1
//   TC5: Unallocated (access_code=6'b000000) → steal_active = 0
//   TC6: All 4 slots, mixed steal/non-steal
//   TC7: SB burst type (burst_type=1) → steal_active NOT updated
//   TC8: Reset mid-sequence clears all flags
//
// Ref: ETSI EN 300 392-2 §21.4.1 Table 21.56
// =============================================================================

`timescale 1ns / 1ps

module tb_tetra_steal_detect;

// =============================================================================
// Parameters
// =============================================================================
localparam AACH_K     = 14;
localparam CLK_HALF   = 5;        // 100 MHz sys clock

// AACH access codes
localparam AC_UNALLOC   = 6'b000000;
localparam AC_TCHA      = 6'b000001;   // TCH/A — normal voice
localparam AC_STCH      = 6'b001000;   // STCH  — stolen
localparam AC_STCH_ACCH = 6'b001001;   // STCH+ACCH — dual steal
localparam AC_MCCH      = 6'b100000;   // MCCH  — control (not stolen)
localparam AC_BNCH      = 6'b100001;   // BNCH  — broadcast

// Burst types
localparam BT_NDB = 2'd0;
localparam BT_SB  = 2'd1;
localparam BT_NUB = 2'd2;

// =============================================================================
// Clock and reset
// =============================================================================
reg clk_sys;
reg rst_n_sys;

initial clk_sys = 1'b0;
always #(CLK_HALF) clk_sys = ~clk_sys;

// =============================================================================
// DUT signals
// =============================================================================
reg  [AACH_K-1:0] aach_data_sys;
reg               aach_valid_sys;
reg  [1:0]        slot_num_sys;
reg  [1:0]        burst_type_sys;

wire [3:0]        steal_active_sys;
wire [5:0]        access_code0_sys;
wire [5:0]        access_code1_sys;
wire [5:0]        access_code2_sys;
wire [5:0]        access_code3_sys;

// =============================================================================
// DUT instantiation
// =============================================================================
tetra_steal_detect #(
    .AACH_K (AACH_K)
) dut (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .aach_data_sys    (aach_data_sys),
    .aach_valid_sys   (aach_valid_sys),
    .slot_num_sys     (slot_num_sys),
    .burst_type_sys   (burst_type_sys),
    .steal_active_sys (steal_active_sys),
    .access_code0_sys (access_code0_sys),
    .access_code1_sys (access_code1_sys),
    .access_code2_sys (access_code2_sys),
    .access_code3_sys (access_code3_sys)
);

// =============================================================================
// Waveform dump
// =============================================================================
initial begin
    $dumpfile("tb_tetra_steal_detect.vcd");
    $dumpvars(0, tb_tetra_steal_detect);
end

// =============================================================================
// Test bookkeeping
// =============================================================================
integer tc_pass;
integer tc_fail;

task check;
    input [31:0] got;
    input [31:0] exp;
    input [63:0] label;
    begin
        if (got !== exp) begin
            $display("  FAIL %s: got=0x%0x exp=0x%0x", label, got, exp);
            tc_fail = tc_fail + 1;
        end else begin
            $display("  PASS %s", label);
            tc_pass = tc_pass + 1;
        end
    end
endtask

// =============================================================================
// Helper: send one AACH pulse
// =============================================================================
task send_aach;
    input [AACH_K-1:0] data;
    input [1:0]        slot;
    input [1:0]        btype;
    begin
        @(posedge clk_sys); #1;
        aach_data_sys  = data;
        aach_valid_sys = 1'b1;
        slot_num_sys   = slot;
        burst_type_sys = btype;
        @(posedge clk_sys); #1;
        aach_valid_sys = 1'b0;
        // One more cycle for registered output to settle
        @(posedge clk_sys); #1;
    end
endtask

// Helper: build 14-bit AACH from 6-bit access code + 8-bit secondary field
function [AACH_K-1:0] make_aach;
    input [5:0] ac;
    input [7:0] sec;
    begin
        make_aach = {ac, sec};   // bits [13:8]=access_code, [7:0]=secondary
    end
endfunction

// =============================================================================
// Main test sequence
// =============================================================================
initial begin
    tc_pass = 0;
    tc_fail = 0;

    // Defaults
    aach_data_sys  = {AACH_K{1'b0}};
    aach_valid_sys = 1'b0;
    slot_num_sys   = 2'd0;
    burst_type_sys = BT_NDB;

    // -------------------------------------------------------------------------
    // TC1: Reset — all outputs must be zero
    // -------------------------------------------------------------------------
    $display("--- TC1: Reset ---");
    rst_n_sys = 1'b0;
    repeat(10) @(posedge clk_sys);
    #1;
    check(steal_active_sys, 4'b0000, "steal_active after reset");
    check(access_code0_sys, 6'd0,    "access_code0 after reset");
    check(access_code1_sys, 6'd0,    "access_code1 after reset");
    check(access_code2_sys, 6'd0,    "access_code2 after reset");
    check(access_code3_sys, 6'd0,    "access_code3 after reset");
    rst_n_sys = 1'b1;
    repeat(2) @(posedge clk_sys);

    // -------------------------------------------------------------------------
    // TC2: TCH/A on slot 0 → steal_active[0] = 0
    // -------------------------------------------------------------------------
    $display("--- TC2: TCH/A slot 0 (no steal) ---");
    send_aach(make_aach(AC_TCHA, 8'h00), 2'd0, BT_NDB);
    check(steal_active_sys[0], 1'b0,   "steal_active[0]");
    check(access_code0_sys,    AC_TCHA, "access_code0");

    // -------------------------------------------------------------------------
    // TC3: STCH on slot 1 → steal_active[1] = 1
    // -------------------------------------------------------------------------
    $display("--- TC3: STCH slot 1 (stolen) ---");
    send_aach(make_aach(AC_STCH, 8'hAB), 2'd1, BT_NDB);
    check(steal_active_sys[1], 1'b1,    "steal_active[1]");
    check(access_code1_sys,    AC_STCH, "access_code1");
    // Other slots must be unaffected
    check(steal_active_sys[0], 1'b0,    "steal_active[0] unchanged");

    // -------------------------------------------------------------------------
    // TC4: STCH+ACCH on slot 2 → steal_active[2] = 1
    // -------------------------------------------------------------------------
    $display("--- TC4: STCH+ACCH slot 2 (dual steal) ---");
    send_aach(make_aach(AC_STCH_ACCH, 8'h55), 2'd2, BT_NDB);
    check(steal_active_sys[2], 1'b1,         "steal_active[2]");
    check(access_code2_sys,    AC_STCH_ACCH, "access_code2");

    // -------------------------------------------------------------------------
    // TC5: Unallocated on slot 3 → steal_active[3] = 0
    // -------------------------------------------------------------------------
    $display("--- TC5: Unallocated slot 3 ---");
    send_aach(make_aach(AC_UNALLOC, 8'h00), 2'd3, BT_NDB);
    check(steal_active_sys[3], 1'b0,      "steal_active[3]");
    check(access_code3_sys,    AC_UNALLOC, "access_code3");

    // -------------------------------------------------------------------------
    // TC6: All 4 slots mixed — slot 0 stolen, 1 normal, 2 stolen, 3 MCCH
    // -------------------------------------------------------------------------
    $display("--- TC6: Mixed 4-slot scenario ---");
    send_aach(make_aach(AC_STCH, 8'h01), 2'd0, BT_NDB);   // slot 0: stolen
    send_aach(make_aach(AC_TCHA, 8'h02), 2'd1, BT_NDB);   // slot 1: normal
    send_aach(make_aach(AC_STCH, 8'h03), 2'd2, BT_NDB);   // slot 2: stolen
    send_aach(make_aach(AC_MCCH, 8'h04), 2'd3, BT_NDB);   // slot 3: MCCH (not stolen)
    check(steal_active_sys, 4'b0101, "steal_active all 4 slots");
    check(access_code0_sys, AC_STCH, "access_code0");
    check(access_code1_sys, AC_TCHA, "access_code1");
    check(access_code2_sys, AC_STCH, "access_code2");
    check(access_code3_sys, AC_MCCH, "access_code3");

    // -------------------------------------------------------------------------
    // TC7: SB burst type → steal_active must NOT be updated
    // -------------------------------------------------------------------------
    $display("--- TC7: SB burst type (no AACH update) ---");
    // First set slot 0 to non-stolen
    send_aach(make_aach(AC_TCHA, 8'h00), 2'd0, BT_NDB);
    check(steal_active_sys[0], 1'b0, "TC7 pre: slot 0 not stolen");
    // Now send STCH via SB — should be ignored
    send_aach(make_aach(AC_STCH, 8'hFF), 2'd0, BT_SB);
    check(steal_active_sys[0], 1'b0, "TC7: SB ignored, steal_active[0] unchanged");
    check(access_code0_sys, AC_TCHA, "TC7: access_code0 unchanged");
    // Also test NUB
    send_aach(make_aach(AC_STCH, 8'hFF), 2'd0, BT_NUB);
    check(steal_active_sys[0], 1'b0, "TC7: NUB ignored, steal_active[0] unchanged");

    // -------------------------------------------------------------------------
    // TC8: Reset mid-sequence clears all flags
    // -------------------------------------------------------------------------
    $display("--- TC8: Reset mid-sequence ---");
    // Set some steal flags
    send_aach(make_aach(AC_STCH, 8'h00), 2'd0, BT_NDB);
    send_aach(make_aach(AC_STCH, 8'h00), 2'd1, BT_NDB);
    check(steal_active_sys[1:0], 2'b11, "pre-reset: slots 0,1 stolen");
    // Assert reset
    rst_n_sys = 1'b0;
    @(posedge clk_sys); #1;
    check(steal_active_sys, 4'b0000, "steal_active cleared by reset");
    check(access_code0_sys, 6'd0,    "access_code0 cleared by reset");
    check(access_code1_sys, 6'd0,    "access_code1 cleared by reset");
    rst_n_sys = 1'b1;
    @(posedge clk_sys); #1;

    // -------------------------------------------------------------------------
    // TC9: BNCH access code — not stolen (access_code[5:3] = 100)
    // -------------------------------------------------------------------------
    $display("--- TC9: BNCH slot 0 (not stolen) ---");
    send_aach(make_aach(AC_BNCH, 8'h00), 2'd0, BT_NDB);
    check(steal_active_sys[0], 1'b0,   "BNCH not stolen");
    check(access_code0_sys,    AC_BNCH, "access_code0=BNCH");

    // =========================================================================
    // Summary
    // =========================================================================
    $display("=================================");
    $display("RESULT: PASS=%0d  FAIL=%0d", tc_pass, tc_fail);
    if (tc_fail == 0)
        $display("*** ALL TESTS PASSED ***");
    else
        $display("*** FAILURES DETECTED ***");
    $display("=================================");
    $finish;
end

// Timeout watchdog
initial begin
    #1_000_000;
    $display("ERROR: Simulation timeout!");
    $finish;
end

endmodule
