// =============================================================================
// tb_tetra_rcpc_encoder.v — Self-Checking Testbench
// =============================================================================
// Tests tetra_rcpc_encoder.v against known reference values from
// gen_rcpc_encoder_vectors.py (same encode_bit() model as gen_viterbi_vectors.py).
//
// Test Cases:
//   TC1: 4-bit block [1,0,1,1], no tail — verify coded_bits per cycle
//   TC2: All-zeros 8-bit block — verify all coded_bits=0
//   TC3: Flush after 4-bit block [1,0,1,1] — verify tail outputs + SR returns to 0
//   TC4: Rate 2/3 puncturing — verify punct_out_bits and punct_valid
//   TC5: Reset mid-sequence — verify clean restart
//   TC6: 4-bit block [1,1,0,0] — additional pattern verification
//
// Expected values computed from gen_rcpc_encoder_vectors.py output.
// Pipeline: 1 cycle (coded_bits valid 1 cycle after data_in/data_valid sampled)
//
// Simulation: iverilog -g2001 tb_tetra_rcpc_encoder.v ../../rtl/lmac/tetra_rcpc_encoder.v
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_tetra_rcpc_encoder;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg        clk_sys;
    reg        rst_n_sys;
    reg        data_in;
    reg        data_valid;
    reg  [2:0] punct_pattern;
    reg        flush;
    wire [2:0] coded_bits;
    wire       coded_valid;
    wire [1:0] punct_out_bits;
    wire       punct_valid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    tetra_rcpc_encoder #(
        .K (5)
    ) dut (
        .clk_sys       (clk_sys),
        .rst_n_sys     (rst_n_sys),
        .data_in       (data_in),
        .data_valid    (data_valid),
        .punct_pattern (punct_pattern),
        .flush         (flush),
        .coded_bits    (coded_bits),
        .coded_valid   (coded_valid),
        .punct_out_bits(punct_out_bits),
        .punct_valid   (punct_valid)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period (100 MHz)
    // -------------------------------------------------------------------------
    initial clk_sys = 1'b0;
    always  #5 clk_sys = ~clk_sys;

    // -------------------------------------------------------------------------
    // Test infrastructure
    // -------------------------------------------------------------------------
    integer fail_cnt;
    integer pass_cnt;

    task apply_bit;
        input data_bit;
        input dv;
        begin
            @(negedge clk_sys);
            data_in    = data_bit;
            data_valid = dv;
            flush      = 1'b0;
        end
    endtask

    task check_coded;
        input [2:0] expected;
        input       exp_valid;
        input [31:0] tc_num;
        input [31:0] step;
        begin
            @(posedge clk_sys); #1;
            if (coded_bits !== expected || coded_valid !== exp_valid) begin
                $display("FAIL TC%0d step%0d: coded_bits=%b coded_valid=%b  expected=%b valid=%b",
                         tc_num, step, coded_bits, coded_valid, expected, exp_valid);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    task check_punct;
        input [1:0] expected_pb;
        input       expected_pv;
        input [31:0] tc_num;
        input [31:0] step;
        begin
            // punct_valid and punct_out_bits are sampled at same posedge as coded
            if (punct_valid !== expected_pv || punct_out_bits !== expected_pb) begin
                $display("FAIL TC%0d step%0d: punct_out=%b punct_valid=%b  expected=%b valid=%b",
                         tc_num, step, punct_out_bits, punct_valid, expected_pb, expected_pv);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_tetra_rcpc_encoder.vcd");
        $dumpvars(0, tb_tetra_rcpc_encoder);

        fail_cnt     = 0;
        pass_cnt     = 0;

        // --- Reset ---
        rst_n_sys    = 1'b0;
        data_in      = 1'b0;
        data_valid   = 1'b0;
        punct_pattern= 3'd0;
        flush        = 1'b0;
        @(posedge clk_sys); #1;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys    = 1'b1;

        // =====================================================================
        // TC1: Input [1,0,1,1], no tail, punct_pattern=0
        // Expected (from gen_rcpc_encoder_vectors.py, SR starts at 0):
        //   bit=1, SR=0000: g1=1 g2=1 g3=1 → coded_bits=3'b111
        //   bit=0, SR=1000: g1=1 g2=1 g3=0 → coded_bits=3'b011
        //   bit=1, SR=0100: g1=1 g2=1 g3=0 → coded_bits=3'b011
        //   bit=1, SR=1010: g1=1 g2=0 g3=1 → coded_bits=3'b101
        // =====================================================================
        $display("--- TC1: 4-bit block [1,0,1,1], no tail, rate 1/3 ---");
        punct_pattern = 3'd0;

        // Apply bit 0 (=1) and check output after posedge
        apply_bit(1'b1, 1'b1);
        check_coded(3'b111, 1'b1, 1, 0);

        // Apply bit 1 (=0)
        apply_bit(1'b0, 1'b1);
        check_coded(3'b011, 1'b1, 1, 1);

        // Apply bit 2 (=1)
        apply_bit(1'b1, 1'b1);
        check_coded(3'b011, 1'b1, 1, 2);

        // Apply bit 3 (=1)
        apply_bit(1'b1, 1'b1);
        check_coded(3'b101, 1'b1, 1, 3);

        // Idle cycle — coded_valid must go low
        apply_bit(1'b0, 1'b0);
        check_coded(3'b101, 1'b0, 1, 4);  // coded_bits holds; valid=0

        // =====================================================================
        // TC2: All-zeros 8-bit block (SR was 13=1101 from TC1, but reset here)
        // Reset DUT to start fresh
        // All-zeros input from clean state (SR=0): output is all zeros
        // =====================================================================
        $display("--- TC2: All-zeros 8-bit, clean reset ---");
        @(negedge clk_sys);
        rst_n_sys = 1'b0;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys = 1'b1;

        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 0);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 1);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 2);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 3);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 4);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 5);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 6);
        apply_bit(1'b0, 1'b1); check_coded(3'b000, 1'b1, 2, 7);

        // =====================================================================
        // TC3: Flush after [1,0,1,1] — verify 4 tail outputs + final SR=0
        // Starting from clean reset:
        //   Data: [1,0,1,1] → SR ends at 13 (1101)
        //   Tail 0 (SR=1101, in=0): g1=0 g2=0 g3=0 → coded_bits=000
        //   Tail 1 (SR=0110, in=0): g1=1 g2=0 g3=1 → coded_bits=101
        //   Tail 2 (SR=0011, in=0): g1=0 g2=1 g3=1 → coded_bits=110
        //   Tail 3 (SR=0001, in=0): g1=1 g2=1 g3=1 → coded_bits=111; final SR=0
        // =====================================================================
        $display("--- TC3: Flush (tail bits) after [1,0,1,1] ---");
        @(negedge clk_sys);
        rst_n_sys = 1'b0;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys = 1'b1;

        // Send data bits [1,0,1,1]
        apply_bit(1'b1, 1'b1);
        check_coded(3'b111, 1'b1, 3, 0);

        apply_bit(1'b0, 1'b1);
        check_coded(3'b011, 1'b1, 3, 1);

        apply_bit(1'b1, 1'b1);
        check_coded(3'b011, 1'b1, 3, 2);

        apply_bit(1'b1, 1'b1);
        check_coded(3'b101, 1'b1, 3, 3);

        // Trigger flush (data_valid=0, flush=1 for 1 cycle)
        @(negedge clk_sys);
        data_valid = 1'b0;
        data_in    = 1'b0;
        flush      = 1'b1;
        @(posedge clk_sys); #1;
        // flush registered — flush_active_sys becomes 1 next cycle
        // coded_valid should still be 0 (no enable yet)
        @(negedge clk_sys);
        flush = 1'b0;

        // Tail bit 0: flush_active_sys=1, in=0, SR=1101 → coded_bits=000
        check_coded(3'b000, 1'b1, 3, 4);

        // Tail bit 1: SR=0110, in=0 → coded_bits=101
        apply_bit(1'b0, 1'b0);
        check_coded(3'b101, 1'b1, 3, 5);

        // Tail bit 2: SR=0011, in=0 → coded_bits=110
        apply_bit(1'b0, 1'b0);
        check_coded(3'b110, 1'b1, 3, 6);

        // Tail bit 3: SR=0001, in=0 → coded_bits=111; final SR→0
        apply_bit(1'b0, 1'b0);
        check_coded(3'b111, 1'b1, 3, 7);

        // After flush complete: coded_valid should go 0, flush_active=0
        apply_bit(1'b0, 1'b0);
        check_coded(3'b111, 1'b0, 3, 8);   // valid=0, bits hold last value

        // =====================================================================
        // TC4: Rate 2/3 puncturing — input [1,0,1,1] from clean state
        // Expected punct_out_bits = {G2, G1} = coded_bits[1:0]:
        //   bit=1, SR=0: g1=1, g2=1 → punct_out_bits=2'b11
        //   bit=0, SR=8: g1=1, g2=1 → punct_out_bits=2'b11
        //   bit=1, SR=4: g1=1, g2=1 → punct_out_bits=2'b11
        //   bit=1, SR=10: g1=1, g2=0 → punct_out_bits=2'b01
        // =====================================================================
        $display("--- TC4: Rate 2/3 puncturing, [1,0,1,1] ---");
        @(negedge clk_sys);
        rst_n_sys = 1'b0;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys     = 1'b1;
        punct_pattern = 3'd1;   // rate 2/3

        apply_bit(1'b1, 1'b1);
        @(posedge clk_sys); #1;
        check_punct(2'b11, 1'b1, 4, 0);

        apply_bit(1'b0, 1'b1);
        @(posedge clk_sys); #1;
        check_punct(2'b11, 1'b1, 4, 1);

        apply_bit(1'b1, 1'b1);
        @(posedge clk_sys); #1;
        check_punct(2'b11, 1'b1, 4, 2);

        apply_bit(1'b1, 1'b1);
        @(posedge clk_sys); #1;
        check_punct(2'b01, 1'b1, 4, 3);

        // Idle: punct_valid should go low
        apply_bit(1'b0, 1'b0);
        @(posedge clk_sys); #1;
        check_punct(2'b01, 1'b0, 4, 4);

        // =====================================================================
        // TC5: Pattern 0 (no punct) — punct_valid must be 0 always
        // =====================================================================
        $display("--- TC5: Pattern=0, punct_valid must stay 0 ---");
        @(negedge clk_sys);
        rst_n_sys     = 1'b0;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys     = 1'b1;
        punct_pattern = 3'd0;

        // All inputs → punct_valid must stay 0 (pattern=0 = no puncturing)
        apply_bit(1'b1, 1'b1); @(posedge clk_sys); #1;
        if (punct_valid !== 1'b0) begin $display("FAIL TC5 s0: punct_valid=%b", punct_valid); fail_cnt=fail_cnt+1; end else pass_cnt=pass_cnt+1;
        apply_bit(1'b1, 1'b1); @(posedge clk_sys); #1;
        if (punct_valid !== 1'b0) begin $display("FAIL TC5 s1: punct_valid=%b", punct_valid); fail_cnt=fail_cnt+1; end else pass_cnt=pass_cnt+1;
        apply_bit(1'b1, 1'b1); @(posedge clk_sys); #1;
        if (punct_valid !== 1'b0) begin $display("FAIL TC5 s2: punct_valid=%b", punct_valid); fail_cnt=fail_cnt+1; end else pass_cnt=pass_cnt+1;
        apply_bit(1'b1, 1'b1); @(posedge clk_sys); #1;
        if (punct_valid !== 1'b0) begin $display("FAIL TC5 s3: punct_valid=%b", punct_valid); fail_cnt=fail_cnt+1; end else pass_cnt=pass_cnt+1;

        // =====================================================================
        // TC6: Reset mid-sequence — verify clean restart
        // =====================================================================
        $display("--- TC6: Reset mid-sequence ---");
        @(negedge clk_sys);
        rst_n_sys     = 1'b1;
        punct_pattern = 3'd0;

        // Start encoding
        apply_bit(1'b1, 1'b1);
        @(posedge clk_sys); #1;  // bit 1 processed

        apply_bit(1'b1, 1'b1);
        @(posedge clk_sys); #1;  // bit 2 processed

        // Mid-sequence reset
        @(negedge clk_sys);
        rst_n_sys = 1'b0; data_valid = 1'b0;  // clear leftover valid
        @(posedge clk_sys); #1;
        if (coded_valid !== 1'b0) begin
            $display("FAIL TC6: coded_valid should be 0 in reset, got %b", coded_valid);
            fail_cnt = fail_cnt + 1;
        end else begin
            pass_cnt = pass_cnt + 1;
        end

        @(negedge clk_sys);
        rst_n_sys = 1'b1;

        // After reset: SR=0, first bit=1 should give coded_bits=111
        apply_bit(1'b1, 1'b1);
        check_coded(3'b111, 1'b1, 6, 0);

        // =====================================================================
        // TC7: Known TETRA-like pattern: alternating bits [1,0] × 4
        // SR starts 0; expected:
        //   bit=1,SR=0000: g1=1 g2=1 g3=1 → 111
        //   bit=0,SR=1000: g1=1 g2=1 g3=0 → 011
        //   bit=1,SR=0100: g1=1 g2=1 g3=0 → 011  (SR=0100: sr[3]=0,sr[2]=1,sr[1]=0,sr[0]=0)
        //     g1=1^0^0^0=1, g2=1^0^0=1, g3=1^1^0=0 → 011
        //   bit=0,SR=1010: g1=0^1^1^0=0, g2=0^1^0=1, g3=0^0^0=0 → 010
        //   bit=1,SR=0101: g1=1^0^0^1=0, g2=1^0^1=0, g3=1^1^1=1 → 100
        //   bit=0,SR=1010: same as before → 010
        //   bit=1,SR=0101: same as before → 100
        //   bit=0,SR=1010: same → 010
        // =====================================================================
        $display("--- TC7: Alternating [1,0] x4 ---");
        @(negedge clk_sys);
        data_valid = 1'b0;    // clear before reset — TC6 leaves data_valid=1
        rst_n_sys  = 1'b0;
        @(posedge clk_sys); #1;
        @(negedge clk_sys);
        rst_n_sys = 1'b1;

        // Precomputed (verified against Python):
        //  [1,0,1,0,1,0,1,0] from SR=0
        //  Expected coded: 111, 011, 011, 010, 100, 010, 100, 010
        apply_bit(1'b1, 1'b1); check_coded(3'b111, 1'b1, 7, 0);
        apply_bit(1'b0, 1'b1); check_coded(3'b011, 1'b1, 7, 1);
        apply_bit(1'b1, 1'b1); check_coded(3'b011, 1'b1, 7, 2);
        apply_bit(1'b0, 1'b1); check_coded(3'b010, 1'b1, 7, 3);
        apply_bit(1'b1, 1'b1); check_coded(3'b100, 1'b1, 7, 4);
        apply_bit(1'b0, 1'b1); check_coded(3'b010, 1'b1, 7, 5);
        apply_bit(1'b1, 1'b1); check_coded(3'b100, 1'b1, 7, 6);
        apply_bit(1'b0, 1'b1); check_coded(3'b010, 1'b1, 7, 7);

        // =====================================================================
        // Final summary
        // =====================================================================
        $display("========================================");
        if (fail_cnt == 0) begin
            $display("PASS — All %0d checks passed", pass_cnt);
        end else begin
            $display("FAIL — %0d/%0d checks failed", fail_cnt, fail_cnt + pass_cnt);
        end
        $display("========================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout guard
    // -------------------------------------------------------------------------
    initial begin
        #500000;
        $display("TIMEOUT — simulation exceeded 500 us");
        $finish;
    end

endmodule
`default_nettype wire
