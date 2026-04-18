// =============================================================================
// Module:      tetra_rx_frontend
// Project:     tetra-zynq-phy
// File:        rtl/rx/tetra_rx_frontend.v
//
// Description: TETRA RX Frontend — CDC + CIC Decimation + RRC Matched Filter.
//
//   Signal path:
//     AD9361 LVDS (clk_lvds) → XPM Async FIFO → clk_sys domain
//     → 5th-order CIC Decimator (R=64, input 4.608 MHz → output 72 kHz)
//     → 33-tap RRC Matched Filter (α=0.35, 4 samples/symbol)
//     → out_valid_sys pulse at 72 kHz for downstream timing recovery
//
//   Clock domain: all processing in clk_sys (100 MHz); samples marked by
//   single-cycle valid strobes (no separate slow clocks needed).
//
//   CIC design:
//     Order N=5, Decimation R=64, Differential delay M=1.
//     Internal bit width = 16 + 5×ceil(log2(64)) = 16 + 30 = 46 bits.
//     Gain = R^N = 64^5 = 2^30; normalised by CIC_TRUNC=30, then amplified
//     by 2^CIC_GAIN_SHF=64 (CIC_GAIN_SHF=6) with saturation to IQ_WIDTH.
//     Effective output range: input × 64, clamped to ±32767.
//     Required because Gardner TED gain ∝ amplitude²; ADC amplitude (~512
//     with slow_attack AGC) gives zero loop gain without this boost.
//     Combs run combinatorially (5 subtractions in one clock cycle at 100 MHz;
//     worst-case path < 3 ns, easily meets timing).
//
//   RRC filter design:
//     33 taps, α=0.35, 4 samples/symbol (72 kHz / 18 ksymbol/s).
//     Coefficients: Q14 signed, energy-normalised (run gen_rx_frontend_vectors.py
//     to regenerate exact values if needed).
//     Implementation: sequential MAC — 1 multiplier, 33 cycles per output sample.
//     33 cycles << 64-cycle inter-sample spacing → always completes before next sample.
//     Shift register: flat 528-bit bus (33 × 16-bit, no Verilog arrays, per R3).
//
// Pipeline latency (clk_sys cycles):
//   FIFO read    : 2 (rd_en → dout, FIFO_READ_LATENCY=1 + 1 register)
//   CIC integrators: 0 (combinatorial advance; output captured at strobe)
//   CIC combs    : 1 (output registered after comb chain)
//   RRC MAC      : 33 (sequential, starts cycle after CIC output valid)
//   Total        : ~36 cycles from ADC sample to RRC output
//   Group delay  : (RRC_TAPS-1)/2 = 16 output samples = 16 × 64 = 1024 ADC samples
//
// Ports:
//   clk_sys          i  1      100 MHz system clock
//   rst_n_sys        i  1      Active-low sync reset (from tetra_clk_reset)
//   clk_lvds         i  1      AD9361 DATA_CLK (from tetra_ad9361_interface)
//   rst_n_lvds       i  1      Active-low reset, clk_lvds domain
//   rx_i_lvds        i 16      RX I sample, signed, clk_lvds domain
//   rx_q_lvds        i 16      RX Q sample, signed, clk_lvds domain
//   rx_valid_lvds    i  1      One-cycle valid pulse per IQ pair (clk_lvds)
//   i_out_sys        o 16      Filtered I sample, signed, clk_sys domain
//   q_out_sys        o 16      Filtered Q sample, signed, clk_sys domain
//   out_valid_sys    o  1      One-cycle valid pulse per output sample
//
// Resource estimate (Vivado 2022.2, xc7z020):
//   LUT  : ~120   (CIC integrators + comb mux, RRC coeff case, address decode)
//   FF   : ~280   (CIC 10×46-bit regs, RRC 2×528-bit shift regs, FSM regs)
//   DSP48: 1      (RRC MAC multiplier, inferred)
//   BRAM : 0      (XPM FIFO ≤16 words → LUTRAM)
//
// Ref: Harris "On the use of CIC filters" (1977)
//      Proakis & Salehi "Communication Systems Engineering" §9.3 (RRC)
//      ETSI EN 300 392-2 §9.5 (TETRA pulse shaping, α=0.35)
//      Xilinx UG974 "Vivado Design Suite" (xpm_fifo_async)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_rx_frontend #(
    parameter IQ_WIDTH       = 16,  // I/Q sample width (in and out)
    parameter CIC_ORDER      = 5,   // CIC filter order (stages)
    parameter CIC_R          = 64,  // Decimation ratio; ADC_RATE/CIC_R = symbol_rate × SPS
    //  4,608,000 / 64 = 72,000 Hz = 18 kHz × 4 samples/symbol
    parameter CIC_M          = 1,   // CIC differential delay (standard = 1)
    parameter RRC_TAPS       = 33,  // RRC matched filter length (odd, symmetric)
    parameter RRC_ACC_SHIFT  = 14   // Right-shift after MAC to remove Q14 fractional bits
)(
    // ------------------------------------------------------------------
    // System clock domain
    // ------------------------------------------------------------------
    input  wire                         clk_sys,
    input  wire                         rst_n_sys,

    // ------------------------------------------------------------------
    // LVDS clock domain — from axi_ad9361 IP (via tetra_ad9361_axis_adapter)
    // ------------------------------------------------------------------
    input  wire                         clk_lvds,
    input  wire                         rst_n_lvds,
    input  wire signed [IQ_WIDTH-1:0]   rx_i_lvds,
    input  wire signed [IQ_WIDTH-1:0]   rx_q_lvds,
    input  wire                         rx_valid_lvds,

    // ------------------------------------------------------------------
    // System clock domain outputs — to tetra_timing_recovery
    // One out_valid_sys pulse per sample at 72 kHz (= CIC output rate)
    // ------------------------------------------------------------------
    output reg  signed [IQ_WIDTH-1:0]   i_out_sys,
    output reg  signed [IQ_WIDTH-1:0]   q_out_sys,
    output reg                          out_valid_sys,

    // ------------------------------------------------------------------
    // Digital loopback control (clk_sys domain)
    // When HIGH, bypasses CIC ×64 gain (CIC_GAIN_SHF).  Loopback signals
    // are already full-scale; the gain would clip the entire waveform and
    // destroy the raised-cosine pulse shape needed by timing recovery.
    // ------------------------------------------------------------------
    input  wire                         loopback_en_sys
);

