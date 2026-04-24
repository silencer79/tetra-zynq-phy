// =============================================================================
// tb_ul_mac_access_parser.v — Verify MAC-ACCESS PDU field extraction
//
// Reads sim_out/ul_wav_exp.hex (13 bytes/record: crc_flag + 12 info bytes),
// drives one info_valid pulse per CRC-OK record, and cross-checks the parsed
// fields against Python scripts/decode_ul.parse_mac_access() output written
// to sim_out/ul_mac_access_exp.hex (see scripts/gen_ul_mac_exp.py).
//
// Format of ul_mac_access_exp.hex (one 32-bit hex per record, CRC-OK only):
//   [31:30]   pdu_type
//   [29]      fill_bit
//   [28:27]   encryption_mode
//   [26]      access_ack
//   [25:23]   address_type
//   [22:13]   short_ssi (10 bits)
//   [12:0]    reserved
//
// PASS iff all CRC-OK records match the expected parse.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_mac_access_parser;

localparam integer N_RECORDS = 8;
localparam integer CLK_PERIOD = 10;

reg clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;
reg rst_n;

reg [91:0] info_bits;
reg        info_valid;
reg        crc_ok;

wire [1:0]  pdu_type_w;
wire        fill_bit_w;
wire [1:0]  encryption_mode_w;
wire        access_ack_w;
wire [2:0]  address_type_w;
wire [9:0]  short_ssi_w;
wire [3:0]  mm_pdu_type_w;
wire [2:0]  loc_upd_type_w;
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
    .encryption_mode_sys  (encryption_mode_w),
    .access_ack_sys       (access_ack_w),
    .address_type_sys     (address_type_w),
    .short_ssi_sys        (short_ssi_w),
    .mm_pdu_type_sys      (mm_pdu_type_w),
    .loc_upd_type_sys     (loc_upd_type_w),
    .raw_info_bits_sys    (raw_w),
    .pdu_valid_sys        (pdu_valid_w),
    .pdu_count_sys        (pdu_count_w),
    .bl_ack_valid_sys     (bl_ack_valid_w),
    .bl_ack_nr_sys        (bl_ack_nr_w),
    .bl_ack_count_sys     (bl_ack_count_w)
);

reg [7:0]  exp_bytes [0:N_RECORDS*13 - 1];
reg [31:0] exp_fields[0:N_RECORDS - 1];

integer pass_cnt, fail_cnt, r_idx, i;
reg [91:0] info_tmp;
reg        crc_flag_exp;
reg [31:0] expv;
reg [1:0]  exp_pdu;
reg        exp_fill;
reg [1:0]  exp_enc;
reg        exp_ack;
reg [2:0]  exp_at;
reg [9:0]  exp_ssi;

