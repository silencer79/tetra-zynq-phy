// =============================================================================
// tb_d_attach_detach_grp_id_ack_encoder.v — Phase Y.1.c regression
// =============================================================================
//
// Coverage:
//   TC1  Single-record ACCEPT (gssi=0x2F4D61 class=4 lifetime=1 at=0)
//        → mm_pdu_type=11, accept_reject=0, len_bits=64
//   TC2  Single-record ACCEPT bit-positions cross-check
//   TC3  REJECT path (count=0 → len=8, mm_pdu_type=11, ar=1, o-bit=0)
//   TC4  Two-record ACCEPT length=96
//   TC5  Three-record ACCEPT length=128
//   TC6  Detach record (adi=1) — single record, gid_count=1 detach
//   TC7  bit-exact spot-check on gold-ref-style record layout
//
// Run:
//   iverilog -g2001 -o /tmp/tb_aenc tb/tb_d_attach_detach_grp_id_ack_encoder.v \
//        rtl/lmac/tetra_d_attach_detach_grp_id_ack_encoder.v
//   vvp /tmp/tb_aenc
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_d_attach_detach_grp_id_ack_encoder;
    reg          accept_reject = 1'b0;
    reg [1:0]    gid_count     = 2'd0;
    reg [71:0]   gssi_arr      = 72'd0;
    reg [5:0]    at_arr        = 6'd0;
    reg [5:0]    lt_arr        = 6'd0;
    reg [2:0]    adi_arr       = 3'd0;
    reg [8:0]    class_arr     = 9'd0;
    wire [127:0] mm_bits;
    wire [7:0]   mm_len;

    tetra_d_attach_detach_grp_id_ack_encoder dut (
        .accept_reject  (accept_reject),
        .gid_count      (gid_count),
        .gssi_array     (gssi_arr),
        .at_array       (at_arr),
        .lifetime_array (lt_arr),
        .adi_array      (adi_arr),
        .class_array    (class_arr),
        .pdu_bits_mm    (mm_bits),
        .pdu_len_bits   (mm_len)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check_eq;
        input [255:0] tag;
        input integer got;
        input integer expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=%0d  expected=%0d",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic check_h;
        input [255:0] tag;
        input integer width;
        input [127:0] got;
        input [127:0] expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=0x%h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0x%h  expected=0x%h",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
            if (width == 0) begin /* silence lint */ end
        end
    endtask

    task automatic check_b;
        input [255:0] tag;
        input         got;
        input         expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=%b", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=%b  expected=%b",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $display("=========================================================");
        $display("  tb_d_attach_detach_grp_id_ack_encoder — Phase Y.1.c");
        $display("=========================================================");

        // ---- TC1 — Single-record ACCEPT ----
        $display("");
        $display("TC1  Single-record ACCEPT gssi=0x2F4D61 class=4 lifetime=1");
        accept_reject = 1'b0;
        gid_count     = 2'd1;
        gssi_arr      = {48'd0, 24'h2F4D61};
        at_arr        = 6'd0;       // record 0: at=00
        lt_arr        = 6'b00_00_01;
        adi_arr       = 3'b000;     // record 0: adi=0 (attach)
        class_arr     = 9'b000_000_100;
        #1;
        check_eq("TC1.mm_len=64",         mm_len,                64);
        check_eq("TC1.mm_pdu_type=0xB",   mm_bits[127:124],      4'hB);
        check_b ("TC1.accept_reject=0",   mm_bits[123],          1'b0);
        check_b ("TC1.reserved=0",        mm_bits[122],          1'b0);
        check_b ("TC1.o-bit=1",           mm_bits[121],          1'b1);
        check_b ("TC1.p_prop=0",          mm_bits[120],          1'b0);
        check_b ("TC1.m_gid_dl=1",        mm_bits[119],          1'b1);
        check_eq("TC1.elem_id=7",         mm_bits[118:115],      4'd7);
        check_eq("TC1.length=38",         mm_bits[114:104],      11'd38);
        check_eq("TC1.num_elems=1",       mm_bits[103:98],       6'd1);
        check_b ("TC1.adi=0",             mm_bits[97],           1'b0);
        check_eq("TC1.lifetime=1",        mm_bits[96:95],        2'd1);
        check_eq("TC1.class=4",           mm_bits[94:92],        3'd4);
        check_eq("TC1.address_type=0",    mm_bits[91:90],        2'd0);
        check_eq("TC1.gssi=0x2F4D61",     mm_bits[89:66],        24'h2F4D61);
        check_b ("TC1.m_grp_sec=0",       mm_bits[65],           1'b0);
        check_b ("TC1.trailing_mbit=0",   mm_bits[64],           1'b0);

        // ---- TC2 — REJECT ----
        $display("");
        $display("TC2  REJECT (count=0, accept_reject=1)");
        accept_reject = 1'b1;
        gid_count     = 2'd0;
        #1;
        check_eq("TC2.mm_len=8",        mm_len,             8);
        check_eq("TC2.mm_pdu_type=0xB", mm_bits[127:124],   4'hB);
        check_b ("TC2.ar=1",            mm_bits[123],       1'b1);
        check_b ("TC2.o-bit=0",         mm_bits[121],       1'b0);
        check_b ("TC2.trailing=0",      mm_bits[120],       1'b0);

        // ---- TC3 — Two-record ACCEPT ----
        $display("");
        $display("TC3  Two-record ACCEPT");
        accept_reject = 1'b0;
        gid_count     = 2'd2;
        gssi_arr      = {24'd0, 24'h222222, 24'h111111};
        at_arr        = {2'd0, 2'd0, 2'd0};
        lt_arr        = {2'd0, 2'd0, 2'd1};      // record0 lt=1, record1 lt=0
        adi_arr       = 3'b000;                   // both attach
        class_arr     = {3'd0, 3'd5, 3'd4};
        #1;
        check_eq("TC3.mm_len=96",       mm_len,           96);
        check_eq("TC3.num_elems=2",     mm_bits[103:98],  6'd2);
        check_eq("TC3.length=70",       mm_bits[114:104], 11'd70);  // 6 + 2*32
        check_eq("TC3.rec0.gssi",       mm_bits[89:66],   24'h111111);
        check_eq("TC3.rec1.gssi",       mm_bits[57:34],   24'h222222);

        // ---- TC4 — Three-record ACCEPT ----
        $display("");
        $display("TC4  Three-record ACCEPT (full body)");
        gid_count     = 2'd3;
        gssi_arr      = {24'h333333, 24'h222222, 24'h111111};
        class_arr     = {3'd6, 3'd5, 3'd4};
        #1;
        check_eq("TC4.mm_len=128",     mm_len,           128);
        check_eq("TC4.num_elems=3",    mm_bits[103:98],  6'd3);
        check_eq("TC4.length=102",     mm_bits[114:104], 11'd102); // 6 + 3*32
        check_eq("TC4.rec0.gssi",      mm_bits[89:66],   24'h111111);
        check_eq("TC4.rec1.gssi",      mm_bits[57:34],   24'h222222);
        check_eq("TC4.rec2.gssi",      mm_bits[25:2],    24'h333333);

        // ---- TC5 — Detach single ----
        $display("");
        $display("TC5  Single-record detach (adi=1)");
        gid_count = 2'd1;
        adi_arr   = 3'b001;       // record 0 adi=1
        gssi_arr  = {48'd0, 24'h444444};
        #1;
        check_eq("TC5.mm_len=64",      mm_len,           64);
        check_b ("TC5.adi=1",          mm_bits[97],      1'b1);
        // detach: bits 96..95 = lifetime field reused as gid_detachment, here 0
        // We pack the lifetime[1:0] same way regardless — still 64 bit envelope.
        check_eq("TC5.gssi=0x444444",  mm_bits[89:66],   24'h444444);

        // ---- TC6 — Bit-exact spot-check (mock gold-ref single record) ----
        $display("");
        $display("TC6  Bit-exact spot-check 1-record ACCEPT");
        accept_reject = 1'b0;
        gid_count     = 2'd1;
        gssi_arr      = {48'd0, 24'h2F4D61};
        at_arr        = 6'd0;
        lt_arr        = 6'b000001;
        adi_arr       = 3'b000;
        class_arr     = 9'b000_000_100;
        #1;
        // Expected bit-pack of the 64 meaningful bits, MSB at [127]:
        //   pdu_type=1011, ar=0, resv=0, o=1, p_prop=0, m_gid=1,
        //   elem_id=0111, length=00000100110, num_elem=000001,
        //   adi=0, lt=01, class=100, at=00, gssi=24'h2F4D61,
        //   m_grp_sec=0, trail=0
        check_h("TC6.bits[127:64]", 64, {mm_bits[127:64], 64'd0},
                {64'b1011_0_0_1_0_1_0111_00000100110_000001_0_01_100_00_001011110100110101100001_0_0,
                 64'd0});

        // ---- TC7 — at=2 (vgssi) record ----
        $display("");
        $display("TC7  at=2 (vgssi) record");
        accept_reject = 1'b0;
        gid_count     = 2'd1;
        at_arr        = 6'd2;       // record 0: at=10
        gssi_arr      = {48'd0, 24'h555555};
        #1;
        check_eq("TC7.at=2",           mm_bits[91:90],   2'd2);
        check_eq("TC7.vgssi=0x555555", mm_bits[89:66],   24'h555555);

        $display("");
        $display("=========================================================");
        $display("  tb_d_attach_detach_grp_id_ack_encoder SUMMARY  pass=%0d  fail=%0d",
                 pass_cnt, fail_cnt);
        $display("=========================================================");
        if (fail_cnt == 0) $display("  RESULT: PASS");
        else               $display("  RESULT: FAIL");
        $finish;
    end

endmodule

`default_nettype wire
