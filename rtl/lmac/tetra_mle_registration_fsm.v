// =============================================================================
// tetra_mle_registration_fsm.v
//
// MLE registration engine — takes an uplink "location update request"
// (ISSI + LA from the UL MAC-ACCESS parser) and drives the four-step
// downlink response flow:
//
//   1. Query the active-session-table for an existing record on this ISSI.
//      - hit  → reuse slot (MS is re-registering)
//      - miss → alloc mode scan, pick the first free slot
//   2. Write the session record back into the table marked REG_ACCEPT_SENT.
//   3. Build the MAC-RESOURCE DL PDU (268 type-1 info bits) around the raw
//      MM D-LOCATION-UPDATE-ACCEPT bits via tetra_mac_resource_dl_builder.
//   4. Run the 268-bit MAC-RESOURCE PDU through tetra_sch_f_encoder
//      (CRC+RCPC+interleave+scramble) and split the 432-bit SCH/F output
//      into two 216-bit halves (BKN1/BKN2) for the DL slot multiplexer.
//
// The D-LOCATION-UPDATE encoder, MAC-RESOURCE builder, and SCH/F encoder
// are all instantiated inside this module.  The FSM owns the active-
// session-table ports exclusively for MVP — an arbiter can be wrapped
// around it later when a second MLE/CMCE FSM needs the same resource.
//
// Table-full behaviour: alloc miss just drops the request (no REJECT PDU on
// the MVP path — the MS will retry).  Wire a REJECT encode branch in as
// soon as we have a capacity-exhausted scenario worth handling.
//
// N(S)/N(R) sequencing — TODO: the active-session-table record currently
// has no dedicated N(S)/N(R) field, so the builder gets {ns,nr} = {0,0}
// for every request.  This is correct for first transactions (which is
// all we handle today); sticking NS=0/NR=0 on re-registrations is still
// protocol-acceptable because the MS treats D-LOC-UPDATE-ACCEPT as
// unacknowledged downlink signalling.  Widen ast_wr_data / ast_q_record
// to carry per-MS NS/NR when we add an upper-layer call-setup flow.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_mle_registration_fsm #(
    parameter integer AST_IDX_WIDTH = 6,
    parameter integer AST_REC_WIDTH = 64
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // -----------------------------------------------------------------
    // Uplink request from UL MAC-ACCESS parser (1-cycle pulse)
    // -----------------------------------------------------------------
    input  wire                        ul_req_valid,
    input  wire [2:0]                  ul_addr_type,
    input  wire [23:0]                 ul_ssi,
    input  wire [13:0]                 ul_la,
    // Location update type from MS's U-LOC-UPDATE-DEMAND (ETSI §16.10.37);
    // echoed back as the D-LOC-UPDATE-ACCEPT's Location-update-accept-type
    // field so the MS's state machine recognises the response.
    input  wire [2:0]                  ul_loc_upd_type,

    // -----------------------------------------------------------------
    // UL LLC BL-ACK (M1→M2, 2026-04-24) — fires when the MS acknowledges
    // our most recent BL-DATA D-LOC-UPDATE-ACCEPT.  We toggle our local
    // outstanding_ns and pulse ack_pulse so software can count the
    // completed BL-DATA transactions.  The actual registration state in
    // the active-session-table is already REGISTERED at S_WRITE; this
    // ack confirmation only affects the LLC-layer N(S)/N(R) sequencing.
    // -----------------------------------------------------------------
    input  wire                        bl_ack_valid,
    input  wire                        bl_ack_nr,
    input  wire [9:0]                  bl_ack_short_ssi,

    // -----------------------------------------------------------------
    // Timeslot tick (M3, 2026-04-24) — 1-cycle pulse at the start of each
    // TDMA timeslot, used by S_WAIT_ACK to count elapsed slots for the
    // T251 BL-DATA retransmit timer.  Hook up to tx_slot_pulse_sys in
    // tetra_zynq_top.  When slot_pulse is tied 0 the retransmit logic
    // is dormant (TB that only exercises the match path can leave it
    // unwired).
    // -----------------------------------------------------------------
    input  wire                        slot_pulse,

    // -----------------------------------------------------------------
    // Cell configuration (static, from AXI regs)
    // -----------------------------------------------------------------
    input  wire [13:0]                 cfg_la,
    input  wire [31:0]                 cfg_scramble_init,
    input  wire [1:0]                  cfg_mcch_tn,       // target_tn for the queue req

    // -----------------------------------------------------------------
    // Active-session table port — this FSM owns it for MVP
    // -----------------------------------------------------------------
    output reg                         ast_wr_en,
    output reg  [AST_IDX_WIDTH-1:0]    ast_wr_idx,
    output reg  [AST_REC_WIDTH-1:0]    ast_wr_data,
    output reg                         ast_q_start,
    output reg                         ast_q_mode,     // 0=query, 1=alloc
    output reg  [23:0]                 ast_q_issi,
    input  wire                        ast_q_busy,
    input  wire                        ast_q_done,
    input  wire                        ast_q_hit,
    input  wire [AST_IDX_WIDTH-1:0]    ast_q_slot,
    input  wire [AST_REC_WIDTH-1:0]    ast_q_record,

    // -----------------------------------------------------------------
    // DL signalling-queue request — 1-cycle pulse carrying the full 432-bit
    // SCH/F coded PDU plus type/target metadata.  The queue assembles it
    // into an entry; a downstream scheduler decides when it goes on air.
    // -----------------------------------------------------------------
    output reg                         req_valid,
    output reg  [431:0]                req_coded_bits,
    output reg  [1:0]                  req_pdu_type,    // 00=SCH_F
    output reg  [1:0]                  req_target_tn,   // mirrors cfg_mcch_tn

    // -----------------------------------------------------------------
    // Debug / status
    // -----------------------------------------------------------------
    output reg                         busy,
    output reg                         accept_pulse,   // 1 cyc on ACCEPT built
    output reg                         drop_pulse,     // 1 cyc on table-full
    output reg                         ack_pulse,      // 1 cyc on matching BL-ACK
    output reg                         retransmit_pulse, // 1 cyc per retransmit
    output reg                         lost_pulse      // 1 cyc on N252 exhaust
);

    // -------------------------------------------------------------------------
    // Latched UL request
    // -------------------------------------------------------------------------
    reg [2:0]                   lat_addr_type;
    reg [23:0]                  lat_ssi;
    reg [13:0]                  lat_la;
    reg [2:0]                   lat_loc_upd_type;
    reg [AST_IDX_WIDTH-1:0]     lat_slot;
    reg                         lat_existing;
    reg [267:0]                 lat_info_bits;       // builder→encoder handoff

    // -------------------------------------------------------------------------
    // LLC-layer N(S) tracker (M2, 2026-04-24).  MVP: one global 1-bit
    // register, matches bluestation llc_bs_ms.rs:126-131 per-SSI V(S)
    // HashMap but simplified to a single active session until the
    // active-session-table carries per-SSI NS in a future step.
    //
    // Initial value 0; toggles 0↔1 on each acknowledged BL-DATA.  Fed into
    // tetra_mac_resource_dl_builder as `ns` so the outgoing MAC-RESOURCE
    // wraps the correct LLC BL-DATA N(S) bit.
    //
    // Bluestation flow (llc_bs_ms.rs:126-131 get_next_send_seq + :167-171
    // process_incoming_ack mark_acknowledged):
    //   TX: ns = V(S); V(S) ^= 1
    //   RX: if (nr == expected_ack.ns) mark_acknowledged()
    //
    // We fuse these — on a matching BL-ACK, we toggle outstanding_ns.  The
    // next transmitted BL-DATA uses the toggled value.
    // -------------------------------------------------------------------------
    reg                         outstanding_ns;

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE builder — combinational, always watching the latched
    // request fields.  Produces the raw 54-bit MM PDU (MSB-aligned in 80-bit
    // bus) that the MAC-RESOURCE builder wraps.
    // -------------------------------------------------------------------------
    wire [79:0] dloc_mm_bits_w;
    wire [6:0]  dloc_mm_len_w;
    wire [123:0] dloc_legacy_pdu_w;  // unused here, kept for linter silence

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject      (1'b0),                 // MVP: accept only
        .addr_type       (lat_addr_type),
        .ssi             (lat_ssi),
        .la              (cfg_la),               // echo our cell LA
        .result          (2'b00),                // accept
        .encryption      (2'b00),                // clear
        .auth_result     (2'b01),                // success
        .subscriber_class(16'h0000),             // MVP: placeholder
        .loc_acc_type    (lat_loc_upd_type),     // echo MS demand type
        .pdu_bits        (dloc_legacy_pdu_w),
        .pdu_bits_mm     (dloc_mm_bits_w),
        .pdu_len_bits    (dloc_mm_len_w)
    );

    // -------------------------------------------------------------------------
    // MAC-RESOURCE DL builder — 80-bit MM PDU → 268-bit SCH/F info payload.
    // Triggered from S_BUILD_START.
    // TODO: widen AST record to carry N(S)/N(R) and forward them here.  For
    // MVP (first-transaction D-LOC-UPDATE-ACCEPT) NS=NR=0 is correct.
    // -------------------------------------------------------------------------
    reg          builder_start;
    wire [267:0] builder_pdu_bits_w;
    wire         builder_valid_w;

    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268)
    ) u_builder (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (builder_start),
        .ssi               (lat_ssi),
        .addr_type         (lat_addr_type),
        .ns                (outstanding_ns),       // toggles on BL-ACK match (M2)
        .nr                (1'b0),                 // TODO: from AST record
        // D-LOC-UPDATE-ACCEPT is the canonical response to a successful
        // UL Random Access (MAC-ACCESS → MLE → MM demand).  Setting the
        // MAC-RESOURCE RandAccFlag acknowledges the MS's RA and stops
        // it from retrying (ETSI §21.4.3.1, bluestation umac_bs.rs:1176
        // analogous path).  This FSM is exclusively triggered from the
        // UL MAC-ACCESS parser, so hard-1 is correct here.
        .random_access_flag(1'b1),
        .mm_pdu_bits       (dloc_mm_bits_w),
        .mm_pdu_len_bits   (dloc_mm_len_w),
        .pdu_bits          (builder_pdu_bits_w),
        .valid             (builder_valid_w)
    );

    // -------------------------------------------------------------------------
    // SCH/F channel encoder — 268 info bits → 432 type-5 coded bits.
    // Pulsed at S_ENCODE_START after the builder latches a complete PDU.
    // -------------------------------------------------------------------------
    reg          sch_encode_start;
    wire [431:0] sch_coded_bits_w;
    wire         sch_coded_valid_w;

    tetra_sch_f_encoder u_sch_f (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (sch_encode_start),
        .info_bits    (lat_info_bits),
        .scramble_init(cfg_scramble_init),
        .coded_bits   (sch_coded_bits_w),
        .coded_valid  (sch_coded_valid_w)
    );

    // -------------------------------------------------------------------------
    // Session record packer — thin layout (see tetra_active_session_table.v)
    // [REC-1 -: 24]   ISSI            (visible to AST query scan)
    // [ 39:26]        LA
    // [ 25:22]        session state   (1=REG_ACCEPT_SENT)
    // [ 21:16]        slot
    // [ 15: 1]        reserved
    // [ 0]            valid           (visible to AST alloc scan)
    // -------------------------------------------------------------------------
    wire [AST_REC_WIDTH-1:0] session_record_w = {
        lat_ssi,                    // [63:40]
        lat_la,                     // [39:26]
        4'd1,                       // [25:22] state=REG_ACCEPT_SENT
        lat_slot,                   // [21:16]
        15'd0,                      // [15: 1] reserved
        1'b1                        // [0]     valid
    };

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [3:0] S_IDLE         = 4'd0;
    localparam [3:0] S_CHECK_START  = 4'd1;
    localparam [3:0] S_CHECK_WAIT   = 4'd2;
    localparam [3:0] S_ALLOC_START  = 4'd3;
    localparam [3:0] S_ALLOC_WAIT   = 4'd4;
    localparam [3:0] S_WRITE        = 4'd5;
    localparam [3:0] S_BUILD_START  = 4'd6;
    localparam [3:0] S_BUILD_WAIT   = 4'd7;
    localparam [3:0] S_ENCODE_START = 4'd8;
    localparam [3:0] S_ENCODE_WAIT  = 4'd9;
    localparam [3:0] S_DELIVER      = 4'd10;
    localparam [3:0] S_DROP         = 4'd11;
    // M3 — acknowledged-link retransmit path
    localparam [3:0] S_WAIT_ACK     = 4'd12;
    localparam [3:0] S_RETRANSMIT   = 4'd13;

    // BL-DATA retransmit timer / counter constants — bluestation
    // tetra-pdus::llc::consts::{timers,consts}:
    //   T251_SENDER_RETRY_TIMER = frames!(4) = 16 timeslots
    //   N252_BL_MAX_TLSDU_RETRANSMITS_ACKED = 3
    localparam [4:0] T251_SLOTS     = 5'd16;
    localparam [1:0] N252_MAX       = 2'd3;

    reg [3:0] state;
    reg [4:0] wait_slot_cnt;      // 0..15, wraps trigger retransmit
    reg [1:0] retransmit_count;   // 0..3, exhaust trigger mark_lost

    // Synchronous reset — Xilinx DRC (REQP-1839) flags async resets on
    // registers feeding BRAM control pins (WEBWE, ADDRBWRADDR) as memory-
    // corruption hazards.  Keep the AST ports async-reset-free.
    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            lat_addr_type     <= 3'd0;
            lat_ssi           <= 24'd0;
            lat_la            <= 14'd0;
            lat_loc_upd_type  <= 3'd0;
            lat_slot          <= {AST_IDX_WIDTH{1'b0}};
            lat_existing      <= 1'b0;
            lat_info_bits     <= 268'd0;
            ast_wr_en         <= 1'b0;
            ast_wr_idx        <= {AST_IDX_WIDTH{1'b0}};
            ast_wr_data       <= {AST_REC_WIDTH{1'b0}};
            ast_q_start       <= 1'b0;
            ast_q_mode        <= 1'b0;
            ast_q_issi        <= 24'd0;
            builder_start     <= 1'b0;
            sch_encode_start  <= 1'b0;
            req_valid         <= 1'b0;
            req_coded_bits    <= 432'd0;
            req_pdu_type      <= 2'd0;
            req_target_tn     <= 2'd0;
            busy              <= 1'b0;
            accept_pulse      <= 1'b0;
            drop_pulse        <= 1'b0;
            ack_pulse         <= 1'b0;
            retransmit_pulse  <= 1'b0;
            lost_pulse        <= 1'b0;
            wait_slot_cnt     <= 5'd0;
            retransmit_count  <= 2'd0;
        end else begin
            // Default strobes — every state may override
            ast_wr_en        <= 1'b0;
            ast_q_start      <= 1'b0;
            builder_start    <= 1'b0;
            sch_encode_start <= 1'b0;
            req_valid        <= 1'b0;
            accept_pulse     <= 1'b0;
            drop_pulse       <= 1'b0;
            ack_pulse        <= 1'b0;
            retransmit_pulse <= 1'b0;
            lost_pulse       <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (ul_req_valid) begin
                    // D-LOCATION UPDATE ACCEPT is always addressed per SSI
                    // (ETSI EN 300 392-2 §16.10.28).  ul_addr_type on the UL
                    // request carries the MS-picked MAC addressing (often
                    // Event Label = 2 for MAC-ACCESS), which is UL-only
                    // (MS→BS, transient).  Latching it here and reusing it
                    // in the DL ACCEPT wraps the PDU in the wrong address
                    // type — the MS won't recognise its own reply.  Force
                    // SSI (3'd1) for every registration accept.
                    lat_addr_type    <= 3'd1;
                    lat_ssi          <= ul_ssi;
                    lat_la           <= ul_la;
                    lat_loc_upd_type <= ul_loc_upd_type;
                    busy             <= 1'b1;
                    state            <= S_CHECK_START;
                end
            end

            // -----------------------------------------------------------------
            S_CHECK_START: begin
                ast_q_start <= 1'b1;
                ast_q_mode  <= 1'b0;    // query existing
                ast_q_issi  <= lat_ssi;
                state       <= S_CHECK_WAIT;
            end

            // -----------------------------------------------------------------
            S_CHECK_WAIT: begin
                if (ast_q_done) begin
                    if (ast_q_hit) begin
                        // Existing session → reuse slot, skip alloc
                        lat_slot     <= ast_q_slot;
                        lat_existing <= 1'b1;
                        state        <= S_WRITE;
                    end else begin
                        lat_existing <= 1'b0;
                        state        <= S_ALLOC_START;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_ALLOC_START: begin
                ast_q_start <= 1'b1;
                ast_q_mode  <= 1'b1;    // alloc scan
                ast_q_issi  <= 24'd0;   // don't care in alloc mode
                state       <= S_ALLOC_WAIT;
            end

            // -----------------------------------------------------------------
            S_ALLOC_WAIT: begin
                if (ast_q_done) begin
                    if (ast_q_hit) begin
                        lat_slot <= ast_q_slot;
                        state    <= S_WRITE;
                    end else begin
                        // Table full — drop for MVP, no REJECT yet
                        state <= S_DROP;
                    end
                end
            end

            // -----------------------------------------------------------------
            S_WRITE: begin
                ast_wr_en   <= 1'b1;
                ast_wr_idx  <= lat_slot;
                ast_wr_data <= session_record_w;
                state       <= S_BUILD_START;
            end

            // -----------------------------------------------------------------
            S_BUILD_START: begin
                builder_start <= 1'b1;
                state         <= S_BUILD_WAIT;
            end

            // -----------------------------------------------------------------
            S_BUILD_WAIT: begin
                if (builder_valid_w) begin
                    lat_info_bits <= builder_pdu_bits_w;
                    state         <= S_ENCODE_START;
                end
            end

            // -----------------------------------------------------------------
            S_ENCODE_START: begin
                sch_encode_start <= 1'b1;
                state            <= S_ENCODE_WAIT;
            end

            // -----------------------------------------------------------------
            S_ENCODE_WAIT: begin
                if (sch_coded_valid_w) begin
                    // SCH/F output [431] = first bit on air.  The full 432-bit
                    // coded block is handed to the DL-signalling queue as one
                    // request; the scheduler will split it into BKN1/BKN2 when
                    // it pops the entry.
                    req_coded_bits <= sch_coded_bits_w;
                    req_pdu_type   <= 2'd0;                // SCH_F
                    req_target_tn  <= cfg_mcch_tn;
                    state          <= S_DELIVER;
                end
            end

            // -----------------------------------------------------------------
            S_DELIVER: begin
                req_valid        <= 1'b1;
                accept_pulse     <= 1'b1;
                wait_slot_cnt    <= 5'd0;
                retransmit_count <= 2'd0;
                state            <= S_WAIT_ACK;
            end

            // -----------------------------------------------------------------
            // S_WAIT_ACK — stay here counting timeslots until either
            //   (a) a matching BL-ACK arrives from the MS → transaction done
            //       (ack_pulse + N(S) toggle via separate reg below), or
            //   (b) T251=16 slots elapsed with no ACK → retransmit or give up.
            //
            // Bluestation equivalent: llc_bs_ms.rs::submit_retransmissions_to_umac
            // (Z.564-625) — on age ≥ T251_SENDER_RETRY_TIMER, retransmit if
            // count < N252_BL_MAX_TLSDU_RETRANSMITS_ACKED, else mark_lost.
            // -----------------------------------------------------------------
            S_WAIT_ACK: begin
                if (bl_ack_valid &&
                    bl_ack_short_ssi == lat_ssi[9:0] &&
                    bl_ack_nr == outstanding_ns) begin
                    // Match — ack the transaction, reset retransmit state,
                    // return to idle so the next UL request can start fresh.
                    ack_pulse        <= 1'b1;
                    wait_slot_cnt    <= 5'd0;
                    retransmit_count <= 2'd0;
                    state            <= S_IDLE;
                end else if (slot_pulse) begin
                    if (wait_slot_cnt == T251_SLOTS - 5'd1) begin
                        // T251 expired.
                        wait_slot_cnt <= 5'd0;
                        if (retransmit_count == N252_MAX) begin
                            // N252 exhausted — give up and clear outbound.
                            // Bluestation: tx_reporter.mark_lost() (Z.619).
                            lost_pulse       <= 1'b1;
                            retransmit_count <= 2'd0;
                            state            <= S_IDLE;
                        end else begin
                            // Retransmit the existing req_coded_bits without
                            // rebuilding — N(S), SSI, payload identical.
                            retransmit_count <= retransmit_count + 2'd1;
                            state            <= S_RETRANSMIT;
                        end
                    end else begin
                        wait_slot_cnt <= wait_slot_cnt + 5'd1;
                    end
                end
            end

            // -----------------------------------------------------------------
            // S_RETRANSMIT — single-cycle pulse of req_valid to re-enqueue
            // the existing req_coded_bits.  Matches bluestation
            // submit_for_acknowledged_transmission (Z.241-250) which clones
            // the retained retransmission_buf and re-submits.
            // -----------------------------------------------------------------
            S_RETRANSMIT: begin
                req_valid        <= 1'b1;
                retransmit_pulse <= 1'b1;
                state            <= S_WAIT_ACK;
            end

            // -----------------------------------------------------------------
            S_DROP: begin
                drop_pulse <= 1'b1;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            // BL-ACK counter-tick also fires `ack_pulse` for observability
            // from states other than S_WAIT_ACK (e.g., if the MS spams BL-ACKs
            // after the transaction is already idle).  outstanding_ns toggles
            // only on matching states, driven by the separate register below.
            // No state change here — S_WAIT_ACK arm above owns the transition.
        end
    end

    // -------------------------------------------------------------------------
    // N(S) toggle register — M2 one-register-per-always rule.  M3 refinement:
    // toggle only when state == S_WAIT_ACK, so spurious BL-ACKs arriving
    // outside the active transaction window don't corrupt the sequence
    // number.  Mirrors bluestation llc_bs_ms.rs::process_incoming_ack
    // take_expected_ack_for_ssi (Z.134-142) which refuses to advance V(S)
    // if no outstanding acknowledged entry exists.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n)
            outstanding_ns <= 1'b0;
        else if (state == S_WAIT_ACK &&
                 bl_ack_valid &&
                 bl_ack_short_ssi == lat_ssi[9:0] &&
                 bl_ack_nr == outstanding_ns)
            outstanding_ns <= ~outstanding_ns;
    end

endmodule

`default_nettype wire
