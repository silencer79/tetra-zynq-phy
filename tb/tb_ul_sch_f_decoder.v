// =============================================================================
// tb_ul_sch_f_decoder.v — Unit test for tetra_ul_sch_f_decoder
//
// Loads clean SCH/F test vectors from scripts/gen_sch_f_dec_tv.py:
//   sim_out/ul_sch_f_soft.hex — 432 signed 8-bit soft values per burst
//   sim_out/ul_sch_f_exp.hex  — 35 bytes/burst: [crc_ok:1][info 34 bytes]
//
// Per burst: feed 216 soft-dibit pairs (soft_bit1=type5[2k], soft_bit0=2k+1),
// wait for info_valid_sys, compare crc_ok_sys + 268 info bits.
//
// Scrambler init via +SCRAMB_INIT=<hex> (default 0xE1670EC7 = MCC901/MNC9998/CC49).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_sch_f_decoder;

localparam integer SOFT_W = 8;
localparam integer N_BURSTS = 8;
localparam integer BITS_BURST = 432;
localparam integer INFO_BITS = 268;
localparam integer EXP_BYTES = 1 + ((INFO_BITS + 7) / 8); // 1 + 34 = 35
localparam integer CLK_PERIOD = 10;

reg clk;
reg rst_n;

reg signed [SOFT_W-1:0] soft_bit0;
reg signed [SOFT_W-1:0] soft_bit1;
reg soft_valid;
reg soft_first;
reg soft_last;
reg soft_half;

reg [31:0] scramb_init;

wire [INFO_BITS-1:0] info_bits;
wire info_valid;
wire crc_ok;
wire [15:0] decodes_attempted;
wire [15:0] decodes_ok;

tetra_ul_sch_f_decoder #(
 .SOFT_IN_WIDTH(SOFT_W)
) dut (
 .clk_sys (clk),
 .rst_n_sys (rst_n),
 .scramb_init_sys (scramb_init),
 .soft_bit0_sys (soft_bit0),
 .soft_bit1_sys (soft_bit1),
 .soft_valid_sys (soft_valid),
 .soft_first_sys (soft_first),
 .soft_last_sys (soft_last),
 .info_bits_sys (info_bits),
 .info_valid_sys (info_valid),
 .crc_ok_sys (crc_ok),
 .decodes_attempted_sys (decodes_attempted),
 .decodes_ok_sys (decodes_ok)
);

initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

reg [7:0] soft_mem [0:N_BURSTS*BITS_BURST-1];
reg [7:0] exp_mem  [0:N_BURSTS*EXP_BYTES-1];

integer pass_cnt;
integer fail_cnt;

function integer info_match;
 input [INFO_BITS-1:0] info_actual;
 input integer burst_i;
 integer i, bit_actual, bit_expected;
 reg [7:0] eb;
 begin
 info_match = 1;
 for (i = 0; i < INFO_BITS; i = i + 1) begin
 eb = exp_mem[burst_i*EXP_BYTES + 1 + (i/8)];
 bit_expected = (eb >> (7 - (i%8))) & 1;
 bit_actual = info_actual[i];
 if (bit_actual !== bit_expected) begin
 info_match = 0;
 if (i < 8)
 $display("    info[%0d] actual=%0d expected=%0d",
 i, bit_actual, bit_expected);
 end
 end
 end
endfunction

integer b_idx;
integer k, soft_idx;
integer wait_cycles;
reg [7:0] s_byte;

initial begin
 $dumpfile("sim_out/tb_ul_sch_f_decoder.vcd");
 $dumpvars(1, dut);

 scramb_init = 32'hE1670EC7;
 if ($value$plusargs("SCRAMB_INIT=%h", scramb_init))
 $display("(scramb_init override: 0x%08h)", scramb_init);

 for (k = 0; k < N_BURSTS*BITS_BURST; k = k + 1) soft_mem[k] = 8'h00;
 for (k = 0; k < N_BURSTS*EXP_BYTES; k = k + 1) exp_mem[k] = 8'h00;

 $readmemh("sim_out/ul_sch_f_soft.hex", soft_mem);
 $readmemh("sim_out/ul_sch_f_exp.hex", exp_mem);

 rst_n = 1'b0;
 soft_bit0 = 0; soft_bit1 = 0;
 soft_valid = 1'b0; soft_first = 1'b0; soft_last = 1'b0; soft_half = 1'b0;
 pass_cnt = 0; fail_cnt = 0;

 repeat (10) @(posedge clk);
 rst_n = 1'b1;
 repeat (5) @(posedge clk);

 $display("=== tb_ul_sch_f_decoder: %0d bursts, scramb_init=0x%08h ===",
 N_BURSTS, scramb_init);

 for (b_idx = 0; b_idx < N_BURSTS; b_idx = b_idx + 1) begin
 $display("-- burst #%0d --", b_idx);

 for (k = 0; k < BITS_BURST/2; k = k + 1) begin
 soft_idx = b_idx*BITS_BURST + 2*k;
 @(posedge clk); #1;
 s_byte = soft_mem[soft_idx];       soft_bit1 = $signed(s_byte);
 s_byte = soft_mem[soft_idx + 1];   soft_bit0 = $signed(s_byte);
 soft_valid = 1'b1;
 soft_first = (k == 0);
 soft_last  = (k == (BITS_BURST/2 - 1));
 soft_half  = (k >= BITS_BURST/4);
 @(posedge clk); #1;
 soft_valid = 1'b0; soft_first = 1'b0; soft_last = 1'b0;
 repeat (2) @(posedge clk);
 end

 wait_cycles = 0;
 while (!info_valid && wait_cycles < 40000) begin
 @(posedge clk);
 wait_cycles = wait_cycles + 1;
 end

 if (!info_valid) begin
 $display("    FAIL: info_valid never fired (timeout)");
 fail_cnt = fail_cnt + 1;
 end else begin
 if (crc_ok && info_match(info_bits, b_idx)) begin
 $display("    PASS crc_ok=1 info[0:16]=%04h", info_bits[15:0]);
 pass_cnt = pass_cnt + 1;
 end else begin
 $display("    FAIL crc_ok=%0d info[0:16]=%04h exp=%02h %02h",
 crc_ok, info_bits[15:0],
 exp_mem[b_idx*EXP_BYTES + 1], exp_mem[b_idx*EXP_BYTES + 2]);
 fail_cnt = fail_cnt + 1;
 end
 end

 repeat (20) @(posedge clk);
 end

 $display("=============================================");
 $display("decodes_attempted=%0d decodes_ok=%0d", decodes_attempted, decodes_ok);
 $display("TB counters: pass=%0d fail=%0d / %0d bursts", pass_cnt, fail_cnt, N_BURSTS);
 if (pass_cnt == N_BURSTS)
 $display("RESULT: PASS");
 else
 $display("RESULT: FAIL");
 $display("=============================================");
 $finish;
end

initial begin
 #500_000_000;
 $display("WATCHDOG timeout");
 $finish;
end

endmodule

`default_nettype wire
