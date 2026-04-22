// =============================================================================
// tetra_ul_sync_detect_os4.v — Oversampled UL-Burst Sync Detector (M=4 phases)
// =============================================================================
//
// Purpose:
//   Detect TETRA uplink Random-Access / Control-Uplink bursts via the ETSI
//   x-sequence (§9.4.4.3.3, 15 symbols / 30 bits).  The signal source is the
//   post-RRC IQ stream at 72 kHz (= 4 samples/symbol).  Because isolated UL
//   bursts are only 127 symbols long (~7 ms), the Gardner TED in the main RX
//   chain does not converge before the burst ends, so its 18 kHz dibit output
//   has arbitrary symbol timing with systematic bit errors.
//
//   This block bypasses Gardner entirely: it runs FOUR independent differential
//   demodulators and sliding correlators in parallel, one per possible symbol
//   phase (k ∈ {0,1,2,3} at 4 sps).  The correct phase wins on real x-seq
//   matches; phases that sample mid-eye degrade gracefully.
//
// Algorithm per phase k:
//   1. Hold IQ history: i_hist[k], q_hist[k] = IQ sample one symbol ago
//      (written every 4th valid sample — the one tagged with phase k).
//   2. On each valid with phase==k:
//        z = current × conj(prev_k)
//        dibit[1] = sign(Im(z)) = sign(Q_cur*I_prev - I_cur*Q_prev)
//        dibit[0] = sign(Re(z)) = sign(I_cur*I_prev + Q_cur*Q_prev)
//      (matches tetra_pi4dqpsk_demod quadrant→dibit table.)
//   3. Shift dibit into 30-bit flat register (newest at [1:0]).
//   4. Compare window against ETS_REF, count matches → corr_k.
//
// Output:
//   corr_peak_ul = max(corr_0..corr_3) over all four phase registers.
//   sync_found_ul pulses on any phase crossing corr_threshold (holdoff
//   suppresses re-fire within the same burst).
//
// Resource estimate (Zynq-7020):
//   LUT ≈ 300  FF ≈ 310  DSP48 = 4  BRAM = 0
//
// =============================================================================

