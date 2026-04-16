`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_builder_sync;

localparam CLK_HALF = 5;
localparam integer BURSTS_TO_SEND = 4;

reg clk_sys;
reg rst_n_sys;

reg  [215:0] block1_data_sys;
reg  [215:0] block2_data_sys;
reg  [29:0]  bb_data_sys;
reg  [119:0] sb1_data_sys;
reg          burst_type_sys;
reg          build_req_sys;

wire [1:0] tx_dibit_sys;
wire       tx_dibit_valid_sys;
wire       tx_done_sys;
wire       tx_busy_sys;

wire       sync_found;
wire       sync_locked;
wire [7:0] slot_position;
wire [1:0] slot_number;

integer bursts_sent;
integer sync_found_count;
integer timeout_cycles;
reg     idle_request_armed;

initial clk_sys = 1'b0;
always #CLK_HALF clk_sys = ~clk_sys;

tetra_burst_builder #(
    .BLOCK_BITS   (216),
    .BB_BITS      (30),
    .SB1_BITS     (120),
    .SYM_DIV      (13'd0)
) dut_builder (
    .clk_sys            (clk_sys),
    .rst_n_sys          (rst_n_sys),
    .block1_data_sys    (block1_data_sys),
    .block2_data_sys    (block2_data_sys),
    .bb_data_sys        (bb_data_sys),
    .sb1_data_sys       (sb1_data_sys),
    .burst_type_sys     (burst_type_sys),
    .build_req_sys      (build_req_sys),
    .tx_dibit_sys       (tx_dibit_sys),
    .tx_dibit_valid_sys (tx_dibit_valid_sys),
    .tx_done_sys        (tx_done_sys),
    .tx_busy_sys        (tx_busy_sys)
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
    .dibit_in       (tx_dibit_sys),
    .dibit_valid    (tx_dibit_valid_sys),
    .corr_threshold (6'd15),
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
        $display("sync_found at cycle=%0t slot_pos=%0d slot_num=%0d count=%0d",
                 $time, slot_position, slot_number, sync_found_count + 1);
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
            $display("build_req for burst=%0d at time=%0t", bursts_sent + 1, $time);
        end
    end
end

always @(posedge clk_sys) begin
    if (rst_n_sys && tx_done_sys)
        $display("tx_done at time=%0t", $time);
end

initial begin
    $dumpfile("tb_tetra_builder_sync.vcd");
    $dumpvars(0, tb_tetra_builder_sync);

    rst_n_sys = 1'b0;
    block1_data_sys = 216'd0;
    block2_data_sys = 216'd0;
    bb_data_sys = 30'd0;
    sb1_data_sys = 120'd0;
    burst_type_sys = 1'b1;
    build_req_sys = 1'b0;
    bursts_sent = 0;
    sync_found_count = 0;
    idle_request_armed = 1'b1;

    repeat (10) @(posedge clk_sys);
    rst_n_sys = 1'b1;

    timeout_cycles = 0;
    while (!sync_locked && timeout_cycles < 5000) begin
        @(posedge clk_sys);
        timeout_cycles = timeout_cycles + 1;
    end

    if (!sync_locked) begin
        $display("FAIL: sync_locked never asserted, sync_found_count=%0d", sync_found_count);
        $fatal(1);
    end

    if (sync_found_count < 4) begin
        $display("FAIL: expected at least 4 sync_found pulses, got %0d", sync_found_count);
        $fatal(1);
    end

    $display("PASS: sync_locked asserted after %0d cycles, sync_found_count=%0d, slot_number=%0d",
             timeout_cycles, sync_found_count, slot_number);
    $finish;
end

endmodule

`default_nettype wire
