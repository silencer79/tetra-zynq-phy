#!/usr/bin/env bash
# =============================================================================
# ad9361_init.sh — AD9361 Initialisierung via SSH + libiio
# Project: tetra-zynq-phy
#
# Konfiguriert den AD9361 auf dem LibreSDR via SSH und iio_attr.
# Setzt RX-Frequenz, Samplerate, Gain-Mode und RX-Port.
#
# Usage:
#   ./scripts/ad9361_init.sh [--host IP] [--freq HZ] [--samplerate HZ] [--gain DB]
#
# Defaults:
#   --host       192.168.2.180
#   --freq       430000000   (430 MHz, TETRA 70cm Amateur)
#   --samplerate 4096000     (4.096 MSPS → CIC decimiert auf ~18 kHz Symboltakt)
#   --gain       40          (40 dB, manual mode; 0 für slow_attack AGC)
#
# Voraussetzungen auf dem Zielsystem:
#   - OpenWifi Linux mit ADI AD9361 IIO-Treiber
#   - iio_attr / libiio installiert
# =============================================================================

set -euo pipefail

# --- Defaults ---
SSH_HOST="192.168.2.180"
SSH_USER="root"
SSH_PASS="openwifi"
RX_FREQ_HZ=430000000
SAMPLERATE_HZ=4096000
RX_GAIN_DB=40
GAIN_MODE="manual"    # manual | slow_attack | fast_attack

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       SSH_HOST="$2";       shift 2 ;;
        --freq)       RX_FREQ_HZ="$2";     shift 2 ;;
        --samplerate) SAMPLERATE_HZ="$2";  shift 2 ;;
        --gain)       RX_GAIN_DB="$2";     shift 2 ;;
        --agc)        GAIN_MODE="slow_attack"; shift 1 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# SSH ohne Host-Key-Check (Lab-Umgebung), Passwort via sshpass
SSH_CMD="sshpass -p ${SSH_PASS} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${SSH_HOST}"

echo "=== AD9361 Init: ${SSH_HOST} ==="
echo "    RX Freq:    ${RX_FREQ_HZ} Hz ($(echo "scale=3; ${RX_FREQ_HZ}/1000000" | bc) MHz)"
echo "    Samplerate: ${SAMPLERATE_HZ} sps ($(echo "scale=3; ${SAMPLERATE_HZ}/1000000" | bc) MSPS)"
echo "    Gain Mode:  ${GAIN_MODE}"
if [[ "${GAIN_MODE}" == "manual" ]]; then
    echo "    RX Gain:    ${RX_GAIN_DB} dB"
fi
echo ""

# --- Erreichbarkeit prüfen ---
if ! command -v sshpass &>/dev/null; then
    echo "ERROR: sshpass nicht gefunden. Installieren: sudo apt install sshpass"
    exit 1
fi

echo "--- Verbindungstest ---"
if ! ${SSH_CMD} "echo OK" &>/dev/null; then
    echo "ERROR: SSH-Verbindung zu ${SSH_USER}@${SSH_HOST} fehlgeschlagen."
    echo "Prüfe: Board eingeschaltet? Netzwerk? Passwort korrekt?"
    exit 1
fi
echo "SSH OK"

# --- AD9361 IIO-Device finden ---
echo ""
echo "--- AD9361 IIO-Device suchen ---"
IIO_DEV=$( ${SSH_CMD} "iio_attr -s 2>/dev/null | grep -i 'ad9361' | head -1 | awk '{print \$1}'" || true )

if [[ -z "${IIO_DEV}" ]]; then
    echo "WARN: iio_attr -s liefert kein ad9361-Device."
    echo "     Versuche direkt über /sys/bus/iio ..."
    IIO_DEV=$( ${SSH_CMD} "grep -r 'ad9361-phy' /sys/bus/iio/devices/*/name 2>/dev/null | head -1 | sed 's|/sys/bus/iio/devices/||;s|/name:.*||'" || true )
