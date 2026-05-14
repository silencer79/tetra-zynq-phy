// =============================================================================
// tb_tetra_bsch_encoder_integration.v — Self-Checking Testbench (Plan Stufe 3.5)
// DUTs: tetra_tdma_timebase + tetra_sb1_encoder
// =============================================================================
//
// Integration-level TB: proves that the BSCH (SB1) encoder is correctly
// wired to the TDMA timebase, that trigger timing works, that
// cell-config fields propagate, and that dynamic (TN, FN, MN) fields
// change the encoder output as expected.
//
// This is NOT a bit-exact reference check against SW (that's covered by
// the pre-existing unit TB `tb/tb_sb1_encoder.v`). Here we verify:
// TC1: load (tn=0, fn=0, mn=0), trigger, capture output — output is
// non-zero (encoder actually produced something) and valid.
// TC2: load (tn=1, fn=17=FN_ETSI_18, mn=2), trigger, capture output —
// output differs from TC1 (different TN/FN/MN fields in SYNC PDU).
// TC3: change MCC/MNC config, rerun TC1 load, capture output — output
// differs from TC1 (static config propagates into the PDU).
// TC4: let the timebase free-run for 4 slot_pulses; each pulse must
// fire one encoder cycle and produce a valid, non-zero, and
// distinct 120-bit output (since TN advances every slot).
//
// Wiring model mirrors tetra_zynq_top.v exactly for the
// Timebase→Encoder boundary:
// encode_start_sys = slot_pulse_sys
// sdb_slot_sys = tn_sys
// frame_num_sys = fn_sys + 1 (1-based)
// multiframe_num_sys = mn_sys + 1 (1-based)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_tetra_bsch_encoder_integration;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10; // 10 ns -> 100 MHz clk_sys
localparam SYM_DIV = 4; // sym_en every 4 cycles (fast sim). Slot =
 // 255 sym_en ticks = 255*4 = 1020 cycles,
 // well outside the 142-cycle encoder latency.

// ---------------------------------------------------------------------------
// Clock / Reset
// ---------------------------------------------------------------------------
reg clk_sys;
reg rst_n_sys;
initial clk_sys = 1'b0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// sym_en generator — one-cycle pulse every SYM_DIV cycles
// ---------------------------------------------------------------------------
reg [7:0] sym_div_cnt;
reg sym_en;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 sym_div_cnt <= 8'd0;
 sym_en <= 1'b0;
 end else if (sym_div_cnt == SYM_DIV - 1) begin
 sym_div_cnt <= 8'd0;
 sym_en <= 1'b1;
 end else begin
 sym_div_cnt <= sym_div_cnt + 8'd1;
 sym_en <= 1'b0;
 end
end

// ---------------------------------------------------------------------------
// Timebase DUT
// ---------------------------------------------------------------------------
reg sync_load_strobe;
reg [1:0] sync_tn_in;
reg [4:0] sync_fn_in;
reg [5:0] sync_mn_in;
reg [5:0] sync_hn_in;

wire [7:0] tb_sym_cnt;
wire [1:0] tb_tn;
wire [4:0] tb_fn;
wire [5:0] tb_mn;
wire [5:0] tb_hn;
wire tb_slot_pulse;
wire tb_tdma_tick;

tetra_tdma_timebase u_tb_timebase (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.sym_en (sym_en),
.sync_load_strobe (sync_load_strobe),
.sync_tn_in (sync_tn_in),
.sync_fn_in (sync_fn_in),
.sync_mn_in (sync_mn_in),
.sync_hn_in (sync_hn_in),
.sym_cnt (tb_sym_cnt),
.tn (tb_tn),
.fn (tb_fn),
.mn (tb_mn),
.hn (tb_hn),
.slot_pulse (tb_slot_pulse),
.tdma_tick (tb_tdma_tick)
);

// ---------------------------------------------------------------------------
// Cell-Config stubs (reg, so the TB can change MCC/MNC between TCs)
// ---------------------------------------------------------------------------
reg [3:0] cfg_system_code;
reg [5:0] cfg_colour_code;
reg [1:0] cfg_sharing_mode;
reg [2:0] cfg_ts_reserved_frames;
reg cfg_u_plane;
reg cfg_frame_18_ext;
reg [9:0] cfg_mcc;
reg [13:0] cfg_mnc;
reg [1:0] cfg_neigh;
reg [1:0] cfg_csl;
reg cfg_late_entry;

// ---------------------------------------------------------------------------
// BSCH Encoder DUT
// ---------------------------------------------------------------------------
// Dynamic fields derived from timebase (mirrors top-level wiring).
wire [4:0] sb1_frame_num_sys = tb_fn + 5'd1;
wire [5:0] sb1_multiframe_num_sys = tb_mn + 6'd1;

wire [119:0] sb1_coded;
wire sb1_valid;

