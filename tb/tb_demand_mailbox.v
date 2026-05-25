// =============================================================================
// tb_demand_mailbox.v — Phase X.1 UL-Demand Snapshot Mailbox regression
// =============================================================================
//
// Coverage:
// TC1 single push (count=1, ssi=0x282F91, gssi[0]=0x000001, la=0x0042,
// loc_upd_type=1) → verify W0..W7 bit-exact
// TC2 push with count=3, three GSSIs/Classes → verify W3, W4, W5, W6
// TC3 push while pending=1 → drop_cnt += 1, latches unchanged
// TC4 ack_consumed_pulse_sys clears pending → next push accepted
//
// Run:
// iverilog -g2001 -o /tmp/tb_dmbox tb/tb_demand_mailbox.v \
// rtl/lmac/tetra_demand_mailbox.v
// vvp /tmp/tb_dmbox
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_demand_mailbox;
 reg clk = 1'b0;
 always #5 clk = ~clk;
 reg rst_n = 1'b0;

 reg push_valid = 1'b0;
 reg [23:0] push_ssi = 24'd0;
 reg [2:0] push_count = 3'd0;
 reg [71:0] push_gssi_arr = 72'd0;
 reg [8:0] push_class_arr = 9'd0;
 reg [2:0] push_lut = 3'd0;
 reg [13:0] push_la = 14'd0;
 reg ack_pulse = 1'b0;
 reg [3:0] index = 4'd0;

 wire [31:0] data_word;
 wire pending;
 wire [15:0] drop_cnt;

 tetra_demand_mailbox dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.demand_parsed_valid_sys (push_valid),
