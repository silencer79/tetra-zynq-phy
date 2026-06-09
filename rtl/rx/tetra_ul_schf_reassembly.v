// =============================================================================
// tetra_ul_schf_reassembly.v — UL long-SDS multi-fragment accumulator (SCH/F)
// =============================================================================
//
// Joins the MAC-ACCESS(frag=1) start (SCH/HU) with N × MAC-FRAG + MAC-END
// (SCH/F, decoded by tetra_ul_sch_f_decoder) into one TM-SDU body, packed as
// 32-bit words and exposed to SW through a built-in AXI-style read mailbox.
//
// On-air chain (long SDS):
//   MAC-ACCESS(frag=1) SCH/HU → TM-SDU start (frag1_bits[61:0] = on-air 30..91)
//   N × MAC-FRAG       SCH/F   → mac_pdu_type=01, sub=0 → append info[4..267]  (264)
//   MAC-END            SCH/F   → mac_pdu_type=01, sub=1 → append info[10..267] (258)
//
// SELF-FILTERING: only schf_valid & schf_crc_ok & mac_pdu_type==01 is accepted,
// so every captured NUB can be fed (voice bursts crc-fail → ignored).  SEPARATE
// from the air-verified tetra_ul_demand_reassembly (SCH/HU 2-burst) — untouched.
//
// Body packing: body bit b → word[b/32], MSB-first within the word
//   (body[0] = word[0][31], body[31] = word[0][0], body[32] = word[1][31], ...).
//   reass_len_sys is the body length in BITS.
//
// AXI read mailbox (combinational index mux, voice_nub-style):
//   index 0..NWORDS-1 → body word
//   index NWORDS      → {31'b0, valid}
//   index NWORDS+1    → {8'b0, ssi[23:0]}
//   index NWORDS+2    → {15'b0, opt_flag, len_bits[15:0]}
//   valid set on chain-complete, cleared on ack_pulse.
// =============================================================================

