# 12 — Sprachkanal, Codec und Sprachweiterleitung

**Scope:** Der Sprachpfad vollständig: Rahmenstruktur des Sprachkanals TCH/S, der Sprachcodec
in Sende- und Empfangsrichtung samt Bitzuordnung, Klassen und Schnittstelle — einschließlich
der begründeten Entscheidung, in der Basisstation **keinen** Analyse-/Synthese-Codec zu
betreiben (§3.2.4) —, die Weiterleitungskette vom Empfang eines sprechenden Endgeräts zur
Aussendung an die zuhörenden Endgeräte, Erkennung und Behandlung fehlerhafter Sprachrahmen,
Stehlen von Halbschlitzen im laufenden Ruf, Sprechpausen-Erkennung je Zeitschlitz, Rechenlast
auf dem ARM-Kern.

**Nicht hier:**
Kanalcodierung des Sprachkanals (CRC, Faltungscode, Punktierung, Interleaver, Scrambler,
Viterbi) → `05_CHANNEL_CODING.md` §3.8.6.
Erfassung und Soft-Demodulation des Uplink-Sprachbursts → `03_PHY_UL_RX.md` §3.6.
Sende-Slot-Zeitplan und Burst-Aufbau → `04_PHY_TX_TDMA.md`.
Rufsteuerung, Floor-Verwaltung, Kanalzuweisung → `10_CMCE_CALL.md`.
Register-Adressen und Mailbox-Formate → `07_PS_PL_CONTRACT.md`.
Stehl-Signalisierung auf MAC-Ebene → `06_MAC.md` §3.3.

**Abhängigkeiten:** `00_OVERVIEW.md` (§3 Architektur-Schnitt, P1–P7), `03_PHY_UL_RX.md`
(§3.2 Vorzeichenkonvention, §3.6 NUB-Erfassung), `05_CHANNEL_CODING.md` (§3.8.6 TCH/S-Kette,
§3.10 Rechenlast), `08_TIMING.md` (R-08-10 Zeitstempelpflicht).

---

## 1. Anforderungen

