// =============================================================================
// tetra_slot_content_mux.v — Schedule -> Payload mux (Plan Stufe 4)
// =============================================================================
//
// Picks the per-slot burst attributes (burst_type, enable, ndb2) and the
// per-slot 2x216-bit block payloads based on the 16-bit schedule entry
// that the Slot-Schedule BRAM returns for each (mn, fn, tn).  Also routes
// the RTL-encoded BSCH (SB1) and AACH (BB) outputs into the tx_chain
// datapath, replacing the SW-driven REG_SB_SB1_* / REG_SB_BB paths.
//
// BRAM read strategy — Option A (pick-ahead, single read port)
// -----------------------------------------------------------
// tetra_tx_chain receives a 4-slot parallel bundle; before each
// slot_pulse the bundle must reflect the schedule entries for all 4
// TNs of the current frame.  With a single-port schedule BRAM we
// sequence 4 reads across 4 sys-cycles and latch them into a local
// register array sched_entry_reg[0..3][15:0].
//
// Trigger timing:
//   * slot_pulse_sys && (tn_sys == 2'd3) — at the slot_pulse that marks
//     the START of TN=3 (the last slot of the current frame), we kick
//     off a 4-entry refresh targeting the NEXT frame's (mn', fn').  We
//     have a full slot (~5556 sys-cycles at 100 MHz) to complete the 4
//     reads (which take ~6 cycles total including BRAM latency), so
//     the refresh finishes long before slot_pulse of the new TN=0 fires.
//   * A first_refresh_pending_sys one-shot flag (set at reset) triggers
//     an additional refresh on the first slot_pulse after reset,
//     targeting the CURRENT (mn, fn).  Ensures the initial frame has
//     correct entries too.
//
// Next-frame (fn', mn'[1:0]) wrap math (0-based counters):
//   fn == 17  : fn' = 0,       mn'[1:0] = mn[1:0] + 1 (natural 2-bit wrap)
//   else      : fn' = fn + 1,  mn'[1:0] = mn[1:0]
// Schedule only consumes mn[1:0]; the full mn counter wraps at 60 but
// the schedule is mn%4-indexed, so the 2-bit natural wrap is the right
// semantic for schedule addressing.
//
// FSM:
//   S_IDLE   wait for trigger
//   S_RD0    addr valid for TN=0 (BRAM captures on this edge, read next)
//   S_RD1    addr valid for TN=1; latch BRAM data for TN=0 into reg0
//   S_RD2    addr valid for TN=2; latch [1]
//   S_RD3    addr valid for TN=3; latch [2]
//   S_CAP3   latch [3]; return to S_IDLE
//
// Schedule BRAM protocol (see tetra_slot_schedule.v):
//   On cycle N the top-level ties sched_addr_sys to some dense index.
//   On cycle N's posedge clk_sys the BRAM samples the address and
//   outputs mem[addr] on sched_data_sys at cycle N+1.  We therefore
//   need the FSM address to be valid on the cycle PRECEDING the capture
//   cycle.
//
// Payload mapping — class=STATIC_BROADCAST (0), idx:
//   0  NDB_SYSINFO       blk1 = ndb_block1_sw, blk2 = ndb_block2_sw
//   1  MCCH              blk1 = mcch_block1_sw, blk2 = mcch_block2_sw
//   2  BNCH              blk1 = bnch_block1_sw, blk2 = bnch_block2_sw
//   3  SB                SDB burst — blk1 ignored by tx_chain (routes
//                        sb_sb1_data_sys), blk2 = sb_bkn2_sw.  We drive
//                        blk1 = 0 for cleanliness.
//   4  NDB2_half1_bnch   blk1 = ndb_block1_sw, blk2 = bnch_block2_sw
//   7  empty             blk1/blk2 = 0 (enable bit in schedule gates TX)
//   other (fallback)    blk1 = ndb_block1_sw, blk2 = ndb_block2_sw
//
// Payload mapping — class=NULL_PDU (1), idx=0:
//   blk1 = null_pdu_bits_sys (already SCH/HD-coded 216 bits, SW-computed
//   once at boot — see Stufe-4 decision in the encoder report).
//   blk2 = ndb_block2_sw (companion half: SYSINFO / BNCH per Gold).
//
// sb_sb1_data_sys / sb_bb_data_sys outputs are ALWAYS driven from the
// RTL encoder outputs sb1_coded_sys / aach_coded_sys, regardless of the
// schedule entry.  The burst_mux consumes them only for SDB slots; they
// are ignored otherwise.
//
// Timing caveat (pre-existing, not introduced by this module): the
// sb1/aach encoders are started by the top-level on slot_pulse_sys of
// the CURRENT slot, so their output for slot K is only fully settled
// ~142 clk_sys cycles AFTER slot K's slot_pulse.  In SDB slots the
// burst_mux latches sb1_data_sys on slot_pulse (cold start) or during
// the preceding slot (chain).  See final report for timing analysis.
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

    // NULL-PDU register bank — 216-bit already-SCH/HD-coded payload
    input  wire [BLOCK_BITS-1:0]  null_pdu_bits_sys,

    // MLE signalling response — one-shot DL PDU produced by the MLE
    // registration FSM.  When `dl_signal_valid_sys` pulses, the 216-bit
    // `dl_signal_bits_sys` is latched and overrides TN=1 BKN1 on the next
    // slot_pulse for TN=1, then pending clears.  The MS sees one D-LOC-
    // UPDATE-ACCEPT on the advertised signalling carrier and transitions
    // to registered.
    input  wire [BLOCK_BITS-1:0]  dl_signal_bits_sys,
    input  wire                   dl_signal_valid_sys,
    output wire                   dl_signal_pending_sys,

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
// MLE signalling response — latched one-shot DL payload
//
// Snapshot `dl_signal_bits_sys` on any `dl_signal_valid_sys` pulse and hold
// it until TN=1's slot_pulse consumes it (the injection point).  Clearing
// the pending flag one cycle after the consumption pulse keeps the override
// stable throughout TN=1's transmit window.
// =============================================================================
// Two-stage pending: a TN=1 slot_pulse must pass with pending HIGH (apply)
// BEFORE the TN=2 slot_pulse can consume it.  Without this, a valid that
// fires mid-TN=1 window sets pending too late for the burst_mux capture
// (which latches block1[1] shortly after the TN=1 slot_pulse), and the
// TN=2 consume then throws the payload away before any TN=1 capture ever
// saw it — injection silently lost.
reg [BLOCK_BITS-1:0] dl_signal_latched_sys;
reg                  dl_signal_pending_r_sys;
reg                  dl_signal_seen_tn1_sys;
assign dl_signal_pending_sys = dl_signal_pending_r_sys;

