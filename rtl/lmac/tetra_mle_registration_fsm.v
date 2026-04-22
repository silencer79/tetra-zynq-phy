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
//   3. Build the D-LOCATION-UPDATE-ACCEPT PDU (124 type-1 info bits) from
//      the latched ISSI/LA and the cell context.
//   4. Run the PDU through the SCH/HD encoder (CRC+RCPC+interleave+scramble)
//      and emit the 216 coded bits with a 1-cycle `dl_pdu_valid` pulse for
//      the DL slot multiplexer to inject into the next SCH/HD-bearing slot.
//
// Both the D-LOCATION-UPDATE builder and the SCH/HD encoder are instantiated
// inside this module.  The FSM owns the active-session-table ports
// exclusively for MVP — an arbiter can be wrapped around it later when a
// second MLE/CMCE FSM needs the same resource.
//
// Table-full behaviour: alloc miss just drops the request (no REJECT PDU on
// the MVP path — the MS will retry).  Wire a REJECT encode branch in as
// soon as we have a capacity-exhausted scenario worth handling.
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
    // DL output — 216 coded SCH/HD bits ready for slot mux
    // -----------------------------------------------------------------
    output reg  [215:0]                dl_pdu_bits,
    output reg                         dl_pdu_valid,

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

    // -------------------------------------------------------------------------
    // D-LOCATION-UPDATE builder — combinational, always watching the latched
    // request fields.  The FSM samples its output into the SCH/HD encoder at
    // S_ENCODE.
    // -------------------------------------------------------------------------
    wire [123:0] dloc_pdu_bits_w;

    tetra_d_location_update_encoder u_dloc (
        .pdu_reject      (1'b0),                 // MVP: accept only
        .addr_type       (lat_addr_type),
        .ssi             (lat_ssi),
        .la              (cfg_la),               // echo our cell LA
        .result          (2'b00),                // accept
        .encryption      (2'b00),                // clear
        .auth_result     (2'b01),                // success
        .subscriber_class(16'h0000),             // MVP: placeholder
        .pdu_bits        (dloc_pdu_bits_w)
    );

    // -------------------------------------------------------------------------
    // SCH/HD channel encoder — pulsed at S_ENCODE
    // -------------------------------------------------------------------------
    reg          sch_encode_start;
    wire [215:0] sch_coded_bits_w;
    wire         sch_coded_valid_w;

    tetra_sch_hd_encoder u_sch (
        .clk          (clk),
        .rst_n        (rst_n),
        .encode_start (sch_encode_start),
        .info_bits    (dloc_pdu_bits_w),
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
    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_CHECK_START = 4'd1;
    localparam [3:0] S_CHECK_WAIT  = 4'd2;
    localparam [3:0] S_ALLOC_START = 4'd3;
    localparam [3:0] S_ALLOC_WAIT  = 4'd4;
    localparam [3:0] S_WRITE       = 4'd5;
    localparam [3:0] S_ENCODE      = 4'd6;
    localparam [3:0] S_ENCODE_WAIT = 4'd7;
    localparam [3:0] S_DELIVER     = 4'd8;
    localparam [3:0] S_DROP        = 4'd9;

    reg [3:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            lat_addr_type     <= 3'd0;
            lat_ssi           <= 24'd0;
            lat_la            <= 14'd0;
            lat_slot          <= {AST_IDX_WIDTH{1'b0}};
            lat_existing      <= 1'b0;
            ast_wr_en         <= 1'b0;
            ast_wr_idx        <= {AST_IDX_WIDTH{1'b0}};
            ast_wr_data       <= {AST_REC_WIDTH{1'b0}};
            ast_q_start       <= 1'b0;
            ast_q_mode        <= 1'b0;
            ast_q_issi        <= 24'd0;
            sch_encode_start  <= 1'b0;
            dl_pdu_bits       <= 216'd0;
            dl_pdu_valid      <= 1'b0;
            busy              <= 1'b0;
            accept_pulse      <= 1'b0;
            drop_pulse        <= 1'b0;
        end else begin
            // Default strobes — every state may override
            ast_wr_en        <= 1'b0;
            ast_q_start      <= 1'b0;
            sch_encode_start <= 1'b0;
            dl_pdu_valid     <= 1'b0;
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
                state       <= S_ENCODE;
            end

            // -----------------------------------------------------------------
            S_ENCODE: begin
                sch_encode_start <= 1'b1;
                state            <= S_ENCODE_WAIT;
            end

            // -----------------------------------------------------------------
            S_ENCODE_WAIT: begin
                if (sch_coded_valid_w) begin
                    dl_pdu_bits <= sch_coded_bits_w;
                    state       <= S_DELIVER;
                end
            end

            // -----------------------------------------------------------------
            S_DELIVER: begin
                dl_pdu_valid <= 1'b1;
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
