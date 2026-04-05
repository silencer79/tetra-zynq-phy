// =============================================================================
// tetra_scrambler.v — LFSR Scrambler / Descrambler
// =============================================================================
//
// Implements the TETRA scrambling sequence as defined in
// ETSI EN 300 392-2 §8.2.5.
//
// Algorithm:
//   Galois LFSR, 32 bits, shift-right, output = LSB before shift.
//   Polynomial: p(x) = x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11
//                       + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1
//   Galois feedback mask (bits 31..0 = x^31..x^0, excluding x^32):
//     32'h04C11DB7
//
//   Each valid clock cycle:
//     q_k  = lfsr[0]                 (output scrambling bit)
//     lfsr → (lfsr >> 1) ^ (q_k ? POLY_MASK : 0)
//     data_out = data_in ^ q_k       (scramble / descramble — symmetric)
//
// Note: An all-zero LFSR state is degenerate (output stays 0 forever).
//   The initialization value lfsr_init must be non-zero. Software is
//   responsible for ensuring this. The reset state is all-ones (0xFFFFFFFF).
//
// Initialization (ETSI EN 300 392-2 §8.2.5.2):
//   lfsr_init = { TN[1:0], MNC[13:0], MCC[9:0], CC[5:0] }  (32 bits total)
//   where:
//     CC  = Colour Code (6 bits, from AACH broadcast)
//     MCC = Mobile Country Code (10 bits)
//     MNC = Mobile Network Code (14 bits)
//     TN  = Timeslot Number (2 bits)
//   Software computes this value and writes it to AXI-Lite COLOUR_CODE register
//   before asserting load_init.
//
// Symmetry:
//   The XOR operation is self-inverse: descrambling = scrambling with the
//   same initialization. No mode select needed.
//
// Timing:
//   load_init takes priority over data_valid on the same clock edge.
//   On load_init: LFSR loads lfsr_init, no data output produced.
//   First valid data_out appears 1 cycle after the first data_valid.
//   data_out_valid follows data_valid by exactly 1 clock cycle.
//
// Clock domain: _sys (100 MHz)
//
// Resource estimate: LUT ~35  FF ~34  DSP 0  BRAM 0
//
// =============================================================================

`default_nettype none

module tetra_scrambler #(
    parameter LFSR_WIDTH = 32
)(
    input  wire                      clk_sys,
    input  wire                      rst_n_sys,

    // LFSR initialization (load from AXI-Lite before each burst)
    input  wire [LFSR_WIDTH-1:0]     lfsr_init,   // Colour Code + MCC + MNC + TN
    input  wire                      load_init,   // one-cycle pulse: load lfsr_init

    // Bit-serial data stream
    input  wire                      data_in,
    input  wire                      data_valid,

    // Scrambled / descrambled output (1 cycle latency)
    output reg                       data_out,
    output reg                       data_out_valid
);

// ---------------------------------------------------------------------------
// LFSR polynomial (Galois feedback mask)
// Corresponds to: x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10
//               + x^8  + x^7  + x^5  + x^4  + x^2  + x    + 1
// Ref: ETSI EN 300 392-2 §8.2.5; same as CRC-32 (IEEE 802.3)
// ---------------------------------------------------------------------------
localparam [LFSR_WIDTH-1:0] POLY_MASK = 32'h04C11DB7;

// ---------------------------------------------------------------------------
// Internal wires (combinatorial, _sys domain)
// ---------------------------------------------------------------------------

// Current output bit (LSB before shift)
wire lfsr_out_sys  = lfsr_sys[0];

// Next LFSR state (Galois shift-right with conditional XOR)
wire [LFSR_WIDTH-1:0] lfsr_next_sys =
    {1'b0, lfsr_sys[LFSR_WIDTH-1:1]} ^ ({LFSR_WIDTH{lfsr_out_sys}} & POLY_MASK);

// ---------------------------------------------------------------------------
// lfsr_sys — 32-bit Galois LFSR state
// Reset to all-ones (non-zero, safe default).
// load_init has priority over data_valid.
// LFSR advances only when data_valid=1 (one bit consumed per valid cycle).
// Pipeline Stage 0: scrambling sequence generator
// ---------------------------------------------------------------------------
reg [LFSR_WIDTH-1:0] lfsr_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        lfsr_sys <= {LFSR_WIDTH{1'b1}};
    else if (load_init)
        lfsr_sys <= lfsr_init;
    else if (data_valid)
        lfsr_sys <= lfsr_next_sys;
end

// ---------------------------------------------------------------------------
// data_out — scrambled/descrambled bit (data_in XOR lfsr_out)
// Updated only when data_valid=1 and not loading init.
// Retains last value when idle (data_out_valid indicates validity).
// Pipeline Stage 1: XOR output
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out <= 1'b0;
    else if (data_valid && !load_init)
        data_out <= data_in ^ lfsr_out_sys;
end

// ---------------------------------------------------------------------------
// data_out_valid — follows data_valid by exactly 1 clock cycle
// Goes LOW on load_init to suppress the invalid output cycle.
// Pipeline Stage 1: valid flag
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out_valid <= 1'b0;
    else
        data_out_valid <= data_valid && !load_init;
end

endmodule

`default_nettype wire
