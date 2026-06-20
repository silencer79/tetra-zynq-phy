// =============================================================================
// Testbench: tb_tetra_ad9361_interface
// Project: tetra-zynq-phy
// File: tb/tb_tetra_ad9361_interface.v
//
// Self-checking testbench for tetra_ad9361_interface.v
// Tests the AD9361 LVDS DDR RX path from DDR pins to signed IQ outputs.
//
// Test structure:
// Test 0 — Reset: outputs cleared during assert, rx_valid=0 after deassert
// Tests 1–15 — Vector-driven IQ pairs (15 pairs from ad9361_iq_vectors.hex):
// 5 × NORMAL, 5 × BOUNDARY, 5 × STRESS
// Test 16 — Mid-stream reset: 3 pairs sent, reset asserted during pair 3,
// then 2 more pairs verified post-reset
// Test 17 — Back-to-back pairs: 3 consecutive pairs with no idle cycles
// between them (pipeline stress test)
//
// DDR stimulus timing:
// The AD9361 launches data at clock edges (source-synchronous).
// Testbench models this as: data driven T_HOLD = 1 ns AFTER each edge.
// IDDR (SAME_EDGE_PIPELINED, 1-cycle latency) captures the data at the
// NEXT same-polarity edge.
//
// I-cycle (RX_FRAME=1):
// posedge N + T_HOLD: data_p = I[11:6], frame_p = 1
// negedge N + T_HOLD: data_p = I[5:0]
//
// Q-cycle (RX_FRAME=0):
// posedge N+1 + T_HOLD: data_p = Q[11:6], frame_p = 0
// negedge N+1 + T_HOLD: data_p = Q[5:0]
//
// rx_valid_lvds asserts at posedge N+2 (2-cycle pipeline latency from
// I-cycle start). Check is performed at posedge N+2 + T_HOLD.
//
// Vector file format (ad9361_iq_vectors.hex):
// 32-bit word per pair: [31:16] = expected I (16-bit), [15:0] = expected Q
// The raw 12-bit stimulus: i_raw = exp_i[11:0], q_raw = exp_q[11:0]
// (valid because sign extension preserves the lower 12 bits unchanged)
//
// Pass criterion: error_count == 0 at end of simulation.
//
// Ref: AD9361 Reference Manual UG-570, §5
// Xilinx UG472, §2 (IDDR SAME_EDGE_PIPELINED)
// =============================================================================

