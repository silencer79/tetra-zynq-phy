// =============================================================================
// Module:  tetra_rx_chain
// Project: tetra-zynq-phy
// File:    rtl/rx/tetra_rx_chain.v
//
// Description:
//   RX Chain Container — instantiates and connects all RX datapath modules:
//
//   AD9361 (clk_lvds) → rx_frontend (CIC+RRC, CDC) → pi4dqpsk_demod
//   → timing_recovery → sync_detect → burst_demux → frame_counter
//   → [outputs to LMAC / AXI-DMA]
//
// Clock domains:
//   clk_lvds: input IQ samples from AD9361
//   clk_sys:  100 MHz processing clock (all modules after CDC)
//
// Resource estimate (sum of Phase-1 sub-modules):
//   LUT  : ~500    FF  : ~1200    DSP48 : 3    BRAM : 0
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_rx_chain #(
    parameter IQ_WIDTH   = 16,
    parameter BLOCK_BITS = 216,
    parameter BB_BITS    = 30,
    parameter CORR_WIDTH = 24
)(
    // -------------------------------------------------------------------------
    // clk_lvds domain (AD9361 DATA_CLK)
    // -------------------------------------------------------------------------
    input  wire              clk_lvds,
    input  wire              rst_n_lvds,

    // Raw IQ from axi_ad9361 IP (via tetra_ad9361_axis_adapter)
    input  wire signed [IQ_WIDTH-1:0] rx_i_lvds,
    input  wire signed [IQ_WIDTH-1:0] rx_q_lvds,
    input  wire                       rx_valid_lvds,

    // -------------------------------------------------------------------------
    // clk_sys domain (100 MHz)
    // -------------------------------------------------------------------------
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // Configuration (from AXI-Lite registers)
    input  wire [CORR_WIDTH-1:0]  corr_threshold_sys,
    input  wire [1:0]             seq_select_sys,

    // Digital loopback mode — bypasses CIC ×64 gain in rx_frontend
    input  wire                   loopback_en_sys,

    // -------------------------------------------------------------------------
    // Outputs to LMAC / AXI-DMA (clk_sys domain)
    // -------------------------------------------------------------------------
    // Demodulated burst fields (single burst per slot_valid pulse)
    output wire [BLOCK_BITS-1:0]   block1_out_sys,
    output wire [BLOCK_BITS-1:0]   block2_out_sys,
    output wire [BB_BITS-1:0]      bb_out_sys,
    output wire                    slot_valid_sys,   // 1-cycle pulse per completed burst
    output wire [1:0]              slot_num_out_sys, // slot index (0-3) of this burst
    output wire [1:0]              burst_type_out_sys,

    // Frame timing outputs
    output wire [1:0]              timeslot_num_sys,
    output wire [4:0]              frame_num_sys,
    output wire [5:0]              multiframe_num_sys,
    output wire [15:0]             hyperframe_num_sys,
    output wire                    is_control_frame_sys,
    output wire                    frame_18_slot1_sys,

    // -------------------------------------------------------------------------
    // Status (to AXI-Lite register bank)
    // -------------------------------------------------------------------------
    output wire              sync_locked_sys,
    output wire              sync_found_sys,
    output wire [7:0]        slot_position_sys,

    // Phase error for timing recovery diagnostics
    output wire signed [15:0] phase_error_sys,

    // Debug: peak STS correlation value
    output wire [CORR_WIDTH-1:0] corr_peak_sys,

  // -------------------------------------------------------------------------
  // Debug outputs (ILA probes)
  // -------------------------------------------------------------------------
  output wire dbg_fe_valid_sys,
  output wire dbg_tr_valid_sys,
  output wire dbg_demod_valid_sys
);

// =============================================================================
// Internal wires
// =============================================================================

// rx_frontend → timing_recovery → pi4dqpsk_demod
wire signed [IQ_WIDTH-1:0] fe_i_sys;
wire signed [IQ_WIDTH-1:0] fe_q_sys;
wire                       fe_valid_sys;

// timing_recovery → pi4dqpsk_demod (on-time samples at 18 kHz)
wire signed [IQ_WIDTH-1:0] tr_i_sys;
wire signed [IQ_WIDTH-1:0] tr_q_sys;
wire                       tr_valid_sys;  // 18 kHz strobe — 1 sample per TDMA symbol

// pi4dqpsk_demod → sync_detect, burst_demux
wire [1:0]  demod_dibit_sys;
wire        demod_valid_sys;
wire signed [15:0] demod_phase_err_sys;

// sync_detect → burst_demux
wire        sync_found_w;
wire        sync_locked_w;
wire [7:0]  slot_position_w;
wire [CORR_WIDTH-1:0] corr_peak_w;
wire [1:0]  slot_number_w;

// burst_demux internal signal (slot_valid is both an output and feeds frame_counter)

