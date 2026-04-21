# Plan — TDMA-Timebase & Slot-Scheduling in RTL

**Erstellt:** 2026-04-20
**Status:** Entwurf, wartet auf Review
**Ziel:** Die Gold-Zelle 1:1 nachbilden. Slot-Inhalt, Rotationen und
Systemzeit müssen deterministisch pro (TN, FN, MN, Hyperframe) sitzen.
Die einzige Instanz, die "wo bin ich?" weiß, ist das RTL.

---

## 1. Warum

- SW-getriebenes Scheduling ist fragil. `tetra_sysinfo` schreibt in
  Registern, die RTL konsumiert, sobald `tx_slot_pulse` kommt — SW muss
  also die Register rechtzeitig *vor* dem Puls umrühren. Jedes Paging,
  jeder Kontextswitch → falscher Burst-Typ in falschem Slot.
- TDMA-Zähler existiert heute nur in `tetra_zynq_top.v` (`tx_frame_cnt_sys`,
  `tx_mf_cnt_sys`), aber das **Scheduling** (welcher Burst, welche Rotation)
  sitzt in `always @(*)`-Blöcken mit hartkodierten Mustern (Zeilen 694–756),
  und die **Payload-Bytes** kommen asynchron aus SW-Registern. Das Ergebnis
  hat 1 % NDB-Decoderate auf unserem eigenen WAV (vs. 100 % auf Gold).
- Systemzeit (SYNC-PDU TN/FN/MN/HN) muss den Burst beschreiben, der in
  genau dem Moment rausgeht. Heute schreibt SW den Timestamp *vor*
  `tx_slot_pulse` — race auf eine halbe Frame-Dauer.
- BSCH/BNCH-Rotationen und per-Slot-Burst-Type sind deterministisch aus
  (TN, MN) ableitbar. Alles was nicht aus der aktuellen Zeit abgeleitet
  werden kann, ist ein Bug.

**Leitprinzip:** RTL hält die Uhr, das Sende-Raster **und die
zeitabhängigen PDUs**. SW liefert nur langsam ändernde Payload-Körbe
(Cell-Config, SYSINFO, MCCH, NULL-PDU). Die per-Slot variablen
Anteile (BSCH-SYNC-PDU mit TN/FN/MN, AACH mit FN-abhängiger Semantik)
werden im RTL aus der Timebase + statischen Config-Registern kodiert —
SW ist aus dem per-Slot-Takt raus.

---

## 2. Ist-Stand (was da ist)

| Modul / Datei | Rolle heute | Problem |
|---|---|---|
| `rtl/tetra_zynq_top.v:616–652` | Frei laufender Frame-Counter (TN/FN/MN) auf `sym_en_sys_w` | Zählt korrekt, aber **niemand lädt ihn nach BSCH-Sync** — er startet willkürlich bei (TN=0, FN=1, MN=1) |
| `rtl/tetra_zynq_top.v:694–756` | Per-Slot burst_type/enable/ndb2 via `always @(*)` | Harte Muster, keine Tabelle, kein SW-Zugriff |
| `rtl/tx/tetra_burst_builder.v` | Formt einen Burst aus Eingangs-Bussen | OK — `burst_type_sys` + `burst_ndb2_sys` sind die richtigen Knöpfe |
| `sw/tetra_hal.c` | Schreibt SB_SB1 / SB_BKN2 / SB_BB / NDB_BLK1/2 / BNCH_BLK1/2 / MCCH_BLK1/2 | Schreibt **kontinuierlich** dieselben Werte; Systemzeit in SB_BKN1 steht in der Frame, in der SW das Register gerade schreibt — nicht in der, in der gesendet wird; **NULL PDU Builder wurde in 06dddab entfernt, muss reaktiviert werden** |
| AXI-Lite 0x38 `TX_TDMA` | SW-Readback (MF/FN/TN) | Read-only. Kein Write-Sync, keine IRQ |

Gold-Zelle (gemessen, 60 s WAV, `decode_dl.py` nach allen Fixes):
- 903 SDB + 295 NDB + 1 empty = 1199/1200 Slots
- **Jeder Slot trägt einen vollen Burst** — keine echten PA-Ramp-Down-
  Slots. Frühere "20 % empty"-Zahlen waren Decoder-Miss vor den
  NTS2-/LAYOUTS-/Phasen-Fixes.
- TN2/3/4: SDB 100 %
- TN1 (ETSI, intern TN=0): SDB bei F18+MN%4==2 (BSCH-Rotation); sonst
  NDB mit SYSINFO oder NULL-PDU (genaue Verteilung siehe Verifikation
  unten)

Unsere Zelle (gleicher Code, aber nach jeder Deploy-Iteration andere Startzeit):
- Burst-Typ-Verteilung hängt vom Boot-Zeitpunkt ab (TDMA-Counter startet bei 1/1)
- NDB-Rate auf eigenem WAV (decode_dl.py): 1 % — Timing-Jitter an Burst-Rändern,
  weil BB/AACH aus einem anderen Slot gelesen wird als die NDB-Blocks

---

## 3. Ziel-Architektur

