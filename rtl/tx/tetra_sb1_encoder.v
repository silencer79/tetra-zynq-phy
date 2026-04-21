// =============================================================================
// Module: tetra_sb1_encoder
// Project: tetra-zynq-phy
// File: rtl/tx/tetra_sb1_encoder.v
//
// Description:
//   BSCH SB1 Encoder — builds the SYNC PDU (60 type-1 bits) from static
//   config + FPGA TX counters, then applies the full channel coding chain:
//     PDU (60) → CRC-16 (76) → tail (80) → RCPC rate 2/3 (120)
//     → multiplicative interleave (120) → scramble init=3 (120 type-5)
//
//   Eliminates SW-driven SB1 register writes and the associated register
//   tearing / stale-FN problems.  The FPGA has exact FN/MN from its own
//   TX counters, so the SYNC PDU is always correct.
//
//   Encoding takes 142 clock cycles (~1.4 µs at 100 MHz).  Triggered once
//   per slot; result stored in output register for burst_mux to latch.
//
// SYNC PDU field order (ETSI EN 300 392-2 §21.4.3.1):
//   SystemCode(4), ColourCode(6), TimeSlot(2), Frame(5), MultiFrame(6),
//   SharingMode(2), TSReservedFrames(3), UPlaneDTX(1), Frame18Extension(1),
//   Reserved(1), MCC(10), MNC(14), NeighbourCellBroadcast(2),
//   CellServiceLevel(2), LateEntryInfo(1)
//
// Coding chain (continuous downlink, §8.2.3.1):
//   Rate-1/4 mother code (K=5, G1..G4), punctured to rate 2/3:
//     keep {g1(even), g2(even), g1(odd)} per pair → 80 → 120 bits
//   Multiplicative interleaver: N=120, a=11 (§8.2.4.1)
//   Scrambler: Fibonacci LFSR, init=3 (§8.2.5.2, fixed for BSCH)
//
// Generator polynomials (ETSI §8.2.3.1.1, shift-left / SW convention):
//   G1 = 0x13 = 10011, G2 = 0x1D = 11101
//   G3 = 0x17 = 10111, G4 = 0x1B = 11011
//
// Clock domain: clk_sys (100 MHz)
// Resource estimate: ~200 LUT, ~250 FF, 0 DSP, 0 BRAM
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_sb1_encoder (
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // Static SYNC PDU config (from AXI registers, set once at init)
    input  wire [3:0]  cfg_system_code,
    input  wire [5:0]  cfg_colour_code,
    input  wire [1:0]  cfg_sharing_mode,
    input  wire [2:0]  cfg_ts_reserved_frames,
    input  wire        cfg_u_plane,
    input  wire        cfg_frame_18_ext,
    input  wire [9:0]  cfg_mcc,
    input  wire [13:0] cfg_mnc,
    input  wire [1:0]  cfg_neighbour_cell_broadcast,
    input  wire [1:0]  cfg_cell_service_level,
    input  wire        cfg_late_entry_info,

    // Trigger — 1-cycle pulse, start new encoding
    input  wire        encode_start_sys,

    // Dynamic fields (sampled on encode_start_sys)
    input  wire [1:0]  sdb_slot_sys,       // SDB timeslot (0-based)
    input  wire [4:0]  frame_num_sys,      // 1..18
    input  wire [5:0]  multiframe_num_sys, // 1..60

    // Output — 120 type-5 coded bits, [119] = first transmitted bit
    output reg [119:0] sb1_coded_sys,
    output reg         sb1_valid_sys       // HIGH after first valid encoding
);

// =========================================================================
// Compile-time constant: BSCH scramble mask (Fibonacci LFSR, init=3)
//
// The BSCH scrambler uses a fixed init=3 (§8.2.5.2) because the cell
// identity is INSIDE the BSCH and the receiver can't derive it yet.
// Since init is constant, the 120-bit XOR mask is a compile-time constant.
//
// LFSR: Fibonacci, 32-bit, ETSI §8.2.5 polynomial taps at bits
//   0, 6, 9, 10, 16, 20, 21, 22, 24, 25, 27, 28, 30, 31
// Matches tetra_hal.c next_lfsr_bit() / tetra_aach_encoder.v.
// =========================================================================

