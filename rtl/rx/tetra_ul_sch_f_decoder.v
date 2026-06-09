// =============================================================================
// tetra_ul_sch_f_decoder.v — UL SCH/F Channel Decoder (N=432, a=103, info=268)
// =============================================================================
//
// Decodes one SCH/F full-slot burst (432 type-5 soft bits, on-air order) into
// 268 info bits + CRC16, per ETSI EN 300 392-2 §8.2/§8.3. Used for the long-SDS
// MAC-FRAG/MAC-END continuation (captured as a NUB, streamed in as dibits by
// tetra_ul_nub_to_schf).  Bit-exact to sw/tetra_channel_codec.c::schf_decode.
//
// SCH/F coding (decode = reverse of encode):
//   type-5(432) → descramble → deinterleave(a=103) → depuncture P_2/3 (kept
//   {0,1,4} of period 8) → mother(1152) → Viterbi K=5 r1/4 → 288 → drop 4 tail
//   → CRC16 over 268 info + 16 FCS.
//
// RESOURCE MAPPING — the 432-deep soft buffers live in BRAM (not slice
// flops+muxes; those ~8k LUT of variable-index muxes overflowed slice packing,
// BRAM has ~89% headroom):
//   - buf_soft : 216×16 BRAM (two 8-bit softs per word → keeps the dibit input,
//     so the stream interface and the GATE testbenches are unchanged).
//   - buf_deint: 432×8 BRAM.
//   - Read ADDRESS is COMBINATIONAL, read DATA registered (rq) → 1-cycle read
//     latency (registered-addr would be 2 cycles and break the pipeline).
//   - descramble is FUSED into the deinterleave read (sign on the buf_soft byte).
//
// FSM: S_IDLE → S_COLLECT(216 words) → S_WAIT_SCR(scrambler done) → S_DEINT
//   (pipelined read→write) → S_FEED(2-phase: issue buf_deint read, then feed)
//   → S_DRAIN → S_FEED_CRC(284) → S_DONE.  Cycle budget ample (bursts ≥ ms).
// =============================================================================

