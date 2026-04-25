// =============================================================================
// tetra_d_location_update_encoder.v
//
// Combinational bit-packer for the MM D-LOCATION UPDATE ACCEPT / REJECT PDU
// (EN 300 392-2 §16.10.x, ETSI 16.9.2.7).  Emits the raw MM PDU MSB-aligned
// in a 128-bit bus along with its bit-length, ready to be wrapped by the
// MAC-RESOURCE DL builder.
//
// Bluestation-compliant Accept body (always present fields — gold-reference
// `captures_external_bs_2026-04-25/`):
//
//   [127:124]  PDU type                                4    (0101 = ACCEPT)
//   [123:121]  Location update accept type             3    (echo MS demand)
//   [120]      o-bit                                   1    = 1
//   [119]      p-bit SSI                               1    = 1
//   [118: 95]  SSI                                    24
//   [ 94]      p-bit Address-Extension                 1    = 1
//   [ 93: 70]  Address-Extension (MNI = MCC<<14 | MNC) 24
//   [ 69]      p-bit Subscriber-Class                  1    = 1
//   [ 68: 53]  Subscriber-Class                       16
//   [ 52]      p-bit Energy-Saving-Info                1    = 1
//   [ 51: 38]  Energy-Saving-Info                     14    (ESM 3 + FN 5 + MN 6)
//   [ 37]      p-bit SCCH-info-and-Distrib-18         1    = 0
//   [ 36]      m-bit Security-Downlink                1    = 1
//   [ 35: 32]  Type3 ID = Security-Downlink           4    = 3
//   [ 31: 21]  Type3 length                           11   = 0
//   [ 20]      Trailing m-bit                         1    = 0
//   [ 19:  0]  padding (don't-care, outside pdu_len_bits)  20
//
// Total meaningful bits:
//   4+3+1 + (1+24)+(1+24)+(1+16)+(1+14) + 1 + (1+4+11+0) + 1 = 108.
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

    // Location / registration (legacy 124-bit path only)
    input  wire [13:0]  la,              // Location Area
    input  wire [1:0]   result,          // 00=accept, 01=rej-temp, 10=rej-perm
    input  wire [1:0]   encryption,      // encryption mode
    input  wire [1:0]   auth_result,     // authentication result

    // Subscriber class — used in BOTH legacy 124-bit and new MM 128-bit paths
    input  wire [15:0]  subscriber_class,

    // Address Extension (MNI = MCC[9:0]<<14 | MNC[13:0])
    input  wire [23:0]  address_extension,

    // Energy Saving Information (ETSI §16.10.27 — 14 bits total):
    //   [13:11] energy_saving_mode (3 bit; 0=StayAlive)
    //   [10: 6] frame_number       (5 bit; 0 when StayAlive)
    //   [ 5: 0] multiframe_number  (6 bit; 0 when StayAlive)
    input  wire [13:0]  energy_saving_info,

    // Location update accept type (ETSI §16.10.35a) — must match the
    // Location-update-type the MS sent in U-LOC-UPDATE-DEMAND (§16.10.37).
    input  wire [2:0]   loc_acc_type,

    // Legacy output — 124-bit PDU, [123] first bit on air.  Retained for the
    // loopback TB.
    output wire [123:0] pdu_bits,

    // Wrapper-oriented output — raw MM PDU, MSB-aligned to [127], explicit
    // bit-length in pdu_len_bits so MAC-RESOURCE wrapping
    // (tetra_mac_resource_dl_builder) embeds just the meaningful bits.
    output wire [127:0] pdu_bits_mm,
    output wire [7:0]   pdu_len_bits
);

    // PDU Type codes — MM PDU type (EN 300 392-2 Table 16.12 / §16.9.2).
    localparam [3:0] PDU_TYPE_LOC_ACCEPT = 4'b0101;
    localparam [3:0] PDU_TYPE_LOC_REJECT = 4'b0111;

    wire [3:0] pdu_type_w = pdu_reject ? PDU_TYPE_LOC_REJECT
                                        : PDU_TYPE_LOC_ACCEPT;

    // -------------------------------------------------------------------------
    // MM PDU body — extended Accept.  The type-2 fields Address-Extension,
    // Subscriber-Class, and Energy-Saving-Info are always present.  After the
    // type-2 block we emit a structurally valid zero-length Security-Downlink
    // type-3 header followed by the terminating m-bit.  This matches the
    // 21-octet full Accept sizing seen in the external BS reference and avoids
    // the old incorrect "one zero m-bit per absent type3/4 field" packing.
    // -------------------------------------------------------------------------
    localparam [7:0] MM_PDU_LEN = 8'd108;
    localparam [3:0] TYPE3_ID_SECURITY_DOWNLINK = 4'd3;

    assign pdu_bits_mm = {
        pdu_type_w,                 // [127:124]  4   PDU type
        loc_acc_type,               // [123:121]  3   accept type
        1'b1,                       // [120]      o-bit
        1'b1,                       // [119]      p SSI
        ssi,                        // [118: 95] 24
        1'b1,                       // [ 94]      p Address-Extension
        address_extension,          // [ 93: 70] 24
        1'b1,                       // [ 69]      p Subscriber-Class
        subscriber_class,           // [ 68: 53] 16
        1'b1,                       // [ 52]      p Energy-Saving-Info
        energy_saving_info,         // [ 51: 38] 14
        1'b0,                       // [ 37]      p SCCH-info-and-Distrib-18
        1'b1,                       // [ 36]      m Security-Downlink present
        TYPE3_ID_SECURITY_DOWNLINK, // [ 35: 32] type-3 field ID
        11'd0,                      // [ 31: 21] type-3 payload length = 0
        1'b0,                       // [ 20]      trailing m-bit
        20'b0                       // [ 19:  0]  padding
    };
    assign pdu_len_bits = MM_PDU_LEN;

    // -------------------------------------------------------------------------
    // Legacy 124-bit PDU — unchanged layout, used by the loopback TB only.
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
        57'b0                // [ 56:  0] 57
    };

endmodule

`default_nettype wire
