# TETRA Base Station Stack — Implementierungsplan

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Ziel:** Vollständige TETRA BS — Einbuchen, Gruppenrufe, Einzelrufe
**Erstellt:** 2026-04-17
**Zuletzt aktualisiert:** 2026-04-22

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
- Uplink-Empfang (NUB/CUB, NTS-Sync, RACH)
- Dynamisches TX TDMA Scheduling
- MAC Layer (L2) auf ARM
- MLE/CMCE (L3) auf ARM
- TETRA Voice Codec (ACELP 4.8 kbit/s)

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

### M2.1 — SCH/HU Channel Decoding für CUB (RTL + SW, hoch)
- CUB: 84 type-5 Bits (2×42) statt 216 (NDB)
- Viterbi/Deinterleaver unterstützen nur 216-Bit-Blöcke
- **Empfehlung:** Zweite LMAC-Instanz für UL (~3000 LUT + 8000 FF, bei 10% Auslastung problemlos)
- **ETSI:** EN 300 392-2 §8.2.3, §9.4.4.2.3

### M2.2 — MAC Layer (L2) auf ARM (SW, hoch)
- **Neue Dateien:** `sw/tetra_mac.c`, `sw/tetra_mac.h`
- MAC-ACCESS PDU parsen (RACH-Request)
- MAC-RESOURCE PDU senden (Slot-Zuweisung)
- MAC-DATA für L3-Transport
- Fragmentierung/Reassembly
- **ETSI:** EN 300 392-2 §21.1-21.4

### M2.3 — MLE (L3) auf ARM: Registration (SW, hoch)
- **Neue Dateien:** `sw/tetra_mle.c`, `sw/tetra_mle.h`
- U-LOCATION UPDATE DEMAND empfangen
- D-LOCATION UPDATE ACCEPT senden
- Subscriber-Datenbank (ISSI → registriert, LA)
- **ETSI:** EN 300 392-2 §16, §14.5

### M2.4 — Per-Slot TX-Inhalt (RTL + SW, mittel)
- Aktuell: alle NDB-Slots senden denselben Filler
- **Ansatz:** AXI-Lite Registerbank um per-Slot NDB-Register erweitern (4×14 Register)
- `tetra_zynq_top.v`: per-Slot Daten an burst_mux statt Replikation
- `tetra_hal.c`: per-Slot NDB-Write-Funktionen
- **ETSI:** EN 300 392-2 §21.2

### M2.5 — SYSINFO Frame Counter Update (SW, niedrig)
- Frame/Multiframe im SYSINFO muss laufend aktualisiert werden
- ARM pollt `REG_TX_TDMA` und schreibt SYSINFO-Register (~17 Hz)
- **ETSI:** EN 300 392-2 §18.4.2.1

### M2 Abhängigkeiten
```
M2.1 ── hängt von M1.5/M1.6 ab
M2.2 ── hängt von M2.1 ab
M2.3 ── hängt von M2.2 ab
M2.4 ── parallel zu M2.2 (RTL + SW)
M2.5 ── unabhängig
```

**Aufwand:** ~3-4 Wochen

---

## M3: Gruppenruf mit Sprache

**Ziel:** BS initiiert/akzeptiert Gruppenruf. Mehrere MS in der Gruppe hören Sprache.

### M3.1 — CMCE Group Call Setup (SW, hoch)
- **Neue Dateien:** `sw/tetra_cmce.c`, `sw/tetra_cmce.h`
- D-SETUP → D-CONNECT → U-TX DEMAND → D-TX GRANTED → D-TX CEASED
- GSSI (Group Short Subscriber Identity) Verwaltung
- **ETSI:** EN 300 392-2 §14.7

### M3.2 — TCH Voice Channel (RTL + SW, hoch)
- TCH/S: 274 type-1 Bits pro Frame (137 class-1 + 137 class-2)
- Stealing Bits (HA/HB) zeigen TCH vs SCH — `tetra_steal_detect` existiert
- **DMA MM2S Pfad nötig:** AXI-DMA Bridge um TX-Richtung erweitern (PS → PL)
- 14 Register pro Slot @ 70 Hz via AXI-Lite ist grenzwertig für Voice
- **ETSI:** EN 300 392-2 §8.2.3, §8.3

