// =============================================================================
// tetra_ul_demand_ie_parser.v — Phase 7 F.2 + F.7.1
// =============================================================================
//
// Parses the 129-bit reassembled MM body produced by
// tetra_ul_demand_reassembly.v and exposes either the U-LOCATION-UPDATE-DEMAND
// fields (mm_pdu_type==2, ETSI EN 300 392-2 §16.10.21 + bluestation
// `mm/pdus/u_location_update_demand.rs`) or the
// U-ATTACH-DETACH-GROUP-IDENTITY fields (mm_pdu_type==7, ETSI §16.9.3.1 +
// bluestation `mm/pdus/u_attach_detach_group_identity.rs`) as registered
// outputs.  The caller selects the body type via `body_kind_sys`:
//
//   body_kind_sys = 0  →  U-LOCATION-UPDATE-DEMAND   (Phase 7 F.2 path)
//   body_kind_sys = 1  →  U-ATTACH-DETACH-GROUP-ID   (Phase 7 F.7.1 path)
//
// The legacy (mm=2) walker is bit-for-bit unchanged so the
// `profile0_m2_guard` regression and gold-ref M2 attach replay stay green.
// The mm=7 walker is a parallel FSM tail invoked when body_kind_sys=1 and
// produces a separate set of `gad_*` outputs (GAD = group-attach-detach).
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
// Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY (mm_pdu_type=7) walker.
// The 129-bit body for mm=7 is produced by the same reassembly module as
// mm=2 (mm_type-agnostic, F.1 design lock).  Layout per
// `reference_group_attach_bitexact.md` decoded UL#0+UL#1:
//
//   bit[ 0]      group_identity_report           1 bit  (Type-1)
//   bit[ 1]      attach_detach_mode              1 bit  (Type-1, 0=amend
//                                                       1=replace-all)
//   bit[ 2]      o-bit                           1 bit
//   if obit == 1:
//     // Optional Type-3/4 elements, peek-and-skip semantics:
//     // Order per bluestation u_attach_detach_group_identity.rs:
//     //   group_report_response  (Type-3 id=4)
//     //   group_identity_uplink  (Type-4 id=8)
//     //   proprietary            (Type-3 id=15)
//     // We only consume GroupIdentityUplink; other id's are skipped via
//     // length field.  Multiple GIU records (num_elem) walked sequentially.
//   trailing m-bit                                1 bit
//
// GroupIdentityUplink record (per `mm/fields/group_identity_uplink.rs`):
//   bit[+0]      attach_detach_type_id           (1 bit, 0=attach 1=detach)
//   if attach (=0): class_of_usage               (3 bit)
//   if detach (=1): group_identity_detachment_uplink (2 bit)
//   bits[..]     address_type                    (2 bit, 0=GSSI, 1=GSSI+AE,
//                                                          2=VGSSI)
//   if at∈{0,1}: gssi                            (24 bit)
//   if at == 1:  address_extension               (24 bit)
//   if at == 2:  vgssi                           (24 bit)
//
// F.7.1 outputs the first 3 records (at most) into a fixed-width array.
// Each slot exposes attach/detach-type, class_of_usage (or detachment
// code), address_type, and gssi.  Records with addr_type=2 (VGSSI) are
// flagged but the 24-bit value is written into the gssi slot — VGSSI vs
// GSSI is disambiguated downstream via gad_address_type_array.
//
//   gad_valid_sys                              (1 if mm=7 body parsed OK
//                                                AND obit=1 AND at least
//                                                one GIU record present)
//   gad_attach_detach_mode_sys                  (1 bit)
//   gad_count_sys[2:0]                          (number of GIU records
//                                                exposed, capped at 3)
//   gad_attach_array_sys[2:0]                   (per-slot attach=0/detach=1)
//   gad_class_array_sys[8:0]                    (per-slot class_of_usage 3b)
//   gad_at_array_sys[5:0]                       (per-slot address_type 2b)
//   gad_gssi_array_sys[71:0]                    (per-slot 24b GSSI/VGSSI)
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
    // Body kind selector — sampled with start_sys.
    //   0 = U-LOCATION-UPDATE-DEMAND  (mm_pdu_type=2, Phase 7 F.2)
    //   1 = U-ATTACH-DETACH-GROUP-ID  (mm_pdu_type=7, Phase 7 F.7.1)
    // Default 0 (mm=2) preserves Phase F.2 wiring for callers that omit
    // the input; the existing top-level wires the value from the latched
    // mm_pdu_type captured at frag1_pulse.
    input  wire                body_kind_sys,

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

    // Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY (mm=7) outputs.
    // Up to 3 GroupIdentityUplink records exposed in arrayed form:
    //   gad_attach_array_sys[k]  : 0 = attach,  1 = detach (slot k)
    //   gad_class_array_sys[3*k +: 3] : class_of_usage (attach) or
    //                                   {1'b0, group_identity_detachment_uplink}
    //                                   (detach; 2-bit value zero-extended).
    //   gad_at_array_sys[2*k +: 2]    : address_type (0=GSSI, 1=GSSI+AE,
    //                                   2=VGSSI).
    //   gad_gssi_array_sys[24*k +: 24]: 24-bit GSSI / VGSSI.
    output reg                 gad_valid_sys,
    output reg                 gad_attach_detach_mode_sys,
    output reg  [2:0]          gad_count_sys,
    output reg  [2:0]          gad_attach_array_sys,
    output reg  [8:0]          gad_class_array_sys,
    output reg  [5:0]          gad_at_array_sys,
    output reg  [71:0]         gad_gssi_array_sys,

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
    // Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY walker states.
    localparam [4:0] S_GAD_HEADER_T1    = 5'd13;
    localparam [4:0] S_GAD_OBIT         = 5'd14;
    localparam [4:0] S_GAD_T34_M        = 5'd15;
    localparam [4:0] S_GAD_T34_HEADER   = 5'd16;
    localparam [4:0] S_GAD_GIU_LIST     = 5'd17;
    localparam [4:0] S_GAD_TRAILING_M   = 5'd18;

    reg [4:0] state;
    // Latched body kind selector — sampled at S_IDLE on start_sys edge.
    reg       lat_body_kind;

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
    // F.7.1 — Per-GIU walker state.  We stay on the outer cursor (no payload
    // snapshot) because the GIU records sit directly in the body_buf stream
    // after the Type-4 length field.  Up to 3 records exposed; gad_count_sys
    // saturates there.
    // -------------------------------------------------------------------------
    reg [10:0] gad_pending_giu_bits;   // bits of GIU payload still to walk
    reg [5:0]  gad_remaining_records;  // records still to walk
    reg [2:0]  gad_idx;                // 0..2 (output slot index)

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
            // Phase 7 F.7.1 — GAD outputs reset
            gad_valid_sys                  <= 1'b0;
            gad_attach_detach_mode_sys     <= 1'b0;
            gad_count_sys                  <= 3'd0;
            gad_attach_array_sys           <= 3'd0;
            gad_class_array_sys            <= 9'd0;
            gad_at_array_sys               <= 6'd0;
            gad_gssi_array_sys             <= 72'd0;
            gad_pending_giu_bits           <= 11'd0;
            gad_remaining_records          <= 6'd0;
            gad_idx                        <= 3'd0;
            lat_body_kind                  <= 1'b0;
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
                    lat_body_kind                <= body_kind_sys;
                    // Clear all output validity on a new parse cycle.
                    class_of_ms_valid_sys        <= 1'b0;
                    energy_saving_mode_valid_sys <= 1'b0;
                    la_information_valid_sys     <= 1'b0;
                    ssi_field_valid_sys          <= 1'b0;
                    address_ext_valid_sys        <= 1'b0;
                    gild_valid_sys               <= 1'b0;
                    gad_valid_sys                <= 1'b0;
                    gad_count_sys                <= 3'd0;
                    gad_attach_array_sys         <= 3'd0;
                    gad_class_array_sys          <= 9'd0;
                    gad_at_array_sys             <= 6'd0;
                    gad_gssi_array_sys           <= 72'd0;
                    gad_idx                      <= 3'd0;
                    if (body_kind_sys == 1'b1)
                        state <= S_GAD_HEADER_T1;
                    else
                        state <= S_HEADER_T1;
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
            // Phase 7 F.7.1 — U-ATTACH-DETACH-GROUP-IDENTITY walker.
            //
            // Body layout (129-bit reassembled body, mm_pdu_type stripped):
            //   bit[0]   group_identity_report
            //   bit[1]   attach_detach_mode  (0=amend, 1=replace-all)
            //   bit[2]   o-bit
            //   if obit:
            //     // Type-3/4 list with 3 expected elements:
            //     //   group_report_response  (id=4)
            //     //   group_identity_uplink  (id=8) ← we consume this
            //     //   proprietary            (id=15)
            //     // Encoder writes nothing for absent elements.  Walker
            //     // peeks m-bit + id; if matches expected, consume; else
            //     // skip (cursor unchanged, fall to next field).
            //   trailing m-bit (= 0)
            //
            // Within Group-Identity-Uplink length prefix (length(11)) sits
            // a 6-bit num_elem followed by num_elem record blocks.  We
            // expose up to 3 records; further records advance the cursor
            // but do not populate output slots.
            // -----------------------------------------------------------------
            S_GAD_HEADER_T1: begin
                if (cursor >= 8'd2) begin
                    // [128] group_identity_report (currently unused on
                    // the FSM side — exposed via gad_count_sys==0 + obit
                    // as the "report-only" indication when needed).
                    // [127] attach_detach_mode
                    gad_attach_detach_mode_sys <= body_buf[cursor - 8'd2];
                    cursor                     <= cursor - 8'd2;
                    state                      <= S_GAD_OBIT;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_GAD_OBIT: begin
                if (cursor == 8'd0) begin
                    // No optional fields → mark valid only when we already
                    // captured at least one GIU record (here: never).
                    state <= S_DONE;
                end else if (peek1 == 1'b0) begin
                    // obit=0 → done, no GIU.  Trailing m-bit not required
                    // per bluestation early-return.
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
                end else begin
                    cursor <= cursor - 8'd1;
                    state  <= S_GAD_T34_M;
                end
            end

            // -----------------------------------------------------------------
            // S_GAD_T34_M: PEEK m-bit + 4-bit id.  We only consume when
            // the next field is GroupIdentityUplink (id=8).  All other id's
            // (GroupReportResponse=4, Proprietary=15) get skipped via the
            // length-prefix in S_GAD_T34_HEADER.
            // -----------------------------------------------------------------
            S_GAD_T34_M: begin
                if (cursor == 8'd0) begin
                    // Out of bits without trailing m-bit terminator.
                    state <= S_DONE_FAIL;
                end else if (peek1 == 1'b0) begin
                    // Trailing m-bit terminator reached.  Mark valid if
                    // we collected at least one GIU record.
                    cursor          <= cursor - 8'd1;
                    if (gad_count_sys != 3'd0)
                        gad_valid_sys <= 1'b1;
                    state           <= S_DONE;
                end else if (cursor >= 8'd16) begin
                    // m=1 → read id(4) + length(11) into staging.
                    cur_elem_id  <= body_buf[cursor - 8'd2 -: 4];
                    cur_elem_len <= body_buf[cursor - 8'd6 -: 11];
                    cursor       <= cursor - 8'd16;
                    state        <= S_GAD_T34_HEADER;
                end else begin
                    state <= S_DONE_FAIL;
                end
            end

            // -----------------------------------------------------------------
            S_GAD_T34_HEADER: begin
                if ({1'b0, cursor} < {2'b00, cur_elem_len[7:0]}) begin
                    state <= S_DONE_FAIL;
                end else if (cur_elem_id == 4'd8) begin
                    // GroupIdentityUplink — consume num_elem(6) up front,
                    // then walk records.  cur_elem_len already counts
                    // num_elem(6) + records.
                    if (cur_elem_len < 11'd6) begin
                        // Malformed — at least num_elem must fit.
                        state <= S_DONE_FAIL;
                    end else if (cursor < 8'd6) begin
                        state <= S_DONE_FAIL;
                    end else begin
                        gad_remaining_records <= body_buf[cursor - 8'd1 -: 6];
                        gad_pending_giu_bits  <= cur_elem_len - 11'd6;
                        cursor                <= cursor - 8'd6;
                        state                 <= S_GAD_GIU_LIST;
                    end
                end else begin
                    // Skip unknown id's wholesale.
                    cursor <= cursor - cur_elem_len[7:0];
                    state  <= S_GAD_T34_M;
                end
            end

            // -----------------------------------------------------------------
            // S_GAD_GIU_LIST — walk one GIU record per cycle.  Each record
            // is variable-width:
            //   attach_detach_type_id(1)
            //   if attach: class_of_usage(3)
            //   if detach: gid_detachment_uplink(2)
            //   address_type(2)
            //   if at∈{0,1}: gssi(24)
            //   if at == 1:  address_extension(24)  ← we skip the AE bits
            //                                          but still record gssi
            //   if at == 2:  vgssi(24)
            // For F.7.1 scope each record is at most 1+3+2+24+24 = 54 bits
            // (attach + GSSI+AE) and at least 1+3+2+24 = 30 bits (attach +
            // GSSI only).  Detach + GSSI = 1+2+2+24 = 29 bits.
            //
            // We commit decoded fields into the next free output slot
            // (gad_idx); when gad_idx hits 3 we still walk the cursor but
            // stop populating outputs (multi-IE bodies beyond 3 records
            // are extremely rare, and the AST.group_list slot count is 8).
            // -----------------------------------------------------------------
            S_GAD_GIU_LIST: begin : gad_giu_walk
                reg        adi;
                reg [2:0]  cou;
                reg [1:0]  detach;
                reg [1:0]  at;
                reg [23:0] gssi;
                reg [7:0]  consumed;
                adi    = 1'b0;
                cou    = 3'd0;
                detach = 2'd0;
                at     = 2'd0;
                gssi   = 24'd0;
                consumed = 8'd0;
                if (gad_remaining_records == 6'd0) begin
                    // Done with GIU list — fall back to the m-bit loop
                    // (skip remaining peer-elements / proprietary).
                    state <= S_GAD_T34_M;
                end else if (cursor < 8'd29) begin
                    // Not enough bits for the smallest record.
                    state <= S_DONE_FAIL;
                end else begin
                    adi = body_buf[cursor - 8'd1];
                    if (adi == 1'b0) begin
                        // attach: class_of_usage(3) + addr_type(2) + gssi(24)
                        cou = body_buf[cursor - 8'd2 -: 3];
                        at  = body_buf[cursor - 8'd5 -: 2];
                    end else begin
                        // detach: gid_detachment_uplink(2) + addr_type(2) + gssi(24)
                        detach = body_buf[cursor - 8'd2 -: 2];
                        at     = body_buf[cursor - 8'd4 -: 2];
                    end
                    if (at == 2'b00) begin
                        // GSSI only.
                        if (adi == 1'b0) begin
                            gssi     = body_buf[cursor - 8'd7 -: 24];
                            consumed = 8'd30;
                        end else begin
                            gssi     = body_buf[cursor - 8'd6 -: 24];
                            consumed = 8'd29;
                        end
                    end else if (at == 2'b01) begin
                        // GSSI + AE.
                        if (adi == 1'b0) begin
                            if (cursor < 8'd54) begin
                                state <= S_DONE_FAIL;
                            end
                            gssi     = body_buf[cursor - 8'd7 -: 24];
                            consumed = 8'd54;
                        end else begin
                            if (cursor < 8'd53) begin
                                state <= S_DONE_FAIL;
                            end
                            gssi     = body_buf[cursor - 8'd6 -: 24];
                            consumed = 8'd53;
                        end
                    end else if (at == 2'b10) begin
                        // VGSSI only.
                        if (adi == 1'b0) begin
                            gssi     = body_buf[cursor - 8'd7 -: 24];
                            consumed = 8'd30;
                        end else begin
                            gssi     = body_buf[cursor - 8'd6 -: 24];
                            consumed = 8'd29;
                        end
                    end else begin
                        // Reserved address_type — bail out.
                        state <= S_DONE_FAIL;
                    end

                    if (state != S_DONE_FAIL) begin
                        // Populate output slot if there's room.
                        case (gad_idx)
                            3'd0: begin
                                gad_attach_array_sys[0]            <= adi;
                                gad_class_array_sys[2:0]           <= (adi == 1'b0) ? cou : {1'b0, detach};
                                gad_at_array_sys[1:0]              <= at;
                                gad_gssi_array_sys[23:0]           <= gssi;
                                gad_count_sys                      <= 3'd1;
                            end
                            3'd1: begin
                                gad_attach_array_sys[1]            <= adi;
                                gad_class_array_sys[5:3]           <= (adi == 1'b0) ? cou : {1'b0, detach};
                                gad_at_array_sys[3:2]              <= at;
                                gad_gssi_array_sys[47:24]          <= gssi;
                                gad_count_sys                      <= 3'd2;
                            end
                            3'd2: begin
                                gad_attach_array_sys[2]            <= adi;
                                gad_class_array_sys[8:6]           <= (adi == 1'b0) ? cou : {1'b0, detach};
                                gad_at_array_sys[5:4]              <= at;
                                gad_gssi_array_sys[71:48]          <= gssi;
                                gad_count_sys                      <= 3'd3;
                            end
                            default: ;   // gad_idx >= 3, no slot left
                        endcase
                        if (gad_idx != 3'd7) gad_idx <= gad_idx + 3'd1;

                        // Advance cursor + remaining counts.
                        cursor                <= cursor - consumed;
                        gad_remaining_records <= gad_remaining_records - 6'd1;
                        if (gad_pending_giu_bits >= {3'd0, consumed})
                            gad_pending_giu_bits <= gad_pending_giu_bits - {3'd0, consumed};
                        else
                            gad_pending_giu_bits <= 11'd0;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_GAD_TRAILING_M: begin
                if (cursor == 8'd0) begin
                    state <= S_DONE;
                end else begin
                    cursor <= cursor - 8'd1;
                    state  <= S_DONE;
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
