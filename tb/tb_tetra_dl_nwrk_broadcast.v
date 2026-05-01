// =============================================================================
// Testbench: tb_tetra_dl_nwrk_broadcast
//
// Verifies the periodic-push module:
//   - On rising edge of trigger_sys, fires wr_cmce_valid_sys for exactly 1
//     clk_sys cycle.
//   - Drives the 432-bit coded bus through unchanged from payload_sys.
//   - Sets pdu_type = 2'd0 (SCH/F) and target_tn = cfg_mcch_tn_sys.
//   - Increments push_cnt_sys exactly once per rising edge.
//   - Multiple back-to-back rising edges → multiple pulses + counter increments.
//
// Compile + run:
//   iverilog -g2001 -o /tmp/tb_nwrk tb/tb_tetra_dl_nwrk_broadcast.v \
//       rtl/lmac/tetra_dl_nwrk_broadcast.v
//   vvp /tmp/tb_nwrk
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_dl_nwrk_broadcast;

reg          clk_sys;
reg          rst_n_sys;
reg  [431:0] payload_sys;
reg          trigger_sys;
reg  [1:0]   cfg_mcch_tn_sys;
wire         wr_cmce_valid_sys;
wire [431:0] wr_cmce_coded_sys;
wire [1:0]   wr_cmce_pdu_type_sys;
wire [1:0]   wr_cmce_target_tn_sys;
wire [15:0]  push_cnt_sys;

tetra_dl_nwrk_broadcast u_dut (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .payload_sys          (payload_sys),
    .trigger_sys          (trigger_sys),
    .cfg_mcch_tn_sys      (cfg_mcch_tn_sys),
    .wr_cmce_valid_sys    (wr_cmce_valid_sys),
    .wr_cmce_coded_sys    (wr_cmce_coded_sys),
    .wr_cmce_pdu_type_sys (wr_cmce_pdu_type_sys),
    .wr_cmce_target_tn_sys(wr_cmce_target_tn_sys),
    .push_cnt_sys         (push_cnt_sys)
);

always #5 clk_sys = ~clk_sys;

integer pass_cnt = 0;
integer fail_cnt = 0;

task check_eq;
    input [255:0] label;
    input [31:0]  expected;
    input [31:0]  got;
    begin
        if (expected === got) begin
            $display("PASS %0s: 0x%08x", label, got);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL %0s: got 0x%08x  expected 0x%08x", label, got, expected);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

