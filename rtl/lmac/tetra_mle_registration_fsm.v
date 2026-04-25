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
//   3. Emit the short addressed pre-reply as SCH/HD:
//        MAC-RESOURCE + slot-granting + LLC AL-SETUP.
//   4. Emit the full D-LOCATION-UPDATE-ACCEPT as SCH/F:
//        MAC-RESOURCE + LLC BL-ADATA + MLE/MM.
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
// The reference BS drives the full accept as BL-ADATA NR=0 NS=0 and the
// short pre-reply as AL-SETUP with slot-granting=0.  The registration FSM
// therefore emits two separate queue requests per accepted UL demand.
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
    // Uplink request from UL MAC-ACCESS parser (1-cycle pulse).
    //   ul_addr_type[1:0] : MAC-ACCESS addr_type (0=Ssi/ISSI, 1=EventLabel,
    //                       2=Ussi, 3=Smi) — bluestation
    //                       `mac_access.rs::AddressType`.
    //   ul_ssi[23:0]      : full 24-bit address when addr_type ∈ {0,2,3}.
    //                       For EventLabel the lower 10 bits hold the label.
    // -----------------------------------------------------------------
    input  wire                        ul_req_valid,
    input  wire [1:0]                  ul_addr_type,
    input  wire [23:0]                 ul_ssi,
    input  wire [13:0]                 ul_la,
    // Location update type from MS's U-LOC-UPDATE-DEMAND (ETSI §16.10.37);
    // echoed back as the D-LOC-UPDATE-ACCEPT's Location-update-accept-type
    // field so the MS's state machine recognises the response.
    input  wire [2:0]                  ul_loc_upd_type,
    // Reserved compatibility input from the current UL parser.  The external
    // gold reference drives registration replies through the Basic-Link path
    // regardless of the UL wrapper, so the FSM ignores this for now.
    input  wire                        ul_use_l2sig,

    // Reserved compatibility inputs from the current UL parser.  The
    // BlueStation-like registration path no longer appends a concat BL-ACK
    // in this FSM; it emits the short AL-SETUP pre-reply followed by the
    // full BL-ADATA accept as two separate PDUs.
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
    input  wire [23:0]                 bl_ack_issi,
    input  wire                        slot_pulse,

    // -----------------------------------------------------------------
    // Cell configuration (static, from AXI regs)
    // -----------------------------------------------------------------
    input  wire [13:0]                 cfg_la,
    input  wire [31:0]                 cfg_scramble_init,
    input  wire [1:0]                  cfg_mcch_tn,       // target_tn for the queue req
    // Address-Extension (MNI) for the D-LOC-UPDATE-ACCEPT MM body.
    // Bluestation packs MNI = MCC[9:0]<<14 | MNC[13:0] (24 bit total).
    input  wire [23:0]                 cfg_address_extension,
    // Subscriber class default for the MM body (16 bit, broadcast value).
    input  wire [15:0]                 cfg_subscriber_class,
    // Energy-Saving-Information field (14 bit: 3 bit ESM + 5 bit FN + 6 bit MN).
    // Default StayAlive = 14'h0000.
    input  wire [13:0]                 cfg_energy_saving_info,

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
    // Legacy telemetry, kept wired for downstream debug compatibility.
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
    reg                         lat_use_l2sig;
    reg [AST_IDX_WIDTH-1:0]     lat_slot;
    reg                         lat_existing;
    reg [267:0]                 lat_accept_info_bits;
    reg [123:0]                 lat_short_info_bits;

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE builder — combinational, always watching the latched
    // request fields.  Produces the raw 108-bit MM PDU (MSB-aligned in 128-bit
    // bus) that the MAC-RESOURCE builder wraps.  Always emits all 3 type-2
    // optional fields (Address-Extension, Subscriber-Class, Energy-Saving-Info)
    // plus a zero-length Security-Downlink type-3 header so the full Accept
    // lands at the external-reference LI=21 sizing.
    // -------------------------------------------------------------------------
    wire [127:0] dloc_mm_bits_w;
    wire [7:0]   dloc_mm_len_w;
    wire [123:0] dloc_legacy_pdu_w;  // unused here, kept for linter silence

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject        (1'b0),                 // MVP: accept only
        .addr_type         (lat_addr_type),
        .ssi               (lat_ssi),
        .la                (cfg_la),               // legacy 124-bit path
        .result            (2'b00),                // accept
        .encryption        (2'b00),                // clear
        .auth_result       (2'b01),                // success
        .subscriber_class  (cfg_subscriber_class),
        .address_extension (cfg_address_extension),
        .energy_saving_info(cfg_energy_saving_info),
        .loc_acc_type      (lat_loc_upd_type),     // echo MS demand type
        .pdu_bits          (dloc_legacy_pdu_w),
        .pdu_bits_mm       (dloc_mm_bits_w),
        .pdu_len_bits      (dloc_mm_len_w)
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
    // MAC-RESOURCE DL builders:
    //   - short pre-reply: SCH/HD, MAC-RESOURCE + slot-grant + LLC AL-SETUP
    //   - full accept:     SCH/F, MAC-RESOURCE + slot-grant + LLC BL-ADATA + MLE/MM
    // -------------------------------------------------------------------------
    reg          short_builder_start;
    reg          accept_builder_start;
    wire [123:0] short_builder_pdu_bits_w;
    wire         short_builder_valid_w;
    wire [267:0] accept_builder_pdu_bits_w;
    wire         accept_builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(124),
        // Short builder fits in 124 bits; override the default 144-bit LLC
        // buffer so the (PDU_BITS - LLC_BUF_BITS) repeat stays non-negative.
        // No MM body in the short pre-reply — 96 bit is plenty for AL-SETUP
        // (4 bit) + slot-grant element (8 bit).
        .LLC_BUF_BITS(96)
    ) u_short_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (short_builder_start),
        .ssi               (lat_ssi),
        .addr_type         (lat_addr_type),
        .ns                (1'b0),
        .nr                (1'b0),                 // TODO: from AST record
        .llc_pdu_type      (4'd8),                 // AL-SETUP
        .random_access_flag(1'b1),
        .power_control_flag       (1'b0),
        .power_control_element    (4'd0),
        .slot_granting_flag       (1'b1),
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
        .mm_pdu_bits       (128'd0),
        .mm_pdu_len_bits   (8'd0),
        .pdu_bits          (short_builder_pdu_bits_w),
        .valid             (short_builder_valid_w)
    );

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268)
    ) u_accept_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (accept_builder_start),
        .ssi               (lat_ssi),
        .addr_type         (lat_addr_type),
        .ns                (1'b0),
        .nr                (1'b0),
        .llc_pdu_type      (4'd0),                 // BL-ADATA
        .random_access_flag(1'b1),
        .power_control_flag       (1'b0),
        .power_control_element    (4'd0),
        .slot_granting_flag       (1'b1),
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
        .pdu_bits          (accept_builder_pdu_bits_w),
        .valid             (accept_builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // SCH/F channel encoder — 268 info bits → 432 type-5 coded bits.
    // Pulsed at S_ENCODE_START after the builder latches a complete PDU.
    // -------------------------------------------------------------------------
    reg          sch_encode_start;
    wire [431:0] sch_coded_bits_w;
    wire         sch_coded_valid_w;

    tetra_sch_f_encoder u_sch_f (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (sch_encode_start),
        .info_bits    (lat_accept_info_bits),
        .scramble_init(cfg_scramble_init),
        .coded_bits   (sch_coded_bits_w),
        .coded_valid  (sch_coded_valid_w)
    );

    reg          sch_hd_encode_start;
    wire [215:0] sch_hd_coded_bits_w;
    wire         sch_hd_coded_valid_w;

    tetra_sch_hd_encoder u_sch_hd (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (sch_hd_encode_start),
        .info_bits    (lat_short_info_bits),
        .scramble_init(cfg_scramble_init),
        .coded_bits   (sch_hd_coded_bits_w),
        .coded_valid  (sch_hd_coded_valid_w)
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
    localparam [3:0] S_IDLE                = 4'd0;
    localparam [3:0] S_CHECK_START         = 4'd1;
    localparam [3:0] S_CHECK_WAIT          = 4'd2;
    localparam [3:0] S_ALLOC_START         = 4'd3;
    localparam [3:0] S_ALLOC_WAIT          = 4'd4;
    localparam [3:0] S_WRITE               = 4'd5;
    localparam [3:0] S_BUILD_SHORT_START   = 4'd6;
    localparam [3:0] S_BUILD_SHORT_WAIT    = 4'd7;
    localparam [3:0] S_ENCODE_HD_START     = 4'd8;
    localparam [3:0] S_ENCODE_HD_WAIT      = 4'd9;
    localparam [4:0] S_BUILD_ACCEPT_START  = 5'd10;
    localparam [4:0] S_BUILD_ACCEPT_WAIT   = 5'd11;
    localparam [4:0] S_ENCODE_F_START      = 5'd12;
    localparam [4:0] S_ENCODE_F_WAIT       = 5'd13;
    localparam [4:0] S_DELIVER_ACCEPT      = 5'd14;
    localparam [4:0] S_DROP                = 5'd15;
    localparam [4:0] S_WAIT_GAP_FRAME      = 5'd16;
    reg [4:0] state;
    reg [2:0] gap_slot_count;

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
            lat_use_l2sig     <= 1'b0;
            lat_slot          <= {AST_IDX_WIDTH{1'b0}};
            lat_existing      <= 1'b0;
            lat_accept_info_bits <= 268'd0;
            lat_short_info_bits  <= 124'd0;
            gap_slot_count    <= 3'd0;
            ast_wr_en         <= 1'b0;
            ast_wr_idx        <= {AST_IDX_WIDTH{1'b0}};
            ast_wr_data       <= {AST_REC_WIDTH{1'b0}};
            ast_q_start       <= 1'b0;
            ast_q_mode        <= 1'b0;
            ast_q_issi        <= 24'd0;
            short_builder_start  <= 1'b0;
            accept_builder_start <= 1'b0;
            sch_encode_start  <= 1'b0;
            sch_hd_encode_start <= 1'b0;
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
            short_builder_start  <= 1'b0;
            accept_builder_start <= 1'b0;
            sch_encode_start <= 1'b0;
            sch_hd_encode_start <= 1'b0;
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
                    lat_use_l2sig    <= ul_use_l2sig;
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
                state       <= S_BUILD_SHORT_START;
            end

            // -----------------------------------------------------------------
            S_BUILD_SHORT_START: begin
                short_builder_start <= 1'b1;
                state               <= S_BUILD_SHORT_WAIT;
            end

            // -----------------------------------------------------------------
            S_BUILD_SHORT_WAIT: begin
                if (short_builder_valid_w) begin
                    lat_short_info_bits <= short_builder_pdu_bits_w;
                    state               <= S_ENCODE_HD_START;
                end
            end

            // -----------------------------------------------------------------
            S_ENCODE_HD_START: begin
                sch_hd_encode_start <= 1'b1;
                state               <= S_ENCODE_HD_WAIT;
            end

            // -----------------------------------------------------------------
            S_ENCODE_HD_WAIT: begin
                if (sch_hd_coded_valid_w) begin
                    req_coded_bits[431:216] <= sch_hd_coded_bits_w;
                    req_coded_bits[215:0]   <= 216'd0;
                    req_pdu_type   <= 2'd1;                // SCH_HD
                    req_target_tn  <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    req_valid      <= 1'b1;
                    gap_slot_count <= 3'd4;
                    state          <= S_WAIT_GAP_FRAME;
                end
            end

            // -----------------------------------------------------------------
            // Match the external BS spacing: the short SCH/HD pre-reply appears
            // on TN1/FN=N, the full SCH/F accept two frames later on TN1/FN=N+2.
            // The scheduler pops at most one signalling PDU per frame, so hold
            // the accept back for one full TDMA frame (4 slot pulses) after the
            // pre-reply request has been queued.
            S_WAIT_GAP_FRAME: begin
                if (slot_pulse) begin
                    if (gap_slot_count == 3'd1)
                        state <= S_BUILD_ACCEPT_START;
                    else
                        gap_slot_count <= gap_slot_count - 3'd1;
                end
            end

            // -----------------------------------------------------------------
            S_BUILD_ACCEPT_START: begin
                accept_builder_start <= 1'b1;
                state                <= S_BUILD_ACCEPT_WAIT;
            end

            // -----------------------------------------------------------------
            S_BUILD_ACCEPT_WAIT: begin
                if (accept_builder_valid_w) begin
                    lat_accept_info_bits <= accept_builder_pdu_bits_w;
                    state                <= S_ENCODE_F_START;
                end
            end

            // -----------------------------------------------------------------
            S_ENCODE_F_START: begin
                sch_encode_start <= 1'b1;
                state            <= S_ENCODE_F_WAIT;
            end

            // -----------------------------------------------------------------
            S_ENCODE_F_WAIT: begin
                if (sch_coded_valid_w) begin
                    req_coded_bits <= sch_coded_bits_w;
                    req_pdu_type   <= 2'd0;                // SCH_F
                    req_target_tn  <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    state          <= S_DELIVER_ACCEPT;
                end
            end

            // -----------------------------------------------------------------
            S_DELIVER_ACCEPT: begin
                req_valid        <= 1'b1;
                accept_pulse     <= 1'b1;
                state            <= S_IDLE;
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
