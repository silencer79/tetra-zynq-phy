# TETRA Base Station Stack — Implementierungsplan

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Ziel:** Vollständige TETRA BS — Einbuchen, Gruppenrufe, Einzelrufe
**Erstellt:** 2026-04-17
**Zuletzt aktualisiert:** 2026-04-22

---

## Architektur-Entscheidung 2026-04-22 — FPGA-heavy Stack

MAC/MLE/CMCE-Logik (Registration, ChannelRequest, Call-Setup/TxGrant/Release,
Paging) läuft als **RTL-FSMs im FPGA**, nicht auf ARM. Response-Latenz ist damit
deterministisch innerhalb eines TDMA-Slots (14.17 ms).

**Rollenverteilung:**
- **PS (ARM)** — reine Management-Rolle:
  - Subscriber-DB (ISSI → permit-mask, LA, home-cell)
  - Group-DB (GSSI → Memberlist, service-class)
  - Admin-UI, Provisioning, Log-Aggregation
  - Schreibt DB-Einträge über AXI-Lite in einen BRAM-Shadow (Variante A)
- **FPGA (PL)** — Echtzeit-Protokoll:
  - RTL-FSMs für Registration / ChannelReq / GroupCall / Paging
  - Hot-State in BRAM: aktive Sessions (ISSI→Slot-Alloc), aktive Gruppen (GSSI→Slot/Speaker)
  - Subscriber-/Group-Shadow-BRAM für permit-Lookup (1-Cycle)
  - PDU-Encoder: MAC-RESOURCE, D-LOCATION-UPDATE-ACCEPT/REJECT, D-CONNECT, D-ALERT
- **Bestehende RTL-Mailbox** (UL MAC-ACCESS → AXI-Register 0x164…0x178) bleibt als
  Diagnose-/Logging-Pfad erhalten; der Response-Weg geht *nicht* mehr über ARM.

**DB-Transport — Variante A (gewählt):**
- ARM pusht komplette Subscriber-Table per AXI-Lite in BRAM-Shadow.
- Dimension z.B. 256 Einträge × 64 bit = 1 BRAM36 = 16 kbit.
- Lookup-Latenz 1 Cycle, ausreichend für Feldgerät #1.
- Upgrade auf AXI-HP-Read zu PS-DRAM (Variante B) bleibt offen für > 1000 MS.

Diese Entscheidung ersetzt die frühere Planung (ehemalige
`sw/tetra_mac.c`, `sw/tetra_mle.c`, `sw/tetra_cmce.c`) in den Abschnitten M2–M4.

---

## Stand 2026-04-22 (Meilenstein M1 teilweise erreicht)

- **M1.1 SYSINFO PDU:** ✅ bit-exakt gegen Gold-WAV, unabhängig von tetra-kit dekodiert
- **M1.2 ACCESS_DEFINE:** ✅ BNCH sendet echten Content (nicht Filler)
- **M1.3 AACH Access:** ✅ F1-17 CapAlloc, F18 TN=0 MN%4∈{0,1,3} Unalloc, MN%4=2
  DL/UL-Assign = Unalloc (0x0049) — matcht Gold
- **M1.7 AD9361 FDD:** ✅ Duplex=0 (10 MHz Band 4) korrekt, MS antwortet auf
  korrekter UL-Frequenz 428.250 MHz
- **MS-Verhalten:** ✅ MTP3550 sendet Random-Access-Bursts auf UL (42 Bursts
  in 34.9 s laut WAV-Analyse `baseband_428235864Hz_01-06-04_22-04-2026.wav`),
  je 127 Symbole / 7.17 ms (§9.4.4.2.1)

**Offen für M1-Abschluss:**
- **M1.4 Sync-Detect ETS_REF:** 🔴 `rtl/rx/tetra_sync_detect.v:120` hat 60-bit
  Placeholder; korrigieren auf 30-bit ETSI-`x_bits` (§9.4.4.3.3)
- **M1.5 Burst-Demux RA:** 🔴 Auf DL-NDB (BKN1=120 + BKN2=108) getunt — RA-Burst
  `RA-blk1(54) + x + RA-blk2(54)` braucht eigenen Pfad
- **M1.6 Sync-Lock für sporadische Bursts:** 🔴 Aktuelle LOCK_COUNT=4 ist
  DL-continuous — UL sendet nur sporadisch, Per-Burst-Detect nötig

**Pragmatischer Plan:** Python-Sliding-Korrelator auf die gecaptete WAV, x_bits
an Offset 56 Symbole suchen. Bestätigt x_bits in den Bursts vor RTL-Zyklus.
Details: `.ralph/fix_plan.md`.

---

## Architektur-Überblick

**Vorhanden (PHY Layer):**
- TX: SDB (SYSINFO) + NDB Filler, π/4-DQPSK, RRC, CIC → AD9361
- RX: AD9361 → CIC → RRC → Timing Recovery → Demod → Sync (STS) → Burst Demux (NDB/SDB)
- LMAC: Scrambler, Interleaver, Viterbi, CRC, Reed-Muller, RCPC Encoder (22/22 Sim PASS)
- Infra: AXI-Lite Regs, AXI-DMA Bridge (S2MM), Frame Counter, IRQ
- SW: tetra_hal.c (SYSINFO/BNCH/AACH/NDB Channel Coding)
- Zynq-7020 Auslastung: ~10% LUT, ~12% FF — viel Headroom

**Fehlt:**
- Dynamisches TX TDMA Scheduling (per-Slot Content-Mux mit Alloc-Tabellen-Lookup)
- **MAC Layer (L2) in RTL** — Registration-FSM, ChannelReq-FSM, ResourceAlloc-FSM
- **MLE/CMCE (L3) in RTL** — Location-Update-FSM, GroupCall-FSM, Paging-FSM
- DB-Shadow-BRAM + AXI-Lite-Window für Subscriber/Group-DB (Variante A)
- ARM-Subscriber/Group-DB-Service (nur DB + Admin, kein Echtzeit-Pfad)
- TETRA Voice Codec (ACELP 4.8 kbit/s) — offen, Platzierung PS vs PL noch zu prüfen

**Fertig (2026-04-22):**
- Uplink-Empfang (RA-Burst, NTS-Sync, SCH/HU-Decoder, MAC-ACCESS-Parser, AXI-Mailbox)
  — hardware-verifiziert mit MTP3550

---

## Meilensteine

```
M1: MS sieht BS, sendet RACH         ──→ "Hallo, hier bin ich"
M2: MS bucht sich ein                ──→ Location Update Complete
M3: Gruppenruf mit Sprache           ──→ PTT Voice über Gruppe
M4: Einzelrufe                       ──→ Point-to-Point Calls
```

---

## M1: MS sieht BS und sendet RACH

**Ziel:** Ein TETRA-Endgerät findet unsere BS, dekodiert SYSINFO, und sendet einen RACH (Random Access) auf dem Uplink. Wir sehen den RACH-Burst.

### M1.1 — SYSINFO PDU vervollständigen (SW, niedrig)
- **Datei:** `sw/tetra_hal.c`
- `build_sysinfo_pdu()` prüfen: `late_entry_info=1`, `cell_service_level` auf "service available", `system_code=0` (V+D), `sharing_mode=0` (continuous carrier)
- **ETSI:** EN 300 392-2 §18.4.2.1

### M1.2 — ACCESS_DEFINE PDU im BNCH (SW, mittel)
- **Datei:** `sw/tetra_hal.c`
- Aktuell sendet BNCH (bkn2) einen PN-Filler. Stattdessen echte ACCESS_DEFINE PDU:
  - `access_code`, `immediate_access`, `waiting_time`, `frame_length`
  - Sagt dem MS auf welchem Slot es RACH senden darf
- `tetra_bnch_encode()` bleibt — nur die 124 Info-Bits ändern sich
- **ETSI:** EN 300 392-2 §18.4.2.2, §21.4

### M1.3 — AACH Access Assignment korrigieren (SW, niedrig)
- **Datei:** `sw/tetra_hal.c`
- `build_aach()` muss "uplink access allowed" signalisieren
- `timeslot_assigned` Feld korrekt setzen
- **ETSI:** EN 300 392-2 §18.5.1

### M1.4 — NTS Sync-Detection für Uplink (RTL, mittel-hoch)
- **Datei:** `rtl/rx/tetra_sync_detect.v`, `rtl/tetra_zynq_top.v`
- `seq_select` von `2'd2` (STS, 19 sym) auf `2'd0` (NTS, 11 sym) für UL-RX
- NTS-Referenz ist bereits parametrisiert — nur aktivieren
- **Architekturentscheidung:** Separater UL-RX-Pfad oder shared? → Zunächst shared, seq_select umschaltbar machen
- **ETSI:** EN 300 392-2 §9.4.4.3.3

