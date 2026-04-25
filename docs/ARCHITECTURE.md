# ARCHITECTURE — RTL/SW-Stack, Meilensteine, Modul-Status, Ressourcen

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Architektur-Entscheidung:** 2026-04-22 — FPGA-heavy Stack
**Zuletzt aktualisiert:** 2026-04-25 (M2 erreicht — MTP3550 attached)

Ersetzt: `plan_tetra_bs_stack.md`, `plan_tetra_tdma_rtl_ownership.md`,
`module_status.md`, `resource_estimate.md`.

---

## 1. Projektziel

Vollständige TETRA-Base-Station für Amateurfunk (70-cm-Band, 438.25 MHz DL / 428.25 MHz UL) — Einbuchen, Gruppenrufe, Einzelrufe. MS (MTP3550) als Anchor-Test-Gerät.

**Leitprinzip:** RTL hält die Uhr, das Sende-Raster und die zeitabhängigen PDUs. SW (ARM) liefert nur langsam ändernde Payload-Körbe (Cell-Config, SYSINFO, MCCH, NULL-PDU) + hält die Subscriber/Group-DB.

---

## 2. Architektur-Entscheidung 2026-04-22 — FPGA-heavy

**MAC/MLE/CMCE-Logik läuft als RTL-FSMs im FPGA, nicht auf ARM.** Response-Latenz ist damit deterministisch innerhalb eines TDMA-Slots (14.17 ms).

### 2.1 Rollenverteilung

**PS (ARM Cortex-A9)** — reine Management-Rolle:
- Subscriber-DB (ISSI → permit-mask, LA, home-cell)
- Group-DB (GSSI → Memberlist, service-class)
- Admin-UI, Provisioning, Log-Aggregation
- Schreibt DB-Einträge per AXI-Lite in BRAM-Shadow (Variante A)

**FPGA (PL)** — Echtzeit-Protokoll:
- RTL-FSMs für Registration / ChannelReq / GroupCall / Paging
- Hot-State in BRAM: aktive Sessions (ISSI → Slot-Alloc), aktive Gruppen (GSSI → Slot/Speaker)
- Subscriber-/Group-Shadow-BRAM für permit-Lookup (1 Cycle)
- PDU-Encoder: MAC-RESOURCE, D-LOCATION-UPDATE, D-CONNECT, D-ALERT, BSCH, AACH
- Bestehende UL MAC-ACCESS → AXI-Mailbox (`0x164..0x178`) bleibt als Diagnose-Pfad

**DB-Transport — Variante A (gewählt):** ARM pusht komplette Subscriber-Table per AXI-Lite in BRAM-Shadow (256 Einträge × 64 bit = 1× BRAM36 = 16 kbit), Lookup-Latenz 1 Cycle. Upgrade auf AXI-HP-Read zu PS-DRAM (Variante B) bleibt offen für >1000 MS.

### 2.2 Warum FPGA-heavy

- SW-getriebenes Scheduling ist fragil (Race zwischen SW-Register-Write und `tx_slot_pulse`). Bisher 1 % NDB-Decoderate auf unserem eigenen WAV (vs. 100 % auf Gold).
- TDMA-Counter + Scheduling müssen deterministisch pro `(TN, FN, MN, HN)` sitzen. Die einzige Instanz die "wo bin ich" kennt, ist das RTL.
- ACELP-Sprach-Codec für Voice-Relay (Gruppenruf) nicht nötig: bit-transparenter UL-TCH → DL-TCH Pass-Through, alles in RTL.
- Response-Latenz-Budget: 1 Slot = 14 ms, ARM kann das nicht garantieren.

---

## 3. Architektur-Überblick

### 3.1 Signalfluss

```
AD9361 IQ ──► [axi_ad9361 IP] ──► [adapter] ──► [RX Frontend: CIC+RRC]
                                                      │
                                                      ▼
          [Demod] ──► [Timing Recovery] ──► [Sync Detect]
                                                      │
                                                      ▼
                 [Burst Demux] ──► [Frame Counter] (TDMA-Status)
                                                      │
                    ┌─────────────────────────────────┘
                    ▼
 [LMAC RX: descramble → deinterleave → Viterbi → CRC → Reed-Muller]
                    │
                    ▼
 [MAC-ACCESS Parser] ──► [MLE Registration FSM] ──► [Active Session Table]
                                                             │
                                                             ▼
                                        [MAC-RESOURCE DL Builder]
                                        [D-LOCATION-UPDATE Encoder]
                                                             │
                                                             ▼
 [LMAC TX: CRC → RCPC → interleave → scramble] ──► [π/4-DQPSK Mod]
                                                             │
                                                             ▼
                                  [RRC → CIC → DAC → axi_ad9361 IP]
                                                             │
                                                             ▼
                                                         AD9361 IQ
```

### 3.2 Modulbaum (aktueller Stand)

```
tetra_zynq_top.v
├── tetra_ad9361_axis_adapter.v
│
├── tetra_rx_chain.v
│   ├── tetra_rx_frontend.v          (CIC + RRC)
│   ├── tetra_pi4dqpsk_demod.v       (CORDIC)
│   ├── tetra_timing_recovery.v      (Gardner TED + NCO)
│   ├── tetra_sync_detect.v          (Training-Seq-Correlator)
│   ├── tetra_burst_demux.v          (4-Slot Demux)
│   ├── tetra_frame_counter.v        (TDMA-Hierarchie)
│   ├── tetra_ul_sync_detect_os4.v   (UL-RA-Sync, 4× oversampled)
│   ├── tetra_ul_burst_capture.v     (UL-RA-Ring-Buffer)
│   ├── tetra_ul_pi4dqpsk_demod.v    (UL Demod 5-bit Soft-out)
│   ├── tetra_ul_sch_hu_decoder.v    (K=168, a=13, 92 info bits)
│   └── tetra_ul_viterbi_r14.v       (ETSI-konformer UL-Viterbi)
│
├── tetra_tx_chain.v
│   ├── tetra_pi4dqpsk_mod.v         (Symbol-Mapping)
│   ├── tetra_rrc_filter.v           (α=0.35)
│   ├── tetra_burst_builder.v        (255-sym Slot-Content)
│   ├── tetra_burst_mux.v            (4-Slot Multiplexer)
│   ├── tetra_tx_frontend.v          (CIC-Interpolation)
│   ├── tetra_sb1_encoder.v          (BSCH/SYNC-PDU)
│   ├── tetra_sch_f_encoder.v        (SCH/F 268→432)
│   └── tetra_aach_encoder.v         (Reed-Muller 30/14)
│
├── tetra_lmac.v
│   ├── tetra_scrambler.v
│   ├── tetra_interleaver.v
│   ├── tetra_rcpc_encoder.v
│   ├── tetra_viterbi_decoder.v      (DL-Path, 16-state)
│   ├── tetra_reed_muller.v
│   ├── tetra_crc16.v
│   ├── tetra_steal_detect.v
│   ├── tetra_ul_mac_access_parser.v (MAC-ACCESS Header → AXI-Mailbox)
│   ├── tetra_mle_registration_fsm.v (UL-RA → AST-Query → ACCEPT → DL-Queue)
│   ├── tetra_d_location_update_encoder.v (MM-PDU-Builder)
│   ├── tetra_mac_resource_dl_builder.v   (MAC-RESOURCE-Wrapper)
│   ├── tetra_active_session_table.v      (ISSI → Slot-Alloc BRAM)
│   ├── tetra_dl_signal_queue.v           (depth-4 Drop-Newest FIFO)
│   └── tetra_dl_signal_scheduler.v       (MLE > CMCE > SDS, 1 frame ahead)
│
├── tetra_axi_dma_bridge.v            (PL → PS S2MM)
├── tetra_axi_lite_regs.v             (Reg-Bank + Shadow-BRAM-Window)
└── tetra_clk_reset.v                 (Reset-Sync, MMCM)
```