// =============================================================================
// Localparams
// =============================================================================

// CIC internal bit width: IQ_WIDTH + N * ceil(log2(R * M))
// For R=64, log2(64)=6; 5*6=30; total = 16+30 = 46 bits
localparam CIC_BITS  = IQ_WIDTH + CIC_ORDER * 6;  // = 46

// CIC output truncation: discard lower (CIC_BITS - IQ_WIDTH) bits
// This removes the CIC DC gain of R^N = 2^30
localparam CIC_TRUNC = CIC_BITS - IQ_WIDTH;        // = 30

// CIC output gain shift: take CIC_GAIN_SHF extra LSBs beyond the normalised
// output, then saturate to IQ_WIDTH.  Gain = 2^CIC_GAIN_SHF.
//
// Why this is needed: the Gardner TED gain scales as signal_amplitude².
// Digital loopback feeds pi4dqpsk_mod output (~32767) directly into the RX
// CIC; the loop gain is large and the TED converges.  In RF mode the AD9361
// ADC operates at ~512 LSB (slow_attack AGC, ~-12 dBFS target), giving
// TED ≈ 4 and kp_term = 4 >> KP_SHIFT = 0 — the loop is dead.
// CIC_GAIN_SHF=6 multiplies amplitude 512 → 32768, matching the digital-
// loopback operating point.  For digital loopback (amplitude 32767), the
// 64× product saturates back to 32767, so existing behaviour is unchanged.
localparam CIC_GAIN_SHF  = 6;
localparam CIC_WIDE_BITS = IQ_WIDTH + CIC_GAIN_SHF;  // 22
localparam CIC_OUT_LOW   = CIC_TRUNC - CIC_GAIN_SHF; // 24 (new LSB of output slice)

// Decimation counter width: ceil(log2(CIC_R)) = 6 bits for R=64
localparam DCNT_BITS = 6;

// RRC MAC accumulator width: IQ_WIDTH + RRC_COEFF_WIDTH + ceil(log2(RRC_TAPS))
// = 16 + 16 + 6 = 38 bits (saturates 33 × 2^30 products)
localparam RRC_COEFF_WIDTH = 16;
localparam RRC_ACC_WIDTH   = 38;

// RRC flat shift register: RRC_TAPS * IQ_WIDTH = 33 * 16 = 528 bits
localparam RRC_SR_WIDTH = RRC_TAPS * IQ_WIDTH;    // = 528

// MAC counter width: ceil(log2(RRC_TAPS)) = 6 bits for 33 taps
localparam MAC_CNT_BITS = 6;

// RRC MAC FSM states (one always-block for state register, R5)
localparam S_IDLE = 1'b0;
localparam S_MAC  = 1'b1;

