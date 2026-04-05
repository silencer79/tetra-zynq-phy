// =============================================================================
// tetra_timing_recovery.v — Gardner Timing Error Detector + NCO
// =============================================================================
//
// Description:
//   Symbol timing recovery for the TETRA RX chain.  Receives 4× oversampled
//   IQ data from tetra_rx_frontend (72 kHz) and outputs on-time samples to
//   tetra_pi4dqpsk_demod (18 kHz).
//
// Algorithm — Gardner TED:
//   At every NCO overflow (≈ every 4 input samples):
//     late   = i_in_sys     (current on-time candidate, S[n])
//     mid    = i_s1_sys     (midpoint, S[n-2])
//     early  = i_s3_sys     (previous on-time, S[n-4])
//     e(k)   = mid_I × (late_I − early_I) + mid_Q × (late_Q − early_Q)
//   Positive e: sampling too early → increase NCO step (run faster)
//   Negative e: sampling too late  → decrease NCO step (run slower)
//
// NCO design:
//   32-bit accumulator, nominal step = 2^30.
//   Exactly 4 steps of 2^30 = 2^32 → overflow every 4 input samples.
//   Loop filter adjusts step to track symbol timing.
//
// PI loop filter:
//   Proportional: kp_term  = TED >>> KP_SHIFT   (default: >>> 4, Kp = 1/16)
//   Integral:     ki_delta = TED >>> KI_SHIFT   (default: >>> 8, Ki = 1/256)
//   new_step = NCO_NOMINAL + kp_term + loop_integrator
//   loop_integrator += ki_delta (each overflow)
//
// Lock detection:
//   Timing locked when |TED| < LOCK_THRESH for LOCK_COUNT consecutive symbols.
//
// Shift register naming (before clock edge on NCO overflow cycle, i.e.,
// before the registers are updated):
//   i_in_sys = S[n]     ← on-time (current input being presented)
//   i_s0_sys = S[n-1]
//   i_s1_sys = S[n-2]   ← midpoint (between S[n-4] and S[n])
//   i_s2_sys = S[n-3]
//   i_s3_sys = S[n-4]   ← previous on-time
//
// Pipeline / latency:
//   sample_valid_out_sys fires 1 cycle after NCO overflow.
//   At that cycle, i_out_sys / q_out_sys hold the on-time IQ sample.
//   Total latency from on-time input to demod input: 1 clk_sys cycle.
//
// Ports:
//   clk_sys              100 MHz system clock (same domain as downstream)
//   rst_n_sys            Active-low asynchronous reset
//   i_in_sys / q_in_sys  4× oversampled IQ from tetra_rx_frontend (72 kHz)
//   sample_valid_in_sys  One-cycle strobe per input sample (72 kHz)
//   i_out_sys / q_out_sys  On-time IQ to tetra_pi4dqpsk_demod (18 kHz)
//   sample_valid_out_sys   One-cycle strobe (18 kHz)
//   timing_locked_sys    High when PLL locked
//   timing_error_sys     Scaled Gardner TED output (for debug / AXI readback)
//
// Resource estimate (Zynq-7020 post-synthesis):
//   LUT  : ~120   (shift-reg mux, loop arithmetic, comparators)
//   FF   : ~200   (8 × 16-bit IQ delays, NCO/filter regs, output regs)
//   DSP48: 2      (two 16×17 Gardner products)
//   BRAM : 0
//
// CDC:
//   No CDC inside this module.  All signals clk_sys domain.
//   Upstream:   tetra_rx_frontend   (clk_sys, 100 MHz)
//   Downstream: tetra_pi4dqpsk_demod (clk_sys, 100 MHz)
//
// Reference:
//   Gardner, F.M. (1986) "A BPSK/QPSK Timing-Error Detector for Sampled
//   Receivers", IEEE Trans. Comm. Vol. 34(5).
//   ETSI EN 300 392-2 §9.1 (TETRA 18 ksymbol/s, 4× oversampling at 72 kHz)
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_timing_recovery #(
    parameter IQ_WIDTH    = 16,   // I/Q sample width
    parameter NCO_WIDTH   = 32,   // NCO accumulator width
    parameter KP_SHIFT    = 4,    // Proportional gain = 2^-KP_SHIFT
    parameter KI_SHIFT    = 8,    // Integral gain     = 2^-KI_SHIFT
    parameter LOCK_THRESH = 256,  // |TED| < this → locked  (TED units ≈ Q14)
    parameter LOCK_COUNT  = 144   // Consecutive locked symbols to assert lock flag
)(
    input  wire                         clk_sys,
    input  wire                         rst_n_sys,

    // From tetra_rx_frontend — 72 kHz, 4× oversampled
    input  wire signed [IQ_WIDTH-1:0]   i_in_sys,
    input  wire signed [IQ_WIDTH-1:0]   q_in_sys,
    input  wire                         sample_valid_in_sys,

    // To tetra_pi4dqpsk_demod — 18 kHz, on-time samples
    output reg  signed [IQ_WIDTH-1:0]   i_out_sys,
    output reg  signed [IQ_WIDTH-1:0]   q_out_sys,
    output reg                          sample_valid_out_sys,

    // Status
    output reg                          timing_locked_sys,
    output wire signed [IQ_WIDTH-1:0]   timing_error_sys   // Scaled TED (debug)
);

