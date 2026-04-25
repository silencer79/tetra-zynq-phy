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
    // Phase D-rev: AST record widened to 256 bit per §9.2 (group_list[8]).
    // Phase B kept it at 128.  Keep parameter so TB / older callers can
    // still drive 64-bit / 128-bit during transitional builds.
    parameter integer AST_REC_WIDTH = 256
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
    // EntityTable lookup port (Phase 6 D-rev — §9.2/§9.3 Multi-Lookup).
    // FSM scans the 256×64-bit BRAM for the incoming ISSI/GSSI before
    // accepting the registration.  Three lookup modes:
    //   match_type=1, default_gssi_scan=0 → strict (id, type) match
    //   match_type=0, default_gssi_scan=0 → id-only match (legacy path)
    //   default_gssi_scan=1               → first valid entity_type=1
    //
    // Record layout per rtl/lmac/tetra_entity_table.v:
    //   [63:40] entity_id  [39] entity_type  [38:35] profile_id
    //   [34:1]  reserved=0 [0]  valid
    // -----------------------------------------------------------------
    output reg                         entity_q_start,
    output reg  [23:0]                 entity_q_id,
    output reg                         entity_q_type,
    output reg                         entity_q_match_type,
    output reg                         entity_q_default_gssi_scan,
    output reg                         entity_q_alloc,
    input  wire                        entity_q_busy,
    input  wire                        entity_q_done,
    input  wire                        entity_q_hit,
    input  wire [7:0]                  entity_q_slot,
    input  wire [63:0]                 entity_q_record,

    // -----------------------------------------------------------------
    // ProfileTable read port (Phase 6 D-rev).
    //   profile_rd_idx → drive 3-bit Profile-Table slot index.
    //   profile_rd_data ← 32-bit profile record (read latency 1 cycle).
    // Record layout per rtl/lmac/tetra_profile_table.v:
    //   [31:24] max_call_duration  [23:16] hangtime  [15:12] priority
    //   [11:9]  gila_class         [8:7]   gila_lifetime
    //   [6:4]   reserved           [3]     permit_voice
    //   [2]     permit_data        [1]     permit_reg     [0] valid
    // -----------------------------------------------------------------
    output reg  [2:0]                  profile_rd_idx,
    input  wire [31:0]                 profile_rd_data,
    // Alloc + write port for entity table — used for Auto-Enroll on
    // EntityTable-miss when accept_unknown=1.  Writes a fresh ISSI slot
    // with profile_id=0, valid=1.
    output reg                         entity_wr_en,
    output reg  [7:0]                  entity_wr_idx,
    output reg  [63:0]                 entity_wr_data,

    // -----------------------------------------------------------------
    // DB policy (REG_DB_POLICY @ 0x1AC):
    //   accept_unknown=1: shadow miss → still accept (anonymous).
    //   accept_unknown=0: shadow miss → REJECT with cause=ITSI unknown.
    // CDC-resynced from clk_axi in tetra_zynq_top.
    // -----------------------------------------------------------------
    input  wire                        accept_unknown,

    // -----------------------------------------------------------------
    // Phase B — Detach pulse + free-running multiframe counter.
    // ul_detach_valid = U-ITSI-DETACH (mm_pdu_type=1, MLE=MM, LLC=BL-DATA)
    //                   → AST entry for ul_detach_ssi cleared.
    // mf_global_cnt 24-bit free-running multiframe tick (see top-level),
    // used to refresh AST `last_seen` field for TTL sweep (Phase C).
    // -----------------------------------------------------------------
    input  wire                        ul_detach_valid,
    input  wire [23:0]                 ul_detach_ssi,
    input  wire [23:0]                 mf_global_cnt,

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
    output reg                         lost_pulse,     // 1 cyc on N252 exhaust
    output reg                         detach_pulse    // 1 cyc on AST clear (Phase B)
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
    // Phase 6 D-rev — latched lookup results driving the GILA encoder.
    // Reset defaults reproduce the M2 gold-ref bit pattern when no DB
    // entry is found (Auto-Enroll path with Profile 0).
    reg [3:0]                   lat_profile_id;     // EntityTable→Profile slot
    reg [23:0]                  lat_gila_gssi;
    reg [2:0]                   lat_gila_class;
    reg [1:0]                   lat_gila_lifetime;
    reg                         lat_gila_present;
    reg [7:0]                   lat_alloc_idx;      // EntityTable alloc target

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
        .pdu_reject        (1'b0),                 // ACCEPT-Pfad nutzt diesen Encoder
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
        // Phase 6 D-rev — dynamic GILA inputs from EntityTable/ProfileTable
        // multi-lookup (latched in lat_gila_*).  M2 default values reproduce
        // the gold-ref bit pattern when Profile 0 + GSSI 0x2F4D61 are in DB.
        .gila_gssi         (lat_gila_gssi),
        .gila_class        (lat_gila_class),
        .gila_lifetime     (lat_gila_lifetime),
        .gila_present      (lat_gila_present),
        .pdu_bits          (dloc_legacy_pdu_w),
        .pdu_bits_mm       (dloc_mm_bits_w),
        .pdu_len_bits      (dloc_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE-REJECT encoder (Phase 6 A, ETSI §16.10.40).
    // 8-bit MM body: pdu_type=0111, reject_cause(3), o-bit=0.
    // Used when the subscriber-shadow lookup denies registration
    // (permit_reg=0 or shadow miss + accept_unknown=0).
    // -------------------------------------------------------------------------
    reg  [2:0]   lat_reject_cause;
    wire [127:0] dreject_mm_bits_w;
    wire [7:0]   dreject_mm_len_w;

    tetra_d_location_update_reject_encoder u_dreject (
        .reject_cause (lat_reject_cause),
        .pdu_bits_mm  (dreject_mm_bits_w),
        .pdu_len_bits (dreject_mm_len_w)
    );

    // Mux between ACCEPT (102 bit) and REJECT (8 bit) MM body for the
    // accept-path MAC-RESOURCE wrapper.  `lat_is_reject` is set during
    // S_PERMIT_DECIDE when the lookup denies registration.
    reg          lat_is_reject;
    wire [127:0] mle_mm_bits_w  = lat_is_reject ? dreject_mm_bits_w : dloc_mm_bits_w;
    wire [7:0]   mle_mm_len_w   = lat_is_reject ? dreject_mm_len_w  : dloc_mm_len_w;

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
        // Gold-ref Burst #735: RA-flag = 0 on the full Accept.  The RA
        // acknowledgement was already piggybacked in the SCH/HD AL-SETUP
        // pre-reply (Burst #727, RA-flag=1), so the SCH/F Accept must NOT
        // re-acknowledge.  Setting this to 1 here was a delta vs. gold.
        .random_access_flag(1'b0),
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
        .mm_pdu_bits       (mle_mm_bits_w),    // ACCEPT (102b) or REJECT (8b) per lat_is_reject
        .mm_pdu_len_bits   (mle_mm_len_w),
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
    // Session record packer (Phase D-rev — 256 bit layout per §9.2)
    // [255:232]  ISSI               24    (visible to AST query scan)
    // [231:208]  last_seen_multiframe 24  (free-running counter, TTL key)
    // [207:200]  shadow_idx          8    (Phase A backref — 0 in D rev,
    //                                       wired in D.4)
    // [199:196]  state               4    (1=REG_ACCEPT_SENT)
    // [195:192]  group_count         4    (Phase D writes 0 — RX IE parser
    //                                       is M3 scope)
    // [191:  1]  group_list[8]    191    (Phase D writes 0; MS-driven GSSI
    //                                       lists land here in M3)
    // [  0]      valid               1    (visible to AST alloc scan)
    //
    // The legacy 128-bit and 64-bit paths still work via parameter override
    // — record packing degrades gracefully at the lower widths (everything
    // above [127] / [63] simply isn't emitted).  In the 256-bit path we
    // re-use the SAME [0]=valid convention from Phase B/C (see header of
    // tetra_active_session_table.v for the §9.2-vs-valid reconciliation).
    // -------------------------------------------------------------------------
    wire [AST_REC_WIDTH-1:0] session_record_w = (AST_REC_WIDTH == 256) ? {
        lat_ssi,                    // [255:232]  24  ISSI
        mf_global_cnt,              // [231:208]  24  last_seen_multiframe
        8'd0,                       // [207:200]   8  shadow_idx (D.4 wires)
        4'd1,                       // [199:196]   4  state=REG_ACCEPT_SENT
        4'd0,                       // [195:192]   4  group_count=0 (M3)
        191'd0,                     // [191:  1] 191  group_list (M3)
        1'b1                        // [  0]       1  valid
    } : (AST_REC_WIDTH == 128) ? {
        lat_ssi,                    // [127:104]  24  ISSI (legacy)
        mf_global_cnt,              // [103: 80]  24  last_seen
        8'd0,                       // [ 79: 72]   8  shadow_idx
        4'd1,                       // [ 71: 68]   4  state
        67'd0,                      // [ 67:  1]  67  reserved
        1'b1                        // [  0]       1  valid
    } : {
        // 64-bit fallback for legacy TBs (shadow_idx/state collapsed)
        lat_ssi,                    // [63:40]    24  ISSI
        39'd0,                      // [39: 1]    39  reserved
        1'b1                        // [ 0]        1  valid
    };

    // -------------------------------------------------------------------------
    // Detach record — same layout, all-zero except width (write valid=0)
    // -------------------------------------------------------------------------
    wire [AST_REC_WIDTH-1:0] detach_zero_record_w = {AST_REC_WIDTH{1'b0}};

    // -------------------------------------------------------------------------
    // FSM — Phase 6 D-rev Multi-Lookup attach flow per §9.3:
    //   Entity(ISSI) → Profile → (Default-GSSI scan when group_count==0) → AST.
    // -------------------------------------------------------------------------
    localparam [4:0] S_IDLE                = 5'd0;
    localparam [4:0] S_CHECK_START         = 5'd1;
    localparam [4:0] S_CHECK_WAIT          = 5'd2;
    localparam [4:0] S_ALLOC_START         = 5'd3;
    localparam [4:0] S_ALLOC_WAIT          = 5'd4;
    localparam [4:0] S_WRITE               = 5'd5;
    localparam [4:0] S_BUILD_SHORT_START   = 5'd6;
    localparam [4:0] S_BUILD_SHORT_WAIT    = 5'd7;
    localparam [4:0] S_ENCODE_HD_START     = 5'd8;
    localparam [4:0] S_ENCODE_HD_WAIT      = 5'd9;
    localparam [4:0] S_BUILD_ACCEPT_START  = 5'd10;
    localparam [4:0] S_BUILD_ACCEPT_WAIT   = 5'd11;
    localparam [4:0] S_ENCODE_F_START      = 5'd12;
    localparam [4:0] S_ENCODE_F_WAIT       = 5'd13;
    localparam [4:0] S_DELIVER_ACCEPT      = 5'd14;
    localparam [4:0] S_DROP                = 5'd15;
    localparam [4:0] S_WAIT_GAP_FRAME      = 5'd16;
    // Phase 6 D-rev Multi-Lookup attach flow:
    //   ENTITY_QUERY_ISSI[_DONE] → PROFILE_QUERY[_WAIT][_DECIDE]
    //                            → DEFAULT_GSSI[_DONE] → AST (S_CHECK_START).
    //   On ENTITY-miss + accept_unknown=1: ENTITY_ALLOC[_WAIT] → write fresh
    //   entry with profile_id=0 → PROFILE_QUERY (slot 0).
    localparam [4:0] S_ENTITY_QUERY_ISSI       = 5'd17;
    localparam [4:0] S_ENTITY_QUERY_ISSI_DONE  = 5'd18;
    localparam [4:0] S_ENTITY_ALLOC_ISSI       = 5'd19;
    localparam [4:0] S_ENTITY_ALLOC_WAIT       = 5'd20;
    localparam [4:0] S_PROFILE_QUERY           = 5'd21;
    localparam [4:0] S_PROFILE_WAIT            = 5'd22;
    localparam [4:0] S_PROFILE_DECIDE          = 5'd23;
    localparam [4:0] S_GSSI_QUERY_DEFAULT      = 5'd24;
    localparam [4:0] S_GSSI_QUERY_DEFAULT_DONE = 5'd25;
    // Phase 6 B: U-ITSI-DETACH path — clear AST entry for ISSI
    localparam [4:0] S_DETACH_QUERY        = 5'd26;
    localparam [4:0] S_DETACH_WAIT         = 5'd27;
    localparam [4:0] S_DETACH_CLEAR        = 5'd28;
    reg [23:0] lat_detach_ssi;
    reg [4:0] state;
    reg [2:0] gap_slot_count;
    // Profile-Table read latency = 1 cycle (registered output); we drive
    // profile_rd_idx in S_PROFILE_QUERY and consume profile_rd_data 2
    // cycles later via S_PROFILE_WAIT.
    reg [1:0] profile_wait_cnt;

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
            // Phase 6 D-rev — entity table & profile table FSM ports
            entity_q_start              <= 1'b0;
            entity_q_id                 <= 24'd0;
            entity_q_type               <= 1'b0;
            entity_q_match_type         <= 1'b0;
            entity_q_default_gssi_scan  <= 1'b0;
            entity_q_alloc              <= 1'b0;
            entity_wr_en                <= 1'b0;
            entity_wr_idx               <= 8'd0;
            entity_wr_data              <= 64'd0;
            profile_rd_idx              <= 3'd0;
            profile_wait_cnt            <= 2'd0;
            // GILA defaults — Profile 0 / Default-GSSI lookup result.
            // Reset values are the M2 gold-ref bit-identity guard so that
            // even if the DB is empty / unsynced, the encoder still
            // produces the canonical Accept (modulo gila_present=0 path
            // when no GSSI is in DB, which is also a valid behaviour).
            lat_profile_id    <= 4'd0;
            lat_gila_gssi     <= 24'h2F4D61;
            lat_gila_class    <= 3'b100;
            lat_gila_lifetime <= 2'b01;
            lat_gila_present  <= 1'b1;
            lat_alloc_idx     <= 8'd0;
            lat_is_reject     <= 1'b0;
            lat_reject_cause  <= 3'd0;
            lat_detach_ssi    <= 24'd0;
            detach_pulse      <= 1'b0;
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
            entity_q_start   <= 1'b0;
            entity_q_alloc   <= 1'b0;
            entity_wr_en     <= 1'b0;
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
            detach_pulse     <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy          <= 1'b0;
                lat_is_reject <= 1'b0;
                // Phase 6 B — U-ITSI-DETACH takes priority over a new
                // registration request.
                if (ul_detach_valid) begin
                    lat_detach_ssi <= ul_detach_ssi;
                    busy           <= 1'b1;
                    state          <= S_DETACH_QUERY;
                end else if (ul_req_valid) begin
                    // D-LOCATION UPDATE ACCEPT is always addressed per SSI
                    // (ETSI EN 300 392-2 §16.10.28).  Force SSI (3'd1)
                    // for every registration accept regardless of the
                    // MS-picked MAC addressing on the UL request.
                    lat_addr_type    <= 3'd1;
                    lat_ssi          <= ul_ssi;
                    lat_la           <= ul_la;
                    lat_loc_upd_type <= ul_loc_upd_type;
                    lat_use_l2sig    <= ul_use_l2sig;
                    busy             <= 1'b1;
                    // Phase 6 D-rev §9.3 step 1: EntityTable.query(ISSI).
                    state            <= S_ENTITY_QUERY_ISSI;
                end
            end

            // -----------------------------------------------------------------
            // Phase 6 D-rev — §9.3 Multi-Lookup attach flow
            //
            // Step 1: Entity.query(issi=ul_issi, type=0).
            //   hit  → profile_id = entity.profile_id
            //          goto S_PROFILE_QUERY
            //   miss + accept_unknown=0 → REJECT (cause "service profile not
            //                                      subscribed")
            //   miss + accept_unknown=1 → goto S_ENTITY_ALLOC_ISSI
            // -----------------------------------------------------------------
            S_ENTITY_QUERY_ISSI: begin
                entity_q_start             <= 1'b1;
                entity_q_id                <= lat_ssi;
                entity_q_type              <= 1'b0;          // ISSI
                entity_q_match_type        <= 1'b1;          // strict
                entity_q_default_gssi_scan <= 1'b0;
                state                      <= S_ENTITY_QUERY_ISSI_DONE;
            end

            S_ENTITY_QUERY_ISSI_DONE: begin
                if (entity_q_done) begin
                    if (entity_q_hit) begin
                        // Latch profile_id from EntityTable record [38:35].
                        lat_profile_id <= entity_q_record[38:35];
                        state          <= S_PROFILE_QUERY;
                    end else if (accept_unknown) begin
                        // Auto-Enroll: alloc free slot, write fresh entry
                        // with profile_id=0.
                        state <= S_ENTITY_ALLOC_ISSI;
                    end else begin
                        // Strict mode unknown → REJECT cause=0 (ITSI unknown
                        // per ETSI §16.10.39 / "service profile not
                        // subscribed").
                        lat_is_reject    <= 1'b1;
                        lat_reject_cause <= 3'd0;
                        // Default GILA inputs to M2 values so the encoder
                        // still emits a clean REJECT (GILA bits ignored on
                        // REJECT path — len=8).
                        lat_profile_id   <= 4'd0;
                        // Skip Profile/GSSI lookups, go straight to AST so
                        // the existing flow records the rejected attempt.
                        state            <= S_CHECK_START;
                    end
                end
            end

            S_ENTITY_ALLOC_ISSI: begin
                // Issue alloc-mode scan to find first valid=0 slot.
                entity_q_start             <= 1'b1;
                entity_q_id                <= 24'd0;         // don't-care
                entity_q_type              <= 1'b0;
                entity_q_match_type        <= 1'b0;
                entity_q_default_gssi_scan <= 1'b0;
                entity_q_alloc             <= 1'b1;
                state                      <= S_ENTITY_ALLOC_WAIT;
            end

            S_ENTITY_ALLOC_WAIT: begin
                if (entity_q_done) begin
                    if (entity_q_hit) begin
                        // Found free slot — write fresh entry with
                        // entity_id=lat_ssi, entity_type=0, profile_id=0,
                        // valid=1.
                        lat_alloc_idx  <= entity_q_slot;
                        entity_wr_en   <= 1'b1;
                        entity_wr_idx  <= entity_q_slot;
                        entity_wr_data <= {lat_ssi,        // [63:40]
                                           1'b0,           // [39] type=ISSI
                                           4'd0,           // [38:35] profile=0
                                           34'd0,          // [34:1] reserved
                                           1'b1};          // [0] valid
                        lat_profile_id <= 4'd0;
                        state          <= S_PROFILE_QUERY;
                    end else begin
                        // EntityTable full — REJECT cause=0.
                        lat_is_reject    <= 1'b1;
                        lat_reject_cause <= 3'd0;
                        state            <= S_CHECK_START;
                    end
                end
            end

            // -----------------------------------------------------------------
            // Step 2: Profile.lookup(profile_id) → permit_reg?
            //   permit_reg=0 → REJECT (cause "service profile not subscribed")
            //   permit_reg=1 → continue, latch gila_class/lifetime
            // -----------------------------------------------------------------
            S_PROFILE_QUERY: begin
                profile_rd_idx   <= lat_profile_id[2:0];
                // Profile-Table read latency = 1 cycle (registered).
                // We need at least 2 cycles between drive-rd_idx and
                // sample-rd_data: cycle N drives rd_idx, cycle N+1 the
                // BRAM/LUT-RAM internal read fires, cycle N+2 rd_data
                // is stable.
                profile_wait_cnt <= 2'd2;
                state            <= S_PROFILE_WAIT;
            end

            S_PROFILE_WAIT: begin
                if (profile_wait_cnt == 2'd0) begin
                    state <= S_PROFILE_DECIDE;
                end else begin
                    profile_wait_cnt <= profile_wait_cnt - 2'd1;
                end
            end

            S_PROFILE_DECIDE: begin
                // profile_rd_data[1] = permit_reg per §9.2.
                if (!profile_rd_data[0]) begin
                    // valid=0 → profile slot is unconfigured → REJECT
                    // cause=0 (ITSI unknown / profile not subscribed).
                    // Profile 0 reset-default has valid=1, so this only
                    // fires when an Auto-Enroll-with-Profile-N path is
                    // wired in Phase E.5.
                    lat_is_reject    <= 1'b1;
                    lat_reject_cause <= 3'd0;
                    state            <= S_CHECK_START;
                end else if (!profile_rd_data[1]) begin
                    // permit_reg=0 → REJECT cause=4 ("service not
                    // authorised").
                    lat_is_reject    <= 1'b1;
                    lat_reject_cause <= 3'd4;
                    state            <= S_CHECK_START;
                end else begin
                    // Permit granted — latch gila_class/lifetime from
                    // Profile record [11:9] / [8:7] per §9.2.
                    lat_gila_class    <= profile_rd_data[11:9];
                    lat_gila_lifetime <= profile_rd_data[8:7];
                    lat_is_reject     <= 1'b0;
                    state             <= S_GSSI_QUERY_DEFAULT;
                end
            end

            // -----------------------------------------------------------------
            // Step 3: Default-GSSI scan (§9.3 + fix_plan M2-Bit-Identity hack).
            //   In Phase D the RX `group_identity_location_demand` IE is not
            //   yet parsed (M3 scope), so AST.group_count == 0 unconditionally.
            //   Per the fix_plan resolution, we scan EntityTable for the first
            //   valid entity_type=1 slot ("Default-Group-of-the-Cell"); if
            //   found, GILA goes out with that GSSI.  If no GSSI in DB, the
            //   GILA Type-3 element is omitted (gila_present=0).
            // -----------------------------------------------------------------
            S_GSSI_QUERY_DEFAULT: begin
                entity_q_start             <= 1'b1;
                entity_q_id                <= 24'd0;
                entity_q_type              <= 1'b0;
                entity_q_match_type        <= 1'b0;
                entity_q_default_gssi_scan <= 1'b1;
                state                      <= S_GSSI_QUERY_DEFAULT_DONE;
            end

            S_GSSI_QUERY_DEFAULT_DONE: begin
                if (entity_q_done) begin
                    if (entity_q_hit) begin
                        // GSSI found — latch it, GILA Type-3 emitted.
                        lat_gila_gssi    <= entity_q_record[63:40];
                        lat_gila_present <= 1'b1;
                    end else begin
                        // No GSSI in DB — omit GILA Type-3 element.
                        lat_gila_present <= 1'b0;
                    end
                    state <= S_CHECK_START;
                end
            end

            // -----------------------------------------------------------------
            // Phase 6 B — U-ITSI-DETACH path: query AST for ISSI, clear slot.
            //   1. AST.query(lat_detach_ssi)
            //   2. hit  → AST.write(slot, valid=0) + detach_pulse
            //      miss → ignore, detach_pulse still fires for counter purpose
            //   3. No DL response (ETSI: ITSI-DETACH is one-way).
            // -----------------------------------------------------------------
            S_DETACH_QUERY: begin
                ast_q_start <= 1'b1;
                ast_q_mode  <= 1'b0;       // query existing
                ast_q_issi  <= lat_detach_ssi;
                state       <= S_DETACH_WAIT;
            end

            S_DETACH_WAIT: begin
                if (ast_q_done) begin
                    if (ast_q_hit) begin
                        // Latch the slot we will overwrite with a zeroed record
                        lat_slot <= ast_q_slot;
                        state    <= S_DETACH_CLEAR;
                    end else begin
                        // No matching session — pulse counter, return idle.
                        detach_pulse <= 1'b1;
                        state        <= S_IDLE;
                    end
                end
            end

            S_DETACH_CLEAR: begin
                ast_wr_en    <= 1'b1;
                ast_wr_idx   <= lat_slot;
                ast_wr_data  <= detach_zero_record_w;
                detach_pulse <= 1'b1;
                state        <= S_IDLE;
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
