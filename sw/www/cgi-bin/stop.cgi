#!/bin/sh
echo "Content-Type: text/plain"
echo ""

killall tetra_sysinfo 2>/dev/null
sleep 0.3

if pidof tetra_sysinfo > /dev/null 2>&1; then
    echo "FEHLER: Prozess laeuft noch"
else
    echo "Cell gestoppt."
fi
