// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase X.5b — Pre-Reply Slot-Grant Mini-FSM (post-Frag-1 = Step 2 of
// Gold ITSI-Attach sequence).
//
// Purpose:
//   On every Frag-1 detection (`frag1_pulse` 1-cycle pulse from the
//   MAC-ACCESS parser at top.v) build a 268-bit MAC-RESOURCE AL-SETUP PDU
//   that carries `slot_granting_flag=1` + `slot_granting_element=0x01`
//   (capacity_allocation=0, granting_delay=1 — Phase H.3.2 Gold-Ref-bit-
//   identity), SCH/F-encode it to 432 bits, and push it to the DL-Signal-
//   Queue's MLE producer slot (muxed at top.v against the MLE-FSM's Final-
//   ACCEPT output, which fires on a much later mb_go_pulse).
//
//   Without this slot-grant, the MS receives Frag-1 unacknowledged and
//   has no slot reservation for Frag-2 — it retries Frag-1 indefinitely
//   (verified UL-WAV 2026-05-02: 51 Frag-1 Bursts, 0 Frag-2 in 31s).
//
//   This restores the post-Frag-1 slot-grant behaviour that lived in the
//   MLE-FSM's S_BUILD_SHORT_* path before Phase X.4 deleted it (commit
//   75c639a, mis-interpreted as obsolete Multi-Lookup leftover).  Phase
//   H.3.2 (commit 1fd63db) demonstrated this path made ITSI-Attach
//   Gold-conformant on the MTP3550.
//
// Architecture (sequential pipeline):
//   frag1_pulse (edge-detect) ──► tetra_basic_slotgrant_encoder
//                                      │  (combinational, packed_element)
//                                      ▼
//                                 tetra_mac_resource_dl_builder
//                                      │  PDU_BITS=268, AL-SETUP, sg_flag=1
//                                      ▼
//                                 tetra_sch_f_encoder
//                                      │  268 → 432 type-5 coded bits
//                                      ▼
//                                 wr_slotgrant_*  (queue MLE slot)
//
// Builder/encoder constants (Gold-Ref-Bit-Identity to H.3.2 commit 1fd63db
// short pre-reply, with SCH/F substituting the historical SCH/HD path):
//   addr_type            = 3'd1   (SSI)
//   llc_pdu_type         = 4'd8   (AL-SETUP)
//   random_access_flag   = 1'b1   (RA-piggyback)
//   ns/nr                = 1'b0   (AL-SETUP has no LLC sequence)
//   slot_granting_flag   = 1'b1
//   slot_granting_element= 8'h01  (cap_alloc=0, granting_delay=1)
//   power_control_flag   = 1'b0
//   chan_alloc_flag      = 1'b0
//   second_pdu_valid     = 1'b0   (no concat)
//   mm_pdu_*             = 0      (AL-SETUP carries no MM body)
//
// Coding rules (Verilog-2001 strict):
//   R1   one always block per FSM
//   R4   async active-low reset
//   R10  @(*) for combinational
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_pre_reply_slotgrant (
    input  wire         clk_sys,
    input  wire         rst_n_sys,

    // Frag-1 trigger from MAC-ACCESS parser (1-cycle pulse on clk_sys)
    input  wire         frag1_pulse,
    input  wire [23:0]  ul_ssi,

    // MCCH slot (CDC-resynced from AXI), pre-reply target TN
    input  wire [1:0]   cfg_mcch_tn,
    input  wire [31:0]  cfg_scramble_init,

    // DL-Signal-Queue producer (MLE slot — muxed at top.v with MLE-FSM)
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
    reg [23:0] lat_ssi;
    reg [1:0]  lat_target_tn;

    // -------------------------------------------------------------------------
    // Stage A — basic slot-grant element encoder (combinational, 8 bits).
    //   capacity_allocation = 4'd0
    //   granting_delay      = 4'd1   (Phase H.3.2 Gold-bit-identity)
    //   packed_element      = 8'h01
    // -------------------------------------------------------------------------
    wire [7:0] slotgrant_packed_w;
    tetra_basic_slotgrant_encoder u_slotgrant_pkt (
        .capacity_allocation (4'd0),
        .granting_delay      (4'd1),
        .packed_element      (slotgrant_packed_w)
    );

    // -------------------------------------------------------------------------
    // Stage B — MAC-RESOURCE DL builder (268-bit PDU, AL-SETUP, sg_flag=1).
    // Latency: 6 cycles per builder header comment (IDLE→ASSEMBLE_INNER→
    // LLC_HEAD→MAC_HEAD→PAD→DONE).
    // -------------------------------------------------------------------------
    reg          builder_start;
    wire [267:0] builder_pdu_w;
    wire         builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268),
        .LLC_BUF_BITS(144)        // matches default; AL-SETUP only writes 4 LLC bits
    ) u_mac_res (
        .clk                          (clk_sys),
        .rst_n                        (rst_n_sys),
        .start                        (builder_start),
        .ssi                          (lat_ssi),
        .addr_type                    (3'd1),         // SSI
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (4'd8),         // AL-SETUP
        .random_access_flag           (1'b1),         // RA-piggyback
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        .slot_granting_flag           (1'b1),
        .slot_granting_element        (slotgrant_packed_w),
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
        .mm_pdu_bits                  (128'd0),       // AL-SETUP has no MM body
        .mm_pdu_len_bits              (8'd0),
        .pdu_bits                     (builder_pdu_w),
        .valid                        (builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // Stage C — SCH/F encoder (268 type-1 → 432 type-5).  Latency ~991 cyc.
    // -------------------------------------------------------------------------
    reg          encode_start;
    reg  [267:0] lat_info_bits;
    wire [431:0] coded_w;
    wire         coded_valid_w;

    tetra_sch_f_encoder u_sch_f (
        .clk           (clk_sys),
        .rst_n         (rst_n_sys),
        .encode_start  (encode_start),
        .info_bits     (lat_info_bits),
        .scramble_init (cfg_scramble_init),
        .coded_bits    (coded_w),
        .coded_valid   (coded_valid_w)
    );

    // Latched coded payload for queue push
    reg [431:0] lat_coded;

    // -------------------------------------------------------------------------
    // FSM
    //   S_IDLE   — wait for frag1_edge_w
    //   S_BUILD  — wait for mac_resource_dl_builder.valid
    //   S_PACK   — latch builder PDU into lat_info_bits, kick SCH/F encoder
    //   S_ENC    — wait for sch_f_encoder.coded_valid → latch coded
    //   S_PUSH   — pulse wr_slotgrant_valid_sys for 1 cycle
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_BUILD = 3'd1;
    localparam [2:0] S_PACK  = 3'd2;
    localparam [2:0] S_ENC   = 3'd3;
    localparam [2:0] S_PUSH  = 3'd4;

    reg [2:0] state;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            state                 <= S_IDLE;
            lat_ssi               <= 24'd0;
            lat_target_tn         <= 2'd0;
            builder_start         <= 1'b0;
            encode_start          <= 1'b0;
            lat_info_bits         <= 268'd0;
            lat_coded             <= 432'd0;
            wr_slotgrant_valid_sys<= 1'b0;
            push_cnt_sys          <= 16'd0;
            drop_cnt_sys          <= 16'd0;
        end else begin
            // Default strobes (1-cycle pulses)
            builder_start         <= 1'b0;
            encode_start          <= 1'b0;
            wr_slotgrant_valid_sys<= 1'b0;

            case (state)
            S_IDLE: begin
                if (frag1_edge_w) begin
                    lat_ssi       <= ul_ssi;
                    lat_target_tn <= cfg_mcch_tn;
                    builder_start <= 1'b1;
                    state         <= S_BUILD;
                end
            end
            S_BUILD: begin
                // Drop concurrent Frag-1 pulses while pipeline busy.
                // Frag-1 cadence on the slot grid is ~14 ms; pipeline
                // takes ~1000 cyc @ 100 MHz = 10 µs — collisions only
                // happen in TB stress.
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (builder_valid_w) begin
                    lat_info_bits <= builder_pdu_w;
                    state         <= S_PACK;
                end
            end
            S_PACK: begin
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                // Kick SCH/F encoder one cycle after PDU is latched
                encode_start <= 1'b1;
                state        <= S_ENC;
            end
            S_ENC: begin
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (coded_valid_w) begin
                    lat_coded <= coded_w;
                    state     <= S_PUSH;
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
    // Combinational outputs to DL-Signal-Queue (MLE slot, muxed at top.v).
    //   coded[431:0]   = SCH/F type-5 coded bits, [431] = first on air
    //   pdu_type[1:0]  = 2'd0  (SCH_F)
    //   target_tn[1:0] = latched cfg_mcch_tn
    // -------------------------------------------------------------------------
    assign wr_slotgrant_coded_sys     = lat_coded;
    assign wr_slotgrant_pdu_type_sys  = 2'd0;          // SCH/F
    assign wr_slotgrant_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
