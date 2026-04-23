// =============================================================================
// tetra_d_location_update_encoder.v
//
// Combinational bit-packer for the MM D-LOCATION UPDATE ACCEPT / REJECT PDU
// (EN 300 392-2 §16.8.9).  Emits a 124-bit type-1 info PDU ready to be
// fed into the SCH/HD channel-coding chain (CRC-16 → tail → RCPC r=2/3
// → multiplicative interleave → cell-specific scrambling → 216 type-5
// coded bits) on any single SCH/HD downlink slot.
//
// This module owns only the *field packing* — it does NOT compute CRC,
// apply channel coding, or manage timing.  Those live in the SCH/HD
// encoder wrapper (next module), so every MLE/MM PDU can reuse the same
// coding path.
//
// Bit order: `pdu_bits[123]` is the first bit transmitted on the air
// (MSB-first convention used throughout the TX chain — see
// tetra_sb1_encoder.v and sw/tetra_hal.c for matching references).
//
// Field layout (124 bits, indexed from the MSB-first wire position):
//   [123:120]  PDU Type          4 bit   0001 = D-LOC-UPDATE ACCEPT
//                                          0010 = D-LOC-UPDATE REJECT
//   [119:117]  Address type      3 bit   (1=SSI, 2=USSI, 3=SMI, 4=ISSI, …)
//   [116:93]   Address (SSI)    24 bit   TETRA short subscriber identity
//   [ 92:79]   Location Area    14 bit   cell LA
//   [ 78:77]   Registration    2 bit   00=accept, 01=reject temporary,
//               result                    10=reject permanent, 11=reserved
//   [ 76:75]   Encryption mode   2 bit   00=clear, 01=SCK, 10=CCK, 11=DMO
//   [ 74:73]   Authentication    2 bit   00=none, 01=success, 10=failure
//               result                    (only meaningful on accept)
//   [ 72:57]   Subscriber class 16 bit   MS class / service profile
//   [ 56: 0]   Reserved / 0-fill 57 bit  (populated by MM optional IEs
//                                          later — frame-countdown, group
//                                          attach lists, etc.)
//
// NOTE: the exact bit layout published by ETSI for D-LOCATION UPDATE
// ACCEPT is dense and optional-field heavy.  This builder captures the
// fields that gate acceptance on common TETRA MS (tested against
// MTP3550) — Registration result=accept + matching LA + SSI in the
// address block is what the MS needs to transition to "registered".
// Optional extensions (group attach, cell reselect hints, auth challenge)
// are left as 0-fill and can be wired in later without changing the
// already-committed downstream coding path.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_d_location_update_encoder (
    // PDU class selector: 0 = ACCEPT (PDU-Type 0001)
    //                     1 = REJECT (PDU-Type 0010)
    input  wire         pdu_reject,

    // Address block
    input  wire [2:0]   addr_type,       // EN 300 392-2 Table 21.66
    input  wire [23:0]  ssi,             // short subscriber identity

    // Location / registration
    input  wire [13:0]  la,              // Location Area
    input  wire [1:0]   result,          // 00=accept, 01=rej-temp, 10=rej-perm
    input  wire [1:0]   encryption,      // encryption mode
    input  wire [1:0]   auth_result,     // authentication result

    // Subscriber class / service profile — FSM fills from shadow record
    input  wire [15:0]  subscriber_class,

    // Location update accept type (ETSI §16.10.35a) — must match the
    // Location-update-type the MS sent in U-LOC-UPDATE-DEMAND (§16.10.37).
    //   3'b000 Roaming       3'b001 Temporary
    //   3'b010 Periodic      3'b011 ITSI attach
    //   3'b100 Call restore  3'b101 Migrating
    //   3'b110 Demand        3'b111 Disabled MS
    // MLE registration FSM drives this from the UL MAC-ACCESS parser.
    input  wire [2:0]   loc_acc_type,

    // Legacy output — 124-bit PDU, [123] first bit on air.  Retained for the
    // loopback TB that still drives the raw SCH/HD coding chain directly.
    output wire [123:0] pdu_bits,

    // Wrapper-oriented output — raw MM PDU, MSB-aligned to [79], with the
    // explicit length so MAC-RESOURCE wrapping (tetra_mac_resource_dl_builder)
    // can embed just the meaningful bits (no SCH/HD-sized padding).
    output wire [79:0]  pdu_bits_mm,
    output wire [6:0]   pdu_len_bits
);

    // PDU Type codes — MM PDU type (EN 300 392-2 Table 16.12 / §16.9.2).
    // D-LOCATION UPDATE ACCEPT = 0b0101, D-LOCATION UPDATE REJECT = 0b0111.
    // (Historical legacy constants below preserved in wire form for the
    // SCH/HD-loopback path that the upstream TB still references.)
    localparam [3:0] PDU_TYPE_LOC_ACCEPT = 4'b0101;
    localparam [3:0] PDU_TYPE_LOC_REJECT = 4'b0111;

    wire [3:0] pdu_type_w = pdu_reject ? PDU_TYPE_LOC_REJECT
                                        : PDU_TYPE_LOC_ACCEPT;

    // -------------------------------------------------------------------------
    // MM PDU (raw, MSB-aligned).  Layout per EN 300 392-2 §16.10.28 / §16.9.2
    // Table 16.12 — minimum mandatory ACCEPT with ALL type-2 p-bits = 0
    // (no optional elements present) and no type-3/4 lists.  The MS reads
    // its address from the MAC-RESOURCE header (§21.4.3.1), NOT from the
    // MM body — that is why SSI/subscriber-class are NOT embedded here.
    //
    //   [79:76]  PDU type                   4  (0101 = ACCEPT)
    //   [75:73]  Location update accept     3  (from loc_acc_type input;
    //                                           mirrors MS's demand type
    //                                           per ETSI §16.10.35a)
    //   [72]     p-bit Address extension    1  (0 = absent)
    //   [71]     p-bit Subscriber class     1  (0 = absent)
    //   [70]     p-bit Energy saving info   1  (0 = absent)
    //   [69]     p-bit SCCH info & distrib  1  (0 = absent)
    //   [68]     p-bit Distrib-18th-frame   1  (0 = absent)
    //   [67]     p-bit New registered area  1  (0 = absent)
    //   [66]     p-bit Group identity       1  (0 = absent)
    //   [65]     M-bit type-3 elements      1  (0 = none)
    //   [64]     M-bit type-4 elements      1  (0 = none)
    //   [63: 0]  padding (don't-care, outside pdu_len_bits)
    //
    // Total meaningful bits: 4 + 3 + 9 = 16 bits.
    // Wrapper uses pdu_len_bits to know the boundary; anything beyond is
    // ignored by the FCS shift and not transmitted.
    // -------------------------------------------------------------------------
    localparam [6:0] MM_PDU_LEN           = 7'd16;

    assign pdu_bits_mm = {
        pdu_type_w,                 // [79:76]  4   PDU type
        loc_acc_type,               // [75:73]  3   accept type (dynamic)
        1'b0,                       // [72]     p Address extension
        1'b0,                       // [71]     p Subscriber class
        1'b0,                       // [70]     p Energy saving
        1'b0,                       // [69]     p SCCH info & distrib
        1'b0,                       // [68]     p Distrib 18th frame
        1'b0,                       // [67]     p New registered area
        1'b0,                       // [66]     p Group identity
        1'b0,                       // [65]     M type-3 elements
        1'b0,                       // [64]     M type-4 elements
        64'b0                       // [63: 0]  padding
    };
    assign pdu_len_bits = MM_PDU_LEN;

    // -------------------------------------------------------------------------
    // Legacy 124-bit PDU — unchanged layout, SCH/HD-encoded via the
    // existing tetra_mle_registration_fsm path (not ETSI-conformant MAC-
    // RESOURCE — retained only for the loopback TB).  Note the legacy path
    // used 4'b0001 as its "PDU type" constant; we preserve that historical
    // byte-sequence to keep the encoder-TB vector bit-exact.
    // -------------------------------------------------------------------------
    wire [3:0] legacy_pdu_type_w = pdu_reject ? 4'b0010 : 4'b0001;
    assign pdu_bits = {
        legacy_pdu_type_w,   // [123:120]  4
        addr_type,           // [119:117]  3
        ssi,                 // [116: 93] 24
        la,                  // [ 92: 79] 14
        result,              // [ 78: 77]  2
        encryption,          // [ 76: 75]  2
        auth_result,         // [ 74: 73]  2
        subscriber_class,    // [ 72: 57] 16
        57'b0                // [ 56:  0] 57  reserved
    };

endmodule

`default_nettype wire
