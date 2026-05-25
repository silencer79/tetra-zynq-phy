// =============================================================================
// tb_tx_tdma_axi.v — Self-Checking Testbench (Plan §4 Stufe 2)
// DUT: tetra_axi_lite_regs + tetra_tdma_timebase
// =============================================================================
// Exercises the AXI-Lite path for the TX TDMA timebase registers added in
// Stufe 2:
// 0x140 TX_TDMA_LOAD W [1:0]TN [6:2]FN [12:7]MN [18:13]HN [31]STROBE
// 0x144 TX_TDMA_STATE RO [1:0]TN [6:2]FN [12:7]MN [18:13]HN [26:19]sym_cnt
//
// The TB instantiates both the AXI register bank AND the real timebase
// module side by side, wired the same way the top-level wires them,
// including the strobe and STATE-snapshot 2-FF synchronizers. All other
// DUT ports (BSCH payload, status etc.) are tied to sensible defaults
// and ignored.
//
// Test cases (matching the 6 TCs enumerated in the Stufe 2 prompt):
// TC1: after reset, TX_TDMA_STATE reads back (TN,FN,MN,HN,sym_cnt) = 0.
// TC2: write LOAD with STROBE=0 — counters DO NOT jump to the written
// values (they keep free-running from 0,0,0,0).
// TC3: write LOAD with STROBE=1 — after enough sym_en ticks the counters
// reflect the loaded (TN,FN,MN,HN) [sym_cnt may have advanced].
// TC4: write a DIFFERENT load with STROBE=1 — counters commit the new
// values.
// TC5: sym_cnt visibility — after a handful of sym_en ticks the field
// is non-zero (free-running confirms the strobe isn't stuck).
// TC6: monotonicity over wraps — successive reads while the counter
// free-runs never return Xs/Zs and produce non-decreasing sym_cnt
// within the same slot (intra-slot monotonic).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_tx_tdma_axi;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10; // 10 ns = 100 MHz shared clk_axi == clk_sys
localparam [31:0] ADDR_TX_TDMA_LOAD = 32'h0000_0140;
localparam [31:0] ADDR_TX_TDMA_STATE = 32'h0000_0144;

// ---------------------------------------------------------------------------
// Clock / Reset
// ---------------------------------------------------------------------------
reg clk; // shared clk_axi == clk_sys (matches Zynq PS PLL sharing)
reg rst_n;
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// AXI4-Lite Master signals
// ---------------------------------------------------------------------------
reg [31:0] awaddr;
reg awvalid;
wire awready;
reg [31:0] wdata;
reg [3:0] wstrb;
reg wvalid;
wire wready;
wire [1:0] bresp;
wire bvalid;
reg bready;
reg [31:0] araddr;
reg arvalid;
wire arready;
wire [31:0] rdata;
wire [1:0] rresp;
wire rvalid;
reg rready;

// ---------------------------------------------------------------------------
// Timebase stimulus: sym_en pulse — one cycle every SYM_PERIOD cycles
// ---------------------------------------------------------------------------
// Keep sym_en fast enough for TB speed (every 20 cycles vs. ~5556 in HW),
// slow enough that multiple AXI transactions can land between ticks.
localparam SYM_DIV = 20;
reg [7:0] sym_div_cnt;
reg sym_en;
always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
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
// AXI register bank — TX TDMA interface wires
// ---------------------------------------------------------------------------
wire [1:0] tx_tdma_sync_tn_axi_w;
wire [4:0] tx_tdma_sync_fn_axi_w;
wire [5:0] tx_tdma_sync_mn_axi_w;
wire [5:0] tx_tdma_sync_hn_axi_w;
wire tx_tdma_sync_strobe_axi_w;

// Timebase outputs (clk_sys domain)
wire [7:0] tb_sym_cnt_sys;
wire [1:0] tb_tn_sys;
wire [4:0] tb_fn_sys;
wire [5:0] tb_mn_sys;
wire [5:0] tb_hn_sys;

