// =============================================================================
// tetra_ul_demand_reassembly.v — UL-Demand-Reassembly (Phase 7 F.1)
// =============================================================================
//
// Joins the two SCH/HU bursts of an MS-initiated U-LOC-UPDATE-DEMAND into a
// single 129-bit MM body for the downstream MLE-FSM IE-parser (Phase F.2).
//
// On-air sequence (per docs/PROTOCOL.md §6.4a + reference_demand_reassembly_
// bitexact memory; corrected after Phase-7-F.1-Audit on 2026-04-26):
//
//   UL#0  SCH/HU  MAC-ACCESS  (mac_pdu_type=0, frag=1)
//                  bits[48..91] = 44 bit MM-body fragment 1
//   UL#1  SCH/HU  MAC-END-HU  (mac_pdu_type=1)
//                  bits[ 7..91] = 85 bit MM-body fragment 2
//
//   reassembled_body[0..128] = ul0_bits[48..91] (44) ++ ul1_bits[7..91] (85)
//                            = 129 bit
//
// Buffer: 144 bit × 2 in-flight slots.  The 2-slot capacity supports two MS
// completing the two-burst handshake in overlapping windows; in real ops
// this is rare but spec'd.  Each slot stores SSI + 44-bit fragment 1 + a
// T0 frame counter.  T0 default = 2 frames (≈113 ms).
//
// Ports: SSI is 24-bit Ssi/ISSI/Ussi (parser already filters EventLabel).
//   - frag1_pulse_sys: MAC-ACCESS frag=1 with mac_pdu_type=0 just decoded.
//     The parser exposes this as `ul_pdu_valid_sys & ul_frag_flag_sys`,
//     which is constructed at the top level.
//   - frag1_ssi_sys / frag1_bits_sys[43:0]: latched fragment-1 fields.
//   - end_hu_pulse_sys: MAC-END-HU just decoded.
//     The parser exposes this as `ul_continuation_valid_sys`.
//   - end_hu_ssi_sys / end_hu_bits_sys[84:0]: continuation fields from the
//     parser (the parser carries the latched MAC-ACCESS frag=1 SSI through
//     so we don't have to re-extract it here).
//   - frame_tick_sys: 1-cycle pulse at every TDMA-frame boundary (~56.67 ms).
//     Drives the T0 timer.
//
// Outputs:
//   - reassembled_valid_sys: 1-cycle pulse when fragment 1 + 2 are joined
//     within T0.
//   - reassembled_body_sys[128:0]: 129-bit MM body, MSB-first (bit[128] is
//     the on-air MSB of the body — i.e., ul0_bits[48]).
//   - reassembled_ssi_sys[23:0]: SSI of the joined PDU.
//   - reassembled_cnt_sys[15:0]: number of successful reassemblies.
//   - drop_cnt_sys[15:0]: number of fragment-1 latches that timed out
//     before a matching MAC-END-HU arrived.
//   - busy_slots_sys[1:0]: one-hot view of the two slots (debug).
//
// =============================================================================

