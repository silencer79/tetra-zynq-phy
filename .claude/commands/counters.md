---
description: AXI-Diagnose-Counter live vom Board lesen
---

Lese die aktuellen MLE/Scheduler-Counter vom Board:

```bash
./scripts/tetra_ctrl.sh read 0x190 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x194 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x198 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x19C 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x1A0 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x1A4 2>&1 | tail -1
./scripts/tetra_ctrl.sh read 0x1AC 2>&1 | tail -1
```

Werte interpretieren:

- **0x190** = `{accept_cnt[15:0], ul_req_cnt[15:0]}` — perfekt 1:1
  Demand→Accept Quote zeigt erfolgreichen Attach
- **0x194** = `{busy_sticky, drop_cnt[15:0]}` — drop_cnt > 0 ist
  schlecht, busy_sticky = MLE-FSM aktiv
- **0x198** = `{clear_cnt[15:0], sig_override_cnt[15:0]}` — zeigt
  wieviele Bursts on-air gegangen sind
- **0x19C** = `REG_SIGNAL_TARGET_TN` (default 0)
- **0x1A0** = `REG_CELL_LA` (default 1)
- **0x1A4** = `REG_AST_DETACH_CNT` Phase 6 B — `[15:0]`=mle_detach_cnt (Anzahl
  decoder U-ITSI-DETACH events seit Boot)
- **0x1AC** = `REG_DB_POLICY` Phase 6 A — bit[0]=accept_unknown (default 1).
  `1`: Shadow miss → ACCEPT (M2-Verhalten). `0`: strict permit-check.

Output kompakt als Tabelle melden, mit Bedeutung wenn ungewöhnlich.
