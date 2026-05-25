// =============================================================================
// Module: tetra_system_top
// Project: tetra-zynq-phy
// File: rtl/tetra_system_top.v
//
// Description:
// Physical Top Level — LibreSDR Board (Zynq-7020 + AD9361)
//
// This file is the synthesizable top module that Vivado sees.
// It contains all board-level I/O and instantiates the BD-generated
// wrapper (tetra_system_wrapper), which contains:
// - Zynq PS7 (DDR, MIO, SPI0, I2C0, UART0, FCLK_CLK0/1)
// - proc_sys_reset
// - axi_ad9361 (ADI IP — handles AD9361 LVDS DDR I/O)
// - Xilinx AXI DMA (S2MM RX path)
// - AXI Interconnects (GP0 → ctrl, HP0 ← DMA)
// - tetra_zynq_top (our PL design, as BD module reference)
//
// Modeled after OpenWifi's system_top.v for LibreSDR.
//
// Hardware:
// LibreSDR board with Zynq-7020 XC7Z020-CLG484 + AD9361 RF Transceiver
//
// Board-level responsibilities:
// - IOBUF instantiation for bidirectional AD9361 GPIO signals
// - GPIO bit routing to/from PS EMIO (enable, txnrx, resetb, etc.)
// - LED assignment from PS GPIO outputs
// - All other signals passed through to the BD wrapper
//
// Pin mapping (from libresdr/system.xdc — verified working with OpenWifi):
// GPIO_O[47] → up_enable → AD9361 ENABLE pin
// GPIO_O[48] → up_txnrx → AD9361 TXNRX pin
// GPIO[46] ↔ gpio_resetb
// GPIO[45] ↔ gpio_sync
// GPIO[44] ↔ gpio_en_agc
// GPIO[43:40] ↔ gpio_ctl[3:0]
// GPIO_I[39:32] ← gpio_status[7:0]
// GPIO_O[20] → pl_led0
// GPIO_O[22] → pl_led1
//
// References:
// libresdr/system_top.v — OpenWifi physical top (adaptation basis)
// libresdr/system.xdc — Board pin constraints
// =============================================================================

`timescale 1ns/100ps
`default_nettype none

module tetra_system_top (

 // -------------------------------------------------------------------------
 // DDR Interface (PS MIO-side, inout) — routed directly to PS7
 // -------------------------------------------------------------------------
 inout wire [14:0] ddr_addr,
 inout wire [ 2:0] ddr_ba,
 inout wire ddr_cas_n,
 inout wire ddr_ck_n,
 inout wire ddr_ck_p,
 inout wire ddr_cke,
 inout wire ddr_cs_n,
 inout wire [ 3:0] ddr_dm,
 inout wire [31:0] ddr_dq,
 inout wire [ 3:0] ddr_dqs_n,
 inout wire [ 3:0] ddr_dqs_p,
 inout wire ddr_odt,
 inout wire ddr_ras_n,
 inout wire ddr_reset_n,
 inout wire ddr_we_n,

 // -------------------------------------------------------------------------
 // Fixed I/O (MIO, PS power/clock)
 // -------------------------------------------------------------------------
 inout wire fixed_io_ddr_vrn,
 inout wire fixed_io_ddr_vrp,
 inout wire [53:0] fixed_io_mio,
 inout wire fixed_io_ps_clk,
 inout wire fixed_io_ps_porb,
 inout wire fixed_io_ps_srstb,

 // -------------------------------------------------------------------------
 // I2C (AD9361 control, PS I2C0 via EMIO)
 // -------------------------------------------------------------------------
 inout wire iic_scl,
 inout wire iic_sda,

 // -------------------------------------------------------------------------
 // AD9361 LVDS Interface — routed to axi_ad9361 IP in Block Design
 // Pin assignments from libresdr/system.xdc (verified on hardware)
 // -------------------------------------------------------------------------
 input wire rx_clk_in_p,
 input wire rx_clk_in_n,
 input wire rx_frame_in_p,
 input wire rx_frame_in_n,
 input wire [ 5:0] rx_data_in_p,
 input wire [ 5:0] rx_data_in_n,
 output wire tx_clk_out_p,
 output wire tx_clk_out_n,
 output wire tx_frame_out_p,
 output wire tx_frame_out_n,
 output wire [ 5:0] tx_data_out_p,
 output wire [ 5:0] tx_data_out_n,

 // -------------------------------------------------------------------------
 // AD9361 Control (from PS GPIO via EMIO)
 // -------------------------------------------------------------------------
 output wire enable, // AD9361 ENABLE — driven by PS GPIO_O[47]
 output wire txnrx, // AD9361 TXNRX — driven by PS GPIO_O[48]

 // -------------------------------------------------------------------------
 // AD9361 GPIO (bidirectional via EMIO, requires IOBUF)
 // -------------------------------------------------------------------------
 inout wire gpio_resetb, // GPIO[46] — active-low reset for AD9361
 inout wire gpio_sync, // GPIO[45] — sync input
 inout wire gpio_en_agc, // GPIO[44] — AGC enable
 inout wire [ 3:0] gpio_ctl, // GPIO[43:40] — control bits
 input wire [ 7:0] gpio_status, // GPIO_I[39:32] — AD9361 status (input only)

 // -------------------------------------------------------------------------
 // SPI (AD9361 register configuration — PS SPI0 via EMIO)
 // The BD wrapper exposes SPI0 as inout (EMIO IOBUF inside wrapper).
 // -------------------------------------------------------------------------
 inout wire spi_csn,
 inout wire spi_clk,
 inout wire spi_mosi,
 inout wire spi_miso,

 // -------------------------------------------------------------------------
 // LEDs (PL-controlled via PS GPIO EMIO)
 // -------------------------------------------------------------------------
 output wire pl_led0, // GPIO_O[20]
 output wire pl_led1, // GPIO_O[22]

 // -------------------------------------------------------------------------
 // DAC5311 SPI (VCXO 40 MHz tuning — PS GPIO EMIO bitbang)
 // CS/CLK/DIN are pure outputs; driven from Linux sysfs gpio 1011/1012/1013
 // -------------------------------------------------------------------------
 output wire dac_sync, // GPIO_O[51] — SPI chip-select (active low)
 output wire dac_sclk, // GPIO_O[52] — SPI clock
 output wire dac_din // GPIO_O[53] — SPI data in
);

