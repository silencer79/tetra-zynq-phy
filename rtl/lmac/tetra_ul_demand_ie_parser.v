// =============================================================================
// tetra_ul_demand_ie_parser.v — Phase Y.1.a (mm=2 + mm=7 dispatch)
// =============================================================================
//
// Parses the 129-bit reassembled MM body produced by
// tetra_ul_demand_reassembly.v and exposes the U-LOCATION-UPDATE-DEMAND
// fields (mm_pdu_type==2, ETSI EN 300 392-2 §16.10.21 + bluestation
// `mm/pdus/u_location_update_demand.rs`) as registered outputs.
//
// Phase Y.1.a (2026-05-03): mm=7 U-ATTACH-DETACH-GROUP-IDENTITY walker
// re-introduced for the Group-Attach FPGA path (Phase Y.1).  The mm=2
// path is bit-identical to the prior version (additive change).
//
// Dispatch:
//   - mm_pdu_type_sys[3:0] is latched at start_sys.
//   - mm_pdu_type == 4'd2 → S_HEADER_T1 (mm=2 LOCATION-UPDATE-DEMAND).
//   - mm_pdu_type == 4'd7 → S_GAD_HDR (mm=7 ATTACH-DETACH-GROUP-IDENTITY).
//   - other → parse_done_sys + parse_ok_sys=0.
//
// Entry: pulse `start_sys` with `body_sys` / `ssi_sys` valid.  The parser
// walks the variable-length bitstream over a few clock cycles and asserts
// `parse_done_sys` for one cycle when finished.  `parse_ok_sys` is high
// during the same cycle when the stream parsed cleanly.
//
// Body layout (MSB-first; bit[128] = first on-air bit, == ul0_bits[48]).
// NOTE: the 4-bit mm_pdu_type that appears on-air at info_bits[44..47] is
// stripped by the upstream LLC parser BEFORE the 129-bit body is built —
// so bit[128] is the FIRST bit of the MM body proper (= bit immediately
// after pdu_type on-air).  All offsets below assume this strip.
//
//   [128:126] location_update_type        (3 bit)
//   [125]     request_to_append_la        (1 bit)
//   [124]     cipher_control              (1 bit)
//             ciphering_parameters        (10 bit if cipher_control = 1)
//             o-bit                       (1 bit, optional fields present)
//             if o-bit == 1:
//               p_class_of_ms             (1 bit)
//                 class_of_ms             (24 bit if p = 1)
//               p_energy_saving_mode      (1 bit)
//                 energy_saving_mode      (3  bit if p = 1)
//               p_la_information          (1 bit)
//                 la_information          (15 bit if p = 1, low bit = 0)
//               p_ssi                     (1 bit)
//                 ssi                     (24 bit if p = 1)
//               p_address_extension       (1 bit)
//                 address_extension       (24 bit if p = 1)
//               // Type-3 / Type-4 list — m-bit + elem_id + length triples
//               while m-bit == 1:
//                 elem_id                 (4  bit)
//                 length                  (11 bit, payload length in bits)
//                 payload                 (length bits)
//               m-bit == 0 terminator     (1 bit)
//
// Type-3 elements recognised in this sprint:
//   elem_id = 3 (GroupIdentityLocationDemand)
//             → drill into payload for the embedded type-4
//               GroupIdentityUplink list.  The first GIU element with
//               address_type ∈ {0,1} is exposed via gild_gssi_sys /
//               gild_class_of_usage_sys / gild_address_type_sys.
//   any other elem_id → skipped (length-bits consumed and ignored).
//
// GroupIdentityLocationDemand (per `group_identity_location_demand.rs`):
//   reserved                                  (1 bit, must be 0)
//   group_identity_attach_detach_mode         (1 bit)
//   o-bit (type-4 list follows)               (1 bit)
//   if o-bit == 1:
//     m-bit                                   (1 bit, list start)
//     elem_id (= 8 GroupIdentityUplink)       (4 bit)
//     length                                  (11 bit, payload length)
//     payload (= num_elem (6) + GIU records)
//     m-bit                                   (terminator, = 0)
//
// GroupIdentityUplink (per `group_identity_uplink.rs`):
//   attach_detach_type_id                     (1 bit, 0 = attach)
//   if = 0: class_of_usage  (3 bit)
//   if = 1: gid_detach_uplink (2 bit)
//   address_type (2 bit)
//   if address_type ∈ {0, 1}: gssi (24 bit)
//   if address_type == 1:     address_extension (24 bit)
//   if address_type == 2:     vgssi (24 bit)
//
// Outputs (registered, stable from `parse_done_sys` until the next
// `start_sys` pulse):
//
//   location_update_type_sys[2:0]
//   request_to_append_la_sys
//   cipher_control_sys
//   class_of_ms_sys[23:0] / class_of_ms_valid_sys
//   energy_saving_mode_sys[2:0] / energy_saving_mode_valid_sys
//   la_information_sys[13:0] / la_information_valid_sys
//   ssi_field_sys[23:0]    / ssi_field_valid_sys     (SSI in MM body)
//   address_ext_sys[23:0]  / address_ext_valid_sys
//   pdu_ssi_sys[23:0]                              (passthrough from
//                                                    reassembly module)
//
//   gild_valid_sys                              (1 if a GILD IE present
//                                                AND a usable GIU element
//                                                with address_type∈{0,1})
//   gild_gssi_sys[23:0]
//   gild_class_of_usage_sys[2:0]
//   gild_address_type_sys[1:0]
//
//   parse_done_sys                              (1-cycle pulse)
//   parse_ok_sys                                (high during the same
//                                                 cycle when the body
//                                                 parsed without overrun
//                                                 / m-bit issues)
//
// =============================================================================

