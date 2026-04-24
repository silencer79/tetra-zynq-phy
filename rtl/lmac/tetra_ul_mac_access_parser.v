// =============================================================================
// tetra_ul_mac_access_parser.v — MAC-ACCESS PDU field extractor (ETSI §21.4.3.3)
// =============================================================================
//
// Consumes the 92 info bits delivered by tetra_ul_sch_hu_decoder when
// info_valid_sys pulses with crc_ok_sys=1, and exposes the parsed MAC-ACCESS
// PDU fields as registered outputs.  A one-cycle pdu_valid_sys pulse fires
// when a fresh CRC-OK PDU is latched; a sticky pdu_count increments on each
// valid PDU so software can detect new arrivals via register polling.
//
// PDU layout (bit 0 = MSB of info_bits, ETSI §21.4.3.3 MAC-ACCESS):
//   [0:2)   pdu_type       (0 = MAC-ACCESS)
//   [2:3)   fill_bit_ind
//   [3:5)   encryption_mode
//   [5:6)   access_ack
//   [6:9)   address_type
//   [9:19)  short_subscriber_identity / event_label (10 bits)
//   [19:23) LLC-PDU-Type (4 bits, start of TM-SDU) —
//           {link_type[1], has_fcs[1], bl_pdu_type[2]}
//           per ETSI §21.2.1 Table 21.3 / bluestation
//           `tetra-pdus::llc::enums::llc_pdu_type::LlcPduType` (values
//           0=BL-ADATA, 1=BL-DATA, 2=BL-UDATA, 3=BL-ACK, +4=…-FCS).
//           Extract `ns`/`nr` bits at the offsets below based on the
//           decoded bl_pdu_type so the MLE FSM can auto-ACK incoming
//           BL-DATA(ns) frames (bluestation llc_bs_ms.rs:488-493
//           schedule_outgoing_ack).
//   [23]    ns  (when bl_pdu_type ∈ {BL-ADATA, BL-DATA})
//   [24]    nr  (when bl_pdu_type == BL-ADATA)
//   [23]    nr  (when bl_pdu_type == BL-ACK)
//   [23:27) MM PDU-type (4 bits) — kept as legacy output but only valid
//           for non-LLC frames; with BL-DATA wrapping this overlaps the
//           {ns, MLE-PD[2:0]} bits.  Consumers should prefer the new
//           ul_llc_* outputs below.
//   [27:30) Location update type (3 bits) — legacy, same overlap caveat.
//
// Only pdu_type == 2'b00 (MAC-ACCESS) is decoded; other types flag as
// "unhandled" but still pulse pdu_valid_sys so SW can see raw bits.
//
// Separate LLC BL-ACK detection (M1 of 2026-04-24 post-accept flow):
//
// The 19-bit MAC-ACCESS header (bit 0..18) is followed by a 5-bit LLC
// header — ETSI §22.2.1, bluestation `tetra-pdus::llc::pdus::bl_ack`:
//
//     [19]   llc_link_type = 0
//     [20]   has_fcs       (0 = BL-ACK, 1 = BL-ACK-FCS)
//     [21:22] bl_pdu_type  (11 = BL-ACK per Clause 21.2.2.1)
//     [23]   N(R)          acknowledged sender sequence number
//
// When bl_pdu_type == 11 at [21:22] and llc_link_type == 0 at [19], the
// PDU is a standalone BL-ACK from the MS.  The MLE registration FSM
// consumes `bl_ack_valid_sys` + `bl_ack_nr_sys` + `short_ssi_sys` to
// terminate the acknowledged BL-DATA transaction that carried
// D-LOCATION-UPDATE-ACCEPT.  Cf. `llc_bs_ms.rs::process_incoming_ack`.
//
// NOTE: The existing MM-PDU-Type / loc-upd-type fields at [23:27)/[27:30)
// are decoded IN PARALLEL with BL-ACK detection — when the MS sends an
// MM-DEMAND the BL-ACK check resolves to 0 (no match at [21:22]==11),
// and vice versa.  No cross-talk.
//
// =============================================================================

