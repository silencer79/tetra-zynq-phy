// =============================================================================
// tetra_entity_table.v
//
// Phase 6 D-rev — EntityTable per docs/ARCHITECTURE.md §9.2.
//
// Persistent list of all known entities (ISSIs + GSSIs) on this BS.  Written
// from the ARM (via AXI-Lite indirect window 0x180..0x18C) and queried by the
// on-chip MLE/Registration FSM.  No permits, no LA, no priority — those live
// in the Profile Table, referenced by `profile_id`.
//
// Record layout (64 bit, §9.2 verbatim):
//   [63:40]  entity_id     24    ISSI ODER GSSI
//   [39]     entity_type    1    0=ISSI, 1=GSSI
//   [38:35]  profile_id     4    Index in Profile Table (0..5)
//   [34: 1]  reserved      34
//   [ 0]     valid          1    slot occupied; lookup only matches when set
//
// Lookup ports
//   Standard (FSM): match on (entity_id, entity_type) when q_match_type=1,
//                   match on entity_id only when q_match_type=0 (legacy
//                   ISSI-only path, kept for first-pass MLE attach).
//
// Default-GSSI scan port (no entity_id key — find first valid entry with
//   entity_type=1).  Used by MLE-FSM in S_ENTITY_QUERY_DEFAULT_GSSI when
//   AST.group_count==0 (Phase D — RX IE parser not yet wired).
//
// Lookup is a linear scan through DEPTH BRAM entries, single pipelined read.
// Worst-case latency = DEPTH+2 clk cycles ≈ 2.58 µs @ 100 MHz for 256 entries.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_entity_table #(
    parameter integer DEPTH      = 256,
    parameter integer IDX_WIDTH  = 8,     // $clog2(DEPTH)
    parameter integer REC_WIDTH  = 64,
    parameter integer ID_WIDTH   = 24     // entity_id width (ISSI/GSSI = 24 bit)
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // AXI-Lite (indirect) write port
    input  wire [IDX_WIDTH-1:0]       wr_idx,
    input  wire [REC_WIDTH-1:0]       wr_data,
    input  wire                       wr_en,

    // FSM lookup port
    //   q_match_type = 0 : match on entity_id only (any type)
    //                  1 : match on (entity_id, entity_type)
    //   q_default_gssi_scan = 1 : ignore q_id, match first valid+entity_type=1
    //                              (used for fallback group lookup)
    input  wire                       q_start,
    input  wire [ID_WIDTH-1:0]        q_id,
    input  wire                       q_type,
    input  wire                       q_match_type,
    input  wire                       q_default_gssi_scan,
    output reg                        q_busy,
    output reg                        q_done,
    output reg                        q_hit,
    output reg  [IDX_WIDTH-1:0]       q_slot,
    output reg  [REC_WIDTH-1:0]       q_record
);

    // -------------------------------------------------------------------------
    // Storage — inferred block RAM
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) reg [REC_WIDTH-1:0] mem [0:DEPTH-1];

    // Synchronous read register
    reg [REC_WIDTH-1:0] rd_data;

    reg [IDX_WIDTH:0]    rd_addr_ext;
    wire [IDX_WIDTH-1:0] rd_addr = rd_addr_ext[IDX_WIDTH-1:0];

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_idx] <= wr_data;
        end
        rd_data <= mem[rd_addr];
    end

    // -------------------------------------------------------------------------
    // Scan pipeline — one stage of latency between address-out and data-in
    // -------------------------------------------------------------------------
    reg                    scan_issue;
    reg                    scan_result;
    reg [IDX_WIDTH-1:0]    scan_result_addr;
    reg [ID_WIDTH-1:0]     id_key;
    reg                    type_key;
    reg                    match_type_key;
    reg                    default_gssi_scan_key;

    // Field projections from rd_data
    wire                   rec_valid_w   = rd_data[0];
    wire [ID_WIDTH-1:0]    rec_id_w      = rd_data[REC_WIDTH-1 -: ID_WIDTH];
    wire                   rec_type_w    = rd_data[REC_WIDTH-1-ID_WIDTH];

    wire id_match_w        = (rec_id_w == id_key);
    wire type_match_w      = (rec_type_w == type_key);
    wire normal_match_w    = scan_result && rec_valid_w && id_match_w
                             && (!match_type_key || type_match_w);
    wire default_gssi_match_w =
        scan_result && rec_valid_w && (rec_type_w == 1'b1);

    wire match_w       = default_gssi_scan_key ? default_gssi_match_w
                                                : normal_match_w;
    wire end_of_scan_w = scan_result && (scan_result_addr == DEPTH-1);

    always @(posedge clk) begin
        if (!rst_n) begin
            q_busy                <= 1'b0;
            q_done                <= 1'b0;
            q_hit                 <= 1'b0;
            q_slot                <= {IDX_WIDTH{1'b0}};
            q_record              <= {REC_WIDTH{1'b0}};
            rd_addr_ext           <= {(IDX_WIDTH+1){1'b0}};
            scan_issue            <= 1'b0;
            scan_result           <= 1'b0;
            scan_result_addr      <= {IDX_WIDTH{1'b0}};
            id_key                <= {ID_WIDTH{1'b0}};
            type_key              <= 1'b0;
            match_type_key        <= 1'b0;
            default_gssi_scan_key <= 1'b0;
        end else begin
            q_done <= 1'b0;

            // --- Kick off a lookup ---------------------------------------
            if (q_start && !q_busy) begin
                q_busy                <= 1'b1;
                q_hit                 <= 1'b0;
                id_key                <= q_id;
                type_key              <= q_type;
                match_type_key        <= q_match_type;
                default_gssi_scan_key <= q_default_gssi_scan;
                rd_addr_ext           <= {(IDX_WIDTH+1){1'b0}};
                scan_issue            <= 1'b1;
                scan_result           <= 1'b0;
            end

            // --- Pipeline advance ----------------------------------------
            if (q_busy) begin
                if (match_w) begin
                    q_hit       <= 1'b1;
                    q_slot      <= scan_result_addr;
                    q_record    <= rd_data;
                    q_done      <= 1'b1;
                    q_busy      <= 1'b0;
                    scan_issue  <= 1'b0;
                    scan_result <= 1'b0;
                end else if (end_of_scan_w) begin
                    q_hit       <= 1'b0;
                    q_done      <= 1'b1;
                    q_busy      <= 1'b0;
                    scan_issue  <= 1'b0;
                    scan_result <= 1'b0;
                end else begin
                    if (scan_issue) begin
                        scan_result      <= 1'b1;
                        scan_result_addr <= rd_addr;
                        if (rd_addr_ext == DEPTH-1) begin
                            scan_issue <= 1'b0;
                        end else begin
                            rd_addr_ext <= rd_addr_ext + 1'b1;
                        end
                    end else begin
                        scan_result <= 1'b0;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
