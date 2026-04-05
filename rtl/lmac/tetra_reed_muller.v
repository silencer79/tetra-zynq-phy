// =============================================================================
// tetra_reed_muller.v — (30,14) Reed-Muller Codec for AACH/ACCH
// =============================================================================
//
// Implements the TETRA (30,14) linear block code as defined in
// ETSI EN 300 392-2 §8.2.4.1.
//
// Code construction:
//   Derived from RM(2,5) = (32,16,8) second-order Reed-Muller code by
//   shortening: remove row 0 (constant) and row 1 (x0) from basis, and
//   remove columns 0 and 1 (evaluation points 00000 and 00001).
//   Shortening preserves d_min ≥ 8, giving t_max = 3 correctable errors.
//
//   Generator matrix G (14 rows × 30 columns), encoded as localparams
//   G_ROW00..G_ROW13 (30-bit each).  Bit j of G_ROWi = G[i][j].
//   Basis row ordering:
//     row 0: x1       row 4: x0*x1    row  8: x1*x2
//     row 1: x2       row 5: x0*x2    row  9: x1*x3
//     row 2: x3       row 6: x0*x3    row 10: x1*x4
//     row 3: x4       row 7: x0*x4    row 11: x2*x3
//                                      row 12: x2*x4
//                                      row 13: x3*x4
//   Verified: d_min ≥ 8, rank = 14.  See gen_reed_muller_vectors.py.
//
// Encoder:
//   Combinatorial: c = u * G (mod 2)
//   c[j] = XOR of u[i] for all i where G[i][j] = 1
//   Latency: 1 clock cycle (registered output, encode_done 1 cycle after
//             encode_valid).
//
// Decoder:
//   Sequential minimum-distance hard-decision decoder.
//   Enumerates all 2^K = 16 384 candidate codewords over 16 384 clock cycles.
//   Tracks the candidate with minimum Hamming distance to the received word.
//   decode_done fires 1 cycle after search completes (~163 µs @ 100 MHz).
//   decode_error asserted when best distance > T_MAX (uncorrectable).
//
//   TETRA context: BB/AACH is 30 bits per burst, burst period 14.167 ms.
//   163 µs latency ≪ 14.167 ms — well within timing budget.
//
// Clock domain: _sys (100 MHz)
//
// Resource estimate: LUT ~270  FF ~100  DSP 0  BRAM 0
//
// =============================================================================

