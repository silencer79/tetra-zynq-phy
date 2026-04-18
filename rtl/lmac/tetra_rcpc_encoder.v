// =============================================================================
// tetra_rcpc_encoder.v — Rate-Compatible Punctured Convolutional Encoder
// =============================================================================
// ETSI EN 300 392-2 §8.2.3
// Rate 1/4 mother code, Constraint Length K=5, 16 states
// Generator polynomials (ETSI §8.2.3.1.1):
//   G1 = 10011 = 0x13   taps {4,1,0}
//   G2 = 11101 = 0x1D   taps {4,3,2,0}
//   G3 = 10111 = 0x17   taps {4,2,1,0}
//   G4 = 11011 = 0x1B   taps {4,3,1,0}
//
// Cross-checked against:
//   - osmo-tetra  src/lower_mac/tetra_conv_enc.c (Welte 2011)
//   - SDRSharp.Tetra.dll  Viterbi::Process (signed-byte soft Viterbi)
//   - tetra_hal.c  tetra_etsi_conv_encode_r14()
//
// State convention (matches tetra_viterbi_decoder.v):
//   sr_sys[3:0]: sr[3]=newest stored bit, sr[0]=oldest stored bit
//   Transition: new_sr = {data_in, sr[3:1]}   (shift right, drop sr[0])
//   Full 5-bit register: {data_in, sr[3], sr[2], sr[1], sr[0]}
//
// Generator polynomial outputs (XOR of tapped positions):
//   G1=10011: taps 4,1,0 → g1 = data_in ^ sr[1] ^ sr[0]
//   G2=11101: taps 4,3,2,0 → g2 = data_in ^ sr[3] ^ sr[2] ^ sr[0]
//   G3=10111: taps 4,2,1,0 → g3 = data_in ^ sr[2] ^ sr[1] ^ sr[0]
//   G4=11011: taps 4,3,1,0 → g4 = data_in ^ sr[3] ^ sr[1] ^ sr[0]
//
// Ports:
//   data_in / data_valid   — serial 1-bit input, active when valid=1
//   flush                  — single-cycle pulse: starts K-1=4 tail-bit sequence
//                            (forces 4 zero bits automatically; data_valid ignored during flush)
//   coded_bits / coded_valid — mother-rate 1/4 output; valid 1 cycle after input
//                              coded_bits[0]=G1, [1]=G2, [2]=G3, [3]=G4
//   punct_out_bits / punct_valid — punctured output for rate 2/3
//
// Puncturing (ETSI §8.2.3.1.3, rate 2/3 over rate-1/4 mother):
//   Per 2 input bits (a=even, b=odd), mother outputs 8 bits:
//     g1(a), g2(a), g3(a), g4(a), g1(b), g2(b), g3(b), g4(b)
//   Rate 2/3 keeps positions {0, 1, 4} → {g1(a), g2(a), g1(b)}
//   = 3 output bits per 2 input bits = rate 2/3.
//
//   Matches: P_rate2_3 = {0, 1, 2, 5} (1-indexed) in osmo-tetra,
//            tetra_etsi_puncture_r23() positions {0, 1, 4} (0-indexed) in tetra_hal.c.
//
// Flush operation:
//   Assert flush=1 for exactly 1 cycle after last data bit (data_valid must be 0).
//   Encoder automatically inserts K-1=4 zero bits into the trellis, returning SR to 0.
//   flush_active_sys=1 during flush; new flush ignored until previous completes.
//
// Pipeline latency: 1 cycle (coded_bits valid 1 cycle after data_in/data_valid)
// Resource estimate: ~30 LUT, ~35 FF, 0 DSP, 0 BRAM
// =============================================================================

