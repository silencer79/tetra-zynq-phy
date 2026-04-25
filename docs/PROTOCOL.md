# PROTOCOL — TETRA Stack, ETSI-Referenz, Fremd-Implementierungen

**Projekt:** tetra-zynq-phy
**Stand:** 2026-04-25

Ersetzt: `sdrsharp_tetra_dll_analysis.md`. Integriert Findings aus `osmo-tetra`
Decoder, `tetra-bluestation` (MidnightBlueLabs, Rust-BS-Implementierung), sowie
dem Gold-Reference-Capture einer fremden TETRA-BS mit erfolgreichem MS-Attach
(`docs/references/captures_external_bs_2026-04-25/`).

---

## 1. Inhalt

1. TETRA Air-Interface Basisdaten
2. Channel-Coding Pipeline (Scrambler → Interleaver → RCPC → Viterbi → CRC → RM)
3. Burst-Struktur (NDB, SB/SDB, CB, NUB)
4. Frame/Slot/Multiframe/Hyperframe-Timing
5. PDUs: SYNC, SYSINFO, ACCESS-DEFINE, AACH, MAC-RESOURCE, MAC-ACCESS
6. Registration-Protokoll (UL-Demand → DL-Accept → Handshake)
7. Offene Registration-Blocker 2026-04-24
8. Referenz-Tabellen (Enums, Codes, Magics)

---

## 2. TETRA Air-Interface Basisdaten

| Parameter | Wert | ETSI-Ref |
|-----------|------|----------|
| Modulation | π/4-DQPSK, Gray-coded | §5.5.2 |
| Symbol-Rate | 18 ksymbol/s | §4 |
| Bit-Rate (brutto) | 36 kbit/s | — |
| Kanal-Raster | 25 kHz | §4.4 |
| Puls-Formung | Root Raised Cosine α=0.35 | §5 |
| TDMA | 4 Timeslots pro Frame | §18 |
| Frame-Dauer | 56.67 ms (255 Symbole × 4 Slots) | §18 |
| Multiframe | 18 Frames (1.02 s) | §18 |
| Hyperframe | 60 Multiframes (61.2 s) | §18 |
| Duplex | FDD 10 MHz (Band 4, 400 MHz) | §4.4, TS 100 392-15 |

### 2.1 Dibit-Mapping π/4-DQPSK (ETSI §5.5.2.3)

| Dibit | Differenz-Phase |
|-------|-----------------|
| 00 | +π/4 |
| 01 | +3π/4 |
| **10** | **−π/4** |
| **11** | **−3π/4** |

Unsere frühere Implementierung hatte 10↔11 vertauscht (BER 15% / MER 100 % gegen echten Receiver trotz CRC-PASS bei Python-Decoder, der denselben Bug hatte). Fix 2026-04-13.

### 2.2 Frequenz-Berechnung (SDRSharp.Tetra.FrequencyCalc)

```
freq_Hz = band × 100_000_000 + carrier × 25_000
offset 1 → +6250
offset 2 → −6250
offset 3 → +12500
```

Band 4 (400 MHz): carrier 1530 × 25 kHz + 400 MHz = **438.25 MHz DL**, -10 MHz Duplex → **428.25 MHz UL**.

---

## 3. Channel-Coding Pipeline

### 3.1 Scrambler (ETSI §8.2.5)

**LFSR 32-bit** mit polynom-AND + Popcount-Parity:

```
masked      = scrambler & 0xDB710641
output_bit  = popcount(masked) & 1
scrambler   = (scrambler >> 1) | (output_bit << 31)
data[i]    ^= output_bit
```

### 3.2 Scrambler-Init-Konstruktion

**TMO** (3-Parameter, aus SYNC-PDU): 
```
init = (MCC[10] << 22) | (MNC[14] << 8) | (CC[6] << 2) | 0b11
```

Die untersten 2 Bits sind **immer `0b11`** (= Default-Scrambler-Init `3`).

**DMO** (2-Parameter):
```
init = (MNC[6] << 26) | (SourceAddr[24] << 2) | 0b11
```

### 3.3 Scrambler-Init pro Kanal

| Kanal | Init | Hinweis |
|-------|------|---------|
| SB (SYNC-Burst) | **fixed 3** | NICHT network-dependent! |
| BKN (single-slot SCH/HD) | `network_scramb_init` | aus CreateScramblerCode |
| BKN2 (standalone DMO) | fixed 3 | DMO-Spezialfall |
| BKN1+BKN2 (full-slot SCH/F) | `network_scramb_init` | |
| BB (AACH) | `network_scramb_init` | |

Unser Cell-Default (`MCC=901, MNC=9998, CC=49`) ergibt `scramb_init = 0xE1670EC7`.

### 3.4 Block-Interleaver (ETSI §8.2.4)

Multiplikativer Interleaver pro Kanal-Variante:

| Kanal | K (Block-Länge) | a (Multiplier) |
|-------|-----------------|----------------|
| SB (BSCH 120b) | 120 | 11 |
| SCH/HD (216b) | 216 | 101 |
| SCH/F (432b) | 432 | 103 |

Formel: `output[(a × k) mod K + 1] = input[k]` für `k = 1..K`.

### 3.5 RCPC-Puncturing (ETSI §8.2.3)

**Mother-Code:** Rate 1/4, Constraint-Length K=5, 16 States. Generator-Polys G0..G3.

**Puncture-Patterns:**
- SCH/F, SCH/HD, SCH/HU → Rate 2/3 (aus der 1/4-Mutter punctured)
- TCH/S → Rate variabel je Klasse

### 3.6 CRC-16 (ETSI §8.2.4.1)

| Parameter | Wert |
|-----------|------|
| Polynom | 0x8408 (reflected CCITT-16) |
| Init | 0xFFFF |
| Good-Residual | **0xF0B8** |

Für 60-bit SYNC-PDU: +16 bit CRC → 76 bit → +4 tail → 80 bit → RCPC 2/3 → 120 bit type-5.

### 3.7 Reed-Muller (30,14) für AACH (ETSI §8.2.4.2)

AACH (Access Assignment Channel) auf jedem NDB-Burst in BB-Block:
- k=14 Info-Bits
- n=30 coded Bits
- Syndrom-basiertes Decoding

### 3.8 Viterbi-Decoder

Soft-Decision, 16-state, rate-1/4 mother-decoded mit depuncturing.

**WICHTIGER RTL-Split:** `rtl/lmac/tetra_viterbi_decoder.v` nutzt bit-reversed state convention — nur DL-Loopback-kompatibel. `rtl/rx/tetra_ul_viterbi_r14.v` ist die ETSI-konforme Version für UL-RA-Decode (MTP3550 live getestet).

---

## 4. Burst-Struktur

### 4.1 Burst-Typen (ETSI §9.4)

| Typ | Länge (Symbole) | Verwendung |
|-----|-----------------|------------|
| NDB (Normal DL Burst) | 255 | Haupt-DL-Verkehr (Kanal-Typ via Training-Seq: NDB1=n, NDB2=p) |
| SB / SDB (Synchronisation DL Burst) | 255 | BSCH/BNCH — carrier sync + network info |
| CB (Control UL Burst) | 127 | Random Access (MS → BS) |
| NUB (Normal UL Burst) | 255 | Assigned UL (nach Resource-Alloc) |
| LB (Linearisation UL Burst) | variable | AD-Kalibrierung |
| EUB (Extended UL Burst) | ~510 | Doppel-Slot |

