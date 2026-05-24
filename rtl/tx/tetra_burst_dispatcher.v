// =============================================================================
// Module: tetra_burst_dispatcher
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_burst_dispatcher.v
//
// Description:
// Phase Y.3 — flat-stage replacement for tetra_burst_mux + the per-slot
// tx_blk*_slot*_sys / slot_burst_type_sys / slot_en_sys / slot_ndb2_sys
// latches that previously lived in tetra_slot_content_mux.
//
// Old post-pop pipeline (8 stages):
//
// queue.head ─▶ scheduler ─▶ slot_content_mux: blk*_mux_tnK (comb)
// ─▶ free-running latches (8× 216-bit)
// ─▶ burst_mux: slot_lat / burst_type_lat /
// ndb2_lat / slot_en_lat
// ─▶ burst_mux: build_block1/2_sys (S_PENDING→S_REQ)
// ─▶ burst_builder
//
// New post-pop pipeline (3 stages):
//
// queue.head ─▶ scheduler ─▶ tetra_burst_dispatcher (this module):
// on tx_slot_pulse_sys, ONE always block
// latches body/burst_type/ndb2/bb/sb1
// for the slot identified by tx_slot_num_sys.
// ─▶ build_req_sys is a 1-cycle pulse @ T+1
// ─▶ burst_builder.
//
// Selection priority per slot (single mux):
// 1) Scheduler signalling-active (sched_active_sys[k]==1) OR static
// schedule entry's class field is SIGNALLING (1). Body =
// sched_blk1_tnK_sys / sched_blk2_tnK_sys; burst_type from entry's
// SDB bit (00=NDB, 01=SDB); ndb2 = sched_ndb2_sys[k].
// 2) Static schedule entry (class=0). Body taken from SW banks per
// idx field (NDB / MCCH / BNCH / SB / NDB2_half1_bnch / empty).
// burst_type / ndb2 derived from the entry bits.
//
// Coding rules: Verilog-2001 strict (R1–R10).
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_burst_dispatcher #(
 parameter BLOCK_BITS = 216,
 parameter BB_BITS = 30,
 parameter SB1_BITS = 120
) (
 input wire clk_sys,
 input wire rst_n_sys,

 // -------------------------------------------------------------------------
 // TX slot timing (from tetra_tdma_timebase)
 // -------------------------------------------------------------------------
 input wire tx_slot_pulse_sys,
 input wire [1:0] tx_slot_num_sys,

 // -------------------------------------------------------------------------
 // Scheduler fan-out (combinational from queue.head — see
 // tetra_dl_signal_scheduler). 4×216-bit per-TN body bundle plus
 // active/ndb2 strobes.
 // -------------------------------------------------------------------------
 input wire [BLOCK_BITS-1:0] sched_blk1_tn0_sys,
 input wire [BLOCK_BITS-1:0] sched_blk2_tn0_sys,
 input wire [BLOCK_BITS-1:0] sched_blk1_tn1_sys,
 input wire [BLOCK_BITS-1:0] sched_blk2_tn1_sys,
 input wire [BLOCK_BITS-1:0] sched_blk1_tn2_sys,
 input wire [BLOCK_BITS-1:0] sched_blk2_tn2_sys,
 input wire [BLOCK_BITS-1:0] sched_blk1_tn3_sys,
 input wire [BLOCK_BITS-1:0] sched_blk2_tn3_sys,
 input wire [3:0] sched_active_sys,
 input wire [3:0] sched_ndb2_sys,

 // -------------------------------------------------------------------------
 // Static schedule entries (from tetra_slot_content_mux's BRAM-prefetch
 // FSM). Stable in S_IDLE, refreshed each frame at slot_pulse@tn=3.
 // -------------------------------------------------------------------------
 input wire [15:0] sched_entry_reg_sys0,
 input wire [15:0] sched_entry_reg_sys1,
 input wire [15:0] sched_entry_reg_sys2,
 input wire [15:0] sched_entry_reg_sys3,

 // -------------------------------------------------------------------------
 // SW payload banks (216-bit each, slow-changing AXI registers)
 // -------------------------------------------------------------------------
 input wire [BLOCK_BITS-1:0] ndb_block1_sw_sys,
 input wire [BLOCK_BITS-1:0] ndb_block2_sw_sys,
 input wire [BLOCK_BITS-1:0] mcch_block1_sw_sys,
 input wire [BLOCK_BITS-1:0] mcch_block2_sw_sys,
 input wire [BLOCK_BITS-1:0] bnch_block1_sw_sys,
 input wire [BLOCK_BITS-1:0] bnch_block2_sw_sys,
 input wire [BLOCK_BITS-1:0] sb_bkn2_sw_sys,

 // -------------------------------------------------------------------------
 // AACH / SB1 pre-coded streams (from tetra_aach_encoder /
 // tetra_sb1_encoder — already routed to slot via top-level mux).
 // -------------------------------------------------------------------------
 input wire [BB_BITS-1:0] bb_in_sys,
 input wire [SB1_BITS-1:0] sb_sb1_in_sys,

 // -------------------------------------------------------------------------
 // Builder feedback (reserved — burst_builder accepts chained
 // build_req while tx_busy_sys is HIGH).
 // -------------------------------------------------------------------------
 input wire tx_busy_sys,

 // -------------------------------------------------------------------------
 // Phase 7 G.8 — Voice-Slot Filler-Mailbox override.
 // SW encoded SCH/F type-5 burst (NULL-PDU oder echte voice-PDU mit
 // GSSI-Adresse) wird via tetra_voice_filler_mailbox in vfill_blk1/2 +
 // vfill_valid eingespeist. Bei aktivem voice-call (voice_active_mask &
 // voice_slot_tn match) UND voice-FN (1..17 = fn_sys 0..16) UND
 // vfill_valid=1, überschreibt der dispatcher den scheduler/static-
 // fallback mit den filler-bits.
 // -------------------------------------------------------------------------
 input wire [3:0] voice_active_mask_sys, // mask bit per tn
 input wire [1:0] voice_slot_tn_sys, // tn_sys of active voice slot
 input wire [4:0] tx_fn_sys, // 0-based fn (ETSI FN-1)
 input wire vfill_valid_sys, // SW: filler-mailbox loaded
 input wire [BLOCK_BITS-1:0] vfill_blk1_sys, // type-5 bits 0..215
 input wire [BLOCK_BITS-1:0] vfill_blk2_sys, // type-5 bits 216..431
 input wire [BLOCK_BITS-1:0] null_pdu_bits_sys, // 216-bit NULL-PDU for NDB2-filler

 // Phase 2/3 (2026-05-23) — DL FACCH-Stealing mailbox + slot_mode.
 // Wenn slot_mode[tn] in {2,3,4}: NDB2-Format + facch_steal-mailbox-bits
 // (statt vfill und statt scheduler). Mailbox liefert BKN1=signaling (SCH/HD-
 // encoded D-RELEASE etc.), BKN2=SYSINFO-broadcast oder TCH-Voice-Half.
 input wire [15:0] slot_mode_sys, // 4×4-bit per TN
 input wire facch_steal_valid_sys, // beide BKN-Banken loaded
 input wire [BLOCK_BITS-1:0] facch_bkn1_sys, // SCH/HD signaling
 input wire [BLOCK_BITS-1:0] facch_bkn2_sys, // SCH/HD SYSINFO or TCH-half

 // -------------------------------------------------------------------------
 // Outputs to tetra_burst_builder
 // -------------------------------------------------------------------------
 output reg [BLOCK_BITS-1:0] build_block1_sys,
 output reg [BLOCK_BITS-1:0] build_block2_sys,
 output reg [BB_BITS-1:0] build_bb_sys,
 output reg [SB1_BITS-1:0] build_sb1_sys,
 output reg build_burst_type_sys, // 0=NDB, 1=SDB
 output reg build_ndb2_sys, // 0=NDB1, 1=NDB2
 output reg build_req_sys
);

