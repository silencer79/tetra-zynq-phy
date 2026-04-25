// =============================================================================
// tb_profile_table.v — unit test for tetra_profile_table (Phase 6 D-rev)
//
// Verifies the §9.2 ProfileTable record layout:
//   [31:24] max_call_duration  [23:16] hangtime  [15:12] prio
//   [11:9]  gila_class         [8:7]  gila_lifetime
//   [6:4]   reserved           [3]    permit_voice
//   [2]     permit_data        [1]    permit_reg     [0] valid
// and the M2 bit-identity guard: Profile 0 reset-default = 0x0000_088F.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_profile_table;
    localparam integer DEPTH      = 6;
    localparam integer IDX_WIDTH  = 3;
    localparam integer REC_WIDTH  = 32;

    reg                       clk   = 1'b0;
    reg                       rst_n = 1'b0;
    reg  [IDX_WIDTH-1:0]      wr_idx  = 0;
    reg  [REC_WIDTH-1:0]      wr_data = 0;
    reg                       wr_en   = 1'b0;
    reg  [IDX_WIDTH-1:0]      rd_idx  = 0;
    wire [REC_WIDTH-1:0]      rd_data;

    always #5 clk = ~clk;

    tetra_profile_table #(
        .DEPTH    (DEPTH),
        .IDX_WIDTH(IDX_WIDTH),
        .REC_WIDTH(REC_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_idx  (wr_idx),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .rd_idx  (rd_idx),
        .rd_data (rd_data)
    );

    integer fail_count = 0;
    integer test_count = 0;

    // ---------------------------------------------------------------------
    // Helpers — pack/unpack §9.2 profile record
    // ---------------------------------------------------------------------
    function [REC_WIDTH-1:0] pack_profile;
        input [7:0] max_call_duration;
        input [7:0] hangtime;
        input [3:0] prio;
        input [2:0] gila_class;
        input [1:0] gila_lifetime;
        input       permit_voice;
        input       permit_data;
        input       permit_reg;
        input       valid;
        begin
            pack_profile = {
                max_call_duration,    // [31:24]
                hangtime,             // [23:16]
                prio,             // [15:12]
                gila_class,           // [11: 9]
                gila_lifetime,        // [ 8: 7]
                3'b000,               // [ 6: 4] reserved
                permit_voice,         // [ 3]
                permit_data,          // [ 2]
                permit_reg,           // [ 1]
                valid                 // [ 0]
            };
        end
    endfunction

    task automatic write_slot(input [IDX_WIDTH-1:0] idx,
                              input [REC_WIDTH-1:0] rec);
        begin
            @(posedge clk);
            wr_idx  <= idx;
            wr_data <= rec;
            wr_en   <= 1'b1;
            @(posedge clk);
            wr_en   <= 1'b0;
        end
    endtask

    task automatic read_and_check(input [IDX_WIDTH-1:0] idx,
                                  input [REC_WIDTH-1:0] exp,
                                  input [255:0]         tag);
        begin
            test_count = test_count + 1;
            @(posedge clk);
            rd_idx <= idx;
            // Read latency = 1 cycle (registered)
            @(posedge clk);
            @(posedge clk);
            if (rd_data !== exp) begin
                $display("[T%0d %0s] FAIL slot=%0d got=0x%08X exp=0x%08X",
                         test_count, tag, idx, rd_data, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("[T%0d %0s] PASS slot=%0d 0x%08X",
                         test_count, tag, idx, rd_data);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    initial begin
        $dumpfile("sim_out/tb_profile_table.vcd");
        $dumpvars(0, tb_profile_table);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ----- T1: Slot 0 reset default = 0x0000_088F (M2 bit-identity) -----
        // Bit-by-bit verification:
        //   gila_class    = 4   (3'b100)
        //   gila_lifetime = 1   (2'b01)
        //   permit_voice  = 1
        //   permit_data   = 1
        //   permit_reg    = 1
        //   valid         = 1
        //   everything else = 0
        read_and_check(3'd0, 32'h0000_088F, "slot0_reset_default");

        // ----- T2: bit-by-bit field decomposition of slot 0 default -----
        // (this is the Profile-0 M2 guard — must not drift)
        test_count = test_count + 1;
        if (rd_data[15:12] !== 4'd0) begin
            $display("[T%0d slot0_prio] FAIL got=%0d exp=0",
                     test_count, rd_data[15:12]);
            fail_count = fail_count + 1;
        end else if (rd_data[11:9] !== 3'b100) begin
            $display("[T%0d slot0_gila_class] FAIL got=%0d exp=4",
                     test_count, rd_data[11:9]);
            fail_count = fail_count + 1;
        end else if (rd_data[8:7] !== 2'b01) begin
            $display("[T%0d slot0_gila_lifetime] FAIL got=%0d exp=1",
                     test_count, rd_data[8:7]);
            fail_count = fail_count + 1;
        end else if (rd_data[6:4] !== 3'd0) begin
            $display("[T%0d slot0_reserved] FAIL got=0x%h exp=0",
                     test_count, rd_data[6:4]);
            fail_count = fail_count + 1;
        end else if (rd_data[3:0] !== 4'b1111) begin
            $display("[T%0d slot0_permits_valid] FAIL got=0x%h exp=0xF",
                     test_count, rd_data[3:0]);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d slot0_field_decomp] PASS class=4 lifetime=1 perm=111 v=1",
                     test_count);
        end

        // ----- T3..T7: Slot 1..5 reset default = 0 -----
        read_and_check(3'd1, 32'h0000_0000, "slot1_reset_zero");
        read_and_check(3'd2, 32'h0000_0000, "slot2_reset_zero");
        read_and_check(3'd3, 32'h0000_0000, "slot3_reset_zero");
        read_and_check(3'd4, 32'h0000_0000, "slot4_reset_zero");
        read_and_check(3'd5, 32'h0000_0000, "slot5_reset_zero");

        // ----- T8: Write slot 1 with Profile 1 (different class/lifetime) -----
        // gila_class=3, gila_lifetime=2, permit_voice=1, permit_data=0,
        // permit_reg=1, valid=1, prio=2, hangtime=10, max_call_dur=30
        write_slot(3'd1,
            pack_profile(8'd30, 8'd10, 4'd2,
                         3'd3, 2'd2,
                         1'b1, 1'b0, 1'b1, 1'b1));
        read_and_check(3'd1,
            pack_profile(8'd30, 8'd10, 4'd2,
                         3'd3, 2'd2,
                         1'b1, 1'b0, 1'b1, 1'b1),
            "slot1_write_readback");

        // ----- T9: Slot 0 still 0x088F after writing slot 1 -----
        read_and_check(3'd0, 32'h0000_088F, "slot0_unchanged_after_slot1_write");

        // ----- T10: Overwrite slot 0 with new policy -----
        write_slot(3'd0,
            pack_profile(8'd255, 8'd255, 4'd15,
                         3'b111, 2'b11,
                         1'b1, 1'b1, 1'b0, 1'b1));
        read_and_check(3'd0,
            pack_profile(8'd255, 8'd255, 4'd15,
                         3'b111, 2'b11,
                         1'b1, 1'b1, 1'b0, 1'b1),
            "slot0_overwrite_max_values");

        // ----- T11: rst_n pulse drives rd_data to spec default 0x088F
        //            during reset (mem itself persists per dist-LUT-RAM rules).
        //            Verify by sampling DURING the reset window.
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        test_count = test_count + 1;
        if (rd_data !== 32'h0000_088F) begin
            $display("[T%0d rd_data_during_reset] FAIL rd_data=0x%08X exp=0x088F",
                     test_count, rd_data);
            fail_count = fail_count + 1;
        end else begin
            $display("[T%0d rd_data_during_reset] PASS rd_data=0x%08X",
                     test_count, rd_data);
        end
        rst_n = 1'b1;
        @(posedge clk);

        // ----- T12..T13: Read all 6 slots round-trip -----
        write_slot(3'd0, 32'h0000_088F);  // restore default for guard
        write_slot(3'd5, 32'hAABB_CCDD);
        read_and_check(3'd5, 32'hAABB_CCDD, "slot5_arbitrary_pattern");

        // Out-of-range index ≥ DEPTH should not write (silent)
        write_slot(3'd6, 32'hDEAD_BEEF);  // wr_idx=6 > DEPTH-1=5; no effect
        read_and_check(3'd5, 32'hAABB_CCDD, "slot5_unchanged_after_oob_write");

        // ----- Summary -----
        $display("=============================================");
        if (fail_count == 0)
            $display("tb_profile_table: PASS (%0d/%0d)", test_count, test_count);
        else
            $display("tb_profile_table: FAIL (%0d/%0d failures)", fail_count, test_count);
        $display("=============================================");
        $finish;
    end

    initial begin
        #500000;
        $display("tb_profile_table: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire
