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
// Bit layout — bluestation `tetra-pdus/src/umac/pdus/mac_access.rs::from_bitbuf`
// is the authority.  info_bits_sys[i] is bit `i` on air (MSB-first).
//
// SCH/HU dispatcher per bluestation `umac/pdus/umac_bs.rs` accepts ONLY two
// MAC PDU types on this channel, distinguished by the 1-bit `mac_pdu_type`:
//   bit[0]=0 → MAC-ACCESS  (this module's primary path)
//   bit[0]=1 → MAC-END-HU  (continuation of a fragmented MAC-ACCESS PDU,
//             consumed by tetra_ul_demand_reassembly).  Per
//             `umac/pdus/mac_end_hu.rs`:
//               [0]      mac_pdu_type           = 1
//               [1]      fill_bits              = 1 bit
//               [2]      length_ind_or_cap_req  = 1 bit
//                          if 0 → [3..6] length_ind (4 bit, octets)
//                          if 1 → [3..6] reservation_req (4 bit)
//               [7..91]  MM body fragment 2     = 85 bit
//
//   bit[0]:     mac_pdu_type         (1 bit, 0 for MAC-ACCESS, 1 for MAC-END-HU)
//   bit[1]:     fill_bits            (1 bit)
//   bit[2]:     encrypted            (1 bit)
//   bit[3..4]:  addr_type            (2 bits — 0=Ssi/ISSI, 1=EventLabel,
//                                      2=Ussi, 3=Smi)
//   bit[5..28]: address              (24 bits when addr_type ∈ {0,2,3};
//                                      only [5..14] used when addr_type=1
//                                      and [15..28] are TL-SDU instead).
//   bit[29]:    optional_field_flag
//     if 1:
//       bit[30]: length_ind_or_cap_req
//         if 0: bits[31..35]: length_ind (5 bits)
//         if 1: bit[31]: frag_flag, bits[32..35]: reservation_req (4 bits)
//   bit[36 (or 30)..]: TL-SDU = LLC PDU
//
// LLC layer (TL-SDU) — bit indices below are anchored at the TL-SDU start.
// The MS uses unfragmented forms during registration (frag_flag=1 indicates
// that more PDU data follows in a chained MAC-FRAG, *not* truncation of
// this header).  bluestation `crates/tetra-pdus/src/llc/pdus/{bl_data,
// bl_adata,bl_ack,bl_udata}.rs`:
//
//   LlcPduType value → {link_type, has_fcs, bl_pdu_type}
//     0 BL-ADATA   {0, 0, 00}  ns at [tl_sdu+4], nr at [tl_sdu+5]
//     1 BL-DATA    {0, 0, 01}  ns at [tl_sdu+4]
//     2 BL-UDATA   {0, 0, 10}  no flow control
//     3 BL-ACK     {0, 0, 11}  nr at [tl_sdu+4]
//
// Outputs:
//   - ul_addr_type_sys         [1:0]  raw addr_type field
//   - ul_issi_sys              [23:0] address when addr_type ∈ {0,2,3}
//   - ul_event_label_sys       [9:0]  address when addr_type == 1
//   - ul_frag_flag_sys                fragmentation flag when opt_field=1 &
//                                      length_or_cap=1
//   - ul_reservation_req_sys   [3:0]  reservation request (cap_req mode)
//
//   Legacy compatibility outputs:
//     - mm_pdu_type_sys / loc_upd_type_sys  (re-anchored to new TL-SDU pos)
//     - ul_llc_*                            (re-anchored to new TL-SDU pos)
//     - bl_ack_valid_sys / bl_ack_nr_sys    (re-anchored)
//
// Removed: short_ssi_sys (10-bit) — was bit-misaligned.  All consumers now
// use ul_issi_sys[23:0] and refer to ul_addr_type_sys for interpretation.
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
    // -------- Header fields (bluestation-aligned) --------
    output reg                       pdu_type_sys,        // bit[0] (1 bit, was 2 bits)
    output reg                       fill_bit_sys,        // bit[1]
    output reg                       encryption_mode_sys, // bit[2] (1 bit, was 2 bits)
    output reg  [1:0]                ul_addr_type_sys,    // bits[3..4]
    output reg  [23:0]               ul_issi_sys,         // bits[5..28] (when at∈{0,2,3})
    output reg  [9:0]                ul_event_label_sys,  // bits[5..14] (when at==1)
    output reg                       optional_field_flag_sys,  // bit[29]
    output reg                       ul_frag_flag_sys,    // bit[31] when length_or_cap=1
    output reg  [3:0]                ul_reservation_req_sys, // bits[32..35]
    output reg  [4:0]                ul_length_ind_sys,   // bits[31..35] when length_or_cap=0
    // -------- TL-SDU / LLC layer --------
    // mm_pdu_type re-anchored: TL-SDU starts at bit 30 (opt=0) or 36 (opt=1).
    // For BL-DATA/BL-ADATA/BL-ACK the LLC header occupies the first 4 bits
    // of TL-SDU; for non-LLC frames mm_pdu_type sits at TL-SDU+4..TL-SDU+8.
    // The legacy `mm_pdu_type_sys` and `loc_upd_type_sys` outputs are now
    // computed assuming the BL-DATA wrap (which is what real MS use during
    // registration).
    output reg  [3:0]                mm_pdu_type_sys,
    output reg  [2:0]                loc_upd_type_sys,
    output reg  [INFO_BITS-1:0]      raw_info_bits_sys,
    output reg                       pdu_valid_sys,    // 1-cycle pulse
    output reg  [15:0]               pdu_count_sys,    // sticky counter
    // LLC BL-ACK detection — pulses 1 cycle coincident with pdu_valid_sys
    // when the TL-SDU LLC header matches BL-ACK (link_type=0, bl_pdu_type=11).
    output reg                       bl_ack_valid_sys,
    output reg                       bl_ack_nr_sys,
    output reg  [15:0]               bl_ack_count_sys,
    // LLC-layer parse outputs.  Registered on the same cycle as
    // pdu_valid_sys; flags read 0 on non-MAC-ACCESS or invalid frames.
    output reg                       ul_llc_is_bl_data_sys, // BL-DATA or BL-ADATA
    output reg                       ul_llc_is_bl_ack_sys,  // BL-ACK
    output reg                       ul_llc_has_fcs_sys,    // has_fcs LLC bit
    output reg                       ul_llc_ns_valid_sys,
    output reg                       ul_llc_ns_sys,
    output reg                       ul_llc_nr_valid_sys,
    output reg                       ul_llc_nr_sys,
    // Wrapped MLE/MM decode for BL-DATA/BL-ADATA carrying MM TL-SDU.
    output reg                       ul_llc_is_mle_mm_sys,
    output reg  [3:0]                ul_llc_mm_pdu_type_sys,
    output reg  [2:0]                ul_llc_mm_loc_upd_type_sys,
    // Phase 7 F.3 — raw 4-bit LLC pdu_type (= TL-SDU bits 0..3) +
    // 3-bit MLE protocol discriminator at TL-SDU's LLC payload start.
    // Both registered on the same cycle as pdu_valid_sys.  Used by the
    // AXI-Lite UL_PDU_STATUS_2 register so tetra_ul_mon can pretty-print
    // the decoded MAC/LLC/MLE/MM type triple per PDU.
    output reg  [3:0]                ul_llc_pdu_type_sys,
    output reg  [2:0]                ul_mle_disc_sys,
    // -------- Phase 7 F.1 — MAC-END-HU continuation path --------
    // When mac_pdu_type==1 (MAC-END-HU) on SCH/HU the parser does NOT fire
    // pdu_valid_sys/llc_*; instead the dedicated continuation outputs below
    // pulse with the 85-bit MM-body fragment 2 ready for the reassembly
    // module.  The SSI tag is the most recent MAC-ACCESS frag=1 ISSI, which
    // is latched the moment that pdu was parsed.  The reassembly module owns
    // the T0 timer; the parser only forwards the latched SSI.
    output reg                       ul_pdu_is_continuation_sys,
    output reg                       ul_continuation_valid_sys,
    output reg  [84:0]               ul_continuation_bits_sys,
    output reg  [23:0]               ul_continuation_ssi_sys,
    output reg  [15:0]               ul_continuation_count_sys
);

