// =============================================================================
// tetra_pi4dqpsk_mod.v — π/4-DQPSK Modulator
// =============================================================================
// ETSI EN 300 392-2 §9.3 (PI/4-DQPSK Modulation)
//
// Maps Type-5 dibits to IQ symbol constellation points using differential
// phase encoding. Phase increments per dibit (ETSI EN 300 392-2 §5.5.2.3,
// confirmed against SDRSharp.Tetra.dll `SymbolToAngel` reference):
//   dibit=00 (b1=0,b0=0) → ΔΦ = +π/4   (phase_idx increment +1 mod 8)
//   dibit=01 (b1=0,b0=1) → ΔΦ = +3π/4  (phase_idx increment +3 mod 8)
//   dibit=10 (b1=1,b0=0) → ΔΦ = -π/4   (phase_idx increment +7 mod 8)
//   dibit=11 (b1=1,b0=1) → ΔΦ = -3π/4  (phase_idx increment +5 mod 8)
//
// Phase represented as 3-bit index (0..7), where idx × (π/4) = absolute phase.
// Arithmetic is mod-8 naturally via 3-bit overflow — no explicit modulo needed.
//
// IQ constellation (16-bit signed, amplitude 1.0 = 32767):
//   idx=0 (  0°): I=+32767, Q=      0
//   idx=1 ( 45°): I=+23170, Q=+23170
//   idx=2 ( 90°): I=     0, Q=+32767
//   idx=3 (135°): I=-23170, Q=+23170
//   idx=4 (180°): I=-32767, Q=      0
//   idx=5 (225°): I=-23170, Q=-23170
//   idx=6 (270°): I=     0, Q=-32767
//   idx=7 (315°): I=+23170, Q=-23170
//
// Note: IQ values match cos/sin of idx×45° scaled to 16-bit Q1.15:
//   cos(45°) = sin(45°) ≈ 0.70711 × 32767 ≈ 23170
//
// Pipeline: 1 cycle latency (i_out/q_out valid 1 cycle after dibit_valid)
// Resource estimate: ~20 LUT, ~50 FF, 0 DSP, 0 BRAM
//
// Pipeline stages:
//   Stage 0: dibit_in sampled; phase_inc_w and i/q_new_w computed (combinatorial)
//   Stage 1: phase_idx, i_out, q_out registered; sample_valid_out = dibit_valid_d1
//
// Ports:
//   clk_sample    — 100 MHz system clock (symbol strobes at ~18 kHz)
//   rst_n_sample  — active-low async reset
//   dibit_in      — 2-bit Type-5 input (dibit_in[1]=b1, dibit_in[0]=b0)
//   dibit_valid   — 1-cycle strobe: dibit_in valid this cycle
//   i_out         — signed 16-bit I output (valid when sample_valid_out=1)
//   q_out         — signed 16-bit Q output (valid when sample_valid_out=1)
//   sample_valid_out — 1-cycle strobe: IQ output valid this cycle
// =============================================================================

