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
#   --host       192.168.2.85
#   --freq       429000000   (429 MHz, TETRA 70cm Amateur)
#   --samplerate 4608000     (4.608 MSPS → CIC R=64 → 72 kHz = 4× Symbolrate)
#   --gain       40          (40 dB, manual mode; --agc für slow_attack)
#
# Board-Spezifika (LibreSDR + OpenWiFi-Kernel 5.10.0-98248):
#   - AD9361 IIO-Treiber ist NICHT im Kernel — muss per insmod geladen werden:
#       insmod /root/kernel_modules32/ad9361_drv.ko
#   - iio_attr-Syntax: -c <device> <channel> <attr> [value]  (NICHT -d und -c kombinieren)
#   - driver_override auf spi0.0 muss geleert sein bevor bind funktioniert:
#       echo '' > /sys/bus/spi/devices/spi0.0/driver_override
#   - AD9361 IIO-Device: ad9361-phy (iio:device1)
#   - Kanäle: voltage0 (RX), voltage1 (TX), altvoltage0 (RX_LO), altvoltage1 (TX_LO)
#
# Voraussetzungen auf dem Zielsystem:
#   - OpenWiFi Linux (5.10.0-98248-g1bbe32fa5182-dirty)
#   - /root/kernel_modules32/ad9361_drv.ko vorhanden
#   - iio_attr (libiio 0.24) installiert
# =============================================================================

set -euo pipefail

# --- Defaults ---
SSH_HOST="192.168.2.85"
SSH_USER="root"
SSH_PASS="openwifi"
RX_FREQ_HZ=429950000
TX_FREQ_HZ=""              # leer → RX+10 MHz Default; sonst expliziter Wert
SAMPLERATE_HZ=4608000
RX_GAIN_DB=40
GAIN_MODE="fast_attack"    # manual | slow_attack | fast_attack — TETRA Burst-Mode profitiert von fast (Onset-Anpassung µs statt ms)

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       SSH_HOST="$2";       shift 2 ;;
        --freq)       RX_FREQ_HZ="$2";     shift 2 ;;
        --tx-freq)    TX_FREQ_HZ="$2";     shift 2 ;;
        --samplerate) SAMPLERATE_HZ="$2";  shift 2 ;;
        --gain)       RX_GAIN_DB="$2";     shift 2 ;;
        --agc)        GAIN_MODE="fast_attack"; shift 1 ;;
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

# --- AD9361 Kernel-Treiber laden (OpenWiFi-Kernel hat keinen eingebauten ad9361) ---
echo ""
echo "--- AD9361 Kernel-Treiber laden ---"
# Auf dem LibreSDR mit OpenWiFi-Kernel (5.10.0-98248) ist ad9361 als Modul
# kompiliert aber NICHT installiert. /root/kernel_modules32/ad9361_drv.ko
# ist die korrekte 32-Bit Version.
AD9361_MODULE_OK=0
if ${SSH_CMD} "lsmod | grep -q ad9361_drv" 2>/dev/null; then
    echo "ad9361_drv bereits geladen"
    AD9361_MODULE_OK=1
elif ${SSH_CMD} "[ -f /root/kernel_modules32/ad9361_drv.ko ]" 2>/dev/null; then
    ${SSH_CMD} "insmod /root/kernel_modules32/ad9361_drv.ko" 2>/dev/null && \
        echo "ad9361_drv geladen" && AD9361_MODULE_OK=1 || \
        echo "WARN: insmod fehlgeschlagen"
else
    echo "WARN: /root/kernel_modules32/ad9361_drv.ko nicht gefunden"
fi

# --- spi0.0 an ad9361 binden ---
echo ""
echo "--- AD9361 SPI-Binding ---"
# Prüfen ob IIO-Device bereits vorhanden
AD9361_IIO_READY=$( ${SSH_CMD} \
    "cat /sys/bus/iio/devices/*/name 2>/dev/null | grep -c ad9361-phy" || echo "0" )

if [[ "${AD9361_IIO_READY}" == "0" && "${AD9361_MODULE_OK}" == "1" ]]; then
    # driver_override leeren (verhindert sonst das Binden)
    ${SSH_CMD} "echo '' > /sys/bus/spi/devices/spi0.0/driver_override 2>/dev/null" || true
    # Ggf. vorhandenen Driver lösen
    ${SSH_CMD} "echo spi0.0 > /sys/bus/spi/drivers/spidev/unbind 2>/dev/null" || true
    ${SSH_CMD} "echo spi0.0 > /sys/bus/spi/drivers/ad9361/unbind 2>/dev/null" || true
    sleep 0.5
    # Ad9361 binden
    ${SSH_CMD} "echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind 2>/dev/null"
    sleep 3
fi

# IIO-Device prüfen
IIO_DEV=$( ${SSH_CMD} \
    "grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name 2>/dev/null | \
     sed 's|/sys/bus/iio/devices/||;s|/name||' | head -1" || true )

if [[ -z "${IIO_DEV}" ]]; then
    echo "ERROR: AD9361 IIO-Device nicht gefunden!"
    echo "dmesg:"
    ${SSH_CMD} "dmesg | grep -i ad9361 | tail -5" || true
    exit 1
fi
echo "AD9361 IIO-Device: ${IIO_DEV}"

