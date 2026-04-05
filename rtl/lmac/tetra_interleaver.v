// =============================================================================
// tetra_interleaver.v — Block Interleaver / Deinterleaver
// =============================================================================
//
// Implements the TETRA block interleaving (ETSI EN 300 392-2 §8.2.4).
//
// Algorithm — Step Interleaver:
//   FILL phase: write data bits into flat buffer sequentially
//               buf[0], buf[1], ..., buf[K-1] ← data_in (one per valid cycle)
//
//   DRAIN phase: read buffer with permuted address sequence
//               address sequence: 0, STEP, 2×STEP, ..., (K-1)×STEP  (mod K)
//               Since gcd(STEP, K)=1 this visits all K positions exactly once.
//
//   Interleave   (TX, mode=0): STEP = 11   → d[j] = buf[11j mod K]
//   Deinterleave (RX, mode=1): STEP = 59   (K=216: 11⁻¹ mod 216)
//                               STEP = 275  (K=432: 11⁻¹ mod 432)
//
// NOTE: The step value STEP=11 is derived from common TETRA implementations
//   (EN 300 392-2 §8.2.4.3).  Verify against tetra-bluestation reference
//   before field deployment — the standard defines separate step parameters
//   for each logical channel type (SCH/HD, SCH/F, STCH, etc.).
//
// Buffer: flat 432-bit register (R3 compliant: no reg[] array).
//   Variable bit-select on LHS/RHS synthesizes to write-enable decode + MUX
//   in Vivado.  Maps to ~432 FF + ~432 LUT.
//
// Latency:
//   One block latency: FILL completes, then DRAIN begins immediately.
//   First data_out_valid fires 2 cycles after the last data_in_valid of FILL:
//     cycle 0 (last FILL):  buf[K-1] written, state→S_DRAIN
//     cycle 1 (first DRAIN): rd_addr=0, buf[0] combinatorially available
//                             → data_out registered, data_out_valid registered
//     cycle 2: data_out_valid HIGH, data_out = d[0] (first output bit)
//
// block_done:
//   Registered one cycle after the last data_out_valid cycle.
//
// block_size:
//   Must be in [1, MAX_BLOCK_SIZE].  Supported values: 216 (NDB), 432 (SCH/F).
//   Software must assert block_size before the first data_in_valid of each block.
//   block_size must remain stable during the fill and drain phases.
//
// Clock domain: _sys (100 MHz)
//
// Resource estimate (MAX_BLOCK_SIZE=432):
//   LUT ~500  FF ~458  DSP 0  BRAM 0
//   (432 FF buffer + 9 FF counters + ~500 LUT for MUX tree and logic)
//
// =============================================================================

