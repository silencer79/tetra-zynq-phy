// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase Z.3 — Pre-Reply Slot-Grant Mini-FSM, SCH/HD path (Gold-conform).
//
// Trigger: `frag1_pulse` (1-cycle pulse from MAC-ACCESS parser on Frag-1
// detection, mm=2 ITSI-Attach **and** mm=7 Group-Switch — both share the
// same Pre-Reply LI=7 AL-SETUP pattern per
// reference_gold_group_switch_burst_timeline.md).
//
// Per-Gold raw bit decode (reference_gold_full_attach_timeline.md Z. 95-100):
//
//   bits: 0010001 000111001 001010000010111111110100 010 0000000 0...
//                                                    ^^^ ^^^^^^^^
//                                                  flags  sg_element
//
//   MAC-RESOURCE pdu=00 fill=1 pog=0 enc=00 ra=1 LI=7
//                addr=SSI=0x282FF4 flags=010   (sg_flag=1, NOT 0!)
//                slot_granting_element=0x00     (8 zero bits)
//   LLC: AL-SETUP (type=8) — 7-octet wrapper, kein MM body inline
//
// Note 2026-05-04: the human comment "kein slot_grant" / "flags=000" in the
// memory file was a misread — the raw bit stream right above it clearly
// shows `010` for flag-triple and `00000000` for sg_element.  Z.3 honours
// the bits, not the human label: slot_granting_flag=1 + sg_element=0x00 is
// what Gold sends, giving LI=7 (51-bit header + 4-bit LLC = 55 bits → 7
// octets).
//
// Pre-Z.3 this module ran through tetra_dl_pdu_builder which hardcoded
// slot_granting_flag=1 + element=0x01.  That generated SCH/F 432-bit output
// on a slot whose AACH expected SCH/HD — bit-drift caught by Z.3 audit.
// Z.3 fix:
//   - keep slot_granting_flag=1 (Gold-bit-identity, contradicts the misread
//     memory note),
//   - drop element from 0x01 to 0x00 (matches raw bit stream),
//   - migrate slot format SCH/F → SCH/HD (matches AACH 0x0009 + LI=7
//     short-PDU expectation).
//
// Architecture (sequential pipeline, builder INTERNAL):
//   frag1_pulse (edge-detect) ──► tetra_mac_resource_dl_builder #(124)
//                                      └─► 124-bit padded MAC-RESOURCE
//                                          └─► tetra_sch_hd_encoder
//                                              └─► 216-bit SCH/HD coded
//                                                  └─► wr_slotgrant_*  (queue)
//
// Bit-identity to Gold:
//   - addr_type            = SSI (3'd1)
//   - LI                   = 7 octets (4 hdr + AL-SETUP 4-bit fits 1 byte;
//                            48 total bits → 6 octets — but Gold reports
//                            LI=7 octets for LI=7 textual MAC-header field;
//                            see ETSI Table 21.56 → LengthInd = total octets
//                            = ceil((43+4)/8) = 6, then bluestation fill
//                            adds +1 = 7).  Matches builder math
//                            `mac_total_octets = (47+7)>>3 = 6`, but with
//                            fill_bit_ind=1 in S_PAD bumps post-pad → 7
//                            (cf. mac_resource_dl_builder S_PAD comment).
//   - random_access_flag   = 1 (RA-piggyback)
//   - slot_granting_flag   = 0  ← Gold bit-identity, not 1 like pre-Z.3
//   - llc_pdu_type         = 4'd8 (AL-SETUP)
//
// Slot-format / AACH:
//   pdu_type = SCH_HD    → 124 → 216 coded bits
//   AACH on this slot is set to PDUC_PRE_REPLY_SLOTGRANT_AACH (=0x0009)
//   by the queue's MLE-slot AACH override at top.v.  MS sees signalling-
//   active AACH on the next-frame Pre-Reply slot.
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

    // MCCH slot (CDC-resynced from AXI), pre-reply target TN
    input  wire [1:0]   cfg_mcch_tn,
    input  wire [31:0]  cfg_scramble_init,

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
    // Latches
    // -------------------------------------------------------------------------
    reg [23:0]  lat_ssi;
    reg [1:0]   lat_target_tn;
    reg [31:0]  lat_scramble_init;

    // -------------------------------------------------------------------------
    // Internal MAC-RESOURCE 124-bit builder (PDU_BITS=124, LLC_BUF_BITS=16
    // — AL-SETUP needs only the 4-bit LLC header).
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
        // Z.3: Gold raw bits decode to flags=010 (sg_flag=1) +
        // sg_element=0x00.  See module-header comment for forensic detail.
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

    // -------------------------------------------------------------------------
    // Internal SCH/HD encoder (124 → 216 type-5 coded bits).
    // -------------------------------------------------------------------------
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

    reg [215:0] lat_coded_blk1;

    // -------------------------------------------------------------------------
    // FSM
    //   S_IDLE   — wait for frag1_edge_w
    //   S_BUILD  — wait for builder.valid → kick SCH/HD encoder
    //   S_ENC    — wait for sch_hd_encoder.coded_valid → latch coded
    //   S_PUSH   — pulse wr_slotgrant_valid_sys for 1 cycle
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
            lat_coded_blk1         <= 216'd0;
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
                    lat_ssi             <= ul_ssi;
                    lat_target_tn       <= cfg_mcch_tn;
                    lat_scramble_init   <= cfg_scramble_init;
                    builder_start       <= 1'b1;
                    state               <= S_BUILD;
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
                    lat_coded_blk1 <= coded_w;
                    state          <= S_PUSH;
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
    //   coded[431:0]   = SCH/HD LSB-aligned (queue convention; same as
    //                    tetra_pre_reply_blck.v output)
    //   pdu_type[1:0]  = `PDUC_PRE_REPLY_SLOTGRANT_FMT  (= SCH_HD = 2'd1)
    //   target_tn[1:0] = latched cfg_mcch_tn
    // -------------------------------------------------------------------------
    assign wr_slotgrant_coded_sys     = {216'd0, lat_coded_blk1};
    assign wr_slotgrant_pdu_type_sys  = `PDUC_PRE_REPLY_SLOTGRANT_FMT;
    assign wr_slotgrant_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
