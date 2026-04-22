// =============================================================================
// tetra_ul_viterbi_r14.v — ETSI-convention K=5 Rate-1/4 Soft Viterbi Decoder
// =============================================================================
// ETSI EN 300 392-2 §8.2.3.1.1 mother code.
// Generators (shift-left, input @ LSB of sr = {old[3:0], b}):
//   G1 = 0x13 = 10011 → taps {0,1,4} → b ^ old[0] ^ old[3]
//   G2 = 0x1D = 11101 → taps {0,2,3,4} → b ^ old[1] ^ old[2] ^ old[3]
//   G3 = 0x17 = 10111 → taps {0,1,2,4} → b ^ old[0] ^ old[1] ^ old[3]
//   G4 = 0x1B = 11011 → taps {0,1,3,4} → b ^ old[0] ^ old[2] ^ old[3]
//
// State encoding: state[3:0] = last 4 input bits, state[0]=newest, state[3]=oldest.
// Forward transition: new_state = ((old_state << 1) | input) & 0xF.
// For a new_state s:
//   input = s[0]
//   prev0 = s >> 1         (old[3] was 0)
//   prev1 = (s >> 1) | 8   (old[3] was 1)
//   old[3] bit is lost on shift — equals s's predecessor-LSB selector.
// Generators in new_state coords (with old[3]=0 for P0, =1 for P1):
//   G1_P0 = s[0] ^ s[1]                   // old[0] = s[1]
//   G2_P0 = s[0] ^ s[2] ^ s[3]
//   G3_P0 = s[0] ^ s[1] ^ s[2]
//   G4_P0 = s[0] ^ s[1] ^ s[3]
// G?_P1 = ~G?_P0.
//
// Traceback: decoded_bit at stage T = tb_state[0] (the input bit that produced
// that state). Walk back: prev = {surv, tb_state[3:1]}.
//
// Mirrors canonical reference implementation (viterbi_r14_soft in
// scripts/decode_dl.py) which decodes real ETSI-encoded signals.
//
// FSM: identical to tetra_viterbi_decoder.v
//   S_IDLE → S_ACS → S_TB_INIT → S_TRACEBACK → S_OUTPUT → S_IDLE
//
// Soft-decision: 3-bit unsigned. 0=strong 0, 7=strong 1, 4=erasure.
// =============================================================================

