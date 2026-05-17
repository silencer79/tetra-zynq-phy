# IST — Kapitel 9: SW Stack
Stand: 2026-05-17
Quelle: alle Dateien in sw/ inkl. `sw/etsi_codec/`

Dieses Kapitel beschreibt nur das, was die Quellen unter `sw/` heute tatsaechlich
implementieren. Es ist kein Design-Dokument und keine Spezifikation. Bei
Unklarheit aus dem Code ist das im Text vermerkt.

---

## Section 1 — Daemons

Auf dem Board (LibreSDR, Zynq-7020, armv7l) laufen drei langlebige Userspace-
Prozesse, alle aus `sw/` cross-kompiliert und nach `/root/` deployed.

---

### sw/tetra_hal.c (1908 Zeilen) — Binary: `tetra_sysinfo`

Datei trägt sowohl die HAL-Library-Funktionen als auch `main()`. Das gleiche
`.c` wird mehrfach gegen verschiedene Stubs gelinkt — siehe Section 6.

**Lifecycle:**
- Cross-kompiliert via `make tetra_sysinfo` → ARM binary `sw/tetra_sysinfo`.
- Deploy nach `/root/tetra_sysinfo` per `scripts/deploy.sh`.
- Start ueber `scripts/deploy.sh --init` (Zeile 333):
 ```
 setsid /root/tetra_sysinfo --daemon < /dev/null > /tmp/tetra_sysinfo.log 2>&1 &
 ```
 also `setsid` (detached, ueberlebt SSH-Disconnect).
- Alternativstart: WebUI `apply.cgi` (Zeile 81) startet via `nohup`:
 ```
 nohup /root/tetra_sysinfo --freq … --daemon > /tmp/tetra_sysinfo.log 2>&1 &
 ```
- Stop: WebUI `stop.cgi` macht `killall tetra_sysinfo`. Selbst-Stop ueber
 SIGINT/SIGTERM → `daemon_signal_handler` setzt `g_daemon_running = 0`.
- Log: `/tmp/tetra_sysinfo.log` (stdout+stderr line-buffered via
 `setvbuf(stdout, NULL, _IOLBF, 0)`).

**Boot-Sequenz** (Zeile 1717…1789, immer auch im Nicht-Daemon-Modus):
1. `tetra_rm3014_init()` baut RM(30,14) Lookup-Table im RAM.
2. `tetra_hal_init()` → `open("/dev/mem", O_RDWR|O_SYNC)` + `mmap(NULL,
 0x1000, …, TETRA_AXI_BASE=0x43C00000)`.
3. Sanity-Check `REG_VERSION (0x08)`: muss != 0x00000000 und != 0xFFFFFFFF
 sein, sonst Abort.
4. `tetra_write_cell_config(&hal, &info)` → `REG_CELL_CFG_0 (0x130)` +
 `REG_CELL_CFG_1 (0x134)` mit gepacktem `system_code | sharing_mode |
 ts_reserved_frames | u_plane | frame_18_extension | ncb | csl |
 late_entry_support` resp. `mcc | mnc`.
5. `tetra_refresh_sysinfo(&hal, &info)`: rebuildet BNCH SCH/F + SB_BKN2 +
 NDB + MCCH-Blocks (alle 216-bit SCH/HD bzw. 432-bit SCH/F kanal-kodiert).
6. `tetra_write_null_pdu(…)` → `REG_NULL_PDU_0..6 (0x148..0x160)`,
 static 216-bit Filler fuer Idle-Slots.
7. `tetra_write_schedule(&hal)` kopiert 144×32-bit aus
 `tetra_schedule_table.h` nach `REG_SCHEDULE_BASE (0x400)`.
8. `REG_COLOUR_CODE (0x10)` = `info.colour_code & 0x3F`.
9. `tetra_tx_tdma_load(&hal, 0, 0, 0, 0)` → `REG_TX_TDMA_LOAD (0x140)`
 mit `TX_TDMA_LOAD_STROBE` Bit 31.
10. `REG_SIGNAL_TARGET_TN (0x19C) = 0` (Signalling auf TN=0).
11. `REG_CELL_LA (0x1A0) = info.la & 0x3FFF`.
12. `tetra_enable(&hal, sync_thresh)` → `REG_CTRL (0x00)` = 0x03 + optional
 `REG_SYNC_THRESH (0x0C)`.
13. `REG_REASSEMBLY_T0 (0x1DC) = 1` (Frame).
14. `REG_NWRK_BCAST_PERIOD_MF (0x1E8) = 10` (Multiframes).
15. Falls nicht `--daemon`: HAL schließen und exit 0.

**Daemon-Hauptschleife** (Zeile 1856…1903, nur mit `--daemon`):
- `clock_gettime(CLOCK_MONOTONIC, &next)` als Start-Anchor.
- Vor Schleifeneintritt einmalig `refresh_d_nwrk_broadcast(&hal, scramb_init)`.
- Schleife pro Iteration:
 - `next.tv_sec += 60` (Sleep-Cadence 60 s).
 - `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL)`,
 EINTR-retry-fest.
 - Jede Iteration: `info.hyperframe++` und `tetra_refresh_sysinfo(&hal,
 &info)` (Hyperframe alle ~61.2 s on-air ≈ alle Iteration).
 - `refresh_d_nwrk_broadcast(&hal, scramb_init)` rebuildet das 432-bit
 SCH/F kodierte D-NWRK-BROADCAST-Window aus aktueller UTC-Zeit
 (`time(NULL)`) und schreibt nach
 `REG_NWRK_BCAST_INDEX (0x1D0) / REG_NWRK_BCAST_DATA (0x1D4)` (14
 Wörter), KEIN Trigger-Write (RTL feuert autonom alle
 `REG_NWRK_BCAST_PERIOD_MF` Multiframes).

**Inputs:**
- `getopt_long` Optionen (Zeile 1634): `--freq --mcc --mnc --la --cc --sc
 --duplex --txpwr --rxmin --access --dltimo --optfield --prio --migr --ncb
 --csl --hf --daemon --thresh --status --no-enable`.
- Sysinfo-Defaults (Zeile 1580): freq=438.250 MHz, mcc=901, mnc=9998, la=1,
 cc=49, system_code=3, opt_field=1011456 (0xF6F00), hyperframe=1.

**Outputs (AXI-Writes):**
Alle AXI-Adressen sind `TETRA_AXI_BASE + offset` mit Base 0x43C00000.
Wichtige Schreib-Targets pro Boot:
- `0x40..0x7C` (SB1 + SB_BKN2 + SB_BB) — BSCH-Block + SB_BKN2 SCH/F-Filler
- `0x88..0xBC` (NDB_BLK1 + NDB_BLK2) — NDB SCH/HD-Filler
- `0xC0..0xF4` (MCCH_BLK1 + MCCH_BLK2) — MCCH ACCESS-DEFINE
- `0xF8..0x12C` (BNCH_BLK1 + BNCH_BLK2) — BNCH SCH/HD
- `0x130, 0x134` (CELL_CFG_0/1)
- `0x140` (TX_TDMA_LOAD)
- `0x148..0x160` (NULL_PDU)
- `0x400..0x63C` (Schedule BRAM 144 Wörter)
- `0x10` (REG_COLOUR_CODE)
- `0x19C` (REG_SIGNAL_TARGET_TN)
- `0x1A0` (REG_CELL_LA)
- `0x00` (REG_CTRL = 0x03)
- `0x1DC` (REG_REASSEMBLY_T0 = 1)
- `0x1E8` (REG_NWRK_BCAST_PERIOD_MF = 10)
- `0x1D0` (REG_NWRK_BCAST_INDEX) + `0x1D4` (REG_NWRK_BCAST_DATA) — Daemon-
 Loop alle 60 s zyklisch.

**Log destinations:**
- `/tmp/tetra_sysinfo.log` (stdout/stderr via `setsid` Redirect)
- `printf` mit Boot-Info ("Frequency: x.xxx MHz → band=N carrier=M …"),
 "SYSINFO written: BNCH SCH/F + …", "REASSEMBLY_T0 set to 1 frame …",
 "NWRK_BCAST_PERIOD_MF set to 10 multiframes …", pro Iteration "HN
 advance: hyperframe = N".

**FSM-States:** keine explizite FSM. Nur Hauptloop = "sleep 60 s →
hyperframe++ → refresh".

**Bekannte Trigger:**
- SIGINT/SIGTERM → exit (Daemon)
- Daemon-Tick (60 s) → SYSINFO hyperframe++ + D-NWRK-BCAST payload-refresh.

**Auffaelligkeiten:**
- Datei trägt sowohl Library-Funktionen (CRC-16, RCPC, Interleaver,
 Scrambler, BSCH/BNCH/SCH/F Encoder) als auch `main()` in einer Datei.
 `tetra_attach_daemon.c` und `tetra_ul_mon.c` definieren deshalb lokale
 Kopien von `tetra_hal_init/close` (sonst Multi-`main`-Linkfehler).
- Inline-Kommentar "Phase H.3.2d (2026-05-02) — Reassembly-T0 = 1 Frame"
 erklärt den `REG_REASSEMBLY_T0 = 1` Write.
