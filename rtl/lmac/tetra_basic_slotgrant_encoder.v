// =============================================================================
// tetra_basic_slotgrant_encoder.v
//
// Combinational packer for the 8-bit "basic slot-granting element" defined in
// ETSI EN 300 392-2 §21.5.6 — used as the `slot_granting_element` payload of a
// MAC-RESOURCE DL PDU when the slot_granting_flag is set.
//
// Layout (bluestation crates/tetra-pdus/src/umac/fields/basic_slotgrant.rs,
// BasicSlotgrant::to_bitbuf):
//
//   bit  [7:4]  capacity_allocation   (BasicSlotgrantCapAlloc, 4-bit enum,
//                                       §21.5.6, e.g. 1 = "grant 1 slot")
//   bit  [3:0]  granting_delay        (BasicSlotgrantGrantingDelay, 4-bit raw)
//
// The MSB of the packed element (bit 7) is emitted first on air when the
// MAC-RESOURCE builder inserts the element into the header, matching
// BitBuffer::write_bits(val, 8) semantics in bluestation.
//
// Intended use: instantiated by upper FSMs (Phase-6 CMCE / call-setup /
// slot-granting paging) and routed to tetra_mac_resource_dl_builder's
// slot_granting_element[7:0] input.  Today's D-LOC-UPDATE-ACCEPT path in
// tetra_mle_registration_fsm.v uses slot_granting_flag=0, so this encoder is
// instantiated as structural placeholder only.
//
// Verilog-2001 strict — pure combinational, no clocked registers.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_basic_slotgrant_encoder (
    // Capacity allocation (§21.5.6 Table 21.88):
    //   0  = FirstSubslotGranted
    //   1  = Grant 1 slot
    //   2  = Grant 2 slots
    //   ...
    //   15 = SecondSubslotGranted
    input  wire [3:0] capacity_allocation,

    // Granting delay (§21.5.6 Table 21.89) — raw 4-bit field, caller
    // maps semantic values to the raw enum encoding.
    input  wire [3:0] granting_delay,

    // Packed 8-bit element, MSB = capacity_allocation[3].  When delivered
    // to tetra_mac_resource_dl_builder the builder emits bit [7] first on
    // air (MSB-first, same convention as all MAC-RESOURCE fields).
    output wire [7:0] packed_element
);

    assign packed_element = { capacity_allocation, granting_delay };

endmodule

`default_nettype wire
