`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_full_loopback_sync;

localparam CLK_HALF = 5;
localparam integer BURSTS_TO_SEND = 4;
// SYM_DIV must be (4 × lvds_cnt_period) - 1 = 4×256-1 = 1023 when clk_sys=clk_lvds,
// so that rrc_filter output rate (4×symbol_rate) matches tx_frontend FIFO read rate.
localparam integer SYM_DIV = 13'd1023;

reg clk_sys;
reg clk_lvds;
reg rst_n_sys;
reg rst_n_lvds;

reg  [215:0] block1_data_sys;
reg  [215:0] block2_data_sys;
reg  [29:0]  bb_data_sys;
reg  [239:0] bkn1_sb_data_sys;
reg  [27:0]  bb_sb_data_sys;
reg  [1:0]   burst_type_sys;
reg          build_req_sys;
reg          idle_request_armed;

wire [1:0] builder_dibit_sys;
wire       builder_dibit_valid_sys;
wire       tx_done_sys;
wire       tx_busy_sys;

wire signed [15:0] mod_i_sys;
wire signed [15:0] mod_q_sys;
wire               mod_valid_sys;

wire signed [15:0] rrc_i_sys;
wire signed [15:0] rrc_q_sys;
wire               rrc_valid_sys;

wire signed [15:0] tx_i_lvds;
wire signed [15:0] tx_q_lvds;
wire               tx_valid_lvds;

wire signed [15:0] fe_i_sys;
wire signed [15:0] fe_q_sys;
wire               fe_valid_sys;

wire signed [15:0] tr_i_sys;
wire signed [15:0] tr_q_sys;
wire               tr_valid_sys;
wire               timing_locked_sys;
wire signed [15:0] timing_error_sys;

wire [1:0] demod_dibit_sys;
wire       demod_valid_sys;
wire       sync_found;
wire       sync_locked;
wire [7:0] slot_position;
wire [1:0] slot_number;

integer bursts_sent;
integer sync_found_count;
integer timeout_cycles;
integer fe_valid_count;
integer tr_valid_count;
integer demod_valid_count;
integer dibit_count_dbg;
integer tr_count_dbg;
integer fe_dbg_count;
integer nco_dbg_count;
integer tx_cic_dbg_count;
integer rrc_dbg_count;
integer max_fe_abs;
integer cur_fe_abs;
integer max_tr_abs;
integer cur_tr_abs;

initial clk_sys = 1'b0;
always #CLK_HALF clk_sys = ~clk_sys;

initial clk_lvds = 1'b0;
always #CLK_HALF clk_lvds = ~clk_lvds;

tetra_burst_builder #(
    .BLOCK_BITS   (216),
    .BB_BITS      (30),
    .BB_SB_BITS   (28),
    .BKN1_SB_BITS (240),
    .SYM_DIV      (SYM_DIV)
) dut_builder (
    .clk_sys            (clk_sys),
    .rst_n_sys          (rst_n_sys),
    .block1_data_sys    (block1_data_sys),
    .block2_data_sys    (block2_data_sys),
    .bb_data_sys        (bb_data_sys),
    .bkn1_sb_data_sys   (bkn1_sb_data_sys),
    .bb_sb_data_sys     (bb_sb_data_sys),
    .burst_type_sys     (burst_type_sys),
    .build_req_sys      (build_req_sys),
    .tx_dibit_sys       (builder_dibit_sys),
    .tx_dibit_valid_sys (builder_dibit_valid_sys),
    .tx_done_sys        (tx_done_sys),
    .tx_busy_sys        (tx_busy_sys)
);

tetra_pi4dqpsk_mod #(
    .IQ_WIDTH    (16),
    .PHASE_WIDTH (16),
    .LUT_DEPTH   (1024)
) dut_mod (
    .clk_sample       (clk_sys),
    .rst_n_sample     (rst_n_sys),
    .dibit_in         (builder_dibit_sys),
    .dibit_valid      (builder_dibit_valid_sys),
    .i_out            (mod_i_sys),
    .q_out            (mod_q_sys),
    .sample_valid_out (mod_valid_sys)
);

tetra_rrc_filter #(
    .IQ_WIDTH      (16),
    .RRC_ACC_SHIFT (14)
) dut_rrc (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .i_in             (mod_i_sys),
    .q_in             (mod_q_sys),
    .sample_valid_in  (mod_valid_sys),
    .i_out            (rrc_i_sys),
    .q_out            (rrc_q_sys),
    .sample_valid_out (rrc_valid_sys)
);

tetra_tx_frontend #(
    .IQ_WIDTH  (16),
    .CIC_SHIFT (24),
    .CIC_ACC   (48)
) dut_tx_frontend (
    .clk_sys         (clk_sys),
    .rst_n_sys       (rst_n_sys),
    .i_in            (rrc_i_sys),
    .q_in            (rrc_q_sys),
    .sample_valid_in (rrc_valid_sys),
    .clk_lvds        (clk_lvds),
    .rst_n_lvds      (rst_n_lvds),
    .tx_i_lvds       (tx_i_lvds),
    .tx_q_lvds       (tx_q_lvds),
    .tx_valid_lvds   (tx_valid_lvds)
);

tetra_rx_frontend #(
    .IQ_WIDTH      (16),
    .CIC_ORDER     (5),
    .CIC_R         (64),
    .CIC_M         (1),
    .RRC_TAPS      (33),
    .RRC_ACC_SHIFT (14)
) dut_rx_frontend (
    .clk_sys       (clk_sys),
    .rst_n_sys     (rst_n_sys),
    .clk_lvds      (clk_lvds),
    .rst_n_lvds    (rst_n_lvds),
    .rx_i_lvds     (tx_i_lvds),
    .rx_q_lvds     (tx_q_lvds),
    .rx_valid_lvds (tx_valid_lvds),
    .i_out_sys     (fe_i_sys),
    .q_out_sys     (fe_q_sys),
    .out_valid_sys (fe_valid_sys)
);

tetra_timing_recovery #(
    .IQ_WIDTH  (16),
    .NCO_WIDTH (32)
) dut_timing (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .i_in_sys             (fe_i_sys),
    .q_in_sys             (fe_q_sys),
    .sample_valid_in_sys  (fe_valid_sys),
    .i_out_sys            (tr_i_sys),
    .q_out_sys            (tr_q_sys),
    .sample_valid_out_sys (tr_valid_sys),
    .timing_locked_sys    (timing_locked_sys),
    .timing_error_sys     (timing_error_sys)
);

tetra_pi4dqpsk_demod #(
    .IQ_WIDTH    (16),
    .PHASE_WIDTH (16),
    .CORDIC_ITER (16)
) dut_demod (
    .clk_sample   (clk_sys),
    .rst_n_sample (rst_n_sys),
    .i_in         (tr_i_sys),
    .q_in         (tr_q_sys),
    .sample_valid (tr_valid_sys),
    .dibit_out    (demod_dibit_sys),
    .dibit_valid  (demod_valid_sys),
    .phase_error  ()
);

tetra_sync_detect #(
    .CORR_WIDTH   (6),
    .SEQ_LEN_MAX  (38),
    .HOLDOFF      (220),
    .LOCK_COUNT   (4),
    .SLOT_SYMS    (255),
    .LOCK_TOL     (8),
    .LOCK_TIMEOUT (300)
) dut_sync (
    .clk_sample     (clk_sys),
    .rst_n_sample   (rst_n_sys),
    .dibit_in       (demod_dibit_sys),
    .dibit_valid    (demod_valid_sys),
    .corr_threshold (6'd30),
    .seq_select     (2'd2),
    .sync_found     (sync_found),
    .sync_locked    (sync_locked),
    .slot_position  (slot_position),
    .slot_number    (slot_number)
);

always @(posedge clk_sys) begin
    if (!rst_n_sys)
        sync_found_count <= 0;
    else if (sync_found) begin
        sync_found_count <= sync_found_count + 1;
        $display("full-loop sync_found at time=%0t slot_pos=%0d slot_num=%0d count=%0d",
                 $time, slot_position, slot_number, sync_found_count + 1);
    end
end

always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
        fe_valid_count <= 0;
        tr_valid_count <= 0;
        demod_valid_count <= 0;
        dibit_count_dbg <= 0;
        tr_count_dbg <= 0;
        fe_dbg_count <= 0;
        nco_dbg_count <= 0;
        max_fe_abs <= 0;
        cur_fe_abs = 0;
    end else begin
        if (fe_valid_sys) begin
            fe_valid_count <= fe_valid_count + 1;
            // Track peak amplitude
            cur_fe_abs = (fe_i_sys[15]) ? (~fe_i_sys + 1) : fe_i_sys;
            if (cur_fe_abs > max_fe_abs) max_fe_abs <= cur_fe_abs;
            // Print fe sample when amplitude first exceeds threshold (signal arrived)
            if (fe_dbg_count < 20 &&
                (fe_i_sys > 16'sd200 || fe_i_sys < -16'sd200 ||
                 fe_q_sys > 16'sd200 || fe_q_sys < -16'sd200)) begin
                fe_dbg_count <= fe_dbg_count + 1;
                $display("fe_big[%0d] i=%0d q=%0d t=%0t fe_cnt=%0d",
                         fe_dbg_count, fe_i_sys, fe_q_sys, $time, fe_valid_count);
            end
        end
        if (tr_valid_sys) begin
            tr_valid_count <= tr_valid_count + 1;
            if (nco_dbg_count < 40) begin
                nco_dbg_count <= nco_dbg_count + 1;
                $display("tr[%0d] i=%0d q=%0d ted=%0d locked=%0b t=%0t",
                         nco_dbg_count, tr_i_sys, tr_q_sys,
                         timing_error_sys, timing_locked_sys, $time);
            end
            if (timing_locked_sys) begin
                tr_count_dbg <= tr_count_dbg + 1;
            end
        end
        if (demod_valid_sys) begin
            demod_valid_count <= demod_valid_count + 1;
            if (dibit_count_dbg < 60) begin
                dibit_count_dbg <= dibit_count_dbg + 1;
                $display("dbg_dibit[%0d]=%02b locked=%0b t=%0t",
                         dibit_count_dbg, demod_dibit_sys, timing_locked_sys, $time);
            end
        end
    end
end

always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
        build_req_sys <= 1'b0;
        bursts_sent <= 0;
        idle_request_armed <= 1'b1;
    end else begin
        build_req_sys <= 1'b0;
        if (tx_busy_sys)
            idle_request_armed <= 1'b1;
        else if (idle_request_armed && bursts_sent < BURSTS_TO_SEND) begin
            build_req_sys <= 1'b1;
            bursts_sent <= bursts_sent + 1;
            idle_request_armed <= 1'b0;
            $display("full-loop build_req for burst=%0d at time=%0t", bursts_sent + 1, $time);
        end
    end
end

always @(posedge clk_sys) begin
    if (rst_n_sys && tx_done_sys) begin
        $display("full-loop tx_done at time=%0t max_fe_abs=%0d fe_valid_count=%0d",
                 $time, max_fe_abs, fe_valid_count);
        max_fe_abs <= 0;
    end
end

// Print first 20 TX RRC output samples (before CIC)
always @(posedge clk_sys) begin
    if (!rst_n_sys)
        rrc_dbg_count <= 0;
    else if (rrc_valid_sys) begin
        rrc_dbg_count <= rrc_dbg_count + 1;
        if (rrc_dbg_count < 20)
            $display("rrc[%0d] i=%0d q=%0d t=%0t", rrc_dbg_count, rrc_i_sys, rrc_q_sys, $time);
    end
end

// Print 20 TX CIC output samples AFTER RRC has started producing signal
// rrc_dbg_count is set in clk_sys domain; both clocks same freq in sim so safe to read here
always @(posedge clk_lvds) begin
    if (!rst_n_lvds)
        tx_cic_dbg_count <= 0;
    else if (tx_valid_lvds && rrc_dbg_count >= 5) begin
        tx_cic_dbg_count <= tx_cic_dbg_count + 1;
        if (tx_cic_dbg_count < 20)
            $display("tx_cic[%0d] i=%0d q=%0d t=%0t", tx_cic_dbg_count, tx_i_lvds, tx_q_lvds, $time);
    end
end

initial begin
    $dumpfile("tb_tetra_full_loopback_sync.vcd");
    $dumpvars(0, tb_tetra_full_loopback_sync);

    rst_n_sys = 1'b0;
    rst_n_lvds = 1'b0;
    block1_data_sys = 216'd0;
    // BKN2 (SB block2) — AES S-box bytes 30..56 for pseudo-random timing stimulus
    // (non-periodic avoids Gardner TED false-lock that 0x1B cycling data causes)
    block2_data_sys = 216'hB81F981169D98E949B1E87E9CE5528DF8CA1890DBFE6426841992D;
    bb_data_sys = 30'd0;
    // BKN1 (120 dibits) — AES S-box bytes 0..29 for pseudo-random timing stimulus
    // (cycling 0x1B creates period-4 IQ that has 4 stable TED zeros; loop picks wrong one)
    bkn1_sb_data_sys = 240'h637C777BF26B6FC53001672BFED7AB76CA82C97DFA5947F0ADD4A2AF9CA4;
    bb_sb_data_sys = 28'd0;
    burst_type_sys = 2'b01;
    build_req_sys = 1'b0;
    idle_request_armed = 1'b1;
    bursts_sent = 0;
    sync_found_count = 0;
    dibit_count_dbg = 0;
    tr_count_dbg = 0;
    fe_dbg_count = 0;
    nco_dbg_count = 0;
    tx_cic_dbg_count = 0;
    rrc_dbg_count = 0;

    repeat (20) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    rst_n_lvds = 1'b1;

    timeout_cycles = 0;
    while (!sync_locked && timeout_cycles < 5000000) begin
        @(posedge clk_sys);
        timeout_cycles = timeout_cycles + 1;
    end

    if (!sync_locked) begin
        $display("FAIL: full-loop sync_locked never asserted, sync_found_count=%0d fe_valid_count=%0d tr_valid_count=%0d demod_valid_count=%0d timing_locked=%0b",
                 sync_found_count, fe_valid_count, tr_valid_count, demod_valid_count, timing_locked_sys);
        $fatal(1);
    end

    $display("PASS: full-loop sync_locked asserted after %0d cycles, sync_found_count=%0d",
             timeout_cycles, sync_found_count);
    $finish;
end

endmodule

`default_nettype wire
