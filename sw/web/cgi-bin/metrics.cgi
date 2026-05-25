#!/bin/sh
# metrics.cgi — live status snapshot as JSON for WebUI auto-refresh.
# Reads:
#   - AD9361 RSSI (in_voltage[01]_rssi sysfs)
#   - FPGA NUB-RX counter (REG_VOICE_NUB_RX_CNT @ 0x43C00260 via devmem)
#   - voice_pipe last status line (BFI soft/hard, diff_avg, max) from
#     /tmp/tetra_attach_daemon.log
#   - Process state of tetra_sysinfo + tetra_attach_daemon

echo "Content-Type: application/json"
echo ""

SYSFS=/sys/bus/iio/devices/iio:device1
LOG=/tmp/tetra_attach_daemon.log

# Process status
si_run=0; pidof tetra_sysinfo > /dev/null 2>&1 && si_run=1
ad_run=0; pidof tetra_attach_daemon > /dev/null 2>&1 && ad_run=1

# Uptime
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
: ${up:=0}

# AD9361 RSSI — strip " dB" suffix, fallback null on read failure
rssi0=$(cat $SYSFS/in_voltage0_rssi 2>/dev/null | awk '{print $1+0}')
rssi1=$(cat $SYSFS/in_voltage1_rssi 2>/dev/null | awk '{print $1+0}')
: ${rssi0:=null}
: ${rssi1:=null}

# NUB-RX counter (16-bit, freilaufend)
nub_raw=$(busybox devmem 0x43C00260 32 2>/dev/null)
: ${nub_raw:=0x0}
nub_cnt=$(printf "%d" "$nub_raw" 2>/dev/null)
: ${nub_cnt:=0}

# voice_pipe parse — last line, ggf. älter wenn keine aktive Voice-Pipe
vp_line=$(grep "voice_pipe.*bursts" "$LOG" 2>/dev/null | tail -1)
vp_bursts=$(echo "$vp_line" | grep -oE "bursts=[0-9]+" | cut -d= -f2)
vp_soft_bfi=$(echo "$vp_line" | grep -oE "soft\{bfi=[0-9]+" | grep -oE "[0-9]+$")
vp_soft_pct=$(echo "$vp_line" | grep -oE "soft\{[^}]+\}" | grep -oE "[0-9]+%" | tr -d %)
vp_hard_bfi=$(echo "$vp_line" | grep -oE "hard\{bfi=[0-9]+" | grep -oE "[0-9]+$")
vp_hard_pct=$(echo "$vp_line" | grep -oE "hard\{[^}]+\}" | grep -oE "[0-9]+%" | tr -d %)
vp_diff_avg=$(echo "$vp_line" | grep -oE "diff_avg=[0-9]+" | cut -d= -f2)
vp_max=$(echo "$vp_line" | grep -oE "max=[0-9]+" | cut -d= -f2)
vp_ts_ms=$(echo "$vp_line" | grep -oE "t=[0-9]+ms" | grep -oE "[0-9]+")
# Soft-magnitude average (z.B. "soft_mag=3.42") → centi-units for JSON
vp_mag_str=$(echo "$vp_line" | grep -oE "soft_mag=[0-9]+\.[0-9]+" | cut -d= -f2)
if [ -n "$vp_mag_str" ]; then
    vp_mag_x100=$(echo "$vp_mag_str" | awk '{printf "%d", $1*100}')
else
    vp_mag_x100=0
fi

: ${vp_bursts:=0}
: ${vp_soft_bfi:=0}
: ${vp_soft_pct:=0}
: ${vp_hard_bfi:=0}
: ${vp_hard_pct:=0}
: ${vp_diff_avg:=0}
: ${vp_max:=0}
: ${vp_ts_ms:=0}
: ${vp_mag_x100:=0}

# MER/SNR-Proxy aus Mean-|soft| ∈ [0..8] (4-bit signed = [-8,+7]):
#   linear estimate = mag / (8 - mag)   (signal/noise ratio rough)
#   dB              = 20 * log10(linear)
# Clamp bei mag ≥ 7.95 auf 60 dB (= „voll am Clipping, sehr stark").
# Berechnung in awk wegen float.
vp_mer_db=$(awk -v m="$vp_mag_x100" 'BEGIN {
    mv = m / 100.0;
    if (mv <= 0) { print "-99.0"; exit }
    if (mv >= 7.95) { print "60.0"; exit }
    lin = mv / (8.0 - mv);
    if (lin <= 0) { print "-99.0"; exit }
    printf "%.1f", 20.0 * log(lin) / log(10);
}')

cat <<EOF
{
  "tetra_sysinfo_running": $si_run,
  "attach_daemon_running": $ad_run,
  "uptime_s": $up,
  "rssi_rx0_db": $rssi0,
  "rssi_rx1_db": $rssi1,
  "nub_rx_cnt": $nub_cnt,
  "voice_pipe": {
    "bursts": $vp_bursts,
    "soft_bfi": $vp_soft_bfi,
    "soft_pct": $vp_soft_pct,
    "hard_bfi": $vp_hard_bfi,
    "hard_pct": $vp_hard_pct,
    "diff_avg": $vp_diff_avg,
    "max_diff": $vp_max,
    "soft_mag_x100": $vp_mag_x100,
    "mer_db": $vp_mer_db,
    "ts_ms": $vp_ts_ms
  }
}
EOF
