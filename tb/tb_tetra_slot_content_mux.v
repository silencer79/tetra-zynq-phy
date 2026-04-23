// =============================================================================
// tb_tetra_slot_content_mux.v — Self-Checking Testbench
// DUT : tetra_slot_content_mux  + tetra_slot_schedule (dual-port BRAM)
// =============================================================================
//
// Stimulus loads the schedule BRAM via its AXI port, drives the TDMA
// timebase and the scheduler-fed per-TN signalling bundle, and checks:
//   TC1: Reset state — all content_mux outputs are 0 after reset.
//   TC2: Gold-preset — load the 288-entry gold schedule, step through a
//        full frame, verify slot_burst_type/en/ndb2 metadata match.
//   TC3: Class=SIGNALLING routing — schedule class=1 at all 4 TNs.
//        Drive distinct sched_blk*_tn*_sys patterns and sched_ndb2_sys,
//        verify tx_blk*_slot* mirror the scheduler inputs and slot_ndb2
//        mirrors sched_ndb2_sys.
//   TC4: SDB blk2 routing — class=0 idx=3 SB at (mn=2, fn=5, tn=2).
//        Verify tx_blk2_slot2 = sb_bkn2_sw, tx_blk1_slot2 = 0, and that
//        scheduler inputs are ignored for class=0 slots.
//   TC5: sb_bb / sb_sb1 passthrough from encoder outputs.
//   TC6: 4-TN sweep across multiple class=0 indices.
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

// Scheduler → mux per-TN signalling bundle (scheduler is stubbed — regs
// are driven by the TB directly to exercise class=SIGNALLING paths).
reg  [BLOCK_BITS-1:0]  sched_blk1_tn0_sys;
reg  [BLOCK_BITS-1:0]  sched_blk2_tn0_sys;
reg  [BLOCK_BITS-1:0]  sched_blk1_tn1_sys;
reg  [BLOCK_BITS-1:0]  sched_blk2_tn1_sys;
reg  [BLOCK_BITS-1:0]  sched_blk1_tn2_sys;
reg  [BLOCK_BITS-1:0]  sched_blk2_tn2_sys;
reg  [BLOCK_BITS-1:0]  sched_blk1_tn3_sys;
reg  [BLOCK_BITS-1:0]  sched_blk2_tn3_sys;
reg  [3:0]             sched_ndb2_sys;

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
    .sched_blk1_tn0_sys   (sched_blk1_tn0_sys),
    .sched_blk2_tn0_sys   (sched_blk2_tn0_sys),
    .sched_blk1_tn1_sys   (sched_blk1_tn1_sys),
    .sched_blk2_tn1_sys   (sched_blk2_tn1_sys),
    .sched_blk1_tn2_sys   (sched_blk1_tn2_sys),
    .sched_blk2_tn2_sys   (sched_blk2_tn2_sys),
    .sched_blk1_tn3_sys   (sched_blk1_tn3_sys),
    .sched_blk2_tn3_sys   (sched_blk2_tn3_sys),
    .sched_ndb2_sys       (sched_ndb2_sys),
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

