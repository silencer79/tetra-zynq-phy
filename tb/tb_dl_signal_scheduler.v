// =============================================================================
// tb_dl_signal_scheduler.v — Phase Z.13 unit test for tetra_dl_signal_scheduler
//
// The scheduler is now a thin combinational fan-out of queue.head:
// * sched_blk1_tnK / sched_blk2_tnK / sched_ndb2[K] / sched_active[K]
// are combinational from head_*_sys. No bundle latch.
// * pop_sys fires on slot_pulse_sys && (tn_sys == head_target_tn) &&
// head_valid_sys — i.e. on the slot that actually carries the popped
// PDU, NOT one frame ahead at slot_pulse@tn==3.
//
// Coverage:
// T1 reset → sched_ndb2 = 4'b1111 idle (head_valid=0, all defaults)
// T2 head valid for TN=1 SCH/F → blocks visible on TN=1 immediately
// (combinational); other TNs hold idle defaults
// T3 pop fires only on slot_pulse@target_tn (TN=1 here), not on TN=0/2/3
// T4 SCH/HD → blk2 falls back to sig_companion
// T5 head_valid drops → all TNs revert to idle the same cycle
// T6 stats counters advance on each pop
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_signal_scheduler;

 // -------------------------------------------------------------------------
 // DUT signals
 // -------------------------------------------------------------------------
 reg clk = 1'b0;
 reg rst_n = 1'b0;
 reg [1:0] tn_sys = 2'd0;
 reg slot_pulse_sys = 1'b0;
 reg head_valid_sys = 1'b0;
 reg [431:0] head_coded_sys = 432'd0;
 reg [1:0] head_pdu_type_sys = 2'd0;
 reg [1:0] head_target_tn_sys = 2'd0;
 reg [1:0] head_prio_sys = 2'd0;
 reg [215:0] null_pdu_bits_sys;
 reg [215:0] sig_companion_sys;

 wire pop_sys;
 wire [215:0] sched_blk1_tn0_sys, sched_blk2_tn0_sys;
 wire [215:0] sched_blk1_tn1_sys, sched_blk2_tn1_sys;
 wire [215:0] sched_blk1_tn2_sys, sched_blk2_tn2_sys;
 wire [215:0] sched_blk1_tn3_sys, sched_blk2_tn3_sys;
 wire [3:0] sched_ndb2_sys;
 wire [3:0] sched_active_sys;
 wire [15:0] override_cnt_sys;
 wire [15:0] pop_cnt_sys;

 integer errors = 0;
 integer pop_observed = 0;

 always #5 clk = ~clk;

 tetra_dl_signal_scheduler dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.tn_sys (tn_sys),