### 4.2 NDB-Layout (§9.4.4.3.1, 255 Symbole)

```
[tail(2)] [PA(34)] [Block1(216)] [BB1(14)] [NTS(22)] [BB2(16)] [Block2(216)] [guard(14)] 
                                           = 255 symbols
```

- **PA** — Power Amplifier ramp-up (Freq-Correction bei SB)
- **Block1/Block2** — 216 type-5 Bits pro Hälfte
- **BB** — Broadcast Block (AACH) 30 Bit = bb1(14) + bb2(16), RM(30,14)-coded
- **NTS** — Normal Training Sequence (22 dibits → `n` oder `p` je nach BurstType)

### 4.3 SB/SDB-Layout (§9.4.4.3.2, TMO)

```
[guard(2)] [freq_corr(80)] [tail(4)] [SB(120)] [STS(38)] [BB(30)] [BKN2(216)] [...]
```

- **freq_corr** — 80-Bit Freq-Correction (PA-Ramp-Ersatz bei SB)
- **SB** — BSCH 120 type-5 Bits (60 info + CRC + tail, coded)
- **STS** — Sync Training Sequence 38 dibits
- **BB** — AACH (30 bit)
- **BKN2** — BNCH-Payload 216 type-5 Bits (124 info bits nach Decode, enthält SYSINFO)

### 4.4 Training-Sequenzen (§9.4.4.4)

| Name | Länge (Dibits) | Verwendung |
|------|----------------|------------|
| n | 22 | NDB1 |
| p | 22 | NDB2 |
| q | 22 | NDB-alt (selten) |
| x | 30 | Extended (NTS3 + ETS) |
| y / STS | 38 | SB/SDB Synchronisation |

**Bit-Werte** (aus `osmo-tetra/src/phy/tetra_burst.c`):

```
n = 1,1,0,1,0,0,0,0,1,1,1,0,1,0,0,1,1,1,0,1,0,0
p = 0,1,1,1,1,0,1,0,0,1,0,0,0,0,1,1,0,1,1,1,1,0
q = 1,0,1,1,0,1,1,1,0,0,0,0,0,1,1,0,1,0,1,1,0,1
x = 1,0,0,1,1,1,0,1,0,0,0,0,1,1,1,0,1,0,0,1,1,1,0,1,0,0,0,0,1,1
y = 1,1,0,0,0,0,0,1,1,0,0,1,1,1,0,0,1,1,1,0,1,0,0,1,1,1,0,0,0,0,0,1,1,0,0,1,1,1
```

### 4.5 π/4-DQPSK Demod (Differential Phase)

Aus SDRSharp `ConvertAngleToDiBits`:

```
dibit_high = (angle >= 0) ? 0 : 1       // Sign → erstes Bit
dibit_low  = (|angle| <= π/2) ? 0 : 1   // Magnitude → zweites Bit
```

---

## 5. Frame / Slot / Multiframe / Hyperframe

### 5.1 Zähler-Konvention

**Internal (RTL/SW):** 1-based. TN=1..4, FN=1..18, MN=1..60, HN=1..60.
**On-Air (SB-PDU):** 0-based. TN=0..3, FN=0..17, MN=0..59.

Konvertierung beim Empfang (SDRSharp, osmo, bluestation alle gleich):
```
TN_internal = TN_air + 1
FN_internal = FN_air + 1
MN_internal = MN_air + 1
```

Wrap: `AddTimeSlot()` erhöht TN; bei TN>4 → TN=1, FN++; bei FN>18 → FN=1, MN++; bei MN>60 → MN=1.

### 5.2 BSCH/BNCH-Rotation (§18.3.2)

Nur auf Frame 18:
```
BSCH_timeslot = 4 − ((MN+1) mod 4)    // intern 1-based
BNCH_timeslot = 4 − ((MN+3) mod 4)
```

Beispiel MN=2: BSCH auf TN=4−((3)%4)=4−3=1, BNCH auf TN=4−(5%4)=4−1=3.

Gold-Cell-Messung bestätigt: F18 TN=0 (ETSI 1) nur bei `MN%4==2` SB-Anchor, sonst NDB2 mit BNCH-Inhalt.

### 5.3 TDMA-Timing

```
Frame  = 4 × 255 Symbole / 18 kHz = 56.67 ms
Slot   = 255 Symbole / 18 kHz     = 14.167 ms
Symbol = 1 / 18 kHz               = 55.56 µs
```

Response-Latenz-Budget für RA → Accept: ~2-3 Slots = 28-42 ms.

---

## 6. PDU-Struktur

### 6.1 Layer-Stack

```
MS ─ Air ─ BS
           │
           ▼
┌───────────────────────────────────────┐
│ MAC Layer (§21)                       │
│   MAC-RESOURCE / MAC-ACCESS / ...    │
│   ├── LLC PDU Container              │
│   │     ├── BL-ADATA / BL-UDATA /... │
│   │     └── TL-SDU                   │
│   │           ├── MLE PD (3 bit)     │
│   │           └── MM / CMCE PDU      │
└───────────────────────────────────────┘
```

### 6.2 MAC PDU-Typen (§21.4)

2-bit Header:

| Wert | Typ |
|------|-----|
| 00 | MAC-RESOURCE (DL) / MAC-ACCESS (UL) |
| 01 | MAC-FRAG / MAC-END |
| 10 | MAC-BROADCAST (SYSINFO, ACCESS-DEFINE) |
| 11 | MAC-U-SIGNAL (UL only) / MAC-D-BLCK |

### 6.3 MAC-RESOURCE DL-Header (§21.4.3.1 Tabelle 21.55)

```
[2 bit] PDU-Type = 00 (MAC-RESOURCE)
[1 bit] FillBit
[1 bit] PosOfGrant
[2 bit] EncryptionMode
[1 bit] RandAccFlag           ← 1 als RA-Acknowledgement für ISSI-adressiertes Accept
[6 bit] LengthIndication       (MAC total octets)
[3 bit] AddrType               (0=NULL, 1=SSI, 2=EventLabel, 3=USSI, 4=SMI, ...)
[... bit] Address              (variable: 0/10/24/48 bit je AddrType)
─────────  wenn PosOfGrant=1 AND addr!=NULL AND LI!=0: ──────────
[1 bit] PowerCtrl present
[1 bit] SlotGrant present
[1 bit] ChanAlloc present
─────────  TM-SDU startet hier ──────────
```

**Wichtige Erkenntnis Bug #7 (2026-04-23):** unser RTL emittierte die 3 presence-flag-bits unkonditional. ETSI (§21.4.3.1) verlangt sie NUR bei `PosOfGrant=1 AND addr!=NULL AND LI!=0`. Für pure Registration-Accept (PosOfGrant=0) OMITTED.

### 6.4 MAC-ACCESS UL-Header (§21.4.3.3)

Parser-Layout aus `rtl/lmac/tetra_ul_mac_access_parser.v`
(bluestation-aligned, Rev. 2026-04-25 Commit `eeabf1f`):

