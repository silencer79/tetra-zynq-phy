// =============================================================================
// tetra_ul_burst_capture.v — UL Random-Access Burst IQ Capture + Phase-Align
// =============================================================================
//
// Purpose:
//   After tetra_ul_sync_detect_os4 fires sync_found_sys on the x[14] symbol,
//   this module extracts 86 phase-aligned IQ samples from a ring buffer and
//   streams them to the downstream UL demodulator.
//
// ETSI CB layout (EN 300 392-2 §9.4.4.2.1 Table 9.3):
//     2 tail + 42 cb1 + 15 x + 42 cb2 + 2 tail = 103 sym  (Snmax=103)
//
// Symbol anchor: sync_found_sys pulses when x[14] (last x symbol) matches.
//   Taking burst-local index n=0 at x[14]:
//     cb1 = sym n=-56..-15 (42 syms)  — diff ref at n=-57 (last pre-x tail)
//     cb2 = sym n=+1..+42  (42 syms)  — diff ref at n=0   (x[14] itself)
//
//   Ring pre-window  = 57 syms * 4 sps = 228 samples before anchor
//   Ring post-window = 42 syms * 4 sps = 168 samples after  anchor
//   Ring depth       = 512 entries ≈ 128 syms (plenty of margin)
//
// Output stream (one sample/sys_clk, 1-cycle BRAM read latency):
//   43 CB1 samples (ref + 42 data), then 43 CB2 samples (ref + 42 data) = 86
//   iq_first_sys pulses on CB1[0] and CB2[0]; iq_last_sys on CB2[42];
//   iq_half_sys = 0 during CB1 window, 1 during CB2.
//
// Phase Alignment:
//   sync_detect runs 4 parallel correlators, one per symbol phase at 4 sps.
//   best_phase_sys identifies winning phase. A local phase_cnt_sys mirrors
//   the sync_detect internal counter (same reset, same valid_in_sys gate).
//   On sync_found_sys (registered, 1-cycle after trigger), the triggering
//   sample sits at ring[wp_sys - 1] and its phase was (phase_cnt_sys - 1)
//   mod 4. The winning-phase x[14] sample is delta_w = (phase_cnt_sys - 1 -
//   best_phase_sys) mod 4 samples earlier, so
//     anchor_idx_sys = wp_sys - 1 - delta_w  (mod RING_DEPTH)
//   Stepping by ±SPS from anchor gives correct-phase samples directly.
//
// Resource estimate (Zynq-7020):
//   LUT ≈ 90  FF ≈ 110  BRAM = 1  DSP = 0
//
// =============================================================================

