// =============================================================================
// tetra_dl_nwrk_broadcast.v
//
// Phase H.7 — D-NWRK-BROADCAST Periodic Push
//
// Software (sw/tetra_hal daemon loop) builds the full 432-bit type-5 SCH/F
// payload (CRC + conv + punc + interleave + scramble) in C using the same
// math as `scripts/gen_sch_f_tv.py` and writes it into 14 AXI shadow
// registers. Two trigger sources:
//
// (1) SW-Trigger (legacy) — `trigger_sys` rising edge, used by
// Phase H.7 daemon loop and by TBs.
// Active when `cfg_period_mf == 0`.
// (2) Auto-Fire (Phase H.7-AF) — internal modulo-N counter on
// `mf_pulse_sys` (1-cycle multiframe
// pulse). Active when `cfg_period_mf >= 1`.
// Fires `wr_cmce_valid_sys` every N MFs.
//
// Mode selection is mutually exclusive: if `cfg_period_mf != 0` the SW-edge
// detect is ignored entirely (no double-fire possible). This is documented
// here and enforced in the always-block by gating the SW-edge term with
// `cfg_period_mf == 0`.
//
// On either trigger source this module:
// - Pulses `wr_cmce_valid_sys` for one clk_sys cycle into the DL-Signal-
// Queue (CMCE producer slot, currently unused by any other producer)
// - Drives `wr_cmce_coded_sys` = latched 432-bit payload,
// `wr_cmce_pdu_type_sys` = 2'd0 (SCH/F),
// `wr_cmce_target_tn_sys` = `cfg_mcch_tn_sys`
// - Maintains a 16-bit counter of completed pushes for software readback
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tetra_dl_nwrk_broadcast (
 input wire clk_sys,
 input wire rst_n_sys,

 // AXI-side shadow + trigger (already CDC'd to clk_sys at top level)
 input wire [431:0] payload_sys,
 input wire trigger_sys, // pulse, 1 cycle on rising edge

 // MCCH slot config (CDC'd from AXI, slow-changing)
 input wire [1:0] cfg_mcch_tn_sys,

 // Auto-Fire config (Phase H.7-AF)
 input wire [4:0] cfg_period_mf, // 0 = SW-Trigger; >=1 = auto, every N MFs
 input wire mf_pulse_sys, // 1-cycle multiframe-edge pulse

 // DL-Signal-Queue producer (CMCE slot — was tied off)
 output reg wr_cmce_valid_sys,
 output wire [431:0] wr_cmce_coded_sys,
 output wire [1:0] wr_cmce_pdu_type_sys,
 output wire [1:0] wr_cmce_target_tn_sys,

 // Counter (saturating at 16'hFFFF)
 output reg [15:0] push_cnt_sys
);

// -----------------------------------------------------------------------------
// Edge-detect on trigger_sys (SW path) — push wr_cmce_valid_sys for exactly
// 1 cycle on rising edge. Software is expected to write the trigger reg as
// W1S; the AXI reg has HW-clr semantics (cleared after consume).
//
// Auto-Fire path — a 5-bit modulo-N counter on `mf_pulse_sys`; when the
// counter reaches `cfg_period_mf`, fire and reset. Counter is held in reset
// while `cfg_period_mf == 0` (SW-Trigger mode active).
//
// Both decision terms are evaluated INLINE in the always block (not via
// `assign`-driven wires) so simulators sample the same `trigger_sys` /
// `mf_count` snapshot the always block uses for the NBA assignments — this
// avoids a continuous-assign visibility race in iverilog where a wire driven
// by `assign` may still hold its old value at the active-region of posedge.
// -----------------------------------------------------------------------------
reg trigger_sys_q;
reg [4:0] mf_count;

always @(posedge clk_sys or negedge rst_n_sys) begin: sw_af_block
 reg sw_edge_v;
 reg auto_fire_v;
 reg fire_v;
 if (!rst_n_sys) begin
 trigger_sys_q <= 1'b0;
 wr_cmce_valid_sys <= 1'b0;
 push_cnt_sys <= 16'd0;
 mf_count <= 5'd0;
 end else begin
 sw_edge_v = (cfg_period_mf == 5'd0) &&
 (trigger_sys & ~trigger_sys_q);
 auto_fire_v = (cfg_period_mf != 5'd0) && mf_pulse_sys &&
 ((mf_count + 5'd1) >= cfg_period_mf);
 fire_v = sw_edge_v | auto_fire_v;

 trigger_sys_q <= trigger_sys;
 wr_cmce_valid_sys <= fire_v;

 // Auto-Fire counter (only advances when enabled).
 if (cfg_period_mf == 5'd0) begin
 mf_count <= 5'd0;
 end else if (mf_pulse_sys) begin
 if ((mf_count + 5'd1) >= cfg_period_mf)
 mf_count <= 5'd0;
 else
 mf_count <= mf_count + 5'd1;
 end

 if (fire_v) begin
 if (push_cnt_sys != 16'hFFFF)
 push_cnt_sys <= push_cnt_sys + 16'd1;
 end
 end
end

// Combinational: payload + pdu_type + target_tn pass-through. The
// DL-Signal-Queue samples them on the cycle wr_cmce_valid_sys is high.
assign wr_cmce_coded_sys = payload_sys;
assign wr_cmce_pdu_type_sys = `PDUC_NWRK_BCAST_FMT; // SCH_F (NDB1)
assign wr_cmce_target_tn_sys = cfg_mcch_tn_sys;

endmodule

`default_nettype wire
