// =============================================================================
// tb_ul_demand_reassembly.v — Phase 7 F.1 / G.x unit TB
// =============================================================================
//
// Verifies tetra_ul_demand_reassembly.v (generic TM-SDU reassembly) against:
// - reference_demand_reassembly_bitexact.md (corrected 2026-04-26)
// - docs/PROTOCOL.md §6.4a
// - docs/ARCHITECTURE.md §9.8.1
//
// On-air sequence (Phase G.x — body now starts at the LLC header):
// UL#0 SCH/HU MAC-ACCESS frag=1 → bits[30..91] = 62 bit fragment 1 (TM-SDU)
// UL#1 SCH/HU MAC-END-HU → bits[ 7..91] = 85 bit fragment 2
// reassembled_body[146:0] = ul0_bits[30..91] ++ ul1_bits[7..91] (147 bit)
//
// Note: end_hu still occupies body[84:0], so the GSSI (UL#1 bits[48..71])
// stays at body[43:20] — the 44→62 frag1 widening only grows the MSB end.
//
// Test cases:
// T1: frag1 arrives, no end_hu within T0 → drop_cnt = 1, no reassembled.
// T2: ref frag1 + ref end_hu within T0 → reassembled_valid pulse
// AND body matches the bit-exact splice; reassembled_ssi = frag1_ssi;
// reassembled_meta echoes the latched frag1_meta.
// T3: Two SSIs in flight; second frag1 takes slot 1; both end_hu pulses
// resolve correctly → reassembled_cnt = 2.
// T4: MTP3550-style end_hu hex → GSSI=0x000001 at the documented position.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_demand_reassembly;

 localparam integer CLK_PERIOD = 10;

 reg clk = 1'b0;
 always #(CLK_PERIOD/2) clk = ~clk;
 reg rst_n;

 // DUT inputs
 reg [3:0] t0_frames;
 reg frame_tick;
 reg frag1_pulse;
 reg [23:0] frag1_ssi;
 reg [61:0] frag1_bits;
 reg [12:0] frag1_meta;
 reg end_hu_pulse;
 reg [23:0] end_hu_ssi;
 reg [84:0] end_hu_bits;

 // DUT outputs
 wire reassembled_valid_w;
 wire [146:0] reassembled_body_w;
 wire [23:0] reassembled_ssi_w;
 wire [12:0] reassembled_meta_w;
 wire [15:0] reassembled_cnt_w;
 wire [15:0] drop_cnt_w;
 wire [1:0] busy_slots_w;

 tetra_ul_demand_reassembly #(
.T0_FRAMES_DEFAULT(2)
 ) u_dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.t0_frames_sys (t0_frames),
