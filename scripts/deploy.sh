#!/bin/bash
# =============================================================================
# deploy.sh — Build, Convert, Upload
# Project: tetra-zynq-phy
#
# Pipeline from Vivado source to files on the LibreSDR:
#   1. Vivado synthesis + implementation + bitstream generation
#   2. bootgen .bit → .bit.bin conversion (FPGA Manager format)
#   3. Cross-compile tetra_sysinfo
#   4. SCP upload bitstream + tetra_sysinfo to LibreSDR
#
# After deploy, run manually on the board:
#   ./scripts/tetra_ctrl.sh full_init
#   ./scripts/tetra_ctrl.sh rf_loopback
#
# Usage:
#   ./scripts/deploy.sh              # full pipeline (build + convert + compile + upload)
#   ./scripts/deploy.sh --no-build   # skip Vivado build (use existing .bit)
#   ./scripts/deploy.sh --no-sw      # skip SW compile + upload
#   ./scripts/deploy.sh --build-only # only run Vivado build
#   ./scripts/deploy.sh --init       # also run full_init + tetra_sysinfo after upload
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
DO_SW=true
DO_INIT=false  # off by default — opt-in with --init

# =============================================================================
# Argument parsing
# =============================================================================

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=false ;;
        --no-sw)      DO_SW=false ;;
        --build-only) DO_BUILD=true; DO_SW=false ;;
        --init)       DO_INIT=true ;;
        -h|--help)
            echo "Usage: $0 [--no-build] [--no-sw] [--build-only] [--init]"
            echo ""
            echo "  --no-build    Skip Vivado build (use existing .bit)"
            echo "  --no-sw       Skip SW cross-compile + upload"
            echo "  --build-only  Only run Vivado build, nothing else"
            echo "  --init        Also run full_init + tetra_sysinfo after upload"
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
    step "1/4: Vivado Build"

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
    # Delete stale bitstream first — otherwise a synth failure leaves the
    # previous .bit in place and the existence check below passes silently.
    rm -f "$BIT_FILE"
    set +e
    $VIVADO -mode batch -source scripts/vivado_build.tcl 2>&1 | tee "${BUILD_DIR}/vivado_build.log" | \
        grep -E "^(Phase|INFO.*Timing|ERROR|WARNING.*timing|Build|Bitstream)"
    viv_rc=${PIPESTATUS[0]}
    set -e
    if [ "$viv_rc" -ne 0 ]; then
        fail "Vivado build failed (exit $viv_rc) — see ${BUILD_DIR}/vivado_build.log"
    fi

    if [ ! -f "$BIT_FILE" ]; then
        fail "Bitstream not generated: $BIT_FILE"
    fi

    echo "Bitstream: $BIT_FILE ($(stat -c %s "$BIT_FILE") bytes)"
else
    step "1/4: Vivado Build [SKIPPED]"
    [ -f "$BIT_FILE" ] || fail "No bitstream found: $BIT_FILE"
fi

# =============================================================================
# Step 2: Convert .bit → .bit.bin
# =============================================================================

step "2/4: Bitstream Conversion (.bit → .bit.bin)"

if ! command -v bootgen &>/dev/null; then
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

# Stop here if build-only
if $DO_BUILD && ! $DO_SW && [ "${1:-}" = "--build-only" ]; then
    echo ""
    echo "Build complete. Run: $0 --no-build to upload."
    exit 0
fi

# =============================================================================
# Step 3: Cross-compile tetra_sysinfo
# =============================================================================

if $DO_SW; then
    step "3/4: Cross-Compile tetra_sysinfo"

    CROSS=arm-linux-gnueabihf-gcc
    if ! command -v $CROSS &>/dev/null; then
        fail "$CROSS not found. Install: apt install gcc-arm-linux-gnueabihf"
    fi

    SW_DIR="${PROJECT_ROOT}/sw"
    SW_BIN="${SW_DIR}/tetra_sysinfo"

    echo "Compiling tetra_sysinfo..."
    $CROSS -O2 -Wall -static -o "$SW_BIN" "${SW_DIR}/tetra_hal.c" -I"${SW_DIR}" -lm
    echo "Binary: $SW_BIN ($(stat -c %s "$SW_BIN") bytes)"
else
    step "3/4: Cross-Compile tetra_sysinfo [SKIPPED]"
fi

# =============================================================================
# Step 4: Upload to board
# =============================================================================

step "4/4: Upload to ${BOARD_IP}"

# Check board reachable
if ! sshpass -p "$BOARD_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$BOARD_USER@$BOARD_IP" "echo OK" &>/dev/null; then
    fail "Board not reachable at ${BOARD_IP}"
fi

# Kill running tetra_sysinfo before upload
ssh_cmd "killall tetra_sysinfo 2>/dev/null || true"

# Upload bitstream
echo "Uploading bitstream..."
scp_to "$BIN_FILE" "${REMOTE_FW_DIR}/${BITSTREAM_NAME}.bit.bin"

# Verify bitstream
LOCAL_MD5=$(md5sum "$BIN_FILE" | cut -d' ' -f1)
REMOTE_MD5=$(ssh_cmd "md5sum ${REMOTE_FW_DIR}/${BITSTREAM_NAME}.bit.bin" | cut -d' ' -f1)
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    fail "MD5 mismatch! Local=$LOCAL_MD5 Remote=$REMOTE_MD5"
fi
echo "Bitstream verified (MD5: $LOCAL_MD5)"

# Upload tetra_sysinfo
if $DO_SW; then
    SW_BIN="${PROJECT_ROOT}/sw/tetra_sysinfo"
    echo "Uploading tetra_sysinfo..."
    scp_to "$SW_BIN" "${REMOTE_BIN_DIR}/tetra_sysinfo"
    ssh_cmd "chmod +x ${REMOTE_BIN_DIR}/tetra_sysinfo"
    echo "tetra_sysinfo uploaded"
fi

# =============================================================================
# Optional: Full init + tetra_sysinfo
# =============================================================================

if $DO_INIT; then
    step "Running full_init + tetra_sysinfo"

    bash "${SCRIPT_DIR}/tetra_ctrl.sh" full_init

    ssh_cmd "nohup /root/tetra_sysinfo > /tmp/tetra_sysinfo.log 2>&1 &"
    echo "tetra_sysinfo started in background"
fi

# =============================================================================
# Done
# =============================================================================

echo ""
echo "================================================"
echo " DEPLOY COMPLETE"
echo "================================================"
echo " Bitstream : ${BITSTREAM_NAME}.bit.bin (verified)"
if $DO_SW; then
echo " SW        : tetra_sysinfo"
fi
echo ""
if ! $DO_INIT; then
echo " Next steps:"
echo "   ./scripts/tetra_ctrl.sh full_init"
echo "   ssh root@${BOARD_IP} 'nohup /root/tetra_sysinfo > /tmp/tetra_sysinfo.log 2>&1 &'"
echo "   ./scripts/tetra_ctrl.sh rf_loopback"
echo "   ./scripts/tetra_ctrl.sh monitor"
fi
echo "================================================"
