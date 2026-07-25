# 08 — Zeitverhalten, Fristen und die DL→UL-Zeitkopplung

**Scope:** Alles Zeitliche an einem Ort — die Fristen innerhalb eines
Zeitschlitzes und wer sie einhalten muss; das Antwortfenster für Signalisierung;
die Zeitkopplung zwischen Sendezeitraster und Uplink-Empfangsfenster samt
Zuordnung eines empfangenen Bursts zu seinem Zeitschlitz; das Zeitbudget der
Uplink-Zuweisung; die Zeitgeber der Fragment-Zusammensetzung und der
Ruf-Überwachung; die gemessenen Ende-zu-Ende-Latenzen mit Messkontext.

**Nicht hier:** Algorithmen (02, 03, 04, 05). Registeradressen und
Mailbox-Formate (07 — dieses Kapitel nennt nur Registernamen). Protokollabläufe
(09–12 — hier stehen ausschließlich deren Zeitbudgets). Taktarchitektur und
Oszillator-Genauigkeit (01).

**Abhängigkeiten:** `00_OVERVIEW.md` (§2.1 Zeitstruktur, §3 Schnitt, R-00-01…04),
`01_PLATFORM.md` (§3.3 Symbol-Tick), `04_PHY_TX_TDMA.md` (§3.1 Zeitbasis),
`03_PHY_UL_RX.md` (§3.4, §3.6 Burst-Geometrie und Ankerlage).

---

## 1. Anforderungen

| Nr | Anforderung | Prüfbar durch |
|---|---|---|
| **R-08-01** | Die TDMA-Zeitbasis im PL ist die **einzige** Zeitwahrheit des Systems. Die Software hält keine eigene TDMA-Uhr und leitet keinen Luft-Zeitbezug aus `CLOCK_MONOTONIC` ab. | Codereview: kein `clock_gettime` in einem Pfad, der eine Frame-, Slot- oder Multiframe-Nummer erzeugt. |
| **R-08-02** | Der vollständige Inhalt eines Sende-Bursts (beide Blöcke, Broadcast-Feld, Trainingsfolgen) liegt zum **Slot-Start** in Registern. Kein Modul im Sendepfad wartet nach Slot-Start noch auf eine Quelle. | Simulation: `build_req` → letzter Dibit ohne Lücke; Zähler `TX_UNDERRUN_CNT` bleibt 0 über 10 000 Slots. |
| **R-08-03** | Die Uplink-Zuweisung liegt spätestens **17,0 ms** nach dem UL-Sync-Anker als fertige Bits im Sendepfad (Herleitung §3.3). Die Frist gilt als Worst Case, nicht als Mittelwert. | Simulation mit Anker-Stimulus auf dem spätesten Unterschlitz; Zähler `grant_late_cnt` bleibt 0. |
| **R-08-04** | Im Antwort-Zeitpfad der Uplink-Zuweisung liegt **kein** Software-Umlauf (= R-00-01). Software setzt nur das Zuweisungs-**Muster** über Register (= R-00-03). | Codereview + Blockdiagramm: kein Pfad von der Zuweisungslogik über eine PS-Mailbox. |
| **R-08-05** | Die gemessene Differenz zwischen Sende-Anker und UL-Sync-Anker wächst von Zeitschlitz zu Zeitschlitz um **genau eine Zeitschlitzdauer** (85/6 ms). Zulässige Abweichung: **±1 Symboldauer** (±55,6 µs). | Luft-Messung mit vier aufeinanderfolgenden Einzel-Zuweisungen TS1…TS4 (§5.3). |
| **R-08-06** | Der Sende-Anker der Stoppuhr liegt auf dem **dritten** Sende-Zeitschlitz (`tn=2` RTL = TS3 ETSI), nicht auf dem ersten. Begründung §3.2.2 — dies ist eine Invariante, kein Kalibrierwert. | Codereview + Messung: alle vier UL-Ankunftsdifferenzen liegen in `[0, 1 Frame)` und wachsen monoton. |
| **R-08-07** | Die Differenz wird **atomar in der Hardware** im Moment des UL-Ereignisses gebildet. Die Software liest ein einziges fertiges Differenz-Register und rechnet nie aus zwei separat gelesenen Zeitstempeln nach. | Codereview: genau eine Subtraktion, im UL-Ereignis-`always`-Block; kein SW-Code, der zwei Stoppuhr-Register subtrahiert. |
| **R-08-08** | Die **Absolutwerte** der Differenz sind Kalibrierwerte der jeweiligen Pipeline, **kein** Abnahmekriterium. Die V2-Abweichung gegenüber der Nominalrechnung muss vollständig aus den Stufenlatenzen der Kapitel 02–04 erklärbar sein; der unerklärte Restposten beträgt ≤ 100 µs. | Latenz-Bilanz (§3.2.5) gegen Messung; Restposten dokumentiert. |
| **R-08-09** | Nach jedem Eingriff in Sendefilter, Interpolation, Dezimation, Empfangsfilter oder Taktübergänge wird die Differenzmessung wiederholt. Eine Änderung > 1 Symboldauer ohne erklärende Stufenlatenz-Änderung ist ein Build-Blocker. | Verfahren §3.2.6, verankert in `14_VERIFICATION.md`. |
| **R-08-10** | Jeder an die Software übergebene UL-Burst trägt `(tn, fn, mn)` seines Empfangs-Slots im selben Mailbox-Transfer (= R-00-04). Die Software bildet daraus alle Fenster-Zeitgeber. | Mailbox-Testvektor: Zeitstempel im gelesenen Datensatz stimmt mit dem stimulierten Slot überein. |
| **R-08-11** | Die Vor-Antwort auf einen UL-Signalisierungsburst liegt im DL-Frame **N+1** relativ zum Empfangs-Frame N. Die substanzielle Antwort folgt frame-granular, sobald die Software sie hat. | Luft-Capture: Frame-Abstand Vor-Antwort ↔ auslösender UL-Burst = 1 (§3.4). |
| **R-08-12** | Alle Fenster- und Überwachungs-Zeitgeber sind zur Laufzeit lesbar und einstellbar, und jeder Verfall hat einen eigenen Zähler (P6). | Registerliste in 07; Zähler `*_DROP_CNT` je Zeitgeber. |
| **R-08-13** | Die monotone Software-Uhr wird ausschließlich für Ruf-Überwachungs-Zeitgeber (Ruhe, Verfall, Klingeldauer) verwendet, deren Toleranz ≥ 100 ms ist. Für Luft-Timing ist sie verboten. | Codereview. |
| **R-08-14** | Die Ende-zu-Ende-Zeitziele aus §3.8 werden im Luft-Abnahmetest über ≥ 3 Wiederholungen erreicht. | Air-Test-Protokoll `14_VERIFICATION.md`. |

---

## 2. Architektur / Aufbau

### 2.1 Drei Zeitachsen, die nicht vermischt werden dürfen

| Achse | Auflösung | Erzeuger | Verbraucher | Verbot |
|---|---|---|---|---|
| **Luftzeit** | Symboldauer 500/9 µs | Symbol-Tick aus `clk_lvds` ÷ 1024 [CODE rtl/tx/tetra_burst_builder.v:20-23] | TDMA-Zähler, Burst-Aufbau, AACH, BSCH | Nie aus `clk_sys` nachgebildet — 100 MHz/18 kHz = 5555,56 ist nicht ganzzahlig [01 §3.3] |
| **Zyklenzeit** | 10 ns (`clk_sys`) | freilaufender 32-bit-Zähler | Stoppuhr, Encoder-FSMs | Kein Luft-Zeitmaß: die Umrechnung Zyklen→ms trägt die `clk_sys`-Genauigkeit (§3.2.5) |
| **Ereigniszeit** | 1 ms (`CLOCK_MONOTONIC`) | ARM-Kernel | Ruf-Zeitgeber, Wiederholungs-Abstände | Nie für Slot-, Frame- oder Zuweisungs-Timing |

Die Brücke zwischen Luftzeit und Software ist **ausschließlich** der Zeitstempel
`(tn, fn, mn)`, der jeden UL-Burst begleitet (R-08-10). V1 hatte diese Brücke
nicht: der Zeitgeber der UL-Fragment-Zusammensetzung bezog seinen Frame-Takt aus
der **DL-Empfangskette** über einen HF-Rückschluss auf die eigene Aussendung
[CODE rtl/tetra_zynq_top.v:688-695, :752, :837]. Damit hing die
UL-Zusammensetzung am DL-Empfang, der funktional nichts damit zu tun hat. V2
entkoppelt das (§3.5).

### 2.2 Normative Zeitkonstanten

