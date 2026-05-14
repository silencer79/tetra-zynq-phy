// =============================================================================
// tetra_ul_nub_capture.v — UL TCH/S Normal-Uplink-Burst Capture + Demod
// =============================================================================
//
// Purpose:
//   After tetra_ul_sync_detect_os4 (instanced with NTS1 pattern) fires
//   sync_found_sys on NTS1[10] (= burst symbol 132), this module
//   captures + π/4-DQPSK demods BKN1 (108 sym) and BKN2 (108 sym) from a
//   ring buffer, outputs 432 type-5 bits (BKN1 MSB-first || BKN2 MSB-first)
//   as a parallel register, and pulses coded_valid_sys when done.
//
// NUB layout (ETSI EN 300 392-2 §9.4.4.3.4, 255 sym = 14.06 ms @ 18 kHz):
//   sym  0..5    TAIL1            6 sym
//   sym  6       HA1              1 sym (phase-adj)
//   sym  7..114  BKN1           108 sym → 216 type-5 bits
//   sym  115..121 BB1            7 sym
//   sym  122..132 NTS1          11 sym  ← sync anchor at sym 132
//   sym  133..140 BB2            8 sym
//   sym  141..248 BKN2         108 sym → 216 type-5 bits
//   sym  249     HA2              1 sym
//   sym  250..254 TAIL2          5 sym
//
// Relative to anchor (sym 132):
//   BKN1 diff-ref (HA1 = sym 6)    : anchor − 126 sym = −504 samples
//   BKN1[0]       (sym 7)          : anchor − 125 sym = −500 samples
//   BKN1[107]     (sym 114)        : anchor −  18 sym = − 72 samples
//   BKN2 diff-ref (BB2[7] = 140)   : anchor +   8 sym = + 32 samples
//   BKN2[0]       (sym 141)        : anchor +   9 sym = + 36 samples
//   BKN2[107]     (sym 248)        : anchor + 116 sym = +464 samples
//
// Ring depth = 1024 (10-bit address) → 1024 samples backlog.  At sync_found
// the BKN1 diff-ref is 504 samples behind wp; we wait POST_WAIT_SMP=480
// samples for BKN2[107] to be written (wp advances 480 → BKN1 diff-ref at
// wp − 984, still inside 1024 ring with 40-slot margin).
//
// Phase alignment: same scheme as tetra_ul_burst_capture — best_phase_sys
// + local phase_cnt_sys give delta_w = (phase_cnt − 1 − best_phase) mod 4.
// anchor_idx = wp_sys − 1 − delta_w.
//
// Differential demod (matches tetra_pi4dqpsk_demod / ul_sync_detect_os4):
//   z = current × conj(prev)
//   dibit[1] = sign(Im(z)) = sign(Q_cur·I_prev − I_cur·Q_prev)
//   dibit[0] = sign(Re(z)) = sign(I_cur·I_prev + Q_cur·Q_prev)
//
// Output format:
//   coded_bits_sys[431:216] = BKN1, MSB = first transmitted dibit
//   coded_bits_sys[215:0]   = BKN2, MSB = first transmitted dibit
//   coded_valid_sys = 1-cycle pulse on completion
//
// Resource estimate (Zynq-7020):
//   LUT ≈ 250  FF ≈ 500  BRAM = 2 (one per I/Q)  DSP = 4 (diff product)
//
// =============================================================================

