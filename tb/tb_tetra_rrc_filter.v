// =============================================================================
// tb_tetra_rrc_filter.v — Self-checking testbench for tetra_rrc_filter.v
// =============================================================================
// Verifies TX RRC polyphase interpolation filter (L=4, 33 taps, α=0.35).
// Reference vectors from tb/vectors/gen_rrc_filter_vectors.py.
//
// Symbol shift register is reset (zeroed) before each test case.
//
// Test cases:
// TC1: Single I-impulse (32767) — verify 4 output samples (phases 0..3)
// TC2: Two identical symbols — verify 8 outputs
// TC3: Pure Q impulse — verify I=0, Q channel correct
// TC4: Reset mid-MAC, clean restart
// TC5: All-zero input — all outputs zero
// TC6: Timing — exactly 4 valid pulses per symbol
//
// Expected output values (Q14 arithmetic, SR zeroed before each symbol):
// Single impulse I=32767, Q=0:
// ph=0: I= 33 (h[0]*32767>>14 = 17*32767>>14)
// ph=1: I= 217 (h[1]*32767>>14 = 109*32767>>14)
// ph=2: I= 155 (h[2]*32767>>14 = 78*32767>>14)
// ph=3: I=-156 (h[3]*32767>>14 = -78*32767>>14)
// Second symbol I=32767 (SR=[32767,32767,0,...]):
// ph=0: I=-384 ((17-209)*32767>>14)
// ph=1: I= -24 ((109-121)*32767>>14)
// ph=2: I= 575 ((78+210)*32767>>14)
// ph=3: I= 913 ((-78+535)*32767>>14)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_rrc_filter;

 // -------------------------------------------------------------------------
 // DUT signals
 // -------------------------------------------------------------------------
 reg clk_sys;
 reg rst_n_sys;
 reg signed [15:0] i_in;
 reg signed [15:0] q_in;
 reg sample_valid_in;
 wire signed [15:0] i_out;
 wire signed [15:0] q_out;
 wire sample_valid_out;

 // -------------------------------------------------------------------------
 // DUT instantiation
 // -------------------------------------------------------------------------
 tetra_rrc_filter #(
