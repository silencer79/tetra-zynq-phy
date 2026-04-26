# =============================================================================
# vivado_build.tcl — Full Build: Sources + BD + Synth + Impl + Bitstream
# Project: tetra-zynq-phy
# Target: LibreSDR (Zynq-7020 XC7Z020-CLG400 + AD9361)
# Tool: Vivado 2022.2
#
# Usage:
# vivado -mode batch -source scripts/vivado_build.tcl
#
# Optional environment variable:
# ADI_HDL_DIR — path to ADI HDL library (hdl/library directory)
# e.g. export ADI_HDL_DIR=/opt/adi/hdl/library
# If not set, the script auto-detects common locations.
#
# Build Flow:
# 1. Create Vivado project (xc7z020clg400-1)
# 2. Enable XPM libraries (xpm_fifo_async used in tetra_zynq_top)
# 3. Add all RTL sources (tetra_zynq_top and all sub-modules)
# 4. source scripts/create_bd.tcl → creates Block Design + wrapper
# 5. Synthesis
# 6. Implementation (place + route)
# 7. Bitstream generation
#
# Outputs:
# build/tetra_zynq_phy.bit — Bitstream
# build/tetra_zynq_phy.ltx — Debug probes (ILA)
# build/reports/ — Timing + utilization reports
#
# Top Module: tetra_system_top (rtl/tetra_system_top.v)
# Instantiates: tetra_system_wrapper (BD-generated)
# BD contains: PS7 + proc_sys_reset + axi_ad9361 + axi_dma + tetra_zynq_top
# =============================================================================

set PROJ_NAME "tetra_zynq_phy"
set PROJ_DIR [file dirname [file dirname [info script]]]
set BUILD_DIR "$PROJ_DIR/build"
set REPORT_DIR "$BUILD_DIR/reports"
set PART "xc7z020clg400-1"

# =============================================================================
# Production vs Debug Build
# Default to production because the debug ILA core materially hurts timing on
# clk_fpga_0 and can destabilize hardware bring-up. Override with
# ENABLE_ILA_DEBUG=1 in the environment when interactive debug is needed.
# =============================================================================
set ENABLE_ILA_DEBUG 0
if {[info exists env(ENABLE_ILA_DEBUG)]} {
    set ENABLE_ILA_DEBUG $env(ENABLE_ILA_DEBUG)
}

# Forward ADI_HDL_DIR to create_bd.tcl if set in environment
if {[info exists env(ADI_HDL_DIR)]} {
    set ADI_HDL_DIR $env(ADI_HDL_DIR)
}

puts "================================================================="
puts " tetra-zynq-phy Build Script"
puts "================================================================="
puts " Part : $PART"
puts " Dir : $PROJ_DIR"
puts " Build : $BUILD_DIR"
puts " ILA Debug : $ENABLE_ILA_DEBUG"
if {[info exists ADI_HDL_DIR] && $ADI_HDL_DIR ne ""} {
    puts " ADI IP : $ADI_HDL_DIR"
} else {
    puts " ADI IP : auto-detect (set ADI_HDL_DIR if needed)"
}
puts "================================================================="

file mkdir $BUILD_DIR
file mkdir $REPORT_DIR

# =============================================================================
# 1. Create Project
# =============================================================================

puts "\n=== Step 1: Creating Vivado project ==="

create_project $PROJ_NAME $BUILD_DIR/vivado -part $PART -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]
set_property simulator_language Mixed [current_project]

# Enable XPM libraries (required for xpm_fifo_async in tetra_zynq_top)
set_property XPM_LIBRARIES {XPM_FIFO XPM_MEMORY} [current_project]

# =============================================================================
# 2. Add RTL Sources
# =============================================================================

puts "\n=== Step 2: Adding RTL sources ==="

# Infrastructure
add_files -norecurse [list \
 $PROJ_DIR/rtl/infra/tetra_clk_reset.v \
 $PROJ_DIR/rtl/infra/tetra_axi_lite_regs.v \
 $PROJ_DIR/rtl/infra/tetra_axi_dma_bridge.v \
]

# AD9361 Interface Adapter (fabric-side only — LVDS handled by axi_ad9361 IP)
# Note: tetra_ad9361_interface.v is kept as reference but NOT used in synthesis.
# tetra_ad9361_axis_adapter.v is the active adapter for the axi_ad9361 IP.
add_files -norecurse [list \
 $PROJ_DIR/rtl/tetra_ad9361_axis_adapter.v \
]

