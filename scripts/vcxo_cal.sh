#!/usr/bin/env bash
# =============================================================================
# vcxo_cal.sh — DAC5311 VCXO-Tuning via PS GPIO EMIO Bitbang
# Project: tetra-zynq-phy
#
# Schreibt einen 8-Bit-Wert in den DAC5311, der die Steuerspannung des
# 40-MHz-VCXO auf dem LibreSDR Rev.5 setzt.
#
# Hardware:
#   DAC5311 (TI, 8-bit, SPI 3-wire):
#     CS  → FPGA H18 → EMIO[51] → Linux GPIO 1011
#     CLK → FPGA F19 → EMIO[52] → Linux GPIO 1012
#     DIN → FPGA F20 → EMIO[53] → Linux GPIO 1013
#
# DAC5311 16-bit Frame:
#   [15:14] PD1:PD0  = 00 (normal operation)
#   [13:6]  D7:D0    = 8-bit DAC-Wert (MSB zuerst)
#   [5:0]   X        = Don't care
#
# VCXO-Charakteristik (typisch):
#   DAC=0x00 (0V)   → VCXO minimale Frequenz
#   DAC=0x80 (Mid)  → VCXO Nominalfrequenz (~40.000 MHz)
#   DAC=0xFF (3.3V) → VCXO maximale Frequenz
#
# Kalibrierung:
#   - Referenz: GPS-Lock oder Frequenzzähler an 40-MHz-Ausgang
#   - Ziel: AD9361 xo_correction = tatsächliche VCXO-Frequenz (Hz)
#   - Feinjustierung per iio_attr -d ad9361-phy xo_correction <Hz>
#
# Usage:
#   ./scripts/vcxo_cal.sh [--host IP] [--dac 0..255] [--read] [--init]
#
# Optionen:
#   --host IP    SSH-Adresse des LibreSDR  [192.168.2.85]
#   --dac  N     DAC-Wert setzen (0..255)
#   --read       Aktuellen GPIO-Zustand lesen
#   --init       GPIOs exportieren + auf Output konfigurieren
#   --deinit     GPIOs wieder unexporten
#   --xo HZ      AD9361 xo_correction setzen (Hz, z.B. 40000000)
#
# Beispiel (Mittelstellung, dann feinjustieren):
#   ./scripts/vcxo_cal.sh --init
#   ./scripts/vcxo_cal.sh --dac 128
#   ./scripts/vcxo_cal.sh --xo 40000000
# =============================================================================

set -euo pipefail

SSH_HOST="192.168.2.85"
SSH_USER="root"
SSH_PASS="openwifi"
DAC_VAL=""
DO_READ=0
DO_INIT=0
DO_DEINIT=0
XO_HZ=""

# EMIO GPIO-Nummern (Basis 906, EMIO-Offset 54)
GPIO_CS=1011   # EMIO[51] — dac_sync (CS, active low)
GPIO_CLK=1012  # EMIO[52] — dac_sclk
GPIO_DIN=1013  # EMIO[53] — dac_din

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)   SSH_HOST="$2"; shift 2 ;;
        --dac)    DAC_VAL="$2";  shift 2 ;;
        --xo)     XO_HZ="$2";   shift 2 ;;
        --read)   DO_READ=1;     shift 1 ;;
        --init)   DO_INIT=1;     shift 1 ;;
        --deinit) DO_DEINIT=1;   shift 1 ;;
        --help|-h)
            sed -n '/^# Usage/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unbekanntes Argument: $1"; exit 1 ;;
    esac
done

SSH_CMD="sshpass -p ${SSH_PASS} ssh -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST}"

# -----------------------------------------------------------------------------
# GPIO-Hilfsfunktionen (auf dem Board ausführen)
# -----------------------------------------------------------------------------
gpio_export() {
    ${SSH_CMD} "
        for gpio in ${GPIO_CS} ${GPIO_CLK} ${GPIO_DIN}; do
            if [ ! -d /sys/class/gpio/gpio\${gpio} ]; then
                echo \$gpio > /sys/class/gpio/export
            fi
            echo out > /sys/class/gpio/gpio\${gpio}/direction
        done
        # CS idle high
        echo 1 > /sys/class/gpio/gpio${GPIO_CS}/value
        echo 0 > /sys/class/gpio/gpio${GPIO_CLK}/value
        echo 0 > /sys/class/gpio/gpio${GPIO_DIN}/value
        echo 'GPIO ${GPIO_CS}(CS) ${GPIO_CLK}(CLK) ${GPIO_DIN}(DIN) exportiert'
    "
}

