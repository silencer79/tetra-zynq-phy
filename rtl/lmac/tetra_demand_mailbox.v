// =============================================================================
// tetra_demand_mailbox.v — Phase X.1 UL-Demand-Snapshot Mailbox (clk_sys)
// Project : tetra-zynq-phy
// Standard: ETSI EN 300 392-2 (UL-Demand) — passive snapshot
// =============================================================================
// Passive 1-deep snapshot register file that captures the parsed UL-Demand IE
// fields produced by `tetra_ul_demand_ie_parser` (slot 0 of the GSSI array,
// scaling out for up to 3 GSSIs/Classes per Phase X.1 spec).  The snapshot
// is held in a single `pending` slot until ARM SW reads-and-acks it via the
// AXI demand mailbox window (REG_DEMAND_STATUS / DATA / INDEX / ACK).
//
// FSM:
//   IDLE / EMPTY (pending=0)  — first demand_parsed_valid pulse latches all
//                               fields and asserts pending.
//   FULL         (pending=1)  — additional demand_parsed_valid pulses are
//                               dropped; drop_cnt_sys increments by 1 per
//                               dropped pulse.  ack_consumed_pulse_sys
//                               clears pending (latches stay until next push
//                               so SW may re-read after ACK).
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
    // Latched snapshot fields
    // -----------------------------------------------------------------------
    reg [23:0] ssi_lat_sys;
    reg [2:0]  count_lat_sys;
    reg [71:0] gssi_arr_lat_sys;
    reg [8:0]  class_arr_lat_sys;
    reg [2:0]  loc_upd_type_lat_sys;
    reg [13:0] la_lat_sys;

    reg        pending_r_sys;
    reg [15:0] drop_cnt_r_sys;

    // accept-new-push when EMPTY; drop when FULL
    wire push_accept_w = demand_parsed_valid_sys & ~pending_r_sys;
    wire push_drop_w   = demand_parsed_valid_sys &  pending_r_sys;

    // ------------------------------------------------------------------
    // R1: snapshot field latches
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
    // R1: pending flag (set on accept, cleared on ACK)
    // ------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pending_r_sys <= 1'b0;
        else if (push_accept_w)
            pending_r_sys <= 1'b1;
        else if (ack_consumed_pulse_sys)
            pending_r_sys <= 1'b0;
    end

    // ------------------------------------------------------------------
    // R1: drop counter (16-bit saturating)
    // ------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            drop_cnt_r_sys <= 16'd0;
        else if (push_drop_w & (drop_cnt_r_sys != 16'hFFFF))
            drop_cnt_r_sys <= drop_cnt_r_sys + 16'd1;
    end

    // ------------------------------------------------------------------
    // R10: combinational word mux
    // ------------------------------------------------------------------
    reg [31:0] data_word_mux_sys;
    always @(*) begin
        case (index_sys)
            4'd0:  data_word_mux_sys = {8'hA5, 3'd0,
                                         count_lat_sys,
                                         loc_upd_type_lat_sys,
                                         15'd0};
            4'd1:  data_word_mux_sys = {8'd0, ssi_lat_sys};
            4'd2:  data_word_mux_sys = {18'd0, la_lat_sys};
            4'd3:  data_word_mux_sys = {8'd0, gssi_arr_lat_sys[23:0]};
            4'd4:  data_word_mux_sys = {8'd0, gssi_arr_lat_sys[47:24]};
            4'd5:  data_word_mux_sys = {8'd0, gssi_arr_lat_sys[71:48]};
            4'd6:  data_word_mux_sys = {23'd0, class_arr_lat_sys};
            4'd7:  data_word_mux_sys = {16'd0, drop_cnt_r_sys};
            default: data_word_mux_sys = 32'd0;
        endcase
    end

    assign data_word_sys = data_word_mux_sys;
    assign pending_sys   = pending_r_sys;
    assign drop_cnt_sys  = drop_cnt_r_sys;

endmodule

`default_nettype wire
