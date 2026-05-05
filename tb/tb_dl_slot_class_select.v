// =============================================================================
// tb_dl_slot_class_select.v — Phase Z.13 self-checking TB
//
// DUTs (integration): tetra_dl_signal_queue + tetra_dl_signal_scheduler +
//                     tetra_slot_schedule + tetra_slot_content_mux +
//                     tetra_aach_encoder (default-logic only) +
//                     tetra_aach_rm_encoder (queued-PDU AACH)
//
// Phase Z.13 architectural rewrite — no scheduler bundle latch, no AACH
// override branch, no per-TN aach_override path.  Instead:
//
//   * sched_blk1_tnK / sched_blk2_tnK / sched_active[K] are combinational
//     fan-outs of queue.head.
//   * Slot-side AACH select: when head_match (head_valid &&
//     head_target_tn == tx_tn_next), the slot AACH = rm_encode(
//     head_aach_pattern, lfsr_init).  Else use tetra_aach_encoder's
//     default-logic output.
//
// Goal: prove the Z.13 single-path lift on TN=1.
//
//   Case A (default, no queue pop)
//     Queue empty → frame stays NDB2-SYSINFO, AACH = default-encoder
//     output for traffic-slot idle (0x3000 CapAlloc on TN=1 F1).
//
//   Case B (queue pop SCH/F target_tn=1, aach_pattern=0x0009)
//     Queue gets one MLE PDU with target_tn=1, aach_pattern=0x0009.
//     Expect on the carrier frame:
//       slot_ndb2[1] == 0           (NDB1 SCH/F)
//       tx_blk1_slot1 == coded[431:216]
//       tx_blk2_slot1 == coded[215:0]
//       Slot AACH for TN=1 = rm_encode(0x0009, lfsr_init) (queued path).
//
//   Case C (queue pop SCH/HD target_tn=1, aach_pattern=0x0009)
//     pdu_type=01 (SCH/HD), target_tn=1, aach_pattern=0x0009.
//     Expect: slot_ndb2[1] == 1, tx_blk1_slot1 == coded[431:216] (the
//     SCH/HD halfblock), slot AACH = rm_encode(0x0009, lfsr_init).
//
//   Case D (no regression: when queue targets TN=1, TN=2's AACH
//   continues to take the default-encoder path).
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

// Z.14 — pipeline image of queue head (registered consumer-facing
// outputs).  Scheduler + slot-AACH-mux read these instead of the
// combinational head_*.  Mirrors top.v wiring.
wire         queue_head_pipe_valid;
wire [431:0] queue_head_pipe_coded;
wire [1:0]   queue_head_pipe_pdu_type;
wire [1:0]   queue_head_pipe_target_tn;
wire [1:0]   queue_head_pipe_prio;
wire [13:0]  queue_head_pipe_aach_pattern;

