// =============================================================================
// Module: tetra_tx_chain
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_tx_chain.v
//
// Description:
// TX Chain Container — instantiates and connects all TX datapath modules:
//
// AXI-DMA (MM2S) ─► burst_mux ─► burst_builder ─► pi4dqpsk_mod
// ─► rrc_filter ─► tx_frontend ─► AD9361
//
// Continuous downlink: all 4 timeslots always transmit (SDB or NDB).
// No TX blanking — the continuous burst format with tail symbols ensures
// an uninterrupted RF carrier across all timeslots.
//
// Signal flow (clk_sys, all modules):
// burst_mux → build_req → burst_builder → tx_dibit → pi4dqpsk_mod
// pi4dqpsk_mod → dibit → sample_valid → rrc_filter
// rrc_filter → IQ → tx_frontend (CDC) → tx_i/q/valid_lvds
//
// Resource estimate (sum of sub-modules):
// LUT : ~280 FF : ~1500 DSP48 : 1 BRAM : 1
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_chain #(
 parameter IQ_WIDTH = 16,
 parameter BLOCK_BITS = 216,
 parameter BB_BITS = 30,
 parameter SB1_BITS = 120  // SDB sb1 bits (60 symbols × 2)
)(
 // -------------------------------------------------------------------------
 // clk_sys domain
 // -------------------------------------------------------------------------
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // Slot payload inputs (NDB) (from LMAC / AXI-DMA registers)
 // Flat buses: slot N at [N*BLOCK_BITS +: BLOCK_BITS]
 // -------------------------------------------------------------------------
 input wire [4*BLOCK_BITS-1:0] block1_sys,
 input wire [4*BLOCK_BITS-1:0] block2_sys,

 // -------------------------------------------------------------------------
 // BB/AACH — shared across all burst types (30 bits)
 // -------------------------------------------------------------------------
 input wire [BB_BITS-1:0] bb_sys,

 // -------------------------------------------------------------------------
 // SDB payload inputs (shared across slots)
 // -------------------------------------------------------------------------
 input wire [SB1_BITS-1:0] sb_sb1_data_sys,
 input wire [BLOCK_BITS-1:0] sb_bkn2_data_sys,

 // Per-slot configuration
 input wire [3:0] slot_en_sys,
 input wire [3:0] slot_burst_type_sys, // 1 bit per slot: 0=NDB, 1=SDB
 input wire [3:0] slot_ndb2_sys,       // 1 bit per slot: 0=NDB1, 1=NDB2

 // Diagnostic test mode: when HIGH, the builder dibit feeding the modulator
 // is replaced by a 15-bit LFSR PRBS.  Used for spectrum verification — all
 // four dibit values occur with equal probability so the π/4-DQPSK chain
 // produces a proper RRC-shaped spread spectrum rather than a degenerate
 // narrow line when the payload happens to be all-zeros.
 input wire tx_test_prbs_en_sys,

 // -------------------------------------------------------------------------
 // TX timing (from tetra_frame_counter or free-running timer)
 // -------------------------------------------------------------------------
 input wire [1:0] tx_slot_num_sys,
 input wire tx_slot_pulse_sys,

 // Symbol enable — exact 18,000 Hz derived from clk_lvds, synced to clk_sys
 input wire sym_en_ext_sys,

 // -------------------------------------------------------------------------
 // clk_lvds domain (AD9361 DATA_CLK)
 // -------------------------------------------------------------------------
 input wire clk_lvds,
 input wire rst_n_lvds,

 // Output to axi_ad9361 IP (via tetra_ad9361_axis_adapter)
 output wire signed [IQ_WIDTH-1:0] tx_i_lvds,
 output wire signed [IQ_WIDTH-1:0] tx_q_lvds,
 output wire tx_valid_lvds,

 // -------------------------------------------------------------------------
 // Status outputs (to AXI-Lite register bank)
 // -------------------------------------------------------------------------
 output wire tx_busy_sys // HIGH while burst in progress
);

// =============================================================================
// Internal wires
// =============================================================================

// burst_mux → burst_builder
wire [BLOCK_BITS-1:0] mux_block1_sys;
wire [BLOCK_BITS-1:0] mux_block2_sys;
wire [BB_BITS-1:0] mux_bb_sys;
wire [SB1_BITS-1:0] mux_sb1_sys;
wire mux_burst_type_sys;
wire mux_ndb2_sys;
wire mux_build_req_sys;
wire mux_ready_sys;

// burst_builder → pi4dqpsk_mod
wire [1:0] builder_dibit_sys;
wire builder_dibit_valid_sys;
wire builder_done_sys;
wire builder_busy_sys;

// pi4dqpsk_mod → rrc_filter
wire signed [IQ_WIDTH-1:0] mod_i_sys;
wire signed [IQ_WIDTH-1:0] mod_q_sys;
wire mod_sample_valid_sys;

// rrc_filter → tx_frontend
wire signed [IQ_WIDTH-1:0] rrc_i_sys;
wire signed [IQ_WIDTH-1:0] rrc_q_sys;
wire rrc_sample_valid_sys;

// tx_frontend → output

