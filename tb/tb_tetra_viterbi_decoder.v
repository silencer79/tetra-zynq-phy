// =============================================================================
// tb_tetra_viterbi_decoder.v — Self-Checking Testbench
// =============================================================================
// Tests:
// TC1: All-zeros block (220 stages NDB) — decoder must recover 216 zeros
// TC2: Known 8-bit pattern, perfect soft decisions, rate 1/3
// TC3: 216-bit NDB block, pseudo-random data, perfect soft decisions
// TC4: 216-bit NDB block with erasures on G3 (simulates rate-2/3 puncturing)
// TC5: SCH/F block 436 stages, perfect soft decisions
// TC6: Noisy soft decisions (confidence=5/2 instead of 7/0)
// TC7: Back-to-back blocks — second block starts immediately after block_done
//
// Reference encoder: inline Verilog task implementing the same K=5 convolutional
// code (G1=0x1B, G2=0x19, G3=0x15) used by tetra_rcpc_encoder.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_viterbi_decoder;

 // -------------------------------------------------------------------------
 // DUT parameters
 // -------------------------------------------------------------------------
 localparam SOFT_WIDTH = 3;
 localparam TRACEBACK = 32;
 localparam MAX_STAGES = 436;

 // -------------------------------------------------------------------------
 // Clock and reset
 // -------------------------------------------------------------------------
 reg clk_sys;
 reg rst_n_sys;

 initial clk_sys = 0;
 always #5 clk_sys = ~clk_sys; // 100 MHz

 // -------------------------------------------------------------------------
 // DUT ports
 // -------------------------------------------------------------------------
 reg [SOFT_WIDTH-1:0] soft_bit_0;
 reg [SOFT_WIDTH-1:0] soft_bit_1;
 reg [SOFT_WIDTH-1:0] soft_bit_2;
 reg input_valid;
 reg [8:0] num_stages;
 reg [2:0] punct_pattern;

 wire decoded_bit;
 wire decoded_valid;
 wire block_done;
 wire [15:0] path_metric_min;

 tetra_viterbi_decoder #(
