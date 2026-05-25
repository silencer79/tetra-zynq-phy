// =============================================================================
// tetra_slot_content_mux.v — Schedule BRAM prefetch (post-Y.3 stripped)
// =============================================================================
//
// Phase Y.3 — body/meta latches and SW-bank dispatch were moved into
// tetra_burst_dispatcher. This module is now ONLY the BRAM-prefetch
// FSM that keeps the four schedule entries (one per TN of the upcoming
// frame) in registers visible to the dispatcher.
//
// Outputs:
// sched_addr_sys — Port-B address into tetra_slot_schedule
// sched_entry_reg_sys0..3 — registered 16-bit schedule entries
// dbg_sched_entry0..3_sys — ILA-friendly aliases of the above
//
// BRAM read strategy — pick-ahead, single read port (unchanged):
// Trigger:
// * slot_pulse_sys && (tn_sys == 2'd3) — kick off 4-entry refresh for
// the NEXT frame. Full slot available for 4 reads (~6 sys-cycles
// total).
// * first_refresh_pending_sys (one-shot at reset) — refresh CURRENT
// frame on the very first slot_pulse after reset.
//
// Next-frame (fn', mn'[1:0]) wrap math (0-based counters):
// fn == 17: fn' = 0, mn'[1:0] = mn[1:0] + 1 (2-bit wrap)
// else: fn' = fn + 1, mn'[1:0] = mn[1:0]
//
// FSM:
// S_IDLE wait for trigger
// S_RD0 addr valid for TN=0
// S_RD1 addr valid for TN=1; latch BRAM data for TN=0 into reg0
// S_RD2 addr valid for TN=2; latch [1]
// S_RD3 addr valid for TN=3; latch [2]
// S_CAP3 latch [3]; return to S_IDLE
//
// Coding rules: Verilog-2001 strict (R1–R10).
// =============================================================================