fi

if [[ -z "${IIO_DEV}" ]]; then
    echo "ERROR: AD9361 IIO-Device nicht gefunden!"
    echo "Ausgabe von iio_info:"
    ${SSH_CMD} "iio_info 2>/dev/null | head -40" || true
    exit 1
fi
echo "AD9361 IIO-Device: ${IIO_DEV}"

# Hilfsfunktion: Attribut setzen mit Fehlerbehandlung
iio_set() {
    local attr="$1"
    local value="$2"
    echo "  SET ${attr} = ${value}"
    if ! ${SSH_CMD} "iio_attr -d ad9361-phy ${attr} ${value}" &>/dev/null; then
        echo "  WARN: iio_attr fehlgeschlagen für ${attr}, versuche /sys ..."
        ${SSH_CMD} "echo ${value} > /sys/bus/iio/devices/${IIO_DEV}/${attr}" 2>/dev/null || \
            echo "  WARN: Auch /sys-Pfad fehlgeschlagen, übersprungen."
    fi
}

iio_get() {
    local attr="$1"
    ${SSH_CMD} "iio_attr -d ad9361-phy ${attr} 2>/dev/null || cat /sys/bus/iio/devices/${IIO_DEV}/${attr} 2>/dev/null || echo '?'"
}

echo ""
echo "--- AD9361 konfigurieren ---"

# 1. Samplerate (muss vor LO-Frequenz gesetzt werden)
iio_set "in_voltage_sampling_frequency" "${SAMPLERATE_HZ}"
iio_set "out_voltage_sampling_frequency" "${SAMPLERATE_HZ}"

# 2. RX LO-Frequenz
iio_set "out_altvoltage0_RX_LO_frequency" "${RX_FREQ_HZ}"

# 3. TX LO-Frequenz (10 MHz über RX = TETRA-Duplex-Abstand)
TX_FREQ_HZ=$(( RX_FREQ_HZ + 10000000 ))
iio_set "out_altvoltage1_TX_LO_frequency" "${TX_FREQ_HZ}"

# 4. RX RF-Port: A_BALANCED (Standard für LibreSDR Rx-Eingang)
iio_set "in_voltage0_rf_port_select" "A_BALANCED"
iio_set "in_voltage1_rf_port_select" "A_BALANCED"

# 5. Gain-Mode
iio_set "in_voltage0_gain_control_mode" "${GAIN_MODE}"
if [[ "${GAIN_MODE}" == "manual" ]]; then
    iio_set "in_voltage0_hardwaregain" "${RX_GAIN_DB}"
fi

# 6. Bandwidth: 1.25× Samplerate (ADI Empfehlung)
BW_HZ=$(( SAMPLERATE_HZ * 5 / 4 ))
iio_set "in_voltage_rf_bandwidth" "${BW_HZ}"
iio_set "out_voltage_rf_bandwidth" "${BW_HZ}"

# 7. LVDS sicherstellen (OpenWifi konfiguriert das i.d.R. schon korrekt)
# iio_set "in_voltage_lo_powerdown" "0"   # RX-PLL ein

echo ""
echo "--- Verifizierung ---"
echo "  RX LO Freq:    $(iio_get out_altvoltage0_RX_LO_frequency) Hz"
echo "  Samplerate:    $(iio_get in_voltage_sampling_frequency) sps"
echo "  Gain Mode:     $(iio_get in_voltage0_gain_control_mode)"
if [[ "${GAIN_MODE}" == "manual" ]]; then
    echo "  RX Gain:       $(iio_get in_voltage0_hardwaregain) dB"
fi

echo ""
echo "=== AD9361 Initialisierung abgeschlossen ==="
echo "AD9361 sollte jetzt IQ-Daten an FPGA-Fabric liefern."
echo "Warte ~1s auf PLL-Lock ..."
sleep 1