### M3.3 — TETRA Voice Codec ACELP (SW, sehr hoch)
- 4.567 kbit/s, 137 Bits pro 30ms Frame
- ETSI Referenz-Codec (C-Quellcode) portieren auf ARM
- Cortex-A9 @ 667 MHz: ACELP braucht < 1 MIPS → kein Problem
- `tetraVoiceDec.dll` im Projekt-Root → Windows-Decoder vorhanden, Linux-Port nötig
- **ETSI:** EN 300 395-2

### M3.4 — Voice Relay (SW, mittel)
- Gruppenruf: ein MS sendet (PTT), BS empfängt und retransmittiert an alle
- Kein Mixing nötig — nur Relay der Codec-Frames UL → DL
- Latenz-Budget: ein TDMA Frame (56.67ms)

### M3.5 — AACH Update während Call (SW, niedrig)
- AACH muss Slot-Zuweisung (Traffic vs Free) reflektieren
- **ETSI:** EN 300 392-2 §18.5.1

**Aufwand:** ~4-6 Wochen (Voice Codec ist höchstes Risiko)

---

## M4: Einzelrufe

**Ziel:** Punkt-zu-Punkt-Ruf zwischen zwei MS über die BS.

### M4.1 — CMCE Individual Call (SW, mittel)
- D-SETUP nur an gerufenes MS (per ISSI adressiert)
- D-CONNECT / U-CONNECT Handshake
- D-RELEASE für Rufabbau
- Simplex (PTT) = wie Gruppenruf; Duplex braucht 2 Slots
- **ETSI:** EN 300 392-2 §14.7, §14.8

### M4.2 — Duplex Slot Management (SW, mittel)
- Full-Duplex: 2 Slots (je Richtung einer)
- burst_mux per-Slot Infrastruktur von M2.4 reicht

### M4.3 — Paging (SW, mittel)
- D-ALERT PDU im BNCH um gerufenes MS aufzuwecken
- `tetra_bnch_encode()` kann Paging-PDUs kodieren (nur Info-Bits ändern)
- Paging-Antwort kommt über RACH (bereits in M2)
- **ETSI:** EN 300 392-2 §14.6

**Aufwand:** ~2-3 Wochen (inkrementell auf M3)

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

### FPGA RTL
| Meilenstein | Module | Änderung |
|-------------|--------|----------|
| M1 | `tetra_sync_detect.v` | NTS-Modus (seq_select=0) für UL |
| M1 | `tetra_burst_demux.v` | NUB/CUB Feldpositionen |
| M1 | `tetra_zynq_top.v` | seq_select umschaltbar |
| M2 | `tetra_axi_lite_regs.v` | Per-Slot NDB Register |
| M2 | `tetra_zynq_top.v` | Per-Slot Verdrahtung zu burst_mux |
| M2 | Neue LMAC-Instanz | UL Channel Decoding (CUB 84-Bit) |
| M3 | `tetra_axi_dma_bridge.v` | MM2S Pfad (PS → PL) |

### ARM Software (neu)
| Datei | Meilenstein | Beschreibung |
|-------|-------------|--------------|
| `sw/tetra_mac.c/.h` | M2 | MAC Layer (Slot-Zuweisung, PDU Parsing) |
| `sw/tetra_mle.c/.h` | M2 | MLE (Location Update, Subscriber DB) |
| `sw/tetra_cmce.c/.h` | M3 | CMCE (Gruppenruf, Einzelruf) |
| `sw/tetra_codec.c/.h` | M3 | ACELP Voice Codec Wrapper |
| `sw/tetra_bs_main.c` | M2 | Haupt-BS-Applikation |

### ARM Software (bestehend)
| Datei | Meilenstein | Änderung |
|-------|-------------|----------|
| `sw/tetra_hal.c/.h` | M1/M2 | ACCESS_DEFINE, per-Slot NDB, Frame Counter |

---

## Zeitplan (geschätzt)

```
Woche 1-3:   M1 — MS sieht BS, RACH sichtbar
Woche 4-7:   M2 — Einbuchen (Location Update)
Woche 8-13:  M3 — Gruppenruf mit Sprache
Woche 14-16: M4 — Einzelrufe
```

**Gesamtaufwand: ~12-16 Wochen**

---

## Referenzen

- EN 300 392-2: TETRA V+D Air Interface (Hauptspezifikation)
- EN 300 395-2: TETRA Speech Codec
- EN 300 392-7: Security (erstmal überspringen)
- osmo-tetra: Open-Source TETRA Decoder (Referenz für PDU-Formate)
- SDRSharp.Tetra.dll: Windows TETRA Plugin (bereits reverse-engineered)