```
 ┌──────────────────────────────────────────────────────────────────┐
 │                     tetra_tdma_timebase                          │
 │  TN[1:0] FN[4:0] MN[5:0] HN[5:0]  (+1 pro tx_slot_pulse)        │
 │  sync_load_strobe (AXI)  → SW lädt absolute Zeit bei Boot       │
 │  tdma_tick  → fires 1 Sys-Takt vor slot_pulse                   │
 └─┬───────────────────────────┬──────────────────────────┬─────────┘
   │ (TN, FN, MN, HN)          │ (TN, FN, MN, HN)         │ (FN)
   ▼                           ▼                          ▼
 ┌────────────────┐  ┌──────────────────────┐  ┌──────────────────┐
 │ tetra_slot_    │  │  tetra_bsch_encoder  │  │  tetra_aach_     │
 │ schedule       │  │  (SYNC-PDU →         │  │  encoder         │
 │ BRAM 288×16    │  │   CRC16 + tail +     │  │  (14 bit info →  │
 │ (MN%4,FN,TN)   │  │   RCPC 2/3 + inter + │  │   RM(30,14))     │
 │  → entry       │  │   scramble → 120 bit)│  │  → 30 bit        │
 └─┬──────────────┘  └──────────────┬───────┘  └────────┬─────────┘
   │ schedule_entry                 │ sb_sb1            │ bb
   ▼                                ▼                   ▼
 ┌────────────────────────────────────────────────────────────────┐
 │                   tetra_slot_content_mux                       │
 │  payload_class wählt: {BSCH+BNCH+AACH(SDB),                    │
 │                        MCCH-Block, NDB-SYSINFO, NULL-PDU,     │
 │                        empty}                                  │
 │  Quellen: RTL-Encoder (BSCH, AACH) + SW-Register (BNCH, MCCH,  │
 │           NDB-Filler) + Register (NULL-PDU 16 Byte)           │
 └─┬──────────────────────────────────────────────────────────────┘
   │ {block1, block2, bb, sb1, bkn2, nts_sel, burst_type}
   ▼
 ┌────────────────────────────────────────────────────────────────┐
 │                    tetra_burst_builder (existiert)             │
 └────────────────────────────────────────────────────────────────┘

 ┌────────────────────────────────────────────────────────────────┐
 │  Cell-Config-Register (AXI, statisch; SW schreibt bei Boot +   │
 │  bei Konfig-Änderung): MCC, MNC, ColourCode, SystemCode,       │
 │  SharingMode, TS-ReservedFrames, U-plane DTX, …                │
 │  → gehen direkt in BSCH-Encoder und (teilweise) in AACH-       │
 │    Encoder                                                      │
 └────────────────────────────────────────────────────────────────┘
```

---

## 4. Bausteine (8 Teile, in Reihenfolge)

### Stufe 1 — `tetra_tdma_timebase.v` (neues Modul)

**Zweck:** Kanonischer TDMA-Counter. Ersetzt die `tx_*_cnt_sys`-Register
im Top.

**Ports:**
```verilog
module tetra_tdma_timebase (
    input  wire       clk_sys, rst_n_sys,
    input  wire       sym_en,              // 18 kHz strobe
    // SW-Sync (1 Zyklus-Strobe)
    input  wire       sync_load_strobe,
    input  wire [1:0] sync_tn_in,          // 1..4 normalized to 0..3 intern
    input  wire [4:0] sync_fn_in,          // 1..18
    input  wire [5:0] sync_mn_in,          // 1..60
    input  wire [5:0] sync_hn_in,          // 1..60
    // Outputs
    output reg  [7:0] sym_cnt,             // 0..254
    output reg  [1:0] tn,                  // 0..3  (ETSI-TN = tn+1)
    output reg  [4:0] fn,                  // 1..18
    output reg  [5:0] mn,                  // 1..60
    output reg  [5:0] hn,                  // 1..60
    output reg        slot_pulse,          // 1 Zyklus bei sym_cnt=0 Übergang
    output reg        tdma_tick            // 1 Zyklus *davor* (Preload-Window)
);
```

**Invariant:** `sync_load_strobe` lädt synchron beim nächsten `sym_en`,
nicht asynchron.

**Test:** Unit-TB, Counter-Wrap bei MN=60, Hyperframe-Inkrement.

---

### Stufe 2 — AXI-Lite `TX_TDMA_SYNC` Register (SW → Timebase)

**Neue Register:**
| Offset | Name | Bits | Semantik |
|---|---|---|---|
| 0x140 | TX_TDMA_LOAD | `[1:0]` TN, `[6:2]` FN, `[12:7]` MN, `[18:13]` HN, `[31]` STROBE | Write 1 in STROBE triggert Load. **Adresse 0x140 statt geplant 0xC0**, weil 0xC0/0xC4 schon `MCCH_BLK1_0/1` belegen. |
| 0x144 | TX_TDMA_STATE | RO, Layout `[1:0]` TN, `[6:2]` FN, `[12:7]` MN, `[18:13]` HN, `[26:19]` sym_cnt, `[31:27]` reserved | Für Debug/IRQ-ACK |

**SW-Nutzung:** Nach BSCH-Acquisition liest RX die aktuelle NetworkTime,
schreibt sie (mit +N Slots Korrektur für TX-Latenz) in TX_TDMA_LOAD mit
STROBE=1. RTL übernimmt beim nächsten `sym_en`.

**Test:** Deploy, SW setzt (TN=0, FN=18, MN=42), liest TX_TDMA_STATE,
erwartet Inkrement-Verhalten.

---

### Stufe 3 — `tetra_slot_schedule.v` + AXI-Fenster

**Zweck:** Tabellen-Lookup `(MN%4, FN, TN) → burst_schedule_entry` statt
`always @(*)`-Kaskade oder hartkodierter MN-Regel.

**Speicher:** 4 × 18 × 4 = 288 Einträge × 16 Bit = 576 Byte Dual-Port-BRAM
(AXI-Port schreibt, RTL-Port liest — keine Schedule-Updates während
Lesezugriff nötig). Passt in 1× RAMB18E1 mit viel Platz übrig.

