#!/bin/sh
echo "Content-Type: text/plain"
echo ""

# Parse query string into variables
eval $(echo "$QUERY_STRING" | tr '&' '\n' | while read kv; do
    key=$(echo "$kv" | cut -d= -f1)
    val=$(echo "$kv" | cut -d= -f2)
    # Sanitize: only allow alphanumeric, dash, dot
    val=$(echo "$val" | sed 's/[^a-zA-Z0-9._-]//g')
    echo "$key=$val"
done)

# Defaults
freq=${freq:-438250000}
mcc=${mcc:-901}
mnc=${mnc:-9998}
la=${la:-1}
cc=${cc:-49}
tx_atten=${tx_atten:--10}
system_code=${system_code:-2}
duplex_spacing=${duplex_spacing:-1}
ms_txpwr=${ms_txpwr:-6}
rxlevel_min=${rxlevel_min:-0}
access_param=${access_param:-10}
radio_dl_timeout=${radio_dl_timeout:-5}
opt_field=${opt_field:-1011456}
priority_cell=${priority_cell:-0}
migration=${migration:-0}
ncb=${ncb:-3}
csl=${csl:-0}

# Save config for next boot
cat > /tmp/tetra_cell.conf <<EOF
freq=$freq
mcc=$mcc
mnc=$mnc
la=$la
cc=$cc
tx_atten=$tx_atten
system_code=$system_code
duplex_spacing=$duplex_spacing
ms_txpwr=$ms_txpwr
rxlevel_min=$rxlevel_min
access_param=$access_param
radio_dl_timeout=$radio_dl_timeout
opt_field=$opt_field
priority_cell=$priority_cell
migration=$migration
ncb=$ncb
csl=$csl
EOF

# Stop running instance
killall tetra_sysinfo 2>/dev/null
sleep 0.3

# Set AD9361 TX frequency and attenuation
echo "$freq" > /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency 2>/dev/null

# Calculate RX frequency based on duplex spacing
case "$duplex_spacing" in
    1) rx_freq=$(( freq - 7600000 )) ;;
    3) rx_freq=$(( freq - 10000000 )) ;;
    4) rx_freq=$(( freq + 10000000 )) ;;
    7) rx_freq=$freq ;;
    *) rx_freq=$(( freq - 10000000 )) ;;
esac
echo "$rx_freq" > /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency 2>/dev/null

# TX attenuation (driver needs float format e.g. "-10.000000")
printf "%f" "$tx_atten" > /sys/bus/iio/devices/iio:device1/out_voltage0_hardwaregain 2>/dev/null

# Start tetra_sysinfo with all CLI args
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

# Check if running
if pidof tetra_sysinfo > /dev/null 2>&1; then
    echo "=== Cell gestartet ==="
    echo "DL: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency) Hz"
    echo "RX: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency) Hz"
    echo "TX: $(cat /sys/bus/iio/devices/iio:device1/out_voltage0_hardwaregain)"
    echo ""
    echo "Parameter: MCC=$mcc MNC=$mnc LA=$la CC=$cc SC=$system_code"
    echo "Duplex=$duplex_spacing TXPwr=$ms_txpwr RxMin=$rxlevel_min"
    echo "Access=$access_param DLTimeout=$radio_dl_timeout"
    echo "OptField=$opt_field PrioCell=$priority_cell Migration=$migration"
    echo "NCB=$ncb CSL=$csl"
    echo ""
    head -5 /tmp/tetra_sysinfo.log
else
    echo "=== FEHLER: tetra_sysinfo nicht gestartet ==="
    cat /tmp/tetra_sysinfo.log
fi