### M1.5 — Burst Demux für NUB/CUB (RTL, mittel)
- **Datei:** `rtl/rx/tetra_burst_demux.v`
- NUB (Normal Uplink Burst, 255 sym):
  `tail(6) + block1(108) + bb1(7) + NTS(11) + bb2(8) + block2(108) + tail(5) + guard(2)`
- CUB (Control Uplink Burst, 112 sym):
  `tail(10) + block1(42) + NTS(11) + block2(42) + tail(5) + guard(2)`
- CUB ist der RACH-Burst — Schlüssel für M1
- **ETSI:** EN 300 392-2 §9.4.4.2.1 (NUB), §9.4.4.2.3 (CUB)

### M1.6 — RACH-Erkennung (RTL + SW, mittel)
- Für M1 reicht: `slot_valid` Pulse auf dem Uplink erkennen = RACH-Energie sichtbar
- Vollständige CUB-Dekodierung (SCH/HU, 84 Bits) erst in M2
- **ETSI:** EN 300 392-2 §8.2.3

### M1.7 — AD9361 FDD-Konfiguration (SW, mittel)
- **Dateien:** `scripts/tetra_ctrl.sh`, `scripts/ad9361_init.sh`
- Separate TX/RX LO mit TETRA Duplex-Abstand (typ. 10 MHz im 400-MHz-Band)
- AD9361 unterstützt FDD nativ
- **Hardware:** Duplexer oder zwei Antennen (TX/RX getrennt) nötig!
- **ETSI:** EN 300 392-2 §4.4

### M1 Abhängigkeiten
```
M1.1 ─┐
M1.2 ─┼── parallel (alles SW) ──→ Deploy + Test
M1.3 ─┘
M1.4 ─┬── parallel (RTL) ──→ Vivado Build
M1.5 ─┘
M1.6 ── hängt von M1.5 ab
M1.7 ── unabhängig (RF-Setup)
```

**Aufwand:** ~2-3 Wochen

---

## M2: MS bucht sich erfolgreich ein

**Ziel:** Voller Round-Trip: MS sendet RACH → BS dekodiert → BS antwortet → MS Location Update Complete.

### M2.1 — SCH/HU Channel Decoding für UL RA-Burst (RTL) ✅ FERTIG (2026-04-22)
- UL Viterbi r=1/4 + CRC16 + Descrambler in RTL (`tetra_ul_sch_hu_decoder.v`,
  `tetra_ul_viterbi_r14.v`)
- Hardware-verifiziert, 41/42 CRC-OK gegen Python-Baseline, Live-Decode MTP3550
- **ETSI:** EN 300 392-2 §8.2.3, §9.4.4.2.3

### M2.2 — MAC Layer (L2) in RTL (hoch)
- **Neue Module:**
  - `rtl/lmac/tetra_mac_resource_encoder.v` — baut MAC-RESOURCE PDU aus Slot-Alloc
  - `rtl/lmac/tetra_mac_fragment.v` — Fragmentierung/Reassembly für L3-Transport
  - `rtl/lmac/tetra_active_session_table.v` — BRAM: ISSI → Slot-Alloc + State
- **Reuse:** `tetra_ul_mac_access_parser.v` (bereits vorhanden) als Trigger
- MAC-ACCESS empfangen → ActiveSession-Lookup → MAC-RESOURCE auf DL emittieren
- **ETSI:** EN 300 392-2 §21.1-21.4

### M2.3 — MLE (L3) in RTL: Registration (hoch)
- **Neue Module:**
  - `rtl/lmac/tetra_mle_registration_fsm.v` — FSM: RX_UREG → DB_LOOKUP → ACCEPT/REJECT → TX_DACCEPT
  - `rtl/lmac/tetra_d_location_update_encoder.v` — D-LOCATION UPDATE ACCEPT/REJECT PDU-Builder
  - `rtl/lmac/tetra_subscriber_shadow.v` — BRAM-Shadow der ARM-Subscriber-DB (permit-Bit, LA)
