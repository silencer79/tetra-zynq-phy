#!/bin/bash
# =============================================================================
# tetra_autostart.sh — Boot-time auto-init für tetra-zynq-phy
# =============================================================================
# Konfig liest aus /root/tetra_cell.conf
# Ausführung typischerweise via systemd-Unit tetra-autostart.service
# Log: /tmp/tetra_autostart.log + journalctl -u tetra-autostart
#
# Sequence (verifiziert 2026-05-17):
#   1. Bitstream-Load #1 (initial FPGA-Config)
#   2. ad9361_drv kernel-Modul laden + spi0.0 binden
#   3. TX SAFE — Pegel auf TX_ATT_INIT_DB (z.B. -89 dB ≈ muted)
#   4. AD9361 Config #1 (samplerate, RX/TX-LO, gain-mode, bandwidth, ensm_mode, calib)
#   5. Bitstream-Load #2 — REQUIRED, sonst MMCM lockt nicht (siehe memory)
#   6. AD9361 Config #2 (FPGA-AXI-Register wurden durch #2 resetted)
#   7. DAC + ADC core init (devmem auf axi_ad9361_*-Cores)
#   8. VCXO GPIO export + xo_correction setzen
#   9. VCXO DAC trim (SPI-Bitbang über GPIO 1011/1012/1013)
#  10. REG_DB_POLICY setzen + devmem symlink
#  11. Daemons starten (sysinfo + ul_mon + attach_daemon)
#  12. TX → operationaler Pegel TX_ATT_OP_DB
#  13. WebUI httpd (busybox httpd auf Port 80, Doc-Root /www)
# =============================================================================

set -e

CONF=/root/tetra_cell.conf
if [ ! -r "$CONF" ]; then
    echo "FATAL: $CONF nicht gefunden/lesbar"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

# Required vars sanity-check
for v in RX_FREQ_HZ TX_FREQ_HZ SAMPLERATE_HZ RF_BW_HZ GAIN_MODE \
         TX_ATT_INIT_DB TX_ATT_OP_DB VCXO_DAC_VAL XO_CORRECTION_HZ \
         NUB_SYNC_THRESH DB_POLICY; do
    if [ -z "${!v}" ]; then
        echo "FATAL: $CONF: $v nicht gesetzt"
        exit 1
    fi
done

# Logging: systemd-Unit hat StandardOutput=journal — zusätzlich /tmp-Logfile
# via einfacher Redirect (NICHT tee/subshell, das verursacht im systemd-
# Kontext stdio-Buffer-Probleme die iio_attr blockieren).
LOG=/tmp/tetra_autostart.log
exec >> "$LOG" 2>&1

echo "=== tetra_autostart $(date) ==="
echo "Config: RX=$RX_FREQ_HZ TX=$TX_FREQ_HZ SR=$SAMPLERATE_HZ"
echo "       TX_INIT=$TX_ATT_INIT_DB dB TX_OP=$TX_ATT_OP_DB dB"
echo "       VCXO_DAC=$VCXO_DAC_VAL NUB_THRESH=$NUB_SYNC_THRESH"

SYSFS=/sys/bus/iio/devices/iio:device1
BIT=/lib/firmware/tetra_zynq_phy.bit.bin

if [ ! -f "$BIT" ]; then
    echo "FATAL: Bitstream $BIT nicht gefunden"
    exit 1
fi

# Kill any existing daemons (idempotent re-run)
pkill -f '[t]etra_attach_daemon' 2>/dev/null || true
pkill -f '[t]etra_ul_mon' 2>/dev/null || true
pkill -f '[t]etra_sysinfo' 2>/dev/null || true

# -----------------------------------------------------------------------------
# 1: Bitstream load #1
# -----------------------------------------------------------------------------
echo "--- 1/12 Bitstream load #1 ---"
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware
sleep 2
state=$(cat /sys/class/fpga_manager/fpga0/state)
[ "$state" = "operating" ] || { echo "FATAL: fpga state=$state"; exit 1; }

