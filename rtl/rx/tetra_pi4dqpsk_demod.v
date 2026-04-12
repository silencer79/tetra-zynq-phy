// =============================================================================
// tetra_pi4dqpsk_demod.v — PI/4-DQPSK Demodulator (CORDIC Vectoring)
// =============================================================================
//
// Description:
//   Demodulates a PI/4-DQPSK symbol stream using sequential CORDIC vectoring
//   mode to compute the absolute phase of each received IQ sample, then
//   performs differential decoding to recover 2-bit symbols (dibits).
//
// Algorithm:
//   Stage 1 (S_INIT, 1 cycle):
//     Quadrant-correct incoming IQ to ensure CORDIC convergence (x > 0),
//     record initial phase offset into z accumulator.
//   Stage 2 (S_ITER, 16 cycles):
//     16 CORDIC micro-rotations, one per clock.  Accumulates phase in
//     cordic_z_sample, drives X toward the vector magnitude.
//   Stage 3 (S_DECIDE, 1 cycle):
//     Compute differential phase ΔΦ = z_final - phase_prev.
//     Map ΔΦ to dibit via PI/4-DQPSK symbol table.
//     Compute phase_error = ΔΦ - ideal(dibit) for timing recovery.
//
// Pipeline / latency:
//   18 clk_sample cycles from sample_valid assertion to dibit_valid pulse:
//     1  (S_INIT) + 16 (S_ITER) + 1 (S_DECIDE) = 18 clock edges.
//   At 100 MHz / 72 kHz symbol rate → ~1388 cycles/symbol >> 18: no backpressure.
//
// Port table:
//   clk_sample      100 MHz system clock (same domain as clk_sys)
//   rst_n_sample    Active-low asynchronous reset
//   i_in            Signed I sample, held valid while sample_valid=1
//   q_in            Signed Q sample, held valid while sample_valid=1
//   sample_valid    1-cycle strobe: IQ data is valid this cycle
//   dibit_out       2-bit symbol output (registered)
//   dibit_valid     1-cycle strobe: dibit_out is valid this cycle
//   phase_error     Signed phase error for timing recovery (registered)
//
// Resource estimate (Zynq-7020 post-synthesis):
//   ~300 LUT, ~150 FF, 0 DSP48, 0 BRAM18k
//
// CDC:
//   No CDC inside this module.
//   Upstream: tetra_rx_frontend (clk_sys domain, 100 MHz).
//   Downstream: tetra_timing_recovery (clk_sys domain, 100 MHz).
//
// Reference: ETSI EN 300 392-2 §9.3 (PI/4-DQPSK modulation)
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_pi4dqpsk_demod #(
    parameter IQ_WIDTH     = 16,
    parameter PHASE_WIDTH  = 16,
    parameter CORDIC_ITER  = 16
)(
    input  wire                             clk_sample,    // 100 MHz (same as clk_sys)
    input  wire                             rst_n_sample,
    input  wire signed [IQ_WIDTH-1:0]       i_in,
    input  wire signed [IQ_WIDTH-1:0]       q_in,
    input  wire                             sample_valid,
    output reg  [1:0]                       dibit_out,
    output reg                              dibit_valid,
    output wire signed [PHASE_WIDTH-1:0]    phase_error
);

// =============================================================================
// Localparams
// =============================================================================

localparam CORDIC_WIDTH = IQ_WIDTH + 2;     // 18-bit (2 guard bits for CORDIC gain ~1.647)

// FSM states
localparam [1:0] S_IDLE   = 2'd0;           // Waiting for sample_valid
localparam [1:0] S_INIT   = 2'd1;           // 1 cycle: quadrant correction + CORDIC load
localparam [1:0] S_ITER   = 2'd2;           // 16 cycles: CORDIC iterations
localparam [1:0] S_DECIDE = 2'd3;           // 1 cycle: phase diff + decision + output

