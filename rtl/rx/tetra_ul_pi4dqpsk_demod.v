// =============================================================================
// tetra_ul_pi4dqpsk_demod.v — Differential pi/4-DQPSK Demod (UL CB/NUB)
// =============================================================================
//
// Purpose:
// Consume 43 phase-aligned symbol-rate IQ samples per burst-half from
// tetra_ul_burst_capture and produce 42 soft-dibit pairs per half
// (84 soft bits per half, 168 total per CB burst).
//
// Sample 0 of each half is the differential reference; samples 1..42
// carry the actual dibits. For symbol k (1..42):
// z(k) = IQ(k) * conj(IQ(k-1))
// dibit[0] = sign(Re(z)) (soft = Re(z))
// dibit[1] = sign(Im(z)) (soft = Im(z))
// Sign convention matches tetra_ul_sync_detect_os4 and scripts/decode_ul.py.
//
// Pipeline (4-stage, DSP-friendly):
// S0 (input): latch IQ, update prev, set has_prev_sys / pending_first_sys
// S1 (multiply): register four IQ*IQ products (inferred DSP48)
// S2 (combine): register Re(z)=ii+qq and Im(z)=qi-iq
// S2b (normalise): leading-one of |z|₁=|re|+|im| → power-of-two shift amount
// S3 (output): arith-shift normalise + saturate to SOFT_WIDTH, register
//
// Pipeline latency iq_valid_sys → soft_valid_sys: 4 sys_clk cycles.
//
// Soft quantization (amplitude-normalised — see NORM_TGT + stage 2b/3 below):
// re_z / im_z = |r(k)|·|r(k-1)|·{cos,sin}(Δφ) span 2*IQ_WIDTH+1 bits signed
// (33 bit @ IQ16), scaled by the PRODUCT of the two sample magnitudes. A fixed
// MSB-slice collapses to erasure once amplitude drops below ~50 % FS, so we
// normalise by the L1 magnitude |z|₁ (power-of-two, no divider) → soft becomes
// ≈ {cos,sin}(Δφ), amplitude-free — the relative scale the Viterbi BMU needs.
//
// Resource estimate (Zynq-7020):
// LUT ≈ 180 FF ≈ 220 DSP48 = 4 BRAM = 0
//
// =============================================================================

