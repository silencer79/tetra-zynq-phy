# 05 — Kanalcodierung und -decodierung

**Scope:** Alle Fehlerschutz- und Verschleierungsverfahren zwischen Nutzinformation
(type-1) und gesendeten Bits (type-5): Prüffeld, RCPC-Faltungscode mit Punktierung,
Blockinterleaving, Scrambling, verkürzter Reed-Muller-Blockcode, Viterbi-Decodierung mit
Soft-Entscheidungen — und darauf aufbauend die vollständige Kette je logischem Kanal in
beiden Richtungen.

**Nicht hier:** Sample-Signalverarbeitung, Demodulation, Soft-Bit-Erzeugung → `02`
(DL-RX), `03` (UL-RX), `04` (TX/TDMA). Semantik der MAC-PDUs, Längenindikator, Stealing,
AACH-**Inhalt** → `06`. Registeradressen und Mailbox-Formate → `07`. Slot-Deadlines und
gemessene Latenzen → `08`. ACELP-Quellcodierung → `12`.

**Abhängigkeiten:** `00` (Architektur-Schnitt §3, Prinzipien P1–P7), `03` §3.2
(Soft-Vorzeichenkonvention K1–K3), `04` §3.11 (Bit-Order-Regel R).

---

## 1. Anforderungen

| Nr. | Anforderung |
|---|---|
| **R-05-01** | Die Kanalcodierung und -decodierung der **Nutzdaten** aller logischen Kanäle liegt vollständig in Software. Es existiert im gesamten System **genau eine** Implementierung je Primitiv (Prüffeld, Faltungscodierer, Punktierer, Interleaver, Scrambler, Viterbi). Ein zweiter Codierer derselben Funktion — in RTL, in einem zweiten C-Modul oder in einem Werkzeug-Skript, das Produktionscode ersetzt — ist ein Spec-Verstoß. |
| **R-05-02** | Die einzigen Kanalcodierer in Hardware sind **BSCH** (Broadcast-Synchronisation, 60 → 120 bit) und **AACH** (Zugriffszuweisung, 14 → 30 bit). Beide sind slot-deadline-gebunden nach `00` §3.2 Punkt 4. Keine weiteren. |
| **R-05-03** | Der 16-Zustands-Mutter-Code arbeitet mit den ETSI-Generatorpolynomen in der ETSI-Zustandskonvention (§3.2.2). Jede Implementierung — Encoder, Decoder, Testvektor-Generator — nutzt dieselbe Konvention. Eine bit-vertauschte Zustandskonvention ist verboten, auch wenn Encoder und Decoder desselben Paares zueinander passen. |
| **R-05-04** | Es gibt **eine** normative Generatormatrix für den verkürzten (30,14)-RM-Code: die aus `[ETSI §8.2.3.2 Gl. 8.13]`. Jede andere (30,14)-Matrix ist verboten, auch wenn sie dieselbe Mindestdistanz erreicht (§3.5.3). |
| **R-05-05** | Die Scrambler-Initialisierung ist genau **eine** Funktion mit genau **einer** Bitanordnung (§3.4.3). Der Zeitschlitz geht **nicht** in die Initialisierung ein. Die untersten zwei Bits sind konstant `2'b11`. |
| **R-05-06** | Der Farbcode wird an jede Schnittstelle **unverschoben** übergeben (Wertebereich 0…63). Kein Konsument erhält einen bereits in den Scrambler-Startwert eingebetteten Farbcode. |
| **R-05-07** | Für BSCH ist der erweiterte Farbcode `e(1)…e(30) = 0`, der Startwert damit `0x00000003` [ETSI §8.2.5.2]. Alle anderen Kanäle nutzen den zell-spezifischen Startwert. |
| **R-05-08** | Soft-Entscheidungen folgen der Konvention aus `03` §3.2.2 (K1): **`soft > 0 ⇔ Bit '0'`, `soft < 0 ⇔ Bit '1'`, `soft = 0 ⇔ Erasure`**, 8 bit signed, symmetrisch gesättigt auf ±127. Der Viterbi gewichtet mit `\|soft\|` (§3.6.3). |
| **R-05-09** | Es existiert im System **höchstens eine** Vorzeichen-Inversion von Soft-Werten, und sie liegt in der SW-Adaption zum Sprachcodec-Decoder (`03` K3). Kein RTL-Modul und kein Signalisierungs-Decoder invertiert. |
| **R-05-10** | Der Pfadmetrik-Datentyp des Viterbi hält den Worst-Case `n_stages · n_out · \|soft\|_max` ohne Überlauf. Für den Sprachkanal (184 Stufen, 3 Ausgänge, `\|soft\| ≤ 127`) ist das ≥ 32 bit (§3.6.4). |
| **R-05-11** | Alle Faltungsblöcke sind mit `K−1 = 4` Nullbits terminiert. Die Rückverfolgung startet **unbedingt im Zustand 0**, nicht am Minimum der Pfadmetriken (§3.6.2). |
| **R-05-12** | Jeder Decodierversuch erhöht einen Versuchszähler; jeder Prüffeld-Fehler einen Fehlerzähler — je logischem Kanal getrennt und im Betrieb über AXI lesbar (P6). |
| **R-05-13** | Ein Prüffeld-Fehler verwirft die PDU. Die decodierten Informationsbits werden trotzdem bereitgestellt, aber als „ungeprüft" gekennzeichnet; kein Protokollzustand darf aus ungeprüften Bits verändert werden. |
| **R-05-14** | Bit-Order: auf jedem Bus und in jedem Mailbox-Wort, das **Bits** trägt, liegt das **zuerst gesendete Bit im MSB** (`04` §3.11 Regel R). In C-Bitarrays gilt: Index 0 = zuerst gesendetes Bit. Beide Darstellungen werden an genau einer Stelle je Richtung umgerechnet (§2.3). **Ausnahme, abschließend:** Fenster, die keine Bits, sondern **mehrbit-Zahlenwerte** tragen — die UL-Soft-Wert-Wörter — folgen `07` §3.2: LSB-first innerhalb des Worts, Index aufsteigend mit der On-Air-Zeit (`DATA[8·n +: 8] = soft[4·d + n]`, normativ `07` §3.4 und `03` §3.6.4). Ein Byteplatz kann nicht „zuerst gesendet = MSB" folgen, weil er keine Sendereihenfolge hat. Für alle Bit-Ports gilt die MSB-Regel unverändert. |
| **R-05-15** | Ein Startwert `0x00000000` des Scramblers ist entartet (Ausgangsfolge konstant 0). Jede Scrambler-Instanz ersetzt ihn durch `0xFFFFFFFF` und erhöht einen Diagnosezähler. |
| **R-05-16** | Jede Kette ist gegen die Gold-Aufzeichnung abgenommen: type-5 → Informationsbits **bit-identisch** für BSCH, SCH/HD, SCH/F, AACH und SCH/HU, zusätzlich type-5 → type-4 bit-identisch für SCH/HU (§5.2). |
| **R-05-17** | Die vollständige SW-Kette hält ihre Zeitbudgets ein: DL-Codierung einer Signalisierungs-PDU < 1 Zeitschlitz (14,167 ms), UL-Decodierung eines Bursts < 1 Zeitschlitz, Sprach-Transcodierung eines 60-ms-Rahmens < 60 ms — gemessen auf dem Zielprozessor, nicht geschätzt (§3.10, §6 O-05-1). |

---

## 2. Architektur / Aufbau

### 2.1 Wo die Codierung liegt

```
  SOFTWARE (PS)                                      HARDWARE (PL)
  ─────────────                                      ─────────────
  Body → MAC → LLC → MLE  (09/10/11)
        │ type-1
        ▼
  tetra_cc_encode(kanal, info, seed)
   Prüffeld → Tail → RCPC → Punktierung
   → Interleave → Scramble
        │ type-5 (432 / 216)   ── Mailbox (07) ──▶  Signalisierungs-Queue
        │                                           → Slot-Zeitplan → TX
  ACELP → tetra_cc_encode(TCH_S)  ── Mailbox (07) ──▶ Halteplatz (PERSIST_SET) → TX

  tetra_cc_decode_soft(kanal, soft, seed)  ◀──────   Soft-Burst-Mailbox
   Descramble → Deinterleave → Depunktierung          + TDMA-Zeitstempel
   → Viterbi → Prüffeld                               (R-00-04)
        │ type-1 → MAC/LLC/MLE (06/09)
                                                     ┌─────────────────────┐
  Nur diese zwei Codierer bleiben in RTL, weil ihr   │ BSCH  60 → 120 bit  │
  Inhalt aus FN/MN des *Folge*slots entsteht und     │ AACH  14 →  30 bit  │
  nicht auf Software warten kann (00 §3.2, 04 §3.2.4)└─────────────────────┘
```

