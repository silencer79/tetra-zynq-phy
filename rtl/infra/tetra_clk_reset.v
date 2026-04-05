// =============================================================================
// Module:      tetra_clk_reset
// Project:     tetra-zynq-phy
// File:        rtl/infra/tetra_clk_reset.v
//
// Description: Reset synchronizer for all clock domains.
//   Generates synchronized active-low resets for each clock domain.
//   Assert is asynchronous (immediate propagation on arst_n falling edge).
//   Deassert is synchronous (2-cycle delay in target domain — safe release).
//
//   This is the first module to instantiate in any design. Every other module
//   receives its reset from here.
//
// Clock Domains:
//   clk_sys    — 100 MHz system processing clock (Zynq PL fabric)
//   clk_sample — AD9361 RX_CLK decimated to symbol rate (~72 kHz for
//                18 kSPS × 4 oversampling; exact rate set by CIC configuration)
//   clk_axi    — 100 MHz AXI bus clock (typically same source as clk_sys but
//                treated as independent domain for safety)
//   clk_lvds   — AD9361 DATA_CLK (LVDS DDR clock, ~61 MHz for 122 MSPS mode)
//
// Pipeline:
//   Stage 0: First synchronizer FF — absorbs metastability
//   Stage 1: Second synchronizer FF — stable synchronized output
//   Deassert latency: exactly 2 rising edges of target clock after arst_n high
//
// Ports:
//   arst_n       i  1   Asynchronous reset source, active-low (from PS or pin)
//   clk_sys      i  1   100 MHz system clock
//   clk_sample   i  1   AD9361-derived sample clock
//   clk_axi      i  1   100 MHz AXI bus clock
//   clk_lvds     i  1   AD9361 DATA_CLK
//   rst_n_sys    o  1   Synchronized reset, clk_sys domain
//   rst_n_sample o  1   Synchronized reset, clk_sample domain
//   rst_n_axi    o  1   Synchronized reset, clk_axi domain
//   rst_n_lvds   o  1   Synchronized reset, clk_lvds domain
//
// Resource Estimate: 8 FF, 0 LUT, 0 DSP48, 0 BRAM18k
//
// Constraints: See constraints/libresdr_tetra.xdc
//   set_false_path -to [get_cells *rst_sync0*]  — for all 4 sync chains
//
// CDC documented in: docs/timing_analysis.md
//
// Ref: Xilinx UG901 "Vivado Design Suite User Guide: Design Analysis and
//      Closure Techniques", Reset Synchronizer pattern
//      ETSI EN 300 392-2 (no direct dependency — infrastructure module)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_clk_reset (
    // ------------------------------------------------------------------
    // Asynchronous reset input (active-low)
    // ------------------------------------------------------------------
    input  wire arst_n,         // From Zynq PS (proc_sys_reset) or board pin

    // ------------------------------------------------------------------
    // Clock inputs — one per domain
    // ------------------------------------------------------------------
    input  wire clk_sys,        // 100 MHz system clock
    input  wire clk_sample,     // AD9361 RX sample clock (decimated)
    input  wire clk_axi,        // 100 MHz AXI bus clock
    input  wire clk_lvds,       // AD9361 DATA_CLK (LVDS)

    // ------------------------------------------------------------------
    // Synchronized resets — active-low, one per domain
    // ------------------------------------------------------------------
    output wire rst_n_sys,      // clk_sys domain reset
    output wire rst_n_sample,   // clk_sample domain reset
    output wire rst_n_axi,      // clk_axi domain reset
    output wire rst_n_lvds      // clk_lvds domain reset
);

// =============================================================================
// CLK_SYS Domain — Reset Synchronizer
//
// Pipeline Stage 0: Metastability absorber (first FF)
// Pipeline Stage 1: Stable output (second FF)
//
// ASYNC_REG attribute instructs Vivado to:
//   1. Place both FFs close together (same slice if possible)
//   2. Not optimize or reorder the chain
//   3. Apply appropriate MTBF analysis
// =============================================================================

(* ASYNC_REG = "TRUE" *) reg rst_sync0_sys;
(* ASYNC_REG = "TRUE" *) reg rst_sync1_sys;