### 3.3 Verilog-Konventionen

- Ein `always`-Block pro Register; keine kombinatorischen Blöcke mit mehreren Register-Zuweisungen
- Explizite Clock-Domain-Suffixe: `_sys` (100 MHz), `_axi`, `_lvds`, `_sample` (72 kHz)
- Asynchroner Reset mit Synchronizer (`tetra_clk_reset.v`), active-low
- **Keine Arrays** in Synthese-Code — flache Busse statt `reg [7:0] mem [0:255]`
- `snake_case` für Signale, `UPPER_CASE` für Parameter, `tetra_` Prefix für alle Module
- FSM: separater `always`-Block für State-Register und kombinatorische Next-State-Logik
- Pipeline-Dokumentation pro Stufe mit `// Pipeline Stage N: ...`-Kommentar

---

## 4. Meilensteine

```
M1: MS sieht BS, RACH sichtbar       ✅ fertig (UL-Decode HW-verifiziert 2026-04-22)
M2: MS bucht sich ein                ✅ HW-verifiziert 2026-04-25 12:18 (Build `26191b4`, MTP3550 attached)
M3: Gruppenruf mit Voice-Relay       ⏳ Phase 3 (komplett in RTL geplant)
M4: Einzelrufe + Paging              ⏳ Phase 4
```

### 4.1 M1 — MS sieht BS, sendet RACH ✅

| Substep | Scope | Status |
|---------|-------|--------|
| M1.1 SYSINFO PDU | `sw/tetra_hal.c` — `build_sysinfo_pdu()`, `late_entry=1`, `cell_service_level=service_available` | ✅ bit-exakt Gold-WAV |
| M1.2 ACCESS_DEFINE in BNCH | `sw/tetra_hal.c` — echte PDU statt PN-Filler | ✅ BNCH echter Content |
| M1.3 AACH Access Assignment | `build_aach()` — CapAlloc F1-17, F18 DL/UL-Assign mit MN%4-Rotation | ✅ matcht Gold |
| M1.4 NTS Sync-Detection für UL | `tetra_sync_detect.v` — NTS 11-sym + STS 19-sym schaltbar | ✅ |
| M1.5 UL Burst Demux / NUB+CUB | Neuer UL-RX-Pfad (127-sym CB für RA) | ✅ HW-verifiziert MTP3550 |
| M1.6 RACH-Erkennung | 41/42 CRC-Pass gegen Python-Baseline | ✅ 2026-04-22 |
| M1.7 AD9361 FDD | Duplex=0 (10 MHz Band 4), RX 428.25 / TX 438.25 MHz | ✅ |

### 4.2 M2 — MS bucht sich ein ✅

| Substep | Status |
|---------|--------|
| M2.1 SCH/HU Channel-Decoding | ✅ `tetra_ul_sch_hu_decoder.v` + `tetra_ul_viterbi_r14.v` (ETSI-konform), HW-verifiziert |
| M2.2 MAC Layer (MAC-RESOURCE Builder + AST) | ✅ `tetra_mac_resource_dl_builder.v` + `tetra_active_session_table.v` |
| M2.3 MLE Registration FSM + D-LOC-UPDATE-Encoder | ✅ Two-Phase-Attach (SCH/HD AL-SETUP + SCH/F BL-ADATA), 102-bit MM body bit-exakt zur Gold-Ref, ra_flag=0 im Accept |
| M2.4 Per-Slot TX-Content-Mux | ✅ `tetra_slot_content_mux.v` + `tetra_dl_signal_queue.v` + `tetra_dl_signal_scheduler.v` (Refactor 2026-04-23) + `sched_active_sys` Bus für AACH-Override (2026-04-25) |
| M2.5 SYSINFO Frame-Counter im RTL | ⚠️ Teilweise — `tx_frame_cnt_sys` läuft frei, aber Frame-Nummer wird aus SW geschrieben (siehe §5) |
| M2.6 DL-Signal-Queue/Scheduler | ✅ Lock-Spec validiert + AACH dynamic Unalloc/Unalloc + 1-Frame Pre-Reply→Accept-Gap |
| M2.7 UL-Parser bluestation-aligned | ✅ 2-bit addr_type + 24-bit ISSI (Commit `eeabf1f`..`1f1ec3a`) |
| M2.8 MLE-FSM mm_type=2 als U-LOC-UPDATE-DEMAND | ✅ Commit `545cc50` — `MmPduTypeUl` ist UL-PDU-Type-Authority |
| M2.9 MM-Body bit-exakter Gold-Ref-Replay | ✅ Commit `26191b4` — 102-bit, GILA mit GSSI=0x2F4D61 |

**Verifikation (2026-04-25 12:18 ZULU, Build `26191b4`):** `tetra_ul_mon.log`
zeigt 1 Demand-Fragment vom MTP3550, dann Stille. AXI-Counter
`0x190 = 0x0001_0001` (1:1 Demand→Accept), `0x198 = 0x0000_0002` (Pre-Reply
+ Accept on-air). Vorher (Build `b994e5d`): 8+ Demand-Retries pro 90 s,
Re-Demand-Loop. Siehe `PROTOCOL.md §9` für komplette Wegfindung.

