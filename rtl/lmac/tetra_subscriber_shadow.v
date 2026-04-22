// =============================================================================
// tetra_subscriber_shadow.v
//
// Subscriber database shadow — a BRAM-backed table of 256 subscriber records
// written by the ARM (via AXI-Lite indirect window) and queried by the on-chip
// MLE/Registration FSM.
//
// Record layout (64 bit):
//   [63:40] issi          24 bit — TETRA short subscriber identity
//   [39:26] la            14 bit — location area
//   [25:8]  reserved      18 bit — (home-cell, sub-class … populated later)
//   [7]     permit_voice   1 bit
//   [6]     permit_data    1 bit
//   [5]     permit_reg     1 bit
//   [4:1]   priority       4 bit
//   [0]     valid          1 bit — slot occupied; lookup only matches when set
//
// Ports
//   AXI-Lite side (clk_axi):
//     wr_idx   — slot index 0..DEPTH-1
//     wr_data  — 64-bit record
//     wr_en    — 1-cycle write strobe
//   FSM side (clk_sys — single-clock project for now):
//     q_start  — 1-cycle pulse to kick off lookup
//     q_issi   — ISSI to search for
//     q_busy   — high while scan is in progress
//     q_done   — 1-cycle pulse when result valid
//     q_hit    — 1 if a matching valid record was found
//     q_slot   — slot index of the hit (undefined if q_hit=0)
//     q_record — full record (undefined if q_hit=0)
//
// Lookup is a linear scan through DEPTH BRAM entries, single pipelined read.
// Worst-case latency = DEPTH+2 clk cycles = 2.58 µs @ 100 MHz for 256 entries,
// well inside a TDMA slot budget (14.17 ms).
//
// Since clk_axi and clk_sys are the same fabric clock (clk_fpga_0) in this
// design, we use a single `clk` port and let write/read ports of the BRAM
// share it.  Splitting into true dual-clock is a trivial wrap if ever needed.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_subscriber_shadow #(
    parameter integer DEPTH      = 256,
    parameter integer IDX_WIDTH  = 8,     // must match $clog2(DEPTH)
    parameter integer REC_WIDTH  = 64,
    parameter integer ISSI_WIDTH = 24     // top ISSI_WIDTH bits of record
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // AXI-Lite (indirect) write port
    input  wire [IDX_WIDTH-1:0]       wr_idx,
    input  wire [REC_WIDTH-1:0]       wr_data,
    input  wire                       wr_en,

    // FSM lookup port
    input  wire                       q_start,
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

    // Synchronous read register (lives in BRAM output stage)
    reg [REC_WIDTH-1:0] rd_data;

    // Address currently driven to BRAM read port
    reg [IDX_WIDTH:0]   rd_addr_ext;      // 1 bit wider so DEPTH is representable
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
    reg                    scan_issue;       // driving an address this cycle
    reg                    scan_result;      // result of prev cycle's address is on rd_data
    reg [IDX_WIDTH-1:0]    scan_result_addr; // which address that was
    reg [ISSI_WIDTH-1:0]   issi_key;

    wire rec_valid_w  = rd_data[0];
    wire [ISSI_WIDTH-1:0] rec_issi_w = rd_data[REC_WIDTH-1 -: ISSI_WIDTH];
    wire match_w      = scan_result && rec_valid_w && (rec_issi_w == issi_key);
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
        end else begin
            q_done <= 1'b0;

            // --- Kick off a lookup ---------------------------------------
            if (q_start && !q_busy) begin
                q_busy            <= 1'b1;
                q_hit             <= 1'b0;
                issi_key          <= q_issi;
                rd_addr_ext       <= {(IDX_WIDTH+1){1'b0}};
                scan_issue        <= 1'b1;
                scan_result       <= 1'b0;
            end

            // --- Pipeline advance ----------------------------------------
            // Result of THIS cycle's BRAM read = last cycle's rd_addr.
            // Once we set scan_issue, next cycle rd_data holds that word.
            if (q_busy) begin
                // Compare stage: check previous cycle's read
                if (match_w) begin
                    q_hit    <= 1'b1;
                    q_slot   <= scan_result_addr;
                    q_record <= rd_data;
                    q_done   <= 1'b1;
                    q_busy   <= 1'b0;
                    scan_issue  <= 1'b0;
                    scan_result <= 1'b0;
                end else if (end_of_scan_w) begin
                    q_hit    <= 1'b0;
                    q_done   <= 1'b1;
                    q_busy   <= 1'b0;
                    scan_issue  <= 1'b0;
                    scan_result <= 1'b0;
                end else begin
                    // Advance address + result pipeline
                    if (scan_issue) begin
                        scan_result      <= 1'b1;
                        scan_result_addr <= rd_addr;
                        if (rd_addr_ext == DEPTH-1) begin
                            // last address just went out — stop issuing
                            scan_issue <= 1'b0;
                        end else begin
                            rd_addr_ext <= rd_addr_ext + 1'b1;
                        end
                    end else begin
                        // issue stopped but result in flight → let it settle
                        scan_result <= 1'b0;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
