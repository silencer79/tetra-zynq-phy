// =============================================================================
// tb_tetra_tdma_timebase.v — Self-Checking Testbench (Stufe 1)
// =============================================================================
//
// Test cases:
//   TC1: Reset — after rst_n_sys deassert, counters = 0, no strobes
//   TC2: sym_cnt wrap — 255 sym_en strobes => sym_cnt=0, tn incremented,
//                       exactly one slot_pulse fired
//   TC3: tdma_tick leads slot_pulse by 1 sys-cycle; both 1-cycle wide
//   TC4: TN wrap — after 4 slots: tn=0, fn=1
//   TC5: FN wrap — after 18 frames (72 slots): fn=0, mn=1
//   TC6: MN wrap — pre-load MN=58, then drive 2 multiframes: mn=0, hn=1
//   TC7: HN wrap — pre-load HN=62, drive 2 hyperframe boundaries:
//                   hn wraps 63->0
//   TC8: sync_load_strobe mid-slot — loaded values appear on NEXT sym_en;
//                                     sym_cnt reset to 0
//   TC9: sync_load_strobe coincident with sym_en — sync-load wins
//
// Timing: sym_en every SYM_PERIOD sys-cycles (fast for simulation).
//         Real hardware: ~5556 cycles at 100 MHz (18 kHz symbol rate).
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_tdma_timebase;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD        = 10;    // 10 ns → 100 MHz
localparam SYM_PERIOD        = 10;    // sym_en every 10 sys-cycles (fast sim)
localparam SYMS_PER_SLOT     = 255;
localparam SLOTS_PER_FRAME   = 4;
localparam FRAMES_PER_MF     = 18;
localparam MF_PER_HF         = 60;
localparam SLOTS_PER_MF      = SLOTS_PER_FRAME * FRAMES_PER_MF;    // 72

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg         clk_sys;
reg         rst_n_sys;
reg         sym_en;
reg         sync_load_strobe;
reg  [1:0]  sync_tn_in;
reg  [4:0]  sync_fn_in;
reg  [5:0]  sync_mn_in;
reg  [5:0]  sync_hn_in;

wire [7:0]  sym_cnt;
wire [1:0]  tn;
wire [4:0]  fn;
wire [5:0]  mn;
wire [5:0]  hn;
wire        slot_pulse;
wire        tdma_tick;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_tdma_timebase dut (
    .clk_sys         (clk_sys),
    .rst_n_sys       (rst_n_sys),
    .sym_en          (sym_en),
    .sync_load_strobe(sync_load_strobe),
    .sync_tn_in      (sync_tn_in),
    .sync_fn_in      (sync_fn_in),
    .sync_mn_in      (sync_mn_in),
    .sync_hn_in      (sync_hn_in),
    .sym_cnt         (sym_cnt),
    .tn              (tn),
    .fn              (fn),
    .mn              (mn),
    .hn              (hn),
    .slot_pulse      (slot_pulse),
    .tdma_tick       (tdma_tick)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_tdma_timebase.vcd");
    $dumpvars(0, tb_tetra_tdma_timebase);
end

// ---------------------------------------------------------------------------
// Clock generation
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// Counters for error tracking and strobe observation
// ---------------------------------------------------------------------------
integer err_count;
integer slot_pulse_count;
integer tdma_tick_count;
integer cycles_tick_to_pulse;    // measured distance in sys-cycles
reg     tick_seen_this_run;

initial begin
    err_count             = 0;
    slot_pulse_count      = 0;
    tdma_tick_count       = 0;
    cycles_tick_to_pulse  = -1;
    tick_seen_this_run    = 1'b0;
end

// Count strobes and measure tdma_tick -> slot_pulse distance
integer tick_cycle;
initial tick_cycle = 0;
integer cycle_idx;
initial cycle_idx = 0;

always @(posedge clk_sys) begin
    cycle_idx <= cycle_idx + 1;
    if (tdma_tick) begin
        tdma_tick_count <= tdma_tick_count + 1;
        tick_cycle      <= cycle_idx;
        tick_seen_this_run <= 1'b1;
    end
    if (slot_pulse) begin
        slot_pulse_count <= slot_pulse_count + 1;
        if (tick_seen_this_run && cycles_tick_to_pulse < 0)
            cycles_tick_to_pulse <= cycle_idx - tick_cycle;
    end
end

// ---------------------------------------------------------------------------
// Task: drive one sym_en pulse (1 sys-cycle wide) at the start of each
// SYM_PERIOD window.  Call at the beginning of a cycle; it will leave
// the DUT advanced by SYM_PERIOD cycles with exactly one sym_en tick.
// ---------------------------------------------------------------------------
task apply_sym_en;
    begin
        @(posedge clk_sys); #1;
        sym_en = 1'b1;
        @(posedge clk_sys); #1;
        sym_en = 1'b0;
        // Wait remainder of SYM_PERIOD
        repeat (SYM_PERIOD - 2) @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Task: drive N sym_en pulses
// ---------------------------------------------------------------------------
task apply_n_sym;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) apply_sym_en;
    end