`default_nettype none

module tetra_ul_burst_capture #(
    parameter IQ_WIDTH      = 16,
    parameter RING_DEPTH    = 512,
    parameter RING_ADDR_W   = 9,
    parameter SPS           = 4,
    parameter HALF_SYMS     = 43,   // 1 diff ref + 42 data per half
    parameter CB1_PRE_SMP   = 228,  // 57 sym * 4 sps  — anchor_idx − CB1[0]
    parameter POST_WAIT_SMP = 172   // ≥ 42*4, with margin for phase delay
)(
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,
    // Post-RRC IQ @ 4 sps (shared with tetra_ul_sync_detect_os4)
    input  wire signed [IQ_WIDTH-1:0] i_in_sys,
    input  wire signed [IQ_WIDTH-1:0] q_in_sys,
    input  wire                       valid_in_sys,
    // Sync pulse
    input  wire                       sync_found_sys,
    input  wire [1:0]                 best_phase_sys,
    // Phase-aligned output stream (86 samples per triggered burst)
    output reg  signed [IQ_WIDTH-1:0] i_out_sys,
    output reg  signed [IQ_WIDTH-1:0] q_out_sys,
    output reg                        iq_valid_sys,
    output reg                        iq_first_sys,  // CB1[0] and CB2[0]
    output reg                        iq_last_sys,   // CB2[42]
    output reg                        iq_half_sys,   // 0=CB1, 1=CB2
    // Debug / AXI visibility
    output wire                       capture_busy_sys,
    output reg  [15:0]                bursts_captured_sys
);

// -------------------------------------------------------------------------
// Ring buffer (BRAM-inferred) — continuous IQ write at 72 kHz
// -------------------------------------------------------------------------
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_i_sys [0:RING_DEPTH-1];
(* ram_style = "block" *)
reg signed [IQ_WIDTH-1:0] ring_q_sys [0:RING_DEPTH-1];

reg [RING_ADDR_W-1:0] wp_sys;
reg [1:0]             phase_cnt_sys;

always @(posedge clk_sys) begin
    if (valid_in_sys) begin
        ring_i_sys[wp_sys] <= i_in_sys;
        ring_q_sys[wp_sys] <= q_in_sys;
    end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        wp_sys        <= {RING_ADDR_W{1'b0}};
        phase_cnt_sys <= 2'd0;
    end else if (valid_in_sys) begin
        wp_sys        <= wp_sys + 1'b1;
        phase_cnt_sys <= phase_cnt_sys + 2'd1;
    end
end

// -------------------------------------------------------------------------
// FSM
// -------------------------------------------------------------------------
localparam S_IDLE       = 2'd0;
localparam S_WAIT_POST  = 2'd1;
localparam S_STREAM_CB1 = 2'd2;
localparam S_STREAM_CB2 = 2'd3;

reg [1:0]              state_sys;
reg [RING_ADDR_W-1:0]  anchor_idx_sys;
reg [RING_ADDR_W-1:0]  cb1_base_sys;
reg [8:0]              post_cnt_sys;
reg [5:0]              stream_idx_sys;

// Read-issue signals (latched by FSM, drive BRAM read on next cycle)
reg                       rd_en_sys;
reg                       rd_first_sys;
reg                       rd_last_sys;
reg                       rd_half_sys;
reg [RING_ADDR_W-1:0]     rd_addr_sys;

// (phase_cnt - 1 - best_phase) mod 4  — phase offset of trigger sample
wire [1:0] delta_w = phase_cnt_sys + 2'd3 - best_phase_sys;

// Anchor = ring index of x[14] at winning phase
// sync_found_sys registered 1 cycle after trigger → wp_sys has advanced by 1
// anchor = wp - 1 - delta   (wraps naturally in RING_ADDR_W bits)
wire [RING_ADDR_W-1:0] delta_ext_w  = {{(RING_ADDR_W-2){1'b0}}, delta_w};
wire [RING_ADDR_W-1:0] anchor_calc_w = wp_sys - delta_ext_w - {{(RING_ADDR_W-1){1'b0}}, 1'b1};

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        state_sys           <= S_IDLE;
        anchor_idx_sys      <= {RING_ADDR_W{1'b0}};
        cb1_base_sys        <= {RING_ADDR_W{1'b0}};
        post_cnt_sys        <= 9'd0;
        stream_idx_sys      <= 6'd0;
        rd_en_sys           <= 1'b0;
        rd_first_sys        <= 1'b0;
        rd_last_sys         <= 1'b0;
        rd_half_sys         <= 1'b0;
        rd_addr_sys         <= {RING_ADDR_W{1'b0}};
        bursts_captured_sys <= 16'd0;
    end else begin
        // Defaults — deassert pulse-like signals each cycle
        rd_en_sys    <= 1'b0;
        rd_first_sys <= 1'b0;
        rd_last_sys  <= 1'b0;

        case (state_sys)
        S_IDLE: begin
            if (sync_found_sys) begin
                anchor_idx_sys <= anchor_calc_w;
                cb1_base_sys   <= anchor_calc_w -
                                  CB1_PRE_SMP[RING_ADDR_W-1:0];
                post_cnt_sys   <= POST_WAIT_SMP[8:0];
                state_sys      <= S_WAIT_POST;
            end
        end

        S_WAIT_POST: begin
            if (valid_in_sys) begin
                if (post_cnt_sys <= 9'd1) begin
                    stream_idx_sys <= 6'd0;
                    state_sys      <= S_STREAM_CB1;
                end else begin
                    post_cnt_sys <= post_cnt_sys - 1'b1;
                end
            end
        end

        S_STREAM_CB1: begin
            rd_addr_sys  <= cb1_base_sys +
                            ({{(RING_ADDR_W-6){1'b0}}, stream_idx_sys} *
                             SPS[RING_ADDR_W-1:0]);
            rd_en_sys    <= 1'b1;
            rd_first_sys <= (stream_idx_sys == 6'd0);
            rd_half_sys  <= 1'b0;
            if (stream_idx_sys == HALF_SYMS[5:0] - 6'd1) begin
                stream_idx_sys <= 6'd0;
                state_sys      <= S_STREAM_CB2;
            end else begin
                stream_idx_sys <= stream_idx_sys + 1'b1;
            end
        end

        S_STREAM_CB2: begin
            rd_addr_sys  <= anchor_idx_sys +
                            ({{(RING_ADDR_W-6){1'b0}}, stream_idx_sys} *
                             SPS[RING_ADDR_W-1:0]);
            rd_en_sys    <= 1'b1;
            rd_first_sys <= (stream_idx_sys == 6'd0);
            rd_last_sys  <= (stream_idx_sys == HALF_SYMS[5:0] - 6'd1);
            rd_half_sys  <= 1'b1;
            if (stream_idx_sys == HALF_SYMS[5:0] - 6'd1) begin
                bursts_captured_sys <= bursts_captured_sys + 16'd1;
                state_sys           <= S_IDLE;
            end else begin
                stream_idx_sys <= stream_idx_sys + 1'b1;
            end
        end

        default: state_sys <= S_IDLE;
        endcase
    end
end

// -------------------------------------------------------------------------
// BRAM sync read (1-cycle latency) — delivers i_out_sys/q_out_sys directly
// -------------------------------------------------------------------------
always @(posedge clk_sys) begin
    if (rd_en_sys) begin
        i_out_sys <= ring_i_sys[rd_addr_sys];
        q_out_sys <= ring_q_sys[rd_addr_sys];
    end
end

// -------------------------------------------------------------------------
// Metadata pipeline — matches BRAM read latency (1 cycle)
// -------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        iq_valid_sys <= 1'b0;
        iq_first_sys <= 1'b0;
        iq_last_sys  <= 1'b0;
        iq_half_sys  <= 1'b0;
    end else begin
        iq_valid_sys <= rd_en_sys;
        iq_first_sys <= rd_first_sys;
        iq_last_sys  <= rd_last_sys;
        iq_half_sys  <= rd_half_sys;
    end
end

assign capture_busy_sys = (state_sys != S_IDLE) | iq_valid_sys;

endmodule

`default_nettype wire
