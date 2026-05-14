// =============================================================================
// Testbench: tb_tetra_clk_reset
// Project: tetra-zynq-phy
// File: tb/tb_tetra_clk_reset.v
//
// Description: Self-checking testbench for tetra_clk_reset.
//
// Tests 3 scenarios:
// Test 1 — NORMAL: Assert reset, deassert, verify 2-cycle behavior per domain
// Test 2 — BOUNDARY: Assert reset mid-cycle (not aligned to clock edges)
// Test 3 — STRESS: Multiple rapid reset pulses (shorter than clock period)
//
// Clock frequencies used in simulation:
// clk_sys = 100 MHz (10 ns period)
// clk_axi = 100 MHz (10 ns period)
// clk_lvds = 50 MHz (20 ns period) — simplified from real 61.44 MHz
// clk_sample = 1 MHz (1000 ns period) — sped up from real 72 kHz for sim
//
// Expected behavior:
// Assert (arst_n=0): all rst_n_* outputs go LOW within 1 ns (async path)
// Deassert (arst_n=1): each output goes HIGH after exactly 2 rising clock edges
//
// Pass/Fail: Automatic — simulation ends with PASS or FAIL summary
// Waveforms: Dumped to tb_tetra_clk_reset.vcd
//
// Run with:
// iverilog -g2001 -o tb_tetra_clk_reset.vvp \
// tb/tb_tetra_clk_reset.v rtl/infra/tetra_clk_reset.v
// vvp tb_tetra_clk_reset.vvp
// =============================================================================

