// =============================================================================
// tb_tetra_axi_lite_regs.v  —  Self-Checking Testbench
// DUT : tetra_axi_lite_regs
// =============================================================================
// 10 Test Cases:
//   TC01: SCRATCH — write DEADBEEF, read back
//   TC02: CTRL    — write 4'b0101 (RX_EN+LOOPBACK), verify output wires
//   TC03: VERSION — RO register, write has no effect
//   TC04: STATUS  — drive live inputs, read STATUS bits
//   TC05: SYNC_THRESH / COLOUR_CODE / RX_GAIN / TX_ATT
//   TC06: IRQ_ENABLE + IRQ_STATUS — pulse irq_mac_block, check irq_out
//   TC07: IRQ_STATUS W1C — write 1 to clear bit 0
//   TC08: IRQ_STATUS HW-set wins — simultaneous pulse + W1C
//   TC09: FRAME_NUM / SLOT_NUM — RO registers
//   TC10: DMA_BLOCK_COUNT / CRC_ERROR_COUNT / SYNC_LOST_COUNT — RO counters
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_tetra_axi_lite_regs;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD = 10; // 10 ns = 100 MHz

// Register offsets
localparam [7:0] ADDR_CTRL         = 8'h00;
localparam [7:0] ADDR_STATUS       = 8'h04;
localparam [7:0] ADDR_VERSION      = 8'h08;
localparam [7:0] ADDR_SYNC_THRESH  = 8'h0C;
localparam [7:0] ADDR_COLOUR_CODE  = 8'h10;
localparam [7:0] ADDR_FRAME_NUM    = 8'h14;
localparam [7:0] ADDR_SLOT_NUM     = 8'h18;
localparam [7:0] ADDR_RX_GAIN      = 8'h1C;
localparam [7:0] ADDR_TX_ATT       = 8'h20;
localparam [7:0] ADDR_IRQ_ENABLE   = 8'h24;
localparam [7:0] ADDR_IRQ_STATUS   = 8'h28;
localparam [7:0] ADDR_DMA_BLK_CNT = 8'h2C;
localparam [7:0] ADDR_CRC_ERR_CNT = 8'h30;
localparam [7:0] ADDR_SYNC_LST_CNT= 8'h34;
localparam [7:0] ADDR_SCRATCH      = 8'h3C;

// ---------------------------------------------------------------------------
// DUT Signals
// ---------------------------------------------------------------------------

// AXI4-Lite
reg         clk_axi;
reg         rst_n;
reg  [31:0] awaddr;
reg         awvalid;
wire        awready;
reg  [31:0] wdata;
reg  [3:0]  wstrb;
reg         wvalid;
wire        wready;
wire [1:0]  bresp;
wire        bvalid;
reg         bready;
reg  [31:0] araddr;
reg         arvalid;
wire        arready;
wire [31:0] rdata;
wire [1:0]  rresp;
wire        rvalid;
reg         rready;

// PHY Status inputs
reg        sync_locked;
reg        pll_locked;
reg        rx_fifo_empty;
reg        rx_fifo_full;
reg [3:0]  slot_status;
reg [4:0]  frame_num;
reg [1:0]  slot_num;

// IRQ pulses
reg        irq_mac_block;
reg        irq_sync_acquired;
reg        irq_sync_lost;
reg        irq_crc_error;
reg        irq_rx_fifo_full;

// Counters
reg [15:0] dma_block_count;
reg [15:0] crc_error_count;
reg [15:0] sync_lost_count;

// Control outputs
wire        ctrl_rx_enable;
wire        ctrl_tx_enable;
wire        ctrl_loopback_en;
wire        ctrl_reset_counters;
wire [7:0]  sync_thresh;
wire [5:0]  colour_code;
wire [6:0]  rx_gain;
wire [7:0]  tx_att;
wire [4:0]  irq_enable;
wire        irq_out;

