#!/usr/bin/env bash
# =============================================================================
# capture_rx_iq.sh — drain the on-board raw RX IQ capture buffer
#
# Reads the SDR's OWN post-RRC RX IQ (72 kHz) from tetra_rx_iq_capture via
# AXI-Lite, ordered oldest→newest, into a file of signed int16 I,Q pairs.
# This is the only valid data for evaluating THIS receiver.
#
# AXI map (base 0x43C00000):
#   REG_IQCAP_CTRL   0x138  [0]=freeze, [28:16]=rd_addr
#   REG_IQCAP_DATA   0x13C  {I[31:16], Q[15:0]} at rd_addr
#   REG_IQCAP_STATUS 0x1FC  {19'd0, wr_ptr[12:0]}
#
# Usage: ./scripts/capture_rx_iq.sh [out.csv]   (default: build/rx_iq_capture.csv)
# =============================================================================
set -euo pipefail
HOST="${HOST:-192.168.2.90}"
PASS="${PASS:-openwifi}"
OUT="${1:-build/rx_iq_capture.csv}"
DEPTH=8192
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$HOST"

echo "=== freeze + drain $DEPTH samples from board $HOST ==="
# One SSH session runs the whole drain on-board (per-word SSH would be far too slow).
RAW=$($SSH '
  CTRL=0x43C00138; DATA=0x43C0013C; STAT=0x43C001FC
  busybox devmem $CTRL 32 0x1            # freeze
  echo "WRPTR $(( $(busybox devmem $STAT 32) ))"   # emit decimal
  a=0
  while [ $a -lt '"$DEPTH"' ]; do
    busybox devmem $CTRL 32 $(( (a<<16) | 1 ))   # set rd_addr, keep freeze
    echo "$a $(( $(busybox devmem $DATA 32) ))"   # emit decimal
    a=$((a+1))
  done
  busybox devmem $CTRL 32 0x0            # un-freeze (resume capture)
')

# wr_ptr = newest+1; chronological order starts there and wraps.
WRPTR=$(echo "$RAW" | awk '/^WRPTR/{print $2}')   # already decimal
echo "wr_ptr = $WRPTR"

# Parse "addr decval" → array[addr]=value, then emit oldest→newest as I,Q int16
echo "$RAW" | awk -v wp="$WRPTR" -v depth="$DEPTH" '
  /^WRPTR/ {next}
  NF==2 { v[$1+0] = $2+0 }
  END {
    for (k=0; k<depth; k++) {
      a = (wp + k) % depth
      w = v[a]
      i = int(w / 65536) % 65536; if (i >= 32768) i -= 65536   # signed I (top 16)
      q = w % 65536;              if (q >= 32768) q -= 65536   # signed Q (low 16)
      printf "%d,%d\n", i, q
    }
  }' > "$OUT"

N=$(wc -l < "$OUT")
echo "wrote $N IQ samples → $OUT"
echo "first 3: $(head -3 "$OUT" | tr "\n" " ")"
NZ=$(awk -F, '$1!=0 || $2!=0' "$OUT" | wc -l)
echo "non-zero samples: $NZ / $N   $([ "$NZ" -gt 0 ] && echo "(RX liefert Daten)" || echo "(ALLES 0 — RX-Tap leer!)")"