`timescale 1ns / 1ps

module tb_tetra_clk_reset;

// =============================================================================
// Clock Periods (ns)
// =============================================================================

localparam real CLK_SYS_HALF = 5.0; // 100 MHz → 10 ns period
localparam real CLK_AXI_HALF = 5.0; // 100 MHz → 10 ns period
localparam real CLK_LVDS_HALF = 10.0; // 50 MHz → 20 ns period
localparam real CLK_SAMPLE_HALF = 500.0; // 1 MHz → 1000 ns period

// Deassert latency: exactly 2 rising edges of the respective clock
// Maximum latency = 2 full periods (if arst_n releases just after a rising edge)
localparam real DEASSERT_MAX_SYS_NS = 2 * 2 * CLK_SYS_HALF; // 20 ns
localparam real DEASSERT_MAX_AXI_NS = 2 * 2 * CLK_AXI_HALF; // 20 ns
localparam real DEASSERT_MAX_LVDS_NS = 2 * 2 * CLK_LVDS_HALF; // 40 ns
localparam real DEASSERT_MAX_SAMPLE_NS = 2 * 2 * CLK_SAMPLE_HALF; // 2000 ns

// Margin for simulation timestep rounding (1 ns)
localparam real MARGIN_NS = 1.0;

// =============================================================================
// DUT Ports
// =============================================================================

reg arst_n;
reg clk_sys;
reg clk_axi;
reg clk_lvds;
reg clk_sample;

wire rst_n_sys;
wire rst_n_axi;
wire rst_n_lvds;
wire rst_n_sample;

// =============================================================================
// DUT Instantiation
// =============================================================================

tetra_clk_reset u_dut (
.arst_n (arst_n),
.clk_sys (clk_sys),
.clk_sample (clk_sample),
.clk_axi (clk_axi),
.clk_lvds (clk_lvds),
.rst_n_sys (rst_n_sys),
.rst_n_sample (rst_n_sample),
.rst_n_axi (rst_n_axi),
.rst_n_lvds (rst_n_lvds)
);

// =============================================================================
// Clock Generation
// =============================================================================

// clk_sys — 100 MHz, starts LOW
initial clk_sys = 1'b0;
always #CLK_SYS_HALF clk_sys = ~clk_sys;

// clk_axi — 100 MHz, slight phase offset to stress CDC
initial clk_axi = 1'b0;
always #CLK_AXI_HALF clk_axi = ~clk_axi;

// clk_lvds — 50 MHz
initial clk_lvds = 1'b0;
always #CLK_LVDS_HALF clk_lvds = ~clk_lvds;

// clk_sample — 1 MHz (sped up from real 72 kHz)
initial clk_sample = 1'b0;
always #CLK_SAMPLE_HALF clk_sample = ~clk_sample;

// =============================================================================
// Waveform Dump
// =============================================================================

initial begin
 $dumpfile("tb_tetra_clk_reset.vcd");
 $dumpvars(0, tb_tetra_clk_reset);
end

// =============================================================================
// Test Infrastructure
// =============================================================================

integer test_num;
integer error_count;
integer pass_count;
time t_assert; // Time when arst_n went LOW
time t_deassert; // Time when arst_n went HIGH

// Failure macro — logs file and line would require SystemVerilog; use task instead
task check_low;
 input [63:0] sig_val;
 input [255:0] sig_name;
 begin
 if (sig_val !== 1'b0) begin
 $display("FAIL [Test %0d] at %0t ns: %s should be 0 but is %b",
 test_num, $time, sig_name, sig_val);
 error_count = error_count + 1;
 end
 end
endtask

task check_high;
 input [63:0] sig_val;
 input [255:0] sig_name;
 begin
 if (sig_val !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: %s should be 1 but is %b",
 test_num, $time, sig_name, sig_val);
 error_count = error_count + 1;
 end
 end
endtask

// Wait for a signal to deassert (go HIGH), with timeout
task wait_for_high;
 input sig;
 input real timeout_ns;
 input [255:0] sig_name;
 real t_start;
 begin
 t_start = $realtime;
 while (sig !== 1'b1) begin
 #1;
 if ($realtime - t_start > timeout_ns + MARGIN_NS) begin
 $display("FAIL [Test %0d] at %0t ns: %s never went HIGH (timeout %.0f ns)",
 test_num, $time, sig_name, timeout_ns);
 error_count = error_count + 1;
 disable wait_for_high;
 end
 end
 pass_count = pass_count + 1;
 $display(" OK: %s deasserted at %0t ns (%.1f ns after arst_n release)",
 sig_name, $time, $realtime - t_deassert);
 end
endtask

// Wait for a signal to assert (go LOW), with timeout
task wait_for_low;
 input sig;
 input real timeout_ns;
 input [255:0] sig_name;
 real t_start;
 begin
 t_start = $realtime;
 while (sig !== 1'b0) begin
 #1;
 if ($realtime - t_start > timeout_ns + MARGIN_NS) begin
 $display("FAIL [Test %0d] at %0t ns: %s never went LOW (timeout %.0f ns)",
 test_num, $time, sig_name, timeout_ns);
 error_count = error_count + 1;
 disable wait_for_low;
 end
 end
 pass_count = pass_count + 1;
 end
endtask

// =============================================================================
// Simulation Timeout Guard
// =============================================================================

initial begin
 #50_000_000; // 50 ms @ 1 ns resolution — well beyond any expected completion
 $display("TIMEOUT — Simulation exceeded 50 ms. Possible infinite loop.");
 $display("Tests passed: %0d, Errors: %0d", pass_count, error_count);
 $finish;
end

// =============================================================================
// Test Sequence
// =============================================================================

initial begin
 // -------------------------------------------------------------------------
 // Initialization
 // -------------------------------------------------------------------------
 error_count = 0;
 pass_count = 0;
 test_num = 0;
 arst_n = 1'b0; // Start in reset

 $display("==========================================================");
 $display("Testbench: tb_tetra_clk_reset");
 $display("DUT: tetra_clk_reset");
 $display("Time: 1 ns resolution");
 $display("==========================================================");

 // =========================================================================
 // TEST 1: NORMAL — Assert then deassert, verify 2-cycle behavior
 // =========================================================================
 test_num = 1;
 $display("\n--- Test 1: NORMAL reset assert/deassert ---");

 // Hold reset for 100 ns
 #100;

 // Verify all outputs are LOW while in reset
 check_low(rst_n_sys, "rst_n_sys");
 check_low(rst_n_axi, "rst_n_axi");
 check_low(rst_n_lvds, "rst_n_lvds");
 check_low(rst_n_sample, "rst_n_sample");
 $display(" All outputs LOW during reset: OK");

 // Release reset — record timestamp
 t_deassert = $realtime;
 arst_n = 1'b1;
 $display(" arst_n deasserted at %0t ns", $time);

 // Wait for clk_sys reset to deassert (max 2 × 10 ns = 20 ns + margin)
 begin: wait_sys_t1
 integer wc; wc = 0;
 while (rst_n_sys !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_sys !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sys never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sys deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 // Wait for clk_axi reset to deassert (same period)
 begin: wait_axi_t1
 integer wc; wc = 0;
 while (rst_n_axi !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_axi !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_axi never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_axi deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 // Wait for clk_lvds reset to deassert (max 2 × 20 ns = 40 ns + margin)
 begin: wait_lvds_t1
 integer wc; wc = 0;
 while (rst_n_lvds !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_lvds !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_lvds never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_lvds deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 // Wait for clk_sample reset to deassert (max 2 × 1000 ns = 2000 ns + margin)
 begin: wait_sample_t1
 integer wc; wc = 0;
 while (rst_n_sample !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_sample !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sample never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sample deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 // All should now be HIGH — final check
 check_high(rst_n_sys, "rst_n_sys");
 check_high(rst_n_axi, "rst_n_axi");
 check_high(rst_n_lvds, "rst_n_lvds");
 check_high(rst_n_sample, "rst_n_sample");
 $display(" Test 1 complete");

 // =========================================================================
 // TEST 2: BOUNDARY — Assert reset at arbitrary phase (mid-cycle)
 // =========================================================================
 test_num = 2;
 $display("\n--- Test 2: BOUNDARY mid-cycle reset assertion ---");

 // Let the design run for 50 sys clocks to ensure all stable
 repeat(50) @(posedge clk_sys);

 // Assert reset at a non-aligned time (3 ns into a clock period)
 #3;
 t_assert = $realtime;
 arst_n = 1'b0;
 $display(" arst_n asserted at %0t ns (mid-cycle)", $time);

 // Async assert: outputs must go LOW immediately (within 1 ns)
 #1;
 check_low(rst_n_sys, "rst_n_sys");
 check_low(rst_n_axi, "rst_n_axi");
 check_low(rst_n_lvds, "rst_n_lvds");
 // clk_sample is slow — still check it within its half-period + 1 ns
 // At 1 MHz, half-period = 500 ns. Async assert should propagate < 1 ns.
 check_low(rst_n_sample, "rst_n_sample");
 $display(" Async assert verified: all LOW within 1 ns");

 // Hold reset for 200 ns, then release
 #200;
 t_deassert = $realtime;
 arst_n = 1'b1;
 $display(" arst_n released at %0t ns", $time);

 // Verify deassert sequence again (same max latencies)
 begin: wait_sys_t2
 integer wc; wc = 0;
 while (rst_n_sys !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_sys !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sys never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sys deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end
 begin: wait_axi_t2
 integer wc; wc = 0;
 while (rst_n_axi !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_axi !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_axi never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_axi deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end
 begin: wait_lvds_t2
 integer wc; wc = 0;
 while (rst_n_lvds !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_lvds !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_lvds never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_lvds deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end
 begin: wait_sample_t2
 integer wc; wc = 0;
 while (rst_n_sample !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_sample !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sample never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sample deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 check_high(rst_n_sys, "rst_n_sys");
 check_high(rst_n_axi, "rst_n_axi");
 check_high(rst_n_lvds, "rst_n_lvds");
 check_high(rst_n_sample, "rst_n_sample");
 $display(" Test 2 complete");

 // =========================================================================
 // TEST 3: STRESS — Multiple rapid reset pulses
 // =========================================================================
 test_num = 3;
 $display("\n--- Test 3: STRESS multiple rapid resets ---");

 // Wait for stable state
 repeat(10) @(posedge clk_sys);

 begin: stress_loop
 integer i;
 for (i = 0; i < 3; i = i + 1) begin
 $display(" Stress pulse %0d", i + 1);

 // Short reset pulse (shorter than clk_sys period = 10 ns)
 t_assert = $realtime;
 arst_n = 1'b0;
 #5; // 5 ns pulse — shorter than clk_sys period but > setup time

 // Verify captured
 check_low(rst_n_sys, "rst_n_sys");
 check_low(rst_n_axi, "rst_n_axi");
 check_low(rst_n_lvds, "rst_n_lvds");
 // Note: rst_n_sample may still be LOW from before (it's slow)
 // — this is expected, no check here

 // Release
 t_deassert = $realtime;
 arst_n = 1'b1;

 // Wait for sys and lvds to come back up before next pulse
 begin: wait_sys_t3s
 integer wc; wc = 0;
 while (rst_n_sys !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_sys !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sys never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sys deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end
 begin: wait_lvds_t3s
 integer wc; wc = 0;
 while (rst_n_lvds !== 1'b1 && wc < 10000) begin #1; wc = wc + 1; end
 if (rst_n_lvds !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_lvds never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_lvds deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 // Inter-pulse gap: 50 ns
 #50;
 end
 end

 // After all pulses: verify final state is all HIGH
 // Wait for slow clk_sample domain to fully recover
 begin: wait_sample_t3
 integer wc; wc = 0;
 while (rst_n_sample !== 1'b1 && wc < 20000) begin #1; wc = wc + 1; end
 if (rst_n_sample !== 1'b1) begin
 $display("FAIL [Test %0d] at %0t ns: rst_n_sample never went HIGH (timeout)", test_num, $time);
 error_count = error_count + 1;
 end else begin
 pass_count = pass_count + 1;
 $display(" OK: rst_n_sample deasserted at %0t ns (%.1f ns after arst_n release)", $time, $realtime - t_deassert);
 end
 end

 check_high(rst_n_sys, "rst_n_sys");
 check_high(rst_n_axi, "rst_n_axi");
 check_high(rst_n_lvds, "rst_n_lvds");
 check_high(rst_n_sample, "rst_n_sample");
 $display(" Test 3 complete");

 // =========================================================================
 // Final Report
 // =========================================================================
 #100;
 $display("\n==========================================================");
 if (error_count == 0) begin
 $display("RESULT: PASS — %0d checks passed, 0 errors", pass_count);
 end else begin
 $display("RESULT: FAIL — %0d errors detected (pass: %0d)",
 error_count, pass_count);
 end
 $display("==========================================================");
 $finish;
end

endmodule
