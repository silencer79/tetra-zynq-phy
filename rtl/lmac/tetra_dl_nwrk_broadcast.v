// =============================================================================
// tetra_dl_nwrk_broadcast.v
//
// Phase H.7 — D-NWRK-BROADCAST Periodic Push
//
// Software (sw/tetra_hal daemon loop) builds the full 432-bit type-5 SCH/F
// payload (CRC + conv + punc + interleave + scramble) in C using the same
// math as `scripts/gen_sch_f_tv.py` and writes it into 14 AXI shadow
// registers + a 1-bit trigger.  This module:
//
//   - CDCs the 432-bit shadow + trigger from clk_axi to clk_sys
//   - On rising trigger edge (one-shot) pulses `wr_cmce_valid_sys` for one
//     clk_sys cycle into the DL-Signal-Queue (CMCE producer slot, currently
//     unused by any other producer)
//   - Drives `wr_cmce_coded_sys` = latched 432-bit payload,
//            `wr_cmce_pdu_type_sys` = 2'd0 (SCH/F),
//            `wr_cmce_target_tn_sys` = `cfg_mcch_tn_sys`
//   - Maintains a 16-bit counter of completed pushes for software readback
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_dl_nwrk_broadcast (
    input  wire         clk_sys,
    input  wire         rst_n_sys,

    // AXI-side shadow + trigger (already CDC'd to clk_sys at top level)
    input  wire [431:0] payload_sys,
    input  wire         trigger_sys,         // pulse, 1 cycle on rising edge

    // MCCH slot config (CDC'd from AXI, slow-changing)
    input  wire [1:0]   cfg_mcch_tn_sys,

    // DL-Signal-Queue producer (CMCE slot — was tied off)
    output reg          wr_cmce_valid_sys,
    output wire [431:0] wr_cmce_coded_sys,
    output wire [1:0]   wr_cmce_pdu_type_sys,
    output wire [1:0]   wr_cmce_target_tn_sys,

    // Counter (saturating at 16'hFFFF)
    output reg  [15:0]  push_cnt_sys
);

// -----------------------------------------------------------------------------
// Edge-detect on trigger_sys — push wr_cmce_valid_sys for exactly 1 cycle on
// rising edge.  Software is expected to write the trigger reg as W1S; the AXI
// reg has HW-clr semantics (cleared after consume) so a fresh write next cycle
// can fire again.
// -----------------------------------------------------------------------------
reg trigger_sys_q;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        trigger_sys_q     <= 1'b0;
        wr_cmce_valid_sys <= 1'b0;
        push_cnt_sys      <= 16'd0;
    end else begin
        trigger_sys_q <= trigger_sys;
        // Rising-edge pulse
        wr_cmce_valid_sys <= trigger_sys & ~trigger_sys_q;
        if (trigger_sys & ~trigger_sys_q) begin
            if (push_cnt_sys != 16'hFFFF)
                push_cnt_sys <= push_cnt_sys + 16'd1;
        end
    end
end

// Combinational: payload + pdu_type + target_tn pass-through.  The
// DL-Signal-Queue samples them on the cycle wr_cmce_valid_sys is high.
assign wr_cmce_coded_sys     = payload_sys;
assign wr_cmce_pdu_type_sys  = 2'd0;            // 00 = SCH_F (NDB1)
assign wr_cmce_target_tn_sys = cfg_mcch_tn_sys;

endmodule

`default_nettype wire