// 2-FF strobe CDC (axi → sys), mirroring the top-level wiring
(* ASYNC_REG = "TRUE" *) reg strobe_sys_r0;
(* ASYNC_REG = "TRUE" *) reg strobe_sys_r1;
reg strobe_sys_r2;
always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
 strobe_sys_r0 <= 1'b0;
 strobe_sys_r1 <= 1'b0;
 strobe_sys_r2 <= 1'b0;
 end else begin
 strobe_sys_r0 <= tx_tdma_sync_strobe_axi_w;
 strobe_sys_r1 <= strobe_sys_r0;
 strobe_sys_r2 <= strobe_sys_r1;
 end
end
wire tb_strobe_sys = strobe_sys_r1 & ~strobe_sys_r2;

// Timebase DUT
tetra_tdma_timebase u_tb_timebase (
.clk_sys (clk),
.rst_n_sys (rst_n),
.sym_en (sym_en),
.sync_load_strobe (tb_strobe_sys),
.sync_tn_in (tx_tdma_sync_tn_axi_w),
.sync_fn_in (tx_tdma_sync_fn_axi_w),
.sync_mn_in (tx_tdma_sync_mn_axi_w),
.sync_hn_in (tx_tdma_sync_hn_axi_w),
.sym_cnt (tb_sym_cnt_sys),
.tn (tb_tn_sys),
.fn (tb_fn_sys),
.mn (tb_mn_sys),
.hn (tb_hn_sys),
.slot_pulse (),
.tdma_tick ()
);

// 2-FF STATE resync (sys → axi), per-bit
(* ASYNC_REG = "TRUE" *) reg [1:0] tn_axi_r0, tn_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [4:0] fn_axi_r0, fn_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [5:0] mn_axi_r0, mn_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [5:0] hn_axi_r0, hn_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [7:0] sc_axi_r0, sc_axi_r1;

always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
 tn_axi_r0 <= 2'd0; tn_axi_r1 <= 2'd0;
 fn_axi_r0 <= 5'd0; fn_axi_r1 <= 5'd0;
 mn_axi_r0 <= 6'd0; mn_axi_r1 <= 6'd0;
 hn_axi_r0 <= 6'd0; hn_axi_r1 <= 6'd0;
 sc_axi_r0 <= 8'd0; sc_axi_r1 <= 8'd0;
 end else begin
 tn_axi_r0 <= tb_tn_sys; tn_axi_r1 <= tn_axi_r0;
 fn_axi_r0 <= tb_fn_sys; fn_axi_r1 <= fn_axi_r0;
 mn_axi_r0 <= tb_mn_sys; mn_axi_r1 <= mn_axi_r0;
 hn_axi_r0 <= tb_hn_sys; hn_axi_r1 <= hn_axi_r0;
 sc_axi_r0 <= tb_sym_cnt_sys;sc_axi_r1 <= sc_axi_r0;
 end
end

