// =============================================================================
// tb_grp_reply_mailbox.v — Phase Y.1.b Group-Attach Reply Mailbox regression
// =============================================================================
//
// Coverage:
//   TC1  W0..W8 read-back of staged values via INDEX/DATA AXI window
//   TC2  Field outputs decoded correctly from staged words
//   TC3  GO pulse passthrough — mb_grp_go_pulse_sys = go_pulse_sys
//   TC4  Reset clears all words
//
// Run:
//   iverilog -g2001 -o /tmp/tb_grmbox tb/tb_grp_reply_mailbox.v \
//                                      rtl/lmac/tetra_grp_reply_mailbox.v \
//                                      rtl/lmac/tetra_indirect_mailbox_wr.v
//   vvp /tmp/tb_grmbox
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_grp_reply_mailbox;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg  [3:0]  index    = 4'd0;
    reg  [31:0] wdata    = 32'd0;
    reg         wr_en    = 1'b0;
    reg         go_pulse = 1'b0;

    wire [31:0] rdata;
    wire [23:0] mb_ssi;
    wire        mb_ar;
    wire [1:0]  mb_count;
    wire [71:0] mb_gssi_arr;
    wire [5:0]  mb_at_arr;
    wire [5:0]  mb_lt_arr;
    wire [2:0]  mb_adi_arr;
    wire [8:0]  mb_class_arr;
    wire        mb_ns;
    wire        mb_nr;
    wire        mb_go;

    tetra_grp_reply_mailbox dut (
        .clk_sys                   (clk),
        .rst_n_sys                 (rst_n),
        .index_sys                 (index),
        .wdata_sys                 (wdata),
        .wr_en_sys                 (wr_en),
        .go_pulse_sys              (go_pulse),
        .rdata_sys                 (rdata),
        .mb_grp_ssi_sys            (mb_ssi),
        .mb_grp_accept_reject_sys  (mb_ar),
        .mb_grp_count_sys          (mb_count),
        .mb_grp_gssi_array_sys     (mb_gssi_arr),
        .mb_grp_at_array_sys       (mb_at_arr),
        .mb_grp_lifetime_array_sys (mb_lt_arr),
        .mb_grp_adi_array_sys      (mb_adi_arr),
        .mb_grp_class_array_sys    (mb_class_arr),
        .mb_grp_ns_sys             (mb_ns),
        .mb_grp_nr_sys             (mb_nr),
        .mb_grp_go_pulse_sys       (mb_go)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check32;
        input [255:0] tag;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=0x%08h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0x%08h  expected=0x%08h",
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
                $display("  PASS  %0s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=%0d  expected=%0d",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
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

    task automatic check72;
        input [255:0] tag;
        input [71:0]  got;
        input [71:0]  expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=0x%018h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0x%018h  expected=0x%018h",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic write_word;
        input [3:0]  idx_in;
        input [31:0] dat_in;
        begin
            @(posedge clk);
            index <= idx_in;
            wdata <= dat_in;
            wr_en <= 1'b1;
            @(posedge clk);
            wr_en <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic read_back;
        input  [3:0]  idx_in;
        output [31:0] data_out;
        begin
            index = idx_in;
            #1;
            data_out = rdata;
        end
    endtask

    reg [31:0] read_w;

    initial begin
        $display("=========================================================");
        $display("  tb_grp_reply_mailbox — Phase Y.1.b regression");
        $display("=========================================================");

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------------------------------------------------------------
        // TC1 — Reset baseline
        // -------------------------------------------------------------
        $display("");
        $display("TC1  Reset baseline (all words=0)");
        read_back(4'd0, read_w);  check32("TC1.W0=0", read_w, 32'd0);
        read_back(4'd1, read_w);  check32("TC1.W1=0", read_w, 32'd0);
        read_back(4'd2, read_w);  check32("TC1.W2=0", read_w, 32'd0);
        read_back(4'd5, read_w);  check32("TC1.W5=0", read_w, 32'd0);
        read_back(4'd8, read_w);  check32("TC1.W8=0", read_w, 32'd0);
        check_b ("TC1.go=0",     mb_go,  1'b0);

        // -------------------------------------------------------------
        // TC2 — Stage 1-record ACCEPT body
        // -------------------------------------------------------------
        $display("");
        $display("TC2  Stage 1-record ACCEPT (gssi=0x282FF4 class=4 lifetime=1)");
        write_word(4'd0, {8'd0, 24'h282FF4});       // ssi
        write_word(4'd1, 32'd0);                     // accept (=0)
        write_word(4'd2, 32'd1);                     // count=1
        write_word(4'd3, {8'd0, 24'h2F4D61});       // gssi[0]
        write_word(4'd4, 32'd0);                     // gssi[1]
        write_word(4'd5, 32'd0);                     // gssi[2]
        // W6 layout per RTL: [31:21] resv, [20:15] at_arr (3×2-bit),
        // [14:9] lt_arr (3×2-bit), [8:6] adi_arr (3×1-bit), [5:0] resv.
        // Build W6 = (lt_arr<<9) where lt_arr[1:0]=01 (record 0 lifetime=1).
        write_word(4'd6, (32'd0)
                         | ((32'd0    ) << 15)   // at_arr  = 0
                         | ((32'b000001) << 9)    // lt_arr  = 6'b000001 (record0=1)
                         | ((32'd0    ) << 6));   // adi_arr = 0
        write_word(4'd7, {23'd0, 9'b000_000_100});  // class_arr (record0 = 100=4)
        write_word(4'd8, 32'b10);                    // ns=1, nr=0

        // -------------------------------------------------------------
        // Read-back via AXI window
        // -------------------------------------------------------------
        read_back(4'd0, read_w);  check32("TC2.W0=ssi",   read_w, {8'd0, 24'h282FF4});
        read_back(4'd1, read_w);  check32("TC2.W1=ar=0",  read_w, 32'd0);
        read_back(4'd2, read_w);  check32("TC2.W2=cnt=1", read_w, 32'd1);
        read_back(4'd3, read_w);  check32("TC2.W3=gssi0", read_w, {8'd0, 24'h2F4D61});
        read_back(4'd6, read_w);
        check32("TC2.W6", read_w, (32'b000001 << 9));
        read_back(4'd7, read_w);
        check32("TC2.W7", read_w, {23'd0, 9'b000_000_100});
        read_back(4'd8, read_w);  check32("TC2.W8=ns/nr", read_w, 32'b10);

        // -------------------------------------------------------------
        // Field-outputs verification
        // -------------------------------------------------------------
        check_eq ("TC2.mb_ssi",   mb_ssi,         24'h282FF4);
        check_b  ("TC2.mb_ar",    mb_ar,          1'b0);
        check_eq ("TC2.mb_count", mb_count,       1);
        check72  ("TC2.mb_gssi",  mb_gssi_arr,    {48'd0, 24'h2F4D61});
        check_eq ("TC2.mb_at",    mb_at_arr,      0);
        check_eq ("TC2.mb_lt",    mb_lt_arr,      6'b00_00_01);
        check_eq ("TC2.mb_adi",   mb_adi_arr,     0);
        check_eq ("TC2.mb_class", mb_class_arr,   9'b000_000_100);
        check_b  ("TC2.mb_ns",    mb_ns,          1'b1);
        check_b  ("TC2.mb_nr",    mb_nr,          1'b0);

        // -------------------------------------------------------------
        // TC3 — GO pulse passthrough
        // -------------------------------------------------------------
        $display("");
        $display("TC3  GO pulse passthrough");
        @(posedge clk);
        go_pulse <= 1'b1;
        @(posedge clk);
        check_b("TC3.mb_go=1 in pulse", mb_go, 1'b1);
        go_pulse <= 1'b0;
        @(posedge clk);
        check_b("TC3.mb_go=0 after",    mb_go, 1'b0);

        // -------------------------------------------------------------
        // TC4 — REJECT path (count=0, ar=1)
        // -------------------------------------------------------------
        $display("");
        $display("TC4  REJECT (ar=1, count=0)");
        write_word(4'd1, 32'd1);   // ar=1
        write_word(4'd2, 32'd0);   // count=0
        check_b ("TC4.mb_ar",     mb_ar,    1'b1);
        check_eq("TC4.mb_count",  mb_count, 0);

        // -------------------------------------------------------------
        // TC5 — Stage 3-record body (full GSSI array)
        // -------------------------------------------------------------
        $display("");
        $display("TC5  Stage 3-record body");
        write_word(4'd1, 32'd0);   // ar=0 (accept)
        write_word(4'd2, 32'd3);   // count=3
        write_word(4'd3, {8'd0, 24'h111111});
        write_word(4'd4, {8'd0, 24'h222222});
        write_word(4'd5, {8'd0, 24'h333333});
        check72("TC5.mb_gssi_full", mb_gssi_arr,
                {24'h333333, 24'h222222, 24'h111111});
        check_eq("TC5.mb_count=3",  mb_count, 3);

        $display("");
        $display("=========================================================");
        $display("  tb_grp_reply_mailbox SUMMARY  pass=%0d  fail=%0d",
                 pass_cnt, fail_cnt);
        $display("=========================================================");
        if (fail_cnt == 0) $display("  RESULT: PASS");
        else               $display("  RESULT: FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("ERROR: TB watchdog");
        $finish;
    end

endmodule

`default_nettype wire
