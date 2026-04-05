// =============================================================================
// Module:      tetra_ad9361_interface
// Project:     tetra-zynq-phy
// File:        rtl/tetra_ad9361_interface.v
//
// Description: AD9361 LVDS DDR interface — serializes/deserializes the AD9361
//   DDR LVDS data stream into signed IQ samples for the downstream RX chain.
//
//   AD9361 LVDS DDR timing (1R1T mode, 6 data lanes × DDR = 12 bits/cycle):
//
//     DATA_CLK cycle N  (RX_FRAME = 1, I sample):
//       Rising  edge: DATA[5:0] = I_sample[11:6]   (upper 6 bits)
//       Falling edge: DATA[5:0] = I_sample[5:0]    (lower 6 bits)
//
//     DATA_CLK cycle N+1 (RX_FRAME = 0, Q sample):
//       Rising  edge: DATA[5:0] = Q_sample[11:6]   (upper 6 bits)
//       Falling edge: DATA[5:0] = Q_sample[5:0]    (lower 6 bits)
//
//     → Output IQ pair rate = DATA_CLK / 2
//     → RX_FRAME is a level signal: high for full I cycle, low for full Q cycle
//
//   Xilinx 7-Series primitives used:
//     IBUFDS                  — differential input buffer (clock, frame, data)
//     BUFG                    — global clock buffer for DATA_CLK distribution
//     IDDR (SAME_EDGE_PIPELINED) — DDR capture (Q1/Q2 both on rising edge +1)
//     ODDR (SAME_EDGE)        — DDR output for TX path and feedback clock
//     OBUFDS                  — differential output buffer (TX, FB_CLK)
//
//   IDDR SAME_EDGE_PIPELINED latency: 1 clk_lvds cycle
//     At rising edge M: Q1 = data from rising edge of M-1
//                       Q2 = data from falling edge of M-1
//
//   RX pipeline (clk_lvds domain):
//     Stage 0 — IBUFDS + IDDR: raw DDR capture (1 cycle IDDR latency)
//     Stage 1 — I/Q assembly: detect I/Q frame, assemble 12-bit sample
//     Stage 2 — Output register: sign-extend to IQ_WIDTH, assert rx_valid_lvds
//
// Ports:
//   rst_n_lvds         i  1      Sync active-low reset, clk_lvds domain
//                                (from tetra_clk_reset; must be stable before use)
//   ad9361_data_clk_p  i  1      LVDS DATA_CLK+ (DDR clock from AD9361)
//   ad9361_data_clk_n  i  1      LVDS DATA_CLK-
//   ad9361_rx_frame_p  i  1      LVDS RX_FRAME+ (H=I cycle, L=Q cycle)
//   ad9361_rx_frame_n  i  1      LVDS RX_FRAME-
//   ad9361_rx_data_p   i  6      LVDS RX_DATA+[5:0] (6 data lanes)
//   ad9361_rx_data_n   i  6      LVDS RX_DATA-[5:0]
//   ad9361_fb_clk_p    o  1      LVDS Feedback clock+ (DATA_CLK echo to AD9361)
//   ad9361_fb_clk_n    o  1      LVDS Feedback clock-
//   ad9361_tx_frame_p  o  1      LVDS TX_FRAME+
//   ad9361_tx_frame_n  o  1      LVDS TX_FRAME-
//   ad9361_tx_data_p   o  6      LVDS TX_DATA+[5:0]
//   ad9361_tx_data_n   o  6      LVDS TX_DATA-[5:0]
//   rx_enable          i  1      Enable RX path (async control, DC-level signal)
//   tx_enable          i  1      Enable TX path (async control, DC-level signal)
//   clk_lvds           o  1      Buffered DATA_CLK (global routing via BUFG)
//   rx_i_lvds          o IQ_W    RX I sample, sign-extended, clk_lvds domain
//   rx_q_lvds          o IQ_W    RX Q sample, sign-extended, clk_lvds domain
//   rx_valid_lvds      o  1      One-cycle pulse per valid IQ pair
//   tx_i_lvds          i IQ_W    TX I sample, clk_lvds domain (from CIC interpolator)
//   tx_q_lvds          i IQ_W    TX Q sample, clk_lvds domain
//   tx_valid_lvds      i  1      TX data valid strobe (must hold until accepted)
//
// Parameters:
//   IQ_WIDTH  = 16    Output/input IQ sample width (sign-extended from 12-bit)
//
// Resource Estimate:
//   ~150 LUT, ~100 FF, 0 DSP48, 0 BRAM18k
//   (I/O primitives use I/O bank resources, not fabric LUT/FF)
//
// CDC documented in: docs/timing_analysis.md
//   iq_sample[11:0]: clk_lvds → clk_sys via XPM Async FIFO in tetra_rx_frontend.v
//
// Ref: AD9361 Reference Manual UG-570, §5 (LVDS Parallel Data Port)
//      Xilinx UG472 "7 Series FPGAs SelectIO Resources" (IBUFDS, IDDR, ODDR)
//      ETSI EN 300 392-2 §9.1 (TETRA symbol rate — determines DATA_CLK rate)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_ad9361_interface #(
    parameter IQ_WIDTH = 16    // Output IQ width; must be >= 12 (ADC native bits)
)(
    // ------------------------------------------------------------------
    // Reset — clk_lvds domain (from tetra_clk_reset)
    // ------------------------------------------------------------------
    input  wire                    rst_n_lvds,

    // ------------------------------------------------------------------
    // AD9361 LVDS RX Interface
    // ------------------------------------------------------------------
    input  wire                    ad9361_data_clk_p,   // DATA_CLK+
    input  wire                    ad9361_data_clk_n,   // DATA_CLK-
    input  wire                    ad9361_rx_frame_p,   // RX_FRAME+
    input  wire                    ad9361_rx_frame_n,   // RX_FRAME-
    input  wire [5:0]              ad9361_rx_data_p,    // RX_DATA+[5:0]
    input  wire [5:0]              ad9361_rx_data_n,    // RX_DATA-[5:0]

    // ------------------------------------------------------------------
    // AD9361 LVDS TX Interface
    // ------------------------------------------------------------------
    output wire                    ad9361_fb_clk_p,     // Feedback clock+
    output wire                    ad9361_fb_clk_n,     // Feedback clock-
    output wire                    ad9361_tx_frame_p,   // TX_FRAME+
    output wire                    ad9361_tx_frame_n,   // TX_FRAME-
    output wire [5:0]              ad9361_tx_data_p,    // TX_DATA+[5:0]
    output wire [5:0]              ad9361_tx_data_n,    // TX_DATA-[5:0]

    // ------------------------------------------------------------------
    // AD9361 Control (DC-level control signals; driven from AXI registers)
    // These are quasi-static — no CDC required.
    // ------------------------------------------------------------------
    input  wire                    rx_enable,           // 1 = RX active
    input  wire                    tx_enable,           // 1 = TX active

    // ------------------------------------------------------------------
    // Recovered DATA_CLK for downstream modules (clk_lvds domain)
    // ------------------------------------------------------------------
    output wire                    clk_lvds,            // Buffered DATA_CLK

    // ------------------------------------------------------------------
    // RX IQ Output — clk_lvds domain
    // Sign-extended from 12-bit ADC to IQ_WIDTH.
    // Valid pulse: rx_valid_lvds high for exactly 1 cycle per IQ pair.
    // CDC to clk_sys domain: done in tetra_rx_frontend.v (XPM Async FIFO).
    // ------------------------------------------------------------------
    output reg  signed [IQ_WIDTH-1:0] rx_i_lvds,
    output reg  signed [IQ_WIDTH-1:0] rx_q_lvds,
    output reg                         rx_valid_lvds,

    // ------------------------------------------------------------------
    // TX IQ Input — clk_lvds domain (from tetra_tx_frontend via CIC interp.)
    // tx_valid_lvds: must be asserted for exactly 1 cycle when I/Q pair ready.
    // tx_i_lvds/tx_q_lvds must be stable during the valid cycle.
    // ------------------------------------------------------------------
    input  wire signed [IQ_WIDTH-1:0] tx_i_lvds,
    input  wire signed [IQ_WIDTH-1:0] tx_q_lvds,
    input  wire                        tx_valid_lvds
);