// =============================================================================
// rx_frontend (CIC decimator + RRC matched filter + CDC)
// =============================================================================
tetra_rx_frontend #(
    .IQ_WIDTH      (IQ_WIDTH),
    .CIC_ORDER     (5),
    .CIC_R         (64),
    .CIC_M         (1),
    .RRC_TAPS      (33),
    .RRC_ACC_SHIFT (14)
) u_rx_frontend (
    .clk_lvds     (clk_lvds),
    .rst_n_lvds   (rst_n_lvds),
    .rx_i_lvds    (rx_i_lvds),
    .rx_q_lvds    (rx_q_lvds),
    .rx_valid_lvds(rx_valid_lvds),
    .clk_sys      (clk_sys),
    .rst_n_sys    (rst_n_sys),
    .i_out_sys    (fe_i_sys),
    .q_out_sys    (fe_q_sys),
    .out_valid_sys(fe_valid_sys),
    .loopback_en_sys(loopback_en_sys)
);

// =============================================================================
// pi4dqpsk_demod
// =============================================================================
tetra_pi4dqpsk_demod #(
    .IQ_WIDTH    (IQ_WIDTH),
    .PHASE_WIDTH (16),
    .CORDIC_ITER (16)
) u_demod (
    .clk_sample   (clk_sys),
    .rst_n_sample (rst_n_sys),
    .i_in         (tr_i_sys),
    .q_in         (tr_q_sys),
    .sample_valid (tr_valid_sys),
    .dibit_out    (demod_dibit_sys),
    .dibit_valid  (demod_valid_sys),
    .phase_error  (demod_phase_err_sys)
);

// =============================================================================
// timing_recovery (Gardner TED + NCO)
// =============================================================================
tetra_timing_recovery #(
    .IQ_WIDTH  (IQ_WIDTH),
    .NCO_WIDTH (32)
) u_timing_recovery (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .i_in_sys             (fe_i_sys),
    .q_in_sys             (fe_q_sys),
    .sample_valid_in_sys  (fe_valid_sys),
    .i_out_sys            (tr_i_sys),
    .q_out_sys            (tr_q_sys),
    .sample_valid_out_sys (tr_valid_sys),
    .timing_locked_sys    (),
    .timing_error_sys     ()
);

// =============================================================================
// sync_detect (Sliding Correlator)
// =============================================================================
tetra_sync_detect #(
    .CORR_WIDTH  (CORR_WIDTH),
    .SEQ_LEN_MAX (38)
) u_sync_detect (
    .clk_sample     (clk_sys),
    .rst_n_sample   (rst_n_sys),
    .dibit_in       (demod_dibit_sys),
    .dibit_valid    (demod_valid_sys),
    .corr_threshold (corr_threshold_sys),
    .seq_select     (seq_select_sys),
    .sync_found     (sync_found_w),
    .sync_locked    (sync_locked_w),
    .slot_position  (slot_position_w),
    .slot_number    (slot_number_w),
    .corr_peak      (corr_peak_w)
);

// =============================================================================
// burst_demux
// =============================================================================
tetra_burst_demux #(
    .BLOCK_BITS   (BLOCK_BITS),
    .BB_BITS      (BB_BITS),
    .TS_PER_FRAME (4)
) u_burst_demux (
    .clk_sample   (clk_sys),
    .rst_n_sample (rst_n_sys),
    .dibit_in     (demod_dibit_sys),
    .dibit_valid  (demod_valid_sys),
    .sync_locked  (sync_locked_w),
    .sync_found   (sync_found_w),
    .seq_select   (seq_select_sys),
    .slot_position(slot_position_w),
    .block1_data  (block1_out_sys),
    .block2_data  (block2_out_sys),
    .bb_data      (bb_out_sys),
    .slot_valid   (slot_valid_sys),
    .slot_num_out (slot_num_out_sys),
    .burst_type   (burst_type_out_sys)
);

// =============================================================================
// frame_counter
// =============================================================================
tetra_frame_counter u_frame_counter (
    .clk_sample       (clk_sys),
    .rst_n_sample     (rst_n_sys),
    .sync_locked      (sync_locked_w),
    .slot_pulse       (slot_valid_sys),
    .timeslot_num     (timeslot_num_sys),
    .frame_num        (frame_num_sys),
    .multiframe_num   (multiframe_num_sys),
    .hyperframe_num   (hyperframe_num_sys),
    .is_control_frame (is_control_frame_sys),
    .frame_18_slot1   (frame_18_slot1_sys)
);

// =============================================================================
// Status output assignments
// =============================================================================
assign sync_locked_sys   = sync_locked_w;
assign sync_found_sys    = sync_found_w;
assign slot_position_sys = slot_position_w;
assign phase_error_sys   = demod_phase_err_sys;
assign corr_peak_sys     = corr_peak_w;

// Debug outputs for ILA
assign dbg_fe_valid_sys = fe_valid_sys;
assign dbg_tr_valid_sys = tr_valid_sys;
assign dbg_demod_valid_sys = demod_valid_sys;

endmodule
`default_nettype wire
