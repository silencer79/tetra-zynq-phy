// =============================================================================
// tb_ul_full_chain.v — Full UL RX chain: sync → capture → demod → sch_hu
//
// Drives a synthetic 103-symbol UL Control-Burst (ZOH-upsampled to 4 sps)
// into tetra_ul_sync_detect_os4 + tetra_ul_burst_capture, then the captured
// burst feeds tetra_ul_pi4dqpsk_demod → tetra_ul_sch_hu_decoder.
//
// Stimulus files (sim_out/, produced by scripts/gen_ul_demod_tv.py):
//   ul_full_iq.hex    — 2 lines/sample (I, Q as 16-bit hex).
//                       Per burst: 400 pre-zeros + 103*4 ZOH + 1200 post-zeros.
//   ul_demod_exp.hex  — 13 bytes/burst: [crc:1][info:12] (shared with integ TB).
//
// PASS criteria: for each burst, info_valid fires, crc_ok=1, info matches.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_ul_full_chain;

localparam integer IQ_WIDTH         = 16;
localparam integer SOFT_WIDTH       = 8;
localparam integer N_BURSTS         = 4;
localparam integer SYMS_FULL        = 103;
localparam integer SPS              = 4;
localparam integer PRE_SMP          = 400;
localparam integer POST_SMP         = 1200;
localparam integer SMP_PER_BURST    = PRE_SMP + SYMS_FULL*SPS + POST_SMP; // 2012
localparam integer TOTAL_IQ         = N_BURSTS * SMP_PER_BURST;
localparam integer CLK_PERIOD       = 10;

reg clk;
reg rst_n;

// RX front-end stimulus (shared by sync_detect and burst_capture)
reg  signed [IQ_WIDTH-1:0] i_in_sys, q_in_sys;
reg                        valid_in_sys;

// sync_detect outputs
wire                 sync_found_w;
wire [5:0]           corr_peak_w;
wire [1:0]           best_phase_w;

// burst_capture outputs (= demod inputs)
wire signed [IQ_WIDTH-1:0] cap_i_w, cap_q_w;
wire                       cap_valid_w, cap_first_w, cap_last_w, cap_half_w;
wire                       capture_busy_w;
wire [15:0]                bursts_captured_w;

// demod outputs (= decoder inputs)
wire signed [SOFT_WIDTH-1:0] soft0_w, soft1_w;
wire                         soft_valid_w, soft_first_w, soft_last_w, soft_half_w;

// decoder outputs
reg  [31:0] scramb_init;
wire [91:0] info_bits;
wire        info_valid, crc_ok;
wire [15:0] decodes_attempted, decodes_ok;

// -------------------------------------------------------------------------
// DUT wiring
// -------------------------------------------------------------------------
tetra_ul_sync_detect_os4 #(
    .IQ_WIDTH  (IQ_WIDTH),
    .CORR_WIDTH(6),
    .HOLDOFF   (50)
) u_sync (
    .clk_sys           (clk),
    .rst_n_sys         (rst_n),
    .reset_peak_sys    (1'b0),
    .i_in_sys          (i_in_sys),
    .q_in_sys          (q_in_sys),
    .valid_in_sys      (valid_in_sys),
    .corr_threshold_sys(6'd14),
    .sync_found_sys    (sync_found_w),
    .corr_peak_sys     (corr_peak_w),
    .best_phase_sys    (best_phase_w)
);

tetra_ul_burst_capture #(
    .IQ_WIDTH(IQ_WIDTH)
) u_cap (
    .clk_sys            (clk),
    .rst_n_sys          (rst_n),
    .i_in_sys           (i_in_sys),
    .q_in_sys           (q_in_sys),
    .valid_in_sys       (valid_in_sys),
    .sync_found_sys     (sync_found_w),
    .best_phase_sys     (best_phase_w),
    .i_out_sys          (cap_i_w),
    .q_out_sys          (cap_q_w),
    .iq_valid_sys       (cap_valid_w),
    .iq_first_sys       (cap_first_w),
    .iq_last_sys        (cap_last_w),
    .iq_half_sys        (cap_half_w),
    .capture_busy_sys   (capture_busy_w),
    .bursts_captured_sys(bursts_captured_w)
);

tetra_ul_pi4dqpsk_demod #(
    .IQ_WIDTH  (IQ_WIDTH),
    .SOFT_WIDTH(SOFT_WIDTH)
) u_demod (
    .clk_sys       (clk),
    .rst_n_sys     (rst_n),
    .i_in_sys      (cap_i_w),
    .q_in_sys      (cap_q_w),
    .iq_valid_sys  (cap_valid_w),
    .iq_first_sys  (cap_first_w),
    .iq_last_sys   (cap_last_w),
    .iq_half_sys   (cap_half_w),
    .soft_bit0_sys (soft0_w),
    .soft_bit1_sys (soft1_w),
    .soft_valid_sys(soft_valid_w),
    .soft_first_sys(soft_first_w),
    .soft_last_sys (soft_last_w),
    .soft_half_sys (soft_half_w)
);

