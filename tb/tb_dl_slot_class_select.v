// =============================================================================
// tb_dl_slot_class_select.v — Phase Z.2 self-checking TB
//
// DUTs (integration): tetra_dl_signal_queue + tetra_dl_signal_scheduler +
//                     tetra_slot_schedule + tetra_slot_content_mux +
//                     tetra_aach_encoder
//
// Goal: prove the dynamic-class lift on TN=1.
//
//   Case A (default, no queue pop)
//     BRAM TN=1 = STATIC NDB2 SYSINFO (idx=0, ndb2=1)
//     Queue empty → frame stays NDB2-SYSINFO, AACH defaults to 0x3000
//     CapAlloc on TN=1 (per ETSI gold-cell schedule for F1-17 traffic
//     slots, see tetra_aach_encoder.v).
//
//   Case B (queue pop SCH/F target_tn=1, aach=0x0009)
//     BRAM TN=1 still STATIC.  Queue gets one MLE PDU:
//       pdu_type=00 (SCH/F), target_tn=1, aach_pattern=0x0009.
//     Expect on the carrier frame:
//       slot_ndb2[1] == 0           (NDB1 SCH/F)
//       tx_blk1_slot1 == coded[431:216]
//       tx_blk2_slot1 == coded[215:0]
//       AACH for TN=1 latches info_sys=0x0009 (Unalloc/Unalloc).
//
//   Case C (queue pop SCH/HD target_tn=1, aach=0x0009)
//     pdu_type=01 (SCH/HD), target_tn=1, aach_pattern=0x0009.
//     Expect: slot_ndb2[1] == 1, tx_blk1_slot1 == coded[431:216] (the
//     SCH/HD halfblock), AACH info_sys=0x0009.
//
//   Case D (no regression on existing SIGNALLING-class slot)
//     BRAM TN=2 entry pre-set to class=SIGNALLING (e.g. NWRK-BCAST mcch
//     slot pattern in Phase H.7).  Queue popping for TN=1 does NOT
//     change TN=2's behaviour — TN=2 still routes the scheduler
//     bundle's null-pdu idle blk1 (= NULL-PDU SCH/HD), and the AACH for
//     TN=2 takes the encoder-default-logic path (0x3000 CapAlloc idle).
//
// Self-checking: each case asserts via $display + errors counter; on
// non-zero errors the TB calls $stop.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_dl_slot_class_select;

localparam CLK_PERIOD = 10;
localparam BLOCK_BITS = 216;
localparam BB_BITS    = 30;
localparam SB1_BITS   = 120;

reg clk;
reg rst_n;
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

integer errors = 0;

// -------------------------------------------------------------------------
// Schedule BRAM (Port A AXI / Port B sys)
// -------------------------------------------------------------------------
reg         axi_we;
reg  [7:0]  axi_addr;
reg  [31:0] axi_wdata;
reg  [3:0]  axi_wstrb;
reg         axi_re;
wire [31:0] axi_rdata;

wire [8:0]  sched_addr_sys;
wire [15:0] sched_data_sys;

tetra_slot_schedule u_sched (
    .clk_axi            (clk),
    .rst_n_axi          (rst_n),
    .axi_we             (axi_we),
    .axi_addr           (axi_addr),
    .axi_wdata          (axi_wdata),
    .axi_wstrb          (axi_wstrb),
    .axi_re             (axi_re),
    .axi_rdata          (axi_rdata),
    .clk_sys            (clk),
    .rst_n_sys          (rst_n),
    .sched_b_addr_sys   (sched_addr_sys),
    .schedule_entry_sys (sched_data_sys)
);

// -------------------------------------------------------------------------
// Queue producer ports + DUT
// -------------------------------------------------------------------------
reg          q_wr_mle_valid;
reg  [431:0] q_wr_mle_coded;
reg  [1:0]   q_wr_mle_pdu_type;
reg  [1:0]   q_wr_mle_target_tn;
reg  [13:0]  q_wr_mle_aach_pattern;