// =============================================================================
// Localparams
// =============================================================================

// NCO nominal step: 4 × 2^30 = 2^32 → overflow every 4 input samples
localparam [NCO_WIDTH-1:0]        NCO_NOMINAL   = 32'h4000_0000;
localparam signed [NCO_WIDTH-1:0] NCO_NOMINAL_S = 32'sh4000_0000;

// Derived widths — avoids magic numbers in bit-range expressions
localparam DIFF_W = IQ_WIDTH + 1;                 // 17: signed diff of two IQ values
localparam PROD_W = IQ_WIDTH + DIFF_W;            // 33: 16 × 17 signed product
localparam SUM_W  = PROD_W + 1;                   // 34: sum of two 33-bit products
localparam SCALE  = SUM_W - IQ_WIDTH;             // 18: right-shift to reach IQ_WIDTH

// Lock counter saturation
localparam [7:0] LOCK_SAT = 8'd255;

// =============================================================================
// Register declarations (one always-block per register — R1)
// =============================================================================

// Pipeline Stage 0: 4-tap IQ shift register (no arrays — R3)
//   Before clock edge on overflow: s1=midpoint(n-2), s3=prev_ontime(n-4)
reg signed [IQ_WIDTH-1:0]   i_s0_sys;      // S[n-1]
reg signed [IQ_WIDTH-1:0]   q_s0_sys;
reg signed [IQ_WIDTH-1:0]   i_s1_sys;      // S[n-2] — midpoint
reg signed [IQ_WIDTH-1:0]   q_s1_sys;
reg signed [IQ_WIDTH-1:0]   i_s2_sys;      // S[n-3]
reg signed [IQ_WIDTH-1:0]   q_s2_sys;
reg signed [IQ_WIDTH-1:0]   i_s3_sys;      // S[n-4] — previous on-time
reg signed [IQ_WIDTH-1:0]   q_s3_sys;

// Pipeline Stage 1: NCO and loop filter state
reg [NCO_WIDTH-1:0]          nco_acc_sys;   // NCO accumulator (unsigned)
reg [NCO_WIDTH-1:0]          nco_step_sys;  // Current NCO step (unsigned, ≈NCO_NOMINAL)
reg signed [NCO_WIDTH-1:0]   loop_integ_sys;// PI integrator (signed)

// Pipeline Stage 2: Output registers
reg signed [IQ_WIDTH-1:0]   ted_out_sys;   // Gardner TED output (debug/lock)
reg [7:0]                   lock_cnt_sys;  // Consecutive locked-symbol counter
// i_out_sys, q_out_sys, sample_valid_out_sys, timing_locked_sys declared as ports

// =============================================================================
// Combinatorial — Pipeline Stage 0: NCO arithmetic
// =============================================================================

wire [NCO_WIDTH-1:0]  nco_sum_sys;
wire                  nco_ovf_sys;

