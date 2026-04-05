# =============================================================================
# create_bd.tcl — Vivado Block Design for tetra-zynq-phy
# Project: tetra-zynq-phy
# Target:  LibreSDR (Zynq-7020 XC7Z020-CLG400 + AD9361)
# Tool:    Vivado 2022.2
#
# Usage (called from vivado_build.tcl after adding RTL sources):
#   source scripts/create_bd.tcl
#
# Prerequisites:
#   1. Vivado project must already be open
#   2. All RTL sources (rtl/**/*.v) must already be added via add_files
#   3. ADI HDL library must be in IP repo path (set ADI_HDL_DIR below)
#      OR the libresdr XCI directory is used as fallback IP reference
#
# Block Design Contents:
#   sys_ps7       — Zynq-7020 PS7 (DDR/MIO/SPI0/I2C0/FCLK/HP0/GP0/IRQ)
#   sys_rstgen    — proc_sys_reset (100 MHz domain)
#   axi_ad9361    — ADI AD9361 LVDS IP (2R2T MIMO, LVDS DDR)
#   axi_dma       — Xilinx AXI DMA 7.1 (S2MM 32-bit for LMAC→DDR)
#   axi_ic_ctrl   — AXI Interconnect (PS GP0 → tetra AXI-Lite + DMA ctrl)
#   axi_ic_hp0    — AXI Interconnect (DMA M_AXI → PS HP0)
#   tetra_zynq_top_0 — Our PL design (module reference)
#
# Address Map (GP0 aperture 0x4000_0000–0x7FFF_FFFF):
#   0x43C0_0000  tetra_zynq_top AXI-Lite (64 KB)
#   0x4040_0000  AXI DMA control (64 KB)
#   0x7902_0000  axi_ad9361 register space (64 KB)
#
# Data Path:
#   AD9361 LVDS → axi_ad9361 → l_clk/adc_* → tetra_zynq_top_0
#   tetra_zynq_top_0.m_axis → axi_dma.S_AXIS_S2MM → HP0 → PS DDR
#   PS GP0 → axi_ic_ctrl → tetra_zynq_top_0.s_axi (control)
#   PS GP0 → axi_ic_ctrl → axi_dma.S_AXI_LITE (DMA control)
#
# References:
#   libresdr/system.bd       — OpenWifi BD (structure reference)
#   libresdr/system_top.v    — Physical top reference
#   libresdr/ip/             — Pre-configured XCI files (ADI IPs)
# =============================================================================

set PROJ_DIR [file dirname [file dirname [info script]]]
set LIBRESDR_DIR "$PROJ_DIR/libresdr"

# =============================================================================
# ADI IP Repository
# =============================================================================
# The axi_ad9361 IP (analog.com:user:axi_ad9361:1.0) is part of the ADI HDL library.
# If you have it installed, set ADI_HDL_DIR to the hdl/library path:
#   e.g. /opt/Xilinx/adi/hdl/library
# If not set / not found, the script uses the libresdr project IP cache instead.

if {![info exists ADI_HDL_DIR]} {
    set ADI_HDL_DIR ""
}

# Try to find ADI HDL in common install locations if not set
if {$ADI_HDL_DIR eq "" || ![file exists $ADI_HDL_DIR]} {
    foreach candidate [list \
        "$::env(HOME)/openwifi/openwifi-hw/adi-hdl/library" \
        "$::env(HOME)/openwifi/openwifi-hw/adi-hdl" \
        "/opt/adi/hdl/library" \
        "$::env(HOME)/hdl/library" \
        "/tools/adi/hdl/library" \
    ] {
        if {[file exists $candidate]} {
            set ADI_HDL_DIR $candidate
            puts "  Found ADI HDL at: $ADI_HDL_DIR"
            break
        }
    }
}

# Add IP repo paths to project
set ip_repo_list [list]

