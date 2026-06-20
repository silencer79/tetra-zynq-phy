// =============================================================================
// tb_ul_demand_ie_parser_mm7.v — Phase Y.1.a IE-Parser mm=7 walker regression
// =============================================================================
//
// Verifies the Phase Y.1.a additive mm=7 dispatch + GID record walker.
// The mm=2 path is already covered by other regressions; this TB focuses on:
//
// TC1 mm=7 single-GIU attach at=0 → gid_count=1, adi=0, at=0,
// class=4, gssi=0x282FF4
// TC2 mm=7 dual-GIU attach at=0,0 → gid_count=2, both records valid
// TC3 mm=7 single-GIU detach at=0 → gid_count=1, adi=1, no class
// TC4 mm=7 with o-bit=0 → gid_count=0, parse_ok=1
// TC5 mm=2 fall-through unchanged → gild_valid_sys still works
// TC6 mm=foreign (e.g. 4) → parse_done + parse_ok=0
//
// Run:
// iverilog -g2001 -o /tmp/tb_iep7 tb/tb_ul_demand_ie_parser_mm7.v \
// rtl/lmac/tetra_ul_demand_ie_parser.v
// vvp /tmp/tb_iep7
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ul_demand_ie_parser_mm7;
 reg clk = 1'b0;
 always #5 clk = ~clk;
 reg rst_n = 1'b0;

 // DUT inputs
 reg start = 1'b0;
 reg [128:0] body = 129'd0;
 reg [23:0] ssi_in = 24'd0;
 reg [3:0] mm_pdu_type_in = 4'd0;

 // DUT outputs (mm=2)
 wire [2:0] loc_upd_type;
 wire req_to_append_la;
 wire cipher_control;
 wire [23:0] class_of_ms;
 wire class_of_ms_valid;
 wire [2:0] esm;
 wire esm_valid;
 wire [13:0] la_info;
 wire la_info_valid;
 wire [23:0] ssi_field;
 wire ssi_field_valid;
 wire [23:0] address_ext;
 wire address_ext_valid;
 wire gild_valid;
 wire [23:0] gild_gssi;
 wire [2:0] gild_class;
 wire [1:0] gild_at;
 wire [23:0] pdu_ssi;
 // DUT outputs (mm=7)
 wire [1:0] gid_count;
 wire gid_atd_mode;
 wire gid_grp_report;
 wire [2:0] gid_adi_arr;
 wire [8:0] gid_class_arr;
 wire [5:0] gid_at_arr;
 wire [71:0] gid_gssi_arr;
 wire parse_done;
 wire parse_ok;

 tetra_ul_demand_ie_parser dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.start_sys (start),
