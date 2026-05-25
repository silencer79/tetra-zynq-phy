// =============================================================================
// tb_indirect_mailbox.v — Phase Y.1.0 generic indirect-mailbox (Read-Side) TB
// =============================================================================
//
// Coverage:
// TC1 reset baseline — pending=0, drop_cnt=0, data_out=0
// TC2 single push (push_valid pulse) → pending=1, ack → pending=0;
// with data_words populated, indirect read returns expected payload
// TC3 push while pending=1 → drop_cnt++, data_words mux unaffected by push
// TC4 saturate drop_cnt at 0xFFFF (no wrap)
// TC5 read indirect: index 0..15, data_out matches data_words[index]
//
// Run:
// iverilog -g2001 -o /tmp/tb_imbox tb/tb_indirect_mailbox.v \
// rtl/lmac/tetra_indirect_mailbox.v
// vvp /tmp/tb_imbox
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_indirect_mailbox;
 reg clk = 1'b0;
 always #5 clk = ~clk;
 reg rst_n = 1'b0;

 reg [3:0] index = 4'd0;
 reg push_valid = 1'b0;
 reg push_drop = 1'b0;
 reg ack_pulse = 1'b0;

 // Provide a non-zero word array so we can verify the indirect mux
 reg [31:0] words [0:15];
 wire [16*32-1:0] words_flat;

 genvar gi;
 generate
 for (gi = 0; gi < 16; gi = gi + 1) begin: g_pack
 assign words_flat[gi*32 +: 32] = words[gi];
 end
 endgenerate

 wire pending;
 wire [15:0] drop_cnt;
 wire [31:0] data_out;

 tetra_indirect_mailbox #(
.NUM_WORDS (16),
.INDEX_WIDTH (4)
 ) dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.data_words_sys (words_flat),
.push_valid_sys (push_valid),
.push_drop_sys (push_drop),
.index_sys (index),
.ack_pulse_sys (ack_pulse),
.pending_sys (pending),
.drop_cnt_sys (drop_cnt),
.data_out_sys (data_out)
 );

 integer pass_cnt = 0;
 integer fail_cnt = 0;
 integer i;
 reg [31:0] read_w;

 task automatic read_word;
 input [3:0] idx;
 output [31:0] word;
 begin
 index = idx;
 #1;
 word = data_out;
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

 task automatic do_pulse_push;
 // 1-cyc push_valid pulse, push_drop driven from push_valid & pending
 // (mimics what the demand wrapper does)
 begin
 @(posedge clk);
 push_valid <= 1'b1;
 push_drop <= pending; // drop if already pending
 @(posedge clk);
 push_valid <= 1'b0;
 push_drop <= 1'b0;
 @(posedge clk);
 end
 endtask

 task automatic do_ack;
 begin
 @(posedge clk);
 ack_pulse <= 1'b1;
 @(posedge clk);
 ack_pulse <= 1'b0;
 @(posedge clk);
 end
 endtask

 initial begin
 $display("=========================================================");
 $display(" tb_indirect_mailbox — Phase Y.1.0 generic mailbox TB");
 $display("=========================================================");

 // populate word array for indirect-mux verification
 for (i = 0; i < 16; i = i + 1)
 words[i] = 32'hCAFE0000 | i[31:0];

 // Reset
 rst_n = 1'b0;
 repeat (5) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // -------------------------------------------------------------
 // TC1 — reset baseline
 // -------------------------------------------------------------
 $display("");
 $display("TC1 reset baseline");
 check_eq("TC1.pending=0", pending, 0);
 check_eq("TC1.drop_cnt=0", drop_cnt, 0);

 // -------------------------------------------------------------
 // TC2 — single push → pending=1, ack → pending=0
 // -------------------------------------------------------------
 $display("");
 $display("TC2 single push, ack");
 do_pulse_push();
 check_eq("TC2.pending=1", pending, 1);
 check_eq("TC2.drop_cnt=0", drop_cnt, 0);

 read_word(4'd5, read_w);
 check32("TC2.idx5 read", read_w, 32'hCAFE0005);

 do_ack();
 check_eq("TC2.post-ack pending=0", pending, 0);

 // -------------------------------------------------------------
 // TC3 — push while pending → drop_cnt++, indirect data unaffected
 // -------------------------------------------------------------
 $display("");
 $display("TC3 push while pending → drop");

 do_pulse_push(); // accept (pending now 1)
 check_eq("TC3.pending=1 after accept", pending, 1);

 do_pulse_push(); // push while pending → drop_cnt = 1
 check_eq("TC3.pending still 1", pending, 1);
 check_eq("TC3.drop_cnt=1", drop_cnt, 1);

 do_pulse_push(); // drop_cnt = 2
 check_eq("TC3.drop_cnt=2", drop_cnt, 2);

 // verify mux is still the words[] payload (not corrupted by push)
 read_word(4'd9, read_w);
 check32("TC3.idx9 read still ok", read_w, 32'hCAFE0009);

 do_ack();
 check_eq("TC3.post-ack pending=0", pending, 0);
 check_eq("TC3.drop_cnt sticky=2", drop_cnt, 2);

 // -------------------------------------------------------------
 // TC4 — saturate drop_cnt at 0xFFFF
 // -------------------------------------------------------------
 $display("");
 $display("TC4 saturate drop_cnt at 0xFFFF");

 // Hold push_valid permanently while pending=1 to flood drops.
 // Easier: directly drive push_drop high for many cycles.
 @(posedge clk);
 push_drop <= 1'b1;
 // We need 0xFFFF - 2 = 65533 more increments, plus a few extra to
 // verify saturation. Drive for 70000 cycles.
 repeat (70000) @(posedge clk);
 push_drop <= 1'b0;
 @(posedge clk);

 check_eq("TC4.drop_cnt saturates 0xFFFF", drop_cnt, 16'hFFFF);

 // One more drop pulse must NOT wrap
 @(posedge clk);
 push_drop <= 1'b1;
 @(posedge clk);
 push_drop <= 1'b0;
 @(posedge clk);
 check_eq("TC4.drop_cnt no wrap", drop_cnt, 16'hFFFF);

 // -------------------------------------------------------------
 // TC5 — indirect read: index 0..15 matches words[index]
 // -------------------------------------------------------------
 $display("");
 $display("TC5 indirect read 0..15");
 for (i = 0; i < 16; i = i + 1) begin
 read_word(i[3:0], read_w);
 check32("TC5.idx", read_w, 32'hCAFE0000 | i[31:0]);
 end

 // -------------------------------------------------------------
 // Summary
 // -------------------------------------------------------------
 $display("");
 $display("=========================================================");
 $display(" tb_indirect_mailbox SUMMARY pass=%0d fail=%0d",
 pass_cnt, fail_cnt);
 $display("=========================================================");
 if (fail_cnt == 0)
 $display(" RESULT: PASS");
 else
 $display(" RESULT: FAIL");
 $finish;
 end

 initial begin
 #5000000;
 $display("FAIL: timeout");
 $finish;
 end

endmodule

`default_nettype wire
