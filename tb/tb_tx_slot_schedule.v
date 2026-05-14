// =============================================================================
// tb_tx_slot_schedule.v — Self-Checking Testbench (Plan Stufe 3)
// DUT: tetra_slot_schedule
// =============================================================================
//
// Exercises the dual-port schedule-BRAM in standalone mode (no AXI bus,
// no TDMA timebase — stimulus drives the DUT ports directly).
//
// Test cases:
// TC1: Reset — schedule_entry_sys = 0 after reset, before any write.
// TC2: AXI write/read bit-pattern integrity. Write 0x12345678 to word 0;
// read it back and check bit-exact match.
// TC3: Sys-side read — write entry at word 0 lower half via AXI, drive
// external dense address on Port B, check the registered output
// one clk later equals the loaded value.
// TC4: Address-translation. Write distinct 16-bit values to four
// addresses corresponding to (mn,fn,tn) = (0,0,0), (0,0,3),
// (3,17,2), (3,17,3); drive each via Port B and check output.
// TC5: -preset sanity — load the full 288-entry blob (regenerated in
// the TB with the same packing as scripts/schedule.py), then
// sweep all (mn%4, fn, tn) and check the entry matches the
// expected pattern.
// TC6: Simultaneous AXI write + sys read to different addresses — both
// succeed (dual-port behaviour).
//
// Latency model being tested (Stufe-4 external-address Port B):
// Port B read: cycle N TB presents sched_b_addr_sys; cycle N+1 DUT
// drives mem[addr]@N onto schedule_entry_sys. The TB
// samples on cycle N+1.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tx_slot_schedule;

// ---------------------------------------------------------------------------
// Clock / Reset
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10; // 10 ns = 100 MHz, single shared clk_axi==clk_sys

reg clk;
reg rst_n;
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// DUT ports
// ---------------------------------------------------------------------------
reg axi_we;
reg [7:0] axi_addr;
reg [31:0] axi_wdata;
reg [3:0] axi_wstrb;
reg axi_re;
wire [31:0] axi_rdata;

reg [8:0] sched_b_addr_sys;
wire [15:0] schedule_entry_sys;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
tetra_slot_schedule u_dut (
.clk_axi (clk),
.rst_n_axi (rst_n),
.axi_we (axi_we),
.axi_addr (axi_addr),
.axi_wdata (axi_wdata),
.axi_wstrb (axi_wstrb),
.axi_re (axi_re),
.axi_rdata (axi_rdata),
.clk_sys (clk),
.rst_n_sys (rst_n),
.sched_b_addr_sys (sched_b_addr_sys),
.schedule_entry_sys (schedule_entry_sys)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
 $dumpfile("sim_out/tb_tx_slot_schedule.vcd");
 $dumpvars(0, tb_tx_slot_schedule);
end

// ---------------------------------------------------------------------------
// Helpers — dense entry-index mapping. Port B dense_idx = mn*72+fn*4+tn;
// AXI word_idx = dense_idx >> 1; halfword = dense_idx[0].
// ---------------------------------------------------------------------------
function [8:0] entry_addr;
 input [1:0] mn;
 input [4:0] fn;
 input [1:0] tn;
 begin
 entry_addr = mn * 9'd72 + {2'b0, fn, 2'b0} + {7'b0, tn};
 end
endfunction

function [7:0] word_idx;
 input [1:0] mn;
 input [4:0] fn;
 input [1:0] tn;
 reg [8:0] ea;
 begin
 ea = entry_addr(mn, fn, tn);
 word_idx = ea[8:1];
 end
endfunction

function is_upper_half;
 input [1:0] mn;
 input [4:0] fn;
 input [1:0] tn;
 reg [8:0] ea;
 begin
 ea = entry_addr(mn, fn, tn);
 is_upper_half = ea[0];
 end
endfunction

// ---------------------------------------------------------------------------
// AXI write: single-cycle pulse. Since the lower/upper halves of a word
// are independent byte-gated writes, this task supports a wstrb argument
// to allow writing only one half.
// ---------------------------------------------------------------------------
task axi_write_word;
 input [7:0] addr;
 input [31:0] data;
 input [3:0] strb;
 begin
 @(posedge clk); #1;
 axi_addr = addr;
 axi_wdata = data;
 axi_wstrb = strb;
 axi_we = 1'b1;
 @(posedge clk); #1;
 axi_we = 1'b0;
 axi_wstrb = 4'h0;
 end
endtask

