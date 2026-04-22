// =============================================================================
// tetra_sch_f_encoder.v
//
// SCH/F channel encoder (EN 300 392-2 §8.2.3.1.2 / §8.2.4 / §8.2.5).
// 268 type-1 info bits → 432 type-5 coded bits, ready for dibit-mapping and
// slot multiplexing into any SCH/F-bearing downlink slot (NDB BKN1+BKN2
// MAC-RESOURCE signalling, MCCH ACCESS-DEFINE, BNCH SCH/F SYSINFO, …).
//
// Coding chain (mirrors tetra_sch_hd_encoder.v, resized for K=432, a=103):
//   PDU(268) → CRC-16-CCITT (+tail 4) → type-3 (288)
//   → rate-1/4 mother (K=5 G1..G4) punctured to rate 2/3 → 432 type-4 bits
//   → multiplicative interleave (N=432, a=103) → cell-scramble → 432 type-5
//
// Generator polys (ETSI §8.2.3.1.1, shift-left / SW convention):
//   G1=0x13 (10011), G2=0x1D (11101), G3=0x17, G4=0x1B   ; only G1/G2
//   survive the rate-2/3 puncturing pattern (even: a=g1,g2 ; odd: b=g1).
//   Cross-checked against sw/tetra_hal.c::tetra_etsi_puncture_r23() — the
//   SW keeps mother[i+0]=g1(a), mother[i+1]=g2(a), mother[i+4]=g1(b) which
//   is the same bit-ordering this FSM produces bit-serially.
//
// Scrambler: Fibonacci LFSR, same taps as BSCH/AACH/SCH-HD (bits 0,6,9,10,
// 16,20,21,22,24,25,27,28,30,31), seeded at runtime from `scramble_init`.
// For SCH/F use the cell-specific 32-bit pack (MCC<<22 | MNC<<8 | CC<<2 | 3).
//
// Interleaver: ETSI §8.2.4.1 multiplicative, out[j-1]=in[k-1],
//   j = 1 + (a·k) mod N with a=103, N=432 (§Table 8.13).
//
// Bit order: `coded_bits[431]` is the first bit transmitted on air.
// Latency: 1 (IDLE) + 268 (CRC) + 1 (BUILD) + 288 (RCPC) + 432 (SCRAM) + 1
//          (FINISH) ≈ 991 clk_sys cycles — still well under one TDMA slot.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_sch_f_encoder (
    input  wire         clk,
    input  wire         rst_n,

    // 1-cycle pulse: sample info_bits+scramble_init and start a fresh encode
    input  wire         encode_start,

    // 268-bit type-1 PDU, [267] = first bit on air (matches encoder outputs
    // in this codebase — see tetra_mac_resource_dl_builder.v)
    input  wire [267:0] info_bits,

    // Cell-specific Fibonacci LFSR seed (32 bit, §8.2.5.2)
    input  wire [31:0]  scramble_init,

    // 432 type-5 coded bits, [431] = first bit on air
    output reg  [431:0] coded_bits,
    // 1-cycle pulse on the S_FINISH→S_IDLE edge (back-to-back encodes see
    // independent pulses).  Caller must sample coded_valid on the cycle it
    // is HIGH — the pulse is unconditionally cleared in S_IDLE, so a sticky
    // handshake is NOT available by design (same as SCH/HD encoder).
    output reg          coded_valid
);

    // -------------------------------------------------------------------------
    // Compile-time multiplicative interleaver (N=432, a=103)
    // -------------------------------------------------------------------------
    function [431:0] sch_f_interleave;
        input [431:0] din;
        integer       k;
        reg [431:0]   dout;
        begin
            dout = 432'b0;
            for (k = 1; k <= 432; k = k + 1) begin
                // FPGA bit index: [N-1-n] = ETSI array element n
                dout[432 - (1 + (103 * k) % 432)] = din[432 - k];
            end
            sch_f_interleave = dout;
        end
    endfunction

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_CRC    = 3'd1;  // 268 cycles
    localparam [2:0] S_BUILD  = 3'd2;  //   1 cycle
    localparam [2:0] S_RCPC   = 3'd3;  // 288 cycles (info + CRC + tail)
    localparam [2:0] S_SCRAM  = 3'd4;  // 432 cycles (roll LFSR to build mask)
    localparam [2:0] S_FINISH = 3'd5;  //   1 cycle

    reg [2:0]   state;
    reg [8:0]   cnt;          // covers 0..431

    reg [267:0] pdu;
    reg [15:0]  crc;
    reg [287:0] type3;        // 268 + 16 + 4 tail = 288

    reg [3:0]   conv_sr;
    reg         bit_phase;    // 0=even(a), 1=odd(b)
    reg [431:0] rcpc;
    reg [8:0]   rcpc_idx;

    reg [31:0]  lfsr;
    reg [431:0] mask;

    // ----- CRC-16-CCITT (poly 0x1021, init 0xFFFF, final ones-complement) ----
    wire        crc_din_w  = pdu[267 - cnt];
    wire        crc_fb_w   = crc_din_w ^ crc[15];
    wire [15:0] crc_next_w = {crc[14:0], 1'b0} ^ ({16{crc_fb_w}} & 16'h1021);

    // ----- RCPC rate-1/4 mother, rate-2/3 punctured (G1, G2 survive) --------
    wire        rcpc_din_w  = type3[287 - cnt];
    wire [4:0]  conv_full_w = {conv_sr, rcpc_din_w};
    wire        g1_w        = ^(conv_full_w & 5'b10011);  // G1=0x13
    wire        g2_w        = ^(conv_full_w & 5'b11101);  // G2=0x1D

    // ----- Scrambler LFSR (same taps as BSCH/AACH/SCH-HD) -------------------
    wire        lfsr_fb_w = lfsr[ 0] ^ lfsr[ 6] ^ lfsr[ 9] ^ lfsr[10] ^
                            lfsr[16] ^ lfsr[20] ^ lfsr[21] ^ lfsr[22] ^
                            lfsr[24] ^ lfsr[25] ^ lfsr[27] ^ lfsr[28] ^
                            lfsr[30] ^ lfsr[31];

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            cnt         <= 9'd0;
            pdu         <= 268'd0;
            crc         <= 16'hFFFF;
            type3       <= 288'd0;
            conv_sr     <= 4'd0;
            bit_phase   <= 1'b0;
            rcpc        <= 432'd0;
            rcpc_idx    <= 9'd0;
            lfsr        <= 32'd0;
            mask        <= 432'd0;
            coded_bits  <= 432'd0;
            coded_valid <= 1'b0;
        end else begin
            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                // Drop coded_valid every cycle we're idle — the S_FINISH→S_IDLE
                // pulse is therefore exactly 1 cycle wide.  Caller must sample
                // coded_valid on the cycle it is HIGH (see port comment).
                coded_valid <= 1'b0;
                if (encode_start) begin
                    pdu         <= info_bits;
                    crc         <= 16'hFFFF;
                    cnt         <= 9'd0;
                    lfsr        <= scramble_init;
                    mask        <= 432'd0;
                    state       <= S_CRC;
                end
            end

            // -----------------------------------------------------------------
            S_CRC: begin
                crc <= crc_next_w;
                if (cnt == 9'd267) begin
                    cnt   <= 9'd0;
                    state <= S_BUILD;
                end else begin
                    cnt <= cnt + 9'd1;
                end
            end

            // -----------------------------------------------------------------
            S_BUILD: begin
                // Type-3: info(268) + ~CRC(16) + 4 tail zeros
                type3     <= {pdu, ~crc, 4'b0000};
                conv_sr   <= 4'd0;
                bit_phase <= 1'b0;
                rcpc      <= 432'd0;
                rcpc_idx  <= 9'd0;
                state     <= S_RCPC;
            end

            // -----------------------------------------------------------------
            S_RCPC: begin
                conv_sr <= {conv_sr[2:0], rcpc_din_w};

                // Rate 2/3 puncturing: even = g1+g2, odd = g1 only
                if (bit_phase == 1'b0) begin
                    rcpc[431 - rcpc_idx]        <= g1_w;
                    rcpc[431 - rcpc_idx - 9'd1] <= g2_w;
                    rcpc_idx                    <= rcpc_idx + 9'd2;
                end else begin
                    rcpc[431 - rcpc_idx] <= g1_w;
                    rcpc_idx             <= rcpc_idx + 9'd1;
                end
                bit_phase <= ~bit_phase;

                if (cnt == 9'd287) begin
                    cnt   <= 9'd0;
                    state <= S_SCRAM;
                end else begin
                    cnt <= cnt + 9'd1;
                end
            end

            // -----------------------------------------------------------------
            S_SCRAM: begin
                mask[431 - cnt] <= lfsr_fb_w;
                lfsr            <= {lfsr_fb_w, lfsr[31:1]};
                if (cnt == 9'd431) begin
                    state <= S_FINISH;
                end else begin
                    cnt <= cnt + 9'd1;
                end
            end

            // -----------------------------------------------------------------
            S_FINISH: begin
                coded_bits  <= sch_f_interleave(rcpc) ^ mask;
                coded_valid <= 1'b1;
                state       <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