- **Neue ARM-SW:** `sw/tetra_db_mgr.c` — Subscriber/Group-DB-Pflege + AXI-Lite-Writes in Shadow-BRAM
- Registration ohne ARM-Hop: MS sendet U-LOCATION UPDATE DEMAND → FPGA liest permit
  aus Shadow-BRAM → FPGA encoded D-LOC-UPDATE-ACCEPT → DL-Slot nächste Frame
- **ETSI:** EN 300 392-2 §16, §14.5

### M2.4 — Per-Slot TX-Inhalt (RTL) mittel
- Aktuell: alle NDB-Slots senden denselben Filler
- **Neu:** `rtl/tx/tetra_slot_content_mux.v` — liest Alloc-Tabelle pro Slot und
  routet NULL-PDU / MAC-RESOURCE / D-LOC-UPDATE / Filler an burst_mux
- Alloc-Tabelle von Registration-FSM geschrieben (gleicher Clock-Domain)
- **ETSI:** EN 300 392-2 §21.2

### M2.5 — SYSINFO Frame Counter Update (RTL) niedrig
- Frame/Multiframe im SYSINFO laufend aktualisieren
- `tetra_zynq_top.v`: frame_counter-Output direkt in SYSINFO-Payload-Byte-Positionen
  einspeisen (nicht mehr über ARM-Polling)
- **ETSI:** EN 300 392-2 §18.4.2.1

### M2.6 — DL-Signalisierungs-Architektur (RTL, hoch) — ERSETZT dl_signal-Latch

**Motivation (2026-04-22):** Der 1-Entry-Pending-Latch in `tetra_slot_content_mux.v`
verliert Injection wenn `dl_pdu_valid` nach einem TN=1 slot_pulse feuert (Race). Unter
aktueller MLE-FSM-Latenz passiert das jedes Mal, wenn MS-RA spät im TN=3-Fenster parst.
Counter `inject_cnt` zählt nur "gute" Events, Rest wird stillschweigend verworfen. WAV
zeigt 100% NULL-PDU auf TN=1.

Gleichzeitig: spätere SAPs (CMCE/SDS/MM) brauchen eigene DL-Injection-Pfade. Statt
3× dieselbe Pending-Logik parallel → zentrale, scheduler-integrierte Lösung.

**Architektur:** Producer alloziert konkreten Ziel-Slot beim Scheduler-Allocator,
schreibt Payload in Per-Slot-Override-RAM (288 Einträge parallel zur Schedule-BRAM).
Mux liest Override + Schedule simultan pro Slot, bei `ovr_valid=1` → override_bits
statt schedule-payload + consume. Race-frei per Design (Producer zeigt auf Slot,
nicht auf "den nächsten TN=1").

**Neue Module:**
- `rtl/tx/tetra_slot_override_ram.v` — 288 × {valid, len, bkn1[215:0], bkn2[215:0]}
  Dual-Port (Write von Arbiter, Read+Consume von Mux)
- `rtl/lmac/tetra_dl_sig_allocator.v` — scannt Schedule ab `(mn,fn,tn)+1` vorwärts,
  findet ersten freien sig-tauglichen Slot (class, ndb2, enable gegen req_len geprüft),
  returned dense addr oder `full` pulse
- `rtl/lmac/tetra_dl_sig_arbiter.v` — 4 Producer-Ports (MLE, CMCE, SDS, reserve),
  fixe Priorität MLE>CMCE>SDS, serialisiert Requests an Allocator + RAM-Write

**Geänderte Module:**
- `rtl/tx/tetra_slot_content_mux.v` — Inject-Latch entfernt, Port-B-Read auf Override-RAM
  ergänzt (gleiche dense addr wie Schedule), Override-Mux in allen 4 TN-Blöcken
- `rtl/lmac/tetra_mle_registration_fsm.v` — Output raus: `dl_pdu_bits/valid`. Rein:
  Producer-Port zum Arbiter (`req_valid`, `req_len=0`, `req_bkn1[215:0]`, `busy_in`)
- `rtl/tetra_zynq_top.v` — Instanzen override_ram/allocator/arbiter + Counter/AXI-Regs
  0x1A0..0x1AC (per-SAP req_cnt, consume_cnt, alloc_full_cnt, arb_stall_cnt)

