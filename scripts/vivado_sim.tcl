# =============================================================================
# vivado_sim.tcl — Vivado Behavioral Simulation Automation
# Project: tetra-zynq-phy
#
# Usage:
# vivado -mode batch -source scripts/vivado_sim.tcl -tclargs <module_name>
#
# Example:
# vivado -mode batch -source scripts/vivado_sim.tcl -tclargs tetra_clk_reset
#
# Supported modules:
# tetra_clk_reset — infra/reset synchronizer
# tetra_pi4dqpsk_demod — RX demodulator
# tetra_timing_recovery — Gardner TED
# tetra_sync_detect — Burst synchronization
# tetra_burst_demux — Burst demultiplexer
# tetra_frame_counter — TDMA frame counter (RX)
# tetra_tdma_timebase — TDMA timebase (TX, 0-based TN/FN/MN/HN)
# tx_slot_schedule — TDMA slot schedule dual-port BRAM (Stufe 3)
# tetra_burst_dispatcher — Phase Y.3 single-stage queue.head→builder dispatcher
# tetra_scrambler — LFSR scrambler
# tetra_interleaver — Block interleaver
# tetra_viterbi_decoder — Viterbi soft-decision
# tetra_reed_muller — Reed-Muller (30,14)
# tetra_crc16 — CRC-16
# tetra_rcpc_encoder — RCPC convolutional encoder
# tetra_loopback — TX→RX integration loopback
# =============================================================================

# Parse module name argument
if {[llength $argv] < 1} {
 puts "ERROR: No module name specified."
 puts "Usage: vivado -mode batch -source scripts/vivado_sim.tcl -tclargs <module>"
 exit 1
}

set MODULE [lindex $argv 0]
puts "=== Simulating module: $MODULE ==="

# =============================================================================
# Directory Paths
# =============================================================================

set PROJ_DIR [file dirname [file dirname [info script]]]
set RTL_DIR "$PROJ_DIR/rtl"
set TB_DIR "$PROJ_DIR/tb"
set VEC_DIR "$TB_DIR/vectors"
set SIM_DIR "$PROJ_DIR/sim_out/$MODULE"

file mkdir $SIM_DIR

# =============================================================================
# Source File Lists per Module
# =============================================================================

# Each entry: list of RTL + TB files needed for this module's simulation
# Format: {rtl_file1 rtl_file2... tb_file}

