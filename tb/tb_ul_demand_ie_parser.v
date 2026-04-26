// =============================================================================
// tb_ul_demand_ie_parser.v — Phase 7 F.2 unit TB
// =============================================================================
//
// Verifies tetra_ul_demand_ie_parser.v against the bit-exact 129-bit MM
// body produced by tetra_ul_demand_reassembly.v for both the gold-ref
// capture (`reference_demand_reassembly_bitexact.md`) and the MTP3550
// capture, plus a no-IE body and a header-only body.
//
// T1: gold-ref body (GSSI 0x2F4D61, class_of_usage 4, address_type 0)
// T2: MTP3550 body (GSSI 0x000001)
// T3: o-bit=1, no Type-3 elements (m-bit=0)         → gild_valid=0
// T4: o-bit=0 minimal body (header only)            → gild_valid=0
//
// The reference body bits are constructed via 256-bit packed
// concatenation, sliced to the upper 129 bits.  This mirrors the
// gold-ref body decoded off-line in
// `reference_demand_reassembly_bitexact.md` (location_update_type=3,
// p_class_of_ms=1 with class_of_ms=0x1A1060, p_esm=1 esm=1, all other
// presence bits 0, then a single Type-3 GroupIdentityLocationDemand IE).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_demand_ie_parser;

    localparam integer CLK_PERIOD = 10;

    reg clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg          start;
    reg [128:0]  body;
    reg [23:0]   pdu_ssi;
    reg          body_kind;

    wire [2:0]   loc_upd_type_w;
    wire         req_to_append_la_w;
    wire         cipher_control_w;
    wire [23:0]  class_of_ms_w;
    wire         class_of_ms_valid_w;
    wire [2:0]   esm_w;
    wire         esm_valid_w;
    wire [13:0]  la_info_w;
    wire         la_info_valid_w;
    wire [23:0]  ssi_field_w;
    wire         ssi_field_valid_w;
    wire [23:0]  address_ext_w;
    wire         address_ext_valid_w;
    wire         gild_valid_w;
    wire [23:0]  gild_gssi_w;
    wire [2:0]   gild_class_w;
    wire [1:0]   gild_at_w;
    wire         gad_valid_w;
    wire         gad_atd_mode_w;
    wire [2:0]   gad_count_w;
    wire [2:0]   gad_attach_array_w;
    wire [8:0]   gad_class_array_w;
    wire [5:0]   gad_at_array_w;
    wire [71:0]  gad_gssi_array_w;
    wire [23:0]  pdu_ssi_w;
    wire         parse_done_w;
    wire         parse_ok_w;

    tetra_ul_demand_ie_parser u_dut (
        .clk_sys                      (clk),
        .rst_n_sys                    (rst_n),
        .start_sys                    (start),
        .body_sys                     (body),
        .ssi_sys                      (pdu_ssi),
        .body_kind_sys                (body_kind),
        .location_update_type_sys     (loc_upd_type_w),
        .request_to_append_la_sys     (req_to_append_la_w),
        .cipher_control_sys           (cipher_control_w),
        .class_of_ms_sys              (class_of_ms_w),
        .class_of_ms_valid_sys        (class_of_ms_valid_w),
        .energy_saving_mode_sys       (esm_w),
        .energy_saving_mode_valid_sys (esm_valid_w),
        .la_information_sys           (la_info_w),
        .la_information_valid_sys     (la_info_valid_w),
        .ssi_field_sys                (ssi_field_w),
        .ssi_field_valid_sys          (ssi_field_valid_w),
        .address_ext_sys              (address_ext_w),
        .address_ext_valid_sys        (address_ext_valid_w),
        .gild_valid_sys               (gild_valid_w),
        .gild_gssi_sys                (gild_gssi_w),
        .gild_class_of_usage_sys      (gild_class_w),
        .gild_address_type_sys        (gild_at_w),
        .gad_valid_sys                (gad_valid_w),
        .gad_attach_detach_mode_sys   (gad_atd_mode_w),
        .gad_count_sys                (gad_count_w),
        .gad_attach_array_sys         (gad_attach_array_w),
        .gad_class_array_sys          (gad_class_array_w),
        .gad_at_array_sys             (gad_at_array_w),
        .gad_gssi_array_sys           (gad_gssi_array_w),
        .pdu_ssi_sys                  (pdu_ssi_w),
        .parse_done_sys               (parse_done_w),
        .parse_ok_sys                 (parse_ok_w)
    );

    integer pass_cnt;
    integer fail_cnt;

    // -------------------------------------------------------------------
    // Build the gold-ref body via direct concatenation (MSB-first).  The
    // body is exactly the bit pattern documented in
    // reference_demand_reassembly_bitexact.md for the gold-ref demand,
    // with the gssi as a parameter.
    //
    //   [128:126] location_update_type = 3        (3 bit)  → 011
    //   [125]     request_to_append_la = 0        (1 bit)  → 0
    //   [124]     cipher_control       = 0        (1 bit)  → 0
    //   [123]     o-bit                = 1        (1 bit)  → 1
    //   [122]     p_class_of_ms        = 1        (1 bit)  → 1
    //   [121: 98] class_of_ms = 0x1A1060          (24 bit) → 0001 1010 0001 0000 0110 0000
    //   [97]      p_esm                = 1        (1 bit)  → 1
    //   [96: 94]  esm                  = 1        (3 bit)  → 001
    //   [93]      p_la                 = 0        (1 bit)  → 0
    //   [92]      p_ssi                = 0        (1 bit)  → 0
    //   [91]      p_ae                 = 0        (1 bit)  → 0
    //   [90]      m-bit (T3 list)      = 1        (1 bit)  → 1
    //   [89: 86]  elem_id              = 3        (4 bit)  → 0011
    //   [85: 75]  length               = 56       (11 bit) → 00000111000
    //   [74: 19]  GILD payload         = 56 bit
    //   [18]      m-bit terminator     = 0        (1 bit)  → 0
    //   [17:  0]  pad zeros (18 bit)
    //
    // Total = 5 + 1 + 1 + 24 + 1 + 3 + 3 + 1 + 4 + 11 + 56 + 1 + 18 = 129 ✓
    //
    // GILD payload (56 bit, MSB-first) =
    //   reserved=0, atd_mode=1, obit=1               (3 bit)  → 011
    //   m-bit=1, elem_id=8, length=36                (1+4+11)
    //                                                          → 1 1000 00000100100
    //   num_elem=1                                   (6 bit)  → 000001
    //   GIU[0]:
    //     attach_detach_type_id = 0                  (1 bit)  → 0
    //     class_of_usage        = 4                  (3 bit)  → 100
    //     address_type          = 0                  (2 bit)  → 00
    //     gssi                  = X                  (24 bit)
    //   trailing m-bit (gild)  = 0                   (1 bit)  → 0
    //
    // Total payload bits = 3 + 16 + 6 + 6 + 24 + 1 = 56 ✓
    // -------------------------------------------------------------------
    function [128:0] build_body_with_gssi;
        input [23:0] gssi_in;
        reg   [55:0] gild_pl;
        reg [128:0]  out;
        begin
            // GILD payload (concat top→bottom, MSB-first):
            //   3 + 1 + 4 + 11 + 6 + 1 + 3 + 2 + 24 + 1 = 56 bits
            gild_pl = {
                3'b011,         // reserved, atd_mode, obit
                1'b1,           // m-bit list start
                4'd8,           // elem_id GIU
                11'd36,         // length
                6'd1,           // num_elem
                1'b0,           // attach_detach_type_id
                3'd4,           // class_of_usage
                2'd0,           // address_type
                gssi_in,        // gssi (24 bit)
                1'b0            // trailing m-bit
            };

            // Body: 5 + 1 + 1 + 24 + 1 + 3 + 3 + 1 + 4 + 11 + 56 + 1 = 111
            // bits, with 18 zero pad bits at the LSB end → 129 bits total.
            out = {
                3'd3,           // location_update_type
                1'b0,           // request_to_append_la
                1'b0,           // cipher_control
                1'b1,           // o-bit
                1'b1,           // p_class_of_ms
                24'h1A1060,     // class_of_ms
                1'b1,           // p_esm
                3'd1,           // esm
                1'b0,           // p_la
                1'b0,           // p_ssi
                1'b0,           // p_ae
                1'b1,           // m-bit (T3 list start)
                4'd3,           // elem_id (GILD)
                11'd56,         // length
                gild_pl,        // 56-bit payload
                1'b0,           // trailing m-bit (T3 terminator)
                18'd0           // pad
            };
            build_body_with_gssi = out;
        end
    endfunction

    // -------------------------------------------------------------------
    // Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY body builder.
    // Reassembled body layout (mm_pdu_type stripped at parser-level):
    //
    //   bit[0]   group_identity_report
    //   bit[1]   attach_detach_mode
    //   bit[2]   o-bit
    //   bits[3..3+5+11-1]  GIU header: m=1 + id=8(4) + length(11)
    //   bits[3+16..]       GIU payload (num_elem(6) + records)
    //   trailing m-bit = 0
    //
    // build_gad_body() composes a body with N attach records (addr_t=0,
    // GSSI only, class_of_usage=4) at given GSSI values.  All bits beyond
    // the trailing m-bit are 0 fill.
    //
    // For the gold-ref Phase 7 F.7 capture (`reference_group_attach_
    // bitexact.md` UL fragment 1+2 reassembled): 2 records, ENT[0]=attach
    // GSSI, ENT[1]=detach GSSI.  Modeled here via build_gad_attach_detach.
    // -------------------------------------------------------------------
    function [128:0] build_gad_body_3attach;
        input [23:0] g0;
        input [23:0] g1;
        input [23:0] g2;
        reg [10:0]   length;
        reg [128:0]  out;
        begin
            // payload: num_elem(6) + 3 × (1+3+2+24) = 6 + 90 = 96 bits
            length = 11'd96;
            out = {
                1'b0,                       // group_identity_report
                1'b0,                       // attach_detach_mode (amend)
                1'b1,                       // o-bit
                1'b1, 4'd8, length,         // m=1 id=8 length=96
                6'd3,                       // num_elem
                1'b0, 3'd4, 2'b00, g0,      // ENT0: attach class=4 at=0 gssi
                1'b0, 3'd4, 2'b00, g1,
                1'b0, 3'd4, 2'b00, g2,
                1'b0,                       // trailing m-bit
                {(129 - 3 - 16 - 96 - 1){1'b0}}
            };
            build_gad_body_3attach = out;
        end
    endfunction

    function [128:0] build_gad_body_replace_all;
        input [23:0] g0;
        reg [10:0]   length;
        reg [128:0]  out;
        begin
            // payload: num_elem(6) + 1 × (1+3+2+24) = 6 + 30 = 36 bits
            length = 11'd36;
            out = {
                1'b0,                       // group_identity_report
                1'b1,                       // attach_detach_mode (replace_all)
                1'b1,                       // o-bit
                1'b1, 4'd8, length,         // m=1 id=8 length=36
                6'd1,                       // num_elem
                1'b0, 3'd4, 2'b00, g0,
                1'b0,
                {(129 - 3 - 16 - 36 - 1){1'b0}}
            };
            build_gad_body_replace_all = out;
        end
    endfunction

    function [128:0] build_gad_body_detach;
        input [23:0] g0;
        reg [10:0]   length;
        reg [128:0]  out;
        begin
            // payload: num_elem(6) + 1 × (1+2+2+24) = 6 + 29 = 35 bits
            length = 11'd35;
            out = {
                1'b0,                       // group_identity_report
                1'b0,                       // attach_detach_mode
                1'b1,                       // o-bit
                1'b1, 4'd8, length,         // m=1 id=8 length=35
                6'd1,                       // num_elem
                1'b1, 2'd0, 2'b00, g0,      // ENT0: detach gid=0 at=0 gssi
                1'b0,
                {(129 - 3 - 16 - 35 - 1){1'b0}}
            };
            build_gad_body_detach = out;
        end
    endfunction

    // Gold-ref-style attach + detach (matches `reference_group_attach_
    // bitexact.md` UL#0+UL#1 v1: ENT0=attach GSSI=0x2F4D63 class=4,
    // ENT1=detach GSSI=0x2F4D62 gid=2, addr_t=0).
    function [128:0] build_gad_body_attach_detach;
        input [23:0] g_attach;
        input [23:0] g_detach;
        reg [10:0]   length;
        reg [128:0]  out;
        begin
            // payload: num_elem(6) + (1+3+2+24)=30 + (1+2+2+24)=29 = 65 bits
            length = 11'd65;
            out = {
                1'b0,                       // group_identity_report
                1'b0,                       // attach_detach_mode (amend)
                1'b1,                       // o-bit
                1'b1, 4'd8, length,         // m=1 id=8 length=65
                6'd2,                       // num_elem
                1'b0, 3'd4, 2'b00, g_attach,
                1'b1, 2'd2, 2'b00, g_detach,
                1'b0,
                {(129 - 3 - 16 - 65 - 1){1'b0}}
            };
            build_gad_body_attach_detach = out;
        end
    endfunction

    // -------------------------------------------------------------------
    // o-bit=1 but no Type-3 elements (m-bit=0 immediately after Type-2
    // flags).  All optional Type-2 fields absent.
    //   3 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 = 12 bits used; pad to 129.
    // -------------------------------------------------------------------
    function [128:0] build_body_no_type3;
        reg [128:0] out;
        begin
            out = {
                3'd3,    // lut
                1'b0,    // ra
                1'b0,    // cc
                1'b1,    // o-bit
                1'b0,    // p_class
                1'b0,    // p_esm
                1'b0,    // p_la
                1'b0,    // p_ssi
                1'b0,    // p_ae
                1'b0,    // m-bit terminator
                {120{1'b0}}
            };
            build_body_no_type3 = out;
        end
    endfunction

    // -------------------------------------------------------------------
    // o-bit=0 — minimal body, just the 5-bit Type-1 header + 1-bit o-bit.
    // Total = 6 bits used; pad to 129.
    // -------------------------------------------------------------------
    function [128:0] build_body_obit0;
        reg [128:0] out;
        begin
            out = {
                3'd3,    // lut
                1'b0,    // ra
                1'b0,    // cc
                1'b0,    // o-bit
                {123{1'b0}}
            };
            build_body_obit0 = out;
        end
    endfunction

    // -------------------------------------------------------------------
    task drive_parse;
        input [23:0]  ssi_in;
        input [128:0] body_in;
        integer t;
        begin
            @(posedge clk); #1;
            body      = body_in;
            pdu_ssi   = ssi_in;
            body_kind = 1'b0;       // mm=2 LOC-UPDATE-DEMAND
            start     = 1'b1;
            @(posedge clk); #1;
            start     = 1'b0;
            t = 0;
            while (!parse_done_w && t < 200) begin
                @(posedge clk); #1;
                t = t + 1;
            end
            if (!parse_done_w) begin
                $display("FAIL: parse never finished (timeout)");
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Phase 7 F.7.1 — body_kind=1 (mm=7 ATTACH-DETACH) variant.
    task drive_parse_gad;
        input [23:0]  ssi_in;
        input [128:0] body_in;
        integer t;
        begin
            @(posedge clk); #1;
            body      = body_in;
            pdu_ssi   = ssi_in;
            body_kind = 1'b1;       // mm=7 ATTACH-DETACH-GROUP-IDENTITY
            start     = 1'b1;
            @(posedge clk); #1;
            start     = 1'b0;
            t = 0;
            while (!parse_done_w && t < 200) begin
                @(posedge clk); #1;
                t = t + 1;
            end
            if (!parse_done_w) begin
                $display("FAIL: parse never finished (timeout)");
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task expect_eq32;
        input [255:0] label;
        input [31:0]  got;
        input [31:0]  exp_v;
        begin
            if (got === exp_v) begin
                $display("  PASS %-40s got=0x%08X", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %-40s got=0x%08X exp=0x%08X",
                         label, got, exp_v);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------
    initial begin
        $dumpfile("sim_out/tb_ul_demand_ie_parser.vcd");
        $dumpvars(0, tb_ul_demand_ie_parser);

        rst_n     = 1'b0;
        start     = 1'b0;
        body      = 129'd0;
        pdu_ssi   = 24'd0;
        body_kind = 1'b0;
        pass_cnt  = 0;
        fail_cnt  = 0;

        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (4) @(posedge clk); #1;

        // ---------------------------------------------------------------
        $display("\n[T1] gold-ref body — GSSI=0x2F4D61");
        drive_parse(24'h282FF4, build_body_with_gssi(24'h2F4D61));
        expect_eq32("T1 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T1 loc_upd_type",    {29'd0, loc_upd_type_w}, 32'd3);
        expect_eq32("T1 cipher_control",  {31'd0, cipher_control_w}, 32'd0);
        expect_eq32("T1 class_of_ms_v",   {31'd0, class_of_ms_valid_w}, 32'd1);
        expect_eq32("T1 class_of_ms",     {8'd0, class_of_ms_w}, 32'h001A1060);
        expect_eq32("T1 esm_v",           {31'd0, esm_valid_w}, 32'd1);
        expect_eq32("T1 esm",             {29'd0, esm_w}, 32'd1);
        expect_eq32("T1 la_v",            {31'd0, la_info_valid_w}, 32'd0);
        expect_eq32("T1 ssi_v",           {31'd0, ssi_field_valid_w}, 32'd0);
        expect_eq32("T1 ae_v",            {31'd0, address_ext_valid_w}, 32'd0);
        expect_eq32("T1 gild_v",          {31'd0, gild_valid_w}, 32'd1);
        expect_eq32("T1 gild_gssi",       {8'd0, gild_gssi_w}, 32'h002F4D61);
        expect_eq32("T1 gild_class",      {29'd0, gild_class_w}, 32'd4);
        expect_eq32("T1 gild_at",         {30'd0, gild_at_w}, 32'd0);
        expect_eq32("T1 pdu_ssi",         {8'd0, pdu_ssi_w}, 32'h00282FF4);

        // ---------------------------------------------------------------
        $display("\n[T2] MTP3550 body — GSSI=0x000001");
        drive_parse(24'h282F91, build_body_with_gssi(24'h000001));
        expect_eq32("T2 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T2 gild_v",          {31'd0, gild_valid_w}, 32'd1);
        expect_eq32("T2 gild_gssi",       {8'd0, gild_gssi_w}, 32'h00000001);
        expect_eq32("T2 gild_class",      {29'd0, gild_class_w}, 32'd4);
        expect_eq32("T2 pdu_ssi",         {8'd0, pdu_ssi_w}, 32'h00282F91);

        // ---------------------------------------------------------------
        $display("\n[T3] body without Type-3 elements — gild_valid=0");
        drive_parse(24'hABCDEF, build_body_no_type3());
        expect_eq32("T3 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T3 gild_v",          {31'd0, gild_valid_w}, 32'd0);

        // ---------------------------------------------------------------
        $display("\n[T4] body with o-bit=0 — minimal header only");
        drive_parse(24'h123456, build_body_obit0());
        expect_eq32("T4 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T4 loc_upd_type",    {29'd0, loc_upd_type_w}, 32'd3);
        expect_eq32("T4 gild_v",          {31'd0, gild_valid_w}, 32'd0);
        expect_eq32("T4 class_of_ms_v",   {31'd0, class_of_ms_valid_w}, 32'd0);

        // ---------------------------------------------------------------
        // Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY (mm=7)
        // ---------------------------------------------------------------
        $display("\n[T5] gad_attach_3_groups — atd_mode=0, 3× attach");
        drive_parse_gad(24'h282FF4,
                        build_gad_body_3attach(24'h2F4D61, 24'h2F4D62, 24'h2F4D63));
        expect_eq32("T5 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T5 gad_v",           {31'd0, gad_valid_w}, 32'd1);
        expect_eq32("T5 atd_mode",        {31'd0, gad_atd_mode_w}, 32'd0);
        expect_eq32("T5 count",           {29'd0, gad_count_w}, 32'd3);
        expect_eq32("T5 attach[2:0]",     {29'd0, gad_attach_array_w}, 32'd0);
        expect_eq32("T5 class_array",     {23'd0, gad_class_array_w},  // {4,4,4}
                                          {23'd0, 9'b100_100_100});
        expect_eq32("T5 gssi[0]",         {8'd0, gad_gssi_array_w[23:0]}, 32'h002F4D61);
        expect_eq32("T5 gssi[1]",         {8'd0, gad_gssi_array_w[47:24]}, 32'h002F4D62);
        expect_eq32("T5 gssi[2]",         {8'd0, gad_gssi_array_w[71:48]}, 32'h002F4D63);
        expect_eq32("T5 pdu_ssi",         {8'd0, pdu_ssi_w}, 32'h00282FF4);

        // ---------------------------------------------------------------
        $display("\n[T6] gad_attach_replace_all — atd_mode=1, 1× attach");
        drive_parse_gad(24'h282FF4, build_gad_body_replace_all(24'hABCDEF));
        expect_eq32("T6 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T6 gad_v",           {31'd0, gad_valid_w}, 32'd1);
        expect_eq32("T6 atd_mode",        {31'd0, gad_atd_mode_w}, 32'd1);
        expect_eq32("T6 count",           {29'd0, gad_count_w}, 32'd1);
        expect_eq32("T6 gssi[0]",         {8'd0, gad_gssi_array_w[23:0]}, 32'h00ABCDEF);

        // ---------------------------------------------------------------
        $display("\n[T7] gad_detach — 1× detach");
        drive_parse_gad(24'h282FF4, build_gad_body_detach(24'h123456));
        expect_eq32("T7 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T7 gad_v",           {31'd0, gad_valid_w}, 32'd1);
        expect_eq32("T7 count",           {29'd0, gad_count_w}, 32'd1);
        expect_eq32("T7 attach[0]",       {31'd0, gad_attach_array_w[0]}, 32'd1);
        expect_eq32("T7 gssi[0]",         {8'd0, gad_gssi_array_w[23:0]}, 32'h00123456);

        // ---------------------------------------------------------------
        $display("\n[T8] gad_attach_detach (gold-ref-style) — 1 attach + 1 detach");
        drive_parse_gad(24'h282FF4,
                        build_gad_body_attach_detach(24'h2F4D63, 24'h2F4D62));
        expect_eq32("T8 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T8 gad_v",           {31'd0, gad_valid_w}, 32'd1);
        expect_eq32("T8 count",           {29'd0, gad_count_w}, 32'd2);
        expect_eq32("T8 attach[0]",       {31'd0, gad_attach_array_w[0]}, 32'd0);
        expect_eq32("T8 attach[1]",       {31'd0, gad_attach_array_w[1]}, 32'd1);
        expect_eq32("T8 gssi[0]",         {8'd0, gad_gssi_array_w[23:0]}, 32'h002F4D63);
        expect_eq32("T8 gssi[1]",         {8'd0, gad_gssi_array_w[47:24]}, 32'h002F4D62);

        // ---------------------------------------------------------------
        // T9 — profile0_m2_guard regression: re-run T1 (gold-ref body) and
        // verify the GAD outputs stay 0 (mm=2 path) so no leakage occurs.
        // ---------------------------------------------------------------
        $display("\n[T9] regression: mm=2 leaves GAD outputs zero");
        drive_parse(24'h282FF4, build_body_with_gssi(24'h2F4D61));
        expect_eq32("T9 parse_ok",        {31'd0, parse_ok_w}, 32'd1);
        expect_eq32("T9 gild_v",          {31'd0, gild_valid_w}, 32'd1);
        expect_eq32("T9 gad_v",           {31'd0, gad_valid_w}, 32'd0);
        expect_eq32("T9 gad_count",       {29'd0, gad_count_w}, 32'd0);

        // ---------------------------------------------------------------
        $display("\n========================================================");
        $display("tb_ul_demand_ie_parser:  PASS=%0d  FAIL=%0d",
                 pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("========================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
