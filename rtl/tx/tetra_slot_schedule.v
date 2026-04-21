// =============================================================================
// tetra_slot_schedule.v — TDMA Slot Schedule Dual-Port BRAM (Plan Stufe 3/4)
// =============================================================================
//
// Tabellen-Lookup dense_idx -> 16-bit schedule_entry.  Port-B addressing
// is EXTERNALLY DRIVEN (Stufe-4 Option b): the caller computes the dense
// index (mn[1:0]*72 + fn*4 + tn[1:0]) and presents it on sched_b_addr_sys
// every cycle.  The BRAM read is unconditional and synchronous — the
// entry at the requested address appears on schedule_entry_sys one
// sys-cycle later.  There is no internal tdma_tick latch any more.
//
// Rationale: Stufe-4's content-mux FSM sequences 4 reads back-to-back on
// consecutive sys-cycles (one per TN) to refresh its local entry cache.
// A tdma_tick-triggered latch + combinational (mn,fn,tn) path inside the
// schedule module would either require 4 tdma_ticks (timebase doesn't
// do that) or would not stabilise the address between reads.  Driving
// the address externally gives the content-mux full control.
//
// Addressing
// ----------
// Both ports address a dense 288-entry memory:
//
//   dense_idx = mn[1:0] * 72 + fn[4:0] * 4 + tn[1:0]
//
// valid for mn in 0..3, fn in 0..17, tn in 0..3.  The AXI side exposes
// 144 32-bit words (word 0..143) where word k packs entries
// (2*k, 2*k+1) — lower 16 bits = even entry, upper 16 bits = odd entry.
// That's exactly the 576-byte layout specified in the plan and generated
// by scripts/gold_schedule.py (gen_gold_schedule_blob()).
//
// Ports
// -----
//   Port A  : clk_axi, 32-bit word-oriented write + readback.
//             AXI word index (0..143) packs TWO 16-bit schedule entries:
//               lower 16b = entry at dense_idx = 2*word_idx (even)
//               upper 16b = entry at dense_idx = 2*word_idx+1 (odd)
//             Byte strobes are honoured at 16-bit granularity:
//               wstrb[1:0] gates the lower half, wstrb[3:2] the upper half.
//   Port B  : clk_sys, caller drives sched_b_addr_sys[8:0] (dense idx).
//             schedule_entry_sys = mem[sched_b_addr_sys] one clk_sys later.
//             Out-of-range addresses (>= 288) return 0.
//
// Entry layout (plan §4 Stufe 3):
//   [15:12] payload_class  (0=STATIC_BROADCAST, 1=NULL_PDU, 2=TCH)
//   [11:6]  payload_idx    (6 bit, variant/channel)
//   [5:4]   burst_type     (00=NDB, 01=SDB, 10=reserved, 11=idle)
//   [3]     ndb2
//   [2]     enable
//   [1]     sys_time_inject
//   [0]     reserved
//
// Latency model (Port B):
//   cycle N    : sched_b_addr_sys presented on DUT input.
//   cycle N+1  : synchronous read of mem[sched_b_addr_sys@N] drives
//                schedule_entry_sys.
//
// Dual-port behaviour with collision:
//   AXI writes use Port A (clk_axi), RTL reads use Port B (clk_sys).
//   Race guidance (SW rule, not enforced here): do not rewrite an entry
//   within 2 frames of the tdma_tick that reads it.  Phase 4 loads the
//   table once at boot, so collisions are not a concern.
//
// Coding Rules: Verilog-2001 strict
//   R1  : one always block per register
//   R2  : _axi / _sys suffix on internal signals
//   R4  : async active-low resets, explicit reset values
//   R9  : no initial blocks
//   R10 : @(*) for combinatorial blocks
// =============================================================================

