// =============================================================================
// tetra_grp_demand_mailbox.v — Phase Y.1.b Group-Attach Demand Mailbox (clk_sys)
// Project : tetra-zynq-phy
// Standard: ETSI EN 300 392-2 §16.10.x (U-ATTACH-DETACH-GROUP-IDENTITY)
// =============================================================================
// Thin wrapper over the generic `tetra_indirect_mailbox` (passive RTL-push,
// AXI-pull pattern, identical to `tetra_demand_mailbox` for mm=2).  Holds the
// PDU-specific snapshot field-latches for U-ATTACH-DETACH-GRP-ID and
// delegates pending/ack/drop_cnt + indirect read-mux to the shared block.
// SW reads the indirect window, looks up the GSSIs in EntityTable / Profile,
// then stages the D-ATTACH-DETACH-GRP-ID-ACK reply via tetra_grp_reply_mailbox.
//
// Word layout (data_words_sys[0..15], 32 bit each):
//   W0 [31:24] = 8'hA7 magic (distinguishes from mm=2 demand mailbox 0xA5)
//      [23:21] = 3'd0 reserved
//      [20:19] = 2'd  rec_count[1:0]   (number of GIU records, 0..3)
//      [18]    = 1'b  attach_detach_mode
//      [17]    = 1'b  group_identity_report
//      [16: 0] = 17'd0 reserved
//   W1 [31:24] = 8'd0
//      [23: 0] = ssi[23:0]                (UL pdu source MS-SSI)
//   W2 [31:24] = 8'd0
//      [23: 0] = gssi_array[ 23:  0]      (record 0 GSSI)
//   W3 [31:24] = 8'd0
//      [23: 0] = gssi_array[ 47: 24]      (record 1 GSSI)
//   W4 [31:24] = 8'd0
//      [23: 0] = gssi_array[ 71: 48]      (record 2 GSSI)
//   W5 [31:18] = 14'd0 reserved
//      [17:12] = at_array[5:0]            (3 × 2-bit address_type)
//      [11: 9] = adi_array[2:0]           (3 × 1-bit attach_detach_type_id)
//      [ 8: 0] = class_array[8:0]         (3 × 3-bit class_of_usage)
//   W6 [31:16] = 16'd0
//      [15: 0] = drop_cnt_sys[15:0]
//   W7..W15    = 32'd0 (reserved)
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_grp_demand_mailbox (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Snapshot push port — clk_sys, fed by IE-Parser passive tap (mm=7 path)
    input  wire        grp_parsed_valid_sys,
    input  wire [23:0] grp_ul_ssi_sys,
    input  wire [1:0]  grp_rec_count_sys,
    input  wire        grp_attach_detach_mode_sys,
    input  wire        grp_group_identity_report_sys,
    input  wire [71:0] grp_gssi_array_sys,
    input  wire [8:0]  grp_class_array_sys,
    input  wire [2:0]  grp_adi_array_sys,
    input  wire [5:0]  grp_at_array_sys,

    // ACK port — clk_sys (already 2-FF resynced from clk_axi by caller)
    input  wire        ack_consumed_pulse_sys,

    // Read port — combinational mux indexed by 4-bit word selector
    input  wire [3:0]  index_sys,
    output wire [31:0] data_word_sys,

    // Status outputs — clk_sys
    output wire        pending_sys,
    output wire [15:0] drop_cnt_sys
);

    // -----------------------------------------------------------------------
    // Latched snapshot fields (PDU-specific — wrapper-local)
    // -----------------------------------------------------------------------
    reg [23:0] ssi_lat_sys;
    reg [1:0]  rec_count_lat_sys;
    reg        atd_mode_lat_sys;
    reg        grp_report_lat_sys;
    reg [71:0] gssi_arr_lat_sys;
    reg [8:0]  class_arr_lat_sys;
    reg [2:0]  adi_arr_lat_sys;
    reg [5:0]  at_arr_lat_sys;

    // pending comes from the generic block; we use it to compute push_accept/drop
    wire pending_w;
    wire push_accept_w = grp_parsed_valid_sys & ~pending_w;
    wire push_drop_w   = grp_parsed_valid_sys &  pending_w;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) ssi_lat_sys <= 24'd0;
        else if (push_accept_w) ssi_lat_sys <= grp_ul_ssi_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) rec_count_lat_sys <= 2'd0;
        else if (push_accept_w) rec_count_lat_sys <= grp_rec_count_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) atd_mode_lat_sys <= 1'b0;
        else if (push_accept_w) atd_mode_lat_sys <= grp_attach_detach_mode_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) grp_report_lat_sys <= 1'b0;
        else if (push_accept_w) grp_report_lat_sys <= grp_group_identity_report_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) gssi_arr_lat_sys <= 72'd0;
        else if (push_accept_w) gssi_arr_lat_sys <= grp_gssi_array_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) class_arr_lat_sys <= 9'd0;
        else if (push_accept_w) class_arr_lat_sys <= grp_class_array_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) adi_arr_lat_sys <= 3'd0;
        else if (push_accept_w) adi_arr_lat_sys <= grp_adi_array_sys;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) at_arr_lat_sys <= 6'd0;
        else if (push_accept_w) at_arr_lat_sys <= grp_at_array_sys;
    end

    // -----------------------------------------------------------------------
    // Word array fed to the generic indirect-mailbox.
    // -----------------------------------------------------------------------
    wire [15:0] drop_cnt_w;

    wire [31:0] w0_w = {8'hA7, 3'd0,
                         rec_count_lat_sys,
                         atd_mode_lat_sys,
                         grp_report_lat_sys,
                         17'd0};
    wire [31:0] w1_w = {8'd0, ssi_lat_sys};
    wire [31:0] w2_w = {8'd0, gssi_arr_lat_sys[23:0]};
    wire [31:0] w3_w = {8'd0, gssi_arr_lat_sys[47:24]};
    wire [31:0] w4_w = {8'd0, gssi_arr_lat_sys[71:48]};
    wire [31:0] w5_w = {14'd0, at_arr_lat_sys, adi_arr_lat_sys, class_arr_lat_sys};
    wire [31:0] w6_w = {16'd0, drop_cnt_w};

    wire [16*32-1:0] data_words_w = {
        32'd0, 32'd0, 32'd0, 32'd0,   // W15..W12
        32'd0, 32'd0, 32'd0, 32'd0,   // W11..W8
        32'd0,                         // W7 reserved
        w6_w,  w5_w,  w4_w,
        w3_w,  w2_w,  w1_w,  w0_w
    };

    // -----------------------------------------------------------------------
    // Generic indirect-mailbox: pending/drop_cnt FSM + indirect read mux
    // -----------------------------------------------------------------------
    tetra_indirect_mailbox #(
        .NUM_WORDS   (16),
        .INDEX_WIDTH (4)
    ) u_imbox (
        .clk_sys        (clk_sys),
        .rst_n_sys      (rst_n_sys),
        .data_words_sys (data_words_w),
        .push_valid_sys (grp_parsed_valid_sys),
        .push_drop_sys  (push_drop_w),
        .index_sys      (index_sys),
        .ack_pulse_sys  (ack_consumed_pulse_sys),
        .pending_sys    (pending_w),
        .drop_cnt_sys   (drop_cnt_w),
        .data_out_sys   (data_word_sys)
    );

    assign pending_sys  = pending_w;
    assign drop_cnt_sys = drop_cnt_w;

endmodule

`default_nettype wire
