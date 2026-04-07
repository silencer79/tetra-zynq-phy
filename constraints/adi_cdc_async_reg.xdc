# =============================================================================
# constraints/adi_cdc_async_reg.xdc
# Project: tetra-zynq-phy
#
# Description:
# Sets ASYNC_REG attribute on ADI axi_ad9361 IP internal synchronizer registers
# to fix CDC violations reported by Vivado CDC Analyzer
#
# Problem:
# Vivado CDC report shows 79 unsafe crossings from clk_fpga_0 → rx_clk
# These violations originate from ADI axi_ad9361 IP internal CDC logic
# The IP has synchronizers but lacks ASYNC_REG attributes
#
# Solution:
# Add ASYNC_REG constraints via this XDC file (external to IP)
# Vivado will apply these during synthesis/implementation
#
# Target: axi_ad9361 IP instance: tetra_system_axi_ad9361_0_0
# =============================================================================

# =============================================================================
# ADC Path Synchronizers (rx_clk → clk_fpga_0)
# These are safe crossings but need ASYNC_REG to suppress CDC warnings
# =============================================================================

# ADC data path synchronizers
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*adc*/*sync*}]

# ADC valid/status synchronizers
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*adc*/*_r0*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*adc*/*_r1*}]

# =============================================================================
# DAC Path Synchronizers (clk_fpga_0 → rx_clk)
# These are the 79 unsafe crossings reported by CDC Analyzer
# =============================================================================

# DAC data path synchronizers
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*dac*/*sync*}]

# DAC valid/status synchronizers
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*dac*/*_r0*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*dac*/*_r1*}]

# =============================================================================
# Control Path Synchronizers (up_xfer modules)
# ADI IP uses up_xfer_cntrl and up_xfer_status for CDC
# =============================================================================

# Transfer control synchronizers
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*up_xfer*/*reg*}]

# Transfer status synchronizers (2-FF chains)
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*up_*status*/*r0*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*up_*status*/*r1*}]

# =============================================================================
# Generic Fallback: All 2-FF Chains in ADI IP
# Matches common synchronizer patterns: *_r0, *_r1, *sync_reg[0-9]
# =============================================================================

# All registers ending with _r0 or _r1 (2-FF synchronizer pattern)
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*_r0*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*_r1*}]

# All registers with "sync" in the name
set_property ASYNC_REG TRUE [get_cells -hierarchical -quiet \
    -filter {NAME =~ *axi_ad9361*/*sync*reg*}]

# =============================================================================
# Specific IP Instance Targeting
# Target only the axi_ad9361 instance in the Block Design
# =============================================================================

# ADC path in tetra_system_axi_ad9361_0_0 instance
set_property ASYNC_REG TRUE [get_cells -quiet \
    tetra_system_i/tetra_system_axi_ad9361_0_0/inst/i_adc/*sync*]

# DAC path in tetra_system_axi_ad9361_0_0 instance
set_property ASYNC_REG TRUE [get_cells -quiet \
    tetra_system_i/tetra_system_axi_ad9361_0_0/inst/i_dac/*sync*]

# Up_xfer modules
set_property ASYNC_REG TRUE [get_cells -quiet \
    tetra_system_i/tetra_system_axi_ad9361_0_0/inst/*up_xfer*/*r*]

# =============================================================================
# Notes
# =============================================================================
# 1. The -quiet flag suppresses warnings if cells don't exist in all configurations
# 2. Hierarchical filters allow matching cells at any depth in the IP hierarchy
# 3. This constraint file is added AFTER IP generation (doesn't modify IP source)
# 4. Vivado applies ASYNC_REG during synthesis - no IP re-customization needed
# 5. After adding this file, rebuild and check CDC report for 0 unsafe crossings
#
# =============================================================================
# Verification Steps
# =============================================================================
# 1. Add this file to Vivado project constraint sources
# 2. Run synthesis + implementation
# 3. Execute: report_cdc -file reports/cdc_report_after_fix.rpt
# 4. Verify: 79 unsafe → 0 unsafe, all synchronous to ADI IP properly marked
# =============================================================================