.demand_ul_ssi_sys (push_ssi),
.demand_gssi_count_sys (push_count),
.demand_gssi_array_sys (push_gssi_arr),
.demand_class_array_sys (push_class_arr),
.demand_loc_upd_type_sys (push_lut),
.demand_la_sys (push_la),
.ack_consumed_pulse_sys (ack_pulse),
.index_sys (index),
.data_word_sys (data_word),
.pending_sys (pending),
.drop_cnt_sys (drop_cnt)
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
 word = data_word;
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

 task automatic do_push;
 input [23:0] ssi_in;
 input [2:0] cnt_in;
 input [71:0] gssi_arr_in;
 input [8:0] class_arr_in;
 input [2:0] lut_in;
 input [13:0] la_in;
 begin
 @(posedge clk);
 push_ssi <= ssi_in;
 push_count <= cnt_in;
 push_gssi_arr <= gssi_arr_in;
 push_class_arr <= class_arr_in;
 push_lut <= lut_in;
 push_la <= la_in;
 push_valid <= 1'b1;
 @(posedge clk);
 push_valid <= 1'b0;
 @(posedge clk);
 end
 endtask

 initial begin
 $display("=========================================================");
 $display(" tb_demand_mailbox — Phase X.1 mailbox regression");
 $display("=========================================================");

 // Reset
 rst_n = 1'b0;
 repeat (5) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // -------------------------------------------------------------
 // TC1 — single push, verify W0..W7
 // -------------------------------------------------------------
 $display("");
 $display("TC1 single push, count=1, ssi=0x282F91, la=0x0042, lut=1");

 do_push(24'h282F91,
 3'd1,
 {48'd0, 24'h000001},
 {6'd0, 3'b001},
 3'd1,
 14'h0042);

 check_eq("TC1.pending=1", pending, 1);
 check_eq("TC1.drop_cnt=0", drop_cnt, 0);

 read_word(4'd0, read_w);
 // W0: {0xA5, 3'd0, count=1, lut=1, 15'd0}
 // = {8'hA5, 3'd0, 3'd1, 3'd1, 15'd0}
 // = 0xA5_0_001_001_0000 packed
 // bits [31:24]=0xA5, [23:21]=0, [20:18]=count=1, [17:15]=lut=1, [14:0]=0
 // = 0xA5_00_4800 ?
 // Let's compute: 0xA5<<24 | (0)<<21 | (1<<3 | 1)<<15
 // = 0xA5000000 | 0x00048000 | (0x9 << 15) = 0xA5048000?
 // count<<18=1<<18=0x40000, lut<<15=1<<15=0x8000
 // => 0xA5000000 | 0x00040000 | 0x00008000 = 0xA5048000
 check32("TC1.W0", read_w, 32'hA5048000);

 read_word(4'd1, read_w);
 check32("TC1.W1", read_w, 32'h00282F91);

 read_word(4'd2, read_w);
 check32("TC1.W2", read_w, 32'h00000042);

 read_word(4'd3, read_w);
 check32("TC1.W3", read_w, 32'h00000001);

 read_word(4'd4, read_w);
 check32("TC1.W4", read_w, 32'h00000000);

 read_word(4'd5, read_w);
 check32("TC1.W5", read_w, 32'h00000000);

 read_word(4'd6, read_w);
 // class_array = {6'd0, 3'b001} = 9'b000_000_001
 check32("TC1.W6", read_w, 32'h00000001);

 read_word(4'd7, read_w);
 check32("TC1.W7", read_w, 32'h00000000);

 // ACK to clear before TC2
 @(posedge clk);
 ack_pulse <= 1'b1;
 @(posedge clk);
 ack_pulse <= 1'b0;
 @(posedge clk);
 check_eq("TC1.post-ack pending=0", pending, 0);

 // -------------------------------------------------------------
 // TC2 — count=3, three GSSIs and Classes
 // -------------------------------------------------------------
 $display("");
 $display("TC2 push count=3, three GSSIs/Classes");

 // gssi_array layout: [23:0]=GSSI0, [47:24]=GSSI1, [71:48]=GSSI2
 // class_array layout: [2:0]=cls0, [5:3]=cls1, [8:6]=cls2
 do_push(24'h123456,
 3'd3,
 {24'hCCCCCC, 24'hBBBBBB, 24'hAAAAAA},
 {3'b101, 3'b010, 3'b111}, // cls2=5, cls1=2, cls0=7
 3'd2,
 14'h2A55);

 check_eq("TC2.pending=1", pending, 1);
 read_word(4'd0, read_w);
 // {0xA5, 3'd0, count=3, lut=2, 15'd0}
 // 0xA5<<24 | 3<<18 | 2<<15 = 0xA5000000 | 0x000C0000 | 0x00010000
 // = 0xA50D0000
 check32("TC2.W0", read_w, 32'hA50D0000);

 read_word(4'd1, read_w);
 check32("TC2.W1", read_w, 32'h00123456);

 read_word(4'd2, read_w);
 check32("TC2.W2", read_w, 32'h00002A55);

 read_word(4'd3, read_w);
 check32("TC2.W3-gssi0", read_w, 32'h00AAAAAA);

 read_word(4'd4, read_w);
 check32("TC2.W4-gssi1", read_w, 32'h00BBBBBB);

 read_word(4'd5, read_w);
 check32("TC2.W5-gssi2", read_w, 32'h00CCCCCC);

 read_word(4'd6, read_w);
 // class_array = {3'b101, 3'b010, 3'b111} = 9'b101_010_111 = 0x157
 check32("TC2.W6-classes", read_w, 32'h00000157);

 read_word(4'd7, read_w);
 check32("TC2.W7-drop=0", read_w, 32'h00000000);

 // -------------------------------------------------------------
 // TC3 — push while pending=1 → drop_cnt += 1, latches unchanged
 // -------------------------------------------------------------
 $display("");
 $display("TC3 push while pending=1, latches must NOT update");

 // Snapshot pre-drop-attempt
 do_push(24'hDEAD01,
 3'd1,
 {48'd0, 24'h0000FF},
 {6'd0, 3'b011},
 3'd5,
 14'h1111);

 check_eq("TC3.pending still 1", pending, 1);
 check_eq("TC3.drop_cnt=1", drop_cnt, 1);

 // Ensure latches still TC2 values
 read_word(4'd1, read_w);
 check32("TC3.W1 unchanged ssi=0x123456", read_w, 32'h00123456);

 read_word(4'd2, read_w);
 check32("TC3.W2 unchanged la=0x2A55", read_w, 32'h00002A55);

 read_word(4'd7, read_w);
 check32("TC3.W7 drop_cnt=1", read_w, 32'h00000001);

 // Second drop
 do_push(24'hDEAD02,
 3'd1,
 {48'd0, 24'h0000EE},
 {6'd0, 3'b001},
 3'd5,
 14'h2222);

 check_eq("TC3.drop_cnt=2", drop_cnt, 2);

 // -------------------------------------------------------------
 // TC4 — ACK clears pending → next push accepted
 // -------------------------------------------------------------
 $display("");
 $display("TC4 ack clears pending, next push accepted");

 @(posedge clk);
 ack_pulse <= 1'b1;
 @(posedge clk);
 ack_pulse <= 1'b0;
 @(posedge clk);
 check_eq("TC4.post-ack pending=0", pending, 0);

 do_push(24'hF00F00,
 3'd1,
 {48'd0, 24'hFEEDED},
 {6'd0, 3'b100},
 3'd3,
 14'h3FFF);

 check_eq("TC4.post-push pending=1", pending, 1);
 // drop_cnt is sticky (not cleared by ACK by spec)
 check_eq("TC4.drop_cnt sticky=2", drop_cnt, 2);

 read_word(4'd1, read_w);
 check32("TC4.W1 ssi=0xF00F00", read_w, 32'h00F00F00);

 read_word(4'd3, read_w);
 check32("TC4.W3 gssi0=0xFEEDED", read_w, 32'h00FEEDED);

 read_word(4'd0, read_w);
 // count=1, lut=3 → 0xA5000000 | 0x00040000 | 0x00018000 = 0xA5058000
 check32("TC4.W0 count=1 lut=3", read_w, 32'hA5058000);

 // -------------------------------------------------------------
 // Summary
 // -------------------------------------------------------------
 $display("");
 $display("=========================================================");
 $display(" tb_demand_mailbox SUMMARY pass=%0d fail=%0d",
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
