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
//     PowerCtrl_flag(1)   [+ PowerCtrl_element(4)   when flag=1]
//     SlotGrant_flag(1)   [+ SlotGrant_element(8)   when flag=1]
//     ChanAlloc_flag(1)   [+ ChanAlloc_element(n)   when flag=1]
//     BlueStation mac_resource.rs::to_bitbuf (Z.263-282, Z.289-319) writes
//     the three 1-bit presence flags unconditionally after the address
//     block — they are NOT gated on PosOfGrant.  Omitting them (our old
//     §21.4.3.1 mis-read) shifted every TM-SDU bit up by 3 and caused the
//     MS to reject the LLC BL-DATA TM-SDU with a type-mismatch.
//     TM-SDU:
//       LLC BL-DATA (§21.2.2.3)
//         LLCLinkType(1)=0  has_fcs(1)=0  bl_pdu_type(2)=01  N(S)(1)
//         TL-SDU:
//           MLE ProtDisc(3)=001 (MM)
//           MM D-LOC-UPDATE-ACCEPT (~72 bit, caller-supplied)
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
//   1 (IDLE) + 1 (ASSEMBLE_INNER) + 1 (LLC_HEAD) +
//   1 (MAC_HEAD) + 1 (PAD) + 1 (DONE).
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
    parameter integer PDU_BITS = 268, // SCH/F MAC-SDU size
    // LLC assembly buffer: BL-ADATA hdr(6) + MLE-PD(3) + MM body.  Default
    // 144 bit fits the bluestation-compliant 100-bit D-LOC-UPDATE-ACCEPT
    // MM body.  Short-builder callers (SCH/HD AL-SETUP, no MM body) override
    // to a smaller value because PDU_BITS=124 cannot hold a 144-bit buffer.
    parameter integer LLC_BUF_BITS = 144
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
    // LLC PDU type for the primary MAC-RESOURCE payload.
    // Supported today:
    //   4'd0  = BL-ADATA   (LLC hdr 6b + MLE PD 3b + MM)
    //   4'd1  = BL-DATA    (LLC hdr 5b + MLE PD 3b + MM)
    //   4'd8  = AL-SETUP   (LLC hdr 4b only, no MLE/MM payload)
    //   4'd14 = L2SigPdu   (LLC hdr 4b + direct MM, no MLE PD)
    input  wire [3:0]            llc_pdu_type,

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

    // -------------------------------------------------------------------
    // Optional header elements (bluestation MacResource struct, §21.4.3.1):
    //   power_control_flag  (1 bit, always emitted after SSI)
    //     + 4-bit power_control_element when flag=1 (§21.5.7)
    //   slot_granting_flag  (1 bit, always emitted)
    //     + 8-bit basic slot-granting element when flag=1 (§21.5.6)
    //       Packed as {cap_alloc[3:0], granting_delay[3:0]}, MSB-first.
    //   chan_alloc_flag     (1 bit, always emitted)
    //     + chan_alloc_element_len bits when flag=1 (§21.5.2).
    //       Variable length 21..25 bits in the supported subset.  Packed
    //       MSB-first in chan_alloc_element[31:0] (left-aligned after shift,
    //       top chan_alloc_element_len bits used).
    //
    // For D-LOC-UPDATE-ACCEPT (registration) all three flags are tied 0 —
    // no resource grant piggybacks the accept.  Plumbed for future CMCE
    // call-setup / paging / group-call scheduling.
    // -------------------------------------------------------------------
    input  wire                  power_control_flag,
    input  wire [3:0]            power_control_element,
    input  wire                  slot_granting_flag,
    input  wire [7:0]            slot_granting_element,
    input  wire                  chan_alloc_flag,
    input  wire [31:0]           chan_alloc_element,
    input  wire [4:0]            chan_alloc_element_len,

    // -------------------------------------------------------------------
    // Concatenated second MAC-RESOURCE (ETSI §21.4.3.7) — Option B of
    // the 2026-04-24 BL-ACK-alongside-Accept flow.  When
    // second_pdu_valid=1 the builder appends a second MAC-RESOURCE PDU
    // after PDU #1 (byte-aligned) in the same 268-bit MAC-SDU.  All
    // second_pdu_* inputs mirror PDU #1's structural fields, with the
    // TM-SDU delivered as a raw bit vector (left-aligned in
    // second_pdu_tl_sdu[79:0], length in second_pdu_tl_sdu_len).  When
    // second_pdu_valid=0 the builder behaves identically to the
    // single-PDU case — backward compatible with the pre-commit-2 TBs.
    //
    // For D-LOC-UPDATE-ACCEPT + BL-ACK concat, caller drives:
    //   second_pdu_valid               = 1
    //   second_pdu_length_ind          = 6
    //   second_pdu_random_access_flag  = 1
    //   second_pdu_addr_type           = 3'b001
    //   second_pdu_ssi                 = MS SSI
    //   second_pdu_tl_sdu[79:75]       = {0, 0, 2'b11, nr}   (BlAck::to_bitbuf)
    //   second_pdu_tl_sdu_len          = 5
    //   second_pdu_{pc,sg,ca}_flag     = 0
    // -------------------------------------------------------------------
    input  wire                  second_pdu_valid,
    input  wire [5:0]            second_pdu_length_ind,
    input  wire                  second_pdu_random_access_flag,
    input  wire [2:0]            second_pdu_addr_type,
    input  wire [23:0]           second_pdu_ssi,
    input  wire [79:0]           second_pdu_tl_sdu,
    input  wire [6:0]            second_pdu_tl_sdu_len,
    input  wire                  second_pdu_pc_flag,
    input  wire [3:0]            second_pdu_pc_element,
    input  wire                  second_pdu_sg_flag,
    input  wire [7:0]            second_pdu_sg_element,
    input  wire                  second_pdu_ca_flag,
    input  wire [31:0]           second_pdu_ca_element,
    input  wire [4:0]            second_pdu_ca_element_len,

    // Raw MM PDU (MSB=[127], actual length in mm_pdu_len_bits)
    // Widened 2026-04-25 from 80→128 bit so the bluestation-compliant
    // D-LOC-UPDATE-ACCEPT body (100 bit, all 3 type-2 optionals present)
    // fits without losing the upper bits.  Callers that drive only 80 bits
    // should zero-extend their MSB side.
    input  wire [127:0]          mm_pdu_bits,
    input  wire [7:0]            mm_pdu_len_bits,

    // Output — 268-bit MAC-RESOURCE PDU, [PDU_BITS-1] = first bit on air
    output reg  [PDU_BITS-1:0]   pdu_bits,
    output reg                   valid           // 1-cycle pulse
);

    // -------------------------------------------------------------------------
    // Local parameters — field widths
    //
    // MAC_HDR_BASE_BITS = 2+1+1+2+1+6+3+24 = 40 — the fixed part up through the
    // 24-bit SSI.  The three mandatory presence flags (PowerCtrl/SlotGrant/
    // ChanAlloc) add 3 more bits unconditionally → minimum mac_hdr_bits = 43.
    // When a flag is 1 the corresponding element (4/8/ca_len bits) is also
    // emitted, making the header up to 80 bits wide for the supported subset
    // (ca_element max 27 bits per tetra_chan_alloc_encoder).
    //
    // The 24-bit address slot assumes AddrType ∈ {1 (SSI), 3 (USSI)}; other
    // addr_types have different widths per Table 21.55 and are rejected in
    // S_ASSEMBLE_INNER's simulation guard.
    //
    // TODO (Group-Call phase): make the address slot addr_type-dependent:
    //   addr_type 1 (SSI)         → 24 bit  (current default)
    //   addr_type 3 (USSI)        → 24 bit  (identical packing)
    //   addr_type 2 (Event Label) → 10 bit
    //   addr_type 4 (SMI)         → 48 bit
    //   addr_type 5 (SSI+Event)   → 34 bit
    //   addr_type 6 (SSI+Usage)   → 30 bit
    //   addr_type 7 (SMI+Event)   → 58 bit
    // -------------------------------------------------------------------------
    localparam integer MAC_HDR_BASE_BITS = 2 + 1 + 1 + 2 + 1 + 6 + 3 + 24;  // =40
    localparam integer LLC_HDR_BITS_MAX  = 6;
    localparam integer MLE_PD_BITS   = 3;

    // LLC BL-DATA header constants per BlueStation `BlData::to_bitbuf()`.
    localparam       LLC_LINK_TYPE_BL  = 1'b0;
    localparam       LLC_HAS_FCS_OFF   = 1'b0;
    localparam [1:0] LLC_PDUT_BL_ADATA = 2'b00;
    localparam [1:0] LLC_PDUT_BL_DATA  = 2'b01;
    localparam [3:0] LLC_PDUT_AL_SETUP = 4'd8;
    localparam [3:0] LLC_PDUT_L2SIG    = 4'd14;

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
    reg [3:0]        lat_llc_pdu_type;
    reg              lat_random_access_flag;
    reg [127:0]      lat_mm_bits;
    reg [7:0]        lat_mm_len;
    // Optional-element inputs latched at S_IDLE (commit 1 plumbing; consumed
    // by the header packer starting commit 4).
    reg              lat_pc_flag;
    reg [3:0]        lat_pc_element;
    reg              lat_sg_flag;
    reg [7:0]        lat_sg_element;
    reg              lat_ca_flag;
    reg [31:0]       lat_ca_element;
    reg [4:0]        lat_ca_element_len;

    // Second concatenated PDU (commit 2, 2026-04-24).  All 0 when
    // lat_second_valid=0 → builder falls back to single-PDU emission.
    reg              lat_second_valid;
    reg [5:0]        lat_second_length_ind;
    reg              lat_second_rand_acc_flag;
    reg [2:0]        lat_second_addr_type;
    reg [23:0]       lat_second_ssi;
    reg [79:0]       lat_second_tl_sdu;
    reg [6:0]        lat_second_tl_sdu_len;
    reg              lat_second_pc_flag;
    reg [3:0]        lat_second_pc_element;
    reg              lat_second_sg_flag;
    reg [7:0]        lat_second_sg_element;
    reg              lat_second_ca_flag;
    reg [31:0]       lat_second_ca_element;
    reg [4:0]        lat_second_ca_element_len;

    // Derived lengths
    reg [8:0]        tl_sdu_len;           // MLE PD (3) + MM PDU len
    reg [3:0]        llc_hdr_bits;
    reg [8:0]        llc_cov_len;          // LLC header + TL-SDU
    reg [8:0]        mac_tm_sdu_len;       // LLC PDU = cov (BlueStation-style, no FCS)
    reg [8:0]        mac_hdr_bits;         // base 40 + 3 mandatory flags + optional elements
    reg [8:0]        mac_total_bits;       // mac_hdr_bits + TM-SDU
    reg [8:0]        mac_total_octets;     // ceil(mac_total_bits / 8)
    reg [5:0]        length_ind;
    reg              fill_bit_ind;
    // Commit 2: PDU #2 latches (subset of mac_* needed in S_MAC_HEAD / S_PAD).
    reg [8:0]        pdu2_hdr_bits;        // base 40 + 3 mandatory flags + optional
    reg [8:0]        pdu2_total_bits;      // hdr + tl_sdu_len
    reg [8:0]        pdu2_total_octets;
    reg              pdu2_fill_bit_ind;

    // -------------------------------------------------------------------------
    // Inner assembly buffer — space for the full LLC PDU (header + TL-SDU)
    // BEFORE the FCS is appended.  Max size we need to cover:
    //   BL-ADATA LLC (6) + MLE PD (3) + MM PDU (80) = 89 bits.
    // Round up to 96 for headroom; MSB = first bit of LLC PDU (i.e.
    // llc_buf[95] = first bit of LLC header on air).
    // -------------------------------------------------------------------------
    // LLC assembly buffer: see module-level LLC_BUF_BITS parameter.
    reg [LLC_BUF_BITS-1:0] llc_buf;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE           = 4'd0;
    localparam [3:0] S_ASSEMBLE_INNER = 4'd1;
    localparam [3:0] S_LLC_HEAD       = 4'd2;
    localparam [3:0] S_MAC_HEAD       = 4'd3;
    localparam [3:0] S_PAD            = 4'd4;
    localparam [3:0] S_DONE           = 4'd5;

    reg [3:0] state;

    // Working copies of the assembled PDU fragments built up across states.
    // complete_pdu_bits accumulates the full 268-bit output in [PDU_BITS-1 : 0]
    // with the MAC header placed at the MSB end in S_MAC_HEAD.
    reg [PDU_BITS-1:0] complete_pdu_bits;
    // Combinational length helpers used by S_ASSEMBLE_INNER
    reg [8:0]  tl_sdu_len_c;
    reg [3:0]  llc_hdr_bits_c;
    reg [8:0]  llc_cov_len_c;
    reg [8:0]  mac_tm_sdu_len_c;
    reg [8:0]  mac_hdr_bits_c;
    reg [8:0]  mac_total_bits_c;
    reg [8:0]  mac_total_octets_c;
    // PDU #2 length helpers (commit 2) — meaningful only when
    // lat_second_valid=1; otherwise treated as 0 everywhere.
    reg [8:0]  pdu2_hdr_bits_c;
    reg [8:0]  pdu2_total_bits_c;
    reg [8:0]  pdu2_total_octets_c;
    reg        pdu2_fill_bit_ind_c;
    always @(*) begin
        if (lat_llc_pdu_type == LLC_PDUT_L2SIG) begin
            tl_sdu_len_c   = {1'b0, lat_mm_len};
            llc_hdr_bits_c = 4;
        end else if (lat_llc_pdu_type == LLC_PDUT_AL_SETUP) begin
            tl_sdu_len_c   = 9'd0;
            llc_hdr_bits_c = 4;
        end else if (lat_llc_pdu_type == {2'b00, LLC_PDUT_BL_ADATA}) begin
            tl_sdu_len_c   = MLE_PD_BITS + {1'b0, lat_mm_len};
            llc_hdr_bits_c = 6;
        end else begin
            tl_sdu_len_c   = MLE_PD_BITS + {1'b0, lat_mm_len};
            llc_hdr_bits_c = 5;
        end
        llc_cov_len_c      = {5'd0, llc_hdr_bits_c} + tl_sdu_len_c;
        mac_tm_sdu_len_c   = llc_cov_len_c;
        // mac_hdr_bits = 40 (base) + 3 (mandatory flag bits)
        //              + 4  if pc_flag
        //              + 8  if sg_flag
        //              + ca_element_len if ca_flag
        // Matches bluestation mac_resource.rs::compute_header_len (Z.289-319).
        mac_hdr_bits_c     = 9'd40 + 9'd3
                             + (lat_pc_flag ? 9'd4 : 9'd0)
                             + (lat_sg_flag ? 9'd8 : 9'd0)
                             + (lat_ca_flag ? {4'd0, lat_ca_element_len} : 9'd0);
        mac_total_bits_c   = mac_hdr_bits_c + mac_tm_sdu_len_c;
        // ceil-to-octet — LengthInd is in octets (Table 21.56, Y2=Z2=1)
        mac_total_octets_c = (mac_total_bits_c + 9'd7) >> 3;

        // PDU #2 sizes.  Same structural rules as PDU #1 but TM-SDU is a
        // raw bit vector (no fixed LLC/MLE prefix added by the builder).
        pdu2_hdr_bits_c    = 9'd40 + 9'd3
                             + (lat_second_pc_flag ? 9'd4 : 9'd0)
                             + (lat_second_sg_flag ? 9'd8 : 9'd0)
                             + (lat_second_ca_flag ? {4'd0, lat_second_ca_element_len} : 9'd0);
        pdu2_total_bits_c  = pdu2_hdr_bits_c + {2'd0, lat_second_tl_sdu_len};
        pdu2_total_octets_c= (pdu2_total_bits_c + 9'd7) >> 3;
        // Bluestation-local fill_bit_ind (mac_resource.rs:327-330):
        //   fill_bits = (8 - total%8) % 8; fill_bit_ind = (fill_bits != 0)
        pdu2_fill_bit_ind_c= |pdu2_total_bits_c[2:0];  // any of bits 2:0 nonzero → not byte-aligned
    end

    // -------------------------------------------------------------------------
    // Commit 2: PDU #2 (concatenated MAC-RESOURCE) top-aligned bit-pack.
    // Same structural layout as PDU #1 but using the lat_second_* latches and
    // raw lat_second_tl_sdu (no builder-inserted LLC/MLE-PD prefix — caller
    // pre-builds the BL-ACK TL-SDU).  Placed in the 268-bit container at
    // byte-offset mac_total_octets*8 via a combinational right-shift.
    // -------------------------------------------------------------------------
    wire [8:0]              offset_pdu2_msb  = {mac_total_octets, 3'b0};
    wire [PDU_BITS-1:0]     pdu2_top;

    // PDU #2 base-40 bits + flag/element cascade, identical in structure to
    // PDU #1 (see S_MAC_HEAD step comments) but replicated here as a wire so
    // the final S_MAC_HEAD expression stays a single OR of three pieces.
    assign pdu2_top =
        ( { 2'b00,
            pdu2_fill_bit_ind,
            1'b0,
            2'b00,
            lat_second_rand_acc_flag,
            lat_second_length_ind,
            lat_second_addr_type,
            lat_second_ssi,
            {(PDU_BITS - 40){1'b0}} }
        | ({{(PDU_BITS-1){1'b0}}, lat_second_pc_flag} << (PDU_BITS - 41))
        | (lat_second_pc_flag
            ? ({{(PDU_BITS-4){1'b0}}, lat_second_pc_element} << (PDU_BITS - 45))
            : {PDU_BITS{1'b0}})
        | ({{(PDU_BITS-1){1'b0}}, lat_second_sg_flag}
            << (PDU_BITS - 41 - 1 - (lat_second_pc_flag ? 4 : 0)))
        | (lat_second_sg_flag
            ? ({{(PDU_BITS-8){1'b0}}, lat_second_sg_element}
                << (PDU_BITS - 42 - 8 - (lat_second_pc_flag ? 4 : 0)))
            : {PDU_BITS{1'b0}})
        | ({{(PDU_BITS-1){1'b0}}, lat_second_ca_flag}
            << (PDU_BITS - 42 - 1
                - (lat_second_pc_flag ? 4 : 0)
                - (lat_second_sg_flag ? 8 : 0)))
        | (lat_second_ca_flag
            ? ({{(PDU_BITS-32){1'b0}}, lat_second_ca_element}
                << (PDU_BITS - 43
                    - (lat_second_pc_flag ? 4 : 0)
                    - (lat_second_sg_flag ? 8 : 0)
                    - lat_second_ca_element_len))
            : {PDU_BITS{1'b0}})
        // TL-SDU — raw left-aligned bits from lat_second_tl_sdu.
        // Strip the (80 - len) trailing don't-care bits via right-shift,
        // then left-shift into position right after the PDU #2 header.
        | ( ( {{(PDU_BITS - 80){1'b0}}, lat_second_tl_sdu}
              >> (7'd80 - lat_second_tl_sdu_len) )
            << (PDU_BITS - pdu2_hdr_bits - {2'd0, lat_second_tl_sdu_len}) )
        );

    wire [PDU_BITS-1:0] pdu2_placed =
        lat_second_valid ? (pdu2_top >> offset_pdu2_msb) : {PDU_BITS{1'b0}};

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
            lat_llc_pdu_type   <= 4'd1;
            lat_random_access_flag <= 1'b0;
            lat_mm_bits        <= 128'd0;
            lat_mm_len         <= 8'd0;
            lat_pc_flag        <= 1'b0;
            lat_pc_element     <= 4'd0;
            lat_sg_flag        <= 1'b0;
            lat_sg_element     <= 8'd0;
            lat_ca_flag        <= 1'b0;
            lat_ca_element     <= 32'd0;
            lat_ca_element_len <= 5'd0;
            lat_second_valid        <= 1'b0;
            lat_second_length_ind   <= 6'd0;
            lat_second_rand_acc_flag<= 1'b0;
            lat_second_addr_type    <= 3'd0;
            lat_second_ssi          <= 24'd0;
            lat_second_tl_sdu       <= 80'd0;
            lat_second_tl_sdu_len   <= 7'd0;
            lat_second_pc_flag      <= 1'b0;
            lat_second_pc_element   <= 4'd0;
            lat_second_sg_flag      <= 1'b0;
            lat_second_sg_element   <= 8'd0;
            lat_second_ca_flag      <= 1'b0;
            lat_second_ca_element   <= 32'd0;
            lat_second_ca_element_len <= 5'd0;
            tl_sdu_len         <= 9'd0;
            llc_hdr_bits       <= 4'd0;
            llc_cov_len        <= 9'd0;
            mac_tm_sdu_len     <= 9'd0;
            mac_hdr_bits       <= 9'd0;
            mac_total_bits     <= 9'd0;
            mac_total_octets   <= 9'd0;
            length_ind         <= 6'd0;
            fill_bit_ind       <= 1'b0;
            pdu2_hdr_bits      <= 9'd0;
            pdu2_total_bits    <= 9'd0;
            pdu2_total_octets  <= 9'd0;
            pdu2_fill_bit_ind  <= 1'b0;
            llc_buf            <= {LLC_BUF_BITS{1'b0}};
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
                    lat_llc_pdu_type      <= llc_pdu_type;
                    lat_random_access_flag<= random_access_flag;
                    lat_mm_bits           <= mm_pdu_bits;
                    lat_mm_len            <= mm_pdu_len_bits;
                    lat_pc_flag           <= power_control_flag;
                    lat_pc_element        <= power_control_element;
                    lat_sg_flag           <= slot_granting_flag;
                    lat_sg_element        <= slot_granting_element;
                    lat_ca_flag           <= chan_alloc_flag;
                    lat_ca_element        <= chan_alloc_element;
                    lat_ca_element_len    <= chan_alloc_element_len;
                    lat_second_valid        <= second_pdu_valid;
                    lat_second_length_ind   <= second_pdu_length_ind;
                    lat_second_rand_acc_flag<= second_pdu_random_access_flag;
                    lat_second_addr_type    <= second_pdu_addr_type;
                    lat_second_ssi          <= second_pdu_ssi;
                    lat_second_tl_sdu       <= second_pdu_tl_sdu;
                    lat_second_tl_sdu_len   <= second_pdu_tl_sdu_len;
                    lat_second_pc_flag      <= second_pdu_pc_flag;
                    lat_second_pc_element   <= second_pdu_pc_element;
                    lat_second_sg_flag      <= second_pdu_sg_flag;
                    lat_second_sg_element   <= second_pdu_sg_element;
                    lat_second_ca_flag      <= second_pdu_ca_flag;
                    lat_second_ca_element   <= second_pdu_ca_element;
                    lat_second_ca_element_len <= second_pdu_ca_element_len;
                    state                 <= S_ASSEMBLE_INNER;
                end
            end

            // -----------------------------------------------------------------
            // Build the LLC PDU (header + TL-SDU) into llc_buf, MSB-first.
            // TL-SDU = MLE ProtDisc(3) | MM PDU (lat_mm_len bits).
            // BlueStation-style LLC BL-DATA layout in llc_buf:
            //   [95 : 91]   LLC header        5 bit = {0, has_fcs=0, 01, N(S)}
            //   [90 : 88]   MLE ProtDisc      3 bit = 001 (MM)
            //   [87 : ...]  MM PDU            lat_mm_len bits
            // -----------------------------------------------------------------
            S_ASSEMBLE_INNER: begin
                // Freeze derived lengths for the rest of the pipeline.
                tl_sdu_len       <= tl_sdu_len_c;
                llc_hdr_bits     <= llc_hdr_bits_c;
                llc_cov_len      <= llc_cov_len_c;
                mac_tm_sdu_len   <= mac_tm_sdu_len_c;
                mac_hdr_bits     <= mac_hdr_bits_c;
                mac_total_bits   <= mac_total_bits_c;
                mac_total_octets <= mac_total_octets_c;
                // LengthInd encoding: Y2=Z2=1 → val == octets (§21.4.3.1 Table
                // 21.55 / decodeLength() in tetra-kit mac.cc:563).
                length_ind       <= mac_total_octets_c[5:0];
                // Bluestation-local byte-align semantic (mac_resource.rs
                // update_len_and_fill_ind Z.327-330): fill_bit_ind = 1 when
                // the MAC-RESOURCE's own bit count is not a multiple of 8.
                // Matches the prior "!= PDU_BITS" value for all currently
                // tested goldens (89-bit D-LOC-UPDATE-ACCEPT both give 1),
                // but makes concat PDU #2 emit fill_bit_ind=0 when that PDU
                // is already byte-aligned (e.g., 48-bit BL-ACK).
                fill_bit_ind     <= |mac_total_bits_c[2:0];
                // PDU #2 sizes (commit 2).  Consumed in S_MAC_HEAD/S_PAD
                // only when lat_second_valid=1.
                pdu2_hdr_bits     <= pdu2_hdr_bits_c;
                pdu2_total_bits   <= pdu2_total_bits_c;
                pdu2_total_octets <= pdu2_total_octets_c;
                pdu2_fill_bit_ind <= pdu2_fill_bit_ind_c;
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
                // LLC_BUF_BITS = 144.  Layout: header + MLE-PD + lat_mm_bits[127:0]
                // top-aligned, trailing zero pad to fill the buffer.  Top-aligned
                // because the downstream shifter does
                //   llc_buf >> (LLC_BUF_BITS - llc_cov_len)
                // to drop the trailing pad and place the LLC PDU at bit position
                // (mac_hdr_bits .. mac_hdr_bits + llc_cov_len - 1).
                if (lat_llc_pdu_type == LLC_PDUT_L2SIG) begin
                    // 4 + 128 = 132, pad 12 → 144
                    llc_buf <= {LLC_PDUT_L2SIG,       // 4
                                lat_mm_bits,          // 128
                                12'd0};               // pad
                end else if (lat_llc_pdu_type == LLC_PDUT_AL_SETUP) begin
                    // 4 header bits, rest zero
                    llc_buf <= {LLC_PDUT_AL_SETUP,    // 4
                                140'd0};
                end else if (lat_llc_pdu_type == {2'b00, LLC_PDUT_BL_ADATA}) begin
                    // 1+1+2+1+1 + 3 + 128 = 137, pad 7 → 144
                    llc_buf <= {LLC_LINK_TYPE_BL,     // 1
                                LLC_HAS_FCS_OFF,      // 1
                                LLC_PDUT_BL_ADATA,    // 2
                                lat_nr,               // 1
                                lat_ns,               // 1
                                MLE_PD_MM,            // 3
                                lat_mm_bits,          // 128
                                7'd0};                // pad
                end else begin
                    // BL-DATA: 1+1+2+1 + 3 + 128 = 136, pad 8 → 144
                    llc_buf <= {LLC_LINK_TYPE_BL,     // 1
                                LLC_HAS_FCS_OFF,      // 1
                                LLC_PDUT_BL_DATA,     // 2
                                lat_ns,               // 1
                                MLE_PD_MM,            // 3
                                lat_mm_bits,          // 128
                                8'd0};                // pad
                end
                state    <= S_MAC_HEAD;
            end

            // -----------------------------------------------------------------
            // Assemble the MAC-RESOURCE header + TM-SDU and pack into
            // complete_pdu_bits.  Field order (§21.4.3.1 Table 21.55,
            // bluestation mac_resource.rs::to_bitbuf):
            //
            //   BASE 40 bits (always):
            //     [2]  PDUtype         = 00
            //     [1]  FillBit         = fill_bit_ind
            //     [1]  PosOfGrant      = 0
            //     [2]  EncryptionMode  = 00
            //     [1]  RandAccFlag     = lat_random_access_flag (caller-driven)
            //     [6]  LengthInd       = length_ind (dynamic, in octets)
            //     [3]  AddrType        = 001 = SSI
            //     [24] SSI             = lat_ssi
            //
            //   MANDATORY presence flags after the address block
            //   (bluestation mac_resource.rs Z.263-282):
            //     [1]  power_control_flag
            //     [4]  power_control_element   — only when flag=1
            //     [1]  slot_granting_flag
            //     [8]  slot_granting_element   — only when flag=1
            //     [1]  chan_alloc_flag
            //     [ca_len] chan_alloc_element  — only when flag=1
            //
            //   TM-SDU:
            //     LLC BL-DATA header (5) + MLE PD (3) + MM PDU (mm_len)
            //
            //   Fill bits (starting at bit position mac_total_bits):
            //     First fill bit = 1 if fill_bit_ind, remainder 0.
            //
            // The complete 268-bit output goes MSB-first: bit [PDU_BITS-1]
            // is the first bit transmitted on air.
            // -----------------------------------------------------------------
            S_MAC_HEAD: begin
                // ---- Step 1: base 40-bit MAC header at MSB end --------------
                // Straight concat, identical layout to pre-43-bit refactor for
                // the first 40 bits so the existing [261] RandAccFlag bit
                // position / [265] FillBit / [260:255] LengthInd spot checks
                // in tb_mac_resource_dl_builder keep working.
                complete_pdu_bits <=
                    ( { 2'b00,
                        fill_bit_ind,
                        1'b0,
                        2'b00,
                        lat_random_access_flag,
                        length_ind,
                        lat_addr_type,
                        lat_ssi,
                        {(PDU_BITS - 40){1'b0}} }
                    // ---- Step 2: mandatory pc_flag at bit 40 ----------------
                    // target LSB-index = PDU_BITS - 1 - 40 = PDU_BITS - 41
                    | ({{(PDU_BITS-1){1'b0}}, lat_pc_flag}  << (PDU_BITS - 41))
                    // ---- Step 3: pc_element (4 bit) when flag=1 -------------
                    // target MSB-position = 41, width = 4
                    // → shifted left by (PDU_BITS - 41 - 4) = PDU_BITS - 45
                    | (lat_pc_flag
                        ? ({{(PDU_BITS-4){1'b0}}, lat_pc_element} << (PDU_BITS - 45))
                        : {PDU_BITS{1'b0}})
                    // ---- Step 4: sg_flag ------------------------------------
                    // target MSB-position = 41 + (pc_flag?4:0)
                    | ({{(PDU_BITS-1){1'b0}}, lat_sg_flag}
                        << (PDU_BITS - 41 - 1 - (lat_pc_flag ? 4 : 0)))
                    // ---- Step 5: sg_element (8 bit) when flag=1 -------------
                    // target MSB-position = 42 + (pc_flag?4:0)
                    | (lat_sg_flag
                        ? ({{(PDU_BITS-8){1'b0}}, lat_sg_element}
                            << (PDU_BITS - 42 - 8 - (lat_pc_flag ? 4 : 0)))
                        : {PDU_BITS{1'b0}})
                    // ---- Step 6: ca_flag ------------------------------------
                    // target MSB-position = 42 + (pc_flag?4:0) + (sg_flag?8:0)
                    | ({{(PDU_BITS-1){1'b0}}, lat_ca_flag}
                        << (PDU_BITS - 42 - 1
                            - (lat_pc_flag ? 4 : 0)
                            - (lat_sg_flag ? 8 : 0)))
                    // ---- Step 7: ca_element (ca_len bit) when flag=1 --------
                    // Right-aligned in lat_ca_element[31:0].  target MSB-pos =
                    // 43 + pc_len + sg_len.  Shift the valid bits into place.
                    | (lat_ca_flag
                        ? ({{(PDU_BITS-32){1'b0}}, lat_ca_element}
                            << (PDU_BITS - 43
                                - (lat_pc_flag ? 4 : 0)
                                - (lat_sg_flag ? 8 : 0)
                                - lat_ca_element_len))
                        : {PDU_BITS{1'b0}})
                    // ---- Step 8: LLC info field at position mac_hdr_bits ----
                    | ( ( { {(PDU_BITS - LLC_BUF_BITS){1'b0}}, llc_buf }
                          >> (LLC_BUF_BITS - llc_cov_len) )
                        << (PDU_BITS - mac_hdr_bits - llc_cov_len) )
                    // ---- Step 9: concatenated PDU #2 (commit 2) ------------
                    // pdu2_top is built top-aligned above and shifted down by
                    // offset_pdu2_msb = mac_total_octets * 8 so PDU #2 starts
                    // on the next byte boundary after PDU #1's octet-padded
                    // end.  Zero when lat_second_valid=0 → backward-compat.
                    | pdu2_placed
                    );
                state <= S_PAD;
            end

            // -----------------------------------------------------------------
            // Fill bits — §21.4.3.4.  When the MAC PDU is shorter than 268
            // bits we set the first fill bit to 1 and leave the rest 0.
            // `complete_pdu_bits` already has zeros in the pad region; we
            // flip the MSB of that region to 1 when fill_bit_ind is set.
            // -----------------------------------------------------------------
            S_PAD: begin
                // PDU #1 internal byte-align fill (first=1) — bluestation
                // local fill_bit_ind (see S_ASSEMBLE_INNER).
                if (fill_bit_ind) begin
                    complete_pdu_bits[PDU_BITS - 1 - mac_total_bits] <= 1'b1;
                end
                if (lat_second_valid) begin
                    // Concat: PDU #2 may also need internal byte-align fill
                    // (first=1) when not byte-aligned, plus global post-fill
                    // (first=1) at the end of the concat sequence.
                    if (pdu2_fill_bit_ind) begin
                        complete_pdu_bits[PDU_BITS - 1 - offset_pdu2_msb - pdu2_total_bits] <= 1'b1;
                    end
                    if ((offset_pdu2_msb + {pdu2_total_octets, 3'b0}) < PDU_BITS[8:0])
                        complete_pdu_bits[PDU_BITS - 1 - offset_pdu2_msb - {pdu2_total_octets, 3'b0}] <= 1'b1;
                end else begin
                    // Single-PDU first-unused-bit marker — only needed when
                    // the PDU is already byte-aligned (fill_bit_ind=0) and
                    // there is still space in the 268-bit container.
                    if (!fill_bit_ind && (mac_total_bits < PDU_BITS[8:0]))
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
