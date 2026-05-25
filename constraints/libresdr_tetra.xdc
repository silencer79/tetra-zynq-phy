# =============================================================================
# libresdr_tetra.xdc — Pin Constraints + Timing
# Project: tetra-zynq-phy
# Target:  LibreSDR (Zynq-7020 XC7Z020-CLG484 + AD9361)
# Tool:    Vivado 2022.2
#
# Pin assignments verified from:
#   libresdr/system.xdc  — OpenWifi reference, tested on LibreSDR hardware
#
# Top Module: tetra_system_top
# =============================================================================

# =============================================================================
# System Clock
# =============================================================================
# The 100 MHz system clock (FCLK_CLK0) comes from the Zynq PS7 MMCM.
# It is internal to the PS7 IP and has no external pin constraint.
# Vivado automatically creates the correct clock constraint for it.
#
# The 200 MHz IDELAYCTRL reference clock (FCLK_CLK1) is also PS-internal.

# =============================================================================
# AD9361 LVDS Interface
# =============================================================================
# RX Clock (DATA_CLK_P/N from AD9361 → Zynq LVDS input)
set_property  -dict {PACKAGE_PIN N20   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports rx_clk_in_p]
set_property  -dict {PACKAGE_PIN P20   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports rx_clk_in_n]

# RX Frame
set_property  -dict {PACKAGE_PIN U18   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports rx_frame_in_p]
set_property  -dict {PACKAGE_PIN U19   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports rx_frame_in_n]

# RX Data [5:0]
set_property  -dict {PACKAGE_PIN V16   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[5]}]
set_property  -dict {PACKAGE_PIN W16   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[5]}]
set_property  -dict {PACKAGE_PIN W18   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[4]}]
set_property  -dict {PACKAGE_PIN W19   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[4]}]
set_property  -dict {PACKAGE_PIN R16   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[3]}]
set_property  -dict {PACKAGE_PIN R17   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[3]}]
set_property  -dict {PACKAGE_PIN V20   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[2]}]
set_property  -dict {PACKAGE_PIN W20   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[2]}]
set_property  -dict {PACKAGE_PIN V17   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[1]}]
set_property  -dict {PACKAGE_PIN V18   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[1]}]
set_property  -dict {PACKAGE_PIN Y18   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_p[0]}]
set_property  -dict {PACKAGE_PIN Y19   IOSTANDARD LVDS_25  DIFF_TERM TRUE} [get_ports {rx_data_in_n[0]}]

# TX Clock (FB_CLK from Zynq → AD9361)
set_property  -dict {PACKAGE_PIN N18   IOSTANDARD LVDS_25} [get_ports tx_clk_out_p]
set_property  -dict {PACKAGE_PIN P19   IOSTANDARD LVDS_25} [get_ports tx_clk_out_n]

# TX Frame
set_property  -dict {PACKAGE_PIN Y16   IOSTANDARD LVDS_25} [get_ports tx_frame_out_p]
set_property  -dict {PACKAGE_PIN Y17   IOSTANDARD LVDS_25} [get_ports tx_frame_out_n]

# TX Data [5:0]
set_property  -dict {PACKAGE_PIN V15   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[5]}]
set_property  -dict {PACKAGE_PIN W15   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[5]}]
set_property  -dict {PACKAGE_PIN V12   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[4]}]
set_property  -dict {PACKAGE_PIN W13   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[4]}]
set_property  -dict {PACKAGE_PIN T16   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[3]}]
set_property  -dict {PACKAGE_PIN U17   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[3]}]
set_property  -dict {PACKAGE_PIN U14   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[2]}]
set_property  -dict {PACKAGE_PIN U15   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[2]}]
set_property  -dict {PACKAGE_PIN T12   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[1]}]
set_property  -dict {PACKAGE_PIN U12   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[1]}]
set_property  -dict {PACKAGE_PIN W14   IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[0]}]
set_property  -dict {PACKAGE_PIN Y14   IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[0]}]