`default_nettype none

module tetra_ul_demand_reassembly #(
    parameter integer T0_FRAMES_DEFAULT = 2     // ETSI ≈ 2 frames = 113 ms
)(
    input  wire                clk_sys,
    input  wire                rst_n_sys,

    // ------------- Configuration (from AXI-Lite, Phase F.3 will wire it) ----
    input  wire [3:0]          t0_frames_sys,    // 0 → use default
    input  wire                frame_tick_sys,   // 1 cycle / TDMA frame

    // ------------- Stimuli from MAC parser ----------------------------------
    input  wire                frag1_pulse_sys,
    input  wire [23:0]         frag1_ssi_sys,
    input  wire [43:0]         frag1_bits_sys,   // ul0_bits[48..91], MSB-first

    input  wire                end_hu_pulse_sys,
    input  wire [23:0]         end_hu_ssi_sys,
    input  wire [84:0]         end_hu_bits_sys,  // ul1_bits[7..91], MSB-first

    // ------------- Reassembled output ---------------------------------------
    output reg                 reassembled_valid_sys,
    output reg  [128:0]        reassembled_body_sys,
    output reg  [23:0]         reassembled_ssi_sys,

    // ------------- Counters / debug -----------------------------------------
    output reg  [15:0]         reassembled_cnt_sys,
    output reg  [15:0]         drop_cnt_sys,
    output wire [1:0]          busy_slots_sys
);

// =============================================================================
// 2-slot in-flight buffer.  Verilog-2001: flat regs (no array of regs).
// Each slot: { occupied, ssi[23:0], frag1[43:0], t0_left[3:0] }.
// =============================================================================

// Slot 0
reg          s0_occ;
reg [23:0]   s0_ssi;
reg [43:0]   s0_frag1;
reg [3:0]    s0_t0_left;
// Slot 1
reg          s1_occ;
reg [23:0]   s1_ssi;
reg [43:0]   s1_frag1;
reg [3:0]    s1_t0_left;

assign busy_slots_sys = {s1_occ, s0_occ};

// Effective T0 — fall back to default when AXI register is 0.
wire [3:0] t0_eff = (t0_frames_sys == 4'd0) ? T0_FRAMES_DEFAULT[3:0]
                                            : t0_frames_sys;

// =============================================================================
// Match logic (combinational): for the END-HU pulse, find which slot's SSI
// matches.  Slot 0 wins on tie (older).  match_slot is only meaningful when
// `match_any` is asserted.
// =============================================================================
wire s0_match = s0_occ && (s0_ssi == end_hu_ssi_sys);
wire s1_match = s1_occ && (s1_ssi == end_hu_ssi_sys);
wire match_any = s0_match | s1_match;
wire match_slot = s0_match ? 1'b0 : 1'b1;       // 0 = slot 0, 1 = slot 1

// On a frag1 pulse, also detect SSI re-entry (same MS retransmits frag-1
// while a buffered fragment is still in flight).  ETSI behaviour: replace
// the older fragment in the same slot, restart T0.  (No drop count — this
// is a legitimate re-attempt.)
wire s0_replace = s0_occ && (s0_ssi == frag1_ssi_sys);
wire s1_replace = s1_occ && (s1_ssi == frag1_ssi_sys);

// Allocation of a fresh slot for a brand-new SSI — pick the first empty.
wire alloc_to_s0 = !s0_occ;
wire alloc_to_s1 =  s0_occ && !s1_occ;
// If both are occupied and the SSI is new, we drop the new fragment 1 and
// bump drop_cnt_sys (simpler than evicting an in-flight reassembly mid-T0).
wire drop_new   =  s0_occ &&  s1_occ && !s0_replace && !s1_replace;

// Build the 129-bit reassembled body (slot-N's frag1 ++ end_hu_bits_sys),
// MSB-first.  Bit 128 = first on-air bit of the body (= UL#0 bit 48).
wire [128:0] reass_body_s0 = {s0_frag1, end_hu_bits_sys};
wire [128:0] reass_body_s1 = {s1_frag1, end_hu_bits_sys};

// =============================================================================
// Sequential — slot bookkeeping + outputs
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        s0_occ                <= 1'b0;
        s0_ssi                <= 24'd0;
        s0_frag1              <= 44'd0;
        s0_t0_left            <= 4'd0;
        s1_occ                <= 1'b0;
        s1_ssi                <= 24'd0;
        s1_frag1              <= 44'd0;
        s1_t0_left            <= 4'd0;
        reassembled_valid_sys <= 1'b0;
        reassembled_body_sys  <= 129'd0;
        reassembled_ssi_sys   <= 24'd0;
        reassembled_cnt_sys   <= 16'd0;
        drop_cnt_sys          <= 16'd0;
    end else begin
        // Default: pulse outputs deassert each cycle.
        reassembled_valid_sys <= 1'b0;

        // ---------------------------------------------------------------
        // T0 timer tick (one cycle per TDMA frame).  Decrement; on reaching
        // 0 the slot is freed and drop_cnt bumped.
        // ---------------------------------------------------------------
        if (frame_tick_sys) begin
            if (s0_occ) begin
                if (s0_t0_left == 4'd1) begin
                    s0_occ      <= 1'b0;
                    drop_cnt_sys<= drop_cnt_sys + 16'd1;
                end
                s0_t0_left <= (s0_t0_left == 4'd0) ? 4'd0
                                                   : (s0_t0_left - 4'd1);
            end
            if (s1_occ) begin
                if (s1_t0_left == 4'd1) begin
                    s1_occ      <= 1'b0;
                    drop_cnt_sys<= drop_cnt_sys + 16'd1;
                end
                s1_t0_left <= (s1_t0_left == 4'd0) ? 4'd0
                                                   : (s1_t0_left - 4'd1);
            end
        end

        // ---------------------------------------------------------------
        // Fragment 1 arrival.  Same-SSI replace > slot allocation > drop.
        // ---------------------------------------------------------------
        if (frag1_pulse_sys) begin
            if (s0_replace) begin
                s0_frag1   <= frag1_bits_sys;
                s0_t0_left <= t0_eff;
            end else if (s1_replace) begin
                s1_frag1   <= frag1_bits_sys;
                s1_t0_left <= t0_eff;
            end else if (alloc_to_s0) begin
                s0_occ     <= 1'b1;
                s0_ssi     <= frag1_ssi_sys;
                s0_frag1   <= frag1_bits_sys;
                s0_t0_left <= t0_eff;
            end else if (alloc_to_s1) begin
                s1_occ     <= 1'b1;
                s1_ssi     <= frag1_ssi_sys;
                s1_frag1   <= frag1_bits_sys;
                s1_t0_left <= t0_eff;
            end else if (drop_new) begin
                drop_cnt_sys <= drop_cnt_sys + 16'd1;
            end
        end

        // ---------------------------------------------------------------
        // MAC-END-HU arrival.  If the SSI matches a slot, splice and emit.
        // Otherwise drop silently (no slot existed → fragment 1 either
        // never arrived or already T0-expired; the parser still emits the
        // pulse but we discard).  We don't bump drop_cnt for orphan ENDs
        // because that counter is reserved for fragment-1 timeouts.
        // ---------------------------------------------------------------
        if (end_hu_pulse_sys && match_any) begin
            if (match_slot == 1'b0) begin
                reassembled_body_sys <= reass_body_s0;
                reassembled_ssi_sys  <= s0_ssi;
                s0_occ               <= 1'b0;
            end else begin
                reassembled_body_sys <= reass_body_s1;
                reassembled_ssi_sys  <= s1_ssi;
                s1_occ               <= 1'b0;
            end
            reassembled_valid_sys <= 1'b1;
            reassembled_cnt_sys   <= reassembled_cnt_sys + 16'd1;
        end
    end
end

endmodule

`default_nettype wire
