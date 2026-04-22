// =============================================================================
// tb_tetra_slot_content_mux.v — Self-Checking Testbench (Plan Stufe 4)
// DUT : tetra_slot_content_mux  + tetra_slot_schedule (dual-port BRAM)
// =============================================================================
//
// Stimulus loads the schedule BRAM via its AXI port, drives the TDMA
// timebase-facing inputs (tn/fn/mn + slot_pulse), and checks:
//   TC1: Reset state — all content_mux outputs are 0 after reset
//        (before any schedule refresh).
//   TC2: Gold-preset — load the 288-entry gold schedule, step through a
//        full frame (tn=0..3 + slot_pulse + wait for refresh), and verify
//        slot_burst_type_sys / slot_en_sys / slot_ndb2_sys match the
//        expected gold pattern for the NEXT frame's (mn', fn').  Sweep
//        (mn, fn) over a few representative points including fn=17
//        (next-frame wrap).
//   TC3: NULL-PDU routing — set up a schedule entry at (mn=1, fn=5) with
//        class=NULL_PDU idx=0 ndb2=1 enable=1.  Load a distinct
//        null_pdu_bits_sys pattern.  Step into the (1,5) frame and
//        verify tx_blk1_slot0 == null_pdu_bits_sys and tx_blk2_slot0 ==
//        ndb_block2_sw_sys.
//   TC4: SDB blk2 routing — schedule entry class=BROADCAST idx=3 (SB) at
//        (mn=0, fn=0, tn=2).  Load distinct sb_bkn2_sw_sys.  Verify
//        burst_type[2] == 1 (SDB) and tx_blk2_slot2 == sb_bkn2_sw_sys
//        and tx_blk1_slot2 == 0.
//   TC5: sb_bb / sb_sb1 passthrough — drive sb1_coded_sys and
//        aach_coded_sys with distinct patterns; verify sb_sb1_data_sys /
//        sb_bb_data_sys mirror them one cycle later (registered).
//   TC6: 4-TN sweep — load 4 distinct schedule entries at (mn=0, fn=0,
//        tn=0..3) with different payload classes and verify each per-TN
//        output (burst_type, enable, ndb2, blk1/blk2) after refresh.
//
// Timing model:
//   clk_sys at 100 MHz (10 ns).  slot_pulse_sys fires for 1 cycle to
//   trigger refresh; content_mux FSM then sequences 4 BRAM reads (5-6
//   cycles total including BRAM latency) and latches all 4 entries.
//   Outputs are registered, so the TB should wait ~8 cycles after the
//   slot_pulse before sampling outputs.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_tetra_slot_content_mux;

localparam CLK_PERIOD = 10;
localparam BLOCK_BITS = 216;
localparam BB_BITS    = 30;
localparam SB1_BITS   = 120;

reg clk;
reg rst_n;
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// Schedule BRAM interface (AXI side + Port B from content_mux)
// ---------------------------------------------------------------------------
reg         axi_we;
reg  [7:0]  axi_addr;
reg  [31:0] axi_wdata;
reg  [3:0]  axi_wstrb;
reg         axi_re;
wire [31:0] axi_rdata;

wire [8:0]  sched_addr_sys;
wire [15:0] sched_data_sys;

tetra_slot_schedule u_sched (
    .clk_axi            (clk),
    .rst_n_axi          (rst_n),
    .axi_we             (axi_we),
    .axi_addr           (axi_addr),
    .axi_wdata          (axi_wdata),
    .axi_wstrb          (axi_wstrb),
    .axi_re             (axi_re),
    .axi_rdata          (axi_rdata),
    .clk_sys            (clk),
    .rst_n_sys          (rst_n),
    .sched_b_addr_sys   (sched_addr_sys),
    .schedule_entry_sys (sched_data_sys)
);

// ---------------------------------------------------------------------------
// content_mux DUT
// ---------------------------------------------------------------------------
reg  [1:0]             tn_sys;
reg  [4:0]             fn_sys;
reg  [5:0]             mn_sys;
reg                    slot_pulse_sys;
reg                    tdma_tick_sys;

reg  [SB1_BITS-1:0]    sb1_coded_sys;
reg                    sb1_valid_sys;
reg  [BB_BITS-1:0]     aach_coded_sys;
reg                    aach_valid_sys;

