// =============================================================================
// Module: tetra_tx_inv_sinc
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_tx_inv_sinc.v
//
// Description:
// Inverse-sinc FIR compensation filter for CIC interpolator droop.
// Placed between RRC filter output (72 kHz) and CIC interpolator input.
//
// Compensates the passband droop of the downstream CIC (R=64, N=5):
//   0 Hz:     0.00 dB → +0.00 dB = 0.00 dB (flat)
//   5 kHz:   -0.34 dB → +0.30 dB = -0.05 dB
//   9 kHz:   -1.12 dB → +1.07 dB = -0.05 dB
//  12.5 kHz: -2.17 dB → +2.03 dB = -0.14 dB
//
// Architecture: 7-tap symmetric FIR, linear phase.
//   Coefficients Q14, computed by least-squares inverse-sinc design.
//   Symmetry exploited: 4 unique coefficients, 3 pre-adders → 4 multiplies.
//   Single MAC not needed — at 72 kHz strobe rate vs 100 MHz clock,
//   all 4 multiplies can be done in parallel (combinatorial) and registered.
//
// Sample rate: 72 kHz (4× symbol rate, from RRC polyphase output)
// Latency: 1 clk_sys cycle after sample_valid_in
//
// Resource estimate:
//   LUT : ~40   FF : ~80   DSP48 : 0   BRAM : 0
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_inv_sinc #(
    parameter IQ_WIDTH = 16
)(
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,

    input  wire signed [IQ_WIDTH-1:0] i_in,
    input  wire signed [IQ_WIDTH-1:0] q_in,
    input  wire                       sample_valid_in,

    output reg  signed [IQ_WIDTH-1:0] i_out,
    output reg  signed [IQ_WIDTH-1:0] q_out,
    output reg                        sample_valid_out
);

// =============================================================================
// Coefficients — 7-tap symmetric inverse-sinc, Q14
// Designed for CIC R=64, N=5, passband ±12.5 kHz at 72 kHz sample rate.
// h = [930, -3346, 2332, 16553, 2332, -3346, 930]
// DC gain = 16385 ≈ 2^14 (unity)
// Symmetry: h[0]=h[6], h[1]=h[5], h[2]=h[4], h[3]=center
// =============================================================================
localparam signed [15:0] C0 =  16'sd930;    // h[0] = h[6]
localparam signed [15:0] C1 = -16'sd3346;   // h[1] = h[5]
localparam signed [15:0] C2 =  16'sd2332;   // h[2] = h[4]
localparam signed [15:0] C3 =  16'sd16553;  // h[3] center

// =============================================================================
// Shift register — 7 samples deep, IQ interleaved
// sr_i[0] = newest, sr_i[6] = oldest
// =============================================================================
reg signed [IQ_WIDTH-1:0] sr_i0, sr_i1, sr_i2, sr_i3, sr_i4, sr_i5, sr_i6;
reg signed [IQ_WIDTH-1:0] sr_q0, sr_q1, sr_q2, sr_q3, sr_q4, sr_q5, sr_q6;