# -----------------------------------------------------------------------------
# 2: ad9361_drv kernel module + spi bind
# -----------------------------------------------------------------------------
echo "--- 2/12 ad9361_drv + spi0.0 bind (idempotent) ---"
if [ -d "$SYSFS" ]; then
    echo "ad9361 already bound (iio:device1 exists) — skipping bind sequence"
else
    if ! lsmod | grep -q "^ad9361_drv "; then
        insmod /root/kernel_modules32/ad9361_drv.ko
    fi
    udevadm settle --timeout=5 || true
    echo "" > /sys/bus/spi/devices/spi0.0/driver_override 2>/dev/null || true
    echo spi0.0 > /sys/bus/spi/drivers/spidev/unbind 2>/dev/null || true
    sleep 0.5
    echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind 2>/dev/null || true
    sleep 3
    udevadm settle --timeout=5 || true
    [ -d "$SYSFS" ] || { echo "FATAL: $SYSFS nicht da nach bind"; exit 1; }
fi

# -----------------------------------------------------------------------------
# 3: TX → SAFE (sehr leise während Init)
# -----------------------------------------------------------------------------
echo "--- 3/12 TX → SAFE ($TX_ATT_INIT_DB dB) ---"
echo "$TX_ATT_INIT_DB" > "$SYSFS/out_voltage0_hardwaregain"
echo "$TX_ATT_INIT_DB" > "$SYSFS/out_voltage1_hardwaregain"

# -----------------------------------------------------------------------------
# 4: AD9361 config #1
# -----------------------------------------------------------------------------
echo "--- 4/12 AD9361 config #1 ---"
# Direct sysfs writes statt iio_attr — iio_attr hängt im systemd-Kontext
# unendlich an out_altvoltage1_TX_LO_frequency (kernel uninterruptible state,
# auch SIGKILL kommt nicht durch). Direct sysfs writes funktionieren immer
# (~0.1-1.5s pro Op). Verifiziert 2026-05-17.
echo "$SAMPLERATE_HZ"    > "$SYSFS/in_voltage_sampling_frequency"
echo "$RX_FREQ_HZ"       > "$SYSFS/out_altvoltage0_RX_LO_frequency"
echo "$TX_FREQ_HZ"       > "$SYSFS/out_altvoltage1_TX_LO_frequency"
echo "$GAIN_MODE"        > "$SYSFS/in_voltage0_gain_control_mode"
echo "$RF_BW_HZ"         > "$SYSFS/in_voltage_rf_bandwidth"
echo "$RF_BW_HZ"         > "$SYSFS/out_voltage_rf_bandwidth"
echo fdd                 > "$SYSFS/ensm_mode"
echo auto                > "$SYSFS/calib_mode"

# -----------------------------------------------------------------------------
# 5: Bitstream load #2 (REQUIRED — MMCM braucht stabilen DATA_CLK)
# -----------------------------------------------------------------------------
echo "--- 5/12 Bitstream load #2 (MMCM stabilize) ---"
echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware
sleep 2
state=$(cat /sys/class/fpga_manager/fpga0/state)
[ "$state" = "operating" ] || { echo "FATAL: fpga state after 2nd load=$state"; exit 1; }

