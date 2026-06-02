// =============================================================================
// tetra_ul_demand_reassembly.v — UL-Demand-Reassembly (Phase 7 F.1 / G.x)
// =============================================================================
//
// Joins the two SCH/HU bursts of an MS-initiated fragmented UL PDU into a
// single TM-SDU body (LLC header onwards) for SW protocol parsing. Generic:
// works for MM (U-LOC-UPDATE-DEMAND) AND CMCE (U-SDS-DATA), because the body
// now starts at the LLC header (tl_sdu_start) instead of the MM-body offset.
//
// On-air sequence (per docs/PROTOCOL.md §6.4a + reference_demand_reassembly_
// bitexact memory; corrected after Phase-7-F.1-Audit on 2026-04-26):
//
// UL#0 SCH/HU MAC-ACCESS (mac_pdu_type=0, frag=1)
// bits[tl_sdu_start..91] = 62 bit TM-SDU fragment 1 (sliced from bit 30
// at the top level; opt=1 leaves a 6-bit MAC-header lead-in that SW
// skips via the opt_flag metadata bit)
// UL#1 SCH/HU MAC-END-HU (mac_pdu_type=1)
// bits[ 7..91] = 85 bit TM-SDU fragment 2
//
// reassembled_body[0..146] = ul0_bits[30..91] (62) ++ ul1_bits[7..91] (85)
// = 147 bit, MSB-first (bit[146] = ul0_bits[30] = first TM-SDU bit on air)
//
// Buffer: 2 in-flight slots. The 2-slot capacity supports two MS completing
// the two-burst handshake in overlapping windows; in real ops this is rare
// but spec'd. Each slot stores SSI + 62-bit fragment 1 + 9-bit metadata +
// a T0 frame counter. T0 default = 2 frames (≈113 ms).
//
// Metadata (frag1_meta_sys[12:0], latched at fragment 1, emitted with body):
// [12:9] mm_pdu_type (MM-PDU subtype; RTL Pre-Reply BL-ACK/SlotGrant
// filter on mm∈{2,7}. Meaningless for CMCE.)
// [8:6] mle_disc (MLE protocol discriminator: MM vs CMCE)
// [5:2] llc_pdu_type ({link_type, has_fcs, bl_pdu_type[1:0]};
// 0=BL-ADATA, 1=BL-DATA, 3=BL-ACK)
// [1] llc_ns (BL-DATA send-sequence — SW needs it for the BL-ACK NR)
// [0] opt_flag (MAC optional-field flag → tl_sdu_start = opt?36:30;
// tells SW the LLC-start offset inside the body)
//
// Ports: SSI is 24-bit Ssi/ISSI/Ussi (parser already filters EventLabel).
// - frag1_pulse_sys: MAC-ACCESS frag=1 with mac_pdu_type=0 just decoded.
// The parser exposes this as `ul_pdu_valid_sys & ul_frag_flag_sys`,
// which is constructed at the top level.
// - frag1_ssi_sys / frag1_bits_sys[61:0]: latched fragment-1 fields.
// - end_hu_pulse_sys: MAC-END-HU just decoded.
// The parser exposes this as `ul_continuation_valid_sys`.
// - end_hu_ssi_sys / end_hu_bits_sys[84:0]: continuation fields from the
// parser (the parser carries the latched MAC-ACCESS frag=1 SSI through
// so we don't have to re-extract it here).
// - frame_tick_sys: 1-cycle pulse at every TDMA-frame boundary (~56.67 ms).
// Drives the T0 timer.
//
// Outputs:
// - reassembled_valid_sys: 1-cycle pulse when fragment 1 + 2 are joined
// within T0.
// - reassembled_body_sys[146:0]: 147-bit TM-SDU body, MSB-first.
// - reassembled_ssi_sys[23:0]: SSI of the joined PDU.
// - reassembled_meta_sys[8:0]: metadata bundle (see above).
// - reassembled_cnt_sys[15:0]: number of successful reassemblies.
// - drop_cnt_sys[15:0]: number of fragment-1 latches that timed out
// before a matching MAC-END-HU arrived.
// - busy_slots_sys[1:0]: one-hot view of the two slots (debug).
//
// =============================================================================

