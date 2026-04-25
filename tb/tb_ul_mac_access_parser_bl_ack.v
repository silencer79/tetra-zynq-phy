// =============================================================================
// tb_ul_mac_access_parser_bl_ack.v — verify BL-ACK detection + LLC parse with
// the bluestation-aligned bit layout (mac_access.rs::from_bitbuf).
//
// All synthetic frames here are addr_type=0 (Ssi), opt_flag=0 so the LLC
// TL-SDU starts at bit 30 (no optional length/cap field).  Frames cover:
//
//   (a) MAC-ACCESS-Ssi without LLC pattern → bl_ack_valid=0
//   (b) BL-ACK    nr=0 / 1 / has_fcs / different LLC link types
//   (c) BL-UDATA, BL-DATA(ns=0/1), BL-ADATA(ns,nr)
//   (d) BL-DATA carrying MLE/MM with mm_pdu_type=4 (U-LOC-UPDATE-DEMAND)
//
// info_bits_sys[i] : MSB-first; bit 0 is first on air.
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

    wire        pdu_type_w;
    wire        fill_bit_w;
    wire        enc_w;
    wire [1:0]  addr_type_w;
    wire [23:0] issi_w;
    wire [9:0]  event_label_w;
    wire        opt_flag_w;
    wire        frag_flag_w;
    wire [3:0]  reservation_req_w;
    wire [4:0]  length_ind_w;
    wire [3:0]  mm_pdu_w;
    wire [2:0]  loc_upd_w;
    wire [91:0] raw_w;
    wire        pdu_valid_w;
    wire [15:0] pdu_count_w;
    wire        bl_ack_valid_w;
    wire        bl_ack_nr_w;
    wire [15:0] bl_ack_count_w;
    wire        ul_llc_is_bl_data_w;
    wire        ul_llc_is_bl_ack_w;
    wire        ul_llc_has_fcs_w;
    wire        ul_llc_ns_valid_w;
    wire        ul_llc_ns_w;
    wire        ul_llc_nr_valid_w;
    wire        ul_llc_nr_w;
    wire        ul_llc_is_mle_mm_w;
    wire [3:0]  ul_llc_mm_pdu_type_w;
    wire [2:0]  ul_llc_mm_loc_upd_type_w;

    tetra_ul_mac_access_parser u_dut (
        .clk_sys                 (clk),
        .rst_n_sys               (rst_n),
        .info_bits_sys           (info_bits),
        .info_valid_sys          (info_valid),
        .crc_ok_sys              (crc_ok),
        .pdu_type_sys            (pdu_type_w),
        .fill_bit_sys            (fill_bit_w),
        .encryption_mode_sys     (enc_w),
        .ul_addr_type_sys        (addr_type_w),
        .ul_issi_sys             (issi_w),
        .ul_event_label_sys      (event_label_w),
        .optional_field_flag_sys (opt_flag_w),
        .ul_frag_flag_sys        (frag_flag_w),
        .ul_reservation_req_sys  (reservation_req_w),
        .ul_length_ind_sys       (length_ind_w),
        .mm_pdu_type_sys         (mm_pdu_w),
        .loc_upd_type_sys        (loc_upd_w),
        .raw_info_bits_sys       (raw_w),
        .pdu_valid_sys           (pdu_valid_w),
        .pdu_count_sys           (pdu_count_w),
        .bl_ack_valid_sys        (bl_ack_valid_w),
        .bl_ack_nr_sys           (bl_ack_nr_w),
        .bl_ack_count_sys        (bl_ack_count_w),
        .ul_llc_is_bl_data_sys   (ul_llc_is_bl_data_w),
        .ul_llc_is_bl_ack_sys    (ul_llc_is_bl_ack_w),
        .ul_llc_has_fcs_sys      (ul_llc_has_fcs_w),
        .ul_llc_ns_valid_sys     (ul_llc_ns_valid_w),
        .ul_llc_ns_sys           (ul_llc_ns_w),
        .ul_llc_nr_valid_sys     (ul_llc_nr_valid_w),
        .ul_llc_nr_sys           (ul_llc_nr_w),
        .ul_llc_is_mle_mm_sys    (ul_llc_is_mle_mm_w),
        .ul_llc_mm_pdu_type_sys  (ul_llc_mm_pdu_type_w),
        .ul_llc_mm_loc_upd_type_sys (ul_llc_mm_loc_upd_type_w)
    );

    // ---------------------------------------------------------------
    // Frame builder for addr_type=0 (Ssi), opt_flag=0 → LLC TL-SDU at bit 30.
    //   bit[0]    pdu_type
    //   bit[1]    fill_bit
    //   bit[2]    encrypted
    //   bits[3..4] addr_type=00
    //   bits[5..28] issi (24 bits, MSB-first)
    //   bit[29]   opt_flag=0
    //   bits[30..32] LLC link_type, has_fcs, bl_pdu_type[1]
    //   bit[32]   bl_pdu_type[0]   (NB MSB-first packing: bits[30..33] = link, fcs, bl[1], bl[0])
    //   bit[34]   ns/nr            (BL-ADATA: ns; BL-DATA: ns; BL-ACK: nr)
    //   bit[35]   nr (BL-ADATA only)
    // ---------------------------------------------------------------
    task build_frame;
        input        f_pdu;
        input        f_fill;
        input        f_enc;
        input [23:0] f_issi;
        input        f_llc_link;
        input        f_has_fcs;
        input [1:0]  f_bl_pdu;
        input        f_seq;        // ns or nr (depends on bl_pdu)
        input        f_seq2;       // BL-ADATA nr
        input [55:0] f_payload;    // bits 36..91 (TL-SDU after LLC header)
        integer i;
        begin
            info_bits = 92'd0;
            info_bits[0] = f_pdu;
            info_bits[1] = f_fill;
            info_bits[2] = f_enc;
            info_bits[3] = 1'b0;   // addr_type=0
            info_bits[4] = 1'b0;
            for (i = 0; i < 24; i = i + 1)
                info_bits[5+i] = (f_issi >> (23-i)) & 1'b1;
            info_bits[29] = 1'b0;  // opt_flag=0 → tl_sdu at bit 30
            info_bits[30] = f_llc_link;
            info_bits[31] = f_has_fcs;
            info_bits[32] = f_bl_pdu[1];   // MSB-first
            info_bits[33] = f_bl_pdu[0];
            info_bits[34] = f_seq;
            info_bits[35] = f_seq2;
            for (i = 0; i < 56; i = i + 1)
                info_bits[36+i] = (f_payload >> (55-i)) & 1'b1;
        end
    endtask

    // Captured pulse-only outputs (1-cycle wide).
    reg cap_bl_ack_valid;
    reg cap_bl_ack_nr;
    reg cap_is_bl_data;
    reg cap_is_bl_ack;
    reg cap_has_fcs;
    reg cap_ns_valid;
    reg cap_ns;
    reg cap_nr_valid;
    reg cap_nr;
    reg cap_is_mle_mm;
    reg [3:0] cap_mm_pdu;
    reg [2:0] cap_mm_loc_upd;

    task drive_frame;
        begin
            @(posedge clk); #1;
            info_valid = 1'b1;
            crc_ok     = 1'b1;
            @(posedge clk); #1;
            info_valid = 1'b0;
            crc_ok     = 1'b0;
            cap_bl_ack_valid = bl_ack_valid_w;
            cap_bl_ack_nr    = bl_ack_nr_w;
            cap_is_bl_data   = ul_llc_is_bl_data_w;
            cap_is_bl_ack    = ul_llc_is_bl_ack_w;
            cap_has_fcs      = ul_llc_has_fcs_w;
            cap_ns_valid     = ul_llc_ns_valid_w;
            cap_ns           = ul_llc_ns_w;
            cap_nr_valid     = ul_llc_nr_valid_w;
            cap_nr           = ul_llc_nr_w;
            cap_is_mle_mm    = ul_llc_is_mle_mm_w;
            cap_mm_pdu       = ul_llc_mm_pdu_type_w;
            cap_mm_loc_upd   = ul_llc_mm_loc_upd_type_w;
            @(posedge clk); #1;   // drain
        end
    endtask

    integer pass_cnt, fail_cnt;

    task expect_llc;
        input         exp_is_bl_data;
        input         exp_is_bl_ack;
        input         exp_ns_valid;
        input         exp_ns;
        input         exp_nr_valid;
        input         exp_nr;
        input [255:0] label;
        reg           ok;
        begin
            ok = (cap_is_bl_data == exp_is_bl_data) &&
                 (cap_is_bl_ack  == exp_is_bl_ack)  &&
                 (cap_ns_valid   == exp_ns_valid)   &&
                 (!exp_ns_valid || cap_ns == exp_ns) &&
                 (cap_nr_valid   == exp_nr_valid)   &&
                 (!exp_nr_valid || cap_nr == exp_nr);
            if (ok) begin
                $display("  PASS  %-40s data=%0d ack=%0d ns{v%0d:%0d} nr{v%0d:%0d}",
                         label, cap_is_bl_data, cap_is_bl_ack,
                         cap_ns_valid, cap_ns, cap_nr_valid, cap_nr);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-40s got data=%0d ack=%0d ns{v%0d:%0d} nr{v%0d:%0d} exp data=%0d ack=%0d ns{v%0d:%0d} nr{v%0d:%0d}",
                         label,
                         cap_is_bl_data, cap_is_bl_ack,
                         cap_ns_valid, cap_ns, cap_nr_valid, cap_nr,
                         exp_is_bl_data, exp_is_bl_ack,
                         exp_ns_valid, exp_ns, exp_nr_valid, exp_nr);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task expect_bl_ack;
        input         exp_valid;
        input         exp_nr;
        input [255:0] label;
        begin
            if (cap_bl_ack_valid == exp_valid &&
                (!exp_valid || cap_bl_ack_nr == exp_nr)) begin
                $display("  PASS  %-40s valid=%0d nr=%0d",
                         label, cap_bl_ack_valid, cap_bl_ack_nr);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-40s got valid=%0d nr=%0d exp valid=%0d nr=%0d",
                         label, cap_bl_ack_valid, cap_bl_ack_nr,
                         exp_valid, exp_nr);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task expect_wrapped_mm;
        input         exp_is_mle_mm;
        input  [3:0]  exp_mm_pdu;
        input  [2:0]  exp_loc_upd;
        input  [255:0] label;
        begin
            if (cap_is_mle_mm == exp_is_mle_mm &&
                (!exp_is_mle_mm ||
                 (cap_mm_pdu == exp_mm_pdu && cap_mm_loc_upd == exp_loc_upd))) begin
                $display("  PASS  %-40s mle_mm=%0d mm_pdu=%0h loc=%0h",
                         label, cap_is_mle_mm, cap_mm_pdu, cap_mm_loc_upd);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-40s got mle_mm=%0d mm_pdu=%0h loc=%0h exp mle_mm=%0d mm_pdu=%0h loc=%0h",
                         label, cap_is_mle_mm, cap_mm_pdu, cap_mm_loc_upd,
                         exp_is_mle_mm, exp_mm_pdu, exp_loc_upd);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

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

        // (a) MAC-ACCESS-Ssi with LLC link_type=1 (Advanced Link) — non-BL
        //     pattern: should NOT match BL-ACK.
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b1, 1'b1, 2'b10, 1'b0, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b0, 1'b0, "a AL link non-BL");

        // (b) BL-ACK nr=0
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b11, 1'b0, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b0, "b BL-ACK nr=0");
        expect_llc(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, "b BL-ACK nr=0 llc");

        // (c) BL-ACK nr=1
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b11, 1'b1, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b1, "c BL-ACK nr=1");

        // (d) BL-ACK-FCS nr=0 — has_fcs=1 still matches bl_pdu_type=11
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b1, 2'b11, 1'b0, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b0, "d BL-ACK-FCS nr=0");

        // (e) BL-UDATA — bl_pdu_type=10, no BL-ACK match
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b10, 1'b0, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b0, 1'b0, "e BL-UDATA");
        expect_llc(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "e BL-UDATA llc");

        // (f) BL-DATA ns=0 carrying MLE/MM + U-LOC-UPDATE-DEMAND.  Payload at
        //     bit 35 onwards: mle_pd=001, mm_pdu_type=4, loc_upd_type=011.
        //     Layout (LLC TL-SDU starts bit 30):
        //       bits 30..33 = LLC header (link=0, fcs=0, bl_pdu=01)
        //       bit  34     = ns
        //       bits 35..37 = mle_pd (3 bits)
        //       bits 38..41 = mm_pdu_type (4 bits)
        //       bits 42..44 = loc_upd_type (3 bits)
        //     Build: at the build_frame level we set seq=ns, seq2=first
        //     payload bit (which is mle_pd[2]).  Pack the rest into payload.
        //     Final 56-bit `f_payload` covers bits 36..91 (mle_pd[1:0],
        //     mm_pdu, loc_upd, then padding).
        //
        //     mle_pd[2] (bit 35)  = 0 (we send seq2=0; mle_pd=001 → MSB=0)
        //     payload[55:54] = mle_pd[1:0] = 01
        //     payload[53:50] = mm_pdu_type = 4 = 0100
        //     payload[49:47] = loc_upd_type = 011
        //     remaining 47 bits = 0
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b01, 1'b0,           // LLC=BL-DATA, ns=0
                    1'b0,                              // seq2 = mle_pd[2] = 0
                    {2'b01, 4'h4, 3'b011, 47'h0});     // payload [55:0]
        drive_frame();
        expect_llc(1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "f BL-DATA ns=0 llc");
        expect_wrapped_mm(1'b1, 4'h4, 3'b011, "f wrapped MM loc-upd");

        // (g) BL-DATA ns=1 carrying same MLE/MM — only ns flips.
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b01, 1'b1,           // ns=1
                    1'b0,
                    {2'b01, 4'h4, 3'b011, 47'h0});
        drive_frame();
        expect_llc(1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, "g BL-DATA ns=1 llc");
        expect_wrapped_mm(1'b1, 4'h4, 3'b011, "g wrapped MM loc-upd");

        // (h) BL-ADATA ns=1, nr=0 — ns at bit 34, nr at bit 35.
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b00, 1'b1, 1'b0, 56'h0);
        drive_frame();
        expect_llc(1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, "h BL-ADATA ns=1 nr=0");

        // (i) BL-ADATA ns=0, nr=1
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b00, 1'b0, 1'b1, 56'h0);
        drive_frame();
        expect_llc(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, "i BL-ADATA ns=0 nr=1");

        // (j) BL-ACK nr=1 — also check new LLC outputs alongside bl_ack_*.
        build_frame(1'b0, 1'b0, 1'b0, 24'h282F91,
                    1'b0, 1'b0, 2'b11, 1'b1, 1'b0, 56'h0);
        drive_frame();
        expect_bl_ack(1'b1, 1'b1, "j BL-ACK nr=1 legacy");
        expect_llc(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, "j BL-ACK nr=1 llc");

        $display("==========================================");
        $display("PASS=%0d FAIL=%0d  bl_ack_count=%0d",
                 pass_cnt, fail_cnt, bl_ack_count_w);
        if (fail_cnt == 0 && pass_cnt > 0)
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
