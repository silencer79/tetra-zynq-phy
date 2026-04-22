// =============================================================================
// tetra_active_session_table.v
//
// Hot-state table for active TETRA sessions (registered MS, call setup,
// voice-active, paging …).  BRAM-backed table of DEPTH 64-bit records,
// indexed by a dense slot id 0..DEPTH-1.  Unlike the subscriber-shadow
// BRAM (which is written from the ARM DB manager), this table is written
// directly by the on-chip MLE/CMCE FSMs.
//
// Record layout is deliberately thin here — field semantics live in the
// owning FSM.  The only bits this module interprets are:
//   [REC_WIDTH-1 : REC_WIDTH-ISSI_WIDTH]  issi         (for query match)
//   [0]                                    valid        (for alloc match)
//
// Suggested higher-level layout (documented here for reference):
//   [63:40] issi            24 bit — session owner
//   [39:24] last_seen_tdma  16 bit — TDMA frame counter, updated by FSM
//                                      on every activity, swept for TTL
//   [23:13] reserved        11 bit
//   [12:8]  alloc_tn_fn      5 bit — allocated air-slot fingerprint
//   [7:5]   state            3 bit — 0=FREE 1=REG_PENDING 2=REGISTERED
//                                    3=CALL_SETUP 4=VOICE_ACTIVE 5=PAGING
//   [4:1]   reserved         4 bit
//   [0]     valid            1 bit — 0 means slot is free/invalid
//
// Ports
//   Write port (clk):
//     wr_idx   — slot index (FSM-supplied, either from a prior alloc or
//                 from a query hit that the FSM is updating).
//     wr_data  — 64-bit record.
//     wr_en    — 1-cycle write strobe.
//
//   Lookup port:
//     q_start  — 1-cycle pulse to kick off a scan.
//     q_mode   — 0 = query (match valid && issi==q_issi)
//                 1 = alloc (match !valid; q_issi ignored)
//     q_issi   — ISSI to search for in query mode.
//     q_busy   — high during scan.
//     q_done   — 1-cycle pulse when scan finished.
//     q_hit    — query: 1 if matching valid record found
//                 alloc: 1 if a free slot was found (i.e. table not full).
//     q_slot   — index of the first matching slot (undefined if !q_hit).
//     q_record — full record at that slot (undefined if !q_hit).
//
// Latency: DEPTH+2 clk cycles worst case (linear scan).  For DEPTH=64 at
// 100 MHz this is ~0.66 µs — a single scan fits comfortably within one
// TDMA slot (14.17 ms).  Multiple ops per slot are fine.
//
// Concurrency: wr_en and q_start are assumed never to be simultaneously
// targeting an in-flight address the scan has already passed; the
// expected usage pattern is "scan → get result → write on next cycle".
// Writes are synchronous — the scan sees the new value on the cycle
// following wr_en.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_active_session_table #(
    parameter integer DEPTH      = 64,
    parameter integer IDX_WIDTH  = 6,     // $clog2(DEPTH)
    parameter integer REC_WIDTH  = 64,
    parameter integer ISSI_WIDTH = 24
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // FSM write port — single-cycle synchronous write
    input  wire [IDX_WIDTH-1:0]       wr_idx,
    input  wire [REC_WIDTH-1:0]       wr_data,
    input  wire                       wr_en,

    // Lookup / alloc scan port
    input  wire                       q_start,
    input  wire                       q_mode,       // 0=query, 1=alloc
    input  wire [ISSI_WIDTH-1:0]      q_issi,
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

    reg [REC_WIDTH-1:0]  rd_data;
    reg [IDX_WIDTH:0]    rd_addr_ext;     // 1 extra bit so DEPTH is representable
    wire [IDX_WIDTH-1:0] rd_addr = rd_addr_ext[IDX_WIDTH-1:0];

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_idx] <= wr_data;
        end
        rd_data <= mem[rd_addr];
    end

    // -------------------------------------------------------------------------
    // Scan pipeline
    // -------------------------------------------------------------------------
    reg                    scan_issue;
    reg                    scan_result;
    reg [IDX_WIDTH-1:0]    scan_result_addr;
    reg [ISSI_WIDTH-1:0]   issi_key;
    reg                    mode_q;          // latched q_mode for the scan

    wire rec_valid_w  = rd_data[0];
    wire [ISSI_WIDTH-1:0] rec_issi_w = rd_data[REC_WIDTH-1 -: ISSI_WIDTH];

    wire query_match_w = scan_result && rec_valid_w && (rec_issi_w == issi_key);
    wire alloc_match_w = scan_result && !rec_valid_w;
    wire match_w       = mode_q ? alloc_match_w : query_match_w;
    wire end_of_scan_w = scan_result && (scan_result_addr == DEPTH-1);

    always @(posedge clk) begin
        if (!rst_n) begin
            q_busy           <= 1'b0;
            q_done           <= 1'b0;
            q_hit            <= 1'b0;
            q_slot           <= {IDX_WIDTH{1'b0}};
            q_record         <= {REC_WIDTH{1'b0}};
            rd_addr_ext      <= {(IDX_WIDTH+1){1'b0}};
            scan_issue       <= 1'b0;
            scan_result      <= 1'b0;
            scan_result_addr <= {IDX_WIDTH{1'b0}};
            issi_key         <= {ISSI_WIDTH{1'b0}};
            mode_q           <= 1'b0;
        end else begin
            q_done <= 1'b0;

            if (q_start && !q_busy) begin
                q_busy      <= 1'b1;
                q_hit       <= 1'b0;
                issi_key    <= q_issi;
                mode_q      <= q_mode;
                rd_addr_ext <= {(IDX_WIDTH+1){1'b0}};
                scan_issue  <= 1'b1;
                scan_result <= 1'b0;
            end

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
