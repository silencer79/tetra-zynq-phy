`timescale 1ns / 1ps
`default_nettype none

// Quick diagnostic: Feed a known π/4-DQPSK signal through TX CIC interp → RX CIC decim → RX RRC
// Compare demodulated dibits against transmitted dibits to find where corruption occurs.
// Bypasses the heavy full_loopback by running CIC at identical clock speed.

module tb_rx_cic_rrc_diag;

localparam CLK_HALF = 5; // 100 MHz
localparam IQ_WIDTH = 16;

reg clk;
reg rst_n;

initial clk = 0;
always #CLK_HALF clk = ~clk;

// -------------------------------------------------------------------------
// TX: burst_builder → mod → rrc (same as bypass_cic)
// -------------------------------------------------------------------------
localparam integer SYM_DIV = 13'd0; // fastest symbol rate for quick STS test

reg [215:0] block1_data, block2_data;
reg [29:0] bb_data;
reg [119:0] sb1_data;
reg burst_type;
reg build_req;
reg idle_request_armed;
integer bursts_sent;

wire [1:0] tx_dibit;
wire tx_dibit_valid;
wire tx_done, tx_busy;
wire signed [15:0] mod_i, mod_q;
wire mod_valid;
wire signed [15:0] rrc_i, rrc_q;
wire rrc_valid;

tetra_burst_builder #(
.BLOCK_BITS(216),.BB_BITS(30),.SB1_BITS(120),.SYM_DIV(SYM_DIV)
) u_builder (
.clk_sys(clk),.rst_n_sys(rst_n),
.block1_data_sys(block1_data),.block2_data_sys(block2_data),
.bb_data_sys(bb_data),.sb1_data_sys(sb1_data),
.burst_type_sys(burst_type),.build_req_sys(build_req),
.tx_dibit_sys(tx_dibit),.tx_dibit_valid_sys(tx_dibit_valid),
.tx_done_sys(tx_done),.tx_busy_sys(tx_busy)
);

tetra_pi4dqpsk_mod #(
.IQ_WIDTH(16),.PHASE_WIDTH(16),.LUT_DEPTH(1024)
) u_mod (
.clk_sample(clk),.rst_n_sample(rst_n),
.dibit_in(tx_dibit),.dibit_valid(tx_dibit_valid),
.i_out(mod_i),.q_out(mod_q),.sample_valid_out(mod_valid)
);

tetra_rrc_filter #(
.IQ_WIDTH(16),.RRC_ACC_SHIFT(14)
) u_tx_rrc (
.clk_sys(clk),.rst_n_sys(rst_n),
.i_in(mod_i),.q_in(mod_q),.sample_valid_in(mod_valid),
.i_out(rrc_i),.q_out(rrc_q),.sample_valid_out(rrc_valid)
);

// -------------------------------------------------------------------------
// TX CIC interpolator (inside tx_frontend) → RX CIC decimator (inside rx_frontend)
// -------------------------------------------------------------------------
wire signed [15:0] tx_cic_i, tx_cic_q;
wire tx_cic_valid;

tetra_tx_frontend #(
.IQ_WIDTH(16),.CIC_SHIFT(24),.CIC_ACC(48)
) u_tx_fe (
.clk_sys(clk),.rst_n_sys(rst_n),
.i_in(rrc_i),.q_in(rrc_q),.sample_valid_in(rrc_valid),
.clk_lvds(clk),.rst_n_lvds(rst_n),
.tx_i_lvds(tx_cic_i),.tx_q_lvds(tx_cic_q),.tx_valid_lvds(tx_cic_valid)
);

wire signed [15:0] rx_fe_i, rx_fe_q;
wire rx_fe_valid;

tetra_rx_frontend #(
.IQ_WIDTH(16),.CIC_ORDER(5),.CIC_R(64),.CIC_M(1),
.RRC_TAPS(33),.RRC_ACC_SHIFT(14)
) u_rx_fe (
.clk_sys(clk),.rst_n_sys(rst_n),
.clk_lvds(clk),.rst_n_lvds(rst_n),
.rx_i_lvds(tx_cic_i),.rx_q_lvds(tx_cic_q),.rx_valid_lvds(tx_cic_valid),
.i_out_sys(rx_fe_i),.q_out_sys(rx_fe_q),.out_valid_sys(rx_fe_valid),
.loopback_en_sys(1'b1)
);

// -------------------------------------------------------------------------
// BYPASS path: TX RRC → timing_recovery → demod (for reference)
// -------------------------------------------------------------------------
wire signed [15:0] bp_tr_i, bp_tr_q;
wire bp_tr_valid, bp_timing_locked;
wire signed [15:0] bp_ted;

tetra_timing_recovery #(.IQ_WIDTH(16),.NCO_WIDTH(32)) u_bp_tr (
.clk_sys(clk),.rst_n_sys(rst_n),
.i_in_sys(rrc_i),.q_in_sys(rrc_q),.sample_valid_in_sys(rrc_valid),
.i_out_sys(bp_tr_i),.q_out_sys(bp_tr_q),
.sample_valid_out_sys(bp_tr_valid),
.timing_locked_sys(bp_timing_locked),.timing_error_sys(bp_ted)
);

wire [1:0] bp_dibit;
wire bp_dibit_valid;

tetra_pi4dqpsk_demod #(
.IQ_WIDTH(16),.PHASE_WIDTH(16),.CORDIC_ITER(16)
) u_bp_demod (
.clk_sample(clk),.rst_n_sample(rst_n),
.i_in(bp_tr_i),.q_in(bp_tr_q),.sample_valid(bp_tr_valid),
.dibit_out(bp_dibit),.dibit_valid(bp_dibit_valid),.phase_error()
);

