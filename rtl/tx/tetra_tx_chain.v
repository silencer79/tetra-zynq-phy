// =============================================================================
// Module:  tetra_tx_chain
// Project: tetra-zynq-phy
// File:    rtl/tx/tetra_tx_chain.v
//
// Description:
//   TX Chain Container — instantiates and connects all TX datapath modules:
//
//   AXI-DMA (MM2S) ─► burst_mux ─► burst_builder ─► pi4dqpsk_mod
//                   ─► rrc_filter ─► tx_frontend ─► AD9361 interface
//
//   Note: The MM2S (TX DMA) path is wired at the boundary but not implemented
//   in this revision (Phase 3). The TX chain accepts direct register-file
//   inputs for burst payload (suitable for loopback testing and initial
//   on-air validation).
//
//   LMAC modules (rcpc_encoder, interleaver, scrambler) are instantiated in
//   tetra_lmac.v and their outputs feed this chain via block1/block2/bb buses.
//
// Signal flow (clk_sys, all modules):
//   burst_mux → build_req → burst_builder → tx_dibit → pi4dqpsk_mod
//   pi4dqpsk_mod → dibit → sample_valid → rrc_filter
//   rrc_filter → IQ → tx_frontend (CDC) → tx_i/q/valid_lvds
//
// Resource estimate (sum of sub-modules):
//   LUT  : ~300    FF  : ~1500    DSP48 : 1    BRAM : 1
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_tx_chain #(
    parameter IQ_WIDTH   = 16,
    parameter BLOCK_BITS = 216,
    parameter BB_BITS    = 30
)(
    // -------------------------------------------------------------------------
    // clk_sys domain
    // -------------------------------------------------------------------------
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // -------------------------------------------------------------------------
    // Slot payload inputs (from LMAC / AXI-DMA registers)
    // Flat buses: slot N at [N*BLOCK_BITS +: BLOCK_BITS]
    // -------------------------------------------------------------------------
    input  wire [4*BLOCK_BITS-1:0] block1_sys,
    input  wire [4*BLOCK_BITS-1:0] block2_sys,
    input  wire [4*BB_BITS-1:0]    bb_sys,
    input  wire [3:0]              slot_en_sys,

    // -------------------------------------------------------------------------
    // TX timing (from tetra_frame_counter)
    // -------------------------------------------------------------------------
    input  wire [1:0]              tx_slot_num_sys,
    input  wire                    tx_slot_pulse_sys,

    // -------------------------------------------------------------------------
    // clk_lvds domain (AD9361 DATA_CLK)
    // -------------------------------------------------------------------------
    input  wire              clk_lvds,
    input  wire              rst_n_lvds,

    // Output to axi_ad9361 IP (via tetra_ad9361_axis_adapter)
    output wire signed [IQ_WIDTH-1:0] tx_i_lvds,
    output wire signed [IQ_WIDTH-1:0] tx_q_lvds,
    output wire                       tx_valid_lvds,

    // -------------------------------------------------------------------------
    // Status outputs (to AXI-Lite register bank)
    // -------------------------------------------------------------------------
    output wire              tx_busy_sys    // HIGH while burst in progress
);

// =============================================================================
// Internal wires
// =============================================================================

// burst_mux → burst_builder
wire [BLOCK_BITS-1:0] mux_block1_sys;
wire [BLOCK_BITS-1:0] mux_block2_sys;
wire [BB_BITS-1:0]    mux_bb_sys;
wire [1:0]            mux_burst_type_sys;
wire                  mux_build_req_sys;
wire                  mux_ready_sys;

// burst_builder → pi4dqpsk_mod
wire [1:0]  builder_dibit_sys;
wire        builder_dibit_valid_sys;
wire        builder_done_sys;
wire        builder_busy_sys;

// pi4dqpsk_mod → rrc_filter
wire signed [IQ_WIDTH-1:0] mod_i_sys;
wire signed [IQ_WIDTH-1:0] mod_q_sys;
wire                       mod_sample_valid_sys;

