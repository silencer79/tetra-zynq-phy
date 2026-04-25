// =============================================================================
// tb_entity_table.v — unit test for tetra_entity_table (Phase 6 D-rev)
//
// Verifies the §9.2 EntityTable record layout:
//   [63:40] entity_id  [39] entity_type  [38:35] profile_id
//   [34:1]  reserved=0 [0] valid
// and the three lookup modes:
//   - id-only match (q_match_type=0)
//   - (id, type) match (q_match_type=1)
//   - default-GSSI scan (q_default_gssi_scan=1, find first valid entity_type=1)
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_entity_table;
    localparam integer DEPTH      = 256;
    localparam integer IDX_WIDTH  = 8;
    localparam integer REC_WIDTH  = 64;
    localparam integer ID_WIDTH   = 24;

    reg                       clk   = 1'b0;
    reg                       rst_n = 1'b0;
    reg  [IDX_WIDTH-1:0]      wr_idx  = 0;
    reg  [REC_WIDTH-1:0]      wr_data = 0;
    reg                       wr_en   = 1'b0;
    reg                       q_start = 1'b0;
    reg  [ID_WIDTH-1:0]       q_id    = 0;
    reg                       q_type  = 1'b0;
    reg                       q_match_type        = 1'b0;
    reg                       q_default_gssi_scan = 1'b0;
    reg                       q_alloc             = 1'b0;
    wire                      q_busy;
    wire                      q_done;
    wire                      q_hit;
    wire [IDX_WIDTH-1:0]      q_slot;
    wire [REC_WIDTH-1:0]      q_record;

    always #5 clk = ~clk;

    tetra_entity_table #(
        .DEPTH    (DEPTH),
        .IDX_WIDTH(IDX_WIDTH),
        .REC_WIDTH(REC_WIDTH),
        .ID_WIDTH (ID_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_idx  (wr_idx),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .q_start (q_start),
        .q_id    (q_id),
        .q_type  (q_type),
        .q_match_type        (q_match_type),
        .q_default_gssi_scan (q_default_gssi_scan),
        .q_alloc             (q_alloc),
        .q_busy  (q_busy),
        .q_done  (q_done),
        .q_hit   (q_hit),
        .q_slot  (q_slot),
        .q_record(q_record)
    );

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    // Build a §9.2 record:
    //   [63:40]=entity_id  [39]=entity_type  [38:35]=profile_id
    //   [34:1]=0           [0]=valid
    function [REC_WIDTH-1:0] pack_rec(
        input [ID_WIDTH-1:0] entity_id,
        input                entity_type,
        input [3:0]          profile_id,
        input                valid
    );
        begin
            pack_rec = {entity_id, entity_type, profile_id, 34'd0, valid};
        end
    endfunction

    task automatic write_rec(input [IDX_WIDTH-1:0]  idx,
                             input [REC_WIDTH-1:0]  rec);
        begin
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

    task automatic do_lookup(input [ID_WIDTH-1:0] id,
                             input                etype,
                             input                match_type,
                             input                default_gssi);
        begin
            @(posedge clk);
            q_id                <= id;
            q_type              <= etype;
            q_match_type        <= match_type;
            q_default_gssi_scan <= default_gssi;
            q_alloc             <= 1'b0;
            q_start             <= 1'b1;
            @(posedge clk);
            q_start             <= 1'b0;
        end
    endtask

    task automatic do_alloc;
        begin
            @(posedge clk);
            q_id                <= 24'd0;
            q_type              <= 1'b0;
            q_match_type        <= 1'b0;
            q_default_gssi_scan <= 1'b0;
            q_alloc             <= 1'b1;
            q_start             <= 1'b1;
            @(posedge clk);
            q_start             <= 1'b0;
            q_alloc             <= 1'b0;
        end
    endtask

    task automatic wait_done;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!q_done && wait_cycles < DEPTH+10) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
        end
    endtask

    task automatic check(input [255:0] tag,
                         input         exp_hit,
                         input [IDX_WIDTH-1:0] exp_slot);
        begin
            test_count = test_count + 1;
            if (!q_done) begin
                $display("[T%0d %0s] TIMEOUT", test_count, tag);
                fail_count = fail_count + 1;
            end else if (q_hit !== exp_hit) begin
                $display("[T%0d %0s] FAIL exp_hit=%0d got_hit=%0d slot=%0d",
                         test_count, tag, exp_hit, q_hit, q_slot);
                fail_count = fail_count + 1;
            end else if (exp_hit && q_slot !== exp_slot) begin
                $display("[T%0d %0s] FAIL slot mismatch exp=%0d got=%0d",
                         test_count, tag, exp_slot, q_slot);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS hit=%0d slot=%0d",
                         test_count, tag, q_hit, q_slot);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    integer i;
    initial begin
        $dumpfile("sim_out/tb_entity_table.vcd");
        $dumpvars(0, tb_entity_table);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Clear all slots
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            wr_idx  <= i[IDX_WIDTH-1:0];
            wr_data <= {REC_WIDTH{1'b0}};
            wr_en   <= 1'b1;
        end
        @(posedge clk);
        wr_en <= 1'b0;
        @(posedge clk);

        // ----- Populate per §9.2 spec -----
        // Slot 0: MTP3550 ISSI, profile 0
        write_rec(8'd0,   pack_rec(24'h282F91, 1'b0, 4'd0, 1'b1));
        // Slot 1: Default Group GSSI, profile 0
        write_rec(8'd1,   pack_rec(24'h2F4D61, 1'b1, 4'd0, 1'b1));
        // Slot 2: another ISSI with profile_id=2
        write_rec(8'd2,   pack_rec(24'h123456, 1'b0, 4'd2, 1'b1));
        // Slot 17: ISSI with profile 1
        write_rec(8'd17,  pack_rec(24'h000001, 1'b0, 4'd1, 1'b1));
        // Slot 100: GSSI profile 3
        write_rec(8'd100, pack_rec(24'hABCDEF, 1'b1, 4'd3, 1'b1));
        // Slot 50: written but valid=0 (must NOT match)
        write_rec(8'd50,  pack_rec(24'h000042, 1'b0, 4'd0, 1'b0));

        @(posedge clk);

        // ----- T1..T5: id-only match (q_match_type=0) -----
        do_lookup(24'h282F91, 1'b0, 1'b0, 1'b0); wait_done;
        check("issi_mtp3550_id_only", 1'b1, 8'd0);

        do_lookup(24'h2F4D61, 1'b0, 1'b0, 1'b0); wait_done;
        check("gssi_default_id_only", 1'b1, 8'd1);

        do_lookup(24'h123456, 1'b0, 1'b0, 1'b0); wait_done;
        check("issi_extra_id_only", 1'b1, 8'd2);

        do_lookup(24'hABCDEF, 1'b0, 1'b0, 1'b0); wait_done;
        check("gssi_abcdef_id_only", 1'b1, 8'd100);

        // ----- T5..T8: (id, type) match (q_match_type=1) -----
        do_lookup(24'h282F91, 1'b0, 1'b1, 1'b0); wait_done;
        check("mtp3550_match_issi", 1'b1, 8'd0);

        do_lookup(24'h282F91, 1'b1, 1'b1, 1'b0); wait_done;
        check("mtp3550_wrong_type_miss", 1'b0, 8'd0);

        do_lookup(24'h2F4D61, 1'b1, 1'b1, 1'b0); wait_done;
        check("default_gssi_match_gssi", 1'b1, 8'd1);

        do_lookup(24'h2F4D61, 1'b0, 1'b1, 1'b0); wait_done;
        check("default_gssi_wrong_type_miss", 1'b0, 8'd0);

        // ----- T9: id miss -----
        do_lookup(24'hDEADBE, 1'b0, 1'b0, 1'b0); wait_done;
        check("id_never_written", 1'b0, 8'd0);

        // ----- T10: valid=0 must miss -----
        do_lookup(24'h000042, 1'b0, 1'b0, 1'b0); wait_done;
        check("written_but_valid0", 1'b0, 8'd0);

        // ----- T11..T12: default-GSSI scan finds slot 1 (first valid type=1) -----
        do_lookup(24'd0, 1'b0, 1'b0, 1'b1); wait_done;
        check("default_gssi_scan_finds_slot1", 1'b1, 8'd1);

        // After invalidating slot 1, scan should find slot 100 (next GSSI).
        write_rec(8'd1, {REC_WIDTH{1'b0}});
        do_lookup(24'd0, 1'b0, 1'b0, 1'b1); wait_done;
        check("default_gssi_scan_advances_to_100", 1'b1, 8'd100);

        // ----- T13: with all GSSIs invalid, default-scan misses -----
        write_rec(8'd100, {REC_WIDTH{1'b0}});
        do_lookup(24'd0, 1'b0, 1'b0, 1'b1); wait_done;
        check("default_gssi_scan_no_gssi", 1'b0, 8'd0);

        // ----- T14: profile_id field round-trip via record -----
        do_lookup(24'h000001, 1'b0, 1'b0, 1'b0); wait_done;
        // Record check: profile_id = bits [38:35] = 4'd1
        test_count = test_count + 1;
        if (q_hit !== 1'b1 || q_record[38:35] !== 4'd1) begin
            $display("[T%0d profile_id_roundtrip] FAIL hit=%b record_pid=%0d exp=1",
                     test_count, q_hit, q_record[38:35]);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d profile_id_roundtrip] PASS profile_id=1",
                     test_count);
        end

        // ----- T15: entity_type bit projection (re-seed since slot 100
        //            was invalidated in T13) -----
        write_rec(8'd200, pack_rec(24'hABCDEF, 1'b1, 4'd3, 1'b1));
        do_lookup(24'hABCDEF, 1'b0, 1'b0, 1'b0); wait_done;
        test_count = test_count + 1;
        if (q_hit !== 1'b1 || q_record[39] !== 1'b1) begin
            $display("[T%0d entity_type_bit] FAIL hit=%b record_type=%b exp=1",
                     test_count, q_hit, q_record[39]);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d entity_type_bit] PASS entity_type=1 (GSSI)",
                     test_count);
        end

        // ----- T16: ensure NO permits/LA bits (reserved=0 sanity) -----
        do_lookup(24'h282F91, 1'b0, 1'b0, 1'b0); wait_done;
        test_count = test_count + 1;
        if (q_hit !== 1'b1 || q_record[34:1] !== 34'd0) begin
            $display("[T%0d reserved_zero] FAIL record[34:1]=0x%h exp=0",
                     test_count, q_record[34:1]);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d reserved_zero] PASS reserved bits all zero",
                     test_count);
        end

        // ----- T17: alloc mode finds first free slot (slot 1, after T11
        //            invalidated it).  Slot 0/2/17/200 still occupied; we
        //            verify alloc returns slot 1 (not 100, since T13 cleared
        //            slot 100 too — actually slot 1 was cleared first).
        do_alloc; wait_done;
        check("alloc_finds_first_free", 1'b1, 8'd1);

        // ----- T18: write the alloc'd slot, alloc again finds NEXT free -----
        write_rec(8'd1, pack_rec(24'h111111, 1'b0, 4'd0, 1'b1));
        do_alloc; wait_done;
        // Slot 0/1/2/17/200 all valid now. Slot 100 was invalidated in T13.
        // Alloc should return slot 3 (lowest free index).
        check("alloc_finds_next_free_after_write", 1'b1, 8'd3);

        // ----- Summary -----
        $display("=============================================");
        if (fail_count == 0)
            $display("tb_entity_table: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_entity_table: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #500000;
        $display("tb_entity_table: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
