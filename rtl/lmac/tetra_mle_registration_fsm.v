// =============================================================================
// tetra_mle_registration_fsm.v
//
// Phase Z.5 — REJECT path (mm=4 D-LOC-UPDATE-REJECT, SCH/HD blk1).
//
// Y.1.x history:
//   X.4 made this a thin SW-trigger machine for the ACCEPT path.
//   X.6 pulled the {basic_slotgrant_encoder, mac_resource_dl_builder,
//       sch_f_encoder} ACCEPT triple OUT of this module (shared in
//       tetra_dl_pdu_builder.v, arbitrated against
//       tetra_pre_reply_slotgrant.v + GroupAck at the top level).
//   X.7 cleanup: removed dead use_sw_body mux + lat_la / lat_loc_upd_type /
//       lat_gila_* fallback latches.
//   Z.5 (this revision): added second branch S_BUILD_REJECT_*.  When
//       `mb_result != 0` on `mb_go_pulse` the FSM no longer triggers the
//       shared SCH/F builder; instead it drives the dedicated mm=4
//       D-LOC-UPDATE-REJECT encoder (8-bit MM body) into a LOCAL
//       MAC-RESOURCE 124-bit builder + SCH/HD encoder pipeline (PDUC_FINAL_
//       LU_REJECT_FMT = SCH/HD blk1 per rtl/include/tetra_pdu_class.vh).
//
//       The resulting 216-bit coded payload is pushed LSB-aligned in the
//       432-bit `req_coded_bits` slot with `req_pdu_type = SCH_HD` —
//       same convention as tetra_pre_reply_slotgrant.v's mm=7 path.
//
//       REJECT completion fires `drop_pulse` (existing counter wire that
//       was tied to 0); ACCEPT completion still fires `accept_pulse`.
//
// Trigger flow:
//   1. SW pre-stages D-LOC-UPDATE-{ACCEPT|REJECT} fields into the Reply-
//      Pull-Mailbox via AXI-Lite REG_REPLY_INDEX/DATA.
//        - W3 = result : 0 = ACCEPT, 1 = reject-temp, 2 = reject-perm.
//   2. SW pulses REG_REPLY_GO -> 1-cycle clk_sys mb_go_pulse.
//   3. FSM samples `mb_result` on the GO cycle and branches:
//        result == 0 → S_BUILD_ACCEPT_REQ → shared dl_pdu_builder (SCH/F)
//        result != 0 → S_BUILD_REJECT_REQ → local SCH/HD pipeline
//   4. On builder/encoder done the 432-bit codeword is delivered via
//      req_valid + req_coded_bits + req_pdu_type{SCH_F|SCH_HD}.
//
// Detach path remains a no-op telemetry stub — owned by SW since X.5.
//
// REJECT-cause mapping (mb_result -> reject_cause, ETSI Table 16.43):
//   mb_result = 1 (reject-temp)  -> cause = 3'd2 ("no resources available")
//   mb_result = 2 (reject-perm)  -> cause = 3'd1 ("illegal MS")
//   mb_result = 3 (reserved)     -> cause = 3'd3 ("unspecified")
//   mb_result = 0 never reaches the REJECT branch (ACCEPT path taken).
//
// M2 ACCEPT bit-identity guarantee preserved: the ACCEPT path is byte-
// for-byte identical to pre-Z.5 — the reject pipeline only fires when
// SW writes a non-zero result into W3, which never happens for the
// gold-ref M2 attach (db.tsv enrolls MTP3550 ISSI → result=0).
// Verified by tb_d_location_update_encoder MM-body PASS unchanged.
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
    // Phase X.6 — Build-request to shared tetra_dl_pdu_builder (ACCEPT path).
    // -----------------------------------------------------------------
    output reg                         accept_build_req,
    output wire [23:0]                 accept_build_ssi,
    output wire [2:0]                  accept_build_addr_type,
    output wire [3:0]                  accept_build_llc_pdu_type,
    output wire                        accept_build_random_access_flag,
    output wire [127:0]                accept_build_mm_pdu_bits,
    output wire [7:0]                  accept_build_mm_pdu_len_bits,
    output wire [31:0]                 accept_build_scramble_init,
    input  wire                        accept_build_done,
    input  wire [431:0]                accept_build_coded,

    // -----------------------------------------------------------------
    // DL signalling-queue request — 1-cycle pulse carrying the full 432-bit
    // codeword plus type/target metadata.  Z.5: req_pdu_type is now either
    // SCH_F (ACCEPT) or SCH_HD (REJECT, LSB-aligned 216-bit coded).
    // -----------------------------------------------------------------
    output reg                         req_valid,
    output reg  [431:0]                req_coded_bits,
    output reg  [1:0]                  req_pdu_type,    // 00=SCH_F, 01=SCH_HD
    output reg  [1:0]                  req_target_tn,
    output reg                         req_second_pdu_present,
    output reg                         req_second_pdu_nr,

    // -----------------------------------------------------------------
    // Debug / status
    // -----------------------------------------------------------------
    output reg                         busy,
    output reg                         accept_pulse,   // 1 cyc on ACCEPT built
    output reg                         drop_pulse,     // 1 cyc on REJECT built (Z.5)
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
        cfg_la, cfg_energy_saving_info, mb_la, mb_encryption,
        mb_auth_result, 1'b0
    };
    // synthesis translate_on

    // -------------------------------------------------------------------------
    // Latched trigger fields — common across ACCEPT and REJECT branches.
    // The S_IDLE entry latches everything the encoder pipelines need so SW
    // can immediately stage the next reply payload without breaking the
    // current encode.
    // -------------------------------------------------------------------------
    reg [2:0]   lat_addr_type;
    reg [23:0]  lat_ssi;
    reg [31:0]  lat_scramble_init;   // Z.5 — REJECT pipeline needs its own copy
    reg [23:0]  lat_detach_ssi;

    // -------------------------------------------------------------------------
    // ACCEPT-path D-LOCATION-UPDATE encoder (single instance).  Drives the
    // 102/36-bit MM body straight from the Reply-Pull-Mailbox.
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
    // ACCEPT build-request field plane — combinational from latched values.
    // -------------------------------------------------------------------------
    assign accept_build_ssi                = lat_ssi;
    assign accept_build_addr_type          = lat_addr_type;
    assign accept_build_llc_pdu_type       = `PDUC_FINAL_LU_ACCEPT_LLC;
    assign accept_build_random_access_flag = `PDUC_FINAL_LU_ACCEPT_RA;
    assign accept_build_mm_pdu_bits        = dloc_mm_bits_w;
    assign accept_build_mm_pdu_len_bits    = dloc_mm_len_w;
    assign accept_build_scramble_init      = cfg_scramble_init;

    // -------------------------------------------------------------------------
    // Z.5 REJECT pipeline (LOCAL — not arbitrated, exclusive to MLE-FSM).
    //
    // mm=4 D-LOC-UPDATE-REJECT MM body is 8 bits (PDU_TYPE=7 + cause(3) +
    // o-bit=0).  The MAC-RESOURCE wrapper packs that into a 124-bit SCH/HD
    // PDU; tetra_sch_hd_encoder produces 216-bit type-5 coded.
    //
    // Reject-cause derivation: tetra_d_location_update_reject_encoder takes
    // a 3-bit `reject_cause`.  mb_result is 2-bit (W3[1:0]); we expand:
    //
    //   mb_result == 1 (reject-temp)  -> cause = 3'd2 (no resources)
    //   mb_result == 2 (reject-perm)  -> cause = 3'd1 (illegal MS)
    //   mb_result == 3 (reserved)     -> cause = 3'd3 (unspecified)
    //   mb_result == 0 -> never enters REJECT path (ACCEPT taken).
    //
    // Latched on the same cycle as lat_ssi etc, so the REJECT branch is
    // independent of further mailbox writes.
    // -------------------------------------------------------------------------
    reg  [2:0]   lat_reject_cause;

    wire [127:0] reject_mm_bits_w;
    wire [7:0]   reject_mm_len_w;

    tetra_d_location_update_reject_encoder u_reject_enc (
        .reject_cause (lat_reject_cause),
        .pdu_bits_mm  (reject_mm_bits_w),
        .pdu_len_bits (reject_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // Local MAC-RESOURCE 124-bit DL builder for REJECT (PDU_BITS=124).
    // Constants follow PDUC_FINAL_LU_REJECT_*: BL-ADATA, addr_type=SSI,
    // RA=0, slot_granting=0 (no grant in REJECT — caller already had MS
    // attention via Pre-Reply slot-grant during the demand exchange).
    // -------------------------------------------------------------------------
    reg          reject_builder_start;
    wire [123:0] reject_builder_pdu_w;
    wire         reject_builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS     (124),
        .LLC_BUF_BITS (16)
    ) u_reject_mac_res (
        .clk                          (clk),
        .rst_n                        (rst_n),
        .start                        (reject_builder_start),
        .ssi                          (lat_ssi),
        .addr_type                    (lat_addr_type),
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (`PDUC_FINAL_LU_REJECT_LLC),
        .random_access_flag           (`PDUC_FINAL_LU_REJECT_RA),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        .slot_granting_flag           (1'b0),
        .slot_granting_element        (8'd0),
        .chan_alloc_flag              (1'b0),
        .chan_alloc_element           (32'd0),
        .chan_alloc_element_len       (5'd0),
        .second_pdu_valid             (1'b0),
        .second_pdu_length_ind        (6'd0),
        .second_pdu_random_access_flag(1'b0),
        .second_pdu_addr_type         (3'd0),
        .second_pdu_ssi               (24'd0),
        .second_pdu_tl_sdu            (80'd0),
        .second_pdu_tl_sdu_len        (7'd0),
        .second_pdu_pc_flag           (1'b0),
        .second_pdu_pc_element        (4'd0),
        .second_pdu_sg_flag           (1'b0),
        .second_pdu_sg_element        (8'd0),
        .second_pdu_ca_flag           (1'b0),
        .second_pdu_ca_element        (32'd0),
        .second_pdu_ca_element_len    (5'd0),
        .mm_pdu_bits                  (reject_mm_bits_w),
        .mm_pdu_len_bits              (reject_mm_len_w),
        .pdu_bits                     (reject_builder_pdu_w),
        .valid                        (reject_builder_valid_w)
    );

    reg          reject_encode_start;
    wire [215:0] reject_coded_w;
    wire         reject_coded_valid_w;

    tetra_sch_hd_encoder u_reject_sch_hd (
        .clk           (clk),
        .rst_n         (rst_n),
        .encode_start  (reject_encode_start),
        .info_bits     (reject_builder_pdu_w),
        .scramble_init (lat_scramble_init),
        .coded_bits    (reject_coded_w),
        .coded_valid   (reject_coded_valid_w)
    );

    // -------------------------------------------------------------------------
    // FSM — Z.5 dual-branch trigger machine.
    //
    //   S_IDLE              — wait for U-ITSI-DETACH or SW-driven GO.
    //   S_DETACH_NOOP       — pulse detach_pulse, return idle.
    //   S_BUILD_ACCEPT_REQ  — pulse accept_build_req for 1 cycle.
    //   S_BUILD_ACCEPT_WAIT — wait for accept_build_done from shared builder.
    //   S_DELIVER_ACCEPT    — emit req_valid (SCH/F) + accept_pulse.
    //   S_BUILD_REJECT_REQ  — pulse reject_builder_start for 1 cycle.
    //   S_BUILD_REJECT_PACK — wait for reject_builder valid, kick SCH/HD.
    //   S_BUILD_REJECT_ENC  — wait for SCH/HD coded_valid.
    //   S_DELIVER_REJECT    — emit req_valid (SCH/HD LSB-aligned) + drop_pulse.
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE              = 4'd0;
    localparam [3:0] S_DETACH_NOOP       = 4'd1;
    localparam [3:0] S_BUILD_ACCEPT_REQ  = 4'd2;
    localparam [3:0] S_BUILD_ACCEPT_WAIT = 4'd3;
    localparam [3:0] S_DELIVER_ACCEPT    = 4'd4;
    localparam [3:0] S_BUILD_REJECT_REQ  = 4'd5;
    localparam [3:0] S_BUILD_REJECT_PACK = 4'd6;
    localparam [3:0] S_BUILD_REJECT_ENC  = 4'd7;
    localparam [3:0] S_DELIVER_REJECT    = 4'd8;
    reg [3:0] state;

    // mb_result -> 3-bit reject_cause map.  Computed combinationally on the
    // GO cycle so the encoder sees a stable cause as soon as we latch it.
    reg [2:0] cause_from_result_w;
    always @(*) begin
        case (mb_result)
            2'd1: cause_from_result_w = 3'd2;  // reject-temp -> no resources
            2'd2: cause_from_result_w = 3'd1;  // reject-perm -> illegal MS
            2'd3: cause_from_result_w = 3'd3;  // reserved   -> unspecified
            default: cause_from_result_w = 3'd3;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            lat_addr_type          <= 3'd0;
            lat_ssi                <= 24'd0;
            lat_scramble_init      <= 32'd0;
            lat_reject_cause       <= 3'd0;
            lat_detach_ssi         <= 24'd0;
            accept_build_req       <= 1'b0;
            reject_builder_start   <= 1'b0;
            reject_encode_start    <= 1'b0;
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
            // Default 1-cycle strobes — every state may override
            accept_build_req     <= 1'b0;
            reject_builder_start <= 1'b0;
            reject_encode_start  <= 1'b0;
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
                if (ul_detach_valid) begin
                    lat_detach_ssi <= ul_detach_ssi;
                    busy           <= 1'b1;
                    state          <= S_DETACH_NOOP;
                end else if (mb_go_pulse) begin
                    lat_ssi           <= mb_ssi;
                    lat_addr_type     <= mb_addr_type;
                    lat_scramble_init <= cfg_scramble_init;
                    lat_reject_cause  <= cause_from_result_w;
                    busy              <= 1'b1;
                    if (mb_result == 2'd0) begin
                        state <= S_BUILD_ACCEPT_REQ;
                    end else begin
                        state <= S_BUILD_REJECT_REQ;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_DETACH_NOOP: begin
                detach_pulse <= 1'b1;
                state        <= S_IDLE;
            end

            // ---------------------------- ACCEPT path ------------------------
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

            // ---------------------------- REJECT path ------------------------
            S_BUILD_REJECT_REQ: begin
                reject_builder_start <= 1'b1;
                state                <= S_BUILD_REJECT_PACK;
            end

            S_BUILD_REJECT_PACK: begin
                if (reject_builder_valid_w) begin
                    reject_encode_start <= 1'b1;
                    state               <= S_BUILD_REJECT_ENC;
                end
            end

            S_BUILD_REJECT_ENC: begin
                if (reject_coded_valid_w) begin
                    // LSB-align the 216-bit SCH/HD coded payload in the
                    // 432-bit slot — same convention as
                    // tetra_pre_reply_slotgrant.v's mm=7 path.
                    req_coded_bits         <= {216'd0, reject_coded_w};
                    req_pdu_type           <= `PDUC_FINAL_LU_REJECT_FMT;  // SCH_HD
                    req_target_tn          <= cfg_mcch_tn;
                    req_second_pdu_present <= 1'b0;
                    req_second_pdu_nr      <= 1'b0;
                    state                  <= S_DELIVER_REJECT;
                end
            end

            S_DELIVER_REJECT: begin
                req_valid  <= 1'b1;
                drop_pulse <= 1'b1;     // REJECT completion telemetry
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
