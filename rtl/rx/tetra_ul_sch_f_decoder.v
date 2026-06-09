// =============================================================================
// tetra_ul_sch_f_decoder.v — UL SCH/F Channel Decoder (N=432, a=103, info=268)
// =============================================================================
//
// Purpose:
//   Decode one SCH/F full-slot burst (432 type-5 soft bits, on-air order) into
//   268 info bits + CRC16 pass/fail, per ETSI EN 300 392-2 §8.2/§8.3.
//   Used for the long-SDS MAC-FRAG/MAC-END continuation that arrives on the
//   reserved SCH/F slots (captured as a Normal Uplink Burst by
//   tetra_ul_nub_capture → 432 parallel softs).
//
//   This is the SCH/F sibling of tetra_ul_sch_hu_decoder.v.  Identical pipeline
//   structure (descramble → deinterleave → depuncture → Viterbi r1/4 → CRC16),
//   re-parameterised for SCH/F and bit-exact to the verified software reference
//   sw/tetra_channel_codec.c::tetra_codec_schf_decode (info_diff = 0/268 on the
//   21:37 reference WAV).  A SEPARATE module (not a parameterised SCH/HU) so the
//   air-verified SCH/HU path is untouched.
//
// SCH/F coding (decode = reverse of encode):
//   type-5(432) → descramble → type-4(432) → deinterleave(a=103) → depuncture
//   P_2/3 → mother(1152) → Viterbi K=5 r1/4 → 288 → drop 4 tail → 284
//   → CRC16 over 268 info + 16 FCS.
//   Depuncture (period 8, kept {0,1,4}): mother[8p]=g1(a), [8p+1]=g2(a),
//   [8p+4]=g1(b); rest = erasure.  Identical to SCH/HU.
//
// Input interface: streaming soft-dibits (2 softs / soft_valid cycle, MSB-first
//   per ETSI), identical to tetra_ul_sch_hu_decoder so the upstream
//   parallel→stream adapter (NUB softs → dibit stream) is the only new glue.
//
// State Machine: S_IDLE → S_COLLECT(432) → S_DESCRAMBLE → S_DEINTERLEAVE
//   → S_FEED_VIT(288×4) → S_DRAIN_VIT → S_FEED_CRC(284) → S_DONE.
//
// Widths: ALL counters widened to 10 bit (N_TX=432 > 255; the SCH/HU 8-bit
//   counters would truncate, e.g. 432 & 0xFF = 176).
//
// Resource: viterbi (MAX_STAGES=288) ≈ 3k LUT / 9k FF; crc16 ≈ 50/30;
//   buffers 432×8 + 432×8 soft (flat flops).  Budget headroom: LUT 66 %.
// =============================================================================

