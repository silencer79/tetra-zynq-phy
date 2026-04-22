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
wire [91:0] raw_w;
wire        pdu_valid_w;
wire [15:0] pdu_count_w;

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
    .raw_info_bits_sys    (raw_w),
    .pdu_valid_sys        (pdu_valid_w),
    .pdu_count_sys        (pdu_count_w)
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

    $display("=============================================");
    $display("PASS=%0d  FAIL=%0d  pdu_count=%0d", pass_cnt, fail_cnt, pdu_count_w);
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
