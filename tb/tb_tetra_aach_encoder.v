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
reg  [1:0]  mn_low2_sys;
reg  [5:0]  cc_sys;
reg  [9:0]  mcc_sys;
reg  [13:0] mnc_sys;
reg         signalling_active_sys;
reg         grant_pending_sys;
reg  [13:0] grant_info_sys;
wire        grant_consume_sys;
reg         encode_start_sys;
wire [29:0] aach_coded_sys;
wire        aach_valid_sys;

tetra_aach_encoder u_dut (
    .clk_sys               (clk_sys),
    .rst_n_sys             (rst_n_sys),
    .fn_sys                (fn_sys),
    .tn_sys                (tn_sys),
    .mn_low2_sys           (mn_low2_sys),
    .colour_code_sys       (cc_sys),
    .mcc_sys               (mcc_sys),
    .mnc_sys               (mnc_sys),
    .signalling_active_sys (signalling_active_sys),
    .grant_pending_sys     (grant_pending_sys),
    .grant_info_sys        (grant_info_sys),
    .grant_consume_sys     (grant_consume_sys),
    .encode_start_sys      (encode_start_sys),
    .aach_coded_sys        (aach_coded_sys),
    .aach_valid_sys        (aach_valid_sys)
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
    input [1:0]  mn_low2_val;
    input [5:0]  cc_val;
    input [9:0]  mcc_val;
    input [13:0] mnc_val;
    begin
        @(posedge clk_sys);
        fn_sys           <= fn_val;
        tn_sys           <= tn_val;
        mn_low2_sys      <= mn_low2_val;
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

    clk_sys               = 1'b0;
    rst_n_sys             = 1'b0;
    fn_sys                = 5'd0;
    tn_sys                = 2'd0;
    mn_low2_sys           = 2'd0;
    cc_sys                = 6'd0;
    mcc_sys               = 10'd0;
    mnc_sys               = 14'd0;
    signalling_active_sys = 1'b0;
    grant_pending_sys     = 1'b0;
    grant_info_sys        = 14'd0;
    encode_start_sys      = 1'b0;
    pass_cnt              = 0;
    fail_cnt              = 0;

    // Reset
    repeat (5) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (3) @(posedge clk_sys);

    // TC1-TC4 reproduce the legacy CapAlloc(F1)/DLUL-Assign(F18) reference
    // vectors from scripts/gen_aach_reference.py (info=0x3000 / 0x0040).
    $display("=== TC1 F1  TN=2 cc=9  mcc=901  mnc=9998  expect 0x09857ABF ===");
    run_encode(5'd0, 2'd2, 2'd0, 6'd9, 10'd901, 14'd9998);
    check("TC1", 30'h09857ABF);

    $display("=== TC2 F18 TN=2 cc=9  mcc=901  mnc=9998  expect 0x39C533E0 ===");
    run_encode(5'd17, 2'd2, 2'd0, 6'd9, 10'd901, 14'd9998);
    check("TC2", 30'h39C533E0);

    $display("=== TC3 F1  TN=2 cc=36 mcc=262  mnc=106   expect 0x3781E09B ===");
    run_encode(5'd0, 2'd2, 2'd0, 6'd36, 10'd262, 14'd106);
    check("TC3", 30'h3781E09B);

    $display("=== TC4 F18 TN=2 cc=36 mcc=262  mnc=106   expect 0x07C1A9C4 ===");
    run_encode(5'd17, 2'd2, 2'd0, 6'd36, 10'd262, 14'd106);
    check("TC4", 30'h07C1A9C4);

    // TC5/TC6: F1-17 TN=0 idle (NDB2 MCCH) → info=0x0249 (Common/Random)
    $display("=== TC5 F1  TN=0 cc=9  mcc=901  mnc=9998  expect 0x3BCC8E90 ===");
    run_encode(5'd0, 2'd0, 2'd0, 6'd9, 10'd901, 14'd9998);
    check("TC5", 30'h3BCC8E90);

    $display("=== TC6 F1  TN=0 cc=36 mcc=262  mnc=106   expect 0x05C814B4 ===");
    run_encode(5'd0, 2'd0, 2'd0, 6'd36, 10'd262, 14'd106);
    check("TC6", 30'h05C814B4);

    // ------------------------------------------------------------------
    // Gold-Cell F18 MN%4-Rotation Tests (Gold-bit-genau verifiziert in
    // docs/references/captures_external_bs_2026-04-25/decode_dl_full.log)
    //
    // F18 TN=0 MN%4=2 → BSCH-Anker mit info=0x0049 (Unalloc/Random CC=9)
    // F18 TN=0 MN%4∈{0,1,3} → NDB2 BNCH mit info=0x0249 (Common/Random)
    // F18 TN!=0 → SB Pilot mit info=0x0040 (Unalloc/Random CC=0)
    // F18 TN=0 BSCH-Anker only on MN%4=2
    // ------------------------------------------------------------------
    $display("=== TC7 F18 TN=0 MN%%4=2 BSCH-Anker → info14=0x0049 ===");
    run_encode(5'd17, 2'd0, 2'd2, 6'd9, 10'd901, 14'd9998);
    if (u_dut.info_sys == 14'h0049) begin
        $display("PASS TC7: info14=0x%04x (BSCH-Anker)", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC7: info14=0x%04x  expected 0x0049", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

    $display("=== TC8 F18 TN=0 MN%%4=0 NDB2 BNCH → info14=0x0249 ===");
    run_encode(5'd17, 2'd0, 2'd0, 6'd9, 10'd901, 14'd9998);
    if (u_dut.info_sys == 14'h0249) begin
        $display("PASS TC8: info14=0x%04x (NDB2 BNCH)", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC8: info14=0x%04x  expected 0x0249", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

    $display("=== TC9 F18 TN=0 MN%%4=1 NDB2 BNCH → info14=0x0249 ===");
    run_encode(5'd17, 2'd0, 2'd1, 6'd9, 10'd901, 14'd9998);
    if (u_dut.info_sys == 14'h0249) begin
        $display("PASS TC9: info14=0x%04x", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC9: info14=0x%04x  expected 0x0249", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

    $display("=== TC10 F18 TN=0 MN%%4=3 NDB2 BNCH → info14=0x0249 ===");
    run_encode(5'd17, 2'd0, 2'd3, 6'd9, 10'd901, 14'd9998);
    if (u_dut.info_sys == 14'h0249) begin
        $display("PASS TC10: info14=0x%04x", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC10: info14=0x%04x  expected 0x0249", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

    // TC11: F18 TN!=0 must have info14=0x0040 (Gold), not 0x0049 (alter Bug)
    $display("=== TC11 F18 TN=2 → info14=0x0040 (Gold, NICHT 0x0049!) ===");
    run_encode(5'd17, 2'd2, 2'd0, 6'd9, 10'd901, 14'd9998);
    if (u_dut.info_sys == 14'h0040) begin
        $display("PASS TC11: info14=0x%04x", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC11: info14=0x%04x  expected 0x0040", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

    // TC12: TN=0 signalling-active (DL-Reply läuft) → info=0x0009
    $display("=== TC12 F1 TN=0 signalling_active=1 → info14=0x0009 ===");
    @(posedge clk_sys);
    signalling_active_sys = 1'b1;
    run_encode(5'd0, 2'd0, 2'd0, 6'd9, 10'd901, 14'd9998);
    signalling_active_sys = 1'b0;
    if (u_dut.info_sys == 14'h0009) begin
        $display("PASS TC12: info14=0x%04x", u_dut.info_sys);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("FAIL TC12: info14=0x%04x  expected 0x0009", u_dut.info_sys);
        fail_cnt = fail_cnt + 1;
    end

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