`default_nettype none

module tetra_ul_pi4dqpsk_demod #(
 parameter IQ_WIDTH = 16,
 parameter SOFT_WIDTH = 8,
 // Amplitude-normalisation target: the L1 magnitude |re_z|+|im_z| of the
 // differential product is shifted so its leading-one lands at this bit.
 // A clean data symbol (Δφ = ±π/4 / ±3π/4) then lands near ±2^(NORM_TGT)
 // — chosen so it saturates to_vit_soft's "strong" region while weak/noisy
 // symbols grade below it.  Makes the soft ≈ {cos,sin}(Δφ), amplitude-free.
 parameter NORM_TGT = 5
)(
 input wire clk_sys,
 input wire rst_n_sys,
 // Phase-aligned IQ stream from tetra_ul_burst_capture (1 sample/cycle)
 input wire signed [IQ_WIDTH-1:0] i_in_sys,
 input wire signed [IQ_WIDTH-1:0] q_in_sys,
 input wire iq_valid_sys,
 input wire iq_first_sys, // diff reference
 input wire iq_last_sys, // last sample of CB2
 input wire iq_half_sys, // 0=CB1, 1=CB2
 // Soft-dibit output (MSB-aligned signed)
 output reg signed [SOFT_WIDTH-1:0] soft_bit0_sys, // sign → dibit[0] (I)
 output reg signed [SOFT_WIDTH-1:0] soft_bit1_sys, // sign → dibit[1] (Q)
 output reg soft_valid_sys,
 output reg soft_first_sys, // first soft of each half
 output reg soft_last_sys, // final soft of burst
 output reg soft_half_sys
);

// ---------------------------------------------------------------------------
// Stage 0 — previous sample & state tracking
// ---------------------------------------------------------------------------
reg signed [IQ_WIDTH-1:0] i_prev_sys, q_prev_sys;
reg has_prev_sys; // set after the ref sample
reg pending_first_sys; // mark next emit as "first"

// emit_sys = non-ref valid sample with a reference on hand
wire emit_s0_w = iq_valid_sys & ~iq_first_sys & has_prev_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 i_prev_sys <= {IQ_WIDTH{1'b0}};
 q_prev_sys <= {IQ_WIDTH{1'b0}};
 has_prev_sys <= 1'b0;
 pending_first_sys <= 1'b0;
 end else if (iq_valid_sys) begin
 i_prev_sys <= i_in_sys;
 q_prev_sys <= q_in_sys;
 if (iq_first_sys) begin
 has_prev_sys <= 1'b1;
 pending_first_sys <= 1'b1;
 end else if (has_prev_sys) begin
 pending_first_sys <= 1'b0;
 end
 end
end

// ---------------------------------------------------------------------------
// Stage 1 — IQ * conj(IQ_prev) multiplications (infer 4 DSP48)
// ---------------------------------------------------------------------------
reg signed [2*IQ_WIDTH-1:0] mul_ii_s1, mul_qq_s1, mul_qi_s1, mul_iq_s1;
reg valid_s1_sys;
reg first_s1_sys;
reg last_s1_sys;
reg half_s1_sys;

// Synchronous reset (not async): lets Vivado absorb these product registers
// into the DSP48 MREG stage (DSP48E1 reg only supports sync reset) — fixes
// DRC DPOP-2/DPOR-1, frees fabric FF. Bit-identical in operation (rst_n is a
// power-on/global reset, deasserted once).
always @(posedge clk_sys) begin
 if (!rst_n_sys) begin
 mul_ii_s1 <= {(2*IQ_WIDTH){1'b0}};
 mul_qq_s1 <= {(2*IQ_WIDTH){1'b0}};
 mul_qi_s1 <= {(2*IQ_WIDTH){1'b0}};
 mul_iq_s1 <= {(2*IQ_WIDTH){1'b0}};
 valid_s1_sys <= 1'b0;
 first_s1_sys <= 1'b0;
 last_s1_sys <= 1'b0;
 half_s1_sys <= 1'b0;
 end else begin
 mul_ii_s1 <= i_in_sys * i_prev_sys;
 mul_qq_s1 <= q_in_sys * q_prev_sys;
 mul_qi_s1 <= q_in_sys * i_prev_sys;
 mul_iq_s1 <= i_in_sys * q_prev_sys;
 valid_s1_sys <= emit_s0_w;
 first_s1_sys <= emit_s0_w & pending_first_sys;
 last_s1_sys <= emit_s0_w & iq_last_sys;
 half_s1_sys <= iq_half_sys;
 end
end

// ---------------------------------------------------------------------------
// Stage 2 — sums: Re(z) = ii + qq, Im(z) = qi - iq
// ---------------------------------------------------------------------------
reg signed [2*IQ_WIDTH:0] re_z_s2, im_z_s2;
reg valid_s2_sys;
reg first_s2_sys;
reg last_s2_sys;
reg half_s2_sys;

// Synchronous reset — same rationale as the stage-1 product registers above
// (DSP48 PREG/adder absorption). Bit-identical in operation.
always @(posedge clk_sys) begin
 if (!rst_n_sys) begin
 re_z_s2 <= {(2*IQ_WIDTH+1){1'b0}};
 im_z_s2 <= {(2*IQ_WIDTH+1){1'b0}};
 valid_s2_sys <= 1'b0;
 first_s2_sys <= 1'b0;
 last_s2_sys <= 1'b0;
 half_s2_sys <= 1'b0;
 end else begin
 re_z_s2 <= {mul_ii_s1[2*IQ_WIDTH-1], mul_ii_s1}
 + {mul_qq_s1[2*IQ_WIDTH-1], mul_qq_s1};
 im_z_s2 <= {mul_qi_s1[2*IQ_WIDTH-1], mul_qi_s1}
 - {mul_iq_s1[2*IQ_WIDTH-1], mul_iq_s1};
 valid_s2_sys <= valid_s1_sys;
 first_s2_sys <= first_s1_sys;
 last_s2_sys <= last_s1_sys;
 half_s2_sys <= half_s1_sys;
 end
end

// ---------------------------------------------------------------------------
// Stage 2b — amplitude normalisation of the soft decision.
//
// re_z/im_z are |r(k)|·|r(k-1)|·{cos,sin}(Δφ): the differential phase scaled
// by the PRODUCT of the two sample magnitudes.  A fixed MSB-slice of that
// (old stage 3) collapses to erasure once the burst amplitude drops — measured
// in tb_ul_demod_sch_hu: a *clean* signal already fails below ~50 % FS, and
// TETRA reception at range lives well below that.
//
// Normalise by an L1 magnitude estimate |z|₁ = |re_z| + |im_z| so the soft
// becomes ≈ {cos,sin}(Δφ), amplitude-independent — the same soft model as the
// proven Python reference decoder (scripts/decode_ul.py uses sin/cos of the
// phase difference).  No divider: align the slice window to the leading-one of
// |z|₁ (power-of-two normalisation) via a priority encoder + arithmetic shift.
// ---------------------------------------------------------------------------
localparam integer ZW = 2*IQ_WIDTH + 1; // re_z/im_z width (33 @ IQ16)

reg signed [ZW-1:0] re_z_s2b, im_z_s2b;
reg [5:0] norm_sh_s2b;
reg valid_s2b_sys, first_s2b_sys, last_s2b_sys, half_s2b_sys;

wire signed [ZW-1:0] re_abs_s2 = re_z_s2[ZW-1] ? -re_z_s2 : re_z_s2;
wire signed [ZW-1:0] im_abs_s2 = im_z_s2[ZW-1] ? -im_z_s2 : im_z_s2;
wire [ZW:0] mag_l1_s2 = {re_abs_s2[ZW-1], re_abs_s2}
 + {im_abs_s2[ZW-1], im_abs_s2}; // ≥0

// leading-one position of |z|₁ (0 when magnitude is zero)
integer mi;
reg [5:0] msb_pos_s2;
always @* begin
 msb_pos_s2 = 6'd0;
 for (mi = 0; mi <= ZW; mi = mi + 1)
 if (mag_l1_s2[mi]) msb_pos_s2 = mi[5:0];
end
// Shift so the magnitude's leading-one lands at bit NORM_TGT.  Small-signal
// guard: never shift left of 0 (would amplify pure noise into false strongs).
wire [5:0] norm_sh_w = (msb_pos_s2 > NORM_TGT)
 ? (msb_pos_s2 - NORM_TGT[5:0]) : 6'd0;

always @(posedge clk_sys) begin
 if (!rst_n_sys) begin
 re_z_s2b <= {ZW{1'b0}};
 im_z_s2b <= {ZW{1'b0}};
 norm_sh_s2b <= 6'd0;
 valid_s2b_sys <= 1'b0;
 first_s2b_sys <= 1'b0;
 last_s2b_sys <= 1'b0;
 half_s2b_sys <= 1'b0;
 end else begin
 re_z_s2b <= re_z_s2;
 im_z_s2b <= im_z_s2;
 norm_sh_s2b <= norm_sh_w;
 valid_s2b_sys <= valid_s2_sys;
 first_s2b_sys <= first_s2_sys;
 last_s2b_sys <= last_s2_sys;
 half_s2b_sys <= half_s2_sys;
 end
end

// ---------------------------------------------------------------------------
// Stage 3 — arithmetic-shift normalise + saturate to SOFT_WIDTH-bit signed
// ---------------------------------------------------------------------------
wire signed [ZW-1:0] re_norm_s3 = re_z_s2b >>> norm_sh_s2b;
wire signed [ZW-1:0] im_norm_s3 = im_z_s2b >>> norm_sh_s2b;

localparam signed [ZW-1:0] SOFT_MAX = (1 <<< (SOFT_WIDTH-1)) - 1; // +127
localparam signed [ZW-1:0] SOFT_MIN = -(1 <<< (SOFT_WIDTH-1)); // -128

function signed [SOFT_WIDTH-1:0] sat_soft;
 input signed [ZW-1:0] v;
 begin
 if (v > SOFT_MAX) sat_soft = SOFT_MAX[SOFT_WIDTH-1:0];
 else if (v < SOFT_MIN) sat_soft = SOFT_MIN[SOFT_WIDTH-1:0];
 else sat_soft = v[SOFT_WIDTH-1:0];
 end
endfunction

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 soft_bit0_sys <= {SOFT_WIDTH{1'b0}};
 soft_bit1_sys <= {SOFT_WIDTH{1'b0}};
 soft_valid_sys <= 1'b0;
 soft_first_sys <= 1'b0;
 soft_last_sys <= 1'b0;
 soft_half_sys <= 1'b0;
 end else begin
 soft_bit0_sys <= sat_soft(re_norm_s3);
 soft_bit1_sys <= sat_soft(im_norm_s3);
 soft_valid_sys <= valid_s2b_sys;
 soft_first_sys <= first_s2b_sys;
 soft_last_sys <= last_s2b_sys;
 soft_half_sys <= half_s2b_sys;
 end
end

endmodule

`default_nettype wire
