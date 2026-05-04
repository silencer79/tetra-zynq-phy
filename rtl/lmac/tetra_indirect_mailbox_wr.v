// =============================================================================
// tetra_indirect_mailbox_wr.v — Phase Y.1.0 generic indirect-mailbox (Write)
// Project : tetra-zynq-phy
// =============================================================================
// Generic shared sub-block for the standard "AXI-write, AXI-read-back, slice
// fields combinationally" indirect-mailbox pattern used by SW-pulled mailboxes
// (e.g. D-LOC-UPDATE-ACCEPT body, Y.1+ Group-Attach-Reply, etc.).
// 16 × 32-bit explicit word latches + indirect read-mux + GO-pulse passthrough.
//
// Word storage is implemented as 16 explicit reg-32 latches (per repo R3-rule
// — no array-reg) so synth maps to LUT-RAM/distributed registers, not BRAM.
// NUM_WORDS is fixed at 16 — generalising to N would defeat R3 trivially; if
// future PDUs need more storage they can instantiate two of these.
//
// Wrapper responsibilities:
//   - drive index_sys / wdata_sys / wr_en_sys / go_pulse_sys from AXI-side
//   - slice the words_flat_sys output combinationally to expose PDU-specific
//     field outputs to FSM/Builder
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant, async active-low rst.
// =============================================================================
`default_nettype none

module tetra_indirect_mailbox_wr (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // AXI-side write port (clk_sys, already 2-FF resynced by caller)
    input  wire [3:0]  index_sys,
    input  wire [31:0] wdata_sys,
    input  wire        wr_en_sys,
    input  wire        go_pulse_sys,

    // AXI-side read port (combinational mux)
    output wire [31:0] rdata_sys,

    // 16 × 32-bit word array flattened — wrapper slices for field-outputs
    output wire [16*32-1:0] words_flat_sys,

    // GO pulse passthrough (1-cycle, fanned out to FSM by wrapper)
    output wire        go_pulse_out_sys
);

    // -----------------------------------------------------------------------
    // 16 × 32-bit word array (R1: one always block per element).
    // Implemented as 16 explicit reg-32 latches to stay R3-compliant and to
    // keep synth from inferring a tiny BRAM.
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

    // Flatten 16 words into single bus for the wrapper to slice
    assign words_flat_sys = {
        w15_r_sys, w14_r_sys, w13_r_sys, w12_r_sys,
        w11_r_sys, w10_r_sys, w9_r_sys,  w8_r_sys,
        w7_r_sys,  w6_r_sys,  w5_r_sys,  w4_r_sys,
        w3_r_sys,  w2_r_sys,  w1_r_sys,  w0_r_sys
    };

    assign go_pulse_out_sys = go_pulse_sys;

endmodule

`default_nettype wire
