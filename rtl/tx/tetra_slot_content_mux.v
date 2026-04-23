// =============================================================================
// tetra_slot_content_mux.v — Schedule -> Payload mux
// =============================================================================
//
// Picks per-slot burst attributes and 2x216-bit block payloads from the
// 16-bit schedule entry the Slot-Schedule BRAM returns for each (mn,fn,tn).
// Also routes the RTL-encoded BSCH (SB1) and AACH (BB) outputs into the
// tx_chain datapath.
//
// Class dispatch (single-writer, no override pattern):
//
//   class == 0  STATIC_BROADCAST
//     Idx-indexed lookup into the SW payload banks.  This is the only
//     path for broadcast-type slots (NDB/SB/MCCH/BNCH).  Scheduler
//     outputs are ignored for these slots.
//
//   class == 1  SIGNALLING
//     blk1/blk2/ndb2 come DIRECTLY from tetra_dl_signal_scheduler's
//     per-TN outputs.  The scheduler is the authoritative source for
//     every signalling-class slot: when the signalling queue is empty
//     it drives NULL-PDU idle content; when a PDU is queued for this
//     TN it drives the coded PDU; other TNs in the same frame see the
//     idle default.  No conditional override, no if/else mux — the
//     schedule entry's class field selects which source drives the slot.
//
// BRAM read strategy — Option A (pick-ahead, single read port)
// -----------------------------------------------------------
// The 4-slot parallel bundle to tx_chain must reflect the schedule
// entries for all 4 TNs of the current frame before each slot_pulse.
// With a single-port schedule BRAM we sequence 4 reads across 4
// sys-cycles and latch them into a local register array.
//
// Trigger timing:
//   * slot_pulse_sys && (tn_sys == 2'd3) — at the slot_pulse that marks
//     the START of TN=3 (last slot of the current frame), kick off a
//     4-entry refresh targeting the NEXT frame's (mn', fn').  Full slot
//     available for 4 reads (~6 sys-cycles total).
//   * A first_refresh_pending_sys one-shot flag (set at reset) triggers
//     an additional refresh on the first slot_pulse after reset,
//     targeting the CURRENT (mn, fn).
//
// Next-frame (fn', mn'[1:0]) wrap math (0-based counters):
//   fn == 17  : fn' = 0,       mn'[1:0] = mn[1:0] + 1 (2-bit wrap)
//   else      : fn' = fn + 1,  mn'[1:0] = mn[1:0]
//
// FSM:
//   S_IDLE   wait for trigger
//   S_RD0    addr valid for TN=0
//   S_RD1    addr valid for TN=1; latch BRAM data for TN=0 into reg0
//   S_RD2    addr valid for TN=2; latch [1]
//   S_RD3    addr valid for TN=3; latch [2]
//   S_CAP3   latch [3]; return to S_IDLE
//
// Payload mapping — class=STATIC_BROADCAST (0), idx:
//   0  NDB_SYSINFO       blk1 = ndb_block1_sw, blk2 = ndb_block2_sw
//   1  MCCH              blk1 = mcch_block1_sw, blk2 = mcch_block2_sw
//   2  BNCH              blk1 = bnch_block1_sw, blk2 = bnch_block2_sw
//   3  SB                blk1 = 0 (tx_chain routes sb1_coded directly),
//                        blk2 = sb_bkn2_sw
//   4  NDB2_half1_bnch   blk1 = ndb_block1_sw, blk2 = bnch_block2_sw
//   7  empty             blk1/blk2 = 0 (slot_en gated by schedule)
//   other (fallback)    blk1 = ndb_block1_sw, blk2 = ndb_block2_sw
//
// Payload mapping — class=SIGNALLING (1), all idx:
//   blk1 = sched_blk1_tn<k>_sys
//   blk2 = sched_blk2_tn<k>_sys
//   ndb2 = sched_ndb2_sys[k]
//   (scheduler delivers both NULL-PDU idle and active PDU content)
//
// sb_sb1_data_sys / sb_bb_data_sys are ALWAYS driven from sb1_coded_sys /
// aach_coded_sys regardless of schedule.  burst_mux consumes them only
// for SDB slots; ignored otherwise.
//
// Coding Rules: Verilog-2001 strict
//   R1  : one always block per register
//   R2  : _sys suffix
//   R4  : async active-low reset
//   R9  : no initial blocks
//   R10 : @(*) for combinatorial blocks
// =============================================================================

