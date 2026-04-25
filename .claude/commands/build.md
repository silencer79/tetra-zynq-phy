---
description: Build + Deploy aktuellen HEAD im Hintergrund
---

Starte den Vivado-Build + Deploy im Hintergrund und logge in eine
zeitgestempelte Datei. Nutze `Bash` mit `run_in_background: true` damit
ich nicht blockiert werde.

```bash
./scripts/deploy.sh --init 2>&1 | tee /tmp/deploy_$(date +%H%M%S).log
```

Nach Start: kurz die Background-Task-ID melden, dann auf die
Notification warten (NICHT pollen). Wenn die Notification kommt, lese
das Log-Tail an und prüfe ob "DEPTH COMPLETE" + Bitstream verifiziert
drin steht.

Nach erfolgreichem Deploy: AXI-Counter lesen (siehe `/counters`) damit
wir den frischen Reset-Stand haben.
