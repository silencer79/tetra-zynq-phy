// =============================================================================
// tetra_voice_filler_mailbox.v — Voice-Slot Filler Bit-Pipe
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   AXI-writable 16-word storage holding a pre-encoded SCH/F type-5 burst
//   (432 bits) that the burst_dispatcher emits in the voice-slot during an
//   active group-call. SW is the encoder (CRC + conv + interleave + scramble);
//   this RTL module is just a bit-pipe. No new encoder/decoder logic per
//   project_arch_fpga_thin_signaling.md.
//
// Word layout (16 × 32-bit):
//   W0..W13  type-5 bits 0..431, packed LSB-first within each word
//            (W0[0]=bit 0, W0[31]=bit 31; W13[15:0]=bits 416..431,
//            W13[31:16] padding=0)
//   W14[0]   filler_valid (SW writes 1 after loading W0..W13 + GO pulse;
//            cleared on SW write of 0 or on reset)
//   W15      reserved (=0)
//
// Outputs (combinational, fanned out to burst_dispatcher):
//   blk1_sys[215:0]  = type-5 bits 0..215   (= BKN1, NDB1 layout)
//   blk2_sys[215:0]  = type-5 bits 216..431 (= BKN2)
//   valid_sys        = W14[0]
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_voice_filler_mailbox (
 input wire clk_sys,
 input wire rst_n_sys,

 // AXI-side write port (already 2-FF resynced clk_axi → clk_sys by caller)
 input wire [3:0] index_sys,
 input wire [31:0] wdata_sys,
 input wire wr_en_sys,
 input wire go_pulse_sys,

 // AXI-side read port (combinational mux)
 output wire [31:0] rdata_sys,

 // Field outputs to burst_dispatcher
 output wire [215:0] blk1_sys,
 output wire [215:0] blk2_sys,
 output wire valid_sys,
 output wire go_pulse_out_sys
);

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
.go_pulse_out_sys (go_pulse_out_sys)
 );

 // -----------------------------------------------------------------------
 // Slice 432 type-5 bits out of W0..W13 (14 words × 32 bit = 448 bits).
 //   bit n = words_flat_w[n], LSB-first per word.
 // BKN1 = bits 0..215 (NDB1 layout, MSB-first = first symbol on air).
 // BKN2 = bits 216..431.
 // SW must pack bits accordingly (see sw/tetra_voice_filler.c).
 // -----------------------------------------------------------------------
 assign blk1_sys = words_flat_w[ 215 :   0];
 assign blk2_sys = words_flat_w[ 431 : 216];

 // W14[0] = filler_valid
 assign valid_sys = words_flat_w[14*32];

endmodule

`default_nettype wire