**Tests (alle TBs lokal grün vor Deploy):**
1. `tb/tb_slot_override_ram.v` — write/read/consume/clear
2. `tb/tb_dl_sig_allocator.v` — legale Slots, Skip BNCH/BSCH/SB/empty/F18-BNCH-DMO,
   full-detection, cold start
3. `tb/tb_dl_sig_arbiter.v` — Priorität, parallele Pushes, busy-handling
4. `tb/tb_slot_content_mux_override.v` — Override auf allen 4 TNs, Consume-Puls,
   keine Cross-Frame-Leaks
5. `tb/tb_mle_registration_fsm.v` angepasst — schreibt via Arbiter
6. `tb/tb_dl_sig_integration.v` — UL-RA → MLE → Arbiter → Allocator → RAM → Mux →
   tx_blk1/2; Szenarien: single, back-to-back, full, F18-skip, MLE+CMCE concurrent

**Reihenfolge:** override_ram → allocator → arbiter → mux-Umbau → MLE-Umbau →
top-Integration → integration-TB → deploy.

**Akzeptanz (Board):**
- `mle_req_cnt == consume_cnt > 0`, `alloc_full_cnt == 0`, `arb_stall_cnt == 0`
- WAV: non-NULL MAC-PDU auf konkretem TN=1-Slot sichtbar
- MS-Retransmits stoppen bzw. wechseln zu nächstem Registrierungs-Schritt

**ETSI:** EN 300 392-2 §21 (scheduling), §19 (MAC resource allocation)

### M2 Abhängigkeiten
```
M2.1 ✅ fertig
M2.2 ── braucht M2.3 Shadow-BRAM + ActiveSession-Table
M2.3 ── braucht Subscriber-Shadow-BRAM + ARM DB-Mgr
M2.4 ── parallel zu M2.2 (Alloc-Tabelle als gemeinsame Schnittstelle)
M2.5 ── unabhängig
M2.6 ── ersetzt dl_signal-Latch in M2.3; Voraussetzung für CMCE/SDS in M3/M4
```

**Aufwand:** ~4-5 Wochen (RTL-FSMs + Shadow-BRAM + ARM DB-Mgr + M2.6 ~1 Woche)

---

## M3: Gruppenruf mit Sprache

**Ziel:** BS initiiert/akzeptiert Gruppenruf. Mehrere MS in der Gruppe hören Sprache.

### M3.1 — CMCE Group Call Setup (RTL, hoch)
- **Neue Module:**
  - `rtl/lmac/tetra_cmce_group_fsm.v` — FSM: D-SETUP → D-CONNECT → U-TX DEMAND → D-TX GRANTED → D-TX CEASED
  - `rtl/lmac/tetra_active_group_table.v` — BRAM: GSSI → Slot-Alloc + Speaker-ISSI + State
  - `rtl/lmac/tetra_group_shadow.v` — BRAM-Shadow der ARM-Group-DB (GSSI → Memberlist)
  - `rtl/lmac/tetra_cmce_pdu_encoder.v` — D-SETUP / D-CONNECT / D-TX GRANTED / D-TX CEASED Builder
- ARM nur: Group-DB-Pflege (GSSI, Members) via AXI-Lite
- **ETSI:** EN 300 392-2 §14.7

### M3.2 — TCH Voice Channel (RTL, hoch)
- TCH/S: 274 type-1 Bits pro Frame (137 class-1 + 137 class-2)
- Stealing Bits (HA/HB) zeigen TCH vs SCH — `tetra_steal_detect` existiert
- **Voice-Relay-Pfad:** UL-TCH-Decode → BRAM-FIFO (ein Frame = 56.67 ms) → DL-TCH-Encode
  — kein DMA zu ARM nötig, Relay läuft komplett in RTL
- **ETSI:** EN 300 392-2 §8.2.3, §8.3

### M3.3 — TETRA Voice Codec ACELP (Platzierung offen)
- 4.567 kbit/s, 137 Bits pro 30ms Frame
- Für reinen Voice-Relay (Group-Call) ist *kein* Codec nötig — wir reichen
  die kodierten Bits transparent UL→DL durch (M3.4)
- Codec wird erst für Test-Injection (BS als Talker) oder Recording-Gateway
  relevant — dann Entscheidung PS (Cortex-A9 < 1 MIPS, simpel) vs PL
- `tetraVoiceDec.dll` im Projekt-Root → Referenz-Decoder für Dev-Tools
- **ETSI:** EN 300 395-2

