// =============================================================================
// tb_tetra_crc16.v — Self-Checking Testbench for tetra_crc16
// =============================================================================
//
// Tests: CRC-16-CCITT generator and checker (ETSI EN 300 392-2 §8.2.6)
//   Poly=0x1021, Init=0xFFFF, no final XOR, MSB-first
//
// Strategy:
//   A software reference model (ref_crc16 function) runs inside the testbench
//   and computes expected values independently. The DUT output is compared
//   against this reference — pure simulation, no external .hex required.
//
// Separately, TC1 uses the canonical CRC-16/CCITT-FALSE check value 0x29B1
// for "123456789" as a hard-coded ground truth sanity check.
//
// Test cases (10 total):
//   TC0  Empty message (0 bits)       — DUT stays at init=0xFFFF
//   TC1  "123456789" (72 bits)        — canonical check value 0x29B1
//   TC2  0x0000 (16 bits)             — reference model vs. DUT
//   TC3  0xFFFF (16 bits)             — reference model vs. DUT
//   TC4  216 all-zero bits (NDB)      — reference model vs. DUT
//   TC5  216 alternating bits (NDB)   — reference model vs. DUT
//   TC6  Single bit 1                 — reference: known result 0xFFFE
//   TC7  0xABCD (16 bits)             — reference model vs. DUT
//   TC8  RX path: data+"123456789"+FCS 0x29B1 → crc_ok=1
//   TC9  RX path with bit error       → crc_ok=0
//
// Simulation: Vivado xsim (run via scripts/vivado_sim.tcl tetra_crc16)
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_tetra_crc16;

// ---------------------------------------------------------------------------
// DUT ports
// ---------------------------------------------------------------------------
reg        clk_sys;
reg        rst_n_sys;
reg        init_sys;
reg        done_in_sys;
reg        data_in_sys;
reg        data_valid_sys;

wire [15:0] crc_out_sys;
wire        crc_valid_sys;
wire        crc_ok_sys;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_crc16 u_dut (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .init_sys       (init_sys),
    .done_in_sys    (done_in_sys),
    .data_in_sys    (data_in_sys),
    .data_valid_sys (data_valid_sys),
    .crc_out_sys    (crc_out_sys),
    .crc_valid_sys  (crc_valid_sys),
    .crc_ok_sys     (crc_ok_sys)
);

// ---------------------------------------------------------------------------
// Clock: 100 MHz (10 ns period)
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_crc16.vcd");
    $dumpvars(0, tb_tetra_crc16);
end

// ---------------------------------------------------------------------------
// Pass/fail counters
// ---------------------------------------------------------------------------
integer pass_cnt;
integer fail_cnt;

// ---------------------------------------------------------------------------
// CRC-16-CCITT reference model (pure combinatorial, runs in initial block)
//   Processes bits[width-1:0] from MSB (bit[width-1]) down to LSB (bit[0]).
//   Returns the 16-bit CRC.
// ---------------------------------------------------------------------------
function [15:0] ref_crc16;
    input [255:0] data;
    input integer width;
    integer i;
    reg [15:0] crc;
    reg        fb;
    begin
        crc = 16'hFFFF;
        for (i = width - 1; i >= 0; i = i - 1) begin
            fb  = data[i] ^ crc[15];
            crc = {crc[14:0], 1'b0} ^ ({16{fb}} & 16'h1021);
        end
        ref_crc16 = crc;
    end
endfunction

// ---------------------------------------------------------------------------
// Task: assert init_sys (1-cycle pulse)
// ---------------------------------------------------------------------------
task crc_init;
    begin
        @(negedge clk_sys);
        init_sys <= 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        init_sys <= 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Task: feed one bit into the CRC
// ---------------------------------------------------------------------------
task feed_bit;
    input bit_val;
    begin
        @(negedge clk_sys);
        data_in_sys    <= bit_val;
        data_valid_sys <= 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        data_valid_sys <= 1'b0;
        data_in_sys    <= 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Task: feed last bit and assert done_in simultaneously (on same clock edge),
//       then wait 1 cycle for crc_valid to appear.
// ---------------------------------------------------------------------------
task feed_last_and_done;
    input bit_val;
    begin
        @(negedge clk_sys);
        data_in_sys    <= bit_val;
        data_valid_sys <= 1'b1;
        done_in_sys    <= 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        data_valid_sys <= 1'b0;
        data_in_sys    <= 1'b0;
        done_in_sys    <= 1'b0;
        // crc_valid_sys appears 1 cycle after done_in posedge
        @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Task: assert done_in without a concurrent data bit
