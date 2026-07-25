# 03 — Uplink-Empfangs-PHY

**Scope:** Die vollständige UL-gerichtete Empfangs-PHY zwischen dem 72-kHz-Post-RRC-IQ-Strom
und den Soft-Bit-Strömen an die Kanaldecodierung: UL-Synchronisation mit 4-fach-Überabtastung
und Phasenwahl, Erfassung des Control-Uplink-Bursts (CB) und des Normal-Uplink-Bursts (NUB),
differentielle π/4-DQPSK-Soft-Demodulation mit Amplituden-Normierung, Soft-Quantisierung,
Vorzeichen- und Bit-Order-Konvention, Schwellwerte samt Messkontext, Verhalten ohne Sync.

**Nicht hier:**
- DL-Empfangskette (Dezimation, CIC, RRC, Gardner-Timing-Recovery, DL-Sync, Burst-Demux) → `02_PHY_DL_RX.md`
- CRC, Descrambling, Deinterleaving, Depunktierung, Viterbi, RM(30,14) → `05_CHANNEL_CODING.md`
- MAC-PDU-Parsing, LI, Reservierung, Fragment-Reassembly, AACH → `06_MAC.md`
- Registeradressen und Mailbox-Protokolle → `07_PS_PL_CONTRACT.md`
- DL→UL-Air-Lock, Slot-Zuordnung eines empfangenen UL-Bursts → `08_TIMING.md`
- TCH/S-Codec, BFI, Voice-Relay → `12_VOICE.md`

**Abhängigkeiten:** `01_PLATFORM.md` (Clock-/Reset-Architektur, `clk_sys` = 100 MHz),
`02_PHY_DL_RX.md` (Eingangsvertrag des 72-kHz-IQ-Taps), `07_PS_PL_CONTRACT.md` (Registernamen).

---

## 1. Anforderungen

| ID | Anforderung |
|---|---|
| **R-03-01** | Die UL-Empfangskette ist eine **eigene, vom DL entkoppelte Kette**. Sie darf keinen geschlossenen Regelkreis (Timing-PLL, AGC-Loop, Frequenz-Loop) enthalten, dessen Einschwingzeit die Dauer eines einzelnen UL-Bursts überschreitet. Begründung in §2.1. |
| **R-03-02** | Die UL-Synchronisation arbeitet auf dem 4-fach überabgetasteten Post-RRC-IQ-Strom (72 kHz) und prüft **alle vier Symbolphasen gleichzeitig**. Ein Burst muss unabhängig von seiner Sub-Symbol-Ankunftsphase erkannt werden. |
| **R-03-03** | Es existieren **zwei unabhängig parametrierte Sync-Instanzen**: eine auf die Extended Training Sequence (x-Sequenz, 15 Symbole) für den CB, eine auf Normal Training Sequence 1 (NTS1, 11 Symbole) für den NUB. Beide haben getrennte, zur Laufzeit einstellbare Korrelationsschwellen. |
| **R-03-04** | Die UL-Sync-Schwelle darf **nicht** mit der DL-Sync-Schwelle geteilt werden. Getrennte Register, getrennte Defaults (§4). |
| **R-03-05** | Die Burst-Erfassung liest die Symbol-Samples **relativ zum Sync-Anker mit exakt den in §3.4/§3.6 tabellierten Offsets**, abgeleitet aus ETSI Tabelle 9.3 (CB) bzw. Tabelle 9.5 (NUB). Kein Offset darf von einem DL-Burst-Layout übernommen werden. |
| **R-03-06** | Die Soft-Demodulation liefert pro Dibit zwei vorzeichenbehaftete Soft-Werte. Der Betrag ist **amplituden-normiert**: er hängt nur von `cos Δφ` / `sin Δφ` ab, nicht vom Produkt der beiden Sample-Magnituden. Das gilt für **beide** UL-Pfade (CB und NUB) mit identischem Normierer. |
| **R-03-07** | Die Vorzeichenkonvention ist **systemweit einheitlich** und ETSI-ausgerichtet: `soft > 0 ⇒ Bit '0'`, `soft < 0 ⇒ Bit '1'` (§3.2). Es gibt genau **eine** legale Inversionsstelle im Gesamtsystem, und sie liegt in der SW-Adaption zum TCH/S-Soft-Viterbi, nicht in der PHY. |
| **R-03-08** | Die Bit-Order jedes Soft-Vektors und jedes Mailbox-Worts ist explizit festgelegt (§3.2.3, §3.6.4). On-Air-Reihenfolge und Index-Reihenfolge müssen an genau einer Stelle umgerechnet werden, dokumentiert an der Stelle. |
| **R-03-09** | Die Ausleseoperation eines Bursts aus dem Ringpuffer muss abgeschlossen sein, bevor der Schreibzeiger in den gelesenen Bereich läuft. Der Nachweis erfolgt rechnerisch aus Ringtiefe, Sample-Rate und Zyklenbedarf (§3.4.4, §3.6.5). |
| **R-03-10** | Ohne Sync gibt die Kette **keine** Soft-Werte aus, verbraucht keine Downstream-Kapazität und hält alle Zwischenregister in definiertem Zustand. Ein Sync-Fehlalarm darf höchstens einen verworfenen Decodierversuch kosten (§3.8). |
| **R-03-11** | Jede Sync-Instanz stellt zur Laufzeit lesbar bereit: Anzahl Sync-Ereignisse, Peak-Korrelationswert seit letztem Reset, gewinnende Phase, Anzahl erfasster Bursts. Diese Werte müssen von der SW **tatsächlich lesbar** sein (Registername in `07`, kein Adressüberlapp mit einem Write-Register). |
| **R-03-12** | Die Kette benötigt eine korrekte Amplituden-Observability über den vollen 16-bit-Bereich des Post-RRC-Samples, um den Arbeitspunkt des Soft-Quantisierers prüfbar zu machen (§5.4). |
| **R-03-13** | Es gibt keine CFO-Schätzung/-Korrektur in der UL-PHY. Die differentielle Demodulation muss den nach ETSI §7.8 a) zugelassenen MS-Frequenzfehler von ±100 Hz tolerieren; der Nachweis ist rechnerisch zu führen (§3.3.5). |
| **R-03-14** | Keine synthetisierte Debug-Instrumentierung im FPGA. Verifikation über Simulation, Testvektoren, AXI-Zähler und Luft-Captures (§5). |

---

## 2. Architektur / Aufbau

### 2.1 Warum UL und DL getrennte Empfangsketten sind

Das ist eine bewusste Architektur-Entscheidung, keine Redundanz. Vier Gründe, jeder einzeln
ausreichend:

**(1) Die DL-Timing-Recovery kann innerhalb eines UL-Bursts nicht einrasten.**
Die DL-Kette gewinnt Symboltakt über einen Gardner-TED mit PI-Loop und meldet Lock erst nach
`LOCK_COUNT = 144` aufeinanderfolgenden Symbolen mit `|TED| < LOCK_THRESH`
[CODE rtl/rx/tetra_timing_recovery.v:82-83]. 144 Symbole entsprechen bei 18 kHz Symbolrate
8,0 ms. Ein CB ist 103 Symbole lang (5,7 ms) [ETSI Tabelle 9.2, Snmax = 103], ein NUB
231 Symbole (12,8 ms) [ETSI Tabelle 9.2, Snmax = 231]. Der CB ist damit **kürzer als die
Lock-Zeit**; der Loop liefert über die gesamte Burstdauer willkürliche Symbolphase. Die
18-kHz-Dibits am Ausgang der DL-Kette sind für einen isolierten UL-Burst systematisch
fehlerbehaftet.

**(2) UL ist bursthaft, DL ist quasi-kontinuierlich.** Der DL-Träger der BS sendet in jedem
Slot; der UL-Träger trägt einzelne MS-Bursts mit weniger als 1 % Tastverhältnis. Jeder
Regelkreis, der auf Dauersignal ausgelegt ist (Timing-PLL, langsame AGC-Integration), driftet
in den Lücken weg und muss pro Burst neu akquirieren — was nach (1) nicht geht.

**(3) Die Ankunftsphase jedes UL-Bursts ist unabhängig.** Die MS hält ihre Zeitbasis nur
innerhalb von 125/9 µs zur BS-Zeitbasis nach und korrigiert in Schritten von höchstens
125/9 µs, im Abstand von 1–3 s [ETSI §7.8 b)]. 125/9 µs = 13,89 µs = **exakt ein
Sample-Intervall bei 72 kHz** = ¼ Symbol. Dazu kommt die Laufzeit. Die Sub-Symbol-Phase ist
also pro Burst und pro MS anders und liegt in einem Fenster von rund einem 4-sps-Sample.
Eine Vorwärts-Phasenwahl über 4 parallele Phasen deckt dieses Fenster ohne Akquisitionszeit
vollständig ab; ein Regelkreis kann es nicht.

**(4) UL und DL tragen strukturell verschiedene Bursts.** DL: SB mit Synchronization
Training Sequence (38 bit) und NDB mit Broadcast-Block, beide mit BBK. UL: CB mit Extended
Training Sequence (30 bit) und NUB mit Normal Training Sequence (22 bit), **beide ohne BBK**
[ETSI Tabelle 9.3, 9.5 vs. 9.7, 9.9]. Trainingsfolge, Länge, Feldreihenfolge und Ankerposition
sind disjunkt. Genau die Übernahme einer DL-Annahme (NDB mit BB1/BB2, 255 Symbole) in den
NUB-Pfad hat in V1 die Sample-Offset-Fehler aus §3.6.2 erzeugt.

**Konsequenz für V2 (normativ):** Es gibt keine gemeinsame Symboltakt-Rückgewinnung für UL
und DL. Der UL-Zweig tappt ausschließlich den 72-kHz-Post-RRC-IQ-Strom und arbeitet rein
vorwärts. Gemeinsam genutzt wird nur das RX-Frontend (CIC + RRC), siehe §3.1.

### 2.2 Blockstruktur

```
        (aus Kapitel 02)
  fe_i_sys/fe_q_sys/fe_valid_sys      72 kHz = 4 sps, 16 bit signed, clk_sys
                 │
     ┌───────────┴────────────────────────────┐
     │                                        │
 ┌───▼──────────────────┐            ┌────────▼─────────────┐
 │ tetra_ul_sync_os4    │            │ tetra_ul_sync_os4    │
 │  PATTERN = x-seq     │            │  PATTERN = NTS1      │
 │  LEN_SYM = 15        │            │  LEN_SYM = 11        │
 │  thresh = UL_CB      │            │  thresh = UL_NUB     │
 └───┬──────────────────┘            └────────┬─────────────┘
     │ sync_found, best_phase                 │ sync_found, best_phase
 ┌───▼──────────────────┐            ┌────────▼─────────────┐
 │ tetra_ul_cb_capture  │            │ tetra_ul_nub_capture │
 │  Ring 512×2×16 bit   │            │  Ring 1024×2×16 bit  │
 │  2 × 43 Samples      │            │  2 × 109 Samples     │
 └───┬──────────────────┘            │  + Diff-Demod        │
     │ IQ @ Symbolrate               │  + Normierer         │
 ┌───▼──────────────────┐            │  + Soft-BRAM (2 Bank)│
 │ tetra_ul_soft_demod  │            └────────┬─────────────┘
 │  Diff-Produkt        │                     │ Wort-Port (AXI-indiziert)
 │  L1-Normierung       │                     │
 │  Sättigung → 8 bit   │                     │
 └───┬──────────────────┘                     │
     │ 168 Softs/Burst                        │ 432 Softs/Burst
     └────────────────┬───────────────────────┘
                      ▼
      UL-Burst-Mailbox (Kap. 07 §3.4)  ──▶  SW-Decode (Kap. 05)
      W0.burst_type = 00 Control Uplink Burst · 01 Normal Uplink Burst
                      (Erfassungszweig, KEIN logischer Kanal)
                      ──▶ 12 (Sprache) · 06/09/11 (Signalisierung)
                      Sprache ↔ Signalisierung entscheidet die SW (13 §3.2)
```

**`burst_type` benennt den Erfassungszweig, nicht den logischen Kanal.** Die Belegung des
Feldes steht normativ in `07 §3.4`: `00` = Control Uplink Burst (168 Soft), `01` = Normal
Uplink Burst (432 Soft), `10`/`11` reserviert. Was die PL unterscheiden **kann**, ist
ausschließlich physikalisch: die getroffene Sync-Sequenz (x-Sequenz gegen NTS1) und die
daraus folgende Burstlänge. Ob ein Normal-Uplink-Burst Sprache oder ein SCH/F-Fragment
trägt, weiß die PL nicht (§3.7) und darf sie nach `00 §3.3` Punkt 2 und `00` R-00-02 auch
nicht auswerten; diese
Zuordnung fällt in der Software über den Reservierungszustand des Zeitschlitzes
(`13 §3.2`).

Beide Zweige laufen dauerhaft und unabhängig. Ein NUB kann gleichzeitig vom CB-Zweig
korreliert werden (und umgekehrt); Fehlalarme werden downstream durch CRC verworfen (§3.8).

