// =============================================================================
// tetra_dl_signal_queue.v
//
// Downlink signalling queue — buffers coded SCH/F or SCH/HD PDUs produced
// by higher-layer FSMs (MLE registration, future CMCE, future SDS) and
// hands them to tetra_dl_signal_scheduler one at a time.
//
// Design decisions locked in the 2026-04-23 architecture review:
//   * DEPTH = 4          (enough for 2 parallel MS registrations + reserve)
//   * Overflow           drop-newest (retry is the MS's problem, not ours)
//   * Priority           strict prio: MLE-Accept (0) > CMCE (1) > SDS (2)
//   * No encoder sharing (each producer emits coded 432-bit PDUs already;
//                         queue is a pure byte-transport, zero PHY logic)
//
// Entry layout (register array, not BRAM — 4*~440 bits is tiny):
//   coded_bits[431:0]   SCH/F full 432b or SCH/HD LSB-aligned in [215:0]
//   pdu_type[1:0]       00 = SCH_F, 01 = SCH_HD, 10/11 = reserved
//   target_tn[1:0]      0..3 — which TN of the next frame to inject on
//   prio[1:0]           00 = MLE, 01 = CMCE, 10 = SDS, 11 = reserved
//   valid               slot occupancy
//
// Arbitration on pop:
//   Scan all 4 slots, find the (valid && lowest prio-number) entry.  Ties
//   broken by slot index (lower index wins).  Fully combinational — the
//   scheduler samples the head on its trigger cycle and asserts `pop` the
//   same cycle; the queue clears the entry on the next posedge.
//
// Arbitration on write:
//   Three write ports (MLE / CMCE / SDS).  At most one fires per cycle in
//   MVP (MLE owns the path, CMCE/SDS tied off).  If two fire the same
//   cycle, strict producer-prio (MLE > CMCE > SDS) selects the survivor;
//   the losers count as drop_cnt++ as well.
//
// drop_cnt semantics: sticky 16-bit counter incremented on any attempted
// write that could not be stored (queue full, or arbitration loss).  The
// scheduler / top-level wires this to an AXI debug register.
//
// Coding rules: Verilog-2001 strict
//   R1  one always block per register
//   R2  _sys suffix not used here (this module is single-clock, clk/rst_n)
//   R4  async active-low reset
//   R9  no initial blocks
//   R10 @(*) for combinational
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_dl_signal_queue #(
    parameter integer DEPTH = 4
)(
    input  wire         clk,
    input  wire         rst_n,

    // -------------------------------------------------------------------------
    // Producer write port — MLE registration FSM (prio 00)
    // -------------------------------------------------------------------------
    input  wire         wr_mle_valid,
    input  wire [431:0] wr_mle_coded,
    input  wire [1:0]   wr_mle_pdu_type,
    input  wire [1:0]   wr_mle_target_tn,
    // Option B (2026-04-24 commit 4): telemetry bits indicating that the
    // coded SCH/F block carries a concatenated BL-ACK second MAC-RESOURCE
    // (bluestation llc_bs_ms.rs schedule_outgoing_ack).  Purely
    // informational — the actual 2-PDU concat is already baked into the
    // 432-bit wr_mle_coded payload by tetra_mac_resource_dl_builder.  The
    // scheduler forwards these to top-level ILA probes / AXI debug regs
    // so we can observe on-air which slots ship an auto-ACK.
    input  wire         wr_mle_second_pdu_present,
    input  wire         wr_mle_second_pdu_nr,

    // -------------------------------------------------------------------------
    // Producer write port — CMCE (prio 01, tied off in MVP)
    // -------------------------------------------------------------------------
    input  wire         wr_cmce_valid,
    input  wire [431:0] wr_cmce_coded,
    input  wire [1:0]   wr_cmce_pdu_type,
    input  wire [1:0]   wr_cmce_target_tn,

    // -------------------------------------------------------------------------
    // Producer write port — SDS (prio 10, tied off in MVP)
    // -------------------------------------------------------------------------
    input  wire         wr_sds_valid,
    input  wire [431:0] wr_sds_coded,
    input  wire [1:0]   wr_sds_pdu_type,
    input  wire [1:0]   wr_sds_target_tn,

    // -------------------------------------------------------------------------
    // Consumer pop (single reader, single cycle latency)
    // -------------------------------------------------------------------------
    input  wire         pop,
    output wire         head_valid,
    output wire [431:0] head_coded,
    output wire [1:0]   head_pdu_type,
    output wire [1:0]   head_target_tn,
    output wire [1:0]   head_prio,
    output wire         head_second_pdu_present, // commit 4 telemetry
    output wire         head_second_pdu_nr,

    // -------------------------------------------------------------------------
    // Status / debug
    // -------------------------------------------------------------------------
    output wire [3:0]   depth_valid_mask,   // one bit per slot
    output wire [2:0]   depth_count,        // 0..DEPTH
    output reg  [15:0]  drop_cnt
);

    // =========================================================================
    // Storage — register array
    // =========================================================================
    reg [431:0] entry_coded   [0:DEPTH-1];
    reg [1:0]   entry_pdu_type[0:DEPTH-1];
    reg [1:0]   entry_target_tn[0:DEPTH-1];
    reg [1:0]   entry_prio    [0:DEPTH-1];
    reg         entry_second_pdu_present [0:DEPTH-1];
    reg         entry_second_pdu_nr      [0:DEPTH-1];
    reg [DEPTH-1:0] entry_valid;

    assign depth_valid_mask = entry_valid;
    assign depth_count      = {2'd0, entry_valid[0]} + {2'd0, entry_valid[1]}
                            + {2'd0, entry_valid[2]} + {2'd0, entry_valid[3]};

    // =========================================================================
    // Write-port arbitration — MLE > CMCE > SDS.  At most one wins.
    // =========================================================================
    wire        arb_write_valid = wr_mle_valid | wr_cmce_valid | wr_sds_valid;
    wire [1:0]  arb_write_prio  = wr_mle_valid ? 2'd0
                               : (wr_cmce_valid ? 2'd1 : 2'd2);
    wire [431:0] arb_write_coded    = wr_mle_valid  ? wr_mle_coded
                                    : wr_cmce_valid ? wr_cmce_coded
                                    :                 wr_sds_coded;
    wire [1:0]   arb_write_pdu_type = wr_mle_valid  ? wr_mle_pdu_type
                                    : wr_cmce_valid ? wr_cmce_pdu_type
                                    :                 wr_sds_pdu_type;
    wire [1:0]   arb_write_target_tn= wr_mle_valid  ? wr_mle_target_tn
                                    : wr_cmce_valid ? wr_cmce_target_tn
                                    :                 wr_sds_target_tn;
    // Only MLE currently sets a second_pdu; CMCE/SDS default to 0.
    wire         arb_write_second_pdu_present = wr_mle_valid ? wr_mle_second_pdu_present : 1'b0;
    wire         arb_write_second_pdu_nr      = wr_mle_valid ? wr_mle_second_pdu_nr      : 1'b0;

    // Count producers that attempted this cycle — used for drop-on-collision
    wire [1:0] write_attempts = {1'b0, wr_mle_valid}
                              + {1'b0, wr_cmce_valid}
                              + {1'b0, wr_sds_valid};

    // Free slot — lowest index with valid==0
    reg [2:0] free_idx;
    reg       have_free;
    integer   w_i;
    always @(*) begin
        free_idx  = 3'd0;
        have_free = 1'b0;
        for (w_i = DEPTH-1; w_i >= 0; w_i = w_i - 1) begin
            if (!entry_valid[w_i]) begin
                free_idx  = w_i[2:0];
                have_free = 1'b1;
            end
        end
    end

    wire write_accepted = arb_write_valid && have_free;

    // =========================================================================
    // Pop-port arbitration — strict priority over valid entries.  For DEPTH=4
    // we unroll per prio level; ties within a prio go to lower slot index.
    // =========================================================================
    reg [2:0] idx_prio0, idx_prio1, idx_prio2, idx_prio3;
    reg       hit_prio0, hit_prio1, hit_prio2, hit_prio3;
    integer   p_i;

    // Reverse scan + unconditional reassign → last assignment wins → lowest
    // slot index with matching prio survives.
    always @(*) begin
        hit_prio0 = 1'b0;
        idx_prio0 = 3'd0;
        for (p_i = DEPTH-1; p_i >= 0; p_i = p_i - 1) begin
            if (entry_valid[p_i] && entry_prio[p_i] == 2'd0) begin
                hit_prio0 = 1'b1;
                idx_prio0 = p_i[2:0];
            end
        end
    end
    always @(*) begin
        hit_prio1 = 1'b0;
        idx_prio1 = 3'd0;
        for (p_i = DEPTH-1; p_i >= 0; p_i = p_i - 1) begin
            if (entry_valid[p_i] && entry_prio[p_i] == 2'd1) begin
                hit_prio1 = 1'b1;
                idx_prio1 = p_i[2:0];
            end
        end
    end
    always @(*) begin
        hit_prio2 = 1'b0;
        idx_prio2 = 3'd0;
        for (p_i = DEPTH-1; p_i >= 0; p_i = p_i - 1) begin
            if (entry_valid[p_i] && entry_prio[p_i] == 2'd2) begin
                hit_prio2 = 1'b1;
                idx_prio2 = p_i[2:0];
            end
        end
    end
    always @(*) begin
        hit_prio3 = 1'b0;
        idx_prio3 = 3'd0;
        for (p_i = DEPTH-1; p_i >= 0; p_i = p_i - 1) begin
            if (entry_valid[p_i] && entry_prio[p_i] == 2'd3) begin
                hit_prio3 = 1'b1;
                idx_prio3 = p_i[2:0];
            end
        end
    end

    reg [2:0] head_idx;
    reg       head_found;
    always @(*) begin
        if (hit_prio0) begin
            head_idx   = idx_prio0;
            head_found = 1'b1;
        end else if (hit_prio1) begin
            head_idx   = idx_prio1;
            head_found = 1'b1;
        end else if (hit_prio2) begin
            head_idx   = idx_prio2;
            head_found = 1'b1;
        end else if (hit_prio3) begin
            head_idx   = idx_prio3;
            head_found = 1'b1;
        end else begin
            head_idx   = 3'd0;
            head_found = 1'b0;
        end
    end

    assign head_valid     = head_found;
    assign head_coded     = entry_coded   [head_idx];
    assign head_pdu_type  = entry_pdu_type[head_idx];
    assign head_target_tn = entry_target_tn[head_idx];
    assign head_prio      = entry_prio    [head_idx];
    assign head_second_pdu_present = entry_second_pdu_present[head_idx];
    assign head_second_pdu_nr      = entry_second_pdu_nr     [head_idx];

    // =========================================================================
    // Storage updates — single always block per slot register-set
    //
    // Semantics (each posedge):
    //   1. If `pop && head_valid`, clear entry[head_idx].valid
    //   2. If `write_accepted`, install new entry into entry[free_idx]
    //
    // Pop and write can happen the same cycle; they target different slots
    // because pop's head_idx is a valid slot and write's free_idx is !valid.
    // =========================================================================
    integer s_i;

    // Valid mask
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid <= {DEPTH{1'b0}};
        end else begin
            if (pop && head_valid)
                entry_valid[head_idx] <= 1'b0;
            if (write_accepted)
                entry_valid[free_idx] <= 1'b1;
        end
    end

    // Payload registers — update only on write_accepted
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s_i = 0; s_i < DEPTH; s_i = s_i + 1) begin
                entry_coded    [s_i] <= 432'd0;
                entry_pdu_type [s_i] <= 2'd0;
                entry_target_tn[s_i] <= 2'd0;
                entry_prio     [s_i] <= 2'd0;
                entry_second_pdu_present[s_i] <= 1'b0;
                entry_second_pdu_nr     [s_i] <= 1'b0;
            end
        end else if (write_accepted) begin
            entry_coded    [free_idx] <= arb_write_coded;
            entry_pdu_type [free_idx] <= arb_write_pdu_type;
            entry_target_tn[free_idx] <= arb_write_target_tn;
            entry_prio     [free_idx] <= arb_write_prio;
            entry_second_pdu_present[free_idx] <= arb_write_second_pdu_present;
            entry_second_pdu_nr     [free_idx] <= arb_write_second_pdu_nr;
        end
    end

    // =========================================================================
    // Drop counter — increments on:
    //   * arb_write_valid && !have_free  (queue full, newest dropped)
    //   * write_attempts > 1 && have_free (collision, losers dropped)
    //   * arb_write_valid && !have_free && collision (compound — both)
    // Saturates at 16'hFFFF.
    // =========================================================================
    wire [2:0] drop_losers = (write_attempts >= 2'd2) ? (write_attempts - 2'd1)
                                                      : 3'd0;
    wire [2:0] drop_full   = (arb_write_valid && !have_free) ? 3'd1 : 3'd0;
    wire [2:0] drop_this   = drop_losers + drop_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            drop_cnt <= 16'd0;
        else if (drop_this != 3'd0 && drop_cnt != 16'hFFFF)
            drop_cnt <= drop_cnt + {13'd0, drop_this};
    end

endmodule

`default_nettype wire
