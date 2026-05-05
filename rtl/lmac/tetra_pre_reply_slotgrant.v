// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase Z.4 — Pre-Reply Slot-Grant Mini-FSM, dual-path (mm-type-switched).
//
// Trigger: `frag1_pulse` (1-cycle pulse from MAC-ACCESS parser on Frag-1
// detection).  The mm-type latched on the same cycle (`mm_pdu_type[3:0]`,
// sourced from `ul_llc_mm_pdu_type_w` at top.v) selects the reply path:
//
//   mm_pdu_type == 4'd2 → PDUC_PRE_REPLY_SLOTGRANT_LU  (ITSI-Attach)
//                          SCH/F 432-bit via SHARED tetra_dl_pdu_builder
//                          (slot_granting_flag=1, sg_element=0x01 — pre-Z.3
//                          working bit-pattern, MTP3550 in our cell expects
//                          SCH/F here, otherwise no Frag-2 follow-up).
//
//   mm_pdu_type == 4'd7 → PDUC_PRE_REPLY_SLOTGRANT_GRP (Group-Switch)
//                          SCH/HD 216-bit via INTERNAL builder/encoder
//                          (slot_granting_flag=1, sg_element=0x00 —
//                          Gold-Ref bit-pattern per
//                          reference_gold_group_switch_burst_timeline.md).
//
//   any other mm_pdu_type → no push (defensive default; counter-only,
//                            no DL transmission).
//
// History:
//   - cad69e0 (pre-Z.3): mm=2 SCH/F path, working on the MS.
//   - Z.3 (regression):  ALL mm-types switched to SCH/HD with sg_element=0x00.
//                        The MS stopped sending Frag-2 → mm=2 attach broken.
//   - Z.4 (this revision): keep both paths, switch by mm-type at runtime.
//                          mm=2 path is bit-identical to cad69e0
//                          (slot_granting_flag=1, sg_element=0x01, SCH/F);
//                          mm=7 path uses the Z.3 SCH/HD pipeline.
//
// Architecture:
//
//   ┌──────────────────────────── frag1_pulse_w ────────────────────────────┐
//   │                                                                       │
//   │           latch {ul_ssi, cfg_mcch_tn, cfg_scramble_init, mm_pdu_type} │
//   │                                                                       │
//   │                          mm_pdu_type == 2 ?                           │
//   │                          /                \                          │
//   │                         /                  \                         │
//   │   slotgrant_build_req=1                  builder_start_local=1        │
//   │  (shared SCH/F pipeline)                 (internal MAC-RES + SCH/HD)  │
//   │      ↓ build_done                            ↓ coded_valid_w          │
//   │  lat_coded_schf[431:0]                   lat_coded_schhd[215:0]       │
//   │                                                                       │
//   │                ────────► S_PUSH ◄────────                             │
//   │                          wr_slotgrant_*  (queue)                      │
//   └───────────────────────────────────────────────────────────────────────┘
//
// Coding rules (Verilog-2001 strict):
//   R1   one always block per FSM
//   R4   async active-low reset
//   R10  @(*) for combinational
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tetra_pre_reply_slotgrant (
    input  wire         clk_sys,
    input  wire         rst_n_sys,

    // Frag-1 trigger from MAC-ACCESS parser (1-cycle pulse on clk_sys)
    input  wire         frag1_pulse,
    input  wire [23:0]  ul_ssi,
    // Phase Z.4 — mm-type from MAC-ACCESS parser (LLC-walker decoded).
    // Latched on the same cycle as frag1_pulse to select reply path.
    input  wire [3:0]   mm_pdu_type,

    // MCCH slot (CDC-resynced from AXI), pre-reply target TN
    input  wire [1:0]   cfg_mcch_tn,
    input  wire [31:0]  cfg_scramble_init,

    // ----------------------------------------------------------------------
    // mm=2 SCH/F path — shared tetra_dl_pdu_builder build-request bus
    //   slotgrant_build_req           1-cyc pulse
    //   slotgrant_build_*             field plane (constants + lat_ssi)
    //   slotgrant_build_done          1-cyc pulse from builder
    //   slotgrant_build_coded         432-bit SCH/F coded
    //   slotgrant_build_grant_blocked builder busy / higher-prio winner
    // ----------------------------------------------------------------------
    output reg          slotgrant_build_req,
    output wire [23:0]  slotgrant_build_ssi,
    output wire [2:0]   slotgrant_build_addr_type,
    output wire [3:0]   slotgrant_build_llc_pdu_type,
    output wire         slotgrant_build_random_access_flag,
    output wire [127:0] slotgrant_build_mm_pdu_bits,
    output wire [7:0]   slotgrant_build_mm_pdu_len_bits,
    output wire [31:0]  slotgrant_build_scramble_init,
    input  wire         slotgrant_build_done,
    input  wire [431:0] slotgrant_build_coded,
    input  wire         slotgrant_build_grant_blocked,

    // DL-Signal-Queue producer (MLE slot — muxed at top.v with MLE-FSM,
    // GroupAck queue-side path).
    output reg          wr_slotgrant_valid_sys,
    output wire [431:0] wr_slotgrant_coded_sys,
    output wire [1:0]   wr_slotgrant_pdu_type_sys,
    output wire [1:0]   wr_slotgrant_target_tn_sys,

    // Stats — saturating 16-bit counters
    output reg  [15:0]  push_cnt_sys,
    output reg  [15:0]  drop_cnt_sys
);

    // -------------------------------------------------------------------------
    // Edge-detect on frag1_pulse (defensive — upstream provides 1-cyc pulse
    // already, but double-trigger protection costs nothing).
    // -------------------------------------------------------------------------
    reg frag1_pulse_q;
    wire frag1_edge_w = frag1_pulse & ~frag1_pulse_q;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) frag1_pulse_q <= 1'b0;
        else            frag1_pulse_q <= frag1_pulse;
    end

    // -------------------------------------------------------------------------
    // Latches (shared across both paths)
    // -------------------------------------------------------------------------
    reg [23:0]  lat_ssi;
    reg [1:0]   lat_target_tn;
    reg [31:0]  lat_scramble_init;
    reg [3:0]   lat_mm_type;

    // mm=2 SCH/F coded-payload latch
    reg [431:0] lat_coded_schf;
    // mm=7 SCH/HD coded-payload latch
    reg [215:0] lat_coded_schhd;

    // -------------------------------------------------------------------------
    // mm=2 path — shared builder request field plane.  All constants are the
    // pre-Z.3 cad69e0-bit-identity values (RA=1, AL-SETUP, slot_granting=1
    // hardcoded inside dl_pdu_builder + element=0x01 from basic_slotgrant
    // encoder also internal to dl_pdu_builder).  We supply only the SSI,
    // scramble seed and addressing class.
    // -------------------------------------------------------------------------
    assign slotgrant_build_ssi                = lat_ssi;
    assign slotgrant_build_addr_type          = `PDUC_PRE_REPLY_SLOTGRANT_LU_ADDRTYPE;
    assign slotgrant_build_llc_pdu_type       = `PDUC_PRE_REPLY_SLOTGRANT_LU_LLC;
    assign slotgrant_build_random_access_flag = `PDUC_PRE_REPLY_SLOTGRANT_LU_RA;
    assign slotgrant_build_mm_pdu_bits        = 128'd0;
    assign slotgrant_build_mm_pdu_len_bits    = 8'd0;
    assign slotgrant_build_scramble_init      = lat_scramble_init;

    // -------------------------------------------------------------------------
    // mm=7 path — internal MAC-RESOURCE 124-bit builder + SCH/HD encoder.
    //   slot_granting_flag=1, sg_element=0x00 (Gold-Ref bit-identity per
    //   reference_gold_group_switch_burst_timeline.md).
    // -------------------------------------------------------------------------
    reg          builder_start;
    wire [123:0] builder_pdu_w;
    wire         builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(124),
        .LLC_BUF_BITS(16)
    ) u_mac_res (
        .clk                          (clk_sys),
        .rst_n                        (rst_n_sys),
        .start                        (builder_start),
        .ssi                          (lat_ssi),
        .addr_type                    (`PDUC_PRE_REPLY_SLOTGRANT_GRP_ADDRTYPE),
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (`PDUC_PRE_REPLY_SLOTGRANT_GRP_LLC),
        .random_access_flag           (`PDUC_PRE_REPLY_SLOTGRANT_GRP_RA),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        // Gold raw bits decode to flags=010 (sg_flag=1) + sg_element=0x00.
        .slot_granting_flag           (1'b1),
        .slot_granting_element        (8'h00),
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
        .mm_pdu_bits                  (128'd0),
        .mm_pdu_len_bits              (8'd0),
        .pdu_bits                     (builder_pdu_w),
        .valid                        (builder_valid_w)
    );

    reg          encode_start;
    wire [215:0] coded_w;
    wire         coded_valid_w;

    tetra_sch_hd_encoder u_sch_hd (
        .clk           (clk_sys),
        .rst_n         (rst_n_sys),
        .encode_start  (encode_start),
        .info_bits     (builder_pdu_w),
        .scramble_init (lat_scramble_init),
        .coded_bits    (coded_w),
        .coded_valid   (coded_valid_w)
    );

    // -------------------------------------------------------------------------
    // FSM — unified across both paths.  S_BUILD/S_ENC are shared states;
    // the latched mm-type drives which child block is sourcing the
    // build/encode events.
    //
    //   S_IDLE  — wait for frag1_edge_w → latch trigger inputs, kick path
    //             {mm=2: shared-builder request | mm=7: local builder start}
    //   S_BUILD — wait for {mm=2: slotgrant_build_done | mm=7: builder_valid_w}
    //             then either go straight to S_PUSH (mm=2 already coded by
    //             shared dl_pdu_builder) or kick local SCH/HD encoder (mm=7)
    //   S_ENC   — only entered for mm=7; wait for coded_valid_w
    //   S_PUSH  — pulse wr_slotgrant_valid_sys for 1 cycle
    // -------------------------------------------------------------------------
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_BUILD = 2'd1;
    localparam [1:0] S_ENC   = 2'd2;
    localparam [1:0] S_PUSH  = 2'd3;

    reg [1:0] state;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            state                  <= S_IDLE;
            lat_ssi                <= 24'd0;
            lat_target_tn          <= 2'd0;
            lat_scramble_init      <= 32'd0;
            lat_mm_type            <= 4'd0;
            lat_coded_schf         <= 432'd0;
            lat_coded_schhd        <= 216'd0;
            slotgrant_build_req    <= 1'b0;
            builder_start          <= 1'b0;
            encode_start           <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;
            push_cnt_sys           <= 16'd0;
            drop_cnt_sys           <= 16'd0;
        end else begin
            // Default 1-cycle strobes
            slotgrant_build_req    <= 1'b0;
            builder_start          <= 1'b0;
            encode_start           <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;

            case (state)
            S_IDLE: begin
                if (frag1_edge_w) begin
                    // Latch trigger inputs — common for both paths.
                    lat_ssi             <= ul_ssi;
                    lat_target_tn       <= cfg_mcch_tn;
                    lat_scramble_init   <= cfg_scramble_init;
                    lat_mm_type         <= mm_pdu_type;

                    if (mm_pdu_type == 4'd2) begin
                        // mm=2 path — request shared SCH/F builder.  If the
                        // arbiter says blocked (MLE/GroupAck wins or builder
                        // busy), drop this Frag-1 pre-reply and stay IDLE.
                        if (slotgrant_build_grant_blocked) begin
                            if (drop_cnt_sys != 16'hFFFF)
                                drop_cnt_sys <= drop_cnt_sys + 16'd1;
                        end else begin
                            slotgrant_build_req <= 1'b1;
                            state               <= S_BUILD;
                        end
                    end else if (mm_pdu_type == 4'd7) begin
                        // mm=7 path — kick local SCH/HD pipeline (no
                        // arbitration; pipeline is exclusive to this FSM).
                        builder_start <= 1'b1;
                        state         <= S_BUILD;
                    end else begin
                        // Defensive default — unknown mm-type.  Count as
                        // drop and stay IDLE (no wr_slotgrant push).
                        if (drop_cnt_sys != 16'hFFFF)
                            drop_cnt_sys <= drop_cnt_sys + 16'd1;
                    end
                end
            end

            S_BUILD: begin
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;

                if (lat_mm_type == 4'd2) begin
                    // mm=2 — wait for shared-builder coded payload.
                    if (slotgrant_build_done) begin
                        lat_coded_schf <= slotgrant_build_coded;
                        state          <= S_PUSH;
                    end
                end else begin
                    // mm=7 — wait for MAC-RESOURCE PDU then kick SCH/HD.
                    if (builder_valid_w) begin
                        encode_start <= 1'b1;
                        state        <= S_ENC;
                    end
                end
            end

            S_ENC: begin
                // Only mm=7 enters S_ENC.
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (coded_valid_w) begin
                    lat_coded_schhd <= coded_w;
                    state           <= S_PUSH;
                end
            end

            S_PUSH: begin
                wr_slotgrant_valid_sys <= 1'b1;
                if (push_cnt_sys != 16'hFFFF)
                    push_cnt_sys <= push_cnt_sys + 16'd1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational outputs to DL-Signal-Queue
    //   mm=2:  coded[431:0]  = lat_coded_schf  (SCH/F 432-bit, full)
    //          pdu_type      = PDUC_PRE_REPLY_SLOTGRANT_LU_FMT  (= SCH/F)
    //   mm=7:  coded[431:0]  = {216'd0, lat_coded_schhd}  (SCH/HD LSB-aligned)
    //          pdu_type      = PDUC_PRE_REPLY_SLOTGRANT_GRP_FMT (= SCH/HD)
    // target_tn is the latched cfg_mcch_tn for both.
    // -------------------------------------------------------------------------
    // Z.8-Fix 2026-05-05: SCH/HD-Pfad muss MSB-aligned in den 432-bit-Bus
    // gepackt werden — der Scheduler liest BKN1 aus head_coded[431:216].
    // Vorher LSB-aligned ({216'd0, x}) → Scheduler bekam 216 Nullen → SCH/HD-
    // CRC fail → MS verwirft Pre-Reply → kein Frag-2 für mm=7-Demands.
    assign wr_slotgrant_coded_sys     = (lat_mm_type == 4'd2)
                                          ? lat_coded_schf
                                          : {lat_coded_schhd, 216'd0};
    assign wr_slotgrant_pdu_type_sys  = (lat_mm_type == 4'd2)
                                          ? `PDUC_PRE_REPLY_SLOTGRANT_LU_FMT
                                          : `PDUC_PRE_REPLY_SLOTGRANT_GRP_FMT;
    assign wr_slotgrant_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
