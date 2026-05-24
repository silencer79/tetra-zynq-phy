// =============================================================================
// tetra_facch_steal_mailbox.v — DL FACCH-Stealing Bit-Pipe (Phase 2)
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   AXI-writable storage holding pre-encoded SCH/HD type-5 BKN1 + BKN2 bits
//   (216 bits each = 432 bits total) that the burst_dispatcher emits in the
//   voice-slot as NDB2-burst when slot_mode[tn] != 0 (FACCH-Stealing mode).
//   SW is the encoder (CRC + conv + interleave + scramble for BKN1; analog
//   for BKN2 oder TCH-half).
//
//   Architektur-Parallele zu tetra_voice_filler_mailbox.v: gleiches
//   indirect-mailbox-Schema mit zwei separaten 16×32-bit-Banken (eine per
//   BKN). Zweite Mailbox damit BKN1 und BKN2 unabhängig staged werden können
//   (z.B. BKN1=D-RELEASE-SCH/HD, BKN2=SYSINFO-SCH/HD).
//
// Word layout pro Bank (16 × 32-bit):
//   W0..W6   type-5 bits 0..215 packed LSB-first (W6[23:0] = bits 192..215,
//            W6[31:24] padding=0)
//   W7..W14  reserved (=0)
//   W15[0]   bank_valid (SW writes 1 after loading W0..W6 + GO pulse;
//            cleared on reset or SW W15[0]=0)
//
//   Note: SCH/HD-type5 is 216 bits = 6.75 × 32-bit words. We use W0..W6 (7 words)
//   for storage; only bits 0..215 are read by burst_dispatcher.
//
// Outputs:
//   bkn1_sys[215:0]  = type-5 bits 0..215 from BKN1-bank
//   bkn2_sys[215:0]  = type-5 bits 0..215 from BKN2-bank
//   valid_sys        = bkn1_valid & bkn2_valid (both must be loaded)
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_facch_steal_mailbox (
 input wire clk_sys,
 input wire rst_n_sys,

 // BKN1 mailbox AXI-side (2-FF resynced clk_axi → clk_sys by caller)
 input wire [3:0] bkn1_index_sys,
 input wire [31:0] bkn1_wdata_sys,
 input wire bkn1_wr_en_sys,
 input wire bkn1_go_pulse_sys,
 output wire [31:0] bkn1_rdata_sys,

 // BKN2 mailbox AXI-side
 input wire [3:0] bkn2_index_sys,
 input wire [31:0] bkn2_wdata_sys,
 input wire bkn2_wr_en_sys,
 input wire bkn2_go_pulse_sys,
 output wire [31:0] bkn2_rdata_sys,

 // Field outputs to burst_dispatcher
 output wire [215:0] bkn1_out_sys,
 output wire [215:0] bkn2_out_sys,
 output wire valid_sys
);

 wire [16*32-1:0] bkn1_words_flat_w;
 wire [16*32-1:0] bkn2_words_flat_w;
 wire bkn1_go_out_w;
 wire bkn2_go_out_w;

 tetra_indirect_mailbox_wr u_bkn1_mb (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.index_sys (bkn1_index_sys),
.wdata_sys (bkn1_wdata_sys),
.wr_en_sys (bkn1_wr_en_sys),
.go_pulse_sys (bkn1_go_pulse_sys),
.rdata_sys (bkn1_rdata_sys),
.words_flat_sys (bkn1_words_flat_w),
.go_pulse_out_sys (bkn1_go_out_w)
 );

 tetra_indirect_mailbox_wr u_bkn2_mb (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.index_sys (bkn2_index_sys),
.wdata_sys (bkn2_wdata_sys),
.wr_en_sys (bkn2_wr_en_sys),
.go_pulse_sys (bkn2_go_pulse_sys),
.rdata_sys (bkn2_rdata_sys),
.words_flat_sys (bkn2_words_flat_w),
.go_pulse_out_sys (bkn2_go_out_w)
 );

 // Slice 216 bits out of W0..W6 (7 words × 32 = 224 bits, top 8 unused)
 assign bkn1_out_sys = bkn1_words_flat_w[215:0];
 assign bkn2_out_sys = bkn2_words_flat_w[215:0];

 // W15[0] = bank_valid per bank
 wire bkn1_valid = bkn1_words_flat_w[15*32];
 wire bkn2_valid = bkn2_words_flat_w[15*32];
 assign valid_sys = bkn1_valid & bkn2_valid;

 // Suppress unused-go warnings
 wire _unused_go = bkn1_go_out_w | bkn2_go_out_w;
 (* keep = "true" *) wire _unused_go_keep = _unused_go;

endmodule

`default_nettype wire