```
bit[0]      mac_pdu_type              (1 bit, 0 = MAC-ACCESS)
bit[1]      fill_bits                 (1 bit)
bit[2]      encrypted                 (1 bit)
bits[3..4]  addr_type                 (2 bit, NICHT 3)
bits[5..28] address                   (24 bit — Ssi/Ussi/Smi)
                                      bei addr_type=1 (EventLabel): nur 10 bit → [5..14]
bit[29]     optional_field_flag
───────── wenn optional_field_flag = 1: ─────────
bit[30]     choice-bit (0 = length_ind, 1 = frag_flag+reservation_req)
bits[31..34] entweder 4 bit length_ind, oder
             1 bit frag_flag + 3 bit reservation_req
─────────  TL-SDU startet ab bit 30 (opt=0) bzw. 36 (opt=1) ──────────
TL-SDU = LLC-PDU (BL-DATA / BL-ADATA / ...)
```

**Historischer Bug (2026-04-25 gefixt):** Parser las `addr_type` als 3 bit
und danach `short_ssi_or_event_label` als 10 bit — falsch aligned, mit dem
Resultat dass für jede Motorola-MS (ISSI-Präfix `0x282xxx`) konstant
`short_id=523` herauskam. BS konnte die MS nicht adressieren, Accept landete
on-Air mit SSI=523. Real-BS (Gold-Ref 2026-04-25) adressiert Accept immer an
die **echte 24-bit ISSI** aus dem MAC-ACCESS-Header (keine Lookup-Tabelle,
keine Short-SSI-Auflösung). Parser + Mailbox + MLE-FSM + SW-Monitor sind
seit Commit `1f1ec3a` 24-bit-durchgängig.

AddrType-Codes pro bluestation `mac_access.rs`:

| Code | Typ | Address-Breite |
|------|-----|----------------|
| 0 | Ssi (ISSI) | 24 bit |
| 1 | EventLabel | 10 bit |
| 2 | Ussi | 24 bit |
| 3 | Smi | 24 bit |

Für UL ist bluestation hart `SsiType::Issi // Uplink, always ISSI`, d.h.
effektiv immer 24-bit-ISSI sobald die MS ihre ITSI kennt (nach erstem Attach).

### 6.5 LLC PDU-Typen (§22.2)

| Code | Typ | Header-Felder | Acknowledged | FCS | Verwendung |
|------|-----|---------------|--------------|-----|------------|
| 0 | BL-ADATA | NR + NS | ✓ | ✗ | DL-Signalling MIT piggyback-ACK |
| **1** | **BL-DATA** | **NS only (kein NR)** | ✓ | ✗ | **Default DL/UL-Signalling ohne piggyback** |
| 2 | BL-UDATA | — | ✗ | ✗ | Unacknowledged |
| 3 | BL-ACK | NR only | — | ✗ | Standalone LLC-ACK |
| 4 | BL-ADATA+FCS | NR + NS | ✓ | ✓ | wie 0, mit CRC-32 |
| 5 | BL-DATA+FCS | NS | ✓ | ✓ | wie 1, mit CRC-32 |
| 6 | BL-UDATA+FCS | — | ✗ | ✓ | — |
| 7 | BL-ACK+FCS | NR | — | ✓ | — |
| 8-15 | AL-SETUP, AL-DATA, AL-ACK, ... | — | — | — | (Advanced Link, call control) |

**Kritisches Finding 2026-04-24:**

- **tetra-bluestation Default-LLC ist BL-DATA (type 1)**, nicht BL-ADATA. BL-ADATA wird nur gewählt wenn ein BL-ACK piggyback gestapelt werden soll (`llc_bs_ms.rs:276-301`: `if let Some(out_ack_n) = out_ack_n { BlAdata {...} } else { BlData {...} }`).
- **`fcs_flag: false`** hart in `mle_bs.rs:212/277/301` für alle MLE-Pfade. Real-BS schickt D-LOC-UPDATE-ACCEPT als `BL-DATA` (type 1, OHNE FCS), nicht `BL-ADATA+FCS` (type 4).
- Unser RTL nutzt aktuell type 4 (`BL-ADATA+FCS`). Beide Felder falsch: ADATA statt DATA + FCS-Append statt weglassen.

### 6.6 LLC BL-ADATA(+FCS) Header (§22.2.2.2)

Aus bluestation `bl_adata.rs:38-46`:

```
[1 bit] llc_link_type = 0
[1 bit] has_fcs            ← 0 bei BL-ADATA, 1 bei BL-ADATA+FCS
[2 bit] bl_pdu_type = 00
[1 bit] N(R)
[1 bit] N(S)
─────── 6 Bit Header gesamt ───────
```

### 6.7 FCS (CRC-32) bei LLC BL-*-FCS (§22.2.2.5)

**Nur bei LLC-Type 4-7.** osmo-tetra + bluestation implementieren identisch:

```c
uint32_t crc = 0xFFFFFFFF;
if (len < 32) crc <<= (32 - len);          // Pre-Shift für kurze Payloads
for (i = 0; i < len; i++) {
    bit = (data[i] ^ (crc >> 31)) & 1;
    crc <<= 1;
    if (bit) crc ^= 0x04C11DB7;
}
return ~crc;
```

**Coverage:** nur die TL-SDU-Bits (MLE-PD + MM-Body), **NICHT** der LLC-Header. Die bluestation-Logik parst LLC-Header in 6 Bit, dann `check_fcs(cur, tl_sdu_len)` mit `cur` = Pointer nach LLC-Header.

SDRSharp.Tetra nutzt für FCS-Check:
```
Poly    = 0xEDB88320    // bit-reversed CCITT-32
GoodFCS = 0xDEBB20E3    // Magic Residual
```
(entspricht dem bit-reversed Äquivalent von `0x04C11DB7`-Poly + Komplement).

### 6.8 MLE Protocol Discriminator (§18.5.2 Tabelle 18.4)

Nach LLC-Header, 3 Bit:

| Code | Discriminator |
|------|---------------|
| 0 | Reserved |
| 1 | MM (Mobility Management) |
| 2 | CMCE (Circuit Mode Control Entity) |
| 3 | Reserved |
| 4 | SNDCP |
| 5 | MLE (MLE-protocol internal) |
| 6 | TETRA Management Entity |
| 7 | Testing |

### 6.9 MM PDU-Typen

**Downlink (§16.10.39):**

| Code | PDU |
|------|-----|
| 0x0 | D-OTAR |
| 0x1 | D-AUTHENTICATION |
| 0x2 | D-CK-CHANGE-DEMAND |
| 0x3 | D-DISABLE |
| 0x4 | D-ENABLE |
| **0x5** | **D-LOCATION UPDATE ACCEPT** |
| 0x6 | D-LOCATION UPDATE COMMAND |
| 0x7 | D-LOCATION UPDATE REJECT |
| 0x9 | D-LOCATION UPDATE PROCEEDING |
| 0xA | D-ATTACH/DETACH-GROUP-ID |
| 0xB | D-ATTACH/DETACH-GROUP-ID-ACK |
| 0xC | D-MM-STATUS |
| 0xF | D-MM PDU/FUNCTION NOT SUPPORTED |