// =============================================================================
// Schedule entry decoders (mirror tetra_slot_content_mux helper functions).
// ent[15:12]: class (4'd0=STATIC_BROADCAST, 4'd1=SIGNALLING)
// ent[11:6]: idx
// ent[5:4]: burst-type (00=NDB, 01=SDB)
// ent[3]: ndb2 flag
// ent[2]: enable
// =============================================================================
function bus_is_sdb; input [15:0] ent; begin bus_is_sdb = (ent[5:4] == 2'b01); end endfunction
function bus_is_enable; input [15:0] ent; begin bus_is_enable = ent[2]; end endfunction
function bus_is_ndb2; input [15:0] ent; begin bus_is_ndb2 = ent[3]; end endfunction
function bus_is_signal; input [15:0] ent; begin bus_is_signal = (ent[15:12] == 4'd1); end endfunction
function [5:0] bus_idx; input [15:0] ent; begin bus_idx = ent[11:6]; end endfunction

// =============================================================================
// Per-slot static-class body lookup (combinational). Used when the slot
// is NOT lifted into the SIGNALLING path.
// =============================================================================
function [BLOCK_BITS-1:0] static_blk1_for;
 input [5:0] idx;
 begin
 case (idx)
 6'd0: static_blk1_for = ndb_block1_sw_sys; // NDB SYSINFO
 6'd1: static_blk1_for = mcch_block1_sw_sys; // MCCH
 6'd2: static_blk1_for = bnch_block1_sw_sys; // BNCH
 6'd3: static_blk1_for = {BLOCK_BITS{1'b0}}; // SB (sb1 routed via build_sb1_sys)
 6'd4: static_blk1_for = ndb_block1_sw_sys; // NDB2_half1_bnch
 6'd7: static_blk1_for = {BLOCK_BITS{1'b0}}; // empty
 default: static_blk1_for = ndb_block1_sw_sys;
 endcase
 end