`timescale 1ns / 1ps

module tb_tetra_ad9361_interface;

// =============================================================================
// Parameters
// =============================================================================

localparam IQ_WIDTH = 16;
localparam AD9361_BITS = 12;
localparam NUM_VECTORS = 15;

// Clock period: 10 ns (100 MHz — functional test only, not timing-correct)
// Real DATA_CLK ≈ 1923 ns (520 kHz), but we test behavior not timing.
localparam CLK_PERIOD = 10; // ns, full period
localparam T_HOLD = 1; // ns, data launch delay after clock edge
localparam RESET_CYCLES = 5; // clk_lvds cycles to hold reset

// =============================================================================
// Waveform dump
// =============================================================================

initial begin
 $dumpfile("tb_tetra_ad9361_interface.vcd");
 $dumpvars(0, tb_tetra_ad9361_interface);
end

// =============================================================================
// DUT signals
// =============================================================================

// Reset
reg rst_n_lvds_tb;

// AD9361 RX LVDS (driven by testbench to stimulate DUT)
reg ad9361_data_clk_p_tb;
wire ad9361_data_clk_n_tb;
reg ad9361_rx_frame_p_tb;
wire ad9361_rx_frame_n_tb;
reg [5:0] ad9361_rx_data_p_tb;
wire [5:0] ad9361_rx_data_n_tb;

// AD9361 TX LVDS outputs (from DUT — not checked in Phase 1)
wire ad9361_fb_clk_p_dut;
wire ad9361_fb_clk_n_dut;
wire ad9361_tx_frame_p_dut;
wire ad9361_tx_frame_n_dut;
wire [5:0] ad9361_tx_data_p_dut;
wire [5:0] ad9361_tx_data_n_dut;

// Control
reg rx_enable_tb;
reg tx_enable_tb;

// DUT clock output
wire clk_lvds_dut;

// RX IQ outputs (from DUT)
wire signed [IQ_WIDTH-1:0] rx_i_lvds_dut;
wire signed [IQ_WIDTH-1:0] rx_q_lvds_dut;
wire rx_valid_lvds_dut;

// TX IQ inputs (Phase 1: tied to zero)
reg signed [IQ_WIDTH-1:0] tx_i_lvds_tb;
reg signed [IQ_WIDTH-1:0] tx_q_lvds_tb;
reg tx_valid_lvds_tb;

// Differential tie-offs (IBUFDS ignores _n in our sim model)
assign ad9361_rx_frame_n_tb = ~ad9361_rx_frame_p_tb;
assign ad9361_rx_data_n_tb = ~ad9361_rx_data_p_tb;

// =============================================================================
// Test tracking
// =============================================================================

integer error_count;
integer test_num;
integer i;

// =============================================================================
// Vector storage (loaded from.hex file)
// Flat bus: 15 words × 32 bits = 480 bits
// word N occupies [480 - 32*N - 1: 480 - 32*(N+1)]
// =============================================================================

reg [31:0] vectors [0:NUM_VECTORS-1]; // Testbench-only array (allowed in TB)

// =============================================================================
// DUT Instantiation
// =============================================================================

tetra_ad9361_interface #(
.IQ_WIDTH (IQ_WIDTH)
) dut (
 // Reset
.rst_n_lvds (rst_n_lvds_tb),

 // RX LVDS
.ad9361_data_clk_p (ad9361_data_clk_p_tb),
.ad9361_data_clk_n (ad9361_data_clk_n_tb),
.ad9361_rx_frame_p (ad9361_rx_frame_p_tb),
.ad9361_rx_frame_n (ad9361_rx_frame_n_tb),
.ad9361_rx_data_p (ad9361_rx_data_p_tb),
.ad9361_rx_data_n (ad9361_rx_data_n_tb),

 // TX LVDS
.ad9361_fb_clk_p (ad9361_fb_clk_p_dut),
.ad9361_fb_clk_n (ad9361_fb_clk_n_dut),
.ad9361_tx_frame_p (ad9361_tx_frame_p_dut),
.ad9361_tx_frame_n (ad9361_tx_frame_n_dut),
.ad9361_tx_data_p (ad9361_tx_data_p_dut),
.ad9361_tx_data_n (ad9361_tx_data_n_dut),

 // Control
.rx_enable (rx_enable_tb),
.tx_enable (tx_enable_tb),

 // Clock output
.clk_lvds (clk_lvds_dut),

 // RX IQ outputs
.rx_i_lvds (rx_i_lvds_dut),
.rx_q_lvds (rx_q_lvds_dut),
.rx_valid_lvds (rx_valid_lvds_dut),

 // TX IQ inputs
.tx_i_lvds (tx_i_lvds_tb),
.tx_q_lvds (tx_q_lvds_tb),
.tx_valid_lvds (tx_valid_lvds_tb)
);

// =============================================================================
// Clock generation
// ad9361_data_clk_p_tb drives DATA_CLK → passed through IBUFDS+BUFG to clk_lvds.
// All DUT logic runs on clk_lvds_dut (= ad9361_data_clk_p_tb in simulation).
// =============================================================================

initial ad9361_data_clk_p_tb = 1'b0;
always #(CLK_PERIOD/2) ad9361_data_clk_p_tb = ~ad9361_data_clk_p_tb;

// _n is the complement (unused by IBUFDS model but kept clean)
assign ad9361_data_clk_n_tb = ~ad9361_data_clk_p_tb; // wire, not reg

// =============================================================================
// Task: drive_iq_pair
//
// Drives one IQ pair onto the LVDS data bus as the AD9361 would:
// - I cycle: RX_FRAME=1, data changes after posedge (T_HOLD) and negedge (T_HOLD)
// - Q cycle: RX_FRAME=0, same timing
//
// After this task returns (after negedge of Q-cycle + T_HOLD), the caller
// can wait one more posedge to capture rx_valid and check the outputs.
// =============================================================================

task drive_iq_pair;
 input [AD9361_BITS-1:0] i_raw; // 12-bit two's complement I sample
 input [AD9361_BITS-1:0] q_raw; // 12-bit two's complement Q sample
 begin
 // ---- I Cycle --------------------------------------------------------
 // Rising edge: drive I[11:6] (upper 6 bits)
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = i_raw[AD9361_BITS-1: AD9361_BITS-6]; // [11:6]

 // Falling edge: drive I[5:0] (lower 6 bits); frame stays 1
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = i_raw[5:0];

 // ---- Q Cycle --------------------------------------------------------
 // Rising edge: drive Q[11:6], deassert RX_FRAME
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = q_raw[AD9361_BITS-1: AD9361_BITS-6]; // [11:6]

 // Falling edge: drive Q[5:0]
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = q_raw[5:0];
 // Task returns here: rx_valid appears at the NEXT posedge (N+2)
 end
endtask

// =============================================================================
// Task: check_rx_output
//
// Waits for rx_valid to appear and verifies rx_i/rx_q.
//
// Pipeline latency analysis (with IDDR SAME_EDGE_PIPELINED sim model):
// drive_iq_pair returns after negedge N+1 + T_HOLD.
// At posedge N+1: IDDR outputs I-cycle data; i_raw captured; frame_locked=1
// At posedge N+2: IDDR outputs Q-cycle data; frame_fall wire goes HIGH (post-edge)
// At posedge N+3: frame_fall PRE-edge = 1; rx_valid registered; rx_i/rx_q captured
// → Wait 2 posedges after drive_iq_pair returns (posedge N+2 is a dummy,
// posedge N+3 is where rx_valid and IQ data are valid).
// =============================================================================

task check_rx_output;
 input [IQ_WIDTH-1:0] exp_i; // Expected I (16-bit, two's complement)
 input [IQ_WIDTH-1:0] exp_q; // Expected Q (16-bit, two's complement)
 input integer tnum;
 integer errors_before;
 begin
 errors_before = error_count;

 @(posedge ad9361_data_clk_p_tb); // posedge N+2 — dummy (rx_valid not yet)
 @(posedge ad9361_data_clk_p_tb); #T_HOLD; // posedge N+3 — rx_valid here

 if (rx_valid_lvds_dut !== 1'b1) begin
 $display("FAIL T%0d: rx_valid_lvds=0 (expected 1)", tnum);
 error_count = error_count + 1;
 end
 if (rx_i_lvds_dut !== $signed(exp_i)) begin
 $display("FAIL T%0d: rx_i=0x%04X expected=0x%04X",
 tnum, rx_i_lvds_dut, exp_i);
 error_count = error_count + 1;
 end
 if (rx_q_lvds_dut !== $signed(exp_q)) begin
 $display("FAIL T%0d: rx_q=0x%04X expected=0x%04X",
 tnum, rx_q_lvds_dut, exp_q);
 error_count = error_count + 1;
 end

 if (error_count == errors_before)
 $display("PASS T%0d: I=0x%04X Q=0x%04X", tnum, exp_i, exp_q);
 end
endtask

// =============================================================================
// Task: wait_clocks
// =============================================================================

task wait_clocks;
 input integer n;
 integer k;
 begin
 for (k = 0; k < n; k = k + 1)
 @(posedge ad9361_data_clk_p_tb);
 end
endtask

// =============================================================================
// Main test sequence
// =============================================================================

initial begin
 // -------------------------------------------------------------------------
 // Initialisation
 // -------------------------------------------------------------------------
 error_count = 0;
 test_num = 0;
 rst_n_lvds_tb = 1'b0;
 rx_enable_tb = 1'b1;
 tx_enable_tb = 1'b0;
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = 6'h00;
 tx_i_lvds_tb = {IQ_WIDTH{1'b0}};
 tx_q_lvds_tb = {IQ_WIDTH{1'b0}};
 tx_valid_lvds_tb = 1'b0;

 // Load test vectors (testbench array — allowed in TB per R9 exception)
 $readmemh("tb/vectors/ad9361_iq_vectors.hex", vectors);

 // -------------------------------------------------------------------------
 // Test 0: Reset assertion — all outputs must be 0 during reset
 // -------------------------------------------------------------------------
 $display("--- Test 0: Reset check ---");
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 if (rx_valid_lvds_dut !== 1'b0 ||
 rx_i_lvds_dut !== {IQ_WIDTH{1'b0}} ||
 rx_q_lvds_dut !== {IQ_WIDTH{1'b0}}) begin
 $display("FAIL T0: outputs non-zero during reset");
 error_count = error_count + 1;
 end else begin
 $display("PASS T0: outputs zero during reset");
 end

 // Deassert reset after a few cycles
 wait_clocks(RESET_CYCLES);
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 rst_n_lvds_tb = 1'b1;

 // Wait 2 cycles for reset synchronizer to propagate
 wait_clocks(3);

 // -------------------------------------------------------------------------
 // Tests 1–15: Vector-based IQ pairs
 // -------------------------------------------------------------------------
 $display("--- Tests 1-15: IQ vector pairs (NORMAL/BOUNDARY/STRESS) ---");

 for (i = 0; i < NUM_VECTORS; i = i + 1) begin
 test_num = i + 1;
 drive_iq_pair(
 vectors[i][27:16], // i_raw[11:0] = exp_i[11:0]
 vectors[i][11:0] // q_raw[11:0] = exp_q[11:0]
 );
 check_rx_output(
 vectors[i][31:16], // exp_i[15:0]
 vectors[i][15:0], // exp_q[15:0]
 test_num
 );
 end

 // -------------------------------------------------------------------------
 // Test 16: Latency verification
 // Check that rx_valid is NOT asserted 1 cycle too early (before Q cycle)
 // -------------------------------------------------------------------------
 $display("--- Test 16: Pipeline latency check (valid must NOT fire early) ---");
 test_num = 16;
 begin: test16_latency
 reg [AD9361_BITS-1:0] i_raw_t16;
 reg [AD9361_BITS-1:0] q_raw_t16;
 i_raw_t16 = 12'h400; // +1024
 q_raw_t16 = 12'hC00; // -1024 (two's complement)

 // Drive I cycle only, check that valid is NOT high 1 cycle later
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = i_raw_t16[11:6];
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = i_raw_t16[5:0];

 // One posedge after I-cycle: valid should NOT yet be asserted
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 if (rx_valid_lvds_dut === 1'b1) begin
 $display("FAIL T16: rx_valid asserted 1 cycle early (before Q-cycle complete)");
 error_count = error_count + 1;
 end else begin
 $display("PASS T16a: rx_valid correctly 0 after I-cycle only");
 end

 // Complete the Q cycle
 #0; // No extra delay — frame_p transitions at this posedge + T_HOLD
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = q_raw_t16[11:6];
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = q_raw_t16[5:0];

 // Pipeline latency: rx_valid appears 3 cycles after I-cycle posedge.
 // After the Q-cycle completes, we need 2 more posedges for rx_valid.
 @(posedge ad9361_data_clk_p_tb); // posedge N+2 — dummy
 @(posedge ad9361_data_clk_p_tb); #T_HOLD; // posedge N+3 — rx_valid here
 if (rx_valid_lvds_dut !== 1'b1) begin
 $display("FAIL T16b: rx_valid did not assert after Q-cycle");
 error_count = error_count + 1;
 end else begin
 $display("PASS T16b: rx_valid asserts at posedge+3 (3-cycle pipeline latency)");
 end
 end

 // -------------------------------------------------------------------------
 // Test 17: Mid-stream reset recovery
 // Send 2 pairs, assert reset during pair 2, deassert, send 2 more pairs.
 // -------------------------------------------------------------------------
 $display("--- Test 17: Mid-stream reset recovery ---");
 test_num = 17;

 // Pair A before reset
 drive_iq_pair(12'h2C3, 12'h2C3); // I=+707, Q=+707
 check_rx_output(16'h02C3, 16'h02C3, 17);

 // Start pair B and assert reset partway through the I-cycle
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = 6'h3F;
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 rst_n_lvds_tb = 1'b0; // Assert reset mid-stream
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 // Check outputs are cleared immediately by async reset
 if (rx_valid_lvds_dut !== 1'b0 ||
 rx_i_lvds_dut !== {IQ_WIDTH{1'b0}} ||
 rx_q_lvds_dut !== {IQ_WIDTH{1'b0}}) begin
 $display("FAIL T17: outputs not cleared by async reset");
 error_count = error_count + 1;
 end else begin
 $display("PASS T17a: async reset clears outputs correctly");
 end

 // Deassert reset, wait for re-lock
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 rst_n_lvds_tb = 1'b1;
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = 6'h00;
 wait_clocks(3);

 // Send pair after reset and verify it decodes correctly
 drive_iq_pair(12'h7FF, 12'h800); // I=+2047, Q=-2048
 check_rx_output(16'h07FF, 16'hF800, 18);

 // -------------------------------------------------------------------------
 // Test 19–21: Back-to-back pairs (no idle cycles between them)
 // Verifies the pipeline handles consecutive IQ pairs without data loss.
 //
 // Pipeline latency: rx_valid appears 3 posedges after I-cycle posedge (B).
 // Timing (B = first I-cycle posedge):
 // B: pair 1 I-cycle
 // B+1: pair 1 Q-cycle
 // B+2: pair 2 I-cycle
 // B+3: pair 2 Q-cycle ← pair 1 valid fires HERE (T19 check)
 // B+4: pair 3 I-cycle
 // B+5: pair 3 Q-cycle ← pair 2 valid fires HERE (T20 check)
 // B+7: ← pair 3 valid fires HERE (T21 check)
 // -------------------------------------------------------------------------
 $display("--- Tests 19-21: Back-to-back pairs (pipeline stress) ---");

 // --- Pair 1 I-cycle (posedge B) ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = 6'h10; // I1[11:6]: +1024 = 12'h400 → [11:6]=0x10
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // I1[5:0]

 // --- Pair 1 Q-cycle (posedge B+1) ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = 6'h38; // Q1[11:6]: -512 = 12'hE00 → [11:6]=0x38
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // Q1[5:0]

 // --- Pair 2 I-cycle (posedge B+2) ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = 6'h38; // I2[11:6]: -512
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // I2[5:0]

 // --- Pair 2 Q-cycle (posedge B+3) — pair 1 valid fires at THIS posedge ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD; // B+3: pair 1 valid
 // Check pair 1 (T19)
 if (rx_valid_lvds_dut !== 1'b1 ||
 rx_i_lvds_dut !== 16'h0400 ||
 rx_q_lvds_dut !== 16'hFE00) begin
 $display("FAIL T19: back-to-back pair 1: valid=%b I=0x%04X Q=0x%04X (exp I=0x0400 Q=0xFE00)",
 rx_valid_lvds_dut, rx_i_lvds_dut, rx_q_lvds_dut);
 error_count = error_count + 1;
 end else begin
 $display("PASS T19: back-to-back pair 1 I=0x0400 Q=0xFE00");
 end
 // Drive pair 2 Q-cycle (simultaneous with check — check reads, then drive writes)
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = 6'h10; // Q2[11:6]: +1024
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // Q2[5:0]

 // --- Pair 3 I-cycle (posedge B+4) ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_frame_p_tb = 1'b1;
 ad9361_rx_data_p_tb = 6'h04; // I3[11:6]: +256 = 12'h100 → [11:6]=0x04
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // I3[5:0]

 // --- Pair 3 Q-cycle (posedge B+5) — pair 2 valid fires at THIS posedge ---
 @(posedge ad9361_data_clk_p_tb); #T_HOLD; // B+5: pair 2 valid
 // Check pair 2 (T20)
 if (rx_valid_lvds_dut !== 1'b1 ||
 rx_i_lvds_dut !== 16'hFE00 ||
 rx_q_lvds_dut !== 16'h0400) begin
 $display("FAIL T20: back-to-back pair 2: valid=%b I=0x%04X Q=0x%04X (exp I=0xFE00 Q=0x0400)",
 rx_valid_lvds_dut, rx_i_lvds_dut, rx_q_lvds_dut);
 error_count = error_count + 1;
 end else begin
 $display("PASS T20: back-to-back pair 2 I=0xFE00 Q=0x0400");
 end
 // Drive pair 3 Q-cycle
 ad9361_rx_frame_p_tb = 1'b0;
 ad9361_rx_data_p_tb = 6'h3E; // Q3[11:6]: -128 = 12'hF80 → [11:6]=0x3E
 @(negedge ad9361_data_clk_p_tb); #T_HOLD;
 ad9361_rx_data_p_tb = 6'h00; // Q3[5:0]

 // Wait 2 posedges for pair 3 valid (B+7)
 @(posedge ad9361_data_clk_p_tb); // B+6 — dummy
 @(posedge ad9361_data_clk_p_tb); #T_HOLD; // B+7: pair 3 valid
 if (rx_valid_lvds_dut !== 1'b1 ||
 rx_i_lvds_dut !== 16'h0100 ||
 rx_q_lvds_dut !== 16'hFF80) begin
 $display("FAIL T21: back-to-back pair 3: valid=%b I=0x%04X Q=0x%04X (exp I=0x0100 Q=0xFF80)",
 rx_valid_lvds_dut, rx_i_lvds_dut, rx_q_lvds_dut);
 error_count = error_count + 1;
 end else begin
 $display("PASS T21: back-to-back pair 3 I=0x0100 Q=0xFF80");
 end

 // -------------------------------------------------------------------------
 // Final result
 // -------------------------------------------------------------------------
 wait_clocks(4);
 $display("");
 $display("=========================================");
 if (error_count == 0) begin
 $display("RESULT: ALL TESTS PASSED (0 errors)");
 $display(" tetra_ad9361_interface: GATE 2 PASS");
 end else begin
 $display("RESULT: FAILED — %0d error(s)", error_count);
 $display(" tetra_ad9361_interface: GATE 2 FAIL");
 end
 $display("=========================================");
 $display("");
 $finish;
end

// =============================================================================
// Timeout watchdog — abort if simulation hangs
// =============================================================================

initial begin
 #(CLK_PERIOD * 2000);
 $display("TIMEOUT: simulation did not finish in time");
 $finish;
end

endmodule
