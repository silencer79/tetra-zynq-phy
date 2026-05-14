// =============================================================================
// tb_burst_dispatcher.v — Phase Y.3 self-checking TB
//
// DUT: tetra_burst_dispatcher
//
// Coverage:
// T1 STATIC NDB on TN=0..3 — bodies come from ndb_block*_sw_sys, burst_type=0,
// ndb2 = entry's ndb2 bit.
// T2 STATIC SB on TN=0 — burst_type=1, blk2 = sb_bkn2_sw_sys, blk1=0,
// sb1 = sb_sb1_in_sys, ndb2 = entry's ndb2 bit.
// T3 SIGNALLING (queue head) on TN=2 — body = sched_blk1/blk2_tn2_sys,
// burst_type follows entry (NDB), ndb2 = sched_ndb2_sys[2].
// T4 sched_active dynamic-class lift on TN=1 (entry says STATIC NDB but
// sched_active_sys[1]==1) — body comes from sched_blk*_tn1_sys, NOT
// from SW banks.
// T5 build_req_sys is exactly a 1-cycle pulse aligned to slot_pulse + 1.
// T6 Disabled slot (entry.enable=0) — bodies zeroed even though static
// lookup would point at NDB SYSINFO.
// T7 BB/AACH input always lands in build_bb_sys (broadcast on every slot).
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module tb_burst_dispatcher;

 localparam integer BLOCK_BITS = 216;
 localparam integer BB_BITS = 30;
 localparam integer SB1_BITS = 120;

 reg clk = 1'b0;
 reg rst_n = 1'b0;
 always #5 clk = ~clk;

 integer errors = 0;

 // -------------------------------------------------------------------------
 // DUT inputs
 // -------------------------------------------------------------------------
 reg tx_slot_pulse;
 reg [1:0] tx_slot_num;

 reg [BLOCK_BITS-1:0] sched_blk1_tn0, sched_blk2_tn0;
 reg [BLOCK_BITS-1:0] sched_blk1_tn1, sched_blk2_tn1;
 reg [BLOCK_BITS-1:0] sched_blk1_tn2, sched_blk2_tn2;
 reg [BLOCK_BITS-1:0] sched_blk1_tn3, sched_blk2_tn3;
 reg [3:0] sched_active;
 reg [3:0] sched_ndb2;

 reg [15:0] ent0, ent1, ent2, ent3;

 reg [BLOCK_BITS-1:0] ndb1_sw, ndb2_sw;
 reg [BLOCK_BITS-1:0] mcch1_sw, mcch2_sw;
 reg [BLOCK_BITS-1:0] bnch1_sw, bnch2_sw;
 reg [BLOCK_BITS-1:0] sb_bkn2_sw;

 reg [BB_BITS-1:0] bb_in;
 reg [SB1_BITS-1:0] sb_sb1_in;

 // -------------------------------------------------------------------------
 // DUT outputs
 // -------------------------------------------------------------------------
 wire [BLOCK_BITS-1:0] build_block1, build_block2;
 wire [BB_BITS-1:0] build_bb;
 wire [SB1_BITS-1:0] build_sb1;
 wire build_burst_type;
 wire build_ndb2;
 wire build_req;

 // -------------------------------------------------------------------------
 // DUT
 // -------------------------------------------------------------------------
 tetra_burst_dispatcher #(
.BLOCK_BITS(BLOCK_BITS),
.BB_BITS (BB_BITS),
.SB1_BITS (SB1_BITS)
 ) u_dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.tx_slot_pulse_sys (tx_slot_pulse),