.slot_pulse_sys (slot_pulse_sys),
.pop_sys (pop_sys),
.head_valid_sys (head_valid_sys),
.head_coded_sys (head_coded_sys),
.head_pdu_type_sys (head_pdu_type_sys),
.head_target_tn_sys (head_target_tn_sys),
.head_prio_sys (head_prio_sys),
.head_second_pdu_present_sys (1'b0),
.head_second_pdu_nr_sys (1'b0),
.popped_second_pdu_present_sys (),
.popped_second_pdu_nr_sys (),
.null_pdu_bits_sys (null_pdu_bits_sys),
.sig_companion_sys (sig_companion_sys),
.sched_blk1_tn0_sys (sched_blk1_tn0_sys),
.sched_blk2_tn0_sys (sched_blk2_tn0_sys),
.sched_blk1_tn1_sys (sched_blk1_tn1_sys),
.sched_blk2_tn1_sys (sched_blk2_tn1_sys),
.sched_blk1_tn2_sys (sched_blk1_tn2_sys),
.sched_blk2_tn2_sys (sched_blk2_tn2_sys),
.sched_blk1_tn3_sys (sched_blk1_tn3_sys),
.sched_blk2_tn3_sys (sched_blk2_tn3_sys),
.sched_ndb2_sys (sched_ndb2_sys),
.sched_active_sys (sched_active_sys),
.override_cnt_sys (override_cnt_sys),
.pop_cnt_sys (pop_cnt_sys)
 );

 always @(posedge clk) begin
 if (pop_sys) pop_observed <= pop_observed + 1;
 end

 // -------------------------------------------------------------------------
 // Helpers
 // -------------------------------------------------------------------------
 task automatic tick_slot(input [1:0] new_tn);
 begin
 @(negedge clk);
 tn_sys = new_tn;
 slot_pulse_sys = 1'b1;
 @(posedge clk);
 @(negedge clk);
 slot_pulse_sys = 1'b0;
 end
 endtask

 task automatic check_eq_int(input [31:0] got, input [31:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s: got=%0d exp=%0d", msg, got, exp);
 errors = errors + 1;
 end
 end
 endtask

 task automatic check_eq_h(input [215:0] got, input [215:0] exp,
 input [511:0] msg);
 begin
 if (got !== exp) begin
 $display(" FAIL %0s: got[31:0]=%h exp[31:0]=%h",
 msg, got[31:0], exp[31:0]);
 errors = errors + 1;
 end
 end
 endtask

 // Check all non-target TNs carry the NULL-PDU idle default.
 task automatic check_idle_except(input [1:0] target_tn, input [511:0] tag);
 begin
 if (target_tn !== 2'd0) begin
 check_eq_h(sched_blk1_tn0_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn0"});
 check_eq_h(sched_blk2_tn0_sys, sig_companion_sys, {tag,".idle_blk2_tn0"});
 check_eq_int({31'd0, sched_ndb2_sys[0]}, 1'b1, {tag,".idle_ndb2_tn0"});
 end
 if (target_tn !== 2'd1) begin
 check_eq_h(sched_blk1_tn1_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn1"});
 check_eq_h(sched_blk2_tn1_sys, sig_companion_sys, {tag,".idle_blk2_tn1"});
 check_eq_int({31'd0, sched_ndb2_sys[1]}, 1'b1, {tag,".idle_ndb2_tn1"});
 end
 if (target_tn !== 2'd2) begin
 check_eq_h(sched_blk1_tn2_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn2"});
 check_eq_h(sched_blk2_tn2_sys, sig_companion_sys, {tag,".idle_blk2_tn2"});
 check_eq_int({31'd0, sched_ndb2_sys[2]}, 1'b1, {tag,".idle_ndb2_tn2"});
 end
 if (target_tn !== 2'd3) begin
 check_eq_h(sched_blk1_tn3_sys, null_pdu_bits_sys, {tag,".idle_blk1_tn3"});
 check_eq_h(sched_blk2_tn3_sys, sig_companion_sys, {tag,".idle_blk2_tn3"});
 check_eq_int({31'd0, sched_ndb2_sys[3]}, 1'b1, {tag,".idle_ndb2_tn3"});
 end
 end
 endtask

 // -------------------------------------------------------------------------
 // Main
 // -------------------------------------------------------------------------
 initial begin
 $display("[tb_dl_signal_scheduler] start");

 // Distinctive 216-bit patterns — byte-repeat to fill exactly 216 bits.
 null_pdu_bits_sys = {27{8'hDE}};
 sig_companion_sys = {27{8'hCA}};

 repeat (4) @(posedge clk);
 @(negedge clk);
 rst_n = 1'b1;

 // -----------------------------------------------------------------
 // T1 — reset/idle: head_valid=0 → all TNs idle, ndb2=4'b1111
 // -----------------------------------------------------------------
 @(negedge clk);
 head_valid_sys = 1'b0;
 @(negedge clk);
 check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T1.ndb2_all_idle");
 check_eq_int({28'd0, sched_active_sys}, 4'b0000, "T1.active_zero");
 check_idle_except(2'd0, "T1");
 // explicit re-check of TN0 too
 check_eq_h(sched_blk1_tn0_sys, null_pdu_bits_sys, "T1.blk1_tn0_idle");
 check_eq_h(sched_blk2_tn0_sys, sig_companion_sys, "T1.blk2_tn0_idle");

 // -----------------------------------------------------------------
 // T2 — head valid for TN=1 SCH/F → TN=1 carries content immediately
 // (combinational, no clock needed)
 // -----------------------------------------------------------------
 head_valid_sys = 1'b1;
 head_coded_sys = {{27{8'hA5}}, {27{8'h5A}}};
 head_pdu_type_sys = 2'd0; // SCH_F
 head_target_tn_sys = 2'd1;
 @(negedge clk);
 check_eq_h(sched_blk1_tn1_sys, head_coded_sys[431:216], "T2.tgt_blk1");
 check_eq_h(sched_blk2_tn1_sys, head_coded_sys[215:0], "T2.tgt_blk2");
 check_eq_int({31'd0, sched_ndb2_sys[1]}, 1'b0, "T2.tgt_ndb2_nts1");
 check_eq_int({28'd0, sched_active_sys}, 4'b0010, "T2.active_only_tn1");
 check_idle_except(2'd1, "T2");

 // -----------------------------------------------------------------
 // T3 — pop fires only on slot_pulse@tn==target_tn (=1 here),
 // never on tn=0/2/3
 // -----------------------------------------------------------------
 pop_observed = 0;
 tick_slot(2'd0);
 check_eq_int(pop_observed, 0, "T3.no_pop_tn0");
 tick_slot(2'd2);
 check_eq_int(pop_observed, 0, "T3.no_pop_tn2");
 tick_slot(2'd3);
 check_eq_int(pop_observed, 0, "T3.no_pop_tn3");
 tick_slot(2'd1);
 @(posedge clk);
 @(negedge clk);
 check_eq_int(pop_observed, 1, "T3.pop_on_target_tn1");

 // -----------------------------------------------------------------
 // T4 — SCH/HD: blk2 falls back to sig_companion, ndb2=1
 // -----------------------------------------------------------------
 head_coded_sys = {{27{8'h3C}}, {27{8'h00}}};
 head_pdu_type_sys = 2'd1; // SCH_HD
 head_target_tn_sys = 2'd2;
 @(negedge clk);
 check_eq_h(sched_blk1_tn2_sys, head_coded_sys[431:216], "T4.tgt_blk1");
 check_eq_h(sched_blk2_tn2_sys, sig_companion_sys, "T4.tgt_blk2_companion");
 check_eq_int({31'd0, sched_ndb2_sys[2]}, 1'b1, "T4.tgt_ndb2_nts2");
 check_eq_int({28'd0, sched_active_sys}, 4'b0100, "T4.active_only_tn2");
 check_idle_except(2'd2, "T4");
 // pop on slot_pulse@tn=2
 pop_observed = 0;
 tick_slot(2'd2);
 @(posedge clk);
 @(negedge clk);
 check_eq_int(pop_observed, 1, "T4.pop_on_target_tn2");

 // -----------------------------------------------------------------
 // T5 — head_valid drops → all TNs revert to idle the same cycle
 // -----------------------------------------------------------------
 head_valid_sys = 1'b0;
 @(negedge clk);
 check_eq_int({28'd0, sched_ndb2_sys}, 4'b1111, "T5.ndb2_all_idle_after_drop");
 check_eq_int({28'd0, sched_active_sys}, 4'b0000, "T5.active_zero");
 check_eq_h(sched_blk1_tn1_sys, null_pdu_bits_sys, "T5.tn1_reverted");
 check_eq_h(sched_blk1_tn2_sys, null_pdu_bits_sys, "T5.tn2_reverted");

 // -----------------------------------------------------------------
 // T6 — stats counters: 2 pops so far (T3 + T4)
 // -----------------------------------------------------------------
 check_eq_int({16'd0, pop_cnt_sys}, 16'd2, "T6.pop_cnt");
 check_eq_int({16'd0, override_cnt_sys}, 16'd2, "T6.override_cnt");

 if (errors == 0)
 $display("[tb_dl_signal_scheduler] PASS");
 else
 $display("[tb_dl_signal_scheduler] FAIL — %0d errors", errors);
 $finish;
 end

 initial begin
 #200000;
 $display("[tb_dl_signal_scheduler] WATCHDOG timeout");
 $fatal;
 end

endmodule

`default_nettype wire