// =============================================================================
// Header field extraction (bluestation-aligned)
// =============================================================================
// info_bits_sys[0] = first decoded bit on air = ETSI MSB-first bit 0.
// Multi-bit fields are concatenated MSB-first: info_bits_sys[start] is the
// highest-order bit of the field.

wire        f_pdu_type        = info_bits_sys[0];
wire        f_fill_bit        = info_bits_sys[1];
wire        f_encryption_mode = info_bits_sys[2];

wire [1:0]  f_addr_type       = {info_bits_sys[3], info_bits_sys[4]};

// Address: 24 bits at [5..28], MSB-first.
wire [23:0] f_issi = {
    info_bits_sys[5],  info_bits_sys[6],  info_bits_sys[7],  info_bits_sys[8],
    info_bits_sys[9],  info_bits_sys[10], info_bits_sys[11], info_bits_sys[12],
    info_bits_sys[13], info_bits_sys[14], info_bits_sys[15], info_bits_sys[16],
    info_bits_sys[17], info_bits_sys[18], info_bits_sys[19], info_bits_sys[20],
    info_bits_sys[21], info_bits_sys[22], info_bits_sys[23], info_bits_sys[24],
    info_bits_sys[25], info_bits_sys[26], info_bits_sys[27], info_bits_sys[28]
};

