// =============================================================================
// tb_tetra_reed_muller.v — Self-Checking Testbench
// =============================================================================
//
// Tests tetra_reed_muller.v: (30,14) Reed-Muller codec for AACH/ACCH.
//
// Test cases:
//   TC01: Encode zero message → all-zero codeword
//   TC02–TC15: Encode single-bit messages → each yields exactly the
//               corresponding generator-matrix row
//   TC16: Encode all-ones message → XOR of all 14 G_ROW constants
//   TC17: Encode arbitrary word 0x1234 → known codeword
//   TC18: Decode with no errors → perfect round-trip
//   TC19: Decode with 1-bit error → corrects, decode_error=0
//   TC20: Decode with 3-bit errors → corrects (t_max=3), decode_error=0
//   TC21: Decode with 4-bit errors → decode_error=1 (uncorrectable)
//   TC22: Back-to-back: two consecutive encode-then-decode operations
//   TC23: Simultaneous encode + decode in flight (orthogonal paths)
//
// Reference model:
//   Verilog function rm_encode_ref() with the same G_ROW constants as the
//   DUT.  Encoder results are compared cycle-by-cycle.  Decoder results are
//   compared after the ~16 384 clock decode latency.
//
// Timing convention:
//   − encode_valid / decode_valid are 1-cycle pulses.
//   − encode_done fires 1 cycle after encode_valid.
//   − decode_done fires 2^K + 1 cycles after decode_valid (≈ 163 µs).
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_reed_muller;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10;   // 10 ns → 100 MHz
localparam N = 30;
localparam K = 14;

// Generator matrix rows (must match DUT localparams exactly)
localparam [29:0] G_ROW00 = 30'h33333333;
localparam [29:0] G_ROW01 = 30'h3C3C3C3C;
localparam [29:0] G_ROW02 = 30'h3FC03FC0;
localparam [29:0] G_ROW03 = 30'h3FFFC000;
localparam [29:0] G_ROW04 = 30'h22222222;
localparam [29:0] G_ROW05 = 30'h28282828;
localparam [29:0] G_ROW06 = 30'h2A802A80;
localparam [29:0] G_ROW07 = 30'h2AAA8000;
localparam [29:0] G_ROW08 = 30'h30303030;
localparam [29:0] G_ROW09 = 30'h33003300;
localparam [29:0] G_ROW10 = 30'h33330000;
localparam [29:0] G_ROW11 = 30'h3C003C00;
localparam [29:0] G_ROW12 = 30'h3C3C0000;
localparam [29:0] G_ROW13 = 30'h3FC00000;

localparam [4:0] T_MAX = 5'd3;

// Decode latency: 2^K S_DECODE cycles + 1 S_OUTPUT cycle + 1 decode_done reg
localparam DECODE_TIMEOUT = (1 << K) + 16;

// ---------------------------------------------------------------------------
// Reference model
// ---------------------------------------------------------------------------
function [N-1:0] rm_encode_ref;
    input [K-1:0] u;
    begin
        rm_encode_ref = ({N{u[ 0]}} & G_ROW00) ^
                        ({N{u[ 1]}} & G_ROW01) ^
                        ({N{u[ 2]}} & G_ROW02) ^
                        ({N{u[ 3]}} & G_ROW03) ^
                        ({N{u[ 4]}} & G_ROW04) ^
                        ({N{u[ 5]}} & G_ROW05) ^
                        ({N{u[ 6]}} & G_ROW06) ^
                        ({N{u[ 7]}} & G_ROW07) ^
                        ({N{u[ 8]}} & G_ROW08) ^
                        ({N{u[ 9]}} & G_ROW09) ^
                        ({N{u[10]}} & G_ROW10) ^
                        ({N{u[11]}} & G_ROW11) ^
                        ({N{u[12]}} & G_ROW12) ^
                        ({N{u[13]}} & G_ROW13);
    end
endfunction

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg          clk_sys;
reg          rst_n_sys;
reg  [K-1:0] encode_data_in;
reg          encode_valid;
wire [N-1:0] encode_data_out;
wire         encode_done;
reg  [N-1:0] decode_data_in;
reg          decode_valid;
wire [K-1:0] decode_data_out;
wire         decode_done;
wire         decode_error;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_reed_muller #(
    .N (N),
    .K (K)
) u_dut (
    .clk_sys        (clk_sys),
    .rst_n_sys      (rst_n_sys),
    .encode_data_in (encode_data_in),
    .encode_valid   (encode_valid),
    .encode_data_out(encode_data_out),
    .encode_done    (encode_done),
    .decode_data_in (decode_data_in),
    .decode_valid   (decode_valid),
    .decode_data_out(decode_data_out),
    .decode_done    (decode_done),
    .decode_error   (decode_error)
);

