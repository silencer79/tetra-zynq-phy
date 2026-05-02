// =============================================================================
// tetra_viterbi_decoder.v — 16-State Soft-Decision Viterbi Decoder
// =============================================================================
// ETSI EN 300 392-2 §8.2.3
// Rate 1/4 mother code, Constraint Length K=5, 16 states
// Generator polynomials: G1=0x13, G2=0x1D, G3=0x17, G4=0x1B
// Soft-decision: 3-bit unsigned  0=strong_0 .. 7=strong_1, 4=erasure
//
// Trellis convention:
//   state[3:0] = last 4 input bits, state[3] = oldest bit
//   new_state  = {input_bit, prev_state[3:1]}
//   Predecessors of state s: prev0 = {s[2:0], 0}, prev1 = {s[2:0], 1}
//   Input bit for both predecessors = s[3]
//   Branch outputs (for P0 predecessor, sr LSB=0):
//     g1_p0 = s[3]^s[0]         (G1=0x13: taps 4,1,0)
//     g2_p0 = s[3]^s[2]^s[1]    (G2=0x1D: taps 4,3,2,0)
//     g3_p0 = s[3]^s[1]^s[0]    (G3=0x17: taps 4,2,1,0)
//     g4_p0 = s[3]^s[2]^s[0]    (G4=0x1B: taps 4,3,1,0)
//   All generators have tap at position 0 => g_p1 = ~g_p0 => bm1 = 28 - bm0
//
// Operation (block-based, one block at a time):
//   S_IDLE      — wait for first input_valid
//   S_ACS       — receive num_stages soft triplets; update path metrics + survivors
//   S_TB_INIT   — register argmin(path_metrics) as traceback start state (1 cycle)
//   S_TRACEBACK — walk back num_stages steps, writing decoded bits to out_buf
//   S_OUTPUT    — stream (num_stages - TAIL) decoded info bits; assert block_done
//
// Path metrics: 16 x 16-bit, stored in flat 256-bit register (R3 compliant)
// Survivors:    16 flat registers of MAX_STAGES bits (variable bit-select, R3)
// Output buf:   MAX_STAGES-bit flat register (variable bit-select write)
//
// Resource estimate: ~2500 LUT, ~7800 FF, 0 DSP, 0 BRAM
//
// Ports:
//   soft_bit_0/1/2/3 — G1/G2/G3/G4 soft values, one quad per trellis stage
//   num_stages      — total trellis stages = info_bits + K-1 tail (e.g. 220, 436)
//   punct_pattern   — reserved (depuncturing / erasure insertion is upstream)
//   path_metric_min — minimum final path metric, proxy for BER estimation
// =============================================================================