# -----------------------------------------------------------------------------
# 6: AD9361 config #2 (FPGA-AXI-Register wurden durch 2nd load resetted)
# -----------------------------------------------------------------------------
echo "--- 6/12 AD9361 config #2 (post-reset re-init) ---"
# Belt-and-suspenders TX safe
echo "$TX_ATT_INIT_DB" > "$SYSFS/out_voltage0_hardwaregain"
echo "$TX_ATT_INIT_DB" > "$SYSFS/out_voltage1_hardwaregain"
# Direct sysfs writes statt iio_attr — iio_attr hängt im systemd-Kontext
# unendlich an out_altvoltage1_TX_LO_frequency (kernel uninterruptible state,
# auch SIGKILL kommt nicht durch). Direct sysfs writes funktionieren immer
# (~0.1-1.5s pro Op). Verifiziert 2026-05-17.
echo "$SAMPLERATE_HZ"    > "$SYSFS/in_voltage_sampling_frequency"
echo "$RX_FREQ_HZ"       > "$SYSFS/out_altvoltage0_RX_LO_frequency"
echo "$TX_FREQ_HZ"       > "$SYSFS/out_altvoltage1_TX_LO_frequency"
echo "$GAIN_MODE"        > "$SYSFS/in_voltage0_gain_control_mode"
echo "$RF_BW_HZ"         > "$SYSFS/in_voltage_rf_bandwidth"
echo "$RF_BW_HZ"         > "$SYSFS/out_voltage_rf_bandwidth"
echo fdd                 > "$SYSFS/ensm_mode"
echo auto                > "$SYSFS/calib_mode"

# -----------------------------------------------------------------------------
# 7: DAC + ADC core init via devmem
# -----------------------------------------------------------------------------
echo "--- 7/12 DAC + ADC core init ---"
busybox devmem 0x79024040 32 0x00000003   # DAC RSTN
busybox devmem 0x79024048 32 0x00000020   # DAC CNTRL_2
busybox devmem 0x79024418 32 0x00000002   # DAC CH0 DATSEL (fabric)
busybox devmem 0x79024458 32 0x00000002   # DAC CH1 DATSEL (fabric)
busybox devmem 0x79020040 32 0x00000003   # ADC RSTN
busybox devmem 0x79020044 32 0x00000000   # ADC CNTRL (r1_mode=0)
busybox devmem 0x79020400 32 0x00000051   # ADC CH0 (enable+dfmt_se+dfmt_enable)
busybox devmem 0x79020440 32 0x00000051   # ADC CH1

# -----------------------------------------------------------------------------
# 8: VCXO GPIO export + xo_correction
# -----------------------------------------------------------------------------
echo "--- 8/12 VCXO GPIO + xo_correction ---"
for pin in 1011 1012 1013; do
    echo $pin > /sys/class/gpio/export 2>/dev/null || true
    echo out > /sys/class/gpio/gpio${pin}/direction
done
echo "$XO_CORRECTION_HZ" > "$SYSFS/xo_correction"

# -----------------------------------------------------------------------------
# 9: VCXO DAC trim — DAC5311 SPI bitbang
#    PD[1:0]=00, D[7:0]=val, X[5:0]=000000  →  frame = val << 6
# -----------------------------------------------------------------------------
echo "--- 9/12 VCXO DAC trim (val=$VCXO_DAC_VAL) ---"
CS=1011; CLK=1012; DIN=1013
FRAME=$(( VCXO_DAC_VAL << 6 ))
echo 0 > /sys/class/gpio/gpio${CS}/value
for bit in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0; do
    echo $(( (FRAME >> bit) & 1 )) > /sys/class/gpio/gpio${DIN}/value
    echo 1 > /sys/class/gpio/gpio${CLK}/value
    echo 0 > /sys/class/gpio/gpio${CLK}/value
done
echo 1 > /sys/class/gpio/gpio${CS}/value

# -----------------------------------------------------------------------------
# 10: REG_DB_POLICY + devmem symlink (für tetra_attach_daemon)
# -----------------------------------------------------------------------------
echo "--- 10/12 REG_DB_POLICY + devmem symlink ---"
ln -sf /usr/bin/busybox /usr/bin/devmem
busybox devmem 0x43C001AC 32 "$DB_POLICY"

# DB seed wenn /root/db.tsv fehlt
[ -f /root/db.tsv ] || [ ! -f /root/db.tsv.default ] || cp /root/db.tsv.default /root/db.tsv

