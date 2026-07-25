# 14 — Verifikation und Abnahme

**Scope:** Die vollständige Verifikationsstrategie für V2: Prüfstufen von der
Einzelfunktion bis zum Luft-Test, Erzeugung und Unabhängigkeit von Testvektoren, das
Verfahren des Vergleichs mit der Referenz-Aufzeichnung, Regressionsverfahren,
Mess-Protokolle an echter Hardware und die zusammengeführte Abnahme-Matrix für Stufe 1.
**Nicht hier:** Fachinhalte — die stehen in `01`…`13` und werden hier nur mit
Kapitel- und Abschnittsverweis zitiert. Build- und Deploy-Vorgang: `15_BUILD_DEPLOY.md`.
Bug-Historie und Vermeidungsregeln: `17_LESSONS_LEARNED.md`.
**Abhängigkeiten:** `00_OVERVIEW.md` (§3.4 Uplink-Zuweisung, §4 Prinzipien),
`CONVENTIONS.md` (§3 Evidenz, §6 Verbote). Für die Abnahme eines Teilsystems zusätzlich
dessen Fachkapitel.

---

## 1. Anforderungen

| ID | Anforderung |
|---|---|
| **R-14-01** | Jede Prüfstufe liefert ein **binäres** Urteil und beendet sich mit Exit-Code 0 (bestanden) oder ≠ 0 (nicht bestanden). Ein Sammel-Runner, der bei Fehlschlägen mit 0 endet, ist ein Spec-Verstoß. |
| **R-14-02** | Ein Testfall ohne explizites Urteil gilt als **nicht bestanden**. Es gibt keine Kategorie „durchgelaufen, kein Urteil". |
| **R-14-03** | Jede Testbench und jedes Host-Testprogramm ist selbstprüfend und gibt genau eine Ergebniszeile im Format aus §2.4 aus. |
| **R-14-04** | Kein Testvektor stammt aus der Implementierung, die er prüft (§3.4.2). Zulässige unabhängige Quellen: ETSI-Normtext (händisch nachgerechnet), Referenz-Aufzeichnung, eine zweite, unabhängig geschriebene Implementierung. |
| **R-14-05** | Jede Testdatei ist Teil des Sammelziels ihrer Stufe. Eine Testdatei ohne Ziel und ein Ziel ohne Datei sind beides Fehler der Stufe 0 (§3.1). |
| **R-14-06** | Testvektor-Erzeuger sind deterministisch (fester Startwert) und erzeugen bei gleicher Eingabe bit-identische Ausgabe. Der Vektorbestand wird durch ein **erzeugtes** Manifest beschrieben, nicht durch eine handgepflegte Tabelle. |
| **R-14-07** | Der Vergleich mit der Referenz-Aufzeichnung ist **funktional**: Bit-Identität wird nur für strukturelle Felder gefordert, zell- und gerätespezifische Felder dürfen und müssen abweichen. Die Zuordnung der Felder auf die zwei Kategorien ist in §3.6.1 normativ. |
| **R-14-08** | Der Vergleichs-Decoder führt **jeden** Bursttyp und **jeden** logischen Kanal durch **alle** Schichten (MAC → LLC → MLE → MM/CMCE/SDS). Der Nachweis dafür ist selbst zu erbringen (§3.6.4). |
| **R-14-09** | Ein Nullbefund in einer Aufzeichnung ist **kein** Beleg für Abwesenheit, solange der Abdeckungsnachweis nach R-14-08 für den betroffenen Pfad nicht vorliegt. Jede Abwesenheits-Aussage in der Spezifikation trägt den Abdeckungsbeleg mit. |
| **R-14-10** | Jeder Luft-Test läuft **mindestens dreimal**. Ein einzelner Lauf ist kein Nachweis. |
| **R-14-11** | Jede Bewertung einer Änderung erfolgt als Gegenüberstellung innerhalb **derselben** Messsitzung. Ein Vergleich gegen einen Wert aus einer früheren Sitzung ist unzulässig. |
| **R-14-12** | Die Zeitkopplungs-Messung (§3.10) läuft nach **jedem** Bitstream und ist Blocker. Das Kriterium liegt auf der Schrittweite zwischen den Zeitschlitzen, nicht auf den Absolutwerten. |
| **R-14-13** | Der Aufschaukelungs-Test (§3.9) ist in der Simulation zu bestehen, **bevor** die Zelle mit fremden Endgeräten auf Sendung geht, und auf der Luft zu bestätigen. |
| **R-14-14** | Jeder im Betrieb zählbare Fehlerfall (Verwurf, Prüfsummen-Verletzung, Mailbox-Überlauf, Fristverletzung) hat einen Zähler **und** ein Abnahmekriterium. Ein Zähler ohne Kriterium erfüllt P6 nicht. |
| **R-14-15** | Jedes Messergebnis trägt Datum, Bitstream-Kennung, Software-Kennung, Konfigurations-Kennung und Wiederholungsindex. Ein Ergebnis ohne archiviertes Rohlog ist kein Beleg. |
| **R-14-16** | Jede Suite der Stufen 1 und 2 muss in der Mutationsprobe (§5.1) mindestens einen injizierten Fehler je geprüfter Kernfunktion erkennen. Eine Suite, die alle Mutationen überlebt, prüft nichts. |
| **R-14-17** | In-Circuit-Debug-Kerne im FPGA sind als Verifikationsmethode **nicht zugelassen** (§3.12). |

---

## 2. Architektur / Aufbau

### 2.1 Sechs Stufen, streng gestaffelt

Jede Stufe ist Gate für die nächste. Wer eine Stufe überspringt, hat kein Ergebnis,
sondern eine Vermutung.

| Stufe | Gegenstand | Umgebung | Laufzeit-Ziel | Gate für |
|---|---|---|---|---|
| **S0** | Statische Prüfungen: Ein-Wahrheit-Gates, Namens- und Vollständigkeits-Gates, Tool-Reports | Host, kein Simulator | < 30 s | S1 |
| **S1** | RTL-Unit-Simulation je Modul | `iverilog`/`vvp`, ergänzend `xsim` | < 5 min gesamt | S3 |
| **S2** | Software-Unit-Tests | Host-`gcc`, Adress- und Undefined-Sanitizer | < 2 min gesamt | S3 |
| **S3** | Ketten- und Integrations-Simulation, inkl. Luftdaten als Stimulus | Simulator + Python-Referenz | < 30 min | S4 |
| **S4** | Vergleich mit der Referenz-Aufzeichnung (strukturell) | Host, Vergleichs-Decoder | < 10 min | S5 |
| **S5** | Board-Abnahme über Register, Zähler und Bring-up | echte Hardware, kein Funkverkehr nach außen | — | S6 |
| **S6** | Luft-Tests mit kommerziellen Endgeräten | echte Hardware + Endgeräte + Mitschnitt | — | Freigabe |

**Zwei Sonderfälle stehen quer zu dieser Staffelung**, weil sie das Systemverhalten und
nicht ein Modul prüfen:

- der **Aufschaukelungs-Test** (§3.9) — in S3 als Blocker, in S6 als Bestätigung;
- die **Zeitkopplungs-Messung** (§3.10) — in S5 nach jedem Bitstream, als
  Regressionsdetektor mit der höchsten Empfindlichkeit im ganzen System.

### 2.2 Werkzeugkette

| Werkzeug | Rolle | V1-Vorbild |
|---|---|---|
`tools/sim/run_units.py` | Sammel-Runner S1: kompiliert und simuliert jede Testbench, aggregiert Urteile, Exit-Code | `run_all_tests.sh`, `run_sims.py` — **beide ersetzt**, Begründung §3.2.1 |
`tools/sim/run_chain.py` | Sammel-Runner S3: Kettenläufe mit Vektor- und WAV-Stimulus | `tb_ul_wav_chain`-Aufrufe, heute nur manuell [CODE docs/OPERATIONS.md:157 (Prinzip: Kettenläufe werden explizit aufgerufen); `tb/tb_ul_wav_chain.v` hat in `run_all_tests.sh` und `run_sims.py` keinen Eintrag] |
`tools/vectors/gen_*.py` + `MANIFEST.json` | Vektorerzeugung, deterministisch, mit erzeugtem Manifest | `tb/vectors/gen_*.py`, `scripts/gen_*_tv.py` |
`sw/test/` + `make check` | Sammelziel S2 | `sw/Makefile` Ziel `test:` — deckt 11 von 17 vorhandenen Testprogrammen ab [CODE sw/Makefile:134] |
`tools/decode/decode_dl.py`, `decode_ul.py` | unabhängiger Vergleichs-Decoder, Grundlage für S3 und S4 | `scripts/decode_dl.py` (2 424 Z.), `scripts/decode_ul.py` (980 Z.) |
`tools/decode/coverage.py` | Abdeckungsnachweis des Vergleichs-Decoders (§3.6.4) | **existiert in V1 nicht** — die Lücke in §3.6.3 ist genau deshalb entstanden |
`tools/decode/compare_gold.py` | strukturvergleichender Abgleich gegen die Referenz, mit Feldkategorien aus §3.6.1 | `scripts/parse_reference_decode.py`, `scripts/decode_pdu.py` |
`tools/board/ctrl.py` | Registerzugriff, Zählerabzug als JSON | `scripts/tetra_ctrl.sh` (601 Z.), `.claude/commands/counters.md` |
`tools/air/session.py` | Messsitzung anlegen, Umgebung erfassen, Rohlogs archivieren (R-14-15) | **existiert in V1 nicht**; Sitzungsdaten lagen verstreut in `/tmp` |
`tools/air/ab.py` | A/B-Auswertung **innerhalb** einer Sitzung (R-14-11) | Verfahren in V1 gelebt, nicht als Werkzeug vorhanden |

**Nicht Bestandteil der Werkzeugkette:** `scripts/ila_capture.tcl` und
`scripts/analyze_ila.py` aus V1. Begründung §3.12.

### 2.3 Ergebnis-Ablage

```
results/
  <YYYY-MM-DD>_<sitzung>/          Messsitzung (S5/S6)
    env.json                       bitstream_sha256, sw_rev, config_sha256, MS-Typen, Ort
    run_<n>/                       je Wiederholung: Rohlog, Zählerabzug vor/nach, WAV-Mitschnitte
    verdict.json                   Kriterium → Messwert → Urteil
  sim/<gitrev>/                    S1..S4, maschinenlesbar
```

Regel: **Rohdaten werden nie überschrieben.** Eine Auswertung, die sich nicht aus dem
archivierten Rohlog nachrechnen lässt, ist keine Messung.

### 2.4 Einheitliches Ergebnisformat

Jede Testbench, jedes Host-Testprogramm und jedes Werkzeug gibt als **letzte** Zeile
genau aus:

```
RESULT: PASS  n_pass=<k> n_fail=0  case=<name>
RESULT: FAIL  n_pass=<k> n_fail=<m> case=<name> first_fail=<beschreibung>
```

Verilog-Testbenches beenden bei `n_fail > 0` zusätzlich mit `$fatal`, damit auch ein
Werkzeug ohne Textanalyse ein Urteil hat. Der Runner wertet **ausschließlich** diese Zeile
und den Exit-Code aus — keine Textsuche nach den Zeichenfolgen `FAIL` oder `ERROR` im
Gesamtlog.

**Warum das eine Anforderung und keine Formfrage ist.** In V1 entscheidet der Runner per
Textsuche: `grep -qi "FAIL\|\$error\|\$fatal\|ERROR\|FATAL"`, mit einer nachgeschalteten
Heuristik, die `FAIL=0` und `0 FAIL` wieder ausnimmt
[CODE run_all_tests.sh:69-84]. Die Folgen sind belegt:

- Eine Testbench ohne Urteilszeile zählt in `run_all_tests.sh` als **bestanden**
  („`SIM: COMPLETED (no PASS/FAIL marker)`", `PASS=$((PASS+1))`)
  [CODE run_all_tests.sh:89-96] — in `run_sims.py` dagegen als **Fehlschlag**
  [CODE run_sims.py:64-65 gegen :212-217]. Zwei Runner, gegensätzliches Urteil für
  denselben Zustand.
- 37 der 69 Testbenches in `tb/` geben überhaupt keine `RESULT:`-Zeile aus; nur 19 nutzen
  `$fatal` [CODE `grep -l` über `tb/*.v`, 2026-07-25].
- Die V1-Betriebsdoku führt einen Fehlschlag als kosmetisch: „TIMEOUT-`$error`-Meldungen im
  Log — **cosmetic**, alle 7 TCs bestehen" [CODE docs/OPERATIONS.md:206]. Ein Urteil, das
  händisch relativiert werden muss, ist kein Gate.
- Keiner der beiden Runner beendet sich mit einem Fehler-Exit-Code; beide drucken nur eine
  Summenzeile [CODE run_all_tests.sh:230]. Automatisieren lässt sich damit nichts.

---

## 3. Detail-Spezifikation

### 3.1 Stufe 0 — Statische Gates

Alle Prüfungen laufen ohne Simulator und ohne Hardware. Jede endet binär.

| Gate | Prüfung | Bestehens-Bedingung |
|---|---|---|
| **S0-1 Ein-Wahrheit Kanalcodierung** | `grep` über `rtl/` und `sw/` nach den Codier-Konstanten: Prüffeld-Polynom, die vier Generator-Masken, die Interleaver-Parameter `103/101/13/11`, die 14 Zeilen der RM-Matrix, die Verschleierungs-Taps | Jede Konstante existiert an **genau einer** Stelle. Zugelassene Ausnahme: der Broadcast-Synchronisations- und der Zugriffszuweisungs-Encoder in RTL dürfen Verschleierungs-Taps und RM-Zeilen tragen (`05 §5.4`) |
| **S0-2 Ein-Wahrheit Registeradressen** | Alle Adress- und Feldkonstanten werden aus **einer** Quelle erzeugt; `07` ist normativ | Kein handgeschriebenes Adress-Literal außerhalb des Generats. V1-Gegenbefund: `REG_SLOT_AACH_TS1..4` existieren in `sw/tetra_hal.h`, in der Regmap-Doku nicht (`CONVENTIONS §3`) |
| **S0-3 Testvollständigkeit** | Jede Datei `tb/**/tb_*.v` ist im Runner-Manifest; jede Datei `sw/test/test_*.c` im Ziel `check`; jeder Manifest-Eintrag hat eine Datei | Beide Richtungen leer. V1-Gegenbefund: 48 von 69 Testbenches sind in keinem Runner [CODE run_all_tests.sh gegen `ls tb/*.v`]; `run_all_tests.sh:218-220` und `run_sims.py:191-193` verweisen auf `tb_tetra_burst_mux.v` und `rtl/tx/tetra_burst_mux.v`, die **beide nicht existieren**; 4 von 17 Host-Testprogrammen haben überhaupt kein Makefile-Ziel (`test_bs_codec`, `test_mm_demand_parser`, `test_sds_dl_frag`, `test_soft_viterbi`) |
| **S0-4 Zähler-Vollständigkeit** | Jeder in `07` definierte Zähler erscheint in mindestens einem Abnahmekriterium dieses Kapitels; jedes Kriterium nennt einen existierenden Zähler | Beide Richtungen leer (R-14-14) |
| **S0-5 Zeitschlitz-Zählung** | Kein `± 1` auf einer Zeitschlitz-Variablen außerhalb des zentralen Umrechnungsmoduls (`00 §2.2`) | Kein Treffer |
| **S0-6 Bit-Order-Vollständigkeit** | Jedes in `07` beschriebene Mailbox-Wort hat eine explizite MSB/LSB-Angabe | Kein Feld ohne Angabe (P4) |
| **S0-7 Waisen-RTL** | Jedes Modul in `rtl/` ist erreichbar von der Top-Instanz; jede Datei der Build-Filelist existiert | Kein Waise, keine Lücke |
| **S0-8 CDC-Gate** | `report_cdc` nach Implementation | 0 `Unsafe`, 0 `No ASYNC_REG` für alle `tetra_*`-Instanzen; IP-interne Restbefunde namentlich gewaivert (`01 §5` V-01-4) |
| **S0-9 Ressourcen- und Timing-Gate** | `report_utilization`, `report_timing_summary` gegen das Budget in `01 §3.9` | Keine Budgetzeile überschritten, WNS ≥ +0,250 ns. **Slice-Prozent wird nicht geprüft** (`CONVENTIONS §6.4`) |
| **S0-10 Vektor-Manifest** | `tools/vectors/MANIFEST.json` wird neu erzeugt und gegen den Bestand verglichen; jeder Eintrag trägt `line_kind` und `bit_order` aus der geschlossenen Liste (§3.4.1) | Bit-identisch, kein Eintrag ohne `line_kind`/`bit_order`. V1-Gegenbefund: `tb/vectors/README.md:20-32` führt Vektoren als „fehlen", die vorhanden sind — eine handgepflegte Statustabelle driftet zwangsläufig |

### 3.2 Stufe 1 — RTL-Unit-Simulation

#### 3.2.1 Runner-Vertrag

Ein Runner, ein Manifest, ein Urteil. Der Runner

1. liest `tools/sim/units.json` — je Eintrag: Testbench, RTL-Dateien, Simulationsmodelle,
   Arbeitsverzeichnis, Zeitlimit, benötigte Vektoren;
2. kompiliert mit **Verilog-2001** (`-g2001`) und schlägt bei jeder Warnung fehl;
3. simuliert mit Zeitlimit; ein Zeitlimit ist ein Fehlschlag, keine Ausnahme;
4. bewertet **ausschließlich** die `RESULT:`-Zeile und den Exit-Code (§2.4);
5. schreibt `results/sim/<gitrev>/units.jsonl` und endet mit ≠ 0, wenn ein Eintrag nicht
   bestanden hat.

**Zwei Simulatoren, ein Manifest.** `iverilog` ist der primäre Simulator, weil er schnell
und in der Schleife nutzbar ist. `xsim` läuft nachgelagert über dasselbe Manifest, weil
einzelne Konstrukte simulator-abhängig sind: der Uplink-Viterbi enthält eine
Vorwärtsreferenz und braucht `xvlog --relax` sowie Verilog- statt SystemVerilog-Modus
[SIM 2026-05-30, `03 §5.1`]. Ein Modul, das nur in einem der beiden Simulatoren besteht,
gilt als **nicht bestanden**; die Abweichung ist zu beheben, nicht zu waivern.
Der V1-Vivado-Pfad `scripts/vivado_sim.tcl` kennt 19 fest verdrahtete Modul-Filelisten
[CODE scripts/vivado_sim.tcl:59-150] und verweist auf `archive/`-Dateien — die
Doppelpflege von Filelisten ist damit als V1-Last belegt und entfällt.

#### 3.2.2 Was jede Testbench mindestens abdeckt

Für **jedes** Modul, unabhängig vom Fachkapitel:

1. **Reset-Verhalten:** alle Ausgänge auf dem in `07` bzw. im Fachkapitel genannten
   Rücksetzwert; asynchrone Aktivierung, synchrone Deaktivierung über 2-FF-Synchronisierer.
2. **Randwerte jeder Zählergröße:** Umschlag nach oben und unten, Sättigung dort, wo
   Sättigung gefordert ist.
3. **Reset mitten im Betrieb** (Datenstrom läuft) → definierter Neuaufbau, kein Hänger.
4. **Rückwärtsdruck / Leerlauf** an jeder Schnittstelle mit Bereitschaftssignal.
5. **Bit-Order** jedes Bus- und Mailbox-Wortes über eine **wandernde Eins** über alle
   Positionen — kein Sammelvektor.
6. Für alle Module mit Zeitbezug: Verhalten am Frame-18-Übergang und am
   Multiframe-Umschlag.

Die fachlichen Zusatzprüfungen stehen in den §5-Abschnitten der Kapitel `01`…`12` und
werden in der Matrix (§3.13) referenziert, nicht wiederholt.

#### 3.2.3 Die Regel, die V1 zwei Fehler gekostet hat

> **Der Sollwert kommt aus der Norm oder aus der Referenz-Aufzeichnung, niemals aus dem
> Prüfling.**

Belege, warum diese Regel hier steht und nicht als Stilhinweis:

- Der Burst-Demultiplexer-Test von V1 benutzt dasselbe falsche Feldraster als Sollwert wie
  der Prüfling und findet den Block-1-Versatz deshalb nicht
  [CODE tb/tb_tetra_burst_demux.v:6-17, `02 §5` V-02-6].
- Die RM(30,14)-Vektoren werden gegen die **eigene** Herleitung geprüft
  [CODE tb/vectors/gen_reed_muller_vectors.py:113-122].
- Der Verschleierungs-Vektor stammt aus der eigenen Galois-Annahme; der Generator sagt es
  selbst: „LFSR model (matches RTL exactly)"
  [CODE tb/vectors/gen_scrambler_vectors.py:35-39].
- Der Referenzvektor des Zugriffszuweisungs-Encoders wird explizit aus dem
  Software-Pfad erzeugt, der mit ihm verglichen wird: „Reproduces the SW path in
  `sw/tetra_hal.c` exactly … so that the RTL `tetra_aach_encoder` can be verified
  bit-exact against it" [CODE scripts/gen_aach_reference.py:5-7]. Das prüft die
  Übereinstimmung zweier Implementierungen, nicht die Übereinstimmung mit der Norm.

### 3.3 Stufe 2 — Software-Unit-Tests

**Sammelziel:** `make -C sw check`. Ein Testprogramm ohne Ziel ist ein S0-3-Fehler.

**Übersetzungsvertrag** (verbindlich, weil V1 hier zu weich war — V1 übersetzt die
Host-Testziele mit `-Wall -Werror -O2`, ohne `-Wextra` und ohne Speicherprüfer
[CODE sw/Makefile:70-104]; der ARM-Produktionsbau nutzt `-Wall -Wextra -O2`, aber **kein**
`-Werror` [CODE sw/Makefile:19]. Keine der beiden Konfigurationen ist vollständig):

| Konfiguration | Flags | Zweck |
|---|---|---|
| `check` | `-Wall -Wextra -Werror -O2` | Grundlauf |
| `check-asan` | zusätzlich `-fsanitize=address,undefined -fno-omit-frame-pointer` | Pflicht für alle Parser- und Zusammensetzungstests; `09 §5.1` (`test_mm_fuzz`) und `10 §5.1` (`t_cmce_parse_short`) fordern einen Speicherprüfer ausdrücklich |
| `check-32` | zusätzlich `-m32` | deckt Annahmen über Zeigerbreite und `int`-Größe auf, die auf dem 32-bit-ARM-Ziel wirksam werden |

**Pflicht-Testklassen je Software-Modul:**

1. **Rundlauf** bauen → parsen für jede PDU und jede Längenvariante.
2. **Kurzer Puffer** für jedes Pflichtfeld jeder Uplink-PDU: Rückgabe „ungültig", kein
   Zugriff jenseits der übergebenen Bitzahl (unter Adressprüfer).
3. **Zufallsbeschuss** ≥ 10⁵ Körper: kein Zugriff außerhalb des Puffers, keine
   Downlink-PDU als Reaktion auf einen als fehlerhaft erkannten Körper.
4. **Grenzlängen** der Fragmentketten, insbesondere die Fälle, in denen ein leeres
   Endfragment entsteht (`11 §5.1`).
5. **Kein Heap im Sprach- und Empfangspfad:** Belegung nach 10⁵ Bursts unverändert
   (`12 §5.1`).

**V1-Befund, der die Regel R-14-05 begründet.** `sw/test_sds_dl_frag.c` existiert, ist in
keinem Makefile-Ziel eingetragen und schlägt gegen den korrigierten Erzeuger fehl, weil er
den Endfragment-Kopf noch mit 4 statt 21 bit zurückliest
[CODE sw/test_sds_dl_frag.c:60-62]; nachgeprüft bricht er mit `UDD mismatch @81` ab
[SIM 2026-07-25, `11 §5.1`]. Ein nicht ausgeführter Test mit veralteter Erwartung ist
schlechter als kein Test: er erzeugt den Eindruck von Abdeckung.

### 3.4 Testvektoren

#### 3.4.1 Erzeugung

| Eigenschaft | Regel |
|---|---|
| Determinismus | Fester Startwert je Vektor; Startwert steht im Manifest, nicht im Skript-Aufruf |
| Parametrierung | Amplitude, Rauschen, Burstzahl und Normierungsziel als Kommandozeilen-Parameter, damit Messreihen ohne Skript-Änderung laufen — Muster aus V1 übernommen [CODE scripts/gen_ul_demod_tv.py, `03 §5.1`] |
| Manifest | `tools/vectors/MANIFEST.json`: Datei, Prüfsumme, Erzeuger, Startwert, Verbraucher-Testbench, Herkunftskategorie (§3.4.2), **`line_kind`** und **`bit_order`** (Pflichtfelder, siehe unten) |
| Ablage | Erzeugte Vektoren liegen **nicht** im Versionsverwaltungssystem, außer sie stammen aus einer Aufzeichnung (dann mit Herkunftszeile) |
| Format | `$readmemh`-lesbar, **eine** Größe pro Zeile, Kommentare mit `//`; relative Pfade immer vom Projektwurzelverzeichnis. Welche Größe eine Zeile trägt, steht als `line_kind` im Manifest — nicht im Dateinamen und nicht im Kopfkommentar |
| Bit-Order | Pflichtfeld `bit_order` je Vektordatei, aus der geschlossenen Liste der Tabelle unten. Ohne dieses Feld ist der Eintrag ein S0-10-Fehler. „Wie das Nachbarmodul" ist keine Angabe (`CONVENTIONS §4`) |

**Geschlossene Liste `line_kind` × `bit_order`** — verbindlich, weil genau diese Angabe in
V1 fehlte und dieselben Daten in zwei Kapiteln unterschiedlich geordnet gelesen wurden
(`03 §3.6.4` gegen die Wortordnung in `12 §2.2` G2):

| `line_kind` | Eine Zeile trägt | Zugelassene `bit_order` | Bedeutung |
|---|---|---|---|
| `bit` | ein Bit (`0`/`1`) | `onair_first` | Zeile 0 = **zuerst gesendetes** Bit; ETSI zählt ab 1, also Zeile `i` = Bit `i+1` der Normtabelle. Andere Ordnung ist unzulässig |
| `dibit` | ein Dibit als Hex-Ziffer `0`…`3` | `dibit_onair` | Zeile 0 = erstes gesendetes Dibit; Wert = `2·B(2k−1) + B(2k)`, also erstes Bit des Paares im MSB |
| `soft8` | ein 8-bit-Soft-Wert im Zweierkomplement | `soft_onair_j` | Zeilenindex = On-Air-Type-5-Index `j` nach `03 §3.6.4` (`j = 0` = bkn1(1)); Vorzeichenkonvention K1 (positiv ⇒ Bit `0`) mit Verweis auf `03 §3.6.4` |
| `word32` | ein 32-bit-Wort in Hex | `word_msb_bits` | Bit-Port: Bit mit kleinstem On-Air-Index im **MSB** des Worts (R-05-14) |
| `word32` | ein 32-bit-Wort in Hex | `word_lsb_soft` | Soft-Wortport: `wort[8·n +: 8] = soft[4·w + n]`, Soft-**Werte** aufsteigend ab LSB — die in `07 §3.4`, `03 §3.6.4` und `12 §2.2` G2 dokumentierte Ausnahme, nur für diesen Port zugelassen |
| `iq` | ein IQ-Paar, `I` dann `Q`, je Zweierkomplement | `sample_time` | Zeilenindex = aufsteigende Abtastzeit; Breite und Skalierung stehen im Manifest |

Ein Vektor, dessen `bit_order` nicht zu seinem Verbraucher passt, ist kein Formfehler,
sondern der Fehler, den die wandernde Eins aus §3.2.2 Punkt 5 finden muss. Beide
Prüfungen sind Pflicht: das Manifestfeld macht die Erwartung sichtbar, die wandernde Eins
prüft die Umsetzung.

#### 3.4.2 Herkunftskategorien und die Unabhängigkeitsregel

Jeder Vektor trägt im Manifest genau eine Kategorie:

| Kategorie | Bedeutung | Zugelassen als Sollwert für |
|---|---|---|
| **N** — Norm | händisch aus dem ETSI-Text nachgerechnet | alles |
| **G** — Aufzeichnung | aus `docs/reference_decode/` bzw. einem eigenen Mitschnitt extrahiert | alles |
| **X** — Zweitimplementierung | aus einer unabhängig geschriebenen zweiten Implementierung | alles, wenn die Zweitimplementierung selbst gegen N oder G abgenommen ist |
| **S** — Selbstbezug | aus derselben Kette erzeugt, die geprüft wird | **nur** Rundlauf- und Regressionsvektoren, nie als Korrektheitsnachweis |

Ein Vektor der Kategorie **S** darf einen Rundlauf sichern („Encoder und Decoder passen
zueinander") und eine Regression festhalten („das Verhalten hat sich nicht geändert"). Er
darf **nie** die Aussage tragen „die Kette ist richtig". V1 vermischt beides:
`gen_sch_f_dec_tv.py` erzeugt Decoder-Vektoren über den eigenen, bereits verifizierten
Encoder und nennt das selbst einen „closed-loop GATE"
[CODE scripts/gen_sch_f_dec_tv.py:4-7] — als Rundlauf korrekt, als Korrektheitsnachweis
nicht. Ebenso importiert die Prüfhilfe für den Uplink-Pfad ihre Bausteine aus den
Decodern, gegen die sie prüft
[CODE scripts/check_ul_wav_rtl_emu.py:13-14].

#### 3.4.3 Pflicht-Vektorbestand Stufe 1

Vollständig in den Fachkapiteln, hier nur die Kategorien, damit S0-10 prüfbar ist:

| Bereich | Vektoren | Kategorie |
|---|---|---|
Prüffeld, Mutter-Code, Punktierung, Interleaver, RM(30,14) | Norm-Nachrechnung je Kanal und je `K1` | N (`05 §5.1`) |
Verschleierung | erste 432 bit gegen die aus der Referenz-Zugriffszuweisung extrahierte Folge; zusätzlich Startwert `0x3` gegen die Broadcast-Maske | G + N (`05 §5.1`) |
Fünf Kanalketten (Broadcast-Synchronisation, Halbschlitz-Downlink, Vollschlitz-Downlink, Zugriffszuweisung, Halbschlitz-Uplink) | Zwischenebenen aus `dl_events.jsonl` / `ul_events.jsonl` | G (`05 §5.2`) |
Empfangs-Frontend, Filter, Demodulator, Zeitrückgewinnung, Korrelator | Fixpunkt-Referenzmodell mit **Integer**-Arithmetik, bit-exakt | X (`02 §5`) |
Burst-Geometrie Sende- und Empfangsseite | Feldraster aus den ETSI-Tabellen, jedes Feld mit eigenem Muster | N (`02 §5`, `04 §5.1`) |
Uplink-Soft-Kette, Amplitudenkennlinie | parametrierte Erzeugung über Amplitude und Rauschen | X (`03 §5.1`) |
Sprachkanal-Codierung | ETSI-Referenzimplementierung als Orakel, ≥ 1 000 Zufallsrahmen, Toleranz null Bits | X (`12 §5.2`) |
Echte Luftdaten | Uplink-WAV → Symbolstrom → Testbench; Downlink-IQ-Aufzeichnung → Dibit-Datei | G (`03 §5.2`, `02 §5`) |

### 3.5 Stufe 3 — Ketten- und Integrations-Simulation

Vier Läufe, jeder mit binärem Kriterium.

**S3-A Sendekette gegen unabhängigen Referenz-Demodulator.**
Zeitplan → Verteiler → Burst-Aufbau → Modulator → Sendefilter → Interpolation, danach
Demodulation durch den Python-Referenz-Demodulator. Kriterien: Trainingssequenz-Dibits
bit-genau zurückgewonnen, Bitfehlerrate über 4 verkettete Bursts = 0 (rauschfrei),
Korrelation der Trainingssequenz ≥ 0,95 (`04 §5.2`).

**S3-B Empfangskette gegen unabhängigen Referenz-Decoder auf echten Luftdaten.**
Ein Mitschnitt läuft (a) durch die RTL-Simulation und (b) durch den Python-Decoder.
Kriterium Downlink: identischer Dibit-Strom über ≥ 4 aufeinanderfolgende Bursts, gleiche
Synchronisationspositionen (`02 §5` V-02-8). Kriterium Uplink: die Zahl der von der RTL
erfolgreich dekodierten Bursts ist ≥ der Zahl der vom Python-Decoder dekodierten; ein
Burst, den Python nicht dekodiert, zählt nicht gegen die RTL
[CODE tb/tb_ul_wav_chain.v:16, `03 §5.2`].

**S3-C Software ↔ Hardware-Grenze in Simulation.**
Ein Software-Modell schreibt eine fertig codierte PDU über die Downlink-Mailbox, die
Simulation sendet sie, die simulierte Empfangskette liest sie zurück — bit-identisch.
Umgekehrt wird ein synthetischer Uplink-Burst eingespeist; die Software liest die 432
Soft-Werte samt Zeitstempel zurück, und der Zeitstempel entspricht dem eingespeisten
Slot (`07 §5.2`). Der Zeitstempel-Test läuft über **alle** 4 × 18 × 60 Kombinationen
(`07 §5.1`), weil R-00-04 die einzige Zeitquelle der Software ist.

**S3-D Aufschaukelungs-Test.** Siehe §3.9. Blocker.

### 3.6 Stufe 4 — Vergleich mit der Referenz-Aufzeichnung

Der Vergleich ist **funktional, nicht bit-genau**. Die Referenz-Aufzeichnung ist die
Ein-Endgerät-Sicht eines fremden Netzes mit anderen Zellparametern; sie belegt Struktur
und Zeitlage, nicht Feldinhalte.

#### 3.6.1 Feldkategorien (normativ)

| Kategorie | Felder | Vergleich |
|---|---|---|
| **Strukturell — Bit-Identität gefordert** | PDU-Typ und Untertyp; Reihenfolge und Vorhandensein aller O-/P-/M-Bits; Längenangaben (`LI`, Element-Längen, Wiederholungszahlen); Kopflängen aller Kettenblöcke; Füllbit-Anzeige und Füllmuster; Adresstyp-Feld (nicht der Adresswert); Reservierungs- und Zugriffsanforderungs-Bits; Anzahl und Reihenfolge der Informationselemente; Kapazitätszuweisung und Zuweisungs-Verzögerung; Infowort-Kopf des Zugriffszuweisungskanals; alle Ebenen der Kanalcodierung bei gleichem Startwert der Verschleierung | bitweise |
| **Zell- und gerätespezifisch — Abweichung erlaubt und erwartet** | Teilnehmer-Kurzadresse; Gruppen-Kurzadresse; Trägernummer; Landeskennung; Netzkennung; Farbcode; Aufenthaltsbereich; Verschleierungs-Startwert; Ruf-Kennung; Nachrichten-Referenz; Ereignis-Kennung; Zeitstempel und Slotnummern der Aufzeichnung; Sendeleistungs- und Pegelangaben | **nicht** verglichen |
| **Semantisch — gleiche Regel, anderer Wert** | quittierter Anmeldetyp (muss dem angeforderten gleichen, nicht dem der Referenz); Nutzungsmarkierung (muss über den Ruf konstant sein, nicht gleich der Referenz); Anzahl Anhänge-Datensätze (muss der eigenen Konfiguration entsprechen) | Regel geprüft, Wert nicht |

Die Ausnahme von R-14-07: Beim Vergleich der **reinen Codierungsfunktion** ist
Bit-Identität zulässig und gefordert, weil dort kein zellspezifisches Feld verglichen
wird, sondern eine mathematische Abbildung — fünf Ketten, alle Zwischenebenen, aus den
Ereignisdateien der Referenz (`05 §5.2`).

#### 3.6.2 Verfahren

1. **Eigenen Mitschnitt erzeugen:** Downlink und Uplink gleichzeitig, ≥ 60 s, mit
   Anmeldung, Gruppenwechsel und Gruppenruf im Ablauf.
2. **Beide Aufzeichnungen mit demselben Decoder-Stand auswerten** und je Burst alle
   Ebenen ausgeben (Sendebits → entschleiert → deinterleavt → Informationsbits → MAC →
   LLC → MLE → MM/CMCE/SDS).
3. **Abdeckungsnachweis** nach §3.6.4 für beide Läufe erbringen. Ohne diesen Schritt ist
   der Vergleich nicht auswertbar.
4. **Inventar vergleichen:** Bursttyp-Verteilung je Zeitschlitz, Infowort-Verteilung des
   Zugriffszuweisungskanals, PDU-Inventar je Schicht — als Rate pro Sekunde, weil die
   Aufzeichnungen unterschiedlich lang sind (Referenz 103,98 s / 7 338 Downlink-Bursts;
   eigene V1-Aufzeichnung 26,59 s / 1 876 Bursts [GOLD `docs/reference_decode/README.md`,
   `docs/local_cell_decode/README.md`]).
5. **Struktur vergleichen** nach §3.6.1, Feld für Feld, mit den Vergleichspunkten aus den
   Fachkapiteln (`04 §5.3`, `06 §5.2`, `08 §5.2`, `09 §5.3`, `10 §5.2`, `12 §5.3`).
6. **Zeitlage vergleichen** in Frames und Slots, nicht in Millisekunden: Vorantwort ein
   Frame nach dem auslösenden Uplink-Burst, Wiederholungsabstand zwei Frames (`08 §5.2`).
   Die substanzielle Antwort liegt auf **demselben** Zeitschlitz wie die Vorantwort; ihr
   Abstand wird protokolliert, aber **nicht** gegen einen Sollwert geprüft — er ist
   ereignisgetriggert (`08` R-08-11, `08 §3.5.2`, `04` R-04-21). Die Referenz zeigt für die
   Anmeldung 8 Burst-Positionen = 2 Frames (Burst #775 → #783); ein anderer Abstand in der
   eigenen Aufzeichnung ist **keine** Abweichung, solange Inhalt und Zeitschlitz stimmen
   (`04 §5.3`, `04 §5.4` Punkt 5).
7. **Abweichungen einordnen** in: erwartet (Kategorie 2), Regel erfüllt (Kategorie 3),
   Fehlschlag (Kategorie 1). Nur die dritte Klasse blockiert.

**Was der Vergleich nicht kann.** Die Reservierungs-Haltedauer ist in der
Referenz-Aufzeichnung nicht enthalten — das reservierte Infowort `0x0000` kommt dort nicht
vor (`08 §5.2`). Ebenso enthält die Referenz keine Kurznachricht und keine
Statusnachricht (`11 §5.3`). Für diese Funktionen ist der eigene Mitschnitt die einzige
Quelle; das ist eine Einschränkung des Verfahrens, keine Aussage über die Norm — und im
Fall der Kurznachrichten steht diese Einschränkung ausdrücklich unter dem Vorbehalt von
§3.6.3.

#### 3.6.3 Warnung: Werkzeuglücke im Halbschlitz-Signalisierungspfad

> **Ein Nullbefund in `docs/reference_decode/` ist KEIN Beweis für Abwesenheit.**

Der Decoder, mit dem die Referenz-Aufzeichnung ausgewertet wurde, führt die
Halbschlitz-Signalisierungsblöcke **nicht** in die oberen Protokollschichten. Belege,
alle gegen die Dateien nachgeprüft:

| Befund | Beleg |
|---|---|
| Die Aufzeichnung enthält 1 969 Halbschlitz-Blöcke mit dekodierter MAC-Zeile, davon **27 mit einer echten Teilnehmeradresse** (die übrigen 1 942 mit Null-Adresse) | [GOLD `docs/reference_decode/dl_full.md`, Zählung über `MAC-RESOURCE (SCH/HD) addr=…ID=`] |
| Für **keinen** dieser 1 969 Blöcke existiert eine LLC-, MLE-, MM- oder CMCE-Zeile | [GOLD ebenda: 28 LLC-Zeilen und 24 MLE-Zeilen insgesamt — genau die Zahl der 28 Vollschlitz-Blöcke] |
| Vollschlitz-Blöcke werden dagegen vollständig ausgewertet: 24 adressierte + 4 mit Null-Adresse = 28, jeder mit LLC-Zeile | [GOLD ebenda] |
| Damit ist etwa **die Hälfte der adressierten Downlink-Signalisierung** der Aufzeichnung oberhalb der MAC-Schicht unsichtbar: 27 von 51 adressierten PDUs | Rechnung aus den beiden Zeilen darüber |
| Die Lücke besteht **auch heute noch**, in zwei unabhängigen Stufen: (a) für Synchronisations-Bursts ruft der Decoder für den zweiten Halbschlitzblock die oberen Schichten überhaupt nicht auf; (b) für Normal-Bursts ruft er sie auf, aber mit einem Blockpräfix im Ausgabetext, das der Aggregator nicht erkennt | (a) [CODE scripts/decode_dl.py:1914-1916]; (b) [CODE scripts/decode_dl.py:2116 erzeugt `    BKN1 LLC …`, während CODE scripts/parse_reference_decode.py:124 auf `^\s+LLC\s+` prüft] |
| Selbst bei passendem Muster wäre die Zuordnung mehrdeutig: der Aggregator sammelt LLC- und MLE-Zeilen in **flachen Listen** ohne Blockbezug | [CODE scripts/parse_reference_decode.py:229-236] |
| Dieselbe Lücke besteht in der eigenen V1-Aufzeichnung: 1 adressierter Halbschlitz-Block, 0 zugehörige LLC-Zeilen; 7 Vollschlitz-Blöcke, 7 LLC-Zeilen | [CODE `grep` über `docs/local_cell_decode/dl_full.md`] |

**Folgen für die Spezifikation.** Jede Stelle, die aus der Referenz-Aufzeichnung
Abwesenheit ableitet, steht unter Vorbehalt, solange der Abdeckungsnachweis fehlt. Das
betrifft insbesondere die Feststellung, die Referenz enthalte keine Kurznachricht
(`11 §5.3`): der Nullbefund stammt aus einer Textsuche über Dateien, in denen der
Halbschlitz-Pfad oberhalb der MAC-Schicht nie ausgewertet wurde — und der
Halbschlitz-Pfad ist genau der Pfad, auf dem eine kurze Kurznachricht im Downlink läuft.

**Anforderungen, die daraus folgen:**

- **R-14-08** (Decoder führt jeden Bursttyp durch alle Schichten) ist **vor** dem ersten
  Referenz-Vergleich zu erfüllen, nicht danach.
- Die Ausgabe des Decoders trägt je Zeile den **Blockbezug** (Vollschlitz, Halbschlitz 1,
  Halbschlitz 2) als strukturiertes Feld, nicht als Textpräfix. Die Ereignisdatei ist die
  primäre Schnittstelle; die Textdatei ist Ansichtssache.
- Der Aggregator ordnet jede Schichtzeile **einem** Block zu. Flache Listen sind
  unzulässig.
- Die Referenz-Aufzeichnung wird mit dem abgenommenen Decoder **neu erzeugt**, bevor sie
  als Abnahmegrundlage dient. Bis dahin gilt sie für den Halbschlitz-Pfad als unbelegt.

#### 3.6.4 Abdeckungsnachweis des Vergleichs-Decoders

`tools/decode/coverage.py` erzeugt aus einem Decoderlauf eine Matrix
**Bursttyp × Block × höchste erreichte Schicht** und bewertet sie:

| Bursttyp | Block | Erwarteter Endpunkt |
|---|---|---|
Synchronisations-Burst | Broadcast-Synchronisationsblock | Systeminformation geparst |
Synchronisations-Burst | Halbschlitzblock 2 | MAC → LLC → MLE → MM/CMCE/SDS **oder** Broadcast-Systeminformation |
Synchronisations-Burst | Zugriffszuweisungsblock | Infowort geparst |
Normal-Burst, Vollschlitz | Vollschlitzblock | MAC → LLC → MLE → MM/CMCE/SDS |
Normal-Burst, Halbschlitz | Halbschlitzblock 1 **und** 2, getrennt | MAC → LLC → MLE → MM/CMCE/SDS |
Normal-Burst mit Kanalstehlen | gestohlene Hälfte | MAC → LLC → MLE → MM/CMCE/SDS |
Uplink-Burst | Halbschlitz-Uplink | MAC → LLC → MLE → MM/CMCE/SDS (in V1 vorhanden, 20 LLC- und 19 MLE-Zeilen zu 47 MAC-Zeilen [GOLD `docs/reference_decode/ul_full.md`]) |

**Bestehens-Bedingung:** Für jede Zeile gilt entweder „Endpunkt erreicht" oder eine
ausgeschriebene, geprüfte Begründung („Prüffeld verletzt", „Null-PDU", „Sprachnutzlast",
„Broadcast ohne LLC"). Eine Zelle mit dem Wert „MAC" ohne Begründung ist ein Fehlschlag
der Stufe 4. Der Bericht wird zusammen mit jeder Aufzeichnung archiviert und ist der
Beleg, den R-14-09 verlangt.

**Zusätzliche Negativprobe:** Eine synthetische Aufzeichnung, in die je Bursttyp und
Block genau eine bekannte PDU jeder Schicht eingebettet ist, muss vom Decoder vollständig
wiedergefunden werden. Genau diese Probe hätte die Lücke aus §3.6.3 beim ersten Lauf
sichtbar gemacht.

### 3.7 Stufe 5 — Board-Abnahme über Register und Zähler

Ohne Funkverkehr nach außen; Sendepegel auf dem für Nahfeld-Prüfung vorgesehenen Wert.

| Prüfung | Kriterium |
|---|---|
| **Hochlauf-Reihenfolge**, ≥ 3 Kaltstarts | Jeder Durchlauf erfüllt das Bereitschafts-Gate innerhalb der in `01 §5` genannten Zeit; der Sendezweig geht erst danach auf den Betriebspegel; Negativtests aus `01 §5` V-01-7 protokolliert |
| **Rücksetzwerte** | Jede in `07 §3` genannte Adresse liest nach Reset ihren dokumentierten Wert; die Prüftabelle stammt aus derselben Quelle wie die Dekodierkonstanten (`07 §5.1`) |
| **Adressraum** | `REG_ACCESS_ERR_CNT` = 0 nach dem Hochlauf; kein Aliasing zwischen den belegten Seiten (`07 §5.1`) |
| **Taktüberwachung** | Frequenzmesswert im Fenster, Lebendigkeitsbit gesetzt (`01 §5` V-01-3) |
| **Symbol- und Sample-Raten** | Sample-Zähler 72 000 ± 1 pro Sekunde, Dibit-Zähler 18 000 ± 1, Symbolticks 180 000 ± Messfenster über 10 s (`02 §5`, `04 §5.4`) |
| **Datenformat des Transceivers** | Histogramm der Empfangs-IQ enthält negative Werte und ist um 0 zentriert (`01 §5` V-01-6) |
| **Sendekanal-Zuordnung** | Pegeländerung nur am tatsächlich genutzten Sendekanal (`01 §5` V-01-9) |
| **Duplex-Ablage** | Änderung des Tabelleneintrags wirkt auf den Empfangs-Lokaloszillator und übersteht einen Neustart; es existiert kein zweiter Codepfad, der die Uplink-Frequenz rechnet (`01 §5` V-01-8) |
| **Zeitkopplung** | §3.10 — **Blocker nach jedem Bitstream** |
| **Leerlauf-Zähler** | Über 10 min ohne Endgerät: alle Verwurfs-, Überlauf-, Unterlauf-, Sättigungs- und Fristzähler bleiben 0 (`04 §5.4`, `07 §5.4`) |

### 3.8 Stufe 6 — Luft-Protokolle

#### 3.8.1 Gemeinsame Vorbereitung (für jedes Protokoll verbindlich)

1. **Sitzung anlegen:** `tools/air/session.py` erfasst Bitstream-Prüfsumme,
   Software-Kennung, Konfigurations-Prüfsumme, Endgerätetypen, Aufbau, Ort, Zeit.
2. **Nach jedem neuen Bitstream: Board neu starten**, danach die
   Zeitkopplungs-Messung (§3.10). Ohne dieses Ergebnis beginnt kein Protokoll.
3. **Nach Änderungen an der Downlink-Signalisierung: Endgeräte-Neustart ansagen** und
   abwarten, damit kein Endgerät mit altem Zellzustand mitgemessen wird.
4. **Mitschnitt Downlink und Uplink gleichzeitig starten**, ein unabhängiger Empfänger.
5. **Zählerabzug vor dem Lauf** als JSON archivieren.
6. **Sprechtasten-Tests mit dem Bediener abstimmen** und auf Bestätigung warten, statt
   blind zu messen.
7. **Betriebsparameter zurückstellen:** Kein Protokoll darf mit einem verkürzten
   Ruf-Verfallszeitgeber abgeschlossen werden; der Betriebswert wird vor der Abnahme
   wiederhergestellt und ein Ablauf wiederholt (`08 §5.3` E).

#### 3.8.2 Durchführung, Abbruch, Auswertung

**Durchführung:** ≥ 3 Wiederholungen je Protokollpunkt (R-14-10). Zwischen den
Wiederholungen wird nichts verändert — kein Pegel, keine Antennenposition, keine
Konfiguration. Änderungen begründen eine neue Sitzung.

**Abbruchbedingungen** (Lauf abbrechen, Rohlog behalten, Ursache klären, **nicht**
weitermessen):

| Bedingung | Grund |
|---|---|
| Ein Endgerät meldet sich innerhalb von 5 s zweimal an | Signatur der Anmelde-Spirale (`00 §3.4`) |
| `REG_DLQ_DROP_TOTAL` > 0 | Warteschlangen-Überlauf; jeder Folgemesswert ist verfälscht |
| Zuweisungsrate über der Obergrenze aus §3.9 | Aufschaukelung im Gang |
| Fehlerrate der Sprachrahmen > 20 % | Empfangskette nicht im Arbeitspunkt; Protokollmessungen darauf sind wertlos |
| Board nicht mehr über die Netzverbindung erreichbar | Zustand über die serielle Konsole erfassen, nicht neu starten |
| Zeitkopplungs-Schrittweite verletzt | §3.10, Blocker |

**Auswertung:** Je Wiederholung ein Datensatz; Bericht mit Minimum, Median, Maximum und
Spannweite. Ein Protokollpunkt ist bestanden, wenn **jede** Wiederholung das Kriterium
erfüllt — nicht, wenn der Mittelwert es erfüllt. Vergleiche gegen eine Referenz laufen als
A/B **innerhalb** der Sitzung (R-14-11); Begründung in §4.

#### 3.8.3 Protokolle

| ID | Protokoll | Kern-Kriterien (Details im genannten Kapitel) |
|---|---|---|
| **L1** | **Zellaussendung, Fremdempfänger** | Ein normgerechter Fremdempfänger rastet ein und dekodiert die Systeminformation mit richtiger Landes-/Netzkennung und Farbcode. Prüffeld-Erfolg ≥ 99 % der Signalisierungs-Bursts im eigenen Mitschnitt (`04 §5.4`, `05 §5.4`) |
| **L2** | **Anmeldung** | Anmeldung in allen Durchläufen erfolgreich; Zufallszugriff bis Bestätigung ≤ 5 Frames; quittierter Anmeldetyp gleich dem angeforderten; Warteschlangen-Verwurf 0; Zuweisungs-Nutzungszähler gleich Auslösezähler, Wiederhol-Zuweisungen 0 (`06 §5.3`, `09 §5.4`) |
| **L3** | **Gruppenruf mit Sprache** | Sprechtaste 10 s, 3 Wiederholungen: Fehlerrate der Sprachrahmen ≤ 5 %; Sende-Sprachburst-Zähler 16–18 je Sekunde Sprechzeit; Mailbox-Überlauf und -Zerreißen 0; Hörurteil dokumentiert (`12 §5.4`) |
| **L4** | **Mehrere Gruppen, mehrere Zeitschlitze** | Zwei Rufe auf zwei Zeitschlitzen; Loslassen auf einem legt innerhalb 300–400 ms genau dieses Bit der Aktivmaske frei, das andere bleibt, das Audio der anderen Gruppe läuft unterbrechungsfrei (`10 §5.3` A3, `12 §5.4`) |
| **L5** | **Einzelruf** | Annahme-Fall und Nichtannahme-Fall; Abbau nach Klingelzeitgeber mit der spezifizierten Ursache (`10 §5.3` A6/A7) |
| **L6** | **Kurznachrichten** | Kurze Nachricht, lange Nachricht in beide Richtungen mit vollständiger Fragmentkette, Statusnachricht, Kurzbericht; Zusammensetzungs-Zähler je Grund getrennt (`11 §5.4`) |
| **L7** | **Zeitkopplung** | §3.10 |
| **L8** | **Aufschaukelung** | §3.9 |
| **L9** | **Späteinstieg** | Zweites Endgerät tritt während eines laufenden Rufs bei — über Gruppenwechsel **und** über Einschalten; letzterer Fall war in V1 nie beim Auslösen beobachtet und ist Pflicht-Abnahmefall (`10 §5.3` A8/A9) |
| **L10** | **Entfernungslauf** | 50 m, 3 Wiederholungen: Fehlerrate der Sprachrahmen ≤ 10 %; mittlerer Betrag der Soft-Werte weicht ≤ 20 % vom Nahfeldwert **derselben Sitzung** ab (`03 §5.5`, `12 §5.4`) |
| **L11** | **Dauerlauf** | 10 min mit zwei Endgeräten, Anmeldung + Gruppenwechsel + Gruppenruf: alle Verwurfs-, Überlauf-, Fristzähler bleiben 0; Folgenummer der Uplink-Mailbox lückenlos; Abfrageschleife < 5 % eines Kerns (`07 §5.4`, `10 §5.3` A10) |

### 3.9 Der Aufschaukelungs-Test — das wichtigste Abnahmekriterium

#### 3.9.1 Was zu verhindern ist

In V1 wurde die Uplink-Zuweisung an einen Software-Umlauf gebunden. Damit war sie nicht
mehr sendezeitpunkt-fest. Die Folge war eine sich selbst verstärkende Kette: Endgeräte ohne
rechtzeitige Zuweisung wiederholen ihre Anforderung → jede Wiederholung erzeugt eine
weitere Zuweisung → die Zuweisungen fluten die Signalisierungs-Warteschlange → die
Anmeldebestätigung kommt nicht mehr durch → das Endgerät meldet sich erneut an. Eine
Ratenbegrenzung milderte die Symptome und behob die Ursache nicht; der Umbau wurde
zurückgenommen [MESS 2026-07-11, `00 §3.4`, `06 §3.9.1`].

Das ist kein Protokollfehler, sondern ein **Regelkreis mit Schleifenverstärkung > 1**. Ein
funktionaler Test („Anmeldung klappt") sieht das nicht, weil der Kreis erst unter Last
aufschwingt. Deshalb wird die Schleifenverstärkung direkt gemessen.

#### 3.9.2 Messgrößen

| Größe | Herkunft | Bedeutung |
|---|---|---|
`grant_trigger_rate` | `REG_GRANT_TRIGGER_CNT`-Zuwachs / Zeit | Wie oft ein Uplink-Burst überhaupt eine Zuweisung anstoßen darf |
`grant_emit_rate` | `REG_GRANT_EMIT_CNT`-Zuwachs / Zeit | Tatsächlich ausgesendete Zuweisungen |
`resv_ratio` | `REG_RESV_SLOT_CNT` / `REG_MCCH_SLOT_CNT` | Anteil der Kontrollkanal-Slots mit Reservierungsmuster |
`dlq_drop` | `REG_DLQ_DROP_TOTAL` und je Produzent | Verwürfe der Signalisierungs-Warteschlange |
`dlq_depth_p99` | `REG_DLQ_STATUS` | 99-Perzentil der Warteschlangentiefe |
`req_per_ack` | Anforderungen / Bestätigungen, aus dem Uplink-Mitschnitt und den Anmeldezählern | Verhältnis Anforderungen zu Bestätigungen |
`ms_retry_rate` | Anzahl Zufallszugriffe derselben Teilnehmeradresse / Zeit, aus dem Uplink-Mitschnitt | Wiederholrate des Endgeräts |
`G` | Δ`grant_emit_rate` / Δ`ms_retry_rate` über einen Laststufen-Sweep | **Schleifenverstärkung** |

#### 3.9.3 Simulationsteil (S3-D, Blocker vor jedem Luft-Betrieb)

Aufbau: die Zuweisungs-Hardware in Simulation, dazu ein **Verhaltensmodell eines
Endgeräts**, das die normierte Zufallszugriffs-Logik nachbildet:

- **Randomisierungs-Vorlauf `IMM`**, **Mindestabstand `WT`** bis zur Wiederholung und
  **maximale Zahl der Zufallszugriffe `Nu`** (bei höchster PDU-Priorität `2 × Nu`) — alle
  drei sendet die Zelle selbst aus [ETSI §21.4.4.3 Tabelle 21.79]. `WT` wird in
  Downlink-Signalisierungs-Gelegenheiten gezählt, davon **höchstens eine je TDMA-Frame**
  [ETSI §23.5.1.4.8 NOTE 3]. Das Modell wird mit **genau den Werten** parametriert, die die
  eigene Zelle im Rundspruch der Zugriffsparameter aussendet; ein Modell mit anderen Werten
  prüft eine fremde Zelle. Solange `06` keinen normativen Vorgabewert festlegt (§6 O-14-8),
  gilt der V1-Satz als Parametrierung: `IMM = 1`, `WT = 2`, `Nu = 3`
  [CODE sw/tetra_hal.c:804-809, gleichlautend :843-848 und :1063-1068].
- **Gesamtfrist des Versuchs `T.205`** (5…60 Multiframes, Wahl des Geräteherstellers) und
  die Aufgabe-Regel: nach Aufgabe ohne Antwort darf kein neuer Versuch beginnen, bevor der
  **restliche `WT`-Zeitgeber** abgelaufen ist [ETSI §23.5.1.4.9, Annex B.1].
- **Fragmentierungs- und Reserviert-Zugriffs-Auszeiten** `T.202` = 9
  Downlink-Signalisierungsframes und `T.206` = 18 [ETSI Annex B.1].
- Reaktion auf das Infowort des Zugriffszuweisungskanals und auf die empfangene Zuweisung,
  einschließlich der Regel, dass eine Zuweisung **ohne** Erfolgsanzeige den Versuch beendet
  und das Gerät in der reservierten Kapazität sendet [ETSI §23.5.1.4.9 d)].

Ablauf: **Laststufen-Sweep.** Die Zahl gleichzeitig anfordernder Endgeräte-Modelle wird
in Stufen 1, 2, 4, 8, 16 erhöht; zusätzlich läuft je Stufe ein Durchlauf mit unterdrückter
Anmeldebestätigung, damit die Modelle dauerhaft wiederholen.

Bestehens-Bedingungen — **alle** müssen halten:

| # | Bedingung | Begründung |
|---|---|---|
| 1 | **`G ≤ 1`** über alle Laststufen, gemessen als Differenzenquotient zweier benachbarter Stufen | Eine Verstärkung > 1 ist die Definition der Aufschaukelung |
| 2 | **Sättigung:** `grant_emit_rate` erreicht ab Stufe 4 eine Obergrenze und wächst mit weiterer Last nicht mehr | Der inhaltsunabhängige Auslösefilter deckelt die Rate strukturell (`06 §3.9.3`) |
| 3 | `grant_emit_rate ≤ GRANT_REPEAT / (GRANT_GAP × 56,67 ms)` — mit den Vorgabewerten 2 und 4 Frames also **≤ 8,8/s** | Formale Obergrenze des Mechanismus (`06 §5.4` Bedingung 1) |
| 4 | `grant_emit_cnt ≤ GRANT_REPEAT × grant_trigger_cnt` **und** `grant_trigger_cnt ≤` Anzahl der **offenen** Zufallszugriffs-Unterschlitze | Formale Aufschaukelungs-Sperre; als Zufallsstimulus-Test über 10 000 Frames (`06 §5.1` `tb_ul_grant_bound`) |
| 5 | `dlq_drop = 0` — **strukturell**, weil die Zuweisung die Warteschlange nicht benutzt | Ein Zähler ≠ 0 ist der Beweis, dass die Trennung verletzt wurde (`06 §5.4` Bedingung 3) |
| 6 | Eine Zuweisung markiert ihren eigenen Unterschlitz **im selben Staging-Zyklus** als reserviert | Sonst löst die Nutzung der Zusage eine neue Zusage aus — der Kern der Selbstverstärkung (`06 §3.9.3`) |
| 7 | Die Zuweisungs-Entscheidung ändert sich **nicht**, wenn die Decoder-Schnittstellen mit Zufallswerten getrieben werden | Nachweis der Inhaltsunabhängigkeit R-00-02 (`07 §5.1` `tb_ul_assign_content_independence`) |
| 8 | Kein Software-Umlauf im Antwort-Zeitpfad: Zuweisungsbits liegen vor dem Slot-Puls des Zielslots vor, Fristzähler = 0 | R-00-01 (`08 §5.1` `tb_grant_deadline`) |

Bedingung 1 und 2 sind die eigentliche Aussage. Bedingungen 3–8 sind die
Einzelmechanismen, die 1 und 2 erzwingen; sie sind getrennt geführt, damit ein Fehlschlag
lokalisierbar ist.

#### 3.9.4 Luftteil (L8, Bestätigung)

Aufbau: ein Endgerät, 60 s, die Software unterdrückt die Anmeldebestätigung, sodass das
Endgerät seinen Zufallszugriff wiederholt, solange es die Zelle sieht. Danach ein zweiter
Durchlauf mit zwei Endgeräten (verdoppelte Anforderungsrate).

Bestehens-Bedingungen:

| # | Bedingung | Grenzwert |
|---|---|---|
| 1 | `grant_emit_rate` | ≤ 8,8/s (Vorgabewerte, §3.9.3 Bedingung 3) |
| 2 | `resv_ratio` | ≤ 5 %. Zielgröße aus der Referenz: 0,71 % (13 von 1 834 Kontrollkanal-Slots) [GOLD, `06 §3.9.6`] |
| 3 | `dlq_drop` (Summe und je Produzent) | = 0 |
| 4 | `dlq_depth_p99` | ≤ 2 von 4 Plätzen |
| 5 | **Monotonie:** Verdoppelung der Anforderungsrate | `grant_emit_rate` steigt um **höchstens Faktor 2**. Ein überproportionaler Anstieg ist die Signatur der Selbstverstärkung (`06 §5.4` Bedingung 4) |
| 6 | `ms_retry_rate` je Endgerät | ≤ `1 / (WT × 56,67 ms)`, mit dem **von der eigenen Zelle ausgesendeten** `WT`. Die Zelle kennt damit die Obergrenze, die sie erwarten darf: ein normgerechtes Endgerät wiederholt seinen Zufallszugriff erst nach `WT` Downlink-Signalisierungs-Gelegenheiten, davon höchstens eine je TDMA-Frame [ETSI §23.5.1.4.8], und höchstens `Nu`-mal je Versuch (`2 × Nu` bei höchster PDU-Priorität) [ETSI §23.5.1.4.9 a)]. Mit dem heute ausgesendeten `WT = 2` [CODE sw/tetra_hal.c:806, V1-Referenz; kein normativer V2-Vorgabewert, §6 O-14-8] also **≤ 8,8/s**; der Grenzwert wird mit dem tatsächlich gesendeten `WT` nachgerechnet, nicht aus dieser Zeile übernommen. Der Zahlenwert stimmt zufällig mit Bedingung 1 überein, meint aber eine andere Größe: dort die Zuweisungsrate der Zelle, hier die Wiederholrate **eines** Endgeräts. Eine **höhere** gemessene Rate bedeutet, dass der Versuch oberhalb der MAC-Schicht neu gestartet wird — genau die Anmelde-Spirale |
| 7 | `req_per_ack` nach Aufheben der Unterdrückung | Das Endgerät meldet sich innerhalb von **2 s** an, ohne Neustart; danach 1 Bestätigung je Anforderung (`06 §5.4` Bedingung 5) |
| 8 | Kein Endgerät meldet sich innerhalb 5 s zweimal an | Abbruchbedingung §3.8.2 |

**Wenn Bedingung 5 verletzt wird, ist der Fehler nicht die Rate, sondern die Kopplung.**
Eine Ratenbegrenzung als Abhilfe ist in V2 unzulässig: sie war in V1 die Maßnahme, die die
Symptome milderte und die Ursache stehen ließ [MESS 2026-07-11].

### 3.10 Zeitkopplungs-Messung als Regressionsdetektor

#### 3.10.1 Warum diese Messung

Die Differenz zwischen dem Sende-Anker und der Ankunft eines Uplink-Bursts summiert die
Laufzeiten der gesamten Kette: Sendefilter, Interpolation, Transceiver-Latenz,
Empfangsdezimation, Empfangsfilter, Korrelator, Taktübergänge. Sie ändert sich, sobald
jemand an einer dieser Stellen etwas anfasst — auch dann, wenn Simulation und
Funktionstest unverändert grün bleiben. Damit ist sie der **empfindlichste
Regressionsdetektor des Systems** und läuft nach jedem Bitstream (R-14-12).

#### 3.10.2 Verfahren

1. **Anker konfigurieren:** `REG_AIRLOCK_CFG.anchor_ts` auf den Vorgabewert (ETSI-TS3).
   Mit TS1 als Anker wickelt der Messwert für die hinteren Zeitschlitze über die
   Frameperiode und die Slot-Zuordnung wird zweideutig [CODE rtl/tetra_zynq_top.v:1305–1309,
   `07 §4`].
2. **Vier kontrollierte Einzel-Zuweisungen** auf TS1…TS4, je ≥ 20 Uplink-Bursts;
   Ruf-Verfallszeitgeber für die Messung auf 5 s, danach zurückstellen (`08 §5.3` A/E).
3. **Je Ereignis** `REG_AIRLOCK_DELTA_CYC` lesen, sobald `REG_AIRLOCK_EVT_CNT` sich
   ändert. Die Differenz wird **im PL atomar** gebildet; die Software rechnet sie nicht aus
   zwei Zählerständen (R-07-12, `07 §5.1`).
4. **Auswerten** als Folge der vier Differenzen und ihrer **Schrittweiten**.

#### 3.10.3 Kriterien

| # | Kriterium | Wert | Status |
|---|---|---|---|
| 1 | Schrittweite TS(n) → TS(n+1) | 85/6 ms ± 1 Symboldauer (≈ ± 55,6 µs) | **Blocker** |
| 2 | Alle vier Differenzen in `[0, 1 Frame)` und monoton steigend | — | Blocker |
| 3 | Streuung je Zeitschlitz | ≤ 1 Symboldauer; V1-Referenz ± 14 µs [MESS 2026-05-25] | Blocker |
| 4 | Umschlag-Zähler und Fehlzuordnungs-Zähler | = 0 | Blocker |
| 5 | Absolutwerte | protokolliert und gegen die Latenz-Bilanz aufgeschlüsselt, Restposten ≤ 100 µs | **kein** Bestehens-Kriterium |

> **Vorrangregel.** Das Kriterium liegt auf der **Schrittweite**, nicht auf den
> Absolutwerten. Ein Kriterium, das die V1-Absolutwerte fordert (TS2/TS3/TS4 = 22,499 /
> 36,669 / 50,836 ms [MESS 2026-05-25]; TS1 = 8,340 ms ist **kein Messwert**, sondern aus
> TS2…TS4 zurückgerechnete Kalibrier-Referenz [CODE sw/tetra_ts_map.h:43-45, `08 §3.2.4`]),
> widerspricht `08 §3.2` und ist nicht anwendbar: es
> würde eine korrekte V2-Kette mit anderer Pipeline-Latenz durchfallen lassen und eine
> V2-Kette mit zufällig passender Latenz und falscher Schrittweite bestehen lassen
> (`08 §5.3`, Vorrangregel).

#### 3.10.4 Was ein Fehlschlag bedeutet

| Befund | Wahrscheinliche Ursache |
|---|---|
Schrittweite ≠ Slot-Dauer | Slot-Raster oder Anker-Lage defekt; Zeitbasis prüfen, nicht die Empfangskette |
Alle vier Werte um denselben Betrag verschoben, Schrittweite korrekt | Pipeline-Latenz geändert — **erwartet** nach Filter-, Dezimations- oder Taktänderung; Bilanz nachziehen, kein Fehler |
Nicht monoton | Anker auf dem falschen Zeitschlitz (§3.10.2 Punkt 1) |
Streuung > 1 Symboldauer | Synchronisations-Anker instabil; Korrelatorschwelle und Pegel prüfen |
Umschlag-Zähler ≠ 0 | Zuordnungstoleranz Differenz → Zeitschlitz zu eng oder Anker falsch |

Der Simulationsteil ist Pflicht und deckt genau die Falle ab, die zu Punkt 1 in §3.10.2
führt: eine Testbench setzt den Anker künstlich auf TS1 und **muss** das Umschlagen
reproduzieren (`08 §5.1` `tb_airlock_anchor_negative`).

### 3.11 Regressionsverfahren

#### 3.11.1 Gate-Reihenfolge je Änderungsart

| Änderung an | Pflicht-Stufen | Zusätzlich |
|---|---|---|
Nur Software, Protokollschichten | S0, S2, S3-C, S4 | Betroffenes Luft-Protokoll, ≥ 3 Läufe |
Software, Sprach- oder Empfangspfad | S0, S2, S3 | L3 + L10 |
RTL, ohne Schnittstellenänderung | S0, S1, S3 | S5 vollständig, **§3.10 zwingend**, L1 + L2 |
RTL, mit Schnittstellenänderung an `07` | S0, S1, S3 | S5 vollständig, §3.10, L1…L4, L11 |
Zuweisungs- oder Reservierungsmechanismus | S0, S1, S3-D | **§3.9 vollständig**, L2 + L8, danach L6 |
Kanalcodierung | S0, S1, S2, S3, S4 (fünf Ketten bit-identisch) | L1 |
Zeitbasis, Filter, Dezimation, Taktübergänge | S0, S1, S3 | **§3.10 zwingend**, L2 + L3 |
Konfiguration, Bedienoberfläche | S0, S2 | Kohärenzprüfung `09 §5.2` |

#### 3.11.2 Die fünf Dauer-Regressionen

Diese laufen bei **jeder** Änderung, unabhängig vom Gegenstand, weil sie in V1 die
teuersten Fehler abgedeckt hätten:

1. **Fünf Kanalketten gegen die Referenz-Aufzeichnung**, bit-identisch, automatisiert —
   nicht als einmalige Handrechnung (`05 §5.2`).
2. **Sprachkanal-Codierung gegen die ETSI-Referenzimplementierung**, ≥ 1 000 Rahmen,
   Toleranz null Bits (`12 §5.2`).
3. **Bit-Order aller Mailbox-Worte** über wandernde Eins (`07 §5.1`).
4. **Zeitstempel-Rechnung** über alle Zeitschlitz-, Frame- und Multiframe-Kombinationen
   (`07 §5.1`).
5. **Formale Aufschaukelungs-Sperre** über 10 000 Frames Zufallsstimulus
   (`06 §5.1` `tb_ul_grant_bound`).

#### 3.11.3 Was kein Regressionsnachweis ist

- Ein grüner Funktionstest bei unverändertem Absolutwert der Zeitkopplung — der
  Absolutwert ist kein Kriterium (§3.10.3).
- Ein Vergleich gegen eine Zahl aus einer früheren Sitzung (R-14-11, §4).
- Ein einzelner Luft-Lauf (R-14-10).
- Eine Suite, in der ein Fehlschlag als „kosmetisch" geführt wird
  [CODE docs/OPERATIONS.md:206].
- Eine Zusammenfassung ohne archiviertes Rohlog (R-14-15). Die V1-Rohdaten-Ablage wurde
  ausdrücklich aufgegeben: „Beide nicht mehr aktiv gepflegt"
  [CODE docs/OPERATIONS.md:215].

### 3.12 Nicht zugelassene Verfahren

**In-Circuit-Debug-Kerne im FPGA (Logikanalysator-IP) sind als Verifikationsmethode
ausgeschlossen** (R-14-17). Begründung, in dieser Reihenfolge:

1. **Ressourcen.** Ein solcher Kern belegt Blockspeicher für den Aufzeichnungspuffer und
   zusätzliche Logik für Trigger und Anbindung. Der aktuelle Referenzbuild liegt bei
   37 567 Logikzellen (70,61 %), 15,5 Blockspeicher-Kacheln (11,07 %) und 38 Rechenwerken
   (17,27 %) [BUILD 2026-07-12, `build/reports/impl_utilization.rpt:35,106,121`] —
   **die Logikzellen sind die knappste dieser Größen**. Der Aufzeichnungspuffer liegt damit
   im entspanntesten Budget (`01 §3.9`: ≤ 40 von 140 Kacheln), Trigger- und
   Anbindungslogik dagegen im knappsten. Das Argument trägt über Logikzellen und
   Zeitreserve (Punkt 2), nicht über Blockspeicher.
2. **Zeitverhalten.** Derselbe Build hat eine Zeitreserve von **+0,006 ns**
   [BUILD 2026-07-12, `build/reports/impl_timing.rpt:139`]. Ein zusätzlicher Kern mit
   Fan-out auf beobachtete Netze verschiebt Platzierung und Verdrahtung des gesamten
   Entwurfs. Was danach gemessen wird, ist ein anderes Design als das, das ausgeliefert
   wird.
3. **Iterationszeit.** Jede Änderung der Beobachtungsliste erzwingt einen vollständigen
   Implementierungslauf, gefolgt von der zweistufigen Bitstream-Ladefolge und einem
   Board-Neustart.
4. **Es gibt einen gleichwertigen Weg.** Beobachtbarkeit ist nach P6 Teil der
   Schnittstelle: Zähler in `07`, Zustandsregister, die Uplink-Soft-Mailbox und die
   Roh-IQ-Aufzeichnung des eigenen Empfängers [CODE scripts/capture_rx_iq.sh:1-12] liefern
   dieselbe Information ohne Eingriff in Timing und Fläche. Was damit nicht sichtbar ist,
   fehlt als Zähler — und das ist der Befund, nicht der Kern.

Konsequenz: `scripts/ila_capture.tcl` und `scripts/analyze_ila.py` aus V1 werden nicht
übernommen.

Ebenfalls nicht zugelassen:

- **Textsuche als Urteil** über Simulationslogs (§2.4).
- **Bewertung über den Mittelwert mehrerer Läufe**, wenn das Kriterium je Lauf gilt
  (§3.8.2).
- **Hardware-, Transceiver- oder Treiberschuld** als Abschluss einer Fehlersuche. In V1 lag
  die Ursache jedes untersuchten Fehlverhaltens im eigenen Entwurf (P7). Ein Befund
  „Hardware defekt" ist erst dann ein Befund, wenn er mit einem Registerabzug und einer
  reproduzierbaren Messung belegt ist.
- **Slice-Prozent** als Ressourcen- oder Abnahmekriterium (`CONVENTIONS §6.4`).

### 3.13 Abnahme-Matrix V2 Stufe 1

Eine Zeile je Kapitel. „Kriterium" nennt die abnahmerelevante Kernaussage; die
vollständige Kriterienliste steht im §5 des jeweiligen Kapitels und wird hier nicht
wiederholt.

| Kap. | Kriterium (Kern) | Methode | Werkzeug | Bestanden, wenn |
|---|---|---|---|---|
| **01** | Takt-/Reset-Struktur, Symboltakt, Taktüberwachung, Hochlauf-Folge, Transceiver-Datenformat, Sendekanal, Duplex-Ablage | S0-8/9, S1, S5 | `run_units`, Vivado-Reports, `board/ctrl` | Alle V-01-1…9 erfüllt; 0 unsichere Taktübergänge; WNS ≥ +0,250 ns; 3/3 Kaltstarts |
| **02** | Frontend bit-exakt gegen Fixpunktmodell; Filterkoeffizienten; alle vier Symbolübergänge; Zeitrückgewinnung; Korrelator inkl. Falschalarm-Messreihe; Burst-Raster gegen Normtabellen; Kette gegen Referenz-Decoder | S1, S3-B, S4, S5 | `run_units`, `decode_dl`, `board/ctrl` | Bit-exakt; Sample- und Dibit-Raten im Fenster; Sättigungs- und Überlaufzähler 0 über 60 s; ≥ 3 Läufe |
| **03** | Phasenunabhängigkeit des Uplink-Synchronisation; Burst-Geometrie + Prüffeld; Soft-Kennlinie flach über Amplitude; Vorzeichenkonvention; Ring-Randfall; RTL ≥ Python auf demselben WAV | S1, S3-B, S6 | `run_units`, `decode_ul`, `check_*`-Nachfolger | Alle V-03-1…6 (`03 §5.1`) erfüllt; Prüffeld-Erfolg auf allen Sub-Symbol-Phasen; Roh-Bitfehlerrate ≤ 3 %; Soft-Fehlerrate ≤ Hart-Fehlerrate **im selben Mitschnitt**; ≥ 3 Sprechtasten-Läufe |
| **04** | Modulator gegen unabhängige Vektoren; Filter-Polyphasen; Burst-Register gegen Normtabellen; Phasenbalance; Zeitbasis-Umschläge; Zeitplan-Speicher; Vorabruf; Verteiler-Priorität; Warteschlange inkl. Verwurf und Priorität; Ausrichtung jeder Warteschlangen-Quelle | S1, S3-A, S4, S5, L1 | `run_units`, `run_chain`, Fremdempfänger | Trainingssequenz bit-genau zurückgewonnen; Bitfehlerrate 0 rauschfrei; Korrelation ≥ 0,95; Fremdempfänger dekodiert Systeminformation; Unterlauf/Überlauf/Sättigung/Phasenbalance/Fristzähler = 0 nach 10 min |
| **05** | Primitive gegen ETSI (nicht gegen sich selbst); fünf Ketten bit-identisch gegen die Referenz; Software gegen die bestehenden RTL-Vektoren; kein zweiter Codierer | S0-1, S1, S2, S4 | `run_units`, `make check`, `compare_gold` | Alle Norm-Nachrechnungen bestanden; 5/5 Ketten bit-identisch; 4/4 Vektor-Paritäten; jede Codier-Konstante genau einmal im Repository |
| **06** | Infowort-Musterliste vollständig und geschlossen; Frame-18-Positionsregel; Auslösefilter; Fenster-Buchhaltung; **formale Aufschaukelungs-Sperre**; Downlink-Füllregeln; Uplink-Kopf-Offsets; Zusammensetzung inkl. Kollision und Zeitgeberablauf | S1, S2, S4, **§3.9**, L2/L6/L8 | `run_units`, `make check`, `compare_gold`, `air/session` | Alle V-06-1…8 (`06 §5.1`) bestanden, insbesondere V-06-5 als formale Aufschaukelungs-Sperre; kein Infowort außerhalb der Liste über einen Hyperframe; kein Verkehrsmuster auf einem Synchronisations-Burst; §3.9 vollständig bestanden; Fragmentkette 3/3 vollständig |
| **07** | Bus-Konformität; Adressraum ohne Aliasing; Rücksetzwerte aus generierter Tabelle; drei Mailboxen nach gemeinsamem Prüfkörper; zwei Erzeuger auf einem Fenster; Bit-Order über wandernde Eins; Zeitstempel über alle Kombinationen; atomare Zeitkopplungs-Differenz; Inhaltsunabhängigkeit der Zuweisung; kein Register ohne Treiber/Senke | S0-2/4/6, S1, S3-C, S5, L11 | `run_units`, `board/ctrl` | Alle Testbenches aus `07 §5.1` bestanden; Adressfehlerzähler 0; alle Verwurfszähler 0 über 10 min; Folgenummer lückenlos; Abfragelast < 5 % eines Kerns |
| **08** | Zeitraster über > 1 Hyperframe; **Zeitkopplung: Schrittweite**; Anker-Negativtest; Zuweisungs-Frist; Reservierungs-Haltedauer; Zusammensetzungsfenster; Frame-Arithmetik über den Hyperframe-Umschlag; Slot-Frist unter Laständerung | S1, S5 **§3.10**, L2/L6 | `run_units`, `board/ctrl` | Schrittweite 85/6 ms ± 1 Symboldauer; 4 Werte monoton in `[0, 1 Frame)`; Streuung ≤ 1 Symboldauer; Fristzähler 0; Unterlaufzähler 0 über 10 000 Slots |
| **09** | LLC-Kopflängen über alle 16 Codepunkte inkl. der drei Regressionsvektoren gegen die V1-Abweichungen (`09 §5.1`); Rundlauf; Prüffolge für kurze Längen; Folgenummern gegen die Referenzfolge; Elementmechanik; Erbauer bit-identisch gegen die Referenz außer Zell-/Gerätefeldern; Konfigurations-Kohärenz; Zufallsbeschuss unter Speicherprüfer | S0, S2 (`check-asan`), S4, L2 | `make check-asan`, `compare_gold` | Alle Unit-Tests bestanden; quittierter Anmeldetyp = angeforderter; 8 Luft-Punkte je 3/3 |
| **10** | Alle Erbauer und Parser; Ursachentabelle; Zustandsübergangstabelle Zeile für Zeile; beide Sprechrecht-Pfade auf identischen Platzinhalt; Mehrschlitz-Vergabe; Zeitgeber inkl. Sättigung; Kennungs-Vorrat | S2 (`check-asan`), S4, L3/L4/L5/L9/L11 | `make check-asan`, `compare_gold`, `air/session` | A1…A10 je ≥ 3 Läufe bestanden; Späteinstieg über Einschalten nachgewiesen; gestagete PDUs < 10/s |
| **11** | Kette bauen/zusammensetzen für **jede** Nutzlastlänge; Randfall leeres Endfragment; Uplink-Zusammensetzung mit getrennten Zählern je Grund; Füll-/Löschregel; Transportschicht-Kenner; Statusnachricht | S2, S3, S4 (unter Vorbehalt §3.6.3), L6 | `make check`, `run_chain`, `compare_gold` | Nutzdaten bit-identisch für jede Länge 1…131; jeder Randfall erhöht genau seinen Zähler; 6 Luft-Punkte je 3/3; 10 Anmeldungen nach dem Umstellen der Zusage erfolgreich |
| **12** | Sprachketten-Rundlauf; Klassen-Umsortierung; Prüffelder gegen Referenztabellen; Vorzeichen-Anpassung; Bit-Packung; Bad-Frame-Behandlung; kein Heap; **Gleichheit mit der ETSI-Referenzimplementierung** | S2, S4, L3/L4/L10 | `make check`, `compare_gold`, `air/session` | 432 bzw. 274 Bits identisch zur Referenz, Toleranz null; Fehlerrate der Sprachrahmen ≤ 5 % nah / ≤ 10 % auf 50 m; Mailbox-Überlauf und -Zerreißen 0; alle Negativtests aus `12 §5.5` |
| **13** | Schichten- und Strangschnitt statisch nachgewiesen; Ringe, Streuwerttabelle, Konfigurationsparser, nebenläufiges Schreiben, HAL gegen Registermodell, Zustandsdatei; Rechenzeit und Entkopplung auf dem Ziel; Konfigurationswirkung, Neustartfestigkeit, Hyperframe-Fortschreibung, Diagnosetauglichkeit (`13 §5.1`…`§5.4`) | S0, S2, S5 (`13 §5.3` M1…M6), L11 (`13 §5.4`) | `make check`, `board/ctrl`, `air/session` | V-13-1…9a je 0 Treffer; V-13-10…15 bestanden; M1…M6 gefahren: `rx_deadline_miss_cnt` = 0, `rx_iter_max_us` ≤ 4 000 µs, `REG_MB_UL_DROP_CNT` = 0, und in M6 **kein** Anstieg von `rx_iter_max_us`; V-13-16…21 je ≥ 3 Läufe. Restunsicherheit: die Rechenlast-Zahlen aus `13 §3.12` sind bis zum Vorliegen von M1…M5 Annahmen (§6 O-14-1) |
| **quer** | Aufschaukelung | **§3.9** | `run_chain`, `air/session` | Schleifenverstärkung ≤ 1 über alle Laststufen; Sättigung ab Stufe 4; 8 Luftbedingungen erfüllt |
| **quer** | Zeitkopplung | **§3.10** | `board/ctrl` | Schrittweite eingehalten; Absolutwerte nur protokolliert |
| **quer** | Abdeckung des Vergleichs-Decoders | §3.6.4 | `decode/coverage` | Jede Zelle der Matrix „Endpunkt erreicht" oder begründet |

**Freigabe von Stufe 1** liegt vor, wenn jede Zeile dieser Matrix bestanden ist und die
Ergebnisse nach §2.3 archiviert sind. Eine Zeile ohne ausgeschriebenes, gemessenes
Kriterium ist kein Bestehen; ein Vermerk „noch zu liefern" oder „Kriterium offen" in der
Spalte „Bestanden, wenn" blockiert die Freigabe.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Wiederholungen je Luft-Test | **≥ 3** | Projektregel, aus der Streuung der Einzelmessung abgeleitet [MESS 2026-05-17 ff.] | Ein Einzellauf trifft je nach Tageslage jedes Urteil; die V1-Amplituden-Messreihe zeigt Sprünge zwischen benachbarten Läufen |
| Tagesvariabilität Roh-Bitfehlerrate Uplink | 1,4 – 3,5 % | [MESS 2026-05-18] | Liegt in derselben Größenordnung wie die zu messenden Effekte. **Deshalb R-14-11:** A/B nur innerhalb einer Sitzung |
| Fehlerrate der Sprachrahmen, Betriebswert | Nahfeld Soft **0 %** (2/840 Bursts), Hard 1 % (11/840); auf 50 m 5–6 % | [MESS 2026-05-25 / 2026-05-30], normativ `12 §4` | Abnahmegrenzen 5 % Nahfeld / 10 % auf 50 m (`12 §5.4`, R-12-08) liegen bewusst **über** den Betriebswerten, weil die Roh-Bitfehlerrate tagesvariabel 1,4–3,5 % ist. Der Wert 4,7 % bei Korrelatorschwelle 11 (6,1 % bei 10) [MESS 2026-05-17] ist der Stand **vor** der Offset- und Amplitudenkorrektur und taugt nicht als Betriebswert |
| Prüffeld-Erfolg Uplink-Signalisierung | 93 % nach Verstärkungs- und Schwellenkorrektur | [MESS 2026-05-22] | Abnahmegrenze 90 % (`05 §5.4`); darunter ist die Amplitudenkette nicht im Arbeitspunkt |
| Normative Obergrenze Nachrichten-Ausfallrate **Basisstations-Empfänger** | Halbschlitz-Uplink `SCH/HU` 8 %, Vollschlitz-Uplink `SCH/F` 8 % (Klasse B, TU50, > 300 MHz) — beides Uplink, weil Tabelle 6.31 die BS-**Empfänger**-Tabelle ist; Downlink-Grenzwerte stehen in den MS-Empfänger-Tabellen | [ETSI Tabelle 6.31] | Bezugsrahmen für die eigenen Grenzen: die Projektgrenze 90 % Prüffeld-Erfolg ist strenger als die Norm fordert |
| Normative Obergrenze Bitfehlerrate ungeschützte Bits | 0,01 % statisch, 0,4 % TU50 bei −85 dBm | [ETSI Tabelle 6.28] | Die eigene Roh-Bitfehlerrate liegt darüber (`03` O-03-1); das ist bekannt und begrenzt die erreichbare Sprachqualität |
| Normative Obergrenze unentdeckt falscher Nachrichten | < 10⁻⁵ für Broadcast-Synchronisation, Halb- und Vollschlitzkanäle; < 10⁻⁴ für den Zugriffszuweisungskanal | [ETSI §6.6.2.2.0] | Grenzwert für **falsch positive** Prüffeld-Urteile. Ein Prüffeld-Test, der nur „bestanden" zählt, prüft das nicht — deshalb die Negativvektoren in §5.2 |
| Referenz-Anteil reservierter Kontrollkanal-Slots | 0,71 % (13 von 1 834) | [GOLD, `06 §3.9.6`] | Zielgröße; Abnahmegrenze 5 % (§3.9.4) |
| Kontrollkanal-Slots je Sekunde | 17,65 gerechnet, 17,64 gemessen (1 834 / 103,98 s) | [ETSI §4.5.2], [GOLD] | Bezugsgröße jeder Ratenrechnung in §3.9 |
| Obergrenze Zuweisungsrate mit Vorgabewerten | ≤ 8,8/s | Rechnung aus `GRANT_REPEAT = 2`, `GRANT_GAP = 4` Frames [ANNAHME, `06 §5.4`] | Wird sie überschritten, ist entweder der Auslösefilter unwirksam oder die Konfiguration abweichend |
| Fragmentierungs-Auszeit / Reserviert-Zugriffs-Auszeit des Endgeräts | 9 bzw. 18 Downlink-Signalisierungsframes (≈ 510 ms / 1,02 s) | [ETSI Annex B.1] | Toleranzreserve der Zuweisung: eine um einen Frame verspätete Zusage ist nicht verloren. Eine **nicht slot-feste** Zusage mit unbegrenzten Wiederholungen ist das Problem |
| Fragmente-Verwurfsschwelle des Endgeräts | ≥ 4 Zeitschlitze ohne Fragment | [ETSI Annex B.2, N.203] | Untergrenze für das eigene Zusammensetzungsfenster (`08 §4`) |
| Toleranz Zeitkopplung, Streuung je Slot | ± 14 µs gemessen; Grenze 1 Symboldauer ≈ 55,6 µs | [MESS 2026-05-25] | Größere Streuung ⇒ Synchronisations-Anker instabil |
| V1-Testbench-Bestand | 69 Testbenches, davon 48 in keinem Runner; 37 ohne Urteilszeile; 19 mit `$fatal` | [CODE `ls tb/*.v`, `grep` 2026-07-25] | Ausgangslage, gegen die S0-3 und §2.4 gerichtet sind |
| V1-Host-Testbestand | 17 Testprogramme, 11 im Sammelziel, 4 ohne jedes Ziel | [CODE sw/Makefile:134] | dito |
| V1-Vektorgeneratoren | 18 in `tb/vectors/` und 10 weitere in `scripts/` (von 12 `scripts/gen_*.py`; `gen_code_map.py` und `gen_code_analysis_pdf.py` erzeugen keine Testvektoren); das Sammelskript ruft **7** auf, der zweite Runner **12** | [CODE scripts/gen_all_vectors.sh:32-38, tb/vectors/run_all_generators.py:9-22, `ls` 2026-07-25] | Zwei unvollständige Listen an zwei Orten — Grund für das erzeugte Manifest (R-14-06) |
| V1-Vollständigkeit des Referenz-Decodes | 24 von 51 adressierten Downlink-PDUs oberhalb der MAC-Schicht ausgewertet; die 27 Halbschlitz-PDUs nicht | [GOLD, §3.6.3] | Grund für R-14-08 und R-14-09 |

---

## 5. Verifikation

Dieses Kapitel beschreibt Prüfungen. Es braucht selbst eine — sonst entsteht genau die
Lage, die §3.6.3 dokumentiert: ein Werkzeug, dessen Lücke erst Jahre später auffällt.

### 5.1 Mutationsprobe (R-14-16)

Für jede Suite der Stufen 1 und 2 wird je geprüfter Kernfunktion **eine** Mutation in den
Prüfling injiziert und die Suite unverändert laufen gelassen. Die Suite muss jede Mutation
erkennen. Pflicht-Mutationen:

| Mutation | Muss erkannt werden von |
|---|---|
Ein Bit in einer Interleaver-Permutation vertauschen | `05` Stufe 1 |
Ein Tap im Mutter-Code entfernen | `05` Stufe 1 (deshalb 5 Ausgangsquadrupel, nicht 4) |
Verschleierungs-Startwert um 1 verschieben | `05` Stufe 1 und Stufe 2 |
Feldgrenze im Burst-Raster um 1 Symbol verschieben | `02`/`04` Burst-Tests — **die Mutation, die V1 nicht erkannt hat** [CODE tb/tb_tetra_burst_demux.v:6-17] |
Ein Bit in einem Mailbox-Wort um eine Position verschieben | `07` Bit-Order-Test (wandernde Eins) |
Zeitschlitz-Umrechnung um 1 verschieben | `07` Zeitstempel-Test, S0-5 |
Zuweisungs-Auslösefilter deaktivieren (auch reservierte Unterschlitze lösen aus) | §3.9.3 Bedingung 4 |
Reservierung einen Slot später setzen | §3.9.3 Bedingung 6 |
Endfragment-Kopf von 21 auf 4 bit ändern | `11` Kettentests — der Fehler, den der abgeschaltete V1-Test nicht meldete [CODE sw/test_sds_dl_frag.c:60-62] |
Anmelde-Anker auf TS1 setzen | `08` Anker-Negativtest |

Eine Suite, die eine Pflicht-Mutation überlebt, ist unvollständig und wird ergänzt, bevor
sie als Gate gilt.

### 5.2 Negativvektoren und Falsch-Positiv-Prüfung

Jeder Prüffeld-Test führt neben gültigen Vektoren mindestens 10⁴ **verfälschte** Vektoren
je Kanal (zufällige Einzel- und Doppelbitfehler nach der Codierung). Kriterium: kein
verfälschter Vektor wird als gültig gemeldet. Damit wird die Größe geprüft, die die Norm
begrenzt — die Wahrscheinlichkeit unentdeckt falscher Nachrichten [ETSI §6.6.2.2.0] —
und nicht nur die Erkennung korrekter Vektoren.

### 5.3 Selbsttest des Runners

| Prüfung | Erwartung |
|---|---|
Testbench, die absichtlich `RESULT: FAIL` ausgibt | Runner endet mit ≠ 0, Eintrag als Fehlschlag |
Testbench ohne Urteilszeile | Fehlschlag (R-14-02), **nicht** „durchgelaufen" |
Testbench, die ins Zeitlimit läuft | Fehlschlag |
Testbench, die das Wort „FAIL" in einer Informationszeile ausgibt, aber `RESULT: PASS` liefert | Bestanden — kein Falsch-Alarm durch Textsuche |
Manifest-Eintrag ohne Datei / Datei ohne Manifest-Eintrag | S0-3-Fehler |
Vektor-Erzeuger zweimal gelaufen | bit-identische Ausgabe (R-14-06) |

### 5.4 Selbsttest des Vergleichs-Decoders

1. **Abdeckungsmatrix** nach §3.6.4 auf einer synthetischen Aufzeichnung, in die je
   Bursttyp und Block eine bekannte PDU jeder Schicht eingebettet ist: alle wiedergefunden.
2. **Regressionsprobe gegen die bestehende Referenz:** derselbe Decoder-Stand reproduziert
   die in `05 §5.2` als bestanden geführten fünf Ketten bit-identisch.
3. **Aggregator-Probe:** jede Schichtzeile ist genau **einem** Block zugeordnet; eine
   Aufzeichnung mit zwei verschiedenen PDUs in Halbschlitz 1 und 2 darf nicht zu einer
   flachen Liste zusammenfallen [Gegenbefund CODE scripts/parse_reference_decode.py:229-236].
4. **Unabhängigkeitsprobe:** der Decoder importiert keinen Baustein aus dem Prüfling und
   keinen aus einem Vektor-Erzeuger. Gegenbefunde in V1:
   [CODE scripts/check_ul_wav_rtl_emu.py:13-14],
   [CODE scripts/decode_pdu.py:5] — Letzterer leitet seine PDU-Layouts aus der externen
   Rust-Referenz ab, nicht aus dem Normtext; das ist als Kategorie **X** zulässig, aber
   nur, wenn die Rust-Referenz selbst gegen N abgenommen ist. Diese Abnahme fehlt.

### 5.5 Prüfung der Abnahme-Matrix

Ein Werkzeug liest die §5-Abschnitte der Kapitel `01`…`13` und die Matrix §3.13 und
vergleicht: jedes Kriterium eines Fachkapitels erscheint in der Matrix, jede Matrixzeile
verweist auf ein existierendes Kapitel und einen existierenden Abschnitt. Abweichung =
Fehlschlag. Ohne diese Prüfung driftet die Matrix genauso auseinander wie die
V1-Testtabelle in der Betriebsdoku, die 22 von 22 bestandenen Modulen für einen Stand
meldet, in dem zwei der referenzierten Dateien nicht mehr existieren
[CODE docs/OPERATIONS.md:190 gegen run_all_tests.sh:218-220].

---

## 6. Offene Punkte

**O-14-1 — Die Rechenlast-Kriterien aus `13` stehen auf ungemessenen Umrechnungsfaktoren.**
`13 §5` liegt vollständig vor (statische Prüfungen §5.1, Einheiten- und
Nebenläufigkeitstests §5.2, Ziel-Messung §5.3 M1…M6, Luft-Abnahme §5.4) und ist in die
Matrix §3.13 eingearbeitet. Offen bleibt der Bezugspunkt: alle Lastzahlen in `13 §3.12`
beruhen auf einem angenommenen Faktor 11 zwischen Host und Cortex-A9 (`13 §6` O-13-1), und
die Buszeit je Registerzugriff ist mit 100 ns angesetzt statt gemessen (`13 §5.3` M5).
Damit sind die Abnahmegrenzen dieser Zeile heute Annahmen, nicht abgeleitete Werte.
*Empfehlung:* M1…M5 aus `13 §5.3` vor der ersten Luft-Abnahme fahren, die Faktor-11-Spalte
durch Messwerte ersetzen und die Zahlen als `[MESS]` in `13 §4` und hier in §4 nachtragen.
Bis dahin ist das tragende Kriterium dieser Zeile nicht die gerechnete Last, sondern
`rx_deadline_miss_cnt` = 0 und M6 (Entkopplungsnachweis) — beide sind vom Faktor unabhängig.
Ebenfalls noch nicht durch eine Messung gedeckt: die Kernbindung (`13 §6` O-13-2) und die
Zahl der Wiederholungen nach einem Neustart (`13 §6` O-13-5).

**O-14-2 — Die Referenz-Aufzeichnung ist für den Halbschlitz-Pfad unbelegt.** §3.6.3 ist
nachgewiesen, aber nicht behoben: die Dateien in `docs/reference_decode/` stammen aus einem
Decoder-Stand ohne obere Schichten für diesen Pfad, und der heutige Aggregator würde die
Zeilen selbst dann nicht übernehmen. *Empfehlung:* Decoder und Aggregator zuerst nach
R-14-08 ertüchtigen, dann die Aufzeichnung aus den vorhandenen WAV-Dateien **neu erzeugen**
und die Abdeckungsmatrix mit archivieren. Bis dahin trägt jede Abwesenheits-Aussage über
diesen Pfad einen Vorbehalt — konkret die Feststellung in `11 §5.3`, die Referenz enthalte
keine Kurznachricht.

**O-14-3 — Zwei Aufzeichnungen fehlen im Repository.** Die Werte
`capacity_allocation = 0x30`, das Halte-Infowort und der 21-bit-Endfragment-Kopf stammen
aus Mitschnitten, die nicht abgelegt sind; die zugehörigen V1-Kommentare verweisen auf
Burst-Nummern, die nicht nachprüfbar sind (`11 §5.3`). *Empfehlung:* Beide Mitschnitte als
Referenzdecode aufnehmen. Solange das nicht geschehen ist, sind diese Werte `[MESS]` und
nicht `[GOLD]`, und der Reservierungs-Teil der Abnahme stützt sich ausschließlich auf den
eigenen Mitschnitt.

**O-14-4 — Der Zuweisungs-Mechanismus ist entschieden, die Zähler-Abnahme bleibt zu fahren.**
Die frühere Fassung dieses Punktes hielt fest, dass `06` und `07` zwei unvereinbare
Zuweisungs-Mechanismen beschrieben (Magazin gegen parametrischen PL-Block) und dass die
Zählernamen deshalb nicht aufeinander abbildbar waren. **Entschieden ist:** normativ ist der
Magazin-Mechanismus aus `06 §3.9` — nur er hält `05_CHANNEL_CODING` R-05-02 ein (kein
Kanalcodierer für Nutzdaten in Hardware) —, und `07 §3.1.6` trägt seine Registerseite
(`REG_UL_ASSIGN_CFG` mit `GRANT_*`, `REG_GRANT_MAG_INDEX`/`_DATA`/`_CTRL`/`_GO`,
`REG_UL_ASSIGN_STATE`). Die abschließende Zählerliste steht in **`06 §3.13`** (14 Zähler,
nicht 7) und ist in `07 §3.1.8` mit je eigener Adresse verankert:
`REG_GRANT_TRIGGER_CNT`, `REG_GRANT_EMIT_CNT`, `REG_GRANT_REGRANT_CNT`,
`REG_GRANT_USED_CNT`, `REG_GRANT_SUPPRESSED_CNT`, `REG_GRANT_STARVED_CNT`,
`REG_GRANT_MAG_OVERWRITE_CNT`, `REG_GRANT_PREEMPT_CNT`, `REG_GRANT_LATE_CNT`,
`REG_RESV_SLOT_CNT`, `REG_MCCH_SLOT_CNT`, `REG_AACH_F18_CLCH_CNT`,
`REG_UL_NTS2_DETECT_CNT`, `REG_STEAL_OVERRIDE_CNT`. **Offen bleibt** nur die Abnahme selbst:
für keinen dieser Zähler existiert ein gemessener V1-Vergleichswert, weil V1 sie nicht hatte
(`08` O-08-4). Die Kriterien in §3.9 sind damit strukturell auswertbar, aber ihre Grenzwerte
sind bis zur ersten Messreihe [ANNAHME] (R-14-14).

**O-14-5 — Kein gemessener Bezugswert für die Schleifenverstärkung.** §3.9.3 fordert
`G ≤ 1`, aber es liegt kein gemessener V1-Wert vor, gegen den man die Empfindlichkeit des
Verfahrens kalibrieren könnte — der V1-Befund ist qualitativ („Warteschlange lief über")
[MESS 2026-07-11]. *Empfehlung:* Beim ersten Aufbau des Simulationsteils bewusst die
V1-Kopplung nachbauen (Zuweisung über die geteilte Warteschlange, Auslösung auch in
reservierten Unterschlitzen) und `G` in dieser Konfiguration messen. Dieser Wert ist der
Nachweis, dass der Test die Spirale überhaupt sieht — ohne ihn ist ein Ergebnis
`G ≤ 1` nicht aussagekräftig. Der Messwert ist danach als `[SIM]` in §4 nachzutragen.

**O-14-6 — Zulässige Zahl der Simulator-Abweichungen.** §3.2.1 verlangt, dass jedes Modul
in beiden Simulatoren besteht, und verbietet Waiver. Ob das mit dem
Uplink-Viterbi-Konstrukt erreichbar ist, ohne die RTL zu ändern, ist offen — in V1 braucht
er `--relax` [SIM 2026-05-30]. *Empfehlung:* Die Vorwärtsreferenz in V2 auflösen (das
Konstrukt ist vermeidbar) statt eine Simulator-Option zu normieren. Falls das
Ressourcen- oder Timing-Kosten hat, ist die Entscheidung in `03` zu treffen und hier zu
referenzieren.

**O-14-7 — Abdeckungsmaß für die Software fehlt.** Die Stufen S0-3 und §5.1 prüfen, dass
Tests existieren und wirksam sind, aber es gibt kein Maß dafür, welcher Anteil der
Protokoll-Zustandsübergänge je erreicht wird. *Empfehlung:* Zeilen- und
Zweigabdeckung im Sammelziel `check` mitmessen und als Trend führen, **nicht** als
Abnahmegrenze — eine Abdeckungszahl als Gate erzeugt Tests, die Zeilen berühren, ohne zu
prüfen. Verbindliches Gate bleibt die Mutationsprobe.

**O-14-8 — Kein normativer Vorgabewert für `IMM`, `WT` und `Nu`.** §3.9.3 braucht diese drei
Werte, um das Endgeräte-Verhaltensmodell zu parametrieren, und §3.9.4 Bedingung 6 rechnet
den Grenzwert der Wiederholrate daraus. `06` legt sie nicht fest; belegt ist nur, was V1
aussendet: `IMM = 1`, `WT = 2`, `Nu = 3`, in allen drei Aussendungspfaden gleich
[CODE sw/tetra_hal.c:804-809, :843-848, :1063-1068]. Solange kein Vorgabewert normativ ist,
hängt eine Abnahmegrenze an einer Code-Stelle. *Empfehlung:* `06` legt die
Zugriffsparameter der Zelle als Vorgabewerte fest (mit `WT`/`Nu`-Begründung gegen die
Zuweisungsfrist aus `08 §3.3.1`), §3.9 zitiert sie dann von dort. Bis dahin wird jeder
Grenzwert im Messprotokoll mit dem tatsächlich ausgesendeten Wert nachgerechnet und dieser
Wert im Sitzungsdatensatz (§2.3 `env.json`) mit archiviert.