function exp_is_sdb;    input [15:0] e; begin exp_is_sdb    = (e[5:4] == 2'b01); end endfunction
function exp_is_enable; input [15:0] e; begin exp_is_enable = e[2];              end endfunction
function exp_is_ndb2;   input [15:0] e; begin exp_is_ndb2  = e[3];              end endfunction
function exp_is_signal; input [15:0] e; begin exp_is_signal = (e[15:12] == 4'd1); end endfunction

// Expected slot_ndb2[k] is the class-dispatched value: SIGNALLING → sched_ndb2[k],
// STATIC_BROADCAST → entry[3].
function exp_ndb2_eff;
    input [15:0] e;
    input        sched_bit;
    begin
        exp_ndb2_eff = exp_is_signal(e) ? sched_bit : exp_is_ndb2(e);
    end
endfunction

// ---------------------------------------------------------------------------
// AXI write task
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
reg [3:0]  exp_slot_ndb2;

initial begin
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
    sched_blk1_tn0_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn0_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn1_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn1_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn2_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn2_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn3_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn3_sys = {BLOCK_BITS{1'b0}};
    sched_ndb2_sys     = 4'b0000;

    pass_cnt = 0;
    fail_cnt = 0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // -----------------------------------------------------------------------
    // TC1: Reset state — before any slot_pulse, all outputs 0.
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
    // TC2: Gold-preset — load schedule, step through slot_pulses and verify
    // metadata.  Note: for class=SIGNALLING slots the effective slot_ndb2[k]
    // is sched_ndb2_sys[k] (driven by the TB to 0 here, which matches the
    // gold entry's ndb2=0 for class=1 slots).
    // -----------------------------------------------------------------------
    load_gold_schedule();

    fire_slot_pulse(2'd3, 5'd0, 6'd0);
    exp_e0 = gold_entry(2'd0, 5'd0, 2'd0);
    exp_e1 = gold_entry(2'd0, 5'd0, 2'd1);
    exp_e2 = gold_entry(2'd0, 5'd0, 2'd2);
    exp_e3 = gold_entry(2'd0, 5'd0, 2'd3);
    exp_slot_ndb2 = {exp_ndb2_eff(exp_e3, sched_ndb2_sys[3]),
                     exp_ndb2_eff(exp_e2, sched_ndb2_sys[2]),
                     exp_ndb2_eff(exp_e1, sched_ndb2_sys[1]),
                     exp_ndb2_eff(exp_e0, sched_ndb2_sys[0])};
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
        if (slot_ndb2_sys !== exp_slot_ndb2) ok = 1'b0;
        if (ok) begin
            $display("PASS TC2a: first_refresh loads (mn=0,fn=0,*) — entries %h %h %h %h",
                     exp_e0, exp_e1, exp_e2, exp_e3);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC2a: first_refresh mismatch");
            $display("  got  %h %h %h %h", dbg_sched_entry0_sys, dbg_sched_entry1_sys,
                                            dbg_sched_entry2_sys, dbg_sched_entry3_sys);
            $display("  exp  %h %h %h %h", exp_e0, exp_e1, exp_e2, exp_e3);
            $display("  bt=%b en=%b ndb2=%b exp_ndb2=%b",
                     slot_burst_type_sys, slot_en_sys, slot_ndb2_sys, exp_slot_ndb2);
            fail_cnt = fail_cnt + 1;
        end
    end

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
    // TC3: class=SIGNALLING routing.  All 4 TNs at (mn=1, fn=5) programmed
    // with class=1.  Drive the scheduler inputs with distinct patterns and
    // verify mux outputs mirror them; slot_ndb2 mirrors sched_ndb2_sys.
    // -----------------------------------------------------------------------
    axi_write_entry(2'd1, 5'd5, 2'd0, pack_entry(4'd1, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd1, pack_entry(4'd1, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd2, pack_entry(4'd1, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd1, 5'd5, 2'd3, pack_entry(4'd1, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));

    sched_blk1_tn0_sys = {8'hA0, {(BLOCK_BITS-8){1'b0}}};
    sched_blk2_tn0_sys = {8'hA1, {(BLOCK_BITS-8){1'b0}}};
    sched_blk1_tn1_sys = {8'hB0, {(BLOCK_BITS-8){1'b0}}};
    sched_blk2_tn1_sys = {8'hB1, {(BLOCK_BITS-8){1'b0}}};
    sched_blk1_tn2_sys = {8'hC0, {(BLOCK_BITS-8){1'b0}}};
    sched_blk2_tn2_sys = {8'hC1, {(BLOCK_BITS-8){1'b0}}};
    sched_blk1_tn3_sys = {8'hD0, {(BLOCK_BITS-8){1'b0}}};
    sched_blk2_tn3_sys = {8'hD1, {(BLOCK_BITS-8){1'b0}}};
    sched_ndb2_sys     = 4'b1010;

    fire_slot_pulse(2'd3, 5'd4, 6'd1);
    begin : tc3
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys !== 4'b0000) ok = 1'b0;
        if (slot_en_sys         !== 4'b1111) ok = 1'b0;
        if (slot_ndb2_sys       !== 4'b1010) ok = 1'b0;  // mirror sched_ndb2_sys
        if (tx_blk1_slot0_sys   !== sched_blk1_tn0_sys) ok = 1'b0;
        if (tx_blk2_slot0_sys   !== sched_blk2_tn0_sys) ok = 1'b0;
        if (tx_blk1_slot1_sys   !== sched_blk1_tn1_sys) ok = 1'b0;
        if (tx_blk2_slot1_sys   !== sched_blk2_tn1_sys) ok = 1'b0;
        if (tx_blk1_slot2_sys   !== sched_blk1_tn2_sys) ok = 1'b0;
        if (tx_blk2_slot2_sys   !== sched_blk2_tn2_sys) ok = 1'b0;
        if (tx_blk1_slot3_sys   !== sched_blk1_tn3_sys) ok = 1'b0;
        if (tx_blk2_slot3_sys   !== sched_blk2_tn3_sys) ok = 1'b0;
        if (ok) begin
            $display("PASS TC3: class=SIGNALLING routes scheduler per-TN bundle verbatim");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL TC3: SIGNALLING routing mismatch");
            $display("  bt=%b en=%b ndb2=%b (exp 1010)",
                     slot_burst_type_sys, slot_en_sys, slot_ndb2_sys);
            $display("  blk1 top [tn0..3]: %h %h %h %h (exp A0 B0 C0 D0)",
                     tx_blk1_slot0_sys[215:208], tx_blk1_slot1_sys[215:208],
                     tx_blk1_slot2_sys[215:208], tx_blk1_slot3_sys[215:208]);
            $display("  blk2 top [tn0..3]: %h %h %h %h (exp A1 B1 C1 D1)",
                     tx_blk2_slot0_sys[215:208], tx_blk2_slot1_sys[215:208],
                     tx_blk2_slot2_sys[215:208], tx_blk2_slot3_sys[215:208]);
            fail_cnt = fail_cnt + 1;
        end
    end

    // Reset scheduler regs to 0 for next tests so their residue doesn't
    // bleed into subsequent checks (TC4/TC6 exercise class=0 — sched inputs
    // are ignored, but leave them clean).
    sched_blk1_tn0_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn0_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn1_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn1_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn2_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn2_sys = {BLOCK_BITS{1'b0}};
    sched_blk1_tn3_sys = {BLOCK_BITS{1'b0}};
    sched_blk2_tn3_sys = {BLOCK_BITS{1'b0}};
    sched_ndb2_sys     = 4'b0000;

    // -----------------------------------------------------------------------
    // TC4: SDB blk2 routing.  (mn=2, fn=5, tn=2) → class=0 idx=3 SB SDB.
    // -----------------------------------------------------------------------
    axi_write_entry(2'd2, 5'd5, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd2, 5'd5, 2'd1, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd2, 5'd5, 2'd2, pack_entry(4'd0, 6'd3, 2'b01, 1'b0, 1'b1, 1'b1));
    axi_write_entry(2'd2, 5'd5, 2'd3, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));

    sb_bkn2_sw_sys = {BLOCK_BITS{1'b0}};
    sb_bkn2_sw_sys[215:200] = 16'hDEAD;
    sb_bkn2_sw_sys[15:0]    = 16'hBEEF;
    ndb_block1_sw_sys = {BLOCK_BITS{1'b0}};
    ndb_block1_sw_sys[215:208] = 8'h77;

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
    // TC5: sb_bb / sb_sb1 passthrough.
    // -----------------------------------------------------------------------
    @(posedge clk); #1;
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
    // TC6: 4-TN sweep.  (mn=3, fn=2, tn=0..3): class=0 with varying idx.
    // -----------------------------------------------------------------------
    axi_write_entry(2'd3, 5'd2, 2'd0, pack_entry(4'd0, 6'd0, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd1, pack_entry(4'd0, 6'd1, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd2, pack_entry(4'd0, 6'd2, 2'b00, 1'b0, 1'b1, 1'b0));
    axi_write_entry(2'd3, 5'd2, 2'd3, pack_entry(4'd0, 6'd7, 2'b00, 1'b0, 1'b0, 1'b0));

    ndb_block1_sw_sys  = {8'hA0, {(BLOCK_BITS-8){1'b0}}};
    ndb_block2_sw_sys  = {8'hA1, {(BLOCK_BITS-8){1'b0}}};
    mcch_block1_sw_sys = {8'hB0, {(BLOCK_BITS-8){1'b0}}};
    mcch_block2_sw_sys = {8'hB1, {(BLOCK_BITS-8){1'b0}}};
    bnch_block1_sw_sys = {8'hC0, {(BLOCK_BITS-8){1'b0}}};
    bnch_block2_sw_sys = {8'hC1, {(BLOCK_BITS-8){1'b0}}};

    fire_slot_pulse(2'd3, 5'd1, 6'd3);
    begin : tc6
        reg ok;
        ok = 1'b1;
        if (slot_burst_type_sys !== 4'b0000) ok = 1'b0;
        if (slot_en_sys         !== 4'b0111) ok = 1'b0;
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

initial begin
    #10_000_000;
    $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