.IQ_WIDTH (16),
.RRC_ACC_SHIFT (14)
 ) u_dut (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.i_in (i_in),
.q_in (q_in),
.sample_valid_in (sample_valid_in),
.i_out (i_out),
.q_out (q_out),
.sample_valid_out(sample_valid_out)
 );

 // -------------------------------------------------------------------------
 // Clock: 10 ns period (100 MHz)
 // -------------------------------------------------------------------------
 initial clk_sys = 0;
 always #5 clk_sys = ~clk_sys;

 // -------------------------------------------------------------------------
 // Test infrastructure
 // -------------------------------------------------------------------------
 integer pass_cnt;
 integer fail_cnt;

 // VCD dump
 initial begin
 $dumpfile("sim_out/sim_rrc_filter.vcd");
 $dumpvars(0, tb_tetra_rrc_filter);
 end

 // Timeout guard: 50000 ns
 initial begin
 #50000;
 $display("FATAL: testbench timeout");
 $finish;
 end

 // -------------------------------------------------------------------------
 // do_reset task — assert reset to zero SR and return to IDLE
 // -------------------------------------------------------------------------
 task do_reset;
 begin
 @(negedge clk_sys);
 rst_n_sys = 1'b0;
 sample_valid_in = 1'b0;
 repeat (4) @(posedge clk_sys);
 @(negedge clk_sys);
 rst_n_sys = 1'b1;
 repeat (2) @(posedge clk_sys);
 end
 endtask

 // -------------------------------------------------------------------------
 // apply_sample task — drive inputs, pulse sample_valid_in for 1 cycle
 // -------------------------------------------------------------------------
 task apply_sample;
 input signed [15:0] ii;
 input signed [15:0] qi;
 begin
 @(negedge clk_sys);
 i_in = ii;
 q_in = qi;
 sample_valid_in = 1'b1;
 @(negedge clk_sys);
 sample_valid_in = 1'b0;
 end
 endtask

 // -------------------------------------------------------------------------
 // check_output task — wait for sample_valid_out pulse, check i_out / q_out
 // -------------------------------------------------------------------------
 task check_output;
 input signed [15:0] exp_i;
 input signed [15:0] exp_q;
 input [127:0] label;
 begin
 @(posedge sample_valid_out);
 #1; // settle after edge
 if (i_out === exp_i && q_out === exp_q) begin
 $display("PASS [%0s]: I=%0d Q=%0d", label, i_out, q_out);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display("FAIL [%0s]: got I=%0d Q=%0d, exp I=%0d Q=%0d",
 label, i_out, q_out, exp_i, exp_q);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 // =========================================================================
 // Main test sequence
 // =========================================================================
 initial begin
 pass_cnt = 0;
 fail_cnt = 0;

 // Initial reset
 rst_n_sys = 1'b0;
 i_in = 16'sd0;
 q_in = 16'sd0;
 sample_valid_in = 1'b0;
 repeat (6) @(posedge clk_sys);
 rst_n_sys = 1'b1;
 repeat (2) @(posedge clk_sys);

 // =====================================================================
 // TC1: Single I-impulse — 4 output samples (phases 0..3)
 // SR=[0..0] before; SR=[32767,0..0] during MAC
 // Expected: 33, 217, 155, -156 (I); 0 (Q)
 // =====================================================================
 $display("# TC1: Single I-impulse (I=32767, Q=0, SR=0)");

 fork
 begin
 apply_sample(16'sd32767, 16'sd0);
 end
 begin
 check_output(16'sd33, 16'sd0, "TC1_ph0");
 check_output(16'sd217, 16'sd0, "TC1_ph1");
 check_output(16'sd155, 16'sd0, "TC1_ph2");
 check_output(-16'sd156, 16'sd0, "TC1_ph3");
 end
 join

 // Wait for FSM to return to IDLE (36 MAC cycles + margin)
 repeat (20) @(posedge clk_sys);

 // =====================================================================
 // TC2: Two identical symbols — 8 output samples
 // After reset: sym1 SR=[32767,0..0], sym2 SR=[32767,32767,0..0]
 // Sym1 outputs: 33, 217, 155, -156 (same as TC1)
 // Sym2 outputs: -384, -24, 575, 913
 // =====================================================================
 $display("# TC2: Two identical I symbols (32767 then 32767)");

 do_reset;

 fork
 begin
 // Apply first symbol; wait for its MAC to complete, then second
 apply_sample(16'sd32767, 16'sd0);
 // MAC takes 36 cycles; wait 50 to be safe before second symbol
 repeat (50) @(posedge clk_sys);
 apply_sample(16'sd32767, 16'sd0);
 end
 begin
 // Sym1 phase 0..3
 check_output(16'sd33, 16'sd0, "TC2_s0_ph0");
 check_output(16'sd217, 16'sd0, "TC2_s0_ph1");
 check_output(16'sd155, 16'sd0, "TC2_s0_ph2");
 check_output(-16'sd156, 16'sd0, "TC2_s0_ph3");
 // Sym2 phase 0..3 (SR=[32767, 32767, 0...])
 // ph0: (h[0]+h[4])*32767>>14 = (17-209)*32767>>14 = -192*32767>>14 = -384
 // ph1: (h[1]+h[5])*32767>>14 = (109-121)*32767>>14 = -12*32767>>14 = -24
 // ph2: (h[2]+h[6])*32767>>14 = (78+210)*32767>>14 = 288*32767>>14 = 575
 // ph3: (h[3]+h[7])*32767>>14 = (-78+535)*32767>>14 = 457*32767>>14 = 913
 check_output(-16'sd384, 16'sd0, "TC2_s1_ph0");
 check_output(-16'sd24, 16'sd0, "TC2_s1_ph1");
 check_output(16'sd575, 16'sd0, "TC2_s1_ph2");
 check_output(16'sd913, 16'sd0, "TC2_s1_ph3");
 end
 join

 repeat (20) @(posedge clk_sys);

 // =====================================================================
 // TC3: Pure Q impulse — I must be 0; Q outputs match TC1 pattern
 // SR=[0..0]; Q=32767 → same subfilter applied to Q channel
 // Q outputs: ph0=33 ph1=217 ph2=155 ph3=-156; I=0 throughout
 // =====================================================================
 $display("# TC3: Single Q-impulse (I=0, Q=32767, SR=0)");

 do_reset;

 fork
 begin
 apply_sample(16'sd0, 16'sd32767);
 end
 begin
 check_output(16'sd0, 16'sd33, "TC3_ph0");
 check_output(16'sd0, 16'sd217, "TC3_ph1");
 check_output(16'sd0, 16'sd155, "TC3_ph2");
 check_output(16'sd0, -16'sd156, "TC3_ph3");
 end
 join

 repeat (20) @(posedge clk_sys);

 // =====================================================================
 // TC4: Reset mid-MAC — MAC aborts; restart produces correct output
 // =====================================================================
 $display("# TC4: Reset mid-MAC, clean restart");

 do_reset;

 // Start a symbol
 @(negedge clk_sys);
 i_in = 16'sd32767;
 q_in = 16'sd0;
 sample_valid_in = 1'b1;
 @(negedge clk_sys);
 sample_valid_in = 1'b0;

 // Let MAC run for a few cycles then reset
 repeat (5) @(posedge clk_sys);
 @(negedge clk_sys);
 rst_n_sys = 1'b0;
 repeat (4) @(posedge clk_sys);
 @(negedge clk_sys);
 rst_n_sys = 1'b1;
 repeat (2) @(posedge clk_sys);

 // After reset, sample_valid_out must not be high for a while
 begin: tc4_no_spurious
 integer spurious;
 spurious = 0;
 repeat (10) begin
 @(posedge clk_sys);
 if (sample_valid_out === 1'b1) spurious = spurious + 1;
 end
 if (spurious === 0) begin
 $display("PASS [TC4_no_spurious]: no valid after reset");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display("FAIL [TC4_no_spurious]: %0d spurious valid pulses", spurious);
 fail_cnt = fail_cnt + 1;
 end
 end

 // Now apply a clean impulse — should give same as TC1
 fork
 begin
 apply_sample(16'sd32767, 16'sd0);
 end
 begin
 check_output(16'sd33, 16'sd0, "TC4_restart_ph0");
 check_output(16'sd217, 16'sd0, "TC4_restart_ph1");
 check_output(16'sd155, 16'sd0, "TC4_restart_ph2");
 check_output(-16'sd156, 16'sd0, "TC4_restart_ph3");
 end
 join

 repeat (20) @(posedge clk_sys);

 // =====================================================================
 // TC5: All-zero input — all outputs must be 0
 // =====================================================================
 $display("# TC5: All-zero input");

 do_reset;

 fork
 begin
 apply_sample(16'sd0, 16'sd0);
 end
 begin
 check_output(16'sd0, 16'sd0, "TC5_ph0");
 check_output(16'sd0, 16'sd0, "TC5_ph1");
 check_output(16'sd0, 16'sd0, "TC5_ph2");
 check_output(16'sd0, 16'sd0, "TC5_ph3");
 end
 join

 repeat (20) @(posedge clk_sys);

 // =====================================================================
 // TC6: Timing — exactly 4 valid pulses per input symbol over 100 cycles
 // =====================================================================
 $display("# TC6: Timing — 4 valid pulses per symbol");

 do_reset;

 begin: tc6_count
 integer valid_cnt;
 valid_cnt = 0;
 @(negedge clk_sys);
 i_in = 16'sd32767;
 q_in = 16'sd0;
 sample_valid_in = 1'b1;
 @(negedge clk_sys);
 sample_valid_in = 1'b0;
 repeat (100) begin
 @(posedge clk_sys);
 if (sample_valid_out === 1'b1)
 valid_cnt = valid_cnt + 1;
 end
 if (valid_cnt === 4) begin
 $display("PASS [TC6_valid_count]: 4 valid pulses in 100 cycles");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display("FAIL [TC6_valid_count]: got %0d valid pulses, expected 4",
 valid_cnt);
 fail_cnt = fail_cnt + 1;
 end
 end

 // =====================================================================
 // Final result
 // =====================================================================
 $display("");
 $display("========================================");
 $display("TETRA RRC Filter: PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
 if (fail_cnt == 0)
 $display("RESULT: PASS");
 else
 $display("RESULT: FAIL");
 $display("========================================");
 $finish;
 end

endmodule
`default_nettype wire
