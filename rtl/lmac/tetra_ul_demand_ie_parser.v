// =============================================================================
// tetra_ul_demand_ie_parser.v — Phase 7 F.2 (mm=2 GILD-only after Phase H.0.4)
// =============================================================================
//
// Parses the 129-bit reassembled MM body produced by
// tetra_ul_demand_reassembly.v and exposes the U-LOCATION-UPDATE-DEMAND
// fields (mm_pdu_type==2, ETSI EN 300 392-2 §16.10.21 + bluestation
// `mm/pdus/u_location_update_demand.rs`) as registered outputs.
//
// Phase H.0.4 (2026-04-27): the mm=7 U-ATTACH-DETACH-GROUP-IDENTITY
// walker (S_GAD_*, gad_*_sys outputs, body_kind_sys dispatch) was
// removed per the FPGA+SW split — Group-Switch flow moves to ARM SW.
// This module is again mm=2-only.
//
// Entry: pulse `start_sys` with `body_sys` / `ssi_sys` valid.  The parser
// walks the variable-length bitstream over a few clock cycles and asserts
// `parse_done_sys` for one cycle when finished.  `parse_ok_sys` is high
// during the same cycle when the stream parsed cleanly.
//
// Body layout (MSB-first; bit[128] = first on-air bit, == ul0_bits[48]):
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

    reg [4:0] state;

    // Type-3 element header staging
    reg [3:0]  cur_elem_id;
    reg [10:0] cur_elem_len;     // up to 2047 bits (length is 11-bit per ETSI)

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
                    // Clear all output validity on a new parse cycle.
                    class_of_ms_valid_sys        <= 1'b0;
                    energy_saving_mode_valid_sys <= 1'b0;
                    la_information_valid_sys     <= 1'b0;
                    ssi_field_valid_sys          <= 1'b0;
                    address_ext_valid_sys        <= 1'b0;
                    gild_valid_sys               <= 1'b0;
                    state                        <= S_HEADER_T1;
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