# RX Chain
add_files -norecurse [list \
 $PROJ_DIR/rtl/rx/tetra_rx_chain.v \
 $PROJ_DIR/rtl/rx/tetra_rx_frontend.v \
 $PROJ_DIR/rtl/rx/tetra_pi4dqpsk_demod.v \
 $PROJ_DIR/rtl/rx/tetra_timing_recovery.v \
 $PROJ_DIR/rtl/rx/tetra_sync_detect.v \
 $PROJ_DIR/rtl/rx/tetra_ul_sync_detect_os4.v \
 $PROJ_DIR/rtl/rx/tetra_ul_burst_capture.v \
 $PROJ_DIR/rtl/rx/tetra_ul_pi4dqpsk_demod.v \
 $PROJ_DIR/rtl/rx/tetra_ul_sch_hu_decoder.v \
 $PROJ_DIR/rtl/rx/tetra_ul_viterbi_r14.v \
 $PROJ_DIR/rtl/rx/tetra_burst_demux.v \
 $PROJ_DIR/rtl/rx/tetra_frame_counter.v \
 $PROJ_DIR/rtl/rx/tetra_ul_demand_reassembly.v \
]

# TX Chain
add_files -norecurse [list \
 $PROJ_DIR/rtl/tx/tetra_tx_chain.v \
 $PROJ_DIR/rtl/tx/tetra_tx_frontend.v \
 $PROJ_DIR/rtl/tx/tetra_pi4dqpsk_mod.v \
 $PROJ_DIR/rtl/tx/tetra_rrc_filter.v \
 $PROJ_DIR/rtl/tx/tetra_tx_inv_sinc.v \
 $PROJ_DIR/rtl/tx/tetra_burst_builder.v \
 $PROJ_DIR/rtl/tx/tetra_burst_mux.v \
 $PROJ_DIR/rtl/tx/tetra_tdma_timebase.v \
 $PROJ_DIR/rtl/tx/tetra_slot_schedule.v \
 $PROJ_DIR/rtl/tx/tetra_slot_content_mux.v \
 $PROJ_DIR/rtl/tx/tetra_sb1_encoder.v \
 $PROJ_DIR/rtl/tx/tetra_aach_encoder.v \
]

# LMAC
add_files -norecurse [list \
 $PROJ_DIR/rtl/lmac/tetra_lmac.v \
 $PROJ_DIR/rtl/lmac/tetra_scrambler.v \
 $PROJ_DIR/rtl/lmac/tetra_interleaver.v \
 $PROJ_DIR/rtl/lmac/tetra_deinterleaver.v \
 $PROJ_DIR/rtl/lmac/tetra_depuncture_r23.v \
 $PROJ_DIR/rtl/lmac/tetra_rcpc_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_viterbi_decoder.v \
 $PROJ_DIR/rtl/lmac/tetra_reed_muller.v \
 $PROJ_DIR/rtl/lmac/tetra_crc16.v \
 $PROJ_DIR/rtl/lmac/tetra_steal_detect.v \
 $PROJ_DIR/rtl/lmac/tetra_ul_mac_access_parser.v \
 $PROJ_DIR/rtl/lmac/tetra_entity_table.v \
 $PROJ_DIR/rtl/lmac/tetra_profile_table.v \
 $PROJ_DIR/rtl/lmac/tetra_active_session_table.v \
 $PROJ_DIR/rtl/lmac/tetra_d_location_update_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_d_location_update_reject_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_d_attach_detach_group_identity_ack_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_sch_hd_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_sch_f_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_basic_slotgrant_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_chan_alloc_encoder.v \
 $PROJ_DIR/rtl/lmac/tetra_mac_resource_dl_builder.v \
 $PROJ_DIR/rtl/lmac/tetra_mac_resource_bl_ack_builder.v \
 $PROJ_DIR/rtl/lmac/tetra_mle_registration_fsm.v \
 $PROJ_DIR/rtl/lmac/tetra_dl_signal_queue.v \
 $PROJ_DIR/rtl/lmac/tetra_dl_signal_scheduler.v \
 $PROJ_DIR/rtl/lmac/tetra_ul_demand_ie_parser.v \
]

