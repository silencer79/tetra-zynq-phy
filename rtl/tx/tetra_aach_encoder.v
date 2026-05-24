// =============================================================================
// Module: tetra_aach_encoder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_aach_encoder.v
//
// Description:
// AACH Encoder — builds the 14-bit Access Assignment Channel PDU from
// FN (air-side slot role) + static cell config, then applies the
// channel coding chain:
//
// info14 → RM(30,14) encode → 30 bits → Fibonacci-LFSR scramble (init
// derived from MCC+MNC+ColourCode) → 30 type-5 bits
//
// Content per ETSI EN 300 392-2 §21.5.2 (matches sw/tetra_hal.c exactly):
// fn_sys == 5'd17 (FN_ETSI = 18): DL/UL-Assign, info = 14'h040
// Header=00 DL-usage=000 UL-usage=001 Field2(aach_cc)=000000
// fn_sys != 5'd17 (FN_ETSI = 1..17): Capacity Allocation, info = 14'h3000
// Header=11 Field1=000000 Field2=000000
//
// Scrambler init (matches aach_scramble in sw/tetra_hal.c:440):
// lfsr = (mcc & 0x3FF)<<22 | (mnc & 0x3FFF)<<8 | (cc & 0x3F)<<2 | 3
// If lfsr == 0 → lfsr = 0xFFFFFFFF (never happens in practice)
//
// Fibonacci LFSR taps (matches next_lfsr_bit in sw/tetra_hal.c:273):
// ST-form: 32,26,23,22,16,12,11,10,8,7,5,4,2,1
// bit-0=LSB form: 0,6,9,10,16,20,21,22,24,25,27,28,30,31
//
// Encoding takes ~33 cycles (~0.33 µs @ 100 MHz). Triggered once per slot;
// result stored in output register for slot_content_mux (Stufe 4) to latch.
//
// Clock domain: clk_sys (100 MHz)
// Coding rules: Verilog-2001 strict
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tetra_aach_encoder (
 input wire clk_sys,
 input wire rst_n_sys,

 // Variable: FN (0-based, 0..17). FN_ETSI=18 is fn_sys == 5'd17.
 input wire [4:0] fn_sys,
 // Variable: TN (0-based, 0..3). TN=0 is the signalling slot.
 input wire [1:0] tn_sys,
 // Variable: MN%4 (0..3). Used to distinguish F18 TN=0 MN%4=2 (BSCH anchor
 // slot, AACH=Unalloc/Random) from MN%4∈{0,1,3} (NDB2 slots, AACH=Common/Random).
 input wire [1:0] mn_low2_sys,

 // Static config (from AXI registers, already CDC'd to clk_sys)
 input wire [5:0] colour_code_sys,
 input wire [9:0] mcc_sys,
 input wire [13:0] mnc_sys,
 // 1 when the slot being encoded carries an addressed signalling reply.
 // On those slots the reference uses DL/UL-Assign Unalloc/Unalloc.
 // Idle TN0 slots stay DL/UL-Assign Common/Random.
 input wire signalling_active_sys,

 // H.6.3 — UL-Slot-Grant override. When grant_pending_sys=1 and the slot
 // being encoded is TN=0 idle (signalling_active_sys=0), the AACH info is
 // overridden with grant_info_sys[13:0] instead of the default 0x0249.
 // grant_pending_sys is held high by software (REG_AACH_GRANT_HINT[31])
 // until the AACH encoder consumes it (consume pulse 1 cycle on encode_start
 // when override fires). grant_info_sys carries the 14-bit AACH info word
 // to broadcast: header=01 (DL/UL-Assign), DL-usage / UL-usage as needed,
 // Field2 = USSI or subslot index per ETSI EN 300 392-2 §21.5.2.
 input wire grant_pending_sys,
 input wire [13:0] grant_info_sys,
 output reg grant_consume_sys,

 /* Phase Y.4.1 — Voice-Active-Mask (4 bit, bit N = active voice on
 * tn_sys==N). Wenn bit gesetzt UND tn_sys nicht 0 UND nicht F18
 * → AACH = 14'h22C9 (DL+UL allocated to traffic, #6136 Burst-
 * Forensik). Sonst idle-Pattern wie bisher. SW kontrolliert via
 * REG_VOICE_ACTIVE_MASK @ 0x1EC. */
 input wire [3:0] voice_active_mask_sys,

 /* Phase 2/3 (2026-05-23) — Per-TN slot_mode (4×4-bit = 16-bit), höchste
  * Priorität nach FN=18-Override und TN=0-Branches. Wenn slot_mode[tn] != 0,
  * gewinnt die LUT (TCH_VOICE/HALF_STEAL_SIG/FULL_STEAL_SIG/FULL_STEAL_FILLER).
  * Wenn slot_mode[tn] == 0 → Fallback auf bisherigen voice_active_mask-Pfad.
  * SW kontrolliert via REG_SLOT_MODE @ 0x2B4. */
 input wire [15:0] slot_mode_sys,
 /* Phase 3.4 (2026-05-24) — Per-TN Traffic Usage Marker (UMt), ETSI
  * EN 300 392-2 §21.4.7.2. 4×8-bit packed; bits[TN*8 +: 6] = UMt für TN.
  * UMt=0 → kein aktiver Call, AACH-LUT-Pfade nutzen legacy hardcoded
  * Werte; UMt=4..63 → dynamische AACH-Berechnung (Voice: Header=11+UMt+UMt,
  * HALF_STEAL: Header=10+UMt+0x09). SW kontrolliert via REG_SLOT_UMT @ 0x2D4. */
 input wire [31:0] slot_umt_sys,

 // Phase Z.13 (2026-05-04): the Z.2/Z.12 `aach_override_valid_sys` +
 // `aach_override_info_sys` inputs were removed. Queued-PDU AACH
 // patterns now flow through a separate combinational tetra_aach_rm_
 // encoder instance at the top-level slot-encoder side, and the slot
 // mux selects head_aach vs default-encoder output as one if/else.
 // This module is purely the "default-logic" path: F18 anchor / TN=0
 // idle 0x0249 / TN=0 reply 0x0009 / TN!=0 traffic / grant_pending.

 // Trigger — 1-cycle pulse, start new encoding
 input wire encode_start_sys,

 // Output — 30 type-5 coded+scrambled bits. [29]=first transmitted bit.
 output reg [29:0] aach_coded_sys,
 output reg aach_valid_sys
);

