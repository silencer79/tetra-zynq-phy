// =============================================================================
// tetra_ul_pi4dqpsk_demod.v — Differential pi/4-DQPSK Demod (UL CB/NUB)
// =============================================================================
//
// Purpose:
//   Consume 43 phase-aligned symbol-rate IQ samples per burst-half from
//   tetra_ul_burst_capture and produce 42 soft-dibit pairs per half
//   (84 soft bits per half, 168 total per CB burst).
//
//   Sample 0 of each half is the differential reference; samples 1..42
//   carry the actual dibits. For symbol k (1..42):
//     z(k)      = IQ(k) * conj(IQ(k-1))
//     dibit[0]  = sign(Re(z))   (soft = Re(z))
//     dibit[1]  = sign(Im(z))   (soft = Im(z))
//   Sign convention matches tetra_ul_sync_detect_os4 and scripts/decode_ul.py.
//
// Pipeline (3-stage, DSP-friendly):
//   S0 (input)    : latch IQ, update prev, set has_prev_sys / pending_first_sys
//   S1 (multiply) : register four IQ*IQ products (inferred DSP48)
//   S2 (combine)  : register Re(z)=ii+qq and Im(z)=qi-iq
//   S3 (output)   : MSB-slice to SOFT_WIDTH, register outputs + metadata
//
//   Pipeline latency iq_valid_sys → soft_valid_sys : 3 sys_clk cycles.
//
// Soft quantization:
//   re_z / im_z span 2*IQ_WIDTH+1 bits signed (33 bit @ IQ_WIDTH=16). We
//   slice MSB-aligned bits [2*IQ_WIDTH -: SOFT_WIDTH] — signals well below
//   full-scale yield small soft magnitudes, strong signals yield large ones
//   (relative scale is what the Viterbi branch-metric unit needs).
//
// Resource estimate (Zynq-7020):
//   LUT ≈ 180  FF ≈ 220  DSP48 = 4  BRAM = 0
//
// =============================================================================

`default_nettype none

module tetra_ul_pi4dqpsk_demod #(
    parameter IQ_WIDTH   = 16,
    parameter SOFT_WIDTH = 8
)(
    input  wire                         clk_sys,
    input  wire                         rst_n_sys,
    // Phase-aligned IQ stream from tetra_ul_burst_capture (1 sample/cycle)
    input  wire signed [IQ_WIDTH-1:0]   i_in_sys,
    input  wire signed [IQ_WIDTH-1:0]   q_in_sys,
    input  wire                         iq_valid_sys,
    input  wire                         iq_first_sys,   // diff reference
    input  wire                         iq_last_sys,    // last sample of CB2
    input  wire                         iq_half_sys,    // 0=CB1, 1=CB2
    // Soft-dibit output (MSB-aligned signed)
    output reg  signed [SOFT_WIDTH-1:0] soft_bit0_sys,  // sign → dibit[0] (I)
    output reg  signed [SOFT_WIDTH-1:0] soft_bit1_sys,  // sign → dibit[1] (Q)
    output reg                          soft_valid_sys,
    output reg                          soft_first_sys, // first soft of each half
    output reg                          soft_last_sys,  // final soft of burst
    output reg                          soft_half_sys
);

// ---------------------------------------------------------------------------
// Stage 0 — previous sample & state tracking
// ---------------------------------------------------------------------------
reg signed [IQ_WIDTH-1:0] i_prev_sys, q_prev_sys;
reg                       has_prev_sys;       // set after the ref sample
reg                       pending_first_sys;  // mark next emit as "first"

// emit_sys = non-ref valid sample with a reference on hand
wire emit_s0_w = iq_valid_sys & ~iq_first_sys & has_prev_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        i_prev_sys        <= {IQ_WIDTH{1'b0}};
        q_prev_sys        <= {IQ_WIDTH{1'b0}};
        has_prev_sys      <= 1'b0;
        pending_first_sys <= 1'b0;
    end else if (iq_valid_sys) begin
        i_prev_sys <= i_in_sys;
        q_prev_sys <= q_in_sys;
        if (iq_first_sys) begin
            has_prev_sys      <= 1'b1;
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
reg                         valid_s1_sys;
reg                         first_s1_sys;
reg                         last_s1_sys;
reg                         half_s1_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        mul_ii_s1    <= {(2*IQ_WIDTH){1'b0}};
        mul_qq_s1    <= {(2*IQ_WIDTH){1'b0}};
        mul_qi_s1    <= {(2*IQ_WIDTH){1'b0}};
        mul_iq_s1    <= {(2*IQ_WIDTH){1'b0}};
        valid_s1_sys <= 1'b0;
        first_s1_sys <= 1'b0;
        last_s1_sys  <= 1'b0;
        half_s1_sys  <= 1'b0;
    end else begin
        mul_ii_s1    <= i_in_sys * i_prev_sys;
        mul_qq_s1    <= q_in_sys * q_prev_sys;
        mul_qi_s1    <= q_in_sys * i_prev_sys;
        mul_iq_s1    <= i_in_sys * q_prev_sys;
        valid_s1_sys <= emit_s0_w;
        first_s1_sys <= emit_s0_w & pending_first_sys;
        last_s1_sys  <= emit_s0_w & iq_last_sys;
        half_s1_sys  <= iq_half_sys;
    end
end

// ---------------------------------------------------------------------------
// Stage 2 — sums: Re(z) = ii + qq ,  Im(z) = qi - iq
// ---------------------------------------------------------------------------
reg signed [2*IQ_WIDTH:0]   re_z_s2, im_z_s2;
reg                         valid_s2_sys;
reg                         first_s2_sys;
reg                         last_s2_sys;
reg                         half_s2_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        re_z_s2      <= {(2*IQ_WIDTH+1){1'b0}};
        im_z_s2      <= {(2*IQ_WIDTH+1){1'b0}};
        valid_s2_sys <= 1'b0;
        first_s2_sys <= 1'b0;
        last_s2_sys  <= 1'b0;
        half_s2_sys  <= 1'b0;
    end else begin
        re_z_s2      <= {mul_ii_s1[2*IQ_WIDTH-1], mul_ii_s1}
                      + {mul_qq_s1[2*IQ_WIDTH-1], mul_qq_s1};
        im_z_s2      <= {mul_qi_s1[2*IQ_WIDTH-1], mul_qi_s1}
                      - {mul_iq_s1[2*IQ_WIDTH-1], mul_iq_s1};
        valid_s2_sys <= valid_s1_sys;
        first_s2_sys <= first_s1_sys;
        last_s2_sys  <= last_s1_sys;
        half_s2_sys  <= half_s1_sys;
    end
end

// ---------------------------------------------------------------------------
// Stage 3 — MSB-slice to SOFT_WIDTH-bit signed + register outputs
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        soft_bit0_sys  <= {SOFT_WIDTH{1'b0}};
        soft_bit1_sys  <= {SOFT_WIDTH{1'b0}};
        soft_valid_sys <= 1'b0;
        soft_first_sys <= 1'b0;
        soft_last_sys  <= 1'b0;
        soft_half_sys  <= 1'b0;
    end else begin
        soft_bit0_sys  <= re_z_s2[2*IQ_WIDTH -: SOFT_WIDTH];
        soft_bit1_sys  <= im_z_s2[2*IQ_WIDTH -: SOFT_WIDTH];
        soft_valid_sys <= valid_s2_sys;
        soft_first_sys <= first_s2_sys;
        soft_last_sys  <= last_s2_sys;
        soft_half_sys  <= half_s2_sys;
    end
end

endmodule

`default_nettype wire
