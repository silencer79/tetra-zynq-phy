// =============================================================================
// tetra_ul_viterbi_r14_bram.v — K=5 r1/4 soft Viterbi, BRAM survivor variant
// =============================================================================
// Functionally identical to tetra_ul_viterbi_r14 (same ETSI generators, ACS,
// argmin, "start traceback at state 0") — but the survivor memory lives in a
// MAX_STAGES×16 simple-dual-port BRAM instead of 16×MAX_STAGES flops with
// variable-index muxes.  At MAX_STAGES=288 (SCH/F) the flop version was the
// slice/timing bottleneck (16:1-of-288-bit + 288:1 traceback muxes, 4608 FF →
// 99.92% slice / WNS -0.716ns).  BRAM frees those flops + kills the muxes.
//
// Survivor BRAM: word[stage] = {surv_15..surv_0} (the 16 ACS decisions of that
// stage).  Sequential write during ACS; registered read during traceback.  The
// traceback feedback loop (tb_state → stage → read → surv_bit → tb_state) gets a
// 1-cycle BRAM read latency, so S_TRACEBACK runs 2 cycles/stage (tb_phase).
//
// Used by tetra_ul_sch_f_decoder.  tetra_ul_viterbi_r14 (the flop version) is
// unchanged and still used by the air-verified SCH/HU decoder.
// =============================================================================

