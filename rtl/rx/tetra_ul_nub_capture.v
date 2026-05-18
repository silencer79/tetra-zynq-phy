// =============================================================================
// tetra_ul_nub_capture.v — UL TCH/S Normal-Uplink-Burst Capture + Demod
// =============================================================================
//
// Purpose:
// After tetra_ul_sync_detect_os4 (instanced with NTS1 pattern) fires
// sync_found_sys on NTS1[10] (= burst symbol 132), this module
// captures + π/4-DQPSK demods BKN1 (108 sym) and BKN2 (108 sym) from a
// ring buffer, outputs 432 type-5 bits (BKN1 MSB-first || BKN2 MSB-first)
// as a parallel register, and pulses coded_valid_sys when done.
//
// NUB layout (ETSI EN 300 392-2, body = 462 bits = 231 sym; cf. BlueStation
// burst_consts.rs:32 NUB_BITS = 4 + 216 + 22 + 216 + 4):
// bits 0..3 head 2 sym (TAIL/ramp)
// bits 4..219 BKN1 216 bits = 108 sym → 216 type-5 bits
// bits 220..241 NTS1 22 bits = 11 sym ← sync anchor on NTS1's last dibit
// bits 242..457 BKN2 216 bits = 108 sym → 216 type-5 bits
// bits 458..461 tail 2 sym
//
// NUB does NOT contain BB1/BB2 broadcast blocks — those belong to NDB (DL).
//
// Relative to anchor (= raw sample of NTS1's last modulation symbol):
// BKN1 diff-ref (= sym before BKN1[0]): anchor − 119 sym = −476 samples
// BKN1[0]: anchor − 118 sym = −472 samples
// BKN1[107]: anchor − 11 sym = − 44 samples
// BKN2 diff-ref (= anchor itself, NTS1's last sym): anchor + 0 samples
// BKN2[0]: anchor + 1 sym = + 4 samples
// BKN2[107]: anchor + 108 sym = +432 samples
//
// Ring depth = 1024 (10-bit address) → 1024 samples backlog. At sync_found
// the BKN1 diff-ref is 476 samples behind wp; we wait POST_WAIT_SMP=480
// samples for BKN2[107] to be written (wp advances 480 → BKN1 diff-ref at
// wp − 956, still inside 1024 ring with 68-slot margin).
//
// Phase alignment: same scheme as tetra_ul_burst_capture — best_phase_sys
// + local phase_cnt_sys give delta_w = (phase_cnt − 1 − best_phase) mod 4.
// anchor_idx = wp_sys − 1 − delta_w.
//
// Differential demod (matches tetra_pi4dqpsk_demod / ul_sync_detect_os4):
// z = current × conj(prev)
// I_z = I_cur·I_prev + Q_cur·Q_prev → I-axis soft-value
// Q_z = Q_cur·I_prev − I_cur·Q_prev → Q-axis soft-value
//
// Soft-output (Phase E2 — 2026-05-18):
// Pre-Test (sw/test_soft_viterbi.c) bestätigt ~+1 dB Viterbi-Gewinn am
// marginalen SNR (= unser Arbeitspunkt). Per dibit emittieren wir zwei
// SOFT_W-bit signed soft-values via saturating arithmetic right-shift
// um SOFT_SHIFT, clip auf ±MAX_ABS. Sign-bit allein = legacy hard.
//
// Output format:
// coded_softs_sys[ 432*SOFT_W-1 : 216*SOFT_W ] = BKN1 softs
// coded_softs_sys[ 216*SOFT_W-1 : 0 ] = BKN2 softs
// soft for coded-bit i ∈ [0,432): coded_softs_sys[i*SOFT_W +: SOFT_W]
// Higher-index = first transmitted; lower-index = last transmitted.
// coded_valid_sys = 1-cycle pulse on completion.
//
// Resource estimate (Zynq-7020):
// LUT ≈ 250 FF ≈ 500 + 432*(SOFT_W-1) BRAM = 2 DSP = 4 (diff product)
//
// =============================================================================

