// =============================================================================
// Module: tetra_tx_chain
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_tx_chain.v
//
// Description:
// TX Chain Container — wraps the symbol-rate datapath after the
// post-Y.3 burst dispatcher:
//
// tetra_burst_dispatcher (top-level) ─►
// burst_builder ─► pi4dqpsk_mod ─► rrc_filter ─► tx_frontend ─► AD9361
//
// Continuous downlink: every TDMA slot transmits (NDB or SDB). Idle
// slots arrive with all-zero body and zero burst_type so the builder
// produces a valid TAIL/sync-shaped continuous symbol stream.
//
// Coding rules: Verilog-2001 strict (R1–R10).
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_chain #(
 parameter IQ_WIDTH = 16,
 parameter BLOCK_BITS = 216,
 parameter BB_BITS = 30,
 parameter SB1_BITS = 120
) (
 // -------------------------------------------------------------------------
 // clk_sys domain
 // -------------------------------------------------------------------------
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // Builder payload inputs (from tetra_burst_dispatcher). All values
 // are valid on the cycle that build_req_sys pulses.
 // -------------------------------------------------------------------------
 input wire [BLOCK_BITS-1:0] build_block1_sys,
 input wire [BLOCK_BITS-1:0] build_block2_sys,
 input wire [BB_BITS-1:0] build_bb_sys,
 input wire [SB1_BITS-1:0] build_sb1_sys,
 input wire build_burst_type_sys, // 0=NDB, 1=SDB
 input wire build_ndb2_sys, // 0=NDB1, 1=NDB2
 input wire build_req_sys,

 // -------------------------------------------------------------------------
 // Diagnostic test mode: when HIGH, the builder dibit feeding the
 // modulator is replaced by a 15-bit LFSR PRBS (spectrum-only test).
 // -------------------------------------------------------------------------
 input wire tx_test_prbs_en_sys,

 // -------------------------------------------------------------------------
 // Symbol enable — exact 18,000 Hz from clk_lvds ÷ 1024, synced to
 // clk_sys in the top-level.
 // -------------------------------------------------------------------------
 input wire sym_en_ext_sys,

 // -------------------------------------------------------------------------
 // clk_lvds domain (AD9361 DATA_CLK)
 // -------------------------------------------------------------------------
 input wire clk_lvds,
 input wire rst_n_lvds,

 output wire signed [IQ_WIDTH-1:0] tx_i_lvds,
 output wire signed [IQ_WIDTH-1:0] tx_q_lvds,
 output wire tx_valid_lvds,

 // -------------------------------------------------------------------------
 // Status outputs (to AXI-Lite register bank)
 // -------------------------------------------------------------------------
 output wire tx_busy_sys,

 // -------------------------------------------------------------------------
 // 2026-05-25 Mess-Infra: 1-cycle Puls am ersten Dibit jeder Burst aus
 // dem burst_builder. Wird im zynq_top mit current_burst_is_ts1_r AND-
 // verknüpft → TS1-Stopuhr-Start-Puls. Keine RRC/CIC-Pipeline involved.
 // -------------------------------------------------------------------------
 output wire first_dibit_sys
);

// =============================================================================
// Internal wires
// =============================================================================

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
.block1_data_sys (build_block1_sys),
.block2_data_sys (build_block2_sys),
.bb_data_sys (build_bb_sys),
 // SDB inputs
.sb1_data_sys (build_sb1_sys),
 // Control
.burst_type_sys (build_burst_type_sys),
.burst_ndb2_sys (build_ndb2_sys),
.build_req_sys (build_req_sys),
 // Outputs
.tx_dibit_sys (builder_dibit_sys),
.tx_dibit_valid_sys(builder_dibit_valid_sys),
.tx_done_sys (builder_done_sys),
.tx_busy_sys (builder_busy_sys),
.first_dibit_sys (first_dibit_sys)
);

// =============================================================================
// PRBS dibit source (diagnostic) — 15-bit LFSR x^15 + x^14 + 1.
// Period: 32767 symbols ≈ 1.82 s at 18 ksym/s. Kept as a TX-test mode.
// =============================================================================
reg [14:0] prbs_lfsr_sys;
wire prbs_fb_w = prbs_lfsr_sys[14] ^ prbs_lfsr_sys[13];

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 prbs_lfsr_sys <= 15'h7FFF;
 else if (builder_dibit_valid_sys)
 prbs_lfsr_sys <= {prbs_lfsr_sys[13:0], prbs_fb_w};
end

wire [1:0] prbs_dibit_w = prbs_lfsr_sys[14:13];
wire [1:0] mod_dibit_sys = tx_test_prbs_en_sys ? prbs_dibit_w: builder_dibit_sys;

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
// tx_frontend (CDC clk_sys → clk_lvds)
// =============================================================================
tetra_tx_frontend #(
.IQ_WIDTH (IQ_WIDTH),
.CIC_SHIFT(24),
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
// Status
// =============================================================================
assign tx_busy_sys = builder_busy_sys;

endmodule

`default_nettype wire
