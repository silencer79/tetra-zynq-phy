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
#   ./tetra_ctrl.sh tx_monitor — Configure AD9361 internal TX monitor path
#   ./tetra_ctrl.sh rf_loopback — Configure external RF loopback path
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

# ADI axi_ad9361 register space base addresses (AXI-Lite aperture, 0x7902_0000)
# ADC core: 0x7902_0000 (up_adc registers start at IP base)
# DAC core: 0x7902_4000 (up_dac registers start at IP base + 0x4000)
ADC_BASE="0x79020000"
DAC_BASE="0x79024000"

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
# Sets SYNC_THRESH, resets counters, then enables digital loopback.
# Prerequisite: full_init (DAC/ADC cores must be initialized after bitstream load).
cmd_loopback() {
    local sync_thresh="${2:-15}"

    echo "Enabling digital loopback (TX→RX), SYNC_THRESH=${sync_thresh}..."

    # 1. Set sync threshold
    write_reg "$REG_SYNC_THRESH" "$sync_thresh"
    echo "SYNC_THRESH = $sync_thresh"

    # 2. Reset counters (RST_CNTRS bit3) with LOOPBACK|TX_EN|RX_EN
    write_reg "$REG_CTRL" "0x0000000F"
    sleep 0.1
    # 3. Clear RST_CNTRS, keep LOOPBACK|TX_EN|RX_EN
    write_reg "$REG_CTRL" "0x00000007"
    echo "CTRL register set to 0x00000007 (LOOPBACK=1, TX_EN=1, RX_EN=1)"

    # Verify
    local ctrl=$(read_reg "$REG_CTRL")
    local ctrl_dec=$(($ctrl))
    local thresh=$(read_reg "$REG_SYNC_THRESH")
    echo "Verified CTRL = $ctrl"
    echo "  RX_EN=$(( ctrl_dec & 1 ))  TX_EN=$(( (ctrl_dec >> 1) & 1 ))  LOOPBACK=$(( (ctrl_dec >> 2) & 1 ))"
    echo "  SYNC_THRESH = $thresh"
    echo ""
    echo "Loopback active — TX output routed to RX input."
    echo "RX chain should now see TX samples. Run: $0 monitor"
}

# Command: dac_init — initialize ADI axi_ad9361 DAC core
# Required after every bitstream load. Three-step sequence:
#   1. RSTN=0x3    — release core reset + MMCM reset (common block, 0x40)
#   2. CNTRL_2=0x20 — set r1_mode=1 (1R1T mode, common block, 0x48)
#   3. CH0/CH1 dac_data_sel=2 — CRITICAL: select fabric data from FPGA
#      per-channel registers at 0x418 (CH0) and 0x458 (CH1)
#      Address derivation: up_waddr[13:8]=0x11 (COMMON_ID), [7:4]=channel, [3:0]=0x6 (data_sel reg)
#      CH0: up_waddr=0x1106 → offset=0x4418 → DAC_BASE+0x418
#      CH1: up_waddr=0x1116 → offset=0x4458 → DAC_BASE+0x458
#      Reset value=0 → selects DDS output → DDS is disabled (DAC_DDS_DISABLE=1) → zero output!
#      Without this step: DAC outputs zero, only LO leakage visible on RF (TX appears dead).
cmd_dac_init() {
    echo "Initializing ADI axi_ad9361 DAC core @ ${DAC_BASE}..."
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        DAC=${DAC_BASE}
        # 1. Release core reset + MMCM reset (bits[1:0]=11)
        busybox devmem \$((DAC+0x40)) 32 0x3
        # 2. CNTRL_2: r1_mode=1 (bit5, 1R1T mode)
        busybox devmem \$((DAC+0x48)) 32 0x20
        # 3. CRITICAL: set per-channel dac_data_sel=2 (fabric data from FPGA)
        #    Reset default=0 → DDS mode → DDS disabled → zero output → TX dead!
        busybox devmem \$((DAC+0x418)) 32 0x2    # CH0 (I) data_sel = fabric
        busybox devmem \$((DAC+0x458)) 32 0x2    # CH1 (Q) data_sel = fabric
        # Verify
        RSTN=\$(busybox devmem \$((DAC+0x40)) 32)
        CNTRL2=\$(busybox devmem \$((DAC+0x48)) 32)
        STATUS=\$(busybox devmem \$((DAC+0x68)) 32)
        CH0SEL=\$(busybox devmem \$((DAC+0x418)) 32)
        CH1SEL=\$(busybox devmem \$((DAC+0x458)) 32)
        printf 'DAC RSTN=0x%08X CNTRL_2=0x%08X STATUS=0x%08X\n' \$RSTN \$CNTRL2 \$STATUS
        printf 'CH0_DATSEL=0x%08X CH1_DATSEL=0x%08X\n' \$CH0SEL \$CH1SEL
    "
    echo "DAC core initialized (fabric data mode active on CH0+CH1)"
}