// =============================================================================
// Internal Width Constant
// =============================================================================

localparam AD9361_BITS = 12;                        // AD9361 native ADC/DAC width
localparam SIGN_EXT    = IQ_WIDTH - AD9361_BITS;    // Extension bits (e.g., 4 for 16-bit)

// =============================================================================
// IBUFDS — Differential Input Buffers (LVDS → single-ended)
// =============================================================================

wire clk_lvds_ibuf;     // DATA_CLK after IBUFDS, before global buffer
wire rxframe_buf;       // RX_FRAME single-ended
wire rxdata_buf_0;      // RX_DATA[0] single-ended
wire rxdata_buf_1;      // RX_DATA[1] single-ended
wire rxdata_buf_2;      // RX_DATA[2] single-ended
wire rxdata_buf_3;      // RX_DATA[3] single-ended
wire rxdata_buf_4;      // RX_DATA[4] single-ended
wire rxdata_buf_5;      // RX_DATA[5] single-ended

// DATA_CLK — differential input
// DIFF_TERM=TRUE: internal termination (LibreSDR board has no external termination)
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_clk_ibuf (
    .I  (ad9361_data_clk_p),
    .IB (ad9361_data_clk_n),
    .O  (clk_lvds_ibuf)
);

// RX_FRAME
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxframe_ibuf (
    .I  (ad9361_rx_frame_p),
    .IB (ad9361_rx_frame_n),
    .O  (rxframe_buf)
);

