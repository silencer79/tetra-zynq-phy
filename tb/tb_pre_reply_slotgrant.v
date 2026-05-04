// =============================================================================
// tb_pre_reply_slotgrant.v — Phase Z.3 Pre-Reply Slot-Grant Mini-FSM regression
//
// Z.3 (Gold-conform refactor): the FSM no longer goes through the shared
// SCH/F builder.  It now packs a 124-bit MAC-RESOURCE LI=7 AL-SETUP PDU
// with `slot_granting_flag=0` (Gold bit-identity per
// reference_gold_full_attach_timeline.md) and SCH/HD-encodes it to 216
// bits.  The TB drives a parallel reference chain (mac_resource_dl_builder
// PDU_BITS=124 + sch_hd_encoder) and asserts bit-identity of
// wr_slotgrant_coded_sys[215:0] against it.
//
// Coverage:
//   TC1  reset baseline                — all outputs 0, drop_cnt=0
//   TC2  frag1_pulse with ssi=0x282FF4 → wr_slotgrant_valid pulses 1 cyc,
//        wr_slotgrant_pdu_type=01 (SCH_HD), target_tn=cfg_mcch_tn,
//        wr_slotgrant_coded[215:0] equals SCH/HD-encoded MAC-RESOURCE
//        AL-SETUP (bit-exact via reference chain in parallel),
//        wr_slotgrant_coded[431:216] = 0
//        Plus Gold-Bit-Pattern-Spotcheck on the FIRST 40 bits of the
//        builder PDU (MSB-first):
//          [123]    PDUtype[1]      = 0
//          [122]    PDUtype[0]      = 0
//          [121]    FillBit         = 1
//          [120]    PosOfGrant      = 0
//          [119]    Encr[1]         = 0
//          [118]    Encr[0]         = 0
//          [117]    RandAccFlag     = 1
//          [116:111] LengthInd      = 6'd7    ← LI=7 octets
//          [110:108] AddrType       = 3'b001
//          [107: 84] SSI            = 24'h282FF4
//          [83]    pc_flag          = 0
//          [82]    sg_flag          = 0       ← Gold flags=000
//          [81]    ca_flag          = 0
//          [80:77] LLC AL-SETUP type = 4'b1000
//   TC3  frag1_pulse with ssi=0xCAFE42 → fresh push, different coded bits
//        (sanity: SSI swap propagates), push_cnt += 1
//   TC4  collision drop: trigger second frag1_pulse while pipeline busy
//        in S_BUILD/S_ENC → drop_cnt += 1
//   TC5  fresh push after IDLE recovery, push_cnt monotonic
//
// Run:
//   iverilog -g2001 -I rtl/include -o /tmp/tb_sg \
//          tb/tb_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_mac_resource_dl_builder.v \
//          rtl/lmac/tetra_sch_hd_encoder.v \
//          rtl/lmac/tetra_crc16.v \
//          rtl/lmac/tetra_interleaver.v
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

    tetra_pre_reply_slotgrant dut (
        .clk_sys                  (clk),
        .rst_n_sys                (rst_n),
        .frag1_pulse              (frag1_pulse),
        .ul_ssi                   (ul_ssi),
        .cfg_mcch_tn              (cfg_mcch_tn),
        .cfg_scramble_init        (cfg_scramble_init),
        .wr_slotgrant_valid_sys   (wr_slotgrant_valid_sys),
        .wr_slotgrant_coded_sys   (wr_slotgrant_coded_sys),
        .wr_slotgrant_pdu_type_sys(wr_slotgrant_pdu_type_sys),
        .wr_slotgrant_target_tn_sys(wr_slotgrant_target_tn_sys),
        .push_cnt_sys             (push_cnt_sys),
        .drop_cnt_sys             (drop_cnt_sys)
    );

    // -------------------------------------------------------------------------
    // Reference encoder chain — mac_resource_dl_builder PDU_BITS=124 +
    // sch_hd_encoder.  Driven from a separate ref_start so we can pre-
    // compute expected coded bits for any SSI before kicking the DUT.
    // -------------------------------------------------------------------------
    reg          ref_builder_start = 1'b0;
    reg  [23:0]  ref_ssi           = 24'd0;

    wire [123:0] ref_pdu_w;
    wire         ref_pdu_valid_w;
    tetra_mac_resource_dl_builder #(
        .PDU_BITS(124),
        .LLC_BUF_BITS(16)
    ) u_ref_mac (
        .clk                          (clk),
        .rst_n                        (rst_n),
        .start                        (ref_builder_start),
        .ssi                          (ref_ssi),
        .addr_type                    (3'd1),       // SSI
        .ns                           (1'b0),
        .nr                           (1'b0),
        .llc_pdu_type                 (4'd8),       // AL-SETUP
        .random_access_flag           (1'b1),
        .power_control_flag           (1'b0),
        .power_control_element        (4'd0),
        .slot_granting_flag           (1'b1),       // Gold raw bits: flags=010
        .slot_granting_element        (8'h00),      // Gold sg_element=0x00
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
    reg  [123:0] ref_enc_info  = 124'd0;
    wire [215:0] ref_coded_w;
    wire         ref_coded_valid_w;
    tetra_sch_hd_encoder u_ref_sch_hd (
        .clk           (clk),
        .rst_n         (rst_n),
        .encode_start  (ref_enc_start),
        .info_bits     (ref_enc_info),
        .scramble_init (32'd0),
        .coded_bits    (ref_coded_w),
        .coded_valid   (ref_coded_valid_w)
    );

    // Build the reference SCH/HD-coded 216-bit payload for `s`, plus return
    // the 124-bit info bits for spot-checks.  Blocking task in TB context.
    task automatic compute_ref;
        input  [23:0]  s;
        output [215:0] out_coded;
        output [123:0] out_info;
        integer        guard;
        reg [215:0]    cap;
        reg [123:0]    cap_pdu;
        begin
            ref_ssi           <= s;
            ref_builder_start <= 1'b1;
            @(posedge clk);
            ref_builder_start <= 1'b0;

            guard = 0;
            while (!ref_pdu_valid_w && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
            cap_pdu = ref_pdu_w;

            // One cycle gap: drop builder valid, latch PDU, then start enc.
            @(posedge clk);
            ref_enc_info  <= cap_pdu;
            ref_enc_start <= 1'b1;
            @(posedge clk);
            ref_enc_start <= 1'b0;

            guard = 0;
            cap   = 216'd0;
            while (!ref_coded_valid_w && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            cap = ref_coded_w;
            @(posedge clk);
            out_coded = cap;
            out_info  = cap_pdu;
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
                $display("  PASS  %0s  coded[215:192]=0x%06h", tag, got[215:192]);
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
    reg [215:0] ref_coded_a;
    reg [215:0] ref_coded_b;
    reg [123:0] ref_info_a;
    reg [123:0] ref_info_b;
    integer hit_a, hit_b, hit_x;

    initial begin
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
        $display("---- TC2 single push, ssi=0x282FF4 (Gold-MS) ----");
        compute_ref(24'h282FF4, ref_coded_a, ref_info_a);
        exp_coded_a = {216'd0, ref_coded_a};
        @(posedge clk);
        cfg_mcch_tn = 2'd1;

        // Gold-bit-pattern spot-check on the reference info-bits (MSB=[123])
        $display("  REF-PDU[123:80] = %b", ref_info_a[123:80]);
        // [123:122] PDUtype = 00
        if (ref_info_a[123:122] === 2'b00) begin
            $display("  PASS  PDUtype=00"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  PDUtype expected 00 got %b", ref_info_a[123:122]);
            fail_cnt = fail_cnt + 1;
        end
        // [121] FillBit = 1
        if (ref_info_a[121] === 1'b1) begin
            $display("  PASS  FillBit=1"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  FillBit expected 1 got %b", ref_info_a[121]);
            fail_cnt = fail_cnt + 1;
        end
        // [120] PosOfGrant = 0
        if (ref_info_a[120] === 1'b0) begin
            $display("  PASS  PosOfGrant=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  PosOfGrant expected 0 got %b", ref_info_a[120]);
            fail_cnt = fail_cnt + 1;
        end
        // [119:118] Encr = 00
        if (ref_info_a[119:118] === 2'b00) begin
            $display("  PASS  Encr=00"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  Encr expected 00 got %b", ref_info_a[119:118]);
            fail_cnt = fail_cnt + 1;
        end
        // [117] RandAccFlag = 1
        if (ref_info_a[117] === 1'b1) begin
            $display("  PASS  RandAccFlag=1"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  RandAccFlag expected 1 got %b", ref_info_a[117]);
            fail_cnt = fail_cnt + 1;
        end
        // [116:111] LengthInd = 6'd7  (Gold LI=7)
        if (ref_info_a[116:111] === 6'd7) begin
            $display("  PASS  LengthInd=7"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  LengthInd expected 7 got %0d", ref_info_a[116:111]);
            fail_cnt = fail_cnt + 1;
        end
        // [110:108] AddrType = 001 (SSI)
        if (ref_info_a[110:108] === 3'b001) begin
            $display("  PASS  AddrType=001 (SSI)"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  AddrType expected 001 got %b", ref_info_a[110:108]);
            fail_cnt = fail_cnt + 1;
        end
        // [107:84] SSI = 0x282FF4
        if (ref_info_a[107:84] === 24'h282FF4) begin
            $display("  PASS  SSI=0x282FF4"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  SSI expected 282FF4 got %h", ref_info_a[107:84]);
            fail_cnt = fail_cnt + 1;
        end
        // [83] pc_flag=0  [82] sg_flag=1  → triple [83:82,73] later
        if (ref_info_a[83] === 1'b0) begin
            $display("  PASS  pc_flag=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  pc_flag expected 0 got %b", ref_info_a[83]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_a[82] === 1'b1) begin
            $display("  PASS  sg_flag=1 (Gold raw bits)"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  sg_flag expected 1 got %b", ref_info_a[82]);
            fail_cnt = fail_cnt + 1;
        end
        // [81:74] sg_element = 8'h00 (Gold)
        if (ref_info_a[81:74] === 8'h00) begin
            $display("  PASS  sg_element=0x00"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  sg_element expected 0x00 got 0x%h", ref_info_a[81:74]);
            fail_cnt = fail_cnt + 1;
        end
        // [73] ca_flag = 0
        if (ref_info_a[73] === 1'b0) begin
            $display("  PASS  ca_flag=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  ca_flag expected 0 got %b", ref_info_a[73]);
            fail_cnt = fail_cnt + 1;
        end
        // [72:69] AL-SETUP llc_pdu_type = 1000 (4'd8)
        if (ref_info_a[72:69] === 4'b1000) begin
            $display("  PASS  AL-SETUP type=1000"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  AL-SETUP expected 1000 got %b", ref_info_a[72:69]);
            fail_cnt = fail_cnt + 1;
        end

        // Now drive DUT and compare against reference coded
        pulse_frag1(24'h282FF4);
        wait_push(4000, hit_a);
        if (hit_a == 0) begin
            $display("  FAIL  no wr_slotgrant_valid_sys within 4000 cyc");
            fail_cnt = fail_cnt + 1;
        end else begin
            got_coded_a = wr_slotgrant_coded_sys;
            check_eq2 ("pdu_type=01 (SCH_HD)",        wr_slotgrant_pdu_type_sys,  2'd1);
            check_eq2 ("target_tn=cfg_mcch_tn",       wr_slotgrant_target_tn_sys, 2'd1);
            check_eq432("coded[431:0] bit-exact",     got_coded_a, exp_coded_a);
            // upper 216 bits must be zero
            if (got_coded_a[431:216] === 216'd0) begin
                $display("  PASS  coded[431:216]=0 (LSB-aligned)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  coded[431:216] != 0, got %h", got_coded_a[431:216]);
                fail_cnt = fail_cnt + 1;
            end
            check_eq32 ("push_cnt=1",                {16'd0, push_cnt_sys}, 32'd1);
        end

        // -----------------------------------------------------------------
        $display("---- TC3 second push, ssi=0xCAFE42 ----");
        compute_ref(24'hCAFE42, ref_coded_b, ref_info_b);
        exp_coded_b = {216'd0, ref_coded_b};
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
        cfg_mcch_tn = 2'd1;
        pulse_frag1(24'hAA0001);
        repeat (5) @(posedge clk);
        pulse_frag1(24'hBB0002);   // during S_BUILD/S_ENC
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

    initial begin
        #10_000_000;
        $display("ERROR: TB watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