// Phase boundaries (Q1.15 fixed-point, full-scale = pi)
localparam signed [PHASE_WIDTH-1:0] BOUND_POS         =  16384;  // +pi/2
localparam signed [PHASE_WIDTH-1:0] BOUND_NEG         = -16384;  // -pi/2
localparam signed [PHASE_WIDTH-1:0] PHASE_PI_HALF     =  16384;  // +pi/2 quadrant offset
localparam signed [PHASE_WIDTH-1:0] PHASE_NEG_PI_HALF = -16384;  // -pi/2 quadrant offset

// Ideal constellation differential phases (Q1.15)
localparam signed [PHASE_WIDTH-1:0] IDEAL_00 =  8192;   // +pi/4
localparam signed [PHASE_WIDTH-1:0] IDEAL_01 =  24576;  // +3pi/4
localparam signed [PHASE_WIDTH-1:0] IDEAL_10 = -8192;   // -pi/4
localparam signed [PHASE_WIDTH-1:0] IDEAL_11 = -24576;  // -3pi/4

// =============================================================================
// Register declarations (10 registers, one always block each — R1)
// =============================================================================

reg  [1:0]                          state_sample;           // R1-1: FSM state
reg  [3:0]                          iter_cnt_sample;        // R1-2: CORDIC iteration counter (0..15)
reg  signed [CORDIC_WIDTH-1:0]      cordic_x_sample;        // R1-3: CORDIC X accumulator
reg  signed [CORDIC_WIDTH-1:0]      cordic_y_sample;        // R1-4: CORDIC Y accumulator
reg  signed [PHASE_WIDTH-1:0]       cordic_z_sample;        // R1-5: CORDIC Z (phase accumulator)
reg  signed [PHASE_WIDTH-1:0]       phase_prev_sample;      // R1-6: Absolute phase of previous symbol
reg                                 phase_locked_sample;    // R1-7: Set after first valid phase
// dibit_out                                                 // R1-8: Output dibit register (port)
// dibit_valid                                               // R1-9: Output valid strobe (port)
reg  signed [PHASE_WIDTH-1:0]       phase_error_reg_sample; // R1-10: Phase error output register

// =============================================================================
// Combinatorial: ATAN lookup table (case statement — R3, no arrays in synth)
// =============================================================================
// Stage 2 pipeline: atan(2^{-i}) scaled to Q1.15 (full-scale = pi)
// Table: atan_val = round(atan(2^{-i}) * 32768 / pi)

reg  signed [PHASE_WIDTH-1:0]       atan_val_sample;        // Current iteration atan value

always @(*) begin   // R10: combinatorial
    case (iter_cnt_sample)
        4'd0:  atan_val_sample = 16'sd8192;
        4'd1:  atan_val_sample = 16'sd4836;
        4'd2:  atan_val_sample = 16'sd2556;
        4'd3:  atan_val_sample = 16'sd1297;
        4'd4:  atan_val_sample = 16'sd651;
        4'd5:  atan_val_sample = 16'sd326;
        4'd6:  atan_val_sample = 16'sd163;
        4'd7:  atan_val_sample = 16'sd81;
        4'd8:  atan_val_sample = 16'sd41;
        4'd9:  atan_val_sample = 16'sd20;
        4'd10: atan_val_sample = 16'sd10;
        4'd11: atan_val_sample = 16'sd5;
        4'd12: atan_val_sample = 16'sd3;
        4'd13: atan_val_sample = 16'sd1;
        4'd14: atan_val_sample = 16'sd1;
        default: atan_val_sample = 16'sd0;  // iter 15 and beyond
    endcase
end

// =============================================================================
// Combinatorial: Sign-extension wires (Stage 1 pre-processing)
// =============================================================================
// Stage 1: Extend IQ inputs from IQ_WIDTH to CORDIC_WIDTH for guard bits

wire signed [CORDIC_WIDTH-1:0]      i_ext_sample;
wire signed [CORDIC_WIDTH-1:0]      q_ext_sample;

assign i_ext_sample = {{(CORDIC_WIDTH-IQ_WIDTH){i_in[IQ_WIDTH-1]}}, i_in};
assign q_ext_sample = {{(CORDIC_WIDTH-IQ_WIDTH){q_in[IQ_WIDTH-1]}}, q_in};

