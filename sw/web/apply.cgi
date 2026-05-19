#!/bin/sh
# apply.cgi — set BS-Cell-Parameters + persist nach /root/tetra_cell.conf
#
# Reads existing /root/tetra_cell.conf to preserve hardware defaults
# (samplerate, BW, VCXO, etc.), overlays user-submitted values from
# QUERY_STRING, writes the file back, and restarts tetra_sysinfo with
# the cell parameters as CLI args.
#
# Duplex spacing: configurable 8-row table (DUPLEX_OFFSET_HZ_0..7) — both
# the table and the selected setting come from the user form, allowing
# per-MS calibration of the actual mapping.

echo "Content-Type: text/plain"
echo ""

CONF=/root/tetra_cell.conf

# ----------------------------------------------------------------------
# 1. Parse QUERY_STRING into variables (sanitized).
# ----------------------------------------------------------------------
eval $(echo "$QUERY_STRING" | tr '&' '\n' | while read kv; do
    key=$(echo "$kv" | cut -d= -f1)
    val=$(echo "$kv" | cut -d= -f2)
    # URL-decode minus sign (allows negative duplex offsets via "%2D")
    val=$(echo "$val" | sed 's/%2D/-/g; s/%2d/-/g')
    # Sanitize: alphanumeric, dash, dot, underscore
    val=$(echo "$val" | sed 's/[^a-zA-Z0-9._-]//g')
    echo "$key=$val"
done)

# ----------------------------------------------------------------------
# 2. Read existing conf to inherit hardware/tuning defaults.
#    Each KEY=value line becomes a shell variable.
# ----------------------------------------------------------------------
if [ -r "$CONF" ]; then
    . "$CONF"
fi

# ----------------------------------------------------------------------
# 3. Apply form-overrides (fallback to existing conf or hardcoded default).
# ----------------------------------------------------------------------
# Cell parameters (form fields use lowercase, conf uses UPPERCASE legacy).
freq=${freq:-${TX_FREQ_HZ:-438250000}}
mcc=${mcc:-${MCC:-901}}
mnc=${mnc:-${MNC:-9998}}
la=${la:-${LA:-1}}
cc=${cc:-${CC:-49}}
tx_atten=${tx_atten:-${TX_ATT_OP_DB:--10}}
system_code=${system_code:-${SYSTEM_CODE:-2}}
duplex_spacing=${duplex_spacing:-${DUPLEX_SPACING:-0}}
ms_txpwr=${ms_txpwr:-${MS_TXPWR:-6}}
rxlevel_min=${rxlevel_min:-${RXLEVEL_MIN:-0}}
access_param=${access_param:-${ACCESS_PARAM:-10}}
radio_dl_timeout=${radio_dl_timeout:-${RADIO_DL_TIMEOUT:-5}}
opt_field=${opt_field:-${OPT_FIELD:-1011456}}
priority_cell=${priority_cell:-${PRIORITY_CELL:-0}}
migration=${migration:-${MIGRATION:-0}}
ncb=${ncb:-${NCB:-3}}
csl=${csl:-${CSL:-0}}

# Duplex-offset table: form fields dx0..dx7 (Hz, may be negative).
# Defaults from previous conf, else hardcoded MS-verified mapping.
dx0=${dx0:-${DUPLEX_OFFSET_HZ_0:--10000000}}
dx1=${dx1:-${DUPLEX_OFFSET_HZ_1:--45000000}}
dx2=${dx2:-${DUPLEX_OFFSET_HZ_2:-0}}
dx3=${dx3:-${DUPLEX_OFFSET_HZ_3:--10000000}}
dx4=${dx4:-${DUPLEX_OFFSET_HZ_4:--10000000}}
dx5=${dx5:-${DUPLEX_OFFSET_HZ_5:--10000000}}
dx6=${dx6:-${DUPLEX_OFFSET_HZ_6:--10000000}}
dx7=${dx7:-${DUPLEX_OFFSET_HZ_7:--7600000}}

# Hardware defaults (preserved from existing conf if not overridden).
SAMPLERATE_HZ=${SAMPLERATE_HZ:-4608000}
RF_BW_HZ=${RF_BW_HZ:-200000}
GAIN_MODE=${GAIN_MODE:-fast_attack}
TX_ATT_INIT_DB=${TX_ATT_INIT_DB:--89}
VCXO_DAC_VAL=${VCXO_DAC_VAL:-153}
XO_CORRECTION_HZ=${XO_CORRECTION_HZ:-40000000}
NUB_SYNC_THRESH=${NUB_SYNC_THRESH:-11}
DB_POLICY=${DB_POLICY:-0x3}

# ----------------------------------------------------------------------
# 4. Compute RX (UL) frequency.
#    Priority: explicit ul_freq form field > duplex_spacing-table lookup.
# ----------------------------------------------------------------------
if [ -n "${ul_freq:-}" ] && [ "$ul_freq" -gt 0 ] 2>/dev/null; then
    rx_freq=$ul_freq
else
    case "$duplex_spacing" in
        0) rx_freq=$(( freq + dx0 )) ;;
        1) rx_freq=$(( freq + dx1 )) ;;
        2) rx_freq=$(( freq + dx2 )) ;;
        3) rx_freq=$(( freq + dx3 )) ;;
        4) rx_freq=$(( freq + dx4 )) ;;
        5) rx_freq=$(( freq + dx5 )) ;;
        6) rx_freq=$(( freq + dx6 )) ;;
        7) rx_freq=$(( freq + dx7 )) ;;
        *) rx_freq=$(( freq + dx0 )) ;;
    esac
