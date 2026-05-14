// =============================================================================
// tetra_indirect_mailbox.v — Phase Y.1.0 generic indirect-mailbox (Read-Side)
// Project: tetra-zynq-phy
// =============================================================================
// Generic shared sub-block that implements the standard "RTL-push, AXI-pull"
// indirect-mailbox pattern used by passive-snapshot mailboxes (e.g. UL-Demand).
// One pending-flag, one saturating drop-counter, and one combinational
// indirect read-mux over an externally provided word array.
//
// Wrapper responsibilities:
// - hold the actual field-latches (PDU-specific)
// - flatten them into data_words_sys[] for this generic block
// - drive push_valid_sys and push_drop_sys (typically
// push_drop_sys = push_valid_sys & pending_sys, which the wrapper
// computes against the pending_sys output of this block).
//
// Generic-side responsibilities:
// - latch pending on push_valid_sys & ~pending
// - clear pending on ack_pulse_sys
// - increment drop_cnt_sys on push_drop_sys (saturating at 16'hFFFF)
// - combinational data_out_sys = data_words_sys[index_sys]
//
// Coding rules: Verilog-2001 strict, R1/R2/R4/R10 compliant, async active-low rst.
// =============================================================================
`default_nettype none

module tetra_indirect_mailbox #(
 parameter NUM_WORDS = 16,
 parameter INDEX_WIDTH = 4
) (
 input wire clk_sys,
 input wire rst_n_sys,

 // Wrapper-driven word array (one entry per indirect index)
 input wire [NUM_WORDS*32-1:0] data_words_sys,

 // Push side — wrapper-driven 1-cyc pulses
 input wire push_valid_sys,
 input wire push_drop_sys,

 // Pull side (clk_sys, AXI-resynced by caller)
 input wire [INDEX_WIDTH-1:0] index_sys,
 input wire ack_pulse_sys,

 // Status / data out
 output wire pending_sys,
 output wire [15:0] drop_cnt_sys,
 output wire [31:0] data_out_sys
);

 // ------------------------------------------------------------------
 // R1: pending flag — set on accepted push, cleared on ACK
 // accepted push = push_valid_sys & ~pending (wrapper guarantees this
 // semantic by computing push_drop_sys = push_valid & pending; we still
 // gate the set-condition locally so we are robust if the wrapper feeds
 // push_valid every cycle).
 // ------------------------------------------------------------------
 reg pending_r_sys;
 wire push_accept_w = push_valid_sys & ~pending_r_sys;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 pending_r_sys <= 1'b0;
 else if (push_accept_w)
 pending_r_sys <= 1'b1;
 else if (ack_pulse_sys)
 pending_r_sys <= 1'b0;
 end

 // ------------------------------------------------------------------
 // R1: 16-bit saturating drop counter
 // ------------------------------------------------------------------
 reg [15:0] drop_cnt_r_sys;
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 drop_cnt_r_sys <= 16'd0;
 else if (push_drop_sys & (drop_cnt_r_sys != 16'hFFFF))
 drop_cnt_r_sys <= drop_cnt_r_sys + 16'd1;
 end

 // ------------------------------------------------------------------
 // R10: combinational indirect read-mux over the wrapper word array
 // ------------------------------------------------------------------
 wire [31:0] data_mux_w;
 assign data_mux_w =
 (index_sys < NUM_WORDS) ? data_words_sys[index_sys*32 +: 32]
: 32'd0;

 assign pending_sys = pending_r_sys;
 assign drop_cnt_sys = drop_cnt_r_sys;
 assign data_out_sys = data_mux_w;

endmodule

`default_nettype wire