`default_nettype none

module tetra_slot_content_mux #(
    parameter BLOCK_BITS = 216,
    parameter BB_BITS    = 30,
    parameter SB1_BITS   = 120
) (
    input  wire                   clk_sys,
    input  wire                   rst_n_sys,

    // Timebase
    input  wire [1:0]             tn_sys,
    input  wire [4:0]             fn_sys,
    input  wire [5:0]             mn_sys,
    input  wire                   slot_pulse_sys,
    input  wire                   tdma_tick_sys,     // reserved; not used

    // Schedule BRAM read interface (Port B, externally-driven address)
    output wire [8:0]             sched_addr_sys,
    input  wire [15:0]            sched_data_sys,

    // RTL encoder outputs
    input  wire [SB1_BITS-1:0]    sb1_coded_sys,
    input  wire                   sb1_valid_sys,     // probe; not gated here
    input  wire [BB_BITS-1:0]     aach_coded_sys,
    input  wire                   aach_valid_sys,    // probe; not gated here

    // SW payload banks (216-bit each, slow-changing)
    input  wire [BLOCK_BITS-1:0]  ndb_block1_sw_sys,
    input  wire [BLOCK_BITS-1:0]  ndb_block2_sw_sys,
    input  wire [BLOCK_BITS-1:0]  mcch_block1_sw_sys,
    input  wire [BLOCK_BITS-1:0]  mcch_block2_sw_sys,
    input  wire [BLOCK_BITS-1:0]  bnch_block1_sw_sys,
    input  wire [BLOCK_BITS-1:0]  bnch_block2_sw_sys,
    input  wire [BLOCK_BITS-1:0]  sb_bkn2_sw_sys,

    // Per-TN signalling block bundle — authoritative source for every
    // class=SIGNALLING slot.  Driven by tetra_dl_signal_scheduler, fully
    // registered one frame ahead.  Always valid: NULL-PDU when queue is
    // empty, coded PDU content on the target TN when a PDU is queued.
    input  wire [BLOCK_BITS-1:0]  sched_blk1_tn0_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk2_tn0_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk1_tn1_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk2_tn1_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk1_tn2_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk2_tn2_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk1_tn3_sys,
    input  wire [BLOCK_BITS-1:0]  sched_blk2_tn3_sys,
    input  wire [3:0]             sched_ndb2_sys,

    // Outputs to tetra_tx_chain
    output reg  [3:0]             slot_burst_type_sys,
    output reg  [3:0]             slot_en_sys,
    output reg  [3:0]             slot_ndb2_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk1_slot0_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk1_slot1_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk1_slot2_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk1_slot3_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk2_slot0_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk2_slot1_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk2_slot2_sys,
    output reg  [BLOCK_BITS-1:0]  tx_blk2_slot3_sys,
    output reg  [SB1_BITS-1:0]    sb_sb1_data_sys,
    output reg  [BB_BITS-1:0]     sb_bb_data_sys,

    // Debug probes (latched schedule entries for ILA visibility)
    output wire [15:0]            dbg_sched_entry0_sys,
    output wire [15:0]            dbg_sched_entry1_sys,
    output wire [15:0]            dbg_sched_entry2_sys,
    output wire [15:0]            dbg_sched_entry3_sys
);

// =============================================================================
// Schedule entry latches — one 16-bit entry per TN
// =============================================================================
reg [15:0] sched_entry_reg_sys0;
reg [15:0] sched_entry_reg_sys1;
reg [15:0] sched_entry_reg_sys2;
reg [15:0] sched_entry_reg_sys3;

assign dbg_sched_entry0_sys = sched_entry_reg_sys0;
assign dbg_sched_entry1_sys = sched_entry_reg_sys1;
assign dbg_sched_entry2_sys = sched_entry_reg_sys2;
assign dbg_sched_entry3_sys = sched_entry_reg_sys3;

// =============================================================================
// Refresh FSM
// =============================================================================
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_RD0  = 3'd1;
localparam [2:0] S_RD1  = 3'd2;
localparam [2:0] S_RD2  = 3'd3;
localparam [2:0] S_RD3  = 3'd4;
localparam [2:0] S_CAP3 = 3'd5;

reg [2:0] state_sys;
reg [2:0] next_state_sys;

wire        fn_wrap_sys         = (fn_sys == 5'd17);
wire [4:0]  fn_next_sys         = fn_wrap_sys ? 5'd0             : (fn_sys + 5'd1);
wire [1:0]  mn_next_low2_sys    = fn_wrap_sys ? (mn_sys[1:0] + 2'd1)
                                               :  mn_sys[1:0];

reg [4:0] refresh_fn_sys;
reg [1:0] refresh_mn_low2_sys;

reg first_refresh_pending_sys;

wire refresh_trigger_sys = slot_pulse_sys &&
                           (first_refresh_pending_sys || (tn_sys == 2'd3));

always @(*) begin
    case (state_sys)
    S_IDLE:  next_state_sys = refresh_trigger_sys ? S_RD0 : S_IDLE;
    S_RD0:   next_state_sys = S_RD1;
    S_RD1:   next_state_sys = S_RD2;
    S_RD2:   next_state_sys = S_RD3;
    S_RD3:   next_state_sys = S_CAP3;
    S_CAP3:  next_state_sys = S_IDLE;
    default: next_state_sys = S_IDLE;
    endcase
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_IDLE;
    else
        state_sys <= next_state_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        refresh_fn_sys      <= 5'd0;
        refresh_mn_low2_sys <= 2'd0;
    end else if (state_sys == S_IDLE && refresh_trigger_sys) begin
        if (first_refresh_pending_sys) begin
            refresh_fn_sys      <= fn_sys;
            refresh_mn_low2_sys <= mn_sys[1:0];
        end else begin
            refresh_fn_sys      <= fn_next_sys;
            refresh_mn_low2_sys <= mn_next_low2_sys;
        end
    end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        first_refresh_pending_sys <= 1'b1;
    else if (state_sys == S_IDLE && refresh_trigger_sys && first_refresh_pending_sys)
        first_refresh_pending_sys <= 1'b0;
end

// =============================================================================
// Address mux — combinational (R10).
// =============================================================================
reg [4:0] eff_fn_sys;
reg [1:0] eff_mn_low2_sys;
always @(*) begin
    if (state_sys == S_IDLE && refresh_trigger_sys) begin
        if (first_refresh_pending_sys) begin
            eff_fn_sys      = fn_sys;
            eff_mn_low2_sys = mn_sys[1:0];
        end else begin
            eff_fn_sys      = fn_next_sys;
            eff_mn_low2_sys = mn_next_low2_sys;
        end
    end else begin
        eff_fn_sys      = refresh_fn_sys;
        eff_mn_low2_sys = refresh_mn_low2_sys;
    end
end

wire [8:0] mn72_sys = {eff_mn_low2_sys, 6'b0} + {3'b0, eff_mn_low2_sys, 3'b0};
wire [8:0] fn4_sys  = {2'b0, eff_fn_sys, 2'b00};
wire [8:0] base_addr_sys = mn72_sys + fn4_sys;

reg [1:0] tn_for_addr_sys;
always @(*) begin
    case (next_state_sys)
        S_RD0:   tn_for_addr_sys = 2'd0;
        S_RD1:   tn_for_addr_sys = 2'd1;
        S_RD2:   tn_for_addr_sys = 2'd2;
        S_RD3:   tn_for_addr_sys = 2'd3;
        default: tn_for_addr_sys = 2'd0;
    endcase
end

assign sched_addr_sys = base_addr_sys + {7'b0, tn_for_addr_sys};

// =============================================================================
// Entry capture
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys0 <= 16'h0000;
    else if (state_sys == S_RD0)
        sched_entry_reg_sys0 <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys1 <= 16'h0000;
    else if (state_sys == S_RD1)
        sched_entry_reg_sys1 <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys2 <= 16'h0000;
    else if (state_sys == S_RD2)
        sched_entry_reg_sys2 <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys3 <= 16'h0000;
    else if (state_sys == S_RD3)
        sched_entry_reg_sys3 <= sched_data_sys;
end

// =============================================================================
// Schedule entry decoders
// =============================================================================
function bus_is_sdb;    input [15:0] ent; begin bus_is_sdb    = (ent[5:4] == 2'b01); end endfunction
function bus_is_enable; input [15:0] ent; begin bus_is_enable = ent[2];              end endfunction
function bus_is_ndb2;   input [15:0] ent; begin bus_is_ndb2   = ent[3];              end endfunction
function bus_is_signal; input [15:0] ent; begin bus_is_signal = (ent[15:12] == 4'd1); end endfunction
function [5:0] bus_idx; input [15:0] ent; begin bus_idx       = ent[11:6];           end endfunction

// =============================================================================
// Per-TN class dispatch.  For each slot the schedule entry selects ONE
// source — STATIC_BROADCAST from the SW banks, or SIGNALLING from the
// scheduler's per-TN bundle.  No conditional override, no layered mux.
// =============================================================================
reg [BLOCK_BITS-1:0] blk1_mux_tn0_sys;
reg [BLOCK_BITS-1:0] blk2_mux_tn0_sys;
reg [BLOCK_BITS-1:0] blk1_mux_tn1_sys;
reg [BLOCK_BITS-1:0] blk2_mux_tn1_sys;
reg [BLOCK_BITS-1:0] blk1_mux_tn2_sys;
reg [BLOCK_BITS-1:0] blk2_mux_tn2_sys;
reg [BLOCK_BITS-1:0] blk1_mux_tn3_sys;
reg [BLOCK_BITS-1:0] blk2_mux_tn3_sys;

// TN=0
always @(*) begin
    if (bus_is_signal(sched_entry_reg_sys0)) begin
        blk1_mux_tn0_sys = sched_blk1_tn0_sys;
        blk2_mux_tn0_sys = sched_blk2_tn0_sys;
    end else begin
        case (bus_idx(sched_entry_reg_sys0))
            6'd0:    begin blk1_mux_tn0_sys = ndb_block1_sw_sys;  blk2_mux_tn0_sys = ndb_block2_sw_sys;  end
            6'd1:    begin blk1_mux_tn0_sys = mcch_block1_sw_sys; blk2_mux_tn0_sys = mcch_block2_sw_sys; end
            6'd2:    begin blk1_mux_tn0_sys = bnch_block1_sw_sys; blk2_mux_tn0_sys = bnch_block2_sw_sys; end
            6'd3:    begin blk1_mux_tn0_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn0_sys = sb_bkn2_sw_sys;     end
            6'd4:    begin blk1_mux_tn0_sys = ndb_block1_sw_sys;  blk2_mux_tn0_sys = bnch_block2_sw_sys; end
            6'd7:    begin blk1_mux_tn0_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn0_sys = {BLOCK_BITS{1'b0}}; end
            default: begin blk1_mux_tn0_sys = ndb_block1_sw_sys;  blk2_mux_tn0_sys = ndb_block2_sw_sys;  end
        endcase
    end
end

// TN=1
always @(*) begin
    if (bus_is_signal(sched_entry_reg_sys1)) begin
        blk1_mux_tn1_sys = sched_blk1_tn1_sys;
        blk2_mux_tn1_sys = sched_blk2_tn1_sys;
    end else begin
        case (bus_idx(sched_entry_reg_sys1))
            6'd0:    begin blk1_mux_tn1_sys = ndb_block1_sw_sys;  blk2_mux_tn1_sys = ndb_block2_sw_sys;  end
            6'd1:    begin blk1_mux_tn1_sys = mcch_block1_sw_sys; blk2_mux_tn1_sys = mcch_block2_sw_sys; end
            6'd2:    begin blk1_mux_tn1_sys = bnch_block1_sw_sys; blk2_mux_tn1_sys = bnch_block2_sw_sys; end
            6'd3:    begin blk1_mux_tn1_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn1_sys = sb_bkn2_sw_sys;     end
            6'd4:    begin blk1_mux_tn1_sys = ndb_block1_sw_sys;  blk2_mux_tn1_sys = bnch_block2_sw_sys; end
            6'd7:    begin blk1_mux_tn1_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn1_sys = {BLOCK_BITS{1'b0}}; end
            default: begin blk1_mux_tn1_sys = ndb_block1_sw_sys;  blk2_mux_tn1_sys = ndb_block2_sw_sys;  end
        endcase
    end
end

// TN=2
always @(*) begin
    if (bus_is_signal(sched_entry_reg_sys2)) begin
        blk1_mux_tn2_sys = sched_blk1_tn2_sys;
        blk2_mux_tn2_sys = sched_blk2_tn2_sys;
    end else begin
        case (bus_idx(sched_entry_reg_sys2))
            6'd0:    begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = ndb_block2_sw_sys;  end
            6'd1:    begin blk1_mux_tn2_sys = mcch_block1_sw_sys; blk2_mux_tn2_sys = mcch_block2_sw_sys; end
            6'd2:    begin blk1_mux_tn2_sys = bnch_block1_sw_sys; blk2_mux_tn2_sys = bnch_block2_sw_sys; end
            6'd3:    begin blk1_mux_tn2_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn2_sys = sb_bkn2_sw_sys;     end
            6'd4:    begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = bnch_block2_sw_sys; end
            6'd7:    begin blk1_mux_tn2_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn2_sys = {BLOCK_BITS{1'b0}}; end
            default: begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = ndb_block2_sw_sys;  end
        endcase
    end
end

// TN=3
always @(*) begin
    if (bus_is_signal(sched_entry_reg_sys3)) begin
        blk1_mux_tn3_sys = sched_blk1_tn3_sys;
        blk2_mux_tn3_sys = sched_blk2_tn3_sys;
    end else begin
        case (bus_idx(sched_entry_reg_sys3))
            6'd0:    begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = ndb_block2_sw_sys;  end
            6'd1:    begin blk1_mux_tn3_sys = mcch_block1_sw_sys; blk2_mux_tn3_sys = mcch_block2_sw_sys; end
            6'd2:    begin blk1_mux_tn3_sys = bnch_block1_sw_sys; blk2_mux_tn3_sys = bnch_block2_sw_sys; end
            6'd3:    begin blk1_mux_tn3_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn3_sys = sb_bkn2_sw_sys;     end
            6'd4:    begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = bnch_block2_sw_sys; end
            6'd7:    begin blk1_mux_tn3_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn3_sys = {BLOCK_BITS{1'b0}}; end
            default: begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = ndb_block2_sw_sys;  end
        endcase
    end
end

// =============================================================================
// Per-TN NDB2 selection — same class dispatch.
// =============================================================================
wire ndb2_tn0_w = bus_is_signal(sched_entry_reg_sys0) ? sched_ndb2_sys[0]
                                                      : bus_is_ndb2(sched_entry_reg_sys0);
wire ndb2_tn1_w = bus_is_signal(sched_entry_reg_sys1) ? sched_ndb2_sys[1]
                                                      : bus_is_ndb2(sched_entry_reg_sys1);
wire ndb2_tn2_w = bus_is_signal(sched_entry_reg_sys2) ? sched_ndb2_sys[2]
                                                      : bus_is_ndb2(sched_entry_reg_sys2);
wire ndb2_tn3_w = bus_is_signal(sched_entry_reg_sys3) ? sched_ndb2_sys[3]
                                                      : bus_is_ndb2(sched_entry_reg_sys3);

// =============================================================================
// Registered per-slot outputs (R1: one always block per register).
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_burst_type_sys <= 4'b0000;
    else
        slot_burst_type_sys <= {bus_is_sdb(sched_entry_reg_sys3),
                                bus_is_sdb(sched_entry_reg_sys2),
                                bus_is_sdb(sched_entry_reg_sys1),
                                bus_is_sdb(sched_entry_reg_sys0)};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_en_sys <= 4'b0000;
    else
        slot_en_sys <= {bus_is_enable(sched_entry_reg_sys3),
                        bus_is_enable(sched_entry_reg_sys2),
                        bus_is_enable(sched_entry_reg_sys1),
                        bus_is_enable(sched_entry_reg_sys0)};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_ndb2_sys <= 4'b0000;
    else
        slot_ndb2_sys <= {ndb2_tn3_w, ndb2_tn2_w, ndb2_tn1_w, ndb2_tn0_w};
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk1_slot0_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk1_slot0_sys <= blk1_mux_tn0_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk1_slot1_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk1_slot1_sys <= blk1_mux_tn1_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk1_slot2_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk1_slot2_sys <= blk1_mux_tn2_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk1_slot3_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk1_slot3_sys <= blk1_mux_tn3_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk2_slot0_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk2_slot0_sys <= blk2_mux_tn0_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk2_slot1_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk2_slot1_sys <= blk2_mux_tn1_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk2_slot2_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk2_slot2_sys <= blk2_mux_tn2_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) tx_blk2_slot3_sys <= {BLOCK_BITS{1'b0}};
    else            tx_blk2_slot3_sys <= blk2_mux_tn3_sys;
end

// =============================================================================
// sb_sb1_data_sys / sb_bb_data_sys — always driven from RTL encoders.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sb_sb1_data_sys <= {SB1_BITS{1'b0}};
    else            sb_sb1_data_sys <= sb1_coded_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sb_bb_data_sys <= {BB_BITS{1'b0}};
    else            sb_bb_data_sys <= aach_coded_sys;
end

// synthesis translate_off
wire _unused_sig_sys = sb1_valid_sys | aach_valid_sys | tdma_tick_sys;
// synthesis translate_on

endmodule

`default_nettype wire
