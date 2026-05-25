# =============================================================================
# export_xsa.tcl — Export XSA from Implemented Design
# Project: tetra-zynq-phy
#
# Usage:
# vivado -mode batch -source scripts/export_xsa.tcl
#
# Prerequisites:
# - build/post_route.dcp exists (implementation checkpoint)
# - build/tetra_zynq_phy.bit exists
#
# Output:
# build/tetra_zynq_phy.xsa — Hardware export with bitstream
# =============================================================================

set PROJ_NAME "tetra_zynq_phy"
set PROJ_DIR [file dirname [file dirname [info script]]]
set BUILD_DIR "$PROJ_DIR/build"

puts "================================================================="
puts " Export XSA from Implemented Design"
puts "================================================================="

# Check if checkpoint exists
set dcp_file "$BUILD_DIR/post_route.dcp"
if {![file exists $dcp_file]} {
 puts "ERROR: Implementation checkpoint not found: $dcp_file"
 puts "Please run full build first: vivado -mode batch -source scripts/vivado_build.tcl"
 exit 1
}

# Check if bitstream exists
set bit_file "$BUILD_DIR/${PROJ_NAME}.bit"
if {![file exists $bit_file]} {
 puts "ERROR: Bitstream not found: $bit_file"
 puts "Please run full build first: vivado -mode batch -source scripts/vivado_build.tcl"
 exit 1
}

puts "\\n=== Step 1: Opening implemented design ==="
puts " Checkpoint: $dcp_file"

open_checkpoint $dcp_file

puts "\\n=== Step 2: Exporting Hardware (Include Bitstream) ==="

# Export hardware platform with bitstream included
set xsa_file "$BUILD_DIR/${PROJ_NAME}.xsa"
write_hw_platform -fixed -include_bit -force -file $xsa_file

puts "\\n================================================================="
puts " XSA Export COMPLETE"
puts "================================================================="
puts " XSA: $xsa_file"
puts ""
puts "Next steps:"
puts " 1. Convert bitstream:./scripts/convert_bitstream.sh"
puts " 2. Follow deploy_workflow.md for deployment"
puts "================================================================="

close_project