`default_nettype none

module tetra_slot_content_mux (
 input wire clk_sys,
 input wire rst_n_sys,

 // Timebase
 input wire [1:0] tn_sys,
 input wire [4:0] fn_sys,
 input wire [5:0] mn_sys,
 input wire slot_pulse_sys,
 input wire tdma_tick_sys, // reserved; not used

 // Schedule BRAM read interface (Port B, externally-driven address)
 output wire [8:0] sched_addr_sys,
 input wire [15:0] sched_data_sys,

 // Latched schedule entries (one per TN of the upcoming frame)
 output wire [15:0] sched_entry_reg_sys0,
 output wire [15:0] sched_entry_reg_sys1,
 output wire [15:0] sched_entry_reg_sys2,
 output wire [15:0] sched_entry_reg_sys3,

 // Debug probes (ILA-friendly aliases)
 output wire [15:0] dbg_sched_entry0_sys,
 output wire [15:0] dbg_sched_entry1_sys,
 output wire [15:0] dbg_sched_entry2_sys,
 output wire [15:0] dbg_sched_entry3_sys
);

// =============================================================================
// Schedule entry latches — one 16-bit entry per TN
// =============================================================================
reg [15:0] sched_entry_reg_sys0_r;
reg [15:0] sched_entry_reg_sys1_r;
reg [15:0] sched_entry_reg_sys2_r;
reg [15:0] sched_entry_reg_sys3_r;

assign sched_entry_reg_sys0 = sched_entry_reg_sys0_r;
assign sched_entry_reg_sys1 = sched_entry_reg_sys1_r;
assign sched_entry_reg_sys2 = sched_entry_reg_sys2_r;
assign sched_entry_reg_sys3 = sched_entry_reg_sys3_r;

assign dbg_sched_entry0_sys = sched_entry_reg_sys0_r;
assign dbg_sched_entry1_sys = sched_entry_reg_sys1_r;
assign dbg_sched_entry2_sys = sched_entry_reg_sys2_r;
assign dbg_sched_entry3_sys = sched_entry_reg_sys3_r;

// =============================================================================
// Refresh FSM
// =============================================================================
localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_RD0 = 3'd1;
localparam [2:0] S_RD1 = 3'd2;
localparam [2:0] S_RD2 = 3'd3;
localparam [2:0] S_RD3 = 3'd4;
localparam [2:0] S_CAP3 = 3'd5;

reg [2:0] state_sys;
reg [2:0] next_state_sys;

wire fn_wrap_sys = (fn_sys == 5'd17);
wire [4:0] fn_next_sys = fn_wrap_sys ? 5'd0: (fn_sys + 5'd1);
wire [1:0] mn_next_low2_sys = fn_wrap_sys ? (mn_sys[1:0] + 2'd1)
: mn_sys[1:0];

reg [4:0] refresh_fn_sys;
reg [1:0] refresh_mn_low2_sys;

reg first_refresh_pending_sys;

wire refresh_trigger_sys = slot_pulse_sys &&
 (first_refresh_pending_sys || (tn_sys == 2'd3));

always @(*) begin
 case (state_sys)
 S_IDLE: next_state_sys = refresh_trigger_sys ? S_RD0: S_IDLE;
 S_RD0: next_state_sys = S_RD1;
 S_RD1: next_state_sys = S_RD2;
 S_RD2: next_state_sys = S_RD3;
 S_RD3: next_state_sys = S_CAP3;
 S_CAP3: next_state_sys = S_IDLE;
 default: next_state_sys = S_IDLE;
 endcase
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 state_sys <= S_IDLE;
 else
 state_sys <= next_state_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 refresh_fn_sys <= 5'd0;
 refresh_mn_low2_sys <= 2'd0;
 end else if (state_sys == S_IDLE && refresh_trigger_sys) begin
 if (first_refresh_pending_sys) begin
 refresh_fn_sys <= fn_sys;
 refresh_mn_low2_sys <= mn_sys[1:0];
 end else begin
 refresh_fn_sys <= fn_next_sys;
 refresh_mn_low2_sys <= mn_next_low2_sys;
 end
 end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 first_refresh_pending_sys <= 1'b1;
 else if (state_sys == S_IDLE && refresh_trigger_sys && first_refresh_pending_sys)
 first_refresh_pending_sys <= 1'b0;
end

// =============================================================================
// Address mux — combinational (R10).
// =============================================================================
reg [4:0] eff_fn_sys;
reg [1:0] eff_mn_low2_sys;
always @(*) begin
 if (state_sys == S_IDLE && refresh_trigger_sys) begin
 if (first_refresh_pending_sys) begin
 eff_fn_sys = fn_sys;
 eff_mn_low2_sys = mn_sys[1:0];
 end else begin
 eff_fn_sys = fn_next_sys;
 eff_mn_low2_sys = mn_next_low2_sys;
 end
 end else begin
 eff_fn_sys = refresh_fn_sys;
 eff_mn_low2_sys = refresh_mn_low2_sys;
 end
end

wire [8:0] mn72_sys = {eff_mn_low2_sys, 6'b0} + {3'b0, eff_mn_low2_sys, 3'b0};
wire [8:0] fn4_sys = {2'b0, eff_fn_sys, 2'b00};
wire [8:0] base_addr_sys = mn72_sys + fn4_sys;

reg [1:0] tn_for_addr_sys;
always @(*) begin
 case (next_state_sys)
 S_RD0: tn_for_addr_sys = 2'd0;
 S_RD1: tn_for_addr_sys = 2'd1;
 S_RD2: tn_for_addr_sys = 2'd2;
 S_RD3: tn_for_addr_sys = 2'd3;
 default: tn_for_addr_sys = 2'd0;
 endcase
end

assign sched_addr_sys = base_addr_sys + {7'b0, tn_for_addr_sys};

// =============================================================================
// Entry capture
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 sched_entry_reg_sys0_r <= 16'h0000;
 else if (state_sys == S_RD0)
 sched_entry_reg_sys0_r <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 sched_entry_reg_sys1_r <= 16'h0000;
 else if (state_sys == S_RD1)
 sched_entry_reg_sys1_r <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 sched_entry_reg_sys2_r <= 16'h0000;
 else if (state_sys == S_RD2)
 sched_entry_reg_sys2_r <= sched_data_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 sched_entry_reg_sys3_r <= 16'h0000;
 else if (state_sys == S_RD3)
 sched_entry_reg_sys3_r <= sched_data_sys;
end

// synthesis translate_off
wire _unused_scm_sys = tdma_tick_sys;
// synthesis translate_on

endmodule

`default_nettype wire