- Inline-Kommentar "Phase H.7-AF" erklärt `REG_NWRK_BCAST_PERIOD_MF=10`.
- `build_d_nwrk_broadcast_268()` Zeile 1469: PDU-Template fest als
 HEX-Konstante `2081ffffff0552b2a98fcefc8423ffc4001080…`, davon nur Bits
 87..96 mit Live-UTC (`(utc/2) & 0x3FF`) ueberschrieben.
- `usage()` listet `--optfield 24448` als Default; tatsächlich ist
 `info.optional_field_value = 1011456` (0xF6F00) im Init-Block — die
 Usage-Help-Zeile ist veraltet.

---

### sw/tetra_attach_daemon.c (580 Zeilen)

**Lifecycle:**
- Cross-kompiliert via `make tetra_attach_daemon`. Build linkt
 `tetra_attach_daemon.c + tetra_db.c + tetra_tx_transport.c +
 tetra_grpack_body.c + tetra_cmce_body.c + tetra_cmce_parser.c +
 tetra_call_fsm.c` (Makefile Zeile 39-47).
- Deploy nach `/root/tetra_attach_daemon` per `scripts/deploy.sh`.
- Start ueber `scripts/deploy.sh --init` (Zeile 347):
 ```
 pkill -f '[t]etra_attach_daemon' 2>/dev/null
 test -f /root/db.tsv || cp /root/db.tsv.default /root/db.tsv
 devmem 0x43C001AC 32 0x3
 setsid /root/tetra_attach_daemon < /dev/null > /tmp/tetra_attach_daemon.log 2>&1 &
 ```
- Stop: SIGINT/SIGTERM → `on_sigint` setzt `keep_running = 0`.
- Vor Exit (Zeile 574): `tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x0u)` und
 letzte stderr-Zeile.
- Log: `/tmp/tetra_attach_daemon.log`.

**Boot-Init** (Zeile 327…390):
- arg parse `[--db-path PATH]` (default `TETRA_DB_DEFAULT_PATH = "/root/db.tsv"`).
- `tetra_hal_init()` (lokal definiert, Zeile 48-56).
- `signal(SIGINT/SIGTERM, on_sigint)`.
- `tetra_db_load(db_path)` → in-RAM Tabelle.
- `REG_REPLY_USE_SW (0x230) = 0x1` (Mailbox-Pull aktivieren).
- **MER-Fix:** `REG_VOICE_ACTIVE_MASK (0x1EC) = 0x00` (clear ggf. von
 vorherigem Call hängenden Mask-Bits).
- **2026-05-17:** `REG_VOICE_NUB_SYNC_THRESH (0x268) = 11u` (Boot-Default,
 ersetzt RTL-Default 8). 11 ist Sweet-Spot aus Survey: BFI 4.7 % bei
 saubererem Burst-Rate (~19/s real vs ~28/s false-positives bei thresh=10).
 Siehe `reference_nub_sync_thresh` Memory.
- Stderr-Log: "tetra_attach_daemon: started — USE_SW=1, polling
 REG_DEMAND_STATUS, policy=0xN, VOICE_ACTIVE_MASK=0, NUB_SYNC_THRESH=11".

**Main loop** (Zeile 375…572):

Drei zusammengefasste Aufgaben pro Iteration (kein verschachteltes
Polling-Intervall — pacing nur ueber `nanosleep(POLL_INTERVAL_MS)` im
"nichts passiert"-Branch):

1. **Group-Demand mailbox** (Phase Y.1.e):
 - `status = tetra_reg_read(REG_GRP_DEMAND_STATUS=0x240)`; wenn Bit 0
 gesetzt → `service_grp_demand(&hal)`.
2. **CMCE UL-PDU-Dispatch** (Phase 7 G.2):
 - `ul_status = tetra_reg_read(REG_UL_PDU_STATUS=0x164)`; wenn
 `UL_STATUS_VALID` UND `ul_count != last_ul_count`:
 - Liest `REG_UL_PDU_STATUS_2 (0x1B4)`, prueft `MLE_DISC == 2` (CMCE),
 - liest `REG_UL_PDU_SSI (0x168)` + `RAW_0/1/2 (0x16C/0x170/0x174)`,
 - rekonstruiert MSB-first Body (`raws[N/32] bit N%32`),
 - berechnet `cmce_start = (opt_flag ? 36: 30) + llc_hdr_bits + 3`,
 wobei llc_hdr_bits = 6 (BL-ADATA) / 5 (BL-DATA) / 4 (BL-ACK/BL-UDATA),
 - ruft `tetra_cmce_parse(body, cmce_bits, &p)` und
 `tetra_call_fsm_handle(&hal, cmce_ssi, &p)` auf.
 - last_ul_count = ul_count (Init mit 0xFFFF, damit erste PDU
 garantiert getriggert wird).
3. **mm=2 Demand mailbox** (Phase X.3):
 - `status = tetra_reg_read(REG_DEMAND_STATUS=0x200)`; Bit 0 = pending.
 - Wenn pending → 6 Worte ueber `demand_read(idx=0..5)` lesen
 (`REG_DEMAND_INDEX=0x204 → REG_DEMAND_DATA=0x208`).
 - Felder: `ssi = w1 & 0xFFFFFF`, `la = REG_CELL_LA & 0x3FFF` (NICHT
 w2 — wird ignoriert, Cell-LA "antwortet" mit eigener LA), `lut = (w0
 >> 15) & 0x7`, `cnt = (w0 >> 18) & 0x7`, `gssi[3] = w3/w4/w5`.
 - ISSI-Lookup → entweder ENTRY (profile_id übernehmen), oder bei
 `allow_issi=1` autoenroll `tetra_db_alloc(ssi, 0, 0)`, oder
 reject-temp.
 - GSSI-Wish-Loop ueber `actual_count = min(cnt, 3)` Slots: erste
 Lookup-Hit gewinnt; bei allow_gssi=1 autoenroll. Fallback
 `M2_FALLBACK_GILA_GSSI = 0x2F4D61`.
 - `stage_accept_body(...)` mit `result`, `gila_*` → ruft je nach
 `result` entweder `tetra_tx_submit(hal, TX_LU_ACCEPT, &meta)` oder
 `TX_LU_REJECT` auf.
 - `REG_DEMAND_ACK (0x20C) = 1` Pulse → HW-Slot frei.
4. **Idle-Branch** (kein Demand pending, keine UL-PDU):
 - `nanosleep(POLL_INTERVAL_MS = 10 ms)`.
 - `since_reload_ms += 10`. Wenn ≥ `DB_RELOAD_INTERVAL_MS = 5000`:
 `tetra_db_reload()` (stat mtime → re-read TSV wenn geändert).

**Polling-Intervalle (Konstanten):**
- `POLL_INTERVAL_MS = 10` (Zeile 82)
- `DB_RELOAD_INTERVAL_MS = 5000` (Zeile 83)
- `GRP_NSNR_SLOTS = 64` (open-addressing Hash fuer LLC NS/NR per SSI)

**FSM-States:**
Keine explizite Top-Level-FSM. Aber zwei interne Zustandsspeicher:
- `grp_nsnr_table[64]` (Zeile 113): pro SSI ein 32-bit Slot
 `{ssi[31:8], ns[1], nr[0]}`, alterniert pro Aufruf.
- `last_ul_count` (Zeile 373) als Edge-Trigger fuer CMCE-Dispatch.

**Inputs:**
- AXI-Reads: 0x164 (REG_UL_PDU_STATUS), 0x168 (REG_UL_PDU_SSI), 0x16C/0x170/0x174 (RAW_0/1/2), 0x1A0 (REG_CELL_LA), 0x1AC (REG_DB_POLICY), 0x1B4 (REG_UL_PDU_STATUS_2), 0x200 (REG_DEMAND_STATUS), 0x208 (REG_DEMAND_DATA), 0x240 (REG_GRP_DEMAND_STATUS), 0x248 (REG_GRP_DEMAND_DATA).
- File-Inputs: `/root/db.tsv` (Default-Pfad).

**Outputs:**
- AXI-Writes: 0x204 (REG_DEMAND_INDEX), 0x20C (REG_DEMAND_ACK=1), 0x230 (REG_REPLY_USE_SW=1/0 entry/exit), 0x244 (REG_GRP_DEMAND_INDEX), 0x24C (REG_GRP_DEMAND_ACK=1), 0x1EC (REG_VOICE_ACTIVE_MASK via call_fsm), plus alles was `tetra_tx_transport` ueber die Reply-Mailbox stagt (0x220..0x22C, REG_REPLY_GO=0x228).
- File-Writes: indirekt via `tetra_db_alloc()` → `/root/db.tsv` atomic
 re-write (write `db.tsv.tmp` + `rename(2)`).
- Log: stderr → `/tmp/tetra_attach_daemon.log`.

**Bekannte Trigger:**
- mm=7 Group-Status-Query (`cnt=0 rep=1 atd=0`): COMPLETE SKIP (Zeile
 237-243). Daemon ACKt nur die Demand-Snapshot, kein Reply.
- mm=7 Group-Demand mit cnt>0: filtert DETACH-Records raus (`adi[i]==1`,
 Zeile 196), behält nur ATTACH-Records. Bei `reply_count==0` → ACK, kein
 Reply. Sonst → `tetra_tx_submit(TX_GRP_ATTACH_ACK)`.