reg  [BLOCK_BITS-1:0]  ndb_block1_sw_sys;
reg  [BLOCK_BITS-1:0]  ndb_block2_sw_sys;
reg  [BLOCK_BITS-1:0]  mcch_block1_sw_sys;
reg  [BLOCK_BITS-1:0]  mcch_block2_sw_sys;
reg  [BLOCK_BITS-1:0]  bnch_block1_sw_sys;
reg  [BLOCK_BITS-1:0]  bnch_block2_sw_sys;
reg  [BLOCK_BITS-1:0]  sb_bkn2_sw_sys;
reg  [BLOCK_BITS-1:0]  null_pdu_bits_sys;

wire [3:0]             slot_burst_type_sys;
wire [3:0]             slot_en_sys;
wire [3:0]             slot_ndb2_sys;
wire [BLOCK_BITS-1:0]  tx_blk1_slot0_sys;
wire [BLOCK_BITS-1:0]  tx_blk1_slot1_sys;
wire [BLOCK_BITS-1:0]  tx_blk1_slot2_sys;
wire [BLOCK_BITS-1:0]  tx_blk1_slot3_sys;
wire [BLOCK_BITS-1:0]  tx_blk2_slot0_sys;
wire [BLOCK_BITS-1:0]  tx_blk2_slot1_sys;
wire [BLOCK_BITS-1:0]  tx_blk2_slot2_sys;
wire [BLOCK_BITS-1:0]  tx_blk2_slot3_sys;
wire [SB1_BITS-1:0]    sb_sb1_data_sys;
wire [BB_BITS-1:0]     sb_bb_data_sys;

wire [15:0] dbg_sched_entry0_sys;
wire [15:0] dbg_sched_entry1_sys;
wire [15:0] dbg_sched_entry2_sys;
wire [15:0] dbg_sched_entry3_sys;