if {$ADI_HDL_DIR ne "" && [file exists $ADI_HDL_DIR]} {
    lappend ip_repo_list $ADI_HDL_DIR
    puts "  Using ADI HDL library: $ADI_HDL_DIR"
} else {
    # Fallback: use the libresdr project IP cache (pre-built XCIs)
    set libresdr_ip_dir "$LIBRESDR_DIR/ip"
    if {[file exists $libresdr_ip_dir]} {
        lappend ip_repo_list $libresdr_ip_dir
        puts "  Using libresdr pre-built IP cache: $libresdr_ip_dir"
    } else {
        puts "  WARNING: ADI_HDL_DIR not found and libresdr IP cache missing."
        puts "  Set ADI_HDL_DIR=/path/to/adi/hdl/library and re-run."
    }
}

if {[llength $ip_repo_list] > 0} {
    set_property ip_repo_paths $ip_repo_list [current_project]
    update_ip_catalog -rebuild
}

# =============================================================================
# Create Block Design
# =============================================================================

puts "\n=== Creating Block Design: tetra_system ==="

create_bd_design "tetra_system"
current_bd_design [get_bd_designs tetra_system]

# =============================================================================
# PS7 — Zynq Processing System
# =============================================================================
# Configuration based on LibreSDR XCI (libresdr/ip/system_sys_ps7_0/system_sys_ps7_0.xci)
# Key settings: FCLK0=100MHz, FCLK1=200MHz (for IDELAYCTRL), SPI0 EMIO,
#               I2C0 EMIO, HP0 AXI, GP0 AXI, 64-bit EMIO GPIO, IRQ F2P

puts "  Creating PS7..."
set sys_ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 sys_ps7]

