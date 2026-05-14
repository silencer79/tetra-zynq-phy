// =============================================================================
// tb_tetra_burst_demux.v — Self-Checking Testbench
// =============================================================================
//
// Tests tetra_burst_demux.v with synthetic NDB burst data.
//
// IMPORTANT — slot_position convention:
// slot_position=0 corresponds to the first BB symbol of slot N, i.e., the
// cycle AFTER sync fires. A "period" (255 symbols between two syncs) covers:
//
// pos 0– 14: BB of slot N (BB_START..BB_END)
// pos 15–122: Block2 of slot N (BLOCK2_START..BLOCK2_END)
// pos 123–124: FreqCorr of slot N+1
// pos 125–232: Block1 of slot N+1
// pos 233–253: TS symbols 0..20 of slot N+1
// pos 254: TS symbol 21 of slot N+1 → sync fires, slot_position→0
//
// Test cases:
// TC1 — No slot_valid while sync_locked=0
// TC2 — First complete burst: appears after period 1 (slot_cnt=1)
// TC3 — Three more consecutive bursts (slots 2,3,0 wrapping)
// TC4 — Unlock/relock: state reset, burst resumes after two periods
//
// Self-checking: $error on any field mismatch; final PASS/FAIL summary.
//
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_tetra_burst_demux;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam BLOCK_BITS = 216;
localparam BB_BITS = 30;
localparam CLK_PERIOD = 10; // ns, 100 MHz
localparam SYMS_PER_SLOT = 255;
// dibit_valid fires every STRIDE clocks (speed up sim vs real 18 kHz)
localparam STRIDE = 4;

// NDB absolute positions within a burst slot
localparam FREQCORR_START = 0;
localparam FREQCORR_END = 1;
localparam BLOCK1_START = 2;
localparam BLOCK1_END = 109;
localparam TS_START = 110;
localparam TS_END = 131;
localparam BB_START = 132;
localparam BB_END = 146;
localparam BLOCK2_START = 147;
localparam BLOCK2_END = 254;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg clk_sample;
reg rst_n_sample;
reg [1:0] dibit_in;
reg dibit_valid;
reg sync_found;
reg sync_locked;
reg [7:0] slot_position;
reg [1:0] slot_number;
reg [1:0] seq_select;

