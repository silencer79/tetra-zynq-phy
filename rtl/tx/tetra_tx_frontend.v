// =============================================================================
// Module:  tetra_tx_frontend
// Project: tetra-zynq-phy
// File:    rtl/tx/tetra_tx_frontend.v
//
// Description:
//   TX Frontend — CIC Interpolator (R=64, N=5, M=1) with CDC (sys → lvds).
//
//   Upsamples IQ samples from 72 kHz (post-RRC, clk_sys domain) to 4.608 MHz
//   (AD9361 DAC rate, clk_lvds domain).
//
//   Clock relations (all exact):
//     clk_lvds  = 18.432 MHz = 256 × 72 kHz = 4 × 4.608 MHz
//     (AD9361 2R2T DDR LVDS: DATA_CLK = 4 × sample_rate = 4 × 4.608 MSPS)
//     Input     = 72 kHz  (one IQ pair per ~256 lvds cycles)
//     Output    = 4.608 MHz = one IQ pair every 4 clk_lvds cycles
//
// Architecture:
//   [clk_sys domain]
//     XPM Async FIFO write: one 32-bit entry {i_in[15:0], q_in[15:0]} per
//     sample_valid_in pulse.
//
//   [clk_lvds domain — CIC interpolator]
//     lvds_cnt[7:0]: 8-bit counter 0..255 (natural overflow = R×4 - 1)
//
//     Timing summary (each line = 1 clk_lvds cycle):
//       cnt==254 → FIFO rd_en pulse
//       cnt==255 → fifo_dout valid; comb stages update;
//                  FIRST integration step (adds new comb_out = OLD period's comb)
//       cnt==0,4,8,...,252 → 64 integration steps per period
//       cnt==1,2,3,5,6,7,...,253,255 → no integration
//       Output valid: 1 cycle after each integration step (cnt==1,5,...,253
//                     with 1-cycle pipeline delay from intg to output registers)
//
//     CIC comb section (5 × 1st-order differentiator at input rate):
//       y[n] = x[n] - x[n-1],  updated once per 128-cycle period
//       All 5 comb stages update simultaneously on comb_load_w (cnt==0).
//
//     CIC integrator section (5 cascaded accumulators at output rate):
//       Each integrator: acc += input
//       Input to integrator chain = comb_out (only at cnt==0); 0 otherwise.
//       This implements zero-insertion interpolation correctly:
//         [comb_out, 0, 0, ..., 0]  per 128-cycle period → 64 output samples.
//
//     Effective interpolation gain of this comb-before-zero-stuff structure:
//       R^(N-1) = 64^4 = 2^24
//     Output scaling: right-shift by CIC_SHIFT=24, then saturate to IQ_WIDTH.
//     Accumulator width: CIC_ACC = 48 bits (16 + 30 + 2 guard bits).
//
//   Output valid pulses: 64 per 256 lvds cycles → 18.432 MHz / 4 = 4.608 MHz ✓
//
// Resource estimate (Vivado 2022.2, xc7z020):
//   LUT  : ~80    FF : ~680    DSP48 : 0    BRAM : 0 (LUTRAM FIFO)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// Ref: EN 300 392-2 §9.5; Hogenauer 1981 (CIC filters); Xilinx UG974 (XPM)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_frontend #(
    parameter IQ_WIDTH  = 16,    // signed IQ sample width
    parameter CIC_SHIFT = 24,    // Effective gain = R^(N-1) = 64^4 = 2^24
    parameter CIC_ACC   = 48     // accumulator width (IQ_WIDTH + 30 + 2 guard)
)(
    // -------------------------------------------------------------------------
    // clk_sys domain
    // -------------------------------------------------------------------------
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,

    input  wire signed [IQ_WIDTH-1:0] i_in,
    input  wire signed [IQ_WIDTH-1:0] q_in,
    input  wire                       sample_valid_in,   // ~72 kHz strobe

    // -------------------------------------------------------------------------
    // clk_lvds domain (~9.216 MHz)
    // -------------------------------------------------------------------------
    input  wire                       clk_lvds,      // 18.432 MHz (AD9361 2R2T DDR DATA_CLK)
    input  wire                       rst_n_lvds,

    output reg  signed [IQ_WIDTH-1:0] tx_i_lvds,
    output reg  signed [IQ_WIDTH-1:0] tx_q_lvds,
    output reg                        tx_valid_lvds   // 1-cycle pulse per IQ pair @ 4.608 MHz
);

