// =============================================================================
// Module:  tetra_ad9361_axis_adapter
// Project: tetra-zynq-phy
// File:    rtl/tetra_ad9361_axis_adapter.v
//
// Description:
//   Thin adapter between the ADI axi_ad9361 IP block (Vivado Block Design)
//   and the tetra_rx_chain / tetra_tx_chain fabric interfaces.
//
//   The axi_ad9361 IP handles all LVDS DDR I/O, DDR calibration, and AD9361
//   SPI configuration internally.  It exposes separate 16-bit I and Q buses
//   on the fabric side (NOT a combined 32-bit bus):
//
//     ADC (axi_ad9361 → fabric):
//       adc_clk        — DATA_CLK derived clock, driven by IP
//       adc_valid_i0   — one-cycle pulse per I sample (= valid per IQ pair)
//       adc_data_i0    — I sample, 16-bit (sign-extended 12→16 bit by IP)
//       adc_data_q0    — Q sample, 16-bit (sign-extended 12→16 bit by IP)
//       adc_enable_i0  — IP asserts when ADC path is active (DC level)
//
//     DAC (fabric → axi_ad9361):
//       dac_clk        — DAC clock driven by IP (same source as adc_clk)
//       dac_valid_i0   — IP OUTPUT: asserts each cycle IP samples DAC data
//       dac_enable_i0  — IP OUTPUT: asserts when DAC path is active (DC level)
//       dac_data_i0    — I sample from fabric to IP, 16-bit
//       dac_data_q0    — Q sample from fabric to IP, 16-bit
//
//   Mapping to tetra signal conventions:
//     rx_i_lvds      = adc_data_i0    (combinational pass-through)
//     rx_q_lvds      = adc_data_q0    (combinational pass-through)
//     rx_valid_lvds  = adc_valid_i0   (combinational pass-through)
//     clk_lvds       = l_clk          (wire pass-through; was adc_clk = dac_clk = l_clk)
//
//     dac_data_i0    = tx_i_lvds      (registered, holds last value)
//     dac_data_q0    = tx_q_lvds      (registered, holds last value)
//
// Note on Q0 valid/enable:
//   adc_valid_q0 / adc_enable_q0 / dac_valid_q0 / dac_enable_q0 are included
//   as ports to match the full axi_ad9361 IP interface per XCI.  In the ADI IP,
//   these signals are always asserted together with their I0 counterparts in
//   normal operation (I and Q are always valid simultaneously).  Our RX path
//   uses adc_valid_i0 as the single valid strobe — both I0 and Q0 are always
//   valid at the same time per the ADI interface specification.
//
// TX hold behaviour:
//   The axi_ad9361 DAC runs at DATA_CLK rate (continuous stream).  Our
//   tx_valid_lvds strobe arrives at the symbol rate (~18 kHz, much slower).
//   The adapter registers the last TX IQ pair and holds it until the next
//   valid strobe.  This matches the "sample-and-hold" pattern expected by
//   the RRC upsampler in the TX chain — the IP will repeat the same sample
//   until a new symbol arrives, but the CIC/RRC interpolation in the TX
//   frontend makes this correct (upsampling is done before this point).
//
//   NOTE: in the full BD the TX datapath is:
//     PS → AXI-DMA (MM2S) → burst_builder → pi4dqpsk_mod → rrc_filter
//     → tx_frontend (CIC interp) → tx_i/q_lvds → [this adapter] → axi_ad9361
//   The CIC outputs samples at DATA_CLK rate, so tx_valid_lvds will toggle
//   at the full DATA_CLK rate during transmission bursts.  The hold behaviour
//   is only visible during idle gaps.
//
// Clock domain:
//   All registered logic in this module runs in the adc_clk / dac_clk domain
//   (both are the same DATA_CLK source from the axi_ad9361 IP).
//   Suffix used: _lvds (matching tetra_clk_reset convention).
//
// Resource estimate:
//   ~5 LUT, ~32 FF, 0 DSP48, 0 BRAM18k
//   (RX path is pure wire; TX path is one 32-bit register)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//
// Ref: ADI HDL library — library/axi_ad9361 (Apache-2.0)
//      AD9361 Reference Manual UG-570, §5 (Parallel Data Port)
//      openwifi project — libresdr/system_top.v (verified hardware config)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_ad9361_axis_adapter #(
    parameter IQ_WIDTH = 16
)(
    // -------------------------------------------------------------------------
    // DATA_CLK — axi_ad9361 IP port: l_clk (master clock output from IP)
    // Same clock drives both ADC and DAC fabric interface.
    // -------------------------------------------------------------------------
    input  wire                       l_clk,             // DATA_CLK from axi_ad9361.l_clk

    // -------------------------------------------------------------------------
    // axi_ad9361 ADC fabric interface (IP outputs → fabric inputs)
    // Port names match axi_ad9361 XCI boundary exactly.
    // -------------------------------------------------------------------------
    input  wire                       adc_valid_i0,      // I0: one-cycle valid pulse
    input  wire [IQ_WIDTH-1:0]        adc_data_i0,       // I0: sample data (16-bit)
    input  wire                       adc_enable_i0,     // I0: path active (DC level)
    input  wire                       adc_valid_q0,      // Q0: one-cycle valid pulse (parallel with I0)
    input  wire [IQ_WIDTH-1:0]        adc_data_q0,       // Q0: sample data (16-bit)
    input  wire                       adc_enable_q0,     // Q0: path active

    // -------------------------------------------------------------------------
    // axi_ad9361 DAC fabric interface
    // dac_valid_i0/q0 and dac_enable_i0/q0 are IP outputs (informational).
    // dac_data_i0/q0 are IP inputs (fabric drives these).
    // -------------------------------------------------------------------------
    input  wire                       dac_valid_i0,      // IP output: I0 data requested
    input  wire                       dac_enable_i0,     // IP output: I0 path active
    input  wire                       dac_valid_q0,      // IP output: Q0 data requested
    input  wire                       dac_enable_q0,     // IP output: Q0 path active
    output reg  [IQ_WIDTH-1:0]        dac_data_i0,       // I0 to IP (16-bit)
    output reg  [IQ_WIDTH-1:0]        dac_data_q0,       // Q0 to IP (16-bit)

    // -------------------------------------------------------------------------
    // Reset (from tetra_clk_reset, adc_clk / dac_clk domain)
    // -------------------------------------------------------------------------
    input  wire                       rst_n_lvds,

    // -------------------------------------------------------------------------
    // tetra_rx_chain interface (clk_lvds = adc_clk domain)
    // -------------------------------------------------------------------------
    output wire                       clk_lvds,                        // = adc_clk
    output wire signed [IQ_WIDTH-1:0] rx_i_lvds,                      // I sample
    output wire signed [IQ_WIDTH-1:0] rx_q_lvds,                      // Q sample
    output wire                       rx_valid_lvds,                   // valid strobe

    // -------------------------------------------------------------------------
    // tetra_tx_chain interface (clk_lvds = dac_clk domain)
    // -------------------------------------------------------------------------
    input  wire signed [IQ_WIDTH-1:0] tx_i_lvds,                      // I sample
    input  wire signed [IQ_WIDTH-1:0] tx_q_lvds,                      // Q sample
    input  wire                       tx_valid_lvds                    // valid strobe
);