| Größe | Exakter Wert | Näherung | Beleg |
|---|---|---|---|
| Modulationsrate | 36 kbit/s (π/4-DQPSK) | — | [ETSI §5.3] |
| Symboldauer `Tsym` | 500/9 µs | 55,556 µs | 36 kbit/s ÷ 2 bit/Symbol |
| Zeitschlitz | 85/6 ms = 255 `Tsym` | 14,167 ms | [ETSI §9.3.3] |
| Unterschlitz | 85/12 ms = 127,5 `Tsym` | 7,083 ms | [ETSI §9.3.6] |
| TDMA-Frame | 170/3 ms = 4 Zeitschlitze | 56,667 ms | [ETSI §9.3.4] |
| Multiframe | 18 Frames | 1,02 s | [ETSI §9.3.7] |
| Hyperframe | 60 Multiframes | 61,2 s | [ETSI §9.3.8] |
| Frame 18 | Kontroll-Frame, ausschließlich Kontrollkanäle | — | [ETSI §9.3.4] |
| **UL-Rasterversatz** | UL-Raster ist um **genau 2 Zeitschlitze** gegen das DL-Raster verzögert | 28,333 ms | [ETSI §9.3.9] |
| Zuweisungs-Bezug | Die Zugriffszuweisung eines DL-Slots gilt für den gleichnummerierten UL-Slot **desselben** TDMA-Frames — physikalisch zwei Slots später | — | [ETSI §23.5.1.4.2] |
| Burst-Verzögerung `d` | NUB: 17 `Tsym`; CB Unterschlitz 1: 17 `Tsym`; CB Unterschlitz 2: 144,5 `Tsym`; DL-NDB (kontinuierlich): 0 | — | [ETSI Tabelle 9.2] |
| Symbolzeit von `SN(n)` | `(n + d)` Symboldauern nach Slot-Start | — | [ETSI §9.4.3.4 „Burst timing"] |

Der Rasterversatz von 2 Zeitschlitzen (§9.3.9) und die Zuweisungs-Bezugsregel
(§23.5.1.4.2) sind die beiden Sätze, aus denen sich **jede** Frist in diesem
Kapitel ableitet.

### 2.3 Wer welche Frist einhalten muss — Übersicht

| Frist | Wert | Träger | Konsequenz bei Verletzung |
|---|---|---|---|
| Burst-Inhalt vollständig | Slot-Start | PL: Zeitplan → Dispatcher → Builder | Lücke im Symbolstrom, MS verliert Slot-Lock |
| Broadcast-Feld (AACH) codiert | Slot-Start (Feld liegt bei Symbol 116…141 [ETSI Tabelle 9.7]) | PL: AACH-Encoder | MS liest falsche Zugriffsrechte, sendet nicht oder kollidiert |
| Synchronisationskanal (BSCH) codiert | Slot-Start des F18-Ankerslots, mit Lookahead auf das Folge-Tupel | PL: BSCH-Encoder | Falsche Slot-Nummer im Sync-PDU [04 §3.2.4] |
| Uplink-Zuweisung auf der Luft | 17,0 ms nach UL-Sync-Anker (§3.3) | **PL** (R-00-01) | MS wiederholt Anforderung → Zuweisungs-Spirale [MESS 2026-07-11] |
| Vor-Antwort im Signalisierungspfad | DL-Frame N+1 | PL (Vor-Antwort-Erzeuger) | MS-LLC-Wiederholung |
| Substanzielle Antwort | frame-granular, Ziel ≤ 2 Frames nach dem letzten UL-Fragment | PS | MS-Wiederholung, Warteschlangen-Stau |
| Fragment-Fenster | ≥ 4 Signalisierungs-Gelegenheiten (§3.5) | PS | Kette verworfen, MS wiederholt vollständig |
| Sprach-Ruhe-Erkennung | 300 ms | PS | Audio-Aussetzer bzw. verzögerte PTT-Reaktion |

---

## 3. Detail-Spezifikation

### 3.1 Fristen innerhalb eines Zeitschlitzes

#### 3.1.1 Die Kette und ihre Vorlaufzeiten

```
Frame-Grenze (slot_pulse @ tn=3)
   └─ Zeitplan-Vorabruf für alle 4 Slots des Folge-Frames   ~6 clk_sys
Slot-Grenze (slot_pulse @ tn=k)
   └─ Dispatcher latcht Inhalt für Slot k                    1 clk_sys
   └─ build_req                                              1 clk_sys
   └─ Builder schiebt Dibit 1 … 255 im Symbol-Takt          255 Tsym
```

**Vorabruf des Zeitplans.** Die vier Zeitplan-Einträge des **Folge**-Frames
werden am `slot_pulse` des letzten Slots (`tn=3`) in Register geholt; die
FSM braucht dafür 4 Lesezugriffe ≈ 6 `clk_sys`-Takte und hat einen ganzen
Zeitschlitz Zeit [CODE rtl/tx/tetra_slot_content_mux.v:15-22, :108-120]. Der
Vorabruf ist damit um Größenordnungen schneller als seine Frist; er existiert
nur, damit der Dispatcher zum Slot-Start nicht auf einen BRAM-Zugriff warten
muss.

**Inhaltsauswahl.** Der Dispatcher wählt zum `slot_pulse` in **einem**
`always`-Block zwischen Signalisierungs-Warteschlange, statischem Zeitplan und
Füller-Mailbox und gibt `build_req` einen Takt später aus
[CODE rtl/tx/tetra_burst_dispatcher.v:20-37]. Damit ist die gesamte
Auswahllatenz 2 `clk_sys` = 20 ns.

**Deadline-Regel für V2 (R-08-02).** Jede Quelle, die Burst-Inhalt liefert
(Software-Bank, Warteschlangen-Kopf, Füller-Mailbox), muss **vor** dem
`slot_pulse` des betreffenden Slots stabil sein. Die Hardware prüft das nicht
inhaltlich; sie zählt lediglich, wie oft der Dispatcher auf einen Füller
zurückfallen musste. Zwei Zähler sind verpflichtend:

| Zähler | Bedeutung |
|---|---|
| `TX_FILLER_FALLBACK_CNT` | Slot ohne bereitgestellten Inhalt → NULL-PDU gesendet |
| `TX_UNDERRUN_CNT` | Builder erreichte Symbol 255 ohne gültige Fortsetzung |

#### 3.1.2 Encoder-Laufzeiten gegen die Slot-Frist

| Encoder | Laufzeit | Beleg | Frist | Reserve |
|---|---|---|---|---|
| AACH RM(30,14) + Verschlüsselung | ~33 `clk_sys` = 0,33 µs | [CODE rtl/tx/tetra_aach_encoder.v:29] | 1 Slot | > 40 000× |
| SCH/HD (216 bit) | ~487 `clk_sys` = 4,87 µs | [CODE rtl/lmac/tetra_sch_hd_encoder.v:27] | 1 Slot | ~2 900× |
| SCH/F (432 bit) | ~991 `clk_sys` = 9,91 µs | [CODE rtl/lmac/tetra_sch_f_encoder.v:30] | 1 Slot | ~1 400× |
| BSCH/SYSINFO | ~142 `clk_sys` = 1,42 µs | [CODE rtl/tetra_zynq_top.v:3946-3959] | 1 Slot, **mit Lookahead** | ~10 000× |

Die Kanalcodierung ist damit **nie** der Engpass gegenüber der Slot-Frist. Das
ist der quantitative Grund, warum sie in V2 vollständig in die Software wandern
darf (00 §3.3): entscheidend ist nicht die Rechenzeit, sondern die
**Determiniertheit der Bereitstellung**. Der Engpass ist der Software-Umlauf,
nicht der Codierer — siehe §3.3.

> **Was in V1 wirklich der Engpass war.** Die SCH/F-Kanalcodierung existiert in
> V1 bit-gleich zweimal, in RTL und in C, und beide Kopien laufen live
> [00 §1.1]. Die RTL-Kopie war nie nötig, um eine Frist zu halten — sie hielt
> eine Frist, die es nicht gab.

#### 3.1.3 Lage des Broadcast-Feldes und die MS-seitige Frist

Im kontinuierlichen DL-Normalburst liegt das Broadcast-Feld gesplittet um die
Trainingsfolge: `bb(1..14)` auf den Bits 231–244, `bb(15..30)` auf den Bits
267–282 [ETSI Tabelle 9.7], mit `d = 0` [ETSI Tabelle 9.2] also auf den
Symbolen 116–122 und 134–141. Daraus:

| Ereignis | Zeit nach DL-Slot-Start | Rechnung |
|---|---|---|
| Erstes AACH-Symbol auf der Luft | 6,444 ms | 116 × 500/9 µs |
| Letztes AACH-Symbol auf der Luft | 7,833 ms | 141 × 500/9 µs |
| Start des zugehörigen UL-Slots | 28,333 ms | 2 × 85/6 ms [ETSI §9.3.9] |
| **Frist des MS**: AACH-Ende → erstes eigenes NUB-Symbol | **21,444 ms** | 28,333 − 7,833 + 17 × 500/9 µs |

[ANNAHME: Rechnung aus den zitierten ETSI-Tabellen; nicht gemessen.] Diese
Zahl gehört nicht zu unseren Fristen, erklärt aber, warum die
Zuweisungs-Semantik „nächste Gelegenheit" (`granting delay = 0000`) überhaupt
funktioniert: das MS hat gut 21 ms für AACH-Decodierung, PDU-Decodierung und
Senderhochlauf.

### 3.2 Die DL→UL-Zeitkopplung

Dies ist der Kern des Kapitels. Es wird strikt getrennt in **Invarianten**
(§3.2.1–3.2.3, in V2 exakt einzuhalten) und **Kalibrierwerte**
(§3.2.4–3.2.5, ausdrücklich keine Sollwerte).

#### 3.2.1 Invariante 1 — Schrittweite genau eine Zeitschlitzdauer

Das UL-Raster ist gegen das DL-Raster um genau 2 Zeitschlitze verzögert
[ETSI §9.3.9]. Zeitschlitze innerhalb eines Frames folgen mit genau einer
Zeitschlitzdauer aufeinander [ETSI §9.3.3]. Daraus folgt zwingend:

> Wird derselbe Sende-Anker verwendet, unterscheiden sich die
> Ankunftszeitpunkte zweier UL-Bursts auf benachbarten Zeitschlitzen um
> **genau 85/6 ms = 14,1667 ms**.

Das ist Physik des Zeitrasters, unabhängig von jeder Pipeline-Verzögerung: die
Pipeline-Latenz ist für alle vier Zeitschlitze **dieselbe** und fällt in der
Differenz heraus. **Deshalb liegt das Abnahmekriterium auf der Schrittweite und
nicht auf dem Absolutwert (R-08-05).**

Zulässige Abweichung: ±1 Symboldauer (±55,6 µs). Begründung der Toleranz: Der
Symbol-Tick wird aus `clk_lvds` erzeugt und über eine 2-FF-Kette nach `clk_sys`
resynchronisiert; das kostet ±1 `clk_sys`-Takt = ±10 ns Jitter
[01 §3.3]. Der Sync-Anker selbst rastet auf ein Sample bei 4 Samples/Symbol,
also ±¼ Symbol. Beides ist weit innerhalb der Toleranz; die Toleranz ist
bewusst so weit gefasst, dass ein Sub-Symbol-Effekt keinen Fehlalarm auslöst,
aber ein echter Slot-Versatz sofort auffällt.

#### 3.2.2 Invariante 2 — der Anker liegt auf dem dritten Sende-Zeitschlitz

**Die Regel:** Der Sende-Anker der Stoppuhr wird auf dem Slot mit `tn = 2`
(RTL, 0-basiert) = **TS3 (ETSI)** ausgelöst
[CODE rtl/tetra_zynq_top.v:1316-1324].

**Warum nicht TS1 — der real durchlittene Fehler.** Der erste Entwurf legte den
Anker auf `tn = 0` (TS1). Der Anker feuert **einmal pro Frame**, und die
Differenz wird gegen den *jüngsten vorausgegangenen* Anker gebildet. Liegt eine
UL-Ankunft mehr als einen Frame hinter „ihrem" Anker, ist beim Eintreffen längst
der nächste Anker gelatcht und der Messwert erscheint um einen Frame verkleinert.

Bezug ist jeweils der Sende-Anker; `A ≈ 7,67 ms` ist die Lage des UL-Sync-Ankers
innerhalb des UL-Slots ohne Pipeline-Latenz (§3.2.5), `TS = 14,167 ms`,
`Frame = 56,667 ms`:

| UL-Slot | Anker **TS1**: nominal | Anker **TS1**: nominal, mod 1 Frame (Rechnung) | Anker **TS3**: nominal, mod 1 Frame (Rechnung) |
|---|---|---|---|
| TS1 | 2 TS + A = 36,00 ms | 36,00 ms | 0 TS + A = **7,67 ms** |
| TS2 | 3 TS + A = 50,17 ms | 50,17 ms | 1 TS + A = **21,83 ms** |
| TS3 | 4 TS + A = 64,33 ms | **7,67 ms** (−1 Frame) | 2 TS + A = **36,00 ms** |
| TS4 | 5 TS + A = 78,50 ms | **21,83 ms** (−1 Frame) | 3 TS + A = **50,17 ms** |

Alle Werte dieser Tabelle sind **gerechnet**, ohne `L_pipe` (§3.2.5), und sind
keine Messwerte. Gemessen wurde mit TS1-Anker genau ein Wert, und er enthält
`L_pipe`: `voice_ts = TS2` ⇒ **50,837 ms** (±14 µs, 91 % Trefferrate über
73 UL-Ereignisse) [MESS 2026-05-25] — nominal 50,17 ms + 0,67 ms `L_pipe`.
Für TS3/TS4 ist nur qualitativ belegt, dass das Register die **gewrappten**
Werte „~8/22 ms statt 65/79" zeigte [MESS 2026-05-25]; 65/79 ms sind dabei die
Nominalwerte 64,33/78,50 ms **plus** `L_pipe`. Der TS1-Fall (36,00 ms) wurde nie
gemessen. Das Umschlagverhalten ist damit belegt, die Absolutwerte der Tabelle
sind es nicht.

**Drei konkrete Schäden — der Grund, warum das eine Invariante ist:**

1. **Die Zuordnung kollidiert mit der Kalibrierung.** Die Zuordnungsfunktion
   arbeitet gegen eine Kalibrierkonstante „TS1 ⇒ 8,34 ms"
   [CODE sw/tetra_ts_map.h:45, :79-95]. Mit TS1-Anker liefert **TS3** genau
   diesen Wert. Wer Anker und Konstante nicht gemeinsam ändert, mappt still um
   zwei Zeitschlitze falsch — und die Sprachwege zweier gleichzeitiger
   Gruppenrufe landen im falschen Zeitschlitz. Genau das hat in V1 mehrere
   Mehrgruppen-Versuche kaputt gemacht, bevor die Ursache gefunden war.
2. **Das Abnahmekriterium verschwindet.** Die Wertereihe lautet mit TS1-Anker
   (gerechnet, ohne `L_pipe`) 36,00 / 50,17 / 7,67 / 21,83 ms — Schrittfolge
   `+1 TS, +1 TS, −3 TS, +1 TS`.
   Die Prüfung „Schrittweite = genau eine Zeitschlitzdauer" (R-08-05), also der
   gesamte Regressionsdetektor aus §3.2.6, ist damit nicht mehr als einfacher
   Vergleich formulierbar.
3. **Zwei Messwerte liegen nahe der Umschlagkante.** 64,33 ms und 78,50 ms
   liegen 7,67 ms bzw. 21,83 ms hinter einem Frame-Vielfachen; bei anderer
   Ankerlage oder größerer Pipeline-Latenz kann ein Wert unter die Kante
   rutschen und um einen ganzen Frame springen. Ein Messwert, der von einer
   Latenz-Änderung um einen Frame springen kann, ist als Regressionsdetektor
   unbrauchbar.

Mit Anker auf dem dritten Sende-Zeitschlitz liegen alle vier Ankünfte in
`[7,67 ms, 50,17 ms]` ⊂ `[0, 1 Frame)`, mit ≥ 6,5 ms Abstand zu beiden Kanten,
monoton wachsend
[CODE rtl/tetra_zynq_top.v:1302-1310, sw/tetra_ts_map.h:39-44].

**Verallgemeinerte Regel für V2.** Bei Anker auf `tn = a` beträgt der
beobachtete Wert für den UL-Slot `tn = u`
`(((u − a + 2) mod 4) × TS) + A`. Diese Abbildung ist für jedes `a` umkehrbar,
aber **monoton steigend in `u` und ohne Umschlag genau für `a = 2`**. `a = 2` ist
damit die einzige Ankerlage, die die Monotonie- und Umschlagfreiheits-Bedingung
erfüllt; die Kantenabstände sind von `a` **unabhängig**, weil `a` nur die
Zuordnung `u → Wert` permutiert und die Wertemenge
`{A, TS+A, 2 TS+A, 3 TS+A}` unverändert lässt. Die Ankerlage ist also über die
Monotonie eindeutig bestimmt und nicht Geschmackssache.

**Ankerlage als Register — und was das für R-08-06 bedeutet.** V2 macht den
Anker-Zeitschlitz einstellbar: `REG_AIRLOCK_CFG.anchor_ts`, Reset-Wert 3
(ETSI TS3) [07 §Air-Lock]. Das ist eine Diagnose-Freiheit, **keine
Betriebsoption**: Nur `anchor_ts = 3` erfüllt die Monotonie- und
Kantenabstands-Bedingung dieses Abschnitts. **Jeder andere Wert ist ein
Diagnosemodus**, in dem die Zuordnung Differenz → Zeitschlitz (§3.2.7) und der
Regressionsdetektor (§3.2.6) nicht gelten. Die Betriebssoftware schreibt das
Register nicht.

**Nebenwirkung, die dokumentiert bleiben muss.** Die V1-Registernamen tragen den
Bestandteil `TS1` aus dem ursprünglichen Entwurf, obwohl der Anker auf TS3 liegt
— bewusst nicht umbenannt, um SW-Churn zu vermeiden
[CODE sw/tetra_hal.h:348-358, rtl/infra/tetra_axi_lite_regs.v:575-579]. V2
benennt nach Funktion; die Zuordnung alt → neu steht in 07. Ein Registername,
der eine falsche Slot-Nummer behauptet, ist ein Doku-Fehler mit
Bit-Konsequenzen.

#### 3.2.3 Invariante 3 — die Differenz wird atomar in Hardware gebildet

**Die Regel:** Im Moment des UL-Sync-Ereignisses subtrahiert die Hardware in
einem Takt und legt das Ergebnis in ein Register. Die Software liest dieses
Register und den Ereigniszähler; sie liest **nie** zwei Zeitstempel und
subtrahiert selbst.

V1 hatte zuerst genau das falsch: die Software las
`STOPWATCH_UL − STOPWATCH_ANCHOR` und lief in einen Race, weil zwischen den
beiden Lesevorgängen ein neuer Anker latchen konnte. Der Kommentar zum Fix
steht direkt am Code [CODE rtl/tetra_zynq_top.v:1340-1343]; das
Kommentarrelikt in der HAL, das die SW-seitige Subtraktion noch beschreibt, ist
**gedriftet** [CODE sw/tetra_hal.h:350-351] — der Code nutzt das
Differenz-Register [CODE sw/tetra_voice_pipe.c:93-96].

**Verbindliche V2-Struktur.** Die Register heißen `REG_AIRLOCK_CFG`,
`REG_AIRLOCK_ANCHOR_CNT`, `REG_AIRLOCK_UL_CNT`, `REG_AIRLOCK_EVT_CNT` und
`REG_AIRLOCK_DELTA_CYC`; Adressen, Breiten und Bitfelder sind in 07 normativ.
Für dieses Kapitel gilt nur die Nutzungsregel:

| Register | Erlaubte Nutzung |
|---|---|
| `REG_AIRLOCK_DELTA_CYC` | **einzige** Quelle für die Slot-Zuordnung und die Regressionsprüfung |
| `REG_AIRLOCK_EVT_CNT` | Erkennung, dass ein neuer Messwert vorliegt |
| `REG_AIRLOCK_ANCHOR_CNT`, `REG_AIRLOCK_UL_CNT` | **nur** Plausibilisierung; nie voneinander subtrahieren |
| `REG_AIRLOCK_CFG.anchor_ts` | Betriebswert 3; abweichende Werte nur im Diagnosemodus (§3.2.2) |

Signale in der PL (`clk_sys`-Domäne, alle mit Suffix `_sys`):

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `anchor_pulse_sys` | 1 | intern | `tx_first_dibit_sys & (tn_sys == cfg_anchor_tn_sys)`, 1 Takt; `cfg_anchor_tn_sys` = 2 im Betrieb |
| `ul_sync_found_sys` | 1 | in | Sync-Treffer aus dem UL-Korrelator [03 §3.3] |
| `lock_counter_sys` | 32 | intern | freilaufend, `+1` je `clk_sys` |
| `lock_anchor_sys` | 32 | intern | Latch auf `anchor_pulse_sys` |
| `lock_delta_sys` | 32 | intern | `lock_counter_sys − lock_anchor_sys`, Latch auf `ul_sync_found_sys` |
| `lock_evt_cnt_sys` | 32 | intern | `+1` auf `ul_sync_found_sys` |

Der Zähler ist 32 bit und wrappt bei 100 MHz nach 42,95 s. Der Wrap ist harmlos,
weil die Differenz in Zweierkomplement-Arithmetik gebildet wird und die zu
messenden Intervalle < 1 Frame sind.

**Lese-Reihenfolge in V1 und warum sie in V2 entfällt.** V1 musste das
Differenz-Register lesen, **bevor** der Burst aus der Mailbox geholt wurde, damit
Differenz und Burst zum selben Ereignis gehören
[CODE sw/tetra_voice_pipe.c:93-96]. Eine solche Reihenfolge-Regel ist eine
ungeschriebene Kopplung zwischen zwei Registern und bricht bei jeder Umstellung
der Aufrufreihenfolge still. In V2 entfällt sie, weil der Zeitstempel Teil
**desselben** Mailbox-Transfers ist (§3.7) — genau der Grund, aus dem R-00-04 so
formuliert ist.

#### 3.2.4 Kalibriertabelle V1 — **kein Sollwert für V2**

> ⚠️ **Die Zahlen in dieser Tabelle sind Kalibrierwerte der V1-Pipeline. Sie
> dürfen in V2 nicht als Abnahmevorgabe verwendet werden.** Sie enthalten die
> Gruppenlaufzeit des V1-Sendefilters, die V1-Interpolation und -Dezimation, die
> V1-Position des Synchronisations-Latches und die internen Filterketten des
> verwendeten Transceivers. V2 baut diese Kette neu und wird **andere**
> Absolutwerte messen. Verbindlich ist R-08-05 (Schrittweite) und R-08-08
> (Erklärbarkeit aus den Stufenlatenzen).

**Messkontext** [MESS 2026-05-25]: Sende-Anker auf DL TS3
(`tx_tdma_state_tn_sys == 2`), UL-Anker `ul_sync_found` aus dem NUB-Korrelator,
Differenz atomar in der PL gebildet, `clk_sys` = 100 MHz. Kontrollierte
Einzel-PTT-Tests, Ruf-Verfallszeitgeber auf 5 s verkürzt, damit die
Slot-Zuteilung zwischen den Messungen sauber durchläuft; jeweils ein
Sprach-Zeitschlitz erzwungen. Stabilität über den Messlauf ±14 µs
(Sub-Symbol-Jitter). Der TS2-Wert wurde am 2026-05-30 nach einer Änderung im
UL-Soft-Pfad unabhängig reproduziert: 22,497 ms [MESS 2026-05-30, 03 §3.5.3].

| Sprach-Zeitschlitz | Nominal (Rechnung §3.2.5) | **Gemessen V1** | Abweichung | Herkunft |
|---|---|---|---|---|
| TS1 (Kontrollkanal) | 8,340 ms | nicht gemessen | — | Kalibrier-Referenz, aus TS2…TS4 zurückgerechnet [CODE sw/tetra_ts_map.h:45] |
| TS2 | 22,507 ms | **22,499 ms** | −8 µs | [MESS 2026-05-25] |
| TS3 | 36,674 ms | **36,669 ms** | −5 µs | [MESS 2026-05-25] |
| TS4 | 50,841 ms | **50,836 ms** | −5 µs | [MESS 2026-05-25] |

**Gemessene Schrittweite** — das ist das Abnahmekriterium:

| Schritt | Gemessen | Nominal | Fehler |
|---|---|---|---|
| TS2 → TS3 | 14,170 ms | 14,1667 ms | +3,3 µs = 0,06 `Tsym` |
| TS3 → TS4 | 14,167 ms | 14,1667 ms | +0,3 µs = 0,01 `Tsym` |

Beide innerhalb ±0,06 Symboldauern — weit unter der zugelassenen ±1
Symboldauer (R-08-05).

**Historischer Zweitwert, der nicht verwechselt werden darf.** Vor der
Ankerverschiebung wurde mit Anker auf DL TS1 und `voice_ts = TS2` eine
Differenz von **50,837 ms** gemessen [MESS 2026-05-25]. Das ist derselbe
physikalische Sachverhalt in anderer Ankerlage (3 Zeitschlitze statt 1
Zeitschlitz Rasterabstand) und **nicht** der TS4-Wert der Tabelle oben.

#### 3.2.5 Nominalrechnung und Latenz-Bilanz — die Vorgabe für V2

Der Absolutwert zerlegt sich in drei Beiträge:

```
Delta(TSn) = (n − 1) × 85/6 ms          Rasterversatz zwischen den UL-Slots
           + 138 × 500/9 µs             Lage des UL-Sync-Ankers im UL-Burst
           + L_pipe                     Sende- + Empfangs-Pipeline + Ausbreitung
```

**Term 1 — Rasterversatz.** Mit Anker auf DL TS3 fällt der Start des UL-Slots
TS1 exakt mit dem Start des DL-Slots TS3 zusammen (2-Zeitschlitz-Versatz,
[ETSI §9.3.9]). Der Beitrag für TS1 ist damit 0.

**Term 2 — Lage des UL-Sync-Ankers.** Der NUB-Sync-Anker ist das **letzte
Symbol der Trainingsfolge**, Symbol 121 des Bursts [03 §3.6.1, aus
ETSI Tabelle 9.5 abgeleitet]. Mit der NUB-Burst-Verzögerung `d = 17`
[ETSI Tabelle 9.2] und `SN(n)` bei `(n + d)` Symboldauern nach Slot-Start
[ETSI §9.4.3.4] liegt der Anker bei `121 + 17 = 138` Symboldauern
= **7,6667 ms** nach UL-Slot-Start.

**Term 3 — Pipeline.** Der Sende-Anker wird **vor** der Sendekette abgegriffen
(erster Dibit an den Modulator), der UL-Anker **nach** der Empfangskette. Beide
Latenzen **addieren** sich daher.

Aus dem V1-Kalibrierwert TS1 = 8,340 ms folgt
`L_pipe = 8,340 − 7,667 = 0,673 ms`. Bilanz:

| Beitrag | Wert | Beleg |
|---|---|---|
| Sende-RRC, Gruppenlaufzeit `(N−1)/(2L)` = 4 Symbolperioden | 222,2 µs | [04 §3.8], [CODE rtl/tx/tetra_rrc_filter.v:39] |
| Sende-CIC-Interpolator, `N(R−1)/2` = 157,5 Samples @ 4,608 MHz | ~34 µs | [ANNAHME: Rechnung, R = 64, N = 5 aus CODE rtl/tx/tetra_tx_frontend.v:62-65] |
| Empfangs-CIC-Dezimator, `N(R−1)/2` | ~34 µs | [ANNAHME: Rechnung, R = 64, N = 5] |
| Empfangs-RRC, Gruppenlaufzeit 16 Ausgangssamples @ 72 kHz | 222,2 µs | [02 §3.3], [CODE rtl/rx/tetra_rx_frontend.v:42] |
| Digitale Pipelinestufen (FIFO, MAC, Korrelator-Register) | < 1 µs | [02, 03] |
| Ausbreitung (Labor, wenige Meter) | < 0,1 µs | [ANNAHME] |
| **Summe erklärt** | **~512 µs** | |
| **Restposten** | **~161 µs** | interne Filterketten des Transceivers, LVDS-Übergänge — in V1 **nicht** vermessen |

**V2-Vorgabe (R-08-08).** Die V2-Messung wird andere Werte liefern. Verbindlich
ist: Die Abweichung der gemessenen TS1-Differenz von `7,6667 ms` muss aus den
Stufenlatenzen der Kapitel 02, 03 und 04 aufgeschlüsselt werden, und der
unerklärte Restposten darf **≤ 100 µs** betragen. Ein größerer Restposten
bedeutet, dass eine Stufe eine undokumentierte Verzögerung hat — das ist ein
Befund, kein Toleranzwert.

**Zwei Genauigkeitsgrenzen, die V1 nicht adressiert hat.**

1. Die Stoppuhr zählt `clk_sys`-Takte, das gemessene Intervall ist aber durch
   das `clk_lvds`-Raster definiert. `clk_sys` (PS-`FCLK_CLK0`) und `clk_lvds`
   (Transceiver-`DATA_CLK`) stammen aus **verschiedenen** Quellen
   [01 §3.2, R-01-02]. Ein Frequenzfehler von `clk_sys` erscheint daher als
   **Skalenfehler** der Differenz: bei ±50 ppm sind das auf 50,8 ms ±2,5 µs.
   [ANNAHME: Rechnung; der `clk_sys`-Fehler wurde in V1 nicht vermessen.] Das
   ist genau die Größenordnung der beobachteten Streuung.
2. Die V1-Konstante für einen Zeitschlitz in `clk_sys`-Takten ist
   `1 416 700` [CODE sw/tetra_ts_map.h:37]. Exakt sind es
   `100 MHz × 85/6 ms = 1 416 666,67` — nicht ganzzahlig. Die V1-Konstante ist
   33 Takte (+23 ppm) zu groß; über den TS1…TS4-Bereich summiert sich das auf
   +1 µs und ist gegenüber der ±0,5-Zeitschlitz-Zuordnungstoleranz irrelevant.

**V2-Empfehlung, die beide Punkte beseitigt:** Die Stoppuhr zählt **Symbol-Ticks
zusätzlich zu `clk_sys`-Takten**. Das Grobmaß (`sym_en`-Zählung) ist dann exakt
ganzzahlig auf dem Luft-Raster und vollständig unabhängig von der
`clk_sys`-Genauigkeit; der `clk_sys`-Feinanteil liefert die Sub-Symbol-Auflösung.
Verbindliche Zuordnung Differenz → Zeitschlitz erfolgt danach über die
Symbol-Zählung, nicht über die Zyklenzahl.

#### 3.2.6 Die Messung als Regressionsdetektor — Verfahren

Diese Messinfrastruktur ist kein Diagnose-Nebenprodukt, sondern das
**Abnahme- und Regressionsinstrument** für die gesamte analoge und
Sample-Pipeline. In V1 hat genau sie mehrere fehlgeschlagene
Mehrgruppen-Versuche aufgeklärt, die vorher für ein Endgeräte-Problem gehalten
wurden [MESS 2026-05-25]. Die Diagnose lautete zunächst „MS-Firmware ignoriert
die Kanalzuweisung"; sie war falsch. Erst die Messung zeigte, dass die
Slot-Zuordnung im Umschlag-Bereich zweideutig war.

**Verfahren (verbindlich in `14_VERIFICATION.md` zu verankern):**

1. **Referenzlauf nach Bring-up.** Vier kontrollierte Einzel-Zuweisungen
   TS1…TS4, je ≥ 20 UL-Bursts. Erfasst werden Differenz-Mittelwert und
   Spannweite je Zeitschlitz. Ergebnis wird als Referenztabelle im
   Build-Artefakt abgelegt.
2. **Auslöser für eine Wiederholung** (R-08-09) — jede Änderung an:
   Sendefilter-Koeffizienten oder -Struktur; Interpolations- oder
   Dezimationsfaktor; Empfangsfilter; Position des Sync-Latches;
   Takt-Domänenübergängen; Transceiver-Filterkonfiguration; Symbol-Tick-Teiler.
3. **Bewertung.**

| Beobachtung | Bewertung | Nächster Schritt |
|---|---|---|
| Schrittweite verletzt ±1 `Tsym` | **Blocker** | Slot-Raster oder Ankerlage defekt — nicht in Betrieb nehmen |
| Schrittweite ok, Absolutwerte alle um denselben Betrag verschoben | Pipeline-Latenz geändert | Betrag gegen die geänderte Stufe bilanzieren (§3.2.5). Erklärbar ⇒ Referenztabelle aktualisieren. Nicht erklärbar ⇒ Blocker |
| Absolutwerte um ~1 Zeitschlitz verschoben | Slot-Versatz | Anker-Slot, Zeitplan oder Lookahead prüfen |
| Absolutwerte springen zwischen zwei Klassen mit ~1 Frame Abstand | Umschlag | Ankerlage prüfen (§3.2.2) |
| Streuung > 1 Symboldauer | Sync-Anker instabil | Korrelatorschwelle, Amplitudennormierung (03 §4) |
| Ereigniszähler steigt nicht | kein UL-Sync | RX-Kette, nicht Timing |

4. **Verbotene Reaktion.** Eine Abweichung darf **nicht** durch Anpassen der
   Zuordnungskonstante „weggerechnet" werden, bevor die Ursache benannt ist. Die
   Konstante ist ein Messergebnis, kein Stellknopf. V1 hat diese Regel explizit
   festgehalten, weil das Mapping sonst kippt. Die drei bit-stabilen
   Differenzwerte für TS2/TS3/TS4, gegen die geprüft wird, stehen in §3.2.5
   dieses Kapitels [MESS 2026-05-25, DL→UL-Air-Lock-Stoppuhr über die
   Messregister CODE sw/tetra_hal.h:354-356].

#### 3.2.7 Zuordnung Differenz → Zeitschlitz

Die Software rechnet die Differenz in einen ETSI-Zeitschlitz um. Verbindlicher
Algorithmus (Umsetzung im zentralen Mapping-Modul, 04 §3.2.3):

```
rel   = (delta − delta_TS1) mod (4 × TS)
ts_ix = round(rel / TS)                     // nächster Mittelpunkt
TS    = (ts_ix mod 4) + 1                   // ETSI 1..4
```

Toleranz: ±0,5 Zeitschlitz = ±7,08 ms. Die gemessene Streuung liegt bei ±14 µs
— das ist ein Sicherheitsabstand von Faktor ~500. Die V1-Implementierung
[CODE sw/tetra_ts_map.h:79-95] arbeitet genau so; der Modulo-Term fängt den
Frame-Umschlag ab, der mit korrekter Ankerlage (§3.2.2) gar nicht auftreten
darf. **V2 behält den Modulo als Sicherheitsnetz, zählt aber jeden Fall, in dem
er greift** (`UL_TS_MAP_WRAP_CNT`) — greift er, ist die Ankerlage falsch.

Randfall „Differenz ohne zugehörigen Anker" (erster UL-Burst nach Reset, bevor
je ein Anker gefeuert hat): Die Hardware liefert eine Differenz gegen den
Reset-Wert 0. **V2-Festlegung:** ein `anchor_seen`-Bit im Statuswort; die
Software verwirft die Zuordnung, solange es 0 ist, und zählt den Fall.

