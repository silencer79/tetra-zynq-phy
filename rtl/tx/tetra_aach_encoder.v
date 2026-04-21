// =============================================================================
// Module: tetra_aach_encoder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_aach_encoder.v
//
// Description:
//   AACH Encoder — builds the 14-bit Access Assignment Channel PDU from
//   FN (air-side slot role) + static cell config, then applies the
//   channel coding chain:
//
//     info14 → RM(30,14) encode → 30 bits → Fibonacci-LFSR scramble (init
//     derived from MCC+MNC+ColourCode) → 30 type-5 bits
//
//   Content per ETSI EN 300 392-2 §21.5.2 (matches sw/tetra_hal.c exactly):
//     fn_sys == 5'd17  (FN_ETSI = 18): DL/UL-Assign, info = 14'h040
//         Header=00  DL-usage=000  UL-usage=001  Field2(aach_cc)=000000
//     fn_sys != 5'd17  (FN_ETSI = 1..17): Capacity Allocation, info = 14'h3000
//         Header=11  Field1=000000  Field2=000000
//
//   Scrambler init (matches aach_scramble in sw/tetra_hal.c:440):
//     lfsr = (mcc & 0x3FF)<<22 | (mnc & 0x3FFF)<<8 | (cc & 0x3F)<<2 | 3
//     If lfsr == 0  →  lfsr = 0xFFFFFFFF  (never happens in practice)
//
//   Fibonacci LFSR taps (matches next_lfsr_bit in sw/tetra_hal.c:273):
//     ST-form: 32,26,23,22,16,12,11,10,8,7,5,4,2,1
//     bit-0=LSB form: 0,6,9,10,16,20,21,22,24,25,27,28,30,31
//
//   Encoding takes ~33 cycles (~0.33 µs @ 100 MHz). Triggered once per slot;
//   result stored in output register for slot_content_mux (Stufe 4) to latch.
//
// Clock domain: clk_sys (100 MHz)
// Coding rules: Verilog-2001 strict
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_aach_encoder (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Variable: FN (0-based, 0..17). FN_ETSI=18 is fn_sys == 5'd17.
    input  wire [4:0]  fn_sys,
    // Variable: TN (0-based, 0..3).  TN=0 is the NDB2 NULL-PDU slot in
    // the Gold-mimic schedule; it needs AACH=DL/UL-Assign so MS sees
    // "MCCH active, random access permitted" and can register.
    input  wire [1:0]  tn_sys,

    // Static config (from AXI registers, already CDC'd to clk_sys)
    input  wire [5:0]  colour_code_sys,
    input  wire [9:0]  mcc_sys,
    input  wire [13:0] mnc_sys,

    // Trigger — 1-cycle pulse, start new encoding
    input  wire        encode_start_sys,

    // Output — 30 type-5 coded+scrambled bits. [29]=first transmitted bit.
    output reg  [29:0] aach_coded_sys,
    output reg         aach_valid_sys
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
localparam [1:0] S_MASK = 2'd1;  // 30 cycles: step LFSR, build 30-bit scramble mask
localparam [1:0] S_DONE = 2'd2;  // 1 cycle: apply mask, latch output

reg [1:0]   state_sys;
reg [4:0]   mask_cnt_sys;       // 0..29
reg [31:0]  lfsr_sys;
reg [29:0]  mask_sys;
reg [13:0]  info_sys;

// Fibonacci LFSR feedback (matches sw/tetra_hal.c:next_lfsr_bit)
wire lfsr_fb_w = lfsr_sys[ 0] ^ lfsr_sys[ 6] ^ lfsr_sys[ 9] ^ lfsr_sys[10] ^
                 lfsr_sys[16] ^ lfsr_sys[20] ^ lfsr_sys[21] ^ lfsr_sys[22] ^
                 lfsr_sys[24] ^ lfsr_sys[25] ^ lfsr_sys[27] ^ lfsr_sys[28] ^
                 lfsr_sys[30] ^ lfsr_sys[31];

wire [31:0] lfsr_init_w = {mcc_sys, mnc_sys, colour_code_sys, 2'b11};

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        state_sys      <= S_IDLE;
        mask_cnt_sys   <= 5'd0;
        lfsr_sys       <= 32'd0;
        mask_sys       <= 30'd0;
        info_sys       <= 14'd0;
        aach_coded_sys <= 30'd0;
        aach_valid_sys <= 1'b0;
    end else begin
        case (state_sys)
        // -----------------------------------------------------------------
        S_IDLE: begin
            if (encode_start_sys) begin
                // Per-slot AACH info (Gold-mimic, EN 300 392-2 §21.5.2):
                //   TN=0  → DL/UL-Assign DL=Common(1) UL=Random(1) CC=9
                //           (info=0x0249) — NDB2/MCCH slot, MS random access
                //   FN=18 → DL/UL-Assign DL=Unalloc(0) UL=Random(1) CC=0
                //           (info=0x040)  — hyperframe sync frame
                //   else  → CapAlloc f1=0 f2=0 (info=0x3000) — SB slots
                if (tn_sys == 2'd0)
                    info_sys <= 14'h0249;
                else if (fn_sys == 5'd17)
                    info_sys <= 14'h040;
                else
                    info_sys <= 14'h3000;
                // Init LFSR; handle degenerate lfsr=0 case (never in practice)
                lfsr_sys     <= (lfsr_init_w == 32'h0) ? 32'hFFFFFFFF
                                                       : lfsr_init_w;
                mask_sys     <= 30'd0;
                mask_cnt_sys <= 5'd0;
                state_sys    <= S_MASK;
            end
        end
        // -----------------------------------------------------------------
        S_MASK: begin
            // Step LFSR, shift bit into mask at position (29 - mask_cnt).
            // lfsr <<- bit into MSB, existing content shifts right.
            mask_sys[29 - mask_cnt_sys] <= lfsr_fb_w;
            lfsr_sys                    <= {lfsr_fb_w, lfsr_sys[31:1]};
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
            state_sys      <= S_IDLE;
        end
        // -----------------------------------------------------------------
        default: state_sys <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
