// =============================================================================
// tb_subscriber_shadow.v — unit test for tetra_subscriber_shadow
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_subscriber_shadow;
    localparam integer DEPTH      = 256;
    localparam integer IDX_WIDTH  = 8;
    localparam integer REC_WIDTH  = 64;
    localparam integer ISSI_WIDTH = 24;

    reg                       clk   = 1'b0;
    reg                       rst_n = 1'b0;
    reg  [IDX_WIDTH-1:0]      wr_idx  = 0;
    reg  [REC_WIDTH-1:0]      wr_data = 0;
    reg                       wr_en   = 1'b0;
    reg                       q_start = 1'b0;
    reg  [ISSI_WIDTH-1:0]     q_issi  = 0;
    wire                      q_busy;
    wire                      q_done;
    wire                      q_hit;
    wire [IDX_WIDTH-1:0]      q_slot;
    wire [REC_WIDTH-1:0]      q_record;

    // 100 MHz
    always #5 clk = ~clk;

    tetra_subscriber_shadow #(
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

    integer fail_count = 0;
    integer test_count = 0;

    task automatic lookup_and_check(input [ISSI_WIDTH-1:0] issi,
                                    input                  exp_hit,
                                    input [IDX_WIDTH-1:0]  exp_slot,
                                    input [31:0]           tag);
        integer wait_cycles;
        begin
            test_count = test_count + 1;
            @(posedge clk);
            q_issi  <= issi;
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
                $display("[T%0d tag=%0d] FAIL issi=%06h exp_hit=%0d got_hit=%0d slot=%0d",
                         test_count, tag, issi, exp_hit, q_hit, q_slot);
                fail_count = fail_count + 1;
            end else if (exp_hit && q_slot !== exp_slot) begin
                $display("[T%0d tag=%0d] FAIL slot mismatch exp=%0d got=%0d",
                         test_count, tag, exp_slot, q_slot);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d tag=%0d] PASS issi=%06h hit=%0d slot=%0d (scan_cycles=%0d)",
                         test_count, tag, issi, q_hit, q_slot, wait_cycles);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    initial begin
        $dumpfile("sim_out/tb_subscriber_shadow.vcd");
        $dumpvars(0, tb_subscriber_shadow);

        // Reset
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Populate a handful of slots (skip 0 so we can check "empty-at-0" path)
        write_rec(8'd1,   24'h00_020B, 1'b1);  // ISSI 523 (MTP3550 live-seen)
        write_rec(8'd2,   24'h12_3456, 1'b1);
        write_rec(8'd17,  24'h00_0001, 1'b1);
        write_rec(8'd100, 24'hAB_CDEF, 1'b1);
        write_rec(8'd255, 24'hFF_FFFF, 1'b1);

        // Occupied but valid=0 (must NOT match)
        write_rec(8'd50,  24'h00_0042, 1'b0);

        @(posedge clk);

        // ----- Hits -----
        lookup_and_check(24'h00_020B, 1'b1, 8'd1,   1);
        lookup_and_check(24'h12_3456, 1'b1, 8'd2,   2);
        lookup_and_check(24'h00_0001, 1'b1, 8'd17,  3);
        lookup_and_check(24'hAB_CDEF, 1'b1, 8'd100, 4);
        lookup_and_check(24'hFF_FFFF, 1'b1, 8'd255, 5);

        // ----- Misses -----
        lookup_and_check(24'h00_0000, 1'b0, 8'd0,   6);  // empty & zero-issi
        lookup_and_check(24'hDE_ADBE, 1'b0, 8'd0,   7);  // never written
        lookup_and_check(24'h00_0042, 1'b0, 8'd0,   8);  // written but valid=0

        // ----- Overwrite and re-query -----
        write_rec(8'd2, 24'h00_ABCD, 1'b1);
        lookup_and_check(24'h00_ABCD, 1'b1, 8'd2,   9);
        lookup_and_check(24'h12_3456, 1'b0, 8'd0,  10); // old issi must be gone

        // ----- Back-to-back -----
        lookup_and_check(24'h00_020B, 1'b1, 8'd1,  11);
        lookup_and_check(24'hAB_CDEF, 1'b1, 8'd100,12);

        // ----- Summary -----
        $display("=============================================");
        if (fail_count == 0)
            $display("tb_subscriber_shadow: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_subscriber_shadow: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    // Safety timeout
    initial begin
        #500000;
        $display("tb_subscriber_shadow: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
