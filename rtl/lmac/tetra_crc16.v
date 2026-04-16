// =============================================================================
// tetra_crc16.v — CRC-16-CCITT Generator / Checker
// =============================================================================
//
// Implements the TETRA Frame Check Sequence (FCS) as defined in
// ETSI EN 300 392-2 §8.2.6.
//
// Algorithm: CRC-16-CCITT X.25 (HDLC-style complemented FCS)
//   Polynomial : G(x) = x^16 + x^12 + x^5 + 1  →  0x1021
//   Initial CRC: 0xFFFF
//   Final XOR  : 0xFFFF (ones-complement before transmission)
//   Bit order  : MSB-first (network byte order, as transmitted in TETRA)
//
// Serial computation (one bit per valid clock cycle):
//   feedback   = data_in_sys XOR crc_out_sys[15]
//   crc_next   = {crc_out_sys[14:0], 1'b0} XOR ({16{feedback}} & 16'h1021)
//
//   Bit positions affected by feedback:
//     [12] — x^12 term
//     [ 5] — x^5  term
//     [ 0] — x^0  term (implicit in shift-and-XOR)
//
// TX mode (FCS generation):
//   1. Assert init_sys for 1 cycle  →  CRC register reloads to 0xFFFF
//   2. Feed data bits via data_in_sys / data_valid_sys (MSB first)
//   3. Assert done_in_sys on the same cycle as the last data_valid_sys,
//      or one cycle after all data bits have been fed
//   4. One cycle later crc_valid_sys pulses HIGH;
//      crc_out_sys holds the 16-bit FCS to transmit (MSB first)
//
// RX mode (FCS verification):
//   1. Assert init_sys for 1 cycle
//   2. Feed data bits followed by the 16 received FCS bits (MSB first)
//   3. Assert done_in_sys on/after the last FCS bit
//   4. One cycle later crc_valid_sys pulses HIGH;
//      crc_ok_sys == 1'b1 iff no bit errors  (residue == 16'h1D0F)
//
// Priority:
//   init_sys overrides data_valid_sys on the same clock edge.
//   done_in_sys may be concurrent with data_valid_sys on the last bit.
//   crc_ok_sys captures crc_next when done+valid are concurrent,
//   otherwise captures crc_out (which already includes the last bit).
//
// Timing:
//   data_in_sys is sampled on the same edge as data_valid_sys.
//   crc_valid_sys and crc_ok_sys are registered — they appear 1 cycle
//   after done_in_sys.
//
// Clock domain: _sys (100 MHz)
//
// Resource estimate: LUT ~20  FF ~18  DSP 0  BRAM 0
//
// =============================================================================

`default_nettype none

module tetra_crc16 (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Control
    input  wire        init_sys,       // 1-cycle pulse: reset CRC register to 0xFFFF
    input  wire        done_in_sys,    // 1-cycle pulse: last bit fed; latch crc_valid/crc_ok

    // Bit-serial data stream (MSB first)
    input  wire        data_in_sys,    // Current data bit
    input  wire        data_valid_sys, // Strobe: process data_in_sys this cycle

    // CRC outputs
    output reg  [15:0] crc_out_sys,   // Running CRC (valid at all times after init)
    output reg         crc_valid_sys, // 1-cycle pulse, 1 cycle after done_in_sys
    output reg         crc_ok_sys     // HIGH 1 cycle after done_in when residue==0x0000
);

// ---------------------------------------------------------------------------
// CRC polynomial feedback mask — G(x) = x^16 + x^12 + x^5 + 1
// Bits [15:0] represent coefficients x^15..x^0; x^16 is implicit in shift.
// ---------------------------------------------------------------------------
localparam [15:0] POLY_MASK = 16'h1021;

// CRC residue for error-free RX: CRC(data || FCS) == CRC_RESIDUE
// For CRC-16-CCITT X.25 (init=0xFFFF, poly=0x1021, final XOR=0xFFFF),
// feeding data + complemented FCS through the CRC engine yields 0x1D0F
// (the "magic" HDLC residue). Matches tetra_hal.c TX-side encoding.
localparam [15:0] CRC_RESIDUE = 16'h1D0F;

// ---------------------------------------------------------------------------
// Combinatorial: one-step CRC update
//   feedback_sys  = MSB of current CRC XOR incoming data bit
//   crc_next_sys  = shift CRC left, XOR in POLY_MASK where feedback=1
// ---------------------------------------------------------------------------

wire        feedback_sys  = data_in_sys ^ crc_out_sys[15];

wire [15:0] crc_next_sys  = {crc_out_sys[14:0], 1'b0}
                           ^ ({16{feedback_sys}} & POLY_MASK);

// ---------------------------------------------------------------------------
// crc_out_sys — 16-bit CRC shift register
//   Reset / init : 0xFFFF
//   init_sys     : reload 0xFFFF (overrides data_valid_sys)
//   data_valid   : advance CRC by one bit
// Pipeline Stage 0: CRC computation
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        crc_out_sys <= 16'hFFFF;
    else if (init_sys)
        crc_out_sys <= 16'hFFFF;
    else if (data_valid_sys)
        crc_out_sys <= crc_next_sys;
end

// ---------------------------------------------------------------------------
// crc_valid_sys — 1-cycle pulse, one cycle after done_in_sys
// Pipeline Stage 1: valid flag
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        crc_valid_sys <= 1'b0;
    else
        crc_valid_sys <= done_in_sys;
end

// ---------------------------------------------------------------------------
// crc_ok_sys — high when residue matches CRC_RESIDUE (RX error check)
//   Sampled at done_in_sys:
//     - If done_in_sys and data_valid_sys are concurrent (last bit):
//       use crc_next_sys (last bit not yet registered in crc_out_sys)
//     - If done_in_sys fires after the last data_valid_sys:
//       use crc_out_sys (already holds final value)
//   Cleared whenever not done_in_sys (not sticky; use crc_valid_sys gating).
// Pipeline Stage 1: RX check flag
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        crc_ok_sys <= 1'b0;
    else if (done_in_sys)
        crc_ok_sys <= (data_valid_sys ? crc_next_sys : crc_out_sys) == CRC_RESIDUE;
    else
        crc_ok_sys <= 1'b0;
end

endmodule

`default_nettype wire