// RX_DATA[0] — Lane 0 (LSB of each 6-bit half-word)
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata0_ibuf (
    .I  (ad9361_rx_data_p[0]),
    .IB (ad9361_rx_data_n[0]),
    .O  (rxdata_buf_0)
);

// RX_DATA[1]
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata1_ibuf (
    .I  (ad9361_rx_data_p[1]),
    .IB (ad9361_rx_data_n[1]),
    .O  (rxdata_buf_1)
);

// RX_DATA[2]
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata2_ibuf (
    .I  (ad9361_rx_data_p[2]),
    .IB (ad9361_rx_data_n[2]),
    .O  (rxdata_buf_2)
);

// RX_DATA[3]
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata3_ibuf (
    .I  (ad9361_rx_data_p[3]),
    .IB (ad9361_rx_data_n[3]),
    .O  (rxdata_buf_3)
);

// RX_DATA[4]
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata4_ibuf (
    .I  (ad9361_rx_data_p[4]),
    .IB (ad9361_rx_data_n[4]),
    .O  (rxdata_buf_4)
);

// RX_DATA[5] — Lane 5 (MSB of each 6-bit half-word)
IBUFDS #(
    .DIFF_TERM   ("TRUE"),
    .IBUF_LOW_PWR("FALSE")
) u_rxdata5_ibuf (
    .I  (ad9361_rx_data_p[5]),
    .IB (ad9361_rx_data_n[5]),
    .O  (rxdata_buf_5)
);

// =============================================================================
// BUFG — Global Clock Buffer for DATA_CLK
//
// Distributes clk_lvds across the fabric via global routing network.
// For TETRA application DATA_CLK ≤ ~2 MHz → well within BUFG specs.
// For higher sample rates (future use), BUFIO + BUFR may be preferred.
// =============================================================================

BUFG u_clk_bufg (
    .I (clk_lvds_ibuf),
    .O (clk_lvds)
);

// =============================================================================
// IDDR — DDR Data Capture (SAME_EDGE_PIPELINED mode)
//
// SAME_EDGE_PIPELINED:
//   At rising edge M of clk_lvds:
//     Q1 = data sampled at rising  edge of cycle M-1
//     Q2 = data sampled at falling edge of cycle M-1
//   Both outputs are registered and available at the same rising edge (M).
//   Latency: 1 clk_lvds cycle.
//
// R and S connected to 1'b0 — no forced reset/set of IDDR FFs.
// The downstream pipeline registers handle reset via rst_n_lvds.
// =============================================================================

// IDDR outputs: rising-edge captures and falling-edge captures
wire       q1_rxframe_lvds;    // RX_FRAME from rising  edge of prev cycle
wire       q2_rxframe_lvds;    // RX_FRAME from falling edge of prev cycle

// Pipeline Stage 0 (output): q1 = D[11:6], q2 = D[5:0]  (for I or Q half-words)
wire [5:0] q1_rxdata_lvds;     // Upper 6 bits of current sample
wire [5:0] q2_rxdata_lvds;     // Lower 6 bits of current sample

// RX_FRAME IDDR
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxframe (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxframe_buf),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxframe_lvds),
    .Q2 (q2_rxframe_lvds)
);

