// =============================================================================
// tetra_d_attach_detach_group_identity_ack_encoder.v — Phase 7 F.7.3
// =============================================================================
//
// Combinational bit-packer for the MM D-ATTACH/DETACH GROUP IDENTITY
// ACKNOWLEDGEMENT PDU (ETSI EN 300 392-2 §16.9.2.2 / bluestation
// `mm/pdus/d_attach_detach_group_identity_acknowledgement.rs`).  Emits
// the raw MM PDU MSB-aligned in a 128-bit bus along with its bit-length,
// ready to be wrapped by the existing MAC-RESOURCE DL builder pair (see
// tetra_mac_resource_dl_builder.v with llc_pdu_type = 4'd0 = BL-ADATA).
//
// Bit-exact replica of the 2026-04-26 gold-reference 5 DL-ACK slices in
// `reference_group_attach_bitexact.md`.
//
// MM body layout (MSB-first; bit[0] = first on-air bit):
//
//   [0]      accept_reject                              1   (0=accept,
//                                                            1=reject)
//   [1]      reserved                                   1   = 0
//   [2]      o-bit                                      1
//   if obit:
//     // proprietary (Type-3, id=15) — encoder always omits → no bits
//     [3]    m-bit  (= 1, gid_dl present)               1
//     [4..7] elem_id = 0111 (= 7)                       4
//     [8..18] length (in bits)                         11
//     payload (length bits):
//       num_elem (6 bit)
//       per record:
//         attach_detach_type_id (1 bit, 0=attach 1=detach)
//         if attach (=0):
//           lifetime (2 bit)
//           class_of_usage (3 bit)
//         if detach (=1):
//           group_identity_detachment_uplink (2 bit)
//         address_type (2 bit, 0=GSSI, 1=GSSI+AE, 2=VGSSI)
//         if at∈{0,1}: gssi (24 bit)
//         if at == 1:  address_extension (24 bit) — NOT emitted in F.7
//         if at == 2:  vgssi (24 bit)              — NOT emitted in F.7
//     // group_identity_security_related_information (Type-4, id=12)
//     // — encoder always omits → no bits
//     trailing m-bit (= 0)                                1
//
// Phase 7 scope:
//   - up to 3 records
//   - address_type = 0 only (GSSI only) for emitted records;
//     at_array passes through transparently (Type-3 walker downstream
//     consumes whatever value).  Records with at∈{1,2,3} emit the same
//     base bits as at=0 (24-bit gssi only) and rely on the spec
//     compatibility (the MS parser uses at to choose the IE structure).
//
// Per-record sizes (Phase 7 scope, at=0):
//   attach: 1 + 2 + 3 + 2 + 24 = 32 bits
//   detach: 1 + 2 + 2 + 24     = 29 bits
//
// Length field = 6 (num_elem) + Σ record_size.  Examples:
//   1 attach        :  6 + 32 = 38   (matches all 5 gold-ref slices)
//   1 attach + detach:  6 + 32 + 29 = 67
//   3 attaches      :  6 + 32×3 = 102
//
// REJECT PDU (accept_reject=1): bluestation may emit obit=0 (no IEs)
// when the whole request is rejected.  Phase 7 scope: encoder emits
// obit=0 → only 3 useful bits + trailing zero pad.  Gold-ref capture
// has no REJECT slice; this branch is ETSI-derived best-guess and gets
// flagged for later capture-verification.
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_d_attach_detach_group_identity_ack_encoder (
    input  wire           accept_reject,
    input  wire [2:0]     count,                   // 0..3
    input  wire [2:0]     attach_array,            // per-record 0=attach 1=detach
    input  wire [5:0]     lifetime_array,          // 3×2 bit
    input  wire [8:0]     class_array,             // 3×3 bit (or detach code at LSB 2)
    input  wire [5:0]     at_array,                // 3×2 bit
    input  wire [71:0]    gssi_array,              // 3×24 bit

    output wire [127:0]   pdu_bits_mm,
    output wire [7:0]     pdu_len_bits
);

    localparam [3:0] T4_ID_GID_DL = 4'd7;

    // -------------------------------------------------------------------------
    // Per-record size + bit-pattern.  Each record is built MSB-first into a
    // 32-bit working register (top sz bits valid, lower bits zero).  Phase 7
    // emits at=0 paths only (24-bit gssi, no AE/VGSSI extensions).
    // -------------------------------------------------------------------------
    function [6:0] record_size_f;       // 32 or 29 (need 6 bits)
        input attach_bit;
        begin
            record_size_f = (attach_bit == 1'b0) ? 7'd32 : 7'd29;
        end
    endfunction

    // Build the record bits MSB-aligned in a 32-bit word.
    function [31:0] record_bits_f;
        input        attach_bit;
        input [1:0]  lt_bits;
        input [2:0]  class_bits;
        input [1:0]  at_bits;
        input [23:0] gssi_bits;
        reg [31:0]   out;
        begin
            if (attach_bit == 1'b0) begin
                // attach: ATD(0) lifetime(2) class(3) at(2) gssi(24) = 32
                // MSB-first: bit31=ATD, bits30..29=lt, 28..26=class,
                //            25..24=at, 23..0=gssi.
                out = {1'b0, lt_bits, class_bits, at_bits, gssi_bits};
            end else begin
                // detach: ATD(1) detach(2) at(2) gssi(24) = 29 bits
                // MSB-first into 32-bit, bottom 3 bits are zero pad.
                // class_bits[1:0] holds the detach_code in the calling
                // convention (we ignore class_bits[2]).
                out = {1'b1, class_bits[1:0], at_bits, gssi_bits, 3'b000};
            end
            record_bits_f = out;
        end
    endfunction

    wire [6:0]  sz0 = record_size_f(attach_array[0]);
    wire [6:0]  sz1 = record_size_f(attach_array[1]);
    wire [6:0]  sz2 = record_size_f(attach_array[2]);

    wire [31:0] rb0 = record_bits_f(attach_array[0],
                                    lifetime_array[1:0],
                                    class_array[2:0],
                                    at_array[1:0],
                                    gssi_array[23:0]);
    wire [31:0] rb1 = record_bits_f(attach_array[1],
                                    lifetime_array[3:2],
                                    class_array[5:3],
                                    at_array[3:2],
                                    gssi_array[47:24]);
    wire [31:0] rb2 = record_bits_f(attach_array[2],
                                    lifetime_array[5:4],
                                    class_array[8:6],
                                    at_array[5:4],
                                    gssi_array[71:48]);

    // payload_total_bits = 6 (num_elem) + Σ active record sizes
    wire [10:0] payload_total_bits =
        11'd6
        + ((count >= 3'd1) ? {4'd0, sz0} : 11'd0)
        + ((count >= 3'd2) ? {4'd0, sz1} : 11'd0)
        + ((count >= 3'd3) ? {4'd0, sz2} : 11'd0);

    // -------------------------------------------------------------------------
    // Build the payload (num_elem + records) MSB-aligned in a 192-bit buffer.
    //
    // Layout in the 192-bit buffer:
    //   bits [191:186]  num_elem (6 bit)
    //   bits [185 - off_r0_lsb : 185]  record 0 (sz0 bits)
    //   bits [185 - off_r0_lsb - sz1 : 185 - off_r0_lsb - 1]  record 1
    //   ...
    //
    // We compute each record's "place into 192-bit" via right-shifting
    // its 32-bit working register so the valid bits sit in the lower
    // (sz) bits, then left-shifting by (192 - 6 - prev_offsets - sz).
    // -------------------------------------------------------------------------
    wire [10:0] off_r0 = 11'd6;
    wire [10:0] off_r1 = off_r0 + {4'd0, sz0};
    wire [10:0] off_r2 = off_r1 + {4'd0, sz1};

    // Each record's bits LSB-aligned to its size (so we can left-shift it
    // into place).  rb_top[(sz-1):0] = valid bits.
    wire [31:0] r0_lsb = rb0 >> (7'd32 - sz0);
    wire [31:0] r1_lsb = rb1 >> (7'd32 - sz1);
    wire [31:0] r2_lsb = rb2 >> (7'd32 - sz2);

    // Place each piece in the 192-bit MSB-aligned buffer.  The MSB-most
    // bit of the field lands at (192 - 1 - prev_offset).  Equivalently,
    // we left-shift the LSB-aligned value by (192 - prev_offset - sz).
    wire [191:0] num_elem_192 =
        {{186{1'b0}}, count} << (192 - 6);

    wire [191:0] r0_192 = (count >= 3'd1)
        ? ({{160{1'b0}}, r0_lsb} << (192 - off_r0 - {4'd0, sz0}))
        : 192'd0;
    wire [191:0] r1_192 = (count >= 3'd2)
        ? ({{160{1'b0}}, r1_lsb} << (192 - off_r1 - {4'd0, sz1}))
        : 192'd0;
    wire [191:0] r2_192 = (count >= 3'd3)
        ? ({{160{1'b0}}, r2_lsb} << (192 - off_r2 - {4'd0, sz2}))
        : 192'd0;

    wire [191:0] payload_192 = num_elem_192 | r0_192 | r1_192 | r2_192;

    // -------------------------------------------------------------------------
    // Header (19 bits MSB-first):
    //   [127] accept_reject
    //   [126] reserved (= 0)
    //   [125] obit (= 1 for accept)
    //   [124] m-bit (= 1, GID-DL present)
    //   [123:120] elem_id = 4'd7
    //   [119:109] length (= payload_total_bits)
    //
    // Then payload (payload_total_bits bits) starts at bit [108] downward.
    // Then trailing m-bit (= 0) at bit (108 - payload_total_bits).
    // -------------------------------------------------------------------------
    wire [127:0] header_msb = {
        accept_reject,                  // [127]
        1'b0,                           // [126]
        1'b1,                           // [125] obit
        1'b1,                           // [124] m-bit
        T4_ID_GID_DL,                   // [123:120]
        payload_total_bits,             // [119:109]
        109'd0                          // [108:0]
    };

    // Right-shift the 192-bit MSB-aligned payload so its top
    // payload_total_bits land at [108:108-payload_total_bits+1] of a
    // 128-bit buffer.  payload_192's top bits are at [191:191-pt+1].
    // We need them at [108:...].  Difference = 191 - 108 = 83.
    //   payload_128 = payload_192[191:64];     // top 128 bits
    //   payload_shifted = payload_128 >> 19;   // shift down by 19 to
    //                                          // make space for header
    wire [127:0] payload_top128 = payload_192[191:64];
    wire [127:0] payload_shifted = payload_top128 >> 19;

    // Trailing m-bit at bit position (128 - 19 - payload_total_bits - 1)
    // ... but it is 0, so no OR contribution.  We only need to remember
    // its position for pdu_len_bits accounting.

    wire [127:0] mm_accept_w = header_msb | payload_shifted;

    // REJECT: obit=0 → only 3 useful bits.  No IE list, no trailing m-bit
    // (per bluestation early-return when obit=0).
    wire [127:0] mm_reject_w = {
        1'b1,                           // [127] accept_reject = 1
        1'b0,                           // [126] reserved
        1'b0,                           // [125] obit = 0
        125'd0
    };

    // Total bit-length of the meaningful PDU.  ACCEPT: 3 (header T1) +
    // 16 (m-bit + id + length) + payload_total_bits + 1 (trailing m-bit)
    //                                    = 20 + payload_total_bits.
    // REJECT: 3 (T1 + obit=0).
    wire [7:0] len_accept_w = 8'd20 + payload_total_bits[7:0];
    wire [7:0] len_reject_w = 8'd3;

    assign pdu_bits_mm  = (accept_reject == 1'b1) ? mm_reject_w  : mm_accept_w;
    assign pdu_len_bits = (accept_reject == 1'b1) ? len_reject_w : len_accept_w;

endmodule

`default_nettype wire
