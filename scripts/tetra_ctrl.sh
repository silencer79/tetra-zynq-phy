#!/bin/bash
# =============================================================================
# tetra_ctrl.sh — TETRA PHY PS Register Access Utility
# Project: tetra-zynq-phy
# Date: 2026-04-08
#
# Provides convenient access to AXI-Lite registers for TETRA base station control.
# Uses busybox devmem for register read/write operations.
#
# Usage:
#   ./tetra_ctrl.sh status    — Dump all registers
#   ./tetra_ctrl.sh enable    — Enable TX+RX (set CTRL reg)
#   ./tetra_ctrl.sh monitor   — Continuous STATUS polling (wait for SYNC_LOCKED)
#   ./tetra_ctrl.sh read <offset>  — Read single register
#   ./tetra_ctrl.sh write <offset> <value> — Write single register
#
# Prerequisites:
#   - Board accessible via SSH: root@192.168.2.180
#   - busybox devmem available
#   - FPGA bitstream loaded
#   - AD9361 initialized (ad9361_init.sh)
# =============================================================================

set -e

# Board connection parameters
BOARD_IP="192.168.2.180"
BOARD_USER="root"
BOARD_PASS="openwifi"

# AXI-Lite base address (AXI GP0 aperture)
BASE_ADDR="0x43C00000"

# Register offsets (from tetra_axi_lite_regs.v line 14-38)
REG_CTRL="0x00"          # [0]=RX_EN [1]=TX_EN [2]=LOOPBACK [3]=RST_CNTRS
REG_STATUS="0x04"        # [0]=SYNC_LOCKED [1]=PLL_LOCKED [2]=FIFO_EMPTY [3]=FIFO_FULL
REG_VERSION="0x08"       # Hardware version (RO)
REG_SYNC_THRESH="0x0C"   # Sync correlator threshold
REG_COLOUR_CODE="0x10"  # TETRA colour code
REG_FRAME_NUM="0x14"     # Current frame number (RO)
REG_SLOT_NUM="0x18"      # Current slot number (RO)
REG_IRQ_STATUS="0x28"    # IRQ status bits

# SSH command helper
ssh_cmd() {
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "$@"
}

# Read register via devmem
read_reg() {
    local offset="$1"
    local addr=$((BASE_ADDR + offset))
    local value=$(ssh_cmd "busybox devmem $addr 2>/dev/null")
    echo "$value"
}

# Write register via devmem
write_reg() {
    local offset="$1"
    local value="$2"
    local addr=$((BASE_ADDR + offset))
    ssh_cmd "busybox devmem $addr 32 $value"
}

# Convert hex to binary with bit fields
format_status() {
    local status_hex="$1"
    local status_dec=$(($status_hex))

    local sync_locked=$(( (status_dec >> 0) & 0x1 ))
    local pll_locked=$(( (status_dec >> 1) & 0x1 ))
    local fifo_empty=$(( (status_dec >> 2) & 0x1 ))
    local fifo_full=$(( (status_dec >> 3) & 0x1 ))

    echo "STATUS[$status_hex] = SYNC_LOCKED=$sync_locked PLL_LOCKED=$pll_locked FIFO_EMPTY=$fifo_empty FIFO_FULL=$fifo_full"
}

# Command: status — dump all registers
cmd_status() {
    echo "=== TETRA PHY Register Dump ==="
    echo "Base Address: $BASE_ADDR"
    echo ""

    local ctrl=$(read_reg "$REG_CTRL")
    echo "CTRL   [0x00]: $ctrl"

    local status=$(read_reg "$REG_STATUS")
    echo "STATUS [0x04]: $status"
    format_status "$status"

    local version=$(read_reg "$REG_VERSION")
    echo "VERSION[0x08]: $version"

    local sync_thresh=$(read_reg "$REG_SYNC_THRESH")
    echo "SYNC_THRESH[0x0C]: $sync_thresh"

    local colour=$(read_reg "$REG_COLOUR_CODE")
    echo "COLOUR_CODE[0x10]: $colour"

    local frame=$(read_reg "$REG_FRAME_NUM")
    echo "FRAME_NUM  [0x14]: $frame"

    local slot=$(read_reg "$REG_SLOT_NUM")
    echo "SLOT_NUM   [0x18]: $slot"

    local irq=$(read_reg "$REG_IRQ_STATUS")
    echo "IRQ_STATUS [0x28]: $irq"

    echo ""
    echo "=== Interpretation ==="
    echo "CTRL bits: TX_EN=$(( ($ctrl >> 1) & 1 )) RX_EN=$(( $ctrl & 1 ))"
    echo "VERSION: Major.$(( ($version >> 8) & 0xFF )).Patch=$(( $version & 0xFF ))"
}

