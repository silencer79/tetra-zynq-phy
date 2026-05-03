// =============================================================================
// tetra_reply_mailbox.v — Phase X.2 SW-Pulled Reply Mailbox (clk_sys)
// Project : tetra-zynq-phy
// Standard: ETSI EN 300 392-2 (D-LOC-UPDATE-ACCEPT body fields)
// =============================================================================
// 16 × 32-bit indirect word array (R/W from AXI side via INDEX/DATA pattern).
// SW-Daemon stages a complete D-LOC-UPDATE-ACCEPT body per UL-Demand by
// writing the appropriate words W0..W8 (W9..W15 reserved) and then pulses
// REG_REPLY_GO.  HW resynchronises the latched payload onto clk_sys and
// fans the field outputs out to the MLE-FSM where they may override the
// existing FSM-state-latch values driving u_dloc.
//
// Word layout (verbindlich):
//   W0  [31:24] 8'd0            [23: 0] ssi[23:0]
//   W1  [31:14] 18'd0           [13: 0] la[13:0]
//   W2  [31: 3] 29'd0           [ 2: 0] addr_type[2:0]
//   W3  [31: 2] 30'd0           [ 1: 0] result[1:0]
//   W4  [31:24] 8'd0            [23: 0] gila_gssi[23:0]
//   W5  [31: 5] 27'd0  [4:2]    gila_class[2:0]   [1:0] gila_lifetime[1:0]
//   W6  [31: 1] 31'd0           [ 0]    gila_present
//   W7  [31: 2] 30'd0           [ 1: 0] encryption[1:0]   (Reserved)
//   W8  [31: 2] 30'd0           [ 1: 0] auth_result[1:0]  (Reserved)
//   W9..W15                     32'd0   (reserved Phase X.4)
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_reply_mailbox (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // ------------------------------------------------------------------
    // AXI-side write port (already 2-FF resynced clk_axi → clk_sys by caller).
    // SW writes data to W[index] when wr_en_sys is held, then pulses go.
    // ------------------------------------------------------------------
    input  wire [3:0]  index_sys,
    input  wire [31:0] wdata_sys,
    input  wire        wr_en_sys,         // 1 = commit wdata_sys → words[index]
    input  wire        go_pulse_sys,      // 1-cycle pulse → mb_go_pulse_sys

    // ------------------------------------------------------------------
    // AXI-side read port (combinational mux).
    // ------------------------------------------------------------------
    output wire [31:0] rdata_sys,

    // ------------------------------------------------------------------
    // Field outputs — fanned out to MLE-FSM (clk_sys domain).
    // ------------------------------------------------------------------
    output wire [23:0] mb_ssi_sys,
    output wire [13:0] mb_la_sys,
    output wire [2:0]  mb_addr_type_sys,
    output wire [1:0]  mb_result_sys,
    output wire [23:0] mb_gila_gssi_sys,
    output wire [2:0]  mb_gila_class_sys,
    output wire [1:0]  mb_gila_lifetime_sys,
    output wire        mb_gila_present_sys,
    output wire [1:0]  mb_encryption_sys,
    output wire [1:0]  mb_auth_result_sys,
    output wire        mb_go_pulse_sys
);

    // -----------------------------------------------------------------------
    // 16 × 32-bit word array (R1: one always block per element).
    // Implemented as 16 explicit reg-32 latches to stay R3-compliant
    // (no array reg) and to keep the synth tool from inferring a tiny BRAM.
    // -----------------------------------------------------------------------
    reg [31:0] w0_r_sys;
    reg [31:0] w1_r_sys;
    reg [31:0] w2_r_sys;
    reg [31:0] w3_r_sys;
    reg [31:0] w4_r_sys;
    reg [31:0] w5_r_sys;
    reg [31:0] w6_r_sys;
    reg [31:0] w7_r_sys;
    reg [31:0] w8_r_sys;
    reg [31:0] w9_r_sys;
    reg [31:0] w10_r_sys;
    reg [31:0] w11_r_sys;
    reg [31:0] w12_r_sys;
    reg [31:0] w13_r_sys;
    reg [31:0] w14_r_sys;
    reg [31:0] w15_r_sys;

    wire we0  = wr_en_sys & (index_sys == 4'd0);
    wire we1  = wr_en_sys & (index_sys == 4'd1);
    wire we2  = wr_en_sys & (index_sys == 4'd2);
    wire we3  = wr_en_sys & (index_sys == 4'd3);
    wire we4  = wr_en_sys & (index_sys == 4'd4);
    wire we5  = wr_en_sys & (index_sys == 4'd5);
    wire we6  = wr_en_sys & (index_sys == 4'd6);
    wire we7  = wr_en_sys & (index_sys == 4'd7);
    wire we8  = wr_en_sys & (index_sys == 4'd8);
    wire we9  = wr_en_sys & (index_sys == 4'd9);
    wire we10 = wr_en_sys & (index_sys == 4'd10);
    wire we11 = wr_en_sys & (index_sys == 4'd11);
    wire we12 = wr_en_sys & (index_sys == 4'd12);
    wire we13 = wr_en_sys & (index_sys == 4'd13);
    wire we14 = wr_en_sys & (index_sys == 4'd14);
    wire we15 = wr_en_sys & (index_sys == 4'd15);

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w0_r_sys  <= 32'd0;
        else if (we0)   w0_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w1_r_sys  <= 32'd0;
        else if (we1)   w1_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w2_r_sys  <= 32'd0;
        else if (we2)   w2_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w3_r_sys  <= 32'd0;
        else if (we3)   w3_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w4_r_sys  <= 32'd0;
        else if (we4)   w4_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w5_r_sys  <= 32'd0;
        else if (we5)   w5_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w6_r_sys  <= 32'd0;
        else if (we6)   w6_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w7_r_sys  <= 32'd0;
        else if (we7)   w7_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w8_r_sys  <= 32'd0;
        else if (we8)   w8_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w9_r_sys  <= 32'd0;
        else if (we9)   w9_r_sys  <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w10_r_sys <= 32'd0;
        else if (we10)  w10_r_sys <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w11_r_sys <= 32'd0;
        else if (we11)  w11_r_sys <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w12_r_sys <= 32'd0;
        else if (we12)  w12_r_sys <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w13_r_sys <= 32'd0;
        else if (we13)  w13_r_sys <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w14_r_sys <= 32'd0;
        else if (we14)  w14_r_sys <= wdata_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) w15_r_sys <= 32'd0;
        else if (we15)  w15_r_sys <= wdata_sys;
    end

    // -----------------------------------------------------------------------
    // R10: combinational read mux
    // -----------------------------------------------------------------------
    reg [31:0] rdata_mux_sys;
    always @(*) begin
        case (index_sys)
            4'd0:  rdata_mux_sys = w0_r_sys;
            4'd1:  rdata_mux_sys = w1_r_sys;
            4'd2:  rdata_mux_sys = w2_r_sys;
            4'd3:  rdata_mux_sys = w3_r_sys;
            4'd4:  rdata_mux_sys = w4_r_sys;
            4'd5:  rdata_mux_sys = w5_r_sys;
            4'd6:  rdata_mux_sys = w6_r_sys;
            4'd7:  rdata_mux_sys = w7_r_sys;
            4'd8:  rdata_mux_sys = w8_r_sys;
            4'd9:  rdata_mux_sys = w9_r_sys;
            4'd10: rdata_mux_sys = w10_r_sys;
            4'd11: rdata_mux_sys = w11_r_sys;
            4'd12: rdata_mux_sys = w12_r_sys;
            4'd13: rdata_mux_sys = w13_r_sys;
            4'd14: rdata_mux_sys = w14_r_sys;
            4'd15: rdata_mux_sys = w15_r_sys;
            default: rdata_mux_sys = 32'd0;
        endcase
    end

    assign rdata_sys = rdata_mux_sys;

    // -----------------------------------------------------------------------
    // Field-decoders — pure combinational slice on the mailbox latches.
    // Updates as soon as SW writes a word; mb_go_pulse_sys signals the FSM
    // that the staged payload is ready.
    // -----------------------------------------------------------------------
    assign mb_ssi_sys           = w0_r_sys[23:0];
    assign mb_la_sys            = w1_r_sys[13:0];
    assign mb_addr_type_sys     = w2_r_sys[2:0];
    assign mb_result_sys        = w3_r_sys[1:0];
    assign mb_gila_gssi_sys     = w4_r_sys[23:0];
    assign mb_gila_class_sys    = w5_r_sys[4:2];
    assign mb_gila_lifetime_sys = w5_r_sys[1:0];
    assign mb_gila_present_sys  = w6_r_sys[0];
    assign mb_encryption_sys    = w7_r_sys[1:0];
    assign mb_auth_result_sys   = w8_r_sys[1:0];

    // mb_go_pulse_sys is just the resynced 1-cycle SW-Trigger forwarded to
    // the MLE-FSM (Reserve for Phase X.4 — currently the FSM does not need
    // it because the existing accept_pulse path re-runs on the next demand).
    assign mb_go_pulse_sys = go_pulse_sys;

endmodule

`default_nettype wire
