// =============================================================================
// tetra_demand_mailbox.v — Phase X.1 UL-Demand-Snapshot Mailbox (clk_sys)
// Project : tetra-zynq-phy
// Standard: ETSI EN 300 392-2 (UL-Demand) — passive snapshot
// =============================================================================
// Y.1.0 refactor: thin wrapper over generic `tetra_indirect_mailbox`.
// Holds the PDU-specific snapshot field-latches (W0..W7 layout per spec) and
// delegates pending/ack/drop_cnt + indirect read-mux to the shared block.
// Module header / behavior bit-exact preserved (tb_demand_mailbox 32/32).
//
// FSM (handled by generic block):
//   IDLE / EMPTY (pending=0)  — first push_valid pulse latches all fields
//                               and asserts pending.
//   FULL         (pending=1)  — additional push pulses are dropped;
//                               drop_cnt_sys increments by 1 per dropped pulse.
//                               ack_consumed_pulse_sys clears pending.
//
// Word layout (data_words_sys[0..15], 32 bit each):
//   W0 [31:24] = 8'hA5 magic
//      [23:21] = 3'd0 reserved
//      [20:18] = count[2:0]
//      [17:15] = loc_upd_type[2:0]
//      [14:0]  = 15'd0 reserved
//   W1 [31:24] = 8'd0
//      [23: 0] = ssi[23:0]
//   W2 [31:14] = 18'd0
//      [13: 0] = la[13:0]
//   W3..W5     = gssi_array slices (3 × 24 bit)
//   W6 [31: 9] = 23'd0
//      [ 8: 0] = class_array[8:0]   (3 × 3-bit class fields, packed)
//   W7 [31:16] = 16'd0
//      [15: 0] = drop_cnt_sys[15:0]
//   W8..W15    = 32'd0 (reserved for Phase X.2+)
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R6/R10 compliant.
// =============================================================================
`default_nettype none

module tetra_demand_mailbox (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Snapshot push port — clk_sys, fed by IE-Parser passive tap
    input  wire        demand_parsed_valid_sys,
    input  wire [23:0] demand_ul_ssi_sys,
    input  wire [2:0]  demand_gssi_count_sys,
    input  wire [71:0] demand_gssi_array_sys,
    input  wire [8:0]  demand_class_array_sys,
    input  wire [2:0]  demand_loc_upd_type_sys,
    input  wire [13:0] demand_la_sys,

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
    reg [2:0]  count_lat_sys;
    reg [71:0] gssi_arr_lat_sys;
    reg [8:0]  class_arr_lat_sys;
    reg [2:0]  loc_upd_type_lat_sys;
    reg [13:0] la_lat_sys;

    // pending comes from the generic block; we use it to compute push_accept/drop
    wire pending_w;
    wire push_accept_w = demand_parsed_valid_sys & ~pending_w;
    wire push_drop_w   = demand_parsed_valid_sys &  pending_w;

    // ------------------------------------------------------------------
    // R1: snapshot field latches — only update on accepted push
    // ------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            ssi_lat_sys <= 24'd0;
        else if (push_accept_w)
            ssi_lat_sys <= demand_ul_ssi_sys;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            count_lat_sys <= 3'd0;
        else if (push_accept_w)
            count_lat_sys <= demand_gssi_count_sys;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            gssi_arr_lat_sys <= 72'd0;
        else if (push_accept_w)
            gssi_arr_lat_sys <= demand_gssi_array_sys;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            class_arr_lat_sys <= 9'd0;
        else if (push_accept_w)
            class_arr_lat_sys <= demand_class_array_sys;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            loc_upd_type_lat_sys <= 3'd0;
        else if (push_accept_w)
            loc_upd_type_lat_sys <= demand_loc_upd_type_sys;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            la_lat_sys <= 14'd0;
        else if (push_accept_w)
            la_lat_sys <= demand_la_sys;
    end

    // ------------------------------------------------------------------
    // Word array fed to the generic indirect-mailbox.
    // W7 includes the live drop_cnt from the generic block — declared here
    // as wires that capture the generic outputs and are then routed back
    // into the word array.
    // ------------------------------------------------------------------
    wire [15:0] drop_cnt_w;

    wire [31:0] w0_w = {8'hA5, 3'd0,
                         count_lat_sys,
                         loc_upd_type_lat_sys,
                         15'd0};
    wire [31:0] w1_w = {8'd0, ssi_lat_sys};
    wire [31:0] w2_w = {18'd0, la_lat_sys};
    wire [31:0] w3_w = {8'd0, gssi_arr_lat_sys[23:0]};
    wire [31:0] w4_w = {8'd0, gssi_arr_lat_sys[47:24]};
    wire [31:0] w5_w = {8'd0, gssi_arr_lat_sys[71:48]};
    wire [31:0] w6_w = {23'd0, class_arr_lat_sys};
    wire [31:0] w7_w = {16'd0, drop_cnt_w};

    wire [16*32-1:0] data_words_w = {
        32'd0, 32'd0, 32'd0, 32'd0,   // W15..W12
        32'd0, 32'd0, 32'd0, 32'd0,   // W11..W8
        w7_w,  w6_w,  w5_w,  w4_w,
        w3_w,  w2_w,  w1_w,  w0_w
    };

    // ------------------------------------------------------------------
    // Generic indirect-mailbox: pending/drop_cnt FSM + indirect read mux
    // ------------------------------------------------------------------
    tetra_indirect_mailbox #(
        .NUM_WORDS   (16),
        .INDEX_WIDTH (4)
    ) u_imbox (
        .clk_sys        (clk_sys),
        .rst_n_sys      (rst_n_sys),
        .data_words_sys (data_words_w),
        .push_valid_sys (demand_parsed_valid_sys),
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