### 4.3 M3 — Gruppenruf ⏳ (Plan)

| Substep | Module | Scope |
|---------|--------|-------|
| M3.1 CMCE Group-Call Setup | `tetra_cmce_group_fsm.v`, `tetra_active_group_table.v`, `tetra_group_shadow.v`, `tetra_cmce_pdu_encoder.v` | D-SETUP → D-CONNECT → U-TX-DEMAND → D-TX-GRANTED → D-TX-CEASED |
| M3.2 TCH Voice Channel | TCH/S 274 type-1 Bits, Stealing HA/HB | Existiert als Skeleton |
| M3.3 ACELP Codec | nicht benötigt für Voice-Relay (bit-transparent Pass-Through UL-TCH → DL-TCH) | Platzierung offen — erst für BS-als-Talker relevant |
| M3.4 Voice Relay | Bit-transparent UL→DL, FIFO 1 Frame = 56.67 ms | Komplett in RTL geplant |
| M3.5 AACH-Update während Call | Alloc-Tabellen-basiert | Baut auf M2.4 auf |

**Aufwand M3:** ~5-7 Wochen.

### 4.4 M4 — Einzelrufe + Paging ⏳ (Plan)

| Substep | Module |
|---------|--------|
| M4.1 CMCE Individual Call | `tetra_cmce_indiv_fsm.v` (oder Erweiterung M3.1) — D-SETUP/D-CONNECT/D-RELEASE |
| M4.2 Duplex-Slot-Management | `tetra_slot_content_mux.v`-Erweiterung |
| M4.3 Paging | `tetra_paging_fsm.v`, D-ALERT-Encoder, RACH-Antwort → Handoff an Call-FSM |

**Aufwand M4:** ~3-4 Wochen (inkrementell auf M3).

---

## 5. TDMA-Timebase + Slot-Scheduling-Architektur (M2.4/M2.5)

### 5.1 Motivation

- SW-getriebene Schedule-Registrierung hat Race-Bedingungen (`tetra_sysinfo` schreibt Register, RTL konsumiert bei `tx_slot_pulse`).
- BSCH-Rotationen und per-Slot-Burst-Type sind deterministisch aus `(TN, MN)` ableitbar → ins RTL.
- Systemzeit (SYNC-PDU TN/FN/MN/HN) **muss** den Burst beschreiben, der in genau dem Moment rausgeht — SW kann das nicht garantieren.

### 5.2 Ziel-Architektur

```
 ┌──────────────────────────────────────────────────────────────────┐
 │ tetra_tdma_timebase                                              │
 │  TN[1:0] FN[4:0] MN[5:0] HN[5:0]  (+1 pro tx_slot_pulse)        │
 │  sync_load_strobe (AXI) → SW lädt absolute Zeit bei Boot         │
 │  tdma_tick  → 1 Sys-Takt vor slot_pulse (Preload-Window)         │
 └─┬──────────────────────┬──────────────────────┬─────────────────┘
   │                      │                      │ (FN)
   ▼                      ▼                      ▼
 ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐
 │ slot_schedule│  │ bsch_encoder     │  │ aach_encoder     │
 │ BRAM 288×16  │  │ SYNC-PDU → 120b  │  │ 14b→RM(30,14)    │
 └─┬────────────┘  └──┬───────────────┘  └─────────────┬────┘
   │ schedule_entry   │ sb_sb1                         │ bb
   ▼                  ▼                                ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ slot_content_mux                                                │
 │  payload_class wählt: {BSCH+BNCH+AACH, MCCH, NDB-SYSINFO,      │
 │                        NULL-PDU, empty}                        │
 └─┬──────────────────────────────────────────────────────────────┘
   │ {block1, block2, bb, sb1, bkn2, nts_sel, burst_type}
   ▼
 [tetra_burst_builder]
```

### 5.3 Bausteine (8 Stufen)

**Stufe 1 — `tetra_tdma_timebase.v`** (neu): Kanonischer TDMA-Counter. `sync_load_strobe` lädt absolute Zeit synchron beim nächsten `sym_en`. Outputs: `tn[1:0]`, `fn[4:0]`, `mn[5:0]`, `hn[5:0]`, `slot_pulse`, `tdma_tick`.

**Stufe 2 — AXI-Lite `TX_TDMA_SYNC`-Register** (`0x140` LOAD, `0x144` STATE): Write STROBE-Bit lädt Timebase. Read liefert Debug-State inkl. `sym_cnt`.

**Stufe 3 — `tetra_slot_schedule.v`** (neu): Tabellen-Lookup `(MN%4, FN, TN) → 16-bit schedule_entry`. 4×18×4 = 288 Einträge in 1× RAMB18 (Dual-Port, AXI-write + RTL-read). AXI-Fenster `0x400..0x63F`.

Eintrag-Format (16 bit):
```
[15:12] payload_class  (0=STATIC_BROADCAST, 1=NULL_PDU, 2=TCH, 3..15=reserved)
[11:6]  payload_idx    (Variant/Slot/Channel-Nummer innerhalb der Klasse)
[5:4]   burst_type     (00=NDB, 01=SDB, 10=reserved, 11=idle)
[3]     ndb2           (Training-Seq 2 vs. 1)
[2]     enable         (0 = blank burst, kein RF)
[1]     sys_time_inject (obsolet, Umwidmung möglich)
[0]     reserved
```

**Stufe 3.5 — `tetra_bsch_encoder.v`** (neu): BSCH 60 type-1 → CRC16 → tail → RCPC 2/3 → interleave 8×15 → scramble(init=3) → 120 type-5. Inputs: `tn/fn/mn` aus Timebase + Cell-Config-Register (MCC/MNC/CC/System-Code etc.). Budget: ~400 Sys-Takte = 4 µs bei 100 MHz.

**Stufe 3.7 — `tetra_aach_encoder.v`** (neu): AACH 14 type-1 → RM(30,14) → 30 type-5. F1-17: CapAlloc. F18: DL/UL-Assign mit CC-Scramble.

**Stufe 4 — `tetra_slot_content_mux.v`** (Umbau): Liest aus Schedule-Eintrag `payload_class`/`payload_idx`, multiplexed BSCH-Encoder-Output / AACH-Encoder-Output / SW-Register-Banks (BNCH, MCCH, NDB-SYSINFO-Filler) / NULL-PDU-Register.

**Stufe 5 — Cell-Config-Register** (`0xE0` CELL_CFG_0, `0xE4` CELL_CFG_1): MCC, MNC, sys_code, sharing_mode, ts_reserved_frames, U-plane-DTX, neigh_cell_bc, cell_service_level, late_entry.