array set MODULE_FILES {
 tetra_clk_reset {
 rtl/infra/tetra_clk_reset.v
 tb/tb_tetra_clk_reset.v
 }
 tetra_ad9361_interface {
 tb/sim_models/xilinx_prim_sim.v
 archive/rtl/tetra_ad9361_interface.v
 archive/tb/tb_tetra_ad9361_interface.v
 }
 tetra_pi4dqpsk_demod {
 rtl/rx/tetra_pi4dqpsk_demod.v
 tb/tb_tetra_pi4dqpsk_demod.v
 }
 tetra_timing_recovery {
 rtl/rx/tetra_timing_recovery.v
 tb/tb_tetra_timing_recovery.v
 }
 tetra_sync_detect {
 rtl/rx/tetra_sync_detect.v
 tb/tb_tetra_sync_detect.v
 }
 tetra_burst_demux {
 rtl/rx/tetra_burst_demux.v
 tb/tb_tetra_burst_demux.v
 }
 tetra_frame_counter {
 rtl/rx/tetra_frame_counter.v
 tb/tb_tetra_frame_counter.v
 }
 tetra_tdma_timebase {
 rtl/tx/tetra_tdma_timebase.v
 tb/tb_tetra_tdma_timebase.v
 }
 tx_slot_schedule {
 rtl/tx/tetra_slot_schedule.v
 tb/tb_tx_slot_schedule.v
 }
 tetra_burst_dispatcher {
 rtl/tx/tetra_burst_dispatcher.v
 tb/tb_burst_dispatcher.v
 }
 tetra_bsch_encoder_integration {
 rtl/tx/tetra_tdma_timebase.v
 rtl/tx/tetra_sb1_encoder.v
 tb/tb_tetra_bsch_encoder_integration.v
 }
 tetra_aach_encoder {
 rtl/tx/tetra_aach_encoder.v
 tb/tb_tetra_aach_encoder.v
 }
 tetra_scrambler {
 rtl/lmac/tetra_scrambler.v
 tb/tb_tetra_scrambler.v
 }
 tetra_interleaver {
 rtl/lmac/tetra_interleaver.v
 tb/tb_tetra_interleaver.v
 }
 tetra_rcpc_encoder {
 rtl/lmac/tetra_rcpc_encoder.v
 tb/tb_tetra_rcpc_encoder.v
 }
 tetra_viterbi_decoder {
 rtl/lmac/tetra_viterbi_decoder.v
 tb/tb_tetra_viterbi_decoder.v
 }
 tetra_reed_muller {
 rtl/lmac/tetra_reed_muller.v
 tb/tb_tetra_reed_muller.v
 }
 tetra_crc16 {
 rtl/lmac/tetra_crc16.v
 tb/tb_tetra_crc16.v
 }
 tetra_loopback {
 rtl/infra/tetra_clk_reset.v
 rtl/lmac/tetra_scrambler.v
 rtl/lmac/tetra_interleaver.v
 rtl/lmac/tetra_rcpc_encoder.v
 rtl/lmac/tetra_viterbi_decoder.v
 rtl/lmac/tetra_reed_muller.v
 rtl/lmac/tetra_crc16.v
 rtl/tx/tetra_pi4dqpsk_mod.v
 rtl/tx/tetra_rrc_filter.v
 rtl/rx/tetra_pi4dqpsk_demod.v
 rtl/rx/tetra_timing_recovery.v
 rtl/rx/tetra_sync_detect.v
 rtl/rx/tetra_burst_demux.v
 tb/tb_tetra_loopback.v
 }
}

# Validate module name
if {![info exists MODULE_FILES($MODULE)]} {
 puts "ERROR: Unknown module '$MODULE'"
 puts "Supported: [array names MODULE_FILES]"
 exit 1
}

# =============================================================================
# Create Vivado Project (in-memory)
# =============================================================================

create_project -in_memory -part xc7z020clg400-1

# Set Verilog-2001 as default
set_property default_lib work [current_project]
set_property simulator_language Verilog [current_project]

# Add source files
foreach src_file $MODULE_FILES($MODULE) {
 set full_path "$PROJ_DIR/$src_file"
 if {[file exists $full_path]} {
 add_files -norecurse $full_path
 puts " Added: $src_file"
 } else {
 puts "WARNING: File not found: $full_path (module may be incomplete)"
 }
}

# Set testbench as simulation top
set tb_name "tb_$MODULE"
set_property top $tb_name [get_filesets sim_1]
set_property top_lib work [get_filesets sim_1]

# Add test vector directory to include path
set_property include_dirs $VEC_DIR [get_filesets sim_1]

# =============================================================================
# Run Simulation
# =============================================================================

puts "\n=== Launching behavioral simulation ==="
puts " Top: $tb_name"
puts " Output: $SIM_DIR"

# Launch simulation
launch_simulation -simset sim_1 -mode behavioral

# Run to completion
run all

# =============================================================================
# Capture Results
# =============================================================================

# Check for PASS/FAIL in simulation log
set sim_log "$SIM_DIR/simulate.log"
if {[file exists $sim_log]} {
 set fp [open $sim_log r]
 set log_content [read $fp]
 close $fp

 if {[string match "*RESULT: PASS*" $log_content]} {
 puts "\n=== SIMULATION RESULT: PASS ==="
 } elseif {[string match "*RESULT: FAIL*" $log_content]} {
 puts "\n=== SIMULATION RESULT: FAIL ==="
 puts "Check $sim_log for details"
 exit 1
 } else {
 puts "\n=== SIMULATION RESULT: UNKNOWN (check log) ==="
 }
} else {
 puts "WARNING: Simulation log not found at $sim_log"
}

puts "\nSimulation complete for module: $MODULE"
close_project
