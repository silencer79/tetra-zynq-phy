// =============================================================================
// tb_mac_resource_dl_builder.v
//
// Golden-vector check for tetra_mac_resource_dl_builder.  Drives a known MM
// PDU (D-LOC-UPDATE-ACCEPT minimal bit layout) and verifies the 268-bit
// MAC-RESOURCE output matches a Python-computed reference.  The reference
// exercises every stage: LLC header build, FCS (CRC-32 poly 0x04C11DB7),
// MAC header, length indicator, fill-bit padding.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_mac_resource_dl_builder;
    localparam integer PDU_BITS = 268;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // DUT inputs
    reg              start    = 1'b0;
    reg [23:0]       ssi      = 24'd523;
    reg [2:0]        addr_type= 3'b001;     // SSI
    reg              ns       = 1'b0;
    reg              nr       = 1'b0;
    reg [79:0]       mm_bits  = 80'd0;
    reg [6:0]        mm_len   = 7'd0;

    // DUT outputs
    wire [PDU_BITS-1:0] pdu_bits;
    wire                valid;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(PDU_BITS)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .ssi             (ssi),
        .addr_type       (addr_type),
        .ns              (ns),
        .nr              (nr),
        .mm_pdu_bits     (mm_bits),
        .mm_pdu_len_bits (mm_len),
        .pdu_bits        (pdu_bits),
        .valid           (valid)
    );

    // -------------------------------------------------------------------------
    // Build the MM PDU bitstring in the same MSB-left-aligned format the
    // tetra_d_location_update_encoder emits on its `pdu_bits_mm` output.
    //   [79:76] PDU type = 0101
    //   [75:73] Loc update accept type = 000
    //   [72]    O-bit = 1
    //   [71]    p SSI = 1
    //   [70:47] SSI
    //   [46]    p addr-ext = 0
    //   [45]    p subs-class = 1
    //   [44:29] subs class
    //   [28]    p energy-saving = 0
    //   [27]    p SCCH info = 0
    //   [26]    m type-3/4 = 0
    //   [25:0]  padding (don't-care)
    // Total valid length = 54 bits.
    // -------------------------------------------------------------------------
    function [79:0] build_mm_accept;
        input [23:0] ssi_in;
        input [15:0] subs_cls;
        reg  [79:0]  m;
        begin
            m = 80'd0;
            m[79:76] = 4'b0101;
            m[75:73] = 3'b000;
            m[72]    = 1'b1;
            m[71]    = 1'b1;
            m[70:47] = ssi_in;
            m[46]    = 1'b0;
            m[45]    = 1'b1;
            m[44:29] = subs_cls;
            m[28]    = 1'b0;
            m[27]    = 1'b0;
            m[26]    = 1'b0;
            build_mm_accept = m;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Golden reference — from /tmp/regen_bug7_goldens.py
    // (SSI=523, subs_class=0x0000, NS=0, NR=0). Regenerate if any input or
    // the MAC-RESOURCE builder's header layout changes.
    //
    //   mm_len = 54           (legacy pre-Bug-#6 fixture kept in this TB;
    //                          wrapper is MM-content-agnostic so it stays)
    //   tl_sdu_len = 57 bits  (MLE-PD + MM only; Bug #9 FCS coverage)
    //   llc_cov_len = 63 bits (LLC header + TL-SDU — layout only)
    //   FCS = 0x44138683       (osmo-style: TL-SDU-only, no preshift at len≥32)
    //   length_ind = 17 (octets)
    //   mac_total_bits = 135, fill_bit_ind = 1
    //   MAC_HDR_BITS = 40      (Bug #7)
    // -------------------------------------------------------------------------
    localparam [PDU_BITS-1:0] EXPECTED_1 =
        268'h208900020b40a8c00082d0000088270d07000000000000000000000000000000000;

    integer fail_count = 0;
    integer test_count = 0;

    task automatic wait_valid(output reg [PDU_BITS-1:0] got);
        integer cycles;
        begin
            got    = {PDU_BITS{1'b0}};
            cycles = 0;
            while (cycles < 500 && !valid) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (valid) got = pdu_bits;
        end
    endtask

    task automatic run_vec(input [23:0] ssi_in,
                           input [15:0] subs_cls,
                           input        ns_in,
                           input        nr_in,
                           input [PDU_BITS-1:0] expected,
                           input [255:0] tag);
        reg [PDU_BITS-1:0] got;
        begin
            test_count = test_count + 1;
            @(posedge clk);
            ssi     <= ssi_in;
            nr      <= nr_in;
            ns      <= ns_in;
            mm_bits <= build_mm_accept(ssi_in, subs_cls);
            mm_len  <= 7'd54;
            start   <= 1'b1;
            @(posedge clk);
            start   <= 1'b0;
            wait_valid(got);
            if (got !== expected) begin
                $display("[T%0d %0s] FAIL", test_count, tag);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", expected);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS", test_count, tag);
            end
            // Let the FSM return to S_IDLE before the next call.
            repeat (4) @(posedge clk);
        end
    endtask

    // Basic sanity check — verify LengthInd field is at [260:255].
    task automatic check_length_ind(input [PDU_BITS-1:0] bits,
                                     input [5:0]         expected,
                                     input [255:0]       tag);
        reg [5:0] got;
        begin
            test_count = test_count + 1;
            got = bits[260:255];
            if (got !== expected) begin
                $display("[T%0d %0s] FAIL length_ind got=%0d exp=%0d",
                         test_count, tag, got, expected);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS length_ind=%0d", test_count, tag, got);
            end
        end
    endtask

    task automatic check_addr_ssi(input [PDU_BITS-1:0] bits,
                                   input [2:0]         exp_atype,
                                   input [23:0]        exp_ssi,
                                   input [255:0]       tag);
        reg [2:0]  got_at;
        reg [23:0] got_ssi;
        begin
            test_count = test_count + 1;
            got_at  = bits[254:252];
            got_ssi = bits[251:228];
            if (got_at !== exp_atype || got_ssi !== exp_ssi) begin
                $display("[T%0d %0s] FAIL addr: at=%0d/%0d ssi=%0d/%0d",
                         test_count, tag, got_at, exp_atype, got_ssi, exp_ssi);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS addr at=%0d ssi=%0d",
                         test_count, tag, got_at, got_ssi);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_mac_resource_dl_builder.vcd");
        $dumpvars(0, tb_mac_resource_dl_builder);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // T1 — golden vector match (SSI=523, subs_class=0, NS=NR=0)
        run_vec(24'd523, 16'h0000, 1'b0, 1'b0, EXPECTED_1, "ssi523_golden");

        // T2 — re-run the same input, verify output is stable across
        // back-to-back invocations (stale-valid regression guard).
        run_vec(24'd523, 16'h0000, 1'b0, 1'b0, EXPECTED_1, "ssi523_rerun");

        // T3 — field spot-checks on a second vector (different SSI).
        //       We don't have a pre-computed full golden, but verify the
        //       header and address bits propagate through correctly.
        @(posedge clk);
        ssi     <= 24'd1000;
        nr      <= 1'b1;
        ns      <= 1'b1;
        mm_bits <= build_mm_accept(24'd1000, 16'h1234);
        mm_len  <= 7'd54;
        start   <= 1'b1;
        @(posedge clk);
        start   <= 1'b0;
        begin : ssi1000_checks
            reg [PDU_BITS-1:0] got;
            wait_valid(got);
            // PDUtype[267:266]=00 — MAC-RESOURCE
            test_count = test_count + 1;
            if (got[267:266] !== 2'b00) begin
                $display("[T%0d ssi1000_pdut] FAIL got=%b", test_count, got[267:266]);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ssi1000_pdut] PASS", test_count);
            end
            // Length indication = 17 (same MM/LLC lengths -> same total;
            // 17 octets after Bug #7 header-size fix, was 18 pre-Bug-#7)
            check_length_ind(got, 6'd17, "ssi1000_len");
            // Address type + SSI
            check_addr_ssi(got, 3'b001, 24'd1000, "ssi1000_addr");
            // Fill-bit flag
            test_count = test_count + 1;
            if (got[265] !== 1'b1) begin
                $display("[T%0d ssi1000_fillflag] FAIL", test_count);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ssi1000_fillflag] PASS", test_count);
            end
        end

        repeat (4) @(posedge clk);

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_mac_resource_dl_builder: PASS (%0d/%0d)",
                     test_count, test_count);
        else
            $display("tb_mac_resource_dl_builder: FAIL (%0d/%0d failures)",
                     fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #500000;
        $display("tb_mac_resource_dl_builder: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
