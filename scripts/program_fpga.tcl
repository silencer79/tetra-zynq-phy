# =============================================================================
# program_fpga.tcl — Upload Bitstream to LibreSDR / Zynq-7020
# Project: tetra-zynq-phy
#
# Usage:
#   vivado -mode batch -source scripts/program_fpga.tcl
#
# Requires: Xilinx JTAG cable connected (Digilent HS2, or LibreSDR onboard JTAG)
# =============================================================================

set PROJ_DIR  [file dirname [file dirname [info script]]]
set BIT_FILE  "$PROJ_DIR/build/tetra_zynq_phy.bit"
set LTX_FILE  "$PROJ_DIR/build/tetra_zynq_phy.ltx"

if {![file exists $BIT_FILE]} {
    puts "ERROR: Bitstream not found: $BIT_FILE"
    puts "Run vivado_build.tcl first."
    exit 1
}

puts "=== Programming LibreSDR / Zynq-7020 ==="
puts "  Bitstream: $BIT_FILE"

open_hw_manager
connect_hw_server -url localhost:3121

# Get first target (adjust if multiple cables connected)
open_hw_target [get_hw_targets]
current_hw_device [get_hw_devices xc7z020_0]

# Program
set_property PROGRAM.FILE $BIT_FILE [current_hw_device]
if {[file exists $LTX_FILE]} {
    set_property PROBES.FILE $LTX_FILE [current_hw_device]
    puts "  Debug probes: $LTX_FILE"
}

program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]

puts "\n=== Programming complete ==="
puts "Zynq PL is now running tetra_zynq_phy."
puts "Start ARM software: sw/tetra_test_rx (see sw/Makefile)"

close_hw_manager
