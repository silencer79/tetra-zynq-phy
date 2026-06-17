// Focused reassembly test: real-world timing — frame_tick active, T0=4,
// a complete chain START → FRAG(+1F) → FRAG(+1F) → END(+2F), preceded by
// retransmit STARTs. Checks reass_cnt increments (S_EMIT reached).
`timescale 1ns/1ps
`default_nettype none
module tb_schf_reass_realseq;
localparam integer INFO = 268;
localparam integer NWORDS = 256;
localparam integer FRAME = 1000;   // cycles per "frame"
reg clk; initial clk=0; always #5 clk=~clk;
reg rst_n;
reg frame_tick;
reg frag1_pulse; reg [23:0] frag1_ssi; reg [61:0] frag1_bits; reg frag1_opt;
reg schf_valid, schf_crc_ok; reg [INFO-1:0] schf_info;
reg [8:0] index; reg ack_pulse;
wire [31:0] rdata; wire valid; wire reass_pulse; wire [15:0] reass_cnt, drop_cnt;

tetra_ul_schf_reassembly dut(
 .clk_sys(clk), .rst_n_sys(rst_n),
 .t0_frames_sys(4'd4), .frame_tick_sys(frame_tick),
 .frag1_pulse_sys(frag1_pulse), .frag1_ssi_sys(frag1_ssi),
 .frag1_bits_sys(frag1_bits), .frag1_opt_flag_sys(frag1_opt),
 .schf_valid_sys(schf_valid), .schf_crc_ok_sys(schf_crc_ok), .schf_info_sys(schf_info),
 .reass_valid_pulse_sys(reass_pulse), .reass_cnt_sys(reass_cnt), .drop_cnt_sys(drop_cnt),
 .index_sys(index), .rdata_sys(rdata), .valid_sys(valid), .ack_pulse_sys(ack_pulse));

// free-running frame_tick: 1-cycle pulse every FRAME cycles
integer fc; initial fc=0;
always @(posedge clk) begin
  if (!rst_n) begin frame_tick<=0; fc<=0; end
  else begin
    if (fc==FRAME-1) begin frame_tick<=1; fc<=0; end
    else begin frame_tick<=0; fc<=fc+1; end
  end
end

task do_start; begin
  @(posedge clk); #1; frag1_ssi=24'h282F91; frag1_bits=62'h0; frag1_opt=1'b1; frag1_pulse=1;
  @(posedge clk); #1; frag1_pulse=0;
end endtask

// mac_pdu_type=01 (info[0]=0,info[1]=1); is_end sets info[2]
task do_frag; input is_end; integer k; begin
  for (k=0;k<INFO;k=k+1) schf_info[k]=1'b0;
  schf_info[0]=1'b0; schf_info[1]=1'b1; schf_info[2]=is_end;  // type=01, end-bit
  // some payload so body is non-trivial
  schf_info[20]=1'b1; schf_info[40]=1'b1;
  schf_crc_ok=1'b1;
  @(posedge clk); #1; schf_valid=1;
  @(posedge clk); #1; schf_valid=0;
end endtask

task wait_frames; input integer n; integer c; begin
  for (c=0;c<n*FRAME;c=c+1) @(posedge clk);
end endtask

initial begin
  rst_n=0; frame_tick=0; frag1_pulse=0; frag1_ssi=0; frag1_bits=0; frag1_opt=0;
  schf_valid=0; schf_crc_ok=0; schf_info=0; index=0; ack_pulse=0;
  repeat(20) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);

  $display("=== realseq: retransmit STARTs, then complete chain (END +2F) ===");
  // retransmit STARTs far apart (like the MS waiting for grant)
  do_start; wait_frames(6);
  do_start; wait_frames(6);
  // complete chain: START, +1F FRAG, +1F FRAG, +2F END
  do_start;            wait_frames(1);
  do_frag(1'b0);       wait_frames(1);
  do_frag(1'b0);       wait_frames(2);
  do_frag(1'b1);       // END, 2 frames after last FRAG
  wait_frames(2);

  $display("RESULT: reass_cnt=%0d drop_cnt=%0d", reass_cnt, drop_cnt);
  if (reass_cnt>0) $display(">>> PASS: FSM emits on real-timed chain");
  else             $display(">>> FAIL: FSM never emits (reass_cnt=0) — reproduces board bug");
  $finish;
end
endmodule
`default_nettype wire
