// =============================================================================
// Module: tetra_lmac
// Project: tetra-zynq-phy
// File: rtl/lmac/tetra_lmac.v
//
// Description:
// Lower MAC Container — instantiates channel coding/decoding modules and
// wires them in the RX and TX signal paths.
//
// RX path (after burst_demux):
// block data → descrambler → deinterleaver → depuncturer → viterbi_decoder → CRC-16
// bb data → reed_muller (decoder)
//
// TX path (before burst_mux):
// payload → CRC-16 → rcpc_encoder → interleaver → scrambler → block data
// AACH → reed_muller (encoder) → bb data
//
// steal_detect is wired to the RX path to flag traffic vs. signalling bursts.
//
// Note: In Phase 3, this module is structural only. Hard-decision bits from
// the deinterleaver are fed through the rate-2/3 depuncturer which inserts
// erasures (soft=4) at punctured positions, then into the rate-1/4 Viterbi
// decoder. Full soft-decision requires LLR from the demodulator (future work).
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_lmac #(
 parameter BLOCK_BITS = 216,
 parameter LFSR_WIDTH = 32
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // RX input (from burst_demux, per slot 0 only in this phase)
 // Full 4-slot processing requires 4× instantiation or time-sharing.
 // -------------------------------------------------------------------------
 input wire [BLOCK_BITS-1:0] rx_block1_sys,
 input wire [BLOCK_BITS-1:0] rx_block2_sys,
 input wire [29:0] rx_bb_sys,
 input wire rx_slot_valid_sys,

 // Scrambler configuration (from AXI-Lite)
 input wire [LFSR_WIDTH-1:0] lfsr_init_sys,
 input wire load_lfsr_sys,

 // Puncturing pattern for Viterbi (from AXI-Lite)
 input wire [2:0] punct_pattern_sys,

 // -------------------------------------------------------------------------
 // RX decoded output (to AXI-DMA bridge)
 // -------------------------------------------------------------------------
 output wire rx_decoded_bit_sys,
 output wire rx_decoded_valid_sys,
 output wire rx_block_done_sys,
 output wire [15:0] rx_path_metric_sys,

 // Reed-Muller decoded BB (AACH)
 output wire [13:0] rx_aach_data_sys,
 output wire rx_aach_done_sys,
 output wire rx_aach_error_sys,

 // CRC status
 output wire rx_crc_ok_sys,
 output wire rx_crc_valid_sys,

 // Steal-detect output
 output wire rx_stolen_sys
);

// =============================================================================
// Local wire declarations
// =============================================================================

// ---- RX path ----------------------------------------------------------------
wire rx_descr_out_sys;
wire rx_descr_valid_sys;
wire rx_deintlv_out_sys;
wire rx_deintlv_valid_sys;
wire rx_deintlv_done_sys;
wire [2:0] rx_depunct_soft0_sys;
wire [2:0] rx_depunct_soft1_sys;
wire [2:0] rx_depunct_soft2_sys;
wire [2:0] rx_depunct_soft3_sys;
wire rx_depunct_valid_sys;
wire rx_depunct_done_sys;


// CRC wires
wire rx_crc_next_ok_sys;

// Internal AACH decode wires (fed to both module outputs and steal_detect)
wire [13:0] rm_aach_data_w;
wire rm_aach_done_w;
wire rm_aach_error_w;

// =============================================================================
// RX PATH
// =============================================================================

// ---- Step 1: Descrambler (RX = descramble mode) ─────────────────────────────
// Process Block1 then Block2 sequentially; output to deinterleaver.
// In this structural version, only Block1 is wired (one processing channel).
// Full dual-block requires FSM arbitration (left for integration phase).
tetra_scrambler #(
.LFSR_WIDTH(LFSR_WIDTH)
) u_rx_scrambler (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.lfsr_init (lfsr_init_sys),
.load_init (load_lfsr_sys),
.data_in (rx_block1_sys[BLOCK_BITS-1]), // MSB-first stream
.data_valid (rx_slot_valid_sys),
.data_out (rx_descr_out_sys),
.data_out_valid(rx_descr_valid_sys)
);

