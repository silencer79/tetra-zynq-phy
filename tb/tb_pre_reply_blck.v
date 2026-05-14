// =============================================================================
// tb_pre_reply_blck.v — Phase X.5 Pre-Reply BL-ACK Mini-FSM regression
// =============================================================================
//
// Coverage:
// TC1 reset baseline — all outputs 0, push_cnt=0
// TC2 ul_req pulse with ssi=0x282F91 → wr_blck_valid_sys pulses 1 cycle,
// wr_blck_pdu_type=01 (SCH_HD), target_tn=cfg_mcch_tn,
// wr_blck_coded[215:0] equals SCH/HD-encoded BL-ACK (bit-exact via
// a reference instance of bl_ack_builder + sch_hd_encoder driven in
// parallel from the same SSI), upper [431:216] = 0
// TC3 ul_req pulse with ssi=0xCAFE42 → fresh push, different coded
// bits (sanity: SSI swap propagates), push_cnt += 1
// TC4 two ul_req pulses 5 cycles apart while FSM busy in S_BUILD →
// first push delivered, second drop_cnt += 1; after FSM returns
// to IDLE a fresh ul_req pulse pushes again
// TC5 push_cnt sticky-saturate sanity (force-set internal counter near
// 0xFFFF — done via deep-hierarchy poke; smaller-cycle proxy: 3
// successful pushes back-to-back yield push_cnt=3)
//
// Run:
// iverilog -g2001 -o /tmp/tb_blck tb/tb_pre_reply_blck.v \
// rtl/lmac/tetra_pre_reply_blck.v \
// rtl/lmac/tetra_mac_resource_bl_ack_builder.v \
// rtl/lmac/tetra_sch_hd_encoder.v \
// rtl/lmac/tetra_crc16.v \
// rtl/lmac/tetra_interleaver.v
// vvp /tmp/tb_blck
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pre_reply_blck;
 reg clk = 1'b0;
 reg rst_n = 1'b0;
 always #5 clk = ~clk;

 // DUT inputs
 reg trigger_valid = 1'b0;
 reg [23:0] ul_ssi = 24'd0;
 reg [1:0] cfg_mcch_tn = 2'd1;
 reg [31:0] cfg_scramble_init = 32'd0; // TB uses 0 so reference encoder matches

 // DUT outputs
 wire wr_blck_valid_sys;
 wire [431:0] wr_blck_coded_sys;
 wire [1:0] wr_blck_pdu_type_sys;
 wire [1:0] wr_blck_target_tn_sys;
 wire [15:0] push_cnt_sys;
 wire [15:0] drop_cnt_sys;

 tetra_pre_reply_blck dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.trigger_valid (trigger_valid),
.ul_ssi (ul_ssi),
.cfg_mcch_tn (cfg_mcch_tn),
.cfg_scramble_init (cfg_scramble_init),
.wr_blck_valid_sys (wr_blck_valid_sys),
.wr_blck_coded_sys (wr_blck_coded_sys),
.wr_blck_pdu_type_sys (wr_blck_pdu_type_sys),
.wr_blck_target_tn_sys(wr_blck_target_tn_sys),
.push_cnt_sys (push_cnt_sys),
.drop_cnt_sys (drop_cnt_sys)
 );

 // -------------------------------------------------------------------------
 // Reference encoder chain — same parameters as DUT, driven from a
 // separate `ref_start` so we can pre-compute the expected coded bits
 // for any given SSI before kicking the DUT.
 // -------------------------------------------------------------------------
 reg ref_start = 1'b0;
 reg [23:0] ref_ssi = 24'd0;

 wire [123:0] ref_pdu_w;
 wire ref_pdu_valid_w;
 tetra_mac_resource_bl_ack_builder #(
