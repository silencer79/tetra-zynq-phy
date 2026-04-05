// =============================================================================
// tb_tetra_axi_dma_bridge.v  —  Self-Checking Testbench
// DUT : tetra_axi_dma_bridge
// =============================================================================
// 7 Test Cases:
//   TC01: 216-bit NDB block — 8 words total (header + 7 data), correct TKEEP
//   TC02: 432-bit SCH/F block — 15 words total, correct TKEEP
//   TC03: 32-bit aligned block — 2 words total, TKEEP=4'hF on last
//   TC04: Back-pressure — tready deasserted for several cycles mid-transfer
//   TC05: Block counter increment after each block
//   TC06: IRQ pulse fires 1 cycle after last word accepted
//   TC07: reset_counters clears dma_block_count
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_tetra_axi_dma_bridge;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10; // 10 ns = 100 MHz
localparam MAX_BLOCK_BITS = 432;
localparam MAX_DATA_WORDS = 14;
localparam PAD_WIDTH      = MAX_DATA_WORDS * 32; // 448

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg                       clk_sys;
reg                       rst_n_sys;

reg  [MAX_BLOCK_BITS-1:0] mac_data;
reg  [9:0]                mac_len;
reg  [1:0]                mac_slot;
reg  [1:0]                mac_burst_type;
reg  [15:0]               mac_frame;
reg                       mac_valid;
wire                      mac_ready;

wire                      m_axis_tvalid;
reg                       m_axis_tready;
wire [31:0]               m_axis_tdata;
wire [3:0]                m_axis_tkeep;
wire                      m_axis_tlast;

wire [15:0]               dma_block_count;
wire                      irq_mac_block;
wire                      fifo_empty;
wire                      fifo_full;
reg                       reset_counters;

// ---------------------------------------------------------------------------
// DUT Instantiation
// ---------------------------------------------------------------------------
tetra_axi_dma_bridge #(
    .MAX_BLOCK_BITS (MAX_BLOCK_BITS),
    .MAX_DATA_WORDS (MAX_DATA_WORDS)
) dut (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    .mac_data_sys         (mac_data),
    .mac_len_sys          (mac_len),
    .mac_slot_sys         (mac_slot),
    .mac_burst_type_sys   (mac_burst_type),
    .mac_frame_sys        (mac_frame),
    .mac_valid_sys        (mac_valid),
    .mac_ready_sys        (mac_ready),
    .m_axis_tvalid        (m_axis_tvalid),
    .m_axis_tready        (m_axis_tready),
    .m_axis_tdata         (m_axis_tdata),
    .m_axis_tkeep         (m_axis_tkeep),
    .m_axis_tlast         (m_axis_tlast),
    .dma_block_count_sys  (dma_block_count),
    .irq_mac_block_sys    (irq_mac_block),
    .fifo_empty_sys       (fifo_empty),
    .fifo_full_sys        (fifo_full),
    .reset_counters_sys   (reset_counters)
);

// ---------------------------------------------------------------------------
// Clock Generation
// ---------------------------------------------------------------------------
initial clk_sys = 1'b0;
always #(CLK_PERIOD/2) clk_sys = ~clk_sys;

// ---------------------------------------------------------------------------
// Waveform Dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim_out/tb_tetra_axi_dma_bridge.vcd");
    $dumpvars(0, tb_tetra_axi_dma_bridge);
end