# =============================================================================
# AD9361 Control & GPIO (LVCMOS 2.5 V)
# =============================================================================

# ENABLE / TXNRX — AD9361 operating mode control
set_property  -dict {PACKAGE_PIN R18   IOSTANDARD LVCMOS25} [get_ports enable]
set_property  -dict {PACKAGE_PIN P14   IOSTANDARD LVCMOS25} [get_ports txnrx]

# SPI — AD9361 register configuration (PS SPI0 via EMIO)
set_property  -dict {PACKAGE_PIN P18   IOSTANDARD LVCMOS25  PULLTYPE PULLUP} [get_ports spi_csn]
set_property  -dict {PACKAGE_PIN R14   IOSTANDARD LVCMOS25} [get_ports spi_clk]
set_property  -dict {PACKAGE_PIN P15   IOSTANDARD LVCMOS25} [get_ports spi_mosi]
set_property  -dict {PACKAGE_PIN R19   IOSTANDARD LVCMOS25} [get_ports spi_miso]

# GPIO Status (AD9361 status output bits)
set_property  -dict {PACKAGE_PIN T11   IOSTANDARD LVCMOS25} [get_ports {gpio_status[0]}]
set_property  -dict {PACKAGE_PIN T14   IOSTANDARD LVCMOS25} [get_ports {gpio_status[1]}]
set_property  -dict {PACKAGE_PIN T15   IOSTANDARD LVCMOS25} [get_ports {gpio_status[2]}]
set_property  -dict {PACKAGE_PIN T17   IOSTANDARD LVCMOS25} [get_ports {gpio_status[3]}]
set_property  -dict {PACKAGE_PIN T19   IOSTANDARD LVCMOS25} [get_ports {gpio_status[4]}]
set_property  -dict {PACKAGE_PIN T20   IOSTANDARD LVCMOS25} [get_ports {gpio_status[5]}]
set_property  -dict {PACKAGE_PIN U13   IOSTANDARD LVCMOS25} [get_ports {gpio_status[6]}]
set_property  -dict {PACKAGE_PIN V13   IOSTANDARD LVCMOS25} [get_ports {gpio_status[7]}]

# GPIO Control (AD9361 control inputs)
set_property  -dict {PACKAGE_PIN T10   IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[0]}]
set_property  -dict {PACKAGE_PIN Y11   IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[1]}]
set_property  -dict {PACKAGE_PIN V10   IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[2]}]
set_property  -dict {PACKAGE_PIN U9    IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[3]}]

# GPIO AGC Enable
set_property  -dict {PACKAGE_PIN P16   IOSTANDARD LVCMOS25} [get_ports gpio_en_agc]

# GPIO Sync
set_property  -dict {PACKAGE_PIN U20   IOSTANDARD LVCMOS25} [get_ports gpio_sync]

# GPIO Reset (AD9361 hardware reset — active low)
set_property  -dict {PACKAGE_PIN N17   IOSTANDARD LVCMOS25} [get_ports gpio_resetb]

# =============================================================================
# I2C (IIC — on-board I2C bus, PS I2C0 via EMIO)
# =============================================================================

set_property  -dict {PACKAGE_PIN M15   IOSTANDARD LVCMOS33  PULLTYPE PULLUP} [get_ports iic_scl]
set_property  -dict {PACKAGE_PIN K16   IOSTANDARD LVCMOS33  PULLTYPE PULLUP} [get_ports iic_sda]

# =============================================================================
# LEDs (PL-controlled via PS GPIO EMIO)
# =============================================================================

set_property  -dict {PACKAGE_PIN J20   IOSTANDARD LVCMOS33} [get_ports pl_led0]
set_property  -dict {PACKAGE_PIN H20   IOSTANDARD LVCMOS33} [get_ports pl_led1]