// EventLabel: 10 bits at [5..14] (the upper 10 bits of the 24-bit address slot).
wire [9:0]  f_event_label = f_issi[23:14];

wire        f_opt_flag        = info_bits_sys[29];
wire        f_length_or_cap   = info_bits_sys[30];     // valid iff opt_flag=1

wire [4:0]  f_length_ind = {
    info_bits_sys[31], info_bits_sys[32], info_bits_sys[33],
    info_bits_sys[34], info_bits_sys[35]
};
wire        f_frag_flag       = info_bits_sys[31];     // valid iff opt_flag=1 & length_or_cap=1
wire [3:0]  f_reservation_req = {
    info_bits_sys[32], info_bits_sys[33], info_bits_sys[34], info_bits_sys[35]
};

// =============================================================================
// TL-SDU start (LLC PDU) — depends on optional_field layout
// =============================================================================
// opt_flag=0:                           TL-SDU starts at bit 30
// opt_flag=1, length_or_cap=0 (LengInd): TL-SDU starts at bit 36
// opt_flag=1, length_or_cap=1 (CapReq):  TL-SDU starts at bit 36
//
// During registration the MS sets opt_flag=1 length_or_cap=1 frag=1 (per
// captured trace), so the canonical TL-SDU offset for the LLC parse is 36.
// We parameterise via a small select net to keep the LLC field-extraction
// MSB-first regardless.

wire [5:0]  tl_sdu_start = f_opt_flag ? 6'd36 : 6'd30;

