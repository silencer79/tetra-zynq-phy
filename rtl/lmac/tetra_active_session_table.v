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
    parameter integer ISSI_WIDTH = 24,
    // Phase 6 C — TTL-Sweep configuration.
    // last_seen field offset inside the record (24-bit field).  The default
    // matches the Phase B AST layout (bits [REC_WIDTH-1-ISSI_WIDTH-1
    // : REC_WIDTH-ISSI_WIDTH-24] = bits [103:80] when REC_WIDTH=128).
    // Setting LAST_SEEN_WIDTH=0 disables the sweeper completely (legacy
    // mode for Phase A and earlier).
    parameter integer LAST_SEEN_WIDTH = 24,
    parameter integer LAST_SEEN_LSB   = REC_WIDTH - ISSI_WIDTH - LAST_SEEN_WIDTH
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
    output reg  [REC_WIDTH-1:0]       q_record,

    // Phase 6 C — TTL-Sweep (background scanner).
    //   sweep_enable      : gate from REG_DB_POLICY (or always-on)
    //   sweep_now         : free-running 24-bit multiframe counter
    //   sweep_threshold   : evict when (now - last_seen) > threshold
    //   sweep_tick        : 1-cycle pulse — advances scan_idx by 1.
    //                       Drive once per multiframe; FSM checks one
    //                       slot per tick.  64 ticks = full sweep cycle
    //                       (~65 s at 1.02 s/MF).
    //   sweep_evict_pulse : 1-cycle, fires when a slot is invalidated.
    //   sweep_idx         : current scan position (debug visibility).
    input  wire                       sweep_enable,
    input  wire [23:0]                sweep_now,
    input  wire [23:0]                sweep_threshold,
    input  wire                       sweep_tick,
    output reg                        sweep_evict_pulse,
    output wire [IDX_WIDTH-1:0]       sweep_idx
);

    // -------------------------------------------------------------------------
    // Storage — inferred block RAM (true dual-port).
    //   Port A : FSM scan/write (existing q_* / wr_*)
    //   Port B : TTL sweeper (Phase 6 C — independent read+invalidate)
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) reg [REC_WIDTH-1:0] mem [0:DEPTH-1];

    reg [REC_WIDTH-1:0]  rd_data;
    reg [IDX_WIDTH:0]    rd_addr_ext;     // 1 extra bit so DEPTH is representable
    wire [IDX_WIDTH-1:0] rd_addr = rd_addr_ext[IDX_WIDTH-1:0];

    // Sweeper port-B signals (declared early so the BRAM block can see them)
    reg [IDX_WIDTH-1:0]  sweep_scan_idx_r;
    reg [REC_WIDTH-1:0]  sweep_rd_data;
    reg                  sweep_invalidate_now;     // 1-cycle write-zero strobe

    assign sweep_idx = sweep_scan_idx_r;

    // Port A (FSM scan / external write)
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_idx] <= wr_data;
        end
        rd_data <= mem[rd_addr];
    end

    // Port B (TTL sweeper read + invalidate write).  Vivado infers a true
    // dual-port BRAM when each port is in its own always block.
    always @(posedge clk) begin
        if (sweep_invalidate_now) begin
            mem[sweep_scan_idx_r] <= {REC_WIDTH{1'b0}};
        end
        sweep_rd_data <= mem[sweep_scan_idx_r];
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

    // -------------------------------------------------------------------------
    // Phase 6 C — TTL Sweeper (round-robin background scanner, port B).
    //
    // Once per `sweep_tick` (~1 multiframe = 1.02 s), the FSM advances to
    // the next slot and reads sweep_rd_data on the following cycle.
    // After the read settles, it computes (sweep_now - last_seen) and
    // compares against sweep_threshold.  On expiry, it pulses
    // sweep_invalidate_now for one cycle, which writes {0…} into the slot
    // via port B, and emits sweep_evict_pulse.
    //
    // Three-stage pipeline:
    //   S_IDLE  → wait sweep_tick
    //   S_READ  → wait one cycle for BRAM read latency, sweep_rd_data valid
    //   S_CHECK → compare last_seen, decide invalidate, pulse evict
    //
    // 64 slots × 1 tick/MF = full sweep cycle ~65 s with default 1.02 s/MF.
    // -------------------------------------------------------------------------
    localparam [1:0] SW_IDLE       = 2'd0;
    localparam [1:0] SW_READ       = 2'd1;
    localparam [1:0] SW_CHECK      = 2'd2;
    localparam [1:0] SW_INVALIDATE = 2'd3;  // hold scan_idx for port-B write
    reg [1:0] sweep_state;

    wire                          sweep_rec_valid_w  = sweep_rd_data[0];
    wire [LAST_SEEN_WIDTH-1:0]    sweep_last_seen_w  =
        sweep_rd_data[LAST_SEEN_LSB +: LAST_SEEN_WIDTH];
    // Modular subtraction (now wraps every 16M MF, threshold also 24-bit).
    wire [23:0] sweep_age_w = sweep_now - {{(24-LAST_SEEN_WIDTH){1'b0}},
                                           sweep_last_seen_w};
    wire        sweep_expired_w =
        sweep_rec_valid_w && (sweep_age_w > sweep_threshold);

    always @(posedge clk) begin
        if (!rst_n) begin
            sweep_scan_idx_r     <= {IDX_WIDTH{1'b0}};
            sweep_state          <= SW_IDLE;
            sweep_invalidate_now <= 1'b0;
            sweep_evict_pulse    <= 1'b0;
        end else begin
            sweep_invalidate_now <= 1'b0;
            sweep_evict_pulse    <= 1'b0;

            case (sweep_state)
            SW_IDLE: begin
                if (sweep_enable && sweep_tick) begin
                    // address sweep_scan_idx_r is already on port B —
                    // result lands in sweep_rd_data after this edge.
                    sweep_state <= SW_READ;
                end
            end

            SW_READ: begin
                // BRAM read latency = 1 clock; sweep_rd_data is valid now.
                sweep_state <= SW_CHECK;
            end

            SW_CHECK: begin
                if (sweep_expired_w) begin
                    // Pulse invalidate_now NOW; port B writes mem[scan_idx]=0
                    // on the next edge.  Hold scan_idx through SW_INVALIDATE
                    // so the port-B write lands on the correct slot, then
                    // advance.
                    sweep_invalidate_now <= 1'b1;
                    sweep_evict_pulse    <= 1'b1;
                    sweep_state          <= SW_INVALIDATE;
                end else begin
                    sweep_scan_idx_r <= sweep_scan_idx_r + {{(IDX_WIDTH-1){1'b0}}, 1'b1};
                    sweep_state      <= SW_IDLE;
                end
            end

            SW_INVALIDATE: begin
                // Port-B write committed this cycle (sweep_invalidate_now
                // was set in SW_CHECK and is sampled on this edge).  Now
                // safe to advance scan_idx and return to idle.
                sweep_scan_idx_r <= sweep_scan_idx_r + {{(IDX_WIDTH-1){1'b0}}, 1'b1};
                sweep_state      <= SW_IDLE;
            end

            default: sweep_state <= SW_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
