// =============================================================================
// Testbench: tb_tetra_ad9361_axis_adapter
// Module under test: rtl/tetra_ad9361_axis_adapter.v
//
// Tests:
//   TC1 — RX combinational passthrough: adc_data_i0/q0/valid → rx_i/q/valid
//   TC2 — TX register: tx_i/q captured on tx_valid_lvds rising edge
//   TC3 — TX hold: dac_data_i0/q0 hold last value when tx_valid_lvds = 0
//   TC4 — Reset: all outputs clear to zero on rst_n_lvds deassertion
//   TC5 — dac_valid_i0/dac_enable_i0 are IP inputs, not gating TX data
//   TC6 — RX sign extension: negative samples pass through correctly
//   TC7 — Rapid TX updates: multiple valid pulses in consecutive cycles
//
// Pass criterion: 0 errors, all 7 test cases PASS.
// Waveform: tb_tetra_ad9361_axis_adapter.vcd
// =============================================================================

`timescale 1ns / 1ps

module tb_tetra_ad9361_axis_adapter;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam IQ_WIDTH   = 16;
localparam CLK_PERIOD = 10;   // 100 MHz (represents l_clk DATA_CLK from axi_ad9361)

// ---------------------------------------------------------------------------
// DUT signals — matching axi_ad9361 IP fabric interface (per XCI boundary)
// ---------------------------------------------------------------------------
// DATA_CLK — single clock for ADC + DAC (IP port: l_clk)
reg                         l_clk;

// ADC (IP → fabric)
reg                         adc_valid_i0;
reg  [IQ_WIDTH-1:0]         adc_data_i0;
reg                         adc_enable_i0;
reg                         adc_valid_q0;      // Q0 valid (parallel with I0)
reg  [IQ_WIDTH-1:0]         adc_data_q0;
reg                         adc_enable_q0;

// DAC (IP outputs, fabric provides data)
reg                         dac_valid_i0;      // IP output: I0 data requested
reg                         dac_enable_i0;     // IP output: I0 path active
reg                         dac_valid_q0;      // IP output: Q0 data requested
reg                         dac_enable_q0;     // IP output: Q0 path active
wire [IQ_WIDTH-1:0]         dac_data_i0;       // fabric → IP I0
wire [IQ_WIDTH-1:0]         dac_data_q0;       // fabric → IP Q0

reg                         rst_n_lvds;

wire                        clk_lvds;
wire signed [IQ_WIDTH-1:0]  rx_i_lvds;
wire signed [IQ_WIDTH-1:0]  rx_q_lvds;
wire                        rx_valid_lvds;

reg  signed [IQ_WIDTH-1:0]  tx_i_lvds;
reg  signed [IQ_WIDTH-1:0]  tx_q_lvds;
reg                         tx_valid_lvds;

// ---------------------------------------------------------------------------
// Error counter
// ---------------------------------------------------------------------------
integer err_cnt;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
tetra_ad9361_axis_adapter #(
    .IQ_WIDTH(IQ_WIDTH)
) dut (
    // DATA_CLK
    .l_clk         (l_clk),
    // ADC fabric interface
    .adc_valid_i0  (adc_valid_i0),
    .adc_data_i0   (adc_data_i0),
    .adc_enable_i0 (adc_enable_i0),
    .adc_valid_q0  (adc_valid_q0),
    .adc_data_q0   (adc_data_q0),
    .adc_enable_q0 (adc_enable_q0),
    // DAC fabric interface
    .dac_valid_i0  (dac_valid_i0),
    .dac_enable_i0 (dac_enable_i0),
    .dac_valid_q0  (dac_valid_q0),
    .dac_enable_q0 (dac_enable_q0),
    .dac_data_i0   (dac_data_i0),
    .dac_data_q0   (dac_data_q0),
    // Reset + tetra interface
    .rst_n_lvds    (rst_n_lvds),
    .clk_lvds      (clk_lvds),
    .rx_i_lvds     (rx_i_lvds),
    .rx_q_lvds     (rx_q_lvds),
    .rx_valid_lvds (rx_valid_lvds),
    .tx_i_lvds     (tx_i_lvds),
    .tx_q_lvds     (tx_q_lvds),
    .tx_valid_lvds (tx_valid_lvds)
);

// ---------------------------------------------------------------------------
// Clock generation — l_clk models axi_ad9361.l_clk (DATA_CLK)
// Both ADC and DAC fabric interfaces are clocked by this single source.
// ---------------------------------------------------------------------------
initial l_clk = 1'b0;
always  #(CLK_PERIOD/2) l_clk = ~l_clk;

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_tetra_ad9361_axis_adapter.vcd");
    $dumpvars(0, tb_tetra_ad9361_axis_adapter);
end

// ---------------------------------------------------------------------------
// Helper tasks
// ---------------------------------------------------------------------------

task check16;
    input signed [15:0] got;
    input signed [15:0] expected;
    input [127:0]       test_name;
    begin
        if (got !== expected) begin
            $display("FAIL [%0s]: got=%0d (0x%04X) expected=%0d (0x%04X)",
                     test_name, got, got, expected, expected);
            err_cnt = err_cnt + 1;
        end
    end
endtask

task check1;
    input        got;
    input        expected;
    input [127:0] test_name;
    begin
        if (got !== expected) begin
            $display("FAIL [%0s]: got=%0b expected=%0b",
                     test_name, got, expected);
            err_cnt = err_cnt + 1;
        end
    end
endtask

// Positive clock edge + small delta
task posedge_clk;
    begin
        @(posedge l_clk);
        #1;
    end
endtask

// ---------------------------------------------------------------------------
// Main test sequence
// ---------------------------------------------------------------------------
initial begin : test_main
    // Initial state
    err_cnt        = 0;
    adc_valid_i0   = 1'b0;
    adc_data_i0    = {IQ_WIDTH{1'b0}};
    adc_enable_i0  = 1'b0;
    adc_valid_q0   = 1'b0;
    adc_data_q0    = {IQ_WIDTH{1'b0}};
    adc_enable_q0  = 1'b0;
    dac_valid_i0   = 1'b0;
    dac_enable_i0  = 1'b0;
    dac_valid_q0   = 1'b0;
    dac_enable_q0  = 1'b0;
    tx_i_lvds      = {IQ_WIDTH{1'b0}};
    tx_q_lvds      = {IQ_WIDTH{1'b0}};
    tx_valid_lvds  = 1'b0;
    rst_n_lvds     = 1'b0;

    // -----------------------------------------------------------------------
    // TC4 — Reset: dac_data_i0/q0 are zero while rst_n_lvds = 0
    //        RX path is combinational so it passes data even during reset.
    // -----------------------------------------------------------------------
    $display("TC4: Reset behaviour");
    repeat(4) @(posedge l_clk);  // wait while rst_n_lvds=0
    #1;
    adc_data_i0   = 16'hDEAD;
    adc_data_q0   = 16'hBEEF;
    adc_valid_i0  = 1'b1;
    #1;
    // TX registers should be zero (reset)
    check16($signed(dac_data_i0), 16'sh0, "TC4-dac_i_reset");
    check16($signed(dac_data_q0), 16'sh0, "TC4-dac_q_reset");

    adc_valid_i0  = 1'b0;
    adc_data_i0   = {IQ_WIDTH{1'b0}};
    adc_data_q0   = {IQ_WIDTH{1'b0}};

    // Release reset
    @(negedge l_clk);
    rst_n_lvds = 1'b1;
    @(posedge l_clk);
    #1;

    // -----------------------------------------------------------------------
    // TC5 — dac_valid_i0 / dac_enable_i0 are IP inputs; toggling them does
    //        not affect dac_data_i0/q0 output (hold behaviour still active)
    // -----------------------------------------------------------------------
    $display("TC5: dac_valid_i0/enable_i0 are IP inputs — do not gate TX data");
    begin : tc5
        reg signed [15:0] hold_i, hold_q;
        // Load a known value via tx_valid_lvds
        tx_i_lvds     = 16'sh1234;
        tx_q_lvds     = 16'sh5678;
        tx_valid_lvds = 1'b1;
        posedge_clk;
        tx_valid_lvds = 1'b0;
        hold_i = $signed(dac_data_i0);
        hold_q = $signed(dac_data_q0);
        check16(hold_i, 16'sh1234, "TC5-load-i");
        check16(hold_q, 16'sh5678, "TC5-load-q");

        // Toggle dac_valid_i0 and dac_enable_i0 — data should remain held
        dac_valid_i0  = 1'b1;
        dac_enable_i0 = 1'b1;
        repeat(3) begin
            posedge_clk;
            check16($signed(dac_data_i0), hold_i, "TC5-hold-i");
            check16($signed(dac_data_q0), hold_q, "TC5-hold-q");
        end
        dac_valid_i0  = 1'b0;
        dac_enable_i0 = 1'b0;
    end

    // -----------------------------------------------------------------------
    // TC1 — RX combinational passthrough (positive samples)
    // -----------------------------------------------------------------------
    $display("TC1: RX combinational passthrough (positive)");
    begin : tc1
        // Apply known I=0x1234, Q=0x5678 on separate buses
        adc_data_i0  = 16'h1234;
        adc_data_q0  = 16'h5678;
        adc_valid_i0 = 1'b1;
        #1; // combinational — no clock edge needed

        check16(rx_i_lvds, $signed(16'h1234), "TC1-rx_i");
        check16(rx_q_lvds, $signed(16'h5678), "TC1-rx_q");
        check1(rx_valid_lvds, 1'b1, "TC1-rx_valid");
        check1(clk_lvds, l_clk, "TC1-clk_lvds");  // clk_lvds = l_clk passthrough
    end

    adc_valid_i0 = 1'b0;
    #1;
    check1(rx_valid_lvds, 1'b0, "TC1-valid-deasserted");

    // -----------------------------------------------------------------------
    // TC6 — RX sign extension: negative samples
    // -----------------------------------------------------------------------
    $display("TC6: RX sign extension (negative samples)");
    begin : tc6
        // I = -1 = 0xFFFF, Q = -256 = 0xFF00
        adc_data_i0  = 16'hFFFF;
        adc_data_q0  = 16'hFF00;
        adc_valid_i0 = 1'b1;
        #1;

        check16(rx_i_lvds, -16'sd1,   "TC6-rx_i_neg");
        check16(rx_q_lvds, -16'sd256, "TC6-rx_q_neg");

        adc_valid_i0 = 1'b0;
        adc_data_i0  = {IQ_WIDTH{1'b0}};
        adc_data_q0  = {IQ_WIDTH{1'b0}};
    end

    // -----------------------------------------------------------------------
    // TC2 — TX register: I and Q captured separately on tx_valid_lvds
    // -----------------------------------------------------------------------
    $display("TC2: TX register — separate I and Q capture on tx_valid_lvds");
    begin : tc2
        tx_i_lvds     = 16'shABCD;
        tx_q_lvds     = 16'sh1357;
        tx_valid_lvds = 1'b1;
        posedge_clk;   // rising edge captures

        check16($signed(dac_data_i0), 16'shABCD, "TC2-dac_i_captured");
        check16($signed(dac_data_q0), 16'sh1357, "TC2-dac_q_captured");

        tx_valid_lvds = 1'b0;
    end

    // -----------------------------------------------------------------------
    // TC3 — TX hold: dac_data_i0/q0 hold last values when tx_valid = 0
    // -----------------------------------------------------------------------
    $display("TC3: TX hold — last I and Q retained independently");
    begin : tc3
        reg signed [15:0] held_i, held_q;
        held_i = $signed(dac_data_i0);
        held_q = $signed(dac_data_q0);

        // Apply different I/Q but DON'T assert tx_valid_lvds
        tx_i_lvds     = 16'sh1111;
        tx_q_lvds     = 16'sh2222;
        tx_valid_lvds = 1'b0;

        repeat(5) begin
            posedge_clk;
            check16($signed(dac_data_i0), held_i, "TC3-hold-i");
            check16($signed(dac_data_q0), held_q, "TC3-hold-q");
        end
    end

    // -----------------------------------------------------------------------
    // TC7 — Rapid TX updates: consecutive valid cycles
    // -----------------------------------------------------------------------
    $display("TC7: Rapid TX updates (consecutive valid pulses)");
    begin : tc7
        integer i;
        reg signed [15:0] exp_i, exp_q;

        for (i = 0; i < 8; i = i + 1) begin
            exp_i = $signed(i * 16'h0100);
            exp_q = $signed(~(i * 16'h0100));
            tx_i_lvds     = exp_i;
            tx_q_lvds     = exp_q;
            tx_valid_lvds = 1'b1;
            posedge_clk;
            check16($signed(dac_data_i0), exp_i, "TC7-rapid-i");
            check16($signed(dac_data_q0), exp_q, "TC7-rapid-q");
        end
        tx_valid_lvds = 1'b0;
    end

    // -----------------------------------------------------------------------
    // Final report
    // -----------------------------------------------------------------------
    $display("");
    if (err_cnt == 0)
        $display("RESULT: PASS — 0 errors");
    else
        $display("RESULT: FAIL — %0d error(s)", err_cnt);

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #200000;
    $display("TIMEOUT: simulation exceeded 200 us");
    $finish;
end

endmodule