# Top-Level modules
# tetra_zynq_top.v — TETRA PL design (instantiated as BD module reference)
# tetra_system_top.v — Physical board top (actual top module for synthesis)
add_files -norecurse [list \
 $PROJ_DIR/rtl/tetra_zynq_top.v \
 $PROJ_DIR/rtl/tetra_system_top.v \
]

# Constraints
# Main pin/timing constraints
# CDC constraints for ADI axi_ad9361 IP synchronizers (fixes 79 unsafe crossings)
add_files -fileset constrs_1 -norecurse [list \
 $PROJ_DIR/constraints/libresdr_tetra.xdc \
 $PROJ_DIR/constraints/adi_cdc_async_reg.xdc \
]

# Update compile order before BD creation (needed for module reference)
update_compile_order -fileset sources_1

puts " RTL sources added. Updating compile order..."

# =============================================================================
# 3. Create Block Design
# =============================================================================

puts "\n=== Step 3: Creating Block Design ==="

# Pass ADI_HDL_DIR to the BD script
if {[info exists ADI_HDL_DIR]} {
    # Variable is already in scope — create_bd.tcl will use it
}
source $PROJ_DIR/scripts/create_bd.tcl

# After BD creation, tetra_system_top is set as top in create_bd.tcl
# Confirm the top module
puts " Top module: [get_property top [current_fileset]]"

# =============================================================================
# 4. Synthesis
# =============================================================================

puts "\n=== Step 4: Running Synthesis ==="

# Use global synthesis mode for the BD — includes all BD IPs (including axi_ad9361)
# inline with synth_design rather than requiring pre-built OOC netlist checkpoints.
set bd_file [get_files tetra_system.bd]
set_property SYNTH_CHECKPOINT_MODE None $bd_file
puts " BD synthesis mode: Global (SYNTH_CHECKPOINT_MODE=None)"

synth_design \
-top tetra_system_top \
-part $PART \
-flatten_hierarchy rebuilt \
-directive PerformanceOptimized \
-retiming

report_utilization -file "$REPORT_DIR/synth_utilization.rpt"
report_timing_summary -file "$REPORT_DIR/synth_timing.rpt" -max_paths 10

write_checkpoint -force "$BUILD_DIR/post_synth.dcp"
puts " Synthesis complete → $BUILD_DIR/post_synth.dcp"

# =============================================================================
# 5. Implementation
# =============================================================================

puts "\n=== Step 5: Running Implementation ==="

opt_design

# =============================================================================
# ILA Debug Core Insertion (non-project flow)
#
# Production build: ENABLE_ILA_DEBUG=0 → ILA disabled, timing clean
# Debug build: ENABLE_ILA_DEBUG=1 → ILA enabled for hardware debug
# =============================================================================

set debug_nets [get_nets -hierarchical -filter {MARK_DEBUG == "TRUE"}]
puts " MARK_DEBUG nets found: [llength $debug_nets]"
write_checkpoint -force "$BUILD_DIR/post_opt.dcp"

