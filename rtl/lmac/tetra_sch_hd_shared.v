// =============================================================================
// tetra_sch_hd_shared.v
//
// 2026-05-17 — Util-Refactor: shared SCH/HD encoder + 2-channel arbiter.
//
// Vor diesem Refactor hatten `tetra_pre_reply_slotgrant.v` und
// `tetra_pre_reply_blck.v` je eine eigene tetra_sch_hd_encoder-Instanz
// (Vivado-Util-Audit 2026-05-17: 1297 + 1089 = ~2400 LUT total). Die
// beiden Trigger sind temporal getrennt (Frag-1 vs Frag-2-reassembled,
// ≥ 14 ms apart) und SCH/HD-Encode braucht ~486 cycles ≈ 5 µs bei
// 100 MHz, deshalb kann ein Encoder beide Reply-Pfade serialisieren.
//
// Architektur:
//   - 1× tetra_sch_hd_encoder-Instanz intern.
//   - 2× Request-Channel mit Round-Robin/Priority-Arbiter:
//       ch0 = SlotGrant (Priorität)
//       ch1 = BL-ACK
//   - Pro Channel: Request + Info + Scramble-Init Eingang;
//     Done-Puls + Coded-Output zurück.
//   - Arbiter ist FSM mit States IDLE/CH0_ACTIVE/CH1_ACTIVE.
//
// Erwartete Wirkung: ~600 LUT save (1× statt 2× sch_hd-Interleave-Funktion,
// Scrambler-LFSR, RCPC-Encoder); ~110 LUT Overhead Arbiter; Netto ~500
// LUT (= ~4 % Slice-Reduktion bei aktuellem 98 % Slice-Util).
//
// Coding rules: Verilog-2001 strict, R1/R4/R10.
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tetra_sch_hd_shared (
 input wire clk_sys,
 input wire rst_n_sys,

 // Channel 0 — SlotGrant (Priorität)
 input wire ch0_req,
 input wire [123:0] ch0_info_bits,
 input wire [31:0] ch0_scramble_init,
 output reg ch0_done,
 output reg [215:0] ch0_coded,

 // Channel 1 — BL-ACK
 input wire ch1_req,
 input wire [123:0] ch1_info_bits,
 input wire [31:0] ch1_scramble_init,
 output reg ch1_done,
 output reg [215:0] ch1_coded
);

 // -------------------------------------------------------------------------
 // Interne Encoder-Instanz
 // -------------------------------------------------------------------------
 reg enc_start;
 reg [123:0] enc_info_bits;
 reg [31:0] enc_scramble_init;
 wire [215:0] enc_coded;
 wire enc_coded_valid;

 tetra_sch_hd_encoder u_enc (
.clk (clk_sys),
.rst_n (rst_n_sys),
.encode_start (enc_start),
.info_bits (enc_info_bits),
.scramble_init (enc_scramble_init),
.coded_bits (enc_coded),
.coded_valid (enc_coded_valid)
 );

 // -------------------------------------------------------------------------
 // Arbiter FSM
 //   S_IDLE      — pick ch0 if req=1, else ch1 if req=1, kick encoder
 //   S_CH0_BUSY  — wait enc_coded_valid → pulse ch0_done, latch ch0_coded
 //   S_CH1_BUSY  — same for ch1
 // -------------------------------------------------------------------------
 localparam [1:0] S_IDLE = 2'd0;
 localparam [1:0] S_CH0_BUSY = 2'd1;
 localparam [1:0] S_CH1_BUSY = 2'd2;

 reg [1:0] state;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state <= S_IDLE;
 enc_start <= 1'b0;
 enc_info_bits <= 124'd0;
 enc_scramble_init <= 32'd0;
 ch0_done <= 1'b0;
 ch0_coded <= 216'd0;
 ch1_done <= 1'b0;
 ch1_coded <= 216'd0;
 end else begin
 // Defaults (1-cycle pulses)
 enc_start <= 1'b0;
 ch0_done <= 1'b0;
 ch1_done <= 1'b0;

 case (state)
 S_IDLE: begin
 if (ch0_req) begin
 enc_info_bits <= ch0_info_bits;
 enc_scramble_init <= ch0_scramble_init;
 enc_start <= 1'b1;
 state <= S_CH0_BUSY;
 end else if (ch1_req) begin
 enc_info_bits <= ch1_info_bits;
 enc_scramble_init <= ch1_scramble_init;
 enc_start <= 1'b1;
 state <= S_CH1_BUSY;
 end
 end
 S_CH0_BUSY: begin
 if (enc_coded_valid) begin
 ch0_coded <= enc_coded;
 ch0_done <= 1'b1;
 state <= S_IDLE;
 end
 end
 S_CH1_BUSY: begin
 if (enc_coded_valid) begin
 ch1_coded <= enc_coded;
 ch1_done <= 1'b1;
 state <= S_IDLE;
 end
 end
 default: state <= S_IDLE;
 endcase
 end
 end

endmodule

`default_nettype wire