`default_nettype none

module tetra_ul_sync_detect_os4 #(
    parameter IQ_WIDTH    = 16,
    parameter CORR_WIDTH  = 6,
    parameter HOLDOFF     = 50   // symbols to suppress re-fire after sync_fire
)(
    input  wire                         clk_sys,
    input  wire                         rst_n_sys,
    input  wire                         reset_peak_sys,   // clear corr_peak on AXI RST_CNTRS
    // Post-RRC IQ from rx_frontend (72 kHz = 4 sps)
    input  wire signed [IQ_WIDTH-1:0]   i_in_sys,
    input  wire signed [IQ_WIDTH-1:0]   q_in_sys,
    input  wire                         valid_in_sys,
    // Configuration
    input  wire [CORR_WIDTH-1:0]        corr_threshold_sys,
    // Outputs
    output reg                          sync_found_sys,
    output reg  [CORR_WIDTH-1:0]        corr_peak_sys,
    output reg  [1:0]                   best_phase_sys
);

// ---------------------------------------------------------------------------
// ETS reference — §9.4.4.3.3 x-sequence, MSB=first TX (oldest in sreg)
// Identical to tetra_sync_detect.v
// ---------------------------------------------------------------------------
localparam [29:0] ETS_REF = {
    2'b10,
    2'b01, 2'b11, 2'b01, 2'b00, 2'b00,
    2'b11, 2'b10, 2'b10, 2'b01, 2'b11,
    2'b01, 2'b00, 2'b00, 2'b11
};

// ---------------------------------------------------------------------------
// Phase counter — increments on each valid_in_sys (72 kHz → wraps at 4)
// ---------------------------------------------------------------------------
reg [1:0] phase_cnt_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        phase_cnt_sys <= 2'd0;
    else if (valid_in_sys)
        phase_cnt_sys <= phase_cnt_sys + 2'd1;
end

// ---------------------------------------------------------------------------
// IQ history — one register pair per phase (updated when its phase ticks)
// Holds the sample "one symbol ago" for the differential product.
// ---------------------------------------------------------------------------
reg signed [IQ_WIDTH-1:0] i_hist0_sys, i_hist1_sys, i_hist2_sys, i_hist3_sys;
reg signed [IQ_WIDTH-1:0] q_hist0_sys, q_hist1_sys, q_hist2_sys, q_hist3_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        i_hist0_sys <= {IQ_WIDTH{1'b0}}; q_hist0_sys <= {IQ_WIDTH{1'b0}};
        i_hist1_sys <= {IQ_WIDTH{1'b0}}; q_hist1_sys <= {IQ_WIDTH{1'b0}};
        i_hist2_sys <= {IQ_WIDTH{1'b0}}; q_hist2_sys <= {IQ_WIDTH{1'b0}};
        i_hist3_sys <= {IQ_WIDTH{1'b0}}; q_hist3_sys <= {IQ_WIDTH{1'b0}};
    end else if (valid_in_sys) begin
        case (phase_cnt_sys)
            2'd0: begin i_hist0_sys <= i_in_sys; q_hist0_sys <= q_in_sys; end
            2'd1: begin i_hist1_sys <= i_in_sys; q_hist1_sys <= q_in_sys; end
            2'd2: begin i_hist2_sys <= i_in_sys; q_hist2_sys <= q_in_sys; end
            2'd3: begin i_hist3_sys <= i_in_sys; q_hist3_sys <= q_in_sys; end
        endcase
    end
end

// Select previous-sample register for the phase being processed this cycle
reg signed [IQ_WIDTH-1:0] i_prev_sel_sys;
reg signed [IQ_WIDTH-1:0] q_prev_sel_sys;
always @(*) begin
    case (phase_cnt_sys)
        2'd0: begin i_prev_sel_sys = i_hist0_sys; q_prev_sel_sys = q_hist0_sys; end
        2'd1: begin i_prev_sel_sys = i_hist1_sys; q_prev_sel_sys = q_hist1_sys; end
        2'd2: begin i_prev_sel_sys = i_hist2_sys; q_prev_sel_sys = q_hist2_sys; end
        2'd3: begin i_prev_sel_sys = i_hist3_sys; q_prev_sel_sys = q_hist3_sys; end
    endcase
end

// ---------------------------------------------------------------------------
// Differential product z = current × conj(prev)
//   I_z = I_c*I_p + Q_c*Q_p
//   Q_z = Q_c*I_p - I_c*Q_p
// 4 signed multiplications (inferred to DSP48 blocks)
// ---------------------------------------------------------------------------
wire signed [2*IQ_WIDTH-1:0] mul_ii_sys = i_in_sys * i_prev_sel_sys;
wire signed [2*IQ_WIDTH-1:0] mul_qq_sys = q_in_sys * q_prev_sel_sys;
wire signed [2*IQ_WIDTH-1:0] mul_qi_sys = q_in_sys * i_prev_sel_sys;
wire signed [2*IQ_WIDTH-1:0] mul_iq_sys = i_in_sys * q_prev_sel_sys;

wire signed [2*IQ_WIDTH:0] i_prod_sys = mul_ii_sys + mul_qq_sys;
wire signed [2*IQ_WIDTH:0] q_prod_sys = mul_qi_sys - mul_iq_sys;

// Dibit from product signs (matches tetra_pi4dqpsk_demod quadrant table):
//   (+,+)=00  (-,+)=01  (+,-)=10  (-,-)=11
//   → dibit[1] = sign_Q, dibit[0] = sign_I
wire [1:0] dibit_sys = {q_prod_sys[2*IQ_WIDTH], i_prod_sys[2*IQ_WIDTH]};

// ---------------------------------------------------------------------------
// Four phase-indexed 30-bit shift registers (newest dibit at [1:0])
// Each gets shifted only when its phase is current.
// ---------------------------------------------------------------------------
reg [29:0] sreg0_sys, sreg1_sys, sreg2_sys, sreg3_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sreg0_sys <= 30'd0; sreg1_sys <= 30'd0;
        sreg2_sys <= 30'd0; sreg3_sys <= 30'd0;
    end else if (valid_in_sys) begin
        case (phase_cnt_sys)
            2'd0: sreg0_sys <= {sreg0_sys[27:0], dibit_sys};
            2'd1: sreg1_sys <= {sreg1_sys[27:0], dibit_sys};
            2'd2: sreg2_sys <= {sreg2_sys[27:0], dibit_sys};
            2'd3: sreg3_sys <= {sreg3_sys[27:0], dibit_sys};
        endcase
    end
end

// ---------------------------------------------------------------------------
// Per-phase correlators — count matching dibits vs ETS_REF
// Combinatorial: 15-term adder tree per phase.
// ---------------------------------------------------------------------------
function [3:0] corr_count;
    input [29:0] sreg;
    reg [29:0] xr;
    reg [14:0] m;
    begin
        xr = sreg ^ ETS_REF;
        m[ 0] = ~|xr[ 1: 0]; m[ 1] = ~|xr[ 3: 2]; m[ 2] = ~|xr[ 5: 4];
        m[ 3] = ~|xr[ 7: 6]; m[ 4] = ~|xr[ 9: 8]; m[ 5] = ~|xr[11:10];
        m[ 6] = ~|xr[13:12]; m[ 7] = ~|xr[15:14]; m[ 8] = ~|xr[17:16];
        m[ 9] = ~|xr[19:18]; m[10] = ~|xr[21:20]; m[11] = ~|xr[23:22];
        m[12] = ~|xr[25:24]; m[13] = ~|xr[27:26]; m[14] = ~|xr[29:28];
        corr_count = ({3'd0,m[ 0]}+{3'd0,m[ 1]}+{3'd0,m[ 2]}+{3'd0,m[ 3]}+
                      {3'd0,m[ 4]}+{3'd0,m[ 5]}+{3'd0,m[ 6]}+{3'd0,m[ 7]}+
                      {3'd0,m[ 8]}+{3'd0,m[ 9]}+{3'd0,m[10]}+{3'd0,m[11]}+
                      {3'd0,m[12]}+{3'd0,m[13]}+{3'd0,m[14]});
    end
endfunction

wire [3:0] corr0_sys = corr_count(sreg0_sys);
wire [3:0] corr1_sys = corr_count(sreg1_sys);
wire [3:0] corr2_sys = corr_count(sreg2_sys);
wire [3:0] corr3_sys = corr_count(sreg3_sys);

// ---------------------------------------------------------------------------
// Max-reduction over 4 phases + phase index
// ---------------------------------------------------------------------------
wire [3:0] corr_01_sys = (corr0_sys >= corr1_sys) ? corr0_sys : corr1_sys;
wire [3:0] corr_23_sys = (corr2_sys >= corr3_sys) ? corr2_sys : corr3_sys;
wire [3:0] corr_max_sys = (corr_01_sys >= corr_23_sys) ? corr_01_sys : corr_23_sys;

wire [1:0] best_phase_w =
    (corr0_sys >= corr1_sys && corr0_sys >= corr2_sys && corr0_sys >= corr3_sys) ? 2'd0 :
    (corr1_sys >= corr2_sys && corr1_sys >= corr3_sys)                           ? 2'd1 :
    (corr2_sys >= corr3_sys)                                                     ? 2'd2 : 2'd3;

// ---------------------------------------------------------------------------
// Threshold + holdoff (runs on valid_in_sys only — "symbol rate" is 18 kHz,
// but we gate on any 72 kHz valid; HOLDOFF counts valid samples).
// ---------------------------------------------------------------------------
reg [7:0] holdoff_cnt_sys;
wire      holdoff_active_sys = (holdoff_cnt_sys != 8'd0);

wire zero_ext_thresh_sys = |corr_threshold_sys[CORR_WIDTH-1:4];  // threshold > 15 → impossible
wire thresh_hit_sys = !zero_ext_thresh_sys &&
                      (corr_max_sys >= corr_threshold_sys[3:0]);

wire sync_fire_sys = valid_in_sys & thresh_hit_sys & ~holdoff_active_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        holdoff_cnt_sys <= 8'd0;
    else if (sync_fire_sys)
        holdoff_cnt_sys <= HOLDOFF[7:0];
    else if (valid_in_sys && holdoff_active_sys)
        holdoff_cnt_sys <= holdoff_cnt_sys - 8'd1;
end

// Register outputs (1-cycle delay)
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sync_found_sys <= 1'b0;
        best_phase_sys <= 2'd0;
    end else begin
        sync_found_sys <= sync_fire_sys;
        if (sync_fire_sys)
            best_phase_sys <= best_phase_w;
    end
end

// corr_peak — max since reset_peak_sys
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        corr_peak_sys <= {CORR_WIDTH{1'b0}};
    else if (reset_peak_sys)
        corr_peak_sys <= {CORR_WIDTH{1'b0}};
    else if (valid_in_sys &&
             {{(CORR_WIDTH-4){1'b0}}, corr_max_sys} > corr_peak_sys)
        corr_peak_sys <= {{(CORR_WIDTH-4){1'b0}}, corr_max_sys};
end

endmodule

`default_nettype wire