// -------------------------------------------------------------------------
// FULL path: RX frontend → timing_recovery → demod
// -------------------------------------------------------------------------
wire signed [15:0] fl_tr_i, fl_tr_q;
wire fl_tr_valid, fl_timing_locked;
wire signed [15:0] fl_ted;

tetra_timing_recovery #(.IQ_WIDTH(16),.NCO_WIDTH(32)) u_fl_tr (
.clk_sys(clk),.rst_n_sys(rst_n),
.i_in_sys(rx_fe_i),.q_in_sys(rx_fe_q),.sample_valid_in_sys(rx_fe_valid),
.i_out_sys(fl_tr_i),.q_out_sys(fl_tr_q),
.sample_valid_out_sys(fl_tr_valid),
.timing_locked_sys(fl_timing_locked),.timing_error_sys(fl_ted)
);

wire [1:0] fl_dibit;
wire fl_dibit_valid;

tetra_pi4dqpsk_demod #(
.IQ_WIDTH(16),.PHASE_WIDTH(16),.CORDIC_ITER(16)
) u_fl_demod (
.clk_sample(clk),.rst_n_sample(rst_n),
.i_in(fl_tr_i),.q_in(fl_tr_q),.sample_valid(fl_tr_valid),
.dibit_out(fl_dibit),.dibit_valid(fl_dibit_valid),.phase_error()
);

// -------------------------------------------------------------------------
// Comparison counters
// -------------------------------------------------------------------------
integer bp_count, fl_count;
integer bp_match_cnt, fl_match_cnt;
integer tx_dibit_count;
reg [1:0] tx_dibit_history [0:4095];

// Store TX dibits for comparison
always @(posedge clk) begin
 if (!rst_n)
 tx_dibit_count <= 0;
 else if (tx_dibit_valid) begin
 tx_dibit_history[tx_dibit_count[11:0]] <= tx_dibit;
 tx_dibit_count <= tx_dibit_count + 1;
 end
end

// Compare bypass path dibits
always @(posedge clk) begin
 if (!rst_n) begin
 bp_count <= 0;
 bp_match_cnt <= 0;
 end else if (bp_dibit_valid) begin
 bp_count <= bp_count + 1;
 // Print first 40 bypass dibits
 if (bp_count < 40)
 $display("bp[%0d] dibit=%02b locked=%b t=%0t", bp_count, bp_dibit, bp_timing_locked, $time);
 end
end

// Compare full path dibits
integer fl_fe_count;
always @(posedge clk) begin
 if (!rst_n) begin
 fl_count <= 0;
 fl_match_cnt <= 0;
 fl_fe_count <= 0;
 end else begin
 if (rx_fe_valid) begin
 fl_fe_count <= fl_fe_count + 1;
 if (fl_fe_count < 20)
 $display("fe[%0d] i=%0d q=%0d t=%0t", fl_fe_count, rx_fe_i, rx_fe_q, $time);
 end
 if (fl_dibit_valid) begin
 fl_count <= fl_count + 1;
 if (fl_count < 40)
 $display("fl[%0d] dibit=%02b i=%0d q=%0d locked=%b ted=%0d t=%0t",
 fl_count, fl_dibit, fl_tr_i, fl_tr_q, fl_timing_locked, fl_ted, $time);
 end
 end
end

// -------------------------------------------------------------------------
// Burst request
// -------------------------------------------------------------------------
always @(posedge clk) begin
 if (!rst_n) begin
 build_req <= 0;
 bursts_sent <= 0;
 idle_request_armed <= 1;
 end else begin
 build_req <= 0;
 if (tx_busy) idle_request_armed <= 1;
 else if (idle_request_armed && bursts_sent < 6) begin
 build_req <= 1;
 bursts_sent <= bursts_sent + 1;
 idle_request_armed <= 0;
 end
 end
end

// -------------------------------------------------------------------------
// Main test
// -------------------------------------------------------------------------
initial begin
 $dumpfile("tb_rx_cic_rrc_diag.vcd");
 $dumpvars(0, tb_rx_cic_rrc_diag);

 rst_n = 0;
 block1_data = 216'd0;
 block2_data = 216'hB81F981169D98E949B1E87E9CE5528DF8CA1890DBFE6426841992D;
 bb_data = 30'd0;
 sb1_data = 120'h637C777BF26B6FC53001672BFED7;
 burst_type = 1;
 build_req = 0;
 idle_request_armed = 1;
 bursts_sent = 0;
 tx_dibit_count = 0;
 bp_count = 0; fl_count = 0;
 bp_match_cnt = 0; fl_match_cnt = 0;
 fl_fe_count = 0;

 repeat (20) @(posedge clk);
 rst_n = 1;

 // Wait for full path to produce dibits (CIC adds latency)
 // Timeout after 5s sim time
 begin: wait_loop
 integer timeout;
 timeout = 0;
 while (fl_count < 100 && timeout < 500000000) begin
 @(posedge clk);
 timeout = timeout + 1;
 end
 $display("--- bypass=%0d dibits, full=%0d dibits, fe_samples=%0d ---",
 bp_count, fl_count, fl_fe_count);
 if (fl_count < 100)
 $display("TIMEOUT: full path only produced %0d dibits", fl_count);
 end

 $finish;
end

endmodule

`default_nettype wire