// Unsigned addition; overflow when result wraps (sum < addend)
assign nco_sum_sys = nco_acc_sys + nco_step_sys;
assign nco_ovf_sys = sample_valid_in_sys & (nco_sum_sys < nco_acc_sys);

// =============================================================================
// Combinatorial — Pipeline Stage 0: Gardner TED
// =============================================================================
// Evaluated combinatorially at NCO overflow; registered in Stage 1.
//
// Before clock edge on overflow cycle:
//   i_in_sys = S[n]   (new sample being presented)
//   i_s1_sys = S[n-2] (midpoint, two valid clocks ago)
//   i_s3_sys = S[n-4] (previous on-time, four valid clocks ago)
//
// e = i_s1 × (i_in - i_s3) + q_s1 × (q_in - q_s3)

// Stage 0a: differences (17-bit signed)
wire signed [DIFF_W-1:0]  i_diff_sys;
wire signed [DIFF_W-1:0]  q_diff_sys;

assign i_diff_sys = $signed(i_in_sys)  - $signed(i_s3_sys);
assign q_diff_sys = $signed(q_in_sys)  - $signed(q_s3_sys);

// Stage 0b: products (33-bit signed, maps to DSP48E1 via inference)
wire signed [PROD_W-1:0]  prod_i_sys;
wire signed [PROD_W-1:0]  prod_q_sys;

assign prod_i_sys = $signed(i_s1_sys) * $signed(i_diff_sys);
assign prod_q_sys = $signed(q_s1_sys) * $signed(q_diff_sys);

// Stage 0c: TED sum (34-bit signed)
wire signed [SUM_W-1:0]   ted_sum_sys;

assign ted_sum_sys = $signed({prod_i_sys[PROD_W-1], prod_i_sys}) +
                     $signed({prod_q_sys[PROD_W-1], prod_q_sys});

// Stage 0d: Scale to IQ_WIDTH (arithmetic right-shift by SCALE=18)
//   Extracts bits [33:18] → 16-bit signed result in ≈ Q14 units
wire signed [IQ_WIDTH-1:0]  ted_scaled_sys;

assign ted_scaled_sys = ted_sum_sys[SUM_W-1 : SCALE];

// =============================================================================
// Combinatorial — Pipeline Stage 0: PI loop filter
// =============================================================================
// sign-extend TED to NCO_WIDTH for loop arithmetic

wire signed [NCO_WIDTH-1:0]  ted_ext_sys;
assign ted_ext_sys = {{(NCO_WIDTH-IQ_WIDTH){ted_scaled_sys[IQ_WIDTH-1]}}, ted_scaled_sys};

// Proportional term: TED * Kp = TED >>> KP_SHIFT
wire signed [NCO_WIDTH-1:0]  kp_term_sys;
assign kp_term_sys = ted_ext_sys >>> KP_SHIFT;

// Integral increment: TED * Ki = TED >>> KI_SHIFT
wire signed [NCO_WIDTH-1:0]  ki_delta_sys;
assign ki_delta_sys = ted_ext_sys >>> KI_SHIFT;

// New integrator value (added to nco_step at next overflow)
wire signed [NCO_WIDTH-1:0]  integ_new_sys;
assign integ_new_sys = loop_integ_sys + ki_delta_sys;

// New NCO step: NOMINAL + proportional + updated integrator
// NCO_NOMINAL_S is large positive (2^30) so sum stays positive for small corrections
wire signed [NCO_WIDTH-1:0]  nco_step_new_s;
assign nco_step_new_s = NCO_NOMINAL_S + kp_term_sys + integ_new_sys;

wire [NCO_WIDTH-1:0]  nco_step_new_sys;
assign nco_step_new_sys = nco_step_new_s[NCO_WIDTH-1:0];  // reinterpret as unsigned

// =============================================================================
// Combinatorial — Pipeline Stage 0: Lock detection
// =============================================================================