.frame_tick_sys (frame_tick),
.frag1_pulse_sys (frag1_pulse),
.frag1_ssi_sys (frag1_ssi),
.frag1_bits_sys (frag1_bits),
.frag1_meta_sys (frag1_meta),
.end_hu_pulse_sys (end_hu_pulse),
.end_hu_ssi_sys (end_hu_ssi),
.end_hu_bits_sys (end_hu_bits),
.reassembled_valid_sys(reassembled_valid_w),
.reassembled_body_sys (reassembled_body_w),
.reassembled_ssi_sys (reassembled_ssi_w),
.reassembled_meta_sys (reassembled_meta_w),
.reassembled_cnt_sys (reassembled_cnt_w),
.drop_cnt_sys (drop_cnt_w),
.busy_slots_sys (busy_slots_w)
 );

 integer pass_cnt;
 integer fail_cnt;

 // -------------------------------------------------------------------
 // Helpers
 // -------------------------------------------------------------------

 // Pack 12 bytes (MSB-first within each byte) into 92 bits. bit[0] of
 // the 92-bit buffer is the on-air MSB of byte[0]. Same convention the
 // parser uses on info_bits_sys.
 function [91:0] pack92;
 input [7:0] b0, b1, b2, b3, b4, b5;
 input [7:0] b6, b7, b8, b9, b10, b11;
 integer k;
 reg [7:0] bytes [0:11];
 begin
 bytes[ 0] = b0; bytes[ 1] = b1; bytes[ 2] = b2; bytes[ 3] = b3;
 bytes[ 4] = b4; bytes[ 5] = b5; bytes[ 6] = b6; bytes[ 7] = b7;
 bytes[ 8] = b8; bytes[ 9] = b9; bytes[10] = b10; bytes[11] = b11;
 pack92 = 92'd0;
 for (k = 0; k < 92; k = k + 1)
 pack92[k] = (bytes[k/8] >> (7 - (k%8))) & 1'b1;
 end
 endfunction

 // Extract bits[30..91] (62 bits) from a 92-bit info buffer, MSB-first
 // into the 62-bit bus. bus[61] = info[30], bus[0] = info[91].
 function [61:0] slice62_from_30;
 input [91:0] info;
 integer k;
 begin
 slice62_from_30 = 62'd0;
 for (k = 0; k < 62; k = k + 1)
 slice62_from_30[61 - k] = info[30 + k];
 end
 endfunction

 // Extract bits[7..91] (85 bits) from a 92-bit info buffer, MSB-first.
 // bus[84] = info[7], bus[0] = info[91].
 function [84:0] slice85_from_7;
 input [91:0] info;
 integer k;
 begin
 slice85_from_7 = 85'd0;
 for (k = 0; k < 85; k = k + 1)
 slice85_from_7[84 - k] = info[7 + k];
 end
 endfunction

 task tick;
 begin
 @(posedge clk); #1;
 end
 endtask

 task drive_frag1;
 input [23:0] ssi;
 input [61:0] bits62;
 input [12:0] meta;
 begin
 @(posedge clk); #1;
 frag1_pulse = 1'b1;
 frag1_ssi = ssi;
 frag1_bits = bits62;
 frag1_meta = meta;
 @(posedge clk); #1;
 frag1_pulse = 1'b0;
 end
 endtask

 task drive_end_hu;
 input [23:0] ssi;
 input [84:0] bits85;
 begin
 @(posedge clk); #1;
 end_hu_pulse = 1'b1;
 end_hu_ssi = ssi;
 end_hu_bits = bits85;
 @(posedge clk); #1;
 end_hu_pulse = 1'b0;
 end
 endtask

 task pulse_frame_tick;
 begin
 @(posedge clk); #1;
 frame_tick = 1'b1;
 @(posedge clk); #1;
 frame_tick = 1'b0;
 end
 endtask

 task expect_eq32;
 input [255:0] label;
 input [31:0] got;
 input [31:0] exp_v;
 begin
 if (got === exp_v) begin
 $display(" PASS %-40s got=0x%08X", label, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %-40s got=0x%08X exp=0x%08X", label, got, exp_v);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task expect_eq147;
 input [255:0] label;
 input [146:0] got;
 input [146:0] exp_v;
 begin
 if (got === exp_v) begin
 $display(" PASS %-40s got=0x%037X", label, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %-40s", label);
 $display(" got=0x%037X", got);
 $display(" exp=0x%037X", exp_v);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 // -------------------------------------------------------------------
 // Reference vectors — bit-exact from corrected memory + PROTOCOL.md
 // -------------------------------------------------------------------

 // Ref UL#0: 01 41 7F A7 01 12 66 34 20 C1 22 60 (Sepura, ITSI=0x282FF4)
 // Ref UL#1: D4 1C 3C 02 40 50 2F 4D 61 20 00 00 (GSSI=0x2F4D61)
 //
 // MTP3550 UL#0: 01 41 7C 8F 01 12 66 34 20 C1 22 60 (ssi=0x282F91)
 // MTP3550 UL#6: D4 1C 3C 02 40 50 00 00 01 20 00 00 (GSSI=0x000001)

 wire [91:0] ref_ul0_w = pack92(
 8'h01, 8'h41, 8'h7F, 8'hA7, 8'h01, 8'h12,
 8'h66, 8'h34, 8'h20, 8'hC1, 8'h22, 8'h60
 );
 wire [91:0] ref_ul1_w = pack92(
 8'hD4, 8'h1C, 8'h3C, 8'h02, 8'h40, 8'h50,
 8'h2F, 8'h4D, 8'h61, 8'h20, 8'h00, 8'h00
 );
 wire [91:0] mtp_ul0_w = pack92(
 8'h01, 8'h41, 8'h7C, 8'h8F, 8'h01, 8'h12,
 8'h66, 8'h34, 8'h20, 8'hC1, 8'h22, 8'h60
 );
 wire [91:0] mtp_ul1_w = pack92(
 8'hD4, 8'h1C, 8'h3C, 8'h02, 8'h40, 8'h50,
 8'h00, 8'h00, 8'h01, 8'h20, 8'h00, 8'h00
 );

 wire [61:0] ref_frag1_w = slice62_from_30(ref_ul0_w);
 wire [84:0] ref_end_hu_w = slice85_from_7(ref_ul1_w);
 wire [61:0] mtp_frag1_w = slice62_from_30(mtp_ul0_w);
 wire [84:0] mtp_end_hu_w = slice85_from_7(mtp_ul1_w);

 // Expected reassembled body = frag1 (62 MSB) ++ end_hu (85 LSB) = 147 bit.
 wire [146:0] ref_body_exp_w = {ref_frag1_w, ref_end_hu_w};
 wire [146:0] mtp_body_exp_w = {mtp_frag1_w, mtp_end_hu_w};

 // Test meta bundles (arbitrary but distinct; verify pass-through).
 // [12:9]=mm_type, [8:6]=mle_disc, [5:2]=llc_pdu_type, [1]=ns, [0]=opt
 localparam [12:0] REF_META = 13'b0010_010_0001_1_0; // mm=2,mle=2,llc=BL-DATA,ns=1
 localparam [12:0] MTP_META = 13'b0111_001_0000_0_1; // mm=7,mle=1,llc=BL-ADATA,opt=1

 // -------------------------------------------------------------------
 // Initial sequence
 // -------------------------------------------------------------------
 initial begin
 $dumpfile("sim_out/tb_ul_demand_reassembly.vcd");
 $dumpvars(0, tb_ul_demand_reassembly);

 rst_n = 1'b0;
 t0_frames = 4'd0; // → use default (2)
 frame_tick = 1'b0;
 frag1_pulse = 1'b0;
 frag1_ssi = 24'd0;
 frag1_bits = 62'd0;
 frag1_meta = 13'd0;
 end_hu_pulse = 1'b0;
 end_hu_ssi = 24'd0;
 end_hu_bits = 85'd0;
 pass_cnt = 0;
 fail_cnt = 0;

 repeat (4) tick;
 rst_n = 1'b1;
 repeat (4) tick;

 // Show first the bit-exact derivation matches the spec hex slice.
 $display("------------------------------------------------------------------");
 $display("Reference vectors:");
 $display(" ref_ul0 hex = 01 41 7F A7 01 12 66 34 20 C1 22 60");
 $display(" ref_frag1[61:0] = 0x%016X (62 bit, info[30..91])", ref_frag1_w);
 $display(" ref_ul1 hex = D4 1C 3C 02 40 50 2F 4D 61 20 00 00");
 $display(" ref_end_hu[84:0] = 0x%022X", ref_end_hu_w);
 $display(" expected body[146:0] = 0x%037X", ref_body_exp_w);
 $display("------------------------------------------------------------------");

 // ---------------------------------------------------------------
 // T1: frag1 alone, T0-timeout
 // ---------------------------------------------------------------
 $display("\n[T1] frag1 alone, T0=2, no end_hu → drop_cnt should be 1");
 drive_frag1(24'h282FF4, ref_frag1_w, REF_META);
 expect_eq32("T1 occ_after_frag1", {30'd0, busy_slots_w}, 32'd1);
 // Tick T0+1 frames
 pulse_frame_tick; // t0_left: 2 → 1
 pulse_frame_tick; // t0_left: 1 → 0 + slot freed + drop_cnt++
 repeat (4) tick;
 expect_eq32("T1 drop_cnt", {16'd0, drop_cnt_w}, 32'd1);
 expect_eq32("T1 reass_cnt", {16'd0, reassembled_cnt_w}, 32'd0);
 expect_eq32("T1 occ_after_t0", {30'd0, busy_slots_w}, 32'd0);

 // ---------------------------------------------------------------
 // T2: ref frag1 + end_hu within T0, body bit-exact + meta echoed
 // ---------------------------------------------------------------
 $display("\n[T2] ref frag1 + end_hu within T0 → reassembled_valid + body bit-exact");
 drive_frag1(24'h282FF4, ref_frag1_w, REF_META);
 // No frame_tick — within T0
 drive_end_hu(24'h282FF4, ref_end_hu_w);
 // The DUT registers reassembled_body on the same cycle that
 // end_hu_pulse fires; capture is one tick after `drive_end_hu`
 // returns (it ends right after the pulse).
 @(posedge clk); #1;
 expect_eq32("T2 reass_cnt", {16'd0, reassembled_cnt_w}, 32'd1);
 expect_eq32("T2 drop_cnt_unchanged", {16'd0, drop_cnt_w}, 32'd1);
 expect_eq32("T2 reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00282FF4);
 expect_eq32("T2 reass_meta", {19'd0, reassembled_meta_w}, {19'd0, REF_META});
 expect_eq147("T2 reass_body_bitexact", reassembled_body_w, ref_body_exp_w);
 expect_eq32("T2 slot_freed", {30'd0, busy_slots_w}, 32'd0);

 // ---------------------------------------------------------------
 // T3: two simultaneous reassemblies, different SSI
 // ---------------------------------------------------------------
 $display("\n[T3] two SSIs in flight → both reassemble correctly");
 drive_frag1(24'hAAAA01, ref_frag1_w, REF_META); // → slot 0
 drive_frag1(24'hBBBB02, mtp_frag1_w, MTP_META); // → slot 1
 expect_eq32("T3 both_slots_occ", {30'd0, busy_slots_w}, 32'd3);
 // Resolve B first then A — SSIs must route to the right slot.
 drive_end_hu(24'hBBBB02, mtp_end_hu_w);
 @(posedge clk); #1;
 expect_eq32("T3 first_reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00BBBB02);
 expect_eq32("T3 first_reass_meta", {19'd0, reassembled_meta_w}, {19'd0, MTP_META});
 expect_eq32("T3 reass_cnt_2", {16'd0, reassembled_cnt_w}, 32'd2);
 drive_end_hu(24'hAAAA01, ref_end_hu_w);
 @(posedge clk); #1;
 expect_eq32("T3 second_reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00AAAA01);
 expect_eq32("T3 second_reass_meta", {19'd0, reassembled_meta_w}, {19'd0, REF_META});
 expect_eq32("T3 reass_cnt_3", {16'd0, reassembled_cnt_w}, 32'd3);
 expect_eq32("T3 drop_cnt_unchanged", {16'd0, drop_cnt_w}, 32'd1);
 expect_eq32("T3 all_slots_freed", {30'd0, busy_slots_w}, 32'd0);

 // ---------------------------------------------------------------
 // T4: MTP3550-style hex, GSSI=0x000001 visible in body
 // ---------------------------------------------------------------
 $display("\n[T4] MTP3550 frag1+end_hu → body contains GSSI=0x000001");
 drive_frag1(24'h282F91, mtp_frag1_w, MTP_META);
 drive_end_hu(24'h282F91, mtp_end_hu_w);
 @(posedge clk); #1;
 expect_eq32("T4 reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00282F91);
 expect_eq147("T4 body_bitexact", reassembled_body_w, mtp_body_exp_w);

 // GSSI is in UL#1 bits[48..71], i.e. end_hu_bits[43:20], which sits at
 // body[43:20] (end_hu occupies the low 85 bits regardless of frag1 width).
 begin: check_gssi_pos
 reg [23:0] gssi_field;
 integer kk;
 gssi_field = 24'd0;
 for (kk = 0; kk < 24; kk = kk + 1)
 gssi_field[23 - kk] = reassembled_body_w[43 - kk];
 expect_eq32("T4 gssi_in_body", {8'd0, gssi_field}, 32'h00000001);
 end

 // Same GSSI-position check for the ref body.
 $display("\n[T2b] same GSSI-position check on body");
 drive_frag1(24'h282FF4, ref_frag1_w, REF_META);
 drive_end_hu(24'h282FF4, ref_end_hu_w);
 @(posedge clk); #1;
 begin: check_ref_gssi_pos
 reg [23:0] ref_gssi;
 integer kk2;
 ref_gssi = 24'd0;
 for (kk2 = 0; kk2 < 24; kk2 = kk2 + 1)
 ref_gssi[23 - kk2] = reassembled_body_w[43 - kk2];
 expect_eq32("T2b ref_gssi_in_body", {8'd0, ref_gssi}, 32'h002F4D61);
 end

 // ---------------------------------------------------------------
 // Summary
 // ---------------------------------------------------------------
 $display("\n========================================================");
 $display("tb_ul_demand_reassembly: PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
 if (fail_cnt == 0)
 $display("RESULT: PASS");
 else
 $display("RESULT: FAIL");
 $display("========================================================");
 $finish;
 end

 initial begin
 #200_000;
 $display("TIMEOUT");
 $fatal;
 end

endmodule

`default_nettype wire
