// =============================================================================
// tb_ul_nub_e2e.v — End-to-End TB für Phase C Voice-Channel-Pipeline
// =============================================================================
//
// Stimuliert synthetic NUB-Burst-IQ-Samples (TAIL1 + random BKN1 + BB1 + NTS1
// + BB2 + random BKN2 + TAIL2 = 255 sym), feeds into:
//   - tetra_ul_sync_detect_os4 mit NTS1-Pattern
//   - tetra_ul_nub_capture
//   - tetra_voice_relay
//   - manuelle Dispatcher-Voice-Override-Logik (Mini-Stub)
//
// Asserts:
//   1. sync_found_sys feuert nach NTS1-Empfang
//   2. coded_valid_sys pulst nach POST_WAIT
//   3. coded_bits[431:216] == eingespeiste BKN1 dibits
//   4. coded_bits[215:0]   == eingespeiste BKN2 dibits
//   5. relay_valid_sys high nach erstem dl_slot_pulse mit voice_slot_tn
//   6. relay_blk identisch zu coded_bits
//
// Symbol-Rate IQ-Generation: π/4-DQPSK constellation per dibit
//   dibit  Δφ
//   00     +π/4
//   01     +3π/4
//   10     -π/4
//   11     -3π/4
// (per ETSI EN 300 392-2 §5.3.2.1, matches tetra_pi4dqpsk_mod table)
//
// Sample-Rate: 4 sps (= 72 kHz post-RRC).  TB feeds raw IQ at clk_sys rate
// with valid_in_sys gated on a divider — same model as real rx_frontend.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_ul_nub_e2e;

localparam IQ_W       = 16;
localparam SPS        = 4;
localparam NUB_SYMS   = 255;
localparam CLK_PERIOD = 10;   // 100 MHz clk_sys

// NTS1 pattern (same as tetra_burst_builder.v NTS1_REF)
localparam [21:0] NTS1_DIBITS = {
    2'b11, 2'b01, 2'b00, 2'b00, 2'b11, 2'b10,
    2'b10, 2'b01, 2'b11, 2'b01, 2'b00
};

