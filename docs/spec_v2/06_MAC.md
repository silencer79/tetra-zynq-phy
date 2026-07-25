# 06 — MAC-Schicht, Kanalzuweisung und Reservierung

**Scope:** Bursttypen und ihre Blockbelegung, Abbildung logischer Kanäle auf Blöcke und
Halbschlitze, MAC-PDU-Typen in beiden Richtungen mit Kopffeldern, Längenangabe und
Füllbit-Regeln, Kanalstehlen, Adressierungsarten, Nutzungsmarkierung sowie vollständig die
Semantik des Zugriffszuweisungskanals (AACH) und der Uplink-Zuweisung samt
Mehrschlitz-Reservierung.

**Nicht hier:** Kanalcodierung, CRC, Verschachtelung, Verwürfelung, RM(30,14) → `05`.
LLC-, MLE- und MM-Schicht → `09`. Rufsteuerung, Sprachrouting → `10`, `12`.
Registeradressen und Mailbox-Formate → `07`. Zeitmessung, Slot-Deadlines,
DL→UL-Air-Lock → `08`. Physikalischer Burstaufbau, Trainingssequenz-Bits,
Slot-Zeitplan-Tabelle → `04`.

**Abhängigkeiten:** `00` (Architektur-Schnitt, R-00-01…R-00-04), `04` (Zeitbasis,
Slot-Zeitplan, Sende-Warteschlange), `03` (UL-Burst-Erkennung), `05` (Kanalcodierung als
Auftragnehmer der Software).

---

## 1. Anforderungen

**Kanalabbildung**

- **R-06-01** Die Zuordnung logischer Kanal → Bursttyp → Block (BBK/BKN1/BKN2/SSN1/SSN2)
  folgt §3.2 dieses Kapitels und ist die **einzige** Quelle dieser Zuordnung im System.
- **R-06-02** Die Steuerframe-Abbildung (BSCH, BNCH, CLCH) wird aus den Formeln
  `FN = 18 ∧ (MN + TN) mod 4 = 3` (BSCH, CLCH) bzw. `= 1` (BNCH) berechnet, mit
  **ETSI-1-basiertem TN**. Eine Regel, die `MN mod 4` ohne `TN` prüft, ist ein Spec-Verstoß.
- **R-06-03** Kanalstehlen wird auf der Luft **ausschließlich** über die Trainingssequenz
  signalisiert (NTS1 = ein Vollschlitz-Kanal, NTS2 = zwei Halbschlitz-Kanäle). Kein Modul
  leitet Stehlen aus dem AACH-Inhalt ab.

**AACH / Zugriffszuweisung**

- **R-06-04** Das 14-bit-Infowort des AACH wird **aus der Inhaltsentscheidung desselben
  Slots** berechnet, in derselben Vorausschaustufe wie die Burst-Inhaltswahl. Es gibt
  **kein** von der Slot-Inhaltswahl unabhängiges Software-Register, das ein AACH-Muster
  über Slots hinweg festhält.
- **R-06-05** Die Software liefert dem AACH-Generator ausschließlich *Zustandsgrößen*:
  Nutzungsmarkierung je Verkehrsschlitz, Richtungszustand je Verkehrsschlitz,
  Zugriffsparameter des Kontrollkanals. Sie liefert **kein** fertiges Infowort.
- **R-06-06** Jedes vom Generator erzeugbare Infowort ist in der Tabelle §3.8.3 aufgeführt.
  Ein nicht in dieser Tabelle stehendes Muster darf die Hardware nicht senden.
- **R-06-07** Der AACH eines Downlink-Slots beschreibt die Zugriffsrechte des
  **gleichnummerierten** Uplink-Slots derselben TDMA-Frame [ETSI §23.5.1.4.2 NOTE].
  Reservierungen über mehrere Slots laufen deshalb über aufeinanderfolgende Frames
  desselben `tn`, ohne Frame-Arithmetik.

**Uplink-Zuweisung (Kernanforderung dieses Kapitels)**

- **R-06-08** Die Uplink-Zuweisung wird vollständig in Hardware ausgelöst, zeitlich
  platziert, wiederholt und begrenzt (R-00-01). Kein Software-Handshake liegt zwischen
  Auslöseereignis und Sendeslot.
- **R-06-09** Das Auslöseereignis ist **hardware-lokal und inhaltsunabhängig** (R-00-02):
  Erkennung eines Control-Uplink-Bursts in einem Unterschlitz, der im AACH desselben
  Uplink-Slots als **offen für Zufallszugriff** ausgewiesen war. Ein Burst in einem
  reservierten Unterschlitz löst **nie** eine neue Zuweisung aus.
- **R-06-10** Die Software stellt fertig codierte Zuweisungs-PDUs vorab in ein
  Hardware-Magazin (R-00-03). Die Hardware wählt, platziert und wiederholt; sie codiert
  nicht und parst nicht.
- **R-06-11** Die Zuweisungs-PDU trägt `granting_delay = 0000₂`. Damit ist der codierte
  Block **positionsunabhängig**: er gilt immer für den Uplink-Slot, dessen Downlink-Slot ihn
  trägt [ETSI §23.5.2.2.2].
- **R-06-12** Über-Zuweisung ist hart begrenzt: maximal `GRANT_REPEAT` Aussendungen je
  Auslösung, danach eine Sperrzeit `GRANT_GAP` in Frames. Jede unterdrückte Auslösung ist
  an einem Zähler sichtbar.
- **R-06-13** Die Zuweisung nutzt **nicht** die DL-Signalisierungs-Warteschlange aus
  `04 §3.5`. Sie hat einen eigenen, einträgigen Pfad. Damit kann eine Zuweisungsflut die
  Warteschlange strukturell nicht überlaufen lassen.
- **R-06-14** Die Mehrschlitz-Reservierung ist Grundfunktion: `capacity_allocation ≥ 1`
  hält das Reservierungsmuster im AACH über die zugesagte Anzahl aufeinanderfolgender
  Kontrollkanal-Slots, wobei Frame-18-Slots mit vordefinierter Linearisierungsgelegenheit
  **übersprungen** und nicht angerechnet werden [ETSI §23.5.2.2.2].
- **R-06-15** Wird in einem reservierten Unterschlitz ein Uplink-Burst erkannt, endet das
  Wiederholen sofort. Wird keiner erkannt, wiederholt die Hardware die Zuweisung bis
  `GRANT_REPEAT` erschöpft ist [ETSI §23.5.2.2.7].

**MAC-PDUs, Länge, Füllbits**

- **R-06-16** Die drei Präsenz-Flags `power control flag`, `slot granting flag`,
  `channel allocation flag` sind im MAC-RESOURCE-Kopf **immer** vorhanden, unmittelbar
  hinter dem Adressblock, in dieser Reihenfolge; das jeweilige Element folgt nur bei
  Flag = 1 [ETSI §21.4.3.1 Tab. 21.55, Mindest-Kopflänge 29 bit].
- **R-06-17** Kein Encoder legt einen Flag-**Wert** fest. Die Werte kommen aus der
  PDU-Klassentabelle §3.4.5.
- **R-06-18** Die Längenangabe zählt die **gesamte MAC-PDU** (Kopf + TM-SDU) in Oktetten;
  für π/4-DQPSK gilt `Y2 = Z2 = 1`, also Wert = Oktette [ETSI §21.6 Tab. 21.98].
- **R-06-19** Füllbits werden nach §3.7 gesetzt: erstes Füllbit `1` unmittelbar nach dem
  letzten Nutzbit, danach `0` bis zur angegebenen Länge; `fill bit indication = 1` genau
  dann, wenn Füllbits vorhanden sind [ETSI §23.4.2.2].
- **R-06-20** Nach der letzten Nutz-PDU eines Downlink-MAC-Blocks folgt eine 16-bit
  **Null-PDU**, wenn mindestens 16 bit frei sind; danach ein Block-Füllmuster `1` gefolgt
  von `0`. Ein einzelnes gesetztes Bit ohne Null-PDU ist verboten.
- **R-06-21** Unterstützte Adressierungsarten sind in §3.6 abschließend aufgezählt. Ein
  Sender, der eine nicht aufgezählte Art verwendet, ist ein Spec-Verstoß; ein Empfänger
  verwirft solche PDUs und zählt sie.

**Metadaten und Beobachtbarkeit**

- **R-06-22** Jeder an die Software übergebene Uplink-Burst trägt `tn`, `fn`, `mn`,
  Unterschlitz-Index und Bursttyp im selben Transfer (R-00-04). Die Software leitet
  Slot-Zuordnung, Sprachrouting und Reassembly-Fenster **ausschließlich** daraus ab.
- **R-06-23** Für jeden der in §3.13 aufgeführten Vorgänge existiert ein im Betrieb
  AXI-lesbarer, sättigender Zähler unter eigenem Namen (P6).

---

## 2. Architektur / Aufbau

### 2.1 Was in Hardware bleibt

Aus dem Schnitt in `00 §3` folgt für die MAC-Schicht eine sehr kurze Hardware-Liste:

| Einheit | Warum Hardware | Neu in V2 |
|---|---|---|
| `tetra_aach_info` | Der AACH beschreibt den Slot, in dem er gesendet wird, und den gleichnummerierten Uplink-Slot. Er muss vor der Sende-Deadline dieses Slots fertig sein und braucht Vorausschau auf FN/MN. | ersetzt die Default-Logik in `tetra_aach_encoder` |
| `tetra_ul_grant` | Antwortzeit im Bereich eines Zeitschlitzes (§3.9.2), Reservierung über mehrere Slots, Wiederholungs- und Begrenzungslogik. | ersetzt `tetra_pre_reply_slotgrant` + `resv_hold` |

Alles andere an MAC-Funktion liegt in Software. Die folgenden V1-Module haben in V2
**keinen** Nachfolger in RTL:

| V1-Modul | LUT | FF | V2-Ort |
|---|---:|---:|---|
| `tetra_mac_resource_dl_builder` (268 bit) | 2247 | 1535 | SW `tetra_mac_dl.c` |
| `tetra_mac_resource_dl_builder` (124 bit) | 322 | 298 | SW `tetra_mac_dl.c` |
| `tetra_dl_pdu_builder` (**nur** Hülle; die 2 271 LUT / 1 934 FF seines SCH/F-Encoders sind in `05 §2.1` gezählt, nicht hier) | 5 | 917 | SW (`05`) |
| `tetra_mac_resource_bl_ack_builder` | 5 | 55 | SW `tetra_mac_dl.c` |
| `tetra_basic_slotgrant_encoder` | — | — | SW `tetra_mac_dl.c` (rein kombinatorisch, im Report nicht als eigene Instanz geführt) |
| `tetra_pre_reply_slotgrant` (Hülle) | 17 | 315 | `tetra_ul_grant` |
| `tetra_pre_reply_blck` (Hülle) | 14 | 280 | SW `tetra_mac_dl.c` |
| `tetra_ul_mac_access_parser` | 43 | 283 | SW `tetra_mac_ul.c` |
| `tetra_ul_demand_reassembly` | 144 | 425 | SW `tetra_mac_reass.c` |
| `tetra_ul_schf_reassembly` | 229 | 174 (+1 RAMB18) | SW `tetra_mac_reass.c` |
| `tetra_steal_detect` | 0 | 1 | entfällt (§3.3.3) |

[BUILD 2026-06-20, `build/reports/cur_hier_deep.rpt` Zeilen 133–197, Spalten
„Total LUTs"/„FFs"; der Report gibt den Designstand jenes Tages wieder]

Summe der entfallenden MAC-Logik: **≈ 3 000 LUT / ≈ 4 300 FF / 1 RAMB18**. Diese Summe und die
Summe der entfallenden Codierer-Logik in `05 §2.1` (≈ 11 500 LUT / ≈ 12 300 FF / 3 RAMB18)
sind **disjunkt und dürfen addiert werden**; der SCH/F-Encoder steckt genau in einer von
beiden (`05`). Der Gewinn ist
nicht nur Fläche: die C-Spiegel `sw/tetra_ul_mac_parse.c` und `sw/tetra_ul_reassembly.c`
existieren in V1 bereits und sind ausdrücklich als „bit-genaue Spiegelung" des RTL
angelegt [CODE sw/tetra_ul_mac_parse.c:1-4, sw/tetra_ul_reassembly.c:1-4]. V2 behält
**nur** die C-Seite und beendet damit eine der vier in `00 §1.1` benannten Doppelungen.

### 2.2 Blockstruktur

```
                      ┌──────────────── Software (PS) ─────────────────┐
                      │ tetra_mac_dl.c   PDU-Bau, LI, Füllbits,        │
                      │                  Null-PDU, Assoziation         │
                      │ tetra_mac_ul.c   MAC-ACCESS/END-HU/FRAG/END    │
                      │                  Kopf-Parse                    │
                      │ tetra_mac_reass.c Fragment-Zusammensetzung     │
                      │ tetra_mac_grant.c Magazin-Pflege               │
                      └───┬──────────────┬──────────────────────┬──────┘
        codierte PDU (05) │              │ codierte Grant-PDU   │ Zustandsgrößen
                          ▼              ▼                      ▼
        ┌─────────────────────────┐  ┌──────────────────┐  ┌──────────────────┐
        │ tetra_dl_signal_queue   │  │ tetra_ul_grant   │  │ tetra_aach_info  │
        │        (04 §3.5)        │  │  Magazin 4×216   │  │  14-bit Infowort │
        └───────────┬─────────────┘  └───┬──────────┬───┘  └────────┬─────────┘
                    │  BKN1/BKN2         │ BKN1     │ resv_*        │ info14
                    ▼                    ▼          └──────────────►│
        ┌───────────────────────────────────────┐            ┌──────▼─────────┐
        │ tetra_burst_dispatcher (04 §3.4)      │            │ tetra_aach_rm_ │
        │  content_sys[2:0] (§3.8.2) ───────────┼──┐         │ encoder  (05)  │
        └───────────────┬───────────────────────┘  │         └──────┬─────────┘
                        │     an tetra_aach_info ◄─┘                │
                        ▼ BKN1, BKN2, NTS-Wahl                      ▼ 30 bit BBK
                 tetra_burst_builder (04 §3.6)  ◄─────────────────────
                        ▲
       ul_cb_detect_sys │ (03 §3.4)  ── inhaltsunabhängiges Auslöseereignis
                        └─────────────────────────► tetra_ul_grant
```

Die Auflösung eines Konflikts zwischen Zuweisung und Warteschlange ist normativ
festgelegt: **`tetra_ul_grant` hat auf dem Kontrollkanal-Slot Vorrang vor
`tetra_dl_signal_queue`**; der Warteschlangen-Kopf wird in diesem Slot **nicht** entnommen
und der Vorgang an `grant_preempt_cnt` gezählt. Weil `GRANT_REPEAT` klein ist (Default 2),
ist die Verzögerung der Warteschlange nach oben durch zwei Slots je Auslösung begrenzt.