// ---------------------------------------------------------------------------
// DUT Instantiation
// ---------------------------------------------------------------------------
tetra_axi_lite_regs dut (
    .s_axi_aclk             (clk_axi),
    .s_axi_aresetn          (rst_n),
    .s_axi_awaddr           (awaddr),
    .s_axi_awvalid          (awvalid),
    .s_axi_awready          (awready),
    .s_axi_wdata            (wdata),
    .s_axi_wstrb            (wstrb),
    .s_axi_wvalid           (wvalid),
    .s_axi_wready           (wready),
    .s_axi_bresp            (bresp),
    .s_axi_bvalid           (bvalid),
    .s_axi_bready           (bready),
    .s_axi_araddr           (araddr),
    .s_axi_arvalid          (arvalid),
    .s_axi_arready          (arready),
    .s_axi_rdata            (rdata),
    .s_axi_rresp            (rresp),
    .s_axi_rvalid           (rvalid),
    .s_axi_rready           (rready),
    .sync_locked_axi        (sync_locked),
    .pll_locked_axi         (pll_locked),
    .rx_fifo_empty_axi      (rx_fifo_empty),
    .rx_fifo_full_axi       (rx_fifo_full),
    .slot_status_axi        (slot_status),
    .frame_num_axi          (frame_num),
    .slot_num_axi           (slot_num),
    .irq_mac_block_axi      (irq_mac_block),
    .irq_sync_acquired_axi  (irq_sync_acquired),
    .irq_sync_lost_axi      (irq_sync_lost),
    .irq_crc_error_axi      (irq_crc_error),
    .irq_rx_fifo_full_axi   (irq_rx_fifo_full),
    .dma_block_count_axi    (dma_block_count),
    .crc_error_count_axi    (crc_error_count),
    .sync_lost_count_axi    (sync_lost_count),
    .ctrl_rx_enable_axi     (ctrl_rx_enable),
    .ctrl_tx_enable_axi     (ctrl_tx_enable),
    .ctrl_loopback_en_axi   (ctrl_loopback_en),
    .ctrl_reset_counters_axi(ctrl_reset_counters),
    .sync_thresh_axi        (sync_thresh),
    .colour_code_axi        (colour_code),
    .rx_gain_axi            (rx_gain),
    .tx_att_axi             (tx_att),
    .irq_enable_axi         (irq_enable),
    .irq_out_axi            (irq_out)
);

// ---------------------------------------------------------------------------
// Clock Generation
// ---------------------------------------------------------------------------
initial clk_axi = 1'b0;
always #(CLK_PERIOD/2) clk_axi = ~clk_axi;

// ---------------------------------------------------------------------------
// Waveform Dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim_out/tb_tetra_axi_lite_regs.vcd");
    $dumpvars(0, tb_tetra_axi_lite_regs);
end

// ---------------------------------------------------------------------------
// AXI4-Lite Task: Write
// Drives AWADDR + WDATA simultaneously (most AXI masters do this)
// Waits for BVALID.
// ---------------------------------------------------------------------------
task axi_write;
    input [7:0]  addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
        @(posedge clk_axi);
        #1;
        awaddr  <= addr;
        awvalid <= 1'b1;
        wdata   <= data;
        wstrb   <= strb;
        wvalid  <= 1'b1;
        bready  <= 1'b1;

        // Wait for both address and data to be accepted
        fork
            begin : wait_aw
                while (!awready) @(posedge clk_axi);
                @(posedge clk_axi); #1; awvalid <= 1'b0;
            end
            begin : wait_w
                while (!wready) @(posedge clk_axi);
                @(posedge clk_axi); #1; wvalid <= 1'b0;
            end
        join

        // Wait for BVALID
        while (!bvalid) @(posedge clk_axi);
        @(posedge clk_axi); #1; bready <= 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// AXI4-Lite Task: Read
