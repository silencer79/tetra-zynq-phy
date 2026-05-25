// =============================================================================
// tb_tetra_pi4dqpsk_mod.v — Self-Checking Testbench
// =============================================================================
// Tests tetra_pi4dqpsk_mod.v against reference values from
// gen_pi4dqpsk_mod_vectors.py
//
// IQ amplitude constants (16-bit Q1.15):
// AMP_ONE = 32767 (1.0 scale)
// AMP_SQ2 = 23170 (1/sqrt(2) scale)
// AMP_ZERO = 0
//
// Test Cases:
// TC1: All dibit=00 — rotates +pi/4 each step, traverses all 8 phases
// TC2: All dibit=11 — rotates -3pi/4 each step
// TC3: All dibit values {00,01,10,11} — verify each phase increment
// TC4: Reset mid-sequence — verify clean restart from phase idx=0
// TC5: sample_valid_out timing — verify exactly 1 cycle after dibit_valid
// TC6: NTS first 8 dibits — verify specific IQ values
//
// Expected values precomputed from gen_pi4dqpsk_mod_vectors.py.
// Pipeline: 1 cycle (i_out/q_out valid 1 cycle after dibit_valid)
//
// Simulation: iverilog -g2001 tb_tetra_pi4dqpsk_mod.v../../rtl/tx/tetra_pi4dqpsk_mod.v
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_tetra_pi4dqpsk_mod;

 // -------------------------------------------------------------------------
 // IQ amplitude constants
 // -------------------------------------------------------------------------
 localparam signed [15:0] AMP_ONE = 16'sd32767;
 localparam signed [15:0] AMP_SQ2 = 16'sd23170;
 localparam signed [15:0] AMP_NEG1 = -16'sd32767;
 localparam signed [15:0] AMP_NSQR = -16'sd23170;
 localparam signed [15:0] AMP_ZERO = 16'sd0;

 // -------------------------------------------------------------------------
 // DUT signals
 // -------------------------------------------------------------------------
 reg clk_sample;
 reg rst_n_sample;
 reg [1:0] dibit_in;
 reg dibit_valid;
 wire signed [15:0] i_out;
 wire signed [15:0] q_out;
 wire sample_valid_out;

 // -------------------------------------------------------------------------
 // DUT instantiation
 // -------------------------------------------------------------------------
 tetra_pi4dqpsk_mod #(
