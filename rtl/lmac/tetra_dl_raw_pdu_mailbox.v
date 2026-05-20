// =============================================================================
// tetra_dl_raw_pdu_mailbox.v — SW→DL Raw PDU push window
//
// Phase Move-3+4 (2026-05-20): SW (tetra_attach_daemon, tetra_call_fsm) baut
// jetzt die kompletten 432-bit type-5 SCH/F-Bursts in C (siehe
// sw/tetra_dl_pdu.c + tetra_mac_resource_dl_builder.c + tetra_sch_f_encoder.c).
// Dieses Modul ersetzt die alte u_dl_pdu_builder/u_mle_registration_fsm/
// u_dloc/u_reply_mailbox-Pipeline (~5000 LUT) durch einen reinen Push-Pfad.
//
// AXI-Layout (siehe rtl/infra/tetra_axi_lite_regs.v):
//   REG_DL_RAW_PDU_INDEX   R/W [3:0]  word selector 0..14
//   REG_DL_RAW_PDU_DATA    R/W [31:0] indirect-write via INDEX
//   REG_DL_RAW_PDU_META    R/W [31:0] metadata word
//                                     [1:0]  pdu_type (SCH/F=0)
//                                     [3:2]  target_tn
//                                     [17:4] aach_pattern (14 bit)
//                                     [18]   second_pdu_present
//                                     [19]   second_pdu_nr
//   REG_DL_RAW_PDU_GO      W1S [0]    1-cycle push trigger; HW-clears on
//                                     consume_pulse via the mailbox FSM.
//   REG_DL_RAW_PDU_CNT     RO  [15:0] saturating push counter (telemetry)
//
// On the GO-edge:
//   - latch the 432-bit payload + metadata
//   - assert wr_valid_sys for exactly 1 cycle
//   - bump push_cnt_sys
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_dl_raw_pdu_mailbox (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // AXI-side shadow (already CDC'd to clk_sys at top level)
    input  wire [431:0] payload_sys,
    input  wire [1:0]   meta_pdu_type_sys,
    input  wire [1:0]   meta_target_tn_sys,
    input  wire [13:0]  meta_aach_pattern_sys,
    input  wire         meta_second_pdu_present_sys,
    input  wire         meta_second_pdu_nr_sys,

    // GO trigger — level signal that goes high for at least 1 clk_sys cycle
    // when SW writes REG_DL_RAW_PDU_GO. We do edge-detect inside.
    input  wire        trigger_sys,

    // DL-Signal-Queue producer (MLE-slot — previously fed by u_mle_registration_fsm)
    output reg         wr_valid_sys,
    output wire [431:0] wr_coded_sys,
    output wire [1:0]   wr_pdu_type_sys,
    output wire [1:0]   wr_target_tn_sys,
    output wire [13:0]  wr_aach_pattern_sys,
    output wire         wr_second_pdu_present_sys,
    output wire         wr_second_pdu_nr_sys,

    // 16-bit saturating push counter (telemetry → mle_accept_cnt)
    output reg  [15:0]  push_cnt_sys
);

    // Edge-detect on trigger_sys → 1-cycle wr_valid_sys pulse
    reg trigger_sys_q;
    wire trigger_edge_w = trigger_sys & ~trigger_sys_q;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            trigger_sys_q <= 1'b0;
            wr_valid_sys  <= 1'b0;
            push_cnt_sys  <= 16'd0;
        end else begin
            trigger_sys_q <= trigger_sys;
            wr_valid_sys  <= trigger_edge_w;
            if (trigger_edge_w && push_cnt_sys != 16'hFFFF)
                push_cnt_sys <= push_cnt_sys + 16'd1;
        end
    end

    // Combinational pass-through — DL-Signal-Queue samples them on the cycle
    // wr_valid_sys is high. SW must hold REG_DL_RAW_PDU_DATA / META stable
    // across the GO write (it does — INDEX writes precede DATA, then META,
    // then GO, and all writes are serialized through the AXI-Lite slave).
    assign wr_coded_sys              = payload_sys;
    assign wr_pdu_type_sys           = meta_pdu_type_sys;
    assign wr_target_tn_sys          = meta_target_tn_sys;
    assign wr_aach_pattern_sys       = meta_aach_pattern_sys;
    assign wr_second_pdu_present_sys = meta_second_pdu_present_sys;
    assign wr_second_pdu_nr_sys      = meta_second_pdu_nr_sys;

endmodule

`default_nettype wire
