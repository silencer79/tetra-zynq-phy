// =============================================================================
// tetra_tdma_timebase.v — Canonical TX-side TDMA Timebase (Stufe 1)
// =============================================================================
//
// Deterministic TDMA counter for the TX path.  Drives downstream encoders
// (BSCH, AACH, schedule, content-mux) with the air-side (TN, FN, MN, HN)
// tuple for the slot that is about to be built.
//
// Counter conventions (AIR-SIDE, 0-based — used directly as SYNC-PDU bit
// fields; ETSI 1-based display = value + 1):
//
//   sym_cnt:  0..254   (255 symbols per slot, one sym_en strobe per count)
//   tn:       0..3     (4 timeslots per frame)
//   fn:       0..17    (18 frames per multiframe)
//   mn:       0..59    (60 multiframes per hyperframe)
//   hn:       0..63    (6 bit hyperframe counter, free-running wrap)
//
// Note: this module intentionally uses 0-based counters and therefore
// differs from the RX-side tetra_frame_counter.v which mirrors the ETSI
// 1-based hardware convention for display.  Using 0-based values here
// lets the BSCH encoder (Stufe 3.5) drop TN/FN/MN straight into the
// SYNC PDU bitfields with no conversion.
//
// Strobes:
//   tdma_tick   — one clk_sys cycle HIGH on the sym_en edge that makes
//                 sym_cnt wrap 254 -> 0.  Leads slot_pulse by exactly
//                 one sys-cycle.  Intended as a pre-load strobe for
//                 downstream encoders that need the upcoming (tn, fn,
//                 mn, hn) tuple a cycle in advance.
//   slot_pulse  — one clk_sys cycle HIGH, one sys-cycle AFTER tdma_tick.
//                 Fires once per slot; indicates the counters have
//                 advanced to the new slot's values.
//
// Software sync:
//   sync_load_strobe, when HIGH for one clk_sys cycle, latches
//   (sync_tn_in, sync_fn_in, sync_mn_in, sync_hn_in) into a pending
//   shadow register.  The load is committed on the NEXT sym_en strobe,
//   at which point sym_cnt is forced to 0 and the counters adopt the
//   loaded values.  Deferring the commit to sym_en avoids races with
//   the free-running counter increment and keeps the slot grid
//   symbol-aligned.
//
//   If sync_load_strobe and sym_en fall on the same sys-cycle, the
//   sync-load wins (commit happens this cycle; counters adopt the
//   loaded values, sym_cnt = 0, no counter advance this cycle).
//
// Wrap hierarchy (executed on sym_en only, nested conditions):
//   sym_cnt 254 -> 0  triggers tn++
//   tn       3 -> 0   triggers fn++
//   fn      17 -> 0   triggers mn++
//   mn      59 -> 0   triggers hn++
//   hn      63 -> 0   wraps freely (no higher layer)
//
// Reset (async active-low rst_n_sys):
//   sym_cnt=0, tn=0, fn=0, mn=0, hn=0, slot_pulse=0, tdma_tick=0.
//
// Clock domain: _sys  (clk_sys ~100 MHz; sym_en strobe 18 kHz = every
//                      ~5556 sys-cycles in real hardware).
//
// Resource estimate: LUT ~30  FF ~32  DSP 0  BRAM 0
// =============================================================================

