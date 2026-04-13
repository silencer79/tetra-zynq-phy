#!/bin/bash
# =============================================================================
# deploy.sh — Build, Convert, Upload, Init, Run
# Project: tetra-zynq-phy
#
# One-command pipeline from Vivado source to running TETRA basestation:
#   1. Vivado synthesis + implementation + bitstream generation
#   2. bootgen .bit → .bit.bin conversion (FPGA Manager format)
#   3. SCP upload to LibreSDR
#   4. Full board init (2x bitstream + 2x AD9361 + DAC/ADC)
#   5. Cross-compile + upload tetra_sysinfo
#   6. Run tetra_sysinfo (SYSINFO + NCO + enable TX/RX)
#
# Usage:
#   ./scripts/deploy.sh              # full pipeline (build + deploy + init)
#   ./scripts/deploy.sh --no-build   # skip Vivado build (use existing .bit)
#   ./scripts/deploy.sh --no-init    # skip board init (just upload)
#   ./scripts/deploy.sh --no-sw      # skip SW compile + upload
#   ./scripts/deploy.sh --build-only # only run Vivado build
#
# Prerequisites:
#   - Vivado 2022.2 (auto-detected or in PATH)
#   - arm-linux-gnueabihf-gcc (cross compiler)
#   - sshpass, scp, ssh
#   - Board accessible: root@192.168.2.180
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"

BOARD_IP="192.168.2.180"
BOARD_USER="root"
BOARD_PASS="openwifi"

BITSTREAM_NAME="tetra_zynq_phy"
BIT_FILE="${BUILD_DIR}/${BITSTREAM_NAME}.bit"
BIN_FILE="${BUILD_DIR}/${BITSTREAM_NAME}.bit.bin"

REMOTE_FW_DIR="/lib/firmware"
REMOTE_BIN_DIR="/root"

# Flags
DO_BUILD=true
DO_INIT=true
DO_SW=true

# =============================================================================
# Argument parsing
# =============================================================================

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=false ;;
        --no-init)    DO_INIT=false ;;
        --no-sw)      DO_SW=false ;;
        --build-only) DO_BUILD=true; DO_INIT=false; DO_SW=false ;;
        -h|--help)
            echo "Usage: $0 [--no-build] [--no-init] [--no-sw] [--build-only]"
            echo ""
            echo "  --no-build    Skip Vivado build (use existing .bit)"
            echo "  --no-init     Skip board init (just upload)"
            echo "  --no-sw       Skip SW cross-compile + upload"
            echo "  --build-only  Only run Vivado build, nothing else"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# =============================================================================
# Helper functions
# =============================================================================

ssh_cmd() {
    sshpass -p "$BOARD_PASS" ssh -o StrictHostKeyChecking=no "$BOARD_USER@$BOARD_IP" "$@"
}

scp_to() {
    sshpass -p "$BOARD_PASS" scp -o StrictHostKeyChecking=no "$1" "$BOARD_USER@$BOARD_IP:$2"
}

