// =============================================================================
// tb_d_location_update_encoder.v — unit test for MM-Body field packing.
//
// Phase X.7 — Legacy 124-bit pdu_bits output removed from the encoder; the
// regression set is now MM-body-only.  All preserved tests are the M2 bit-
// identity / gold-reference checks against the 102-bit Accept layout.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_d_location_update_encoder;
    reg         pdu_reject = 0;
    reg  [13:0] energy_saving_info = 14'h0000;
    reg  [2:0]  loc_acc_type = 3'd0;
    // Phase 6 D-rev — dynamic GILA inputs (default M2 values).
    reg  [23:0] gila_gssi     = 24'h2F4D61;
    reg  [2:0]  gila_class    = 3'b100;  // = 4
    reg  [1:0]  gila_lifetime = 2'b01;   // = 1
    reg         gila_present  = 1'b1;
    wire [127:0] pdu_bits_mm;
    wire [7:0]   pdu_len_bits;

    tetra_d_location_update_encoder dut (
        .pdu_reject        (pdu_reject),
        .energy_saving_info(energy_saving_info),
        .loc_acc_type      (loc_acc_type),
        .gila_gssi         (gila_gssi),
        .gila_class        (gila_class),
        .gila_lifetime     (gila_lifetime),
        .gila_present      (gila_present),
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

        // ----- Test 1: MM wrapper output — bit-exact gold-reference Accept
        // (102 bit MM body): p_ssi=0, p_ae=0, p_sc=0, p_esi=1+ESI(StayAlive),
        // p_scch=0, type-3 GroupIdentityLocationAccept with hard-coded gold
        // GILA payload (length=58).
        loc_acc_type       = 3'b011;          // ITSI attach
        energy_saving_info = 14'h0000;        // StayAlive
        gila_gssi          = 24'h2F4D61;
        gila_class         = 3'b100;          // = 4
        gila_lifetime      = 2'b01;           // = 1
        gila_present       = 1'b1;
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

        // ----- Test 2: GILA-absent path (gila_present=0) — MM body shrinks
        // to 36 bits, m-bit at [100] clears.  pdu_len_bits drops to 36.
        gila_present = 1'b0;
        #1;
        test_count = test_count + 1;
        if (pdu_len_bits !== 8'd36) begin
            $display("[T%0d] FAIL mm_len_no_gila got=%0d exp=36", test_count, pdu_len_bits);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d] PASS mm_len_no_gila = %0d", test_count, pdu_len_bits);
        end
        check_field({128'd0, pdu_bits_mm}, 127, 124, 64'h5,        "mm_no_gila_pdu_type");
        check_field({128'd0, pdu_bits_mm}, 100, 100, 64'h0,        "mm_no_gila_m_bit_clear");
        check_field({128'd0, pdu_bits_mm},  99,  99, 64'h0,        "mm_no_gila_trailing_mbit");
        gila_present = 1'b1;

        // ----- Test 3: REJECT path — pdu_reject=1 flips PDU type to 0111.
        pdu_reject = 1'b1;
        #1;
        check_field({128'd0, pdu_bits_mm}, 127, 124, 64'h7,        "mm_pdu_type_reject");
        // GILA payload itself unchanged (encoder doesn't gate on pdu_reject
        // — the REJECT-with-GILA case is rare but must remain bit-stable).
        check_field({128'd0, pdu_bits_mm},  51,  28, 64'h2F4D61,   "mm_reject_gila_gssi");
        pdu_reject = 1'b0;

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