**Dual-Port als Laufzeit-Vorsorge:** Phase 4 nutzt die Tabelle statisch
(Boot-Preset), aber Phase 5 (Traffic) muss Einträge zur Laufzeit ändern,
wenn Rufe starten/enden. Dual-Port von Anfang an spart späteren Umbau.
Race-Vermeidung bleibt SW-Regel ("schreibe Eintrag X nicht wenn er in
den nächsten 2 Frames gelesen wird") — kein Commit-Strobe-Overhead.

**Adressierung intern:** `{MN[1:0], FN-1, TN}` als 9-Bit Adresse
(4 × 18 × 4 = 288 < 512). Falls FN-1 unbequem wegen 1-basiert: einfach
`FN[4:0]` direkt nehmen, Slot 0 bleibt ungenutzt (80 Byte Slack).

**Design-Entscheidung:** Vollständige Tabelle ohne Overlay / ohne
Runtime-Regel. Alle Scheduling-Muster sind reine Daten im BRAM, SW lädt
sie bei Boot. Keine MN-Rotation-Logik im RTL.

**Eintrag-Format (16 bit — von Anfang an Pointer-basiert, Phase-5-
tauglich):**
```
[15:12] payload_class  (0=STATIC_BROADCAST, 1=NULL_PDU, 2=TCH,
                        3..15 reserved für Phase 5)
[11:6]  payload_idx    (6 Bit: Variant/Slot/Channel-Nummer innerhalb
                        der Klasse — reicht für 64 TCH-Kanäle o.ä.)
[5:4]   burst_type     (00=NDB, 01=SDB, 10=reserved, 11=idle)
[3]     ndb2           (Training Seq 2 vs 1)
[2]     enable         (0 = blank burst, kein RF)
[1]     sys_time_inject (1 = SB_BKN1 Systemzeit im RTL patchen — nur SDB)
[0]     reserved
```

Damit ist die Tabelle `288 × 16 Bit = 576 Byte` — immer noch deutlich
unter einem RAMB18 (2 kByte). Gewinn: der `payload_src`-Namespace
skaliert ohne Schedule-Breiten-Änderung, wenn Phase 5 Traffic-Channels
und weitere Quellen bringt.

**Mapping in Phase 4 (aktuell):**
```
class=STATIC_BROADCAST, idx=0 → NDB_SYSINFO
class=STATIC_BROADCAST, idx=1 → MCCH
class=STATIC_BROADCAST, idx=2 → BNCH
class=STATIC_BROADCAST, idx=3 → SB
class=STATIC_BROADCAST, idx=4 → NDB2_half1_bnch
class=STATIC_BROADCAST, idx=7 → empty (enable=0 bevorzugt)
class=NULL_PDU, idx=0       → statisches Pattern aus NULL_PDU_BITS-Register
class=TCH, idx=0..63        → reserviert Phase 5
```

**Payload-Quellen im Detail:**
- `NDB_SYSINFO` — heutiger Filler (SCH/F MAC-BROADCAST SYSINFO), für Slots
  auf denen SYSINFO erwartet wird (BCCH-Rolle).
- `MCCH` — ACCESS-DEFINE SCH/F, feste Slot-1-Rolle (FN=18 nur).
- `BNCH` — SYSINFO SCH/HD als BKN2 einer SDB-Rotation.
- `NULL_PDU` — **MAC-RESOURCE NULL PDU** (Slot ist belegt, kein Inhalt).
  War bis Commit `06dddab` im SW, wurde irrtümlich entfernt mit Begründung
  "Gold schickt überall SYSINFO" — stimmt nicht. Gold sendet auf TN=1
  (ETSI 1) BKN1 von NDB2-Bursts statisches NULL PDU
  (`0x0010_8000_0000_…_0000`, gemessen 2026-04-20, alle 97/97 Vorkommen
  bit-identisch). Storage: 16-Byte Register-Bank, siehe Stufe 4.
- `NDB2_half1_bnch` — für das Sonderfall-BNCH-Muster auf NDB2-Bursts
  (BKN2 carrying BNCH auf TN=1 FN=18 in DMO-Zellen; siehe Decoder).
- `empty` — Schedule-Eintrag deaktiviert Burst (enable=0).

**AXI-Fenster:** `0x400..0x63F` (576 Byte, 144 32-bit-Words, jedes Word
aggregiert 2 Schedule-Einträge à 16 Bit — unteres 16 Bit = gerade
Adresse, oberes 16 Bit = ungerade Adresse). Erfordert Erweiterung der
AXI-Adress-Dekodierung auf 9-Bit Word-Address (`[10:2]`) — bisher 7-Bit
bis 0x1FC. Ursprünglich geplant bei `0x100..0x33F`, verschoben wegen
Kollision mit BNCH_BLK1/2 (0x100..0x12C) und TX_TDMA_LOAD/STATE
(0x140/0x144). SW schreibt Gold-Muster bei Boot (`memcpy` 576 Byte),
in Phase 5 Laufzeit-Updates pro Call-Event.

**Gold-Preset-Generator:** `scripts/gold_schedule.py` erweitern um eine
Funktion die das 288-Byte-Blob produziert (C-Header oder Binär).
SW lädt es per `memcpy` ins AXI-Fenster.

**Muster (aus realer Gold-Zelle, MCC=262 MNC=106):**
- TN=1,2,3 (ETSI 2,3,4): alle 288 Einträge → SDB mit sys_time_inject=1
- TN=0 (ETSI 1):
  - FN=18 & MN%4==2: SDB (BSCH-Rotation hit, sys_time_inject=1)
  - FN=18 & MN%4!=2: MCCH (ACCESS-DEFINE, `class=STATIC_BROADCAST,
    idx=MCCH`)
  - FN≠18, MN%4==0: NDB mit SYSINFO (`class=STATIC_BROADCAST,
    idx=NDB_SYSINFO`)
  - FN≠18, MN%4!=0: NDB mit NULL PDU (`class=NULL_PDU, idx=0`,
    statisches Pattern, Gold-bestätigt 97/97 bit-identisch)
- Alle TN=0-Einträge mit `enable=1` — Gold sendet durchgehend, kein
  PA-Ramp-Down.

**Offen (Verifikations-Task):** Vor Produktiv-Preset prüfen per Spectrum-
Analyzer oder bias-korrigiertem RSSI-Plot der Gold-WAV, ob Gold
tatsächlich auf TN=0-nicht-Broadcast-Slots sendet oder dort doch PA
absenkt. Falls ramp-down: die entsprechenden Einträge auf `enable=0`
stellen. Script-Idee: `scripts/wav_slot_rssi.py` — pro Slot mittlere
Amplitude messen, Histogramm über 60 s.

**Test:** Tabelle mit Gold-Preset laden, Zähler laufen lassen, RTL-Sim
prüft: schedule_entry matcht erwartetes Muster für jeden
(TN, FN, MN%4)-Eintrag über 4 Multiframes (volle MN%4-Abdeckung).

---

### Stufe 3.5 — `tetra_bsch_encoder.v` + Cell-Config-Register

**Zweck:** BSCH (SYNC PDU) komplett im RTL kodieren. SW ist damit raus
aus dem per-Slot-Encoding-Takt.

**SYNC-PDU-Inhalt (60 Type-1-Bits, ETSI EN 300 392-2 §18.5.21,
verifiziert gegen `scripts/decode_dl.py:663–690` parse_sysinfo_sb):**

| Bits | Feld | Quelle |
|---|---|---|
| [0:3]   | System-Code (4) | AXI-Register (Reset-Default = TETRA V+D, Sync-PDU-Type) |
| [4:9]   | Colour-Code (6) | AXI-Register (`COLOUR_CODE` 0x10, existiert) |
| [10:11] | Timeslot-Number (2) | **Timebase** (TN, air-side 0..3) |
| [12:16] | Frame-Number (5) | **Timebase** (FN, air-side 0..17) |
| [17:22] | Multiframe-Number (6) | **Timebase** (MN, air-side 0..59) |
| [23:24] | Sharing-Mode (2) | AXI-Register |
| [25:27] | TS-Reserved-Frames (3) | AXI-Register |
| [28]    | U-plane-DTX (1) | AXI-Register |
| [29]    | Frame-18-Extension (1) | AXI-Register |
| [30]    | Reserved (1) | konstant 0 |
| [31:40] | MCC (10) | AXI-Register |
| [41:54] | MNC (14) | AXI-Register |
| [55:56] | Neighboring-Cell-Broadcast (2) | AXI-Register |
| [57:58] | Cell-Service-Level (2) | AXI-Register |
| [59]    | Late-Entry-Supported (1) | AXI-Register |

Summe: 60 Bit ✓.

**Wichtig:** Die SYNC-PDU enthält **kein** Hyperframe-Feld und **keinen**
Cipher-Key-Flag — diese sitzen in SYSINFO Type 4 (BNCH, SW-managed über
die BNCH-Payload-Bank), nicht in BSCH. Der BSCH-Encoder bekommt also
nur TN/FN/MN von der Timebase, kein HN.

**Variable Inputs von Timebase:** 13 Bit (TN+FN+MN). Alles andere ist
Cell-Config, selten geschrieben, auf zwei AXI-Register verteilt
(CELL_CFG_0/1).

**Coding-Pipeline:**
```
60 type-1 ──CRC16──► 76 ──+4 tail──► 80 ──RCPC 2/3──► 120 ──interleave 8×15──► 120 ──scramble(init=3)──► 120 type-5
```

Alle Blöcke existieren bereits als Module (`tetra_crc16.v`,
`tetra_rcpc_encoder.v`, `tetra_interleaver.v`, `tetra_scrambler.v`).
Für den Encoder wird eine FSM gebaut die diese Blöcke nacheinander
füttert.

**Budget:** ~400 Sys-Takte = 4 µs pro BSCH-Encode bei 100 MHz. Muss
vor `slot_pulse` fertig sein — `tdma_tick` ist 1 Zyklus vor dem Puls
zu früh. Lösung: Encoder läuft bei `tdma_tick_early` (neues Signal,
z.B. 500 Zyklen vor `slot_pulse`) oder fest ab Slot-Mitte des
*Vorgänger*-Slots. Timing: 14 ms Slot / 4 µs Encoding = 3500× Luft.

**Ports:**
```verilog
module tetra_bsch_encoder (
    input  wire        clk_sys, rst_n_sys,
    // Variable Inputs (Timebase, air-side 0-based)
    input  wire [1:0]  tn,                  // SYNC[10:11]
    input  wire [4:0]  fn,                  // SYNC[12:16]
    input  wire [5:0]  mn,                  // SYNC[17:22]
    // Static Inputs (Cell-Config aus AXI-Registern)
    input  wire [3:0]  sys_code,            // SYNC[0:3]
    input  wire [5:0]  colour_code,         // SYNC[4:9]
    input  wire [1:0]  sharing_mode,        // SYNC[23:24]
    input  wire [2:0]  ts_reserved_frames,  // SYNC[25:27]
    input  wire        uplane_dtx,          // SYNC[28]
    input  wire        frame18_ext,         // SYNC[29]
    input  wire [9:0]  mcc,                 // SYNC[31:40]
    input  wire [13:0] mnc,                 // SYNC[41:54]
    input  wire [1:0]  neigh_cell_bc,       // SYNC[55:56]
    input  wire [1:0]  cell_service_level,  // SYNC[57:58]
    input  wire        late_entry_support,  // SYNC[59]
    // Trigger
    input  wire        encode_strobe,
    // Output
    output reg  [119:0] sb_sb1_encoded,
    output reg          sb_sb1_valid
);
```

**Neue AXI-Register (Cell-Config-Block, ab 0xE0):**
| Offset | Name | Semantik |
|---|---|---|
| 0xE0 | CELL_CFG_0 | `[3:0]` sys_code, `[5:4]` sharing_mode, `[8:6]` ts_res_frames, `[9]` uplane_dtx, `[10]` frame18_ext, `[12:11]` neigh_cell_bc, `[14:13]` cell_service_level, `[15]` late_entry_support, `[31:16]` reserved |
| 0xE4 | CELL_CFG_1 | `[9:0]` mcc, `[23:10]` mnc, `[31:24]` reserved |
| (ColourCode bleibt in 0x10) | | |

**Hinweis Air-Interface-Encryption / Second-Control-Channel:** Gehören
zu SYSINFO Type 4 (BNCH-Payload), nicht zur SYNC-PDU. Werden über die
BNCH-Payload-Bank (SW) gesetzt, nicht hier.

**Test:** RTL-Sim, bekannte (TN, FN, MN) + Config → erwartete 120 Type-5
Bits (Referenz aus Python-Kopie der SW-Kette, bit-exact-Vergleich).

---

### Stufe 3.7 — `tetra_aach_encoder.v`

**Zweck:** AACH (Access Assignment Channel) ebenfalls im RTL kodieren.
Inhalt variiert per Slot nach FN/TN-Logik, Encoding ist Reed-Muller(30,14).

**AACH-Inhalt (14 Type-1-Bits):**
- **F1–F17 (alle Frames außer 18):** CapAlloc (Header=11, Field1=0,
  Field2=0) — "alle Kapazität für Sprache/Control, keine Reservierung"
- **F18:** DL/UL-Assign (Header=00, Field1=DL-Usage, Field2=UL-Usage,
  mit CC = ColourCode)

Beide Muster hängen nur von FN + ColourCode ab. Trivial im RTL zu
generieren:

```verilog
always @(*) begin
    if (fn == 5'd18) begin
        // F18: DL/UL-Assign
        aach_info = {2'b00,                 // Header=DL/UL-Assign
                     2'b00, 4'd0,           // DL-Usage (Unalloc)
                     2'b01, 4'd1};          // UL-Usage (Random)
        // CC-Field nicht im AACH-Info, sondern im RM-Scramble (siehe Spec)
    end else begin
        // F1-17: CapAlloc
        aach_info = {2'b11,                 // Header=CapAlloc
                     12'b0};                // Field1/Field2 beide 0
    end
end
```

Dann durch `tetra_reed_muller.v` (existiert) → 30 Type-5-Bits.

**Budget:** RM(30,14) ist rein kombinatorisch / 1 Takt. Vernachlässigbar.

**Ports:**
```verilog
module tetra_aach_encoder (
    input  wire       clk_sys, rst_n_sys,
    input  wire [4:0] fn,
    input  wire [5:0] colour_code,
    input  wire       encode_strobe,
    output reg [29:0] aach_encoded,
    output reg        aach_valid
);
```

**Test:** RTL-Sim, alle FN-Werte 1..18 × Colour-Code-Varianten, Output
matcht Referenz-Bytes aus `sw/tetra_hal.c:build_aach_capaloc()` /
`build_aach()` (kopiert als Python-Referenz).

---

### Stufe 4 — `tetra_slot_content_mux.v` + NULL-PDU-BRAM

**Zweck:** Aus `payload_class`/`payload_idx` + den Payload-Quellen die
richtigen Busse für den Burst-Builder zusammenstellen.

**Eingänge:**
- **RTL-Encoder (Stufe 3.5/3.7):** `sb_sb1_encoded` aus BSCH-Encoder,
  `aach_encoded` aus AACH-Encoder — beide autonom pro Slot generiert,
  SW ist nicht beteiligt.
- **SW-Register-Bänke:** BNCH (SYSINFO, langsam), MCCH (ACCESS-DEFINE,
  langsam), NDB-SYSINFO-Filler (langsam).
- **NULL-PDU-BRAM** (siehe unten).
- **NULL-PDU-Register** (16 Byte, statisches Gold-Pattern, kein
  Variant-Index nötig).

**NULL-PDU-Bank (neu, BRAM, SW-schreibbar):**

**Gold-Messung (2026-04-20, 400 Bursts der Gold-WAV):** alle 97
NULL-PDU-Vorkommen sind **bit-identisch** — Gold sendet eine einzige
statische Variante. Das NULL PDU sitzt ausschließlich auf TN=1
(ETSI 1) im **BKN1 (SCH/HD)** von NDB2-Bursts. BKN2 daneben trägt
SYSINFO oder BNCH, niemals NULL.

**Bit-Layout (124 Bit SCH/HD-Info-Block, gemessen):**
```
Bit-Position  Wert       Feld (per ETSI EN 300 392-2 §21.4.3)
[0:1]         00         PDU-Type = MAC-RESOURCE
[2]           0          fill_bit (header)
[3]           0          position_of_grant
[4:5]         00         encryption_mode = clear
[6]           0          random_access_flag
[7:12]        000010     length_indicator = 2 (2-octet TM-SDU)
[13:15]       000        address_type = NULL
[16]          1          fill-pattern start ("1 followed by 0s")
[17:31]       0…0        15× zero (completes 2-octet TM-SDU)
[32:123]      0…0        92× zero (SCH/HD slot stuffing)
```
Hex: `0x0010_8000_0000_0000_0000_0000_0000_0000` (124 Bit, MSB-first)

**Auswirkung auf Storage:**
- **1 Variante reicht** — Gold ist statisch. Kein 4-Varianten-Schema,
  keine MN-basierte Rotation, kein Double-Buffer-Tanz. Spart BRAM und
  Komplexität.
- **Speicher-Form:** 124 Bit = 16 Byte. Passt in 4 AXI-Words = 16 Byte
  Register-Bank (kein BRAM nötig). Kein eigenes Schedule-Feld für
  Variant-Index.
- **AXI-Register:** `NULL_PDU_BITS_0/1/2/3` bei `0x340..0x34F`
  (4 × 32-Bit-Words = 128 Bit, MSB-first im Word-0 first; oberste
  4 Bit von Word 3 = Stuffing-Padding, ignoriert).

**Falls später echt Anti-Fingerprint-Variation gewollt:** Trivial
nachrüstbar — Register-Bank zu 4× ausweiten, Index = `MN[1:0]`,
Adresse `0x340..0x37F`. Phase 4 baut bewusst nur 1 Slot, weil die
Gold-Mimik genau das spiegelt.

**Ergänzung Stufe 6:** `build_schf_null_pdu()` generiert die 124 Bit
einmal beim Boot und schreibt sie in die `NULL_PDU_BITS_*`-Register.
Kein per-Slot-Update nötig.

**Empty-Burst-Pfad (optional, nicht im Gold-Preset genutzt):**
Content-Mux unterstützt `enable=0` im Schedule-Eintrag durch Ausgabe von
255 Null-Symbolen statt Burst-Content. Das resultiert in RRC-Output ≈ 0
(LO-Leakage ~−35 dBc bleibt). Kein AD9361-Eingriff — reine Baseband-
Null-Schreibweise. Reserviert für Phase-5-Wartungsfenster /
Spectrum-Tests; Gold-Mimik kommt **ohne** aus, weil Gold auf allen
Slots sendet.

**Systemzeit & AACH:** erledigt durch BSCH-Encoder (Stufe 3.5) und
AACH-Encoder (Stufe 3.7). Content-Mux nimmt deren Output direkt als
`sb_sb1` / `bb` Busse — keine Injektion, keine Shadow-Register für
diese beiden Felder nötig. Das alte `sys_time_inject`-Flag im Schedule-
Eintrag ist damit **redundant** und wird umgewidmet (siehe unten).

**Per-Bank Commit-Bits (jetzt nur noch langsame Banks):**

Da BSCH und AACH autonom im RTL entstehen, bleiben als SW-schreibbare
Payload-Bänke nur die langsam-ändernden:

```
[0] commit_sb_bkn2      (BNCH-Payload im SDB — Cell-SYSINFO)
[1] commit_bnch_blk     (BNCH-Payload im NDB-BNCH-Sonderfall)
[2] commit_mcch_blk     (MCCH/ACCESS-DEFINE)
[3] commit_ndb_sysinfo  (SYSINFO-Filler für NDB-BCCH-Rolle)
[31:4] reserved
```

AXI-Register `PAYLOAD_COMMIT` bei `0x48`, Write-1-to-Strobe. SW schreibt
1 → RTL dirty-Flag → bei nächstem `tdma_tick` Shadow→Live kopieren +
Flag clearen. Lesen zeigt ob Commit durch.

**Wichtig:** SW muss diese Commits **nicht pro Slot** setzen — nur wenn
sich der Inhalt ändert (Cell-Config-Change, SYSINFO-Update, neue
MCCH-ACCESS-DEFINE). Für Standardbetrieb genügt 1× Commit bei Boot.

**Test:** RTL-Sim, Schedule-Preset = Gold, Payload-Bänke mit
Referenz-Bits, Bit-für-Bit-Vergleich mit erwartetem Burst-Stream.

---

### Stufe 5 — IRQ-Infra (jetzt entspannt, nur für Config-Änderungen)

**Zweck:** Durch Stufe 3.5/3.7 ist der per-Slot-Druck weg. SW braucht
keinen engen per-Slot-IRQ mehr. Dieser Baustein liefert nur noch:

- **`IRQ_TX_COMMIT_DONE`:** fires wenn `PAYLOAD_COMMIT` durchgegangen
  ist — erlaubt SW-Pipelining mehrerer Config-Updates.
- **`IRQ_TX_HYPERFRAME`:** fires bei MN=60→MN=1 (jeder HN-Wrap, ~61 s)
  — sinnvoller Trigger für SYSINFO-Refresh.
- **`IRQ_TX_MULTIFRAME`:** optional, fires bei FN=18→FN=1 — falls SW
  pro Multiframe irgendwas machen will. Aktuell ohne Verwendung —
  Gold-Mimik braucht keine Per-Multiframe-Aktion.

**Kein IRQ pro Slot.** SW macht ihre Config-Updates zu beliebigen
Zeitpunkten, commitet, fertig.

**SW-Aufwand:** Sehr gering. `tetra_sysinfo` wird hauptsächlich ein
Boot-Init-Programm: Cell-Config-Register füllen, BNCH/MCCH/NDB-Filler
in ihre Banks schreiben, NULL-PDU-Pattern in Register, Schedule-BRAM
laden, alle Commits setzen. Danach idle im IRQ-Handler für
Config-Änderungen.

**Test:** Hardware-Deploy. 60 s laufen lassen, `decode_dl.py` muss
stabile Systemzeit sehen (TN/FN/MN passen zu dem Slot, in dem sie
gesendet wurden). `scripts/decode_dl.py` hat die NetworkTime-Logik,
Abweichung = Bug.

---

### Stufe 6 — SW-Cleanup

**Cleanup:** `sw/tetra_sysinfo/main.c` wird zum **Boot-Init-Programm**.
Kontinuierlicher Register-Schreiber entfällt ganz — RTL macht den Takt.

**Was SW noch macht:**
1. Cell-Config-Register setzen (MCC, MNC, ColourCode, Sharing-Mode, …)
2. BNCH-Payload encodieren und in Bank schreiben + commit (1× Boot,
   dann bei Config-Änderung)
3. MCCH-ACCESS-DEFINE encodieren + commit (1× Boot, dann bei Änderung)
4. NDB-SYSINFO-Filler encodieren + commit (1× Boot)
5. NULL-PDU statisches Pattern (`0x0010_8000_0000_…`) in
   `NULL_PDU_BITS_*`-Register schreiben (1× Boot)
6. Schedule-Preset per `memcpy` ins Schedule-BRAM laden
7. `TX_TDMA_LOAD` mit Startzeit setzen (z.B. aus RTC oder frei gewählt)
8. CTRL[1]=TX_ENABLE

**Was SW nicht mehr macht:**
- Keine BSCH-Encoding pro Slot (RTL Stufe 3.5)
- Keine AACH-Encoding pro Slot (RTL Stufe 3.7)
- Keine `REG_SB_SB1` / `REG_SB_BB` Schreibzugriffe — die Register werden
  aus dem AXI-Fenster entfernt (freiwerdender Platz für Cell-Config)
- Keine Gold-Muster-Simulation in SW (Schedule-BRAM)
- Keine per-Slot Commits

**Neu nötig (wieder):**
- `build_schf_null_pdu()` zurück in `sw/tetra_hal.c` bringen (war in
  Commit `06dddab` entfernt). Gold-Zelle sendet NULL PDU auf
  Traffic-Slots, nicht wiederholtes SYSINFO. Payload geht in den
  `NULL_PDU_BITS_*`-Register (`0x340..0x34F`, 16 Byte = 124 Bit
  effektiv). Content-Mux gibt das Pattern auf BKN1 wenn Schedule-Eintrag
  `payload_class=NULL_PDU` sagt. Gold-Pattern ist statisch, kein
  Variant-Index, kein Per-Slot-Update.

**Nicht mehr nötig:**
- `REG_SB_BB` kontinuierliches Rewriting (heute weil BB shared ist)
- Gold-Muster-Simulation in SW (RTL macht das jetzt)

---

## 5. Implementierungsreihenfolge

| # | Schritt | Gate (muss grün sein bevor weiter) |
|---|---|---|
| 1 | `tetra_tdma_timebase.v` + TB | Unit-TB: Counter-Wrap, sync_load, tdma_tick |
| 2 | AXI TX_TDMA_SYNC Register | Deploy, SW liest/schreibt, STATE-Register spiegelt |
| 3 | Slot-Schedule-BRAM + Gold-Preset | RTL-Sim: Burst-Typen matchen Gold-Muster über 4 Multiframes (alle MN%4) |
| 3.5 | `tetra_bsch_encoder.v` + Cell-Config-Register + TB | RTL-Sim: bit-exact vs. Python-Referenz (SW-Kette in Python nachbauen) |
| 3.7 | `tetra_aach_encoder.v` + TB | RTL-Sim: alle FN 1..18 × CC-Werte matchen `build_aach*()` Python-Referenz |
| 4 | Content-Mux + NULL-PDU-BRAM | `decode_dl.py` auf eigenem WAV zeigt **≥95 % SB, ≥90 % NDB, Systemzeit inkrementiert pro Slot** |
| 5 | IRQ-Infra (Commit-Done, Hyperframe) | 60-s-Stabilität, keine Config-Update-Races |
| 6 | SW-Cleanup (tetra_sysinfo wird Boot-Init) | Code-Diff, `scripts/deploy.sh` grün, SW tut nichts in Hot-Path |

**Gate für Stufe 4 ist der entscheidende Meilenstein.** Wenn Systemzeit
dort nicht pro Slot inkrementiert, ist BSCH-Encoder/Timebase-Verdrahtung
falsch. Wenn NDB <90 %, ist das Content-Mux-Verhalten (insbesondere
NULL-PDU-BRAM-Anbindung) das Problem.

---

## 6. Verifikation je Stufe

**RTL-Sim:** jeweils Unit-TB + ein Integrations-TB in `tb/tb_tdma_schedule.v`
der 1 Multiframe simuliert und jeden Burst gegen ein Gold-Muster
(Python-generiert aus `scripts/gold_schedule.py`) vergleicht.

**Hardware:** nach jeder Stufe auf-Board deployen, WAV aufnehmen
(30 s reicht), mit `scripts/decode_dl.py` durchlaufen, Zahlen eintragen:

| Stufe | SB-OK % | NDB-OK % | MER % | Bemerkung |
|---|---|---|---|---|
| Baseline (heute) | 41 | 1 | ? | siehe letzte WAV-Analyse |
| Stufe 1 | ≈Baseline | ≈Baseline | ≈ | nur interner Zähler, kein Verhalten geändert |
| Stufe 2 | ≈Baseline | ≈Baseline | ≈ | SW kann laden, macht aber noch nichts |
| Stufe 3 | Burst-Typ-Verteilung matcht Gold | ≈Baseline | ? | Content noch SW-gesteuert, Schedule ist es nicht mehr |
| Stufe 3.5 | **>90** (BSCH jetzt korrekt pro Slot) | ≈Baseline | ≈ | Systemzeit inkrementiert pro Slot in decoder |
| Stufe 3.7 | ≈Stufe 3.5 | ≈Baseline | ≈ | AACH-Felder matchen Gold pro FN |
| Stufe 4 | **>95** | **>90** | **<1** | Haupt-Gewinn — NULL-PDU aus BRAM, SW aus dem Hot-Path |
| Stufe 5 | ≈Stufe 4 | ≈Stufe 4 | stabil über 60 s | Commit-IRQ, Hyperframe-IRQ |
| Stufe 6 | ≈Stufe 5 | ≈Stufe 5 | | Code kleiner, Verhalten gleich |

Gold-Referenz bleibt `18-Apr-2026 220430.876 425.487MHz 000.wav`.

---

## 6b. Phase-5-Vorsorge (Traffic Channels) — nicht in diesem Plan gebaut

Dieser Plan zielt auf Phase 4 (Broadcast-Zelle, SYSINFO + NULL PDU).
Phase 5 bringt echte Calls: TCH/S (Speech), TCH/7.2 (Data), MS-Zuweisung.
Damit Phase 5 kein Architektur-Umbau wird, sind die folgenden Design-
Entscheidungen **jetzt schon** in Phase 4 eingebaut:

| Vorsorge | Eingebaut in | Wofür in Phase 5 |
|---|---|---|
| 16-Bit Schedule-Eintrag mit `payload_class`/`payload_idx` statt 8-Bit-Enum | Stufe 3 | TCH-Channel-Index (bis 64 Rufe) ohne Schedule-Umbau |
| Schedule-BRAM als Dual-Port (AXI-Schreiben + RTL-Lesen parallel) | Stufe 3 | Laufzeit-Schedule-Updates bei Call-Start/Ende ohne Commit-Strobe |
| `payload_class`-Namespace-Plan (0=BROADCAST, 1=NULL, 2=TCH, 3..15 frei) | Stufe 3 | TCH als neue Klasse ohne Schedule-Migration |
| Current-Slot-IRQ + Shadow-Commit-Infra | Stufe 5 | TCH-Frame-Lieferung pro 60 ms Call-Slot |

**Neu in Phase 5 (eigener Plan):**
- Per-TCH Ring-FIFO im RTL (DMA-gefüttert, wie `axi_dma_bridge.v` in
  RX-Richtung, nur umgekehrt). Größe ~1 kBit/Kanal × 4 Kanäle → 1 BRAM18
- `payload_class=TCH` im Content-Mux: liest nächsten Frame aus
  `FIFO[payload_idx]` pro Slot-Pulse
- Underrun-Handling: leere FIFO → NULL PDU statt Silence-ACELP
- SW-Upper-MAC (MM/CMCE) füttert FIFOs via DMA, wenn MAC-RESOURCE einen
  Slot zuweist → Schedule-BRAM-Eintrag updaten auf `class=TCH, idx=N`

**Out-of-scope für Phase 4:**
ACELP-Codec, Voice-Pfad, MS-Registration, MAC-RESOURCE Slot-Zuweisung,
TEA-Verschlüsselung. Alles Phase 5.

---

## 7. Risiken / Tradeoffs

1. **BSCH-Encoder-Pipeline muss bit-exact zur SW-Referenz sein.** Die
   volle Kette (CRC16 → tail → RCPC 2/3 → Interleave 8×15 → Scramble
   init=3) hat viele Stellen für Bit-Order-/Endianness-Fehler. Jeder
   Mismatch = Gold-Zelle dekodiert uns nicht.
   **Mitigation:** Python-Referenz aus der bestehenden SW-Kette
   (`sw/tetra_hal.c` → `build_sync_pdu()` + `encode_sch_hu()`) extrahieren,
   in `scripts/verify_bsch_encoder.py` als Golden-Model. RTL-TB vergleicht
   10× zufällige (TN, FN, MN, Config)-Inputs bit-genau gegen Python.
   Gate für Stufe 3.5.
2. **Cell-Config-Register-Writes während aktivem Encoding könnten
   glitchen.** Wenn SW MCC mitten im BSCH-Encode umschreibt, kann die
   FSM inkonsistente Bits produzieren.
   **Mitigation:** BSCH-Encoder latcht Config-Inputs bei `encode_strobe`
   einmalig in interne Register, arbeitet nur auf Latches. Config-Writes
   zwischen den Encodes sind dann race-frei. (Alternativ: `tdma_tick`
   als globaler Latch-Strobe — einfacher, spart Logik.)
3. **Slot-Schedule-ROM statisch vs. BRAM.** Static ist starr (Gold
   only), BRAM ist 576 Byte, sollte kein Ressourcen-Thema sein. BRAM
   mit Dual-Port für Phase-5-Updates.
4. **IRQ-Latenz auf Linux.** Durch RTL-BSCH/AACH irrelevant für
   per-Slot-Pfad. Bleibt nur für Commit-Done/Hyperframe/Multiframe-IRQ
   (alle ≥60 ms Abstand) — völlig unkritisch auf Standard-Linux.
5. **BSCH-Sync → Time-Load braucht funktionierenden RX.** Der RX-Pfad
   ist Phase-4-Baustelle. Falls RX-Sync weiter unzuverlässig: Stufe 2
   bleibt optional (SW kann auch "frei laufen ohne Real-Time-Sync"
   solange nur der MS-Test der Gold-Zelle gleicht).
6. **Rückwärtskompatibilität.** Keine; das ist eine Architektur-
   Änderung. `tetra_hal.c` wird mitverändert, `REG_SB_SB1`/`REG_SB_BB`
   entfallen. Einzelne Git-Commits pro Stufe ermöglichen Rollback.

---

## 8. Verweise

- Burst-Builder-Seite: `rtl/tx/tetra_burst_builder.v` (bereits korrekt,
  lesen akzeptiert `burst_type_sys`, `burst_ndb2_sys`, `nts_sel`)
- Aktuelle TDMA-Zähler: `rtl/tetra_zynq_top.v:616–652`
- Aktuelles Scheduling: `rtl/tetra_zynq_top.v:694–756`
- Gold-Messungen: `scripts/gold_schedule.py`,
  `memory/project_gold_cell_mimic.md`
- Validierung: `scripts/decode_dl.py` (100 % auf Gold WAV,
  `memory/project_decoder_dll_feature_complete.md`)
- Commit dd84e22 — NTS2-Fix, Phantom-Gruppen-Bug
- Register-Karte: `docs/register_map.md` — neu zu ergänzen:
  - `0x140 TX_TDMA_LOAD`, `0x144 TX_TDMA_STATE` (Stufe 2 — Adressen verschoben weil 0xC0/0xC4 mit MCCH_BLK1_0/1 kollidiert hätten)
  - `0xE0 CELL_CFG_0`, `0xE4 CELL_CFG_1` (Stufe 3.5)
  - `0x400..0x63F` Schedule-BRAM-Fenster (Stufe 3, 9-Bit Decode-Erweiterung)
  - `0x340..0x34F` NULL_PDU_BITS_0..3 Register (Stufe 4 — 1 Variante,
    16 Byte; Gold-Messung zeigt statisches Pattern)
  - Zu entfernen: `REG_SB_SB1`, `REG_SB_BB` (BSCH jetzt in RTL)
- SYNC-PDU-Feldliste: ETSI EN 300 392-2 §18.5.21
- AACH-Kodierung: ETSI EN 300 392-2 §21.4.4 (RM(30,14) + Scramble-Rolle
  des Colour-Codes)
- Referenz-Encoder für Bit-Exact-TB: `sw/tetra_hal.c` →
  `build_sync_pdu()`, `encode_sch_hu()`, `build_aach*()`