`default_nettype none

module tetra_ul_demand_ie_parser (
    input  wire                clk_sys,
    input  wire                rst_n_sys,

    // Stimulus from reassembly module
    input  wire                start_sys,
    input  wire [128:0]        body_sys,        // MSB-first; [128] = first on-air
    input  wire [23:0]         ssi_sys,
    input  wire [3:0]          mm_pdu_type_sys, // Phase Y.1.a — mm-type branch

    // Type-1 / Type-2 fields
    output reg  [2:0]          location_update_type_sys,
    output reg                 request_to_append_la_sys,
    output reg                 cipher_control_sys,
    output reg  [23:0]         class_of_ms_sys,
    output reg                 class_of_ms_valid_sys,
    output reg  [2:0]          energy_saving_mode_sys,
    output reg                 energy_saving_mode_valid_sys,
    output reg  [13:0]         la_information_sys,
    output reg                 la_information_valid_sys,
    output reg  [23:0]         ssi_field_sys,
    output reg                 ssi_field_valid_sys,
    output reg  [23:0]         address_ext_sys,
    output reg                 address_ext_valid_sys,

    // GroupIdentityLocationDemand IE (single-GIU summary for Phase 7 F.2)
    output reg                 gild_valid_sys,
    output reg  [23:0]         gild_gssi_sys,
    output reg  [2:0]          gild_class_of_usage_sys,
    output reg  [1:0]          gild_address_type_sys,

    // SSI of the reassembled PDU (from reassembly module).
    output reg  [23:0]         pdu_ssi_sys,

    // ----------------------------------------------------------------
    // Phase Y.1.a — mm=7 U-ATTACH-DETACH-GROUP-IDENTITY outputs.
    // Up to 3 GIU records exposed (multi-GSSI bodies stop at slot 2).
    //   gid_count_sys                 0..3 valid GIU records
    //   gid_attach_detach_mode_sys    1 bit (top-level mode)
    //   gid_group_identity_report_sys 1 bit (top-level report)
    //   gid_attach_detach_array_sys[i]    1 bit per record (0=attach,1=detach)
    //   gid_class_array_sys[i]            3 bit per record (class_of_usage,
    //                                                       valid only on attach)
    //   gid_address_type_array_sys[i]     2 bit per record
    //   gid_gssi_array_sys[i]             24 bit per record (gssi or vgssi
    //                                                        depending on at)
    // ----------------------------------------------------------------
    output reg  [1:0]          gid_count_sys,
    output reg                 gid_attach_detach_mode_sys,
    output reg                 gid_group_identity_report_sys,
    output reg  [2:0]          gid_attach_detach_array_sys, // 3 records, 1 bit each
    output reg  [8:0]          gid_class_array_sys,         // 3 × 3 bit
    output reg  [5:0]          gid_address_type_array_sys,  // 3 × 2 bit
    output reg  [71:0]         gid_gssi_array_sys,          // 3 × 24 bit

    // Status
    output reg                 parse_done_sys,
    output reg                 parse_ok_sys
);

    // -------------------------------------------------------------------------
    // Stream cursor + working buffer.  We snapshot `body_sys` into
    // `body_buf` on `start_sys` and decrement `cursor` as we consume bits.
    // cursor counts the number of bits remaining; the next bit to consume
    // sits at body_buf[cursor-1].  cursor=129 → about to take body_buf[128].
    // cursor=0 → stream exhausted.
    // -------------------------------------------------------------------------
    reg [128:0] body_buf;
    reg [7:0]   cursor;          // 0..129

    // -------------------------------------------------------------------------
    // FSM states.  A single state machine traverses the body with a tight
    // 1-cycle-per-decision loop.  Multi-bit fields are read in a single
    // cycle (combinational slice), so total parse latency is bounded by
    // the number of presence-flag decisions (~10 cycles for a typical
    // demand body).
    // -------------------------------------------------------------------------
    localparam [4:0] S_IDLE             = 5'd0;
    localparam [4:0] S_HEADER_T1        = 5'd1;
    localparam [4:0] S_OPT_OBIT         = 5'd2;
    localparam [4:0] S_T2_CLASS_P       = 5'd3;
    localparam [4:0] S_T2_ESM_P         = 5'd4;
    localparam [4:0] S_T2_LA_P          = 5'd5;
    localparam [4:0] S_T2_SSI_P         = 5'd6;
    localparam [4:0] S_T2_AE_P          = 5'd7;
    localparam [4:0] S_T3_M             = 5'd8;
    localparam [4:0] S_T3_HEADER        = 5'd9;
    localparam [4:0] S_T3_PAYLOAD_GILD  = 5'd10;
    localparam [4:0] S_DONE             = 5'd11;
    localparam [4:0] S_DONE_FAIL        = 5'd12;
    // Phase Y.1.a — mm=7 U-ATTACH-DETACH-GROUP-IDENTITY walker states
    localparam [4:0] S_GAD_HDR          = 5'd13; // skip redundant pdu_type, latch top hdr
    localparam [4:0] S_GAD_OBIT         = 5'd14; // optional fields o-bit
    localparam [4:0] S_GAD_M_REP        = 5'd15; // m-bit for group_report_response
    localparam [4:0] S_GAD_M_GIU        = 5'd16; // m-bit for group_identity_uplink
    // Phase Y.1.a-fix — pipelined GIU record walker (one record per cycle pair)
    localparam [4:0] S_GAD_GIU_INIT     = 5'd17; // latch num_elem, off=6
    localparam [4:0] S_GAD_GIU_REC_HDR  = 5'd18; // 1 record: read adi+cou+at, advance off
    localparam [4:0] S_GAD_GIU_REC_GSSI = 5'd19; // 1 record: read 24-bit gssi, optional ae

    reg [4:0] state;

    // -------------------------------------------------------------------------
    // Phase Y.1.a-fix — pipelined GIU walker registers.
    //
    // Splits the 3-record one-cycle walker (~29 logic levels) into a tiny
    // FSM that processes ONE record across two cycles (HDR + GSSI).  All
    // bit-slice index arithmetic is reduced to a single subtractor per
    // cycle (`body_buf[gad_base - gad_off]`), eliminating the deep mux
    // cascade that came from chaining 3 record-blocks combinationally.
    //
    // gad_base is the bit index of the first GIU payload bit (= cursor-1
    // captured at S_GAD_GIU_INIT entry); gad_off counts bits consumed
    // *within* the payload starting at num_elem(6).
    // -------------------------------------------------------------------------
    reg [7:0]  gad_base;        // body_buf MSB index for payload bit 0
    reg [10:0] gad_off;         // running offset within payload, in bits
    reg [5:0]  gad_num_elem;    // total GIU record count
    reg [1:0]  gad_rec_idx;     // next record to write (0..3)
    reg        gad_adi;         // current record attach/detach flag
    reg [2:0]  gad_cou;         // current record class_of_usage
    reg [1:0]  gad_at;          // current record address_type
    reg        gad_skip_ae;     // record HDR signaled an extra 24-bit AE skip

    // Type-3 element header staging
    reg [3:0]  cur_elem_id;
    reg [10:0] cur_elem_len;     // up to 2047 bits (length is 11-bit per ETSI)

    // Phase Y.1.a — mm-type latched at start (used to dispatch + ignore
    // foreign types).
    reg [3:0]  mm_pdu_type_lat;

    // -------------------------------------------------------------------------
    // GILD payload snapshot: when we encounter a Type-3 elem_id=3, we slice
    // the payload bits into a separate buffer (gild_buf) so the GILD walker
    // does not perturb the outer cursor.  The outer cursor is decremented
    // by exactly cur_elem_len in S_T3_HEADER, and S_T3_PAYLOAD_GILD does
    // its work entirely in one cycle on the snapshot.
    //
    // The snapshot is MSB-aligned at gild_buf[cur_elem_len-1 .. 0]: payload
    // bit 0 (first on-air) sits at gild_buf[cur_elem_len-1].
    // -------------------------------------------------------------------------
    reg [255:0] gild_buf;

    // -------------------------------------------------------------------------
    // Combinational helper — peek the next bit at the outer cursor.
    // -------------------------------------------------------------------------
    wire        peek1 = body_buf[cursor - 8'd1];

    // -------------------------------------------------------------------------
    // Sequential FSM
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            state                          <= S_IDLE;
            body_buf                       <= 129'd0;
            cursor                         <= 8'd0;
            gild_buf                       <= 256'd0;
            cur_elem_id                    <= 4'd0;
            cur_elem_len                   <= 11'd0;
            location_update_type_sys       <= 3'd0;
            request_to_append_la_sys       <= 1'b0;
            cipher_control_sys             <= 1'b0;
            class_of_ms_sys                <= 24'd0;
            class_of_ms_valid_sys          <= 1'b0;
            energy_saving_mode_sys         <= 3'd0;
            energy_saving_mode_valid_sys   <= 1'b0;
            la_information_sys             <= 14'd0;
            la_information_valid_sys       <= 1'b0;
            ssi_field_sys                  <= 24'd0;
            ssi_field_valid_sys            <= 1'b0;
            address_ext_sys                <= 24'd0;
            address_ext_valid_sys          <= 1'b0;
            gild_valid_sys                 <= 1'b0;
            gild_gssi_sys                  <= 24'd0;
            gild_class_of_usage_sys        <= 3'd0;
            gild_address_type_sys          <= 2'd0;
            pdu_ssi_sys                    <= 24'd0;
            mm_pdu_type_lat                <= 4'd0;
            gid_count_sys                  <= 2'd0;
            gid_attach_detach_mode_sys     <= 1'b0;
            gid_group_identity_report_sys  <= 1'b0;
            gid_attach_detach_array_sys    <= 3'd0;
            gid_class_array_sys            <= 9'd0;
            gid_address_type_array_sys     <= 6'd0;
            gid_gssi_array_sys             <= 72'd0;
            gad_base                       <= 8'd0;
            gad_off                        <= 11'd0;
            gad_num_elem                   <= 6'd0;
            gad_rec_idx                    <= 2'd0;
            gad_adi                        <= 1'b0;
            gad_cou                        <= 3'd0;
            gad_at                         <= 2'd0;
            gad_skip_ae                    <= 1'b0;
            parse_done_sys                 <= 1'b0;
            parse_ok_sys                   <= 1'b0;
        end else begin
            // Defaults (single-cycle pulses)
            parse_done_sys <= 1'b0;
            parse_ok_sys   <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (start_sys) begin
                    body_buf                     <= body_sys;
                    cursor                       <= 8'd129;
                    pdu_ssi_sys                  <= ssi_sys;
                    mm_pdu_type_lat              <= mm_pdu_type_sys;
                    // Clear all output validity on a new parse cycle.
                    class_of_ms_valid_sys        <= 1'b0;
                    energy_saving_mode_valid_sys <= 1'b0;
                    la_information_valid_sys     <= 1'b0;
                    ssi_field_valid_sys          <= 1'b0;
                    address_ext_valid_sys        <= 1'b0;
                    gild_valid_sys               <= 1'b0;
                    gid_count_sys                <= 2'd0;
                    gid_attach_detach_mode_sys   <= 1'b0;
                    gid_group_identity_report_sys<= 1'b0;
                    gid_attach_detach_array_sys  <= 3'd0;
                    gid_class_array_sys          <= 9'd0;
                    gid_address_type_array_sys   <= 6'd0;
                    gid_gssi_array_sys           <= 72'd0;
                    // Phase Y.1.a — mm-type dispatch
                    case (mm_pdu_type_sys)
                        4'd2:    state <= S_HEADER_T1;     // mm=2 LOC-UPDATE-DEMAND
                        4'd7:    state <= S_GAD_HDR;       // mm=7 ATTACH-DETACH-GRP-ID
                        default: state <= S_DONE_FAIL;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Type-1 header — always 5 bits (LUT 3 + ra 1 + cc 1).
            // cipher_control gates the 10-bit ciphering_parameters tail.
            // -----------------------------------------------------------------
            S_HEADER_T1: begin
                if (cursor >= 8'd5) begin
                    location_update_type_sys <= body_buf[cursor - 8'd1 -: 3];
                    request_to_append_la_sys <= body_buf[cursor - 8'd4];
                    cipher_control_sys       <= body_buf[cursor - 8'd5];
                    if (body_buf[cursor - 8'd5] == 1'b1) begin
                        if (cursor >= 8'd15) begin
                            // Skip the 10-bit ciphering_parameters block.
                            cursor <= cursor - 8'd15;
                            state  <= S_OPT_OBIT;
                        end else begin
                            state <= S_DONE_FAIL;
                        end
                    end else begin
                        cursor <= cursor - 8'd5;
                        state  <= S_OPT_OBIT;
                    end
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // Optional-fields o-bit.  obit==0 → body ends; bluestation does
            // not require a trailing m-bit in this case (it returns early).
            // -----------------------------------------------------------------
            S_OPT_OBIT: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
                end else begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T2_CLASS_P;
                end
            end

            // -----------------------------------------------------------------
            // Type-2 class_of_ms presence + 24-bit field.
            // -----------------------------------------------------------------
            S_T2_CLASS_P: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T2_ESM_P;
                end else if (cursor >= 8'd25) begin
                    class_of_ms_sys       <= body_buf[cursor - 8'd2 -: 24];
                    class_of_ms_valid_sys <= 1'b1;
                    cursor                <= cursor - 8'd25;
                    state                 <= S_T2_ESM_P;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_T2_ESM_P: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T2_LA_P;
                end else if (cursor >= 8'd4) begin
                    energy_saving_mode_sys       <= body_buf[cursor - 8'd2 -: 3];
                    energy_saving_mode_valid_sys <= 1'b1;
                    cursor                       <= cursor - 8'd4;
                    state                        <= S_T2_LA_P;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // la_information: bluestation reads 15 bits and divides by 2 to
            // get the 14-bit LA (low bit always 0).  We expose the 14-bit LA.
            // -----------------------------------------------------------------
            S_T2_LA_P: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T2_SSI_P;
                end else if (cursor >= 8'd16) begin
                    la_information_sys       <= body_buf[cursor - 8'd2 -: 14];
                    la_information_valid_sys <= 1'b1;
                    cursor                   <= cursor - 8'd16;
                    state                    <= S_T2_SSI_P;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_T2_SSI_P: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T2_AE_P;
                end else if (cursor >= 8'd25) begin
                    ssi_field_sys       <= body_buf[cursor - 8'd2 -: 24];
                    ssi_field_valid_sys <= 1'b1;
                    cursor              <= cursor - 8'd25;
                    state               <= S_T2_AE_P;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_T2_AE_P: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_T3_M;
                end else if (cursor >= 8'd25) begin
                    address_ext_sys       <= body_buf[cursor - 8'd2 -: 24];
                    address_ext_valid_sys <= 1'b1;
                    cursor                <= cursor - 8'd25;
                    state                 <= S_T3_M;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // Type-3 list — m-bit terminator.  Loop until m-bit == 0.
            // -----------------------------------------------------------------
            S_T3_M: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
                end else if (cursor >= 8'd16) begin
                    cur_elem_id  <= body_buf[cursor - 8'd2 -: 4];
                    cur_elem_len <= body_buf[cursor - 8'd6 -: 11];
                    cursor       <= cursor - 8'd16;
                    state        <= S_T3_HEADER;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // Type-3 header decoded.  Route based on elem_id and consume
            // the payload bits.
            //
            // For elem_id=3 (GILD) we snapshot the payload into gild_buf
            // and walk it in S_T3_PAYLOAD_GILD.  For all other ids we skip
            // the payload entirely.
            // -----------------------------------------------------------------
            S_T3_HEADER: begin
                if ({1'b0, cursor} < {2'b00, cur_elem_len[7:0]}) begin
                    // Stream too short to hold the claimed payload.
                    state <= S_DONE_FAIL;
                end else if (cur_elem_id == 4'd3 && cur_elem_len > 11'd0) begin
                    // Snapshot the payload into gild_buf, MSB-aligned.
                    // Right-shift body_buf by (cursor - cur_elem_len) bits
                    // to drop the bits AFTER the payload.  The payload's
                    // MSB then lands at gild_buf[cur_elem_len-1] and the
                    // header bits sit above (we mask them off conceptually
                    // by indexing only the low cur_elem_len bits when
                    // reading).
                    gild_buf      <= ({{(256-129){1'b0}}, body_buf} >>
                                       (cursor - cur_elem_len));
                    cursor        <= cursor - cur_elem_len[7:0];
                    state         <= S_T3_PAYLOAD_GILD;
                end else begin
                    // Skip non-GILD payload wholesale.
                    cursor <= cursor - cur_elem_len[7:0];
                    state  <= S_T3_M;
                end
            end

            // -----------------------------------------------------------------
            // GILD payload sub-walker.  All decoding done in one cycle —
            // we do not advance gild_buf, just index into it directly.
            //
            // We expose the FIRST GroupIdentityUplink record (Phase 7 F.2
            // only requires single-GIU support; the FSM scaffolding loops
            // multi-GSSI elsewhere via direct stimulus, M4 widens this to
            // proper multi-GIU parsing).
            //
            // GILD payload offsets — let g = cur_elem_len.  The reserved
            // bit sits at gild_buf[g-1]; subsequent bits are accessed at
            // gild_buf[g-2], gild_buf[g-3], …  All field offsets below are
            // expressed in terms of g.
            //
            //   g-1   reserved (= 0)
            //   g-2   group_identity_attach_detach_mode
            //   g-3   o-bit
            //   if o-bit == 1:
            //     g-4              m-bit (list start, must be 1)
            //     g-5..g-8         elem_id (4 bit; expect 8 for GIU)
            //     g-9..g-19        length (11 bit, payload size in bits)
            //     g-20..g-25       num_elem (6 bit; expect ≥1)
            //     g-26..           first GIU element
            //
            // Inside the first GIU, with cur_elem_len read above:
            //     g-26             attach_detach_type_id
            //     if = 0: g-27..g-29 class_of_usage (3 bit)
            //              g-30..g-31 address_type (2 bit)
            //              if at∈{0,1}: g-32..g-55 gssi (24 bit)
            //
            // We bail out (gild_valid_sys=0) if any structural assumption
            // breaks.  The outer FSM then resumes the type-3 loop with the
            // already-decremented cursor.
            // -----------------------------------------------------------------
            S_T3_PAYLOAD_GILD: begin : gild_decode
                reg [10:0] g;
                reg        atd_mode;
                reg        obit;
                reg        mbit;
                reg [3:0]  sub_id;
                reg [10:0] sub_len;
                reg [5:0]  num_elem;
                reg        adi;
                reg [2:0]  cou;
                reg [1:0]  at;
                reg [23:0] gssi;
                g        = cur_elem_len;
                atd_mode = 1'b0;
                obit     = 1'b0;
                mbit     = 1'b0;
                sub_id   = 4'd0;
                sub_len  = 11'd0;
                num_elem = 6'd0;
                adi      = 1'b0;
                cou      = 3'd0;
                at       = 2'd0;
                gssi     = 24'd0;
                if (g >= 11'd3) begin
                    atd_mode = gild_buf[g - 11'd2];
                    obit     = gild_buf[g - 11'd3];
                    if (obit == 1'b1 && g >= 11'd29) begin
                        mbit    = gild_buf[g - 11'd4];
                        sub_id  = gild_buf[g - 11'd5  -: 4];
                        sub_len = gild_buf[g - 11'd9  -: 11];
                        if (mbit == 1'b1 && sub_id == 4'd8 &&
                            sub_len >= 11'd6 && g >= 11'd32) begin
                            num_elem = gild_buf[g - 11'd20 -: 6];
                            if (num_elem >= 6'd1) begin
                                adi = gild_buf[g - 11'd26];
                                if (adi == 1'b0 && g >= 11'd56) begin
                                    cou = gild_buf[g - 11'd27 -: 3];
                                    at  = gild_buf[g - 11'd30 -: 2];
                                    if (at == 2'b00 || at == 2'b01) begin
                                        gssi = gild_buf[g - 11'd32 -: 24];
                                        gild_gssi_sys           <= gssi;
                                        gild_class_of_usage_sys <= cou;
                                        gild_address_type_sys   <= at;
                                        gild_valid_sys          <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end
                // atd_mode is parsed but not yet exposed (M4 will use it
                // for U-ATTACH-DETACH-GROUP-IDENTITY).  Tie it off here.
                if (atd_mode == 1'b1) begin /* future: detach path */ end
                state <= S_T3_M;
            end

            // -----------------------------------------------------------------
            // Phase Y.1.a — mm=7 U-ATTACH-DETACH-GROUP-IDENTITY walker
            //
            // Body layout (per `u_attach_detach_group_identity.rs`, MSB-first
            // in body_sys; bit[128] = first MM-body bit AFTER pdu_type strip).
            // The 4-bit pdu_type that appears on-air at info_bits[44..47] is
            // already removed by the LLC layer before the 129-bit body is
            // assembled; it is therefore NOT present in body_sys.
            //
            //   [128]       group_identity_report                          1 bit
            //   [127]       attach_detach_mode                             1 bit
            //   [126]       o-bit (optional fields follow)                 1 bit
            //     if o-bit:
            //       [125]   m-bit shared by parse_type3_generic(GRR=4)
            //               and parse_type4_struct(GIU=8) per bluestation
            //               peek_type34_mbit_and_id semantics.  GRR (elem
            //               id=4) is consumed only when m=1 AND the next
            //               4 bits == 4'd4; otherwise the m-bit stays for
            //               the GIU walker to peek again.
            //         if GRR present: [124..121] elem_id=0100 + [120..110]
            //               length(11) + length bits payload (skip)
            //       [..]    m-bit for GIU
            //         if m=1 && elem_id=1000: 4-bit id + 11-bit length
            //               + 6-bit num_elem + N×GIU records
            // -----------------------------------------------------------------
            S_GAD_HDR: begin : gad_hdr_blk
                // Reassembly already stripped the on-air pdu_type, so the
                // top of body_buf is GIR + atd_mode directly.
                if (cursor >= 8'd3) begin
                    gid_group_identity_report_sys <= body_buf[cursor - 8'd1];
                    gid_attach_detach_mode_sys    <= body_buf[cursor - 8'd2];
                    cursor                        <= cursor - 8'd2;
                    state                         <= S_GAD_OBIT;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_GAD_OBIT: begin
                if (cursor == 8'd0) begin
                    // No optional payload — only the 2-bit header (no GIU).
                    state <= S_DONE;
                end else if (peek1 == 1'b0) begin
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
                end else begin
                    cursor <= cursor - 8'd1;
                    state  <= S_GAD_M_REP;
                end
            end

            // -----------------------------------------------------------------
            // m-bit for GroupReportResponse (Type-3, elem_id=4) — bluestation
            // peek_type34_mbit_and_id semantics: only consume the m-bit when
            // it is 1 AND the trailing 4-bit elem_id == expected (=4).  When
            // m-bit==0 we still consume it (GRR not present, fall through to
            // GIU); when m-bit==1 with elem_id != 4 the m-bit BELONGS to the
            // following Type-4 (GIU) walker, so we DO NOT consume — just hand
            // over with cursor untouched.
            S_GAD_M_REP: begin : gad_m_rep_blk
                reg [10:0] skip_len;
                reg [3:0]  peek_id;
                skip_len = 11'd0;
                peek_id  = 4'd0;
                if (cursor == 8'd0) begin
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    // m-bit explicitly 0 — consume the bit, GRR not present.
                    cursor <= cursor - 8'd1;
                    state  <= S_GAD_M_GIU;
                end else if (cursor >= 8'd5) begin
                    // m-bit == 1: peek elem_id WITHOUT consuming the m-bit.
                    peek_id = body_buf[cursor - 8'd2 -: 4];
                    if (peek_id != 4'd4) begin
                        // elem_id != GroupReportResponse — the m-bit is for
                        // the upcoming GIU element; leave cursor untouched.
                        state <= S_GAD_M_GIU;
                    end else if (cursor >= 8'd16) begin
                        // GRR present: consume m-bit + elem_id(4) + len(11)
                        // + length bits of opaque payload.
                        skip_len = body_buf[cursor - 8'd6 -: 11];
                        if ({1'b0, cursor} >=
                                ({2'b00, skip_len[7:0]} + 17)) begin
                            cursor <= cursor - 8'd16 - skip_len[7:0];
                            state  <= S_GAD_M_GIU;
                        end else begin
                            state <= S_DONE_FAIL;
                        end
                    end else begin
                        state <= S_DONE_FAIL;
                    end
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // m_group_identity_uplink (Type-4) — drives GIU record walker.
            S_GAD_M_GIU: begin : gad_m_giu_blk
                reg [3:0]  sub_id;
                reg [10:0] sub_len;
                sub_id  = 4'd0;
                sub_len = 11'd0;
                if (cursor == 8'd0) begin
                    state <= S_DONE;
                end else if (peek1 == 1'b0) begin
                    // GIU not present; mm=7 with no records is unusual but
                    // accept it (spec allows; gid_count stays 0).
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
                end else if (cursor >= 8'd16) begin
                    sub_id  = body_buf[cursor - 8'd2 -: 4];
                    sub_len = body_buf[cursor - 8'd6 -: 11];
                    if (sub_id == 4'd8 && {1'b0, cursor} >=
                            ({2'b00, sub_len[7:0]} + 17)) begin
                        // Set up payload walker — payload starts cursor-16
                        // (after eating elem_id+length), payload size =
                        // sub_len bits.  Pipelined walker takes 2 cycles
                        // per record (HDR + GSSI) plus one INIT cycle.
                        cur_elem_len <= sub_len;
                        cursor       <= cursor - 8'd16;
                        state        <= S_GAD_GIU_INIT;
                    end else begin
                        state <= S_DONE_FAIL;
                    end
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            // Phase Y.1.a-fix — pipelined GIU payload walker.
            //
            // Payload sits in body_buf[cursor-1 .. cursor-cur_elem_len], MSB-
            // first.  Layout: num_elem(6) + N×GIU.  Each GIU varies in size:
            //   attach (atd=0): 1 + 3 + 2 + (24 if at∈{0,1,2}) + (24 if at==1)
            //                 = 6/30/54 bits
            //   detach (atd=1): 1 + 2 + 2 + (24 if at∈{0,1,2}) + (24 if at==1)
            //                 = 5/29/53 bits
            //
            // The original walker ran num_elem + 3-record-unroll in ONE cycle
            // with a chained `off` accumulator that gated 5 separate 24-bit
            // mux indices through ~29 logic levels (timing-fail at 100 MHz).
            //
            // The pipelined walker uses three states:
            //   INIT      — read num_elem(6), latch off=6 + base = cursor-1.
            //   REC_HDR   — read adi(1) and the variable-length record header
            //               (cou+at for attach, skip+at for detach).  Update
            //               off by +6 (attach) or +5 (detach), latch
            //               gad_adi/gad_cou/gad_at.  One bit-slice per cycle.
            //   REC_GSSI  — read 24-bit gssi (if at∈{0,1,2}), write the
            //               record into gid_*_array_sys[gad_rec_idx], advance
            //               off by +24 or +48 (when at==1), increment
            //               rec_idx.  Loop back to REC_HDR or finish.
            //
            // Each state does ONE 24-bit slice at a single subtractor depth.
            // Total parse latency for 1 record = 3 cycles (INIT+HDR+GSSI),
            // for 2 records = 5 cycles, for 3 records = 7 cycles.  This is
            // well within Demand-Mailbox roundtrip budget.
            // -----------------------------------------------------------------
            S_GAD_GIU_INIT: begin
                if (cur_elem_len < 11'd6) begin
                    state <= S_DONE_FAIL;
                end else begin
                    gad_base     <= cursor - 8'd1;       // payload bit 0 index
                    gad_num_elem <= body_buf[cursor - 8'd1 -: 6];
                    gad_off      <= 11'd6;               // num_elem consumed
                    gad_rec_idx  <= 2'd0;
                    if (body_buf[cursor - 8'd1 -: 6] == 6'd0) begin
                        // num_elem == 0 — empty list, accept gracefully.
                        gid_count_sys <= 2'd0;
                        state         <= S_DONE;
                    end else begin
                        state <= S_GAD_GIU_REC_HDR;
                    end
                end
            end

            // -----------------------------------------------------------------
            // Per-record header: read adi, then either (cou+at) or (skip+at).
            // gad_base - gad_off[7:0] is ONE subtraction; subsequent slices
            // within this cycle use +1/+3 offsets relative to it.
            // -----------------------------------------------------------------
            S_GAD_GIU_REC_HDR: begin : gad_rec_hdr_blk
                reg [7:0]  pos0;     // first remaining bit (= gad_base - gad_off)
                reg        adi_w;
                reg [1:0]  at_w;
                reg [2:0]  cou_w;
                reg        ok_w;
                pos0  = gad_base - gad_off[7:0];
                adi_w = body_buf[pos0];
                cou_w = 3'd0;
                at_w  = 2'd0;
                ok_w  = 1'b1;
                if (adi_w == 1'b0) begin
                    // attach: cou(3) + at(2) follow adi
                    if ((gad_off + 11'd6) > cur_elem_len) begin
                        ok_w = 1'b0;
                    end else begin
                        cou_w = body_buf[pos0 - 8'd1 -: 3];
                        at_w  = body_buf[pos0 - 8'd4 -: 2];
                    end
                end else begin
                    // detach: skip(2) + at(2) follow adi
                    if ((gad_off + 11'd5) > cur_elem_len) begin
                        ok_w = 1'b0;
                    end else begin
                        at_w = body_buf[pos0 - 8'd3 -: 2];
                    end
                end
                if (!ok_w) begin
                    // Truncated header — accept records collected so far.
                    gid_count_sys <= gad_rec_idx;
                    state         <= (gad_rec_idx == 2'd0) ? S_DONE_FAIL
                                                            : S_DONE;
                end else begin
                    gad_adi <= adi_w;
                    gad_cou <= cou_w;
                    gad_at  <= at_w;
                    if (adi_w == 1'b0)
                        gad_off <= gad_off + 11'd6;   // 1 adi + 3 cou + 2 at
                    else
                        gad_off <= gad_off + 11'd5;   // 1 adi + 2 skip + 2 at
                    gad_skip_ae <= (at_w == 2'b01);
                    state <= S_GAD_GIU_REC_GSSI;
                end
            end

            // -----------------------------------------------------------------
            // Per-record GSSI read + write to output array.
            // - For at∈{0,1,2}: read 24-bit gssi at body_buf[gad_base-gad_off].
            // - For at==1: also skip 24-bit address_extension (no field).
            // - For at==3: no gssi (g24 stays 0).
            // The indexed write to gid_gssi_array_sys[gad_rec_idx] is a 3:1
            // mux of 24-bit slices — short logic.
            // -----------------------------------------------------------------
            S_GAD_GIU_REC_GSSI: begin : gad_rec_gssi_blk
                reg [7:0]  pos0;
                reg [23:0] g24_w;
                reg        ok_w;
                reg [10:0] off_after;
                pos0      = gad_base - gad_off[7:0];
                g24_w     = 24'd0;
                ok_w      = 1'b1;
                off_after = gad_off;
                if (gad_at == 2'b00 || gad_at == 2'b01 || gad_at == 2'b10) begin
                    if ((gad_off + 11'd24) > cur_elem_len) begin
                        ok_w = 1'b0;
                    end else begin
                        g24_w     = body_buf[pos0 -: 24];
                        off_after = gad_off + 11'd24;
                        if (gad_skip_ae) begin
                            if ((off_after + 11'd24) > cur_elem_len)
                                ok_w = 1'b0;
                            else
                                off_after = off_after + 11'd24;
                        end
                    end
                end
                if (!ok_w) begin
                    gid_count_sys <= gad_rec_idx;
                    state         <= (gad_rec_idx == 2'd0) ? S_DONE_FAIL
                                                            : S_DONE;
                end else begin
                    // Write the record into the appropriate slot.
                    case (gad_rec_idx)
                        2'd0: begin
                            gid_attach_detach_array_sys[0]  <= gad_adi;
                            gid_class_array_sys[2:0]        <= gad_cou;
                            gid_address_type_array_sys[1:0] <= gad_at;
                            gid_gssi_array_sys[23:0]        <= g24_w;
                        end
                        2'd1: begin
                            gid_attach_detach_array_sys[1]  <= gad_adi;
                            gid_class_array_sys[5:3]        <= gad_cou;
                            gid_address_type_array_sys[3:2] <= gad_at;
                            gid_gssi_array_sys[47:24]       <= g24_w;
                        end
                        default: begin // 2'd2 (cap at 3 records)
                            gid_attach_detach_array_sys[2]  <= gad_adi;
                            gid_class_array_sys[8:6]        <= gad_cou;
                            gid_address_type_array_sys[5:4] <= gad_at;
                            gid_gssi_array_sys[71:48]       <= g24_w;
                        end
                    endcase
                    gad_off     <= off_after;
                    gad_rec_idx <= gad_rec_idx + 2'd1;
                    // Done when this slot was the last requested record OR
                    // we've filled all 3 output slots (cap at 3).
                    // gad_num_elem is 6 bit; widen rec_idx for compare.
                    if ((({4'd0, gad_rec_idx} + 6'd1) >= gad_num_elem) ||
                        (gad_rec_idx == 2'd2)) begin
                        gid_count_sys <= gad_rec_idx + 2'd1;
                        state         <= S_DONE;
                    end else begin
                        state <= S_GAD_GIU_REC_HDR;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_DONE: begin
                parse_done_sys <= 1'b1;
                parse_ok_sys   <= 1'b1;
                state          <= S_IDLE;
            end

            // -----------------------------------------------------------------
            S_DONE_FAIL: begin
                parse_done_sys <= 1'b1;
                parse_ok_sys   <= 1'b0;
                state          <= S_IDLE;
            end

            // -----------------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
