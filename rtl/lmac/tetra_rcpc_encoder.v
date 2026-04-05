// =============================================================================
// tetra_rcpc_encoder.v — Rate-Compatible Punctured Convolutional Encoder
// =============================================================================
// ETSI EN 300 392-2 §8.2.3
// Rate 1/3 mother code, Constraint Length K=5, 16 states
// Generator polynomials (octal): G1=33 (0x1B=11011), G2=31 (0x19=11001), G3=25 (0x15=10101)
//
// State convention (matches tetra_viterbi_decoder.v):
//   sr_sys[3:0]: sr[3]=newest stored bit, sr[0]=oldest stored bit
//   Transition: new_sr = {data_in, sr[3:1]}   (shift right, drop sr[0])
//   Full 5-bit register: {data_in, sr[3], sr[2], sr[1], sr[0]}
//
// Generator polynomial outputs (XOR of tapped positions):
//   G1=11011: taps 4,3,1,0 → g1 = data_in ^ sr[3] ^ sr[1] ^ sr[0]
//   G2=11001: taps 4,3,0   → g2 = data_in ^ sr[3] ^ sr[0]
//   G3=10101: taps 4,2,0   → g3 = data_in ^ sr[2] ^ sr[0]
//
// Ports:
//   data_in / data_valid   — serial 1-bit input, active when valid=1
//   flush                  — single-cycle pulse: starts K-1=4 tail-bit sequence
//                            (forces 4 zero bits automatically; data_valid ignored during flush)
//   coded_bits / coded_valid — mother-rate 1/3 output; valid 1 cycle after input
//                              coded_bits[0]=G1, coded_bits[1]=G2, coded_bits[2]=G3
//   punct_out_bits / punct_valid — punctured output (1 or 2 bits depending on pattern)
//
// Puncturing patterns (punct_pattern[2:0]):
//   3'd0 — No puncturing (punct_valid=0 always; use coded_bits/coded_valid)
//   3'd1 — Rate 2/3: keep G1,G2; drop G3. punct_out_bits={G2,G1}; 2 bits per input bit
//   3'd2-7 — Reserved (same as 3'd0)
//
// Flush operation:
//   Assert flush=1 for exactly 1 cycle after last data bit (data_valid must be 0).
//   Encoder automatically inserts K-1=4 zero bits into the trellis, returning SR to 0.
//   flush_active_sys=1 during flush; new flush ignored until previous completes.
//
// Pipeline latency: 1 cycle (coded_bits valid 1 cycle after data_in/data_valid)
// Resource estimate: ~20 LUT, ~26 FF, 0 DSP, 0 BRAM
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
    // Mother-rate 1/3 output
    output reg  [2:0]  coded_bits,    // [0]=G1, [1]=G2, [2]=G3
    output reg         coded_valid,
    // Punctured output
    output reg  [1:0]  punct_out_bits,
    output reg         punct_valid
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
    // G1=11011: taps 4,3,1,0
    // G2=11001: taps 4,3,0
    // G3=10101: taps 4,2,0
    // -------------------------------------------------------------------------
    wire g1_w = data_in_eff_w ^ sr_sys[3] ^ sr_sys[1] ^ sr_sys[0];
    wire g2_w = data_in_eff_w ^ sr_sys[3]              ^ sr_sys[0];
    wire g3_w = data_in_eff_w              ^ sr_sys[2] ^ sr_sys[0];

    // =========================================================================
    // R1: coded_bits — registered {G3, G2, G1}
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            coded_bits <= 3'b000;
        else if (enable_enc_w)
            coded_bits <= {g3_w, g2_w, g1_w};
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

    // -------------------------------------------------------------------------
    // Puncturing — combinatorial selection based on punct_pattern
    // Pattern 1: rate 2/3, keep G1(bit0)+G2(bit1), drop G3(bit2)
    //   punct_out_bits = {g2_w, g1_w}
    //   punct_valid_w  = enable_enc_w
    // All others: punct_valid_w = 0
    // -------------------------------------------------------------------------
    wire [1:0] punct_out_bits_w = (punct_pattern == 3'd1) ? {g2_w, g1_w} : 2'b00;
    wire       punct_valid_w    = (punct_pattern == 3'd1) ? enable_enc_w  : 1'b0;

    // =========================================================================
    // R1: punct_out_bits — registered punctured output
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            punct_out_bits <= 2'b00;
        else if (enable_enc_w)
            punct_out_bits <= punct_out_bits_w;
    end

    // =========================================================================
    // R1: punct_valid — registered punctured valid
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            punct_valid <= 1'b0;
        else
            punct_valid <= punct_valid_w;
    end

endmodule
`default_nettype wire
