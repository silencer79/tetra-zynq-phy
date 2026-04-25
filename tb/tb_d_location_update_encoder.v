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
    reg  [23:0] address_extension = 24'h000000;
    reg  [13:0] energy_saving_info = 14'h0000;
    reg  [2:0]  loc_acc_type = 3'd0;  // Bug #8 — dynamic accept type
    // Phase 6 D-rev — dynamic GILA inputs (default M2 values).
    reg  [23:0] gila_gssi     = 24'h2F4D61;
    reg  [2:0]  gila_class    = 3'b100;  // = 4
    reg  [1:0]  gila_lifetime = 2'b01;   // = 1
    reg         gila_present  = 1'b1;
    wire [123:0] pdu_bits;
    wire [127:0] pdu_bits_mm;
    wire [7:0]   pdu_len_bits;

    tetra_d_location_update_encoder dut (
        .pdu_reject        (pdu_reject),
        .addr_type         (addr_type),
        .ssi               (ssi),
        .la                (la),
        .result            (result),
        .encryption        (encryption),
        .auth_result       (auth_result),
        .subscriber_class  (subscriber_class),
        .address_extension (address_extension),
        .energy_saving_info(energy_saving_info),
        .loc_acc_type      (loc_acc_type),
        .gila_gssi         (gila_gssi),
        .gila_class        (gila_class),
        .gila_lifetime     (gila_lifetime),
        .gila_present      (gila_present),
        .pdu_bits          (pdu_bits),
        .pdu_bits_mm       (pdu_bits_mm),
        .pdu_len_bits      (pdu_len_bits)
    );

    integer fail_count = 0;
    integer test_count = 0;

    task automatic check_field(input [255:0] got,
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

        check_field({132'd0, pdu_bits},123, 120, 64'h1,        "PDU_Type_ACCEPT");
        check_field({132'd0, pdu_bits},119, 117, 64'd1,        "addr_type");
        check_field({132'd0, pdu_bits},116,  93, 64'd523,      "ssi");
        check_field({132'd0, pdu_bits}, 92,  79, 64'd36,       "la");
        check_field({132'd0, pdu_bits}, 78,  77, 64'd0,        "result_accept");
        check_field({132'd0, pdu_bits}, 76,  75, 64'd0,        "encryption_clear");
        check_field({132'd0, pdu_bits}, 74,  73, 64'd1,        "auth_success");
        check_field({132'd0, pdu_bits}, 72,  57, 64'h1234,     "subscriber_class");
        check_field({132'd0, pdu_bits}, 56,   0, 64'd0,        "reserved_zero");

        // ----- Test 2: REJECT permanent -----
        pdu_reject      = 1'b1;
        result          = 2'b10;
        ssi             = 24'hFFFFFF;
        la              = 14'h3FFF;
        #1;
        check_field({132'd0, pdu_bits},123, 120, 64'h2,        "PDU_Type_REJECT");
        check_field({132'd0, pdu_bits},116,  93, 64'hFFFFFF,   "ssi_all_ones");
        check_field({132'd0, pdu_bits}, 92,  79, 64'h3FFF,     "la_all_ones");
        check_field({132'd0, pdu_bits}, 78,  77, 64'd2,        "result_reject_perm");

        // ----- Test 3: SSI boundary (0 and max) -----
        pdu_reject = 1'b0;
        ssi        = 24'd0;
        la         = 14'd0;
        #1;
        check_field({132'd0, pdu_bits},116, 93, 64'd0, "ssi_zero");
        check_field({132'd0, pdu_bits}, 92, 79, 64'd0, "la_zero");

        // ----- Test 4: MM wrapper output — bit-exact gold-reference Accept
        // (102 bit MM body): p_ssi=0, p_ae=0, p_sc=0, p_esi=1+ESI(StayAlive),
        // p_scch=0, type-3 GroupIdentityLocationAccept with hard-coded gold
        // GILA payload (length=58).
        loc_acc_type       = 3'b011;          // ITSI attach
        ssi                = 24'd10001;       // legacy path only
        address_extension  = 24'hABCDEF;      // unused in new MM body
        subscriber_class   = 16'hFFFF;        // unused in new MM body
        energy_saving_info = 14'h0000;        // StayAlive
        #1;
        test_count = test_count + 1;
        if (pdu_len_bits !== 8'd102) begin
            $display("[T%0d] FAIL mm_len got=%0d exp=102", test_count, pdu_len_bits);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d] PASS mm_len = %0d", test_count, pdu_len_bits);
        end
        check_field({128'd0, pdu_bits_mm}, 127, 124, 64'h5,        "mm_pdu_type_accept");
        check_field({128'd0, pdu_bits_mm}, 123, 121, 64'h3,        "mm_loc_acc_type");
        check_field({128'd0, pdu_bits_mm}, 120, 120, 64'h1,        "mm_obit");
        check_field({128'd0, pdu_bits_mm}, 119, 119, 64'h0,        "mm_p_ssi_absent");
        check_field({128'd0, pdu_bits_mm}, 118, 118, 64'h0,        "mm_p_ae_absent");
        check_field({128'd0, pdu_bits_mm}, 117, 117, 64'h0,        "mm_p_sc_absent");
        check_field({128'd0, pdu_bits_mm}, 116, 116, 64'h1,        "mm_p_esi_present");
        check_field({128'd0, pdu_bits_mm}, 115, 102, 64'h0,        "mm_esi_stayalive");
        check_field({128'd0, pdu_bits_mm}, 101, 101, 64'h0,        "mm_p_scch_zero");
        check_field({128'd0, pdu_bits_mm}, 100, 100, 64'h1,        "mm_m_gila_present");
        check_field({128'd0, pdu_bits_mm},  99,  96, 64'h5,        "mm_type3_id_gila");
        check_field({128'd0, pdu_bits_mm},  95,  85, 64'd58,       "mm_type3_len_58");
        // GILA payload spans bits 84..27 (58 bits, gold-ref bit-exact).
        //   top 24 (84..61) = 0011_0111_0000_0100_1100_0000 = 0x3704C0
        //   mid 10 (60..51) = 1001_100000                    = 0x260
        //   bot 24 (50..27) = 0001_0111_1010_0110_1011_0000_10... = 0x5E9AC2
        //   GSSI at bits 51..28 = 0x2F4D61
        check_field({128'd0, pdu_bits_mm},  84,  61, 64'h3704C0,   "mm_gila_top24");
        check_field({128'd0, pdu_bits_mm},  60,  51, 64'h260,      "mm_gila_mid10");
        check_field({128'd0, pdu_bits_mm},  50,  27, 64'h5E9AC2,   "mm_gila_bot24");
        check_field({128'd0, pdu_bits_mm},  51,  28, 64'h2F4D61,   "mm_gila_gssi");
        check_field({128'd0, pdu_bits_mm},  26,  26, 64'h0,        "mm_trailing_mbit");

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
