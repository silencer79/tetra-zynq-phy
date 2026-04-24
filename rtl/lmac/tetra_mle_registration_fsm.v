// =============================================================================
// tetra_mle_registration_fsm.v
//
// MLE registration engine — takes an uplink "location update request"
// (ISSI + LA from the UL MAC-ACCESS parser) and drives the four-step
// downlink response flow:
//
//   1. Query the active-session-table for an existing record on this ISSI.
//      - hit  → reuse slot (MS is re-registering)
//      - miss → alloc mode scan, pick the first free slot
//   2. Write the session record back into the table marked REG_ACCEPT_SENT.
//   3. Build the MAC-RESOURCE DL PDU (268 type-1 info bits) around the raw
//      MM D-LOCATION-UPDATE-ACCEPT bits via tetra_mac_resource_dl_builder.
//   4. Run the 268-bit MAC-RESOURCE PDU through tetra_sch_f_encoder
//      (CRC+RCPC+interleave+scramble) and split the 432-bit SCH/F output
//      into two 216-bit halves (BKN1/BKN2) for the DL slot multiplexer.
//
// The D-LOCATION-UPDATE encoder, MAC-RESOURCE builder, and SCH/F encoder
// are all instantiated inside this module.  The FSM owns the active-
// session-table ports exclusively for MVP — an arbiter can be wrapped
// around it later when a second MLE/CMCE FSM needs the same resource.
//
// Table-full behaviour: alloc miss just drops the request (no REJECT PDU on
// the MVP path — the MS will retry).  Wire a REJECT encode branch in as
// soon as we have a capacity-exhausted scenario worth handling.
//
// N(S)/N(R) sequencing — TODO: the active-session-table record currently
// has no dedicated N(S)/N(R) field, so the builder gets {ns,nr} = {0,0}
// for every request.  This is correct for first transactions (which is
// all we handle today); sticking NS=0/NR=0 on re-registrations is still
// protocol-acceptable because the MS treats D-LOC-UPDATE-ACCEPT as
// unacknowledged downlink signalling.  Widen ast_wr_data / ast_q_record
// to carry per-MS NS/NR when we add an upper-layer call-setup flow.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_mle_registration_fsm #(
    parameter integer AST_IDX_WIDTH = 6,
    parameter integer AST_REC_WIDTH = 64
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // -----------------------------------------------------------------
    // Uplink request from UL MAC-ACCESS parser (1-cycle pulse)
    // -----------------------------------------------------------------
    input  wire                        ul_req_valid,
    input  wire [2:0]                  ul_addr_type,
    input  wire [23:0]                 ul_ssi,
    input  wire [13:0]                 ul_la,
    // Location update type from MS's U-LOC-UPDATE-DEMAND (ETSI §16.10.37);
    // echoed back as the D-LOC-UPDATE-ACCEPT's Location-update-accept-type
    // field so the MS's state machine recognises the response.
    input  wire [2:0]                  ul_loc_upd_type,

    // -----------------------------------------------------------------
    // Option B auto-BL-ACK (commit 3, 2026-04-24).  When the incoming
    // MAC-ACCESS carries BL-DATA/BL-ADATA (ul_llc_is_bl_data=1 and
    // ul_llc_ns_valid=1), we schedule an auto-ACK alongside the Accept
    // in the same SCH/F slot.  The BL-ACK's N(R) mirrors the MS's N(S)
    // (bluestation llc_bs_ms.rs:488-493 schedule_outgoing_ack).  When
    // the flags are 0 (or the input is unconnected) the FSM falls back
    // to single-PDU emission.
    // -----------------------------------------------------------------
    input  wire                        ul_llc_is_bl_data,
    input  wire                        ul_llc_ns_valid,
    input  wire                        ul_llc_ns,

    // -----------------------------------------------------------------
    // UL LLC BL-ACK / slot-pulse are kept on the interface for compatibility
    // with the existing top-level wiring, but the registration path no longer
    // waits for an MS-side ack after delivering the Accept.  BlueStation-like
    // behavior for this flow is "UL BL-DATA(ns) -> DL Accept (+ piggybacked
    // BL-ACK for the UL request) -> done".
    // -----------------------------------------------------------------
    input  wire                        bl_ack_valid,
    input  wire                        bl_ack_nr,
    input  wire [9:0]                  bl_ack_short_ssi,
    input  wire                        slot_pulse,

    // -----------------------------------------------------------------
    // Cell configuration (static, from AXI regs)
    // -----------------------------------------------------------------
    input  wire [13:0]                 cfg_la,
    input  wire [31:0]                 cfg_scramble_init,
    input  wire [1:0]                  cfg_mcch_tn,       // target_tn for the queue req

    // -----------------------------------------------------------------
    // Active-session table port — this FSM owns it for MVP
    // -----------------------------------------------------------------
    output reg                         ast_wr_en,
    output reg  [AST_IDX_WIDTH-1:0]    ast_wr_idx,
    output reg  [AST_REC_WIDTH-1:0]    ast_wr_data,
    output reg                         ast_q_start,
    output reg                         ast_q_mode,     // 0=query, 1=alloc
    output reg  [23:0]                 ast_q_issi,
    input  wire                        ast_q_busy,
    input  wire                        ast_q_done,
    input  wire                        ast_q_hit,
    input  wire [AST_IDX_WIDTH-1:0]    ast_q_slot,
    input  wire [AST_REC_WIDTH-1:0]    ast_q_record,

    // -----------------------------------------------------------------
    // DL signalling-queue request — 1-cycle pulse carrying the full 432-bit
    // SCH/F coded PDU plus type/target metadata.  The queue assembles it
    // into an entry; a downstream scheduler decides when it goes on air.
    // -----------------------------------------------------------------
    output reg                         req_valid,
    output reg  [431:0]                req_coded_bits,
    output reg  [1:0]                  req_pdu_type,    // 00=SCH_F
    output reg  [1:0]                  req_target_tn,   // mirrors cfg_mcch_tn
    // Option B telemetry (commit 6) — present when the delivered SCH/F
    // block contains a concatenated BL-ACK.  Fed into the queue's
    // wr_mle_second_pdu_* ports for downstream ILA / AXI visibility.
    output reg                         req_second_pdu_present,
    output reg                         req_second_pdu_nr,

    // -----------------------------------------------------------------
    // Debug / status
    // -----------------------------------------------------------------
    output reg                         busy,
    output reg                         accept_pulse,   // 1 cyc on ACCEPT built
    output reg                         drop_pulse,     // 1 cyc on table-full
    output reg                         ack_pulse,      // 1 cyc on matching BL-ACK
    output reg                         retransmit_pulse, // 1 cyc per retransmit
    output reg                         lost_pulse      // 1 cyc on N252 exhaust
);

    // -------------------------------------------------------------------------
    // Latched UL request
    // -------------------------------------------------------------------------
    reg [2:0]                   lat_addr_type;
    reg [23:0]                  lat_ssi;
    reg [13:0]                  lat_la;
    reg [2:0]                   lat_loc_upd_type;
    reg [AST_IDX_WIDTH-1:0]     lat_slot;
    reg                         lat_existing;
    reg [267:0]                 lat_info_bits;       // builder→encoder handoff
    // MS-provided LLC N(S) latched from the UL parser for auto-BL-ACK.
    reg                         lat_ms_bl_data;
    reg                         lat_ms_ns;

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE builder — combinational, always watching the latched
    // request fields.  Produces the raw 54-bit MM PDU (MSB-aligned in 80-bit
    // bus) that the MAC-RESOURCE builder wraps.
    // -------------------------------------------------------------------------
    wire [79:0] dloc_mm_bits_w;
    wire [6:0]  dloc_mm_len_w;
    wire [123:0] dloc_legacy_pdu_w;  // unused here, kept for linter silence

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject      (1'b0),                 // MVP: accept only
        .addr_type       (lat_addr_type),
        .ssi             (lat_ssi),
        .la              (cfg_la),               // echo our cell LA
        .result          (2'b00),                // accept
        .encryption      (2'b00),                // clear
        .auth_result     (2'b01),                // success
        .subscriber_class(16'h0000),             // MVP: placeholder
        .loc_acc_type    (lat_loc_upd_type),     // echo MS demand type
        .pdu_bits        (dloc_legacy_pdu_w),
        .pdu_bits_mm     (dloc_mm_bits_w),
        .pdu_len_bits    (dloc_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // BasicSlotgrant + ChanAllocElement encoders — structurally wired in
    // ahead of Phase-6 call-setup / paging callers.  For D-LOC-UPDATE-ACCEPT
    // all three MAC-RESOURCE flag inputs on the builder are tied 0 so the
    // builder skips the optional elements regardless of what these encoders
    // output.  Both encoders are pure combinational — they synthesise to
    // constant zeros here (all-zero inputs propagate through).
    //
    // Phase-6 callers will replace these zero stimuli with real semantic
    // values (capacity_allocation, granting_delay, carrier_num, ...) and
    // flip the corresponding *_flag on the builder interface — no further
    // rewiring needed.
    // -------------------------------------------------------------------------
    wire [7:0]  slot_grant_packed_w;
    tetra_basic_slotgrant_encoder u_slotgrant (
        .capacity_allocation (4'd0),
        .granting_delay      (4'd0),
        .packed_element      (slot_grant_packed_w)
    );

    wire [31:0] chan_alloc_packed_w;
    wire [4:0]  chan_alloc_len_w;
    tetra_chan_alloc_encoder u_chanalloc (
        .alloc_type          (2'd0),
        .ts_assigned         (4'd0),
        .ul_dl_assigned      (2'd0),
        .clch_permission     (1'b0),
        .cell_change_flag    (1'b0),
        .carrier_num         (12'd0),
        .mon_pattern         (2'd3),   // non-zero → 25-bit form, matches
                                       // bluestation "replace_lab" default
        .frame18_mon_pattern (2'd0),
        .packed_element      (chan_alloc_packed_w),
        .element_len         (chan_alloc_len_w)
    );

    // -------------------------------------------------------------------------
    // MAC-RESOURCE DL builders — one for the Accept BL-DATA, one for the
    // separate BL-ACK resource.  BlueStation models these as two distinct
    // MacResources; the registration FSM mirrors that by issuing two queue
    // requests when the UL request arrived in acknowledged LLC mode.
    // -------------------------------------------------------------------------
    reg          builder_start;
    wire [267:0] builder_pdu_bits_w;
    wire         builder_valid_w;
    reg          ack_builder_start;
    wire [267:0] ack_builder_pdu_bits_w;
    wire         ack_builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268)
    ) u_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (builder_start),
        .ssi               (lat_ssi),
        .addr_type         (lat_addr_type),
        .ns                (1'b0),
        .nr                (1'b0),                 // TODO: from AST record
        // D-LOC-UPDATE-ACCEPT is the canonical response to a successful
        // UL Random Access (MAC-ACCESS → MLE → MM demand).  Setting the
        // MAC-RESOURCE RandAccFlag acknowledges the MS's RA and stops
        // it from retrying (ETSI §21.4.3.1, bluestation umac_bs.rs:1176
        // analogous path).  This FSM is exclusively triggered from the
        // UL MAC-ACCESS parser, so hard-1 is correct here.
        .random_access_flag(1'b1),
        // D-LOC-UPDATE-ACCEPT carries no resource grant, so all three
        // optional MAC-RESOURCE elements are absent.  Bluestation-equivalent:
        // MacResource { power_control_element: None, slot_granting_element: None,
        //               chan_alloc_element: None, .. } in
        // crates/tetra-pdus/src/umac/pdus/mac_resource.rs.  Phase-6 CMCE /
        // call-setup callsites will set these to actual values.
        .power_control_flag       (1'b0),
        .power_control_element    (4'd0),
        // Flag=0 → builder skips the element.  Outputs of u_slotgrant /
        // u_chanalloc are wired in so Phase-6 callers can flip the flag
        // without further structural changes.
        .slot_granting_flag       (1'b0),
        .slot_granting_element    (slot_grant_packed_w),
        .chan_alloc_flag          (1'b0),
        .chan_alloc_element       (chan_alloc_packed_w),
        .chan_alloc_element_len   (chan_alloc_len_w),
        .second_pdu_valid              (1'b0),
        .second_pdu_length_ind         (6'd0),
        .second_pdu_random_access_flag (1'b0),
        .second_pdu_addr_type          (3'd0),
        .second_pdu_ssi                (24'd0),
        .second_pdu_tl_sdu             (80'd0),
        .second_pdu_tl_sdu_len         (7'd0),
        .second_pdu_pc_flag            (1'b0),
        .second_pdu_pc_element         (4'd0),
        .second_pdu_sg_flag            (1'b0),
        .second_pdu_sg_element         (8'd0),
        .second_pdu_ca_flag            (1'b0),
        .second_pdu_ca_element         (32'd0),
        .second_pdu_ca_element_len     (5'd0),
        .mm_pdu_bits       (dloc_mm_bits_w),
        .mm_pdu_len_bits   (dloc_mm_len_w),
        .pdu_bits          (builder_pdu_bits_w),
        .valid             (builder_valid_w)
    );

    tetra_mac_resource_bl_ack_builder #(
        .PDU_BITS(268)
    ) u_bl_ack_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (ack_builder_start),
        .ssi               (lat_ssi),
        .addr_type         (3'd1),
        .random_access_flag(1'b1),
        .nr                (lat_ms_ns),
        .pdu_bits          (ack_builder_pdu_bits_w),
        .valid             (ack_builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // SCH/F channel encoder — 268 info bits → 432 type-5 coded bits.
    // Pulsed at S_ENCODE_START after the builder latches a complete PDU.
    // -------------------------------------------------------------------------
    reg          sch_encode_start;
    wire [431:0] sch_coded_bits_w;
    wire         sch_coded_valid_w;
    reg          ack_sch_encode_start;
    reg [267:0]  lat_ack_info_bits;
    wire [431:0] ack_sch_coded_bits_w;
    wire         ack_sch_coded_valid_w;

    tetra_sch_f_encoder u_sch_f (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (sch_encode_start),
        .info_bits    (lat_info_bits),
        .scramble_init(cfg_scramble_init),
        .coded_bits   (sch_coded_bits_w),
        .coded_valid  (sch_coded_valid_w)
    );

    tetra_sch_f_encoder u_ack_sch_f (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (ack_sch_encode_start),
        .info_bits    (lat_ack_info_bits),
        .scramble_init(cfg_scramble_init),
        .coded_bits   (ack_sch_coded_bits_w),
        .coded_valid  (ack_sch_coded_valid_w)
    );

    // -------------------------------------------------------------------------
    // Session record packer — thin layout (see tetra_active_session_table.v)
    // [REC-1 -: 24]   ISSI            (visible to AST query scan)
    // [ 39:26]        LA
    // [ 25:22]        session state   (1=REG_ACCEPT_SENT)
    // [ 21:16]        slot
    // [ 15: 1]        reserved
    // [ 0]            valid           (visible to AST alloc scan)
    // -------------------------------------------------------------------------
    wire [AST_REC_WIDTH-1:0] session_record_w = {
        lat_ssi,                    // [63:40]
        lat_la,                     // [39:26]
        4'd1,                       // [25:22] state=REG_ACCEPT_SENT
        lat_slot,                   // [21:16]
        15'd0,                      // [15: 1] reserved
        1'b1                        // [0]     valid
    };

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE         = 4'd0;
    localparam [3:0] S_CHECK_START  = 4'd1;
    localparam [3:0] S_CHECK_WAIT   = 4'd2;
    localparam [3:0] S_ALLOC_START  = 4'd3;
    localparam [3:0] S_ALLOC_WAIT   = 4'd4;
    localparam [3:0] S_WRITE        = 4'd5;
    localparam [3:0] S_BUILD_START  = 4'd6;
    localparam [3:0] S_BUILD_WAIT   = 4'd7;
    localparam [3:0] S_ENCODE_START = 4'd8;
    localparam [3:0] S_ENCODE_WAIT  = 4'd9;
    localparam [3:0] S_DELIVER      = 4'd10;
    localparam [3:0] S_DROP         = 4'd11;
    localparam [3:0] S_ACK_BUILD_START  = 4'd12;
    localparam [3:0] S_ACK_BUILD_WAIT   = 4'd13;
    localparam [3:0] S_ACK_ENCODE_START = 4'd14;
    localparam [3:0] S_ACK_ENCODE_WAIT  = 4'd15;
    reg [3:0] state;

    // Synchronous reset — Xilinx DRC (REQP-1839) flags async resets on
    // registers feeding BRAM control pins (WEBWE, ADDRBWRADDR) as memory-
    // corruption hazards.  Keep the AST ports async-reset-free.
    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            lat_addr_type     <= 3'd0;
            lat_ssi           <= 24'd0;
            lat_la            <= 14'd0;
            lat_loc_upd_type  <= 3'd0;
            lat_slot          <= {AST_IDX_WIDTH{1'b0}};
            lat_existing      <= 1'b0;
            lat_info_bits     <= 268'd0;
            lat_ack_info_bits <= 268'd0;
            lat_ms_bl_data    <= 1'b0;
            lat_ms_ns         <= 1'b0;
            ast_wr_en         <= 1'b0;
            ast_wr_idx        <= {AST_IDX_WIDTH{1'b0}};
            ast_wr_data       <= {AST_REC_WIDTH{1'b0}};
            ast_q_start       <= 1'b0;
            ast_q_mode        <= 1'b0;
            ast_q_issi        <= 24'd0;
            builder_start     <= 1'b0;
            ack_builder_start <= 1'b0;
            sch_encode_start  <= 1'b0;
            ack_sch_encode_start <= 1'b0;
            req_valid         <= 1'b0;
            req_coded_bits    <= 432'd0;
            req_pdu_type      <= 2'd0;
            req_target_tn     <= 2'd0;
            req_second_pdu_present <= 1'b0;
            req_second_pdu_nr      <= 1'b0;
            busy              <= 1'b0;
            accept_pulse      <= 1'b0;
            drop_pulse        <= 1'b0;
            ack_pulse         <= 1'b0;
            retransmit_pulse  <= 1'b0;
            lost_pulse        <= 1'b0;
        end else begin
            // Default strobes — every state may override
            ast_wr_en        <= 1'b0;
            ast_q_start      <= 1'b0;
            builder_start    <= 1'b0;
            ack_builder_start<= 1'b0;
            sch_encode_start <= 1'b0;
            ack_sch_encode_start <= 1'b0;
            req_valid        <= 1'b0;
            accept_pulse     <= 1'b0;
            drop_pulse       <= 1'b0;
            ack_pulse        <= 1'b0;
            retransmit_pulse <= 1'b0;
            lost_pulse       <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (ul_req_valid) begin
                    // D-LOCATION UPDATE ACCEPT is always addressed per SSI
                    // (ETSI EN 300 392-2 §16.10.28).  ul_addr_type on the UL
                    // request carries the MS-picked MAC addressing (often
                    // Event Label = 2 for MAC-ACCESS), which is UL-only
                    // (MS→BS, transient).  Latching it here and reusing it
                    // in the DL ACCEPT wraps the PDU in the wrong address
                    // type — the MS won't recognise its own reply.  Force
                    // SSI (3'd1) for every registration accept.
                    lat_addr_type    <= 3'd1;
                    lat_ssi          <= ul_ssi;
                    lat_la           <= ul_la;
                    lat_loc_upd_type <= ul_loc_upd_type;
                    // Option B: latch MS N(S) for auto-BL-ACK alongside
                    // Accept (commit 3).  lat_ms_bl_data arms the second
                    // MAC-RESOURCE PDU in the builder.
                    lat_ms_bl_data   <= ul_llc_is_bl_data & ul_llc_ns_valid;
                    lat_ms_ns        <= ul_llc_ns;
                    busy             <= 1'b1;
                    state            <= S_CHECK_START;
                end
            end

            // -----------------------------------------------------------------
            S_CHECK_START: begin
                ast_q_start <= 1'b1;
                ast_q_mode  <= 1'b0;    // query existing
                ast_q_issi  <= lat_ssi;
                state       <= S_CHECK_WAIT;
            end

            // -----------------------------------------------------------------
            S_CHECK_WAIT: begin
                if (ast_q_done) begin
                    if (ast_q_hit) begin
                        // Existing session → reuse slot, skip alloc
                        lat_slot     <= ast_q_slot;
                        lat_existing <= 1'b1;
                        state        <= S_WRITE;
                    end else begin
                        lat_existing <= 1'b0;
                        state        <= S_ALLOC_START;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_ALLOC_START: begin
                ast_q_start <= 1'b1;
                ast_q_mode  <= 1'b1;    // alloc scan
                ast_q_issi  <= 24'd0;   // don't care in alloc mode
                state       <= S_ALLOC_WAIT;
            end

            // -----------------------------------------------------------------
            S_ALLOC_WAIT: begin
                if (ast_q_done) begin
                    if (ast_q_hit) begin
                        lat_slot <= ast_q_slot;
                        state    <= S_WRITE;
                    end else begin
                        // Table full — drop for MVP, no REJECT yet
                        state <= S_DROP;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_WRITE: begin
                ast_wr_en   <= 1'b1;
                ast_wr_idx  <= lat_slot;
                ast_wr_data <= session_record_w;
                state       <= S_BUILD_START;
            end

            // -----------------------------------------------------------------
            S_BUILD_START: begin
                builder_start <= 1'b1;
                state         <= S_BUILD_WAIT;
            end

            // -----------------------------------------------------------------
            S_BUILD_WAIT: begin
                if (builder_valid_w) begin
                    lat_info_bits <= builder_pdu_bits_w;
                    state         <= S_ENCODE_START;
                end
            end

            // -----------------------------------------------------------------
            S_ENCODE_START: begin
                sch_encode_start <= 1'b1;
                state            <= S_ENCODE_WAIT;
            end

            // -----------------------------------------------------------------
            S_ENCODE_WAIT: begin
                if (sch_coded_valid_w) begin
                    // SCH/F output [431] = first bit on air.  The full 432-bit
                    // coded block is handed to the DL-signalling queue as one
                    // request; the scheduler will split it into BKN1/BKN2 when
                    // it pops the entry.
                    req_coded_bits <= sch_coded_bits_w;
                    req_pdu_type   <= 2'd0;                // SCH_F
                    req_target_tn  <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    state          <= S_DELIVER;
                end
            end

            // -----------------------------------------------------------------
            S_DELIVER: begin
                req_valid        <= 1'b1;
                accept_pulse     <= 1'b1;
                if (lat_ms_bl_data)
                    state <= S_ACK_BUILD_START;
                else
                    state <= S_IDLE;
            end

            // -----------------------------------------------------------------
            // Build and queue a separate BL-ACK resource after the Accept.
            // This matches BlueStation's model of two distinct MacResources
            // instead of a single concatenated payload blob inside one queue
            // entry.
            // -----------------------------------------------------------------
            S_ACK_BUILD_START: begin
                ack_builder_start <= 1'b1;
                state             <= S_ACK_BUILD_WAIT;
            end

            S_ACK_BUILD_WAIT: begin
                if (ack_builder_valid_w) begin
                    lat_ack_info_bits <= ack_builder_pdu_bits_w;
                    state             <= S_ACK_ENCODE_START;
                end
            end

            S_ACK_ENCODE_START: begin
                ack_sch_encode_start <= 1'b1;
                state                <= S_ACK_ENCODE_WAIT;
            end

            S_ACK_ENCODE_WAIT: begin
                if (ack_sch_coded_valid_w) begin
                    req_coded_bits <= ack_sch_coded_bits_w;
                    req_pdu_type   <= 2'd0;
                    req_target_tn  <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    req_valid      <= 1'b1;
                    state          <= S_IDLE;
                end
            end

            // -----------------------------------------------------------------
            S_DROP: begin
                drop_pulse <= 1'b1;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