// =============================================================================
// RM(30,14) generator matrix rows
// Each RM_ROWi is XORed into the coded word when info[13-i] == 1.
// Values produced by scripts/gen_aach_reference.py:build_rm_rows().
// Top 14 bits [29:16] = systematic identity, low 16 bits = parity from
// RM_30_14_GEN in sw/tetra_hal.c.
// =============================================================================
localparam [29:0] RM_ROW00 = 30'h20009B60; // info[13] (MSB, first bit)
localparam [29:0] RM_ROW01 = 30'h10002DE0; // info[12]
localparam [29:0] RM_ROW02 = 30'h0800FC20; // info[11]
localparam [29:0] RM_ROW03 = 30'h0400E03C; // info[10]
localparam [29:0] RM_ROW04 = 30'h0200983A; // info[9]
localparam [29:0] RM_ROW05 = 30'h01005436; // info[8]
localparam [29:0] RM_ROW06 = 30'h00802C2E; // info[7]
localparam [29:0] RM_ROW07 = 30'h0040FFDF; // info[6]
localparam [29:0] RM_ROW08 = 30'h00208339; // info[5]
localparam [29:0] RM_ROW09 = 30'h001042B5; // info[4]
localparam [29:0] RM_ROW10 = 30'h000821AD; // info[3]
localparam [29:0] RM_ROW11 = 30'h00041273; // info[2]
localparam [29:0] RM_ROW12 = 30'h0002096B; // info[1]
localparam [29:0] RM_ROW13 = 30'h000104E7; // info[0] (LSB)

// Combinatorial RM(30,14) encoder
function [29:0] rm_encode;
 input [13:0] u;
 begin
 rm_encode = ({30{u[13]}} & RM_ROW00) ^
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

// =============================================================================
// FSM
// =============================================================================
localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_MASK = 2'd1; // 30 cycles: step LFSR, build 30-bit scramble mask
localparam [1:0] S_DONE = 2'd2; // 1 cycle: apply mask, latch output

reg [1:0] state_sys;
reg [4:0] mask_cnt_sys; // 0..29
reg [31:0] lfsr_sys;
reg [29:0] mask_sys;
reg [13:0] info_sys;

