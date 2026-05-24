// =============================================================================
// tetra_facch_nub_read_mailbox.v — UL-NUB FACCH-Stealing Soft-Bits → SW Read-Mailbox
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   AXI-readable storage filled by tetra_ul_nub_capture (NTS2-triggered instance)
//   each time a FACCH-Stealing-Burst from UL-Voice-Slot is captured. Holds 432
//   signed SOFT_W-bit soft-values for SW SCH/HD soft-Viterbi decode (124-bit
//   info → CMCE parse → call_fsm).
//
//   Architektur-Parallele zu tetra_voice_nub_read_mailbox.v (= NTS1-Voice-Pfad):
//     u_ul_sync_nub (NTS1)  → u_ul_nub_capture       → voice_nub_read_mailbox  (existing)
//     u_ul_sync_facch (NTS2) → u_ul_facch_capture     → facch_nub_read_mailbox  (THIS FILE)
//
//   RTL ist bit-pipe only — descramble/deinterleave/Viterbi/CRC/parse in SW
//   per project_arch_fpga_thin_signaling.md.
//
// Word layout (SOFT_W=4 → 54 data words + valid):
//   W0..W53            coded_softs packed LSB-first; each 32-bit word holds
//                      8 nibbles (= 8 soft-values for SOFT_W=4).
//                      Within a word: word[i*4 +: 4] = soft[Wn*8+i]
//                      (= same flat indexing as coded_softs_sys input).
//   W54[0]             facch_valid (set on coded_valid_sys, cleared on ack_pulse_sys)
//
// SW protocol (analog REG_VOICE_NUB_READ_*):
//   1. Poll REG_FACCH_NUB_READ_STATUS[0]  — wait for facch_valid=1
//   2. Read INDEX=0..53 via REG_FACCH_NUB_READ_INDEX + REG_FACCH_NUB_READ_DATA
//   3. Pulse REG_FACCH_NUB_READ_ACK[0]=1 to clear valid + arm next burst
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_facch_nub_read_mailbox #(
 parameter SOFT_W = 4,
 parameter integer N_CODED = 432
) (
 input wire clk_sys,
 input wire rst_n_sys,

 // From tetra_ul_nub_capture (NTS2-trigger instance) — 432 signed soft-values
 input wire [N_CODED*SOFT_W-1:0] coded_softs_sys,
 input wire coded_valid_sys, // 1-cycle pulse — latch + set valid

 // From SW (CDC'd to clk_sys by caller)
 input wire ack_pulse_sys, // 1-cycle pulse — clear valid

 // AXI-side read port (combinational mux over storage)
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

 // Valid-Latch — set on capture, clear on SW ack. Capture-priority over ack.
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