.body_sys (body),
.ssi_sys (ssi_in),
.mm_pdu_type_sys (mm_pdu_type_in),
.location_update_type_sys (loc_upd_type),
.request_to_append_la_sys (req_to_append_la),
.cipher_control_sys (cipher_control),
.class_of_ms_sys (class_of_ms),
.class_of_ms_valid_sys (class_of_ms_valid),
.energy_saving_mode_sys (esm),
.energy_saving_mode_valid_sys (esm_valid),
.la_information_sys (la_info),
.la_information_valid_sys (la_info_valid),
.ssi_field_sys (ssi_field),
.ssi_field_valid_sys (ssi_field_valid),
.address_ext_sys (address_ext),
.address_ext_valid_sys (address_ext_valid),
.gild_valid_sys (gild_valid),
.gild_gssi_sys (gild_gssi),
.gild_class_of_usage_sys (gild_class),
.gild_address_type_sys (gild_at),
.pdu_ssi_sys (pdu_ssi),
.gid_count_sys (gid_count),
.gid_attach_detach_mode_sys (gid_atd_mode),
.gid_group_identity_report_sys (gid_grp_report),
.gid_attach_detach_array_sys (gid_adi_arr),
.gid_class_array_sys (gid_class_arr),
.gid_address_type_array_sys (gid_at_arr),
.gid_gssi_array_sys (gid_gssi_arr),
.parse_done_sys (parse_done),
.parse_ok_sys (parse_ok)
 );

 integer pass_cnt = 0;
 integer fail_cnt = 0;
 reg parse_ok_lat = 1'b0;
 reg parse_done_seen = 1'b0;
 always @(posedge clk) begin
 if (start) begin
 parse_ok_lat <= 1'b0;
 parse_done_seen <= 1'b0;
 end else if (parse_done) begin
 parse_ok_lat <= parse_ok;
 parse_done_seen <= 1'b1;
 end
 end

 task automatic check;
 input [255:0] tag;
 input got;
 input expected;
 begin
 if (got === expected) begin
 $display(" PASS %0s got=%b", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=%b expected=%b",
 tag, got, expected);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task automatic check_int;
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

 task automatic check_h;
 input [255:0] tag;
 input [23:0] got;
 input [23:0] expected;
 begin
 if (got === expected) begin
 $display(" PASS %0s got=0x%06h", tag, got);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display(" FAIL %0s got=0x%06h expected=0x%06h",
 tag, got, expected);
 fail_cnt = fail_cnt + 1;
 end
 end
 endtask

 task automatic do_parse;
 input [3:0] mm_t;
 input [128:0] body_in;
 begin
 @(posedge clk);
 mm_pdu_type_in <= mm_t;
 body <= body_in;
 ssi_in <= 24'h282FF4;
 start <= 1'b1;
 @(posedge clk);
 start <= 1'b0;
 // wait for parse_done
 repeat (50) begin
 @(posedge clk);
 if (parse_done) begin
 repeat (1) @(posedge clk);
 disable do_parse;
 end
 end
 end
 endtask

 // -------------------------------------------------------------------------
 // Build a synthetic mm=7 body using the REAL reassembly layout: the
 // upstream LLC parser strips the 4-bit on-air pdu_type, so body_sys
 // starts at the first MM-body bit.
 //
 // Body header (10 bit):
 // [128] group_identity_report = 1
 // [127] attach_detach_mode = 0
 // [126] o-bit = 1
 // [125] m-bit (shared with GIU walker) = 1
 // [124:121] elem_id = 1000 (= 8) GroupIdentityUplink
 // [120:110] length = 36 (= 6 num_elem + 30 GIU)
 // [109:104] num_elem = 1
 // GIU#0 (30 bit):
 // [103] adi = 0 (attach)
 // [102:100] class_of_usage = cou
 // [ 99: 98] address_type = at
 // [ 97: 74] gssi (24)
 // trailing pad
 // -------------------------------------------------------------------------
 function automatic [128:0] mm7_body_1rec_attach;
 input [23:0] g;
 input [2:0] cou;
 input [1:0] at;
 reg [128:0] b;
 begin
 b = 129'd0;
 b[128] = 1'b1; // group_identity_report
 b[127] = 1'b0; // atd_mode
 b[126] = 1'b1; // o-bit
 b[125] = 1'b1; // m_giu
 b[124:121] = 4'd8; // elem_id
 b[120:110] = 11'd36; // length = 6 + 30
 b[109:104] = 6'd1; // num_elem
 b[103] = 1'b0; // adi=attach
 b[102:100] = cou; // class_of_usage
 b[ 99: 98] = at; // address_type
 b[ 97: 74] = g; // gssi
 mm7_body_1rec_attach = b;
 end
 endfunction

 function automatic [128:0] mm7_body_2rec_attach;
 input [23:0] g0;
 input [23:0] g1;
 reg [128:0] b;
 begin
 b = 129'd0;
 b[128] = 1'b1;
 b[127] = 1'b0;
 b[126] = 1'b1;
 b[125] = 1'b1;
 b[124:121] = 4'd8;
 b[120:110] = 11'd66; // length = 6 + 2*30
 b[109:104] = 6'd2;
 // record 0
 b[103] = 1'b0;
 b[102:100] = 3'd4;
 b[ 99: 98] = 2'd0;
 b[ 97: 74] = g0;
 // record 1
 b[ 73] = 1'b0;
 b[ 72: 70] = 3'd5;
 b[ 69: 68] = 2'd0;
 b[ 67: 44] = g1;
 mm7_body_2rec_attach = b;
 end
 endfunction

 function automatic [128:0] mm7_body_1rec_detach;
 input [23:0] g;
 reg [128:0] b;
 begin
 b = 129'd0;
 b[128] = 1'b0; // grp_report=0
 b[127] = 1'b1; // atd_mode=1 (replace)
 b[126] = 1'b1; // o-bit
 b[125] = 1'b1; // m_giu
 b[124:121] = 4'd8;
 b[120:110] = 11'd35; // length = 6 + (1+2+2+24)=35
 b[109:104] = 6'd1;
 b[103] = 1'b1; // adi=detach
 b[102:101] = 2'd0; // gid_detachment
 b[100: 99] = 2'd0; // address_type
 b[ 98: 75] = g; // gssi
 mm7_body_1rec_detach = b;
 end
 endfunction

 function automatic [128:0] mm7_body_obit_zero;
 input dummy;
 reg [128:0] b;
 begin
 b = 129'd0;
 b[128] = 1'b0; // grp_report=0
 b[127] = 1'b1; // atd_mode=1
 b[126] = 1'b0; // o-bit=0 (no opt fields)
 mm7_body_obit_zero = b;
 end
 endfunction

 // -------------------------------------------------------------------------
 // Bluestation peek-and-id corner case: m-bit==1 with elem_id != GRR (=4),
 // so S_GAD_M_REP must NOT consume the m-bit; it belongs to the GIU walker.
 // This is exactly the mm=7 -MS pattern (one m-bit, elem_id=8 directly).
 // -------------------------------------------------------------------------
 function automatic [128:0] mm7_body_grr_present;
 input [23:0] g;
 reg [128:0] b;
 begin
 // GRR present: m=1 elem_id=4 length=8 payload=0x55, then GIU.
 b = 129'd0;
 b[128] = 1'b0;
 b[127] = 1'b0;
 b[126] = 1'b1; // o-bit
 // GRR m=1 id=4 len=8 payload=0x55
 b[125] = 1'b1;
 b[124:121] = 4'd4;
 b[120:110] = 11'd8;
 b[109:102] = 8'h55;
 // GIU m=1 id=8 len=36 num=1 attach class=4 at=0 gssi=g
 b[101] = 1'b1; // m-bit
 b[100: 97] = 4'd8; // elem_id
 b[ 96: 86] = 11'd36; // length
 b[ 85: 80] = 6'd1; // num_elem
 b[ 79] = 1'b0; // adi=attach
 b[ 78: 76] = 3'd4; // class
 b[ 75: 74] = 2'd0; // at
 b[ 73: 50] = g; // gssi
 mm7_body_grr_present = b;
 end
 endfunction

 // -------------------------------------------------------------------------
 // Ref Group-Switch #1 (UL#11+UL#12 reassembled), 129-bit body
 // (mm_pdu_type stripped):
 // GIR=0 atd=0 obit=1 m=1 id=8 len=65 num=2
 // GIU#0 attach class=4 at=0 gssi=0x2F4D64
 // GIU#1 detach gid_det=2 at=0 gssi=0x2F4D63
 // m_proprietary=0 trailing=0
 // -------------------------------------------------------------------------
 function automatic [128:0] mm7_body_ref_gs1;
 input dummy;
 reg [128:0] b;
 begin
 b = 129'd0;
 b[128] = 1'b0; // GIR=0
 b[127] = 1'b0; // atd_mode=0
 b[126] = 1'b1; // o-bit
 b[125] = 1'b1; // m-bit (GIU)
 b[124:121] = 4'd8; // elem_id GIU
 b[120:110] = 11'd65; // length=65
 b[109:104] = 6'd2; // num_elem=2
 // GIU#0 attach class=4 at=0 gssi=0x2F4D64
 b[103] = 1'b0; // adi=attach
 b[102:100] = 3'd4; // class
 b[ 99: 98] = 2'd0; // at
 b[ 97: 74] = 24'h2F4D64; // gssi
 // GIU#1 detach gid_det=2 at=0 gssi=0x2F4D63
 b[ 73] = 1'b1; // adi=detach
 b[ 72: 71] = 2'd2; // group_id_detachment
 b[ 70: 69] = 2'd0; // at
 b[ 68: 45] = 24'h2F4D63; // gssi
 // [44] m_proprietary=0, [43] trailing m-bit=0
 mm7_body_ref_gs1 = b;
 end
 endfunction

 // mm=2 body — pre-existing GILD layout, single-GIU attach
 function automatic [128:0] mm2_body_gild;
 input [23:0] g;
 reg [128:0] b;
 begin
 // Type-1 hdr: lut(3)=000 ra(1)=0 cc(1)=0
 // o-bit=0 → no Type-2; jump to Type-3 m=1, elem_id=3 (GILD),
 // length, payload (reserved + atd_mode + obit + m + giu)
 b = 129'd0;
 b[128:126] = 3'd0; // location_update_type
 b[125] = 1'b0; // request_to_append_la
 b[124] = 1'b0; // cipher_control
 // [123] o-bit (T1 obit follows, but we set it to enter Type-3)
 b[123] = 1'b1; // o-bit
 // Type-2 fields all p=0
 b[122] = 1'b0; // p_class_of_ms
 b[121] = 1'b0; // p_esm
 b[120] = 1'b0; // p_la_info
 b[119] = 1'b0; // p_ssi
 b[118] = 1'b0; // p_ae
 // Type-3 list
 b[117] = 1'b1; // m-bit (GILD follows)
 b[116:113] = 4'd3; // elem_id = 3 (GILD)
 b[112:102] = 11'd56; // length=56 (3 hdr + 1 m + 4+11 typ4hdr +
 // 6 num_elem + 30 GIU - 1 mass...
 // we'll match hand-laid layout below)
 // GILD inner — 56 bits packed at [101..46]:
 // reserved(1)=0 + atd_mode(1)=0 + o-bit(1)=1 +
 // m-bit(1)=1 + elem_id=8(4) + length=36(11) +
 // num_elem=1(6) + GIU(adi=0+class=4+at=0+gssi=24)=30
 // = 1+1+1+1+4+11+6+30 = 55 bit; pad 1 m-bit terminator =56.
 b[101] = 1'b0; // reserved
 b[100] = 1'b0; // atd_mode
 b[ 99] = 1'b1; // o-bit
 b[ 98] = 1'b1; // m-bit T4
 b[ 97: 94] = 4'd8; // elem_id GIU
 b[ 93: 83] = 11'd36; // length = 6+30
 b[ 82: 77] = 6'd1; // num_elem
 b[ 76] = 1'b0; // adi=0 attach
 b[ 75: 73] = 3'd4; // class
 b[ 72: 71] = 2'd0; // address_type
 b[ 70: 47] = g; // gssi
 b[ 46] = 1'b0; // GILD trailing m-bit
 // [45] outer Type-3 list trailing m-bit = 0, then padding
 mm2_body_gild = b;
 end
 endfunction

 initial begin
 $display("=========================================================");
 $display(" tb_ul_demand_ie_parser_mm7 — Phase Y.1.a regression");
 $display("=========================================================");

 rst_n = 1'b0;
 repeat (5) @(posedge clk);
 rst_n = 1'b1;
 @(posedge clk);

 // ---- TC1 — mm=7 single-GIU attach ----
 $display("");
 $display("TC1 mm=7 single-GIU attach gssi=0x282FF4 class=4 at=0");
 do_parse(4'd7, mm7_body_1rec_attach(24'h282FF4, 3'd4, 2'd0));
 check ("TC1.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC1.gid_count", gid_count, 1);
 check ("TC1.adi[0]", gid_adi_arr[0], 1'b0);
 check_int("TC1.class[0]", gid_class_arr[2:0], 4);
 check_int("TC1.at[0]", gid_at_arr[1:0], 0);
 check_h ("TC1.gssi[0]", gid_gssi_arr[23:0], 24'h282FF4);
 check ("TC1.atd_mode", gid_atd_mode, 1'b0);
 check ("TC1.grp_report", gid_grp_report, 1'b1);

 // ---- TC2 — mm=7 dual-GIU attach ----
 $display("");
 $display("TC2 mm=7 dual-GIU attach 0x111111 + 0x222222");
 do_parse(4'd7, mm7_body_2rec_attach(24'h111111, 24'h222222));
 check ("TC2.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC2.gid_count", gid_count, 2);
 check_h ("TC2.gssi[0]", gid_gssi_arr[23:0], 24'h111111);
 check_h ("TC2.gssi[1]", gid_gssi_arr[47:24], 24'h222222);
 check_int("TC2.class[0]", gid_class_arr[2:0], 4);
 check_int("TC2.class[1]", gid_class_arr[5:3], 5);

 // ---- TC3 — mm=7 single detach ----
 $display("");
 $display("TC3 mm=7 single-GIU detach gssi=0x333333");
 do_parse(4'd7, mm7_body_1rec_detach(24'h333333));
 check ("TC3.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC3.gid_count", gid_count, 1);
 check ("TC3.adi[0]", gid_adi_arr[0], 1'b1);
 check_int("TC3.at[0]", gid_at_arr[1:0], 0);
 check_h ("TC3.gssi[0]", gid_gssi_arr[23:0], 24'h333333);
 check ("TC3.atd_mode", gid_atd_mode, 1'b1);

 // ---- TC4 — mm=7 with o-bit=0 (no records) ----
 $display("");
 $display("TC4 mm=7 with o-bit=0 (no records)");
 do_parse(4'd7, mm7_body_obit_zero(1'b0));
 check ("TC4.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC4.gid_count", gid_count, 0);

 // ---- TC5 — mm=2 fall-through ----
 $display("");
 $display("TC5 mm=2 single-GIU GILD (legacy, must still work)");
 do_parse(4'd2, mm2_body_gild(24'hABCDEF));
 check ("TC5.parse_ok", parse_ok_lat, 1'b1);
 check ("TC5.gild_valid", gild_valid, 1'b1);
 check_h ("TC5.gild_gssi", gild_gssi, 24'hABCDEF);
 check_int("TC5.gild_class", gild_class, 4);
 check_int("TC5.gid_count_zero", gid_count, 0);

 // ---- TC6 — mm=foreign ----
 $display("");
 $display("TC6 mm=4 (foreign) — parse_done + parse_ok=0");
 do_parse(4'd4, 129'd0);
 check ("TC6.parse_ok=0", parse_ok_lat, 1'b0);

 // ---- TC7 — Bluestation peek-and-id corner case ----
 $display("");
 $display("TC7 mm=7 GRR present (m=1 id=4) then GIU (m=1 id=8)");
 do_parse(4'd7, mm7_body_grr_present(24'h123456));
 check ("TC7.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC7.gid_count", gid_count, 1);
 check_h ("TC7.gssi[0]", gid_gssi_arr[23:0], 24'h123456);
 check_int("TC7.class[0]", gid_class_arr[2:0], 4);
 check ("TC7.adi[0]", gid_adi_arr[0], 1'b0);

 // ---- TC8 — Ref Group-Switch #1 (Memory bit-exact) ----
 $display("");
 $display("TC8 mm=7 GS#1 — attach 0x2F4D64 + detach 0x2F4D63");
 do_parse(4'd7, mm7_body_ref_gs1(1'b0));
 check ("TC8.parse_ok", parse_ok_lat, 1'b1);
 check_int("TC8.gid_count", gid_count, 2);
 // Record 0: attach 0x2F4D64 class=4
 check ("TC8.adi[0]", gid_adi_arr[0], 1'b0);
 check_int("TC8.class[0]", gid_class_arr[2:0], 4);
 check_int("TC8.at[0]", gid_at_arr[1:0], 0);
 check_h ("TC8.gssi[0]", gid_gssi_arr[23:0], 24'h2F4D64);
 // Record 1: detach 0x2F4D63
 check ("TC8.adi[1]", gid_adi_arr[1], 1'b1);
 check_int("TC8.at[1]", gid_at_arr[3:2], 0);
 check_h ("TC8.gssi[1]", gid_gssi_arr[47:24], 24'h2F4D63);
 check ("TC8.atd_mode", gid_atd_mode, 1'b0);
 check ("TC8.grp_report", gid_grp_report, 1'b0);

 $display("");
 $display("=========================================================");
 $display(" tb_ul_demand_ie_parser_mm7 SUMMARY pass=%0d fail=%0d",
 pass_cnt, fail_cnt);
 $display("=========================================================");
 if (fail_cnt == 0) $display(" RESULT: PASS");
 else $display(" RESULT: FAIL");
 $finish;
 end

 initial begin
 #2_000_000;
 $display("ERROR: TB watchdog");
 $finish;
 end

endmodule

`default_nettype wire