// ---------------------------------------------------------------------------
// RRC coefficients — Q14 signed, α=0.35, 33 taps, 4 samples/symbol
// Generated by tb/vectors/gen_rx_frontend_vectors.py
// h[k] = h[32-k] (symmetric filter)
// ---------------------------------------------------------------------------
localparam signed [15:0] RRC_H00 = 16'sh0011;  // +17   float: +0.001021
localparam signed [15:0] RRC_H01 = 16'sh006D;  // +109  float: +0.006662
localparam signed [15:0] RRC_H02 = 16'sh004E;  // +78   float: +0.004786
localparam signed [15:0] RRC_H03 = 16'shFFB2;  // -78   float: -0.004776
localparam signed [15:0] RRC_H04 = 16'shFF2F;  // -209  float: -0.012733
localparam signed [15:0] RRC_H05 = 16'shFF87;  // -121  float: -0.007377
localparam signed [15:0] RRC_H06 = 16'sh00D2;  // +210  float: +0.012813
localparam signed [15:0] RRC_H07 = 16'sh0217;  // +535  float: +0.032663
localparam signed [15:0] RRC_H08 = 16'sh01D4;  // +468  float: +0.028562
localparam signed [15:0] RRC_H09 = 16'shFF4B;  // -181  float: -0.011048
localparam signed [15:0] RRC_H10 = 16'shFBAC;  // -1108 float: -0.067616
localparam signed [15:0] RRC_H11 = 16'shF9F7;  // -1545 float: -0.094322
localparam signed [15:0] RRC_H12 = 16'shFD4A;  // -694  float: -0.042361
localparam signed [15:0] RRC_H13 = 16'sh06A0;  // +1696 float: +0.103526
localparam signed [15:0] RRC_H14 = 16'sh1373;  // +4979 float: +0.303926
localparam signed [15:0] RRC_H15 = 16'sh1EA4;  // +7844 float: +0.478619
localparam signed [15:0] RRC_H16 = 16'sh2312;  // +8978 float: +0.547929
localparam signed [15:0] RRC_H17 = 16'sh1EA4;  // +7844 float: +0.478619
localparam signed [15:0] RRC_H18 = 16'sh1373;  // +4979 float: +0.303926
localparam signed [15:0] RRC_H19 = 16'sh06A0;  // +1696 float: +0.103526
localparam signed [15:0] RRC_H20 = 16'shFD4A;  // -694  float: -0.042361
localparam signed [15:0] RRC_H21 = 16'shF9F7;  // -1545 float: -0.094322
localparam signed [15:0] RRC_H22 = 16'shFBAC;  // -1108 float: -0.067616
localparam signed [15:0] RRC_H23 = 16'shFF4B;  // -181  float: -0.011048
localparam signed [15:0] RRC_H24 = 16'sh01D4;  // +468  float: +0.028562
localparam signed [15:0] RRC_H25 = 16'sh0217;  // +535  float: +0.032663
localparam signed [15:0] RRC_H26 = 16'sh00D2;  // +210  float: +0.012813
localparam signed [15:0] RRC_H27 = 16'shFF87;  // -121  float: -0.007377
localparam signed [15:0] RRC_H28 = 16'shFF2F;  // -209  float: -0.012733
localparam signed [15:0] RRC_H29 = 16'shFFB2;  // -78   float: -0.004776
localparam signed [15:0] RRC_H30 = 16'sh004E;  // +78   float: +0.004786
localparam signed [15:0] RRC_H31 = 16'sh006D;  // +109  float: +0.006662
localparam signed [15:0] RRC_H32 = 16'sh0011;  // +17   float: +0.001021

// =============================================================================
// Section 1: XPM Async FIFO — CDC clk_lvds → clk_sys
// =============================================================================
// Packs I and Q into one 32-bit write word: din[31:16]=I, din[15:0]=Q.
// FIFO depth 16: at 4.608 MHz input and 100 MHz clk_sys the FIFO is nearly
// empty; depth-16 handles brief clock-domain burst jitter.
// READ_LATENCY=1: dout stable 1 cycle after rd_en.

wire [31:0]  fifo_din;
wire         fifo_wr_en;
wire [31:0]  fifo_dout;
wire         fifo_empty_sys;
wire         fifo_rd_en_sys;
wire         fifo_wr_rst_busy;
wire         fifo_rd_rst_busy;

assign fifo_din   = {rx_i_lvds, rx_q_lvds};
assign fifo_wr_en = rx_valid_lvds;

// rd_en: pull one word per cycle whenever FIFO is not empty AND we are not
// currently processing (to pace the CIC at the correct input rate).
// Since the CIC can accept a new sample every cycle, we drain as fast as
// available.
assign fifo_rd_en_sys = ~fifo_empty_sys & ~fifo_rd_rst_busy;