**Uplink (§16.10.39):**

| Code | PDU |
|------|-----|
| 0x0 | U-OTAR |
| 0x1 | U-AUTHENTICATION |
| 0x2 | U-CK-CHANGE-RESP |
| 0x3 | U-DISABLE-STATUS |
| **0x4** | **U-LOCATION UPDATE DEMAND** |
| 0x5 | U-MM-STATUS |
| 0x8 | U-ATTACH/DETACH-GRP-ID |
| 0x9 | U-ATTACH/DETACH-GRP-ID-ACK |
| 0xC | U-TEI-PROVIDE |
| 0xF | U-MM-PDU NOT SUPPORTED |

### 6.10 CMCE PDU-Typen (5 bit, §14.7)

| Code | PDU |
|------|-----|
| 0 | D-ALERT |
| 1 | D-CALL-PROCEEDING |
| 2 | D-CONNECT |
| 3 | D-CONNECT-ACK |
| 4 | D-DISCONNECT |
| 6 | D-RELEASE |
| 7 | D-SETUP |
| 8 | D-STATUS |
| 9 | D-TX-CEASED |
| 11 | D-TX-GRANTED |
| 12 | D-TX-WAIT |
| 14 | D-CALL-RESTORE |
| 15 | D-SDS-DATA |
| 16 | D-FACILITY |

### 6.11 Location-Update-Type (§16.10.35a / §16.10.37)

Gemeinsame Codes für UL-Demand + DL-Accept:

| Code | Typ |
|------|-----|
| 0 | Roaming location updating |
| 1 | Temporary |
| 2 | Periodic |
| **3** | **ITSI attach** |
| 4 | Call restoration roaming |
| 5 | Migrating |
| 6 | Demand |
| 7 | Disabled MS |

MTP3550-Test (decode_ul_raw.py) bestätigt: MS sendet **Code 3 = ITSI attach** auf initialem Reg-Versuch.

### 6.12 SYNC-PDU (BSCH, 60 type-1 Bits)

Layout aus SDRSharp `_syncInfoRulesTMO` + `decode_dl.py:parse_sysinfo_sb`:

| Bits | Feld | Quelle |
|------|------|--------|
| [0:3] | System-Code (4) | Cell-Config |
| [4:9] | Colour-Code (6) | Cell-Config |
| [10:11] | Timeslot (2) | **Timebase** (TN, air-side 0..3) |
| [12:16] | Frame-Number (5) | **Timebase** (FN, air-side 0..17) |
| [17:22] | Multiframe (6) | **Timebase** (MN, air-side 0..59) |
| [23:24] | Sharing-Mode (2) | Cell-Config |
| [25:27] | TS-Reserved-Frames (3) | Cell-Config |
| [28] | U-plane-DTX (1) | Cell-Config |
| [29] | Frame-18-Extension (1) | Cell-Config |
| [30] | Reserved (1) | 0 |
| [31:40] | MCC (10) | Cell-Config |
| [41:54] | MNC (14) | Cell-Config |
| [55:56] | Neighbor-Cell-Broadcast (2) | Cell-Config |
| [57:58] | Cell-Service-Level (2) | Cell-Config |
| [59] | Late-Entry-Supported (1) | Cell-Config |

**Wichtig:** SYNC-PDU enthält KEIN Hyperframe-Feld und KEIN Cipher-Key-Flag — die sitzen in SYSINFO Type 4 (BNCH).

### 6.13 SYSINFO-PDU (BNCH, 124 type-1 Bits) — Schlüsselfelder

| Feld | Bits | Beschreibung |
|------|------|--------------|
| MAC-PDU-Type | 2 | = 10 (Broadcast) |
| Broadcast-Type | 2 | = 00 (SYSINFO) |
| Main-Carrier | 12 | Carrier-Nummer (unser: 1530) |
| Frequency-Band | 4 | = 4 (70 cm) |
| Offset | 2 | 0=0 / 1=+6.25 / 2=-6.25 / 3=+12.5 kHz |
| Duplex-Spacing | 3 | 0 = 10 MHz (Band 4) |
| Reverse-Operation | 1 | |
| Number-Common-SCH | 2 | |
| MS-TXPWR-MAX-CELL | 3 | |
| RXLEVEL-ACCESS-MIN | 4 | |
| Access-Parameter | 4 | |
| Radio-Downlink-Timeout | 4 | |
| Hyperframe-or-Cipher-Flag | 1 | |
| Hyperframe | 16 | |
| Optional-Field-Flag | 2 | |
| Location-Area | 14 | |
| Subscriber-Class | 16 | Service-Profile-Maske |
| Registration-Required | 1 | |
| ... weitere Felder ... | | |

### 6.14 MAC-RESOURCE RandAccFlag — das Random-Access-Ack-Bit

**Schlüsselmechanismus für MS-Registration.** ETSI §21.4.3.1: *"The random access flag shall be used for the BS to acknowledge a successful random access so as to prevent the MS sending further random access requests."*

Das RA-Ack ist **kein eigenes MM- oder LLC-Paket**, sondern ein **einzelnes Bit im DL-MAC-RESOURCE-Header** (bit-Position zwischen `encryption_mode` und `length_ind`).

**Wie bluestation es einsetzt:**

Sobald BS einen gültigen UL-MAC-ACCESS empfängt → `dl_enqueue_random_access_ack(timeslot, addr)` (`umac_bs.rs:657`). Der Scheduler merkt sich: "Für SSI X auf TS Y muss ein RA-Ack raus." (`bs_sched.rs:411`)

Zwei Emissions-Varianten:

**Variante 1 — Piggyback in bestehender MAC-RESOURCE:**
Falls schon ein anderes DL-MAC-RESOURCE an diese SSI queued ist (z.B. D-LOC-UPDATE-ACCEPT), wird in dieses Paket `random_access_flag = true` gesetzt (`bs_sched.rs:683-686`). Das Paket trägt dann DOPPELTE Funktion: MM-Inhalt + RA-Ack.

**Variante 2 — Standalone-Stub-MAC-RESOURCE (ohne SDU):**
Falls noch keine Resource an diese SSI geplant ist, baut der Scheduler eine **minimale MAC-RESOURCE-PDU ohne SDU** (`bs_sched.rs:574, 694`):
- Adresse = MS-SSI
- `random_access_flag = true`
- Keine weitere Payload (length_ind=0 / 1-Octet-Stub)

**bluestation umac_bs.rs:1176-1184:**

```rust
// random_access_flag: true for SSI-addressed (responses to random access requests),
// false for GSSI-addressed (unsolicited group signaling like D-SETUP).
// A radio will reject a random-access-flagged message if it didn't initiate one.
let is_random_access_response = prim.main_address.ssi_type != SsiType::Gssi;
```

**Abgrenzung zu anderen ACKs:**

| Ack-Mechanismus | Layer | Zweck |
|-----------------|-------|-------|
| `random_access_flag=1` im MAC-Header | MAC | Bestätigt MAC-Zugang (RA-Burst empfangen, bitte nicht mehr retry-en) |
| `BL-ACK` LLC-PDU (Type 3) | LLC | Bestätigt LLC-SDU-Empfang (`N(R) = ns_seen + 1`) |
| Piggyback `N(R)` in BL-ADATA | LLC | LLC-ACK wird zusammen mit nächstem Daten-Paket gesendet |