### M3.4 — Voice Relay (RTL, mittel)
- Gruppenruf: ein MS sendet (PTT), BS empfängt und retransmittiert an alle
- Kein Mixing nötig, kein Codec nötig — Bit-transparenter Relay UL-TCH → DL-TCH
- Läuft komplett in RTL (Voice-Relay-FIFO), keine ARM-Latenz
- Latenz-Budget: ein TDMA Frame (56.67 ms)

### M3.5 — AACH Update während Call (RTL, niedrig)
- AACH muss Slot-Zuweisung (Traffic vs Free) reflektieren
- AACH-Encoder liest Alloc-Tabelle aus Group-FSM (gleicher Clock-Domain)
- **ETSI:** EN 300 392-2 §18.5.1

**Aufwand:** ~5-7 Wochen (CMCE-FSM + Voice-Relay komplett in RTL)

---

## M4: Einzelrufe

**Ziel:** Punkt-zu-Punkt-Ruf zwischen zwei MS über die BS.

### M4.1 — CMCE Individual Call (RTL, mittel)
- Erweiterung der `tetra_cmce_group_fsm.v` um Individual-Call-Zweig, oder
  separate `tetra_cmce_indiv_fsm.v` (Entscheidung bei Implementierung)
- D-SETUP nur an gerufenes MS (per ISSI adressiert, Shadow-BRAM-Lookup)
- D-CONNECT / U-CONNECT Handshake in FSM
- D-RELEASE für Rufabbau
- Simplex (PTT) = wie Gruppenruf; Duplex braucht 2 Slots
- **ETSI:** EN 300 392-2 §14.7, §14.8

### M4.2 — Duplex Slot Management (RTL, mittel)
- Full-Duplex: 2 Slots (je Richtung einer)
- `tetra_slot_content_mux.v` Alloc-Tabellen aus M2.4 reichen

### M4.3 — Paging (RTL, mittel)
- **Neues Modul:** `rtl/lmac/tetra_paging_fsm.v` — FSM: CALL_REQ → PAGE_BUILD → TX_BNCH
- D-ALERT PDU-Encoder (baut auf bestehendem BNCH-Payload-Pfad auf)
- Paging-Antwort kommt über RACH (in M2 bereits empfangen) — FSM-Handoff an Registration/Call
- **ETSI:** EN 300 392-2 §14.6

**Aufwand:** ~3-4 Wochen (inkrementell auf M3)

---

## Risiken

| # | Risiko | Impact | Mitigation |
|---|--------|--------|------------|
| 1 | **FDD RF-Isolation** | TX desensibilisiert RX bei Single-Antenna | Duplexer oder 2 Antennen. Für Lab: 2 Antennen mit Abstand |
| 2 | **Uplink Timing Advance** | MS sendet Burst zu früh/spät | Sync-Fenster breit genug machen (±2 Symbole) |
| 3 | **CUB-Erkennung** | Kurzer Burst (112 sym), nur 2 sym Guard | NTS-Threshold anpassen, Holdoff kürzen |
| 4 | **Voice Codec Lizenz** | ETSI Referenz-Code hat Lizenzbeschränkung | Für Forschung/Experiment OK, nicht für Produktion |
| 5 | **SYSINFO Frame Timing** | Inkonsistente Frame-Nummern → MS verweigert Registration | RTL-basiertes Auto-Update statt ARM-Polling erwägen |
| 6 | **MAC PDU Komplexität** | Variable-Length Fields, viele PDU-Typen | osmo-tetra als Referenz für PDU-Formate nutzen |
| 7 | **Viterbi für CUB** | 84-Bit statt 216-Bit Blöcke | Zweite LMAC-Instanz (~3000 LUT, ~8000 FF) |

---

## Änderungen nach Domain

### FPGA RTL (bestehende Module, Änderungen)
| Meilenstein | Module | Änderung |
|-------------|--------|----------|
| M1 ✅ | `tetra_ul_sync_detect_os4.v`, `tetra_ul_burst_capture.v`, `tetra_ul_pi4dqpsk_demod.v` | UL RA-Burst-Kette |
| M1 ✅ | `tetra_ul_sch_hu_decoder.v`, `tetra_ul_viterbi_r14.v` | SCH/HU r=1/4 Viterbi |
| M1 ✅ | `tetra_ul_mac_access_parser.v` | MAC-ACCESS Parser + AXI-Mailbox |
| M2 | `tetra_axi_lite_regs.v` | Shadow-BRAM-Write-Window + Alloc-Regs |
| M2 | `tetra_zynq_top.v` | Registration-FSM + Slot-Content-Mux verdrahten |
| M3 | `tetra_zynq_top.v` | Voice-Relay-FIFO (UL-TCH → DL-TCH) |

