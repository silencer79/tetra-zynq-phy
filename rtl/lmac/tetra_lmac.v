// =============================================================================
// Module:  tetra_lmac
// Project: tetra-zynq-phy
// File:    rtl/lmac/tetra_lmac.v
//
// Description:
//   Lower MAC Container — instantiates channel coding/decoding modules and
//   wires them in the RX and TX signal paths.
//
//   RX path (after burst_demux):
//     block data → descrambler → deinterleaver → viterbi_decoder → CRC-16
//     bb data     → reed_muller (decoder)
//
//   TX path (before burst_mux):
//     payload → CRC-16 → rcpc_encoder → interleaver → scrambler → block data
//     AACH    → reed_muller (encoder) → bb data
//
//   steal_detect is wired to the RX path to flag traffic vs. signalling bursts.
//
// Note: In Phase 3, this module is structural only. The soft-decision interface
//   for the Viterbi decoder (3-bit soft bits) is currently driven by the hard-
//   decision demod output (MSB = sign, all others = 0). Full soft-decision
//   requires a LLR computation stage in rx_frontend (future work).
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_lmac #(
    parameter BLOCK_BITS = 216,
    parameter LFSR_WIDTH = 32
)(
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // -------------------------------------------------------------------------
    // RX input (from burst_demux, per slot 0 only in this phase)
    // Full 4-slot processing requires 4× instantiation or time-sharing.
    // -------------------------------------------------------------------------
    input  wire [BLOCK_BITS-1:0] rx_block1_sys,
    input  wire [BLOCK_BITS-1:0] rx_block2_sys,
    input  wire [29:0]           rx_bb_sys,
    input  wire                  rx_slot_valid_sys,

    // Scrambler configuration (from AXI-Lite)
    input  wire [LFSR_WIDTH-1:0] lfsr_init_sys,
    input  wire                  load_lfsr_sys,

    // Puncturing pattern for Viterbi (from AXI-Lite)
    input  wire [2:0]            punct_pattern_sys,

    // -------------------------------------------------------------------------
    // RX decoded output (to AXI-DMA bridge)
    // -------------------------------------------------------------------------
    output wire                  rx_decoded_bit_sys,
    output wire                  rx_decoded_valid_sys,
    output wire                  rx_block_done_sys,
    output wire [15:0]           rx_path_metric_sys,

    // Reed-Muller decoded BB (AACH)
    output wire [13:0]           rx_aach_data_sys,
    output wire                  rx_aach_done_sys,
    output wire                  rx_aach_error_sys,

    // CRC status
    output wire                  rx_crc_ok_sys,
    output wire                  rx_crc_valid_sys,

    // Steal-detect output
    output wire                  rx_stolen_sys,

    // -------------------------------------------------------------------------
    // TX input (from AXI-DMA / software)
    // -------------------------------------------------------------------------
    input  wire                  tx_data_in_sys,
    input  wire                  tx_data_valid_sys,
    input  wire                  tx_flush_sys,
    input  wire [13:0]           tx_aach_in_sys,
    input  wire                  tx_aach_valid_sys,

    // -------------------------------------------------------------------------
    // TX output (to burst_mux / burst_builder)
    // -------------------------------------------------------------------------
    output wire [BLOCK_BITS-1:0] tx_block1_sys,
    output wire [BLOCK_BITS-1:0] tx_block2_sys,
    output wire [29:0]           tx_bb_sys,
    output wire                  tx_block_ready_sys
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

// ---- TX path ----------------------------------------------------------------
wire tx_enc_bit2_sys;
wire tx_enc_bit1_sys;
wire tx_enc_bit0_sys;
wire tx_enc_valid_sys;
wire [1:0] tx_punct_bits_sys;
wire       tx_punct_valid_sys;

wire tx_intlv_out_sys;
wire tx_intlv_valid_sys;
wire tx_intlv_done_sys;

wire tx_scr_out_sys;
wire tx_scr_valid_sys;

// CRC wires
wire rx_crc_next_ok_sys;

// Internal AACH decode wires (fed to both module outputs and steal_detect)
wire [13:0] rm_aach_data_w;
wire        rm_aach_done_w;
wire        rm_aach_error_w;

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
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .lfsr_init     (lfsr_init_sys),
    .load_init     (load_lfsr_sys),
    .data_in       (rx_block1_sys[BLOCK_BITS-1]),   // MSB-first stream
    .data_valid    (rx_slot_valid_sys),
    .data_out      (rx_descr_out_sys),
    .data_out_valid(rx_descr_valid_sys)
);

