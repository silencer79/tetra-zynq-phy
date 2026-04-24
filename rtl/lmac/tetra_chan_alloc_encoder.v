// =============================================================================
// tetra_chan_alloc_encoder.v
//
// Combinational packer for the "channel allocation element" defined in
// ETSI EN 300 392-2 §21.5.2 — used as the chan_alloc_element payload of a
// MAC-RESOURCE DL PDU when the chan_alloc_flag is set.
//
// Bluestation reference: crates/tetra-pdus/src/umac/fields/channel_allocation.rs
// (ChanAllocElement::to_bitbuf + compute_len).  This encoder covers the
// non-extended subset that bluestation also implements (ext_carrier_num_flag
// is hard-wired 0 here because the extended fields are `unimplemented!()` in
// bluestation too).
//
// Layout, MSB-first:
//   alloc_type          2 bits   §21.5.2.2 Table 21.55
//   ts_assigned         4 bits   bitmap, bit [3] = TS1, bit [0] = TS4
//   ul_dl_assigned      2 bits   0=Augmented, 1=DL, 2=UL, 3=Both (bluestation
//                                UlDlAssignment enum, augmented unsupported)
//   clch_permission     1 bit
//   cell_change_flag    1 bit
//   carrier_num         12 bits  ETSI carrier index (0..4095)
//   ext_carrier_flag    1 bit    forced 0 (extended carrier unsupported)
//   mon_pattern         2 bits   (§21.5.2.2 Table 21.63)
//   frame18_mon_pattern 2 bits   OPTIONAL — only when mon_pattern == 0
//
// Packed widths:
//   25 bits when mon_pattern != 0
//   27 bits when mon_pattern == 0 (frame18 pattern present)
//
// The packed element is right-aligned in a 32-bit bus (bit [element_len-1]
// is the first bit on air, bit [0] is the last).  tetra_mac_resource_dl_builder
// shifts the element to the correct position in the header based on
// chan_alloc_element_len.
//
// Today's D-LOC-UPDATE-ACCEPT path sets chan_alloc_flag=0, so this encoder is
// instantiated structurally in tetra_mle_registration_fsm.v but its output is
// ignored by the builder.  Phase-6 call-setup / handover / cell-change
// callsites will drive real values.
//
// Verilog-2001 strict — pure combinational.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_chan_alloc_encoder (
    input  wire [1:0]  alloc_type,
    input  wire [3:0]  ts_assigned,
    input  wire [1:0]  ul_dl_assigned,
    input  wire        clch_permission,
    input  wire        cell_change_flag,
    input  wire [11:0] carrier_num,
    input  wire [1:0]  mon_pattern,
    input  wire [1:0]  frame18_mon_pattern,  // only emitted when mon_pattern == 0

    output wire [31:0] packed_element,        // right-aligned, upper bits 0
    output wire [4:0]  element_len            // 25 or 27
);

    // Fixed-layout prefix: 2+4+2+1+1+12+1+2 = 25 bits (ext_carrier_flag forced 0).
    wire [24:0] prefix25 = {
        alloc_type,        // [24:23]
        ts_assigned,       // [22:19]
        ul_dl_assigned,    // [18:17]
        clch_permission,   // [16]
        cell_change_flag,  // [15]
        carrier_num,       // [14: 3]
        1'b0,              // [2]  ext_carrier_num_flag (unsupported)
        mon_pattern        // [1:0]
    };

    // Optional frame18 pattern appended when mon_pattern == 0.  When absent,
    // the element is 25 bits wide and lives in packed[24:0]; when present,
    // the frame18 bits occupy [1:0] and prefix25 shifts up by 2.
    wire [26:0] prefix27 = { prefix25, frame18_mon_pattern };

    assign element_len    = (mon_pattern == 2'd0) ? 5'd27 : 5'd25;
    assign packed_element = (mon_pattern == 2'd0)
                            ? { 5'd0, prefix27 }
                            : { 7'd0, prefix25 };

endmodule

`default_nettype wire
