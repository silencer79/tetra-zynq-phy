// =============================================================================
// tetra_sync_detect.v — TETRA Sliding Correlator / Synchronisation Detector
// =============================================================================
//
// Description:
//   Sliding correlator for TETRA training sequence detection (EN 300 392-2
//   §9.4.4).  Receives the demodulated dibit stream from tetra_pi4dqpsk_demod
//   and asserts sync_found when a training sequence is detected above the
//   configurable correlation threshold.
//
//   Three training sequences are supported (seq_select):
//     0 — Normal Training Sequence   (NTS, 22 symbols, Table 9.11)
//     1 — Extended Training Sequence (ETS, 30 symbols, Table 9.12)
//     2 — Synchronisation TS         (STS, 38 symbols, Table 9.14)
//
// Algorithm:
//   1. Incoming dibits fill a 38-symbol (76-bit) flat shift register.
//   2. On each dibit_valid pulse: correlate shift register tail against
//      the selected reference sequence (count of matching dibits).
//   3. Internal wire sync_fire_sample = (corr >= threshold) & !holdoff & dibit_valid.
//   4. sync_found output is sync_fire_sample registered by 1 cycle.
//   5. After sync_fire: start a holdoff counter (HOLDOFF symbols) to suppress
//      re-triggers within the same burst.
//   6. Lock detection: sync_locked asserts after LOCK_COUNT (4) consecutive
//      sync_fire pulses with spacing in [SLOT_SYMS-TOL, SLOT_SYMS+TOL].
//      sync_locked de-asserts if no sync_fire arrives within LOCK_TIMEOUT.
//
// Key pipeline note:
//   sync_fire_sample is combinatorial and used internally for control.
//   sync_found is registered (1-cycle delayed) for the output port.
//   All control registers (holdoff, spacing, consec, FSM) use sync_fire_sample
//   to avoid a 1-cycle skew.
//
// Training Sequence Reference Values:
//   IMPORTANT — Dibit values in NTS_REF / ETS_REF / STS_REF must be
//   verified against ETSI EN 300 392-2 Tables 9.11, 9.12, 9.14.
//   Current values are design-intent placeholders; correct before hardware use.
//
// Clock domain:
//   clk_sample = 100 MHz system clock (same physical clock as clk_sys).
//   dibit_valid is a one-cycle strobe at 18 kHz symbol rate.
//   All internal signals carry the _sample suffix.
//
// Shift register convention:
//   sreg_sample[1:0]   = most recently received dibit (newest)
//   sreg_sample[75:74] = oldest dibit in window
//   Reference constants use the same newest-first ordering.
//
// Pipeline / Latency:
//   sync_found fires 1 cycle after the dibit_valid that completes the TS window.
//
// Resource estimate (rough):
//   LUT: ~380  FF: ~130  DSP48: 0  BRAM: 0
//
// Ports:
//   clk_sample        100 MHz clock (label matches downstream chain)
//   rst_n_sample      Active-low async reset
//   dibit_in          2-bit symbol from pi4dqpsk_demod
//   dibit_valid       One-cycle strobe per symbol (18 kHz)
//   corr_threshold    Match count threshold (AXI-Lite configurable)
//   seq_select        0=NTS, 1=ETS, 2=STS
//   sync_found        One-cycle pulse when correlation peak detected (registered)
//   sync_locked       High when timing lock acquired
//   slot_position     Symbol offset within current timeslot (0..254)
//   slot_number       Current timeslot index (0..3)
//
// =============================================================================