xpm_fifo_async #(
    .FIFO_WRITE_DEPTH   (16),    // 16 entries; uses LUTRAM (no BRAM18k)
    .WRITE_DATA_WIDTH   (32),
    .READ_DATA_WIDTH    (32),
    .READ_MODE          ("std"),
    .FIFO_READ_LATENCY  (1),
    .CDC_SYNC_STAGES    (2),
    .FULL_RESET_VALUE   (0),
    .ECC_MODE           ("no_ecc"),
    .RELATED_CLOCKS     (0),
    .USE_ADV_FEATURES   ("0000"), // no side-band signals
    .DOUT_RESET_VALUE   ("0"),
    .WAKEUP_TIME        (0),
    .PROG_FULL_THRESH   (10),
    .PROG_EMPTY_THRESH  (3)
) u_iq_cdc_fifo (
    // Write side (clk_lvds domain)
    .wr_clk        (clk_lvds),
    .rst           (~rst_n_lvds),
    .wr_en         (fifo_wr_en),
    .din           (fifo_din),
    .full          (/* unused — overflow handled by design rate matching */),
    .wr_rst_busy   (fifo_wr_rst_busy),
    .prog_full     (),
    .overflow      (),
    .wr_data_count (),
    .almost_full   (),

    // Read side (clk_sys domain)
    .rd_clk        (clk_sys),
    .rd_en         (fifo_rd_en_sys),
    .dout          (fifo_dout),
    .empty         (fifo_empty_sys),
    .rd_rst_busy   (fifo_rd_rst_busy),
    .prog_empty    (),
    .underflow     (),
    .rd_data_count (),
    .almost_empty  (),

    // Unused ECC / injection ports
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       (),
    .sleep         (1'b0)
);

// =============================================================================
// Section 2: FIFO output registration — clk_sys domain
// =============================================================================
// rd_en is registered one cycle before dout is valid (FIFO_READ_LATENCY=1).
// Delay rd_en by 1 to produce in_valid_sys aligned with stable dout.

wire                        fifo_dout_valid_raw;

// One-cycle delay of rd_en to align with FIFO's 1-cycle read latency
reg                         rd_en_d1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) rd_en_d1_sys <= 1'b0;
    else            rd_en_d1_sys <= fifo_rd_en_sys & ~fifo_rd_rst_busy;
end

assign fifo_dout_valid_raw = rd_en_d1_sys;

// Register FIFO output to improve timing
reg signed [IQ_WIDTH-1:0]   i_fifo_sys;
reg signed [IQ_WIDTH-1:0]   q_fifo_sys;
reg                         in_valid_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_fifo_sys <= {IQ_WIDTH{1'b0}};
    else if (fifo_dout_valid_raw) i_fifo_sys <= $signed(fifo_dout[31:16]);
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_fifo_sys <= {IQ_WIDTH{1'b0}};
    else if (fifo_dout_valid_raw) q_fifo_sys <= $signed(fifo_dout[15:0]);
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) in_valid_sys <= 1'b0;
    else            in_valid_sys <= fifo_dout_valid_raw;
end

// =============================================================================
// Section 3: CIC Decimator — 5th order, R=64, M=1
// =============================================================================
// Pipeline Stage CIC-0: sign-extend input to CIC_BITS

wire signed [CIC_BITS-1:0] i_ext_sys;
wire signed [CIC_BITS-1:0] q_ext_sys;

assign i_ext_sys = {{(CIC_BITS-IQ_WIDTH){i_fifo_sys[IQ_WIDTH-1]}}, i_fifo_sys};
assign q_ext_sys = {{(CIC_BITS-IQ_WIDTH){q_fifo_sys[IQ_WIDTH-1]}}, q_fifo_sys};

// ---------------------------------------------------------------------------
// CIC Integrators (R1: one always-block per register)
// All 5 stages run at input rate (gated by in_valid_sys).
// ---------------------------------------------------------------------------

// Stage 1 — I
reg signed [CIC_BITS-1:0] i_int1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_int1_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) i_int1_sys <= i_int1_sys + i_ext_sys;
end

// Stage 1 — Q
reg signed [CIC_BITS-1:0] q_int1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_int1_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) q_int1_sys <= q_int1_sys + q_ext_sys;
end

// Stage 2 — I
reg signed [CIC_BITS-1:0] i_int2_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_int2_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) i_int2_sys <= i_int2_sys + i_int1_sys;
end

// Stage 2 — Q
reg signed [CIC_BITS-1:0] q_int2_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_int2_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) q_int2_sys <= q_int2_sys + q_int1_sys;
end

// Stage 3 — I
reg signed [CIC_BITS-1:0] i_int3_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_int3_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) i_int3_sys <= i_int3_sys + i_int2_sys;
end

// Stage 3 — Q
reg signed [CIC_BITS-1:0] q_int3_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_int3_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) q_int3_sys <= q_int3_sys + q_int2_sys;
end

// Stage 4 — I
reg signed [CIC_BITS-1:0] i_int4_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_int4_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) i_int4_sys <= i_int4_sys + i_int3_sys;
end

// Stage 4 — Q
reg signed [CIC_BITS-1:0] q_int4_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_int4_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) q_int4_sys <= q_int4_sys + q_int3_sys;
end

// Stage 5 — I
reg signed [CIC_BITS-1:0] i_int5_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_int5_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) i_int5_sys <= i_int5_sys + i_int4_sys;
end

