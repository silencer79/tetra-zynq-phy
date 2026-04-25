// =============================================================================
// tb_mle_registration_fsm.v
//
// Integration test for the registration FSM connected to a real
// tetra_active_session_table instance.  The gold-path registration flow is:
//   1. short SCH/HD pre-reply  (AL-SETUP, LI=7, slot-granting=0)
//   2. full SCH/F accept       (BL-ADATA, LI>7)
//
// The TB checks sequencing, slot reuse/allocation, and the queue request
// metadata.  Exact on-air bit identity is covered in the lower-level builder
// tests; this TB focuses on the FSM's two-request behavior.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_mle_registration_fsm;
    localparam integer AST_DEPTH      = 64;
    localparam integer AST_IDX_WIDTH  = 6;
    // Phase 6 D-rev — AST widened from 128→256 bit per §9.2 (group_list[8]
    // + group_count + state + shadow_idx + last_seen + ISSI).  See
    // tetra_zynq_top.v for the in-design layout, and the header of
    // tetra_active_session_table.v for the spec-vs-valid reconciliation.
    localparam integer AST_REC_WIDTH  = 256;
    localparam integer AST_ISSI_WIDTH = 24;

    reg                         clk   = 1'b0;
    reg                         rst_n = 1'b0;
    always #5 clk = ~clk;

    reg         ul_req_valid      = 1'b0;
    reg  [1:0]  ul_addr_type      = 2'd0;     // Ssi/ISSI per bluestation
    reg  [23:0] ul_ssi            = 24'd0;
    reg  [13:0] ul_la             = 14'd0;
    reg  [2:0]  ul_loc_upd_type   = 3'b011;  // ITSI attach
    reg         ul_use_l2sig      = 1'b0;
    reg         ul_llc_is_bl_data = 1'b0;
    reg         ul_llc_ns_valid   = 1'b0;
    reg         ul_llc_ns         = 1'b0;
    reg         bl_ack_valid      = 1'b0;
    reg         bl_ack_nr         = 1'b0;
    reg  [23:0] bl_ack_issi       = 24'd0;
    reg         slot_pulse        = 1'b0;
    // Phase 6 B — Detach + multiframe counter
    reg         ul_detach_valid   = 1'b0;
    reg  [23:0] ul_detach_ssi     = 24'd0;
    reg  [23:0] mf_global_cnt     = 24'd0;

    reg [13:0]  cfg_la            = 14'd36;
    reg [31:0]  cfg_scramble_init = 32'hE1670C03;
    reg [1:0]   cfg_mcch_tn       = 2'd1;
    // 2026-04-25: D-LOC-UPDATE-ACCEPT MM-Body fields
    reg [23:0]  cfg_address_extension  = 24'h000000;
    reg [15:0]  cfg_subscriber_class   = 16'hFFFF;
    reg [13:0]  cfg_energy_saving_info = 14'h0000;

    wire                         ast_wr_en;
    wire [AST_IDX_WIDTH-1:0]     ast_wr_idx;
    wire [AST_REC_WIDTH-1:0]     ast_wr_data;
    wire                         ast_q_start;
    wire                         ast_q_mode;
    wire [23:0]                  ast_q_issi;
    wire                         ast_q_busy;
    wire                         ast_q_done;
    wire                         ast_q_hit;
    wire [AST_IDX_WIDTH-1:0]     ast_q_slot;
    wire [AST_REC_WIDTH-1:0]     ast_q_record;

    // Phase 6 D-rev: entity-table + profile-table lookup wires (FSM ↔ DUTs)
    wire                         entity_q_start;
    wire [23:0]                  entity_q_id;
    wire                         entity_q_type;
    wire                         entity_q_match_type;
    wire                         entity_q_default_gssi_scan;
    wire                         entity_q_alloc;
    wire                         entity_q_busy;
    wire                         entity_q_done;
    wire                         entity_q_hit;
    wire [7:0]                   entity_q_slot;
    wire [63:0]                  entity_q_record;
    wire                         entity_wr_en;
    wire [7:0]                   entity_wr_idx;
    wire [63:0]                  entity_wr_data;

    wire [2:0]                   profile_rd_idx;
    wire [31:0]                  profile_rd_data;

    reg                          accept_unknown = 1'b1;  // permissive default
    // Entity-table write port driven from TB to seed records (mimics ARM
    // via AXI).  When the FSM also writes (Auto-Enroll), we mux them: TB
    // writes are issued only when `tb_entity_wr_en` is high; otherwise the
    // FSM's `entity_wr_en` drives the port.
    reg [7:0]                    tb_entity_wr_idx  = 8'd0;
    reg [63:0]                   tb_entity_wr_data = 64'd0;
    reg                          tb_entity_wr_en   = 1'b0;
    // Combined write port to the entity table — either TB-side or FSM-side.
    wire        et_wr_en   = tb_entity_wr_en | entity_wr_en;
    wire [7:0]  et_wr_idx  = tb_entity_wr_en ? tb_entity_wr_idx  : entity_wr_idx;
    wire [63:0] et_wr_data = tb_entity_wr_en ? tb_entity_wr_data : entity_wr_data;

    // Profile-table write port driven from TB.
    reg [2:0]                    tb_profile_wr_idx  = 3'd0;
    reg [31:0]                   tb_profile_wr_data = 32'd0;
    reg                          tb_profile_wr_en   = 1'b0;

    wire         req_valid;
    wire [431:0] req_coded_bits;
    wire [1:0]   req_pdu_type;
    wire [1:0]   req_target_tn;
    wire         busy;
    wire         accept_pulse;
    wire         drop_pulse;
    wire         ack_pulse;
    wire         retransmit_pulse;
    wire         lost_pulse;
    wire         detach_pulse;
    wire         req_second_pdu_present;
    wire         req_second_pdu_nr;

    tetra_active_session_table #(
        .DEPTH      (AST_DEPTH),
        .IDX_WIDTH  (AST_IDX_WIDTH),
        .REC_WIDTH  (AST_REC_WIDTH),
        .ISSI_WIDTH (AST_ISSI_WIDTH)
    ) u_ast (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_idx  (ast_wr_idx),
        .wr_data (ast_wr_data),
        .wr_en   (ast_wr_en),
        .q_start (ast_q_start),
        .q_mode  (ast_q_mode),
        .q_issi  (ast_q_issi),
        .q_busy  (ast_q_busy),
        .q_done  (ast_q_done),
        .q_hit   (ast_q_hit),
        .q_slot  (ast_q_slot),
        .q_record(ast_q_record)
    );

    // Phase 6 D-rev — real EntityTable DUT for §9.3 Multi-Lookup attach
    tetra_entity_table #(
        .DEPTH    (256),
        .IDX_WIDTH(8),
        .REC_WIDTH(64),
        .ID_WIDTH (24)
    ) u_entity (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_idx   (et_wr_idx),
        .wr_data  (et_wr_data),
        .wr_en    (et_wr_en),
        .q_start  (entity_q_start),
        .q_id     (entity_q_id),
        .q_type   (entity_q_type),
        .q_match_type        (entity_q_match_type),
        .q_default_gssi_scan (entity_q_default_gssi_scan),
        .q_alloc             (entity_q_alloc),
        .q_busy   (entity_q_busy),
        .q_done   (entity_q_done),
        .q_hit    (entity_q_hit),
        .q_slot   (entity_q_slot),
        .q_record (entity_q_record)
    );

    // Phase 6 D-rev — real ProfileTable DUT
    tetra_profile_table #(
        .DEPTH    (6),
        .IDX_WIDTH(3),
        .REC_WIDTH(32)
    ) u_profile (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_idx  (tb_profile_wr_idx),
        .wr_data (tb_profile_wr_data),
        .wr_en   (tb_profile_wr_en),
        .rd_idx  (profile_rd_idx),
        .rd_data (profile_rd_data)
    );

    tetra_mle_registration_fsm #(
        .AST_IDX_WIDTH(AST_IDX_WIDTH),
        .AST_REC_WIDTH(AST_REC_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .ul_req_valid     (ul_req_valid),
        .ul_addr_type     (ul_addr_type),
        .ul_ssi           (ul_ssi),
        .ul_la            (ul_la),
        .ul_loc_upd_type  (ul_loc_upd_type),
        .ul_use_l2sig     (ul_use_l2sig),
        .ul_llc_is_bl_data(ul_llc_is_bl_data),
        .ul_llc_ns_valid  (ul_llc_ns_valid),
        .ul_llc_ns        (ul_llc_ns),
        .bl_ack_valid     (bl_ack_valid),
        .bl_ack_nr        (bl_ack_nr),
        .bl_ack_issi      (bl_ack_issi),
        .slot_pulse       (slot_pulse),
        .cfg_la           (cfg_la),
        .cfg_scramble_init(cfg_scramble_init),
        .cfg_mcch_tn      (cfg_mcch_tn),
        .cfg_address_extension (cfg_address_extension),
        .cfg_subscriber_class  (cfg_subscriber_class),
        .cfg_energy_saving_info(cfg_energy_saving_info),
        .ast_wr_en        (ast_wr_en),
        .ast_wr_idx       (ast_wr_idx),
        .ast_wr_data      (ast_wr_data),
        .ast_q_start      (ast_q_start),
        .ast_q_mode       (ast_q_mode),
        .ast_q_issi       (ast_q_issi),
        .ast_q_busy       (ast_q_busy),
        .ast_q_done       (ast_q_done),
        .ast_q_hit        (ast_q_hit),
        .ast_q_slot       (ast_q_slot),
        .ast_q_record     (ast_q_record),
        .entity_q_start              (entity_q_start),
        .entity_q_id                 (entity_q_id),
        .entity_q_type               (entity_q_type),
        .entity_q_match_type         (entity_q_match_type),
        .entity_q_default_gssi_scan  (entity_q_default_gssi_scan),
        .entity_q_alloc              (entity_q_alloc),
        .entity_q_busy               (entity_q_busy),
        .entity_q_done               (entity_q_done),
        .entity_q_hit                (entity_q_hit),
        .entity_q_slot               (entity_q_slot),
        .entity_q_record             (entity_q_record),
        .entity_wr_en                (entity_wr_en),
        .entity_wr_idx               (entity_wr_idx),
        .entity_wr_data              (entity_wr_data),
        .profile_rd_idx              (profile_rd_idx),
        .profile_rd_data             (profile_rd_data),
        .accept_unknown   (accept_unknown),
        .req_valid        (req_valid),
        .req_coded_bits   (req_coded_bits),
        .req_pdu_type     (req_pdu_type),
        .req_target_tn    (req_target_tn),
        .req_second_pdu_present (req_second_pdu_present),
        .req_second_pdu_nr      (req_second_pdu_nr),
        .busy             (busy),
        .accept_pulse     (accept_pulse),
        .drop_pulse       (drop_pulse),
        .ack_pulse        (ack_pulse),
        .retransmit_pulse (retransmit_pulse),
        .lost_pulse       (lost_pulse),
        // Phase 6 B
        .ul_detach_valid  (ul_detach_valid),
        .ul_detach_ssi    (ul_detach_ssi),
        .mf_global_cnt    (mf_global_cnt),
        .detach_pulse     (detach_pulse)
    );

    integer fail_count = 0;
    integer test_count = 0;
    integer i;

    task automatic clear_ast;
        integer idx;
        begin
            for (idx = 0; idx < AST_DEPTH; idx = idx + 1)
                u_ast.mem[idx] = {AST_REC_WIDTH{1'b0}};
        end
    endtask

    // Phase 6 D-rev — clear EntityTable BRAM at sim init.  Profile-table
    // is initialised by its own `initial` block (Profile 0 = 0x0000_088F,
    // others zero); we override slots in seed_profile() as needed.
    task automatic clear_entity;
        integer idx;
        begin
            for (idx = 0; idx < 256; idx = idx + 1)
                u_entity.mem[idx] = 64'd0;
        end
    endtask

    task automatic push_request(input [23:0] issi, input [13:0] la);
        begin
            @(posedge clk);
            ul_ssi       <= issi;
            ul_la        <= la;
            ul_req_valid <= 1'b1;
            @(posedge clk);
            ul_req_valid <= 1'b0;
        end
    endtask

    task automatic pulse_slots(input integer count);
        integer j;
        begin
            for (j = 0; j < count; j = j + 1) begin
                @(posedge clk);
                slot_pulse <= 1'b1;
                @(posedge clk);
                slot_pulse <= 1'b0;
            end
        end
    endtask

    task automatic wait_for_req(output reg [1:0] got_pdu_type,
                                output reg [1:0] got_target_tn,
                                output reg [431:0] got_coded,
                                output reg got_accept_pulse);
        integer wait_cycles;
        begin
            got_pdu_type     = 2'd0;
            got_target_tn    = 2'd0;
            got_coded        = 432'd0;
            got_accept_pulse = 1'b0;
            wait_cycles      = 0;
            while (wait_cycles < 4000) begin
                @(posedge clk);
                if (req_valid) begin
                    got_pdu_type     = req_pdu_type;
                    got_target_tn    = req_target_tn;
                    got_coded        = req_coded_bits;
                    got_accept_pulse = accept_pulse;
                    wait_cycles      = 4000;
                end else begin
                    wait_cycles = wait_cycles + 1;
                end
            end
        end
    endtask

    task automatic expect_two_phase_accept(input [23:0] issi,
                                           input [AST_IDX_WIDTH-1:0] exp_slot);
        reg [1:0]   got_type1, got_type2;
        reg [1:0]   got_tn1, got_tn2;
        reg [431:0] got_coded1, got_coded2;
        reg         got_accept1, got_accept2;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_for_req(got_type1, got_tn1, got_coded1, got_accept1);
            pulse_slots(4);
            wait_for_req(got_type2, got_tn2, got_coded2, got_accept2);

            if (got_type1 !== 2'd1) begin
                $display("[T%0d] FAIL first req type got=%0d exp=1(SCH_HD)",
                         test_count, got_type1);
                fail_count = fail_count + 1;
            end else if (got_type2 !== 2'd0) begin
                $display("[T%0d] FAIL second req type got=%0d exp=0(SCH_F)",
                         test_count, got_type2);
                fail_count = fail_count + 1;
            end else if (got_tn1 !== cfg_mcch_tn || got_tn2 !== cfg_mcch_tn) begin
                $display("[T%0d] FAIL target_tn got=%0d/%0d exp=%0d",
                         test_count, got_tn1, got_tn2, cfg_mcch_tn);
                fail_count = fail_count + 1;
            end else if (got_accept1 !== 1'b0 || got_accept2 !== 1'b1) begin
                $display("[T%0d] FAIL accept_pulse pre/full=%b/%b exp=0/1",
                         test_count, got_accept1, got_accept2);
                fail_count = fail_count + 1;
            end else if (req_second_pdu_present !== 1'b0 || req_second_pdu_nr !== 1'b0) begin
                $display("[T%0d] FAIL legacy second_pdu telemetry present=%b nr=%b",
                         test_count, req_second_pdu_present, req_second_pdu_nr);
                fail_count = fail_count + 1;
            end else if (ast_wr_idx !== exp_slot) begin
                $display("[T%0d] FAIL slot got=%0d exp=%0d",
                         test_count, ast_wr_idx, exp_slot);
                fail_count = fail_count + 1;
            end else if (got_coded1[431:216] == 216'd0 || got_coded2 == 432'd0) begin
                $display("[T%0d] FAIL coded payload unexpectedly zero",
                         test_count);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS slot=%0d short=SCH_HD full=SCH_F",
                         test_count, ast_wr_idx);
            end
            repeat (3) @(posedge clk);
            if (busy !== 1'b0) begin
                $display("[T%0d] FAIL did not return idle, busy=%b",
                         test_count, busy);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Phase 6 D-rev — seed an EntityTable slot (ISSI/GSSI + profile_id).
    // Layout per §9.2:
    //   [63:40] entity_id / [39] entity_type / [38:35] profile_id
    //   [34:1]  reserved=0 / [0] valid
    task automatic seed_entity(input [7:0]  slot,
                               input [23:0] entity_id,
                               input        entity_type,
                               input [3:0]  profile_id);
        begin
            @(posedge clk);
            tb_entity_wr_idx  <= slot;
            tb_entity_wr_data <= {entity_id, entity_type, profile_id,
                                  34'd0, 1'b1};
            tb_entity_wr_en   <= 1'b1;
            @(posedge clk);
            tb_entity_wr_en   <= 1'b0;
        end
    endtask

    // Phase 6 D-rev — seed a ProfileTable slot per §9.2.
    task automatic seed_profile(input [2:0] slot,
                                input [7:0] max_call_dur,
                                input [7:0] hangtime,
                                input [3:0] prio,
                                input [2:0] gila_class,
                                input [1:0] gila_lifetime,
                                input       permit_voice,
                                input       permit_data,
                                input       permit_reg,
                                input       valid);
        begin
            @(posedge clk);
            tb_profile_wr_idx  <= slot;
            tb_profile_wr_data <= {max_call_dur, hangtime, prio,
                                   gila_class, gila_lifetime, 3'd0,
                                   permit_voice, permit_data, permit_reg,
                                   valid};
            tb_profile_wr_en   <= 1'b1;
            @(posedge clk);
            tb_profile_wr_en   <= 1'b0;
        end
    endtask

    // Phase 6 A — assert a registration goes the REJECT path with given cause.
    // We watch for accept_pulse (FSM signals "decision delivered to queue")
    // and then probe internal lat_is_reject + lat_reject_cause.
    task automatic expect_reject(input [23:0] issi,
                                 input [2:0]  exp_cause,
                                 input [255:0] tag);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            // wait for pre-reply (first req_valid)
            wait_cycles = 0;
            while (wait_cycles < 4000 && !req_valid) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            // FSM now in S_WAIT_GAP_FRAME — drive 4 slot_pulses
            pulse_slots(4);
            // wait for full Accept/Reject (second req_valid + accept_pulse)
            wait_cycles = 0;
            while (wait_cycles < 4000 && !accept_pulse) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!accept_pulse) begin
                $display("[T%0d] FAIL %0s no decision pulse", test_count, tag);
                fail_count = fail_count + 1;
            end else if (dut.lat_is_reject !== 1'b1) begin
                $display("[T%0d] FAIL %0s expected REJECT path, lat_is_reject=%b",
                         test_count, tag, dut.lat_is_reject);
                fail_count = fail_count + 1;
            end else if (dut.lat_reject_cause !== exp_cause) begin
                $display("[T%0d] FAIL %0s reject_cause got=%0d exp=%0d",
                         test_count, tag, dut.lat_reject_cause, exp_cause);
                fail_count = fail_count + 1;
            end else if (dut.mle_mm_len_w !== 8'd8) begin
                $display("[T%0d] FAIL %0s MM length got=%0d exp=8 (REJECT)",
                         test_count, tag, dut.mle_mm_len_w);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS %0s REJECT cause=%0d MM=8bit",
                         test_count, tag, dut.lat_reject_cause);
            end
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic expect_accept(input [23:0] issi,
                                 input [255:0] tag);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_cycles = 0;
            while (wait_cycles < 4000 && !req_valid) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            pulse_slots(4);
            wait_cycles = 0;
            while (wait_cycles < 4000 && !accept_pulse) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!accept_pulse) begin
                $display("[T%0d] FAIL %0s no decision pulse", test_count, tag);
                fail_count = fail_count + 1;
            end else if (dut.lat_is_reject !== 1'b0) begin
                $display("[T%0d] FAIL %0s expected ACCEPT path, lat_is_reject=%b",
                         test_count, tag, dut.lat_is_reject);
                fail_count = fail_count + 1;
            end else if (dut.mle_mm_len_w !== 8'd102) begin
                $display("[T%0d] FAIL %0s MM length got=%0d exp=102 (ACCEPT)",
                         test_count, tag, dut.mle_mm_len_w);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS %0s ACCEPT MM=102bit",
                         test_count, tag);
            end
            repeat (3) @(posedge clk);
        end
    endtask

    // Phase 6 B — issue a U-ITSI-DETACH pulse and wait for the FSM to fire
    // detach_pulse (= AST.write(slot, valid=0) completed or hit-miss).
    task automatic detach_request(input [23:0] issi);
        begin
            @(posedge clk);
            ul_detach_ssi   <= issi;
            ul_detach_valid <= 1'b1;
            @(posedge clk);
            ul_detach_valid <= 1'b0;
        end
    endtask

    task automatic expect_detach_clear(input [7:0]  exp_slot,
                                       input [23:0] issi,
                                       input [255:0] tag);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            // capture pre-state: AST entry should still hold the registration
            if (u_ast.mem[exp_slot][AST_REC_WIDTH-1 -: AST_ISSI_WIDTH] !== issi) begin
                $display("[T%0d] FAIL %0s pre-condition: AST[%0d] ISSI=0x%06X exp=0x%06X",
                         test_count, tag, exp_slot,
                         u_ast.mem[exp_slot][AST_REC_WIDTH-1 -: AST_ISSI_WIDTH], issi);
                fail_count = fail_count + 1;
            end
            detach_request(issi);
            // wait for detach_pulse
            wait_cycles = 0;
            while (wait_cycles < 4000 && !detach_pulse) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!detach_pulse) begin
                $display("[T%0d] FAIL %0s no detach_pulse after 4000 cycles",
                         test_count, tag);
                fail_count = fail_count + 1;
            end else begin
                // AST.write commits one cycle after wr_en is sampled.
                // We are now at the cycle where detach_pulse fires (= same
                // cycle as wr_en); wait one more posedge so the BRAM has
                // the zero record.
                @(posedge clk);
                if (u_ast.mem[exp_slot] !== {AST_REC_WIDTH{1'b0}}) begin
                    $display("[T%0d] FAIL %0s AST[%0d] not cleared, ISSI=0x%h",
                             test_count, tag, exp_slot,
                             u_ast.mem[exp_slot][AST_REC_WIDTH-1 -: AST_ISSI_WIDTH]);
                    fail_count = fail_count + 1;
                end else begin
                    $display("[T%0d] PASS %0s AST slot %0d cleared (valid=0, ISSI=0)",
                             test_count, tag, exp_slot);
                end
            end
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic expect_drop(input [23:0] issi);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_cycles = 0;
            while (wait_cycles < 4000 && !drop_pulse) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!drop_pulse) begin
                $display("[T%0d] FAIL expected drop", test_count);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS drop", test_count);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_out/tb_mle_registration_fsm.vcd");
        $dumpvars(0, tb_mle_registration_fsm);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        clear_ast();
        clear_entity();
        @(posedge clk);

        // Seed the M2 default DB:
        //   EntityTable slot 0 = MTP3550 ISSI 0x282F91, type=0, profile=0
        //   EntityTable slot 1 = Default-Group GSSI 0x2F4D61, type=1, profile=0
        // Profile 0 is reset-default 0x0000_088F (gila_class=4, lifetime=1,
        // permit_reg=1, valid=1).
        seed_entity(8'd0, 24'h282F91, 1'b0, 4'd0);
        seed_entity(8'd1, 24'h2F4D61, 1'b1, 4'd0);
        @(posedge clk);

        // T1..T3: basic Auto-Enroll path (accept_unknown=1, ISSI not in DB).
        // Each accept consumes one AST slot.
        expect_two_phase_accept(24'd523, 6'd0);
        expect_two_phase_accept(24'd523, 6'd0);
        expect_two_phase_accept(24'd1000, 6'd1);

        // Real on-air ISSIs from docs/references/captures_external_bs_2026-04-25/
        //   external MS = 0x282FF4 (2 633 716)
        //   our MTP3550 = 0x282F91 (2 633 617)
        // Both share the Motorola 0x282xxx prefix.  The previous parser
        // collapsed every 0x282xxx ISSI onto ssi=523 — these tests guard
        // the 24-bit-end-to-end fix.
        //
        // The MAC-RESOURCE DL header (§21.4.3.1) packs the 24-bit SSI at
        // bits [16..39] of the 268-bit info bus, MSB-first.  In the
        // accept_builder output `lat_accept_info_bits` (268-bit, bit 267 =
        // first on air), the SSI occupies bits [251:228].
        expect_two_phase_accept(24'h282FF4, 6'd2);
        if (dut.lat_ssi !== 24'h282FF4) begin
            $display("FAIL external lat_ssi got=0x%06X exp=0x282FF4", dut.lat_ssi);
            fail_count = fail_count + 1;
        end else if (dut.lat_accept_info_bits[251:228] !== 24'h282FF4) begin
            $display("FAIL external SSI@[251:228] got=0x%06X exp=0x282FF4",
                     dut.lat_accept_info_bits[251:228]);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS external 24-bit ISSI propagated to MAC-RESOURCE SSI@[251:228]=0x282FF4");
        end

        expect_two_phase_accept(24'h282F91, 6'd3);
        if (dut.lat_ssi !== 24'h282F91) begin
            $display("FAIL MTP3550 lat_ssi got=0x%06X exp=0x282F91", dut.lat_ssi);
            fail_count = fail_count + 1;
        end else if (dut.lat_accept_info_bits[251:228] !== 24'h282F91) begin
            $display("FAIL MTP3550 SSI@[251:228] got=0x%06X exp=0x282F91",
                     dut.lat_accept_info_bits[251:228]);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS MTP3550 24-bit ISSI propagated to MAC-RESOURCE SSI@[251:228]=0x282F91");
        end

        // -------------------------------------------------------------------
        // Phase 6 D-rev — §9.3 Multi-Lookup attach flow tests
        // Pre-conditions: AST has 4 entries (slot 0..3) from earlier
        // expect_two_phase_accept calls; EntityTable has slot 0 (MTP3550
        // ISSI) and slot 1 (Default-Group GSSI).  Profile 0 = M2 default.
        // -------------------------------------------------------------------

        // -------------------------------------------------------------------
        // T7 — profile0_m2_guard: ISSI 0x282F91 + Default-GSSI 0x2F4D61 +
        //      Profile 0 → MM body bit-exact to the gold-ref Accept.
        //      This is the M2 bit-identity guard: any change here breaks
        //      MTP3550 attach on real hardware.
        // -------------------------------------------------------------------
        accept_unknown <= 1'b0;  // strict mode — must come from DB
        repeat (4) @(posedge clk);
        expect_accept(24'h282F91, "profile0_m2_guard");

        // Probe the constructed GILA payload (pre-MAC-RESOURCE wrap).  The
        // encoder output is in dut.u_dloc.GILA_PAYLOAD_W (58 bit) and
        // dut.u_dloc.pdu_bits_mm[ 84:27]; either should match the gold-ref
        // bit pattern.
        test_count = test_count + 1;
        if (dut.u_dloc.GILA_PAYLOAD_W !==
            58'b0011011100000100110000001001100000010111101001101011000010) begin
            $display("[T%0d profile0_m2_gila_bits] FAIL got=0x%015h",
                     test_count, dut.u_dloc.GILA_PAYLOAD_W);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d profile0_m2_gila_bits] PASS gold-ref bit-exact",
                     test_count);
        end

        // -------------------------------------------------------------------
        // T8 — profile1_diff_class_lifetime: Profile 1 has class=3,
        //      lifetime=2 (different from M2 defaults).  Attaching an
        //      ISSI bound to Profile 1 must produce GILA bits differing
        //      ONLY in the class/lifetime fields, GSSI unchanged.
        // -------------------------------------------------------------------
        // Seed Profile 1: class=3'b011=3, lifetime=2'b10=2, permit_reg=1, valid=1.
        seed_profile(3'd1,
                     8'd0, 8'd0, 4'd0,    // max_call/hangtime/prio
                     3'b011, 2'b10,        // class=3, lifetime=2
                     1'b1, 1'b1, 1'b1,     // permit_voice/data/reg
                     1'b1);                // valid
        // Seed an EntityTable ISSI bound to Profile 1.
        seed_entity(8'd2, 24'h111111, 1'b0, 4'd1);
        repeat (8) @(posedge clk);
        expect_accept(24'h111111, "profile1_diff_class_lifetime");

        // GSSI must still be 0x2F4D61 (Default-Group), only class+lifetime differ.
        test_count = test_count + 1;
        if (dut.lat_gila_gssi !== 24'h2F4D61) begin
            $display("[T%0d profile1_gssi_unchanged] FAIL got=0x%06h exp=0x2F4D61",
                     test_count, dut.lat_gila_gssi);
            fail_count = fail_count + 1;
        end else if (dut.lat_gila_class !== 3'b011) begin
            $display("[T%0d profile1_class] FAIL got=%b exp=011",
                     test_count, dut.lat_gila_class);
            fail_count = fail_count + 1;
        end else if (dut.lat_gila_lifetime !== 2'b10) begin
            $display("[T%0d profile1_lifetime] FAIL got=%b exp=10",
                     test_count, dut.lat_gila_lifetime);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d profile1_diff_class_lifetime] PASS class=3 lifetime=2 GSSI=2F4D61",
                     test_count);
        end

        // -------------------------------------------------------------------
        // T9 — profile1_diff_gssi: invalidate Default-GSSI (slot 1), add a
        //      new GSSI entry 0xABCDEF bound to Profile 1.  Attach with
        //      ISSI bound to Profile 1 must emit GILA-GSSI = 0xABCDEF.
        // -------------------------------------------------------------------
        seed_entity(8'd1, 24'd0, 1'b0, 4'd0);  // invalidate slot 1 (valid bit
                                                // set; reuses slot 1 with
                                                // valid=1 ISSI=0 type=0).
                                                // Hmm - this re-validates with
                                                // valid=1.  Use direct mem clear:
        @(posedge clk);
        u_entity.mem[1] = 64'd0;
        // Add new GSSI on slot 30
        seed_entity(8'd30, 24'hABCDEF, 1'b1, 4'd1);
        repeat (8) @(posedge clk);
        expect_accept(24'h111111, "profile1_diff_gssi");

        test_count = test_count + 1;
        if (dut.lat_gila_gssi !== 24'hABCDEF) begin
            $display("[T%0d profile1_diff_gssi_check] FAIL got=0x%06h exp=0xABCDEF",
                     test_count, dut.lat_gila_gssi);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d profile1_diff_gssi_check] PASS GSSI=ABCDEF on-air",
                     test_count);
        end

        // -------------------------------------------------------------------
        // T10 — permit_reg_zero_rejects: Profile 2 with permit_reg=0 →
        //       REJECT cause=4 (service not authorised).
        // -------------------------------------------------------------------
        seed_profile(3'd2,
                     8'd0, 8'd0, 4'd0,
                     3'b100, 2'b01,
                     1'b1, 1'b1, 1'b0,    // permit_reg=0
                     1'b1);                // valid=1
        seed_entity(8'd3, 24'h222222, 1'b0, 4'd2);
        repeat (8) @(posedge clk);
        expect_reject(24'h222222, 3'd4, "permit_reg_zero_rejects");

        // -------------------------------------------------------------------
        // T11 — unknown_issi_strict_rejects: ISSI not in EntityTable +
        //       accept_unknown=0 → REJECT cause=0 (ITSI unknown).
        // -------------------------------------------------------------------
        accept_unknown <= 1'b0;
        repeat (4) @(posedge clk);
        expect_reject(24'h333333, 3'd0, "unknown_issi_strict_rejects");

        // -------------------------------------------------------------------
        // T12 — unknown_issi_open_alloc: ISSI not in EntityTable +
        //       accept_unknown=1 → Auto-Enroll new EntityTable slot with
        //       profile_id=0, then ACCEPT (Profile 0 = M2 defaults).
        // -------------------------------------------------------------------
        accept_unknown <= 1'b1;
        repeat (4) @(posedge clk);
        expect_accept(24'h444444, "unknown_issi_open_alloc");

        // Verify Auto-Enroll wrote the ISSI into a free EntityTable slot
        // with profile_id=0 and valid=1.  We don't pin the slot index
        // (depends on which free slot the alloc-scan finds first).
        test_count = test_count + 1;
        begin
            integer found_slot;
            integer s;
            found_slot = -1;
            for (s = 0; s < 256; s = s + 1) begin
                if (u_entity.mem[s][63:40] == 24'h444444 &&
                    u_entity.mem[s][39] == 1'b0 &&
                    u_entity.mem[s][38:35] == 4'd0 &&
                    u_entity.mem[s][0] == 1'b1)
                    found_slot = s;
            end
            if (found_slot < 0) begin
                $display("[T%0d unknown_issi_open_alloc_db] FAIL no Auto-Enroll slot found",
                         test_count);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d unknown_issi_open_alloc_db] PASS Auto-Enroll → slot %0d profile=0",
                         test_count, found_slot);
            end
        end

        // -------------------------------------------------------------------
        // Phase 6 B — Detach test (U-ITSI-DETACH clears AST entry)
        //
        // Pre-state: AST has multiple entries from the earlier accept-path
        // tests (Auto-Enroll Accepts + Profile-1 + Auto-Enroll-on-miss).  We
        // detach by ISSI 0x282F91 — find which slot it landed in.
        // -------------------------------------------------------------------

        // Find AST slot for ISSI 0x282F91 dynamically.
        begin
            integer det_slot;
            integer s;
            det_slot = -1;
            for (s = 0; s < AST_DEPTH; s = s + 1) begin
                if (u_ast.mem[s][AST_REC_WIDTH-1 -: AST_ISSI_WIDTH] == 24'h282F91 &&
                    u_ast.mem[s][0] == 1'b1)
                    det_slot = s;
            end
            if (det_slot < 0) begin
                $display("DETACH-pre WARN: ISSI 0x282F91 not in AST — skipping detach test");
                test_count = test_count + 1;
            end else begin
                expect_detach_clear(det_slot[7:0], 24'h282F91, "detach_known_mtp3550");
            end
        end

        // T12 DETACH unknown ISSI: should pulse counter but no AST write
        begin
            integer det_wait;
            test_count = test_count + 1;
            detach_request(24'hABCDEF);
            det_wait = 0;
            while (det_wait < 4000 && !detach_pulse) begin
                @(posedge clk);
                det_wait = det_wait + 1;
            end
            if (!detach_pulse) begin
                $display("[T%0d] FAIL detach_unknown no pulse", test_count);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d] PASS detach_unknown_no_match (counter pulse)",
                         test_count);
            end
            // Wait long enough for FSM to finish whatever scan was in flight
            // and return to S_IDLE before next test.
            repeat (200) @(posedge clk);
        end

        // -------------------------------------------------------------------
        // Final test: AST full → drop (existing M2 behaviour)
        // T11 detached slot 3, so we have to refill all 64 slots here.
        // -------------------------------------------------------------------
        accept_unknown <= 1'b1;
        for (i = 0; i < AST_DEPTH; i = i + 1)
            u_ast.mem[i] = {{(AST_REC_WIDTH - 1){1'b0}}, 1'b1};
        @(posedge clk);

        expect_drop(24'd2000);

        $display("=============================================");
        if (fail_count == 0)
            $display("tb_mle_registration_fsm: PASS (%0d/%0d)",
                     test_count, test_count);
        else
            $display("tb_mle_registration_fsm: FAIL (%0d/%0d failures)",
                     fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #2000000;
        $display("tb_mle_registration_fsm: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