wire [BLOCK_BITS-1:0] block1_data;
wire [BLOCK_BITS-1:0] block2_data;
wire [BB_BITS-1:0] bb_data;
wire [1:0] slot_num_out;
wire slot_valid;
wire [1:0] burst_type;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
tetra_burst_demux #(
.BLOCK_BITS (BLOCK_BITS),
.BB_BITS (BB_BITS),
.TS_PER_FRAME(4)
) dut (
.clk_sample (clk_sample),
.rst_n_sample (rst_n_sample),
.dibit_in (dibit_in),
.dibit_valid (dibit_valid),
.sync_found (sync_found),
.sync_locked (sync_locked),
.slot_position (slot_position),
.slot_number (slot_number),
.seq_select (seq_select),
.block1_data (block1_data),
.block2_data (block2_data),
.bb_data (bb_data),
.slot_num_out (slot_num_out),
.slot_valid (slot_valid),
.burst_type (burst_type)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
 $dumpfile("tb_tetra_burst_demux.vcd");
 $dumpvars(0, tb_tetra_burst_demux);
end

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------
initial clk_sample = 1'b0;
always #(CLK_PERIOD/2) clk_sample = ~clk_sample;

// ---------------------------------------------------------------------------
// NTS reference (oldest-first, matching sync_detect NTS_REF)
// ---------------------------------------------------------------------------
reg [1:0] nts_sym [0:21];
initial begin
 nts_sym[ 0] = 2'b01; nts_sym[ 1] = 2'b11;
 nts_sym[ 2] = 2'b00; nts_sym[ 3] = 2'b00;
 nts_sym[ 4] = 2'b01; nts_sym[ 5] = 2'b11;
 nts_sym[ 6] = 2'b00; nts_sym[ 7] = 2'b10;
 nts_sym[ 8] = 2'b01; nts_sym[ 9] = 2'b10;
 nts_sym[10] = 2'b00; nts_sym[11] = 2'b11;
 nts_sym[12] = 2'b01; nts_sym[13] = 2'b10;
 nts_sym[14] = 2'b10; nts_sym[15] = 2'b11;
 nts_sym[16] = 2'b01; nts_sym[17] = 2'b10;
 nts_sym[18] = 2'b10; nts_sym[19] = 2'b01;
 nts_sym[20] = 2'b11; nts_sym[21] = 2'b00;
end

// ---------------------------------------------------------------------------
// Deterministic test patterns (matches gen_burst_vectors.py)
// ---------------------------------------------------------------------------
function [1:0] b1_dibit;
 input integer s, f;
 begin b1_dibit = ((s * 4 + f + 1) % 4); end
endfunction

function [1:0] bb_dibit;
 input integer s, f;
 begin bb_dibit = ((s + 1) % 4); end
endfunction

function [1:0] b2_dibit;
 input integer s, f;
 begin b2_dibit = (((s + f * 4 + 2) % 3) + 1); end
endfunction

// Return dibit given slot_position P within a period that started after
// sync for slot (cur_s, cur_f). Next slot is (nxt_s, nxt_f).
function [1:0] period_dibit;
 input integer p;
 input integer cur_s, cur_f; // slot whose BB/Block2 follow the sync
 input integer nxt_s, nxt_f; // slot whose Block1/TS precede next sync
 begin
 if (p >= 0 && p <= 14) // BB of cur slot: abs 132+p
 period_dibit = bb_dibit(cur_s, cur_f);
 else if (p >= 15 && p <= 122) // Block2 of cur slot: abs 147+(p-15)
 period_dibit = b2_dibit(cur_s, cur_f);
 else if (p >= 123 && p <= 124) // FreqCorr of nxt slot
 period_dibit = 2'b00;
 else if (p >= 125 && p <= 232) // Block1 of nxt slot: abs 2+(p-125)
 period_dibit = b1_dibit(nxt_s, nxt_f);
 else if (p >= 233 && p <= 253) // TS[0..20] of nxt slot
 period_dibit = nts_sym[p - 233];
 else // p == 254: TS[21], sync fires
 period_dibit = nts_sym[21];
 end
endfunction

// ---------------------------------------------------------------------------
// Expected block values
// ---------------------------------------------------------------------------
function [BLOCK_BITS-1:0] exp_block1;
 input integer s, f;
 integer i;
 reg [BLOCK_BITS-1:0] acc;
 begin
 acc = 0;
 for (i = 0; i < 108; i = i + 1)
 acc = {acc[BLOCK_BITS-3:0], b1_dibit(s, f)};
 exp_block1 = acc;
 end
endfunction

function [BB_BITS-1:0] exp_bb;
 input integer s, f;
 integer i;
 reg [BB_BITS-1:0] acc;
 begin
 acc = 0;
 for (i = 0; i < 15; i = i + 1)
 acc = {acc[BB_BITS-3:0], bb_dibit(s, f)};
 exp_bb = acc;
 end
endfunction

function [BLOCK_BITS-1:0] exp_block2;
 input integer s, f;
 integer i;
 reg [BLOCK_BITS-1:0] acc;
 begin
 acc = 0;
 for (i = 0; i < 108; i = i + 1)
 acc = {acc[BLOCK_BITS-3:0], b2_dibit(s, f)};
 exp_block2 = acc;
 end
endfunction

// ---------------------------------------------------------------------------
// Task: drive one 255-symbol period
// cur_s/cur_f: slot that just had its sync (BB+Block2 are from this slot)
// nxt_s/nxt_f: the following slot (Block1 is from this slot)
// At end: sync fires (slot_position→0, sync_found→1 for one cycle).
// ---------------------------------------------------------------------------
task drive_period;
 input integer cur_s, cur_f, nxt_s, nxt_f;
 integer p;
 begin
 for (p = 0; p < SYMS_PER_SLOT; p = p + 1) begin
 @(posedge clk_sample); #1;
 dibit_in = period_dibit(p, cur_s, cur_f, nxt_s, nxt_f);
 dibit_valid = 1'b1;
 slot_position = p[7:0];
 sync_found = 1'b0;
 @(posedge clk_sample); #1;
 dibit_valid = 1'b0;
 repeat(STRIDE - 2) @(posedge clk_sample);
 end
 // End of period: sync fires simultaneously with slot_position→0
 @(posedge clk_sample); #1;
 slot_position = 8'd0;
 sync_found = 1'b1;
 @(posedge clk_sample); #1;
 sync_found = 1'b0;
 repeat(STRIDE - 2) @(posedge clk_sample);
 end
endtask

// ---------------------------------------------------------------------------
// slot_valid monitor — captures outputs when slot_valid fires.
// valid_pending acts as a sticky flag so expect_burst does not race with
// the one-cycle slot_valid pulse.
// ---------------------------------------------------------------------------
reg valid_pending;
reg [BLOCK_BITS-1:0] cap_block1, cap_block2;
reg [BB_BITS-1:0] cap_bb;
reg [1:0] cap_slot_num;
reg [1:0] cap_burst_type;

initial begin
 valid_pending = 1'b0;
 cap_block1 = 0;
 cap_block2 = 0;
 cap_bb = 0;
 cap_slot_num = 0;
 cap_burst_type = 0;
end

always @(posedge clk_sample) begin
 if (slot_valid) begin
 valid_pending <= 1'b1;
 cap_block1 <= block1_data;
 cap_block2 <= block2_data;
 cap_bb <= bb_data;
 cap_slot_num <= slot_num_out;
 cap_burst_type <= burst_type;
 end
end

// ---------------------------------------------------------------------------
// Task: wait for slot_valid (via valid_pending) and check outputs
// ---------------------------------------------------------------------------
integer err_count;

task expect_burst;
 input integer s, f;
 input integer exp_slot_num;
 integer timeout;
 begin
 timeout = 0;
 // Wait for valid_pending (sticky: survives until we clear it)
 while (!valid_pending && timeout < SYMS_PER_SLOT * STRIDE * 2) begin
 @(posedge clk_sample);
 timeout = timeout + 1;
 end
 if (!valid_pending) begin
 $error("TIMEOUT waiting for slot_valid (slot %0d frame %0d)", s, f);
 err_count = err_count + 1;
 end else begin
 if (cap_slot_num !== exp_slot_num[1:0]) begin
 $error("slot_num_out=%0d, expected=%0d (s=%0d f=%0d)",
 cap_slot_num, exp_slot_num, s, f);
 err_count = err_count + 1;
 end
 if (cap_block1 !== exp_block1(s, f)) begin
 $error("block1 mismatch s=%0d f=%0d\n got=%h\n exp=%h",
 s, f, cap_block1, exp_block1(s, f));
 err_count = err_count + 1;
 end
 if (cap_bb !== exp_bb(s, f)) begin
 $error("bb mismatch s=%0d f=%0d got=%h exp=%h",
 s, f, cap_bb, exp_bb(s, f));
 err_count = err_count + 1;
 end
 if (cap_block2 !== exp_block2(s, f)) begin
 $error("block2 mismatch s=%0d f=%0d\n got=%h\n exp=%h",
 s, f, cap_block2, exp_block2(s, f));
 err_count = err_count + 1;
 end
 end
 // Clear sticky flag for next burst check
 valid_pending = 1'b0;
 @(posedge clk_sample);
 end
endtask

// ---------------------------------------------------------------------------
// Main test sequence
// ---------------------------------------------------------------------------
initial begin
 err_count = 0;
 rst_n_sample = 1'b0;
 sync_locked = 1'b0;
 sync_found = 1'b0;
 dibit_valid = 1'b0;
 dibit_in = 2'b00;
 slot_position = 8'd0;
 slot_number = 2'd0;
 seq_select = 2'd0;

 repeat(8) @(posedge clk_sample);
 rst_n_sample = 1'b1;
 repeat(4) @(posedge clk_sample);

 // -------------------------------------------------------------------
 // TC1: No slot_valid without sync_locked
 // -------------------------------------------------------------------
 $display("TC1: no output while sync_locked=0...");
 sync_locked = 1'b0;
 fork
 begin: tc1_drive
 // Period 0: slot 0,frame 0 → next slot 1,frame 0
 drive_period(0, 0, 1, 0);
 end
 begin: tc1_monitor
 integer i;
 for (i = 0; i < SYMS_PER_SLOT * STRIDE + 10; i = i + 1) begin
 @(posedge clk_sample);
 if (slot_valid) begin
 $error("TC1: unexpected slot_valid");
 err_count = err_count + 1;
 end
 end
 end
 join
 $display("TC1: %s", (err_count == 0) ? "PASS": "FAIL");

 // -------------------------------------------------------------------
 // TC2: First burst after 2 periods
 // -------------------------------------------------------------------
 $display("TC2: first burst after two periods...");
 sync_locked = 1'b1;

 // Period 0 (after lock): cur=slot0/f0, nxt=slot1/f0
 // No output expected (block1_ready not yet set)
 fork
 begin: tc2_p0_drive
 drive_period(0, 0, 1, 0);
 end
 begin: tc2_p0_check
 integer j;
 for (j = 0; j < SYMS_PER_SLOT * STRIDE + 10; j = j + 1) begin
 @(posedge clk_sample);
 if (slot_valid) begin
 $error("TC2: unexpected slot_valid during period 0");
 err_count = err_count + 1;
 end
 end
 end
 join

 // Period 1: cur=slot1/f0, nxt=slot2/f0
 // slot_valid fires for burst of slot1/f0 (slot_cnt=1)
 fork
 begin: tc2_p1_drive
 drive_period(1, 0, 2, 0);
 end
 begin: tc2_p1_check
 expect_burst(1, 0, 1); // slot_cnt=1 after second sync
 end
 join
 $display("TC2: %s", (err_count == 0) ? "PASS": "FAIL (errs so far: %0d)", err_count);

 // -------------------------------------------------------------------
 // TC3: Three consecutive bursts (slot 2, 3, 0 with wrap)
 // -------------------------------------------------------------------
 $display("TC3: consecutive bursts slots 2,3,0...");

 // Period 2: cur=slot2/f0, nxt=slot3/f0 → burst for slot2/f0, slot_cnt=2
 fork
 begin: tc3_p2_drive
 drive_period(2, 0, 3, 0);
 end
 begin: tc3_p2_check
 expect_burst(2, 0, 2);
 end
 join

 // Period 3: cur=slot3/f0, nxt=slot0/f1 → burst for slot3/f0, slot_cnt=3
 fork
 begin: tc3_p3_drive
 drive_period(3, 0, 0, 1);
 end
 begin: tc3_p3_check
 expect_burst(3, 0, 3);
 end
 join

 // Period 4: cur=slot0/f1, nxt=slot1/f1 → burst for slot0/f1, slot_cnt=0 (wrap)
 fork
 begin: tc3_p4_drive
 drive_period(0, 1, 1, 1);
 end
 begin: tc3_p4_check
 expect_burst(0, 1, 0); // slot_cnt wraps to 0
 end
 join
 $display("TC3: %s", (err_count == 0) ? "PASS": "FAIL (errs so far: %0d)", err_count);

 // -------------------------------------------------------------------
 // TC4: Unlock / relock — state resets, resumes after 2 periods
 // -------------------------------------------------------------------
 $display("TC4: unlock and relock...");
 sync_locked = 1'b0;
 repeat(20) @(posedge clk_sample);

 // Drive a period unlocked — no slot_valid
 fork
 begin: tc4_unlocked_drive
 drive_period(1, 1, 2, 1);
 end
 begin: tc4_unlocked_check
 integer k;
 for (k = 0; k < SYMS_PER_SLOT * STRIDE + 10; k = k + 1) begin
 @(posedge clk_sample);
 if (slot_valid) begin
 $error("TC4: slot_valid during unlock");
 err_count = err_count + 1;
 end
 end
 end
 join

 // Relock
 sync_locked = 1'b1;
 repeat(4) @(posedge clk_sample);

 // First period after relock — no output (block1_ready=0 after reset)
 fork
 begin: tc4_relock_p0
 drive_period(2, 1, 3, 1);
 end
 begin: tc4_relock_no_out
 integer m;
 for (m = 0; m < SYMS_PER_SLOT * STRIDE + 10; m = m + 1) begin
 @(posedge clk_sample);
 if (slot_valid) begin
 $error("TC4: unexpected slot_valid after relock (period 0)");
 err_count = err_count + 1;
 end
 end
 end
 join

 // Second period after relock — burst for slot3/f1
 // After relock: slot_cnt resets to 0; first sync → slot_cnt increments to 1,
 // slot_at_sync = slot_cnt+1 = 1. emit at p=123: slot_num_out = 1.
 fork
 begin: tc4_relock_p1
 drive_period(3, 1, 0, 2);
 end
 begin: tc4_relock_check
 expect_burst(3, 1, 1); // slot_at_sync=1 after first post-relock sync (same as TC2)
 end
 join
 $display("TC4: %s", (err_count == 0) ? "PASS": "FAIL (errs so far: %0d)", err_count);

 // -------------------------------------------------------------------
 // Final report
 // -------------------------------------------------------------------
 repeat(20) @(posedge clk_sample);
 if (err_count == 0)
 $display("\n*** ALL TESTS PASSED ***");
 else
 $display("\n*** FAIL — %0d error(s) ***", err_count);

 $finish;
end

// Watchdog
initial begin
 #(SYMS_PER_SLOT * STRIDE * CLK_PERIOD * 40);
 $display("WATCHDOG TIMEOUT");
 $finish;
end

endmodule

`default_nettype wire