// Stage 5 — Q
reg signed [CIC_BITS-1:0] q_int5_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_int5_sys <= {CIC_BITS{1'b0}};
    else if (in_valid_sys) q_int5_sys <= q_int5_sys + q_int4_sys;
end

// ---------------------------------------------------------------------------
// CIC Decimation Counter and Strobe
// cic_strobe_sys: one-cycle pulse every CIC_R input samples.
// ---------------------------------------------------------------------------

reg [DCNT_BITS-1:0] dec_cnt_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        dec_cnt_sys <= {DCNT_BITS{1'b0}};
    else if (in_valid_sys)
        dec_cnt_sys <= (dec_cnt_sys == CIC_R - 1) ? {DCNT_BITS{1'b0}}
                                                   : dec_cnt_sys + 1'b1;
end

reg cic_strobe_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        cic_strobe_sys <= 1'b0;
    else
        cic_strobe_sys <= in_valid_sys & (dec_cnt_sys == CIC_R - 1);
end

// ---------------------------------------------------------------------------
// CIC Comb Stages (5 stages, combinatorial chain, delay regs update at strobe)
// Each stage: output = input - z^{-1}(input)
// ---------------------------------------------------------------------------

// --- Comb Stage 1 — I ---
reg  signed [CIC_BITS-1:0] i_comb1_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_comb1_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) i_comb1_z1_sys <= i_int5_sys;
end
wire signed [CIC_BITS-1:0] i_comb1_sys = i_int5_sys - i_comb1_z1_sys;

// --- Comb Stage 1 — Q ---
reg  signed [CIC_BITS-1:0] q_comb1_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_comb1_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) q_comb1_z1_sys <= q_int5_sys;
end
wire signed [CIC_BITS-1:0] q_comb1_sys = q_int5_sys - q_comb1_z1_sys;

// --- Comb Stage 2 — I ---
reg  signed [CIC_BITS-1:0] i_comb2_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_comb2_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) i_comb2_z1_sys <= i_comb1_sys;
end
wire signed [CIC_BITS-1:0] i_comb2_sys = i_comb1_sys - i_comb2_z1_sys;

// --- Comb Stage 2 — Q ---
reg  signed [CIC_BITS-1:0] q_comb2_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_comb2_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) q_comb2_z1_sys <= q_comb1_sys;
end
wire signed [CIC_BITS-1:0] q_comb2_sys = q_comb1_sys - q_comb2_z1_sys;

// --- Comb Stage 3 — I ---
reg  signed [CIC_BITS-1:0] i_comb3_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_comb3_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) i_comb3_z1_sys <= i_comb2_sys;
end
wire signed [CIC_BITS-1:0] i_comb3_sys = i_comb2_sys - i_comb3_z1_sys;

// --- Comb Stage 3 — Q ---
reg  signed [CIC_BITS-1:0] q_comb3_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_comb3_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) q_comb3_z1_sys <= q_comb2_sys;
end
wire signed [CIC_BITS-1:0] q_comb3_sys = q_comb2_sys - q_comb3_z1_sys;

// --- Comb Stage 4 — I ---
reg  signed [CIC_BITS-1:0] i_comb4_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_comb4_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) i_comb4_z1_sys <= i_comb3_sys;
end
wire signed [CIC_BITS-1:0] i_comb4_sys = i_comb3_sys - i_comb4_z1_sys;

// --- Comb Stage 4 — Q ---
reg  signed [CIC_BITS-1:0] q_comb4_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_comb4_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) q_comb4_z1_sys <= q_comb3_sys;
end
wire signed [CIC_BITS-1:0] q_comb4_sys = q_comb3_sys - q_comb4_z1_sys;

// --- Comb Stage 5 — I ---
reg  signed [CIC_BITS-1:0] i_comb5_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_comb5_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) i_comb5_z1_sys <= i_comb4_sys;
end
wire signed [CIC_BITS-1:0] i_comb5_sys = i_comb4_sys - i_comb5_z1_sys;

