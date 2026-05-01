// =============================================================================
// tetra_rx_burst_fifo.v — Phase H.4.1 — UL RX-Burst-Stream-FIFO
// =============================================================================
//
// Pushes every UL-RX burst into a 16-deep BRAM-FIFO so the ARM PS can
// read the raw 92-bit MAC-ACCESS / MAC-END-HU body together with metadata
// (SSI, burst type, frag flag, timestamp).  Replaces the legacy single-
// sticky UL_PDU mailbox (REG_UL_PDU_STATUS @ 0x164..0x17C) for streaming
// access — Phase J SW reads this FIFO when handling Group-Switch (mm=7),
// CMCE call setup, and any other PS-side protocol logic.
//
// Push sources (multiplexed in `u_rx_chain` upstream wiring):
//   - ul_pdu_valid_sys     → MAC-ACCESS frag-1 / BL-ACK / mm=4 single-burst
//   - ul_continuation_valid_sys → MAC-END-HU continuation
//   (only one source pulses per cycle; if both ever fire together, the
//    bits source has priority and the continuation drops with drop_cnt++)
//
// Pop interface (clk_axi side; clk_sys==clk_axi in this design):
//   - pop_pulse_axi         — 1-cycle pulse advances rp_axi
//   - data0_axi[31:0]       — bits[31:0] at current rp_axi
//   - data1_axi[31:0]       — bits[63:32]
//   - data2_axi[31:0]       — {4'b0, bits[91:64]} (28 bits used)
//   - meta_axi [31:0]       — {ssi[23:0], burst_type[3:0], crc_ok, frag,
//                              addr_type[1:0]} (drop the timestamp slot
//                              and use ts_axi separately)
//   - ts_axi   [31:0]       — push-time mf_global_cnt[23:0] (drop hi 8b)
//   - status_axi[31:0]      — {drop_cnt[15:0], 12'd0, count[3:0]}
//                              (count==0 → empty, count==DEPTH → full,
//                               halffull = count >= DEPTH/2)
//
// Resource estimate (Zynq-7020):
//   16 entries × 156 bits = 2496 bits → fits in 1 RAMB18 (18 kb).
//   FF ≈ 60 (pointers + status), LUT ≈ 200 (mux + decode + push gate).
// =============================================================================