set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0                {1} \
    CONFIG.PCW_USE_S_AXI_HP0                {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH         {64} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT         {1} \
    CONFIG.PCW_IRQ_F2P_INTR                 {1} \
    CONFIG.PCW_APU_CLK_RATIO_ENABLE         {6:2:1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ     {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ     {200} \
    CONFIG.PCW_EN_CLK0_PORT                 {1} \
    CONFIG.PCW_EN_CLK1_PORT                 {1} \
    CONFIG.PCW_EN_RST0_PORT                 {1} \
    CONFIG.PCW_FCLK_CLK0_BUF               {TRUE} \
    CONFIG.PCW_FCLK_CLK1_BUF               {TRUE} \
    CONFIG.PCW_SPI0_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_SPI0_SPI0_IO                 {EMIO} \
    CONFIG.PCW_I2C0_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_I2C0_I2C0_IO                 {EMIO} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE      {1} \
    CONFIG.PCW_UART0_UART0_IO               {MIO 14 .. 15} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE      {1} \
    CONFIG.PCW_ENET0_ENET0_IO               {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE        {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO            {MIO 52 .. 53} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE        {1} \
    CONFIG.PCW_SD0_SD0_IO                   {MIO 40 .. 45} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE         {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE        {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_IO            {64} \
    CONFIG.PCW_USE_HIGH_OCM                 {0} \
    CONFIG.PCW_TTC0_PERIPHERAL_ENABLE       {0} \
    CONFIG.PCW_WDT_PERIPHERAL_ENABLE        {0} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ         {534.0} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0  {0.048} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1  {0.050} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2  {0.249} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3  {0.249} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0     {0.241} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1     {0.240} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2     {0.216} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3     {0.217} \
] $sys_ps7

# =============================================================================
# proc_sys_reset — Reset Generator for 100 MHz domain
# =============================================================================

puts "  Creating proc_sys_reset..."
set sys_rstgen [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 sys_rstgen]

set_property -dict [list \
    CONFIG.C_EXT_RST_WIDTH  {1} \
    CONFIG.C_AUX_RST_WIDTH  {1} \
    CONFIG.C_NUM_BUS_RST    {1} \
    CONFIG.C_NUM_PERP_RST   {1} \
    CONFIG.C_NUM_INTERCONNECT_ARESETN {1} \
] $sys_rstgen

# =============================================================================
# axi_ad9361 — ADI AD9361 LVDS Interface IP
# =============================================================================
# Parameters from libresdr/ip/system_axi_ad9361_0/system_axi_ad9361_0.xci:
#   CMOS_OR_LVDS_N = 0 (LVDS)
#   MIMO_ENABLE = 1 (2R2T)
#   TDD_DISABLE = 1 (FDD mode for TETRA)
#   DAC_DDS_DISABLE = 1 (we provide our own DAC data)
#   ADC_INIT_DELAY = 30
#   USE_SSI_CLK = 1
#   DELAY_REFCLK_FREQUENCY = 200 (matches FCLK1)
#   IODELAY_CTRL = 1

puts "  Creating axi_ad9361..."
set axi_ad9361_0 [create_bd_cell -type ip -vlnv analog.com:user:axi_ad9361:1.0 axi_ad9361_0]

set_property -dict [list \
    CONFIG.ID                   {0} \
    CONFIG.MODE_1R1T            {0} \
    CONFIG.CMOS_OR_LVDS_N       {0} \
    CONFIG.MIMO_ENABLE          {1} \
    CONFIG.USE_SSI_CLK          {1} \
    CONFIG.TDD_DISABLE          {1} \
    CONFIG.ADC_INIT_DELAY       {30} \
    CONFIG.ADC_DATAPATH_DISABLE {0} \
    CONFIG.ADC_USERPORTS_DISABLE {0} \
    CONFIG.DAC_DDS_DISABLE      {1} \
    CONFIG.DAC_USERPORTS_DISABLE {0} \
    CONFIG.DAC_IODELAY_ENABLE   {0} \
    CONFIG.IODELAY_CTRL         {1} \
    CONFIG.DELAY_REFCLK_FREQUENCY {200} \
    CONFIG.IO_DELAY_GROUP       {dev_if_delay_group} \
] $axi_ad9361_0

# =============================================================================
# AXI DMA — Xilinx AXI Direct Memory Access
# =============================================================================
# S2MM (Stream→Memory): 32-bit, receives MAC blocks from tetra_zynq_top
# MM2S (Memory→Stream): 64-bit, reserved for future TX DMA path
# Scatter-Gather enabled for efficient large block transfers
# Data width: 32-bit stream (matches m_axis_tdata in tetra_axi_dma_bridge)

puts "  Creating AXI DMA..."
set axi_dma_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]

set_property -dict [list \
    CONFIG.c_include_sg             {1} \
    CONFIG.c_sg_length_width        {14} \
    CONFIG.c_include_mm2s           {0} \
    CONFIG.c_include_s2mm           {1} \
    CONFIG.c_m_axi_s2mm_data_width  {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_include_s2mm_dre       {1} \
    CONFIG.c_s2mm_burst_size        {256} \
    CONFIG.c_addr_width             {32} \
] $axi_dma_0

# =============================================================================
# AXI Interconnect — Control Path (PS GP0 → peripherals)
# =============================================================================
# 1 master (PS GP0), 3 slaves:
#   M00 → tetra_zynq_top AXI-Lite  (0x43C0_0000)
#   M01 → AXI DMA AXI-Lite         (0x4040_0000)
#   M02 → axi_ad9361 AXI config    (0x7902_0000)

puts "  Creating AXI control interconnect..."
set axi_ic_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ctrl]
set_property -dict [list \
    CONFIG.NUM_MI {3} \
    CONFIG.NUM_SI {1} \
] $axi_ic_ctrl

# =============================================================================
# AXI Interconnect — HP0 Data Path (DMA → PS HP0)
# =============================================================================
# 1 master (AXI DMA), 1 slave (PS HP0)

puts "  Creating AXI HP0 interconnect..."
set axi_ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
] $axi_ic_hp0

# =============================================================================
# tetra_zynq_top — Our TETRA PL Design (Module Reference)
# =============================================================================
# All RTL sources must be added to the project before this call.
# Vivado 2022.2 supports module references in Block Design:
#   create_bd_cell -type module -reference <module_name> <cell_name>

puts "  Creating tetra_zynq_top module reference..."
# Disable array-of-interfaces inference: prevents ADI library definitions
# (if_xcvr_cm, fifo_wr/fifo_rd) from matching our s_axi_* / adc_* port names.
# X_INTERFACE_INFO attributes on tetra_zynq_top ports take precedence, but
# this param ensures no array-of-interfaces wrapper is created for multi-bit ports.
set_param ips.enableInterfaceArrayInference false
set tetra_top [create_bd_cell -type module -reference tetra_zynq_top tetra_zynq_top_0]

# =============================================================================
# Interrupt Concatenation
# =============================================================================
# Collects IRQs from DMA and tetra_zynq_top, feeds PS IRQ_F2P[2:0]
#   IRQ_F2P[0] ← axi_dma_0.s2mm_introut
#   IRQ_F2P[1] ← tetra_zynq_top_0.o_irq

puts "  Creating IRQ concat..."
set xlconcat_irq [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
set_property CONFIG.NUM_PORTS {2} $xlconcat_irq

# =============================================================================
# Clock Connections
# =============================================================================

puts "  Connecting clocks..."

# FCLK_CLK0 (100 MHz) — system clock for all PL logic
connect_bd_net \
    [get_bd_pins sys_ps7/FCLK_CLK0] \
    [get_bd_pins sys_ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins sys_ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins sys_rstgen/slowest_sync_clk] \
    [get_bd_pins axi_ad9361_0/s_axi_aclk] \
    [get_bd_pins axi_ad9361_0/clk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins axi_dma_0/m_axi_sg_aclk] \
    [get_bd_pins axi_ic_ctrl/ACLK] \
    [get_bd_pins axi_ic_ctrl/S00_ACLK] \
    [get_bd_pins axi_ic_ctrl/M00_ACLK] \
    [get_bd_pins axi_ic_ctrl/M01_ACLK] \
    [get_bd_pins axi_ic_ctrl/M02_ACLK] \
    [get_bd_pins axi_ic_hp0/ACLK] \
    [get_bd_pins axi_ic_hp0/S00_ACLK] \
    [get_bd_pins axi_ic_hp0/S01_ACLK] \
    [get_bd_pins axi_ic_hp0/M00_ACLK] \
    [get_bd_pins tetra_zynq_top_0/i_clk] \
    [get_bd_pins tetra_zynq_top_0/s_axi_aclk]

# FCLK_CLK1 (200 MHz) — reference clock for axi_ad9361 IDELAYCTRL
connect_bd_net \
    [get_bd_pins sys_ps7/FCLK_CLK1] \
    [get_bd_pins axi_ad9361_0/delay_clk]

# =============================================================================
# Reset Connections
# =============================================================================

puts "  Connecting resets..."

# PS FCLK_RESET0_N → sys_rstgen input
connect_bd_net \
    [get_bd_pins sys_ps7/FCLK_RESET0_N] \
    [get_bd_pins sys_rstgen/ext_reset_in]

# sys_rstgen outputs → all peripherals
connect_bd_net \
    [get_bd_pins sys_rstgen/peripheral_aresetn] \
    [get_bd_pins tetra_zynq_top_0/i_arst_n] \
    [get_bd_pins axi_ad9361_0/s_axi_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins axi_ic_ctrl/S00_ARESETN] \
    [get_bd_pins axi_ic_ctrl/M00_ARESETN] \
    [get_bd_pins axi_ic_ctrl/M01_ARESETN] \
    [get_bd_pins axi_ic_ctrl/M02_ARESETN] \
    [get_bd_pins axi_ic_hp0/S00_ARESETN] \
    [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]

connect_bd_net \
    [get_bd_pins sys_rstgen/interconnect_aresetn] \
    [get_bd_pins axi_ic_ctrl/ARESETN] \
    [get_bd_pins axi_ic_hp0/ARESETN]

connect_bd_net \
    [get_bd_pins tetra_zynq_top_0/s_axi_aresetn] \
    [get_bd_pins sys_rstgen/peripheral_aresetn]

# =============================================================================
# axi_ad9361 ↔ tetra_zynq_top_0 IQ Data Connections
# =============================================================================

puts "  Connecting axi_ad9361 ↔ tetra_zynq_top..."

# DATA_CLK (l_clk) — master clock from axi_ad9361 IP
connect_bd_net \
    [get_bd_pins axi_ad9361_0/l_clk] \
    [get_bd_pins tetra_zynq_top_0/l_clk]

# ADC path: axi_ad9361 → tetra_zynq_top (axi_ad9361 drives all these)
connect_bd_net [get_bd_pins axi_ad9361_0/adc_valid_i0]  [get_bd_pins tetra_zynq_top_0/adc_valid_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_data_i0]   [get_bd_pins tetra_zynq_top_0/adc_data_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_enable_i0] [get_bd_pins tetra_zynq_top_0/adc_enable_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_valid_q0]  [get_bd_pins tetra_zynq_top_0/adc_valid_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_data_q0]   [get_bd_pins tetra_zynq_top_0/adc_data_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_enable_q0] [get_bd_pins tetra_zynq_top_0/adc_enable_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_r1_mode]   [get_bd_pins tetra_zynq_top_0/adc_r1_mode]

# ADC overflow from tetra_zynq_top → axi_ad9361 (tied to 0 in RTL)
connect_bd_net [get_bd_pins tetra_zynq_top_0/adc_dovf]  [get_bd_pins axi_ad9361_0/adc_dovf]

# DAC path: axi_ad9361 → tetra_zynq_top (enables/valids are IP outputs)
connect_bd_net [get_bd_pins axi_ad9361_0/dac_valid_i0]  [get_bd_pins tetra_zynq_top_0/dac_valid_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/dac_enable_i0] [get_bd_pins tetra_zynq_top_0/dac_enable_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/dac_valid_q0]  [get_bd_pins tetra_zynq_top_0/dac_valid_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/dac_enable_q0] [get_bd_pins tetra_zynq_top_0/dac_enable_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/dac_r1_mode]   [get_bd_pins tetra_zynq_top_0/dac_r1_mode]

# DAC data: tetra_zynq_top → axi_ad9361
connect_bd_net [get_bd_pins tetra_zynq_top_0/dac_data_i0] [get_bd_pins axi_ad9361_0/dac_data_i0]
connect_bd_net [get_bd_pins tetra_zynq_top_0/dac_data_q0] [get_bd_pins axi_ad9361_0/dac_data_q0]
connect_bd_net [get_bd_pins tetra_zynq_top_0/dac_dunf]    [get_bd_pins axi_ad9361_0/dac_dunf]

# AD9361 enable/txnrx: driven from PS GPIO via tetra_system_top (exported below)
# These come from GPIO_O[47:48] in tetra_system_top.v, not from the BD.
# axi_ad9361 internal up_enable/up_txnrx are controlled from its own AXI regs.

# =============================================================================
# AXI Control Interconnect (PS GP0 → peripherals)
# =============================================================================

puts "  Connecting AXI control path..."

# PS GP0 master → interconnect slave
connect_bd_intf_net \
    [get_bd_intf_pins sys_ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_ctrl/S00_AXI]

# M00 → tetra_zynq_top AXI-Lite
connect_bd_intf_net \
    [get_bd_intf_pins axi_ic_ctrl/M00_AXI] \
    [get_bd_intf_pins tetra_zynq_top_0/s_axi]

# M01 → AXI DMA AXI-Lite control
connect_bd_intf_net \
    [get_bd_intf_pins axi_ic_ctrl/M01_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# M02 → axi_ad9361 AXI config
connect_bd_intf_net \
    [get_bd_intf_pins axi_ic_ctrl/M02_AXI] \
    [get_bd_intf_pins axi_ad9361_0/s_axi]

# =============================================================================
# AXI-Stream: tetra_zynq_top → AXI DMA S2MM
# =============================================================================

puts "  Connecting AXI-Stream (tetra → DMA)..."

connect_bd_intf_net \
    [get_bd_intf_pins tetra_zynq_top_0/m_axis] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# =============================================================================
# AXI HP0 Data Path (DMA → PS DDR)
# =============================================================================

puts "  Connecting HP0 data path..."

# AXI DMA S2MM M_AXI → HP0 interconnect
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins axi_ic_hp0/S00_AXI]

# AXI DMA Scatter-Gather M_AXI → HP0 interconnect
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_SG] \
    [get_bd_intf_pins axi_ic_hp0/S01_AXI]

# HP0 interconnect → PS HP0 slave
connect_bd_intf_net \
    [get_bd_intf_pins axi_ic_hp0/M00_AXI] \
    [get_bd_intf_pins sys_ps7/S_AXI_HP0]

# =============================================================================
# Interrupts
# =============================================================================

puts "  Connecting interrupts..."

# DMA S2MM interrupt → IRQ concat bit 0
connect_bd_net \
    [get_bd_pins axi_dma_0/s2mm_introut] \
    [get_bd_pins xlconcat_irq/In0]

# tetra_zynq_top MAC block IRQ → IRQ concat bit 1
connect_bd_net \
    [get_bd_pins tetra_zynq_top_0/o_irq] \
    [get_bd_pins xlconcat_irq/In1]

# IRQ concat output → PS IRQ_F2P
connect_bd_net \
    [get_bd_pins xlconcat_irq/dout] \
    [get_bd_pins sys_ps7/IRQ_F2P]

# =============================================================================
# Export External Ports (LVDS, SPI, I2C, GPIO, DDR, MIO)
# =============================================================================

puts "  Exporting external ports..."

# --- DDR (PS7 MIO-connected, managed by Vivado automation) ---
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $sys_ps7

# --- AD9361 LVDS ports (from axi_ad9361 IP) ---
# The axi_ad9361 IP exposes LVDS pins as individual (non-interface) BD pins.
# Export each differential pair individually; the wrapper will propagate them
# to tetra_system_top.v as individual ports matched to the XDC constraints.

foreach pin_name {
    rx_clk_in_p rx_clk_in_n
    rx_frame_in_p rx_frame_in_n
    rx_data_in_p rx_data_in_n
    tx_clk_out_p tx_clk_out_n
    tx_frame_out_p tx_frame_out_n
    tx_data_out_p tx_data_out_n
} {
    set pin [get_bd_pins axi_ad9361_0/$pin_name]
    if {[llength $pin] > 0} {
        make_bd_pins_external $pin
    } else {
        puts "  WARNING: axi_ad9361_0/$pin_name not found — skipping"
    }
}

# --- SPI0 (AD9361 configuration via PS EMIO) ---
make_bd_intf_pins_external [get_bd_intf_pins sys_ps7/SPI_0]

# --- I2C0 (board I2C) ---
make_bd_intf_pins_external [get_bd_intf_pins sys_ps7/IIC_0]

# Rename IIC port to match tetra_system_top.v convention
set_property name iic_main [get_bd_intf_ports IIC_0_0]

# --- GPIO EMIO (64-bit — includes AD9361 GPIO, enable/txnrx, status) ---
make_bd_pins_external [get_bd_pins sys_ps7/GPIO_I]
make_bd_pins_external [get_bd_pins sys_ps7/GPIO_O]
make_bd_pins_external [get_bd_pins sys_ps7/GPIO_T]

# Rename GPIO ports
set_property name gpio_i [get_bd_ports GPIO_I_0]
set_property name gpio_o [get_bd_ports GPIO_O_0]
set_property name gpio_t [get_bd_ports GPIO_T_0]

# --- gpio_status input (AD9361 status bits) ---
create_bd_port -dir I -from 7 -to 0 gpio_status
# gpio_status drives gpio_i[39:32] — connect via slice/concat (see note below)
# NOTE: For simplicity, gpio_status is handled in tetra_system_top.v
#       The 8 bits are assigned: gpio_i[39:32] = gpio_status (outside BD)

# --- TDD sync (TDD_DISABLE=1 — port only exists in TDD builds; skip if absent) ---
foreach {dir name} {I tdd_sync_i O tdd_sync_o O tdd_sync_t} {
    set pin [get_bd_pins axi_ad9361_0/$name]
    if {[llength $pin] > 0} {
        create_bd_port -dir $dir $name
        if {$dir eq "I"} {
            connect_bd_net [get_bd_ports $name] $pin
        } else {
            connect_bd_net $pin [get_bd_ports $name]
        }
    }
}

# --- up_enable / up_txnrx (AD9361 enable control from PS GPIO) ---
# These are driven by PS GPIO_O[47:48] in tetra_system_top.v and passed
# to the wrapper as separate ports (see tetra_system_top.v).
create_bd_port -dir I up_enable
create_bd_port -dir I up_txnrx
connect_bd_net [get_bd_ports up_enable] [get_bd_pins axi_ad9361_0/up_enable]
connect_bd_net [get_bd_ports up_txnrx]  [get_bd_pins axi_ad9361_0/up_txnrx]

# Lock output port (axi_ad9361 PLL lock indicator — not present in all versions)
set locked_pin [get_bd_pins axi_ad9361_0/locked]
if {[llength $locked_pin] > 0} {
    create_bd_port -dir O locked
    connect_bd_net $locked_pin [get_bd_ports locked]
}

# =============================================================================
# Address Assignment
# =============================================================================

puts "  Assigning addresses..."

# tetra_zynq_top AXI-Lite: 0x43C0_0000, 64 KB
assign_bd_address \
    -target_address_space [get_bd_addr_spaces sys_ps7/Data] \
    -range 64K \
    -offset 0x43C00000 \
    [get_bd_addr_segs tetra_zynq_top_0/s_axi/reg0]

# AXI DMA: 0x4040_0000, 64 KB
assign_bd_address \
    -target_address_space [get_bd_addr_spaces sys_ps7/Data] \
    -range 64K \
    -offset 0x40400000 \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]

# axi_ad9361: 0x7902_0000, 64 KB
# Segment name varies by ADI IP version — query it dynamically
set ad9361_segs [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_ad9361_0/s_axi]]
if {[llength $ad9361_segs] > 0} {
    assign_bd_address \
        -target_address_space [get_bd_addr_spaces sys_ps7/Data] \
        -range 64K \
        -offset 0x79020000 \
        [lindex $ad9361_segs 0]
} else {
    puts "  WARNING: axi_ad9361_0 s_axi address segment not found — skipping manual assignment"
}

# DMA S2MM master → PS HP0 DDR window (full 1 GB)
assign_bd_address \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    -range 1G \
    -offset 0x00000000 \
    [get_bd_addr_segs sys_ps7/S_AXI_HP0/HP0_DDR_LOWOCM]

# DMA SG master → PS HP0 DDR window (same segment, different addr space)
assign_bd_address \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_SG] \
    -range 1G \
    -offset 0x00000000 \
    [get_bd_addr_segs sys_ps7/S_AXI_HP0/HP0_DDR_LOWOCM]

# =============================================================================
# Validate & Save
# =============================================================================

puts "  Validating BD..."
validate_bd_design

save_bd_design
puts "\n=== Block Design 'tetra_system' created successfully ==="
puts "  Next step: generate_target / make_wrapper / add_files"

# =============================================================================
# Generate Wrapper
# =============================================================================

puts "  Generating output products..."
generate_target all [get_files tetra_system.bd]

puts "  Creating HDL wrapper..."
set bd_wrapper [make_wrapper -files [get_files tetra_system.bd] -top]
add_files -norecurse $bd_wrapper

puts "  Setting top to tetra_system_top..."
set_property top tetra_system_top [current_fileset]
update_compile_order -fileset sources_1

puts "\n=== BD wrapper generated: tetra_system_wrapper.v ==="
puts "  Top module: tetra_system_top"