`default_nettype none

module tetra_ul_demand_reassembly #(
 parameter integer T0_FRAMES_DEFAULT = 2 // ETSI ≈ 2 frames = 113 ms
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // ------------- Configuration (from AXI-Lite, Phase F.3 will wire it) ----
 input wire [3:0] t0_frames_sys, // 0 → use default
 input wire frame_tick_sys, // 1 cycle / TDMA frame

 // ------------- Stimuli from MAC parser ----------------------------------
 input wire frag1_pulse_sys,
 input wire [23:0] frag1_ssi_sys,
 input wire [61:0] frag1_bits_sys, // ul0_bits[30..91], MSB-first (TM-SDU)
 // Phase 7 G.x — MAC-ACCESS frag=1 metadata from LLC/MLE parser. Latched
 // alongside frag1_bits_sys per slot; propagated to reassembled output.
 // [12:9]=mm_pdu_type, [8:6]=mle_disc, [5:2]=llc_pdu_type, [1]=ns, [0]=opt.
 input wire [12:0] frag1_meta_sys,

 input wire end_hu_pulse_sys,
 input wire [23:0] end_hu_ssi_sys,
 input wire [84:0] end_hu_bits_sys, // ul1_bits[7..91], MSB-first

 // ------------- Reassembled output ---------------------------------------
 output reg reassembled_valid_sys,
 output reg [146:0] reassembled_body_sys,
 output reg [23:0] reassembled_ssi_sys,
 output reg [12:0] reassembled_meta_sys,

 // ------------- Counters / debug -----------------------------------------
 output reg [15:0] reassembled_cnt_sys,
 output reg [15:0] drop_cnt_sys,
 output wire [1:0] busy_slots_sys
);

// =============================================================================
// 2-slot in-flight buffer. Verilog-2001: flat regs (no array of regs).
// Each slot: { occupied, ssi[23:0], frag1[61:0], meta[8:0], t0_left[3:0] }.
// =============================================================================

// Slot 0
reg s0_occ;
reg [23:0] s0_ssi;
reg [61:0] s0_frag1;
reg [3:0] s0_t0_left;
reg [12:0] s0_meta; // latched at frag1 (mm_type/mle_disc/llc_pdu_type/ns/opt)
// Slot 1
reg s1_occ;
reg [23:0] s1_ssi;
reg [61:0] s1_frag1;
reg [3:0] s1_t0_left;
reg [12:0] s1_meta; // latched at frag1 (mm_type/mle_disc/llc_pdu_type/ns/opt)

assign busy_slots_sys = {s1_occ, s0_occ};

// Effective T0 — fall back to default when AXI register is 0.
wire [3:0] t0_eff = (t0_frames_sys == 4'd0) ? T0_FRAMES_DEFAULT[3:0]
: t0_frames_sys;

// =============================================================================
// Match logic (combinational): for the END-HU pulse, find which slot's SSI
// matches. Slot 0 wins on tie (older). match_slot is only meaningful when
// `match_any` is asserted.
// =============================================================================
wire s0_match = s0_occ && (s0_ssi == end_hu_ssi_sys);
wire s1_match = s1_occ && (s1_ssi == end_hu_ssi_sys);
wire match_any = s0_match | s1_match;
wire match_slot = s0_match ? 1'b0: 1'b1; // 0 = slot 0, 1 = slot 1

// On a frag1 pulse, also detect SSI re-entry (same MS retransmits frag-1
// while a buffered fragment is still in flight). ETSI behaviour: replace
// the older fragment in the same slot, restart T0. (No drop count — this
// is a legitimate re-attempt.)
wire s0_replace = s0_occ && (s0_ssi == frag1_ssi_sys);
wire s1_replace = s1_occ && (s1_ssi == frag1_ssi_sys);

// Allocation of a fresh slot for a brand-new SSI — pick the first empty.
wire alloc_to_s0 = !s0_occ;
wire alloc_to_s1 = s0_occ && !s1_occ;
// If both are occupied and the SSI is new, we drop the new fragment 1 and
// bump drop_cnt_sys (simpler than evicting an in-flight reassembly mid-T0).
wire drop_new = s0_occ && s1_occ && !s0_replace && !s1_replace;

// Build the 147-bit reassembled body (slot-N's frag1 ++ end_hu_bits_sys),
// MSB-first. Bit 146 = first on-air TM-SDU bit (= UL#0 bit 30).
wire [146:0] reass_body_s0 = {s0_frag1, end_hu_bits_sys};
wire [146:0] reass_body_s1 = {s1_frag1, end_hu_bits_sys};

// =============================================================================
// Sequential — slot bookkeeping + outputs
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 s0_occ <= 1'b0;
 s0_ssi <= 24'd0;
 s0_frag1 <= 62'd0;
 s0_t0_left <= 4'd0;
 s0_meta <= 13'd0;
 s1_occ <= 1'b0;
 s1_ssi <= 24'd0;
 s1_frag1 <= 62'd0;
 s1_t0_left <= 4'd0;
 s1_meta <= 13'd0;
 reassembled_valid_sys <= 1'b0;
 reassembled_body_sys <= 147'd0;
 reassembled_ssi_sys <= 24'd0;
 reassembled_meta_sys <= 13'd0;
 reassembled_cnt_sys <= 16'd0;
 drop_cnt_sys <= 16'd0;
 end else begin
 // Default: pulse outputs deassert each cycle.
 reassembled_valid_sys <= 1'b0;

 // ---------------------------------------------------------------
 // T0 timer tick (one cycle per TDMA frame). Decrement; on reaching
 // 0 the slot is freed and drop_cnt bumped.
 // ---------------------------------------------------------------
 if (frame_tick_sys) begin
 if (s0_occ) begin
 if (s0_t0_left == 4'd1) begin
 s0_occ <= 1'b0;
 drop_cnt_sys<= drop_cnt_sys + 16'd1;
 end
 s0_t0_left <= (s0_t0_left == 4'd0) ? 4'd0
: (s0_t0_left - 4'd1);
 end
 if (s1_occ) begin
 if (s1_t0_left == 4'd1) begin
 s1_occ <= 1'b0;
 drop_cnt_sys<= drop_cnt_sys + 16'd1;
 end
 s1_t0_left <= (s1_t0_left == 4'd0) ? 4'd0
: (s1_t0_left - 4'd1);
 end
 end

 // ---------------------------------------------------------------
 // Fragment 1 arrival. Same-SSI replace > slot allocation > drop.
 // ---------------------------------------------------------------
 if (frag1_pulse_sys) begin
 if (s0_replace) begin
 s0_frag1 <= frag1_bits_sys;
 s0_meta <= frag1_meta_sys;
 s0_t0_left <= t0_eff;
 end else if (s1_replace) begin
 s1_frag1 <= frag1_bits_sys;
 s1_meta <= frag1_meta_sys;
 s1_t0_left <= t0_eff;
 end else if (alloc_to_s0) begin
 s0_occ <= 1'b1;
 s0_ssi <= frag1_ssi_sys;
 s0_frag1 <= frag1_bits_sys;
 s0_meta <= frag1_meta_sys;
 s0_t0_left <= t0_eff;
 end else if (alloc_to_s1) begin
 s1_occ <= 1'b1;
 s1_ssi <= frag1_ssi_sys;
 s1_frag1 <= frag1_bits_sys;
 s1_meta <= frag1_meta_sys;
 s1_t0_left <= t0_eff;
 end else if (drop_new) begin
 drop_cnt_sys <= drop_cnt_sys + 16'd1;
 end
 end

 // ---------------------------------------------------------------
 // MAC-END-HU arrival. If the SSI matches a slot, splice and emit.
 // Otherwise drop silently (no slot existed → fragment 1 either
 // never arrived or already T0-expired; the parser still emits the
 // pulse but we discard). We don't bump drop_cnt for orphan ENDs
 // because that counter is reserved for fragment-1 timeouts.
 // ---------------------------------------------------------------
 if (end_hu_pulse_sys && match_any) begin
 if (match_slot == 1'b0) begin
 reassembled_body_sys <= reass_body_s0;
 reassembled_ssi_sys <= s0_ssi;
 reassembled_meta_sys <= s0_meta;
 s0_occ <= 1'b0;
 end else begin
 reassembled_body_sys <= reass_body_s1;
 reassembled_ssi_sys <= s1_ssi;
 reassembled_meta_sys <= s1_meta;
 s1_occ <= 1'b0;
 end
 reassembled_valid_sys <= 1'b1;
 reassembled_cnt_sys <= reassembled_cnt_sys + 16'd1;
 end
 end
end

endmodule

`default_nettype wire