function [119:0] compute_scramble_mask;
    input [31:0] init;      // LFSR initial value (3 for BSCH)
    reg [31:0] lfsr;
    reg        fb;
    integer    i;
    begin
        lfsr = init;
        compute_scramble_mask = 120'b0;
        for (i = 0; i < 120; i = i + 1) begin
            fb = lfsr[ 0] ^ lfsr[ 6] ^ lfsr[ 9] ^ lfsr[10] ^
                 lfsr[16] ^ lfsr[20] ^ lfsr[21] ^ lfsr[22] ^
                 lfsr[24] ^ lfsr[25] ^ lfsr[27] ^ lfsr[28] ^
                 lfsr[30] ^ lfsr[31];
            compute_scramble_mask[119 - i] = fb;
            lfsr = {fb, lfsr[31:1]};
        end
    end
endfunction

localparam [119:0] SCRAMBLE_MASK = compute_scramble_mask(32'h00000003);

// =========================================================================
// Compile-time function: BSCH multiplicative interleaver (N=120, a=11)
//
// ETSI EN 300 392-2 §8.2.4.1:
//   out[j-1] = in[k-1], where j = 1 + (a*k) mod N, k=1..N
// Wire permutation — zero combinatorial depth.
// =========================================================================

function [119:0] bsch_interleave;
    input [119:0] din;
    integer       k;
    reg [119:0]   dout;
    begin
        dout = 120'b0;
        for (k = 1; k <= 120; k = k + 1) begin
            // FPGA bit index: [119-n] = array element n (MSB-first)
            dout[120 - (1 + (11 * k) % 120)] = din[120 - k];
        end
        bsch_interleave = dout;
    end
endfunction

// =========================================================================
// FSM states
// =========================================================================
localparam [2:0] S_IDLE   = 3'd0;
localparam [2:0] S_CRC    = 3'd1;  // 60 cycles: CRC-16 over PDU
localparam [2:0] S_BUILD  = 3'd2;  // 1 cycle: construct type-3 word
localparam [2:0] S_RCPC   = 3'd3;  // 80 cycles: conv encode + puncture
localparam [2:0] S_FINISH = 3'd4;  // 1 cycle: interleave + scramble

reg [2:0]   state_sys;
reg [6:0]   cnt_sys;       // 0..79 counter

// Latched PDU (60 bits, MSB-first)
reg [59:0]  pdu_sys;

// CRC-16 shift register
reg [15:0]  crc_sys;

// Type-3 word: PDU(60) + ~CRC(16) + tail(4) = 80 bits
reg [79:0]  type3_sys;

// Convolutional encoder: 4-bit storage, shift-left (SW convention)
// Full 5-bit virtual: {conv_sr[3:0], data_in}
//   conv_sr[3] = oldest stored, conv_sr[0] = newest stored
reg [3:0]   conv_sr_sys;
reg         bit_phase_sys; // 0=even(a), 1=odd(b)

// RCPC output collector (120 type-4 bits)
reg [119:0] rcpc_sys;
reg [6:0]   rcpc_idx_sys;

// =========================================================================
// CRC-16-CCITT combinatorial (used during S_CRC)
// Polynomial: x^16 + x^12 + x^5 + 1 = 0x1021
// Init: 0xFFFF, final: ones-complement (§8.2.6)
// =========================================================================
wire        crc_din_w    = pdu_sys[59 - cnt_sys[5:0]]; // MSB-first
wire        crc_fb_w     = crc_din_w ^ crc_sys[15];
wire [15:0] crc_next_w   = {crc_sys[14:0], 1'b0}
                          ^ ({16{crc_fb_w}} & 16'h1021);

// =========================================================================
// RCPC encoder combinatorial (used during S_RCPC)
//
// Shift-left convention matching tetra_hal.c:
//   conv_sr shifts left: conv_sr <= {conv_sr[2:0], data_in}
//   Full 5-bit: {conv_sr[3:0], data_in}
//   [4]=oldest stored, [0]=newest input
//
// Generator polynomials (ETSI §8.2.3.1.1):
//   G1=10011  G2=11101  G3=10111  G4=11011
// =========================================================================
wire        rcpc_din_w = type3_sys[79 - cnt_sys[6:0]]; // MSB-first
wire [4:0]  conv_full_w = {conv_sr_sys, rcpc_din_w};

wire g1_w = ^(conv_full_w & 5'b10011); // G1 = 0x13
wire g2_w = ^(conv_full_w & 5'b11101); // G2 = 0x1D
// g3, g4 not needed — punctured away for rate 2/3

// =========================================================================
// Main FSM
// =========================================================================
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        state_sys     <= S_IDLE;
        cnt_sys       <= 7'd0;
        pdu_sys       <= 60'd0;
        crc_sys       <= 16'hFFFF;
        type3_sys     <= 80'd0;
        conv_sr_sys   <= 4'd0;
        bit_phase_sys <= 1'b0;
        rcpc_sys      <= 120'd0;
        rcpc_idx_sys  <= 7'd0;
        sb1_coded_sys <= 120'd0;
        sb1_valid_sys <= 1'b0;
    end else begin
        case (state_sys)
        // -----------------------------------------------------------------
        S_IDLE: begin
            if (encode_start_sys) begin
                // Assemble 60-bit SYNC PDU (MSB-first = [59] first)
                pdu_sys <= {cfg_system_code,              // [59:56]  4b
                            cfg_colour_code,              // [55:50]  6b
                            sdb_slot_sys,                 // [49:48]  2b
                            frame_num_sys,                // [47:43]  5b
                            multiframe_num_sys,           // [42:37]  6b
                            cfg_sharing_mode,             // [36:35]  2b
                            cfg_ts_reserved_frames,       // [34:32]  3b
                            cfg_u_plane,                  // [31]     1b
                            cfg_frame_18_ext,             // [30]     1b
                            1'b0,                         // [29]     reserved
                            cfg_mcc,                      // [28:19] 10b
                            cfg_mnc,                      // [18:5]  14b
                            cfg_neighbour_cell_broadcast, // [4:3]    2b
                            cfg_cell_service_level,       // [2:1]    2b
                            cfg_late_entry_info};         // [0]      1b
                crc_sys  <= 16'hFFFF;
                cnt_sys  <= 7'd0;
                state_sys <= S_CRC;
            end
        end

        // -----------------------------------------------------------------
        S_CRC: begin
            crc_sys <= crc_next_w;
            if (cnt_sys == 7'd59) begin
                cnt_sys   <= 7'd0;
                state_sys <= S_BUILD;
            end else begin
                cnt_sys <= cnt_sys + 7'd1;
            end
        end

        // -----------------------------------------------------------------
        S_BUILD: begin
            // Type-3: PDU(60) + ones-complement CRC(16) + 4 tail zeros
            type3_sys    <= {pdu_sys, ~crc_sys, 4'b0000};
            conv_sr_sys  <= 4'd0;
            bit_phase_sys <= 1'b0;
            rcpc_sys     <= 120'd0;
            rcpc_idx_sys <= 7'd0;
            state_sys    <= S_RCPC;
        end

        // -----------------------------------------------------------------
        S_RCPC: begin
            // Update shift register (shift left)
            conv_sr_sys <= {conv_sr_sys[2:0], rcpc_din_w};

            // Rate 2/3 puncturing: per pair (even=a, odd=b)
            //   even: keep g1(a), g2(a) → 2 bits
            //   odd:  keep g1(b)        → 1 bit
            if (bit_phase_sys == 1'b0) begin
                rcpc_sys[119 - rcpc_idx_sys]       <= g1_w;
                rcpc_sys[119 - rcpc_idx_sys - 7'd1] <= g2_w;
                rcpc_idx_sys <= rcpc_idx_sys + 7'd2;
            end else begin
                rcpc_sys[119 - rcpc_idx_sys] <= g1_w;
                rcpc_idx_sys <= rcpc_idx_sys + 7'd1;
            end
            bit_phase_sys <= ~bit_phase_sys;

            if (cnt_sys == 7'd79) begin
                state_sys <= S_FINISH;
            end else begin
                cnt_sys <= cnt_sys + 7'd1;
            end
        end

        // -----------------------------------------------------------------
        S_FINISH: begin
            // Apply interleaver permutation + scrambler (all combinatorial)
            sb1_coded_sys <= bsch_interleave(rcpc_sys) ^ SCRAMBLE_MASK;
            sb1_valid_sys <= 1'b1;
            state_sys     <= S_IDLE;
        end

        default: state_sys <= S_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
