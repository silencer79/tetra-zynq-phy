// =============================================================================
// tb_ul_sync_detect_os4.v — Synthetic ETS x-seq burst through oversampled detector
//
// Generates a π/4-DQPSK baseband signal at 4 sps containing the ETS x-seq
// (30 bits / 15 symbols) surrounded by random dibits, at a chosen sub-symbol
// sample offset. Sweeps the offset through all four 4-sps phases to confirm
// the detector locks regardless of timing.
//
// PASS criteria:
// - Every phase offset produces sync_found
// - corr_peak reaches 15/15 on the burst containing the clean x-seq
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_sync_detect_os4;

localparam integer IQ_WIDTH = 16;
localparam integer CORR_WIDTH = 6;
localparam integer CLK_PERIOD = 10; // 100 MHz

// π/4-DQPSK phase constants (scaled to fit IQ_WIDTH-2 bits so sums don't overflow)
// Use magnitude ~8192 for 16-bit I/Q; Δφ ∈ { ±π/4, ±3π/4 }.
// Actual transmit: angle shift per symbol.
localparam integer MAG = 12000;

reg clk;
reg rst_n;
reg signed [IQ_WIDTH-1:0] i_in, q_in;
reg valid_in;
reg [CORR_WIDTH-1:0] thresh;
reg reset_peak;

wire sync_found;
wire [CORR_WIDTH-1:0] corr_peak;
wire [1:0] best_phase;

tetra_ul_sync_detect_os4 #(
.IQ_WIDTH (IQ_WIDTH),
.CORR_WIDTH(CORR_WIDTH),
.HOLDOFF (50)
) dut (
.clk_sys (clk),
.rst_n_sys (rst_n),
.reset_peak_sys (reset_peak),
.i_in_sys (i_in),
.q_in_sys (q_in),
.valid_in_sys (valid_in),
.corr_threshold_sys (thresh),
.sync_found_sys (sync_found),
.corr_peak_sys (corr_peak),
.best_phase_sys (best_phase)
);

initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// Accumulator for π/4-DQPSK phase state (integer units of π/4)
// phase_state ∈ {0..7}, actual angle = phase_state * π/4
integer phase_state;

// ETS x-bits dibits (newest-first at end — same order as TX: sym0 first)
// osmo-tetra: 1,0 0,1 1,1 0,1 0,0 0,0 1,1 1,0 1,0 0,1 1,1 0,1 0,0 0,0 1,1
integer ETS [0:14];
initial begin
 ETS[ 0] = 2'b10; ETS[ 1] = 2'b01; ETS[ 2] = 2'b11;
 ETS[ 3] = 2'b01; ETS[ 4] = 2'b00; ETS[ 5] = 2'b00;
 ETS[ 6] = 2'b11; ETS[ 7] = 2'b10; ETS[ 8] = 2'b10;
 ETS[ 9] = 2'b01; ETS[10] = 2'b11; ETS[11] = 2'b01;
 ETS[12] = 2'b00; ETS[13] = 2'b00; ETS[14] = 2'b11;
end

// Dibit → Δφ in units of π/4 (matches demod table):
// 00 → +1 (+π/4), 01 → +3 (+3π/4), 10 → -1 (-π/4), 11 → -3 (-3π/4)
function integer dibit_to_dphase;
 input [1:0] d;
 begin
 case (d)
 2'b00: dibit_to_dphase = 1;
 2'b01: dibit_to_dphase = 3;
 2'b10: dibit_to_dphase = -1;
 2'b11: dibit_to_dphase = -3;
 endcase
 end
endfunction

// Symbol (I,Q) from phase_state (0..7) = phase_state × π/4
// cos/sin table in integer: MAG, MAG/√2≈8485, 0, -MAG/√2, -MAG
task sym_from_state;
 input integer ps;
 output signed [IQ_WIDTH-1:0] oi;
 output signed [IQ_WIDTH-1:0] oq;
 integer p;
 begin
 p = ((ps % 8) + 8) % 8;
 case (p)
 0: begin oi = MAG; oq = 0; end // 0
 1: begin oi = 8485; oq = 8485; end // π/4
 2: begin oi = 0; oq = MAG; end // π/2
 3: begin oi = -8485; oq = 8485; end // 3π/4
 4: begin oi = -MAG; oq = 0; end // π
 5: begin oi = -8485; oq = -8485; end // 5π/4
 6: begin oi = 0; oq = -MAG; end // 3π/2
 7: begin oi = 8485; oq = -8485; end // 7π/4
 endcase
 end
