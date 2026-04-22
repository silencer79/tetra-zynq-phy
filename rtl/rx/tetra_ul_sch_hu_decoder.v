// =============================================================================
// tetra_ul_sch_hu_decoder.v — UL SCH/HU Channel Decoder (K=168, a=13, info=92)
// =============================================================================
//
// Purpose:
//   Consume 168 soft-dibit values (84 cb1 + 84 cb2) from tetra_ul_pi4dqpsk_demod
//   and produce 92 decoded info bits + CRC16 pass/fail flag per ETSI EN 300 392-2
//   §8.3.1 (SCH/HU) and §8.2 (RCPC r=2/3 + bit-interleave + scrambling).
//
//   Mirrors the offline pipeline in scripts/decode_dl.decode_channel_soft()
//   with K=168, a=13, info=92 — the same path that gives 41/42 CRC pass on the
//   WAV capture (see project_ul_ra_decoded memory).
//
// RX Pipeline (reverse of TX):
//   (1) type-2 bits (168 soft, in-air order)  ← from demod
//   (2) Descramble:  flip sign of soft bit k using scrambler_seq[k]
//        - LFSR §8.2.5: 32-bit Galois, taps 0,6,9,10,16,20,21,22,24,25,27,28,30,31
//        - Init = (MCC<<22)|(MNC<<8)|(CC<<2)|3 from AXI register
//   (3) Deinterleave (168, a=13):  out[i-1] = in[(13*i) mod 168]  (self-inverse)
//   (4) Depuncture r=2/3:  168 → 448 bits, period=8, P=[1,2,5] kept
//        - For j=1..168: k = 8*((j-1)/3) + P[((j-1) mod 3)+1]; out[k-1] = in[j-1]
//        - Other positions = erasure (unsigned soft = 4 for 3-bit)
//   (5) Viterbi K=5 r=1/4:  448 mother soft → 112 decoded bits
//        - Reuses rtl/lmac/tetra_viterbi_decoder.v (G1/G2/G3/G4=0x13/1D/17/1B)
//   (6) CRC16 check:  first 108 decoded bits = 92 info + 16 FCS
//        - Reuses rtl/lmac/tetra_crc16.v (CCITT bit-reversed, DLL-compatible)
//   (7) Output 92 info bits + crc_ok_sys
//
// State Machine:
//   S_IDLE         — wait for first soft_valid_sys
//   S_COLLECT      — store 168 soft bits; generate scrambler seq in parallel
//   S_DESCRAMBLE   — flip sign of each buf entry based on scrambler bit
//   S_DEINTERLEAVE — copy buf_desc[(13*i) mod 168] → buf_deint[i-1]
//   S_FEED_VIT     — iterate trellis stages (112) × 4 soft values, applying
//                    depuncture pattern. Erasure = unsigned 4.
//   S_DRAIN_VIT    — wait for tetra_viterbi_decoder block_done + output stream
//   S_FEED_CRC     — stream first 108 decoded bits into tetra_crc16
//   S_DONE         — latch info_bits + crc_ok, pulse info_valid_sys
//
// Timing: one bit per sys_clk cycle across the pipeline. Sys_clk = 100 MHz,
// burst interval ≥ 7 ms = 700 k cycles → plenty of headroom (total ~2 k cycles).
//
// Resource estimate (Zynq-7020):
//   + viterbi ≈ 2.5k LUT / 8k FF / 0 DSP / 0 BRAM
//   + crc16   ≈  50 LUT /  30 FF
//   + local   ≈ 500 LUT /  800 FF / 0 BRAM  (buffers are flat flops per CLAUDE.md)
//
// =============================================================================