step() {
    echo ""
    echo "=== $1 ==="
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# =============================================================================
# Step 1: Vivado Build
# =============================================================================

if $DO_BUILD; then
    step "1/6: Vivado Build"

    # Find Vivado
    if command -v vivado &>/dev/null; then
        VIVADO=vivado
    elif [ -x /opt/Xilinx/Vivado/2022.2/bin/vivado ]; then
        VIVADO=/opt/Xilinx/Vivado/2022.2/bin/vivado
    else
        fail "Vivado not found. Source settings64.sh or install Vivado 2022.2"
    fi

    echo "Using: $VIVADO"
    echo "Building..."

    cd "$PROJECT_ROOT"
    $VIVADO -mode batch -source scripts/vivado_build.tcl 2>&1 | tee "${BUILD_DIR}/vivado_build.log" | \
        grep -E "^(Phase|INFO.*Timing|ERROR|WARNING.*timing|Build|Bitstream)" || true

    if [ ! -f "$BIT_FILE" ]; then
        fail "Bitstream not generated: $BIT_FILE"
    fi

    echo "Bitstream: $BIT_FILE ($(stat -c %s "$BIT_FILE") bytes)"
else
    step "1/6: Vivado Build [SKIPPED]"
    [ -f "$BIT_FILE" ] || fail "No bitstream found: $BIT_FILE"
fi

# =============================================================================
# Step 2: Convert .bit → .bit.bin
# =============================================================================

step "2/6: Bitstream Conversion (.bit → .bit.bin)"

if ! command -v bootgen &>/dev/null; then
    # Try sourcing Vivado env
    if [ -f /opt/Xilinx/Vivado/2022.2/settings64.sh ]; then
        source /opt/Xilinx/Vivado/2022.2/settings64.sh
    else
        fail "bootgen not found. Source Vivado settings64.sh"
    fi
fi

BIF_FILE="${BUILD_DIR}/${BITSTREAM_NAME}.bif"
cat > "$BIF_FILE" << EOF
all:
{
	$(basename "$BIT_FILE")
}
EOF

(cd "$BUILD_DIR" && bootgen -w on -process_bitstream bin -image "$BIF_FILE" -o "$BIN_FILE")

[ -f "$BIN_FILE" ] || fail "Conversion failed"
echo "Output: $BIN_FILE ($(stat -c %s "$BIN_FILE") bytes)"

# =============================================================================
# Step 3: Upload bitstream to board
# =============================================================================

step "3/6: Upload Bitstream"

echo "Uploading to ${BOARD_IP}:${REMOTE_FW_DIR}/"
scp_to "$BIN_FILE" "${REMOTE_FW_DIR}/${BITSTREAM_NAME}.bit.bin"
echo "Done"

# =============================================================================
# Step 4: Cross-compile + upload SW
# =============================================================================

if $DO_SW; then
    step "4/6: Cross-Compile + Upload SW"

    CROSS=arm-linux-gnueabihf-gcc
    if ! command -v $CROSS &>/dev/null; then
        fail "$CROSS not found. Install: apt install gcc-arm-linux-gnueabihf"
    fi

    SW_DIR="${PROJECT_ROOT}/sw"
    SW_BIN="${SW_DIR}/tetra_sysinfo"

    echo "Compiling tetra_sysinfo..."
    $CROSS -O2 -Wall -static -o "$SW_BIN" "${SW_DIR}/tetra_hal.c" -I"${SW_DIR}" -lm
    echo "Binary: $SW_BIN ($(stat -c %s "$SW_BIN") bytes)"

    echo "Uploading to ${BOARD_IP}:${REMOTE_BIN_DIR}/"
    scp_to "$SW_BIN" "${REMOTE_BIN_DIR}/tetra_sysinfo"
    echo "Done"
else
    step "4/6: Cross-Compile + Upload SW [SKIPPED]"
fi

# =============================================================================
# Step 5: Full board init
# =============================================================================

if $DO_INIT; then
    step "5/6: Full Board Init (2x bitstream + 2x AD9361 + DAC/ADC)"

    bash "${SCRIPT_DIR}/tetra_ctrl.sh" full_init

    echo "Board initialized"
else
    step "5/6: Full Board Init [SKIPPED]"
fi

# =============================================================================
# Step 6: Run tetra_sysinfo
# =============================================================================

if $DO_INIT && $DO_SW; then
    step "6/6: Run tetra_sysinfo (SYSINFO + NCO 106 kHz + TX/RX enable)"

    ssh_cmd "/root/tetra_sysinfo --nco 106000"

    echo ""
    echo "================================================"
    echo " DEPLOY COMPLETE"
    echo "================================================"
    echo " Bitstream : ${BITSTREAM_NAME}.bit.bin"
    echo " NCO       : 106 kHz (signal at TX_LO + 106 kHz)"
    echo " TX/RX     : enabled"
    echo ""
    echo " Next: ./scripts/tetra_ctrl.sh status"
    echo "        ./scripts/tetra_ctrl.sh rf_loopback"
    echo "================================================"
else
    step "6/6: Run tetra_sysinfo [SKIPPED]"
    echo ""
    echo "================================================"
    echo " DEPLOY COMPLETE (partial)"
    echo "================================================"
    echo " Bitstream uploaded to board."
    echo " Run manually:"
    echo "   ./scripts/tetra_ctrl.sh full_init"
    echo "   ssh root@${BOARD_IP} /root/tetra_sysinfo --nco 106000"
    echo "================================================"
fi