`default_nettype none

module tetra_ul_sch_f_decoder #(
 parameter SOFT_IN_WIDTH = 8,
 parameter VIT_SOFT_WIDTH = 5,
 parameter N_TX = 432,
 parameter DEINT_A = 103,
 parameter INFO_BITS = 268,
 parameter TAIL = 4,
 parameter MOTHER_LEN = 1152,
 parameter TRELLIS_STAGES = 288
)(
 input wire clk_sys,
 input wire rst_n_sys,
 input wire [31:0] scramb_init_sys,
 input wire signed [SOFT_IN_WIDTH-1:0] soft_bit0_sys,
 input wire signed [SOFT_IN_WIDTH-1:0] soft_bit1_sys,
 input wire soft_valid_sys,
 input wire soft_first_sys,
 input wire soft_last_sys,
 output reg [INFO_BITS-1:0] info_bits_sys,
 output reg info_valid_sys,
 output reg crc_ok_sys,
 output reg [15:0] decodes_attempted_sys,
 output reg [15:0] decodes_ok_sys
);

 wire _unused_ok = &{1'b0, soft_first_sys, soft_last_sys};

localparam integer N_WORDS = N_TX/2;            // 216
localparam integer CRC_LEN = INFO_BITS + 16;    // 284

localparam [3:0] S_IDLE = 4'd0;
localparam [3:0] S_COLLECT = 4'd1;
localparam [3:0] S_WAIT_SCR = 4'd2;
localparam [3:0] S_DEINT = 4'd3;
localparam [3:0] S_FEED = 4'd4;
localparam [3:0] S_DRAIN = 4'd5;
localparam [3:0] S_FEED_CRC = 4'd6;
localparam [3:0] S_DONE = 4'd7;

reg [3:0] state_sys;

// ---------- Counters ----------
reg [7:0]  collect_word_sys;   // 0..N_WORDS
reg [9:0]  deint_addr_sys;     // (a*i) mod N — source soft index
reg [9:0]  deint_i_sys;        // issue index 0..N
reg [9:0]  deint_wr_sys;       // writeback count 0..N
reg [9:0]  vit_stage_sys;
reg [1:0]  vit_g_sys;
reg [9:0]  vit_kept_idx_sys;
reg        feed_phase_sys;     // 0=read-issue, 1=use

// deinterleave pipeline regs (1 stage)
reg        di_v_sys;
reg [9:0]  di_i_sys;
reg        di_addr_lsb_sys;
reg        di_scr_sys;

// ---------- buf_soft : 216×16 BRAM (word = {odd-soft[15:8], even-soft[7:0]}) ----
(* ram_style = "block" *) reg [2*SOFT_IN_WIDTH-1:0] bsoft_mem [0:N_WORDS-1];
reg                       bsoft_we;
reg [7:0]                 bsoft_waddr;
reg [2*SOFT_IN_WIDTH-1:0] bsoft_wdata;
reg [2*SOFT_IN_WIDTH-1:0] bsoft_rq;
wire [7:0] bsoft_rd_w = deint_addr_sys[8:1];     // combinational read word addr
always @(posedge clk_sys) begin
 if (bsoft_we) bsoft_mem[bsoft_waddr] <= bsoft_wdata;
 bsoft_rq <= bsoft_mem[bsoft_rd_w];
end

// ---------- buf_deint : 432×8 BRAM ----------
(* ram_style = "block" *) reg [SOFT_IN_WIDTH-1:0] bdeint_mem [0:N_TX-1];
reg                      bdeint_we;
reg [9:0]                bdeint_waddr;
reg signed [SOFT_IN_WIDTH-1:0] bdeint_wdata;
reg signed [SOFT_IN_WIDTH-1:0] bdeint_rq;
wire [9:0] bdeint_rd_w = vit_kept_idx_sys;        // combinational read addr
always @(posedge clk_sys) begin
 if (bdeint_we) bdeint_mem[bdeint_waddr] <= bdeint_wdata;
 bdeint_rq <= bdeint_mem[bdeint_rd_w];
end

// ---------- Scrambler LFSR (§8.2.5) — scramb_seq flat 1-bit reg ----------
reg [31:0] lfsr_sys;
reg [9:0]  lfsr_cnt_sys;
reg        lfsr_running_sys;
reg [N_TX-1:0] scramb_seq_sys;
wire lfsr_bit_w = (
 lfsr_sys[0] ^ lfsr_sys[6] ^ lfsr_sys[9] ^ lfsr_sys[10] ^
 lfsr_sys[16] ^ lfsr_sys[20] ^ lfsr_sys[21] ^ lfsr_sys[22] ^
 lfsr_sys[24] ^ lfsr_sys[25] ^ lfsr_sys[27] ^ lfsr_sys[28] ^
 lfsr_sys[30] ^ lfsr_sys[31]);

// kept-position test
wire [2:0] mother_pos_lo_w = {vit_stage_sys[0], vit_g_sys};
wire vit_is_kept_w = (mother_pos_lo_w == 3'd0) || (mother_pos_lo_w == 3'd1) ||
 (mother_pos_lo_w == 3'd4);

// soft → unsigned Viterbi soft
localparam [VIT_SOFT_WIDTH-1:0] VIT_CENTER = {1'b1, {(VIT_SOFT_WIDTH-1){1'b0}}};
localparam [VIT_SOFT_WIDTH-1:0] VIT_MAX = {VIT_SOFT_WIDTH{1'b1}};
function [VIT_SOFT_WIDTH-1:0] to_vit_soft;
 input signed [SOFT_IN_WIDTH-1:0] s_in;
 reg signed [SOFT_IN_WIDTH:0] diff_ext;
 begin
 diff_ext = {1'b0, VIT_CENTER} - {s_in[SOFT_IN_WIDTH-1], s_in};
 if (diff_ext < 0) to_vit_soft = {VIT_SOFT_WIDTH{1'b0}};
 else if (diff_ext > VIT_MAX) to_vit_soft = VIT_MAX;
 else to_vit_soft = diff_ext[VIT_SOFT_WIDTH-1:0];
 end
endfunction

// fused descramble on the buf_soft read: pick the byte, apply scramb sign
wire signed [SOFT_IN_WIDTH-1:0] di_byte_w =
 di_addr_lsb_sys ? bsoft_rq[2*SOFT_IN_WIDTH-1:SOFT_IN_WIDTH]
 : bsoft_rq[SOFT_IN_WIDTH-1:0];
wire signed [SOFT_IN_WIDTH-1:0] di_soft_w = di_scr_sys ? -di_byte_w : di_byte_w;

// Viterbi
reg [VIT_SOFT_WIDTH-1:0] vit_soft0_sys, vit_soft1_sys, vit_soft2_sys, vit_soft3_sys;
reg vit_input_valid_sys;
wire vit_decoded_bit_w, vit_decoded_valid_w, vit_block_done_w;
wire [VIT_SOFT_WIDTH-1:0] vit_soft_active_w = vit_is_kept_w ? to_vit_soft(bdeint_rq)
 : VIT_CENTER;
tetra_ul_viterbi_r14 #(.SOFT_WIDTH(VIT_SOFT_WIDTH), .TRACEBACK(32),
 .MAX_STAGES(TRELLIS_STAGES)) u_viterbi (
 .clk_sys(clk_sys), .rst_n_sys(rst_n_sys),
 .soft_bit_0(vit_soft0_sys), .soft_bit_1(vit_soft1_sys),
 .soft_bit_2(vit_soft2_sys), .soft_bit_3(vit_soft3_sys),
 .input_valid(vit_input_valid_sys), .num_stages(TRELLIS_STAGES[8:0]),
 .decoded_bit(vit_decoded_bit_w), .decoded_valid(vit_decoded_valid_w),
 .block_done(vit_block_done_w), .path_metric_min());

reg [CRC_LEN-1:0] vit_out_buf_sys;
reg [9:0] vit_out_cnt_sys;

reg crc_init_sys, crc_data_valid_sys, crc_done_in_sys, crc_data_in_sys;
wire crc_done_w; wire [15:0] crc_out_w; wire crc_ok_w;
tetra_crc16 u_crc16 (.clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .init_sys(crc_init_sys),
 .data_in_sys(crc_data_in_sys), .data_valid_sys(crc_data_valid_sys),
 .done_in_sys(crc_done_in_sys), .crc_out_sys(crc_out_w),
 .crc_valid_sys(crc_done_w), .crc_ok_sys(crc_ok_w));
reg [9:0] crc_fed_cnt_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state_sys <= S_IDLE;
 collect_word_sys <= 8'd0;
 deint_addr_sys <= 10'd0; deint_i_sys <= 10'd0; deint_wr_sys <= 10'd0;
 vit_stage_sys <= 10'd0; vit_g_sys <= 2'd0; vit_kept_idx_sys <= 10'd0;
 feed_phase_sys <= 1'b0;
 di_v_sys <= 1'b0; di_i_sys <= 10'd0; di_addr_lsb_sys <= 1'b0; di_scr_sys <= 1'b0;
 bsoft_we <= 1'b0; bsoft_waddr <= 8'd0; bsoft_wdata <= {2*SOFT_IN_WIDTH{1'b0}};
 bdeint_we <= 1'b0; bdeint_waddr <= 10'd0; bdeint_wdata <= {SOFT_IN_WIDTH{1'b0}};
 vit_input_valid_sys <= 1'b0;
 vit_soft0_sys <= {VIT_SOFT_WIDTH{1'b0}}; vit_soft1_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_soft2_sys <= {VIT_SOFT_WIDTH{1'b0}}; vit_soft3_sys <= {VIT_SOFT_WIDTH{1'b0}};
 vit_out_buf_sys <= {CRC_LEN{1'b0}}; vit_out_cnt_sys <= 10'd0;
 crc_init_sys <= 1'b0; crc_data_valid_sys <= 1'b0; crc_done_in_sys <= 1'b0; crc_data_in_sys <= 1'b0;
 crc_fed_cnt_sys <= 10'd0;
 info_bits_sys <= {INFO_BITS{1'b0}}; info_valid_sys <= 1'b0; crc_ok_sys <= 1'b0;
 decodes_attempted_sys <= 16'd0; decodes_ok_sys <= 16'd0;
 lfsr_sys <= 32'hFFFF_FFFF; lfsr_cnt_sys <= 10'd0; lfsr_running_sys <= 1'b0;
 scramb_seq_sys <= {N_TX{1'b0}};
 end else begin
 vit_input_valid_sys <= 1'b0;
 crc_init_sys <= 1'b0; crc_data_valid_sys <= 1'b0; crc_done_in_sys <= 1'b0;
 info_valid_sys <= 1'b0;
 bsoft_we <= 1'b0;
 bdeint_we <= 1'b0;

 if (lfsr_running_sys && lfsr_cnt_sys < N_TX[9:0]) begin
 scramb_seq_sys[lfsr_cnt_sys] <= lfsr_bit_w;
 lfsr_sys <= {lfsr_bit_w, lfsr_sys[31:1]};
 lfsr_cnt_sys <= lfsr_cnt_sys + 10'd1;
 end

 case (state_sys)
 // -----------------------------------------------------------------
 S_IDLE: begin
 if (soft_valid_sys) begin
 lfsr_sys <= (scramb_init_sys == 32'd0) ? 32'hFFFF_FFFF : scramb_init_sys;
 lfsr_cnt_sys <= 10'd0;
 lfsr_running_sys <= 1'b1;
 decodes_attempted_sys <= decodes_attempted_sys + 16'd1;
 bsoft_we <= 1'b1; bsoft_waddr <= 8'd0;
 bsoft_wdata <= {soft_bit0_sys, soft_bit1_sys};  // word = {odd, even}
 collect_word_sys <= 8'd1;
 state_sys <= S_COLLECT;
 end
 end

 // -----------------------------------------------------------------
 S_COLLECT: begin
 if (soft_valid_sys) begin
 bsoft_we <= 1'b1; bsoft_waddr <= collect_word_sys;
 bsoft_wdata <= {soft_bit0_sys, soft_bit1_sys};
 if (collect_word_sys + 8'd1 >= N_WORDS[7:0]) begin
 state_sys <= S_WAIT_SCR;
 end else begin
 collect_word_sys <= collect_word_sys + 8'd1;
 end
 end
 end

 // -----------------------------------------------------------------
 // scrambler LFSR needs N_TX cycles; collect is only N_WORDS — wait for the
 // full scramb_seq before the permuted-address deinterleave reads it.
 S_WAIT_SCR: begin
 if (lfsr_cnt_sys >= N_TX[9:0]) begin
 deint_addr_sys <= DEINT_A[9:0];   // (a*1) mod N
 deint_i_sys <= 10'd0;
 deint_wr_sys <= 10'd0;
 di_v_sys <= 1'b0;
 state_sys <= S_DEINT;
 end
 end

 // -----------------------------------------------------------------
 // Pipelined (1 stage, combinational read addr bsoft_rd_w = deint_addr>>1):
 // cycle T issues addr(T) → bsoft_rq valid T+1; the writeback at T+1 uses the
 // pipelined di_i/di_addr_lsb/di_scr from T. deint_addr = (a*(i+1)) mod N.
 S_DEINT: begin
 if (di_v_sys) begin
 bdeint_we <= 1'b1;
 bdeint_waddr <= di_i_sys;
 bdeint_wdata <= di_soft_w;
 deint_wr_sys <= deint_wr_sys + 10'd1;
 end
 di_v_sys <= 1'b0;

 if (deint_i_sys < N_TX[9:0]) begin
 di_v_sys <= 1'b1;
 di_i_sys <= deint_i_sys;
 di_addr_lsb_sys <= deint_addr_sys[0];
 di_scr_sys <= scramb_seq_sys[deint_addr_sys];
 deint_i_sys <= deint_i_sys + 10'd1;
 if (deint_addr_sys + DEINT_A[9:0] >= N_TX[9:0])
 deint_addr_sys <= deint_addr_sys + DEINT_A[9:0] - N_TX[9:0];
 else
 deint_addr_sys <= deint_addr_sys + DEINT_A[9:0];
 end

 if (deint_wr_sys + (di_v_sys ? 10'd1 : 10'd0) >= N_TX[9:0]) begin
 state_sys <= S_FEED;
 vit_stage_sys <= 10'd0; vit_g_sys <= 2'd0;
 vit_kept_idx_sys <= 10'd0; feed_phase_sys <= 1'b0;
 end
 end

 // -----------------------------------------------------------------
 // 2-phase feed (combinational read addr bdeint_rd_w = vit_kept_idx):
 // phase 0 issues the read (kept_idx stable) → bdeint_rq valid in phase 1.
 S_FEED: begin
 if (feed_phase_sys == 1'b0) begin
 feed_phase_sys <= 1'b1;            // bdeint_rd_w = kept_idx now → rq next cyc
 end else begin
 case (vit_g_sys)
 2'd0: vit_soft0_sys <= vit_soft_active_w;
 2'd1: vit_soft1_sys <= vit_soft_active_w;
 2'd2: vit_soft2_sys <= vit_soft_active_w;
 2'd3: vit_soft3_sys <= vit_soft_active_w;
 endcase
 if (vit_is_kept_w) vit_kept_idx_sys <= vit_kept_idx_sys + 10'd1;
 feed_phase_sys <= 1'b0;
 if (vit_g_sys == 2'd3) begin
 vit_input_valid_sys <= 1'b1;
 vit_g_sys <= 2'd0;
 if (vit_stage_sys + 10'd1 >= TRELLIS_STAGES[9:0]) begin
 state_sys <= S_DRAIN;
 vit_out_cnt_sys <= 10'd0;
 end else begin
 vit_stage_sys <= vit_stage_sys + 10'd1;
 end
 end else begin
 vit_g_sys <= vit_g_sys + 2'd1;
 end
 end
 end

 // -----------------------------------------------------------------
 S_DRAIN: begin
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
 if (crc_fed_cnt_sys < CRC_LEN[9:0]) begin
 crc_data_in_sys <= vit_out_buf_sys[crc_fed_cnt_sys];
 crc_data_valid_sys <= 1'b1;
 crc_done_in_sys <= (crc_fed_cnt_sys == (CRC_LEN[9:0] - 10'd1));
 crc_fed_cnt_sys <= crc_fed_cnt_sys + 10'd1;
 end else if (crc_done_w) begin
 crc_ok_sys <= crc_ok_w;
 info_bits_sys <= vit_out_buf_sys[INFO_BITS-1:0];
 info_valid_sys <= 1'b1;
 if (crc_ok_w) decodes_ok_sys <= decodes_ok_sys + 16'd1;
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