### 3.3 Das Zeitbudget der Uplink-Zuweisung

**Das ist die Zahl, an der V1 gescheitert ist.**

#### 3.3.1 Herleitung

Gegeben: Ein MS macht einen Zufallszugriff auf dem UL-Slot `k` des Frames `N`.
Die Basisstation will, dass das MS den **Folge**-Burst auf dem UL-Slot `k` des
Frames `N+1` sendet. Das ist die Zuweisung mit `granting delay = 0000`,
„Kapazitätszuweisung bei nächster Gelegenheit", die sich auf den
gleichnummerierten UL-Zeitschlitz **desselben** TDMA-Frames bezieht
[ETSI §23.5.2.2.2]. Diese Zuweisung muss folglich im **DL-Slot `k` des Frames
`N+1`** stehen — als Zugriffszuweisungsfeld im Broadcast-Feld und/oder als
Zuweisungselement in der adressierten PDU.

Zeitachse, Bezug = Start des DL-Slots `k` im Frame `N`:

| Ereignis | Zeitpunkt | Rechnung |
|---|---|---|
| Start des UL-Slots `k`, Frame `N` | 28,333 ms | 2 × 85/6 ms [ETSI §9.3.9] |
| **UL-Sync-Anker, Zufallszugriff im Unterschlitz 1** | 32,556 ms | + (59 + 17) × 500/9 µs [03 §3.4.1; ETSI Tab. 9.2] |
| **UL-Sync-Anker, Zufallszugriff im Unterschlitz 2** | 39,639 ms | + (59 + 144,5) × 500/9 µs |
| Ende des UL-Slots `k`, Frame `N` | 42,500 ms | 3 × 85/6 ms |
| **Start des DL-Slots `k`, Frame `N+1`** = **Frist** | **56,667 ms** | 4 × 85/6 ms |