`default_nettype none

module tetra_pi4dqpsk_mod #(
    parameter IQ_WIDTH    = 16,
    parameter PHASE_WIDTH = 16,
    parameter LUT_DEPTH   = 1024   // Kept for compatibility; 8-entry LUT used
)(
    input  wire                          clk_sample,
    input  wire                          rst_n_sample,
    input  wire [1:0]                    dibit_in,
    input  wire                          dibit_valid,
    output reg  signed [IQ_WIDTH-1:0]    i_out,
    output reg  signed [IQ_WIDTH-1:0]    q_out,
    output reg                           sample_valid_out
);

    // -------------------------------------------------------------------------
    // Constants
    // Phase index uses 3-bit unsigned counter (0..7, mod-8 automatically)
    // IQ amplitude values: cos/sin(idx*45°) scaled to 16-bit Q1.15
    // cos(0°)   = 1.0      →  32767
    // cos(45°)  = 0.70711  →  23170
    // cos(90°)  = 0.0      →      0
    // cos(135°) = -0.70711 → -23170
    // cos(180°) = -1.0     → -32767   (note: -32767 avoids -32768 abs-value issue)
    // -------------------------------------------------------------------------
    localparam signed [IQ_WIDTH-1:0] AMP_ONE  =  32767;
    localparam signed [IQ_WIDTH-1:0] AMP_SQ2  =  23170;  // 1/sqrt(2) * 32767
    localparam signed [IQ_WIDTH-1:0] AMP_ZERO =      0;

    // =========================================================================
    // R1: Phase index register — phase_idx_sample [2:0]
    // =========================================================================
    reg [2:0] phase_idx_sample;

    always @(posedge clk_sample or negedge rst_n_sample) begin
        if (!rst_n_sample)
            phase_idx_sample <= 3'd0;
        else if (dibit_valid)
            phase_idx_sample <= phase_idx_sample + phase_inc_w;
    end

    // -------------------------------------------------------------------------
    // R10/R5: Phase increment — combinatorial, based on dibit_in
    // ETSI EN 300 392-2 §5.5.2.3:
    //   dibit=00→+1 (+π/4), 01→+3 (+3π/4), 10→+7 (-π/4), 11→+5 (-3π/4)
    // -------------------------------------------------------------------------
    reg [2:0] phase_inc_w;

    always @(*) begin
        case (dibit_in)
            2'b00:   phase_inc_w = 3'd1;   // +π/4
            2'b01:   phase_inc_w = 3'd3;   // +3π/4
            2'b10:   phase_inc_w = 3'd7;   // -π/4
            2'b11:   phase_inc_w = 3'd5;   // -3π/4
            default: phase_inc_w = 3'd1;
        endcase
    end

    // -------------------------------------------------------------------------
    // Phase after applying increment (used for IQ lookup before registration)
    // 3-bit addition is automatically mod-8
    // -------------------------------------------------------------------------
    wire [2:0] phase_new_w = phase_idx_sample + phase_inc_w;

    // -------------------------------------------------------------------------
    // IQ lookup — combinatorial case statement (8 entries, no array: R3 safe)
    // Lookup is from NEW phase (phase_new_w), so IQ reflects the phase AFTER
    // this dibit has been applied — matches the expectation of the downstream
    // RRC filter that receives IQ samples at the new constellation point.
    // -------------------------------------------------------------------------
    reg signed [IQ_WIDTH-1:0] i_new_w;
    reg signed [IQ_WIDTH-1:0] q_new_w;

    always @(*) begin
        case (phase_new_w)
            3'd0: begin i_new_w =  AMP_ONE;  q_new_w =  AMP_ZERO; end  //   0°
            3'd1: begin i_new_w =  AMP_SQ2;  q_new_w =  AMP_SQ2;  end  //  45°
            3'd2: begin i_new_w =  AMP_ZERO; q_new_w =  AMP_ONE;  end  //  90°
            3'd3: begin i_new_w = -AMP_SQ2;  q_new_w =  AMP_SQ2;  end  // 135°
            3'd4: begin i_new_w = -AMP_ONE;  q_new_w =  AMP_ZERO; end  // 180°
            3'd5: begin i_new_w = -AMP_SQ2;  q_new_w = -AMP_SQ2;  end  // 225°
            3'd6: begin i_new_w =  AMP_ZERO; q_new_w = -AMP_ONE;  end  // 270°
            3'd7: begin i_new_w =  AMP_SQ2;  q_new_w = -AMP_SQ2;  end  // 315°
            default: begin i_new_w = AMP_ONE; q_new_w = AMP_ZERO; end
        endcase
    end

    // =========================================================================
    // R1: i_out — registered I output
    // =========================================================================
    always @(posedge clk_sample or negedge rst_n_sample) begin
        if (!rst_n_sample)
            i_out <= {IQ_WIDTH{1'b0}};
        else if (dibit_valid)
            i_out <= i_new_w;
    end

    // =========================================================================
    // R1: q_out — registered Q output
    // =========================================================================
    always @(posedge clk_sample or negedge rst_n_sample) begin
        if (!rst_n_sample)
            q_out <= {IQ_WIDTH{1'b0}};
        else if (dibit_valid)
            q_out <= q_new_w;
    end

    // =========================================================================
    // R1: sample_valid_out — delayed dibit_valid (1-cycle pipeline)
    // =========================================================================
    always @(posedge clk_sample or negedge rst_n_sample) begin
        if (!rst_n_sample)
            sample_valid_out <= 1'b0;
        else
            sample_valid_out <= dibit_valid;
    end

endmodule
`default_nettype wire