initial begin
    $dumpfile("sim_out/tb_tetra_dl_nwrk_broadcast.vcd");
    $dumpvars(0, tb_tetra_dl_nwrk_broadcast);

    clk_sys         = 1'b0;
    rst_n_sys       = 1'b0;
    payload_sys     = 432'd0;
    trigger_sys     = 1'b0;
    cfg_mcch_tn_sys = 2'd0;

    repeat (5) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (3) @(posedge clk_sys);

    // ----- TC1: rising edge → exactly 1 pulse, counter=1 -----
    // Bit-Layout: payload_sys = {high32, ..., low32} → coded[431:400] = high32
    // Timing: register-output of pulse erscheint NACH dem zweiten posedge nach
    // trigger=1 (1 cycle für trigger_sys_q sample, 1 cycle für wr_cmce_valid
    // register-output sichtbar).  Test liest direkt nach `@(posedge)` →
    // sees post-edge values.
    $display("=== TC1: single rising edge ===");
    payload_sys     = {16'hCAFE, {416{1'b0}}};
    cfg_mcch_tn_sys = 2'd0;
    @(posedge clk_sys);
    trigger_sys = 1'b1;
    // Wait for register output to update.  Edge after trigger=1: pulse=1
    // appears in register output.
    @(posedge clk_sys);
    if (wr_cmce_valid_sys !== 1'b1) begin
        $display("FAIL TC1.valid: got %b expected 1", wr_cmce_valid_sys);
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC1.valid: 1");
        pass_cnt = pass_cnt + 1;
    end
    check_eq("TC1.coded[431:416]", 32'h0000CAFE, {16'b0, wr_cmce_coded_sys[431:416]});
    check_eq("TC1.pdu_type",      32'd0,         {30'b0, wr_cmce_pdu_type_sys});
    check_eq("TC1.target_tn",     32'd0,         {30'b0, wr_cmce_target_tn_sys});
    @(posedge clk_sys);  // next edge: trigger_sys_q=1 → pulse=0 (one-shot)
    if (wr_cmce_valid_sys !== 1'b0) begin
        $display("FAIL TC1.deassert: got %b expected 0", wr_cmce_valid_sys);
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC1.deassert");
        pass_cnt = pass_cnt + 1;
    end
    check_eq("TC1.cnt", 32'd1, {16'b0, push_cnt_sys});

    // Trigger stays high — no further pulses (one-shot semantics)
    repeat (5) @(posedge clk_sys);
    check_eq("TC1.cnt_no_re_arm", 32'd1, {16'b0, push_cnt_sys});

    // ----- TC2: trigger goes 1→0→1, second pulse fires -----
    $display("=== TC2: re-trigger after low ===");
    @(posedge clk_sys);
    trigger_sys = 1'b0;
    @(posedge clk_sys);
    @(posedge clk_sys);
    payload_sys = {16'hBEEF, {416{1'b0}}};
    cfg_mcch_tn_sys = 2'd1;
    trigger_sys = 1'b1;
    @(posedge clk_sys);
    if (wr_cmce_valid_sys !== 1'b1) begin
        $display("FAIL TC2.valid: got %b expected 1", wr_cmce_valid_sys);
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("PASS TC2.valid: 1");
        pass_cnt = pass_cnt + 1;
    end
    check_eq("TC2.coded[431:416]", 32'h0000BEEF, {16'b0, wr_cmce_coded_sys[431:416]});
    check_eq("TC2.target_tn",      32'd1,         {30'b0, wr_cmce_target_tn_sys});
    @(posedge clk_sys);
    check_eq("TC2.cnt", 32'd2, {16'b0, push_cnt_sys});

    // ----- TC3: payload pass-through full 432 bits -----
    // 432 bit = 13 × 32 bit + 1 × 16 bit.  Top word of 432-bit bus = 16 bit.
    $display("=== TC3: full 432-bit pass-through ===");
    @(posedge clk_sys);
    trigger_sys = 1'b0;
    @(posedge clk_sys);
    @(posedge clk_sys);
    payload_sys = {16'hDEAD,
                   32'h12345678, 32'hAAAA5555, 32'h0F0F0F0F,
                   32'hFFFFFFFF, 32'h00000000, 32'hCCCCCCCC, 32'h33333333,
                   32'hA5A5A5A5, 32'h5A5A5A5A, 32'h11223344, 32'h55667788,
                   32'h99AABBCC, 32'hDDEEFF00};
    trigger_sys = 1'b1;
    @(posedge clk_sys);
    check_eq("TC3.coded[431:416]_top16", 32'h0000DEAD, {16'b0, wr_cmce_coded_sys[431:416]});
    check_eq("TC3.coded[415:384]_word2", 32'h12345678, wr_cmce_coded_sys[415:384]);
    check_eq("TC3.coded[ 31:  0]_low",   32'hDDEEFF00, wr_cmce_coded_sys[ 31:  0]);

    // ----- Summary -----
    $display("=============================================");
    if (fail_cnt == 0) begin
        $display("tb_tetra_dl_nwrk_broadcast: ALL %0d TCs PASS", pass_cnt);
        $display("RESULT: PASS");
    end else begin
        $display("tb_tetra_dl_nwrk_broadcast: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        $display("RESULT: FAIL");
    end
    $display("=============================================");
    $finish;
end

initial begin
    #100000;
    $display("TIMEOUT");
    $finish;
end

endmodule

`default_nettype wire
