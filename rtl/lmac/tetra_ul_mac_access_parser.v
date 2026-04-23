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
//   [19:23) 4-bit aux / presence-flags field (empirically 0xE for MTP3550
//           RA; ETSI leaves this as reservation-requirement / PwrCtrl+
//           SlotGrant+ChanAlloc pres.  Not semantically parsed by us.)
//   [23:27) MM PDU-type (4 bits, uplink discriminator per §16.10.39)
//   [27:30) Location update type (3 bits) — only meaningful when
//           MM PDU-type == 0x4 (U-LOCATION-UPDATE-DEMAND).  Pass-through
//           so the MLE registration FSM can echo the matching
//           Location-update-accept-type in the D-LOC-UPDATE-ACCEPT response
//           (ETSI §16.10.35a, value table identical to §16.10.37).
//   remainder: further MM fields (class-of-MS, cipher-control, addr-ext,
//              etc.) — not parsed here.
//
// Only pdu_type == 2'b00 (MAC-ACCESS) is decoded; other types flag as
// "unhandled" but still pulse pdu_valid_sys so SW can see raw bits.
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
    output reg  [15:0]               pdu_count_sys     // sticky counter
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
    end else begin
        pdu_valid_sys <= 1'b0;
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
        end
    end
end

endmodule

`default_nettype wire