// =============================================================================
// burst_mux
// =============================================================================
tetra_burst_mux #(
 .BLOCK_BITS (BLOCK_BITS),
 .BB_BITS (BB_BITS),
 .SB1_BITS (SB1_BITS),
 .TS_PER_FRAME(4)
) u_burst_mux (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 // NDB inputs
 .block1_in_sys (block1_sys),
 .block2_in_sys (block2_sys),
 // BB/AACH (shared)
 .bb_in_sys (bb_sys),
 // SDB inputs
 .sb_sb1_in_sys (sb_sb1_data_sys),
 .sb_bkn2_in_sys (sb_bkn2_data_sys),
 // Slot config
 .slot_en_sys (slot_en_sys),
 .slot_burst_type_sys(slot_burst_type_sys),
 .slot_ndb2_sys      (slot_ndb2_sys),
 // Timing
 .tx_slot_num_sys (tx_slot_num_sys),
 .tx_slot_pulse_sys (tx_slot_pulse_sys),
 // Outputs
 .build_block1_sys (mux_block1_sys),
 .build_block2_sys (mux_block2_sys),
 .build_bb_sys (mux_bb_sys),
 .build_sb1_sys (mux_sb1_sys),
 .build_burst_type_sys(mux_burst_type_sys),
 .build_ndb2_sys      (mux_ndb2_sys),
 .build_req_sys (mux_build_req_sys),
 .builder_busy_sys (builder_busy_sys),
 .mux_ready_sys (mux_ready_sys)
);

// =============================================================================
// burst_builder
// =============================================================================
tetra_burst_builder #(
 .BLOCK_BITS(BLOCK_BITS),
 .BB_BITS (BB_BITS),
 .SB1_BITS (SB1_BITS)
) u_burst_builder (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 .sym_en_ext_sys (sym_en_ext_sys),
 // NDB inputs
 .block1_data_sys (mux_block1_sys),
 .block2_data_sys (mux_block2_sys),
 .bb_data_sys (mux_bb_sys),
 // SDB inputs
 .sb1_data_sys (mux_sb1_sys),
 // Control
 .burst_type_sys (mux_burst_type_sys),
 .burst_ndb2_sys (mux_ndb2_sys),
 .build_req_sys (mux_build_req_sys),
 // Outputs
 .tx_dibit_sys (builder_dibit_sys),
 .tx_dibit_valid_sys(builder_dibit_valid_sys),
 .tx_done_sys (builder_done_sys),
 .tx_busy_sys (builder_busy_sys)
);

// =============================================================================
// PRBS dibit source (diagnostic) — 15-bit LFSR, polynomial x^15 + x^14 + 1
// -----------------------------------------------------------------------------
// When tx_test_prbs_en_sys is HIGH, two fresh LFSR bits replace the builder
// dibit feeding pi4dqpsk_mod.  The LFSR advances once per builder dibit_valid
// pulse (= once per symbol ~18 kHz) and taps the two MSBs as the dibit.
//
// Period: 2^15 − 1 = 32767 symbols ≈ 1.82 s at 18 ksym/s.
// Seed: all-ones (avoids the degenerate all-zero state).
//
// Why here (not in burst_builder):
//   - Keeps the symbol cadence and tx_busy / sym_en machinery untouched.
//   - The builder's TAIL/FC/STS/NTS fixed-pattern fields are also overwritten
//     by the PRBS in test mode, which is acceptable: spectrum-level test only.
//
// Rationale for this register: see register 0x84 bit [0] (REG_TX_TEST).
// =============================================================================
reg [14:0] prbs_lfsr_sys;
wire       prbs_fb_w = prbs_lfsr_sys[14] ^ prbs_lfsr_sys[13];

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
  prbs_lfsr_sys <= 15'h7FFF;
 else if (builder_dibit_valid_sys)
  prbs_lfsr_sys <= {prbs_lfsr_sys[13:0], prbs_fb_w};
end

wire [1:0] prbs_dibit_w = prbs_lfsr_sys[14:13];

// Dibit mux: select PRBS when test mode is enabled
wire [1:0] mod_dibit_sys = tx_test_prbs_en_sys ? prbs_dibit_w : builder_dibit_sys;

// =============================================================================
// pi4dqpsk_mod
// =============================================================================
tetra_pi4dqpsk_mod #(
 .IQ_WIDTH (IQ_WIDTH),
 .PHASE_WIDTH(16),
 .LUT_DEPTH (1024)
) u_pi4dqpsk_mod (
 .clk_sample (clk_sys),
 .rst_n_sample (rst_n_sys),
 .dibit_in (mod_dibit_sys),
 .dibit_valid (builder_dibit_valid_sys),
 .i_out (mod_i_sys),
 .q_out (mod_q_sys),
 .sample_valid_out(mod_sample_valid_sys)
);

// =============================================================================
// rrc_filter
// =============================================================================
tetra_rrc_filter #(
 .IQ_WIDTH (IQ_WIDTH),
 .RRC_ACC_SHIFT(14)
) u_rrc_filter (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 .i_in (mod_i_sys),
 .q_in (mod_q_sys),
 .sample_valid_in (mod_sample_valid_sys),
 .i_out (rrc_i_sys),
 .q_out (rrc_q_sys),
 .sample_valid_out(rrc_sample_valid_sys)
);

// =============================================================================
// tx_frontend
// =============================================================================
tetra_tx_frontend #(
 .IQ_WIDTH (IQ_WIDTH),
 .CIC_SHIFT (24),
 .CIC_ACC (48)
) u_tx_frontend (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 .i_in (rrc_i_sys),
 .q_in (rrc_q_sys),
 .sample_valid_in(rrc_sample_valid_sys),
 .clk_lvds (clk_lvds),
 .rst_n_lvds (rst_n_lvds),
 .tx_i_lvds (tx_i_lvds),
 .tx_q_lvds (tx_q_lvds),
 .tx_valid_lvds (tx_valid_lvds)
);

// =============================================================================
// No TX blanking — continuous downlink always transmits on all timeslots.
// Tail symbols in the burst format maintain phase continuity between slots.
// =============================================================================

// =============================================================================
// Status
// =============================================================================
assign tx_busy_sys = builder_busy_sys;

endmodule
`default_nettype wire
