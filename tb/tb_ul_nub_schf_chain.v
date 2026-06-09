// =============================================================================
// tb_ul_nub_schf_chain.v — adapter + SCH/F decoder chain test
//
// Feeds NUB-convention 4-bit softs (sim_out/ul_sch_f_nubsoft.hex) through
// tetra_ul_nub_to_schf → tetra_ul_sch_f_decoder, checks 268 info + crc_ok
// against sim_out/ul_sch_f_exp.hex.  Covers the parallel→stream adapter AND
// the NUB→ETSI sign inversion — the highest-risk integration detail.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_nub_schf_chain;

localparam integer NUB_SOFT_W = 4;
localparam integer NBITS = 432;
localparam integer N_BURSTS = 8;
localparam integer INFO_BITS = 268;
localparam integer EXP_BYTES = 1 + ((INFO_BITS+7)/8); // 35
localparam integer CLK = 10;

reg clk; initial clk=0; always #(CLK/2) clk=~clk;
reg rst_n;
reg [31:0] scramb_init;

// adapter <-> decoder
wire signed [7:0] a_bit0, a_bit1;
wire a_valid, a_first, a_last, a_busy;

reg nub_valid;
reg [NBITS*NUB_SOFT_W-1:0] nub_softs;

wire [INFO_BITS-1:0] info_bits;
wire info_valid, crc_ok;
wire [15:0] dec_att, dec_ok;

tetra_ul_nub_to_schf #(.NUB_SOFT_W(NUB_SOFT_W), .OUT_W(8), .NBITS(NBITS)) u_adapt (
 .clk_sys(clk), .rst_n_sys(rst_n),
 .nub_coded_valid_sys(nub_valid),
 .nub_coded_softs_sys(nub_softs),
 .soft_bit0_sys(a_bit0), .soft_bit1_sys(a_bit1),
 .soft_valid_sys(a_valid), .soft_first_sys(a_first), .soft_last_sys(a_last),
 .busy_sys(a_busy)
);

tetra_ul_sch_f_decoder #(.SOFT_IN_WIDTH(8)) u_dec (
 .clk_sys(clk), .rst_n_sys(rst_n), .scramb_init_sys(scramb_init),
 .soft_bit0_sys(a_bit0), .soft_bit1_sys(a_bit1),
 .soft_valid_sys(a_valid), .soft_first_sys(a_first), .soft_last_sys(a_last),
 .info_bits_sys(info_bits), .info_valid_sys(info_valid), .crc_ok_sys(crc_ok),
 .decodes_attempted_sys(dec_att), .decodes_ok_sys(dec_ok)
);

reg [3:0] nub_mem [0:N_BURSTS*NBITS-1];
reg [7:0] exp_mem  [0:N_BURSTS*EXP_BYTES-1];

integer pass_cnt, fail_cnt, b, i, w;

function integer info_match;
 input [INFO_BITS-1:0] act;
 input integer bi;
 integer i, ba, be; reg [7:0] eb;
 begin
 info_match = 1;
 for (i=0;i<INFO_BITS;i=i+1) begin
 eb = exp_mem[bi*EXP_BYTES + 1 + (i/8)];
 be = (eb >> (7-(i%8))) & 1;
 ba = act[i];
 if (ba !== be) begin info_match=0; if(i<8) $display("    info[%0d] a=%0d e=%0d",i,ba,be); end
 end
 end
endfunction

initial begin
 $dumpfile("sim_out/tb_ul_nub_schf_chain.vcd"); $dumpvars(1,u_dec);
 scramb_init = 32'hE1670EC7;
 for (i=0;i<N_BURSTS*NBITS;i=i+1) nub_mem[i]=4'h0;
 for (i=0;i<N_BURSTS*EXP_BYTES;i=i+1) exp_mem[i]=8'h0;
 $readmemh("sim_out/ul_sch_f_nubsoft.hex", nub_mem);
 $readmemh("sim_out/ul_sch_f_exp.hex", exp_mem);

 rst_n=0; nub_valid=0; nub_softs=0; pass_cnt=0; fail_cnt=0;
 repeat(10) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);
 $display("=== tb_ul_nub_schf_chain: %0d bursts ===", N_BURSTS);

 for (b=0;b<N_BURSTS;b=b+1) begin
 $display("-- burst #%0d --", b);
 // pack the parallel bus: nub_softs[i*4 +: 4] = nub_mem[b*432 + i]
 for (i=0;i<NBITS;i=i+1)
 nub_softs[i*NUB_SOFT_W +: NUB_SOFT_W] = nub_mem[b*NBITS + i];
 @(posedge clk); #1; nub_valid=1;
 @(posedge clk); #1; nub_valid=0;

 w=0;
 while (!info_valid && w<60000) begin @(posedge clk); w=w+1; end
 if (!info_valid) begin $display("    FAIL timeout"); fail_cnt=fail_cnt+1; end
 else if (crc_ok && info_match(info_bits,b)) begin
 $display("    PASS crc_ok=1 info[0:16]=%04h", info_bits[15:0]); pass_cnt=pass_cnt+1;
 end else begin
 $display("    FAIL crc_ok=%0d info[0:16]=%04h", crc_ok, info_bits[15:0]); fail_cnt=fail_cnt+1;
 end
 repeat(30) @(posedge clk);
 end

 $display("=============================================");
 $display("pass=%0d fail=%0d / %0d", pass_cnt, fail_cnt, N_BURSTS);
 $display(pass_cnt==N_BURSTS ? "RESULT: PASS" : "RESULT: FAIL");
 $display("=============================================");
 $finish;
end

initial begin #800_000_000; $display("WATCHDOG"); $finish; end

endmodule

`default_nettype wire