// ---------------------------------------------------------------------------
// Clock and waveform
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always  #(CLK_PERIOD/2) clk_sys = ~clk_sys;

initial begin
    $dumpfile("tb_tetra_reed_muller.vcd");
    $dumpvars(0, tb_tetra_reed_muller);
end

// ---------------------------------------------------------------------------
// Test counters
// ---------------------------------------------------------------------------
integer tc_pass;
integer tc_fail;

// ---------------------------------------------------------------------------
// Task: do_encode
//   Assert encode_valid for one cycle, then check encode_data_out 1 cycle
//   later when encode_done fires.
// ---------------------------------------------------------------------------
task do_encode;
    input [K-1:0]  u;
    input [N-1:0]  expected_c;
    input [127:0]  tc_name;  // for display (padded string)
    reg   [N-1:0]  ref_c;
    integer        timeout;
    begin
        ref_c = rm_encode_ref(u);

        // Assert for 1 cycle
        encode_data_in = u;
        encode_valid   = 1'b1;
        @(posedge clk_sys); #1;
        encode_valid   = 1'b0;

        // Wait for encode_done
        timeout = 0;
        while (!encode_done && timeout < 4) begin
            @(posedge clk_sys); #1;
            timeout = timeout + 1;
        end

        if (!encode_done) begin
            $error("%s FAIL: encode_done never fired", tc_name);
            tc_fail = tc_fail + 1;
        end else if (encode_data_out !== expected_c) begin
            $error("%s FAIL: encode got 0x%08X, expected 0x%08X",
                   tc_name, encode_data_out, expected_c);
            tc_fail = tc_fail + 1;
        end else if (encode_data_out !== ref_c) begin
            $error("%s FAIL: encode mismatch vs ref: got 0x%08X, ref 0x%08X",
                   tc_name, encode_data_out, ref_c);
            tc_fail = tc_fail + 1;
        end else begin
            $display("%s PASS: encode 0x%04X → 0x%08X", tc_name, u, encode_data_out);
            tc_pass = tc_pass + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Task: do_decode
//   Assert decode_valid for one cycle, then wait up to DECODE_TIMEOUT cycles
//   for decode_done.  Check decode_data_out and decode_error.
//   When expect_error=1, only the decode_error flag is checked; decode_data_out
//   is best-effort and not verified (the code is uncorrectable).
// ---------------------------------------------------------------------------
task do_decode;
    input [N-1:0]  recv_word;
    input [K-1:0]  expected_msg;   // ignored when expect_error=1
    input          expect_error;
    input [127:0]  tc_name;
    integer        timeout;
    begin
        decode_data_in = recv_word;
        decode_valid   = 1'b1;
        @(posedge clk_sys); #1;
        decode_valid = 1'b0;

        // Wait for decode_done
        timeout = 0;
        while (!decode_done && timeout < DECODE_TIMEOUT) begin
            @(posedge clk_sys); #1;
            timeout = timeout + 1;
        end

        if (!decode_done) begin
            $error("%s FAIL: decode_done never fired (timeout=%0d)", tc_name, timeout);
            tc_fail = tc_fail + 1;
        end else if (decode_error !== expect_error) begin
            $error("%s FAIL: decode_error=%b, expected %b (data=0x%04X)",
                   tc_name, decode_error, expect_error, decode_data_out);
            tc_fail = tc_fail + 1;
        end else if (!expect_error && decode_data_out !== expected_msg) begin
            // Only verify decoded data when no error is expected
            $error("%s FAIL: decode got 0x%04X, expected 0x%04X",
                   tc_name, decode_data_out, expected_msg);
            tc_fail = tc_fail + 1;
        end else begin
            $display("%s PASS: decode 0x%08X → 0x%04X (err=%b, t=%0d)",
                     tc_name, recv_word, decode_data_out, decode_error, timeout);
            tc_pass = tc_pass + 1;
        end
    end
endtask

// ===========================================================================
// Test sequence
// ===========================================================================
integer i;
reg [N-1:0] cw;   // codeword scratch