# Command: enable — set TX_EN + RX_EN
cmd_enable() {
    echo "Enabling TX and RX..."
    # CTRL[0]=RX_EN, CTRL[1]=TX_EN
    write_reg "$REG_CTRL" "0x00000003"
    echo "CTRL register set to 0x00000003 (TX_EN=1, RX_EN=1)"

    # Verify
    local ctrl=$(read_reg "$REG_CTRL")
    echo "Verified CTRL = $ctrl"
}

# Command: loopback — set TX_EN + RX_EN + LOOPBACK_EN
cmd_loopback() {
    echo "Enabling digital loopback (TX→RX)..."
    # CTRL[0]=RX_EN, CTRL[1]=TX_EN, CTRL[2]=LOOPBACK
    write_reg "$REG_CTRL" "0x00000007"
    echo "CTRL register set to 0x00000007 (RX_EN=1, TX_EN=1, LOOPBACK=1)"

    # Verify
    local ctrl=$(read_reg "$REG_CTRL")
    local ctrl_dec=$(($ctrl))
    echo "Verified CTRL = $ctrl"
    echo "  RX_EN=$(( ctrl_dec & 1 ))  TX_EN=$(( (ctrl_dec >> 1) & 1 ))  LOOPBACK=$(( (ctrl_dec >> 2) & 1 ))"
    echo ""
    echo "Loopback active — TX output routed to RX input."
    echo "RX chain should now see TX samples. Run: $0 monitor"
}

# Command: disable — clear CTRL register
cmd_disable() {
    echo "Disabling TX and RX..."
    write_reg "$REG_CTRL" "0x00000000"
    echo "CTRL register cleared (all disabled)"

    local ctrl=$(read_reg "$REG_CTRL")
    echo "Verified CTRL = $ctrl"
}

# Command: monitor — poll STATUS until SYNC_LOCKED=1
cmd_monitor() {
    echo "Monitoring STATUS register (Ctrl+C to stop)..."
    echo "Waiting for SYNC_LOCKED=1..."
    echo ""

    local count=0
    while true; do
        local status=$(read_reg "$REG_STATUS")
        local status_dec=$(($status))
        local sync_locked=$(( (status_dec >> 0) & 0x1 ))

        printf "\r[%04d] STATUS=0x%s SYNC_LOCKED=%d" "$count" "$status" "$sync_locked"

        if [ "$sync_locked" -eq 1 ]; then
            echo ""
            echo ""
            echo "✓ SYNC_LOCKED detected! TX successfully received by RX."
            echo ""
            format_status "$status"
            return 0
        fi

        count=$((count + 1))
        sleep 1
    done
}

# Command: read — single register
cmd_read() {
    if [ -z "$1" ]; then
        echo "Usage: $0 read <offset>"
        echo "Example: $0 read 0x04"
        exit 1
    fi
    local offset="$1"
    local value=$(read_reg "$offset")
    echo "Register $offset = $value"
}

# Command: write — single register
cmd_write() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: $0 write <offset> <value>"
        echo "Example: $0 write 0x00 0x00000003"
        exit 1
    fi
    local offset="$1"
    local value="$2"
    write_reg "$offset" "$value"
    echo "Wrote $value to register $offset"
}

# Main entry point
case "${1:-}" in
    status)
        cmd_status
        ;;
    enable)
        cmd_enable
        ;;
    loopback)
        cmd_loopback
        ;;
    disable)
        cmd_disable
        ;;
    monitor)
        cmd_monitor
        ;;
    read)
        cmd_read "$2"
        ;;
    write)
        cmd_write "$2" "$3"
        ;;
    *)
        echo "TETRA PHY Control Utility"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  status          — Dump all registers"
        echo "  enable          — Enable TX+RX (CTRL=0x03)"
        echo "  loopback        — Enable TX+RX+Loopback (CTRL=0x07)"
        echo "  disable         — Clear CTRL register"
        echo "  monitor         — Poll STATUS every 1s until SYNC_LOCKED=1"
        echo "  read <offset>   — Read single register"
        echo "  write <offset> <value> — Write single register"
        echo ""
        echo "Loopback test workflow:"
        echo "  $0 loopback     # TX→RX digital loopback aktivieren"
        echo "  $0 monitor      # Warten auf SYNC_LOCKED=1"
        echo ""
        echo "Example:"
        echo "  $0 status"
        echo "  $0 enable"
        echo "  $0 monitor"
        exit 1
        ;;
esac
