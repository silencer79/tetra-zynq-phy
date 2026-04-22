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

    // Output — 124-bit PDU, [123] first bit on air
    output wire [123:0] pdu_bits
);

    // PDU Type codes — EN 300 392-2 Table 21.72 (PDU type field, MM layer)
    localparam [3:0] PDU_TYPE_LOC_ACCEPT = 4'b0001;
    localparam [3:0] PDU_TYPE_LOC_REJECT = 4'b0010;

    wire [3:0] pdu_type_w = pdu_reject ? PDU_TYPE_LOC_REJECT
                                        : PDU_TYPE_LOC_ACCEPT;

    assign pdu_bits = {
        pdu_type_w,          // [123:120]  4
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
