// =============================================================================
// tetra_axi_dma_bridge.v  —  PL → PS DMA Bridge (S2MM path)
// Project : tetra-zynq-phy  (Zynq-7020 + AD9361)
// Standard: ETSI EN 300 392-2 §7 (MAC block framing)
// =============================================================================
// Packs decoded MAC blocks from the LMAC into an AXI4-Stream word stream
// that feeds the Xilinx AXI DMA IP (S2MM channel: Stream→Memory-Mapped).
//
// Packet format per MAC block:
//   Word 0  — Header:  [31:30]=slot_num [29:28]=burst_type
//                       [27:16]=block_len_bits [15:0]=frame_num
//   Words 1…N — Payload: MAC block bits packed LSB-first into 32-bit words
//
// Block sizes supported:
//   NDB Block 1/2 : 216 bits → 7 data words  (8 words total incl. header)
//   SCH/F Block   : 432 bits → 14 data words (15 words total)
//   Any multiple of 1 bit up to MAX_BLOCK_BITS.
//
// AXI4-Stream TKEEP:
//   All words except last: 4'hF (all bytes valid)
//   Last word: byte mask derived from (block_len mod 32):
//     0 → 4'hF (full), 1–8 → 4'h1, 9–16 → 4'h3, 17–24 → 4'h7, 25–31 → 4'hF
//
// TX path (MM2S, PS→PL): Phase 3 — not implemented here, reserved ports only.
//
// NOTE ON PORT NAMING (R2 exception):
//   m_axis_* ports follow AXI4-Stream Vivado naming convention (no _sys suffix).
//   All internal signals carry the _sys suffix per Rule R2.
//
// Coding Rules: Verilog-2001 strict
//   R1 : one always block per register
//   R2 : _sys suffix on all internal signals
//   R3 : no arrays; 448-bit flat payload register (14 × 32)
//   R4 : async active-low rst_n_sys
//   R5 : FSM — 3 separate always blocks
//   R9 : no initial blocks
//   R10: @(*) for all combinatorial blocks
// =============================================================================
`default_nettype none

module tetra_axi_dma_bridge #(
    parameter MAX_BLOCK_BITS = 432,   // maximum MAC block size
    parameter MAX_DATA_WORDS = 14     // ceil(432/32) = 14
)(
    // ------------------------------------------------------------------
    // System Clock & Reset  (all internal logic in sys domain)
    // ------------------------------------------------------------------
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    // ------------------------------------------------------------------
    // MAC Block Input  (from LMAC, sys domain)
    // ------------------------------------------------------------------
    // mac_valid_sys: 1-cycle pulse indicating mac_data/meta are stable
    input  wire [MAX_BLOCK_BITS-1:0] mac_data_sys,      // block payload
    input  wire [9:0]  mac_len_sys,    // block length in bits (1–432)
    input  wire [1:0]  mac_slot_sys,   // timeslot number (0–3)
    input  wire [1:0]  mac_burst_type_sys, // 0=NDB, 1=SB, 2=NUB
    input  wire [15:0] mac_frame_sys,  // frame number
    input  wire        mac_valid_sys,  // pulse: new block available

    // mac_ready_sys: indicates bridge can accept a new block
    output wire        mac_ready_sys,

    // ------------------------------------------------------------------
    // AXI4-Stream Master  (to Xilinx AXI DMA IP — S2MM channel)
    // Port names follow Vivado BD convention (no _sys suffix)
    // ------------------------------------------------------------------
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tlast,

    // ------------------------------------------------------------------
    // Status & IRQ Outputs  (sys domain → axi_lite_regs + PS)
    // ------------------------------------------------------------------
    output reg  [15:0] dma_block_count_sys,   // total blocks sent (since reset)
    output reg         irq_mac_block_sys,      // 1-cycle pulse per block
    output wire        fifo_empty_sys,         // 1 when idle
    output wire        fifo_full_sys,          // 0 (no FIFO — direct stream)

    // From AXI-Lite CTRL register
    input  wire        reset_counters_sys      // 1 = clear dma_block_count
);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
localparam [1:0] S_IDLE = 2'b00;
localparam [1:0] S_SEND = 2'b01;

// Payload register width: 14 × 32 = 448 bits (pads upper 16 bits with 0)
localparam PAD_BITS    = MAX_DATA_WORDS * 32;      // 448
localparam PAD_WIDTH   = PAD_BITS;                  // 448

// ---------------------------------------------------------------------------
// State register  (R1, R4, R5)
// ---------------------------------------------------------------------------
reg [1:0] state_sys;

// ---------------------------------------------------------------------------
// Data path registers
// ---------------------------------------------------------------------------

// R1: Payload register — flat bus, 448 bits (14 × 32, upper 16 = padding zeros)
reg [PAD_WIDTH-1:0] payload_reg_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        payload_reg_sys <= {PAD_WIDTH{1'b0}};
    else if (mac_valid_sys & (state_sys == S_IDLE))
        payload_reg_sys <= {{16{1'b0}}, mac_data_sys}; // pad MSBs to 448 bits
end

// R1: Header register — assembled at mac_valid time
// [31:30]=slot, [29:28]=burst_type, [27:16]=block_len (zero-extended to 12b),
// [15:0]=frame_num
reg [31:0] header_reg_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        header_reg_sys <= 32'b0;
    else if (mac_valid_sys & (state_sys == S_IDLE))
        header_reg_sys <= {mac_slot_sys,
                           mac_burst_type_sys,
                           2'b00, mac_len_sys, // 12-bit field, len is 10-bit
                           mac_frame_sys};
end

// R1: Number of data words register — ceil(mac_len/32)
// Computed: (mac_len + 31) >> 5
reg [4:0] num_data_words_reg_sys;
wire [4:0] num_data_words_w = (mac_len_sys + 10'd31) >> 5;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        num_data_words_reg_sys <= 5'd1;
    else if (mac_valid_sys & (state_sys == S_IDLE))
        num_data_words_reg_sys <= num_data_words_w;
end

// R1: TKEEP for last word register
// Bytes in last word = ceil((mac_len mod 32) / 8)
// last_bits = mac_len[4:0]; 0 means 32 (full word)
wire [4:0] last_bits_w   = (mac_len_sys[4:0] == 5'b0) ? 5'd0 : mac_len_sys[4:0];
wire [3:0] last_tkeep_w  = (last_bits_w == 5'd0)   ? 4'hF :
                            (last_bits_w  > 5'd24)  ? 4'hF :
                            (last_bits_w  > 5'd16)  ? 4'h7 :
                            (last_bits_w  > 5'd8)   ? 4'h3 :
                                                      4'h1;

reg [3:0] last_tkeep_reg_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        last_tkeep_reg_sys <= 4'hF;
    else if (mac_valid_sys & (state_sys == S_IDLE))
        last_tkeep_reg_sys <= last_tkeep_w;
end

// R1: Word counter — 0 = header, 1..num_data_words = data
reg [4:0] word_cnt_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        word_cnt_sys <= 5'b0;
    else if (state_sys == S_IDLE)
        word_cnt_sys <= 5'b0;                          // reset when idle
    else if (state_sys == S_SEND && m_axis_tvalid && m_axis_tready)
        word_cnt_sys <= word_cnt_sys + 5'b1;           // advance on handshake
end

// ---------------------------------------------------------------------------
// R5: FSM — State Register
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        state_sys <= S_IDLE;
    else
        state_sys <= next_state_sys;
end

// R5: FSM — Next-State Logic (combinatorial)
reg [1:0] next_state_sys;
always @(*) begin
    next_state_sys = state_sys;
    case (state_sys)
        S_IDLE:
            if (mac_valid_sys)
                next_state_sys = S_SEND;
        S_SEND:
            if (m_axis_tready && (word_cnt_sys == num_data_words_reg_sys))
                next_state_sys = S_IDLE;
        default:
            next_state_sys = S_IDLE;
    endcase
end

// ---------------------------------------------------------------------------
// AXI4-Stream Output Logic  (combinatorial from state/word_cnt, R10)
// ---------------------------------------------------------------------------

// TVALID: active whenever in SEND state
assign m_axis_tvalid = (state_sys == S_SEND);

// TLAST: on the last word (word_cnt == num_data_words, where header = word 0)
assign m_axis_tlast = (state_sys == S_SEND) &&
                      (word_cnt_sys == num_data_words_reg_sys);

// TKEEP: 4'hF for all words except the last data word
assign m_axis_tkeep = ((state_sys == S_SEND) &&
                       (word_cnt_sys == num_data_words_reg_sys)) ?
                      last_tkeep_reg_sys : 4'hF;

// TDATA mux:
//   word_cnt == 0 → header
//   word_cnt >= 1 → payload word (word_cnt-1) from flat bus
//   Variable part-select: (word_cnt-1) × 32 bits into payload_reg_sys
wire [9:0] data_bit_addr_sys = {(word_cnt_sys - 5'b1), 5'b0}; // = (cnt-1)*32
wire [31:0] tdata_payload_sys = payload_reg_sys[data_bit_addr_sys +: 32];

reg [31:0] tdata_mux_sys;
always @(*) begin
    if (word_cnt_sys == 5'b0)
        tdata_mux_sys = header_reg_sys;
    else
        tdata_mux_sys = tdata_payload_sys;
end

assign m_axis_tdata = tdata_mux_sys;

// mac_ready: accept new block only when idle
assign mac_ready_sys  = (state_sys == S_IDLE);
assign fifo_empty_sys = (state_sys == S_IDLE);
assign fifo_full_sys  = 1'b0; // no FIFO — direct stream

// ---------------------------------------------------------------------------
// Block completion pulse and counter
// ---------------------------------------------------------------------------

// block_done fires on the cycle the last word handshake completes
wire block_done_w_sys = (state_sys == S_SEND) &&
                        m_axis_tready &&
                        (word_cnt_sys == num_data_words_reg_sys);

// R1: IRQ pulse — registered 1 cycle after block_done
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        irq_mac_block_sys <= 1'b0;
    else
        irq_mac_block_sys <= block_done_w_sys;
end

// R1: DMA block count register
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        dma_block_count_sys <= 16'h0;
    else if (reset_counters_sys)
        dma_block_count_sys <= 16'h0;
    else if (block_done_w_sys)
        dma_block_count_sys <= dma_block_count_sys + 16'h1;
end

endmodule

`default_nettype wire
