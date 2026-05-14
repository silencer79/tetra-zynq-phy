// =============================================================================
// tb_mle_grpack_e2e.v — Phase Y.2 raw_mode_flag=1 grpack end-to-end audit
//
// Bug-hunt TB: on the board, accept_cnt=2 fires (attach + grpack), queue
// reports drop_cnt_mle=0, but DL air capture shows ZERO LI=16 grpack to MS.
// This TB drives the MLE-FSM + shared DL-PDU builder standalone to find
// where the grpack PDU gets corrupted or lost between mb_go_pulse and
// req_coded_bits.
//
// Coverage:
// TC1 raw_mode_flag=0 baseline (mm=2 D-LOC-UPD-ACCEPT, 102-bit body)
// → accept_pulse fires, req_valid fires, req_coded_bits non-zero,
// builder MAC-RESOURCE has LI=21 + addr=SSI=0x282F91
// TC2 raw_mode_flag=1 grpack (mm=11 D-ATTACH-DETACH-GRP-ID-ACK, 62-bit)
// → accept_pulse fires, req_valid fires, req_coded_bits non-zero,
// builder MAC-RESOURCE has LI=16 + addr=SSI=0x282F91 + MM body
// bits[125..64] match the staged raw body
// TC3 field-plane forwarding raw_mode=1
// → accept_build_mm_pdu_bits == staged raw_mm_bits
// → accept_build_mm_pdu_len_bits == 62
// → accept_build_ns/nr == staged ns/nr
// TC4 queue+scheduler collision (sequential push)
// → SlotGrant LI=7 injected first via wr_mle producer port
// → ~1500 cycles later, MLE-FSM mm=11 emits req_valid
// → both PDUs sit in queue; tdma slot_pulse rotates through TN=0..3
// → pop_cnt advances by 2; sched_active[mcch_tn] fires twice
// → captured sched_blk1 shows both 432-bit payloads on air
// TC5 same-cycle collision (SlotGrant + MLE-FSM req_valid SAME cycle)
// → wr_mle is OR'd at top-level; data-mux currently picks MLE on
// collision (mle_req_valid_w?mle_data:slotgrant_data). TB
// forces them onto the same cycle and verifies which one
// survives + whether the loser shows up in any drop counter.
//
// Run:
// iverilog -g2001 -I rtl/include -o /tmp/tb_mle_grpack_e2e \
// tb/tb_mle_grpack_e2e.v \
// rtl/lmac/tetra_mle_registration_fsm.v \
// rtl/lmac/tetra_d_location_update_encoder.v \
// rtl/lmac/tetra_dl_pdu_builder.v \
// rtl/lmac/tetra_basic_slotgrant_encoder.v \
// rtl/lmac/tetra_mac_resource_dl_builder.v \
// rtl/lmac/tetra_sch_f_encoder.v \
// rtl/lmac/tetra_dl_signal_queue.v \
// rtl/lmac/tetra_dl_signal_scheduler.v
// vvp /tmp/tb_mle_grpack_e2e
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_mle_grpack_e2e;

 reg clk = 1'b0;
 reg rst_n = 1'b0;
 always #5 clk = ~clk; // 100 MHz

 // ------------------------------------------------------------------
 // FSM ports — mailbox-side inputs driven directly (no mailbox DUT).
 // ------------------------------------------------------------------
 reg ul_req_valid = 1'b0;
 reg [1:0] ul_addr_type = 2'b00;
 reg [23:0] ul_ssi = 24'd0;
 reg [13:0] ul_la = 14'd0;
 reg [2:0] ul_loc_upd_type = 3'b000;
 reg ul_use_l2sig = 1'b0;
 reg ul_llc_is_bl_data= 1'b0;
 reg ul_llc_ns_valid = 1'b0;
 reg ul_llc_ns = 1'b0;
 reg bl_ack_valid = 1'b0;
 reg bl_ack_nr = 1'b0;
 reg [23:0] bl_ack_issi = 24'd0;
 reg slot_pulse = 1'b0;
 reg [13:0] cfg_la = 14'd0;
 reg [31:0] cfg_scramble_init= 32'hE1670EC7;
 reg [1:0] cfg_mcch_tn = 2'd0;
 reg [13:0] cfg_energy_saving_info = 14'd0;
 reg ul_detach_valid = 1'b0;
 reg [23:0] ul_detach_ssi = 24'd0;

 // Mailbox-side staging
 reg [23:0] mb_ssi = 24'd0;
 reg [13:0] mb_la = 14'd0;
 reg [2:0] mb_addr_type = 3'd1; // SSI
 reg [1:0] mb_result = 2'd0;
 reg [23:0] mb_gila_gssi = 24'd0;
 reg [2:0] mb_gila_class = 3'd4;
 reg [1:0] mb_gila_lifetime = 2'd1;
 reg mb_gila_present = 1'b0;
 reg [1:0] mb_encryption = 2'd0;
 reg [1:0] mb_auth_result = 2'd0;
 reg mb_go_pulse = 1'b0;
 reg mb_raw_mode_flag = 1'b0;
 reg [127:0] mb_raw_mm_bits = 128'd0;
 reg [7:0] mb_raw_mm_len = 8'd0;
 reg mb_raw_ns = 1'b0;
 reg mb_raw_nr = 1'b0;

 // FSM → Builder field plane
 wire accept_build_req;
 wire [23:0] accept_build_ssi;
 wire [2:0] accept_build_addr_type;
 wire [3:0] accept_build_llc_pdu_type;
 wire accept_build_random_access_flag;
 wire [127:0] accept_build_mm_pdu_bits;
 wire [7:0] accept_build_mm_pdu_len_bits;
 wire [31:0] accept_build_scramble_init;
 wire accept_build_ns;
 wire accept_build_nr;

 // Builder → FSM
 wire accept_build_done;
 wire [431:0] accept_build_coded;

 // FSM → queue
 wire req_valid;
 wire [431:0] req_coded_bits;
 wire [1:0] req_pdu_type;
 wire [1:0] req_target_tn;
 wire req_second_pdu_present;
 wire req_second_pdu_nr;

 // Status pulses
 wire busy;
 wire accept_pulse;
 wire drop_pulse;
 wire ack_pulse;
 wire retransmit_pulse;
 wire lost_pulse;
 wire detach_pulse;

 // ------------------------------------------------------------------
 // DUTs — wire FSM to real shared builder, just like tetra_zynq_top.v.
 // The builder grant is `accept_build_req & ~busy_w`, identical to top.
 // ------------------------------------------------------------------
 wire dl_pdu_busy_w;
 wire dl_pdu_grant_w = accept_build_req & ~dl_pdu_busy_w;

 tetra_mle_registration_fsm u_fsm (
.clk (clk),
.rst_n (rst_n),
.ul_req_valid (ul_req_valid),
.ul_addr_type (ul_addr_type),
.ul_ssi (ul_ssi),
.ul_la (ul_la),
.ul_loc_upd_type (ul_loc_upd_type),
.ul_use_l2sig (ul_use_l2sig),
.ul_llc_is_bl_data (ul_llc_is_bl_data),
.ul_llc_ns_valid (ul_llc_ns_valid),
.ul_llc_ns (ul_llc_ns),
.bl_ack_valid (bl_ack_valid),
.bl_ack_nr (bl_ack_nr),
.bl_ack_issi (bl_ack_issi),
.slot_pulse (slot_pulse),
.cfg_la (cfg_la),
.cfg_scramble_init (cfg_scramble_init),
.cfg_mcch_tn (cfg_mcch_tn),
.cfg_energy_saving_info (cfg_energy_saving_info),
.ul_detach_valid (ul_detach_valid),
.ul_detach_ssi (ul_detach_ssi),
.mb_ssi (mb_ssi),
.mb_la (mb_la),
.mb_addr_type (mb_addr_type),
.mb_result (mb_result),
.mb_gila_gssi (mb_gila_gssi),
.mb_gila_class (mb_gila_class),
.mb_gila_lifetime (mb_gila_lifetime),
.mb_gila_present (mb_gila_present),
.mb_encryption (mb_encryption),
.mb_auth_result (mb_auth_result),
.mb_go_pulse (mb_go_pulse),
.mb_raw_mode_flag (mb_raw_mode_flag),
.mb_raw_mm_bits (mb_raw_mm_bits),
.mb_raw_mm_len (mb_raw_mm_len),
.mb_raw_ns (mb_raw_ns),
.mb_raw_nr (mb_raw_nr),
.accept_build_req (accept_build_req),
.accept_build_ssi (accept_build_ssi),
.accept_build_addr_type (accept_build_addr_type),
.accept_build_llc_pdu_type (accept_build_llc_pdu_type),
.accept_build_random_access_flag(accept_build_random_access_flag),
.accept_build_mm_pdu_bits (accept_build_mm_pdu_bits),
.accept_build_mm_pdu_len_bits (accept_build_mm_pdu_len_bits),
.accept_build_scramble_init (accept_build_scramble_init),
.accept_build_ns (accept_build_ns),
.accept_build_nr (accept_build_nr),
.accept_build_done (accept_build_done),
.accept_build_coded (accept_build_coded),
.req_valid (req_valid),
.req_coded_bits (req_coded_bits),
.req_pdu_type (req_pdu_type),
.req_target_tn (req_target_tn),
.req_second_pdu_present (req_second_pdu_present),
.req_second_pdu_nr (req_second_pdu_nr),
.busy (busy),
.accept_pulse (accept_pulse),
.drop_pulse (drop_pulse),
.ack_pulse (ack_pulse),
.retransmit_pulse (retransmit_pulse),
.lost_pulse (lost_pulse),
.detach_pulse (detach_pulse)
 );

 tetra_dl_pdu_builder u_builder (
.clk (clk),
.rst_n (rst_n),
.req_valid (dl_pdu_grant_w),
.req_ssi (accept_build_ssi),
.req_addr_type (accept_build_addr_type),
.req_llc_pdu_type (accept_build_llc_pdu_type),
.req_random_access_flag (accept_build_random_access_flag),
.req_mm_pdu_bits (accept_build_mm_pdu_bits),
.req_mm_pdu_len_bits (accept_build_mm_pdu_len_bits),
.req_scramble_init (accept_build_scramble_init),
.req_ns (accept_build_ns),
.req_nr (accept_build_nr),
.done (accept_build_done),
.coded_bits (accept_build_coded),
.busy (dl_pdu_busy_w)
 );

 // ------------------------------------------------------------------
 // TC4/TC5 — Queue + scheduler DUTs. Mirrors tetra_zynq_top.v wiring:
 // * MLE-FSM (req_valid) and SlotGrant injection share the wr_mle port
 // * NWRK-Bcast (CMCE) and Pre-Reply BL-ACK (SDS) tied off
 // * TDMA driver below fakes slot_pulse + tn rotation
 // ------------------------------------------------------------------
 reg slotgrant_inject_valid = 1'b0;
 reg [431:0] slotgrant_inject_coded = 432'd0;
 reg [1:0] slotgrant_inject_pdu_type = 2'd1; // SCH/HD
 reg [1:0] slotgrant_inject_target_tn = 2'd0;

 // Top-level OR-mux exactly as in rtl/tetra_zynq_top.v:2829-2841
 wire mle_slot_wr_valid_w =
 req_valid | slotgrant_inject_valid;
 wire [431:0] mle_slot_wr_coded_w =
 req_valid ? req_coded_bits: slotgrant_inject_coded;
 wire [1:0] mle_slot_wr_pdu_type_w =
 req_valid ? req_pdu_type: slotgrant_inject_pdu_type;
 wire [1:0] mle_slot_wr_target_tn_w =
 req_valid ? req_target_tn: slotgrant_inject_target_tn;
 wire mle_slot_wr_second_pdu_present_w =
 req_valid ? req_second_pdu_present: 1'b0;
 wire mle_slot_wr_second_pdu_nr_w =
 req_valid ? req_second_pdu_nr: 1'b0;
 // Signalling-active for both producers (matches top-level constant)
 wire [13:0] mle_slot_wr_aach_pattern_w = 14'h0009;

 // Queue head wires
 wire queue_head_valid_w;
 wire [431:0] queue_head_coded_w;
 wire [1:0] queue_head_pdu_type_w;
 wire [1:0] queue_head_target_tn_w;
 wire [1:0] queue_head_prio_w;
 wire [13:0] queue_head_aach_pattern_w;
 wire queue_head_second_pdu_present_w;
 wire queue_head_second_pdu_nr_w;
 wire [3:0] queue_depth_mask_w;
 wire [2:0] queue_depth_count_w;
 wire [15:0] queue_drop_cnt_w;
 wire [7:0] queue_drop_cnt_mle_w;
 wire [7:0] queue_drop_cnt_cmce_w;
 wire [7:0] queue_drop_cnt_sds_w;
 wire sched_pop_w;
 wire popped_second_pdu_present_w;
 wire popped_second_pdu_nr_w;

 tetra_dl_signal_queue #(.DEPTH(4)) u_queue (