`default_nettype none

module tetra_rcpc_encoder #(
    parameter K = 5
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    // Input
    input  wire        data_in,
    input  wire        data_valid,
    // Puncturing configuration
    input  wire [2:0]  punct_pattern,
    // Flush / tail-bit insertion (single-cycle pulse; assert when data_valid=0)
    input  wire        flush,
    // Mother-rate 1/4 output
    output reg  [3:0]  coded_bits,    // [0]=G1, [1]=G2, [2]=G3, [3]=G4
    output reg         coded_valid,
    // Punctured output (rate 2/3: 3 bits per 2 input bits)
    output reg  [1:0]  punct_out_bits, // see punct_valid for bit count
    output reg         punct_valid,
    output reg         punct_out_cnt   // 0=2 bits valid, 1=1 bit valid
);

    // -------------------------------------------------------------------------
    // Localparam: number of tail bits = K-1
    // -------------------------------------------------------------------------
    localparam [1:0] TAIL_LAST = K - 2;   // flush_cnt value of last tail bit (3 for K=5)

    // =========================================================================
    // R1: Flush control — flush_active_sys
    // Set on flush pulse (when not already active and data_valid=0).
    // Cleared after TAIL_LAST flush cycle completes (flush_cnt==3).
    // =========================================================================
    reg flush_active_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            flush_active_sys <= 1'b0;
        else if (flush && !flush_active_sys && !data_valid)
            flush_active_sys <= 1'b1;
        else if (flush_active_sys && (flush_cnt_sys == TAIL_LAST))
            flush_active_sys <= 1'b0;
    end

    // =========================================================================
    // R1: Flush counter — flush_cnt_sys [1:0]
    // Counts 0..K-2 while flush active; resets when inactive.
    // =========================================================================
    reg [1:0] flush_cnt_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            flush_cnt_sys <= 2'd0;
        else if (flush_active_sys)
            flush_cnt_sys <= flush_cnt_sys + 2'd1;
        else
            flush_cnt_sys <= 2'd0;
    end

    // -------------------------------------------------------------------------
    // Combinatorial: effective input and enable
    // During flush: force data=0; use flush_active_sys as enable
    // Normal mode: use data_in/data_valid
    // -------------------------------------------------------------------------
    wire data_in_eff_w  = flush_active_sys ? 1'b0 : data_in;
    wire enable_enc_w   = data_valid | flush_active_sys;

    // =========================================================================
    // R1: Shift register — sr_sys [3:0]
    // sr[3]=newest stored bit, sr[0]=oldest stored bit
    // Transition: {data_in_eff, sr[3:1]}
    // =========================================================================
    reg [3:0] sr_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            sr_sys <= 4'b0000;
        else if (enable_enc_w)
            sr_sys <= {data_in_eff_w, sr_sys[3:1]};
    end

    // -------------------------------------------------------------------------
    // Generator polynomial outputs (combinatorial)
    // Full 5-bit register: {data_in_eff, sr[3], sr[2], sr[1], sr[0]}
    //
    // ETSI EN 300 392-2 §8.2.3.1.1:
    //   G1 = 0x13 = 10011: taps 4,1,0
    //   G2 = 0x1D = 11101: taps 4,3,2,0
    //   G3 = 0x17 = 10111: taps 4,2,1,0
    //   G4 = 0x1B = 11011: taps 4,3,1,0
    // -------------------------------------------------------------------------
    wire g1_w = data_in_eff_w              ^ sr_sys[1] ^ sr_sys[0]; // G1=10011
    wire g2_w = data_in_eff_w ^ sr_sys[3] ^ sr_sys[2] ^ sr_sys[0]; // G2=11101
    wire g3_w = data_in_eff_w ^ sr_sys[2] ^ sr_sys[1] ^ sr_sys[0]; // G3=10111
    wire g4_w = data_in_eff_w ^ sr_sys[3] ^ sr_sys[1] ^ sr_sys[0]; // G4=11011

    // =========================================================================
    // R1: coded_bits — registered {G4, G3, G2, G1}
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            coded_bits <= 4'b0000;
        else if (enable_enc_w)
            coded_bits <= {g4_w, g3_w, g2_w, g1_w};
    end

    // =========================================================================
    // R1: coded_valid — registered enable
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            coded_valid <= 1'b0;
        else
            coded_valid <= enable_enc_w;
    end

    // =========================================================================
    // Puncturing — ETSI §8.2.3.1.3 Rate 2/3 over rate-1/4 mother
    //
    // Per 2 input bits (even=a, odd=b), mother produces 8 bits:
    //   [g1a, g2a, g3a, g4a, g1b, g2b, g3b, g4b]
    // Rate 2/3 keeps positions {0,1,4}: {g1a, g2a, g1b}
    //   → even bit: output g1, g2 (2 bits, punct_out_cnt=0)
    //   → odd bit:  output g1     (1 bit,  punct_out_cnt=1)
    // =========================================================================

    // Track even/odd input bit position
    reg bit_phase_sys;   // 0 = even (a), 1 = odd (b)

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            bit_phase_sys <= 1'b0;
        else if (enable_enc_w)
            bit_phase_sys <= ~bit_phase_sys;
    end

    // Punctured output (registered)
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            punct_out_bits <= 2'b00;
            punct_valid    <= 1'b0;
            punct_out_cnt  <= 1'b0;
        end else if (punct_pattern == 3'd1 && enable_enc_w) begin
            if (bit_phase_sys == 1'b0) begin
                // Even input bit (a): output g1(a), g2(a) — 2 bits
                punct_out_bits <= {g2_w, g1_w};
                punct_valid    <= 1'b1;
                punct_out_cnt  <= 1'b0;  // 2 bits valid
            end else begin
                // Odd input bit (b): output g1(b) — 1 bit
                punct_out_bits <= {1'b0, g1_w};
                punct_valid    <= 1'b1;
                punct_out_cnt  <= 1'b1;  // 1 bit valid
            end
        end else begin
            punct_valid <= 1'b0;
        end
    end

endmodule
`default_nettype wire
