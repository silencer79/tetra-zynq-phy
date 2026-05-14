// =============================================================================
// tb_reply_mailbox.v — Phase X.2 Reply-Pull Mailbox regression
// Phase Y.2 raw-mode (Variante A) coverage
// =============================================================================
//
// Coverage:
// TC1 reset baseline — all 16 words read 0, all field outputs 0
// TC2 write W0..W8 with M2 ref ACCEPT body, verify field outputs:
// ssi=0x282F91, la=0x0042, addr_type=1, result=0,
// gila_gssi=0x2F4D61, gila_class=4, gila_lifetime=1, gila_present=1,
// encryption=0, auth_result=1
// (also implicitly: raw_mode_flag=0 because W9 untouched)
// TC3 GO pulse propagation (mb_go_pulse_sys mirrors go_pulse_sys for 1 cyc)
// TC4 re-write W4 (gila_gssi) with a new value (0x123456) — field updates,
// other fields unchanged
// TC5 Phase Y.2 raw-mode: write W9..W13 with raw_mode_flag=1, raw_mm_len=64,
// raw_ns=1, raw_nr=0, and a 64-bit Ref grpack body, verify the
// five new field outputs report correctly and W0..W8 fields stay
// whatever TC2/TC4 left them at (no aliasing).
//
// Run:
// iverilog -g2001 -o /tmp/tb_replmb tb/tb_reply_mailbox.v \
// rtl/lmac/tetra_reply_mailbox.v \
// rtl/lmac/tetra_indirect_mailbox_wr.v
// vvp /tmp/tb_replmb
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_reply_mailbox;
 reg clk = 1'b0;
 always #5 clk = ~clk;
 reg rst_n = 1'b0;

 reg [3:0] index = 4'd0;
 reg [31:0] wdata = 32'd0;
 reg we = 1'b0;
 reg go = 1'b0;

 wire [31:0] rdata;
 wire [23:0] mb_ssi;
 wire [13:0] mb_la;
 wire [2:0] mb_addr_type;
 wire [1:0] mb_result;
 wire [23:0] mb_gila_gssi;
 wire [2:0] mb_gila_class;
 wire [1:0] mb_gila_lifetime;
 wire mb_gila_present;
 wire [1:0] mb_encryption;
 wire [1:0] mb_auth_result;
 wire mb_go_pulse;

 // Phase Y.2 — raw-mode field outputs
 wire mb_raw_mode_flag;
 wire [127:0] mb_raw_mm_bits;
 wire [7:0] mb_raw_mm_len;
 wire mb_raw_ns;
 wire mb_raw_nr;

 tetra_reply_mailbox dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.index_sys (index),
