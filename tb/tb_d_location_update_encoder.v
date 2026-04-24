// =============================================================================
// tb_d_location_update_encoder.v — unit test for field packing
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_d_location_update_encoder;
    reg         pdu_reject = 0;
    reg  [2:0]  addr_type  = 3'd0;
    reg  [23:0] ssi        = 24'h000000;
    reg  [13:0] la         = 14'd0;
    reg  [1:0]  result     = 2'd0;
    reg  [1:0]  encryption = 2'd0;
    reg  [1:0]  auth_result= 2'd0;
    reg  [15:0] subscriber_class = 16'h0000;
    reg  [2:0]  loc_acc_type = 3'd0;  // Bug #8 — dynamic accept type
    wire [123:0] pdu_bits;
    wire [79:0]  pdu_bits_mm;
    wire [6:0]   pdu_len_bits;

    tetra_d_location_update_encoder dut (
        .pdu_reject      (pdu_reject),
        .addr_type       (addr_type),
        .ssi             (ssi),
        .la              (la),
        .result          (result),
        .encryption      (encryption),
        .auth_result     (auth_result),
        .subscriber_class(subscriber_class),
        .loc_acc_type    (loc_acc_type),
        .pdu_bits        (pdu_bits),
        .pdu_bits_mm     (pdu_bits_mm),
        .pdu_len_bits    (pdu_len_bits)
    );

    integer fail_count = 0;
    integer test_count = 0;

    task automatic check_field(input [123:0] got,
                               input integer hi,
                               input integer lo,
                               input [63:0]  expected,
                               input [255:0] name);
        reg [63:0] actual;
        begin
            test_count = test_count + 1;
            actual = (got >> lo) & ((64'd1 << (hi - lo + 1)) - 64'd1);
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
        $dumpfile("sim_out/tb_d_location_update_encoder.vcd");
        $dumpvars(0, tb_d_location_update_encoder);

        // ----- Test 1: ACCEPT / SSI=523 / LA=36 (MTP3550 / HAM cell values) -----
        pdu_reject      = 1'b0;
        addr_type       = 3'd1;        // SSI
        ssi             = 24'd523;
        la              = 14'd36;
        result          = 2'b00;       // accept
        encryption      = 2'b00;       // clear
        auth_result     = 2'b01;       // success
        subscriber_class= 16'h1234;
        #1;

        check_field(pdu_bits, 123, 120, 64'h1,        "PDU_Type_ACCEPT");
        check_field(pdu_bits, 119, 117, 64'd1,        "addr_type");
        check_field(pdu_bits, 116,  93, 64'd523,      "ssi");
        check_field(pdu_bits,  92,  79, 64'd36,       "la");
        check_field(pdu_bits,  78,  77, 64'd0,        "result_accept");
        check_field(pdu_bits,  76,  75, 64'd0,        "encryption_clear");
        check_field(pdu_bits,  74,  73, 64'd1,        "auth_success");
        check_field(pdu_bits,  72,  57, 64'h1234,     "subscriber_class");
        check_field(pdu_bits,  56,   0, 64'd0,        "reserved_zero");

        // ----- Test 2: REJECT permanent -----
        pdu_reject      = 1'b1;
        result          = 2'b10;
        ssi             = 24'hFFFFFF;
        la              = 14'h3FFF;
        #1;
        check_field(pdu_bits, 123, 120, 64'h2,        "PDU_Type_REJECT");
        check_field(pdu_bits, 116,  93, 64'hFFFFFF,   "ssi_all_ones");
        check_field(pdu_bits,  92,  79, 64'h3FFF,     "la_all_ones");
        check_field(pdu_bits,  78,  77, 64'd2,        "result_reject_perm");

        // ----- Test 3: SSI boundary (0 and max) -----
        pdu_reject = 1'b0;
        ssi        = 24'd0;
        la         = 14'd0;
        #1;
        check_field(pdu_bits, 116, 93, 64'd0, "ssi_zero");
        check_field(pdu_bits,  92, 79, 64'd0, "la_zero");

        // ----- Test 4: MM wrapper-oriented output matches BlueStation-style
        // accept layout with SSI IE present.
        loc_acc_type = 3'b011;  // ITSI attach
        ssi          = 24'd10001;
        #1;
        test_count = test_count + 1;
        if (pdu_len_bits !== 7'd38) begin
            $display("[T%0d] FAIL mm_len got=%0d exp=38", test_count, pdu_len_bits);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d] PASS mm_len = %0d", test_count, pdu_len_bits);
        end
        check_field({44'd0, pdu_bits_mm}, 79, 76, 64'h5,     "mm_pdu_type_accept");
        check_field({44'd0, pdu_bits_mm}, 75, 73, 64'h3,     "mm_loc_acc_type");
        check_field({44'd0, pdu_bits_mm}, 72, 72, 64'h1,     "mm_obit");
        check_field({44'd0, pdu_bits_mm}, 71, 71, 64'h1,     "mm_p_ssi");
        check_field({44'd0, pdu_bits_mm}, 70, 47, 64'd10001, "mm_ssi");
        check_field({44'd0, pdu_bits_mm}, 46, 43, 64'h0,     "mm_pbits_zero");
        check_field({44'd0, pdu_bits_mm}, 42, 42, 64'h0,     "mm_mbit_zero");

        // ----- Test 5: total width sanity — expected bits set match hand-computed -----
        // With accept, addr_type=1, ssi=1, la=0, everything-else=0:
        //   pdu_type  = 0001    at [123:120]
        //   addr_type = 001     at [119:117]
        //   ssi       = 0..01   at [116: 93]   (bit 93 = 1)
        //   all other = 0
        // Expected 124-bit pattern: 1=at123, 1=at117, 1=at93
        pdu_reject      = 1'b0;
        addr_type       = 3'd1;
        ssi             = 24'd1;
        la              = 14'd0;
        result          = 2'b00;
        encryption      = 2'b00;
        auth_result     = 2'b00;
        subscriber_class= 16'h0000;
        #1;
        begin
            reg [123:0] exp;
            exp = 124'd0;
            exp[120] = 1'b1;  // pdu_type LSB (0001)
            exp[117] = 1'b1;  // addr_type LSB (001)
            exp[93]  = 1'b1;  // ssi LSB (24'd1)
            test_count = test_count + 1;
            if (pdu_bits !== exp) begin
                $display("[T%0d] FAIL full_vector\n  got=%h\n  exp=%h",
                         test_count, pdu_bits, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS full_vector", test_count);
            end
        end

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_d_location_update_encoder: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_d_location_update_encoder: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

endmodule

`default_nettype wire