// =============================================================================
// Internal wires — GPIO bus from PS EMIO (64-bit)
// =============================================================================

wire [63:0] gpio_i; // GPIO inputs → PS
wire [63:0] gpio_o; // GPIO outputs ← PS
wire [63:0] gpio_t; // GPIO tristate ← PS (1=input, 0=output)

// =============================================================================
// LED outputs from PS GPIO
// =============================================================================

assign pl_led0 = gpio_o[20];
assign pl_led1 = gpio_o[22];

// =============================================================================
// AD9361 control lines — driven from PS GPIO EMIO outputs
// (These are unidirectional outputs, no IOBUF needed)
// =============================================================================

assign enable = gpio_o[47];
assign txnrx = gpio_o[48];

// =============================================================================
// GPIO passthrough — unconnected upper bits loop back to keep PS happy
// =============================================================================

assign gpio_i[63:54] = gpio_o[63:54];
assign gpio_i[53:51] = gpio_o[53:51]; // DAC5311 bits — loopback so PS can readback
assign gpio_i[50:49] = gpio_o[50:49];

// DAC5311 SPI outputs — driven by PS GPIO EMIO bitbang (Linux sysfs)
// EMIO[51]=gpio1011=CS, EMIO[52]=gpio1012=CLK, EMIO[53]=gpio1013=DIN
assign dac_sync = gpio_o[51];
assign dac_sclk = gpio_o[52];
assign dac_din = gpio_o[53];
// gpio_i[48:47] driven by the PS (enable/txnrx are outputs, not loopback)

// =============================================================================
// AD9361 Status inputs (GPIO_I[39:32]) — direct input, no IOBUF
// =============================================================================

assign gpio_i[39:32] = gpio_status;

// =============================================================================
// AD9361 Bidirectional GPIO — IOBUF instances
//
// Bit mapping (matches OpenWifi system_top.v convention):
// GPIO[46] ↔ gpio_resetb
// GPIO[45] ↔ gpio_sync
// GPIO[44] ↔ gpio_en_agc
// GPIO[43] ↔ gpio_ctl[3]
// GPIO[42] ↔ gpio_ctl[2]
// GPIO[41] ↔ gpio_ctl[1]
// GPIO[40] ↔ gpio_ctl[0]
// =============================================================================

IOBUF u_iobuf_resetb (
.I (gpio_o[46]),
.T (gpio_t[46]),
.O (gpio_i[46]),
.IO (gpio_resetb)
);

IOBUF u_iobuf_sync (
.I (gpio_o[45]),
.T (gpio_t[45]),
.O (gpio_i[45]),
.IO (gpio_sync)
);

