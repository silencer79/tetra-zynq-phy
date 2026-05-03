// =============================================================================
// tetra_pre_reply_blck.v
//
// Phase X.5 — Pre-Reply BL-ACK Mini-FSM
//
// Purpose:
//   On every reassembly+IE-parse-done event (`trigger_valid` 1-cycle pulse,
//   bound at top.v to `mle_demand_parsed_valid_sys = iep_parse_done_sys &
//   iep_parse_ok_sys`) build a SCH/HD-coded BL-ACK PDU and push it into the
//   DL-Signal-Queue's SDS producer port (was tied off).  The DL-Signal-
//   Scheduler picks it up the next frame and overrides the target slot, so
//   the MS sees an ACK on the post-Frag-2 slot.
//
//   This corresponds to Step 4 of the Gold-ITSI-Attach sequence
//   (reference_gold_full_attach_timeline.md): BS BL-ACK after Frag-2.
//   Step 2 (slot-grant after Frag-1) is now handled by the parallel
//   tetra_pre_reply_slotgrant.v module.  Earlier (Phase X.5 initial)
//   this module was triggered on Frag-1 — that conflated Step 2 with
//   Step 4 and broke Gold-conformance; the trigger has been moved to
//   the post-reassembly pulse.
//
// Per Gold-Ref `reference_gold_full_attach_timeline.md` the post-Frag-2
// BL-ACK lives on the same TN as MCCH (cfg_mcch_tn).  AACH on that slot is
// currently 0x0249 (reserved/capacity-allocation) which is enough for the
// MS to expect a SCH/HD payload — the existing AACH-Schedule is unchanged
// by this module.
//
// Architecture:
//   trigger_valid (edge-detect) ──► tetra_mac_resource_bl_ack_builder
//                                      └─► 124-bit padded BL-ACK PDU
//                                          └─► tetra_sch_hd_encoder
//                                              └─► 216-bit SCH/HD coded
//                                                  └─► wr_blck_*  (queue)
//
// Coding rules: Verilog-2001 strict (R1/R2/R4/R10), single clock domain
// (clk_sys), async active-low reset.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_pre_reply_blck (
    input  wire         clk_sys,
    input  wire         rst_n_sys,

    // Reassembly+IEP-Done trigger (1-cycle pulse on clk_sys).  Bound at
    // top.v to `mle_demand_parsed_valid_sys = iep_parse_done_sys &
    // iep_parse_ok_sys` — i.e. fires AFTER Frag-2 has been received,
    // reassembled, and the IE parser walked the MM body successfully.
    // This is Step 4 of the Gold ITSI-Attach sequence.
    input  wire         trigger_valid,
    input  wire [23:0]  ul_ssi,

    // MCCH slot (CDC-resynced from AXI), pre-reply target TN
    input  wire [1:0]   cfg_mcch_tn,
    input  wire [31:0]  cfg_scramble_init,

    // DL-Signal-Queue producer (SDS slot — was tied off)
    output reg          wr_blck_valid_sys,
    output wire [431:0] wr_blck_coded_sys,
    output wire [1:0]   wr_blck_pdu_type_sys,
    output wire [1:0]   wr_blck_target_tn_sys,

    // Stats — saturating 16-bit counters
    output reg  [15:0]  push_cnt_sys,
    output reg  [15:0]  drop_cnt_sys
);

    // -------------------------------------------------------------------------
    // Edge-detect on trigger_valid (defensively — even if upstream guarantees
    // a 1-cycle pulse, double-trigger protection costs nothing).
    // -------------------------------------------------------------------------
    reg trigger_valid_q;
    wire trigger_pulse_w = trigger_valid & ~trigger_valid_q;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            trigger_valid_q <= 1'b0;
        else
            trigger_valid_q <= trigger_valid;
    end

    // -------------------------------------------------------------------------
    // FSM
    //   S_IDLE   — wait for trigger_pulse_w
    //   S_BUILD  — wait for bl_ack_builder.valid → kick SCH/HD encoder
    //   S_ENC    — wait for sch_hd_encoder.coded_valid → latch coded
    //   S_PUSH   — pulse wr_blck_valid_sys for 1 cycle
    // -------------------------------------------------------------------------
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_BUILD = 2'd1;
    localparam [1:0] S_ENC   = 2'd2;
    localparam [1:0] S_PUSH  = 2'd3;

    reg [1:0]  state;
    reg [23:0] lat_ssi;
    reg [1:0]  lat_target_tn;

    // BL-ACK builder — 124-bit PDU (zero-padded MSB above the 48 used bits)
    reg          builder_start;
    wire [123:0] builder_pdu_w;
    wire         builder_valid_w;

    tetra_mac_resource_bl_ack_builder #(
        .PDU_BITS(124)
    ) u_bl_ack (
        .clk                (clk_sys),
        .rst_n              (rst_n_sys),
        .start              (builder_start),
        .ssi                (lat_ssi),
        .addr_type          (3'd1),       // SSI (ETSI EN 300 392-2 Table 21.66)
        .random_access_flag (1'b0),
        .nr                 (1'b0),       // first BL-ACK
        .pdu_bits           (builder_pdu_w),
        .valid              (builder_valid_w)
    );

    // SCH/HD encoder — 124 → 216 type-5 coded bits.  scramble_init is the
    // cell DL seed `{MCC,MNC,CC,2'b11}` (identical pack as MLE-FSM uses
    // for ACCEPT and as AACH-encoder uses for the slot scrambler).  MS
    // requires this seed to match its own descrambler, otherwise the
    // BL-ACK payload looks like noise on-air.
    reg          encode_start;
    wire [215:0] coded_w;
    wire         coded_valid_w;

    tetra_sch_hd_encoder u_sch_hd (
        .clk           (clk_sys),
        .rst_n         (rst_n_sys),
        .encode_start  (encode_start),
        .info_bits     (builder_pdu_w),
        .scramble_init (cfg_scramble_init),
        .coded_bits    (coded_w),
        .coded_valid   (coded_valid_w)
    );

    // Latched coded payload for queue push
    reg [215:0] lat_coded_blk1;

    // -------------------------------------------------------------------------
    // FSM control + payload registers
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            state           <= S_IDLE;
            lat_ssi         <= 24'd0;
            lat_target_tn   <= 2'd0;
            builder_start   <= 1'b0;
            encode_start    <= 1'b0;
            wr_blck_valid_sys <= 1'b0;
            lat_coded_blk1  <= 216'd0;
            push_cnt_sys    <= 16'd0;
            drop_cnt_sys    <= 16'd0;
        end else begin
            // Default strobes
            builder_start     <= 1'b0;
            encode_start      <= 1'b0;
            wr_blck_valid_sys <= 1'b0;

            case (state)
            S_IDLE: begin
                if (trigger_pulse_w) begin
                    lat_ssi       <= ul_ssi;
                    lat_target_tn <= cfg_mcch_tn;
                    builder_start <= 1'b1;
                    state         <= S_BUILD;
                end
            end
            S_BUILD: begin
                // While busy, drop concurrent trigger pulses (Reassembly-
                // done cadence is multi-frame-apart on the slot grid; the
                // FSM completes in ~500 cycles @ 100 MHz = 5 µs, so this
                // is essentially never hit in real traffic — but the
                // counter catches stress cases / TB collisions).
                if (trigger_pulse_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (builder_valid_w) begin
                    encode_start <= 1'b1;
                    state        <= S_ENC;
                end
            end
            S_ENC: begin
                if (trigger_pulse_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (coded_valid_w) begin
                    lat_coded_blk1 <= coded_w;
                    state          <= S_PUSH;
                end
            end
            S_PUSH: begin
                wr_blck_valid_sys <= 1'b1;
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
    //   coded[431:0]   = SCH/HD LSB-aligned (queue convention, see
    //                    tetra_dl_signal_queue.v line 17 + scheduler line 122)
    //   pdu_type[1:0]  = 2'd1  (SCH_HD)
    //   target_tn[1:0] = latched cfg_mcch_tn
    // -------------------------------------------------------------------------
    assign wr_blck_coded_sys     = {216'd0, lat_coded_blk1};
    assign wr_blck_pdu_type_sys  = 2'd1;
    assign wr_blck_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