if {$ENABLE_ILA_DEBUG && [llength $debug_nets] > 0} {
 # Re-open checkpoint so implement_debug_core has a valid project context
 open_checkpoint "$BUILD_DIR/post_opt.dcp"

 # Re-fetch nets after reopening
 set all_dbg [get_nets -hierarchical -filter {MARK_DEBUG == "TRUE"}]
 puts " Nets after reopen: [llength $all_dbg]"
 foreach n $all_dbg { puts " DBG: $n" }

 # Split by clock domain using name suffix
 set lvds_nets {}
 set sys_nets {}
 foreach net $all_dbg {
 set leaf [lindex [split $net "/"] end]
 if {[string match "*_lvds" $leaf]} {
 lappend lvds_nets $net
 } else {
 lappend sys_nets $net
 }
 }
 puts " l_clk nets : [llength $lvds_nets]"
 puts " clk_sys nets: [llength $sys_nets]"

 # Find clock net from a known registered probe cell
 proc ila_clk_net {cell_glob} {
 set cells [get_cells -hierarchical -filter "NAME =~ *${cell_glob}*" -quiet]
 if {[llength $cells] == 0} { return {} }
 set pin [get_pins -of_objects [lindex $cells 0] -filter {IS_CLOCK == 1} -quiet]
 if {$pin eq {}} { return {} }
 return [get_nets -of_objects $pin -quiet]
 }

 set l_clk_net [ila_clk_net "dbg_adc_valid_i0_lvds_reg"]
 set clk_sys_net [ila_clk_net "dbg_sync_locked_sys_reg"]
 puts " l_clk net : $l_clk_net"
 puts " clk_sys net: $clk_sys_net"

 # Helper: create one ILA core with N single-bit probes
 proc create_ila {name depth clk_net probe_nets} {
 if {[llength $probe_nets] == 0 || $clk_net eq {}} {
 puts " SKIP $name — missing nets"
 return
 }
 create_debug_core $name ila
 set_property C_DATA_DEPTH $depth [get_debug_cores $name]
 set_property C_TRIGIN_EN false [get_debug_cores $name]
 set_property C_TRIGOUT_EN false [get_debug_cores $name]
 set_property C_ADV_TRIGGER false [get_debug_cores $name]
 set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores $name]
 set_property ALL_PROBE_SAME_MU true [get_debug_cores $name]
 set_property port_width 1 [get_debug_ports ${name}/clk]
 connect_debug_port ${name}/clk [get_nets $clk_net]
 set i 0
 foreach net $probe_nets {
 if {$i == 0} {
 set port [get_debug_ports ${name}/probe0]
 } else {
 set port [create_debug_port $name probe]
 }
 set_property PROBE_TYPE DATA_AND_TRIGGER $port
 set_property port_width 1 $port
 connect_debug_port $port [get_nets $net]
 incr i
 }
 puts " Created $name: [llength $probe_nets] probe(s), depth=$depth"
 }

 # ========================================================================
 # ILA Clock Domain Strategy (2026-04-07 Fix):
 # - REMOVED: u_ila_lvds (l_clk domain)
 #   REASON: l_clk = AD9361 DATA_CLK, requires AD9361 SPI config to be active.
 #   Without AD9361 init software, debug hub clock is dead → ILA undetectable.
 # - KEPT: u_ila_sys (clk_sys = FCLK_CLK0 @ 100 MHz)
 #   REASON: Always active after FPGA program, independent of AD9361 state.
 # ========================================================================
 # create_ila u_ila_lvds 4096 $l_clk_net $lvds_nets  # DISABLED — l_clk not available without AD9361 init
 create_ila u_ila_sys 4096 $clk_sys_net $sys_nets

 implement_debug_core
 puts " implement_debug_core complete — u_ila_lvds + u_ila_sys inserted"
} else {
 if {!$ENABLE_ILA_DEBUG} {
 puts " ILA DISABLED — Production build (ENABLE_ILA_DEBUG=0)"
 } else {
 puts " WARNING: No MARK_DEBUG nets — ILA probes not inserted"
 }
}

place_design -directive Auto_1
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore

# implement_debug_core already connects ILA → dbg_hub → BSCAN automatically.
# connect_debug_cores is only needed for debug-bridge IP, not standard ILA flow.

report_utilization -file "$REPORT_DIR/impl_utilization.rpt"
report_timing_summary -file "$REPORT_DIR/impl_timing.rpt" \
-max_paths 20 -warn_on_violation
report_clock_interaction -file "$REPORT_DIR/clock_interaction.rpt"
report_cdc -file "$REPORT_DIR/cdc_report.rpt"

# Timing check
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} {
 puts "WARNING: Timing violation! WNS = $wns ns"
 puts " See $REPORT_DIR/impl_timing.rpt"
} else {
 puts " Timing PASSED. WNS = $wns ns"
}

write_checkpoint -force "$BUILD_DIR/post_route.dcp"

# =============================================================================
# 6. Bitstream
# =============================================================================

puts "\n=== Step 6: Generating Bitstream ==="

# Note: BITSTREAM.CONFIG.SPI_* properties are not settable on 'design' in
# non-project flow. Configure SPI programming options via Vivado Hardware
# Manager at programming time (bitstream content is not affected).

write_bitstream -force "$BUILD_DIR/$PROJ_NAME.bit"
write_debug_probes -force "$BUILD_DIR/$PROJ_NAME.ltx"

puts "\n================================================================="
puts " Build COMPLETE"
puts "================================================================="
puts " Bitstream : $BUILD_DIR/$PROJ_NAME.bit"
puts " Probes : $BUILD_DIR/$PROJ_NAME.ltx"
puts " Reports : $REPORT_DIR/"
puts "================================================================="

close_project