tetra_sb1_encoder u_enc (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.cfg_system_code (cfg_system_code),
.cfg_colour_code (cfg_colour_code),
.cfg_sharing_mode (cfg_sharing_mode),
.cfg_ts_reserved_frames (cfg_ts_reserved_frames),
.cfg_u_plane (cfg_u_plane),
.cfg_frame_18_ext (cfg_frame_18_ext),
.cfg_mcc (cfg_mcc),
.cfg_mnc (cfg_mnc),
.cfg_neighbour_cell_broadcast (cfg_neigh),
.cfg_cell_service_level (cfg_csl),
.cfg_late_entry_info (cfg_late_entry),
.encode_start_sys (tb_slot_pulse),
.sdb_slot_sys (tb_tn),
.frame_num_sys (sb1_frame_num_sys),
.multiframe_num_sys (sb1_multiframe_num_sys),
.sb1_coded_sys (sb1_coded),
.sb1_valid_sys (sb1_valid)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
 $dumpfile("sim_out/tb_tetra_bsch_encoder_integration.vcd");
 $dumpvars(0, tb_tetra_bsch_encoder_integration);
end

// ---------------------------------------------------------------------------
// Scoreboard / capture
// ---------------------------------------------------------------------------
reg [119:0] cap_tc1;
reg [119:0] cap_tc2;
reg [119:0] cap_tc3;
reg [119:0] cap_tc4_0, cap_tc4_1, cap_tc4_2, cap_tc4_3;

integer err_count;
integer tc_pass_count;

// Helper: wait until sb1_valid is HIGH and output is stable, i.e. the
// encoder just finished one pass. The encoder latches sb1_valid=1 at
// the S_FINISH state. We sample sb1_coded one cycle AFTER sb1_valid
// goes high to make sure the output register has settled.
task wait_encoder_done_and_capture;
 output [119:0] cap;
 integer timeout;
 begin
 timeout = 0;
 // Wait for sb1_valid high and a fresh encode. After reset
 // sb1_valid stays 1 between encodes (latched), so instead we
 // wait for S_FINISH — which we detect as the first cycle
 // after the encoder's 142-cycle pipeline completes. The
 // simplest correct trigger: wait long enough (160 cycles)
 // then sample; by then S_FINISH has definitely fired for
 // whatever slot_pulse kicked this off.
 repeat (160) @(posedge clk_sys);
 cap = sb1_coded;
 if (!sb1_valid) begin
 $display("ERROR: sb1_valid not HIGH after 160 cycles");
 err_count = err_count + 1;
 end
 end
endtask

// Helper: hold sync-load inputs, pulse strobe for 1 clk_sys cycle
task sync_load_to;
 input [1:0] t_tn;
 input [4:0] t_fn;
 input [5:0] t_mn;
 input [5:0] t_hn;
 begin
 @(posedge clk_sys);
 sync_tn_in <= t_tn;
 sync_fn_in <= t_fn;
 sync_mn_in <= t_mn;
 sync_hn_in <= t_hn;
 sync_load_strobe <= 1'b1;
 @(posedge clk_sys);
 sync_load_strobe <= 1'b0;
 // Wait for next sym_en so the load commits
 @(posedge sym_en);
 @(posedge clk_sys);
 end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
 // Init
 rst_n_sys = 1'b0;
 sync_load_strobe = 1'b0;
 sync_tn_in = 2'd0;
 sync_fn_in = 5'd0;
 sync_mn_in = 6'd0;
 sync_hn_in = 6'd0;
 cfg_system_code = 4'd3;
 cfg_colour_code = 6'd49;
 cfg_sharing_mode = 2'd0;
 cfg_ts_reserved_frames = 3'd0;
 cfg_u_plane = 1'b0;
 cfg_frame_18_ext = 1'b1;
 cfg_mcc = 10'd901;
 cfg_mnc = 14'd9998;
 cfg_neigh = 2'd3;
 cfg_csl = 2'd0;
 cfg_late_entry = 1'b1;
 err_count = 0;
 tc_pass_count = 0;

 // Deassert reset after some cycles
 repeat (5) @(posedge clk_sys);
 rst_n_sys = 1'b1;
 repeat (5) @(posedge clk_sys);

 // =========================================================
 // TC1: load (tn=0, fn=0, mn=0); capture encoder output after
 // the next slot_pulse drives encode_start.
 // =========================================================
 $display("=== TC1: baseline load tn=0 fn=0 mn=0, default cell-cfg ===");
 sync_load_to(2'd0, 5'd0, 6'd0, 6'd0);
 // Wait for next slot_pulse — guarantees a fresh encode with TN=0 FN=0 MN=0.
 @(posedge tb_slot_pulse);
 // Sample the TN/FN/MN the encoder saw on that pulse:
 // slot_pulse fires the cycle AFTER sym_cnt 254→0 wrap, so the
 // counters have already advanced to the NEW slot's (tn+1,fn,mn).
 // That's OK — we just capture whatever it is and assert the
 // output is valid + non-zero.
 wait_encoder_done_and_capture(cap_tc1);
 if (cap_tc1 != 120'd0) begin
 $display("PASS TC1: cap_tc1 = %030h (non-zero, valid=%b)", cap_tc1, sb1_valid);
 tc_pass_count = tc_pass_count + 1;
 end else begin
 $display("FAIL TC1: encoder output is zero");
 err_count = err_count + 1;
 end

 // =========================================================
 // TC2: load (tn=1, fn=17, mn=2); capture — must differ from TC1
 // =========================================================
 $display("=== TC2: load tn=1 fn=17 mn=2, same cell-cfg ===");
 sync_load_to(2'd1, 5'd17, 6'd2, 6'd0);
 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc2);
 if (cap_tc2 != cap_tc1 && cap_tc2 != 120'd0) begin
 $display("PASS TC2: cap_tc2 = %030h (differs from TC1)", cap_tc2);
 tc_pass_count = tc_pass_count + 1;
 end else begin
 $display("FAIL TC2: cap_tc2 = %030h cap_tc1 = %030h",
 cap_tc2, cap_tc1);
 err_count = err_count + 1;
 end

 // =========================================================
 // TC3: change MCC/MNC, re-run TC1 load — must differ from TC1
 // =========================================================
 $display("=== TC3: change MCC/MNC, same (tn=0, fn=0, mn=0) ===");
 cfg_mcc = 10'd262; // different cell id
 cfg_mnc = 14'd106;
 // Wait a couple of clk_sys cycles for new cfg to settle (no CDC
 // here since TB drives cfg directly in clk_sys domain).
 repeat (2) @(posedge clk_sys);
 sync_load_to(2'd0, 5'd0, 6'd0, 6'd0);
 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc3);
 if (cap_tc3 != cap_tc1 && cap_tc3 != 120'd0) begin
 $display("PASS TC3: cap_tc3 = %030h (MCC/MNC change propagated)",
 cap_tc3);
 tc_pass_count = tc_pass_count + 1;
 end else begin
 $display("FAIL TC3: cap_tc3 = %030h cap_tc1 = %030h",
 cap_tc3, cap_tc1);
 err_count = err_count + 1;
 end

 // Restore original config for TC4
 cfg_mcc = 10'd901;
 cfg_mnc = 14'd9998;
 repeat (2) @(posedge clk_sys);

 // =========================================================
 // TC4: free-run — 4 consecutive slot_pulses, all 4 outputs must
 // be non-zero and pairwise distinct (since TN advances each
 // slot, the SYNC PDU's TimeSlot field changes, which
 // propagates through CRC + RCPC + interleaver → different
 // 120-bit codewords).
 // =========================================================
 $display("=== TC4: 4 consecutive slot_pulses, pairwise distinct ===");
 // Re-load from a known state so TN starts at 0 across the test.
 sync_load_to(2'd0, 5'd0, 6'd0, 6'd0);

 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc4_0);
 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc4_1);
 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc4_2);
 @(posedge tb_slot_pulse);
 wait_encoder_done_and_capture(cap_tc4_3);

 if (cap_tc4_0 != 120'd0 &&
 cap_tc4_1 != 120'd0 &&
 cap_tc4_2 != 120'd0 &&
 cap_tc4_3 != 120'd0 &&
 cap_tc4_0 != cap_tc4_1 &&
 cap_tc4_1 != cap_tc4_2 &&
 cap_tc4_2 != cap_tc4_3 &&
 cap_tc4_0 != cap_tc4_2 &&
 cap_tc4_1 != cap_tc4_3 &&
 cap_tc4_0 != cap_tc4_3) begin
 $display("PASS TC4: 4 successive outputs all distinct + non-zero");
 $display(" s0 = %030h", cap_tc4_0);
 $display(" s1 = %030h", cap_tc4_1);
 $display(" s2 = %030h", cap_tc4_2);
 $display(" s3 = %030h", cap_tc4_3);
 tc_pass_count = tc_pass_count + 1;
 end else begin
 $display("FAIL TC4: 4 successive outputs not all distinct/non-zero");
 $display(" s0 = %030h", cap_tc4_0);
 $display(" s1 = %030h", cap_tc4_1);
 $display(" s2 = %030h", cap_tc4_2);
 $display(" s3 = %030h", cap_tc4_3);
 err_count = err_count + 1;
 end

 // =========================================================
 // Final report
 // =========================================================
 $display("=============================================");
 if (err_count == 0) begin
 $display("tb_tetra_bsch_encoder_integration: ALL %0d TCs PASS",
 tc_pass_count);
 $display("RESULT: PASS");
 end else begin
 $display("tb_tetra_bsch_encoder_integration: %0d errors, %0d pass",
 err_count, tc_pass_count);
 $display("RESULT: FAIL");
 end
 $display("=============================================");
 $finish;
end

// Safety watchdog — should never fire
initial begin
 #5_000_000; // 5 ms
 $display("ERROR: watchdog timeout");
 $finish;
end

endmodule

`default_nettype wire
