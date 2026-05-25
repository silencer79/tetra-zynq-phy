---
description: Neueste DL+UL-WAV-Captures finden und dekodieren
---

Finde die zuletzt erstellten DL/UL-WAV-Files (heutige):

```bash
ls -lt --time=mtime *.wav 2>/dev/null | head -6
```

Wenn das jüngste Pärchen DL+UL ist (gleicher Zeitstempel, "DL_..." und
"UL_..." prefix):

1. RIFF-Header beider Files reparieren (sr=250 kHz beide):
 ```python
 import struct, os
 for f in [DL_FILE, UL_FILE]:
 sz = os.path.getsize(f)
 with open(f, 'r+b') as fp:
 fp.seek(4); fp.write(struct.pack('<I', sz - 8))
 fp.seek(40); fp.write(struct.pack('<I', sz - 44))
 ```

2. DL dekodieren:
 ```bash
 python3 scripts/decode_dl.py "$DL_FILE" --sr 250000 --max-bursts 99999 -v \
 > /tmp/dl_$(basename $DL_FILE.wav).log 2>&1
 tail -8 /tmp/dl_*.log | tail -8 # Summary
 grep -c "ID=2633617" /tmp/dl_*.log # SSI-addressed bursts to MTP3550
 grep -B1 "addr=SSI ID=2633617" /tmp/dl_*.log | grep AACH | sort -u # AACH variants
 ```

3. UL dekodieren:
 ```bash
 python3 scripts/decode_ul.py "$UL_FILE" --max-bursts 99999 \
 > /tmp/ul_$(basename $UL_FILE.wav).log 2>&1
 echo "BL-ACK count:"; grep -c "BL-ACK" /tmp/ul_*.log
 echo "Demand-frags:"; grep -c "BL-DATA(NS=0)" /tmp/ul_*.log
 echo "Distinct ssi:"; grep -oE "ssi=[0-9]+" /tmp/ul_*.log | sort -u
 ```

Resultat als Tabelle: SSI-Adressed-Burst-Count, Pre-Reply/Accept-Pärchen,
AACH-Werte (Unalloc/Unalloc als Match), MS-Lifecycle-PDUs, etc.

Bei Deltas zur Ref → Memory `removed-memory`
ist die verbindliche Bit-Spec.
