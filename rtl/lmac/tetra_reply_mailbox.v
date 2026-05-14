// =============================================================================
// tetra_reply_mailbox.v — Phase X.2 SW-Pulled Reply Mailbox (clk_sys)
// Project: tetra-zynq-phy
// Standard: ETSI EN 300 392-2 (D-LOC-UPDATE-ACCEPT + D-ATTACH-DETACH-GRP-ID-
// ACK body fields, Phase Y.2 raw-mode extension)
// =============================================================================
// Y.1.0 refactor: thin wrapper over generic `tetra_indirect_mailbox_wr`.
// Holds the PDU-specific field-output slices over the 16-word storage and
// passes the AXI write/read paths through to the shared block.
// Module header / behavior bit-exact preserved (tb_reply_mailbox 32/32).
//
// Y.2 extension (Variante A — multi-PDU via raw-mode flag): re-uses the
// same mailbox window for D-ATTACH-DETACH-GRP-ID-ACK by adding a SW-built
// raw MM-bit payload in W9..W13. When mb_raw_mode_flag_sys=1 the MLE-FSM
// bypasses the dloc encoder and routes raw bits directly into the shared
// DL-PDU builder. mm=2 ACCEPT path (raw_mode_flag=0) stays bit-identical.
//
// Word layout (verbindlich):
// W0 [31:24] 8'd0 [23: 0] ssi[23:0]
// W1 [31:14] 18'd0 [13: 0] la[13:0]
// W2 [31: 3] 29'd0 [ 2: 0] addr_type[2:0]
// W3 [31: 2] 30'd0 [ 1: 0] result[1:0]
// W4 [31:24] 8'd0 [23: 0] gila_gssi[23:0]
// W5 [31: 5] 27'd0 [4:2] gila_class[2:0] [1:0] gila_lifetime[1:0]
// W6 [31: 1] 31'd0 [ 0] gila_present
// W7 [31: 2] 30'd0 [ 1: 0] encryption[1:0] (Reserved)
// W8 [31: 2] 30'd0 [ 1: 0] auth_result[1:0] (Reserved)
// W9 [31] raw_mode_flag [30:13] 18'd0
// [12:10] raw_mle_pd (Phase 7 G.4: 0=defaultMM, 1=MM, 2=CMCE)
// [9] raw_nr [8] raw_ns
// [7: 0] raw_mm_len[7:0] (Phase Y.2)
// W10 [31: 0] raw_mm_bits[31: 0] (Phase Y.2)
// W11 [31: 0] raw_mm_bits[63:32] (Phase Y.2)
// W12 [31: 0] raw_mm_bits[95:64] (Phase Y.2)
// W13 [31: 0] raw_mm_bits[127:96] (Phase Y.2)
// W14..W15 32'd0 (reserved Phase X.4)
//
// Y.2 raw-mode field outputs:
// mb_raw_mode_flag_sys (1 bit) — 1 = consume raw bits, bypass dloc enc
// mb_raw_mm_bits_sys (128 bit) — pre-built MM body, MSB at bit 127
// mb_raw_mm_len_sys (8 bit) — number of valid raw bits (≤ 128)
// mb_raw_ns_sys (1 bit) — LLC sequence number (BL-ADATA)
// mb_raw_nr_sys (1 bit) — LLC ack number (BL-ADATA)
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_reply_mailbox (
 input wire clk_sys,
 input wire rst_n_sys,

 // ------------------------------------------------------------------
 // AXI-side write port (already 2-FF resynced clk_axi → clk_sys by caller).
 // SW writes data to W[index] when wr_en_sys is held, then pulses go.
 // ------------------------------------------------------------------
 input wire [3:0] index_sys,
 input wire [31:0] wdata_sys,
 input wire wr_en_sys, // 1 = commit wdata_sys → words[index]
 input wire go_pulse_sys, // 1-cycle pulse → mb_go_pulse_sys

 // ------------------------------------------------------------------
 // AXI-side read port (combinational mux).
 // ------------------------------------------------------------------
 output wire [31:0] rdata_sys,

 // ------------------------------------------------------------------
 // Field outputs — fanned out to MLE-FSM (clk_sys domain).
 // ------------------------------------------------------------------
 output wire [23:0] mb_ssi_sys,
 output wire [13:0] mb_la_sys,
 output wire [2:0] mb_addr_type_sys,
 output wire [1:0] mb_result_sys,
 output wire [23:0] mb_gila_gssi_sys,
 output wire [2:0] mb_gila_class_sys,
 output wire [1:0] mb_gila_lifetime_sys,
 output wire mb_gila_present_sys,
 output wire [1:0] mb_encryption_sys,
 output wire [1:0] mb_auth_result_sys,
 output wire mb_go_pulse_sys,

 // Phase Y.2 — raw-mode MM-body bypass (Variante A).
 // raw_mode_flag=1 selects raw_mm_bits/raw_mm_len in the MLE-FSM build
 // path, skipping the dloc encoder. raw_mode_flag=0 → legacy mm=2 path.
 output wire mb_raw_mode_flag_sys,
 output wire [127:0] mb_raw_mm_bits_sys,
 output wire [7:0] mb_raw_mm_len_sys,
 output wire mb_raw_ns_sys,
 output wire mb_raw_nr_sys,
 /* Phase 7 G.4 — MLE-PD selector decoded from W9[12:10].
 * 0b000 = default MM (legacy / grpack)
 * 0b001 = MM
 * 0b010 = CMCE (D-CONNECT / D-TX-GRANTED / D-RELEASE / …) */
 output wire [2:0] mb_raw_mle_pd_sys
);

 // -----------------------------------------------------------------------
 // Generic 16-word indirect-write storage + read-mux + GO passthrough.
 // -----------------------------------------------------------------------
 wire [16*32-1:0] words_flat_w;

 tetra_indirect_mailbox_wr u_imbox_wr (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.index_sys (index_sys),
.wdata_sys (wdata_sys),
.wr_en_sys (wr_en_sys),
.go_pulse_sys (go_pulse_sys),
.rdata_sys (rdata_sys),
.words_flat_sys (words_flat_w),
.go_pulse_out_sys (mb_go_pulse_sys)
 );

 // -----------------------------------------------------------------------
 // Word-name aliases — slice out W0..W8 for the field-decoders.
 // words_flat_w packing (LSB → MSB): W0, W1, W2,..., W15.
 // -----------------------------------------------------------------------
 wire [31:0] w0_w = words_flat_w[ 0*32 +: 32];
 wire [31:0] w1_w = words_flat_w[ 1*32 +: 32];
 wire [31:0] w2_w = words_flat_w[ 2*32 +: 32];
 wire [31:0] w3_w = words_flat_w[ 3*32 +: 32];
 wire [31:0] w4_w = words_flat_w[ 4*32 +: 32];
 wire [31:0] w5_w = words_flat_w[ 5*32 +: 32];
 wire [31:0] w6_w = words_flat_w[ 6*32 +: 32];
 wire [31:0] w7_w = words_flat_w[ 7*32 +: 32];
 wire [31:0] w8_w = words_flat_w[ 8*32 +: 32];
 wire [31:0] w9_w = words_flat_w[ 9*32 +: 32];
 wire [31:0] w10_w = words_flat_w[10*32 +: 32];
 wire [31:0] w11_w = words_flat_w[11*32 +: 32];
 wire [31:0] w12_w = words_flat_w[12*32 +: 32];
 wire [31:0] w13_w = words_flat_w[13*32 +: 32];

 // -----------------------------------------------------------------------
 // Field-decoders — pure combinational slice on the mailbox latches.
 // Updates as soon as SW writes a word; mb_go_pulse_sys signals the FSM
 // that the staged payload is ready.
 // -----------------------------------------------------------------------
 assign mb_ssi_sys = w0_w[23:0];
 assign mb_la_sys = w1_w[13:0];
 assign mb_addr_type_sys = w2_w[2:0];
 assign mb_result_sys = w3_w[1:0];
 assign mb_gila_gssi_sys = w4_w[23:0];
 assign mb_gila_class_sys = w5_w[4:2];
 assign mb_gila_lifetime_sys = w5_w[1:0];
 assign mb_gila_present_sys = w6_w[0];
 assign mb_encryption_sys = w7_w[1:0];
 assign mb_auth_result_sys = w8_w[1:0];

 // Phase Y.2 — raw-mode bypass field outputs. W9..W13 are zero out of
 // reset so legacy mm=2 staging (W0..W8 only) reports raw_mode_flag=0.
 assign mb_raw_mode_flag_sys = w9_w[31];
 assign mb_raw_nr_sys = w9_w[9];
 assign mb_raw_ns_sys = w9_w[8];
 assign mb_raw_mm_len_sys = w9_w[7:0];
 assign mb_raw_mm_bits_sys = { w13_w, w12_w, w11_w, w10_w };
 assign mb_raw_mle_pd_sys = w9_w[12:10];

endmodule

`default_nettype wire