`default_nettype none

module tetra_ul_nub_capture #(
    parameter IQ_WIDTH        = 16,
    parameter RING_DEPTH      = 1024,
    parameter RING_ADDR_W     = 10,
    parameter SPS             = 4,
    parameter BKN_SYMS        = 108,
    parameter BKN1_PRE_SMP    = 504,   // anchor − HA1 sample (BKN1 diff-ref)
    parameter BKN2_OFFSET_SMP = 32,    // anchor + BB2[7] sample (BKN2 diff-ref)
    parameter POST_WAIT_SMP   = 480    // wait until BKN2[107] is in ring
)(
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,
    // Post-RRC IQ @ 4 sps (shared with tetra_ul_sync_detect_os4 NUB instance)
    input  wire signed [IQ_WIDTH-1:0] i_in_sys,
    input  wire signed [IQ_WIDTH-1:0] q_in_sys,
    input  wire                       valid_in_sys,
    // Sync pulse from NUB-configured sync detector
    input  wire                       sync_found_sys,
    input  wire [1:0]                 best_phase_sys,
    // Output — 432 type-5 bits + valid pulse
    output reg  [431:0]               coded_bits_sys,
    output reg                        coded_valid_sys,
    // Debug / AXI visibility
    output reg  [15:0]                bursts_captured_sys
);

// -------------------------------------------------------------------------
// Ring buffer (BRAM-inferred) — continuous IQ write at 72 kHz
// -------------------------------------------------------------------------
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_i_sys [0:RING_DEPTH-1];
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_q_sys [0:RING_DEPTH-1];

reg [RING_ADDR_W-1:0] wp_sys;
reg [1:0]             phase_cnt_sys;

always @(posedge clk_sys) begin
    if (valid_in_sys) begin
        ring_i_sys[wp_sys] <= i_in_sys;
        ring_q_sys[wp_sys] <= q_in_sys;
    end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        wp_sys        <= {RING_ADDR_W{1'b0}};
        phase_cnt_sys <= 2'd0;
    end else if (valid_in_sys) begin
        wp_sys        <= wp_sys + 1'b1;
        phase_cnt_sys <= phase_cnt_sys + 2'd1;
    end
end

// -------------------------------------------------------------------------
// FSM
// -------------------------------------------------------------------------
localparam S_IDLE          = 4'd0;
localparam S_WAIT_POST     = 4'd1;
localparam S_READ_BKN1_PRE = 4'd2;  // issue read for BKN1[0], wait for ref BRAM
localparam S_READ_BKN1_REF = 4'd3;  // rd_iq = HA1 ref; latch prev; read BKN1[1]
localparam S_READ_BKN1_RUN = 4'd4;  // demod loop
localparam S_READ_BKN2_PRE = 4'd5;
localparam S_READ_BKN2_REF = 4'd6;
localparam S_READ_BKN2_RUN = 4'd7;
localparam S_DONE          = 4'd8;

reg [3:0]              state_sys;
reg [RING_ADDR_W-1:0]  anchor_idx_sys;
reg [RING_ADDR_W-1:0]  bkn1_base_sys;
reg [RING_ADDR_W-1:0]  bkn2_base_sys;
reg [8:0]              post_cnt_sys;
reg [6:0]              sym_idx_sys;        // 0..BKN_SYMS

// Previous-symbol IQ for differential demod
reg signed [IQ_WIDTH-1:0] prev_i_sys, prev_q_sys;

// (phase_cnt − 1 − best_phase) mod 4
wire [1:0] delta_w = phase_cnt_sys + 2'd3 - best_phase_sys;

// Anchor = ring index of NTS1[10] (last NTS1 dibit) at winning phase
// sync_found is registered 1 cycle after the trigger → wp_sys has advanced 1
wire [RING_ADDR_W-1:0] delta_ext_w   = {{(RING_ADDR_W-2){1'b0}}, delta_w};
wire [RING_ADDR_W-1:0] anchor_calc_w = wp_sys
                                       - delta_ext_w
                                       - {{(RING_ADDR_W-1){1'b0}}, 1'b1};

// Read-issue: drive BRAM addr
reg                       rd_en_sys;
reg [RING_ADDR_W-1:0]     rd_addr_sys;

// BRAM read output (1-cycle latency)
reg signed [IQ_WIDTH-1:0] rd_i_sys, rd_q_sys;

always @(posedge clk_sys) begin
    if (rd_en_sys) begin
        rd_i_sys <= ring_i_sys[rd_addr_sys];
        rd_q_sys <= ring_q_sys[rd_addr_sys];
    end
end

// -------------------------------------------------------------------------
// Differential product z = current × conj(prev)
//   I_z = I_c·I_p + Q_c·Q_p
//   Q_z = Q_c·I_p − I_c·Q_p
// 4 signed multiplications (DSP48-inferred)
// -------------------------------------------------------------------------
wire signed [2*IQ_WIDTH-1:0] mul_ii_w = rd_i_sys * prev_i_sys;
wire signed [2*IQ_WIDTH-1:0] mul_qq_w = rd_q_sys * prev_q_sys;
wire signed [2*IQ_WIDTH-1:0] mul_qi_w = rd_q_sys * prev_i_sys;
wire signed [2*IQ_WIDTH-1:0] mul_iq_w = rd_i_sys * prev_q_sys;

wire signed [2*IQ_WIDTH:0] i_prod_w = mul_ii_w + mul_qq_w;
wire signed [2*IQ_WIDTH:0] q_prod_w = mul_qi_w - mul_iq_w;

wire [1:0] dibit_w = {q_prod_w[2*IQ_WIDTH], i_prod_w[2*IQ_WIDTH]};

// -------------------------------------------------------------------------
// FSM logic
// -------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        state_sys           <= S_IDLE;
        anchor_idx_sys      <= {RING_ADDR_W{1'b0}};
        bkn1_base_sys       <= {RING_ADDR_W{1'b0}};
        bkn2_base_sys       <= {RING_ADDR_W{1'b0}};
        post_cnt_sys        <= 9'd0;
        sym_idx_sys         <= 7'd0;
        prev_i_sys          <= {IQ_WIDTH{1'b0}};
        prev_q_sys          <= {IQ_WIDTH{1'b0}};
        rd_en_sys           <= 1'b0;
        rd_addr_sys         <= {RING_ADDR_W{1'b0}};
        coded_bits_sys      <= 432'd0;
        coded_valid_sys     <= 1'b0;
        bursts_captured_sys <= 16'd0;
    end else begin
        // Defaults
        rd_en_sys       <= 1'b0;
        coded_valid_sys <= 1'b0;

        case (state_sys)
        // ----------------------------------------------------------------
        S_IDLE: begin
            if (sync_found_sys) begin
                anchor_idx_sys <= anchor_calc_w;
                bkn1_base_sys  <= anchor_calc_w
                                  - BKN1_PRE_SMP[RING_ADDR_W-1:0];
                bkn2_base_sys  <= anchor_calc_w
                                  + BKN2_OFFSET_SMP[RING_ADDR_W-1:0];
                post_cnt_sys   <= POST_WAIT_SMP[8:0];
                state_sys      <= S_WAIT_POST;
            end
        end

        // ----------------------------------------------------------------
        S_WAIT_POST: begin
            if (valid_in_sys) begin
                if (post_cnt_sys <= 9'd1) begin
                    // Issue read for diff-ref sample (HA1).  BRAM has 1-
                    // cycle latency, so data arrives next cycle.
                    rd_en_sys   <= 1'b1;
                    rd_addr_sys <= bkn1_base_sys;
                    sym_idx_sys <= 7'd0;
                    state_sys   <= S_READ_BKN1_PRE;
                end else begin
                    post_cnt_sys <= post_cnt_sys - 1'b1;
                end
            end
        end

        // ----------------------------------------------------------------
        // S_READ_BKN1_PRE: BRAM read for HA1 in-flight; issue read for
        //   BKN1[0].  Do NOT latch prev_iq yet — rd_iq still holds stale
        //   data from before the burst.
        // ----------------------------------------------------------------
        S_READ_BKN1_PRE: begin
            rd_en_sys   <= 1'b1;
            rd_addr_sys <= bkn1_base_sys + SPS[RING_ADDR_W-1:0];
            state_sys   <= S_READ_BKN1_REF;
        end

        // ----------------------------------------------------------------
        // S_READ_BKN1_REF: rd_iq now = HA1 (BKN1 diff-ref).  Latch prev
        //   for use as differential reference of BKN1[0].  Issue read for
        //   BKN1[1] (we already issued read for BKN1[0] last cycle).
        // ----------------------------------------------------------------
        S_READ_BKN1_REF: begin
            prev_i_sys  <= rd_i_sys;
            prev_q_sys  <= rd_q_sys;
            rd_en_sys   <= 1'b1;
            rd_addr_sys <= bkn1_base_sys
                           + ({{(RING_ADDR_W-2){1'b0}}, 2'd2})
                           * SPS[RING_ADDR_W-1:0];
            sym_idx_sys <= 7'd0;
            state_sys   <= S_READ_BKN1_RUN;
        end

        // ----------------------------------------------------------------
        // S_READ_BKN1_RUN: rd_iq = BKN1[sym_idx].  Demod (= rd_iq × conj(prev_iq))
        //   shift dibit into coded_bits[431:216].  Latch prev for next.
        //   Issue read for BKN1[sym_idx+2] (we already have +1 in flight).
        // ----------------------------------------------------------------
        S_READ_BKN1_RUN: begin
            coded_bits_sys[431:216] <=
                {coded_bits_sys[429:216], dibit_w};
            prev_i_sys <= rd_i_sys;
            prev_q_sys <= rd_q_sys;
            if (sym_idx_sys == BKN_SYMS[6:0] - 7'd1) begin
                // Just decoded BKN1[107].  Switch to BKN2.
                // Issue read for BKN2 diff-ref (BB2[7])
                rd_en_sys   <= 1'b1;
                rd_addr_sys <= bkn2_base_sys;
                sym_idx_sys <= 7'd0;
                state_sys   <= S_READ_BKN2_PRE;
            end else begin
                // Issue read for BKN1[sym_idx+2]
                rd_en_sys   <= 1'b1;
                rd_addr_sys <= bkn1_base_sys
                               + ({{(RING_ADDR_W-7){1'b0}}, sym_idx_sys + 7'd3})
                               * SPS[RING_ADDR_W-1:0];
                sym_idx_sys <= sym_idx_sys + 7'd1;
            end
        end

        // ----------------------------------------------------------------
        // BKN2 demod — analog 3-state version
        // ----------------------------------------------------------------
        S_READ_BKN2_PRE: begin
            rd_en_sys   <= 1'b1;
            rd_addr_sys <= bkn2_base_sys + SPS[RING_ADDR_W-1:0];
            state_sys   <= S_READ_BKN2_REF;
        end

        S_READ_BKN2_REF: begin
            prev_i_sys  <= rd_i_sys;
            prev_q_sys  <= rd_q_sys;
            rd_en_sys   <= 1'b1;
            rd_addr_sys <= bkn2_base_sys
                           + ({{(RING_ADDR_W-2){1'b0}}, 2'd2})
                           * SPS[RING_ADDR_W-1:0];
            sym_idx_sys <= 7'd0;
            state_sys   <= S_READ_BKN2_RUN;
        end

        S_READ_BKN2_RUN: begin
            coded_bits_sys[215:0] <=
                {coded_bits_sys[213:0], dibit_w};
            prev_i_sys <= rd_i_sys;
            prev_q_sys <= rd_q_sys;
            if (sym_idx_sys == BKN_SYMS[6:0] - 7'd1) begin
                state_sys <= S_DONE;
            end else begin
                rd_en_sys   <= 1'b1;
                rd_addr_sys <= bkn2_base_sys
                               + ({{(RING_ADDR_W-7){1'b0}}, sym_idx_sys + 7'd3})
                               * SPS[RING_ADDR_W-1:0];
                sym_idx_sys <= sym_idx_sys + 7'd1;
            end
        end

        // ----------------------------------------------------------------
        S_DONE: begin
            coded_valid_sys     <= 1'b1;
            bursts_captured_sys <= bursts_captured_sys + 16'd1;
            state_sys           <= S_IDLE;
        end

        default: state_sys <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