# Command: adc_init — initialize ADI axi_ad9361 ADC core
# Required after every bitstream load. Releases ADC core and MMCM from reset.
# CRITICAL: CNTRL (0x44) bit2=r1_mode MUST be 0 for 2R2T DDR (LibreSDR DATA_CLK=18.432 MHz).
#   r1_mode=0 → 2R2T DDR frame detection → adc_valid_p fires at 4.608 MHz ✓
#   r1_mode=1 → 1R1T frame detection → WRONG for 2R2T → adc_valid_p stuck at 0 → SYNC=0 ✗
# ADC_BASE = 0x79020000 (IP base, ADC sub-core is the first block)
# Register layout: +0x40=RSTN, +0x44=CNTRL (bit2=r1_mode), +0x5C=STATUS, +0x58=CLK_RATIO
# Per-channel: +0x400=CH0_CNTRL (bit0=enable), +0x440=CH1_CNTRL
cmd_adc_init() {
    echo "Initializing ADI axi_ad9361 ADC core @ ${ADC_BASE}..."
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        ADC=${ADC_BASE}
        # 1. Release core reset + MMCM reset (bits[1:0]=11)
        busybox devmem \$((ADC+0x40)) 32 0x3
        # 2. CNTRL: r1_mode=0 (bit2=0) — MUST be 0 for 2R2T DDR (DATA_CLK=18.432 MHz)
        #    AD9361 on LibreSDR uses 2R2T DDR LVDS (DATA_CLK = 4× sample_rate = 18.432 MHz).
        #    r1_mode=0 → case 5'b00000 (frame_s=00, frame=00) fires at 4.608 MHz → valid ✓
        #    r1_mode=1 → case 5'b10011 (frame_s=00, frame=11) expects 1R1T (DATA_CLK=9.216 MHz)
        #               → frame pattern never matches in 2R2T mode → adc_valid_p stuck at 0!
        busybox devmem \$((ADC+0x44)) 32 0x0
        # 3. Enable per-channel data path (bit0=enable)
        # 3. Enable channel + data format: bit0=enable, bit4=dfmt_enable, bit6=dfmt_se
        #    dfmt_se=1 + dfmt_enable=1: sign-extend 12-bit 2's complement ADC data to 16 bits.
        #    Without this (writing 0x1), ad_datafmt ZERO-extends → negative ADC values become
        #    large positive → signal is rectified → demodulator/sync_detect fail completely.
        #    dfmt_type=0 (bit5): AD9361 already outputs 2's complement, no offset binary conversion.
        #    Value: (1<<6)|(1<<4)|(1<<0) = 0x51
        busybox devmem \$((ADC+0x400)) 32 0x51  # CH0 (I): enable + sign-extend 12→16
        busybox devmem \$((ADC+0x440)) 32 0x51  # CH1 (Q): enable + sign-extend 12→16
        # Verify
        RSTN=\$(busybox devmem \$((ADC+0x40)) 32)
        CNTRL=\$(busybox devmem \$((ADC+0x44)) 32)
        STATUS=\$(busybox devmem \$((ADC+0x5C)) 32)
        CLK_RATIO=\$(busybox devmem \$((ADC+0x58)) 32)
        CH0EN=\$(busybox devmem \$((ADC+0x400)) 32)
        CH1EN=\$(busybox devmem \$((ADC+0x440)) 32)
        printf 'ADC RSTN=0x%08X CNTRL=0x%08X STATUS=0x%08X CLK_RATIO=0x%08X\n' \$RSTN \$CNTRL \$STATUS \$CLK_RATIO
        printf 'CH0=0x%08X CH1=0x%08X (0x51=enable+dfmt_se+dfmt_enable, r1_mode=0=2R2T)\n' \$CH0EN \$CH1EN
    "
    echo "ADC core initialized (r1_mode=0, CH0+CH1 enabled)"
}