`default_nettype none

module tetra_reed_muller #(
    parameter N = 30,    // codeword length (only N=30 supported)
    parameter K = 14     // information bits (only K=14 supported)
)(
    input  wire          clk_sys,
    input  wire          rst_n_sys,

    // --- Encoder interface ---
    // Present encode_data_in with encode_valid=1 for one cycle.
    // encode_data_out / encode_done appear 1 cycle later.
    input  wire [K-1:0]  encode_data_in,    // K info bits to encode
    input  wire          encode_valid,      // 1-cycle pulse: encode_data_in valid
    output reg  [N-1:0]  encode_data_out,   // N coded bits (valid when encode_done)
    output reg           encode_done,       // 1-cycle pulse: encode_data_out valid

    // --- Decoder interface ---
    // Present decode_data_in with decode_valid=1 for one cycle.
    // Decoder runs for 2^K cycles then fires decode_done.
    // Do NOT assert another decode_valid until decode_done fires.
    input  wire [N-1:0]  decode_data_in,    // N received bits (may contain errors)
    input  wire          decode_valid,      // 1-cycle pulse: decode_data_in valid
    output reg  [K-1:0]  decode_data_out,   // K decoded bits (valid when decode_done)
    output reg           decode_done,       // 1-cycle pulse: decode_data_out valid
    output reg           decode_error       // 1 = uncorrectable (dist > T_MAX)
);

// ---------------------------------------------------------------------------
// Generator matrix G (14 rows × 30 columns) — RM(2,5) shortening
// G_ROWi = (RM25_basis_row_(i+2) >> 2) & 0x3FFFFFFF
// Each row is a 30-bit constant; bit j of G_ROWi = G[i][j].
// ---------------------------------------------------------------------------
localparam [29:0] G_ROW00 = 30'h33333333; // x1
localparam [29:0] G_ROW01 = 30'h3C3C3C3C; // x2
localparam [29:0] G_ROW02 = 30'h3FC03FC0; // x3
localparam [29:0] G_ROW03 = 30'h3FFFC000; // x4
localparam [29:0] G_ROW04 = 30'h22222222; // x0*x1
localparam [29:0] G_ROW05 = 30'h28282828; // x0*x2
localparam [29:0] G_ROW06 = 30'h2A802A80; // x0*x3
localparam [29:0] G_ROW07 = 30'h2AAA8000; // x0*x4
localparam [29:0] G_ROW08 = 30'h30303030; // x1*x2
localparam [29:0] G_ROW09 = 30'h33003300; // x1*x3
localparam [29:0] G_ROW10 = 30'h33330000; // x1*x4
localparam [29:0] G_ROW11 = 30'h3C003C00; // x2*x3
localparam [29:0] G_ROW12 = 30'h3C3C0000; // x2*x4
localparam [29:0] G_ROW13 = 30'h3FC00000; // x3*x4

// Maximum correctable errors: floor((d_min - 1) / 2) = floor(7/2) = 3
localparam [4:0] T_MAX = 5'd3;

// ---------------------------------------------------------------------------
// FSM state encoding (2 bits)
// ---------------------------------------------------------------------------
localparam [1:0] S_IDLE   = 2'd0;
localparam [1:0] S_DECODE = 2'd1;
localparam [1:0] S_OUTPUT = 2'd2;

// ---------------------------------------------------------------------------
// rm_encode — combinatorial GF(2) matrix-vector multiply
//   c = u[0]*G_ROW00 ^ u[1]*G_ROW01 ^ ... ^ u[13]*G_ROW13
//   Each G_ROWi contributes its 30-bit pattern when u[i]=1.
// ---------------------------------------------------------------------------
function [N-1:0] rm_encode;
    input [K-1:0] u;
    begin
        rm_encode = ({N{u[ 0]}} & G_ROW00) ^
                    ({N{u[ 1]}} & G_ROW01) ^
                    ({N{u[ 2]}} & G_ROW02) ^
                    ({N{u[ 3]}} & G_ROW03) ^
                    ({N{u[ 4]}} & G_ROW04) ^
                    ({N{u[ 5]}} & G_ROW05) ^
                    ({N{u[ 6]}} & G_ROW06) ^
                    ({N{u[ 7]}} & G_ROW07) ^
                    ({N{u[ 8]}} & G_ROW08) ^
                    ({N{u[ 9]}} & G_ROW09) ^
                    ({N{u[10]}} & G_ROW10) ^
                    ({N{u[11]}} & G_ROW11) ^
                    ({N{u[12]}} & G_ROW12) ^
                    ({N{u[13]}} & G_ROW13);
    end
endfunction

// ---------------------------------------------------------------------------
// popcount30 — Hamming weight of 30-bit vector, result 0..30 (5 bits)
// Implemented as a 30-input adder tree; synthesises to carry-save adders.
// ---------------------------------------------------------------------------
function [4:0] popcount30;
    input [29:0] v;
    begin
        popcount30 = {4'b0, v[ 0]} + {4'b0, v[ 1]} + {4'b0, v[ 2]} +
                     {4'b0, v[ 3]} + {4'b0, v[ 4]} + {4'b0, v[ 5]} +
                     {4'b0, v[ 6]} + {4'b0, v[ 7]} + {4'b0, v[ 8]} +
                     {4'b0, v[ 9]} + {4'b0, v[10]} + {4'b0, v[11]} +
                     {4'b0, v[12]} + {4'b0, v[13]} + {4'b0, v[14]} +
                     {4'b0, v[15]} + {4'b0, v[16]} + {4'b0, v[17]} +
                     {4'b0, v[18]} + {4'b0, v[19]} + {4'b0, v[20]} +
                     {4'b0, v[21]} + {4'b0, v[22]} + {4'b0, v[23]} +
                     {4'b0, v[24]} + {4'b0, v[25]} + {4'b0, v[26]} +
                     {4'b0, v[27]} + {4'b0, v[28]} + {4'b0, v[29]};
    end
endfunction

// ===========================================================================
// ENCODER PATH
// ===========================================================================

// Pipeline Stage 0 (combinatorial): c = encode_data_in * G
wire [N-1:0] encode_c_w = rm_encode(encode_data_in);

// Pipeline Stage 1: encode_data_out — registered codeword
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        encode_data_out <= {N{1'b0}};
    else if (encode_valid)
        encode_data_out <= encode_c_w;
end

// Pipeline Stage 1: encode_done — valid pulse, 1 cycle after encode_valid
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        encode_done <= 1'b0;
    else
        encode_done <= encode_valid;
end

// ===========================================================================
// DECODER PATH — sequential minimum-distance search over 2^K candidates
// ===========================================================================

// ---------------------------------------------------------------------------
// Decoder state registers
// ---------------------------------------------------------------------------
reg [1:0]  state_sys;     // FSM state
reg [N-1:0] r_latch_sys;  // latched received word
reg [K-1:0] cand_sys;     // current candidate message (14-bit counter)
reg [K-1:0] best_m_sys;   // best matching message found so far
reg [4:0]   best_dist_sys; // Hamming distance to best match (0..30; init 31)

// ---------------------------------------------------------------------------
// Decoder combinatorial signals
// ---------------------------------------------------------------------------
// Pipeline Stage 0: encode candidate and compute distance to received word
wire [N-1:0] cand_c_sys     = rm_encode(cand_sys);
wire [N-1:0] diff_sys       = cand_c_sys ^ r_latch_sys;
wire [4:0]   dist_raw_sys   = popcount30(diff_sys);

// Is current candidate better than best seen so far?
wire         better_sys     = (dist_raw_sys < best_dist_sys);

// ---------------------------------------------------------------------------
// FSM: next-state logic (combinatorial)
// ---------------------------------------------------------------------------
reg [1:0] next_state_sys;

// R5: combinatorial next-state block
always @(*) begin
    next_state_sys = state_sys;    // default: stay
    case (state_sys)
        S_IDLE:   if (decode_valid)                  next_state_sys = S_DECODE;
        S_DECODE: if (cand_sys == {K{1'b1}})         next_state_sys = S_OUTPUT;
        S_OUTPUT:                                     next_state_sys = S_IDLE;
        default:                                      next_state_sys = S_IDLE;
    endcase
end

// R5/R1: state register
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_IDLE;
    else
        state_sys <= next_state_sys;
end

// ---------------------------------------------------------------------------
// r_latch_sys — latch received word when decode starts
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        r_latch_sys <= {N{1'b0}};
    else if (state_sys == S_IDLE && decode_valid)
        r_latch_sys <= decode_data_in;
end

// ---------------------------------------------------------------------------
// cand_sys — candidate counter: reset at decode start, counts in S_DECODE
// Wraps naturally from (2^K - 1) → 0 on the cycle state leaves S_DECODE.
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        cand_sys <= {K{1'b0}};
    else if (state_sys == S_IDLE && decode_valid)
        cand_sys <= {K{1'b0}};
    else if (state_sys == S_DECODE)
        cand_sys <= cand_sys + {{(K-1){1'b0}}, 1'b1};
end

// ---------------------------------------------------------------------------
// best_dist_sys — reset to N+1 at decode start; updated in S_DECODE
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        best_dist_sys <= 5'd31;
    else if (state_sys == S_IDLE && decode_valid)
        best_dist_sys <= 5'd31;
    else if (state_sys == S_DECODE && better_sys)
        best_dist_sys <= dist_raw_sys;
end

// ---------------------------------------------------------------------------
// best_m_sys — updated when current candidate beats best so far
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        best_m_sys <= {K{1'b0}};
    else if (state_sys == S_IDLE && decode_valid)
        best_m_sys <= {K{1'b0}};
    else if (state_sys == S_DECODE && better_sys)
        best_m_sys <= cand_sys;
end

// ---------------------------------------------------------------------------
// decode_data_out — latches best_m on S_OUTPUT entry
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        decode_data_out <= {K{1'b0}};
    else if (state_sys == S_OUTPUT)
        decode_data_out <= best_m_sys;
end

// ---------------------------------------------------------------------------
// decode_done — 1-cycle pulse when state enters and immediately leaves S_OUTPUT
// decode_done fires on the cycle AFTER state becomes S_OUTPUT (registered)
// At that moment decode_data_out and decode_error are also valid.
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        decode_done <= 1'b0;
    else
        decode_done <= (state_sys == S_OUTPUT);
end

// ---------------------------------------------------------------------------
// decode_error — asserted when best distance exceeds T_MAX (uncorrectable)
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        decode_error <= 1'b0;
    else if (state_sys == S_OUTPUT)
        decode_error <= (best_dist_sys > T_MAX);
end

endmodule

`default_nettype wire
