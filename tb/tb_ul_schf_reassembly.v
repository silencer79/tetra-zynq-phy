// =============================================================================
// tb_ul_schf_reassembly.v — Unit test for tetra_ul_schf_reassembly
//
// Vectors from scripts/gen_schf_reass_tv.py (flat 1-bit-per-line):
//   schf_reass_frag1.b — 62 bits frag1[0..61]
//   schf_reass_frags.b — N*268 bits (block f, bit k = info_f[k])
//   schf_reass_exp.b   — EXP_LEN body bits (body[0..])
//   schf_reass_meta.txt — "N_FRAGS EXP_LEN"
//
// Feeds frag1 then N SCH/F fragments (info held stable during each write),
// waits the completion pulse, then reads the body via the AXI word mailbox
// (index mux) and compares bit-for-bit (body bit i = word[i/32][31-(i%32)]).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_schf_reassembly;

localparam integer INFO   = 268;
localparam integer NWORDS = 256;
localparam integer CLK    = 10;

reg clk; initial clk = 0; always #(CLK/2) clk = ~clk;
reg rst_n;

reg frag1_pulse;
reg [23:0] frag1_ssi;
reg [61:0] frag1_bits;
reg frag1_opt;

reg schf_valid;
reg schf_crc_ok;
reg [INFO-1:0] schf_info;

wire reass_pulse;
wire [15:0] reass_cnt, drop_cnt;

reg [8:0] index;
wire [31:0] rdata;
wire mb_valid;
reg ack_pulse;

tetra_ul_schf_reassembly dut (
 .clk_sys(clk), .rst_n_sys(rst_n),
 .t0_frames_sys(4'd0), .frame_tick_sys(1'b0),
 .frag1_pulse_sys(frag1_pulse), .frag1_ssi_sys(frag1_ssi),
 .frag1_bits_sys(frag1_bits), .frag1_opt_flag_sys(frag1_opt),
 .schf_valid_sys(schf_valid), .schf_crc_ok_sys(schf_crc_ok),
 .schf_info_sys(schf_info),
 .reass_valid_pulse_sys(reass_pulse),
 .reass_cnt_sys(reass_cnt), .drop_cnt_sys(drop_cnt),
 .index_sys(index), .rdata_sys(rdata), .valid_sys(mb_valid),
 .ack_pulse_sys(ack_pulse)
);

reg frag1_mem [0:61];
reg frags_mem [0:8192-1];
reg exp_mem   [0:8192-1];

integer N_FRAGS, EXP_LEN;
integer fd, rc, f, k, i, errors;
reg got_reass;
reg [31:0] w;
integer got_len, got_opt, got_ssi;

always @(posedge clk or negedge rst_n)
 if (!rst_n) got_reass <= 1'b0; else if (reass_pulse) got_reass <= 1'b1;

initial begin
 $dumpfile("sim_out/tb_ul_schf_reassembly.vcd"); $dumpvars(1, dut);

 for (k=0;k<62;k=k+1) frag1_mem[k]=1'b0;
 for (k=0;k<8192;k=k+1) begin frags_mem[k]=1'b0; exp_mem[k]=1'b0; end
 $readmemb("sim_out/schf_reass_frag1.b", frag1_mem);
 $readmemb("sim_out/schf_reass_frags.b", frags_mem);
 $readmemb("sim_out/schf_reass_exp.b",   exp_mem);
 fd = $fopen("sim_out/schf_reass_meta.txt","r"); rc = $fscanf(fd,"%d %d",N_FRAGS,EXP_LEN); $fclose(fd);
 $display("=== tb_ul_schf_reassembly: N_FRAGS=%0d EXP_LEN=%0d ===", N_FRAGS, EXP_LEN);

 rst_n=0; frag1_pulse=0; frag1_ssi=0; frag1_bits=0; frag1_opt=0;
 schf_valid=0; schf_crc_ok=0; schf_info=0; index=0; ack_pulse=0; errors=0;
 repeat (10) @(posedge clk); rst_n=1; repeat (5) @(posedge clk);

 for (k=0;k<62;k=k+1) frag1_bits[61-k] = frag1_mem[k];  // body[0]=frag1_bits[61]=frag1[0]
 frag1_ssi=24'h282F91; frag1_opt=1'b1;
 @(posedge clk); #1; frag1_pulse=1;
 @(posedge clk); #1; frag1_pulse=0;
 repeat (90) @(posedge clk);

 for (f=0; f<N_FRAGS; f=f+1) begin
 for (k=0;k<INFO;k=k+1) schf_info[k] = frags_mem[f*INFO + k];
 schf_crc_ok=1'b1;
 @(posedge clk); #1; schf_valid=1;
 @(posedge clk); #1; schf_valid=0;
 repeat (320) @(posedge clk);
 end

 i=0; while (!got_reass && i<3000) begin @(posedge clk); i=i+1; end
 if (!got_reass) begin $display("FAIL: completion pulse never fired"); $finish; end

 // read status via mailbox
 index = NWORDS[8:0] + 9'd2; @(posedge clk); #1; got_len = rdata[15:0]; got_opt = rdata[16];
 index = NWORDS[8:0] + 9'd1; @(posedge clk); #1; got_ssi = rdata[23:0];
 index = NWORDS[8:0];        @(posedge clk); #1;
 $display("mailbox: valid=%0b ssi=0x%06h len=%0d opt=%0d cnt=%0d", rdata[0], got_ssi, got_len, got_opt, reass_cnt);

 if (got_len !== EXP_LEN) begin $display("FAIL: len=%0d != %0d", got_len, EXP_LEN); errors=errors+1; end
 if (got_ssi !== 24'h282F91) begin $display("FAIL: ssi=0x%06h", got_ssi); errors=errors+1; end

 // read body words, compare bit-for-bit (MSB-first within word)
 for (i=0;i<EXP_LEN;i=i+1) begin
 index = (i/32);
 @(posedge clk); #1;
 w = rdata;
 if (w[31 - (i%32)] !== exp_mem[i]) begin
 if (errors<12) $display("    body[%0d] act=%0b exp=%0b", i, w[31-(i%32)], exp_mem[i]);
 errors = errors + 1;
 end
 end

 $display("=============================================");
 if (errors==0 && got_len===EXP_LEN)
 $display("RESULT: PASS  (body %0d bits bit-identical via word mailbox)", EXP_LEN);
 else
 $display("RESULT: FAIL  (%0d mismatches)", errors);
 $display("=============================================");
 $finish;
end

initial begin #500_000_000; $display("WATCHDOG"); $finish; end

endmodule

`default_nettype wire
