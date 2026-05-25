// =============================================================================
// tb_basic_slotgrant_encoder.v
//
// Exercises the combinational packing of tetra_basic_slotgrant_encoder.v
// against bluestation reference values from
// crates/tetra-pdus/src/umac/fields/basic_slotgrant.rs::to_bitbuf.
//
// {cap[3:0], delay[3:0]} packed MSB-first.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_basic_slotgrant_encoder;

 reg [3:0] cap = 4'd0;
 reg [3:0] delay = 4'd0;
 wire [7:0] packed_element;

 tetra_basic_slotgrant_encoder dut (
.capacity_allocation (cap),
.granting_delay (delay),
.packed_element (packed_element)
 );

 integer fail_count = 0;
 integer test_count = 0;

 task automatic check(input [3:0] cap_in,
 input [3:0] dly_in,
 input [7:0] expected,
 input [127:0] tag);
 begin
 test_count = test_count + 1;
 cap = cap_in;
 delay = dly_in;
 #1;
 if (packed_element !== expected) begin
 $display("[T%0d %0s] FAIL got=%02h exp=%02h",
 test_count, tag, packed_element, expected);
 fail_count = fail_count + 1;
 end else begin
 $display("[T%0d %0s] PASS cap=%0d delay=%0d -> 0x%02h",
 test_count, tag, cap_in, dly_in, packed_element);
 end
 end
 endtask

 initial begin
 // T1 — grant 1 slot, delay 0 → 0b0001_0000 = 0x10
 check(4'd1, 4'd0, 8'h10, "grant1_delay0");
 // T2 — grant 2 slots, delay 2 → 0b0010_0010 = 0x22
 check(4'd2, 4'd2, 8'h22, "grant2_delay2");
 // T3 — FirstSubslotGranted (0), delay 0 → 0x00
 check(4'd0, 4'd0, 8'h00, "firstsubslot");
 // T4 — SecondSubslotGranted (15), delay 15 → 0xFF
 check(4'd15, 4'd15, 8'hFF, "secondsubslot_max_delay");
 // T5 — mid-range: cap=5, delay=3 → 0x53
 check(4'd5, 4'd3, 8'h53, "cap5_delay3");

 $display("=============================================");
 if (fail_count == 0)
 $display("tb_basic_slotgrant_encoder: PASS (%0d/%0d)",
 test_count, test_count);
 else
 $display("tb_basic_slotgrant_encoder: FAIL (%0d/%0d failures)",
 fail_count, test_count);
 $display("=============================================");
 $finish;
 end

endmodule

`default_nettype wire
