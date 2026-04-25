// =============================================================================
// tetra_d_location_update_reject_encoder.v
//
// Combinational bit-packer for the MM D-LOCATION UPDATE REJECT PDU
// (ETSI EN 300 392-2 §16.10.40).  Emits the raw MM PDU MSB-aligned in a
// 128-bit bus along with its bit-length, ready to be wrapped by the
// MAC-RESOURCE DL builder.
//
// Minimal Reject body (no optional fields, ETSI Table 16.42):
//
//   [127:124]  PDU type        4   = 0111 (7 = D-LOC-UPDATE-REJECT,
//                                    `MmPduTypeDl::DLocationUpdateReject`)
//   [123:121]  Reject cause    3   ETSI Table 16.43:
//                                    000 = ITSI unknown
//                                    001 = illegal MS
//                                    010 = no resources available
//                                    011 = unspecified
//                                    100 = service not authorised
//                                    101 = subscription expired
//                                    110 = roaming not allowed
//                                    111 = forbidden LA
//   [120]      o-bit           1   = 0 (no optional fields → PDU ends here)
//   [119:  0]  padding        120  (don't-care, outside pdu_len_bits)
//
// Total meaningful bits: 4 + 3 + 1 = 8.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_d_location_update_reject_encoder (
    // Reject cause (ETSI §16.10.40 Table 16.43)
    input  wire [2:0]   reject_cause,

    // Wrapper-oriented output — raw MM PDU, MSB-aligned to [127], with
    // explicit bit-length so the MAC-RESOURCE wrapper embeds just the
    // meaningful bits (no SCH/F-sized padding).
    output wire [127:0] pdu_bits_mm,
    output wire [7:0]   pdu_len_bits
);

    localparam [3:0] PDU_TYPE_REJECT = 4'b0111;
    localparam [7:0] MM_REJECT_LEN   = 8'd8;

    assign pdu_bits_mm = {
        PDU_TYPE_REJECT,    // [127:124]   4   PDU type = 7
        reject_cause,       // [123:121]   3   cause
        1'b0,               // [120]       o-bit = 0 (no optional fields)
        120'b0              // [119:  0]   padding
    };
    assign pdu_len_bits = MM_REJECT_LEN;

endmodule

`default_nettype wire