Daraus die Budgets **ab UL-Sync-Anker**:

| Fall | Budget | Bemerkung |
|---|---|---|
| Zugriff im Unterschlitz 1 | 24,11 ms | günstiger Fall |
| **Zugriff im Unterschlitz 2** | **17,03 ms** | **bindend** — die Basisstation kann den Unterschlitz nicht wählen |
| Voll-Slot-NUB (Anker bei 138 `Tsym`) | 20,67 ms | Fortsetzungs-Bursts |

**R-08-03 fixiert 17,0 ms** — den bindenden Fall, abgerundet.
[ANNAHME: Rechnung aus den zitierten ETSI-Stellen und der Ankerlage aus
Kapitel 03; **keine** Messung. Gemessen ist nur, dass V1 diese Frist mit einem
Software-Umlauf **nicht** gehalten hat, siehe §3.3.3.]

#### 3.3.2 Was in das Budget noch hineinmuss

| Posten | V1-Wert | Beleg |
|---|---|---|
| Burst-Erfassung nach Anker (CB-Pfad): `POST_WAIT` | 2,39 ms | [03 §3.8] |
| Ausgabe der erfassten Werte | 0,87 µs | [03 §3.8] |
| SCH/HU-Decodierung (falls inhaltsabhängig entschieden wird) | ~20 µs | [03 §3.8] |
| SCH/HD-Codierung der Zuweisungs-PDU | 4,87 µs | [CODE rtl/lmac/tetra_sch_hd_encoder.v:27] |
| Einstellen in die Sende-Warteschlange | < 1 µs | [CODE rtl/lmac/tetra_dl_signal_queue.v:38-42] |

**Rein hardware-lokal, inhaltsunabhängig (R-00-02):** Auslöser ist der
Sync-Treffer. Verbrauch ≈ 5 µs Codierung. **Restreserve ≈ 17,0 ms.**

**Inhaltsabhängig in Hardware (V1-Weg):** Auslöser ist der abgeschlossene
SCH/HU-Decode. Verbrauch ≈ 2,41 ms. **Restreserve ≈ 14,6 ms.** Funktioniert,
verletzt aber R-00-02.

**Mit Software-Umlauf (V1-Umbau, gescheitert):** zusätzlich das
Abfrage-Intervall des Dienstes und der Mailbox-Handschlag.

#### 3.3.3 Warum der Software-Umlauf die Frist nicht halten kann

| Posten des Software-Wegs | V1-Wert | Beleg |
|---|---|---|
| Abfrage-Intervall der Hauptschleife | 10 ms, gleichverteilt 0…10 ms | [CODE sw/tetra_attach_daemon.c:86, :1206-1210] |
| Mailbox-Lesen, Decodieren, Parsen, Antwort-Mailbox schreiben | nicht vermessen | — |
| Wartezeit auf „Antwort-Mailbox frei" | Spin bis **50 ms** | [CODE sw/tetra_tx_transport.c:54-56] |
| Warteschlange → Luft | bis 1 Frame = 56,7 ms (§3.4.1) | [CODE rtl/lmac/tetra_dl_signal_scheduler.v:18-24] |

Der erste Posten allein verbraucht im Mittel 5 ms und im Worst Case 10 ms von
17,0 ms; der dritte kann die Frist um Faktor 3 überschreiten. Der Weg ist damit
nicht *langsam im Mittel*, sondern **nicht deterministisch beschränkt** — und
eine Slot-Frist verlangt eine obere Schranke, keinen Mittelwert.

**Gemessene Folge auf der Luft** [MESS 2026-07-11]: Die Anmeldung „klebte" nicht
zuverlässig; das MS wiederholte seine Anforderung; jede Wiederholung löste eine
weitere Zuweisung aus; die Zuweisungen fluteten die
Signalisierungs-Warteschlange; die Anmeldebestätigung erreichte das MS nicht
mehr; das MS meldete sich erneut an. Eine Ratenbegrenzung von 120 ms je
Teilnehmeradresse milderte die Symptome, behob die Ursache nicht. Der Umbau
wurde zurückgenommen.

Dass die Warteschlange überhaupt geflutet werden kann, ist quantifizierbar: der
Signalisierungs-Scheduler entnimmt **höchstens eine PDU pro Frame** je
Kontrollkanal-Slot (§3.4.1) — 17,65 PDU/s. Eine Zuweisung pro
MS-Wiederholung erreicht diese Rate mit wenigen Endgeräten. Bei einer Tiefe von
4 Einträgen und Verwurf des jüngsten [CODE rtl/lmac/tetra_dl_signal_queue.v:11]
fällt genau die Bestätigung heraus, auf die das MS wartet — die Rückkopplung
schließt sich.

#### 3.3.4 Verbindliche V2-Struktur des Zeitpfads

```
ul_sync_found_sys ──▶ Zuweisungs-Erzeuger (PL)  ──▶ SCH/HD-Codierung (5 µs)
                          ▲                              │
       Muster-Register    │                              ▼
       (Unterschlitz-     │                    Sende-Warteschlange, Prio hoch
        anzahl, Halte-    │                              │
        dauer, Wieder-  ──┘                              ▼
        holung) ← PS                        DL-Slot k, Frame N+1  (Frist)
```

- Der Zeitpfad `ul_sync_found_sys` → Bits in der Warteschlange enthält
  **keinen** PS-Zugriff (R-08-04).
- Die Software beschreibt nur die Muster-Register, und zwar zu einem beliebigen
  Zeitpunkt vorher (R-00-03).
- Ein Zähler `grant_late_cnt` inkrementiert, wenn der Erzeuger die Bits nicht
  vor dem `slot_pulse` des Ziel-Slots bereitstellt. Der Zähler muss im Betrieb
  0 sein; er ist das Luft-Abnahmekriterium für R-08-03.
- Ein Zähler `grant_emit_cnt` je Auslöseart macht die
  Zuweisungs-**Rate** sichtbar. Das Abnahmekriterium gegen die Spirale
  (00 §3.4) lautet: `grant_emit_cnt`-Rate ≤ 1 pro erkanntem UL-Sync und
  ≤ Slot-Rate des Kontrollkanals.

#### 3.3.5 Mehrslot-Reservierung — Haltedauer

Eine Zuweisung von `N` Slots verlangt, dass die Zugriffszuweisung des
betreffenden Zeitschlitzes für `N` aufeinanderfolgende Frames als reserviert
ausgewiesen bleibt, statt nach einem Frame wieder Zufallszugriff zu öffnen.

**Beleg aus einem eigenen Referenz-Mitschnitt** [MESS 2026-06-10]: Bei einer
Kapazitätszuweisung von 3 Slots hielt die Referenz-Basisstation die
Zugriffszuweisung des Kontrollkanal-Slots über die Frames FN09/FN10/FN11 auf
„beide Unterschlitze reserviert" (AACH-Infowort `0x0000`) und öffnete erst in
FN12 wieder Zufallszugriff.

> ⚠️ **Kein [GOLD]-Beleg.** Diese Beobachtung stammt aus einem eigenen
> 392-MHz-Mitschnitt der Referenzzelle vom 2026-06-10, der **nicht** im Repo
> liegt. In der abgelegten Gold-Aufzeichnung `docs/reference_decode/` ist das
> Muster **nicht** nachprüfbar: über alle 7338 DL-Bursts tritt das AACH-Infowort
> `0x0000` **nie** auf (vorkommende Werte: `0x3000`, `0x0249`, `0x0040`,
> `0x32CB`, `0x2049`, `0x0049`, `0x2249`, `0x0009`, `0x22C9`, `0x304B`), und auf
> dem Kontrollkanal-Slot TN1 gibt es keine Dreier-Folge FN09/FN10/FN11 mit
> reserviertem Muster [GOLD `docs/reference_decode/dl_events.jsonl`, Auszählung
> über `aach_info_14b`]. Für V2 ist die Regel unten daher **nicht** über einen
> Repo-Vergleich abnehmbar, sondern nur über einen eigenen Mitschnitt (§5.3 C).

**V1-Fehler und Fix** [MESS 2026-06-12]: V1 hielt nur den Zuweisungs-Frame
selbst, und den auch nur halb; ab dem Folge-Frame stand wieder Zufallszugriff.
Folge: das MS sendete **ein** Fortsetzungsfragment und brach ab. Nach Einbau
eines Haltezählers, der mit der Kapazitätszuweisung geladen und je
Kontrollkanal-Frame dekrementiert wird
[CODE rtl/tx/tetra_aach_encoder.v:74-81, :178-179, :199-252], sendete das MS
Start + 3 Fortsetzungsfragmente; ein externer Empfänger reassemblierte 6
vollständige Ketten à 842 bit — bit-identisch zu den Gold-Fragmenten.

**V2-Regel:** Haltedauer = Wert der Kapazitätszuweisung, **beginnend mit dem
Zuweisungs-Frame selbst**. Der Haltezähler ist Teil des Zuweisungs-Erzeugers in
der PL und wird nur aus dessen Muster-Registern parametriert.

### 3.4 Antwortfenster für Signalisierung

#### 3.4.1 Frame-Quantisierung

Der Signalisierungs-Scheduler entnimmt der Warteschlange höchstens **eine PDU
pro Frame** je Kontrollkanal-Slot: der Entnahme-Auslöser ist
`slot_pulse && (tn == Ziel-Slot) && Kopf gültig`
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:18-24]. Daraus:

| Größe | Wert |
|---|---|
| Antwort-Zeitraster | 1 TDMA-Frame = 56,667 ms |
| Maximaldurchsatz Signalisierung, 1 Kontrollkanal-Slot | 17,65 PDU/s |
| Frühestmögliche Antwort auf einen UL-Burst aus Frame N | DL-Frame N+1 |
| Zeit von UL-Burst-Ende bis Frist des Frames N+1 | 14,167 ms (= 1 Zeitschlitz) |

Der letzte Wert ist die harte Frist, wenn im unmittelbar folgenden Frame
geantwortet werden soll: das UL-Slot endet bei 3 Zeitschlitzen nach dem
DL-Bezugsslot, der DL-Slot des Folge-Frames beginnt bei 4 (§3.3.1).

**Gold-Beleg für 17,65 PDU/s** [GOLD]: Die Rate der Zugriffszuweisungen im
Referenz-Capture beträgt 17,4/s, im eigenen Capture ebenfalls 17,4/s
[docs/local_cell_decode/DIFF_vs_reference.md, Abschnitt AACH-Pattern-Diff] —
also ein Kontrollkanal-Slot pro Frame in beiden Netzen.

#### 3.4.2 Vor-Antwort und Antwort — die gemessene Struktur der Referenz

Die absoluten UL→DL-Latenzen der Gold-Aufzeichnung sind **nicht** belastbar
(§3.8.1). Belastbar ist die **Frame-Struktur** innerhalb des DL-Captures. Zwei
Sequenzen, direkt aus den Burst-Daten:

**Anmeldung (fragmentierte UL-PDU), Referenz, MN49** [GOLD
docs/reference_decode/dl_events.jsonl]:

| DL-Frame | Slot | Kanal | Inhalt |
|---|---|---|---|
| FN01 | TS1 | SCH/HD | NULL-PDU (Füller) |
| **FN02** | TS1 | SCH/HD | **Vor-Antwort**: MAC-RESOURCE, adressiert, LI = 7 Oktette, Zuweisungsflag = 1, Zuweisungselement = `0x00` (erster Unterschlitz, nächste Gelegenheit), **ohne TM-SDU, kein LLC-Anteil** — die 5 Restbits hinter dem 51-bit-MAC-Kopf sind Füllbits nach `06 §3.7` F4 (Nachrechnung in `09 §3.1.1`) |
| FN03 | TS1 | SCH/HD | NULL-PDU (Füller) |
| **FN04** | TS1 | SCH/F | **Antwort**: MAC-RESOURCE, LI = 21, LLC BL-ADATA NS = 1, MM D-LOC-UPD-ACCEPT |
| FN05…FN08 | TS1 | SCH/HD | NULL-PDU |

Die zugehörigen UL-Bursts liegen ein Frame vor der jeweiligen DL-Reaktion und
nutzen den Frame dazwischen: Fragment 1 in UL-Frame FN01, Fragment 2 (MAC-END-HU)
in UL-Frame FN02 — also in dem Frame, dessen Unterschlitz die Vor-Antwort aus
FN02 zuweist —, und die LLC-Quittung des MS auf die Antwort in UL-Frame FN03
[GOLD docs/reference_decode/ul_events.jsonl, UL #0/#1/#2, Abstände 57 ms und
113 ms].