**Stufe 6 — NULL-PDU-Register** (`0x340..0x34F`, 4× 32 bit = 128 Bit): statisches 124-Bit-Pattern `0x0010_8000_0000_…_0000` (Gold-Messung: 97/97 Vorkommen bit-identisch). SW schreibt einmal beim Boot via `build_schf_null_pdu()`.

**Stufe 7 — Gold-Schedule-Preset**: `scripts/gold_schedule.py` erzeugt 288-Byte Blob, SW `memcpy` ins AXI-Fenster. Gold-Muster:
- TN=1,2,3 (ETSI 2,3,4): alle SDB mit `sys_time_inject=1`
- TN=0 (ETSI 1): F18 MN%4==2 = SDB, sonst MCCH (ACCESS-DEFINE), sonst NDB-SYSINFO/NULL-PDU je MN%4
- Alle `enable=1` — Gold sendet durchgehend

**Stufe 8 — SW-Migration**: `tetra_sysinfo` schreibt Cell-Config + Gold-Preset + NULL-PDU-Register nur einmal beim Boot. Per-Slot-Encoding-Pfade (BSCH, AACH) werden aus SW entfernt.

### 5.4 Aktueller Status TDMA-Umbau

🔴 **Nicht umgesetzt.** Heutiges RTL hat `always @(*)`-Scheduling in `tetra_zynq_top.v:694-756` mit hart kodierten Mustern. SW schreibt BSCH/AACH-Payload kontinuierlich. 1 % NDB-Decoderate auf eigenen WAVs ist ein direkter Folgeeffekt.

**Aufwand:** ~1-2 Wochen für alle 8 Stufen. Priorität: hoch für DL-Qualität, niedrig für MS-Registration (dort andere Blocker).

---

## 6. Modul-Status + Ressourcen

### 6.1 Übersicht

| Kategorie | Module | TBs | Sim-Status | Phase |
|-----------|--------|-----|------------|-------|
| RX Chain | 8 | 8 | ✅ 8/8 PASS | 1 |
| UL RX Chain (RA) | 6 | 5 | ✅ 5/5 PASS (HW-verifiziert) | 2 |
| LMAC DL+UL | 11 | 11 | ✅ 11/11 PASS | 2 |
| TX Chain | 6 | 6 | ✅ 6/6 PASS | 3 |
| Signalling (MLE/MAC-RES/DL-Queue) | 6 | 6 | ✅ 6/6 PASS (incl. Golden-SCH/F) | 2 |
| Infra (AXI-Regs, DMA, Reset) | 3 | 3 | ✅ 3/3 PASS | 1 |
| **Total** | **~40** | **~35** | **Integration ok** | — |

### 6.2 Detail-Status (Stand 2026-04-25)

| Modul | LUT | FF | DSP | BRAM | Sim | Notiz |
|-------|-----|----|----|------|-----|-------|
| `tetra_clk_reset` | 0 | 8 | 0 | 0 | 15/15 | 4 Domain-Resets |
| `tetra_ad9361_axis_adapter` | ~5 | ~32 | 0 | 0 | 7/7 | AXI-IP-Wrapper |
| `tetra_rx_frontend` | ~120 | ~280 | 1 | 0 | 12/12 | CIC+RRC+CDC, `CIC_GAIN_SHF=6` |
| `tetra_pi4dqpsk_demod` | ~300 | ~150 | 0 | 0 | 3/3 | CORDIC |
| `tetra_timing_recovery` | ~120 | ~200 | 2 | 0 | 5/5 | Gardner TED |
| `tetra_sync_detect` | ~380 | ~130 | 0 | 0 | 6/6 | LOCK_TOL=30, LOCK_TIMEOUT=3060 |
| `tetra_burst_demux` | ~120 | ~580 | 0 | 0 | 4/4 | — |
| `tetra_frame_counter` | ~50 | ~50 | 0 | 0 | 8/8 | Free-running, nach BSCH-Sync zu laden (§5) |
| `tetra_ul_sync_detect_os4` | ~280 | ~200 | 0 | 0 | 5/5 | UL-RA NTS 4× oversampled |
| `tetra_ul_burst_capture` | ~90 | ~110 | 0 | 1 | 3/3 | Ring 512×32 |
| `tetra_ul_pi4dqpsk_demod` | ~200 | ~300 | 4 | 0 | 4/4 | 5-bit Soft |
| `tetra_ul_sch_hu_decoder` | ~2000 | ~4000 | 2 | 1 | 4/4 | K=168, a=13, info=92 |
| `tetra_ul_viterbi_r14` | ~1500 | ~3000 | 0 | 1 | 5/5 | ETSI-konform (DL-Viterbi bit-reversed!) |
| `tetra_ul_mac_access_parser` | ~100 | ~150 | 0 | 0 | 5/5 | Bug #8 Erweiterung: `mm_pdu_type` + `loc_upd_type` |
| `tetra_scrambler` | ~50 | ~32 | 0 | 0 | 8/8 | Dual-Use DL+UL |
| `tetra_interleaver` | ~100 | ~450 | 0 | 0 | 8/8 | Block-Interleave |
| `tetra_viterbi_decoder` (DL) | ~2500 | ~7800 | 0 | 0 | 7/7 | Bit-reversed state conv (Loopback only) |
| `tetra_reed_muller` | ~270 | ~100 | 0 | 0 | 25/25 | AACH/ACCH 30/14 |
| `tetra_crc16` | ~20 | ~18 | 0 | 0 | 11/11 | CCITT |
| `tetra_rcpc_encoder` | ~150 | ~80 | 0 | 0 | 7/7 | r=1/3 mother, r=2/3 puncture |
| `tetra_steal_detect` | ~20 | ~28 | 0 | 0 | 9/9 | HA/HB |
| `tetra_pi4dqpsk_mod` | ~200 | ~100 | 0 | 0 | 31/31 | **Dibit 10↔11 Fix 2026-04-13** |
| `tetra_rrc_filter` | ~300 | ~150 | 1 | 0 | 6/6 | α=0.35 |
| `tetra_burst_builder` | ~65 | ~524 | 0 | 0 | 5/5 | 255-sym, 18 kHz `sym_en_w` |
| `tetra_burst_mux` | ~50 | ~200 | 0 | 0 | 5/5 | — |
| `tetra_tx_frontend` | ~80 | ~680 | 0 | 0 | 5/5 | CIC-Interpolation, `CIC_SHIFT=24` |
| `tetra_sb1_encoder` | ~180 | ~260 | 0 | 0 | ok | BSCH 60→120, **Scrambler-Tap-Fix 2026-04-21** |
| `tetra_sch_f_encoder` | ~200 | ~350 | 0 | 0 | ok | 268→432 |
| `tetra_aach_encoder` | ~50 | ~40 | 0 | 0 | ok | F1-17 / F18-Varianten |
| `tetra_mac_resource_dl_builder` | ~400 | ~500 | 0 | 0 | 6/6 | 9 Bugs durchgearbeitet |
| `tetra_d_location_update_encoder` | ~50 | ~80 | 0 | 0 | 16/16 | MM-PDU-Bits (Minimal-Accept) |
| `tetra_active_session_table` | ~200 | ~300 | 0 | 1 | 4/4 | 64-bit-Records, 64 Slots |
| `tetra_dl_signal_queue` | ~150 | ~400 | 0 | 0 | ok | Depth-4 drop-newest |
| `tetra_dl_signal_scheduler` | ~300 | ~500 | 0 | 0 | ok | MLE>CMCE>SDS, 1 frame ahead |
| `tetra_mle_registration_fsm` | ~500 | ~700 | 0 | 0 | 4/4 | FSM + AST-Handshake + SCH/F-Encoder |
| `tetra_slot_content_mux` | ~200 | ~300 | 0 | 0 | 8/8 | 4-TN-Sweep inkl. SIGNALLING-Routing |
| `tetra_axi_lite_regs` | ~500 | ~400 | 0 | 0 | 10/10 | 0x00..0x1AC + SB/NDB + Gold-Schedule |
| `tetra_axi_dma_bridge` | ~120 | ~570 | 0 | 0 | 7/7 | S2MM 32-bit |
| **Summe** | **~12,000** | **~25,000** | **~10** | **~5** | | — |

