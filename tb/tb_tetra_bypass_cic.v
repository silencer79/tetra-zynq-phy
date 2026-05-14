`timescale 1ns / 1ps
`default_nettype none

// Bypass testbench: TX chain (builder→mod→RRC) directly into timing_recovery+demod+sync_detect.
// No TX frontend or RX frontend (CIC pair bypassed).
// Proves whether the problem is in the CIC or elsewhere.

module tb_tetra_bypass_cic;

localparam CLK_HALF = 5;
localparam integer BURSTS_TO_SEND = 4;
localparam integer SYM_DIV = 13'd1023;

reg clk_sys;
reg rst_n_sys;

reg [215:0] block1_data_sys;
reg [215:0] block2_data_sys;
reg [29:0] bb_data_sys;
reg [119:0] sb1_data_sys;
reg burst_type_sys;
reg build_req_sys;
reg idle_request_armed;

wire [1:0] builder_dibit_sys;
wire builder_dibit_valid_sys;
wire tx_done_sys;
wire tx_busy_sys;

wire signed [15:0] mod_i_sys;
wire signed [15:0] mod_q_sys;
wire mod_valid_sys;

wire signed [15:0] rrc_i_sys;
wire signed [15:0] rrc_q_sys;
wire rrc_valid_sys;

// Timing recovery receives RRC output directly (4× oversampled, 1 valid per 256 cycles)
wire signed [15:0] tr_i_sys;
wire signed [15:0] tr_q_sys;
wire tr_valid_sys;
wire timing_locked_sys;
wire signed [15:0] timing_error_sys;

wire [1:0] demod_dibit_sys;
wire demod_valid_sys;
wire sync_found;
wire sync_locked;
wire [7:0] slot_position;
wire [1:0] slot_number;

integer bursts_sent;
integer sync_found_count;
integer timeout_cycles;
integer tr_count_dbg;

initial clk_sys = 1'b0;
always #CLK_HALF clk_sys = ~clk_sys;

tetra_burst_builder #(
.BLOCK_BITS (216),
.BB_BITS (30),
.SB1_BITS (120),
.SYM_DIV (SYM_DIV)
) dut_builder (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.block1_data_sys (block1_data_sys),
.block2_data_sys (block2_data_sys),
.bb_data_sys (bb_data_sys),
.sb1_data_sys (sb1_data_sys),
.burst_type_sys (burst_type_sys),
.build_req_sys (build_req_sys),
.tx_dibit_sys (builder_dibit_sys),
.tx_dibit_valid_sys (builder_dibit_valid_sys),
.tx_done_sys (tx_done_sys),
.tx_busy_sys (tx_busy_sys)
);

tetra_pi4dqpsk_mod #(
.IQ_WIDTH (16),
.PHASE_WIDTH (16),
.LUT_DEPTH (1024)
) dut_mod (
.clk_sample (clk_sys),
.rst_n_sample (rst_n_sys),
.dibit_in (builder_dibit_sys),
.dibit_valid (builder_dibit_valid_sys),
.i_out (mod_i_sys),
.q_out (mod_q_sys),
.sample_valid_out (mod_valid_sys)
);

tetra_rrc_filter #(
.IQ_WIDTH (16),
.RRC_ACC_SHIFT (14)
) dut_rrc (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.i_in (mod_i_sys),
.q_in (mod_q_sys),
.sample_valid_in (mod_valid_sys),
.i_out (rrc_i_sys),
.q_out (rrc_q_sys),
.sample_valid_out (rrc_valid_sys)
);

// RRC output → timing recovery directly (bypass CIC pair)
// RRC outputs 4 samples per symbol at 1/256 rate → NCO_NOMINAL=2^30 overflows every 4 valids ✓
tetra_timing_recovery #(
.IQ_WIDTH (16),
.NCO_WIDTH (32)
) dut_timing (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.i_in_sys (rrc_i_sys),
.q_in_sys (rrc_q_sys),
.sample_valid_in_sys (rrc_valid_sys),
.i_out_sys (tr_i_sys),
.q_out_sys (tr_q_sys),
.sample_valid_out_sys (tr_valid_sys),
.timing_locked_sys (timing_locked_sys),
.timing_error_sys (timing_error_sys)
);