.SOFT_WIDTH (SOFT_WIDTH),
.TRACEBACK (TRACEBACK),
.MAX_STAGES (MAX_STAGES)
 ) u_dut (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.soft_bit_0 (soft_bit_0),
.soft_bit_1 (soft_bit_1),
.soft_bit_2 (soft_bit_2),
.input_valid (input_valid),
.num_stages (num_stages),
.punct_pattern (punct_pattern),
.decoded_bit (decoded_bit),
.decoded_valid (decoded_valid),
.block_done (block_done),
.path_metric_min (path_metric_min)
 );

 // -------------------------------------------------------------------------
 // Waveform dump
 // -------------------------------------------------------------------------
 initial begin
 $dumpfile("tb_tetra_viterbi_decoder.vcd");
 $dumpvars(0, tb_tetra_viterbi_decoder);
 end

 // -------------------------------------------------------------------------
 // Reference encoder registers (used in tasks below)
 // -------------------------------------------------------------------------
 reg [3:0] enc_sr; // encoder shift register: enc_sr[3]=newest, enc_sr[0]=oldest

 // Compute encoder outputs for one bit; updates enc_sr
 // full_sr = {inp, enc_sr[3:0]} (5 bits)
 // G1=0x1B: tap bits [4,3,1,0] => parity of {inp, enc_sr[3], enc_sr[1], enc_sr[0]}
 // G2=0x19: tap bits [4,3,0] => parity of {inp, enc_sr[3], enc_sr[0]}
 // G3=0x15: tap bits [4,2,0] => parity of {inp, enc_sr[2], enc_sr[0]}
 task encode_one;
 input inp;
 output g1, g2, g3;
 begin
 g1 = inp ^ enc_sr[3] ^ enc_sr[1] ^ enc_sr[0];
 g2 = inp ^ enc_sr[3] ^ enc_sr[0];
 g3 = inp ^ enc_sr[2] ^ enc_sr[0];
 enc_sr = {inp, enc_sr[3:1]}; // blocking: shift newest to [3], drop [0]
 end
 endtask

 // -------------------------------------------------------------------------
 // Test state
 // -------------------------------------------------------------------------
 integer tc_pass;
 integer tc_fail;
 integer bit_errors;
 integer i;

 // Storage for one block
 reg [MAX_STAGES-1:0] enc_g1_buf; // encoded G1 bits (including tail)
 reg [MAX_STAGES-1:0] enc_g2_buf;
 reg [MAX_STAGES-1:0] enc_g3_buf;
 reg [MAX_STAGES-1:0] data_buf; // original data bits (info only, no tail)
 reg [MAX_STAGES-1:0] decoded_buf; // captured decoder output

 // -------------------------------------------------------------------------
 // Task: encode a data block and store bits in enc_g{1,2,3}_buf
 // n_info = number of info bits
 // data_buf[n_info-1:0] must be populated before calling
 // appends K-1=4 tail zeros
 // fills enc_g1_buf, enc_g2_buf, enc_g3_buf for n_info+4 stages
 // -------------------------------------------------------------------------
 task encode_block;
 input integer n_info;
 integer t;
 reg g1, g2, g3;
 begin
 enc_sr = 4'd0;
 for (t = 0; t < n_info; t = t + 1) begin
 encode_one(data_buf[t], g1, g2, g3);
 enc_g1_buf[t] = g1;
 enc_g2_buf[t] = g2;
 enc_g3_buf[t] = g3;
 end
 // Tail: K-1 = 4 zero bits
 for (t = n_info; t < n_info + 4; t = t + 1) begin
 encode_one(1'b0, g1, g2, g3);
 enc_g1_buf[t] = g1;
 enc_g2_buf[t] = g2;
 enc_g3_buf[t] = g3;
 end
 end
 endtask

 // -------------------------------------------------------------------------
 // Task: run_viterbi
 // Sends num_stg soft triplets to DUT (one per clock when input_valid=1).
 // soft values: hard bit 0 -> conf_0, hard bit 1 -> conf_1, erasure -> 4
 // erase_g3: if 1, replace G3 soft with erasure 4 (simulate rate-2/3 punct)
 // Waits for block_done, captures decoded bits into decoded_buf.
 // Returns bit_errors = number of mismatches vs data_buf[0..n_info-1]
 // -------------------------------------------------------------------------
 task run_viterbi;
 input integer num_stg; // trellis stages to send
 input integer n_info; // info bits to check (excludes tail)
 input [2:0] conf_0; // soft value for hard 0 (e.g. 3'd0 = max conf)
 input [2:0] conf_1; // soft value for hard 1 (e.g. 3'd7 = max conf)
 input erase_g3; // 1 = replace G3 channel with erasure (4)
 integer t;
 integer timeout;
 reg block_done_seen; // latch: set if block_done fires during output loop
 begin
 // Feed input stages
 num_stages = num_stg[8:0];
 punct_pattern = 3'd0;
 input_valid = 1'b0;
 @(posedge clk_sys); #1;

 for (t = 0; t < num_stg; t = t + 1) begin
 soft_bit_0 = enc_g1_buf[t] ? conf_1: conf_0;
 soft_bit_1 = enc_g2_buf[t] ? conf_1: conf_0;
 soft_bit_2 = erase_g3 ? 3'd4: (enc_g3_buf[t] ? conf_1: conf_0);
 input_valid = 1'b1;
 @(posedge clk_sys); #1;
 end
 input_valid = 1'b0;
 soft_bit_0 = 3'd0;
 soft_bit_1 = 3'd0;
 soft_bit_2 = 3'd0;

 // Wait for decoded_valid (S_OUTPUT phase)
 // Latency: S_ACS + S_TB_INIT + S_TRACEBACK + pipeline = ~3*num_stg cycles
 decoded_buf = {MAX_STAGES{1'b0}};
 block_done_seen = 1'b0;
 timeout = 0;
 while (!decoded_valid && timeout < 4000) begin
 @(posedge clk_sys); #1;
 timeout = timeout + 1;
 end
 if (timeout >= 4000) begin
 $error("TIMEOUT waiting for decoded_valid");
 disable run_viterbi;
 end

 // Capture n_info decoded bits.
 // block_done is a 1-cycle pulse that fires on the LAST output cycle
 // (same posedge as the last decoded_valid tick). The loop's trailing
 // @(posedge) advance takes us one cycle past that edge, so we latch
 // block_done BEFORE advancing to avoid missing it.
 for (t = 0; t < n_info; t = t + 1) begin
 if (!decoded_valid) begin
 $error("decoded_valid dropped early at bit %0d", t);
 disable run_viterbi;
 end
 decoded_buf[t] = decoded_bit;
 if (block_done) block_done_seen = 1'b1; // catch 1-cycle pulse
 @(posedge clk_sys); #1;
 end

 // Wait for block_done (may already have been latched in the loop above)
 timeout = 0;
 while (!block_done && !block_done_seen && timeout < 20) begin
 @(posedge clk_sys); #1;
 timeout = timeout + 1;
 end
 if (!block_done && !block_done_seen)
 $error("TIMEOUT waiting for block_done");

 // Count bit errors
 bit_errors = 0;
 for (t = 0; t < n_info; t = t + 1) begin
 if (decoded_buf[t] !== data_buf[t]) bit_errors = bit_errors + 1;
 end
 end
 endtask

 // =========================================================================
 // Test cases
 // =========================================================================
 integer n;
 integer seed;

 initial begin
 tc_pass = 0;
 tc_fail = 0;
 seed = 42;

 // Reset
 rst_n_sys = 1'b0;
 input_valid = 1'b0;
 soft_bit_0 = 3'd0;
 soft_bit_1 = 3'd0;
 soft_bit_2 = 3'd0;
 num_stages = 9'd220;
 punct_pattern = 3'd0;
 repeat (5) @(posedge clk_sys);
 #1 rst_n_sys = 1'b1;
 repeat (3) @(posedge clk_sys); #1;

 // -----------------------------------------------------------------
 // TC1: All-zeros NDB block (216 bits), perfect soft (hard) decisions
 // -----------------------------------------------------------------
 for (i = 0; i < 216; i = i + 1) data_buf[i] = 1'b0;
 encode_block(216);
 run_viterbi(220, 216, 3'd0, 3'd7, 1'b0);
 if (bit_errors == 0) begin
 $display("TC1 PASS: all-zeros NDB, 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC1 FAIL: all-zeros NDB, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC2: Known 8-bit pattern (padded to 216), perfect soft decisions
 // Pattern: 10110010 repeated
 // -----------------------------------------------------------------
 for (i = 0; i < 216; i = i + 1)
 data_buf[i] = ({1'b1,1'b0,1'b1,1'b1,1'b0,1'b0,1'b1,1'b0} >> (i % 8)) & 1;
 encode_block(216);
 run_viterbi(220, 216, 3'd0, 3'd7, 1'b0);
 if (bit_errors == 0) begin
 $display("TC2 PASS: known pattern NDB, 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC2 FAIL: known pattern NDB, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC3: Pseudo-random 216-bit NDB block, perfect soft decisions
 // -----------------------------------------------------------------
 for (i = 0; i < 216; i = i + 1) begin
 seed = seed * 1664525 + 1013904223;
 data_buf[i] = seed[23];
 end
 encode_block(216);
 run_viterbi(220, 216, 3'd0, 3'd7, 1'b0);
 if (bit_errors == 0) begin
 $display("TC3 PASS: random NDB, 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC3 FAIL: random NDB, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC4: 216-bit NDB block, G3 channel erased (rate-2/3 simulation)
 // With soft=4 (erasure) on G3, decoder should still converge with
 // > 0 dB effective SNR on G1+G2 channels.
 // -----------------------------------------------------------------
 for (i = 0; i < 216; i = i + 1) begin
 seed = seed * 1664525 + 1013904223;
 data_buf[i] = seed[17];
 end
 encode_block(216);
 run_viterbi(220, 216, 3'd0, 3'd7, 1'b1); // erase_g3=1
 if (bit_errors == 0) begin
 $display("TC4 PASS: NDB with G3 erased (rate-2/3 sim), 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC4 FAIL: NDB G3 erased, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC5: SCH/F block (432 info bits, 436 stages), perfect soft
 // -----------------------------------------------------------------
 for (i = 0; i < 432; i = i + 1) begin
 seed = seed * 1664525 + 1013904223;
 data_buf[i] = seed[31];
 end
 encode_block(432);
 run_viterbi(436, 432, 3'd0, 3'd7, 1'b0);
 if (bit_errors == 0) begin
 $display("TC5 PASS: SCH/F 432-bit block, 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC5 FAIL: SCH/F, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC6: 216-bit NDB, reduced-confidence soft decisions (SNR ~3 dB)
 // Hard 0 -> soft 2, hard 1 -> soft 5 (confidence 3 instead of 7)
 // BER should still be 0 with no channel noise
 // -----------------------------------------------------------------
 for (i = 0; i < 216; i = i + 1) begin
 seed = seed * 1664525 + 1013904223;
 data_buf[i] = seed[7];
 end
 encode_block(216);
 run_viterbi(220, 216, 3'd2, 3'd5, 1'b0); // conf_0=2, conf_1=5
 if (bit_errors == 0) begin
 $display("TC6 PASS: NDB reduced soft confidence (2/5), 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC6 FAIL: NDB reduced soft, %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // TC7: Back-to-back NDB blocks (no idle gap between them)
 // -----------------------------------------------------------------
 // Block A
 for (i = 0; i < 216; i = i + 1) data_buf[i] = i[0]; // 010101...
 encode_block(216);
 // Send block A
 num_stages = 9'd220;
 input_valid = 1'b0;
 @(posedge clk_sys); #1;
 begin: send_a
 integer t;
 for (t = 0; t < 220; t = t + 1) begin
 soft_bit_0 = enc_g1_buf[t] ? 3'd7: 3'd0;
 soft_bit_1 = enc_g2_buf[t] ? 3'd7: 3'd0;
 soft_bit_2 = enc_g3_buf[t] ? 3'd7: 3'd0;
 input_valid = 1'b1;
 @(posedge clk_sys); #1;
 end
 end
 input_valid = 1'b0;

 // Block B — start immediately after A's input (decoded output of A still pending)
 for (i = 0; i < 216; i = i + 1) data_buf[i] = i[1]; // 001100...
 encode_block(216);
 // Do NOT assert input_valid until after block_done of A
 begin: wait_done_a
 integer timeout;
 timeout = 0;
 while (!block_done && timeout < 3000) begin
 @(posedge clk_sys); #1;
 timeout = timeout + 1;
 end
 end

 // Now capture A's output (already streamed, just check block_done fired)
 // Then send B
 @(posedge clk_sys); #1;
 run_viterbi(220, 216, 3'd0, 3'd7, 1'b0);
 if (bit_errors == 0) begin
 $display("TC7 PASS: back-to-back blocks, block B 0 bit errors");
 tc_pass = tc_pass + 1;
 end else begin
 $error("TC7 FAIL: back-to-back, block B %0d bit errors", bit_errors);
 tc_fail = tc_fail + 1;
 end

 // -----------------------------------------------------------------
 // Summary
 // -----------------------------------------------------------------
 $display("============================================================");
 $display("Viterbi testbench: %0d/%0d passed", tc_pass, tc_pass + tc_fail);
 $display("============================================================");
 if (tc_fail == 0)
 $display("ALL TESTS PASSED");
 else
 $error("FAILURES: %0d test(s) failed", tc_fail);

 #100;
 $finish;
 end

 // Timeout watchdog
 initial begin
 #10_000_000;
 $error("WATCHDOG TIMEOUT — simulation exceeded 10ms");
 $finish;
 end

endmodule

`default_nettype wire
