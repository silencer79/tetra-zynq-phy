#!/bin/sh
echo "Content-Type: text/plain"
echo ""

# Brief mode for state indicator
if echo "$QUERY_STRING" | grep -q "brief=1"; then
    if pidof tetra_sysinfo > /dev/null 2>&1; then
        /root/tetra_sysinfo --status 2>/dev/null | grep "CTRL:"
    else
        echo "TX=0 RX=0"
    fi
    exit 0
fi

echo "=== TETRA Cell Status ==="
echo ""

if pidof tetra_sysinfo > /dev/null 2>&1; then
    echo "Process: RUNNING (PID $(pidof tetra_sysinfo))"
else
    echo "Process: STOPPED"
fi
echo ""

echo "--- AD9361 ---"
echo "TX LO: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency 2>/dev/null) Hz"
echo "RX LO: $(cat /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency 2>/dev/null) Hz"
echo "TX Gain: $(cat /sys/bus/iio/devices/iio:device1/out_voltage0_hardwaregain 2>/dev/null)"
echo "Sample Rate: $(cat /sys/bus/iio/devices/iio:device1/in_voltage_sampling_frequency 2>/dev/null) Hz"
echo ""

echo "--- PHY Registers ---"
/root/tetra_sysinfo --status 2>/dev/null || echo "(tetra_sysinfo not available)"
echo ""

echo "--- Last Log ---"
tail -10 /tmp/tetra_sysinfo.log 2>/dev/null || echo "(no log)"