tetra_pi4dqpsk_demod #(
.IQ_WIDTH (16),
.PHASE_WIDTH (16),
.CORDIC_ITER (16)
) dut_demod (
.clk_sample (clk_sys),
.rst_n_sample (rst_n_sys),
.i_in (tr_i_sys),
.q_in (tr_q_sys),
.sample_valid (tr_valid_sys),
.dibit_out (demod_dibit_sys),
.dibit_valid (demod_valid_sys),
.phase_error ()
);

tetra_sync_detect #(
.CORR_WIDTH (6),
.SEQ_LEN_MAX (38),
.HOLDOFF (220),
.LOCK_COUNT (4),
.SLOT_SYMS (255),
.LOCK_TOL (8),
.LOCK_TIMEOUT (300)
) dut_sync (
.clk_sample (clk_sys),
.rst_n_sample (rst_n_sys),
.dibit_in (demod_dibit_sys),
.dibit_valid (demod_valid_sys),
.corr_threshold (6'd15),
.seq_select (2'd2),
.sync_found (sync_found),
.sync_locked (sync_locked),
.slot_position (slot_position),
.slot_number (slot_number),
.corr_peak ()
);

always @(posedge clk_sys) begin
 if (!rst_n_sys)
 sync_found_count <= 0;
 else if (sync_found) begin
 sync_found_count <= sync_found_count + 1;
 $display("bypass sync_found at time=%0t slot_pos=%0d count=%0d",
 $time, slot_position, sync_found_count + 1);
 end
end

// Print first 60 TR samples: IQ, TED, magnitude
always @(posedge clk_sys) begin
 if (!rst_n_sys)
 tr_count_dbg <= 0;
 else if (tr_valid_sys) begin
 tr_count_dbg <= tr_count_dbg + 1;
 if (tr_count_dbg < 60)
 $display("bypass_tr[%0d] i=%0d q=%0d ted=%0d locked=%0b t=%0t",
 tr_count_dbg, tr_i_sys, tr_q_sys, timing_error_sys,
 timing_locked_sys, $time);
 end
end

always @(posedge clk_sys) begin
 if (!rst_n_sys) begin
 build_req_sys <= 1'b0;
 bursts_sent <= 0;
 idle_request_armed <= 1'b1;
 end else begin
 build_req_sys <= 1'b0;
 if (tx_busy_sys)
 idle_request_armed <= 1'b1;
 else if (idle_request_armed && bursts_sent < BURSTS_TO_SEND) begin
 build_req_sys <= 1'b1;
 bursts_sent <= bursts_sent + 1;
 idle_request_armed <= 1'b0;
 end
 end
end

initial begin
 $dumpfile("tb_tetra_bypass_cic.vcd");
 $dumpvars(0, tb_tetra_bypass_cic);

 rst_n_sys = 1'b0;
 block1_data_sys = 216'd0;
 block2_data_sys = 216'hB81F981169D98E949B1E87E9CE5528DF8CA1890DBFE6426841992D;
 bb_data_sys = 30'd0;
 sb1_data_sys = 120'h637C777BF26B6FC53001672BFED7;
 burst_type_sys = 1'b1;
 build_req_sys = 1'b0;
 idle_request_armed = 1'b1;
 bursts_sent = 0;
 sync_found_count = 0;
 tr_count_dbg = 0;

 repeat (20) @(posedge clk_sys);
 rst_n_sys = 1'b1;

 timeout_cycles = 0;
 while (!sync_locked && timeout_cycles < 5000000) begin
 @(posedge clk_sys);
 timeout_cycles = timeout_cycles + 1;
 end

 if (!sync_locked) begin
 $display("FAIL: bypass sync_locked never asserted, sync_found_count=%0d timing_locked=%0b",
 sync_found_count, timing_locked_sys);
 $fatal(1);
 end

 $display("PASS: bypass sync_locked after %0d cycles, sync_found_count=%0d",
 timeout_cycles, sync_found_count);
 $finish;
end

endmodule

`default_nettype wire
