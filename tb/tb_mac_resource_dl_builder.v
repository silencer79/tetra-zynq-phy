// =============================================================================
// tb_mac_resource_dl_builder.v
//
// Golden-vector check for tetra_mac_resource_dl_builder.  Drives a known MM
// PDU (D-LOC-UPDATE-ACCEPT with SSI IE in BlueStation-like layout) and
// verifies the 268-bit
// MAC-RESOURCE output matches a Python-computed reference.  The reference
// exercises the BlueStation-like LLC BL-DATA header build, MAC header,
// length indicator, and fill-bit padding.
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
    reg              random_access_flag = 1'b0;  // default off for legacy goldens
    // Optional header elements (commit 1 plumbing — all zero for legacy cases)
    reg              power_control_flag     = 1'b0;
    reg [3:0]        power_control_element  = 4'd0;
    reg              slot_granting_flag     = 1'b0;
    reg [7:0]        slot_granting_element  = 8'd0;
    reg              chan_alloc_flag        = 1'b0;
    reg [31:0]       chan_alloc_element     = 32'd0;
    reg [4:0]        chan_alloc_element_len = 5'd0;
    // Concatenated PDU #2 inputs (commit 2) — all zero for single-PDU cases
    reg              second_pdu_valid            = 1'b0;
    reg  [5:0]       second_pdu_length_ind       = 6'd0;
    reg              second_pdu_random_access_flag = 1'b0;
    reg  [2:0]       second_pdu_addr_type        = 3'd0;
    reg  [23:0]      second_pdu_ssi              = 24'd0;
    reg  [79:0]      second_pdu_tl_sdu           = 80'd0;
    reg  [6:0]       second_pdu_tl_sdu_len       = 7'd0;
    reg              second_pdu_pc_flag          = 1'b0;
    reg  [3:0]       second_pdu_pc_element       = 4'd0;
    reg              second_pdu_sg_flag          = 1'b0;
    reg  [7:0]       second_pdu_sg_element       = 8'd0;
    reg              second_pdu_ca_flag          = 1'b0;
    reg  [31:0]      second_pdu_ca_element       = 32'd0;
    reg  [4:0]       second_pdu_ca_element_len   = 5'd0;
    reg [79:0]       mm_bits  = 80'd0;
    reg [6:0]        mm_len   = 7'd0;

    // DUT outputs
    wire [PDU_BITS-1:0] pdu_bits;
    wire                valid;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(PDU_BITS)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .ssi                (ssi),
        .addr_type          (addr_type),
        .ns                 (ns),
        .nr                 (nr),
        .random_access_flag (random_access_flag),
        .power_control_flag     (power_control_flag),
        .power_control_element  (power_control_element),
        .slot_granting_flag     (slot_granting_flag),
        .slot_granting_element  (slot_granting_element),
        .chan_alloc_flag        (chan_alloc_flag),
        .chan_alloc_element     (chan_alloc_element),
        .chan_alloc_element_len (chan_alloc_element_len),
        .second_pdu_valid              (second_pdu_valid),
        .second_pdu_length_ind         (second_pdu_length_ind),
        .second_pdu_random_access_flag (second_pdu_random_access_flag),
        .second_pdu_addr_type          (second_pdu_addr_type),
        .second_pdu_ssi                (second_pdu_ssi),
        .second_pdu_tl_sdu             (second_pdu_tl_sdu),
        .second_pdu_tl_sdu_len         (second_pdu_tl_sdu_len),
        .second_pdu_pc_flag            (second_pdu_pc_flag),
        .second_pdu_pc_element         (second_pdu_pc_element),
        .second_pdu_sg_flag            (second_pdu_sg_flag),
        .second_pdu_sg_element         (second_pdu_sg_element),
        .second_pdu_ca_flag            (second_pdu_ca_flag),
        .second_pdu_ca_element         (second_pdu_ca_element),
        .second_pdu_ca_element_len     (second_pdu_ca_element_len),
        .mm_pdu_bits        (mm_bits),
        .mm_pdu_len_bits    (mm_len),
        .pdu_bits           (pdu_bits),
        .valid              (valid)
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
    //   [45]    p subs-class = 0
    //   [44]    p energy-saving = 0
    //   [43]    p SCCH info = 0
    //   [42]    m type-3/4 = 0
    //   [41:0]  padding (don't-care)
    // Total valid length = 38 bits.
    // -------------------------------------------------------------------------
    function [79:0] build_mm_accept;
        input [23:0] ssi_in;
        reg  [79:0]  m;
        begin
            m = 80'd0;
            m[79:76] = 4'b0101;
            m[75:73] = 3'b000;
            m[72]    = 1'b1;
            m[71]    = 1'b1;
            m[70:47] = ssi_in;
            m[46]    = 1'b0;
            m[45]    = 1'b0;
            m[44]    = 1'b0;
            m[43]    = 1'b0;
            m[42]    = 1'b0;
            build_mm_accept = m;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Golden reference — bluestation-parity 43-bit MAC-RESOURCE header.
    // Recomputed 2026-04-24 via the bluestation-equivalent Python reference
    // (MacResource::to_bitbuf + update_len_and_fill_ind in
    //  crates/tetra-pdus/src/umac/pdus/mac_resource.rs).
    //
    //   mm_len        = 38
    //   tl_sdu_len    = 41 bits  (MLE-PD 3 + MM 38)
    //   llc_cov_len   = 46 bits  (LLC header 5 + TL-SDU)
    //   hdr_len       = 43 bits  (40 base + 1 pc_flag + 1 sg_flag + 1 ca_flag)
    //   mac_total_bits= 89 bits  (43 + 46)
    //   length_ind    = 12 octets
    //   fill_bits     = 7        (first fill bit = 1)
    //
    // Expected emission (MSB-first hex):
    //   206100020b 022a300020 b04 (then 7-bit fill: first=1 → +0x040)
    //   +  zero pad to 268 bits.
    // -------------------------------------------------------------------------
    localparam [PDU_BITS-1:0] EXPECTED_1 =
        268'h206100020b022a300020b0400000000000000000000000000000000000000000000;

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
            mm_bits <= build_mm_accept(ssi_in);
            mm_len  <= 7'd38;
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
        run_vec(24'd523, 1'b0, 1'b0, EXPECTED_1, "ssi523_golden");

        // T2 — re-run the same input, verify output is stable across
        // back-to-back invocations (stale-valid regression guard).
        run_vec(24'd523, 1'b0, 1'b0, EXPECTED_1, "ssi523_rerun");

        // T3 — field spot-checks on a second vector (different SSI).
        //       We don't have a pre-computed full golden, but verify the
        //       header and address bits propagate through correctly.
        @(posedge clk);
        ssi     <= 24'd1000;
        nr      <= 1'b1;
        ns      <= 1'b1;
        mm_bits <= build_mm_accept(24'd1000);
        mm_len  <= 7'd38;
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
            check_length_ind(got, 6'd12, "ssi1000_len");
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
            // RandAccFlag at bit [261] — should still be 0 (default, no RA-ack)
            test_count = test_count + 1;
            if (got[261] !== 1'b0) begin
                $display("[T%0d ssi1000_raflag_off] FAIL got=%b expected 0",
                         test_count, got[261]);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ssi1000_raflag_off] PASS", test_count);
            end
        end

        repeat (4) @(posedge clk);

        // T7+ — RandAccFlag=1 path: RA-Ack piggyback scenario
        //   Same SSI/MM fixture as T1 golden, but caller now signals this PDU
        //   is a response to a UL Random Access.  Verify bit [261] flips to 1
        //   and the rest of the PDU matches the RandAcc=0 golden with that
        //   one bit XOR'd.
        @(posedge clk);
        random_access_flag <= 1'b1;
        ssi                <= 24'd523;
        nr                 <= 1'b0;
        ns                 <= 1'b0;
        mm_bits            <= build_mm_accept(24'd523);
        mm_len             <= 7'd38;
        start              <= 1'b1;
        @(posedge clk);
        start              <= 1'b0;
        begin : ra_ack_checks
            reg [PDU_BITS-1:0] got_ra;
            reg [PDU_BITS-1:0] exp_ra;
            wait_valid(got_ra);
            // Expected = EXPECTED_1 with bit [261] flipped
            exp_ra = EXPECTED_1 ^ ({{(PDU_BITS-262){1'b0}}, 1'b1, 261'd0});
            test_count = test_count + 1;
            if (got_ra[261] !== 1'b1) begin
                $display("[T%0d ssi523_raflag_on] FAIL bit[261]=%b", test_count, got_ra[261]);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ssi523_raflag_on] PASS", test_count);
            end
            // Full vector compare
            test_count = test_count + 1;
            if (got_ra !== exp_ra) begin
                $display("[T%0d ssi523_raflag_goldenmatch] FAIL", test_count);
                $display("  got = 268'h%067x", got_ra);
                $display("  exp = 268'h%067x", exp_ra);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ssi523_raflag_goldenmatch] PASS", test_count);
            end
        end
        random_access_flag <= 1'b0;   // restore default
        repeat (4) @(posedge clk);

        // =====================================================================
        // Commit 6 — optional-element coverage.  Each new case sets one (or
        // all three) of power_control/slot_granting/chan_alloc flags and
        // verifies the full 268-bit MAC-RESOURCE PDU against a bluestation-
        // equivalent Python reference (/tmp/mac_resource_ref.py:
        //   build_mac_resource_dl(ssi=523, ns=0, RA=0, mm_bits=...) + flags).
        //
        // All cases reuse SSI=523 + the standard 38-bit D-LOC-UPDATE-ACCEPT
        // MM fixture, so field positions up through bit 40 stay bit-identical
        // to EXPECTED_1 and the deltas are purely in the optional block.
        // =====================================================================

        // ---- T_pc: power_control_flag=1, element=5 ------------------------
        // hdr_len = 43 + 4 = 47.  total = 47+46 = 93.  bytes=12, fill=3.
        begin : t_pc_flag
            reg [PDU_BITS-1:0] got;
            reg [PDU_BITS-1:0] exp;
            @(posedge clk);
            ssi                   <= 24'd523;
            ns                    <= 1'b0;
            nr                    <= 1'b0;
            random_access_flag    <= 1'b0;
            power_control_flag    <= 1'b1;
            power_control_element <= 4'd5;
            slot_granting_flag    <= 1'b0;
            chan_alloc_flag       <= 1'b0;
            mm_bits               <= build_mm_accept(24'd523);
            mm_len                <= 7'd38;
            start                 <= 1'b1;
            @(posedge clk);
            start                 <= 1'b0;
            wait_valid(got);
            exp = 268'h206100020ba822a300020b040000000000000000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d pc_flag_on] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d pc_flag_on] PASS", test_count);
            end
            power_control_flag    <= 1'b0;
            power_control_element <= 4'd0;
        end
        repeat (4) @(posedge clk);

        // ---- T_sg: slot_granting_flag=1, element=0x10 (grant 1 slot) -------
        // hdr_len = 43 + 8 = 51.  total = 97.  bytes=13, fill=7.
        begin : t_sg_flag
            reg [PDU_BITS-1:0] got;
            reg [PDU_BITS-1:0] exp;
            @(posedge clk);
            ssi                   <= 24'd523;
            ns                    <= 1'b0;
            nr                    <= 1'b0;
            random_access_flag    <= 1'b0;
            power_control_flag    <= 1'b0;
            slot_granting_flag    <= 1'b1;
            slot_granting_element <= 8'h10;   // cap=1 slot, delay=0
            chan_alloc_flag       <= 1'b0;
            mm_bits               <= build_mm_accept(24'd523);
            mm_len                <= 7'd38;
            start                 <= 1'b1;
            @(posedge clk);
            start                 <= 1'b0;
            wait_valid(got);
            exp = 268'h206900020b44022a300020b04000000000000000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d sg_flag_on] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d sg_flag_on] PASS", test_count);
            end
            slot_granting_flag    <= 1'b0;
            slot_granting_element <= 8'd0;
        end
        repeat (4) @(posedge clk);

        // ---- T_ca: chan_alloc_flag=1, 25-bit replace_lab element ----------
        // element = 0x0273E94B (carrier_num=1001), element_len=25.
        // hdr_len = 43 + 25 = 68.  total = 114.  bytes=15, fill=6.
        begin : t_ca_flag
            reg [PDU_BITS-1:0] got;
            reg [PDU_BITS-1:0] exp;
            @(posedge clk);
            ssi                    <= 24'd523;
            ns                     <= 1'b0;
            nr                     <= 1'b0;
            random_access_flag     <= 1'b0;
            power_control_flag     <= 1'b0;
            slot_granting_flag     <= 1'b0;
            chan_alloc_flag        <= 1'b1;
            chan_alloc_element     <= 32'h0273E94B;
            chan_alloc_element_len <= 5'd25;
            mm_bits                <= build_mm_accept(24'd523);
            mm_len                 <= 7'd38;
            start                  <= 1'b1;
            @(posedge clk);
            start                  <= 1'b0;
            wait_valid(got);
            exp = 268'h207900020b273e94b11518001058200000000000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d ca_flag_on] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d ca_flag_on] PASS", test_count);
            end
            chan_alloc_flag        <= 1'b0;
            chan_alloc_element     <= 32'd0;
            chan_alloc_element_len <= 5'd0;
        end
        repeat (4) @(posedge clk);

        // ---- T_all: all three flags=1 simultaneously ----------------------
        // hdr_len = 43 + 4 + 8 + 25 = 80.  total = 126.  bytes=16, fill=2.
        begin : t_all_flags
            reg [PDU_BITS-1:0] got;
            reg [PDU_BITS-1:0] exp;
            @(posedge clk);
            ssi                    <= 24'd523;
            ns                     <= 1'b0;
            nr                     <= 1'b0;
            random_access_flag     <= 1'b0;
            power_control_flag     <= 1'b1;
            power_control_element  <= 4'd5;
            slot_granting_flag     <= 1'b1;
            slot_granting_element  <= 8'h10;
            chan_alloc_flag        <= 1'b1;
            chan_alloc_element     <= 32'h0273E94B;
            chan_alloc_element_len <= 5'd25;
            mm_bits                <= build_mm_accept(24'd523);
            mm_len                 <= 7'd38;
            start                  <= 1'b1;
            @(posedge clk);
            start                  <= 1'b0;
            wait_valid(got);
            exp = 268'h208100020bac4273e94b11518001058200000000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d all_flags_on] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d all_flags_on] PASS", test_count);
            end
            power_control_flag     <= 1'b0;
            power_control_element  <= 4'd0;
            slot_granting_flag     <= 1'b0;
            slot_granting_element  <= 8'd0;
            chan_alloc_flag        <= 1'b0;
            chan_alloc_element     <= 32'd0;
            chan_alloc_element_len <= 5'd0;
        end
        repeat (4) @(posedge clk);

        // =====================================================================
        // Commit 2 — concatenated second MAC-RESOURCE (Option B BL-ACK).
        // Emit D-LOC-UPDATE-ACCEPT (PDU #1) + BL-ACK (PDU #2) in a single
        // 268-bit SCH/F info block.  Golden from /tmp/mac_resource_ref.py
        // build_concat_accept_plus_blaack(ssi=523, ms_ns=0/1).
        //
        // PDU #1 layout: identical to EXPECTED_1 RA=1 variant (226100020b...)
        //   - hdr 43, LLC 5 + MLE-PD 3 + MM 38, total 89 bits
        //   - LI=12, internal fill bit at position 89 (first=1)
        // PDU #2 starts at byte-offset 12 (bit 96):
        //   - hdr 43 + BL-ACK 5 = 48 bits, LI=6, byte-aligned (fill_bit_ind=0)
        // Global post-fill first bit = 1 at position 144.
        // =====================================================================
        begin : t_concat_blaack
            reg [PDU_BITS-1:0] got;
            reg [PDU_BITS-1:0] exp;
            @(posedge clk);
            ssi                    <= 24'd523;
            ns                     <= 1'b0;
            nr                     <= 1'b0;
            random_access_flag     <= 1'b1;
            power_control_flag     <= 1'b0;
            slot_granting_flag     <= 1'b0;
            chan_alloc_flag        <= 1'b0;
            mm_bits                <= build_mm_accept(24'd523);
            mm_len                 <= 7'd38;
            // Second PDU — BL-ACK with nr=0, RA-ack=1
            second_pdu_valid              <= 1'b1;
            second_pdu_length_ind         <= 6'd6;
            second_pdu_random_access_flag <= 1'b1;
            second_pdu_addr_type          <= 3'b001;
            second_pdu_ssi                <= 24'd523;
            // BL-ACK TL-SDU, MSB-aligned in 80-bit bus:
            //   {link=0, fcs=0, bl_pdu=11, nr=0} = 00110
            second_pdu_tl_sdu             <= {5'b00110, 75'b0};
            second_pdu_tl_sdu_len         <= 7'd5;
            second_pdu_pc_flag            <= 1'b0;
            second_pdu_sg_flag            <= 1'b0;
            second_pdu_ca_flag            <= 1'b0;
            start                  <= 1'b1;
            @(posedge clk);
            start                  <= 1'b0;
            wait_valid(got);
            exp = 268'h226100020b022a300020b040023100020b068000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d concat_blaack_nr0] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d concat_blaack_nr0] PASS", test_count);
            end
            // ms_ns=1 variant — flip nr bit in BL-ACK TL-SDU
            @(posedge clk);
            second_pdu_tl_sdu      <= {5'b00111, 75'b0};
            start                  <= 1'b1;
            @(posedge clk);
            start                  <= 1'b0;
            wait_valid(got);
            exp = 268'h226100020b022a300020b040023100020b078000000000000000000000000000000;
            test_count = test_count + 1;
            if (got !== exp) begin
                $display("[T%0d concat_blaack_nr1] FAIL", test_count);
                $display("  got = 268'h%067x", got);
                $display("  exp = 268'h%067x", exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d concat_blaack_nr1] PASS", test_count);
            end
            second_pdu_valid       <= 1'b0;
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