fi

# ----------------------------------------------------------------------
# 5. Write merged config back to /root/tetra_cell.conf (persistent).
#    Format: bash-source compatible, consumed by tetra_autostart.sh
# ----------------------------------------------------------------------
cat > "$CONF" <<EOF
# tetra_cell.conf — Board-Auto-Start-Konfiguration
# Letzte Aktualisierung via WebUI apply.cgi
# =============================================================================

# RF-Konfiguration (DL/UL & basics)
TX_FREQ_HZ=$freq
RX_FREQ_HZ=$rx_freq
SAMPLERATE_HZ=$SAMPLERATE_HZ
RF_BW_HZ=$RF_BW_HZ
GAIN_MODE=$GAIN_MODE

# TX-Pegel
TX_ATT_INIT_DB=$TX_ATT_INIT_DB
TX_ATT_OP_DB=$tx_atten

# VCXO/Clock
VCXO_DAC_VAL=$VCXO_DAC_VAL
XO_CORRECTION_HZ=$XO_CORRECTION_HZ

# Tetra-Cell-Tuning
NUB_SYNC_THRESH=$NUB_SYNC_THRESH
DB_POLICY=$DB_POLICY

# Cell-Identity + Signaling (consumed by tetra_sysinfo CLI)
MCC=$mcc
MNC=$mnc
LA=$la
CC=$cc
SYSTEM_CODE=$system_code
DUPLEX_SPACING=$duplex_spacing
MS_TXPWR=$ms_txpwr
RXLEVEL_MIN=$rxlevel_min
ACCESS_PARAM=$access_param
RADIO_DL_TIMEOUT=$radio_dl_timeout
OPT_FIELD=$opt_field
PRIORITY_CELL=$priority_cell
MIGRATION=$migration
NCB=$ncb
CSL=$csl

# Duplex-Spacing-Tabelle: pro Wert (0..7) ein Offset in Hz (negativ = UL unter DL).
# Editierbar via WebUI, MS-spezifisch wenn nötig.
DUPLEX_OFFSET_HZ_0=$dx0
DUPLEX_OFFSET_HZ_1=$dx1
DUPLEX_OFFSET_HZ_2=$dx2
DUPLEX_OFFSET_HZ_3=$dx3
DUPLEX_OFFSET_HZ_4=$dx4
DUPLEX_OFFSET_HZ_5=$dx5
DUPLEX_OFFSET_HZ_6=$dx6
DUPLEX_OFFSET_HZ_7=$dx7
EOF

# ----------------------------------------------------------------------
# 6. Apply RF settings live + restart tetra_sysinfo with new args.
# ----------------------------------------------------------------------
killall tetra_sysinfo 2>/dev/null
sleep 0.3

echo "$freq"    > /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency 2>/dev/null
echo "$rx_freq" > /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency 2>/dev/null
printf "%f"     "$tx_atten" > /sys/bus/iio/devices/iio:device1/out_voltage0_hardwaregain 2>/dev/null

nohup /root/tetra_sysinfo \
    --freq "$freq" \
    --mcc "$mcc" \
    --mnc "$mnc" \
    --la "$la" \
    --cc "$cc" \
    --sc "$system_code" \
    --duplex "$duplex_spacing" \
    --txpwr "$ms_txpwr" \
    --rxmin "$rxlevel_min" \
    --access "$access_param" \
    --dltimo "$radio_dl_timeout" \
    --optfield "$opt_field" \
    --prio "$priority_cell" \
    --migr "$migration" \
    --ncb "$ncb" \
    --csl "$csl" \
    --daemon \
    > /tmp/tetra_sysinfo.log 2>&1 &

sleep 1

# ----------------------------------------------------------------------
# 7. Confirmation output.
# ----------------------------------------------------------------------
if pidof tetra_sysinfo > /dev/null 2>&1; then
    echo "=== Cell gestartet — Conf gespeichert nach $CONF ==="
    echo "DL: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency) Hz"
    echo "RX: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency) Hz"
    echo "TX-Atten: $(cat /sys/bus/iio/devices/iio:device1/out_voltage0_hardwaregain) dB"
    echo ""
    echo "Cell: MCC=$mcc MNC=$mnc LA=$la CC=$cc SC=$system_code"
    echo "Duplex-Spacing-ID=$duplex_spacing → Offset=$(case $duplex_spacing in
        0) echo $dx0 ;; 1) echo $dx1 ;; 2) echo $dx2 ;; 3) echo $dx3 ;;
        4) echo $dx4 ;; 5) echo $dx5 ;; 6) echo $dx6 ;; 7) echo $dx7 ;;
    esac) Hz"
    echo "TXPwr=$ms_txpwr RxMin=$rxlevel_min Access=$access_param"
    echo "OptField=$opt_field PrioCell=$priority_cell Migration=$migration NCB=$ncb CSL=$csl"
    echo ""
    echo "--- Duplex-Tabelle (Hz) ---"
    echo "  0:$dx0   1:$dx1   2:$dx2   3:$dx3"
    echo "  4:$dx4   5:$dx5   6:$dx6   7:$dx7"
    echo ""
    head -5 /tmp/tetra_sysinfo.log
else
    echo "=== FEHLER: tetra_sysinfo nicht gestartet ==="
    cat /tmp/tetra_sysinfo.log
fi