tetra_dl_signal_queue #(.DEPTH(4)) u_q (
    .clk              (clk),
    .rst_n            (rst_n),
    // Z.14 capture trigger
    .slot_pulse       (slot_pulse_sys),
    .wr_mle_valid     (q_wr_mle_valid),
    .wr_mle_coded     (q_wr_mle_coded),
    .wr_mle_pdu_type  (q_wr_mle_pdu_type),
    .wr_mle_target_tn (q_wr_mle_target_tn),
    .wr_mle_aach_pattern (q_wr_mle_aach_pattern),
    .wr_mle_second_pdu_present (1'b0),
    .wr_mle_second_pdu_nr      (1'b0),
    .wr_cmce_valid    (1'b0),
    .wr_cmce_coded    (432'd0),
    .wr_cmce_pdu_type (2'd0),
    .wr_cmce_target_tn(2'd0),
    .wr_cmce_aach_pattern (14'd0),
    .wr_sds_valid     (1'b0),
    .wr_sds_coded     (432'd0),
    .wr_sds_pdu_type  (2'd0),
    .wr_sds_target_tn (2'd0),
    .wr_sds_aach_pattern (14'd0),
    .pop              (sched_pop),
    .head_valid       (queue_head_valid),
    .head_coded       (queue_head_coded),
    .head_pdu_type    (queue_head_pdu_type),
    .head_target_tn   (queue_head_target_tn),
    .head_prio        (queue_head_prio),
    .head_aach_pattern (queue_head_aach_pattern),
    .head_second_pdu_present (),
    .head_second_pdu_nr      (),
    // Z.14 pipeline outputs — feed scheduler + slot AACH RM-encoder
    .head_pipe_valid              (queue_head_pipe_valid),
    .head_pipe_coded              (queue_head_pipe_coded),
    .head_pipe_pdu_type           (queue_head_pipe_pdu_type),
    .head_pipe_target_tn          (queue_head_pipe_target_tn),
    .head_pipe_prio               (queue_head_pipe_prio),
    .head_pipe_aach_pattern       (queue_head_pipe_aach_pattern),
    .head_pipe_second_pdu_present (),
    .head_pipe_second_pdu_nr      (),
    .depth_valid_mask (),
    .depth_count     (),
    .drop_cnt         ()
);

// -------------------------------------------------------------------------
// Scheduler DUT — Phase Z.13 trimmed port list
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

// Z.14 — scheduler reads pipeline image (registered head) — same wiring
// pattern as tetra_zynq_top.v.
tetra_dl_signal_scheduler u_s (
    .clk_sys                       (clk),
    .rst_n_sys                     (rst_n),
    .tn_sys                        (tn_sys),
    .slot_pulse_sys                (slot_pulse_sys),
    .pop_sys                       (sched_pop),
    .head_valid_sys                (queue_head_pipe_valid),
    .head_coded_sys                (queue_head_pipe_coded),
    .head_pdu_type_sys             (queue_head_pipe_pdu_type),
    .head_target_tn_sys            (queue_head_pipe_target_tn),
    .head_prio_sys                 (queue_head_pipe_prio),
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
// Phase Z.13 slot-side AACH select.
//
// When head_match for the slot being encoded, the slot AACH = rm_encode(
// queue_head_aach_pattern).  Else use tetra_aach_encoder's default-logic
// output.  This mirrors the top-level architecture exactly.
// -------------------------------------------------------------------------
localparam [9:0]  CC_MCC = 10'd901;
localparam [13:0] CC_MNC = 14'd9998;
localparam [5:0]  CC_CC  = 6'd49;

wire [31:0] aach_lfsr_init_w = {CC_MCC, CC_MNC, CC_CC, 2'b11};

// Z.14 — slot-AACH RM-encoder reads pipeline image (registered).
wire [29:0] head_aach_coded_w;
tetra_aach_rm_encoder u_aach_rm_slot (
    .info_w      (queue_head_pipe_aach_pattern),
    .lfsr_init_w (aach_lfsr_init_w),
    .coded_w     (head_aach_coded_w)
);

reg          aach_kick;
wire [29:0]  aach_default_coded_out;
wire         aach_default_valid_out;

tetra_aach_encoder u_aach (
    .clk_sys                (clk),
    .rst_n_sys              (rst_n),
    .fn_sys                 (fn_sys),
    .tn_sys                 (tn_sys),
    .mn_low2_sys            (mn_sys[1:0]),
    .colour_code_sys        (CC_CC),
    .mcc_sys                (CC_MCC),
    .mnc_sys                (CC_MNC),
    .signalling_active_sys  (1'b0),       // simplified — Z.13 path test
    .grant_pending_sys      (1'b0),
    .grant_info_sys         (14'd0),
    .grant_consume_sys      (),
    .encode_start_sys       (aach_kick),
    .aach_coded_sys         (aach_default_coded_out),
    .aach_valid_sys         (aach_default_valid_out)
);

// Slot-side AACH select.  In the real top.v the lookahead is tx_tn_next_sys;
// for TB simplicity we use tn_sys directly.  Z.14: use pipeline image.
wire head_match_aach = queue_head_pipe_valid
                    && (queue_head_pipe_target_tn == tn_sys);
wire [29:0] aach_slot_coded_w = head_match_aach
                              ? head_aach_coded_w
                              : aach_default_coded_out;

// Probe info_sys directly via hierarchical reference (Verilog-2001 allows
// in simulation; not synthesizable but TB-only).  Used to verify the
// default-encoder produces 0x3000/0x0249/etc as expected.
wire [13:0] dut_aach_info_sys = u_aach.info_sys;

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

// Fires a single tn=3 slot_pulse — drives the content_mux's refresh
// trigger.  After ~10 sys cycles all output registers are stable and
// reflect the entries for the NEXT frame (fn_next, mn_next).  Note: the
// scheduler's pop trigger no longer fires on tn==3 in Z.13 — it fires on
// slot_pulse@target_tn.  The refresh's purpose here is purely to
// populate the slot_content_mux schedule entries.
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

// Fires the AACH default-encoder once for slot tn at fn,mn.  Waits for
// the encoder to finish (~33 cycles).
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
        // encode_start_sys=1, so it's stable now.
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

// Compute the expected RM(30,14)+scrambler output for a given info word
// and our cell config.  Independent reference (separate instance) used
// to compare against the slot-side encoder output.
wire [13:0] ref_info_w;
wire [29:0] ref_aach_coded_w;
reg  [13:0] ref_info_drv;
assign ref_info_w = ref_info_drv;
tetra_aach_rm_encoder u_aach_rm_ref (
    .info_w      (ref_info_w),
    .lfsr_init_w (aach_lfsr_init_w),
    .coded_w     (ref_aach_coded_w)
);

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
    ref_info_drv   = 14'd0;

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
    // Programme schedule: every (mn=0, fn=0..2) slot is STATIC NDB
    // SYSINFO; (mn=0, fn=1, tn=2) is class=SIGNALLING for Case D.
    // -----------------------------------------------------------------
    write_entry(2'd0, 5'd0, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd2, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd0, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));

    write_entry(2'd0, 5'd1, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd2, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1));
    write_entry(2'd0, 5'd1, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b1, 1'b1));

    // ------------------------------------------------------------------
    // Case A — Default (queue empty), TN=1 STATIC NDB2 SYSINFO
    // ------------------------------------------------------------------
    $display("=== Case A: default, queue empty ===");
    fire_refresh(5'd0, 6'd0);

    check_eq_h(cm_blk1_s1, ndb_block1_sw_sys, "A.blk1_tn1");
    check_eq_h(cm_blk2_s1, ndb_block2_sw_sys, "A.blk2_tn1");
    check_eq_int({28'd0, cm_ndb2[1]}, 1'b1,    "A.ndb2_tn1");
    check_eq_int({28'd0, sched_active_sys},  4'd0, "A.sched_active");
    check_eq_int({31'd0, head_match_aach}, 1'b0, "A.head_match_aach_zero");

    // Trigger AACH default-encoder for TN=1 fn=0 (F1, traffic slot)
    // Default for F1-17 TN!=0 idle traffic-slot: 0x3000.
    aach_kick_at(2'd1, 5'd0, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h3000, "A.aach_info_default_capalloc");

    // ------------------------------------------------------------------
    // Case B — Queue pop SCH/F target_tn=1, aach_pattern=0x0009.
    // The slot-side AACH select should pick rm_encode(0x0009) for TN=1.
    // ------------------------------------------------------------------
    $display("=== Case B: queue pop SCH/F target_tn=1 ===");
    push_mle(tcb_coded, 2'd0 /* SCH/F */, 2'd1, 14'h0009);
    // Refresh the slot_content_mux for the next frame (queue.head still
    // valid at this moment — pop fires only on slot_pulse@target_tn).
    fire_refresh(5'd0, 6'd0);

    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "B.sched_active_tn1");
    check_eq_int({18'd0, queue_head_aach_pattern}, 32'h0009, "B.head_aach_pattern");
    check_eq_h(cm_blk1_s1, tcb_coded[431:216], "B.blk1_tn1_schf_upper");
    check_eq_h(cm_blk2_s1, tcb_coded[215:0],   "B.blk2_tn1_schf_lower");
    check_eq_int({28'd0, cm_ndb2[1]}, 32'd0,   "B.ndb2_tn1_schf");

    // Slot AACH for TN=1 must equal rm_encode(0x0009) (head-match path).
    @(negedge clk); tn_sys = 2'd1;  // simulate the slot encoder evaluating TN=1
    @(posedge clk); #1;
    check_eq_int({31'd0, head_match_aach}, 1'b1, "B.head_match_aach_one");
    ref_info_drv = 14'h0009; @(posedge clk); #1;
    check_eq_int({2'd0, aach_slot_coded_w}, {2'd0, ref_aach_coded_w}, "B.slot_aach_eq_rm_0009");

    // Pop fires on slot_pulse@tn=1 → drains the queue.
    pulse_slot(2'd1);
    @(posedge clk); #1;
    check_eq_int({31'd0, queue_head_valid}, 1'b0, "B.queue_drained_after_pop");

    // Drain refresh
    fire_refresh(5'd1, 6'd0);

    // ------------------------------------------------------------------
    // Case C — Queue pop SCH/HD target_tn=1, aach_pattern=0x0009
    // ------------------------------------------------------------------
    $display("=== Case C: queue pop SCH/HD target_tn=1 ===");
    push_mle(tcc_coded, 2'd1 /* SCH/HD */, 2'd1, 14'h0009);
    fire_refresh(5'd2, 6'd0);

    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "C.sched_active_tn1");
    check_eq_h(cm_blk1_s1, tcc_coded[431:216], "C.blk1_tn1_schhd_upper");
    // SCH/HD uses sig_companion in BKN2:
    check_eq_h(cm_blk2_s1, sig_companion_sys, "C.blk2_tn1_companion");
    check_eq_int({28'd0, cm_ndb2[1]}, 32'd1,   "C.ndb2_tn1_schhd");

    @(negedge clk); tn_sys = 2'd1;
    @(posedge clk); #1;
    check_eq_int({31'd0, head_match_aach}, 1'b1, "C.head_match_aach_one");
    ref_info_drv = 14'h0009; @(posedge clk); #1;
    check_eq_int({2'd0, aach_slot_coded_w}, {2'd0, ref_aach_coded_w}, "C.slot_aach_eq_rm_0009");

    // Drain
    pulse_slot(2'd1);
    @(posedge clk); #1;
    fire_refresh(5'd3, 6'd0);

    // ------------------------------------------------------------------
    // Case D — Queue targets TN=1; TN=2 must NOT take the head-match
    // path (head_target_tn=1 ≠ 2).  Default-encoder drives TN=2 AACH.
    // ------------------------------------------------------------------
    $display("=== Case D: head targets TN=1 — TN=2 untouched ===");
    push_mle(tcb_coded, 2'd0, 2'd1, 14'h0009);
    fire_refresh(5'd0, 6'd0);

    check_eq_int({28'd0, sched_active_sys[1]}, 32'd1, "D.sched_active_tn1_set");
    check_eq_int({28'd0, sched_active_sys[2]}, 32'd0, "D.sched_active_tn2_zero");

    // TN=1 → queued, head match
    @(negedge clk); tn_sys = 2'd1;
    @(posedge clk); #1;
    check_eq_int({31'd0, head_match_aach}, 1'b1, "D.head_match_tn1");

    // TN=2 → NOT head match → slot AACH = default encoder output
    @(negedge clk); tn_sys = 2'd2;
    @(posedge clk); #1;
    check_eq_int({31'd0, head_match_aach}, 1'b0, "D.head_match_tn2_zero");

    // Default-encoder for TN=2 fn=1 (F2 in ETSI), MN%4=0 → 0x3000 traffic idle
    aach_kick_at(2'd2, 5'd1, 6'd0);
    check_eq_int({18'd0, dut_aach_info_sys}, 32'h3000, "D.aach_info_tn2_default");

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