**Warum diese Grenze.** Der BSCH trägt die aktuelle Frame- und Multiframe-Nummer, die AACH
die Slot-Rolle — beide Inhalte stehen erst mit der Vorausschau auf den Folgeslot fest und
müssen vor dessen Sendezeitpunkt codiert sein (`04` §3.2.4). V1-Fehlerbild bei fehlender
Vorausschau: das Feld `SB1.TimeSlot` auf der Luft lief dem tatsächlichen Sendeslot um einen
TN nach [MESS 2026-04-21, TimeSlot-Feld unseres Downlinks gegen die Gold-Aufzeichnung,
belegt über die Fix-Historie `8c79123`: „SB1.TimeSlot on air lagged the actual air slot by
one TN (observed as -1 shift vs Gold)"]. Alle anderen Kanäle tragen
ereignisgesteuerten Inhalt mit mehr als einer Slot-Dauer Spielraum und wandern nach
Prinzip P1 („wer den Body baut, codiert ihn") vollständig in die Software.

**Was V1 an dieser Stelle tut — Begründung, nicht Vorbild.** Jede Kanalcodierung existiert
dort mindestens zweimal, für SCH/F dreimal:

| Kanal | RTL-Codierer | SW-Codierer | Was in V1 auf die Luft geht |
|---|---|---|---|
| BSCH (SB1) | `tetra_sb1_encoder` [CODE rtl/tx/tetra_sb1_encoder.v:43] | `tetra_write_sysinfo` [CODE sw/tetra_hal.c:885-917] | **RTL.** Der SW-Pfad schreibt Register, die niemand liest: „legacy AXI path — unused in tx_chain" [CODE rtl/tetra_zynq_top.v:1066-1068] |
| AACH | `tetra_aach_encoder` + `tetra_aach_rm_encoder` | `build_aach` / `build_aach_capaloc` [CODE sw/tetra_hal.c:444-502] | **RTL**, SW-Kopie ebenfalls ungenutzt |
| SCH/HD (BNCH im SB) | `tetra_sch_hd_encoder` | `tetra_bnch_encode` [CODE sw/tetra_hal.c:541-580] | **SW** — `sb_bkn2_data_sys` ist „still used" [CODE rtl/tetra_zynq_top.v:1069] |
| SCH/HD (Signalisierung) | `tetra_sch_hd_encoder` via `tetra_sch_hd_shared` | dieselbe SW-Funktion | **RTL** |
| SCH/F | `tetra_sch_f_encoder` [CODE rtl/lmac/tetra_sch_f_encoder.v:35] | `tetra_codec_schf_encode` [CODE sw/tetra_channel_codec.c:131] **und** `tetra_schf_encode` [CODE sw/tetra_hal.c:990] | **beide** — RTL über die Signalisierungs-Queue, SW über die Filler-Mailbox |
| SCH/HU (UL) | `tetra_ul_sch_hu_decoder` | `tetra_codec_schhu_decode_soft` | **RTL** (SW-Kette inert im Repo) |
| TCH/S | — | `tetra_bs_tch_s.c` **und** `tetra_etsi_tch_s.c` + `sw/etsi_codec/` | **`tetra_bs_tch_s.c`**; die zweite Implementierung ist mitgelinkt und wird nie aufgerufen |

Die Kopfzeile von `sw/tetra_channel_codec.c` benennt das Problem selbst: „Verbatim extract
from tetra_hal.c […] When tetra_hal.c is refactored to share this codec module the
duplicates there can be removed" [CODE sw/tetra_channel_codec.c:4-7]. Der Refactor kam
nicht; die Kopien blieben.

**Was V2 dadurch gewinnt.** Die entfallenden RTL-Module, mit der im Utilization-Report
ausgewiesenen Fläche (Tool-Ausgabe, keine Hardware-Messung):

| Modul | LUT | FF | RAMB18 | Beleg |
|---|---|---|---|---|
| `tetra_sch_f_encoder` | 2 271 | 1 934 | 0 | [BUILD 2026-06-20 `cur_hier_deep.rpt:142`] |
| `tetra_sch_hd_encoder` | 1 303 | 994 | 0 | [BUILD 2026-06-20 `cur_hier_deep.rpt:179`] |
| `tetra_ul_sch_hu_decoder` | 4 851 | 5 786 | 0 | [BUILD 2026-06-20 `cur_hier_deep.rpt:172`] |
| `tetra_ul_sch_f_decoder` (inkl. Viterbi + CRC) | 2 602 | 1 809 | 3 | [BUILD 2026-06-20 `cur_hier_deep.rpt:193`] |
| `tetra_ul_nub_to_schf` (Soft-Adapter) | 484 | 1 749 | 0 | [BUILD 2026-06-20 `cur_hier_deep.rpt:151`] |
| **Summe** | **≈ 11 500** | **≈ 12 300** | **3** | Der Bericht warnt selbst, dass Hierarchiesummen wegen Cross-Hierarchy-LUT-Combining nicht exakt addieren |

Diese Summe und die Summe der entfallenden MAC-Logik in `06 §2.1`
(≈ 3 000 LUT / ≈ 4 300 FF / 1 RAMB18) sind **disjunkt und dürfen addiert werden**: der
`tetra_sch_f_encoder` ist eine Unterinstanz von `tetra_dl_pdu_builder`, wird hier gezählt und
deshalb in `06 §2.1` ausdrücklich **nicht** [BUILD 2026-06-20 `cur_hier_deep.rpt:139-142`:
`u_dl_pdu_builder` 4 523/4 386 gesamt, davon eigene Hülle 5/917, `u_mac_res` 2 247/1 535,
`u_sch_f` 2 271/1 934].

**Nicht in dieser Summe:** der `tetra_lmac`-Baum (generischer Scrambler, Interleaver,
Deinterleaver, Depunktierer, RCPC, Viterbi, RM). Er ist in V1 **nicht instanziiert** —
`u_lmac` existiert im heutigen `rtl/` nicht mehr — und kostet damit **0 LUT / 0 FF**. Die
Werte 702 LUT / 513 FF (`tetra_lmac`) bzw. 94 LUT / 59 FF (`tetra_reed_muller`) aus
[BUILD 2026-06-20 `cur_hier_deep.rpt:146-147`] stammen aus einem Build **vor** der
Entfernung der Instanz (Report 16:13, Entfernung 21:56 desselben Tages, Commit `b92f47e`).
V2 gewinnt hier keine Fläche, sondern die entfallene Duplikat-Falle (§3.4.2, §3.5.3).

Zum Vergleich: das Gesamtdesign belegt 38 098 LUT / 46 401 FF [BUILD 2026-05-18
`impl_hier_util.rpt:25`]. In RTL bleiben `tetra_aach_encoder` (123 LUT / 116 FF) und
`tetra_sb1_encoder` (609 LUT / 657 FF) [BUILD 2026-05-18 `impl_hier_util.rpt:70,88`].

### 2.2 Das Ebenenmodell type-1 … type-5

ETSI benennt fünf Bitebenen [ETSI §8.1, Bilder 8.5/8.6]. V2 verwendet ausschließlich
diese Bezeichnungen; „coded bits", „raw bits", „air bits" sind verboten.

| Ebene | Inhalt | Erzeugt durch |
|---|---|---|
| type-1 | Nutzinformation der MAC-PDU | `06`/`09`/`10`/`11`/`12` |
| type-2 | type-1 + Prüffeld + 4 Tailbits | Blockcode (§3.1) |
| type-3 | punktierter Faltungscode | RCPC (§3.2) |
| type-4 | umsortiert | Blockinterleaver (§3.3) |
| type-5 | verschleiert, sendefertig | Scrambler (§3.4) |

**Reihenfolge, verbindlich, Senderichtung:**

```
type-1 ──Prüffeld(+16)──▶ ──Tail(+4 Nullen)──▶ type-2
type-2 ──RCPC r=1/4 (×4)──▶ ──Punktierung P_2/3──▶ type-3
type-3 ──Blockinterleaver (K,a)──▶ type-4
type-4 ──XOR Scrambler-Folge p(k)──▶ type-5
```

Empfangsrichtung ist die exakte Umkehr; abweichende Zwischenschritte
(z. B. Descramble nach Deinterleave) sind falsch, weil die Scrambler-Folge auf der
**type-4-Indexachse** definiert ist [ETSI §8.2.5.1 Gl. 8.38].

Zwei Kanäle weichen strukturell ab und dürfen nicht in dieses Schema gepresst werden:
**AACH** hat keinen Faltungscode und kein Interleaving (`type-4 = type-2`
[ETSI §8.3.1.1 Gl. 8.43]); **TCH/S** bringt type-3 aus der Sprachcodierung mit und nutzt
einen anderen Faltungscode und ein anderes Interleaving (§3.8.6).

### 2.3 Bit-Order und Ausrichtung

Regel R aus `04` §3.11 gilt unverändert: auf jedem Bus liegt das zuerst gesendete Bit im
MSB, kürzere Felder sind MSB-ausgerichtet. Ergänzend für die Software:

> **Regel B (verbindlich).** In C wird jede Bitfolge als `uint8_t[]` bzw. `int8_t[]` mit
> **einem Bit pro Byte** geführt. **Index 0 = ETSI-Bit 1 = zuerst gesendetes Bit.**
> Werte sind `0`/`1` (hart) bzw. `−128…+127` (soft).
>
> Die Umrechnung Array ↔ MSB-ausgerichtetes Mailbox-Wort geschieht an **genau zwei**
> Stellen im System: `tetra_cc_pack_msb()` (Senderichtung) und `tetra_cc_unpack_msb()`
> (Empfangsrichtung). Für ein Bitarray `b[0..N−1]` und Worte `w[0..⌈N/32⌉−1]` gilt
> `b[i] = (w[i/32] >> (31 − (i mod 32))) & 1`. Teilweise gefüllte letzte Worte sind
> **MSB-ausgerichtet**, ungenutzte niedrige Bits sind 0.

Der V1-Fall, den Regel B ausschließt: `tetra_ul_nub_to_schf` musste die 432 Soft-Werte
**vollständig umkehren**, weil der Erzeuger sie MSB-first mit BKN1 in der oberen Hälfte
ablegte, der Verbraucher aber On-Air-Ordnung erwartete — Symptom war 0 % Prüffeld-Erfolg
auf dem Board bei in Simulation korrektem Decoder
[CODE rtl/rx/tetra_ul_nub_to_schf.v:62-72].

### 2.4 Schnittstelle nach außen

Ein einziges SW-Modul `tetra_channel_coding` (`tetra_cc_*`) exportiert:

```c
typedef enum {                  /* logischer Kanal — bestimmt alle Parameter */
    TETRA_CC_SCH_F,             /* 268 → 432 */
    TETRA_CC_SCH_HD,            /* 124 → 216  (auch BNCH, auch STCH) */
    TETRA_CC_SCH_HU,            /* 92  → 168 */
    TETRA_CC_BSCH,              /* 60  → 120  (nur Referenz/Verifikation, HW codiert) */
    TETRA_CC_AACH,              /* 14  → 30   (nur Referenz/Verifikation, HW codiert) */
    TETRA_CC_TCH_S              /* 274 ACELP → 432 */
} tetra_cc_chan_t;

/* Startwert-Berechnung — die EINZIGE Stelle im System (R-05-05). */
uint32_t tetra_cc_scramble_seed(uint16_t mcc, uint16_t mnc, uint8_t colour_code);
#define   TETRA_CC_SEED_BSCH   0x00000003u

/* Senderichtung. info: type-1, ein Bit pro Byte, Index 0 = zuerst gesendet.
 * out:  type-5, gleiche Konvention. Rückgabe 0 = ok, <0 = Parameterfehler. */
int tetra_cc_encode(tetra_cc_chan_t ch, const uint8_t *info, uint32_t seed,
                    uint8_t *out_type5);

/* Empfangsrichtung, Soft. soft: type-5-Soft, K1-Konvention (R-05-08).
 * info_out wird IMMER gefüllt (best effort, R-05-13).
 * Rückgabe: 0 = Prüffeld ok, -1 = Prüffeld verletzt, <-1 = Parameterfehler. */
int tetra_cc_decode_soft(tetra_cc_chan_t ch, const int8_t *soft, uint32_t seed,
                         uint8_t *info_out, tetra_cc_stats_t *st);

/* Empfangsrichtung, hart — nur für Testvektoren und Regressionen. */
int tetra_cc_decode_hard(tetra_cc_chan_t ch, const uint8_t *type5, uint32_t seed,
                         uint8_t *info_out, tetra_cc_stats_t *st);
```

`tetra_cc_stats_t` enthält je Kanal `attempts`, `crc_fail`, `seed_degenerate`,
`erasure_count` und die minimale Endpfadmetrik (R-05-12, P6). Kein Aufrufer greift auf
Zwischenebenen zu; die Primitive (§3.1–§3.6) sind `static` im Modul. Wer eine
Zwischenebene für Diagnose braucht, bekommt sie über einen optionalen
`tetra_cc_trace_t`-Ausgang, nicht über exportierte Primitive.

---

## 3. Detail-Spezifikation

### 3.1 Prüffeld: (K1+16, K1)-Blockcode

**Zweck:** 16 Prüfbits über K1 Informationsbits. Identisch für alle Kanäle außer AACH und
TCH/S.

**Normativ** [ETSI §8.2.3.3 Gl. 8.14–8.18]:

- Generatorpolynom `G(X) = X¹⁶ + X¹² + X⁵ + 1` (= `0x1021`).
- Registerinitialisierung `0xFFFF`, MSB-first-Verarbeitung.
- Das Ergebnis wird **einerkomplementiert** (die Terme `Σ X^i, i=0…15` in Gl. 8.15).
- `b2(k) = b1(k)` für `k = 1…K1`; `b2(K1+k) = f(16−k)` für `k = 1…16`, d. h. das
  Prüffeld wird mit dem **höchstwertigen** Koeffizienten `f(15)` zuerst gesendet.

**Implementierung (bitseriell):**

```
crc = 0xFFFF
für jedes Informationsbit b (Index 0 = zuerst gesendet):
    fb  = b XOR ((crc >> 15) & 1)
    crc = (crc << 1) & 0xFFFF
    wenn fb: crc ^= 0x1021
fcs = crc XOR 0xFFFF
type2[K1 + i] = (fcs >> (15 − i)) & 1     für i = 0…15
```

[CODE sw/tetra_channel_codec.c:19-35] und bit-identisch
[CODE rtl/lmac/tetra_sch_f_encoder.v:100-103,167].

**Prüfung im Empfänger — zwei erlaubte Varianten, beide normativ äquivalent:**

1. **Neuberechnung:** Prüffeld über die ersten K1 decodierten Bits neu bilden und mit den
   folgenden 16 vergleichen [CODE sw/tetra_channel_codec.c:344-357].
2. **Restwert:** `K1 + 16` Bits durch dieselbe Maschine schieben; fehlerfrei ergibt sich
   der Restwert **`0x1D0F`** [CODE rtl/lmac/tetra_crc16.v:85].

Der Restwert `0x1D0F` ist verifiziert für K1 ∈ {60, 92, 124, 268}
[SIM 2026-07-25, eigene Nachrechnung, 5/5 Zufallsvektoren].

V2 verwendet Variante 1 (Neuberechnung), weil sie ohne Magic Constant auskommt und die
K1-Länge nicht in einen Restwert eincodiert.

**K1-Werte:** BSCH 60 → (76,60); SCH/HU 92 → (108,92); SCH/HD/BNCH/STCH 124 → (140,124);
SCH/F 268 → (284,268) [ETSI §8.3.1.2, §8.3.1.4.3, §8.3.1.4.1, §8.3.1.4.5].

**Tailbits:** Nach dem Prüffeld folgen **4 Nullbits**, die zu type-2 gehören
[ETSI §8.3.1.2: „Four tail bits … all set equal to zero, shall be appended"]. Sie
terminieren den Faltungscode im Zustand 0 und sind die Voraussetzung für R-05-11.

### 3.2 RCPC-Faltungscode

#### 3.2.1 Mutter-Code Rate 1/4

**Normativ** [ETSI §8.2.3.1.1 Gl. 8.1–8.6]: Jedes type-2-Bit `b2(k)` erzeugt vier
Ausgangsbits `V(4(k−1)+i)`, `i = 1…4`, mit

```
V(4(k−1)+i) = Σ_{j=0..4}  b2(k−j) · g_{i,j}      (mod 2),   b2(k−j) = 0 für k ≤ j
```

```
G1(D) = 1 + D      + D⁴        →  Tap-Maske 0b10011 = 0x13
G2(D) = 1 + D² + D³ + D⁴       →  Tap-Maske 0b11101 = 0x1D
G3(D) = 1 + D + D²  + D⁴       →  Tap-Maske 0b10111 = 0x17
G4(D) = 1 + D + D³  + D⁴       →  Tap-Maske 0b11011 = 0x1B
```

#### 3.2.2 Zustandskonvention (normativ) — die V1-Falle

> **Regel C.** Das 5-bit-Fenster ist `sr = (sr_alt << 1) | b`, maskiert auf `0x1F`.
> **`sr` Bit `j` trägt `b2(k−j)`**, also **Bit 0 = neuestes Bit `b2(k)`, Bit 4 =
> ältestes Bit `b2(k−4)`**. Der Generatorausgang ist `parity(sr & G_i)`.
> Der Trellis-Zustand ist `sr & 0xF` (die letzten vier Eingangsbits),
> Übergang `zustand_neu = ((zustand_alt << 1) | b) & 0xF`.
> Der Bitindex einer Tap-Maske ist damit **identisch mit dem D-Exponenten** des
> Generatorpolynoms.

Diese Konvention ist in V1 an den **live** laufenden Stellen korrekt umgesetzt:
[CODE sw/tetra_channel_codec.c:52-65] (`sr = ((sr << 1) | bit) & 0x1F`, `parity5(sr & 0x13)`),
[CODE rtl/lmac/tetra_sch_f_encoder.v:106-109] (`conv_full = {conv_sr, din}`,
`^(conv_full & 5'b10011)`), [CODE rtl/tx/tetra_sb1_encoder.v:180-184],
[CODE rtl/rx/tetra_ul_viterbi_r14.v:5-9], [CODE scripts/decode_dl.py:420-466].

**Die Falle.** Zwei V1-Module verwenden die **gespiegelte** Konvention — neuestes Bit an
Position 4, ältestes an Position 0:

```verilog
// rtl/lmac/tetra_rcpc_encoder.v:132,145-148  — Schieberichtung nach RECHTS
sr_sys <= {data_in_eff_w, sr_sys[3:1]};             // sr[3] = neuestes
wire g1_w = data_in_eff_w ^ sr_sys[1] ^ sr_sys[0];  // = 1 + D³ + D⁴
```

```verilog
// rtl/lmac/tetra_viterbi_decoder.v:9-18
// new_state = {input_bit, prev_state[3:1]};  state[3] = neuestes
```

Wirkung, nachgerechnet: Der so entstehende Generatorsatz ist
`{ 1+D³+D⁴ , G3 , G2 , G4 }` statt `{ G1, G2, G3, G4 }`. `1+D³+D⁴` ist **kein**
ETSI-Generator, und die Punktierung `P_2/3` behält genau die beiden Positionen 1 und 2 —
also `1+D³+D⁴` und `G3` statt `G1` und `G2`. Encoder und Decoder dieses Paares passen
zueinander (Loopback grün), gegenüber einem echten Endgerät ist die Ausgabe falsch.
Deshalb bekam der Uplink in V1 einen **zweiten**, ETSI-konformen Decoder
(`tetra_ul_viterbi_r14`) mit dem ausdrücklichen Header-Vermerk „Mirrors canonical
reference implementation […] which decodes real ETSI-encoded signals"
[CODE rtl/rx/tetra_ul_viterbi_r14.v:28-29].

**V2:** Regel C gilt überall. Ein Loopback-Test, der Encoder gegen Decoder derselben
Konvention prüft, ist **kein** Nachweis der Normkonformität (§5).

#### 3.2.3 Punktierung

**Normativ** [ETSI §8.2.3.1.2 Gl. 8.7]:
`b3(j) = V(k)` mit `k = 8·((i−1) div t) + P(i − t·((i−1) div t))`.

| Rate | t | P | benötigt für |
|---|---|---|---|
| **2/3** | 3 | `{1, 2, 5}` [ETSI §8.2.3.1.3 Gl. 8.8], `i = j` | **alle** Signalisierungskanäle |
| 1/3 | 6 | `{1,2,3,5,6,7}` [ETSI §8.2.3.1.4] | nicht benötigt (kein Kanal in Stufe 1) |
| 292/432 | 3 | `{1,2,5}`, `i = j + (j−1) div 65` [ETSI §8.2.3.1.5] | TCH/4,8 — Roadmap `18` |
| 148/432 | 6 | `{1,2,3,5,6,7}`, `i = j + (j−1) div 35` [ETSI §8.2.3.1.6] | TCH/2,4 — Roadmap `18` |

**Rate 2/3 konkret (0-basiert), verbindliche Formulierung:**

```
Mutter-Periode = 8 Bits = { g1(a), g2(a), g3(a), g4(a), g1(b), g2(b), g3(b), g4(b) }
                            ^0      ^1      ^2      ^3      ^4      ^5      ^6      ^7
behalten: Positionen { 0, 1, 4 }  →  3 type-3-Bits je 2 type-2-Bits
```

[CODE sw/tetra_channel_codec.c:70-83], [CODE rtl/lmac/tetra_sch_f_encoder.v:176-196].

**Depunktierung** (Empfang): Positionen 0, 1, 4 der Periode werden aus type-3 gefüllt,
Positionen 2, 3, 5, 6, 7 sind **Erasure**. Erasure ist im Soft-Pfad exakt `0` und trägt
**keinen** Beitrag zur Metrik [CODE sw/tetra_channel_codec.c:395-402]. Ein
„Mittelwert"-Erasure in einer unsigned-Codierung ist dazu äquivalent, solange die Metrik
`|soft − CENTER|` verwendet. V1-RTL: `VIT_CENTER = 2^(VIT_SOFT_WIDTH−1)`
[CODE rtl/rx/tetra_ul_sch_hu_decoder.v:177]; die im Live-Pfad wirksame Breite ist die
Modul-Vorbelegung `VIT_SOFT_WIDTH = 5` ⇒ `VIT_CENTER = 16`, `VIT_MAX = 31`
[CODE rtl/rx/tetra_ul_sch_hu_decoder.v:54, CODE rtl/rx/tetra_rx_chain.v:487-489 überschreibt
nur `SOFT_IN_WIDTH`]. Der Modulkommentar beschreibt die 4-bit-Variante (`center=8, max=15`)
und hält fest, dass die frühere 3-bit-Quantisierung auf echten WAV-Signalen verlustbehaftet
war [CODE rtl/rx/tetra_ul_sch_hu_decoder.v:170-175]. V2 nutzt die signed-Form mit
`Erasure = 0`; sie hat keinen Quantisierungs-Nullpunktfehler.

Mutterlänge: `mother_len = (K3 / 3) · 8`, Trellis-Stufen = `K1 + 16 + 4`.

| Kanal | type-2 (Stufen) | Mutter | type-3 |
|---|---|---|---|
| BSCH | 80 | 320 | 120 |
| SCH/HU | 112 | 448 | 168 |
| SCH/HD | 144 | 576 | 216 |
| SCH/F | 288 | 1 152 | 432 |

### 3.3 Blockinterleaver

**Normativ** [ETSI §8.2.4.1 Gl. 8.34]: ein (K, a)-Blockinterleaver bildet

```
b4(k) = b3(i)   mit   k = 1 + ((a · i) mod K),   i = 1 … K
```

**Umkehr (Empfang):** `b3(i) = b4(1 + ((a · i) mod K))` — dieselbe Formel, Rollen
getauscht [CODE sw/tetra_channel_codec.c:186-197], [CODE scripts/decode_dl.py:392-402].

**Parameter je Kanal** — direkt aus den Kanalabschnitten, **nicht** aus einer Tabelle:

| Kanal | K | a | Beleg |
|---|---|---|---|
| BSCH | 120 | 11 | [ETSI §8.3.1.2] |
| SCH/HU | 168 | 13 | [ETSI §8.3.1.4.3] |
| SCH/HD, BNCH, STCH | 216 | 101 | [ETSI §8.3.1.4.1] |
| SCH/F | 432 | 103 | [ETSI §8.3.1.4.5] |
| TCH/S Halbschlitz | 216 | 101 | [ETSI §8.3.1.3.7] |
| AACH | — | — | kein Interleaving [ETSI §8.3.1.1] |

**Keine dieser Permutationen ist selbstinvers** — der Richtungsparameter ist für **jeden**
Kanal zwingend, nicht Vorsichtsmaßnahme. Grund ist der `+1`-Versatz in Gl. 8.34: zweimal
angewandt ergibt sich `π(π(k)) = 1 + ((a + a²·k) mod K)`, also selbst dort keine Identität,
wo `a² ≡ 1 mod K` gilt (120/11 und 168/13). Nachgerechnet gegen die Formel aus
[CODE sw/tetra_channel_codec.c:88-95] bzw. [CODE sw/tetra_channel_codec.c:186-197]:
Fixpunkte von `π²` = 0 für alle vier Paare (120/11, 168/13, 216/101, 432/103), z. B.
`π(π(1)) = 13` für 120/11 und `= 15` für 168/13
[SIM 2026-07-25, eigene Nachrechnung, alle K Indizes je Paar]. Die V1-Behauptung
„self-inverse (11²≡1 mod 120)" [CODE rtl/lmac/tetra_interleaver.v:24] wendet die
Bedingung des reinen Modulo-Produkts auf eine Permutation mit Versatz an und ist damit
falsch; die Selbstinvers-Bedingung dieser Permutation wäre `a ≡ −1 mod K`.
V2 hat genau eine Funktion mit einem Richtungsparameter.

**Achtung Dokumentationsfalle.** V1 zitiert für dieselben Parameter drei Tabellennummern,
von denen keine den zitierten Inhalt trägt: „Table 8.19" [CODE rtl/lmac/tetra_interleaver.v:23,
CODE sw/tetra_hal.c:560], „Table 8.13" [CODE rtl/lmac/tetra_sch_f_encoder.v:26] und für
die RM-Matrix „Table 8.11" [CODE sw/tetra_hal.c:384]. Nachgeprüft am Normtext: „Table 8.19"
existiert in EN 300 392-2 v3.8.1 **nicht** — Clause 8 endet bei Table 8.14. „Table 8.11"
und „Table 8.13" existieren, enthalten aber **K1-Werte für QAM-Kanäle** (SCH-Q/D + BNCH-Q
bzw. SCH-Q/B) [ETSI Table 8.11, Table 8.13]; ebenso sind Tabellen 8.2–8.6 ausschließlich
QAM-Parameter (`K`/`a` zum QAM-Interleaver [ETSI §8.2.4.3]). Die RM-Generatormatrix ist
**Gleichung** (8.13) [ETSI §8.2.3.2], die Interleaver-Formel Gleichung (8.34)
[ETSI §8.2.4.1]. V2 zitiert Abschnitte und Gleichungsnummern, keine Tabellennummern aus
dem Gedächtnis.

**Interleaving über N Blöcke** [ETSI §8.2.4.2] wird von TCH/4,8 und TCH/2,4 benötigt und
ist in Stufe 1 **nicht** implementiert (`18_ROADMAP.md`).

### 3.4 Scrambling

#### 3.4.1 Verfahren

`b5(k) = b4(k) ⊕ p(k)`, `k = 1…K5` [ETSI §8.2.5.1 Gl. 8.38]. Selbstinvers — Descrambling
ist dieselbe Operation. Im Soft-Pfad wird aus dem XOR ein **Vorzeichenwechsel**:
`soft4(k) = p(k) ? −soft5(k) : soft5(k)` [CODE sw/tetra_channel_codec.c:381-390].

#### 3.4.2 Die Folge

**Normativ** [ETSI §8.2.5.2 Gl. 8.39–8.42]:

```
c(x) = 1 + X + X² + X⁴ + X⁵ + X⁷ + X⁸ + X¹⁰ + X¹¹ + X¹² + X¹⁶ + X²² + X²³ + X²⁶ + X³²

p(k) = Σ_{i=1..32}  c_i · p(k−i)          (mod 2)

Initialisierung:  p(k) = e(1−k)   für k = −29 … 0
                  p(k) = 1       für k = −31, −30
```

Rückkopplungs-Lags: `{1, 2, 4, 5, 7, 8, 10, 11, 12, 16, 22, 23, 26, 32}`.

**Verbindliche Realisierung — Fibonacci, Schieberichtung rechts:**

```
Registerbelegung:  lfsr Bit 31 = p(k−1),  Bit 30 = p(k−2),  …,  Bit 0 = p(k−32)
                   ⇒ Bit-Index = 32 − Lag

p(k) = lfsr[0]  ^ lfsr[6]  ^ lfsr[9]  ^ lfsr[10] ^ lfsr[16] ^ lfsr[20] ^ lfsr[21]
     ^ lfsr[22] ^ lfsr[24] ^ lfsr[25] ^ lfsr[27] ^ lfsr[28] ^ lfsr[30] ^ lfsr[31]

lfsr = (lfsr >> 1) | (p(k) << 31)
```

Ausgabe ist das **Rückkopplungsbit selbst**, nicht ein Registerbit
[CODE sw/tetra_channel_codec.c:103-116], [CODE rtl/lmac/tetra_sch_f_encoder.v:112-115,199-201].

> **Kein Galois.** Eine Galois-Realisierung mit derselben Polynommaske erzeugt aus
> demselben Startwort eine **andere** Folge. Genau das steht in V1 als
> `tetra_scrambler.v` mit `POLY_MASK = 32'h04C11DB7`
> [CODE rtl/lmac/tetra_scrambler.v:77] — und dessen Testvektoren wurden aus derselben
> Galois-Annahme erzeugt [CODE tb/vectors/gen_scrambler_vectors.py:38], sodass die
> Testbench die Abweichung nie sichtbar machen konnte. Der C-Code weiß es und schreibt es
> hin: „Must be Fibonacci form — Galois form produces a different sequence"
> [CODE sw/tetra_hal.c:262-265]. Das Modul ist in V1 nur vom nicht instanziierten
> `tetra_lmac` referenziert und existiert als Falle, nicht als Funktion.

#### 3.4.3 Startwert (normativ)

Der erweiterte Farbcode ist 30 bit: 24 bit Scrambling-Code (MCC + MNC) aus MLE plus
6 bit Farbcode aus dem Upper MAC [ETSI §23.2.1, Bild 23.5]. Mit der
Registerbelegung aus §3.4.2 (`Bit 31 = p(0) = e(1)`) folgt zwingend:

```
       Bit  31 … 22   21 …  8    7 …  2    1  0
seed =    MCC (10)    MNC (14)   CC (6)    1  1

uint32_t tetra_cc_scramble_seed(uint16_t mcc, uint16_t mnc, uint8_t cc)
{
    return ((uint32_t)(mcc & 0x03FF) << 22)
         | ((uint32_t)(mnc & 0x3FFF) <<  8)
         | ((uint32_t)(cc  & 0x003F) <<  2)
         | 3u;
}
```

`e(1)…e(10) = MCC` MSB-first, `e(11)…e(24) = MNC` MSB-first, `e(25)…e(30) = Farbcode`
MSB-first, danach die zwei Einsen aus `p(−31) = p(−30) = 1`.

**BSCH:** `e(1)…e(30) = 0` ⇒ `seed = 0x00000003` [ETSI §8.2.5.2, §23.2.1 NOTE 2],
[CODE rtl/tx/tetra_sb1_encoder.v:104]. Das Begleit-Halbblock im selben Burst
(BNCH auf BKN2) nutzt den **normalen** zell-spezifischen Startwert — die Zellidentität ist
zu diesem Zeitpunkt aus dem BSCH bereits bekannt [ETSI §8.2.5.2 NOTE analog für SCH-Q/B],
in V1 empirisch bestätigt [CODE sw/tetra_hal.c:535-537: „TMO path uses
ExtractLogicChannelFromBKN which unscrambles with cell-identity, NOT init=3"] und in §5.2
gegen die Gold-Aufzeichnung verifiziert.

**Verifikation gegen die Gold-Aufzeichnung** — Zelle MCC = 262, MNC = 1010, CC = 1:
Die Formel ergibt `0x4183F207`, exakt der von der Referenz-Basisstation abgeleitete Wert
[GOLD `docs/reference_decode/README.md:12`]. Die XOR-Differenz zwischen
`AACH bb (30 bit onair)` und `AACH bb (30 bit descrambled)` von Burst 0
[GOLD `dl_full.md:20-21`] ist bit-für-bit die ersten 30 Werte der Folge aus §3.4.2 mit
diesem Startwert [SIM 2026-07-25, eigene Nachrechnung, 30/30 Bits].

#### 3.4.4 Die zwei V1-Fehler an dieser Stelle

1. **Zeitschlitz im Startwert.** Die Altfunktion `scrambler_init()` schiebt den Farbcode
   zusammen mit MNC/MCC um zwei Stellen nach links und legt in die untersten zwei Bits den
   **Zeitschlitz** statt der zwei ETSI-Einsen
   [CODE sw/tetra_hal.c:293-301: `init = (init << 2) | (slot_num & 0x03)`]. Für
   `slot_num ≠ 3` ist die Folge falsch. Der Wrapper `tetra_scramble()` ruft sie zusätzlich
   mit `mcc = mnc = 0` auf [CODE sw/tetra_hal.c:304-313]. Die Kommentare der später
   korrigierten Aufrufer tragen die Altform weiter mit
   [CODE sw/tetra_hal.c:983, sw/tetra_channel_codec.h:48] und der aktuelle Code nimmt
   `slot_num` nur noch entgegen, um es zu verwerfen
   [CODE sw/tetra_channel_codec.c:162: `(void)slot_num;`].
   **V2: R-05-05 — kein Zeitschlitz, keine Slot-Nummer, kein `(void)`-Parameter.**

2. **Verschobener Farbcode am Registerausgang.** Der Farbcode wurde in das
   Konfigurationsregister geschrieben, indem der bereits gepackte Startwert auf 6 bit
   maskiert wurde. Aus `CC = 49` wurde `(49 << 2) & 0x3F = 4` auf der Luft
   [CODE sw/tetra_hal.c:1770-1772]. Fehlerbild: der Farbcode im SYNC-PDU passte nicht zum
   Scrambler, das Endgerät verwarf die Bursts.
   **V2: R-05-06 — jede Schnittstelle bekommt den rohen Farbcode 0…63; die Verschiebung
   passiert ausschließlich in `tetra_cc_scramble_seed()`.**

3. **Entarteter Startwert.** `seed = 0` erzeugt eine konstante Nullfolge. AACH und die
   UL-Decoder in V1 fangen das ab [CODE rtl/tx/tetra_aach_rm_encoder.v:108,
   CODE rtl/rx/tetra_ul_sch_f_decoder.v:212], der SCH/F-Encoder **nicht**
   [CODE rtl/lmac/tetra_sch_f_encoder.v:147]. **V2: R-05-15, einheitlich, mit Zähler.**

### 3.5 Verkürzter (30,14)-Reed-Muller-Code

#### 3.5.1 Normative Definition

`[b2(1) … b2(30)] = [b1(1) … b1(14)] × G` mit `G = [ I₁₄ | P ]`, `P` = 14 × 16
[ETSI §8.2.3.2 Gl. 8.12–8.13]:

```
P =  1 0 0 1 1 0 1 1 0 1 1 0 0 0 0 0      (Zeile 1, wirkt auf b1(1))
     0 0 1 0 1 1 0 1 1 1 1 0 0 0 0 0
     1 1 1 1 1 1 0 0 0 0 1 0 0 0 0 0
     1 1 1 0 0 0 0 0 0 0 1 1 1 1 0 0
     1 0 0 1 1 0 0 0 0 0 1 1 1 0 1 0
     0 1 0 1 0 1 0 0 0 0 1 1 0 1 1 0
     0 0 1 0 1 1 0 0 0 0 1 0 1 1 1 0
     1 1 1 1 1 1 1 1 1 1 0 1 1 1 1 1
     1 0 0 0 0 0 1 1 0 0 1 1 1 0 0 1
     0 1 0 0 0 0 1 0 1 0 1 1 0 1 0 1
     0 0 1 0 0 0 0 1 1 0 1 0 1 1 0 1
     0 0 0 1 0 0 1 0 0 1 1 1 0 0 1 1
     0 0 0 0 1 0 0 1 0 1 1 0 1 0 1 1
     0 0 0 0 0 1 0 0 1 1 1 0 0 1 1 1      (Zeile 14, wirkt auf b1(14))
```

**Implementierungsform (verbindlich).** Zeile `i` (0-basiert) als 30-bit-Wort mit
`Bit 29 = b2(1)`:

```
row[i] = (1 << (29 − i))  |  Σ_{j=0..15}  P[i][j] << (15 − j)
c      = XOR über alle row[i] mit b1(i+1) = 1
```

```
row[ 0] = 0x20009B60   row[ 4] = 0x0200983A   row[ 8] = 0x00208339   row[12] = 0x0002096B
row[ 1] = 0x10002DE0   row[ 5] = 0x01005436   row[ 9] = 0x001042B5   row[13] = 0x000104E7
row[ 2] = 0x0800FC20   row[ 6] = 0x00802C2E   row[10] = 0x000821AD
row[ 3] = 0x0400E03C   row[ 7] = 0x0040FFDF   row[11] = 0x00041273
```

Diese 14 Konstanten sind aus `P` neu berechnet und stimmen mit V1 überein
[CODE rtl/tx/tetra_aach_rm_encoder.v:51-64], [CODE sw/tetra_hal.c:387-414]
[SIM 2026-07-25, eigene Nachrechnung, 14/14 Werte].

Mindestdistanz `d_min = 8`, also bis zu **3** Bitfehler korrigierbar
[SIM 2026-07-25, vollständige Aufzählung aller 2¹⁴ Codewörter].

**Gold-Beweis.** RM-Codierung des AACH-Infoworts `0x3000` mit dieser Matrix ergibt
`110000000000001011011010000000` — bit-identisch mit dem Feld
`AACH bb (30 bit descrambled)` von Burst 0 der Referenzaufzeichnung
[GOLD `dl_full.md:21-22`] [SIM 2026-07-25, eigene Nachrechnung].

#### 3.5.2 Decodierung

Für die Basisstation ist AACH-**Decodierung** nur für Diagnose relevant (die BS empfängt
ihren eigenen Downlink nicht). V2 implementiert sie in Software als
Minimaldistanz-Suche über 2¹⁴ = 16 384 Kandidaten; auf dem ARM-Kern ist das nicht
zeitkritisch. Ergebnis „unkorrigierbar", wenn die kleinste Distanz > 3 ist
[Analogie CODE rtl/lmac/tetra_reed_muller.v:95-96]. Für 14 Informationsbits wäre eine
Syndrom-Tabelle möglich; die Aufzählung ist einfacher und in Software gleich schnell
genug.

#### 3.5.3 Der Zwei-Matrizen-Befund (echter Bug-Kandidat)

V1 enthält für denselben Code **zwei unterschiedliche Generatormatrizen**:

| Ort | Matrix | Herkunft |
|---|---|---|
| `tetra_aach_encoder` / `tetra_aach_rm_encoder` / `sw/tetra_hal.c` | `row[i]` wie §3.5.1 | ETSI Gl. 8.13 |
| `tetra_reed_muller` (generisches Modul) | `G_ROW00 = 0x33333333`, `G_ROW01 = 0x3C3C3C3C`, … `G_ROW13 = 0x3FC00000` [CODE rtl/lmac/tetra_reed_muller.v:80-93] | eigene Herleitung als verkürzter RM(2,5) |

**Befund, nachgerechnet [SIM 2026-07-25, vollständige Aufzählung beider Codes]:**

- Beide Matrizen haben Rang 14 und `d_min = 8`. Eine reine Distanz-/Rangprüfung
  unterscheidet sie **nicht**.
- Die erzeugten Codes sind trotzdem **verschieden**: **keine** der 14 Zeilen der
  generischen Matrix liegt im ETSI-Code, und die Schnittmenge der beiden Codes
  besteht aus **genau einem** Codewort — dem Nullwort (1 von 16 384).
- Beispiel: Infowort `0x3000` (AACH-Kapazitätszuweisung) ergibt ETSI-konform
  `0x3000B680`, mit der generischen Matrix `0x0F0F0F0F` (MSB-first) bzw. `0x03FC0000`
  (LSB-first).
- Die generische Matrix ist außerdem **nicht systematisch**: die oberen 14 Bits sind kein
  Identitätsblock, das Infowort ist im Codewort nicht ablesbar.

**Welche ist korrekt:** die ETSI-Matrix aus §3.5.1 — belegt durch [ETSI §8.2.3.2 Gl. 8.13]
**und** durch den bit-identischen Gold-Vergleich in §3.5.1.

**Warum V1 den Fehler nie bemerkt hat:** `tetra_reed_muller` wird ausschließlich von
`tetra_lmac` instanziiert, und `tetra_lmac` ist im Top-Level **nicht** instanziiert (nur in
Kommentaren erwähnt) — das Modul liegt in keinem Datenpfad und kostet auch keine Fläche
mehr; die Zahlen 94 LUT / 59 FF stammen aus einem Build vor der Entfernung der
`u_lmac`-Instanz [BUILD 2026-06-20 `cur_hier_deep.rpt:146-147`, siehe §2.1].
Zusätzlich prüft sein
Testvektor-Generator die Matrix nur gegen die eigene Herleitung und verschiebt den
ETSI-Vergleich auf einen Kommentar: „Replace G_ROWS with ETSI values if different"
[CODE tb/vectors/gen_reed_muller_vectors.py:21,113-122]. Der Modulkopf zitiert außerdem den
falschen Abschnitt (`§8.2.4.1` = Interleaving statt `§8.2.3.2`)
[CODE rtl/lmac/tetra_reed_muller.v:6].

**V2 (R-05-04):** Es gibt eine RM-Implementierung, sie trägt die Matrix aus §3.5.1, und
ihr Abnahmekriterium ist der Vektor `info = 0x3000 → 0x3000B680` plus der Gold-Burst aus
§3.5.1 — nicht Rang und Distanz.

### 3.6 Viterbi-Decodierung

#### 3.6.1 Trellis

16 Zustände, `K = 5`, Rate 1/4 vor Depunktierung. Zustand und Übergang nach Regel C
(§3.2.2): `zustand_neu = ((zustand_alt << 1) | b) & 0xF`, `sr = (zustand_alt << 1) | b`
(5 bit), Zweigausgang `e_i = parity(sr & G_i)`.

Die beiden Vorgänger eines Zustands `s` sind `s >> 1` und `(s >> 1) | 8`; das erzeugende
Eingangsbit ist in beiden Fällen `s & 1`. Die beiden Vorgänger unterscheiden sich genau im
Bit `zustand_alt[3]`, das beim Schieben aus dem 4-bit-Zustand herausfällt und im 5-bit-Fenster
auf `sr`-Bit 4 (den `D⁴`-Term) abgebildet wird. **Alle vier Generatoren enthalten den
`D⁴`-Term** (`0x13`, `0x1D`, `0x17`, `0x1B` haben Bit 4 gesetzt), daher unterscheiden sich
die Zweigausgänge der beiden Vorgänger in **allen vier** Ausgängen: `e_i(P1) = ¬e_i(P0)`,
die Zweigmetrik der Eins-Kante ist das Komplement der Null-Kante — eine Butterfly-Struktur
[CODE rtl/rx/tetra_ul_viterbi_r14.v:13-23,120-145: „old[3] bit is lost on shift",
`G1_P0 = s[0]^s[1]`, `G?_P1 = ~G?_P0`]. Nicht der Tap an Position 0 begründet das — `sr`-Bit 0
ist nach Regel C (§3.2.2) das **Eingangsbit** `b = s & 1` und für beide Vorgänger identisch.

#### 3.6.2 Terminierung und Rückverfolgung (normativ)

Der Encoder endet nach den 4 Nullbits **immer** im Zustand 0. Die Rückverfolgung startet
deshalb **unbedingt** im Zustand 0 (R-05-11). Der Kommentar in V1 hält den Grund fest:

> „Using argmin(pm) is only correct on a converged (noise-free) trellis — real-world noise
> flips the argmin to a non-zero state and the traceback then walks a wrong survivor path.
> Always start at state 0." [CODE rtl/rx/tetra_ul_viterbi_r14.v:364-367]

Der DL-Viterbi in V1 startet dagegen bei `argmin(pm)`
[CODE rtl/lmac/tetra_viterbi_decoder.v:24]. In V2 gibt es diesen zweiten Decoder nicht.

Ausgabe: `n_stages` Bits, davon die letzten 4 (Tailbits) verworfen. Die verbleibenden
`K1 + 16` Bits gehen in die Prüffeldkontrolle.

Die minimale Endpfadmetrik wird als Kanalgüte-Indikator exportiert (P6) und ist
**kein** Abbruchkriterium.

#### 3.6.3 Metrik

```
für jede Stufe i, für jeden Ausgang m ∈ {0,1,2,3}:
    s = soft[4i + m]                       (K1-Konvention, R-05-08)
    wenn s == 0:            Beitrag 0      (Erasure — punktierte Position)
    sonst:  hb = (s > 0) ? 0 : 1           (Hard-Entscheidung nach K1)
            Beitrag = (e_m == hb) ? 0 : |s|
```

Also: Straf-Metrik, minimiert. Erasures kosten nichts, sichere Bits kosten viel, unsichere
wenig. Das ist algebraisch dieselbe Entscheidung wie die Korrelationsmetrik
`−Σ s·e_signiert`, nur mit nichtnegativen Werten und damit ohne Vorzeichenfallen
[CODE sw/tetra_channel_codec.c:403-425].

**Achtung, V1-Drift:** Die V1-SW-Kette verwendet die **umgekehrte** Vorzeichenkonvention
(„positiv = bit '1'") [CODE sw/tetra_channel_codec.c:377-380,
CODE sw/tetra_channel_codec.h:108-109]. Nachgeprüft: Speist man `tetra_codec_schf_decode_soft`
mit der Konvention K1 aus `03` (positiv = '0'), liefert sie `rc = −1` und falsche
Informationsbits; mit „positiv = '1'" liefert sie `rc = 0` und korrekte Bits
[SIM 2026-07-25, `test`-Programm gegen `sw/tetra_channel_codec.c`, sauberer Kanal].
V1 hat damit **innerhalb der Software** zwei gegenläufige Konventionen — die PHY und der
Python-Referenzdecoder folgen K1 [CODE scripts/decode_dl.py:492-503], die
Signalisierungs-Soft-Decoder nicht.
**V2: R-05-08 gilt für alle Kanäle; die einzige Inversion liegt an der Stelle aus
`03` K3 und ist dort kommentiert.**

#### 3.6.4 Metrikbreite (R-05-10) — gemessene Überlaufgrenze

Die Pfadmetrik wächst im Worst-Case um `n_out · |soft|_max` je Stufe. Für den Sprachkanal
(184 Stufen, 3 Ausgänge) sind das bis zu `184 · 3 · 127 = 70 104` — mehr als `INT16_MAX`.

V1 verwendet `int16_t` [CODE sw/tetra_bs_tch_s.c:229] und initialisiert die
Nicht-Null-Zustände mit `INT16_MAX/2` [CODE sw/tetra_bs_tch_s.c:273]. Auf einem
**rauschfreien** Kanal gemessen:

| `\|soft\|` | Prüffeld | ACELP-Bits |
|---:|---|---|
| 1 … 63 | ok | korrekt |
| 100 … 107 | **verletzt** | korrekt |
| ≥ 108 | **verletzt** | **korrupt** |

[SIM 2026-07-25, 20 Zufallsrahmen je Magnitude, `sw/tetra_bs_tch_s.c` + `sw/tetra_tch_s_codec.c`,
Host-gcc `-O2`]

In V1 fällt das nicht auf, weil der Sprachpfad 4-bit-Softs liefert (`|soft| ≤ 7`). Ein
V2-Entwickler, der die durchgehende 8-bit-Soft-Breite aus `03` §3.6 verwendet, läuft ohne
R-05-10 direkt hinein. **V2: `int32_t` Pfadmetrik, `INF = 1 << 28`** — die
Signalisierungs-Kette macht das bereits richtig und begründet es
[CODE sw/tetra_channel_codec.c:406: `const int INF=1<<28;` „> max metric (~448×|s|); passt
in 32-bit int (auch arm)"].

#### 3.6.5 Rückverfolgungstiefe

Die Blöcke sind kurz (80…288 Stufen) und terminiert. V2 verfolgt über den **gesamten
Block** zurück, nicht über ein Fenster; damit entfällt der Parameter
`TRACEBACK` (V1: 32 [CODE rtl/rx/tetra_ul_viterbi_r14.v:41]) und die Frage, ob er
groß genug ist. Speicherbedarf: `n_stages × 16` Byte Überlebender-Tabelle, maximal
288 × 16 = 4 608 Byte — auf dem ARM-Kern unkritisch.

### 3.7 Soft-Entscheidungen

Übernommen aus `03` §3.2.2 und §3.5.4, hier nur die für die Decodierung relevanten
Festlegungen:

| Eigenschaft | Festlegung | Beleg |
|---|---|---|
| Datentyp | `int8_t` (`SOFT_WIDTH = 8`) | `03` §3.5.1 |
| Wertebereich | −127 … +127, **symmetrisch** gesättigt | `03` §3.5.4 (V2-Änderung: V1 sättigt asymmetrisch auf −128) |
| Vorzeichen | `> 0` ⇒ Bit `'0'`; `< 0` ⇒ Bit `'1'` | `03` K1, [CODE scripts/decode_dl.py:492-503] |
| Erasure | genau `0` | §3.2.3 |
| Gewichtung | `\|soft\|` als Straf-Metrik | §3.6.3 |
| Arbeitspunkt | `soft ≈ 32 · {cos, sin}(Δφ)` nach Amplitudennormierung | `03` §3.5.3 |

Warum symmetrische Sättigung zwingend ist: das Descrambling ist ein Vorzeichenwechsel
(§3.4.1). Mit `SOFT_MIN = −128` hat `−(−128)` in `int8_t` keinen Wert und läuft über.
V1 fängt das im Sprachpfad per Sonderfall ab
[CODE sw/tetra_tch_s_codec.c:87-89],
im Signalisierungspfad nicht. Symmetrische Sättigung löscht die Fallklasse statt sie zu
behandeln.

**Warum Soft überhaupt Pflicht ist — zwei unabhängige Belege:**

- Auf der Gold-UL-Aufzeichnung sind 27 von 192 SCH/HU-Bursts prüffeld-korrekt
  [GOLD `docs/reference_decode/ul_full.md:3`]. Decodiert man die **aufgezeichneten harten**
  type-5-Bits derselben Bursts, reproduzieren nur **20 von 27** das protokollierte
  Ergebnis; die restlichen 7 (26 %) sind ausschließlich über den Soft-Pfad gewinnbar
  [SIM 2026-07-25, eigene Nachrechnung über `ul_events.jsonl`].
- Auf synthetischem Rauschen: **41,2 % korrekt-mit-Prüffeld soft gegen 3,5 % hart**
  (+37,7 Prozentpunkte) [SIM 2026-07-06, `make test_ul_soft`, `sw/test_soft_gain.c` —
  Host-gcc `-O2`, kanalseitig programminternes Box-Muller-Gaußrauschen (`AMP = 8.0`,
  `SIGMA = 6.0`, 4 000 Bursts), **keine** Hardware-Messung].

### 3.8 Ketten je logischem Kanal

Übersicht — alle Zahlen [ETSI §8.3.1.x], gegengeprüft gegen die Gold-Parametertabelle
[GOLD `docs/reference_decode/README.md:22-27`]:

| Kanal | Richtung | type-1 | Blockcode | type-2 | RCPC | type-3 | Interleave | type-4 | Scrambler | type-5 | Träger |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **SCH/F** | DL + UL | 268 | (284,268) +4 | 288 | 2/3 | 432 | (432,103) | 432 | Zelle | 432 | BKN1+BKN2 |
| **SCH/HD** | DL | 124 | (140,124) +4 | 144 | 2/3 | 216 | (216,101) | 216 | Zelle | 216 | BKN1 **oder** BKN2 |
| **BNCH** | DL | 124 | wie SCH/HD | 144 | 2/3 | 216 | (216,101) | 216 | Zelle | 216 | BKN2 des SB |
| **STCH** | DL/UL | 124 | wie SCH/HD | 144 | 2/3 | 216 | (216,101) | 216 | Zelle | 216 | gestohlener Block (`18`) |
| **SCH/HU** | UL | 92 | (108,92) +4 | 112 | 2/3 | 168 | (168,13) | 168 | Zelle | 168 | Control-Block |
| **BSCH** | DL | 60 | (76,60) +4 | 80 | 2/3 | 120 | (120,11) | 120 | **0x3** | 120 | SB-Block |
| **AACH** | DL | 14 | RM(30,14) | 30 | — | — | — | 30 | Zelle | 30 | BBK |
| **TCH/S** | DL + UL | 274 ACELP | §3.8.6 | — | 1/3 | 432 | 24×18 | 432 | Zelle | 432 | BKN1+BKN2 |

Die Gold-Tabelle stimmt in allen vier dort genannten Bursttypen mit ETSI überein
(SB → 120/11/60, NDB1 → SCH/F 432/103/268, NDB2 → SCH/HD 216/101/124,
NUB → SCH/HU 168/13/92).

Aufteilung von type-5 auf Blöcke:
`bkn1(k) = b5(k)`, `bkn2(k) = b5(k+216)` für SCH/F und TCH/S [ETSI §8.3.1.4.5 Gl. 8.67-8.68,
§8.3.1.3.6 Gl. 8.58-8.59]; SCH/HD belegt genau einen der beiden Blöcke
[ETSI §8.3.1.4.1 Gl. 8.61-8.62]; SCH/HU belegt den Control-Block `cb(k) = b5(k)`
[ETSI §8.3.1.4.3 Gl. 8.65]; BSCH belegt den Synchronisationsblock `sb(k) = b5(k)`
[ETSI §8.3.1.2 Gl. 8.45]; AACH belegt den Broadcast-Block `bb(k) = b5(k)`
[ETSI §8.3.1.1 Gl. 8.44]. Die physikalische Bitverteilung im Burst steht in `04` §3.4.

#### 3.8.1 SCH/F — Vollschlitz-Signalisierung

Der Hauptkanal: MAC-RESOURCE-Signalisierung, ACCESS-DEFINE, SYSINFO, Fragmentketten
langer Kurznachrichten — DL wie UL.

```
Senden:     268 type-1 → CRC-16 (284) → +4 Null (288)
            → RCPC r=1/4 (1152) → P_2/3 (432)
            → Interleave (432, 103) → Scramble (Zelle) → 432 type-5
Empfangen:  432 Soft → Descramble → Deinterleave (432, 103)
            → Depunktierung (1152, Erasure=0) → Viterbi (288 Stufen)
            → 4 Tailbits verwerfen → CRC-Prüfung über 284 → 268 type-1
```

Gold-Beleg: Burst 423 (NDB1, **TS1, FN4, MN44**) der Referenzaufzeichnung wird von dieser
Kette bit-identisch auf die protokollierten 268 Informationsbits abgebildet, Prüffeld ok,
Tailbits `0000` [GOLD `dl_events.jsonl` idx 423] [SIM 2026-07-25, eigene Nachrechnung].

> **Achtung Umrechnungsfalle** (`CONVENTIONS.md` §4): die Felder `tn`, `fn`, `mn` in
> `dl_events.jsonl` und `ul_events.jsonl` sind **schon ETSI-1-basiert** (`tn` 1…4, `fn` 1…18,
> `mn` 1…60); das 0-basierte Pendant heißt `tn_air` (0…3) — `tn = 1` (ETSI TS1) entspricht
> `tn_air = 0` (RTL) [GOLD `dl_events.jsonl`, Wertebereiche über alle 7 338 Datensätze].
> Ein zusätzliches `+1` auf `tn`/`fn`/`mn` ist falsch.

#### 3.8.2 SCH/HD, BNCH, STCH — Halbschlitz-Signalisierung DL

Identische Kette mit `K1 = 124`, `(216, 101)`. **Einer** Codierer für alle drei Kanäle;
sie unterscheiden sich nur im Träger und in der PDU-Semantik (`06`).

Gold-Beleg: Burst 3 (NDB2) wird bit-identisch auf die protokollierten 124
Informationsbits abgebildet, Prüffeld ok [GOLD `dl_events.jsonl` idx 3]
[SIM 2026-07-25, eigene Nachrechnung].

Der BNCH im BKN2 des Synchronisations-Bursts nutzt den **zell-spezifischen** Startwert
(§3.4.3), nicht `0x3`.

**Stealing** (STCH) ersetzt fertige type-5-Blöcke **nach** Codierung, Interleaving und
Scrambling [ETSI §8.3.1.3.1]. Für die Codierkette bedeutet das: keine Sonderbehandlung,
nur eine andere Zielposition. Nicht in Stufe 1 (`18_ROADMAP.md`).

#### 3.8.3 SCH/HU — Halbschlitz-Signalisierung UL

`K1 = 92`, `(168, 13)`. Trägt MAC-ACCESS: Zufallszugriff, Anmeldeanforderung, kurze
Kurznachrichten, Reservierungsanforderung.

Auch hier ist die Permutation **nicht** selbstinvers (§3.3): trotz `13² ≡ 1 mod 168` gilt
wegen des `+1`-Versatzes `π(π(1)) = 15 ≠ 1`, Interleaver und Deinterleaver sind also
**verschiedene** Abbildungen [SIM 2026-07-25, eigene Nachrechnung]. Die gemeinsame Funktion
wird deshalb — wie bei jedem Kanal — mit Richtungsparameter aufgerufen (R-05-01); ein
Decoder, der hier dieselbe Richtung wie der Encoder verwendet, liefert Müll.

Gold-Beleg: UL-Bursts 0 und 1 der Referenzaufzeichnung werden bit-identisch auf die
protokollierten 92 Informationsbits abgebildet, Prüffeld ok, Tailbits `0000`; der
Zwischenzustand type-4 stimmt ebenfalls bit-identisch
[GOLD `docs/reference_decode/ul_events.jsonl` idx 0, 1] [SIM 2026-07-25, eigene
Nachrechnung].

Die Soft-Kette ist in V1 bereits vollständig in C vorhanden und gegen die RTL-Vektoren
abgeglichen: **4/4 Vektoren identisch** [SIM 2026-07-06, `make test_ul_parity` — Host-gcc
gegen die per `scripts/gen_sch_hu_tv.py` erzeugten Vektoren der RTL-Testbench], Roundtrip
**500/500** [SIM 2026-07-06, `make test_schhu_rt` — reiner C-Roundtrip auf dem Host], und
auf einem echten UL-WAV-Mitschnitt **6/6 reale Bursts** übereinstimmend mit der Referenz
[SIM 2026-07-10, `make test_ul_realair` — Host-Decodierung eines Luft-Mitschnitts, keine
Board-Messung]. V2 übernimmt diese Kette als normative Implementierung.

#### 3.8.4 BSCH — Broadcast-Synchronisation (RTL-Ausnahme)

`K1 = 60`, `(120, 11)`, Startwert **`0x00000003`** fest. Weil der Startwert konstant ist,
ist die 120-bit-Scrambler-Maske eine **Übersetzungszeit-Konstante**; das RTL berechnet sie
in einer Verilog-`function` und synthetisiert sie zu Verdrahtung
[CODE rtl/tx/tetra_sb1_encoder.v:85-104]. Ebenso die Interleaver-Permutation
[CODE rtl/tx/tetra_sb1_encoder.v:114-126].

**Modul `tetra_bsch_encoder` (V2-Name), Ports:**

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `clk_sys`, `rst_n_sys` | 1 | in | `_sys` | 100 MHz, Reset active-low |
| `cfg_*` (Systemcode, Farbcode, Sharing-Mode, reservierte Frames, U-Plane-DTX, Frame-18-Erweiterung, MCC, MNC, Nachbarzell-Broadcast, `cell_load_ca`, Late-Entry) | 4/6/2/3/1/1/10/14/2/2/1 | in | `_sys` | statische Zellparameter aus `07` (`REG_CELL_CFG_0..2`) |
| `encode_start_sys` | 1 | in | `_sys` | 1-Zyklus-Puls |
| `sdb_slot_sys` | 2 | in | `_sys` | `tn` des **Folge**slots (0-basiert) |
| `frame_num_sys` | 5 | in | `_sys` | `fn` des Folgeslots, **1-basiert** 1…18 |
| `multiframe_num_sys` | 6 | in | `_sys` | `mn` des Folgeslots, **1-basiert** 1…60 |
| `sb1_coded_sys` | 120 | out | `_sys` | type-5, `[119]` = `sb(1)` = erstes Bit auf der Luft |
| `sb1_valid_sys` | 1 | out | `_sys` | high nach der ersten gültigen Codierung |

Der 60-bit-Feldaufbau des SYNC-PDU gehört nach `06`; hier zählt nur, dass FN/MN
**1-basiert** auf die Luft gehen [CODE rtl/tx/tetra_sb1_encoder.v:65-66]. Ein V1-Fehler war
die 0-basierte Übergabe (`fn−1`, `mn−1`); Fehlerbild „Trägernummer flackert" auf dem
Endgerät, weil die Empfänger-BSCH-Slotformel `4 − ((MN+1) mod 4)` mit falschem MN rechnete
und das SYSINFO im falschen Slot suchte [MESS 2026-04-19, Air-Beobachtung an MTP-3550,
belegt über die Fix-Historie `d7423a3`]. Root-Cause und Regel gehören nach
`17_LESSONS_LEARNED.md`.

**Laufzeit:** 1 (IDLE) + 60 (CRC) + 1 (BUILD) + 80 (RCPC) + 1 (FINISH) = **143 Zyklen**
= 1,43 µs bei 100 MHz — 0,01 % eines Zeitschlitzes. Vorausschau-Pflicht nach `04` §3.2.4.

**Ressourcen:** V1-Referenz 609 LUT / 657 FF [BUILD 2026-05-18 `impl_hier_util.rpt:88`].
Erwartung für V2 gleiche Größenordnung.

#### 3.8.5 AACH — Zugriffszuweisung (RTL-Ausnahme)

`14 type-1 → RM(30,14) → 30 type-2 = type-4 → Scramble (Zelle) → 30 type-5`. Kein
Faltungscode, kein Interleaving [ETSI §8.3.1.1].

V2 hat **einen** RTL-Block, rein kombinatorisch, ohne FSM — RM-Matrix als XOR-Netz,
Scrambler-Maske als 30 lineare Funktionen der 32 Startwortbits (die LFSR-Iteration ist
linear, also in einer Verilog-`function` ausrollbar)
[CODE rtl/tx/tetra_aach_rm_encoder.v:98-123].

**Modul `tetra_aach_encoder` (V2), Ports:**

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `info_w` | 14 | in | — | AACH-Infowort, `[13]` = `b1(1)`. Semantik → `06` |
| `seed_w` | 32 | in | — | Scrambler-Startwert nach §3.4.3 |
| `coded_w` | 30 | out | — | type-5, `[29]` = `bb(1)` = erstes Bit auf der Luft |

Kein Takt, kein Reset, kein Zustand. Wer das Infowort auswählt (Slot-Rolle, Zuweisung,
Reservierung), gehört nach `06`; wer es registriert, nach `04`.

**Warum kombinatorisch statt FSM:** V1 hatte beides — eine 32-Zyklen-FSM
[CODE rtl/tx/tetra_aach_encoder.v:284-307] **und** den kombinatorischen Block, weil die
FSM-Variante ein Einzyklus-Wettrennen zwischen Scheduler-Latch und Encoder-Ende erzeugte
[CODE rtl/tx/tetra_aach_rm_encoder.v:14-16]. Die kombinatorische Form hat das Problem
nicht und kostet weniger: die FSM-Variante belegt 123 LUT / 116 FF
[BUILD 2026-05-18 `impl_hier_util.rpt:70`], der kombinatorische Block wird vollständig in
die Umgebung gefaltet und erscheint im Hierarchiebericht nicht als eigene Zeile.

**Startwert-Entartung:** `seed_w == 0` → intern `0xFFFFFFFF` (R-05-15). Bei realen Zellen
unmöglich, weil die untersten zwei Bits konstant `11` sind.

#### 3.8.6 TCH/S — Sprachkanal (Kanalcodierung)

Die Kanalcodierung des Sprachkanals ist in EN 300 395-2 definiert; EN 300 392-2 übernimmt
ab type-4 nur noch das Scrambling: „EN 300 395-2 defines in clause 5.5.3 432 type-4 bits
C4(1)…C4(432). For the purpose of scrambling those bits are mapped into b4(k) = C4(k)"
[ETSI §8.3.1.3.6]. Der Quellcodec selbst gehört nach `12`.

**Kette (Senderichtung), 2 ACELP-Rahmen à 137 bit = 274 bit je 60-ms-Burst:**

```
274 ACELP-Bits (Codec-Ordnung)
  │  Klassen-Umsortierung (Empfindlichkeitsklassen, je Klasse beide Rahmen)
  ▼
Klasse 0: 102 bit  │ Klasse 1: 112 bit │ Klasse 2: 60 bit
  │ ungeschützt    │                   │  + CRC-8 (§u.) + 4 Tail = 72 bit
  │                ▼                   ▼
  │        Faltungscode Rate 1/3, K=5, DURCHLAUFEND über Klasse 1 → Klasse 2
  │        112·3 = 336 Mutter          72·3 = 216 Mutter
  │                │ Punktierung 112/168 │ Punktierung 72/162
  │                ▼                     ▼
  │              168 bit                162 bit
  └────────────────┴─────────────────────┘
                   ▼
      type-3 = 102 + 168 + 162 = 432 bit
                   ▼  Blockinterleaver 24 Zeilen × 18 Spalten
      type-4 = 432 bit
                   ▼  Scramble (Zellstartwert, §3.4.3)
      type-5 = 432 bit  →  bkn1 = b5(1..216), bkn2 = b5(217..432)
```

**Parameter:**

| Größe | Wert | Beleg |
|---|---|---|
| ACELP-Bits je Rahmen | 137 | [CODE sw/tetra_bs_tch_s.c:28] |
| Klassengrößen je Rahmen | 51 / 56 / 30 | [CODE sw/tetra_tch_s_codec.h:45-47] |
| Klassengrößen je Burst | 102 / 112 / 60 | [CODE sw/tetra_tch_s_codec.h:48-50] |
| Klassen-Indextabellen | `CLASS0_POS[51]`, `CLASS1_POS[56]`, `CLASS2_POS[30]` (1-basierte ACELP-Ränge) | [CODE sw/tetra_bs_tch_s.c:30-45] |
| Sprach-Faltungscode | `G1 = 1+D+D²+D³+D⁴`, `G2 = 1+D+D³+D⁴`, `G3 = 1+D²+D⁴` | [CODE sw/tetra_bs_tch_s.c:117-137] |
| Punktierung Klasse 1 | `t = 3`, Periode 6, `P = {1,2,4}` → 336 → 168 | [CODE sw/tetra_bs_tch_s.c:164,167-169] |
| Punktierung Klasse 2 | `t = 9`, Periode 12, `P = {1,2,3,4,5,7,8,10,11}` → 216 → 162 | [CODE sw/tetra_bs_tch_s.c:165,170-172] |
| Interleaver | 24 × 18, `out[col·24 + line] = in[line·18 + col]` | [CODE sw/tetra_tch_s_codec.c:35-43], [CODE sw/tetra_tch_s_codec.h:57-58] |
| Sprach-Prüffeld | `G(X) = X⁷ + X³ + 1` über die 60 Klasse-2-Bits, 7 Prüfbits + 1 Gesamtparitätsbit = 8 | [CODE sw/tetra_bs_tch_s.c:88-114] |

Die ETSI-Referenzen dieser Kette (EN 300 395-2 §5.4.3.1, §5.5.1, §5.5.3, §5.6.3) sind aus
den Codekommentaren übernommen; der Normtext lag beim Schreiben dieses Kapitels **nicht**
als Text vor. Sie sind damit `[CODE]`-belegt, nicht `[ETSI]`-verifiziert — siehe §6
O-05-3.

**Die Falle, die V1 gemessen hat:** Der Faltungscodierer läuft **durchlaufend** über
Klasse 1 und Klasse 2 (ein 184-bit-Eingangsstrom → 552 Mutterbits → **eine**
Viterbi-Decodierung). Eine Aufteilung in zwei getrennte Ströme erzeugt eine andere
Bitfolge, und „MS can't decode our re-encoded bursts"
[CODE sw/tetra_bs_tch_s.c:9-12]. **V2: ein Codierer-Zustand über beide Klassen,
`n_stages = 184`.**

**Empfangsrichtung:** Descramble → Deinterleave 24×18 → Klasse 0 hart über `sign(soft)` →
Klasse 1 und 2 depunktieren in **einen** Soft-Puffer → ein Viterbi über 184 Stufen →
Prüffeld über Klasse 2 → Klassen-Rückordnung → 274 ACELP-Bits. Das Prüffeld-Ergebnis ist
das **Bad-Frame-Indicator**-Signal für `12`.

**Zwei Implementierungen in V1, eine davon tot.** Live ist `sw/tetra_bs_tch_s.c`
(Portierung aus einer Rust-Referenz-Basisstation). Ebenfalls gelinkt, aber von keinem
Aufrufer verwendet, sind `sw/tetra_etsi_tch_s.c` plus der Baum `sw/etsi_codec/`
[verifiziert: keine Referenz auf `tetra_etsi_tch_s_*` außerhalb der Datei selbst].
Zusätzlich sind `tetra_tch_s_encode()` / `tetra_tch_s_decode()` in
`sw/tetra_tch_s_codec.c` Stümpfe, die `-1` zurückgeben
[CODE sw/tetra_tch_s_codec.c:192-210], während die Nachbarfunktionen desselben Moduls
(Interleaver, Scrambler) live sind. **V2: eine Implementierung, keine Stümpfe.**

### 3.9 Fehler- und Randfallverhalten

| Fall | Verhalten |
|---|---|
| Prüffeld verletzt | PDU verworfen, `crc_fail++`, Informationsbits als „ungeprüft" bereitgestellt (R-05-13). Kein Protokollzustand ändert sich. |
| Startwert `0` | ersetzt durch `0xFFFFFFFF`, `seed_degenerate++` (R-05-15) |
| Soft-Vektor unvollständig (Mailbox-Teilerfassung) | Decodierversuch **unterbleibt**, `short_burst++`. V1-Fehlerbild: die Soft-Burst-Mailbox überschrieb CB1 mit CB2, weil der `soft_first`-Anker den Schreibindex zurücksetzte, und lieferte nur **einen** Control-Block statt beider [CODE-Historie `91cc5a2`: „Fixt Halb-Erfassung (soft_first-Reset liess CB2 CB1 ueberschreiben)"]. Dass daraus 168/2 = 84 Soft-Werte und eine vollständige Prüffeld-Verletzung folgen, ist aus dem Mechanismus abgeleitet [ANNAHME — im Repo ist keine Zählung dieses Fehlerbildes protokolliert] |
| Alle Soft-Werte 0 (Signalverlust) | Metrik degeneriert, Ausgabe zufällig; Prüffeld fängt es ab. Zusätzlich `erasure_count == n` als Diagnosemerkmal |
| Unbekannter Kanal-Enum | `tetra_cc_encode/decode` liefert `< −1`, kein Puffer wird beschrieben |
| Falsche Bitanzahl im Aufruf | Der Kanal-Enum bestimmt alle Längen; es gibt **keinen** Längenparameter, also keinen Weg, sie inkonsistent zu setzen |
| Pfadmetrik-Sättigung | darf nicht auftreten (R-05-10). Tritt sie auf, ist es ein Implementierungsfehler, kein Betriebszustand — Assertion im Debug-Build |

### 3.10 Rechenlast auf dem ARM-Kern

Die Codierung wandert vollständig in Software; die Frage „passt das?" muss beantwortet
sein, bevor gebaut wird.

**Host-Messung** (x86-64, 3,7 GHz, gcc `-O2`, 2 000 Wiederholungen je Fall, Code aus
`sw/tetra_channel_codec.c` und `sw/tetra_bs_tch_s.c`) [SIM 2026-07-25]:

| Operation | µs / Burst (Host) |
|---|---|
| SCH/F codieren (268 → 432) | 3,4 |
| SCH/F decodieren, hart | 56,3 |
| SCH/F decodieren, soft | 59,0 |
| SCH/HU decodieren, soft | 22,4 |
| TCH/S codieren | 2,4 |
| TCH/S decodieren, soft | 6,9 |

Die Decodierzeit dominiert und skaliert mit `n_stages · 16 · 2 · n_out` — SCH/F hat
288 Stufen, SCH/HU 112, TCH/S 184 Stufen bei nur 3 Ausgängen.

**Umrechnung auf den Zielprozessor.** Cortex-A9 bei 667 MHz (Datenblattgrenze
XC7Z020-1): Taktfaktor 5,5; für skalaren Integer-Code mit
Tabellenzugriffen ist zusätzlich ein IPC-Faktor von etwa 2 anzusetzen. **Angenommener
Gesamtfaktor 10–12** [ANNAHME — nicht auf dem Board gemessen; die Größenordnung folgt aus
Taktverhältnis und A9-Doppel-Issue-Pipeline gegenüber einem modernen x86-Kern].

**Lastbudget im Dauerbetrieb** (Slotrate 4 / 56,67 ms = 70,6 Slots/s):

| Last | Rate | Host-Zeit/s | A9 bei Faktor 11 |
|---|---|---|---|
| DL-Signalisierung, jeder Slot codiert | 70,6 /s | 0,24 ms | 2,6 ms |
| UL-SCH/HU, beide Unterschlitze belegt | 141 /s | 3,2 ms | 35 ms |
| UL-SCH/F (lange Kurznachricht, 1 TS reserviert) | 17,6 /s | 1,0 ms | 11 ms |
| TCH/S, **3** Zeitschlitze aktiv (Maximum nach `10` R-10-04 / `12` R-12-16: TS2…TS4, TS1 trägt den Steuerkanal), decodieren + codieren | 3 × 16,7 /s | 0,47 ms | 5,1 ms |
| **Summe** | | **≈ 4,9 ms/s** | **≈ 54 ms/s ⇒ 5,4 % eines Kerns** |

Die Zeilen sind eine **Einhüllende** und **nicht** additiv: je Zeitschlitz und Frame ist
**entweder** Steuerverkehr **oder** Sprache **oder** ein Fortsetzungsburst möglich. Die
szenarienweise, additiv korrekte Bilanz steht in `13 §3.12.2`; diese Summe ist die obere
Schranke, gegen die R-05-17 geprüft wird.

**Deadline-Prüfung (R-05-17):** Teuerster Einzelvorgang ist die SCH/F-Soft-Decodierung mit
59 µs (Host) ⇒ ≈ 0,65 ms auf dem A9 = 4,6 % eines Zeitschlitzes. DL-Codierung einer
Signalisierungs-PDU ≈ 37 µs ⇒ 0,26 % eines Zeitschlitzes. Sprachkette 9,3 µs ⇒ ≈ 0,1 ms
je 60-ms-Rahmen. **Alle drei Budgets sind mit mehr als einer Größenordnung Reserve
eingehalten** — auf Basis der [ANNAHME]-Skalierung.

Zum Vergleich: der V1-RTL-SCH/F-Encoder erledigt dieselbe Arbeit in 991 Zyklen = 9,9 µs,
kostet dafür aber 2 271 LUT / 1 934 FF [BUILD 2026-06-20 `cur_hier_deep.rpt:142`]. Bei
14 167 µs Budget ist Faktor 4 Laufzeit gegen die gesamte Fläche kein Kompromiss.

**Nicht in diesem Budget:** die ACELP-Quellcodierung (`12`). Sie dominiert die PS-Last um
Größenordnungen und ist dort zu budgetieren.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Scrambler-Startwert Gold-Zelle | `0x4183F207` bei MCC 262 / MNC 1010 / CC 1 | [GOLD `reference_decode/README.md:12`] + [SIM 2026-07-25 nachgerechnet] | Formel §3.4.3 ist widerlegt, gesamte Zelle unlesbar |
| Scrambler-Startwert eigene Zelle | `0xE1670EC7` bei MCC 901 / MNC 9998 / CC 49 | [MESS `docs/local_cell_decode/DIFF_vs_reference.md:12`] + [SIM 2026-07-25 nachgerechnet] | wie oben |
| BSCH-Startwert | `0x00000003` | [ETSI §8.2.5.2], [CODE rtl/tx/tetra_sb1_encoder.v:104] | Endgerät findet die Zelle nicht — kein Sync, keine Anmeldung |
| RM(30,14)-Zeile 0 | `0x20009B60` | [ETSI §8.2.3.2 Gl. 8.13] + [GOLD `dl_full.md:21-22`] | AACH unlesbar, Endgerät verwirft **jeden** Burst der Zelle |
| CRC-Restwert bei fehlerfreiem Empfang | `0x1D0F` | [CODE rtl/lmac/tetra_crc16.v:85] + [SIM 2026-07-25 für K1 ∈ {60,92,124,268}] | Nur relevant für Prüfvariante 2 (§3.1); V2 nutzt Variante 1 |
| Punktierungsmuster r=2/3 | Positionen `{0, 1, 4}` je 8-bit-Mutterperiode | [ETSI §8.2.3.1.3 Gl. 8.8] | Faltungsdecodierung schlägt vollständig fehl |
| Interleaver-Parameter | 120/11 · 168/13 · 216/101 · 432/103 | [ETSI §8.3.1.2/.4.3/.4.1/.4.5] + [GOLD README:22-27] | Prüffeld schlägt fehl, keine PDU kommt durch |
| Soft-Gewinn synthetisch | soft 41,2 % vs. hart 3,5 % korrekt-mit-Prüffeld | [SIM 2026-07-06 `make test_ul_soft`, Host-gcc, programminternes Gaußrauschen] | Hart-Only kostet den Uplink im Rauschen |
| Soft-Gewinn auf Gold-UL | 27/27 mit Soft, 20/27 mit Hart | [GOLD `ul_events.jsonl`] + [SIM 2026-07-25 nachgerechnet] | 26 % der UL-Bursts gehen verloren |
| Viterbi-Metrik `int16_t` bricht ab | Prüffeld verletzt ab `\|soft\| = 100`, Bits korrupt ab `\|soft\| = 108` | [SIM 2026-07-25, 20 Rahmen/Magnitude, sauberer Kanal] | Sprachkanal bricht, sobald die Soft-Breite über 4 bit wächst |
| SCH/HU-Prüffeld-Rate Gold-UL | 27 OK / 161 FAIL / 4 SKIP von 192 | [GOLD `ul_full.md:3`] | Referenzwert für die Abnahme; die FAILs sind Sprach-Bursts, kein Defekt |
| SCH/HU-Prüffeld-Rate Live-Luft | ~27 % → **93 %** nach Amplituden-/Schwellwertkorrektur | [MESS 2026-05-22, Air-Messreihe `CIC_GAIN_SHF` 6/5/4 gegen UL-Prüffeld-Rate; Wert im Repo CODE rtl/rx/tetra_rx_frontend.v:135, vollständiger Messkontext in `02 §4` und `03 §4`] | Der Codierer war nie die Ursache — die Amplitudenkette war es (`03`) |
| Sprach-BFI im Betrieb | 4,7 % bei NUB-Sync-Schwelle 11 (6,1 % bei 10, kein Lock bei 12) — Stand **vor** der Offset- und Amplitudenkorrektur; der V2-Betriebswert steht in `12 §4` | [MESS 2026-05-17, NUB-Sync-Schwellen-Survey 10/11/12 über 10-s-Sprechtasten-Läufe; Wert im Repo CODE board_autostart/tetra_cell.conf:21, CODE sw/tetra_attach_daemon.c:1044; vollständiger Messkontext in `03 §4`] | Empirisch, nicht herleitbar; gehört zu `03` |
| RTL-Encoder-Laufzeiten | BSCH 143, AACH 32, SCH/HD 487, SCH/F 991 Zyklen bei 100 MHz | [CODE Modulköpfe + FSM-Zählerbreiten] | Alle ≪ 1 Zeitschlitz (1 416 700 Zyklen) |
| SW-Codierzeiten Host | siehe §3.10 | [SIM 2026-07-25] | Basis für R-05-17; Board-Messung offen (§6 O-05-1) |

---

## 5. Verifikation

Abnahme in vier Stufen. Jede Stufe hat ein binäres Kriterium.

### 5.1 Stufe 1 — Primitive gegen ETSI, nicht gegen sich selbst

| Prüfung | Kriterium |
|---|---|
| Prüffeld | Für jedes `K1 ∈ {60, 92, 124, 268}`: 1 000 Zufallsvektoren, Restwert der Prüfvariante 2 == `0x1D0F`; Variante 1 bestätigt Variante 2 |
| Mutter-Code | Ein einzelnes `1`-Bit in einen leeren Codierer: die **5** ersten Ausgangsquadrupel müssen die **Impulsantworten** der vier Generatoren reproduzieren, also in der Zeitachse (Koeffizientenfolge `g_{i,0} … g_{i,4}`, **nicht** die Maskenschreibweise aus §3.2.1) `G1 = 11001`, `G2 = 10111`, `G3 = 11101`, `G4 = 11011` [SIM 2026-07-25, gegen `sw/tetra_channel_codec.c:52-65` nachgestellt]. 4 Quadrupel genügen nicht — der `D⁴`-Tap bliebe ungetestet. Der Test ist konventionsempfindlich und fällt bei gespiegelter Zustandsordnung durch (§3.2.2) |
| Punktierung | `b3(j)` gegen [ETSI Gl. 8.7] direkt nachgerechnet, `j = 1…K3`, alle vier Kanäle |
| Interleaver | Permutation gegen [ETSI Gl. 8.34] elementweise; Hin-und-Rück ergibt die Identität für **alle** vier (K, a) |
| Scrambler | Erste 432 Bits mit Startwert `0x4183F207` gegen die aus der Gold-AACH extrahierte Folge (§3.4.3): 30/30 Bits identisch. Zusätzlich: Startwert `0x3` erzeugt die BSCH-Maske aus [CODE rtl/tx/tetra_sb1_encoder.v:104] |
| RM(30,14) | `info = 0x3000 → 0x3000B680`; `d_min = 8` per vollständiger Aufzählung; **und** jede Zeile der Matrix liegt im Code der ETSI-Matrix. Die letzte Prüfung ist die, die V1 gefehlt hat (§3.5.3) |
| Viterbi | Codieren/Decodieren über 1 000 Zufallsblöcke je Kanal: 100 % Prüffeld ok und bit-identische Rückgewinnung. Zusätzlich Metrik-Test: bei `\|soft\| = 127` **kein** Fehlverhalten (R-05-10) |

**Verbindliche Regel für diese Stufe:** Kein Testvektor darf aus derselben
Implementierung stammen, die er prüft. V1 hat genau daran zwei Bugs vorbeigelassen — die
RM-Vektoren wurden aus der eigenen Herleitung erzeugt
[CODE tb/vectors/gen_reed_muller_vectors.py:113-122], die Scrambler-Vektoren aus der
eigenen Galois-Annahme [CODE tb/vectors/gen_scrambler_vectors.py:38]. Zulässige
unabhängige Quellen: der ETSI-Normtext (händisch nachgerechnet) und die
Gold-Aufzeichnung.

### 5.2 Stufe 2 — Ketten gegen die Gold-Aufzeichnung (R-05-16)

Die Referenzaufzeichnung enthält je Burst alle Zwischenebenen. Kriterium je Kanal:
**bit-identische** Rückgewinnung der protokollierten Informationsbits **und** Prüffeld ok
**und** Tailbits `0000`.

| Kanal | Quelle | Status |
|---|---|---|
| BSCH (120, 11, `seed = 3`) | `dl_events.jsonl`, Feld `sb1_t5_onair_120b` → `sb1_info_60b` | **bestanden**, Burst 0 [SIM 2026-07-25] |
| SCH/HD (216, 101, Zell-Seed) | `bkn2_onair_216b` → `bkn2_info_124b` | **bestanden**, Burst 3 [SIM 2026-07-25] |
| SCH/F (432, 103, Zell-Seed) | `type5_onair_432b` → `info_268b` | **bestanden**, Burst 423 [SIM 2026-07-25] |
| AACH (RM + Zell-Seed) | `bb_raw_30b` → `bb_descr_30b` → `aach_info_14b` | **bestanden**, Burst 0, alle 30 Bits [SIM 2026-07-25] |
| SCH/HU (168, 13, Zell-Seed) | `ul_events.jsonl`: `type5_onair_168b` → `type4_descr_168b` → `bits92` | **bestanden** für Bursts 0 und 1; über alle 27 prüffeld-korrekten Bursts reproduziert die **harte** Decodierung 20, die restlichen 7 brauchen den Soft-Pfad [SIM 2026-07-25] |

Diese fünf Vergleiche sind als automatisierter Regressionstest zu führen (`14`), nicht als
einmalige Handrechnung. Der Vergleich ist zulässigerweise **bit-identisch**, weil hier
keine zell- oder MS-spezifischen Felder verglichen werden, sondern eine reine
Codierungsfunktion — die Einschränkung aus `CONVENTIONS.md §3` („Gold-Match heißt
funktional äquivalent") betrifft PDU-Inhalte, nicht die Codierung.

### 5.3 Stufe 3 — SW gegen die bestehenden RTL-Vektoren

Die V1-Testbenches für die SCH/F-, SCH/HD-, SCH/HU- und AACH-Encoder/Decoder existieren
mit generierten Vektoren (`tb/tb_sch_f_encoder.v`, `tb_sch_hd_encoder.v`,
`tb_ul_sch_hu_decoder.v`, `tb_tetra_aach_encoder.v`,
`tb/vectors/aach_reference.memh`, `scripts/gen_sch_f_tv.py`, `gen_sch_hd_tv.py`,
`gen_sch_hu_tv.py`, `gen_sch_f_dec_tv.py`). V2 verwendet dieselben Vektoren als
Regression gegen die **SW**-Kette: **4/4** wurde in V1 bereits erreicht
[SIM 2026-07-06, `make test_ul_parity`, Host-gcc]. Kriterium: 100 % identisch.

### 5.4 Stufe 4 — Luft

| Kriterium | Messgröße | Zielwert |
|---|---|---|
| DL wird von kommerziellem Endgerät decodiert | Anmeldung mit 2 Endgeräten, ≥ 3 Durchläufe | 3/3 erfolgreich |
| DL wird von unabhängigem Empfänger decodiert | Mitschnitt + `scripts/decode_dl.py` | Prüffeld-Erfolg ≥ 99 % der Signalisierungs-Bursts |
| UL-Signalisierung | `crc_fail / attempts` je Kanal aus den Zählern (R-05-12) | SCH/HU ≥ 90 % bei geeigneter Amplitudenkette (V1-Referenz 93 %, [MESS 2026-05-22]) |
| Sprachkanal | BFI-Zähler über 10 s Sprechtaste, ≥ 3 Durchläufe | ≤ 5 % (V1-Referenz 4,7 %, [MESS 2026-05-17]) |
| Kein zweiter Codierer (R-05-01) | statische Prüfung: `grep` über `rtl/` und `sw/` nach den Konstanten `0x1021`, `0x13/0x1D/0x17/0x1B`, `103`/`101`/`13`/`11` als Interleaver-Parameter, den 14 RM-Zeilen und der Tap-Liste | jede Konstante existiert an **genau einer** Stelle; Ausnahme: BSCH- und AACH-RTL dürfen die Scrambler-Taps und die RM-Zeilen tragen |

Die letzte Zeile ist ein echtes Abnahmekriterium, kein Stilhinweis: sie ist die einzige
Prüfung, die R-05-01 dauerhaft durchsetzt.

---

## 6. Offene Punkte

**O-05-1 — Rechenlast auf dem Zielprozessor ist nicht gemessen.** §3.10 beruht auf einer
Host-Messung und einem angenommenen Skalierungsfaktor 10–12. R-05-17 fordert eine
Messung auf dem Board. *Empfehlung:* Beim Bring-up einen Mikrobenchmark im Daemon mitliefern
(`CLOCK_MONOTONIC` um jede `tetra_cc_*`-Aufruf-Klasse, Perzentile 50/99 über 60 s) und die
Werte in `08_TIMING.md` als `[MESS]` eintragen. Die Reserve ist nach der Rechnung so groß
(> Faktor 20), dass ein Scheitern unwahrscheinlich ist — aber „unwahrscheinlich" ist kein
Messwert.

**O-05-2 — Reihenfolge Descramble/Deinterleave im Empfänger als Kostenfrage.** Die
Norm definiert die Scrambler-Folge auf der type-4-Achse (§2.2), also muss zuerst
descrambelt werden. Das V1-RTL verschmilzt beides in einen Lesevorgang mit permutierter
Adresse [CODE rtl/rx/tetra_ul_sch_f_decoder.v:23,253-279]. In Software ist die
Verschmelzung ebenfalls möglich (Vorzeichen beim permutierten Lesen anwenden) und spart
einen 432-Byte-Durchlauf. *Empfehlung:* getrennte Stufen implementieren — der
Geschwindigkeitsgewinn ist gegenüber der Viterbi-Zeit (§3.10) irrelevant, die
Nachvollziehbarkeit wichtiger. Erst optimieren, wenn O-05-1 einen Grund liefert.

**O-05-3 — ETSI-Belege der Sprachkanal-Codierung nicht am Normtext geprüft.** Die
Parameter in §3.8.6 (Klassentabellen, Sprach-Generatorpolynome, beide
Punktierungsmuster, 24×18-Interleaver, `X⁷+X³+1`) sind `[CODE]`-belegt und über den
Air-Test mittelbar bestätigt (Endgeräte decodieren die re-codierten Bursts), aber nicht
gegen EN 300 395-2 verifiziert — der Normtext lag nicht vor. *Empfehlung:* EN 300 395-2
§5.4/§5.5/§5.6 beschaffen und jede Zeile der Tabelle in §3.8.6 einzeln gegen den
Paragraphen abgleichen, bevor der Sprachkanal in V2 als abgenommen gilt. Bis dahin gilt:
Werte übernehmen, **nicht** „aufräumen".

**O-05-4 — Klassen-Umsortierung im Sprachkanal: zwei Varianten im Repo.** Die live
laufende Funktion ordnet **paarweise** (`codec[pos]`, `codec[137+pos]` direkt
hintereinander) [CODE sw/tetra_bs_tch_s.c:47-65]; die zweite, nicht aufgerufene Variante
ordnet **klassenweise erst Rahmen 1, dann Rahmen 2**, und ihr Kommentar widerspricht sich
dabei selbst („interleaved per ETSI" … „actually frame-by-frame")
[CODE sw/tetra_tch_s_codec.c:143-170]. *Empfehlung:* mit O-05-3 zusammen klären und die
Alternative löschen, nicht kommentieren.

**O-05-5 — Punktierungsraten 292/432 und 148/432 und Interleaving über N Blöcke.** Für
Sprache und Signalisierung nicht benötigt, erst für leitungsvermittelte Datenkanäle
[ETSI §8.2.3.1.5/.1.6, §8.2.4.2]. *Empfehlung:* Die Punktierungsfunktion aus §3.2.3 nimmt
`t`, `P[]` und die `i`-Abbildung als Kanaltabellen-Eintrag; damit sind beide Raten ohne
Codeänderung nachrüstbar. Ebenso bleibt die AACH-Decodierung (§3.5.2) hinter der
Schnittstelle aus §2.4 austauschbar, falls je ein Betriebsfall entsteht, der sie im
Empfangspfad braucht. Beides mit diesem Verweis in `18_ROADMAP.md` führen.