**Gruppenruf-Aufbau, Referenz, MN60** [GOLD]:

| DL-Frame | Kanal | Inhalt |
|---|---|---|
| **FN01** | SCH/HD | **Vor-Antwort**: MAC-RESOURCE, adressiert, LI = 6 Oktette, **kein** Zuweisungselement, LLC-Typ `0011₂` = BL-ACK [ETSI Tabelle 21.1] |
| **FN02** | SCH/F | **Antwort**: D-CONNECT (1/3) |
| FN03 | SCH/F | vom Decoder **nicht** geparst; Infowort beginnt mit MAC-PDU-Typ `01₂` (MAC-FRAG/MAC-END) — **kein** NULL-PDU-Füller |
| FN04 | SCH/F | D-CONNECT (2/3) |
| FN05 | SCH/F | wie FN03, Infowort **bit-identisch** |
| FN06 | SCH/F | D-CONNECT (3/3) |
| FN07 | SCH/F | wie FN03, Infowort bit-identisch |
| FN08 | SCH/HD | NULL-PDU (Füller): MAC-RESOURCE `addr=NULL`, LI = 2 Oktette |

Belegstellen für die drei Zwischen-Frames: `dl_events.jsonl` idx 5891 / 5899 /
5907 (TN1, MN60, FN03/FN05/FN07), `mac: []`, `info_268b` beginnt
`0111000010101000…`, in allen drei Bursts identisch; der Füller ist idx 5911
(FN08) [GOLD docs/reference_decode/dl_events.jsonl].

#### 3.4.3 Die daraus abgeleiteten Regeln

**R-1: Vor-Antwort im Frame N+1.** Beide Sequenzen zeigen die Vor-Antwort genau
einen Frame nach dem auslösenden UL-Burst. Die Vor-Antwort ist kurz
(6–7 Oktette), passt in SCH/HD und hat genau eine Aufgabe: dem MS zu bestätigen,
dass sein Burst angekommen ist, und ihm — wenn er fragmentiert war — den
Unterschlitz für die Fortsetzung zuzuweisen. Sie ist deshalb der Teil, der die
Slot-Frist einhalten muss, und liegt in V2 in der PL.

**R-2: Die Art der Vor-Antwort hängt davon ab, ob das MS noch senden muss.**

| Auslösender UL-Burst | Vor-Antwort | Zweck |
|---|---|---|
| MAC-ACCESS mit Fragmentierungsflag | MAC-RESOURCE + Zuweisungselement `0x00`, **ohne TM-SDU** (`09 §3.1.1`) | MS braucht den Unterschlitz für Fragment 2 |
| Einzelner MAC-ACCESS mit LLC BL-DATA | MAC-RESOURCE ohne Zuweisung, LLC BL-ACK | MS-LLC-Wiederholungszeitgeber stoppen |

**R-3: Der Frame-Abstand zwischen Vor-Antwort und Antwort ist kein Selbstzweck,
sondern der Platz für den UL-Burst des MS.** Bei der Anmeldung liegen zwei
Frames zwischen Vor-Antwort (FN02) und Antwort (FN04), weil das MS in UL-Frame
FN02 sein Fragment 2 sendet und die Basisstation erst danach die vollständige
Nachricht hat. Der DL-Slot des Zwischen-Frames FN03 trägt dort den Füller
(`addr=NULL`, LI = 2) — die Referenz belegt ihn **nicht** mit einer weiteren
adressierten PDU [GOLD MN49 FN03, idx 779]. Diese Aussage ist **nur** für den
Anmeldeablauf MN49 belegt; im Gruppenruf-Ablauf MN60 tragen die Zwischen-Frames
FN03/FN05/FN07 einen unparsierten SCH/F-Burst mit MAC-PDU-Typ `01₂`, also
keinen Füller (§3.4.2). Beim
Gruppenruf entfällt dieser Abstand, weil die Anforderung ein einziger Burst war:
Vor-Antwort FN01, Antwort FN02.

> **Abweichung V1 ↔ Referenz, die V2 auflöst.** V1 sendet zusätzlich eine
> LLC-Quittung nach Fragment 2, ausgelöst auf „Zusammensetzung fertig", und legt
> sie damit in genau den Frame, den die Referenz frei lässt
> [CODE rtl/lmac/tetra_pre_reply_blck.v:6-21, rtl/tetra_zynq_top.v:2521-2527].
> In der Gold-Aufzeichnung existiert diese PDU nicht. **V2-Festlegung:** Eine
> LLC-Quittung wird nur dann als eigene PDU gesendet, wenn keine substanzielle
> Antwort innerhalb von 2 Frames folgt; andernfalls trägt die Antwort selbst die
> Quittung (`NR`-Feld). Ein Frame darf höchstens eine adressierte PDU je
> Kontrollkanal-Slot tragen — das ist ohnehin die Kapazitätsgrenze aus §3.4.1.

**R-4: Wiederholungsabstand für substanzielle Antworten = 2 Frames.**
Referenz: D-CONNECT auf FN02/FN04/FN06 = 2 Frames = 113,33 ms Abstand [GOLD].
V1 verwendet 113 ms, nicht blockierend über die Ereigniszeit gestellt
[CODE sw/tetra_call_fsm.c:455-463, :479, :750]. Das eigene Capture von
2026-05-15 zeigte dagegen 1-Frame-Abstand (FN12/FN13/FN14)
[docs/local_cell_decode/BUGS_LIST.md, BUG-005] — inzwischen behoben.

**Messung nach dem Fix** [MESS 2026-05-20], 8 PTT-Vorgänge, Bezug = Empfang der
Ruf-Anforderung:

| Ereignis | Δ |
|---|---|
| D-CONNECT (1) | 0 ms |
| D-CONNECT (2) | 122 ms |
| D-CONNECT (3) | 244 ms |
| D-SETUP | 245 ms |

Die 122 statt 113 ms sind die Quantisierung des 10-ms-Abfrageintervalls
[CODE sw/tetra_attach_daemon.c:86]. **V2-Regel:** Wiederholungsabstände werden
in **Frames** ausgedrückt und aus dem Zeitstempel gerechnet, nicht in
Millisekunden über die Ereigniszeit — sonst trägt jeder Abstand die
Abfragegranularität als Fehler. Die Toleranz eines
2-Frame-Wiederholungsabstands beträgt ±½ Frame; 10 ms Abfrageintervall passen
hinein, sind aber unnötig.

**R-5: Spielraum des Software-Umlaufs.** Für die substanzielle Antwort hat die
Software ein Budget von einem Frame minus der Warteschlangen-Latenz, also
≈ 56,7 ms je Antwortstufe, und darf dabei die nächste Stufe verzögern, nicht
aber verlieren. Verbindlich:

- Die Antwort-Erzeugung **blockiert nie** die Hauptschleife. V1 hatte hier drei
  Antwortstufen mit **zwei** Wartezeiten à 113 ms synchron im Antwortpfad
  = 226 ms Blockade je Anforderung [CODE sw/tetra_call_fsm.c:455-463];
  während dieser Zeit wurden keine weiteren UL-PDUs verarbeitet, sodass eine
  MS-Wiederholung die volle Sequenz erneut auslöste. Messung vor/nach dem Umbau
  auf eine nicht blockierende Zustandsmaschine [MESS 2026-05-17], je 10 PTT:

| Metrik | Mit Blockade | Nicht blockierend |
|---|---|---|
| Median Sprechtaste → Sprachweg | 0,95 s | **0,58 s** |
| Mittelwert | 1,4 s | **0,76 s** |
| Minimum | 0,5 s | 0,02 s |
| Maximum | 3,6 s | 2,0 s |
| MS-Wiederholungen | 3/10 = 30 % | **1/9 = 11 %** |

- Der Gold-Wiederholungsabstand **bleibt** erhalten. Ein Zwischenversuch, der
  die Schlafzeit einfach entfernte, erzeugte einen Fall, in dem das MS drei zu
  schnell aufeinanderfolgende Antworten verwarf [MESS 2026-05-17]. Der Abstand
  ist MS-Konformitätsbedingung, nur seine Implementierung war falsch.

### 3.5 Zeitgeber der Fragment-Zusammensetzung

#### 3.5.1 Die zwei Fenster

| Fenster | Kette | V1-Betriebswert | V1-Beleg |
|---|---|---|---|
| **Zwei-Burst-Fenster** | MAC-ACCESS (frag) + MAC-END-HU, beide SCH/HU | **1 Frame ≈ 57 ms** — die Software schreibt `REG_REASSEMBLY_T0 = 1` im Init [CODE sw/tetra_hal.c:1807-1808], verdrahtet nach `t0_frames_sys` [CODE rtl/tetra_zynq_top.v:751]. **2 Frames sind nur der RTL-Fallback für Registerwert 0** [CODE rtl/rx/tetra_ul_demand_reassembly.v:67, :122-123]; der SW-Spiegel 113 ms [CODE sw/tetra_ul_reassembly.h:23] gehört zu diesem Fallback, nicht zum Betriebswert |
| **Mehr-Fragment-Fenster** (V1-Wert; V2 siehe §3.5.2) | MAC-ACCESS (frag) + N × MAC-FRAG + MAC-END, Fortsetzungen auf SCH/F | 4 Frames ≈ 227 ms | [CODE rtl/rx/tetra_ul_schf_reassembly.v:38], SW-Spiegel 227 ms [CODE sw/tetra_ul_reassembly.h:68] |

**Der air-verifizierte V1-Wert des Zwei-Burst-Fensters ist damit 1 Frame**, nicht
2 Frames. Das ist keine Nachlässigkeit, sondern eine bewusste Verkürzung mit
einer Begründung, die V2 kennen muss — siehe §3.5.2 („Warum V1 auf 1 Frame
verkürzt hat").

Einstellbereich in V1: 1…15 Frames über ein 4-bit-Feld, `0` bedeutet
„Standardwert verwenden" [CODE rtl/rx/tetra_ul_demand_reassembly.v:122-123,
rtl/rx/tetra_ul_schf_reassembly.v:95]. **In V2 ist dieses Feld entfallen** und der Wert
fest (§3.5.2); es gibt weder ein Register noch einen Konfigurationsschlüssel
(`13 §3.7`). Der Zeitgeber wird je Frame-Puls um 1
dekrementiert; erreicht er 0, wird der Eintrag freigegeben und ein
Verwurfszähler erhöht [CODE …demand_reassembly.v:183-200,
…schf_reassembly.v:207-208, :257-260].

#### 3.5.2 Die Standardwerte sind zu kurz — Belegkorrektur

Der V1-Kommentar am Fallback-Parameter des Zwei-Burst-Fensters behauptet
„ETSI ≈ 2 Frames = 113 ms" [CODE rtl/rx/tetra_ul_demand_reassembly.v:67]. Das
ist **falsch belegt** (und der Wert ist ohnehin nicht der Betriebswert, §3.5.1). Die
ETSI-Werte sind:

| Konstante | Wert | Bedeutung | Beleg |
|---|---|---|---|
| `T.202` | 9 Downlink-Signalisierungs-Frames | Fragmentierungs-Zeitablauf des MS | [ETSI Annex B.1] |
| `N.203` | ≥ 4 Zeitschlitze ohne Fragment | danach verwirft die MAC eine unvollständige Nachricht | [ETSI Annex B.2] |
| `T.206` | 18 Downlink-Signalisierungs-Frames, `T.206 ≥ T.202` | Wartezeit reservierter Zugriff | [ETSI Annex B.1] |

Beide Annex-B-Größen sind **MS-Konstanten**; für die Empfangsseite der
Basisstation legt ETSI keinen Zahlenwert fest. Auf einem
Ein-Slot-Kontrollkanal ist eine Signalisierungs-Gelegenheit ein Frame, also
`N.203 ≥ 4` ⇒ **≥ 4 Frames ≈ 227 ms**, und `T.202 = 9` ⇒ 510 ms auf der
MS-Seite.

**V2-Festlegung.** Das Empfangsfenster der Basisstation ist mindestens so
tolerant wie die MS-Verwurfsregel, damit die Basisstation nicht vor dem MS
aufgibt:

Der Wert ist **hier** normativ (Zeitgröße, P2); `06 §3.12` (`REASS_T0_FRAMES`) und
`11 §3.7.3` (`T0`) verweisen darauf und wiederholen ihn nicht.

| Fenster | V2-Wert | Einstellbarkeit | Begründung |
|---|---|---|---|
| Zwei-Burst | **9 Frames = 510 ms** | **fest** | `T.202 = 9` Downlink-Signalisierungsframes [ETSI Annex B.1] — die Verwurfsfrist des **Endgeräts**; die Basisstation gibt damit nicht vor dem Endgerät auf. `N.203 ≥ 4` [ETSI Annex B.2] ist nur die **Untergrenze** und von 9 eingehalten. V1s Betriebswert von 1 Frame liegt weit darunter (§3.5.1) |
| Mehr-Fragment | **9 Frames = 510 ms** je Fragment-Lücke, Zeitgeber bei jedem Fragment neu geladen | **fest** | wie oben. Zusätzliches Argument aus `11 §3.7.3`: ein kürzerer Wert kostet ganze Nachrichten, sobald die Zusage über mehrere Grant-Nachrichten verteilt wird, was ETSI ausdrücklich erlaubt [ETSI §23.4.2.1.2 NOTE 9]. V1 hat hier 4 Frames [CODE …schf_reassembly.v:38, :254] |

**Warum fest und nicht einstellbar.** Beide Fenster tragen **denselben** Wert, und dieser
Wert ist keine Zell-Eigenschaft, sondern die Spiegelung einer ETSI-Endgerätekonstante. Ein
kleinerer Wert ist durch die Begründung oben ausgeschlossen (die Basisstation gäbe vor dem
Endgerät auf), ein größerer ist wirkungslos, weil das Endgerät nach `T.202` selbst verworfen
hat — er hält nur einen Kontext länger belegt, und dagegen wirkt die Ältesten-Regel aus
§3.5.3. Es bleibt kein zulässiger anderer Wert, also gibt es in V2 **kein** Register
(§3.5.1) und **keinen** Konfigurationsschlüssel (`13 §3.7` führt die Festlegung mit
derselben Begründung). Software-Seite: eine Übersetzungskonstante, `06 §3.12`
(`REASS_T0_FRAMES`).

