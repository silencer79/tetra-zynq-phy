// =============================================================================
// tetra_voice_relay.v — UL→DL Bit-Transparent Voice-Burst Relay
// =============================================================================
//
// Purpose:
// Buffer one 432-bit UL TCH/S NUB payload (BKN1+BKN2 type-5 coded bits)
// captured by tetra_ul_nub_capture, expose it to tetra_burst_dispatcher
// for emit on the next DL voice-slot. In TMO (ESN=0) the cell scrambler
// is identical UL+DL → no descramble/rescramble needed; bits pass through
// bit-transparent.
//
// Buffer policy:
// - Latch ul_coded_bits on ul_coded_valid pulse, mark buffer fresh.
// - Each emit (= dl_slot_pulse on voice_slot_tn) increments age counter.
// - When age ≥ TIMEOUT_FRAMES (default 2) WITHOUT a fresh refresh, drop
// relay_valid → dispatcher falls back to static schedule.
// - Allows ~113 ms gap before voice mute (MS-side retransmit margin).
//
// Outputs to burst_dispatcher:
// relay_blk_sys[431:216] = BKN1 (= ul_coded_bits[431:216] from capture)
// relay_blk_sys[215:0] = BKN2
// relay_valid_sys = fresh-buffer + voice-active gate (asserted
// continuously while buffer is alive; dispatcher
// latches its content per voice slot)
//
// SW-visibility:
// relay_cnt_sys = counter, incremented each voice-slot emit
//
// Resource estimate (Zynq-7020):
// LUT ≈ 80 FF ≈ 460 BRAM = 0 DSP = 0
//
// =============================================================================

`default_nettype none

module tetra_voice_relay #(
 parameter TIMEOUT_FRAMES = 2 // frames without refresh before mute
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // Voice-channel state (CDC-resynced upstream)
 input wire [3:0] voice_active_mask_sys,
 input wire [1:0] voice_slot_tn_sys, // 0..3, target voice TN

 // UL-captured payload from tetra_ul_nub_capture
 input wire [431:0] ul_coded_bits_sys,
 input wire ul_coded_valid_sys,

 // DL TDMA pulse from timebase (to track per-frame age + count emits)
 input wire dl_slot_pulse_sys,
 input wire [1:0] dl_tn_sys,

 // To burst_dispatcher
 output reg [431:0] relay_blk_sys,
 output reg relay_valid_sys,

 // Debug / AXI visibility
 output reg [15:0] relay_cnt_sys
);

reg buf_valid_sys;
reg [3:0] buf_age_frames_sys;

// voice-active gate: mask must have voice_slot_tn bit set
wire voice_active_gate_w = voice_active_mask_sys[voice_slot_tn_sys];

// emit-slot detection
wire emit_slot_w = dl_slot_pulse_sys & (dl_tn_sys == voice_slot_tn_sys);

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 relay_blk_sys <= 432'd0;
 relay_valid_sys <= 1'b0;
 buf_valid_sys <= 1'b0;
 buf_age_frames_sys <= 4'd0;
 relay_cnt_sys <= 16'd0;
 end else begin
 // Fresh UL payload — latch + reset age
 if (ul_coded_valid_sys) begin
 relay_blk_sys <= ul_coded_bits_sys;
 buf_valid_sys <= 1'b1;
 buf_age_frames_sys <= 4'd0;
 end

 // Emit-slot bookkeeping
 if (emit_slot_w && buf_valid_sys && voice_active_gate_w) begin
 relay_cnt_sys <= relay_cnt_sys + 16'd1;
 if (buf_age_frames_sys >= TIMEOUT_FRAMES[3:0]) begin
 // Buffer too stale — drop
 buf_valid_sys <= 1'b0;
 end else begin
 buf_age_frames_sys <= buf_age_frames_sys + 4'd1;
 end
 end

 // Clear buffer immediately if voice goes inactive
 if (!voice_active_gate_w) begin
 buf_valid_sys <= 1'b0;
 buf_age_frames_sys <= 4'd0;
 end

 // Output combinatorial-equivalent (registered for downstream timing)
 relay_valid_sys <= buf_valid_sys
 & voice_active_gate_w
 & (buf_age_frames_sys < TIMEOUT_FRAMES[3:0]);
 end
end

endmodule

`default_nettype wire
