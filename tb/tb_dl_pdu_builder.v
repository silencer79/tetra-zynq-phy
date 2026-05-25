// =============================================================================
// tb_dl_pdu_builder.v — Phase X.6 shared DL-PDU build pipeline regression
//
// Standalone test of tetra_dl_pdu_builder.v (the {basic_slotgrant +
// mac_resource_dl_builder + sch_f_encoder} pipeline shared between
// MLE-FSM and Pre-Reply SlotGrant FSMs after the X.6 slice-saver
// refactor).
//
// Coverage:
// TC1 reset baseline — done=0, busy=0, coded=0
// TC2 AL-SETUP build — slot-grant pre-reply config; verify
// bit-exact against independent
// reference encoder chain
// TC3 BL-ADATA build — MLE-FSM ACCEPT-style config; non-zero
// MM body; verify bit-exact
// TC4 back-to-back — request2 after first done; both
// complete with correct coded payloads
// TC5 busy-protect — request asserted while busy; builder
// ignores spurious req (caller's job to
// gate via busy)
//
// Run:
// iverilog -g2001 -o /tmp/tb_dlb tb/tb_dl_pdu_builder.v \
// rtl/lmac/tetra_dl_pdu_builder.v \
// rtl/lmac/tetra_basic_slotgrant_encoder.v \
// rtl/lmac/tetra_mac_resource_dl_builder.v \
// rtl/lmac/tetra_sch_f_encoder.v
// vvp /tmp/tb_dlb
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dl_pdu_builder;
 reg clk = 1'b0;
 reg rst_n = 1'b0;
 always #5 clk = ~clk;

 // DUT inputs
 reg req_valid = 1'b0;
 reg [23:0] req_ssi = 24'd0;
 reg [2:0] req_addr_type = 3'd1;
 reg [3:0] req_llc_pdu_type = 4'd8;
 reg req_random_access_flag = 1'b1;
 reg [127:0]req_mm_pdu_bits = 128'd0;
 reg [7:0] req_mm_pdu_len_bits = 8'd0;
 reg [31:0] req_scramble_init = 32'd0;

 // DUT outputs
 wire done;
 wire [431:0]coded_bits;
 wire busy;

 tetra_dl_pdu_builder dut (
.clk (clk),
.rst_n (rst_n),
.req_valid (req_valid),
.req_ssi (req_ssi),
.req_addr_type (req_addr_type),
.req_llc_pdu_type (req_llc_pdu_type),
.req_random_access_flag (req_random_access_flag),
.req_mm_pdu_bits (req_mm_pdu_bits),
.req_mm_pdu_len_bits (req_mm_pdu_len_bits),
.req_mle_pd (3'b001),
.req_scramble_init (req_scramble_init),
 // Phase Y.1.c' — req_ns/req_nr default 0 to bit-id with the
 // pre-Y.1 builder pipeline (the legacy MLE-FSM and SlotGrant
 // callers still drive these to 0).
.req_ns (1'b0),
.req_nr (1'b0),
.done (done),
.coded_bits (coded_bits),
.busy (busy)
 );

 // -------------------------------------------------------------------------
 // Reference chain — independent instances of the same encoders, driven
 // step-by-step from a TB task. Pre-X.6 the FSM-internal pipeline was
 // exactly this sequence — TC2/TC3 verify the new wrapper produces
 // identical coded bits.
 // -------------------------------------------------------------------------
 reg ref_builder_start = 1'b0;
 reg [23:0] ref_ssi = 24'd0;
 reg [2:0] ref_addr_type = 3'd1;
 reg [3:0] ref_llc_pdu_type = 4'd8;
 reg ref_rand_acc = 1'b1;
 reg [127:0] ref_mm_bits = 128'd0;
 reg [7:0] ref_mm_len = 8'd0;
 reg [31:0] ref_scramble = 32'd0;

 wire [7:0] ref_sg_w;
 tetra_basic_slotgrant_encoder u_ref_sg (
.capacity_allocation (4'd0),
.granting_delay (4'd1),
.packed_element (ref_sg_w)
 );

 wire [267:0] ref_pdu_w;
 wire ref_pdu_valid_w;
 tetra_mac_resource_dl_builder #(
.PDU_BITS(268),
.LLC_BUF_BITS(144)
 ) u_ref_mac (
.clk (clk),
.rst_n (rst_n),
.start (ref_builder_start),
.ssi (ref_ssi),
.addr_type (ref_addr_type),
.ns (1'b0),
.nr (1'b0),
.llc_pdu_type (ref_llc_pdu_type),
.random_access_flag (ref_rand_acc),
.power_control_flag (1'b0),
.power_control_element (4'd0),
.slot_granting_flag (1'b1),
.slot_granting_element (ref_sg_w),
.chan_alloc_flag (1'b0),
.chan_alloc_element (32'd0),
.chan_alloc_element_len (5'd0),
.second_pdu_valid (1'b0),
.second_pdu_length_ind (6'd0),
.second_pdu_random_access_flag(1'b0),
.second_pdu_addr_type (3'd0),
.second_pdu_ssi (24'd0),
.second_pdu_tl_sdu (80'd0),
.second_pdu_tl_sdu_len (7'd0),
.second_pdu_pc_flag (1'b0),
.second_pdu_pc_element (4'd0),
.second_pdu_sg_flag (1'b0),
.second_pdu_sg_element (8'd0),
.second_pdu_ca_flag (1'b0),
.second_pdu_ca_element (32'd0),
.second_pdu_ca_element_len (5'd0),
.mm_pdu_bits (ref_mm_bits),
.mm_pdu_len_bits (ref_mm_len),
.mle_pd_in (3'b001),
.pdu_bits (ref_pdu_w),
.valid (ref_pdu_valid_w)
 );

 reg ref_enc_start = 1'b0;
 reg [267:0] ref_enc_info = 268'd0;
 wire [431:0] ref_coded_w;
 wire ref_coded_valid_w;
 tetra_sch_f_encoder u_ref_sch_f (
.clk (clk),
.rst_n (rst_n),
.encode_start (ref_enc_start),
.info_bits (ref_enc_info),
.scramble_init (ref_scramble),
.coded_bits (ref_coded_w),
.coded_valid (ref_coded_valid_w)
 );

 // Compute reference coded bits for given inputs.
 task automatic compute_ref;
 input [23:0] s;
 input [2:0] at;
 input [3:0] lpt;
 input ra;
 input [127:0] mmb;
 input [7:0] mml;
 input [31:0] sci;
 output [431:0] out_coded;
 integer guard;
 reg [431:0] cap;
 reg [267:0] cap_pdu;
 begin
 ref_ssi <= s;
 ref_addr_type <= at;
 ref_llc_pdu_type <= lpt;
 ref_rand_acc <= ra;
 ref_mm_bits <= mmb;
 ref_mm_len <= mml;
 ref_scramble <= sci;
 @(posedge clk);
 ref_builder_start <= 1'b1;
 @(posedge clk);
 ref_builder_start <= 1'b0;
 guard = 0;
 while (!ref_pdu_valid_w && guard < 200) begin
 @(posedge clk);
 guard = guard + 1;
 end
 cap_pdu = ref_pdu_w;
 @(posedge clk);
 ref_enc_info <= cap_pdu;
 ref_enc_start <= 1'b1;
 @(posedge clk);
 ref_enc_start <= 1'b0;
 guard = 0;
 cap = 432'd0;
 while (!ref_coded_valid_w && guard < 2000) begin
 @(posedge clk);
 guard = guard + 1;
 end
 cap = ref_coded_w;
 @(posedge clk);
 out_coded = cap;
 end
 endtask

 // Pulse req_valid for one cycle with field plane.
 task automatic pulse_req;
 input [23:0] s;
 input [2:0] at;
 input [3:0] lpt;
 input ra;
 input [127:0] mmb;
 input [7:0] mml;
 input [31:0] sci;
 begin
 req_ssi <= s;
 req_addr_type <= at;
 req_llc_pdu_type <= lpt;
 req_random_access_flag <= ra;
 req_mm_pdu_bits <= mmb;
 req_mm_pdu_len_bits <= mml;
 req_scramble_init <= sci;
 req_valid <= 1'b1;
 @(posedge clk);
 req_valid <= 1'b0;
 end
 endtask

 // Wait for done (or timeout)
 integer guard_i;
 task automatic wait_done;
 input integer max_cyc;
 output integer hit;
 begin
 hit = 0;
 for (guard_i = 0; guard_i < max_cyc; guard_i = guard_i + 1) begin
 @(posedge clk);
 if (done) begin
 hit = 1;
 disable wait_done;
 end
 end
 end
 endtask

 // -------------------------------------------------------------------------
 integer pass_cnt = 0;
 integer fail_cnt = 0;

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

 task automatic check_eq432;
 input [255:0] tag;
 input [431:0] got;
 input [431:0] exp;
 begin
 if (got === exp) begin
 $display(" PASS %0s coded[431:400]=0x%08h", tag, got[431:400]);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s", tag);
 $display(" got[431:288]= %h", got[431:288]);
 $display(" exp[431:288]= %h", exp[431:288]);
 $display(" got[287:144]= %h", got[287:144]);
 $display(" exp[287:144]= %h", exp[287:144]);
 $display(" got[143:0] = %h", got[143:0]);
 $display(" exp[143:0] = %h", exp[143:0]);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 // -------------------------------------------------------------------------
 reg [431:0] exp_a, exp_b, got_a, got_b;
 integer hit;

 initial begin
 // Reset
 rst_n = 1'b0;
 req_valid = 1'b0;
 repeat (4) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // -----------------------------------------------------------------
 $display("---- TC1 reset baseline ----");
 if (done === 1'b0 && busy === 1'b0 && coded_bits === 432'd0) begin
 $display(" PASS done=0 busy=0 coded=0");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL done=%b busy=%b coded[431:400]=0x%08h",
 done, busy, coded_bits[431:400]);
 fail_cnt = fail_cnt + 1;
 end

 // -----------------------------------------------------------------
 $display("---- TC2 AL-SETUP slot-grant config (Pre-Reply style) ----");
 compute_ref(24'h282F91, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0, exp_a);
 @(posedge clk);
 pulse_req(24'h282F91, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0);
 wait_done(4000, hit);
 if (hit == 0) begin
 $display(" FAIL no done within 4000 cyc");
 fail_cnt = fail_cnt + 1;
 end else begin
 got_a = coded_bits;
 check_eq432("AL-SETUP coded bit-exact", got_a, exp_a);
 end

 // -----------------------------------------------------------------
 $display("---- TC3 BL-ADATA + non-zero MM body (MLE-ACCEPT style) ----");
 // 100-bit-equiv MM body — top 100 bits filled with a recognisable
 // pattern; len=100. This exercises the mm_pdu_bits path that the
 // pre-Reply path leaves at 0.
 compute_ref(24'hABCDEF, 3'd1, 4'd0, 1'b0,
 128'h2F4D610000_00000000_FFFF_F800_0000_0000,
 8'd100, 32'h1234_5678, exp_b);
 @(posedge clk);
 pulse_req(24'hABCDEF, 3'd1, 4'd0, 1'b0,
 128'h2F4D610000_00000000_FFFF_F800_0000_0000,
 8'd100, 32'h1234_5678);
 wait_done(4000, hit);
 if (hit == 0) begin
 $display(" FAIL no done within 4000 cyc");
 fail_cnt = fail_cnt + 1;
 end else begin
 got_b = coded_bits;
 check_eq432("BL-ADATA coded bit-exact", got_b, exp_b);
 if (got_a !== got_b) begin
 $display(" PASS config swap ⇒ coded payload differs");
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL config swap did NOT change coded payload");
 fail_cnt = fail_cnt + 1;
 end
 end

 // -----------------------------------------------------------------
 $display("---- TC4 back-to-back encode ----");
 compute_ref(24'h111111, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0, exp_a);
 @(posedge clk);
 pulse_req(24'h111111, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0);
 wait_done(4000, hit);
 if (hit == 0) begin
 $display(" FAIL back-to-back #1 timed out");
 fail_cnt = fail_cnt + 1;
 end else begin
 check_eq432("back-to-back #1 bit-exact", coded_bits, exp_a);
 end
 // Wait one cycle, then immediately request second build
 @(posedge clk);
 compute_ref(24'h222222, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0, exp_b);
 @(posedge clk);
 pulse_req(24'h222222, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0);
 wait_done(4000, hit);
 if (hit == 0) begin
 $display(" FAIL back-to-back #2 timed out");
 fail_cnt = fail_cnt + 1;
 end else begin
 check_eq432("back-to-back #2 bit-exact", coded_bits, exp_b);
 end

 // -----------------------------------------------------------------
 $display("---- TC5 busy-protect (req while busy is ignored) ----");
 // Kick a long build, then assert req_valid mid-flight — the
 // builder must NOT restart (caller's responsibility, but verify
 // wrapper FSM is robust to it).
 @(posedge clk);
 pulse_req(24'h333333, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0);
 // Spurious request 100 cyc into the build.
 repeat (100) @(posedge clk);
 if (busy !== 1'b1) begin
 $display(" FAIL builder not busy at cyc 100");
 fail_cnt = fail_cnt + 1;
 end
 req_ssi <= 24'hDEADBE;
 req_valid <= 1'b1;
 @(posedge clk);
 req_valid <= 1'b0;
 // Wait for original done — coded must reflect the original ssi=0x333333,
 // not the spurious 0xDEADBE.
 wait_done(4000, hit);
 if (hit == 0) begin
 $display(" FAIL busy-protect run timed out");
 fail_cnt = fail_cnt + 1;
 end else begin
 compute_ref(24'h333333, 3'd1, 4'd8, 1'b1, 128'd0, 8'd0, 32'd0, exp_a);
 @(posedge clk);
 // coded_bits is latched after done — re-fetch once
 // (coded_bits remains stable until next build completes).
 check_eq432("busy-protect: coded matches ORIGINAL ssi", coded_bits, exp_a);
 end

 // -----------------------------------------------------------------
 $display("================================================");
 $display(" PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
 if (fail_cnt == 0) $display(" RESULT: ALL TESTS PASS");
 else $display(" RESULT: FAILURES PRESENT");
 $display("================================================");
 $finish;
 end

 initial begin
 #20_000_000;
 $display("ERROR: TB watchdog timeout");
 $finish;
 end

endmodule

`default_nettype wire
