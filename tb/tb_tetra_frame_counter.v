// =============================================================================
// tb_tetra_frame_counter.v — Self-Checking Testbench
// =============================================================================
//
// Test cases:
//   TC1: Basic counter wrap — timeslot 0-3, frame 1-18
//   TC2: Multiframe wrap — multiframe 1-60 → 1
//   TC3: Hyperframe wrap — hyperframe_num increments
//   TC4: is_control_frame — active only during frame 18
//   TC5: frame_18_slot1 — fires exactly on timeslot 1 of frame 18
//   TC6: sync_locked low — counters reset mid-frame
//   TC7: Re-acquisition — counters restart cleanly after sync loss
//
// Timing: slot_pulse every SLOT_PERIOD cycles (fast for simulation).
//         Real hardware: ~1 415 000 cycles at 100 MHz (14.167 ms/timeslot).
//
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_frame_counter;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD   = 10;   // 10 ns → 100 MHz
localparam SLOT_PERIOD  = 20;   // slot_pulse every 20 cycles (fast sim)
localparam SLOTS_PER_FRAME      = 4;
localparam FRAMES_PER_MF        = 18;
localparam MF_PER_HF            = 60;
localparam SLOTS_PER_MF         = SLOTS_PER_FRAME * FRAMES_PER_MF;  // 72
localparam SLOTS_PER_HF         = SLOTS_PER_MF * MF_PER_HF;         // 4320

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg         clk_sample;
reg         rst_n_sample;
reg         sync_locked;
reg         slot_pulse;

wire [1:0]  timeslot_num;
wire [4:0]  frame_num;
wire [5:0]  multiframe_num;
wire [15:0] hyperframe_num;
wire        is_control_frame;
wire        frame_18_slot1;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_frame_counter dut (
    .clk_sample     (clk_sample),
    .rst_n_sample   (rst_n_sample),
    .sync_locked    (sync_locked),
    .slot_pulse     (slot_pulse),
    .timeslot_num   (timeslot_num),
    .frame_num      (frame_num),
    .multiframe_num (multiframe_num),
    .hyperframe_num (hyperframe_num),
    .is_control_frame (is_control_frame),
    .frame_18_slot1 (frame_18_slot1)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_frame_counter.vcd");
    $dumpvars(0, tb_tetra_frame_counter);
end

// ---------------------------------------------------------------------------
// Clock generation
// ---------------------------------------------------------------------------
initial clk_sample = 1'b0;
always #(CLK_PERIOD/2) clk_sample = ~clk_sample;

// ---------------------------------------------------------------------------
// Error counter
// ---------------------------------------------------------------------------
integer err_count;
initial err_count = 0;

// ---------------------------------------------------------------------------
// Task: apply one slot_pulse (one cycle wide)
// ---------------------------------------------------------------------------
task apply_slot_pulse;
    begin
        @(posedge clk_sample); #1;
        slot_pulse = 1'b1;
        @(posedge clk_sample); #1;
        slot_pulse = 1'b0;
        // Wait remainder of slot period
        repeat (SLOT_PERIOD - 2) @(posedge clk_sample);
    end
endtask

// ---------------------------------------------------------------------------
// Task: apply N slot_pulses
// ---------------------------------------------------------------------------
task apply_n_slots;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1)
            apply_slot_pulse;
    end
endtask

// ---------------------------------------------------------------------------
// Task: check counter values
// ---------------------------------------------------------------------------
task check_counters;
    input [1:0]  exp_ts;
    input [4:0]  exp_fn;
    input [5:0]  exp_mf;
    input [15:0] exp_hf;
    input [63:0] label;   // 8-char ASCII tag (packed)
    begin
        #1; // settle after posedge
        if (timeslot_num !== exp_ts) begin
            $error("[%s] timeslot_num: got %0d, expected %0d", label, timeslot_num, exp_ts);
            err_count = err_count + 1;
        end
        if (frame_num !== exp_fn) begin
            $error("[%s] frame_num: got %0d, expected %0d", label, frame_num, exp_fn);
            err_count = err_count + 1;
        end
        if (multiframe_num !== exp_mf) begin
            $error("[%s] multiframe_num: got %0d, expected %0d", label, multiframe_num, exp_mf);
            err_count = err_count + 1;
        end
        if (hyperframe_num !== exp_hf) begin
            $error("[%s] hyperframe_num: got %0d, expected %0d", label, hyperframe_num, exp_hf);
            err_count = err_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// TC1 & TC2 helper: drive N complete multiframes, check each frame boundary