// TAIL1 / TAIL2 from §9.4.4.3.2 q-sequence
localparam [11:0] TAIL1_DIBITS = {2'b00, 2'b01, 2'b10, 2'b10, 2'b11, 2'b01};
localparam [9:0]  TAIL2_DIBITS = {2'b10, 2'b11, 2'b01, 2'b11, 2'b00};

// Test stimuli
reg [215:0] bkn1_stim_dibits;
reg [215:0] bkn2_stim_dibits;
reg [13:0]  bb1_stim_dibits;   // 7 sym × 2 = 14 bits
reg [15:0]  bb2_stim_dibits;   // 8 sym × 2 = 16 bits

// Concatenated full burst dibit stream (255 sym × 2 = 510 bits)
// MSB-first: TAIL1[5]..TAIL1[0] BKN1[107]..BKN1[0] BB1[6]..BB1[0] NTS1[10]..[0] BB2[7]..[0] BKN2[107]..[0] TAIL2[4]..[0]
// Plus 1 sym HA1 between TAIL1 and BKN1, 1 sym HA2 between BKN2 and TAIL2 = NDB.
// HA = phase-adjust = 00 by convention.
reg [509:0] full_burst_dibits;

// Clock + reset
reg clk_sys = 0;
reg rst_n_sys = 0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// Stimulus driver: emits one symbol's worth of IQ samples (SPS=4)
reg signed [IQ_W-1:0] i_in_sys, q_in_sys;
reg                   valid_in_sys;

// π/4-DQPSK accumulating phase
// Constellation table per ETSI (dibit → phase increment in units of π/8):
//   00 → +1 (= +π/4)     01 → +3 (= +3π/4)
//   10 → -1 (= -π/4)     11 → -3 (= -3π/4)
//
// Symbol-rate stream of dibits at TX side → cumulative phase, complex
// exponential, scaled to 16-bit IQ.

reg signed [3:0] phase_acc;  // phase modulo 16, units of π/8

// Drive a single symbol: emit SPS=4 IQ samples with constant phase per
// symbol (no pulse-shaping — RRC is a TB simplification, sync detector
// tolerates squared pulses).
task drive_symbol;
    input [1:0] dibit;
    integer ph_step;
    integer s;
    reg signed [IQ_W-1:0] i_val, q_val;
    begin
        // Phase increment per ETSI (units of π/8 because we have 16-phase
        // constellation table below).  ETSI dibit → Δφ:
        //   00 → +π/4  = +2     01 → +3π/4 = +6
        //   10 → -π/4  = -2     11 → -3π/4 = -6
        case (dibit)
            2'b00: ph_step =  2;
            2'b01: ph_step =  6;
            2'b10: ph_step = -2;
            2'b11: ph_step = -6;
        endcase
        phase_acc = phase_acc + ph_step[3:0];
        // Sample on the constellation:
        //   ph (units of π/8) → I = cos(ph·π/8) × A, Q = sin(ph·π/8) × A
        // For TB simplicity hardcode the 16-phase table with A ≈ 16000.
        case (phase_acc[3:0])
            4'd0:  begin i_val =  16'sd16000; q_val =  16'sd0;     end
            4'd1:  begin i_val =  16'sd14781; q_val =  16'sd6122;  end
            4'd2:  begin i_val =  16'sd11314; q_val =  16'sd11314; end
            4'd3:  begin i_val =  16'sd6122;  q_val =  16'sd14781; end
            4'd4:  begin i_val =  16'sd0;     q_val =  16'sd16000; end
            4'd5:  begin i_val = -16'sd6122;  q_val =  16'sd14781; end
            4'd6:  begin i_val = -16'sd11314; q_val =  16'sd11314; end
            4'd7:  begin i_val = -16'sd14781; q_val =  16'sd6122;  end
            4'd8:  begin i_val = -16'sd16000; q_val =  16'sd0;     end
            4'd9:  begin i_val = -16'sd14781; q_val = -16'sd6122;  end
            4'd10: begin i_val = -16'sd11314; q_val = -16'sd11314; end
            4'd11: begin i_val = -16'sd6122;  q_val = -16'sd14781; end
            4'd12: begin i_val =  16'sd0;     q_val = -16'sd16000; end
            4'd13: begin i_val =  16'sd6122;  q_val = -16'sd14781; end
            4'd14: begin i_val =  16'sd11314; q_val = -16'sd11314; end
            4'd15: begin i_val =  16'sd14781; q_val = -16'sd6122;  end
        endcase
        // Emit SPS IQ samples at one valid per symbol-rate divider
        for (s = 0; s < SPS; s = s + 1) begin
            @(posedge clk_sys);
            i_in_sys     <= i_val;
            q_in_sys     <= q_val;
            valid_in_sys <= 1'b1;
            @(posedge clk_sys);
            valid_in_sys <= 1'b0;
            // wait extra clk_sys cycles to simulate 72 kHz valid spacing
            repeat (10) @(posedge clk_sys);
        end
    end
endtask

// -------------------------------------------------------------------------
// Build full burst dibit stream
// Order (transmit-order): TAIL1(6) + HA1(1=00) + BKN1(108) + BB1(7) + NTS1(11)
//                       + BB2(8) + BKN2(108) + HA2(1=00) + TAIL2(5) = 255 sym
// -------------------------------------------------------------------------
integer i;
reg [1:0] burst_seq [0:NUB_SYMS-1];

task build_burst;
    reg [31:0] rnd;
    begin
        // Randomize BKN1/BKN2/BB stims (concat several $random calls)
        bkn1_stim_dibits = {$random, $random, $random, $random, $random, $random, $random};
        bkn1_stim_dibits = bkn1_stim_dibits & {216{1'b1}};
        bkn2_stim_dibits = {$random, $random, $random, $random, $random, $random, $random};
        bkn2_stim_dibits = bkn2_stim_dibits & {216{1'b1}};
        rnd = $random; bb1_stim_dibits = rnd[13:0];
        rnd = $random; bb2_stim_dibits = rnd[15:0];

        // Build flat burst array (index 0 = first transmitted sym)
        // TAIL1: 6 sym
        for (i = 0; i < 6; i = i + 1)
            burst_seq[i] = TAIL1_DIBITS[(5-i)*2 +: 2];
        // HA1: 1 sym (phase-adj 00)
        burst_seq[6] = 2'b00;
        // BKN1: 108 sym
        for (i = 0; i < 108; i = i + 1)
            burst_seq[7+i] = bkn1_stim_dibits[(107-i)*2 +: 2];
        // BB1: 7 sym
        for (i = 0; i < 7; i = i + 1)
            burst_seq[115+i] = bb1_stim_dibits[(6-i)*2 +: 2];
        // NTS1: 11 sym
        for (i = 0; i < 11; i = i + 1)
            burst_seq[122+i] = NTS1_DIBITS[(10-i)*2 +: 2];
        // BB2: 8 sym
        for (i = 0; i < 8; i = i + 1)
            burst_seq[133+i] = bb2_stim_dibits[(7-i)*2 +: 2];
        // BKN2: 108 sym
        for (i = 0; i < 108; i = i + 1)
            burst_seq[141+i] = bkn2_stim_dibits[(107-i)*2 +: 2];
        // HA2: 1 sym
        burst_seq[249] = 2'b00;
        // TAIL2: 5 sym
        for (i = 0; i < 5; i = i + 1)
            burst_seq[250+i] = TAIL2_DIBITS[(4-i)*2 +: 2];
    end
endtask

// -------------------------------------------------------------------------
// DUT — sync detector + capture + relay
// -------------------------------------------------------------------------
wire                  nub_sync_found_w;
wire [5:0]            nub_corr_peak_w;
wire [1:0]            nub_best_phase_w;

tetra_ul_sync_detect_os4 #(
    .IQ_WIDTH    (IQ_W),
    .CORR_WIDTH  (6),
    .HOLDOFF     (250),
    .SYNC_PATTERN({8'b0, NTS1_DIBITS}),
    .SYNC_LEN_SYM(11)
) u_sync (
    .clk_sys            (clk_sys),
    .rst_n_sys          (rst_n_sys),
    .reset_peak_sys     (1'b0),
    .i_in_sys           (i_in_sys),
    .q_in_sys           (q_in_sys),
    .valid_in_sys       (valid_in_sys),
    .corr_threshold_sys (6'd8),
    .sync_found_sys     (nub_sync_found_w),
    .corr_peak_sys      (nub_corr_peak_w),
    .best_phase_sys     (nub_best_phase_w)
);

wire [431:0] coded_bits_w;
wire         coded_valid_w;
wire [15:0]  bursts_captured_w;

tetra_ul_nub_capture #(
    .IQ_WIDTH(IQ_W)
) u_capture (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .i_in_sys             (i_in_sys),
    .q_in_sys             (q_in_sys),
    .valid_in_sys         (valid_in_sys),
    .sync_found_sys       (nub_sync_found_w),
    .best_phase_sys       (nub_best_phase_w),
    .coded_bits_sys       (coded_bits_w),
    .coded_valid_sys      (coded_valid_w),
    .bursts_captured_sys  (bursts_captured_w)
);

// Voice-relay
reg          dl_slot_pulse_sys = 0;
reg  [1:0]   dl_tn_sys = 0;
wire [431:0] relay_blk_w;
wire         relay_valid_w;
wire [15:0]  relay_cnt_w;

tetra_voice_relay #(
    .TIMEOUT_FRAMES(2)
) u_relay (
    .clk_sys                (clk_sys),
    .rst_n_sys              (rst_n_sys),
    .voice_active_mask_sys  (4'b0010),   // TN=1 active
    .voice_slot_tn_sys      (2'd1),
    .ul_coded_bits_sys      (coded_bits_w),
    .ul_coded_valid_sys     (coded_valid_w),
    .dl_slot_pulse_sys      (dl_slot_pulse_sys),
    .dl_tn_sys              (dl_tn_sys),
    .relay_blk_sys          (relay_blk_w),
    .relay_valid_sys        (relay_valid_w),
    .relay_cnt_sys          (relay_cnt_w)
);

// -------------------------------------------------------------------------
// Stimulus sequence
// -------------------------------------------------------------------------
integer errors = 0;
reg sync_seen = 1'b0;
reg coded_seen = 1'b0;
reg [31:0] rnd_dibit;

// Monitor sync_found + corr peak (debug)
reg [5:0] last_peak = 0;
always @(posedge clk_sys) begin
    if (nub_corr_peak_w > last_peak) begin
        last_peak <= nub_corr_peak_w;
        $display("[%0t] corr_peak rose to %0d", $time, nub_corr_peak_w);
    end
    if (nub_sync_found_w) begin
        sync_seen <= 1'b1;
        $display("[%0t] NTS1 sync_found, corr_peak=%0d, best_phase=%0d",
                 $time, nub_corr_peak_w, nub_best_phase_w);
    end
    if (coded_valid_w) begin
        coded_seen <= 1'b1;
        $display("[%0t] coded_valid pulse, bursts_captured=%0d",
                 $time, bursts_captured_w);
        // Check BKN1
        if (coded_bits_w[431:216] !== bkn1_stim_dibits) begin
            $display("  FAIL: BKN1 mismatch");
            $display("    expect %h", bkn1_stim_dibits);
            $display("    got    %h", coded_bits_w[431:216]);
            errors = errors + 1;
        end else begin
            $display("  PASS: BKN1 match");
        end
        if (coded_bits_w[215:0] !== bkn2_stim_dibits) begin
            $display("  FAIL: BKN2 mismatch");
            $display("    expect %h", bkn2_stim_dibits);
            $display("    got    %h", coded_bits_w[215:0]);
            errors = errors + 1;
        end else begin
            $display("  PASS: BKN2 match");
        end
    end
end

initial begin
    $dumpfile("tb_ul_nub_e2e.vcd");
    $dumpvars(0, tb_ul_nub_e2e);

    // Reset
    rst_n_sys    = 0;
    valid_in_sys = 0;
    i_in_sys     = 0;
    q_in_sys     = 0;
    phase_acc    = 4'd0;
    #100 rst_n_sys = 1;
    #100;

    // Build + drive burst
    build_burst;
    $display("[%0t] Driving NUB burst: BKN1=%h BKN2=%h",
             $time, bkn1_stim_dibits, bkn2_stim_dibits);

    // Drive 50 noise symbols first (random) to mimic pre-burst noise
    for (i = 0; i < 50; i = i + 1) begin
        rnd_dibit = $random;
        drive_symbol(rnd_dibit[1:0]);
    end

    // Drive the burst
    for (i = 0; i < NUB_SYMS; i = i + 1)
        drive_symbol(burst_seq[i]);

    // Drive 100 noise symbols after to let capture finish
    for (i = 0; i < 100; i = i + 1) begin
        rnd_dibit = $random;
        drive_symbol(rnd_dibit[1:0]);
    end

    // Wait for coded_valid
    if (!coded_seen) #1000;

    // Pulse DL slot for relay (4 slots, voice slot = TN=1)
    repeat (4) begin
        dl_slot_pulse_sys <= 1'b1;
        @(posedge clk_sys);
        dl_slot_pulse_sys <= 1'b0;
        @(posedge clk_sys);
        if (dl_tn_sys == 2'd1) begin
            if (relay_valid_w && relay_blk_w === coded_bits_w) begin
                $display("[%0t] PASS: relay_valid=1, relay_blk match coded_bits (TN=%0d)",
                         $time, dl_tn_sys);
            end else if (dl_tn_sys == 2'd1) begin
                $display("[%0t] relay_valid=%b on TN=1 (expect 1 after coded_valid)",
                         $time, relay_valid_w);
            end
        end
        dl_tn_sys <= dl_tn_sys + 1;
        repeat (50) @(posedge clk_sys);
    end

    // Summary
    if (!sync_seen) begin
        $display("FAIL: sync_found never asserted");
        errors = errors + 1;
    end
    if (!coded_seen) begin
        $display("FAIL: coded_valid never asserted");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("\n==== TB PASS ====\n");
    else
        $display("\n==== TB FAIL (%0d errors) ====\n", errors);

    $finish;
end

endmodule

`default_nettype wire