endfunction

function [BLOCK_BITS-1:0] static_blk2_for;
 input [5:0] idx;
 begin
 case (idx)
 6'd0: static_blk2_for = ndb_block2_sw_sys;
 6'd1: static_blk2_for = mcch_block2_sw_sys;
 6'd2: static_blk2_for = bnch_block2_sw_sys;
 6'd3: static_blk2_for = sb_bkn2_sw_sys;
 6'd4: static_blk2_for = bnch_block2_sw_sys;
 6'd7: static_blk2_for = {BLOCK_BITS{1'b0}};
 default: static_blk2_for = ndb_block2_sw_sys;
 endcase
 end
endfunction

// =============================================================================
// Combinational selection per slot — collapsed mux that names the chosen
// body/meta for the slot identified by tx_slot_num_sys. At the next
// posedge clk_sys with tx_slot_pulse_sys asserted, those values are
// captured into the build_*_sys output registers.
//
// Slot lift rule (mirrors tetra_slot_content_mux Z.2 dynamic-class):
//
// sig_route = sched_active_sys[k] || bus_is_signal(entry_k)
//
// When sig_route is asserted, body/blk2/ndb2 come from the scheduler's
// per-TN bundle. The static SW-bank lookup is bypassed. burst_type
// is still taken from the schedule entry's SDB bit (signalling can ride
// either NDB or SDB slots, decided at compile time by the schedule).
// =============================================================================
reg [BLOCK_BITS-1:0] sel_blk1_w;
reg [BLOCK_BITS-1:0] sel_blk2_w;
reg sel_burst_type_w;
reg sel_ndb2_w;
reg sel_enable_w;