# =============================================================================
# DAC5311 SPI (VCXO 40 MHz tuning — PS GPIO EMIO bitbang)
# =============================================================================
set_property  -dict {PACKAGE_PIN H18   IOSTANDARD LVCMOS33} [get_ports dac_sync]
set_property  -dict {PACKAGE_PIN F19   IOSTANDARD LVCMOS33} [get_ports dac_sclk]
set_property  -dict {PACKAGE_PIN F20   IOSTANDARD LVCMOS33} [get_ports dac_din]

# =============================================================================
# Clock Constraints
# =============================================================================
# rx_clk_in_p (N20) is IO_L14P_T2_SRCC_34 — SRCC capable, bank 34.
# Period 4 ns = 250 MHz covers the maximum AD9361 DATA_CLK rate.

create_clock -name rx_clk -period 4 [get_ports rx_clk_in_p]

# =============================================================================
# Timing Exceptions — Reset Synchronizers
# =============================================================================
# Async reset paths through 2-FF synchronizers (ASYNC_REG handles metastability).
# set_false_path prevents unnecessary timing analysis on these paths.

set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rst_sync0_sys*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rst_sync0_axi*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rst_sync0_lvds*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *rst_sync0_sample*}]

# =============================================================================
# Timing Exceptions — Clock Domain Crossings
# =============================================================================
# rx_clk (AD9361 LVDS l_clk, up to 250 MHz) and clk_fpga_0 (100 MHz) are
# asynchronous. The axi_ad9361 IP handles CDC internally (XPM FIFOs, up_xfer).
# Tell Vivado not to analyse inter-domain paths — they are not synchronous.

set_clock_groups -asynchronous \
    -group [get_clocks rx_clk] \
    -group [get_clocks clk_fpga_0]

# sync_locked / pll_locked CDC synchronisers (2-FF; may not exist in all builds)
set_false_path -quiet -to [get_cells -hierarchical -filter {NAME =~ *sync_locked_r0*}]
set_false_path -quiet -to [get_cells -hierarchical -filter {NAME =~ *pll_locked_r0*}]

# =============================================================================
# Multicycle Path — tetra_rrc_filter MAC (TX path)
# =============================================================================
# The RRC filter MAC (mac_tap_sys_reg → q_out_reg) runs for only 36 out of
# ~5556 clk_sys cycles per input symbol (~0.65% duty cycle).  The data path
# delay is ~9.95 ns which narrowly violates the 10 ns setup window.
# A 2-cycle multicycle path relaxes the setup requirement to 20 ns.
# The hold check is tightened by 1 cycle to compensate (standard practice).
# This is safe because the destination register (q_out_reg) is only sampled
# on the cycle after sample_valid_out is asserted — never back-to-back.

set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/mac_tap_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/q_out_reg*}]
set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/mac_tap_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/q_out_reg*}]

# =============================================================================
# Multicycle Path — tetra_timing_recovery NCO step + loop integrator
# =============================================================================
# The NCO step and loop integrator are only updated at NCO overflow (≤ 18 kHz).
# Critical path: DSP48 (Gardner TED mult) → 34-bit sum → scale → sign-extend
# → kp_term → 32-bit adder → nco_step_sys_reg.  At ~11 ns this narrows violates
# the 10 ns budget.
# 2-cycle multicycle path relaxes setup to 20 ns — safe because nco_step_sys
# and loop_integ_sys are gated by nco_ovf_sys (never consecutive clk_sys cycles).

set_multicycle_path 2 -setup \
    -to [get_cells -hierarchical -filter {NAME =~ *u_timing_recovery/nco_step_sys_reg*}]
set_multicycle_path 1 -hold \
    -to [get_cells -hierarchical -filter {NAME =~ *u_timing_recovery/nco_step_sys_reg*}]
set_multicycle_path 2 -setup \
    -to [get_cells -hierarchical -filter {NAME =~ *u_timing_recovery/loop_integ_sys_reg*}]
