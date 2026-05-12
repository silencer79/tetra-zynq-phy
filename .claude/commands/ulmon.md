---
description: UL-Monitor-Log vom Board lesen + zusammenfassen
---

Live-State des UL-Monitors:

```bash
sshpass -p openwifi ssh -o StrictHostKeyChecking=no root@192.168.2.183 \
  'wc -l /tmp/tetra_ul_mon.log; echo "---"; cat /tmp/tetra_ul_mon.log' \
  2>/dev/null | tail -30
```

Zusammenfassung erzeugen:
- Anzahl `addr=Ssi(ISSI)` Demand-Fragments (frag=1) — entspricht
  Attach-Versuchen
- Anzahl `BL-ACK NR=0` (LI=6) — entspricht erfolgreichen Accept-Quittungen
- Anzahl `MAC-U-BLCK` (pdu=1 fill=1 at=2) — Demand-Fortsetzungen ODER
  fremde Sender (zweite ssi prüfen)
- Anzahl `U-RELEASE` (CMCE_type=7) und `U-ITSI-DETACH` (mm_type=1) —
  Lifecycle-PDUs einer registrierten MS
- Letzter Timestamp + Differenz zur Board-Zeit (`date +%T` via SSH) =
  wie lange ist Stille seit letzter Aktivität

Wenn unbekannte PDU-Form auftaucht: bit-walken (siehe Skript-Pattern in
PROTOCOL.md §9.1.1).