Ohne `RandAccFlag=1` cycled MS unbegrenzt neue RAs ungeachtet aller MM-Layer-Korrektheit.

**Unser RTL aktuell:** `RandAccFlag = 1'b0` hartverdrahtet in `tetra_mac_resource_dl_builder.v`. Wahrscheinlichster Haupt-Blocker der MS-Registration.

---

## 7. D-LOCATION-UPDATE-ACCEPT — Zentrales PDU für Registration

### 7.1 Vollständiges Layout per bluestation `d_location_update_accept.rs`

```
[4 bit]  PDU-Type = 0101 (ACCEPT)
[3 bit]  Location Update Accept Type = echoed from U-DEMAND
[1 bit]  O-bit — 1 wenn IRGENDEIN optional Feld folgt
────── Wenn O=0: PDU ENDE bei 8 Bit. ──────
────── Wenn O=1: Optional-Felder in dieser Reihenfolge: ──────
[1 bit]  P-bit SSI               (1 = SSI-Feld folgt)
[24 bit] SSI                     (ASSI/VASSI der MS)
[1 bit]  P-bit Address-Extension
[24 bit] Address-Extension        (MNI der MS)
[1 bit]  P-bit Subscriber-Class
[16 bit] Subscriber-Class
[1 bit]  P-bit Energy-Saving-Info
[var]    Energy-Saving-Info
[1 bit]  P-bit SCCH-info-and-Distrib-18
[6 bit]  SCCH-info-and-Distrib-18
────── Type-4/Type-3 Felder (mit M-bit per Feld, NICHT vorangestellter Präfix): ──────
[M + ...] New-Registered-Area (Type-4)
[M + ...] Security-Downlink (Type-3)
[M + ...] Group-Identity-Location-Accept (Type-3)
[M + ...] Default-Group-Attach-Lifetime (Type-3)
[M + ...] Authentication-Downlink (Type-3)
[M + ...] Group-Identity-Security-Related-Info (Type-4)
[M + ...] Cell-Type-Control (Type-3)
[M + ...] Proprietary (Type-3)
[1 bit]  Terminierendes M-bit = 0
```

### 7.2 bluestation Reference Accept (mm_bs.rs:273-288)

Was eine real-BS für ITSI-Attach-Erstregistrierung sendet:

```rust
let pdu_response = DLocationUpdateAccept {
    location_update_accept_type: pdu.location_update_type,   // echo demand
    ssi: Some(issi as u64),                                   // ← SSI IM MM-Body!
    address_extension: None,
    subscriber_class: None,
    energy_saving_information: esi,
    scch_information_and_distribution_on_18th_frame: None,
    new_registered_area: None,
    security_downlink: None,
    group_identity_location_accept: gila,
    default_group_attachment_lifetime: None,
    authentication_downlink: None,
    group_identity_security_related_information: None,
    cell_type_control: None,
    proprietary: None,
};
```

Anfangs-Minimum: `4+3+24+1+1+1 = 34 bit` (PDU-Type + LocAccType + SSI + O-bit + P-bit-SSI + terminierendes M-bit). Bei SSI-only grows to ~38 Bit (P-bits für andere Type-2-Felder = 0).

**Wrapper-Layer für den Accept:**
- `layer2service: Layer2Service::Acknowledged`
- `fcs_flag: false` (hart in mle_bs.rs)
- LLC: **BL-DATA (type 1)** als Default (keine piggyback-ACK pending). Falls beim Sende-Zeitpunkt ein UL-ACK vom selben MS eingetroffen ist → BL-ADATA (type 0) mit piggyback-NR.
- MAC-RESOURCE Wrapper mit `random_access_flag = 1` (RA-Ack piggyback!)

---

## 8. Registration-Protokoll (bluestation-Referenz, komplette Sequenz)

**Zwei UNABHÄNGIGE Protokoll-Phasen:**

- **Phase 1 — Registration (Location-Update):** Nach erfolgreichem D-LOC-UPDATE-ACCEPT + LLC-BL-ACK ist die MS **im Netz registriert**. Fertig. Sie muss keinen Group-Attach machen um als "angemeldet" zu gelten.
- **Phase 2 — Group-Identity-Attach:** Separat, nur wenn die MS Gruppen-Dienste (Group-Calls, Broadcast-Subscription) nutzen will. Triggert die MS selbstständig wenn eine Gruppe aktiv werden soll.

Die Phasen sind unabhängig: eine registrierte MS ohne Group-Attach kann trotzdem Einzelrufe empfangen. Unsere MTP3550-Blocker-Analyse muss sich auf Phase 1 konzentrieren.

### 8.1 Phase 1 — ITSI Attach / Location Update

```
MS                                                           BS
│                                                             │
│  ── UL CB 127sym, SCH/HU ─────────────────────────────────► │
│     MAC-ACCESS                                              │
│     └─ addr_type = Event-Label (MS hat noch keine ISSI-Reg) │
│     LLC: BL-DATA (type 1, no FCS)                           │
│     └─ MLE-PD = MM (1)                                      │
│        └─ MM PDU-Type = U-LOCATION UPDATE DEMAND (0x4)     │
│           └─ location_update_type = ITSI attach (3)         │
│           └─ optional: class_of_ms, energy_saving_mode,    │
│              groups[], address_extension                    │
│                                                             │
│  [UMAC: dl_enqueue_random_access_ack(slot, issi)]           │
│  [MLE → MM: parst ULocationUpdateDemand]                    │
│  [MM: client_mgr.update_client(issi, class_of_ms, ...)]     │
│  [MM: baut DLocationUpdateAccept]                           │
│                                                             │
│  ◄────────────────────── DL SCH/F, MAC-RESOURCE ─────────── │
│     MAC-RESOURCE                                            │
│     ├─ random_access_flag = 1  ← RA-Ack piggybacked         │
│     ├─ addr_type = SSI (1)                                  │
│     └─ ssi = MS-ISSI                                        │
│     LLC: BL-DATA (type 1, no FCS) — oder BL-ADATA wenn     │
│          UL-ACK im selben Slot zusammen läuft               │
│     └─ MLE-PD = MM (1)                                      │
│        └─ D-LOCATION UPDATE ACCEPT (0x5)                    │
│           ├─ location_update_accept_type = ITSI attach (3)  │
│           ├─ ssi = MS-ISSI (im MM-Body, 24-bit)             │
│           └─ optional: energy_saving_info,                  │
│              group_identity_location_accept                 │
│                                                             │
│  [MS: REGISTERED (bzgl. Lokation)]                          │
│                                                             │
│  ── UL NUB, MAC-END ───────────────────────────────────────►│
│     LLC: BL-ACK (type 3)                                    │
│     └─ N(R) = ns_seen + 1                                   │
│                                                             │
│  [BS: client_mgr markiert Accept als bestätigt,             │
│       kein Retransmit nötig]                                │
```

### 8.2 Phase 2 — Group Identity Attach (unabhängig von Phase 1)