`default_nettype none

module tetra_ul_viterbi_r14 #(
    parameter SOFT_WIDTH = 3,
    parameter TRACEBACK  = 32,
    parameter MAX_STAGES = 436
)(
    input  wire                  clk_sys,
    input  wire                  rst_n_sys,
    input  wire [SOFT_WIDTH-1:0] soft_bit_0,   // G1 channel (ETSI)
    input  wire [SOFT_WIDTH-1:0] soft_bit_1,   // G2 channel
    input  wire [SOFT_WIDTH-1:0] soft_bit_2,   // G3 channel
    input  wire [SOFT_WIDTH-1:0] soft_bit_3,   // G4 channel
    input  wire                  input_valid,
    input  wire [8:0]            num_stages,
    output reg                   decoded_bit,
    output reg                   decoded_valid,
    output reg                   block_done,
    output wire [15:0]           path_metric_min
);

    localparam K    = 5;
    localparam TAIL = K - 1;
    localparam [SOFT_WIDTH-1:0] SOFT_MAX = {SOFT_WIDTH{1'b1}};   // e.g. 3'd7 / 4'd15
    localparam integer          BM_BITS  = SOFT_WIDTH + 2;       // 4·SOFT_MAX fits
    localparam [BM_BITS-1:0]    BM_MAX   = {BM_BITS{1'b0}} | (4 * SOFT_MAX);
    localparam integer          BM_PAD_HI = 16 - BM_BITS;        // to pad into 17-bit cost

    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_ACS       = 3'd1;
    localparam [2:0] S_TB_INIT   = 3'd2;
    localparam [2:0] S_TRACEBACK = 3'd3;
    localparam [2:0] S_OUTPUT    = 3'd4;

    reg [2:0] state_sys;
    reg [2:0] next_state_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) state_sys <= S_IDLE;
        else            state_sys <= next_state_sys;
    end

    reg [8:0] stage_cnt_sys;

    wire acs_done_sys = (state_sys == S_ACS)
                        && input_valid
                        && (stage_cnt_sys == num_stages - 9'd1);
    wire tb_done_sys  = (state_sys == S_TRACEBACK)
                        && (stage_cnt_sys == num_stages - 9'd1);
    wire out_done_sys = (state_sys == S_OUTPUT)
                        && (stage_cnt_sys == num_stages - TAIL - 9'd1);

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) stage_cnt_sys <= 9'd0;
        else case (state_sys)
            S_IDLE:
                if (input_valid) stage_cnt_sys <= 9'd1;
            S_ACS:
                if (input_valid)
                    stage_cnt_sys <= acs_done_sys ? 9'd0 : stage_cnt_sys + 9'd1;
            S_TB_INIT:   stage_cnt_sys <= 9'd0;
            S_TRACEBACK:
                stage_cnt_sys <= tb_done_sys ? 9'd0 : stage_cnt_sys + 9'd1;
            S_OUTPUT:
                stage_cnt_sys <= out_done_sys ? 9'd0 : stage_cnt_sys + 9'd1;
            default: stage_cnt_sys <= 9'd0;
        endcase
    end

    // verilator lint_off CASEINCOMPLETE
    always @(*) begin
        next_state_sys = state_sys;
        case (state_sys)
            S_IDLE:      if (input_valid)   next_state_sys = S_ACS;
            S_ACS:       if (acs_done_sys)  next_state_sys = S_TB_INIT;
            S_TB_INIT:                      next_state_sys = S_TRACEBACK;
            S_TRACEBACK: if (tb_done_sys)   next_state_sys = S_OUTPUT;
            S_OUTPUT:    if (out_done_sys)  next_state_sys = S_IDLE;
            default:                        next_state_sys = S_IDLE;
        endcase
    end
    // verilator lint_on CASEINCOMPLETE

    // =========================================================================
    // ACS — ETSI convention: P0 = s>>1, P1 = (s>>1)|8, input = s[0]
    // G_P0 formulas:
    //   G1_P0 = s[0]^s[1]
    //   G2_P0 = s[0]^s[2]^s[3]
    //   G3_P0 = s[0]^s[1]^s[2]
    //   G4_P0 = s[0]^s[1]^s[3]
    // =========================================================================
    reg [255:0] pm_flat_sys;

    genvar s;
    generate
    for (s = 0; s < 16; s = s + 1) begin : g_acs
        localparam P0   = (s >> 1);
        localparam P1   = (s >> 1) | 4'd8;
        localparam G1P0 = ((s >> 0) ^ (s >> 1)) & 1;                // s[0]^s[1]
        localparam G2P0 = ((s >> 0) ^ (s >> 2) ^ (s >> 3)) & 1;     // s[0]^s[2]^s[3]
        localparam G3P0 = ((s >> 0) ^ (s >> 1) ^ (s >> 2)) & 1;     // s[0]^s[1]^s[2]
        localparam G4P0 = ((s >> 0) ^ (s >> 1) ^ (s >> 3)) & 1;     // s[0]^s[1]^s[3]

        wire [BM_BITS-1:0] bm0_w =
            ({{2{1'b0}}, G1P0[0] ? (SOFT_MAX - soft_bit_0) : soft_bit_0}) +
            ({{2{1'b0}}, G2P0[0] ? (SOFT_MAX - soft_bit_1) : soft_bit_1}) +
            ({{2{1'b0}}, G3P0[0] ? (SOFT_MAX - soft_bit_2) : soft_bit_2}) +
            ({{2{1'b0}}, G4P0[0] ? (SOFT_MAX - soft_bit_3) : soft_bit_3});
        wire [BM_BITS-1:0] bm1_w = BM_MAX - bm0_w;

        wire [16:0] cost0_w = {1'b0, pm_flat_sys[P0*16 +: 16]} + {{BM_PAD_HI{1'b0}}, bm0_w};
        wire [16:0] cost1_w = {1'b0, pm_flat_sys[P1*16 +: 16]} + {{BM_PAD_HI{1'b0}}, bm1_w};

        wire        surv_w  = (cost1_w < cost0_w) ? 1'b1 : 1'b0;
        wire [16:0] raw_w   = surv_w ? cost1_w : cost0_w;
    end
    endgenerate

    generate
    for (s = 0; s < 16; s = s + 1) begin : g_sat
        // Per-stage normalization is not required here: even MAX_STAGES worst-case
        // branch accumulation stays well below 16 bits, so we can keep the ACS
        // feedback local to each state and only saturate invalid/infinite metrics.
        wire [15:0] raw_sat_w = g_acs[s].raw_w[16] ? 16'hFFFF : g_acs[s].raw_w[15:0];
    end
    endgenerate

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
        end else if (state_sys == S_OUTPUT && out_done_sys) begin
            pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
        end else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid) begin
            pm_flat_sys[  15:  0] <= g_sat[0].raw_sat_w;
            pm_flat_sys[  31: 16] <= g_sat[1].raw_sat_w;
            pm_flat_sys[  47: 32] <= g_sat[2].raw_sat_w;
            pm_flat_sys[  63: 48] <= g_sat[3].raw_sat_w;
            pm_flat_sys[  79: 64] <= g_sat[4].raw_sat_w;
            pm_flat_sys[  95: 80] <= g_sat[5].raw_sat_w;
            pm_flat_sys[ 111: 96] <= g_sat[6].raw_sat_w;
            pm_flat_sys[ 127:112] <= g_sat[7].raw_sat_w;
            pm_flat_sys[ 143:128] <= g_sat[8].raw_sat_w;
            pm_flat_sys[ 159:144] <= g_sat[9].raw_sat_w;
            pm_flat_sys[ 175:160] <= g_sat[10].raw_sat_w;
            pm_flat_sys[ 191:176] <= g_sat[11].raw_sat_w;
            pm_flat_sys[ 207:192] <= g_sat[12].raw_sat_w;
            pm_flat_sys[ 223:208] <= g_sat[13].raw_sat_w;
            pm_flat_sys[ 239:224] <= g_sat[14].raw_sat_w;
            pm_flat_sys[ 255:240] <= g_sat[15].raw_sat_w;
        end
    end

    // Path metric slices
    wire [15:0] pm0  = pm_flat_sys[  15:  0];
    wire [15:0] pm1  = pm_flat_sys[  31: 16];
    wire [15:0] pm2  = pm_flat_sys[  47: 32];
    wire [15:0] pm3  = pm_flat_sys[  63: 48];
    wire [15:0] pm4  = pm_flat_sys[  79: 64];
    wire [15:0] pm5  = pm_flat_sys[  95: 80];
    wire [15:0] pm6  = pm_flat_sys[ 111: 96];
    wire [15:0] pm7  = pm_flat_sys[ 127:112];
    wire [15:0] pm8  = pm_flat_sys[ 143:128];
    wire [15:0] pm9  = pm_flat_sys[ 159:144];
    wire [15:0] pm10 = pm_flat_sys[ 175:160];
    wire [15:0] pm11 = pm_flat_sys[ 191:176];
    wire [15:0] pm12 = pm_flat_sys[ 207:192];
    wire [15:0] pm13 = pm_flat_sys[ 223:208];
    wire [15:0] pm14 = pm_flat_sys[ 239:224];
    wire [15:0] pm15 = pm_flat_sys[ 255:240];

    // =========================================================================
    // Survivor storage — 16 x MAX_STAGES bits
    // =========================================================================
    reg [MAX_STAGES-1:0] surv_s0,  surv_s1,  surv_s2,  surv_s3;
    reg [MAX_STAGES-1:0] surv_s4,  surv_s5,  surv_s6,  surv_s7;
    reg [MAX_STAGES-1:0] surv_s8,  surv_s9,  surv_s10, surv_s11;
    reg [MAX_STAGES-1:0] surv_s12, surv_s13, surv_s14, surv_s15;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s0  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s0[stage_cnt_sys]  <= g_acs[0].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s1  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s1[stage_cnt_sys]  <= g_acs[1].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s2  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s2[stage_cnt_sys]  <= g_acs[2].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s3  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s3[stage_cnt_sys]  <= g_acs[3].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s4  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s4[stage_cnt_sys]  <= g_acs[4].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s5  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s5[stage_cnt_sys]  <= g_acs[5].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s6  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s6[stage_cnt_sys]  <= g_acs[6].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s7  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s7[stage_cnt_sys]  <= g_acs[7].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s8  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s8[stage_cnt_sys]  <= g_acs[8].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s9  <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s9[stage_cnt_sys]  <= g_acs[9].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s10 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s10[stage_cnt_sys] <= g_acs[10].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s11 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s11[stage_cnt_sys] <= g_acs[11].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s12 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s12[stage_cnt_sys] <= g_acs[12].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s13 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s13[stage_cnt_sys] <= g_acs[13].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s14 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s14[stage_cnt_sys] <= g_acs[14].surv_w;
    end
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) surv_s15 <= {MAX_STAGES{1'b0}};
        else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid)
            surv_s15[stage_cnt_sys] <= g_acs[15].surv_w;
    end

    // =========================================================================
    // Argmin
    // =========================================================================
    wire        cmp01   = (pm0  <= pm1);
    wire [3:0]  idx01   = cmp01  ? 4'd0  : 4'd1;
    wire [15:0] val01   = cmp01  ? pm0   : pm1;

    wire        cmp23   = (pm2  <= pm3);
    wire [3:0]  idx23   = cmp23  ? 4'd2  : 4'd3;
    wire [15:0] val23   = cmp23  ? pm2   : pm3;

    wire        cmp45   = (pm4  <= pm5);
    wire [3:0]  idx45   = cmp45  ? 4'd4  : 4'd5;
    wire [15:0] val45   = cmp45  ? pm4   : pm5;

    wire        cmp67   = (pm6  <= pm7);
    wire [3:0]  idx67   = cmp67  ? 4'd6  : 4'd7;
    wire [15:0] val67   = cmp67  ? pm6   : pm7;

    wire        cmp89   = (pm8  <= pm9);
    wire [3:0]  idx89   = cmp89  ? 4'd8  : 4'd9;
    wire [15:0] val89   = cmp89  ? pm8   : pm9;

    wire        cmpAB   = (pm10 <= pm11);
    wire [3:0]  idxAB   = cmpAB  ? 4'd10 : 4'd11;
    wire [15:0] valAB   = cmpAB  ? pm10  : pm11;

    wire        cmpCD   = (pm12 <= pm13);
    wire [3:0]  idxCD   = cmpCD  ? 4'd12 : 4'd13;
    wire [15:0] valCD   = cmpCD  ? pm12  : pm13;

    wire        cmpEF   = (pm14 <= pm15);
    wire [3:0]  idxEF   = cmpEF  ? 4'd14 : 4'd15;
    wire [15:0] valEF   = cmpEF  ? pm14  : pm15;

    wire        cmp0123 = (val01 <= val23);
    wire [3:0]  idx0123 = cmp0123 ? idx01 : idx23;
    wire [15:0] val0123 = cmp0123 ? val01 : val23;

    wire        cmp4567 = (val45 <= val67);
    wire [3:0]  idx4567 = cmp4567 ? idx45 : idx67;
    wire [15:0] val4567 = cmp4567 ? val45 : val67;

    wire        cmp89AB = (val89 <= valAB);
    wire [3:0]  idx89AB = cmp89AB ? idx89 : idxAB;
    wire [15:0] val89AB = cmp89AB ? val89 : valAB;

    wire        cmpCDEF = (valCD <= valEF);
    wire [3:0]  idxCDEF = cmpCDEF ? idxCD : idxEF;
    wire [15:0] valCDEF = cmpCDEF ? valCD : valEF;

    wire        cmp07   = (val0123 <= val4567);
    wire [3:0]  idx07   = cmp07 ? idx0123 : idx4567;
    wire [15:0] val07   = cmp07 ? val0123 : val4567;

    wire        cmp8F   = (val89AB <= valCDEF);
    wire [3:0]  idx8F   = cmp8F ? idx89AB : idxCDEF;
    wire [15:0] val8F   = cmp8F ? val89AB : valCDEF;

    assign path_metric_min = (val07 <= val8F) ? val07 : val8F;
    wire [3:0]  best_state_w = (val07 <= val8F) ? idx07 : idx8F;

    // =========================================================================
    // Traceback — ETSI convention
    //   forward  : new_state = ((old << 1) | input) & 0xF
    //   backward : prev_state = {surv, new_state[3:1]} = (new >> 1) | (surv << 3)
    //   decoded_bit at stage T = new_state[0] at that stage
    //
    // Block is terminated with K-1=4 tail bits of 0, so the final state MUST
    // be state 0. Using argmin(pm) is only correct on a converged (noise-free)
    // trellis — real-world noise flips the argmin to a non-zero state and the
    // traceback then walks a wrong survivor path. Always start at state 0.
    // =========================================================================
    reg [3:0] tb_state_sys;
    wire [3:0] best_state_unused_w = best_state_w;  // kept for VCD visibility

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) tb_state_sys <= 4'd0;
        else if (state_sys == S_TB_INIT)
            tb_state_sys <= 4'd0;
        else if (state_sys == S_TRACEBACK)
            tb_state_sys <= {tb_surv_bit_w, tb_state_sys[3:1]};
    end

    wire [8:0] tb_stage_w = num_stages - 9'd1 - stage_cnt_sys;

    wire [MAX_STAGES-1:0] tb_surv_row_w =
        (tb_state_sys == 4'd0)  ? surv_s0  :
        (tb_state_sys == 4'd1)  ? surv_s1  :
        (tb_state_sys == 4'd2)  ? surv_s2  :
        (tb_state_sys == 4'd3)  ? surv_s3  :
        (tb_state_sys == 4'd4)  ? surv_s4  :
        (tb_state_sys == 4'd5)  ? surv_s5  :
        (tb_state_sys == 4'd6)  ? surv_s6  :
        (tb_state_sys == 4'd7)  ? surv_s7  :
        (tb_state_sys == 4'd8)  ? surv_s8  :
        (tb_state_sys == 4'd9)  ? surv_s9  :
        (tb_state_sys == 4'd10) ? surv_s10 :
        (tb_state_sys == 4'd11) ? surv_s11 :
        (tb_state_sys == 4'd12) ? surv_s12 :
        (tb_state_sys == 4'd13) ? surv_s13 :
        (tb_state_sys == 4'd14) ? surv_s14 :
                                  surv_s15;

    wire tb_surv_bit_w = tb_surv_row_w[tb_stage_w];

    // =========================================================================
    // Output buffer — write tb_state[0] (the input bit at this stage)
    // =========================================================================
    reg [MAX_STAGES-1:0] out_buf_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) out_buf_sys <= {MAX_STAGES{1'b0}};
        else if (state_sys == S_TRACEBACK)
            out_buf_sys[tb_stage_w] <= tb_state_sys[0];
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) decoded_bit <= 1'b0;
        else if (state_sys == S_OUTPUT)
            decoded_bit <= out_buf_sys[stage_cnt_sys];
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) decoded_valid <= 1'b0;
        else            decoded_valid <= (state_sys == S_OUTPUT);
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) block_done <= 1'b0;
        else            block_done <= out_done_sys;
    end

endmodule

`default_nettype wire