Der Zeitgeber wird bei **jedem** angenommenen Fragment neu geladen, nicht nur
beim ersten — die Frist gilt je Lücke, nicht je Kette. V1 macht das im
Mehr-Fragment-Pfad korrekt [CODE rtl/rx/tetra_ul_schf_reassembly.v:254], im
Zwei-Burst-Pfad ist die Frage nicht relevant (nur eine Lücke).

**Warum V1 auf 1 Frame verkürzt hat — und was V2 anders machen muss.** Die
Verkürzung war **keine** Puffer-Maßnahme, sondern eine Reihenfolge-Kopplung im
Antwortpfad: Die Antwort-Zustandsmaschine wartete nach der Vor-Antwort eine feste
Anzahl Slots — im V1-Kommentar `gap_slot_count = 8`, also 8 Slots = 2 Frames —
und baute danach die Anmeldebestätigung. (Der Bezeichner selbst steht nur noch im
Kommentar; im heutigen RTL/SW existiert kein Signal dieses Namens
[CODE sw/tetra_hal.c:1796-1806].) Mit einem Zwei-Burst-Fenster von 2 Frames endete die
Zusammensetzung samt Auswertung der optionalen Felder erst **zu oder nach**
diesem Baubeginn; die aus dem UL geparsten Werte lagen dann noch nicht vor, die
Zustandsmaschine fiel auf ihren Profil-Standardpfad zurück und sendete eine
kürzere Bestätigung (LI = 12) statt der spec-konformen mit LI = 21. Mit 1 Frame
schloss die Zusammensetzung rund einen Frame früher ab und die Bestätigung wurde
korrekt gebaut [CODE sw/tetra_hal.c:1796-1808].

Diese Kopplung ist der eigentliche Befund, und sie verbietet es, das Fenster
einfach zu verlängern, ohne den Antwortpfad umzubauen. **V2-Festlegung — der
Zeitgeber ist eine obere Verwurfsschranke, kein Warteschritt:**

1. Die Antwort-Erzeugung wird **nicht** vom Fensterablauf getaktet. Auslöser für
   den Bau der substanziellen Antwort ist das Ereignis
   **„Kette vollständig ODER Fenster abgelaufen"** — und zwar dasjenige, das
   zuerst eintritt. Ein fester Slot- oder Frame-Abstand als Ersatz für dieses
   Ereignis ist verboten.
2. Die Antwort-Zustandsmaschine kennt keinen Zustand, in dem sie eine feste
   Wartezeit abzählt und dabei annimmt, die Zusammensetzung sei fertig. Sie
   prüft den Vollständigkeits-Status explizit.
3. Ist die Kette beim Bau der Antwort nicht vollständig, wird der Fallback-Pfad
   **gezählt** (`reass_incomplete_at_reply_cnt`, definiert in `13 §3.10.2`) und
   geloggt, nicht still genommen. Ein von 0 verschiedener Zähler ist ein Befund,
   keine Toleranz.

Nur unter diesen drei Bedingungen ist die Verlängerung von 1 auf 9 Frames
unschädlich. Ohne sie greift der in V1 beobachtete Fehlpfad mit 9 Frames stärker
als mit 2 — die Fenstergröße wäre dann die Ursache eines falschen
Antwortinhalts, nicht nur einer späteren Antwort.

#### 3.5.3 Zu kurz und zu lang — die Wirkungen

| Fenster | Wirkung | Beleg |
|---|---|---|
| **Zu kurz** | Die Basisstation verwirft Fragment 1, während das MS noch Fortsetzungen sendet. Die Fortsetzungen sind dann Waisen und werden still verworfen; die Basisstation antwortet nie; das MS läuft in `T.202` und wiederholt die **ganze** Nachricht. Bei langen Nachrichten kann das nie konvergieren. | Mechanismus aus [ETSI §23.4.2.1.2 b)] |
| **Zu lang** | Belegte Plätze im Zusammensetzungspuffer blockieren neue Ketten. V1 hat 2 Plätze im Zwei-Burst-Puffer und verwirft bei Vollstand die **neue** Adresse [CODE rtl/rx/tetra_ul_demand_reassembly.v:143-147] — ein hängengebliebener Eintrag sperrt also eine echte Anmeldung, und zwar so lange, wie das Fenster läuft. Der Mehr-Fragment-Pfad hat genau **eine** Kette; ein zu langes Fenster sperrt dort alles. | [CODE …schf_reassembly.v:236-261] |
| **Gleiche Adresse erneut** | Wiederholt dasselbe MS Fragment 1, wird der alte Eintrag **ersetzt** und das Fenster neu gestartet — kein Verwurf, denn das ist ein legitimer Neuversuch. | [CODE rtl/rx/tetra_ul_demand_reassembly.v:135-140, :205-213] |

**V2-Pufferdimensionierung:** ≥ 4 gleichzeitige Zwei-Burst-Ketten und ≥ 2
Mehr-Fragment-Ketten. Bei Vollstand wird die **älteste** Kette verworfen, nicht
die neue — eine hängende Kette darf keine frische Anmeldung blockieren. Jeder
Verwurfsgrund hat einen eigenen Zähler (P6): Fensterablauf `reass_t0_cnt`,
Ältesten-Verwurf bei Vollstand `reass_evict_cnt`, herrenloses Fortsetzungsfragment
`reass_orphan_cnt`, dazu `reass_incomplete_at_reply_cnt` aus §3.5.2. Die
Zusammensetzung läuft in Software, deshalb sind diese Zähler **ausschließlich** in
`13 §3.10.2` definiert (Ereignis, Kettenindex, Sollwert); dieses Kapitel nennt nur die
Namen und wiederholt die Definition nicht. Das Ersetzen bei gleicher Adresse ist **kein**
Verwurf und zählt `reass_restart_cnt`.

#### 3.5.4 Das Fenster in V2: aus Zeitstempeln, nicht aus einem Frame-Takt

In V2 liegt die Zusammensetzung in der Software (00 §3.3). Der Zeitgeber wird
**nicht** als Wanduhr und **nicht** aus einem Frame-Puls der DL-Empfangskette
gebildet, sondern aus dem Zeitstempel jedes Bursts (R-08-10). Die Prüfung lautet
mit der Frame-Arithmetik aus §3.7:

```
verworfen = elapsed(letztes_fragment, aktuell) > fenster_frames
```

**Warum das die V1-Kopplung auflöst.** V1 speiste die Fenster-Zeitgeber aus
`frame_tick_sys`, das aus dem **Frame-Zähler der DL-Empfangskette** stammt, die
sich per HF-Rückschluss auf die eigene Aussendung einrastet
[CODE rtl/tetra_zynq_top.v:688-695, :752, :837]. Damit hing die
UL-Zusammensetzung an der DL-Demodulation: fiel der Rückschluss aus, brachen
alle UL-Fenster-Zeitgeber, obwohl der UL-Empfang selbst intakt war. Mit dem
Zeitstempel entfällt die Kopplung vollständig — die Sende-Zeitbasis stempelt,
die Software rechnet.

**Randfall „kein Fortschritt".** Bekommt die Software keine neuen Bursts, tickt
auch kein Zeitgeber. Ein hängender Eintrag würde ewig stehen. **V2-Regel:** Die
Software prüft die Fenster zusätzlich gegen den Zeitstempel des **jüngsten
beliebigen** UL-Ereignisses; kommt gar keines mehr, ist eine offene Kette
unschädlich, weil auch keine neue kommt. Ein Puffer-Vollstand kann dann nur
noch durch die Ältesten-Verwurfsregel entstehen.

### 3.6 Zeitgeber der Ruf-Überwachung

Diese Zeitgeber laufen auf der Ereigniszeit (R-08-13). Ihre Toleranz ist
mindestens 100 ms, sie steuern kein Luft-Timing.

| Zeitgeber | V1-Wert | Was er tut | Beleg |
|---|---|---|---|
| Sprach-Ruhe | 300 ms (**normativ `12` R-12-11**) | Kein UL-Sprachburst auf diesem Zeitschlitz ⇒ Halteplatz dieses Zeitschlitzes löschen (`07 §3.3`, `mode = PERSIST_CLEAR`). Ruf bleibt bestehen. | [CODE sw/tetra_call_fsm.h:43, sw/tetra_call_fsm.c:804-809] |
| Ruf-Verfall | 5 s **vorläufig** (`10` O-10-8) | Kein UL-Sprachburst ⇒ Ruf-Platz freigeben (MS ohne Freigabe verschwunden) | [CODE sw/tetra_call_fsm.h:48, sw/tetra_call_fsm.c:793-803] |
| Klingeldauer Einzelruf | 20 s | Gerufener nimmt nicht ab ⇒ Ruf abbauen | [CODE sw/tetra_call_fsm.h:50, sw/tetra_call_fsm.c:784-791] |
| Abfrageintervall | 10 ms | Kadenz der Überwachungsschleife | [CODE sw/tetra_attach_daemon.c:86] |