// ---- Step 2: Deinterleaver ───────────────────────────────────────────────────
tetra_interleaver #(
    .MAX_BLOCK_SIZE(432)
) u_rx_deinterleaver (
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .mode          (1'b1),           // 1 = Deinterleave (RX)
    .block_size    (9'd216),
    .data_in       (rx_descr_out_sys),
    .data_in_valid (rx_descr_valid_sys),
    .data_out      (rx_deintlv_out_sys),
    .data_out_valid(rx_deintlv_valid_sys),
    .block_done    (rx_deintlv_done_sys)
);

// ---- Step 3: Viterbi Decoder ─────────────────────────────────────────────────
// Hard-decision input: soft_bit_2 = data bit, soft_bit_1/0 = 0 (MSB = sign)
// (Full soft-decision: future work — requires LLR from demodulator)
tetra_viterbi_decoder #(
    .SOFT_WIDTH(3),
    .TRACEBACK (20),
    .MAX_STAGES(436)
) u_viterbi (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .soft_bit_0     ({2'b0, rx_deintlv_out_sys}),
    .soft_bit_1     (3'd0),
    .soft_bit_2     (3'd0),
    .input_valid    (rx_deintlv_valid_sys),
    .punct_pattern  (punct_pattern_sys),
    .decoded_bit    (rx_decoded_bit_sys),
    .decoded_valid  (rx_decoded_valid_sys),
    .block_done     (rx_block_done_sys),
    .path_metric_min(rx_path_metric_sys)
);

// ---- Step 4: CRC-16 (RX checker) ────────────────────────────────────────────
tetra_crc16 u_rx_crc (
    .clk_sys      (clk_sys),
    .rst_n_sys    (rst_n_sys),
    .data_in_sys  (rx_decoded_bit_sys),
    .data_valid_sys(rx_decoded_valid_sys),
    .init_sys     (rx_block_done_sys),
    .done_in_sys  (1'b0),          // continuous check mode
    .crc_out_sys  (),
    .crc_valid_sys(rx_crc_valid_sys),
    .crc_ok_sys   (rx_crc_ok_sys)
);

// ---- Step 5: Reed-Muller Decoder (BB / AACH) ─────────────────────────────────
tetra_reed_muller #(
    .N(30),
    .K(14)
) u_rm (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    // Decoder
    .decode_data_in (rx_bb_sys),
    .decode_valid   (rx_slot_valid_sys),
    .decode_data_out(rm_aach_data_w),
    .decode_done    (rm_aach_done_w),
    .decode_error   (rm_aach_error_w),
    // Encoder (TX path, wired below)
    .encode_data_in (tx_aach_in_sys),
    .encode_valid   (tx_aach_valid_sys),
    .encode_data_out(tx_bb_sys),
    .encode_done    (tx_block_ready_sys)
);

// ---- Module output assignments for AACH ──────────────────────────────────────
assign rx_aach_data_sys  = rm_aach_data_w;
assign rx_aach_done_sys  = rm_aach_done_w;
assign rx_aach_error_sys = rm_aach_error_w;

// ---- Steal detect (Phase 3: slot 0 only) ─────────────────────────────────────
wire [3:0] steal_active_w;

tetra_steal_detect u_steal_detect (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .aach_data_sys    (rm_aach_data_w),
    .aach_valid_sys   (rm_aach_done_w),
    .slot_num_sys     (2'd0),           // Phase 3: single-slot operation
    .burst_type_sys   (2'd0),           // NDB only
    .steal_active_sys (steal_active_w),
    .access_code0_sys (),
    .access_code1_sys (),
    .access_code2_sys (),
    .access_code3_sys ()
);

assign rx_stolen_sys = steal_active_w[0];

// =============================================================================
// TX PATH
// =============================================================================

// ---- Step 1: CRC-16 append (TX) ─────────────────────────────────────────────
// CRC appended in software (AXI-DMA payload already includes FCS).
// The CRC module here is used as a checker only (RX path, wired above).
// TX CRC: ARM software appends 16-bit FCS before DMA transfer.

// ---- Step 2: RCPC Encoder ────────────────────────────────────────────────────
tetra_rcpc_encoder #(
    .K(5)
) u_rcpc_encoder (
    .clk_sys      (clk_sys),
    .rst_n_sys    (rst_n_sys),
    .data_in      (tx_data_in_sys),
    .data_valid   (tx_data_valid_sys),
    .punct_pattern(punct_pattern_sys),
    .flush        (tx_flush_sys),
    .coded_bits   ({tx_enc_bit2_sys, tx_enc_bit1_sys, tx_enc_bit0_sys}),
    .coded_valid  (tx_enc_valid_sys),
    .punct_out_bits(tx_punct_bits_sys),
    .punct_valid  (tx_punct_valid_sys)
);

// ---- Step 3: Interleaver ─────────────────────────────────────────────────────
tetra_interleaver #(
    .MAX_BLOCK_SIZE(432)
) u_tx_interleaver (
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .mode          (1'b0),           // 0 = Interleave (TX)
    .block_size    (9'd216),
    .data_in       (tx_punct_bits_sys[0]),
    .data_in_valid (tx_punct_valid_sys),
    .data_out      (tx_intlv_out_sys),
    .data_out_valid(tx_intlv_valid_sys),
    .block_done    (tx_intlv_done_sys)
);

// ---- Step 4: Scrambler (TX) ──────────────────────────────────────────────────
tetra_scrambler #(
    .LFSR_WIDTH(LFSR_WIDTH)
) u_tx_scrambler (
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .lfsr_init     (lfsr_init_sys),
    .load_init     (load_lfsr_sys),
    .data_in       (tx_intlv_out_sys),
    .data_valid    (tx_intlv_valid_sys),
    .data_out      (tx_scr_out_sys),
    .data_out_valid(tx_scr_valid_sys)
);

// ---- TX block output (serial to parallel — accumulate into block bus) ─────────
// In Phase 3, the block bus is filled by the ARM via AXI-DMA (pre-encoded).
// The LMAC TX path (encoder → interleaver → scrambler) is instantiated here
// but feeds the DMA bridge input, not directly the burst_mux, in the current
// architecture. The output ports tx_block1_sys/tx_block2_sys are driven by
// the scrambler stream — full integration requires a serial-to-parallel
// accumulation buffer (future: integrate with AXI-DMA bridge MM2S path).

// For now: tie tx_block1/2 to zero (AXI-DMA provides encoded blocks directly)
assign tx_block1_sys = {BLOCK_BITS{1'b0}};
assign tx_block2_sys = {BLOCK_BITS{1'b0}};

endmodule
`default_nettype wire