`default_nettype none

module tetra_ul_mac_access_parser #(
    parameter INFO_BITS = 92
)(
    input  wire                      clk_sys,
    input  wire                      rst_n_sys,
    // From sch_hu_decoder
    input  wire [INFO_BITS-1:0]      info_bits_sys,
    input  wire                      info_valid_sys,
    input  wire                      crc_ok_sys,
    // Parsed fields (latched on valid CRC-OK PDU)
    output reg  [1:0]                pdu_type_sys,
    output reg                       fill_bit_sys,
    output reg  [1:0]                encryption_mode_sys,
    output reg                       access_ack_sys,
    output reg  [2:0]                address_type_sys,
    output reg  [9:0]                short_ssi_sys,
    output reg  [3:0]                mm_pdu_type_sys,   // bits [23:27)
    output reg  [2:0]                loc_upd_type_sys,  // bits [27:30)
    output reg  [INFO_BITS-1:0]      raw_info_bits_sys,
    output reg                       pdu_valid_sys,    // 1-cycle pulse
    output reg  [15:0]               pdu_count_sys,    // sticky counter
    // LLC BL-ACK detection (M1, 2026-04-24)
    // bl_ack_valid_sys pulses 1 cycle coincident with pdu_valid_sys when the
    // 5-bit LLC header at [19:24) matches BL-ACK: link_type=0, bl_pdu_type=11.
    // bl_ack_nr_sys latches the N(R) bit (position [23]) on the same edge.
    // SSI match happens downstream (MLE FSM compares short_ssi_sys against
    // the outstanding accept's session record).
    output reg                       bl_ack_valid_sys,
    output reg                       bl_ack_nr_sys,
    output reg  [15:0]               bl_ack_count_sys, // sticky counter (debug)
    // -----------------------------------------------------------------
    // LLC-layer parse outputs (Option B / 2026-04-24 concatenated-BL-ACK
    // flow).  Registered on the same cycle as pdu_valid_sys; flags read
    // 0 on non-MAC-ACCESS or invalid frames.  Decoding covers bluestation
    // LlcPduType values 0..3 (the non-FCS basic-link subset used by MS
    // during registration).  FCS variants 4..7 currently fall through as
    // "no match" — extend if future fixtures need them.
    // -----------------------------------------------------------------
    output reg                       ul_llc_is_bl_data_sys, // BL-DATA or BL-ADATA
    output reg                       ul_llc_is_bl_ack_sys,  // BL-ACK (mirror of bl_ack_valid_sys)
    output reg                       ul_llc_has_fcs_sys,    // [20] has_fcs
    output reg                       ul_llc_ns_valid_sys,   // ns field present
    output reg                       ul_llc_ns_sys,         // N(S) from MS
    output reg                       ul_llc_nr_valid_sys,   // nr field present
    output reg                       ul_llc_nr_sys,         // N(R) from MS
    // Wrapped MLE/MM decode for BL-DATA/BL-ADATA carrying MM TL-SDU.
    output reg                       ul_llc_is_mle_mm_sys,
    output reg  [3:0]                ul_llc_mm_pdu_type_sys,
    output reg  [2:0]                ul_llc_mm_loc_upd_type_sys
);

// info_bits_sys[0] = first decoded bit = ETSI bit 0 (MSB per §21.4.3.3).
// Verilog [hi:lo] slices have hi=MSB, so we build each multi-bit field
// explicitly with info_bits_sys[start] as MSB, matching decode_ul.py's
// `field(start, n)` which does (v << 1) | b[start+i].
wire [1:0]  f_pdu_type        = {info_bits_sys[0], info_bits_sys[1]};
wire        f_fill_bit        =  info_bits_sys[2];
wire [1:0]  f_encryption_mode = {info_bits_sys[3], info_bits_sys[4]};
wire        f_access_ack      =  info_bits_sys[5];
wire [2:0]  f_address_type    = {info_bits_sys[6], info_bits_sys[7], info_bits_sys[8]};
wire [9:0]  f_short_ssi       = {info_bits_sys[9],  info_bits_sys[10], info_bits_sys[11],
                                 info_bits_sys[12], info_bits_sys[13], info_bits_sys[14],
                                 info_bits_sys[15], info_bits_sys[16], info_bits_sys[17],
                                 info_bits_sys[18]};
// MM PDU-type at bits [23:27) — 4 bits MSB-first.
wire [3:0]  f_mm_pdu_type     = {info_bits_sys[23], info_bits_sys[24],
                                 info_bits_sys[25], info_bits_sys[26]};
// Location update type at bits [27:30) — 3 bits MSB-first.  Only
// semantically valid when f_mm_pdu_type == 4'h4 (U-LOC-UPDATE-DEMAND).
wire [2:0]  f_loc_upd_type    = {info_bits_sys[27], info_bits_sys[28],
                                 info_bits_sys[29]};

// LLC BL-ACK detector at bits [19:24) — parallel path, does not affect
// the MM-field decoders above.  ETSI §22.2.1 / bluestation bl_ack.rs:
//   [19] llc_link_type  (0 = Basic Link)
//   [20] has_fcs
//   [21:22] bl_pdu_type (11 = BL-ACK)
//   [23] N(R)
wire        f_llc_link_type    = info_bits_sys[19];
wire        f_llc_has_fcs      = info_bits_sys[20];
wire [1:0]  f_llc_bl_pdu_type  = {info_bits_sys[21], info_bits_sys[22]};
wire        f_bl_ack_nr        = info_bits_sys[23];
wire        f_is_bl_ack        = (f_llc_link_type == 1'b0) &&
                                 (f_llc_bl_pdu_type == 2'b11);

// Option-B LLC parse (2026-04-24): matches bluestation
// crates/tetra-pdus/src/llc/pdus/{bl_data,bl_adata,bl_ack,bl_udata}.rs.
//
//   LlcPduType value → {link_type, has_fcs, bl_pdu_type}
//     0 BL-ADATA   {0, 0, 00}  ns at [23], nr at [24]
//     1 BL-DATA    {0, 0, 01}  ns at [23]
//     2 BL-UDATA   {0, 0, 10}  no flow control
//     3 BL-ACK     {0, 0, 11}  nr at [23]
//
// is_bl_data covers both BL-ADATA and BL-DATA — the MLE FSM schedules an
// auto-BL-ACK for both cases (bluestation schedule_outgoing_ack triggers
// whenever an incoming ns exists).
wire        f_is_bl_adata      = (f_llc_link_type   == 1'b0) &&
                                 (f_llc_bl_pdu_type == 2'b00);
wire        f_is_bl_data       = (f_llc_link_type   == 1'b0) &&
                                 (f_llc_bl_pdu_type == 2'b01);
// f_is_bl_udata = 2'b10 — present for completeness, not latched today.
wire        f_ns_valid         = f_is_bl_adata | f_is_bl_data;
wire        f_nr_valid         = f_is_bl_adata | f_is_bl_ack;
wire        f_ns_bit           = info_bits_sys[23];
wire        f_nr_bit           = f_is_bl_adata ? info_bits_sys[24]
                                               : info_bits_sys[23];
wire [2:0]  f_llc_mle_pd       = {info_bits_sys[24], info_bits_sys[25], info_bits_sys[26]};
wire [3:0]  f_llc_mm_pdu_type  = {info_bits_sys[27], info_bits_sys[28],
                                  info_bits_sys[29], info_bits_sys[30]};
wire [2:0]  f_llc_loc_upd_type = {info_bits_sys[31], info_bits_sys[32],
                                  info_bits_sys[33]};
wire        f_is_mle_mm        = (f_llc_mle_pd == 3'b001);

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        pdu_type_sys        <= 2'd0;
        fill_bit_sys        <= 1'b0;
        encryption_mode_sys <= 2'd0;
        access_ack_sys      <= 1'b0;
        address_type_sys    <= 3'd0;
        short_ssi_sys       <= 10'd0;
        mm_pdu_type_sys     <= 4'd0;
        loc_upd_type_sys    <= 3'd0;
        raw_info_bits_sys   <= {INFO_BITS{1'b0}};
        pdu_valid_sys       <= 1'b0;
        pdu_count_sys       <= 16'd0;
        bl_ack_valid_sys    <= 1'b0;
        bl_ack_nr_sys       <= 1'b0;
        bl_ack_count_sys    <= 16'd0;
        ul_llc_is_bl_data_sys <= 1'b0;
        ul_llc_is_bl_ack_sys  <= 1'b0;
        ul_llc_has_fcs_sys    <= 1'b0;
        ul_llc_ns_valid_sys   <= 1'b0;
        ul_llc_ns_sys         <= 1'b0;
        ul_llc_nr_valid_sys   <= 1'b0;
        ul_llc_nr_sys         <= 1'b0;
        ul_llc_is_mle_mm_sys      <= 1'b0;
        ul_llc_mm_pdu_type_sys    <= 4'd0;
        ul_llc_mm_loc_upd_type_sys<= 3'd0;
    end else begin
        pdu_valid_sys        <= 1'b0;
        bl_ack_valid_sys     <= 1'b0;
        ul_llc_is_bl_data_sys<= 1'b0;
        ul_llc_is_bl_ack_sys <= 1'b0;
        ul_llc_ns_valid_sys  <= 1'b0;
        ul_llc_nr_valid_sys  <= 1'b0;
        ul_llc_is_mle_mm_sys <= 1'b0;
        if (info_valid_sys && crc_ok_sys) begin
            pdu_type_sys        <= f_pdu_type;
            fill_bit_sys        <= f_fill_bit;
            encryption_mode_sys <= f_encryption_mode;
            access_ack_sys      <= f_access_ack;
            address_type_sys    <= f_address_type;
            short_ssi_sys       <= f_short_ssi;
            mm_pdu_type_sys     <= f_mm_pdu_type;
            loc_upd_type_sys    <= f_loc_upd_type;
            raw_info_bits_sys   <= info_bits_sys;
            pdu_valid_sys       <= 1'b1;
            pdu_count_sys       <= pdu_count_sys + 16'd1;
            // BL-ACK detection — only fires on MAC-ACCESS frames with
            // bl_pdu_type=11 at the ETSI-strict LLC offset.  Orthogonal to
            // MM-PDU-type decoder above; both can evaluate the same frame.
            if (f_is_bl_ack) begin
                bl_ack_valid_sys <= 1'b1;
                bl_ack_nr_sys    <= f_bl_ack_nr;
                bl_ack_count_sys <= bl_ack_count_sys + 16'd1;
            end
            // Option B: expose per-LLC-type flags + ns/nr for the MLE
            // FSM's BL-ACK auto-scheduler.  Latched on the same edge as
            // pdu_valid_sys; valid flags fall back to 0 on the next cycle.
            ul_llc_has_fcs_sys    <= f_llc_has_fcs;
            ul_llc_is_bl_data_sys <= f_is_bl_data | f_is_bl_adata;
            ul_llc_is_bl_ack_sys  <= f_is_bl_ack;
            ul_llc_ns_valid_sys   <= f_ns_valid;
            ul_llc_ns_sys         <= f_ns_bit;
            ul_llc_nr_valid_sys   <= f_nr_valid;
            ul_llc_nr_sys         <= f_nr_bit;
            ul_llc_is_mle_mm_sys      <= (f_is_bl_data | f_is_bl_adata) && f_is_mle_mm;
            ul_llc_mm_pdu_type_sys    <= f_llc_mm_pdu_type;
            ul_llc_mm_loc_upd_type_sys<= f_llc_loc_upd_type;
        end
    end
end

endmodule

`default_nettype wire