`default_nettype none

module tetra_ul_nub_capture #(
 parameter IQ_WIDTH = 16,
 parameter RING_DEPTH = 1024,
 parameter RING_ADDR_W = 10,
 parameter SPS = 4,
 parameter BKN_SYMS = 108,
 parameter BKN1_PRE_SMP = 476, // anchor − 119 sym = BKN1 diff-ref sample
 parameter BKN2_OFFSET_SMP = 0, // anchor itself = BKN2 diff-ref (= NTS1[10])
 parameter POST_WAIT_SMP = 480, // wait until BKN2[107] is in ring
 // Soft-decision output (Phase E2):
 // SOFT_W = 4 → ±7 (sweet spot per pre-test).
 // SOFT_SHIFT chosen so typical |prod| lands in ±3..±4 range; tunable via
 // top-level parameter override if signal level changes (AGC re-target).
 parameter SOFT_W = 4,
 parameter SOFT_SHIFT = 24
)(
 input wire clk_sys,
 input wire rst_n_sys,
 // Post-RRC IQ @ 4 sps (shared with tetra_ul_sync_detect_os4 NUB instance)
 input wire signed [IQ_WIDTH-1:0] i_in_sys,
 input wire signed [IQ_WIDTH-1:0] q_in_sys,
 input wire valid_in_sys,
 // Sync pulse from NUB-configured sync detector
 input wire sync_found_sys,
 input wire [1:0] best_phase_sys,
 // Output — 432 SOFT_W-bit signed soft-values + valid pulse
 output reg [432*SOFT_W-1:0] coded_softs_sys,
 output reg coded_valid_sys,
 // Debug / AXI visibility
 output reg [15:0] bursts_captured_sys
);

localparam signed [SOFT_W-1:0] SOFT_MAX_POS = (1 << (SOFT_W-1)) - 1; // +7
localparam signed [SOFT_W-1:0] SOFT_MAX_NEG = -SOFT_MAX_POS;          // -7 (symmetric)
localparam integer BKN_BIT_W = 216 * SOFT_W;                          // bits per half-burst
localparam integer DIBIT_W = 2 * SOFT_W;                              // bits per dibit

// -------------------------------------------------------------------------
// Ring buffer (BRAM-inferred) — continuous IQ write at 72 kHz
// -------------------------------------------------------------------------
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_i_sys [0:RING_DEPTH-1];
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_q_sys [0:RING_DEPTH-1];

reg [RING_ADDR_W-1:0] wp_sys;
reg [1:0] phase_cnt_sys;

always @(posedge clk_sys) begin
 if (valid_in_sys) begin
 ring_i_sys[wp_sys] <= i_in_sys;
 ring_q_sys[wp_sys] <= q_in_sys;
 end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 wp_sys <= {RING_ADDR_W{1'b0}};
 phase_cnt_sys <= 2'd0;
 end else if (valid_in_sys) begin
 wp_sys <= wp_sys + 1'b1;
 phase_cnt_sys <= phase_cnt_sys + 2'd1;
 end
end

// -------------------------------------------------------------------------
// FSM
// -------------------------------------------------------------------------
localparam S_IDLE = 4'd0;
localparam S_WAIT_POST = 4'd1;
localparam S_READ_BKN1_PRE = 4'd2; // issue read for BKN1[0], wait for ref BRAM
localparam S_READ_BKN1_REF = 4'd3; // rd_iq = HA1 ref; latch prev; read BKN1[1]
localparam S_READ_BKN1_RUN = 4'd4; // demod loop
localparam S_READ_BKN2_PRE = 4'd5;
localparam S_READ_BKN2_REF = 4'd6;
localparam S_READ_BKN2_RUN = 4'd7;
localparam S_DONE = 4'd8;

reg [3:0] state_sys;
reg [RING_ADDR_W-1:0] anchor_idx_sys;
reg [RING_ADDR_W-1:0] bkn1_base_sys;
reg [RING_ADDR_W-1:0] bkn2_base_sys;
reg [8:0] post_cnt_sys;
reg [6:0] sym_idx_sys; // 0..BKN_SYMS

// Previous-symbol IQ for differential demod
reg signed [IQ_WIDTH-1:0] prev_i_sys, prev_q_sys;

// (phase_cnt − 1 − best_phase) mod 4
wire [1:0] delta_w = phase_cnt_sys + 2'd3 - best_phase_sys;

// Anchor = ring index of NTS1[10] (last NTS1 dibit) at winning phase
// sync_found is registered 1 cycle after the trigger → wp_sys has advanced 1
wire [RING_ADDR_W-1:0] delta_ext_w = {{(RING_ADDR_W-2){1'b0}}, delta_w};
wire [RING_ADDR_W-1:0] anchor_calc_w = wp_sys
 - delta_ext_w
 - {{(RING_ADDR_W-1){1'b0}}, 1'b1};

// Read-issue: drive BRAM addr
reg rd_en_sys;
reg [RING_ADDR_W-1:0] rd_addr_sys;

// BRAM read output (1-cycle latency)
reg signed [IQ_WIDTH-1:0] rd_i_sys, rd_q_sys;

always @(posedge clk_sys) begin
 if (rd_en_sys) begin
 rd_i_sys <= ring_i_sys[rd_addr_sys];
 rd_q_sys <= ring_q_sys[rd_addr_sys];
 end
end

// -------------------------------------------------------------------------
// Differential product z = current × conj(prev)
// I_z = I_c·I_p + Q_c·Q_p
// Q_z = Q_c·I_p − I_c·Q_p
// 4 signed multiplications (DSP48-inferred)
// -------------------------------------------------------------------------
// PIPELINE STAGE 1 (Phase E2): register the 4 multiplications. Inferred
// as DSP48 MREG (multiplier output register) by Vivado → moves the mult
// delay off the critical path and into the DSP cell itself.
(* use_dsp = "yes" *) reg signed [2*IQ_WIDTH-1:0] mul_ii_r, mul_qq_r,
                                                  mul_qi_r, mul_iq_r;
always @(posedge clk_sys) begin
 mul_ii_r <= rd_i_sys * prev_i_sys;
 mul_qq_r <= rd_q_sys * prev_q_sys;
 mul_qi_r <= rd_q_sys * prev_i_sys;
 mul_iq_r <= rd_i_sys * prev_q_sys;
end

// PIPELINE STAGE 2: register the sum/difference (= diff product).
// Path now: BRAM → DSP-mult → MREG (stage 1) → adder → i_prod_r
// (stage 2) → sat → coded_softs FF (stage 3).
wire signed [2*IQ_WIDTH:0] i_prod_w = mul_ii_r + mul_qq_r;
wire signed [2*IQ_WIDTH:0] q_prod_w = mul_qi_r - mul_iq_r;
reg signed [2*IQ_WIDTH:0] i_prod_r, q_prod_r;
always @(posedge clk_sys) begin
 i_prod_r <= i_prod_w;
 q_prod_r <= q_prod_w;
end

// Saturating arithmetic right-shift to SOFT_W signed.
//
// CONVENTION (per legacy hard-path + SW Viterbi):
//   positive Re(z)/Im(z) → physical bit '0' → SW Viterbi expects -|N|
//   negative Re(z)/Im(z) → physical bit '1' → SW Viterbi expects +|N|
// Therefore we NEGATE the product before slicing — keeps sign-bit
// semantics congruent with the existing hard-mode dibit logic
// (bit_w = MSB(prod)) and the SW soft convention (1↦+N, 0↦−N).
wire signed [2*IQ_WIDTH:0] i_shifted_w = (-i_prod_r) >>> SOFT_SHIFT;
wire signed [2*IQ_WIDTH:0] q_shifted_w = (-q_prod_r) >>> SOFT_SHIFT;

// Saturation via bitwise overflow detection (= no CARRY4 chain).
// In-range iff upper bits [2*IQ_WIDTH : SOFT_W-1] are all same (sign-ext).
// Saturated value: sign of original → ±MAX (asymmetric for 4-bit: [-8,+7]).
wire i_all_zero_w = ~|i_shifted_w[2*IQ_WIDTH : SOFT_W-1];
wire i_all_one_w  =  &i_shifted_w[2*IQ_WIDTH : SOFT_W-1];
wire q_all_zero_w = ~|q_shifted_w[2*IQ_WIDTH : SOFT_W-1];
wire q_all_one_w  =  &q_shifted_w[2*IQ_WIDTH : SOFT_W-1];

wire signed [SOFT_W-1:0] soft_i_w =
 (i_all_zero_w | i_all_one_w) ? i_shifted_w[SOFT_W-1:0]
                              : (i_shifted_w[2*IQ_WIDTH]
                                  ? {1'b1, {(SOFT_W-1){1'b0}}}  /* -8 */
                                  : {1'b0, {(SOFT_W-1){1'b1}}});/* +7 */
wire signed [SOFT_W-1:0] soft_q_w =
 (q_all_zero_w | q_all_one_w) ? q_shifted_w[SOFT_W-1:0]
                              : (q_shifted_w[2*IQ_WIDTH]
                                  ? {1'b1, {(SOFT_W-1){1'b0}}}
                                  : {1'b0, {(SOFT_W-1){1'b1}}});

// Dibit-packed soft = {Q-soft, I-soft}, matches old {q_sign, i_sign} ordering.
wire [DIBIT_W-1:0] dibit_softs_w = {soft_q_w, soft_i_w};

// -------------------------------------------------------------------------
// FSM logic
// -------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state_sys <= S_IDLE;
 anchor_idx_sys <= {RING_ADDR_W{1'b0}};
 bkn1_base_sys <= {RING_ADDR_W{1'b0}};
 bkn2_base_sys <= {RING_ADDR_W{1'b0}};
 post_cnt_sys <= 9'd0;
 sym_idx_sys <= 7'd0;
 prev_i_sys <= {IQ_WIDTH{1'b0}};
 prev_q_sys <= {IQ_WIDTH{1'b0}};
 rd_en_sys <= 1'b0;
 rd_addr_sys <= {RING_ADDR_W{1'b0}};
 coded_softs_sys <= {(432*SOFT_W){1'b0}};
 coded_valid_sys <= 1'b0;
 bursts_captured_sys <= 16'd0;
 end else begin
 // Defaults
 rd_en_sys <= 1'b0;
 coded_valid_sys <= 1'b0;

 case (state_sys)
 // ----------------------------------------------------------------
 S_IDLE: begin
 if (sync_found_sys) begin
 anchor_idx_sys <= anchor_calc_w;
 bkn1_base_sys <= anchor_calc_w
 - BKN1_PRE_SMP[RING_ADDR_W-1:0];
 bkn2_base_sys <= anchor_calc_w
 + BKN2_OFFSET_SMP[RING_ADDR_W-1:0];
 post_cnt_sys <= POST_WAIT_SMP[8:0];
 state_sys <= S_WAIT_POST;
 end
 end

 // ----------------------------------------------------------------
 S_WAIT_POST: begin
 if (valid_in_sys) begin
 if (post_cnt_sys <= 9'd1) begin
 // Issue read for diff-ref sample (HA1). BRAM has 1-
 // cycle latency, so data arrives next cycle.
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn1_base_sys;
 sym_idx_sys <= 7'd0;
 state_sys <= S_READ_BKN1_PRE;
 end else begin
 post_cnt_sys <= post_cnt_sys - 1'b1;
 end
 end
 end

 // ----------------------------------------------------------------
 // S_READ_BKN1_PRE: BRAM read for HA1 in-flight; issue read for
 // BKN1[0]. Do NOT latch prev_iq yet — rd_iq still holds stale
 // data from before the burst.
 // ----------------------------------------------------------------
 S_READ_BKN1_PRE: begin
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn1_base_sys + SPS[RING_ADDR_W-1:0];
 state_sys <= S_READ_BKN1_REF;
 end

 // ----------------------------------------------------------------
 // S_READ_BKN1_REF: rd_iq now = HA1 (BKN1 diff-ref). Latch prev
 // for use as differential reference of BKN1[0]. Issue read for
 // BKN1[1] (we already issued read for BKN1[0] last cycle).
 // ----------------------------------------------------------------
 S_READ_BKN1_REF: begin
 prev_i_sys <= rd_i_sys;
 prev_q_sys <= rd_q_sys;
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn1_base_sys
 + ({{(RING_ADDR_W-2){1'b0}}, 2'd2})
 * SPS[RING_ADDR_W-1:0];
 sym_idx_sys <= 7'd0;
 state_sys <= S_READ_BKN1_RUN;
 end

 // ----------------------------------------------------------------
 // S_READ_BKN1_RUN: rd_iq = BKN1[sym_idx]. Demod (= rd_iq × conj(prev_iq))
 // shift dibit into coded_softs[431*SW : 216*SW]. Latch prev for next.
 // Issue read for BKN1[sym_idx+2] (we already have +1 in flight).
 //
 // Phase E2 pipelining: 2-cycle delay (mul_*_r + i_prod_r) between
 // rd_iq arrival and dibit_softs_w validity. So sym_idx runs 0..109
 // (= BKN_SYMS+1): cycles 0..1 warm up the pipeline (no commit),
 // cycles 2..109 commit the 108 dibits. Reads for BKN1[2..107] issue
 // in sym_idx 0..105; sym_idx 106..109 drain the pipeline.
 // ----------------------------------------------------------------
 S_READ_BKN1_RUN: begin
 // Commit pipelined dibit once pipeline is warm (sym_idx >= 2).
 if (sym_idx_sys >= 7'd2) begin
 coded_softs_sys[432*SOFT_W-1 -: BKN_BIT_W] <=
 {coded_softs_sys[(432*SOFT_W-1-DIBIT_W) -: (BKN_BIT_W-DIBIT_W)],
  dibit_softs_w};
 end
 // Latch prev only while reads are still arriving (sym_idx < BKN_SYMS).
 if (sym_idx_sys < BKN_SYMS[6:0]) begin
 prev_i_sys <= rd_i_sys;
 prev_q_sys <= rd_q_sys;
 end

 if (sym_idx_sys == BKN_SYMS[6:0] + 7'd1) begin
 // All 108 BKN1 dibits committed. Switch to BKN2.
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn2_base_sys;
 sym_idx_sys <= 7'd0;
 state_sys <= S_READ_BKN2_PRE;
 end else begin
 // Issue read for BKN1[sym_idx+2] while sym_idx+2 < BKN_SYMS.
 // Last useful read (BKN1[107]) is issued at sym_idx = 105.
 if (sym_idx_sys < BKN_SYMS[6:0] - 7'd2) begin
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn1_base_sys
 + ({{(RING_ADDR_W-7){1'b0}}, sym_idx_sys + 7'd3})
 * SPS[RING_ADDR_W-1:0];
 end
 sym_idx_sys <= sym_idx_sys + 7'd1;
 end
 end

 // ----------------------------------------------------------------
 // BKN2 demod — analog 3-state version
 // ----------------------------------------------------------------
 S_READ_BKN2_PRE: begin
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn2_base_sys + SPS[RING_ADDR_W-1:0];
 state_sys <= S_READ_BKN2_REF;
 end

 S_READ_BKN2_REF: begin
 prev_i_sys <= rd_i_sys;
 prev_q_sys <= rd_q_sys;
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn2_base_sys
 + ({{(RING_ADDR_W-2){1'b0}}, 2'd2})
 * SPS[RING_ADDR_W-1:0];
 sym_idx_sys <= 7'd0;
 state_sys <= S_READ_BKN2_RUN;
 end

 // Phase E2 — same 2-cycle pipeline semantics as BKN1.
 S_READ_BKN2_RUN: begin
 if (sym_idx_sys >= 7'd2) begin
 coded_softs_sys[BKN_BIT_W-1 -: BKN_BIT_W] <=
 {coded_softs_sys[(BKN_BIT_W-1-DIBIT_W) -: (BKN_BIT_W-DIBIT_W)],
  dibit_softs_w};
 end
 if (sym_idx_sys < BKN_SYMS[6:0]) begin
 prev_i_sys <= rd_i_sys;
 prev_q_sys <= rd_q_sys;
 end

 if (sym_idx_sys == BKN_SYMS[6:0] + 7'd1) begin
 state_sys <= S_DONE;
 end else begin
 if (sym_idx_sys < BKN_SYMS[6:0] - 7'd2) begin
 rd_en_sys <= 1'b1;
 rd_addr_sys <= bkn2_base_sys
 + ({{(RING_ADDR_W-7){1'b0}}, sym_idx_sys + 7'd3})
 * SPS[RING_ADDR_W-1:0];
 end
 sym_idx_sys <= sym_idx_sys + 7'd1;
 end
 end

 // ----------------------------------------------------------------
 S_DONE: begin
 coded_valid_sys <= 1'b1;
 bursts_captured_sys <= bursts_captured_sys + 16'd1;
 state_sys <= S_IDLE;
 end

 default: state_sys <= S_IDLE;
 endcase
 end
end

endmodule

`default_nettype wire