`default_nettype none

module tetra_ul_sch_f_decoder #(
 parameter SOFT_IN_WIDTH = 8,   // signed soft width (sign-extended from NUB SOFT_W=4)
 parameter VIT_SOFT_WIDTH = 5,  // tetra_ul_viterbi_r14 unsigned soft width
 parameter N_TX = 432,          // transmitted type-5 bits per SCH/F burst
 parameter DEINT_A = 103,       // multiplicative interleave constant (SCH/F)
 parameter INFO_BITS = 268,     // info bits (excl. 16 CRC, excl. tail)
 parameter TAIL = 4,            // K-1 tail bits
 parameter MOTHER_LEN = 1152,   // (N_TX/3)*8
 parameter TRELLIS_STAGES = 288 // MOTHER_LEN/4
)(
 input wire clk_sys,
 input wire rst_n_sys,
 // AXI config — cell scrambler init (same as SCH/HU)
 input wire [31:0] scramb_init_sys,
 // Soft-dibit input (2 softs / valid cycle, bit1 then bit0 MSB-first)
 input wire signed [SOFT_IN_WIDTH-1:0] soft_bit0_sys,
 input wire signed [SOFT_IN_WIDTH-1:0] soft_bit1_sys,
 input wire soft_valid_sys,
 input wire soft_first_sys,
 input wire soft_last_sys,
 // Decoded output
 output reg [INFO_BITS-1:0] info_bits_sys,
 output reg info_valid_sys,
 output reg crc_ok_sys,
 // Debug / AXI visibility
 output reg [15:0] decodes_attempted_sys,
 output reg [15:0] decodes_ok_sys
);

 // unused stream flags kept for interface parity with SCH/HU
 wire _unused_ok = &{1'b0, soft_first_sys, soft_last_sys};

// -------------------------------------------------------------------------
// FSM states
// -------------------------------------------------------------------------
localparam [3:0] S_IDLE = 4'd0;
localparam [3:0] S_COLLECT = 4'd1;
localparam [3:0] S_DESCRAMBLE = 4'd2;
localparam [3:0] S_DEINTERLEAVE = 4'd3;
localparam [3:0] S_FEED_VIT = 4'd4;
localparam [3:0] S_DRAIN_VIT = 4'd5;
localparam [3:0] S_FEED_CRC = 4'd6;
localparam [3:0] S_DONE = 4'd7;

reg [3:0] state_sys;

// -------------------------------------------------------------------------
// Soft-bit buffers — N_TX entries × SOFT_IN_WIDTH bits signed
// -------------------------------------------------------------------------
reg signed [SOFT_IN_WIDTH-1:0] buf_soft_sys [0:N_TX-1];
reg signed [SOFT_IN_WIDTH-1:0] buf_deint_sys [0:N_TX-1];

// Flat scrambler sequence bits (N_TX bits)
reg [N_TX-1:0] scramb_seq_sys;

// -------------------------------------------------------------------------
// Scrambler LFSR (§8.2.5, 32-bit Galois) — identical to SCH/HU
// -------------------------------------------------------------------------
reg [31:0] lfsr_sys;
reg [9:0] lfsr_cnt_sys;        // 0..N_TX (10-bit)
reg lfsr_running_sys;

wire lfsr_bit_w = (
 lfsr_sys[0] ^ lfsr_sys[6] ^ lfsr_sys[9] ^ lfsr_sys[10] ^
 lfsr_sys[16] ^ lfsr_sys[20] ^ lfsr_sys[21] ^ lfsr_sys[22] ^
 lfsr_sys[24] ^ lfsr_sys[25] ^ lfsr_sys[27] ^ lfsr_sys[28] ^
 lfsr_sys[30] ^ lfsr_sys[31]
);

// -------------------------------------------------------------------------
// Counters (all 10-bit — N_TX=432, MOTHER stages 288)
// -------------------------------------------------------------------------
reg [9:0] collect_cnt_sys;     // soft-bit index 0..N_TX
reg [9:0] step_cnt_sys;        // generic iterator 0..N_TX-1
reg [9:0] deint_addr_sys;      // (DEINT_A*i) mod N_TX
reg [9:0] vit_stage_sys;       // 0..TRELLIS_STAGES-1
reg [1:0] vit_g_sys;           // 0..3 generator index within stage
reg [9:0] vit_kept_idx_sys;    // next kept-position input index 0..N_TX-1

// kept-position test: mother_pos = stage*4 + g; kept iff (mother_pos mod 8) in {0,1,4}
// (stage*4 + g) mod 8 == {stage[0], g}
wire [2:0] mother_pos_lo_w = {vit_stage_sys[0], vit_g_sys};
wire vit_is_kept_w = (mother_pos_lo_w == 3'd0) ||
 (mother_pos_lo_w == 3'd1) ||
 (mother_pos_lo_w == 3'd4);

// -------------------------------------------------------------------------
// Signed-soft → unsigned Viterbi soft (CENTER = erasure). Identical to SCH/HU.
// -------------------------------------------------------------------------
localparam [VIT_SOFT_WIDTH-1:0] VIT_CENTER = {1'b1, {(VIT_SOFT_WIDTH-1){1'b0}}};
localparam [VIT_SOFT_WIDTH-1:0] VIT_MAX = {VIT_SOFT_WIDTH{1'b1}};

function [VIT_SOFT_WIDTH-1:0] to_vit_soft;
 input signed [SOFT_IN_WIDTH-1:0] s_in;
 reg signed [SOFT_IN_WIDTH:0] diff_ext;
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
reg [VIT_SOFT_WIDTH-1:0] vit_soft0_sys, vit_soft1_sys, vit_soft2_sys, vit_soft3_sys;
reg vit_input_valid_sys;
wire vit_decoded_bit_w;
wire vit_decoded_valid_w;
wire vit_block_done_w;

wire signed [SOFT_IN_WIDTH-1:0] soft_for_g_w = buf_deint_sys[vit_kept_idx_sys];
wire [VIT_SOFT_WIDTH-1:0] vit_soft_active_w = vit_is_kept_w
 ? to_vit_soft(soft_for_g_w)
 : VIT_CENTER; // erasure

tetra_ul_viterbi_r14 #(
 .SOFT_WIDTH(VIT_SOFT_WIDTH),
 .TRACEBACK(32),
 .MAX_STAGES(TRELLIS_STAGES)
) u_viterbi (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 .soft_bit_0 (vit_soft0_sys),
 .soft_bit_1 (vit_soft1_sys),
 .soft_bit_2 (vit_soft2_sys),
 .soft_bit_3 (vit_soft3_sys),
 .input_valid (vit_input_valid_sys),
 .num_stages (TRELLIS_STAGES[8:0]),
 .decoded_bit (vit_decoded_bit_w),
 .decoded_valid (vit_decoded_valid_w),
 .block_done (vit_block_done_w),
 .path_metric_min ()
);

// -------------------------------------------------------------------------
// Viterbi output capture — first CRC_LEN decoded bits
// -------------------------------------------------------------------------
localparam integer CRC_LEN = INFO_BITS + 16; // 284

reg [CRC_LEN-1:0] vit_out_buf_sys;
reg [9:0] vit_out_cnt_sys; // 0..CRC_LEN

// -------------------------------------------------------------------------
// CRC16 interface (CCITT, DLL-compatible) — reused
// -------------------------------------------------------------------------
reg crc_init_sys, crc_data_valid_sys, crc_done_in_sys;
reg crc_data_in_sys;
wire crc_done_w;
wire [15:0] crc_out_w;
wire crc_ok_w;

tetra_crc16 u_crc16 (
 .clk_sys (clk_sys),
 .rst_n_sys (rst_n_sys),
 .init_sys (crc_init_sys),
 .data_in_sys (crc_data_in_sys),
 .data_valid_sys (crc_data_valid_sys),
 .done_in_sys (crc_done_in_sys),
 .crc_out_sys (crc_out_w),
 .crc_valid_sys (crc_done_w),
 .crc_ok_sys (crc_ok_w)
);

reg [9:0] crc_fed_cnt_sys;

integer idx_i;

// -------------------------------------------------------------------------
// Main FSM
// -------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state_sys <= S_IDLE;
 collect_cnt_sys <= 10'd0;
 step_cnt_sys <= 10'd0;
 deint_addr_sys <= 10'd0;
 vit_stage_sys <= 10'd0;
 vit_g_sys <= 2'd0;
 vit_kept_idx_sys <= 10'd0;
 vit_input_valid_sys <= 1'b0;
 vit_soft0_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_soft1_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_soft2_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_soft3_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_out_buf_sys <= {CRC_LEN{1'b0}};
 vit_out_cnt_sys <= 10'd0;
 crc_init_sys <= 1'b0;
 crc_data_valid_sys <= 1'b0;
 crc_done_in_sys <= 1'b0;
 crc_data_in_sys <= 1'b0;
 crc_fed_cnt_sys <= 10'd0;
 info_bits_sys <= {INFO_BITS{1'b0}};
 info_valid_sys <= 1'b0;
 crc_ok_sys <= 1'b0;
 decodes_attempted_sys <= 16'd0;
 decodes_ok_sys <= 16'd0;
 lfsr_sys <= 32'hFFFF_FFFF;
 lfsr_cnt_sys <= 10'd0;
 lfsr_running_sys <= 1'b0;
 scramb_seq_sys <= {N_TX{1'b0}};
 for (idx_i = 0; idx_i < N_TX; idx_i = idx_i + 1) begin
 buf_soft_sys[idx_i] <= {SOFT_IN_WIDTH{1'b0}};
 buf_deint_sys[idx_i] <= {SOFT_IN_WIDTH{1'b0}};
 end
 end else begin
 // Pulse defaults
 vit_input_valid_sys <= 1'b0;
 crc_init_sys <= 1'b0;
 crc_data_valid_sys <= 1'b0;
 crc_done_in_sys <= 1'b0;
 info_valid_sys <= 1'b0;

 // LFSR advances one bit per cycle while enabled
 if (lfsr_running_sys && lfsr_cnt_sys < N_TX[9:0]) begin
 scramb_seq_sys[lfsr_cnt_sys] <= lfsr_bit_w;
 lfsr_sys <= {lfsr_bit_w, lfsr_sys[31:1]};
 lfsr_cnt_sys <= lfsr_cnt_sys + 10'd1;
 end

 case (state_sys)
 // -----------------------------------------------------------------
 S_IDLE: begin
 if (soft_valid_sys) begin
 lfsr_sys <= (scramb_init_sys == 32'd0) ? 32'hFFFF_FFFF
 : scramb_init_sys;
 lfsr_cnt_sys <= 10'd0;
 lfsr_running_sys <= 1'b1;
 decodes_attempted_sys <= decodes_attempted_sys + 16'd1;
 // first soft pair (bit1 then bit0, MSB-first per ETSI)
 buf_soft_sys[0] <= soft_bit1_sys;
 buf_soft_sys[1] <= soft_bit0_sys;
 collect_cnt_sys <= 10'd2;
 state_sys <= S_COLLECT;
 end
 end

 // -----------------------------------------------------------------
 S_COLLECT: begin
 if (soft_valid_sys) begin
 buf_soft_sys[collect_cnt_sys] <= soft_bit1_sys;
 buf_soft_sys[collect_cnt_sys+10'd1] <= soft_bit0_sys;
 if (collect_cnt_sys + 10'd2 >= N_TX[9:0]) begin
 state_sys <= S_DESCRAMBLE;
 step_cnt_sys <= 10'd0;
 collect_cnt_sys <= 10'd0;
 end else begin
 collect_cnt_sys <= collect_cnt_sys + 10'd2;
 end
 end
 end

 // -----------------------------------------------------------------
 S_DESCRAMBLE: begin
 // flip sign of buf_soft[k] where scramb_seq[k]=1 (XOR in soft domain)
 if (lfsr_cnt_sys > step_cnt_sys) begin
 if (scramb_seq_sys[step_cnt_sys]) begin
 buf_soft_sys[step_cnt_sys] <= -buf_soft_sys[step_cnt_sys];
 end
 if (step_cnt_sys + 10'd1 >= N_TX[9:0]) begin
 state_sys <= S_DEINTERLEAVE;
 step_cnt_sys <= 10'd0;
 deint_addr_sys <= DEINT_A[9:0]; // (a*1) mod N
 end else begin
 step_cnt_sys <= step_cnt_sys + 10'd1;
 end
 end
 end

 // -----------------------------------------------------------------
 S_DEINTERLEAVE: begin
 // buf_deint[i-1] = buf_soft[(a*i) mod N] for i=1..N
 buf_deint_sys[step_cnt_sys] <= buf_soft_sys[deint_addr_sys];
 if (step_cnt_sys + 10'd1 >= N_TX[9:0]) begin
 state_sys <= S_FEED_VIT;
 step_cnt_sys <= 10'd0;
 vit_stage_sys <= 10'd0;
 vit_g_sys <= 2'd0;
 vit_kept_idx_sys <= 10'd0;
 end else begin
 step_cnt_sys <= step_cnt_sys + 10'd1;
 // deint_addr = (deint_addr + DEINT_A) mod N_TX  (DEINT_A < N_TX → 1 subtract)
 if (deint_addr_sys + DEINT_A[9:0] >= N_TX[9:0])
 deint_addr_sys <= deint_addr_sys + DEINT_A[9:0] - N_TX[9:0];
 else
 deint_addr_sys <= deint_addr_sys + DEINT_A[9:0];
 end
 end

 // -----------------------------------------------------------------
 S_FEED_VIT: begin
 // one soft per cycle into g=0..3; on g=3 fire input_valid for the stage
 case (vit_g_sys)
 2'd0: vit_soft0_sys <= vit_soft_active_w;
 2'd1: vit_soft1_sys <= vit_soft_active_w;
 2'd2: vit_soft2_sys <= vit_soft_active_w;
 2'd3: vit_soft3_sys <= vit_soft_active_w;
 endcase
 if (vit_is_kept_w) begin
 vit_kept_idx_sys <= vit_kept_idx_sys + 10'd1;
 end
 if (vit_g_sys == 2'd3) begin
 vit_input_valid_sys <= 1'b1;
 vit_g_sys <= 2'd0;
 if (vit_stage_sys + 10'd1 >= TRELLIS_STAGES[9:0]) begin
 state_sys <= S_DRAIN_VIT;
 vit_out_cnt_sys <= 10'd0;
 end else begin
 vit_stage_sys <= vit_stage_sys + 10'd1;
 end
 end else begin
 vit_g_sys <= vit_g_sys + 2'd1;
 end
 end

 // -----------------------------------------------------------------
 S_DRAIN_VIT: begin
 if (vit_decoded_valid_w) begin
 if (vit_out_cnt_sys < CRC_LEN[9:0]) begin
 vit_out_buf_sys[vit_out_cnt_sys] <= vit_decoded_bit_w;
 vit_out_cnt_sys <= vit_out_cnt_sys + 10'd1;
 end
 end
 if (vit_block_done_w ||
 (vit_out_cnt_sys >= CRC_LEN[9:0] && !vit_decoded_valid_w)) begin
 state_sys <= S_FEED_CRC;
 crc_init_sys <= 1'b1;
 crc_fed_cnt_sys <= 10'd0;
 end
 end

 // -----------------------------------------------------------------
 S_FEED_CRC: begin
 // stream CRC_LEN bits MSB-first (bit 0 = earliest decoded)
 if (crc_fed_cnt_sys < CRC_LEN[9:0]) begin
 crc_data_in_sys <= vit_out_buf_sys[crc_fed_cnt_sys];
 crc_data_valid_sys <= 1'b1;
 crc_done_in_sys <= (crc_fed_cnt_sys == (CRC_LEN[9:0] - 10'd1));
 crc_fed_cnt_sys <= crc_fed_cnt_sys + 10'd1;
 end else if (crc_done_w) begin
 crc_ok_sys <= crc_ok_w;
 info_bits_sys <= vit_out_buf_sys[INFO_BITS-1:0];
 info_valid_sys <= 1'b1;
 if (crc_ok_w)
 decodes_ok_sys <= decodes_ok_sys + 16'd1;
 state_sys <= S_DONE;
 end
 end

 // -----------------------------------------------------------------
 S_DONE: begin
 lfsr_running_sys <= 1'b0;
 state_sys <= S_IDLE;
 end

 default: state_sys <= S_IDLE;
 endcase
 end
end

endmodule

`default_nettype wire
