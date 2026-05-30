// tb_rx_iq_capture.v — verify the raw RX IQ capture buffer
// Writes known IQ, freezes, reads back via AXI port, checks bit-identity +
// that writes stop after freeze + that wr_ptr reflects the stop position.
`timescale 1ns/1ps
`default_nettype none

module tb_rx_iq_capture;

localparam integer DEPTH  = 16;
localparam integer ADDR_W = 4;

reg clk_sys = 0, clk_axi = 0, rst_n = 0;
always #5  clk_sys = ~clk_sys;   // 100 MHz
always #7  clk_axi = ~clk_axi;   // ~71 MHz (different clock)

reg signed [15:0] i_in, q_in;
reg               valid_in;
reg               freeze;
reg  [ADDR_W-1:0] rd_addr;
wire [31:0]       rd_data;
wire [ADDR_W-1:0] wr_ptr;

tetra_rx_iq_capture #(.DEPTH(DEPTH), .ADDR_W(ADDR_W)) dut (
 .clk_sys(clk_sys), .rst_n_sys(rst_n),
 .i_in_sys(i_in), .q_in_sys(q_in), .valid_in_sys(valid_in),
 .clk_axi(clk_axi), .rst_n_axi(rst_n),
 .freeze_axi(freeze), .rd_addr_axi(rd_addr),
 .rd_data_axi(rd_data), .wr_ptr_axi(wr_ptr)
);

integer k, errors = 0;

// write one IQ sample (clk_sys): I=k, Q=1000+k
task wr_sample; input integer kk; begin
 @(posedge clk_sys); #1; i_in = kk[15:0]; q_in = (1000+kk); valid_in = 1'b1;
 @(posedge clk_sys); #1; valid_in = 1'b0;
end endtask

// read one address (clk_axi), return rd_data after registered latency
task rd_at; input [ADDR_W-1:0] a; begin
 @(posedge clk_axi); #1; rd_addr = a;
 @(posedge clk_axi); @(posedge clk_axi); #1;  // 2 edges: settle + registered out
end endtask

integer a, exp_k;
initial begin
 $dumpfile("sim_out/tb_rx_iq_capture.vcd"); $dumpvars(0, tb_rx_iq_capture);
 i_in=0; q_in=0; valid_in=0; freeze=0; rd_addr=0;
 repeat(4) @(posedge clk_sys); rst_n=1; repeat(4) @(posedge clk_sys);

 // write k=0..19 (wraps the 16-deep buffer once + 4)
 for (k=0; k<20; k=k+1) wr_sample(k);

 // freeze + let CDC settle
 @(posedge clk_axi); #1; freeze=1;
 repeat(6) @(posedge clk_sys); repeat(6) @(posedge clk_axi);

 // writes must stop now: drive 5 more valids, must NOT change buffer
 for (k=20; k<25; k=k+1) wr_sample(k);
 repeat(4) @(posedge clk_axi);

 // wr_ptr should be 20 mod 16 = 4
 if (wr_ptr !== 4) begin $display("FAIL wr_ptr=%0d exp 4", wr_ptr); errors=errors+1; end
 else $display("PASS wr_ptr=4 (capture stopped at right spot)");

 // check each address: addr a holds last k with (k mod 16)==a, k in 0..19
 for (a=0; a<DEPTH; a=a+1) begin
  exp_k = (a < 4) ? a+16 : a;          // 0..3 overwritten by 16..19
  rd_at(a[ADDR_W-1:0]);
  if (rd_data[31:16] !== exp_k[15:0] || rd_data[15:0] !== (1000+exp_k)) begin
   $display("FAIL addr %0d: got I=%0d Q=%0d exp I=%0d Q=%0d",
            a, $signed(rd_data[31:16]), rd_data[15:0], exp_k, 1000+exp_k);
   errors=errors+1;
  end
 end
 if (errors==0) $display("PASS readback bit-identical + no-write-after-freeze");

 $display("=============================================");
 $display(errors==0 ? "RESULT: PASS" : "RESULT: FAIL (%0d)", errors);
 $finish;
end

initial begin #100000; $display("RESULT: FAIL (timeout)"); $finish; end

endmodule
`default_nettype wire
