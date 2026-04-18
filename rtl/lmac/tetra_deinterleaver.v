// =============================================================================
// tetra_deinterleaver.v — Block Deinterleaver (RX)
// =============================================================================
//
// ETSI EN 300 392-2 §8.2.4.1 — Multiplicative Deinterleaver.
//
// RX direction (decoding):
//   out[i-1] = in[k-1],  k = 1 + (a·i) mod K   (osmo-tetra block_deinterleave)
//
// Implementation:
//   FILL phase:  input arrives sequentially → write to buf[0..K-1].
//   DRAIN phase: read with permuted address: rd_addr starts at a, steps by a.
//                → for output position i=1..K: read buf[(a*i) mod K] = buf[k-1].
//                → out[i-1] = in[k-1].  ✓
//
// Cross-checked against:
//   - osmo-tetra  block_deinterleave():  out[i-1] = in[k-1]
//   - decode_bnch.py  etsi_deinterleave_bnch():  out[i-1] = bits[k-1]
//   - SDRSharp.Tetra.dll  Deinterleave::Process
//
// Parameters per ETSI Table 8.19:
//   BSCH  sb1  (K=120): a=11
//   BNCH / SCH/HD / STCH (K=216): a=101
//   SCH/F / TCH/2.4      (K=432): a=103
//
// Clock domain: clk_sys (100 MHz)
// Resource estimate (MAX_BLOCK_SIZE=432):
//   ~500 LUT, ~460 FF, 0 DSP, 0 BRAM
// =============================================================================

`default_nettype none

module tetra_deinterleaver #(
    parameter MAX_BLOCK_SIZE = 432
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    input  wire [8:0]  block_size,    // 120, 216, or 432

    input  wire        data_in,
    input  wire        data_in_valid,

    output reg         data_out,
    output reg         data_out_valid,
    output reg         block_done
);

// ---------------------------------------------------------------------------
// ETSI multiplicative 'a' parameter
// ---------------------------------------------------------------------------
localparam [8:0] STEP_BSCH = 9'd11;
localparam [8:0] STEP_BNCH = 9'd101;
localparam [8:0] STEP_SCHF = 9'd103;

wire [8:0] a_param = (block_size == 9'd432) ? STEP_SCHF :
                     (block_size == 9'd216) ? STEP_BNCH :
                                              STEP_BSCH;

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
localparam S_FILL  = 1'b0;
localparam S_DRAIN = 1'b1;

reg       state;
reg       next_state;

reg [8:0] wr_addr;     // sequential write address during FILL
reg [8:0] rd_addr;     // permuted read address during DRAIN
reg [8:0] drain_cnt;

reg [MAX_BLOCK_SIZE-1:0] buf_data;

// ---------------------------------------------------------------------------
// Next read address: rd_addr steps by 'a' (mod K)
// ---------------------------------------------------------------------------
wire [9:0] rd_next_wide = {1'b0, rd_addr} + {1'b0, a_param};
wire [8:0] rd_next      = (rd_next_wide >= {1'b0, block_size}) ?
                            rd_next_wide[8:0] - block_size[8:0] :
                            rd_next_wide[8:0];

wire fill_done  = (state == S_FILL) && data_in_valid &&
                  (wr_addr == block_size - 9'd1);
wire drain_done = (state == S_DRAIN) &&
                  (drain_cnt == block_size - 9'd1);

wire rd_bit = buf_data[rd_addr];

// ---------------------------------------------------------------------------
// FSM state register
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state <= S_FILL;
    else
        state <= next_state;
end

always @(*) begin
    next_state = state;
    case (state)
        S_FILL:  if (fill_done)  next_state = S_DRAIN;
        S_DRAIN: if (drain_done) next_state = S_FILL;
        default: next_state = S_FILL;
    endcase
end

// ---------------------------------------------------------------------------
// wr_addr — sequential write address (0, 1, 2, ..., K-1)
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        wr_addr <= 9'd0;
    else if (state == S_DRAIN)
        wr_addr <= 9'd0;
    else if (state == S_FILL && data_in_valid)
        wr_addr <= (wr_addr == block_size - 9'd1) ? 9'd0 : wr_addr + 9'd1;
end

// ---------------------------------------------------------------------------
// buf_data — sequential write during FILL
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        buf_data <= {MAX_BLOCK_SIZE{1'b0}};
    else if (state == S_FILL && data_in_valid)
        buf_data[wr_addr] <= data_in;
end

// ---------------------------------------------------------------------------
// rd_addr — permuted read address (starts at a, steps by a mod K)
// ETSI: for output position i=1..K, read from k-1 = (a*i) mod K
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        rd_addr <= 9'd0;
    else if (state == S_FILL)
        rd_addr <= a_param;          // first read at addr = a
    else if (state == S_DRAIN)
        rd_addr <= rd_next;
end

// ---------------------------------------------------------------------------
// drain_cnt — counts output bits during DRAIN
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        drain_cnt <= 9'd0;
    else if (state == S_FILL)
        drain_cnt <= 9'd0;
    else if (state == S_DRAIN)
        drain_cnt <= drain_cnt + 9'd1;
end

// ---------------------------------------------------------------------------
// data_out — registered permuted read from buffer
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out <= 1'b0;
    else if (state == S_DRAIN)
        data_out <= rd_bit;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        data_out_valid <= 1'b0;
    else
        data_out_valid <= (state == S_DRAIN);
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        block_done <= 1'b0;
    else
        block_done <= drain_done;
end

endmodule
`default_nettype wire