### FPGA RTL (neue Module)
| Meilenstein | Modul | Beschreibung |
|-------------|-------|--------------|
| M2.2 | `rtl/lmac/tetra_mac_resource_encoder.v` | MAC-RESOURCE PDU Builder |
| M2.2 | `rtl/lmac/tetra_mac_fragment.v` | Fragmentierung / Reassembly |
| M2.2 | `rtl/lmac/tetra_active_session_table.v` | Hot-State BRAM (ISSI → Alloc) |
| M2.3 | `rtl/lmac/tetra_mle_registration_fsm.v` | RX_UREG → DB-Lookup → ACCEPT/REJECT → TX |
| M2.3 | `rtl/lmac/tetra_d_location_update_encoder.v` | D-LOC-UPDATE-ACCEPT/REJECT |
| M2.3 | `rtl/lmac/tetra_subscriber_shadow.v` | Subscriber-Shadow-BRAM (permit-Lookup) |
| M2.4 | `rtl/tx/tetra_slot_content_mux.v` | Per-Slot Content-Auswahl |
| M3.1 | `rtl/lmac/tetra_cmce_group_fsm.v` | Group-Call FSM (Setup/Grant/Release) |
| M3.1 | `rtl/lmac/tetra_cmce_pdu_encoder.v` | D-SETUP / D-CONNECT / D-TX GRANTED / D-TX CEASED |
| M3.1 | `rtl/lmac/tetra_active_group_table.v` | Hot-State BRAM (GSSI → Alloc + Speaker) |
| M3.1 | `rtl/lmac/tetra_group_shadow.v` | Group-Shadow-BRAM (GSSI → Memberlist) |
| M4.1 | `rtl/lmac/tetra_cmce_indiv_fsm.v` | Individual-Call FSM (oder Erweiterung M3.1) |
| M4.3 | `rtl/lmac/tetra_paging_fsm.v` | Paging-FSM + D-ALERT Encoder |

### ARM Software (neu — nur DB + Admin)
| Datei | Meilenstein | Beschreibung |
|-------|-------------|--------------|
| `sw/tetra_db_mgr.c/.h` | M2 | Subscriber/Group-DB-Pflege + AXI-Lite Shadow-Write |
| `sw/tetra_admin.c/.h` | M2 | CLI/Web-UI-Hooks für Provisioning (optional) |

### ARM Software (bestehend)
| Datei | Meilenstein | Änderung |
|-------|-------------|----------|
| `sw/tetra_hal.c/.h` | M1/M2 | bleibt für SYSINFO-Setup; Frame-Counter wandert in RTL (M2.5) |
| `sw/tetra_ul_mon.c` | M1 ✅ | Diagnose-Tool für UL-Mailbox — bleibt (kein Response-Pfad) |

---

## Zeitplan (geschätzt)

```
Woche 1-3:   M1 — MS sieht BS, RACH sichtbar         ✅ fertig (UL-Decode HW-verifiziert)
Woche 4-8:   M2 — Einbuchen (RTL FSMs + Shadow-BRAM + ARM DB-Mgr)
Woche 9-15:  M3 — Gruppenruf mit Voice-Relay (komplett in RTL)
Woche 16-19: M4 — Einzelrufe + Paging
```

**Gesamtaufwand: ~15-19 Wochen** (RTL-FSMs sind aufwendiger als ARM-SW gewesen
wäre, dafür entfällt Voice-Codec-Portierung im Critical-Path)

---

## Referenzen

- EN 300 392-2: TETRA V+D Air Interface (Hauptspezifikation)
- EN 300 395-2: TETRA Speech Codec
- EN 300 392-7: Security (erstmal überspringen)
- osmo-tetra: Open-Source TETRA Decoder (Referenz für PDU-Formate)
- SDRSharp.Tetra.dll: Windows TETRA Plugin (bereits reverse-engineered)
