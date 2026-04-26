// =============================================================================
// tetra_profile_table.v
//
// Phase 6 D-rev — ProfileTable per docs/ARCHITECTURE.md §9.2.
//
// 6-slot × 32-bit table of authorisation/policy profiles, referenced by
// EntityTable.profile_id.  Distributed-LUT-RAM — small enough that it does
// not need a BRAM, and fast enough for low-latency lookup.
//
// Record layout (32 bit, §9.2 verbatim):
//   [31:24]  max_call_duration  8    Sekunden, 0=unlimited, max 255 s
//   [23:16]  hangtime           8    × 100 ms, max 25.5 s
//   [15:12]  priority           4
//   [11: 9]  gila_class         3    M2-default = 3'b100 (=4)
//   [ 8: 7]  gila_lifetime      2    M2-default = 2'b01 (=1)
//   [ 6: 4]  reserved           3
//   [ 3]     permit_voice       1
//   [ 2]     permit_data        1
//   [ 1]     permit_reg         1
//   [ 0]     valid              1
//
// Slot 0 reset default: 0x0000_088F
//   bits[15:12]=priority=0
//   bits[11: 9]=gila_class=4    = 3'b100
//   bits[ 8: 7]=gila_lifetime=1 = 2'b01
//   bits[ 6: 4]=reserved=0
//   bits[ 3:0] =1111 (permit_voice=1 | permit_data=1 | permit_reg=1 | valid=1)
//   → 0000_1000_1000_1111 = 0x088F ✓
//
// AXI-Lite indirect window (§9.5 + fix_plan):
//   0x1C0  PROFILE_INDEX [2:0]  slot 0..5
//   0x1C4  PROFILE_DATA  [31:0] 32-bit record (single word, no DATA_HI)
//   0x1CC  PROFILE_CTRL  [0]=commit (W1S, single-cycle wr_en pulse)
//
// Read port: registered by-index — drive `rd_idx`, get `rd_data` next cycle.
//
// Slot 0 reset-loads to 0x0000_088F via the `initial` block so the M2
// bit-identity guard (Profile 0 → MTP3550 GILA = GSSI 0x2F4D61, lifetime=1,
// class=4) holds.  All other slots reset to 0 (valid=0).
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_profile_table #(
    parameter integer DEPTH      = 6,
    parameter integer IDX_WIDTH  = 3,     // $clog2(DEPTH) rounded up
    parameter integer REC_WIDTH  = 32
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // AXI-Lite (indirect) write port
    input  wire [IDX_WIDTH-1:0]       wr_idx,
    input  wire [REC_WIDTH-1:0]       wr_data,
    input  wire                       wr_en,

    // FSM read port (registered, BRAM-style: drive rd_idx → rd_data next cycle).
    input  wire [IDX_WIDTH-1:0]       rd_idx,
    output reg  [REC_WIDTH-1:0]       rd_data,

    // Phase 7 F.4 — independent AXI-Lite read port for profiles.cgi GET.
    // The MLE-FSM uses the `rd_idx`/`rd_data` pair above for inline
    // permit-checks.  The CGI GET path uses this second port so it can
    // observe live RTL state without contending for the FSM port and
    // without risking a same-cycle race between FSM and SW reads.
    //
    // Drive rd_idx_axi → rd_data_axi available next cycle (single-cycle
    // read latency, identical to the FSM port).
    input  wire [IDX_WIDTH-1:0]       rd_idx_axi,
    output reg  [REC_WIDTH-1:0]       rd_data_axi
);

    // Distributed-LUT-RAM — small array, never inferred as BRAM.
    (* ram_style = "distributed" *) reg [REC_WIDTH-1:0] mem [0:DEPTH-1];

    // Reset default: Profile 0 = 0x0000_088F (M2 bit-identity guard).
    // Distributed-LUT-RAM accepts `initial` for power-on / config-load values.
    integer i;
    initial begin
        mem[0] = 32'h0000_088F;
        for (i = 1; i < DEPTH; i = i + 1)
            mem[i] = 32'h0000_0000;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            // Pipe register only — memory contents persist across rst_n
            // (Vivado distributed-LUT-RAM rule).  Drive rd_data to slot-0
            // default during reset so a downstream consumer is never
            // exposed to undefined bits.
            rd_data     <= 32'h0000_088F;
            rd_data_axi <= 32'h0000_088F;
        end else begin
            if (wr_en && (wr_idx < DEPTH[IDX_WIDTH-1:0])) begin
                mem[wr_idx] <= wr_data;
            end
            rd_data     <= mem[rd_idx];
            rd_data_axi <= mem[rd_idx_axi];
        end
    end

endmodule

`default_nettype wire