set_multicycle_path 1 -hold \
    -to [get_cells -hierarchical -filter {NAME =~ *u_timing_recovery/loop_integ_sys_reg*}]

# =============================================================================
# Multicycle Path — Phase H.3.2e (2026-05-02): Slack-Sanierung WNS=-0.254 ns
# =============================================================================
# Folgende Datapaths violiteren das 10 ns Setup-Fenster, sind aber funktional
# multicycle-fähig (Datenrate << clk_sys=100 MHz).  Vivado weiß das ohne XDC-
# Hint nicht; daher Verletzungen in `impl_timing.rpt` Build vom 18:55.
# =============================================================================

# --- 1. RRC-Filter i_out_reg (analog zu existing q_out_reg block oben) -------
# Symmetrischer i-Kanal des RRC, gleiches Sample-Rate-Profil wie q_out.
# 2 von 26 Top-Verletzungen kommen von hier (-0.254 ns / -0.205 ns).
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/mac_tap_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/i_out_reg*}]
set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/mac_tap_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rrc_filter/i_out_reg*}]

# --- 2. UL Viterbi-Decoder soft-bit → survivor-state (13 Verletzungen) -------
# Größte Cluster der Slack-Verletzungen (vit_soft0/1_sys_reg → surv_s8/s11/s13).
# Symbol-Rate auf SCH/HU ist ~9 kHz (TETRA).  clk_sys ist 100 MHz.  Survivor-
# State-Update läuft nur 1× pro Demod-Symbol — multicycle 4 (= 40 ns) ist
# weit konservativer als das physische Update-Intervall.
set_multicycle_path 4 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/vit_soft0_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/u_viterbi/surv_s*_reg*}]
set_multicycle_path 3 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/vit_soft0_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/u_viterbi/surv_s*_reg*}]
set_multicycle_path 4 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/vit_soft1_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/u_viterbi/surv_s*_reg*}]
set_multicycle_path 3 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/vit_soft1_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_ul_sch_hu/u_viterbi/surv_s*_reg*}]

# --- 3. MLE-FSM Accept-Builder PDU-Build (3 Verletzungen) --------------------
# llc_cov_len_reg → complete_pdu_bits_reg ist der 268-bit-MAC-RESOURCE-Build.
# Feuert 1× pro Attach-Reply (= alle paar Sekunden).  Multicycle 4 sicher.
set_multicycle_path 4 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_accept_builder/llc_cov_len_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accept_builder/complete_pdu_bits_reg*}]
set_multicycle_path 3 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_accept_builder/llc_cov_len_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accept_builder/complete_pdu_bits_reg*}]

# --- 4. RX Frontend CIC-Integrator (2 Verletzungen) --------------------------
# q_comb4_z1_sys_reg → q_cic_out_sys_reg ist der CIC-Output-Stage.  Update-
# Rate ist die Sample-Rate (1.8 MHz LVDS), nicht clk_sys (100 MHz).
# Multicycle 2 wie für RRC.
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rx_frontend/q_comb4_z1_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rx_frontend/q_cic_out_sys_reg*}]
set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_rx_frontend/q_comb4_z1_sys_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_rx_frontend/q_cic_out_sys_reg*}]

# --- 5. TX Frontend CIC-Integrator (6 Verletzungen) --------------------------
# Ähnliches Profil wie RX-CIC — datapath-intensiv, läuft mit Sample-Rate.
set_multicycle_path 2 -setup \
    -to [get_cells -hierarchical -filter {NAME =~ *u_tx_frontend/intg_*_reg*}]
set_multicycle_path 1 -hold \
    -to [get_cells -hierarchical -filter {NAME =~ *u_tx_frontend/intg_*_reg*}]

# =============================================================================
# Board voltage identification (DRC)
# =============================================================================

set_property CONFIG_VOLTAGE  3.3  [current_design]
set_property CFGBVS          VCCO [current_design]
