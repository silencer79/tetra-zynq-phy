// =============================================================================
// tetra_voice_nub_read_mailbox.v — Phase B: UL-NUB-Bits → SW Read-Mailbox
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   16-word AXI-readable storage filled by tetra_ul_nub_capture each time it
//   demods a 432-bit UL TCH/S burst. SW polls the valid-Flag, reads the bits
//   out, runs descramble + Viterbi + SSI-Patch + re-encode in SW, then
//   writes the patched type-5 bits into tetra_voice_filler_mailbox for the
//   DL emit. RTL is bit-pipe only — no decoder/encoder, per
//   project_arch_fpga_thin_signaling.md.
//
// Word layout (16 × 32-bit):
//   W0..W13   type-5 bits 0..431 packed LSB-first within each word
//             (matches tetra_voice_filler_mailbox convention)
//   W14[0]    nub_valid (set on coded_valid_sys, cleared on ack_pulse_sys)
//   W14[31:1] reserved (=0)
//   W15       reserved (=0)
//
// SW protocol:
//   1. Poll REG_VOICE_NUB_READ_STATUS[0]  — wait for nub_valid=1
//   2. Read INDEX=0..13 via REG_VOICE_NUB_READ_INDEX + REG_VOICE_NUB_READ_DATA
//   3. Pulse REG_VOICE_NUB_READ_ACK[0]=1 to clear nub_valid + arm next burst
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_voice_nub_read_mailbox (
 input wire clk_sys,
 input wire rst_n_sys,

 // From tetra_ul_nub_capture
 input wire [431:0] coded_bits_sys,
 input wire coded_valid_sys, // 1-cycle pulse — latch + set valid

 // From SW (CDC'd to clk_sys by caller)
 input wire ack_pulse_sys, // 1-cycle pulse — clear valid

 // AXI-side read port (combinational mux over storage)
 input wire [3:0] index_sys,
 output wire [31:0] rdata_sys,

 // Status for AXI-side polling
 output wire valid_sys
);

 // Storage: 14 × 32-bit for 432 bits + valid latch
 reg [31:0] w0_r_sys;
 reg [31:0] w1_r_sys;
 reg [31:0] w2_r_sys;
 reg [31:0] w3_r_sys;
 reg [31:0] w4_r_sys;
 reg [31:0] w5_r_sys;
 reg [31:0] w6_r_sys;
 reg [31:0] w7_r_sys;
 reg [31:0] w8_r_sys;
 reg [31:0] w9_r_sys;
 reg [31:0] w10_r_sys;
 reg [31:0] w11_r_sys;
 reg [31:0] w12_r_sys;
 reg [31:0] w13_r_sys;
 reg valid_r_sys;

 // Pack 432 bits LSB-first into 14 words; same convention as
 // tetra_voice_filler_mailbox.v so SW round-trip uses identical layout.
 //   type5[i] → words[i/32][(i % 32)]
 // i.e., coded_bits_sys[i] → w(i/32)[i%32].
 // Each always block follows R1 (one register per block).

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w0_r_sys <= 32'd0;
 else if (coded_valid_sys) w0_r_sys <= coded_bits_sys[ 31:  0];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w1_r_sys <= 32'd0;
 else if (coded_valid_sys) w1_r_sys <= coded_bits_sys[ 63: 32];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w2_r_sys <= 32'd0;
 else if (coded_valid_sys) w2_r_sys <= coded_bits_sys[ 95: 64];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w3_r_sys <= 32'd0;
 else if (coded_valid_sys) w3_r_sys <= coded_bits_sys[127: 96];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w4_r_sys <= 32'd0;
 else if (coded_valid_sys) w4_r_sys <= coded_bits_sys[159:128];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w5_r_sys <= 32'd0;
 else if (coded_valid_sys) w5_r_sys <= coded_bits_sys[191:160];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w6_r_sys <= 32'd0;
 else if (coded_valid_sys) w6_r_sys <= coded_bits_sys[223:192];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w7_r_sys <= 32'd0;
 else if (coded_valid_sys) w7_r_sys <= coded_bits_sys[255:224];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w8_r_sys <= 32'd0;
 else if (coded_valid_sys) w8_r_sys <= coded_bits_sys[287:256];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w9_r_sys <= 32'd0;
 else if (coded_valid_sys) w9_r_sys <= coded_bits_sys[319:288];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w10_r_sys <= 32'd0;
 else if (coded_valid_sys) w10_r_sys <= coded_bits_sys[351:320];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w11_r_sys <= 32'd0;
 else if (coded_valid_sys) w11_r_sys <= coded_bits_sys[383:352];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w12_r_sys <= 32'd0;
 else if (coded_valid_sys) w12_r_sys <= coded_bits_sys[415:384];
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) w13_r_sys <= 32'd0;
 else if (coded_valid_sys) w13_r_sys <= coded_bits_sys[431:416] & 32'h0000_FFFF;
 end

 // Valid-Latch — set on capture, clear on SW ack. capture-priority over ack
 // (= if both pulses on same cycle, the new burst wins — SW gets a fresh
 // valid burst rather than dropping the new one because of stale ack).
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)         valid_r_sys <= 1'b0;
 else if (coded_valid_sys) valid_r_sys <= 1'b1;
 else if (ack_pulse_sys)   valid_r_sys <= 1'b0;
 end

 // Combinational read mux.
 reg [31:0] rdata_mux_sys;
 always @(*) begin
 case (index_sys)
 4'd0: rdata_mux_sys = w0_r_sys;
 4'd1: rdata_mux_sys = w1_r_sys;
 4'd2: rdata_mux_sys = w2_r_sys;
 4'd3: rdata_mux_sys = w3_r_sys;
 4'd4: rdata_mux_sys = w4_r_sys;
 4'd5: rdata_mux_sys = w5_r_sys;
 4'd6: rdata_mux_sys = w6_r_sys;
 4'd7: rdata_mux_sys = w7_r_sys;
 4'd8: rdata_mux_sys = w8_r_sys;
 4'd9: rdata_mux_sys = w9_r_sys;
 4'd10: rdata_mux_sys = w10_r_sys;
 4'd11: rdata_mux_sys = w11_r_sys;
 4'd12: rdata_mux_sys = w12_r_sys;
 4'd13: rdata_mux_sys = w13_r_sys;
 4'd14: rdata_mux_sys = {31'd0, valid_r_sys};
 default: rdata_mux_sys = 32'd0;
 endcase
 end

 assign rdata_sys = rdata_mux_sys;
 assign valid_sys = valid_r_sys;

endmodule

`default_nettype wire