// --- Comb Stage 5 — Q ---
reg  signed [CIC_BITS-1:0] q_comb5_z1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_comb5_z1_sys <= {CIC_BITS{1'b0}};
    else if (cic_strobe_sys) q_comb5_z1_sys <= q_comb4_sys;
end
wire signed [CIC_BITS-1:0] q_comb5_sys = q_comb4_sys - q_comb5_z1_sys;

// ---------------------------------------------------------------------------
// CIC Output Register — extract amplified slice, saturate, then register.
// Takes bits [CIC_BITS-1 : CIC_OUT_LOW] = bits [45:24] (22 bits = IQ_WIDTH+6)
// instead of the normalised [45:30], providing 2^6=64× gain before saturation.
// One cycle after cic_strobe, cic_valid_sys goes high.
// ---------------------------------------------------------------------------

// Wide (pre-saturation) CIC output — CIC_WIDE_BITS = 22 bits
// RF mode:      bits [45:24] → 22-bit slice with ×64 gain, then saturate to 16-bit
// Loopback mode: bits [45:30] → 16-bit slice, no extra gain (signal already full-scale)
wire signed [CIC_WIDE_BITS-1:0] i_cic_wide_sys = i_comb5_sys[CIC_BITS-1 : CIC_OUT_LOW];
wire signed [CIC_WIDE_BITS-1:0] q_cic_wide_sys = q_comb5_sys[CIC_BITS-1 : CIC_OUT_LOW];

// Unity-gain path: extract normalised [45:30] = 16 bits, no saturation needed
wire signed [IQ_WIDTH-1:0] i_cic_unity_sys = i_comb5_sys[CIC_BITS-1 : CIC_TRUNC];
wire signed [IQ_WIDTH-1:0] q_cic_unity_sys = q_comb5_sys[CIC_BITS-1 : CIC_TRUNC];

// Saturation (gained path only): overflow iff the CIC_GAIN_SHF guard bits
// differ from the sign bit.
// Guard bits are [CIC_WIDE_BITS-2 : IQ_WIDTH-1] = [20:15] — must all equal bit [21].
wire i_pos_ovf = (!i_cic_wide_sys[CIC_WIDE_BITS-1]) && (|i_cic_wide_sys[CIC_WIDE_BITS-2:IQ_WIDTH-1]);
wire i_neg_ovf =   i_cic_wide_sys[CIC_WIDE_BITS-1]  && (~&i_cic_wide_sys[CIC_WIDE_BITS-2:IQ_WIDTH-1]);
wire q_pos_ovf = (!q_cic_wide_sys[CIC_WIDE_BITS-1]) && (|q_cic_wide_sys[CIC_WIDE_BITS-2:IQ_WIDTH-1]);
wire q_neg_ovf =   q_cic_wide_sys[CIC_WIDE_BITS-1]  && (~&q_cic_wide_sys[CIC_WIDE_BITS-2:IQ_WIDTH-1]);

wire signed [IQ_WIDTH-1:0] i_cic_gained =
    i_pos_ovf ? {1'b0, {(IQ_WIDTH-1){1'b1}}} :   // +32767
    i_neg_ovf ? {1'b1, {(IQ_WIDTH-1){1'b0}}} :   // -32768
                i_cic_wide_sys[IQ_WIDTH-1:0];

wire signed [IQ_WIDTH-1:0] q_cic_gained =
    q_pos_ovf ? {1'b0, {(IQ_WIDTH-1){1'b1}}} :
    q_neg_ovf ? {1'b1, {(IQ_WIDTH-1){1'b0}}} :
                q_cic_wide_sys[IQ_WIDTH-1:0];

// Mux: loopback → unity gain; RF → ×64 gain with saturation
wire signed [IQ_WIDTH-1:0] i_cic_sat = loopback_en_sys ? i_cic_unity_sys : i_cic_gained;
wire signed [IQ_WIDTH-1:0] q_cic_sat = loopback_en_sys ? q_cic_unity_sys : q_cic_gained;

