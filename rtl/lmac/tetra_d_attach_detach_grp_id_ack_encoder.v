// =============================================================================
// tetra_d_attach_detach_grp_id_ack_encoder.v — Phase Y.1.c
//
// Combinational bit-packer for the MM D-ATTACH-DETACH-GROUP-IDENTITY-
// ACKNOWLEDGEMENT PDU (mm_pdu_type=11 DL, ETSI EN 300 392-2 +
// bluestation `mm/pdus/d_attach_detach_group_identity_acknowledgement.rs`).
// Emits the raw MM PDU MSB-aligned in a 128-bit bus along with its
// bit-length, ready to be wrapped by `tetra_mac_resource_dl_builder`.
//
// Per `reference_group_attach_bitexact.md` (gold-ref capture 2026-04-26 of
// external BS @ 392.9875 MHz, Burst #687/#1447/#2111/#2487/#2787 — five
// alterating-NR/NS slices, all accept_reject=0):
//
// MM body (variable, 1..3 GroupIdentityDownlink records):
//   [127:124]  mm_pdu_type            = 1011 (= 11, ATTACH-DETACH-GRP-ID-ACK)
//   [123]      group_identity_accept_reject  (0=ACCEPT, 1=REJECT)
//   [122]      reserved                = 0
//   [121]      o-bit                   = 1 (optional fields present)
//   [120]      p_proprietary           = 0 (skipped)
//   [119]      m_group_identity_downlink = 1
//   [118:115]  GID-DL elem_id          = 0111 (= 7)
//   [114:104]  GID-DL length          (11 bit, payload size in bits)
//   [103: 98]  num_elems               (6 bit, 1..3)
//   [ 97:   ]  N × GroupIdentityDownlink-struct (variable)
//   [   ]      m_grp_security          = 0
//   [   ]      trailing m-bit          = 0
//
// GroupIdentityDownlink-struct (per `mm/fields/group_identity_downlink.rs`):
//   [+0]       attach_detach_type_id   (1 bit, 0=attach, 1=detach)
//     if attach (=0):
//       [+1..+2] lifetime              (2 bit, GroupIdentityAttachment)
//       [+3..+5] class_of_usage        (3 bit)
//       attach total = 6 bit
//     if detach (=1):
//       [+1..+2] gid_detachment        (2 bit)
//       detach total = 3 bit
//   [..]       address_type            (2 bit, 0=GSSI, 1=GSSI+AE, 2=VGSSI)
//     if at∈{0,1}: [..+24] gssi (24 bit)
//     if at==1:    [..+24] address_extension (24 bit)
//     if at==2:    [..+24] vgssi (24 bit)
//
// For the Phase Y.1 MVP we support only at∈{0} GSSI-only records.  For
// at=0 attach the per-record size is 1 + 2 + 3 + 2 + 24 = 32 bit.  For
// 1 record + GID-DL header(4+11+6) + outer hdr+m+grp_sec+trailing
// (4+1+1+1+1+1+1) = 60 bit total MM body.
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_d_attach_detach_grp_id_ack_encoder (
    // Reply staging (from tetra_grp_reply_mailbox)
    input  wire         accept_reject,           // 0=ACCEPT, 1=REJECT
    input  wire [1:0]   gid_count,               // 0..3 GroupIdentityDownlink records
    input  wire [71:0]  gssi_array,              // 3 × 24-bit GSSI
    input  wire [5:0]   at_array,                // 3 × 2-bit address_type
    input  wire [5:0]   lifetime_array,          // 3 × 2-bit lifetime
    input  wire [2:0]   adi_array,               // 3 × 1-bit attach/detach selector
    input  wire [8:0]   class_array,             // 3 × 3-bit class_of_usage

    // Wrapper-oriented output — raw MM PDU, MSB-aligned to [127], explicit
    // bit-length in pdu_len_bits so MAC-RESOURCE wrapping
    // (tetra_mac_resource_dl_builder) embeds just the meaningful bits.
    output wire [127:0] pdu_bits_mm,
    output wire [7:0]   pdu_len_bits
);

    // PDU Type code — MM PDU type DL (bluestation MmPduTypeDl::DAttachDetach
    // GroupIdentityAcknowledgement = 11; gold-ref bit-forensik confirmed).
    localparam [3:0] MM_PDU_TYPE = 4'b1011;

    // Type-4 element ID (bluestation MmType34ElemIdDl::GroupIdentityDownlink)
    localparam [3:0] T4_ID_GROUP_IDENTITY_DOWNLINK = 4'd7;

    // -------------------------------------------------------------------------
    // Per-record GroupIdentityDownlink generator — single-record MVP.  We
    // emit at most `gid_count` records but only support at=0 (GSSI-only)
    // and adi=0 (attach) variants for now; record 0 is the typical case
    // for ITSI-Attach replies.
    //
    // Record layout (32 bit, attach + at=0):
    //   [+0]    adi=0  (attach)
    //   [+1..+2] lifetime  (2 bit)
    //   [+3..+5] class_of_usage (3 bit)
    //   [+6..+7] address_type=0 (2 bit)
    //   [+8..+31] gssi (24 bit)
    // -------------------------------------------------------------------------
    wire [31:0] rec0_w = {
        adi_array[0],                              // attach_detach_type_id
        lifetime_array[1:0],                       // lifetime (2)
        class_array[2:0],                          // class (3)
        at_array[1:0],                             // address_type (2)
        gssi_array[23:0]                           // gssi (24)
    };
    wire [31:0] rec1_w = {
        adi_array[1],
        lifetime_array[3:2],
        class_array[5:3],
        at_array[3:2],
        gssi_array[47:24]
    };
    wire [31:0] rec2_w = {
        adi_array[2],
        lifetime_array[5:4],
        class_array[8:6],
        at_array[5:4],
        gssi_array[71:48]
    };

    // -------------------------------------------------------------------------
    // Build the GID-DL inner payload + length according to gid_count.
    // We pre-compute up to 3 records concatenated MSB-first.  The unused
    // tail bits are masked off via pdu_len_bits.
    // -------------------------------------------------------------------------
    wire [10:0] gid_inner_len_w =
        (gid_count == 2'd0) ? 11'd0 :
        (gid_count == 2'd1) ? 11'd32 :
        (gid_count == 2'd2) ? 11'd64 :
                              11'd96;  // 3 records

    wire [10:0] gid_payload_len_w = (gid_count == 2'd0) ? 11'd6 :
                                                          (11'd6 + gid_inner_len_w);

    // -------------------------------------------------------------------------
    // MM body composition — variable length:
    //   accept (gid_count > 0):
    //     mm_pdu_type(4) + accept_reject(1) + reserved(1) + o-bit(1)
    //     + p_prop(1) + m_gid(1) + elem_id(4) + length(11) + num_elems(6)
    //     + N × 32 bit + m_grp_sec(1) + trailing(1)
    //   reject or empty (gid_count == 0):
    //     mm_pdu_type(4) + accept_reject(1) + reserved(1) + o-bit(0) + trailing(1)
    //     = 8 bit
    //
    // Single-record (typical): 4+1+1+1+1+1+4+11+6+32+1+1 = 63 bit (66 incl
    // trailing).  Two-record: 95.  Three-record: 127.  Reject: 8.
    // -------------------------------------------------------------------------
    wire [127:0] mm_attach_1rec_w = {
        MM_PDU_TYPE,                               // [127:124]
        accept_reject,                             // [123]
        1'b0,                                      // [122] reserved
        1'b1,                                      // [121] o-bit
        1'b0,                                      // [120] p_proprietary
        1'b1,                                      // [119] m_group_identity_downlink
        T4_ID_GROUP_IDENTITY_DOWNLINK,             // [118:115] elem_id (4)
        gid_payload_len_w,                         // [114:104] length (11)
        6'd1,                                      // [103: 98] num_elems
        rec0_w,                                    // [ 97: 66] record 0
        1'b0,                                      // [ 65] m_grp_security
        1'b0,                                      // [ 64] trailing m-bit
        64'd0                                      // [ 63:  0] padding
    };

    wire [127:0] mm_attach_2rec_w = {
        MM_PDU_TYPE,
        accept_reject,
        1'b0,
        1'b1,
        1'b0,
        1'b1,
        T4_ID_GROUP_IDENTITY_DOWNLINK,
        gid_payload_len_w,
        6'd2,
        rec0_w,
        rec1_w,
        1'b0,
        1'b0,
        32'd0
    };

    wire [127:0] mm_attach_3rec_w = {
        MM_PDU_TYPE,
        accept_reject,
        1'b0,
        1'b1,
        1'b0,
        1'b1,
        T4_ID_GROUP_IDENTITY_DOWNLINK,
        gid_payload_len_w,
        6'd3,
        rec0_w,
        rec1_w,
        rec2_w,
        1'b0,
        1'b0
    };

    wire [127:0] mm_reject_w = {
        MM_PDU_TYPE,                               // [127:124]
        accept_reject,                             // [123]
        1'b0,                                      // [122] reserved
        1'b0,                                      // [121] o-bit = 0
        1'b0,                                      // [120] trailing m-bit
        120'd0                                     // [119:  0] padding
    };

    // -------------------------------------------------------------------------
    // Output mux + length
    // -------------------------------------------------------------------------
    assign pdu_bits_mm =
        (gid_count == 2'd0) ? mm_reject_w :
        (gid_count == 2'd1) ? mm_attach_1rec_w :
        (gid_count == 2'd2) ? mm_attach_2rec_w :
                              mm_attach_3rec_w;

    assign pdu_len_bits =
        (gid_count == 2'd0) ? 8'd8 :              // reject / no records
        (gid_count == 2'd1) ? 8'd64 :             // 1 record
        (gid_count == 2'd2) ? 8'd96 :             // 2 records
                              8'd128;             // 3 records

endmodule

`default_nettype wire