`default_nettype none

module tetra_sync_detect #(
    parameter CORR_WIDTH   = 6,     // Enough for 0..38
    parameter SEQ_LEN_MAX  = 38,    // Longest TS (STS)
    parameter HOLDOFF      = 220,   // Symbols blocked after sync_fire
    parameter LOCK_COUNT   = 4,     // Consecutive hits needed for lock
    parameter SLOT_SYMS    = 255,   // Symbols per TDMA timeslot
    parameter LOCK_TOL     = 8,     // ±symbols tolerance for lock spacing
    parameter LOCK_TIMEOUT = 512    // Symbols without sync_fire → unlock (~2 slots)
)(
    input  wire                      clk_sample,
    input  wire                      rst_n_sample,
    // Demodulated symbol stream
    input  wire [1:0]                dibit_in,
    input  wire                      dibit_valid,
    // AXI-Lite configuration
    input  wire [CORR_WIDTH-1:0]     corr_threshold,
    input  wire [1:0]                seq_select,
    // Outputs
    output reg                       sync_found,
    output reg                       sync_locked,
    output reg [7:0]                 slot_position,
    output reg [1:0]                 slot_number
);

// ---------------------------------------------------------------------------
// Training Sequence Reference Constants
// ETSI EN 300 392-2 — VERIFY AGAINST TABLES 9.11 / 9.12 / 9.14
//
// Bit ordering (newest-first, matching shift register):
//   bits [1:0]           = last  symbol of sequence (most recently received)
//   bits [2*N-1:2*N-2]   = first symbol of sequence (received N-1 clocks ago)
// ---------------------------------------------------------------------------

// NTS — 22 symbols (44 bits), Table 9.11
localparam [43:0] NTS_REF = {
    2'b00, 2'b11,              // symbols 21..20 (oldest)
    2'b01, 2'b10, 2'b01, 2'b11, 2'b10, 2'b10,
    2'b00, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01,
    2'b10, 2'b00, 2'b11, 2'b01, 2'b00, 2'b00,
    2'b11, 2'b01              // symbols 1..0 (newest)
};

// ETS — 30 symbols (60 bits), Table 9.12
localparam [59:0] ETS_REF = {
    2'b01, 2'b11,              // symbols 29..28 (oldest)
    2'b01, 2'b00, 2'b10, 2'b11, 2'b01, 2'b10,
    2'b00, 2'b11, 2'b01, 2'b00, 2'b01, 2'b11,
    2'b10, 2'b10, 2'b00, 2'b11, 2'b01, 2'b10,
    2'b10, 2'b00, 2'b11, 2'b01, 2'b00, 2'b00,
    2'b10, 2'b01, 2'b11, 2'b01  // symbols 5..0 (newest)
};

// STS — 38 symbols (76 bits), Table 9.14
localparam [75:0] STS_REF = {
    2'b01, 2'b11,              // symbols 37..36 (oldest)
    2'b10, 2'b10, 2'b00, 2'b11, 2'b01, 2'b00,
    2'b10, 2'b01, 2'b10, 2'b11, 2'b01, 2'b00,
    2'b10, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01,
    2'b10, 2'b11, 2'b00, 2'b10, 2'b01, 2'b11,
    2'b01, 2'b00, 2'b00, 2'b11, 2'b10, 2'b10,
    2'b01, 2'b11, 2'b01, 2'b00, 2'b10, 2'b11  // symbols 1..0 (newest)
};

// ---------------------------------------------------------------------------
// Stage 0 — Shift Register (flat 76 bits, no arrays per R3)
// Shifts left: newest dibit enters at [1:0], oldest exits at [75:74].
// ---------------------------------------------------------------------------

reg [75:0] sreg_sample;

// R1: one always block per register
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        sreg_sample <= 76'd0;
    else if (dibit_valid)
        sreg_sample <= {sreg_sample[73:0], dibit_in};
end

// ---------------------------------------------------------------------------
// Stage 1 — Per-Dibit Match Signals (combinatorial, unrolled)
// match_X[i] = 1 when symbol i in the window matches reference[i].
// i=0: newest (sreg[1:0]), i=N-1: oldest in window.
//
// sreg_shifted: combinatorial pre-shift — what sreg_sample would be
// AFTER this dibit_valid posedge.  Must be used for correlation so
// that sync_fire_sample is asserted on the dibit_valid that completes
// the TS window, not one symbol later.
// ---------------------------------------------------------------------------
wire [75:0] sreg_shifted = {sreg_sample[73:0], dibit_in};

// ---- NTS (22 symbols) ----
wire [43:0] xor_nts_sample = sreg_shifted[43:0] ^ NTS_REF;

wire [21:0] match_nts_sample;
assign match_nts_sample[ 0] = ~|xor_nts_sample[ 1: 0];
assign match_nts_sample[ 1] = ~|xor_nts_sample[ 3: 2];
assign match_nts_sample[ 2] = ~|xor_nts_sample[ 5: 4];
assign match_nts_sample[ 3] = ~|xor_nts_sample[ 7: 6];
assign match_nts_sample[ 4] = ~|xor_nts_sample[ 9: 8];
assign match_nts_sample[ 5] = ~|xor_nts_sample[11:10];
assign match_nts_sample[ 6] = ~|xor_nts_sample[13:12];
assign match_nts_sample[ 7] = ~|xor_nts_sample[15:14];
assign match_nts_sample[ 8] = ~|xor_nts_sample[17:16];
assign match_nts_sample[ 9] = ~|xor_nts_sample[19:18];
assign match_nts_sample[10] = ~|xor_nts_sample[21:20];
assign match_nts_sample[11] = ~|xor_nts_sample[23:22];
assign match_nts_sample[12] = ~|xor_nts_sample[25:24];
assign match_nts_sample[13] = ~|xor_nts_sample[27:26];
assign match_nts_sample[14] = ~|xor_nts_sample[29:28];
assign match_nts_sample[15] = ~|xor_nts_sample[31:30];
assign match_nts_sample[16] = ~|xor_nts_sample[33:32];
assign match_nts_sample[17] = ~|xor_nts_sample[35:34];
assign match_nts_sample[18] = ~|xor_nts_sample[37:36];
assign match_nts_sample[19] = ~|xor_nts_sample[39:38];
assign match_nts_sample[20] = ~|xor_nts_sample[41:40];
assign match_nts_sample[21] = ~|xor_nts_sample[43:42];

// ---- ETS (30 symbols) ----
wire [59:0] xor_ets_sample = sreg_shifted[59:0] ^ ETS_REF;

wire [29:0] match_ets_sample;
assign match_ets_sample[ 0] = ~|xor_ets_sample[ 1: 0];
assign match_ets_sample[ 1] = ~|xor_ets_sample[ 3: 2];
assign match_ets_sample[ 2] = ~|xor_ets_sample[ 5: 4];
assign match_ets_sample[ 3] = ~|xor_ets_sample[ 7: 6];
assign match_ets_sample[ 4] = ~|xor_ets_sample[ 9: 8];
assign match_ets_sample[ 5] = ~|xor_ets_sample[11:10];
assign match_ets_sample[ 6] = ~|xor_ets_sample[13:12];
assign match_ets_sample[ 7] = ~|xor_ets_sample[15:14];
assign match_ets_sample[ 8] = ~|xor_ets_sample[17:16];
assign match_ets_sample[ 9] = ~|xor_ets_sample[19:18];
assign match_ets_sample[10] = ~|xor_ets_sample[21:20];
assign match_ets_sample[11] = ~|xor_ets_sample[23:22];
assign match_ets_sample[12] = ~|xor_ets_sample[25:24];
assign match_ets_sample[13] = ~|xor_ets_sample[27:26];
assign match_ets_sample[14] = ~|xor_ets_sample[29:28];
assign match_ets_sample[15] = ~|xor_ets_sample[31:30];
assign match_ets_sample[16] = ~|xor_ets_sample[33:32];
assign match_ets_sample[17] = ~|xor_ets_sample[35:34];
assign match_ets_sample[18] = ~|xor_ets_sample[37:36];
assign match_ets_sample[19] = ~|xor_ets_sample[39:38];
assign match_ets_sample[20] = ~|xor_ets_sample[41:40];
assign match_ets_sample[21] = ~|xor_ets_sample[43:42];
assign match_ets_sample[22] = ~|xor_ets_sample[45:44];
assign match_ets_sample[23] = ~|xor_ets_sample[47:46];
assign match_ets_sample[24] = ~|xor_ets_sample[49:48];
assign match_ets_sample[25] = ~|xor_ets_sample[51:50];
assign match_ets_sample[26] = ~|xor_ets_sample[53:52];
assign match_ets_sample[27] = ~|xor_ets_sample[55:54];
assign match_ets_sample[28] = ~|xor_ets_sample[57:56];
assign match_ets_sample[29] = ~|xor_ets_sample[59:58];

// ---- STS (38 symbols) ----
wire [75:0] xor_sts_sample = sreg_shifted ^ STS_REF;

wire [37:0] match_sts_sample;
assign match_sts_sample[ 0] = ~|xor_sts_sample[ 1: 0];
assign match_sts_sample[ 1] = ~|xor_sts_sample[ 3: 2];
assign match_sts_sample[ 2] = ~|xor_sts_sample[ 5: 4];
assign match_sts_sample[ 3] = ~|xor_sts_sample[ 7: 6];
assign match_sts_sample[ 4] = ~|xor_sts_sample[ 9: 8];
assign match_sts_sample[ 5] = ~|xor_sts_sample[11:10];
assign match_sts_sample[ 6] = ~|xor_sts_sample[13:12];
assign match_sts_sample[ 7] = ~|xor_sts_sample[15:14];
assign match_sts_sample[ 8] = ~|xor_sts_sample[17:16];
assign match_sts_sample[ 9] = ~|xor_sts_sample[19:18];
assign match_sts_sample[10] = ~|xor_sts_sample[21:20];
assign match_sts_sample[11] = ~|xor_sts_sample[23:22];
assign match_sts_sample[12] = ~|xor_sts_sample[25:24];
assign match_sts_sample[13] = ~|xor_sts_sample[27:26];
assign match_sts_sample[14] = ~|xor_sts_sample[29:28];
assign match_sts_sample[15] = ~|xor_sts_sample[31:30];
assign match_sts_sample[16] = ~|xor_sts_sample[33:32];
assign match_sts_sample[17] = ~|xor_sts_sample[35:34];
assign match_sts_sample[18] = ~|xor_sts_sample[37:36];
assign match_sts_sample[19] = ~|xor_sts_sample[39:38];
assign match_sts_sample[20] = ~|xor_sts_sample[41:40];
assign match_sts_sample[21] = ~|xor_sts_sample[43:42];
assign match_sts_sample[22] = ~|xor_sts_sample[45:44];
assign match_sts_sample[23] = ~|xor_sts_sample[47:46];
assign match_sts_sample[24] = ~|xor_sts_sample[49:48];
assign match_sts_sample[25] = ~|xor_sts_sample[51:50];
assign match_sts_sample[26] = ~|xor_sts_sample[53:52];
assign match_sts_sample[27] = ~|xor_sts_sample[55:54];
assign match_sts_sample[28] = ~|xor_sts_sample[57:56];
assign match_sts_sample[29] = ~|xor_sts_sample[59:58];
assign match_sts_sample[30] = ~|xor_sts_sample[61:60];
assign match_sts_sample[31] = ~|xor_sts_sample[63:62];
assign match_sts_sample[32] = ~|xor_sts_sample[65:64];
assign match_sts_sample[33] = ~|xor_sts_sample[67:66];
assign match_sts_sample[34] = ~|xor_sts_sample[69:68];
assign match_sts_sample[35] = ~|xor_sts_sample[71:70];
assign match_sts_sample[36] = ~|xor_sts_sample[73:72];
assign match_sts_sample[37] = ~|xor_sts_sample[75:74];

// ---------------------------------------------------------------------------
// Stage 2 — Correlation Adder Trees (combinatorial, unrolled)
// ---------------------------------------------------------------------------

wire [5:0] corr_nts_sample;
assign corr_nts_sample =
    ({5'd0,match_nts_sample[0]}+{5'd0,match_nts_sample[1]}+
     {5'd0,match_nts_sample[2]}+{5'd0,match_nts_sample[3]}+
     {5'd0,match_nts_sample[4]}+{5'd0,match_nts_sample[5]}+
     {5'd0,match_nts_sample[6]}+{5'd0,match_nts_sample[7]}+
     {5'd0,match_nts_sample[8]}+{5'd0,match_nts_sample[9]}+
     {5'd0,match_nts_sample[10]}+{5'd0,match_nts_sample[11]}+
     {5'd0,match_nts_sample[12]}+{5'd0,match_nts_sample[13]}+
     {5'd0,match_nts_sample[14]}+{5'd0,match_nts_sample[15]}+
     {5'd0,match_nts_sample[16]}+{5'd0,match_nts_sample[17]}+
     {5'd0,match_nts_sample[18]}+{5'd0,match_nts_sample[19]}+
     {5'd0,match_nts_sample[20]}+{5'd0,match_nts_sample[21]});

wire [5:0] corr_ets_sample;
assign corr_ets_sample =
    ({5'd0,match_ets_sample[0]}+{5'd0,match_ets_sample[1]}+
     {5'd0,match_ets_sample[2]}+{5'd0,match_ets_sample[3]}+
     {5'd0,match_ets_sample[4]}+{5'd0,match_ets_sample[5]}+
     {5'd0,match_ets_sample[6]}+{5'd0,match_ets_sample[7]}+
     {5'd0,match_ets_sample[8]}+{5'd0,match_ets_sample[9]}+
     {5'd0,match_ets_sample[10]}+{5'd0,match_ets_sample[11]}+
     {5'd0,match_ets_sample[12]}+{5'd0,match_ets_sample[13]}+
     {5'd0,match_ets_sample[14]}+{5'd0,match_ets_sample[15]}+
     {5'd0,match_ets_sample[16]}+{5'd0,match_ets_sample[17]}+
     {5'd0,match_ets_sample[18]}+{5'd0,match_ets_sample[19]}+
     {5'd0,match_ets_sample[20]}+{5'd0,match_ets_sample[21]}+
     {5'd0,match_ets_sample[22]}+{5'd0,match_ets_sample[23]}+
     {5'd0,match_ets_sample[24]}+{5'd0,match_ets_sample[25]}+
     {5'd0,match_ets_sample[26]}+{5'd0,match_ets_sample[27]}+
     {5'd0,match_ets_sample[28]}+{5'd0,match_ets_sample[29]});

wire [5:0] corr_sts_sample;
assign corr_sts_sample =
    ({5'd0,match_sts_sample[0]}+{5'd0,match_sts_sample[1]}+
     {5'd0,match_sts_sample[2]}+{5'd0,match_sts_sample[3]}+
     {5'd0,match_sts_sample[4]}+{5'd0,match_sts_sample[5]}+
     {5'd0,match_sts_sample[6]}+{5'd0,match_sts_sample[7]}+
     {5'd0,match_sts_sample[8]}+{5'd0,match_sts_sample[9]}+
     {5'd0,match_sts_sample[10]}+{5'd0,match_sts_sample[11]}+
     {5'd0,match_sts_sample[12]}+{5'd0,match_sts_sample[13]}+
     {5'd0,match_sts_sample[14]}+{5'd0,match_sts_sample[15]}+
     {5'd0,match_sts_sample[16]}+{5'd0,match_sts_sample[17]}+
     {5'd0,match_sts_sample[18]}+{5'd0,match_sts_sample[19]}+
     {5'd0,match_sts_sample[20]}+{5'd0,match_sts_sample[21]}+
     {5'd0,match_sts_sample[22]}+{5'd0,match_sts_sample[23]}+
     {5'd0,match_sts_sample[24]}+{5'd0,match_sts_sample[25]}+
     {5'd0,match_sts_sample[26]}+{5'd0,match_sts_sample[27]}+
     {5'd0,match_sts_sample[28]}+{5'd0,match_sts_sample[29]}+
     {5'd0,match_sts_sample[30]}+{5'd0,match_sts_sample[31]}+
     {5'd0,match_sts_sample[32]}+{5'd0,match_sts_sample[33]}+
     {5'd0,match_sts_sample[34]}+{5'd0,match_sts_sample[35]}+
     {5'd0,match_sts_sample[36]}+{5'd0,match_sts_sample[37]});

// Sequence selection mux (combinatorial)
reg [5:0] corr_sel_sample;
always @(*) begin
    case (seq_select)
        2'd0:    corr_sel_sample = corr_nts_sample;
        2'd1:    corr_sel_sample = corr_ets_sample;
        2'd2:    corr_sel_sample = corr_sts_sample;
        default: corr_sel_sample = corr_nts_sample;
    endcase
end

// Threshold compare
wire thresh_hit_sample = (corr_sel_sample >= corr_threshold);

// ---------------------------------------------------------------------------
// Stage 3 — Holdoff Counter
// Prevents re-fire for HOLDOFF dibits after each sync_fire.
// ---------------------------------------------------------------------------

reg [7:0] holdoff_cnt_sample;
wire      holdoff_active_sample = (holdoff_cnt_sample != 8'd0);

// Internal combinatorial fire signal (used by ALL control registers)
wire sync_fire_sample = thresh_hit_sample & ~holdoff_active_sample & dibit_valid;

// R1: one always block for holdoff_cnt_sample
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        holdoff_cnt_sample <= 8'd0;
    else if (sync_fire_sample)
        holdoff_cnt_sample <= HOLDOFF[7:0];
    else if (dibit_valid && holdoff_active_sample)
        holdoff_cnt_sample <= holdoff_cnt_sample - 8'd1;
end

// ---------------------------------------------------------------------------
// Stage 4 — sync_found Output Register
// One-cycle pulse, 1 clock after sync_fire_sample.
// R1: one always block for sync_found.
// ---------------------------------------------------------------------------

always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        sync_found <= 1'b0;
    else
        sync_found <= sync_fire_sample;
end

// ---------------------------------------------------------------------------
// Stage 5 — Slot Position Counter
// Resets on sync_fire_sample, increments on each dibit_valid.
// slot_number increments when slot_position wraps.
// ---------------------------------------------------------------------------

// R1: one always block for slot_position
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_position <= 8'd0;
    else if (dibit_valid) begin
        if (sync_fire_sample)
            slot_position <= 8'd0;
        else if (slot_position == (SLOT_SYMS[7:0] - 8'd1))
            slot_position <= 8'd0;
        else
            slot_position <= slot_position + 8'd1;
    end
end

// R1: one always block for slot_number
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        slot_number <= 2'd0;
    else if (dibit_valid && !sync_fire_sample &&
             slot_position == (SLOT_SYMS[7:0] - 8'd1))
        slot_number <= slot_number + 2'd1;
end

// ---------------------------------------------------------------------------
// Stage 6 — Lock Detection FSM (R5: 3 separate always blocks)
//
// States:
//   S_HUNT — searching for first sync_fire
//   S_ACQR — accumulating consecutive pulses (need LOCK_COUNT with good spacing)
//   S_LOCK — locked; watchdog monitors pulse interval
//
// spacing_cnt_sample counts dibits between consecutive sync_fire pulses.
// Resets on sync_fire; increments on every other dibit_valid.
// ---------------------------------------------------------------------------

localparam [1:0] S_HUNT = 2'd0,
                 S_ACQR = 2'd1,
                 S_LOCK = 2'd2;

reg [1:0]  lock_state_sample;
reg [1:0]  next_lock_state_sample;
reg [9:0]  spacing_cnt_sample;
reg [2:0]  consec_cnt_sample;

// Spacing in range?
wire spacing_ok_sample = (spacing_cnt_sample >= (SLOT_SYMS - LOCK_TOL)) &&
                         (spacing_cnt_sample <= (SLOT_SYMS + LOCK_TOL));

// Spacing timed out (no sync for too long)?
wire spacing_timeout_sample = (spacing_cnt_sample > LOCK_TIMEOUT);

// R1: State register
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        lock_state_sample <= S_HUNT;
    else
        lock_state_sample <= next_lock_state_sample;
end

// R1: Spacing counter
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        spacing_cnt_sample <= 10'd0;
    else if (dibit_valid) begin
        if (sync_fire_sample)
            spacing_cnt_sample <= 10'd0;
        else if (spacing_cnt_sample < 10'd1023)
            spacing_cnt_sample <= spacing_cnt_sample + 10'd1;
    end
end

// R1: Consecutive good pulse counter
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        consec_cnt_sample <= 3'd0;
    else begin
        case (lock_state_sample)
            S_HUNT:
                if (sync_fire_sample)
                    consec_cnt_sample <= 3'd1;
            S_ACQR: begin
                if (sync_fire_sample) begin
                    if (spacing_ok_sample)
                        consec_cnt_sample <= consec_cnt_sample + 3'd1;
                    else
                        consec_cnt_sample <= 3'd1;  // bad spacing; restart count
                end else if (dibit_valid && spacing_timeout_sample)
                    consec_cnt_sample <= 3'd0;
            end
            S_LOCK:
                if (sync_fire_sample && !spacing_ok_sample)
                    consec_cnt_sample <= 3'd0;
            default:
                consec_cnt_sample <= 3'd0;
        endcase
    end
end

// R5: Next-state logic (combinatorial)
always @(*) begin
    next_lock_state_sample = lock_state_sample;  // default: hold
    case (lock_state_sample)
        S_HUNT:
            if (sync_fire_sample)
                next_lock_state_sample = S_ACQR;
        S_ACQR: begin
            if (consec_cnt_sample >= LOCK_COUNT[2:0])
                next_lock_state_sample = S_LOCK;
            else if (dibit_valid && spacing_timeout_sample && !sync_fire_sample)
                next_lock_state_sample = S_HUNT;
        end
        S_LOCK:
            if (dibit_valid && spacing_timeout_sample && !sync_fire_sample)
                next_lock_state_sample = S_HUNT;
        default:
            next_lock_state_sample = S_HUNT;
    endcase
end

// R1: sync_locked output register
always @(posedge clk_sample or negedge rst_n_sample) begin
    if (!rst_n_sample)
        sync_locked <= 1'b0;
    else
        sync_locked <= (lock_state_sample == S_LOCK);
end

endmodule

`default_nettype wire
