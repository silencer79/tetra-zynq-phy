// =============================================================================
// tb_ul_mac_access_parser_bl_ack.v — Verify BL-ACK detection in MAC-ACCESS
// parser (M1 of 2026-04-24 post-accept flow).
//
// The main `tb_ul_mac_access_parser` already covers the MAC-ACCESS-header
// fields against bluestation-aligned Python reference vectors.  This TB is
// self-contained: it feeds synthetic 92-bit frames with
//   (a) U-LOC-UPDATE-DEMAND shape  — no BL-ACK pattern, bl_ack_valid=0
//   (b) BL-ACK  with N(R)=0         — bl_ack_valid=1, nr=0
//   (c) BL-ACK  with N(R)=1         — bl_ack_valid=1, nr=1
//   (d) BL-ACK-FCS with N(R)=0      — has_fcs=1 still matches bl_pdu_type=11
//   (e) BL-UDATA dummy              — bl_pdu_type=10, bl_ack_valid=0
//
// Frames are built MSB-first: info_bits_sys[0] = first bit on air.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_mac_access_parser_bl_ack;

    localparam integer CLK_PERIOD = 10;

    reg clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg  [91:0] info_bits;
    reg         info_valid;
    reg         crc_ok;

    wire [1:0]  pdu_type_w;
    wire        fill_bit_w;
    wire [1:0]  enc_w;
    wire        access_ack_w;
    wire [2:0]  addr_type_w;
    wire [9:0]  short_ssi_w;
    wire [3:0]  mm_pdu_w;
    wire [2:0]  loc_upd_w;
    wire [91:0] raw_w;
    wire        pdu_valid_w;
    wire [15:0] pdu_count_w;
    wire        bl_ack_valid_w;
    wire        bl_ack_nr_w;
    wire [15:0] bl_ack_count_w;

    tetra_ul_mac_access_parser u_dut (
        .clk_sys              (clk),
        .rst_n_sys            (rst_n),
        .info_bits_sys        (info_bits),
        .info_valid_sys       (info_valid),
        .crc_ok_sys           (crc_ok),
        .pdu_type_sys         (pdu_type_w),
        .fill_bit_sys         (fill_bit_w),
        .encryption_mode_sys  (enc_w),
        .access_ack_sys       (access_ack_w),
        .address_type_sys     (addr_type_w),
        .short_ssi_sys        (short_ssi_w),
        .mm_pdu_type_sys      (mm_pdu_w),
        .loc_upd_type_sys     (loc_upd_w),
        .raw_info_bits_sys    (raw_w),
        .pdu_valid_sys        (pdu_valid_w),
        .pdu_count_sys        (pdu_count_w),
        .bl_ack_valid_sys     (bl_ack_valid_w),
        .bl_ack_nr_sys        (bl_ack_nr_w),
        .bl_ack_count_sys     (bl_ack_count_w)
    );

    // ---------------------------------------------------------------
    // Helper: build a synthetic 92-bit MAC-ACCESS info frame.
    // Bit-index in info_bits[i] uses i=0 as MSB / first on-air bit
    // (matches `info_bits_sys[0]` convention in the parser).
    // ---------------------------------------------------------------
    // MAC-ACCESS header fields (existing parser's 19-bit layout):
    //   [0:2)   pdu_type
    //   [2:3)   fill_bit
    //   [3:5)   encryption_mode
    //   [5:6)   access_ack
    //   [6:9)   address_type
    //   [9:19)  short_ssi
    // LLC header fields (new BL-ACK detector):
    //   [19]    llc_link_type
    //   [20]    has_fcs
    //   [21:23) bl_pdu_type
    //   [23]    N(R)  (for BL-ACK) / N(S) (for BL-DATA)
    // ---------------------------------------------------------------
    task build_frame;
        input [1:0]  f_pdu;
        input        f_fill;
        input [1:0]  f_enc;
        input        f_ack;
        input [2:0]  f_at;
        input [9:0]  f_ssi;
        input        f_llc_link;      // bit 19
        input        f_has_fcs;       // bit 20
        input [1:0]  f_bl_pdu;        // bits 21..22
        input        f_seq;           // bit 23 (N(R) or N(S))
        input [67:0] f_tail;          // bits 24..91
        integer i;
        begin
            info_bits = 92'd0;
            info_bits[0] = f_pdu[1];
            info_bits[1] = f_pdu[0];
            info_bits[2] = f_fill;
            info_bits[3] = f_enc[1];
            info_bits[4] = f_enc[0];
            info_bits[5] = f_ack;
            info_bits[6] = f_at[2];
            info_bits[7] = f_at[1];
            info_bits[8] = f_at[0];
            for (i = 0; i < 10; i = i + 1)
                info_bits[9+i] = f_ssi[9-i];
            info_bits[19] = f_llc_link;
            info_bits[20] = f_has_fcs;
            info_bits[21] = f_bl_pdu[1];
            info_bits[22] = f_bl_pdu[0];
            info_bits[23] = f_seq;
            for (i = 0; i < 68; i = i + 1)
                info_bits[24+i] = f_tail[67-i];
        end
    endtask

    // Captured values during the 1-cycle pulse.  Refreshed per drive_frame.
    reg        cap_bl_ack_valid;
    reg        cap_bl_ack_nr;

    task drive_frame;
        begin
            cap_bl_ack_valid = 1'b0;
            cap_bl_ack_nr    = 1'b0;
            @(posedge clk); #1;
            info_valid = 1'b1;
            crc_ok     = 1'b1;
            @(posedge clk); #1;
            info_valid = 1'b0;
            crc_ok     = 1'b0;
            // Parser latches on this edge; pulse is high right now.
            if (bl_ack_valid_w) begin
                cap_bl_ack_valid = 1'b1;
                cap_bl_ack_nr    = bl_ack_nr_w;
            end
            @(posedge clk); #1;    // drain cycle, pulse back to 0
        end
    endtask

    // ---------------------------------------------------------------
    integer pass_cnt, fail_cnt;
    task expect_bl_ack;
        input        exp_valid;
        input        exp_nr;
        input [255:0] label;
        begin
            if (cap_bl_ack_valid == exp_valid &&
                (!exp_valid || cap_bl_ack_nr == exp_nr)) begin
                $display("  PASS  %-32s valid=%0d nr=%0d",
                         label, cap_bl_ack_valid, cap_bl_ack_nr);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-32s got valid=%0d nr=%0d  exp valid=%0d nr=%0d",
                         label, cap_bl_ack_valid, cap_bl_ack_nr, exp_valid, exp_nr);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("sim_out/tb_ul_mac_access_parser_bl_ack.vcd");
        $dumpvars(0, tb_ul_mac_access_parser_bl_ack);

        rst_n      = 1'b0;
        info_bits  = 92'd0;
        info_valid = 1'b0;
        crc_ok     = 1'b0;
        pass_cnt   = 0;
        fail_cnt   = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=== tb_ul_mac_access_parser_bl_ack ===");

        // (a) U-LOC-UPDATE-DEMAND — empirical MTP3550 layout: aux=0xE at
        //     bits [19:23) which decodes to llc_link=1, has_fcs=1, bl_pdu=10
        //     (BL-UDATA) — does NOT match BL-ACK pattern, bl_ack_valid=0.
        build_frame(2'b00, 1'b0, 2'b00, 1'b1, 3'b010, 10'd523,
                    1'b1, 1'b1, 2'b10, 1'b0, 68'h0);   // aux=0xE
        drive_frame();
        expect_bl_ack(1'b0, 1'b0, "a U-LOC-UPDATE-DEMAND");

        // (b) BL-ACK  with N(R)=0 — link=0, has_fcs=0, bl_pdu=11, nr=0
        build_frame(2'b00, 1'b0, 2'b00, 1'b1, 3'b010, 10'd523,
                    1'b0, 1'b0, 2'b11, 1'b0, 68'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b0, "b BL-ACK nr=0");

        // (c) BL-ACK  with N(R)=1
        build_frame(2'b00, 1'b0, 2'b00, 1'b1, 3'b010, 10'd523,
                    1'b0, 1'b0, 2'b11, 1'b1, 68'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b1, "c BL-ACK nr=1");

        // (d) BL-ACK-FCS N(R)=0 — has_fcs=1 still matches bl_pdu_type=11
        build_frame(2'b00, 1'b0, 2'b00, 1'b1, 3'b010, 10'd523,
                    1'b0, 1'b1, 2'b11, 1'b0, 68'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b0, "d BL-ACK-FCS nr=0");

        // (e) BL-UDATA (bl_pdu_type=10) — no BL-ACK match
        build_frame(2'b00, 1'b0, 2'b00, 1'b1, 3'b010, 10'd523,
                    1'b0, 1'b0, 2'b10, 1'b0, 68'h0);
        drive_frame();
        expect_bl_ack(1'b0, 1'b0, "e BL-UDATA");

        $display("==========================================");
        $display("PASS=%0d FAIL=%0d  bl_ack_count=%0d",
                 pass_cnt, fail_cnt, bl_ack_count_w);
        if (fail_cnt == 0 && pass_cnt == 5)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("==========================================");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("WATCHDOG");
        $finish;
    end

endmodule

`default_nettype wire