```
MS                                                           BS
│                                                             │
│  ── UL CB 127sym / oder ad-hoc NUB ──────────────────────── │
│     MAC-ACCESS (auf RA-Slot) / MAC-END (auf assigned UL)   │
│     LLC: BL-DATA (type 1)                                   │
│     └─ MLE-PD = MM                                          │
│        └─ MM PDU-Type = U-ATTACH/DETACH GROUP IDENTITY      │
│           ├─ group_identity_attach_detach_mode              │
│           └─ group_identity_uplink[] mit GSSI/class_of_usage│
│                                                             │
│  [MM: parst UAttachDetachGroupIdentity]                     │
│  [MM: detach_all optional]                                  │
│  [MM: attach/detach Gruppen in client_mgr]                  │
│  [MM: baut DAttachDetachGroupIdentityAcknowledgement]       │
│                                                             │
│  ◄── DL MAC-RESOURCE ───────────────────────────────────── │
│     LLC: BL-DATA                                            │
│     └─ MM: D-ATTACH/DETACH GROUP IDENTITY ACK               │
│        ├─ group_identity_accept_reject = 0 (accepted)       │
│        └─ group_identity_downlink[] mit akzeptierten GSSI  │
│                                                             │
│  [MS: REGISTERED + ATTACHED to groups]                      │
│                                                             │
│  ── UL, LLC BL-ACK ────────────────────────────────────────►│
```

### 8.3 Was im BS-Stack passiert (bluestation-Referenz)

| Schritt | Modul | Aktion | Code-Pfad |
|---------|-------|--------|-----------|
| 1 | PHY | Demoduliert CB-Burst 127 sym, SCH/HU-Decoder liefert 92 info bits | `rtl/rx/tetra_ul_sch_hu_decoder.v` |
| 2 | UMAC | Parst MAC-ACCESS-Header → extrahiert SSI/addr_type/SDU; ruft `dl_enqueue_random_access_ack()` | `umac_bs.rs:657` |
| 3 | LLC | Parst BL-DATA LLC-Header, erzeugt bei `ns!=vs_expected` einen LLC-ACK-Schedule; reicht TL-SDU an MLE | `llc_bs_ms.rs` |
| 4 | MLE | Liest 3 bit ProtDisc → bei MM → weiter an MM | `mle_bs.rs:101` |
| 5 | MM | Parst `ULocationUpdateDemand`, registriert MS in `client_mgr`, baut `DLocationUpdateAccept` | `mm_bs.rs:117, 273-288` |
| 6 | MLE | Fügt MLE-PD (3b=001 für MM) voran an die MM-PDU | `mle_bs.rs` |
| 7 | LLC | Wählt PDU-Typ: `BL-DATA` default / `BL-ADATA` wenn UL-ACK piggyback | `llc_bs_ms.rs:276-301` |
| 8 | UMAC | Wrapping in MAC-RESOURCE mit `random_access_flag=1` (falls RA-Ack queued), `addr_type=SSI`, `ssi=issi` | `umac_bs.rs:1176-1204` oder `bs_sched.rs:683` |
| 9 | PHY-TX | SCH/F-Encoding: CRC16 → tail → RCPC 2/3 → interleave K=432 a=103 → scramble → 432 coded bits | `rtl/lmac/tetra_sch_f_encoder.v` |
| 10 | Scheduler | Setzt Accept auf MCCH-Slot (TN=1) | `bs_sched.rs` |
| 11 | LLC-State | Speichert outbound (NR/NS, Timer) für Retransmit falls MS keinen BL-ACK schickt | `llc_bs_ms.rs:304-338` |

### 8.4 Unser RTL — Lücken pro Schritt

