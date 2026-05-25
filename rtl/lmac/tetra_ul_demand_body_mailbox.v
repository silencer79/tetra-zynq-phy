// =============================================================================
// tetra_ul_demand_body_mailbox.v — Raw UL-Demand-Body Snapshot Mailbox
// Project: tetra-zynq-phy
// =============================================================================
// Captures the raw 129-bit MM body + SSI + mm_pdu_type produced by
// tetra_ul_demand_reassembly.v, so SW can do the IE-walking instead of the
// large RTL state machine (tetra_ul_demand_ie_parser.v = ~3500 LUT).
//
// Push: rising edge of reass_valid_sys latches body/ssi/mm_pdu_type and sets
//       pending. Subsequent pushes while pending=1 are dropped (drop_cnt++).
//
// Word layout (data_words_sys[0..15], 32 bit each, MSB-first for clarity):
//   W0  [31:24] = 8'hA5 magic
//       [ 7: 4] = mm_pdu_type[3:0]
//       [    0] = body[128]   (the 129th bit, MSB)
//   W1  [31:24] = 8'd0
//       [23: 0] = ssi[23:0]
//   W2          = body[127:96]
//   W3          = body[95:64]
//   W4          = body[63:32]
//   W5          = body[31:0]
//   W6          = 32'd0 reserved
//   W7  [31:16] = 16'd0
//       [15: 0] = drop_cnt[15:0]
//   W8..W15     = 32'd0 reserved
//
// SW protocol:
//   1. Poll REG_UL_DEMAND_BODY_STATUS[0] = pending; wait for 1.
//   2. Read INDEX 0..7 via REG_UL_DEMAND_BODY_INDEX + REG_UL_DEMAND_BODY_DATA.
//   3. Pulse REG_UL_DEMAND_BODY_ACK[0]=1 to clear pending + arm next.
//
// Coding rules: Verilog-2001 strict.
// =============================================================================
`default_nettype none

module tetra_ul_demand_body_mailbox (
 input wire clk_sys,
 input wire rst_n_sys,

 // Push port — clk_sys, fed by tetra_ul_demand_reassembly output
 input wire push_valid_sys,
 input wire [128:0] body_sys,
 input wire [23:0] ssi_sys,
 input wire [3:0] mm_pdu_type_sys,

 // ACK port — clk_sys (2-FF resynced from clk_axi by caller)
 input wire ack_consumed_pulse_sys,

 // Read port — combinational mux indexed by 4-bit word selector
 input wire [3:0] index_sys,
 output wire [31:0] data_word_sys,

 // Status outputs — clk_sys
 output wire pending_sys,
 output wire [15:0] drop_cnt_sys
);

 // Latched snapshot fields
 reg [128:0] body_lat_sys;
 reg [23:0]  ssi_lat_sys;
 reg [3:0]   mm_pdu_type_lat_sys;

 wire pending_w;
 wire push_accept_w = push_valid_sys & ~pending_w;
 wire push_drop_w   = push_valid_sys &  pending_w;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)        body_lat_sys <= 129'd0;
 else if (push_accept_w) body_lat_sys <= body_sys;
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)        ssi_lat_sys <= 24'd0;
 else if (push_accept_w) ssi_lat_sys <= ssi_sys;
 end
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)        mm_pdu_type_lat_sys <= 4'd0;
 else if (push_accept_w) mm_pdu_type_lat_sys <= mm_pdu_type_sys;
 end

 // ------------------------------------------------------------------
 // Word array fed to the generic indirect-mailbox.
 // ------------------------------------------------------------------
 wire [15:0] drop_cnt_w;
 wire [16*32-1:0] words_flat_w;

 // W0: magic + mm_pdu_type + body[128]
 wire [31:0] w0_w = {8'hA5,         /* [31:24] magic */
                     16'd0,         /* [23: 8] reserved */
                     mm_pdu_type_lat_sys, /* [ 7: 4] */
                     3'd0,          /* [ 3: 1] reserved */
                     body_lat_sys[128]};  /* [    0] */
 wire [31:0] w1_w = {8'd0, ssi_lat_sys};
 wire [31:0] w2_w = body_lat_sys[127:96];
 wire [31:0] w3_w = body_lat_sys[95:64];
 wire [31:0] w4_w = body_lat_sys[63:32];
 wire [31:0] w5_w = body_lat_sys[31:0];
 wire [31:0] w6_w = 32'd0;
 wire [31:0] w7_w = {16'd0, drop_cnt_w};

 assign words_flat_w = {32'd0, 32'd0, 32'd0, 32'd0,   /* W15..W12 */
                        32'd0, 32'd0, 32'd0, 32'd0,   /* W11..W8 */
                        w7_w,  w6_w,  w5_w,  w4_w,    /* W7..W4 */
                        w3_w,  w2_w,  w1_w,  w0_w};   /* W3..W0 */

 tetra_indirect_mailbox #(
   .NUM_WORDS   (16),
   .INDEX_WIDTH (4)
 ) u_indirect (
   .clk_sys        (clk_sys),
   .rst_n_sys      (rst_n_sys),
   .data_words_sys (words_flat_w),
   .push_valid_sys (push_accept_w),
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