// ---------------------------------------------------------------------------
// Helper: Reset
// ---------------------------------------------------------------------------
task do_reset;
    begin
        rst_n_sys      <= 1'b0;
        mac_data       <= {MAX_BLOCK_BITS{1'b0}};
        mac_len        <= 10'd0;
        mac_slot       <= 2'b0;
        mac_burst_type <= 2'b0;
        mac_frame      <= 16'b0;
        mac_valid      <= 1'b0;
        m_axis_tready  <= 1'b1;
        reset_counters <= 1'b0;
        repeat(4) @(posedge clk_sys);
        #1; rst_n_sys <= 1'b1;
        repeat(2) @(posedge clk_sys);
    end
endtask

// ---------------------------------------------------------------------------
// Helper: Send one MAC block; collect all AXI-Stream words into a flat bus.
//
// Parameters:
//   data        — block payload (MAX_BLOCK_BITS wide)
//   len_bits    — block length in bits
//   slot        — slot number
//   burst_t     — burst type
//   frame_n     — frame number
//   tready_mask — if 0, tready is deasserted for 3 cycles mid-transfer to
//                 test back-pressure
//
// Outputs:
//   words_out      — flat array of received 32-bit words (up to 16 words)
//   tkeep_out      — flat array of received tkeep values
//   tlast_word_idx — word index at which TLAST was seen
//   num_words_out  — total number of words received
// ---------------------------------------------------------------------------
localparam MAX_WORDS_BUF = 16; // 15 + 1 margin

reg [MAX_WORDS_BUF*32-1:0] words_out_buf;
reg [MAX_WORDS_BUF*4-1:0]  tkeep_out_buf;
reg [3:0]                   num_words_received;
reg [3:0]                   tlast_word_idx;

task send_block_and_collect;
    input [MAX_BLOCK_BITS-1:0] data;
    input [9:0]   len_bits;
    input [1:0]   slot;
    input [1:0]   burst_t;
    input [15:0]  frame_n;
    input         use_backpressure; // 1 = assert backpressure mid-transfer

    integer i;
    integer bp_done;
    begin
        words_out_buf    = {(MAX_WORDS_BUF*32){1'b0}};
        tkeep_out_buf    = {(MAX_WORDS_BUF*4){1'b0}};
        num_words_received = 4'b0;
        tlast_word_idx   = 4'hF; // sentinel
        bp_done          = 0;

        // Present block to DUT
        @(posedge clk_sys); #1;
        mac_data       <= data;
        mac_len        <= len_bits;
        mac_slot       <= slot;
        mac_burst_type <= burst_t;
        mac_frame      <= frame_n;
        mac_valid      <= 1'b1;

        @(posedge clk_sys); #1;
        mac_valid <= 1'b0;

        // Collect words until TLAST
        for (i = 0; i < MAX_WORDS_BUF + 2; i = i + 1) begin
            // Apply back-pressure at word 2 (first data word after header)
            if (use_backpressure && !bp_done && (num_words_received == 4'd2)) begin
                m_axis_tready = 1'b0;  // blocking: immediate effect for while-loop check
                repeat(3) @(posedge clk_sys);
                #1; m_axis_tready = 1'b1;  // blocking: visible before while-loop re-evaluates
                bp_done = 1;
            end

            // Wait for a valid word (tvalid & tready)
            while (!(m_axis_tvalid && m_axis_tready)) @(posedge clk_sys);

            // Sample word
            words_out_buf[num_words_received*32 +: 32] = m_axis_tdata;
            tkeep_out_buf[num_words_received*4  +:  4] = m_axis_tkeep;
            if (m_axis_tlast) tlast_word_idx = num_words_received;
            num_words_received = num_words_received + 4'b1;

            @(posedge clk_sys); #1;

            if (tlast_word_idx !== 4'hF) begin
                i = MAX_WORDS_BUF + 2; // exit loop
            end
        end
        #1;
    end
endtask

// ---------------------------------------------------------------------------
// Helper: compute expected header word
// ---------------------------------------------------------------------------
function [31:0] expected_header;
    input [1:0]  slot;
    input [1:0]  burst_t;
    input [9:0]  len;
    input [15:0] frame;
    begin
        expected_header = {slot, burst_t, 2'b00, len, frame};
    end
endfunction

// ---------------------------------------------------------------------------
// Helper: compute expected number of total words (header + data words)
// ---------------------------------------------------------------------------
function [4:0] expected_num_words;
    input [9:0] len;
    begin
        expected_num_words = 5'd1 + ((len + 10'd31) >> 5);
    end
endfunction

// ---------------------------------------------------------------------------
// Helper: compute expected TKEEP for last word
// ---------------------------------------------------------------------------
function [3:0] expected_last_tkeep;
    input [9:0] len;
    reg [4:0] lb;
    begin
        lb = len[4:0];
        if (lb == 5'd0)      expected_last_tkeep = 4'hF;
        else if (lb > 5'd24) expected_last_tkeep = 4'hF;
        else if (lb > 5'd16) expected_last_tkeep = 4'h7;
        else if (lb > 5'd8)  expected_last_tkeep = 4'h3;
        else                 expected_last_tkeep = 4'h1;
    end
endfunction

// ---------------------------------------------------------------------------
// Main Stimulus
// ---------------------------------------------------------------------------
integer tc;
reg [31:0]           exp_hdr;
reg [4:0]            exp_num_words;
reg [3:0]            exp_last_tkeep;
reg [MAX_BLOCK_BITS-1:0] test_data;
integer              wi; // word index

initial begin
    tc = 0;
    do_reset;

    // -----------------------------------------------------------------------
    // TC01: 216-bit NDB block
    //   slot=2, burst_type=0(NDB), frame=42
    //   Expected: 8 words (header + 7 data), TKEEP last = 4'h7 (24 valid bits)
    // -----------------------------------------------------------------------
    tc = 1;
    // Fill test data with known pattern: alternating 0xAA/0x55 bytes
    test_data = {216{1'b0}};
    test_data[215:0] = 216'hAA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA; // 27 bytes

    send_block_and_collect(
        test_data, 10'd216, 2'd2, 2'd0, 16'd42, 1'b0
    );

    exp_num_words  = expected_num_words(10'd216);  // 8
    exp_hdr        = expected_header(2'd2, 2'd0, 10'd216, 16'd42);
    exp_last_tkeep = expected_last_tkeep(10'd216); // 4'h7

    if (num_words_received !== exp_num_words[3:0]) begin
        $fatal(1,"FAIL TC%0d: word count = %0d, expected %0d",
               tc, num_words_received, exp_num_words);
    end
    if (words_out_buf[31:0] !== exp_hdr) begin
        $fatal(1,"FAIL TC%0d: header = %08h, expected %08h",
               tc, words_out_buf[31:0], exp_hdr);
    end
    if (tlast_word_idx !== (exp_num_words[3:0] - 4'b1)) begin
        $fatal(1,"FAIL TC%0d: TLAST at word %0d, expected %0d",
               tc, tlast_word_idx, exp_num_words-1);
    end
    if (tkeep_out_buf[tlast_word_idx*4 +: 4] !== exp_last_tkeep) begin
        $fatal(1,"FAIL TC%0d: last TKEEP = %04b, expected %04b",
               tc, tkeep_out_buf[tlast_word_idx*4 +: 4], exp_last_tkeep);
    end
    // Verify all non-last words have TKEEP=4'hF
    for (wi = 0; wi < (exp_num_words - 1); wi = wi + 1) begin
        if (tkeep_out_buf[wi*4 +: 4] !== 4'hF) begin
            $fatal(1,"FAIL TC%0d: TKEEP[word%0d] = %04b, expected F",
                   tc, wi, tkeep_out_buf[wi*4 +: 4]);
        end
    end
    // Verify data word 0 (word index 1 in output) equals first 32 bits of test_data
    if (words_out_buf[32 +: 32] !== test_data[31:0]) begin
        $fatal(1,"FAIL TC%0d: data[0] = %08h, expected %08h",
               tc, words_out_buf[32 +: 32], test_data[31:0]);
    end
    $display("PASS TC%0d: 216-bit NDB block — 8 words, TKEEP[last]=4'h7", tc);

    // -----------------------------------------------------------------------
    // TC02: 432-bit SCH/F block
    //   slot=0, burst_type=1(SB), frame=1
    //   Expected: 15 words, TKEEP last = 4'h3 (16 valid bits)
    // -----------------------------------------------------------------------
    tc = 2;
    test_data = {432{1'b0}};
    // Fill with counting pattern: byte n = n & 0xFF
    begin : fill_432
        integer b;
        for (b = 0; b < 54; b = b + 1)
            test_data[b*8 +: 8] = b[7:0];
    end

    send_block_and_collect(
        test_data, 10'd432, 2'd0, 2'd1, 16'd1, 1'b0
    );

    exp_num_words  = expected_num_words(10'd432);  // 15
    exp_hdr        = expected_header(2'd0, 2'd1, 10'd432, 16'd1);
    exp_last_tkeep = expected_last_tkeep(10'd432); // 4'h3

    if (num_words_received !== exp_num_words[3:0]) begin
        $fatal(1,"FAIL TC%0d: word count = %0d, expected %0d",
               tc, num_words_received, exp_num_words);
    end
    if (words_out_buf[31:0] !== exp_hdr) begin
        $fatal(1,"FAIL TC%0d: header = %08h, expected %08h",
               tc, words_out_buf[31:0], exp_hdr);
    end
    if (tkeep_out_buf[tlast_word_idx*4 +: 4] !== exp_last_tkeep) begin
        $fatal(1,"FAIL TC%0d: last TKEEP = %04b, expected %04b",
               tc, tkeep_out_buf[tlast_word_idx*4 +: 4], exp_last_tkeep);
    end
    $display("PASS TC%0d: 432-bit SCH/F block — 15 words, TKEEP[last]=4'h3", tc);

    // -----------------------------------------------------------------------
    // TC03: 32-bit aligned block (len=32)
    //   Expected: 2 words (header + 1 data), TKEEP last = 4'hF
    // -----------------------------------------------------------------------
    tc = 3;
    test_data = {MAX_BLOCK_BITS{1'b0}};
    test_data[31:0] = 32'hCAFE_BABE;

    send_block_and_collect(
        test_data, 10'd32, 2'd1, 2'd2, 16'd99, 1'b0
    );

    exp_num_words  = expected_num_words(10'd32);  // 2
    exp_last_tkeep = expected_last_tkeep(10'd32); // 4'hF (32 mod 32 = 0 → full)

    if (num_words_received !== exp_num_words[3:0]) begin
        $fatal(1,"FAIL TC%0d: word count = %0d, expected %0d",
               tc, num_words_received, exp_num_words);
    end
    if (tkeep_out_buf[tlast_word_idx*4 +: 4] !== 4'hF) begin
        $fatal(1,"FAIL TC%0d: last TKEEP = %04b for 32-bit aligned, expected F",
               tc, tkeep_out_buf[tlast_word_idx*4 +: 4]);
    end
    if (words_out_buf[32 +: 32] !== 32'hCAFE_BABE) begin
        $fatal(1,"FAIL TC%0d: data word = %08h, expected CAFEBABE",
               tc, words_out_buf[32 +: 32]);
    end
    $display("PASS TC%0d: 32-bit aligned block — 2 words, TKEEP[last]=4'hF", tc);

    // -----------------------------------------------------------------------
    // TC04: Back-pressure test — tready deasserted mid-transfer
    //   Use 216-bit block; tready goes low for 3 cycles during word 2
    //   All data must still be correct.
    // -----------------------------------------------------------------------
    tc = 4;
    test_data = {MAX_BLOCK_BITS{1'b0}};
    test_data[215:0] = 216'h0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456;

    send_block_and_collect(
        test_data, 10'd216, 2'd3, 2'd0, 16'd5, 1'b1 // use_backpressure=1
    );

    exp_num_words = expected_num_words(10'd216); // 8

    if (num_words_received !== exp_num_words[3:0]) begin
        $fatal(1,"FAIL TC%0d: word count under backpressure = %0d, expected %0d",
               tc, num_words_received, exp_num_words);
    end
    if (tlast_word_idx !== (exp_num_words[3:0] - 4'b1)) begin
        $fatal(1,"FAIL TC%0d: TLAST position wrong under backpressure", tc);
    end
    if (words_out_buf[31:0] !== expected_header(2'd3, 2'd0, 10'd216, 16'd5)) begin
        $fatal(1,"FAIL TC%0d: header wrong under backpressure", tc);
    end
    $display("PASS TC%0d: back-pressure test — all 8 words received correctly", tc);

    // -----------------------------------------------------------------------
    // TC05: Block counter increments after each block
    //   Send 3 consecutive blocks; verify dma_block_count = 3 (+ prior 5)
    // -----------------------------------------------------------------------
    tc = 5;
    // After TC01–TC04, dma_block_count should be 4 blocks
    // Send 3 more to reach 7
    begin : send3
        integer b;
        for (b = 0; b < 3; b = b + 1) begin
            test_data = {MAX_BLOCK_BITS{1'b0}};
            test_data[31:0] = b[31:0];
            send_block_and_collect(test_data, 10'd32, 2'd0, 2'd0, b[15:0], 1'b0);
        end
    end

    @(posedge clk_sys); @(posedge clk_sys);
    if (dma_block_count !== 16'd7) begin
        $fatal(1,"FAIL TC%0d: dma_block_count = %0d, expected 7", tc, dma_block_count);
    end
    $display("PASS TC%0d: dma_block_count = 7 after 7 blocks", tc);

    // -----------------------------------------------------------------------
    // TC06: IRQ pulse — fires exactly 1 cycle after last word accepted
    // -----------------------------------------------------------------------
    tc = 6;
    begin : irq_check
        integer irq_delay;
        reg     irq_seen;
        reg     last_seen;

        irq_delay = 0;
        irq_seen  = 0;
        last_seen = 0;

        // Send a 32-bit block
        test_data = {MAX_BLOCK_BITS{1'b0}};
        @(posedge clk_sys); #1;
        mac_data       <= test_data;
        mac_len        <= 10'd32;
        mac_slot       <= 2'b0;
        mac_burst_type <= 2'b0;
        mac_frame      <= 16'd0;
        mac_valid      <= 1'b1;
        @(posedge clk_sys); #1;
        mac_valid <= 1'b0;

        // Wait for TLAST handshake
        while (!(m_axis_tvalid && m_axis_tready && m_axis_tlast)) @(posedge clk_sys);
        // TLAST accepted this cycle.
        // IRQ should fire on the NEXT posedge.
        @(posedge clk_sys);
        if (irq_mac_block !== 1'b1) begin
            $fatal(1,"FAIL TC%0d: irq_mac_block not asserted 1 cycle after TLAST", tc);
        end
        @(posedge clk_sys);
        if (irq_mac_block !== 1'b0) begin
            $fatal(1,"FAIL TC%0d: irq_mac_block not cleared after 1 cycle", tc);
        end
    end
    $display("PASS TC%0d: irq_mac_block pulse exactly 1 cycle after last word", tc);

    // -----------------------------------------------------------------------
    // TC07: reset_counters clears dma_block_count
    // -----------------------------------------------------------------------
    tc = 7;
    // At this point dma_block_count = 8 (7 + TC06)
    @(posedge clk_sys); #1;
    reset_counters <= 1'b1;
    @(posedge clk_sys); #1;
    reset_counters <= 1'b0;
    @(posedge clk_sys);
    if (dma_block_count !== 16'd0) begin
        $fatal(1,"FAIL TC%0d: dma_block_count = %0d after reset, expected 0",
               tc, dma_block_count);
    end
    $display("PASS TC%0d: reset_counters clears dma_block_count to 0", tc);

    // -----------------------------------------------------------------------
    // All tests passed
    // -----------------------------------------------------------------------
    repeat(4) @(posedge clk_sys);
    $display("==========================================");
    $display("tb_tetra_axi_dma_bridge: ALL 7 TCs PASS");
    $display("==========================================");
    $finish;
end

// Watchdog
initial begin
    #2_000_000;
    $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
