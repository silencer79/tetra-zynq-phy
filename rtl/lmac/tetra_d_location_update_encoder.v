// =============================================================================
// tetra_d_location_update_encoder.v
//
// Phase X.7 — Legacy 124-bit pdu_bits output + its dedicated address /
// subscriber_class / address_extension inputs removed.  Only the
// MM-Body wrapper output (pdu_bits_mm + pdu_len_bits) remains; that
// is the only path the post-X.4 MLE-FSM uses to drive the shared
// tetra_dl_pdu_builder.  M2 bit-identity guard preserved.
//
// Combinational bit-packer for the MM D-LOCATION UPDATE ACCEPT / REJECT PDU
// (EN 300 392-2 §16.10.x, ETSI 16.9.2.7).  Emits the raw MM PDU MSB-aligned
// in a 128-bit bus along with its bit-length, ready to be wrapped by the
// MAC-RESOURCE DL builder.
//
// Bit-exact replica of the 2026-04-25 gold-reference Accept (Burst #735 in
// docs/references/captures_external_bs_2026-04-25/, MM body = 102 bit):
//
//   [127:124]  PDU type                                4    = 0101 (ACCEPT)
//   [123:121]  Location update accept type             3    (echo MS demand)
//   [120]      o-bit                                   1    = 1
//   [119]      p-bit SSI                               1    = 0   (NO SSI in MM body —
//                                                                  SSI lives in the
//                                                                  MAC-RESOURCE addr field)
//   [118]      p-bit Address-Extension                 1    = 0
//   [117]      p-bit Subscriber-Class                  1    = 0
//   [116]      p-bit Energy-Saving-Info                1    = 1
//   [115:102]  Energy-Saving-Info                     14    = 0 (StayAlive: ESM=0, FN=0, MN=0)
//   [101]      p-bit SCCH-info-and-Distrib-18         1    = 0
//   [100]      m-bit (Type-3 element follows)          1    = 1
//   [ 99: 96]  Type-3 elem_id                          4    = 0101 (= 5,
//                                                                  GroupIdentityLocationAccept)
//   [ 95: 85]  Type-3 length (= GILA payload bits)    11    = 58
//   [ 84: 27]  GILA payload                           58    (gold-ref: bit-exact replica
//                                                            of the external-BS Burst #735
//                                                            GILA — see GILA_PAYLOAD below)
//   [ 26]      Trailing m-bit (D-LOC-UPDATE-ACCEPT)    1    = 0
//   [ 25:  0]  padding (don't-care, outside pdu_len_bits)  26
//
// Total meaningful bits: 4+3 + 1+1+1+1 + 1+14 + 1 + 1+4+11+58 + 1 = 102.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_d_location_update_encoder (
    // PDU class selector: 0 = ACCEPT (PDU-Type 0001)
    //                     1 = REJECT (PDU-Type 0010)
    input  wire         pdu_reject,

    // Energy Saving Information (ETSI §16.10.27 — 14 bits total):
    //   [13:11] energy_saving_mode (3 bit; 0=StayAlive)
    //   [10: 6] frame_number       (5 bit; 0 when StayAlive)
    //   [ 5: 0] multiframe_number  (6 bit; 0 when StayAlive)
    input  wire [13:0]  energy_saving_info,

    // Location update accept type (ETSI §16.10.35a) — must match the
    // Location-update-type the MS sent in U-LOC-UPDATE-DEMAND (§16.10.37).
    input  wire [2:0]   loc_acc_type,

    // ----------------------------------------------------------------------
    // Phase 6 D-rev — dynamic GILA inputs (§9.3 Multi-Lookup attach flow).
    //   gila_gssi      24-bit GSSI emitted into the GroupIdentityDownlink
    //                   entry.  Sourced from EntityTable default-GSSI scan
    //                   when AST.group_count==0 (which is always the case
    //                   in Phase D — RX IE parser is M3 scope).
    //   gila_class      3-bit class_of_usage (M2-default = 4 = 3'b100).
    //   gila_lifetime   2-bit lifetime field (M2-default = 1 = 2'b01).
    //   gila_present    1 = include GILA Type-3 element (default M2 path),
    //                   0 = omit GILA entirely (no default GSSI in cell;
    //                       MM body shrinks from 102 to 36 bits).
    //
    // For M2 bit-identity guard (Profile 0 + GSSI 0x2F4D61 + class=4 +
    // lifetime=1) the encoder must produce the SAME 102-bit MM body as the
    // pre-D constant — verified bit-for-bit in tb_mle_registration_fsm
    // (profile0_m2_guard test case).
    // ----------------------------------------------------------------------
    input  wire [23:0]  gila_gssi,
    input  wire [2:0]   gila_class,
    input  wire [1:0]   gila_lifetime,
    input  wire         gila_present,

    // Wrapper-oriented output — raw MM PDU, MSB-aligned to [127], explicit
    // bit-length in pdu_len_bits so MAC-RESOURCE wrapping
    // (tetra_mac_resource_dl_builder) embeds just the meaningful bits.
    output wire [127:0] pdu_bits_mm,
    output wire [7:0]   pdu_len_bits
);

    // PDU Type codes — MM PDU type DL (EN 300 392-2 Table 16.12).
    localparam [3:0] PDU_TYPE_LOC_ACCEPT = 4'b0101;
    localparam [3:0] PDU_TYPE_LOC_REJECT = 4'b0111;

    wire [3:0] pdu_type_w = pdu_reject ? PDU_TYPE_LOC_REJECT
                                        : PDU_TYPE_LOC_ACCEPT;

    // Type-3/4 element IDs (bluestation MmType34ElemIdDl).
    localparam [3:0] T3_ID_GROUP_IDENTITY_LOCATION_ACCEPT = 4'd5;
    localparam [3:0] T4_ID_GROUP_IDENTITY_DOWNLINK        = 4'd7;

    // -------------------------------------------------------------------------
    // GILA payload (58 bit) — bit-exact replica of the external-BS gold
    // reference Burst #735 (docs/references/captures_external_bs_2026-04-25/).
    //
    // Internal layout per bluestation `group_identity_location_accept.rs`
    // and `group_identity_downlink.rs`:
    //
    //   accept_reject(1)  reserved(1)  obit(1)
    //     m-bit(1)+id=7(4)+length=38(11)+num_elems=1(6)
    //       attach_type=0(1) lifetime(2) class(3) addr_type=00(2) gssi(24)
    //   trailing m-bit(1)
    //
    // Phase 6 D-rev — payload is now constructed from `gila_gssi`,
    // `gila_class`, `gila_lifetime` inputs (driven by the MLE-FSM from
    // EntityTable+ProfileTable lookup results).  M2 bit-identity guard:
    // for {gssi=0x2F4D61, class=4, lifetime=1} the constructed payload is
    // bit-identical to the pre-D constant
    //   58'b0011011100000100110000001001100000010111101001101011000010.
    //
    // See ~/.claude/.../memory/reference_gold_attach_bitexact.md for the
    // gold-ref bit pattern.
    // -------------------------------------------------------------------------
    wire [57:0] GILA_PAYLOAD_W = {
        // accept_reject(0) + reserved(0) + o-bit(1)
        3'b001,
        // m-bit(1) + elem_id=7(4) + length=38(11)
        1'b1,
        T4_ID_GROUP_IDENTITY_DOWNLINK,             // 4 bit (= 7)
        11'd38,                                    // length
        // num_elems = 1 (6 bit)
        6'd1,
        // GroupIdentityDownlink entry (32 bit):
        //   attach_detach_type_id (1) + lifetime (2) + class (3) +
        //   address_type (2) + GSSI (24)
        1'b0,                                      // attach_detach_type_id
        gila_lifetime,                             // 2 bit
        gila_class,                                // 3 bit
        2'b00,                                     // address_type = gssi only
        gila_gssi,                                 // 24 bit
        // trailing m-bit (GILA itself)
        1'b0
    };
    localparam [10:0] GILA_LENGTH = 11'd58;

    // -------------------------------------------------------------------------
    // MM body — variable length depending on `gila_present`:
    //   GILA present  (default): 102 bit  — Type-3 GILA emitted, M2-compat.
    //   GILA absent:               36 bit  — Type-3 m-bit clears, no GILA.
    //
    // Both forms are MSB-aligned in [127].  pdu_len_bits gates how many
    // bits the MAC-RESOURCE wrapper embeds; the trailing zeros are
    // padding.
    //
    // Bit positions when GILA present (verbatim §16.10.x layout):
    //   [127:124]  PDU type        4
    //   [123:121]  loc_acc_type    3
    //   [120]      o-bit           1   = 1
    //   [119:117]  p-bits SSI/AE/SC each = 0 (3 bit)
    //   [116]      p-bit ESI       1   = 1
    //   [115:102]  ESI            14
    //   [101]      p-bit SCCH-info 1   = 0
    //   [100]      m-bit T3        1   = 1 (GILA follows)
    //   [ 99: 96]  T3 elem_id      4   = 5
    //   [ 95: 85]  T3 length      11   = 58
    //   [ 84: 27]  GILA payload   58
    //   [ 26]      trailing m-bit  1   = 0
    //   [ 25:  0]  padding        26
    //
    // Bit positions when GILA absent:
    //   [127:124]  PDU type        4
    //   [123:121]  loc_acc_type    3
    //   [120]      o-bit           1   = 1
    //   [119:117]  p-bits SSI/AE/SC each = 0 (3 bit)
    //   [116]      p-bit ESI       1   = 1
    //   [115:102]  ESI            14
    //   [101]      p-bit SCCH-info 1   = 0
    //   [100]      m-bit T3        1   = 0 (no GILA)
    //   [ 99]      trailing m-bit  1   = 0
    //   [ 98:  0]  padding        99
    // -------------------------------------------------------------------------
    wire [127:0] mm_with_gila_w = {
        pdu_type_w,                                // [127:124]   4
        loc_acc_type,                              // [123:121]   3
        1'b1,                                      // [120]
        1'b0,                                      // [119] p_ssi
        1'b0,                                      // [118] p_address_extension
        1'b0,                                      // [117] p_subscriber_class
        1'b1,                                      // [116] p_energy_saving_info
        energy_saving_info,                        // [115:102]  14
        1'b0,                                      // [101] p_scch_info
        1'b1,                                      // [100] m-bit T3 follows
        T3_ID_GROUP_IDENTITY_LOCATION_ACCEPT,      // [ 99: 96]   4
        GILA_LENGTH,                               // [ 95: 85]  11
        GILA_PAYLOAD_W,                            // [ 84: 27]  58
        1'b0,                                      // [ 26] trailing m-bit
        26'b0                                      // [ 25:  0]  padding
    };

    wire [127:0] mm_without_gila_w = {
        pdu_type_w,                                // [127:124]   4
        loc_acc_type,                              // [123:121]   3
        1'b1,                                      // [120]
        1'b0,                                      // [119] p_ssi
        1'b0,                                      // [118] p_address_extension
        1'b0,                                      // [117] p_subscriber_class
        1'b1,                                      // [116] p_energy_saving_info
        energy_saving_info,                        // [115:102]  14
        1'b0,                                      // [101] p_scch_info
        1'b0,                                      // [100] m-bit T3 = 0 (no GILA)
        1'b0,                                      // [ 99] trailing m-bit
        99'b0                                      // [ 98:  0]  padding
    };

    assign pdu_bits_mm  = gila_present ? mm_with_gila_w  : mm_without_gila_w;
    assign pdu_len_bits = gila_present ? 8'd102          : 8'd36;

endmodule

`default_nettype wire
