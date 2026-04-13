// =============================================================================
// Module:  tetra_tx_nco
// Project: tetra-zynq-phy
// File:    rtl/tx/tetra_tx_nco.v
//
// Description:
//   TX NCO — Complex frequency shifter for LO leakage avoidance.
//
//   Multiplies input IQ by exp(j·2π·f_offset·n/fs) to shift the transmit
//   spectrum away from the AD9361 TX LO frequency.
//
//   phase_inc = round(f_offset_hz × 2^32 / 4608000)
//   Example: 25 kHz → phase_inc = 23301840 (0x0163_8E90)
//
//   When phase_inc = 0, output equals input (unity gain, no shift).
//
// Pipeline: 3 cycles latency (LUT read → multiply → add/saturate)
//
// Resources: ~4 DSP48, 1 BRAM18 (or distributed RAM), ~50 FF
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_nco #(
    parameter IQ_WIDTH   = 16,
    parameter PHASE_WIDTH = 32,
    parameter LUT_BITS   = 10    // 1024 entries
)(
    // -------------------------------------------------------------------------
    // clk_lvds domain (18.432 MHz, output rate 4.608 MHz)
    // -------------------------------------------------------------------------
    input  wire                        clk_lvds,
    input  wire                        rst_n_lvds,

    // Phase increment (from AXI register, sys domain — CDC handled here)
    input  wire [PHASE_WIDTH-1:0]      phase_inc_sys,

    // Input IQ from tx_frontend
    input  wire signed [IQ_WIDTH-1:0]  i_in,
    input  wire signed [IQ_WIDTH-1:0]  q_in,
    input  wire                        valid_in,

    // Output IQ to AD9361
    output reg  signed [IQ_WIDTH-1:0]  i_out,
    output reg  signed [IQ_WIDTH-1:0]  q_out,
    output reg                         valid_out
);

