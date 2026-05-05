// =============================================================================
// tb_tetra_aach_rm_encoder.v — Phase Z.12 cross-check
//
// Verifies that the new combinational standalone tetra_aach_rm_encoder
// produces bit-identical outputs to the existing tetra_aach_encoder for
// every (info, lfsr_init) pair we care about.
//
// We drive both encoders with the same {info, mcc, mnc, cc} tuple and
// compare aach_coded after the FSM-based encoder finishes its 33-cycle
// run.  The combinational module produces its result in 0 cycles.
//
// Test set (mirrors tb_tetra_aach_encoder.v Z.12-relevant TCs):
//   - F1 TN=0 cc=9  mcc=901  mnc=9998 (Common/Random idle 0x0249)
//   - F1 TN=0 sigact info=0x0009 cc=9  mcc=901  mnc=9998
//   - F1 TN=2 cc=36 mcc=262  mnc=106  default 0x3000
//   - F18 BSCH-Anker info=0x0049 cc=9 mcc=901 mnc=9998
//   - NWRK-Bcast pattern info=0x0249 (idle) cc=49 mcc=901 mnc=9998
//   - BL-ACK pattern info=0x0249 (idle) cc=49 mcc=901 mnc=9998
//   - Pre-Reply pattern info=0x0009 (sigact) cc=49 mcc=901 mnc=9998
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tb_tetra_aach_rm_encoder;

    integer pass_cnt;
    integer fail_cnt;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------- DUT 1
    reg  [13:0] info_w;
    reg  [31:0] lfsr_init_w;
    wire [29:0] coded_combinational_w;

    tetra_aach_rm_encoder u_rm (
        .info_w      (info_w),
        .lfsr_init_w (lfsr_init_w),
        .coded_w     (coded_combinational_w)
    );

    // ----------------------------------------------------------------- DUT 2
    // Reference: existing FSM-based AACH encoder (tetra_aach_encoder.v)
    reg  [4:0]  fn_sys;
    reg  [1:0]  tn_sys;
    reg  [1:0]  mn_low2_sys;
    reg  [5:0]  cc_sys;
    reg  [9:0]  mcc_sys;
    reg  [13:0] mnc_sys;
    reg         sigact_sys;
    reg         aach_override_valid_sys;
    reg  [13:0] aach_override_info_sys;
    reg         encode_start_sys;
    wire [29:0] aach_fsm_coded_w;
    wire        aach_fsm_valid_w;

    tetra_aach_encoder u_fsm (
        .clk_sys                 (clk),
        .rst_n_sys               (rst_n),
        .fn_sys                  (fn_sys),
        .tn_sys                  (tn_sys),
        .mn_low2_sys             (mn_low2_sys),
        .colour_code_sys         (cc_sys),
        .mcc_sys                 (mcc_sys),
        .mnc_sys                 (mnc_sys),
        .signalling_active_sys   (sigact_sys),
        .grant_pending_sys       (1'b0),
        .grant_info_sys          (14'd0),
        .grant_consume_sys       (),
        .aach_override_valid_sys (aach_override_valid_sys),
        .aach_override_info_sys  (aach_override_info_sys),
        .encode_start_sys        (encode_start_sys),
        .aach_coded_sys          (aach_fsm_coded_w),
        .aach_valid_sys          (aach_fsm_valid_w)
    );

    task automatic check_match(input [127:0] label,
                               input [13:0]  info_val,
                               input [9:0]   mcc_val,
                               input [13:0]  mnc_val,
                               input [5:0]   cc_val);
        reg [31:0] lfsr_pack;
        begin
            lfsr_pack = {mcc_val, mnc_val, cc_val, 2'b11};

            // Drive combinational encoder
            info_w      = info_val;
            lfsr_init_w = lfsr_pack;

            // Drive FSM encoder via override path so info is exactly info_val
            // regardless of fn/tn/mn defaults.
            @(posedge clk);
            fn_sys                  = 5'd0;       // not 5'd17 (avoid F18 branch)
            tn_sys                  = 2'd0;
            mn_low2_sys             = 2'd0;
            cc_sys                  = cc_val;
            mcc_sys                 = mcc_val;
            mnc_sys                 = mnc_val;
            sigact_sys              = 1'b0;
            aach_override_valid_sys = 1'b1;
            aach_override_info_sys  = info_val;
            encode_start_sys        = 1'b1;
            @(posedge clk);
            encode_start_sys        = 1'b0;
            // FSM takes 31 cycles for S_MASK + 1 cycle S_DONE
            repeat (40) @(posedge clk);

            if (aach_fsm_coded_w === coded_combinational_w) begin
                $display("PASS %0s: info=0x%04x lfsr=0x%08x  → 0x%08x",
                         label, info_val, lfsr_pack, coded_combinational_w);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL %0s: info=0x%04x lfsr=0x%08x  fsm=0x%08x comb=0x%08x",
                         label, info_val, lfsr_pack,
                         aach_fsm_coded_w, coded_combinational_w);
                fail_cnt = fail_cnt + 1;
            end
            aach_override_valid_sys = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_tetra_aach_rm_encoder.vcd");
        $dumpvars(0, tb_tetra_aach_rm_encoder);

        info_w                  = 14'd0;
        lfsr_init_w             = 32'd0;
        fn_sys                  = 5'd0;
        tn_sys                  = 2'd0;
        mn_low2_sys             = 2'd0;
        cc_sys                  = 6'd0;
        mcc_sys                 = 10'd0;
        mnc_sys                 = 14'd0;
        sigact_sys              = 1'b0;
        aach_override_valid_sys = 1'b0;
        aach_override_info_sys  = 14'd0;
        encode_start_sys        = 1'b0;
        pass_cnt                = 0;
        fail_cnt                = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Cell A: cc=9 mcc=901 mnc=9998 (test cell)
        check_match("A.idle_0249",     14'h0249, 10'd901, 14'd9998, 6'd9);
        check_match("A.sigact_0009",   14'h0009, 10'd901, 14'd9998, 6'd9);
        check_match("A.bsch_0049",     14'h0049, 10'd901, 14'd9998, 6'd9);
        check_match("A.traffic_3000",  14'h3000, 10'd901, 14'd9998, 6'd9);
        check_match("A.reserved_2049", 14'h2049, 10'd901, 14'd9998, 6'd9);
        check_match("A.reserved_2249", 14'h2249, 10'd901, 14'd9998, 6'd9);
        check_match("A.f18tn0_0040",   14'h0040, 10'd901, 14'd9998, 6'd9);

        // Cell B: cc=36 mcc=262 mnc=106 (Cologne ham cell)
        check_match("B.idle_0249",     14'h0249, 10'd262, 14'd106,  6'd36);
        check_match("B.sigact_0009",   14'h0009, 10'd262, 14'd106,  6'd36);
        check_match("B.traffic_3000",  14'h3000, 10'd262, 14'd106,  6'd36);

        // Cell C: cc=49 mcc=901 mnc=9998 (own cell tracking)
        check_match("C.idle_0249",     14'h0249, 10'd901, 14'd9998, 6'd49);
        check_match("C.sigact_0009",   14'h0009, 10'd901, 14'd9998, 6'd49);

        // Phase Z.12 critical cases — exact patterns the queue producers use
        check_match("Z12.NWRK_BCAST_0249",       `PDUC_NWRK_BCAST_AACH,
                    10'd901, 14'd9998, 6'd49);
        check_match("Z12.BL_ACK_POST_FRAG2_0249", `PDUC_BL_ACK_POST_FRAG2_AACH,
                    10'd901, 14'd9998, 6'd49);
        check_match("Z12.PRE_REPLY_0009",         `PDUC_PRE_REPLY_SLOTGRANT_AACH,
                    10'd901, 14'd9998, 6'd49);
        check_match("Z12.FINAL_LU_ACCEPT_0009",   `PDUC_FINAL_LU_ACCEPT_AACH,
                    10'd901, 14'd9998, 6'd49);

        $display("=============================================");
        if (fail_cnt == 0) begin
            $display("tb_tetra_aach_rm_encoder: %0d PASS, 0 FAIL", pass_cnt);
            $display("RESULT: PASS");
        end else begin
            $display("tb_tetra_aach_rm_encoder: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
            $display("RESULT: FAIL");
        end
        $display("=============================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
