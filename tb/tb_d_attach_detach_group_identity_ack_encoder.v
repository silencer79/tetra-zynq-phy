// =============================================================================
// tb_d_attach_detach_group_identity_ack_encoder.v — Phase 7 F.7.3 TB
// =============================================================================
//
// Verifies that
// tetra_d_attach_detach_group_identity_ack_encoder.v produces an MM body
// bit-exact to all 5 DL-ACK slices documented in
// `reference_group_attach_bitexact.md` for the equivalent input
// (count=1, attach=0, lifetime=1, class=4, addr_t=0, gssi=...).
//
// Each gold-ref slice is a 124-bit MAC-RESOURCE-wrapped PDU.  The encoder
// produces only the MM portion (58 bits MSB-aligned in 128 bits).  The TB
// extracts the MM portion from each slice (bits [63:4] in our naming
// convention, or [60:1] of the lower 64 bits) and compares.
//
// Slice layout per memory:
//   bits[0..63]   MAC-RESOURCE header + LLC BL-ADATA + MLE-PD + mm_pdu_type
//   bits[64..123] MM body (60 bits = 58 useful + 2 fill from MAC-RESOURCE)
//
// We compare the top 58 bits of bits[64..]: that's bit[64..121] of the
// 124-bit slice.
//
// Test cases:
//   gold_ref_replay_slice_1   → GSSI=0x2F4D63, NR=0/NS=1
//   gold_ref_replay_slice_2   → GSSI=0x2F4D62, NR=1/NS=0
//   gold_ref_replay_slice_3   → GSSI=0x2F4D61, NR=0/NS=1
//   gold_ref_replay_slice_4   → GSSI=0x2F4D62, NR=1/NS=0  (= slice 2)
//   gold_ref_replay_slice_5   → GSSI=0x2F4D63, NR=0/NS=1  (= slice 1)
//
// (NR/NS doesn't enter the MM body — they're in the LLC BL-ADATA header.
// All 5 slices use class=4, lifetime=1, addr_t=0 in the MM portion.  The
// only varying field is GSSI.  Slices #1/#5 and #2/#4 are MM-identical.)
//
// Additional cases:
//   T6 reject_path           → accept_reject=1, MM body = 3 bits (000... )
//   T7 multi_record_attach   → 3 records (3 attaches) length=102
//   T8 attach_plus_detach    → 1 attach + 1 detach length=67 (matches the
//                              UL request layout in
//                              `reference_group_attach_bitexact.md` v1)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_d_attach_detach_group_identity_ack_encoder;

    reg          accept_reject;
    reg  [2:0]   count;
    reg  [2:0]   attach_array;
    reg  [5:0]   lifetime_array;
    reg  [8:0]   class_array;
    reg  [5:0]   at_array;
    reg  [71:0]  gssi_array;

    wire [127:0] pdu_bits_mm_w;
    wire [7:0]   pdu_len_bits_w;

    tetra_d_attach_detach_group_identity_ack_encoder u_dut (
        .accept_reject  (accept_reject),
        .count          (count),
        .attach_array   (attach_array),
        .lifetime_array (lifetime_array),
        .class_array    (class_array),
        .at_array       (at_array),
        .gssi_array     (gssi_array),
        .pdu_bits_mm    (pdu_bits_mm_w),
        .pdu_len_bits   (pdu_len_bits_w)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // -------------------------------------------------------------------
    // Build the expected 58-bit MM body for the gold-ref ACCEPT slice
    // with a single GSSI:
    //
    //   0 (accept_rej) | 0 (reserved) | 1 (obit)
    //   1 (m-bit) | 0111 (id=7) | 11'd38 (length)
    //   000001 (num_elem)
    //   0 (ATD=attach) | 01 (lifetime) | 100 (class) | 00 (at) | gssi(24)
    //   0 (trailing m-bit)
    //
    // Total = 3 + 16 + 38 + 1 = 58 bits.
    // -------------------------------------------------------------------
    function [57:0] build_expected_accept_one_gssi;
        input [23:0] gssi;
        begin
            build_expected_accept_one_gssi = {
                3'b001,             // accept_rej(0) reserved(0) obit(1)
                4'b1011,            // mbit(1) elem_id high
                7'b1110000,         // elem_id low + length high → 0111 + 0000_001
                4'b0010,            // length = ...00100110 (continuing)
                3'b110,             // length finish (this needs unification!)
                gssi[23:0],
                1'b0                // trailing
            };
            // NOTE: above is a placeholder; the proper concat is built
            // below via a clear list, not a packed splat.
        end
    endfunction

    // Cleaner expected builder via straight concatenation of the
    // per-field bits.  Returns the 58-bit MM body LSB-aligned in a 64-bit
    // word (top 6 bits = 0).
    function [63:0] build_expected_accept_clean;
        input [23:0] gssi;
        reg [57:0] mm;
        begin
            mm = {
                1'b0,           // accept_rej
                1'b0,           // reserved
                1'b1,           // obit
                1'b1,           // m-bit (gid_dl present)
                4'd7,           // elem_id
                11'd38,         // length
                6'd1,           // num_elem
                1'b0,           // ATD = attach
                2'd1,           // lifetime
                3'd4,           // class_of_usage
                2'd0,           // address_type
                gssi,           // 24-bit gssi
                1'b0            // trailing m-bit
            };
            build_expected_accept_clean = {6'd0, mm};
        end
    endfunction

    function [127:0] build_expected_accept_msb;
        input [23:0] gssi;
        reg [63:0]   tmp;
        begin
            tmp = build_expected_accept_clean(gssi);
            build_expected_accept_msb = {tmp[57:0], 70'd0};
        end
    endfunction

    task drive_and_check_accept;
        input [255:0] label;
        input [23:0]  gssi;
        reg [127:0]   expected;
        reg [127:0]   actual;
        reg [127:0]   mask;
        begin
            accept_reject  = 1'b0;
            count          = 3'd1;
            attach_array   = 3'b000;
            lifetime_array = {4'd0, 2'd1};      // slot 0 = lt=1, others 0
            class_array    = {6'd0, 3'd4};      // slot 0 = class=4
            at_array       = 6'b00_00_00;
            gssi_array     = {48'd0, gssi};
            #1;
            expected = build_expected_accept_msb(gssi);
            // Mask to 58 useful bits.
            mask     = {58{1'b1}} << (128 - 58);
            actual   = pdu_bits_mm_w & mask;
            if (pdu_len_bits_w !== 8'd58) begin
                $display("  FAIL %-30s len got=%0d exp=58", label, pdu_len_bits_w);
                fail_cnt = fail_cnt + 1;
            end else if ((actual ^ expected) === 128'd0) begin
                $display("  PASS %-30s gssi=0x%06X", label, gssi);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %-30s gssi=0x%06X", label, gssi);
                $display("       got=%032h", actual);
                $display("       exp=%032h", expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Compare the encoder MM body against the MM portion extracted from
    // a 124-bit gold-ref slice.  The MM body sits at bits [63..4] of the
    // 124-bit slice (positions 64..123 of the 124-bit string MSB-first).
    // We extract 58 bits = positions 64..121 of the slice and compare to
    // the encoder's top-58 bits.
    // -------------------------------------------------------------------
    task drive_and_check_against_slice;
        input [255:0] label;
        input [23:0]  gssi;
        input [123:0] slice_lsb_first;   // bit[0] = on-air first → slice[123]
        reg [123:0]   slice_msb_first;   // [123]=on-air first
        reg [57:0]    expected_mm;
        reg [127:0]   expected_msb;
        reg [127:0]   actual;
        reg [127:0]   mask;
        integer       k;
        begin
            // Convert LSB-first input (input is [123:0], MSB-first from
            // the on-air convention).  No conversion needed: the input
            // is already MSB-first as documented in the memory.  The MM
            // portion lives at bits [59:0] of the 124-bit MSB-first
            // slice (the top 64 bits are MAC-RESOURCE/LLC/MLE header).
            //
            // Layout: slice_msb_first[123:64] = MAC+LLC+MLE header (64 bits).
            //         slice_msb_first[63:4]   = MM body (60 bits, top 58
            //                                            useful + 2 fill).
            slice_msb_first = slice_lsb_first;
            // Slice convention: bit[123] = first on-air, bit[0] = last
            // on-air.  MAC-RESOURCE header is 64 bits (positions 0..63
            // on-air) at slice_msb_first[123:60].  MM body 60 bits at
            // slice_msb_first[59:0].  Top 58 bits of MM (skip 2 fill at
            // tail) = slice_msb_first[59:2].
            expected_mm = slice_msb_first[59:2];

            accept_reject  = 1'b0;
            count          = 3'd1;
            attach_array   = 3'b000;
            lifetime_array = {4'd0, 2'd1};
            class_array    = {6'd0, 3'd4};
            at_array       = 6'b00_00_00;
            gssi_array     = {48'd0, gssi};
            #1;
            expected_msb = {expected_mm, 70'd0};
            mask         = {58{1'b1}} << (128 - 58);
            actual       = pdu_bits_mm_w & mask;
            if (pdu_len_bits_w !== 8'd58) begin
                $display("  FAIL %-30s len got=%0d exp=58", label, pdu_len_bits_w);
                fail_cnt = fail_cnt + 1;
            end else if ((actual ^ expected_msb) === 128'd0) begin
                $display("  PASS %-30s gssi=0x%06X (gold-ref bit-exact)",
                         label, gssi);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %-30s gssi=0x%06X", label, gssi);
                $display("       got_mm[63:6]=%015h", actual[127:70]);
                $display("       exp_mm[63:6]=%015h", expected_msb[127:70]);
                fail_cnt = fail_cnt + 1;
            end
            // Suppress unused warning
            for (k = 0; k < 1; k = k + 1) begin /* */ end
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_d_attach_detach_group_identity_ack_encoder.vcd");
        $dumpvars(0, tb_d_attach_detach_group_identity_ack_encoder);

        accept_reject = 1'b0;
        count         = 3'd0;
        attach_array  = 3'd0;
        lifetime_array= 6'd0;
        class_array   = 9'd0;
        at_array      = 6'd0;
        gssi_array    = 72'd0;
        #10;


        // ---------------------------------------------------------------
        $display("\n[T1] gold_ref_replay_slice_1  GSSI=0x2F4D63 (slice #1)");
        drive_and_check_against_slice("T1 gold_ref_replay_slice_1",
            24'h2F4D63,
            124'b0010000010000001001010000010111111110100010000000000000010011011001101110000010011000000100110000001011110100110101100011010);

        $display("\n[T2] gold_ref_replay_slice_2  GSSI=0x2F4D62 (slice #2)");
        drive_and_check_against_slice("T2 gold_ref_replay_slice_2",
            24'h2F4D62,
            124'b0010000010000001001010000010111111110100010000000000000100011011001101110000010011000000100110000001011110100110101100010010);

        $display("\n[T3] gold_ref_replay_slice_3  GSSI=0x2F4D61 (slice #3)");
        drive_and_check_against_slice("T3 gold_ref_replay_slice_3",
            24'h2F4D61,
            124'b0010000010000001001010000010111111110100010000000000000010011011001101110000010011000000100110000001011110100110101100001010);

        $display("\n[T4] gold_ref_replay_slice_4  GSSI=0x2F4D62 (slice #4 = #2)");
        drive_and_check_against_slice("T4 gold_ref_replay_slice_4",
            24'h2F4D62,
            124'b0010000010000001001010000010111111110100010000000000000100011011001101110000010011000000100110000001011110100110101100010010);

        $display("\n[T5] gold_ref_replay_slice_5  GSSI=0x2F4D63 (slice #5 = #1)");
        drive_and_check_against_slice("T5 gold_ref_replay_slice_5",
            24'h2F4D63,
            124'b0010000010000001001010000010111111110100010000000000000010011011001101110000010011000000100110000001011110100110101100011010);

        // ---------------------------------------------------------------
        $display("\n[T6] reject_path  accept_reject=1 → 3-bit MM body");
        accept_reject  = 1'b1;
        count          = 3'd0;
        gssi_array     = 72'd0;
        #1;
        if (pdu_len_bits_w !== 8'd3) begin
            $display("  FAIL T6 len got=%0d exp=3", pdu_len_bits_w);
            fail_cnt = fail_cnt + 1;
        end else if (pdu_bits_mm_w[127:125] !== 3'b100) begin
            $display("  FAIL T6 hdr got=%03b exp=100", pdu_bits_mm_w[127:125]);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  PASS T6 reject_path");
            pass_cnt = pass_cnt + 1;
        end

        // ---------------------------------------------------------------
        $display("\n[T7] multi_record_attach (3 attaches) → length=102");
        accept_reject  = 1'b0;
        count          = 3'd3;
        attach_array   = 3'b000;
        lifetime_array = {2'd1, 2'd1, 2'd1};
        class_array    = {3'd4, 3'd4, 3'd4};
        at_array       = 6'b00_00_00;
        gssi_array     = {24'h2F4D63, 24'h2F4D62, 24'h2F4D61};
        #1;
        if (pdu_len_bits_w !== 8'(20 + 6 + 32*3)) begin
            $display("  FAIL T7 len got=%0d exp=%0d", pdu_len_bits_w, 20+6+32*3);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  PASS T7 multi_record_attach len=%0d", pdu_len_bits_w);
            pass_cnt = pass_cnt + 1;
        end

        // ---------------------------------------------------------------
        $display("\n[T8] attach_plus_detach length=67");
        accept_reject  = 1'b0;
        count          = 3'd2;
        attach_array   = 3'b010;        // slot0 attach, slot1 detach
        lifetime_array = {4'd0, 2'd1};  // slot0 lt=1
        class_array    = {3'd0, 3'd2, 3'd4};
        // slot1 detach_code = class_array[5:4] = 2'd0 from {3'd0, 3'd2,...}
        // Actually class_array[5:3] = 3'd2, so slot1 detach_code = [4:3] = 2'd2.
        at_array       = 6'b00_00_00;
        gssi_array     = {24'd0, 24'h2F4D62, 24'h2F4D63};
        #1;
        // expected len = 20 + 6 + 32 + 29 = 87
        // Wait — recompute:  20 + (6 + 32 + 29) = 20 + 67 = 87
        if (pdu_len_bits_w !== 8'd87) begin
            $display("  FAIL T8 len got=%0d exp=87", pdu_len_bits_w);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  PASS T8 attach_plus_detach len=%0d", pdu_len_bits_w);
            pass_cnt = pass_cnt + 1;
        end

        // ---------------------------------------------------------------
        $display("\n========================================================");
        $display("tb_d_attach_detach_group_identity_ack_encoder:  PASS=%0d  FAIL=%0d",
                 pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("========================================================");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
