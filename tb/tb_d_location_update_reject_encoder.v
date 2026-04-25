// =============================================================================
// tb_d_location_update_reject_encoder.v — REJECT field-packing tests
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_d_location_update_reject_encoder;
    reg [2:0]   reject_cause = 3'd0;
    wire [127:0] pdu_bits_mm;
    wire [7:0]   pdu_len_bits;

    tetra_d_location_update_reject_encoder dut (
        .reject_cause (reject_cause),
        .pdu_bits_mm  (pdu_bits_mm),
        .pdu_len_bits (pdu_len_bits)
    );

    integer fail_count = 0;
    integer test_count = 0;

    task automatic check;
        input integer hi;
        input integer lo;
        input [63:0]  expected;
        input [255:0] name;
        reg   [63:0]  actual;
        reg   [255:0] g;
        begin
            test_count = test_count + 1;
            g          = {128'd0, pdu_bits_mm};
            actual     = (g >> lo) & ((64'd1 << (hi - lo + 1)) - 64'd1);
            if (actual !== expected) begin
                $display("[T%0d] FAIL %0s [%0d:%0d] got=%h exp=%h",
                         test_count, name, hi, lo, actual, expected);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS %0s [%0d:%0d] = %h",
                         test_count, name, hi, lo, actual);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_d_location_update_reject_encoder.vcd");
        $dumpvars(0, tb_d_location_update_reject_encoder);

        // ----- Test all 8 reject-cause values -----
        reject_cause = 3'd0; #1;  // ITSI unknown
        check(127, 124, 64'h7,   "pdu_type_reject");
        check(123, 121, 64'h0,   "cause_itsi_unknown");
        check(120, 120, 64'h0,   "obit_zero");
        test_count = test_count + 1;
        if (pdu_len_bits !== 8'd8) begin
            $display("[T%0d] FAIL pdu_len got=%0d exp=8", test_count, pdu_len_bits);
            fail_count = fail_count + 1;
        end else $display("[T%0d] PASS pdu_len = %0d", test_count, pdu_len_bits);

        reject_cause = 3'd4; #1;  // service not authorised
        check(123, 121, 64'h4, "cause_service_not_authorised");

        reject_cause = 3'd2; #1;  // no resources available
        check(123, 121, 64'h2, "cause_no_resources");

        reject_cause = 3'd7; #1;  // forbidden LA
        check(123, 121, 64'h7, "cause_forbidden_la");

        // Sanity: padding bits are zero for any cause
        reject_cause = 3'd5; #1;
        check(119,   0, 64'h0, "padding_zero");

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_d_location_update_reject_encoder: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_d_location_update_reject_encoder: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

endmodule

`default_nettype wire