// rrc_filter → tx_frontend
wire signed [IQ_WIDTH-1:0] rrc_i_sys;
wire signed [IQ_WIDTH-1:0] rrc_q_sys;
wire                       rrc_sample_valid_sys;

// =============================================================================
// burst_mux
// =============================================================================
tetra_burst_mux #(
    .BLOCK_BITS  (BLOCK_BITS),
    .BB_BITS     (BB_BITS),
    .TS_PER_FRAME(4)
) u_burst_mux (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .block1_in_sys        (block1_sys),
    .block2_in_sys        (block2_sys),
    .bb_in_sys            (bb_sys),
    .slot_en_sys          (slot_en_sys),
    .tx_slot_num_sys      (tx_slot_num_sys),
    .tx_slot_pulse_sys    (tx_slot_pulse_sys),
    .build_block1_sys     (mux_block1_sys),
    .build_block2_sys     (mux_block2_sys),
    .build_bb_sys         (mux_bb_sys),
    .build_burst_type_sys (mux_burst_type_sys),
    .build_req_sys        (mux_build_req_sys),
    .builder_busy_sys     (builder_busy_sys),
    .mux_ready_sys        (mux_ready_sys)
);

// =============================================================================
// burst_builder
// =============================================================================
tetra_burst_builder #(
    .BLOCK_BITS(BLOCK_BITS),
    .BB_BITS   (BB_BITS)
) u_burst_builder (
    .clk_sys           (clk_sys),
    .rst_n_sys         (rst_n_sys),
    .block1_data_sys   (mux_block1_sys),
    .block2_data_sys   (mux_block2_sys),
    .bb_data_sys       (mux_bb_sys),
    .burst_type_sys    (mux_burst_type_sys),
    .build_req_sys     (mux_build_req_sys),
    .tx_dibit_sys      (builder_dibit_sys),
    .tx_dibit_valid_sys(builder_dibit_valid_sys),
    .tx_done_sys       (builder_done_sys),
    .tx_busy_sys       (builder_busy_sys)
);

// =============================================================================
// pi4dqpsk_mod
// =============================================================================
tetra_pi4dqpsk_mod #(
    .IQ_WIDTH   (IQ_WIDTH),
    .PHASE_WIDTH(16),
    .LUT_DEPTH  (1024)
) u_pi4dqpsk_mod (
    .clk_sample      (clk_sys),
    .rst_n_sample    (rst_n_sys),
    .dibit_in        (builder_dibit_sys),
    .dibit_valid     (builder_dibit_valid_sys),
    .i_out           (mod_i_sys),
    .q_out           (mod_q_sys),
    .sample_valid_out(mod_sample_valid_sys)
);

// =============================================================================
// rrc_filter
// =============================================================================
tetra_rrc_filter #(
    .IQ_WIDTH     (IQ_WIDTH),
    .RRC_ACC_SHIFT(14)
) u_rrc_filter (
    .clk_sys         (clk_sys),
    .rst_n_sys       (rst_n_sys),
    .i_in            (mod_i_sys),
    .q_in            (mod_q_sys),
    .sample_valid_in (mod_sample_valid_sys),
    .i_out           (rrc_i_sys),
    .q_out           (rrc_q_sys),
    .sample_valid_out(rrc_sample_valid_sys)
);

// =============================================================================
// tx_frontend
// =============================================================================
tetra_tx_frontend #(
    .IQ_WIDTH  (IQ_WIDTH),
    .CIC_SHIFT (30),
    .CIC_ACC   (48)
) u_tx_frontend (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .i_in           (rrc_i_sys),
    .q_in           (rrc_q_sys),
    .sample_valid_in(rrc_sample_valid_sys),
    .clk_lvds       (clk_lvds),
    .rst_n_lvds     (rst_n_lvds),
    .tx_i_lvds      (tx_i_lvds),
    .tx_q_lvds      (tx_q_lvds),
    .tx_valid_lvds  (tx_valid_lvds)
);

// =============================================================================
// Status
// =============================================================================
assign tx_busy_sys = builder_busy_sys;

endmodule
`default_nettype wire