// =============================================================================
// Combinatorial: Two's-complement negations for quadrant correction
// =============================================================================
// Needed for I<0 quadrants where we must present positive X to CORDIC

wire signed [CORDIC_WIDTH-1:0]      neg_i_ext_sample;
wire signed [CORDIC_WIDTH-1:0]      neg_q_ext_sample;

assign neg_i_ext_sample = -i_ext_sample;
assign neg_q_ext_sample = -q_ext_sample;

// =============================================================================
// Combinatorial: Quadrant correction (Stage 1 mux)
// =============================================================================
// Maps input IQ to first-quadrant equivalent so CORDIC can converge.
// Correction angle recorded in z_init_sample.
//
//   I >= 0:          (x, y, z) = (I,  Q,  0)       no rotation needed
//   I <  0, Q >= 0:  (x, y, z) = (Q, -I, +pi/2)   CCW rotation by 90 deg
//   I <  0, Q <  0:  (x, y, z) = (-Q, I, -pi/2)   CW rotation by 90 deg

wire signed [CORDIC_WIDTH-1:0]      x_init_sample;
wire signed [CORDIC_WIDTH-1:0]      y_init_sample;
wire signed [PHASE_WIDTH-1:0]       z_init_sample;

assign x_init_sample = i_in[IQ_WIDTH-1] ?
    (q_in[IQ_WIDTH-1] ? neg_q_ext_sample : q_ext_sample) : i_ext_sample;

assign y_init_sample = i_in[IQ_WIDTH-1] ?
    (q_in[IQ_WIDTH-1] ? i_ext_sample : neg_i_ext_sample) : q_ext_sample;