// Fibonacci LFSR feedback (matches sw/tetra_hal.c:next_lfsr_bit)
wire lfsr_fb_w = lfsr_sys[ 0] ^ lfsr_sys[ 6] ^ lfsr_sys[ 9] ^ lfsr_sys[10] ^
 lfsr_sys[16] ^ lfsr_sys[20] ^ lfsr_sys[21] ^ lfsr_sys[22] ^
 lfsr_sys[24] ^ lfsr_sys[25] ^ lfsr_sys[27] ^ lfsr_sys[28] ^
 lfsr_sys[30] ^ lfsr_sys[31];

wire [31:0] lfsr_init_w = {mcc_sys, mnc_sys, colour_code_sys, 2'b11};

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state_sys <= S_IDLE;
 mask_cnt_sys <= 5'd0;
 lfsr_sys <= 32'd0;
 mask_sys <= 30'd0;
 info_sys <= 14'd0;
 aach_coded_sys <= 30'd0;
 aach_valid_sys <= 1'b0;
 grant_consume_sys <= 1'b0;
 end else begin
 grant_consume_sys <= 1'b0;
 case (state_sys)
 // -----------------------------------------------------------------
 S_IDLE: begin
 if (encode_start_sys) begin
 // Per-slot AACH info — Cell bit-genau verifiziert
 // (Capture reference-DL.wav, 7338 Slot-Decode + AACH-
 // Schedule-Histogramm 2026-05-02):
 //
 // F18 TN=0 MN%4==2 (BSCH-Anker, SB) → 0x0049 Unalloc/Random
 // F18 TN=0 MN%4∈{0,1,3} (NDB2 BNCH) → 0x0249 Common/Random
 // F18 TN!=0 MN%4==1 (SB) → 0x0040 Unalloc/Random
 // F18 TN!=0 MN%4∈{0,2,3} → 0x2249 Reserved f1=9 f2=9
 // F1-17 TN=0 + signalling-active reply → 0x0009 Unalloc/Unalloc
 // F1-17 TN=0 + idle (NDB2 MCCH) → 0x0249 Common/Random
 // F1-17 TN!=0 MN%4==1 + FN(ETSI)=3..13 → 0x2049 Reserved f1=1 f2=9
 // F1-17 TN!=0 MN%4==3 + FN(ETSI)=14..17 → 0x2049 Reserved f1=1 f2=9
 // F1-17 TN!=0 sonst (Traffic-Slot idle) → 0x3000 CapAlloc f1=0 f2=0
 // (bit-genau 2026-05-04
 // Audit; vorher 0x32CB war Drift)
 //
 // FN-Codierung: fn_sys = ETSI FN-1, also fn_sys=2..12 == FN 3..13,
 // fn_sys=13..16 == FN 14..17, fn_sys=17 == FN 18.
 //
 // Branch-Reihenfolge: F18 vor TN=0, sonst fällt der F18-TN=0
 // BSCH-Anker durch. H.6.3 grant-override wirkt nur auf den
 // F1-17 TN=0 idle-Pfad (signalling_active=0, kein F18).
 if (fn_sys == 5'd17) begin
 // F18-Bereich (BSCH timing)
 if (tn_sys == 2'd0 && mn_low2_sys == 2'd2)
 info_sys <= 14'h0049; // F18 TN=0 BSCH-Anker
 else if (tn_sys == 2'd0)
 info_sys <= 14'h0249; // F18 TN=0 NDB2 BNCH
 else if (mn_low2_sys == 2'd1)
 info_sys <= 14'h0040; // F18 TN!=0 MN%4=1 SB
 else
 info_sys <= 14'h2249; // F18 TN!=0 MN%4∈{0,2,3} Reserved
 end else if (tn_sys == 2'd0 && !signalling_active_sys && grant_pending_sys) begin
 info_sys <= grant_info_sys;
 grant_consume_sys <= 1'b1;
 end else if (tn_sys == 2'd0) begin
 info_sys <= signalling_active_sys ? 14'h0009: 14'h0249;
 end else if (slot_mode_sys[tn_sys*4 +: 4] != 4'd0) begin
 /* Phase 3.4 (2026-05-24) — DYNAMISCHE AACH-Berechnung aus slot_mode +
  * UMt (Traffic Usage Marker), ETSI EN 300 392-2 §21.4.7.2 Table 21.82.
  * slot_mode-LUT (gewinnt vor voice_active_mask):
  *   1 = TCH_VOICE         → Header=11 + DL=UMt + UL=UMt
  *   2 = HALF_STEAL_SIG    → Header=10 + DL=UMt + UL=AccessField(code=A,len=8)
  *   3 = FULL_STEAL_SIG    → Header=10 + DL=UMa(1) + UL=AccessField(code=A,len=8)
  *   4 = FULL_STEAL_FILLER → wie 3
  *   default               → 14'h3000 (idle traffic)
  * Access field default 6'h09 = (00=code-A) | (1001=8 subslots base-frame-len). */
 case (slot_mode_sys[tn_sys*4 +: 4])
 4'd1: info_sys <= {2'b11, slot_umt_sys[tn_sys*8 +: 6], slot_umt_sys[tn_sys*8 +: 6]};
 4'd2: info_sys <= {2'b10, slot_umt_sys[tn_sys*8 +: 6], 6'h09};
 4'd3: info_sys <= {2'b10, 6'd1, 6'h09}; /* UMa = Assigned Control */
 4'd4: info_sys <= {2'b10, 6'd1, 6'h09};
 default: info_sys <= 14'h3000;
 endcase
 end else if (voice_active_mask_sys[tn_sys]) begin
 /* Fallback: voice_active_mask-Pfad. Wenn SW UMt im Register stehen hat,
  * berechne AACH dynamisch (Header=11 + UMt + UMt); sonst hardcoded
  * 0x33CF (legacy backward-compat für Setup ohne UMt-Allokation). */
 if (|slot_umt_sys[tn_sys*8 +: 6])
 info_sys <= {2'b11, slot_umt_sys[tn_sys*8 +: 6], slot_umt_sys[tn_sys*8 +: 6]};
 else
 info_sys <= 14'h33CF;
 end else begin
 // F1-17 TN!=0 idle (Traffic-Slots) — rotiert nach FN/MN%4
 if (mn_low2_sys == 2'd1 &&
 fn_sys >= 5'd2 && fn_sys <= 5'd12)
 info_sys <= 14'h2049; // FN=3..13 MN%4=1 Reserved
 else if (mn_low2_sys == 2'd3 &&
 fn_sys >= 5'd13 && fn_sys <= 5'd16)
 info_sys <= 14'h2049; // FN=14..17 MN%4=3 Reserved
 else
 info_sys <= `PDUC_AACH_TRAFFIC_IDLE; // 14'h3000 — CapAlloc f1=0 f2=0 (bit-genau 2026-05-04)
 end
 // Init LFSR; handle degenerate lfsr=0 case (never in practice)
 lfsr_sys <= (lfsr_init_w == 32'h0) ? 32'hFFFFFFFF
: lfsr_init_w;
 mask_sys <= 30'd0;
 mask_cnt_sys <= 5'd0;
 state_sys <= S_MASK;
 end
 end
 // -----------------------------------------------------------------
 S_MASK: begin
 // Step LFSR, shift bit into mask at position (29 - mask_cnt).
 // lfsr <<- bit into MSB, existing content shifts right.
 mask_sys[29 - mask_cnt_sys] <= lfsr_fb_w;
 lfsr_sys <= {lfsr_fb_w, lfsr_sys[31:1]};
 if (mask_cnt_sys == 5'd29) begin
 state_sys <= S_DONE;
 end else begin
 mask_cnt_sys <= mask_cnt_sys + 5'd1;
 end
 end
 // -----------------------------------------------------------------
 S_DONE: begin
 // Note: mask_sys's last write (from S_MASK at mask_cnt==29)
 // lands this cycle too; but since state transitions on the
 // same clock edge, mask_sys is fully populated here.
 // Actually wait — we transition TO S_DONE when mask_cnt==29,
 // but the mask bit for position 0 (29-29) is written ON that
 // same cycle. So by the NEXT clock (which is this S_DONE
 // entry), mask_sys has bits [29:0] fully set.
 aach_coded_sys <= rm_encode(info_sys) ^ mask_sys;
 aach_valid_sys <= 1'b1;
 state_sys <= S_IDLE;
 end
 // -----------------------------------------------------------------
 default: state_sys <= S_IDLE;
 endcase
 end
end

endmodule

`default_nettype wire