// ---------------------------------------------------------------------------
task assert_done;
    begin
        @(negedge clk_sys);
        done_in_sys <= 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        done_in_sys <= 1'b0;
        @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Task: check FCS output — expects crc_valid_sys == 1 and crc_out == expected
// ---------------------------------------------------------------------------
task check_fcs;
    input [15:0] expected;
    input integer tc_num;
    begin
        if (!crc_valid_sys) begin
            $display("  TC%0d FAIL: crc_valid not asserted", tc_num);
            $error("TC%0d: crc_valid missing", tc_num);
            fail_cnt = fail_cnt + 1;
        end else if (crc_out_sys !== expected) begin
            $display("  TC%0d FAIL: crc_out=0x%04X  expected=0x%04X",
                     tc_num, crc_out_sys, expected);
            $error("TC%0d: FCS mismatch", tc_num);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  TC%0d PASS: FCS=0x%04X", tc_num, crc_out_sys);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Task: check crc_ok output (RX residue check)
// ---------------------------------------------------------------------------
task check_crc_ok;
    input exp_ok;
    input integer tc_num;
    begin
        if (!crc_valid_sys) begin
            $display("  TC%0d FAIL: crc_valid not asserted", tc_num);
            $error("TC%0d: crc_valid missing", tc_num);
            fail_cnt = fail_cnt + 1;
        end else if (crc_ok_sys !== exp_ok) begin
            $display("  TC%0d FAIL: crc_ok=%0b  expected=%0b",
                     tc_num, crc_ok_sys, exp_ok);
            $error("TC%0d: crc_ok mismatch", tc_num);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  TC%0d PASS: crc_ok=%0b (%s)",
                     tc_num, crc_ok_sys,
                     exp_ok ? "no error" : "error detected");
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Known-good constants
// ---------------------------------------------------------------------------

// "123456789" packed MSB-first into 72 bits [71:0]
// 0x31=49, 0x32=50, ... 0x39=57
localparam [71:0] STR_123456789 = {
    8'h31, 8'h32, 8'h33, 8'h34,
    8'h35, 8'h36, 8'h37, 8'h38, 8'h39
};

// CRC residue for error-free RX path
localparam [15:0] CRC_RESIDUE = 16'h1D0F;

// Computed CRC of "123456789" (canonical CRC-16/CCITT-FALSE check value)
localparam [15:0] CANON_CRC = 16'h29B1;

// ---------------------------------------------------------------------------
// Main test sequence
// ---------------------------------------------------------------------------
integer bit_idx;
reg [15:0] exp_fcs;
reg [215:0] alt216;