`default_nettype none

module tetra_slot_schedule (
    // ------------------------------------------------------------------
    // AXI (Port A) — 32-bit word-oriented writes + readback
    // ------------------------------------------------------------------
    input  wire        clk_axi,
    input  wire        rst_n_axi,
    input  wire        axi_we,              // 1-cycle write enable
    input  wire [7:0]  axi_addr,            // 0..143 word index (144 words)
    input  wire [31:0] axi_wdata,           // {upper_entry, lower_entry}
    input  wire [3:0]  axi_wstrb,           // byte strobes
    input  wire        axi_re,              // 1-cycle read enable
    output reg  [31:0] axi_rdata,           // registered one cycle after axi_re
    // ------------------------------------------------------------------
    // RTL (Port B) — clk_sys synchronous read, externally-driven address
    // ------------------------------------------------------------------
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire [8:0]  sched_b_addr_sys,    // dense idx 0..287
    output reg  [15:0] schedule_entry_sys
);

// ---------------------------------------------------------------------------
// Memory: 288 dense 16-bit entries (mn*72 + fn*4 + tn).  Implemented as
// a 288-deep reg array; Vivado infers a single RAMB18E1 (36 kb) for
// 288×16 dual-port, leaving most of the block unused but guaranteeing
// independent read/write clocks.
// ---------------------------------------------------------------------------
reg [15:0] mem [0:287];

// ---------------------------------------------------------------------------
// Port A — AXI write (two 16-bit entries per 32-bit word)
// ---------------------------------------------------------------------------
wire [8:0] axi_entry_addr_lo_axi = {axi_addr, 1'b0};  // 2*word_idx
wire [8:0] axi_entry_addr_hi_axi = {axi_addr, 1'b1};  // 2*word_idx+1

// Byte-strobe gating at 16-bit granularity: wstrb[1:0] -> lower half,
// wstrb[3:2] -> upper half.  Treat "any byte within the halfword
// asserted" as a write to that halfword.
wire axi_we_lo_axi = axi_we & (|axi_wstrb[1:0]);
wire axi_we_hi_axi = axi_we & (|axi_wstrb[3:2]);

// Guard against word_idx >= 144 (addr_lo would still be in-range but
// addr_hi == 287 is the max valid entry).  Silently drop out-of-range
// writes — the parent register bank pre-filters with the 0x400..0x63F
// window, so this is defensive.
wire axi_in_range_lo_axi = (axi_entry_addr_lo_axi < 9'd288);
wire axi_in_range_hi_axi = (axi_entry_addr_hi_axi < 9'd288);

// R1: memory write lower half
always @(posedge clk_axi) begin
    if (axi_we_lo_axi & axi_in_range_lo_axi)
        mem[axi_entry_addr_lo_axi[8:0]] <= axi_wdata[15:0];
end

// R1: memory write upper half
always @(posedge clk_axi) begin
    if (axi_we_hi_axi & axi_in_range_hi_axi)
        mem[axi_entry_addr_hi_axi[8:0]] <= axi_wdata[31:16];
end

// ---------------------------------------------------------------------------
// Port A — AXI read (32-bit word = {upper_entry, lower_entry})
// Registered one clk_axi cycle after axi_re, matching synchronous-read
// BRAM timing.
// ---------------------------------------------------------------------------
reg [15:0] axi_rd_lo_axi;
reg [15:0] axi_rd_hi_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        axi_rd_lo_axi <= 16'h0000;
    else if (axi_re & axi_in_range_lo_axi)
        axi_rd_lo_axi <= mem[axi_entry_addr_lo_axi[8:0]];
    else if (axi_re)
        axi_rd_lo_axi <= 16'h0000;
end

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        axi_rd_hi_axi <= 16'h0000;
    else if (axi_re & axi_in_range_hi_axi)
        axi_rd_hi_axi <= mem[axi_entry_addr_hi_axi[8:0]];
    else if (axi_re)
        axi_rd_hi_axi <= 16'h0000;
end

// R1: axi_rdata combinatorial alias of the two latched halves
always @(*) begin
    axi_rdata = {axi_rd_hi_axi, axi_rd_lo_axi};
end

// ---------------------------------------------------------------------------
// Port B — clk_sys synchronous read with externally-driven address.
//
// Every cycle, mem[sched_b_addr_sys] is clocked into schedule_entry_sys.
// One-cycle BRAM read latency.  Out-of-range addresses return 0 as a
// defensive measure (should never happen with the content-mux FSM).
// ---------------------------------------------------------------------------
wire rd_in_range_sys = (sched_b_addr_sys < 9'd288);

// R1: schedule_entry_sys output register — unconditional synchronous
// read of mem[sched_b_addr_sys] each cycle.
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        schedule_entry_sys <= 16'h0000;
    else if (rd_in_range_sys)
        schedule_entry_sys <= mem[sched_b_addr_sys];
    else
        schedule_entry_sys <= 16'h0000;
end

endmodule

`default_nettype wire