// R1: shift register I
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sr_i0 <= {IQ_WIDTH{1'b0}};
        sr_i1 <= {IQ_WIDTH{1'b0}};
        sr_i2 <= {IQ_WIDTH{1'b0}};
        sr_i3 <= {IQ_WIDTH{1'b0}};
        sr_i4 <= {IQ_WIDTH{1'b0}};
        sr_i5 <= {IQ_WIDTH{1'b0}};
        sr_i6 <= {IQ_WIDTH{1'b0}};
    end else if (sample_valid_in) begin
        sr_i6 <= sr_i5;
        sr_i5 <= sr_i4;
        sr_i4 <= sr_i3;
        sr_i3 <= sr_i2;
        sr_i2 <= sr_i1;
        sr_i1 <= sr_i0;
        sr_i0 <= i_in;
    end
end

// R1: shift register Q
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sr_q0 <= {IQ_WIDTH{1'b0}};
        sr_q1 <= {IQ_WIDTH{1'b0}};
        sr_q2 <= {IQ_WIDTH{1'b0}};
        sr_q3 <= {IQ_WIDTH{1'b0}};
        sr_q4 <= {IQ_WIDTH{1'b0}};
        sr_q5 <= {IQ_WIDTH{1'b0}};
        sr_q6 <= {IQ_WIDTH{1'b0}};
    end else if (sample_valid_in) begin
        sr_q6 <= sr_q5;
        sr_q5 <= sr_q4;
        sr_q4 <= sr_q3;
        sr_q3 <= sr_q2;
        sr_q2 <= sr_q1;
        sr_q1 <= sr_q0;
        sr_q0 <= q_in;
    end
end

// =============================================================================
// Pre-adders (exploit symmetry: h[k] = h[6-k])
// =============================================================================
wire signed [IQ_WIDTH:0] pa_i0 = {sr_i0[IQ_WIDTH-1], sr_i0} + {sr_i6[IQ_WIDTH-1], sr_i6};
wire signed [IQ_WIDTH:0] pa_i1 = {sr_i1[IQ_WIDTH-1], sr_i1} + {sr_i5[IQ_WIDTH-1], sr_i5};
wire signed [IQ_WIDTH:0] pa_i2 = {sr_i2[IQ_WIDTH-1], sr_i2} + {sr_i4[IQ_WIDTH-1], sr_i4};

wire signed [IQ_WIDTH:0] pa_q0 = {sr_q0[IQ_WIDTH-1], sr_q0} + {sr_q6[IQ_WIDTH-1], sr_q6};
wire signed [IQ_WIDTH:0] pa_q1 = {sr_q1[IQ_WIDTH-1], sr_q1} + {sr_q5[IQ_WIDTH-1], sr_q5};
wire signed [IQ_WIDTH:0] pa_q2 = {sr_q2[IQ_WIDTH-1], sr_q2} + {sr_q4[IQ_WIDTH-1], sr_q4};

// =============================================================================
// Multiply-accumulate (combinatorial — plenty of time at 72 kHz)
// Result width: 17 (pre-add) + 16 (coeff) + 2 (accumulation of 4 terms) = 35
// =============================================================================
localparam ACC_W = 35;

wire signed [ACC_W-1:0] acc_i = pa_i0 * C0 + pa_i1 * C1 + pa_i2 * C2
                               + {{(ACC_W-IQ_WIDTH){sr_i3[IQ_WIDTH-1]}}, sr_i3} * C3;
wire signed [ACC_W-1:0] acc_q = pa_q0 * C0 + pa_q1 * C1 + pa_q2 * C2
                               + {{(ACC_W-IQ_WIDTH){sr_q3[IQ_WIDTH-1]}}, sr_q3} * C3;

// =============================================================================
// Output scaling: >> 14 (Q14 coefficients), saturate to IQ_WIDTH
// =============================================================================
wire signed [ACC_W-1:0] sc_i = acc_i >>> 14;
wire signed [ACC_W-1:0] sc_q = acc_q >>> 14;

wire i_ovf = (|sc_i[ACC_W-1:IQ_WIDTH-1]) && (~&sc_i[ACC_W-1:IQ_WIDTH-1]);
wire q_ovf = (|sc_q[ACC_W-1:IQ_WIDTH-1]) && (~&sc_q[ACC_W-1:IQ_WIDTH-1]);

wire signed [IQ_WIDTH-1:0] i_sat =
    i_ovf ? (sc_i[ACC_W-1] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}
                           : {1'b0, {(IQ_WIDTH-1){1'b1}}})
          : sc_i[IQ_WIDTH-1:0];
wire signed [IQ_WIDTH-1:0] q_sat =
    q_ovf ? (sc_q[ACC_W-1] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}
                           : {1'b0, {(IQ_WIDTH-1){1'b1}}})
          : sc_q[IQ_WIDTH-1:0];

// =============================================================================
// R1: output registers
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_out <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in) i_out <= i_sat;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_out <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in) q_out <= q_sat;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sample_valid_out <= 1'b0;
    else            sample_valid_out <= sample_valid_in;
end

endmodule
`default_nettype wire