`default_nettype none

module tetra_ul_sch_hu_decoder #(
    parameter SOFT_IN_WIDTH  = 8,      // signed soft width from demod
    parameter VIT_SOFT_WIDTH = 5,      // tetra_viterbi_decoder unsigned soft width
    parameter N_TX           = 168,    // transmitted type-2 bits per CB
    parameter DEINT_A        = 13,     // multiplicative interleave constant
    parameter INFO_BITS      = 92,     // info bits (includes 16 CRC, excl tail)
    parameter TAIL           = 4,      // K-1 = 4 tail bits
    parameter MOTHER_LEN     = 448,    // (N_TX/3)*8
    parameter TRELLIS_STAGES = 112     // MOTHER_LEN/4
)(
    input  wire                               clk_sys,
    input  wire                               rst_n_sys,
    // AXI config
    input  wire [31:0]                        scramb_init_sys,
    // Soft-dibit input from demod
    input  wire signed [SOFT_IN_WIDTH-1:0]    soft_bit0_sys,
    input  wire signed [SOFT_IN_WIDTH-1:0]    soft_bit1_sys,
    input  wire                               soft_valid_sys,
    input  wire                               soft_first_sys,
    input  wire                               soft_last_sys,
    input  wire                               soft_half_sys,
    // Decoded output
    output reg  [INFO_BITS-1:0]               info_bits_sys,
    output reg                                info_valid_sys,
    output reg                                crc_ok_sys,
    // Debug / AXI visibility
    output reg  [15:0]                        decodes_attempted_sys,
    output reg  [15:0]                        decodes_ok_sys
);

// -------------------------------------------------------------------------
// Constants — ETSI SCH/HU depuncture pattern (period 8, P=[1,2,5] 1-indexed)
// -------------------------------------------------------------------------
localparam integer PERIOD = 8;
localparam integer T_PER  = 3;

// -------------------------------------------------------------------------
// FSM states
// -------------------------------------------------------------------------
localparam [3:0] S_IDLE         = 4'd0;
localparam [3:0] S_COLLECT      = 4'd1;
localparam [3:0] S_DESCRAMBLE   = 4'd2;
localparam [3:0] S_DEINTERLEAVE = 4'd3;
localparam [3:0] S_FEED_VIT     = 4'd4;
localparam [3:0] S_DRAIN_VIT    = 4'd5;
localparam [3:0] S_FEED_CRC     = 4'd6;
localparam [3:0] S_DONE         = 4'd7;

reg [3:0]  state_sys;

// -------------------------------------------------------------------------
// Soft-bit buffer — 168 entries × SOFT_IN_WIDTH bits signed
// Packed into flat 2D reg (per CLAUDE.md convention)
// -------------------------------------------------------------------------
reg signed [SOFT_IN_WIDTH-1:0] buf_soft_sys [0:N_TX-1];

// Flat scrambler sequence bits (168 bits)
reg [N_TX-1:0] scramb_seq_sys;

// Deinterleaved soft bits
reg signed [SOFT_IN_WIDTH-1:0] buf_deint_sys [0:N_TX-1];

// -------------------------------------------------------------------------
// Scrambler LFSR — runs continuously during S_COLLECT
//   Galois: output = LSB, shift right, XOR mask on feedback (per §8.2.5)
// -------------------------------------------------------------------------
reg [31:0] lfsr_sys;
reg [7:0]  lfsr_cnt_sys;      // 0..N_TX
reg        lfsr_running_sys;

wire lfsr_bit_w = (
    lfsr_sys[0]  ^ lfsr_sys[6]  ^ lfsr_sys[9]  ^ lfsr_sys[10] ^
    lfsr_sys[16] ^ lfsr_sys[20] ^ lfsr_sys[21] ^ lfsr_sys[22] ^
    lfsr_sys[24] ^ lfsr_sys[25] ^ lfsr_sys[27] ^ lfsr_sys[28] ^
    lfsr_sys[30] ^ lfsr_sys[31]
);

// -------------------------------------------------------------------------
// Collect counter
// -------------------------------------------------------------------------
reg [8:0] collect_cnt_sys;    // 0..167 (soft-bit index)

// -------------------------------------------------------------------------
// Descramble / Deinterleave counters
// -------------------------------------------------------------------------
reg [8:0] step_cnt_sys;       // generic 0..N_TX-1 iterator

// Deinterleave address = (DEINT_A * i) mod N_TX, computed incrementally
reg [8:0] deint_addr_sys;     // init = 0 for i=0; stepped by DEINT_A mod N_TX

// -------------------------------------------------------------------------
// Viterbi feed counters — (period, sub_idx) for depuncture pattern
// -------------------------------------------------------------------------
reg [7:0] vit_stage_sys;      // 0..111 trellis stage
reg [1:0] vit_g_sys;          // 0..3 generator index within stage
// Packed mother-bit index within-stage mapping to P[sub_idx] or erasure:
//   mother_bit_in_period = 8 * stage_period + offset
//   where offset is within-period pos 0..7; P={1,2,5} (1-indexed) = {0,1,4}
// We map sub_idx over input bits differently — simpler to compute
// "mother_pos = stage*4 + g" and test membership in the kept-position set.

// kept-position LUT (bit N set ⇔ mother_pos N is a kept bit, i.e. populated
// by a real soft value). With period 8 mapping to P=[1,2,5] 1-indexed:
//   positions 0,1,4 within each period → pack every 8-bit mask = 8'b00010011
// For MOTHER_LEN=448 we replicate this pattern 56 times. Test via
// low 3 bits of mother_pos: pos[2:0] ∈ {0,1,4} → kept.
wire [2:0] mother_pos_lo_w   = {vit_stage_sys[0], vit_g_sys};  // low 3 bits of (stage*4+g)
// (stage*4 + g) mod 8 == (stage[0]<<2) | g  ⇔  {stage[0], g}

// But wait — we need the INPUT-INDEX of the kept position within its period,
// so we can fetch the right buf_deint[] entry. Use running counter.
reg [8:0] vit_kept_idx_sys;   // 0..N_TX-1 — next kept-position input index

wire vit_is_kept_w = (mother_pos_lo_w == 3'd0) ||
                     (mother_pos_lo_w == 3'd1) ||
                     (mother_pos_lo_w == 3'd4);

// -------------------------------------------------------------------------
// Signed-soft → unsigned soft for Viterbi (0=strong 0, MAX=strong 1, CENTER=erasure).
// diff = CENTER − s_in, clamp [0, MAX].
// With VIT_SOFT_WIDTH=4: center=8, max=15, |s_in|≥8 saturates → strong decision.
// Demod outputs in ±20..±27 range (low-SNR WAV) all map to strong, and small
// values |s_in| < center give graded confidence. 3-bit quant was lossy on real
// WAV signals; 4-bit matches Python float Viterbi 5/8 baseline.
// -------------------------------------------------------------------------
localparam [VIT_SOFT_WIDTH-1:0] VIT_CENTER = {1'b1, {(VIT_SOFT_WIDTH-1){1'b0}}};
localparam [VIT_SOFT_WIDTH-1:0] VIT_MAX    = {VIT_SOFT_WIDTH{1'b1}};

function [VIT_SOFT_WIDTH-1:0] to_vit_soft;
    input signed [SOFT_IN_WIDTH-1:0] s_in;
    reg signed [SOFT_IN_WIDTH:0]  diff_ext;     // 9-bit signed: CENTER − s_in
    begin
        diff_ext = {1'b0, VIT_CENTER} - {s_in[SOFT_IN_WIDTH-1], s_in};
        if (diff_ext < 0)
            to_vit_soft = {VIT_SOFT_WIDTH{1'b0}};
        else if (diff_ext > VIT_MAX)
            to_vit_soft = VIT_MAX;
        else
            to_vit_soft = diff_ext[VIT_SOFT_WIDTH-1:0];
    end
endfunction

// -------------------------------------------------------------------------
// Viterbi interface
// -------------------------------------------------------------------------
reg  [VIT_SOFT_WIDTH-1:0] vit_soft0_sys, vit_soft1_sys, vit_soft2_sys, vit_soft3_sys;
reg                       vit_input_valid_sys;
wire                      vit_decoded_bit_w;
wire                      vit_decoded_valid_w;
wire                      vit_block_done_w;

// Select which soft to produce on vit_soft{g}: use g-index
// Combinational fetch — must see current vit_kept_idx_sys, not a 1-cycle lag
wire signed [SOFT_IN_WIDTH-1:0] soft_for_g_w = buf_deint_sys[vit_kept_idx_sys];

wire [VIT_SOFT_WIDTH-1:0] vit_soft_active_w = vit_is_kept_w
                                             ? to_vit_soft(soft_for_g_w)
                                             : {1'b1, {(VIT_SOFT_WIDTH-1){1'b0}}};
                                             //  3'd4 = erasure (unsigned)

tetra_ul_viterbi_r14 #(
    .SOFT_WIDTH(VIT_SOFT_WIDTH),
    .TRACEBACK(32),
    .MAX_STAGES(TRELLIS_STAGES)
) u_viterbi (
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .soft_bit_0    (vit_soft0_sys),
    .soft_bit_1    (vit_soft1_sys),
    .soft_bit_2    (vit_soft2_sys),
    .soft_bit_3    (vit_soft3_sys),
    .input_valid   (vit_input_valid_sys),
    .num_stages    (TRELLIS_STAGES[8:0]),
    .decoded_bit   (vit_decoded_bit_w),
    .decoded_valid (vit_decoded_valid_w),
    .block_done    (vit_block_done_w),
    .path_metric_min ()
);

// -------------------------------------------------------------------------
// Viterbi output capture — buffer the 112 decoded bits (discard last 4 tail)
// -------------------------------------------------------------------------
localparam integer CRC_LEN = INFO_BITS + 16;  // 108 bits

reg [CRC_LEN-1:0] vit_out_buf_sys;
reg [7:0]         vit_out_cnt_sys;  // 0..112

// -------------------------------------------------------------------------
// CRC16 interface
// -------------------------------------------------------------------------
reg  crc_init_sys, crc_data_valid_sys, crc_done_in_sys;
reg  crc_data_in_sys;
wire crc_done_w;
wire [15:0] crc_out_w;
wire crc_ok_w;

tetra_crc16 u_crc16 (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .init_sys       (crc_init_sys),
    .data_in_sys    (crc_data_in_sys),
    .data_valid_sys (crc_data_valid_sys),
    .done_in_sys    (crc_done_in_sys),
    .crc_out_sys    (crc_out_w),
    .crc_valid_sys  (crc_done_w),
    .crc_ok_sys     (crc_ok_w)
);

reg [7:0] crc_fed_cnt_sys;

// -------------------------------------------------------------------------
// Integers for loops
// -------------------------------------------------------------------------
integer idx_i;

// -------------------------------------------------------------------------
// Main FSM
// -------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        state_sys             <= S_IDLE;
        collect_cnt_sys       <= 9'd0;
        step_cnt_sys          <= 9'd0;
        deint_addr_sys        <= 9'd0;
        vit_stage_sys         <= 8'd0;
        vit_g_sys             <= 2'd0;
        vit_kept_idx_sys      <= 9'd0;
        vit_input_valid_sys   <= 1'b0;
        vit_soft0_sys         <= {VIT_SOFT_WIDTH{1'b0}};
        vit_soft1_sys         <= {VIT_SOFT_WIDTH{1'b0}};
        vit_soft2_sys         <= {VIT_SOFT_WIDTH{1'b0}};
        vit_soft3_sys         <= {VIT_SOFT_WIDTH{1'b0}};
        vit_out_buf_sys       <= {CRC_LEN{1'b0}};
        vit_out_cnt_sys       <= 8'd0;
        crc_init_sys          <= 1'b0;
        crc_data_valid_sys    <= 1'b0;
        crc_done_in_sys       <= 1'b0;
        crc_data_in_sys       <= 1'b0;
        crc_fed_cnt_sys       <= 8'd0;
        info_bits_sys         <= {INFO_BITS{1'b0}};
        info_valid_sys        <= 1'b0;
        crc_ok_sys            <= 1'b0;
        decodes_attempted_sys <= 16'd0;
        decodes_ok_sys        <= 16'd0;
        lfsr_sys              <= 32'hFFFF_FFFF;
        lfsr_cnt_sys          <= 8'd0;
        lfsr_running_sys      <= 1'b0;
        scramb_seq_sys        <= {N_TX{1'b0}};
        for (idx_i = 0; idx_i < N_TX; idx_i = idx_i + 1) begin
            buf_soft_sys[idx_i]  <= {SOFT_IN_WIDTH{1'b0}};
            buf_deint_sys[idx_i] <= {SOFT_IN_WIDTH{1'b0}};
        end
    end else begin
        // Defaults for pulse signals
        vit_input_valid_sys <= 1'b0;
        crc_init_sys        <= 1'b0;
        crc_data_valid_sys  <= 1'b0;
        crc_done_in_sys     <= 1'b0;
        info_valid_sys      <= 1'b0;

        // LFSR advances one bit per cycle when enabled
        if (lfsr_running_sys && lfsr_cnt_sys < N_TX[7:0]) begin
            scramb_seq_sys[lfsr_cnt_sys] <= lfsr_bit_w;
            lfsr_sys     <= {lfsr_bit_w, lfsr_sys[31:1]};
            lfsr_cnt_sys <= lfsr_cnt_sys + 8'd1;
        end

        case (state_sys)
        // -----------------------------------------------------------------
        S_IDLE: begin
            if (soft_valid_sys) begin
                // First soft bit — kick off LFSR + collection
                lfsr_sys         <= (scramb_init_sys == 32'd0) ? 32'hFFFF_FFFF
                                                              : scramb_init_sys;
                lfsr_cnt_sys     <= 8'd0;
                lfsr_running_sys <= 1'b1;
                collect_cnt_sys  <= 9'd0;
                state_sys        <= S_COLLECT;
                decodes_attempted_sys <= decodes_attempted_sys + 16'd1;
                // Store first soft pair (bit1 then bit0 — MSB first per ETSI)
                buf_soft_sys[0]  <= soft_bit1_sys;
                buf_soft_sys[1]  <= soft_bit0_sys;
                collect_cnt_sys  <= 9'd2;
            end
        end

        // -----------------------------------------------------------------
        S_COLLECT: begin
            if (soft_valid_sys) begin
                buf_soft_sys[collect_cnt_sys]   <= soft_bit1_sys;
                buf_soft_sys[collect_cnt_sys+1] <= soft_bit0_sys;
                if (collect_cnt_sys + 9'd2 >= N_TX[8:0]) begin
                    state_sys       <= S_DESCRAMBLE;
                    step_cnt_sys    <= 9'd0;
                    collect_cnt_sys <= 9'd0;
                end else begin
                    collect_cnt_sys <= collect_cnt_sys + 9'd2;
                end
            end
        end

        // -----------------------------------------------------------------
        S_DESCRAMBLE: begin
            // Flip sign of buf_soft[k] where scramb_seq[k]=1. One bit/cycle.
            // Wait until LFSR has produced bit step_cnt_sys.
            if (lfsr_cnt_sys > step_cnt_sys[7:0]) begin
                if (scramb_seq_sys[step_cnt_sys]) begin
                    // Two's complement negate: buf <= -buf  (saturation OK for 8-bit)
                    buf_soft_sys[step_cnt_sys] <= -buf_soft_sys[step_cnt_sys];
                end
                if (step_cnt_sys + 9'd1 >= N_TX[8:0]) begin
                    state_sys      <= S_DEINTERLEAVE;
                    step_cnt_sys   <= 9'd0;
                    deint_addr_sys <= DEINT_A[8:0];  // start at (13*1) mod 168 = 13
                end else begin
                    step_cnt_sys <= step_cnt_sys + 9'd1;
                end
            end
        end

        // -----------------------------------------------------------------
        S_DEINTERLEAVE: begin
            // buf_deint[i-1] = buf_soft[(13*i) mod 168]  for i=1..168
            // step_cnt_sys counts i-1 from 0..167; deint_addr_sys holds (13*i) mod 168
            // Note: when step_cnt_sys = 0 we want i=1 so addr = 13 (set on entry).
            buf_deint_sys[step_cnt_sys] <= buf_soft_sys[deint_addr_sys];
            if (step_cnt_sys + 9'd1 >= N_TX[8:0]) begin
                state_sys        <= S_FEED_VIT;
                step_cnt_sys     <= 9'd0;
                vit_stage_sys    <= 8'd0;
                vit_g_sys        <= 2'd0;
                vit_kept_idx_sys <= 9'd0;
            end else begin
                step_cnt_sys   <= step_cnt_sys + 9'd1;
                // Advance deint_addr = (deint_addr + 13) mod 168
                if (deint_addr_sys + DEINT_A[8:0] >= N_TX[8:0])
                    deint_addr_sys <= deint_addr_sys + DEINT_A[8:0] - N_TX[8:0];
                else
                    deint_addr_sys <= deint_addr_sys + DEINT_A[8:0];
            end
        end

        // -----------------------------------------------------------------
        S_FEED_VIT: begin
            // Produce one soft quad per trellis stage, 1 soft per cycle in g=0..3.
            // Mother position = vit_stage*4 + vit_g. Kept iff (mother_pos mod 8) in {0,1,4}.
            // We register the 4 channels as we iterate g — on g=3 fire input_valid
            case (vit_g_sys)
                2'd0: vit_soft0_sys <= vit_soft_active_w;
                2'd1: vit_soft1_sys <= vit_soft_active_w;
                2'd2: vit_soft2_sys <= vit_soft_active_w;
                2'd3: vit_soft3_sys <= vit_soft_active_w;
            endcase
            if (vit_is_kept_w) begin
                vit_kept_idx_sys <= vit_kept_idx_sys + 9'd1;
            end
            if (vit_g_sys == 2'd3) begin
                vit_input_valid_sys <= 1'b1;
                vit_g_sys           <= 2'd0;
                if (vit_stage_sys + 8'd1 >= TRELLIS_STAGES[7:0]) begin
                    state_sys       <= S_DRAIN_VIT;
                    vit_out_cnt_sys <= 8'd0;
                end else begin
                    vit_stage_sys <= vit_stage_sys + 8'd1;
                end
            end else begin
                vit_g_sys <= vit_g_sys + 2'd1;
            end
        end

        // -----------------------------------------------------------------
        S_DRAIN_VIT: begin
            // Capture first CRC_LEN=108 decoded bits from Viterbi output stream
            if (vit_decoded_valid_w) begin
                if (vit_out_cnt_sys < CRC_LEN[7:0]) begin
                    vit_out_buf_sys[vit_out_cnt_sys] <= vit_decoded_bit_w;
                    vit_out_cnt_sys <= vit_out_cnt_sys + 8'd1;
                end
            end
            if (vit_block_done_w ||
                (vit_out_cnt_sys >= CRC_LEN[7:0] && !vit_decoded_valid_w)) begin
                state_sys       <= S_FEED_CRC;
                crc_init_sys    <= 1'b1;
                crc_fed_cnt_sys <= 8'd0;
            end
        end

        // -----------------------------------------------------------------
        S_FEED_CRC: begin
            // Stream 108 bits MSB-first: buf bit 0 is first decoded bit (earliest)
            if (crc_fed_cnt_sys < CRC_LEN[7:0]) begin
                crc_data_in_sys    <= vit_out_buf_sys[crc_fed_cnt_sys];
                crc_data_valid_sys <= 1'b1;
                crc_done_in_sys    <= (crc_fed_cnt_sys == (CRC_LEN[7:0] - 8'd1));
                crc_fed_cnt_sys    <= crc_fed_cnt_sys + 8'd1;
            end else if (crc_done_w) begin
                crc_ok_sys     <= crc_ok_w;
                info_bits_sys  <= vit_out_buf_sys[INFO_BITS-1:0];
                info_valid_sys <= 1'b1;
                if (crc_ok_w)
                    decodes_ok_sys <= decodes_ok_sys + 16'd1;
                state_sys      <= S_DONE;
            end
        end

        // -----------------------------------------------------------------
        S_DONE: begin
            // Release back to IDLE; hold info_bits until next burst overwrites
            lfsr_running_sys <= 1'b0;
            state_sys        <= S_IDLE;
        end

        default: state_sys <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
