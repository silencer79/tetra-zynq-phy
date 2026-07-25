# V2-Spec — Schreib-Konventionen (verbindlich für alle Autoren)

**Zweck:** Diese Datei steuert das Schreiben aller `docs/spec_v2/*`-Kapitel.
Sie ist **kein** Spec-Kapitel und beschreibt kein Produktverhalten.

---

## 1. Was die V2-Spec ist

Eine **implementierungsreife SOLL-Spezifikation** für einen vollständigen
Neuaufbau des TETRA-BS-Stacks (RTL + ARM-SW + Tooling) auf LibreSDR /
Zynq-7020 + AD9361/AD9363.

**Zielbild:** Ein Entwickler (oder Agent) ohne Kenntnis von V1 kann aus diesen
Dokumenten das System neu bauen und erreicht dabei mindestens den heute
air-verifizierten Funktionsumfang.

### Was die Spec NICHT ist

- **Keine IST-Doku.** `docs/ist/*` beschreibt V1 („was der Code tut"). Die V2-Spec
  beschreibt, was V2 tun **soll**. V1 ist Wissensquelle, nicht Vorbild.
- **Keine Historie.** Keine Phasen-Tags (`Phase X.4`, `Y.1.b`), keine
  Commit-Chroniken, keine „früher war das anders"-Absätze. Ausnahme: Kapitel
  `17_LESSONS_LEARNED.md`, dort ist Historie der Inhalt.
- **Keine Migrations-Anleitung.** V2 wird neu gebaut, nicht migriert.
- **Kein Plan-Dokument.** Keine Aufwandsschätzungen, keine Zeitpläne.

### Der zentrale Mehrwert gegenüber V1

V1 ist über viele Iterationen von mehreren Modellen gewachsen. Daraus folgen die
drei Aufgaben jedes Kapitels:

1. **Erhalten**, was air-verifiziert funktioniert — inklusive der empirisch
   gefundenen Zahlenwerte, die niemand aus der Theorie herleiten kann.
2. **Bereinigen**, was als Drift/Duplikat/Altlast erkennbar ist — mit
   ausgeschriebener Begründung, nicht stillschweigend.
3. **Festlegen**, was in V1 unterspezifiziert war und darum mehrfach neu
   erfunden wurde (Naming, Bit-Order, Register-Semantik, Fehlerverhalten).

---

## 2. Dokumenten-Satz (verbindliche Struktur)

| Datei | Inhalt | Autor |
|---|---|---|
| `00_OVERVIEW.md` | Zielbild, Scope, Prinzipien, Architektur-Cut, Leseführung, Glossar | Hauptautor |
| `01_PLATFORM.md` | Zynq-7020, AD9361/AD9363, LibreSDR, Clock-/Reset-Architektur, Ressourcen-Budget, Board-Bring-up | WF1 |
| `02_PHY_DL_RX.md` | DL-RX-PHY: Dezimation, RRC, Demod, Timing-Recovery, Sync, Burst-Demux | WF1 |
| `03_PHY_UL_RX.md` | UL-RX-PHY: UL-Sync, Burst-Capture, Soft-Demod, NUB-Capture, Amplituden-Normierung | WF1 |
| `04_PHY_TX_TDMA.md` | TX-PHY: Modulator, RRC, Interpolation, Burst-Aufbau, TDMA-Zeitbasis, Slot-Scheduling | WF1 |
| `05_CHANNEL_CODING.md` | CRC, RCPC, Punktierung, Interleaving, Scrambling, RM(30,14), Viterbi, alle Kanal-Encoder/Decoder | WF2 |
| `06_MAC.md` | Burst-Typen, logische Kanäle, MAC-PDUs, LI, Stealing, Reservierung, AACH-Semantik | WF2 |
| `07_PS_PL_CONTRACT.md` | **Der PS↔PL-Vertrag:** Register-Map, Mailbox-Protokolle, CDC-Regeln, IRQ | WF2 |
| `08_TIMING.md` | TDMA-Timing, Slot-Deadlines, Reply-Fenster, DL→UL-Air-Lock, gemessene Latenzen | WF2 |
| `09_LLC_MLE_MM.md` | LLC-PDUs, NS/NR, FCS; MLE-Routing; MM: Attach, Group-Attach, Gruppenwechsel | WF3 |
| `10_CMCE_CALL.md` | Call-Control: Gruppenruf, Einzelruf, Multi-TS/Multi-Group, Late Entry | WF3 |
| `11_SDS.md` | Kurze SDS, Status-SDS, lange SDS (Multi-Fragment DL+UL), Reassembly, Quittung | WF3 |
| `12_VOICE.md` | TCH/S, ACELP-Codec, Voice-Relay-Kette, BFI, Quiet-Detection | WF3 |
| `13_SW_ARCHITECTURE.md` | Prozess-/Thread-Modell, Mainloop, Konfiguration, Subscriber-DB, WebUI | WF4 |
| `14_VERIFICATION.md` | Verifikations-Strategie: Unit-TB, Testvektoren, Gold-Vergleich, Air-Test-Protokolle, Akzeptanzkriterien | WF4 |
| `15_BUILD_DEPLOY.md` | Vivado-Flow, Cross-Compile, Deploy-Pipeline, Autostart, Bring-up-Reihenfolge | WF4 |
| `17_LESSONS_LEARNED.md` | Bug-Katalog V1: Root-Cause + verbindliche V2-Vermeidungsregel | WF4 |
| `18_ROADMAP.md` | Spezifizierte, aber nicht in Stufe 1 gebaute Features | WF4 |

Der normative Satz ist mit diesen 18 Kapiteln **vollständig**. Es gibt **kein**
Nachschlage-Kapitel für Werte: Bit-Layouts, Konstanten und Gold-Messwerte stehen
jeweils in dem Fachkapitel, das sie normativ festlegt (P2 — eine Wahrheit, ein
Ort), und Registeradressen ausschließlich in `07_PS_PL_CONTRACT.md`. Ein Verweis
auf eine zentrale Konstantensammlung ist ein Spec-Fehler; verwiesen wird auf die
Fachstelle. Die maschinenlesbare Erzeugung von HDL-Headern, HAL-Headern und
Testvektortabellen speist sich aus **diesen** Stellen (`15_BUILD_DEPLOY.md`).

Dazu tritt **eine** Datei, die nichts normiert:

| Datei | Inhalt | Autor |
|---|---|---|
| `99_REFERENCE.md` | **Reine Verzeichnisse, keine Definitionen:** ETSI-Fundstellen mit Thema und nutzenden Kapiteln, sowie die Kennungszahlen je Kapitel | Hauptautor |

Für `99` gilt die Sonderregel: Es enthält ausschließlich **Metadaten über den
Satz** — welche Norm-Fundstelle wo benutzt wird, wie viele Kennungen ein Kapitel
führt. Beides kann inhaltlich nicht widersprechen. Sobald dort ein Wert,
ein Bit-Layout oder eine Adresse auftaucht, ist das ein Spec-Verstoß. Beide
Verzeichnisse werden bei Änderungen **neu erhoben**, nicht von Hand
fortgeschrieben.

Jedes Kapitel ist **eigenständig lesbar**: wer nur DL-RX baut, braucht `01`,
`02`, `05`, `07`, `08` — nicht die Protokoll-Kapitel.

---

## 3. Evidenz-Kennzeichnung (harte Pflicht)

Jede Zahl, jedes Bit-Layout, jeder Schwellwert trägt genau eine Herkunft.
Verwende diese Marker **inline**:

| Marker | Bedeutung | Belegform |
|---|---|---|
| `[ETSI §x.y]` | Aus ETSI EN 300 392-2 (bzw. genannter Teil) abgeleitet | Paragraf-/Tabellennummer |
| `[CODE file:line]` | Aus dem V1-Quellcode gelesen | Pfad + Zeile |
| `[GOLD]` | Aus den Gold-Aufzeichnungen gemessen (`docs/reference_decode/`) | Burst-Nr./Datei |
| `[MESS datum]` | Auf echter Hardware gemessen (Air-Test, AXI-Counter, Log) | Datum + Messgröße |
| `[BUILD datum]` | Aus einer Vivado-Tool-Ausgabe gelesen (Utilization-, Timing-, CDC-, Clock-Report) — **keine** Hardware-Messung | Datum + Reportdatei + Abschnitt/Zeile |
| `[SIM datum]` | Aus einem Simulationslauf (xsim/Testbench) oder aus dem Verhalten der Simulations-Werkzeuge gelesen — **keine** Hardware-Messung | Datum + Testbench/Skript + Messgröße |
| `[ANNAHME]` | Nicht belegt — bewusste Festlegung für V2 | + einzeilige Begründung |

**Regeln:**

- **Theorie ist niemals ein Messwert.** Ein Wert, den du berechnet oder
  geschätzt hast, ist `[ANNAHME]` — auch wenn die Rechnung stimmt. Ein
  gemessener Wert ist `[MESS]` oder `[GOLD]`. Nie vermischen, nie
  „ca."-Werte als gemessen ausgeben. Tool-Ausgaben (Vivado-Reports) sind
  `[BUILD]`, Simulationsergebnisse und Simulator-Verhalten sind `[SIM]` — beides
  **nicht** `[MESS]`; Datenblatt-Konstanten (Device-Kapazitäten) werden
  als solche benannt.
- **Der Code ist die Quelle, nicht die Doku.** `docs/ist/*` und
  `docs/ARCHITECTURE.md` sind **gedriftet** — nachgewiesen: `hal.h` definiert
  `REG_SLOT_AACH_TS1..4 @ 0x2A0..0x2AC`, die Regmap-Doku `docs/ist/08` kennt
  sie nicht. Nutze die Doku als Landkarte, belege aber gegen
  `rtl/`, `sw/`, `scripts/`. Wo Doku und Code sich widersprechen: Code gewinnt,
  und der Widerspruch gehört als Zeile nach `17_LESSONS_LEARNED.md`.
- **Empirische Werte sind heilig.** Schwellwerte wie NUB-Sync-Threshold,
  CIC-Gain-Shift, UL-RA-Threshold, Quiet-Timeouts wurden durch Messreihen
  gefunden und sind nicht herleitbar. Übernimm sie mit Wert, Messkontext und
  dem, was bei Nachbarwerten passierte. Ein Wert ohne diese Begleitung
  wird beim nächsten Refactor „optimiert" und bricht das System.
- **Gold-Match heißt funktional äquivalent, nicht bit-identisch.** Die
  Gold-Aufzeichnung ist die 1-MS-Sicht eines fremden Netzes mit anderen
  Cell-Parametern. Zell-/MS-spezifische Felder (SSI, GSSI, Carrier, MCC/MNC,
  CC, LA, Scrambler, Call-Identifier) dürfen und müssen abweichen. Fordere
  Bit-Identität nur für strukturelle Felder.

---

## 4. Namens- und Darstellungs-Konventionen

### Zeitschlitz-Nummerierung (häufigste Fehlerquelle in V1)

- **Spec-Text, SW-Code, Logs, WebUI:** ETSI-Zählung **1-basiert** — `TS1..TS4`.
- **RTL-Signale:** 0-basiert — `tn`/`_tn` mit Wertebereich `0..3`.
- **Jede** Umrechnung wird an der Stelle benannt: `TS2 (ETSI) = tn=1 (RTL)`.
- Ein zentrales Mapping-Modul ist verbindlich; Ad-hoc-`±1` im Code ist verboten.

### RTL

- Verilog-2001. Modul-Prefix `tetra_`, Dateiname == Modulname.
- `snake_case` Signale, `UPPER_CASE` Parameter.
- Clock-Domain als Suffix: `_sys`, `_axi`, `_lvds`, `_sample`.
- Ein `always`-Block pro Register. FSM: State-Register und Next-State getrennt.
- Reset active-low, synchron deasserted über 2-FF-Synchronizer.
- Keine Speicher-Arrays in Synthesecode außer bewusst inferiertem BRAM — dann
  mit explizitem Kommentar, welcher Primitivtyp erwartet wird.
- Neue Blöcke mit Pipeline-Registern und dokumentierter Stufenzahl.

### SW

- C, `snake_case`, Modul-Prefix `tetra_`.
- Jedes Modul mit `.h`-Vertrag: Zweck, Aufrufkontext, Fehlerverhalten.
- Kein Zugriff auf AXI-Register außerhalb der HAL-Schicht.

### Bit-Order (in V1 wiederholt falsch)

Bei **jedem** Bit-Feld, Bus und Mailbox-Wort explizit angeben:

- MSB-first oder LSB-first,
- Bit-Nummerierung des Referenzdokuments (ETSI zählt ab 1),
- bei Mailboxen: welches Bit in welchem Wort an welcher Position.

„Wie üblich" oder „analog zum Nachbarmodul" ist keine Angabe.

### Register-Definitionen

Der PS↔PL-Vertrag (`07`) ist **die** Quelle für Adressen. Andere Kapitel
verweisen mit Registernamen, wiederholen keine Adressen. So kann eine
Adress-Änderung nicht an fünf Stellen auseinanderlaufen.

---

## 5. Kapitelaufbau (einheitlich)

```markdown
# NN — Titel

**Scope:** Ein Satz — was drin ist.
**Nicht hier:** Verweise auf die zuständigen Kapitel.
**Abhängigkeiten:** Kapitel, die man vorher gelesen haben muss.

## 1. Anforderungen
Nummeriert und prüfbar: R-NN-01, R-NN-02 …
Jede Anforderung testbar formuliert. Kein "sollte möglichst".

## 2. Architektur / Aufbau
Blockstruktur, Datenfluss, Schnittstellen nach außen.

## 3. Detail-Spezifikation
Pro Modul/Funktion: Zweck, Schnittstelle (Ports/Signatur mit Breite und
Richtung), Verhalten, Bit-Layouts, Timing, Ressourcen-Erwartung,
Fehler-/Randfallverhalten.

## 4. Empirische Werte
Tabelle: Parameter | Wert | Herkunft | Was bei Abweichung passiert.

## 5. Verifikation
Wie wird dieses Kapitel abgenommen: Unit-Tests, Testvektoren,
Gold-Vergleich, Air-Test-Kriterium.
Jeder Verifikationspunkt trägt eine Kennung: V-NN-1, V-NN-2 …

## 6. Offene Punkte
Was in V1 unklar war und in V2 entschieden werden muss — mit Empfehlung.
Jeder offene Punkt trägt eine Kennung: O-NN-1, O-NN-2 …
```

### Stabile Kennungen für §5 und §6 (verbindlich)

Anforderungen tragen `R-NN-01`. Dieselbe Pflicht gilt für die beiden anderen
Listen, weil andere Kapitel sie zitieren:

- **Offene Punkte (§6):** `O-NN-n`, `NN` = zweistellige Kapitelnummer, `n`
  einstellig aufsteigend und **nicht** nullgefüllt (`O-04-5`, nicht `O-04-05`).
- **Verifikationspunkte (§5):** `V-NN-n`, gleiche Schreibweise. Verbindlich mindestens für
  jeden Punkt, den ein anderes Kapitel zitiert; im Bestand durchnummeriert sind `01`, `02`,
  `03 §5.1`, `06 §5.1`, `13`, `15`, `17`.
- Kapitel `00` führt seine offenen Punkte in §9; die Kennung ist trotzdem
  `O-00-n`.

**Verboten sind** die kapitellose Kurzform `O-n` (sie kollidiert global: `O-3`
gäbe es dann in mehreren Kapiteln für verschiedene Sachverhalte) und Verweise
auf Unterabschnitte, die es nicht gibt — es existiert **kein** `### 6.x`.
Ein Fremdverweis lautet `` `04` O-04-5 ``, nie `` `04 §6.5` ``.

---

## 6. Absolute Verbote

1. **Keine erfundenen Fakten.** Kein Modulname, keine Registeradresse, kein
   Bit-Layout, keine Zeilennummer ohne Verifikation gegen die echte Datei. Bei
   Unsicherheit: `[ANNAHME]` schreiben. Ein falscher Beleg ist schlimmer als
   ein fehlender.
2. **Keine Erwähnung der Crypto-Rekey-PDU** (die mit vier Buchstaben,
   Schlüsselverteilung über die Luft). Weder Name noch Abkürzung noch
   Umschreibung, in keinem Kapitel. Wo sie in Aufzeichnungen auftaucht:
   überspringen, nicht kommentieren.
3. **Keine In-Circuit-Debug-Instrumentierung** als Verifikations-Methode
   vorschlagen (Logic-Analyzer-Cores im FPGA). Verifikation läuft über
   Simulation, AXI-Zähler, Logs und Luft-Captures.
4. **Kein Verlass auf Slice-Prozent** als Ressourcen-Grenze. Slice-Auslastung
   ist ein Packing-Artefakt. Verbindliche Metriken sind **LUT**, **FF**,
   **BRAM**, **DSP** und **WNS**.
5. **Keine Beschuldigung von Hardware, SDR oder Treibern** als Erklärung für
   Fehlverhalten. In V1 war die Ursache jedes Mal im eigenen Code.
6. **Keine leeren Steigerungen.** Nicht „robust", „state of the art",
   „optimiert" ohne messbares Kriterium.

---

## 7. Quellenlage

| Quelle | Pfad | Nutzung |
|---|---|---|
| V1-RTL | `rtl/**` (~25 500 Zeilen, 70 Module) | Primärquelle Hardware-Verhalten |
| V1-SW | `sw/**` (~16 800 Zeilen) | Primärquelle Protokoll-Verhalten |
| V1-Tooling | `scripts/**`, `board_autostart/**` | Build/Deploy/Decode |
| Testbenches | `tb/**`, `tb/vectors/**` | Bestehende Testvektoren + Abdeckung |
| IST-Doku | `docs/ist/00..13`, `docs/IST.md` | Landkarte — **gedriftet, nicht zitierfähig ohne Code-Beleg** |
| ETSI-Hauptspec | `en_30039202v030801p.pdf` (EN 300 392-2 v3.8.1) | Normative Referenz |
| Weitere ETSI | `docs/en_30039209v010701p.pdf`, `docs/etr_30001e01p.pdf` | Ergänzend |
| Gold-Aufzeichnung | `docs/reference_decode/` (`dl_full.md` ~174k Zeilen, `ul_full.md`, `action_reaction.md`, `*.jsonl`) | Referenz-Verhalten echter BS. **Gezielt greppen, nie komplett lesen** |
| Eigene Aufzeichnung | `docs/local_cell_decode/` (inkl. `BUGS_LIST.md`, `DIFF_vs_reference.md`) | V1-Ist-Verhalten + bekannte Abweichungen |
| Rust-Referenz-BS | `tetra-bluestation/crates/**` | Sekundäre Struktur-Referenz (PDU-Layouts). **Externes Submodul — nur lesen** |
| Decoder-Referenz | `tetra-kit/`, `osmo-debug-rx/` | Sekundär |

**Zur Gold-Aufzeichnung:** `docs/reference_decode/dl_full.md` hat ~174 000
Zeilen. Immer `grep`/`jq` mit gezieltem Muster, niemals ganz lesen. Die
JSONL-Dateien sind für Statistik der bessere Zugriff.

**Zu BlueStation:** externes Upstream-Submodul. Lesen ja, verändern nein, nie
ins Haupt-Repo committen. Achtung bei V1-Doku: einzelne Stellen in
`docs/local_cell_decode/` benennen fälschlich BlueStation-Rust-Dateien als
Fix-Ort für Fehler **unserer** BS. Das ist ein Doku-Fehler, kein Hinweis.

---

## 8. Sprache

Deutsch. Technische Begriffe, Signalnamen, Registernamen, PDU-Namen und
Code-Identifier bleiben im Original. Vollständige Orthographie inklusive
Umlauten und ß — keine ASCII-Ersatzschreibung.