IOBUF u_iobuf_en_agc (
.I (gpio_o[44]),
.T (gpio_t[44]),
.O (gpio_i[44]),
.IO (gpio_en_agc)
);

IOBUF u_iobuf_ctl3 (
.I (gpio_o[43]),
.T (gpio_t[43]),
.O (gpio_i[43]),
.IO (gpio_ctl[3])
);

IOBUF u_iobuf_ctl2 (
.I (gpio_o[42]),
.T (gpio_t[42]),
.O (gpio_i[42]),
.IO (gpio_ctl[2])
);

IOBUF u_iobuf_ctl1 (
.I (gpio_o[41]),
.T (gpio_t[41]),
.O (gpio_i[41]),
.IO (gpio_ctl[1])
);

IOBUF u_iobuf_ctl0 (
.I (gpio_o[40]),
.T (gpio_t[40]),
.O (gpio_i[40]),
.IO (gpio_ctl[0])
);

// Remaining bidirectional range [46:32] — bits [31:0] are PS-managed,
// bits [48:47] are unidirectional outputs, upper bits loop back.
assign gpio_i[31:0] = gpio_o[31:0]; // lower 32 MIO-mapped bits loop back

// =============================================================================
// Block Design Wrapper — instantiated by Vivado after BD generation
// (tetra_system_wrapper.v is auto-generated by:
// create_wrapper -files [get_files tetra_system.bd] -top)
// =============================================================================

tetra_system_wrapper i_tetra_system_wrapper (

 // DDR — Vivado wrapper uses uppercase DDR_* names
.DDR_addr (ddr_addr),
.DDR_ba (ddr_ba),
.DDR_cas_n (ddr_cas_n),
.DDR_ck_n (ddr_ck_n),
.DDR_ck_p (ddr_ck_p),
.DDR_cke (ddr_cke),
.DDR_cs_n (ddr_cs_n),
.DDR_dm (ddr_dm),
.DDR_dq (ddr_dq),
.DDR_dqs_n (ddr_dqs_n),
.DDR_dqs_p (ddr_dqs_p),
.DDR_odt (ddr_odt),
.DDR_ras_n (ddr_ras_n),
.DDR_reset_n (ddr_reset_n),
.DDR_we_n (ddr_we_n),

 // Fixed IO — Vivado wrapper uses uppercase FIXED_IO_* names
.FIXED_IO_ddr_vrn (fixed_io_ddr_vrn),
.FIXED_IO_ddr_vrp (fixed_io_ddr_vrp),
.FIXED_IO_mio (fixed_io_mio),
.FIXED_IO_ps_clk (fixed_io_ps_clk),
.FIXED_IO_ps_porb (fixed_io_ps_porb),
.FIXED_IO_ps_srstb(fixed_io_ps_srstb),

 // IIC — wrapper IOBUF inside, exposes *_io port
.iic_main_scl_io (iic_scl),
.iic_main_sda_io (iic_sda),

 // AD9361 LVDS — wrapper appends _0 suffix to pin names
.rx_clk_in_p_0 (rx_clk_in_p),
.rx_clk_in_n_0 (rx_clk_in_n),
.rx_frame_in_p_0 (rx_frame_in_p),
.rx_frame_in_n_0 (rx_frame_in_n),
.rx_data_in_p_0 (rx_data_in_p),
.rx_data_in_n_0 (rx_data_in_n),
.tx_clk_out_p_0 (tx_clk_out_p),
.tx_clk_out_n_0 (tx_clk_out_n),
.tx_frame_out_p_0 (tx_frame_out_p),
.tx_frame_out_n_0 (tx_frame_out_n),
.tx_data_out_p_0 (tx_data_out_p),
.tx_data_out_n_0 (tx_data_out_n),

 // SPI — wrapper uses SPI_0_0_*_io (IOBUF inside wrapper)
.SPI_0_0_sck_io (spi_clk),
.SPI_0_0_ss_io (spi_csn),
.SPI_0_0_ss1_o (),
.SPI_0_0_ss2_o (),
.SPI_0_0_io0_io (spi_mosi),
.SPI_0_0_io1_io (spi_miso),

 // GPIO EMIO (64-bit)
.gpio_i (gpio_i),
.gpio_o (gpio_o),
.gpio_t (gpio_t),

 // AD9361 GPIO status input
.gpio_status (gpio_status),

 // up_enable / up_txnrx — AD9361 mode control from PS GPIO
.up_enable (gpio_o[47]),
.up_txnrx (gpio_o[48])
);

endmodule

// =============================================================================
// End of tetra_system_top.v
// =============================================================================