wire         queue_head_valid;
wire [431:0] queue_head_coded;
wire [1:0]   queue_head_pdu_type;
wire [1:0]   queue_head_target_tn;
wire [1:0]   queue_head_prio;
wire [13:0]  queue_head_aach_pattern;
wire         sched_pop;

tetra_dl_signal_queue #(.DEPTH(4)) u_q (
    .clk              (clk),
    .rst_n            (rst_n),
    .wr_mle_valid     (q_wr_mle_valid),
    .wr_mle_coded     (q_wr_mle_coded),
    .wr_mle_pdu_type  (q_wr_mle_pdu_type),
    .wr_mle_target_tn (q_wr_mle_target_tn),
    .wr_mle_aach_pattern (q_wr_mle_aach_pattern),
    .wr_mle_aach_coded   (30'd0),
    .wr_mle_second_pdu_present (1'b0),
    .wr_mle_second_pdu_nr      (1'b0),
    .wr_cmce_valid    (1'b0),
    .wr_cmce_coded    (432'd0),
    .wr_cmce_pdu_type (2'd0),
    .wr_cmce_target_tn(2'd0),
    .wr_cmce_aach_pattern (14'd0),
    .wr_cmce_aach_coded   (30'd0),
    .wr_sds_valid     (1'b0),
    .wr_sds_coded     (432'd0),
    .wr_sds_pdu_type  (2'd0),
    .wr_sds_target_tn (2'd0),
    .wr_sds_aach_pattern (14'd0),
    .wr_sds_aach_coded   (30'd0),
    .pop              (sched_pop),
    .head_valid       (queue_head_valid),
    .head_coded       (queue_head_coded),
    .head_pdu_type    (queue_head_pdu_type),
    .head_target_tn   (queue_head_target_tn),
    .head_prio        (queue_head_prio),
    .head_aach_pattern (queue_head_aach_pattern),
    .head_aach_coded   (),
    .head_second_pdu_present (),
    .head_second_pdu_nr      (),
    .depth_valid_mask (),
    .depth_count     (),
    .drop_cnt         ()
);

// -------------------------------------------------------------------------
// Scheduler DUT
// -------------------------------------------------------------------------
reg [1:0]    tn_sys;
reg [4:0]    fn_sys;
reg [5:0]    mn_sys;
reg          slot_pulse_sys;

reg [BLOCK_BITS-1:0] null_pdu_bits_sys;
reg [BLOCK_BITS-1:0] sig_companion_sys;

wire [BLOCK_BITS-1:0] sched_blk1_tn0_sys, sched_blk2_tn0_sys;
wire [BLOCK_BITS-1:0] sched_blk1_tn1_sys, sched_blk2_tn1_sys;
wire [BLOCK_BITS-1:0] sched_blk1_tn2_sys, sched_blk2_tn2_sys;
wire [BLOCK_BITS-1:0] sched_blk1_tn3_sys, sched_blk2_tn3_sys;
wire [3:0]            sched_ndb2_sys;
wire [3:0]            sched_active_sys;
wire [13:0]           sched_aach_override_tn0_sys;
wire [13:0]           sched_aach_override_tn1_sys;
wire [13:0]           sched_aach_override_tn2_sys;
wire [13:0]           sched_aach_override_tn3_sys;

tetra_dl_signal_scheduler u_s (
    .clk_sys                       (clk),
    .rst_n_sys                     (rst_n),
    .tn_sys                        (tn_sys),
    .slot_pulse_sys                (slot_pulse_sys),
    .pop_sys                       (sched_pop),
    .head_valid_sys                (queue_head_valid),
    .head_coded_sys                (queue_head_coded),
    .head_pdu_type_sys             (queue_head_pdu_type),
    .head_target_tn_sys            (queue_head_target_tn),
    .head_prio_sys                 (queue_head_prio),
    .head_aach_pattern_sys         (queue_head_aach_pattern),
    .head_aach_coded_sys           (30'd0),
    .head_second_pdu_present_sys   (1'b0),
    .head_second_pdu_nr_sys        (1'b0),
    .popped_second_pdu_present_sys (),
    .popped_second_pdu_nr_sys      (),
    .null_pdu_bits_sys             (null_pdu_bits_sys),
    .sig_companion_sys             (sig_companion_sys),
    .sched_blk1_tn0_sys            (sched_blk1_tn0_sys),
    .sched_blk2_tn0_sys            (sched_blk2_tn0_sys),
    .sched_blk1_tn1_sys            (sched_blk1_tn1_sys),
    .sched_blk2_tn1_sys            (sched_blk2_tn1_sys),
    .sched_blk1_tn2_sys            (sched_blk1_tn2_sys),
    .sched_blk2_tn2_sys            (sched_blk2_tn2_sys),
    .sched_blk1_tn3_sys            (sched_blk1_tn3_sys),
    .sched_blk2_tn3_sys            (sched_blk2_tn3_sys),
    .sched_ndb2_sys                (sched_ndb2_sys),
    .sched_active_sys              (sched_active_sys),
    .sched_aach_override_tn0_sys   (sched_aach_override_tn0_sys),
    .sched_aach_override_tn1_sys   (sched_aach_override_tn1_sys),
    .sched_aach_override_tn2_sys   (sched_aach_override_tn2_sys),
    .sched_aach_override_tn3_sys   (sched_aach_override_tn3_sys),
    .sched_aach_coded_tn0_sys      (),
    .sched_aach_coded_tn1_sys      (),
    .sched_aach_coded_tn2_sys      (),
    .sched_aach_coded_tn3_sys      (),
    .sched_aach_active_sys         (),
    .override_cnt_sys              (),
    .pop_cnt_sys                   ()
);

// -------------------------------------------------------------------------
// Slot content mux DUT
// -------------------------------------------------------------------------
reg  [BLOCK_BITS-1:0] ndb_block1_sw_sys, ndb_block2_sw_sys;
reg  [BLOCK_BITS-1:0] mcch_block1_sw_sys, mcch_block2_sw_sys;
reg  [BLOCK_BITS-1:0] bnch_block1_sw_sys, bnch_block2_sw_sys;
reg  [BLOCK_BITS-1:0] sb_bkn2_sw_sys;
reg  [SB1_BITS-1:0]   sb1_coded_sys;
reg  [BB_BITS-1:0]    aach_coded_in_sys;

wire [3:0]  cm_burst_type, cm_en, cm_ndb2;
wire [BLOCK_BITS-1:0] cm_blk1_s0, cm_blk1_s1, cm_blk1_s2, cm_blk1_s3;
wire [BLOCK_BITS-1:0] cm_blk2_s0, cm_blk2_s1, cm_blk2_s2, cm_blk2_s3;

tetra_slot_content_mux #(
    .BLOCK_BITS(BLOCK_BITS),
    .BB_BITS   (BB_BITS),
    .SB1_BITS  (SB1_BITS)
) u_mux (
    .clk_sys              (clk),
    .rst_n_sys            (rst_n),
    .tn_sys               (tn_sys),
    .fn_sys               (fn_sys),
    .mn_sys               (mn_sys),
    .slot_pulse_sys       (slot_pulse_sys),
    .tdma_tick_sys        (1'b0),
    .sched_addr_sys       (sched_addr_sys),
    .sched_data_sys       (sched_data_sys),
    .sb1_coded_sys        (sb1_coded_sys),
    .sb1_valid_sys        (1'b0),
    .aach_coded_sys       (aach_coded_in_sys),
    .aach_valid_sys       (1'b0),
    .ndb_block1_sw_sys    (ndb_block1_sw_sys),
    .ndb_block2_sw_sys    (ndb_block2_sw_sys),
    .mcch_block1_sw_sys   (mcch_block1_sw_sys),
    .mcch_block2_sw_sys   (mcch_block2_sw_sys),
    .bnch_block1_sw_sys   (bnch_block1_sw_sys),
    .bnch_block2_sw_sys   (bnch_block2_sw_sys),
    .sb_bkn2_sw_sys       (sb_bkn2_sw_sys),
    .sched_blk1_tn0_sys   (sched_blk1_tn0_sys),
    .sched_blk2_tn0_sys   (sched_blk2_tn0_sys),
    .sched_blk1_tn1_sys   (sched_blk1_tn1_sys),
    .sched_blk2_tn1_sys   (sched_blk2_tn1_sys),
    .sched_blk1_tn2_sys   (sched_blk1_tn2_sys),
    .sched_blk2_tn2_sys   (sched_blk2_tn2_sys),
    .sched_blk1_tn3_sys   (sched_blk1_tn3_sys),
    .sched_blk2_tn3_sys   (sched_blk2_tn3_sys),
    .sched_ndb2_sys       (sched_ndb2_sys),
    .sched_active_sys     (sched_active_sys),
    .slot_burst_type_sys  (cm_burst_type),
    .slot_en_sys          (cm_en),
    .slot_ndb2_sys        (cm_ndb2),
    .tx_blk1_slot0_sys    (cm_blk1_s0),
    .tx_blk1_slot1_sys    (cm_blk1_s1),
    .tx_blk1_slot2_sys    (cm_blk1_s2),
    .tx_blk1_slot3_sys    (cm_blk1_s3),
    .tx_blk2_slot0_sys    (cm_blk2_s0),
    .tx_blk2_slot1_sys    (cm_blk2_s1),
    .tx_blk2_slot2_sys    (cm_blk2_s2),
    .tx_blk2_slot3_sys    (cm_blk2_s3),
    .sb_sb1_data_sys      (),
    .sb_bb_data_sys       (),
    .dbg_sched_entry0_sys (),
    .dbg_sched_entry1_sys (),
    .dbg_sched_entry2_sys (),
    .dbg_sched_entry3_sys ()
);

// -------------------------------------------------------------------------
// AACH encoder DUT — fed via the same per-tn-pattern lookup the top-level
// uses, but driven by tn_sys (not lookahead) for TB simplicity.  Triggered
// once per slot manually via `aach_kick`.
// -------------------------------------------------------------------------
reg          aach_kick;
wire [29:0]  aach_coded_out;
wire         aach_valid_out;

reg  [13:0] aach_override_info_tn_sys;
always @(*) begin
    case (tn_sys)
        2'd0:    aach_override_info_tn_sys = sched_aach_override_tn0_sys;
        2'd1:    aach_override_info_tn_sys = sched_aach_override_tn1_sys;
        2'd2:    aach_override_info_tn_sys = sched_aach_override_tn2_sys;
        default: aach_override_info_tn_sys = sched_aach_override_tn3_sys;
    endcase
end
wire aach_override_valid_tn_sys = (aach_override_info_tn_sys != 14'd0);

// Probe info_sys directly via hierarchical reference (Verilog-2001 allows
// in simulation; not synthesizable but TB-only).
wire [13:0] dut_aach_info_sys = u_aach.info_sys;

tetra_aach_encoder u_aach (
    .clk_sys                (clk),
    .rst_n_sys              (rst_n),
    .fn_sys                 (fn_sys),
    .tn_sys                 (tn_sys),
    .mn_low2_sys            (mn_sys[1:0]),
    .colour_code_sys        (6'd49),
    .mcc_sys                (10'd901),
    .mnc_sys                (14'd9998),
    .signalling_active_sys  (1'b0),       // simplified — Z.2 path only
    .grant_pending_sys      (1'b0),
    .grant_info_sys         (14'd0),
    .grant_consume_sys      (),
    .aach_override_valid_sys(aach_override_valid_tn_sys),
    .aach_override_info_sys (aach_override_info_tn_sys),
    .encode_start_sys       (aach_kick),
    .aach_coded_sys         (aach_coded_out),
    .aach_valid_sys         (aach_valid_out)
);

// -------------------------------------------------------------------------
// AXI write helper for schedule BRAM (one-half-word per call)
// -------------------------------------------------------------------------
function [15:0] pack_entry;
    input [3:0] cls;
    input [5:0] idx;
    input [1:0] bt;
    input       ndb2;
    input       en;
    begin
        pack_entry = {cls, idx, bt, ndb2, en, 1'b0, 1'b0};
    end
endfunction

task write_entry(input [1:0] mn,
                 input [4:0] fn,
                 input [1:0] tn,
                 input [15:0] entry);
    reg [8:0] ea;
    reg [7:0] word_idx;
    reg       upper;
    begin
        ea = mn * 9'd72 + {2'b0, fn, 2'b0} + {7'b0, tn};
        word_idx = ea[8:1];
        upper = ea[0];
        @(negedge clk);
        axi_we    = 1'b1;
        axi_addr  = word_idx;
        axi_wdata = upper ? {entry, 16'h0000} : {16'h0000, entry};
        axi_wstrb = upper ? 4'b1100 : 4'b0011;
        @(posedge clk);
        @(negedge clk);
        axi_we    = 1'b0;
        axi_addr  = 8'd0;
        axi_wdata = 32'd0;
        axi_wstrb = 4'b0000;
    end
endtask

task pulse_slot(input [1:0] new_tn);
    begin
        @(negedge clk);
        tn_sys         = new_tn;
        slot_pulse_sys = 1'b1;
        @(posedge clk);
        @(negedge clk);
        slot_pulse_sys = 1'b0;
    end
endtask

// Fires a single tn=3 slot_pulse — drives the scheduler's pop_trigger
// and the content_mux's refresh trigger.  After ~10 sys cycles all
// output registers are stable and reflect the entries for the NEXT
// frame (fn_next, mn_next).
task fire_refresh(input [4:0] cur_fn, input [5:0] cur_mn);
    integer w;
    begin
        @(posedge clk); #1;
        tn_sys = 2'd3;
        fn_sys = cur_fn;
        mn_sys = cur_mn;
        slot_pulse_sys = 1'b1;
        @(posedge clk); #1;
        slot_pulse_sys = 1'b0;
        for (w = 0; w < 10; w = w + 1) @(posedge clk);
        #1;
    end
endtask

// Fires the AACH encoder once for slot tn at fn,mn.  Waits for the
// encoder to finish (~33 cycles) so info_sys captured this kick.
task aach_kick_at(input [1:0] tn, input [4:0] fn, input [5:0] mn);
    integer w;
    begin
        // Wait for encoder to be in S_IDLE before driving a new kick.
        while (u_aach.state_sys !== 2'd0) @(posedge clk);
        @(negedge clk);
        tn_sys = tn; fn_sys = fn; mn_sys = mn;
        #1;
        aach_kick = 1'b1;
        @(posedge clk);
        @(negedge clk);
        aach_kick = 1'b0;
        // info_sys is registered on the same clock edge that ingested
        // encode_start_sys=1, so it's stable now.  No need to wait
        // through S_MASK/S_DONE for the info_sys check.
    end
endtask

// Step through all 4 slots of one frame at fn,mn settings.  After this
// returns, the slot_content_mux outputs reflect the entries loaded for
// (mn, fn).  We set tn_sys to TN=3 last so that the refresh fires for
// the same frame's content during the FIRST frame (first_refresh).
task one_frame;
    begin
        pulse_slot(2'd0);
        // Wait a few cycles so the FSM completes RD0..CAP3 before we
        // pulse the next slot — content_mux needs ~6 sys cycles of
        // headroom after the trigger.
        repeat (6) @(posedge clk);
        pulse_slot(2'd1);
        repeat (6) @(posedge clk);
        pulse_slot(2'd2);
        repeat (6) @(posedge clk);
        pulse_slot(2'd3);
        repeat (6) @(posedge clk);
    end
endtask

// Like one_frame but skips the trailing tn=3 pulse — used for cases
// where the test must observe the slot_content_mux outputs of frame
// N+1 (resulting from the queue-driven refresh at the end of frame N)
// without re-triggering the scheduler at the end of frame N+1 (which
// would clear sched_active and invalidate the comparison).
task one_frame_no_tn3;
    begin
        pulse_slot(2'd0);
        repeat (6) @(posedge clk);
        pulse_slot(2'd1);
        repeat (6) @(posedge clk);
        pulse_slot(2'd2);
        repeat (6) @(posedge clk);
        // intentionally NO tn=3 pulse
    end
endtask

task push_mle(input [431:0] coded,
              input [1:0]   pdu_type,
              input [1:0]   target_tn,
              input [13:0]  aach_pattern);
    begin
        @(negedge clk);
        q_wr_mle_valid        = 1'b1;
        q_wr_mle_coded        = coded;
        q_wr_mle_pdu_type     = pdu_type;
        q_wr_mle_target_tn    = target_tn;
        q_wr_mle_aach_pattern = aach_pattern;
        @(posedge clk);
        @(negedge clk);
        q_wr_mle_valid = 1'b0;
    end
endtask

task check_eq_int(input [31:0] got, input [31:0] exp,
                  input [511:0] msg);
    begin
        if (got !== exp) begin
            $display("  FAIL %0s: got=%0h exp=%0h", msg, got, exp);
            errors = errors + 1;
        end else begin
            $display("  PASS %0s = %0h", msg, got);
        end
    end
endtask

task check_eq_h(input [BLOCK_BITS-1:0] got,
                input [BLOCK_BITS-1:0] exp,
                input [511:0] msg);
    begin
        if (got !== exp) begin
            $display("  FAIL %0s: got[31:0]=%h exp[31:0]=%h",
                     msg, got[31:0], exp[31:0]);
            errors = errors + 1;
        end else begin
            $display("  PASS %0s [31:0]=%h", msg, got[31:0]);
        end
    end
endtask

// -------------------------------------------------------------------------
// Stimulus
// -------------------------------------------------------------------------
reg [431:0] tcb_coded;
reg [431:0] tcc_coded;

initial begin
    $dumpfile("sim_out/tb_dl_slot_class_select.vcd");
    $dumpvars(0, tb_dl_slot_class_select);

    // Init regs
    rst_n          = 1'b0;
    axi_we         = 1'b0;
    axi_addr       = 8'd0;
    axi_wdata      = 32'd0;
    axi_wstrb      = 4'd0;
    axi_re         = 1'b0;
    tn_sys         = 2'd0;
    fn_sys         = 5'd0;
    mn_sys         = 6'd0;
    slot_pulse_sys = 1'b0;
    aach_kick      = 1'b0;
    q_wr_mle_valid = 1'b0;
    q_wr_mle_coded = 432'd0;
    q_wr_mle_pdu_type = 2'd0;
    q_wr_mle_target_tn = 2'd0;
    q_wr_mle_aach_pattern = 14'd0;

    // Distinct test patterns
    null_pdu_bits_sys  = {216{1'b0}};
    null_pdu_bits_sys[7:0] = 8'hAA;        // recognisable marker for NULL-PDU
    sig_companion_sys  = {216{1'b1}};
    sig_companion_sys[7:0] = 8'h11;
    ndb_block1_sw_sys  = {216{1'b0}};
    ndb_block1_sw_sys[15:0] = 16'hBEEF;    // SYSINFO marker
    ndb_block2_sw_sys  = {216{1'b0}};
    ndb_block2_sw_sys[15:0] = 16'hCAFE;
    mcch_block1_sw_sys = {216{1'b0}};
    mcch_block1_sw_sys[15:0] = 16'h1111;
    mcch_block2_sw_sys = {216{1'b0}};
    mcch_block2_sw_sys[15:0] = 16'h2222;
    bnch_block1_sw_sys = 216'd0;
    bnch_block2_sw_sys = 216'd0;
    sb_bkn2_sw_sys     = 216'd0;
    sb1_coded_sys      = 120'd0;
    aach_coded_in_sys  = 30'd0;

    tcb_coded = 432'd0;
    tcb_coded[431:216] = {216{1'b0}};
    tcb_coded[423:408] = 16'hF00D;          // SCH/F upper-half marker
    tcb_coded[15:0]    = 16'hABCD;          // SCH/F lower-half marker

    tcc_coded = 432'd0;
    tcc_coded[423:408] = 16'h5A5A;          // SCH/HD upper-half marker
    tcc_coded[15:0]    = 16'h0000;

    // Reset
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // -----------------------------------------------------------------
    // Programme schedule:
    //   (mn=0, fn=0, tn=0..3) all class=STATIC NDB SYSINFO (idx=0,
    //   bt=00, ndb2=1, en=1).
    //   For Case D we use TN=2 with class=SIGNALLING (cls=1) at
    //   (mn=0, fn=1) to verify TN=1 lift does not affect TN=2.
    // -----------------------------------------------------------------
    write_entry(2'd0, 5'd0, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd2, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));

    // For Case D - mn=0 fn=1: TN=0,1,3 STATIC NDB; TN=2 = SIGNALLING.
    write_entry(2'd0, 5'd1, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd2, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));

    // ------------------------------------------------------------------
    // Case A — Default (queue empty), TN=1 STATIC NDB2 SYSINFO
    // ------------------------------------------------------------------
    $display("=== Case A: default, queue empty ===");
    // First refresh — first_refresh_pending=1 forces loading entries
    // for the CURRENT frame (mn=0,fn=0).  Mux output registers then
    // reflect those STATIC NDB SYSINFO entries.
    fire_refresh(5'd0, 6'd0);

    // After 2 frames at fn=0: the registered cm outputs latched the
    // STATIC pathway: blk1=NDB SYSINFO, ndb2=1, AACH info default.
    check_eq_h(cm_blk1_s1, ndb_block1_sw_sys, "A.blk1_tn1");
    check_eq_h(cm_blk2_s1, ndb_block2_sw_sys, "A.blk2_tn1");
    check_eq_int({28'd0, cm_ndb2[1]}, 1'b1,    "A.ndb2_tn1");
    check_eq_int({28'd0, sched_active_sys},  4'd0, "A.sched_active");
    check_eq_int({18'd0, sched_aach_override_tn1_sys}, 32'd0, "A.aach_ovr_tn1");

    // Trigger AACH encode for TN=1 fn=0 (F1 in ETSI, traffic slot)
    // Default for F1-17 TN!=0 idle traffic-slot: 0x3000 (Gold-Audit 2026-05-04).
    aach_kick_at(2'd1, 5'd0, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h3000, "A.aach_info_default_capalloc");

    // ------------------------------------------------------------------
    // Case B — Queue pop SCH/F target_tn=1, aach=0x0009
    // ------------------------------------------------------------------
    $display("=== Case B: queue pop SCH/F target_tn=1 ===");
    push_mle(tcb_coded, 2'd0 /* SCH/F */, 2'd1, 14'h0009);
    // Single tn=3 refresh — pops the queued PDU, registers
    // sched_active[1]=1 + sched_aach_override_tn1=0x0009, and
    // content_mux loads the NEXT frame's entries (mn=0,fn=1) which
    // are also STATIC NDB SYSINFO; the dynamic-class lift then
    // routes the scheduler bundle for TN=1 instead.
    fire_refresh(5'd0, 6'd0);

    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "B.sched_active_tn1");
    check_eq_int({18'd0, sched_aach_override_tn1_sys}, 32'h0009, "B.aach_ovr_tn1");
    check_eq_h(cm_blk1_s1, tcb_coded[431:216], "B.blk1_tn1_schf_upper");
    check_eq_h(cm_blk2_s1, tcb_coded[215:0],   "B.blk2_tn1_schf_lower");
    check_eq_int({28'd0, cm_ndb2[1]}, 32'd0,   "B.ndb2_tn1_schf");

    // AACH for TN=1 must take override path → info_sys = 0x0009
    aach_kick_at(2'd1, 5'd0, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h0009, "B.aach_info_signalling");

    // Drain: another empty refresh clears sched_active.
    fire_refresh(5'd1, 6'd0);
    check_eq_int({28'd0, sched_active_sys}, 32'd0, "B.sched_active_cleared");

    // ------------------------------------------------------------------
    // Case C — Queue pop SCH/HD target_tn=1, aach=0x0009
    // ------------------------------------------------------------------
    $display("=== Case C: queue pop SCH/HD target_tn=1 ===");
    push_mle(tcc_coded, 2'd1 /* SCH/HD */, 2'd1, 14'h0009);
    fire_refresh(5'd2, 6'd0);

    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "C.sched_active_tn1");
    check_eq_int({18'd0, sched_aach_override_tn1_sys}, 32'h0009, "C.aach_ovr_tn1");
    check_eq_h(cm_blk1_s1, tcc_coded[431:216], "C.blk1_tn1_schhd_upper");
    // SCH/HD uses sig_companion in BKN2:
    check_eq_h(cm_blk2_s1, sig_companion_sys, "C.blk2_tn1_companion");
    check_eq_int({28'd0, cm_ndb2[1]}, 32'd1,   "C.ndb2_tn1_schhd");

    aach_kick_at(2'd1, 5'd0, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h0009, "C.aach_info_signalling");

    // Drain
    fire_refresh(5'd3, 6'd0);

    // ------------------------------------------------------------------
    // Case D — TN=2 already SIGNALLING in BRAM; queue popping for some
    // OTHER target should not affect TN=2 (it should still see the
    // scheduler's NULL-PDU idle), and TN=2's AACH must NOT take the
    // Z.2 override path (no queued PDU for TN=2 → override pattern=0).
    // ------------------------------------------------------------------
    $display("=== Case D: pre-existing SIGNALLING TN=2 unaffected ===");
    // Push an unrelated PDU for TN=1 only.
    push_mle(tcb_coded, 2'd0, 2'd1, 14'h0009);
    // Refresh from fn=0 → next is fn=1 where we programmed
    // TN=2 = SIGNALLING, others STATIC.
    fire_refresh(5'd0, 6'd0);

    // Scheduler for TN=2: not target → stays NULL-PDU idle, sched_ndb2[2]=1
    check_eq_h(cm_blk1_s2, null_pdu_bits_sys, "D.tn2_blk1_nullpdu");
    check_eq_h(cm_blk2_s2, sig_companion_sys, "D.tn2_blk2_companion");
    check_eq_int({28'd0, cm_ndb2[2]}, 32'd1, "D.tn2_ndb2_idle");
    // sched_active for TN=2 must stay 0 (no override pattern)
    check_eq_int({28'd0, sched_active_sys[2]}, 32'd0, "D.sched_active_tn2_zero");
    check_eq_int({18'd0, sched_aach_override_tn2_sys}, 32'd0, "D.aach_ovr_tn2_zero");

    // AACH for TN=2 falls into encoder default-logic path (override
    // valid=0).  In the simplified TB harness signalling_active_sys=0
    // and grant_pending=0, fn=1 mn=0 tn=2 → MN%4=0, fn=5'd1=ETSI FN 2,
    // not in the FN=3..13 MN%4=1 reserved window, so default 0x3000
    // (Gold-bit-genau 2026-05-04 Audit; vorher 0x32CB war Drift).
    aach_kick_at(2'd2, 5'd1, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h3000, "D.aach_info_tn2_default");

    // Also confirm the queued PDU for TN=1 still fired correctly in this
    // frame (no regression caused by D's class=SIGNALLING TN=2 entry).
    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "D.sched_active_tn1_set");
    check_eq_h(cm_blk1_s1, tcb_coded[431:216], "D.tn1_blk1_schf_upper");

    // ------------------------------------------------------------------
    if (errors == 0) begin
        $display("=============================================");
        $display("tb_dl_slot_class_select: ALL CASES PASS");
        $display("=============================================");
    end else begin
        $display("=============================================");
        $display("tb_dl_slot_class_select: %0d FAILURE(S)", errors);
        $display("=============================================");
        $stop;
    end
    $finish;
end

initial begin
    #10_000_000;
    $display("TIMEOUT");
    $stop;
end

endmodule

`default_nettype wire