initial begin
    pass_cnt = 0;
    fail_cnt = 0;

    rst_n_sys      = 1'b0;
    init_sys       = 1'b0;
    done_in_sys    = 1'b0;
    data_in_sys    = 1'b0;
    data_valid_sys = 1'b0;

    // Build 216-bit alternating pattern: bit[i] = i%2
    // (bit[215]=1, bit[214]=0, bit[213]=1, ...)
    for (bit_idx = 0; bit_idx < 216; bit_idx = bit_idx + 1)
        alt216[bit_idx] = bit_idx[0];

    repeat(4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1'b1;
    @(posedge clk_sys);

    $display("");
    $display("=== tb_tetra_crc16 ===");
    $display("    CRC-16-CCITT  Poly=0x1021  Init=0xFFFF  MSB-first");
    $display("    Ref: ETSI EN 300 392-2 Section 8.2.6");
    $display("");

    // -----------------------------------------------------------------------
    // TC0: Empty message — CRC must stay at 0xFFFF after init + done
    // -----------------------------------------------------------------------
    $display("--- TC0: Empty message (0 bits) ---");
    crc_init;
    assert_done;
    // After assert_done: crc_valid_sys is HIGH, crc_out = 0xFFFF
    // crc_ok should be 0 (0xFFFF != 0x1D0F)
    check_fcs(16'hFFFF, 0);
    if (crc_ok_sys !== 1'b0) begin
        $display("  TC0 FAIL: crc_ok should be 0 for empty message");
        $error("TC0: crc_ok false positive");
        fail_cnt = fail_cnt + 1;
    end else begin
        $display("  TC0 PASS: crc_ok=0 (correct)");
        pass_cnt = pass_cnt + 1;
    end
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC1: "123456789" — must yield canonical CRC-16/CCITT-FALSE = 0x29B1
    // -----------------------------------------------------------------------
    $display("--- TC1: '123456789' (72 bits) canonical check ---");
    crc_init;
    for (bit_idx = 71; bit_idx >= 1; bit_idx = bit_idx - 1)
        feed_bit(STR_123456789[bit_idx]);
    feed_last_and_done(STR_123456789[0]);
    check_fcs(CANON_CRC, 1);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC2: 0x0000 as 16-bit message — DUT vs. reference model
    // -----------------------------------------------------------------------
    $display("--- TC2: 0x0000 (16 bits) ---");
    exp_fcs = ref_crc16(256'h0000, 16);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    for (bit_idx = 14; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(1'b0);
    feed_last_and_done(1'b0);
    check_fcs(exp_fcs, 2);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC3: 0xFFFF as 16-bit message — DUT vs. reference model
    // -----------------------------------------------------------------------
    $display("--- TC3: 0xFFFF (16 bits) ---");
    exp_fcs = ref_crc16(256'hFFFF, 16);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    for (bit_idx = 14; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(1'b1);
    feed_last_and_done(1'b1);
    check_fcs(exp_fcs, 3);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC4: 216 all-zero bits (NDB block) — DUT vs. reference model
    // -----------------------------------------------------------------------
    $display("--- TC4: 216 zero bits (NDB block) ---");
    exp_fcs = ref_crc16(256'h0, 216);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    for (bit_idx = 214; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(1'b0);
    feed_last_and_done(1'b0);
    check_fcs(exp_fcs, 4);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC5: 216 alternating bits (NDB block) — DUT vs. reference model
    //      alt216 is 216 bits wide; bit[215]=MSB (first to transmit)
    // -----------------------------------------------------------------------
    $display("--- TC5: 216-bit alternating (NDB block) ---");
    // ref_crc16 operates on bits [width-1:0]; we pass alt216 as 256-bit value
    // with the 216 valid bits in [215:0]
    exp_fcs = ref_crc16({40'h0, alt216}, 216);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    for (bit_idx = 215; bit_idx >= 1; bit_idx = bit_idx - 1)
        feed_bit(alt216[bit_idx]);
    feed_last_and_done(alt216[0]);
    check_fcs(exp_fcs, 5);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC6: Single bit = 1
    //   init=0xFFFF, bit=1: fb=1^1=0, crc_next=0xFFFE^0=0xFFFE
    // -----------------------------------------------------------------------
    $display("--- TC6: Single bit 1 ---");
    exp_fcs = ref_crc16(256'h1, 1);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    feed_last_and_done(1'b1);
    check_fcs(exp_fcs, 6);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC7: 0xABCD as 16-bit message — DUT vs. reference model
    // -----------------------------------------------------------------------
    $display("--- TC7: 0xABCD (16 bits) ---");
    exp_fcs = ref_crc16(256'hABCD, 16);
    $display("  reference FCS = 0x%04X", exp_fcs);
    crc_init;
    for (bit_idx = 14; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(16'hABCD >> (bit_idx + 1) & 1'b1);
    feed_last_and_done(1'b1);  // LSB of 0xABCD = 1
    check_fcs(exp_fcs, 7);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC8: RX residue check — "123456789" + FCS 0x29B1 → crc_ok must be 1
    //   Total 88 bits: 72 data + 16 FCS (MSB-first)
    // -----------------------------------------------------------------------
    $display("--- TC8: RX residue — '123456789' + FCS 0x29B1 ---");
    crc_init;
    // Feed 72 data bits
    for (bit_idx = 71; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(STR_123456789[bit_idx]);
    // Feed 16 FCS bits MSB-first
    for (bit_idx = 14; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(CANON_CRC >> (bit_idx + 1) & 1'b1);
    feed_last_and_done(CANON_CRC & 1'b1);  // LSB of FCS
    check_crc_ok(1'b1, 8);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC9: RX with deliberate bit error — FCS 0x29B1 → flip bit 3 → 0x29B9
    //   crc_ok must be 0
    // -----------------------------------------------------------------------
    $display("--- TC9: RX error detect — FCS bit 3 flipped (0x29B9) ---");
    crc_init;
    for (bit_idx = 71; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(STR_123456789[bit_idx]);
    for (bit_idx = 14; bit_idx >= 0; bit_idx = bit_idx - 1)
        feed_bit(16'h29B9 >> (bit_idx + 1) & 1'b1);
    feed_last_and_done(16'h29B9 & 1'b1);
    check_crc_ok(1'b0, 9);
    @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    $display("");
    $display("=== RESULTS: %0d PASS  %0d FAIL ===",
             pass_cnt, fail_cnt);
    if (fail_cnt == 0)
        $display("    STATUS: ALL TESTS PASSED");
    else
        $display("    STATUS: *** FAILURES DETECTED ***");
    $display("");

    #50;
    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #10_000_000;
    $display("TIMEOUT: simulation exceeded 10 ms");
    $fatal(1, "Watchdog timeout");
end

endmodule

`default_nettype wire
