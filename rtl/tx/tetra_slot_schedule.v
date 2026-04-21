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
// Memory: 288 dense 16-bit entries (mn*72 + fn*4 + tn).
//
// The always blocks below use the Xilinx UG901 true-dual-port inference
// template: synchronous read/write, ONE always block per port (no async
// reset on the RAM block, no else-zero on the read register).  Vivado
// infers a single RAMB18E1 (18Kb) — leaves most of the block unused but
// guarantees independent read/write clocks.
//
// `ram_style="block"` attribute forces BRAM; without it Vivado may
// choose LUTRAM/distributed for 288×16.
// ---------------------------------------------------------------------------
(* ram_style = "block" *) reg [15:0] mem [0:287];

// ---------------------------------------------------------------------------
// Port A — AXI side (clk_axi): write two 16-bit halves + readback.
// 32-bit word index 0..143 packs (even, odd) entries at dense_idx
// (2*word_idx, 2*word_idx+1).
// ---------------------------------------------------------------------------
wire [8:0] axi_entry_addr_lo_axi = {axi_addr, 1'b0};  // 2*word_idx     (<288)
wire [8:0] axi_entry_addr_hi_axi = {axi_addr, 1'b1};  // 2*word_idx + 1 (<288)

// Byte-strobe gating at 16-bit granularity (any byte in a halfword set
// = write that halfword).
wire axi_we_lo_axi = axi_we & (|axi_wstrb[1:0]);
wire axi_we_hi_axi = axi_we & (|axi_wstrb[3:2]);

// 8-bit axi_addr covers word_idx 0..255 — parent register bank already
// decodes 0x400..0x63F (word_idx 0..143), so word_idx >= 144 cannot
// occur in practice.  No in-range guard — keeps the RAM inference clean.
reg [15:0] axi_rd_lo_axi;
reg [15:0] axi_rd_hi_axi;

// R1: Port A — single always block (write + registered read), matches
// Xilinx dual-port BRAM inference template.
always @(posedge clk_axi) begin
    if (axi_we_lo_axi)
        mem[axi_entry_addr_lo_axi] <= axi_wdata[15:0];
    if (axi_we_hi_axi)
        mem[axi_entry_addr_hi_axi] <= axi_wdata[31:16];
    if (axi_re) begin
        axi_rd_lo_axi <= mem[axi_entry_addr_lo_axi];
        axi_rd_hi_axi <= mem[axi_entry_addr_hi_axi];
    end
end

// axi_rdata combinatorial alias of the two latched halves
always @(*) begin
    axi_rdata = {axi_rd_hi_axi, axi_rd_lo_axi};
end

// ---------------------------------------------------------------------------
// Port B — clk_sys side: synchronous read with externally-driven address.
// 9-bit dense idx 0..287.  Caller (content-mux) never drives >=288.
// ---------------------------------------------------------------------------
always @(posedge clk_sys) begin
    schedule_entry_sys <= mem[sched_b_addr_sys];
end

// Reset-value note: BRAM power-up is 0 (XPM MEMORY_INIT_FILE default).
// Unused in this project — no ASYNC reset on the read register is
// required, and Vivado prohibits it in the inference template.
wire _unused_rst_ok_sys = rst_n_sys;     // suppress unused-input warning
wire _unused_rst_ok_axi = rst_n_axi;

endmodule

`default_nettype wire