| ID | Anforderung |
|---|---|
| **R-12-01** | Die Weiterleitungskette ist **genau ein** Pfad: Hardware liefert Soft-Bits, Software decodiert vollständig, verarbeitet, codiert vollständig neu, Hardware sendet fertige Bits. Es existiert kein zweiter Weg (kein Bit-Durchreichen ohne Decodierung, kein RTL-Sprachcodierer, kein Sonderpfad für Einzelrufe). |
| **R-12-02** | Die Basisstation führt **keine** ACELP-Quellcodierung und **keine** ACELP-Synthese aus. Sie transportiert die 274 Sprachparameter-Bits eines 60-ms-Rahmens unverändert von der Empfangs- zur Senderichtung („transcoder-free"). Ein Sprach-Analyse-/Synthese-Codec ist in Stufe 1 nicht Teil des Systems (§3.2.4). |
| **R-12-03** | Die TCH/S-Kanalcodierung existiert im gesamten System **genau einmal**, in C, und wird für Empfangs- und Senderichtung von derselben Modulschnittstelle bedient (= R-05-01). Kein zweites Codec-Modul, keine nicht aufgerufenen Stümpfe, kein mitgelinkter zweiter Baum. |
| **R-12-04** | Die Vorzeichen-Anpassung zwischen PHY-Konvention K1 (`soft > 0 ⇔ Bit '0'`, `03` §3.2.2) und der Viterbi-Konvention des Sprachdecoders K3 (`soft > 0 ⇔ Bit '1'`) findet an **genau einer** Stelle statt: in der Abholfunktion dieses Kapitels (§3.4.2). Kein RTL-Modul und kein anderer Decoder invertiert (= R-05-09). |
| **R-12-05** | Der Zielzeitschlitz eines weitergeleiteten Sprachrahmens wird **ausschließlich** aus dem TDMA-Zeitstempel gebildet, den der Burst laut R-00-04 / R-08-10 mitbringt. Kein Stoppuhr-Register, keine separat gelesene Zeitquelle, keine Reihenfolgeabhängigkeit zweier Registerlesevorgänge (§3.4.4). |
| **R-12-06** | Die Weiterleitung ist **adress-transparent**. Der Sprachrahmen enthält keine Adresse und bekommt keine (Begründung und ETSI-Beleg in §3.4.7). Die Sender-Identität wird ausschließlich über die Rufsteuerung (`10`) und den Verkehrs-Nutzungsmarker im Zugriffszuweisungskanal übertragen. |
| **R-12-07** | Ein Sprachrahmen mit verletztem Klasse-2-Prüffeld (Bad Frame) wird **nicht als gültiger Rahmen weitergegeben**. Die Fehlermarkierung wird zum Endgerät propagiert, statt sie durch Neucodierung zu tilgen (§3.5.4). |
| **R-12-08** | Die Bad-Frame-Rate über einen 10-s-PTT-Lauf ist **≤ 5 %** im Nahfeld und **≤ 10 %** auf 50 m Entfernung. In jedem Lauf gilt zusätzlich `BFI_soft ≤ BFI_hard`; eine Verletzung dieser Ungleichung ist ein Regressionsbefund im Soft-Pfad (§3.5.3, §5.4). |
| **R-12-09** | Jede Bewertung einer Sprachpfad-Änderung erfolgt als A/B im **selben** Capture bzw. derselben Messsitzung. Ein Vergleich gegen einen Wert aus einer früheren Sitzung ist unzulässig — die Tagesvariabilität des Roh-BER beträgt 1,4–3,5 % (`03` §4). |
| **R-12-10** | Die Sprechpausen-Erkennung arbeitet **je Zeitschlitz getrennt**. Das Verstummen eines Sprechers auf einem Zeitschlitz darf den Sprachweg der anderen Zeitschlitze nicht beeinflussen (§3.6). |
| **R-12-11** | Der Sprechpausen-Zeitgeber beträgt **300 ms** und ist in diesem Kapitel normativ definiert (§3.6, §4). Kapitel `10` verweist auf R-12-11 und wiederholt den Wert nicht. Eine Änderung setzt eine neue Messreihe nach dem Verfahren aus §5.4 voraus. |
| **R-12-12** | Eine nicht abgeholte Sprachburst-Ablage darf vom nächsten Burst **nicht stillschweigend überschrieben** werden. Es greift Doppelpufferung; sind beide Bänke ungelesen, wird der **neue** Burst verworfen — der ungelesene bleibt gültig — und der Verlust erhöht einen im Betrieb lesbaren Zähler (`mb_overrun_cnt`, definiert in `03` §3.6.3/§3.6.7, Registerlage `07` §3.1.8 `REG_MB_UL_DROP_CNT[31:16]`). |
| **R-12-13** | Der Lesevorgang eines Sprachbursts aus der Mailbox ist gegen einen gleichzeitig eintreffenden nächsten Burst geschützt: die Fensterbindung hält bis zum Quittieren (`07` §3.4). Ein zerrissener Lesevorgang (Mischung zweier Bursts) ist ein Fehlerzustand, kein toleriertes Ereignis, und wird über die Folgenummer der Mailbox erkannt und gezählt (§3.4.2, §3.8, §3.10). |
| **R-12-14** | Der Sende-Zeitschlitzinhalt eines Sprachkanals wird nur in den TDMA-Frames 1…17 (ETSI-Zählung, 1-basiert; im RTL `fn_sys` 0…16 — Nummerierungsregel in §3.1.1) aus der Sprachablage gespeist. Frame 18 bleibt dem Broadcast-Anker vorbehalten [ETSI §9.5.4] (§3.4.6). |
| **R-12-15** | Die Beobachtbarkeit des Sprachpfads umfasst mindestens: erfasste UL-Sprachbursts, abgeholte Bursts, Bad-Frames, verworfene Bursts wegen Überlauf, tatsächlich **ausgesendete** DL-Sprachbursts je Zeitschlitz. Kein Zähler dieser Liste darf konstant verdrahtet sein (P6, §3.10). |
| **R-12-16** | Die Sprachverarbeitung eines 60-ms-Rahmens hält ihr Zeitbudget: Abholung + Decodierung + Neucodierung + Ablage **< 14,167 ms** je Burst und **< 60 ms** je Sprachrahmen, bei bis zu drei gleichzeitig aktiven Sprachkanälen. Nachweis auf dem Zielprozessor, nicht geschätzt (§3.9, §6 O-12-3). |
| **R-12-17** | Im Sprachpfad wird zur Laufzeit **kein Heap** benutzt. Alle Puffer sind statisch oder auf dem Stack; die Viterbi-Trellis-Ablage ist eine feste Struktur (§3.9). |
| **R-12-18** | Halbschlitz-Stehlen auf einem laufenden Sprachkanal ist in Stufe 1 **nur in Senderichtung** vorgesehen und dann mit der Halbschlitz-Sprachcodierung nach [ETSI §8.3.1.3.7] zu bedienen. Ohne diese Codierung darf kein Sprachschlitz gestohlen werden (§3.7). |

---

## 2. Architektur / Aufbau

### 2.1 Warum diese Kette das Vorbild ist

Der Sprachpfad ist die einzige Kette in V1, die den Architektur-Schnitt aus `00` §3
vollständig einhält: die Hardware erfasst und demoduliert, gibt **rohe Soft-Bits** heraus und
nimmt **fertige Bits** zurück; alles zwischen diesen zwei Punkten liegt in Software. Es gibt
keine geteilte Codierung, keinen bit-genauen C↔Verilog-Vertrag innerhalb einer
Codierungsstufe, keinen zweiten Pfad für Sonderfälle.

Konkret erfüllt der Pfad P1 („wer den Body baut, codiert ihn"): dieselbe Software, die den
Sprachrahmen entgegennimmt, führt die vollständige Kanalcodierung durch und übergibt die
432 sendefertigen Bits. Genau das ist das Muster, das `05` für **alle** Kanäle vorschreibt.

### 2.2 Datenfluss und Größen an jeder Grenze

```
   Luft (Uplink)                                                    Luft (Downlink)
        │                                                                  ▲
        ▼                                                                  │
 ┌──────────────────┐                                            ┌───────────────────┐
 │ PL: UL-RX-PHY    │  Kap. 03                                   │ PL: TX-Kette      │ Kap. 04
 │ Sync NTS1 →      │                                            │ Burst-Builder     │
 │ NUB-Erfassung →  │                                            │ + Slot-Zeitplan   │
 │ Soft-Demod       │                                            └───────────────────┘
 └──────────────────┘                                                      ▲
        │ G1                                                               │ G4
        ▼                                                                  │
 ┌──────────────────┐                                            ┌───────────────────┐
 │ PL: UL-Burst-    │                                            │ PL: DL-PDU-       │
 │ Mailbox (07 §3.4)│                                            │ Mailbox (07 §3.3) │
 │ 432 Soft, 8 bit  │                                            │ 4 Halteplätze     │
 └──────────────────┘                                            └───────────────────┘
        │ G2                                                               ▲ G3
        ▼                                                                  │
 ┌───────────────────────────────────────────────────────────────────────────────────┐
 │ PS (dieses Kapitel):                                                              │
 │  Abholen (§3.4.2) → K1→K3-Anpassung → TCH/S-Decodierung (05 §3.8.6) → BFI         │
 │  → Zielschlitz aus Zeitstempel (§3.4.4) → TCH/S-Neucodierung → Ablage (§3.4.6)    │
 └───────────────────────────────────────────────────────────────────────────────────┘
```

**Format und Größe an jeder Grenze — normativ:**

| Grenze | Richtung | Format | Größe | Konvention |
|---|---|---|---|---|
| **G1** PHY → Mailbox | PL intern | 432 Soft-Werte, 8 bit signed | 3 456 bit | K1 (`soft>0 ⇔ '0'`), Index = On-Air-Type-5-Index, aufsteigend, keine Umkehr [`03` §3.6.4] |
| **G2** Mailbox → PS | PL → PS | 108 Wörter × 32 bit, je 4 Softs à 8 bit; Wort `w`, Soft `n`: `rdata[8n +: 8] = soft[4w+n]` | 432 B | Soft-**Werte** aufsteigend ab LSB des Worts, aufsteigender On-Air-Index; dazu Zeitstempel `(tn, fn, mn)` im selben Transfer (R-00-04). **Bewusste Abweichung von R-05-14, dort als abschließende Ausnahme aufgeführt:** dieses Wort trägt keine Bits, sondern 8-bit-Zahlen, deren Byteplätze nicht „zuerst gesendet = MSB" folgen können. Identisch festgelegt in `07` §3.2/§3.4 (`DATA[8·n +: 8] = soft[4·d + n]`) und `03` §3.6.4. R-05-14 gilt unverändert für alle Bit-Ports, insbesondere G3/G4 (§3.4.6). |
| **PS intern** | — | `int8_t softs[432]` K3, dann `uint8_t acelp[274]` | 432 B / 274 B | K3 nach §3.4.2; ACELP-Bits in Codec-Ordnung (2 × 137) |
| **G3** PS → Mailbox | PS → PL | DL-PDU-Mailbox `07 §3.3`, 16 Wörter × 32 bit: `W0`…`W13` = 432 type-5-Bits, `W14` = `target_ts` + `mode = PERSIST_SET`, `W15` = `coded_len = 432` / `pdu_class = 00₂` (SCH/F) | 64 B | Bit-Abbildung **normativ in `07` §3.3**; Zeitschlitz-Wahl über `W14.target_ts`, Halten über `mode = PERSIST_SET`, Übernahme über `REG_DLMB_GO`. Es gibt keine eigene Sprach-Mailbox (P3, `00 §3.6`) |
| **G4** Mailbox → TX | PL intern | 2 × 216 bit (BKN1, BKN2) je Halteplatz | 432 bit/Halteplatz | `bkn1 = b5(1…216)`, `bkn2 = b5(217…432)` [ETSI §8.3.1.3.6 Gl. 8.58/8.59] |

**Die Kette ist an keiner Stelle inhaltsabhängig.** Weder die Erfassung noch die Ablage
prüfen, ob es sich um Sprache oder Signalisierung handelt. Das ist Absicht und trägt zwei
Eigenschaften: der Sprachpfad braucht keine Zeitschlitz-Tabelle in der Hardware, und derselbe
Erfassungspfad kann parallel den Signalisierungs-Decoder für lange Uplink-Kurznachrichten
speisen (`03` §3.7, „Selbstfilterung"). Diese Eigenschaft wird beibehalten.

### 2.3 Änderungen gegenüber V1 mit Begründung

| V1 | V2 | Grund |
|---|---|---|
| Zielschlitz aus `REG_TS1_STOPWATCH_DELTA`, das **vor** dem Burst-Read gelesen werden muss, damit es „atomar zur Burst-Erkennung passt" [CODE sw/tetra_voice_pipe.c:93-96] | Zielschlitz aus `tn` des Burst-Zeitstempels | Reihenfolgeabhängigkeit zweier Registerlesevorgänge ist eine Race-Konstruktion. R-08-10 stellt den Zeitstempel ohnehin bereit. |
| Zwei Codec-Implementierungen gelinkt, eine tot (`tetra_etsi_tch_s.{c,h}` + `sw/etsi_codec/`, 4 383 Zeilen, kein Aufrufer) | Eine Implementierung; die Referenzquellen wandern in das Verifikations-Werkzeug | R-12-03, P2. Entscheidung mit Messung in §3.3. |
| Zwei widersprüchliche Klassen-Umsortierungen im Repo, die tote ist falsch (§3.2.3) | Eine, die verifizierte | R-12-03; löst `05` O-05-4 |
| A/B-Diagnose (Hard-Decode **zusätzlich** zum Soft-Decode) läuft in jedem Burst mit [CODE sw/tetra_voice_pipe.c:170] | Zweiter Decodierlauf nur bei gesetztem Diagnose-Schalter | Verdoppelt die Decodierlast im Dauerbetrieb ohne Betriebsnutzen |
| `calloc`/`free` je Viterbi-Aufruf [CODE sw/tetra_bs_tch_s.c:269,313] | statische Trellis-Ablage | R-12-17; 17 Heap-Paare/s je Sprachkanal ohne Notwendigkeit |
| Bad Frame wird neu codiert und als gültiger Rahmen ausgesendet [CODE sw/tetra_voice_pipe.c:174-192,304-306] | Fehlermarkierung wird propagiert | R-12-07, §3.5.4 |
| `REG_VOICE_RELAY_CNT` konstant 0 verdrahtet [CODE rtl/tetra_zynq_top.v:268-269] | echter Aussendezähler je Zeitschlitz | R-12-15, P6 |
| Fünf Codestellen dokumentieren eine Adress-Ersetzung, die es nicht gibt (§3.4.7) | R-12-06 schreibt Adress-Transparenz fest | P2; eine Beschreibung, die an fünf Stellen steht und an keiner zutrifft, kostet jeden Leser dieselbe Stunde |

---

## 3. Detail-Spezifikation

### 3.1 Rahmenstruktur des Sprachkanals

#### 3.1.1 Kanal und Burst

TCH/S ist der Vollschlitz-Sprachkanal. Er wird auf **Block 1 und Block 2 der Frames 1 bis 17**
eines Verkehrskanals abgebildet [ETSI §9.5.4]; Frame 18 trägt keinen Verkehr. Der Uplink
benutzt den Normal Uplink Burst, der Downlink den Normal (Discontinuous) Downlink Burst; die
Trainingsfolge **NTS1** kennzeichnet den Burst als Träger *eines* Vollschlitz-Kanals
[ETSI §9.4.4.3.2 Tab. 9.13].

> **Frame-Nummerierung, verbindlich für dieses Kapitel** (analog zur Zeitschlitz-Regel in
> `CONVENTIONS.md` §4): Spec-Text, Logs und Software zählen Frames **1-basiert** (ETSI-Frame
> 1…18); RTL-Signale und das Mailbox-Feld `fn` zählen **0-basiert** (`fn_sys`/`fn_ul` = 0…17,
> `07` §3.4 `W1[6:2]`). ETSI-Frame *n* = `fn_sys` *n−1*. Jede Umrechnung wird an ihrer Stelle
> benannt; Verkehrsframes sind damit ETSI 1…17 = `fn_sys` 0…16 (§3.4.6, R-12-14).

Die 432 type-4-Bits werden gescrambelt und auf die zwei Blöcke verteilt
[ETSI §8.3.1.3.6 Gl. 8.58/8.59]:

```
bkn1(k) = b5(k)         für k = 1 … 216
bkn2(k) = b5(k + 216)   für k = 1 … 216
```

Damit ist die Blockaufteilung des Sprachkanals **identisch** zu SCH/F. Der Unterschied liegt
ausschließlich in der Kanalcodierung oberhalb von type-4 (`05` §3.8.6).

#### 3.1.2 Rahmenhierarchie und Bitraten — geschlossene Rechnung

| Größe | Wert | Herkunft |
|---|---:|---|
| Sprachrahmen (ACELP) | 137 bit / 30 ms | [CODE sw/etsi_codec/const.tab:35], [CODE sw/tetra_tch_s_codec.h:42] |
| Sprachrahmen je Burst | 2 → 274 bit | [CODE sw/etsi_codec/const.tab:36] |
| Codierter Burst (type-3/4/5) | 432 bit | [CODE sw/etsi_codec/const.tab:37] |
| Verkehrsschlitze je Multiframe | 17 (Frames 1…17) | [ETSI §9.5.4] |
| Multiframe-Dauer | 1,02 s | [ETSI §4.5.2] |

Aus diesen fünf Zahlen folgt die Bitratenbilanz **exakt**, ohne Rundung
[ANNAHME: Rechnung aus den belegten Einzelwerten]:

```
Nutzrate  : 17 Bursts × 274 bit = 4 658 bit je Multiframe = 34 × 137 bit
            4 658 bit / 1,02 s  = 4 566,7 bit/s   (= die 4 567 bit/s des Sprachcodecs)
Bruttorate: 17 Bursts × 432 bit = 7 344 bit je Multiframe
            7 344 bit / 1,02 s  = 7 200,0 bit/s   (= die 7,2 kbit/s des Kanals)
```

**Das ist die Erklärung für Frame 18.** Zwei Sprachrahmen dauern 60 ms, ein TDMA-Frame nur
170/3 ms ≈ 56,67 ms. Die Differenz von 3,33 ms je Frame summiert sich über 17 Frames auf
56,67 ms — genau einen Frame. Der Kontroll-Frame 18 ist damit kein Zusatz, sondern der
Ausgleichsposten, der die 30-ms-Rahmenrate des Codecs auf das TDMA-Raster bringt. Wer den
Sprachpfad implementiert, muss diese Bilanz kennen: sie legt fest, dass **je Verkehrsschlitz
und Frame genau ein Sprachburst** entsteht — nicht mehr, nicht weniger.

Erwartete Burst-Rate je aktiver Sprachrichtung: `17 / 1,02 s = 16,67 Bursts/s`
[ANNAHME: Rechnung aus den belegten Einzelwerten]. Gemessen wurden auf der **Empfangsseite**
~19 erfasste Bursts/s bei aktivem PTT und Korrelator-Schwelle 11 (192 Bursts in 10 s)
[MESS 2026-05-17]. Die Differenz zu 16,67/s sind Sync-Fehlalarme, die die Selbstfilterung
(§3.4.1) im Decoder abfängt — die Erfassungsrate ist also **keine** Bestätigung der Rechnung,
sondern liegt konstruktionsbedingt darüber. Deckungsgleich mit der Rechnung ist dagegen die
**Senderate**: 17 Verkehrsframes je Multiframe ergeben 16–18 ausgesendete Sprachbursts/s je
Zeitschlitz (`voice_dl_emit_cnt`, §5.4 Punkt 3).

#### 3.1.3 Nachweis im Bezugsnetz

Die Referenz-Basisstation legt den Gruppenruf-Verkehrskanal auf **TS2** und benutzt dort
**NDB1** (also NTS1) mit Verkehrs-AACH `0x32CB`: 167 von 198 NDB1-Bursts der Aufzeichnung
tragen genau diese Kombination [GOLD `docs/reference_decode/dl_events.jsonl`, Auswertung nach
`(type, tn, aach_raw)`]. Die restlichen NDB1-Bursts liegen auf TS1 (Signalisierung, 23) bzw.
tragen Frame-18-/Stehl-Muster (8).

Die eigene Zelle zeigt dieselbe Struktur: 18 NDB1-Bursts auf TS2 mit `0x32CB`
[MESS 2026-05-25 (Dateistand), `docs/local_cell_decode/dl_events.jsonl`]. **Strukturell
gold-konform**; der AACH-Zahlenwert selbst ist zell- und rufspezifisch (Nutzungsmarker, siehe
`06` §3.8) und darf abweichen.

### 3.2 Der Sprachcodec

#### 3.2.1 Was der Codec liefert und in welcher Ordnung

Der TETRA-Sprachcodec ist ein ACELP-Verfahren mit 137 bit je 30-ms-Rahmen. Für die
Kanalcodierung werden die Bits eines Rahmens nach **Empfindlichkeitsklassen** sortiert; die
Zuordnung ist eine feste Rangtabelle je Klasse:

| Klasse | Bits je Rahmen | Bits je Burst | Schutz | Bedeutung |
|---|---:|---:|---|---|
| 0 | 51 | 102 | **keiner** | am wenigsten empfindlich |
| 1 | 56 | 112 | Faltungscode, Punktierung 112→168 | mittel |
| 2 | 30 | 60 | Faltungscode, Punktierung 72→162, **CRC-8** | am empfindlichsten |

[CODE sw/tetra_tch_s_codec.h:45-52], [CODE sw/etsi_codec/const.tab:23-30]

Die Rangtabellen (1-basierte ACELP-Bitnummern) stehen in
[CODE sw/tetra_bs_tch_s.c:30-45] (`CLASS0_POS`, `CLASS1_POS`, `CLASS2_POS`) und identisch in
[CODE sw/etsi_codec/arrays.tab:11-43] (`TAB0`, `TAB1`, `TAB2`). Die Klasse-2-Tabelle ist im
Referenzquelltext parameterweise kommentiert und zeigt, **was** hier geschützt wird:

| ACELP-Ränge | Parameter | [CODE sw/tetra_tch_s_codec.c:131-140] |
|---|---|---|
| 1–4, 9–12, 18–21 | LSF1 / LSF2 / LSF3 (Spektralhülle) | Zeilen 132–136 |
| 27–32 | Pitch-Verzögerung (Grundperiode) | Zeilen 133, 137 |
| 51–53, 78–80, 105–107, 132–134 | Energie/Verstärkung der vier Teilrahmen | Zeilen 134, 138–139 |

Klasse 2 schützt also genau die Parameter, deren Verlust den Rahmen unbrauchbar macht:
Spektralhülle, Grundperiode, Verstärkung. Das begründet, warum das Prüffeld über Klasse 2 als
Bad-Frame-Indikator taugt (§3.5.1).

#### 3.2.2 Verschränkung der beiden Sprachrahmen (normativ, war Fehlerquelle)

Innerhalb jeder Klasse werden die Bits der **beiden** Sprachrahmen eines Bursts **paarweise
verschränkt**, nicht rahmenweise hintereinander gelegt:

```
Position 2i     ← Rahmen 1, Bit TAB_x[i]
Position 2i + 1 ← Rahmen 2, Bit TAB_x[i]
```

[CODE sw/etsi_codec/sub_cc.c:186-202, `Build_Sensitivity_Classes`: `Output_Frame[2*i]` /
`Output_Frame[2*i+1]`], identisch in [CODE sw/tetra_bs_tch_s.c:47-65].

V1 enthält eine zweite, **nicht aufgerufene** Variante, die rahmenweise ordnet (alle 51
Klasse-0-Bits von Rahmen 1, dann alle 51 von Rahmen 2) und deren Kommentar sich selbst
widerspricht [CODE sw/tetra_tch_s_codec.c:143-170: „interleaved per ETSI" … „actually
frame-by-frame"]. Diese Variante ist **falsch**: sie widerspricht der Referenzimplementierung.
Damit ist `05` O-05-4 entschieden — die paarweise Verschränkung gilt, die Alternative wird
gelöscht, nicht kommentiert.

Warum das wichtig ist: Die Verschränkung verteilt die empfindlichen Bits beider 30-ms-Rahmen
über den gesamten 432-bit-Burst. Ein Fehlerbündel trifft dann beide Rahmen halb statt einen
ganz — die Grundlage der Fehlerverteilung, auf die der 24×18-Interleaver aufbaut.

#### 3.2.3 Schnittstelle des Codecs zur Kanalcodierung

Die Sprachschicht kennt nur zwei Aufrufe und keine Zwischenzustände (`05` §2.4):

```c
/* Empfangsrichtung. soft: 432 type-5-Softs in K3-Konvention (§3.4.2).
 * acelp_out wird IMMER gefüllt (best effort, R-05-13).
 * Rückgabe: 0 = Prüffeld ok, 1 = Bad Frame. */
int tetra_cc_tchs_decode_soft(const int8_t soft[432], uint32_t scramb_seed,
                              uint8_t acelp_out[274], tetra_cc_stats_t *st);

/* Senderichtung. acelp: 274 Bits in Codec-Ordnung. */
int tetra_cc_tchs_encode(const uint8_t acelp[274], uint32_t scramb_seed,
                         uint8_t type5_out[432], tetra_cc_stats_t *st);
```

`scramb_seed` kommt aus der **einen** Startwert-Funktion (`05` §3.4.3, R-05-05) und ist für
Uplink und Downlink derselbe Wert — der erweiterte Farbcode ist zellweit
[ETSI §8.2.5.2, §23.2.1 Fig. 23.5: 30-bit aus MCC(10) + MNC(14) + Farbcode(6)]. V1 berechnet
ihn im Sprachpfad lokal aus drei Registern [CODE sw/tetra_voice_pipe.c:123-130]; V2 ruft die
zentrale Funktion. Der Zeitschlitz geht **nicht** in den Startwert ein (R-05-05) — für den
Sprachkanal wäre das besonders schädlich, weil derselbe Rahmen auf verschiedene
Zeitschlitz-Halteplätze gelegt werden kann.

#### 3.2.4 Entscheidung: kein Sprach-Analyse-/Synthese-Codec in der Basisstation

Die Basisstation vermittelt Sprache zwischen Endgeräten desselben Netzes. Beide Seiten
benutzen denselben Codec. Eine Dekodierung nach PCM und erneute Kodierung wäre Tandem-Codierung:
zusätzliche Verzerrung, zusätzliche Laufzeit, zusätzliche Rechenlast — ohne
Funktionsgewinn.

**R-12-02:** Der Sprachpfad arbeitet auf den 274 Parameter-Bits. Die
Quellcodier-Funktionen sind entsprechend **nicht** Teil des Systems. Belegte Sachlage in V1:
`sw/etsi_codec/source.h` deklariert `Coder_Tetra`, `Decod_Tetra`, `Prm2bits_Tetra`,
`Bits2prm_Tetra` [CODE sw/etsi_codec/source.h:91-116], aber keine dieser Funktionen ist
im Repo implementiert und keine wird aufgerufen — `sw/etsi_codec/` enthält ausschließlich die
**Kanal**codier-Dateien [CODE sw/Makefile:39-41]. V1 ist also bereits transcoder-frei; V2
schreibt es als Entwurfsentscheidung fest, statt es als Zufall zu erben.

**Was diese Entscheidung ausschließt** und wo es dann hingehört: Sprachaufzeichnung,
Ansagen, Konferenzmischung, Verbindung zu einem leitungsvermittelten Netz. Alle vier
brauchen einen echten Codec und stehen deshalb in `18_ROADMAP.md`. Ein Analyse-/Synthese-Codec
ist zusätzlich der einzige Sprachpfad-Baustein, dessen Rechenlast auf dem Zielprozessor
kritisch werden kann (§3.9) — deshalb ist er keine Nachrüstung ohne Messung.

### 3.3 Entscheidung: Herkunft der Codec-Implementierung in V2

`00` O-00-2 lässt offen, ob V2 die ETSI-Referenzquellen weiterverwendet oder eine eigene
Implementierung erhält. **Entscheidung: eigene Implementierung; die Referenzquellen bleiben
als Test-Orakel im Verifikations-Werkzeug** (`14`), nicht im Produktionsbild.

Begründet durch zwei Messungen an genau diesem Code:

**1. Die eigene Implementierung ist bit-identisch zur Referenz.**
Über 200 zufällige 274-bit-Sprachrahmen erzeugen `tetra_bs_tch_s_encode()` und
`tetra_etsi_tch_s_encode_burst()` (= ETSI-Referenzquellen mit derselben äußeren Schicht)
**bit-identische** 432-bit-type-5-Ausgaben; beide Decoder liefern aus derselben Eingabe
**bit-identische** 274 ACELP-Bits, und der Durchlauf ist verlustfrei
(`enc_diff_bits = 0`, `dec_diff_bits = 0`, Rundlauf == Eingabe)
[SIM 2026-07-25, Host-Kreuztest über `sw/tetra_bs_tch_s.c` gegen
`sw/tetra_etsi_tch_s.c` + `sw/etsi_codec/`].

Zusätzlich einzeln geprüft: Das Prüffeld `G(X) = X⁷ + X³ + 1` plus Gesamtparität
[CODE sw/tetra_bs_tch_s.c:93-114] stimmt über 2 000 zufällige Klasse-2-Vektoren in allen
8 Bits mit der tabellengetriebenen Referenz `TAB_CRC1…TAB_CRC8`
[CODE sw/etsi_codec/arrays.tab:71-125], ausgewertet in
[CODE sw/etsi_codec/sub_cc.c `Build_Crc`], überein — 0 Abweichungen [SIM 2026-07-25]. Die
Punktierungsmuster sind ebenfalls äquivalent: die Referenz-Masken `A1`/`A2`
[CODE sw/etsi_codec/arrays.tab:48-58] wählen je Periode dieselben Mutterbits wie die kompakte
Darstellung `t`/`P[]` in [CODE sw/tetra_bs_tch_s.c:164-172] (Klasse 1: G1 immer, G2 bei jedem
zweiten Eingangsbit, G3 nie → 12 von 24; Klasse 2: G1 und G2 immer, G3 bei jedem vierten →
18 von 24).

**2. Die Referenz kostet zehnmal mehr Rechenzeit.**

| Operation | µs / Burst (Host) |
|---|---:|
| ETSI-Referenz-Kette, Decodierung | **75,4** |
| eigene Kette, Decodierung (hart wie soft) | **7,0** |
| ETSI-Referenz-Kette, Codierung | 3,9 |
| eigene Kette, Codierung | 2,4 |

[SIM 2026-07-25, x86-64-Host, gcc `-O2`, 50 000 Wiederholungen je Fall — **keine**
Messung auf dem Zielprozessor]

Faktor 10,8 in der Decodierung. Ursache ist die Bauart der Referenz: sie ist als
Bit-exaktes Fixkomma-Modell mit gesättigten 16-bit-Operatoren geschrieben, jede Addition läuft
über einen Funktionsaufruf mit Überlauf-Flag [CODE sw/etsi_codec/tetra_op.c], und der Viterbi
arbeitet mit einer 30-Stufen-Entscheidungsverzögerung über globale Zustandsmatrizen
[CODE sw/etsi_codec/arrays.tab:167-180].

**3. Die Referenz ist als Produktionscode wartungsfeindlich.** Sie umfasst 4 383 Zeilen
(`sw/etsi_codec/` 4 246 + `tetra_etsi_tch_s.{c,h}` 137) für eine Funktion, die die eigene
Implementierung in 509 Zeilen leistet, braucht `#include`-Dateien mit der Endung
`.tab`, hält Zustand in nicht-konstanten globalen Variablen, die zum Zusammenlinken in eine
eigene Datei ausgelagert werden mussten [CODE sw/etsi_codec/arrays_globals.c], und enthält
Funktionen, die in zwei Übersetzungseinheiten doppelt definiert waren.

**Konsequenz für `14_VERIFICATION.md`:** Die Referenzquellen bleiben im Repo, aber
ausschließlich als Orakel eines Host-Tests, der bei jeder Änderung an der Sprachkette
Bit-Identität über ≥ 1 000 Zufallsrahmen prüft (§5.2). Damit ist der Nutzen der Referenz
(normative Wahrheit) erhalten und ihr Nachteil (Laufzeit, Wartbarkeit, Doppelpfad im
Produktionsbild) beseitigt.

**Restunsicherheit, offen:** Die Bit-Identität ist gegen die Referenz*implementierung*
gezeigt, nicht gegen den Normtext EN 300 395-2 — dieser lag beim Schreiben nicht als Text vor
(`05` O-05-3). Die Referenzimplementierung ist ein starkes, aber nicht das oberste Orakel.
Bleibt als O-12-1.

### 3.4 Die Weiterleitungskette, Stufe für Stufe

#### 3.4.1 Stufe 1 — Erfassung in der Hardware

Vollständig in `03` §3.6 spezifiziert. Für dieses Kapitel sind vier Ergebnisse verbindlich:

- Anker ist das **letzte NTS1-Symbol** (Symbol 121 von 231); die Blockoffsets sind
  `−476` / `0` Samples, Nachlauf `480` Samples [`03` §3.6.1, ETSI Tab. 9.5].
- Ausgabe sind **432 Soft-Werte, 8 bit signed, amplituden-normiert** (R-03-06), Index =
  On-Air-Index aufsteigend, **ohne Umkehr** (`03` §3.6.4).
- Konvention K1: `soft > 0 ⇔ Bit '0'` (R-03-07).
- Der Burst trägt seinen Zeitstempel `(tn, fn, mn)` (R-00-04, R-08-10).

Der Sprachpfad verlässt sich auf **keine** weitere Eigenschaft der PHY. Insbesondere darf er
nicht annehmen, dass ein erfasster Burst überhaupt Sprache enthält. Im **Leerlauf** sind
Fehlalarme bei Korrelator-Schwelle 10 und 11 messbar 0/s, bei 9 ~9/s und bei 8 ~48/s
[MESS 2026-05-16]. Bei **aktivem PTT** liefert Schwelle 10 dagegen ~28 Detects/s gegenüber
~19/s bei Schwelle 11, bei einer echten TCH/S-Rate von 16–18/s [MESS 2026-05-17] — die
Überzahl sind wacklige und falsche Sync-Locks auf dem laufenden Signal, nicht auf Rauschen.
Jeder erfasste Burst wird decodiert und über das Prüffeld
angenommen oder verworfen — die Selbstfilterung ist der Normalfall, nicht der Ausnahmefall.

#### 3.4.2 Stufe 2 — Abholen und Vorzeichen-Anpassung

```c
/* Holt genau einen anliegenden Sprachburst ab. Rückgabe:
 *   1 = Burst geholt, 0 = keiner anliegend, <0 = Fehler. */
int tetra_voice_fetch(tetra_hal_t *hal, int8_t soft_k3_out[432],
                      tetra_burst_ts_t *ts_out);
```

Ablauf, normativ:

1. Status lesen. Liegt kein Burst an → `0` zurück, kein weiterer Registerzugriff.
2. **Zeitstempel und Softs im selben Transfer lesen** — der Zeitstempel gehört zum Datensatz,
   nicht zu einer separaten Uhr (R-12-05).
3. 108 Datenwörter lesen. Der Wortindex **inkrementiert automatisch** beim Lesen; die
   Software schreibt ihn einmal auf 0. Damit kostet ein Burst `1 + 108` AXI-Zugriffe. V1 kommt
   auf dieselbe Zahl, aber anders zusammengesetzt: 54 Wörter × (Index-Schreiben +
   Daten-Lesen) = 108 Zugriffe [CODE sw/tetra_voice_pipe.c:51-58, `SCHF_NUB_WORDS 54`,
   `SOFT_W_BITS 4`] — allerdings mit nur 4 bit Soft-Auflösung. Der Auto-Increment kompensiert
   also genau die Verdopplung der Wortzahl, die die 8-bit-Auflösung kostet (`03` O-03-4).
4. Jeden 8-bit-Soft entpacken und **negieren**. Das ist die eine legale Inversion des Systems
   (R-12-04, R-05-09):

   ```
   K1 (PHY, ETSI-ausgerichtet):  soft > 0  ⇔  Bit '0'
   K3 (Sprach-Viterbi):          soft > 0  ⇔  Bit '1'
   Anpassung:                    soft_k3 = −soft_k1
   ```

   Sättigung beachten: `−(−128)` ist nicht darstellbar. Der Wert wird auf `+127` geklemmt
   [Vorbild CODE sw/tetra_tch_s_codec.c:88].
5. Quittieren. Erst **nach** vollständigem Lesen, damit die Hardware den Puffer nicht
   vorzeitig freigibt.

**Race-Schutz (R-12-13).** V1 hat hier eine echte Lücke: die Mailbox packt bei **jedem**
Erfassungs-Puls bedingungslos neu ein und gibt der Erfassung ausdrücklich Vorrang vor der
Quittung [CODE rtl/lmac/tetra_voice_nub_read_mailbox.v:70-83]. Trifft ein neuer Burst
mitten in den 108 Lesevorgängen, mischt die Software zwei Bursts zu einem — Ergebnis ist ein
Bad Frame, dessen Ursache nirgends sichtbar wird. Das Zeitfenster ist der Lesevorgang selbst,
also ~13 µs gegen 14,167 ms Burst-Abstand ≈ 0,1 % der Bursts
[ANNAHME: Rechnung aus AXI-Zugriffszahl und Slot-Dauer, nicht gemessen]. Klein, aber ohne
Zähler und ohne Notwendigkeit.

**V2:** Doppelpufferung nach `03` §3.6.3/§3.6.7. Das Lesefenster ist bis zum Quittieren an
**einen** Burst gebunden (`07` §3.4 Punkt 2), und die Verwurfsregel ist die aus `03` §3.6.7
und `07` §3.4 Punkt 5: sind **beide** Bänke desselben Erzeugers ungelesen, wird der **neue**
Burst verworfen, der ungelesene bleibt gültig, und `mb_overrun_cnt` steigt (R-12-12). Diese
Richtung ist bewusst so: der ältere Rahmen ist der, für den die Downlink-Aussendung noch
fehlt, und die Reihenfolge der weitergeleiteten Sprachrahmen bleibt erhalten.

**Detektion eines zerrissenen Lesevorgangs (R-12-13), normativ.** Bei reiner Doppelpufferung
ist ein Riss softwareseitig nicht sichtbar, deshalb liefert die Mailbox eine Generationskennung
mit: die Abholfunktion liest die Folgenummer (`seq_num` im Kopfwort `W0[21:14]`, gespiegelt in
`REG_ULMB_STATUS[15:8]`, `07` §3.4) **vor** und **nach** den 108 Datenwörtern und vergleicht
sie samt `valid`. Bei Abweichung ist die Fensterbindung mitten im Lesevorgang gewechselt: der
Datensatz wird verworfen, `voice_mb_torn_cnt` erhöht und **nicht** quittiert. Im
spezifikationskonformen PL kann dieser Fall nicht auftreten (die Bindung hält bis zum `ACK`);
der Vergleich ist die Zusicherung, die den Fehler beim Bring-up sichtbar macht statt ihn als
Bad Frame zu tarnen.

#### 3.4.3 Stufe 3 — Decodierung und Bad-Frame-Bewertung

Ein Aufruf von `tetra_cc_tchs_decode_soft()` (§3.2.3). Die Kette dahinter steht in
`05` §3.8.6: Descramble → Deinterleave 24×18 → Klasse 0 hart über `sign(soft)` → Klasse 1 und
2 depunktieren in **einen** Soft-Puffer → **ein** Viterbi über 184 Stufen → Prüffeld über
Klasse 2 → Klassen-Rückordnung → 274 ACELP-Bits.

Ergebnis sind zwei Dinge: die 274 Bits und das Bad-Frame-Kennzeichen. Beide gehen weiter; die
Bits sind auch bei Bad Frame gefüllt (R-05-13), aber als ungeprüft markiert.

#### 3.4.4 Stufe 4 — Zielzeitschlitz bestimmen

Ein weitergeleiteter Sprachrahmen muss in den Downlink-Zeitschlitz, der zu **demselben Ruf**
gehört wie der Uplink-Zeitschlitz, aus dem er kam. Sonst tauschen zwei parallele Gruppenrufe
ihr Audio.

**V2:** `ziel_ts = tn(Zeitstempel) + 1` (ETSI-Zählung), gefolgt von einem Abgleich gegen die
Rufverwaltung: existiert kein aktiver Ruf mit diesem Verkehrszeitschlitz, wird der Burst
verworfen und `voice_no_call_cnt` erhöht. Keine Umrechnung, keine Toleranzfenster, keine
zweite Zeitquelle.

**Was V1 hier tut, und warum V2 es nicht übernimmt.** V1 liest ein Stoppuhr-Register
`REG_TS1_STOPWATCH_DELTA` (Zyklen zwischen Sende-Anker TS3 und letztem UL-Sync) und bildet
daraus über eine Nearest-Center-Zuordnung mit ±0,5 Zeitschlitz Toleranz den Zeitschlitz
[CODE sw/tetra_voice_pipe.c:95-96 → CODE sw/tetra_ts_map.h:88-95]. Die Zuordnung ist
air-validiert und bit-stabil (TS2 → 22,499 ms, TS3 → 36,669 ms, TS4 → 50,836 ms, Schrittweite
genau 14,167 ms) [MESS 2026-05-25]. Sie funktioniert also — aber sie hat drei bauliche
Nachteile: das Register muss **vor** dem Burst-Read gelesen werden, damit die Werte zusammen
passen [CODE sw/tetra_voice_pipe.c:93-94], sie hängt an einem Kalibrierwert, den `08` R-08-08
ausdrücklich **nicht** als Abnahmekriterium führt, und sie liefert bei mehreren Sprechern in
einem Frame die Zuordnung des *letzten* Sync-Ereignisses, nicht die des gelesenen Bursts. Die
gemessene Trefferrate der Zuordnung lag bei ~94 %; die fehlenden 6 % sind laut Messprotokoll
Idle-Noise-Syncs, also Bursts ohne zugehörigen Ruf [MESS 2026-05-25] — **kein** Beleg gegen die
Stoppuhr. Die drei baulichen Nachteile bleiben die Begründung für R-12-05 [ANNAHME: aus der
Konstruktion abgeleitet, nicht als Fehlzuordnung gemessen]. Mit R-00-04 ist der Zeitstempel
ohnehin vorhanden; die Stoppuhr ist im Sprachpfad damit ersatzlos entbehrlich.

Die Zeitschlitz-Umrechnungen selbst (ETSI-Index ↔ RTL-`tn`, ↔ Zuweisungs-Bitmap, ↔
Masken-Bitposition) laufen über **ein** zentrales Modul (`00` §2.2); V1 hat dieses Modul mit
`sw/tetra_ts_map.h` bereits und V2 behält das Muster.

#### 3.4.5 Stufe 5 — Neucodierung

Ein Aufruf von `tetra_cc_tchs_encode()` mit demselben Startwert wie beim Decodieren
(§3.2.3). Ergebnis: 432 sendefertige type-5-Bits.

**Warum überhaupt neu codieren und nicht die empfangenen Bits durchreichen?** Weil die
Vorwärtsfehlerkorrektur im Decoder die Uplink-Bitfehler beseitigt. Messbar: der Vergleich
`type-5 empfangen XOR type-5 neu codiert` ergibt im Mittel 5–8 gekippte Bits je Burst
(Roh-BER 1,4–1,8 %), im Spitzenfall 41 Bits (9,5 %) [MESS 2026-05-17, MESS 2026-05-25].
Genau diese Bits würde ein Durchreichen an alle zuhörenden Endgeräte weitergeben, wo sie sich
mit den Downlink-Fehlern addieren. Die Neucodierung setzt den Downlink auf einen sauberen
Ausgangspunkt zurück.

Der Vergleich ist zugleich das beste vorhandene Maß für die Luftqualität und bleibt in V2 als
Diagnose erhalten — allerdings hinter einem Schalter, nicht im Dauerbetrieb (§2.3).

#### 3.4.6 Stufe 6 — Ablage und Aussendung

**Der Weg ist die DL-PDU-Mailbox aus `07 §3.3` — es gibt keinen zweiten.** V1 hat für
Sprache eine eigene Füllmailbox mit 14 Datenwörtern, eigenem Commit-Steuerwort und vier
Zeitschlitz-Bänken [CODE rtl/lmac/tetra_voice_filler_mailbox.v:71-109,
sw/tetra_voice_filler.c:87-102]. Das ist einer der drei DL-Emissionspfade, die `00 §1.1`
als V1-Last benennt und `00 §3.6` auflöst. V2 schiebt den Sprachburst über **dasselbe**
16-Wort-Fenster wie jede andere Downlink-PDU und unterscheidet sich nur durch ein
Metadatenfeld (P3: Sonderfälle sind Parameter, nicht Pfade).

Die **Bit-Abbildung ist normativ in `07 §3.3`** und wird hier nicht wiederholt (P2):
`W[w]` Bit `b` trägt `coded[431 − (32·w + (31 − b))]`, damit ist `W0[31]` = `coded[431]` das
erste On-Air-Bit. Was in diesem Kapitel bleibt, ist die eine Umrechnung, die nur der
Sprachpfad braucht: die C-Indexordnung des Codecs (`type5[0]` = zuerst gesendet, R-05-14)
bildet auf `coded` MSB-first ab, also `coded[431 − i] = type5[i]` für `i = 0 … 431`. Daraus
folgt `W0[31] = type5[0]` — `type5[0]` geht als erstes Bit von BKN1 auf die Luft,
`type5[216]` als erstes Bit von BKN2, wie [ETSI §8.3.1.3.6 Gl. 8.58/8.59] fordert. Diese
Umrechnung ist an genau dieser Stelle dokumentiert und nirgends sonst wiederholt.

**Zeitschlitz-Wahl und Halten** statt Bank und Commit: `W14.target_ts` (ETSI 1…4) benennt
den Sprach-Zeitschlitz, `W14.mode = PERSIST_SET` legt den Inhalt auf dessen **Halteplatz**,
`REG_DLMB_GO` löst die Übernahme aus, `mode = PERSIST_CLEAR` löscht den Halteplatz. Die
Übernahme kopiert den vollständigen Stufenpuffer **in einem `clk_sys`** — ein Burst kann
nicht halb übernommen werden (`07 §3.2`, Ablauf PS→PL Schritt 4). Diese Eigenschaft ist
verbindlich für V2; sie ist der Grund, warum die Ablage keinen Handshake mit dem
Sende-Zeitplan braucht.

**Vier Halteplätze, einer je Zeitschlitz** (`07 §3.3`, Betriebsart `PERSIST_SET`). Damit
tragen mehrere gleichzeitige Gruppenrufe auf verschiedenen Zeitschlitzen ihr Audio ohne
Übersprechen — funktional dasselbe wie V1s vier Bänke, nur über dasselbe Fenster wie alles
andere. Der Stufenpuffer ist gemeinsam; daraus folgt: **Beschreiben des Fensters und
`REG_DLMB_GO` sind eine unteilbare Operation der Software.** Bei einem einzigen
Sprachpfad-Thread ist das erfüllt; jede Parallelisierung in `13` muss diese Sequenz sperren.

**Aussendung.** Der Halteplatz speist den Zeitschlitz, solange (a) und (b) der Halteplatz
dieses Zeitschlitzes gesetzt ist (`persist_valid[tn]`, gesetzt durch `PERSIST_SET`, gelöscht
durch `PERSIST_CLEAR`; V1 hatte dafür zwei getrennte Größen — ein Sprach-Aktivbit in
`REG_VOICE_ACTIVE_MASK` und ein Bank-`valid` —, V2 hat eine) und (c) der Frame ein
**Verkehrsframe** ist: ETSI-Frame 1…17, im RTL `fn_sys ≤ 16` (0-basiert, §3.1.1)
[CODE rtl/tx/tetra_burst_dispatcher.v:227 `tx_fn_sys <= 5'd16`, gleichlautend :247, :267,
:287] — Bedingung (c) ist genau [ETSI §9.5.4] und erfüllt R-12-14. Wer „Frame ≤ 17" wörtlich
in 0-basiertes RTL überträgt (`fn_sys <= 17`), sendet Sprache auch im Broadcast-Anker-Frame
und verletzt beides. Der Burst geht als **NDB1** (NTS1, Vollschlitz)
hinaus, gold-konform (§3.1.3). Der Zugriffszuweisungskanal trägt in diesem Zeitschlitz den aus `SLOT_UMT` und
`SLOT_UL_STATE` **abgeleiteten** Verkehrswert (`06` §3.8.2, Zeile `content = 4 ∧
ul_state = 01`); die Software setzt ihn nicht (`06` R-06-05). V1 schreibt ihn dagegen als
fertiges Infowort [CODE rtl/tx/tetra_aach_encoder.v:257-262].

**Wiederholungsverhalten, wichtig:** Der Halteplatz behält seinen Inhalt, bis er
überschrieben oder gelöscht wird. Kommt kein neuer Uplink-Burst, sendet der Downlink **denselben Sprachrahmen
erneut**. Bei 16,67 Uplink-Bursts/s und 16,67 Downlink-Verkehrsschlitzen/s ist das Verhältnis
1:1 und der Normalfall ist genau eine Aussendung je empfangenem Rahmen. Bei einem verlorenen
Uplink-Burst entsteht eine Rahmenwiederholung — das ist zugleich die einfachste Form der
Fehlerverdeckung und der Grund, warum §3.5.4 sie nicht durch Stille ersetzt.

#### 3.4.7 Adresse im Sprachrahmen — Befund und Festlegung

**Befund: Es gibt keine.** Der Sprachburst trägt eine MAC-TRAFFIC-PDU, und die hat
konstruktiv keinen Kopf:

> „The MAC-TRAFFIC PDU shall be used for sending U-plane traffic data on the uplink and
> downlink using TCH/S […]. This PDU has no MAC header and all capacity shall be devoted to
> traffic information" [ETSI §21.4.6]

> „User traffic TCH does not have a MAC header." [ETSI §23.8.3.0 a)]

Alle 432 Bits sind Sprache. Es existiert kein Adressfeld, das ersetzt werden könnte. Die
Zuordnung „welcher Ruf" läuft über den Zeitschlitz, die Zuordnung „welcher Sprecher" über die
Rufsteuerung.

**V1 dokumentiert an fünf Stellen eine Adress-Ersetzung, die der Code nicht ausführt:**

| Stelle | Behauptung |
|---|---|
| [CODE sw/tetra_voice_pipe.c:5-8] | „patches the 24-bit MAC-RESOURCE SSI to the call target" |
| [CODE sw/tetra_voice_pipe.h:5-9, :21-30] | „the SSI in the header is patched to the active call target" |
| [CODE sw/tetra_call_fsm.c:811-813] | „SSI auf Call-Target patchen" |
| [CODE sw/tetra_voice_filler.h:11-12] | „UL-NUB bits decoded + addr-patched + re-encoded" |
| [CODE rtl/infra/tetra_axi_lite_regs.v:470-472] | „SW soft-Viterbi-decodes, patches MAC-RESOURCE SSI, re-encodes" |

Der ausgeführte Code verwirft den übergebenen Zielwert in der ersten Anweisung der Funktion:
`(void)target_ssi;  /* Phase D: Routing via UL-air-TS, nicht via SSI */`
[CODE sw/tetra_voice_pipe.c:88]. Es gibt keine Bit-Manipulation zwischen Decodierung und
Neucodierung. Die einzige Codestelle, die überhaupt je eine Gruppenadresse in einen
Verkehrsschlitz-Burst geschrieben hat — eine MAC-RESOURCE-Leer-PDU mit der Gruppenadresse als
SSI [CODE sw/tetra_voice_filler.c:30-71] — hat **keinen Aufrufer** (verifiziert: keine
Referenz auf `tetra_voice_filler_install` außerhalb ihrer eigenen Datei). Sie ist zusätzlich
normwidrig aufgebaut: Längenangabe 62 = `111110₂` bedeutet „zweite Halbschlitzhälfte in STCH
gestohlen" [ETSI §21.4.3.1 Tab. 21.55] und ist auf einem Vollschlitz-SCH/F keine definierte
Länge; eine echte Leer-PDU trägt Adresstyp `000₂` [ETSI §21.4.3.1].

**Wo die Sender-Identität wirklich läuft** (Details in `10`):

- **Sprecher:** `calling_party_ssi` in der Rufaufbau-PDU an die Gruppe
  [CODE sw/tetra_call_fsm.c:264]. Bei einem Sprecherwechsel innerhalb desselben Rufs wird das
  Sprecher-Feld des Rufkontextes umgesetzt und die PDU erneut gesendet
  [CODE sw/tetra_call_fsm.c:431, :533] — **das** ist die „Adressersetzung", die die zuhörenden
  Endgeräte sehen, und sie liegt in der Rufsteuerung, nicht im Sprachrahmen.
- **Ruf-zu-Zeitschlitz:** Verkehrs-Nutzungsmarker im Zugriffszuweisungskanal, konstant über
  den ganzen Ruf einschließlich Sprecherwechsel [MESS 2026-05-25], [GOLD].

**R-12-06** schreibt die Adress-Transparenz fest, und die fünf Kommentarstellen werden in V2
nicht übernommen. Der Befund gehört zusätzlich als Zeile nach `17_LESSONS_LEARNED.md`: eine
Beschreibung, die an fünf Stellen steht und an keiner zutrifft, kostet jeden Leser dieselbe
Stunde.

### 3.5 Erkennung fehlerhafter Rahmen

#### 3.5.1 Definition

Bad Frame Indication (BFI) ist das Ergebnis des 8-bit-Prüffelds über die 60
Klasse-2-Bits eines Bursts: 7 Prüfbits aus `G(X) = X⁷ + X³ + 1` plus ein Gesamtparitätsbit
[CODE sw/tetra_bs_tch_s.c:88-114]. Stimmt es nicht, ist der Rahmen als Bad Frame markiert.
Das Prüffeld deckt nur Klasse 2 ab (§3.2.1) — die empfindlichsten Parameter.

**BFI = 0 bedeutet nicht fehlerfrei.** Klasse 0 (102 der 274 Bits) ist ungeschützt, Klasse 1
nur teilgeschützt. Gemessen an derselben Kette: bei 5 gekippten codierten Bits je Burst
(≈ 1,2 % Roh-BER) liegt die BFI-Rate bei 0,0 %, es bleiben aber **1,28 fehlerhafte
ACELP-Bits je Burst** stehen [SIM 2026-07-25]. Die BFI-Rate ist deshalb die
**Güte­kenngröße**, nicht die Fehlerfreiheits­garantie.

#### 3.5.2 Gemessene Kennlinie der Kette

Vollmagnitude-Vorzeichenumkehr an zufälligen Positionen des 432-bit-Soft-Vektors (Worst Case
für einen Soft-Decoder), 2 000 Durchläufe je Punkt [SIM 2026-07-25]:

| gekippte codierte Bits | Roh-BER | BFI-Rate | restliche ACELP-Bitfehler/Burst |
|---:|---:|---:|---:|
| 0 | 0 % | 0,0 % | 0,00 |
| 5 | 1,2 % | 0,0 % | 1,28 |
| 10 | 2,3 % | 0,1 % | 3,08 |
| 15 | 3,5 % | 0,6 % | 5,53 |
| 20 | 4,6 % | 1,2 % | 8,78 |
| 25 | 5,8 % | 4,7 % | 12,59 |
| 30 | 6,9 % | 9,4 % | 17,21 |

Die Kennlinie passt zur Luftmessung: bei gemessenem Roh-BER von 1,4 % (avg) wären laut
Tabelle BFI ≈ 0 % zu erwarten, und genau das wurde gemessen — 0 % (2 von 840 Bursts)
[MESS 2026-05-25]. Damit ist die Simulationskennlinie an einem Luftpunkt kalibriert und als
Vorhersagewerkzeug brauchbar: **oberhalb ~5 % Roh-BER bricht die Sprachqualität ein.**

#### 3.5.3 Wie die Rate in V1 von fast vollständigem Ausfall auf Prozentwerte kam

Drei Eingriffe, jeder einzeln belegt. Die Empfangsseite ist in `03` spezifiziert; hier stehen
nur die Wirkungen auf die BFI-Rate, ohne die dortigen Werte zu wiederholen.

| Eingriff | Wirkung auf BFI | Beleg |
|---|---|---|
| **Abtastpositionen der Burst-Erfassung korrigiert** (Blockoffsets stammten aus dem Downlink-Burst-Layout, das für den Uplink nicht gilt) — zusammen mit der Bit-Ordnung zwischen Hardware und Software | **98 % → hörbares Audio**, 3/3 PTT-Läufe klar | [MESS 2026-05-17]; Geometrie in `03` §3.6.1/§3.6.2 |
| **Soft-Entscheidungen statt harter Bits** in den Viterbi | Median **6 % → 3 %** (A/B über 4 PTT-Läufe); im Dauerbetrieb Soft 0 % gegen Hard 1 % (840 Bursts) | [MESS 2026-05-18], [MESS 2026-05-25] |
| **Amplituden-Normierung des Soft-Werts** (in V1 **nur** im Steuerburst-Pfad umgesetzt) | belegt ist nur die Wirkung im Steuerburst-Pfad: 3/3 PTT saubere Sprache, gemessener TS2-Anker bit-identisch bei 22,497 ms; im Amplituden-Sweep pegelunabhängige Soft-Qualität | [SIM 2026-05-30] Amplituden-Sweep, [MESS 2026-05-30] Luft 3/3 PTT — Wirkung auf die Sprach-BFI **nicht** gemessen (der Sprachburst-Pfad ist ungenormt, siehe unten und O-12-4) |
| Korrelator-Schwelle 10 → 11 (weniger Fehl-Sync, weniger Müll im Decoder) | Lauf-BFI **6,1 % → 4,7 %** | [MESS 2026-05-17]; Wert und Nachbarwerte in `03` §4 |

**Die Reihenfolge ist die Lehre.** Der erste Eingriff war ein Geometriefehler, die anderen
drei Verbesserungen der Entscheidungsqualität. Ein Geometriefehler kostet zwei
Größenordnungen, eine Verbesserung der Entscheidungsqualität einen Faktor 2. Wer bei hoher
BFI-Rate zuerst am Decoder dreht, sucht an der falschen Stelle — der erste Verdacht ist immer
die Erfassungsgeometrie, und sie ist rechnerisch prüfbar (`03` §3.6.1).

**Was V2 erreichen muss: R-12-08.** BFI ≤ 5 % im Nahfeld, ≤ 10 % auf 50 m, `BFI_soft ≤
BFI_hard` in jedem Lauf. Die Schwellen liegen bewusst über den in V1 gemessenen 0 % bzw.
5–6 %: die Tagesvariabilität des Roh-BER beträgt 1,4–3,5 % [MESS 2026-05-18], und ein
Abnahmekriterium, das nur an einem guten Tag hält, ist kein Kriterium. Wer die V1-Werte
reproduzieren will, muss A/B im selben Capture messen (R-12-09).

**Ein Nachteil des NUB-Pfads bleibt offen:** Die Amplituden-Normierung ist in V1 nur im
Steuerburst-Pfad umgesetzt, der Sprachburst-Pfad benutzt weiter einen festen Shift
[CODE rtl/rx/tetra_ul_nub_capture.v:77-78]. R-03-06 fordert sie für **beide** Pfade. Das ist
die erste Maßnahme, wenn die BFI-Rate über Entfernung nicht hält (`03` §3.6.6, `03` O-03-1).

#### 3.5.4 Behandlung eines Bad Frames

**V1:** Der Rahmen wird trotzdem neu codiert und ausgesendet
[CODE sw/tetra_voice_pipe.c:174-192 → :304-306, ohne BFI-Abfrage]. Ergebnis: ein Rahmen mit
unbrauchbaren Klasse-2-Parametern erreicht die zuhörenden Endgeräte als **prüffeld-korrekter**
Burst. Deren eigene Fehlerverdeckung greift nicht, weil ihr Prüffeld stimmt. Die
Basisstation wäscht die Fehlermarkierung, statt sie zu übertragen.

**V2 — R-12-07:** Die Fehlermarkierung wird propagiert. Verbindliche Regel:

| Fall | Verhalten |
|---|---|
| Prüffeld ok | Neucodieren, auf den Halteplatz des Zielzeitschlitzes ablegen (§3.4.5/§3.4.6) |
| **Bad Frame** | Neucodieren, aber **ein Bit des Klasse-2-Prüffelds invertieren**, bevor der Faltungscodierer läuft. Der Burst ist danach strukturell gültig (Sync, Interleaving, Scrambling korrekt), das Endgerät setzt sein eigenes BFI und aktiviert seine Fehlerverdeckung. `voice_bfi_cnt++` |
| kein Ruf zum Zeitschlitz | Verwerfen, `voice_no_call_cnt++` |
| Überlauf der Ablage | Verwerfen, `mb_overrun_cnt++` (R-12-12) |

[ANNAHME: Die Bit-Invertierung ist die minimale Umsetzung von „Markierung propagieren" und
in V1 nicht implementiert; sie ist nicht an der Luft geprüft. Alternative wäre, den Halteplatz
unverändert zu lassen — dann wiederholt der Downlink den letzten guten Rahmen (§3.4.6). Beide
Varianten sind gegen das Hörergebnis zu vergleichen, siehe O-12-2.]

Was ausdrücklich **nicht** zulässig ist: bei Bad Frame Stille senden oder den Zeitschlitz
abschalten. Ein einzelner Ausfall unter 10 % Rate ist für einen Sprachdecoder mit
Fehlerverdeckung unhörbar; ein Zeitschlitz-Abbruch kostet den Ruf.

### 3.6 Sprechpausen-Erkennung je Zeitschlitz

#### 3.6.1 Mechanismus

Jeder Ruf hat einen Verkehrszeitschlitz und einen Zeitstempel „letzte Uplink-Sprachaktivität".
Beim Abholen eines Bursts wird der Zeitstempel des Rufs mit dem passenden Zeitschlitz
aufgefrischt [CODE sw/tetra_voice_pipe.c:102 → CODE sw/tetra_call_fsm.c:868-877]. Ein
Überwachungsdurchlauf prüft je Ruf das Alter und wirkt **nur auf dessen Zeitschlitz**:

| Alter | Wirkung |
|---|---|
| ≤ 300 ms | Halteplatz des Zeitschlitzes gesetzt (`mode = PERSIST_SET`), Downlink sendet Audio |
| > 300 ms | Halteplatz **dieses** Zeitschlitzes gelöscht (`mode = PERSIST_CLEAR`, `07 §3.3`). Der Ruf bleibt bestehen, nur der Sprachweg endet [CODE sw/tetra_call_fsm.c:804-809, :56-74] |
| > 5 s | Ruf freigegeben (Endgerät ohne Abmeldung verschwunden) [CODE sw/tetra_call_fsm.h:48] |

Die Aktivmaske ist das OR der Bitpositionen aller Rufe mit frischer Aktivität
[CODE sw/tetra_call_fsm.c:56-74]. Sie steuert zwei Dinge gleichzeitig: die Freigabe der
Sprach-Ablage im Sendepfad (§3.4.6) und den Verkehrswert im Zugriffszuweisungskanal
[CODE rtl/tx/tetra_aach_encoder.v:257-262].

Die Zeitrechnung läuft auf der monotonen Software-Uhr. Das ist zulässig, weil die Toleranz
≥ 100 ms ist (R-08-13) — aber **nur** dafür; ein Luft-Zeitbezug darf nie daraus abgeleitet
werden. Zwei Details, die V1 gelernt hat und die V2 übernimmt: der Vergleich muss sättigend
subtrahieren, weil der Auffrischwert wenige Millisekunden in der Zukunft liegen kann
[CODE sw/tetra_call_fsm.c:65-69], und ein klingelnder Einzelruf darf vom Sprach-Watchdog nicht
freigegeben werden, weil vor der Annahme noch keine Sprache fließt
[CODE sw/tetra_call_fsm.c:782-792].

#### 3.6.2 Wirkung, die man kennen muss

**Bei Sprechpause fällt der Sprachweg für die Dauer des Zeitgebers aus.** Das ist kein
Nebeneffekt, sondern der Zweck: solange das Aktivbit steht, meldet der
Zugriffszuweisungskanal den Zeitschlitz als belegt, und die Endgeräte behandeln den Kanal als
besetzt. Zu langes Stehenbleiben verzögert die Reaktion auf den nächsten Sprechwunsch.

Der Preis ist symmetrisch: Bei hoher BFI-Rate können mehrere Uplink-Bursts hintereinander
ausfallen. 300 ms toleriert etwa fünf verlorene Bursts (Abstand 56,67 ms); danach fällt das
Audio **mitten im Ruf** kurz aus und kommt beim nächsten guten Burst zurück. Genau dieses
Flackern wurde 2026-05-17 bei einer Ruhezeit von 203 ms beobachtet [MESS 2026-05-17].

#### 3.6.3 Der Wert ist festgelegt: 300 ms (R-12-11)

| Wert | Gemessenes Verhalten |
|---|---|
| ~200 ms | Aussetzer mitten im Ruf, weil drei verlorene Bursts die Schwelle reißen [MESS 2026-05-17] |
| **300 ms** | **festgelegt.** Kein nennenswerter Zuwachs der Latenz nach Sprechende, Mitten-im-Ruf-Aussetzer beseitigt [MESS 2026-05-17]; Multi-Gruppen-Betrieb air-verifiziert: Maske folgt dem Sprechzustand (`0x02 → 0x06 → 0x04 → 0x02`), die losgelassene Gruppe verstummt, die andere läuft weiter [MESS 2026-05-25] |
| 1 000 ms | **im Hörurteil schlechter.** Die Maske hält den Zeitschlitz eine Sekunde länger als belegt, obwohl schon Stille ist; die Endgeräte sehen den Kanal zu lange besetzt und reagieren träger auf den nächsten Sprechwunsch. Beleg: Hörurteil nach PTT-Lauf beider Geräte, „war vorher besser" — **keine** Zahlengröße, es existiert kein Zähler- oder Latenzwert für diesen Fall [MESS 2026-05-25]; Codestand und Begründung [CODE sw/tetra_call_fsm.h:38-43] |

**Wer diesen Wert ändern will, braucht eine neue Messreihe nach §5.4** — und muss vorher
prüfen, ob das eigentliche Symptom nicht die BFI-Rate ist. Aussetzer mitten im Ruf und
Flackern der Zuweisungsmaske haben ihre Wurzel in der Uplink-Empfangsqualität, nicht in dieser
Schwelle.

**Ein Ort, ein Wert.** R-12-11 ist die normative Definition. `10_CMCE_CALL.md` verwendet
denselben Zeitgeber für den Rufzustand und **verweist** auf R-12-11, statt den Wert erneut zu
nennen (P2). Der 5-s-Zeitgeber für die Rufauflösung gehört dagegen `10`; er steht hier nur
als Kontext, weil beide Zeitgeber dieselbe Aktivitätsquelle benutzen.

### 3.7 Stehlen von Halbschlitzen im laufenden Ruf

#### 3.7.1 Was das für den Sprachkanal bedeutet

Stehlen ersetzt Blockinhalte **nach** Codierung, Interleaving und Scrambling
[ETSI §8.3.1.3.1]; angezeigt wird es durch die Trainingsfolge NTS2, nicht durch ein Kopffeld
[ETSI §9.5.4] (Details `06` §3.3). Die erste Bursthälfte wird immer zuerst gestohlen
[ETSI §9.5.4].

Für den **Sprachcodec** ist Stehlen aber kein reines MAC-Ereignis. Die Norm sagt ausdrücklich:

> „It is considered that the MS is not stealing from a full slot speech channel but the MAC
> first informs the speech channel encoder which discards the type-1 bits of speech frame A
> and then uses half slot speech channel encoding for the type-1 bits of speech frame B."
> [ETSI §8.3.1.3.6 NOTE]

Der Sprachkanal wechselt also die Betriebsart: statt 274 Bits (zwei Sprachrahmen) in 432 Bits
werden **137 Bits (nur Rahmen B) in 216 Bits** codiert — mit eigenem, kürzerem Prüffeld,
eigenem Punktierungsmuster und einem anderen Interleaver:

| Größe | Vollschlitz | Halbschlitz | Beleg |
|---|---:|---:|---|
| Sprachrahmen je Burst | 2 (274 bit) | **1 (137 bit)** | [ETSI §8.3.1.3.6 / §8.3.1.3.7] |
| type-3-Bits | 432 | **216** | [ETSI §8.3.1.3.7] |
| Prüffeld über Klasse 2 | 8 bit | **4 bit** | [CODE sw/etsi_codec/const.tab:44-45] |
| Punktierung Klasse 2 | 8/18 | **8/17** | [CODE sw/etsi_codec/arrays.tab:60-65] |
| Interleaver | 24 × 18 (432) — [CODE sw/etsi_codec/const.tab:57-58], [CODE sw/tetra_tch_s_codec.h:57-58]; normativ EN 300 395-2 §5.5.3, dessen Text nicht vorliegt (O-12-1) — [ETSI §8.3.1.3.6] verweist nur dorthin und nennt keine Matrix | **(216, 101)** — [ETSI §8.3.1.3.7] | Beleg je Spalte, siehe links |
| belegter Block | BKN1 + BKN2 | **nur BKN2** | [ETSI §8.3.1.3.7 Gl. 8.60 + NOTE] |

#### 3.7.2 Stand in V1 — ehrlich

- **MAC-Seite Downlink: vorhanden** (`06` §3.3.2).
- **Sprachcodec-Seite: nicht vorhanden.** Die live laufende Implementierung hat **keine**
  Halbschlitz-Betriebsart: `tetra_bs_tch_s_encode()` / `_decode()` kennen keinen
  Stehl-Parameter, die Klassengrößen sind auf 102/112/60 festgelegt
  [CODE sw/tetra_bs_tch_s.c:320-325, :452-509]. Die Betriebsart existiert nur in den
  **toten** ETSI-Referenzquellen (`Frame_Stealing`-Zweig in `Channel_Encoding` /
  `Channel_Decoding`, [CODE sw/etsi_codec/ccod_tet.c:60-95],
  [CODE sw/etsi_codec/cdec_tet.c:55-73]).
- **MAC-Seite Uplink: nicht vorhanden.** Der Uplink-Korrelator ist ausschließlich auf NTS1
  parametriert; ein gestohlener Uplink-Burst wird still verworfen (`06` §3.3.2, `03` §3.3.4).

**Folge, unmissverständlich:** Wird in V1 ein Sprachschlitz gestohlen, verliert das Endgerät
beide Sprachrahmen dieses Bursts, nicht nur den einen, den die Norm opfert — weil die
Basisstation den Rest-Halbschlitz nicht in Halbschlitz-Sprachcodierung liefern kann.
Deshalb **R-12-18**: ohne Halbschlitz-Sprachcodierung darf kein Sprachschlitz gestohlen
werden. Die Entscheidung, ob Stufe 1 Stehlen auf Verkehrsschlitzen überhaupt braucht, gehört
zu `10`; die Signalisierungsmechanik zu `06`; die Codec-Betriebsart wäre hier zu ergänzen und
ist bis dahin Roadmap.

Die U-Plane-Variante des Stehlens (121 bit Nutzlast + 3 bit Kopf = 124 bit Halbschlitz-Block,
[ETSI §23.8.3.0 a)]) betrifft Ende-zu-Ende-Signalisierung zwischen Endgeräten und ist in
Stufe 1 kein Sprachpfad-Thema.

### 3.8 Fehler- und Randfälle

| Fall | Verhalten | Zähler |
|---|---|---|
| Kein Burst anliegend | Sofortige Rückkehr, ein Statuslesevorgang | — |
| Prüffeld verletzt | §3.5.4 | `voice_bfi_cnt` |
| Zeitstempel zeigt Zeitschlitz ohne aktiven Ruf | Burst verwerfen. Normalfall im Leerlauf: Korrelator-Fehlalarme und Signalisierungsbursts | `voice_no_call_cnt` |
| Beide Bänke ungelesen, dritter Burst kommt | **Neuer** Burst verworfen, der ungelesene bleibt gültig, **muss zählen** (R-12-12, `03` §3.6.7) | `mb_overrun_cnt` |
| Lesevorgang von neuem Burst überlappt | Darf nicht auftreten (R-12-13: Fensterbindung bis zum Quittieren). Erkennung über die Folgenummer vor/nach den 108 Lesevorgängen (§3.4.2); tritt es auf: Datensatz verwerfen, nicht quittieren, Implementierungsfehler im PL | `voice_mb_torn_cnt` |
| Scrambler-Startwert 0 | Ersetzt durch `0xFFFFFFFF` (R-05-15) | `seed_degenerate` |
| Aktiver Ruf, aber keine Uplink-Aktivität > 300 ms | Aktivbit und Ablage **dieses** Zeitschlitzes löschen, Ruf bleibt (§3.6) | `voice_quiet_cnt` |
| Aktiver Ruf, keine Aktivität > 5 s | Ruf freigeben (`10`) | `call_stale_cnt` |
| Frame 18 | Kein Sprachburst; Broadcast-Anker (R-12-14) | — |
| Mehr aktive Sprachkanäle als Verkehrszeitschlitze (> 3) | Rufannahme scheitert in `10`; der Sprachpfad sieht diesen Fall nicht | — |
| Sprechwechsel innerhalb eines Rufs | Für den Sprachpfad ereignislos: Zeitschlitz, Nutzungsmarker und Ablage bleiben. Nur `10` wechselt die Sprecheradresse (§3.4.7) | — |

### 3.9 Rechenlast auf dem ARM-Kern

Der Sprachpfad ist in V2 **nicht** der teure Teil der Software — aber er läuft ununterbrochen,
und die Kanalcodierung aller anderen Kanäle liegt daneben auf demselben Kern. Deshalb hier die
Bilanz für den Sprachanteil; die Gesamtbilanz steht in `05` §3.10 und `13`.

**Host-Messung** (x86-64, gcc `-O2`, 200 000 Wiederholungen je Fall, Code aus
`sw/tetra_bs_tch_s.c`) [SIM 2026-07-25] — **keine** Messung auf dem Zielprozessor:

| Vorgang | µs / Burst (Host) |
|---|---:|
| TCH/S decodieren, soft (Descramble + Deinterleave + Depunktierung + Viterbi 184 Stufen + Prüffeld + Rückordnung) | 6,94 |
| TCH/S codieren (Ordnung + Prüffeld + Faltung + Punktierung + Interleave + Scramble) | 2,38 |
| **Summe je weitergeleitetem Rahmen** | **9,32** |

**Umrechnung auf den Zielprozessor:** Cortex-A9 bei 667 MHz, skalarer Integer-Code mit
Tabellenzugriffen. Angenommener Gesamtfaktor **10–12** aus Taktverhältnis und
Pipeline-Unterschied [ANNAHME — identische Annahme wie `05` §3.10, damit beide Kapitel
dieselbe Skala benutzen].

**Bilanz je aktivem Sprachkanal** (16,67 Bursts/s, §3.1.2):

| Posten | je Burst (A9, Faktor 11) | je Sekunde und Sprachkanal |
|---|---:|---:|
| Codec-Kette (decode + encode) | ≈ 103 µs | 1,7 ms |
| AXI-Transfer Abholen: 111 Wörter ⇒ 2 + 222 = **224** Zugriffe (`07 §3.2`: kein automatischer Indexvorschub, je Wort ein `INDEX`- **und** ein `DATA`-Zugriff; plus 2 Statuszugriffe §3.4.2) | ≈ 22,4 µs | 0,37 ms |
| AXI-Transfer Ablegen: 16 Wörter ⇒ 32 + 2 = **34** Zugriffe | ≈ 3,4 µs | 0,06 ms |
| **Summe** | **≈ 129 µs** | **≈ 2,2 ms/s ⇒ 0,22 % eines Kerns** |

AXI-Zugriffskosten mit **100 ns** je uncached 32-bit-Zugriff über den Universalport
angesetzt [ANNAHME — nicht gemessen; die Software greift über eine `mmap`-Abbildung direkt
zu, jeder Zugriff ist eine AXI-Lite-Transaktion, CODE sw/tetra_hal.h:501-507].

Die Zugriffszahlen sind aus `07 §3.2` (Zugriffsmodell) und `13 §3.12.1` (Bilanz) übernommen
und dort normativ; dieses Kapitel rechnet sie nur auf den Sprachpfad um.

**Drei aktive Sprachkanäle (TS2/TS3/TS4, das Maximum):** ≈ 6,5 ms/s ≈ **0,7 % eines Kerns**;
teuerster Einzelvorgang 129 µs gegen 14 167 µs Zeitschlitz-Budget = **0,9 %** eines
Zeitschlitzes. R-12-16 ist damit rechnerisch mit über zwei Größenordnungen Reserve erfüllt.

**Bemerkenswert ist das Verhältnis, nicht der Absolutwert:** der Registertransfer kostet
etwa ein Zehntel der Codec-Zeit. Wer die Soft-Breite am Wortport von 8 auf 4 bit halbiert
(`03` §3.7 lässt das ausdrücklich zu), halbiert die Wortzahl von 108 auf 54 und spart damit
**108** Zugriffe ≈ 10,8 µs je Burst — und verliert Soft-Auflösung. Das ist kein guter Handel,
solange die Last bei 0,7 % liegt.

**Drei Lastfallen, die V1 gestellt hat und V2 vermeidet:**

1. **Doppelte Decodierung.** V1 decodiert jeden Burst **zweimal** — einmal hart, einmal soft
   — für einen A/B-Vergleich, der als Dauerdiagnose gedacht war
   [CODE sw/tetra_voice_pipe.c:170-174]. Das verdoppelt den teuersten Posten.
   **V2: hinter einem Diagnose-Schalter** (R-12-16-relevant, §2.3).
2. **Heap je Burst.** Die Viterbi-Trellis-Ablage wird je Aufruf mit `calloc` geholt und mit
   `free` zurückgegeben [CODE sw/tetra_bs_tch_s.c:269, :313] — bei drei Sprachkanälen 50
   Heap-Paare/s in einem Dauerläufer-Daemon. Größe ist konstant (184 × 2 Byte).
   **V2: statisch (R-12-17).**
3. **Abfrage-Takt.** V1 fragt die Mailbox alle 10 ms ab
   [CODE sw/tetra_attach_daemon.c:86] und holt je Durchlauf und aktivem Ruf **einen** Burst.
   Bei drei Sprechern treffen drei Bursts im Abstand von 14,167 ms ein — mit 10 ms Takt geht
   das gerade auf, bei einer einzigen Ablagestelle aber ohne Reserve. Das ist die zweite
   Begründung für Doppelpufferung (R-12-12) und der Grund, warum `13` den Sprachpfad nicht in
   einen Durchlauf mit langsamer Abfrage legen darf. Die Latenzbudgets stehen in `08`.

**Nicht in dieser Bilanz:** ein Sprach-Analyse-/Synthese-Codec. Er würde die PS-Last um
Größenordnungen dominieren und ist nach R-12-02 nicht Teil des Systems (§3.2.4). Das ist die
wichtigste Rechenlast-Entscheidung dieses Kapitels — nicht die Mikrooptimierung der 9,3 µs.

### 3.10 Beobachtbarkeit (R-12-15)

| Zähler | Ort | Zweck |
|---|---|---|
| `voice_ul_capture_cnt` | PL | erfasste Uplink-Sprachbursts. Plausibilitätsband 16–19/s je Sprecher (echte TCH/S-Rate 16–18/s plus Sync-Fehlalarme, §3.1.2, `03` §5.5) — Echtzeit-Indikator für aktive Sendetätigkeit; der Ruf-Watchdog baut darauf auf |
| `mb_overrun_cnt` | PL | verworfene Bursts, weil beide Bänke ungelesen waren (R-12-12). Name und Semantik gehören `03` §3.6.7, Registerlage `07` §3.1.8 — hier nur verwiesen |
| `voice_mb_torn_cnt` | PS | Abholvorgänge, bei denen die Folgenummer der Mailbox vor und nach den 108 Datenwörtern abwich (§3.4.2). Erwartungswert 0; jeder Zuwachs ist ein Verstoß gegen die Fensterbindung aus `07` §3.4 und damit ein PL-Fehler |
| `voice_fetch_cnt` | PS | abgeholte Bursts — Differenz zu `voice_ul_capture_cnt` ist die Verlustrate |
| `voice_bfi_cnt` | PS | Bad Frames. Verhältnis zu `voice_fetch_cnt` ist die Kenngröße aus R-12-08 |
| `voice_fec_diff_sum` / `_max` | PS | gekippte codierte Bits je Burst (§3.4.5) — der Roh-BER-Schätzer |
| `voice_soft_mag_avg` | PS | mittlerer Soft-Betrag am 8-bit-Wortport; Arbeitspunkt-Anzeige der Normierung. Erwartungsbereich V2 `\|soft\| ≈ 16…32` (`03` §5.5 Punkt 4, [ANNAHME] aus `NORM_TGT = 5`). Die V1-Werte `~6,5`/`~7,1` stammen aus dem ungenormten 4-bit-Pfad (Bereich 0…8, also Sättigung) und sind **kein** Vergleichsmaßstab |
| `voice_no_call_cnt` | PS | Bursts ohne zugehörigen Ruf |
| `voice_quiet_cnt` | PS | Sprechpausen-Auslösungen je Zeitschlitz |
| **`voice_dl_emit_cnt[4]`** | PL | **tatsächlich ausgesendete** Sprachbursts je Zeitschlitz |

Die letzte Zeile ist eine Korrektur an V1: dort existiert das Register, aber es ist konstant 0
verdrahtet [CODE rtl/tetra_zynq_top.v:268-269]. Ohne diesen Zähler ist die Frage „sendet der
Downlink überhaupt Sprache?" nur über eine Luft-Aufzeichnung beantwortbar — bei einem
Sprachpfad, dessen Ablage genau dann stumm bleibt, wenn ein Gültigkeitsbit fehlt, ist das die
teuerste mögliche Diagnose. Die Zählerformate stehen in `07`.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| **Sprechpausen-Zeitgeber** | **300 ms** | [MESS 2026-05-17], [MESS 2026-05-25]; [CODE sw/tetra_call_fsm.h:43] | ~200 ms → Aussetzer mitten im Ruf (3 verlorene Bursts reißen die Schwelle). 1 000 ms → Zuweisungsmaske hält den Zeitschlitz 1 s zu lange belegt, träge Reaktion auf den nächsten Sprechwunsch, im **Hörurteil** beider Geräte schlechter (keine Zahlengröße, §3.6.3). **Nicht ohne neue Messreihe ändern (R-12-11).** |
| Ruf-Verfallszeitgeber | 5 s **vorläufig** | [CODE sw/tetra_call_fsm.h:48]; keine Messreihe, `17 §3.8` F8.4 | Kürzer → Ruf fällt bei kurzer Sendepause. Länger → Zeitschlitz bleibt nach Geräteverlust blockiert. Gehört `10` (dort `10` O-10-8) |
| Burst-Rate je Sprachkanal | 16,67/s (Rechnung, [ANNAHME]); **~19/s** UL-erfasst inkl. Fehl-Syncs (gemessen) | §3.1.2; [MESS 2026-05-17] | Deutlich höhere Rate = Korrelator-Fehlalarme (Schwelle prüfen, `03` §4). Die DL-Senderate (`voice_dl_emit_cnt`, 16–18/s) folgt dagegen direkt aus den 17 Verkehrsframes und darf **nicht** über 18/s liegen |
| BFI, Soft-Pfad, Nahfeld | **0 %** (2/840 Bursts) | [MESS 2026-05-25] | Referenzpunkt für R-12-08 |
| BFI, Hard-Pfad, Nahfeld | 1 % (11/840) | [MESS 2026-05-25] | Soft muss ≤ Hard bleiben (R-12-08) |
| BFI auf 50 m | 5–6 % | [MESS 2026-05-30] | Obergrenze R-12-08 ist 10 % |
| BFI vor Korrektur der Abtastpositionen | 98 % | [MESS 2026-05-17] | Historischer Referenzpunkt: so sieht ein Geometriefehler aus (§3.5.3) |
| Roh-BER (per-Burst `type-5 XOR neu codiert`) | avg **1,4 %**, worst 9,5 % | [MESS 2026-05-25] | > 5 % → BFI bricht ein (Kennlinie §3.5.2) |
| Tagesvariabilität Roh-BER | 1,4–3,5 % | [MESS 2026-05-18] | Erzwingt A/B im selben Capture (R-12-09) |
| Mittlerer Soft-Betrag im **ungenormten 4-bit-NUB-Pfad** (V1) | ~6,5 (nah), ~7,1 (50 m) bei Wertebereich 0…8 = praktisch volle Sättigung | [MESS 2026-05-30], Einordnung `03` §3.6.6 | **Kein Referenzwert für V2** — der Pfad graduiert dort nicht mehr und belegt deshalb keine Pegelunabhängigkeit |
| Arbeitspunkt Soft-Betrag V2 (8-bit-Ausgang, beide UL-Pfade) | `\|soft\| ≈ 16…32` | [ANNAHME] Rechnung aus `NORM_TGT = 5`, `03` §5.5 Punkt 4 — für V2 nicht gemessen | Systematische Verschiebung mit dem Pegel = Normierung wirkt nicht (R-03-06); Werte in der Sättigung = Auflösung verschenkt |
| BFI-Kennlinie über Bitfehler | Tabelle §3.5.2 | [SIM 2026-07-25] | An einem Luftpunkt kalibriert (Roh-BER 1,4 % → BFI 0 %) |
| Codec-Laufzeit, eigene Kette | decode 6,94 µs / encode 2,38 µs (Host) | [SIM 2026-07-25] | Grundlage R-12-16; Zielprozessor-Messung offen (O-12-3) |
| Codec-Laufzeit, ETSI-Referenz | decode 75,4 µs (Host) | [SIM 2026-07-25] | Faktor 10,8 — Begründung der Entscheidung §3.3 |
| Bit-Identität eigene Kette ↔ ETSI-Referenz | 0 abweichende Bits über 200 Rahmen (Codierung und Decodierung) | [SIM 2026-07-25] | Voraussetzung von §3.3; bricht sie, ist die eigene Kette nicht mehr abgenommen |
| Prüffeld eigene Kette ↔ Referenztabellen | 0 Abweichungen über 2 000 Vektoren | [SIM 2026-07-25] | dito |
| Gold: Verkehrskanal-Burst-Typ | NDB1 (NTS1) auf TS2, Verkehrs-AACH; 167 Bursts | [GOLD `docs/reference_decode/dl_events.jsonl`] | NDB2 (NTS2) auf einem Vollschlitz-Sprachkanal wäre ein Strukturfehler (§3.1.1) |
| Lokale Zelle, gleiche Auswertung | NDB1 auf TS2, 18 Bursts | [MESS 2026-05-25 (Dateistand), `docs/local_cell_decode/dl_events.jsonl`] | Strukturell gold-konform |
| Ressourcen der V1-Sprach-Mailboxen | Empfang 482 LUT / 1 729 FF; Senden 1 672 LUT / 2 244 FF | [BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt`] | Der Empfangspuffer hält dieselben 1 728 bit ein zweites Mal, die die Erfassung schon hält (`03` §3.6.3) |

---

## 5. Verifikation

### 5.1 Einheitentests, Host

| Test | Kriterium |
|---|---|
| Rundlauf der Sprachkette | 1 000 Zufallsrahmen à 274 bit: `encode` → `decode_soft` mit Vollmagnitude → Prüffeld ok **und** 274 Bits bit-identisch |
| Klassen-Umsortierung | `codec_to_channel` → `channel_to_codec` ist die Identität über 1 000 Rahmen. Zusätzlich: Position `2i` stammt aus Rahmen 1, Position `2i+1` aus Rahmen 2 (§3.2.2) — direkt geprüft, nicht nur über den Rundlauf |
| Prüffeld | Über 2 000 Zufallsvektoren identisch zu den Referenztabellen `TAB_CRC1…8` (§3.3) |
| Vorzeichen-Anpassung | Ein Burst in K1 mit bekanntem Inhalt: nach `tetra_voice_fetch()` gilt für jeden Index `soft_k3 = −soft_k1`, und `−128` wird zu `+127` |
| Bit-Packung Sende-Mailbox | Für alle 432 Positionen: `type5[i]` landet auf der Bitposition, die sich aus §3.4.6 (`coded[431 − i] = type5[i]`) und der normativen Wortabbildung in `07 §3.3` ergibt — also `type5[0]` in `W0[31]`. Prüfung gegen eine unabhängig geschriebene Referenzabbildung, nicht gegen die Implementierung selbst |
| Bad-Frame-Behandlung | Ein Burst mit absichtlich verletztem Prüffeld führt zu genau einem `voice_bfi_cnt++` und zu einem Sende-Burst, dessen Prüffeld beim Rückdecodieren ebenfalls verletzt ist (R-12-07) |
| Kein Heap | Der Sprachpfad läuft 100 000 Bursts ohne Zuwachs der Heap-Belegung (R-12-17) |

### 5.2 Vergleich gegen die ETSI-Referenzimplementierung (Orakel)

Verbindlicher Regressionstest, weil die eigene Kette die Referenz **ersetzt** (§3.3):

Über ≥ 1 000 Zufallsrahmen muss gelten: `tetra_cc_tchs_encode()` liefert dieselben 432 Bits
wie die Referenz-Kette, und `tetra_cc_tchs_decode_soft()` dieselben 274 Bits. Toleranz:
**null Bits**. Der Test läuft auf dem Host, nicht auf dem Ziel, und ist Vorbedingung für jede
Änderung an der Sprachkette. Aufbau und Ort in `14_VERIFICATION.md`; die Referenzquellen
liegen dort, nicht im Produktionsbild.

### 5.3 Vergleich gegen die Gold-Aufzeichnung

Strukturell, nicht bit-identisch (`CONVENTIONS.md` §3):

1. Der Verkehrskanal-Burst der eigenen Zelle ist **NDB1** (NTS1) auf einem Verkehrs-
   zeitschlitz, in den Frames 1…17, mit einem Verkehrs-Nutzungsmarker im
   Zugriffszuweisungskanal — genau wie im Bezugsnetz (§3.1.3).
2. Der Nutzungsmarker ist über den ganzen Ruf **konstant**, einschließlich Sprecherwechsel
   [GOLD], [MESS 2026-05-25].
3. Der Sprachburst enthält **keine** decodierbare MAC-PDU. Ein Decodierlauf des eigenen
   Downlink-Verkehrsschlitzes als SCH/F muss fehlschlagen — schlägt er nicht fehl, wird auf
   dem Verkehrsschlitz Signalisierung statt Sprache gesendet (das war der V1-Zustand mit der
   nicht mehr aufgerufenen Leer-PDU, §3.4.7).

### 5.4 Luft-Abnahme

**Verfahren, verbindlich** (`feedback`: PTT-Tests immer ≥ 3 Wiederholungen):

1. Zwei Endgeräte, gleiche Gruppe. PTT-Lauf 10 s, **3 Wiederholungen**.
2. Je Lauf protokollieren: `voice_ul_capture_cnt`, `voice_fetch_cnt`, `voice_bfi_cnt`,
   `voice_dl_emit_cnt[ts]`, `voice_fec_diff_sum/_max`, `voice_soft_mag_avg`,
   `mb_overrun_cnt`, `voice_mb_torn_cnt`.
3. **Kriterien:** BFI ≤ 5 % (R-12-08); `mb_overrun_cnt = 0`; `voice_mb_torn_cnt = 0`;
   `voice_dl_emit_cnt` steigt um **16–18 je Sekunde** Sprechzeit — dieses Band folgt aus den
   17 Verkehrsframes je Multiframe und ist **nicht** mit der UL-Erfassungsrate (~19/s inkl.
   Fehl-Syncs, §3.1.2) zu verwechseln; `voice_ul_capture_cnt` darf im Band 16–19/s liegen.
   Audio am hörenden Gerät durchgängig verständlich (Hörurteil, dokumentiert).
4. **Entfernungslauf 50 m**, 3 Wiederholungen: BFI ≤ 10 %, und `voice_soft_mag_avg` weicht um
   ≤ 20 % vom Nahfeldwert **derselben Sitzung** ab (Nachweis der Pegelunabhängigkeit,
   R-03-06). Bezugspunkt ist der V2-Arbeitspunkt `|soft| ≈ 16…32` am 8-bit-Ausgang
   (`03` §5.5 Punkt 4, [ANNAHME]) — **nicht** die V1-Werte ~6,5/~7,1, die aus dem ungenormten
   4-bit-Pfad stammen und dort in der Sättigung liegen (§4).
5. **Mehrgruppen-Lauf:** zwei Rufe auf zwei Zeitschlitzen. Beim Loslassen von PTT auf einem
   Zeitschlitz muss innerhalb von 300–400 ms genau **dieses** Bit der Aktivmaske fallen, das
   andere stehen bleiben, und das Audio der anderen Gruppe unterbrechungsfrei weiterlaufen
   (R-12-10, §3.6.1).
6. **A/B-Regel:** Jeder Vergleich (Soft gegen Hard, Normierung ein/aus, Schwellenwert) läuft
   in derselben Sitzung. Ein Vergleich gegen eine Zahl aus einer früheren Sitzung ist
   ungültig (R-12-09).

### 5.5 Negativtests

| Test | Erwartung |
|---|---|
| Sprachburst auf einem Zeitschlitz ohne aktiven Ruf einspeisen | verworfen, `voice_no_call_cnt++`, keine Sendeaktivität |
| Zwei Bursts schneller als die Abholung | Beide werden abgeholt (Ping-Pong), kein Verlust, `mb_overrun_cnt` unverändert |
| Drei Bursts ohne Abholung (beide Bänke ungelesen) | Der **dritte** wird verworfen, `mb_overrun_cnt++`, die zwei gepufferten bleiben gültig und lesbar (R-12-12) |
| Folgenummer während des Lesens künstlich verändert (Testbench) | Datensatz verworfen, nicht quittiert, `voice_mb_torn_cnt++` (R-12-13, §3.4.2); im spezifikationskonformen PL bleibt der Zähler 0 |
| Ruf aktiv, Uplink abgeschaltet | nach 300 ms Aktivbit und Ablage **dieses** Zeitschlitzes gelöscht; nach 5 s Ruf freigegeben |
| Frame 18 | kein Sprachburst auf dem Verkehrsschlitz (R-12-14) |
| Startwert 0 in der Konfiguration | `0xFFFFFFFF` verwendet, `seed_degenerate++`, Kette bleibt lauffähig |

---

## 6. Offene Punkte

**O-12-1 — Die Sprachkanal-Codierung ist gegen die Referenz*implementierung* verifiziert,
nicht gegen den Normtext.** §3.3 zeigt Bit-Identität zwischen der eigenen Kette und den
ETSI-Referenzquellen über 200 Rahmen, und das Prüffeld zusätzlich gegen die Referenztabellen
über 2 000 Vektoren [SIM 2026-07-25]. Der Normtext EN 300 395-2 lag nicht als Text vor
(`05` O-05-3). Referenzimplementierung und Norm sind nicht dasselbe Orakel.
*Empfehlung:* EN 300 395-2 §5.4/§5.5/§5.6 beschaffen und die Parametertabelle in `05` §3.8.6
sowie die Klassentabellen aus §3.2.1 zeilenweise abgleichen. Bis dahin gilt: Werte übernehmen,
**nicht** „aufräumen". Der Umkehrschluss ist bereits belegt — die tote Zweitvariante der
Klassen-Umsortierung war falsch (§3.2.2), also ist plausibles Aussehen kein Argument.

**O-12-2 — Behandlung eines Bad Frames im Downlink ist entschieden, aber nicht gemessen.**
R-12-07 verlangt, die Fehlermarkierung zum Endgerät zu propagieren; §3.5.4 setzt das über eine
Invertierung im Klasse-2-Prüffeld um [ANNAHME]. Die Alternative — Halteplatz unverändert lassen,
also den letzten guten Rahmen wiederholen — ist ebenfalls plausibel und in V1 als
Nebenwirkung des Wiederholungsverhaltens ohnehin vorhanden (§3.4.6).
*Empfehlung:* Beide Varianten im Air-Test als Hörvergleich gegeneinander messen, bei
künstlich erhöhter BFI-Rate (Korrelator-Schwelle absenken erzeugt genau das, `03` §4). Bis zur
Messung R-12-07 als Vorgabe umsetzen; sie ist die einzige der beiden, die die ETSI-Fehlerlogik
des Endgeräts nicht aushebelt.

**O-12-3 — Rechenlast auf dem Zielprozessor ist nicht gemessen.** §3.9 beruht auf einer
Host-Messung und dem Skalierungsfaktor 10–12 aus `05` §3.10 [ANNAHME]. Die berechnete Reserve
ist groß (0,6 % eines Kerns bei drei Sprachkanälen), aber „groß" ist kein Messwert.
*Empfehlung:* Beim Bring-up Zeitmessung um `tetra_voice_fetch()`, die beiden Codec-Aufrufe und
den Ablage-Schreibvorgang, Perzentile 50/99 über 60 s Sprechzeit, Eintrag als `[MESS]` in
`08_TIMING.md`. Zusammen mit `05` O-05-1 in einem Durchlauf erledigen.

**O-12-4 — Amplituden-Normierung im Sprachburst-Pfad fehlt.** R-03-06 fordert sie für beide
Uplink-Pfade; V1 hat sie nur im Steuerburst-Pfad, der Sprachpfad nutzt einen festen Shift
[CODE rtl/rx/tetra_ul_nub_capture.v:77-78]. Die Pegelunabhängigkeit über den ganzen
Amplitudenbereich ist **simulativ** belegt ([SIM 2026-05-30] Amplituden-Sweep); an der Luft
belegt ist für den Steuerburst-Pfad nur „3/3 PTT sauber, TS2-Anker bit-identisch"
[MESS 2026-05-30]. Im Sprachpfad ist die Normierung **nicht** umgesetzt und ihre Wirkung dort
**nicht** gemessen.
*Empfehlung:* Umsetzen (der Normierer existiert), dann Entfernungslauf nach §5.4 Punkt 4 vor
und nach dem Eingriff im selben Capture. Führung des Punktes liegt bei `03` O-03-1; hier steht er,
weil die BFI-Rate über Entfernung das Abnahmekriterium ist, an dem er sichtbar wird.

**O-12-5 — Halbschlitz-Sprachcodierung.** R-12-18 verbietet das Stehlen auf Sprachschlitzen,
solange die Halbschlitz-Betriebsart (§3.7.1) fehlt. Ob Stufe 1 sie braucht, entscheidet `10`
anhand des Bedarfs an schneller Signalisierung im laufenden Ruf.
*Empfehlung:* Nicht spekulativ bauen. Wenn `10` den Bedarf feststellt, ist der Aufwand
begrenzt und bekannt: ein zweiter Parametersatz (137 statt 274 Eingangsbits, Prüffeld 4 statt
8 bit, Punktierung 8/17, Interleaver (216, 101), nur Block 2) an derselben Modulschnittstelle
aus §3.2.3 — die Referenzquellen zeigen die Struktur [CODE sw/etsi_codec/ccod_tet.c:60-95].
Voraussetzung ist zusätzlich ein NTS2-Zweig im Uplink-Korrelator (`06` §3.3.2), sonst bleibt
das Stehlen einseitig.

**O-12-6 — Verhalten bei mehr als drei gleichzeitigen Sprachkanälen ist nicht spezifiziert.**
Drei Verkehrszeitschlitze (TS2…TS4) sind das physikalische Maximum eines Trägers, weil TS1 den
Steuerkanal trägt. Der Sprachpfad selbst ist zahlenunabhängig; die Ablehnung eines vierten
Rufs gehört zu `10`. Offen ist, ob die Zuweisung eines Rufs auf **TS1** je zulässig sein soll
(V1 lässt es strukturell zu: die Sende-Ablage hat vier Plätze, und der Sprachpfad akzeptiert
Zeitschlitz 1…4 [CODE sw/tetra_voice_pipe.c:304, CODE sw/tetra_voice_filler.c:155]).
*Empfehlung:* Nein — Verkehr auf dem Steuerzeitschlitz kostet die Zugriffs- und
Broadcast-Kapazität der Zelle. Der Sprachpfad prüft `ziel_ts ∈ {2,3,4}` und verwirft sonst mit
Zähler; die Begründung gehört als Zuweisungsregel nach `10`.