// ---------------------------------------------------------------------------
// We verify:
//   - After ts3 of frame F, frame_num == F+1 (or 1 if F==18)
//   - After ts3 of frame 18, multiframe_num increments
//   - is_control_frame transitions at the right frame boundaries
// ---------------------------------------------------------------------------
integer slot_abs;      // absolute slot count since sync
integer ts_exp;        // expected timeslot_num (pre-increment = just completed)
integer fn_exp;        // expected frame_num
integer mf_exp;        // expected multiframe_num
integer hf_exp;        // expected hyperframe_num
integer f18s1_count;   // counts frame_18_slot1 pulses observed
reg     f18s1_seen;    // set when frame_18_slot1 detected this cycle

// Capture frame_18_slot1 asynchronously
always @(posedge clk_sample) begin
    if (frame_18_slot1)
        f18s1_count = f18s1_count + 1;
end

// ---------------------------------------------------------------------------
// Main test body
// ---------------------------------------------------------------------------
initial begin
    // -----------------------------------------------------------------------
    // Initialise
    // -----------------------------------------------------------------------
    rst_n_sample = 1'b0;
    sync_locked  = 1'b0;
    slot_pulse   = 1'b0;
    err_count    = 0;
    f18s1_count  = 0;

    repeat (4) @(posedge clk_sample);
    rst_n_sample = 1'b1;
    repeat (2) @(posedge clk_sample);

    // -----------------------------------------------------------------------
    // TC6: sync_locked LOW — counters must stay at reset values
    // -----------------------------------------------------------------------
    $display("TC6: sync_locked LOW reset check");
    apply_n_slots(8);
    @(posedge clk_sample); #1;
    if (timeslot_num !== 2'd0 || frame_num !== 5'd1 ||
        multiframe_num !== 6'd1 || hyperframe_num !== 16'd0) begin
        $error("TC6: counters non-zero with sync_locked=0 (ts=%0d fn=%0d mf=%0d hf=%0d)",
               timeslot_num, frame_num, multiframe_num, hyperframe_num);
        err_count = err_count + 1;
    end else
        $display("TC6: PASS — counters held at reset values");

    // -----------------------------------------------------------------------
    // Assert sync
    // -----------------------------------------------------------------------
    sync_locked = 1'b1;
    @(posedge clk_sample);

    // -----------------------------------------------------------------------
    // TC1: Timeslot counter — verify 0→1→2→3→0
    // -----------------------------------------------------------------------
    $display("TC1: timeslot_num wrap 0-3");
    begin : tc1
        integer i;
        integer prev_ts;
        prev_ts = timeslot_num;
        for (i = 0; i < 8; i = i + 1) begin
            apply_slot_pulse;
            @(posedge clk_sample); #1;
            if (timeslot_num !== ((prev_ts + 1) % 4)) begin
                $error("TC1[%0d]: timeslot_num: got %0d, expected %0d",
                       i, timeslot_num, (prev_ts + 1) % 4);
                err_count = err_count + 1;
            end
            prev_ts = timeslot_num;
        end
        $display("TC1: PASS");
    end

    // -----------------------------------------------------------------------
    // TC1/TC4: Frame counter + is_control_frame — drive 1 complete multiframe
    // -----------------------------------------------------------------------
    $display("TC1/TC4: frame_num and is_control_frame over 1 multiframe");
    begin : tc1_mf
        integer f, t;
        // Reset DUT cleanly: deassert sync, reapply
        sync_locked = 1'b0;
        repeat (3) @(posedge clk_sample);
        sync_locked = 1'b1;
        @(posedge clk_sample);

        for (f = 1; f <= FRAMES_PER_MF; f = f + 1) begin
            for (t = 0; t < SLOTS_PER_FRAME; t = t + 1) begin
                // Before the slot_pulse for timeslot t of frame f:
                // Expected state after this pulse:
                //   timeslot_num post-update = (t+1) mod 4
                //   frame_num: increments when t==3
                apply_slot_pulse;
                @(posedge clk_sample); #1;

                // timeslot_num should now be (t+1) mod 4
                if (timeslot_num !== ((t + 1) % 4)) begin
                    $error("TC1[f=%0d,t=%0d]: timeslot_num=%0d, expected %0d",
                           f, t, timeslot_num, (t + 1) % 4);
                    err_count = err_count + 1;
                end

                // frame_num increments on t==3: new frame = f+1 (or 1 if f==18)
                if (t == 3) begin
                    // Frame boundary: check new frame_num
                    if (f == FRAMES_PER_MF) begin
                        if (frame_num !== 5'd1) begin
                            $error("TC1[f=18,t=3]: frame_num=%0d, expected 1", frame_num);
                            err_count = err_count + 1;
                        end
                    end else begin
                        if (frame_num !== (f + 1)) begin
                            $error("TC1[f=%0d,t=3]: frame_num=%0d, expected %0d",
                                   f, frame_num, f + 1);
                            err_count = err_count + 1;
                        end
                    end

                    // is_control_frame: HIGH when entering frame 18
                    if (f == 17) begin
                        if (!is_control_frame) begin
                            $error("TC4[f=17,t=3]: is_control_frame should be HIGH (entering f18)");
                            err_count = err_count + 1;
                        end
                    end else if (f == 18) begin
                        if (is_control_frame) begin
                            $error("TC4[f=18,t=3]: is_control_frame should be LOW (leaving f18)");
                            err_count = err_count + 1;
                        end
                    end
                end else begin
                    // Mid-frame: frame_num should be unchanged (still f)
                    if (frame_num !== f) begin
                        $error("TC1[f=%0d,t=%0d]: frame_num=%0d, expected %0d",
                               f, t, frame_num, f);
                        err_count = err_count + 1;
                    end
                end

                // is_control_frame inside frame 18 (slots 0,1,2,3 during reception)
                // After ts3/f17 edge, is_control_frame=1; stays until ts3/f18 edge
                if (f == 18 && t < 3) begin
                    if (!is_control_frame) begin
                        $error("TC4[f=18,t=%0d]: is_control_frame should be HIGH", t);
                        err_count = err_count + 1;
                    end
                end
            end // timeslot loop
        end // frame loop
        $display("TC1/TC4: PASS");
    end

    // -----------------------------------------------------------------------
    // TC2: Multiframe wrap 1→60→1
    // -----------------------------------------------------------------------
    $display("TC2: multiframe_num wrap 1-60");
    begin : tc2
        integer mf;
        // DUT is at: frame_num=1, multiframe_num=2 (TC1/TC4 drove exactly 1 multiframe)
        // Drive 59 more multiframes (mf 2→3→...→60→1), checking at each boundary.
        // Loop variable mf = expected multiframe_num AFTER each apply_n_slots call.
        for (mf = 3; mf <= MF_PER_HF + 1; mf = mf + 1) begin
            apply_n_slots(SLOTS_PER_MF);
            @(posedge clk_sample); #1;
            if (mf <= MF_PER_HF) begin
                if (multiframe_num !== mf) begin
                    $error("TC2: multiframe_num=%0d, expected %0d", multiframe_num, mf);
                    err_count = err_count + 1;
                end
            end else begin
                // mf == MF_PER_HF + 1: mf60 just completed, wraps back to 1
                if (multiframe_num !== 6'd1) begin
                    $error("TC2: multiframe_num=%0d, expected 1 (after mf60 wrap)", multiframe_num);
                    err_count = err_count + 1;
                end
            end
        end
        $display("TC2: PASS (drove %0d multiframes)", MF_PER_HF);
    end

    // -----------------------------------------------------------------------
    // TC3: Hyperframe increment — drive 1 more hyperframe (60 more mfs)
    // -----------------------------------------------------------------------
    $display("TC3: hyperframe_num increment");
    begin : tc3
        @(posedge clk_sample); #1;
        if (hyperframe_num !== 16'd1) begin
            $error("TC3: hyperframe_num=%0d, expected 1 after first hyperframe", hyperframe_num);
            err_count = err_count + 1;
        end else
            $display("TC3: PASS — hyperframe_num == 1");
    end

    // -----------------------------------------------------------------------
    // TC5: frame_18_slot1 — verify exactly one pulse per multiframe,
    //      at the correct position
    // -----------------------------------------------------------------------
    $display("TC5: frame_18_slot1 pulse check");
    begin : tc5
        integer f18s1_before;
        // Drive one full multiframe from current position
        f18s1_before = f18s1_count;
        apply_n_slots(SLOTS_PER_MF);
        @(posedge clk_sample); #1;
        if ((f18s1_count - f18s1_before) !== 1) begin
            $error("TC5: frame_18_slot1 fired %0d times in 1 multiframe, expected 1",
                   f18s1_count - f18s1_before);
            err_count = err_count + 1;
        end else
            $display("TC5: PASS — frame_18_slot1 fired exactly once per multiframe");
    end

    // -----------------------------------------------------------------------
    // TC5b: frame_18_slot1 position — must fire exactly 1 cycle after
    //       the slot_pulse for ts1 of frame 18
    // -----------------------------------------------------------------------
    $display("TC5b: frame_18_slot1 timing position");
    begin : tc5b
        integer f, t;
        reg saw_pulse;
        reg saw_on_wrong_slot;
        saw_pulse         = 1'b0;
        saw_on_wrong_slot = 1'b0;

        // Bring counters to a known state: reset sync
        sync_locked = 1'b0;
        repeat (3) @(posedge clk_sample);
        sync_locked = 1'b1;
        @(posedge clk_sample);

        // Drive up to frame 18 slot 1
        // Frames 1-17: 17*4 = 68 slots; then 2 more slots (ts0, ts1 of f18)
        apply_n_slots(17 * 4);  // end of frame 17
        // Now drive ts0 of frame 18
        apply_slot_pulse;
        // Now drive ts1 of frame 18 — frame_18_slot1 should fire 1 cycle after
        @(posedge clk_sample); #1;
        slot_pulse = 1'b1;
        @(posedge clk_sample); #1;
        slot_pulse = 1'b0;
        // Check: frame_18_slot1 should be HIGH now (1 cycle after slot_pulse posedge)
        if (!frame_18_slot1) begin
            $error("TC5b: frame_18_slot1 not HIGH one cycle after ts1/f18 slot_pulse");
            err_count = err_count + 1;
        end
        // Next cycle: frame_18_slot1 should deassert
        @(posedge clk_sample); #1;
        if (frame_18_slot1) begin
            $error("TC5b: frame_18_slot1 still HIGH two cycles after slot_pulse (not a pulse)");
            err_count = err_count + 1;
        end
        if (err_count == 0) $display("TC5b: PASS");
    end

    // -----------------------------------------------------------------------
    // TC6b: sync_locked deassertion mid-frame resets all counters
    // -----------------------------------------------------------------------
    $display("TC6b: sync_locked mid-frame reset");
    begin : tc6b
        // Advance a few slots into frame 3 of multiframe 1
        sync_locked = 1'b0;
        repeat (3) @(posedge clk_sample);
        sync_locked = 1'b1;
        @(posedge clk_sample);
        apply_n_slots(10);  // put counters at non-trivial values
        sync_locked = 1'b0;
        @(posedge clk_sample); #1;
        // All counters must be at reset values
        if (timeslot_num !== 2'd0 || frame_num !== 5'd1 ||
            multiframe_num !== 6'd1 || is_control_frame !== 1'b0 ||
            frame_18_slot1 !== 1'b0) begin
            $error("TC6b: counters not reset on sync_locked=0 (ts=%0d fn=%0d mf=%0d icf=%b f18s1=%b)",
                   timeslot_num, frame_num, multiframe_num, is_control_frame, frame_18_slot1);
            err_count = err_count + 1;
        end else
            $display("TC6b: PASS — counters cleared on sync loss");
        // hyperframe_num also cleared
        if (hyperframe_num !== 16'd0) begin
            $error("TC6b: hyperframe_num=%0d, expected 0 on sync loss", hyperframe_num);
            err_count = err_count + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC7: Re-acquisition after sync loss
    // -----------------------------------------------------------------------
    $display("TC7: re-acquisition after sync loss");
    begin : tc7
        sync_locked = 1'b1;
        @(posedge clk_sample);
        apply_n_slots(4);  // drive 1 complete frame
        @(posedge clk_sample); #1;
        if (frame_num !== 5'd2) begin
            $error("TC7: frame_num=%0d, expected 2 after 1 frame", frame_num);
            err_count = err_count + 1;
        end else
            $display("TC7: PASS — clean restart after re-acquisition");
    end

    // -----------------------------------------------------------------------
    // Final report
    // -----------------------------------------------------------------------
    #100;
    if (err_count == 0) begin
        $display("===========================================");
        $display("TESTBENCH PASSED — 0 errors");
        $display("===========================================");
    end else begin
        $display("===========================================");
        $display("TESTBENCH FAILED — %0d error(s)", err_count);
        $display("===========================================");
        $fatal(1, "Simulation terminated with errors.");
    end

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #50_000_000;
    $fatal(1, "TIMEOUT — simulation exceeded 50 ms simulated time");
end

endmodule

`default_nettype wire
