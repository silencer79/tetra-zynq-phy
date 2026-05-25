// =============================================================================
// tetra_voice_filler_mailbox.v — Voice-Slot Filler Bit-Pipe (Multi-Group)
// Project: tetra-zynq-phy
// =============================================================================
// Purpose:
//   AXI-writable 16-word indirect mailbox holding pre-encoded SCH/F type-5
//   bursts (432 bits) per ETSI Timeslot. burst_dispatcher emits the per-TS
//   burst in the matching voice-slot during an active group-call.
//
//   Multi-Group 2026-05-25: 4 independent storage banks, one per ETSI TS1..TS4.
//   SW writes one staging buffer (W0..W13), then commits to a specific bank
//   via W14[3:1]=target_ts (1..4) + W14[0]=valid (1=set, 0=clear).
//
// Word layout (16 × 32-bit):
//   W0..W13  type-5 bits 0..431, packed LSB-first within each word
//            (Stage-Buffer — wird beim GO-Puls in den Ziel-Bank kopiert)
//   W14[0]   commit valid bit (1 = set valid[target_ts-1], 0 = clear)
//   W14[3:1] target_ts (1..4, ETSI 1-based). 0 = legacy → wirkt auf TS2.
//   W14[31:4] reserved (=0)
//   W15      reserved (=0)
//
// Outputs (combinational, fanned out to burst_dispatcher):
//   blk1_per_ts_sys[864-1:0]  4 × 216-bit type-5 bits 0..215 per TS
//                              (LSB block = TS1, MSB block = TS4)
//   blk2_per_ts_sys[864-1:0]  4 × 216-bit type-5 bits 216..431 per TS
//   valid_per_ts_sys[3:0]     filler-valid per TS (bit 0 = TS1 ... bit 3 = TS4)
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

 // Field outputs to burst_dispatcher — per-TS flat bus
 output wire [4*216-1:0] blk1_per_ts_sys,
 output wire [4*216-1:0] blk2_per_ts_sys,
 output reg  [3:0]       valid_per_ts_sys,
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
 // Stage buffer = W0..W13 (432-bit type-5 burst, LSB-first per word).
 // BKN1 = bits 0..215 (NDB1 layout, MSB-first = first symbol on air).
 // BKN2 = bits 216..431.
 // -----------------------------------------------------------------------
 wire [215:0] stage_blk1_w = words_flat_w[215:0];
 wire [215:0] stage_blk2_w = words_flat_w[431:216];

 // W14 commit fields
 wire commit_valid_w = words_flat_w[14*32 + 0];
 wire [2:0] commit_target_ts_w = words_flat_w[14*32 + 3 : 14*32 + 1];

 // Map target_ts (1..4) → bank index (0..3); 0/5+ → default TS2 (bank 1)
 wire [1:0] commit_bank_w =
   (commit_target_ts_w == 3'd1) ? 2'd0
 : (commit_target_ts_w == 3'd2) ? 2'd1
 : (commit_target_ts_w == 3'd3) ? 2'd2
 : (commit_target_ts_w == 3'd4) ? 2'd3
 :                                2'd1;

 // -----------------------------------------------------------------------
 // 4 storage banks — copy stage on GO into the selected bank.
 // -----------------------------------------------------------------------
 reg [215:0] bank_blk1_sys [3:0];
 reg [215:0] bank_blk2_sys [3:0];

 integer i;
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 for (i = 0; i < 4; i = i + 1) begin
 bank_blk1_sys[i] <= 216'd0;
 bank_blk2_sys[i] <= 216'd0;
 end
 valid_per_ts_sys <= 4'b0000;
 end else if (go_pulse_out_sys) begin
 if (commit_valid_w) begin
 bank_blk1_sys[commit_bank_w] <= stage_blk1_w;
 bank_blk2_sys[commit_bank_w] <= stage_blk2_w;
 valid_per_ts_sys[commit_bank_w] <= 1'b1;
 end else begin
 valid_per_ts_sys[commit_bank_w] <= 1'b0;
 end
 end
 end

 // -----------------------------------------------------------------------
 // Flat outputs — TS1 = blk[215:0], TS2 = blk[431:216], TS3 = blk[647:432],
 // TS4 = blk[863:648].
 // -----------------------------------------------------------------------
 assign blk1_per_ts_sys = {bank_blk1_sys[3], bank_blk1_sys[2],
                           bank_blk1_sys[1], bank_blk1_sys[0]};
 assign blk2_per_ts_sys = {bank_blk2_sys[3], bank_blk2_sys[2],
                           bank_blk2_sys[1], bank_blk2_sys[0]};

endmodule

`default_nettype wire