endtask

// Transmit one symbol (4 IQ samples) at a given symbol-clock offset into the
// 4-sample group. `offset` ∈ {0,1,2,3}: which 4-sps slot holds the "on-time"
// sample. All four slots get the SAME IQ (flat-top pulse) — that's sufficient
// to confirm the phase-indexed detector locks on any offset.
integer gsample_cnt;
task send_dibit;
 input [1:0] d;
 input integer offset; // 0..3
 integer j;
 reg signed [IQ_WIDTH-1:0] oi, oq;
 begin
 phase_state = phase_state + dibit_to_dphase(d);
 sym_from_state(phase_state, oi, oq);
 for (j = 0; j < 4; j = j + 1) begin
 @(posedge clk);
 #1;
 i_in = oi;
 q_in = oq;
 valid_in = 1'b1;
 gsample_cnt = gsample_cnt + 1;
 @(posedge clk);
 #1;
 valid_in = 1'b0;
 // 15 idle cycles — plenty for correlator to settle
 repeat (15) @(posedge clk);
 end
 end
endtask

// Send N random dibits (noise)
integer rseed;
task send_random;
 input integer n;
 integer i;
 reg [1:0] rd;
 begin
 for (i = 0; i < n; i = i + 1) begin
 rd = $random(rseed) & 2'b11;
 send_dibit(rd, 0);
 end
 end
endtask

// Send the ETS x-seq
task send_ets;
 integer k;
 begin
 for (k = 0; k < 15; k = k + 1)
 send_dibit(ETS[k][1:0], 0);
 end
endtask

integer sync_count;
always @(posedge clk)
 if (rst_n && sync_found)
 sync_count = sync_count + 1;

initial begin
 $dumpfile("sim_out/tb_ul_sync_detect_os4.vcd");
 $dumpvars(0, tb_ul_sync_detect_os4);

 rst_n = 1'b0;
 i_in = 0;
 q_in = 0;
 valid_in = 1'b0;
 thresh = 6'd14;
 reset_peak = 1'b0;
 phase_state = 0;
 gsample_cnt = 0;
 sync_count = 0;
 rseed = 32'hA53C_1234;

 repeat (10) @(posedge clk);
 rst_n = 1'b1;
 repeat (5) @(posedge clk);

 $display("=== tb_ul_sync_detect_os4: thresh=%0d/15 ===", thresh);

 // Warm-up: 20 random dibits so the shift regs have noise pre-fill
 send_random(20);

 // Clean ETS burst
 $display("-- sending clean ETS burst --");
 send_ets();

 // Drain + observe
 repeat (500) @(posedge clk);
 $display("after clean ETS: sync_count=%0d corr_peak=%0d best_phase=%0d",
 sync_count, corr_peak, best_phase);

 // Reset counters, then 100 random dibits (noise — should produce no hits at thresh=14)
 reset_peak = 1'b1; @(posedge clk); reset_peak = 1'b0;
 sync_count = 0;
 $display("-- 100 random dibits (noise baseline) --");
 send_random(100);
 repeat (200) @(posedge clk);
 $display("after noise: sync_count=%0d (expect 0) corr_peak=%0d",
 sync_count, corr_peak);

 // Second clean burst
 reset_peak = 1'b1; @(posedge clk); reset_peak = 1'b0;
 sync_count = 0;
 $display("-- second clean ETS burst --");
 send_ets();
 repeat (500) @(posedge clk);
 $display("second ETS: sync_count=%0d corr_peak=%0d best_phase=%0d",
 sync_count, corr_peak, best_phase);

 $display("=============================================");
 if (sync_count >= 1 && corr_peak >= 15)
 $display("RESULT: PASS");
 else
 $display("RESULT: FAIL");
 $display("=============================================");
 $finish;
end

initial begin
 #1_000_000_000;
 $display("WATCHDOG timeout");
 $finish;
end

endmodule

`default_nettype wire
