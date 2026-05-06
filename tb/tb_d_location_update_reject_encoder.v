// =============================================================================
// tb_d_location_update_reject_encoder.v — REJECT field-packing tests + MLE-FSM
// integration (Phase Z.5).
//
// Part 1 — standalone encoder field-pack: every reject_cause value lands in
//          [123:121] and pdu_len_bits stays at 8.
//
// Part 2 — Z.5 MLE-FSM integration: stage mb_result=1 (reject-temp), pulse
//          mb_go_pulse, wait for req_valid:
//            - req_pdu_type        == SCH_HD      (= 2'd1)
//            - req_coded[431:216]  == 0           (LSB-aligned in 432-bit slot)
//            - drop_pulse          fired exactly 1 cycle on req_valid edge
//            - accept_pulse        stayed 0 throughout
//          Repeat for mb_result=2 (reject-perm).
//
// Run:
//   iverilog -g2001 -I rtl/include -o /tmp/tb_rej \
//          tb/tb_d_location_update_reject_encoder.v \
//          rtl/lmac/tetra_d_location_update_reject_encoder.v \
//          rtl/lmac/tetra_d_location_update_encoder.v \
//          rtl/lmac/tetra_mle_registration_fsm.v \
//          rtl/lmac/tetra_mac_resource_dl_builder.v \
//          rtl/lmac/tetra_sch_hd_encoder.v
//   vvp /tmp/tb_rej
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_d_location_update_reject_encoder;
    // -------------------------------------------------------------------------
    // Part 1 — standalone encoder
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Part 2 — MLE-FSM integration harness
    // -------------------------------------------------------------------------
    reg          clk    = 1'b0;
    reg          rst_n  = 1'b0;
    always #5 clk = ~clk;

    // Mailbox-pull stimuli
    reg [23:0]  mb_ssi          = 24'h282F91;
    reg [13:0]  mb_la           = 14'h0042;
    reg [2:0]   mb_addr_type    = 3'd1;
    reg [1:0]   mb_result       = 2'd0;
    reg         mb_go_pulse     = 1'b0;
    reg [13:0]  cfg_la          = 14'h0042;
    reg [31:0]  cfg_scramble_init = 32'h0000_0001;
    reg [1:0]   cfg_mcch_tn     = 2'd1;
    reg [13:0]  cfg_energy_saving_info = 14'd0;

    // Builder-shared port stubbed off (REJECT path doesn't touch it).
    wire        accept_build_req_w;
    wire [23:0] accept_build_ssi_w;
    wire [2:0]  accept_build_addr_type_w;
    wire [3:0]  accept_build_llc_pdu_type_w;
    wire        accept_build_random_access_flag_w;
    wire [127:0] accept_build_mm_pdu_bits_w;
    wire [7:0]  accept_build_mm_pdu_len_bits_w;
    wire [31:0] accept_build_scramble_init_w;

    // FSM outputs
    wire         req_valid_w;
    wire [431:0] req_coded_bits_w;
    wire [1:0]   req_pdu_type_w;
    wire [1:0]   req_target_tn_w;
    wire         req_second_pdu_present_w;
    wire         req_second_pdu_nr_w;
    wire         busy_w;
    wire         accept_pulse_w;
    wire         drop_pulse_w;
    wire         ack_pulse_w;
    wire         retransmit_pulse_w;
    wire         lost_pulse_w;
    wire         detach_pulse_w;

    tetra_mle_registration_fsm u_mle (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .ul_req_valid           (1'b0),
        .ul_addr_type           (2'd0),
        .ul_ssi                 (24'd0),
        .ul_la                  (14'd0),
        .ul_loc_upd_type        (3'd0),
        .ul_use_l2sig           (1'b0),
        .ul_llc_is_bl_data      (1'b0),
        .ul_llc_ns_valid        (1'b0),
        .ul_llc_ns              (1'b0),
        .bl_ack_valid           (1'b0),
        .bl_ack_nr              (1'b0),
        .bl_ack_issi            (24'd0),
        .slot_pulse             (1'b0),
        .cfg_la                 (cfg_la),
        .cfg_scramble_init      (cfg_scramble_init),
        .cfg_mcch_tn            (cfg_mcch_tn),
        .cfg_energy_saving_info (cfg_energy_saving_info),
        .ul_detach_valid        (1'b0),
        .ul_detach_ssi          (24'd0),
        .mb_ssi                 (mb_ssi),
        .mb_la                  (mb_la),
        .mb_addr_type           (mb_addr_type),
        .mb_result              (mb_result),
        .mb_gila_gssi           (24'd0),
        .mb_gila_class          (3'd0),
        .mb_gila_lifetime       (2'd0),
        .mb_gila_present        (1'b0),
        .mb_encryption          (2'd0),
        .mb_auth_result         (2'd0),
        .mb_go_pulse            (mb_go_pulse),
        // Phase Y.2 — raw-mode bypass: tied off (mm=2 reject test only).
        .mb_raw_mode_flag       (1'b0),
        .mb_raw_mm_bits         (128'd0),
        .mb_raw_mm_len          (8'd0),
        .mb_raw_ns              (1'b0),
        .mb_raw_nr              (1'b0),
        // accept-path build-bus left dangling (no shared builder in TB)
        .accept_build_req                (accept_build_req_w),
        .accept_build_ssi                (accept_build_ssi_w),
        .accept_build_addr_type          (accept_build_addr_type_w),
        .accept_build_llc_pdu_type       (accept_build_llc_pdu_type_w),
        .accept_build_random_access_flag (accept_build_random_access_flag_w),
        .accept_build_mm_pdu_bits        (accept_build_mm_pdu_bits_w),
        .accept_build_mm_pdu_len_bits    (accept_build_mm_pdu_len_bits_w),
        .accept_build_scramble_init      (accept_build_scramble_init_w),
        .accept_build_ns                 (/* unused */),
        .accept_build_nr                 (/* unused */),
        .accept_build_done               (1'b0),
        .accept_build_coded              (432'd0),
        .req_valid              (req_valid_w),
        .req_coded_bits         (req_coded_bits_w),
        .req_pdu_type           (req_pdu_type_w),
        .req_target_tn          (req_target_tn_w),
        .req_second_pdu_present (req_second_pdu_present_w),
        .req_second_pdu_nr      (req_second_pdu_nr_w),
        .busy                   (busy_w),
        .accept_pulse           (accept_pulse_w),
        .drop_pulse             (drop_pulse_w),
        .ack_pulse              (ack_pulse_w),
        .retransmit_pulse       (retransmit_pulse_w),
        .lost_pulse             (lost_pulse_w),
        .detach_pulse           (detach_pulse_w)
    );

    // Track strobes during a reject build
    integer drop_count;
    integer accept_count;
    integer cyc;

    task automatic stage_reject(input [1:0] result_val,
                                input [255:0] tag);
        begin
            test_count = test_count + 1;
            // Stage mailbox + GO pulse
            @(posedge clk);
            mb_result    <= result_val;
            mb_go_pulse  <= 1'b1;
            @(posedge clk);
            mb_go_pulse  <= 1'b0;
            mb_result    <= 2'd0;

            // Wait for req_valid (REJECT pipeline ~ 487 cycles SCH/HD +
            // a handful of MAC-RES cycles).  Cap at 800 cycles.  drop_pulse
            // and accept_pulse can only fire in S_DELIVER_REJECT and
            // S_DELIVER_ACCEPT respectively — both states that also raise
            // req_valid — so we count them inside the loop and exit on the
            // same cycle req_valid is observed.
            drop_count   = 0;
            accept_count = 0;
            cyc          = 0;
            while (cyc < 800 && req_valid_w === 1'b0) begin
                @(posedge clk);
                if (drop_pulse_w)   drop_count   = drop_count   + 1;
                if (accept_pulse_w) accept_count = accept_count + 1;
                cyc = cyc + 1;
            end

            if (req_valid_w !== 1'b1) begin
                $display("[T%0d] FAIL %0s — req_valid never asserted in %0d cycles",
                         test_count, tag, cyc);
                fail_count = fail_count + 1;
            end else begin

                if (req_pdu_type_w !== 2'd1) begin
                    $display("[T%0d] FAIL %0s — req_pdu_type got=%0d exp=1 (SCH_HD)",
                             test_count, tag, req_pdu_type_w);
                    fail_count = fail_count + 1;
                end else if (req_coded_bits_w[431:216] !== 216'd0) begin
                    $display("[T%0d] FAIL %0s — req_coded[431:216] not LSB-aligned",
                             test_count, tag);
                    fail_count = fail_count + 1;
                end else if (req_coded_bits_w[215:0] === 216'd0) begin
                    $display("[T%0d] FAIL %0s — req_coded[215:0] is all-zero, encoder didn't run",
                             test_count, tag);
                    fail_count = fail_count + 1;
                end else if (drop_count !== 1) begin
                    $display("[T%0d] FAIL %0s — drop_pulse fired %0d times (exp 1)",
                             test_count, tag, drop_count);
                    fail_count = fail_count + 1;
                end else if (accept_count !== 0) begin
                    $display("[T%0d] FAIL %0s — accept_pulse fired %0d times (exp 0)",
                             test_count, tag, accept_count);
                    fail_count = fail_count + 1;
                end else if (req_target_tn_w !== cfg_mcch_tn) begin
                    $display("[T%0d] FAIL %0s — req_target_tn got=%0d exp=%0d",
                             test_count, tag, req_target_tn_w, cfg_mcch_tn);
                    fail_count = fail_count + 1;
                end else begin
                    $display("[T%0d] PASS %0s — pdu_type=SCH_HD, drop=1, coded[431:216]=0, took %0d cyc",
                             test_count, tag, cyc);
                end
            end
            // Allow FSM to return to IDLE before next stimulus.
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_d_location_update_reject_encoder.vcd");
        $dumpvars(0, tb_d_location_update_reject_encoder);

        // ---- Part 1: standalone encoder ----
        reject_cause = 3'd0; #1;  // ITSI unknown
        check(127, 124, 64'h7,   "pdu_type_reject");
        check(123, 121, 64'h0,   "cause_itsi_unknown");
        check(120, 120, 64'h0,   "obit_zero");
        test_count = test_count + 1;
        if (pdu_len_bits !== 8'd8) begin
            $display("[T%0d] FAIL pdu_len got=%0d exp=8", test_count, pdu_len_bits);
            fail_count = fail_count + 1;
        end else $display("[T%0d] PASS pdu_len = %0d", test_count, pdu_len_bits);

        reject_cause = 3'd4; #1;
        check(123, 121, 64'h4, "cause_service_not_authorised");

        reject_cause = 3'd2; #1;
        check(123, 121, 64'h2, "cause_no_resources");

        reject_cause = 3'd7; #1;
        check(123, 121, 64'h7, "cause_forbidden_la");

        reject_cause = 3'd5; #1;
        check(119,   0, 64'h0, "padding_zero");

        // ---- Part 2: MLE-FSM integration ----
        // De-assert + assert reset
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        stage_reject(2'd1, "reject_temp_via_mle_fsm");
        stage_reject(2'd2, "reject_perm_via_mle_fsm");

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
