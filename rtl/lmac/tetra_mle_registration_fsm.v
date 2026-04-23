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
    output reg                         drop_pulse      // 1 cyc on table-full
);

    // -------------------------------------------------------------------------
    // Latched UL request
    // -------------------------------------------------------------------------
    reg [2:0]                   lat_addr_type;
    reg [23:0]                  lat_ssi;
    reg [13:0]                  lat_la;
    reg [AST_IDX_WIDTH-1:0]     lat_slot;
    reg                         lat_existing;
    reg [267:0]                 lat_info_bits;       // builder→encoder handoff

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
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (builder_start),
        .ssi            (lat_ssi),
        .addr_type      (lat_addr_type),
        .ns             (1'b0),                 // TODO: from AST record
        .nr             (1'b0),                 // TODO: from AST record
        .mm_pdu_bits    (dloc_mm_bits_w),
        .mm_pdu_len_bits(dloc_mm_len_w),
        .pdu_bits       (builder_pdu_bits_w),
        .valid          (builder_valid_w)
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

    reg [3:0] state;

    // Synchronous reset — Xilinx DRC (REQP-1839) flags async resets on
    // registers feeding BRAM control pins (WEBWE, ADDRBWRADDR) as memory-
    // corruption hazards.  Keep the AST ports async-reset-free.
    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            lat_addr_type     <= 3'd0;
            lat_ssi           <= 24'd0;
            lat_la            <= 14'd0;
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
        end else begin
            // Default strobes — every state may override
            ast_wr_en        <= 1'b0;
            ast_q_start      <= 1'b0;
            builder_start    <= 1'b0;
            sch_encode_start <= 1'b0;
            req_valid        <= 1'b0;
            accept_pulse     <= 1'b0;
            drop_pulse       <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (ul_req_valid) begin
                    lat_addr_type <= ul_addr_type;
                    lat_ssi       <= ul_ssi;
                    lat_la        <= ul_la;
                    busy          <= 1'b1;
                    state         <= S_CHECK_START;
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
                req_valid    <= 1'b1;
                accept_pulse <= 1'b1;
                state        <= S_IDLE;
            end

            // -----------------------------------------------------------------
            S_DROP: begin
                drop_pulse <= 1'b1;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