tetra_ul_sch_hu_decoder #(
    .SOFT_IN_WIDTH(SOFT_WIDTH)
) u_dec (
    .clk_sys               (clk),
    .rst_n_sys             (rst_n),
    .scramb_init_sys       (scramb_init),
    .soft_bit0_sys         (soft0_w),
    .soft_bit1_sys         (soft1_w),
    .soft_valid_sys        (soft_valid_w),
    .soft_first_sys        (soft_first_w),
    .soft_last_sys         (soft_last_w),
    .soft_half_sys         (soft_half_w),
    .info_bits_sys         (info_bits),
    .info_valid_sys        (info_valid),
    .crc_ok_sys            (crc_ok),
    .decodes_attempted_sys (decodes_attempted),
    .decodes_ok_sys        (decodes_ok)
);

initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// -------------------------------------------------------------------------
// Memories
// -------------------------------------------------------------------------
reg [15:0] iq_mem  [0:TOTAL_IQ*2 - 1];
reg [7:0]  exp_mem [0:N_BURSTS*13 - 1];

integer pass_cnt, fail_cnt;
integer sync_fires_this_burst;

// Count sync fires
always @(posedge clk) begin
    if (rst_n && sync_found_w)
        sync_fires_this_burst = sync_fires_this_burst + 1;
end

// -------------------------------------------------------------------------
// info match helper (same format as other UL TBs)
// -------------------------------------------------------------------------
function integer info_match;
    input [91:0]  info_actual;
    input integer burst_i;
    integer       i, bit_actual, bit_expected;
    reg [7:0]     eb;
    begin
        info_match = 1;
        for (i = 0; i < 92; i = i + 1) begin
            eb = exp_mem[burst_i*13 + 1 + (i/8)];
            bit_expected = (eb >> (7 - (i%8))) & 1;
            bit_actual   = info_actual[i];
            if (bit_actual !== bit_expected) begin
                info_match = 0;
                if (i < 8)
                    $display("    info[%0d] actual=%0d expected=%0d",
                             i, bit_actual, bit_expected);
            end
        end
    end
endfunction

// -------------------------------------------------------------------------
// Main sequence
// -------------------------------------------------------------------------
integer b_idx, s_idx, wait_cycles, burst_base;

initial begin
    $dumpfile("sim_out/tb_ul_full_chain.vcd");
    $dumpvars(1, u_sync);
    $dumpvars(1, u_cap);
    $dumpvars(1, u_demod);
    $dumpvars(1, u_dec);

    scramb_init = 32'hE1670EC7;
    if ($value$plusargs("SCRAMB_INIT=%h", scramb_init))
        $display("(scramb_init override: 0x%08h)", scramb_init);

    $readmemh("sim_out/ul_full_iq.hex",   iq_mem);
    $readmemh("sim_out/ul_demod_exp.hex", exp_mem);

    rst_n                 = 1'b0;
    i_in_sys              = 0;
    q_in_sys              = 0;
    valid_in_sys          = 1'b0;
    pass_cnt              = 0;
    fail_cnt              = 0;
    sync_fires_this_burst = 0;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("=== tb_ul_full_chain: %0d bursts, scramb_init=0x%08h ===",
             N_BURSTS, scramb_init);

    for (b_idx = 0; b_idx < N_BURSTS; b_idx = b_idx + 1) begin
        $display("-- burst #%0d --", b_idx);
        burst_base            = b_idx * SMP_PER_BURST;
        sync_fires_this_burst = 0;

        // Play back all samples of this burst — 1 sample per sys_clk.
        // info_valid may fire during this loop; we tolerate that and check
        // after playback ends.
        for (s_idx = 0; s_idx < SMP_PER_BURST; s_idx = s_idx + 1) begin
            @(posedge clk);
            #1;
            i_in_sys     = $signed(iq_mem[(burst_base + s_idx)*2 + 0]);
            q_in_sys     = $signed(iq_mem[(burst_base + s_idx)*2 + 1]);
            valid_in_sys = 1'b1;
        end
        @(posedge clk);
        #1;
        valid_in_sys = 1'b0;

        // If info_valid didn't fire during playback (unlikely), wait a bit
        wait_cycles = 0;
        while (!info_valid && wait_cycles < 2000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (decodes_attempted < (b_idx + 1)) begin
            $display("  FAIL  no decode attempted (sync_fires=%0d corr_peak=%0d best_phase=%0d captured=%0d)",
                     sync_fires_this_burst, corr_peak_w, best_phase_w, bursts_captured_w);
            fail_cnt = fail_cnt + 1;
        end else begin
            if (crc_ok && info_match(info_bits, b_idx)) begin
                $display("  PASS  sync_fires=%0d best_phase=%0d corr_peak=%0d info[0:16]=%04h",
                         sync_fires_this_burst, best_phase_w, corr_peak_w, info_bits[15:0]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  crc_ok=%0d sync_fires=%0d info[0:16]=%04h exp=%02h %02h",
                         crc_ok, sync_fires_this_burst, info_bits[15:0],
                         exp_mem[b_idx*13 + 1], exp_mem[b_idx*13 + 2]);
                fail_cnt = fail_cnt + 1;
            end
        end
    end

    $display("=============================================");
    $display("bursts_captured=%0d  decodes_attempted=%0d  decodes_ok=%0d",
             bursts_captured_w, decodes_attempted, decodes_ok);
    $display("TB counters: pass=%0d  fail=%0d  / %0d bursts",
             pass_cnt, fail_cnt, N_BURSTS);
    if (pass_cnt == N_BURSTS)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");
    $display("=============================================");
    $finish;
end

initial begin
    #1_000_000_000;
    $display("WATCHDOG timeout");
    $finish;
end

endmodule

`default_nettype wire
