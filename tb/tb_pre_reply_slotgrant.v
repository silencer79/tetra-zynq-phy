// =============================================================================
// tb_pre_reply_slotgrant.v — Phase X.6 Pre-Reply Slot-Grant Mini-FSM regression
//
// X.6 (slice-saver refactor): the FSM no longer instantiates the
// {basic_slotgrant_encoder + mac_resource_dl_builder + sch_f_encoder}
// triple — those are now in tetra_dl_pdu_builder.v shared with the
// MLE-FSM via a top-level arbiter.  This TB instantiates the shared
// builder externally (no arbiter needed in TB — only one consumer) and
// verifies bit-identity against an independent reference chain that
// drives parallel instances of the same encoders with identical inputs.
// =============================================================================
//
// Coverage:
//   TC1  reset baseline                — all outputs 0, drop_cnt=0
//   TC2  frag1_pulse with ssi=0x282F91 → wr_slotgrant_valid pulses 1 cyc,
//        wr_slotgrant_pdu_type=00 (SCH_F), target_tn=cfg_mcch_tn,
//        wr_slotgrant_coded[431:0] equals SCH/F-encoded MAC-RESOURCE
//        AL-SETUP+slot_grant (bit-exact via reference chain in parallel)
//   TC3  frag1_pulse with ssi=0xCAFE42 → fresh push, different coded bits
//        (sanity: SSI swap propagates), push_cnt += 1
//   TC4  collision drop: trigger second frag1_pulse while pipeline busy
//        in S_REQ/S_WAIT → drop_cnt += 1
//   TC5  push_cnt monotonic: after 4 successful pushes (TC2..TC5) push_cnt>=4
//
// Run:
//   iverilog -g2001 -o /tmp/tb_sg tb/tb_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_dl_pdu_builder.v \
//          rtl/lmac/tetra_basic_slotgrant_encoder.v \
//          rtl/lmac/tetra_mac_resource_dl_builder.v \
//          rtl/lmac/tetra_sch_f_encoder.v
//   vvp /tmp/tb_sg
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pre_reply_slotgrant;
    reg         clk    = 1'b0;
    reg         rst_n  = 1'b0;
    always #5 clk = ~clk;

    // DUT inputs
    reg         frag1_pulse       = 1'b0;
    reg  [23:0] ul_ssi            = 24'd0;
    reg  [1:0]  cfg_mcch_tn       = 2'd1;
    reg  [31:0] cfg_scramble_init = 32'd0;  // TB uses 0 so reference encoder matches

    // DUT outputs
    wire         wr_slotgrant_valid_sys;
    wire [431:0] wr_slotgrant_coded_sys;
    wire [1:0]   wr_slotgrant_pdu_type_sys;
    wire [1:0]   wr_slotgrant_target_tn_sys;
    wire [15:0]  push_cnt_sys;
    wire [15:0]  drop_cnt_sys;

    // Build-request wires from DUT to shared builder
    wire         sg_build_req_w;
    wire [23:0]  sg_build_ssi_w;
    wire [2:0]   sg_build_addr_type_w;
    wire [3:0]   sg_build_llc_pdu_type_w;
    wire         sg_build_random_access_flag_w;
    wire [127:0] sg_build_mm_pdu_bits_w;
    wire [7:0]   sg_build_mm_pdu_len_bits_w;
    wire [31:0]  sg_build_scramble_init_w;

    // Shared builder outputs
    wire         dl_pdu_done_w;
    wire [431:0] dl_pdu_coded_w;
    wire         dl_pdu_busy_w;

    // TB has only one consumer — grant_blocked tied to busy.
    wire         sg_blocked_w = dl_pdu_busy_w;

    tetra_pre_reply_slotgrant dut (
        .clk_sys                  (clk),
        .rst_n_sys                (rst_n),
        .frag1_pulse              (frag1_pulse),
        .ul_ssi                   (ul_ssi),
        .cfg_mcch_tn              (cfg_mcch_tn),
        .cfg_scramble_init        (cfg_scramble_init),
        .slotgrant_build_req                (sg_build_req_w),
        .slotgrant_build_ssi                (sg_build_ssi_w),
        .slotgrant_build_addr_type          (sg_build_addr_type_w),
        .slotgrant_build_llc_pdu_type       (sg_build_llc_pdu_type_w),
        .slotgrant_build_random_access_flag (sg_build_random_access_flag_w),
        .slotgrant_build_mm_pdu_bits        (sg_build_mm_pdu_bits_w),
        .slotgrant_build_mm_pdu_len_bits    (sg_build_mm_pdu_len_bits_w),
        .slotgrant_build_scramble_init      (sg_build_scramble_init_w),
        .slotgrant_build_done               (dl_pdu_done_w),
        .slotgrant_build_coded              (dl_pdu_coded_w),
        .slotgrant_build_grant_blocked      (sg_blocked_w),
        .wr_slotgrant_valid_sys   (wr_slotgrant_valid_sys),
        .wr_slotgrant_coded_sys   (wr_slotgrant_coded_sys),
        .wr_slotgrant_pdu_type_sys(wr_slotgrant_pdu_type_sys),
        .wr_slotgrant_target_tn_sys(wr_slotgrant_target_tn_sys),
        .push_cnt_sys             (push_cnt_sys),
        .drop_cnt_sys             (drop_cnt_sys)
    );

    // Shared builder (single-consumer in TB).
    tetra_dl_pdu_builder u_dl_pdu_builder (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .req_valid              (sg_build_req_w),
        .req_ssi                (sg_build_ssi_w),
        .req_addr_type          (sg_build_addr_type_w),
        .req_llc_pdu_type       (sg_build_llc_pdu_type_w),
        .req_random_access_flag (sg_build_random_access_flag_w),
        .req_mm_pdu_bits        (sg_build_mm_pdu_bits_w),
        .req_mm_pdu_len_bits    (sg_build_mm_pdu_len_bits_w),
        .req_scramble_init      (sg_build_scramble_init_w),
        .done                   (dl_pdu_done_w),
        .coded_bits             (dl_pdu_coded_w),
        .busy                   (dl_pdu_busy_w)
    );

    // -------------------------------------------------------------------------
    // Reference encoder chain — same parameters as DUT-builder, driven from a
    // separate ref_start so we can pre-compute expected coded bits for any SSI
    // before kicking the DUT.  This is the "independent" path — bit-identity
    // failures here would catch a builder regression.
    // -------------------------------------------------------------------------
    reg          ref_builder_start = 1'b0;
    reg  [23:0]  ref_ssi           = 24'd0;

    wire [7:0]   ref_sg_w;
    tetra_basic_slotgrant_encoder u_ref_sg (
        .capacity_allocation (4'd0),
        .granting_delay      (4'd1),
        .packed_element      (ref_sg_w)
    );

    wire [267:0] ref_pdu_w;
    wire         ref_pdu_valid_w;
    tetra_mac_resource_dl_builder #(
        .PDU_BITS(268),
        .LLC_BUF_BITS(144)
    ) u_ref_mac (
        .clk                          (clk),
        .rst_n                        (rst_n),
        .start                        (ref_builder_start),
        .ssi                          (ref_ssi),
        .addr_type                    (3'd1),
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (4'd8),
        .random_access_flag           (1'b1),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        .slot_granting_flag           (1'b1),
        .slot_granting_element        (ref_sg_w),
        .chan_alloc_flag              (1'b0),
        .chan_alloc_element           (32'd0),
        .chan_alloc_element_len       (5'd0),
        .second_pdu_valid             (1'b0),
        .second_pdu_length_ind        (6'd0),
        .second_pdu_random_access_flag(1'b0),
        .second_pdu_addr_type         (3'd0),
        .second_pdu_ssi               (24'd0),
        .second_pdu_tl_sdu            (80'd0),
        .second_pdu_tl_sdu_len        (7'd0),
        .second_pdu_pc_flag           (1'b0),
        .second_pdu_pc_element        (4'd0),
        .second_pdu_sg_flag           (1'b0),
        .second_pdu_sg_element        (8'd0),
        .second_pdu_ca_flag           (1'b0),
        .second_pdu_ca_element        (32'd0),
        .second_pdu_ca_element_len    (5'd0),
        .mm_pdu_bits                  (128'd0),
        .mm_pdu_len_bits              (8'd0),
        .pdu_bits                     (ref_pdu_w),
        .valid                        (ref_pdu_valid_w)
    );

    reg          ref_enc_start = 1'b0;
    reg  [267:0] ref_enc_info  = 268'd0;
    wire [431:0] ref_coded_w;
    wire         ref_coded_valid_w;
    tetra_sch_f_encoder u_ref_sch_f (
        .clk           (clk),
        .rst_n         (rst_n),
        .encode_start  (ref_enc_start),
        .info_bits     (ref_enc_info),
        .scramble_init (32'd0),
        .coded_bits    (ref_coded_w),
        .coded_valid   (ref_coded_valid_w)
    );

    // Build the reference SCH/F-coded 432-bit payload for `s` and store in
    // `out_coded`.  Blocking task in TB context.
    task automatic compute_ref;
        input  [23:0]  s;
        output [431:0] out_coded;
        integer        guard;
        reg [431:0]    cap;
        reg [267:0]    cap_pdu;
        begin
            // Drive SSI into ref builder, pulse start
            ref_ssi           <= s;
            ref_builder_start <= 1'b1;
            @(posedge clk);
            ref_builder_start <= 1'b0;

            // Wait for builder valid (max ~20 cyc)
            guard = 0;
            while (!ref_pdu_valid_w && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
            // Capture PDU and trigger encoder one cycle later
            cap_pdu = ref_pdu_w;
            @(posedge clk);
            ref_enc_info  <= cap_pdu;
            ref_enc_start <= 1'b1;
            @(posedge clk);
            ref_enc_start <= 1'b0;

            // Wait for encoder valid (~991 cyc per encoder header)
            guard = 0;
            cap   = 432'd0;
            while (!ref_coded_valid_w && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            cap = ref_coded_w;
            @(posedge clk);
            out_coded = cap;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test bookkeeping
    // -------------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer guard_i;

    task automatic check_eq32;
        input [255:0] tag;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  %0s  got=0x%08h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0x%08h  exp=0x%08h", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic check_eq2;
        input [255:0] tag;
        input [1:0]   got;
        input [1:0]   exp;
        begin
            if (got === exp) begin
                $display("  PASS  %0s  got=0b%02b", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0b%02b  exp=0b%02b", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic check_eq432;
        input [255:0]  tag;
        input [431:0]  got;
        input [431:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  %0s  coded[431:400]=0x%08h", tag, got[431:400]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s", tag);
                $display("    got[431:288]= %h", got[431:288]);
                $display("    exp[431:288]= %h", exp[431:288]);
                $display("    got[287:144]= %h", got[287:144]);
                $display("    exp[287:144]= %h", exp[287:144]);
                $display("    got[143:0]  = %h", got[143:0]);
                $display("    exp[143:0]  = %h", exp[143:0]);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Wait until wr_slotgrant_valid_sys asserts (or timeout)
    task automatic wait_push;
        input integer max_cyc;
        output integer hit;
        begin
            hit = 0;
            for (guard_i = 0; guard_i < max_cyc; guard_i = guard_i + 1) begin
                @(posedge clk);
                if (wr_slotgrant_valid_sys) begin
                    hit = 1;
                    disable wait_push;
                end
            end
        end
    endtask

    // Pulse frag1_pulse for 1 cycle with given SSI
    task automatic pulse_frag1;
        input [23:0] s;
        begin
            ul_ssi      <= s;
            frag1_pulse <= 1'b1;
            @(posedge clk);
            frag1_pulse <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test cases
    // -------------------------------------------------------------------------
    reg [431:0] exp_coded_a;
    reg [431:0] exp_coded_b;
    reg [431:0] got_coded_a;
    reg [431:0] got_coded_b;
    integer hit_a, hit_b, hit_x;

    initial begin
        // Reset
        rst_n       = 1'b0;
        frag1_pulse = 1'b0;
        ul_ssi      = 24'd0;
        cfg_mcch_tn = 2'd1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -----------------------------------------------------------------
        $display("---- TC1 reset baseline ----");
        check_eq32("push_cnt=0", {16'd0, push_cnt_sys}, 32'd0);
        check_eq32("drop_cnt=0", {16'd0, drop_cnt_sys}, 32'd0);
        if (wr_slotgrant_valid_sys === 1'b0) begin
            $display("  PASS  wr_slotgrant_valid_sys=0");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  wr_slotgrant_valid_sys=%b", wr_slotgrant_valid_sys);
            fail_cnt = fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        $display("---- TC2 single push, ssi=0x282F91 ----");
        compute_ref(24'h282F91, exp_coded_a);
        @(posedge clk);
        cfg_mcch_tn = 2'd1;

        pulse_frag1(24'h282F91);
        wait_push(4000, hit_a);
        if (hit_a == 0) begin
            $display("  FAIL  no wr_slotgrant_valid_sys within 4000 cyc");
            fail_cnt = fail_cnt + 1;
        end else begin
            got_coded_a = wr_slotgrant_coded_sys;
            check_eq2 ("pdu_type=00 (SCH_F)",        wr_slotgrant_pdu_type_sys,  2'd0);
            check_eq2 ("target_tn=cfg_mcch_tn",      wr_slotgrant_target_tn_sys, 2'd1);
            check_eq432("coded[431:0] bit-exact",    got_coded_a, exp_coded_a);
            check_eq32 ("push_cnt=1",                {16'd0, push_cnt_sys}, 32'd1);
        end

        // -----------------------------------------------------------------
        $display("---- TC3 second push, ssi=0xCAFE42 ----");
        compute_ref(24'hCAFE42, exp_coded_b);
        @(posedge clk);
        cfg_mcch_tn = 2'd2;
        pulse_frag1(24'hCAFE42);
        wait_push(4000, hit_b);
        if (hit_b == 0) begin
            $display("  FAIL  no wr_slotgrant_valid_sys within 4000 cyc");
            fail_cnt = fail_cnt + 1;
        end else begin
            got_coded_b = wr_slotgrant_coded_sys;
            check_eq2 ("target_tn=2",             wr_slotgrant_target_tn_sys, 2'd2);
            check_eq432("coded[431:0] bit-exact", got_coded_b, exp_coded_b);
            check_eq32 ("push_cnt=2",             {16'd0, push_cnt_sys}, 32'd2);
            if (got_coded_a !== got_coded_b) begin
                $display("  PASS  SSI swap ⇒ coded payload differs");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  SSI swap did NOT change coded payload");
                fail_cnt = fail_cnt + 1;
            end
        end

        // -----------------------------------------------------------------
        $display("---- TC4 collision drop ----");
        // First pulse, then second during busy → drop_cnt should increment
        cfg_mcch_tn = 2'd1;
        pulse_frag1(24'hAA0001);
        repeat (5) @(posedge clk);
        pulse_frag1(24'hBB0002);   // during S_REQ/S_WAIT
        wait_push(4000, hit_x);
        if (hit_x == 0) begin
            $display("  FAIL  busy-mode first push never delivered");
            fail_cnt = fail_cnt + 1;
        end else begin
            if (drop_cnt_sys >= 16'd1) begin
                $display("  PASS  drop_cnt incremented to %0d", drop_cnt_sys);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  drop_cnt did NOT increment, got=%0d", drop_cnt_sys);
                fail_cnt = fail_cnt + 1;
            end
        end

        // -----------------------------------------------------------------
        $display("---- TC5 fresh push after busy clears ----");
        repeat (50) @(posedge clk);
        pulse_frag1(24'h123456);
        wait_push(4000, hit_x);
        if (hit_x == 1) begin
            $display("  PASS  fresh push delivered after IDLE recovery");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  fresh push not delivered");
            fail_cnt = fail_cnt + 1;
        end
        if (push_cnt_sys >= 16'd4) begin
            $display("  PASS  push_cnt=%0d (>=4)", push_cnt_sys);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  push_cnt=%0d (<4)", push_cnt_sys);
            fail_cnt = fail_cnt + 1;
        end

        // -----------------------------------------------------------------
        $display("================================================");
        $display(" PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display(" RESULT: ALL TESTS PASS");
        else               $display(" RESULT: FAILURES PRESENT");
        $display("================================================");
        $finish;
    end

    // Safety watchdog
    initial begin
        #10_000_000;
        $display("ERROR: TB watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
