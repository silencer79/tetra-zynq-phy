`timescale 1ns / 1ps
`default_nettype none

// Unit test: tetra_tx_frontend
// Drives known input samples, verifies non-zero CIC output.
// PASS criteria: at least 10 non-zero tx_i_lvds values within 1024 output pulses.

module tb_tetra_tx_frontend_unit;

localparam CLK_HALF = 5;
localparam IQ_WIDTH = 16;
localparam CIC_SHIFT = 24;
localparam CIC_ACC = 48;

reg clk_sys;
reg clk_lvds;
reg rst_n_sys;
reg rst_n_lvds;

reg signed [15:0] i_in;
reg signed [15:0] q_in;
reg sample_valid_in;

wire signed [15:0] tx_i_lvds;
wire signed [15:0] tx_q_lvds;
wire tx_valid_lvds;

integer nonzero_count;
integer total_valid;
integer max_abs_i;
integer abs_i;

initial clk_sys = 0;
initial clk_lvds = 0;
always #CLK_HALF clk_sys = ~clk_sys;
always #CLK_HALF clk_lvds = ~clk_lvds;

tetra_tx_frontend #(
.IQ_WIDTH (IQ_WIDTH),
.CIC_SHIFT (CIC_SHIFT),
.CIC_ACC (CIC_ACC)
) dut (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.i_in (i_in),
.q_in (q_in),
.sample_valid_in (sample_valid_in),
.clk_lvds (clk_lvds),
.rst_n_lvds (rst_n_lvds),
.tx_i_lvds (tx_i_lvds),
.tx_q_lvds (tx_q_lvds),
.tx_valid_lvds (tx_valid_lvds)
);

// Count non-zero outputs and track peak
always @(posedge clk_lvds) begin
 if (tx_valid_lvds) begin
 total_valid <= total_valid + 1;
 abs_i = (tx_i_lvds[15]) ? (~tx_i_lvds + 1): tx_i_lvds;
 if (abs_i > 0) begin
 nonzero_count <= nonzero_count + 1;
 if (abs_i > max_abs_i) max_abs_i <= abs_i;
 end
 if (total_valid < 50)
 $display("out[%0d] i=%0d q=%0d t=%0t", total_valid, tx_i_lvds, tx_q_lvds, $time);
 end
end

initial begin
 $dumpfile("tb_tetra_tx_frontend_unit.vcd");
 $dumpvars(0, tb_tetra_tx_frontend_unit);

 rst_n_sys = 0;
 rst_n_lvds = 0;
 i_in = 16'sd0;
 q_in = 16'sd0;
 sample_valid_in = 0;
 nonzero_count = 0;
 total_valid = 0;
 max_abs_i = 0;
 abs_i = 0;

 repeat (10) @(posedge clk_sys);
 rst_n_sys = 1;
 rst_n_lvds = 1;
 repeat (10) @(posedge clk_sys);

 // Send 8 samples at 256-cycle spacing (rate-matched to CIC input)
 // Use constant amplitude so expected CIC output ~= input amplitude
 repeat (8) begin: send_loop
 i_in = 16'sd10000;
 q_in = 16'sd8000;
 @(posedge clk_sys);
 sample_valid_in = 1;
 @(posedge clk_sys);
 sample_valid_in = 0;
 i_in = 0; q_in = 0;
 // Wait 255 more cycles (total 256 per sample)
 repeat (254) @(posedge clk_sys);
 end

 // Wait for CIC to flush (N×R + some margin output samples)
 repeat (1024) @(posedge clk_lvds);

 $display("total_valid=%0d nonzero=%0d max_abs_i=%0d",
 total_valid, nonzero_count, max_abs_i);

 if (nonzero_count < 10) begin
 $display("FAIL: tx_frontend produced fewer than 10 non-zero outputs (nonzero=%0d)", nonzero_count);
 $fatal(1);
 end
 if (max_abs_i < 100) begin
 $display("FAIL: tx_frontend peak output too small (max_abs_i=%0d, expected >100)", max_abs_i);
 $fatal(1);
 end
 $display("PASS: tx_frontend non-zero output count=%0d peak=%0d", nonzero_count, max_abs_i);
 $finish;
end

endmodule
`default_nettype wire