// =============================================================================
// ---- clk_sys domain — FIFO write ------------------------------------------
// Pack: {i_in[15:0], q_in[15:0]}
// =============================================================================
wire [31:0] fifo_din_sys = {i_in, q_in};

// =============================================================================
// XPM Async FIFO — sys (write) → lvds (read)
// Parameters match xilinx_prim_sim.v model in tb/sim_models/
// READ_MODE="std", FIFO_READ_LATENCY=1:
//   the local model updates dout on the read clock edge, so rd_en is issued
//   one cycle before comb_load_w to make fifo_dout stable when consumed.
// =============================================================================
wire [31:0] fifo_dout_lvds;
wire        fifo_rd_en_lvds;
wire        fifo_empty_lvds;
wire        fifo_wr_full_sys;
wire        fifo_wr_rst_busy_sys;
wire        fifo_rd_rst_busy_lvds;

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH (16),
    .WRITE_DATA_WIDTH (32),
    .READ_DATA_WIDTH  (32),
    .READ_MODE        ("std"),
    .FIFO_READ_LATENCY(1),
    .CDC_SYNC_STAGES  (2),
    .FULL_RESET_VALUE (0),
    .ECC_MODE         ("no_ecc"),
    .RELATED_CLOCKS   (0),
    .USE_ADV_FEATURES ("0000"),
    .DOUT_RESET_VALUE ("0"),
    .WAKEUP_TIME      (0),
    .PROG_FULL_THRESH (10),
    .PROG_EMPTY_THRESH(3)
) u_cdc_fifo (
    .wr_clk        (clk_sys),
    .rst           (~rst_n_sys),
    .wr_en         (sample_valid_in),
    .din           (fifo_din_sys),
    .full          (fifo_wr_full_sys),
    .wr_rst_busy   (fifo_wr_rst_busy_sys),
    .prog_full     (),
    .overflow      (),
    .wr_data_count (),
    .almost_full   (),

    .rd_clk        (clk_lvds),
    .rd_en         (fifo_rd_en_lvds),
    .dout          (fifo_dout_lvds),
    .empty         (fifo_empty_lvds),
    .rd_rst_busy   (fifo_rd_rst_busy_lvds),
    .prog_empty    (),
    .underflow     (),
    .rd_data_count (),
    .almost_empty  (),

    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       (),
    .sleep         (1'b0)
);

// =============================================================================
// ---- clk_lvds domain — CIC Interpolator -----------------------------------
// =============================================================================

// -------------------------------------------------------------------------
// R1: lvds_cnt[7:0] — 8-bit counter 0..255
// At clk_lvds=18.432 MHz: period = 256/18.432 MHz = 13.89 µs = 72 kHz symbol rate ✓
// -------------------------------------------------------------------------
reg [7:0] lvds_cnt;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        lvds_cnt <= 8'd0;
    else
        lvds_cnt <= lvds_cnt + 8'd1;   // natural 8-bit wrap: 255 → 0
end

// FIFO read at cnt==254; data is consumed at cnt==255 on the next edge.
assign fifo_rd_en_lvds = (lvds_cnt == 8'd254) && !fifo_empty_lvds && !fifo_rd_rst_busy_lvds;

// comb_load_w fires at cnt==255 after fifo_dout has been updated by the read edge.
wire comb_load_w = (lvds_cnt == 8'd255);

// -------------------------------------------------------------------------
// R1: comb input register — latch FIFO data at cnt==0
// Underrun (FIFO empty): pass 0 to prevent garbage in integrators
// -------------------------------------------------------------------------
reg signed [CIC_ACC-1:0] comb_in_i_lvds;
reg signed [CIC_ACC-1:0] comb_in_q_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        comb_in_i_lvds <= {CIC_ACC{1'b0}};
    else if (comb_load_w)
        comb_in_i_lvds <= {{(CIC_ACC-IQ_WIDTH){fifo_dout_lvds[31]}}, fifo_dout_lvds[31:16]};
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        comb_in_q_lvds <= {CIC_ACC{1'b0}};
    else if (comb_load_w)
        comb_in_q_lvds <= {{(CIC_ACC-IQ_WIDTH){fifo_dout_lvds[15]}}, fifo_dout_lvds[15:0]};
end

// -------------------------------------------------------------------------
// Comb section: 5 × M=1 differentiator: y[n] = x[n] - x[n-1]
// All 5 stages update at comb_load_w (once per 128 lvds cycles).
// Each stage: one delay register (previous input) + current output register.
// R1: one always block per register.
// -------------------------------------------------------------------------

// Stage 1 ─────────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] cd1_i; reg signed [CIC_ACC-1:0] cd1_q;   // delay
reg signed [CIC_ACC-1:0] cy1_i; reg signed [CIC_ACC-1:0] cy1_q;   // output

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd1_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd1_i <= comb_in_i_lvds;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd1_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd1_q <= comb_in_q_lvds;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy1_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy1_i <= comb_in_i_lvds - cd1_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy1_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy1_q <= comb_in_q_lvds - cd1_q;
end

// Stage 2 ─────────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] cd2_i; reg signed [CIC_ACC-1:0] cd2_q;
reg signed [CIC_ACC-1:0] cy2_i; reg signed [CIC_ACC-1:0] cy2_q;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd2_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd2_i <= cy1_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd2_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd2_q <= cy1_q;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy2_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy2_i <= cy1_i - cd2_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy2_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy2_q <= cy1_q - cd2_q;
end

// Stage 3 ─────────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] cd3_i; reg signed [CIC_ACC-1:0] cd3_q;
reg signed [CIC_ACC-1:0] cy3_i; reg signed [CIC_ACC-1:0] cy3_q;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd3_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd3_i <= cy2_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd3_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd3_q <= cy2_q;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy3_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy3_i <= cy2_i - cd3_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy3_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy3_q <= cy2_q - cd3_q;
end

// Stage 4 ─────────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] cd4_i; reg signed [CIC_ACC-1:0] cd4_q;
reg signed [CIC_ACC-1:0] cy4_i; reg signed [CIC_ACC-1:0] cy4_q;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd4_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd4_i <= cy3_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd4_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd4_q <= cy3_q;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy4_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy4_i <= cy3_i - cd4_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cy4_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cy4_q <= cy3_q - cd4_q;
end

// Stage 5 — final comb output ─────────────────────────────────────────────
reg signed [CIC_ACC-1:0] cd5_i; reg signed [CIC_ACC-1:0] cd5_q;
reg signed [CIC_ACC-1:0] comb_out_i; reg signed [CIC_ACC-1:0] comb_out_q;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd5_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd5_i <= cy4_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) cd5_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) cd5_q <= cy4_q;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) comb_out_i <= {CIC_ACC{1'b0}};
    else if (comb_load_w) comb_out_i <= cy4_i - cd5_i;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) comb_out_q <= {CIC_ACC{1'b0}};
    else if (comb_load_w) comb_out_q <= cy4_q - cd5_q;
end

// -------------------------------------------------------------------------
// Integration enable: every 4th lvds cycle (cnt[1:0] == 2'b00)
//   64 pulses per 256-cycle period → output rate = 18.432 MHz / 4 = 4.608 MHz ✓
//   Matches AD9361 sample rate so loopback RX CIC (R=64) gets correct 72 kHz output.
// -------------------------------------------------------------------------
wire intg_en_w = (lvds_cnt[1:0] == 2'b00);

// -------------------------------------------------------------------------
// Integrator input (zero-insertion):
//   Add comb_out ONLY at cnt==0 (first integration step of each period).
//   Add 0 for all other 63 integration steps.
//   This implements the correct CIC zero-padded upsampling.
//
//   Note: comb_out holds the PREVIOUS period's value at cnt==0 (the new value
//   is registered on the same posedge → 1-cycle pipeline delay).
//   This is a 1-sample latency that is acceptable and standard.
// -------------------------------------------------------------------------
wire signed [CIC_ACC-1:0] intg_in_i_w =
    (lvds_cnt == 8'd0) ?
        comb_out_i :
        {CIC_ACC{1'b0}};
wire signed [CIC_ACC-1:0] intg_in_q_w =
    (lvds_cnt == 8'd0) ?
        comb_out_q :
        {CIC_ACC{1'b0}};

// -------------------------------------------------------------------------
// Integrator section: 5 cascaded accumulators
// R1: one always block per register
// -------------------------------------------------------------------------

// Integrator 1 ─────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] intg_i1; reg signed [CIC_ACC-1:0] intg_q1;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_i1 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_i1 <= intg_i1 + intg_in_i_w;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_q1 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_q1 <= intg_q1 + intg_in_q_w;
end

// Integrator 2 ─────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] intg_i2; reg signed [CIC_ACC-1:0] intg_q2;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_i2 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_i2 <= intg_i2 + intg_i1;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_q2 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_q2 <= intg_q2 + intg_q1;
end

// Integrator 3 ─────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] intg_i3; reg signed [CIC_ACC-1:0] intg_q3;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_i3 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_i3 <= intg_i3 + intg_i2;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_q3 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_q3 <= intg_q3 + intg_q2;
end

// Integrator 4 ─────────────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] intg_i4; reg signed [CIC_ACC-1:0] intg_q4;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_i4 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_i4 <= intg_i4 + intg_i3;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_q4 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_q4 <= intg_q4 + intg_q3;
end

// Integrator 5 — final ─────────────────────────────────────────────────────
reg signed [CIC_ACC-1:0] intg_i5; reg signed [CIC_ACC-1:0] intg_q5;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_i5 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_i5 <= intg_i5 + intg_i4;
end
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_q5 <= {CIC_ACC{1'b0}};
    else if (intg_en_w) intg_q5 <= intg_q5 + intg_q4;
end

// -------------------------------------------------------------------------
// Output scaling: right-shift by CIC_SHIFT bits, saturate to IQ_WIDTH
// -------------------------------------------------------------------------
wire signed [CIC_ACC-1:0] out_i_sh_w = intg_i5 >>> CIC_SHIFT;
wire signed [CIC_ACC-1:0] out_q_sh_w = intg_q5 >>> CIC_SHIFT;

// Overflow: all bits [CIC_ACC-1 : IQ_WIDTH-1] must equal the sign bit
wire i_ovf_w = (|out_i_sh_w[CIC_ACC-1:IQ_WIDTH-1]) &&
               (~&out_i_sh_w[CIC_ACC-1:IQ_WIDTH-1]);
wire q_ovf_w = (|out_q_sh_w[CIC_ACC-1:IQ_WIDTH-1]) &&
               (~&out_q_sh_w[CIC_ACC-1:IQ_WIDTH-1]);

wire signed [IQ_WIDTH-1:0] out_i_sat_w =
    i_ovf_w ? (out_i_sh_w[CIC_ACC-1] ? {1'b1,{(IQ_WIDTH-1){1'b0}}}
                                      : {1'b0,{(IQ_WIDTH-1){1'b1}}})
            : out_i_sh_w[IQ_WIDTH-1:0];
wire signed [IQ_WIDTH-1:0] out_q_sat_w =
    q_ovf_w ? (out_q_sh_w[CIC_ACC-1] ? {1'b1,{(IQ_WIDTH-1){1'b0}}}
                                      : {1'b0,{(IQ_WIDTH-1){1'b1}}})
            : out_q_sh_w[IQ_WIDTH-1:0];

// -------------------------------------------------------------------------
// R1: intg_en delayed 1 cycle → output valid strobe (pipeline depth = 1)
// -------------------------------------------------------------------------
reg intg_en_d1;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) intg_en_d1 <= 1'b0;
    else             intg_en_d1 <= intg_en_w;
end

// R1: tx_i_lvds
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) tx_i_lvds <= {IQ_WIDTH{1'b0}};
    else if (intg_en_d1) tx_i_lvds <= out_i_sat_w;
end

// R1: tx_q_lvds
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) tx_q_lvds <= {IQ_WIDTH{1'b0}};
    else if (intg_en_d1) tx_q_lvds <= out_q_sat_w;
end

// R1: tx_valid_lvds — 1-cycle pulse per output IQ pair
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds) tx_valid_lvds <= 1'b0;
    else             tx_valid_lvds <= intg_en_d1;
end

endmodule
`default_nettype wire
