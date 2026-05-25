// =============================================================================
// tetra_aach_rm_encoder.v — Phase Z.12
//
// Standalone AACH RM(30,14) + Fibonacci-LFSR scrambler — combinational
// encoder block extracted from tetra_aach_encoder.v. Takes a 14-bit info
// word and the cell scrambler init pack (MCC,MNC,CC,2'b11) and produces the
// 30-bit type-5 coded+scrambled AACH word in a single cycle (registered
// output) — fully unrolled XOR-tree, no internal FSM.
//
// Use case: the DL-Signal-Queue producers (MLE-FSM, Pre-Reply-SlotGrant,
// Pre-Reply-BlAck, NWRK-Bcast, Group-Ack) compute the AACH coded word
// LOCALLY at push time and store it inside the queue entry alongside the
// 432-bit body. The scheduler latches both atomically in the same bundle
// → the slot AACH output and the slot body output come from the SAME queue
// entry, eliminating the Z.11 single-cycle race between scheduler-latch
// and AACH-encoder-FSM.
//
// LFSR-mask combinational expansion:
// The Fibonacci LFSR feedback `lfsr[0]^lfsr[6]^lfsr[9]^lfsr[10]^lfsr[16]
// ^lfsr[20..22]^lfsr[24..25]^lfsr[27..28]^lfsr[30..31]` is a linear
// function of the 32 LFSR-init bits, so iterating it 30 times yields
// 30 linear functions of the init bits. We compute them by software-
// simulating the LFSR over 30 steps using `for` loops in a Verilog
// `function` (which synthesises to a flat XOR network — no sequential
// logic).
//
// Ports:
// info_w[13:0] AACH info word (header+field1+field2)
// lfsr_init_w[31:0] raw {MCC, MNC, CC, 2'b11} pack (caller handles
// the lfsr_init==0 → 0xFFFFFFFF degeneracy)
// coded_w[29:0] 30 type-5 coded+scrambled bits, [29]=first on-air
//
// Coding rules: Verilog-2001 strict. Pure combinational module — no
// always blocks, no clock, no reset.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_aach_rm_encoder (
 input wire [13:0] info_w,
 input wire [31:0] lfsr_init_w,
 output wire [29:0] coded_w
);

 // -------------------------------------------------------------------------
 // RM(30,14) generator rows — IDENTICAL to tetra_aach_encoder.v / sw/
 // tetra_hal.c RM_30_14_GEN. Each row XORs into the codeword when
 // info[13-i] = 1.
 // -------------------------------------------------------------------------
 localparam [29:0] RM_ROW00 = 30'h20009B60; // info[13]
 localparam [29:0] RM_ROW01 = 30'h10002DE0; // info[12]
 localparam [29:0] RM_ROW02 = 30'h0800FC20; // info[11]
 localparam [29:0] RM_ROW03 = 30'h0400E03C; // info[10]
 localparam [29:0] RM_ROW04 = 30'h0200983A; // info[ 9]
 localparam [29:0] RM_ROW05 = 30'h01005436; // info[ 8]
 localparam [29:0] RM_ROW06 = 30'h00802C2E; // info[ 7]
 localparam [29:0] RM_ROW07 = 30'h0040FFDF; // info[ 6]
 localparam [29:0] RM_ROW08 = 30'h00208339; // info[ 5]
 localparam [29:0] RM_ROW09 = 30'h001042B5; // info[ 4]
 localparam [29:0] RM_ROW10 = 30'h000821AD; // info[ 3]
 localparam [29:0] RM_ROW11 = 30'h00041273; // info[ 2]
 localparam [29:0] RM_ROW12 = 30'h0002096B; // info[ 1]
 localparam [29:0] RM_ROW13 = 30'h000104E7; // info[ 0]

 function [29:0] rm_encode_f;
 input [13:0] u;
 begin
 rm_encode_f = ({30{u[13]}} & RM_ROW00) ^
 ({30{u[12]}} & RM_ROW01) ^
 ({30{u[11]}} & RM_ROW02) ^
 ({30{u[10]}} & RM_ROW03) ^
 ({30{u[ 9]}} & RM_ROW04) ^
 ({30{u[ 8]}} & RM_ROW05) ^
 ({30{u[ 7]}} & RM_ROW06) ^
 ({30{u[ 6]}} & RM_ROW07) ^
 ({30{u[ 5]}} & RM_ROW08) ^
 ({30{u[ 4]}} & RM_ROW09) ^
 ({30{u[ 3]}} & RM_ROW10) ^
 ({30{u[ 2]}} & RM_ROW11) ^
 ({30{u[ 1]}} & RM_ROW12) ^
 ({30{u[ 0]}} & RM_ROW13);
 end
 endfunction

 // -------------------------------------------------------------------------
 // build_lfsr_mask_f — compute the 30-bit scramble mask combinationally
 // by software-simulating 30 Fibonacci-LFSR steps from lfsr_init.
 //
 // The function body uses a `for`-loop over local `reg` variables; a
 // synthesizer unrolls this into a flat XOR network (since the loop
 // bound is a constant). No actual storage — the `reg` variables are
 // function-local "wires" in Verilog-2001 functions.
 //
 // Mask convention matches tetra_aach_encoder.v S_MASK:
 // step k (0..29) writes mask[29 - k] = next feedback bit
 // -------------------------------------------------------------------------
 function [29:0] build_lfsr_mask_f;
 input [31:0] lfsr_in;
 reg [31:0] lfsr;
 reg [29:0] m;
 reg fb;
 integer k;
 begin
 // Handle lfsr==0 degeneracy (matches tetra_aach_encoder.v +
 // sw/tetra_hal.c). In real cells the init pack is never 0
 // because of the trailing 2'b11, but defensive.
 lfsr = (lfsr_in == 32'h0) ? 32'hFFFFFFFF: lfsr_in;
 m = 30'd0;
 for (k = 0; k < 30; k = k + 1) begin
 fb = lfsr[ 0] ^ lfsr[ 6] ^ lfsr[ 9] ^ lfsr[10] ^
 lfsr[16] ^ lfsr[20] ^ lfsr[21] ^ lfsr[22] ^
 lfsr[24] ^ lfsr[25] ^ lfsr[27] ^ lfsr[28] ^
 lfsr[30] ^ lfsr[31];
 m[29 - k] = fb;
 lfsr = {fb, lfsr[31:1]};
 end
 build_lfsr_mask_f = m;
 end
 endfunction

 // Combinational output
 assign coded_w = rm_encode_f(info_w) ^ build_lfsr_mask_f(lfsr_init_w);

endmodule

`default_nettype wire
