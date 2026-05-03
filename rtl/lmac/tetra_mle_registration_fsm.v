// =============================================================================
// tetra_mle_registration_fsm.v
//
// Phase X.4 — SW-driven minimal trigger FSM.
//
// The Multi-Lookup attach flow (EntityTable / ProfileTable / AST) was
// migrated to ARM SW in Phases X.0..X.3 (sw/tetra_db.[ch] +
// sw/tetra_attach_daemon.c).  The on-chip FSM is now reduced to a thin
// trigger machine:
//
//   1. SW pre-stages the D-LOC-UPDATE-ACCEPT MM-Body fields into the
//      Reply-Pull-Mailbox (mb_ssi, mb_addr_type, mb_gila_*, ...) via
//      AXI-Lite REG_REPLY_INDEX/DATA.
//   2. SW pulses REG_REPLY_GO -> 1-cycle clk_sys mb_go_pulse arrives at
//      this FSM.  With use_sw_body=1 (Phase X.4 reset default), the FSM
//      jumps directly into S_BUILD_ACCEPT_START.
//   3. The MAC-RESOURCE accept builder + SCH/F encoder run unchanged on
//      lat_ssi/lat_addr_type (latched on the GO pulse).  The encoder
//      reads mb_* directly via the input mux preserved from Phase X.2.
//   4. accept_pulse fires after S_DELIVER_ACCEPT, exactly as before.
//
// Detach path is now a no-op telemetry stub; SW will own real detach
// behaviour in Phase X.5.  detach_pulse still fires for counter
// observability.
//
// The Pre-Reply (SCH/HD AL-SETUP) path is unreachable in this revision
// because the only S_IDLE entry is the SW-triggered direct jump.  The
// SCH/HD encoder + short MAC-RESOURCE builder + slot-grant + chan-alloc
// encoders are kept instantiated for now so Phase X.5 (Pre-Reply BL-ACK
// + AACH cleanup) lands as a focused diff; they synthesise as dead
// logic and will be pruned out together with the Pre-Reply removal.
//
// M2 bit-identity: tb_d_location_update_encoder.v 34/34 PASS preserved;
// the encoder bit-layout is unchanged.  When SW writes the same Profile
// 0 / GSSI 0x2F4D61 / class=4 / lifetime=1 fields into the Reply
// mailbox, the on-air ACCEPT body is bit-for-bit identical to the
// pre-X.4 hardware-driven path.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_mle_registration_fsm (
    input  wire                        clk,
    input  wire                        rst_n,

    // -----------------------------------------------------------------
    // Uplink request from UL MAC-ACCESS parser (Phase X.4: ignored).
    //
    // Kept on the port for top-level wiring continuity; the SW attach
    // daemon decodes UL Demand reassemblies independently of these
    // signals and drives the Reply-Pull-Mailbox directly.
    // -----------------------------------------------------------------
    input  wire                        ul_req_valid,
    input  wire [1:0]                  ul_addr_type,
    input  wire [23:0]                 ul_ssi,
    input  wire [13:0]                 ul_la,
    input  wire [2:0]                  ul_loc_upd_type,
    input  wire                        ul_use_l2sig,
    input  wire                        ul_llc_is_bl_data,
    input  wire                        ul_llc_ns_valid,
    input  wire                        ul_llc_ns,
    input  wire                        bl_ack_valid,
    input  wire                        bl_ack_nr,
    input  wire [23:0]                 bl_ack_issi,
    input  wire                        slot_pulse,

    // -----------------------------------------------------------------
    // Cell configuration (static, from AXI regs).
    // The encoder still reads cfg_la and cfg_scramble_init / cfg_mcch_tn
    // for the legacy non-SW path; in the X.4 default flow (use_sw_body=1)
    // they are unused on the encoder side but cfg_scramble_init is still
    // consumed by the SCH/F encoder, and cfg_mcch_tn drives req_target_tn.
    // -----------------------------------------------------------------
    input  wire [13:0]                 cfg_la,
    input  wire [31:0]                 cfg_scramble_init,
    input  wire [1:0]                  cfg_mcch_tn,
    input  wire [23:0]                 cfg_address_extension,
    input  wire [15:0]                 cfg_subscriber_class,
    input  wire [13:0]                 cfg_energy_saving_info,

    // -----------------------------------------------------------------
    // Phase B — Detach pulse.  In Phase X.4 the AST has been migrated
    // to SW; this path is a no-op telemetry stub (latches the SSI for
    // visibility, pulses detach_pulse, no AST touch).
    // -----------------------------------------------------------------
    input  wire                        ul_detach_valid,
    input  wire [23:0]                 ul_detach_ssi,

    // -----------------------------------------------------------------
    // Phase X.2 — Reply-Pull-Mailbox pass-through inputs.
    //
    // SW-staged D-LOC-UPDATE-ACCEPT fields.  use_sw_body=1 (Phase X.4
    // default) routes mb_* to the encoder; use_sw_body=0 falls back to
    // the FSM-latched lat_* values (now reset-defaults only — no FSM
    // update path remains in X.4).
    //
    // mb_go_pulse is the new trigger from SW: with use_sw_body=1 the
    // FSM jumps directly from S_IDLE to S_BUILD_ACCEPT_START.
    // -----------------------------------------------------------------
    input  wire [23:0]                 mb_ssi,
    input  wire [13:0]                 mb_la,
    input  wire [2:0]                  mb_addr_type,
    input  wire [1:0]                  mb_result,
    input  wire [23:0]                 mb_gila_gssi,
    input  wire [2:0]                  mb_gila_class,
    input  wire [1:0]                  mb_gila_lifetime,
    input  wire                        mb_gila_present,
    input  wire [1:0]                  mb_encryption,
    input  wire [1:0]                  mb_auth_result,
    input  wire                        mb_go_pulse,
    input  wire                        use_sw_body,

    // -----------------------------------------------------------------
    // DL signalling-queue request — 1-cycle pulse carrying the full 432-bit
    // SCH/F coded PDU plus type/target metadata.
    // -----------------------------------------------------------------
    output reg                         req_valid,
    output reg  [431:0]                req_coded_bits,
    output reg  [1:0]                  req_pdu_type,    // 00=SCH_F
    output reg  [1:0]                  req_target_tn,
    output reg                         req_second_pdu_present,
    output reg                         req_second_pdu_nr,

    // -----------------------------------------------------------------
    // Debug / status
    // -----------------------------------------------------------------
    output reg                         busy,
    output reg                         accept_pulse,   // 1 cyc on ACCEPT built
    output reg                         drop_pulse,     // tied 0 in X.4
    output reg                         ack_pulse,      // tied 0 in X.4
    output reg                         retransmit_pulse, // tied 0 in X.4
    output reg                         lost_pulse,     // tied 0 in X.4
    output reg                         detach_pulse    // 1 cyc on U-ITSI-DETACH (no-op stub)
);

    // Suppress lint on unused legacy ports (kept for top-level wiring).
    // synthesis translate_off
    wire _unused_ports = |{
        ul_req_valid, ul_addr_type, ul_ssi, ul_la, ul_loc_upd_type,
        ul_use_l2sig, ul_llc_is_bl_data, ul_llc_ns_valid, ul_llc_ns,
        bl_ack_valid, bl_ack_nr, bl_ack_issi, slot_pulse,
        cfg_la, cfg_address_extension, cfg_subscriber_class,
        cfg_energy_saving_info, mb_la, mb_result, mb_encryption,
        mb_auth_result, 1'b0
    };
    // synthesis translate_on

    // -------------------------------------------------------------------------
    // Latched ACCEPT trigger fields.
    //
    // The MAC-RESOURCE accept builder consumes ssi/addr_type directly (not
    // through the SW mux), so we latch from mb_* at the GO pulse.  The
    // encoder mux still reads mb_* live, so its bits stay in lock-step with
    // the SW-staged values.
    // -------------------------------------------------------------------------
    reg [2:0]   lat_addr_type;
    reg [23:0]  lat_ssi;

    // Encoder fallback latches (only used when use_sw_body=0 — legacy path).
    // No update path drives them in X.4; they hold their reset defaults so
    // a downstream consumer with the toggle off still sees the M2 bit
    // pattern (Profile 0 default GILA).
    reg [13:0]  lat_la;
    reg [2:0]   lat_loc_upd_type;
    reg [23:0]  lat_gila_gssi;
    reg [2:0]   lat_gila_class;
    reg [1:0]   lat_gila_lifetime;
    reg         lat_gila_present;

    reg [267:0] lat_accept_info_bits;
    reg [23:0]  lat_detach_ssi;

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE encoder — Phase X.2 input mux preserved.  The mux
    // selector is `use_sw_body`; with the X.4 reset default of 1 (driven
    // from REG_REPLY_USE_SW), every encoder input resolves to the SW-staged
    // mailbox value.
    // -------------------------------------------------------------------------
    wire [127:0] dloc_mm_bits_w;
    wire [7:0]   dloc_mm_len_w;
    wire [123:0] dloc_legacy_pdu_w;     // unused — kept for linter silence

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject        (1'b0),
        .addr_type         (use_sw_body ? mb_addr_type : lat_addr_type),
        .ssi               (use_sw_body ? mb_ssi      : lat_ssi),
        .la                (use_sw_body ? mb_la       : cfg_la),
        .result            (use_sw_body ? mb_result   : 2'b00),
        .encryption        (use_sw_body ? mb_encryption  : 2'b00),
        .auth_result       (use_sw_body ? mb_auth_result : 2'b01),
        .subscriber_class  (cfg_subscriber_class),
        .address_extension (cfg_address_extension),
        .energy_saving_info(cfg_energy_saving_info),
        .loc_acc_type      (lat_loc_upd_type),
        .gila_gssi         (use_sw_body ? mb_gila_gssi     : lat_gila_gssi),
        .gila_class        (use_sw_body ? mb_gila_class    : lat_gila_class),
        .gila_lifetime     (use_sw_body ? mb_gila_lifetime : lat_gila_lifetime),
        .gila_present      (use_sw_body ? mb_gila_present  : lat_gila_present),
        .pdu_bits          (dloc_legacy_pdu_w),
        .pdu_bits_mm       (dloc_mm_bits_w),
        .pdu_len_bits      (dloc_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // BasicSlotgrant + ChanAllocElement encoders — kept instantiated; the
    // builder ties their flags to 0/1 below.  These vanish with the
    // Pre-Reply removal in Phase X.5.
    // -------------------------------------------------------------------------
    wire [7:0]  slot_grant_packed_w;
    tetra_basic_slotgrant_encoder u_slotgrant (
        .capacity_allocation (4'd0),
        .granting_delay      (4'd1),
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
        .mon_pattern         (2'd3),
        .frame18_mon_pattern (2'd0),
        .packed_element      (chan_alloc_packed_w),
        .element_len         (chan_alloc_len_w)
    );

    // -------------------------------------------------------------------------
    // MAC-RESOURCE DL builder — full ACCEPT (SCH/F, 268 info bits).
    // -------------------------------------------------------------------------
    reg          accept_builder_start;
    wire [267:0] accept_builder_pdu_bits_w;
    wire         accept_builder_valid_w;

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
        .mm_pdu_bits       (dloc_mm_bits_w),
        .mm_pdu_len_bits   (dloc_mm_len_w),
        .pdu_bits          (accept_builder_pdu_bits_w),
        .valid             (accept_builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // SCH/F channel encoder — 268 info bits → 432 type-5 coded bits.
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

    // -------------------------------------------------------------------------
    // FSM — Phase X.4 minimal trigger machine.
    //
    //   S_IDLE              — wait for U-ITSI-DETACH or SW-driven ACCEPT GO.
    //   S_DETACH_NOOP       — pulse detach_pulse, return idle (no AST touch).
    //   S_BUILD_ACCEPT_*    — drive MAC-RESOURCE builder; latch accept_info.
    //   S_ENCODE_F_*        — drive SCH/F encoder; latch 432-bit coded.
    //   S_DELIVER_ACCEPT    — emit req_valid + accept_pulse.
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE              = 4'd0;
    localparam [3:0] S_DETACH_NOOP       = 4'd1;
    localparam [3:0] S_BUILD_ACCEPT_START= 4'd2;
    localparam [3:0] S_BUILD_ACCEPT_WAIT = 4'd3;
    localparam [3:0] S_ENCODE_F_START    = 4'd4;
    localparam [3:0] S_ENCODE_F_WAIT     = 4'd5;
    localparam [3:0] S_DELIVER_ACCEPT    = 4'd6;
    reg [3:0] state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            lat_addr_type          <= 3'd0;
            lat_ssi                <= 24'd0;
            lat_la                 <= 14'd0;
            lat_loc_upd_type       <= 3'd0;
            lat_gila_gssi          <= 24'h2F4D61;   // M2 default
            lat_gila_class         <= 3'b100;
            lat_gila_lifetime      <= 2'b01;
            lat_gila_present       <= 1'b1;
            lat_accept_info_bits   <= 268'd0;
            lat_detach_ssi         <= 24'd0;
            accept_builder_start   <= 1'b0;
            sch_encode_start       <= 1'b0;
            req_valid              <= 1'b0;
            req_coded_bits         <= 432'd0;
            req_pdu_type           <= 2'd0;
            req_target_tn          <= 2'd0;
            req_second_pdu_present <= 1'b0;
            req_second_pdu_nr      <= 1'b0;
            busy                   <= 1'b0;
            accept_pulse           <= 1'b0;
            drop_pulse             <= 1'b0;
            ack_pulse              <= 1'b0;
            retransmit_pulse       <= 1'b0;
            lost_pulse             <= 1'b0;
            detach_pulse           <= 1'b0;
        end else begin
            // Default strobes — every state may override
            accept_builder_start <= 1'b0;
            sch_encode_start     <= 1'b0;
            req_valid            <= 1'b0;
            accept_pulse         <= 1'b0;
            drop_pulse           <= 1'b0;
            ack_pulse            <= 1'b0;
            retransmit_pulse     <= 1'b0;
            lost_pulse           <= 1'b0;
            detach_pulse         <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                // Phase X.4 — U-ITSI-DETACH takes priority and lands as a
                // no-op telemetry stub.  Real AST clear is owned by SW
                // (Phase X.5 will plumb the SW detach daemon).
                if (ul_detach_valid) begin
                    lat_detach_ssi <= ul_detach_ssi;
                    busy           <= 1'b1;
                    state          <= S_DETACH_NOOP;
                end else if (use_sw_body && mb_go_pulse) begin
                    // Phase X.4 — SW has staged the ACCEPT body; jump
                    // directly into the builder.  Latch ssi/addr_type so the
                    // MAC-RESOURCE wrapper sees a stable address pair while
                    // SW is free to start staging the next ACCEPT.
                    lat_ssi       <= mb_ssi;
                    lat_addr_type <= mb_addr_type;
                    busy          <= 1'b1;
                    state         <= S_BUILD_ACCEPT_START;
                end
            end

            // -----------------------------------------------------------------
            S_DETACH_NOOP: begin
                detach_pulse <= 1'b1;
                state        <= S_IDLE;
            end

            // -----------------------------------------------------------------
            S_BUILD_ACCEPT_START: begin
                accept_builder_start <= 1'b1;
                state                <= S_BUILD_ACCEPT_WAIT;
            end

            S_BUILD_ACCEPT_WAIT: begin
                if (accept_builder_valid_w) begin
                    lat_accept_info_bits <= accept_builder_pdu_bits_w;
                    state                <= S_ENCODE_F_START;
                end
            end

            S_ENCODE_F_START: begin
                sch_encode_start <= 1'b1;
                state            <= S_ENCODE_F_WAIT;
            end

            S_ENCODE_F_WAIT: begin
                if (sch_coded_valid_w) begin
                    req_coded_bits         <= sch_coded_bits_w;
                    req_pdu_type           <= 2'd0;       // SCH_F
                    req_target_tn          <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    state                  <= S_DELIVER_ACCEPT;
                end
            end

            S_DELIVER_ACCEPT: begin
                req_valid    <= 1'b1;
                accept_pulse <= 1'b1;
                state        <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