initial begin
    tc_pass         = 0;
    tc_fail         = 0;

    // Defaults
    rst_n_sys       = 1'b0;
    encode_data_in  = {K{1'b0}};
    encode_valid    = 1'b0;
    decode_data_in  = {N{1'b0}};
    decode_valid    = 1'b0;

    // Reset: hold for 5 cycles
    repeat (5) @(posedge clk_sys);
    #1 rst_n_sys = 1'b1;
    repeat (3) @(posedge clk_sys); #1;

    // -------------------------------------------------------------------------
    // TC01: Encode all-zeros → all-zero codeword
    // -------------------------------------------------------------------------
    do_encode(14'h0000, 30'h0, "TC01 ENC zero  ");

    // -------------------------------------------------------------------------
    // TC02–TC15: Encode single-bit messages → each equals one G_ROW
    // -------------------------------------------------------------------------
    do_encode(14'h0001, G_ROW00, "TC02 ENC u[0]  ");
    do_encode(14'h0002, G_ROW01, "TC03 ENC u[1]  ");
    do_encode(14'h0004, G_ROW02, "TC04 ENC u[2]  ");
    do_encode(14'h0008, G_ROW03, "TC05 ENC u[3]  ");
    do_encode(14'h0010, G_ROW04, "TC06 ENC u[4]  ");
    do_encode(14'h0020, G_ROW05, "TC07 ENC u[5]  ");
    do_encode(14'h0040, G_ROW06, "TC08 ENC u[6]  ");
    do_encode(14'h0080, G_ROW07, "TC09 ENC u[7]  ");
    do_encode(14'h0100, G_ROW08, "TC10 ENC u[8]  ");
    do_encode(14'h0200, G_ROW09, "TC11 ENC u[9]  ");
    do_encode(14'h0400, G_ROW10, "TC12 ENC u[10] ");
    do_encode(14'h0800, G_ROW11, "TC13 ENC u[11] ");
    do_encode(14'h1000, G_ROW12, "TC14 ENC u[12] ");
    do_encode(14'h2000, G_ROW13, "TC15 ENC u[13] ");

    // -------------------------------------------------------------------------
    // TC16: Encode all-ones → XOR of all G_ROWs
    // -------------------------------------------------------------------------
    cw = G_ROW00 ^ G_ROW01 ^ G_ROW02 ^ G_ROW03 ^
         G_ROW04 ^ G_ROW05 ^ G_ROW06 ^ G_ROW07 ^
         G_ROW08 ^ G_ROW09 ^ G_ROW10 ^ G_ROW11 ^
         G_ROW12 ^ G_ROW13;
    do_encode({K{1'b1}}, cw, "TC16 ENC ones  ");

    // -------------------------------------------------------------------------
    // TC17: Encode arbitrary word 0x1234 & 14'h3FFF = 14'h1234
    //   (bit 13 of 0x1234 is 0: 0x1234 = 14'b00_1001_0001_0100 → 14'h1234)
    //   Reference via rm_encode_ref()
    // -------------------------------------------------------------------------
    cw = rm_encode_ref(14'h1234);
    do_encode(14'h1234, cw, "TC17 ENC 0x1234");

    @(posedge clk_sys); #1;

    // -------------------------------------------------------------------------
    // TC18: Decode — no errors, zero message
    // -------------------------------------------------------------------------
    do_decode(30'h00000000, 14'h0000, 1'b0, "TC18 DEC zeros ");

    // -------------------------------------------------------------------------
    // TC19: Decode — no errors, message 0x0A5B
    // -------------------------------------------------------------------------
    cw = rm_encode_ref(14'h0A5B);
    do_decode(cw, 14'h0A5B, 1'b0, "TC19 DEC noerr ");

    // -------------------------------------------------------------------------
    // TC20: Decode — 1-bit error on bit 7
    // -------------------------------------------------------------------------
    cw = rm_encode_ref(14'h0A5B) ^ (30'h1 << 7);
    do_decode(cw, 14'h0A5B, 1'b0, "TC20 DEC 1berr ");

    // -------------------------------------------------------------------------
    // TC21: Decode — 3-bit errors (maximum correctable, t_max=3)
    //   Inject bits 0, 15, 28
    // -------------------------------------------------------------------------
    cw = rm_encode_ref(14'h1AAA) ^
         (30'h1 << 0) ^ (30'h1 << 15) ^ (30'h1 << 28);
    do_decode(cw, 14'h1AAA, 1'b0, "TC21 DEC 3berr ");

    // -------------------------------------------------------------------------
    // TC22: Decode — 4-bit errors (uncorrectable), expect decode_error=1
    //   Inject bits 0, 5, 10, 20
    // -------------------------------------------------------------------------
    cw = rm_encode_ref(14'h0F0F) ^
         (30'h1 << 0) ^ (30'h1 << 5) ^ (30'h1 << 10) ^ (30'h1 << 20);
    // expected_msg is don't-care when expect_error=1; pass 0 as placeholder
    do_decode(cw, 14'h0000, 1'b1, "TC22 DEC 4berr ");

    // -------------------------------------------------------------------------
    // TC23: Back-to-back — encode 0x3210, then immediately decode its codeword
    // -------------------------------------------------------------------------
    begin : tc23_encode
        reg [N-1:0] cw23;
        cw23 = rm_encode_ref(14'h3210);
        // Encode — encode_done fires at the SAME posedge as encode_valid (1-cycle latency).
        // Check immediately after that posedge+#1; do NOT advance one more clock.
        encode_data_in = 14'h3210;
        encode_valid   = 1'b1;
        @(posedge clk_sys); #1;
        encode_valid = 1'b0;
        // encode_done is now 1 (registered at the posedge just passed)
        if (!encode_done || encode_data_out !== cw23) begin
            $error("TC23 FAIL: encode step, got 0x%08X expected 0x%08X",
                   encode_data_out, cw23);
            tc_fail = tc_fail + 1;
        end else begin
            // Immediately feed encoded word to decoder (no errors)
            do_decode(encode_data_out, 14'h3210, 1'b0, "TC23 E2D 0x3210");
        end
    end

    // -------------------------------------------------------------------------
    // TC24: Simultaneous encode and decode start
    //   Assert both encode_valid and decode_valid on the same cycle.
    //   Encoder result arrives 1 cycle later; decode runs in background.
    // -------------------------------------------------------------------------
    begin : tc24
        reg [N-1:0] cw24;
        reg [N-1:0] enc_result;
        integer     t24;

        cw24 = rm_encode_ref(14'h155A);

        // Assert both at once — encode_done fires at the same posedge as encode_valid
        encode_data_in = 14'h155A;
        encode_valid   = 1'b1;
        decode_data_in = rm_encode_ref(14'h155A);  // decode own codeword
        decode_valid   = 1'b1;
        @(posedge clk_sys); #1;
        encode_valid = 1'b0;
        decode_valid = 1'b0;
        // encode_done is now 1 (registered at the posedge just passed); check immediately
        if (!encode_done || encode_data_out !== cw24) begin
            $error("TC24 FAIL: encode side, got 0x%08X expected 0x%08X",
                   encode_data_out, cw24);
            tc_fail = tc_fail + 1;
        end else begin
            $display("TC24 encode side PASS: 0x%08X", encode_data_out);
            tc_pass = tc_pass + 1;
        end

        // Wait for decode to finish
        t24 = 0;
        while (!decode_done && t24 < DECODE_TIMEOUT) begin
            @(posedge clk_sys); #1;
            t24 = t24 + 1;
        end
        if (!decode_done || decode_data_out !== 14'h155A || decode_error !== 1'b0) begin
            $error("TC24 FAIL: decode side, got 0x%04X err=%b (t=%0d)",
                   decode_data_out, decode_error, t24);
            tc_fail = tc_fail + 1;
        end else begin
            $display("TC24 decode side PASS: 0x%04X (t=%0d)", decode_data_out, t24);
            tc_pass = tc_pass + 1;
        end
    end

    // -------------------------------------------------------------------------
    // TC22 error-value check: if decode_error=1, decode_data_out value is
    //   don't-care (best effort).  We only check the error flag was set.
    //   (Checked above — just explain in display.)
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    @(posedge clk_sys); #1;
    $display("============================================================");
    $display("Reed-Muller testbench: %0d/%0d passed",
             tc_pass, tc_pass + tc_fail);
    $display("============================================================");
    if (tc_fail == 0)
        $display("ALL TESTS PASSED");
    else
        $error("FAILURES: %0d test(s) failed", tc_fail);

    #100;
    $finish;
end

// ---------------------------------------------------------------------------
// Watchdog: 10 ms simulation limit (covers ~2 back-to-back decodes)
// ---------------------------------------------------------------------------
initial begin
    #10_000_000;
    $error("WATCHDOG TIMEOUT — simulation exceeded 10 ms");
    $finish;
end

endmodule

`default_nettype wire