// =========================================================================
// CDC: 2-FF synchronizer for phase_inc (set once at init, stable)
// =========================================================================
(* ASYNC_REG = "TRUE" *) reg [PHASE_WIDTH-1:0] phase_inc_r0_lvds;
(* ASYNC_REG = "TRUE" *) reg [PHASE_WIDTH-1:0] phase_inc_r1_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) begin
        phase_inc_r0_lvds <= {PHASE_WIDTH{1'b0}};
        phase_inc_r1_lvds <= {PHASE_WIDTH{1'b0}};
    end else begin
        phase_inc_r0_lvds <= phase_inc_sys;
        phase_inc_r1_lvds <= phase_inc_r0_lvds;
    end
end

// =========================================================================
// Phase accumulator — advances on each valid_in pulse
// =========================================================================
reg [PHASE_WIDTH-1:0] phase_acc_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        phase_acc_lvds <= {PHASE_WIDTH{1'b0}};
    else if (valid_in)
        phase_acc_lvds <= phase_acc_lvds + phase_inc_r1_lvds;
end

// =========================================================================
// Sin LUT — 1024 entries × 16-bit signed, full-wave
// cos(θ) = sin(θ + π/2) accessed via +256 offset
// =========================================================================
localparam LUT_DEPTH = 1 << LUT_BITS;   // 1024
localparam LUT_QUARTER = LUT_DEPTH / 4; // 256

reg signed [IQ_WIDTH-1:0] sin_lut [0:LUT_DEPTH-1];

initial $readmemh("sin_lut_1024x16.hex", sin_lut);

wire [LUT_BITS-1:0] sin_addr_w = phase_acc_lvds[PHASE_WIDTH-1 -: LUT_BITS];
wire [LUT_BITS-1:0] cos_addr_w = sin_addr_w + LUT_QUARTER[LUT_BITS-1:0];

// =========================================================================
// Pipeline Stage 1: LUT read + latch input
// =========================================================================
reg signed [IQ_WIDTH-1:0] sin_val_lvds;
reg signed [IQ_WIDTH-1:0] cos_val_lvds;
reg signed [IQ_WIDTH-1:0] i_p1_lvds;
reg signed [IQ_WIDTH-1:0] q_p1_lvds;
reg                        valid_p1_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) begin
        sin_val_lvds <= {IQ_WIDTH{1'b0}};
        cos_val_lvds <= {IQ_WIDTH{1'b0}};
        i_p1_lvds    <= {IQ_WIDTH{1'b0}};
        q_p1_lvds    <= {IQ_WIDTH{1'b0}};
        valid_p1_lvds <= 1'b0;
    end else begin
        sin_val_lvds <= sin_lut[sin_addr_w];
        cos_val_lvds <= sin_lut[cos_addr_w];
        i_p1_lvds    <= i_in;
        q_p1_lvds    <= q_in;
        valid_p1_lvds <= valid_in;
    end
end

// =========================================================================
// Pipeline Stage 2: Complex multiply
//   I_mix = I·cos − Q·sin
//   Q_mix = I·sin + Q·cos
// =========================================================================
reg signed [2*IQ_WIDTH-1:0] p_ic_lvds;  // I × cos
reg signed [2*IQ_WIDTH-1:0] p_qs_lvds;  // Q × sin
reg signed [2*IQ_WIDTH-1:0] p_is_lvds;  // I × sin
reg signed [2*IQ_WIDTH-1:0] p_qc_lvds;  // Q × cos
reg                          valid_p2_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) begin
        p_ic_lvds <= {(2*IQ_WIDTH){1'b0}};
        p_qs_lvds <= {(2*IQ_WIDTH){1'b0}};
        p_is_lvds <= {(2*IQ_WIDTH){1'b0}};
        p_qc_lvds <= {(2*IQ_WIDTH){1'b0}};
        valid_p2_lvds <= 1'b0;
    end else begin
        p_ic_lvds <= i_p1_lvds * cos_val_lvds;
        p_qs_lvds <= q_p1_lvds * sin_val_lvds;
        p_is_lvds <= i_p1_lvds * sin_val_lvds;
        p_qc_lvds <= q_p1_lvds * cos_val_lvds;
        valid_p2_lvds <= valid_p1_lvds;
    end
end

// =========================================================================
// Pipeline Stage 3: Add/subtract + scale + saturate
//
// Products are Q1.15 × Q1.15 = Q2.30 (32-bit signed).
// Diff/sum: 33 bits. Shift right by 15 → 18-bit result.
// Saturate 18-bit to 16-bit signed.
// =========================================================================
wire signed [2*IQ_WIDTH:0] mix_i_w = {p_ic_lvds[2*IQ_WIDTH-1], p_ic_lvds}
                                    - {p_qs_lvds[2*IQ_WIDTH-1], p_qs_lvds};
wire signed [2*IQ_WIDTH:0] mix_q_w = {p_is_lvds[2*IQ_WIDTH-1], p_is_lvds}
                                    + {p_qc_lvds[2*IQ_WIDTH-1], p_qc_lvds};

// Arithmetic right shift by 15 → 18-bit result
wire signed [17:0] i_sh_w = mix_i_w[32:15];
wire signed [17:0] q_sh_w = mix_q_w[32:15];

// Saturation: check if bits [17:15] are all the same (no overflow)
wire i_ovf_w = ~(&i_sh_w[17:15]) & (|i_sh_w[17:15]);
wire q_ovf_w = ~(&q_sh_w[17:15]) & (|q_sh_w[17:15]);

wire signed [IQ_WIDTH-1:0] i_sat_w = i_ovf_w ? (i_sh_w[17] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}
                                                             : {1'b0, {(IQ_WIDTH-1){1'b1}}})
                                              : i_sh_w[IQ_WIDTH-1:0];
wire signed [IQ_WIDTH-1:0] q_sat_w = q_ovf_w ? (q_sh_w[17] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}
                                                             : {1'b0, {(IQ_WIDTH-1){1'b1}}})
                                              : q_sh_w[IQ_WIDTH-1:0];

// R1: Output registers
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) begin
        i_out     <= {IQ_WIDTH{1'b0}};
        q_out     <= {IQ_WIDTH{1'b0}};
        valid_out <= 1'b0;
    end else begin
        i_out     <= i_sat_w;
        q_out     <= q_sat_w;
        valid_out <= valid_p2_lvds;
    end
end

endmodule
`default_nettype wire