- mm=2 ITSI-Attach Demand: immer komplett bearbeitet (LU-ACCEPT oder
 reject-temp wenn allow_issi=0 oder Tabelle voll).
- CMCE UL-PDU (mle_disc==2): dispatch nach `tetra_call_fsm_handle()`.

**Auffaelligkeiten:**
- `M2_FALLBACK_GILA_GSSI = 0x2F4D61` (Zeile 77).
- Inline-Kommentar im Status-Query-Branch (Zeile 220-243) erklärt, warum
 diese skip-Logic spec-konform ist und MS sonst "I am already in groups"
 schließen würde.
- Inline-Kommentar Zeile 130 erklärt den Initial-NS=0 NR=1 Reset auf GS#1-
 Pattern (vorher NS=1 NR=0 = GS#2).
- `M2_DEFAULT_*` Konstanten Zeile 73-80.

---

### sw/tetra_ul_mon.c (225 Zeilen) — Binary: `tetra_ul_mon`

**Lifecycle:**
- Cross-kompiliert via `make tetra_ul_mon`.
- Deploy nach `/root/tetra_ul_mon`.
- Start ueber `scripts/deploy.sh --init` (Zeile 336):
 ```
 setsid /root/tetra_ul_mon < /dev/null > /tmp/tetra_ul_mon.log 2>&1 &
 ```
- Stop: SIGINT/SIGTERM → `on_sigint` setzt `g_stop = 1`.
- Log: `/tmp/tetra_ul_mon.log`.

**Main loop:**
- Boot: `getopt_long` Args `--mcc N --mnc N --cc N --poll-ms N --seed HEX`.
 Defaults: mcc=901, mnc=9998, cc=49, poll-ms=10.
- `seed = cell_scramb_seed(mcc, mnc, cc) = ((mcc&0x3FF)<<22) |
 ((mnc&0x3FFF)<<8) | ((cc&0x3F)<<2) | 3` (Zeile 49-55).
- `tetra_reg_write(REG_UL_SCRAMB_INIT=0x17C, seed)`, Readback-Check.
- `REG_UL_PDU_CTRL (0x178) = 1` (W1C Clear sticky beim Start).
- Loop `while(!g_stop)`:
 - `status = tetra_reg_read(REG_UL_PDU_STATUS=0x164)`.
 - Wenn `UL_STATUS_VALID(status)`:
 - Liest `ssi (0x168) & 0xFFFFFF` (24-bit ISSI, keine 10-bit-Maske!),
 `RAW_0/1/2 (0x16C/0x170/0x174)`, `status2 (0x1B4)`, `rstats (0x1E0)`.
 - Decodiert Felder: `pdu_type, fill, enc, at, opt, frag, resreq, count`.
 - Printf 2 Zeilen mit Timestamp `[HH:MM:SS]`, raw-hex, gap-Detection
 (`count != last_count+1`), `llc/mle_disc/mm_pdu_type` + reassembly-
 Counter.
 - `REG_UL_PDU_CTRL (0x178) = 1` W1C clear sticky.
 - Heartbeat: alle `5000/poll_ms` Iterationen ein `.` print.
 - `nanosleep(poll_ms ms)`.

**Polling-Intervalle (Konstanten):**
- `poll_ms = 10` (default, ueberschreibbar via `--poll-ms`).
- Heartbeat-Intervall = 5000 ms = 500 Iterationen.

**Inputs:**
- AXI-Reads: 0x164, 0x168, 0x16C, 0x170, 0x174, 0x1B4, 0x1E0.

**Outputs:**
- AXI-Writes: 0x17C (REG_UL_SCRAMB_INIT), 0x178 (REG_UL_PDU_CTRL W1C).
- Log: stdout → `/tmp/tetra_ul_mon.log`.

**FSM-States:** keine. Nur `last_count`, `first`, `loops`-Zähler.

**Bekannte Trigger:**
- Jedes neue PDU (sticky-valid pulse) → eine Log-Zeile + W1C.

**Auffaelligkeiten:**
- Inline-Kommentar Zeile 186-205 dokumentiert dass die alte
 `REG_AACH_GRANT_HINT (0x1F4)` Override-Logik in Phase H.3.2c entfernt
 wurde — der `(void)frag; (void)at;` cast-to-void haelt die Felder
 am Leben falls man sie spaeter braucht.
- Lokale `tetra_hal_init/close` Stubs (Zeile 29-44), gleicher Grund wie
 in tetra_attach_daemon.c.

---

## Section 2 — PDU Encoders/Parsers

### sw/tetra_cmce_parser.c (162 Zeilen)

**Zweck:**
Parsen von UL-CMCE-PDUs aus MSB-first Byte-Streams. Greift NUR Type-1
(Mandatory) Header — Type-2/3 IEs nach `o_bit` werden NICHT konsumiert
(o_bit wird aber sichtbar surfaced).

**Aufrufer:**
- `sw/tetra_attach_daemon.c` Zeile 429: `tetra_cmce_parse(body, cmce_bits,
 &p)` nach dem CMCE-Body-Reassembly aus `RAW_0/1/2`.

**Wichtige Funktionen:**
- `tetra_cmce_parse(body_bits, n_bits, *out)` — Eintrittspunkt. Liest
 5-bit pdu_type, mappt nach `cmce_pdu_type_t` Enum (Zeile 38-52), dann
 per-type Branch.
- `get_bits(src, *pos, nbits)` — MSB-first bit reader.
- `parse_bsi(src, *pos, n_bits, *bsi)` — Basic-Service-Information,
 variable Länge je nach `circuit_mode_type` (8 oder 10 bit).
- `map_pdu_type(raw)` — bluestation-konformes Pdu-Type-Enum:
 - 0 → CMCE_U_ALERT (0x10 marker), 2 → U_CONNECT, 4 → U_DISCONNECT, 5 →
 U_INFO, 6 → U_RELEASE, 7 → U_SETUP, 8 → U_STATUS, 9 → U_TX_CEASED,
 10 → U_TX_DEMAND, default → CMCE_UNSUPPORTED (0xFF).
- Per-Pdu-Type-Parsing:
 - `CMCE_U_SETUP`: area_selection(4)+hook(1)+sd(1)+BSI(8/10)+req_tx(1)+
 call_priority(4)+clir(2)+cpti(2)+ssi/sna/(ssi+ext)+o_bit.
 - `CMCE_U_TX_DEMAND`: call_id(14)+priority(2)+enc_ctrl(1)+reserved(1)+
 o_bit.
 - `CMCE_U_TX_CEASED`: call_id(14)+o_bit.
 - `CMCE_U_RELEASE` / `CMCE_U_DISCONNECT`: call_id(14)+cause(5)+o_bit.
 - Sonst (U_CONNECT/INFO/ALERT/STATUS): nur call_id wenn ≥14 bit
 verfügbar.

**Returncodes:** 0 ok, -1 buffer-too-short / NULL-args, -2
pdu_type unsupported.

**Bekannte Tests:**
- `sw/test_cmce_parser.c` — Host-side regression (compiled via `gcc`,
 nicht `arm-linux-gnueabihf-gcc`). Test-Cases:
 - TC1: U-TX-DEMAND call_id=0x1234 prio=2 enc=1 → erwartet alle Felder.
 - TC2: U-RELEASE call_id=217 cause=11 (ExpiryOfTimer).
 - TC3: U-TX-CEASED call_id=42.
 - TC4: U-SETUP cpti=Ssi ssi=910001 BSI(TchS=0, p2mp=1).
 - TC4b: U-SETUP cpti=SNA sna=0x5A.
 - TC4c: U-SETUP cpti=TSI ssi=0x123456 ext=0xABCDEF.
 - TC5: Unsupported pdu_type=31 → rc=-2.
 - TC6: Short buffer (3 bits) → rc=-1.

---

### sw/tetra_cmce_body.c (207 Zeilen)

**Zweck:**
Erstellt DL-CMCE-PDU-Bodies (MSB-first byte stream, beginnend mit 5-bit
pdu_type) für 5 PDUs.

**Aufrufer:**
- `sw/tetra_tx_transport.c` (Zeile 226-235 `submit_cmce_pdu`), aufgerufen
 aus `tetra_call_fsm.c` (D-CALL-PROCEEDING / D-CONNECT / D-TX-GRANTED /
 D-TX-CEASED / D-RELEASE / D-SETUP).

**Wichtige Funktionen:**
- `put_bits(dst, *pos, value, nbits)` — MSB-first bit-packer.
- `write_bsi(out, *pos, *m)` — BSI 8 bit, variable Sub-Layout.
- `tetra_cmce_build_d_setup(meta, out)` — 41 bit Body (pdu=7 + call_id +
 call_time_out(4) + hook(1) + sd(1) + BSI(8) + tg(2) + trp(1) + prio(4)
 + o-bit=0).
- `tetra_cmce_build_d_call_proceeding(meta, out)` — 25 bit (pdu=1 +
 call_id + call_time_out_setup_phase(3) + hook(1) + sd(1) + o-bit=0).
- `tetra_cmce_build_d_connect(meta, out)` — 39 bit (Phase 7 G.7+
 spec-konform: pdu=2 + call_id + call_time_out(4) + hook(1) + sd(1) +
 tg(2) + trp(1) + call_ownership(1) + **o-bit=1** + p_call_priority(1)
 + value(4) + p_bsi=0 + p_tmp_addr=0 + p_notif=0 + m-bit=0). Inline-
 Kommentar Zeile 112-131 dokumentiert -Burst #5887.
- `tetra_cmce_build_d_tx_granted(meta, out)` — 25 bit (pdu=11 + call_id +
 tg(2) + trp(1) + enc(1) + reserved(1) + o-bit=0).
- `tetra_cmce_build_d_tx_ceased(meta, out)` — 21 bit (pdu=9 + call_id +
 trp(1) + o-bit=0).
- `tetra_cmce_build_d_release(meta, out)` — 25 bit (pdu=6 + call_id +
 cause(5) + o-bit=0).

**Konstanten** (Header tetra_cmce_body.h):
- `CMCE_TG_GRANTED=0, CMCE_TG_NOT_GRANTED=1, CMCE_TG_REQUEST_QUEUED=2,
 CMCE_TG_GRANTED_TO_OTHER_USER=3`.
- DCAUSE-Set: NORMAL_USER_REQ=0, PRE_EMPTIVE_USE=1, NETWORK_UNAVAIL=9,
 EXPIRY_OF_TIMER=11, RESOURCES_UNAVAIL=12.

**Bekannte Tests:**
- `sw/test_cmce_body.c` (278 Zeilen) — Host-side regression.
 - TC1: D-CALL-PROCEEDING call_id=4 T30s → 25 bit.
 - TC2: D-RELEASE call_id=217 cause=11 → 25 bit.
 - TC3: D-CONNECT bluestation-conformant call_id=4 owner=1 → 30 bit.
 **WICHTIG:** TC3 erwartet 30 bit für D-CONNECT (`m.call_ownership=1`),
 aber der lebende `tetra_cmce_build_d_connect()` produziert **39 bit**
 Body mit o-bit=1 Type-2-IE-Chain. TC3 testet eine andere D-CONNECT-
 Variante als der eingesetzte Builder erzeugt — unklar aus Code, ob
 der Test heute noch grün läuft. Inline-Kommentare im Test (Zeile
 155-178) erwähnen 30 bit; Implementierung (Zeile 107-156) liefert
 aber 39 bit.
 - TC4: D-TX-GRANTED call_id=1 tg=Granted → 25 bit.
 - TC5: D-SETUP TchS p2mp tg=GrantedToOther → 41 bit.
 - TC6: D-RELEASE call_id=0x1234 cause=0 → 25 bit.

---

### sw/tetra_grpack_body.c (102 Zeilen)

**Zweck:**
Baut die MM-Body-Bits der `D-ATTACH-DETACH-GROUP-IDENTITY-ACKNOWLEDGEMENT`
PDU (mm_pdu_type=11). 0/1/2/3 Records.

**Aufrufer:**
- `sw/tetra_tx_transport.c::submit_grp_ack` (Zeile 197-220) als Teil des
 `TX_GRP_ATTACH_ACK` Pfads.

**Wichtige Funktionen:**
- `put_bits(dst, *pos, value, nbits)` — MSB-first bit-packer.
- `tetra_grpack_build(meta, out_bits)` — Body-Builder.

**Bitlayout** (per Header `tetra_grpack_body.h`):
- 0 Records: 8 bit Body `1011 0 0 0 0` = `0xB0`.
- 1 Record: 62 bit (header 30 bit + 32 bit Record).
- 2 Records: 94 bit.
- 3 Records: 126 bit.

Header: `mm_pdu_type=11 (4 bit, 0b1011)`, `accept_reject(1)`, `reserved=0(1)`,
`o_bit(1)`, dann bei o_bit=1 Type-4 GID-IE mit `m=1, elem_id=0b0111(4),
length=6+32*n(11), num=n(6)`, danach n Records `atd(1) + lifetime(2) +
class(3) + addr_type(2) + gssi(24)`, dann `trailing_m=0`.

**Bekannte Tests:**
- `sw/test_grpack_body.c` — Host-side.
 - TC1: 1-record GSSI=0x2F4D64 cls=4 lt=1 → 62 bit, expected
 `B3 70 4C 09 81 7A 6B 20` (Ref GS#1).
 - TC2: 1-record GSSI=0x000002 → 62 bit, `B3 70 4C 09 80 00 00 10`.
 - TC3: 2-record (attach+detach) → 94 bit, first 4 bytes `B3 70 8C 11`.
 - TC4: 3-record GSSI=0x111111/0x222222/0x333333 → 126 bit, first 3
 bytes `B3 70 CC`.
 - TC5: 0-record → 8 bit, `0xB0`.

---

### sw/tetra_call_fsm.c (445 Zeilen, Stand 2026-05-17)

**Zweck:**
Per-SSI Group-Call State Machine. Dispatcht UL-CMCE-PDUs auf DL-Replies
via `tetra_tx_submit()`, hält pro Slot Call-State, treibt VOICE_ACTIVE_MASK
Lifecycle inkl. Watchdog. MVP-Implementierung, evolviert nach Phase 7 G.7+G.8.

**Aufrufer:**
- `sw/tetra_attach_daemon.c`: `tetra_call_fsm_handle(&hal, cmce_ssi, &p)`
 nach jedem CRC-OK CMCE-PDU. Zusätzlich `tetra_call_fsm_tick(&hal)` im
 Daemon-Mainloop (~10 ms cadence) für den VOICE_ACTIVE_MASK-Watchdog.

**Wichtige Funktionen:**
- `find_slot(ssi)` / `alloc_slot(ssi)` / `free_slot(s)` — `g_slots[8]`.
- `mask_write_cached(hal, v)` — schreibt `REG_VOICE_ACTIVE_MASK (0x1EC)`
 nur wenn sich der Wert geändert hat (vermeidet AXI-Spam).
- `nsnr_step_bs(s)` — BS-side NS toggle pro emittiertem BL-ADATA-Frame.
- `stage_d_call_proceeding`, `stage_d_setup`, `stage_d_connect`,
 `stage_d_tx_granted`, `stage_d_release` — bauen je eine `tx_pdu_meta_t`
 und rufen `tetra_tx_submit(hal, TX_D_*, &m)` auf.
- `tetra_call_fsm_handle(hal, ssi, *p)` — Dispatcher:
 - `CMCE_U_SETUP`: alloc slot wenn neu. Phase 7 G.8 unterscheidet
   **Group-** vs **Individual-Call** anhand `called_party_type_ssi`
   im U-SETUP — `group_gssi` ODER `target_issi` wird gesetzt
   (mutually exclusive). Dann **3× D-CONNECT** in Folge (Phase 7 G.7),
   anschließend **1× D-SETUP** an `group_gssi` für Group-Call (oder
   `target_issi` für Individual). `tetra_voice_filler_clear()` +
   `REG_VOICE_ACTIVE_MASK = 0x02`, state=CONNECTED.
 - `CMCE_U_TX_DEMAND`: NS toggle, `stage_d_tx_granted`,
   `REG_VOICE_ACTIVE_MASK = 0x02` (re-key falls Watchdog 0 gesetzt
   hatte), state=TALKER.
 - `CMCE_U_TX_CEASED`: state→CONNECTED, broadcast D-TX-CEASED an
   Group-GSSI bzw. ISSI für Individual.
 - `CMCE_U_RELEASE`: NS toggle, `stage_d_release` mit MS-cause,
   `tetra_voice_filler_clear()`, `REG_VOICE_ACTIVE_MASK = 0x00`,
   `free_slot`.
- `tetra_call_fsm_tick(hal)` — pro Daemon-Mainloop-Iteration aufgerufen:
 - Liest `REG_VOICE_NUB_RX_CNT` (0x260), trackt `nub_quiet_ms` seit
   letztem Increment.
 - Iteriert alle aktiven Slots, ruft pro Slot `tetra_voice_pipe_tick`
   für den richtigen Voice-Target (gssi oder issi).
 - Refresht `last_activity_poll_cnt` bei jedem NUB-Bump.
 - 1 Hz Heartbeat-Log mit `slot/ssi/state/mask/nub_cnt/quiet_ms/age_ms`
   (für PTT-Diagnose).
 - **3 Wege zu `mask=0`:** (a) `active == 0` (kein Slot mehr), (b)
   `nub_quiet_ms > VOICE_QUIET_MS` (Channel-off-Watchdog), (c) Slot-Stale
   `age > CALL_STALE_MS` triggert `free_slot` + voice_filler_clear.
 - Jeder mask→0-Transition wird mit Reason geloggt (WATCHDOG-Zeile).
- `tetra_call_fsm_dump()` — Diagnose-Print aller Slots auf stderr.

**Konstanten** (header `tetra_call_fsm.h`):
- `CALL_FSM_MAX_CALLS = 8`.
- `CALL_FSM_VOICE_QUIET_MS = 300u` — nach 300 ms NUB-Stille → mask=0
 (DL-Channel dicht). Toleriert ~5 verlorene Bursts in Folge. Vorgeschichte:
 erst 500 (commit `00228e7`), dann 200 (`cccf4a9`), seit `326439d` 300 als
 sweet-spot zwischen Müll-Reduktion und Robustheit gegen Single-Gap-Cuts.
- `CALL_FSM_CALL_STALE_MS = 5000u` — nach 5 s kein NUB → Slot freigeben
 (MS power-cycle / RF-Drop ohne U-RELEASE). Lang genug für Re-Key ohne
 neuen U-SETUP-Roundtrip.
- States: `IDLE=0, CONNECTING=1, CONNECTED=2, TALKER=3, RELEASING=4`.

**Auffälligkeiten / aktuelle Bugs:**
- D-CONNECT-Retransmit-Rate auf Air: 3/10 PTTs (= 30 %) erleben
 MS-Retransmit weil erstes U-SETUP nicht rechtzeitig ge-ACKed wurde
 (worst gemessen 3.6 s PTT-bis-Audio). Liegt vermutlich im
 DL-PDU-Builder oder AACH-Scheduling, nicht im FSM hier. Siehe Ch 12.
- HB-Logs sind verbose (1 Hz pro aktivem Slot) — nützlich für Live-PTT-
 Diagnose, sollten aber bei stable PTT-Pfad evtl. via Debug-Flag
 gedrosselt werden.

---

### sw/tetra_voice_filler.c + .h (158 + 37 Zeilen, Phase 7 G.8)

**Zweck:**
DL-Voice-Slot-Filler-Initialinstallation. Encodet einmalig eine MAC-RESOURCE
NULL-PDU adressiert an die Group-GSSI als SCH/F type-5 Burst (432 Bits) und
schreibt sie in die `REG_VOICE_FILLER_*`-Mailbox. MS sieht damit auf dem
Voice-Slot kontinuierlich eine valid-CRC-Group-Allocation-Burst, was dem
0x32CB-AACH-Voice-Marker entspricht und PTT-Stabilität sichert.

**Funktionen:**
- `tetra_voice_filler_install(hal, group_gssi)` — baut PDU via
 `build_mac_resource_null_pdu`, encodet mit `tetra_codec_schf_encode`
 (CRC+conv+interleave+scramble), packt 432 Bits in 14 Worte LSB-first,
 schreibt 0x270 INDEX + 0x274 DATA pro Wort, dann W14[0]=1 (filler_valid),
 plus 0x278 GO-Puls.
- `tetra_voice_filler_clear(hal)` — schreibt W14[0]=0, deaktiviert Filler-
 Auswahl im RTL-Dispatcher.

**Aufrufer:**
- `tetra_call_fsm.c::tetra_call_fsm_handle` ruft `_clear` auf bei
 U-SETUP-Start (vor mask=0x02), U-RELEASE, und im Watchdog-Slot-Free-Pfad.
- `_install` aktuell nicht im FSM aufgerufen — Filler wird **per voice-
 pipe-tick** kontinuierlich überschrieben mit echten Re-Encoded-Voice-Frames
 (siehe nächste Sektion). `_install` ist als Fallback-/Setup-Helper
 erhalten.

**SCH/F-Encoder-Chain:**
- `build_mac_resource_null_pdu`: PDU-Type=0 (MAC-RESOURCE), LengthInd=62
 (NULL-PDU), AddrType=001 (SSI), 24-bit Group-GSSI, alle Optional-Flags=0.
- `tetra_codec_schf_encode`: CRC16 + RCPC + 24×18 block-interleave + scramble
 mit Cell-spezifischem LFSR-Init `{MCC,MNC,CC,2'b11}`.

---

### sw/tetra_voice_pipe.c + .h (153 + 34 Zeilen, Phase 7 G.8 + Phase B)

**Zweck:**
UL→DL Voice-Bit-Pipeline. Pro UL-NUB-Burst (verfügbar via
`REG_VOICE_NUB_READ_STATUS=1`) liest 432 type-5 Bits aus der Read-Mailbox
(0x280/0x284), läuft den vollen ETSI TCH/S Decode (descramble + block-
deinterleave + depuncture + Viterbi + CRC → 274-bit ACELP), patcht keinen
SSI mehr (Voice-ACELP hat keinen MAC-Header), re-encodet auf 432 type-5
Bits und schreibt in die Voice-Filler-Mailbox (0x270 INDEX, 0x274 DATA,
0x278 GO).

**Funktionen:**
- `tetra_voice_pipe_tick(hal, target_ssi)` — eine Pipeline-Iteration.
 Returns 0 wenn kein Burst pending, 0 sonst.
 - `target_ssi` ist im Code aktuell ungenutzt (`(void)target_ssi`) — der
   Decode/Encode-Roundtrip ändert die ACELP-Payload nicht, nur die
   Bit-Genauigkeit (FEC räumt UL-Bitfehler auf). Adress-Patching wird in
   späterer Phase relevant wenn Voice-Header eingeführt wird.
- Selftest bei erstem Aufruf: `encode → decode silence` → `bfi=0, diff_bits=0`
 wird einmalig auf stderr geloggt (Sanity-Check des Codec-Wrappers).

**Logging (2026-05-17 instrumentation):**
- Alle 8 Bursts (~0.5 s bei 16/s) eine Zeile:
 `voice_pipe: t=<mono_ms>ms bursts=N bfi_fail=M (= P%)`.
- Timestamp via `clock_gettime(CLOCK_MONOTONIC)` — zur Korrelation mit
 ul_mon-Wall-Time bei PTT-Delay-Messungen.

**Bit-Order:**
- RTL `coded_bits_sys[431] = first BKN1 bit on air`. Mailbox kopiert
 LSB-first pro Wort. SW `read_nub_bits` macht **bit-reverse**:
 `type5[431 - (base + b)] = (word >> b) & 1`, so dass `type5[0]` =
 first-on-air für den BS-Codec.
- Symmetrisch in `write_filler_mailbox`: `gild_buf[dst] = type5[431-i]`
 etc. Beide Pfade haben dasselbe Konvention.

**Aufrufer:**
- `tetra_call_fsm.c::tetra_call_fsm_tick` ruft pro aktivem Slot
 `tetra_voice_pipe_tick(hal, voice_tgt)` mit `voice_tgt = group_gssi || target_issi`.

**Auffälligkeiten:**
- Pipeline ist rein burst-getriggert (kein eigener Timer). Bei Idle UL
 macht `_tick` einfach Early-Return, keine Last.
- BFI-Rate aktuell ~3-7 % unter normalen Bedingungen (Survey 2026-05-17,
 thresh=11, fast_attack AGC).

---

### sw/tetra_bs_tch_s.c + .h (433 + 34 Zeilen) — TCH/S Channel-Codec Wrapper

**Zweck:**
Wrapper um die ETSI-tetra-kit TCH/S Channel-Codec-Sources, damit die
BS lokal in SW dekodieren + re-encoden kann. Architektur: BS macht
full Channel-Decode (FEC + Viterbi + CRC) → ACELP-Payload-Bits → re-encode,
**kein passthrough**. Damit werden UL-Bitfehler über die FEC korrigiert
bevor sie in DL gehen.

**Funktionen:**
- `tetra_bs_tch_s_decode(type5_432, scramb_init, out_acelp_274)` —
 returns BFI flag (1 = bad frame).
- `tetra_bs_tch_s_encode(acelp_274, scramb_init, out_type5_432)`.

**Input-Format des Decoders:** ±127 SOFT bits (0→+127, 1→−127), NICHT
hart 0/1. Im voice_pipe wird der direkt zugeführte type-5-Stream
intern in soft konvertiert.

**Backing:**
- `sw/tetra_etsi_tch_s.{c,h}` (95 + 42) — inner wrapper über die ETSI-
 Sources: scramble + block-interleave 24×18 + Channel_Encoding/Decoding.
- `sw/tetra_tch_s_codec.{c,h}` (183 + 86) — outer layer (block-interleave +
 scramble).
- `sw/etsi_codec/` — lokal kopierte ETSI tetra-kit Channel-Codec-Sources
 (`ccod_tet.c` encoder, `cdec_tet.c` decoder, `sub_cc.c` + `sub_cd.c`
 sub-functions, `arrays.tab` + `const.tab` Tables, `arrays_globals.c` für
 non-const globals damit sub_cc.c + sub_cd.c zusammen linken).

**Refactoring-Hinweise:**
- `arrays.tab` const tables sind als `static const` (file-local) deklariert
 damit duplicate-safe linking funktioniert.
- `sub_cd.c` hat duplicate `Combination`-Funktion entfernt (nutzt jetzt
 `sub_cc.c`-Version).
- Makefile linkt zusätzlichen include-Pfad `-Ietsi_codec`.

---

## Section 3 — Infrastructure

### sw/tetra_hal.c + sw/tetra_hal.h — AXI Access Layer + SYSINFO Encoder

`tetra_hal.h` definiert die gesamte AXI-Lite Register-Map (Base 0x43C00000,
Size 0x1000) als `#define REG_*` Symbole mit Offsets. Inline-Funktionen:
- `tetra_reg_read(hal, offset) → hal->regs[offset/4]`
- `tetra_reg_write(hal, offset, value) → hal->regs[offset/4] = value`

`tetra_hal.c` liefert in Library-Form (verlinkt mit allen 3 Userspace-
Binaries):
- `tetra_hal_init(*hal)` / `tetra_hal_close(*hal)` — `/dev/mem` mmap.
 (NB: `tetra_attach_daemon.c` und `tetra_ul_mon.c` definieren EIGENE
 Stubs mit gleicher Signatur, weil `tetra_hal.c` ein eigenes `main()`
 trägt und nicht direkt mitgelinkt werden kann.)
- Kanalcodierung-Primitives: `tetra_crc16, tetra_rcpc_encode,
 tetra_interleave, tetra_scramble`.
- High-Level-Funktionen: `tetra_write_sysinfo, tetra_write_bnch,
 tetra_write_cell_config, tetra_write_null_pdu, tetra_write_schedule,
 tetra_tx_tdma_load, tetra_enable, tetra_print_status`.
- Plus `main()` mit `getopt_long` Boot-CLI (siehe Section 1 oben).

**Nutzer:**
- `tetra_sysinfo` binary = `tetra_hal.c` allein gegen Cross-gcc.
- `tetra_ul_mon` binary = `tetra_ul_mon.c` allein (nutzt nur Header-
 Inline-Functions).
- `tetra_attach_daemon` binary linkt `tetra_attach_daemon.c +
 tetra_db.c + tetra_tx_transport.c + tetra_grpack_body.c +
 tetra_cmce_body.c + tetra_cmce_parser.c + tetra_call_fsm.c`.

---

### sw/tetra_char_dev.c (508 Zeilen) — Linux Kernel Module

**Zweck:** Linux platform-driver kernel module fuer `/dev/tetra`. Stellt
userspace-API ueber `read/write/ioctl` bereit.

**Build:** `make module` ueber `KERNEL_SRC` Makefile (NB: nutzt
`obj-m += tetra_char_dev.o` als externes Modul).

**API:**
- `/dev/tetra` Char-Device mit Major dynamisch alloziert
 (`alloc_chrdev_region`), Klasse `tetra_class` (`class_create`).
- Read: dumpt Register 0..28 (offset 0x00..0x1C) als `"OFFSET: 0xVALUE\n"`.
- Write: parst `"%x %x"` Eingabe → schreibt 32-bit-Wert in Register.
 Offset muss 4-byte-aligned und ≤ `TETRA_REG_SYNC = 0x0018` sein
 (Zeile 258).
- IOCTLs (Magic `'T'`):
 - `TETRA_IOCTL_GET_STATUS` (0x01) — STATUS Register lesen.
 - `TETRA_IOCTL_SET_CTRL` (0x02) — CTRL Register schreiben.
 - `TETRA_IOCTL_GET_VERSION` (0x03) — VERSION lesen.
 - `TETRA_IOCTL_START_RX` (0x04) — CTRL |= RX_ENABLE.
 - `TETRA_IOCTL_STOP_RX` (0x05) — CTRL &= ~RX_ENABLE.

**Device Tree:**
- Compatible: `"midnightblue,tetra-phy"`.
- Erwartete DT-Node (aus `make dt-node`):
 ```
 tetra_phy: tetra-phy@40000000 {
 compatible = "midnightblue,tetra-phy";
 reg = <0x40000000 0x10000>;
 status = "okay";
 };
 ```

**Auffaelligkeiten:**
- Verwendet einen eigenen Register-Symbol-Satz `TETRA_REG_VERSION=0x0000,
 TETRA_REG_STATUS=0x0004, …, TETRA_REG_SYNC=0x0018`, nicht den
 vollständigen Map aus `tetra_hal.h`.
- Code-Bug: Zeile 59 `#define TETRA_STATUS_FRAME-valid (1 << 3)` — der
 Bindestrich macht den Identifier ungültig (compile error wenn das
 Makro tatsächlich verwendet würde). Wird im Rest der Datei nicht
 referenziert.
- Nicht in `deploy.sh --init` integriert. Kein `insmod tetra_char_dev.ko`
 Aufruf im sichtbaren Init-Pfad. Userspace-Pfad geht aktuell über
 `/dev/mem` mmap (Section 1).
- `make load` / `make unload` als Convenience-Targets vorhanden, aber
 Modul-Build setzt `KERNEL_SRC` voraus.

---

### sw/tetra_db.c + sw/tetra_db.h (275 + 94 Zeilen) — Subscriber DB

**Zweck:** SW-resident Entity-DB (ISSI/GSSI mit Profile-ID). Single-
threaded, file-backed mit atomic Persistenz.

**Storage:**
- `static struct g_db` (Zeile 36-43, file-static):
 - `entries[256]`, `slot_used[256]` — `TETRA_DB_MAX_ENTRIES = 256`.
 - `profiles[6]` — `TETRA_DB_MAX_PROFILES = 6`.
 - `path[256]`, `mtime`, `num_entries`.
- Profile-Format `tetra_db_profile_t` (Header Zeile 41-49) dekodiert das
 32-bit ProfileTable-Record:
 - `[11:9] gila_class`, `[8:7] gila_lifetime`, `[3] permit_voice`,
 `[2] permit_data`, `[1] permit_reg`, `[0] valid`.
- Profile 0 Reset-Default: `0x0000_088F` = gila_class=4, gila_lifetime=1,
 alle permits=1, valid=1 (Konstante `DB_PROFILE0_BITS`, Zeile 34).
- Profiles 1..5 starten als 0 (invalid).

**API:**
- `tetra_db_load(path)` — File parsen, `path` für Reload merken.
 Missing-File = empty DB (0 returned).
- `tetra_db_reload()` — stat mtime, re-read wenn geändert. Returns 1
 re-loaded, 0 unchanged, -1 error.
- `tetra_db_lookup(entity_id, entity_type, *out)` — linearer Scan ueber
 256 Slots.
- `tetra_db_alloc(entity_id, entity_type, profile_id)` — erste freie
 Slot belegen, atomic-write TSV (`fopen tmp + fflush + fsync + rename`).
 Bei Save-Failure roll-back im RAM.
- `tetra_db_profile(profile_id)` — Pointer auf Profile-Record.
- `tetra_db_count(entity_type)` — Anzahl Slots mit passendem Type.
- `tetra_db_iterate_type(*cursor, entity_type, *out)` — Iterator.

**TSV-Format** (`/root/db.tsv`, `TETRA_DB_DEFAULT_PATH`):
- 4 Spalten whitespace-separiert: `slot entity_id entity_type profile_id`.
- `'#'`-Comments und Leerzeilen ignoriert.
- Header `# tetra entity DB (Phase X.3, SW-managed)` wird beim Save
 emitted.

**Default-File (`sw/db.tsv.default`)** wird via `deploy.sh --init` nach
`/root/db.tsv` kopiert, falls fehlend:
- Slot 0: `2633617 0 0` = ISSI 0x282F91 (MTP3550), Profile 0.
- Slot 1: `3100001 1 0` = GSSI 0x2F4D61 (Default-Group), Profile 0.

**Nutzer:**
- `sw/tetra_attach_daemon.c` (load/lookup/alloc/profile/reload).
- `sw/web/cgi-bin/entities.cgi` (liest und schreibt `/root/db.tsv`
 direkt mit shell-tools, nicht über die C-API — Daemon picks up via
 mtime-poll).

---

### sw/tetra_tx_transport.c + sw/tetra_tx_transport.h (264 + 98 Zeilen)

**Zweck:** Single-submit API für alle DL-Signalling-PDUs. Bündelt
Reply-Mailbox-Staging (legacy mm=2 dloc-Path + raw_mode_flag=1 für
mm=11 GRP-ACK und CMCE PDUs).

**API:**
- `tetra_tx_submit(hal, cls, *meta) → int` (Zeile 237-264). Dispatcht
 nach `tx_pdu_class_t`:
 - `TX_LU_ACCEPT` → `submit_lu(hal, meta, 0u)` (mm=2 ACCEPT, dloc-
 encoder im RTL).
 - `TX_LU_REJECT` → `submit_lu(hal, meta, meta->result ?: 1u)` (mm=4
 REJECT, GILA fields auf 0 gezwungen).
 - `TX_GRP_ATTACH_ACK` → `submit_grp_ack(hal, meta)`.
 - `TX_D_SETUP / D_CALL_PROCEEDING / D_CONNECT / D_TX_GRANTED /
 D_TX_CEASED / D_RELEASE` → `submit_cmce_pdu(hal, meta, builder)`.

**Reply-Mailbox-Layout** (per `tetra_hal.h` Zeile 256-274):
- `REG_REPLY_INDEX (0x220)` — word selector W0..W15.
- `REG_REPLY_DATA (0x224)` — indirect data.
- `REG_REPLY_GO (0x228)` — W1S Pulse zur MLE-FSM.
- `REG_REPLY_STATUS (0x22C)` — busy-Mirror (Bit 0).
- `REG_REPLY_USE_SW (0x230)` — Field-Mux Enable.

**`reply_wait_idle(hal)`** (Zeile 52-64): Spin-Wait auf `REG_REPLY_STATUS
& 0x1 == 0`, max 50 ms in 200 µs Schritten. Returns -1 bei Timeout.
Wird vor jedem GO-Pulse aufgerufen (Mailbox ist single-slot).

**`submit_lu(hal, meta, result)`** (Zeile 78-111):
- Falls REJECT (result!=0): GILA-Felder genullt.
- Schreibt W0..W13:
 - W0 = ssi (24 bit)
 - W1 = la (14 bit)
 - W2 = `0x1` (addr_type = Ssi+EventLabel)
 - W3 = result (0..2)
 - W4 = gila_gssi (24 bit)
 - W5 = `(gila_class << 2) | gila_lifetime`
 - W6 = gila_present
 - W7 = encryption (2 bit)
 - W8 = auth_result (1 wenn 0, sonst masked)
 - W9..W13 = 0 (raw_mode_flag cleared)
- `REG_REPLY_GO = 1`, `usleep(200)`.

**`stage_raw_mm(hal, ssi, bytes, len, ns, nr, mle_pd)`** (Zeile 147-195):
- Repackt MSB-first bytes nach `raw_mm_bits[127:0]` mit Bit 0 → `[127]`.
- W9 = `(1<<31) | (mle_pd << 10) | (nr<<9) | (ns<<8) | (len & 0xFF)`.
- W10..W13 = repackte raw_mm_bits Bündel.
- `MLE_PD_DEFAULT_MM=0, MLE_PD_MM=1, MLE_PD_CMCE=2`.
- `REG_REPLY_GO = 1`, `usleep(200)`.

**`submit_grp_ack(hal, meta)`** (Zeile 197-220):
- Baut grpack_meta aus tx_pdu_meta_t, ruft `tetra_grpack_build()`, dann
 `stage_raw_mm(..., MLE_PD_MM)`.

**`submit_cmce_pdu(hal, meta, builder)`** (Zeile 226-235):
- Ruft `builder(&m->cmce, mm_bytes)`, dann `stage_raw_mm(...,
 MLE_PD_CMCE)`.

**`tx_pdu_meta_t` Struct** (Header Zeile 53-85): Common (target_ssi) +
mm=1/4 Felder (la, result, gila_*) + mm=11 Felder (reply_count, gssi[3],
at[3], lifetime[3], adi[3], cls[3], accept_reject) + LLC (ns, nr) +
embedded `cmce_meta_t cmce` + Z.2-Future-Fields (slot_class, aach_pattern,
beide default 0).

**Puffer-Größe:** Reply-Mailbox-Window fest 14 Wörter (W0..W13). MM-Body
max 128 bit = 4 Wörter via W10..W13. `TETRA_CMCE_MAX_BYTES = 32`,
`TETRA_GRPACK_MAX_BYTES = 16`.

---

## Section 4 — Header-Only / Config

### sw/tetra_pdu_class.h (86 Zeilen)

SW-side mirror von `rtl/include/tetra_pdu_class.vh`. Konstanten:
- **Slot-Formate** (`PDUC_SLOTFMT_SCH_F=0, PDUC_SLOTFMT_SCH_HD=1`).
- **AACH-Patterns** (`PDUC_AACH_SIGNALLING_ACTIVE=0x0009,
 PDUC_AACH_IDLE=0x0249`).
- **Address-Type** (`PDUC_ADDRTYPE_SSI=1`).
- **LLC-Typen** (`PDUC_LLC_BL_ADATA=0, BL_UDATA=1, BL_ACK=2,
 AL_SETUP=8`).
- **PDU-Klassen** als Tupel von `(_FMT, _AACH, _ADDRTYPE, _LLC, _RA)`:
 - `PDUC_PRE_REPLY_SLOTGRANT_*` — SCH/HD, signalling, AL_SETUP, RA=1.
 - `PDUC_FINAL_LU_ACCEPT_*` — SCH/F, signalling, BL_ADATA, RA=0.
 - `PDUC_FINAL_LU_REJECT_*` — SCH/HD, signalling, BL_ADATA, RA=0.
 - `PDUC_GROUP_ACK_*` — SCH/F, signalling, BL_ADATA, RA=0.
 - `PDUC_BL_ACK_POST_FRAG2_*` — SCH/HD, idle 0x0249, BL_ACK, RA=0.
 - `PDUC_NWRK_BCAST_*` — SCH/F, idle 0x0249, BL_UDATA, RA=0.

Hard rule (Zeile 9-11): "every value here MUST match its `localparam`
counterpart in the RTL header byte-for-byte".

Aktuell wird **kein** dieser Symbole irgendwo in `sw/*.c` aktiv
referenziert — der Header ist eine SW-side Mirror-Referenz für den
Architektur-Lock, kein aktiv genutztes API. (`grep PDUC_ sw/*.c` =
leer.)

---

### sw/tetra_schedule_table.h (158 Zeilen)

Auto-generated von `scripts/schedule.py --emit-c-header`. Definiert
`static const uint32_t tetra_schedule_table[144]` — die 144 32-bit Wörter
fuer das Schedule-BRAM (`REG_SCHEDULE_BASE = 0x400`).

Layout:
- 144 Wörter à 2 × 16-bit Einträge = 288 Slots pro Hyperframe.
- Dense-Index = `mn*72 + fn*4 + tn`.
- Wert pro Eintrag ist ein 16-bit PDU-Class-Code (`0x00d6, 0x100c`, …).

Verwendet von `tetra_write_schedule(hal)` in `tetra_hal.c` Zeile
1250 (kopiert die 144 Wörter sequenziell ins Schedule-BRAM).

Wert-Verteilung (sichtbar im Header): wechselt sich `0x00d6100c` /
`0x00d600d6` ab. Bei `word 105/106` sieht man eine kleine Abweichung
(`0x00d600d6` an Stelle des erwarteten `0x00d6100c` — vermutlich BNCH-
F18-Sonderfall). Hier nur dokumentarisch erwähnt; Bedeutung der 16-bit
Codes lebt im RTL `tetra_pdu_class.vh`.

---

## Section 5 — WebUI

### Layout

Zwei separate Web-Roots im Repo:
- `sw/www/` — älteres Layout, deploy.sh kopiert NICHT.
- `sw/web/` — aktives Layout, vermutlich auf Board `/www/` deployed.

Beide enthalten `apply.cgi / status.cgi / stop.cgi`. Die Dateien in
`sw/web/` und `sw/www/cgi-bin/` sind ca. 95% identisch — unklar aus Code,
welche Version aktuell aktiv ist; `scripts/deploy.sh` Zeile ~270-280
suggeriert, dass `sw/web/index.html` und `sw/web/cgi-bin/*.cgi` nach
`/www/` deployed werden.

### sw/web/apply.cgi (120 Zeilen, shell)

**Trigger:** WebUI POST/GET → `?freq=…&mcc=…&…`.

**Aktion:**
1. Parst `$QUERY_STRING` nach k=v (`tr '&' '\n'`, `cut -d=`, sanitize
 regex `[a-zA-Z0-9._-]`).
2. Defaults setzen (`freq=438250000`, `mcc=901`, `mnc=9998`, `la=1`,
 `cc=49`, `tx_atten=-10`, `system_code=2`, `duplex_spacing=1`,
 `ms_txpwr=6`, `rxlevel_min=0`, `access_param=10`,
 `radio_dl_timeout=5`, `opt_field=1011456`, `priority_cell=0`,
 `migration=0`, `ncb=3`, `csl=0`).
3. Speichert config nach `/tmp/tetra_cell.conf`.
4. `killall tetra_sysinfo`, `sleep 0.3`.
5. Setzt AD9361 IIO sysfs:
 - `echo $freq > /sys/bus/iio/devices/iio:device1/out_altvoltage1_TX_LO_frequency`
 - RX-Freq berechnet aus `duplex_spacing` (case 0→-10MHz, 1→-7.6MHz,
 3→-10MHz, 4→+10MHz, 7→same; default -10MHz), oder direkt aus
 `ul_freq`-form-field wenn angegeben.
 - `out_altvoltage0_RX_LO_frequency = $rx_freq`.
 - `out_voltage0_hardwaregain = "$tx_atten"` (mit `printf "%f"`).
6. `nohup /root/tetra_sysinfo --freq … --daemon > /tmp/tetra_sysinfo.log
 2>&1 &`.
7. `sleep 1`, check `pidof tetra_sysinfo`, gib Status zurück.

**Output:** `text/plain` Status-Text.

### sw/web/status.cgi (38 Zeilen)

**Modi:**
- `?brief=1` → wenn `tetra_sysinfo` läuft: `tetra_sysinfo --status |
 grep "CTRL:"`. Sonst `TX=0 RX=0`.
- Default: Mehrzeiliger Status (PID, AD9361 IIO sysfs Reads, PHY
 Register via `tetra_sysinfo --status`, letzte 10 Zeilen aus
 `/tmp/tetra_sysinfo.log`).

### sw/web/stop.cgi (13 Zeilen)

`killall tetra_sysinfo`, sleep 0.3, check ob noch lebt, Status.

### sw/web/cgi-bin/policy.cgi (115 Zeilen)

**REG:** `REG_DB_POLICY @ 0x43C001AC`.

**Verhalten:**
- GET → `busybox devmem 0x43C001AC 32` lesen, return JSON
 `{"ok":true,"accept_unknown_issi":<bit0>,"accept_unknown_gssi":<bit1>}`.
- POST `op=set [accept_unknown_issi=0|1] [accept_unknown_gssi=0|1]`:
 - Read-Modify-Write nur der angegebenen Bits.
 - Legacy-Compat: `accept_unknown=…` mappt auf Bit 0.
 - `busybox devmem 0x43C001AC 32 $NEW`.
 - Readback und return als JSON.
- Sanitize Eingabe-Regex `[a-zA-Z0-9._-]`, 0 oder 1 validiert.
- Reset-Value 0x3 = beide Bits 1 (M2-kompatibel).

### sw/web/cgi-bin/entities.cgi (223 Zeilen)

**Source-of-truth:** `/root/db.tsv` (Daemon-pickup via mtime-poll).

**Verhalten:**
- GET → liest `/root/db.tsv` via `awk` filter (skip `#` und blank,
 validate `^[0-9]+$` für alle 4 Felder), emittiert JSON-Array:
 ```
 [{"slot":N,"entity_id":M,"entity_type":T,"profile_id":P,"valid":1},...]
 ```
- POST `op=add slot=N? entity_id=M entity_type=T profile_id=P`:
 - Validiert: entity_id ≤ 16777215, entity_type ∈ {0,1}, profile_id ∈
 {0..5}.
 - Wenn slot leer: `next_free_slot()` ueber Bereich 0..255.
 - Schreibt `/tmp/db.tsv.NEW` mit Header + alten Zeilen (minus
 überschriebener slot) + neue Zeile → `mv` nach `/root/db.tsv`.
 - Return `{"ok":true,"slot":N}`.
- POST `op=del slot=N`:
 - Schreibt `/tmp/db.tsv.NEW` mit allen Zeilen außer der für `slot=N`.
 - `mv` nach `/root/db.tsv`.
 - Return `{"ok":true}`.
- Sanitize: `[a-zA-Z0-9._-]` regex per Feld.

### sw/web/cgi-bin/sessions.cgi (101 Zeilen)

**AXI-Reads** (alle ueber `busybox devmem 0xADDR 32`):
- `0x43C00190` — `{accept[31:16], ul_req[15:0]}`
- `0x43C00194` — `{busy_sticky[16], drop[15:0]}`
- `0x43C00198` — `{clear[31:16], sig_override[15:0]}`
- `0x43C001AC` — Policy-Bits {accept_unknown_gssi[1], accept_unknown_issi[0]}
- `0x43C00168` — REG_UL_PDU_SSI (last MTP3550 mailbox ISSI)
- `0x43C001E0` — REG_REASSEMBLY_STATS {drop[31:16], reassembled[15:0]}
- `0x43C001E4` — REG_NWRK_BCAST_CNT [15:0]
- `0x43C00200` — REG_DEMAND_STATUS {drop_cnt[31:16], pending[0]}
- `0x43C00230` — REG_REPLY_USE_SW [0]

**Sonstige Inputs:**
- `/root/db.tsv` → zählt valid rows split nach entity_type (issi_cnt,
 gssi_cnt, total) per awk.
- `/tmp/tetra_ul_mon.log` → letzte 20 Zeilen als JSON-String-Array.

**Output:** Single-line JSON `{counters, last_issi, last_issi_hex,
policy_*, demand_pending, reply_use_sw, db:{...}, recent_ul_mon:[...]}`.

### sw/www/cgi-bin/apply.cgi (117 Zeilen)

Funktional fast identisch zu `sw/web/apply.cgi`. Unterschiede:
- duplex_spacing-Default = 0 (statt 1).
- RX-Freq-case-Statement nutzt andere Offsets (0→-10, 1→-7, 3→-8, 4→-5,
 5→-9.5, default→-10), KEIN `ul_freq`-Override-Pfad.
- Sonst identisch.

### sw/www/cgi-bin/status.cgi (38 Zeilen)

Identisch zu `sw/web/status.cgi`.

### sw/www/cgi-bin/stop.cgi (13 Zeilen)

Identisch zu `sw/web/stop.cgi`.

---

## Section 6 — Build

### sw/Makefile (112 Zeilen)

**Cross-Compile-Variablen:**
- `ARCH = arm`
- `CROSS_COMPILE = arm-linux-gnueabihf-`
- `CC = $(CROSS_COMPILE)gcc`
- `CFLAGS = -Wall -Wextra -O2 -march=armv7-a -static`

**Targets:**

- `all` → baut `tetra_sysinfo tetra_ul_mon tetra_attach_daemon`.

- `tetra_sysinfo`: kompiliert `tetra_hal.c` alleine
 (`$(CC) $(CFLAGS) -o $@ $<`).

- `tetra_ul_mon`: kompiliert `tetra_ul_mon.c` alleine. Nutzt nur die
 Inline-Funktionen aus `tetra_hal.h` plus lokale `tetra_hal_init/close`
 Stubs.

- `tetra_attach_daemon`: kompiliert
 ```
 tetra_attach_daemon.c + tetra_db.c + tetra_tx_transport.c +
 tetra_grpack_body.c + tetra_cmce_body.c + tetra_cmce_parser.c +
 tetra_call_fsm.c
 ```
 in einem Aufruf.

- Host-side Tests (gebaut mit System-`gcc`, NICHT mit Cross):
 - `test_grpack`: `gcc -Wall -Werror -O2 -o /tmp/test_grpack
 test_grpack_body.c tetra_grpack_body.c`.
 - `test_cmce_parser`: `gcc … -o /tmp/test_cmce_parser
 test_cmce_parser.c tetra_cmce_parser.c`.
 - `test_cmce_body`: `gcc … -o /tmp/test_cmce_body test_cmce_body.c
 tetra_cmce_body.c`.
 - `make test` baut alle drei und führt sie nacheinander aus.

- `module` → baut `tetra_char_dev.ko` extern: `$(MAKE) ARCH=$(ARCH)
 CROSS_COMPILE=$(CROSS_COMPILE) -C $(KERNEL_SRC) M=$(PWD) modules`.

- `install` → `modules_install` ins Kernel-Modules-Verzeichnis.

- `clean` → entfernt Userspace-Binaries + Test-Programme +
 Module-Artefakte.

- Convenience: `load (insmod)`, `unload (rmmod)`, `info (modinfo)`,
 `dt-node` (gibt DT-Node-Template aus).

**Phony:** `all modules install clean load unload info dt-node test
test_grpack test_cmce_parser test_cmce_body`.

**Linker-Optionen:**
- `-static` (alle Userspace-Binaries werden statisch gelinkt → keine
 glibc/.so-Abhängigkeit auf dem Board nötig).
- Keine zusätzlichen `-l` Libs (Code nutzt nur libc + standard POSIX).

**ccflags-y für Kernel-Module:** `-Wall -Werror`.

---

## Anhang — Daten-Files unter sw/

- `sw/db.tsv.default` — Bootstrap-DB. Wird via `deploy.sh --init` nach
 `/root/db.tsv` kopiert, falls dort nichts liegt. Inhalt:
 ```
 0 2633617 0 0 # MTP3550 ISSI 0x282F91, Profile 0
 1 3100001 1 0 # Default-Group GSSI 0x2F4D61, Profile 0
 ```

- `sw/web/index.html` — WebUI HTML (20260 bytes). Nicht im Scope.

- `sw/www/index.html` — Legacy WebUI HTML (6584 bytes). Nicht im Scope.

- `sw/README.md` (6112 bytes), `sw/web/README.md` (2312 bytes) — Doku.

- `sw/SDRSharp.Tetra.*.resources` — vermutlich Reverse-Engineering-
 Artefakte aus SDRSharp-Plugin. Nicht im Build-Pfad.

- `sw/sim_out/` — Sim-Output-Directory, leer in der Inhaltsliste.

- Vorgebaute Binaries im Tree: `sw/tetra_attach_daemon`,
 `sw/tetra_hal`, `sw/tetra_sysinfo`, `sw/tetra_ul_mon` (alle aktuelle
 Datums-Stamps 2026-05-14). Liegen neben den `.c`-Quellen, sind das
 jeweils das Cross-Compile-Output.

---

## Restunsicherheiten

- `tetra_char_dev.c` ist im Repo, aber `deploy.sh --init` lädt das
 Modul nicht. Unklar aus Code, ob es überhaupt im Live-Betrieb genutzt
 wird oder ein toter Pfad ist.
- `sw/www/` Layout vs `sw/web/` Layout: deploy.sh deployt aus `sw/web/`
 (laesst sich aus `deploy.sh` indirekt schließen — direkt grep fand
 nur `sw/web/index.html` als source). `sw/www/` scheint historische
 Restmenge zu sein, wird aber nicht aktiv gepflegt entfernt.
- `test_cmce_body.c` TC3 (D-CONNECT 30 bit) vs aktive
 `tetra_cmce_build_d_connect()` (39 bit) Diskrepanz, siehe Section 2.
- `tetra_pdu_class.h` hat keine sichtbaren Verwender in `sw/*.c` —
 unklar aus Code, ob noch geplant oder ablegbar.
- D-NWRK-BROADCAST Network-Time-Encoding: Inline-Kommentar Zeile 1496-
 1501 in `tetra_hal.c` schreibt selbst: "'s 10-bit-Encoding scheint
 kein einfacher Zeit-Counter zu sein (Differenzen 5/10s, dann Sprung
 510→257). Wir verwenden `(utc/2) & 0x3FF` als grobe Approximation".
 Heißt: exaktes Bit-Encoding ist auch heute noch offen.