`default_nettype none

module tetra_ul_schf_reassembly #(
 parameter integer MAXBITS = 8192,
 parameter integer ADDR_W  = 14,           // bit-length counter width (>log2 MAXBITS)
 parameter integer NWORDS  = 256,          // MAXBITS/32
 parameter integer WADDR_W = 8,            // log2(NWORDS)
 parameter integer SCHF_INFO = 268,
 parameter integer T0_FRAMES_DEFAULT = 4
)(
 input wire clk_sys,
 input wire rst_n_sys,
 input wire [3:0] t0_frames_sys,
 input wire frame_tick_sys,

 // Chain start: MAC-ACCESS(frag=1) from the SCH/HU parser
 input wire frag1_pulse_sys,
 input wire [23:0] frag1_ssi_sys,
 input wire [61:0] frag1_bits_sys,
 input wire frag1_opt_flag_sys,

 // SCH/F decoded continuation fragments
 input wire schf_valid_sys,
 input wire schf_crc_ok_sys,
 input wire [SCHF_INFO-1:0] schf_info_sys,

 // Completion strobe (debug / IRQ)
 output reg reass_valid_pulse_sys,
 output reg [15:0] reass_cnt_sys,
 output reg [15:0] drop_cnt_sys,

 // AXI-style read mailbox
 input wire [8:0] index_sys,
 output reg [31:0] rdata_sys,
 output wire valid_sys,
 input wire ack_pulse_sys
);

localparam [ADDR_W-1:0] WPTR_MAX = MAXBITS[ADDR_W-1:0] - 1'b1;

// Force BRAM (not 8192 flops): registered read + no array-wide reset → SDP BRAM.
// Frees ~8k flops from slice packing (the real impl bottleneck at ~97 % slice).
(* ram_style = "block" *) reg [31:0] word_mem [0:NWORDS-1];

localparam [2:0] S_IDLE  = 3'd0;
localparam [2:0] S_START = 3'd1;
localparam [2:0] S_WAIT  = 3'd2;
localparam [2:0] S_WRITE = 3'd3;
localparam [2:0] S_FLUSH = 3'd4;
localparam [2:0] S_EMIT  = 3'd5;

reg [2:0] state_sys;
reg [ADDR_W-1:0] wptr_sys;        // total bits written
reg [31:0] bit_acc_sys;           // shift accumulator
reg [5:0]  bit_cnt_sys;           // bits in current word (0..31)
reg [WADDR_W-1:0] word_wptr_sys;  // next word index
reg [23:0] cur_ssi_sys;
reg cur_opt_sys;

reg [8:0] frag_src_idx_sys;
reg [8:0] frag_src_end_sys;
reg frag_is_end_sys;
reg [6:0] f1_idx_sys;

reg [3:0] t0_left_sys;
wire [3:0] t0_init_w = (t0_frames_sys == 4'd0) ? T0_FRAMES_DEFAULT[3:0] : t0_frames_sys;

// completion latch + held metadata
reg valid_r_sys;
reg [23:0] done_ssi_sys;
reg [ADDR_W-1:0] done_len_sys;
reg done_opt_sys;
assign valid_sys = valid_r_sys;

// combinational write request (frag1 byte stream OR fragment payload)
reg wr_en;
reg wr_bit;
always @(*) begin
 wr_en  = 1'b0;
 wr_bit = 1'b0;
 case (state_sys)
 S_START: begin wr_en = 1'b1; wr_bit = frag1_bits_sys[61 - f1_idx_sys]; end
 S_WRITE: if (frag_src_idx_sys < frag_src_end_sys && wptr_sys < WPTR_MAX) begin
 wr_en = 1'b1; wr_bit = schf_info_sys[frag_src_idx_sys];
 end
 default: ;
 endcase
end

wire [31:0] acc_next_w = {bit_acc_sys[30:0], wr_bit};

// AXI read mailbox: REGISTERED word read (→ simple-dual-port BRAM) + a
// combinational status mux on the 1-cycle-delayed index. The registered read +
// no array-wide reset is what lets word_mem infer BRAM instead of ~20k LUT of
// flops+mux. SW tolerates the 1-cycle read latency (AXI + CDC already add more).
reg [31:0] word_rd_q;
reg [8:0]  rd_index_q;
// word_mem write port — driven combinationally from the FSM so the memory
// access lives in a RESET-FREE clocked block (async reset on the array blocks
// BRAM inference → 8-4767 "implement RAM in registers"). word_we fires when a
// 32-bit word completes (S_START/S_WRITE) or for the final partial word (S_FLUSH).
reg word_we;
reg [31:0] word_wdata;
always @(*) begin
 word_we    = 1'b0;
 word_wdata = acc_next_w;
 if (wr_en && (bit_cnt_sys == 6'd31)) begin
 word_we = 1'b1;
 end else if (state_sys == S_FLUSH) begin
 word_we = 1'b1;
 word_wdata = bit_acc_sys << (6'd32 - bit_cnt_sys);
 end
end
// SDP BRAM: 1 write port + 1 registered read port, NO async reset → infers BRAM.
always @(posedge clk_sys) begin
 if (word_we) word_mem[word_wptr_sys] <= word_wdata;
 word_rd_q  <= word_mem[index_sys[WADDR_W-1:0]];
 rd_index_q <= index_sys;
end
always @(*) begin
 if (rd_index_q < NWORDS[8:0])
 rdata_sys = word_rd_q;
 else if (rd_index_q == NWORDS[8:0])
 rdata_sys = {31'd0, valid_r_sys};
 else if (rd_index_q == (NWORDS[8:0] + 9'd1))
 rdata_sys = {8'd0, done_ssi_sys};
 else if (rd_index_q == (NWORDS[8:0] + 9'd2))
 rdata_sys = {15'd0, done_opt_sys, {(16-ADDR_W){1'b0}}, done_len_sys};
 else if (rd_index_q == (NWORDS[8:0] + 9'd3))
 rdata_sys = {16'd0, reass_cnt_sys};   // SW erkennt neue Body per cnt-Änderung
 else
 rdata_sys = 32'd0;
end

integer i;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state_sys <= S_IDLE;
 wptr_sys <= {ADDR_W{1'b0}};
 bit_acc_sys <= 32'd0;
 bit_cnt_sys <= 6'd0;
 word_wptr_sys <= {WADDR_W{1'b0}};
 cur_ssi_sys <= 24'd0;
 cur_opt_sys <= 1'b0;
 frag_src_idx_sys <= 9'd0;
 frag_src_end_sys <= 9'd0;
 frag_is_end_sys <= 1'b0;
 f1_idx_sys <= 7'd0;
 t0_left_sys <= 4'd0;
 reass_valid_pulse_sys <= 1'b0;
 reass_cnt_sys <= 16'd0;
 drop_cnt_sys <= 16'd0;
 valid_r_sys <= 1'b0;
 done_ssi_sys <= 24'd0;
 done_len_sys <= {ADDR_W{1'b0}};
 done_opt_sys <= 1'b0;
 // NOTE: word_mem is intentionally NOT reset — an array-wide async clear
 // forces flops (blocks BRAM inference). Content is overwritten before use;
 // valid_r_sys gates SW access. (LUT 20k → BRAM after this + registered read.)
 end else begin
 reass_valid_pulse_sys <= 1'b0;

 // valid latch: set on EMIT (below), cleared on SW ack
 if (ack_pulse_sys) valid_r_sys <= 1'b0;

 // shared bit-write: shift into the current word; store on 32
 if (wr_en) begin
 bit_acc_sys <= acc_next_w;
 wptr_sys <= wptr_sys + 1'b1;
 if (bit_cnt_sys == 6'd31) begin
 word_wptr_sys <= word_wptr_sys + 1'b1;   // word write happens in the BRAM block
 bit_cnt_sys <= 6'd0;
 end else begin
 bit_cnt_sys <= bit_cnt_sys + 6'd1;
 end
 end

 if (frame_tick_sys && (state_sys == S_WAIT) && (t0_left_sys != 4'd0))
 t0_left_sys <= t0_left_sys - 4'd1;

 case (state_sys)
 // -----------------------------------------------------------------
 S_IDLE: begin
 if (frag1_pulse_sys) begin
 cur_ssi_sys <= frag1_ssi_sys;
 cur_opt_sys <= frag1_opt_flag_sys;
 wptr_sys <= {ADDR_W{1'b0}};
 bit_acc_sys <= 32'd0;
 bit_cnt_sys <= 6'd0;
 word_wptr_sys <= {WADDR_W{1'b0}};
 f1_idx_sys <= 7'd0;
 state_sys <= S_START;
 end
 end

 // write frag1 62 bits (wr_en drives the shared bit-write above)
 S_START: begin
 if (f1_idx_sys == 7'd61) begin
 state_sys <= S_WAIT;
 t0_left_sys <= t0_init_w;
 end else begin
 f1_idx_sys <= f1_idx_sys + 7'd1;
 end
 end

 // -----------------------------------------------------------------
 S_WAIT: begin
 if (frag1_pulse_sys) begin            // MS retransmitted the start
 cur_ssi_sys <= frag1_ssi_sys;
 cur_opt_sys <= frag1_opt_flag_sys;
 wptr_sys <= {ADDR_W{1'b0}};
 bit_acc_sys <= 32'd0;
 bit_cnt_sys <= 6'd0;
 word_wptr_sys <= {WADDR_W{1'b0}};
 f1_idx_sys <= 7'd0;
 state_sys <= S_START;
 end
 else if (schf_valid_sys && schf_crc_ok_sys
 && (schf_info_sys[0] == 1'b0) && (schf_info_sys[1] == 1'b1)) begin
 // mac_pdu_type = {info[0],info[1]} = 01 → MAC-FRAG/END.
 // (SCH/F carries no SSI; reserved-slot ownership is implicit.)
 frag_is_end_sys <= schf_info_sys[2];
 frag_src_idx_sys <= schf_info_sys[2] ? 9'd10 : 9'd4;
 frag_src_end_sys <= SCHF_INFO[8:0];
 t0_left_sys <= t0_init_w;
 state_sys <= S_WRITE;
 end
 else if (t0_left_sys == 4'd0 && !frame_tick_sys) begin
 drop_cnt_sys <= drop_cnt_sys + 16'd1;
 state_sys <= S_IDLE;
 end
 end

 // append fragment payload (wr_en drives the shared bit-write)
 S_WRITE: begin
 frag_src_idx_sys <= frag_src_idx_sys + 9'd1;
 if (!(frag_src_idx_sys < frag_src_end_sys && wptr_sys < WPTR_MAX)) begin
 // done writing this fragment
 if (frag_is_end_sys)
 state_sys <= (bit_cnt_sys != 6'd0) ? S_FLUSH : S_EMIT;
 else
 state_sys <= S_WAIT;
 end
 end

 // flush the final partial word (the BRAM block writes it via word_we)
 S_FLUSH: begin
 state_sys <= S_EMIT;
 end

 // -----------------------------------------------------------------
 S_EMIT: begin
 reass_valid_pulse_sys <= 1'b1;
 valid_r_sys <= 1'b1;
 done_ssi_sys <= cur_ssi_sys;
 done_len_sys <= wptr_sys;
 done_opt_sys <= cur_opt_sys;
 reass_cnt_sys <= reass_cnt_sys + 16'd1;
 state_sys <= S_IDLE;
 end

 default: state_sys <= S_IDLE;
 endcase
 end
end

endmodule

`default_nettype wire
