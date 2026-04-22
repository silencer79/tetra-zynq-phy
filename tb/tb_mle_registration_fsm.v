// =============================================================================
// tb_mle_registration_fsm.v — integration test for the MLE registration FSM
// connected to a real tetra_active_session_table instance.
//
// Scenarios:
//   1. Empty table, UL req with ISSI=523/LA=36 → alloc slot 0, ACCEPT, deliver
//      coded_bits that match the SCH/HD bit-exact vector from the encoder TB
//      (same input: D-LOC-UPDATE ACCEPT with SSI=523 LA=36 cfg_la=36).
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
    wire [215:0] dl_pdu_bits;
    wire         dl_pdu_valid;
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
        .dl_pdu_bits      (dl_pdu_bits),
        .dl_pdu_valid     (dl_pdu_valid),
        .busy             (busy),
        .accept_pulse     (accept_pulse),
        .drop_pulse       (drop_pulse)
    );

    integer fail_count = 0;
    integer test_count = 0;

    // Known coded bits for ACCEPT/SSI=523/LA=36/cfg_scramble=E1670C03 from
    // tb_sch_hd_encoder T4 (D-LOC-UPDATE ACCEPT with subscriber_class=0x0000
    // instead of 0x1234 — FSM uses 0x0000 MVP placeholder).
    // Recompute with gen_sch_hd_tv.py if either constant changes.
    localparam [215:0] EXPECTED_ACCEPT_523_36 =
        216'h5a2ac591e7291b9234553e4750bf87cbcc5dc8ade299a1338f8cf6;

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

    task automatic wait_for_result(output reg       got_accept,
                                   output reg       got_drop,
                                   output reg [AST_IDX_WIDTH-1:0] got_slot,
                                   output reg [215:0] got_bits);
        integer wait_cycles;
        begin
            got_accept  = 1'b0;
            got_drop    = 1'b0;
            got_slot    = {AST_IDX_WIDTH{1'b0}};
            got_bits    = 216'd0;
            wait_cycles = 0;
            while (wait_cycles < 2000 && !got_accept && !got_drop) begin
                @(posedge clk);
                if (dl_pdu_valid) begin
                    got_accept = 1'b1;
                    got_bits   = dl_pdu_bits;
                    got_slot   = ast_wr_idx;   // last written slot
                end
                if (drop_pulse) got_drop = 1'b1;
                wait_cycles = wait_cycles + 1;
            end
        end
    endtask

    task automatic expect_accept(input [23:0] issi,
                                 input [AST_IDX_WIDTH-1:0] exp_slot,
                                 input [215:0] exp_bits,
                                 input        check_bits,
                                 input [63:0] tag);
        reg       got_accept;
        reg       got_drop;
        reg [AST_IDX_WIDTH-1:0] got_slot;
        reg [215:0]             got_bits;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_for_result(got_accept, got_drop, got_slot, got_bits);
            if (!got_accept) begin
                $display("[T%0d %0s] FAIL: expected ACCEPT, got drop=%0d",
                         test_count, tag, got_drop);
                fail_count = fail_count + 1;
            end else if (got_slot !== exp_slot) begin
                $display("[T%0d %0s] FAIL slot: got=%0d exp=%0d",
                         test_count, tag, got_slot, exp_slot);
                fail_count = fail_count + 1;
            end else if (check_bits && got_bits !== exp_bits) begin
                $display("[T%0d %0s] FAIL bits:", test_count, tag);
                $display("  got = %054h", got_bits);
                $display("  exp = %054h", exp_bits);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS slot=%0d coded=%054h",
                         test_count, tag, got_slot, got_bits);
            end
        end
    endtask

    task automatic expect_drop(input [23:0] issi, input [63:0] tag);
        reg       got_accept;
        reg       got_drop;
        reg [AST_IDX_WIDTH-1:0] got_slot;
        reg [215:0]             got_bits;
        begin
            test_count = test_count + 1;
            push_request(issi, 14'd36);
            wait_for_result(got_accept, got_drop, got_slot, got_bits);
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

        // T1: first registration — empty table → alloc slot 0, check bits
        expect_accept(24'd523, 6'd0, EXPECTED_ACCEPT_523_36, 1'b1, "first_reg");

        // T2: same ISSI → query hits slot 0, reused
        expect_accept(24'd523, 6'd0, 216'd0, 1'b0, "reregister");

        // T3: new ISSI → alloc slot 1
        expect_accept(24'd1000, 6'd1, 216'd0, 1'b0, "second_ms");

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