// Pipeline Stage 0 — clk_sys domain, first synchronizer FF
always @(posedge clk_sys or negedge arst_n) begin
    if (!arst_n)
        rst_sync0_sys <= 1'b0;
    else
        rst_sync0_sys <= 1'b1;
end

// Pipeline Stage 1 — clk_sys domain, second synchronizer FF
always @(posedge clk_sys or negedge arst_n) begin
    if (!arst_n)
        rst_sync1_sys <= 1'b0;
    else
        rst_sync1_sys <= rst_sync0_sys;
end

assign rst_n_sys = rst_sync1_sys;

// =============================================================================
// CLK_SAMPLE Domain — Reset Synchronizer
//
// Note: clk_sample is very slow (~72 kHz). Reset deassert latency is
// ~27 µs (2 cycles × 13.89 µs). This is acceptable — the sys/axi domains
// will always be released from reset first.
// =============================================================================

(* ASYNC_REG = "TRUE" *) reg rst_sync0_sample;
(* ASYNC_REG = "TRUE" *) reg rst_sync1_sample;

// Pipeline Stage 0 — clk_sample domain, first synchronizer FF
always @(posedge clk_sample or negedge arst_n) begin
    if (!arst_n)
        rst_sync0_sample <= 1'b0;
    else
        rst_sync0_sample <= 1'b1;
end

// Pipeline Stage 1 — clk_sample domain, second synchronizer FF
always @(posedge clk_sample or negedge arst_n) begin
    if (!arst_n)
        rst_sync1_sample <= 1'b0;
    else
        rst_sync1_sample <= rst_sync0_sample;
end

assign rst_n_sample = rst_sync1_sample;

// =============================================================================
// CLK_AXI Domain — Reset Synchronizer
//
// Note: clk_axi is typically the same frequency and phase-locked to clk_sys
// in a Zynq design (both sourced from FCLK_CLK0). However, we treat them
// as independent domains per CDC safety rules. The XPM CDC FIFO between
// clk_sys and clk_axi requires independent resets.
// =============================================================================

(* ASYNC_REG = "TRUE" *) reg rst_sync0_axi;
(* ASYNC_REG = "TRUE" *) reg rst_sync1_axi;

// Pipeline Stage 0 — clk_axi domain, first synchronizer FF
always @(posedge clk_axi or negedge arst_n) begin
    if (!arst_n)
        rst_sync0_axi <= 1'b0;
    else
        rst_sync0_axi <= 1'b1;
end

// Pipeline Stage 1 — clk_axi domain, second synchronizer FF
always @(posedge clk_axi or negedge arst_n) begin
    if (!arst_n)
        rst_sync1_axi <= 1'b0;
    else
        rst_sync1_axi <= rst_sync0_axi;
end

assign rst_n_axi = rst_sync1_axi;

// =============================================================================
// CLK_LVDS Domain — Reset Synchronizer
//
// AD9361 DATA_CLK: frequency depends on sample rate configuration.
// Typical: 61.44 MHz for 122.88 MSPS (max), scaled down for lower rates.
// For TETRA application: AD9361 runs at minimum ~520 kSPS → DATA_CLK ≥ 260 kHz.
// =============================================================================

(* ASYNC_REG = "TRUE" *) reg rst_sync0_lvds;
(* ASYNC_REG = "TRUE" *) reg rst_sync1_lvds;

// Pipeline Stage 0 — clk_lvds domain, first synchronizer FF
always @(posedge clk_lvds or negedge arst_n) begin
    if (!arst_n)
        rst_sync0_lvds <= 1'b0;
    else
        rst_sync0_lvds <= 1'b1;
end

// Pipeline Stage 1 — clk_lvds domain, second synchronizer FF
always @(posedge clk_lvds or negedge arst_n) begin
    if (!arst_n)
        rst_sync1_lvds <= 1'b0;
    else
        rst_sync1_lvds <= rst_sync0_lvds;
end

assign rst_n_lvds = rst_sync1_lvds;

endmodule

`default_nettype wire
