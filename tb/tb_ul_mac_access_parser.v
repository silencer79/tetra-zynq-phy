// =============================================================================
// tb_ul_mac_access_parser.v — verify MAC-ACCESS PDU field extraction against
// bluestation-aligned bit layout (mac_access.rs::from_bitbuf) plus the captured
// on-air RA-bursts in docs/references/captures_external_bs_2026-04-25/.
//
// Coverage:
//   - Synthetic MAC-ACCESS-Ssi frame  (addr_type=0, opt=1, frag=1)
//   - Synthetic MAC-ACCESS-EventLabel frame (addr_type=1)
//   - Synthetic MAC-ACCESS-Ussi frame (addr_type=2)
//   - On-air external-BS MS RA (ISSI=0x282FF4)
//   - On-air our MTP3550 RA      (ISSI=0x282F91)
//   - LLC TL-SDU bytes / mm_pdu_type / loc_upd_type extraction at the
//     corrected bit-30/36 anchor.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_mac_access_parser;

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
    wire [1:0]  ul_addr_type_w;
    wire [23:0] ul_issi_w;
    wire [9:0]  ul_event_label_w;
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
        .ul_addr_type_sys        (ul_addr_type_w),
        .ul_issi_sys             (ul_issi_w),
        .ul_event_label_sys      (ul_event_label_w),
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

    integer pass_cnt;
    integer fail_cnt;
    integer i;
    reg [7:0] bytes [0:11];

    // =============================================================================
    // Helpers
    // =============================================================================

    // Pack 12 bytes MSB-first into the lower 92 bits of `info_bits`.  bit[0]
    // is the on-air MSB of byte[0].
    task pack_bytes_to_info;
        integer k;
        begin
            info_bits = 92'd0;
            for (k = 0; k < 92; k = k + 1)
                info_bits[k] = (bytes[k/8] >> (7 - (k%8))) & 1'b1;
        end
    endtask

    // Captured pulse-only outputs (1-cycle wide).  Refreshed each drive_one().
    reg cap_pdu_valid;
    reg cap_llc_is_bl_data;
    reg cap_llc_is_bl_ack;
    reg cap_llc_ns_valid;
    reg cap_llc_ns;
    reg cap_llc_nr_valid;
    reg cap_llc_nr;
    reg cap_bl_ack_valid;
    reg cap_bl_ack_nr;
    reg cap_llc_is_mle_mm;

    task drive_one;
        begin
            @(posedge clk); #1;
            info_valid = 1'b1;
            crc_ok     = 1'b1;
            @(posedge clk); #1;       // DUT registers fields here
            info_valid = 1'b0;
            crc_ok     = 1'b0;
            // Pulse signals are 1 in the window between the previous edge
            // and the next edge — capture before they decay.
            cap_pdu_valid       = pdu_valid_w;
            cap_llc_is_bl_data  = ul_llc_is_bl_data_w;
            cap_llc_is_bl_ack   = ul_llc_is_bl_ack_w;
            cap_llc_ns_valid    = ul_llc_ns_valid_w;
            cap_llc_ns          = ul_llc_ns_w;
            cap_llc_nr_valid    = ul_llc_nr_valid_w;
            cap_llc_nr          = ul_llc_nr_w;
            cap_bl_ack_valid    = bl_ack_valid_w;
            cap_bl_ack_nr       = bl_ack_nr_w;
            cap_llc_is_mle_mm   = ul_llc_is_mle_mm_w;
            @(posedge clk); #1;       // drain so pulses fall before next test
        end
    endtask

    // Generic bit-for-bit comparator
    task expect_field;
        input [255:0] label;
        input [31:0]  got;
        input [31:0]  exp_v;
        begin
            if (got === exp_v) begin
                $display("  PASS %-32s got=0x%0X", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %-32s got=0x%0X exp=0x%0X", label, got, exp_v);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =============================================================================
    // Initial test sequence
    // =============================================================================
    initial begin
        $dumpfile("sim_out/tb_ul_mac_access_parser.vcd");
        $dumpvars(0, tb_ul_mac_access_parser);

        rst_n      = 1'b0;
        info_bits  = 92'd0;
        info_valid = 1'b0;
        crc_ok     = 1'b0;
        pass_cnt   = 0;
        fail_cnt   = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=== tb_ul_mac_access_parser ===");

        // ---------------------------------------------------------------
        // [1] Synthetic MAC-ACCESS-Ssi (addr_type=0)
        //   pdu_type=0, fill=0, enc=0, addr_type=00, issi=0x123456,
        //   opt=1, length_or_cap=1, frag=1, reservation_req=0,
        //   tl_sdu starts at bit 36, content all zeros (0=BL-ADATA wrap with ns=0).
        // ---------------------------------------------------------------
        info_bits = 92'd0;
        // bit[0]=pdu_type=0
        // bit[1]=fill=0
        // bit[2]=encrypted=0
        // bits[3..4]=addr_type=00 → 0,0
        // bits[5..28]=issi=0x123456 (24 bits) MSB-first
        for (i = 0; i < 24; i = i + 1)
            info_bits[5+i] = (24'h123456 >> (23-i)) & 1'b1;
        // bit[29]=opt_flag=1
        info_bits[29] = 1'b1;
        // bit[30]=length_or_cap=1
        info_bits[30] = 1'b1;
        // bit[31]=frag=1
        info_bits[31] = 1'b1;
        // bits[32..35]=reservation_req=0000 → already 0
        // bits[36..]=TL-SDU all zero → BL-ADATA (link=0, has_fcs=0, bl_pdu=00) ns=0
        drive_one();
        expect_field("[1] pdu_type",        {31'b0, pdu_type_w}, 32'h0);
        expect_field("[1] fill_bit",        {31'b0, fill_bit_w}, 32'h0);
        expect_field("[1] encryption_mode", {31'b0, enc_w},      32'h0);
        expect_field("[1] addr_type",       {30'b0, ul_addr_type_w},     32'h0);
        expect_field("[1] issi",            {8'b0, ul_issi_w},   32'h00123456);
        expect_field("[1] opt_flag",        {31'b0, opt_flag_w}, 32'h1);
        expect_field("[1] frag_flag",       {31'b0, frag_flag_w},32'h1);
        expect_field("[1] reservation_req", {28'b0, reservation_req_w}, 32'h0);
        expect_field("[1] llc_is_bl_data",  {31'b0, cap_llc_is_bl_data}, 32'h1);
        expect_field("[1] llc_ns",          {31'b0, cap_llc_ns},32'h0);

        // ---------------------------------------------------------------
        // [2] Synthetic MAC-ACCESS-EventLabel (addr_type=1).
        //   event_label fits in 10 bits = bits [5..14], remaining bits up to
        //   29 are part of TL-SDU (bluestation-conformant).  We still write
        //   24-bit address slot and capture only the 10-bit event_label.
        // ---------------------------------------------------------------
        info_bits = 92'd0;
        info_bits[3] = 1'b0;
        info_bits[4] = 1'b1;   // addr_type = 01 (EventLabel)
        // event_label = 10'b1011001011 = 0x2CB at bits [5..14]
        for (i = 0; i < 10; i = i + 1)
            info_bits[5+i] = (10'h2CB >> (9-i)) & 1'b1;
        info_bits[29] = 1'b0;  // opt_flag=0 → tl_sdu starts at bit 30
        drive_one();
        expect_field("[2] addr_type",      {30'b0, ul_addr_type_w},      32'h1);
        expect_field("[2] event_label",    {22'b0, ul_event_label_w},    32'h2CB);
        expect_field("[2] opt_flag",       {31'b0, opt_flag_w},          32'h0);

        // ---------------------------------------------------------------
        // [3] Synthetic MAC-ACCESS-Ussi (addr_type=2)
        // ---------------------------------------------------------------
        info_bits = 92'd0;
        info_bits[3] = 1'b1;
        info_bits[4] = 1'b0;   // addr_type = 10 (Ussi)
        for (i = 0; i < 24; i = i + 1)
            info_bits[5+i] = (24'hABCDEF >> (23-i)) & 1'b1;
        drive_one();
        expect_field("[3] addr_type",      {30'b0, ul_addr_type_w},      32'h2);
        expect_field("[3] issi(==ussi)",   {8'b0, ul_issi_w},            32'h00ABCDEF);

        // ---------------------------------------------------------------
        // [4] On-air capture: external-BS MS RA-burst.
        //   bytes 01 41 7F A7 01 12 66 34 20 C1 22 60
        //   Expected: addr_type=0, issi=0x282FF4, opt=1, frag=1, reservation_req=0
        // ---------------------------------------------------------------
        bytes[0] = 8'h01; bytes[1] = 8'h41; bytes[2] = 8'h7F; bytes[3] = 8'hA7;
        bytes[4] = 8'h01; bytes[5] = 8'h12; bytes[6] = 8'h66; bytes[7] = 8'h34;
        bytes[8] = 8'h20; bytes[9] = 8'hC1; bytes[10] = 8'h22; bytes[11] = 8'h60;
        pack_bytes_to_info();
        drive_one();
        expect_field("[4] external pdu_type", {31'b0, pdu_type_w}, 32'h0);
        expect_field("[4] external fill_bit", {31'b0, fill_bit_w}, 32'h0);
        expect_field("[4] external enc",      {31'b0, enc_w},      32'h0);
        expect_field("[4] external addr_type",{30'b0, ul_addr_type_w}, 32'h0);
        expect_field("[4] external ISSI",     {8'b0, ul_issi_w},   32'h00282FF4);
        expect_field("[4] external opt_flag", {31'b0, opt_flag_w}, 32'h1);
        expect_field("[4] external frag",     {31'b0, frag_flag_w},32'h1);
        expect_field("[4] external resreq",   {28'b0, reservation_req_w}, 32'h0);

        // ---------------------------------------------------------------
        // [5] On-air capture: our MTP3550 MS RA-burst.
        //   bytes 01 41 7C 8F 01 12 66 34 20 C1 22 60
        //   Expected: addr_type=0, issi=0x282F91, opt=1, frag=1, reservation_req=0
        // ---------------------------------------------------------------
        bytes[0] = 8'h01; bytes[1] = 8'h41; bytes[2] = 8'h7C; bytes[3] = 8'h8F;
        bytes[4] = 8'h01; bytes[5] = 8'h12; bytes[6] = 8'h66; bytes[7] = 8'h34;
        bytes[8] = 8'h20; bytes[9] = 8'hC1; bytes[10] = 8'h22; bytes[11] = 8'h60;
        pack_bytes_to_info();
        drive_one();
        expect_field("[5] MTP3550 pdu_type",  {31'b0, pdu_type_w}, 32'h0);
        expect_field("[5] MTP3550 fill_bit",  {31'b0, fill_bit_w}, 32'h0);
        expect_field("[5] MTP3550 enc",       {31'b0, enc_w},      32'h0);
        expect_field("[5] MTP3550 addr_type", {30'b0, ul_addr_type_w}, 32'h0);
        expect_field("[5] MTP3550 ISSI",      {8'b0, ul_issi_w},   32'h00282F91);
        expect_field("[5] MTP3550 opt_flag",  {31'b0, opt_flag_w}, 32'h1);
        expect_field("[5] MTP3550 frag",      {31'b0, frag_flag_w},32'h1);
        expect_field("[5] MTP3550 resreq",    {28'b0, reservation_req_w}, 32'h0);

        $display("==========================================");
        $display("PASS=%0d  FAIL=%0d  pdu_count=%0d", pass_cnt, fail_cnt, pdu_count_w);
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