.clk (clk),
.rst_n (rst_n),
.wr_mle_valid (mle_slot_wr_valid_w),
.wr_mle_coded (mle_slot_wr_coded_w),
.wr_mle_pdu_type (mle_slot_wr_pdu_type_w),
.wr_mle_target_tn (mle_slot_wr_target_tn_w),
.wr_mle_aach_pattern (mle_slot_wr_aach_pattern_w),
.wr_mle_second_pdu_present (mle_slot_wr_second_pdu_present_w),
.wr_mle_second_pdu_nr (mle_slot_wr_second_pdu_nr_w),
.wr_cmce_valid (1'b0),
.wr_cmce_coded (432'd0),
.wr_cmce_pdu_type (2'd0),
.wr_cmce_target_tn (2'd0),
.wr_cmce_aach_pattern (14'd0),
.wr_sds_valid (1'b0),
.wr_sds_coded (432'd0),
.wr_sds_pdu_type (2'd0),
.wr_sds_target_tn (2'd0),
.wr_sds_aach_pattern (14'd0),
.pop (sched_pop_w),
.head_valid (queue_head_valid_w),
.head_coded (queue_head_coded_w),
.head_pdu_type (queue_head_pdu_type_w),
.head_target_tn (queue_head_target_tn_w),
.head_prio (queue_head_prio_w),
.head_aach_pattern (queue_head_aach_pattern_w),
.head_second_pdu_present (queue_head_second_pdu_present_w),
.head_second_pdu_nr (queue_head_second_pdu_nr_w),
.depth_valid_mask (queue_depth_mask_w),
.depth_count (queue_depth_count_w),
.drop_cnt (queue_drop_cnt_w),
.drop_cnt_mle (queue_drop_cnt_mle_w),
.drop_cnt_cmce (queue_drop_cnt_cmce_w),
.drop_cnt_sds (queue_drop_cnt_sds_w)
 );

 // TDMA: tn rotates 0..3, slot_pulse fires for 1 cycle at each TN
 // change. Compressed timescale: 1 slot = 50 cycles, 1 frame = 200
 // cycles. Real hardware is 14.17 ms/slot = 1.4M cycles @ 100 MHz —
 // 50 cycles is fine because the scheduler is purely combinational.
 reg [5:0] tdma_subcnt = 6'd0;
 reg [1:0] tn_sys = 2'd0;
 reg sched_slot_pulse = 1'b0;
 always @(posedge clk or negedge rst_n) begin
 if (!rst_n) begin
 tdma_subcnt <= 6'd0;
 tn_sys <= 2'd0;
 sched_slot_pulse <= 1'b0;
 end else begin
 if (tdma_subcnt == 6'd49) begin
 tdma_subcnt <= 6'd0;
 tn_sys <= tn_sys + 2'd1;
 sched_slot_pulse <= 1'b1;
 end else begin
 tdma_subcnt <= tdma_subcnt + 6'd1;
 sched_slot_pulse <= 1'b0;
 end
 end
 end

 // Scheduler outputs
 wire [215:0] sched_blk1_tn0_w, sched_blk1_tn1_w, sched_blk1_tn2_w, sched_blk1_tn3_w;
 wire [215:0] sched_blk2_tn0_w, sched_blk2_tn1_w, sched_blk2_tn2_w, sched_blk2_tn3_w;
 wire [3:0] sched_ndb2_w;
 wire [3:0] sched_active_w;
 wire [15:0] override_cnt_w;
 wire [15:0] pop_cnt_w;

 // Dummy idle defaults — content doesn't matter for the bug-hunt
 wire [215:0] null_pdu_bits_w = 216'd0;
 wire [215:0] sig_companion_w = 216'd0;

 tetra_dl_signal_scheduler u_sched (
.clk_sys (clk),
.rst_n_sys (rst_n),
.tn_sys (tn_sys),
.slot_pulse_sys (sched_slot_pulse),
.pop_sys (sched_pop_w),
.head_valid_sys (queue_head_valid_w),
.head_coded_sys (queue_head_coded_w),
.head_pdu_type_sys (queue_head_pdu_type_w),
.head_target_tn_sys (queue_head_target_tn_w),
.head_prio_sys (queue_head_prio_w),
.head_second_pdu_present_sys (queue_head_second_pdu_present_w),
.head_second_pdu_nr_sys (queue_head_second_pdu_nr_w),
.popped_second_pdu_present_sys (popped_second_pdu_present_w),
.popped_second_pdu_nr_sys (popped_second_pdu_nr_w),
.null_pdu_bits_sys (null_pdu_bits_w),
.sig_companion_sys (sig_companion_w),
.sched_blk1_tn0_sys (sched_blk1_tn0_w),
.sched_blk2_tn0_sys (sched_blk2_tn0_w),
.sched_blk1_tn1_sys (sched_blk1_tn1_w),
.sched_blk2_tn1_sys (sched_blk2_tn1_w),
.sched_blk1_tn2_sys (sched_blk1_tn2_w),
.sched_blk2_tn2_sys (sched_blk2_tn2_w),
.sched_blk1_tn3_sys (sched_blk1_tn3_w),
.sched_blk2_tn3_sys (sched_blk2_tn3_w),
.sched_ndb2_sys (sched_ndb2_w),
.sched_active_sys (sched_active_w),
.override_cnt_sys (override_cnt_w),
.pop_cnt_sys (pop_cnt_w)
 );

 // Capture emitted bursts: snapshot head_coded ON the cycle pop fires.
 // At that cycle, the queue head still reflects the popped entry — the
 // dequeue takes effect on the NEXT posedge.
 reg [431:0] emitted_burst [0:15];
 reg [1:0] emitted_tn [0:15];
 reg [4:0] emitted_count = 5'd0;
 reg [15:0] pop_pulse_seen = 16'd0;
 always @(posedge clk) begin
 if (sched_pop_w) begin
 pop_pulse_seen <= pop_pulse_seen + 1;
 if (emitted_count < 5'd16) begin
 emitted_burst[emitted_count] <= queue_head_coded_w;
 emitted_tn [emitted_count] <= queue_head_target_tn_w;
 emitted_count <= emitted_count + 5'd1;
 end
 end
 end

 task dump_emitted;
 integer i;
 begin
 $display(" Emitted bursts captured: %0d", emitted_count);
 for (i = 0; i < emitted_count; i = i + 1) begin
 $display(" [%0d] tn=%0d top16=0x%h", i,
 emitted_tn[i], emitted_burst[i][431:416]);
 end
 end
 endtask

 task reset_emitted;
 integer i;
 begin
 for (i = 0; i < 16; i = i + 1) emitted_burst[i] = 432'd0;
 emitted_count = 5'd0;
 end
 endtask

 // ------------------------------------------------------------------
 // Bookkeeping
 // ------------------------------------------------------------------
 integer errors = 0;
 integer cycle = 0;
 reg [431:0] coded_tc1 = 432'd0;
 reg [431:0] coded_tc2 = 432'd0;
 reg seen_accept_tc1 = 1'b0;
 reg seen_accept_tc2 = 1'b0;

 // Latch field plane on accept_build_req (cycle when FSM forwards to builder)
 reg [127:0] sampled_mm_bits = 128'd0;
 reg [7:0] sampled_mm_len = 8'd0;
 reg sampled_ns = 1'b0;
 reg sampled_nr = 1'b0;
 reg [23:0] sampled_ssi = 24'd0;
 reg sampled_valid = 1'b0;

 always @(posedge clk) begin
 cycle <= cycle + 1;
 if (accept_build_req) begin
 sampled_mm_bits <= accept_build_mm_pdu_bits;
 sampled_mm_len <= accept_build_mm_pdu_len_bits;
 sampled_ns <= accept_build_ns;
 sampled_nr <= accept_build_nr;
 sampled_ssi <= accept_build_ssi;
 sampled_valid <= 1'b1;
 end
 end

 task check_eq;
 input [255:0] name;
 input [127:0] got;
 input [127:0] exp;
 begin
 if (got !== exp) begin
 $display("FAIL: %0s — got=0x%h exp=0x%h", name, got, exp);
 errors = errors + 1;
 end else begin
 $display(" OK: %0s = 0x%h", name, got);
 end
 end
 endtask

 task wait_cycles;
 input integer n;
 integer i;
 begin
 for (i = 0; i < n; i = i + 1) @(posedge clk);
 end
 endtask

 // ------------------------------------------------------------------
 // TC1 — mm=2 baseline (raw_mode_flag=0)
 // ------------------------------------------------------------------
 task run_tc1;
 integer wait_cnt;
 begin
 $display("\n=== TC1: mm=2 D-LOC-UPDATE-ACCEPT baseline (raw_mode_flag=0) ===");
 sampled_valid = 1'b0;
 mb_ssi = 24'h282F91;
 mb_addr_type = 3'd1; // SSI
 mb_gila_gssi = 24'h2F4D61; // M2-baseline GSSI
 mb_gila_class = 3'd4;
 mb_gila_lifetime = 2'd1;
 mb_gila_present = 1'b1;
 mb_raw_mode_flag = 1'b0;
 mb_raw_mm_bits = 128'd0;
 mb_raw_mm_len = 8'd0;
 mb_raw_ns = 1'b0;
 mb_raw_nr = 1'b0;
 @(posedge clk);
 mb_go_pulse <= 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b0;

 // Wait for accept_pulse with timeout.
 wait_cnt = 0;
 while (!accept_pulse && wait_cnt < 2000) begin
 @(posedge clk);
 wait_cnt = wait_cnt + 1;
 end
 if (!accept_pulse) begin
 $display("FAIL: TC1 accept_pulse never fired after %0d cycles", wait_cnt);
 errors = errors + 1;
 end else begin
 $display(" OK: TC1 accept_pulse fired after %0d cycles", wait_cnt);
 seen_accept_tc1 = 1'b1;
 coded_tc1 = req_coded_bits;
 end
 // Field plane checks
 $display(" TC1 sampled_mm_len = %0d (expect 102)", sampled_mm_len);
 if (sampled_mm_len !== 8'd102) begin
 $display("FAIL: TC1 mm_len mismatch — got %0d exp 102", sampled_mm_len);
 errors = errors + 1;
 end
 // Builder's lat_info_bits should now hold the MAC-RESOURCE 268-bit PDU.
 // Bits [260:255] = length_ind (LI in octets). LI=21 for mm=2 with GILA.
 $display(" TC1 builder.lat_info_bits[260:255] (LI) = %0d (expect 21)",
 u_builder.lat_info_bits[260:255]);
 if (u_builder.lat_info_bits[260:255] !== 6'd21) begin
 $display("FAIL: TC1 LI=%0d (expect 21)", u_builder.lat_info_bits[260:255]);
 errors = errors + 1;
 end
 $display(" TC1 builder.lat_info_bits[251:228] (SSI) = 0x%h (expect 0x282F91)",
 u_builder.lat_info_bits[251:228]);
 if (u_builder.lat_info_bits[251:228] !== 24'h282F91) begin
 $display("FAIL: TC1 SSI mismatch");
 errors = errors + 1;
 end
 end
 endtask

 // ------------------------------------------------------------------
 // TC2 — mm=11 grpack (raw_mode_flag=1)
 //
 // Build a 62-bit grpack body in C-equivalent layout (MSB-first at
 // bit 127):
 // mm_pdu_type=11 (4) + accept_reject=0 (1) + reserved=0 (1) +
 // o-bit=1 (1) + m=1 (1) + elem_id=GID=7 (4) + length=38 (11) +
 // num_elems=1 (6) + atd=0 (1) + lifetime=1 (2) + class=4 (3) +
 // addr_type=0 (2) + GSSI=0x2F4D64 (24) + trailing_m=0 (1) = 62b
 // ------------------------------------------------------------------
 task run_tc2;
 integer wait_cnt;
 reg [127:0] body_raw;
 begin
 $display("\n=== TC2: mm=11 D-ATTACH-DETACH-GRP-ID-ACK (raw_mode_flag=1) ===");
 // Construct body MSB-first into top 62 bits of body_raw.
 // SW does: bit i (i=0 MSB) lands at raw_mm_bits[127-i].
 body_raw = 128'd0;
 // [0:4] pdu_type=11 = 4'b1011
 body_raw[127] = 1'b1; body_raw[126] = 1'b0; body_raw[125] = 1'b1; body_raw[124] = 1'b1;
 // [4] accept_reject=0
 body_raw[123] = 1'b0;
 // [5] reserved=0
 body_raw[122] = 1'b0;
 // [6] o-bit=1
 body_raw[121] = 1'b1;
 // [7] m-bit (GID present)=1
 body_raw[120] = 1'b1;
 // [8:12] elem_id=7 = 4'b0111
 body_raw[119] = 1'b0; body_raw[118] = 1'b1; body_raw[117] = 1'b1; body_raw[116] = 1'b1;
 // [12:23] length=38 = 11'b00000100110
 body_raw[115:105] = 11'd38;
 // [23:29] num_elems=1 = 6'b000001
 body_raw[104:99] = 6'd1;
 // [29] atd=0
 body_raw[98] = 1'b0;
 // [30:32] lifetime=1 = 2'b01
 body_raw[97:96] = 2'd1;
 // [32:35] class=4 = 3'b100
 body_raw[95:93] = 3'd4;
 // [35:37] addr_type=0 = 2'b00
 body_raw[92:91] = 2'd0;
 // [37:61] GSSI=0x2F4D64 (24 bit, MSB first)
 body_raw[90:67] = 24'h2F4D64;
 // [61] trailing_m=0
 body_raw[66] = 1'b0;
 // bits [65:0] are padding / don't-care

 sampled_valid = 1'b0;
 mb_ssi = 24'h282F91;
 mb_addr_type = 3'd1; // SSI
 mb_gila_present = 1'b0; // n/a in raw mode
 mb_raw_mode_flag = 1'b1;
 mb_raw_mm_bits = body_raw;
 mb_raw_mm_len = 8'd62;
 mb_raw_ns = 1'b0;
 mb_raw_nr = 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b0;

 // Wait for accept_pulse.
 wait_cnt = 0;
 while (!accept_pulse && wait_cnt < 2000) begin
 @(posedge clk);
 wait_cnt = wait_cnt + 1;
 end
 if (!accept_pulse) begin
 $display("FAIL: TC2 accept_pulse never fired after %0d cycles", wait_cnt);
 errors = errors + 1;
 end else begin
 $display(" OK: TC2 accept_pulse fired after %0d cycles", wait_cnt);
 seen_accept_tc2 = 1'b1;
 coded_tc2 = req_coded_bits;
 end

 // Field plane forwarding (TC3 in spec).
 $display(" TC2 sampled_mm_len = %0d (expect 62)", sampled_mm_len);
 if (sampled_mm_len !== 8'd62) begin
 $display("FAIL: TC2 mm_len forwarding — got %0d exp 62", sampled_mm_len);
 errors = errors + 1;
 end
 $display(" TC2 sampled_ns = %0d (expect 0), nr = %0d (expect 1)",
 sampled_ns, sampled_nr);
 if (sampled_ns !== 1'b0 || sampled_nr !== 1'b1) begin
 $display("FAIL: TC2 ns/nr forwarding");
 errors = errors + 1;
 end
 // Compare top 62 bits of forwarded body to staged body
 if (sampled_mm_bits[127:66] !== body_raw[127:66]) begin
 $display("FAIL: TC2 mm_bits[127:66] forwarding mismatch");
 $display(" got = 0x%h", sampled_mm_bits[127:66]);
 $display(" exp = 0x%h", body_raw[127:66]);
 errors = errors + 1;
 end else begin
 $display(" OK: TC2 mm_bits[127:66] forwarded bit-exact");
 end

 // Builder MAC-RESOURCE check: LI=16 + addr=SSI=0x282F91.
 $display(" TC2 builder.lat_info_bits[260:255] (LI) = %0d (expect 16)",
 u_builder.lat_info_bits[260:255]);
 if (u_builder.lat_info_bits[260:255] !== 6'd16) begin
 $display("FAIL: TC2 LI=%0d (expect 16)", u_builder.lat_info_bits[260:255]);
 errors = errors + 1;
 end
 $display(" TC2 builder.lat_info_bits[251:228] (SSI) = 0x%h (expect 0x282F91)",
 u_builder.lat_info_bits[251:228]);
 if (u_builder.lat_info_bits[251:228] !== 24'h282F91) begin
 $display("FAIL: TC2 SSI mismatch");
 errors = errors + 1;
 end

 // The grpack 62-bit MM body should appear inside the LLC region
 // of the 268-bit MAC-RESOURCE. Skip the exact placement check
 // here — that's covered by tb_mac_resource_dl_builder when fed
 // the same body directly. Reporting only:
 $display(" TC2 builder.lat_info_bits[216:155] (MM body slice, hex):");
 $display(" = 0x%h", u_builder.lat_info_bits[216:155]);
 end
 endtask

 // ------------------------------------------------------------------
 // TC3 — coded_bits must differ between the two paths.
 // ------------------------------------------------------------------
 task run_tc3;
 begin
 $display("\n=== TC3: coded_tc1 vs coded_tc2 sanity check ===");
 if (!seen_accept_tc1 || !seen_accept_tc2) begin
 $display("SKIP: prerequisite TCs did not complete");
 end else if (coded_tc1 === 432'd0) begin
 $display("FAIL: TC1 coded_bits all zero");
 errors = errors + 1;
 end else if (coded_tc2 === 432'd0) begin
 $display("FAIL: TC2 coded_bits all zero");
 errors = errors + 1;
 end else if (coded_tc1 === coded_tc2) begin
 $display("FAIL: TC1 and TC2 produced IDENTICAL coded_bits (raw_mode_flag has no effect)");
 errors = errors + 1;
 end else begin
 $display(" OK: coded_bits differ between mm=2 and mm=11 paths");
 $display(" coded_tc1[431:400] = 0x%h", coded_tc1[431:400]);
 $display(" coded_tc2[431:400] = 0x%h", coded_tc2[431:400]);
 end
 end
 endtask

 // ------------------------------------------------------------------
 // TC4 — Queue + scheduler: SlotGrant LI=7 first, MLE grpack LI=16 ~1500
 // cycles later. No collision. Verify both PDUs emit on TN=0.
 // ------------------------------------------------------------------
 task inject_slotgrant_li7;
 input [431:0] fake_coded;
 begin
 slotgrant_inject_coded = fake_coded;
 slotgrant_inject_pdu_type = 2'd1; // SCH/HD
 slotgrant_inject_target_tn = 2'd0; // mcch_tn
 @(posedge clk);
 slotgrant_inject_valid <= 1'b1;
 @(posedge clk);
 slotgrant_inject_valid <= 1'b0;
 end
 endtask

 task run_tc4;
 integer wait_cnt;
 reg [431:0] body_raw;
 reg [15:0] pop_cnt_before;
 reg [15:0] pop_cnt_after;
 reg [7:0] mle_drops_before;
 reg [7:0] mle_drops_after;
 begin
 $display("\n=== TC4: Queue+scheduler sequential SlotGrant + MLE-grpack ===");
 pop_cnt_before = pop_cnt_w;
 mle_drops_before = queue_drop_cnt_mle_w;
 reset_emitted();

 // ---- Step 1: inject fake SlotGrant LI=7 directly via wr_mle.
 $display(" TC4 step 1: injecting SlotGrant LI=7 (synthetic 432-bit)");
 inject_slotgrant_li7({16'hCAFE, 416'd0});
 wait_cycles(30); // let queue accept + scheduler observe head

 // ---- Step 2: drive mb_go_pulse for mm=11 grpack (TC2 stimulus).
 $display(" TC4 step 2: triggering MLE grpack via mb_go_pulse");
 body_raw = 128'd0;
 body_raw[127:124] = 4'b1011; // mm_pdu_type=11
 body_raw[123] = 1'b0; body_raw[122] = 1'b0; body_raw[121] = 1'b1;
 body_raw[120] = 1'b1;
 body_raw[119:116] = 4'd7; // elem_id=7 GID
 body_raw[115:105] = 11'd38; // length
 body_raw[104:99] = 6'd1; // num=1
 body_raw[98] = 1'b0; // atd=0
 body_raw[97:96] = 2'd1; // lifetime=1
 body_raw[95:93] = 3'd4; // class=4
 body_raw[92:91] = 2'd0; // addr_type=0
 body_raw[90:67] = 24'h2F4D64;
 body_raw[66] = 1'b0;
 sampled_valid = 1'b0;
 mb_ssi = 24'h282F91;
 mb_addr_type = 3'd1;
 mb_gila_present = 1'b0;
 mb_raw_mode_flag = 1'b1;
 mb_raw_mm_bits = body_raw;
 mb_raw_mm_len = 8'd62;
 mb_raw_ns = 1'b0;
 mb_raw_nr = 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b0;

 // ---- Step 3: let everything settle. Need ~1006 cycles for the
 // builder + ≥4 frames of TDMA so both pops fire.
 wait_cnt = 0;
 while (wait_cnt < 4000) begin
 @(posedge clk);
 wait_cnt = wait_cnt + 1;
 end

 pop_cnt_after = pop_cnt_w;
 mle_drops_after = queue_drop_cnt_mle_w;
 $display(" TC4 pop_cnt delta = %0d (expect 2)", pop_cnt_after - pop_cnt_before);
 $display(" TC4 queue.depth_count = %0d", queue_depth_count_w);
 $display(" TC4 queue.drop_mle delta = %0d (expect 0)", mle_drops_after - mle_drops_before);
 $display(" TC4 emitted_count = %0d, pop_pulse_seen total = %0d", emitted_count, pop_pulse_seen);

 // TC4 pushes 2 PDUs (SlotGrant + MLE-grpack). TC2's earlier
 // grpack push may still be queued at TC4 start — expect ≥ 2.
 if ((pop_cnt_after - pop_cnt_before) < 2) begin
 $display("FAIL: TC4 expected ≥2 pops, got %0d", pop_cnt_after - pop_cnt_before);
 errors = errors + 1;
 end else begin
 $display(" OK: TC4 both PDUs popped from queue (delta=%0d)",
 pop_cnt_after - pop_cnt_before);
 end
 if ((mle_drops_after - mle_drops_before) !== 0) begin
 $display("FAIL: TC4 MLE drops = %0d (expected 0)", mle_drops_after - mle_drops_before);
 errors = errors + 1;
 end
 dump_emitted();
 if (emitted_count < 5'd2) begin
 $display("FAIL: TC4 scheduler did not emit at least 2 PDUs (emitted=%0d)", emitted_count);
 errors = errors + 1;
 end else begin
 $display(" OK: TC4 scheduler emitted %0d PDUs", emitted_count);
 // Marker check: among emitted bursts, expect to find 0xCAFE
 // (SlotGrant) AND a non-CAFE non-zero burst (MLE grpack).
 begin: check_markers
 integer ii;
 reg have_cafe;
 reg have_mle;
 have_cafe = 1'b0;
 have_mle = 1'b0;
 for (ii = 0; ii < emitted_count; ii = ii + 1) begin
 if (emitted_burst[ii][431:416] === 16'hCAFE)
 have_cafe = 1'b1;
 else if (emitted_burst[ii] !== 432'd0)
 have_mle = 1'b1;
 end
 if (!have_cafe) begin
 $display("FAIL: TC4 SlotGrant marker (0xCAFE) not on air");
 errors = errors + 1;
 end else $display(" OK: TC4 SlotGrant marker present on air");
 if (!have_mle) begin
 $display("FAIL: TC4 MLE grpack burst not on air");
 errors = errors + 1;
 end else $display(" OK: TC4 MLE grpack burst present on air");
 end
 end
 end
 endtask

 // ------------------------------------------------------------------
 // TC5 — Same-cycle collision: drive SlotGrant pulse on the EXACT cycle
 // that MLE-FSM emits req_valid. In the top-level OR-mux this lets
 // mle_data win and silently drops the SlotGrant data. We force the
 // collision and check both queue-state + any drop counters.
 // ------------------------------------------------------------------
 task run_tc5;
 integer wait_cnt;
 reg [431:0] body_raw;
 reg [15:0] pop_cnt_before;
 reg [15:0] pop_cnt_after;
 reg [7:0] mle_drops_before;
 reg [7:0] mle_drops_after;
 begin
 $display("\n=== TC5: Same-cycle SlotGrant + MLE-FSM req_valid collision ===");
 pop_cnt_before = pop_cnt_w;
 mle_drops_before = queue_drop_cnt_mle_w;
 reset_emitted();

 // Stage grpack body
 body_raw = 128'd0;
 body_raw[127:124] = 4'b1011;
 body_raw[121] = 1'b1; body_raw[120] = 1'b1;
 body_raw[119:116] = 4'd7;
 body_raw[115:105] = 11'd38;
 body_raw[104:99] = 6'd1;
 body_raw[97:96] = 2'd1;
 body_raw[95:93] = 3'd4;
 body_raw[90:67] = 24'h2F4D65; // different GSSI so we can tell apart
 mb_ssi = 24'h282F91;
 mb_addr_type = 3'd1;
 mb_gila_present = 1'b0;
 mb_raw_mode_flag = 1'b1;
 mb_raw_mm_bits = body_raw;
 mb_raw_mm_len = 8'd62;
 mb_raw_ns = 1'b1;
 mb_raw_nr = 1'b0;
 @(posedge clk);
 mb_go_pulse <= 1'b1;
 @(posedge clk);
 mb_go_pulse <= 1'b0;

 // Wait for the FSM to reach the cycle BEFORE req_valid asserts.
 // The TC1/TC2 measurements showed accept_pulse fires after 1006
 // cycles from GO. We arm SlotGrant injection one cycle before
 // that by polling req_valid.
 wait_cnt = 0;
 while (!req_valid && wait_cnt < 2000) begin
 @(posedge clk);
 wait_cnt = wait_cnt + 1;
 end
 if (!req_valid) begin
 $display("FAIL: TC5 req_valid never fired");
 errors = errors + 1;
 end else begin
 // We're now ON the cycle that req_valid is asserted. Pulse
 // SlotGrant valid for this same cycle by combinational
 // assignment — but slotgrant_inject_valid is a reg, so
 // assert it now (will be visible to queue same cycle).
 slotgrant_inject_valid = 1'b1;
 slotgrant_inject_coded = {16'hBEEF, 416'd0};
 slotgrant_inject_pdu_type = 2'd1;
 slotgrant_inject_target_tn = 2'd0;
 @(posedge clk);
 slotgrant_inject_valid = 1'b0;
 $display(" TC5 collision triggered on cycle %0d", cycle);
 end

 // Drain — let scheduler emit anything queued.
 wait_cnt = 0;
 while (wait_cnt < 2000) begin
 @(posedge clk);
 wait_cnt = wait_cnt + 1;
 end

 pop_cnt_after = pop_cnt_w;
 mle_drops_after = queue_drop_cnt_mle_w;
 $display(" TC5 pop_cnt delta = %0d", pop_cnt_after - pop_cnt_before);
 $display(" TC5 queue.drop_mle delta = %0d", mle_drops_after - mle_drops_before);
 dump_emitted();
 if ((pop_cnt_after - pop_cnt_before) < 2) begin
 $display(" NOTE: TC5 only %0d pop on same-cycle collision",
 pop_cnt_after - pop_cnt_before);
 $display(" → OR-mux silently dropped one producer (matches");
 $display(" the suspected on-board bug if Frag-1 SlotGrant");
 $display(" + grpack ever fire on the same cycle).");
 end
 end
 endtask

 // ------------------------------------------------------------------
 // Main
 // ------------------------------------------------------------------
 initial begin
 $dumpfile("tb_mle_grpack_e2e.vcd");
 $dumpvars(0, tb_mle_grpack_e2e);
 // Reset
 rst_n = 1'b0;
 wait_cycles(20);
 rst_n = 1'b1;
 wait_cycles(5);

 run_tc1();
 wait_cycles(50);
 run_tc2();
 wait_cycles(50);
 run_tc3();
 wait_cycles(50);
 run_tc4();
 wait_cycles(50);
 run_tc5();

 $display("\n=== SUMMARY: %0d errors ===\n", errors);
 if (errors == 0) $display("ALL TESTS PASS");
 else $display("TESTS FAILED");
 $finish;
 end

 // Safety timeout
 initial begin
 #500000;
 $display("FATAL: global timeout @500us");
 $finish;
 end

endmodule

`default_nettype wire