assign z_init_sample = i_in[IQ_WIDTH-1] ?
    (q_in[IQ_WIDTH-1] ? PHASE_NEG_PI_HALF : PHASE_PI_HALF) : {PHASE_WIDTH{1'b0}};

// =============================================================================
// Combinatorial: CORDIC direction and shift (Stage 2)
// =============================================================================
// cordic_d_sample: rotation direction — 1 if y >= 0 (drive y toward zero)
// The MSB of cordic_y_sample is 1 for negative values.

wire                                cordic_d_sample;
wire signed [CORDIC_WIDTH-1:0]      y_shr_sample;
wire signed [CORDIC_WIDTH-1:0]      x_shr_sample;

assign cordic_d_sample = ~cordic_y_sample[CORDIC_WIDTH-1];   // 1 if y >= 0

// Arithmetic right-shifts by iter_cnt_sample positions
assign y_shr_sample = cordic_y_sample >>> iter_cnt_sample;
assign x_shr_sample = cordic_x_sample >>> iter_cnt_sample;

// =============================================================================
// Combinatorial: CORDIC update equations (Stage 2)
// =============================================================================
// When cordic_d=1 (y >= 0): rotate CW  → x += y>>i, y -= x>>i, z += atan
// When cordic_d=0 (y <  0): rotate CCW → x -= y>>i, y += x>>i, z -= atan
// Vectoring mode: z accumulates +angle so that z_final = +φ (not −φ).
// With the quadrant correction preloading z_init, the result is
// z_final = z_init + angle(x_init, y_init) = φ across all four quadrants.

wire signed [CORDIC_WIDTH-1:0]      x_next_sample;
wire signed [CORDIC_WIDTH-1:0]      y_next_sample;
wire signed [PHASE_WIDTH-1:0]       z_next_sample;

assign x_next_sample = cordic_d_sample ? (cordic_x_sample + y_shr_sample)
                                       : (cordic_x_sample - y_shr_sample);
assign y_next_sample = cordic_d_sample ? (cordic_y_sample - x_shr_sample)
                                       : (cordic_y_sample + x_shr_sample);
assign z_next_sample = cordic_d_sample ? (cordic_z_sample + atan_val_sample)
                                       : (cordic_z_sample - atan_val_sample);

// =============================================================================
// Combinatorial: Differential phase (Stage 3 / S_DECIDE)
// =============================================================================
// ΔΦ = absolute_phase(n) - absolute_phase(n-1)
// Wrapped to PHASE_WIDTH bits via natural truncation (handles wraparound correctly
// for small phase differences when both are near ±pi).

wire signed [PHASE_WIDTH-1:0]       delta_phase_sample;

assign delta_phase_sample = cordic_z_sample - phase_prev_sample;

// =============================================================================
// Combinatorial: Dibit decision (Stage 3)
// =============================================================================
// PI/4-DQPSK symbol mapping based on differential phase quadrant:
//   [0,   +pi/2)  →  dibit 00 (ΔΦ ≈ +pi/4)
//   [+pi/2, +pi)  →  dibit 01 (ΔΦ ≈ +3pi/4)
//   (-pi/2, 0)    →  dibit 10 (ΔΦ ≈ -pi/4)
//   (-pi, -pi/2]  →  dibit 11 (ΔΦ ≈ -3pi/4)

reg  [1:0]                          dibit_next_sample;

always @(*) begin   // R10: combinatorial
    // Note: BOUND_POS/NEG are signed localparams; delta_phase_sample is signed wire.
    // Signed comparison is correct since both operands are signed.
    if (delta_phase_sample >= BOUND_POS)
        dibit_next_sample = 2'b01;
    else if (!delta_phase_sample[PHASE_WIDTH-1])
        dibit_next_sample = 2'b00;      // delta >= 0 (MSB=0)
    else if (delta_phase_sample < BOUND_NEG)
        dibit_next_sample = 2'b11;
    else
        dibit_next_sample = 2'b10;
end

// =============================================================================
// Combinatorial: Ideal phase for phase_error computation
// =============================================================================
// Look up ideal differential phase for the decided dibit symbol.

reg  signed [PHASE_WIDTH-1:0]       ideal_delta_sample;

always @(*) begin   // R10: combinatorial
    case (dibit_next_sample)
        2'b00:   ideal_delta_sample = IDEAL_00;
        2'b01:   ideal_delta_sample = IDEAL_01;
        2'b10:   ideal_delta_sample = IDEAL_10;
        2'b11:   ideal_delta_sample = IDEAL_11;
        default: ideal_delta_sample = IDEAL_00;
    endcase
end

// =============================================================================
// Combinatorial: Phase error computation (Stage 3)
// =============================================================================
// phase_error = ΔΦ - ideal_ΔΦ  (used by timing recovery loop)

wire signed [PHASE_WIDTH-1:0]       phase_err_next_sample;

assign phase_err_next_sample = delta_phase_sample - ideal_delta_sample;

// =============================================================================
// FSM: Next-state logic (R5 — one of three FSM always blocks)
// =============================================================================

reg  [1:0]                          next_state_sample;

always @(*) begin   // R10: combinatorial next-state (R5)
    case (state_sample)
        S_IDLE:   next_state_sample = sample_valid  ? S_INIT   : S_IDLE;
        S_INIT:   next_state_sample = S_ITER;       // unconditional 1-cycle
        S_ITER:   next_state_sample = (iter_cnt_sample == 4'd15) ? S_DECIDE : S_ITER;
        S_DECIDE: next_state_sample = S_IDLE;       // unconditional 1-cycle
        default:  next_state_sample = S_IDLE;
    endcase
end

// =============================================================================
// Register 1: FSM state register (R1, R4, R5)
// =============================================================================

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        state_sample <= S_IDLE;
    else
        state_sample <= next_state_sample;
end

// =============================================================================
// Register 2: CORDIC iteration counter (R1, R4)
// =============================================================================
// Increments each cycle in S_ITER; reset to 0 at start of each S_INIT.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        iter_cnt_sample <= 4'd0;
    else begin
        case (state_sample)
            S_INIT:   iter_cnt_sample <= 4'd0;           // Reset counter for new CORDIC run
            S_ITER:   iter_cnt_sample <= iter_cnt_sample + 4'd1;
            default:  iter_cnt_sample <= 4'd0;
        endcase
    end
end

// =============================================================================
// Register 3: CORDIC X accumulator (R1, R4)
// =============================================================================
// Stage 1 (S_INIT): Load quadrant-corrected X.
// Stage 2 (S_ITER): Update per CORDIC micro-rotation.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        cordic_x_sample <= {CORDIC_WIDTH{1'b0}};
    else begin
        case (state_sample)
            S_INIT: cordic_x_sample <= x_init_sample;   // Load from quadrant mux
            S_ITER: cordic_x_sample <= x_next_sample;   // CORDIC micro-rotation
            default: cordic_x_sample <= {CORDIC_WIDTH{1'b0}};
        endcase
    end
end

// =============================================================================
// Register 4: CORDIC Y accumulator (R1, R4)
// =============================================================================
// Stage 1 (S_INIT): Load quadrant-corrected Y.
// Stage 2 (S_ITER): Update per CORDIC micro-rotation (drives toward 0).

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        cordic_y_sample <= {CORDIC_WIDTH{1'b0}};
    else begin
        case (state_sample)
            S_INIT: cordic_y_sample <= y_init_sample;   // Load from quadrant mux
            S_ITER: cordic_y_sample <= y_next_sample;   // CORDIC micro-rotation
            default: cordic_y_sample <= {CORDIC_WIDTH{1'b0}};
        endcase
    end
end

// =============================================================================
// Register 5: CORDIC Z (phase accumulator) (R1, R4)
// =============================================================================
// Stage 1 (S_INIT): Load quadrant offset into z.
// Stage 2 (S_ITER): Accumulate phase angle corrections.
// After S_ITER: cordic_z_sample holds absolute phase of current symbol.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        cordic_z_sample <= {PHASE_WIDTH{1'b0}};
    else begin
        case (state_sample)
            S_INIT: cordic_z_sample <= z_init_sample;   // Load quadrant offset
            S_ITER: cordic_z_sample <= z_next_sample;   // Accumulate phase
            default: cordic_z_sample <= {PHASE_WIDTH{1'b0}};
        endcase
    end
end

// =============================================================================
// Register 6: Previous symbol phase (R1, R4)
// =============================================================================
// Updated in S_DECIDE with the just-computed absolute phase.
// Used next symbol to compute differential phase ΔΦ.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        phase_prev_sample <= {PHASE_WIDTH{1'b0}};
    else if (state_sample == S_DECIDE)
        phase_prev_sample <= cordic_z_sample;   // Store absolute phase for next symbol
end

// =============================================================================
// Register 7: Phase-locked flag (R1, R4)
// =============================================================================
// Prevents dibit output on first symbol (no valid phase_prev yet).
// Set in S_DECIDE after first symbol has been processed.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        phase_locked_sample <= 1'b0;
    else if (state_sample == S_DECIDE)
        phase_locked_sample <= 1'b1;            // Lock after storing first phase reference
end

// =============================================================================
// Register 8: dibit_out output register (R1, R4)
// =============================================================================
// Stage 3 (S_DECIDE): Latch symbol decision into output register.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        dibit_out <= 2'b00;
    else if (state_sample == S_DECIDE)
        dibit_out <= dibit_next_sample;         // Register decided dibit
end

// =============================================================================
// Register 9: dibit_valid output strobe (R1, R4)
// =============================================================================
// Asserted for exactly 1 cycle after S_DECIDE (when phase_locked was already 1).
// The clock edge exiting S_DECIDE samples: dibit_valid <= (state == S_DECIDE) && phase_locked.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        dibit_valid <= 1'b0;
    else
        dibit_valid <= (state_sample == S_DECIDE) && phase_locked_sample;
end

// =============================================================================
// Register 10: Phase error output register (R1, R4)
// =============================================================================
// Stage 3 (S_DECIDE): Latch phase error for timing recovery.

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        phase_error_reg_sample <= {PHASE_WIDTH{1'b0}};
    else if (state_sample == S_DECIDE)
        phase_error_reg_sample <= phase_err_next_sample;  // Register phase error
end

// =============================================================================
// Output wire
// =============================================================================

assign phase_error = phase_error_reg_sample;

endmodule

`default_nettype wire