tetra_slot_content_mux #(
    .BLOCK_BITS(BLOCK_BITS),
    .BB_BITS   (BB_BITS),
    .SB1_BITS  (SB1_BITS)
) u_dut (
    .clk_sys              (clk),
    .rst_n_sys            (rst_n),
    .tn_sys               (tn_sys),
    .fn_sys               (fn_sys),
    .mn_sys               (mn_sys),
    .slot_pulse_sys       (slot_pulse_sys),
    .tdma_tick_sys        (tdma_tick_sys),
    .sched_addr_sys       (sched_addr_sys),
    .sched_data_sys       (sched_data_sys),
    .sb1_coded_sys        (sb1_coded_sys),
    .sb1_valid_sys        (sb1_valid_sys),
    .aach_coded_sys       (aach_coded_sys),
    .aach_valid_sys       (aach_valid_sys),
    .ndb_block1_sw_sys    (ndb_block1_sw_sys),
    .ndb_block2_sw_sys    (ndb_block2_sw_sys),
    .mcch_block1_sw_sys   (mcch_block1_sw_sys),
    .mcch_block2_sw_sys   (mcch_block2_sw_sys),
    .bnch_block1_sw_sys   (bnch_block1_sw_sys),
    .bnch_block2_sw_sys   (bnch_block2_sw_sys),
    .sb_bkn2_sw_sys       (sb_bkn2_sw_sys),
    .null_pdu_bits_sys    (null_pdu_bits_sys),
    .dl_signal_bits_sys   ({BLOCK_BITS{1'b0}}),
    .dl_signal_valid_sys  (1'b0),
    .dl_signal_pending_sys(),
    .slot_burst_type_sys  (slot_burst_type_sys),
    .slot_en_sys          (slot_en_sys),
    .slot_ndb2_sys        (slot_ndb2_sys),
    .tx_blk1_slot0_sys    (tx_blk1_slot0_sys),
    .tx_blk1_slot1_sys    (tx_blk1_slot1_sys),
    .tx_blk1_slot2_sys    (tx_blk1_slot2_sys),
    .tx_blk1_slot3_sys    (tx_blk1_slot3_sys),
    .tx_blk2_slot0_sys    (tx_blk2_slot0_sys),
    .tx_blk2_slot1_sys    (tx_blk2_slot1_sys),
    .tx_blk2_slot2_sys    (tx_blk2_slot2_sys),
    .tx_blk2_slot3_sys    (tx_blk2_slot3_sys),
    .sb_sb1_data_sys      (sb_sb1_data_sys),
    .sb_bb_data_sys       (sb_bb_data_sys),
    .dbg_sched_entry0_sys (dbg_sched_entry0_sys),
    .dbg_sched_entry1_sys (dbg_sched_entry1_sys),
    .dbg_sched_entry2_sys (dbg_sched_entry2_sys),
    .dbg_sched_entry3_sys (dbg_sched_entry3_sys)
);

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim_out/tb_tetra_slot_content_mux.vcd");
    $dumpvars(0, tb_tetra_slot_content_mux);
end

// ---------------------------------------------------------------------------
// Helpers — dense entry mapping matches scripts/gold_schedule.py
// ---------------------------------------------------------------------------
function [8:0] entry_addr;
    input [1:0] mn;
    input [4:0] fn;
    input [1:0] tn;
    begin
        entry_addr = mn * 9'd72 + {2'b0, fn, 2'b0} + {7'b0, tn};
    end
endfunction

function [7:0] word_idx;
    input [1:0] mn;
    input [4:0] fn;
    input [1:0] tn;
    reg [8:0] ea;
    begin
        ea = entry_addr(mn, fn, tn);
        word_idx = ea[8:1];
    end
endfunction

function is_upper_half;
    input [1:0] mn;
    input [4:0] fn;
    input [1:0] tn;
    reg [8:0] ea;
    begin
        ea = entry_addr(mn, fn, tn);
        is_upper_half = ea[0];
    end
endfunction

function [15:0] pack_entry;
    input [3:0] cls;
    input [5:0] idx;
    input [1:0] bt;
    input       ndb2;
    input       en;
    input       sti;
    begin
        pack_entry = {cls, idx, bt, ndb2, en, sti, 1'b0};
    end
endfunction

function [15:0] gold_entry;
    input [1:0] mn;
    input [4:0] fn;
    input [1:0] tn;
    reg [3:0]  cls;
    reg [5:0]  idx;
    reg [1:0]  bt;
    reg        ndb2;
    reg        en;
    reg        sti;
    begin
        cls  = 4'd0; idx  = 6'd0; bt = 2'b00;
        ndb2 = 1'b0; en = 1'b1; sti = 1'b0;
        if (tn != 2'd0) begin
            cls = 4'd0; idx = 6'd3; bt = 2'b01;
            ndb2 = 1'b0; en = 1'b1; sti = 1'b1;
        end else begin
            if (fn == 5'd17 && mn == 2'd2) begin
                cls = 4'd0; idx = 6'd3; bt = 2'b01;
                ndb2 = 1'b0; en = 1'b1; sti = 1'b1;
            end else if (fn == 5'd17) begin
                cls = 4'd0; idx = 6'd1; bt = 2'b01;
                ndb2 = 1'b0; en = 1'b1; sti = 1'b0;
            end else if (mn == 2'd0) begin
                cls = 4'd0; idx = 6'd0; bt = 2'b00;
                ndb2 = 1'b0; en = 1'b1; sti = 1'b0;
            end else begin
                cls = 4'd1; idx = 6'd0; bt = 2'b00;
                ndb2 = 1'b0; en = 1'b1; sti = 1'b0;
            end
        end
        gold_entry = pack_entry(cls, idx, bt, ndb2, en, sti);
    end
endfunction

// Unpacking helpers for expected-signal computation
function exp_is_sdb;    input [15:0] e; begin exp_is_sdb    = (e[5:4] == 2'b01); end endfunction
function exp_is_enable; input [15:0] e; begin exp_is_enable = e[2];              end endfunction
function exp_is_ndb2;   input [15:0] e; begin exp_is_ndb2  = e[3];              end endfunction

// ---------------------------------------------------------------------------
// AXI write task — single-cycle pulse
// ---------------------------------------------------------------------------
task axi_write_word;
    input [7:0]  addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
        @(posedge clk); #1;
        axi_addr  = addr;
        axi_wdata = data;
        axi_wstrb = strb;
        axi_we    = 1'b1;
        @(posedge clk); #1;
        axi_we    = 1'b0;
        axi_wstrb = 4'h0;
    end
endtask

// Write a single 16-bit entry, RMW via internal exp_mem[] mirror
reg [15:0] exp_mem [0:287];
task axi_write_entry;
    input [1:0]  mn;
    input [4:0]  fn;
    input [1:0]  tn;
    input [15:0] value;
    reg   [7:0]  wi;
    reg   [8:0]  ea_lo, ea_hi;
    reg   [31:0] word_value;
    begin
        wi = word_idx(mn, fn, tn);
        ea_lo = {wi, 1'b0};
        ea_hi = {wi, 1'b1};
        if (is_upper_half(mn, fn, tn)) begin
            word_value = {value, exp_mem[ea_lo]};
        end else begin
            word_value = {exp_mem[ea_hi], value};
        end
        axi_write_word(wi, word_value, 4'hF);
        exp_mem[entry_addr(mn, fn, tn)] = value;
    end
endtask

// Gold schedule preset load
task load_gold_schedule;
    integer mn_e, fn_e, tn_e, mn_o, fn_o, tn_o;
    reg [15:0] v_even, v_odd;
    reg [8:0] ea_even, ea_odd;
    integer wi;
    begin
        for (wi = 0; wi < 144; wi = wi + 1) begin
            ea_even = (wi << 1);
            ea_odd  = (wi << 1) + 9'd1;
            mn_e = ea_even / 72;
            fn_e = (ea_even - mn_e * 72) / 4;
            tn_e = ea_even - mn_e * 72 - fn_e * 4;
            mn_o = ea_odd / 72;
            fn_o = (ea_odd - mn_o * 72) / 4;
            tn_o = ea_odd - mn_o * 72 - fn_o * 4;
            v_even = gold_entry(mn_e[1:0], fn_e[4:0], tn_e[1:0]);
            v_odd  = gold_entry(mn_o[1:0], fn_o[4:0], tn_o[1:0]);
            axi_write_word(wi[7:0], {v_odd, v_even}, 4'hF);
            exp_mem[ea_even] = v_even;
            exp_mem[ea_odd]  = v_odd;
        end
    end
endtask

// Fire a slot_pulse_sys with the given (tn, fn, mn); wait for refresh
// FSM to complete (8 cycles is plenty: S_IDLE -> S_RD0 -> S_RD1 -> S_RD2
// -> S_RD3 -> S_CAP3 -> output register update).
task fire_slot_pulse;
    input [1:0] tn;
    input [4:0] fn;
    input [5:0] mn;
    integer     w;
    begin
        @(posedge clk); #1;
        tn_sys = tn;
        fn_sys = fn;
        mn_sys = mn;
        slot_pulse_sys = 1'b1;
        @(posedge clk); #1;
        slot_pulse_sys = 1'b0;
        // Wait 10 cycles for FSM + output register settling
        for (w = 0; w < 10; w = w + 1) @(posedge clk);
        #1;
    end
endtask

integer init_i;
initial begin
    for (init_i = 0; init_i < 288; init_i = init_i + 1)
        exp_mem[init_i] = 16'h0000;
end

// ---------------------------------------------------------------------------
// Main stimulus
// ---------------------------------------------------------------------------
integer pass_cnt;
integer fail_cnt;
reg [15:0] exp_e0, exp_e1, exp_e2, exp_e3;

// Expected fresh-frame (mn', fn') pair after a slot_pulse on (tn==3, fn, mn):
//   fn' = (fn==17) ? 0 : fn+1; mn'[1:0] = (fn==17) ? mn[1:0]+1 : mn[1:0].
// For the first_refresh path (post-reset), refresh targets the CURRENT
// (mn, fn) of the slot_pulse — this test exercises that path in TC2's
// first kick.
function [4:0] fn_next;
    input [4:0] fn;
    begin
        fn_next = (fn == 5'd17) ? 5'd0 : (fn + 5'd1);
    end
endfunction

function [1:0] mn_next_low2;
    input [1:0] mn_low2;
    input [4:0] fn;
    begin
        mn_next_low2 = (fn == 5'd17) ? (mn_low2 + 2'd1) : mn_low2;
    end
endfunction

initial begin
    // Defaults
    axi_we     = 1'b0;
    axi_addr   = 8'h00;
    axi_wdata  = 32'h0;
    axi_wstrb  = 4'h0;
    axi_re     = 1'b0;
    tn_sys     = 2'd0;
    fn_sys     = 5'd0;
    mn_sys     = 6'd0;
    slot_pulse_sys = 1'b0;
    tdma_tick_sys  = 1'b0;
    sb1_coded_sys  = 120'h0;
    sb1_valid_sys  = 1'b0;
    aach_coded_sys = 30'h0;
    aach_valid_sys = 1'b0;
    ndb_block1_sw_sys  = {BLOCK_BITS{1'b0}};
    ndb_block2_sw_sys  = {BLOCK_BITS{1'b0}};
    mcch_block1_sw_sys = {BLOCK_BITS{1'b0}};
    mcch_block2_sw_sys = {BLOCK_BITS{1'b0}};
    bnch_block1_sw_sys = {BLOCK_BITS{1'b0}};
    bnch_block2_sw_sys = {BLOCK_BITS{1'b0}};
    sb_bkn2_sw_sys     = {BLOCK_BITS{1'b0}};
    null_pdu_bits_sys  = {BLOCK_BITS{1'b0}};

    pass_cnt = 0;
    fail_cnt = 0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // -----------------------------------------------------------------------
    // TC1: Reset state — before any slot_pulse, all outputs should be 0.
    // -----------------------------------------------------------------------
    begin : tc1
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys !== 4'b0) ok = 1'b0;
        if (slot_en_sys         !== 4'b0) ok = 1'b0;
        if (slot_ndb2_sys       !== 4'b0) ok = 1'b0;
        if (tx_blk1_slot0_sys   !== {BLOCK_BITS{1'b0}}) ok = 1'b0;
        if (tx_blk2_slot3_sys   !== {BLOCK_BITS{1'b0}}) ok = 1'b0;
        if (sb_sb1_data_sys     !== {SB1_BITS{1'b0}})  ok = 1'b0;
        if (sb_bb_data_sys      !== {BB_BITS{1'b0}})   ok = 1'b0;
        if (ok) begin
            $display("PASS TC1: reset state — all outputs 0");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC1: reset-state non-zero outputs (bt=%b en=%b ndb2=%b)",
                     slot_burst_type_sys, slot_en_sys, slot_ndb2_sys);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC2: Gold-preset — load schedule, fire slot_pulse with (tn=3, mn=0,
    // fn=0) to trigger a refresh for the NEXT frame (mn=0, fn=1).  Verify
    // the 4 captured entries match gold_entry(0, 1, 0..3).
    // Note: Uses first_refresh_pending path the first time — that targets
    // (mn=0, fn=0, tn=0..3) since tn_sys@trigger = 3 but first_refresh
    // forces CURRENT-frame target.  So the first slot_pulse loads (0,0,*).
    // We then fire a SECOND pulse (tn=3, mn=0, fn=0) which is a normal
    // refresh targeting (0, 1, *).
    // -----------------------------------------------------------------------
    load_gold_schedule();

    // First pulse — first_refresh path, loads (mn=0, fn=0, tn=0..3)
    fire_slot_pulse(2'd3, 5'd0, 6'd0);
    exp_e0 = gold_entry(2'd0, 5'd0, 2'd0);
    exp_e1 = gold_entry(2'd0, 5'd0, 2'd1);
    exp_e2 = gold_entry(2'd0, 5'd0, 2'd2);
    exp_e3 = gold_entry(2'd0, 5'd0, 2'd3);
    begin : tc2_check_first
        reg ok;
        ok = 1'b1;
        if (dbg_sched_entry0_sys !== exp_e0) ok = 1'b0;
        if (dbg_sched_entry1_sys !== exp_e1) ok = 1'b0;
        if (dbg_sched_entry2_sys !== exp_e2) ok = 1'b0;
        if (dbg_sched_entry3_sys !== exp_e3) ok = 1'b0;
        if (slot_burst_type_sys !== {exp_is_sdb(exp_e3),exp_is_sdb(exp_e2),
                                      exp_is_sdb(exp_e1),exp_is_sdb(exp_e0)}) ok = 1'b0;
        if (slot_en_sys !== {exp_is_enable(exp_e3),exp_is_enable(exp_e2),
                              exp_is_enable(exp_e1),exp_is_enable(exp_e0)}) ok = 1'b0;
        if (slot_ndb2_sys !== {exp_is_ndb2(exp_e3),exp_is_ndb2(exp_e2),
                                exp_is_ndb2(exp_e1),exp_is_ndb2(exp_e0)}) ok = 1'b0;
        if (ok) begin
            $display("PASS TC2a: first_refresh loads (mn=0,fn=0,*) — entries %h %h %h %h",
                     exp_e0, exp_e1, exp_e2, exp_e3);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC2a: first_refresh mismatch");
            $display("  got  %h %h %h %h", dbg_sched_entry0_sys, dbg_sched_entry1_sys,
                                            dbg_sched_entry2_sys, dbg_sched_entry3_sys);
            $display("  exp  %h %h %h %h", exp_e0, exp_e1, exp_e2, exp_e3);
            $display("  bt=%b en=%b ndb2=%b", slot_burst_type_sys, slot_en_sys, slot_ndb2_sys);
            fail_cnt = fail_cnt + 1;
        end
    end

    // Second pulse — normal refresh from (tn=3, fn=0, mn=0) targets (0,1,*)
    fire_slot_pulse(2'd3, 5'd0, 6'd0);
    exp_e0 = gold_entry(2'd0, 5'd1, 2'd0);
    exp_e1 = gold_entry(2'd0, 5'd1, 2'd1);
    exp_e2 = gold_entry(2'd0, 5'd1, 2'd2);
    exp_e3 = gold_entry(2'd0, 5'd1, 2'd3);
    begin : tc2_check_next
        reg ok;
        ok = 1'b1;
        if (dbg_sched_entry0_sys !== exp_e0) ok = 1'b0;
        if (dbg_sched_entry1_sys !== exp_e1) ok = 1'b0;
        if (dbg_sched_entry2_sys !== exp_e2) ok = 1'b0;
        if (dbg_sched_entry3_sys !== exp_e3) ok = 1'b0;
        if (ok) begin
            $display("PASS TC2b: next-frame refresh loads (mn=0,fn=1,*)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC2b: next-frame refresh mismatch");
            $display("  got  %h %h %h %h", dbg_sched_entry0_sys, dbg_sched_entry1_sys,
                                            dbg_sched_entry2_sys, dbg_sched_entry3_sys);
            $display("  exp  %h %h %h %h", exp_e0, exp_e1, exp_e2, exp_e3);
            fail_cnt = fail_cnt + 1;
        end
    end

    // Third test: fn-wrap at fn=17 (tn=3 trigger targets next mn, fn=0)
    fire_slot_pulse(2'd3, 5'd17, 6'd0);
    exp_e0 = gold_entry(2'd1, 5'd0, 2'd0);
    exp_e1 = gold_entry(2'd1, 5'd0, 2'd1);
    exp_e2 = gold_entry(2'd1, 5'd0, 2'd2);
    exp_e3 = gold_entry(2'd1, 5'd0, 2'd3);
    begin : tc2_check_wrap
        reg ok;
        ok = 1'b1;
        if (dbg_sched_entry0_sys !== exp_e0) ok = 1'b0;
        if (dbg_sched_entry1_sys !== exp_e1) ok = 1'b0;
        if (dbg_sched_entry2_sys !== exp_e2) ok = 1'b0;
        if (dbg_sched_entry3_sys !== exp_e3) ok = 1'b0;
        if (ok) begin
            $display("PASS TC2c: fn-wrap refresh loads (mn=1,fn=0,*)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC2c: fn-wrap refresh mismatch");
            $display("  got  %h %h %h %h", dbg_sched_entry0_sys, dbg_sched_entry1_sys,
                                            dbg_sched_entry2_sys, dbg_sched_entry3_sys);
            $display("  exp  %h %h %h %h", exp_e0, exp_e1, exp_e2, exp_e3);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC3: NULL-PDU routing.  Program entry at (mn=1, fn=5, tn=0) as
    // class=NULL_PDU(1) idx=0 burst_type=NDB(00) ndb2=1 enable=1.  Load
    // null_pdu_bits_sys with a distinct pattern, and fire the refresh.
    // Verify tx_blk1_slot0_sys == null_pdu_bits_sys, tx_blk2_slot0 ==
    // ndb_block2_sw_sys, burst_type[0]=0, ndb2[0]=1, enable[0]=1.
    // -----------------------------------------------------------------------
    // Clear TN=1..3 entries at (mn=1, fn=5) to NULL_PDU too, so we don't
    // accidentally hit SB-class and mess up blk2.
    axi_write_entry(2'd1, 5'd5, 2'd0, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd1, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd2, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd3, pack_entry(4'd1, 6'd0, 2'b00, 1'b1, 1'b1, 1'b0));

    null_pdu_bits_sys = {BLOCK_BITS{1'b0}};
    null_pdu_bits_sys[215:208] = 8'hA5;
    null_pdu_bits_sys[7:0]     = 8'h5A;
    ndb_block2_sw_sys = {BLOCK_BITS{1'b0}};
    ndb_block2_sw_sys[215:208] = 8'h3C;

    // Trigger a refresh targeting (mn=1, fn=5, tn=0..3).  Use slot_pulse
    // with tn=3, mn=1, fn=4 so fn_next=5.
    fire_slot_pulse(2'd3, 5'd4, 6'd1);
    begin : tc3
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys !== 4'b0000) ok = 1'b0;     // all NDB
        if (slot_en_sys         !== 4'b1111) ok = 1'b0;     // all enabled
        if (slot_ndb2_sys       !== 4'b1111) ok = 1'b0;     // all ndb2=1
        if (tx_blk1_slot0_sys   !== null_pdu_bits_sys) ok = 1'b0;
        if (tx_blk1_slot3_sys   !== null_pdu_bits_sys) ok = 1'b0;
        if (tx_blk2_slot0_sys   !== ndb_block2_sw_sys) ok = 1'b0;
        if (tx_blk2_slot2_sys   !== ndb_block2_sw_sys) ok = 1'b0;
        if (ok) begin
            $display("PASS TC3: NULL_PDU routed to all 4 slots (blk1=null, blk2=ndb_block2)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC3: NULL_PDU routing mismatch");
            $display("  bt=%b en=%b ndb2=%b", slot_burst_type_sys, slot_en_sys, slot_ndb2_sys);
            $display("  blk1_slot0[215:208]=%h exp %h",
                     tx_blk1_slot0_sys[215:208], null_pdu_bits_sys[215:208]);
            $display("  blk2_slot0[215:208]=%h exp %h",
                     tx_blk2_slot0_sys[215:208], ndb_block2_sw_sys[215:208]);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC4: SDB blk2 routing.  Program (mn=2, fn=5, tn=2) as
    // class=BROADCAST(0) idx=3 (SB) burst_type=SDB(01) ndb2=0 enable=1.
    // Other slots of this frame: set NDB SYSINFO so they are distinguishable.
    // Load sb_bkn2_sw_sys with distinct pattern.  Verify:
    //   slot_burst_type_sys[2] == 1 (SDB)
    //   tx_blk1_slot2_sys == 0
    //   tx_blk2_slot2_sys == sb_bkn2_sw_sys
    // -----------------------------------------------------------------------
    axi_write_entry(2'd2, 5'd5, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0)); // NDB SYSINFO
    axi_write_entry(2'd2, 5'd5, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd2, 5'd5, 2'd2, pack_entry(4'd0, 6'd3, 2'b01, 1'b0, 1'b1, 1'b1)); // SB SDB
    axi_write_entry(2'd2, 5'd5, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));

    sb_bkn2_sw_sys = {BLOCK_BITS{1'b0}};
    sb_bkn2_sw_sys[215:200] = 16'hDEAD;
    sb_bkn2_sw_sys[15:0]    = 16'hBEEF;
    ndb_block1_sw_sys = {BLOCK_BITS{1'b0}};
    ndb_block1_sw_sys[215:208] = 8'h77;

    // Trigger refresh -> (mn=2, fn=5): slot_pulse (tn=3, fn=4, mn=2) wraps fn=5
    fire_slot_pulse(2'd3, 5'd4, 6'd2);
    begin : tc4
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys[2] !== 1'b1) ok = 1'b0;
        if (slot_burst_type_sys[0] !== 1'b0) ok = 1'b0;
        if (tx_blk1_slot2_sys   !== {BLOCK_BITS{1'b0}}) ok = 1'b0;
        if (tx_blk2_slot2_sys   !== sb_bkn2_sw_sys)     ok = 1'b0;
        if (tx_blk1_slot0_sys   !== ndb_block1_sw_sys)  ok = 1'b0;
        if (ok) begin
            $display("PASS TC4: SDB blk2 routes sb_bkn2_sw, NDB slots route ndb_block1/2");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC4: SDB/NDB routing mismatch");
            $display("  bt=%b", slot_burst_type_sys);
            $display("  blk1_slot2[215:208]=%h (exp 0)", tx_blk1_slot2_sys[215:208]);
            $display("  blk2_slot2[215:200]=%h (exp %h)",
                     tx_blk2_slot2_sys[215:200], sb_bkn2_sw_sys[215:200]);
            $display("  blk1_slot0[215:208]=%h (exp %h)",
                     tx_blk1_slot0_sys[215:208], ndb_block1_sw_sys[215:208]);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC5: sb_bb / sb_sb1 passthrough.  Drive sb1_coded_sys and
    // aach_coded_sys with distinct patterns; verify outputs mirror them
    // after one cycle (registered).
    // -----------------------------------------------------------------------
    @(posedge clk); #1;
    // 30 hex digits = 120 bits
    sb1_coded_sys  = 120'h01_2345_6789_ABCD_EFFE_DCBA_9876_5432;
    aach_coded_sys = 30'h1234_5678 & 30'h3FFF_FFFF;
    @(posedge clk); #1;
    @(posedge clk); #1;
    begin : tc5
        reg ok;
        ok = 1'b1;
        if (sb_sb1_data_sys !== sb1_coded_sys)  ok = 1'b0;
        if (sb_bb_data_sys  !== aach_coded_sys) ok = 1'b0;
        if (ok) begin
            $display("PASS TC5: sb_sb1/sb_bb passthrough from encoders");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC5: passthrough mismatch");
            $display("  sb_sb1_data_sys = %h", sb_sb1_data_sys);
            $display("  exp             = %h", sb1_coded_sys);
            $display("  sb_bb_data_sys  = %h", sb_bb_data_sys);
            $display("  exp             = %h", aach_coded_sys);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // TC6: 4-TN sweep.  Load 4 distinct classes/idx at (mn=3, fn=2, tn=0..3):
    //   TN=0: STATIC_BROADCAST idx=0 (NDB_SYSINFO)   NDB    ndb2=0 en=1
    //   TN=1: STATIC_BROADCAST idx=1 (MCCH)           NDB    ndb2=0 en=1
    //   TN=2: STATIC_BROADCAST idx=2 (BNCH)           NDB    ndb2=0 en=1
    //   TN=3: STATIC_BROADCAST idx=7 (empty)          NDB    ndb2=0 en=0
    // Verify per-TN burst_type / en / ndb2 + blk1/blk2 payload routing.
    // -----------------------------------------------------------------------
    axi_write_entry(2'd3, 5'd2, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd1, pack_entry(4'd0, 6'd1, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd2, pack_entry(4'd0, 6'd2, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd3, pack_entry(4'd0, 6'd7, 2'b00, 1'b0, 1'b0, 1'b0));

    // Distinct payload patterns
    ndb_block1_sw_sys  = {8'hA0, {(BLOCK_BITS-8){1'b0}}};
    ndb_block2_sw_sys  = {8'hA1, {(BLOCK_BITS-8){1'b0}}};
    mcch_block1_sw_sys = {8'hB0, {(BLOCK_BITS-8){1'b0}}};
    mcch_block2_sw_sys = {8'hB1, {(BLOCK_BITS-8){1'b0}}};
    bnch_block1_sw_sys = {8'hC0, {(BLOCK_BITS-8){1'b0}}};
    bnch_block2_sw_sys = {8'hC1, {(BLOCK_BITS-8){1'b0}}};

    // Fire refresh targeting (mn=3, fn=2): slot_pulse (tn=3, fn=1, mn=3)
    fire_slot_pulse(2'd3, 5'd1, 6'd3);
    begin : tc6
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys !== 4'b0000) ok = 1'b0;
        if (slot_en_sys         !== 4'b0111) ok = 1'b0;   // TN=3 disabled
        if (slot_ndb2_sys       !== 4'b0000) ok = 1'b0;
        if (tx_blk1_slot0_sys[215:208] !== 8'hA0) ok = 1'b0;
        if (tx_blk2_slot0_sys[215:208] !== 8'hA1) ok = 1'b0;
        if (tx_blk1_slot1_sys[215:208] !== 8'hB0) ok = 1'b0;
        if (tx_blk2_slot1_sys[215:208] !== 8'hB1) ok = 1'b0;
        if (tx_blk1_slot2_sys[215:208] !== 8'hC0) ok = 1'b0;
        if (tx_blk2_slot2_sys[215:208] !== 8'hC1) ok = 1'b0;
        if (tx_blk1_slot3_sys !== {BLOCK_BITS{1'b0}}) ok = 1'b0;
        if (tx_blk2_slot3_sys !== {BLOCK_BITS{1'b0}}) ok = 1'b0;
        if (ok) begin
            $display("PASS TC6: 4-TN sweep — NDB_SYSINFO/MCCH/BNCH/empty routed correctly");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC6: 4-TN sweep mismatch");
            $display("  bt=%b en=%b ndb2=%b", slot_burst_type_sys, slot_en_sys, slot_ndb2_sys);
            $display("  blk1 top [tn0..3]: %h %h %h %h",
                     tx_blk1_slot0_sys[215:208], tx_blk1_slot1_sys[215:208],
                     tx_blk1_slot2_sys[215:208], tx_blk1_slot3_sys[215:208]);
            $display("  blk2 top [tn0..3]: %h %h %h %h",
                     tx_blk2_slot0_sys[215:208], tx_blk2_slot1_sys[215:208],
                     tx_blk2_slot2_sys[215:208], tx_blk2_slot3_sys[215:208]);
            fail_cnt = fail_cnt + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    repeat (4) @(posedge clk);
    $display("=============================================");
    if (fail_cnt == 0) begin
        $display("tb_tetra_slot_content_mux: ALL TESTS PASSED (%0d pass, %0d fail)",
                 pass_cnt, fail_cnt);
        $display("RESULT: PASS");
    end else begin
        $display("tb_tetra_slot_content_mux: FAILURES (%0d pass, %0d fail)",
                 pass_cnt, fail_cnt);
        $display("RESULT: FAIL");
    end
    $display("=============================================");
    if (fail_cnt != 0) $fatal(1, "TB failure count = %0d", fail_cnt);
    $finish;
end

// Watchdog
initial begin
    #10_000_000;
    $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