// ---- Step 2: Deinterleaver ───────────────────────────────────────────────────
tetra_deinterleaver #(
.MAX_BLOCK_SIZE(432)
) u_rx_deinterleaver (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.block_size (9'd216),
.data_in (rx_descr_out_sys),
.data_in_valid (rx_descr_valid_sys),
.data_out (rx_deintlv_out_sys),
.data_out_valid(rx_deintlv_valid_sys),
.block_done (rx_deintlv_done_sys)
);

// ---- Step 3: Depuncturer (rate-2/3 over rate-1/4 mother) ─────────────────────
// 3 hard bits in → 2 trellis stages × 4 soft values out (with erasures)
tetra_depuncture_r23 #(
.SOFT_WIDTH(3)
) u_depuncturer (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.data_in (rx_deintlv_out_sys),
.data_in_valid(rx_deintlv_valid_sys),
.soft_0 (rx_depunct_soft0_sys),
.soft_1 (rx_depunct_soft1_sys),
.soft_2 (rx_depunct_soft2_sys),
.soft_3 (rx_depunct_soft3_sys),
.output_valid (rx_depunct_valid_sys),
.block_start (rx_slot_valid_sys),
.block_done (rx_depunct_done_sys)
);

// ---- Step 4: Viterbi Decoder (rate-1/4, ETSI generators) ─────────────────────
// Hard-decision input via depuncturer soft values (0=strong_0, 7=strong_1, 4=erasure)
// num_stages: BNCH=144 (140 info+4 tail), SCH/F=288 (284 info+4 tail)
// Using 144 for slot-0 BNCH decode path.
tetra_viterbi_decoder #(
.SOFT_WIDTH(3),
.TRACEBACK (32),
.MAX_STAGES(436)
) u_viterbi (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.soft_bit_0 (rx_depunct_soft0_sys),
.soft_bit_1 (rx_depunct_soft1_sys),
.soft_bit_2 (rx_depunct_soft2_sys),
.soft_bit_3 (rx_depunct_soft3_sys),
.input_valid (rx_depunct_valid_sys),
.num_stages (9'd144),
.punct_pattern (punct_pattern_sys),
.decoded_bit (rx_decoded_bit_sys),
.decoded_valid (rx_decoded_valid_sys),
.block_done (rx_block_done_sys),
.path_metric_min(rx_path_metric_sys)
);

// ---- Step 5: CRC-16 (RX checker) ────────────────────────────────────────────
tetra_crc16 u_rx_crc (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.data_in_sys (rx_decoded_bit_sys),
.data_valid_sys(rx_decoded_valid_sys),
.init_sys (rx_block_done_sys),
.done_in_sys (1'b0), // continuous check mode
.crc_out_sys (),
.crc_valid_sys(rx_crc_valid_sys),
.crc_ok_sys (rx_crc_ok_sys)
);

// ---- Step 6: Reed-Muller Decoder (BB / AACH) ─────────────────────────────────
tetra_reed_muller #(
.N(30),
.K(14)
) u_rm (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Decoder
.decode_data_in (rx_bb_sys),
.decode_valid (rx_slot_valid_sys),
.decode_data_out(rm_aach_data_w),
.decode_done (rm_aach_done_w),
.decode_error (rm_aach_error_w),
 // Encoder ports unused — AACH TX-Encode-Pfad 2026-06-20 entfernt, tie off
.encode_data_in (14'd0),
.encode_valid (1'b0),
.encode_data_out(),
.encode_done ()
);

// ---- Module output assignments for AACH ──────────────────────────────────────
assign rx_aach_data_sys = rm_aach_data_w;
assign rx_aach_done_sys = rm_aach_done_w;
assign rx_aach_error_sys = rm_aach_error_w;

// ---- Steal detect (Phase 3: slot 0 only) ─────────────────────────────────────
wire [3:0] steal_active_w;

tetra_steal_detect u_steal_detect (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.aach_data_sys (rm_aach_data_w),
.aach_valid_sys (rm_aach_done_w),
.slot_num_sys (2'd0), // Phase 3: single-slot operation
.burst_type_sys (2'd0), // NDB only
.steal_active_sys (steal_active_w),
.access_code0_sys (),
.access_code1_sys (),
.access_code2_sys (),
.access_code3_sys ()
);

assign rx_stolen_sys = steal_active_w[0];

endmodule
`default_nettype wire