.tx_slot_num_sys (tx_slot_num),
.sched_blk1_tn0_sys (sched_blk1_tn0),
.sched_blk2_tn0_sys (sched_blk2_tn0),
.sched_blk1_tn1_sys (sched_blk1_tn1),
.sched_blk2_tn1_sys (sched_blk2_tn1),
.sched_blk1_tn2_sys (sched_blk1_tn2),
.sched_blk2_tn2_sys (sched_blk2_tn2),
.sched_blk1_tn3_sys (sched_blk1_tn3),
.sched_blk2_tn3_sys (sched_blk2_tn3),
.sched_active_sys (sched_active),
.sched_ndb2_sys (sched_ndb2),
.sched_entry_reg_sys0 (ent0),
.sched_entry_reg_sys1 (ent1),
.sched_entry_reg_sys2 (ent2),
.sched_entry_reg_sys3 (ent3),
.ndb_block1_sw_sys (ndb1_sw),
.ndb_block2_sw_sys (ndb2_sw),
.mcch_block1_sw_sys (mcch1_sw),
.mcch_block2_sw_sys (mcch2_sw),
.bnch_block1_sw_sys (bnch1_sw),
.bnch_block2_sw_sys (bnch2_sw),
.sb_bkn2_sw_sys (sb_bkn2_sw),
.bb_in_sys (bb_in),
.sb_sb1_in_sys (sb_sb1_in),
.tx_busy_sys (1'b0),
.build_block1_sys (build_block1),
.build_block2_sys (build_block2),
.build_bb_sys (build_bb),
.build_sb1_sys (build_sb1),
.build_burst_type_sys (build_burst_type),
.build_ndb2_sys (build_ndb2),
.build_req_sys (build_req)
 );

 // -------------------------------------------------------------------------
 // Helpers
 // -------------------------------------------------------------------------
 function [15:0] pack_entry;
 input [3:0] cls;
 input [5:0] idx;
 input [1:0] bt;
 input ndb2_b;
 input en;
 begin
 // [15:12]=class [11:6]=idx [5:4]=burst-type [3]=ndb2 [2]=en [1:0]=rsv
 pack_entry = {cls, idx, bt, ndb2_b, en, 2'b00};
 end
 endfunction

 task automatic pulse_slot(input [1:0] slot_n);
 begin
 @(negedge clk);
 tx_slot_num = slot_n;
 tx_slot_pulse = 1'b1;
 @(posedge clk);
 @(negedge clk);
 tx_slot_pulse = 1'b0;
 // Allow build_req register to settle
 @(posedge clk); #1;
 end
 endtask

 task automatic check_eq_int(input [31:0] got, input [31:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s: got=%0h exp=%0h", msg, got, exp);
 errors = errors + 1;
 end else begin
 $display(" PASS %0s = 0x%0h", msg, got);
 end
 end
 endtask

 task automatic check_eq_blk(input [BLOCK_BITS-1:0] got,
 input [BLOCK_BITS-1:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s:\n got[31:0]=%h exp[31:0]=%h",
 msg, got[31:0], exp[31:0]);
 errors = errors + 1;
 end else begin
 $display(" PASS %0s [31:0]=%h", msg, got[31:0]);
 end
 end
 endtask

 task automatic check_eq_bb(input [BB_BITS-1:0] got,
 input [BB_BITS-1:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s: got=%0h exp=%0h", msg, got, exp);
 errors = errors + 1;
 end else begin
 $display(" PASS %0s = %0h", msg, got);
 end
 end
 endtask

 task automatic check_eq_sb1(input [SB1_BITS-1:0] got,
 input [SB1_BITS-1:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s: got[31:0]=%h exp[31:0]=%h",
 msg, got[31:0], exp[31:0]);
 errors = errors + 1;
 end else begin
 $display(" PASS %0s [31:0]=%h", msg, got[31:0]);
 end
 end
 endtask

 // -------------------------------------------------------------------------
 // Stimulus
 // -------------------------------------------------------------------------
 initial begin
 $dumpfile("sim_out/tb_burst_dispatcher.vcd");
 $dumpvars(0, tb_burst_dispatcher);

 // -- init regs --
 rst_n = 1'b0;
 tx_slot_pulse = 1'b0;
 tx_slot_num = 2'd0;
 sched_blk1_tn0 = {27{8'h11}};
 sched_blk2_tn0 = {27{8'h12}};
 sched_blk1_tn1 = {27{8'h21}};
 sched_blk2_tn1 = {27{8'h22}};
 sched_blk1_tn2 = {27{8'h31}};
 sched_blk2_tn2 = {27{8'h32}};
 sched_blk1_tn3 = {27{8'h41}};
 sched_blk2_tn3 = {27{8'h42}};
 sched_active = 4'b0000;
 sched_ndb2 = 4'b0000;
 ent0 = 16'h0000;
 ent1 = 16'h0000;
 ent2 = 16'h0000;
 ent3 = 16'h0000;
 ndb1_sw = {27{8'hA1}};
 ndb2_sw = {27{8'hA2}};
 mcch1_sw = {27{8'hC1}};
 mcch2_sw = {27{8'hC2}};
 bnch1_sw = {27{8'hB1}};
 bnch2_sw = {27{8'hB2}};
 sb_bkn2_sw = {27{8'hDB}};
 bb_in = 30'h2AAAAAAA;
 sb_sb1_in = {15{8'hAB}};

 repeat (4) @(posedge clk);
 @(negedge clk);
 rst_n = 1'b1;
 repeat (2) @(posedge clk);

 // -----------------------------------------------------------------
 // T1 — STATIC NDB (idx=0, ndb2=1, enable=1) on each TN.
 // Body = ndb_block*_sw_sys, burst_type=0, ndb2=1.
 // -----------------------------------------------------------------
 $display("=== T1: STATIC NDB on TN=0..3 ===");
 ent0 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1);
 ent1 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1);
 ent2 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1);
 ent3 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1);
 sched_active = 4'b0000;

 pulse_slot(2'd0);
 check_eq_blk(build_block1, ndb1_sw, "T1.tn0_blk1");
 check_eq_blk(build_block2, ndb2_sw, "T1.tn0_blk2");
 check_eq_int({31'd0, build_burst_type}, 32'd0, "T1.tn0_burst_type");
 check_eq_int({31'd0, build_ndb2}, 32'd1, "T1.tn0_ndb2");

 pulse_slot(2'd1);
 check_eq_blk(build_block1, ndb1_sw, "T1.tn1_blk1");
 check_eq_blk(build_block2, ndb2_sw, "T1.tn1_blk2");

 pulse_slot(2'd2);
 check_eq_blk(build_block1, ndb1_sw, "T1.tn2_blk1");
 check_eq_blk(build_block2, ndb2_sw, "T1.tn2_blk2");

 pulse_slot(2'd3);
 check_eq_blk(build_block1, ndb1_sw, "T1.tn3_blk1");
 check_eq_blk(build_block2, ndb2_sw, "T1.tn3_blk2");

 // -----------------------------------------------------------------
 // T2 — STATIC SB (idx=3, burst_type=01=SDB, ndb2=0, enable=1) on TN=0.
 // -----------------------------------------------------------------
 $display("=== T2: STATIC SB on TN=0 ===");
 ent0 = pack_entry(4'd0, 6'd3, 2'b01, 1'b0, 1'b1);
 pulse_slot(2'd0);
 check_eq_blk(build_block1, {BLOCK_BITS{1'b0}}, "T2.tn0_blk1_zero");
 check_eq_blk(build_block2, sb_bkn2_sw, "T2.tn0_blk2_bkn2");
 check_eq_int({31'd0, build_burst_type}, 32'd1, "T2.tn0_burst_type_sdb");
 check_eq_int({31'd0, build_ndb2}, 32'd0, "T2.tn0_ndb2");
 check_eq_sb1(build_sb1, sb_sb1_in, "T2.tn0_sb1");

 // -----------------------------------------------------------------
 // T3 — SIGNALLING (class=1) on TN=2 — body comes from
 // sched_blk*_tn2_sys, ndb2 from sched_ndb2_sys[2].
 // -----------------------------------------------------------------
 $display("=== T3: SIGNALLING class on TN=2 ===");
 ent2 = pack_entry(4'd1, 6'd0, 2'b00, 1'b0, 1'b1);
 sched_active = 4'b0000; // class=1 alone is enough
 sched_ndb2 = 4'b0000;
 pulse_slot(2'd2);
 check_eq_blk(build_block1, sched_blk1_tn2, "T3.tn2_blk1_sched");
 check_eq_blk(build_block2, sched_blk2_tn2, "T3.tn2_blk2_sched");
 check_eq_int({31'd0, build_burst_type}, 32'd0, "T3.tn2_burst_type_ndb");
 check_eq_int({31'd0, build_ndb2}, 32'd0, "T3.tn2_ndb2_zero");

 // -----------------------------------------------------------------
 // T4 — Dynamic-class lift via sched_active. Schedule says STATIC
 // NDB on TN=1 but sched_active_sys[1]==1 ⇒ scheduler bundle wins.
 // -----------------------------------------------------------------
 $display("=== T4: sched_active dynamic-class lift on TN=1 ===");
 ent1 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1); // STATIC NDB
 sched_active = 4'b0010;
 sched_ndb2 = 4'b0000; // SCH/F → ndb2=0
 pulse_slot(2'd1);
 check_eq_blk(build_block1, sched_blk1_tn1, "T4.tn1_blk1_lifted");
 check_eq_blk(build_block2, sched_blk2_tn1, "T4.tn1_blk2_lifted");
 check_eq_int({31'd0, build_ndb2}, 32'd0, "T4.tn1_ndb2_lifted");

 // -----------------------------------------------------------------
 // T5 — build_req is exactly 1 cycle wide, aligned to slot_pulse + 1.
 // -----------------------------------------------------------------
 $display("=== T5: build_req 1-cycle pulse ===");
 sched_active = 4'b0000;
 // Drive a slot_pulse and sample build_req across multiple cycles.
 @(negedge clk);
 tx_slot_num = 2'd0;
 tx_slot_pulse = 1'b1;
 check_eq_int({31'd0, build_req}, 32'd0, "T5.req_low_pre_pulse");
 @(posedge clk); #1; // T+0 — req latched HIGH
 check_eq_int({31'd0, build_req}, 32'd1, "T5.req_high_at_T+1");
 @(negedge clk);
 tx_slot_pulse = 1'b0;
 @(posedge clk); #1; // T+1 — req should clear
 check_eq_int({31'd0, build_req}, 32'd0, "T5.req_low_at_T+2");
 @(posedge clk); #1;
 check_eq_int({31'd0, build_req}, 32'd0, "T5.req_still_low");

 // -----------------------------------------------------------------
 // T6 — Disabled slot — entry.enable=0 ⇒ bodies zeroed regardless
 // of class/idx.
 // -----------------------------------------------------------------
 $display("=== T6: disabled slot ===");
 ent3 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b0); // enable=0
 sched_active = 4'b0000;
 pulse_slot(2'd3);
 check_eq_blk(build_block1, {BLOCK_BITS{1'b0}}, "T6.tn3_blk1_zero");
 check_eq_blk(build_block2, {BLOCK_BITS{1'b0}}, "T6.tn3_blk2_zero");
 check_eq_sb1(build_sb1, {SB1_BITS{1'b0}}, "T6.tn3_sb1_zero");

 // -----------------------------------------------------------------
 // T7 — BB/AACH always lands in build_bb_sys (every slot, regardless
 // of class/burst-type). Update bb_in and verify on next pulse.
 // -----------------------------------------------------------------
 $display("=== T7: bb_in broadcast ===");
 ent0 = pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1);
 bb_in = 30'h15555555;
 pulse_slot(2'd0);
 check_eq_bb(build_bb, 30'h15555555, "T7.bb_broadcast");

 // -----------------------------------------------------------------
 if (errors == 0) begin
 $display("=============================================");
 $display("tb_burst_dispatcher: ALL CASES PASS");
 $display("=============================================");
 end else begin
 $display("=============================================");
 $display("tb_burst_dispatcher: %0d FAILURE(S)", errors);
 $display("=============================================");
 $stop;
 end
 $finish;
 end

 initial begin
 #200_000;
 $display("[tb_burst_dispatcher] WATCHDOG timeout");
 $fatal;
 end

endmodule

`default_nettype wire