initial begin
    $dumpfile("sim_out/tb_ul_mac_access_parser.vcd");
    $dumpvars(0, tb_ul_mac_access_parser);

    $readmemh("sim_out/ul_wav_exp.hex",         exp_bytes);
    $readmemh("sim_out/ul_mac_access_exp.hex",  exp_fields);

    rst_n      = 1'b0;
    info_bits  = 92'd0;
    info_valid = 1'b0;
    crc_ok     = 1'b0;
    pass_cnt   = 0;
    fail_cnt   = 0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("=== tb_ul_mac_access_parser: %0d records ===", N_RECORDS);

    for (r_idx = 0; r_idx < N_RECORDS; r_idx = r_idx + 1) begin
        crc_flag_exp = exp_bytes[r_idx*13 + 0][0];
        if (!crc_flag_exp) begin
            $display("  #%0d  SKIP (py_crc=0)", r_idx);
        end else begin
            // Pack 12 bytes MSB-first into info_tmp[91:0]
            info_tmp = 92'd0;
            for (i = 0; i < 92; i = i + 1) begin
                info_tmp[i] = (exp_bytes[r_idx*13 + 1 + (i/8)] >> (7 - (i%8))) & 1;
            end
            @(posedge clk); #1;
            info_bits  = info_tmp;
            info_valid = 1'b1;
            crc_ok     = 1'b1;
            @(posedge clk); #1;
            info_valid = 1'b0;
            crc_ok     = 1'b0;
            @(posedge clk); #1;  // one more cycle for latch

            expv     = exp_fields[r_idx];
            exp_pdu  = expv[31:30];
            exp_fill = expv[29];
            exp_enc  = expv[28:27];
            exp_ack  = expv[26];
            exp_at   = expv[25:23];
            exp_ssi  = expv[22:13];

            if (pdu_type_w == exp_pdu && fill_bit_w == exp_fill &&
                encryption_mode_w == exp_enc && access_ack_w == exp_ack &&
                address_type_w == exp_at && short_ssi_w == exp_ssi)
            begin
                $display("  #%0d  PASS  pdu=%0d fill=%0d enc=%0d ack=%0d at=%0d ssi=%0d",
                         r_idx, pdu_type_w, fill_bit_w, encryption_mode_w,
                         access_ack_w, address_type_w, short_ssi_w);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  #%0d  FAIL  got pdu=%0d fill=%0d enc=%0d ack=%0d at=%0d ssi=%0d  exp pdu=%0d fill=%0d enc=%0d ack=%0d at=%0d ssi=%0d",
                         r_idx,
                         pdu_type_w, fill_bit_w, encryption_mode_w, access_ack_w,
                         address_type_w, short_ssi_w,
                         exp_pdu, exp_fill, exp_enc, exp_ack, exp_at, exp_ssi);
                fail_cnt = fail_cnt + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // BL-ACK Inline Tests (M1 of 2026-04-24)
    // Synthetic frames with LLC-header BL-ACK pattern at bits [19:24)
    // to verify bl_ack_valid_sys / bl_ack_nr_sys detection.
    //
    // Frame layout (MSB bit 0):
    //   [0:2)  pdu_type     = 00  (MAC-ACCESS)
    //   [2:3)  fill_bit     = 0
    //   [3:5)  encryption   = 00
    //   [5:6)  access_ack   = 0
    //   [6:9)  addr_type    = 010 (short_ssi 10-bit present)
    //   [9:19) short_ssi    = 0x20B (= 523 decimal, MTP3550 empirical)
    //   [19]   llc_link_type = 0
    //   [20]   has_fcs      = 0
    //   [21:22] bl_pdu_type = 11 (BL-ACK)
    //   [23]   N(R)         = 0 or 1
    //   [24:92] fill=0
    // ---------------------------------------------------------------

    $display("--- BL-ACK inline tests ---");

    // Build mask: bits [0:19) = 00_0_00_0_010_0100001011 (for addr_type=2, ssi=523)
    // Bit layout concrete values:
    //   bit 0:0, 1:0, 2:0, 3:0, 4:0, 5:0, 6:0, 7:1, 8:0    ( addr_type=010 )
    //   bit 9..18 = 10-bit ssi 523 = 0b1000001011
    //   → bits 9..18 = 1,0,0,0,0,0,1,0,1,1
    // Then LLC header at 19..23:
    //   19:0, 20:0, 21:1, 22:1, 23:nr

    // --- Test BL-ACK nr=0 ---
    info_tmp = 92'd0;
    // addr_type bits 6,7,8 = 0,1,0
    info_tmp[7] = 1'b1;
    // short_ssi = 523 = 0b10_0000_1011
    info_tmp[9]  = 1'b1; // MSB
    info_tmp[15] = 1'b1;
    info_tmp[17] = 1'b1;
    info_tmp[18] = 1'b1;
    // LLC BL-ACK: bits 21,22 = 1,1 ; nr=0 at bit 23
    info_tmp[21] = 1'b1;
    info_tmp[22] = 1'b1;
    // bit 23 nr=0 (already zero)

    @(posedge clk); #1;
    info_bits  = info_tmp;
    info_valid = 1'b1;
    crc_ok     = 1'b1;
    @(posedge clk); #1;
    // bl_ack_valid_w is a 1-cycle pulse — sampled HERE while info_valid still 1,
    // deassert info_valid for the *next* edge but latch the pulse readout first.
    info_valid = 1'b0;
    crc_ok     = 1'b0;

    if (bl_ack_valid_w && bl_ack_nr_w == 1'b0 && short_ssi_w == 10'd523) begin
        $display("  BL-ACK nr=0  PASS  bl_ack_nr=%0d short_ssi=%0d", bl_ack_nr_w, short_ssi_w);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  BL-ACK nr=0  FAIL  valid=%b nr=%0d ssi=%0d",
                 bl_ack_valid_w, bl_ack_nr_w, short_ssi_w);
        fail_cnt = fail_cnt + 1;
    end
    @(posedge clk); #1;   // pulse cleared here

    // --- Test BL-ACK nr=1 ---
    info_tmp[23] = 1'b1;  // nr=1

    @(posedge clk); #1;
    info_bits  = info_tmp;
    info_valid = 1'b1;
    crc_ok     = 1'b1;
    @(posedge clk); #1;
    info_valid = 1'b0;
    crc_ok     = 1'b0;

    if (bl_ack_valid_w && bl_ack_nr_w == 1'b1) begin
        $display("  BL-ACK nr=1  PASS  bl_ack_nr=%0d", bl_ack_nr_w);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  BL-ACK nr=1  FAIL  valid=%b nr=%0d",
                 bl_ack_valid_w, bl_ack_nr_w);
        fail_cnt = fail_cnt + 1;
    end
    @(posedge clk); #1;

    // --- Test NOT-BL-ACK: bl_pdu_type = 01 (BL-DATA) ---
    // Expect bl_ack_valid=0 (no false positive on BL-DATA)
    info_tmp = 92'd0;
    info_tmp[7] = 1'b1;  // addr_type=2
    info_tmp[21] = 1'b0; // bl_pdu_type = 01 (BL-DATA)
    info_tmp[22] = 1'b1;

    @(posedge clk); #1;
    info_bits  = info_tmp;
    info_valid = 1'b1;
    crc_ok     = 1'b1;
    @(posedge clk); #1;
    info_valid = 1'b0;
    crc_ok     = 1'b0;
    @(posedge clk); #1;

    if (!bl_ack_valid_w) begin
        $display("  BL-DATA reject  PASS  bl_ack_valid=%b (expected 0)", bl_ack_valid_w);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  BL-DATA reject  FAIL  bl_ack_valid=%b (got false positive)",
                 bl_ack_valid_w);
        fail_cnt = fail_cnt + 1;
    end

    // --- Test NOT-BL-ACK: llc_link_type=1 (advanced link) ---
    // Expect bl_ack_valid=0
    info_tmp = 92'd0;
    info_tmp[7] = 1'b1;
    info_tmp[19] = 1'b1; // llc_link_type=1 (AL, not BL)
    info_tmp[21] = 1'b1; // bl_pdu_type=11 would match BL-ACK but link_type disqualifies
    info_tmp[22] = 1'b1;

    @(posedge clk); #1;
    info_bits  = info_tmp;
    info_valid = 1'b1;
    crc_ok     = 1'b1;
    @(posedge clk); #1;
    info_valid = 1'b0;
    crc_ok     = 1'b0;
    @(posedge clk); #1;

    if (!bl_ack_valid_w) begin
        $display("  AL reject  PASS  bl_ack_valid=%b (expected 0 on llc_link_type=1)",
                 bl_ack_valid_w);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  AL reject  FAIL  bl_ack_valid=%b (got false positive)",
                 bl_ack_valid_w);
        fail_cnt = fail_cnt + 1;
    end

    $display("=============================================");
    $display("PASS=%0d  FAIL=%0d  pdu_count=%0d bl_ack_count=%0d",
             pass_cnt, fail_cnt, pdu_count_w, bl_ack_count_w);
    if (fail_cnt == 0 && pass_cnt > 0)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");
    $display("=============================================");
    $finish;
end

initial begin
    #1_000_000;
    $display("WATCHDOG");
    $finish;
end

endmodule

`default_nettype wire