// Write a single 16-bit entry at (mn, fn, tn) — read the other half
// first, merge in our entry, write full 32-bit word with wstrb = 4'hF.
// For the TB this simpler approach (read-modify-write at the TB level)
// exercises the DUT's halfword wstrb gating less, but TC4 uses direct
// wstrb half-writes to cover that.
reg [31:0] rmw_word;
task axi_write_entry_rmw;
 input [1:0] mn;
 input [4:0] fn;
 input [1:0] tn;
 input [15:0] value;
 reg [7:0] wi;
 reg upper;
 begin
 wi = word_idx(mn, fn, tn);
 upper = is_upper_half(mn, fn, tn);
 // Read-modify-write via the local model array — the DUT side also
 // gets the write below. TB mirror is maintained in exp_mem[].
 if (upper) begin
 rmw_word = {value, exp_mem[{wi, 1'b0}]};
 end else begin
 rmw_word = {exp_mem[{wi, 1'b1}], value};
 end
 axi_write_word(wi, rmw_word, 4'hF);
 exp_mem[entry_addr(mn, fn, tn)] = value;
 end
endtask

// AXI read word — issue axi_re for one cycle; DUT latches and 1 cycle
// later presents the data combinatorially. We sample 2 cycles after.
reg [31:0] rd_captured;
task axi_read_word;
 input [7:0] addr;
 output [31:0] data;
 begin
 @(posedge clk); #1;
 axi_addr = addr;
 axi_re = 1'b1;
 @(posedge clk); #1;
 axi_re = 1'b0;
 // DUT registered on the previous clk edge; axi_rdata is now valid.
 @(posedge clk); #1;
 data = axi_rdata;
 end
endtask

// Sys-side read: drive dense address for 1 cycle; DUT registers
// mem[addr] into schedule_entry_sys on the next clk edge. Sample one
// cycle after presenting the address. (Stufe-4: external address,
// unconditional synchronous read, no tdma_tick/latch pipeline.)
reg [15:0] sys_captured;
task sys_read_entry;
 input [1:0] mn;
 input [4:0] fn;
 input [1:0] tn;
 output [15:0] value;
 begin
 @(posedge clk); #1;
 sched_b_addr_sys = entry_addr(mn, fn, tn);
 // cycle N: address presented; DUT samples on the next posedge.
 @(posedge clk); #1;
 // cycle N+1: schedule_entry_sys reflects mem[addr] now.
 value = schedule_entry_sys;
 end
endtask

// ---------------------------------------------------------------------------
// TB reference model of the schedule memory (288 dense entries).
// ---------------------------------------------------------------------------
reg [15:0] exp_mem [0:287];

integer init_i;
initial begin
 for (init_i = 0; init_i < 288; init_i = init_i + 1)
 exp_mem[init_i] = 16'h0000;
end

// ---------------------------------------------------------------------------
// preset generator — matches scripts/schedule.py
// gen_schedule_blob() entry layout. Internal FN is 0-based (0..17);
// plan §4 "FN=18" = internal fn=17.
//
// Entry layout (16 bit):
// [15:12] payload_class (0=STATIC_BROADCAST, 1=NULL_PDU, 2=TCH)
// [11:6] payload_idx (6 bit)
// [5:4] burst_type (00=NDB, 01=SDB, 11=idle)
// [3] ndb2
// [2] enable
// [1] sys_time_inject
// [0] reserved
//
// preset mapping (plan §4 Stufe 3):
// TN=1,2,3 — all entries: SDB, sys_time_inject=1, class=BROADCAST,
// idx=SB (3), burst_type=01, ndb2=0, enable=1
// TN=0:
// fn=17 & mn%4==2 → SDB sys_time_inject=1 (same as TN=1..3)
// fn=17 & mn%4!=2 → MCCH: class=BROADCAST idx=1, burst_type=01,
// enable=1, sys_time_inject=0
// fn<17 → NDB2 NULL-PDU: class=NULL_PDU idx=0, burst_type=00,
// ndb2=1, enable=1, sys_time_inject=0
// (cell bit-exact:
// BKN1 = NULL-PDU 0x0010_8000… SCH/HD slot=1
// BKN2 = BNCH-SYSINFO SCH/HD slot=0
// Content-mux routes blk1=null_pdu_bits_sys,
// blk2=ndb_block2_sw_sys.)
// ---------------------------------------------------------------------------
function [15:0] ref_entry;
 input [1:0] mn; // mn%4 bucket 0..3
 input [4:0] fn; // 0..17 (internal 0-based)
 input [1:0] tn; // 0..3
 reg [3:0] cls;
 reg [5:0] idx;
 reg [1:0] bt;
 reg ndb2;
 reg en;
 reg sti;
 reg rsv;
 begin
 cls = 4'd0;
 idx = 6'd0;
 bt = 2'b00;
 ndb2 = 1'b0;
 en = 1'b1;
 sti = 1'b0;
 rsv = 1'b0;
 if (tn != 2'd0) begin
 // TN=1,2,3 — always SDB sys_time_inject
 cls = 4'd0; // STATIC_BROADCAST
 idx = 6'd3; // SB
 bt = 2'b01; // SDB
 ndb2 = 1'b0;
 en = 1'b1;
 sti = 1'b1;
 end else begin
 // TN=0 branch
 if (fn == 5'd17 && mn == 2'd2) begin
 cls = 4'd0; idx = 6'd3; bt = 2'b01;
 ndb2 = 1'b0; en = 1'b1; sti = 1'b1;
 end else if (fn == 5'd17) begin
 cls = 4'd0; idx = 6'd1; bt = 2'b01;
 ndb2 = 1'b0; en = 1'b1; sti = 1'b0;
 end else begin
 cls = 4'd1; idx = 6'd0; bt = 2'b00;
 ndb2 = 1'b1; en = 1'b1; sti = 1'b0;
 end
 end
 ref_entry = {cls, idx, bt, ndb2, en, sti, rsv};
 end
endfunction

// ---------------------------------------------------------------------------
// Main stimulus
// ---------------------------------------------------------------------------
integer pass_cnt;
integer fail_cnt;
integer i_mn, i_fn, i_tn;
reg [31:0] rd32;
reg [15:0] rd16;
reg [15:0] ref_v;

initial begin
 // Defaults
 axi_we = 1'b0;
 axi_addr = 8'h00;
 axi_wdata = 32'h0;
 axi_wstrb = 4'h0;
 axi_re = 1'b0;
 sched_b_addr_sys = 9'd0;

 pass_cnt = 0;
 fail_cnt = 0;

 rst_n = 1'b0;
 repeat (10) @(posedge clk);
 #1 rst_n = 1'b1;
 repeat (4) @(posedge clk);

 // -----------------------------------------------------------------------
 // TC1: After zero-init via AXI writes, sys read returns 0.
 // (Physical BRAM is uninitialized — power-on X-state is
 // expected; SW must zero-init before use, per plan §4.)
 // -----------------------------------------------------------------------
 begin: tc1_zero_init
 integer j;
 for (j = 0; j < 144; j = j + 1) begin
 axi_write_word(j[7:0], 32'h0000_0000, 4'hF);
 end
 end
 sys_read_entry(2'd0, 5'd0, 2'd0, rd16);
 if (rd16 !== 16'h0000) begin
 $display("FAIL TC1: post-zero-init sys read = %h (expected 0)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC1: post-zero-init sys read = 0x%h", rd16);
 pass_cnt = pass_cnt + 1;
 end

 // -----------------------------------------------------------------------
 // TC2: AXI write 0x12345678 to word 0, read back
 // -----------------------------------------------------------------------
 axi_write_word(8'h00, 32'h1234_5678, 4'hF);
 exp_mem[0] = 16'h5678;
 exp_mem[1] = 16'h1234;
 axi_read_word(8'h00, rd32);
 if (rd32 !== 32'h1234_5678) begin
 $display("FAIL TC2: readback = %h (expected 0x12345678)", rd32);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC2: AXI write/read bit-integrity (0x%h)", rd32);
 pass_cnt = pass_cnt + 1;
 end

 // -----------------------------------------------------------------------
 // TC3: sys-side read of (0,0,0) returns the lower-half value written
 // in TC2. Entry (mn=0,fn=0,tn=0) = {00,00000,00} = addr 0 = lower
 // half of word 0 = 0x5678.
 // -----------------------------------------------------------------------
 sys_read_entry(2'd0, 5'd0, 2'd0, rd16);
 if (rd16 !== 16'h5678) begin
 $display("FAIL TC3: sys read (0,0,0) = %h (expected 0x5678)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC3: sys-side read reflects AXI write (0x%h)", rd16);
 pass_cnt = pass_cnt + 1;
 end

 // Quick follow-up: sys read (0,0,1) reflects upper half 0x1234
 sys_read_entry(2'd0, 5'd0, 2'd1, rd16);
 if (rd16 !== 16'h1234) begin
 $display("FAIL TC3b: sys read (0,0,1) = %h (expected 0x1234)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC3b: sys-side read upper half (0x%h)", rd16);
 pass_cnt = pass_cnt + 1;
 end

 // -----------------------------------------------------------------------
 // TC4: address-translation — 4 distinct entries at corner addresses
 // (0,0,0), (0,0,3), (3,17,2), (3,17,3). Use halfword wstrb
 // to write just one half of the containing word so we exercise
 // the wstrb[1:0] / wstrb[3:2] gating.
 // -----------------------------------------------------------------------
 // (0,0,0) — entry 0, word 0 lower half — write 0xAAAA via wstrb 4'h3
 axi_write_word(word_idx(2'd0, 5'd0, 2'd0),
 {16'h0000, 16'hAAAA}, 4'h3);
 exp_mem[entry_addr(2'd0, 5'd0, 2'd0)] = 16'hAAAA;

 // (0,0,3) — entry 3, word 1 upper half — write 0xBBBB via wstrb 4'hC
 axi_write_word(word_idx(2'd0, 5'd0, 2'd3),
 {16'hBBBB, 16'h0000}, 4'hC);
 exp_mem[entry_addr(2'd0, 5'd0, 2'd3)] = 16'hBBBB;

 // (3,17,2) — entry = {11,10001,10} = 9'b11_10001_10 = 226 = word 113 lower
 axi_write_word(word_idx(2'd3, 5'd17, 2'd2),
 {16'h0000, 16'hCCCC}, 4'h3);
 exp_mem[entry_addr(2'd3, 5'd17, 2'd2)] = 16'hCCCC;

 // (3,17,3) — entry 227 = word 113 upper
 axi_write_word(word_idx(2'd3, 5'd17, 2'd3),
 {16'hDDDD, 16'h0000}, 4'hC);
 exp_mem[entry_addr(2'd3, 5'd17, 2'd3)] = 16'hDDDD;

 sys_read_entry(2'd0, 5'd0, 2'd0, rd16);
 if (rd16 !== 16'hAAAA) begin
 $display("FAIL TC4a: (0,0,0) = %h (expected 0xAAAA)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC4a: (0,0,0) = 0x%h", rd16);
 pass_cnt = pass_cnt + 1;
 end

 sys_read_entry(2'd0, 5'd0, 2'd3, rd16);
 if (rd16 !== 16'hBBBB) begin
 $display("FAIL TC4b: (0,0,3) = %h (expected 0xBBBB)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC4b: (0,0,3) = 0x%h", rd16);
 pass_cnt = pass_cnt + 1;
 end

 sys_read_entry(2'd3, 5'd17, 2'd2, rd16);
 if (rd16 !== 16'hCCCC) begin
 $display("FAIL TC4c: (3,17,2) = %h (expected 0xCCCC)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC4c: (3,17,2) = 0x%h", rd16);
 pass_cnt = pass_cnt + 1;
 end

 sys_read_entry(2'd3, 5'd17, 2'd3, rd16);
 if (rd16 !== 16'hDDDD) begin
 $display("FAIL TC4d: (3,17,3) = %h (expected 0xDDDD)", rd16);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC4d: (3,17,3) = 0x%h", rd16);
 pass_cnt = pass_cnt + 1;
 end

 // -----------------------------------------------------------------------
 // TC5: -preset — write all 288 entries via AXI word writes,
 // then sweep all (mn%4, fn, tn) and check.
 //
 // Dense mapping: dense_idx = mn*72 + fn*4 + tn. Word word_idx
 // packs entries (2*word_idx, 2*word_idx+1) as (lower, upper).
 // So word_idx = dense_idx >> 1 and the halfword is chosen by
 // dense_idx[0]. Iterate word_idx 0..143 and reverse the map
 // to get the (mn, fn, tn)_even / _odd entries.
 // -----------------------------------------------------------------------
 begin: preset_load
 integer mn_e, fn_e, tn_e;
 integer mn_o, fn_o, tn_o;
 reg [15:0] v_even;
 reg [15:0] v_odd;
 reg [8:0] ea_even;
 reg [8:0] ea_odd;
 integer wi;
 for (wi = 0; wi < 144; wi = wi + 1) begin
 ea_even = (wi << 1);
 ea_odd = (wi << 1) + 9'd1;
 // Invert the dense mapping. ea = mn*72 + fn*4 + tn with
 // mn in 0..3, fn in 0..17, tn in 0..3.
 mn_e = ea_even / 72;
 fn_e = (ea_even - mn_e * 72) / 4;
 tn_e = ea_even - mn_e * 72 - fn_e * 4;
 mn_o = ea_odd / 72;
 fn_o = (ea_odd - mn_o * 72) / 4;
 tn_o = ea_odd - mn_o * 72 - fn_o * 4;
 v_even = ref_entry(mn_e[1:0], fn_e[4:0], tn_e[1:0]);
 v_odd = ref_entry(mn_o[1:0], fn_o[4:0], tn_o[1:0]);
 axi_write_word(wi[7:0], {v_odd, v_even}, 4'hF);
 exp_mem[ea_even] = v_even;
 exp_mem[ea_odd] = v_odd;
 end
 end

 // Verify all 288 active (mn%4, fn, tn) entries via Port B
 begin: sweep
 integer mis;
 mis = 0;
 for (i_mn = 0; i_mn < 4; i_mn = i_mn + 1) begin
 for (i_fn = 0; i_fn < 18; i_fn = i_fn + 1) begin
 for (i_tn = 0; i_tn < 4; i_tn = i_tn + 1) begin
 sys_read_entry(i_mn[1:0], i_fn[4:0], i_tn[1:0], rd16);
 ref_v = ref_entry(i_mn[1:0], i_fn[4:0], i_tn[1:0]);
 if (rd16 !== ref_v) begin
 if (mis < 5) begin
 $display(" TC5 mismatch at (mn=%0d,fn=%0d,tn=%0d): got %h exp %h",
 i_mn, i_fn, i_tn, rd16, ref_v);
 end
 mis = mis + 1;
 end
 end
 end
 end
 if (mis != 0) begin
 $display("FAIL TC5: preset %0d / 288 entries mismatch", mis);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC5: preset — all 288 entries match");
 pass_cnt = pass_cnt + 1;
 end
 end

 // -----------------------------------------------------------------------
 // TC6: Simultaneous AXI write + sys read to different addresses.
 // Drive them on the same clk edge; verify:
 // - the sys-read gets the old value at its address
 // - the AXI write lands at its distinct address (re-read after)
 // -----------------------------------------------------------------------
 begin: tc6
 reg [15:0] before_v;
 reg [15:0] after_v;
 reg [15:0] write_v;
 reg [7:0] wi_tgt;
 // Pick a distinct entry (mn=1, fn=5, tn=2) — entry addr 1_00101_10 = 74.
 // Will read (mn=0, fn=0, tn=0) at the same time (entry 0).
 write_v = 16'hFEED;
 wi_tgt = word_idx(2'd1, 5'd5, 2'd2);
 // Current exp_mem[entry_addr(0,0,0)] was set by TC4a to 0xAAAA,
 // but TC5 overwrote it with ref_entry(0,0,0). Recompute:
 before_v = ref_entry(2'd0, 5'd0, 2'd0);

 @(posedge clk); #1;
 // Fire both actions this cycle
 axi_addr = wi_tgt;
 axi_wdata = {16'h0000, write_v}; // lower half
 axi_wstrb = 4'h3;
 axi_we = 1'b1;
 sched_b_addr_sys = entry_addr(2'd0, 5'd0, 2'd0);
 @(posedge clk); #1;
 axi_we = 1'b0;
 axi_wstrb = 4'h0;
 // schedule_entry_sys now holds the read for (0,0,0)
 after_v = schedule_entry_sys;

 // Now re-read the freshly written entry via Port B
 exp_mem[entry_addr(2'd1, 5'd5, 2'd2)] = write_v;
 sys_read_entry(2'd1, 5'd5, 2'd2, rd16);

 if (after_v !== before_v) begin
 $display("FAIL TC6a: concurrent sys-read got %h exp %h",
 after_v, before_v);
 fail_cnt = fail_cnt + 1;
 end else if (rd16 !== write_v) begin
 $display("FAIL TC6b: concurrent-write readback = %h exp %h",
 rd16, write_v);
 fail_cnt = fail_cnt + 1;
 end else begin
 $display("PASS TC6: dual-port write + read independent");
 pass_cnt = pass_cnt + 1;
 end
 end

 // -----------------------------------------------------------------------
 // Summary
 // -----------------------------------------------------------------------
 repeat (4) @(posedge clk);
 $display("=============================================");
 if (fail_cnt == 0) begin
 $display("tb_tx_slot_schedule: ALL TESTS PASSED (%0d pass, %0d fail)",
 pass_cnt, fail_cnt);
 end else begin
 $display("tb_tx_slot_schedule: FAILURES (%0d pass, %0d fail)",
 pass_cnt, fail_cnt);
 end
 $display("=============================================");
 if (fail_cnt != 0) $fatal(1, "TB failure count = %0d", fail_cnt);
 $finish;
end

// Watchdog
initial begin
 #5_000_000;
 $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