// Pipeline Stage CIC-1: register CIC output
reg signed [IQ_WIDTH-1:0] i_cic_out_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        i_cic_out_sys <= {IQ_WIDTH{1'b0}};
    else if (cic_strobe_sys)
        i_cic_out_sys <= i_cic_sat;
end

reg signed [IQ_WIDTH-1:0] q_cic_out_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        q_cic_out_sys <= {IQ_WIDTH{1'b0}};
    else if (cic_strobe_sys)
        q_cic_out_sys <= q_cic_sat;
end

// Valid flag: 1 cycle after cic_strobe (aligned with cic_out registers)
reg cic_valid_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) cic_valid_sys <= 1'b0;
    else            cic_valid_sys <= cic_strobe_sys;
end

// =============================================================================
// Section 4: RRC Matched Filter — 33-tap sequential MAC
// =============================================================================
// Shift register: flat 528-bit bus.  Newest sample at SR[15:0] (bit 0 end).
// Shift direction: on cic_valid_sys, shift left by IQ_WIDTH and insert new sample.
//   SR[527:16] ← SR[511:0]  (shift out oldest, shift in new at bottom)
//   Wait, more precisely: SR[RRC_SR_WIDTH-1:IQ_WIDTH] ← SR[RRC_SR_WIDTH-1-IQ_WIDTH:0]
//   and SR[IQ_WIDTH-1:0] ← new_sample
// Tap addressing: tap k = SR[k*IQ_WIDTH +: IQ_WIDTH]
//   k=0 → oldest sample (SR[527:512])
//   k=32 → newest sample (SR[15:0])   ← enters at bottom
// Wait: if we shift LEFT (towards MSB), then NEW sample enters at bottom (SR[15:0]).
// BUT: After shift, SR[15:0] = new sample, SR[31:16] = previous newest, etc.
// Tap k maps to the k-th sample from newest:
//   tap 0 = SR[15:0]       = newest (most recent)
//   tap 32 = SR[527:512]   = oldest
// The RRC coefficient order follows h[0]..h[32] = oldest..newest tap.
// To correlate correctly: tap 0 corresponds to h[0], tap 32 to h[32].
// Since h is symmetric (h[0]=h[32]=17), the result is the same.
//
// R3 compliance: flat bus, NOT reg[IQ_WIDTH-1:0] sr[0:RRC_TAPS-1]

reg [RRC_SR_WIDTH-1:0] i_shift_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        i_shift_sys <= {RRC_SR_WIDTH{1'b0}};
    else if (cic_valid_sys)
        // Shift left: discard oldest tap (top IQ_WIDTH bits), insert new at bottom
        i_shift_sys <= {i_shift_sys[RRC_SR_WIDTH-IQ_WIDTH-1:0], i_cic_out_sys};
end

reg [RRC_SR_WIDTH-1:0] q_shift_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        q_shift_sys <= {RRC_SR_WIDTH{1'b0}};
    else if (cic_valid_sys)
        q_shift_sys <= {q_shift_sys[RRC_SR_WIDTH-IQ_WIDTH-1:0], q_cic_out_sys};
end

// ---------------------------------------------------------------------------
// RRC MAC FSM (R5: 3 always-blocks — state register, next-state, outputs)
// Pipeline Stage RRC-0 .. RRC-32: MAC accumulation
// ---------------------------------------------------------------------------

// FSM state register
reg                      mac_state_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) mac_state_sys <= S_IDLE;
    else            mac_state_sys <= mac_next_sys;
end

// MAC tap counter (0 .. RRC_TAPS-1)
reg [MAC_CNT_BITS-1:0] mac_cnt_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        mac_cnt_sys <= {MAC_CNT_BITS{1'b0}};
    else if (mac_state_sys == S_MAC)
        mac_cnt_sys <= mac_cnt_sys + 1'b1;
    else
        mac_cnt_sys <= {MAC_CNT_BITS{1'b0}};
end

// Next-state logic (combinatorial, R5)
reg mac_next_sys;
always @(*) begin
    mac_next_sys = mac_state_sys;  // default: hold
    case (mac_state_sys)
        S_IDLE: if (cic_valid_sys) mac_next_sys = S_MAC;
        S_MAC:  if (mac_cnt_sys == RRC_TAPS - 1) mac_next_sys = S_IDLE;
        default: mac_next_sys = S_IDLE;
    endcase
end

// ---------------------------------------------------------------------------
// Coefficient mux (combinatorial) — select h[mac_cnt] from localparams
// Using a case statement (no array access, per R3).
// ---------------------------------------------------------------------------
reg signed [RRC_COEFF_WIDTH-1:0] coeff_sys;
always @(*) begin
    case (mac_cnt_sys)
        6'd0:  coeff_sys = RRC_H00;
        6'd1:  coeff_sys = RRC_H01;
        6'd2:  coeff_sys = RRC_H02;
        6'd3:  coeff_sys = RRC_H03;
        6'd4:  coeff_sys = RRC_H04;
        6'd5:  coeff_sys = RRC_H05;
        6'd6:  coeff_sys = RRC_H06;
        6'd7:  coeff_sys = RRC_H07;
        6'd8:  coeff_sys = RRC_H08;
        6'd9:  coeff_sys = RRC_H09;
        6'd10: coeff_sys = RRC_H10;
        6'd11: coeff_sys = RRC_H11;
        6'd12: coeff_sys = RRC_H12;
        6'd13: coeff_sys = RRC_H13;
        6'd14: coeff_sys = RRC_H14;
        6'd15: coeff_sys = RRC_H15;
        6'd16: coeff_sys = RRC_H16;
        6'd17: coeff_sys = RRC_H17;
        6'd18: coeff_sys = RRC_H18;
        6'd19: coeff_sys = RRC_H19;
        6'd20: coeff_sys = RRC_H20;
        6'd21: coeff_sys = RRC_H21;
        6'd22: coeff_sys = RRC_H22;
        6'd23: coeff_sys = RRC_H23;
        6'd24: coeff_sys = RRC_H24;
        6'd25: coeff_sys = RRC_H25;
        6'd26: coeff_sys = RRC_H26;
        6'd27: coeff_sys = RRC_H27;
        6'd28: coeff_sys = RRC_H28;
        6'd29: coeff_sys = RRC_H29;
        6'd30: coeff_sys = RRC_H30;
        6'd31: coeff_sys = RRC_H31;
        6'd32: coeff_sys = RRC_H32;
        default: coeff_sys = {RRC_COEFF_WIDTH{1'b0}};
    endcase
end

// ---------------------------------------------------------------------------
// Tap data mux — indexed part-select on flat shift register (R3 compliant).
// tap k = i_shift_sys[k * IQ_WIDTH +: IQ_WIDTH], k = mac_cnt_sys.
// Vivado synthesises this as a wide read multiplexer.
// Tap 0 = oldest sample; tap 32 = newest sample.
// ---------------------------------------------------------------------------
wire signed [IQ_WIDTH-1:0] i_tap_sys;
wire signed [IQ_WIDTH-1:0] q_tap_sys;

assign i_tap_sys = $signed(i_shift_sys[mac_cnt_sys * IQ_WIDTH +: IQ_WIDTH]);
assign q_tap_sys = $signed(q_shift_sys[mac_cnt_sys * IQ_WIDTH +: IQ_WIDTH]);

// ---------------------------------------------------------------------------
// MAC Accumulators
// Pipeline Stage RRC-1: multiply
// Pipeline Stage RRC-2..34: accumulate (33 cycles)
// acc width: RRC_ACC_WIDTH=38 bits handles 33 × 16-bit × 16-bit products without overflow.
// ---------------------------------------------------------------------------

// 32-bit signed multiply (synthesises to DSP48E1)
wire signed [31:0] i_product_sys = i_tap_sys * coeff_sys;
wire signed [31:0] q_product_sys = q_tap_sys * coeff_sys;

// I accumulator — clears when entering S_MAC (mac_cnt==0 first valid cycle)
reg signed [RRC_ACC_WIDTH-1:0] i_acc_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        i_acc_sys <= {RRC_ACC_WIDTH{1'b0}};
    else if (mac_state_sys == S_MAC) begin
        if (mac_cnt_sys == {MAC_CNT_BITS{1'b0}})
            i_acc_sys <= {{(RRC_ACC_WIDTH-32){i_product_sys[31]}}, i_product_sys};
        else
            i_acc_sys <= i_acc_sys + {{(RRC_ACC_WIDTH-32){i_product_sys[31]}}, i_product_sys};
    end
end

// Q accumulator
reg signed [RRC_ACC_WIDTH-1:0] q_acc_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        q_acc_sys <= {RRC_ACC_WIDTH{1'b0}};
    else if (mac_state_sys == S_MAC) begin
        if (mac_cnt_sys == {MAC_CNT_BITS{1'b0}})
            q_acc_sys <= {{(RRC_ACC_WIDTH-32){q_product_sys[31]}}, q_product_sys};
        else
            q_acc_sys <= q_acc_sys + {{(RRC_ACC_WIDTH-32){q_product_sys[31]}}, q_product_sys};
    end
end

// ---------------------------------------------------------------------------
// Section 5: Output — truncate accumulator to IQ_WIDTH with saturation
// Pipeline Stage RRC-35: output register
// Acc is Q14: shift right by RRC_ACC_SHIFT=14 to get integer part.
// After shift: acc[37:14] = 24-bit result.  Take [23:8] for 16-bit output.
// Saturate if the top 8 bits are not all equal (overflow guard).
// ---------------------------------------------------------------------------

// Done flag: last MAC cycle (mac_cnt = RRC_TAPS-1 while still in S_MAC).
// Delayed by 1 cycle so that the accumulator has incorporated the final
// product (tap 32 × H32) before the output is latched.
wire mac_done_raw_sys = (mac_state_sys == S_MAC) && (mac_cnt_sys == RRC_TAPS - 1);

reg mac_done_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) mac_done_sys <= 1'b0;
    else            mac_done_sys <= mac_done_raw_sys;
end

// Shifted accumulator output (combinatorial)
wire signed [RRC_ACC_WIDTH-1:0] i_acc_shifted_sys = i_acc_sys >>> RRC_ACC_SHIFT;
wire signed [RRC_ACC_WIDTH-1:0] q_acc_shifted_sys = q_acc_sys >>> RRC_ACC_SHIFT;

// Saturation helpers: top 9 bits should all be equal (sign extension expected)
wire i_overflow_sys = ~(&i_acc_shifted_sys[RRC_ACC_WIDTH-1:IQ_WIDTH-1]) &&
                      ~(|i_acc_shifted_sys[RRC_ACC_WIDTH-1:IQ_WIDTH-1] == 1'b0);
wire q_overflow_sys = ~(&q_acc_shifted_sys[RRC_ACC_WIDTH-1:IQ_WIDTH-1]) &&
                      ~(|q_acc_shifted_sys[RRC_ACC_WIDTH-1:IQ_WIDTH-1] == 1'b0);

wire signed [IQ_WIDTH-1:0] i_sat_sys =
    i_overflow_sys ? (i_acc_shifted_sys[RRC_ACC_WIDTH-1] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}  // min
                                                          : {1'b0, {(IQ_WIDTH-1){1'b1}}}) // max
                   : i_acc_shifted_sys[IQ_WIDTH-1:0];

wire signed [IQ_WIDTH-1:0] q_sat_sys =
    q_overflow_sys ? (q_acc_shifted_sys[RRC_ACC_WIDTH-1] ? {1'b1, {(IQ_WIDTH-1){1'b0}}}
                                                          : {1'b0, {(IQ_WIDTH-1){1'b1}}})
                   : q_acc_shifted_sys[IQ_WIDTH-1:0];

// Output registers
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_out_sys <= {IQ_WIDTH{1'b0}};
    else if (mac_done_sys) i_out_sys <= i_sat_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_out_sys <= {IQ_WIDTH{1'b0}};
    else if (mac_done_sys) q_out_sys <= q_sat_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) out_valid_sys <= 1'b0;
    else            out_valid_sys <= mac_done_sys;
end

// =============================================================================
// Unused signal tie-off (suppress lint warnings)
// =============================================================================
// synthesis translate_off
wire unused_ok = fifo_wr_rst_busy;
// synthesis translate_on

endmodule

`default_nettype wire