always @(*) begin
 // Default to TN=0 mapping; case below overrides for each TN.
 sel_blk1_w = {BLOCK_BITS{1'b0}};
 sel_blk2_w = {BLOCK_BITS{1'b0}};
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b0;
 sel_enable_w = 1'b0;
 // Voice-Slot-Override gate (gemeinsam für alle 4 TN): SW-Filler liefert
 // pre-encoded SCH/F bits in voice-FN, AACH 0x32CB advertised voice.
 // FN 18 (fn_sys=17) bleibt BSCH-Anchor (kein override).
 case (tx_slot_num_sys)
 2'd0: begin
 sel_burst_type_w = bus_is_sdb (sched_entry_reg_sys0);
 sel_enable_w = bus_is_enable(sched_entry_reg_sys0);
 // Phase 2/3 — slot_mode FACCH-Stealing (höchste Prio, vor voice/sched).
 // slot_mode[tn] in {2,3,4} → NDB2 + facch_steal-mailbox.
 if ((slot_mode_sys[3:0] >= 4'd2) && (slot_mode_sys[3:0] <= 4'd4)
 && facch_steal_valid_sys && (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = facch_bkn1_sys;
 sel_blk2_w = (slot_mode_sys[3:0] == 4'd2 && vfill_valid_sys)
 ? vfill_blk2_sys // HALF_STEAL: BKN2 = TCH-Voice-Half
 : facch_bkn2_sys; // FULL_STEAL: BKN2 = SCH/HD SYSINFO
 sel_burst_type_w = 1'b0; // NDB
 sel_ndb2_w = 1'b1; // NDB2 (NTS2) — FACCH-Stealing
 sel_enable_w = 1'b1;
 end else if (voice_active_mask_sys[0] & vfill_valid_sys
 & (voice_slot_tn_sys == 2'd0)
 & (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = vfill_blk1_sys;
 sel_blk2_w = vfill_blk2_sys;
 sel_burst_type_w = 1'b0;  // NDB
 sel_ndb2_w = 1'b0;        // NDB1 (NTS1) — TCH/S voice = gold-konform
 sel_enable_w = 1'b1;
 end else if (sched_active_sys[0] || bus_is_signal(sched_entry_reg_sys0)) begin
 sel_blk1_w = sched_blk1_tn0_sys;
 sel_blk2_w = sched_blk2_tn0_sys;
 sel_ndb2_w = sched_ndb2_sys[0];
 end else begin
 sel_blk1_w = static_blk1_for(bus_idx(sched_entry_reg_sys0));
 sel_blk2_w = static_blk2_for(bus_idx(sched_entry_reg_sys0));
 sel_ndb2_w = bus_is_ndb2(sched_entry_reg_sys0);
 end
 end
 2'd1: begin
 sel_burst_type_w = bus_is_sdb (sched_entry_reg_sys1);
 sel_enable_w = bus_is_enable(sched_entry_reg_sys1);
 if ((slot_mode_sys[7:4] >= 4'd2) && (slot_mode_sys[7:4] <= 4'd4)
 && facch_steal_valid_sys && (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = facch_bkn1_sys;
 sel_blk2_w = (slot_mode_sys[7:4] == 4'd2 && vfill_valid_sys)
 ? vfill_blk2_sys : facch_bkn2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b1;
 sel_enable_w = 1'b1;
 end else if (voice_active_mask_sys[1] & vfill_valid_sys
 & (voice_slot_tn_sys == 2'd1)
 & (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = vfill_blk1_sys;
 sel_blk2_w = vfill_blk2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b0;  // NDB1 (NTS1) — TCH/S voice = gold-konform (Voice-slot Class)
 sel_enable_w = 1'b1;
 end else if (sched_active_sys[1] || bus_is_signal(sched_entry_reg_sys1)) begin
 sel_blk1_w = sched_blk1_tn1_sys;
 sel_blk2_w = sched_blk2_tn1_sys;
 sel_ndb2_w = sched_ndb2_sys[1];
 end else begin
 sel_blk1_w = static_blk1_for(bus_idx(sched_entry_reg_sys1));
 sel_blk2_w = static_blk2_for(bus_idx(sched_entry_reg_sys1));
 sel_ndb2_w = bus_is_ndb2(sched_entry_reg_sys1);
 end
 end
 2'd2: begin
 sel_burst_type_w = bus_is_sdb (sched_entry_reg_sys2);
 sel_enable_w = bus_is_enable(sched_entry_reg_sys2);
 if ((slot_mode_sys[11:8] >= 4'd2) && (slot_mode_sys[11:8] <= 4'd4)
 && facch_steal_valid_sys && (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = facch_bkn1_sys;
 sel_blk2_w = (slot_mode_sys[11:8] == 4'd2 && vfill_valid_sys)
 ? vfill_blk2_sys : facch_bkn2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b1;
 sel_enable_w = 1'b1;
 end else if (voice_active_mask_sys[2] & vfill_valid_sys
 & (voice_slot_tn_sys == 2'd2)
 & (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = vfill_blk1_sys;
 sel_blk2_w = vfill_blk2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b0;  // NDB1 (NTS1) — TCH/S voice = gold-konform (Voice-slot Class)
 sel_enable_w = 1'b1;
 end else if (sched_active_sys[2] || bus_is_signal(sched_entry_reg_sys2)) begin
 sel_blk1_w = sched_blk1_tn2_sys;
 sel_blk2_w = sched_blk2_tn2_sys;
 sel_ndb2_w = sched_ndb2_sys[2];
 end else begin
 sel_blk1_w = static_blk1_for(bus_idx(sched_entry_reg_sys2));
 sel_blk2_w = static_blk2_for(bus_idx(sched_entry_reg_sys2));
 sel_ndb2_w = bus_is_ndb2(sched_entry_reg_sys2);
 end
 end
 2'd3: begin
 sel_burst_type_w = bus_is_sdb (sched_entry_reg_sys3);
 sel_enable_w = bus_is_enable(sched_entry_reg_sys3);
 if ((slot_mode_sys[15:12] >= 4'd2) && (slot_mode_sys[15:12] <= 4'd4)
 && facch_steal_valid_sys && (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = facch_bkn1_sys;
 sel_blk2_w = (slot_mode_sys[15:12] == 4'd2 && vfill_valid_sys)
 ? vfill_blk2_sys : facch_bkn2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b1;
 sel_enable_w = 1'b1;
 end else if (voice_active_mask_sys[3] & vfill_valid_sys
 & (voice_slot_tn_sys == 2'd3)
 & (tx_fn_sys <= 5'd16)) begin
 sel_blk1_w = vfill_blk1_sys;
 sel_blk2_w = vfill_blk2_sys;
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b0;  // NDB1 (NTS1) — TCH/S voice = gold-konform (Voice-slot Class)
 sel_enable_w = 1'b1;
 end else if (sched_active_sys[3] || bus_is_signal(sched_entry_reg_sys3)) begin
 sel_blk1_w = sched_blk1_tn3_sys;
 sel_blk2_w = sched_blk2_tn3_sys;
 sel_ndb2_w = sched_ndb2_sys[3];
 end else begin
 sel_blk1_w = static_blk1_for(bus_idx(sched_entry_reg_sys3));
 sel_blk2_w = static_blk2_for(bus_idx(sched_entry_reg_sys3));
 sel_ndb2_w = bus_is_ndb2(sched_entry_reg_sys3);
 end
 end
 default: begin
 sel_blk1_w = {BLOCK_BITS{1'b0}};
 sel_blk2_w = {BLOCK_BITS{1'b0}};
 sel_burst_type_w = 1'b0;
 sel_ndb2_w = 1'b0;
 sel_enable_w = 1'b0;
 end
 endcase
end

// =============================================================================
// Single-stage capture — on tx_slot_pulse_sys, latch body/meta + emit
// build_req_sys for ONE cycle. build_req clears unconditionally on the
// next clock edge so the burst_builder's 1-cycle-pulse contract is met.
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 build_block1_sys <= {BLOCK_BITS{1'b0}};
 build_block2_sys <= {BLOCK_BITS{1'b0}};
 build_bb_sys <= {BB_BITS{1'b0}};
 build_sb1_sys <= {SB1_BITS{1'b0}};
 build_burst_type_sys <= 1'b0;
 build_ndb2_sys <= 1'b0;
 build_req_sys <= 1'b0;
 end else if (tx_slot_pulse_sys) begin
 // Body / SB1 — gated by enable (matches old burst_mux behaviour:
 // disabled slots emit zero body so burst_builder shifts out an
 // all-zero NDB / SDB).
 build_block1_sys <= sel_enable_w ? sel_blk1_w: {BLOCK_BITS{1'b0}};
 build_block2_sys <= sel_enable_w ? sel_blk2_w: {BLOCK_BITS{1'b0}};
 build_sb1_sys <= sel_enable_w ? sb_sb1_in_sys: {SB1_BITS{1'b0}};
 // BB/AACH — broadcast on every burst (matches old burst_mux).
 build_bb_sys <= bb_in_sys;
 build_burst_type_sys <= sel_burst_type_w;
 build_ndb2_sys <= sel_ndb2_w;
 build_req_sys <= 1'b1; // 1-cycle pulse to builder
 end else begin
 build_req_sys <= 1'b0;
 end
end

// synthesis translate_off
wire _unused_dispatcher_sys = tx_busy_sys; // reserved future use
// synthesis translate_on

endmodule

`default_nettype wire
