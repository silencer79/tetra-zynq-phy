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
    localparam integer AST_REC_WIDTH  = 64;
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
        .lost_pulse       (lost_pulse)
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
        @(posedge clk);

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

        for (i = 4; i < AST_DEPTH; i = i + 1)
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