`default_nettype none

module tetra_interleaver #(
    parameter MAX_BLOCK_SIZE = 432   // bits; covers NDB (216) and SCH/F (432)
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Mode: 0=Interleave (TX), 1=Deinterleave (RX)
    input  wire        mode,

    // Current block size (216 for NDB blocks, 432 for SCH/F)
    // Must be stable for the entire fill+drain cycle.
    input  wire [8:0]  block_size,

    // Input stream (bit-serial, with backpressure support)
    input  wire        data_in,
    input  wire        data_in_valid,

    // Output stream (bit-serial, no backpressure on output side)
    output reg         data_out,
    output reg         data_out_valid,
    output reg         block_done      // one-cycle pulse after last output bit
);

// ---------------------------------------------------------------------------
// Step constants (EN 300 392-2 §8.2.4.3)
// ---------------------------------------------------------------------------
// Interleaving step (TX): STEP=11 for all block sizes.
// Deinterleaving step (RX): modular inverse of 11 mod K.
//   K=216: 11^{-1} mod 216 = 59   (verify: 11×59 = 649 = 3×216+1 ✓)
//   K=432: 11^{-1} mod 432 = 275  (verify: 11×275 = 3025 = 7×432+1 ✓)
localparam [8:0] STEP_TX        = 9'd11;
localparam [8:0] STEP_RX_NDB    = 9'd59;    // K=216
localparam [8:0] STEP_RX_SCHF   = 9'd275;   // K=432

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam S_FILL  = 1'b0;   // accepting input bits (fill buffer)
localparam S_DRAIN = 1'b1;   // outputting permuted bits (drain buffer)

// ---------------------------------------------------------------------------
// Internal signals
// ---------------------------------------------------------------------------

// FSM
reg        state_sys;
reg        next_state_sys;

// Write address: sequential 0..K-1 during FILL
reg [8:0]  wr_addr_sys;

// Read address: permuted sequence during DRAIN
reg [8:0]  rd_addr_sys;

// Drain bit counter: how many bits output so far in DRAIN phase
reg [8:0]  drain_cnt_sys;

// Flat data buffer (R3: no array declaration — variable bit-select only)
reg [MAX_BLOCK_SIZE-1:0] buf_sys;

// ---------------------------------------------------------------------------
// Combinatorial signals
// ---------------------------------------------------------------------------

// Read step: depends on mode and block_size
wire [8:0] rd_step_sys = mode ?
    ((block_size == 9'd432) ? STEP_RX_SCHF : STEP_RX_NDB) :
    STEP_TX;

// Fill-done: last input bit of the block
wire fill_done_sys = (state_sys == S_FILL) && data_in_valid &&
                     (wr_addr_sys == block_size - 9'd1);

// Drain-done: last output bit of the block
wire drain_done_sys = (state_sys == S_DRAIN) &&
                      (drain_cnt_sys == block_size - 9'd1);

// Combinatorial read from buffer (0-cycle read, output registered)
wire rd_bit_sys = buf_sys[rd_addr_sys];

// Next read address with modular step
wire [9:0] rd_next_wide_sys = {1'b0, rd_addr_sys} + {1'b0, rd_step_sys};
wire [8:0] rd_next_sys = (rd_next_wide_sys >= {1'b0, block_size}) ?
                          rd_next_wide_sys[8:0] - block_size[8:0] :
                          rd_next_wide_sys[8:0];

// ---------------------------------------------------------------------------
// FSM — State Register  (R4, R5)
// Pipeline Stage 0: FSM
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_FILL;
    else
        state_sys <= next_state_sys;
end

// FSM — Next-State Logic (R5: combinatorial block, R10: @(*))
always @(*) begin
    next_state_sys = state_sys;
    case (state_sys)
        S_FILL:  if (fill_done_sys)  next_state_sys = S_DRAIN;
        S_DRAIN: if (drain_done_sys) next_state_sys = S_FILL;
        default: next_state_sys = S_FILL;
    endcase
end

// ---------------------------------------------------------------------------
// wr_addr_sys — write address counter, sequential 0..K-1 during FILL
// Resets to 0 on drain-to-fill transition.
// Pipeline Stage 0: write address
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        wr_addr_sys <= 9'd0;
    else if (state_sys == S_DRAIN)
        wr_addr_sys <= 9'd0;   // reset for next fill phase
    else if (state_sys == S_FILL && data_in_valid)
        wr_addr_sys <= (wr_addr_sys == block_size - 9'd1) ? 9'd0 : wr_addr_sys + 9'd1;
end

// ---------------------------------------------------------------------------
// buf_sys — flat data buffer, MAX_BLOCK_SIZE bits
// Write: variable bit-select on LHS during FILL phase (Vivado-synthesizable).
// Read: variable bit-select on RHS (combinatorial rd_bit_sys wire above).
// R3: not declared as an array reg[7:0][]; uses indexed bit-select instead.
// Pipeline Stage 1: bit storage
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        buf_sys <= {MAX_BLOCK_SIZE{1'b0}};
    else if (state_sys == S_FILL && data_in_valid)
        buf_sys[wr_addr_sys] <= data_in;
end

// ---------------------------------------------------------------------------
// rd_addr_sys — permuted read address during DRAIN
// Steps by rd_step_sys modulo block_size each drain cycle.
// Reset to 0 when not in DRAIN state.
// Pipeline Stage 1: read address
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        rd_addr_sys <= 9'd0;
    else if (state_sys == S_FILL)
        rd_addr_sys <= 9'd0;
    else if (state_sys == S_DRAIN)
        rd_addr_sys <= rd_next_sys;
end

// ---------------------------------------------------------------------------
// drain_cnt_sys — counts output bits during DRAIN phase
// Reset to 0 on fill-to-drain transition and when not draining.
// Pipeline Stage 1: drain counter
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        drain_cnt_sys <= 9'd0;
    else if (state_sys == S_FILL)
        drain_cnt_sys <= 9'd0;
    else if (state_sys == S_DRAIN)
        drain_cnt_sys <= drain_cnt_sys + 9'd1;
end

// ---------------------------------------------------------------------------
// data_out — registered permuted bit from buffer
// Captured on every DRAIN cycle from combinatorial rd_bit_sys.
// Pipeline Stage 2: output data
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out <= 1'b0;
    else if (state_sys == S_DRAIN)
        data_out <= rd_bit_sys;
end

// ---------------------------------------------------------------------------
// data_out_valid — HIGH during drain phase (registered, 1-cycle latency)
// Goes HIGH one cycle after entering S_DRAIN, stays until last bit.
// Pipeline Stage 2: output valid
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out_valid <= 1'b0;
    else
        data_out_valid <= (state_sys == S_DRAIN);
end

// ---------------------------------------------------------------------------
// block_done — one-cycle pulse one cycle after last output bit
// Pipeline Stage 3: completion signal
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        block_done <= 1'b0;
    else
        block_done <= drain_done_sys;
end

endmodule

`default_nettype wire