### 2.3 Zusammenspiel der drei Zuweisungs-Teile

Eine Uplink-Zuweisung besteht in TETRA immer aus **zwei** Aussendungen, die dasselbe
Slotpaar betreffen:

1. **Adressierte Zusage** — MAC-RESOURCE mit `slot granting flag = 1` und dem 8-bit
   Basis-Slot-Grant-Element. Nur der adressierte Teilnehmer darf senden
   [ETSI §23.5.2.3.1].
2. **Reservierung im AACH** — der Zugriffsfeld-Wert „Reserved subslot" verhindert, dass
   andere Teilnehmer Zufallszugriff auf genau diese Unterschlitze machen
   [ETSI §23.5.2.2.7: *„After granting a subslot or slots, the BS should mark the
   equivalent uplink subslots as reserved in the ACCESS-ASSIGN PDU"*].

Ohne (1) sendet niemand; ohne (2) kollidiert der zugesagte Unterschlitz mit
Zufallszugriffen. **V1 hat genau diese Kopplung erst nachträglich hergestellt** — die
Reservierungshaltung wurde separat eingebaut, weil die UL-Fragmentkette sonst nach einem
Fragment abbrach [CODE rtl/tx/tetra_aach_encoder.v:73-81]. In V2 sind beide Teile
**dieselbe** Zustandsmaschine: `tetra_ul_grant` erzeugt die Aussendung und liefert im
selben Takt das Reservierungsmuster an `tetra_aach_info`.

---

## 3. Detail-Spezifikation

### 3.1 Bursttypen und Blockbelegung

Nur π/4-DQPSK; π/8-D8PSK und QAM sind nicht Teil von V2.

| Burst | Richtung | Symbole | Blöcke | Beleg |
|---|---|---:|---|---|
| Control Uplink Burst (CB) | UL | 103 | 2 × 84 scrambled control bits, dazwischen 30 bit erweiterte Trainingssequenz | [ETSI §9.4.4.2.1 Tab. 9.3] |
| Normal Uplink Burst (NUB) | UL | 231 | BKN1 216 bit, BKN2 216 bit, 22 bit Trainingssequenz dazwischen | [ETSI §9.4.4.2.4 Tab. 9.5] |
| Linearisierungs-Uplink-Burst (LB) | UL | — | keine Nutzbits | [ETSI §6.4.5] |
| Normal Downlink Burst (NDB), kontinuierlich | DL | 255 | BKN1 216, BBK 14+16 = 30, BKN2 216 | [ETSI §9.4.4.2.5 Tab. 9.7] |
| Synchronisations-Downlink-Burst (SB), kontinuierlich | DL | 255 | 80 bit Frequenzkorrektur, SB-Block 1 = 120 bit, BBK 30, BKN2 216 | [ETSI §9.4.4.2.6 Tab. 9.9] |

Der Broadcast-Block BBK trägt **immer** den AACH, in jedem Downlink-Slot, in NDB **und**
in SB [ETSI §9.5.5, §21.4.7.2]. Der **Inhalt** dieses AACH ist in V1 nicht mit dem Burst
abgeglichen: von den 1373 SB-Bursts der eigenen Aufzeichnung bewerben **600** im BBK ein
Verkehrsmuster (`0x32CB` 217 + `0x2049` 293 + `0x22C9` 90), obwohl der Slot einen
Synchronisations-Burst trägt [GOLD/MESS `docs/local_cell_decode/dl_events.jsonl`, eigene
Auszählung über alle 1876 Bursts, Felder `type` und `aach_info_14b`] — dieselbe Kennzahl wie
in §3.8.4 und §5.2 (600 von 638 Verkehrsmuster-Fällen).

Der Uplink-Zeitschlitz ist in zwei Unterschlitze SSN1/SSN2 à 127,5 Symboldauern teilbar;
ein CB belegt genau einen Unterschlitz [ETSI §9.4.4.2, §4.5.3].

### 3.2 Logische Kanäle auf Bursts und Blöcke

Auszug aus [ETSI §9.5.1 Tab. 9.27] für die in V2 verwendeten Kanäle:

| Logischer Kanal | Richtung | Burst | Block | FN | TN |
|---|---|---|---|---|---|
| BSCH | DL | SB | BKN1 (120 bit) | 18 | `(MN+TN) mod 4 = 3` |
| BNCH | DL | NDB / SB | BKN2 | 18 bzw. 1…18 | `(MN+TN) mod 4 = 1` bzw. frei |
| AACH | DL | NDB, SB | BBK | 1…18 | 1…4 (zwingend) |
| SCH/F | DL / UL | NDB / NUB | BKN1+BKN2 | 1…18 | 1…4 |
| SCH/HD | DL | NDB, SB | BKN1, BKN2 einzeln | 1…18 | 1…4 |
| SCH/HU | UL | CB | SSN1, SSN2 | 1…18 | 1…4 |
| TCH | DL / UL | NDB / NUB | BKN1, BKN2 | 1…17 | 1…4 |
| STCH | DL / UL | NDB / NUB | BKN1, BKN2 | 1…17 | 1…4 |
| CLCH | UL | LB | SSN1 | 18 | `(MN+TN) mod 4 = 3` |

**Steuerframe-Formeln, normativ** [ETSI §9.5.2 Gl. 9.16–9.18, §23.4.5.1 Gl. 23.2] —
`TN` ist hier **ETSI-1-basiert**:

```
ETSI-Schreibweise (MN = 1..60, TN = 1..4):
  BNCH auf BKN2 : FN = 18 ∧ (MN + TN) mod 4 = 1
  BSCH auf BKN1 : FN = 18 ∧ (MN + TN) mod 4 = 3
  CLCH auf SSN1 : FN = 18 ∧ (MN + TN) mod 4 = 3

RTL-Schreibweise (mn = MN−1 = 0..59, tn = TN−1 = 0..3, fn = FN−1 = 0..17):
  BNCH : fn = 17 ∧ (mn + tn) mod 4 = 3
  BSCH : fn = 17 ∧ (mn + tn) mod 4 = 1
  CLCH : fn = 17 ∧ (mn + tn) mod 4 = 1
```

Die Umrechnung ist `(MN + TN) mod 4 = (mn + tn + 2) mod 4`; die RTL-Bedingung
`(mn + tn) mod 4 = 1` ist im ganzen Kapitel als **`clch_phase`** benannt.

BSCH und CLCH fallen auf denselben Slot: dort trägt der Downlink den
Synchronisationsburst und der zugehörige Uplink-Unterschlitz 1 ist Linearisierungsfenster.
Die Formel ist an der Gold-Aufzeichnung **ohne eine Ausnahme** belegt: auf dem
Kontrollkanal-Zeitschlitz tragen genau die 26 Frame-18-Slots mit
`(MN + TN) mod 4 = 3` das CLCH-Muster `0x0049`, die übrigen 76 das Normalmuster `0x0249`
— und kein Slot der anderen drei Phasen trägt `0x0049`
[GOLD `docs/reference_decode/dl_events.jsonl`, eigene Auszählung aller 408
Frame-18-Bursts].

**V1-Abweichung.** Die Default-Logik prüft `mn mod 4` **ohne** `tn`
[CODE rtl/tx/tetra_aach_encoder.v:231-241] und liegt zusätzlich eine Multiframe daneben
(sie testet `mn mod 4 == 2` statt `== 1`, dieselbe Verschiebung, die `04 §6` für den
BSCH-Anker im Slot-Zeitplan feststellt). Messbare Folge in der eigenen Aufzeichnung: das
CLCH-Muster erscheint auf TS3 und TS4 nur 7-mal je Zeitschlitz statt in allen 26
Frame-18-Slots des Mitschnitts; an den übrigen 19 Positionen steht ein Verkehrsmuster
[GOLD/MESS `docs/local_cell_decode/dl_events.jsonl`, eigene Auszählung über alle 1876
Bursts]. **Konsequenz für V2:** die Bedingung wird an genau einer Stelle als
`clch_phase` berechnet und von AACH-Generator **und** Slot-Zeitplan-Generator benutzt.

### 3.3 Kanalstehlen

#### 3.3.1 Signalisierung

Das Stehlen wird **durch die Trainingssequenz** angezeigt, nicht durch ein Kopffeld und
nicht durch den AACH [ETSI §9.5.4: *„The presence of stolen traffic in one burst shall be
indicated by the type of training sequence"*]:

| Normale Trainingssequenz | Bedeutung |
|---|---|
| NTS1 (`n1…n22`) | ein Vollschlitz-Kanal: TCH **oder** SCH/F |
| NTS2 (`p1…p22`) | zwei Halbschlitz-Kanäle: STCH+TCH, STCH+STCH, SCH/HD+SCH/HD, SCH/HD+BNCH |

[ETSI §9.4.4.3.2 Tab. 9.13; Sequenzwerte in `04 §3.6`]

Regel: **STCH stiehlt immer zuerst die erste Bursthälfte** [ETSI §9.5.4]. Die zweite Hälfte
wird nur mit gestohlen, wenn die Längenangabe der MAC-RESOURCE in der ersten Hälfte
`111110₂` (weitere C-/U-Plane-Signalisierung) oder `111111₂` (letztes Fragment) trägt
[ETSI §21.4.3.1].

#### 3.3.2 Was V2 in Stufe 1 baut

- **Downlink-Stehlen: gebaut.** Die Software entscheidet, dass ein Verkehrsschlitz
  gestohlen wird, und liefert zwei codierte Halbblöcke: einen SCH/HD plus eine TCH-Hälfte
  (Inhaltsklasse **5** nach §3.8.2) oder zwei SCH/HD (Inhaltsklasse **3**). Der
  Burst-Builder wählt daraufhin NTS2 (`04 §3.6`), der AACH-Generator die Zeilen 10 bzw. 12
  aus §3.8.2 — `0x304B` bei Uplink-Verkehr, `0x2049` bei assigned-Zugriff im Uplink.
- **Uplink-Stehlen: Erkennung gebaut, Auswertung Roadmap.** Ein UL-STCH-Burst trägt NTS2
  statt NTS1. Der UL-Sync-Korrelator aus `03 §3.3` korreliert in V1 ausschließlich auf
  NTS1 und **verwirft** damit jeden gestohlenen Uplink-Burst still. V2 fordert einen
  zweiten Korrelatorzweig auf NTS2 mit einem eigenen Trefferzähler
  (`ul_nts2_detect_cnt`), damit die Existenz solcher Bursts messbar wird; die
  Halbschlitz-Zerlegung und ihre Protokollauswertung stehen in `18_ROADMAP.md`.

Beleg für die Lücke: die UL-Sync-Instanz `u_ul_sync_nub` ist ausschließlich mit dem
NTS1-Muster parametriert (`.SYNC_PATTERN({8'b0, NTS1_REF_22B})`, `SYNC_LEN_SYM = 11`)
[CODE rtl/rx/tetra_rx_chain.v:433-439]; ein NTS2-Zweig existiert im Empfangs-RTL nicht
(kein `NTS2`-Treffer in `rtl/rx/`). Gegen die Kanalliste §3.2 gehalten ist STCH damit der
einzige logische Kanal ohne Empfangspfad; dieselbe Feststellung steht in `03 §3.3.4`.

#### 3.3.3 `tetra_steal_detect` entfällt

Das V1-Modul leitet Stehlen aus dem AACH ab und beruft sich dafür auf Feldnamen, die es in
EN 300 392-2 nicht gibt: es liest `aach_data[13:8]` als „Access code (6 bits)" und
verweist auf „§21.4.1 / Table 21.55" und „Table 21.56"
[CODE rtl/lmac/tetra_steal_detect.v:11-22]. Tatsächlich ist Tabelle 21.55 die
MAC-RESOURCE-PDU, Tabelle 21.56 die Maximallänge der TM-SDU im Downlink-MAC-RESOURCE, und
§21.4.1 die Liste der MAC-PDU-Typen. Das AACH-Format steht in Tabellen 21.82/21.83 und hat
kein 6-bit-Zugriffscodefeld an dieser Position (§3.8.1). Die vom Modul aufgezählten
Codewerte (`001000` = STCH usw.) existieren im Standard nicht. Die
Stehl-Erkennungsregel `access_code[5:3] == 001` [CODE …:81] ist damit ohne Grundlage.

Zusätzlich ist die Logik im gebauten Design wirkungslos: der einzige Verbraucher
`rx_stolen_sys` ist ein an der Modulgrenze offen gelassener Ausgang
[CODE rtl/lmac/tetra_lmac.v:263], und der Utilization-Report weist dem Modul 0 LUT / 1 FF zu
[BUILD 2026-06-20 `cur_hier_deep.rpt:148`]. Im aktuellen RTL-Baum ist `tetra_lmac`
überhaupt nicht mehr instanziiert: es gibt keine `tetra_lmac`-Instanz in `rtl/` — die Datei
steht nur noch in der Synthese-Dateiliste [CODE scripts/vivado_build.tcl:149] und wird in
`rtl/tetra_zynq_top.v:14,:35` kommentierend genannt. Der zitierte Report gibt den Stand vor
dem Entfernen wieder und führt `u_lmac` deshalb noch mit 702 LUT
[BUILD 2026-06-20 `cur_hier_deep.rpt:146`]. **V2 baut es nicht nach.**

### 3.4 MAC-PDUs Downlink

Alle Bit-Angaben MSB-first: Bit 0 ist das zuerst gesendete Bit des MAC-Blocks
[ETSI §21.4.0: *„The information content shall start with the most significant bit"*].
MAC-Blockgrößen: **SCH/F = 268 bit, SCH/HD = 124 bit, STCH-Hälfte = 124 bit**
(nachrechenbar aus [ETSI §21.4.3.1 Tab. 21.56]: 239 + 29 = 268, 95 + 29 = 124).

#### 3.4.1 MAC-RESOURCE

| Bit | Breite | Feld | Wert / Regel |
|---:|---:|---|---|
| 0 | 2 | MAC PDU type | `00` |
| 2 | 1 | fill bit indication | 1 wenn Füllbits vorhanden (§3.7) |
| 3 | 1 | position of grant | 0 = Grant gilt auf diesem Kanal |
| 4 | 2 | encryption mode | `00` |
| 6 | 1 | random access flag | 1 = Zufallszugriff quittiert |
| 7 | 6 | length indication | Oktette der gesamten PDU, Sonderwerte unten |
| 13 | 3 | address type | §3.6 |
| 16 | 10/24/30/34 | address | je nach address type; SSI = 24 |
| `A` | 1 | power control flag | **immer vorhanden** |
| `A+1` | 4 | power control element | nur wenn pc-Flag = 1 |
| `B` | 1 | slot granting flag | **immer vorhanden** |
| `B+1` | 8 | basic slot granting element | nur wenn sg-Flag = 1, §3.9.4 |
| `C` | 1 | channel allocation flag | **immer vorhanden** |
| `C+1` | n | channel allocation element | nur wenn ca-Flag = 1 |
| `D` | var | TM-SDU | LLC-PDU (`09`), darf fehlen |

mit `A` = 16 + Adressbreite, `B` = `A` + 1 + (pc ? 4 : 0), `C` = `B` + 1 + (sg ? 8 : 0),
`D` = `C` + 1 + (ca ? n : 0) [ETSI §21.4.3.1 Tab. 21.55].

Bei `address type = 001` (SSI) ist der Grundkopf 40 bit, mit den drei Flags **43 bit**.
Genau dieser Wert ist bit-exakt im Referenznetz nachweisbar: Burst #775 hat nach 40 bit
Grundkopf `pc = 0`, `sg = 1`, `sg_element = 0x00`, `ca = 0`, also endet der Kopf bei Bit 51
[GOLD `docs/reference_decode/dl_events.jsonl` Burst #775, Feld `bkn1_info_124b`].

**Sonderwerte der Längenangabe** [ETSI §21.4.3.1]:

| Wert | Bedeutung |
|---|---|
| `000000₂` | reserviert |
| `000001₂`…`010010₂` | Länge = Wert × Y2 Oktette |
| `010011₂`…`111010₂` | Länge = (18·Y2 + (Wert−18)·Z2) Oktette |
| `111110₂` | zweite Halbschlitzhälfte in STCH gestohlen |
| `111111₂` | **Beginn einer Fragmentierung** |

Für π/4-DQPSK ist `Y2 = Z2 = 1`, also über den ganzen nutzbaren Bereich
**Wert = Oktette** [ETSI §21.6 Tab. 21.98]. V1 rechnet genau so
[CODE rtl/lmac/tetra_mac_resource_dl_builder.v:363-364]. Der Fragmentierungsstart mit
`111111₂` = 63 ist in der Software bereits verwendet
[CODE sw/tetra_sds_dl_frag.c:110].

#### 3.4.2 Null-PDU (Downlink)

16 bit, `address type = 000`, keine weiteren Felder; `length indication = 000010₂` (2
Oktette) für π/4-DQPSK [ETSI §21.4.3.1]. Sie beendet den MAC-Block: danach sucht der
Empfänger keine weiteren PDUs [ETSI §23.4.3.3].

Bit-exakter Nachweis im Referenznetz, Burst #775 (SCH/HD, 124 bit):

```
Bit  0..50  MAC-RESOURCE, LI = 7, addr = SSI, sg = 1, sg_element = 0x00
Bit 51..55  1 0 0 0 0            ← Füllbits: erste '1', dann '0' bis 7 Oktette
Bit 56..71  00 0 0 00 0 000010 000   ← Null-PDU: type=00, LI=2, addr_type=000
Bit 72      1                     ← Blockfüllung, danach 0 bis Bit 123
```

[GOLD `docs/reference_decode/dl_events.jsonl` Burst #775]. Dieselbe Struktur zeigt Burst
#783 (SCH/F, 268 bit): Nutz-PDU bis Bit 167 (LI = 21), Null-PDU auf Bit 168…183,
Blockfüllung ab Bit 184.

#### 3.4.3 MAC-FRAG (Downlink)

4 bit Kopf: `01` (type) + `0` (subtype) + `fill bit indication`; danach bis 264 bit TM-SDU
auf SCH/F bzw. 120 bit auf SCH/HD [ETSI §21.4.3.2 Tab. 21.57/21.58].

#### 3.4.4 MAC-END (Downlink)

| Bit | Breite | Feld |
|---:|---:|---|
| 0 | 2 | MAC PDU type = `01` |
| 2 | 1 | MAC PDU subtype = `1` |
| 3 | 1 | fill bit indication |
| 4 | 1 | position of grant |
| 5 | 6 | length indication |
| 11 | 1 | slot granting flag |
| 12 | 8 | basic slot granting element (nur bei Flag = 1) |
| … | 1 | channel allocation flag |

[ETSI §21.4.3.3 Tab. 21.59]. Mindest-Kopflänge **13 bit**, mit gesetztem Slot-Grant-Flag
**21 bit**. Der V1-Fehler an dieser Stelle ist dokumentiert und behoben: ein 4-bit-Kopf
(MAC-FRAG-Form) im MAC-END führte dazu, dass der Empfänger TM-SDU-Bits als Längenangabe
las und die Reassembly verwarf [CODE sw/tetra_sds_dl_frag.c:132-146]. **V2-Regel:**
MAC-END im Downlink hat nie einen 4-bit-Kopf; die Kopflänge ergibt sich aus den beiden
Flags und ist vom Erzeuger mitzurechnen.

#### 3.4.5 PDU-Klassentabelle (Flag- und Feldwerte, nicht im Encoder)

| Klasse | Slotformat | address type | LLC | RA-Flag | pc/sg/ca | sg_element |
|---|---|---|---|---:|---|---|
| Vorantwort / Kapazitätszusage | SCH/HD | SSI | keine TM-SDU | **1** | 0/1/0 | §3.9.4 |
| Anmelde-Bestätigung | SCH/F | SSI | BL-ADATA | 0 | 0/1/0 | `0x00` |
| Gruppen-Bestätigung | SCH/F | SSI | BL-ADATA | 0 | 0/1/0 | `0x00` |
| LLC-Quittung | SCH/HD | SSI | BL-ACK | 0 | 0/0/0 | — |
| Rufaufbau (CMCE) | SCH/F | SSI + Usage Marker | BL-UDATA | 0 | 0/0/**1** | — |
| Zellrundspruch | SCH/F | SSI (Broadcast) | BL-UDATA | 0 | 0/0/0 | — |
| Leerlauf-Füller | SCH/HD | **000 (Null-PDU)** | — | 0 | — | — |

Belege je Zeile: Vorantwort und Bestätigung bit-exakt aus [GOLD Burst #775 bzw. #783];
Gruppen-Bestätigung aus [GOLD Burst #4811/#5343, LI = 16]; Rufaufbau aus dem
Feld-für-Feld-Vergleich in `docs/local_cell_decode/DIFF_vs_reference.md:65-107`;
Leerlauf-Füller aus der Auszählung in `04 §3.5.2` [GOLD]. Die V1-Entsprechung ist
`rtl/include/tetra_pdu_class.vh` — inhaltlich dieselbe Tabelle, aber als
Verilog-`define`-Satz, weil dort die Encoder in RTL lagen [CODE
rtl/include/tetra_pdu_class.vh:44-160]. In V2 ist die Tabelle eine C-Konstantentabelle in
`tetra_mac_dl.c`.

Zwei Werte sind bewusst so und dürfen nicht „aufgeräumt" werden:

- Die Vorantwort trägt `random access flag = 1`, die Bestätigung `0`
  [GOLD #775 vs. #783] — die Vorantwort quittiert den Zufallszugriff und beendet damit
  die Wiederholungen des Endgeräts [ETSI §21.4.3.1].
- Die Bestätigung trägt `slot granting flag = 1` mit `sg_element = 0x00`, obwohl sie
  keine Kapazität „braucht": sie weist dem Endgerät den Unterschlitz für die
  LLC-Quittung zu. Der Referenz-AACH desselben Slots reserviert genau diesen Unterschlitz
  (§3.8.3, Muster `0x0009`) [GOLD #783].

### 3.5 MAC-PDUs Uplink

#### 3.5.1 MAC-ACCESS (SCH/HU, ein Unterschlitz)

| Bit | Breite | Feld | Anmerkung |
|---:|---:|---|---|
| 0 | 1 | MAC PDU type in subslot | `0` = MAC-ACCESS |
| 1 | 1 | fill bit indication | |
| 2 | 1 | encrypted flag | |
| 3 | 2 | address type | `00`=SSI, `01`=Event Label, `10`=USSI, `11`=SMI |
| 5 | 24 / 10 | address | 10 bit nur bei Event Label |
| 29 | 1 | optional field flag | |
| 30 | 1 | length indication **oder** capacity request | nur wenn opt = 1 |
| 31 | 5 | length indication | wenn Bit 30 = 0 |
| 31 | 1 | fragmentation flag | wenn Bit 30 = 1 |
| 32 | 4 | reservation requirement | wenn Bit 30 = 1 |
| 30 / 36 | ≤ 62 / ≤ 56 | TM-SDU | |

[ETSI §21.4.2.1 Tab. 21.41–21.43]. Kopflängen: **30 bit** ohne Optionalfeld, **36 bit**
mit Optionalfeld (bei 24-bit-Adresse); maximale TM-SDU auf SCH/HU **62 bit** bzw.
**56 bit** [Tab. 21.42/21.43]. Gesamtblock 92 bit. Der V1-Parser trifft diese Positionen
exakt [CODE rtl/lmac/tetra_ul_mac_access_parser.v:152-181, :195], ebenso der C-Spiegel
[CODE sw/tetra_ul_mac_parse.c:21-36].

**Reservation requirement** (4 bit) codiert nicht linear:
`0000` = 1 Unterschlitz, `0001` = 1 Slot, `0010` = 2, `0011` = 3, `0100` = 4, `0101` = 5,
`0110` = 6, `0111` = 8, `1000` = 10, `1001` = 13, `1010` = 17, `1011` = 24, `1100` = 34,
`1101` = 51, `1110` = 68, `1111` = mehr als 68 Slots [ETSI §21.5.4 Tab. 21.93].

#### 3.5.2 MAC-END-HU (SCH/HU, ein Unterschlitz)

7 bit Kopf: `1` (type) + `fill bit indication` + `length-or-capacity` +
4 bit `length indication` **oder** 4 bit `reservation requirement`; danach bis **85 bit**
TM-SDU [ETSI §21.4.2.2 Tab. 21.44/21.45]. Die PDU trägt **keine Adresse** — die Zuordnung
zum Absender erfolgt allein über die Reservierung, in der sie gesendet wurde. Für die
Software heißt das: die Fragment-Zusammensetzung muss den Absender aus dem
Startfragment mitführen, nicht aus dem Endfragment lesen (§3.11).

#### 3.5.3 MAC-DATA, MAC-FRAG, MAC-END (SCH/F, Vollschlitz)

| PDU | Kopflänge | max. TM-SDU (SCH/F) | Beleg |
|---|---:|---:|---|
| MAC-DATA (SSI) | 37 bit | 231 bit | [ETSI §21.4.2.3 Tab. 21.46/21.47] |
| MAC-DATA (Event Label) | 23 bit | 245 bit | dito |
| MAC-FRAG | 4 bit | 264 bit | [ETSI §21.4.2.4 Tab. 21.48/21.49] |
| MAC-END | 10 bit | 258 bit | [ETSI §21.4.2.5 Tab. 21.50/21.51] |

MAC-END im Uplink hat ein 6-bit-Feld, das **entweder** Länge **oder**
Reservierungsbedarf trägt: Werte `000001₂`…`101110₂` sind Längen, Werte mit den
führenden Bits `11` tragen den Reservierungsbedarf in den vier unteren Bits
[ETSI §21.4.2.5]. Die Software muss diese Unterscheidung treffen, sonst liest sie einen
Kapazitätswunsch als Länge.

Die Offsets, mit denen V1 die Fortsetzungsfragmente aneinanderhängt, sind genau diese
Kopflängen: MAC-FRAG ab Bit 4, MAC-END ab Bit 10
[CODE rtl/rx/tetra_ul_schf_reassembly.v:252, sw/tetra_ul_reassembly.c:97].

### 3.6 Adressierungsarten und Nutzungsmarkierung

**Downlink (MAC-RESOURCE)** [ETSI §21.4.3.1 Tab. 21.55; die Tabelle führt für das Feld
„Address" genau die Breiten 34/30/24/10 auf]:

| Wert | Art | Adressbreite | in V2 Stufe 1 |
|---|---|---:|---|
| `000` | Null-PDU | 0 | ja (Leerlauf-Füller, §3.4.2) |
| `001` | SSI | 24 | ja |
| `010` | Event Label | 10 | nein |
| `011` | USSI | 24 | Empfang tolerieren, nicht senden |
| `100` | SMI | 24 | nein |
| `101` | SSI + Event Label | 34 | nein |
| `110` | SSI + Usage Marker | 30 | ja (rufgebundene PDUs) |
| `111` | SMI + Event Label | 34 | nein |

**MAC-D-BLCK hat kein Adressart-Feld.** Diese PDU trägt fest ein **10-bit Event Label**
und kennt weder Adressart noch Power-Control-, noch Channel-Allocation-Flag; ETSI schließt
für sie ausdrücklich aus: SSI-/SMI-Adressierung, Fragmentierung, Quittung des
Zufallszugriffs, Vergabe von Event Label oder Nutzungsmarkierung, Leistungsregelung,
Kanalzuweisung und Null-PDU [ETSI §21.4.3.4 Tab. 21.61]. Die Tabelle oben und R-06-16
gelten deshalb **nur** für MAC-RESOURCE. V2 Stufe 1 sendet MAC-D-BLCK nicht — sie setzt
Event-Label-Adressierung voraus, die in der Tabelle oben mit „nein" geführt ist. Sie belegt
denselben MAC-PDU-Typ (`11` + Subtyp `0`) wie MAC-U-SIGNAL [ETSI §21.4.3.4]; ein Empfänger
unterscheidet beide über den Kanal.

**Uplink (MAC-ACCESS / MAC-DATA)**: 2 bit, `00` = SSI, `01` = Event Label (10 bit Adresse),
`10` = USSI, `11` = SMI [ETSI §21.4.2.1]. Der Empfänger in Software akzeptiert alle vier,
behandelt aber nur `00`/`10` als Teilnehmeradresse und zählt die übrigen (R-06-21).

**Nutzungsmarkierung (Usage Marker).** Bei `address type = 110` folgen der 24-bit-SSI
6 bit Nutzungsmarkierung; damit ist der Adressblock 30 bit breit und der Grundkopf 46 bit
[ETSI §21.4.3.1; V1 rechnet identisch, CODE
rtl/lmac/tetra_mac_resource_dl_builder.v:358]. Der so zugewiesene Wert ist **derselbe**,
der anschließend im AACH des Verkehrsschlitzes als `UMt` erscheint
[ETSI §21.4.7.2 Tab. 21.82: *„UMt is the traffic usage marker, assigned in the
MAC-RESOURCE PDU which allocated the channel"*]. Der Feld-für-Feld-Vergleich bestätigt das
messbar: `usage_marker = 11` in der rufaufbauenden PDU, `UMt = 11` im AACH desselben
Zeitschlitzes [GOLD, `docs/local_cell_decode/DIFF_vs_reference.md:74`; AACH-Muster
`0x32CB`, §3.8.3].

Wertebereich: `0` = UMx (unallocated), `1` = UMa (assigned control), `2` = UMc (common
control), `3` = UMr (common and assigned control) sind vorbelegt und dürfen **nicht** als
Verkehrsmarkierung vergeben werden; `UMt ∈ 4…63` [ETSI §21.4.7.2].

### 3.7 Längenangabe und Füllbits — normativ

Diese vier Regeln sind so formuliert, dass sie nicht falsch implementierbar sind. In V1 ist
jede einzelne mindestens einmal verletzt worden.

**F1 — Die Präsenz-Flags sind Teil des Kopfes, nicht des Optionalteils.**
`power control flag`, `slot granting flag`, `channel allocation flag` werden **immer**
gesendet, in dieser Reihenfolge, direkt hinter dem Adressblock. Nachrechenbarer Beleg: die
Mindest-Kopflänge des MAC-RESOURCE bei Event-Label-Adresse und ohne Optionalfelder ist
**29 bit** [ETSI §21.4.3.1] = 2+1+1+2+1+6+3+10 = 26 Feldbits **plus 3 Flagbits**. Wer die
Flags weglässt, verschiebt die gesamte TM-SDU um 3 bit; der Empfänger liest dann einen
falschen LLC-Typ. Genau dieser Fehler ist in V1 aufgetreten und im Modulkopf
dokumentiert [CODE rtl/lmac/tetra_mac_resource_dl_builder.v:14-18].

**F2 — Die Flag-Werte gehören der PDU-Klasse, nicht dem Encoder.** V1 verdrahtet
`slot_granting_flag` im gemeinsamen Baupfad hart auf 1 für alle nicht-CMCE-PDUs
[CODE rtl/lmac/tetra_dl_pdu_builder.v:165]. Das ist für die Anmelde-Bestätigung richtig
(§3.4.5) und für einen Zellrundspruch an die Broadcast-Adresse sinnlos. In V2 kommt der
Wert aus der Klassentabelle; der Encoder hat keinen Default.

**F3 — Die Längenangabe deckt Kopf **und** TM-SDU der **eigenen** PDU.**
`LI_Oktette = ceil((Kopfbits + TM-SDU-Bits) / 8)`. Sie deckt **nicht** den MAC-Block und
**nicht** eine angehängte zweite PDU. Bei Assoziation trägt jede PDU ihre eigene
Längenangabe, und die nächste PDU beginnt unmittelbar hinter der durch die Längenangabe
bezeichneten Grenze [ETSI §23.4.3.3]. V1 rechnet die Länge korrekt
[CODE rtl/lmac/tetra_mac_resource_dl_builder.v:362-364], berechnet aber
`fill bit indication` aus der Oktett-Ausrichtung statt aus der Existenz von Füllbits
[CODE …:562] — was in der Praxis dasselbe ergibt, solange die Länge auf das nächste Oktett
aufgerundet wird, und genau dann falsch wird, wenn die Länge größer als der Inhalt gesetzt
wird.

**F4 — Füllbits und Blockabschluss.** Reihenfolge, ohne Ausnahme:

```
1. Nutzinhalt der PDU (Kopf + TM-SDU)
2. wenn Bitzahl < LI·8:  ein Bit '1', danach '0' bis LI·8        → fill bit indication = 1
   wenn Bitzahl = LI·8:  nichts                                  → fill bit indication = 0
3. weitere assoziierte PDUs, jede nach 1.–2.
4. wenn ≥ 16 bit frei: 16-bit-Null-PDU (address type 000, LI = 2)
5. Restkapazität: ein Bit '1', danach '0' bis Blockende
```

[ETSI §23.4.2.2 „Fill bit addition", §23.4.3.2 „Fill bit deletion", §23.4.3.3
„PDU dissociation"; bit-exakt bestätigt an [GOLD Burst #775 und #783], siehe §3.4.2]

**Was V1 hier falsch macht:** ist die PDU bereits oktett-ausgerichtet
(`fill bit indication = 0`), setzt V1 trotzdem ein einzelnes `1`-Bit direkt hinter die PDU
und emittiert **keine** Null-PDU [CODE rtl/lmac/tetra_mac_resource_dl_builder.v:786-787].
Der Empfänger entfernt dieses Bit nicht (die Anzeige steht auf 0) und liest es als Beginn
der nächsten MAC-PDU: `1x` ist im Downlink `10` = TMB-SAP-Broadcast oder `11` =
Supplementary. Der V2-Ablauf nach Schritt 4/5 hat dieses Loch nicht.

**Vorverschiebung bei kurzen Blöcken.** Ein codierter Halbschlitzblock (216 bit) muss im
432-bit-Nutzdatenbus der Sende-Warteschlange **MSB-ausgerichtet** liegen, weil der
Verteiler BKN1 aus den oberen 216 bit liest. V1 hat beide Varianten im Baum:
`tetra_pre_reply_slotgrant` schiebt korrekt nach oben
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:334], `tetra_pre_reply_blck` schiebt nach unten
[CODE rtl/lmac/tetra_pre_reply_blck.v:209]. Die Ausrichtungsregel ist in `04 §3.11`
normativ und gilt für alle Erzeuger — auch für das Grant-Magazin (§3.9.3).

### 3.8 AACH: ACCESS-ASSIGN

#### 3.8.1 Feldaufbau

Der AACH trägt genau eine PDU, ACCESS-ASSIGN, 14 bit, in **jedem** Downlink-Slot
[ETSI §21.4.7.2]:

```
info14[13:12]  Header             2 bit
info14[11: 6]  Field 1            6 bit
info14[ 5: 0]  Field 2            6 bit
```

`info14[13]` ist das zuerst gesendete Bit. Die 14 bit gehen unverändert in den RM(30,14)-
Encoder (`05`); die oberen 14 bit des entwürfelten 30-bit-Broadcast-Blocks sind wieder das
Infowort — an 399 Bursts der beiden Aufzeichnungen ohne eine Abweichung geprüft
[GOLD, eigene Auszählung über `dl_events.jsonl` beider Verzeichnisse].

**Header-Semantik, Frames 1…17** [ETSI §21.4.7.2 Tab. 21.82]:

| Header | Downlink-Nutzung | Uplink-Zugriffsrechte | Field 1 | Field 2 |
|---|---|---|---|---|
| `00` | common control | nur common | Zugriffsfeld 1 | Zugriffsfeld 2 |
| `01` | durch Field 1 definiert | common und assigned | DL-Nutzungsmarkierung | Zugriffsfeld |
| `10` | durch Field 1 definiert | nur assigned | DL-Nutzungsmarkierung | Zugriffsfeld |
| `11` | durch Field 1 definiert | durch Field 2 definiert | DL-Nutzungsmarkierung | UL-Nutzungsmarkierung |

**Header-Semantik, Frame 18** [ETSI Tab. 21.83]: Field 1 und Field 2 sind **immer**
Zugriffsfelder; nur bei Header `11` ist Field 1 die Verkehrs-Nutzungsmarkierung. Diese
Umschaltung ist der Grund, warum derselbe 14-bit-Wert in Frame 18 anders zu lesen ist als
in Frames 1…17.

**Zugriffsfeld** (6 bit) [ETSI §21.5.1 Tab. 21.86]:

```
Zugriffsfeld[5:4]  Zugriffscode      00=A 01=B 10=C 11=D
Zugriffsfeld[3:0]  Basis-Framelänge  0000 = reservierter Unterschlitz  (Code bedeutungslos)
                                     0001 = CLCH-Unterschlitz
                                     0010 = laufender Frame
                                     0011..1111 = 1,2,3,4,5,6,8,10,12,16,20,24,32 Unterschlitze
```

Enthält die PDU nur **ein** Zugriffsfeld, gilt: „reservierter Unterschlitz" reserviert
**beide** Unterschlitze; „CLCH-Unterschlitz" bedeutet Unterschlitz 1 = Linearisierung,
Unterschlitz 2 = reserviert [ETSI §23.5.1.4.2]. Enthält die PDU **kein** Zugriffsfeld
(Verkehr im Uplink), sind beide Unterschlitze reserviert. „Assigned only" auf dem
Kontrollkanal wirkt für ein dort eingebuchtes Endgerät ebenfalls als reserviert.

#### 3.8.2 Ableitungsregel (`tetra_aach_info`)

**Schnittstelle**, alle Signale in `clk_sys`:

| Signal | Breite | Richtung | Bedeutung |
|---|---:|---|---|
| `clk_sys`, `rst_n_sys` | 1 | in | Takt, Reset (active-low, synchron deassertiert) |
| `tn_sys` | 2 | in | Zeitschlitz des **gestageten** Slots, 0-basiert (`TS1 (ETSI) = tn=0`) |
| `fn_sys` | 5 | in | Framenummer 0…17 (`FN18 (ETSI) = fn=17`) |
| `mn_sys` | 6 | in | Multiframe-Nummer 0…59 |
| `content_sys` | 3 | in | Inhaltsklasse dieses Slots vom Burst-Verteiler (`04 §3.4`), Codierung und Ableitung unten |
| `is_mcch_sys` | 1 | in | `tn_sys == cfg_mcch_tn_sys` |
| `umt_sys` | 6 | in | Nutzungsmarkierung dieses Verkehrsschlitzes, 0 = unbelegt |
| `ul_state_sys` | 2 | in | `00` unbelegt, `01` Verkehr, `10` assigned-Zugriff, `11` reserviert |
| `resv_active_sys` | 1 | in | Reservierungsfenster offen (von `tetra_ul_grant`) |
| `resv_pattern_sys` | 2 | in | `00` beide Unterschlitze, `01` nur SSN1, `10` nur SSN2 |
| `cfg_access_field_sys` | 6 | in | Zugriffsfeld für Zufallszugriff, Default `001001` |
| `cfg_f18_clch_all_sys` | 1 | in | 1 = CLCH in allen Frame-18-Nicht-MCCH-Slots anbieten |
| `info14_sys` | 14 | out | registriert, gültig ab dem Staging-Punkt des Slots |

**Inhaltsklassen (`content_sys`) — diese Enumeration ist hier normativ.** Die Rohfelder des
Zeitplan-Eintrags (`payload_class`, `payload_idx`, `burst_type`, `ndb2`, `enable`) stehen in
`04 §3.3.2`, die Auswahlpfade des Verteilers in `04 §3.4`. `tetra_burst_dispatcher` gibt
`content_sys[2:0]` mit genau dieser Codierung aus; die Zuordnung Pfad → Wert ist in `04 §3.4`
als Tabelle geführt und **verweist** hierher (P2). Alle dafür nötigen Größen liegen im
Verteiler bereits an.

| `content_sys` | Klasse | Ableitung im Verteiler (`04 §3.4` Auswahlpfad / `04 §3.3.2` Eintragsfeld) |
|---:|---|---|
| `0` | SB/BSCH | `build_burst_type_sys = 1` (Eintragsbit `[5:4]` = `01`) — unabhängig vom Pfad |
| `1` | Broadcast-Leerlauf (BNCH + Begleiter) | statischer Pfad (`04 §3.4` Rang 3) ∧ `burst_type = NDB` ∧ `payload_idx ∈ {2, 4}` |
| `2` | Signalisierung SCH/F | Grant-Override oder Queue-Pfad (`04 §3.4` Rang 0/2) ∧ `build_ndb2_sys = 0` |
| `3` | Signalisierung SCH/HD (zwei Halbblöcke) | Grant-Override oder Queue-Pfad ∧ `build_ndb2_sys = 1` |
| `4` | Verkehr Vollschlitz | Persist-Pfad (`persist_valid[tn]`, `04 §3.4` Rang 1) ∧ `build_ndb2_sys = 0` |
| `5` | Verkehr gestohlen, eine Hälfte SCH/HD | Persist-Pfad ∧ `build_ndb2_sys = 1` |
| `6` | unbelegt | `enable = 0`, oder statischer Pfad mit `payload_idx = 7`, oder kein Pfad aktiv |

[ANNAHME — Festlegung für V2: die Klassen fassen die Pfade aus `04 §3.4` auf genau die
Unterscheidungen zusammen, die der AACH braucht; V1 hat keinen solchen Ausgang.] Klasse `5`
setzt das Downlink-Stehlen aus §3.3.2 voraus: V1s Filler-Pfad erzwingt `ndb2 = 0`; der
Persist-Pfad in `04 §3.4` Rang 1 lässt `ndb2 = persist_steal[tn]` zu und macht die Klasse
damit erreichbar. Der Wert `7` ist reserviert, darf nicht
getrieben werden und wird vom Generator wie `6` behandelt.

**Auswahlreihenfolge** — die erste zutreffende Zeile gewinnt:

Kurzschreibweisen: `clch_phase` = `(mn + tn) mod 4 = 1` (§3.2), `AF` = `cfg_access_field`,
`RSV` = `000000` (reservierter Unterschlitz), `CLCH` = `000001`.

| # | Bedingung | Header | Field 1 | Field 2 | ergibt (Defaults) |
|---:|---|---|---|---|---|
| 1 | `fn=17 ∧ ¬is_mcch ∧ ul_state=00 ∧ (clch_phase ∨ cfg_f18_clch_all)` | `00` | `CLCH` | `RSV` | `0x0040` |
| 2 | `fn=17 ∧ ¬is_mcch ∧ ul_state=00` | `00` | `RSV` | `RSV` | `0x0000` |
| 3 | `fn=17 ∧ ¬is_mcch ∧ clch_phase` | `10` | `CLCH` | `AF` | `0x2049` |
| 4 | `fn=17 ∧ ¬is_mcch` | `10` | `AF` | `AF` | `0x2249` |
| 5 | `fn=17 ∧ is_mcch ∧ clch_phase` | `00` | `CLCH` | `AF` | `0x0049` |
| 6 | `is_mcch ∧ resv_active` | `00` | §3.9.5 | §3.9.5 | `0x0000`/`0x0009`/`0x0240` |
| 7 | `fn=17 ∧ is_mcch` | `00` | `AF` | `AF` | `0x0249` |
| 8 | `is_mcch` | `00` | `AF` | `AF` | `0x0249` |
| 9 | `content=4 ∧ ul_state=01` | `11` | `umt` | `umt` | `0x32CB` bei UMt = 11 |
| 10 | `content∈{2,3,5} ∧ ul_state=01` | `11` | UMa `000001` | `umt` | `0x304B` bei UMt = 11 |
| 11 | `content=4 ∧ ul_state=10` | `10` | `umt` | `AF` | `0x22C9` bei UMt = 11 |
| 12 | `content∈{1,2,3,5} ∧ ul_state=10` | `10` | UMa `000001` | `AF` | `0x2049` |
| 13 | sonst (unbelegt) | `11` | UMx `000000` | UMx `000000` | `0x3000` |

Die Frame-18-Zeilen (1…5 und 7 — Zeile 6 greift in der Gold-Aufzeichnung nie, dort gibt es
keine Mehrschlitz-Reservierung, §3.8.3) sind vollständig und ausnahmslos bestätigt: über
alle 408 Frame-18-Bursts trägt jeder Slot genau das Muster, das diese Reihenfolge
vorhersagt — `0x0049` ausschließlich bei `is_mcch ∧ clch_phase` (26 von 26), `0x0040` auf
allen Frame-18-Slots von TS2…TS4 ohne aktiven Ruf in **allen vier** Multiframe-Phasen
(je 20…26 Fälle), und auf dem Verkehrsschlitz mit aktivem Ruf `0x2049` genau in der
`clch_phase` (5 von 5) und `0x2249` in den anderen drei (15 von 15)
[GOLD, eigene Auszählung über `dl_events.jsonl`].

Zeile 1 vor Zeile 2 heißt: das Referenznetz bietet CLCH in **jeder** Frame 18 auf jedem
Nicht-Kontrollkanal-Zeitschlitz an, nicht nur an der vordefinierten Position. Der
ETSI-Zwang ist nur die vordefinierte Position [ETSI §23.4.5.1 Gl. 23.2]; weitere
Gelegenheiten anzubieten ist ausdrücklich erlaubt (*„The ACCESS-ASSIGN PDU on the AACH
shall indicate those uplink subslots that are available for common use for
linearization"*). `cfg_f18_clch_all = 1` ist deshalb der Default; mit `0` fällt Zeile 1 auf
die vordefinierte Position zurück und die übrigen Frame-18-Slots liefern `0x0000`.

Zeile 3 ist die Regel, die V1 fehlt: auch **während eines Rufs** bleibt die vordefinierte
Linearisierungsgelegenheit auf dem Verkehrsschlitz erhalten, indem Zugriffsfeld 1 den
CLCH-Wert trägt. In Frame 18 sind beide Felder Zugriffsfelder [ETSI Tab. 21.83], deshalb ist
`0x2049` dort etwas völlig anderes als in den Frames 1…17 (dort Zeile 12: DL assigned
control).

**Warum Zeile 6 vor den Zeilen 7 und 8 steht und alle drei vor 9…13:** die Reservierung ist
eine Zusage, die nicht zurückgenommen werden darf [ETSI §23.5.2.2.2: *„Capacity that has
been granted cannot be withdrawn by the BS"*]. Sie überstimmt deshalb auch den
Frame-18-Leerlauf des Kontrollkanals: stünde Zeile 7 vor Zeile 6, würde ein
Reservierungsfenster, das eine Frame 18 **ohne** `clch_phase` kreuzt, dort `0x0249` senden
und beide Uplink-Unterschlitze wieder für Zufallszugriff öffnen — und zwar in 3 von 4
Multiframes, weil `clch_phase` nur in einer von vier zutrifft. Der **einzige** zulässige
Vorrang vor der Reservierung ist Zeile 5, die vordefinierte Linearisierungsgelegenheit:
diese Slots überspringt das Endgerät ohnehin, und nur dort wird `hold_left` nicht
dekrementiert (§3.9.5) [ETSI §23.5.2.2.2]. In einer Frame 18 **ohne** `clch_phase` gilt
also Zeile 6 mit `0x0000`, und `hold_left` **wird** dekrementiert; das ist auch in Frame 18
korrekt lesbar, weil dort beide Felder Zugriffsfelder sind [ETSI Tab. 21.83] und `000000`
„reservierter Unterschlitz" bedeutet.

#### 3.8.3 Vollständige Musterliste

`H` = Header, `F1`/`F2` = Field 1 / Field 2. Alle Häufigkeiten aus eigener Auszählung der
entwürfelten Broadcast-Blöcke über **alle** Bursts beider Aufzeichnungen, nicht nur der
NDB-Bursts.

| Wert | H | F1 | F2 | Bedeutung (Frames 1…17) | Wann gesendet | Gold | Eigen |
|---|---|---|---|---|---|---:|---:|
| `0x0249` | 00 | A/8 sub | A/8 sub | DL common control, UL beide Unterschlitze offen | Kontrollkanal, Leerlauf | 1795 | 460 |
| `0x0009` | 00 | reserviert | A/8 sub | UL-Unterschlitz 1 reserviert, 2 offen | Kontrollkanal mit Ein-Unterschlitz-Zusage | 13 | 2 |
| `0x0000` | 00 | reserviert | reserviert | beide UL-Unterschlitze reserviert | Kontrollkanal während Mehrschlitz-Reservierung | 0 | 0 |
| `0x0240` | 00 | A/8 sub | reserviert | UL-Unterschlitz 2 reserviert | Zusage „zweiter Unterschlitz" | 0 | 0 |
| `0x0049` | 00 | CLCH | A/8 sub | Unterschlitz 1 Linearisierung, 2 offen | Kontrollkanal, Frame 18, `(MN+TN) mod 4 = 3` | 26 | 7 |
| `0x0040` | 00 | CLCH | reserviert | Unterschlitz 1 Linearisierung, 2 reserviert | Nicht-Kontrollkanal, Frame 18, unbelegt | 286 | 21 |
| `0x3000` | 11 | UMx | UMx | Slot in beiden Richtungen unbelegt | Verkehrsschlitz im Leerlauf | 4854 | 691 |
| `0x32CB` | 11 | UMt=11 | UMt=11 | Verkehr in beiden Richtungen | aktive Sprechphase | 180 | 235 |
| `0x2049` | 10 | UMa | A/8 sub | DL assigned control, UL assigned-Zugriff | Verkehrsschlitz mit gehaltenem Kanal ohne Sprache | 156 | 299 |
| `0x22C9` | 10 | UMt=11 | A/8 sub | DL Verkehr, UL assigned-Zugriff | Übergang beim Sprecherwechsel | 11 | 104 |
| `0x304B` | 11 | UMa | UMt=11 | DL assigned control, UL Verkehr | Slot, in dem die BS den Sprecher freigibt | 2 | 0 |
| `0x2249` | 10 | A/8 sub | A/8 sub | Frame 18: beide UL-Unterschlitze assigned-Zugriff | Verkehrsschlitz, Frame 18, Ruf aktiv | 15 | 57 |
| `0x33CF` | 11 | UMt=15 | UMt=15 | Verkehr, Nutzungsmarkierung 15 | wie `0x32CB`, anderer UMt | — | — |

[GOLD `docs/reference_decode/dl_events.jsonl` (7338 Bursts), eigene Aufzeichnung
`docs/local_cell_decode/dl_events.jsonl` (1876 Bursts)]. `0x33CF` ist der V1-Default für
Sprachslots [CODE sw/tetra_hal.h:362] und kommt in keiner der beiden Aufzeichnungen vor.
`0x0000` ist air-verifiziert als Halte-Muster der UL-Fragmentkette
[CODE rtl/tx/tetra_aach_encoder.v:244-252, MESS 2026-06-10], aber **nicht** in der
Gold-Aufzeichnung enthalten — dort gibt es keine UL-Mehrschlitz-Reservierung. Der
V1-Kommentar, der `0x0000` als „Gold-Referenz" bezeichnet, ist insoweit nicht gedeckt.
`0x0240` ist aus [ETSI Tab. 21.86 + 21.96] abgeleitet [ANNAHME — nie gesendet, nie
gemessen; nötig, sobald ein zweiter Unterschlitz zugesagt wird].

#### 3.8.4 Zwei Muster, die V2 anders erzeugen muss

Die Raten pro Sekunde in `docs/local_cell_decode/DIFF_vs_reference.md:196-210` zeigen zwei
deutliche Abweichungen. Die Ursache liegt nicht in der Rate, sondern darin, **auf welchem
Burst** das Muster landet:

| Muster | Gold: Bursttyp | Eigen: Bursttyp |
|---|---|---|
| `0x32CB` (Verkehr/Verkehr) | 167 × NDB1, 13 × NDB2, **0 × SB** | 18 × NDB1, **217 × SB** |
| `0x2049` (assigned control) | 151 × NDB2, 5 × SB (Frame 18) | 6 × NDB1, **293 × SB** |
| `0x22C9` (Übergang) | 11 × NDB2 | 14 × NDB1, **90 × SB** |

[GOLD/MESS, eigene Auszählung über beide `dl_events.jsonl`]

In der Gold-Aufzeichnung ist der AACH **immer konsistent mit dem Burst, der ihn trägt**:
Verkehr wird nur auf einem Vollschlitz-NDB beworben, „assigned control" nur auf einem
Halbschlitz-NDB, und der Leerlauf des Verkehrsschlitzes wird als SB mit `0x3000`
gesendet. In der eigenen Aufzeichnung bewirbt die Mehrheit der Verkehrsmuster einen
Synchronisationsburst — das Endgerät wird auf einen Verkehrskanal verwiesen, in dem kein
Verkehrsblock steht.

**Ursache in V1, strukturell:** der Slotinhalt kommt aus der Zeitplan-Tabelle
(`04 §3.3`), das AACH-Muster aus vier von der Software geschriebenen Registern, die je
Zeitschlitz einen Wert festhalten [CODE sw/tetra_hal.h:343-346,
rtl/tx/tetra_aach_encoder.v:257-263, sw/tetra_call_fsm.c:184-185, :201]. Zwei
Wahrheiten für denselben Slot, die auseinanderlaufen, sobald der Zeitplan etwas anderes
sagt als die Rufphase.

**V2-Auflösung:** R-06-04/R-06-05. `tetra_aach_info` bekommt die **Inhaltsklasse desselben
Slots** als Eingang und kann strukturell kein Verkehrsmuster auf einen SB-Slot legen —
Zeilen 9…12 der Tabelle in §3.8.2 sind an `content_sys` gebunden, Zeile 13 fängt alles
übrige ab. Die Software liefert nur noch `umt_sys` und `ul_state_sys`.

Zusätzlich fällt damit die Frage weg, ob ein Leerlauf-Verkehrsschlitz überhaupt als SB
gesendet werden soll: solange der Zeitplan dort SB vorsieht, ist die Inhaltsklasse `0`
und der AACH ist `0x3000` — genau das Gold-Verhalten.

### 3.9 Die Uplink-Zuweisung — `tetra_ul_grant`

#### 3.9.1 Was V1 gemessen falsch gemacht hat

Zwei getrennte Befunde, beide relevant für den Entwurf:

1. **V1-Arbeitsstand (funktioniert, aber verletzt den Schnitt):** die Zuweisung wird von
   `frag1_pulse` ausgelöst, einem Signal aus dem **RTL-Parse** des empfangenen Bursts, und
   adressiert die dort geparste ISSI [CODE rtl/lmac/tetra_pre_reply_slotgrant.v:55-60,
   :262-269]. Zusätzlich filtert das RTL auf zwei MM-PDU-Typen [CODE …:135]. Das ist
   inhaltsabhängig und in V2 nicht möglich, weil der Parse in Software liegt.
2. **V1-Umbauversuch (gescheitert):** mit dem Parse in Software wanderte die
   Zuweisungs-Entscheidung mit; sie kam über eine asynchrone Mailbox in die geteilte
   Signalisierungs-Warteschlange zurück. Ergebnis: keine sendezeitpunkt-feste Zuweisung,
   Wiederholungen des Endgeräts erzeugten weitere Zuweisungen, die Warteschlange lief über,
   die Anmeldebestätigung kam nicht mehr durch [MESS 2026-07-11, `00 §3.4`]. Eine
   Ratenbegrenzung hat die Symptome gemildert, nicht die Ursache.

Der V2-Entwurf greift beide Punkte an: die Auslösung wird inhaltsunabhängig, und die
Zuweisung verlässt die geteilte Warteschlange (R-06-13).

#### 3.9.2 Das Zeitbudget — gemessen, nicht geschätzt

Aus der Gold-Aufzeichnung ist die Vorantwort-Sequenz vollständig rekonstruierbar. Die
13 Kontrollkanal-Slots mit dem Muster `0x0009` bilden **sechs Paare im Abstand von genau
2 Frames** innerhalb derselben Multiframe — (FN02, FN04), (FN05, FN07), (FN07, FN09),
(FN01, FN03), (FN08, FN10), (FN14, FN16) — plus einen Einzelfall (Burst #5311). Der erste
Slot eines Paares ist stets NDB2 (Vorantwort, LI = 7), der zweite NDB1 (Bestätigung,
LI = 21 bzw. 16) [GOLD, eigene Auszählung über `dl_events.jsonl`].

Zusammen mit den Uplink-Abständen (Fragment 1 → Fragment 2 = 1 Frame, Fragment 2 →
Quittung = 2 Frames) [GOLD `docs/reference_decode/action_reaction.md:23-40`] und der Regel
`granting_delay = 0000₂` = „gleichnummerierter Uplink-Slot derselben Frame"
[ETSI §23.5.2.2.2] ergibt sich genau eine widerspruchsfreie Zeitlage:

```
DL TS1 FN_n     ── Zufallszugriff wird empfangen: UL TS1 FN_n (2 Slots später)
DL TS1 FN_n+1   ── Vorantwort mit Grant, AACH 0x0009  →  UL TS1 FN_n+1 SSN1 reserviert
                   dort sendet das MS MAC-END-HU
DL TS1 FN_n+3   ── Bestätigung, AACH 0x0009           →  UL TS1 FN_n+3 SSN1 reserviert
                   dort sendet das MS die LLC-Quittung
```

Daraus das Budget für die Zuweisung: der Uplink-Slot beginnt 2 Zeitschlitze nach dem
gleichnummerierten Downlink-Slot [ETSI §23.5.1.4.2 NOTE]. Ein Zufallszugriff in
Unterschlitz 1 endet 28,33 + 7,08 = **35,4 ms** nach Beginn von `DL TS1 FN_n`; der
Downlink-Slot `DL TS1 FN_n+1` beginnt bei **56,67 ms**. Bleiben **21,3 ms**; bei
Zufallszugriff in Unterschlitz 2 **14,2 ms** [ANNAHME — Rechnung aus den
Zeitkonstanten in `00 §2.1`, nicht gemessen].

Gegenwert: die gemessene Latenz eines Software-Umlaufs über die Hauptschleife liegt in V1
bei ~133 ms [MESS 2026-05-20, NUB-Latenz 133 ms über 3 PTT-Läufe]. Ein Faktor 6…9 über dem Budget. Das ist
die quantitative Begründung für R-00-01.

Toleranzreserve: das Endgerät verwirft ein angefangenes Fragment erst nach dem
Fragmentierungs-Timeout `T.202` = **9 Downlink-Signalisierungsframes** ≈ 510 ms und
kehrt erst nach `T.206` = **18 Frames** ≈ 1,02 s zum Zufallszugriff zurück
[ETSI Anhang B.1]. Eine Zuweisung, die einen Frame später kommt, ist also nicht verloren —
eine Zuweisung, die **nicht slot-fest** ist und deren Wiederholungen unbegrenzt sind, ist
das Problem. Genau darauf ist der Entwurf ausgelegt.

#### 3.9.3 Mechanismus

**Auslöseereignis (hardware-lokal, inhaltsunabhängig).** `ul_cb_detect_sys` aus
`03 §3.4` — der UL-Sync-Korrelator hat einen Control-Uplink-Burst gefunden — zusammen mit
`ul_cb_tn_sys` und `ul_cb_ssn_sys`. Gültig als Auslöser nur, wenn

```
ul_cb_tn_sys == cfg_mcch_tn_sys   ∧   der betroffene Unterschlitz war im AACH
                                       dieses UL-Slots als offen ausgewiesen
```

Die zweite Bedingung ist der Kern der Aufschaukelungs-Sperre: das Modul führt für den
zuletzt gestageten Kontrollkanal-AACH mit, welche Unterschlitze offen waren
(`open_ssn1`, `open_ssn2`, 2 Register). Ein Burst in einem **reservierten** Unterschlitz
ist die Nutzung einer bereits erteilten Zusage und löst keine neue aus. Damit ist die
maximale Auslöserate durch die Rate der **offenen** Zufallszugriffs-Gelegenheiten nach oben
begrenzt, und eine Zuweisung kann sich nicht selbst nachziehen.

Es wird **nicht** geprüft, ob der Burst dekodierbar war, ob er eine Kapazitätsanforderung
enthielt oder von welchem Teilnehmer er kam. Das ist die in R-00-02 bewusst gewählte
großzügige Seite.

**Magazin.** `MAG_ENTRIES = 4` Einträge, von der Software beschrieben:

| Feld | Breite | Inhalt |
|---|---:|---|
| `coded` | 216 | fertig codierter SCH/HD-Block der Zuweisungs-PDU (`05`), MSB-ausgerichtet |
| `cap_alloc` | 4 | Kopie des Feldes `capacity_allocation` aus derselben PDU |
| `valid` | 1 | Belegung |

Warum `cap_alloc` doppelt: die Hardware braucht die Haltedauer, darf den codierten Block
aber nicht parsen (P1). Die Software schreibt den Wert redundant mit; ein Widerspruch
zwischen Feld und codiertem Inhalt ist ein Software-Fehler und in `14` als Testvektor
abzudecken.

Reihenfolge: FIFO, Kopf = ältester gültiger Eintrag, Überlauf überschreibt den ältesten
(`grant_mag_overwrite_cnt`). Die Software schreibt einen Eintrag, sobald sie aus einem
dekodierten Uplink-Burst weiß, dass ein Teilnehmer Kapazität braucht — für einen bereits
eingebuchten Teilnehmer kann sie den Eintrag beliebig lange vorher bereitstellen, dann
liegt **kein** Software-Anteil im Zeitpfad.

**Ablauf (Zustandsmaschine, `clk_sys`).**

| Zustand | Aktion | Übergang |
|---|---|---|
| `S_IDLE` | `resv_active = 0` | gültiger Auslöser → `S_ARMED`, `emit_left = GRANT_REPEAT`, `arm_wait = 0` |
| `S_ARMED` | am Staging-Punkt des nächsten Kontrollkanal-Slots: Magazin-Kopf gültig? | ja → aussenden, `emit_left--`, `hold_left` laden, `S_WINDOW`; nein → `arm_wait++`, `arm_wait = GRANT_ARM_TIMEOUT` → `grant_starved_cnt++`, `S_IDLE` |
| `S_WINDOW` | `resv_active = 1`, `resv_pattern` nach §3.9.5; je Kontrollkanal-Slot ohne `clch_phase`-Frame-18-Ausnahme `hold_left--` | UL-Burst im reservierten Unterschlitz → `grant_used_cnt++`, Magazin-Kopf freigeben, `S_COOL`; `hold_left = 0` ∧ `emit_left > 0` → `grant_regrant_cnt++`, `S_ARMED`; `hold_left = 0` ∧ `emit_left = 0` → Magazin-Kopf freigeben, `S_COOL` |
| `S_COOL` | `resv_active = 0`, `GRANT_GAP` Frame-Pulse zählen | Ablauf → `S_IDLE` |

Auslöser außerhalb von `S_IDLE` werden verworfen und an `grant_suppressed_cnt` gezählt.

**Aussenden** heißt: `grant_valid_sys = 1` für genau diesen Slot, `grant_blk1_sys` =
Magazin-Kopf, `grant_ndb2_sys = 1` (zwei Halbschlitzblöcke, NTS2), BKN2 bleibt der
Broadcast-Begleiter aus `04 §3.5.2`. Der Burst-Verteiler nimmt `grant_valid_sys` mit
höchster Priorität (§2.2).

**Der Trägerslot trägt seine Reservierung selbst.** `resv_active_sys` und
`resv_pattern_sys` werden **im selben Staging-Zyklus** gesetzt wie `grant_valid_sys`, nicht
einen Slot später. Sonst bewirbt der Slot, der die Zusage trägt, noch offenen
Zufallszugriff, und die zugesagte Kapazität ist im ersten Slot ungeschützt. Das
Referenznetz macht es so: der Slot mit der Vorantwort **ist** der Slot mit AACH `0x0009`
[GOLD #775]. Der verwandte V1-Fehler „AACH greift einen Frame zu spät" ist in
`04 §3.5.2` dokumentiert — dieselbe Falle, anderer Erzeuger.

**Warum die Zuweisung positionsunabhängig ist.** `granting_delay = 0000₂` bedeutet „im
gleichnummerierten Uplink-Slot derselben TDMA-Frame" [ETSI §23.5.2.2.2]. Der codierte
Block hängt damit **nicht** davon ab, in welchem Frame er ausgesendet wird — deshalb kann
die Hardware denselben Block wiederholen, ohne ihn neu zu codieren, und deshalb darf die
Software ihn beliebig lange vorher bereitstellen. Ein Grant mit `granting_delay ≠ 0` wäre
positionsabhängig und ist im Magazin **verboten**.

#### 3.9.4 Basis-Slot-Grant-Element

8 bit, `{capacity_allocation[3:0], granting_delay[3:0]}`, MSB zuerst
[ETSI §21.5.6 Tab. 21.96; V1 packt identisch, CODE
rtl/lmac/tetra_basic_slotgrant_encoder.v:49]:

| `capacity_allocation` | Zusage | Reservierungsdauer |
|---|---|---:|
| `0000` | erster Unterschlitz | 1 Kontrollkanal-Slot |
| `0001`…`1110` | 1, 2, 3, 4, 5, 6, 8, 10, 13, 17, 24, 34, 51, 68 Slots | = Slotzahl |
| `1111` | zweiter Unterschlitz | 1 Kontrollkanal-Slot |

`granting_delay`: `0000` = nächste Gelegenheit (V2: der einzige erlaubte Wert),
`0001`…`1101` = Anzahl Verzögerungs-Gelegenheiten, `1110` = erste Gelegenheit in der
nächsten Frame 18, `1111` = auf eine weitere Zuweisung warten (setzt nur `T.206` zurück).

In V1 belegt: `0x00` für die Anmeldung — dort ist der Wert kritisch, `0x30` bricht die
Einbuchung nachweislich ab („MS sieht die BS, kann sich aber nicht einbuchen")
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:143-149, MESS 2026-06-10] — und `0x30`
(= 3 Slots, keine Verzögerung) für die
Fortsetzungskette einer langen Kurznachricht [CODE …:269, :304-309]. Beide Werte werden
in V2 übernommen; sie sind die einzigen air-verifizierten.

#### 3.9.5 Mehrschlitz-Reservierung

Das Feld, das die Kapazitätszusage steuert, ist `capacity_allocation` im
Basis-Slot-Grant-Element; der Wert, der mehrere Zeitschlitze hält, ist jeder Wert
`0001`…`1110`. V1 verwendet `0x30`, also `capacity_allocation = 0011` = **3 Slots**
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:145-149].

`tetra_ul_grant` leitet daraus ab:

```
hold_left     = LUT_SLOTS[cap_alloc]           (16 Einträge, max. 68, gedeckelt auf GRANT_HOLD_MAX)
resv_pattern  = 00  wenn cap_alloc ∈ 0001..1110   (beide Unterschlitze reserviert)
                01  wenn cap_alloc = 0000         (nur SSN1)
                10  wenn cap_alloc = 1111         (nur SSN2)
```

Daraus die AACH-Field-Werte für Zeile 6 in §3.8.2:

| `resv_pattern` | Field 1 | Field 2 | ergibt |
|---|---|---|---|
| `00` | reserviert `000000` | reserviert `000000` | `0x0000` |
| `01` | reserviert `000000` | `cfg_access_field` | `0x0009` |
| `10` | `cfg_access_field` | reserviert `000000` | `0x0240` |

**Frame-18-Sprungregel (normativ).** Belegte Slots einer Mehrschlitz-Zusage sind
aufeinanderfolgende Slots auf diesem Uplink-Kanal, **außer** den Frame-18-Slots mit
vordefinierter Linearisierungsgelegenheit — die überspringt das Endgerät
[ETSI §23.5.2.2.2]. `tetra_ul_grant` muss identisch springen: ist der gestagete Slot ein
Frame-18-Slot mit `clch_phase`, gewinnt Zeile 5 der AACH-Tabelle (CLCH-Muster), und
`hold_left` wird **nicht** dekrementiert. Ein Frame-18-Slot **ohne** `clch_phase` ist
dagegen ein normaler belegter Slot der Zusage: dort gewinnt Zeile 6 der AACH-Tabelle
(`0x0000`, in Frame 18 als „beide Unterschlitze reserviert" zu lesen, [ETSI Tab. 21.83])
und `hold_left` **wird** dekrementiert. V1 dekrementiert pro Leerlauf-Frame ohne diese
Ausnahme [CODE rtl/tx/tetra_aach_encoder.v:251-252]; bei einer 3-Slot-Zusage, die eine
Frame 18 kreuzt, endet die Reservierung damit einen Slot zu früh.

Ohne Mehrschlitz-Reservierung bricht die Fortsetzungskette nach dem ersten Fragment ab —
in V1 gemessen und der Grund für den Einbau des Halte-Mechanismus
[CODE rtl/tx/tetra_aach_encoder.v:73-81, MESS 2026-06-10]. Deshalb ist sie hier
Grundfunktion und kein Zusatz (R-06-14).

#### 3.9.6 Kosten

| Größe | Wert | Herkunft |
|---|---|---|
| Kontrollkanal-Slots pro Sekunde | 17,65 (1 je TDMA-Frame) | [ETSI §4.5.2]; Gold: 1834 Slots / 103,98 s = 17,64 [GOLD] |
| Kosten einer Aussendung | 1 × BKN1 des Kontrollkanals = 5,7 % der BKN1-Kapazität einer Sekunde | Rechnung [ANNAHME] |
| Kosten einer Ein-Unterschlitz-Reservierung | 1 von 35,3 Zufallszugriffs-Unterschlitzen pro Sekunde | Rechnung [ANNAHME] |
| Kosten einer 3-Slot-Reservierung | 6 von 35,3 Unterschlitzen | Rechnung [ANNAHME] |
| Referenznetz-Anteil reservierter Kontrollkanal-Slots | **0,71 %** (13 von 1834) | [GOLD] |

Das Referenznetz gibt damit die Zielgröße vor: der Anteil der Kontrollkanal-Slots mit
Reservierungsmuster soll unter **5 %** bleiben (§5.4).

#### 3.9.7 Schnittstelle

| Signal | Breite | Richtung | Bedeutung |
|---|---:|---|---|
| `clk_sys`, `rst_n_sys` | 1 | in | Takt / Reset |
| `tn_sys`, `fn_sys`, `mn_sys` | 2/5/6 | in | Zeitbasis des gestageten Slots (`04 §3.1`) |
| `slot_stage_sys` | 1 | in | 1-Zyklus-Puls: Staging-Punkt des nächsten Slots |
| `frame_tick_sys` | 1 | in | 1-Zyklus-Puls je TDMA-Frame (Sperrzeit-Zähler) |
| `ul_cb_detect_sys` | 1 | in | Control-Uplink-Burst erkannt (`03`) |
| `ul_cb_tn_sys` | 2 | in | Zeitschlitz dieses Bursts |
| `ul_cb_ssn_sys` | 1 | in | 0 = SSN1, 1 = SSN2 |
| `cfg_mcch_tn_sys` | 2 | in | Kontrollkanal-Zeitschlitz, CDC-resynchronisiert |
| `cfg_grant_en_sys` | 1 | in | Gesamtfreigabe |
| `cfg_grant_repeat_sys` | 3 | in | `GRANT_REPEAT`, 1…7, Default 2 |
| `cfg_grant_gap_sys` | 6 | in | `GRANT_GAP` in Frames, Default 4 |
| `cfg_grant_hold_max_sys` | 7 | in | `GRANT_HOLD_MAX`, Default 8 |
| `cfg_grant_arm_to_sys` | 4 | in | `GRANT_ARM_TIMEOUT` in Slots, Default 4 |
| `mag_wr_en_sys`, `mag_wr_idx_sys`, `mag_wr_word_sys`, `mag_wr_data_sys` | 1/2/3/32 | in | Magazin-Schreibport (Adressen `07 §3.1.6`, `REG_GRANT_MAG_INDEX`/`_DATA`) |
| `mag_wr_cap_alloc_sys`, `mag_wr_commit_sys` | 4/1 | in | Kapazitätsfeld + Gültig-Setzen (`07 §3.1.6`, `REG_GRANT_MAG_CTRL`/`_GO`) |
| `grant_valid_sys` | 1 | out | dieser Slot trägt die Zuweisung |
| `grant_blk1_sys` | 216 | out | codierter Block, MSB = erstes Bit auf der Luft |
| `grant_ndb2_sys` | 1 | out | konstant 1 (Halbschlitz-Format) |
| `resv_active_sys` | 1 | out | an `tetra_aach_info` |
| `resv_pattern_sys` | 2 | out | an `tetra_aach_info` |
| `grant_*_cnt_sys` | 16 je | out | Zähler nach §3.13 |

Pipeline: 2 Stufen zwischen `slot_stage_sys` und `grant_valid_sys`/`grant_blk1_sys`
(Kopfauswahl, Registerausgabe). Keine kombinatorische Kette vom Magazin zum
Burst-Builder.

**Ressourcen-Erwartung:** Magazin 4 × 216 bit in verteiltem RAM (28 Wörter × 32 bit)
≈ 60 LUT; Zustandsmaschine, Zähler, LUT_SLOTS, Reservierungslogik ≈ 140 LUT / 200 FF.
Gesamt **≈ 200 LUT / ≈ 220 FF / 0 BRAM / 0 DSP** [ANNAHME — Schätzung aus der
Registerzahl; V1-Vergleichswert für die funktional engste Entsprechung
`tetra_pre_reply_slotgrant` ohne den entfallenden PDU-Bauteil: 17 LUT / 315 FF
[BUILD 2026-06-20 `cur_hier_deep.rpt:156`]].

`tetra_aach_info` ist rein kombinatorisch plus Ausgangsregister: **≈ 90 LUT / ≈ 20 FF**
[ANNAHME; V1 `tetra_aach_encoder` einschließlich RM-Encoder und Verwürfler: 141 LUT /
120 FF, BUILD 2026-06-20 `cur_hier_deep.rpt:133`].

### 3.10 Zuordnung eines Uplink-Bursts zu seinem Zeitschlitz

Die Zuordnung ist in V2 die Grundlage für Sprachrouting (`12`) und
Reassembly-Fenster (`09`, `11`). Die MAC-Schicht braucht dafür je Burst folgende
Metadaten, im **selben** Mailbox-Transfer wie die Soft-Bits (R-00-04, Format in `07`):

| Feld | Breite | Quelle | Zweck |
|---|---:|---|---|
| `tn` | 2 | Zeitbasis zum Zeitpunkt des Sync-Ankers | Slot- und Rufzuordnung |
| `fn` | 5 | dito | Reassembly-Fenster, Frame-18-Erkennung |
| `mn` | 6 | dito | Reassembly-Fenster über Multiframe-Grenzen |
| `ssn` | 1 | Ankerposition relativ zur Uplink-Slotgrenze | MAC-ACCESS-Zuordnung, Auslösesperre §3.9.3 |
| `burst_type` | 2 | Korrelatorzweig | Erfassungszweig, **kein** logischer Kanal: `00` = Control Uplink Burst, `01` = Normal Uplink Burst, `10`/`11` reserviert (Belegung normativ `07 §3.4`) |
| `was_reserved` | 1 | `tetra_ul_grant` | Burst kam in reserviertem Unterschlitz an |

Die Zeitmessung selbst — wie der Anker in `(tn, fn, mn)` umgerechnet wird und welche
Toleranz gilt — steht in `08_TIMING`. Hier nur die Konsequenzen für die MAC-Schicht:

- **`burst_type` sagt nicht, welcher logische Kanal ankam.** Die Hardware kann nur
  unterscheiden, welcher Korrelatorzweig getroffen hat — x-Sequenz gegen NTS1 — und damit
  die Burstlänge (168 gegen 432 Soft-Werte). Welcher logische Kanal in einem
  Normal-Uplink-Burst steckt (TCH/S gegen SCH/F), ist eine **Software**-Entscheidung: sie
  fällt über den Reservierungszustand `resv_active[tn]`, den T-CTL selbst mit dem Erteilen
  der Reservierung setzt (`13 §3.2`). Eine Kanalzuordnung im Kopfwort würde verlangen, dass
  die Hardware den Uplink-Inhalt auswertet, und verstieße gegen `00` R-00-02 und gegen
  `03 §3.7`. Der Control Uplink Burst trägt in Stufe 1 stets SCH/HU, aber auch das ist eine
  Festlegung der Software über das Kanalinventar (§3.2), keine Aussage der Mailbox.
  Die Codepunkte `10₂`/`11₂` erzeugt die PL in Stufe 1 nicht; die Software verwirft sie
  definiert und zählt (`ul_burst_type_unsupported_cnt`, `13 §3.10.2`, `18` R-18-07).
- **Kein eigener Zeitgeber in der Software.** Die Reassembly-Timer `T0` laufen in
  Frame-Einheiten, gezählt aus den `(fn, mn)` der eintreffenden Bursts. V1 speist die
  Reassembly-Zeitgeber aus dem Frame-Takt der **Downlink-Empfangskette**: `frame_tick_sys`
  ist ein Puls auf jede Änderung von `frame_num_sys`, und `frame_num_sys` kommt aus
  `u_rx_chain` [CODE rtl/tetra_zynq_top.v:685-697, :577]; genau dieses Signal geht an
  `u_ul_demand_reassembly` und `u_ul_schf_reassembly`
  [CODE rtl/tetra_zynq_top.v:752, :837]. Bricht der DL-Empfang weg, bricht die
  UL-Zusammensetzung mit. V2 entkoppelt das über die Zeitstempel (`00 §3.5`).
- **`ssn` ist Pflicht, nicht optional.** Ohne Unterschlitz-Index kann die Software eine
  MAC-ACCESS nicht der Reservierung zuordnen, und `tetra_ul_grant` kann die
  Auslösesperre aus §3.9.3 nicht bilden. Der V1-Mailbox-Header liefert `slot_tn` und
  `burst_type` [CODE sw/tetra_ul_rx_mailbox.h:11-12]; `fn`, `mn`, `ssn` und `was_reserved`
  fehlen — das ist zu wenig.
- **Der Umweg über eine Stoppuhr entfällt.** V1 bestimmt den Uplink-Zeitschlitz aus einer
  Zykluszähler-Differenz und rechnet sie über eine Tabelle in einen ETSI-Zeitschlitz
  zurück [CODE sw/tetra_ts_map.h:77-95, MESS 2026-05-25]. Die Messwerte (22,50 / 36,67 /
  50,84 ms für TS2/TS3/TS4) bleiben als Plausibilitätsprüfung in `08` wertvoll, sind aber
  in V2 nicht mehr der Zuordnungsweg.

### 3.11 Fragment-Zusammensetzung in Software

Zwei Ketten, beide in `tetra_mac_reass.c`:

**Kette A — zwei Unterschlitze (Anmeldung, kurze Kurznachricht).**
MAC-ACCESS mit `fragmentation flag = 1` liefert die erste TM-SDU-Hälfte; MAC-END-HU
liefert die zweite. Der zusammengesetzte Körper ist
`ul0[tl_sdu_start…91] ++ ul1[7…91]`, MSB-first. Mit `tl_sdu_start = 30` (kein
Optionalfeld) ergibt das 62 + 85 = **147 bit**; ist ein Optionalfeld vorhanden, sind die
ersten 6 bit des ersten Teils MAC-Kopf und die Software überspringt sie anhand des
mitgeführten `optional field flag` [CODE rtl/rx/tetra_ul_demand_reassembly.v:15-21,
sw/tetra_ul_reassembly.c:41-62]. **V2-Präzisierung:** die Software schneidet den ersten
Teil bei `tl_sdu_start` und speichert **nur** die TM-SDU. Der V1-Umweg „immer 62 bit ab
Bit 30 speichern und später überspringen" ist die Ursache dafür, dass der Offset in zwei
Modulen und einem Metadatenbit dupliziert ist.

Zuordnung des Endfragments: MAC-END-HU trägt keine Adresse (§3.5.2). Die Zuordnung
erfolgt über den Absender des Startfragments **und** über `(tn, fn, mn, ssn)`: das
Endfragment muss im reservierten Unterschlitz derselben Zusage liegen. V1 ordnet allein
über die zuletzt gelatchte ISSI zu [CODE rtl/lmac/tetra_ul_mac_access_parser.v:366-372] —
bei zwei gleichzeitig fragmentierenden Endgeräten kann das das falsche Paar bilden.

**Kette B — reservierte Vollschlitze (lange Kurznachricht).**
MAC-ACCESS mit `fragmentation flag = 1` (Start) + N × MAC-FRAG (Nutzlast ab Bit 4) +
MAC-END (Nutzlast ab Bit 10), alle auf SCH/F in den reservierten Slots
[CODE rtl/rx/tetra_ul_schf_reassembly.v:10-13]. SCH/F trägt keine Adresse; die Zuordnung
ist implizit über die Reservierung. Deshalb ist `was_reserved` aus §3.10 nicht Komfort,
sondern die Zuordnungsgrundlage.

Zeitgeber: `T0` je Kette, in Frames, nach jedem Fragment neu gesetzt. Die V1-Modul-Defaults
sind 4 Frames für Kette B und 2 Frames für Kette A
[CODE rtl/rx/tetra_ul_schf_reassembly.v:38, rtl/rx/tetra_ul_demand_reassembly.v:67]; Kette A
läuft in V1 abweichend mit **1 Frame**, weil 2 Frames genau auf den Antwortzeitpunkt fielen
[CODE sw/tetra_hal.c:1794-1809, siehe `04 §3.5.3`]. **V2:** `T0` ist eine feste Konstante
(`REASS_T0_FRAMES`, §3.12) — kein Modul-Default, kein Register, kein
Konfigurationsschlüssel; der **Wert** ist normativ in `08 §3.5.2` festgelegt (9 Frames, ETSI
`T.202`) und für beide Ketten derselbe. Dieses Kapitel wiederholt ihn nicht (P2).

Gleichzeitigkeit: Kette A hat zwei Plätze, Ersetzen bei gleicher Adresse hat Vorrang vor
Neubelegung, Neubelegung vor Verwurf [CODE sw/tetra_ul_reassembly.c:28-36]. Diese
Reihenfolge bleibt; sie ist die einzige, bei der ein legitimer Wiederholversuch desselben
Endgeräts nicht als Verwurf zählt.

### 3.12 Steuergrößen (Vertrag gegenüber `07`)

Dieses Kapitel nennt die **Bedeutung**; Adressen und Bitlagen stehen in `07`. Konkret:
`MCCH_TN`, `ACCESS_FIELD` und `F18_CLCH_ALL` liegen in `REG_AACH_ACCESS_CFG`,
`SLOT_UMT[n]` und `SLOT_UL_STATE[n]` in `REG_SLOT_STATE_TSn`, die fünf `GRANT_*`-Größen in
`REG_UL_ASSIGN_CFG` und `GRANT_MAG[0..3]` im Fenster
`REG_GRANT_MAG_INDEX`/`_DATA`/`_CTRL`/`_GO` — alles `07 §3.1.5`/`§3.1.6`.

| Steuergröße | Richtung | Bedeutung | Default |
|---|---|---|---|
| `MCCH_TN` | SW → HW | Kontrollkanal-Zeitschlitz (ETSI 1-basiert in der Oberfläche, 0-basiert im RTL) | TS1 |
| `ACCESS_FIELD` | SW → HW | Zugriffsfeld für Zufallszugriff: Code + Basis-Framelänge | `001001` (Code A, 8 Unterschlitze) [GOLD] |
| `F18_CLCH_ALL` | SW → HW | CLCH in allen Frame-18-Nicht-Kontrollkanal-Slots anbieten | 1 [GOLD] |
| `SLOT_UMT[1..4]` | SW → HW | Nutzungsmarkierung je Zeitschlitz, 0 = unbelegt | 0 |
| `SLOT_UL_STATE[1..4]` | SW → HW | Uplink-Zustand je Zeitschlitz (unbelegt / Verkehr / assigned-Zugriff / reserviert) | unbelegt |
| `GRANT_EN` | SW → HW | Gesamtfreigabe der Zuweisung | **Rücksetzwert 0** (normativ `07 §3.1.6`, R-07-19: ohne Software-Initialisierung erteilt das PL keine Zuweisung). Die Software setzt ihn im Hochlauf auf 1 — `13 §3.1` Schritt S9 — und im Zuge der Ruhigstellung wieder auf 0 (S4) |
| `GRANT_REPEAT` | SW → HW | maximale Aussendungen je Auslösung | 2 |
| `GRANT_GAP` | SW → HW | Sperrzeit in Frames nach Fensterende | 4 |
| `GRANT_HOLD_MAX` | SW → HW | Deckel der Reservierungsdauer in Slots | 8 |
| `GRANT_ARM_TIMEOUT` | SW → HW | Slots, die auf einen Magazin-Eintrag gewartet wird | 4 |
| `GRANT_MAG[0..3]` | SW → HW | codierte Zuweisungs-PDU + `cap_alloc` + gültig | leer |
| `REASS_T0_FRAMES` | SW-intern, **feste Übersetzungskonstante** | Reassembly-Zeitgeber in Frames, **ein** Wert für beide Ketten aus §3.11 | Wert normativ in `08 §3.5.2` (9 Frames); dieses Kapitel legt ihn nicht fest. Kein Register (`07` führt keines) und kein Konfigurationsschlüssel (`13 §3.7`) — die Begründung für „fest" steht in `08 §3.5.2` |

**Was die Software ausdrücklich nicht setzt:** das einzelne Zuweisungs-Ereignis, das
AACH-Infowort, den Sendeslot einer Zuweisung, die Reservierungsdauer eines konkreten
Fensters (die folgt aus `cap_alloc`).

### 3.13 Zähler (P6, R-06-23)

Alle 16 bit, sättigend, AXI-lesbar unter eigenem Namen; die Adressen und die zugehörigen
Registernamen stehen in `07 §3.1.8`:

| Zähler | Inkrementiert bei |
|---|---|
| `grant_trigger_cnt` | gültiger Auslöser in `S_IDLE` |
| `grant_emit_cnt` | Aussendung einer Zuweisung |
| `grant_regrant_cnt` | Wiederholung, weil im reservierten Unterschlitz nichts empfangen wurde |
| `grant_used_cnt` | Uplink-Burst im reservierten Unterschlitz erkannt |
| `grant_suppressed_cnt` | Auslöser verworfen, weil Zustand ≠ `S_IDLE` |
| `grant_starved_cnt` | `GRANT_ARM_TIMEOUT` abgelaufen, Magazin war leer |
| `grant_mag_overwrite_cnt` | Magazin-Überlauf, ältester Eintrag überschrieben |
| `grant_preempt_cnt` | Signalisierungs-Warteschlange wurde für eine Zuweisung verdrängt |
| `grant_late_cnt` | Zuweisungsbits lagen nicht vor dem `slot_pulse` des Zielslots vor (Frist `08 §3.3.4`, R-08-03); Erwartungswert 0 |
| `steal_override_cnt` | Queue-Eintrag hat den Halteinhalt eines Verkehrsschlitzes verdrängt (`04 §3.4`, gefordert von `10` R-10-09) |
| `resv_slot_cnt` | Kontrollkanal-Slot mit Reservierungsmuster gesendet |
| `mcch_slot_cnt` | Kontrollkanal-Slots gesendet (Bezugsgröße für `resv_slot_cnt`) |
| `aach_f18_clch_cnt` | Frame-18-Slot mit CLCH-Muster gesendet |
| `ul_nts2_detect_cnt` | Uplink-Burst mit NTS2 erkannt (§3.3.2) |
| `ul_addr_type_rej_cnt` | Uplink-PDU mit nicht unterstützter Adressierungsart (SW) |
| `reass_*` | Fragment-Zusammensetzung (§3.11). Die Zusammensetzung läuft in Software, deshalb sind diese Zähler **nicht hier** definiert, sondern abschließend in `13 §3.10.2` — dort auch die Kettenauflösung (Index 0 = Kette A, 1 = Kette B), die dieses Kapitel mit „je Kette" fordert. Für die MAC-Abnahme (§5.3, §5.5) relevant: `reass_ok_cnt`, `reass_t0_cnt`, `reass_gap_cnt` |

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| `sg_element` Anmeldung | `0x00` (erster Unterschlitz, keine Verzögerung) | [CODE rtl/lmac/tetra_pre_reply_slotgrant.v:143-149] + [MESS 2026-06-10] | mit `0x30` sieht das Endgerät die Zelle, kann sich aber nicht einbuchen |
| `sg_element` lange UL-Kurznachricht | `0x30` (3 Slots, keine Verzögerung) | [CODE …:145-149], aus dem Referenz-Downlink dekodiert | mit `0x00` bricht die Fragmentkette nach einem Fragment ab |
| AACH-Halte-Muster Mehrschlitz | `0x0000`, gehalten `cap_alloc` Slots | [CODE rtl/tx/tetra_aach_encoder.v:244-252] + [MESS 2026-06-10] | ohne Halten öffnet der AACH die reservierten Slots wieder für Zufallszugriff, die Kette bricht ab |
| Zugriffsfeld Zufallszugriff | `001001` = Code A, 8 Unterschlitze | [GOLD, 1795 von 1834 Kontrollkanal-Slots] | anderer Code muss mit dem Rundspruch der Zugriffsparameter übereinstimmen, sonst kein Zufallszugriff |
| Antwort-Frameabstand Vorantwort → Bestätigung **im Referenznetz** | 2 Frames, gleicher Zeitschlitz | [GOLD, 6 Paare, ausnahmslos] | **Messwert, kein V2-Sollwert:** in V2 ist die Bestätigung ereignisgetriggert (`08` R-08-11, `08 §3.5.2`, `04` R-04-21). Zu früh **gebaut** (Zusammensetzung noch nicht fertig): die Bestätigung fällt auf einen Default-Inhalt zurück — dagegen schützt der Vollständigkeits-Status, nicht ein Abstand |
| Reservierungsanteil Kontrollkanal | 0,71 % | [GOLD, 13 von 1834] | > 5 %: Zufallszugriff-Kapazität sinkt messbar, Anmeldungen kollidieren |
| Frame-18-CLCH-Anteil Kontrollkanal | 26 von 102 Frame-18-Slots | [GOLD] | fehlt die Gelegenheit, linearisieren Endgeräte in belegten Unterschlitzen |
| `T.202` Fragmentierungs-Timeout des Endgeräts | 9 Downlink-Frames ≈ 510 ms | [ETSI Anhang B.1] | Zuweisung später als das: angefangenes Fragment ist verworfen |
| `T.206` Reserviert-Zugriff-Timeout | 18 Downlink-Frames ≈ 1,02 s | [ETSI Anhang B.1] | danach beginnt das Endgerät den Zufallszugriff neu — der Beginn der Aufschaukelung |
| Software-Umlaufzeit V1 (Hauptschleife) | ≈ 133 ms | [MESS 2026-05-20, NUB-Latenz 133 ms deterministisch über 3 PTT-Läufe] | > Budget 14…21 ms → Zuweisung nicht sendezeitpunkt-fest |

---

## 5. Verifikation

### 5.1 Unit-Simulation (selbstprüfend, Pflicht)

| ID | Testbench | Prüft |
|---|---|---|
| **V-06-1** | `tb_aach_info` | alle 13 Zeilen aus §3.8.2 werden getroffen; Ausgabewerte gleich der Musterliste §3.8.3; über einen vollen Hyperframe wird **kein** Wert außerhalb der Liste erzeugt (R-06-06) |
| **V-06-2** | `tb_aach_info_f18` | `(MN+TN) mod 4` für alle 4 Zeitschlitze × 60 Multiframes: CLCH- und BSCH-Position stimmen mit Gl. 9.17/9.18/23.2 überein — der Test, den V1 nicht bestanden hätte (§3.2) |
| **V-06-3** | `tb_ul_grant_trigger` | Burst in offenem Unterschlitz löst aus; Burst in reserviertem Unterschlitz löst **nicht** aus; Auslöser in `S_ARMED`/`S_WINDOW`/`S_COOL` erhöhen nur `grant_suppressed_cnt` |
| **V-06-4** | `tb_ul_grant_window` | `emit_left`/`hold_left`-Buchhaltung; Frame-18-Sprungregel (§3.9.5); Magazin leer → `grant_starved_cnt`, kein Hänger |
| **V-06-5** | `tb_ul_grant_bound` | Zufallsstimulus über 10 000 Frames: `grant_emit_cnt ≤ GRANT_REPEAT × grant_trigger_cnt` und `grant_trigger_cnt ≤` Anzahl offener Unterschlitze — **formal die Aufschaukelungs-Sperre** |
| **V-06-6** | `tb_mac_dl_fill` (C) | Füll- und Längenregeln F1…F4 gegen die Bitmuster von [GOLD #775] und [GOLD #783], bitweise |
| **V-06-7** | `tb_mac_ul_parse` (C) | MAC-ACCESS/END-HU/FRAG/END-Kopfoffsets gegen `tb/vectors`; Reservierungsbedarf vs. Länge im 6-bit-Feld des UL-MAC-END |
| **V-06-8** | `tb_mac_reass` (C) | Kette A und B einschließlich Kollision zweier Endgeräte, Zeitgeberablauf, verwaistes Endfragment |

### 5.2 Gold-Vergleich (strukturell)

Erfüllt, wenn aus einer eigenen Aufzeichnung über ≥ 60 s mit einer Anmeldung und einem
Gruppenruf gilt:

1. Jedes gesendete AACH-Infowort steht in der Musterliste §3.8.3.
2. Kein Verkehrsmuster (`0x32CB`, `0x22C9`, `0x2049`, `0x304B`) liegt auf einem SB-Burst —
   die Kennzahl, an der V1 mit 600 von 638 Fällen scheitert (§3.8.4).
3. `0x0040` erscheint in **jeder** Frame 18 auf jedem Nicht-Kontrollkanal-Zeitschlitz ohne
   aktiven Ruf; `0x0049` auf dem Kontrollkanal in genau einem Viertel der Frame-18-Slots.
4. Die Vorantwort trägt `LI = 7`, `RA = 1`, `sg = 1`, `sg_element = 0x00`,
   `addr_type = SSI`; die Bestätigung `RA = 0`, `sg = 1`, `sg_element = 0x00`. Beide Slots
   tragen AACH `0x0009` und **denselben** Zeitschlitz. Der Frameabstand zwischen beiden ist
   **kein** Kriterium — er ist ereignisgetriggert (`08` R-08-11, `08 §3.5.2`); die Referenz
   zeigt dort 2 Frames.
5. Jeder Downlink-MAC-Block endet mit Null-PDU + Blockfüllung nach F4; kein Block enthält
   ein gesetztes Bit hinter einer PDU ohne Null-PDU.

Zell- und teilnehmerspezifische Felder (SSI, GSSI, Carrier, MCC/MNC, Colour Code,
Nutzungsmarkierung, Call-Identifier) dürfen und müssen abweichen (`CONVENTIONS §3`).

### 5.3 Luft-Abnahme Anmeldung

Mit einem kommerziellen Endgerät, ≥ 3 Durchläufe:

- Anmeldung erfolgreich in **allen** Durchläufen.
- Zeit vom Zufallszugriff bis zur Bestätigung ≤ 5 Frames (≈ 283 ms). Gold: 3 Frames
  [GOLD].
- `grant_used_cnt` = `grant_trigger_cnt`, `grant_regrant_cnt` = 0 bei gutem Empfang.
- Verwurfszähler der Signalisierungs-Warteschlange (`04 §3.5.1`) bleiben auf 0.

### 5.4 Abnahmekriterium gegen die Aufschaukelung (Pflicht)

Der Test provoziert genau die V1-Spirale und muss sie ausschließen. Aufbau: die Software
unterdrückt die Anmeldebestätigung, sodass das Endgerät seinen Zufallszugriff wiederholt,
solange es die Zelle sieht. Laufzeit 60 s, ein Endgerät.

Bestanden, wenn **alle fünf** Bedingungen halten:

1. `grant_emit_cnt / 60 s ≤ GRANT_REPEAT / (GRANT_GAP × 56,67 ms)` — mit den Defaults
   (2 / 4 Frames) also **≤ 8,8/s**.
2. `resv_slot_cnt / mcch_slot_cnt ≤ 5 %`.
3. Alle Verwurfszähler der DL-Signalisierungs-Warteschlange bleiben **0** — strukturell
   erfüllt, weil die Zuweisung die Warteschlange nicht benutzt (R-06-13); ein Zähler ≠ 0
   ist der Beweis, dass R-06-13 verletzt wurde.
4. **Monotonie:** wird die Wiederholrate des Endgeräts durch einen zweiten Sender
   verdoppelt, steigt `grant_emit_cnt/s` um höchstens den Faktor 2. Ein überproportionaler
   Anstieg ist die Signatur der Selbstverstärkung.
5. Nach Aufheben der Unterdrückung meldet sich das Endgerät innerhalb von 2 s an, ohne
   Neustart.

Bedingung 4 ist die eigentliche Aussage: in V1 stieg die Zuweisungsrate überproportional,
weil jede Zuweisung selbst wieder Zuweisungen auslösen konnte. Der Auslösefilter aus
§3.9.3 (nur Bursts in offenen Unterschlitzen) macht das unmöglich, weil eine Zuweisung
ihren eigenen Unterschlitz als reserviert markiert.

### 5.5 Luft-Abnahme Mehrschlitz-Reservierung

Lange Kurznachricht (> 24 Oktett) im Uplink, ≥ 3 Durchläufe:

- Die vollständige Fragmentkette (Start + N × MAC-FRAG + MAC-END) kommt an;
  `reass_ok_cnt[1]` (Kette B) steigt je Durchlauf um 1, `reass_t0_cnt[1]` und
  `reass_gap_cnt[1]` bleiben konstant (`13 §3.10.2`).
- Während des Fensters zeigt der Kontrollkanal-AACH `0x0000`, danach wieder `0x0249`.
- Kreuzt das Fenster eine Frame 18 mit `clch_phase`, zeigt dieser Kontrollkanal-Slot
  `0x0049` statt `0x0000` und das Fenster verlängert sich um genau einen Slot (§3.9.5).
- Kreuzt das Fenster eine Frame 18 **ohne** `clch_phase` — der Regelfall, 3 von 4
  Multiframes —, bleibt der AACH dieses Slots `0x0000` (Zeile 6 vor Zeile 7, §3.8.2),
  `hold_left` wird dekrementiert und das Fenster verlängert sich **nicht**. Ein `0x0249`
  in einem solchen Slot während des Fensters ist ein Fehlschlag: er nimmt zugesagte
  Kapazität zurück [ETSI §23.5.2.2.2].

---

## 6. Offene Punkte

1. **O-06-1 — Wer füllt das Magazin für einen erstmals gesehenen Teilnehmer?** Für einen bereits
   eingebuchten Teilnehmer kann die Software den codierten Grant beliebig lange vorher
   bereitstellen — dann liegt kein Software-Anteil im Zeitpfad. Beim allerersten Fragment
   eines unbekannten Endgeräts lernt die Software die Adresse erst aus diesem Fragment.
   Der Entwurf deckt das über `GRANT_ARM_TIMEOUT` und die Wiederholung ab: die Zuweisung
   verschiebt sich um bis zu vier Slots, sie entfällt nicht, und `T.202` (510 ms) ist
   um mehr als eine Größenordnung größer als diese Verschiebung. **Zu messen** ist, wie
   oft `grant_starved_cnt` in der Praxis anschlägt und ob eine Anmeldung dadurch je
   scheitert. **Empfehlung:** mit `GRANT_ARM_TIMEOUT = 4` starten und den Zähler in der
   Luft-Abnahme (§5.3) mitprotokollieren. Falls er anschlägt: `cfg_grant_fallback_en`
   nachrüsten, das bei leerem Magazin einen vorab codierten Grant an einen
   Sammel-Platzhalter aussendet — Kosten: ein Kontrollkanal-Slot ohne Wirkung, was nach
   R-00-02 die bewusst gewählte Seite ist.
2. **O-06-2 — `ul_state_sys` je Zeitschlitz ist noch zu grob.** Die Gold-Aufzeichnung zeigt vier
   unterscheidbare Rufphasen auf dem Verkehrsschlitz (`0x32CB` Sprechen, `0x2049`
   gehaltener Kanal, `0x22C9` Sprecherwechsel, `0x304B` Freigabeslot) und wechselt
   innerhalb weniger Slots. Ob V2 alle vier braucht oder mit drei Zuständen
   funktional äquivalent bleibt, ist in `10_CMCE_CALL.md` zu entscheiden.
   **Empfehlung:** alle vier vorsehen; `0x304B` kostet eine Tabellenzeile und ist der
   Slot, in dem die BS den Sprecher freigibt.
3. **O-06-3 — Ist `0x0000` das richtige Halte-Muster, oder genügt `0x0009`?** `0x0000` reserviert
   beide Unterschlitze und ist für Vollschlitz-Zusagen zwingend
   [ETSI §23.5.1.4.2]. Es ist air-verifiziert, aber in der Gold-Aufzeichnung nicht
   enthalten. **Empfehlung:** beibehalten und im Test §5.5 gegen einen Durchlauf mit
   `0x0009` messen, damit die Notwendigkeit belegt ist statt überliefert.
4. **O-06-4 — Uplink-Kanalstehlen.** Der zweite Korrelatorzweig auf NTS2 (§3.3.2) liefert zunächst
   nur einen Zähler. Ob im eigenen Netz überhaupt gestohlene Uplink-Bursts auftreten, ist
   unbekannt — V1 hätte sie nie gesehen. **Empfehlung:** den Zähler in Stufe 1 bauen und
   erst nach einer Messung entscheiden, ob die Halbschlitz-Zerlegung nötig ist.
5. **O-06-5 — Assoziation im Downlink-Block.** Die Gold-Aufzeichnung zeigt einen Block mit zwei
   MAC-RESOURCE-PDUs an verschiedene Adressen (Quittung an den Absender + Fragmentstart an
   den Empfänger) [CODE sw/tetra_sds_dl_frag.c:86-118]. Der Mechanismus ist in §3.7 F3/F4
   vollständig spezifiziert, aber V2 Stufe 1 braucht ihn nur für diesen einen Fall.
   **Empfehlung:** die Assoziation generisch in `tetra_mac_dl.c` implementieren (eine
   Schleife über eine PDU-Liste), nicht als Sonderfall — sonst entsteht der zweite Pfad,
   den P3 verbietet.