**Bezugsgröße für 300 ms.** Auf einem zugewiesenen Sprach-Zeitschlitz kommt je
TDMA-Frame ein UL-Burst; Frame 18 ist Kontroll-Frame [ETSI §9.3.4], also 17
Bursts je Multiframe = **16,67 Bursts/s**, Mittelabstand 1,02 s / 17 = 60 ms.
Der **On-Air-Abstand** ist nicht dieser Mittelwert, sondern 56,7 ms, mit einer
einzelnen Lücke von 113,3 ms über Frame 18. Gold bestätigt das: die
UL-Sprachbursts des Referenz-Captures liegen 56/57 ms auseinander
[GOLD docs/reference_decode/ul_events.jsonl, UL #23…#30: 57/56/57/57/57/56/57 ms].
300 ms entsprechen damit **etwa 5 aufeinanderfolgenden verlorenen Bursts**
(5 × 56,7 ms = 283 ms).

**Messkontext des Wertes 300 ms:** vollständig in `12 §3.6.3` (Nachbarwerte 203 ms und
1000 ms samt Evidenzklasse — die 1000-ms-Aussage ist ein **Hörurteil ohne Zahlengröße**, kein
Zähler- oder Latenzwert). Er wird hier **nicht** wiederholt: `12` R-12-11 ist die normative
Definition (P2). **V2 übernimmt 300 ms unverändert.** Was dieses Kapitel beiträgt, ist die
Bezugsgröße oben: der Wert ist nicht aus der Theorie herleitbar, ableitbar ist nur die
Größenordnung — ein Vielfaches des 56,7-ms-Burst-Abstands (300 ms ≈ 5,3 Burst-Abstände).

**V2-Präzisierung:** Der Ruhe-Zeitgeber wird auf die Burst-**Zeitstempel**
umgestellt: „5 aufeinanderfolgende Frames ohne UL-Burst auf diesem
Zeitschlitz". Das entfernt die Abhängigkeit von der Abfragegranularität und
macht den Wert direkt in Frames prüfbar. Die Wirkung muss gegen die 300 ms
gegengemessen werden, bevor sie übernommen wird.

### 3.7 Nutzung des Zeitstempels — Zeitbezüge in der Software

Bitlage, Wortzuordnung und Feldbreiten des UL-Zeitstempels sind in
`07_PS_PL_CONTRACT.md` normativ (Mailbox-Wort `W1`: `tn_ul`, `fn_ul`, `mn_ul`,
`hn_ul`, `sym_anchor`, `subslot`) und werden hier **nicht** wiederholt (P2).
Dieses Kapitel legt fest, wie daraus Zeitbezüge gebildet werden.

**Regel 1 — der Zeitstempel bezeichnet den Uplink-Slot.** Er ist nicht der
DL-Slot, in dem die Sende-Zeitbasis stand; die Umrechnung um 2 Zeitschlitze
[ETSI §9.3.9] liegt im PL und ist bereits erfolgt [07 §Zeitstempel]. Jede
Verwendungsstelle in der Software schreibt „UL-Slot" aus. Die Werte sind
0-basiert; die Umrechnung nach ETSI 1-basiert erfolgt ausschließlich im zentralen
Mapping-Modul (04 §3.2.3).

**Regel 2 — Zeitdifferenzen werden in Frames gerechnet**, nicht in
Millisekunden. Verbindliche Arithmetik:

```
frame_index(mn, fn) = mn × 18 + fn                     // mn 0..59, fn 0..17
elapsed(a, b)       = (frame_index(b) − frame_index(a) + 1080) mod 1080
```

`1080 = 60 × 18` Frames = 1 Hyperframe = 61,2 s. `hn_ul` wird nicht benötigt,
weil kein Zeitbezug dieses Kapitels länger als ein halber Hyperframe ist (das
längste Fenster sind 15 Frames). Ein Zeitbezug, der `hn_ul` brauchen würde, ist
per Definition kein Luft-Zeitbezug mehr und gehört auf die Ereigniszeit
(R-08-13).

**Regel 3 — der Zeitstempel prüft sich selbst.** Er enthält zwei unabhängig
erzeugte Aussagen über denselben Sachverhalt: `tn_ul` aus der TDMA-Zählerkette
und `sym_anchor` zusammen mit `REG_AIRLOCK_DELTA_CYC` aus der Stoppuhr. Die
Zuordnung nach §3.2.7 muss dasselbe `tn_ul` ergeben, das im Zeitstempel steht.
**V2-Regel:** Die Software vergleicht das bei jedem Burst und zählt Abweichungen
in `UL_TS_MISMATCH_CNT`. Dieser Zähler ist der billigste Dauertest für die
gesamte DL→UL-Zeitkopplung — er läuft im Betrieb mit und muss 0 bleiben. Er ist
zugleich das Frühwarnsignal für §3.2.6, ohne dass ein Messlauf nötig wäre.

### 3.8 Ende-zu-Ende-Latenzen

#### 3.8.1 Was die Aufzeichnungen belegen — und was nicht

Beide Aufzeichnungen bestehen aus **zwei getrennten Mitschnitten** (Downlink und
Uplink, verschiedene Empfänger). Der zeitliche Versatz zwischen ihnen ist nicht
bekannt; die Auswertung setzt ihn so, dass **ein gewähltes Ankerpaar
zusammenfällt**: Referenz `+1,466 s` auf UL #0 ↔ DL #783, eigenes Capture
`−1,222 s` auf UL #0 ↔ DL #873
[docs/reference_decode/action_reaction.md:1-5,
docs/local_cell_decode/action_reaction.md:1-5].

**Damit ist die Latenz des Ankerpaares per Konstruktion 0 und keine Messung.**
Man erkennt es an der Referenz-Sequenz: die Vor-Antwort (DL FN02) liegt nach
dieser Korrektur **vor** dem UL-Burst, den sie beantwortet — der wahre Versatz
ist also um mindestens 2 Frames größer. **Absolute UL→DL-Latenzen aus diesen
Aufzeichnungen sind nicht verwendbar.**

Verwendbar sind:

1. **Frame-Strukturen innerhalb eines Captures** (§3.4.2) — hier liegt die
   belastbare Gold-Evidenz.
2. **Differenzen relativ zum jeweils eigenen Ankerpaar**, weil beide Seiten mit
   derselben Konvention verankert wurden.

**Der Vergleich, der bleibt.** Ruf-Anforderung → erste D-CONNECT, jeweils
relativ zur Anmeldebestätigung desselben Captures:

| | Referenz | Eigene Zelle (2026-05-15) |
|---|---|---|
| Ruf-Anforderung → 1. D-CONNECT | **−6 ms** | **+680 ms** |
| Wiederholungsabstand | +108 / +221 ms (2 Frames) | +737 / +793 ms (1 Frame) |

[GOLD docs/reference_decode/action_reaction.md, UL #22;
docs/local_cell_decode/action_reaction.md, UL #3]

Die eigene Zelle brauchte also **≈ 0,69 s länger** als die Referenz — bei
identischer Verankerungskonvention. Die Tabelle in
`docs/local_cell_decode/DIFF_vs_reference.md` nennt stattdessen 1,9 s: dort
sind die **unkorrigierten** Zeiten beider Mitschnitte verglichen. Der Wert
0,69 s ist der belastbare.

#### 3.8.2 Ursache der 0,69 s — belegt

Das eigene Capture stammt vom **2026-05-15**
[git log docs/local_cell_decode/]. Die nicht blockierende
Antwort-Zustandsmaschine wurde am **2026-05-17** eingeführt
[git log, commit `3c7c320`]. Das Capture zeigt also den Zustand **vor** dem Fix:
drei Antwortstufen mit **zwei** Wartezeiten à 113 ms **synchron** in der
Hauptschleife, = 226 ms Blockade je Anforderung
[CODE sw/tetra_call_fsm.c:455-463], während der keine weiteren UL-PDUs verarbeitet
wurden; eine MS-Wiederholung löste die volle Sequenz erneut aus
[MESS 2026-05-17]. Median 0,95 s, Maximum 3,6 s — die 680 ms des Captures liegen
in diesem Regime.

`BUG-004` in `docs/local_cell_decode/BUGS_LIST.md` benennt als Ursache einen
Scheduling-Rückstand in einer **externen** Referenz-Implementierung. Das ist ein
Doku-Fehler [CONVENTIONS §7]; die Ursache lag im eigenen Antwortpfad (P7). Die
Zahlenangaben derselben Fundstelle (1,2 s / 1,9 s) sind zusätzlich die
unkorrigierten Werte aus §3.8.1.

#### 3.8.3 Gemessene Latenzen und V2-Zeitziele

Alle Werte auf echter Hardware mit zwei kommerziellen Endgeräten.

| Größe | V1 gemessen | Messkontext | **V2-Zeitziel** |
|---|---|---|---|
| Ruf-Anforderung → D-CONNECT (1) | **0 ms** (Antwort noch im selben Abfragezyklus gestellt) | [MESS 2026-05-20], 8 PTT | ≤ 1 Frame ab Empfang |
| Ruf-Anforderung → erster UL-Sprachburst | **133–143 ms**, über alle Läufe ±10 ms; nach Wegfall eines Parser-Durchlaufs deterministisch **133 ms** | [MESS 2026-05-20] / [MESS 2026-05-20, SW-Walker] | ≤ 150 ms, Streuung ≤ 20 ms |
| Sprechtaste → Sprachweg, Median | **0,58 s** | [MESS 2026-05-17], 10 PTT | ≤ 0,40 s |
| Sprechtaste → Sprachweg, Maximum | **2,0 s** | [MESS 2026-05-17] | ≤ 1,0 s |
| MS-Wiederholungsrate der Ruf-Anforderung | **11 %** (1/9) | [MESS 2026-05-17] | ≤ 5 % |
| Anmeldung: Vor-Antwort | 1 Frame nach Fragment 1 | [GOLD] Struktur, V1 gleiches Muster | 1 Frame, deterministisch |
| Anmeldung: Bestätigung | 2 Frames nach Fragment 2 | [GOLD] Struktur | ≤ 2 Frames |

**Die Streuung liegt nicht im Antwortpfad.** Die Diagnose von 2026-05-20 ist
eindeutig: der Sende-Aufbau ist mit 133–143 ms deterministisch, die
Schwankung des Nutzereindrucks korreliert ausschließlich mit der
**UL-Empfangsqualität** [MESS 2026-05-20]:

| Eindruck | Empfangene Beendigungs-Quittungen | Fehlerrate Sprachrahmen |
|---|---|---|
| „sofort" / „ok" | 2–5× | 3–5 % |
| „kleine Verzögerung" | 3× | ~5 % |
| „viel langsamer" | **0×** | **15–16 %** |

In den langsamen Läufen kamen zusätzlich deutlich weniger UL-Sprachbursts an
(~16–50 statt ~150+). **Konsequenz für V2:** Die Zeitziele der Tabelle sind nur
erreichbar, wenn die Empfangskette ihre Ziele aus Kapitel 03 erreicht. Ein
Zeitziel-Fehlschlag ist zuerst gegen die Fehlerrate der Sprachrahmen zu prüfen,
nicht gegen den Antwortpfad.

**Rechenlast-Kontext — schwächer, als er aussieht.** Der Wert **91,7 %
CPU-Leerlauf** wurde **nach** dem Abschalten der Desktop-, Druck- und
Update-Dienste gemessen (vorher 31 %), mit laufenden Tetra-Daemons (`sysinfo`,
`ul_mon`, `attach_daemon`), aber **ohne dokumentierten aktiven Sprachruf**
[MESS 2026-05-20, Vorher/Nachher-Tabelle der Dienst-Abschaltung]. Eine Messung
unter laufender Sprach-Transcodierung (Soft-Decodierung + Neucodierung je Burst
bei 16–18 Bursts/s) existiert in V1 **nicht**.

Die Folgerung, die Verlagerung der gesamten Kanalcodierung in die Software sei
nicht rechenzeit-, sondern nur determinismus-kritisch, ist damit
**[ANNAHME]** — begründet mit dem großen Abstand zwischen 8,3 % Restlast im
Leerlaufbetrieb und dem Antwortbudget von ≈ 56,7 ms je Stufe, aber nicht durch
eine Messung unter Ruflast gestützt. **V2 muss die Codierzeit je PDU unter
Ruflast messen** und in `13_SW_ARCHITECTURE.md` als Budget führen; bis dahin ist
die Annahme nicht als Beleg verwendbar (§6 Punkt 7).

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Sende-Anker-Slot | `tn = 2` (TS3 ETSI) | [MESS 2026-05-25] | Bei `tn = 0`: Differenz für TS3/TS4 schlägt um, Slot-Zuordnung zweideutig, Sprachwege vertauscht |
| Differenz TS1 (Kalibrier-Referenz) | 8,340 ms = 834 000 Takte | [CODE sw/tetra_ts_map.h:45], aus TS2…TS4 zurückgerechnet | **Kalibrierwert, kein Sollwert.** Ändert sich mit jeder Pipeline-Änderung; falsch gesetzt kippt das gesamte Mapping |
| Differenz TS2 / TS3 / TS4 | 22,499 / 36,669 / 50,836 ms | [MESS 2026-05-25]; TS2 unabhängig 22,497 ms [MESS 2026-05-30] | wie oben |
| Schrittweite | 14,167…14,170 ms | [MESS 2026-05-25] | **Abnahmekriterium.** Verletzung ⇒ Slot-Raster oder Ankerlage defekt |
| Stabilität der Differenz | ±14 µs (Sub-Symbol) | [MESS 2026-05-25] | > 1 Symboldauer ⇒ Sync-Anker instabil |
| Takte je Zeitschlitz | 1 416 700 (V1) | [CODE sw/tetra_ts_map.h:37] | Exakt 1 416 666,67. V1-Wert +23 ppm; über TS1…TS4 +1 µs, unkritisch. V2 zählt Symbol-Ticks statt Takte |
| Zuordnungstoleranz Differenz → Slot | ±0,5 Zeitschlitz = ±7,08 ms | [CODE sw/tetra_ts_map.h:78] | Enger: Fehlzuordnung bei Jitter. Weiter: Nachbarslot wird verschluckt |
| Frist Uplink-Zuweisung | 17,0 ms ab UL-Sync-Anker | [ANNAHME: Rechnung §3.3.1] | Überschreitung ⇒ MS wiederholt ⇒ Zuweisungs-Spirale [MESS 2026-07-11] |
| Haltedauer Mehrslot-Reservierung | = Kapazitätszuweisung, ab Zuweisungs-Frame | [MESS 2026-06-10] eigener 392-MHz-Referenz-Mitschnitt, FN09–FN11 bei 3 Slots — **nicht** in `docs/reference_decode/` nachprüfbar (§3.3.5); [MESS 2026-06-12] | Zu kurz: Fortsetzungskette bricht nach 1 Fragment ab. Zu lang: Zufallszugriff bleibt unnötig gesperrt |
| Antwort-Zeitraster | 1 Frame = 56,667 ms, ≤ 1 PDU/Frame/Slot | [CODE rtl/lmac/tetra_dl_signal_scheduler.v:18-24] | — |
| Vor-Antwort-Abstand | 1 Frame nach dem auslösenden UL-Burst | [GOLD] MN49 FN01→FN02, MN60 UL→FN01 | Später: MS-LLC-Wiederholung |
| Wiederholungsabstand Antwort | 2 Frames = 113,33 ms | [GOLD] FN02/04/06; [CODE sw/tetra_call_fsm.c:479, :750] | 1 Frame: MS verwirft zu schnelle Folge-PDUs [MESS 2026-05-17]. 0: Hard-Reject |
| Fenster Zwei-Burst-Zusammensetzung | V1-**Betriebswert 1 Frame** (`REG_REASSEMBLY_T0 = 1`); RTL-Fallback 2 Frames nur bei Registerwert 0; **V2 9 Frames** (§3.5.2) | V1 [CODE sw/tetra_hal.c:1807, rtl/rx/tetra_ul_demand_reassembly.v:67, :122-123]; V2-Wert `T.202 = 9` [ETSI Annex B.1], Untergrenze `N.203 ≥ 4` [ETSI Annex B.2] | Zu kurz: BS gibt vor dem MS auf, Fortsetzungen werden Waisen, MS wiederholt komplett. Länger **nur** mit der Ereignis-Regel aus §3.5.2, sonst falscher Antwortinhalt (LI = 12 statt 21) |
| Fenster Mehr-Fragment-Zusammensetzung | V1 4 Frames = 227 ms, je Fragment neu geladen; **V2 9 Frames = 510 ms** (§3.5.2) | [CODE …schf_reassembly.v:38, :254]; V2-Wert `T.202` [ETSI Annex B.1] | Zu lang: die einzige Kette blockiert alles |
| Sprach-Ruhe | 300 ms ≈ 5 Burst-Abstände (**normativ `12` R-12-11**) | siehe `12 §4` | siehe `12 §3.6.3`; hier nur die Bezugsgröße 56,7 ms (§3.6) |
| Ruf-Verfall | 5 s **vorläufig** (normativ `10`, offen als `10` O-10-8) | [CODE sw/tetra_call_fsm.h:48]; keine Messreihe, `17 §3.8` F8.4 | Kürzer: Neuzuteilung während PTT-Pause. Länger: Slot-Platz bleibt belegt |
| Klingeldauer Einzelruf | 20 s | [CODE sw/tetra_call_fsm.h:50] | Kürzer als Annahmezeit des Gerufenen ⇒ Ruf bricht ab |
| Abfrageintervall SW-Schleife | 10 ms | [CODE sw/tetra_attach_daemon.c:86] | Erscheint als Quantisierungsfehler in jedem ms-basierten Abstand (113 → 122 ms) |
| UL-Sprachburst-Abstand | 56,7 ms auf der Luft (Lücke 113,3 ms über F18); 16,67/s = 60 ms Mittelabstand (F18 = Kontroll-Frame) | [GOLD] UL #23…#30 (56/57 ms); [ETSI §9.3.4] | Mehr als 18/s im Zähler ⇒ Fehlkorrelation im Sync (03 §4) |

---

## 5. Verifikation

### 5.1 Simulation (Pflicht, selbstprüfend)

| Testbench | Prüft | Kriterium |
|---|---|---|
| `tb_tdma_timebase_grid` | Slot-, Frame-, Multiframe-, Hyperframe-Wrap über > 1 Hyperframe | Slot-Länge exakt 255 `sym_en`; Frame 4 Slots; Multiframe 18 Frames; Hyperframe 60 Multiframes; kein Zähler überspringt einen Wert |
| `tb_airlock_grid` | Stoppuhr mit synthetischem Anker und synthetischem UL-Sync auf allen 4 Slots | Differenzen wachsen um exakt eine Slot-Dauer (255 Symbol-Ticks); alle vier Werte in `[0, 1 Frame)`; `EVT_CNT` = Anzahl Stimuli |
| `tb_airlock_anchor_negative` | `REG_AIRLOCK_CFG.anchor_ts` künstlich auf 1 (= `tn = 0`) | Der Test **muss** das Umschlagen reproduzieren: TS3/TS4 liefern die um einen Frame verkleinerten Werte, die Schrittfolge ist nicht mehr monoton. Sichert R-08-06 gegen stille Rückverschiebung |
| `tb_airlock_atomic` (in 07 geführt) | UL-Sync und Anker im selben und in benachbarten Takten | Differenz immer gegen den **letzten vorausgegangenen** Anker; kein Fenster, in dem ein SW-Leser zwei inkonsistente Stempel sehen könnte |
| `tb_grant_deadline` | Zuweisungs-Erzeuger, Auslöser auf dem spätesten Unterschlitz | Bits liegen vor dem `slot_pulse` des Ziel-Slots; `grant_late_cnt` = 0 |
| `tb_resv_hold` | Haltedauer bei Kapazitätszuweisung 1…15 | Reserviertes Zugriffsmuster in genau `N` Frames ab dem Zuweisungs-Frame, danach sofort wieder Zufallszugriff |
| `tb_reass_window` | Fenster-Ablauf, Neuladen je Fragment, gleiche Adresse erneut, Puffer voll | Verwurfszähler je Grund getrennt; Ersetzen bei gleicher Adresse erzeugt **keinen** Verwurf |
| `tb_frame_arith` | `elapsed()` über den Hyperframe-Umschlag | `elapsed(1079, 2) = 3`; kein negativer Wert |
| `tb_slot_deadline_stress` | Alle Inhaltsquellen wechseln im Takt der Slot-Grenze | `TX_UNDERRUN_CNT` = 0 über 10 000 Slots |

### 5.2 Gold-Vergleich (strukturell)

Geprüft wird die **Frame-Struktur**, nicht der Absolutwert (§3.8.1):

| Prüfung | Kriterium | Quelle |
|---|---|---|
| Vor-Antwort-Abstand | genau 1 Frame nach dem auslösenden UL-Burst | [GOLD] §3.4.2 |
| Art der Vor-Antwort | fragmentierte Anforderung ⇒ Zuweisungselement `0x00`, MAC-RESOURCE **ohne TM-SDU** (`09 §3.1.1`); Einzelburst ⇒ LLC BL-ACK ohne Zuweisung | [GOLD] §3.4.2 |
| Wiederholungsabstand | 2 Frames | [GOLD] FN02/04/06 |
| Kein Doppelbelegen | höchstens eine adressierte PDU je Kontrollkanal-Slot und Frame; im Anmeldeablauf trägt der Zwischen-Frame einen Füller (`addr=NULL`, LI = 2) — **nur** für MN49 FN03 belegt, nicht für MN60 (§3.4.2) | [GOLD] MN49 FN03, idx 779 |
| Zuweisungsrate | ≈ 17,4/s Zugriffszuweisungen, entspricht 1 Kontrollkanal-Slot je Frame | [GOLD] DIFF-Tabelle |

Die Reservierungs-Haltedauer (§3.3.5) ist **nicht** Teil des Gold-Vergleichs: das
reservierte AACH-Muster `0x0000` kommt in `docs/reference_decode/` nicht vor
(§3.3.5). Sie wird ausschließlich über den eigenen Mitschnitt in §5.3 C
abgenommen.

### 5.3 Luft-Abnahme

**A — Zeitkopplung (Pflicht nach jedem Bitstream, R-08-09).** Vier
kontrollierte Einzel-Zuweisungen TS1…TS4, je ≥ 20 UL-Bursts, Ruf-Verfall
temporär auf 5 s. Kriterien:

1. Schrittweite TS(n) → TS(n+1) = 85/6 ms ± 1 Symboldauer. **Blocker bei
   Verletzung.**
2. Alle vier Differenzen in `[0, 1 Frame)` und monoton steigend.
3. Streuung je Slot ≤ 1 Symboldauer.
4. `UL_TS_MAP_WRAP_CNT` = 0, `UL_TS_MISMATCH_CNT` = 0.
5. Absolutwerte werden protokolliert und gegen die Latenz-Bilanz (§3.2.5)
   aufgeschlüsselt; Restposten ≤ 100 µs (R-08-08). Absolutwerte sind **kein**
   Bestehens-Kriterium.

> **Vorrangregel.** Für die Abnahme der Zeitkopplung gilt dieses Kapitel. Ein
> Abnahmekriterium, das die V1-Absolutwerte fordert (siehe §6 Punkt 9),
> widerspricht R-08-08 und ist nicht anwendbar: es würde eine korrekte V2-Kette
> mit anderer Pipeline-Latenz durchfallen lassen und eine V2-Kette mit
> zufällig passender Latenz und falscher Schrittweite bestehen lassen.

**B — Zuweisungs-Frist.** ≥ 3 Anmeldungen je Endgerät. Kriterien:
`grant_late_cnt` = 0; keine wiederholte Anmeldung derselben Adresse innerhalb
von 5 s; `grant_emit_cnt`-Rate ≤ 1 pro erkanntem UL-Sync; Warteschlangen-Verwurf
`SIG_QUEUE_DROP_CNT` = 0.

**C — Mehrslot-Reservierung.** Eine lange Uplink-Kurznachricht, ≥ 3 Versuche.
Kriterium: die vollständige Fragmentkette kommt an, `reass_t0_cnt` = 0,
und der externe Mitschnitt zeigt die Zugriffszuweisung für die volle Haltedauer
als reserviert.

**D — Ende-zu-Ende-Zeitziele.** ≥ 3 Wiederholungen je Ablauf; Zielwerte aus
§3.8.3. Bei Fehlschlag zuerst die Fehlerrate der Sprachrahmen prüfen (§3.8.3),
erst dann den Antwortpfad.

**E — Nachlauf.** Kein Test darf mit verkürztem Ruf-Verfallszeitgeber
abgeschlossen werden; der Betriebswert wird vor der Abnahme zurückgestellt und
ein Ablauf wiederholt.

---

## 6. Offene Punkte

1. **O-08-1 — Absolute Ankerlage: 11 Symbole unerklärt.** Der V1-Modulkopf der
   NUB-Erfassung nennt den Sync-Anker als **Burst-Symbol 132**
   („`sync_found_sys` on NTS1[10] (= burst symbol 132)")
   [CODE rtl/rx/tetra_ul_nub_capture.v:6-8]. Aus der ETSI-Burst-Geometrie folgt
   dagegen **Burst-Symbol 121** (NTS1 = BN 221–242 = Symbole 111–121)
   [03 §3.6.1; ETSI Tabelle 9.5], mit der Burst-Verzögerung `d = 17`
   [ETSI Tabelle 9.2] also 138 Symboldauern nach Slot-Start [ETSI §9.4.3.4].
   Beide Größen sind burstbezogen; die Differenz beträgt **11 Symbole
   = 0,611 ms** (slotbezogen gerechnet: 138 gegen 132 Symboldauern nach
   Slot-Start ⇒ 6 Symbole = 0,333 ms — auch dieser Wert entspricht nicht der
   Bilanz). Für die Invarianten (§3.2.1–3.2.3) ist das irrelevant, für R-08-08
   nicht: der unerklärte Restposten der Bilanz in §3.2.5 beträgt nur ~161 µs,
   also weniger als ein Drittel dieser Differenz. Solange nicht geklärt ist,
   welche der beiden Ankerlagen die Stoppuhr tatsächlich stoppt, ist die
   Latenz-Bilanz nicht nur verschoben, sondern **unschlüssig**: mit
   Burst-Symbol 132 läge der Anker bei `132 + 17 = 149` Symboldauern
   = 8,278 ms, `L_pipe` wäre nur noch 8,340 − 8,278 = **62 µs** und damit
   **kleiner als die bereits aufgeschlüsselten ~512 µs** — die Bilanz aus
   §3.2.5 ginge nicht auf.
   **Empfehlung:** In V2 mit der ETSI-Geometrie rechnen, die Kommentarangabe
   streichen und die Ankerlage bei der ersten V2-Messung gegen die Bilanz
   verifizieren, bevor R-08-08 als erfüllt gilt.
2. **O-08-2 — `clk_sys`-Genauigkeit nie vermessen.** Die Stoppuhr zählt `clk_sys`-Takte
   für ein Intervall, das durch `clk_lvds` definiert ist; beide Takte haben
   verschiedene Quellen [01 R-01-02]. Der resultierende Skalenfehler
   (±2,5 µs bei ±50 ppm auf 50 ms, [ANNAHME: Rechnung]) ist die vermutete
   Untergrenze der beobachteten Streuung. **Empfehlung:** Die Grob-Differenz aus
   Symbol-Ticks statt aus Takten bilden (§3.2.5) — dann entfällt die Abhängigkeit
   ganz, und der Punkt ist keine offene Frage mehr, sondern eine Entwurfsregel.
3. **O-08-3 — Restposten der Latenz-Bilanz.** ~161 µs von 673 µs sind in V1 nicht
   aufgeschlüsselt (§3.2.5) — vermutet werden die internen Filterketten des
   Transceivers. **Empfehlung:** Bei der V2-Bring-up-Messung die
   Transceiver-Filterkonfiguration variieren und die Verschiebung der Differenz
   protokollieren; das trennt Transceiver-Anteil und eigene Kette und macht
   R-08-08 erfüllbar.
4. **O-08-4 — Kein Zähler für versäumte Zuweisungs-Fristen in V1.** V1 hat keinen
   Mechanismus, der eine zu spät bereitgestellte Zuweisung sichtbar macht — die
   Zuweisungs-Spirale wurde erst an ihren Folgen erkannt [MESS 2026-07-11].
   `grant_late_cnt` (§3.3.4) ist neu; er steht in der abschließenden Zählerliste
   `06 §3.13` und ist in `07 §3.1.8` als `REG_GRANT_LATE_CNT` verankert. **Empfehlung:** Der
   Zähler ist Voraussetzung für die Abnahme von R-08-03; ohne ihn ist die
   Anforderung nicht prüfbar.
5. **O-08-5 — Wieviel Zuweisung ist zu großzügig?** R-00-02 verlangt eine
   inhaltsunabhängige Zuweisung; damit wird auch für Bursts zugewiesen, die kein
   Folgefragment brauchen. Der Kapazitätsverlust ist zu **messen**, nicht zu
   schätzen (`00` O-00-1). Dieses Kapitel liefert dazu die Zählgrößen
   (`grant_emit_cnt` gegen tatsächlich genutzte reservierte Slots); der
   Mechanismus selbst gehört in `06_MAC.md`. **Empfehlung:** Messreihe mit
   1 / 2 / 4 Unterschlitzen Zuweisungsbreite und dem
   Sprach-Zeitschlitz-Durchsatz als Zielgröße.
6. **O-08-6 — Zwei-Burst-Fenster wird von 1 auf den Wert aus §3.5.2 verlängert.** Der
   V2-Wert ist 9 Frames aus `T.202` [ETSI Annex B.1]; `N.203 ≥ 4` [ETSI Annex B.2] ist
   dabei nur die eingehaltene **Untergrenze**, nicht die Begründung. V1 lief air-verifiziert mit
   **1 Frame** (`REG_REASSEMBLY_T0 = 1` [CODE sw/tetra_hal.c:1807]); die 2 Frames
   im RTL sind nur der Fallback für Registerwert 0
   [CODE rtl/rx/tetra_ul_demand_reassembly.v:67, :122-123]. Der Sprung ist damit
   1 → 9, nicht 2 → 9. Der Grund für V1s 1 Frame war **keine** Puffer-Enge,
   sondern die Reihenfolge-Kopplung zur Antwort-Zustandsmaschine
   [CODE sw/tetra_hal.c:1796-1808]: mit längerem Fenster war die Zusammensetzung
   beim Baubeginn der Bestätigung noch nicht fertig, und die Bestätigung fiel auf
   den Profil-Standardpfad zurück (LI = 12 statt 21). Mit 9 Frames greift dieser
   Fehlpfad **stärker**, solange die Antwort auf einen festen Frame-Abstand
   wartet. **Empfehlung:** Zuerst die Ereignis-Regel aus §3.5.2 umsetzen
   („Kette vollständig ODER Fenster abgelaufen", kein fester Warteschritt,
   `reass_incomplete_at_reply_cnt` = 0); erst dann mit 9 Frames und ≥ 4 Plätzen
   bauen und `reass_evict_cnt` im Betrieb beobachten. Spricht dieser Zähler an,
   ist über die Plätze zu diskutieren, nicht über das Fenster.
7. **O-08-7 — Codierzeit je PDU in Software nicht vermessen.** Mit der vollständigen
   Kanalcodierung in Software (00 §3.3) wird sie Teil des Antwortbudgets von
   ≈ 56,7 ms je Stufe (§3.4.3 R-5). Die vorhandene Evidenz ist indirekt **und
   schwächer als bisher angenommen**: die 91,7 % CPU-Leerlauf sind der
   Nachher-Wert der Dienst-Abschaltung mit laufenden Tetra-Daemons, **ohne**
   dokumentierten aktiven Sprachruf [MESS 2026-05-20, §3.8.3]. Es gibt in V1
   keine Leerlaufmessung unter Ruflast.
   **Empfehlung:** In `13_SW_ARCHITECTURE.md` ein Budget je PDU-Klasse führen und
   beim Bring-up messen; der Grenzfall ist nicht der Mittelwert, sondern das
   99.-Perzentil unter Last.
8. **O-08-8 — Abfrage-getriebene Software.** Das 10-ms-Abfrageintervall erscheint als
   Quantisierungsfehler in jedem ereigniszeit-basierten Abstand (113 → 122 ms,
   §3.4.3). Alle Luft-Abstände werden in V2 in Frames aus Zeitstempeln
   gerechnet, wodurch der Fehler entfällt. Offen bleibt, ob die Hauptschleife
   überhaupt abfragebasiert bleibt oder auf eine Unterbrechung je
   UL-Mailbox-Ereignis umgestellt wird. **Empfehlung:** Unterbrechung — sie
   entfernt bis zu 10 ms aus dem Antwortpfad und ist die einzige Änderung, die
   das Software-Budget messbar entlastet, ohne den Schnitt zu berühren.
   Entscheidung in `07_PS_PL_CONTRACT.md` (Unterbrechungs-Quellen) und
   `13_SW_ARCHITECTURE.md`.
9. **O-08-9 — Widerspruch im Abnahmekriterium der Zeitkopplung.**
   `07_PS_PL_CONTRACT.md` führt in seiner Luft-Abnahme das Kriterium
   „`REG_AIRLOCK_DELTA_CYC` reproduziert `834 000 + (TS_UL − 1) × 1 416 700`
   Zyklen". Das macht die **V1-Absolutwerte** zur Vorgabe und widerspricht
   R-08-08 in zwei Richtungen: es lässt eine korrekte V2-Kette mit anderer
   Pipeline-Latenz durchfallen, und es lässt eine V2-Kette mit zufällig
   passendem Absolutwert bei falscher Schrittweite bestehen. Zusätzlich enthält
   der genannte Ausdruck die um 33 Takte zu große Slot-Konstante (§4).
   **Empfehlung:** In 07 durch „Schrittweite = eine Slot-Dauer ± 1 Symboldauer,
   Absolutwert gegen die Latenz-Bilanz aus `08_TIMING §3.2.5`" ersetzen. Bis
   dahin gilt die Vorrangregel in §5.3 A.
10. **O-08-10 — Ruhe-Zeitgeber auf Frames umstellen — noch nicht gegengemessen.** §3.6
    empfiehlt „5 aufeinanderfolgende Frames ohne UL-Burst" statt 300 ms
    Ereigniszeit. Der Wert 300 ms ist air-verifiziert, die Frame-Fassung nicht.
    **Empfehlung:** Beide Fassungen im gleichen Air-Test gegeneinander messen
    (Aussetzer im Ruf, Nachlauf nach dem Loslassen der Sprechtaste); die
    Ereigniszeit-Fassung bleibt bis dahin die Referenz. Ein „gleichwertig"-Urteil
    ohne Messung wäre genau die Art Optimierung, die P5 verbietet.
