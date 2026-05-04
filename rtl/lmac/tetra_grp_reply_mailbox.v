// =============================================================================
// tetra_grp_reply_mailbox.v — Phase Y.1.b Group-Attach Reply Mailbox (clk_sys)
// Project : tetra-zynq-phy
// Standard: ETSI EN 300 392-2 (D-ATTACH-DETACH-GROUP-IDENTITY-ACKNOWLEDGEMENT)
// =============================================================================
// Thin wrapper over the generic `tetra_indirect_mailbox_wr`.  Holds the
// PDU-specific field-output slices over the 16-word storage and passes the
// AXI write/read paths through to the shared block.
//
// SW stages all D-ATTACH-DETACH-GRP-ID-ACK fields via INDEX/DATA writes,
// then pulses GO; the shared MLE-FSM-style arbiter at the top level samples
// mb_grp_go_pulse_sys and triggers the Group-Attach reply build pipeline.
//
// Word layout (verbindlich):
//   W0  [31:24] 8'd0         [23: 0] ssi[23:0]      (target MS-SSI)
//   W1  [31: 1] 31'd0        [ 0]    accept_reject (0=ACCEPT,1=REJECT)
//   W2  [31: 2] 30'd0        [ 1: 0] gid_count[1:0] (0..3)
//   W3  [31:24] 8'd0         [23: 0] gssi[ 0]
//   W4  [31:24] 8'd0         [23: 0] gssi[ 1]
//   W5  [31:24] 8'd0         [23: 0] gssi[ 2]
//   W6  [31:24] 8'd0
//        [23:21] reserved
//        [20:15] at_array[5:0]    (3 × 2-bit address_type)
//        [14: 9] lifetime_array[5:0] (3 × 2-bit GroupIdentityAttachment lifetime)
//        [ 8: 6] adi_array[2:0]   (3 × 1-bit attach/detach selector)
//        [ 5: 0] class_array[5:0] not enough — see note below
//   W7  [31: 9] 23'd0
//        [ 8: 0] class_array[8:0] (3 × 3-bit class_of_usage)
//   W8  [31: 2] 30'd0        [1] ns  [0] nr   (LLC stop-and-wait)
//   W9..W15                  reserved
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_grp_reply_mailbox (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // ------------------------------------------------------------------
    // AXI-side write port (already 2-FF resynced clk_axi → clk_sys by caller).
    // ------------------------------------------------------------------
    input  wire [3:0]  index_sys,
    input  wire [31:0] wdata_sys,
    input  wire        wr_en_sys,
    input  wire        go_pulse_sys,

    // ------------------------------------------------------------------
    // AXI-side read port (combinational mux).
    // ------------------------------------------------------------------
    output wire [31:0] rdata_sys,

    // ------------------------------------------------------------------
    // Field outputs — fanned out to the Group-Attach reply build pipeline.
    // ------------------------------------------------------------------
    output wire [23:0] mb_grp_ssi_sys,
    output wire        mb_grp_accept_reject_sys,
    output wire [1:0]  mb_grp_count_sys,
    output wire [71:0] mb_grp_gssi_array_sys,
    output wire [5:0]  mb_grp_at_array_sys,
    output wire [5:0]  mb_grp_lifetime_array_sys,
    output wire [2:0]  mb_grp_adi_array_sys,
    output wire [8:0]  mb_grp_class_array_sys,
    output wire        mb_grp_ns_sys,
    output wire        mb_grp_nr_sys,
    output wire        mb_grp_go_pulse_sys
);

    // -----------------------------------------------------------------------
    // Generic 16-word indirect-write storage + read-mux + GO passthrough.
    // -----------------------------------------------------------------------
    wire [16*32-1:0] words_flat_w;

    tetra_indirect_mailbox_wr u_imbox_wr (
        .clk_sys          (clk_sys),
        .rst_n_sys        (rst_n_sys),
        .index_sys        (index_sys),
        .wdata_sys        (wdata_sys),
        .wr_en_sys        (wr_en_sys),
        .go_pulse_sys     (go_pulse_sys),
        .rdata_sys        (rdata_sys),
        .words_flat_sys   (words_flat_w),
        .go_pulse_out_sys (mb_grp_go_pulse_sys)
    );

    // -----------------------------------------------------------------------
    // Word-name aliases — slice out W0..W8 for the field-decoders.
    // -----------------------------------------------------------------------
    wire [31:0] w0_w = words_flat_w[ 0*32 +: 32];
    wire [31:0] w1_w = words_flat_w[ 1*32 +: 32];
    wire [31:0] w2_w = words_flat_w[ 2*32 +: 32];
    wire [31:0] w3_w = words_flat_w[ 3*32 +: 32];
    wire [31:0] w4_w = words_flat_w[ 4*32 +: 32];
    wire [31:0] w5_w = words_flat_w[ 5*32 +: 32];
    wire [31:0] w6_w = words_flat_w[ 6*32 +: 32];
    wire [31:0] w7_w = words_flat_w[ 7*32 +: 32];
    wire [31:0] w8_w = words_flat_w[ 8*32 +: 32];

    assign mb_grp_ssi_sys            = w0_w[23:0];
    assign mb_grp_accept_reject_sys  = w1_w[0];
    assign mb_grp_count_sys          = w2_w[1:0];
    assign mb_grp_gssi_array_sys     = {w5_w[23:0], w4_w[23:0], w3_w[23:0]};
    assign mb_grp_at_array_sys       = w6_w[20:15];
    assign mb_grp_lifetime_array_sys = w6_w[14: 9];
    assign mb_grp_adi_array_sys      = w6_w[ 8: 6];
    assign mb_grp_class_array_sys    = w7_w[ 8: 0];
    assign mb_grp_ns_sys             = w8_w[1];
    assign mb_grp_nr_sys             = w8_w[0];

endmodule

`default_nettype wire