// ---------------------------------------------------------------------------
// AXI register bank DUT
// ---------------------------------------------------------------------------
tetra_axi_lite_regs u_regs (
.s_axi_aclk (clk),
.s_axi_aresetn (rst_n),
.s_axi_awaddr (awaddr),
.s_axi_awprot (3'b000),
.s_axi_awvalid (awvalid),
.s_axi_awready (awready),
.s_axi_wdata (wdata),
.s_axi_wstrb (wstrb),
.s_axi_wvalid (wvalid),
.s_axi_wready (wready),
.s_axi_bresp (bresp),
.s_axi_bvalid (bvalid),
.s_axi_bready (bready),
.s_axi_araddr (araddr),
.s_axi_arprot (3'b000),
.s_axi_arvalid (arvalid),
.s_axi_arready (arready),
.s_axi_rdata (rdata),
.s_axi_rresp (rresp),
.s_axi_rvalid (rvalid),
.s_axi_rready (rready),
 // tied-off PHY status inputs
.sync_locked_axi (1'b0),
.pll_locked_axi (1'b0),
.rx_fifo_empty_axi (1'b1),
.rx_fifo_full_axi (1'b0),
.slot_status_axi (4'b0),
.frame_num_axi (5'b0),
.slot_num_axi (2'b0),
.tx_slot_axi (2'b0),
.tx_frame_axi (5'b0),
.tx_mf_axi (6'b0),
.dbg_fe_cnt_axi (32'b0),
.dbg_demod_cnt_axi (32'b0),
.dbg_sync_cnt_axi (32'b0),
.irq_mac_block_axi (1'b0),
.irq_sync_acquired_axi (1'b0),
.irq_sync_lost_axi (1'b0),
.irq_crc_error_axi (1'b0),
.irq_rx_fifo_full_axi (1'b0),
.dma_block_count_axi (16'b0),
.crc_error_count_axi (16'b0),
.sync_lost_count_axi (16'b0),
 // unused control outputs
.ctrl_rx_enable_axi (),
.ctrl_tx_enable_axi (),
.ctrl_loopback_en_axi (),
.ctrl_reset_counters_axi (),
.sync_thresh_axi (),
.colour_code_axi (),
.rx_gain_axi (),
.tx_att_axi (),
.irq_enable_axi (),
.sb_sb1_axi (),
.sb_bkn2_axi (),
.sb_bb_axi (),
.tx_test_prbs_en_axi (),
.ndb_block1_axi (),
.ndb_block2_axi (),
.mcch_block1_axi (),
.mcch_block2_axi (),
.bnch_block1_axi (),
.bnch_block2_axi (),
 // TX TDMA interface (UUT focus)
.tx_tdma_sync_tn_axi (tx_tdma_sync_tn_axi_w),
.tx_tdma_sync_fn_axi (tx_tdma_sync_fn_axi_w),
.tx_tdma_sync_mn_axi (tx_tdma_sync_mn_axi_w),
.tx_tdma_sync_hn_axi (tx_tdma_sync_hn_axi_w),
.tx_tdma_sync_strobe_axi (tx_tdma_sync_strobe_axi_w),
.tx_tdma_state_tn_axi (tn_axi_r1),
.tx_tdma_state_fn_axi (fn_axi_r1),
.tx_tdma_state_mn_axi (mn_axi_r1),
.tx_tdma_state_hn_axi (hn_axi_r1),
.tx_tdma_state_sym_cnt_axi(sc_axi_r1),
.irq_out_axi ()
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
 $dumpfile("sim_out/tb_tx_tdma_axi.vcd");
 $dumpvars(0, tb_tx_tdma_axi);
end

// ---------------------------------------------------------------------------
// AXI4-Lite helper tasks
// ---------------------------------------------------------------------------
task axi_write;
 input [31:0] addr;
 input [31:0] data;
 begin
 @(posedge clk); #1;
 awaddr <= addr;
 awvalid <= 1'b1;
 wdata <= data;
 wstrb <= 4'hF;
 wvalid <= 1'b1;
 bready <= 1'b1;
 fork
 begin: wa
 while (!awready) @(posedge clk);
 @(posedge clk); #1; awvalid <= 1'b0;
 end
 begin: ww
 while (!wready) @(posedge clk);
 @(posedge clk); #1; wvalid <= 1'b0;
 end
 join
 while (!bvalid) @(posedge clk);
 @(posedge clk); #1; bready <= 1'b0;
 end
endtask

task axi_read;
 input [31:0] addr;
 output [31:0] data;
 begin
 @(posedge clk); #1;
 araddr <= addr;
 arvalid <= 1'b1;
 rready <= 1'b1;
 while (!arready) @(posedge clk);
 @(posedge clk); #1; arvalid <= 1'b0;
 while (!rvalid) @(posedge clk);
 data = rdata;
 @(posedge clk); #1; rready <= 1'b0;
 end
endtask

// Encode a LOAD word: [1:0]TN [6:2]FN [12:7]MN [18:13]HN [31]STROBE
function [31:0] enc_load;
 input [1:0] tn;
 input [4:0] fn;
 input [5:0] mn;
 input [5:0] hn;
 input strobe;
 begin
 enc_load = {strobe, 12'd0, hn, mn, fn, tn};
 end
endfunction

// Wait for the timebase to commit a pending sync-load. The load is
// committed on the next sym_en edge *after* the resynced strobe pulse
// has propagated. Wait for a handful of sym_en ticks to cover this.
task wait_for_commit;
 integer n;
 integer i;
 input integer dummy; // Verilog-2001 tasks always need at least one arg
 begin
 n = 4;
 for (i = 0; i < n; i = i + 1) begin
 @(posedge sym_en);
 end
 // Plus a few clk cycles for resync pipeline
 repeat (8) @(posedge clk);
 end
endtask

// ---------------------------------------------------------------------------
// Main stimulus
// ---------------------------------------------------------------------------
integer tc;
reg [31:0] rd;
reg [31:0] rd2;
reg [1:0] r_tn;
reg [4:0] r_fn;
reg [5:0] r_mn;
reg [5:0] r_hn;
reg [7:0] r_sc;

initial begin
 // Reset + init
 rst_n = 1'b0;
 awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
 araddr = 0; arvalid = 0; rready = 0;
 repeat (10) @(posedge clk);
 #1 rst_n = 1'b1;
 repeat (4) @(posedge clk);

 // -----------------------------------------------------------------------
 // TC1: after reset, STATE = 0
 // Allow the 2-FF snapshot chain to settle
 // -----------------------------------------------------------------------
 tc = 1;
 repeat (4) @(posedge clk);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 r_tn = rd[1:0]; r_fn = rd[6:2]; r_mn = rd[12:7]; r_hn = rd[18:13];
 r_sc = rd[26:19];
 if (r_tn !== 2'd0 || r_fn !== 5'd0 || r_mn !== 6'd0 || r_hn !== 6'd0 || r_sc !== 8'd0) begin
 $fatal(1, "FAIL TC%0d: post-reset STATE = tn=%0d fn=%0d mn=%0d hn=%0d sc=%0d (expected all 0)",
 tc, r_tn, r_fn, r_mn, r_hn, r_sc);
 end
 $display("PASS TC%0d: post-reset TX_TDMA_STATE = 0", tc);

 // -----------------------------------------------------------------------
 // TC2: write LOAD with STROBE=0 — counters must NOT jump
 // -----------------------------------------------------------------------
 tc = 2;
 axi_write(ADDR_TX_TDMA_LOAD, enc_load(2'd2, 5'd10, 6'd30, 6'd5, 1'b0));
 // Let a few sym_en ticks happen
 repeat (3) @(posedge sym_en);
 repeat (6) @(posedge clk);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 r_tn = rd[1:0]; r_fn = rd[6:2]; r_mn = rd[12:7]; r_hn = rd[18:13];
 if (r_tn !== 2'd0 || r_fn !== 5'd0 || r_mn !== 6'd0 || r_hn !== 6'd0) begin
 $fatal(1, "FAIL TC%0d: STROBE=0 write leaked into counters: tn=%0d fn=%0d mn=%0d hn=%0d",
 tc, r_tn, r_fn, r_mn, r_hn);
 end
 $display("PASS TC%0d: LOAD w/ STROBE=0 does not move counters", tc);

 // -----------------------------------------------------------------------
 // TC3: write LOAD with STROBE=1 — counters commit (TN,FN,MN,HN)
 // -----------------------------------------------------------------------
 tc = 3;
 axi_write(ADDR_TX_TDMA_LOAD, enc_load(2'd2, 5'd10, 6'd30, 6'd5, 1'b1));
 wait_for_commit(0);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 r_tn = rd[1:0]; r_fn = rd[6:2]; r_mn = rd[12:7]; r_hn = rd[18:13];
 if (r_tn !== 2'd2 || r_fn !== 5'd10 || r_mn !== 6'd30 || r_hn !== 6'd5) begin
 $fatal(1, "FAIL TC%0d: STROBE=1 did not commit (tn=%0d fn=%0d mn=%0d hn=%0d, expected 2/10/30/5)",
 tc, r_tn, r_fn, r_mn, r_hn);
 end
 $display("PASS TC%0d: LOAD w/ STROBE=1 commits tn=2 fn=10 mn=30 hn=5", tc);

 // -----------------------------------------------------------------------
 // TC4: second STROBE=1 with different values — overrides
 // -----------------------------------------------------------------------
 tc = 4;
 axi_write(ADDR_TX_TDMA_LOAD, enc_load(2'd1, 5'd17, 6'd59, 6'd63, 1'b1));
 wait_for_commit(0);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 r_tn = rd[1:0]; r_fn = rd[6:2]; r_mn = rd[12:7]; r_hn = rd[18:13];
 if (r_tn !== 2'd1 || r_fn !== 5'd17 || r_mn !== 6'd59 || r_hn !== 6'd63) begin
 $fatal(1, "FAIL TC%0d: second STROBE did not override (tn=%0d fn=%0d mn=%0d hn=%0d, expected 1/17/59/63)",
 tc, r_tn, r_fn, r_mn, r_hn);
 end
 $display("PASS TC%0d: second LOAD overrides counters", tc);

 // -----------------------------------------------------------------------
 // TC5: sym_cnt visibility — after a handful of sym_en the counter
 // is free-running (sym_cnt advances every sym_en).
 // -----------------------------------------------------------------------
 tc = 5;
 // Sample once, then after a few sym_en, require at least one value
 // in the sampled range to be non-zero. (We explicitly start from
 // sym_cnt==0 because commit resets sym_cnt.)
 repeat (3) @(posedge sym_en);
 repeat (6) @(posedge clk);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 r_sc = rd[26:19];
 if (r_sc === 8'dx || r_sc === 8'dz) begin
 $fatal(1, "FAIL TC%0d: sym_cnt has X/Z after sym_en ticks", tc);
 end
 if (r_sc == 8'd0) begin
 $fatal(1, "FAIL TC%0d: sym_cnt still 0 after 3 sym_en ticks (strobe stuck?)", tc);
 end
 $display("PASS TC%0d: sym_cnt free-runs (observed = %0d)", tc, r_sc);

 // -----------------------------------------------------------------------
 // TC6: successive reads during free-run never return X/Z and
 // sym_cnt stays monotonic-non-decreasing intra-slot (wraps
 // at 254→0 when crossing a slot boundary; we avoid wraps by
 // doing reads close together).
 // -----------------------------------------------------------------------
 tc = 6;
 // Take two reads with small gap, verify non-X non-Z and, if no slot
 // boundary crossed, sym_cnt2 >= sym_cnt1 (+ allowed wrap).
 begin: mono_check
 integer i;
 reg [7:0] prev_sc;
 reg [7:0] cur_sc;
 axi_read(ADDR_TX_TDMA_STATE, rd);
 prev_sc = rd[26:19];
 if (prev_sc === 8'dx || prev_sc === 8'dz) begin
 $fatal(1, "FAIL TC%0d: initial read sym_cnt has X/Z", tc);
 end
 for (i = 0; i < 5; i = i + 1) begin
 repeat (2) @(posedge sym_en);
 axi_read(ADDR_TX_TDMA_STATE, rd);
 cur_sc = rd[26:19];
 if (cur_sc === 8'dx || cur_sc === 8'dz) begin
 $fatal(1, "FAIL TC%0d: iter %0d sym_cnt has X/Z", tc, i);
 end
 // Accept either forward motion or a wrap (prev_sc>cur_sc
 // only legal if cur_sc is small after the slot boundary).
 if (cur_sc < prev_sc && prev_sc - cur_sc < 8'd200) begin
 $fatal(1, "FAIL TC%0d: iter %0d non-monotonic sym_cnt: prev=%0d cur=%0d",
 tc, i, prev_sc, cur_sc);
 end
 prev_sc = cur_sc;
 end
 end
 $display("PASS TC%0d: successive STATE reads monotonic + no X/Z", tc);

 // -----------------------------------------------------------------------
 // All passed
 // -----------------------------------------------------------------------
 repeat (4) @(posedge clk);
 $display("=============================================");
 $display("tb_tx_tdma_axi: ALL 6 TCs PASS");
 $display("=============================================");
 $finish;
end

// Watchdog
initial begin
 #2_000_000;
 $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
