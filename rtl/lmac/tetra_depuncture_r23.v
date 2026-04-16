// =============================================================================
// tetra_depuncture_r23.v — ETSI Rate-2/3 Depuncturer (over rate-1/4 mother)
// =============================================================================
// EN 300 392-2 §8.2.3.1.3
//
// Puncture pattern P_2/3 over 8-bit mother periods (2 input bits × 4 gens):
//   Keep positions 0, 1, 4 of {g1(a),g2(a),g3(a),g4(a),g1(b),g2(b),g3(b),g4(b)}
//   → 3 coded bits per 2 input bits (rate 2/3)
//
// Depuncture: insert erasure (soft value = ERASURE) at positions 2,3,5,6,7.
//
// Interface: bit-serial in, 4-soft-bit groups out (one per trellis stage).
// For every 3 input bits, outputs 2 trellis stages × 4 soft bits = 8 values.
//
// Soft encoding: 0 = hard 0, 7 = hard 1, ERASURE = 4 (mid-point, zero cost)
//
// Clock domain: clk_sys (100 MHz)
// Resource estimate: ~30 LUT, ~20 FF
// =============================================================================

`default_nettype none

module tetra_depuncture_r23 #(
    parameter SOFT_WIDTH = 3
)(
    input  wire                  clk_sys,
    input  wire                  rst_n_sys,

    // Input: hard bits from deinterleaver (bit-serial)
    input  wire                  data_in,
    input  wire                  data_in_valid,

    // Output: 4 soft values per trellis stage (rate-1/4 mother code)
    output reg  [SOFT_WIDTH-1:0] soft_0,    // G1
    output reg  [SOFT_WIDTH-1:0] soft_1,    // G2
    output reg  [SOFT_WIDTH-1:0] soft_2,    // G3
    output reg  [SOFT_WIDTH-1:0] soft_3,    // G4
    output reg                   output_valid,

    // Block boundary
    input  wire                  block_start,
    output reg                   block_done
);

// Soft-decision constants
localparam [SOFT_WIDTH-1:0] HARD_0  = {SOFT_WIDTH{1'b0}};        // 0
localparam [SOFT_WIDTH-1:0] HARD_1  = {SOFT_WIDTH{1'b1}};        // 7
localparam [SOFT_WIDTH-1:0] ERASURE = {1'b1, {(SOFT_WIDTH-1){1'b0}}}; // 4

// Puncture pattern: per 3 input bits → 2 trellis stages
// Input bit 0 → mother[0] = g1(a)
// Input bit 1 → mother[1] = g2(a)
// Input bit 2 → mother[4] = g1(b)
// Positions 2,3,5,6,7 = erasures

// State: count input bits modulo 3
reg [1:0] in_cnt_sys;
reg [SOFT_WIDTH-1:0] hold_0_sys;   // store first two bits
reg [SOFT_WIDTH-1:0] hold_1_sys;

// Convert hard bit to max-confidence soft value
wire [SOFT_WIDTH-1:0] soft_in = data_in ? HARD_1 : HARD_0;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        in_cnt_sys   <= 2'd0;
        hold_0_sys   <= ERASURE;
        hold_1_sys   <= ERASURE;
        soft_0       <= ERASURE;
        soft_1       <= ERASURE;
        soft_2       <= ERASURE;
        soft_3       <= ERASURE;
        output_valid <= 1'b0;
        block_done   <= 1'b0;
    end else begin
        output_valid <= 1'b0;
        block_done   <= 1'b0;

        if (block_start)
            in_cnt_sys <= 2'd0;

        if (data_in_valid) begin
            case (in_cnt_sys)
                2'd0: begin
                    // First input bit → g1(a), store it
                    hold_0_sys <= soft_in;
                    in_cnt_sys <= 2'd1;
                end
                2'd1: begin
                    // Second input bit → g2(a), store it
                    hold_1_sys <= soft_in;
                    in_cnt_sys <= 2'd2;
                end
                2'd2: begin
                    // Third input bit → g1(b)
                    // Emit trellis stage A: g1(a)=hold_0, g2(a)=hold_1, g3(a)=erasure, g4(a)=erasure
                    soft_0 <= hold_0_sys;
                    soft_1 <= hold_1_sys;
                    soft_2 <= ERASURE;
                    soft_3 <= ERASURE;
                    output_valid <= 1'b1;
                    // Stage B will be emitted next cycle
                    hold_0_sys <= soft_in;   // g1(b) for stage B
                    in_cnt_sys <= 2'd3;      // use 3 as "emit stage B" state
                end
                default: begin
                    // Should not happen — reset
                    in_cnt_sys <= 2'd0;
                end
            endcase
        end

        // Emit trellis stage B one cycle after stage A
        if (in_cnt_sys == 2'd3) begin
            soft_0 <= hold_0_sys;   // g1(b)
            soft_1 <= ERASURE;      // g2(b) = erasure
            soft_2 <= ERASURE;      // g3(b) = erasure
            soft_3 <= ERASURE;      // g4(b) = erasure
            output_valid <= 1'b1;
            in_cnt_sys <= 2'd0;     // ready for next triplet
        end
    end
end

endmodule
`default_nettype wire
