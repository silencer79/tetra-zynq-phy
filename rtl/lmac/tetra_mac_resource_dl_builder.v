// =============================================================================
// tetra_mac_resource_dl_builder.v
//
// Wraps a raw MM PDU (e.g. D-LOCATION-UPDATE-ACCEPT from
// tetra_d_location_update_encoder) into a full ETSI EN 300 392-2 MAC-RESOURCE
// downlink PDU destined for SCH/F signalling:
//
//   MAC-RESOURCE DL header (§21.4.3.1 Table 21.55)
//     PDUtype(2)=00  FillBit(1)  PosOfGrant(1)=0  Encr(2)=00
//     RandAccFlag(1)=random_access_flag  LengthInd(6)  AddrType(3)=001  SSI(24)
//     NOTE: PowerCtrl/SlotGrant/ChanAlloc presence flags (3 bits) are
//     ONLY emitted when PosOfGrant=1 AND addr!=NULL AND LI!=0 per
//     §21.4.3.1.  Since this builder hard-codes PosOfGrant=0 for a pure
//     registration ACCEPT, the 3 flag bits are OMITTED — TM-SDU starts
//     immediately after the 24-bit SSI at bit 40.
//     TM-SDU:
//       LLC BL-ADATA-FCS (§22.2.2, pdu_type=0100)
//         PDUtype(4)=0100  N(R)(1)  N(S)(1)
//         TL-SDU:
//           MLE ProtDisc(3)=001 (MM)
//           MM D-LOC-UPDATE-ACCEPT (~72 bit, caller-supplied)
//       FCS(32) = CRC-32 over {LLC header + TL-SDU}
//       Polynomial 0x04C11DB7, init 0xFFFFFFFF, final ones-complement,
//       MSB-first convention (ETSI §22.2.2.5, matches osmo-tetra reference).
//     FillBits — first fill bit = 1, remainder 0, pad out to PDU_BITS (=268).
//
// Conventions:
//   - pdu_bits[267] is the first bit on air (MSB-first, identical to
//     tetra_d_location_update_encoder, tetra_sb1_encoder, tetra_sch_hd_encoder).
//   - Addr type fixed to SSI (3'b001); other types (USSI/SMI/etc.) would
//     change the address payload length and are out of scope for MVP.
//   - Power-control / slot-granting / channel-allocation flags are all 0 —
//     we're sending a pure registration ACCEPT, no resource grants attached.
//
// FCS input ordering (§22.2.2.5):
//   CRC is computed over the LLC PDU header (6 bits) concatenated with the
//   full TL-SDU (MLE ProtDisc + MM PDU bits), MSB-first, bit-serial.  We use
//   a 32-bit shift register with xor-poly feedback, then complement the
//   final residue per spec.
//
// Length encoding (§21.4.3.1 Table 21.56):
//   SCH/F maximum TM-SDU length is 239 bits (~30 octets after the header).
//   The length indication encodes the TOTAL MAC-RESOURCE PDU size in octets
//   (Y2=Z2=1 for pi/4-DQPSK).  Decode curve (Table 21.55):
//     val <= 18 : octets = val
//     val  > 18 : octets = 18 + (val - 18) = val
//   So val == octets directly for our range.  We pad the raw bit count up to
//   the nearest byte for the length field.
//
// Latency:
//   1 (IDLE) + 1 (ASSEMBLE_INNER) + 1 (LLC_HEAD) + total_len (FCS shift) +
//   1 (MAC_HEAD) + 1 (PAD) + 1 (DONE) ≈ max ~160 cycles for a 72-bit MM PDU.
//
// Coding rules (Verilog-2001 strict):
//   R1  one always block per register
//   R4  async active-low reset
//   R9  no initial blocks
//   R10 @(*) for combinatorial
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_mac_resource_dl_builder #(
    parameter integer PDU_BITS = 268  // SCH/F MAC-SDU size
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // 1-cycle pulse: sample inputs and begin assembly
    input  wire                  start,

    // MAC address — MVP only SSI supported
    input  wire [23:0]           ssi,
    input  wire [2:0]            addr_type,      // usually 3'b001 (SSI)

    // LLC sequence numbers (from active-session-table per-MS state)
    input  wire                  ns,
    input  wire                  nr,

    // MAC-RESOURCE header RandAccFlag (ETSI §21.4.3.1).  Caller decides:
    //   1 = this PDU is a response to a successful UL Random Access and
    //       implicitly acknowledges the MS's RA (RA-ack piggyback).  The
    //       MS stops retrying RA requests upon seeing this bit.
    //   0 = unsolicited DL signalling (e.g. CMCE broadcast, SDS), or
    //       GSSI-addressed group signalling.
    // The builder does NOT infer this — the semantic belongs at the
    // callsite (e.g. MLE-Registration FSM sets 1 because D-LOC-UPDATE-
    // ACCEPT is always a RA response).
    input  wire                  random_access_flag,

    // Raw MM PDU (MSB=[79], actual length in mm_pdu_len_bits)
    input  wire [79:0]           mm_pdu_bits,
    input  wire [6:0]            mm_pdu_len_bits,

    // Output — 268-bit MAC-RESOURCE PDU, [PDU_BITS-1] = first bit on air
    output reg  [PDU_BITS-1:0]   pdu_bits,
    output reg                   valid           // 1-cycle pulse
);

    // -------------------------------------------------------------------------
    // Local parameters — field widths
    //
    // MAC_HDR_BITS reflects the *packed* MAC-RESOURCE header as we emit it
    // today: 2+1+1+2+1+6+3+24 = 40 bits.  The 3 presence flags (PowerCtrl/
    // SlotGrant/ChanAlloc) are OMITTED because ETSI §21.4.3.1 Table 21.55
    // only requires them when PosOfGrant=1; this builder hard-codes
    // PosOfGrant=0.  The 24-bit address slot assumes AddrType ∈ {1 (SSI),
    // 3 (USSI)}; other addr_types have different slot widths per Table
    // 21.55 and are gated below (see lat_addr_type assertion in
    // S_ASSEMBLE_INNER).
    //
    // TODO (Group-Call phase): make MAC_HDR_BITS + the S_MAC_HEAD concat +
    // the LengthInd math addr_type-dependent so the following widths are
    // supported cleanly:
    //   addr_type 1 (SSI)         → 24 bit  (current default)
    //   addr_type 3 (USSI)        → 24 bit  (identical packing)
    //   addr_type 2 (Event Label) → 10 bit
    //   addr_type 4 (SMI)         → 48 bit
    //   addr_type 5 (SSI+Event)   → 34 bit
    //   addr_type 6 (SSI+Usage)   → 30 bit
    //   addr_type 7 (SMI+Event)   → 58 bit
    // Same TODO: emit the 3 presence flags when PosOfGrant becomes 1 for
    // a caller that actually attaches a grant (CMCE call-setup, etc.).
    // -------------------------------------------------------------------------
    localparam integer MAC_HDR_BITS  = 2 + 1 + 1 + 2 + 1 + 6 + 3 + 24; // =40
    localparam integer LLC_HDR_BITS  = 4 + 1 + 1;                                 // = 6
    localparam integer FCS_BITS      = 32;
    localparam integer MLE_PD_BITS   = 3;

    // LLC PDU type: BL-ADATA-FCS (§22.2.2, Table 21.1) — confirmed against
    // osmo-tetra tetra_llc_pdu.h (TLLC_PDUT_BL_ADATA_FCS=4) and our own
    // scripts/decode_dl.py LLC_PDU_NAMES[4].
    localparam [3:0] LLC_PDUT_BL_ADATA_FCS = 4'b0100;

    // MLE protocol discriminator — MM (§18.5.2 Table 18.4) = 3'b001.
    // Confirmed against scripts/decode_dl.py MLE_PDU_NAMES[1]='MM' and the
    // tetra-kit decoder.
    localparam [2:0] MLE_PD_MM = 3'b001;

    // -------------------------------------------------------------------------
    // Latched inputs
    // -------------------------------------------------------------------------
    reg [23:0]       lat_ssi;
    reg [2:0]        lat_addr_type;
    reg              lat_ns, lat_nr;
    reg              lat_random_access_flag;
    reg [79:0]       lat_mm_bits;
    reg [6:0]        lat_mm_len;

    // Derived lengths
    reg [8:0]        tl_sdu_len;           // MLE PD (3) + MM PDU len
    reg [8:0]        llc_cov_len;          // LLC header (6) + TL-SDU — input to CRC
    reg [8:0]        mac_tm_sdu_len;       // LLC PDU = cov + FCS (32)
    reg [8:0]        mac_total_bits;       // MAC header (42) + TM-SDU
    reg [8:0]        mac_total_octets;     // ceil(mac_total_bits / 8)
    reg [5:0]        length_ind;
    reg              fill_bit_ind;

    // -------------------------------------------------------------------------
    // Inner assembly buffer — space for the full LLC PDU (header + TL-SDU)
    // BEFORE the FCS is appended.  Max size we need to cover:
    //   LLC (6) + MLE PD (3) + MM PDU (79) = 88 bits.
    // Round up to 96 for headroom; MSB = first bit of LLC PDU (i.e.
    // llc_buf[95] = first bit of LLC header on air).
    // -------------------------------------------------------------------------
    localparam integer LLC_BUF_BITS = 96;
    reg [LLC_BUF_BITS-1:0] llc_buf;

    // -------------------------------------------------------------------------
    // FCS computation — MSB-first serial CRC-32, poly 0x04C11DB7 (ETSI
    // §22.2.2.5).  Matches osmo-tetra `tetra_llc_compute_fcs` semantics:
    //   1. FCS covers the TL-SDU ONLY (MLE-PD + MM PDU bits), NOT the LLC
    //      header (pdu_type + NR + NS).  osmo parses the LLC header first
    //      then calls check_fcs(cur, tl_sdu_len) — confirmed in
    //      osmo-debug-rx/vendor/osmo-tetra/src/tetra_llc_pdu.c:160.
    //   2. For payloads shorter than 32 bits, the CRC init value is
    //      pre-shifted left by (32 - len) — this aligns the all-ones seed
    //      so that the short input produces the ETSI-specified residual.
    //      Without this pre-shift, on-air FCS is internally consistent
    //      (magic residual 0xC704DD7B works) but the MS's LLC layer
    //      rejects it.  Bug #9 root cause of MTP3550 never registering.
    // The CRC loop reads starting at llc_buf[89] (skipping 6-bit LLC hdr)
    // and runs exactly tl_sdu_len bits.
    // -------------------------------------------------------------------------
    reg  [31:0] crc;
    reg  [8:0]  fcs_cnt;
    // Bit pulled from TL-SDU region of llc_buf: llc_buf[95] is first LLC hdr
    // bit on air, LLC hdr is 6 bits so TL-SDU starts at llc_buf[89].
    wire        fcs_din_w    = llc_buf[LLC_BUF_BITS - 1 - LLC_HDR_BITS - fcs_cnt];
    wire        fcs_fb_w     = fcs_din_w ^ crc[31];
    wire [31:0] fcs_next_w   = {crc[30:0], 1'b0} ^ ({32{fcs_fb_w}} & 32'h04C11DB7);
    // Pre-shift amount for the init seed — only applies when tl_sdu_len < 32.
    // For tl_sdu_len=19 (minimal D-LOC-UPDATE-ACCEPT) → preshift=13 →
    // init = 0xFFFFFFFF << 13 = 0xFFFFE000.  For tl_sdu_len>=32, no shift.
    // (6'd32 avoids the 5-bit truncation warning; shift amount fits in 5 bits.)
    wire [5:0]  fcs_preshift_w =
        (tl_sdu_len < 9'd32) ? (6'd32 - {1'b0, tl_sdu_len[4:0]}) : 6'd0;
    wire [31:0] crc_init_w    = 32'hFFFFFFFF << fcs_preshift_w;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE           = 4'd0;
    localparam [3:0] S_ASSEMBLE_INNER = 4'd1;
    localparam [3:0] S_LLC_HEAD       = 4'd2;
    localparam [3:0] S_FCS            = 4'd3;
    localparam [3:0] S_MAC_HEAD       = 4'd4;
    localparam [3:0] S_PAD            = 4'd5;
    localparam [3:0] S_DONE           = 4'd6;

    reg [3:0] state;

    // Working copies of the assembled PDU fragments built up across states.
    // complete_pdu_bits accumulates the full 268-bit output in [PDU_BITS-1 : 0]
    // with the MAC header placed at the MSB end in S_MAC_HEAD.
    reg [PDU_BITS-1:0] complete_pdu_bits;
    reg [31:0]         fcs_final;

    // Combinational length helpers used by S_ASSEMBLE_INNER
    reg [8:0]  tl_sdu_len_c;
    reg [8:0]  llc_cov_len_c;
    reg [8:0]  mac_tm_sdu_len_c;
    reg [8:0]  mac_total_bits_c;
    reg [8:0]  mac_total_octets_c;
    always @(*) begin
        tl_sdu_len_c       = MLE_PD_BITS + {2'b0, lat_mm_len};       // 3..82
        llc_cov_len_c      = LLC_HDR_BITS + tl_sdu_len_c;            // 9..88
        mac_tm_sdu_len_c   = llc_cov_len_c + FCS_BITS;               // 41..120
        mac_total_bits_c   = MAC_HDR_BITS + mac_tm_sdu_len_c;        // 83..162
        // ceil-to-octet — LengthInd is in octets (Table 21.56, Y2=Z2=1)
        mac_total_octets_c = (mac_total_bits_c + 9'd7) >> 3;
    end

    // -------------------------------------------------------------------------
    // Master FSM + datapath — one always block, all registers under this clock
    // (acceptable departure from strict R1 because the state is tightly
    // coupled to the datapath; each branch writes a non-overlapping set).
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            lat_ssi            <= 24'd0;
            lat_addr_type      <= 3'd0;
            lat_ns             <= 1'b0;
            lat_nr             <= 1'b0;
            lat_random_access_flag <= 1'b0;
            lat_mm_bits        <= 80'd0;
            lat_mm_len         <= 7'd0;
            tl_sdu_len         <= 9'd0;
            llc_cov_len        <= 9'd0;
            mac_tm_sdu_len     <= 9'd0;
            mac_total_bits     <= 9'd0;
            mac_total_octets   <= 9'd0;
            length_ind         <= 6'd0;
            fill_bit_ind       <= 1'b0;
            llc_buf            <= {LLC_BUF_BITS{1'b0}};
            crc                <= 32'hFFFFFFFF;
            fcs_cnt            <= 9'd0;
            fcs_final          <= 32'd0;
            complete_pdu_bits  <= {PDU_BITS{1'b0}};
            pdu_bits           <= {PDU_BITS{1'b0}};
            valid              <= 1'b0;
        end else begin
            // Default: valid is a 1-cycle pulse, cleared every cycle except
            // the single S_DONE edge below.
            valid <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (start) begin
                    lat_ssi               <= ssi;
                    lat_addr_type         <= addr_type;
                    lat_ns                <= ns;
                    lat_nr                <= nr;
                    lat_random_access_flag<= random_access_flag;
                    lat_mm_bits           <= mm_pdu_bits;
                    lat_mm_len            <= mm_pdu_len_bits;
                    state                 <= S_ASSEMBLE_INNER;
                end
            end

            // -----------------------------------------------------------------
            // Build the LLC PDU (header + TL-SDU) into llc_buf, MSB-first.
            // TL-SDU = MLE ProtDisc(3) | MM PDU (lat_mm_len bits).
            // Layout in llc_buf (MSB-first, [LLC_BUF_BITS-1] = first on air):
            //   [95 : 90]   LLC header        6 bit  = {pdut, n_r, n_s}
            //                  (order matches osmo: after pdu_type comes
            //                   N(R) then N(S); see
            //                   osmo-tetra/src/tetra_llc_pdu.c:150–151.)
            //   [89 : 87]   MLE ProtDisc      3 bit  = 001 (MM)
            //   [86 : ...]  MM PDU            lat_mm_len bits
            // -----------------------------------------------------------------
            S_ASSEMBLE_INNER: begin
                // Freeze derived lengths for the rest of the pipeline.
                tl_sdu_len       <= tl_sdu_len_c;
                llc_cov_len      <= llc_cov_len_c;
                mac_tm_sdu_len   <= mac_tm_sdu_len_c;
                mac_total_bits   <= mac_total_bits_c;
                mac_total_octets <= mac_total_octets_c;
                // LengthInd encoding: Y2=Z2=1 → val == octets (§21.4.3.1 Table
                // 21.55 / decodeLength() in tetra-kit mac.cc:563).
                length_ind       <= mac_total_octets_c[5:0];
                // Fill bits required iff the MAC total is not already 268.
                fill_bit_ind     <= (mac_total_bits_c != PDU_BITS[8:0]);
                state            <= S_LLC_HEAD;
                // -------------------------------------------------------------
                // MVP guard: the packed 24-bit address slot below is only
                // valid for AddrType ∈ {1 (SSI), 3 (USSI)}.  MLE
                // registration FSM forces 3'd1 today; other MAC-RESOURCE
                // callers (CMCE, SDS, group call) will need variable-width
                // address packing before they go on air.  Flag mis-use in
                // simulation so we notice before HW-deploy.
                // synthesis translate_off
                if (lat_addr_type != 3'b001 && lat_addr_type != 3'b011) begin
                    $display("[%0t tetra_mac_resource_dl_builder] FATAL: addr_type=%0d not supported (MVP accepts only 1=SSI / 3=USSI). Variable-width packing is TODO.",
                             $time, lat_addr_type);
                    $fatal;
                end
                // synthesis translate_on
            end

            // -----------------------------------------------------------------
            S_LLC_HEAD: begin
                // Pack LLC header + MLE ProtDisc + MM PDU into llc_buf,
                // MSB-first.  The MM PDU is left-justified (lat_mm_bits[79]
                // = first MM bit on air) — only the top lat_mm_len bits are
                // meaningful.  Anything past llc_cov_len is don't-care: the
                // CRC loop shifts exactly llc_cov_len bits, and the output
                // packer (S_MAC_HEAD) also shifts based on llc_cov_len.
                //
                // Concat widths: 4+1+1+3+80+7 = 96 = LLC_BUF_BITS.
                llc_buf <= {LLC_PDUT_BL_ADATA_FCS,    // 4
                            lat_nr, lat_ns,           // 1+1
                            MLE_PD_MM,                // 3
                            lat_mm_bits,              // 80
                            7'b0000000};              // pad to 96
                // Seed CRC with pre-shifted init — aligns ETSI behaviour
                // for short TL-SDUs (< 32 bit).  osmo-tetra reference.
                crc      <= crc_init_w;
                fcs_cnt  <= 9'd0;
                state    <= S_FCS;
            end

            // -----------------------------------------------------------------
            // Bit-serial CRC-32 over tl_sdu_len bits starting at llc_buf[89]
            // (TL-SDU only, excluding LLC header — Bug #9 / §22.2.2.5).
            // crc seeded (0xFFFFFFFF<<(32-tl_sdu_len)) for len<32, MSB-first,
            // poly 0x04C11DB7, final residue complemented.
            // -----------------------------------------------------------------
            S_FCS: begin
                crc <= fcs_next_w;
                if (fcs_cnt + 9'd1 == tl_sdu_len) begin
                    fcs_final <= ~fcs_next_w;
                    state     <= S_MAC_HEAD;
                end else begin
                    fcs_cnt <= fcs_cnt + 9'd1;
                end
            end

            // -----------------------------------------------------------------
            // Assemble the MAC-RESOURCE header + TM-SDU and pack into
            // complete_pdu_bits.  Field order (§21.4.3.1 Table 21.55):
            //   [2]  PDUtype         = 00
            //   [1]  FillBit         = fill_bit_ind
            //   [1]  PosOfGrant      = 0
            //   [2]  EncryptionMode  = 00
            //   [1]  RandAccFlag     = lat_random_access_flag (caller-driven)
            //   [6]  LengthInd
            //   [3]  AddrType        (usually 001 = SSI)
            //   [24] SSI
            //   (PowerCtrl/SlotGrant/ChanAlloc presence flags omitted:
            //    §21.4.3.1 requires them only when PosOfGrant=1.)
            //   → TM-SDU: LLC PDU (header + TL-SDU) + FCS (32) → padding
            //
            // The complete 268-bit output goes MSB-first: bit [PDU_BITS-1]
            // is the first bit transmitted on air.
            // -----------------------------------------------------------------
            S_MAC_HEAD: begin
                // Build the full 268-bit MAC-RESOURCE PDU left-aligned.
                //
                // Step 1 — MAC header (40 bit) — parked at the MSB end.
                // Step 2 — LLC info field (llc_cov_len bit) starts
                //          immediately after and is embedded by shifting
                //          llc_buf right by (LLC_BUF_BITS - llc_cov_len) to
                //          strip trailing don't-care padding, then left-
                //          shifting by (PDU_BITS - MAC_HDR_BITS -
                //          llc_cov_len) so its MSB lands adjacent to the
                //          MAC header.
                // Step 3 — FCS (32 bit) follows the LLC info, placed by
                //          shifting fcs_final left by (PDU_BITS -
                //          MAC_HDR_BITS - llc_cov_len - 32).
                // Step 4 — Remaining bits are zero now; S_PAD flips the
                //          first fill bit to 1 if fill_bit_ind is set.
                //
                // Widening fcs_final to PDU_BITS before the shift avoids
                // the synthesizer complaining about shift overflow.
                complete_pdu_bits <=
                    { 2'b00,                             // [267:266] PDUtype
                      fill_bit_ind,                      // [265]     FillBit
                      1'b0,                              // [264]     PosOfGrant
                      2'b00,                             // [263:262] Encryption
                      lat_random_access_flag,            // [261]     RandAccFlag
                      length_ind,                        // [260:255] LengthInd
                      lat_addr_type,                     // [254:252] AddrType
                      lat_ssi,                           // [251:228] SSI
                      {(PDU_BITS - MAC_HDR_BITS){1'b0}} } // [227:  0] TM-SDU placeholder
                    |
                    // LLC info field — shift llc_buf's top llc_cov_len bits
                    // into the TM-SDU region at the correct offset.
                    ( { {(PDU_BITS - LLC_BUF_BITS){1'b0}}, llc_buf }
                      >> (LLC_BUF_BITS - llc_cov_len)           // drop don't-care pad
                    ) << (PDU_BITS - MAC_HDR_BITS - llc_cov_len) // place after MAC hdr
                    |
                    // FCS field — right after the LLC info.
                    ( { {(PDU_BITS - 32){1'b0}}, fcs_final }
                      << (PDU_BITS - MAC_HDR_BITS - llc_cov_len - FCS_BITS) );
                state <= S_PAD;
            end

            // -----------------------------------------------------------------
            // Fill bits — §21.4.3.4.  When the MAC PDU is shorter than 268
            // bits we set the first fill bit to 1 and leave the rest 0.
            // `complete_pdu_bits` already has zeros in the pad region; we
            // flip the MSB of that region to 1 when fill_bit_ind is set.
            // -----------------------------------------------------------------
            S_PAD: begin
                if (fill_bit_ind) begin
                    // Position of first fill bit = mac_total_bits (0-indexed
                    // from the MSB of the 268-bit PDU).  Bit index in
                    // little-endian form = PDU_BITS-1 - mac_total_bits.
                    complete_pdu_bits[PDU_BITS - 1 - mac_total_bits] <= 1'b1;
                end
                state <= S_DONE;
            end

            // -----------------------------------------------------------------
            S_DONE: begin
                pdu_bits <= complete_pdu_bits;
                valid    <= 1'b1;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