// =============================================================================
// RX path — combinational pass-through
//
// Pipeline stage 0: adc_data_0 → rx_i/q_lvds (zero gate delay)
// axi_ad9361 sign-extends the 12-bit ADC output to 16 bits internally.
// =============================================================================

assign clk_lvds      = l_clk;                  // l_clk is DATA_CLK from axi_ad9361 IP
assign rx_i_lvds     = $signed(adc_data_i0);   // direct 16-bit I pass-through
assign rx_q_lvds     = $signed(adc_data_q0);   // direct 16-bit Q pass-through
assign rx_valid_lvds = adc_valid_i0;            // I0 valid = Q0 valid (per ADI spec)

// Q0 valid/enable signals are parallel to I0 in normal ADI operation.
// We use adc_valid_i0 as the single RX valid strobe.
// synthesis translate_off
wire _unused_adc = adc_enable_i0 | adc_valid_q0 | adc_enable_q0;
// synthesis translate_on

// =============================================================================
// TX path — registered sample-and-hold, separate I and Q registers
//
// R1: dac_data_i0 register
// R2: dac_data_q0 register
//   Each captures the respective tx_i/q_lvds value on every tx_valid_lvds
//   pulse and holds it until the next pulse.
//   The axi_ad9361 IP samples dac_data_i0/q0 continuously at dac_clk rate;
//   our tx_chain drives tx_valid_lvds at the CIC-interpolated rate, so the
//   hold ensures the IP always sees valid data.
//
// dac_valid_i0 / dac_enable_i0 are outputs from the IP (informational).
// We always present data regardless — the IP controls its own sampling.
// =============================================================================

// R1: dac_data_i0 — hold last TX I sample
always @(posedge l_clk or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        dac_data_i0 <= {IQ_WIDTH{1'b0}};
    else if (tx_valid_lvds)
        dac_data_i0 <= tx_i_lvds[IQ_WIDTH-1:0];
    // else: hold last value
end

// R2: dac_data_q0 — hold last TX Q sample
always @(posedge l_clk or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        dac_data_q0 <= {IQ_WIDTH{1'b0}};
    else if (tx_valid_lvds)
        dac_data_q0 <= tx_q_lvds[IQ_WIDTH-1:0];
    // else: hold last value
end

// dac_valid_i0/q0 and dac_enable_i0/q0 are IP outputs — informational only.
// We drive dac_data continuously; the IP samples at its own rate.
// synthesis translate_off
wire _unused_dac = dac_valid_i0 | dac_enable_i0 | dac_valid_q0 | dac_enable_q0;
// synthesis translate_on

endmodule
`default_nettype wire