.IQ_WIDTH (16),
.PHASE_WIDTH (16),
.LUT_DEPTH (1024)
 ) dut (
.clk_sample (clk_sample),
.rst_n_sample (rst_n_sample),
.dibit_in (dibit_in),
.dibit_valid (dibit_valid),
.i_out (i_out),
.q_out (q_out),
.sample_valid_out(sample_valid_out)
 );

 // -------------------------------------------------------------------------
 // Clock: 10 ns period (100 MHz)
 // -------------------------------------------------------------------------
 initial clk_sample = 1'b0;
 always #5 clk_sample = ~clk_sample;

 // -------------------------------------------------------------------------
 // Test infrastructure
 // -------------------------------------------------------------------------
 integer fail_cnt;
 integer pass_cnt;

 task apply_dibit;
 input [1:0] db;
 input dv;
 begin
 @(negedge clk_sample);
 dibit_in = db;
 dibit_valid = dv;
 end
 endtask

 // Check IQ output (called AFTER @posedge that registered the output)
 task check_iq;
 input signed [15:0] exp_i;
 input signed [15:0] exp_q;
 input exp_valid;
 input [31:0] tc_num;
 input [31:0] step;
 begin
 @(posedge clk_sample); #1;
 if (i_out !== exp_i || q_out !== exp_q || sample_valid_out !== exp_valid) begin
 $display("FAIL TC%0d step%0d: I=%0d Q=%0d valid=%b expI=%0d expQ=%0d expV=%b",
 tc_num, step, i_out, q_out, sample_valid_out,
 exp_i, exp_q, exp_valid);
 fail_cnt = fail_cnt + 1;
 end else begin
 pass_cnt = pass_cnt + 1;
 end
 end
 endtask

 // =========================================================================
 // Main test sequence
 // =========================================================================
 initial begin
 $dumpfile("tb_tetra_pi4dqpsk_mod.vcd");
 $dumpvars(0, tb_tetra_pi4dqpsk_mod);

 fail_cnt = 0;
 pass_cnt = 0;
 dibit_in = 2'b00;
 dibit_valid = 1'b0;

 // --- Reset ---
 rst_n_sample = 1'b0;
 @(posedge clk_sample); #1;
 @(posedge clk_sample); #1;
 @(negedge clk_sample);
 rst_n_sample = 1'b1;

 // =====================================================================
 // TC1: All dibit=00 (+pi/4 each), starting phase_idx=0
 // Phase sequence: 0→1→2→3→4→5→6→7→0 (wraps mod 8)
 // Expected IQ after each dibit (1 cycle latency):
 // step 0: phase_new=1 (45°) → I=23170, Q=23170
 // step 1: phase_new=2 (90°) → I=0, Q=32767
 // step 2: phase_new=3 (135°) → I=-23170, Q=23170
 // step 3: phase_new=4 (180°) → I=-32767, Q=0
 // step 4: phase_new=5 (225°) → I=-23170, Q=-23170
 // step 5: phase_new=6 (270°) → I=0, Q=-32767
 // step 6: phase_new=7 (315°) → I=23170, Q=-23170
 // step 7: phase_new=0 (0°) → I=32767, Q=0
 // =====================================================================
 $display("--- TC1: All dibit=00, +pi/4 rotation ---");

 apply_dibit(2'b00, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 1, 0); // idx=1
 apply_dibit(2'b00, 1'b1); check_iq( AMP_ZERO, AMP_ONE, 1'b1, 1, 1); // idx=2
 apply_dibit(2'b00, 1'b1); check_iq( AMP_NSQR, AMP_SQ2, 1'b1, 1, 2); // idx=3
 apply_dibit(2'b00, 1'b1); check_iq( AMP_NEG1, AMP_ZERO, 1'b1, 1, 3); // idx=4
 apply_dibit(2'b00, 1'b1); check_iq( AMP_NSQR, AMP_NSQR, 1'b1, 1, 4); // idx=5
 apply_dibit(2'b00, 1'b1); check_iq( AMP_ZERO, AMP_NEG1, 1'b1, 1, 5); // idx=6
 apply_dibit(2'b00, 1'b1); check_iq( AMP_SQ2, AMP_NSQR, 1'b1, 1, 6); // idx=7
 apply_dibit(2'b00, 1'b1); check_iq( AMP_ONE, AMP_ZERO, 1'b1, 1, 7); // idx=0 (wrap)

 // =====================================================================
 // TC2: sample_valid_out timing — must be 0 when dibit_valid=0
 // =====================================================================
 $display("--- TC2: sample_valid_out timing ---");
 // Idle: no dibit_valid
 apply_dibit(2'b00, 1'b0); @(posedge clk_sample); #1;
 if (sample_valid_out !== 1'b0) begin
 $display("FAIL TC2: sample_valid_out=%b expected 0 when idle", sample_valid_out);
 fail_cnt = fail_cnt + 1;
 end else begin
 pass_cnt = pass_cnt + 1;
 end

 // =====================================================================
 // TC3: dibit=11 (−3pi/4 = +5 mod 8), starting fresh (reset)
 // Phase: 0→5→2→7→4→1→6→3→0
 // Expected IQ:
 // step 0: new_idx=5 (225°) → I=-23170, Q=-23170
 // step 1: new_idx=2 (90°) → I=0, Q=32767
 // step 2: new_idx=7 (315°) → I=23170, Q=-23170
 // step 3: new_idx=4 (180°) → I=-32767, Q=0
 // step 4: new_idx=1 (45°) → I=23170, Q=23170
 // step 5: new_idx=6 (270°) → I=0, Q=-32767
 // step 6: new_idx=3 (135°) → I=-23170, Q=23170
 // step 7: new_idx=0 (0°) → I=32767, Q=0
 // =====================================================================
 $display("--- TC3: All dibit=11, -3pi/4 rotation ---");
 @(negedge clk_sample); rst_n_sample = 1'b0;
 @(posedge clk_sample); #1;
 @(negedge clk_sample); rst_n_sample = 1'b1;

 apply_dibit(2'b11, 1'b1); check_iq( AMP_NSQR, AMP_NSQR, 1'b1, 3, 0); // idx=5
 apply_dibit(2'b11, 1'b1); check_iq( AMP_ZERO, AMP_ONE, 1'b1, 3, 1); // idx=2
 apply_dibit(2'b11, 1'b1); check_iq( AMP_SQ2, AMP_NSQR, 1'b1, 3, 2); // idx=7
 apply_dibit(2'b11, 1'b1); check_iq( AMP_NEG1, AMP_ZERO, 1'b1, 3, 3); // idx=4
 apply_dibit(2'b11, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 3, 4); // idx=1
 apply_dibit(2'b11, 1'b1); check_iq( AMP_ZERO, AMP_NEG1, 1'b1, 3, 5); // idx=6
 apply_dibit(2'b11, 1'b1); check_iq( AMP_NSQR, AMP_SQ2, 1'b1, 3, 6); // idx=3
 apply_dibit(2'b11, 1'b1); check_iq( AMP_ONE, AMP_ZERO, 1'b1, 3, 7); // idx=0 (wrap)

 // =====================================================================
 // TC4: One of each dibit {00, 01, 10, 11} from phase=0
 // Phase increments: +1, +3, +7, +5
 // Phase: 0→1→4→3→0
 // dibit=00, from idx=0: new_idx=0+1=1 → I=23170, Q=23170
 // dibit=01, from idx=1: new_idx=1+3=4 → I=-32767, Q=0
 // dibit=10, from idx=4: new_idx=4+7=3 (mod8: 11mod8=3) → I=-23170, Q=23170
 // dibit=11, from idx=3: new_idx=3+5=0 (mod8: 8mod8=0) → I=32767, Q=0
 // =====================================================================
 $display("--- TC4: One of each dibit {00,01,10,11} ---");
 @(negedge clk_sample); rst_n_sample = 1'b0; dibit_valid = 1'b0; // clear leftover valid
 @(posedge clk_sample); #1;
 @(negedge clk_sample); rst_n_sample = 1'b1;

 apply_dibit(2'b00, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 4, 0); // 0→1 (45°)
 apply_dibit(2'b01, 1'b1); check_iq( AMP_NEG1, AMP_ZERO, 1'b1, 4, 1); // 1→4 (180°)
 apply_dibit(2'b10, 1'b1); check_iq( AMP_NSQR, AMP_SQ2, 1'b1, 4, 2); // 4+7=11→3 (135°)
 apply_dibit(2'b11, 1'b1); check_iq( AMP_ONE, AMP_ZERO, 1'b1, 4, 3); // 3+5=8→0 (0°)

 // =====================================================================
 // TC5: Reset mid-sequence → verify restart from phase=0
 // After reset: next dibit=00 → phase 0+1=1 → I=23170, Q=23170
 // =====================================================================
 $display("--- TC5: Reset mid-sequence ---");
 // First advance to some non-zero phase
 apply_dibit(2'b01, 1'b1); @(posedge clk_sample); #1; // phase goes to 4

 // Reset
 @(negedge clk_sample); rst_n_sample = 1'b0; dibit_valid = 1'b0; // clear leftover valid
 @(posedge clk_sample); #1;
 if (sample_valid_out !== 1'b0) begin
 $display("FAIL TC5: sample_valid_out=%b expected 0 during reset", sample_valid_out);
 fail_cnt = fail_cnt + 1;
 end else begin
 pass_cnt = pass_cnt + 1;
 end
 @(negedge clk_sample); rst_n_sample = 1'b1;

 // After reset: phase_idx=0; dibit=00 → new_idx=1 → I=23170, Q=23170
 apply_dibit(2'b00, 1'b1);
 check_iq(AMP_SQ2, AMP_SQ2, 1'b1, 5, 0);

 // =====================================================================
 // TC6: NTS-derived sequence — first 8 symbols of Normal Training Sequence
 // NTS symbols: +1,-1,+1,+1,+1,-1,-1,+1 → dibits: 00,10,00,00,00,10,10,00
 // Starting phase_idx=0:
 // 00: 0→1 (45°) → 23170, 23170
 // 10: 1→0 (0°) → 32767, 0
 // 00: 0→1 (45°) → 23170, 23170
 // 00: 1→2 (90°) → 0, 32767
 // 00: 2→3 (135°) → -23170, 23170
 // 10: 3→2 (90°) → 0, 32767
 // 10: 2→1 (45°) → 23170, 23170
 // 00: 1→2 (90°) → 0, 32767
 // =====================================================================
 $display("--- TC6: NTS first 8 symbols ---");
 @(negedge clk_sample); rst_n_sample = 1'b0; dibit_valid = 1'b0; // clear leftover valid
 @(posedge clk_sample); #1;
 @(negedge clk_sample); rst_n_sample = 1'b1;

 apply_dibit(2'b00, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 6, 0); // 0→1
 apply_dibit(2'b10, 1'b1); check_iq( AMP_ONE, AMP_ZERO, 1'b1, 6, 1); // 1→0
 apply_dibit(2'b00, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 6, 2); // 0→1
 apply_dibit(2'b00, 1'b1); check_iq( AMP_ZERO, AMP_ONE, 1'b1, 6, 3); // 1→2
 apply_dibit(2'b00, 1'b1); check_iq( AMP_NSQR, AMP_SQ2, 1'b1, 6, 4); // 2→3
 apply_dibit(2'b10, 1'b1); check_iq( AMP_ZERO, AMP_ONE, 1'b1, 6, 5); // 3+7=10→2
 apply_dibit(2'b10, 1'b1); check_iq( AMP_SQ2, AMP_SQ2, 1'b1, 6, 6); // 2+7=9→1
 apply_dibit(2'b00, 1'b1); check_iq( AMP_ZERO, AMP_ONE, 1'b1, 6, 7); // 1→2

 // =====================================================================
 // Final summary
 // =====================================================================
 $display("========================================");
 if (fail_cnt == 0) begin
 $display("PASS — All %0d checks passed", pass_cnt);
 end else begin
 $display("FAIL — %0d/%0d checks failed", fail_cnt, fail_cnt + pass_cnt);
 end
 $display("========================================");
 $finish;
 end

 // -------------------------------------------------------------------------
 // Timeout guard
 // -------------------------------------------------------------------------
 initial begin
 #200000;
 $display("TIMEOUT — simulation exceeded 200 us");
 $finish;
 end

endmodule
`default_nettype wire