// ---------------------------------------------------------------------------
reg [31:0] read_data_buf;
task axi_read;
    input  [7:0]  addr;
    output [31:0] data;
    begin
        @(posedge clk_axi);
        #1;
        araddr  <= addr;
        arvalid <= 1'b1;
        rready  <= 1'b1;

        // Wait for AR accepted
        while (!arready) @(posedge clk_axi);
        @(posedge clk_axi); #1; arvalid <= 1'b0;

        // Wait for RVALID
        while (!rvalid) @(posedge clk_axi);
        data = rdata;
        @(posedge clk_axi); #1; rready <= 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Reset Helper
// ---------------------------------------------------------------------------
task do_reset;
    begin
        rst_n    <= 1'b0;
        awvalid  <= 1'b0; awaddr  <= 8'b0;
        wvalid   <= 1'b0; wdata   <= 32'b0; wstrb <= 4'hF;
        bready   <= 1'b0;
        arvalid  <= 1'b0; araddr  <= 8'b0;
        rready   <= 1'b0;
        sync_locked      <= 1'b0;
        pll_locked       <= 1'b0;
        rx_fifo_empty    <= 1'b1;
        rx_fifo_full     <= 1'b0;
        slot_status      <= 4'b0;
        frame_num        <= 5'd0;
        slot_num         <= 2'd0;
        irq_mac_block    <= 1'b0;
        irq_sync_acquired<= 1'b0;
        irq_sync_lost    <= 1'b0;
        irq_crc_error    <= 1'b0;
        irq_rx_fifo_full <= 1'b0;
        dma_block_count  <= 16'd0;
        crc_error_count  <= 16'd0;
        sync_lost_count  <= 16'd0;
        repeat(4) @(posedge clk_axi);
        #1; rst_n <= 1'b1;
        repeat(2) @(posedge clk_axi);
    end
endtask

// ---------------------------------------------------------------------------
// Main Stimulus
// ---------------------------------------------------------------------------
integer tc;
reg [31:0] rd;
reg test_failed;

