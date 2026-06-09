// =============================================================================
// tetra_ul_nub_to_schf.v — feed adapter: NUB parallel softs → SCH/F decoder stream
// =============================================================================
//
// The NUB capture (tetra_ul_nub_capture) presents 432 type-5 softs in PARALLEL
// (coded_softs[i*NUB_SOFT_W +: NUB_SOFT_W], i=0..431, BKN1||BKN2 = on-air order).
// tetra_ul_sch_f_decoder consumes a STREAM of soft-dibits (2 softs / valid cyc,
// soft_bit1 = type5[2k], soft_bit0 = type5[2k+1]), 8-bit signed.
//
// This adapter streams the 432 softs as 216 dibits, one per cycle, on every
// nub_coded_valid pulse.  The decoder + accumulator are self-filtering (only a
// valid SCH/F MAC-FRAG/END with crc_ok is accepted), so EVERY captured NUB can
// be fed — voice bursts simply crc-fail downstream and are ignored.  No TN
// table, no voice-path interaction.
//
// Sign convention: NUB softs are INVERSE to ETSI (positive = bit '1', see
// feedback_soft_decision_sign_convention).  The SCH/F decoder (like SCH/HU)
// expects positive = bit '0'.  So the adapter NEGATES each soft (and
// sign-extends NUB_SOFT_W → 8-bit).
// =============================================================================

`default_nettype none

module tetra_ul_nub_to_schf #(
 parameter integer NUB_SOFT_W = 4,    // NUB capture soft width (signed)
 parameter integer OUT_W      = 8,    // decoder soft width (signed)
 parameter integer NBITS      = 432   // type-5 bits per burst
)(
 input wire clk_sys,
 input wire rst_n_sys,

 // From NUB capture
 input wire nub_coded_valid_sys,
 input wire [NBITS*NUB_SOFT_W-1:0] nub_coded_softs_sys,

 // To tetra_ul_sch_f_decoder (streaming dibits)
 output reg signed [OUT_W-1:0] soft_bit0_sys,
 output reg signed [OUT_W-1:0] soft_bit1_sys,
 output reg soft_valid_sys,
 output reg soft_first_sys,
 output reg soft_last_sys,
 output reg busy_sys
);

localparam integer NDIBIT = NBITS/2;   // 216

reg [NBITS*NUB_SOFT_W-1:0] softs_lat;
reg [8:0] k_sys;                        // 0..NDIBIT-1
reg streaming;

// extract + negate + sign-extend a single NUB soft
function signed [OUT_W-1:0] conv;
 input [NUB_SOFT_W-1:0] s_raw;
 reg signed [OUT_W-1:0] ext;
 begin
 ext  = {{(OUT_W-NUB_SOFT_W){s_raw[NUB_SOFT_W-1]}}, s_raw}; // sign-extend
 conv = -ext;                                               // invert (NUB→ETSI)
 end
endfunction

// combinational picks for the current dibit k: bit1 = softs[2k], bit0 = softs[2k+1]
wire [NUB_SOFT_W-1:0] raw_b1 = softs_lat[(2*k_sys)   * NUB_SOFT_W +: NUB_SOFT_W];
wire [NUB_SOFT_W-1:0] raw_b0 = softs_lat[(2*k_sys+1) * NUB_SOFT_W +: NUB_SOFT_W];

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 softs_lat <= {(NBITS*NUB_SOFT_W){1'b0}};
 k_sys <= 9'd0;
 streaming <= 1'b0;
 soft_bit0_sys <= {OUT_W{1'b0}};
 soft_bit1_sys <= {OUT_W{1'b0}};
 soft_valid_sys <= 1'b0;
 soft_first_sys <= 1'b0;
 soft_last_sys <= 1'b0;
 busy_sys <= 1'b0;
 end else begin
 soft_valid_sys <= 1'b0;
 soft_first_sys <= 1'b0;
 soft_last_sys <= 1'b0;

 if (!streaming) begin
 busy_sys <= 1'b0;
 if (nub_coded_valid_sys) begin
 softs_lat <= nub_coded_softs_sys;   // latch the whole burst
 k_sys <= 9'd0;
 streaming <= 1'b1;
 busy_sys <= 1'b1;
 end
 end else begin
 // present one dibit per cycle
 soft_bit1_sys <= conv(raw_b1);
 soft_bit0_sys <= conv(raw_b0);
 soft_valid_sys <= 1'b1;
 soft_first_sys <= (k_sys == 9'd0);
 soft_last_sys <= (k_sys == NDIBIT[8:0]-9'd1);
 if (k_sys == NDIBIT[8:0]-9'd1) begin
 streaming <= 1'b0;
 end else begin
 k_sys <= k_sys + 9'd1;
 end
 end
 end
end

endmodule

`default_nettype wire
