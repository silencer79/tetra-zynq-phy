// =============================================================================
// Testbench: tb_tetra_aach_encoder
//
// Verifies rtl/tx/tetra_aach_encoder.v against 4 bit-exact reference vectors
// computed by scripts/gen_aach_reference.py (which mirrors sw/tetra_hal.c's
// build_aach_capaloc + build_aach + aach_scramble + RM(30,14)).
//
// Reference vectors (from scripts/gen_aach_reference.py 2026-04-21):
//   TC1 F1  cc=9  mcc=901  mnc=9998 → 0x09857ABF
//   TC2 F18 cc=9  mcc=901  mnc=9998 → 0x39C533E0
//   TC3 F1  cc=36 mcc=262  mnc=106  → 0x3781E09B
//   TC4 F18 cc=36 mcc=262  mnc=106  → 0x07C1A9C4
//
// Compile + run:
//   iverilog -g2001 -o /tmp/tb_aach tb/tb_tetra_aach_encoder.v \
//       rtl/tx/tetra_aach_encoder.v
//   vvp /tmp/tb_aach
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_aach_encoder;

reg         clk_sys;
reg         rst_n_sys;
reg  [4:0]  fn_sys;
reg  [1:0]  tn_sys;
reg  [5:0]  cc_sys;
reg  [9:0]  mcc_sys;
reg  [13:0] mnc_sys;
reg         encode_start_sys;
wire [29:0] aach_coded_sys;
wire        aach_valid_sys;

tetra_aach_encoder u_dut (
    .clk_sys          (clk_sys),
    .rst_n_sys        (rst_n_sys),
    .fn_sys           (fn_sys),
    .tn_sys           (tn_sys),
    .colour_code_sys  (cc_sys),
    .mcc_sys          (mcc_sys),
    .mnc_sys          (mnc_sys),
    .encode_start_sys (encode_start_sys),
    .aach_coded_sys   (aach_coded_sys),
    .aach_valid_sys   (aach_valid_sys)
);

// 100 MHz
always #5 clk_sys = ~clk_sys;

integer pass_cnt;
integer fail_cnt;

task check;
    input [127:0] label;        // 16-byte ASCII label
    input [29:0]  expected;
    begin
        if (aach_coded_sys == expected) begin
            $display("PASS %0s: got 0x%08x (matches expected)",
                     label, aach_coded_sys);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL %0s: got 0x%08x  expected 0x%08x",
                     label, aach_coded_sys, expected);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

task run_encode;
    input [4:0]  fn_val;
    input [1:0]  tn_val;
    input [5:0]  cc_val;
    input [9:0]  mcc_val;
    input [13:0] mnc_val;
    begin
        @(posedge clk_sys);
        fn_sys           <= fn_val;
        tn_sys           <= tn_val;
        cc_sys           <= cc_val;
        mcc_sys          <= mcc_val;
        mnc_sys          <= mnc_val;
        encode_start_sys <= 1'b1;
        @(posedge clk_sys);
        encode_start_sys <= 1'b0;
        // Wait for aach_valid edge (rising) in case it was already high
        // from a prior run — we actually want to wait until valid pulses
        // into its S_DONE state. Simplest: wait 50 cycles (encoder is ~33).
        repeat (50) @(posedge clk_sys);
    end
endtask

initial begin
    $dumpfile("sim_out/tb_tetra_aach_encoder.vcd");
    $dumpvars(0, tb_tetra_aach_encoder);

    clk_sys          = 1'b0;
    rst_n_sys        = 1'b0;
    fn_sys           = 5'd0;
    tn_sys           = 2'd0;
    cc_sys           = 6'd0;
    mcc_sys          = 10'd0;
    mnc_sys          = 14'd0;
    encode_start_sys = 1'b0;
    pass_cnt         = 0;
    fail_cnt         = 0;

    // Reset
    repeat (5) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (3) @(posedge clk_sys);

    // TN=2 (SB slot) reproduces the legacy CapAlloc/FN18 info words
    // that gen_aach_reference.py originally computed.
    $display("=== TC1 F1  TN=2 cc=9  mcc=901  mnc=9998  expect 0x09857ABF ===");
    run_encode(5'd0, 2'd2, 6'd9, 10'd901, 14'd9998);
    check("TC1", 30'h09857ABF);

    $display("=== TC2 F18 TN=2 cc=9  mcc=901  mnc=9998  expect 0x39C533E0 ===");
    run_encode(5'd17, 2'd2, 6'd9, 10'd901, 14'd9998);
    check("TC2", 30'h39C533E0);

    $display("=== TC3 F1  TN=2 cc=36 mcc=262  mnc=106   expect 0x3781E09B ===");
    run_encode(5'd0, 2'd2, 6'd36, 10'd262, 14'd106);
    check("TC3", 30'h3781E09B);

    $display("=== TC4 F18 TN=2 cc=36 mcc=262  mnc=106   expect 0x07C1A9C4 ===");
    run_encode(5'd17, 2'd2, 6'd36, 10'd262, 14'd106);
    check("TC4", 30'h07C1A9C4);

    // TN=0: DL/UL-Assign DL=Common(1) UL=Random(1) CC=9 → info=0x0249
    // (MCCH/NDB2 slot — MS random access permitted)
    $display("=== TC5 F1  TN=0 cc=9  mcc=901  mnc=9998  expect 0x3BCC8E90 ===");
    run_encode(5'd0, 2'd0, 6'd9, 10'd901, 14'd9998);
    check("TC5", 30'h3BCC8E90);

    $display("=== TC6 F1  TN=0 cc=36 mcc=262  mnc=106   expect 0x05C814B4 ===");
    run_encode(5'd0, 2'd0, 6'd36, 10'd262, 14'd106);
    check("TC6", 30'h05C814B4);

    $display("=============================================");
    if (fail_cnt == 0) begin
        $display("tb_tetra_aach_encoder: ALL %0d TCs PASS", pass_cnt);
        $display("RESULT: PASS");
    end else begin
        $display("tb_tetra_aach_encoder: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        $display("RESULT: FAIL");
    end
    $display("=============================================");
    $finish;
end

// Safety timeout
initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
end

endmodule

`default_nettype wire
