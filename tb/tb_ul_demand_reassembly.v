// =============================================================================
// tb_ul_demand_reassembly.v — Phase 7 F.1 unit TB
// =============================================================================
//
// Verifies tetra_ul_demand_reassembly.v against the bit-exact UL-Demand-
// Reassembly spec in:
//   - reference_demand_reassembly_bitexact.md (corrected 2026-04-26)
//   - docs/PROTOCOL.md §6.4a
//   - docs/ARCHITECTURE.md §9.8.1
//
// On-air sequence:
//   UL#0  SCH/HU  MAC-ACCESS frag=1   →  bits[48..91]  = 44 bit fragment 1
//   UL#1  SCH/HU  MAC-END-HU          →  bits[ 7..91]  = 85 bit fragment 2
//   reassembled_body[128:0] = ul0_bits[48..91] ++ ul1_bits[7..91]  (129 bit)
//
// Test cases:
//   T1: frag1 arrives, no end_hu within T0  → drop_cnt = 1, no reassembled.
//   T2: gold-ref frag1 + gold-ref end_hu within T0 → reassembled_valid pulse
//       AND body matches the bit-exact splice; reassembled_ssi = frag1_ssi.
//   T3: Two SSIs in flight; second frag1 takes slot 1; both end_hu pulses
//       resolve correctly → reassembled_cnt = 2.
//   T4: MTP3550-style end_hu hex (`D4 1C 3C 02 40 50 00 00 01 20 00 00`)
//       → reassembled_body carries GSSI=0x000001 at the documented position.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_demand_reassembly;

    localparam integer CLK_PERIOD = 10;

    reg clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    // DUT inputs
    reg [3:0]   t0_frames;
    reg         frame_tick;
    reg         frag1_pulse;
    reg [23:0]  frag1_ssi;
    reg [43:0]  frag1_bits;
    reg         end_hu_pulse;
    reg [23:0]  end_hu_ssi;
    reg [84:0]  end_hu_bits;

    // DUT outputs
    wire        reassembled_valid_w;
    wire [128:0] reassembled_body_w;
    wire [23:0] reassembled_ssi_w;
    wire [15:0] reassembled_cnt_w;
    wire [15:0] drop_cnt_w;
    wire [1:0]  busy_slots_w;

    tetra_ul_demand_reassembly #(
        .T0_FRAMES_DEFAULT(2)
    ) u_dut (
        .clk_sys              (clk),
        .rst_n_sys            (rst_n),
        .t0_frames_sys        (t0_frames),
        .frame_tick_sys       (frame_tick),
        .frag1_pulse_sys      (frag1_pulse),
        .frag1_ssi_sys        (frag1_ssi),
        .frag1_bits_sys       (frag1_bits),
        .end_hu_pulse_sys     (end_hu_pulse),
        .end_hu_ssi_sys       (end_hu_ssi),
        .end_hu_bits_sys      (end_hu_bits),
        .reassembled_valid_sys(reassembled_valid_w),
        .reassembled_body_sys (reassembled_body_w),
        .reassembled_ssi_sys  (reassembled_ssi_w),
        .reassembled_cnt_sys  (reassembled_cnt_w),
        .drop_cnt_sys         (drop_cnt_w),
        .busy_slots_sys       (busy_slots_w)
    );

    integer pass_cnt;
    integer fail_cnt;

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    // Pack 12 bytes (MSB-first within each byte) into 92 bits.  bit[0] of
    // the 92-bit buffer is the on-air MSB of byte[0].  Same convention the
    // parser uses on info_bits_sys.
    function [91:0] pack92;
        input [7:0] b0, b1, b2, b3, b4, b5;
        input [7:0] b6, b7, b8, b9, b10, b11;
        integer k;
        reg [7:0] bytes [0:11];
        begin
            bytes[ 0] = b0;  bytes[ 1] = b1;  bytes[ 2] = b2;  bytes[ 3] = b3;
            bytes[ 4] = b4;  bytes[ 5] = b5;  bytes[ 6] = b6;  bytes[ 7] = b7;
            bytes[ 8] = b8;  bytes[ 9] = b9;  bytes[10] = b10; bytes[11] = b11;
            pack92 = 92'd0;
            for (k = 0; k < 92; k = k + 1)
                pack92[k] = (bytes[k/8] >> (7 - (k%8))) & 1'b1;
        end
    endfunction

    // Extract bits[48..91] (44 bits) from a 92-bit info buffer, MSB-first
    // into the 44-bit bus.  bus[43] = info[48], bus[0] = info[91].
    function [43:0] slice44_from_48;
        input [91:0] info;
        integer k;
        begin
            slice44_from_48 = 44'd0;
            for (k = 0; k < 44; k = k + 1)
                slice44_from_48[43 - k] = info[48 + k];
        end
    endfunction

    // Extract bits[7..91] (85 bits) from a 92-bit info buffer, MSB-first.
    // bus[84] = info[7], bus[0] = info[91].
    function [84:0] slice85_from_7;
        input [91:0] info;
        integer k;
        begin
            slice85_from_7 = 85'd0;
            for (k = 0; k < 85; k = k + 1)
                slice85_from_7[84 - k] = info[7 + k];
        end
    endfunction

    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    task drive_frag1;
        input [23:0] ssi;
        input [43:0] bits44;
        begin
            @(posedge clk); #1;
            frag1_pulse = 1'b1;
            frag1_ssi   = ssi;
            frag1_bits  = bits44;
            @(posedge clk); #1;
            frag1_pulse = 1'b0;
        end
    endtask

    task drive_end_hu;
        input [23:0] ssi;
        input [84:0] bits85;
        begin
            @(posedge clk); #1;
            end_hu_pulse = 1'b1;
            end_hu_ssi   = ssi;
            end_hu_bits  = bits85;
            @(posedge clk); #1;
            end_hu_pulse = 1'b0;
        end
    endtask

    task pulse_frame_tick;
        begin
            @(posedge clk); #1;
            frame_tick = 1'b1;
            @(posedge clk); #1;
            frame_tick = 1'b0;
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
                $display("  FAIL %-40s got=0x%08X exp=0x%08X", label, got, exp_v);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task expect_eq129;
        input [255:0] label;
        input [128:0] got;
        input [128:0] exp_v;
        begin
            if (got === exp_v) begin
                $display("  PASS %-40s got=0x%033X", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %-40s", label);
                $display("       got=0x%033X", got);
                $display("       exp=0x%033X", exp_v);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Reference vectors — bit-exact from corrected memory + PROTOCOL.md
    // -------------------------------------------------------------------

    // Gold-Ref UL#0:  01 41 7F A7 01 12 66 34 20 C1 22 60   (Sepura, ITSI=0x282FF4)
    // Gold-Ref UL#1:  D4 1C 3C 02 40 50 2F 4D 61 20 00 00   (GSSI=0x2F4D61)
    //
    // MTP3550 UL#0:   01 41 7C 8F 01 12 66 34 20 C1 22 60   (ssi=0x282F91)
    // MTP3550 UL#6:   D4 1C 3C 02 40 50 00 00 01 20 00 00   (GSSI=0x000001)

    wire [91:0] gold_ul0_w = pack92(
        8'h01, 8'h41, 8'h7F, 8'hA7, 8'h01, 8'h12,
        8'h66, 8'h34, 8'h20, 8'hC1, 8'h22, 8'h60
    );
    wire [91:0] gold_ul1_w = pack92(
        8'hD4, 8'h1C, 8'h3C, 8'h02, 8'h40, 8'h50,
        8'h2F, 8'h4D, 8'h61, 8'h20, 8'h00, 8'h00
    );
    wire [91:0] mtp_ul0_w = pack92(
        8'h01, 8'h41, 8'h7C, 8'h8F, 8'h01, 8'h12,
        8'h66, 8'h34, 8'h20, 8'hC1, 8'h22, 8'h60
    );
    wire [91:0] mtp_ul1_w = pack92(
        8'hD4, 8'h1C, 8'h3C, 8'h02, 8'h40, 8'h50,
        8'h00, 8'h00, 8'h01, 8'h20, 8'h00, 8'h00
    );

    wire [43:0] gold_frag1_w = slice44_from_48(gold_ul0_w);
    wire [84:0] gold_end_hu_w = slice85_from_7(gold_ul1_w);
    wire [43:0] mtp_frag1_w  = slice44_from_48(mtp_ul0_w);
    wire [84:0] mtp_end_hu_w = slice85_from_7(mtp_ul1_w);

    // Expected reassembled body = frag1 (44 MSB) ++ end_hu (85 LSB) = 129 bit.
    wire [128:0] gold_body_exp_w = {gold_frag1_w, gold_end_hu_w};
    wire [128:0] mtp_body_exp_w  = {mtp_frag1_w,  mtp_end_hu_w};

    // -------------------------------------------------------------------
    // Initial sequence
    // -------------------------------------------------------------------
    initial begin
        $dumpfile("sim_out/tb_ul_demand_reassembly.vcd");
        $dumpvars(0, tb_ul_demand_reassembly);

        rst_n        = 1'b0;
        t0_frames    = 4'd0;        // → use default (2)
        frame_tick   = 1'b0;
        frag1_pulse  = 1'b0;
        frag1_ssi    = 24'd0;
        frag1_bits   = 44'd0;
        end_hu_pulse = 1'b0;
        end_hu_ssi   = 24'd0;
        end_hu_bits  = 85'd0;
        pass_cnt     = 0;
        fail_cnt     = 0;

        repeat (4) tick;
        rst_n = 1'b1;
        repeat (4) tick;

        // Show first the bit-exact derivation matches the spec hex slice.
        $display("------------------------------------------------------------------");
        $display("Reference vectors:");
        $display("  gold_ul0  hex = 01 41 7F A7 01 12 66 34 20 C1 22 60");
        $display("  gold_frag1[43:0]   = 0x%011X (44 bit, expected 0x6634_20C1_226)",
                 gold_frag1_w);
        $display("  gold_ul1  hex = D4 1C 3C 02 40 50 2F 4D 61 20 00 00");
        $display("  gold_end_hu[84:0]  = 0x%022X", gold_end_hu_w);
        $display("  expected body[128:0] = 0x%033X", gold_body_exp_w);
        $display("------------------------------------------------------------------");

        // ---------------------------------------------------------------
        // T1: frag1 alone, T0-timeout
        // ---------------------------------------------------------------
        $display("\n[T1] frag1 alone, T0=2, no end_hu → drop_cnt should be 1");
        drive_frag1(24'h282FF4, gold_frag1_w);
        expect_eq32("T1 occ_after_frag1", {30'd0, busy_slots_w}, 32'd1);
        // Tick T0+1 frames
        pulse_frame_tick;  // t0_left: 2 → 1
        pulse_frame_tick;  // t0_left: 1 → 0 + slot freed + drop_cnt++
        repeat (4) tick;
        expect_eq32("T1 drop_cnt",      {16'd0, drop_cnt_w}, 32'd1);
        expect_eq32("T1 reass_cnt",     {16'd0, reassembled_cnt_w}, 32'd0);
        expect_eq32("T1 occ_after_t0",  {30'd0, busy_slots_w}, 32'd0);

        // ---------------------------------------------------------------
        // T2: gold-ref frag1 + end_hu within T0, body bit-exact
        // ---------------------------------------------------------------
        $display("\n[T2] gold-ref frag1 + end_hu within T0 → reassembled_valid + body bit-exact");
        drive_frag1(24'h282FF4, gold_frag1_w);
        // No frame_tick — within T0
        drive_end_hu(24'h282FF4, gold_end_hu_w);
        // The DUT registers reassembled_body on the same cycle that
        // end_hu_pulse fires; capture is one tick after `drive_end_hu`
        // returns (it ends right after the pulse).
        @(posedge clk); #1;
        expect_eq32("T2 reass_cnt",      {16'd0, reassembled_cnt_w}, 32'd1);
        expect_eq32("T2 drop_cnt_unchanged", {16'd0, drop_cnt_w}, 32'd1);
        expect_eq32("T2 reass_ssi",      {8'd0, reassembled_ssi_w}, 32'h00282FF4);
        expect_eq129("T2 reass_body_bitexact", reassembled_body_w, gold_body_exp_w);
        expect_eq32("T2 slot_freed",     {30'd0, busy_slots_w}, 32'd0);

        // ---------------------------------------------------------------
        // T3: two simultaneous reassemblies, different SSI
        // ---------------------------------------------------------------
        $display("\n[T3] two SSIs in flight → both reassemble correctly");
        drive_frag1(24'hAAAA01, gold_frag1_w);   // → slot 0
        drive_frag1(24'hBBBB02, mtp_frag1_w);    // → slot 1
        expect_eq32("T3 both_slots_occ", {30'd0, busy_slots_w}, 32'd3);
        // Resolve B first then A — SSIs must route to the right slot.
        drive_end_hu(24'hBBBB02, mtp_end_hu_w);
        @(posedge clk); #1;
        expect_eq32("T3 first_reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00BBBB02);
        expect_eq32("T3 reass_cnt_2",    {16'd0, reassembled_cnt_w}, 32'd2);
        drive_end_hu(24'hAAAA01, gold_end_hu_w);
        @(posedge clk); #1;
        expect_eq32("T3 second_reass_ssi", {8'd0, reassembled_ssi_w}, 32'h00AAAA01);
        expect_eq32("T3 reass_cnt_3",     {16'd0, reassembled_cnt_w}, 32'd3);
        expect_eq32("T3 drop_cnt_unchanged", {16'd0, drop_cnt_w}, 32'd1);
        expect_eq32("T3 all_slots_freed",  {30'd0, busy_slots_w}, 32'd0);

        // ---------------------------------------------------------------
        // T4: MTP3550-style hex, GSSI=0x000001 visible in body
        // ---------------------------------------------------------------
        $display("\n[T4] MTP3550 frag1+end_hu → body contains GSSI=0x000001");
        drive_frag1(24'h282F91, mtp_frag1_w);
        drive_end_hu(24'h282F91, mtp_end_hu_w);
        @(posedge clk); #1;
        expect_eq32("T4 reass_ssi",  {8'd0, reassembled_ssi_w}, 32'h00282F91);
        expect_eq129("T4 body_bitexact", reassembled_body_w, mtp_body_exp_w);

        // The 24-bit GSSI sits at on-air bits [48..71] of UL#1, which after
        // slice from bit 7 lands at end_hu_bits[84-41 : 84-64] = [43:20]
        // (MSB-first), and after the 44-bit frag1 prepend lands at body
        // [128-44-41 : 128-44-64] = [43:20].  body[43:20] should equal the
        // 24-bit hex bytes 6..8 = 0x000001.
        begin : check_gssi_pos
            reg [23:0] gssi_field;
            integer kk;
            // body MSB-first: body[128] = first on-air bit.  GSSI MSB is on-air
            // UL#1 bit 48 → body offset (44 prefix) + (48-7) = 44 + 41 = 85.
            // body[128-85] = body[43] is the GSSI MSB; body[20] is the LSB.
            gssi_field = 24'd0;
            for (kk = 0; kk < 24; kk = kk + 1)
                gssi_field[23 - kk] = reassembled_body_w[43 - kk];
            expect_eq32("T4 gssi_in_body", {8'd0, gssi_field}, 32'h00000001);
        end

        // Same GSSI-position check for the gold body (T2 was already run;
        // re-issue to keep the in-flight body cleared first).
        $display("\n[T2b] same GSSI-position check on gold body");
        drive_frag1(24'h282FF4, gold_frag1_w);
        drive_end_hu(24'h282FF4, gold_end_hu_w);
        @(posedge clk); #1;
        begin : check_gold_gssi_pos
            reg [23:0] gold_gssi;
            integer kk2;
            gold_gssi = 24'd0;
            for (kk2 = 0; kk2 < 24; kk2 = kk2 + 1)
                gold_gssi[23 - kk2] = reassembled_body_w[43 - kk2];
            expect_eq32("T2b gold_gssi_in_body", {8'd0, gold_gssi}, 32'h002F4D61);
        end

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        $display("\n========================================================");
        $display("tb_ul_demand_reassembly:  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("========================================================");
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
