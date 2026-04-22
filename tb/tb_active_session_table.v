// =============================================================================
// tb_active_session_table.v — unit test for tetra_active_session_table
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_active_session_table;
    localparam integer DEPTH      = 64;
    localparam integer IDX_WIDTH  = 6;
    localparam integer REC_WIDTH  = 64;
    localparam integer ISSI_WIDTH = 24;

    localparam Q_QUERY = 1'b0;
    localparam Q_ALLOC = 1'b1;

    reg                      clk   = 1'b0;
    reg                      rst_n = 1'b0;
    reg  [IDX_WIDTH-1:0]     wr_idx  = 0;
    reg  [REC_WIDTH-1:0]     wr_data = 0;
    reg                      wr_en   = 1'b0;
    reg                      q_start = 1'b0;
    reg                      q_mode  = Q_QUERY;
    reg  [ISSI_WIDTH-1:0]    q_issi  = 0;
    wire                     q_busy;
    wire                     q_done;
    wire                     q_hit;
    wire [IDX_WIDTH-1:0]     q_slot;
    wire [REC_WIDTH-1:0]     q_record;

    always #5 clk = ~clk;

    tetra_active_session_table #(
        .DEPTH     (DEPTH),
        .IDX_WIDTH (IDX_WIDTH),
        .REC_WIDTH (REC_WIDTH),
        .ISSI_WIDTH(ISSI_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_idx  (wr_idx),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .q_start (q_start),
        .q_mode  (q_mode),
        .q_issi  (q_issi),
        .q_busy  (q_busy),
        .q_done  (q_done),
        .q_hit   (q_hit),
        .q_slot  (q_slot),
        .q_record(q_record)
    );

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    task automatic write_rec(input [IDX_WIDTH-1:0]  idx,
                             input [ISSI_WIDTH-1:0] issi,
                             input                  valid);
        reg [REC_WIDTH-1:0] rec;
        begin
            rec = {REC_WIDTH{1'b0}};
            rec[REC_WIDTH-1 -: ISSI_WIDTH] = issi;
            rec[0] = valid;
            @(posedge clk);
            wr_idx  <= idx;
            wr_data <= rec;
            wr_en   <= 1'b1;
            @(posedge clk);
            wr_en   <= 1'b0;
        end
    endtask

    task automatic clear_all;
        integer i;
        begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                @(posedge clk);
                wr_idx  <= i[IDX_WIDTH-1:0];
                wr_data <= {REC_WIDTH{1'b0}};
                wr_en   <= 1'b1;
            end
            @(posedge clk);
            wr_en <= 1'b0;
        end
    endtask

    integer fail_count = 0;
    integer test_count = 0;

    task automatic lookup_and_check(input                  mode,
                                    input [ISSI_WIDTH-1:0] issi,
                                    input                  exp_hit,
                                    input [IDX_WIDTH-1:0]  exp_slot,
                                    input [31:0]           tag);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            @(posedge clk);
            q_issi  <= issi;
            q_mode  <= mode;
            q_start <= 1'b1;
            @(posedge clk);
            q_start <= 1'b0;
            wait_cycles = 0;
            while (!q_done && wait_cycles < DEPTH+10) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!q_done) begin
                $display("[T%0d tag=%0d] TIMEOUT waiting for q_done", test_count, tag);
                fail_count = fail_count + 1;
            end else if (q_hit !== exp_hit) begin
                $display("[T%0d tag=%0d] FAIL mode=%0d issi=%06h exp_hit=%0d got_hit=%0d slot=%0d",
                         test_count, tag, mode, issi, exp_hit, q_hit, q_slot);
                fail_count = fail_count + 1;
            end else if (exp_hit && q_slot !== exp_slot) begin
                $display("[T%0d tag=%0d] FAIL slot mismatch exp=%0d got=%0d",
                         test_count, tag, exp_slot, q_slot);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d tag=%0d] PASS mode=%0d issi=%06h hit=%0d slot=%0d (scan=%0d)",
                         test_count, tag, mode, issi, q_hit, q_slot, wait_cycles);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    integer i;
    initial begin
        $dumpfile("sim_out/tb_active_session_table.vcd");
        $dumpvars(0, tb_active_session_table);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        clear_all;

        // Populate a handful of slots
        write_rec(6'd0,  24'h00_020B, 1'b1);
        write_rec(6'd1,  24'h12_3456, 1'b1);
        write_rec(6'd10, 24'h00_ABCD, 1'b1);
        write_rec(6'd63, 24'hFF_FFFF, 1'b1);

        @(posedge clk);

        // ----- Query hits -----
        lookup_and_check(Q_QUERY, 24'h00_020B, 1'b1, 6'd0,  1);
        lookup_and_check(Q_QUERY, 24'h12_3456, 1'b1, 6'd1,  2);
        lookup_and_check(Q_QUERY, 24'h00_ABCD, 1'b1, 6'd10, 3);
        lookup_and_check(Q_QUERY, 24'hFF_FFFF, 1'b1, 6'd63, 4);

        // ----- Query misses -----
        lookup_and_check(Q_QUERY, 24'hDE_AD00, 1'b0, 6'd0,  5);

        // ----- Alloc: first free slot should be 2 (0,1 taken, 10,63 taken) -----
        lookup_and_check(Q_ALLOC, 24'd0, 1'b1, 6'd2, 6);

        // Fill more — leaving slot 3 free — then alloc should return 3
        write_rec(6'd2, 24'h11_1111, 1'b1);
        lookup_and_check(Q_ALLOC, 24'd0, 1'b1, 6'd3, 7);

        // ----- Invalidate slot 0 (written with valid=0) → alloc finds it first -----
        write_rec(6'd0, 24'h00_0000, 1'b0);
        lookup_and_check(Q_ALLOC, 24'd0, 1'b1, 6'd0, 8);
        // Query for the now-invalid issi must miss
        lookup_and_check(Q_QUERY, 24'h00_020B, 1'b0, 6'd0, 9);

        // ----- Table-full scenario -----
        for (i = 0; i < DEPTH; i = i + 1) begin
            write_rec(i[IDX_WIDTH-1:0], 24'h00_1000 + i[ISSI_WIDTH-1:0], 1'b1);
        end
        lookup_and_check(Q_ALLOC, 24'd0, 1'b0, 6'd0, 10);   // full → miss
        lookup_and_check(Q_QUERY, 24'h00_1005, 1'b1, 6'd5, 11);

        // ----- Invalidate middle, alloc finds it -----
        write_rec(6'd42, 24'h00_0000, 1'b0);
        lookup_and_check(Q_ALLOC, 24'd0, 1'b1, 6'd42, 12);

        // ----- Summary -----
        $display("=============================================");
        if (fail_count == 0)
            $display("tb_active_session_table: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_active_session_table: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #500000;
        $display("tb_active_session_table: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
