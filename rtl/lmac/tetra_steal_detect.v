// =============================================================================
// Module:  tetra_steal_detect
// Project: tetra-zynq-phy
// File:    rtl/lmac/tetra_steal_detect.v
//
// Description:
//   TETRA Stealing-Bit Detection from AACH (Access Assignment CHannel Header).
//   Detects when a TCH timeslot has been stolen for ACCH signalling by
//   examining the 14-bit decoded AACH from the (30,14) Reed-Muller decoder.
//
//   AACH bit mapping per ETSI EN 300 392-2 §21.4.1 / Table 21.55:
//     aach_data[13:8] = Access code (6 bits, bit 1 = MSB)
//     aach_data[7:0]  = Secondary field (8 bits)
//
//   Access code definitions (Table 21.56):
//     6'b000000 = Unallocated
//     6'b000001 = TCH/A (normal voice/data)
//     6'b001000 = STCH (Stolen TCH for ACCH)
//     6'b001001 = STCH + ACCH (dual steal)
//     6'b100000 = MCCH
//     6'b100001 = BNCH
//     6'b100010 = BCCH
//
//   Steal detection rule: access_code[5:3] == 3'b001 → stolen
//   (covers STCH=001000 and STCH+ACCH=001001)
//
// Clock domain: _sys (100 MHz system clock)
// Reset:        Active-low asynchronous rst_n_sys
//
// Pipeline: Combinatorial decode, registered outputs. Latency = 1 clock.
//
// Resource estimate:  LUT ~20   FF ~28   DSP 0   BRAM 0
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//   R1: one always-block per register
//   R2: _sys clock-domain suffix on all signals
//   R4: async reset, active-low
//   R9: no initial blocks in synthesis code
//
// Ref: ETSI EN 300 392-2 §21.4 (AACH), §9.4.4.3 (Burst structure)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_steal_detect #(
    parameter AACH_K = 14       // Reed-Muller decoded info bits
)(
    input  wire              clk_sys,
    input  wire              rst_n_sys,

    // AACH input — 14-bit decoded output from tetra_reed_muller
    //   aach_data_sys[13:8] = 6-bit access code (Table 21.56)
    //   aach_data_sys[7:0]  = secondary field
    input  wire [AACH_K-1:0] aach_data_sys,
    input  wire              aach_valid_sys,  // 1-cycle pulse per decoded AACH
    input  wire [1:0]        slot_num_sys,    // timeslot 0–3
    input  wire [1:0]        burst_type_sys,  // 0=NDB, 1=SB, 2=NUB

    // Per-slot steal status (updated on each valid NDB AACH pulse)
    //   steal_active_sys[n] = 1 → slot n TCH has been stolen for ACCH
    output reg  [3:0]        steal_active_sys,

    // Per-slot cached access codes (for status register readback via AXI-Lite)
    output reg  [5:0]        access_code0_sys,   // slot 0
    output reg  [5:0]        access_code1_sys,   // slot 1
    output reg  [5:0]        access_code2_sys,   // slot 2
    output reg  [5:0]        access_code3_sys    // slot 3
);

// =============================================================================
// Combinatorial decode
// =============================================================================

// Access code = upper 6 bits of 14-bit AACH (ETSI §21.4.1, bit 1 = MSB)
wire [5:0] access_code_w;
assign access_code_w = aach_data_sys[AACH_K-1 -: 6];   // [13:8]

// Steal indicator: access_code[5:3] == 3'b001 covers STCH and STCH+ACCH
wire is_stolen_w;
assign is_stolen_w = (access_code_w[5:3] == 3'b001);

// Only update on Normal Downlink Bursts (burst_type=0) — SB/NUB have no AACH
wire update_en_w;
assign update_en_w = aach_valid_sys && (burst_type_sys == 2'd0);

// =============================================================================
// Pipeline Stage 0: register steal_active per slot
// R1: one always-block for the steal_active[3:0] register
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        steal_active_sys <= 4'b0000;
    else if (update_en_w) begin
        case (slot_num_sys)
            2'd0: steal_active_sys[0] <= is_stolen_w;
            2'd1: steal_active_sys[1] <= is_stolen_w;
            2'd2: steal_active_sys[2] <= is_stolen_w;
            2'd3: steal_active_sys[3] <= is_stolen_w;
            default: ;
        endcase
    end
end

// =============================================================================
// R1: access_code0_sys — cached access code for slot 0
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        access_code0_sys <= 6'd0;
    else if (update_en_w && slot_num_sys == 2'd0)
        access_code0_sys <= access_code_w;
end

// =============================================================================
// R1: access_code1_sys — cached access code for slot 1
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        access_code1_sys <= 6'd0;
    else if (update_en_w && slot_num_sys == 2'd1)
        access_code1_sys <= access_code_w;
end

// =============================================================================
// R1: access_code2_sys — cached access code for slot 2
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        access_code2_sys <= 6'd0;
    else if (update_en_w && slot_num_sys == 2'd2)
        access_code2_sys <= access_code_w;
end

// =============================================================================
// R1: access_code3_sys — cached access code for slot 3
// =============================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        access_code3_sys <= 6'd0;
    else if (update_en_w && slot_num_sys == 2'd3)
        access_code3_sys <= access_code_w;
end

endmodule
