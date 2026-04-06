#!/bin/bash
# =============================================================================
# convert_bitstream.sh — Vivado .bit to Linux .bit.bin Conversion
# =============================================================================
# This script converts a Vivado bitstream (.bit) to Linux FPGA Manager format
# (.bit.bin) for dynamic FPGA loading without JTAG.
#
# Usage:
#   ./scripts/convert_bitstream.sh
#
# Prerequisites:
#   - Vivado 2022.2 installed and sourced
#   - build/tetra_zynq_phy.bit exists (from run_build.sh or vivado_build.tcl)
#
# Output:
#   build/tetra_zynq_phy.bit.bin — Linux-compatible bitstream
# =============================================================================

set -e  # Exit on error

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"

BITSTREAM="tetra_zynq_phy"
BIT_FILE="${BUILD_DIR}/${BITSTREAM}.bit"
BIN_FILE="${BUILD_DIR}/${BITSTREAM}.bit.bin"

# -----------------------------------------------------------------------------
# Check Prerequisites
# -----------------------------------------------------------------------------

echo "=== Bitstream Conversion for Linux FPGA Manager ==="
echo ""

# Check Vivado environment
if ! command -v bootgen &> /dev/null; then
    echo "ERROR: bootgen not found. Please source Vivado environment:"
    echo "  source /opt/Xilinx/Vivado/2022.2/settings64.sh"
    exit 1
fi

# Check input files
if [ ! -f "$BIT_FILE" ]; then
    echo "ERROR: Bitstream not found: $BIT_FILE"
    echo "Please run build first:"
    echo "  source /opt/Xilinx/Vivado/2022.2/settings64.sh"
    echo "  vivado -mode batch -source scripts/vivado_build.tcl"
    exit 1
fi

# -----------------------------------------------------------------------------
# Conversion Process
# -----------------------------------------------------------------------------

echo "Input: $BIT_FILE"
echo "Output: $BIN_FILE"
echo ""

# Create conversion BIF file (Boot Image Format)
# Use OpenWiFi-proven minimal syntax: just filename inside braces
BIF_FILE="${BUILD_DIR}/${BITSTREAM}.bif"
cat > "$BIF_FILE" << EOF
all:
{
	${BITSTREAM}.bit
}
EOF

echo "Step 1/2: Creating BIF configuration..."
echo "  $BIF_FILE"

echo ""
echo "Step 2/2: Converting bitstream..."
echo "  bootgen -w on -process_bitstream bin -image $BIF_FILE -o $BIN_FILE"

# Run bootgen
bootgen -w on -process_bitstream bin \
	-image "$BIF_FILE" \
	-o "$BIN_FILE"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

echo ""
echo "Verifying output..."

if [ ! -f "$BIN_FILE" ]; then
    echo "ERROR: Conversion failed — output file not created"
    exit 1
fi

FILE_SIZE=$(stat -c %s "$BIN_FILE" 2>/dev/null || stat -f %z "$BIN_FILE")
echo "  File size: $FILE_SIZE bytes"

if [ "$FILE_SIZE" -lt 100000 ]; then
    echo "WARNING: Output file seems too small (expected ~4 MB)"
    echo "  Conversion may have failed"
    exit 1
fi

# Check file type
FILE_TYPE=$(file -b "$BIN_FILE")
echo "  File type: $FILE_TYPE"

echo ""
echo "✅ Conversion successful!"
echo ""
echo "Output: $BIN_FILE"
echo ""
echo "Next steps:"
echo "  1. Transfer to LibreSDR:"
echo "     scp $BIN_FILE root@192.168.2.180:/lib/firmware/tetra/"
echo ""
echo "  2. Load via FPGA Manager:"
echo "     ssh root@192.168.2.180 'echo tetra/${BITSTREAM}.bit.bin > /sys/class/fpga_manager/fpga0/firmware'"
echo "     ssh root@192.168.2.180 'echo 1 > /sys/class/fpga_manager/fpga0/flags'"
echo ""
echo "  3. Follow deploy_workflow.md for complete procedure"
echo ""

# =============================================================================
# End of convert_bitstream.sh
# =============================================================================
