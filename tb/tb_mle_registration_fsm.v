// =============================================================================
// tb_mle_registration_fsm.v — integration test for the MLE registration FSM
// connected to a real tetra_active_session_table instance.
//
// FSM now wraps the D-LOC-UPDATE-ACCEPT MM PDU in a MAC-RESOURCE DL PDU
// (via tetra_mac_resource_dl_builder, 268 info bits) and runs it through
// the SCH/F encoder (→ 432 coded bits), emitting the full 432-bit codeword
// as a queue-request (req_valid + req_coded_bits + req_pdu_type +
// req_target_tn) for tetra_dl_signal_queue.  Post-refactor the FSM no
// longer exposes the blk1/blk2 split; the scheduler/mux do the split.
//
// Scenarios:
//   1. Empty table, UL req with ISSI=523/LA=36 → alloc slot 0, ACCEPT, deliver
//      coded bits that match the Python SCH/F reference (full chain:
//      builder golden EXPECTED_1 → SCH/F encode, init=0xE1670C03).
//   2. Re-register same ISSI → query hit, reuse slot 0, ACCEPT again.
//   3. Different ISSI → alloc slot 1.
//   4. Fill table, next request → drop_pulse (MVP table-full behaviour).
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

    // ---- UL req stimulus ----
    reg         ul_req_valid = 1'b0;
    reg  [2:0]  ul_addr_type = 3'd1;
    reg  [23:0] ul_ssi       = 24'd0;
    reg  [13:0] ul_la        = 14'd0;

    // ---- Cell config ----
    reg [13:0]  cfg_la            = 14'd36;
    reg [31:0]  cfg_scramble_init = 32'hE1670C03;
    reg [1:0]   cfg_mcch_tn       = 2'd1;

    // ---- FSM <-> AST wiring ----
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

    // ---- FSM outputs ----
    wire         req_valid;
    wire [431:0] req_coded_bits;
    wire [1:0]   req_pdu_type;
    wire [1:0]   req_target_tn;
    wire         busy;
    wire         accept_pulse;
    wire         drop_pulse;

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
        .cfg_la           (cfg_la),
        .cfg_scramble_init(cfg_scramble_init),
        .cfg_mcch_tn      (cfg_mcch_tn),
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
        .busy             (busy),
        .accept_pulse     (accept_pulse),
        .drop_pulse       (drop_pulse)
    );

    integer fail_count = 0;
    integer test_count = 0;

    // Known SCH/F coded bits for ACCEPT/SSI=523/subs_class=0/NS=NR=0
    // wrapped via MAC-RESOURCE builder EXPECTED_1 (see
    // tb_mac_resource_dl_builder.v) and encoded with scramble_init
    // 0xE1670C03.  Golden = Python reference scripts/gen_sch_f_tv.py
    // (encode_sch_f(info=EXPECTED_1, init=0xE1670C03)).  Split:
    //   blk1 = coded[431:216] (MSB half, first on air)
    //   blk2 = coded[215:  0] (LSB half)
    // Recompute if MM PDU layout or scrambler seed changes.
    localparam [215:0] EXPECTED_ACCEPT_523_BLK1 =
        216'h1a52ad41e2a96e829c67af8b763d1d4b8979da4db37ba5d1371896;
    localparam [215:0] EXPECTED_ACCEPT_523_BLK2 =
        216'hc507df3b7996d7a6eff7946978ac255c918a8aadaf96db8668a282;

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

    task automatic wait_for_result(output reg         got_accept,
                                   output reg         got_drop,
                                   output reg [AST_IDX_WIDTH-1:0] got_slot,
                                   output reg [431:0] got_coded,
                                   output reg [1:0]   got_target_tn,
                                   output reg [1:0]   got_pdu_type);
        integer wait_cycles;
        begin
            got_accept    = 1'b0;
            got_drop      = 1'b0;
            got_slot      = {AST_IDX_WIDTH{1'b0}};
            got_coded     = 432'd0;
            got_target_tn = 2'd0;
            got_pdu_type  = 2'd0;
            wait_cycles   = 0;
            while (wait_cycles < 4000 && !got_accept && !got_drop) begin
                @(posedge clk);
                if (req_valid) begin
                    got_accept    = 1'b1;
                    got_coded     = req_coded_bits;
                    got_target_tn = req_target_tn;
                    got_pdu_type  = req_pdu_type;
                    got_slot      = ast_wr_idx;
                end
                if (drop_pulse) got_drop = 1'b1;
                wait_cycles = wait_cycles + 1;
            end
        end
    endtask

    task automatic expect_accept(input [23:0] issi,
                                 input [AST_IDX_WIDTH-1:0] exp_slot,
                                 input [215:0] exp_blk1,
                                 input [215:0] exp_blk2,
                                 input        check_bits,
                                 input [63:0] tag);
        reg       got_accept;
        reg       got_drop;
        reg [AST_IDX_WIDTH-1:0] got_slot;
        reg [431:0]             got_coded;
        reg [1:0]               got_target_tn;
        reg [1:0]               got_pdu_type;
        reg [215:0]             got_blk1;
        reg [215:0]             got_blk2;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_for_result(got_accept, got_drop, got_slot,
                            got_coded, got_target_tn, got_pdu_type);
            got_blk1 = got_coded[431:216];
            got_blk2 = got_coded[215:  0];
            if (!got_accept) begin
                $display("[T%0d %0s] FAIL: expected ACCEPT, got drop=%0d",
                         test_count, tag, got_drop);
                fail_count = fail_count + 1;
            end else if (got_slot !== exp_slot) begin
                $display("[T%0d %0s] FAIL slot: got=%0d exp=%0d",
                         test_count, tag, got_slot, exp_slot);
                fail_count = fail_count + 1;
            end else if (got_target_tn !== cfg_mcch_tn) begin
                $display("[T%0d %0s] FAIL target_tn: got=%0d exp=%0d",
                         test_count, tag, got_target_tn, cfg_mcch_tn);
                fail_count = fail_count + 1;
            end else if (got_pdu_type !== 2'd0) begin
                $display("[T%0d %0s] FAIL pdu_type: got=%0d exp=0 (SCH_F)",
                         test_count, tag, got_pdu_type);
                fail_count = fail_count + 1;
            end else if (check_bits && (got_blk1 !== exp_blk1 ||
                                         got_blk2 !== exp_blk2)) begin
                $display("[T%0d %0s] FAIL bits:", test_count, tag);
                $display("  got blk1 = %054h", got_blk1);
                $display("  exp blk1 = %054h", exp_blk1);
                $display("  got blk2 = %054h", got_blk2);
                $display("  exp blk2 = %054h", exp_blk2);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS slot=%0d tn=%0d type=%0d",
                         test_count, tag, got_slot, got_target_tn, got_pdu_type);
            end
        end
    endtask

    task automatic expect_drop(input [23:0] issi, input [63:0] tag);
        reg       got_accept;
        reg       got_drop;
        reg [AST_IDX_WIDTH-1:0] got_slot;
        reg [431:0]             got_coded;
        reg [1:0]               got_target_tn;
        reg [1:0]               got_pdu_type;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_for_result(got_accept, got_drop, got_slot,
                            got_coded, got_target_tn, got_pdu_type);
            if (!got_drop) begin
                $display("[T%0d %0s] FAIL: expected DROP, got accept=%0d",
                         test_count, tag, got_accept);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS drop (table full)", test_count, tag);
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("sim_out/tb_mle_registration_fsm.vcd");
        $dumpvars(0, tb_mle_registration_fsm);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Clear AST (BRAM may contain X on reset)
        for (i = 0; i < AST_DEPTH; i = i + 1) begin
            u_ast.mem[i] = {AST_REC_WIDTH{1'b0}};
        end
        @(posedge clk);

        // T1: first registration — empty table → alloc slot 0, check both
        // SCH/F halves against Python-computed golden.
        expect_accept(24'd523, 6'd0,
                      EXPECTED_ACCEPT_523_BLK1,
                      EXPECTED_ACCEPT_523_BLK2,
                      1'b1, "first_reg");

        // T2: same ISSI → query hits slot 0, reused
        expect_accept(24'd523, 6'd0, 216'd0, 216'd0, 1'b0, "reregister");

        // T3: new ISSI → alloc slot 1
        expect_accept(24'd1000, 6'd1, 216'd0, 216'd0, 1'b0, "second_ms");

        // T4: fill remaining slots (2..63) so table is full
        for (i = 2; i < AST_DEPTH; i = i + 1) begin
            u_ast.mem[i] = {{(AST_REC_WIDTH - 1){1'b0}}, 1'b1};
        end
        @(posedge clk);

        // T5: new ISSI with full table → drop
        expect_drop(24'd2000, "full_drop");

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