`default_nettype none

module tetra_rx_burst_fifo #(
    parameter DEPTH      = 16,
    parameter ADDR_WIDTH = 4,
    parameter BITS_WIDTH = 92,
    parameter SSI_WIDTH  = 24,
    parameter TS_WIDTH   = 24,
    parameter META_WIDTH = 8           // burst_type[3:0]+crc_ok+frag+addr_type[1:0]
)(
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,

    // -------------------------------------------------------------------------
    // Push port A — primary 92-bit MAC-ACCESS / BL-ACK / single-burst body
    // -------------------------------------------------------------------------
    input  wire                       push_a_pulse_sys,
    input  wire [BITS_WIDTH-1:0]      push_a_bits_sys,
    input  wire [SSI_WIDTH-1:0]       push_a_ssi_sys,
    input  wire [META_WIDTH-1:0]      push_a_meta_sys,    // see header

    // -------------------------------------------------------------------------
    // Push port B — MAC-END-HU continuation body (zero-padded to 92 bits)
    // -------------------------------------------------------------------------
    input  wire                       push_b_pulse_sys,
    input  wire [BITS_WIDTH-1:0]      push_b_bits_sys,
    input  wire [SSI_WIDTH-1:0]       push_b_ssi_sys,
    input  wire [META_WIDTH-1:0]      push_b_meta_sys,

    // Push-time timestamp source (multiframe counter — slow enough that
    // truncating to 24 bits gives ~10h of unique values at 17.6 ms/MF).
    input  wire [TS_WIDTH-1:0]        push_ts_sys,

    // -------------------------------------------------------------------------
    // Pop port (clk_axi == clk_sys in this design)
    // -------------------------------------------------------------------------
    input  wire                       pop_pulse_axi,
    output wire [31:0]                data0_axi,
    output wire [31:0]                data1_axi,
    output wire [31:0]                data2_axi,
    output wire [31:0]                meta_axi,
    output wire [31:0]                ts_axi,
    output wire [31:0]                status_axi,

    // Telemetry (clk_sys side — for AXI-resync at top level if needed)
    output wire [ADDR_WIDTH:0]        count_sys,
    output wire [15:0]                drop_cnt_sys
);

    localparam integer ENTRY_WIDTH = BITS_WIDTH + SSI_WIDTH + TS_WIDTH + META_WIDTH;
    // 92 + 24 + 24 + 8 = 148 bits per entry

    // -------------------------------------------------------------------------
    // BRAM-inferred storage — 16 × 148 bits.  Synth tools place this in
    // 1 RAMB18 (18 kb available, 16×148=2368 bits used).
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [ENTRY_WIDTH-1:0] mem_sys [0:DEPTH-1];

    // Pointers
    reg [ADDR_WIDTH-1:0]  wp_sys;
    reg [ADDR_WIDTH-1:0]  rp_sys;
    reg [ADDR_WIDTH:0]    cnt_sys;        // 0..DEPTH (one extra bit for full)
    reg [15:0]            drop_cnt_sys_r;

    // -------------------------------------------------------------------------
    // Push arbitration — port A wins on simultaneous pulses; port B drops
    // (very unlikely race because A and B sources are 1+ slot apart on air).
    // -------------------------------------------------------------------------
    wire                  push_a_take_w = push_a_pulse_sys & (cnt_sys != DEPTH[ADDR_WIDTH:0]);
    wire                  push_b_take_w = push_b_pulse_sys & ~push_a_pulse_sys &
                                          (cnt_sys != DEPTH[ADDR_WIDTH:0]);
    wire                  push_take_w   = push_a_take_w | push_b_take_w;
    wire                  push_drop_w   =
        (push_a_pulse_sys & ~push_a_take_w) |
        (push_b_pulse_sys & ~push_b_take_w & ~push_a_pulse_sys) |
        (push_b_pulse_sys & push_a_pulse_sys);  // B drops if A takes

    wire [BITS_WIDTH-1:0] push_bits_w = push_a_take_w ? push_a_bits_sys : push_b_bits_sys;
    wire [SSI_WIDTH-1:0]  push_ssi_w  = push_a_take_w ? push_a_ssi_sys  : push_b_ssi_sys;
    wire [META_WIDTH-1:0] push_meta_w = push_a_take_w ? push_a_meta_sys : push_b_meta_sys;

    wire [ENTRY_WIDTH-1:0] push_entry_w = {push_bits_w, push_ssi_w, push_ts_sys, push_meta_w};

    // -------------------------------------------------------------------------
    // Pop side — clk_sys == clk_axi (no CDC needed in this design)
    // -------------------------------------------------------------------------
    wire pop_take_w = pop_pulse_axi & (cnt_sys != {(ADDR_WIDTH+1){1'b0}});

    // -------------------------------------------------------------------------
    // Write pointer
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            wp_sys <= {ADDR_WIDTH{1'b0}};
        else if (push_take_w)
            wp_sys <= wp_sys + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
    end

    // -------------------------------------------------------------------------
    // Read pointer
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            rp_sys <= {ADDR_WIDTH{1'b0}};
        else if (pop_take_w)
            rp_sys <= rp_sys + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
    end

    // -------------------------------------------------------------------------
    // Depth counter
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            cnt_sys <= {(ADDR_WIDTH+1){1'b0}};
        else if (push_take_w & ~pop_take_w)
            cnt_sys <= cnt_sys + {{ADDR_WIDTH{1'b0}}, 1'b1};
        else if (~push_take_w & pop_take_w)
            cnt_sys <= cnt_sys - {{ADDR_WIDTH{1'b0}}, 1'b1};
    end

    // -------------------------------------------------------------------------
    // Drop counter — saturating at 16'hFFFF
    // -------------------------------------------------------------------------
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            drop_cnt_sys_r <= 16'd0;
        else if (push_drop_w & (drop_cnt_sys_r != 16'hFFFF))
            drop_cnt_sys_r <= drop_cnt_sys_r + 16'd1;
    end

    // -------------------------------------------------------------------------
    // Memory write
    // -------------------------------------------------------------------------
    always @(posedge clk_sys) begin
        if (push_take_w)
            mem_sys[wp_sys] <= push_entry_w;
    end

    // -------------------------------------------------------------------------
    // Memory read — 1-cycle BRAM read latency.  Output registered so the
    // pop port presents the head-of-FIFO entry on the SAME cycle as the
    // pop_pulse (i.e. read-before-pop).  We achieve this by always reading
    // mem_sys[rp_sys] into rd_q_sys, with rp_sys advancing post-pop.
    // -------------------------------------------------------------------------
    reg [ENTRY_WIDTH-1:0] rd_q_sys;
    always @(posedge clk_sys) begin
        rd_q_sys <= mem_sys[rp_sys];
    end

    // -------------------------------------------------------------------------
    // Output unpacking
    // -------------------------------------------------------------------------
    wire [BITS_WIDTH-1:0] rd_bits_w = rd_q_sys[ENTRY_WIDTH-1 -: BITS_WIDTH];
    wire [SSI_WIDTH-1:0]  rd_ssi_w  = rd_q_sys[ENTRY_WIDTH-1-BITS_WIDTH -: SSI_WIDTH];
    wire [TS_WIDTH-1:0]   rd_ts_w   = rd_q_sys[ENTRY_WIDTH-1-BITS_WIDTH-SSI_WIDTH -: TS_WIDTH];
    wire [META_WIDTH-1:0] rd_meta_w = rd_q_sys[META_WIDTH-1:0];

    assign data0_axi  = rd_bits_w[31:0];
    assign data1_axi  = rd_bits_w[63:32];
    assign data2_axi  = {4'b0, rd_bits_w[91:64]};
    assign meta_axi   = {rd_ssi_w, rd_meta_w};
    assign ts_axi     = {{(32-TS_WIDTH){1'b0}}, rd_ts_w};
    // Status word layout (32 bit):
    //   [31:16] drop_cnt[15:0]   — saturating overflow counter
    //   [15: 8] reserved (0)
    //   [ 7: 4] count[3:0]       — current entries
    //   [ 3]    full             — count == DEPTH
    //   [ 2]    halffull         — count >= DEPTH/2
    //   [ 1]    reserved (0)
    //   [ 0]    empty            — count == 0
    assign status_axi = {drop_cnt_sys_r,
                         8'b0,
                         cnt_sys[ADDR_WIDTH-1:0],
                         cnt_sys[ADDR_WIDTH:0] == DEPTH[ADDR_WIDTH:0],
                         (cnt_sys >= (DEPTH[ADDR_WIDTH:0] >> 1)),
                         1'b0,
                         cnt_sys == {(ADDR_WIDTH+1){1'b0}}};

    assign count_sys    = cnt_sys;
    assign drop_cnt_sys = drop_cnt_sys_r;

endmodule

`default_nettype wire
