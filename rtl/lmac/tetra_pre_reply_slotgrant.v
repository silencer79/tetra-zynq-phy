// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase X.6 — Pre-Reply Slot-Grant Mini-FSM, builder pipeline EXTERNALISED.
//
// X.5b kept the {basic_slotgrant_encoder, mac_resource_dl_builder,
// sch_f_encoder} triple inline; X.6 (slice-saver refactor) pulls them
// out and shares one instance with tetra_mle_registration_fsm.v via
// tetra_dl_pdu_builder.v + a top-level arbiter.
//
// Trigger flow (unchanged):
//   On every Frag-1 detection (`frag1_pulse` 1-cycle pulse from the
//   MAC-ACCESS parser at top.v) build a 268-bit MAC-RESOURCE AL-SETUP PDU
//   that carries `slot_granting_flag=1` + `slot_granting_element=0x01`
//   (capacity_allocation=0, granting_delay=1 — Phase H.3.2 Gold-Ref-bit-
//   identity), SCH/F-encode it to 432 bits, and push it to the DL-Signal-
//   Queue's MLE producer slot (muxed at top.v against the MLE-FSM's Final-
//   ACCEPT output, which fires on a much later mb_go_pulse).
//
//   Without this slot-grant, the MS receives Frag-1 unacknowledged and
//   has no slot reservation for Frag-2 — it retries Frag-1 indefinitely.
//
// Architecture (sequential pipeline, builder external):
//   frag1_pulse (edge-detect) ──► slotgrant_build_req (1-cyc pulse)
//                                      │  + req_*  field plane
//                                      ▼
//                        [shared tetra_dl_pdu_builder, arbitrated at top]
//                                      │  basic_slotgrant + mac_resource +
//                                      │  sch_f all run sequentially
//                                      ▼
//                                 slotgrant_build_done (1-cyc pulse)
//                                      │  + 432-bit coded
//                                      ▼
//                                 wr_slotgrant_*  (queue MLE slot)
//
// Builder request fields (constant, identical to pre-X.6 inline encoder
// inputs — H.3.2 Gold-Ref-Bit-Identity):
//   addr_type            = 3'd1   (SSI)
//   llc_pdu_type         = 4'd8   (AL-SETUP)
//   random_access_flag   = 1'b1   (RA-piggyback)
//   mm_pdu_bits          = 0      (AL-SETUP carries no MM body)
//   mm_pdu_len_bits      = 0
//   slot_granting_flag   = 1'b1, granting_delay=1, cap_alloc=0
//                          → packed_element=0x01 (hardcoded inside the
//                            shared builder).
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

    // Phase X.6 — Build-request to shared tetra_dl_pdu_builder via arbiter.
    //   slotgrant_build_req           1-cyc pulse
    //   slotgrant_build_*             field plane (constants + lat_ssi)
    //   slotgrant_build_done          1-cyc pulse from builder
    //   slotgrant_build_coded         432-bit SCH/F coded
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
    // High while a Frag-1-triggered build is queued/in-flight (used by the
    // top-level arbiter to drop concurrent SlotGrant pulses while busy).
    input  wire         slotgrant_build_grant_blocked,

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
    reg [31:0] lat_scramble_init;
    reg [431:0] lat_coded;

    // -------------------------------------------------------------------------
    // Build-request field plane — constants per H.3.2 Gold-Ref except SSI
    // and scramble_init which are latched from frag1 trigger time.
    // -------------------------------------------------------------------------
    assign slotgrant_build_ssi                = lat_ssi;
    assign slotgrant_build_addr_type          = 3'd1;       // SSI
    assign slotgrant_build_llc_pdu_type       = 4'd8;       // AL-SETUP
    assign slotgrant_build_random_access_flag = 1'b1;       // RA-piggyback
    assign slotgrant_build_mm_pdu_bits        = 128'd0;     // AL-SETUP no MM
    assign slotgrant_build_mm_pdu_len_bits    = 8'd0;
    assign slotgrant_build_scramble_init      = lat_scramble_init;

    // -------------------------------------------------------------------------
    // FSM
    //   S_IDLE      — wait for frag1_edge_w
    //   S_REQ       — pulse slotgrant_build_req for 1 cycle
    //   S_WAIT      — wait for slotgrant_build_done (counts collisions)
    //   S_PUSH      — pulse wr_slotgrant_valid_sys for 1 cycle
    // -------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_REQ  = 2'd1;
    localparam [1:0] S_WAIT = 2'd2;
    localparam [1:0] S_PUSH = 2'd3;

    reg [1:0] state;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            state                  <= S_IDLE;
            lat_ssi                <= 24'd0;
            lat_target_tn          <= 2'd0;
            lat_scramble_init      <= 32'd0;
            lat_coded              <= 432'd0;
            slotgrant_build_req    <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;
            push_cnt_sys           <= 16'd0;
            drop_cnt_sys           <= 16'd0;
        end else begin
            // Default strobes (1-cycle pulses)
            slotgrant_build_req    <= 1'b0;
            wr_slotgrant_valid_sys <= 1'b0;

            case (state)
            S_IDLE: begin
                if (frag1_edge_w) begin
                    if (slotgrant_build_grant_blocked) begin
                        // Arbiter says builder busy / MLE wins — drop this
                        // Frag-1 pre-reply.
                        if (drop_cnt_sys != 16'hFFFF)
                            drop_cnt_sys <= drop_cnt_sys + 16'd1;
                    end else begin
                        lat_ssi             <= ul_ssi;
                        lat_target_tn       <= cfg_mcch_tn;
                        lat_scramble_init   <= cfg_scramble_init;
                        slotgrant_build_req <= 1'b1;
                        state               <= S_REQ;
                    end
                end
            end

            S_REQ: begin
                // Drop concurrent Frag-1 pulses while pipeline busy.
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                state <= S_WAIT;
            end

            S_WAIT: begin
                if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
                    drop_cnt_sys <= drop_cnt_sys + 16'd1;
                if (slotgrant_build_done) begin
                    lat_coded <= slotgrant_build_coded;
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