`default_nettype none

module tetra_ul_viterbi_r14_bram #(
 parameter SOFT_WIDTH = 3,
 parameter TRACEBACK = 32,
 parameter MAX_STAGES = 436
)(
 input wire clk_sys,
 input wire rst_n_sys,
 input wire [SOFT_WIDTH-1:0] soft_bit_0,
 input wire [SOFT_WIDTH-1:0] soft_bit_1,
 input wire [SOFT_WIDTH-1:0] soft_bit_2,
 input wire [SOFT_WIDTH-1:0] soft_bit_3,
 input wire input_valid,
 input wire [8:0] num_stages,
 output reg decoded_bit,
 output reg decoded_valid,
 output reg block_done,
 output wire [15:0] path_metric_min
);

 localparam K = 5;
 localparam TAIL = K - 1;
 localparam [SOFT_WIDTH-1:0] SOFT_MAX = {SOFT_WIDTH{1'b1}};
 localparam integer BM_BITS = SOFT_WIDTH + 2;
 localparam [BM_BITS-1:0] BM_MAX = {BM_BITS{1'b0}} | (4 * SOFT_MAX);
 localparam integer BM_PAD_HI = 16 - BM_BITS;

 localparam [2:0] S_IDLE = 3'd0;
 localparam [2:0] S_ACS = 3'd1;
 localparam [2:0] S_TB_INIT = 3'd2;
 localparam [2:0] S_TRACEBACK = 3'd3;
 localparam [2:0] S_OUTPUT = 3'd4;

 reg [2:0] state_sys;
 reg [2:0] next_state_sys;
 reg       tb_phase_sys;   // 0 = read-issue, 1 = use (BRAM read latency)

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) state_sys <= S_IDLE;
 else state_sys <= next_state_sys;
 end

 reg [8:0] stage_cnt_sys;

 wire acs_done_sys = (state_sys == S_ACS)
 && input_valid
 && (stage_cnt_sys == num_stages - 9'd1);
 wire tb_done_sys = (state_sys == S_TRACEBACK)
 && (tb_phase_sys == 1'b1)
 && (stage_cnt_sys == num_stages - 9'd1);
 wire out_done_sys = (state_sys == S_OUTPUT)
 && (stage_cnt_sys == num_stages - TAIL - 9'd1);

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) tb_phase_sys <= 1'b0;
 else if (state_sys == S_TB_INIT) tb_phase_sys <= 1'b0;
 else if (state_sys == S_TRACEBACK) tb_phase_sys <= ~tb_phase_sys;
 end

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) stage_cnt_sys <= 9'd0;
 else case (state_sys)
 S_IDLE:
 if (input_valid) stage_cnt_sys <= 9'd1;
 S_ACS:
 if (input_valid)
 stage_cnt_sys <= acs_done_sys ? 9'd0: stage_cnt_sys + 9'd1;
 S_TB_INIT: stage_cnt_sys <= 9'd0;
 S_TRACEBACK:
 if (tb_phase_sys == 1'b1)   // advance only on the USE phase
 stage_cnt_sys <= tb_done_sys ? 9'd0: stage_cnt_sys + 9'd1;
 S_OUTPUT:
 stage_cnt_sys <= out_done_sys ? 9'd0: stage_cnt_sys + 9'd1;
 default: stage_cnt_sys <= 9'd0;
 endcase
 end

 // verilator lint_off CASEINCOMPLETE
 always @(*) begin
 next_state_sys = state_sys;
 case (state_sys)
 S_IDLE: if (input_valid) next_state_sys = S_ACS;
 S_ACS: if (acs_done_sys) next_state_sys = S_TB_INIT;
 S_TB_INIT: next_state_sys = S_TRACEBACK;
 S_TRACEBACK: if (tb_done_sys) next_state_sys = S_OUTPUT;
 S_OUTPUT: if (out_done_sys) next_state_sys = S_IDLE;
 default: next_state_sys = S_IDLE;
 endcase
 end
 // verilator lint_on CASEINCOMPLETE

 // =========================================================================
 // ACS — identical to tetra_ul_viterbi_r14
 // =========================================================================
 reg [255:0] pm_flat_sys;

 genvar s;
 generate
 for (s = 0; s < 16; s = s + 1) begin: g_acs
 localparam P0 = (s >> 1);
 localparam P1 = (s >> 1) | 4'd8;
 localparam G1P0 = ((s >> 0) ^ (s >> 1)) & 1;
 localparam G2P0 = ((s >> 0) ^ (s >> 2) ^ (s >> 3)) & 1;
 localparam G3P0 = ((s >> 0) ^ (s >> 1) ^ (s >> 2)) & 1;
 localparam G4P0 = ((s >> 0) ^ (s >> 1) ^ (s >> 3)) & 1;

 wire [BM_BITS-1:0] bm0_w =
 ({{2{1'b0}}, G1P0[0] ? (SOFT_MAX - soft_bit_0): soft_bit_0}) +
 ({{2{1'b0}}, G2P0[0] ? (SOFT_MAX - soft_bit_1): soft_bit_1}) +
 ({{2{1'b0}}, G3P0[0] ? (SOFT_MAX - soft_bit_2): soft_bit_2}) +
 ({{2{1'b0}}, G4P0[0] ? (SOFT_MAX - soft_bit_3): soft_bit_3});
 wire [BM_BITS-1:0] bm1_w = BM_MAX - bm0_w;

 wire [16:0] cost0_w = {1'b0, pm_flat_sys[P0*16 +: 16]} + {{BM_PAD_HI{1'b0}}, bm0_w};
 wire [16:0] cost1_w = {1'b0, pm_flat_sys[P1*16 +: 16]} + {{BM_PAD_HI{1'b0}}, bm1_w};

 wire surv_w = (cost1_w < cost0_w) ? 1'b1: 1'b0;
 wire [16:0] raw_w = surv_w ? cost1_w: cost0_w;
 end
 endgenerate

 generate
 for (s = 0; s < 16; s = s + 1) begin: g_sat
 wire [15:0] raw_sat_w = g_acs[s].raw_w[16] ? 16'hFFFF: g_acs[s].raw_w[15:0];
 end
 endgenerate

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
 end else if (state_sys == S_TB_INIT) begin
 pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
 end else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid) begin
 pm_flat_sys[ 15: 0] <= g_sat[0].raw_sat_w;
 pm_flat_sys[ 31: 16] <= g_sat[1].raw_sat_w;
 pm_flat_sys[ 47: 32] <= g_sat[2].raw_sat_w;
 pm_flat_sys[ 63: 48] <= g_sat[3].raw_sat_w;
 pm_flat_sys[ 79: 64] <= g_sat[4].raw_sat_w;
 pm_flat_sys[ 95: 80] <= g_sat[5].raw_sat_w;
 pm_flat_sys[111: 96] <= g_sat[6].raw_sat_w;
 pm_flat_sys[127:112] <= g_sat[7].raw_sat_w;
 pm_flat_sys[143:128] <= g_sat[8].raw_sat_w;
 pm_flat_sys[159:144] <= g_sat[9].raw_sat_w;
 pm_flat_sys[175:160] <= g_sat[10].raw_sat_w;
 pm_flat_sys[191:176] <= g_sat[11].raw_sat_w;
 pm_flat_sys[207:192] <= g_sat[12].raw_sat_w;
 pm_flat_sys[223:208] <= g_sat[13].raw_sat_w;
 pm_flat_sys[239:224] <= g_sat[14].raw_sat_w;
 pm_flat_sys[255:240] <= g_sat[15].raw_sat_w;
 end
 end

 // path-metric min (output only; traceback starts at state 0 per ETSI tail)
 wire [15:0] pm0 = pm_flat_sys[ 15: 0]; wire [15:0] pm1 = pm_flat_sys[ 31: 16];
 wire [15:0] pm2 = pm_flat_sys[ 47: 32]; wire [15:0] pm3 = pm_flat_sys[ 63: 48];
 wire [15:0] pm4 = pm_flat_sys[ 79: 64]; wire [15:0] pm5 = pm_flat_sys[ 95: 80];
 wire [15:0] pm6 = pm_flat_sys[111: 96]; wire [15:0] pm7 = pm_flat_sys[127:112];
 wire [15:0] pm8 = pm_flat_sys[143:128]; wire [15:0] pm9 = pm_flat_sys[159:144];
 wire [15:0] pm10= pm_flat_sys[175:160]; wire [15:0] pm11= pm_flat_sys[191:176];
 wire [15:0] pm12= pm_flat_sys[207:192]; wire [15:0] pm13= pm_flat_sys[223:208];
 wire [15:0] pm14= pm_flat_sys[239:224]; wire [15:0] pm15= pm_flat_sys[255:240];
 wire [15:0] vmin0 = (pm0<=pm1)?pm0:pm1;     wire [15:0] vmin1 = (pm2<=pm3)?pm2:pm3;
 wire [15:0] vmin2 = (pm4<=pm5)?pm4:pm5;     wire [15:0] vmin3 = (pm6<=pm7)?pm6:pm7;
 wire [15:0] vmin4 = (pm8<=pm9)?pm8:pm9;     wire [15:0] vmin5 = (pm10<=pm11)?pm10:pm11;
 wire [15:0] vmin6 = (pm12<=pm13)?pm12:pm13; wire [15:0] vmin7 = (pm14<=pm15)?pm14:pm15;
 wire [15:0] vq0=(vmin0<=vmin1)?vmin0:vmin1; wire [15:0] vq1=(vmin2<=vmin3)?vmin2:vmin3;
 wire [15:0] vq2=(vmin4<=vmin5)?vmin4:vmin5; wire [15:0] vq3=(vmin6<=vmin7)?vmin6:vmin7;
 wire [15:0] vh0=(vq0<=vq1)?vq0:vq1;         wire [15:0] vh1=(vq2<=vq3)?vq2:vq3;
 assign path_metric_min = (vh0<=vh1)?vh0:vh1;

 // =========================================================================
 // Survivor BRAM — word[stage] = {surv_15..surv_0}
 // =========================================================================
 wire [15:0] surv_wdata_w;
 genvar sw;
 generate for (sw = 0; sw < 16; sw = sw + 1) begin: g_survwd
 assign surv_wdata_w[sw] = g_acs[sw].surv_w;
 end endgenerate

 wire surv_we_w = (state_sys == S_IDLE || state_sys == S_ACS) && input_valid;

 reg [3:0] tb_state_sys;
 wire [8:0] tb_stage_w = num_stages - 9'd1 - stage_cnt_sys;   // combinational read addr

 (* ram_style = "block" *) reg [15:0] surv_mem [0:MAX_STAGES-1];
 reg [15:0] surv_rq;
 always @(posedge clk_sys) begin
 if (surv_we_w) surv_mem[stage_cnt_sys] <= surv_wdata_w;
 surv_rq <= surv_mem[tb_stage_w];
 end

 // survivor decision for the current traceback state (valid in the USE phase)
 wire tb_surv_bit_w = surv_rq[tb_state_sys];

 // =========================================================================
 // Traceback — 2-phase (phase 0 issued the read; phase 1 uses surv_rq)
 // =========================================================================
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) tb_state_sys <= 4'd0;
 else if (state_sys == S_TB_INIT) tb_state_sys <= 4'd0;
 else if (state_sys == S_TRACEBACK && tb_phase_sys == 1'b1)
 tb_state_sys <= {tb_surv_bit_w, tb_state_sys[3:1]};
 end

 reg [MAX_STAGES-1:0] out_buf_sys;
 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) out_buf_sys <= {MAX_STAGES{1'b0}};
 else if (state_sys == S_TRACEBACK && tb_phase_sys == 1'b1)
 out_buf_sys[tb_stage_w] <= tb_state_sys[0];
 end

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) decoded_bit <= 1'b0;
 else if (state_sys == S_OUTPUT)
 decoded_bit <= out_buf_sys[stage_cnt_sys];
 end

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) decoded_valid <= 1'b0;
 else decoded_valid <= (state_sys == S_OUTPUT);
 end

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) block_done <= 1'b0;
 else block_done <= out_done_sys;
 end

endmodule

`default_nettype wire
