// =============================================================================
// tb_pre_reply_slotgrant.v — Phase Z.4 Pre-Reply Slot-Grant Mini-FSM regression
//
// Z.4 (dual-path): the FSM switches reply class at runtime based on
// `mm_pdu_type`:
//   mm=2 (LU)  → SCH/F 432-bit via SHARED tetra_dl_pdu_builder
//                (slot_granting_flag=1, sg_element=0x01 — pre-Z.3 cad69e0
//                 working pattern that the MTP3550 in our cell expects).
//   mm=7 (GRP) → SCH/HD 216-bit via INTERNAL mac_resource_dl_builder + sch_hd
//                (slot_granting_flag=1, sg_element=0x00 — Gold-Ref bit-pattern
//                 per reference_gold_group_switch_burst_timeline.md).
//
// Coverage:
//   TC1   reset baseline                — all outputs 0, drop_cnt=0
//   TC2   mm=2 frag1_pulse, ssi=0x282FF4
//         → wr_slotgrant_valid=1 cyc, pdu_type=00 (SCH_F),
//           target_tn=cfg_mcch_tn,
//           coded[431:0] equals reference SCH/F build (bit-exact via
//           parallel tetra_dl_pdu_builder reference instance).
//   TC3   mm=7 frag1_pulse, ssi=0xCAFE42
//         → wr_slotgrant_valid=1 cyc, pdu_type=01 (SCH_HD),
//           target_tn=cfg_mcch_tn,
//           coded[215:0] equals SCH/HD reference (bit-exact via parallel
//           mac_resource_dl_builder PDU_BITS=124 + sch_hd_encoder),
//           coded[431:216]=0,
//           Gold-Bit-Pattern spotcheck on the FIRST 40 bits of the builder
//           PDU (MSB-first):
//              [123:122] PDUtype  = 00
//              [121]     FillBit  = 1
//              [120]     PoG      = 0
//              [119:118] Encr     = 00
//              [117]     RA       = 1
//              [116:111] LI       = 6'd7
//              [110:108] AddrType = 3'b001
//              [107:84]  SSI      = 24'hCAFE42
//              [83]      pc_flag  = 0
//              [82]      sg_flag  = 1
//              [81:74]   sg_elem  = 8'h00
//              [73]      ca_flag  = 0
//              [72:69]   AL-SETUP = 4'b1000
//   TC4   collision drop (mm=2 path) — second frag1_pulse during S_BUILD
//         → drop_cnt += 1
//   TC5   fresh push after busy clears (mm=7 path) — push_cnt monotonic
//
// Run:
//   iverilog -g2001 -I rtl/include -o /tmp/tb_sg \
//          tb/tb_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_pre_reply_slotgrant.v \
//          rtl/lmac/tetra_dl_pdu_builder.v \
//          rtl/lmac/tetra_basic_slotgrant_encoder.v \
//          rtl/lmac/tetra_mac_resource_dl_builder.v \
//          rtl/lmac/tetra_sch_f_encoder.v \
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
    reg  [3:0]  mm_pdu_type       = 4'd0;
    reg  [1:0]  cfg_mcch_tn       = 2'd1;
    reg  [31:0] cfg_scramble_init = 32'd0;  // TB uses 0 so reference encoder matches

    // DUT shared-builder port (mm=2 SCH/F path).  Drive these from the
    // reference tetra_dl_pdu_builder so the DUT actually completes its
    // S_BUILD wait when mm=2.
    wire         dut_sg_build_req_w;
    wire [23:0]  dut_sg_build_ssi_w;
    wire [2:0]   dut_sg_build_addr_type_w;
    wire [3:0]   dut_sg_build_llc_pdu_type_w;
    wire         dut_sg_build_random_access_flag_w;
    wire [127:0] dut_sg_build_mm_pdu_bits_w;
    wire [7:0]   dut_sg_build_mm_pdu_len_bits_w;
    wire [31:0]  dut_sg_build_scramble_init_w;
    wire         dut_dl_pdu_done_w;
    wire [431:0] dut_dl_pdu_coded_w;
    wire         dut_dl_pdu_busy_w;

    // DUT outputs
    wire         wr_slotgrant_valid_sys;
    wire [431:0] wr_slotgrant_coded_sys;
    wire [1:0]   wr_slotgrant_pdu_type_sys;
    wire [1:0]   wr_slotgrant_target_tn_sys;
    wire [15:0]  push_cnt_sys;
    wire [15:0]  drop_cnt_sys;

    tetra_pre_reply_slotgrant dut (
        .clk_sys                            (clk),
        .rst_n_sys                          (rst_n),
        .frag1_pulse                        (frag1_pulse),
        .ul_ssi                             (ul_ssi),
        .mm_pdu_type                        (mm_pdu_type),
        .cfg_mcch_tn                        (cfg_mcch_tn),
        .cfg_scramble_init                  (cfg_scramble_init),
        // Shared SCH/F builder bus
        .slotgrant_build_req                (dut_sg_build_req_w),
        .slotgrant_build_ssi                (dut_sg_build_ssi_w),
        .slotgrant_build_addr_type          (dut_sg_build_addr_type_w),
        .slotgrant_build_llc_pdu_type       (dut_sg_build_llc_pdu_type_w),
        .slotgrant_build_random_access_flag (dut_sg_build_random_access_flag_w),
        .slotgrant_build_mm_pdu_bits        (dut_sg_build_mm_pdu_bits_w),
        .slotgrant_build_mm_pdu_len_bits    (dut_sg_build_mm_pdu_len_bits_w),
        .slotgrant_build_scramble_init      (dut_sg_build_scramble_init_w),
        .slotgrant_build_done               (dut_dl_pdu_done_w),
        .slotgrant_build_coded              (dut_dl_pdu_coded_w),
        .slotgrant_build_grant_blocked      (dut_dl_pdu_busy_w),
        .wr_slotgrant_valid_sys             (wr_slotgrant_valid_sys),
        .wr_slotgrant_coded_sys             (wr_slotgrant_coded_sys),
        .wr_slotgrant_pdu_type_sys          (wr_slotgrant_pdu_type_sys),
        .wr_slotgrant_target_tn_sys         (wr_slotgrant_target_tn_sys),
        .push_cnt_sys                       (push_cnt_sys),
        .drop_cnt_sys                       (drop_cnt_sys)
    );

    // Shared SCH/F builder (used by DUT for mm=2 path, exactly like top.v)
    tetra_dl_pdu_builder u_dut_dl_pdu_builder (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .req_valid              (dut_sg_build_req_w),
        .req_ssi                (dut_sg_build_ssi_w),
        .req_addr_type          (dut_sg_build_addr_type_w),
        .req_llc_pdu_type       (dut_sg_build_llc_pdu_type_w),
        .req_random_access_flag (dut_sg_build_random_access_flag_w),
        .req_mm_pdu_bits        (dut_sg_build_mm_pdu_bits_w),
        .req_mm_pdu_len_bits    (dut_sg_build_mm_pdu_len_bits_w),
        .req_scramble_init      (dut_sg_build_scramble_init_w),
        .req_ns                 (1'b0),
        .req_nr                 (1'b0),
        .done                   (dut_dl_pdu_done_w),
        .coded_bits             (dut_dl_pdu_coded_w),
        .busy                   (dut_dl_pdu_busy_w)
    );

    // -------------------------------------------------------------------------
    // mm=2 reference SCH/F chain — independent tetra_dl_pdu_builder driven
    // separately so we can pre-compute expected 432-bit coded bits.
    // -------------------------------------------------------------------------
    reg          ref_schf_req       = 1'b0;
    reg  [23:0]  ref_schf_ssi       = 24'd0;
    wire         ref_schf_done_w;
    wire [431:0] ref_schf_coded_w;
    wire         ref_schf_busy_w;

    tetra_dl_pdu_builder u_ref_schf (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .req_valid              (ref_schf_req),
        .req_ssi                (ref_schf_ssi),
        .req_addr_type          (3'd1),         // SSI
        .req_llc_pdu_type       (4'd8),         // AL-SETUP
        .req_random_access_flag (1'b1),         // RA
        .req_mm_pdu_bits        (128'd0),
        .req_mm_pdu_len_bits    (8'd0),
        .req_scramble_init      (32'd0),
        .req_ns                 (1'b0),
        .req_nr                 (1'b0),
        .done                   (ref_schf_done_w),
        .coded_bits             (ref_schf_coded_w),
        .busy                   (ref_schf_busy_w)
    );

    // -------------------------------------------------------------------------
    // mm=7 reference SCH/HD chain — mac_resource_dl_builder PDU_BITS=124 +
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
        .slot_granting_flag           (1'b1),       // Gold raw bits flags=010
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

    // -------------------------------------------------------------------------
    // Reference helpers
    // -------------------------------------------------------------------------
    task automatic compute_ref_schhd;
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

    task automatic compute_ref_schf;
        input  [23:0]  s;
        output [431:0] out_coded;
        integer        guard;
        reg [431:0]    cap;
        begin
            ref_schf_ssi <= s;
            ref_schf_req <= 1'b1;
            @(posedge clk);
            ref_schf_req <= 1'b0;

            guard = 0;
            cap   = 432'd0;
            while (!ref_schf_done_w && guard < 4000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            cap = ref_schf_coded_w;
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
                $display("  PASS  %0s  coded[431:408]=0x%06h", tag, got[431:408]);
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
        input [3:0]  mm;
        begin
            ul_ssi      <= s;
            mm_pdu_type <= mm;
            frag1_pulse <= 1'b1;
            @(posedge clk);
            frag1_pulse <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test cases
    // -------------------------------------------------------------------------
    reg [431:0] exp_coded_lu;
    reg [431:0] exp_coded_grp;
    reg [431:0] got_coded_lu;
    reg [431:0] got_coded_grp;
    reg [215:0] ref_coded_grp;
    reg [123:0] ref_info_grp;
    integer hit_a, hit_b, hit_x;

    initial begin
        rst_n       = 1'b0;
        frag1_pulse = 1'b0;
        ul_ssi      = 24'd0;
        mm_pdu_type = 4'd0;
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
        $display("---- TC2 mm=2 SCH/F push, ssi=0x282FF4 ----");
        compute_ref_schf(24'h282FF4, exp_coded_lu);
        @(posedge clk);
        cfg_mcch_tn = 2'd1;

        pulse_frag1(24'h282FF4, 4'd2);
        wait_push(4000, hit_a);
        if (hit_a == 0) begin
            $display("  FAIL  no wr_slotgrant_valid_sys within 4000 cyc (mm=2)");
            fail_cnt = fail_cnt + 1;
        end else begin
            got_coded_lu = wr_slotgrant_coded_sys;
            check_eq2  ("pdu_type=00 (SCH_F)",     wr_slotgrant_pdu_type_sys,  2'd0);
            check_eq2  ("target_tn=cfg_mcch_tn",   wr_slotgrant_target_tn_sys, 2'd1);
            check_eq432("coded[431:0] bit-exact",  got_coded_lu, exp_coded_lu);
            check_eq32 ("push_cnt=1",              {16'd0, push_cnt_sys}, 32'd1);
        end

        // -----------------------------------------------------------------
        $display("---- TC3 mm=7 SCH/HD push, ssi=0xCAFE42 ----");
        compute_ref_schhd(24'hCAFE42, ref_coded_grp, ref_info_grp);
        exp_coded_grp = {216'd0, ref_coded_grp};
        @(posedge clk);
        cfg_mcch_tn = 2'd2;

        // Gold-bit-pattern spot-check on the 124-bit reference info-bits
        $display("  REF-PDU[123:80] = %b", ref_info_grp[123:80]);
        if (ref_info_grp[123:122] === 2'b00) begin
            $display("  PASS  PDUtype=00"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  PDUtype expected 00 got %b", ref_info_grp[123:122]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[121] === 1'b1) begin
            $display("  PASS  FillBit=1"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  FillBit expected 1 got %b", ref_info_grp[121]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[120] === 1'b0) begin
            $display("  PASS  PosOfGrant=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  PosOfGrant expected 0 got %b", ref_info_grp[120]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[119:118] === 2'b00) begin
            $display("  PASS  Encr=00"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  Encr expected 00 got %b", ref_info_grp[119:118]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[117] === 1'b1) begin
            $display("  PASS  RandAccFlag=1"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  RandAccFlag expected 1 got %b", ref_info_grp[117]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[116:111] === 6'd7) begin
            $display("  PASS  LengthInd=7"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  LengthInd expected 7 got %0d", ref_info_grp[116:111]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[110:108] === 3'b001) begin
            $display("  PASS  AddrType=001 (SSI)"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  AddrType expected 001 got %b", ref_info_grp[110:108]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[107:84] === 24'hCAFE42) begin
            $display("  PASS  SSI=0xCAFE42"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  SSI expected CAFE42 got %h", ref_info_grp[107:84]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[83] === 1'b0) begin
            $display("  PASS  pc_flag=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  pc_flag expected 0 got %b", ref_info_grp[83]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[82] === 1'b1) begin
            $display("  PASS  sg_flag=1 (Gold raw bits)"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  sg_flag expected 1 got %b", ref_info_grp[82]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[81:74] === 8'h00) begin
            $display("  PASS  sg_element=0x00 (mm=7 GRP)"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  sg_element expected 0x00 got 0x%h", ref_info_grp[81:74]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[73] === 1'b0) begin
            $display("  PASS  ca_flag=0"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  ca_flag expected 0 got %b", ref_info_grp[73]);
            fail_cnt = fail_cnt + 1;
        end
        if (ref_info_grp[72:69] === 4'b1000) begin
            $display("  PASS  AL-SETUP type=1000"); pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL  AL-SETUP expected 1000 got %b", ref_info_grp[72:69]);
            fail_cnt = fail_cnt + 1;
        end

        // Drive DUT mm=7 path
        pulse_frag1(24'hCAFE42, 4'd7);
        wait_push(4000, hit_b);
        if (hit_b == 0) begin
            $display("  FAIL  no wr_slotgrant_valid_sys within 4000 cyc (mm=7)");
            fail_cnt = fail_cnt + 1;
        end else begin
            got_coded_grp = wr_slotgrant_coded_sys;
            check_eq2  ("pdu_type=01 (SCH_HD)",      wr_slotgrant_pdu_type_sys,  2'd1);
            check_eq2  ("target_tn=cfg_mcch_tn",     wr_slotgrant_target_tn_sys, 2'd2);
            check_eq432("coded[431:0] bit-exact",    got_coded_grp, exp_coded_grp);
            if (got_coded_grp[431:216] === 216'd0) begin
                $display("  PASS  coded[431:216]=0 (LSB-aligned)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  coded[431:216] != 0, got %h", got_coded_grp[431:216]);
                fail_cnt = fail_cnt + 1;
            end
            if (got_coded_lu !== got_coded_grp) begin
                $display("  PASS  mm=2 vs mm=7 → coded payload differs");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  mm=2 vs mm=7 produced identical payloads (regression)");
                fail_cnt = fail_cnt + 1;
            end
            check_eq32 ("push_cnt=2",                {16'd0, push_cnt_sys}, 32'd2);
        end

        // -----------------------------------------------------------------
        $display("---- TC4 collision drop (mm=2 path) ----");
        cfg_mcch_tn = 2'd1;
        pulse_frag1(24'hAA0001, 4'd2);
        repeat (5) @(posedge clk);
        pulse_frag1(24'hBB0002, 4'd2);   // during S_BUILD
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
        $display("---- TC5 fresh push after busy clears (mm=7 path) ----");
        repeat (50) @(posedge clk);
        pulse_frag1(24'h123456, 4'd7);
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
        #20_000_000;
        $display("ERROR: TB watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
