// =============================================================================
// tetra_voice_nub_read_mailbox.v — UL-NUB Soft-Bits → SW Read-Mailbox
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   AXI-readable storage filled by tetra_ul_nub_capture each time it demods a
//   NUB burst. Holds 432 signed SOFT_W-bit soft-values for SW soft-Viterbi.
//   RTL is bit-pipe only — descramble/deinterleave/Viterbi/re-encode in SW
//   per project_arch_fpga_thin_signaling.md.
//
// Word layout (Phase E2 — SOFT_W=4 → 54 data words + valid):
//   W0..W(NUM_WORDS-1)   coded_softs packed LSB-first; each 32-bit word holds
//                        32 / SOFT_W = 8 nibbles (= 8 soft-values for SOFT_W=4).
//                        Within a word: word[i*SOFT_W +: SOFT_W] = soft[Wn*8+i]
//                        (= same flat indexing as coded_softs_sys input).
//   W(NUM_WORDS)[0]      nub_valid (set on coded_valid_sys, cleared on ack_pulse_sys)
//
// SW protocol:
//   1. Poll REG_VOICE_NUB_READ_STATUS[0]  — wait for nub_valid=1
//   2. Read INDEX=0..NUM_WORDS-1 via REG_VOICE_NUB_READ_INDEX + REG_VOICE_NUB_READ_DATA
//   3. Pulse REG_VOICE_NUB_READ_ACK[0]=1 to clear nub_valid + arm next burst
//
// Backward compatibility note:
//   Old layout was 14 words × 1-bit per coded-bit (= 432 hard bits). New
//   layout is wider (SOFT_W bits per coded-bit). SW must read 54 words
//   instead of 14 and unpack nibbles. Sign-bit of each soft = legacy
//   hard-decision value.
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_voice_nub_read_mailbox #(
 parameter SOFT_W = 4,
 parameter integer N_CODED = 432
) (
 input wire clk_sys,
 input wire rst_n_sys,

 // From tetra_ul_nub_capture — 432 signed soft-values, SOFT_W bits each
 input wire [N_CODED*SOFT_W-1:0] coded_softs_sys,
 input wire coded_valid_sys, // 1-cycle pulse — latch + set valid

 // From SW (CDC'd to clk_sys by caller)
 input wire ack_pulse_sys, // 1-cycle pulse — clear valid

 // AXI-side read port (combinational mux over storage). Index width matches
 // NUM_WORDS+1 (extra for valid-word).
 input wire [5:0] index_sys,
 output wire [31:0] rdata_sys,

 // Status for AXI-side polling
 output wire valid_sys
);

 // Total payload bits and number of 32-bit words. For SOFT_W=4, N_CODED=432:
 // PAYLOAD_BITS=1728, NUM_WORDS=54.
 localparam integer PAYLOAD_BITS = N_CODED * SOFT_W;
 localparam integer NUM_WORDS    = PAYLOAD_BITS / 32;

 // Storage: NUM_WORDS × 32-bit + valid latch.
 reg [31:0] words_r_sys [0:NUM_WORDS-1];
 reg        valid_r_sys;

 integer i;
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 for (i = 0; i < NUM_WORDS; i = i + 1)
 words_r_sys[i] <= 32'd0;
 end else if (coded_valid_sys) begin
 // Pack coded_softs into 32-bit words LSB-first. Requires PAYLOAD_BITS
 // multiple of 32 (true for SOFT_W=4, N_CODED=432: 1728 = 54*32).
 for (i = 0; i < NUM_WORDS; i = i + 1)
 words_r_sys[i] <= coded_softs_sys[i*32 +: 32];
 end
 end

 // Valid-Latch — set on capture, clear on SW ack. Capture-priority over ack
 // (= if both pulses on same cycle, the new burst wins).
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)           valid_r_sys <= 1'b0;
 else if (coded_valid_sys) valid_r_sys <= 1'b1;
 else if (ack_pulse_sys)   valid_r_sys <= 1'b0;
 end

 // Combinational read mux: index 0..NUM_WORDS-1 → data; index NUM_WORDS → valid.
 reg [31:0] rdata_mux_sys;
 always @(*) begin
 if (index_sys < NUM_WORDS[5:0]) begin
 rdata_mux_sys = words_r_sys[index_sys];
 end else if (index_sys == NUM_WORDS[5:0]) begin
 rdata_mux_sys = {31'd0, valid_r_sys};
 end else begin
 rdata_mux_sys = 32'd0;
 end
 end

 assign rdata_sys = rdata_mux_sys;
 assign valid_sys = valid_r_sys;

endmodule

`default_nettype wire