.wdata_sys (wdata),
.wr_en_sys (we),
.go_pulse_sys (go),
.rdata_sys (rdata),
.mb_ssi_sys (mb_ssi),
.mb_la_sys (mb_la),
.mb_addr_type_sys (mb_addr_type),
.mb_result_sys (mb_result),
.mb_gila_gssi_sys (mb_gila_gssi),
.mb_gila_class_sys (mb_gila_class),
.mb_gila_lifetime_sys (mb_gila_lifetime),
.mb_gila_present_sys (mb_gila_present),
.mb_encryption_sys (mb_encryption),
.mb_auth_result_sys (mb_auth_result),
.mb_go_pulse_sys (mb_go_pulse),
.mb_raw_mode_flag_sys (mb_raw_mode_flag),
.mb_raw_mm_bits_sys (mb_raw_mm_bits),
.mb_raw_mm_len_sys (mb_raw_mm_len),
.mb_raw_ns_sys (mb_raw_ns),
.mb_raw_nr_sys (mb_raw_nr)
 );

 integer pass_cnt = 0;
 integer fail_cnt = 0;
 reg [31:0] read_w;

 task automatic read_word;
 input [3:0] idx;
 output [31:0] word;
 begin
 index = idx;
 we = 1'b0;
 #1;
 word = rdata;
 end
 endtask

 task automatic write_word;
 input [3:0] idx;
 input [31:0] data;
 begin
 @(posedge clk);
 index <= idx;
 wdata <= data;
 we <= 1'b1;
 @(posedge clk);
 we <= 1'b0;
 @(posedge clk);
 end
 endtask

 task automatic check32;
 input [255:0] tag;
 input [31:0] got;
 input [31:0] expected;
 begin
 if (got === expected) begin
 $display(" PASS %0s got=0x%08h", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=0x%08h expected=0x%08h",
 tag, got, expected);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task automatic check_eq;
 input [255:0] tag;
 input integer got;
 input integer expected;
 begin
 if (got === expected) begin
 $display(" PASS %0s got=%0d", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=%0d expected=%0d",
 tag, got, expected);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 integer i;

 initial begin
 $display("=========================================================");
 $display(" tb_reply_mailbox — Phase X.2 mailbox regression");
 $display("=========================================================");

 rst_n = 1'b0;
 repeat (5) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // -------------------------------------------------------------
 // TC1 — reset baseline
 // -------------------------------------------------------------
 $display("");
 $display("TC1 reset baseline — all words read 0, fields all 0");

 for (i = 0; i < 16; i = i + 1) begin
 read_word(i[3:0], read_w);
 end
 // Last read leaves index=15, rdata=W15
 check32("TC1.W15 read=0", read_w, 32'd0);
 check_eq("TC1.mb_ssi=0", mb_ssi, 0);
 check_eq("TC1.mb_la=0", mb_la, 0);
 check_eq("TC1.mb_addr_type=0", mb_addr_type, 0);
 check_eq("TC1.mb_result=0", mb_result, 0);
 check_eq("TC1.mb_gila_gssi=0", mb_gila_gssi, 0);
 check_eq("TC1.mb_gila_class=0", mb_gila_class, 0);
 check_eq("TC1.mb_gila_lifetime=0", mb_gila_lifetime, 0);
 check_eq("TC1.mb_gila_present=0", mb_gila_present, 0);
 check_eq("TC1.mb_encryption=0", mb_encryption, 0);
 check_eq("TC1.mb_auth_result=0", mb_auth_result, 0);

 // -------------------------------------------------------------
 // TC2 — write M2 ref ACCEPT body
 // ssi=0x282F91 (MTP3550 ISSI from reference_test_setup_mtp3550_only.md)
 // la=0x0042
 // addr_type=1 (ETSI Ssi+EventLabel — bluestation enum value 1)
 // result=0 (accept)
 // gila_gssi=0x2F4D61 (Ref GSSI)
 // gila_class=4, gila_lifetime=1, gila_present=1 (M2-defaults)
 // encryption=0, auth_result=1 (success)
 // -------------------------------------------------------------
 $display("");
 $display("TC2 write M2 ref ACCEPT body, verify field outputs");

 write_word(4'd0, 32'h00282F91); // W0 ssi
 write_word(4'd1, 32'h00000042); // W1 la
 write_word(4'd2, 32'h00000001); // W2 addr_type=1
 write_word(4'd3, 32'h00000000); // W3 result=0
 write_word(4'd4, 32'h002F4D61); // W4 gila_gssi
 // W5: gila_class=4 in [4:2], gila_lifetime=1 in [1:0]
 // = (4<<2) | 1 = 0x11
 write_word(4'd5, 32'h00000011);
 write_word(4'd6, 32'h00000001); // W6 gila_present=1
 write_word(4'd7, 32'h00000000); // W7 encryption=0
 write_word(4'd8, 32'h00000001); // W8 auth_result=1

 check_eq("TC2.mb_ssi=0x282F91", mb_ssi, 24'h282F91);
 check_eq("TC2.mb_la=0x0042", mb_la, 14'h0042);
 check_eq("TC2.mb_addr_type=1", mb_addr_type, 1);
 check_eq("TC2.mb_result=0", mb_result, 0);
 check_eq("TC2.mb_gila_gssi=0x2F4D61", mb_gila_gssi, 24'h2F4D61);
 check_eq("TC2.mb_gila_class=4", mb_gila_class, 4);
 check_eq("TC2.mb_gila_lifetime=1", mb_gila_lifetime, 1);
 check_eq("TC2.mb_gila_present=1", mb_gila_present, 1);
 check_eq("TC2.mb_encryption=0", mb_encryption, 0);
 check_eq("TC2.mb_auth_result=1", mb_auth_result, 1);

 // Read-back
 read_word(4'd0, read_w);
 check32("TC2.W0 readback", read_w, 32'h00282F91);
 read_word(4'd4, read_w);
 check32("TC2.W4 readback", read_w, 32'h002F4D61);
 read_word(4'd5, read_w);
 check32("TC2.W5 readback", read_w, 32'h00000011);

 // -------------------------------------------------------------
 // TC3 — GO pulse propagation
 // -------------------------------------------------------------
 $display("");
 $display("TC3 GO pulse propagation");

 @(posedge clk);
 go <= 1'b1;
 @(posedge clk);
 check_eq("TC3.go_pulse high", mb_go_pulse, 1);
 go <= 1'b0;
 @(posedge clk);
 check_eq("TC3.go_pulse low after 1cy", mb_go_pulse, 0);

 // -------------------------------------------------------------
 // TC4 — re-write W4 (gila_gssi) — field updates, others stable
 // -------------------------------------------------------------
 $display("");
 $display("TC4 re-write W4 (gila_gssi) with new value");

 write_word(4'd4, 32'h00123456);
 check_eq("TC4.mb_gila_gssi=0x123456", mb_gila_gssi, 24'h123456);
 // Other fields unchanged
 check_eq("TC4.mb_ssi unchanged", mb_ssi, 24'h282F91);
 check_eq("TC4.mb_la unchanged", mb_la, 14'h0042);
 check_eq("TC4.mb_gila_class unchanged",mb_gila_class, 4);
 check_eq("TC4.mb_gila_lifetime unchanged", mb_gila_lifetime, 1);
 check_eq("TC4.mb_auth_result unchanged", mb_auth_result, 1);

 // -------------------------------------------------------------
 // TC4b — raw-mode flag still 0 (W9 never written) — mm=2 path
 // -------------------------------------------------------------
 check_eq("TC4b.raw_mode_flag=0", mb_raw_mode_flag, 0);
 check_eq("TC4b.raw_mm_len=0", mb_raw_mm_len, 0);
 check_eq("TC4b.raw_ns=0", mb_raw_ns, 0);
 check_eq("TC4b.raw_nr=0", mb_raw_nr, 0);

 // -------------------------------------------------------------
 // TC5 — Phase Y.2 raw-mode (mm=11 GROUP-ACK) staging.
 // W9 = raw_mode_flag=1 | raw_nr=0 | raw_ns=1 | raw_mm_len=64
 // = (1<<31) | (0<<9) | (1<<8) | 64
 // = 0x80000140
 // W10 = raw_mm_bits[31:0] (low word) = 0xDEADBEEF
 // W11 = raw_mm_bits[63:32] = 0xCAFEBABE
 // W12 = raw_mm_bits[95:64] = 0x12345678
 // W13 = raw_mm_bits[127:96] = 0x00B2B826
 //
 // Expected mb_raw_mm_bits = {W13, W12, W11, W10}
 // = 0x00B2B826_12345678_CAFEBABE_DEADBEEF
 // -------------------------------------------------------------
 $display("");
 $display("TC5 Phase Y.2 raw-mode (mm=11) — W9..W13 staging");

 write_word(4'd9, 32'h80000140);
 write_word(4'd10, 32'hDEADBEEF);
 write_word(4'd11, 32'hCAFEBABE);
 write_word(4'd12, 32'h12345678);
 write_word(4'd13, 32'h00B2B826);

 check_eq("TC5.raw_mode_flag=1", mb_raw_mode_flag, 1);
 check_eq("TC5.raw_mm_len=64", mb_raw_mm_len, 64);
 check_eq("TC5.raw_ns=1", mb_raw_ns, 1);
 check_eq("TC5.raw_nr=0", mb_raw_nr, 0);
 if (mb_raw_mm_bits === 128'h00B2B826_12345678_CAFEBABE_DEADBEEF) begin
 $display(" PASS TC5.raw_mm_bits got=0x%032h", mb_raw_mm_bits);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL TC5.raw_mm_bits got=0x%032h", mb_raw_mm_bits);
 fail_cnt = fail_cnt + 1;
 end

 // mm=2 fields untouched
 check_eq("TC5.mb_ssi unchanged", mb_ssi, 24'h282F91);
 check_eq("TC5.mb_addr_type unchanged", mb_addr_type, 1);

 // Re-write W9 with raw_mode_flag=0 — should clear the flag and
 // bring us back to mm=2 path (raw_mm_bits remain in W10..W13 but
 // are ignored by downstream FSM mux).
 write_word(4'd9, 32'h00000000);
 check_eq("TC5.raw_mode_flag=0 after W9 clear", mb_raw_mode_flag, 0);

 // -------------------------------------------------------------
 // Summary
 // -------------------------------------------------------------
 $display("");
 $display("=========================================================");
 $display(" tb_reply_mailbox SUMMARY pass=%0d fail=%0d",
 pass_cnt, fail_cnt);
 $display("=========================================================");
 if (fail_cnt == 0)
 $display(" RESULT: PASS");
 else
 $display(" RESULT: FAIL");
 $finish;
 end

 initial begin
 #200000;
 $display("FAIL: timeout");
 $finish;
 end

endmodule

`default_nettype wire