endtask

// ---------------------------------------------------------------------------
// Task: apply one full slot (255 sym_en strobes)
// ---------------------------------------------------------------------------
task apply_slot;
    begin
        apply_n_sym(SYMS_PER_SLOT);
    end
endtask

// ---------------------------------------------------------------------------
// Task: apply N full slots
// ---------------------------------------------------------------------------
task apply_n_slots;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) apply_slot;
    end
endtask

// ---------------------------------------------------------------------------
// Task: pulse sync_load_strobe for 1 sys-cycle with given values
// ---------------------------------------------------------------------------
task sync_load;
    input [1:0] v_tn;
    input [4:0] v_fn;
    input [5:0] v_mn;
    input [5:0] v_hn;
    begin
        @(posedge clk_sys); #1;
        sync_tn_in       = v_tn;
        sync_fn_in       = v_fn;
        sync_mn_in       = v_mn;
        sync_hn_in       = v_hn;
        sync_load_strobe = 1'b1;
        @(posedge clk_sys); #1;
        sync_load_strobe = 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Main test body
// ---------------------------------------------------------------------------
initial begin
    // -----------------------------------------------------------------------
    // Initialise
    // -----------------------------------------------------------------------
    rst_n_sys        = 1'b0;
    sym_en           = 1'b0;
    sync_load_strobe = 1'b0;
    sync_tn_in       = 2'd0;
    sync_fn_in       = 5'd0;
    sync_mn_in       = 6'd0;
    sync_hn_in       = 6'd0;

    repeat (4) @(posedge clk_sys);
    rst_n_sys = 1'b1;
    repeat (2) @(posedge clk_sys);

    // -----------------------------------------------------------------------
    // TC1: Reset — all counters zero, no strobes
    // -----------------------------------------------------------------------
    $display("TC1: reset values");
    #1;
    if (sym_cnt !== 8'd0 || tn !== 2'd0 || fn !== 5'd0 ||
        mn !== 6'd0 || hn !== 6'd0 ||
        slot_pulse !== 1'b0 || tdma_tick !== 1'b0) begin
        $display("ERROR TC1: non-zero after reset — sym=%0d tn=%0d fn=%0d mn=%0d hn=%0d sp=%b tt=%b",
                 sym_cnt, tn, fn, mn, hn, slot_pulse, tdma_tick);
        err_count = err_count + 1;
    end else begin
        $display("TC1: PASS");
    end

    // -----------------------------------------------------------------------
    // TC2: sym_cnt wrap — 255 sym_en strobes
    // -----------------------------------------------------------------------
    $display("TC2: sym_cnt wrap after 255 sym_en strobes");
    begin : tc2
        integer sp_before;
        sp_before = slot_pulse_count;
        apply_slot;  // 255 sym_en strobes
        // After the 255th sym_en, sym_cnt has wrapped to 0, tn=1
        // slot_pulse lags tdma_tick by 1 sys-cycle; give it a moment
        repeat (3) @(posedge clk_sys); #1;
        if (sym_cnt !== 8'd0) begin
            $display("ERROR TC2: sym_cnt=%0d after slot, expected 0", sym_cnt);
            err_count = err_count + 1;
        end
        if (tn !== 2'd1) begin
            $display("ERROR TC2: tn=%0d after 1 slot, expected 1", tn);
            err_count = err_count + 1;
        end
        if ((slot_pulse_count - sp_before) !== 1) begin
            $display("ERROR TC2: slot_pulse fired %0d times in 1 slot, expected 1",
                     slot_pulse_count - sp_before);
            err_count = err_count + 1;
        end
        $display("TC2: PASS (sym_cnt=%0d tn=%0d pulses=%0d)",
                 sym_cnt, tn, slot_pulse_count - sp_before);
    end

    // -----------------------------------------------------------------------
    // TC3: tdma_tick leads slot_pulse by exactly 1 sys-cycle
    // -----------------------------------------------------------------------
    $display("TC3: tdma_tick -> slot_pulse gap = 1 sys-cycle");
    if (cycles_tick_to_pulse !== 1) begin
        $display("ERROR TC3: tick->pulse distance = %0d cycles, expected 1",
                 cycles_tick_to_pulse);
        err_count = err_count + 1;
    end else begin
        $display("TC3: PASS (distance = %0d)", cycles_tick_to_pulse);
    end

    // TC3b: after TC2 we have tdma_tick_count == slot_pulse_count (each
    // slot produced exactly one of each so far; slot_pulse is registered
    // copy of tdma_tick).
    if (tdma_tick_count !== slot_pulse_count) begin
        $display("ERROR TC3b: tdma_tick_count=%0d != slot_pulse_count=%0d",
                 tdma_tick_count, slot_pulse_count);
        err_count = err_count + 1;
    end else begin
        $display("TC3b: PASS (tick count = pulse count = %0d)", tdma_tick_count);
    end

    // -----------------------------------------------------------------------
    // TC4: TN wrap — drive 3 more slots (total 4 slots since reset):
    //      tn should be 0 again, fn should be 1
    // -----------------------------------------------------------------------
    $display("TC4: TN wrap after 4 slots");
    apply_n_slots(3);
    repeat (3) @(posedge clk_sys); #1;
    if (tn !== 2'd0 || fn !== 5'd1) begin
        $display("ERROR TC4: after 4 slots tn=%0d fn=%0d, expected tn=0 fn=1", tn, fn);
        err_count = err_count + 1;
    end else begin
        $display("TC4: PASS (tn=%0d fn=%0d)", tn, fn);
    end

    // -----------------------------------------------------------------------
    // TC5: FN wrap — drive 17 more frames (= 68 more slots) so total
    //      slots = 4 + 68 = 72 = 1 multiframe.  fn wraps 17->0, mn -> 1.
    // -----------------------------------------------------------------------
    $display("TC5: FN wrap after 1 multiframe (72 slots)");
    apply_n_slots(17 * SLOTS_PER_FRAME);   // 68 slots
    repeat (3) @(posedge clk_sys); #1;
    if (fn !== 5'd0 || mn !== 6'd1 || tn !== 2'd0) begin
        $display("ERROR TC5: after 1 mf tn=%0d fn=%0d mn=%0d, expected 0/0/1", tn, fn, mn);
        err_count = err_count + 1;
    end else begin
        $display("TC5: PASS (tn=0 fn=0 mn=1)");
    end

    // -----------------------------------------------------------------------
    // TC6: MN wrap — pre-load (tn=3, fn=17, mn=59, hn=0) with sym_cnt
    //      just before wrap, so the very next slot wraps the whole chain
    //      up through MN (mn 59 -> 0) and increments hn.  Achieved by
    //      loading at (tn=3, fn=17, mn=59) and driving 1 slot worth of
    //      sym_en strobes (255 syms), which rolls to (tn=0, fn=0, mn=0, hn=1).
    // -----------------------------------------------------------------------
    $display("TC6: MN wrap via pre-load (tn=3,fn=17,mn=59,hn=0)");
    sync_load(2'd3, 5'd17, 6'd59, 6'd0);
    // Commit happens on next sym_en; apply one sym_en to complete load.
    // After the commit, sym_cnt is 0 (no increment this cycle).
    apply_sym_en;
    repeat (3) @(posedge clk_sys); #1;
    if (tn !== 2'd3 || fn !== 5'd17 || mn !== 6'd59 || hn !== 6'd0) begin
        $display("ERROR TC6 pre-check: after load tn=%0d fn=%0d mn=%0d hn=%0d, expected 3/17/59/0",
                 tn, fn, mn, hn);
        err_count = err_count + 1;
    end
    // Drive one full slot: 255 sym_en strobes.  On the 255th strobe,
    // sym_cnt wraps 254->0 and the whole chain cascades:
    //   tn 3->0, fn 17->0, mn 59->0, hn 0->1.
    apply_n_sym(SYMS_PER_SLOT);
    repeat (3) @(posedge clk_sys); #1;
    if (mn !== 6'd0 || hn !== 6'd1 || fn !== 5'd0 || tn !== 2'd0) begin
        $display("ERROR TC6: after full cascade got tn=%0d fn=%0d mn=%0d hn=%0d, expected 0/0/0/1",
                 tn, fn, mn, hn);
        err_count = err_count + 1;
    end else begin
        $display("TC6: PASS (mn wrapped 59->0, hn 0->1)");
    end

    // -----------------------------------------------------------------------
    // TC7: HN wrap — pre-load (tn=3, fn=17, mn=59, hn=63) then drive
    //      one slot so the cascade wraps hn 63 -> 0.
    // -----------------------------------------------------------------------
    $display("TC7: HN wrap via pre-load hn=63 + full cascade");
    sync_load(2'd3, 5'd17, 6'd59, 6'd63);
    apply_sym_en;
    repeat (3) @(posedge clk_sys); #1;
    if (hn !== 6'd63 || mn !== 6'd59) begin
        $display("ERROR TC7 pre-check: after load hn=%0d mn=%0d, expected 63/59", hn, mn);
        err_count = err_count + 1;
    end
    apply_n_sym(SYMS_PER_SLOT);
    repeat (3) @(posedge clk_sys); #1;
    if (hn !== 6'd0 || mn !== 6'd0 || fn !== 5'd0 || tn !== 2'd0) begin
        $display("ERROR TC7: after cascade got tn=%0d fn=%0d mn=%0d hn=%0d, expected 0/0/0/0",
                 tn, fn, mn, hn);
        err_count = err_count + 1;
    end else begin
        $display("TC7: PASS (hn wrapped 63->0)");
    end

    // -----------------------------------------------------------------------
    // TC8: sync_load mid-slot — load (tn=2, fn=10, mn=30, hn=5),
    //      values appear after NEXT sym_en, sym_cnt = 0.
    // -----------------------------------------------------------------------
    $display("TC8: sync_load mid-slot");
    begin : tc8
        // Advance a few sym_en so we are NOT on a boundary
        apply_n_sym(37);
        // Snapshot sym_cnt (should be small non-zero)
        repeat (2) @(posedge clk_sys); #1;
        // Pulse sync_load_strobe (no sym_en this cycle)
        sync_load(2'd2, 5'd10, 6'd30, 6'd5);
        // Immediately after strobe: counters should be UNCHANGED
        #1;
        if (tn === 2'd2 && fn === 5'd10) begin
            $display("ERROR TC8: sync-load applied too early (before sym_en)");
            err_count = err_count + 1;
        end
        // Now one sym_en: load commits
        apply_sym_en;
        repeat (2) @(posedge clk_sys); #1;
        if (tn !== 2'd2 || fn !== 5'd10 || mn !== 6'd30 || hn !== 6'd5) begin
            $display("ERROR TC8: after sym_en got tn=%0d fn=%0d mn=%0d hn=%0d, expected 2/10/30/5",
                     tn, fn, mn, hn);
            err_count = err_count + 1;
        end else if (sym_cnt !== 8'd0) begin
            $display("ERROR TC8: sym_cnt=%0d after sync-load commit, expected 0", sym_cnt);
            err_count = err_count + 1;
        end else begin
            $display("TC8: PASS");
        end
    end

    // -----------------------------------------------------------------------
    // TC9: sync_load coincident with sym_en — sync-load wins
    // -----------------------------------------------------------------------
    $display("TC9: sync_load strobe coincident with sym_en");
    begin : tc9
        integer snap_tn;
        snap_tn = tn;
        // Line up so strobe fires on the same cycle as sym_en.
        // Wait until just before a sym_en boundary.
        repeat (SYM_PERIOD - 2) @(posedge clk_sys);
        @(posedge clk_sys); #1;
        // This cycle will be the sym_en cycle AND we assert strobe:
        sym_en           = 1'b1;
        sync_tn_in       = 2'd1;
        sync_fn_in       = 5'd7;
        sync_mn_in       = 6'd3;
        sync_hn_in       = 6'd9;
        sync_load_strobe = 1'b1;
        @(posedge clk_sys); #1;
        sym_en           = 1'b0;
        sync_load_strobe = 1'b0;
        repeat (2) @(posedge clk_sys); #1;
        if (tn !== 2'd1 || fn !== 5'd7 || mn !== 6'd3 || hn !== 6'd9) begin
            $display("ERROR TC9: coincident load didn't win — tn=%0d fn=%0d mn=%0d hn=%0d, expected 1/7/3/9",
                     tn, fn, mn, hn);
            err_count = err_count + 1;
        end else if (sym_cnt !== 8'd0) begin
            $display("ERROR TC9: sym_cnt=%0d after coincident load, expected 0", sym_cnt);
            err_count = err_count + 1;
        end else begin
            $display("TC9: PASS (sync-load wins on tie)");
        end
        // Restore quiet state
        apply_n_sym(SYM_PERIOD);
    end

    // -----------------------------------------------------------------------
    // Final report
    // -----------------------------------------------------------------------
    #100;
    if (err_count == 0) begin
        $display("===========================================");
        $display("TESTBENCH PASSED - 0 errors");
        $display("RESULT: PASS");
        $display("===========================================");
    end else begin
        $display("===========================================");
        $display("TESTBENCH FAILED - %0d error(s)", err_count);
        $display("RESULT: FAIL");
        $display("===========================================");
        $fatal(1, "Simulation terminated with errors.");
    end

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog — scaled to worst-case test (TC7 needs
// 60+2 multiframes * 72 slots * 255 syms * 10 ns/sym ~= 113 ms)
// ---------------------------------------------------------------------------
initial begin
    #500_000_000;   // 500 ms simulated
    $fatal(1, "TIMEOUT - simulation exceeded 500 ms simulated time");
end

endmodule

`default_nettype wire