// LLC header: 4 bits MSB-first at [tl_sdu_start..tl_sdu_start+3]:
//   [0] link_type
//   [1] has_fcs
//   [2..3] bl_pdu_type
wire        f_llc_link_type   = info_bits_sys[tl_sdu_start + 6'd0];
wire        f_llc_has_fcs     = info_bits_sys[tl_sdu_start + 6'd1];
wire [1:0]  f_llc_bl_pdu_type = {info_bits_sys[tl_sdu_start + 6'd2],
                                 info_bits_sys[tl_sdu_start + 6'd3]};

// BL-ACK detection: link_type=0, bl_pdu_type=11
wire        f_is_bl_ack       = (f_llc_link_type == 1'b0) &&
                                (f_llc_bl_pdu_type == 2'b11);
wire        f_is_bl_adata     = (f_llc_link_type == 1'b0) &&
                                (f_llc_bl_pdu_type == 2'b00);
wire        f_is_bl_data      = (f_llc_link_type == 1'b0) &&
                                (f_llc_bl_pdu_type == 2'b01);

// ns at TL-SDU+4 (BL-ADATA, BL-DATA), nr at TL-SDU+5 (BL-ADATA only)
// or TL-SDU+4 (BL-ACK).
wire        f_ns_valid        = f_is_bl_adata | f_is_bl_data;
wire        f_nr_valid        = f_is_bl_adata | f_is_bl_ack;
wire        f_ns_bit          = info_bits_sys[tl_sdu_start + 6'd4];
wire        f_nr_bit          = f_is_bl_adata ? info_bits_sys[tl_sdu_start + 6'd5]
                                              : info_bits_sys[tl_sdu_start + 6'd4];

// LLC payload: bits after the LLC 4+ns/nr bits.  For BL-DATA the next 3 bits
// are MLE protocol discriminator (mle_pd) and then 4 bits MM pdu_type.
//   BL-DATA  payload = [tl_sdu+5..]:  mle_pd[3] mm_pdu_type[4] loc_upd_type[3] ...
//   BL-ADATA payload = [tl_sdu+6..]:  mle_pd[3] mm_pdu_type[4] loc_upd_type[3] ...
wire [5:0]  llc_payload_start = tl_sdu_start +
                                 (f_is_bl_adata ? 6'd6 :
                                  f_is_bl_data  ? 6'd5 : 6'd4);

wire [2:0]  f_llc_mle_pd      = {info_bits_sys[llc_payload_start + 6'd0],
                                 info_bits_sys[llc_payload_start + 6'd1],
                                 info_bits_sys[llc_payload_start + 6'd2]};
wire [3:0]  f_llc_mm_pdu_type = {info_bits_sys[llc_payload_start + 6'd3],
                                 info_bits_sys[llc_payload_start + 6'd4],
                                 info_bits_sys[llc_payload_start + 6'd5],
                                 info_bits_sys[llc_payload_start + 6'd6]};
wire [2:0]  f_llc_loc_upd_type = {info_bits_sys[llc_payload_start + 6'd7],
                                  info_bits_sys[llc_payload_start + 6'd8],
                                  info_bits_sys[llc_payload_start + 6'd9]};
wire        f_is_mle_mm        = (f_llc_mle_pd == 3'b001);

// Legacy (non-LLC-wrapped) MM-PDU-type and loc-upd-type at TL-SDU+0..TL-SDU+6.
// Some MS ship U-LOC-UPDATE-DEMAND directly in the TL-SDU without an LLC
// wrapper (the previous parser assumed this).  Kept for compatibility with
// the top-level mle_ul_req_direct_w fallback.
wire [3:0]  f_direct_mm_pdu_type   = {info_bits_sys[tl_sdu_start + 6'd0],
                                       info_bits_sys[tl_sdu_start + 6'd1],
                                       info_bits_sys[tl_sdu_start + 6'd2],
                                       info_bits_sys[tl_sdu_start + 6'd3]};
wire [2:0]  f_direct_loc_upd_type  = {info_bits_sys[tl_sdu_start + 6'd4],
                                       info_bits_sys[tl_sdu_start + 6'd5],
                                       info_bits_sys[tl_sdu_start + 6'd6]};

// =============================================================================
// Phase 7 F.1 — MAC-END-HU continuation extraction
// =============================================================================
// info_bits_sys[7..91] = 85 bit MM body fragment 2.  Packed MSB-first into
// the bus: ul_continuation_bits_sys[84] = info_bits_sys[7],
//          ul_continuation_bits_sys[ 0] = info_bits_sys[91].
// (Same MSB-first order the rest of the parser uses — first on-air bit lives
// at the highest index of the bus.)

wire        f_is_end_hu = (f_pdu_type == 1'b1);
wire        f_is_mac_access = (f_pdu_type == 1'b0);

wire [84:0] f_continuation_bits;
genvar gci;
generate
    for (gci = 0; gci < 85; gci = gci + 1) begin : g_continuation_bits
        // Bit position 7 in info_bits_sys → bus index 84 (MSB-first).
        assign f_continuation_bits[84 - gci] = info_bits_sys[7 + gci];
    end
endgenerate

// =============================================================================
// Registers
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        pdu_type_sys              <= 1'b0;
        fill_bit_sys              <= 1'b0;
        encryption_mode_sys       <= 1'b0;
        ul_addr_type_sys          <= 2'd0;
        ul_issi_sys               <= 24'd0;
        ul_event_label_sys        <= 10'd0;
        optional_field_flag_sys   <= 1'b0;
        ul_frag_flag_sys          <= 1'b0;
        ul_reservation_req_sys    <= 4'd0;
        ul_length_ind_sys         <= 5'd0;
        mm_pdu_type_sys           <= 4'd0;
        loc_upd_type_sys          <= 3'd0;
        raw_info_bits_sys         <= {INFO_BITS{1'b0}};
        pdu_valid_sys             <= 1'b0;
        pdu_count_sys             <= 16'd0;
        bl_ack_valid_sys          <= 1'b0;
        bl_ack_nr_sys             <= 1'b0;
        bl_ack_count_sys          <= 16'd0;
        ul_llc_is_bl_data_sys     <= 1'b0;
        ul_llc_is_bl_ack_sys      <= 1'b0;
        ul_llc_has_fcs_sys        <= 1'b0;
        ul_llc_ns_valid_sys       <= 1'b0;
        ul_llc_ns_sys             <= 1'b0;
        ul_llc_nr_valid_sys       <= 1'b0;
        ul_llc_nr_sys             <= 1'b0;
        ul_llc_is_mle_mm_sys      <= 1'b0;
        ul_llc_mm_pdu_type_sys    <= 4'd0;
        ul_llc_mm_loc_upd_type_sys<= 3'd0;
        ul_llc_pdu_type_sys       <= 4'd0;
        ul_mle_disc_sys           <= 3'd0;
        ul_pdu_is_continuation_sys<= 1'b0;
        ul_continuation_valid_sys <= 1'b0;
        ul_continuation_bits_sys  <= 85'd0;
        ul_continuation_ssi_sys   <= 24'd0;
        ul_continuation_count_sys <= 16'd0;
    end else begin
        // Default strobes — overridden below on info_valid_sys & crc_ok_sys.
        pdu_valid_sys         <= 1'b0;
        bl_ack_valid_sys      <= 1'b0;
        ul_llc_is_bl_data_sys <= 1'b0;
        ul_llc_is_bl_ack_sys  <= 1'b0;
        ul_llc_ns_valid_sys   <= 1'b0;
        ul_llc_nr_valid_sys   <= 1'b0;
        ul_llc_is_mle_mm_sys  <= 1'b0;
        ul_continuation_valid_sys <= 1'b0;
        if (info_valid_sys && crc_ok_sys) begin
            pdu_type_sys                <= f_pdu_type;
            ul_pdu_is_continuation_sys  <= f_is_end_hu;
            raw_info_bits_sys           <= info_bits_sys;
            if (f_is_mac_access) begin
                // ===== MAC-ACCESS path (mac_pdu_type=0) =====
                fill_bit_sys            <= f_fill_bit;
                encryption_mode_sys     <= f_encryption_mode;
                ul_addr_type_sys        <= f_addr_type;
                ul_issi_sys             <= f_issi;
                ul_event_label_sys      <= f_event_label;
                optional_field_flag_sys <= f_opt_flag;
                ul_frag_flag_sys        <= f_opt_flag & f_length_or_cap & f_frag_flag;
                ul_reservation_req_sys  <= (f_opt_flag & f_length_or_cap) ? f_reservation_req : 4'd0;
                ul_length_ind_sys       <= (f_opt_flag & ~f_length_or_cap) ? f_length_ind : 5'd0;
                mm_pdu_type_sys         <= f_direct_mm_pdu_type;
                loc_upd_type_sys        <= f_direct_loc_upd_type;
                pdu_valid_sys           <= 1'b1;
                pdu_count_sys           <= pdu_count_sys + 16'd1;
                // BL-ACK detection
                if (f_is_bl_ack) begin
                    bl_ack_valid_sys <= 1'b1;
                    bl_ack_nr_sys    <= f_nr_bit;
                    bl_ack_count_sys <= bl_ack_count_sys + 16'd1;
                end
                // Per-LLC-type flags + ns/nr extraction
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
                // Phase 7 F.3 — raw 4-bit LLC pdu_type (TL-SDU bits 0..3)
                // and 3-bit MLE protocol discriminator (LLC payload start).
                ul_llc_pdu_type_sys       <= {f_llc_link_type, f_llc_has_fcs,
                                              f_llc_bl_pdu_type};
                ul_mle_disc_sys           <= f_llc_mle_pd;
                // Latch SSI of every fragmented MAC-ACCESS so the next
                // MAC-END-HU on this slot can be tagged with it.  We only
                // latch when frag=1 AND addr_type ∈ {0,2,3} (Ssi/Ussi/Smi).
                if ((f_opt_flag & f_length_or_cap & f_frag_flag) &&
                    (f_addr_type != 2'b01)) begin
                    ul_continuation_ssi_sys <= f_issi;
                end
            end else begin
                // ===== MAC-END-HU path (mac_pdu_type=1) =====
                // Pulse the continuation outputs.  Do NOT fire pdu_valid_sys
                // and do NOT touch the MAC-ACCESS fields — they keep their
                // last-MAC-ACCESS values so downstream consumers don't see
                // bogus addr/LLC interpretations of an END-HU.
                ul_continuation_valid_sys <= 1'b1;
                ul_continuation_bits_sys  <= f_continuation_bits;
                ul_continuation_count_sys <= ul_continuation_count_sys + 16'd1;
            end
        end
    end
end

endmodule

`default_nettype wire