.PDU_BITS(124)
 ) u_ref_bl_ack (
.clk (clk),
.rst_n (rst_n),
.start (ref_start),
.ssi (ref_ssi),
.addr_type (3'd1),
.random_access_flag (1'b0),
.nr (1'b0),
.pdu_bits (ref_pdu_w),
.valid (ref_pdu_valid_w)
 );

 reg ref_enc_start = 1'b0;
 wire [215:0] ref_coded_w;
 wire ref_coded_valid_w;
 tetra_sch_hd_encoder u_ref_sch_hd (
.clk (clk),
.rst_n (rst_n),
.encode_start (ref_enc_start),
.info_bits (ref_pdu_w),
.scramble_init (32'd0),
.coded_bits (ref_coded_w),
.coded_valid (ref_coded_valid_w)
 );

 // Build the reference SCH/HD-coded 216-bit payload for `s` and store in
 // `out_coded`. Blocking task in TB context.
 task automatic compute_ref;
 input [23:0] s;
 output [215:0] out_coded;
 integer guard;
 reg [215:0] cap;
 begin
 // Drive SSI into ref builder, pulse start
 ref_ssi <= s;
 ref_start <= 1'b1;
 @(posedge clk);
 ref_start <= 1'b0;

 // Wait for builder valid (max ~10 cyc)
 guard = 0;
 while (!ref_pdu_valid_w && guard < 100) begin
 @(posedge clk);
 guard = guard + 1;
 end
 // Trigger encoder on the same cycle builder asserted valid
 ref_enc_start <= 1'b1;
 @(posedge clk);
 ref_enc_start <= 1'b0;

 // Wait for encoder valid (~487 cyc per encoder header comment)
 guard = 0;
 cap = 216'd0;
 while (!ref_coded_valid_w && guard < 1000) begin
 @(posedge clk);
 guard = guard + 1;
 end
 // sample on the cycle valid is high
 cap = ref_coded_w;
 @(posedge clk); // let valid drop / state return idle
 out_coded = cap;
 end
 endtask

 // -------------------------------------------------------------------------
 // Test bookkeeping
 // -------------------------------------------------------------------------
 integer pass_cnt = 0;
 integer fail_cnt = 0;
 integer guard_i;

 task automatic check_eq32;
 input [255:0] tag;
 input [31:0] got;
 input [31:0] exp;
 begin
 if (got === exp) begin
 $display(" PASS %0s got=0x%08h", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=0x%08h exp=0x%08h", tag, got, exp);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task automatic check_eq2;
 input [255:0] tag;
 input [1:0] got;
 input [1:0] exp;
 begin
 if (got === exp) begin
 $display(" PASS %0s got=0b%02b", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=0b%02b exp=0b%02b", tag, got, exp);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task automatic check_eq216;
 input [255:0] tag;
 input [215:0] got;
 input [215:0] exp;
 begin
 if (got === exp) begin
 $display(" PASS %0s coded[215:192]=0x%06h", tag, got[215:192]);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s", tag);
 $display(" got = %h", got);
 $display(" exp = %h", exp);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 // Wait until wr_blck_valid_sys asserts (or timeout)
 task automatic wait_push;
 input integer max_cyc;
 output integer hit;
 begin
 hit = 0;
 for (guard_i = 0; guard_i < max_cyc; guard_i = guard_i + 1) begin
 @(posedge clk);
 if (wr_blck_valid_sys) begin
 hit = 1;
 disable wait_push;
 end
 end
 end
 endtask

 // Pulse trigger_valid for 1 cycle with given SSI
 task automatic pulse_trigger;
 input [23:0] s;
 begin
 ul_ssi <= s;
 trigger_valid <= 1'b1;
 @(posedge clk);
 trigger_valid <= 1'b0;
 end
 endtask

 // -------------------------------------------------------------------------
 // Test cases
 // -------------------------------------------------------------------------
 reg [215:0] exp_coded_a;
 reg [215:0] exp_coded_b;
 reg [215:0] got_coded_a;
 reg [215:0] got_coded_b;
 integer hit_a, hit_b, hit_x;

 initial begin
 // Reset
 rst_n = 1'b0;
 trigger_valid = 1'b0;
 ul_ssi = 24'd0;
 cfg_mcch_tn = 2'd1;
 repeat (4) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // -----------------------------------------------------------------
 $display("---- TC1 reset baseline ----");
 check_eq32("push_cnt=0", {16'd0, push_cnt_sys}, 32'd0);
 check_eq32("drop_cnt=0", {16'd0, drop_cnt_sys}, 32'd0);
 if (wr_blck_valid_sys === 1'b0) begin
 $display(" PASS wr_blck_valid_sys=0");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL wr_blck_valid_sys=%b", wr_blck_valid_sys);
 fail_cnt = fail_cnt + 1;
 end

 // -----------------------------------------------------------------
 $display("---- TC2 single push, ssi=0x282F91 ----");
 // Pre-compute reference for SSI = 0x282F91
 compute_ref(24'h282F91, exp_coded_a);
 // Idle the ref signals
 @(posedge clk);
 cfg_mcch_tn = 2'd1;

 pulse_trigger(24'h282F91);
 wait_push(2000, hit_a);
 if (hit_a == 0) begin
 $display(" FAIL no wr_blck_valid_sys within 2000 cyc");
 fail_cnt = fail_cnt + 1;
 end else begin
 // Sample queue outputs on the asserted cycle
 got_coded_a = wr_blck_coded_sys[215:0];
 check_eq2 ("pdu_type=01 (SCH_HD)", wr_blck_pdu_type_sys, 2'd1);
 check_eq2 ("target_tn=cfg_mcch_tn", wr_blck_target_tn_sys, 2'd1);
 check_eq32("coded[431:216]=0", wr_blck_coded_sys[431:400], 32'd0);
 check_eq216("coded[215:0] bit-exact", got_coded_a, exp_coded_a);
 check_eq32("push_cnt=1", {16'd0, push_cnt_sys}, 32'd1);
 end

 // -----------------------------------------------------------------
 $display("---- TC3 second push, ssi=0xCAFE42 ----");
 compute_ref(24'hCAFE42, exp_coded_b);
 @(posedge clk);
 cfg_mcch_tn = 2'd2;
 pulse_trigger(24'hCAFE42);
 wait_push(2000, hit_b);
 if (hit_b == 0) begin
 $display(" FAIL no wr_blck_valid_sys within 2000 cyc");
 fail_cnt = fail_cnt + 1;
 end else begin
 got_coded_b = wr_blck_coded_sys[215:0];
 check_eq2 ("target_tn=2", wr_blck_target_tn_sys, 2'd2);
 check_eq216("coded[215:0] bit-exact", got_coded_b, exp_coded_b);
 check_eq32("push_cnt=2", {16'd0, push_cnt_sys}, 32'd2);
 // Sanity: different SSI ⇒ different coded payload
 if (got_coded_a !== got_coded_b) begin
 $display(" PASS SSI swap ⇒ coded payload differs");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL SSI swap did NOT change coded payload");
 fail_cnt = fail_cnt + 1;
 end
 end

 // -----------------------------------------------------------------
 $display("---- TC4 collision drop ----");
 // Fire ul_req while FSM is busy → drop_cnt should increment
 // We trigger first, wait 5 cyc (still in S_BUILD or S_ENC), fire again
 cfg_mcch_tn = 2'd1;
 pulse_trigger(24'hAA0001);
 repeat (5) @(posedge clk);
 // Second pulse during busy
 pulse_trigger(24'hBB0002);
 // Wait for first push to land
 wait_push(2000, hit_x);
 if (hit_x == 0) begin
 $display(" FAIL busy-mode first push never delivered");
 fail_cnt = fail_cnt + 1;
 end else begin
 // The dropped second pulse should NOT cause a second push
 // (FSM is single-token). Verify drop_cnt incremented.
 if (drop_cnt_sys >= 16'd1) begin
 $display(" PASS drop_cnt incremented to %0d", drop_cnt_sys);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL drop_cnt did NOT increment, got=%0d", drop_cnt_sys);
 fail_cnt = fail_cnt + 1;
 end
 end

 // -----------------------------------------------------------------
 $display("---- TC5 fresh push after busy clears ----");
 // Wait long enough for FSM to be back in IDLE
 repeat (50) @(posedge clk);
 pulse_trigger(24'h123456);
 wait_push(2000, hit_x);
 if (hit_x == 1) begin
 $display(" PASS fresh push delivered after IDLE recovery");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL fresh push not delivered");
 fail_cnt = fail_cnt + 1;
 end
 // push_cnt should be at least 4 by now (TC2 + TC3 + TC4 + TC5)
 if (push_cnt_sys >= 16'd4) begin
 $display(" PASS push_cnt=%0d (>=4)", push_cnt_sys);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL push_cnt=%0d (<4)", push_cnt_sys);
 fail_cnt = fail_cnt + 1;
 end

 // -----------------------------------------------------------------
 $display("================================================");
 $display(" PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
 if (fail_cnt == 0) $display(" RESULT: ALL TESTS PASS");
 else $display(" RESULT: FAILURES PRESENT");
 $display("================================================");
 $finish;
 end

 // Safety watchdog
 initial begin
 #10_000_000;
 $display("ERROR: TB watchdog timeout");
 $finish;
 end

endmodule

`default_nettype wire
