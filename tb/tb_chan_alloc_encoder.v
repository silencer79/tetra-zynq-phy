// =============================================================================
// tb_chan_alloc_encoder.v
//
// Exercises tetra_chan_alloc_encoder.v against the bluestation reference
// bitstrings from crates/tetra-pdus/src/umac/fields/channel_allocation.rs
// tests (test_parse_chanalloc_replace_lab + _additional + _replace + _quitandgo).
//
// All four bluestation goldens have mon_pattern != 0 (25-bit width).  We add a
// dedicated T5 for the mon_pattern == 0 path (27-bit width) to prove the
// optional frame18 slot lights up.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_chan_alloc_encoder;

    reg  [1:0]  alloc_type      = 2'd0;
    reg  [3:0]  ts_assigned     = 4'd0;
    reg  [1:0]  ul_dl_assigned  = 2'd0;
    reg         clch_permission = 1'b0;
    reg         cell_change_flag= 1'b0;
    reg  [11:0] carrier_num     = 12'd0;
    reg  [1:0]  mon_pattern     = 2'd0;
    reg  [1:0]  frame18_mon_pattern = 2'd0;

    wire [31:0] packed_element;
    wire [4:0]  element_len;

    tetra_chan_alloc_encoder dut (
        .alloc_type         (alloc_type),
        .ts_assigned        (ts_assigned),
        .ul_dl_assigned     (ul_dl_assigned),
        .clch_permission    (clch_permission),
        .cell_change_flag   (cell_change_flag),
        .carrier_num        (carrier_num),
        .mon_pattern        (mon_pattern),
        .frame18_mon_pattern(frame18_mon_pattern),
        .packed_element     (packed_element),
        .element_len        (element_len)
    );

    integer fail_count = 0;
    integer test_count = 0;

    task automatic check(input [31:0] exp_val,
                         input [4:0]  exp_len,
                         input [127:0] tag);
        begin
            test_count = test_count + 1;
            #1;
            if (packed_element !== exp_val || element_len !== exp_len) begin
                $display("[T%0d %0s] FAIL packed=0x%08x (exp 0x%08x) len=%0d (exp %0d)",
                         test_count, tag, packed_element, exp_val, element_len, exp_len);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS packed=0x%08x len=%0d",
                         test_count, tag, packed_element, element_len);
            end
        end
    endtask

    initial begin
        // ---------------------------------------------------------------------
        // T1 — bluestation test_parse_chanalloc_replace_lab
        //      bitstr = "0001001110001111101001011" (25 bits, carrier_num=1001)
        //   alloc_type       = 00
        //   ts_assigned      = 0100
        //   ul_dl_assigned   = 11  (Both)
        //   clch_permission  = 1
        //   cell_change_flag = 0
        //   carrier_num      = 001111101001  = 1001
        //   ext_flag         = 0
        //   mon_pattern      = 11 (=3, so no frame18)
        // ---------------------------------------------------------------------
        alloc_type          = 2'b00;
        ts_assigned         = 4'b0100;
        ul_dl_assigned      = 2'b11;
        clch_permission     = 1'b1;
        cell_change_flag    = 1'b0;
        carrier_num         = 12'd1001;
        mon_pattern         = 2'b11;
        frame18_mon_pattern = 2'b00;
        check(32'h0000_0000 | 25'b0001001110001111101001011, 5'd25, "replace_lab");

        // ---------------------------------------------------------------------
        // T2 — test_parse_chanalloc_additional
        //      "0100101100010111111000011" (25 bits, carrier_num=1528)
        //   alloc_type       = 01
        //   ts_assigned      = 0010
        //   ul_dl_assigned   = 11
        //   clch_permission  = 0
        //   cell_change_flag = 0
        //   carrier_num      = 010111111000 = 1528
        //   ext_flag         = 0
        //   mon_pattern      = 11
        // ---------------------------------------------------------------------
        alloc_type          = 2'b01;
        ts_assigned         = 4'b0010;
        ul_dl_assigned      = 2'b11;
        clch_permission     = 1'b0;
        cell_change_flag    = 1'b0;
        carrier_num         = 12'd1528;
        mon_pattern         = 2'b11;
        frame18_mon_pattern = 2'b00;
        check(32'h0000_0000 | 25'b0100101100010111111000011, 5'd25, "additional");

        // ---------------------------------------------------------------------
        // T3 — test_parse_chanalloc_replace
        //      "0000101100010111111000011" (25 bits, carrier_num=1528)
        //   alloc_type       = 00
        //   ts_assigned      = 0010
        //   remainder identical to T2
        // ---------------------------------------------------------------------
        alloc_type          = 2'b00;
        ts_assigned         = 4'b0010;
        ul_dl_assigned      = 2'b11;
        clch_permission     = 1'b0;
        cell_change_flag    = 1'b0;
        carrier_num         = 12'd1528;
        mon_pattern         = 2'b11;
        frame18_mon_pattern = 2'b00;
        check(32'h0000_0000 | 25'b0000101100010111111000011, 5'd25, "replace");

        // ---------------------------------------------------------------------
        // T4 — test_parse_chanalloc_quitandgo
        //      "1000001100010111111000011" (25 bits, carrier_num=1528)
        //   alloc_type       = 10
        //   ts_assigned      = 0000
        // ---------------------------------------------------------------------
        alloc_type          = 2'b10;
        ts_assigned         = 4'b0000;
        ul_dl_assigned      = 2'b11;
        clch_permission     = 1'b0;
        cell_change_flag    = 1'b0;
        carrier_num         = 12'd1528;
        mon_pattern         = 2'b11;
        frame18_mon_pattern = 2'b00;
        check(32'h0000_0000 | 25'b1000001100010111111000011, 5'd25, "quitandgo");

        // ---------------------------------------------------------------------
        // T5 — 27-bit path: mon_pattern = 00, frame18_mon_pattern = 10
        //   bitstr = "01_0010_11_0_0_010111111000_0_00_10"
        //        = "010010110001011111100000010"
        //   alloc_type       = 01
        //   ts_assigned      = 0010
        //   ul_dl_assigned   = 11
        //   clch_permission  = 0
        //   cell_change_flag = 0
        //   carrier_num      = 010111111000 = 1528
        //   ext_flag         = 0
        //   mon_pattern      = 00
        //   frame18          = 10
        // ---------------------------------------------------------------------
        alloc_type          = 2'b01;
        ts_assigned         = 4'b0010;
        ul_dl_assigned      = 2'b11;
        clch_permission     = 1'b0;
        cell_change_flag    = 1'b0;
        carrier_num         = 12'd1528;
        mon_pattern         = 2'b00;
        frame18_mon_pattern = 2'b10;
        check(32'h0000_0000 | 27'b010010110001011111100000010, 5'd27, "frame18_path");

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_chan_alloc_encoder: PASS (%0d/%0d)",
                     test_count, test_count);
        else
            $display("tb_chan_alloc_encoder: FAIL (%0d/%0d failures)",
                     fail_count, test_count);
        $display("=============================================");
        $finish;
    end

endmodule

`default_nettype wire
