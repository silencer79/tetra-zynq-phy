#!/bin/bash
# aach_grant_poke.sh — Phase H.6.3 helper
# Writes REG_AACH_GRANT_HINT @ 0x43C001F4 with [31]=pending, [13:0]=info.
# Override fires on the next TN=0 idle slot, then HW clears [31].
#
# Usage:
# scripts/aach_grant_poke.sh <info_hex>
# info_hex: 14-bit AACH info word, e.g. 0x4001 for header=01 sub-slot grant.
#
# Defaults to 0x4001 (Header=01 = sub-slot DL grant; placeholder until ETSI
# UL-grant header/field2 layout is finalized for MTP3550).
#
# Per-burst test recipe:
# 1. tail -F /tmp/tetra_ul_mon.log (board)
# 2../scripts/aach_grant_poke.sh (host)
# 3. watch UL_CONT_CNT @ 0x1B8 — should bump within ~1 frame if MS reacts.

set -e
INFO=${1:-0x4001}
INFO_DEC=$(printf '%d' "$INFO")
if [ "$INFO_DEC" -gt 16383 ]; then
 echo "ERROR: info word > 14 bit (max 0x3FFF)"
 exit 1
fi
WORD=$(printf '0x%08x' $((0x80000000 | INFO_DEC)))

BOARD=root@192.168.2.85
echo "[host] poke 0x43C001F4 = $WORD (pending=1, info=$INFO)"
sshpass -p openwifi ssh -o StrictHostKeyChecking=no $BOARD \
 "busybox devmem 0x43C001F4 32 $WORD"

echo "[host] readback:"
sshpass -p openwifi ssh -o StrictHostKeyChecking=no $BOARD \
 "busybox devmem 0x43C001F4 32"

echo "[host] UL_CONT_CNT before/after (sleep 1s)"
B=$(sshpass -p openwifi ssh -o StrictHostKeyChecking=no $BOARD 'busybox devmem 0x43C001B8 32')
sleep 1
A=$(sshpass -p openwifi ssh -o StrictHostKeyChecking=no $BOARD 'busybox devmem 0x43C001B8 32')
echo " before=$B after=$A"
