// =============================================================================
// tetra_dl_pdu_builder.v
//
// Phase X.6 — Shared DL-PDU build pipeline.
//
// One instance of {basic_slotgrant_encoder, mac_resource_dl_builder,
// sch_f_encoder} with a thin sequencer that turns a single build-request
// pulse into a 1-cycle done pulse carrying the 432-bit type-5 coded SCH/F
// bitstream.  Replaces the two duplicate pipelines that lived inside
// tetra_mle_registration_fsm.v (Final ACCEPT) and tetra_pre_reply_slotgrant.v
// (Pre-Reply slot-grant) before X.6.
//
// Slice budget rationale: the SCH/F encoder is ~800 LUT / 1100 FF; the
// MAC-RESOURCE builder is ~120 LUT / 320 FF; the basic-slot-grant encoder
// is combinational.  Each of the two former call-sites instantiated all
// three — the 97.65 % util headline was driven by the ~1900 LUT duplication
// of the SCH/F + MAC-RESOURCE pair.  Sharing one pipeline buys back roughly
// half the SCH/F + MAC-RESOURCE area without changing on-air content.
//
// Pipeline stages:
//
//   S_IDLE        — wait for `req_valid` (1-cycle pulse).  Latch all
//                   request fields; no encoder action this cycle.
//   S_BUILD       — pulse mac_resource_dl_builder.start; spin until
//                   builder.valid.
//   S_PACK        — latch builder.pdu_bits into lat_info_bits.  Pulse
//                   sch_f_encoder.encode_start one cycle later (gives
//                   builder one cycle to drop valid before next start).
//   S_ENC         — wait for sch_f_encoder.coded_valid; latch coded
//                   into `coded_bits` output reg.
//   S_DONE        — drive `done = 1` for exactly 1 cycle; return to idle.
//
// Throughput:
//   builder      ~6 cyc
//   sch_f         991 cyc (CRC 268 + RCPC 288 + scramble 432 + 3 fixed)
//   total      ~1000 cyc ≈ 10 µs @ 100 MHz
//   ITSI-Attach event cadence is >14 ms (Frag-1 / Frag-2 / mb_go_pulse) so
//   sequential sharing has zero air-side throughput cost — see top.v
//   arbiter logic for collision handling.
//
// Bit-identity: the three internal encoder instances are bit-identical
// to the deleted in-FSM copies in mle_registration_fsm.v / pre_reply_
// slotgrant.v; tb_dl_pdu_builder + tb_pre_reply_slotgrant pin both
// pre-X.6 fixtures (Gold-Ref MM-Body + AL-SETUP + slot_grant_element=
// 8'h00, granting_delay=0 — Gold-Match per project_slot_grant_drift.md).
//
// Coding rules (Verilog-2001 strict):
//   R1   one always block per FSM
//   R4   async active-low reset
//   R10  @(*) for combinational
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_dl_pdu_builder (
    input  wire         clk,
    input  wire         rst_n,

    // Build request — 1-cycle pulse on `req_valid`; all req_* fields must
    // be stable on the same cycle.  Builder rejects new requests while busy
    // (caller must respect `busy`).
    input  wire         req_valid,
    input  wire [23:0]  req_ssi,
    input  wire [2:0]   req_addr_type,
    input  wire [3:0]   req_llc_pdu_type,
    input  wire         req_random_access_flag,
    input  wire [127:0] req_mm_pdu_bits,
    input  wire [7:0]   req_mm_pdu_len_bits,
    /* MLE protocol discriminator — 3-bit. 0b001=MM, 0b010=CMCE. 0 = default MM. */
    input  wire [2:0]   req_mle_pd,
    input  wire [31:0]  req_scramble_init,
    // Phase Y.1.c' — additive LLC sequence numbers for stop-and-wait
    // protocols (Group-Attach reply path).  Existing callers leave these
    // tied to 0 → bit-identical to the pre-Y.1 build (tb_dl_pdu_builder
    // 7/7 PASS preserved).  Pass-through to mac_resource_dl_builder.ns/.nr.
    input  wire         req_ns,
    input  wire         req_nr,

    // 1-cycle pulse on transition into S_DONE; `coded_bits` valid this cycle
    // and stays latched until the next request completes.
    output reg          done,
    output reg  [431:0] coded_bits,

    // High while a build is in flight (S_BUILD / S_PACK / S_ENC / S_DONE).
    output wire         busy
);

    // -------------------------------------------------------------------------
    // Latched request fields
    // -------------------------------------------------------------------------
    reg [23:0]  lat_ssi;
    reg [2:0]   lat_addr_type;
    reg [3:0]   lat_llc_pdu_type;
    reg         lat_random_access_flag;
    reg [127:0] lat_mm_pdu_bits;
    reg [7:0]   lat_mm_pdu_len_bits;
    reg [2:0]   lat_mle_pd;
    reg [31:0]  lat_scramble_init;
    reg         lat_ns;
    reg         lat_nr;

    // -------------------------------------------------------------------------
    // Stage A — basic slot-grant element (capacity_allocation=0, granting_delay=0).
    // Gold-Reference (verified via decode_dl on GOLD_DL_…GRUPPENRUF.wav, 5 Bursts:
    // #775/#783/#4803/#4811/#5343) sendet sg_element=0x00 auf BEIDEN Reply-Slots
    // (Pre-Reply LI=7 + Final-Accept LI=21/16).  Pre-X.6 hardcodete granting_delay=1
    // → sg_element=0x01 — stiller Bit-Drift, wahrscheinliche Ursache fuer
    // MS-Rejection des Z.17 GroupAcks (siehe project_slot_grant_drift.md).
    // -------------------------------------------------------------------------
    wire [7:0] slotgrant_packed_w;
    tetra_basic_slotgrant_encoder u_slotgrant_pkt (
        .capacity_allocation (4'd0),
        .granting_delay      (4'd0),
        .packed_element      (slotgrant_packed_w)
    );

    // -------------------------------------------------------------------------
    // Stage B — MAC-RESOURCE DL builder (PDU_BITS=268).
    // -------------------------------------------------------------------------
    reg          builder_start;
    wire [267:0] builder_pdu_w;
    wire         builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268),
        .LLC_BUF_BITS(144)        // BL-ADATA + MLE-PD + 100-bit MM body fits
    ) u_mac_res (
        .clk                          (clk),
        .rst_n                        (rst_n),
        .start                        (builder_start),
        .ssi                          (lat_ssi),
        .addr_type                    (lat_addr_type),
        .ns                           (lat_ns),
        .nr                           (lat_nr),
        .llc_pdu_type                 (lat_llc_pdu_type),
        .random_access_flag           (lat_random_access_flag),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        .slot_granting_flag           (1'b1),
        .slot_granting_element        (slotgrant_packed_w),
        /* Phase 7 G.5+ — bei CMCE-D-PDUs (D-CONNECT / D-TX-GRANTED) MS
         * eine TCH-Slot-Allokation in MAC-RESOURCE mitgeben, damit MS
         * weiß auf welchem TN sie Voice senden soll.  Default-Layout:
         *   alloc_type=00 (Allocate)
         *   ts_assigned=0010 (= TS3 = TN=2 air)
         *   ul_dl=11 (Both)
         *   clch=0, cell_chg=0
         *   carrier_num=1530 (= 0x5FA, cell-spezifisch)
         *   ext_flag=0, mon_pattern=00
         * Total 25 bits, left-aligned bei [31:7] = 32'h0B17E800.
         * mle_pd != CMCE → ca_flag=0 (bit-identisch zum mm=2/mm=11 Pfad). */
        .chan_alloc_flag              ((lat_mle_pd == 3'b010) ? 1'b1 : 1'b0),
        .chan_alloc_element           ((lat_mle_pd == 3'b010) ? 32'h0B17_E800
                                                                : 32'd0),
        .chan_alloc_element_len       ((lat_mle_pd == 3'b010) ? 5'd25 : 5'd0),
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
        .mm_pdu_bits                  (lat_mm_pdu_bits),
        .mm_pdu_len_bits              (lat_mm_pdu_len_bits),
        .mle_pd_in                    (lat_mle_pd),
        .pdu_bits                     (builder_pdu_w),
        .valid                        (builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // Stage C — SCH/F channel encoder (268 → 432 bits).
    // -------------------------------------------------------------------------
    reg          encode_start;
    reg  [267:0] lat_info_bits;
    wire [431:0] coded_w;
    wire         coded_valid_w;

    tetra_sch_f_encoder u_sch_f (
        .clk           (clk),
        .rst_n         (rst_n),
        .encode_start  (encode_start),
        .info_bits     (lat_info_bits),
        .scramble_init (lat_scramble_init),
        .coded_bits    (coded_w),
        .coded_valid   (coded_valid_w)
    );

    // -------------------------------------------------------------------------
    // Sequencer FSM
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_BUILD = 3'd1;
    localparam [2:0] S_PACK  = 3'd2;
    localparam [2:0] S_ENC   = 3'd3;
    localparam [2:0] S_DONE  = 3'd4;

    reg [2:0] state;

    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            lat_ssi                <= 24'd0;
            lat_addr_type          <= 3'd0;
            lat_llc_pdu_type       <= 4'd0;
            lat_random_access_flag <= 1'b0;
            lat_mm_pdu_bits        <= 128'd0;
            lat_mm_pdu_len_bits    <= 8'd0;
            lat_mle_pd             <= 3'b001;
            lat_scramble_init      <= 32'd0;
            lat_ns                 <= 1'b0;
            lat_nr                 <= 1'b0;
            lat_info_bits          <= 268'd0;
            builder_start          <= 1'b0;
            encode_start           <= 1'b0;
            coded_bits             <= 432'd0;
            done                   <= 1'b0;
        end else begin
            // Default 1-cycle strobes
            builder_start <= 1'b0;
            encode_start  <= 1'b0;
            done          <= 1'b0;

            case (state)
            S_IDLE: begin
                if (req_valid) begin
                    lat_ssi                <= req_ssi;
                    lat_addr_type          <= req_addr_type;
                    lat_llc_pdu_type       <= req_llc_pdu_type;
                    lat_random_access_flag <= req_random_access_flag;
                    lat_mm_pdu_bits        <= req_mm_pdu_bits;
                    lat_mm_pdu_len_bits    <= req_mm_pdu_len_bits;
                    lat_mle_pd             <= (req_mle_pd == 3'b000) ? 3'b001
                                                                     : req_mle_pd;
                    lat_scramble_init      <= req_scramble_init;
                    lat_ns                 <= req_ns;
                    lat_nr                 <= req_nr;
                    builder_start          <= 1'b1;
                    state                  <= S_BUILD;
                end
            end

            S_BUILD: begin
                if (builder_valid_w) begin
                    lat_info_bits <= builder_pdu_w;
                    state         <= S_PACK;
                end
            end

            S_PACK: begin
                // Kick SCH/F encoder one cycle after PDU latched
                encode_start <= 1'b1;
                state        <= S_ENC;
            end

            S_ENC: begin
                if (coded_valid_w) begin
                    coded_bits <= coded_w;
                    state      <= S_DONE;
                end
            end

            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