# Hilfsfunktionen — libiio 0.24 Syntax: -c <device> <channel> <attr> [value]
iio_set_ch() {
    local channel="$1"
    local attr="$2"
    local value="$3"
    local result
    result=$( ${SSH_CMD} "iio_attr -c ad9361-phy ${channel} ${attr} ${value} 2>&1" )
    echo "  ${channel}/${attr} = ${result}"
}

iio_get_ch() {
    local channel="$1"
    local attr="$2"
    ${SSH_CMD} "iio_attr -c ad9361-phy ${channel} ${attr} 2>/dev/null | head -1"
}

iio_set_dev() {
    local attr="$1"
    local value="$2"
    local result
    result=$( ${SSH_CMD} "iio_attr -d ad9361-phy ${attr} ${value} 2>&1" )
    echo "  dev/${attr} = ${result}"
}

echo ""
echo "--- AD9361 TETRA-Konfiguration ---"

if [[ -z "$TX_FREQ_HZ" ]]; then
    TX_FREQ_HZ=$(( RX_FREQ_HZ + 10000000 ))
fi
BW_HZ=200000  # 200 kHz — minimum AD9361, optimal for 25 kHz TETRA

# 1. Samplerate RX (setzt automatisch BBPLL + Decimation)
iio_set_ch "voltage0" "sampling_frequency" "${SAMPLERATE_HZ}"

# 2. LO-Frequenzen
iio_set_ch "altvoltage0" "frequency" "${RX_FREQ_HZ}"
iio_set_ch "altvoltage1" "frequency" "${TX_FREQ_HZ}"

# 3. RX Gain (rf_port_select is A_BALANCED by default; setting it fails with EINVAL)
iio_set_ch "voltage0" "gain_control_mode" "${GAIN_MODE}"
if [[ "${GAIN_MODE}" == "manual" ]]; then
    iio_set_ch "voltage0" "hardwaregain" "${RX_GAIN_DB}"
fi

# 4. Bandbreite
iio_set_ch "voltage0" "rf_bandwidth" "${BW_HZ}"

# 5. FDD-Modus (Duplex, für gleichzeitigen RX+TX)
iio_set_dev "ensm_mode" "fdd"

# 6. TX Dämpfung explizit setzen (nur Output-Channel via sysfs)
#
#    WICHTIG: AD9361 IIO-Kanal-Mapping (verifiziert 2026-04-13):
#      out_voltage0_hardwaregain = TX1 Dämpfung  → AD9361 SPI Register 0x073/0x074
#      out_voltage1_hardwaregain = TX2 Dämpfung  → AD9361 SPI Register 0x075/0x076
#
#    Der LibreSDR nutzt TX1 als RF-Ausgang. Nur out_voltage0 hat Wirkung auf den
#    tatsächlichen TX-Pfad. Writes auf out_voltage1 gehen ins Leere (TX2 nicht verbunden).
#
#    Format: direkt dB (nicht millidB!) — z.B. echo -50 für -50 dB (= 50 dB Dämpfung)
#    0 = keine Dämpfung (maximale TX-Leistung, ~AGC 0-1 dB bei 10cm Abstand)
IIO_PATH="${IIO_DEV_PATH:-/sys/bus/iio/devices/${IIO_DEV}}"
TX_GAIN_RESULT=$( ${SSH_CMD} "
    SYSFS=\$(grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    if [[ -z \"\$SYSFS\" ]]; then
        echo 'sysfs nicht gefunden'
    else
        echo 0 > \"\${SYSFS}/out_voltage0_hardwaregain\" 2>&1 && \
        cat \"\${SYSFS}/out_voltage0_hardwaregain\"
    fi
" 2>&1 )
echo "  voltage0/hardwaregain(TX1) = ${TX_GAIN_RESULT}"

# 7. TX Quadratur-Kalibrierung triggern
#    Der OpenWiFi-Kernel exportiert keine TX-Tracking-Attribute (kein
#    out_voltage_quadrature_tracking_en). Die TX I/Q-Balance muss daher
#    explizit über calib_mode getriggert werden. Ohne diesen Schritt hat
#    der TX-Pfad unkalibrierte I/Q-Imbalance und LO-Leakage → MER-Boden.
echo ""
echo "--- TX Quadratur-Kalibrierung ---"
iio_set_dev "calib_mode" "tx_quad"

echo ""
echo "--- Verifizierung ---"
echo -n "  RX LO: " && iio_get_ch "altvoltage0" "frequency"
echo -n "  TX LO: " && iio_get_ch "altvoltage1" "frequency"
echo -n "  SR:    " && iio_get_ch "voltage0" "sampling_frequency"
echo -n "  Gain:  " && iio_get_ch "voltage0" "gain_control_mode"
echo -n "  TX Att: " && ${SSH_CMD} "
    SYSFS=\$(grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    [[ -n \"\$SYSFS\" ]] && cat \"\${SYSFS}/out_voltage0_hardwaregain\" || echo 'n/a'
" 2>/dev/null
echo -n "  Rates: " && ${SSH_CMD} "iio_attr -d ad9361-phy rx_path_rates 2>/dev/null"

echo ""
echo "=== AD9361 Initialisierung abgeschlossen ==="
echo "AD9361 liefert jetzt IQ-Daten an FPGA-Fabric."
echo "Warte 1s auf PLL-Lock ..."
sleep 1
echo "Bereit für ILA-Capture oder TETRA-Empfang."