**Ein Ausgang, kein Kanaldecoder in der PL.** Beide Zweige enden an **derselben** Mailbox.
Die Kanaldecodierung der Nutzdaten liegt vollständig in Software — `00 §3.3` Punkt 2,
`05` R-05-01 („vollständig in Software") und R-05-02 („die einzigen Kanalcodierer in Hardware
sind BSCH und AACH — keine weiteren"), und `07 §3.4` nennt die Mailbox den **einzigen** Weg
eines Uplink-Bursts zur Software, mit rohen Soft-Werten **vor jeder Decodierung**. V1 hat an
dieser Stelle zwei RTL-Decoder (`tetra_ul_sch_hu_decoder` 4 851 LUT / 5 786 FF,
`tetra_ul_sch_f_decoder` 2 602 LUT / 1 809 FF / 3 RAMB18) plus den Soft-Adapter
`tetra_ul_nub_to_schf` (484 LUT / 1 749 FF); alle drei entfallen samt Fläche
[BUILD 2026-06-20, Aufstellung in `05 §2.1`].

### 2.3 Modul-Umbenennungen gegenüber V1 (mit Begründung)

| V1 | V2 | Grund |
|---|---|---|
| `tetra_ul_sync_detect_os4` | `tetra_ul_sync_os4` | „detect" ist redundant; sonst identisch. |
| `tetra_ul_burst_capture` | `tetra_ul_cb_capture` | Das Modul erfasst ausschließlich den **Control Uplink Burst**. Der generische Name hat in V1 die Verwechslung mit dem NUB-Pfad begünstigt. |
| `tetra_ul_pi4dqpsk_demod` | `tetra_ul_soft_demod` | Es gibt in V1 zusätzlich `tetra_pi4dqpsk_demod` (DL, Hard-Dibit). Namensnähe zweier Module mit unterschiedlicher Ausgangs-Semantik ist eine bekannte Fehlerquelle. |
| `tetra_ul_nub_to_schf` | **entfällt** | Der Adapter existiert nur, um einen 1728-bit-Parallelvektor zu latchen, umzudrehen und das Vorzeichen zu korrigieren. Alle drei Aufgaben verschwinden durch §3.6.4 (BRAM-Ausgang in On-Air-Ordnung) und R-03-07 (einheitliches Vorzeichen). Wert V1: 484 LUT / 1749 FF nur für diesen Adapter [BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt:151`]. |

---

## 3. Detail-Spezifikation

### 3.1 Eingangsvertrag

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `clk_sys` | 1 | in | — | 100 MHz, Periode 10,000 ns [BUILD 2026-07-12, `build/reports/clock_interaction.rpt:20`] |
| `rst_n_sys` | 1 | in | `clk_sys` | active-low, synchron deasserted über 2-FF (Kap. 01) |
| `fe_i_sys` | 16 signed | in | `clk_sys` | Post-RRC I, Q1.15-artig, Vollskala ±32767 |
| `fe_q_sys` | 16 signed | in | `clk_sys` | Post-RRC Q |
| `fe_valid_sys` | 1 | in | `clk_sys` | 1-Zyklus-Strobe, **72 kHz** = 4 sps |

Erzeugt von der gemeinsamen RX-Frontend-Kette (Kapitel 02): CIC 5. Ordnung, R = 64,
4,608 MHz → 72 kHz, danach 33-Tap-RRC mit α = 0,35
[CODE rtl/rx/tetra_rx_frontend.v:9-11], [ETSI §5.5 Gl. 5.4: α = 0,35].
`SAMPLERATE_HZ=4608000` / `CIC R=64` → 72 kHz = 4 × 18 kHz Symbolrate
[CODE board_autostart/tetra_cell.conf:8]. Die Symbolrate folgt aus der Modulationsrate
36 kbit/s bei 2 bit/Symbol [ETSI §5.3].

**Abstand zwischen zwei `fe_valid_sys`-Strobes:** 100 MHz / 72 kHz = 1388,9 `clk_sys`-Zyklen.
Diese Zahl ist die Zeitreserve, in der jede Burst-Ausleseoperation abgeschlossen sein muss
(R-03-09).

**Amplitudenkontrakt.** Die CIC-Ausgangsverstärkung ist ein gemeinsamer Parameter von DL und
UL. V1 verwendet `CIC_GAIN_SHF = 4` (×16) [CODE rtl/rx/tetra_rx_frontend.v:135]. Der Wert war
×64 und wurde gesenkt, weil UL-Bursts bei AGC-Übergängen in die 16-bit-Sättigung gedrückt
wurden; Air-Messung: UL-SCH/HU-CRC-Rate von 16,3 % (×64) auf 25,5 % (×16) bei sonst
gleichen Bedingungen, und zusammen mit der UL-Schwelle 15 auf 92,6 % / 94,1 % in zwei
Läufen [MESS 2026-05-22]. **Der Header derselben Datei behauptet weiterhin `CIC_GAIN_SHF=6`
[CODE rtl/rx/tetra_rx_frontend.v:21] — Kommentar-Drift, der Code gilt.** In V2 ist dieser
Wert Gegenstand von Kapitel 02; die UL-PHY setzt lediglich voraus, dass der Arbeitspunkt
Sättigung vermeidet, und macht sich durch R-03-06 vom absoluten Pegel unabhängig.

### 3.2 Dibit-Demapping und Vorzeichenkonvention (normativ)

Diese Festlegung war in V1 die teuerste Einzelfehlerquelle. Sie wird hier vollständig aus
ETSI abgeleitet, nicht aus Code übernommen.

#### 3.2.1 Ableitung aus ETSI

π/4-DQPSK bildet ein Bitpaar auf einen Phasensprung ab [ETSI Tabelle 5.1]:

| B(2k−1) | B(2k) | Δφ(k) | cos Δφ | sin Δφ |
|:-:|:-:|:-:|:-:|:-:|
| 0 | 0 | +π/4 | + | + |
| 0 | 1 | +3π/4 | − | + |
| 1 | 1 | −3π/4 | − | − |
| 1 | 0 | −π/4 | + | − |

Daraus folgt **zwingend und ohne Freiheitsgrad**:

```
sign(cos Δφ) = +  ⇔  B(2k)   = 0        (zweites Bit des Paares)
sign(sin Δφ) = +  ⇔  B(2k−1) = 0        (erstes Bit des Paares, zuerst gesendet)
```

Mit dem differentiellen Produkt `z(k) = r(k) · conj(r(k−1))`, also
`Re z = I_k I_{k−1} + Q_k Q_{k−1}` und `Im z = Q_k I_{k−1} − I_k Q_{k−1}`, gilt
`Re z = |r_k||r_{k−1}| cos Δφ` und `Im z = |r_k||r_{k−1}| sin Δφ`.

#### 3.2.2 Normative Konvention V2

> **K1 — Soft-Vorzeichen.** Für jedes Dibit gilt am Ausgang jeder UL-PHY-Stufe:
> `soft_bit1 = f(Im z)` gehört zu **B(2k−1)** (zuerst gesendet),
> `soft_bit0 = f(Re z)` gehört zu **B(2k)**.
> `f` ist monoton steigend und ungerade. Damit:
> **`soft > 0 ⇔ Bit '0'`, `soft < 0 ⇔ Bit '1'`, `soft = 0 ⇔ Erasure`.**
>
> **K2 — Hard-Dibit.** Wird eine harte Entscheidung gebildet, ist
> `dibit[1] = ¬sign(Im z) = MSB(Im z)`, `dibit[0] = MSB(Re z)` (Zweierkomplement-MSB),
> also `dibit = {B(2k−1), B(2k)}` — MSB = zuerst gesendetes Bit.
>
> **K3 — Genau eine Inversionsstelle.** Der SW-TCH/S-Soft-Viterbi arbeitet mit der
> umgekehrten Konvention (`+1 = starkes '1'`) [CODE sw/tetra_bs_tch_s.c:221,
> `sw/tetra_bs_tch_s.c:412`]. Die dafür nötige Negation liegt **ausschließlich** in der
> SW-Adaptionsfunktion unmittelbar vor dem TCH/S-Decoder, mit Kommentarverweis auf K1.
> Kein RTL-Modul negiert.

#### 3.2.3 Belege und Konsistenzprüfung gegen V1

Die K1-Richtung ist bereits die Konvention von

- dem Referenz-Python-Decoder: `soft[2i] = sin(Δφ)` (MSB), `soft[2i+1] = cos(Δφ)` (LSB),
  Docstring „positive=0, negative=1" [CODE scripts/decode_dl.py:492-503];
- dem CB-Soft-Demod: `soft_bit0 = Re z`, `soft_bit1 = Im z`, ohne Negation
  [CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:248-249];
- beiden RTL-Kanaldecodern: `to_vit_soft` bildet mit `diff = VIT_CENTER − s_in` ab, d. h. ein
  positiver signed Soft wird auf den unsigned-Bereich nahe 0 („starkes '0'") abgebildet
  [CODE rtl/rx/tetra_ul_sch_hu_decoder.v:177-192] und [CODE rtl/rx/tetra_ul_sch_f_decoder.v:130-140];
- der x-Sequenz-Referenz im Sync-Detektor: das erste Dibit `2'b10` entspricht x₁x₂ = (1,0),
  also `dibit[1]=1 ⇒ Im z < 0` und `dibit[0]=0 ⇒ Re z > 0` ⇒ Δφ = −π/4 — genau der
  Tabellenwert für (1,0) [CODE rtl/rx/tetra_ul_sync_detect_os4.v:48-53], [ETSI Tabelle 5.1].

**Die eine Abweichung in V1 — und sie ist beabsichtigt:** Der Sprachkanal-Pfad negiert das
differentielle Produkt vor dem Slicing:

```verilog
// rtl/rx/tetra_ul_nub_capture.v:213-214
wire signed [2*IQ_WIDTH:0] i_shifted_w = (-i_prod_r) >>> SOFT_SHIFT;
wire signed [2*IQ_WIDTH:0] q_shifted_w = (-q_prod_r) >>> SOFT_SHIFT;
```

Damit gilt im NUB-Pfad von V1 **`positiver Soft = Bit '1'`**, dokumentiert im Modulkommentar
[CODE rtl/rx/tetra_ul_nub_capture.v:207-212]. Grund: der direkte Verbraucher war der
SW-TCH/S-Soft-Viterbi mit umgekehrter Konvention. Der empirische Beleg, dass die Konsistenz
end-to-end zählt: erster Build ohne Negation ergab BFI 23 %, der Build mit Negation BFI 3 %,
validiert in einer 4-Run-PTT-Serie [MESS 2026-05-18].

Als der zweite Verbraucher (RTL-SCH/F-Decoder für lange UL-SDS) dazukam, musste er
zurück-negieren:

```verilog
// rtl/rx/tetra_ul_nub_to_schf.v:52-59
conv = -ext;   // invert (NUB→ETSI)
```

**Bewertung für V2:** Die Messung belegt, dass die *Konsistenz* zwingend ist — nicht, dass
die Negation in `nub_capture` liegen muss. Zwei Negationen in Serie in derselben RX-Kette
sind Drift. V2 legt K1 fest und verschiebt die einzige Negation nach K3 in die SW.
**Wer diese Stelle anfasst, muss die Abnahme aus §5.5 fahren** — bricht die Konvention, ist
`soft{bfi} ≫ hard{bfi}` das Symptom.

#### 3.2.4 Bit-Order-Festlegungen

- **Dibit-Paar:** MSB = B(2k−1) = zuerst gesendet. Gilt für Sync-Pattern-Register,
  Hard-Dibits und die Paar-Reihenfolge in gepackten Soft-Wörtern.
- **ETSI-Bitnummerierung:** ETSI zählt Burst-Bits ab 1 (`BN 1`), Feldbits ab 1
  (`bkn1(1)`). Alle Symbol- und Sample-Offsets in §3.4/§3.6 sind aus dieser 1-basierten
  Zählung abgeleitet und dann als 0-basierte Distanz zum Anker angegeben.
- **Soft-Vektor:** siehe §3.6.4 — On-Air-Index aufsteigend, Speicher-Index aufsteigend,
  keine Umkehr.

### 3.3 `tetra_ul_sync_os4` — Sync mit 4-Phasen-Überabtastung

#### 3.3.1 Zweck

Detektiert eine bekannte Trainingsfolge im 4-sps-IQ-Strom, ohne Symboltakt-Rückgewinnung,
und liefert zusätzlich die gewinnende Symbolphase, damit die nachfolgende Erfassung direkt
mit Schrittweite 4 abgreifen kann.

#### 3.3.2 Schnittstelle

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `clk_sys` | 1 | in | — | 100 MHz |
| `rst_n_sys` | 1 | in | `clk_sys` | active-low |
| `reset_peak_sys` | 1 | in | `clk_sys` | 1-Zyklus-Puls: `corr_peak_sys` löschen |
| `i_in_sys`, `q_in_sys` | 16 signed | in | `clk_sys` | Post-RRC IQ |
| `valid_in_sys` | 1 | in | `clk_sys` | 72-kHz-Strobe |
| `corr_threshold_sys` | 6 | in | `clk_sys` | Trefferschwelle, 2-FF-resynchronisiert aus `clk_axi` |
| `sync_found_sys` | 1 | out | `clk_sys` | 1-Zyklus-Puls, 1 Zyklus nach dem auslösenden Sample |
| `corr_peak_sys` | 6 | out | `clk_sys` | Sticky-Maximum von `corr_max` seit `reset_peak_sys` |
| `best_phase_sys` | 2 | out | `clk_sys` | gewinnende Phase 0..3, gelatcht bei `sync_found_sys` |

Parameter: `IQ_WIDTH = 16`, `SYNC_PATTERN [29:0]`, `SYNC_LEN_SYM`, `HOLDOFF`.

#### 3.3.3 Verhalten

Pro `valid_in_sys`-Sample, alles rein vorwärts, alle Zeilenverweise auf
`rtl/rx/tetra_ul_sync_detect_os4.v`:

| # | Schritt | [CODE :Zeile] |
|---|---|---|
| 1 | `phase_cnt_sys` inkrementiert modulo 4 | 80-86 |
| 2 | Pro Phase k ein Registerpaar `i_hist_k/q_hist_k`, nur bei `phase_cnt == k` geschrieben → hält das Sample **ein Symbol** zurück, nicht ein Sample | 92-109 |
| 3 | Differentialprodukt gegen die Historie der aktuellen Phase, 4 signed Multiplikationen (DSP48) | 129-135 |
| 4 | Hard-Dibit nach K2: `{MSB(Im z), MSB(Re z)}` | 140 |
| 5 | Vier Schieberegister à 30 bit, jedes nur bei seiner Phase geschoben; neuestes Dibit nach `[1:0]`, ältestes bei `[2·LEN−1 : 2·LEN−2]` | 146-160 |
| 6 | Korrelation = Anzahl vollständig übereinstimmender Dibits gegen `SYNC_PATTERN` über `SYNC_LEN_SYM` Slots, zur Synthesezeit entrollt | 167-180 |
| 7 | Max-Reduktion über 4 Phasen; bei Gleichstand gewinnt die niedrigste | 190-197 |
| 8 | `sync_fire = valid_in ∧ (corr_max ≥ thresh) ∧ ¬holdoff` | 213 |

`HOLDOFF` zählt `valid_in`-Samples, **nicht** Symbole — der Parameterkommentar in V1 sagt
„symbols" und ist falsch [CODE rtl/rx/tetra_ul_sync_detect_os4.v:44 vs. :220-221].

**Strukturelle Eigenschaft, die die Schwellwert-Messreihe in §4 erklärt:**
`corr_max ∈ [0, SYNC_LEN_SYM]`. Für die NUB-Instanz mit `SYNC_LEN_SYM = 11` ist
`thresh = 11` gleichbedeutend mit **exakter 11/11-Übereinstimmung**, und `thresh = 12` ist
**konstruktiv unerreichbar** — der Detektor ist dann tot. Für die CB-Instanz mit
`SYNC_LEN_SYM = 15` erlaubt `thresh = 13` zwei Fehldibits, `thresh = 15` fordert exakte
Übereinstimmung.

Eine Schutzbedingung verhindert zusätzlich, dass eine zu große Schwelle als „immer treffend"
missinterpretiert wird: `|corr_threshold_sys[5]` sperrt den Vergleich für Werte > 31
[CODE rtl/rx/tetra_ul_sync_detect_os4.v:209-211]. Der IST-Doku-Eintrag nennt hier `[.. :4]`
und ist gedriftet [docs/ist/04_ul_rx.md:38] — der Code gilt.

#### 3.3.4 Trainingsfolgen (verifiziert gegen ETSI)

**CB-Instanz — Extended Training Sequence, π/4-DQPSK, 30 bit / 15 Symbole**
[ETSI §9.4.4.3.3 Gl. 9.9]:

```
x1..x30 = 1,0 0,1 1,1 0,1 0,0 0,0 1,1 1,0 1,0 0,1 1,1 0,1 0,0 0,0 1,1
Dibits  = 10  01  11  01  00  00  11  10  10  01  11  01  00  00  11
```

Bit-für-Bit identisch mit dem V1-Default-Parameter
[CODE rtl/rx/tetra_ul_sync_detect_os4.v:48-53]. Ausrichtung: x₁x₂ in `[29:28]` (ältestes),
x₂₉x₃₀ in `[1:0]` (neuestes) — passt zur Schieberichtung.

**NUB-Instanz — Normal Training Sequence 1, π/4-DQPSK, 22 bit / 11 Symbole**
[ETSI §9.4.4.3.2 Gl. 9.4]:

```
n1..n22 = 1,1 0,1 0,0 0,0 1,1 1,0 1,0 0,1 1,1 0,1 0,0
Dibits  = 11  01  00  00  11  10  10  01  11  01  00
```

Bit-für-Bit identisch mit `NTS1_REF_22B` [CODE rtl/rx/tetra_rx_chain.v:424-427], gepackt
nach `[21:0]`, `[29:22] = 0`, `SYNC_LEN_SYM = 11` [CODE rtl/rx/tetra_rx_chain.v:433-438].

> **Hinweis zur logischen Kanalzuordnung:** NTS1 signalisiert „ein logischer Kanal auf
> BKN1+BKN2" (TCH oder SCH/F), NTS2 „zwei Kanäle" (STCH+TCH usw.) [ETSI Tabelle 9.13].
> V1 korreliert nur NTS1. Das ist konsistent damit, dass In-Call-Stealing (STCH) nicht im
> Empfangsumfang liegt; siehe §6, offener Punkt O-03-6.

#### 3.3.5 Toleranz gegen Frequenzfehler (Nachweis zu R-03-13)

Die MS hält ihre Trägerfrequenz auf ±100 Hz gegenüber dem BS-Signal [ETSI §7.8 a)]; die BS
selbst auf besser als ±0,2 ppm [ETSI §7.7]. Ein Frequenzfehler Δf erzeugt zwischen zwei
Symbolen eine zusätzliche Phasendrehung von 2π·Δf/18000. Für Δf = 100 Hz sind das
34,9 mrad = 2,00° [ANNAHME: Rechnung, keine Messung]. Die Entscheidungsgrenze der
differentiellen Detektion liegt bei π/4 = 785 mrad Abstand vom Sollwert; 34,9 mrad
verbrauchen 4,4 % davon. Deshalb braucht die UL-PHY keine CFO-Korrektur.

Zu beachten: Das gilt nur, weil die Detektion **differentiell** ist. Der absolute
Phasenfehler über einen NUB (231 Symbole) wäre 8,06 rad — für einen kohärenten Empfänger
inakzeptabel. Ein späterer Wechsel auf kohärente Detektion (Kapitel 18) zieht zwingend eine
CFO-Schätzung nach sich.

Ressourcen: siehe Sammeltabelle §3.9.

### 3.4 `tetra_ul_cb_capture` — Control-Uplink-Burst erfassen

#### 3.4.1 Burst-Geometrie (aus ETSI abgeleitet)

CB, π/4-DQPSK [ETSI Tabelle 9.3], Snmax = 103 Symbole [ETSI Tabelle 9.2]:

| BN | Bits | Feld | Symbole (1-basiert) |
|---|---:|---|---|
| 1–4 | 4 | tail | 1–2 |
| 5–88 | 84 | cb(1..84) | 3–44 |
| 89–118 | 30 | x-Sequenz | 45–59 |
| 119–202 | 84 | cb(85..168) | 60–101 |
| 203–206 | 4 | tail | 102–103 |

Der Sync-Anker ist das **letzte x-Symbol**, also Symbol 59 (x₂₉x₃₀). Daraus:

| Größe | Symbol | Distanz zum Anker | Samples @ 4 sps |
|---|---:|---:|---:|
| CB1-Differenzreferenz | 2 | −57 sym | **−228** |
| CB1[0] (= cb(1..2)) | 3 | −56 sym | −224 |
| CB1[41] (= cb(83..84)) | 44 | −15 sym | −60 |
| CB2-Differenzreferenz | 59 | 0 | **0** |
| CB2[0] (= cb(85..86)) | 60 | +1 sym | +4 |
| CB2[41] (= cb(167..168)) | 101 | +42 sym | **+168** |

Diese Werte entsprechen exakt den V1-Parametern `CB1_PRE_SMP = 228`, `HALF_SYMS = 43`
(1 Referenz + 42 Daten), `POST_WAIT_SMP = 172 ≥ 168`
[CODE rtl/rx/tetra_ul_burst_capture.v:50-52].

Die Differenzreferenz jeder Hälfte ist bewusst das **Symbol unmittelbar davor**: für CB1 das
zweite Tail-Symbol, für CB2 das letzte x-Symbol. Beide sind bekannte, gesendete Symbole; die
π/4-DQPSK-Phase läuft über den ganzen Burst durch [ETSI §5.4 Gl. 5.1], daher ist keine
Phasenreferenz zu rekonstruieren.

#### 3.4.2 Schnittstelle

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `i_in_sys`, `q_in_sys`, `valid_in_sys` | 16/16/1 | in | Post-RRC IQ, 72 kHz |
| `sync_found_sys`, `best_phase_sys` | 1/2 | in | von `tetra_ul_sync_os4` (CB-Instanz) |
| `i_out_sys`, `q_out_sys` | 16 signed | out | phasenrichtige Symbol-Samples, 1/Zyklus |
| `iq_valid_sys` | 1 | out | Strobe |
| `iq_first_sys` | 1 | out | markiert CB1[ref] und CB2[ref] |
| `iq_last_sys` | 1 | out | markiert letztes Sample von CB2 |
| `iq_half_sys` | 1 | out | 0 = CB1, 1 = CB2 |
| `capture_busy_sys` | 1 | out | FSM ≠ IDLE oder Ausgabe aktiv |
| `bursts_captured_sys` | 16 | out | Zähler, wrappt |
| `ul_cb_detect_sys` | 1 | out | 1-Zyklus-Puls am Sync-Anker eines erfassten Control-Uplink-Bursts. **Auslöseereignis der Uplink-Zuweisung** (`06 §3.9.3`); inhaltsunabhängig nach R-00-02 — es wird nicht geprüft, ob der Burst dekodierbar war |
| `ul_cb_tn_sys` | 2 | out | `tn` des Uplink-Slots, 0-basiert (`TS1 (ETSI) = tn=0`), am Anker aus der Zeitbasis gelatcht |
| `ul_cb_ssn_sys` | 1 | out | Unterschlitz des Ankers: 0 = SSN1, 1 = SSN2 [ETSI §9.3.6] |

Alle in `clk_sys`.

**Ableitung von `ul_cb_ssn_sys` — eine Rechnung, eine Stelle.** Der Uplink-Zeitschlitz ist in
zwei Unterschlitze à **127,5 Symboldauern** geteilt [ETSI §9.3.6]. Aus der Ankerposition
folgt: liegt der Symbolindex des Ankers innerhalb des Slots unter 127,5, ist es SSN1, sonst
SSN2. Die Umrechnung Ankerzeitpunkt → `(tn, fn, mn, ssn)` steht in `08_TIMING §3.2`; dieses
Modul latcht das Ergebnis. **Derselbe** Wert speist das Feld `subslot` in `W1[27]` der
UL-Burst-Mailbox (`07 §3.4`) — es gibt keine zweite Berechnung. Ohne `ul_cb_ssn_sys` ist die
Aufschaukelungs-Sperre aus `06 §3.9.3` („Burst kam in einem als offen ausgewiesenen
Unterschlitz an") nicht bildbar, und die Software kann eine MAC-ACCESS nicht ihrer
Reservierung zuordnen (`06 §3.10`: „`ssn` ist Pflicht, nicht optional").

#### 3.4.3 Phasen-Rückrechnung (kritisches Detail)

`sync_found_sys` ist **ein Zyklus nach** dem auslösenden Sample gültig, und der lokale
`phase_cnt_sys` läuft synchron zum Zähler im Sync-Detektor (gleicher Reset, gleiches
`valid_in_sys`). Damit:

```
delta   = (phase_cnt_sys − 1 − best_phase_sys) mod 4      // in V1: phase_cnt + 3 − best_phase
anchor  = wp_sys − 1 − delta                              // modulo Ringtiefe
```

[CODE rtl/rx/tetra_ul_burst_capture.v:125-131]. Die Subtraktion wrappt natürlich in
`RING_ADDR_W` Bits; die Ringtiefe **muss** deshalb eine Zweierpotenz sein.

**V2-Anforderung:** Der Phasenzähler darf nicht dupliziert werden. Der Sync-Detektor
exportiert `phase_cnt_sys` als Ausgang, das Capture-Modul verwendet ihn. Zwei getrennte
Zähler mit „gleichem Reset, gleichem Enable" sind eine stille Kopplung, die bei jeder
Änderung am Reset-Netz bricht.

#### 3.4.4 FSM und Zeitbedarf

`S_IDLE → S_WAIT_POST → S_STREAM_CB1 → S_STREAM_CB2 → S_IDLE`
[CODE rtl/rx/tetra_ul_burst_capture.v:174-203].

- `S_WAIT_POST` wartet `POST_WAIT_SMP = 172` `valid_in`-Samples, damit CB2[41] (+168) im
  Ring steht. Dauer: 172 / 72 kHz = **2,389 ms**.
- `S_STREAM_CB1`/`S_STREAM_CB2` geben je 43 Samples in je 43 aufeinanderfolgenden
  `clk_sys`-Zyklen aus, Adresse `base + idx·4`. Gesamtdauer der Ausgabe: 86 Zyklen + 1 Zyklus
  BRAM-Latenz = **0,87 µs**.
- Metadaten (`iq_valid/_first/_last/_half`) sind um genau 1 Zyklus verzögert registriert,
  passend zur BRAM-Leselatenz [CODE rtl/rx/tetra_ul_burst_capture.v:213-235].

**Nachweis zu R-03-09:** Ältester gelesener Ringindex = `anchor − 228`. Der Anker liegt um die
Phasendifferenz **plus eins** hinter dem Schreibzeiger: `anchor = wp − delta − 1` mit
`delta = (phase_cnt − 1 − best_phase) mod 4 ∈ {0,1,2,3}`
[CODE rtl/rx/tetra_ul_burst_capture.v:125-131]. Zum Startzeitpunkt der Ausgabe ist damit
`wp = anchor + 1 + delta + 172`, Abstand = `401 + delta` Einträge, Ringtiefe 512 → Reserve
`111 − delta`, **Worst Case (`delta = 3`): 108 Einträge**. Während der 87 Zyklen Ausgabe kommt
höchstens 1 neues Sample (Abstand 1389 Zyklen), Reserve bleibt ≥ 107
[ANNAHME: Rechnung aus den Parametern in `rtl/rx/tetra_ul_burst_capture.v:47-52`].

#### 3.4.5 Fehler- und Randfälle

| Fall | Verhalten (normativ) |
|---|---|
| `sync_found_sys` während `capture_busy_sys` | wird ignoriert; kein Abbruch des laufenden Bursts. In V1 implizit, weil `S_IDLE` die einzige Annahmestelle ist. V2: explizit als verworfener Trigger zählen (`sync_dropped_cnt`). |
| Zwei Sync-Ereignisse innerhalb `HOLDOFF` | zweites unterdrückt. |
| Sync-Fehlalarm auf Rauschen | erzeugt einen vollständigen Burst-Durchlauf, der downstream am CRC scheitert. Kosten: ein Decoder-Slot (§3.8). |
| Ring noch nicht gefüllt (kurz nach Reset) | Es werden undefinierte Ringinhalte gelesen. V2: `sync_found_sys` erst freigeben, nachdem ≥ `RING_DEPTH` Samples geschrieben wurden. In V1 nicht implementiert — nach Reset läuft der DL-Träger jedoch mindestens 512 Samples (7,1 ms), bevor eine MS senden kann. |

Ressourcen: siehe Sammeltabelle §3.9.

### 3.5 `tetra_ul_soft_demod` — Soft-Demod mit Amplituden-Normierung

#### 3.5.1 Zweck und Schnittstelle

Konsumiert die 2 × 43 phasenrichtigen Samples des CB und erzeugt 2 × 42 Soft-Dibit-Paare
(168 Soft-Werte pro Burst).

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `i_in_sys`, `q_in_sys` | 16 signed | in | von `tetra_ul_cb_capture` |
| `iq_valid_sys`, `iq_first_sys`, `iq_last_sys`, `iq_half_sys` | 1 | in | Metadaten |
| `soft_bit0_sys` | 8 signed | out | zu **B(2k)** (aus `Re z`) |
| `soft_bit1_sys` | 8 signed | out | zu **B(2k−1)** (aus `Im z`) |
| `soft_valid_sys`, `soft_first_sys`, `soft_last_sys`, `soft_half_sys` | 1 | out | Metadaten |

Der **einzige** Verbraucher dieses Stream-Ports ist der Packer der UL-Burst-Mailbox (`07 §3.4`,
CB-Zweig, `W0.burst_type = 00`, 168 Soft-Werte in 42 Wörtern). In V1 hängt hier der
RTL-SCH/HU-Decoder; der entfällt (§2.2).

Parameter: `IQ_WIDTH = 16`, `SOFT_WIDTH = 8`, `NORM_TGT = 5`.

#### 3.5.2 Pipeline

| Stufe | Inhalt | Register |
|---|---|---|
| S0 | `i_prev/q_prev` latchen, `has_prev`, `pending_first` setzen | ja |
| S1 | 4 Produkte `I·I', Q·Q', Q·I', I·Q'` — DSP48-MREG | ja (synchroner Reset, damit Vivado sie in die DSP-Zelle absorbiert) |
| S2 | `Re z = ii + qq`, `Im z = qi − iq`, Breite 2·IQ_WIDTH+1 = 33 bit | ja |
| S2b | L1-Betrag, Leading-One-Position, Shift-Betrag | ja |
| S3 | arithmetischer Shift + Sättigung auf 8 bit signed | ja |

**Latenz `iq_valid_sys` → `soft_valid_sys` = 4 `clk_sys`-Zyklen.**
Die IST-Doku nennt 3 Stufen [docs/ist/04_ul_rx.md:71] und ist gedriftet — Stufe 2b fehlt dort.

Das erste Sample jeder Hälfte (`iq_first_sys`) ist Differenzreferenz und erzeugt **keinen**
Soft-Wert; `emit = iq_valid ∧ ¬iq_first ∧ has_prev`
[CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:76].

#### 3.5.3 Amplituden-Normierung — Mechanismus und Wirkung

**Problem.** `Re z` und `Im z` sind `|r(k)|·|r(k−1)|·{cos,sin}(Δφ)`, also mit dem **Produkt**
der beiden Sample-Magnituden skaliert — quadratisch im Pegel. Ein fester MSB-Slice (in V1
ursprünglich `re_z[32:25]`, d. h. `>>> 25`) bildet damit den *Pegel* ab, nicht die
*Phase*. Sinkt der Pegel, rutscht der ganze Soft-Wert unter das LSB und wird zu 0 — der
Decoder sieht ausschließlich Erasures und bricht ab. Der Testvektor-Generator dokumentierte
den Effekt unfreiwillig selbst: „demod MSB-slice needs A ≳ 28k for non-erasure soft values"
[CODE scripts/gen_ul_demod_tv.py:44-45]. Das ist ein Abbruch (Cliff), keine graduelle
Degradation.

**Lösung.** Normierung auf eine L1-Magnitudenschätzung, ohne Divider:

```
|z|₁      = |Re z| + |Im z|                                   ; ≥ 0, 34 bit
msb_pos   = Position der höchsten gesetzten Stelle von |z|₁    ; Priority-Encoder
norm_sh   = (msb_pos > NORM_TGT) ? msb_pos − NORM_TGT : 0      ; Small-Signal-Guard
soft_bit0 = sat8( Re z >>> norm_sh )
soft_bit1 = sat8( Im z >>> norm_sh )
```

[CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:183-199, :224-237]. Der Shift ist eine Zweierpotenz,
also nur Verdrahtung; `NORM_TGT = 5` legt die Leading-One von `|z|₁` auf Bit 5, sodass ein
saubereres Symbol (Δφ = ±π/4 / ±3π/4, `|cos| = |sin| = 0,707`) nahe ±2⁵ = ±32 landet
[CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:43-48]. Ergebnis: `soft ≈ 32·{cos,sin}(Δφ)` —
**amplitudenfrei**, genau das Modell des Referenz-Decoders
[CODE scripts/decode_dl.py:496-502].

Der `norm_sh = 0`-Guard bei kleinem `|z|₁` ist wesentlich: ohne ihn würde reines Rauschen
nach links geschoben und als „starker" Soft-Wert präsentiert.

**Wirkung, simuliert** (`tb/tb_ul_demod_sch_hu.v` mit erweitertem
`scripts/gen_ul_demod_tv.py --amplitude/--noise/--seed`, 100 Bursts, xsim)
[SIM 2026-05-30 — Simulation, keine Hardware]:

| Bedingung | Alter fester MSB-Slice | L1-normiert |
|---|---|---|
| rauschfrei, A = 30000…16384 | CRC OK | CRC OK |
| rauschfrei, A < 8192 | **0 / 100** | **100 / 100** |
| konst. SNR (σ = A/3), A = 30k / 16k | 85 / 76 | 77 / 74 |
| konst. SNR (σ = A/3), A = 8k / 4k | **0 / 0** | **74 / 74** |

Der Preis sind ~8 % bei gleichzeitig hoher Amplitude **und** extremem Rauschen — dort
verrauscht die Per-Symbol-Magnitudenschätzung selbst. Eine IIR-Glättung der Magnitude wurde
getestet und wegen Unsigned-Underflow und Nur-Eckfall-Nutzen verworfen [SIM 2026-05-30].

**Wirkung, Luft** [MESS 2026-05-30]: 3/3 PTT saubere Voice, und der gemessene TS2-Anker blieb
bit-identisch bei 22,497 ms. Mehr ist für den CB-Normierer aus der Luftmessung **nicht**
belegt. Insbesondere gehören die gleichzeitig geloggten `soft_mag`-Werte (~6,5 nah, ~7,1 auf
50 m) nicht zu diesem Pfad: `soft_mag` ist der Mittelwert von `|soft|` über die 432
Coded-Bits, die die SW aus der **4-bit-NUB-Mailbox** liest
[CODE sw/tetra_voice_pipe.c:54-69, :226-237] — also aus dem ungenormten NUB-Pfad (§3.6.6),
nicht aus `tetra_ul_soft_demod`. Sie taugen damit nicht als Beleg für Amplitudenunabhängigkeit;
ihre Aussage steht in §3.6.6 (Sättigung). Wichtig für Kapitel 08: die Latenz von Stufe 2b geht
**nicht** in die DL→UL-Stoppuhr, weil diese bei `sync_found` stoppt, also vor dem Demod.

#### 3.5.4 Sättigung

```
SOFT_MAX = +2^(SOFT_WIDTH−1) − 1 = +127
SOFT_MIN = −2^(SOFT_WIDTH−1)     = −128
```

[CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:227-237]. Die Sättigung ist **asymmetrisch**
(−128 erreichbar, +128 nicht). Bei `NORM_TGT = 5` liegt der Arbeitspunkt bei ±32, weit von
der Sättigung — die Asymmetrie ist deshalb praktisch irrelevant, muss aber dokumentiert sein,
weil ein Refactor von `NORM_TGT` sie sofort sichtbar macht.

**V2:** symmetrische Sättigung (`±127`), damit `−soft` (K3) nie überläuft.

**V2-Festlegung zur Rundung (Präzisierung von R-03-06).** Der Normierer behält den
arithmetischen Rechtsshift (`sat8(Re z >>> norm_sh)`), aber mit **Rundung zur nächsten Zahl**
statt Abschneiden zu −∞: `sat8((Re z + (1 << (norm_sh−1))) >>> norm_sh)` für `norm_sh > 0`.
Begründung: `>>>` allein erzeugt einen Bias von einem halben LSB zu negativen Werten, also
einen vorzeichenabhängigen Fehler im Soft-Wert — im NUB-Pfad von V1 nachweisbar an der
polaritätsabhängigen Kennlinie (§3.6.6). Ein solcher Bias zieht einen Soft-Viterbi
systematisch in eine Richtung. Kosten: ein Addierer in Stufe 3.

Ressourcen: siehe Sammeltabelle §3.9. Der LUT-Anteil dieses Moduls steckt überwiegend im
Priority-Encoder und im 33-bit-Barrel-Shifter der Stufen 2b/3.

### 3.6 `tetra_ul_nub_capture` — Sprachkanal-Burst erfassen und demodulieren

#### 3.6.1 Burst-Geometrie (aus ETSI abgeleitet)

NUB, π/4-DQPSK [ETSI Tabelle 9.5], Snmax = 231 Symbole [ETSI Tabelle 9.2]:

| BN | Bits | Feld | Symbole (1-basiert) |
|---|---:|---|---|
| 1–4 | 4 | tail | 1–2 |
| 5–220 | 216 | bkn1(1..216) | 3–110 |
| 221–242 | 22 | NTS1 (bzw. NTS2) | 111–121 |
| 243–458 | 216 | bkn2(1..216) | 122–229 |
| 459–462 | 4 | tail | 230–231 |

> **Der NUB enthält keine Broadcast-Bits.** Das Broadcast-Feld (2 × 15 bit) existiert
> ausschließlich in den Downlink-Bursts [ETSI Tabelle 9.7, 9.9, 9.10 vs. Tabelle 9.5;
> ETSI §9.4.4.2.0: „The normal uplink bursts contains two independent blocks"].

Anker = **letztes NTS1-Symbol** = Symbol 121. Daraus die vollständige Offset-Tabelle:

| Größe | Symbol | Distanz zum Anker | Samples @ 4 sps |
|---|---:|---:|---:|
| BKN1-Differenzreferenz | 2 | −119 sym | **−476** |
| BKN1[0] (= bkn1(1..2)) | 3 | −118 sym | −472 |
| BKN1[107] (= bkn1(215..216)) | 110 | −11 sym | −44 |
| BKN2-Differenzreferenz | 121 | 0 | **0** |
| BKN2[0] (= bkn2(1..2)) | 122 | +1 sym | +4 |
| BKN2[107] (= bkn2(215..216)) | 229 | +108 sym | **+432** |

Diese Werte sind normativ und entsprechen den V1-Parametern
`BKN1_PRE_SMP = 476`, `BKN2_OFFSET_SMP = 0`, `POST_WAIT_SMP = 480 ≥ 432`
[CODE rtl/rx/tetra_ul_nub_capture.v:70-72].

#### 3.6.2 Der V1-Offset-Fehler — warum er hier so ausführlich steht

V1 hatte ursprünglich `BKN1_PRE_SMP = 504` und `BKN2_OFFSET_SMP = 32`. Diese Werte stammen
aus einem NUB-Modell mit 255 Symbolen inklusive BB1 (7 sym) und BB2 (8 sym) zwischen den
Blöcken und der Trainingsfolge — das ist das **DL-NDB-Layout**, nicht der NUB.

Wirkung: Jede Symboladresse eines Blocks leitet sich aus **derselben Basis** ab —
`bkn1_base = anchor − BKN1_PRE_SMP`, `bkn2_base = anchor + BKN2_OFFSET_SMP`
[CODE rtl/rx/tetra_ul_nub_capture.v:266-269], danach `rd_addr = base + m·SPS`
[CODE rtl/rx/tetra_ul_nub_capture.v:298, :311-313, :353-355, :366, :374-376, :398-400]. Ein
Basis-Offset verschiebt deshalb **alle** 109 Lesungen eines Blocks, nicht nur die Ränder:

- BKN1 wurde 504 − 476 = 28 Samples = **7 Symbole zu früh** gelesen: die
  BKN1-Differenzreferenz lag auf Burst-Symbol −5, also vor dem Burst; Soft-Index `j` trug den
  Inhalt von On-Air-Index `j − 14`, und die letzten 14 Bit von bkn1 wurden nie gelesen.
- BKN2 wurde 32 Samples = **8 Symbole zu spät** gelesen: Soft-Index `j` trug den Inhalt von
  `j + 16`, die ersten 16 Bit von bkn2 wurden nie gelesen.
- Ergebnis: **vollständige Index-Verschiebung beider Blöcke um 14 bzw. 16 Bit**, nicht
  16 korrupte Randbits. Genau das passt zum gemessenen Symptom: 16 von 432 falschen Bits
  wären 3,7 % Roh-BER, die die FEC weitgehend gefangen hätte
  [ANNAHME: Rechnung aus der Adressbildung, keine Messung].

Zusammen mit einem gleichzeitig vorhandenen Bit-Order-Fehler (§3.6.4) ergab das das Symptom
**98 % BFI bei MER 0 % und Audio-Müll**. Nach der Korrektur beider Punkte in einem einzigen
Rebuild: Audio durchgängig hörbar, BFI 4–10 % [MESS 2026-05-17].

Das ist die konkrete Begründung von R-03-05: **UL-Burst-Offsets nie aus einem DL-Layout
ableiten.** Der Nachweis in §3.6.1 ist deshalb bis auf die Symbolnummer ausgeschrieben.

#### 3.6.3 Schnittstelle (V2)

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `i_in_sys`, `q_in_sys`, `valid_in_sys` | 16/16/1 | in | Post-RRC IQ, 72 kHz |
| `sync_found_sys`, `best_phase_sys`, `phase_cnt_sys` | 1/2/2 | in | von `tetra_ul_sync_os4` (NUB-Instanz) |
| `mb_index_sys` | 7 | in | Wort-Port: Wortselektor 0..107 — **der einzige Ausgang** der Soft-Werte, siehe unten |
| `mb_rdata_sys` | 32 | out | Wort-Port: 4 Softs à 8 bit |
| `mb_valid_sys` | 1 | out | Burst liegt vor |
| `mb_ack_sys` | 1 | in | 1-Zyklus-Puls: `mb_valid` löschen, nächsten Burst freigeben |
| `bursts_captured_sys` | 16 | out | Zähler, wrappt |

Parameter: `IQ_WIDTH = 16`, `RING_DEPTH = 1024`, `SPS = 4`, `BKN_SYMS = 108`,
`SOFT_WIDTH = 8`, `NORM_TGT = 5`.

**Änderung gegenüber V1 und Begründung.** V1 gibt einen 1728-bit-Parallelvektor
`coded_softs_sys` aus (432 × 4 bit), den zwei Verbraucher jeweils vollständig latchen. Der
Vektor existiert damit dreifach in Flipflops:

| V1-Instanz | LUT | FF | RAMB18 | DSP |
|---|---:|---:|---:|---:|
| `u_ul_nub_capture` | 185 | 1840 | 2 | 4 |
| `u_nub_to_schf` | 484 | 1749 | 0 | 0 |
| `u_voice_nub_read_mailbox` | 482 | 1729 | 0 | 0 |
| **Summe** | **1151** | **5318** | **2** | **4** |

[BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt:151,171,201`]

V2 legt die Softs statt dessen in einen **Ping-Pong-BRAM** (2 Bänke × 216 Wörter × 16 bit =
6912 bit, passt in 1 RAMB18) und bietet daraus **einen** Ausgang an: den wortadressierten
Port zur UL-Burst-Mailbox (`07 §3.4`). Einen Stream-Port in einen RTL-Decoder gibt es nicht
mehr, weil es den RTL-Decoder nicht mehr gibt (§2.2). Erwartung: ~600 LUT / ~450 FF / 3 RAMB18 / 4 DSP, d. h. ca. −550 LUT und −4870 FF
gegen +1 RAMB18 [ANNAHME: Extrapolation aus den V1-Reportzahlen und dem
Aufwand des Normierers in §3.9 — nicht gebaut]. Der Ping-Pong entkoppelt außerdem die
SW-Leselatenz vom nächsten Burst. V1 hat an dieser Stelle **keinen** Backpressure: die Mailbox
packt bei jedem `coded_valid_sys` bedingungslos neu und gibt der Capture ausdrücklich Priorität
über den Ack [CODE rtl/lmac/tetra_voice_nub_read_mailbox.v:70-83], und die Capture-FSM geht von
`S_DONE` bedingungslos nach `S_IDLE` [CODE rtl/rx/tetra_ul_nub_capture.v:407-411]. Ein noch
nicht gelesener Burst wird also vom nächsten **überschrieben** — verloren geht der alte, nicht
der neue, und zwar ohne Zähler. Genau dieser stille Verlust ist die Begründung für Ping-Pong
plus `mb_overrun_cnt`.

#### 3.6.4 Bit-Order und Soft-Ablage (normativ)

**Normative Festlegung V2:**

> Soft-Index `j ∈ [0, 431]` entspricht dem **On-Air-Type-5-Bit** `j`, mit
> `j = 0` = bkn1(1) = erstes gesendetes Bit des Bursts, `j = 431` = bkn2(216) = letztes.
> Innerhalb eines Dibits `k` gilt `j = 2k` → B(2k−1) → `soft_bit1`, `j = 2k+1` → B(2k) →
> `soft_bit0`. Aufsteigender Speicherindex = aufsteigende On-Air-Zeit. **Keine Umkehr.**

Wort-Port-Layout (`SOFT_WIDTH = 8`): Wort `w ∈ [0, 107]`,
`mb_rdata[8·n +: 8] = soft[4·w + n]` für `n = 0..3` — LSB-first innerhalb des Worts,
aufsteigender On-Air-Index. 108 Wörter pro Burst.

**Was V1 macht (zum Vergleich, weil es die Fehlerquelle war).** V1 schiebt MSB-first: das
zuerst committete Dibit landet am **oberen** Ende des Halbwort-Feldes, BKN1 im oberen Halbwort:

```
coded_softs_sys[431]  = erstes Soft von BKN1  (= On-Air-Bit 0)
coded_softs_sys[216]  = letztes Soft von BKN1
coded_softs_sys[215]  = erstes Soft von BKN2
coded_softs_sys[0]    = letztes Soft von BKN2 (= On-Air-Bit 431)
```

also `On-Air-Bit j = coded_softs[431 − j]` — eine **vollständige Umkehr**. Dieselbe Umkehr
steht dreifach im Code: im Modulkommentar
[CODE rtl/rx/tetra_ul_nub_capture.v:50-54], im Adapter
[CODE rtl/rx/tetra_ul_nub_to_schf.v:62-70] und in der SW
[CODE sw/tetra_voice_pipe.c:46-50, :65-66 `softs_432_out[431 - coded_idx] = s`].
Sie wurde zweimal übersehen: einmal 2026-05-17 (SW-Seite fehlte → BS-Viterbi konnte nicht
synchronisieren), einmal 2026-06-12 (SCH/F-Pfad fehlte → 0 crc_ok auf dem Board, obwohl
Decoder und FSM in Simulation korrekt waren)
[CODE rtl/rx/tetra_ul_nub_to_schf.v:62-67]. Genau diese Umkehr entfällt in V2.

#### 3.6.5 Ablauf und Zeitbedarf

FSM (V1, 9 Zustände):
`S_IDLE → S_WAIT_POST → S_READ_BKN1_PRE → S_READ_BKN1_REF → S_READ_BKN1_RUN →
 S_READ_BKN2_PRE → S_READ_BKN2_REF → S_READ_BKN2_RUN → S_DONE`
[CODE rtl/rx/tetra_ul_nub_capture.v:132-140].

- `S_WAIT_POST`: 480 `valid_in`-Samples = **6,667 ms**, damit BKN2[107] (+432) im Ring steht.
- Pro Halbblock werden 109 Samples gelesen (1 Referenz + 108 Daten). Die Adressfolge ist
  `base + m·4`, `m = 0..108`.
- Die Demod-Pipeline ist 3-stufig ab BRAM-Ausgang (`mul_*_r` → `i_prod_r` → Soft-Register)
  [CODE rtl/rx/tetra_ul_nub_capture.v:185-203]. Deshalb läuft `sym_idx` von 0 bis
  `BKN_SYMS + 1 = 109`: die Zyklen 0..1 füllen die Pipeline, die Zyklen 2..109 committen
  die 108 Dibits [CODE rtl/rx/tetra_ul_nub_capture.v:329-359].
- Gesamtdauer der Ausgabe: 2 × (109 + ~3) ≈ **226 `clk_sys`-Zyklen = 2,26 µs**.

**Nachweis zu R-03-09:** Ältester gelesener Index = `anchor − 476`. Wie beim CB gilt
`anchor = wp − delta − 1` mit `delta ∈ {0,1,2,3}`
[CODE rtl/rx/tetra_ul_nub_capture.v:153-160]. Bei Ausgabestart ist damit
`wp = anchor + 1 + delta + 480`, Abstand = `957 + delta` Einträge, Ringtiefe 1024 → Reserve
`67 − delta`, **Worst Case (`delta = 3`): 64 Einträge**. Während der 226 Ausgabezyklen kommt
höchstens 1 neues Sample (Abstand 1389 Zyklen), Reserve bleibt ≥ 63. Der V1-Modulkommentar
nennt 68 und lässt sowohl das `+1` als auch `delta` weg
[CODE rtl/rx/tetra_ul_nub_capture.v:30-33] [ANNAHME: Rechnung aus den Parametern].

**V2-Anforderung:** Eine Worst-Case-Reserve von 64 Samples (6,25 %) ist knapp für ein Modul,
dessen Offsets schon einmal falsch waren. `RING_DEPTH = 2048` kostet 2 weitere RAMB18 und
bringt 1088 Samples Reserve. Entscheidung siehe §6, O-03-2.

#### 3.6.6 Soft-Quantisierung im NUB-Pfad — V1-Zustand und V2-Anforderung

V1 verwendet hier **keine** Amplituden-Normierung, sondern einen festen Shift:

```verilog
// rtl/rx/tetra_ul_nub_capture.v:77-78, :213-214
parameter SOFT_W = 4, SOFT_SHIFT = 24;
wire i_shifted_w = (-i_prod_r) >>> SOFT_SHIFT;   // Sättigung: +7 / −8 (asymmetrisch)
```

Das ist genau der Mechanismus, der im CB-Pfad als Amplituden-Abbruch identifiziert und
2026-05-30 ersetzt wurde (§3.5.3) — im NUB-Pfad ist er noch drin. Rechnerische Kennlinie für
`|r(k)| = |r(k−1)| = A` und `|cos Δφ| = 0,707`. Weil der Pfad **vor** dem arithmetischen
Rechtsshift negiert und `>>>` zu −∞ rundet, ist die Kennlinie polaritätsabhängig und muss für
beide Vorzeichen angegeben werden (Erinnerung: im V1-NUB-Pfad gilt positiver Soft = Bit '1'):

| A (LSB) | `|Re z|` | `|Re z| / 2²⁴` | Soft bei `Re z > 0` (Bit '0') | Soft bei `Re z < 0` (Bit '1') |
|---:|---:|---:|---:|---:|
| 4 000 | 1,13·10⁷ | 0,67 | **−1** | **0 (Erasure)** |
| 4 900 | 1,70·10⁷ | 1,01 | −2 | +1 |
| 8 000 | 4,52·10⁷ | 2,70 | −3 | +2 |
| 12 900 | 1,18·10⁸ | 7,01 | −8 (Sättigung) | +7 (Sättigung) |
| 30 000 | 6,36·10⁸ | 37,9 | −8 (Sättigung) | +7 (Sättigung) |

[ANNAHME: Rechnung aus `SOFT_SHIFT = 24`, `SOFT_W = 4` und dem Floor-Verhalten von `>>>`,
keine Messung], Code-Beleg [CODE rtl/rx/tetra_ul_nub_capture.v:213-214, :219-233]

Der graduierende Bereich ist also nur A ≈ 4 900 … 12 900 — ein Faktor 2,6, darüber
vollständige Sättigung. Darunter tritt Erasure **nur für eine Polarität** ein, die andere
liefert −1; über den ganzen Bereich bleibt damit ein systematischer Bias von einem halben LSB
zugunsten von Bit '0'. Aus demselben Grund ist die Sättigung asymmetrisch: `|soft|` reicht
0..8, weil −8 erreichbar ist, +8 nicht.

Die Live-Messung passt dazu: `soft_mag avg 7,24` [MESS 2026-05-25] — das ist der Mittelwert
von `|soft|` über alle 432 Coded-Bits eines Bursts
[CODE sw/tetra_voice_pipe.c:226-237]. Bei einem Wertebereich 0..8 heißt ein Mittelwert von
7,24, dass praktisch **alle** Soft-Werte gesättigt sind — der Pfad arbeitet effektiv als
Hard-Decision, und genau deshalb ist der gemessene Gewinn von Soft gegenüber Hard klein
(„rettet ~1 Frame", soft-BFI durchgehend ≤ hard-BFI) [MESS 2026-05-30]. Ein Maximum von
`soft_mag` gibt die Instrumentierung **nicht** aus; das `max=`-Feld derselben Logzeile ist die
maximale Zahl abweichender Bits pro Burst [CODE sw/tetra_voice_pipe.c:214, :239-245] und darf
nicht als Soft-Maximum gelesen werden.

> **R-03-06 präzisiert:** V2 verwendet in `tetra_ul_nub_capture` **denselben** Normierer wie
> in `tetra_ul_soft_demod` (L1-Magnitude → Leading-One → Shift auf `NORM_TGT`, Sättigung auf
> `SOFT_WIDTH = 8`). Der Normierer wird als eigenes Submodul `tetra_soft_norm` geführt und
> von beiden Pfaden instanziiert — nicht zweimal geschrieben.

Erwarteter Effekt: Der NUB-Soft trägt wieder Magnitudeninformation über den ganzen
Pegelbereich, statt nur an einem Punkt zu graduieren. Die Größe des Gewinns ist **nicht**
vorhergesagt; die Abnahme erfolgt als A/B im selben Capture (§5.5).

#### 3.6.7 Fehler- und Randfälle

| Fall | Verhalten (normativ) |
|---|---|
| Kein Sync | keine Ausgabe, `mb_valid = 0`, kein Zyklus im Downstream. |
| Sync auf Rauschen / auf einem Signalisierungs-NUB | vollständiger Durchlauf, downstream CRC-Fail. Beabsichtigt: der Pfad filtert nicht selbst (§3.8). |
| SW quittiert nicht | V1: der noch nicht gelesene Burst wird vom nächsten **überschrieben** — Datenverlust ohne Zähler, kein Backpressure [CODE rtl/lmac/tetra_voice_nub_read_mailbox.v:70-83, rtl/rx/tetra_ul_nub_capture.v:407-411]. V2: Ping-Pong puffert genau einen weiteren Burst; ist auch die zweite Bank ungelesen, wird der **neue** Burst verworfen und `mb_overrun_cnt` inkrementiert — der ungelesene bleibt gültig. |
| `sync_found` während laufender Erfassung | verworfen, Zähler `sync_dropped_cnt`. |
| NTS2 statt NTS1 gesendet (zwei logische Kanäle) | kein Sync, Burst geht verloren. Bewusste Einschränkung, siehe §6 O-03-6. |

### 3.7 Übergabe an Kanaldecodierung und Software

Die UL-PHY endet an **einer** Schnittstelle: der UL-Burst-Mailbox. Sie ist hier nur als
Vertrag benannt; Format in Kapitel 07, Decodierung in 05, Verbraucher in 06/09/11/12.

| Ziel | Format | Konvention |
|---|---|---|
| UL-Burst-Mailbox → SW (Kap. 07 §3.4; Decode in 05) | `W0` Kopf (`burst_type` **normativ nach `07 §3.4`**: `00` = Control Uplink Burst, `01` = Normal Uplink Burst, `10`/`11` reserviert — der Wert benennt den Erfassungszweig, nicht den logischen Kanal), `W1` TDMA-Zeitstempel einschließlich `subslot`, `W2` Erfassungs-Diagnose, ab `W3` die Soft-Werte: **168** beim CB (42 Wörter), **432** beim NUB (108 Wörter), je 4 Softs à 8 bit signed | K1; `DATA[8·n +: 8] = soft[4·d + n]`, aufsteigender On-Air-Index (§3.6.4). Die Negation nach K3 erfolgt in der SW-Adaption vor dem TCH/S-Viterbi |

Die V1-Stream-Ports in die RTL-Decoder (`soft_bit0/1`, `soft_first/_last/_half`) entfallen
mit den Decodern selbst (§2.2). Der Wort-Port des Soft-BRAM ist damit der **einzige** Ausgang
des NUB-Zweigs (§3.6.3).

**SW-Leselast.** Die gemessene NUB-Rate bei aktivem PTT liegt bei ~19 Bursts/s (echte
TCH/S-Rate 16–18/s) [MESS 2026-05-17]. Bei 108 Wörtern pro Burst sind das ~2 050
Registerlesevorgänge pro Sekunde. V1 liest 54 Wörter (`SOFT_W = 4`) [CODE
sw/tetra_voice_pipe.c:51-52]. Wenn die Leselast in Kapitel 13 als Problem gemessen wird,
ist `SOFT_WIDTH = 4` am Wort-Port durch einen sättigenden Shift zulässig — **nur dort**,
nicht im internen Soft-Pfad, und ohne Vorzeichenwechsel.

**Inhaltsunabhängigkeit des Erfassungspfads.** Jeder erfasste NUB wird unverändert an die
Mailbox gegeben, und zwar mit `burst_type = 01` — unabhängig davon, was er trägt. Die
Mailbox führt deshalb **kein** Feld für den logischen Kanal: ein solches Feld wäre eine
Inhaltsaussage der Hardware und verstieße gegen `00` R-00-02.
Ob der Burst Sprache oder ein SCH/F-Fragment trägt, entscheidet **die Software**;
deshalb braucht der NUB-Pfad in der PL **keine** TN-Tabelle und keine Interaktion mit dem
Sprachpfad. Das ist der Grund, warum lange UL-SDS und UL-Sprache denselben Erfassungspfad
teilen können.

V1 erreicht dasselbe anders: dort speist die Capture bedingungslos in den **RTL**-SCH/F-Pfad,
und der Decoder samt Akkumulator akzeptiert ausschließlich ein MAC-FRAG/MAC-END mit `crc_ok`
— Sprachbursts fallen dort durch [CODE rtl/rx/tetra_ul_nub_to_schf.v:10-14, V1-Beleg]. Diese
„Selbstfilterung über CRC" ist in V2 **nicht** die Regel: mit dem Decoder in Software kostet
sie je Sprachburst einen vollen SCH/F-Decodierlauf (53,8 µs Host, `13 §3.3`). V2 verzweigt
stattdessen über den Reservierungszustand `resv_active[tn]` in der Software
(`13 §3.3`, dort O-13-4 als riskantester Punkt geführt). Der **PL**-Pfad bleibt in beiden
Fällen inhaltsunabhängig — nur der Filter wandert mit dem Decoder.

### 3.8 Verhalten bei fehlender oder falscher Synchronisation

**Kein Sync.** Beide Sync-Instanzen laufen dauerhaft; ohne Trefferschwelle passiert nichts.
`corr_peak_sys` steigt weiter als Sticky-Maximum und ist das Diagnosemittel: er zeigt, wie
weit die Korrelation von der Schwelle entfernt ist. Ohne `sync_found` gibt es keine
Ringauslesung, keinen Soft-Wert, keinen Decoder-Zyklus, keinen AXI-Verkehr.

**Fehlalarm.** Ein Fehlalarm kostet einen vollständigen Erfassungs- und Decodier-Durchlauf.
Obergrenze für die Kosten:

- CB-Pfad: `S_WAIT_POST` 2,39 ms + Ausgabe 0,87 µs, danach ~2 000 Zyklen SCH/HU-Decode
  [docs/ist/04_ul_rx.md:156, gegen `rtl/rx/tetra_ul_sch_hu_decoder.v` FSM verifiziert].
  Bei 100 MHz ≈ 20 µs. Der Burst-Abstand ist ≥ 7 ms, also reichlich Reserve.
- NUB-Pfad: `S_WAIT_POST` 6,67 ms + Ausgabe 2,26 µs + SCH/F-Decode.

Die eigentliche Gefahr eines Fehlalarms ist **nicht** die Zeit, sondern dass Müll in den
Sprach-Decoder gelangt und dort als BFI-Frame erscheint. Genau das ist der Mechanismus hinter
der Schwellwert-Messreihe in §4: bei zu niedriger NUB-Schwelle kommen mehr als die real
möglichen 16–18 Bursts/s durch, und der Überschuss erzeugt BFI [MESS 2026-05-17].

**Systematische Fehlkorrelation.** Die Wahrscheinlichkeit, dass 30 zufällige Dibits die
x-Sequenz mit ≥ 13 von 15 Treffern nachbilden, ist
`Σ_{m=13..15} C(15,m)·(1/4)^m·(3/4)^(15−m) ≈ 9,2·10⁻⁷`; über die 168 Samples nach einem
echten Anker aufsummiert ≈ 1,5·10⁻⁴ pro Burst [ANNAHME: Rechnung unter der Annahme
unabhängiger Dibits — die Dibits sind wegen RRC-Korrelation und Restphasendrift **nicht**
unabhängig, der Wert ist eine Untergrenze]. Für `SYNC_LEN_SYM = 11` mit `thresh = 11` ist der
entsprechende Wert `4⁻¹¹ ≈ 2,4·10⁻⁷` pro Sample. Das deckt sich mit der Messung
0 Bursts/s im Idle bei `thresh = 11` [MESS 2026-05-16].

**Holdoff.** `HOLDOFF` unterdrückt Mehrfachauslösung in unmittelbarer Umgebung des
Korrelationsmaximums. V1: 50 Samples (0,69 ms) für den CB, 250 Samples (3,47 ms) für den NUB
[CODE rtl/rx/tetra_ul_sync_detect_os4.v:44, rtl/rx/tetra_rx_chain.v:436]. Der V1-Kommentar
„~1 voice frame at 72 kHz" ist falsch: ein TETRA-Frame sind 56,67 ms = 4 080 Samples; 250
Samples sind 62,5 Symbole.

**V2-Festlegung:** `HOLDOFF` = `POST_WAIT_SMP`, also die Anzahl Samples ab Anker, bis das
letzte **benötigte** Sample des Bursts im Ring steht: **172 für den CB, 480 für den NUB**
[CODE rtl/rx/tetra_ul_burst_capture.v:52, rtl/rx/tetra_ul_nub_capture.v:72]. Einheit im
Parameterkommentar als „samples @ 4 sps" benennen.

Das ist **nicht** dieselbe Größe wie die Distanz Anker → physikalisches Burstende: die beträgt
nach §3.4.1 44 sym = **176** Samples (CB, Anker Symbol 59 → Burstende Symbol 103) und nach
§3.6.1 110 sym = **440** Samples (NUB, Symbol 121 → 231). Beim NUB deckt 480 > 440 den Burst
also vollständig ab; beim CB bleiben die letzten 4 Samples (das zweite Tail-Symbol)
unabgedeckt. Ein Trigger in diesem Restfenster träfe nur Tail-Symbole und würde downstream am
CRC scheitern; wer Lückenfreiheit fordert, setzt `HOLDOFF = 176`. In beiden Varianten wird der
nächste mögliche echte Burst (≥ 7 ms später) nicht unterdrückt.

### 3.9 Ressourcen-Erwartung (Sammeltabelle)

Aus dem hierarchischen Post-Route-Utilization-Report, xc7z020clg400-1, Vivado 2022.2
[BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt`]:

| V1-Instanz | Modul | LUT | FF | RAMB18 | DSP48 | Zeile |
|---|---|---:|---:|---:|---:|---:|
| `u_ul_sync_detect` | `tetra_ul_sync_detect_os4` (x-seq, 15 sym) | 183 | 265 | 0 | 4 | :173 |
| `u_ul_sync_nub` | `tetra_ul_sync_detect_os4` (NTS1, 11 sym) | 145 | 229 | 0 | 4 | :174 |
| `u_ul_burst_capture` | `tetra_ul_burst_capture` | 49 | 57 | 2 | 0 | :168 |
| `u_ul_demod` | `tetra_ul_pi4dqpsk_demod` | 453 | 191 | 0 | 4 | :169 |
| `u_ul_nub_capture` | `tetra_ul_nub_capture` | 185 | 1840 | 2 | 4 | :171 |
| `u_nub_to_schf` | `tetra_ul_nub_to_schf` | 484 | 1749 | 0 | 0 | :151 |
| `u_voice_nub_read_mailbox` | `tetra_voice_nub_read_mailbox` | 482 | 1729 | 0 | 0 | :201 |
| **UL-RX-PHY V1 gesamt** | | **1981** | **6060** | **4** | **16** | |

V2-Erwartung nach §2.3 (Adapter entfällt), §3.6.3 (Soft-BRAM statt Parallel-Latch) und
O-03-3 (gemeinsame Dibit-Quelle): **~1350 LUT / ~1150 FF / 5 RAMB18 / 12 DSP48** — Aufteilung:
Sync-Block ~250/~400/0/4, `cb_capture` 49/57/2/0, `soft_demod` 453/191/0/4,
`nub_capture` inkl. Normierer, Soft-BRAM und Wort-Port ~600/~450/3/4
[ANNAHME: Extrapolation aus den Reportzahlen dieser Tabelle, nicht gebaut].
Der Gewinn liegt fast vollständig in den FF: die drei Kopien des 1728-bit-Soft-Vektors
(5318 FF, §3.6.3) verschwinden.

---

## 4. Empirische Werte

Die Werte hier sind gemessen oder aus dem Code gelesen — die Herkunft steht je Zeile in der
Spalte „Herkunft". Kein Wert in dieser Tabelle ist hergeleitet. Wer einen `[MESS]`-Wert
ändert, muss die zugehörige Messreihe wiederholen.

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| **NUB-Sync-Schwelle** (`REG_RX_SYNC_CFG_UL.thresh_nub`, `07 §3.1.4`; V1-Name `REG_VOICE_NUB_SYNC_THRESH`; NTS1, 11 sym) | **11** | [MESS 2026-05-17] Survey; SW-Default [CODE sw/tetra_attach_daemon.c:1044], Boot-Config [CODE board_autostart/tetra_cell.conf:21] | **10:** 280 Bursts / 17 BFI-Fails / Run-BFI 6,1 % in 10 s PTT — mehr Detects (~28/s) als real möglich (16–18/s), Müll im TCH/S-Decoder. **11:** 192 / 9 / **4,7 %** (≈ 22 % relative Verbesserung). **12: Detektor tot** — `corr_max ≤ 11`, Schwelle konstruktiv unerreichbar (§3.3.3); MS interpretiert „PTT abgewiesen". |
| NUB-Sync-Schwelle, Idle-Fehlalarme | 8 → ~48/s; 9 → ~9/s; 10 → 0/s; 11 → 0/s | [MESS 2026-05-16] | Bei < 10 ist `nub_rx_cnt` als Heartbeat unbrauchbar; der Call-FSM-Watchdog baut darauf auf. |
| RTL-Default NUB-Schwelle | 8 | [CODE rtl/infra/tetra_axi_lite_regs.v:1557], CDC-Reset-Wert [CODE rtl/tetra_zynq_top.v:3929] | Weicht vom Messoptimum ab. **V2: RTL-Default = 11**, damit ein Boot ohne SW-Init nicht im Fehlalarm-Regime läuft. |
| **CB-Sync-Schwelle** (`REG_RX_SYNC_CFG_UL.thresh_cb`, `07 §3.1.4`; x-Sequenz, 15 sym) | **15** | [MESS 2026-05-22] Air-Tabelle | 11 → 805 Syncs / 12 CRC = 1,5 % (Rausch-Flut). 13 → 110 / 28 = 25,5 %. 14 → 88 / 32 = 36,4 %. **15 → 27 / 25 = 92,6 %** und 34 / 32 = **94,1 %** (Validierungslauf). 15 bedeutet exakte 15/15-Übereinstimmung; es gibt kein Tuning nach oben. |
| Ist-Zustand CB-Schwelle in V1 | 13, **geteilt mit DL** | [CODE rtl/tetra_zynq_top.v:567 → rtl/rx/tetra_rx_chain.v:350 und :375], Default 0x0D [CODE rtl/infra/tetra_axi_lite_regs.v:1418] | Das gemessene Optimum 15 ist nicht einstellbar, ohne die DL-Sync-Schwelle mitzuverschieben. **V2: getrennte Register (R-03-04), UL-CB-Default 15.** |
| CIC-Ausgangsverstärkung | `CIC_GAIN_SHF = 4` (×16) | [MESS 2026-05-22], [CODE rtl/rx/tetra_rx_frontend.v:135] | ×64 → UL-Bursts bei AGC-Übergängen gesättigt, CRC 16,3 %. ×8 → Pegel zu niedrig, Detektor „abgewiesen". Gehört zu Kapitel 02; die UL-PHY macht sich durch R-03-06 pegelunabhängig. |
| `NORM_TGT` (Soft-Normierung) | 5 | [SIM 2026-05-30] Amplituden-Sweep, bestätigt in [MESS 2026-05-30] Luft (3/3 PTT); [CODE rtl/rx/tetra_ul_pi4dqpsk_demod.v:48] | Zu klein → Softs unterhalb der Sättigungsregion von `to_vit_soft`, Auflösung verschenkt. Zu groß → saubere Symbole sättigen, Magnitudeninformation weg. |
| `SOFT_WIDTH` UL-Soft (CB) | 8 signed | [CODE rtl/rx/tetra_rx_chain.v:385] | Muss zur `SOFT_IN_WIDTH` beider Decoder passen [CODE rtl/rx/tetra_ul_sch_hu_decoder.v:53, rtl/rx/tetra_ul_sch_f_decoder.v:33]. |
| NUB-Roh-BER (nach Offset-Fix, Soft-Pfad) | avg **1,4 %**, worst 9,5 % pro Burst | [MESS 2026-05-25], per-Burst `type5 XOR re-encoded` | Referenz ETSI: BER 0,01 % (STATIC), 0,4 % (TU50) bei −85 dBm [ETSI Tabelle 6.28]. Wir liegen deutlich darüber → §6 O-03-1. |
| NUB-BFI nach FEC | Soft **0 %** (2/840), Hard 1 % (11/840) | [MESS 2026-05-25] | Vor dem Offset-Fix: 98 % [MESS 2026-05-17]. |
| Tagesvariabilität Roh-BER | 1,4–3,5 % | [MESS 2026-05-18] | RF-Bedingung und Antennenposition wechseln zwischen Sessions. **Deshalb: Verbesserungen immer als A/B im selben Capture bewerten, nie gegen einen Erinnerungswert.** |
| Gold: UL-Burst-Verteilung eines echten Netzes | 192 UL-Bursts: 27 SCH/HU CRC-OK, 161 CRC-FAIL (überwiegend TCH/S), 4 verworfen (schwache x-Korrelation) | [GOLD docs/reference_decode/burst_inventory.md, `ul_events.jsonl`] | Bestätigt §3.7: die Mehrheit der erfassten UL-Bursts ist für den Signalisierungspfad Müll. Selbstfilterung über CRC ist nicht optional, sondern der Normalfall. |
| Gold: normierte x-Korrelation nach CRC-Ausgang | CRC-OK: Median **0,912** (min 0,526, max 0,938); CRC-FAIL: Median 0,651 (max 0,883); verworfen: Median 0,486 | [GOLD `docs/reference_decode/ul_events.jsonl`] | Zeigt, dass eine **hohe** Korrelationsschwelle die Decodier-Erfolgsrate treibt — unabhängig belegte Bestätigung der Messreihe „Schwelle 15". Der Gold-Decoder normiert auf 0..1, die RTL zählt Treffer 0..15; die Skalen sind nicht direkt vergleichbar. |
| Lokale Zelle, gleiche Auswertung | 29 UL-Bursts: 10 CRC-OK (Median 0,927), 19 CRC-FAIL (Median 0,680), 0 verworfen | [MESS 2026-05-25 (Dateistand), `docs/local_cell_decode/ul_events.jsonl`] | Gleiche Trennung wie im Gold — die Erfassungs-Geometrie unserer Kette stimmt. |
| Post-Route-Ressourcen der UL-RX-Module | siehe §3.9 | [BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt`] | Gesamtdesign desselben Builds: 38 578 LUT / 52 251 FF / 11 RAMB18 + 10 RAMB36 / 38 DSP [BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt:25`]. Aktuellerer Build: 37 567 Slice-LUTs, 15,5 Block-RAM-Tiles, 38 DSP [BUILD 2026-07-12, `build/reports/impl_utilization.rpt:35,106,121`], dazu WNS **+0,006 ns**, WHS +0,049 ns, 0 verletzte Endpunkte [BUILD 2026-07-12, `build/reports/impl_timing.rpt:139`]. Die Timing-Reserve ist minimal — neue UL-Logik nur mit Pipeline-Registern. |

---

## 5. Verifikation

### 5.1 Unit-Simulation

| ID | Prüfung | Stimulus | Abnahmekriterium |
|---|---|---|---|
| **V-03-1** | Phasenunabhängigkeit des Sync | synthetischer π/4-DQPSK-Burst mit x-Sequenz, Sub-Symbol-Offset über alle 4 Phasen gesweept | `sync_found` bei **jedem** Offset; `corr_peak = 15/15` auf dem Burst mit sauberer x-Sequenz [CODE tb/tb_ul_sync_detect_os4.v:9-11] |
| **V-03-2** | CB-Geometrie + Demod + SCH/HU | vollständiger 103-Symbol-CB, ZOH auf 4 sps, 400 Samples Vorlauf / 1 200 Nachlauf pro Burst, aus `scripts/gen_ul_demod_tv.py` | pro Burst `info_valid`, `crc_ok = 1`, 92 Info-Bits identisch zum Erwartungsdatensatz [CODE tb/tb_ul_full_chain.v:13] |
| **V-03-3** | Soft-Demod-Kennlinie über Amplitude | `gen_ul_demod_tv.py --amplitude/--noise/--seed`, `N_BURSTS`/`NORM_TGT` per `-P`-Override | CRC-OK-Quote über A = 500…30 000 **flach**; kein Abbruch. Referenzwerte in §3.5.3 |
| **V-03-4** | NUB-Offsets und Bit-Order | NUB-Soft-Vektor mit bekannter Type-5-Belegung | 268 Info-Bits + `crc_ok` gegen Erwartung; deckt explizit den Parallel→Stream-Übergang und die Vorzeichenbehandlung ab [CODE tb/tb_ul_nub_schf_chain.v:5-7] |
| **V-03-5** | Vorzeichenkonvention K1 | Einzel-Dibit-Vektoren für alle vier Δφ aus [ETSI Tabelle 5.1] | `sign(soft_bit1)`/`sign(soft_bit0)` entsprechen B(2k−1)/B(2k) nach §3.2.2 — **neuer, in V1 fehlender Test** |
| **V-03-6** | Ring-Reserve | Burst am Rand des Ringindex-Wrap (Anker so gewählt, dass `anchor − 476` über 0 wrappt) | ausgelesene Samples bit-identisch zu einem Lauf ohne Wrap — **neuer Test** |

Simulationshinweis: `xvlog --relax` und Verilog-Modus (nicht `--sv`) sind nötig, weil der
Viterbi eine Vorwärtsreferenz auf `tb_surv_bit_w` enthält [SIM 2026-05-30].

### 5.2 Vergleich gegen den Referenz-Decoder

Der Python-Pfad ist die zweite unabhängige Implementierung derselben Kette:
`scripts/decode_ul.py` (Burst-Detektion, Sub-Symbol-Refine auf der x-Sequenz, Demod,
Descramble, SCH/HU) und `scripts/decode_ul_raw.py`.
`scripts/check_ul_wav_rtl_emu.py` emuliert die RTL-Quantisierung bit-nah in Python und
trennt damit „Quantisierungsverlust" von „Vorzeichen-/Reihenfolge-Fehler"
[CODE scripts/check_ul_wav_rtl_emu.py:4-7].

**Abnahme:** Auf demselben WAV-Stimulus muss `decodes_ok` der RTL ≥ der Anzahl der vom
Python-Decoder erfolgreich dekodierten Bursts sein [CODE tb/tb_ul_wav_chain.v:16].
Ein Burst, den Python nicht dekodiert, zählt nicht gegen die RTL.

### 5.3 Vergleich gegen die Gold-Aufzeichnung

Struktur, nicht Bits: Die Aufteilung aus §4 (Anteil SCH/HU-CRC-OK gegenüber
TCH/S-CRC-FAIL, Trennung der Korrelationswerte nach CRC-Ausgang) muss sich in einem eigenen
Capture qualitativ reproduzieren. Zell- und MS-spezifische Felder (SSI, GSSI, Scrambler,
MCC/MNC, CC) weichen ab und dürfen abweichen.

### 5.4 Amplituden-Observability (R-03-12)

Die einzige Pegel-Observability in V1 ist `REG_RX_IQ_PEAK_I/Q`. Der Monitor ist **defekt**:

```verilog
// rtl/rx/tetra_rx_chain.v:275-276
wire [12:0] abs_i_sys = fe_i_sys[15] ? (~fe_i_sys[12:0] + 13'd1) : fe_i_sys[12:0];
```

Er bildet das Vorzeichen aus Bit 15, den Betrag aber nur aus den unteren 13 Bits des
16-bit-Samples. Jeder Betrag ≥ 8 192 wickelt um: `fe_i = +12 000` liefert 3 808. Der
Messwert ist damit oberhalb 8 191 bedeutungslos, und die Kommentar-Richtwerte
„~1000–1400 = ~70 % FS" [CODE rtl/rx/tetra_rx_chain.v:115-116] passen zu keiner der beiden
Skalen.

**V2-Anforderung an Kapitel 02:** 16-bit-Betrag (`abs = fe_i[15] ? −fe_i : fe_i`, 16 bit
unsigned), Sliding-Window 100 ms wie bisher, plus ein Sättigungszähler (Anzahl Samples mit
`|fe| ≥ 32 512` im Fenster). Ohne diese beiden Werte ist der Arbeitspunkt des
Soft-Quantisierers nicht prüfbar.

### 5.5 Luft-Abnahme

Jede Änderung an Sync, Erfassungs-Offsets, Quantisierung oder Vorzeichen wird über
mindestens **3 PTT-Läufe** abgenommen, und zwar mit den folgenden Kriterien gleichzeitig:

1. **Vorzeichenkonvention intakt:** `soft{bfi} ≤ hard{bfi}` im selben Capture. Ist
   `soft{bfi} ≫ hard{bfi}`, ist die Konvention nach §3.2.2 gebrochen — das ist das
   Symptom, mit dem der Fehler 2026-05-18 gefunden wurde [MESS 2026-05-18].
2. **Erfassungs-Offsets intakt:** Roh-BER (per-Burst `type5 XOR re-encoded`) ≤ 3 %.
   Zur Unterscheidung der Fehlerbilder (§3.6.2):
   ein Fehler in `BKN1_PRE_SMP`/`BKN2_OFFSET_SMP` verschiebt **alle** Softs eines Blocks und
   zeigt sich als vollständiges Decodier-Versagen (BFI ≈ 100 %, Roh-BER in der Größenordnung
   50 %) — nicht als Randkonzentration; er ist damit schon durch ein erfolgreiches Decode
   (`bfi = 0`) ausgeschlossen. Eine Fehler**konzentration an den Blockrändern** (Positionen
   0–15 / 416–431) deutet dagegen auf zu kleines `POST_WAIT_SMP` oder auf Ringüberlauf
   (§3.6.5). [ANNAHME: Zuordnung der Fehlerbilder aus der Adressbildung abgeleitet] — gemessen
   ist nur der Zustand nach dem Fix [MESS 2026-05-17].
3. **Sync-Rate plausibel:** `nub_rx_cnt`-Zuwachs bei aktivem PTT in der Größenordnung
   16–19 Bursts/s. Deutlich mehr = Fehlalarme, deutlich weniger = verpasste Bursts.
4. **Amplituden-Unabhängigkeit:** Messung nah und auf ≥ 50 m im gleichen Setup; der
   mittlere `|soft|` am **8-bit-Ausgang** beider Pfade darf sich nicht systematisch mit dem
   Pegel verschieben. Erwarteter Arbeitspunkt: Leading-One von `|z|₁` auf `NORM_TGT = 5`
   ⇒ `|soft| ≈ 16…32` (§3.5.3) [ANNAHME: Rechnung aus `NORM_TGT`, für V2 nicht gemessen].
   Die V1-Werte ~6,5 / ~7,1 sind **nicht** die Referenz dieses Kriteriums: sie stammen aus dem
   ungenormten 4-bit-NUB-Pfad und liegen dort ohnehin in der Sättigung (§3.6.6).
5. **A/B im selben Capture,** nie gegen einen Wert aus einer früheren Session (§4,
   Tagesvariabilität).

### 5.6 Diagnose-Zähler (Abnahme von R-03-11)

Pro Sync-Instanz und pro Capture-Modul lesbar: `sync_cnt`, `corr_peak`, `best_phase`,
`bursts_captured`, `sync_dropped_cnt`, für den NUB zusätzlich `mb_overrun_cnt`.
Registernamen und Adressen in Kapitel 07.

**V1-Befund, der die Anforderung motiviert:** Der Statuswert
`{best_phase[1:0], 6'd0, corr_peak[7:0], sync_cnt[15:0]}` existiert in der RTL
[CODE rtl/tetra_zynq_top.v:4288-4290, rtl/infra/tetra_axi_lite_regs.v:1133], liegt aber auf
derselben Adresse wie ein Write-Register in der SW-HAL (`REG_SB_COMMIT`,
[CODE sw/tetra_hal.h:68]) und hat dort **keinen Lesename**. Es gibt keine Codestelle, die
ihn liest. Die UL-Sync-Diagnose war damit in V1 praktisch nicht vorhanden — das erklärt,
warum die Schwellwert-Optima nur über Air-Trial-and-Error gefunden werden konnten.

---

## 6. Offene Punkte

**O-03-1 — Roh-BER-Grundpegel: Phasendrift im differentiellen Demodulator.**
Der NUB-Roh-BER liegt bei 1,4–1,8 % (tagesabhängig bis 3,5 %) und ist **nicht**
randkonzentriert: 330 von 432 Positionen (76 %) waren über mehrere Läufe mindestens einmal
gekippt, BKN1/BKN2 quasi gleichverteilt (51/49) [MESS 2026-05-17]. Das Bucket-Histogramm
über je 27 Bits zeigt jedoch ein Muster:

```
BKN1:  125  129  161  210  200  246  226  212
BKN2:  139  130  183  219  205  233  192  155
```

In beiden Blöcken ist der Anfang deutlich fehlerärmer als Mitte und Ende. Das ist das
typische Bild **akkumulierter Phasendrift**: jedes Symbol erbt das Phasenrauschen seines
Vorgängers, weil die Referenz das Nachbarsymbol ist. Ein Sample-Offset-Fehler ist
ausgeschlossen, weil die Messung überhaupt nur bei erfolgreichem Decode entsteht
(`bfi = 0`, Vergleich `type5 XOR re-encoded`) und ein Basis-Offset alle Softs eines Blocks
verschiebt, also gar kein Decode zustande käme (§3.6.2). Blockspezifik ist ebenfalls
ausgeschlossen (BKN1/BKN2 quasi gleichverteilt).

Zum Vergleich: ETSI fordert für die ungeschützten Bits 0,01 % (STATIC) bzw. 0,4 % (TU50)
bei −85 dBm [ETSI Tabelle 6.28]. Wir liegen ein bis zwei Größenordnungen darüber.

Verbesserungsoptionen, nach erwartetem Gewinn und Risiko:
1. **Amplituden-Normierung im NUB-Pfad** (§3.6.6). Kleinster Eingriff, Normierer existiert
   bereits, Gewinn nicht vorhergesagt. **Empfehlung: zuerst, weil es ohnehin R-03-06 ist.**
2. **Phasen-Tracking über den Burst:** eine über die bekannte Trainingsfolge geschätzte
   Rest-Rotation pro Symbol auf die Differenzphase zurückrechnen. Adressiert genau das
   gemessene Bucket-Muster.
3. **Kohärente Detektion mit Kanalschätzung** aus der Trainingsfolge. Größter erwarteter
   Gewinn, aber sie bricht die CFO-Toleranz aus §3.3.5 und zieht eine CFO-Schätzung nach
   sich. Nicht Stufe 1.

**Vorgehensregel:** Vor Option 2 oder 3 das Bucket-Histogramm im aktuellen Soft-Pfad neu
messen. Option 1 kann das Muster verändern; die alte Messung ist als Baseline nicht mehr
gültig [MESS 2026-05-18].

**O-03-2 — Ringtiefe des NUB-Puffers.**
64 Samples Worst-Case-Reserve auf 1 024 (6,25 %; `delta = 3`) sind knapp für ein Modul, dessen
Offsets bereits einmal falsch waren (§3.6.5). `RING_DEPTH = 2048` kostet 2 RAMB18 zusätzlich. Bei 11 RAMB18 + 10
RAMB36 belegt von 140 RAMB36-Äquivalenten ist der Platz vorhanden.
**Empfehlung: 2048.** Die Reserve ist Versicherung gegen genau die Fehlerklasse, die dieses
Modul schon hatte.

**O-03-3 — Zweiter Verbraucher der 4-Phasen-Korrelation.**
Beide Sync-Instanzen berechnen unabhängig 4 differentielle Produkte auf demselben
IQ-Strom — insgesamt 8 DSP48 für dieselbe Rechnung
[BUILD 2026-06-20: je 4 DSP, `build/reports/cur_hier_deep.rpt:173-174`]. Die
Differentialprodukte und Hard-Dibits sind pattern-unabhängig; nur Schieberegister,
Musterlänge und Vergleich unterscheiden sich.
**Empfehlung:** Ein `tetra_ul_diff_dibit`-Modul (4 Phasen, 4 DSP) speist N Korrelatoren.
Ersparnis 4 DSP48 und ~150 LUT; öffnet außerdem die Tür für einen dritten Korrelator (NTS2,
siehe O-03-6) ohne weitere DSP. Risiko: eine zusätzliche Hierarchieebene im Pfad mit +0,006 ns
WNS — deshalb mit Pipeline-Register auf der Dibit-Grenze bauen.

**O-03-4 — Soft-Breite am Wort-Port.**
V2 gibt intern 8 bit signed aus (§3.5). Am SW-Wort-Port sind 108 statt 54 Registerlesungen
pro Burst nötig, ~2 050 Lesungen/s (§3.7). Ob das messbar Last erzeugt, entscheidet
Kapitel 13. **Empfehlung:** mit 8 bit starten, `SOFT_WIDTH_MB` als Build-Parameter (4 oder 8)
vorsehen, Entscheidung nach Messung der Mainloop-Auslastung.

**O-03-5 — Ist ein weicher Korrelator für den NUB nötig?**
`thresh = 11` bei `SYNC_LEN_SYM = 11` heißt: **nur exakte Übereinstimmung** löst aus. Es gibt
kein Tuning nach oben (12 ist tot), und nach unten kostet jeder Schritt sofort Fehlalarme
(§4). Der Arbeitspunkt liegt also auf einer Kante. Eine Korrelation, die auch
Teilübereinstimmungen bewertet — Summe der Soft-Beträge statt Trefferzahl, oder Einbeziehen
der 2 Tail-Symbole am Burstende — würde einen echten Einstellbereich zurückgeben und
gleichzeitig echte Bursts mit einem Dibit-Fehler retten (bei 1,4 % Roh-BER ist die
Wahrscheinlichkeit, dass mindestens eines von 11 NTS1-Dibits kippt, nicht klein).
**Empfehlung:** magnitude-gewichteter Korrelator (Summe von `|Re z|`/`|Im z|` mit dem
Vorzeichen des Referenzdibits) für die NUB-Instanz spezifizieren und in Simulation gegen die
Trefferzahl-Variante messen, bevor Stufe 1 eingefroren wird. Kein Air-Test vor einer
Simulationsmessung.

**O-03-6 — NTS2 / STCH wird nicht empfangen.**
V1 korreliert nur NTS1. Ein NUB mit NTS2 signalisiert zwei logische Kanäle auf BKN1/BKN2
(STCH+TCH, STCH+STCH, SCH/HD+SCH/HD) [ETSI Tabelle 9.13] und wird nicht erkannt. Damit fehlt
UL-In-Call-Stealing — der einzige nach heutigem Stand fehlende UL-Empfangspfad.
**Empfehlung:** Als drittes Korrelationsmuster auf derselben Dibit-Quelle (O-03-3)
spezifizieren, Ausgabe als zusätzliches `nts_sel`-Bit an die Capture-Stufe. Die
Erfassungs-Geometrie ist identisch (NTS2 hat dieselbe Länge und Position
[ETSI Tabelle 9.5: „n1 to n22 **or** p1 to p22"]), nur die Kanalinterpretation in Kapitel 06
unterscheidet sich. Umsetzung nach Stufe 1 (Kapitel 18).

**O-03-7 — Freigabe der Sync nach Reset.**
V1 gibt `sync_found` sofort frei; der Ring kann noch undefinierte Inhalte haben
(§3.4.5). Praktisch unkritisch, weil vor dem ersten MS-Burst mindestens ein
DL-Multiframe vergeht. **Empfehlung:** Trotzdem ein Sättigungszähler „≥ RING_DEPTH Samples
geschrieben" als Freigabebedingung — 10 FF, entfernt eine ganze Klasse von
Nach-Reset-Artefakten aus der Fehlersuche.

**O-03-8 — Doppelter Phasenzähler.**
`tetra_ul_cb_capture` und `tetra_ul_nub_capture` führen je einen eigenen `phase_cnt_sys`,
der nur deshalb zum Zähler im Sync-Detektor passt, weil beide denselben Reset und dasselbe
Enable sehen [CODE rtl/rx/tetra_ul_burst_capture.v:84-101,
rtl/rx/tetra_ul_nub_capture.v:109-127]. Das ist eine stille Kopplung ohne Assertion.
**Empfehlung:** `phase_cnt_sys` als Ausgang des Sync-Detektors führen (§3.4.3, §3.6.3) und
den lokalen Zähler streichen. Kosten: 2 Bits Verdrahtung. Nutzen: die Annahme ist explizit
und kann bei einer Reset-Umstellung nicht stillschweigend brechen.
