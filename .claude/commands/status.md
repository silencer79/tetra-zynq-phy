---
description: Komplett-Status — Branch, Counter, ul_mon, laufender Build
---

Zeige den aktuellen Stand der Anlage in einer Übersicht. Parallel
ausführen wo möglich.

1. Git-Stand:
 ```bash
 git log --oneline -3
 git status --short | grep -v "^??"
 git branch -v
 ```

2. Laufende Builds:
 ```bash
 ps aux | grep -E "deploy.sh|vivado" | grep -v grep | head -5
 ls -lt /tmp/deploy_*.log 2>/dev/null | head -3
 ```

3. Board-AXI-Counter (wie in `/counters`):
 ```bash
./scripts/tetra_ctrl.sh read 0x190
./scripts/tetra_ctrl.sh read 0x194
./scripts/tetra_ctrl.sh read 0x198
 ```

4. UL-Monitor letzte 5 Events + Board-Zeit:
 ```bash
 sshpass -p openwifi ssh -o StrictHostKeyChecking=no root@192.168.2.183 \
 'date +"Board-time: %T"; tail -10 /tmp/tetra_ul_mon.log' 2>/dev/null
 ```

Zusammenfassung als Tabelle:

| Stand | Wert |
|-------|------|
| HEAD | <commit + msg> |
| Working Tree | clean / N modified |
| Build | running / idle |
| ul_req_cnt / accept_cnt | A: B (1:1 = OK) |
| Letzter UL-Event | <timestamp> (<seit>s Stille) |

Wenn etwas auffällig (drop_cnt>0, ul_req != accept_cnt, alte Builds
hängen) — explizit im Klartext erwähnen.