initial begin
    test_failed = 1'b0;
    tc = 0;
    do_reset;

    // -----------------------------------------------------------------------
    // TC01: SCRATCH — write 32'hDEAD_BEEF, read back
    // -----------------------------------------------------------------------
    tc = 1;
    axi_write(ADDR_SCRATCH, 32'hDEAD_BEEF, 4'hF);
    axi_read(ADDR_SCRATCH, rd);
    if (rd !== 32'hDEAD_BEEF) begin
        $fatal(1, "FAIL TC%0d: SCRATCH readback = %08h, expected DEADBEEF", tc, rd);
    end
    $display("PASS TC%0d: SCRATCH write/read DEADBEEF", tc);

    // -----------------------------------------------------------------------
    // TC02: CTRL — write 4'b0101 (RX_ENABLE + LOOPBACK_EN), check outputs
    // -----------------------------------------------------------------------
    tc = 2;
    axi_write(ADDR_CTRL, 32'h0000_0005, 4'hF); // bits [0]=1, [2]=1
    axi_read(ADDR_CTRL, rd);
    if (rd[3:0] !== 4'b0101) begin
        $fatal(1, "FAIL TC%0d: CTRL readback = %04b, expected 0101", tc, rd[3:0]);
    end
    if (ctrl_rx_enable !== 1'b1) begin
        $fatal(1, "FAIL TC%0d: ctrl_rx_enable = %b, expected 1", tc, ctrl_rx_enable);
    end
    if (ctrl_loopback_en !== 1'b1) begin
        $fatal(1, "FAIL TC%0d: ctrl_loopback_en = %b, expected 1", tc, ctrl_loopback_en);
    end
    if (ctrl_tx_enable !== 1'b0) begin
        $fatal(1, "FAIL TC%0d: ctrl_tx_enable = %b, expected 0", tc, ctrl_tx_enable);
    end
    $display("PASS TC%0d: CTRL write + output wire verification", tc);
    // restore CTRL
    axi_write(ADDR_CTRL, 32'h0, 4'hF);

    // -----------------------------------------------------------------------
    // TC03: VERSION — RO, write has no effect
    // -----------------------------------------------------------------------
    tc = 3;
    axi_read(ADDR_VERSION, rd);
    if (rd !== 32'h0001_0000) begin
        $fatal(1, "FAIL TC%0d: VERSION = %08h, expected 00010000", tc, rd);
    end
    axi_write(ADDR_VERSION, 32'hFFFF_FFFF, 4'hF); // write to RO
    axi_read(ADDR_VERSION, rd);
    if (rd !== 32'h0001_0000) begin
        $fatal(1, "FAIL TC%0d: VERSION changed after write: %08h", tc, rd);
    end
    $display("PASS TC%0d: VERSION is read-only 0x00010000", tc);

    // -----------------------------------------------------------------------
    // TC04: STATUS — drive live inputs, read STATUS
    // -----------------------------------------------------------------------
    tc = 4;
    sync_locked   = 1'b1;
    pll_locked    = 1'b1;
    rx_fifo_empty = 1'b0;
    rx_fifo_full  = 1'b1;
    slot_status   = 4'b1010;
    @(posedge clk_axi); @(posedge clk_axi);
    axi_read(ADDR_STATUS, rd);
    // STATUS[7:0] = {slot_status[3:0], fifo_full, fifo_empty, pll_locked, sync_locked}
    if (rd[0] !== 1'b1) $fatal(1, "FAIL TC%0d: STATUS[0]=SYNC_LOCKED not set", tc);
    if (rd[1] !== 1'b1) $fatal(1, "FAIL TC%0d: STATUS[1]=PLL_LOCKED not set", tc);
    if (rd[2] !== 1'b0) $fatal(1, "FAIL TC%0d: STATUS[2]=FIFO_EMPTY should be 0", tc);
    if (rd[3] !== 1'b1) $fatal(1, "FAIL TC%0d: STATUS[3]=FIFO_FULL not set", tc);
    if (rd[7:4] !== 4'b1010) $fatal(1, "FAIL TC%0d: STATUS[7:4]=SLOT_STATUS = %04b, expected 1010", tc, rd[7:4]);
    $display("PASS TC%0d: STATUS live inputs verified", tc);
    // restore
    sync_locked = 1'b0; pll_locked = 1'b0; rx_fifo_empty = 1'b1;
    rx_fifo_full = 1'b0; slot_status = 4'b0;
    @(posedge clk_axi);

    // -----------------------------------------------------------------------
    // TC05: SYNC_THRESH / COLOUR_CODE / RX_GAIN / TX_ATT — write all, read back
    // -----------------------------------------------------------------------
    tc = 5;
    axi_write(ADDR_SYNC_THRESH, 32'h0000_00AA, 4'hF);
    axi_write(ADDR_COLOUR_CODE, 32'h0000_001F, 4'hF); // 5'b11111 = 31
    axi_write(ADDR_RX_GAIN,     32'h0000_0055, 4'hF); // 7'h55 = 85 > 76, clamped by HW
    axi_write(ADDR_TX_ATT,      32'h0000_0059, 4'hF); // 89

    axi_read(ADDR_SYNC_THRESH, rd);
    if (rd[7:0] !== 8'hAA) $fatal(1,"FAIL TC%0d: SYNC_THRESH = %02h, expected AA", tc, rd[7:0]);

    axi_read(ADDR_COLOUR_CODE, rd);
    if (rd[5:0] !== 6'h1F) $fatal(1,"FAIL TC%0d: COLOUR_CODE = %02h, expected 1F", tc, rd[5:0]);

    axi_read(ADDR_RX_GAIN, rd);
    if (rd[6:0] !== 7'h55) $fatal(1,"FAIL TC%0d: RX_GAIN = %02h, expected 55", tc, rd[6:0]);

    axi_read(ADDR_TX_ATT, rd);
    if (rd[7:0] !== 8'h59) $fatal(1,"FAIL TC%0d: TX_ATT = %02h, expected 59", tc, rd[7:0]);

    // Verify output ports match
    if (sync_thresh  !== 8'hAA) $fatal(1,"FAIL TC%0d: sync_thresh output wrong", tc);
    if (colour_code  !== 6'h1F) $fatal(1,"FAIL TC%0d: colour_code output wrong", tc);
    if (rx_gain      !== 7'h55) $fatal(1,"FAIL TC%0d: rx_gain output wrong", tc);
    if (tx_att       !== 8'h59) $fatal(1,"FAIL TC%0d: tx_att output wrong", tc);
    $display("PASS TC%0d: SYNC_THRESH/COLOUR_CODE/RX_GAIN/TX_ATT write+read", tc);

    // -----------------------------------------------------------------------
    // TC06: IRQ — enable bit 0, fire irq_mac_block pulse, check status + irq_out
    // -----------------------------------------------------------------------
    tc = 6;
    axi_write(ADDR_IRQ_ENABLE, 32'h0000_0001, 4'hF); // enable IRQ_MAC_BLOCK_RDY
    // Fire hardware pulse for 1 cycle
    @(posedge clk_axi); #1; irq_mac_block = 1'b1;
    @(posedge clk_axi); #1; irq_mac_block = 1'b0;
    @(posedge clk_axi); @(posedge clk_axi); // let irq_out register update
    axi_read(ADDR_IRQ_STATUS, rd);
    if (rd[0] !== 1'b1) $fatal(1,"FAIL TC%0d: IRQ_STATUS[0] not set after pulse", tc);
    // irq_out should be high (registered)
    @(posedge clk_axi); // let irq_out register settle
    if (irq_out !== 1'b1) $fatal(1,"FAIL TC%0d: irq_out not asserted", tc);
    $display("PASS TC%0d: IRQ_ENABLE + IRQ_STATUS[0] set by hw pulse, irq_out=1", tc);

    // -----------------------------------------------------------------------
    // TC07: IRQ_STATUS W1C — write 1 to bit 0, verify cleared + irq_out=0
    // -----------------------------------------------------------------------
    tc = 7;
    axi_write(ADDR_IRQ_STATUS, 32'h0000_0001, 4'hF); // W1C bit 0
    @(posedge clk_axi); @(posedge clk_axi);
    axi_read(ADDR_IRQ_STATUS, rd);
    if (rd[0] !== 1'b0) $fatal(1,"FAIL TC%0d: IRQ_STATUS[0] not cleared after W1C", tc);
    @(posedge clk_axi);
    if (irq_out !== 1'b0) $fatal(1,"FAIL TC%0d: irq_out still asserted after W1C", tc);
    $display("PASS TC%0d: IRQ_STATUS W1C clears bit, irq_out=0", tc);

    // -----------------------------------------------------------------------
    // TC08: IRQ_STATUS HW wins — simultaneous pulse + W1C
    // Fire irq_mac_block pulse on the same clock edge as we issue W1C write
    // -----------------------------------------------------------------------
    tc = 8;
    // First set the bit via hw pulse so there's something to "clear"
    @(posedge clk_axi); #1; irq_mac_block = 1'b1;
    @(posedge clk_axi); #1; irq_mac_block = 1'b0;
    @(posedge clk_axi);

    // Now start W1C write and simultaneously assert irq_mac_block on the
    // same cycle the write enable fires.  To achieve this we start the write
    // transaction, then on the cycle wr_en fires (bvalid goes high) we
    // also have the hw pulse active for that cycle.
    // Easier approach: pulse hw while write is in-flight.
    @(posedge clk_axi); #1;
    awaddr  = ADDR_IRQ_STATUS;
    awvalid = 1'b1;
    wdata   = 32'h0000_0001; // W1C bit 0
    wstrb   = 4'hF;
    wvalid  = 1'b1;
    bready  = 1'b1;
    irq_mac_block = 1'b1; // hw pulse active

    // posedge: aw_latched and w_latched both latch here, wr_en still 0
    @(posedge clk_axi); #1;
    awvalid = 1'b0;
    wvalid  = 1'b0;
    // irq_mac_block stays 1 — wr_en fires on the NEXT posedge

    // posedge: wr_en fires (aw_latched & w_latched & !bvalid = 1)
    // irq_mac_block still 1 → hw_set=1, sw_clr=1 → hw wins, bit stays set
    @(posedge clk_axi); #1;
    irq_mac_block = 1'b0;

    // Wait for BVALID
    while (!bvalid) @(posedge clk_axi);
    @(posedge clk_axi); #1; bready = 1'b0;
    @(posedge clk_axi); @(posedge clk_axi);

    // Bit 0 should still be 1 because hw set wins
    axi_read(ADDR_IRQ_STATUS, rd);
    if (rd[0] !== 1'b1) begin
        $fatal(1,"FAIL TC%0d: IRQ_STATUS[0] should stay 1 when hw wins over W1C, got %0b", tc, rd[0]);
    end
    $display("PASS TC%0d: HW set wins over simultaneous SW W1C clear", tc);
    // Clean up: clear the bit
    axi_write(ADDR_IRQ_STATUS, 32'h0000_0001, 4'hF);
    axi_write(ADDR_IRQ_ENABLE, 32'h0000_0000, 4'hF);

    // -----------------------------------------------------------------------
    // TC09: FRAME_NUM / SLOT_NUM — RO registers, reflect live inputs
    // -----------------------------------------------------------------------
    tc = 9;
    frame_num = 5'd18;
    slot_num  = 2'd3;
    @(posedge clk_axi); @(posedge clk_axi);
    axi_read(ADDR_FRAME_NUM, rd);
    if (rd[4:0] !== 5'd18) $fatal(1,"FAIL TC%0d: FRAME_NUM = %0d, expected 18", tc, rd[4:0]);
    axi_read(ADDR_SLOT_NUM, rd);
    if (rd[1:0] !== 2'd3) $fatal(1,"FAIL TC%0d: SLOT_NUM = %0d, expected 3", tc, rd[1:0]);
    // Verify RO — write has no effect
    axi_write(ADDR_FRAME_NUM, 32'hFFFF_FFFF, 4'hF);
    axi_read(ADDR_FRAME_NUM, rd);
    if (rd[4:0] !== 5'd18) $fatal(1,"FAIL TC%0d: FRAME_NUM changed after write", tc);
    $display("PASS TC%0d: FRAME_NUM=18, SLOT_NUM=3, both read-only", tc);

    // -----------------------------------------------------------------------
    // TC10: DMA_BLOCK_COUNT / CRC_ERROR_COUNT / SYNC_LOST_COUNT — RO counters
    // -----------------------------------------------------------------------
    tc = 10;
    dma_block_count = 16'd1234;
    crc_error_count = 16'd56;
    sync_lost_count = 16'd7;
    @(posedge clk_axi); @(posedge clk_axi);
    axi_read(ADDR_DMA_BLK_CNT, rd);
    if (rd[15:0] !== 16'd1234) $fatal(1,"FAIL TC%0d: DMA_BLK_CNT = %0d, expected 1234", tc, rd[15:0]);
    axi_read(ADDR_CRC_ERR_CNT, rd);
    if (rd[15:0] !== 16'd56)   $fatal(1,"FAIL TC%0d: CRC_ERR_CNT = %0d, expected 56", tc, rd[15:0]);
    axi_read(ADDR_SYNC_LST_CNT, rd);
    if (rd[15:0] !== 16'd7)    $fatal(1,"FAIL TC%0d: SYNC_LST_CNT = %0d, expected 7", tc, rd[15:0]);
    $display("PASS TC%0d: DMA_BLOCK_COUNT=1234, CRC_ERR=56, SYNC_LOST=7", tc);

    // -----------------------------------------------------------------------
    // All tests passed
    // -----------------------------------------------------------------------
    repeat(4) @(posedge clk_axi);
    $display("=========================================");
    $display("tb_tetra_axi_lite_regs: ALL 10 TCs PASS");
    $display("=========================================");
    $finish;
end

// Watchdog
initial begin
    #1_000_000;
    $fatal(1, "WATCHDOG: simulation timeout");
end

endmodule

`default_nettype wire