wire [IQ_WIDTH-1:0]  ted_abs_sys;   // unsigned magnitude
assign ted_abs_sys = ted_scaled_sys[IQ_WIDTH-1]
                     ? (~ted_scaled_sys + 1'b1)
                     : ted_scaled_sys;

wire lock_good_sys;
assign lock_good_sys = (ted_abs_sys < LOCK_THRESH);

// =============================================================================
// Register 1: NCO accumulator
// =============================================================================
// Advances by nco_step_sys on every valid input sample.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        nco_acc_sys <= {NCO_WIDTH{1'b0}};
    else if (sample_valid_in_sys)
        nco_acc_sys <= nco_sum_sys;
end

// =============================================================================
// Register 2: NCO step
// =============================================================================
// Updated at each overflow to close the timing loop.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        nco_step_sys <= NCO_NOMINAL;
    else if (nco_ovf_sys)
        nco_step_sys <= nco_step_new_sys;
end

// =============================================================================
// Register 3: Loop integrator
// =============================================================================
// Accumulates ki_delta at every overflow.  Provides steady-state correction
// for constant frequency offsets (e.g. ADC clock vs symbol clock skew).

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        loop_integ_sys <= {NCO_WIDTH{1'b0}};
    else if (nco_ovf_sys)
        loop_integ_sys <= integ_new_sys;
end

// =============================================================================
// Registers 4–11: IQ shift register (R3: individual registers, no arrays)
// =============================================================================
// Each register shifts on every valid input sample.

// Pipeline Stage 0: I shift
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_s0_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) i_s0_sys <= i_in_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_s0_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) q_s0_sys <= q_in_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_s1_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) i_s1_sys <= i_s0_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_s1_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) q_s1_sys <= q_s0_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_s2_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) i_s2_sys <= i_s1_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_s2_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) q_s2_sys <= q_s1_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) i_s3_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) i_s3_sys <= i_s2_sys;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) q_s3_sys <= {IQ_WIDTH{1'b0}};
    else if (sample_valid_in_sys) q_s3_sys <= q_s2_sys;
end

// =============================================================================
// Register 12: ted_out (Gardner TED, latched at overflow for debug/lock)
// =============================================================================

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        ted_out_sys <= {IQ_WIDTH{1'b0}};
    else if (nco_ovf_sys)
        ted_out_sys <= ted_scaled_sys;
end

// =============================================================================
// Register 13: i_out — on-time I sample
// =============================================================================
// Latched at NCO overflow; held until next symbol.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        i_out_sys <= {IQ_WIDTH{1'b0}};
    else if (nco_ovf_sys)
        i_out_sys <= i_in_sys;
end

// =============================================================================
// Register 14: q_out — on-time Q sample
// =============================================================================

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        q_out_sys <= {IQ_WIDTH{1'b0}};
    else if (nco_ovf_sys)
        q_out_sys <= q_in_sys;
end

// =============================================================================
// Register 15: sample_valid_out (1-cycle strobe, 1 cycle after NCO overflow)
// =============================================================================
// At this cycle, i_out_sys and q_out_sys already hold the on-time sample,
// so the downstream demodulator sees valid data + strobe simultaneously.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sample_valid_out_sys <= 1'b0;
    else
        sample_valid_out_sys <= nco_ovf_sys;
end

// =============================================================================
// Register 16: lock counter
// =============================================================================
// Increments when |TED| < LOCK_THRESH; resets on any large error.
// Saturates at LOCK_SAT to prevent wrap-around.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        lock_cnt_sys <= 8'd0;
    else if (nco_ovf_sys) begin
        if (lock_good_sys) begin
            if (lock_cnt_sys != LOCK_SAT)
                lock_cnt_sys <= lock_cnt_sys + 8'd1;
        end else
            lock_cnt_sys <= 8'd0;
    end
end

// =============================================================================
// Register 17: timing_locked
// =============================================================================
// Asserted after LOCK_COUNT consecutive low-error symbols.
// De-asserted immediately on any high-error symbol.

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        timing_locked_sys <= 1'b0;
    else if (nco_ovf_sys) begin
        if (lock_good_sys && (lock_cnt_sys >= LOCK_COUNT[7:0]))
            timing_locked_sys <= 1'b1;
        else if (!lock_good_sys)
            timing_locked_sys <= 1'b0;
    end
end

// =============================================================================
// Output wire
// =============================================================================

assign timing_error_sys = ted_out_sys;

endmodule

`default_nettype wire
