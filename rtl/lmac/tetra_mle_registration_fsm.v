// =============================================================================
// tetra_mle_registration_fsm.v
//
// Phase X.7 — Cleanup: USE_SW mux + dead encoder-fallback latches removed.
// Phase X.6 — SW-driven minimal trigger FSM, builder pipeline EXTERNALISED.
//
// X.4 made this a thin SW-trigger machine; X.6 (slice-saver refactor) now
// also pulls the {basic_slotgrant_encoder, mac_resource_dl_builder,
// sch_f_encoder} triple OUT of this module.  The shared instance lives
// in tetra_dl_pdu_builder.v and is arbitrated against
// tetra_pre_reply_slotgrant.v at the top level.
//
// X.7 cleanup: the use_sw_body input mux + lat_la / lat_loc_upd_type /
// lat_gila_* fallback latches are gone — those existed only to support
// USE_SW=0 (legacy MLE-FSM-internal Multi-Lookup), which has been dead
// code since X.4 made USE_SW=1 the reset default.  The encoder is now
// driven directly from the Reply-Pull-Mailbox fields.
//
// Trigger flow (unchanged):
//   1. SW pre-stages D-LOC-UPDATE-ACCEPT MM-Body fields into the Reply-
//      Pull-Mailbox (mb_ssi, mb_addr_type, mb_gila_*, ...) via AXI-Lite
//      REG_REPLY_INDEX/DATA.
//   2. SW pulses REG_REPLY_GO -> 1-cycle clk_sys mb_go_pulse arrives at
//      this FSM, which jumps from S_IDLE into S_BUILD_ACCEPT_REQ.
//   3. The FSM emits a 1-cycle build-request pulse (`accept_build_req`)
//      with the request fields routed through dedicated `accept_build_*`
//      output ports.  Top-level wiring routes those into the shared
//      tetra_dl_pdu_builder via the X.6 arbiter; the builder fires the
//      same MAC-RESOURCE + SCH/F encode chain that lived inline pre-X.6.
//   4. Builder asserts `accept_build_done` for 1 cycle with `accept_build_
//      coded[431:0]` — FSM latches the coded bits, emits accept_pulse
//      and req_valid exactly as before.
//
// Detach path is still a no-op telemetry stub — owned by SW since X.5.
//
// M2 bit-identity guarantee: the MM-Body 102/36-bit payload is computed
// inside this module via tetra_d_location_update_encoder (UNCHANGED — the
// dloc encoder is single-instance, not shared) and routed verbatim into
// `accept_build_mm_pdu_bits[127:0]`.  The builder pipeline outside this
// module instantiates the same MAC-RESOURCE / SCH/F encoders with the
// same flags (slot_granting=1, granting_delay=1, llc_pdu_type=BL-ADATA,
// random_access_flag=0) — see tetra_dl_pdu_builder.v.  Verified via
// tb_d_location_update_encoder MM-body PASS preserved.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

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
    // X.7 cleanup: cfg_address_extension / cfg_subscriber_class removed
    // (only the legacy 124-bit pdu_bits encoder path consumed them, and
    // that path is gone from the encoder in X.7).
    // -----------------------------------------------------------------
    input  wire [13:0]                 cfg_la,
    input  wire [31:0]                 cfg_scramble_init,
    input  wire [1:0]                  cfg_mcch_tn,
    input  wire [13:0]                 cfg_energy_saving_info,

    // -----------------------------------------------------------------
    // Phase B — Detach pulse.  No-op telemetry stub since X.4.
    // -----------------------------------------------------------------
    input  wire                        ul_detach_valid,
    input  wire [23:0]                 ul_detach_ssi,

    // -----------------------------------------------------------------
    // Phase X.2 — Reply-Pull-Mailbox pass-through inputs.
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

    // -----------------------------------------------------------------
    // Phase Y.2 — Reply-Pull-Mailbox raw-mode (Variante A).
    //
    // When mb_raw_mode_flag=1 on the GO pulse the FSM bypasses the dloc
    // encoder and routes mb_raw_mm_bits/mb_raw_mm_len directly into the
    // shared DL-PDU builder via the accept_build_mm_pdu_* ports.  Used
    // by SW for D-ATTACH-DETACH-GRP-ID-ACK (mm=11) where the body is
    // fully built in C; the same Reply mailbox + GO trigger + builder
    // pipeline is reused, only the MM-body source is swapped.
    //
    // raw_mode_flag=0 path (mm=2 ACCEPT) is bit-identical to pre-Y.2.
    // -----------------------------------------------------------------
    input  wire                        mb_raw_mode_flag,
    input  wire [127:0]                mb_raw_mm_bits,
    input  wire [7:0]                  mb_raw_mm_len,
    input  wire                        mb_raw_ns,
    input  wire                        mb_raw_nr,
    /* Phase 7 G.4 — MLE-PD selector: 0b001=MM (mm=2/mm=11), 0b010=CMCE
     * (D-CONNECT/D-TX-GRANTED/...).  Sampled on GO pulse together with the
     * rest of the raw-mode fields.  Mailbox encodes 0b000 ↔ default-MM. */
    input  wire [2:0]                  mb_raw_mle_pd,

    // -----------------------------------------------------------------
    // Phase X.6 — Build-request to shared tetra_dl_pdu_builder.
    //   accept_build_req            1-cyc pulse on S_BUILD_ACCEPT_START
    //   accept_build_*              field plane sampled on the same cycle
    //                               by the arbiter; values stay stable
    //                               while busy (not strictly required
    //                               by the builder, but guarantees clean
    //                               waveform for ILA / TB inspection).
    //   accept_build_done           1-cyc pulse from builder on completion
    //   accept_build_coded          432-bit type-5 SCH/F coded bits
    // -----------------------------------------------------------------
    output reg                         accept_build_req,
    output wire [23:0]                 accept_build_ssi,
    output wire [2:0]                  accept_build_addr_type,
    output wire [3:0]                  accept_build_llc_pdu_type,
    output wire                        accept_build_random_access_flag,
    output wire [127:0]                accept_build_mm_pdu_bits,
    output wire [7:0]                  accept_build_mm_pdu_len_bits,
    output wire [31:0]                 accept_build_scramble_init,
    // Phase Y.2 — LLC stop-and-wait sequence numbers passed to the shared
    // builder.  mm=2 ACCEPT path keeps ns=nr=0 (bit-identical pre-Y.2);
    // mm=11 GROUP-ACK path latches ns/nr from the Reply-Pull-Mailbox W9
    // (bits [9]=nr, [8]=ns) so the builder produces the right BL-ADATA
    // header.  Sampled on the same GO pulse that latches the raw bits.
    output wire [2:0]                  accept_build_mle_pd,
    output wire                        accept_build_ns,
    output wire                        accept_build_nr,
    /* Phase 7 G.7 — AACH pattern per PDU-class.  CMCE BL-UDATA bursts
     * (D-CONNECT/D-SETUP/D-TX-GRANTED) use idle AACH (Gold 0x0249) since
     * no UL-slot grant is implied; ATTACH/grpack BL-ADATA use 0x0009.
     * Driven combinationally from latched raw_mle_pd. */
    output wire [13:0]                 accept_build_aach_pattern,
    input  wire                        accept_build_done,
    input  wire [431:0]                accept_build_coded,

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
        cfg_la, cfg_energy_saving_info, mb_la, mb_result, mb_encryption,
        mb_auth_result, 1'b0
    };
    // synthesis translate_on

    // -------------------------------------------------------------------------
    // Latched ACCEPT trigger fields.
    // The shared builder consumes ssi/addr_type via the build-request
    // ports; we latch from mb_* on the GO pulse so SW is free to start
    // staging the next ACCEPT immediately.  All other MM-body fields are
    // wired combinationally from the Reply-Pull-Mailbox (driven by SW
    // through tetra_reply_mailbox.v).
    // -------------------------------------------------------------------------
    reg [2:0]   lat_addr_type;
    reg [23:0]  lat_ssi;

    reg [23:0]  lat_detach_ssi;

    // Phase Y.2 — latched raw-mode fields (Variante A multi-PDU dispatch).
    // Sampled on the same GO pulse that latches lat_ssi / lat_addr_type.
    // When lat_raw_mode_flag=1 the build-request mux below forwards
    // lat_raw_mm_bits/lat_raw_mm_len instead of dloc_mm_bits_w/dloc_mm_len_w
    // and forwards lat_raw_ns/lat_raw_nr through the new accept_build_ns/nr
    // ports.  Bit-identity for the legacy mm=2 ACCEPT path is preserved as
    // long as SW writes raw_mode_flag=0 for those replies (default reset
    // state of the mailbox W9 = 0, so silent).
    reg         lat_raw_mode_flag;
    reg [127:0] lat_raw_mm_bits;
    reg [2:0]   lat_raw_mle_pd;
    reg [7:0]   lat_raw_mm_len;
    reg         lat_raw_ns;
    reg         lat_raw_nr;

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE encoder — X.7 cleanup: drives the MM body straight
    // from the Reply-Pull-Mailbox.  This is the SINGLE-INSTANCE MM-Body
    // encoder; NOT shared between FSMs (only one consumer).  M2 bit-
    // identity is rooted here.
    //
    // loc_acc_type tied to 3'b000 — the field is part of the 102-bit MM
    // body but the gold-ref Accept (Burst #735) uses 0 for ITSI-attach
    // replies, and the field had no SW staging path pre-X.7 (the legacy
    // lat_loc_upd_type latch was always 0 because ul_req_valid was never
    // wired).  If we ever need a non-zero value, add an mb_loc_acc_type
    // field to the Reply-Pull-Mailbox.
    // -------------------------------------------------------------------------
    wire [127:0] dloc_mm_bits_w;
    wire [7:0]   dloc_mm_len_w;

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject        (1'b0),
        .energy_saving_info(cfg_energy_saving_info),
        .loc_acc_type      (3'b000),
        .gila_gssi         (mb_gila_gssi),
        .gila_class        (mb_gila_class),
        .gila_lifetime     (mb_gila_lifetime),
        .gila_present      (mb_gila_present),
        .pdu_bits_mm       (dloc_mm_bits_w),
        .pdu_len_bits      (dloc_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // Build-request field plane — combinational from latched values.
    // Pre-X.6 the MAC-RESOURCE builder consumed these directly; now the
    // arbiter routes them into the shared tetra_dl_pdu_builder.  Field
    // values match the pre-X.6 hardcoded inputs to u_accept_builder:
    //   addr_type            = lat_addr_type
    //   llc_pdu_type         = 4'd0  (BL-ADATA)
    //   random_access_flag   = 1'b0  (D-LOC-UPDATE-ACCEPT is unsolicited
    //                                 from the MS PoV — the GILA carries
    //                                 implicit ACK semantics)
    //   mm_pdu_bits          = dloc_mm_bits_w  (D-LOC-UPDATE-ACCEPT body)
    //   mm_pdu_len_bits      = dloc_mm_len_w
    //   scramble_init        = cfg_scramble_init
    // -------------------------------------------------------------------------
    // Phase Y.2 — MM-body source mux: raw_mode_flag=1 picks SW-built bits,
    // 0 picks the dloc encoder output (mm=2 legacy path, bit-identical).
    //
    // mm=2 (PDUC_FINAL_LU_ACCEPT) and mm=11 (PDUC_GROUP_ACK) share LLC
    // (BL-ADATA), addr_type (SSI), random_access_flag (0), pdu_format
    // (SCH/F) — confirmed in `rtl/include/tetra_pdu_class.vh`.  The only
    // per-PDU difference is the MM body bits + ns/nr (mm=2 uses 0/0, mm=11
    // uses LLC stop-and-wait alternation supplied by SW).
    /* Phase 7 G.7 — Per-PDU-class field plane.  When raw_mode + MLE-PD=CMCE
     * (=3'b010) the FSM switches to D-CONNECT/D-SETUP/D-TX-GRANTED layout
     * (Gold burst #5887 verified 2026-05-13):
     *   addr_type  = SsiAndUsageMarker (6, with 8-bit usage marker)
     *   llc_pdu_type = BL-UDATA (no NS/NR stop-and-wait)
     *   aach_pattern = IDLE 0x0249 (no UL-slot grant)
     * ATTACH/grpack paths (raw_mle_pd != CMCE) keep the legacy LU_ACCEPT
     * fields → bit-identity preserved. */
    wire cmce_path_w = lat_raw_mode_flag && (lat_raw_mle_pd == 3'b010);

    assign accept_build_ssi                = lat_ssi;
    assign accept_build_addr_type          = cmce_path_w
                                             ? `PDUC_CMCE_D_CONNECT_ADDRTYPE
                                             : lat_addr_type;
    assign accept_build_llc_pdu_type       = cmce_path_w
                                             ? `PDUC_CMCE_D_CONNECT_LLC
                                             : `PDUC_FINAL_LU_ACCEPT_LLC;
    assign accept_build_random_access_flag = `PDUC_FINAL_LU_ACCEPT_RA;
    assign accept_build_aach_pattern       = cmce_path_w
                                             ? `PDUC_CMCE_D_CONNECT_AACH
                                             : `PDUC_FINAL_LU_ACCEPT_AACH;
    assign accept_build_mm_pdu_bits        =
        lat_raw_mode_flag ? lat_raw_mm_bits : dloc_mm_bits_w;
    /* MLE-PD: raw-mode uses staged value (defaulted to MM=001 by mailbox
     * decode); legacy dloc path is always MM. */
    assign accept_build_mle_pd             =
        lat_raw_mode_flag ? lat_raw_mle_pd : 3'b001;
    assign accept_build_mm_pdu_len_bits    =
        lat_raw_mode_flag ? lat_raw_mm_len  : dloc_mm_len_w;
    assign accept_build_scramble_init      = cfg_scramble_init;
    assign accept_build_ns                 =
        lat_raw_mode_flag ? lat_raw_ns : 1'b0;
    assign accept_build_nr                 =
        lat_raw_mode_flag ? lat_raw_nr : 1'b0;

    // -------------------------------------------------------------------------
    // FSM — Phase X.6 minimal trigger machine, builder pipeline external.
    //
    //   S_IDLE              — wait for U-ITSI-DETACH or SW-driven ACCEPT GO.
    //   S_DETACH_NOOP       — pulse detach_pulse, return idle.
    //   S_BUILD_ACCEPT_REQ  — pulse accept_build_req for 1 cycle.
    //   S_BUILD_ACCEPT_WAIT — wait for accept_build_done from shared builder.
    //   S_DELIVER_ACCEPT    — emit req_valid + accept_pulse.
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE              = 3'd0;
    localparam [2:0] S_DETACH_NOOP       = 3'd1;
    localparam [2:0] S_BUILD_ACCEPT_REQ  = 3'd2;
    localparam [2:0] S_BUILD_ACCEPT_WAIT = 3'd3;
    localparam [2:0] S_DELIVER_ACCEPT    = 3'd4;
    reg [2:0] state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            lat_addr_type          <= 3'd0;
            lat_ssi                <= 24'd0;
            lat_detach_ssi         <= 24'd0;
            lat_raw_mode_flag      <= 1'b0;
            lat_raw_mm_bits        <= 128'd0;
            lat_raw_mle_pd         <= 3'b001;
            lat_raw_mm_len         <= 8'd0;
            lat_raw_ns             <= 1'b0;
            lat_raw_nr             <= 1'b0;
            accept_build_req       <= 1'b0;
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
            accept_build_req <= 1'b0;
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
                busy <= 1'b0;
                if (ul_detach_valid) begin
                    lat_detach_ssi <= ul_detach_ssi;
                    busy           <= 1'b1;
                    state          <= S_DETACH_NOOP;
                end else if (mb_go_pulse) begin
                    lat_ssi           <= mb_ssi;
                    lat_addr_type     <= mb_addr_type;
                    lat_raw_mode_flag <= mb_raw_mode_flag;
                    lat_raw_mm_bits   <= mb_raw_mm_bits;
                    lat_raw_mle_pd    <= (mb_raw_mle_pd == 3'b000) ? 3'b001
                                                                   : mb_raw_mle_pd;
                    lat_raw_mm_len    <= mb_raw_mm_len;
                    lat_raw_ns        <= mb_raw_ns;
                    lat_raw_nr        <= mb_raw_nr;
                    busy              <= 1'b1;
                    state             <= S_BUILD_ACCEPT_REQ;
                end
            end

            // -----------------------------------------------------------------
            S_DETACH_NOOP: begin
                detach_pulse <= 1'b1;
                state        <= S_IDLE;
            end

            // -----------------------------------------------------------------
            S_BUILD_ACCEPT_REQ: begin
                accept_build_req <= 1'b1;
                state            <= S_BUILD_ACCEPT_WAIT;
            end

            S_BUILD_ACCEPT_WAIT: begin
                if (accept_build_done) begin
                    req_coded_bits         <= accept_build_coded;
                    req_pdu_type           <= `PDUC_FINAL_LU_ACCEPT_FMT;  // SCH_F
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