# Command: tx_monitor — configure AD9361 internal TX→RX monitor path
# Uses equal RX/TX LO so the RX chain can observe the transmitted spectrum
# through the chip-internal monitor path without external RF coupling.
cmd_tx_monitor() {
    local mon_freq="${2:-440000000}"

    echo "Configuring AD9361 internal TX monitor path @ ${mon_freq} Hz..."
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        set -e
        iio_attr -c ad9361-phy altvoltage0 frequency ${mon_freq} >/dev/null
        iio_attr -c ad9361-phy altvoltage1 frequency ${mon_freq} >/dev/null
        # libiio may return a non-zero code here even when the monitor port
        # switch actually took effect, so verify by readback instead of exit code.
        set +e
        iio_attr -c ad9361-phy voltage0 rf_port_select TX_MONITOR1_2 >/dev/null 2>&1
        set -e
        RX_PORT=\$(iio_attr -c ad9361-phy voltage0 rf_port_select 2>/dev/null | head -1)
        if [[ \"\$RX_PORT\" != \"TX_MONITOR1_2\" ]]; then
            echo \"ERROR: rf_port_select readback is '\$RX_PORT', expected TX_MONITOR1_2\" >&2
            exit 1
        fi
        iio_attr -c ad9361-phy voltage0 gain_control_mode slow_attack >/dev/null
        iio_attr -d ad9361-phy ensm_mode fdd >/dev/null
        DAC=${DAC_BASE}
        busybox devmem \$((DAC+0x40)) 32 0x3   >/dev/null
        busybox devmem \$((DAC+0x48)) 32 0x20  >/dev/null
        busybox devmem \$((DAC+0x418)) 32 0x2  >/dev/null
        busybox devmem \$((DAC+0x458)) 32 0x2  >/dev/null
        busybox devmem $((BASE_ADDR + 0x00)) 32 0x00000003 >/dev/null
        echo RX_LO=\$(iio_attr -c ad9361-phy altvoltage0 frequency 2>/dev/null | head -1)
        echo TX_LO=\$(iio_attr -c ad9361-phy altvoltage1 frequency 2>/dev/null | head -1)
        echo RX_PORT=\$RX_PORT
        echo ENSM=\$(iio_attr -d ad9361-phy ensm_mode 2>/dev/null | head -1)
        echo CTRL=\$(busybox devmem $((BASE_ADDR + 0x00)) 32)
    "
    echo "Internal TX monitor path active. Run: $0 monitor"
}

# Command: rf_loopback — configure external RF TX→RX loopback path
# Uses normal RF input (A_BALANCED), SAME LO for TX and RX (loopback requires
# TX_LO == RX_LO so the TETRA signal falls within the RX passband), AGC on RX,
# DAC fabric-data mode, and resets counters before enabling TX+RX.
#
# TX Attenuation (tx_att_db, 4th arg, default -50):
#   WICHTIG: out_voltage0_hardwaregain = TX1 (aktiver RF-Ausgang auf LibreSDR)
#            out_voltage1_hardwaregain = TX2 (nicht verbunden — hat KEINE Wirkung!)
#   AGC-Sweep verifiziert 2026-04-13 (10cm Luft-Loopback):
#     -30 dB → AGC ≈ 28 dB  (zu stark für stabilen Lock)
#     -40 dB → AGC ≈ 40 dB  (Untergrenze OK)
#     -50 dB → AGC ≈ 47 dB  (optimal, Default)
#     -55 dB → AGC ≈ 52 dB  (gut)
#     -60 dB → AGC ≈ 58 dB  (nahe Obergrenze)
#   Format: negative dB direkt (nicht millidB), Bereich 0 bis -89.
cmd_rf_loopback() {
    local rx_freq="${2:-430000000}"
    local tx_freq="${3:-430000000}"
    local sync_thresh="${4:-15}"
    local tx_att_db="${5:--50}"

    echo "Configuring external RF loopback path RX=${rx_freq} Hz TX=${tx_freq} Hz TX_ATT=${tx_att_db} dB..."
    if [[ "$rx_freq" != "$tx_freq" ]]; then
        echo "WARN: TX_LO (${tx_freq}) != RX_LO (${rx_freq}). TX signal will be ${tx_freq-rx_freq} Hz outside RX passband — loopback will NOT work!"
    fi

    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        set -e
        iio_attr -c ad9361-phy altvoltage0 frequency ${rx_freq} >/dev/null
        iio_attr -c ad9361-phy altvoltage1 frequency ${tx_freq} >/dev/null
        # libiio may return a non-zero code here even when the port switch
        # succeeded, so verify by readback instead of trusting the exit code.
        set +e
        iio_attr -c ad9361-phy voltage0 rf_port_select A_BALANCED >/dev/null 2>&1
        set -e
        RX_PORT=\$(iio_attr -c ad9361-phy voltage0 rf_port_select 2>/dev/null | head -1)
        if [[ \"\$RX_PORT\" != \"A_BALANCED\" ]]; then
            echo \"ERROR: rf_port_select readback is '\$RX_PORT', expected A_BALANCED\" >&2
            exit 1
        fi
        iio_attr -c ad9361-phy voltage0 gain_control_mode slow_attack >/dev/null
        iio_attr -d ad9361-phy ensm_mode fdd >/dev/null

        # TX1 Dämpfung setzen — out_voltage0 = TX1 (aktiver Ausgang), out_voltage1 = TX2 (ungenutzt)
        SYSFS=\$(grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
        if [[ -n \"\$SYSFS\" ]]; then
            echo ${tx_att_db} > \"\${SYSFS}/out_voltage0_hardwaregain\"
        fi

        DAC=${DAC_BASE}
        busybox devmem \$((DAC+0x40)) 32 0x3   >/dev/null
        busybox devmem \$((DAC+0x48)) 32 0x20  >/dev/null
        busybox devmem \$((DAC+0x418)) 32 0x2  >/dev/null
        busybox devmem \$((DAC+0x458)) 32 0x2  >/dev/null

        # Release ADC core + MMCM from reset, r1_mode=0, enable channels with sign-extend
        ADC=${ADC_BASE}
        busybox devmem \$((ADC+0x40)) 32 0x3   >/dev/null  # RSTN: release
        busybox devmem \$((ADC+0x44)) 32 0x0   >/dev/null  # CNTRL: r1_mode=0 (2R2T DDR, MUST be 0!)
        busybox devmem \$((ADC+0x400)) 32 0x51 >/dev/null  # CH0: enable + sign-extend 12→16
        busybox devmem \$((ADC+0x440)) 32 0x51 >/dev/null  # CH1: enable + sign-extend 12→16

        TETRA=${BASE_ADDR}
        busybox devmem \$((TETRA+0x0C)) 32 ${sync_thresh} >/dev/null
        # RST_CNTRS (bit3) | TX_EN (bit1) | RX_EN (bit0) = 0x0B — no LOOPBACK bit!
        # Using 0x0F would accidentally set LOOPBACK (bit2) during counter reset,
        # causing sync_detect to briefly lock via digital loopback, then lose lock.
        busybox devmem \$((TETRA+0x00)) 32 0x0000000B >/dev/null
        sleep 1
        busybox devmem \$((TETRA+0x00)) 32 0x00000003 >/dev/null

        echo RX_LO=\$(iio_attr -c ad9361-phy altvoltage0 frequency 2>/dev/null | head -1)
        echo TX_LO=\$(iio_attr -c ad9361-phy altvoltage1 frequency 2>/dev/null | head -1)
        echo RX_PORT=\$RX_PORT
        echo RX_GAIN_MODE=\$(iio_attr -c ad9361-phy voltage0 gain_control_mode 2>/dev/null | head -1)
        echo TX_ATT=\$( [[ -n \"\$SYSFS\" ]] && cat \"\${SYSFS}/out_voltage0_hardwaregain\" || echo 'n/a')
        echo RX_AGC=\$( [[ -n \"\$SYSFS\" ]] && cat \"\${SYSFS}/in_voltage0_hardwaregain\" || echo 'n/a')
        DAC_STAT=\$(busybox devmem \$((DAC+0x68)) 32)
        ADC_STAT=\$(busybox devmem \$((ADC+0x5C)) 32)
        ADC_CLK_RATIO=\$(busybox devmem \$((ADC+0x58)) 32)
        ADC_CNTRL=\$(busybox devmem \$((ADC+0x44)) 32)
        printf 'DAC_STATUS=0x%08X ADC_STATUS=0x%08X (bit0=adc_locked bit2=overflow)\n' \$DAC_STAT \$ADC_STAT
        printf 'ADC_CNTRL=0x%08X ADC_CLK_RATIO=0x%08X\n' \$ADC_CNTRL \$ADC_CLK_RATIO
        echo SYNC_THRESH=\$(busybox devmem \$((TETRA+0x0C)) 32)
        echo CTRL=\$(busybox devmem \$((TETRA+0x00)) 32)
        echo STATUS=\$(busybox devmem \$((TETRA+0x04)) 32)
    "
    echo "External RF loopback path active. Check physical coupling, then run: $0 monitor"
}

# Command: full_init — complete board init sequence via FPGA manager (no JTAG needed)
# Performs the mandatory 2x bitstream + 2x AD9361 init procedure:
#   1. Load bitstream (FPGA manager) — establishes LVDS fabric, AD9361 not yet running
#   2. Initialize AD9361 (iio_attr via SSH) — DATA_CLK becomes stable
#   3. Reload bitstream — axi_ad9361 MMCM now sees stable DATA_CLK → clk_lvds locks
#   4. Re-run AD9361 init — CRITICAL: IIO driver must re-initialize ADC AXI registers
#      after the 2nd bitstream load (which resets all FPGA AXI registers to zero).
#      Without this step, ADC CLK_RATIO=1 and adc_valid_i0 never pulses → SYNC=0.
#   5. DAC core init (fabric data mode)
#   6. ADC core init (r1_mode=1, channel enable)
# Prerequisite: /lib/firmware/tetra_zynq_phy.bit.bin must exist on the board.
# Use after: session start, reboot, or when clk_lvds appears dead (digital loopback fails).
cmd_full_init() {
    local rx_freq="${2:-429950000}"
    local tx_freq="${3:-439950000}"

    echo "=== Full board init (2x bitstream load + 2x AD9361 + DAC/ADC init) ==="

    PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

    echo "--- Step 1: First bitstream load via FPGA manager ---"
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        echo 0 > /sys/class/fpga_manager/fpga0/flags
        echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware
        sleep 2
        echo 'First bitstream load done'
    " || { echo "ERROR: First bitstream load failed"; exit 1; }

    echo "--- Step 2: AD9361 init (establishes stable DATA_CLK) ---"
    bash "${PROJ_DIR}/scripts/ad9361_init.sh" \
        --host "$BOARD_IP" \
        --freq "$rx_freq" \
        --samplerate 4608000 \
        --agc || { echo "ERROR: ad9361_init.sh (step 2) failed"; exit 1; }

    echo "--- Step 3: Second bitstream load (MMCM sees stable DATA_CLK now) ---"
    sshpass -p "$BOARD_PASS" ssh "$BOARD_USER@$BOARD_IP" "
        echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware
        sleep 2
        echo 'Second bitstream load done'
    " || { echo "ERROR: Second bitstream load failed"; exit 1; }

    echo "--- Step 4: Re-run AD9361 init (restores ADC AXI registers reset by step 3) ---"
    # CRITICAL: The 2nd bitstream load resets all FPGA AXI registers to zero.
    # The IIO driver must re-run to restore ADC common registers (r1_mode, clock path).
    # Without this: ADC CLK_RATIO=1 → adc_valid_i0 never pulses → SYNC_LOCKED=0.
    bash "${PROJ_DIR}/scripts/ad9361_init.sh" \
        --host "$BOARD_IP" \
        --freq "$rx_freq" \
        --samplerate 4608000 \
        --agc || { echo "ERROR: ad9361_init.sh (step 4) failed"; exit 1; }

    echo "--- Step 5: DAC core init (fabric data mode) ---"
    cmd_dac_init

    echo "--- Step 6: ADC core init (r1_mode=0, channel enable) ---"
    cmd_adc_init

    echo "--- Step 7: VCXO GPIO init ---"
    ${SSH_CMD} "
        for pin in 1011 1012 1013; do
            echo \$pin > /sys/class/gpio/export 2>/dev/null
            echo out > /sys/class/gpio/gpio\${pin}/direction
        done
        echo 'VCXO GPIOs 1011-1013 exported + output'
    " || echo "WARN: VCXO GPIO init failed"

    echo "--- Step 8: XO correction ---"
    ${SSH_CMD} "echo 40000000 > /sys/bus/iio/devices/iio:device1/xo_correction" && \
        echo "xo_correction set to 40000000 Hz (nominal)" || \
        echo "WARN: xo_correction failed"

    echo "=== Full init complete. Board is ready for rf_loopback. ==="
    echo "Run: $0 rf_loopback ${rx_freq} ${tx_freq}"
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
    echo "Monitoring STATUS + debug registers (Ctrl+C to stop)..."
    echo "Waiting for SYNC_LOCKED=1..."
    echo ""

    local count=0
    while true; do
        local status=$(read_reg "$REG_STATUS")
        local status_dec=$(($status))
        local sync_locked=$(( (status_dec >> 0) & 0x1 ))

        # Debug counters
        local fe_cnt=$(read_reg "0x50")
        local demod_cnt=$(read_reg "0x54")
        local sync_raw=$(read_reg "0x58")
        local sync_raw_dec=$(($sync_raw))
        local corr_peak=$(( (sync_raw_dec >> 24) & 0xFF ))
        local sync_cnt=$(( sync_raw_dec & 0xFFFFFF ))

        printf "\r[%04d] LOCKED=%d fe=%d demod=%d sync=%d corr_peak=%d/19" \
            "$count" "$sync_locked" "$(($fe_cnt))" "$(($demod_cnt))" "$sync_cnt" "$corr_peak"

        if [ "$sync_locked" -eq 1 ]; then
            echo ""
            echo ""
            echo "✓ SYNC_LOCKED detected! corr_peak=${corr_peak}/19"
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
    dac_init)
        cmd_dac_init
        ;;
    adc_init)
        cmd_adc_init
        ;;
    full_init)
        cmd_full_init "$@"
        ;;
    tx_monitor)
        cmd_tx_monitor "$@"
        ;;
    rf_loopback)
        cmd_rf_loopback "$@"
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
        echo "  full_init [RX_Hz] [TX_Hz] — Complete 2x bitstream load + AD9361 + DAC/ADC init (no JTAG)"
        echo "  dac_init        — Init ADI DAC core (fabric data mode, required after bitstream load)"
        echo "  adc_init        — Init ADI ADC core (release from reset, required after bitstream load)"
        echo "  tx_monitor [Hz] — AD9361 internal TX_MONITOR1_2 path, default 440000000"
        echo "  rf_loopback [RX_Hz] [TX_Hz] [THR] [TX_ATT_dB] — external RF path, defaults 430/430 MHz (same LO!), THR=20, TX_ATT=-50"
        echo "  loopback        — Enable TX+RX+Loopback (CTRL=0x07)"
        echo "  disable         — Clear CTRL register"
        echo "  monitor         — Poll STATUS every 1s until SYNC_LOCKED=1"
        echo "  read <offset>   — Read single register"
        echo "  write <offset> <value> — Write single register"
        echo ""
        echo "Full init workflow (after reboot or when clk_lvds is dead):"
        echo "  $0 full_init    # 2x bitstream load + AD9361 + DAC/ADC init via FPGA manager"
        echo "  $0 rf_loopback  # Configure RF loopback (430/430 MHz, -50 dB TX_ATT)"
        echo "  $0 monitor      # Warten auf SYNC_LOCKED=1"
        echo ""
        echo "Digital loopback workflow:"
        echo "  $0 loopback     # TX→RX digital loopback aktivieren"
        echo "  $0 monitor      # Warten auf SYNC_LOCKED=1"
        echo ""
        echo "Internal TX monitor workflow:"
        echo "  $0 tx_monitor   # AD9361 interner TX→RX Monitorpfad"
        echo "  $0 monitor      # Warten auf SYNC_LOCKED=1"
        echo ""
        echo "External RF workflow (board already initialized):"
        echo "  $0 rf_loopback  # Externer RF-Pfad (A_BALANCED, 430/430 MHz, AGC)"
        echo "  $0 monitor      # Warten auf SYNC_LOCKED=1"
        echo ""
        echo "Example:"
        echo "  $0 status"
        echo "  $0 enable"
        echo "  $0 monitor"
        exit 1
        ;;
esac