wire dl_signal_apply_tn1_sys = dl_signal_pending_r_sys && slot_pulse_sys
                               && (tn_sys == 2'd1);
wire dl_signal_consume_sys   = dl_signal_pending_r_sys && dl_signal_seen_tn1_sys
                               && slot_pulse_sys && (tn_sys == 2'd2);

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        dl_signal_latched_sys   <= {BLOCK_BITS{1'b0}};
        dl_signal_pending_r_sys <= 1'b0;
        dl_signal_seen_tn1_sys  <= 1'b0;
    end else begin
        if (dl_signal_valid_sys) begin
            dl_signal_latched_sys   <= dl_signal_bits_sys;
            dl_signal_pending_r_sys <= 1'b1;
            dl_signal_seen_tn1_sys  <= 1'b0;
        end else if (dl_signal_consume_sys) begin
            dl_signal_pending_r_sys <= 1'b0;
            dl_signal_seen_tn1_sys  <= 1'b0;
        end else if (dl_signal_apply_tn1_sys) begin
            dl_signal_seen_tn1_sys  <= 1'b1;
        end
    end
end

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

// Next-frame wrap math from (tn=3, fn, mn[1:0])
wire        fn_wrap_sys         = (fn_sys == 5'd17);
wire [4:0]  fn_next_sys         = fn_wrap_sys ? 5'd0             : (fn_sys + 5'd1);
wire [1:0]  mn_next_low2_sys    = fn_wrap_sys ? (mn_sys[1:0] + 2'd1)
                                               :  mn_sys[1:0];

// Refresh target registers — latched when the FSM leaves S_IDLE.  Keeps
// the 4-cycle address sequence pointed at a consistent (mn', fn').
reg [4:0] refresh_fn_sys;
reg [1:0] refresh_mn_low2_sys;

// First-refresh one-shot: on the first slot_pulse after reset, refresh
// targeting the CURRENT (mn, fn) so the initial frame has correct
// entries.  Normal refreshes (tn==3 trigger) target the NEXT frame.
reg first_refresh_pending_sys;

wire refresh_trigger_sys = slot_pulse_sys &&
                           (first_refresh_pending_sys || (tn_sys == 2'd3));

// Next-state logic (R10)
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

// R1: state register
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_IDLE;
    else
        state_sys <= next_state_sys;
end

// R1: refresh target latches — captured at trigger time
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

// R1: first_refresh_pending_sys — clear after first successful kick-off
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        first_refresh_pending_sys <= 1'b1;
    else if (state_sys == S_IDLE && refresh_trigger_sys && first_refresh_pending_sys)
        first_refresh_pending_sys <= 1'b0;
end

// =============================================================================
// Address mux — combinational (R10).  Drives sched_addr_sys based on
// next_state so the address is stable for the entire cycle leading up
// to the BRAM capture.
//
// dense_idx = mn[1:0]*72 + fn*4 + tn[1:0]   (matches tetra_slot_schedule)
//           = mn*64 + mn*8 + fn*4 + tn
//
// For the first address (state==S_IDLE & trigger→next_state==S_RD0), the
// refresh latches haven't been updated yet on this cycle — they'll latch
// at the SAME clock edge that transitions state to S_RD0.  So for cycle N
// we must forward the computed (mn', fn') combinationally, then use the
// registered refresh_fn_sys / refresh_mn_low2_sys from cycle N+1 onward.
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

// tn selected by NEXT state so the address is valid entering the state
// on the clock edge.
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
//
// Timing (BRAM synchronous-read, 1-cycle latency):
//   cycle N   : state=S_IDLE, trigger fires. next_state=S_RD0,
//               tn_for_addr=0, sched_addr=addr(TN=0).  BRAM samples addr
//               at posedge N+1.
//   cycle N+1 : state=S_RD0, sched_data=mem[addr(TN=0)] (BRAM output).
//               next_state=S_RD1, sched_addr=addr(TN=1).
//   cycle N+2 : state=S_RD1, sched_data=mem[addr(TN=1)].
//   cycle N+3 : state=S_RD2, sched_data=mem[addr(TN=2)].
//   cycle N+4 : state=S_RD3, sched_data=mem[addr(TN=3)].
//   cycle N+5 : state=S_CAP3, sched_data (stale) — FSM returns to S_IDLE.
//
// A posedge-triggered always block with `state_sys == S_RDk` condition
// samples state_sys AT EDGE TIME (pre-update value), so:
//   state==S_RD0 at posedge N+1→N+2 → reg latches mem[addr(TN=0)]
//   state==S_RD1 at posedge N+2→N+3 → reg latches mem[addr(TN=1)]
//   state==S_RD2 at posedge N+3→N+4 → reg latches mem[addr(TN=2)]
//   state==S_RD3 at posedge N+4→N+5 → reg latches mem[addr(TN=3)]
// =============================================================================
// R1: reg0 — TN=0
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys0 <= 16'h0000;
    else if (state_sys == S_RD0)
        sched_entry_reg_sys0 <= sched_data_sys;
end

// R1: reg1 — TN=1
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys1 <= 16'h0000;
    else if (state_sys == S_RD1)
        sched_entry_reg_sys1 <= sched_data_sys;
end

// R1: reg2 — TN=2
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys2 <= 16'h0000;
    else if (state_sys == S_RD2)
        sched_entry_reg_sys2 <= sched_data_sys;
end

// R1: reg3 — TN=3
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sched_entry_reg_sys3 <= 16'h0000;
    else if (state_sys == S_RD3)
        sched_entry_reg_sys3 <= sched_data_sys;
end

// =============================================================================
// Combinational per-TN payload selection
//
// For each TN k, derive:
//   burst_type_k  = entry[5:4] == 01 -> SDB (bit), 00 -> NDB.
//     The tx_chain `slot_burst_type_sys` bit is 1-bit (0=NDB, 1=SDB),
//     so we condense entry[5:4]: SDB iff entry[5:4] == 2'b01.
//   enable_k      = entry[2]
//   ndb2_k        = entry[3]
//   blk1_k / blk2_k = from payload_class + payload_idx lookup
// =============================================================================
// Helper macros-as-function: decode class, idx
function bus_is_sdb;    input [15:0] ent; begin bus_is_sdb   = (ent[5:4] == 2'b01); end endfunction
function bus_is_enable; input [15:0] ent; begin bus_is_enable= ent[2];              end endfunction
function bus_is_ndb2;   input [15:0] ent; begin bus_is_ndb2  = ent[3];              end endfunction

function [3:0] bus_class;  input [15:0] ent; begin bus_class = ent[15:12];          end endfunction
function [5:0] bus_idx;    input [15:0] ent; begin bus_idx   = ent[11:6];           end endfunction

// Combinational per-TN outputs
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
    case ({bus_class(sched_entry_reg_sys0), bus_idx(sched_entry_reg_sys0)})
        {4'd0, 6'd0}: begin // NDB_SYSINFO
            blk1_mux_tn0_sys = ndb_block1_sw_sys;
            blk2_mux_tn0_sys = ndb_block2_sw_sys;
        end
        {4'd0, 6'd1}: begin // MCCH
            blk1_mux_tn0_sys = mcch_block1_sw_sys;
            blk2_mux_tn0_sys = mcch_block2_sw_sys;
        end
        {4'd0, 6'd2}: begin // BNCH (SDB blk2 case covered below for idx=3)
            blk1_mux_tn0_sys = bnch_block1_sw_sys;
            blk2_mux_tn0_sys = bnch_block2_sw_sys;
        end
        {4'd0, 6'd3}: begin // SB (SDB) — blk1 = 0 (tx_chain uses sb_sb1_data_sys)
            blk1_mux_tn0_sys = {BLOCK_BITS{1'b0}};
            blk2_mux_tn0_sys = sb_bkn2_sw_sys;
        end
        {4'd0, 6'd4}: begin // NDB2_half1_bnch
            blk1_mux_tn0_sys = ndb_block1_sw_sys;
            blk2_mux_tn0_sys = bnch_block2_sw_sys;
        end
        {4'd0, 6'd7}: begin // empty
            blk1_mux_tn0_sys = {BLOCK_BITS{1'b0}};
            blk2_mux_tn0_sys = {BLOCK_BITS{1'b0}};
        end
        {4'd1, 6'd0}: begin // NULL_PDU (pre-coded 216-bit blob into BKN1)
            blk1_mux_tn0_sys = null_pdu_bits_sys;
            blk2_mux_tn0_sys = ndb_block2_sw_sys;
        end
        default: begin
            blk1_mux_tn0_sys = ndb_block1_sw_sys;
            blk2_mux_tn0_sys = ndb_block2_sw_sys;
        end
    endcase
end

// TN=1 — with MLE signalling-response override on BKN1 when pending.
reg [BLOCK_BITS-1:0] blk1_sched_tn1_sys;
reg [BLOCK_BITS-1:0] blk2_sched_tn1_sys;
always @(*) begin
    case ({bus_class(sched_entry_reg_sys1), bus_idx(sched_entry_reg_sys1)})
        {4'd0, 6'd0}: begin blk1_sched_tn1_sys = ndb_block1_sw_sys;  blk2_sched_tn1_sys = ndb_block2_sw_sys;  end
        {4'd0, 6'd1}: begin blk1_sched_tn1_sys = mcch_block1_sw_sys; blk2_sched_tn1_sys = mcch_block2_sw_sys; end
        {4'd0, 6'd2}: begin blk1_sched_tn1_sys = bnch_block1_sw_sys; blk2_sched_tn1_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd3}: begin blk1_sched_tn1_sys = {BLOCK_BITS{1'b0}}; blk2_sched_tn1_sys = sb_bkn2_sw_sys;     end
        {4'd0, 6'd4}: begin blk1_sched_tn1_sys = ndb_block1_sw_sys;  blk2_sched_tn1_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd7}: begin blk1_sched_tn1_sys = {BLOCK_BITS{1'b0}}; blk2_sched_tn1_sys = {BLOCK_BITS{1'b0}}; end
        {4'd1, 6'd0}: begin blk1_sched_tn1_sys = null_pdu_bits_sys;  blk2_sched_tn1_sys = ndb_block2_sw_sys;  end
        default:      begin blk1_sched_tn1_sys = ndb_block1_sw_sys;  blk2_sched_tn1_sys = ndb_block2_sw_sys;  end
    endcase
end
always @(*) begin
    if (dl_signal_pending_sys) begin
        blk1_mux_tn1_sys = dl_signal_latched_sys;
        blk2_mux_tn1_sys = blk2_sched_tn1_sys;
    end else begin
        blk1_mux_tn1_sys = blk1_sched_tn1_sys;
        blk2_mux_tn1_sys = blk2_sched_tn1_sys;
    end
end

// TN=2
always @(*) begin
    case ({bus_class(sched_entry_reg_sys2), bus_idx(sched_entry_reg_sys2)})
        {4'd0, 6'd0}: begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = ndb_block2_sw_sys;  end
        {4'd0, 6'd1}: begin blk1_mux_tn2_sys = mcch_block1_sw_sys; blk2_mux_tn2_sys = mcch_block2_sw_sys; end
        {4'd0, 6'd2}: begin blk1_mux_tn2_sys = bnch_block1_sw_sys; blk2_mux_tn2_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd3}: begin blk1_mux_tn2_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn2_sys = sb_bkn2_sw_sys;     end
        {4'd0, 6'd4}: begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd7}: begin blk1_mux_tn2_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn2_sys = {BLOCK_BITS{1'b0}}; end
        {4'd1, 6'd0}: begin blk1_mux_tn2_sys = null_pdu_bits_sys;  blk2_mux_tn2_sys = ndb_block2_sw_sys;  end
        default:      begin blk1_mux_tn2_sys = ndb_block1_sw_sys;  blk2_mux_tn2_sys = ndb_block2_sw_sys;  end
    endcase
end

// TN=3
always @(*) begin
    case ({bus_class(sched_entry_reg_sys3), bus_idx(sched_entry_reg_sys3)})
        {4'd0, 6'd0}: begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = ndb_block2_sw_sys;  end
        {4'd0, 6'd1}: begin blk1_mux_tn3_sys = mcch_block1_sw_sys; blk2_mux_tn3_sys = mcch_block2_sw_sys; end
        {4'd0, 6'd2}: begin blk1_mux_tn3_sys = bnch_block1_sw_sys; blk2_mux_tn3_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd3}: begin blk1_mux_tn3_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn3_sys = sb_bkn2_sw_sys;     end
        {4'd0, 6'd4}: begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = bnch_block2_sw_sys; end
        {4'd0, 6'd7}: begin blk1_mux_tn3_sys = {BLOCK_BITS{1'b0}}; blk2_mux_tn3_sys = {BLOCK_BITS{1'b0}}; end
        {4'd1, 6'd0}: begin blk1_mux_tn3_sys = null_pdu_bits_sys;  blk2_mux_tn3_sys = ndb_block2_sw_sys;  end
        default:      begin blk1_mux_tn3_sys = ndb_block1_sw_sys;  blk2_mux_tn3_sys = ndb_block2_sw_sys;  end
    endcase
end

// =============================================================================
// Registered per-slot outputs (1-cycle pipeline from the combinational
// mux to keep fan-out to tx_chain clean).  Output registers below —
// R1 compliant: one always block per register.
// =============================================================================
// R1: slot_burst_type_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_burst_type_sys <= 4'b0000;
    else
        slot_burst_type_sys <= {bus_is_sdb(sched_entry_reg_sys3),
                                bus_is_sdb(sched_entry_reg_sys2),
                                bus_is_sdb(sched_entry_reg_sys1),
                                bus_is_sdb(sched_entry_reg_sys0)};
end

// R1: slot_en_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_en_sys <= 4'b0000;
    else
        slot_en_sys <= {bus_is_enable(sched_entry_reg_sys3),
                        bus_is_enable(sched_entry_reg_sys2),
                        bus_is_enable(sched_entry_reg_sys1),
                        bus_is_enable(sched_entry_reg_sys0)};
end

// R1: slot_ndb2_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_ndb2_sys <= 4'b0000;
    else
        slot_ndb2_sys <= {bus_is_ndb2(sched_entry_reg_sys3),
                          bus_is_ndb2(sched_entry_reg_sys2),
                          bus_is_ndb2(sched_entry_reg_sys1),
                          bus_is_ndb2(sched_entry_reg_sys0)};
end

// R1: per-slot block payloads (8 registers, one per (slot, block))
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
// sb_sb1_data_sys / sb_bb_data_sys — always driven from RTL encoder
// outputs.  Registered passthrough to keep downstream fan-out short.
// =============================================================================
// R1: sb_sb1_data_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sb_sb1_data_sys <= {SB1_BITS{1'b0}};
    else            sb_sb1_data_sys <= sb1_coded_sys;
end

// R1: sb_bb_data_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sb_bb_data_sys <= {BB_BITS{1'b0}};
    else            sb_bb_data_sys <= aach_coded_sys;
end

// Unused-input keepalives (synth-side sinks) — valid pulses are observed
// elsewhere; referenced here to silence unused-net warnings.
// synthesis translate_off
wire _unused_sig_sys = sb1_valid_sys | aach_valid_sys | tdma_tick_sys;
// synthesis translate_on

endmodule

`default_nettype wire