gpio_unexport() {
    ${SSH_CMD} "
        for gpio in ${GPIO_CS} ${GPIO_CLK} ${GPIO_DIN}; do
            if [ -d /sys/class/gpio/gpio\${gpio} ]; then
                echo \$gpio > /sys/class/gpio/unexport
            fi
        done
        echo 'GPIO unexportiert'
    "
}

gpio_read() {
    ${SSH_CMD} "
        for gpio in ${GPIO_CS} ${GPIO_CLK} ${GPIO_DIN}; do
            if [ -d /sys/class/gpio/gpio\${gpio} ]; then
                val=\$(cat /sys/class/gpio/gpio\${gpio}/value)
                dir=\$(cat /sys/class/gpio/gpio\${gpio}/direction)
                echo \"  GPIO\${gpio}: \${dir} = \${val}\"
            else
                echo \"  GPIO\${gpio}: nicht exportiert\"
            fi
        done
    "
}

# DAC5311 SPI Bitbang — 16-Bit-Frame senden
# Frame: PD[1:0]=00, D[7:0]=DAC_VAL, X[5:0]=000000
dac_write() {
    local val="$1"
    # Frame berechnen: PD=00, Data=val (8bit), dont-care=0 → val<<6
    local frame=$(( val << 6 ))

    ${SSH_CMD} "
        CS=${GPIO_CS}
        CLK=${GPIO_CLK}
        DIN=${GPIO_DIN}
        FRAME=${frame}

        gpio_set() { echo \$2 > /sys/class/gpio/gpio\$1/value; }

        # CS low — Transfer beginnt
        gpio_set \$CS 0

        # 16 Bits MSB-zuerst schieben
        for bit in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0; do
            # Datenbit setzen
            gpio_set \$DIN \$(( (FRAME >> bit) & 1 ))
            # CLK high (Data wird auf steigender Flanke gelatcht)
            gpio_set \$CLK 1
            # CLK low
            gpio_set \$CLK 0
        done

        # CS high — DAC übernimmt den Wert
        gpio_set \$CS 1

        printf 'DAC5311: Wert=%d (0x%02X) geschrieben, Frame=0x%04X\n' ${val} ${val} ${frame}
    "
}

# -----------------------------------------------------------------------------
# Hauptprogramm
# -----------------------------------------------------------------------------
if [[ ${DO_INIT} -eq 1 ]]; then
    echo "Exportiere GPIO-Pins für DAC5311 ..."
    gpio_export
fi

if [[ ${DO_DEINIT} -eq 1 ]]; then
    echo "Unexportiere GPIO-Pins ..."
    gpio_unexport
fi

if [[ ${DO_READ} -eq 1 ]]; then
    echo "GPIO-Status:"
    gpio_read
fi

if [[ -n "${DAC_VAL}" ]]; then
    if [[ ${DAC_VAL} -lt 0 || ${DAC_VAL} -gt 255 ]]; then
        echo "Fehler: DAC-Wert muss 0..255 sein"
        exit 1
    fi
    echo "Setze DAC5311 auf ${DAC_VAL} (0x$(printf '%02X' ${DAC_VAL})) ..."
    dac_write "${DAC_VAL}"
fi

if [[ -n "${XO_HZ}" ]]; then
    echo "Setze AD9361 xo_correction auf ${XO_HZ} Hz ..."
    ${SSH_CMD} "iio_attr -d ad9361-phy xo_correction ${XO_HZ} 2>&1" && \
        echo "  xo_correction = ${XO_HZ}" || \
        echo "  WARN: xo_correction fehlgeschlagen (AD9361 nicht initialisiert?)"
fi

if [[ ${DO_INIT} -eq 0 && ${DO_DEINIT} -eq 0 && ${DO_READ} -eq 0 && -z "${DAC_VAL}" && -z "${XO_HZ}" ]]; then
    echo "Usage: $0 [--init] [--dac 0..255] [--xo HZ] [--read] [--deinit]"
    echo "       $0 --host 192.168.2.85 --init --dac 128"
fi