### 6.3 Ressourcen-Utilization (Zynq-7020)

| Resource | Genutzt | Verfügbar | Utilization |
|----------|---------|-----------|-------------|
| LUT | ~12,000 | 53,200 | ~23% |
| FF | ~25,000 | 106,400 | ~24% |
| DSP48E1 | ~10 | 220 | ~5% |
| BRAM18k | ~5 | 280 | ~2% |
| BUFG | ~6 | 32 | ~19% |

**Viel Headroom für M3+M4** (Group-Call-FSM, Voice-Relay-FIFO, Paging-FSM, Subscriber/Group-Shadow-BRAM).

### 6.4 Top-Level-Integration

| Modul | RTL | TB | Status |
|-------|-----|----|--------|
| `tetra_zynq_top` | ✅ | — | Component-Integration verifiziert |
| `tetra_system_top` (Vivado BD) | ✅ | — | PS+PL + axi_ad9361 IP |
| `tetra_rx_chain` | ✅ | — | RX-Container |
| `tetra_tx_chain` | ✅ | — | TX-Container |
| `tetra_lmac` | ✅ | — | LMAC-Container |

---

## 7. Bekannte Issues + Fixes (Historie)

| Datum | Issue | Modul | Fix |
|-------|-------|-------|-----|
| 2026-04-13 | ADC dfmt `0x01` statt `0x51` → sign-extend fehlt → RF SYNC unmöglich | `axi_ad9361` ADC-Config | Script-Fix `tetra_ctrl.sh`: 0x01→0x51 |
| 2026-04-13 | π/4-DQPSK Dibit 10↔11 vertauscht (ETSI §5.5.2.3) | `rtl/tx/tetra_pi4dqpsk_mod.v` | phase_inc 2'b10: 7→5, 2'b11: 5→7 |
| 2026-04-13 | CIC_GAIN_SHF=0 → Gardner-TED-Loop-Gain zu niedrig bei ADC-Amplitude ~512 | `rtl/rx/tetra_rx_frontend.v` | CIC_GAIN_SHF 0→6 (64× Verstärkung) |
| 2026-04-17 | `tetra_tx_nco` LO-Offset-Modul komplett entfernt | `rtl/tx/tetra_tx_nco.v` (gelöscht) | Direkt an AD9361, kein Offset nötig |
| 2026-04-17 | sync_detect Lock-FSM zu fragil für RF | `rtl/rx/tetra_sync_detect.v` | LOCK_TOL 8→30, LOCK_TIMEOUT→3060, spacing_ok auf Frame-Vielfache |
| 2026-04-21 | BSCH-Scrambler-Tap-Bug → BER 15% / MER 100% trotz STS 0.990 | `rtl/tx/tetra_sb1_encoder.v` | Scrambler-Taps korrigiert |
| 2026-04-21 | REG_COLOUR_CODE shift-by-2 → on-air CC=4 statt 49 | `sw/tetra_hal.c` | Raw-CC statt packed scrambler_init |
| 2026-04-22 | DL-Viterbi nutzt bit-reversed state conv (nur DL-Loopback kompatibel) | `rtl/lmac/tetra_viterbi_decoder.v` | UL bekam eigene ETSI-Version `rtl/rx/tetra_ul_viterbi_r14.v` |
| 2026-04-22 | Demod→Vit Soft-Scale zu grob (3-bit) | `rtl/rx/tetra_ul_pi4dqpsk_demod.v` | 5-bit Quant, top6 MSB-slice |
| 2026-04-23 | Queue+Scheduler Symptom-Fix-Stack (4 Commits) | Diverse Signalling | Refactor `refactor/dl-signal-arch`: Queue+Scheduler, 1-frame-ahead, strict MLE>CMCE>SDS, depth 4, drop-newest |
| 2026-04-23 | REG_SIGNAL_TARGET_TN Default 1→0 | `rtl/infra/tetra_axi_lite_regs.v` | Reset-Default 1→0 (ETSI TN=1 ist 0-based=0) |
| 2026-04-23 | REG_CELL_LA hart 14'd1 | `rtl/tetra_zynq_top.v` | Neues AXI-Reg `0x1A0`, CDC an MLE-FSM |
| 2026-04-23 | Bug #4: MLE-FSM recycelte UL-`addr_type` in DL-Accept | `rtl/lmac/tetra_mle_registration_fsm.v` | `lat_addr_type <= 3'd1` (SSI) |
| 2026-04-23 | Bug #6: MM-Body mit SSI drin statt nicht — teilweise falsch (siehe PROTOCOL.md) | `rtl/lmac/tetra_d_location_update_encoder.v` | MM-PDU-Len 54→16 (später als Fehler identifiziert) |
| 2026-04-23 | Bug #7: 3 unkonditionale presence-flag-bits im MAC-Header | `rtl/lmac/tetra_mac_resource_dl_builder.v` | Flags nur wenn PosOfGrant=1 (ETSI §21.4.3.1) |
| 2026-04-23 | Bug #8: LocAccType hartverdrahtet | MLE-FSM + MM-Encoder | Echo `ul_loc_upd_type` vom Parser |
| 2026-04-23 | Bug #9: FCS Coverage-Scope (ganz LLC) + kein Pre-Shift bei len<32 | MAC-RESOURCE-Builder | osmo-style: TL-SDU-only + `crc <<= (32-len)` |
| 2026-04-24 | RandAccFlag=0 hartverdrahtet | MAC-RESOURCE-Builder | `90bda0a` — =1 für ISSI-adressierte Accept (ETSI §21.4.3.1) |
| 2026-04-24 | LLC BL-ADATA+FCS statt BL-DATA + MM bluestation-aligned | MLE-FSM, Encoder | `e056439` |
| 2026-04-24 | Two-Phase-Attach-Flow fehlte | DL-Signalling | `2c8ad4a` — SCH/HD AL-SETUP LI=7 pre-reply + SCH/F BL-ADATA LI=21 Accept (matcht Gold-Ref Burst #727+#735) |
| 2026-04-25 | UL MAC-ACCESS-Parser falsch aligned: `addr_type=3 bit` + `short_ssi=10 bit` ergab konstant 523 für jede Motorola-MS | `rtl/lmac/tetra_ul_mac_access_parser.v` | `eeabf1f` — bluestation-Layout (2-bit `addr_type` + 24-bit ISSI) |
| 2026-04-25 | REG_UL_PDU_SSI 10-bit-mask | `rtl/infra/tetra_axi_lite_regs.v`, `sw/tetra_ul_mon.c` | `83f2cdc` + `eb42913` — auf 24-bit (`0xFFFFFF`) erweitert |
| 2026-04-25 | 24-bit ISSI nicht durch CDC propagiert | `rtl/tetra_zynq_top.v` | `26035a9` |
| 2026-04-25 | MLE-FSM adressierte mit short_ssi statt 24-bit ISSI | `rtl/lmac/tetra_mle_registration_fsm.v` | `4ccbed8` — `lat_ssi[23:0]` + `lat_accept_info_bits[251:228]` carry full ISSI |
| 2026-04-25 | TB-Coverage für ISSI-Pfad | `tb/tb_ul_mac_access_parser.v` + `tb/tb_mle_registration_fsm.v` | `1f1ec3a` — externe-BS- + MTP3550-on-air-Vektoren, 31/31 + 6/6 PASS |
| 2026-04-25 | UL-MM-Type-Filter mismatch | `rtl/tetra_zynq_top.v` | `545cc50` — mm_type=2 (= U-LOC-UPDATE-DEMAND per `MmPduTypeUl`) als Trigger akzeptiert (DL-Tabelle hatte =4 erwartet) |
| 2026-04-25 | AACH statisch + Pre-Reply→Accept Gap fehlte | `rtl/tx/tetra_aach_encoder.v`, `rtl/lmac/tetra_dl_signal_scheduler.v`, `rtl/lmac/tetra_mle_registration_fsm.v` | `b994e5d` — dynamic AACH Unalloc/Unalloc + 1-Frame Gap S_WAIT_GAP_FRAME |
| 2026-04-25 | MM-Body-Inhalt nicht bit-exakt zur Gold-Ref | `rtl/lmac/tetra_d_location_update_encoder.v` + `rtl/lmac/tetra_mle_registration_fsm.v` | `26191b4` — 102-bit MM body bit-exakt, GILA mit GSSI=0x2F4D61, ra_flag=0 im Accept → **MTP3550 attached** |
| 2026-04-25 | Subscriber-Shadow Permit-Check fehlte (jeder ISSI durfte attachen) | `rtl/lmac/tetra_d_location_update_reject_encoder.v` (NEU) + `rtl/lmac/tetra_mle_registration_fsm.v` (S_SHADOW_QUERY/WAIT/PERMIT_DECIDE) + `rtl/tetra_zynq_top.v` (Shadow.q_* Verdrahtung + DB-Policy CDC) + `rtl/infra/tetra_axi_lite_regs.v` (REG_DB_POLICY @ 0x1AC) | `2af8e8c` — Phase A der Subscriber-DB; Default `accept_unknown=1` bewahrt M2-Verhalten, `=0` aktiviert strict permit-check |
| 2026-04-25 | U-ITSI-DETACH räumt AST-Slot nicht; AST-`last_seen` fehlte für TTL-Sweep | AST 64→128 bit + free-running 24-bit Multiframe-Counter (`mf_global_cnt_sys`) + `S_DETACH_QUERY/WAIT/CLEAR` States + `REG_AST_DETACH_CNT @ 0x1A4` | `cae0ebc` — Phase B; AST schlüsselt mit ISSI im Top-Block, `last_seen` rollt nach 197 Tagen, Detach-Trigger=mm_pdu_type=1 |
| 2026-04-25 | Stille AST-Slots werden nie geräumt (Zombie-Risiko) — Detach-Path verlässt sich auf NUB-RX-Pfad der noch nicht da ist | AST true dual-port BRAM, neuer Sweeper-FSM (SW_IDLE→READ→CHECK→INVALIDATE) intern im AST-Modul + REG_AST_TTL_MULTIFRAMES @ 0x1A8 (default 84706 ≈ 24 h) + REG_AST_TTL_EVICT_CNT @ 0x1B0 | `e51cc6c` — Phase C; 1 Slot pro Multiframe, kompensiert NUB-RX-Gap zeitbasiert |

### 7.1 M2 erreicht (2026-04-25 12:18 ZULU)

MTP3550 ITSI-Attach erfolgreich auf Build `26191b4`. Counter-Beweis direkt
nach Deploy: `0x190 = 0x0001_0001` (1 Demand → 1 Accept, 1:1), kein Retry-Loop.

Details + Bit-Walk: `PROTOCOL.md §9` und
`docs/references/captures_external_bs_2026-04-25/`.

### 7.2 Offene Lücken zu M3 (Group Call/Voice)

Diese sind für M2 nicht relevant gewesen, werden aber für M3 gebraucht:
- `tetra_subscriber_shadow.v` fehlt (kein permit/LA/home-cell-Lookup pro ISSI) → ✅ Phase A 2026-04-25
- Kein NR/NS-Tracking pro MS (Dialog-PDUs)
- UL-BL-ACK wird parsed, MLE-FSM ignoriert noch
- Kein Retransmit-Loop für verlorene DL-PDUs
- Group-Identity-Attach (echter Path mit dynamischer GILA aus Subscriber-DB)
- Voice-Pfad (CMCE D-SETUP/D-CONNECT, ACELP)
- **UL-RX-Pfad erkennt nur RA-Slot-Bursts** (CB/CUB) — NUB (Normal Uplink
  Burst auf allocated slots, beinhaltet U-ITSI-DETACH, Auth-PDUs, BL-ACK
  nach Attach, Voice) wird vom Sync-Detector durchgelassen. Air-Capture
  2026-04-25 19:16 zeigt 12 Bursts auf-Air vs. nur 3 in `ul_mon`.
  **Konsequenz für Phase B**: Detach-Counter bleibt 0 obwohl MS sauberen
  `U-ITSI-DETACH` sendet. **TTL-Sweep** (Phase C) kompensiert die Lücke
  zeitbasiert. Vollständiger NUB-RX-Pfad-Fix gehört zu M3.1, nicht
  Phase 6. Details: Memory `project_ul_rx_nub_gap.md`.

---

## 8. Zeitplan + Risiken

### 8.1 Zeitplan (Schätzung)

```
Woche 1-3:   M1 — MS sieht BS, RACH sichtbar         ✅ fertig (UL-Decode HW-verifiziert)
Woche 4-8:   M2 — Einbuchen (Stack-Rebuild Bluestation-style)
Woche 9-15:  M3 — Gruppenruf mit Voice-Relay
Woche 16-19: M4 — Einzelrufe + Paging
```

**Gesamtaufwand: ~15-19 Wochen.**

### 8.2 Risiken

| # | Risiko | Impact | Mitigation |
|---|--------|--------|------------|
| 1 | ~~MS-Registration-Blocker~~ ✅ **gelöst 2026-04-25 12:18** durch bit-exakten Gold-Ref MM-Body-Replay (Build `26191b4`) | M2 abgeschlossen | — |
| 2 | FDD RF-Isolation — TX desensibilisiert RX bei Single-Antenna | Reduzierte RX-Empfindlichkeit | Duplexer oder 2 Antennen mit Abstand (Lab: 2 Antennen 10 cm) |
| 3 | UL Timing Advance — MS sendet Burst zu früh/spät | Sync-Fenster-Miss | Sync-Fenster breit (±2 Symbole), bereits implementiert |
| 4 | CUB-Erkennung — kurzer Burst (127 sym), 2 sym Guard | RA-Miss | NTS-Threshold angepasst, Holdoff kurz (verifiziert 41/42) |
| 5 | ACELP Codec-Lizenz | Forschung OK, Produktion problematisch | Ggf. eigene Implementierung aus ETSI-Pseudo-Code |
| 6 | SYSINFO-Frame-Timing — inkonsistente FN → MS verweigert Reg | Sessionsausfall | RTL-TDMA-Timebase (§5) statt SW-Polling |
| 7 | MAC-PDU-Komplexität — Variable-Length + viele PDU-Typen | RTL-Blow-up | `tetra-bluestation` + `osmo-tetra` als PDU-Format-Referenzen |
| 8 | Viterbi für CUB — 84-Bit statt 216-Bit Blöcke | Fragmentiert LMAC | Zweite LMAC-Instanz (~3000 LUT, ~8000 FF) — Resource-OK |
| 9 | Strukturelle Complexity TETRA-LMAC = GSM-BSC-Klasse | Monate statt Wochen realistisch | Offene Architektur-Frage: Rust-BS auf ARM als Alternativ-Weg (widerspricht 2026-04-22-Entscheidung) |

---

## 9. Subscriber-DB / Active Sessions / Profile-Architektur (Phase 6, post-M2)

Für M2-Hardening und M3-Vorbereitung. Trennt persistente Subscriber-/Group-
Whitelist (geändert vom Operator) von volatiler Session-State (geändert
von BS-FSMs).

### 9.1 Datenmodell — drei Tabellen

| Tabelle | Größe | BRAM | Wer schreibt | Inhalt |
|---------|-------|------|--------------|--------|
| **Entity Table** | 256 × 64 bit | 1 BRAM18k | ARM (AXI indirect window 0x180..0x18C) | Persistente Liste aller bekannten ISSI/GSSI mit `profile_id` |
| **Profile Table** | 6 × 32 bit | LUT-RAM | ARM (AXI) | Berechtigungs-Sets (permit/priority/timing) |
| **AST + Group-Cache** | 64 × 256 bit | 1 BRAM18k | MLE-FSM (volatile) | Aktive Sessions: ISSI + last_seen + bis 8 akzeptierte GSSIs + state |

Total: **2 BRAM18k** von 140 verfügbar auf Zynq-7020.

### 9.2 Record-Layouts

**Entity Table (64 bit):**

```
[63:40]  entity_id     24    ISSI ODER GSSI
[39]     entity_type    1    0=ISSI, 1=GSSI
[38:35]  profile_id     4    Index in Profile Table (0..5)
[34: 1]  reserved      34
[ 0]     valid          1
```

**Profile Table (32 bit, 6 Slots):**

```
[31:24]  max_call_duration  8    Sekunden, 0=unlimited, max 255 s
[23:16]  hangtime           8    × 100 ms, max 25.5 s
[15:12]  priority           4
[11: 4]  reserved           8    (encryption_class, dispatcher_allowed später)
[ 3]     permit_voice       1
[ 2]     permit_data        1
[ 1]     permit_reg         1
[ 0]     valid              1
```

Profile 0 = "minimal-permit" (`permit_reg=1`, alles andere 0) — Default
für Auto-Enrollment unbekannter ISSIs/GSSIs.

**AST (256 bit, 64 Slots):**

```
[255:232]  ISSI                  24
[231:208]  last_seen_multiframe  24    24-bit-Counter, rollover ≈ 197 Tage
[207:200]  shadow_idx             8    Backref Entity Table
[199:196]  state                  4    0=FREE, 1=REG, 2=CALL_SETUP, 3=VOICE, 4=PAGING
[195:192]  group_count            4    0..8 gültige GSSIs
[191:  0]  group_list[8]        192    8 × 24 bit GSSI
```

### 9.3 Datenfluss

**Attach (UL `U-LOC-UPDATE-DEMAND`):**

```
1. Entity.query(ISSI, type=ISSI) → record + profile_id
   Profile.lookup(profile_id) → permit_reg?
     ├─ permit_reg=0 → REJECT (D-LOC-UPDATE-REJECT)
     └─ permit_reg=1 → continue
2. Falls miss UND REG_DB_POLICY[0] (accept_unknown)=1:
     Entity.alloc → write {ISSI, profile_id=0, valid=1}
3. (Optional) MS sendet GSSI-Liste über LocUpdate-Demand-IE
   `group_identity_location_demand` ODER separates
   `U-ATTACH-DETACH-GROUP-IDENTITY`.
   Pro vom MS gewünschter GSSI:
     Entity.query(GSSI, type=GSSI) → profile_id
     Profile.lookup(profile_id) → permit_voice/data → accept_or_reject
4. AST.query(ISSI):
     hit  → reuse slot, update last_seen, group_list
     miss → AST.alloc → AST.write {ISSI, last_seen=now, state=REG, groups[]}
5. Build D-LOC-UPDATE-ACCEPT mit GILA aus AST-group_list (nicht hardcoded)
6. Send AL-SETUP (SCH/HD) + Accept (SCH/F) two-phase (wie M2)
```

**Detach (UL `U-ITSI-DETACH`, mm_type=1):**

```
AST.query(ISSI):
  hit  → AST.write(slot, valid=0)  + counter mle_detach_cnt++
  miss → ignore (MS detached without ever attached)
Kein DL-ACK (ETSI: ITSI-DETACH ist one-way).
Entity Table NICHT angefasst — Subscriber bleibt berechtigt.
```

**TTL-Sweep (jede Multiframe = 1.02 s, neue FSM `tetra_ast_ttl_sweeper.v`):**

```
Free-running 24-bit Multiframe-Counter `now`.
For each AST slot where valid=1:
  if (now - last_seen) > REG_AST_TTL_MULTIFRAMES (default 84706 ≈ 24h):
    AST.write(slot, valid=0)
```

`last_seen` wird bei JEDER UL-Aktivität dieser ISSI aktualisiert (Demand,
BL-ACK, MAC-U-BLCK, U-RELEASE, U-DETACH selbst), nicht nur beim Attach.

### 9.4 Empirie zur TTL-Wahl (2026-04-25 Beobachtung)

MTP3550 sendet **keine periodischen Updates** im Idle. Beobachtungs-Session
12:18..14:22 zeigte:
- 5 Demands bei 5 Power-Cycles
- ~1.5 h Stille zwischen den Cycles
- keine spontanen Re-Registrations

→ TTL=24h als Default ist deutlich konservativer als "MS wirklich verloren",
und passt zu ETSI `T354 REGISTRATION_TIMER` (auch 24h-default).

### 9.5 AXI-Lite Konfiguration (neue Regs)

| Reg | Felder | Default | Funktion |
|-----|--------|---------|----------|
| `0x180..0x18C` | bestehend | — | Entity Table indirect window |
| (neu) Profile Table indirect window | im 0x18x-Block | — | ARM schreibt Profile |
| `0x1A4` | `[15:0]` mle_detach_cnt | 0 | Diagnose |
| `0x1A8` | `[31:0]` ast_ttl_multiframes | 84706 (≈24h) | TTL-Schwelle |
| `0x1AC` | `[0]` accept_unknown<br>`[1]` auto_enroll_default_profile | 1, 0 | Policy |

### 9.6 Operator-Schnittstelle

**ARM-Daemon `tetra_web`** (mongoose-basierter Mini-HTTP-Server):

| Endpoint | Funktion |
|----------|----------|
| `GET /api/entities` | Dump aller Subscriber/Groups |
| `POST /api/entities` | Add/Update mit `{entity_id, type, profile_id}` |
| `DELETE /api/entities/{ID}` | Entry invalidieren |
| `GET /api/profiles` | Profile-Liste |
| `POST /api/profiles/{ID}` | Profile-Update |
| `GET /api/sessions` | Live-AST-Dump (über AXI) |
| `GET /` | statisches `index.html` mit JS-Frontend |

Persistenz: `/var/lib/tetra/entities.tsv`, `/var/lib/tetra/profiles.tsv`.
`inotify`-Watcher → bei Datei-Änderung sofortiger BRAM-Sync (z.B. SSH-Edit
schreibt sofort durch).

### 9.7 Roadmap (Phasen)

| Phase | Inhalt | Status |
|-------|--------|--------|
| **A** | Shadow-Lookup-Pfad in MLE-FSM, Permit-Check, REJECT-Encoder | ✅ 2026-04-25 (Commit `2af8e8c`, TBs 10/10) |
| **B** | Detach-Pfad + AST 64→128 bit (last_seen 24 bit + shadow_idx + state) | ✅ 2026-04-25 (Commit `cae0ebc`, TBs 12/12). Profile-Table → Phase D. |
| **C** | TTL-Sweep FSM (intern in AST, true dual-port BRAM) | ✅ 2026-04-25 (Commit `e51cc6c`, TBs 16/16). REG_AST_TTL_MULTIFRAMES @ 0x1A8 + REG_AST_TTL_EVICT_CNT @ 0x1B0. |
| **D** | GILA-Encoder mit GSSI/lifetime/class aus Lookup statt hardcoded | ⏳ Plan |
| **E** | WebUI + inotify-Watcher + Auto-Enroll (ARM-Daemon) | ⏳ Plan |

Auto-Enroll wurde bewusst aus Phase A herausgenommen — landet in Phase E
als ARM-Daemon-Job (UL-mon-Watcher → db.tsv-Update → BRAM-Sync), das
spart einen Shadow-Schreibport-Mux im RTL.

---

## 10. Referenzen

- `docs/HARDWARE.md` — Plattform, AD9361, AXI-Regs, CDC, Timing
- `docs/PROTOCOL.md` — TETRA-Protokoll, ETSI-Referenz, bluestation-Vergleich
- `docs/OPERATIONS.md` — Deploy-Workflow, Tests, Debugging
- `.ralph/chat.md` — Kevin ↔ Ralph Arbeits-Kanal
- `.ralph/fix_plan.md` — aktueller Fix-Plan
- EN 300 392-2: TETRA V+D Air Interface
- EN 300 395-2: TETRA Speech Codec
- osmo-tetra (Harald Welte): Open-Source TETRA Decoder
- tetra-bluestation (MidnightBlueLabs, Apache-2.0): Rust-Referenz BS-Implementierung
- SDRSharp.Tetra.dll: Windows TETRA Plugin (reverse-engineered)