| Schritt | Status | Lücke |
|---------|--------|-------|
| 1 PHY UL RA | ✅ | — (HW-verifiziert 41/42 CRC) |
| 2 UMAC RA-Ack schedulen | ❌ | Kein `dl_enqueue_random_access_ack` — `RandAccFlag=0` hartverdrahtet |
| 3 LLC parsing (BL-DATA) | ⚠️ | MAC-ACCESS-Parser extrahiert nicht TL-SDU → LLC-Header nicht erreicht |
| 4 MLE-Routing | ⚠️ | Parser erkennt MM-PDU-Type, leitet aber nicht layer-gerecht weiter |
| 5 MM Handling | ⚠️ | `tetra_d_location_update_encoder.v` produziert PDU ohne echte O/P/M-Bit-Struktur (falsch!) |
| 6 MLE PD prepend | ✅ | In `tetra_mac_resource_dl_builder.v` gemacht |
| 7 LLC wrapper | ❌ | Nutzt BL-ADATA+FCS (type 4) mit FCS statt BL-DATA (type 1) ohne FCS |
| 8 MAC-RESOURCE wrap | ❌ | RandAccFlag=0, 3 presence-flags unkonditional (Bug #7 teilweise behoben) |
| 9 SCH/F encoding | ✅ | Funktioniert |
| 10 Slot-scheduling | ⚠️ | Fixes TN=0 (ETSI TN=1), nicht MS-spezifisch |
| 11 LLC-State + Retransmit | ❌ | Kein NR/NS-Tracking, kein Retransmit-Timer, kein UL-BL-ACK-Parser |

### 8.5 Group-Attach-Pfad ist bisher NICHT im RTL

Phase 2 ist komplett unbebaut:

- Kein `tetra_u_attach_detach_group_parser.v`
- Kein `tetra_d_attach_detach_group_ack_encoder.v`
- Kein Group-Shadow-BRAM (siehe `ARCHITECTURE.md §4.3 M3` für geplante Module)

**Diese Lücke blockiert NICHT die Phase-1-Registration.** Eine MS die nur anmelden will (kein Gruppen-Interesse), läuft ohne Phase 2. Für Group-Call-Funktionalität (M3) kommt Phase 2 dran — erst dann relevant.

Der aktuelle MTP3550-Registration-Blocker liegt in Phase 1, nicht in fehlender Phase 2.

---

## 9. Offene Registration-Blocker (Stand 2026-04-25)

Seit 2026-04-24 adressiert unser Stack Accepts two-phase (AL-SETUP SCH/HD +
BL-ADATA SCH/F, Commit `2c8ad4a`), seit 2026-04-25 mit der **echten 24-bit-ISSI**
aus dem UL MAC-ACCESS-Header (6 Commits `eeabf1f`→`1f1ec3a`). Der zuvor auf
Air sichtbare Artefakt-SSI `523` ist verschwunden. Was noch offen ist:

### 9.1 Verbleibende Abweichungen vs. bluestation

| # | Bereich | Unser RTL | bluestation Referenz |
|---|---------|-----------|----------------------|
| B | **MM-Body-Gesamtgröße** | LI=11 (SSI only) | LI=21 (address_extension=MNI, subscriber_class, energy_saving_info=StayAlive) |
| C | **LLC-Typ im Accept** | 0 (BL-ADATA, NR+NS, no FCS) — ok | 0 (BL-ADATA, wenn ACK piggyback) / 1 (BL-DATA, default) |
| D | **FCS-Berechnung** | weggelassen (ok) | `fcs_flag: false` hart in `mle_bs.rs:212/277/301` |
| E | **NR/NS-Tracking** | hart 0/0 | pro MS `V(S)`-Toggle in HashMap (`llc_bs_ms.rs:126-131`) |
| F | **UL-BL-ACK-Empfang** | fehlt komplett | `rx_mac_end_ul` parst BL-ACK von MS (`umac_bs.rs:782`) |
| G | **Retransmit-Loop** | fehlt | `outbound_messages` + Timer + Retry-Counter (`llc_bs_ms.rs:304-338`) |
| H | **Slot-aware Delivery** | `REG_SIGNAL_TARGET_TN=0` default | pro-MS RX-Slot gespeichert, Accept landet dort |
| I | **Subscriber-Shadow-BRAM** | fehlt | permit/LA/home-cell Lookup pro ISSI |
| J | **Group-Identity-Attach (Schritt 2)** | fehlt | `u_attach_detach_group_identity.rs` + Handler in `mm_bs.rs` |

### 9.1.1 Abgehakt (2026-04-23 bis 2026-04-25)

| # | Bereich | Status |
|---|---------|--------|
| A | **RandAccFlag** im MAC-Header | ✅ `90bda0a` — =1 für SSI-adressierte Response |
| — | **24-bit ISSI-Extraktion** (Parser-Bug) | ✅ `eeabf1f..1f1ec3a` (6 Commits, 2026-04-25) |
| — | **Two-Phase-Attach-Flow** | ✅ `2c8ad4a` — SCH/HD AL-SETUP LI=7 pre-reply + SCH/F BL-ADATA LI=21 Accept |
| — | **AACH auf addressiertem Slot** | ✅ `Unalloc/Unalloc` wie Gold-Ref |

### 9.2 Plausible Root-Cause-Hypothesen (ranked)

**Hypothese 1 — RandAccFlag (~60 % Impact-Chance):**
ETSI §21.4.3.1 wörtlich: *"shall be used for the BS to acknowledge a successful random access so as to prevent the MS sending further random access requests."* bluestation `umac_bs.rs:657` ruft `dl_enqueue_random_access_ack()` SOFORT nach jedem empfangenen UL-MAC-ACCESS. Unser RTL hat das gar nicht.

**Hypothese 2 — LLC-Typ + FCS falsch (~20 %):**
Unser RTL nutzt BL-ADATA+FCS (type 4) mit 32-Bit-FCS-Append. bluestation nutzt BL-DATA (type 1) ohne FCS. Falls MS strikt auf LLC-Type-Bit 4 (`has_fcs`-Bit im LLC-Header) matcht und dann 32 Bit FCS erwartet die nicht stimmen → silent drop.

**Hypothese 3 — MM-Body-Struktur falsch (~10 %):**
Unser 16-bit Minimal-Accept hat 9 einzelne 0-Bits statt echter O/P/M-Bit-Struktur. Bei O-bit=0 endet die PDU korrekt nach 8 Bit, die 8 extra 0-Bits sind "Stuff-Bits innerhalb der MAC-RESOURCE-Fill" und eigentlich MS-egal. Daher niedrigere Priorität.

**Hypothese 4 — Authentication (~10 %):**
MTP3550 könnte für Reg eine Auth-Challenge erwarten, die wir nicht schicken. Dann wäre der Blocker im Policy-Layer, nicht Protokoll.

### 9.3 Verworfene Hypothese — Phase 3 AACH Dynamic DL-Assign (2026-04-24)

**Status: VERWORFEN**. Spekulation, dass die MS einen AACH-Header-Switch auf `01` (Assigned) oder `10` (Common+Assigned UL) mit individuellem Usage Marker beim RA/ITSI-Attach benötigt. Hypothese wäre gewesen: MLE-FSM emittiert einen Grant-Pulse 1-Frame-ahead, AACH-Encoder schaltet auf "DL-Assignment-Addressed". TN-Wahl käme aus UL-MAC-ACCESS.

**Widerlegt durch BlueStation-Audit von `bs_sched.rs::generate_bbk_block` (Zeilen 1079-1171) und `dl_integrate_sched_elems_for_timeslot` (Zeilen 656-711):**
- AACH-Builder branched ausschließlich auf `ts.f`, `ts.t`, `traffic_usage`, `hangtime` — nie auf Queue-Inhalt
- TS1 (MCCH): immer hart `CommonControl/CommonOnly`, statische Access-Fields mit `base_frame_len=4`
- Kommentar im Code: "MS with a grant transmits in granted slots without checking the AACH" (§23.5.2.2.2)
- `DlSchedElem::RandomAccessAck(addr)` setzt **nur** `pdu.random_access_flag = true` auf der MAC-RESOURCE, keine AACH-Manipulation
- `umac_bs.rs` hat 0 Treffer auf `aach|AccessAssign|dl_usage` (1614 Zeilen)
- MAC-ACCESS PDU (§21.4.3.3) hat kein proposed-TN-Feld; TN-aus-UL ist nicht standardisiert

Details + Code-Zitate siehe `.ralph/chat.md` Eintrag "[2026-04-24] Ralph — BlueStation-AACH-Verifikation abgeschlossen".

**Konsequenz:** Unser AACH-Encoder (TS1 TN=0: `header=00, info=0x0249`, DL/UL-Assign Common/Random CC=9) ist strukturell bluestation-kompatibel. Weitere AACH-Edits sind nicht indiziert. Neuer Hauptverdacht: strukturelle Fast-Path/Slow-Path-Trennung beim MAC-RESOURCE-RA-Ack (leere Stub-PDU zuerst, Accept-Body separat später) — siehe §9.1 Punkt A ("Standalone-Stub-MAC-RESOURCE ohne SDU").

### 9.4 Gold-Reference-Capture (2026-04-25)

Hauptdurchbruch: simultaner DL+UL-Capture einer fremden TETRA-BS bei
**392.9875 MHz** (MCC 262, MNC 1010, CC 1, LA 1) während sich eine
**MS ISSI 2 633 716** erfolgreich einbucht.

| Datei | Inhalt |
|-------|--------|
| `docs/references/captures_external_bs_2026-04-25/baseband_393084625Hz_*.wav` | DL @ 393.0846 MHz (97 kHz off), sr=250 kHz, 18.1 s |
| `docs/references/captures_external_bs_2026-04-25/baseband_382468718Hz_*.wav` | UL @ 382.4687 MHz (519 kHz off), sr=1.536 MHz, 17.7 s |
| `…/decode_dl_full.log` | 1278 Burst-Slots, alle CRC-OK |
| `…/attach_sequence_bursts.txt` | Attach-relevante DL-Bursts mit Bit-Dumps |

**Time-aligned attach sequence:**

| Abs time | Side | Event |
|----------|------|-------|
| 00:12:01.36 | UL #0 | MAC-ACCESS addr=Ssi(ISSI=2 633 716) frag=1 LLC=BL-DATA NS=0 + DirectMM |
| 00:12:01.41 | UL #1 | MAC-U-BLCK |
| 00:12:01.53 | UL #2 | MAC-ACCESS addr=Ssi(ISSI=2 633 716) LI=6 LLC=BL-ACK NR=0 (ackt BS BL-DATA NS=0) |
| 00:12:02.30 | DL #727 | SCH/HD AL-SETUP addr=SSI=2 633 716 LI=7 — BS pre-reply |
| 00:12:02.40 | DL #735 | SCH/F BL-ADATA NR=0 NS=0, D-LOC-UPD-ACCEPT, LI=21 — BS full Accept |

**Implikationen für unseren Stack** (siehe README.md des Capture-Ordners für Details):
1. RTL-UL-Parser: 2 bit `addr_type` + 24 bit ISSI extrahieren — ✅ Commit `eeabf1f`
2. MLE-FSM adressiert Accept mit der echten 24-bit-ISSI — ✅ Commit `4ccbed8`
3. D-LOC-UPD-ACCEPT MM-Body auf LI=21 erweitern (address_extension=MNI,
   subscriber_class, energy_saving_information=StayAlive) — ⏳ offen

**Konsequenz:** "Kein bekannter working reference capture" ist erledigt.
Wir haben jetzt einen bit-genauen Goldpfad für den vollen Attach-Handshake
inkl. UL-BL-ACK-Pfad — die historische LMAC-Lücke für M2 ist
re-bewertet.

---

## 10. Cell-Acquisition-Sequenz (Receiver-Sicht)

Aus SDRSharp + unser eigenes `decode_dl.py`:

**1. Training-Sequence-Detection** → Burst-Typ identifizieren (NDB1/NDB2/SB)

**2. Bei SB-Detect (BurstType=3):**
   - SB (120 dibits) extrahieren
   - Descramble mit **init=3 fix** (nicht Netzwerk-Code!)
   - Deinterleave (K=120, a=11)
   - Depuncture r=2/3
   - Viterbi decode → 76 bit (60 info + 16 CRC)
   - CRC-Check → 60 info bits

**3. SYNC-PDU parsen:**
   - MCC, MNC, ColourCode extrahieren
   - `network_scramb_init = (MCC<<22) | (MNC<<8) | (CC<<2) | 3` berechnen
   - `network_scramb_init` ab jetzt für alle BKN-Channels
   - TN, FN, MN → `NetworkTime.Synchronize(TN+1, FN+1, MN+1)`

**4. BKN2 von SB-Burst dekodieren → SYSINFO.**

**5. Bei NDB-Bursts:** BB-Block via RM(30,14) → 14-bit AACH → Channel-Alloc-Info. BKN1+BKN2 je nach Allocation:
   - Full-slot SCH/F: 432 bit → deinterleave(K=432,a=103) → decode → 268 bit
   - Half-slot SCH/HD: 216 bit → deinterleave(K=216,a=101) → decode → 124 bit

**6. MAC-PDU-Routing:** 2-bit Header-Typ dispatcht zu Parser.

**7. LLC → MLE → CMCE/MM/SDS.**

### 10.1 MER (Receiver-seitig)

SDRSharp zählt alle 100 Bursts:
```
MER_pct = (bad_burst_count / time_count) * 100
// bad += 0.5 pro fehlgeschlagenem CRC
// bad += 1.0 pro fehlendem Burst (keine Training-Seq detected)
```

Also "Burst Error Rate" in %, nicht MER im RF-Sinn.

---

## 11. Referenz-Magics (schnell nachschlagen)

| Konstante | Wert | Verwendung |
|-----------|------|------------|
| Scrambler-Poly | 0xDB710641 | LFSR-AND-Maske |
| Scrambler-Default-Init | 0x00000003 | SB/BSCH immer |
| CRC-16-Poly | 0x8408 | reflected CCITT-16 |
| CRC-16-Init | 0xFFFF | |
| CRC-16-Good | 0xF0B8 | Residual |
| CRC-32-Poly | 0x04C11DB7 | LLC-FCS forward-form |
| CRC-32-Poly-Reflected | 0xEDB88320 | SDRSharp LLC-FCS-Check |
| CRC-32-Good | 0xDEBB20E3 | Residual (reflected) |
| CRC-32-Good (forward) | 0xC704DD7B | Residual (forward) |
| SCH/F-Interleave (K,a) | (432, 103) | |
| SCH/HD-Interleave (K,a) | (216, 101) | |
| BSCH-Interleave (K,a) | (120, 11) | |

### 11.1 Unser Cell-Default

```
MCC = 901  (Test-MCC)
MNC = 9998 (Test-MNC)
CC  = 49   (Test-ColourCode)
→ network_scramb_init = (901<<22) | (9998<<8) | (49<<2) | 3
                       = 0xE1670EC7
Carrier = 1530 (Band 4)
DL-LO   = 438.25 MHz
UL-LO   = 428.25 MHz (10 MHz Duplex, Band 4 Code 0)
LA      = 1 (Default, via REG_CELL_LA settable)
```

---

## 12. Script-Tool-Landkarte

| Tool | Zweck | Referenz |
|------|-------|----------|
| `scripts/decode_dl.py` | Voll-DL-Decoder inkl. MAC/LLC/MLE/MM-Parsing | Kapitel 10 |
| `scripts/decode_ul.py` | UL-RA-Decoder (41/42 CRC-Pass live) | |
| `scripts/decode_ul_raw.py` | Raw-92-Bit-Hex-Parser für `tetra_ul_mon.log`-Einträge | Kapitel 6.4 |
| `scripts/wav_to_tkbits.py` | WAV → tetra-kit Input | externer Decoder-Abgleich |
| `scripts/gen_sch_f_tv.py` | SCH/F-Test-Vektoren (Python-Referenz) | |
| `scripts/verify_sb1_encoder.py` | BSCH-Encoder-Referenz | |

---

## 13. Referenzen

**ETSI-Spec (Hauptquelle):**
- EN 300 392-2 V3.x: TETRA V+D Air Interface (PHY, MAC, MLE, MM, CMCE)
- EN 300 392-7: Security
- EN 300 395-2: TETRA Speech Codec (ACELP)
- TS 100 392-15: Frequency bands

**Open-Source-Implementierungen (lokale Referenz):**
- `osmo-debug-rx/vendor/osmo-tetra/src/` — Decoder-Referenz (Harald Welte, Gitea)
- `tetra-kit/` (extern) — Zweit-Decoder für Validierung
- `tetra-bluestation` (via GitHub clone in `/tmp/bs-ref/`) — **einzige Rust-BS-Referenz**
  - `crates/tetra-pdus/src/mm/pdus/d_location_update_accept.rs` — PDU-Parser/Serializer
  - `crates/tetra-entities/src/mm/mm_bs.rs` — MM-BS-State-Machine
  - `crates/tetra-entities/src/llc/llc_bs_ms.rs` — LLC mit NR/NS-Tracking + Retransmit
  - `crates/tetra-entities/src/umac/umac_bs.rs` — Upper-MAC + `rx_mac_end_ul` (BL-ACK)
  - `crates/tetra-entities/src/llc/components/fcs.rs` — CRC-32-Implementation
- `SDRSharp.Tetra.dll` (reverse-engineered, 2026-04-18) — RX-only C#-Plugin-Analyse

**Projekt-Docs:**
- `docs/ARCHITECTURE.md` — RTL-Stack, Modul-Status, Meilensteine
- `docs/HARDWARE.md` — Plattform, AXI-Regs, CDC, Timing
- `docs/OPERATIONS.md` — Deploy, Test, Debugging