// RX_DATA[0] IDDR  — bit 0 of each 6-bit half-word (LSB of sample)
// Pipeline Stage 0: q1_rxdata_lvds[0] = D0_rise, q2_rxdata_lvds[0] = D0_fall
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata0 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_0),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[0]),
    .Q2 (q2_rxdata_lvds[0])
);

// RX_DATA[1] IDDR
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata1 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_1),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[1]),
    .Q2 (q2_rxdata_lvds[1])
);

// RX_DATA[2] IDDR
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata2 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_2),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[2]),
    .Q2 (q2_rxdata_lvds[2])
);

// RX_DATA[3] IDDR
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata3 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_3),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[3]),
    .Q2 (q2_rxdata_lvds[3])
);

// RX_DATA[4] IDDR
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata4 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_4),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[4]),
    .Q2 (q2_rxdata_lvds[4])
);

// RX_DATA[5] IDDR  — bit 5 of each 6-bit half-word (MSB of the half-word)
IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
    .INIT_Q1     (1'b0),
    .INIT_Q2     (1'b0),
    .SRTYPE      ("SYNC")
) u_iddr_rxdata5 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D  (rxdata_buf_5),
    .R  (1'b0),
    .S  (1'b0),
    .Q1 (q1_rxdata_lvds[5]),
    .Q2 (q2_rxdata_lvds[5])
);

// =============================================================================
// RX Data Assembly — Pipeline Stage 1
//
// After IDDR (Stage 0), at each rising edge of clk_lvds:
//   q1_rxframe_lvds = frame signal from the PREVIOUS DATA_CLK cycle
//   q1_rxdata_lvds  = upper 6 bits (was driven at rising  edge of prev cycle)
//   q2_rxdata_lvds  = lower 6 bits (was driven at falling edge of prev cycle)
//
// When q1_rxframe_lvds = 1 (I cycle just captured):
//   Latch I raw sample: i_raw_lvds = {q1_rxdata_lvds, q2_rxdata_lvds}
//
// When q1_rxframe_lvds = 0 (Q cycle just captured):
//   Q raw sample is directly available from IDDR outputs.
//   Detect falling edge of frame → trigger output stage.
//
// "Falling edge" of captured frame: q1_rxframe_prev was 1, now is 0
//   → Both I (from i_raw_lvds) and Q (from IDDR output) are ready.
// =============================================================================

// Stage 0 → Stage 1 pipeline: captured I sample (12-bit raw)
reg [AD9361_BITS-1:0] i_raw_lvds;

// Previous frame value — used to detect I→Q transition
reg                    q1_rxframe_prev_lvds;

// Frame-locked flag: goes HIGH after first valid I phase seen after reset.
// Prevents spurious valid on the first Q after reset (I may not have been captured).
reg                    frame_locked_lvds;

// Combinatorial frame-fall detection (I→Q transition in IDDR output)
// This is asserted for exactly 1 clk_lvds cycle.
wire frame_fall_lvds;
assign frame_fall_lvds = q1_rxframe_prev_lvds & ~q1_rxframe_lvds & frame_locked_lvds;

// Pipeline Stage 1: capture I raw sample when frame = 1 (I cycle)
// One always block per register (R1)
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        i_raw_lvds <= {AD9361_BITS{1'b0}};
    else if (q1_rxframe_lvds)
        i_raw_lvds <= {q1_rxdata_lvds, q2_rxdata_lvds};
end

// Pipeline Stage 1: track previous frame value for edge detection
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        q1_rxframe_prev_lvds <= 1'b0;
    else
        q1_rxframe_prev_lvds <= q1_rxframe_lvds;
end

// Frame-locked: set HIGH after first I phase seen, stays HIGH until reset.
// Ensures we have a valid i_raw_lvds before asserting rx_valid_lvds.
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        frame_locked_lvds <= 1'b0;
    else if (q1_rxframe_lvds)
        frame_locked_lvds <= 1'b1;
end

// =============================================================================
// RX Output Registers — Pipeline Stage 2
//
// On frame_fall_lvds (the cycle where Q data is available from IDDR):
//   rx_i_lvds ← sign-extend(i_raw_lvds)    [captured in Stage 1]
//   rx_q_lvds ← sign-extend({q1,q2})        [directly from IDDR outputs]
//   rx_valid_lvds ← 1 (one-cycle pulse)
//
// Note on sign extension (12 → IQ_WIDTH bits):
//   Upper SIGN_EXT bits = replicate bit [AD9361_BITS-1] (the sign bit)
//   Lower AD9361_BITS = raw value unchanged
// =============================================================================

// Pipeline Stage 2: RX I output register
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        rx_i_lvds <= {IQ_WIDTH{1'b0}};
    else if (frame_fall_lvds)
        rx_i_lvds <= {{SIGN_EXT{i_raw_lvds[AD9361_BITS-1]}}, i_raw_lvds};
end

// Pipeline Stage 2: RX Q output register
// Q data is taken directly from IDDR outputs (current cycle's falling/rising bits)
// rather than q_raw register, to avoid 1-cycle extra latency.
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        rx_q_lvds <= {IQ_WIDTH{1'b0}};
    else if (frame_fall_lvds)
        rx_q_lvds <= {{SIGN_EXT{q1_rxdata_lvds[AD9361_BITS-7]}},
                      q1_rxdata_lvds,
                      q2_rxdata_lvds};
end

// Pipeline Stage 2: RX valid pulse
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        rx_valid_lvds <= 1'b0;
    else
        rx_valid_lvds <= frame_fall_lvds;
end

// =============================================================================
// TX Path
//
// The TX path generates a continuous DDR stream on the AD9361 TX lines.
// TX data comes from the clk_lvds domain (from tetra_tx_frontend via CIC
// interpolation — see tetra_tx_frontend.v for clk_sys→clk_lvds CDC).
//
// TX state machine: alternates between I and Q cycles.
//   tx_state_lvds = 0: I cycle  — TX_FRAME=1, output tx_i_capture[11:6/5:0]
//   tx_state_lvds = 1: Q cycle  — TX_FRAME=0, output tx_q_capture[11:6/5:0]
//
// When tx_valid_lvds is asserted at the start of the I cycle, tx_i/tx_q are
// latched. When tx_valid_lvds is not asserted, zeros are transmitted.
//
// ODDR D1 = rising edge data, D2 = falling edge data
// TX_FRAME ODDR: D1=D2=1 (I cycle) or D1=D2=0 (Q cycle)
//
// Phase 1 note: TX is infrastructure-complete but outputs zeros since
// the upper layers (LMAC TX, tetra_tx_frontend) are not yet implemented.
// =============================================================================

// TX state register: 0=I_cycle, 1=Q_cycle
reg tx_state_lvds;

// Latched TX I/Q samples (12-bit from IQ_WIDTH input)
reg [AD9361_BITS-1:0] tx_i_capture_lvds;
reg [AD9361_BITS-1:0] tx_q_capture_lvds;

// TX state machine — toggle every clk_lvds cycle
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        tx_state_lvds <= 1'b0;
    else
        tx_state_lvds <= ~tx_state_lvds;
end

// Latch TX I sample when tx_valid asserted during I cycle
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        tx_i_capture_lvds <= {AD9361_BITS{1'b0}};
    else if (tx_valid_lvds && !tx_state_lvds)    // valid + in I cycle
        tx_i_capture_lvds <= tx_i_lvds[AD9361_BITS-1:0];
end

// Latch TX Q sample when tx_valid asserted during Q cycle
always @(posedge clk_lvds or negedge rst_n_lvds) begin
    if (!rst_n_lvds)
        tx_q_capture_lvds <= {AD9361_BITS{1'b0}};
    else if (tx_valid_lvds && tx_state_lvds)     // valid + in Q cycle
        tx_q_capture_lvds <= tx_q_lvds[AD9361_BITS-1:0];
end

// TX ODDR data mux — combinatorial
// Selects upper/lower 6 bits based on current TX state
wire [5:0] tx_data_d1_lvds;    // D1 for ODDR (rising edge output)
wire [5:0] tx_data_d2_lvds;    // D2 for ODDR (falling edge output)
wire       tx_frame_d_lvds;    // TX_FRAME level (same on both edges)

assign tx_data_d1_lvds = (~tx_state_lvds) ?
    tx_i_capture_lvds[AD9361_BITS-1:AD9361_BITS-6] :  // I cycle: upper 6 bits
    tx_q_capture_lvds[AD9361_BITS-1:AD9361_BITS-6];   // Q cycle: upper 6 bits

assign tx_data_d2_lvds = (~tx_state_lvds) ?
    tx_i_capture_lvds[5:0] :   // I cycle: lower 6 bits
    tx_q_capture_lvds[5:0];    // Q cycle: lower 6 bits

// TX_FRAME: HIGH during I cycle (tx_state=0), LOW during Q cycle (tx_state=1)
assign tx_frame_d_lvds = ~tx_state_lvds;

// =============================================================================
// ODDR — TX DDR Output
// =============================================================================

wire       fb_clk_oddr_lvds;
wire       tx_frame_oddr_lvds;
wire [5:0] tx_data_oddr_lvds;

// Feedback clock: D1=1, D2=0 → generates a square wave at DATA_CLK rate
// This echoes DATA_CLK back to the AD9361 for TX synchronization.
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_fbclk (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (1'b1),
    .D2 (1'b0),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (fb_clk_oddr_lvds)
);

// TX_FRAME ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txframe (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_frame_d_lvds),
    .D2 (tx_frame_d_lvds),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_frame_oddr_lvds)
);

// TX_DATA[0] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata0 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[0]),
    .D2 (tx_data_d2_lvds[0]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[0])
);

// TX_DATA[1] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata1 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[1]),
    .D2 (tx_data_d2_lvds[1]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[1])
);

// TX_DATA[2] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata2 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[2]),
    .D2 (tx_data_d2_lvds[2]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[2])
);

// TX_DATA[3] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata3 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[3]),
    .D2 (tx_data_d2_lvds[3]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[3])
);

// TX_DATA[4] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata4 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[4]),
    .D2 (tx_data_d2_lvds[4]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[4])
);

// TX_DATA[5] ODDR
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT        (1'b0),
    .SRTYPE      ("SYNC")
) u_oddr_txdata5 (
    .C  (clk_lvds),
    .CE (1'b1),
    .D1 (tx_data_d1_lvds[5]),
    .D2 (tx_data_d2_lvds[5]),
    .R  (1'b0),
    .S  (1'b0),
    .Q  (tx_data_oddr_lvds[5])
);

// =============================================================================
// OBUFDS — Differential Output Buffers (single-ended ODDR → LVDS pins)
// =============================================================================

// Feedback clock
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_fbclk (
    .I  (fb_clk_oddr_lvds),
    .O  (ad9361_fb_clk_p),
    .OB (ad9361_fb_clk_n)
);

// TX_FRAME
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txframe (
    .I  (tx_frame_oddr_lvds),
    .O  (ad9361_tx_frame_p),
    .OB (ad9361_tx_frame_n)
);

// TX_DATA[0]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata0 (
    .I  (tx_data_oddr_lvds[0]),
    .O  (ad9361_tx_data_p[0]),
    .OB (ad9361_tx_data_n[0])
);

// TX_DATA[1]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata1 (
    .I  (tx_data_oddr_lvds[1]),
    .O  (ad9361_tx_data_p[1]),
    .OB (ad9361_tx_data_n[1])
);

// TX_DATA[2]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata2 (
    .I  (tx_data_oddr_lvds[2]),
    .O  (ad9361_tx_data_p[2]),
    .OB (ad9361_tx_data_n[2])
);

// TX_DATA[3]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata3 (
    .I  (tx_data_oddr_lvds[3]),
    .O  (ad9361_tx_data_p[3]),
    .OB (ad9361_tx_data_n[3])
);

// TX_DATA[4]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata4 (
    .I  (tx_data_oddr_lvds[4]),
    .O  (ad9361_tx_data_p[4]),
    .OB (ad9361_tx_data_n[4])
);

// TX_DATA[5]
OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW      ("FAST")
) u_obufds_txdata5 (
    .I  (tx_data_oddr_lvds[5]),
    .O  (ad9361_tx_data_p[5]),
    .OB (ad9361_tx_data_n[5])
);

// =============================================================================
// Unused signal tie-offs
// rx_enable and tx_enable are reserved for future gating.
// Currently the pipeline is always active; upper layers gate via valid signals.
// =============================================================================
// synthesis translate_off
// Suppress "unused signal" warnings during lint
wire unused_ok;
assign unused_ok = rx_enable ^ tx_enable ^ q2_rxframe_lvds;
// synthesis translate_on

endmodule

`default_nettype wire