`default_nettype none

module tetra_viterbi_decoder #(
    parameter SOFT_WIDTH = 3,
    parameter TRACEBACK  = 32,    // >= 5*(K-1)=20 per spec; 32 for margin
    parameter MAX_STAGES = 436    // 432 info bits + K-1=4 tail
)(
    input  wire                  clk_sys,
    input  wire                  rst_n_sys,
    // Soft-decision input (one quad per trellis stage; erasures pre-inserted)
    input  wire [SOFT_WIDTH-1:0] soft_bit_0,   // G1=0x13 channel
    input  wire [SOFT_WIDTH-1:0] soft_bit_1,   // G2=0x1D channel
    input  wire [SOFT_WIDTH-1:0] soft_bit_2,   // G3=0x17 channel
    input  wire [SOFT_WIDTH-1:0] soft_bit_3,   // G4=0x1B channel
    input  wire                  input_valid,
    // Block configuration
    input  wire [8:0]            num_stages,   // info_bits + K-1  (e.g. 220 or 436)
    // Puncturing config (reserved; depuncturing is done upstream by caller)
    input  wire [2:0]            punct_pattern,
    // Output
    output reg                   decoded_bit,
    output reg                   decoded_valid,
    output reg                   block_done,
    output wire [15:0]           path_metric_min
);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    localparam K    = 5;
    localparam TAIL = K - 1;   // 4 tail bits that the encoder appended

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_ACS      = 3'd1;
    localparam [2:0] S_TB_INIT  = 3'd2;
    localparam [2:0] S_TRACEBACK= 3'd3;
    localparam [2:0] S_OUTPUT   = 3'd4;

    // =========================================================================
    // R1: FSM state register
    // =========================================================================
    reg [2:0] state_sys;
    reg [2:0] next_state_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) state_sys <= S_IDLE;
        else            state_sys <= next_state_sys;
    end

    // =========================================================================
    // R1: Stage counter — ACS input count / traceback step / output index
    // =========================================================================
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

    // =========================================================================
    // R5: FSM next-state logic (combinatorial)
    // =========================================================================
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
    // ACS combinatorial logic — generate block for all 16 states
    //
    // For each new_state s:
    //   P0 = (s & 7) << 1       predecessor with LSB=0
    //   P1 = ((s & 7) << 1) | 1 predecessor with LSB=1
    //   G1P0 = s[3]^s[0], G2P0 = s[3]^s[2]^s[1], G3P0 = s[3]^s[1]^s[0], G4P0 = s[3]^s[2]^s[0]
    //   bm0 = sum( G_k ? (7-soft_k) : soft_k  for k in {0,1,2,3} )
    //   bm1 = 28 - bm0  (butterfly: g_p1 = ~g_p0)
    //   cost0 = pm[P0] + bm0,  cost1 = pm[P1] + bm1
    //   surv  = (cost1 < cost0) ? 1 : 0
    //   raw   = min(cost0, cost1)
    // =========================================================================
    // Path metrics: flat 256-bit register (R3: one register = 16 x 16-bit)
    //   pm_flat_sys[s*16 +: 16] = metric for state s
    reg [255:0] pm_flat_sys;

    genvar s;
    generate
    for (s = 0; s < 16; s = s + 1) begin : g_acs
        // Compile-time constants — predecessor indices and branch outputs
        localparam P0   = (s & 7) << 1;
        localparam P1   = ((s & 7) << 1) | 1;
        localparam G1P0 = ((s >> 3) ^ s) & 1;                // s[3]^s[0]        G1=0x13
        localparam G2P0 = ((s >> 3) ^ (s >> 2) ^ (s >> 1)) & 1; // s[3]^s[2]^s[1]  G2=0x1D
        localparam G3P0 = ((s >> 3) ^ (s >> 1) ^ s) & 1;  // s[3]^s[1]^s[0]  G3=0x17
        localparam G4P0 = ((s >> 3) ^ (s >> 2) ^ s) & 1;  // s[3]^s[2]^s[0]  G4=0x1B

        // Branch metric for P0 path (4 terms each 0..7, sum 0..28, 5-bit)
        wire [4:0] bm0_w =
            ({2'b0, G1P0[0] ? (3'd7 - soft_bit_0) : soft_bit_0}) +
            ({2'b0, G2P0[0] ? (3'd7 - soft_bit_1) : soft_bit_1}) +
            ({2'b0, G3P0[0] ? (3'd7 - soft_bit_2) : soft_bit_2}) +
            ({2'b0, G4P0[0] ? (3'd7 - soft_bit_3) : soft_bit_3});
        wire [4:0] bm1_w = 5'd28 - bm0_w;

        // ACS (17-bit: 16-bit metric + 5-bit bm; max 0xFFFF+28 fits in 17 bits)
        wire [16:0] cost0_w = {1'b0, pm_flat_sys[P0*16 +: 16]} + {12'b0, bm0_w};
        wire [16:0] cost1_w = {1'b0, pm_flat_sys[P1*16 +: 16]} + {12'b0, bm1_w};

        wire        surv_w  = (cost1_w < cost0_w) ? 1'b1 : 1'b0;
        wire [16:0] raw_w   = surv_w ? cost1_w : cost0_w;
    end
    endgenerate

    // =========================================================================
    // Minimum of 16 raw path metrics — binary tree, no array indexing (R3)
    // Carries (index, value) at each level to avoid variable array accesses
    // =========================================================================
    // Extract current path metric slices (constant indices, R3 compliant)
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

    // --- Level 0: min of raw ACS outputs (for normalization) ---
    wire [16:0] mn01 = (g_acs[0].raw_w  <= g_acs[1].raw_w)  ? g_acs[0].raw_w  : g_acs[1].raw_w;
    wire [16:0] mn23 = (g_acs[2].raw_w  <= g_acs[3].raw_w)  ? g_acs[2].raw_w  : g_acs[3].raw_w;
    wire [16:0] mn45 = (g_acs[4].raw_w  <= g_acs[5].raw_w)  ? g_acs[4].raw_w  : g_acs[5].raw_w;
    wire [16:0] mn67 = (g_acs[6].raw_w  <= g_acs[7].raw_w)  ? g_acs[6].raw_w  : g_acs[7].raw_w;
    wire [16:0] mn89 = (g_acs[8].raw_w  <= g_acs[9].raw_w)  ? g_acs[8].raw_w  : g_acs[9].raw_w;
    wire [16:0] mnAB = (g_acs[10].raw_w <= g_acs[11].raw_w) ? g_acs[10].raw_w : g_acs[11].raw_w;
    wire [16:0] mnCD = (g_acs[12].raw_w <= g_acs[13].raw_w) ? g_acs[12].raw_w : g_acs[13].raw_w;
    wire [16:0] mnEF = (g_acs[14].raw_w <= g_acs[15].raw_w) ? g_acs[14].raw_w : g_acs[15].raw_w;
    // Level 1
    wire [16:0] mn0123 = (mn01 <= mn23) ? mn01 : mn23;
    wire [16:0] mn4567 = (mn45 <= mn67) ? mn45 : mn67;
    wire [16:0] mn89AB = (mn89 <= mnAB) ? mn89 : mnAB;
    wire [16:0] mnCDEF = (mnCD <= mnEF) ? mnCD : mnEF;
    // Level 2
    wire [16:0] mn07   = (mn0123 <= mn4567) ? mn0123 : mn4567;
    wire [16:0] mn8F   = (mn89AB <= mnCDEF) ? mn89AB : mnCDEF;
    // Level 3
    wire [16:0] pm_raw_min_w = (mn07 <= mn8F) ? mn07 : mn8F;

    // Normalized new metrics: subtract minimum so best state = 0 (clamp at 16'hFFFF)
    // Since raw >= min, subtraction can't underflow; max spread bounded by TRACEBACK*28
    generate
    for (s = 0; s < 16; s = s + 1) begin : g_norm
        wire [16:0] diff_w = g_acs[s].raw_w - pm_raw_min_w;
        wire [15:0] nm_w   = diff_w[16] ? 16'hFFFF : diff_w[15:0];
    end
    endgenerate

    // =========================================================================
    // R1: Path metric flat register update
    //     Init value: state 0 = 0, all others = 16'hFFFF (encoder starts at 0)
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
        end else if (state_sys == S_OUTPUT && out_done_sys) begin
            pm_flat_sys <= {{15{16'hFFFF}}, 16'h0000};
        end else if ((state_sys == S_IDLE || state_sys == S_ACS) && input_valid) begin
            pm_flat_sys[  15:  0] <= g_norm[0].nm_w;
            pm_flat_sys[  31: 16] <= g_norm[1].nm_w;
            pm_flat_sys[  47: 32] <= g_norm[2].nm_w;
            pm_flat_sys[  63: 48] <= g_norm[3].nm_w;
            pm_flat_sys[  79: 64] <= g_norm[4].nm_w;
            pm_flat_sys[  95: 80] <= g_norm[5].nm_w;
            pm_flat_sys[ 111: 96] <= g_norm[6].nm_w;
            pm_flat_sys[ 127:112] <= g_norm[7].nm_w;
            pm_flat_sys[ 143:128] <= g_norm[8].nm_w;
            pm_flat_sys[ 159:144] <= g_norm[9].nm_w;
            pm_flat_sys[ 175:160] <= g_norm[10].nm_w;
            pm_flat_sys[ 191:176] <= g_norm[11].nm_w;
            pm_flat_sys[ 207:192] <= g_norm[12].nm_w;
            pm_flat_sys[ 223:208] <= g_norm[13].nm_w;
            pm_flat_sys[ 239:224] <= g_norm[14].nm_w;
            pm_flat_sys[ 255:240] <= g_norm[15].nm_w;
        end
    end

    // path_metric_min: minimum final metric (0 after normalisation — output raw min)
    assign path_metric_min = pm_raw_min_w[15:0];

    // =========================================================================
    // Survivor bit storage — 16 flat registers, one per state  (R3: no arrays)
    //   surv_sN[stage] = 1 if winner came from prev1 = {s[2:0],1}
    //                    0 if winner came from prev0 = {s[2:0],0}
    // R1: one always block per register  R3: variable bit-select write
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
    // Argmin — find best final state for traceback initialisation
    // Uses (idx, val) pairs at each tree level to avoid variable array indexing
    // =========================================================================
    // Level 0: compare adjacent pairs, carry both index and value
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

    // Level 1: reduce 8 winners to 4
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

    // Level 2: reduce 4 to 2
    wire        cmp07   = (val0123 <= val4567);
    wire [3:0]  idx07   = cmp07 ? idx0123 : idx4567;
    wire [15:0] val07   = cmp07 ? val0123 : val4567;

    wire        cmp8F   = (val89AB <= valCDEF);
    wire [3:0]  idx8F   = cmp8F ? idx89AB : idxCDEF;
    wire [15:0] val8F   = cmp8F ? val89AB : valCDEF;

    // Level 3: winner
    wire [3:0]  best_state_w = (val07 <= val8F) ? idx07 : idx8F;

    // =========================================================================
    // R1: Traceback state register
    //   S_TB_INIT: latch best final state
    //   S_TRACEBACK: reverse-step: next = {current[2:0], survivor_bit}
    // =========================================================================
    reg [3:0] tb_state_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) tb_state_sys <= 4'd0;
        else if (state_sys == S_TB_INIT)
            tb_state_sys <= best_state_w;
        else if (state_sys == S_TRACEBACK)
            tb_state_sys <= {tb_state_sys[2:0], tb_surv_bit_w};
    end

    // =========================================================================
    // Traceback: current trellis stage and survivor bit lookup
    //   stage walks backward: num_stages-1, num_stages-2, ... 0
    // =========================================================================
    wire [8:0] tb_stage_w = num_stages - 9'd1 - stage_cnt_sys;

    // 16-to-1 survivor row mux (R3 compliant: explicit case, no array index)
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

    // Variable bit-select read (R3: read from flat register, not array)
    wire tb_surv_bit_w = tb_surv_row_w[tb_stage_w];

    // =========================================================================
    // R1: Output buffer
    //   Written during S_TRACEBACK: decoded bit for stage t = state[3] at stage t
    //   Read during S_OUTPUT in forward order (indices 0..num_stages-TAIL-1)
    // =========================================================================
    reg [MAX_STAGES-1:0] out_buf_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) out_buf_sys <= {MAX_STAGES{1'b0}};
        else if (state_sys == S_TRACEBACK)
            out_buf_sys[tb_stage_w] <= tb_state_sys[3];
    end

    // =========================================================================
    // R1: Output registers — decoded_bit, decoded_valid, block_done
    // =========================================================================
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
