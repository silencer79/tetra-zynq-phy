// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase Z.9 — Pre-Reply Slot-Grant Mini-FSM, SINGLE PATH (SCH/HD).
//
// Trigger: `frag1_pulse` (1-cycle pulse from MAC-ACCESS parser on Frag-1
// detection).  Both ITSI-Attach (mm=2) AND Group-Switch (mm=7) build an
// identical 124-bit AL-SETUP MAC-RESOURCE PDU (slot_granting_flag=1,
// slot_granting_element=0x00) and SCH/HD-encode it to 216 bits.  The 216
// bits are MSB-aligned in the 432-bit queue bus
// (`{coded_schhd, 216'd0}`); the scheduler picks BKN1 from
// `head_coded[431:216]` and routes BKN2 to the SYSINFO companion.
// AACH on the carrier slot is `PDUC_PRE_REPLY_SLOTGRANT_AACH=0x0009`
// (signalling-active) via the queue's per-entry AACH-pattern field.
//
// History:
//   - cad69e0 (pre-Z.3): mm=2 SCH/F via shared dl_pdu_builder (sg=0x01).
//   - Z.3 (regression):  ALL mm-types switched to SCH/HD with sg=0x00.
//                        Broke mm=2 Frag-2 retrieval on the MTP3550.
//   - Z.4:               Dual-path — mm=2 kept on SCH/F, mm=7 on SCH/HD.
//                        AACH override on mm=2 SCH/F path was 0x0249 on-air
//                        (Drift #3) and sg_element=0x01 vs Gold's 0x00 (Drift #4).
//   - Z.9 (this rev):    Collapse to single SCH/HD pipeline for both mm-types.
//                        sg_element=0x00 universally (Drift #4 fixed).
//                        AACH 0x0009 via PDU-class header → queue → scheduler
//                        (Drift #3 expected to auto-resolve once both mm-types
//                        traverse the same SCH/HD path).
//                        BKN2 = sig_companion_sys via existing scheduler
//                        scheme (head_is_f=0 routes to SYSINFO; Drift #2 OK).
//
// Filter:
//   `mm_pdu_type` is still consumed as a defensive filter — only mm ∈ {2,7}
//   triggers a push.  The MAC-Resource builder constants are identical for
//   both branches, but the `mm_pdu_type` check guarantees we don't push for
//   unrelated UL random-access PDUs (e.g. mm=4 Detach already handled
//   elsewhere; arbitrary unknown mm-types must not generate signalling).
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
    // Phase Z.9 — mm-type filter.  Only mm ∈ {2,7} produces a push;
    // other mm-types count as drop and stay IDLE.
    input  wire [3:0]   mm_pdu_type,

    // MCCH slot (CDC-resynced from AXI), pre-reply target TN
    input  wire [1:0]   cfg_mcch_tn,
    input  wire [31:0]  cfg_scramble_init,

    // DL-Signal-Queue producer (MLE slot — muxed at top.v with MLE-FSM
    // Final-ACCEPT and GroupAck).  Phase Z.9: 432-bit bus carries the
    // 216-bit SCH/HD payload MSB-aligned; pdu_type fixed at SCH_HD.
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
    // mm-type filter — accept only mm=2 (ITSI-Attach) or mm=7 (Group-Switch).
    // The body content is identical; the filter just guards against unrelated
    // UL random-access events generating spurious Pre-Replies.
    // -------------------------------------------------------------------------
    wire mm_accept_w = (mm_pdu_type == 4'd2) | (mm_pdu_type == 4'd7);

    // -------------------------------------------------------------------------
    // Latches (single SCH/HD path)
    // -------------------------------------------------------------------------
    reg [23:0]  lat_ssi;
    reg [1:0]   lat_target_tn;
    reg [31:0]  lat_scramble_init;
    // SCH/HD coded-payload latch (216 bit).
    reg [215:0] lat_coded_schhd;

    // -------------------------------------------------------------------------
    // Internal MAC-RESOURCE 124-bit builder + SCH/HD encoder.
    //   AL-SETUP, slot_granting_flag=1, sg_element=0x00 — Gold-Ref bit-identity
    //   for BOTH mm=2 (per reference_gold_full_attach_timeline.md) and mm=7
    //   (per reference_gold_group_switch_burst_timeline.md).
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
        .addr_type                    (`PDUC_PRE_REPLY_SLOTGRANT_ADDRTYPE),
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (`PDUC_PRE_REPLY_SLOTGRANT_LLC),
        .random_access_flag           (`PDUC_PRE_REPLY_SLOTGRANT_RA),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
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
        .mle_pd_in                    (3'b001),    /* unused; AL-SETUP has no MM */
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
    // FSM — single SCH/HD path.
    //
    //   S_IDLE  — wait for frag1_edge_w with mm ∈ {2,7}.  Latch trigger
    //             inputs and kick the local MAC-Resource builder.
    //   S_BUILD — wait for builder_valid_w; then kick the SCH/HD encoder.
    //   S_ENC   — wait for coded_valid_w; latch 216-bit coded.
    //   S_PUSH  — pulse wr_slotgrant_valid_sys for 1 cycle.
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
            lat_coded_schhd        <= 216'd0;
            builder_start          <= 1'b0;
            encode_start           <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;
            push_cnt_sys           <= 16'd0;
            drop_cnt_sys           <= 16'd0;
        end else begin
            // Default 1-cycle strobes
            builder_start          <= 1'b0;
            encode_start           <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;

            case (state)
            S_IDLE: begin
                if (frag1_edge_w) begin
                    if (mm_accept_w) begin
                        // Latch trigger inputs and kick local SCH/HD pipeline
                        // (no arbitration; pipeline is exclusive to this FSM).
                        lat_ssi             <= ul_ssi;
                        lat_target_tn       <= cfg_mcch_tn;
                        lat_scramble_init   <= cfg_scramble_init;
                        builder_start       <= 1'b1;
                        state               <= S_BUILD;
                    end else begin
                        // Defensive default — unknown mm-type.  Count drop
                        // and stay IDLE.
                        if (drop_cnt_sys != 16'hFFFF)
                            drop_cnt_sys <= drop_cnt_sys + 16'd1;
                    end
                end
            end

            S_BUILD: begin
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (builder_valid_w) begin
                    encode_start <= 1'b1;
                    state        <= S_ENC;
                end
            end

            S_ENC: begin
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
    //   coded[431:0]  = {lat_coded_schhd, 216'd0}  (SCH/HD MSB-aligned)
    //   pdu_type      = PDUC_SLOTFMT_SCH_HD
    //   target_tn     = latched cfg_mcch_tn
    //
    // Z.8 MSB-alignment: the scheduler reads BKN1 from head_coded[431:216].
    // Pushing LSB-aligned would deliver 216 zero-bits to the slot → SCH/HD
    // CRC fail → MS drops Pre-Reply.  See Z.8 commit context.
    // -------------------------------------------------------------------------
    assign wr_slotgrant_coded_sys     = {lat_coded_schhd, 216'd0};
    assign wr_slotgrant_pdu_type_sys  = `PDUC_PRE_REPLY_SLOTGRANT_FMT;
    assign wr_slotgrant_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