# -----------------------------------------------------------------------------
# 11: Daemons starten (setsid damit sie nach systemd-Exit nicht sterben)
# -----------------------------------------------------------------------------
echo "--- 11/12 Start daemons ---"
# 2026-05-24 — alle Cell-Args aus tetra_cell.conf an sysinfo übergeben,
# sonst nutzt sysinfo die hardcoded defaults aus tetra_hal.c und der User
# muss nach jedem Boot WebUI bemühen um die richtigen Werte zu senden.
# Conf-Vars wurden oben via `source "$CONF"` geladen.
setsid /root/tetra_sysinfo \
    --freq    "${TX_FREQ_HZ}"     \
    --mcc     "${MCC:-901}"       \
    --mnc     "${MNC:-9998}"      \
    --la      "${LA:-1}"          \
    --cc      "${CC:-49}"         \
    --sc      "${SYSTEM_CODE:-2}" \
    --duplex  "${DUPLEX_SPACING:-1}" \
    --txpwr   "${MS_TXPWR:-6}"    \
    --rxmin   "${RXLEVEL_MIN:-0}" \
    --access  "${ACCESS_PARAM:-10}" \
    --dltimo  "${RADIO_DL_TIMEOUT:-5}" \
    --optfield "${OPT_FIELD:-1011456}" \
    --optsel  "${OPT_SEL:-2}"     \
    --prio    "${PRIORITY_CELL:-0}" \
    --migr    "${MIGRATION:-0}"   \
    --ncb     "${NCB:-3}"         \
    --csl     "${CSL:-0}"         \
    --daemon \
    < /dev/null > /tmp/tetra_sysinfo.log 2>&1 &
sleep 0.5
setsid /root/tetra_ul_mon < /dev/null > /tmp/tetra_ul_mon.log 2>&1 &
sleep 0.5
setsid /root/tetra_attach_daemon < /dev/null > /tmp/tetra_attach_daemon.log 2>&1 &
sleep 2
pgrep -al tetra

# -----------------------------------------------------------------------------
# 12: TX → operationaler Pegel
# -----------------------------------------------------------------------------
echo "--- 12/13 TX → operational ($TX_ATT_OP_DB dB) ---"
echo "$TX_ATT_OP_DB" > "$SYSFS/out_voltage0_hardwaregain"
echo "$TX_ATT_OP_DB" > "$SYSFS/out_voltage1_hardwaregain"

# -----------------------------------------------------------------------------
# 13: WebUI httpd (busybox httpd auf Port 80, Doc-Root /www)
#     Vor 2026-05-17 lief der Start implizit am Ende von scripts/deploy.sh;
#     beim Autostart-Refactor wurde der httpd vergessen. Hier nachgeholt.
# -----------------------------------------------------------------------------
echo "--- 13/13 WebUI httpd auf Port 80 ---"
# pkill-Pattern bewusst eng: "httpd -p 80" matched NICHT diesen Skript-Pfad
# (sonst würde pkill -f sich selbst umbringen).
pkill -f "httpd -p 80" 2>/dev/null || true
setsid busybox httpd -p 80 -h /www < /dev/null > /dev/null 2>&1 &
sleep 0.3
if pgrep -f "httpd -p 80" > /dev/null; then
    echo "httpd running: $(pgrep -f "httpd -p 80")"
else
    echo "WARNING: httpd start failed"
fi

echo ""
echo "=== AUTOSTART COMPLETE ==="
echo "STATUS:      $(busybox devmem 0x43C00004 32)  [bit0=SYNC_LOCKED bit1=PLL_LOCKED bit2=FIFO_E]"
echo "ADC STATUS:  $(busybox devmem 0x7902005C 32)"
echo "DB_POLICY:   $(busybox devmem 0x43C001AC 32)"
echo "NUB_THRESH:  $(busybox devmem 0x43C00268 32)"
echo "TX1 gain:    $(cat $SYSFS/out_voltage0_hardwaregain)"
echo ""
echo "Daemons:"
pgrep -al tetra