`default_nettype none

module tetra_tdma_timebase (
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire        sym_en,              // 18 kHz strobe (1 sys-cycle)

    // SW-Sync (1 sys-cycle pulse from AXI write to TX_TDMA_LOAD)
    input  wire        sync_load_strobe,
    input  wire [1:0]  sync_tn_in,          // 0..3
    input  wire [4:0]  sync_fn_in,          // 0..17
    input  wire [5:0]  sync_mn_in,          // 0..59
    input  wire [5:0]  sync_hn_in,          // 0..63

    // Counter outputs (current slot's values; valid throughout the slot)
    output reg  [7:0]  sym_cnt,             // 0..254 within slot
    output reg  [1:0]  tn,                  // 0..3
    output reg  [4:0]  fn,                  // 0..17
    output reg  [5:0]  mn,                  // 0..59
    output reg  [5:0]  hn,                  // 0..63

    // Strobes
    output reg         slot_pulse,          // 1 sys-cycle when slot transitions
    output reg         tdma_tick            // 1 sys-cycle BEFORE slot_pulse
);

// ---------------------------------------------------------------------------
// Pending sync-load shadow
// ---------------------------------------------------------------------------
// When sync_load_strobe is asserted, capture the requested counter values
// into a shadow register and raise sync_load_pending.  The shadow is
// applied on the next sym_en (or on the same cycle if sym_en coincides).
// Pipeline Stage 0: sync-load shadow latch
// ---------------------------------------------------------------------------
reg        sync_load_pending_sys;
reg [1:0]  sync_tn_shadow_sys;
reg [4:0]  sync_fn_shadow_sys;
reg [5:0]  sync_mn_shadow_sys;
reg [5:0]  sync_hn_shadow_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sync_load_pending_sys <= 1'b0;
        sync_tn_shadow_sys    <= 2'd0;
        sync_fn_shadow_sys    <= 5'd0;
        sync_mn_shadow_sys    <= 6'd0;
        sync_hn_shadow_sys    <= 6'd0;
    end else begin
        // Capture the shadow on strobe.  If strobe fires while a previous
        // pending load has not yet committed, the newer values overwrite
        // the older ones (last-writer-wins; simpler than queueing, and
        // SW drives this at most once per TDMA frame).
        if (sync_load_strobe) begin
            sync_tn_shadow_sys <= sync_tn_in;
            sync_fn_shadow_sys <= sync_fn_in;
            sync_mn_shadow_sys <= sync_mn_in;
            sync_hn_shadow_sys <= sync_hn_in;
            sync_load_pending_sys <= 1'b1;
        end else if (sym_en && sync_load_pending_sys) begin
            // Commit consumed on this sym_en edge; clear pending flag
            sync_load_pending_sys <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// Wrap-edge combinational helpers (use PRE-update counter values + sym_en)
// ---------------------------------------------------------------------------
wire slot_edge_sys = sym_en && (sym_cnt == 8'd254);

// Effective commit trigger for sync-load (commit on sym_en when pending,
// OR immediately on the same sys-cycle when strobe + sym_en coincide).
wire sync_commit_sys = sym_en && (sync_load_pending_sys || sync_load_strobe);

// ---------------------------------------------------------------------------
// Main counter update (sym_en gated, with sync-load precedence)
// Pipeline Stage 1: TDMA counters
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
        sym_cnt <= 8'd0;
        tn      <= 2'd0;
        fn      <= 5'd0;
        mn      <= 6'd0;
        hn      <= 6'd0;
    end else if (sync_commit_sys) begin
        // Sync-load wins over free-running advance on this sym_en.
        // Pick the freshest shadow source: if strobe is live THIS cycle,
        // use the input directly (shadow reg has not latched it yet);
        // otherwise use the previously latched shadow.
        sym_cnt <= 8'd0;
        if (sync_load_strobe) begin
            tn <= sync_tn_in;
            fn <= sync_fn_in;
            mn <= sync_mn_in;
            hn <= sync_hn_in;
        end else begin
            tn <= sync_tn_shadow_sys;
            fn <= sync_fn_shadow_sys;
            mn <= sync_mn_shadow_sys;
            hn <= sync_hn_shadow_sys;
        end
    end else if (sym_en) begin
        if (slot_edge_sys) begin
            sym_cnt <= 8'd0;
            // TN wrap
            if (tn == 2'd3) begin
                tn <= 2'd0;
                // FN wrap
                if (fn == 5'd17) begin
                    fn <= 5'd0;
                    // MN wrap
                    if (mn == 6'd59) begin
                        mn <= 6'd0;
                        // HN wrap (free, 6-bit natural)
                        hn <= hn + 6'd1;
                    end else begin
                        mn <= mn + 6'd1;
                    end
                end else begin
                    fn <= fn + 5'd1;
                end
            end else begin
                tn <= tn + 2'd1;
            end
        end else begin
            sym_cnt <= sym_cnt + 8'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// tdma_tick — fires on the same sys-cycle as slot_edge_sys (i.e. the
// sym_en cycle that wraps sym_cnt 254 -> 0).  Counters have not yet
// updated at this edge, so downstream encoders using (tn, fn, mn, hn)
// on a tdma_tick see the OUTGOING slot's values; they must pipeline
// one cycle if they want to act on the NEXT slot's values.
//
// Note: on a sync-load commit we do NOT raise tdma_tick — the commit
// resets sym_cnt to 0 and adopts the loaded values in the same way a
// normal wrap would, but downstream encoders should treat a sync-load
// as an orderly restart, not as a normal slot boundary.
// Pipeline Stage 2: tdma_tick
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        tdma_tick <= 1'b0;
    else
        tdma_tick <= slot_edge_sys && !sync_commit_sys;
end

// ---------------------------------------------------------------------------
// slot_pulse — one sys-cycle delayed copy of tdma_tick, so slot_pulse
// fires exactly one sys-cycle AFTER tdma_tick (= tdma_tick leads by 1).
// Pipeline Stage 3: slot_pulse
// ---------------------------------------------------------------------------
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        slot_pulse <= 1'b0;
    else
        slot_pulse <= tdma_tick;
end

endmodule

`default_nettype wire
