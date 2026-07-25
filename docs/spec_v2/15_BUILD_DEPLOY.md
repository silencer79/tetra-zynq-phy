# 15 — Übersetzung, Auslieferung und Inbetriebnahme

**Scope:** Der vollständige mechanische Weg von den Quellen zum laufenden System:
Werkzeugkette mit Versionen, Synthese- und Implementierungsablauf einschließlich
Randbedingungsdateien, Übersetzung der Software für die Zielarchitektur, Erzeugung
der Ladeabbilder, Übertragung auf das Zielsystem, verbindliche Reihenfolge der
Inbetriebnahme, automatischer Start beim Hochlauf, Prüfschritte nach jeder
Auslieferung.

**Nicht hier:** Verifikations-*Strategie*, Testvektoren, Gold-Vergleich,
Air-Test-Protokolle und Abnahmekriterien für Funktion — alles in
`14_VERIFICATION.md`. Plattform-, Takt- und Ressourcenbeschreibung sowie die
board-interne Bring-up-Sequenz B1…B13 — `01_PLATFORM.md` §3.7/§3.8.
Registeradressen — `07_PS_PL_CONTRACT.md`. Dienst- und Thread-Modell der
Software — `13_SW_ARCHITECTURE.md`.

**Abhängigkeiten:** `00_OVERVIEW.md` (Prinzipien P1–P7), `01_PLATFORM.md`
(Bring-up, Ressourcen-Budget), `07_PS_PL_CONTRACT.md` (Registernamen).

---

## 1. Anforderungen

| Nr. | Anforderung |
|---|---|
| **R-15-01** | Jedes Erzeugnis (Bitstream, Ladeabbild, ARM-Binärdateien) entsteht aus **einem** Kommando pro Ziel, ohne interaktive Schritte und ohne manuelles Setzen von Umgebungsvariablen. Die benötigten Werkzeugversionen sind in einer Datei festgeschrieben und werden vor dem Bau geprüft; Abweichung bricht ab. |
| **R-15-02** | Die Liste der Hardware-Quelldateien wird aus dem Quellbaum **abgeleitet**, nicht handgepflegt. Eine Datei im Quellbaum, die nicht in den Bau eingeht, und ein Listeneintrag ohne Datei sind beide ein Baufehler. |
| **R-15-03** | Der Hardware-Bau endet mit Exit-Code ≠ 0, wenn WNS < 0, WHS < 0, TNS-Failing-Endpoints > 0 oder ein unaufgelöstes Modul (Black Box) im Netzlistenbericht steht. Ein Ladeabbild mit negativem Slack darf nicht ausgeliefert werden. |
| **R-15-04** | Jede Zeile der Randbedingungsdateien muss mindestens ein Objekt treffen. Ein `set_property`/`set_multicycle_path`/`set_false_path` ohne Treffer ist ein Baufehler; `-quiet` ist nur mit begründendem Kommentar zulässig. |
| **R-15-05** | Die Cross-Toolchain wird über einen **absoluten Pfad** oder ein geprüftes Ziel-Triplett festgelegt. Ein Bau, der die Toolchain über die Suchpfad-Reihenfolge findet, ist unzulässig. |
| **R-15-06** | Die Erzeugung des Ladeabbilds ist deterministisch: gleiche `.bit` → bit-identische `.bin`. Nach der Übertragung wird die Prüfsumme auf dem Zielsystem gegen die lokale verglichen; Abweichung bricht die Auslieferung ab. |
| **R-15-07** | Das FPGA-Abbild wird beim Hochlauf **zweimal** geladen, mit AD9361-Konfiguration zwischen den beiden Ladevorgängen und erneuter Konfiguration danach (§3.7). Ein einzelner Ladevorgang ist unzulässig. |
| **R-15-08** | Nach der Übertragung eines neuen FPGA-Abbilds wird das Zielsystem **neu gestartet**. Erst der Neustart erzeugt den Zustand, auf den sich alle weiteren Prüfungen beziehen. Messungen vor dem Neustart sind ungültig. |
| **R-15-09** | Kein Lese- oder Schreibzugriff auf die PL-Registerapertur ohne unmittelbar vorausgehende Prüfung, dass der FPGA-Manager `operating` meldet. Die Regel gilt für **jeden** Pfad: Diagnoseskripte, Dienste, Bedienoberflächen-Endpunkte, Einzelabfragen von Hand. |
| **R-15-10** | Im Kontext des Dienstestarters werden Transceiver-Attribute ausschließlich über direkte sysfs-Schreibvorgänge gesetzt. Das Attribut-Kommandozeilenwerkzeug der IIO-Bibliothek darf dort nicht aufgerufen werden (§3.7.2). |
| **R-15-11** | Ein neuer Dienst wird im **selben** Änderungsschritt in die Dienstetabelle eingetragen. Aus dieser einen Tabelle leiten sich Auslieferung, Beenden vor der Auslieferung, automatischer Start, `ExecStop` der Startdefinition und Prüfliste ab. Ein Dienst, der nur an einer dieser Stellen steht, ist ein Fehler. |
| **R-15-12** | Jede Auslieferung endet mit der Dienste-Prüfung nach §3.10 und meldet deren Ergebnis. Von jedem Dienst läuft genau **eine** Instanz; mehr als eine ist ein Fehlerzustand und wird beendet. |
| **R-15-13** | Auslieferungsskripte enthalten keine HF-Parameter, keine Zellparameter, keine Schwellwerte und keine Registeradressen. Sie transportieren Dateien und lösen Abläufe aus. |
| **R-15-14** | Zieladresse, Zugangsdaten und Zielpfade stehen in **einer** Datei. Kein Skript trägt eine eigene Vorgabeadresse. |
| **R-15-15** | Der Bauform-Bezeichner des Bausteins steht an genau einer Stelle und lautet `xc7z020clg400-1`. Synthese, Simulation, IP-Erzeugung und Kopfkommentare verweisen darauf (§3.13). |
| **R-15-16** | Die Konfigurationsdatei des Zielsystems wird bei der Auslieferung nur **angelegt, wenn sie fehlt**, und niemals überschrieben. Sie ist die einzige Quelle für Zell- und HF-Parameter; jeder daraus abgeleitete Registerwert wird beim Hochlauf gesetzt **und** zurückgelesen (§3.8.3). |
| **R-15-17** | Die Teilschritte sind einzeln aufrufbar. Welche Änderung einen Vollbau erzwingt und welche nicht, ist in §2.4 abschließend festgelegt. |
| **R-15-18** | Während jeder Rekonfiguration der PL und während der gesamten Inbetriebnahme bis zum Erreichen des Gesundheitsgatters ist der Sendepfad gedämpft. Der operative Sendepegel wird als letzter Schritt gesetzt. |
| **R-15-19** | Jedes ausgelieferte Abbild trägt eine im Betrieb lesbare Bau-Kennung. Die Kennung wird aus dem Quellstand abgeleitet, nicht aus der Uhrzeit. Werkzeugberichte werden je Abbild archiviert. |
| **R-15-20** | Die Erstinstallation eines Boards (Betriebssystem-Vorbereitung, Kernel-Modul, Aktivierung des Startdienstes) ist eine dokumentierte, einmalige Prüfliste (§3.11) und nicht Teil der wiederkehrenden Auslieferung. |

---

## 2. Architektur / Aufbau

### 2.1 Werkzeugkette

| Werkzeug | Version | Rolle | Beleg |
|---|---|---|---|
| Vivado | 2022.2 (Build 3671981) | Synthese, Implementierung, Bitstream, Blockdesign | [BUILD 2026-07-12 build/reports/impl_utilization.rpt, Kopfzeile „Tool Version"] |
| `bootgen` | aus derselben Vivado-Installation | `.bit` → `.bit.bin` für den FPGA-Manager | [CODE scripts/deploy.sh:154–160] |
| ADI-HDL-Bibliothek | Quelle der IP `analog.com:user:axi_ad9361:1.0` | Blockdesign-IP | [CODE scripts/create_bd.tcl:52–90] |
| Cross-Compiler | GCC 11.2.0, Ziel-Triplett `arm-xilinx-linux-gnueabi` (Vitis-2022.2-Beilage) **oder** GCC 13.x, Triplett `arm-linux-gnueabihf` (Ubuntu-Paket `gcc-13-arm-linux-gnueabihf`) | ARM-Userspace | [MESS 2026-07-25 — beide auf dem Bauhost vorhanden: `arm-xilinx-linux-gnueabi-gcc.real (GCC) 11.2.0` bzw. `arm-linux-gnueabihf-gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`; `arm-linux-gnueabihf-gcc` löst über den Suchpfad auf die Vitis-Variante auf (`-dumpmachine` → `arm-xilinx-linux-gnueabi`)] |
| Icarus Verilog | 12.0 | Unit-Simulation (Kapitel 14) | [MESS 2026-07-25 `iverilog -V`] |
| `sshpass`, `ssh`, `scp` | Distribution | Übertragung | [CODE scripts/deploy.sh:84,88] |
| Zielsystem-Betriebssystem | Linux 5.10 (openwifi-Abbild, `5.10.0-98248`), ARM 32 bit | Laufzeit | Kernel-Version [CODE scripts/ad9361_init.sh:18–19]; Architektur [MESS 2026-07-25 `file sw/tetra_attach_daemon` → „ELF 32-bit LSB executable, ARM, EABI5 … statically linked"] |

**Zur Toolchain-Zweideutigkeit (R-15-05).** Auf dem Bauhost liegen zwei
Cross-Compiler mit demselben Aufrufnamen. V1 wählt implizit über die
Suchpfad-Reihenfolge [CODE sw/Makefile:17 `CROSS_COMPILE ?= arm-linux-gnueabihf-`].
Weil alle Ziele statisch gebunden werden [CODE sw/Makefile:19 `-static`], fällt der
Unterschied im Betrieb nicht auf — er fällt auf, sobald jemand dynamisch bindet
oder eine Bibliothek dazunimmt. V2 legt die Toolchain fest und prüft sie:
`$(CC) -dumpmachine` muss dem festgeschriebenen Triplett entsprechen, sonst Abbruch.

### 2.2 Erzeugnisse

| Erzeugnis | Pfad (Bauhost) | Größe | Beleg |
|---|---|---|---|
| Bitstream | `build/tetra_zynq_phy.bit` | 4 045 676 B | [MESS 2026-07-25 `ls -la`] |
| Ladeabbild FPGA-Manager | `build/tetra_zynq_phy.bit.bin` | 4 045 568 B | [MESS 2026-07-25] |
| Implementierungs-Prüfpunkt | `build/post_route.dcp` | ~76 MB | [MESS 2026-07-25] |
| Berichte | `build/reports/{synth,impl}_{utilization,timing}.rpt`, `clock_interaction.rpt`, `cdc_report.rpt` | — | [CODE scripts/vivado_build.tcl:247–248,368–372] |
| ARM-Dienste | `sw/<dienstname>` | 0,5…0,6 MB je Dienst, statisch, ARM EABI5, nicht entfernte Symbole | [MESS 2026-07-25 `file`, `ls`] |

**Unterschied `.bit` → `.bit.bin`** [MESS 2026-07-25 Byte-Vergleich der beiden
Dateien]: Die `.bit` trägt einen **112 Byte** langen Kopf. Er besteht aus einer
13-Byte-Präambel und Schlüssel-Länge-Wert-Feldern: `a` (Länge 16 bit) = Name des
Top-Moduls + UserID + Werkzeugversion
(`tetra_system_top;UserID=0XFFFFFFFF;Version=2022.2`), `b` = Bauform
(`7z020clg400`), `c` = Datum, `d` = Uhrzeit, `e` (Länge 32 bit, Schlüsselbyte bei
Offset 0x6B) = Länge der Konfigurationsdaten `0x003D_BAFC` = 4 045 564 Byte, die
ab Offset 112 folgen.

`bootgen` entfernt diesen Kopf, **vertauscht die Bytes jedes 32-bit-Wortes der
Konfigurationsdaten** und hängt 4 Byte an; netto ist die `.bin` 108 Byte kleiner.
Byte-Reihenfolge ausdrücklich (`CONVENTIONS.md` §4 „Bit-Order"): in der `.bit`
liegt jedes Konfigurationswort MSB-first, in der `.bin` LSB-first — das Sync-Wort
`AA995566` steht in der `.bit` bei Offset 160, in der `.bin` als `665599AA` bei
Offset 48. Nachgewiesen: `byteswap32(bit[112:]) == bin[:4045564]`. Die
Byte-Vertauschung ist der eigentliche Unterschied; das Entfernen des Kopfes allein
erklärt die Größendifferenz nicht.

### 2.3 Ablauf im Überblick

```
Quellbaum
 ├── rtl/**, constraints/**        ──► S1 Projekt+Quellen ──► S2 Blockdesign
 │                                        ──► S3 Synthese ──► S4 Implementierung
 │                                        ──► S5 Bitstream ──► S6 Ladeabbild (.bin)
 ├── sw/**                         ──► S7 Cross-Übersetzung ──► Dienste-Binärdateien
 └── deploy/targets.conf,
     deploy/services.tsv,
     deploy/files.tsv             ──► steuern S8

S8 Übertragung ──► S9 Neustart des Zielsystems ──► (Autostart: 01 §3.8 B1…B13)
                                              ──► S10 Prüfschritte (§3.10)
```

Die drei Tabellen unter `deploy/` sind die V2-Antwort auf zwei V1-Fehlerklassen:
verstreute Zieladressen (R-15-14) und Dienste, die ausgeliefert aber nicht
gestartet wurden (R-15-11). Aufbau in §3.5.1.

### 2.4 Was einen Vollbau erzwingt — und was nicht

| Änderung an | Nötige Stufen | Dauer (gemessen, §4) |
|---|---|---|
| `rtl/**` | S1…S6 | ~32 min |
| `constraints/**` | S1…S6 | ~32 min |
| Blockdesign, IP-Version, Bauform, Synthese-/Implementierungs-Direktive | S1…S6 | ~32 min |
| Bau-Kennung (§3.1.6) | S1…S6 | ~32 min |
| nur Ladeabbild neu erzeugen (aus vorhandenem `.bit`) | S6 | 0,7 s |
| `sw/**` | S7, S8 (nur Dienste), Dienst-Neustart | wenige Sekunden |
| Dateien der Bedienoberfläche | S8 (nur diese Dateien) | Sekunden |
| Konfigurationsdatei des Zielsystems | keine; Datei ändern + Dienst-Neustart | Sekunden |
| Zieladresse/Zielpfade (`deploy/*.tsv`) | keine | — |

**Es gibt keinen Zwischenzustand.** Eine RTL-Änderung ohne Neu-Implementierung ist
in V2 nicht vorgesehen; inkrementelle Implementierung ist bewusst nicht Teil von
Stufe 1 (§6, O-15-5).

---

## 3. Detail-Spezifikation

### 3.1 Hardware-Bau (S1…S5)

Ein Vivado-Stapellauf, ein Skript, kein Projektzustand über Läufe hinweg. Aufruf:

```
vivado -mode batch -source scripts/build_hw.tcl
```

Der Lauf legt das Projekt unter `build/vivado` **neu** an (`-force`), damit kein
Zustand aus einem früheren Lauf einfließt [CODE scripts/vivado_build.tcl:79].

#### 3.1.1 Projekt- und Bibliotheksvorgaben

| Vorgabe | Wert | Grund / Beleg |
|---|---|---|
| Bauform | `xc7z020clg400-1` | §3.13; [CODE scripts/vivado_build.tcl:38] |
| Zielsprache, Standardbibliothek | Verilog, `work` | [CODE scripts/vivado_build.tcl:81–82] |
| XPM-Bibliotheken | `XPM_FIFO`, `XPM_MEMORY` | asynchrone FIFOs im PL-Top; ohne diese Freigabe scheitert die Elaboration [CODE scripts/vivado_build.tcl:86] |
| Include-Pfad | `rtl/include` | Kopfdateien müssen **zusätzlich** als Projektdatei mit `Verilog Header` + `is_global_include` registriert sein; nur der Suchpfad genügt Vivado nicht [CODE scripts/vivado_build.tcl:202–205] |

#### 3.1.2 Quellenliste (R-15-02)

V1 pflegt 68 Dateipfade von Hand in sechs Blöcken — Infra (3), AD9361-Adapter (1),
RX (19), TX (12), LMAC (31), Top-Level (2)
[CODE scripts/vivado_build.tcl:95,104,109,132,148,185]. Der nachweisbare Schaden: `rtl/rx/`
enthält ein Modul, das mit Testbench im Baum liegt, aber in keinem Bau eingeht
[MESS 2026-07-25 — Mengenvergleich Quellbaum gegen Skriptliste: 69 Dateien im
Baum, 68 in der Liste; nicht enthalten ist `rtl/rx/tetra_ul_ctrl_softburst_mailbox.v`,
instanziiert nur in `tb/tb_ul_ctrl_softburst_mailbox.v:17`].

V2:

1. Das Bauskript sammelt `rtl/**/*.v` rekursiv und fügt alles hinzu.
2. Kopfdateien (`*.vh`) werden separat behandelt (§3.1.1).
3. Ein Modul, das im Baum liegt und von der Top-Hierarchie nicht erreicht wird,
   erscheint als „nicht erreichbar" im Elaborationsbericht und ist ein Baufehler.
   Bewusst nicht synthetisiertes RTL liegt außerhalb von `rtl/` (Verzeichnis
   `archive/`) und wird nicht eingesammelt.
4. Unaufgelöste Modulreferenzen (Black Box) sind ein Baufehler, kein Hinweis —
   Vivado baut sonst ein funktionsfähig aussehendes Abbild mit fehlender Logik.

#### 3.1.3 Blockdesign (S2)

Das Blockdesign wird bei jedem Lauf aus einem Skript erzeugt, nicht als Binärdatei
versioniert [CODE scripts/create_bd.tcl:103 `create_bd_design "tetra_system"`].
Inhalt und Adressabbildung:
`01_PLATFORM.md` §2.2 und `07_PS_PL_CONTRACT.md`.

Die IP-Quelle wird über die Umgebungsvariable `ADI_HDL_DIR` gesetzt; fehlt sie,
sucht V1 fünf feste Pfade ab und fällt anschließend auf einen projektlokalen
IP-Zwischenspeicher zurück [CODE scripts/create_bd.tcl:60–64 (Kandidatenliste),
:80–90 (Rückfall)]. Für V2 gilt
R-15-01: der Pfad steht in der Werkzeug-Festschreibung, die Suchheuristik entfällt.
Ohne auflösbare IP bricht der Bau ab — er läuft nicht mit Ersatz weiter.

Das Blockdesign wird **global** mitsynthetisiert
(`SYNTH_CHECKPOINT_MODE = None`), damit keine vorab gebauten, versteckt veralteten
Netzlisten-Prüfpunkte der IP entstehen [CODE scripts/vivado_build.tcl:236–238].

#### 3.1.4 Synthese (S3)

```
synth_design -top <system-top> -part xc7z020clg400-1 \
             -flatten_hierarchy rebuilt \
             -directive PerformanceOptimized \
             -retiming
```

[CODE scripts/vivado_build.tcl:240–245]. `-flatten_hierarchy rebuilt` ist
Voraussetzung dafür, dass der hierarchische Auslastungsbericht überhaupt
Modulnamen zeigt — die Grundlage des Ressourcen-Budgets in `01_PLATFORM.md` §3.9.
Danach: Auslastungs- und Zeitbericht, Prüfpunkt `post_synth.dcp`
[CODE scripts/vivado_build.tcl:247–250].

#### 3.1.5 Implementierung (S4)

Feste Abfolge, jede Stufe mit ihrer Direktive:

| Schritt | Direktive | Beleg |
|---|---|---|
| `opt_design` | Vorgabe | [CODE scripts/vivado_build.tcl:259] |
| `place_design` | `ExtraTimingOpt` | [CODE scripts/vivado_build.tcl:360] |
| `phys_opt_design` | `AggressiveExplore` | [CODE scripts/vivado_build.tcl:361] |
| `route_design` | `AggressiveExplore` | [CODE scripts/vivado_build.tcl:362] |
| `phys_opt_design` (nach Routing) | `AggressiveExplore` | [CODE scripts/vivado_build.tcl:363] |

Die zweite physikalische Optimierung **nach** dem Routing ist nicht optional: im
letzten V1-Bau meldet `route_design` „did not meet timing requirements"
[BUILD 2026-07-12 build/vivado_build.log:10855, `[Route 35-39]`], und erst der
folgende Lauf schließt das Timing auf WNS = +0,006 ns
[BUILD 2026-07-12 build/reports/impl_timing.rpt, Design Timing Summary].

**In V2 enthält das Bauskript keinen Zweig zum Einfügen von Debug-Kernen.** Der
gesamte ILA-Block aus V1 [CODE scripts/vivado_build.tcl:262–358] entfällt
ersatzlos; In-Circuit-Debug-Instrumentierung ist als Methode ausgeschlossen
(`CONVENTIONS.md` §6.3). Beobachtbarkeit läuft über AXI-Zähler (P6), Logs und
Luft-Aufzeichnungen.

Berichte nach der Implementierung: Auslastung, Zeitzusammenfassung (mit
`-warn_on_violation`), Takt-Interaktion, CDC [CODE scripts/vivado_build.tcl:368–372].

#### 3.1.6 Abbruchkriterien und Bau-Kennung

V1 **warnt** bei negativem Slack und baut das Abbild trotzdem
[CODE scripts/vivado_build.tcl:375–381]; zusätzlich filtert die Konsolenausgabe
der Pipeline kritische Warnungen weg
[CODE scripts/deploy.sh:126 — Muster `^(Phase|INFO.*Timing|ERROR|WARNING.*timing|Build|Bitstream)`,
kein Treffer auf `CRITICAL WARNING`]. Beides zusammen erzeugt genau den Fall, den
R-15-03 ausschließt: ein Abbild mit verletztem Timing wird ohne sichtbaren Hinweis
ausgeliefert.

V2 — der Bau endet mit Exit-Code ≠ 0, wenn eine der folgenden Bedingungen zutrifft:

| Bedingung | Quelle im Bau |
|---|---|
| WNS < 0 oder WHS < 0 | `report_timing_summary` |
| TNS-Failing-Endpoints > 0 | `report_timing_summary` |
| unaufgelöstes Modul / Black Box | Elaborations-/Synthesebericht |
| Randbedingungszeile ohne Treffer (R-15-04) | `CRITICAL WARNING [Common 17-55]`, `[Vivado 12-4739]` |
| Quellenliste ≠ Quellbaum (R-15-02) | Mengenvergleich vor der Synthese |
| Bauform ≠ `xc7z020clg400-1` | Projektvorgabe |

Eine Freigabe trotz Verletzung ist nur über eine ausdrückliche Umgebungsvariable
möglich, die im Berichtsarchiv festgehalten wird.

**Bau-Kennung (R-15-19).** V1 liest an der Versionsadresse eine im RTL fest
verdrahtete Konstante `0x0001_0000` [CODE rtl/infra/tetra_axi_lite_regs.v:1116] —
damit ist nicht feststellbar, welches Abbild auf dem Board läuft. V2:

- Das Bauskript schreibt vor der Synthese `rtl/include/tetra_build_id.vh` mit einer
  32-bit-Konstante, abgeleitet aus dem kurzen Commit-Hash plus einem Bit
  „Arbeitsbaum verändert".
- Die Datei ist ein Erzeugnis, wird nicht von Hand bearbeitet und nicht versioniert.
- Der Wert ist über das Versionsregister lesbar (Adresse: `07_PS_PL_CONTRACT.md`)
  und Teil der Prüfliste (§3.10, P9).
- **Keine Uhrzeit im Bitstream** — sonst ist bit-identische Reproduzierbarkeit aus
  demselben Quellstand ausgeschlossen. Zeitstempel gehören ins Berichtsarchiv.

### 3.2 Randbedingungsdateien

Zwei Dateien, klar getrennte Aufgaben:

| Datei | Inhalt |
|---|---|
| `constraints/libresdr_tetra.xdc` | Pin-Zuordnung und I/O-Standards: 16 LVDS-Paare des Transceiver-Interfaces — `rx_clk`, `rx_frame`, `rx_data[5:0]`, `tx_clk`, `tx_frame`, `tx_data[5:0]`, entsprechend 32 `IOSTANDARD LVDS_25`-Zeilen, Empfangsseite zusätzlich `DIFF_TERM TRUE` [CODE constraints/libresdr_tetra.xdc:26–67] — dazu Steuer- und GPIO-Leitungen, SPI, I²C, LEDs, VCXO-DAC; Taktdefinition der LVDS-Empfangsleitung, Ausnahmen für Reset-Synchronisierer, asynchrone Taktgruppe, mehrzyklige Pfade, Konfigurationsspannung |
| `constraints/adi_cdc_async_reg.xdc` | Markierung der Synchronisierer-Register innerhalb der Transceiver-IP, damit der CDC-Bericht die Übergänge klassifizieren kann |

Belege: Pin-Block und Ausnahmen [CODE constraints/libresdr_tetra.xdc:22–170],
Taktdefinition `create_clock -name rx_clk -period 4` auf die Empfangs-Taktleitung
[CODE constraints/libresdr_tetra.xdc:135] — 4 ns deckt die höchste
Transceiver-Datentaktrate ab, unabhängig von der betrieblich genutzten Rate.
Fachliche Bedeutung der Takt- und CDC-Regeln: `01_PLATFORM.md` §3.1/§3.5.

**Der V1-Zustand dieser Dateien ist ein Negativbeispiel für R-15-04.** Im letzten
Bau treffen neun `set_property`-Zeilen der CDC-Datei kein Objekt
[BUILD 2026-07-12 build/vivado_build.log:8454–8470, `[Common 17-55]` auf
`adi_cdc_async_reg.xdc` Zeilen 31, 46, 57, 61, 63, 72, 87, 91, 95] und eine
mehrzyklige Ausnahme findet ihr Startregister nicht
[BUILD 2026-07-12 build/vivado_build.log:8398–8402, `[Vivado 12-4739]`]. Folge:
der CDC-Bericht weist 79 Übergänge als „unsafe" und 105 als „unknown" aus
[BUILD 2026-07-12 build/reports/cdc_report.rpt]. Die Pfade sind im RTL
synchronisiert — das Werkzeug kann es ohne die Markierungen nur nicht bestätigen.
Ein Sicherheitsbericht, der aus toten Zeilen entsteht, ist wertlos. Deshalb ist die
nicht getroffene Randbedingung in V2 ein Baufehler.

### 3.3 Ladeabbild (S6)

```
bootgen -w on -process_bitstream bin -image <bif> -o <ziel>
```

[CODE scripts/deploy.sh:170]. Die Beschreibungsdatei enthält nur den Bitstream-Namen
[CODE scripts/deploy.sh:163–168].

**Verhalten, das man kennen muss** [MESS 2026-07-25, bootgen 2022.2]: Mit
`-process_bitstream` bildet das Werkzeug den Ausgabenamen aus dem **Namen der
Eingabedatei** (`<name>.bit` → `<name>.bit.bin`) und legt die Datei im
Arbeitsverzeichnis ab; die Angabe hinter `-o` wird dabei nicht verwendet. V1 ist nur
deshalb korrekt, weil der Aufruf im Ausgabeverzeichnis ausgeführt wird
[CODE scripts/deploy.sh:170 — Aufruf in einer Subshell mit gewechseltem
Arbeitsverzeichnis]. V2 setzt das Arbeitsverzeichnis ausdrücklich und prüft danach
Existenz, Größe und Byte-Reihenfolge der erwarteten Datei: das Sync-Wort muss als
`665599AA` (LSB-first) bei Offset 48 stehen, nicht als `AA995566` (§2.2).

**Determinismus (R-15-06):** Zweifache Umwandlung derselben `.bit` ergibt dieselbe
Prüfsumme [MESS 2026-07-25 — MD5 `717c7bb3…` aus unabhängigem Lauf identisch zum
Erzeugnis des Bau-Lauf vom 2026-07-12]. Dauer: 0,7 s.

### 3.4 Software-Übersetzung (S7)

| Vorgabe | Wert | Beleg |
|---|---|---|
| Compiler-Aufruf | `$(CROSS_COMPILE)gcc` mit festgeschriebenem Präfix | [CODE sw/Makefile:17–18] |
| Übersetzungsschalter | `-Wall -Wextra -O2 -march=armv7-a -static` | [CODE sw/Makefile:19] |
| Bindeart | statisch — keine Abhängigkeit von Bibliotheksversionen des Zielabbilds | [MESS 2026-07-25 `file` → „statically linked"] |
| Ergebnis je Dienst | ein Ziel, alle Quellen in einem Aufruf | [CODE sw/Makefile:33–64] |

**Festlegungen für V2:**

1. `-Wall -Wextra` bleibt, zusätzlich `-Werror` für eigenen Code. Der
   Sprachcodec-Fremdcode wird in einem eigenen Ziel ohne `-Werror` übersetzt —
   er erzeugt Warnungen, die nicht in unserer Verantwortung liegen
   [MESS 2026-07-25 — `etsi_codec/sub_cd.c:844`: `-Wmaybe-uninitialized`].
2. Die ausgelieferten Binärdateien werden von Symbolen befreit; die unentfernte
   Fassung bleibt mit derselben Bau-Kennung im Berichtsarchiv, damit ein
   Absturzabbild auswertbar bleibt. V1 liefert 0,6-MB-Dateien mit Debug-Abschnitten
   aus [MESS 2026-07-25 `file` → „with debug_info, not stripped"].
3. Host-Regressionen (Übersetzung mit dem Host-Compiler, Ausführung auf dem
   Bauhost) sind ein getrenntes Ziel und laufen **vor** S7. Inhalte: Kapitel 14.
   Sie dürfen die Cross-Ziele nicht berühren [V1-Muster: CODE sw/Makefile:66–145].
4. Das Kernelmodul-Ziel aus V1 [CODE sw/Makefile:22,147–153] entfällt in Stufe 1:
   der Registerzugriff läuft über die Speicherabbildung im Userspace, ein eigener
   Treiber ist nicht Teil des Funktionsumfangs (`13_SW_ARCHITECTURE.md`).

Dauer: 2,0 s für den größten Dienst (21 Übersetzungseinheiten, statisch)
[MESS 2026-07-25].

### 3.5 Übertragung auf das Zielsystem (S8)

#### 3.5.1 Die drei Steuerungstabellen

**`deploy/targets.conf`** — genau eine Datei mit Zieladresse, Zugangsart und
Zielpfaden. Begründung: V1 verteilt die Adresse über sieben Skripte mit **zwei
verschiedenen Vorgabewerten** — `192.168.2.90`
[CODE scripts/deploy.sh:40, scripts/tetra_ctrl.sh:29, scripts/vcxo_cal.sh:49,
scripts/capture_rx_iq.sh:17] und `192.168.2.85`
[CODE scripts/ad9361_init.sh:36, scripts/hw_deploy.sh:41,
scripts/aach_grant_poke.sh:27]. Ein **dritter** Wert `192.168.2.183` steht in den
Modul-READMEs [CODE sw/README.md:147,234,237; sw/web/README.md:53,59,60], während die
Betriebsdokumentation einheitlich `192.168.2.90` nennt
[CODE docs/OPERATIONS.md:78, docs/HARDWARE.md:22]. Wer das falsche Skript oder die
falsche README erwischt, konfiguriert ein anderes Gerät oder nichts.

**`deploy/files.tsv`** — Zeilen `quelle → ziel → modus`. Ersetzt die einzeln
ausgeschriebenen Kopierbefehle [V1: CODE scripts/deploy.sh:235–304].

**`deploy/services.tsv`** — je Dienst: Name, Binärdatei, Startreihenfolge,
Argumentquelle (Schlüssel aus der Konfigurationsdatei), Logpfad. Aus dieser Tabelle
werden **alle fünf** Verwendungen erzeugt (R-15-11):

1. das Beenden laufender Instanzen vor der Übertragung,
2. die Übertragung der Binärdateien,
3. der Startabschnitt des Hochlaufskripts,
4. der `ExecStop`-Abschnitt der Startdefinition (§3.8.2),
5. die Prüfliste nach der Auslieferung (§3.10).

Genau diese Kopplung fehlt in V1: dort stehen dieselben Dienstnamen an vier
Stellen von Hand [CODE scripts/deploy.sh:219 (Beenden),
scripts/deploy.sh:249–256 (Übertragung), board_autostart/tetra_autostart.sh:209–232
(Start), board_autostart/tetra-autostart.service:10 (Beenden durch den
Dienstestarter)] — und mindestens einmal wurde ein Dienst ausgeliefert, startete aber
nicht, weil er im Hochlaufskript fehlte: der Webserver, im Quellbaum als Schritt 13
nachgetragen [CODE board_autostart/tetra_autostart.sh:245–247 — Kommentar: „Vor
2026-05-17 lief der Start implizit am Ende von scripts/deploy.sh; beim
Autostart-Refactor wurde der httpd vergessen. Hier nachgeholt."]. Ein Log- oder
Messnachweis weiterer Fälle liegt im Repo nicht vor.

#### 3.5.2 Ablauf

| Schritt | Aktion | Fehlerverhalten |
|---|---|---|
| U1 | Erreichbarkeit prüfen (Anmeldung mit kurzer Zeitgrenze) | Abbruch [CODE scripts/deploy.sh:214–216] |
| U2 | Alle Dienste aus `services.tsv` beenden | Fortfahren, wenn kein Prozess läuft |
| U3 | Ladeabbild in das Firmware-Verzeichnis übertragen | — |
| U4 | Prüfsumme lokal und auf dem Ziel vergleichen | Abbruch bei Abweichung [CODE scripts/deploy.sh:238–243] |
| U5 | Dienste-Binärdateien übertragen, ausführbar setzen | — |
| U6 | Dateien der Bedienoberfläche übertragen; nicht mehr vorhandene Endpunkte auf dem Ziel entfernen | — |
| U7 | Hochlaufskript und Dienstedefinition übertragen, Dienstestarter neu einlesen | — |
| U8 | Konfigurationsdatei **nur anlegen, wenn sie fehlt** (R-15-16) | — |
| U9 | Teilnehmerdatenbank nur anlegen, wenn sie fehlt | — [V1-Muster: CODE scripts/deploy.sh:338] |
| U10 | Neustart des Zielsystems anstoßen und auf Wiedererreichbarkeit warten (R-15-08) | Abbruch bei Zeitüberschreitung |
| U11 | Prüfliste §3.10 ausführen und Ergebnis melden (R-15-12) | Abbruch mit Befund |

**Zu U8 — der Fall, der in V1 offen ist.** Das Hochlaufskript bricht ab, wenn die
Konfigurationsdatei fehlt oder eine Pflichtvariable nicht gesetzt ist
[CODE board_autostart/tetra_autostart.sh:27–44]. Die Auslieferung überträgt diese
Datei aber **nie** [CODE scripts/deploy.sh:293–304 — nur Hochlaufskript und
Dienstedefinition]. Auf einem frischen Board ist der automatische Start damit
funktionsunfähig, ohne dass es beim Ausliefern auffällt. Gleichzeitig darf die
Datei nicht bedingungslos überschrieben werden: die Bedienoberfläche schreibt
dieselbe Datei, ein Überschreiben verwirft Betriebseinstellungen. Die Auflösung ist
die Anlege-Semantik aus U8, wie sie V1 für die Teilnehmerdatenbank schon nutzt.

**Zu U6 — nur ein Wurzelverzeichnis für die Bedienoberfläche.** V1 hat zwei
Verzeichnisbäume mit teils gleichnamigen Endpunkten; ausgeliefert wird nur einer
[CODE scripts/deploy.sh:262–278 überträgt `sw/web/`; `sw/www/` bleibt unberührt und
ist Altlast]. V2 hat genau einen Baum; ein zweiter ist ein Spec-Verstoß (P3).

**Zu U2 — Prozessmuster beim Beenden.** Ein Beenden über Kommandozeilen-Suchmuster
trifft auf dem Zielsystem auch die eigene Anmelde-Sitzung, weil deren
Kommandozeile das Suchmuster enthält; die Verbindung bricht ab und die
Auslieferung endet mit einem Verbindungsfehler. V1 löst das mit einer
Zeichenklasse im ersten Zeichen des Musters
[CODE scripts/deploy.sh:221–231]. V2 übernimmt das Muster **oder** beendet über den
Dienstenamen ohne Kommandozeilensuche; die Wahl ist zu treffen und einheitlich
anzuwenden.

**Zu U10 — Warum ein Neustart, nicht ein Nachladen im Betrieb (R-15-08).** Ein
Nachladen des Abbilds in ein laufendes System hinterlässt Zustand aus dem
vorherigen Abbild in Transceiver- und AXI-Registern; Messungen danach sind nicht
zuordenbar. Der Neustart erzwingt über den Startdienst die vollständige Sequenz
aus `01_PLATFORM.md` §3.8 einschließlich beider Ladevorgänge. Zeit bis
betriebsbereit: ~30 s [MESS 2026-05-17].

### 3.6 Reihenfolge der Inbetriebnahme

Die board-interne Sequenz ist in `01_PLATFORM.md` §3.8 als B1…B13 normativ
festgelegt und wird hier nicht wiederholt. Für die Auslieferung gilt zusätzlich
diese äußere Reihenfolge — sie ist verbindlich, weil jede Umstellung einen bekannten
Fehlerzustand erzeugt:

| Nr. | Schritt | Warum an dieser Stelle |
|---|---|---|
| I1 | Ladeabbild ins Firmware-Verzeichnis, Prüfsumme verifizieren | Der Startdienst lädt aus dem Firmware-Verzeichnis; ein halb übertragenes Abbild führt zu einem fehlgeschlagenen Ladevorgang beim nächsten Hochlauf |
| I2 | Dienste-Binärdateien und Konfigurationsdateien ablegen | müssen vor dem Hochlauf liegen, weil der Startdienst sie startet |
| I3 | Startdienst aktivieren (nur Erstinstallation, §3.11) | ohne Aktivierung läuft nach dem Neustart nichts |
| I4 | Neustart | erzeugt den definierten Anfangszustand |
| I5 | *(Startdienst führt B1…B13 aus)* | Reihenfolge dort normativ |
| I6 | Prüfliste §3.10 | vor jeder Messung |
| I7 | Funktions- und Luft-Tests | Kapitel 14 |

**Kein Registerzugriff zwischen I1 und I6**, außer den Zugriffen innerhalb von
B1…B13 selbst, die dem Gatter aus R-15-09 folgen.

### 3.7 Der zweistufige Ladevorgang (R-15-07)

#### 3.7.1 Normative Reihenfolge

```
L1  fpga_manager: flags = 0
L2  fpga_manager: firmware = <ladeabbild>      → Ladevorgang #1
L3  Zustand prüfen: state == "operating"       → sonst Abbruch, kein Registerzugriff
L4  Transceiver-Treibermodul laden, SPI-Gerät binden (idempotent)
L5  Sendepfad dämpfen (R-15-18)
L6  Transceiver konfigurieren (Sample-Rate, LO, Gain-Modus, Bandbreite, Duplex,
    Kalibrierung) — ausschließlich direkte sysfs-Schreibvorgänge (§3.7.2)
L7  fpga_manager: firmware = <ladeabbild>      → Ladevorgang #2
L8  Zustand prüfen: state == "operating"       → sonst Abbruch
L9  Sendepfad erneut dämpfen; Transceiver-Konfiguration identisch zu L6 wiederholen
L10 Transceiver-IP-Kerne im PL initialisieren (Sende- und Empfangskern)
L11 weiter mit B9…B13 (01 §3.8)
```

Belege: L1–L3 [CODE board_autostart/tetra_autostart.sh:73–78],
L4 [CODE …:83–98], L5 [CODE …:103–105], L6 [CODE …:115–122],
L7–L8 [CODE …:127–131], L9 [CODE …:136–151], L10 [CODE …:156–164].
Dieselbe Reihenfolge in der Host-Variante
[CODE scripts/tetra_ctrl.sh:391–429] und in der JTAG-Variante
[CODE scripts/hw_deploy.sh:233–245].

#### 3.7.2 Begründung und Fehlerbild

**Fehlerbild bei nur einem Ladevorgang** [MESS 2026-05-17, manueller Reboot-Test]:
Der Ladevorgang meldet `operating`, das Treibermodul bindet, die
Transceiver-Konfiguration wird angewendet — **danach ist die AXI-Anbindung tot**.
Der Anmeldedienst hängt, Dienste starten nicht, Registerzugriffe blockieren. Das
Board ist nur durch einen harten Neustart wieder erreichbar. Mit der Sequenz
L1…L9 tritt der Zustand nicht auf.

**Zur Erklärung.** Die in V1-Kommentaren stehende Begründung („MMCM kann nicht auf
den Datentakt einrasten") ist in `01_PLATFORM.md` §3.8 gegen die IP-Quellen geprüft
und **nicht** haltbar. Die Ursache ist offen (`01_PLATFORM.md` §6, O-01-1). Für
dieses Kapitel ist die Konsequenz eindeutig und unabhängig von der Ursache:

> Die Reihenfolge ist empirisch belegt und normativ. Sie wird nicht „wegoptimiert",
> weil ihre Begründung unvollständig ist. Wer sie ändern will, muss den
> Einzel-Ladevorgang als Negativtest bestehen (§5, V-15-6) — und dieser Test kostet
> im Fehlerfall einen harten Neustart des Boards.

**Warum die Konfiguration nach L7 wiederholt wird (L9).** Der zweite Ladevorgang
setzt **alle** Register der PL und der IP-Kerne auf ihre Reset-Werte zurück. Ohne
L9/L10 bleibt der Empfangskern in einem Zustand, in dem das Gültigkeitssignal der
Abtastwerte nie pulst; die Synchronisation rastet nie ein
[CODE scripts/tetra_ctrl.sh:414–423 — Kommentar mit genau diesem Fehlerbild].
Die dabei zu setzenden Kern-Register und ihre Bedeutung: `01_PLATFORM.md` §3.8 B7/B8.

#### 3.7.3 Werkzeug-Stolperstein: Attribut-Werkzeug im Dienstekontext (R-15-10)

Das Kommandozeilenwerkzeug der IIO-Bibliothek hängt beim Setzen der
Sende-LO-Frequenz **unterbrechungsfrei im Kernel**, wenn es aus dem Dienstestarter
heraus aufgerufen wird; auch das nicht abfangbare Beendigungssignal erreicht den
Prozess nicht. Der Dienst bleibt im Zustand „wird gestartet", der Systembus
blockiert, das Board ist nur über einen Netzausfall wieder erreichbar. Aus einer
interaktiven Anmelde-Sitzung läuft derselbe Aufruf in unter einer Sekunde durch
[MESS 2026-05-17].

**Regel:** Im Hochlaufskript und in jedem vom Dienstestarter ausgeführten Skript
werden Transceiver-Attribute ausschließlich per direktem sysfs-Schreibvorgang
gesetzt [CODE board_autostart/tetra_autostart.sh:111–122 — Kommentar und
Umsetzung]. Gemessene Dauer je Schreibvorgang: 0,1…1,5 s, langsamster Fall die
Sende-LO-Frequenz [MESS 2026-05-17]. Host-seitige Skripte, die je Aufruf eine
eigene Anmelde-Sitzung öffnen, dürfen das Werkzeug weiter verwenden
[CODE scripts/ad9361_init.sh:135–156]; für V2 ist es einfacher, überall direkt in
sysfs zu schreiben und das Werkzeug nicht zu verwenden.

Zweite Regel aus demselben Umfeld: **keine Ausgabeumleitung über eine Pipeline im
Dienstekontext.** V1 leitet die Protokollausgabe mit einer einfachen Umleitung
um und begründet ausdrücklich, dass eine Pipeline in eine Subshell
Puffer-Effekte erzeugt, die das Attribut-Werkzeug blockieren
[CODE board_autostart/tetra_autostart.sh:46–50].

### 3.8 Automatischer Start beim Hochlauf

#### 3.8.1 Dateien und Ort

| Ort auf dem Zielsystem | Quelle | Zweck |
|---|---|---|
| Firmware-Verzeichnis, `<abbild>.bit.bin` | Erzeugnis S6 | vom FPGA-Manager geladen |
| `/root/<hochlaufskript>` | `board_autostart/` | führt L1…L11 + B9…B13 aus |
| `/etc/systemd/system/<einheit>.service` | `board_autostart/` | Startdefinition |
| `/root/<konfigurationsdatei>` | `board_autostart/` (nur anlegen) | einzige Quelle der Zell-/HF-Parameter |
| `/root/<dienst>` je Dienst | Erzeugnis S7 | Protokoll-Dienste |
| Wurzelverzeichnis der Bedienoberfläche | `sw/web/` | Bedienoberfläche |

#### 3.8.2 Eigenschaften der Startdefinition

`Type=oneshot` mit `RemainAfterExit=yes`, `After=local-fs.target network.target`,
`Before=multi-user.target`; Ausgabe in das Systemprotokoll
[CODE board_autostart/tetra-autostart.service:3–12].

**V1-Lücke im `ExecStop`.** Das Beenden der Einheit beendet nur die drei
Protokoll-Daemons (`tetra_attach_daemon`, `tetra_ul_mon`, `tetra_sysinfo`)
[CODE board_autostart/tetra-autostart.service:10]. Der in §3.5.1 selbst als Dienst
geführte Webserver wird dort nicht genannt und überlebt das Stoppen der Einheit
[CODE board_autostart/tetra_autostart.sh:252 — Start als eigene Sitzung]. **V2:**
Der `ExecStop`-Abschnitt wird wie die vier anderen Verwendungen aus
`deploy/services.tsv` erzeugt und erfasst damit **alle** Dienste (R-15-11,
R-15-12, Prüfung P4). Ein von Hand geschriebener `ExecStop` ist ein Spec-Verstoß.

Die Dienste selbst werden mit eigener Sitzungskennung gestartet, damit sie das Ende
des Hochlaufskripts überleben [CODE board_autostart/tetra_autostart.sh:209–232].

**Für eine reine Software-Iteration ohne Neustart** wird ein Dienst nicht aus einer
Anmelde-Sitzung heraus gestartet: der Prozess liegt dann in der Ressourcengruppe
der Sitzung und wird beim Abmelden beendet, auch mit eigener Sitzungskennung. Er ist
stattdessen als eigene, vorübergehende Diensteinheit zu starten
[MESS — Betriebsbefund, Datum nicht dokumentiert: Dienst beendet sich Sekunden nach
dem Abmelden mit der Meldung, die dem Beendigungssignal entspricht].
Ebenso: eine laufende Binärdatei kann nicht direkt überschrieben werden — erst
unter neuem Namen übertragen, dann Dienst anhalten, dann umbenennen.

#### 3.8.3 Konfigurationsfluss — und ein V1-Defekt, der hier endet

Vorgehen des Hochlaufskripts: Konfigurationsdatei einlesen, Vorhandensein **jeder**
Pflichtvariablen prüfen und bei Fehlen mit Nennung des Namens abbrechen
[CODE board_autostart/tetra_autostart.sh:37–44].

**Defekt in V1:** Die Variable für die Korrelator-Schwelle des Sprachkanals ist
Pflichtvariable [CODE board_autostart/tetra_cell.conf:21, Prüfliste
board_autostart/tetra_autostart.sh:39], wird im Protokoll ausgegeben
[CODE …:55] und am Ende **zurückgelesen** [CODE …:265] — aber nie **geschrieben**.
Der wirksame Wert entsteht an zwei anderen Stellen: als Reset-Wert 8 im
Registersatz [CODE rtl/infra/tetra_axi_lite_regs.v:1557] und als fest
einkompilierte 11 in einem Dienst [CODE sw/tetra_attach_daemon.c:1044]. Drei Orte,
eine Wahrheit — genau der Fall, den P2 verbietet. Eine Änderung in der
Konfigurationsdatei bleibt wirkungslos, und niemand merkt es, weil der Rücklesewert
plausibel aussieht.

**Verbindliche Festlegung:**

1. Jeder Parameter aus der Konfigurationsdatei hat genau einen Konsumenten, der ihn
   in ein Register oder ein Dienst-Argument überträgt.
2. Jeder so übertragene Wert wird unmittelbar **zurückgelesen und verglichen**;
   Abweichung ist ein Fehler des Hochlaufs, nicht eine Protokollzeile.
3. Kein Dienst und kein RTL-Reset-Wert setzt einen Betriebsparameter, der auch in
   der Konfigurationsdatei steht. Reset-Werte sind sichere Anfangswerte, keine
   Betriebswerte.
4. Die Prüfung „alle Pflichtvariablen vorhanden" wird aus derselben Liste erzeugt
   wie die Übertragung — nicht zweimal geschrieben.

#### 3.8.4 Sendepegel-Disziplin (R-15-18)

Anfangswert stark gedämpft, operativer Wert erst nach dem Gesundheitsgatter
[CODE board_autostart/tetra_autostart.sh:103–105 (vor Ladevorgang #2),
136–139 (Wiederholung nach Ladevorgang #2) und 239–241 (operativer Wert);
Werte board_autostart/tetra_cell.conf:13–14].

**Kanalwahl.** V1 schreibt den Pegel an **beiden** Sendekanälen
(`out_voltage0_hardwaregain` und `out_voltage1_hardwaregain`)
[CODE board_autostart/tetra_autostart.sh:104–105, 138–139, 240–241], liest aber nur
`out_voltage0` zurück [CODE board_autostart/tetra_autostart.sh:266]. V2-Festlegung:
Der Sendepegel wird ausschließlich an `out_voltage0` gesetzt **und** dort
zurückgelesen, weil der zweite Sendekanal auf dieser Baugruppe nicht angeschlossen
ist (Kanalzuordnung: `01_PLATFORM.md` §3.7). Schreiben ohne Rücklesen an einem
unbeschalteten Kanal ist ein zweiter Ort für denselben Parameter und damit ein
P2-Verstoß.

Normativer Rückhalt: Während einer PL-Rekonfiguration ist der Ausgang des
Modulators undefiniert. Für eine BS gilt im nicht-aktiven Sendezustand
`Lmin = −40 dBc` [ETSI §6.4.5.1 — „In the non-active transmit state the
specification Lmin = -40 dBc shall apply."]; für die Schaltflanken t1/t3 begrenzt
ETSI die Aussendung bei 25 kHz Trägerabstand zusätzlich auf −45 dBc (nur
MS-Leistungsklassen 4 und 4L) bzw. −50 dBc (alle anderen Klassen), in keinem Fall
strenger als −36 dBm [ETSI §6.4.2.2.2]. Ein undefiniert modulierender Sender kann
die BS-Grenze nicht einhalten. Dämpfung während der Rekonfiguration ist damit nicht
nur Vorsicht, sondern die einzige Betriebsart, in der die Aussendung während des
Hochlaufs bewertbar bleibt.

### 3.9 Vorprüfung vor jedem Registerzugriff (R-15-09)

**Regel:**

```
zugriff_erlaubt := (fpga_manager.state == "operating")
wenn nicht zugriff_erlaubt:  kein Zugriff, Befund melden, abbrechen
```

Die Prüfung gilt vor dem **ersten** Zugriff einer Zugriffsfolge und erneut nach
jedem Ladevorgang. Innerhalb einer laufenden Folge genügt die einmalige Prüfung;
liefert ein Zugriff einen Busfehler, wird die Folge **abgebrochen** und nicht
fortgesetzt.

**Warum.** Ein Zugriff auf eine Adresse, die die PL nicht dekodiert oder deren
Bereich nicht aktiv ist, endet nicht zuverlässig als abgefangener Busfehler des
aufrufenden Prozesses; das Board kann bis zur Nichterreichbarkeit blockieren. Der
Zustand ist in V1 mehrfach eingetreten [MESS 2026-05-17 — Betriebsbefund, als
inakzeptabel eingestuft]. Ein Log- oder Messnachweis der Kausalität liegt im Repo
nicht vor [ANNAHME — die Regel wird unverändert übernommen, weil sie nichts kostet;
der Nachweis ist Negativtest V-15-7].

**Wo die Regel in V1 verletzt ist — und in V2 nicht sein darf:**

| Ort | Befund |
|---|---|
| Endpunkt der Bedienoberfläche für Live-Kennzahlen | liest eine PL-Adresse ohne Zustandsprüfung, im Zwei-Sekunden-Takt aus dem Browser [CODE sw/web/cgi-bin/metrics.cgi:31] |
| Auslieferungsskript | schreibt eine PL-Adresse direkt als Zahlenwert [CODE scripts/deploy.sh:361] — verstößt zugleich gegen R-15-13 |
| Host-Steuerwerkzeug | Lese-/Schreibbefehle ohne Zustandsprüfung [CODE scripts/tetra_ctrl.sh:58–71] |

V2: **ein** Zugriffspfad. Jeder Zugriff — Dienst, Bedienoberfläche, Diagnose —
geht durch die Hardware-Abstraktionsschicht, und diese enthält das Gatter
(`13_SW_ARCHITECTURE.md`; Registeradressen ausschließlich in
`07_PS_PL_CONTRACT.md`). Ein Zahlenwert als Adresse in einem Skript ist ein
Spec-Verstoß.

### 3.10 Prüfschritte nach jeder Auslieferung

Die Auslieferung ist nicht beendet, wenn die Dateien übertragen sind, sondern wenn
diese Liste durchläuft. Sie läuft **automatisch** am Ende von S8 und ihr Ergebnis
wird berichtet (R-15-12).

| Nr. | Prüfung | Kriterium | Beleg / Herkunft |
|---|---|---|---|
| P1 | Abbild-Identität | Prüfsumme Ziel == Prüfsumme lokal | [CODE scripts/deploy.sh:238–243] |
| P2 | FPGA-Zustand | `operating` | Voraussetzung für alle folgenden Zugriffe (R-15-09) |
| P3 | Startdienst | aktiv; Protokoll ohne Abbruchmeldung | [CODE board_autostart/tetra-autostart.service:7–12] |
| P4 | Dienste-Instanzen | je Dienst aus `services.tsv` **genau eine**; bei mehr: alle beenden und neu starten | zwei Instanzen greifen konkurrierend auf dieselben Mailbox-Register zu und erzeugen widersprüchliche Lesewerte [MESS — Betriebsbefund, Datum nicht dokumentiert] |
| P5 | Dienste-Protokolle | keine Fehlerzeile in den ersten Zeilen nach dem Start | — |
| P6 | Gesundheitsgatter | LVDS-Takt im Fangbereich, Empfangskern eingerastet, Synchronisation innerhalb 3 s | `01_PLATFORM.md` §3.8 B11 |
| P7 | Sendepegel | Rücklesewert == operativer Wert aus der Konfiguration | [CODE board_autostart/tetra_autostart.sh:239–241,266] |
| P8 | Konfigurationswirksamkeit | für **jeden** aus der Konfiguration abgeleiteten Registerwert: Rücklesewert == Sollwert | schließt den Defekt aus §3.8.3 aus |
| P9 | Bau-Kennung | Versionsregister == Kennung des ausgelieferten Abbilds | §3.1.6; schließt „altes Abbild läuft noch" aus |
| P10 | Zähler-Grundzustand | Verwurf-, Prüfsummenfehler- und Überlaufzähler stehen nach dem Hochlauf auf 0 | P6 aus `00_OVERVIEW.md` §4 |

Erst nach P10 beginnen Messungen und Luft-Tests (Kapitel 14). Ein Befund in P1…P10
wird mit konkretem Wert gemeldet — nicht als „vermutlich in Ordnung".

### 3.11 Erstinstallation eines Boards (einmalig, R-15-20)

| Nr. | Schritt | Beleg / Wirkung |
|---|---|---|
| E1 | Betriebssystem-Abbild aufspielen, Netzzugang einrichten | — |
| E2 | Systemziel auf Mehrbenutzerbetrieb ohne Grafik setzen; Anzeige-, Druck-, VNC- und Auto-Aktualisierungsdienste abschalten | gemessen: Arbeitsspeicher 238 → 41 MB, Leerlauf-CPU 31 → 92 %, Prozesse 106 → 80 [MESS 2026-05-20]. Der Auto-Aktualisierungsdienst ist zusätzlich abzuschalten, weil er während eines Luft-Tests Pakete austauschen und Dienste beenden kann |
| E3 | Konkurrierende Dienste abschalten: IIO-Daemon, WLAN-Zulieferer, Bluetooth | der IIO-Daemon konkurriert mit den direkten sysfs-Schreibvorgängen des Hochlaufs [MESS 2026-05-17] |
| E4 | Transceiver-Treibermodul bereitstellen | wird vom Hochlauf geladen [CODE board_autostart/tetra_autostart.sh:87–88] |
| E5 | Werkzeug für Speicherzugriff im Suchpfad verfügbar machen | fehlt im Standardabbild; ohne diesen Schritt scheitern die Registerschritte des Hochlaufs [CODE board_autostart/tetra_autostart.sh:195; Begründung scripts/deploy.sh:342–346] |
| E6 | Startdienst **aktivieren** | V1 lädt die Definition nur neu ein und aktiviert sie nicht [CODE scripts/deploy.sh:301] — auf einem frischen Board startet ohne diesen Schritt nach dem Neustart nichts |
| E7 | Erste Auslieferung nach §3.5 einschließlich Anlegen von Konfigurationsdatei und Teilnehmerdatenbank | — |

### 3.12 Fehlerbilder und Reaktion

| Beobachtung | Ursache | Reaktion |
|---|---|---|
| Bau endet ohne `.bit`, Log endet mit Fehler | Synthese-/Implementierungsfehler | Log auswerten. Das Bauskript löscht das alte Abbild **vor** dem Lauf, damit die Existenzprüfung nicht ein veraltetes Abbild bestätigt [CODE scripts/deploy.sh:121–123] — dieses Verhalten ist verbindlich |
| Bau läuft durch, Timing verletzt | siehe R-15-03 | Kein Ausliefern. Direktive oder RTL ändern; Wechsel der Implementierungs-Strategie kostet grob eine halbe Stunde zusätzliche Bauzeit |
| Prüfsummen-Abweichung nach der Übertragung | abgebrochene Übertragung, voller Datenträger | Übertragung wiederholen; nie „trotzdem weitermachen" |
| Board nach der Auslieferung nicht erreichbar, Anmeldung hängt | Einzel-Ladevorgang oder Attribut-Werkzeug im Dienstekontext | Netzausfall herbeiführen; Ursache in §3.7 |
| Startdienst bleibt im Zustand „wird gestartet" | Attribut-Werkzeug hängt unterbrechungsfrei | §3.7.3; Aufruf entfernen |
| Synchronisation rastet nicht ein, obwohl der Korrelator Treffer meldet | Empfangskern nach dem zweiten Ladevorgang nicht neu initialisiert | L9/L10 prüfen |
| Sender wirkt tot, nur LO-Träger sichtbar | Datenquelle des Sendekerns steht auf dem Reset-Wert | `01_PLATFORM.md` §3.8 B7 |
| Dienst startet, beendet sich nach Sekunden | aus einer Anmelde-Sitzung gestartet | §3.8.2 |
| Mailbox-Lesewerte widersprüchlich | zwei Instanzen desselben Dienstes | P4 |
| Konfigurationsänderung ohne Wirkung | Parameter hat mehr als einen Ort | §3.8.3, P8 |

### 3.13 Ein Bauform-Bezeichner (R-15-15)

Im Quellbaum stehen zwei verschiedene Bezeichnungen desselben Bausteins:

| Ort | Angabe |
|---|---|
| Syntheseablauf | `xc7z020clg400-1` [CODE scripts/vivado_build.tcl:38] |
| Blockdesign-Skript (Kopfkommentar) | `XC7Z020-CLG400` [CODE scripts/create_bd.tcl:4] |
| Simulationsablauf | `xc7z020clg400-1` [CODE scripts/vivado_sim.tcl:163] |
| IP-Erzeugung | `xc7z020clg400-1` [CODE scripts/_resolved/generate_viterbi_ip.tcl:25] |
| Randbedingungsdatei (Kopfkommentar) | `XC7Z020-CLG484` [CODE constraints/libresdr_tetra.xdc:4] |
| RTL-Kopfkommentare | `XC7Z020-CLG484` [CODE rtl/tetra_system_top.v:22, rtl/tetra_zynq_top.v:8] |
| IST-Dokumentation | behauptet, der Simulationsablauf nutze `clg484` [CODE docs/ist/11_build.md:78, docs/ist/10_scripts.md:216] |

**Richtig ist `xc7z020clg400-1`**, belegt durch den Kopf des Auslastungsberichts des
tatsächlich gebauten und auf der Hardware laufenden Abbilds
[BUILD 2026-07-12 build/reports/impl_utilization.rpt, Zeile „Device"] und durch den
CDC-Bericht desselben Laufs [BUILD 2026-07-12 build/reports/cdc_report.rpt, Zeile
„Device : 7z020-clg400"]. Die beiden Bauformen haben unterschiedliche
Anschlussbilder; die Pin-Zuordnung der Randbedingungsdatei ist auf der Hardware
verifiziert, also gehört sie zur 400-Ball-Bauform.

Die `clg484`-Angabe im Simulationsablauf war ein echter Widerspruch und ist im
Quellbaum bereits behoben; die Kopfkommentare und die IST-Dokumentation tragen ihn
weiter — ein Doku-Rest, kein Zustand des Bauablaufs.

**V2:** Der Bezeichner steht in der Werkzeug-Festschreibung (§2.1). Synthese,
Simulation und IP-Erzeugung lesen ihn dort; Kopfkommentare nennen ihn nicht mehr.
Der Bau bricht ab, wenn der Bezeichner des Projekts vom festgeschriebenen abweicht.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Blockdesign-Erzeugung | 12 s | [BUILD 2026-07-12 vivado_build.log:627] | — |
| `synth_design` | 3 min 45 s | [BUILD 2026-07-12 vivado_build.log:8500] | — |
| `opt_design` | 24 s | [BUILD 2026-07-12 vivado_build.log:8658] | — |
| `place_design` | 5 min 13 s | [BUILD 2026-07-12 vivado_build.log:9038] | — |
| `phys_opt_design` (nach Platzierung) | 56 s | [BUILD 2026-07-12 vivado_build.log:10254] | — |
| `route_design` | 13 min 49 s | [BUILD 2026-07-12 vivado_build.log:10866] | — |
| `phys_opt_design` (nach Routing) | 6 min 54 s | [BUILD 2026-07-12 vivado_build.log:11003] | Ohne diese Stufe bleibt das Timing verletzt (§3.1.5) |
| `write_bitstream` | 21 s | [BUILD 2026-07-12 vivado_build.log:11201] | — |
| Summe der Werkzeugstufen | 31 min 34 s | [ANNAHME — addiert aus den acht Stufendauern oben: 12+225+24+313+56+829+414+21 s = 1894 s] | — |
| Ende-zu-Ende ein Vollbau | ~35 min | [ANNAHME — rückgerechnet aus den Stufendauern plus Endzeitstempel; im Log steht nur das Ende (build/vivado_build.log:11220 „Exiting Vivado at Sun Jul 12 01:27:23 2026") und der Berichtszeitstempel 01:26:33, kein Laufbeginn] | — |
| Ladeabbild-Erzeugung | 0,7 s | [MESS 2026-07-25] | — |
| Cross-Übersetzung größter Dienst | 2,0 s | [MESS 2026-07-25] | — |
| Neustart bis betriebsbereit | ~30 s | [MESS 2026-05-17] | Wartet die Auslieferung kürzer, schlägt die Prüfliste fälschlich an |
| WNS letzter V1-Bau | +0,006 ns | [BUILD 2026-07-12 impl_timing.rpt] | Der Spielraum ist minimal: jede zusätzliche Logik kann das Timing kippen, siehe `01_PLATFORM.md` §3.9 |
| WHS letzter V1-Bau | +0,049 ns | [BUILD 2026-07-12 impl_timing.rpt] | — |
| LUT / FF / BRAM-Tiles / DSP | 37 567 / 50 744 / 15,5 / 38 | [BUILD 2026-07-12 impl_utilization.rpt §1–§4] | Verbindliche Metriken; Slice-Prozent ist **keine** Grenze (`CONVENTIONS.md` §6.4) |
| gebundene I/O-Anschlüsse | 60 von 125 | [BUILD 2026-07-12 impl_utilization.rpt §5] | — |
| Bitstream / Ladeabbild | 4 045 676 B / 4 045 568 B | [MESS 2026-07-25] | Deutlich kleineres Abbild ⇒ Bau unvollständig |
| Wartezeit nach jedem Ladevorgang, bevor der Zustand gelesen wird | 2 s | [CODE board_autostart/tetra_autostart.sh:76,129] | Kürzer: Zustand noch nicht `operating`, Hochlauf bricht fälschlich ab |
| Dauer eines direkten sysfs-Schreibvorgangs | 0,1…1,5 s (langsamster Fall Sende-LO) | [MESS 2026-05-17] | — |
| Sendepegel während der Inbetriebnahme / im Betrieb | −89 dB / −10 dB | [CODE board_autostart/tetra_cell.conf:13–14] | −30 dB und höher: Empfangs-Verstärkungsregelung übersteuert, Einrasten instabil [MESS 2026-04-17] |
| VCXO-Abstimmwert | 153 | [CODE board_autostart/tetra_cell.conf:17] | Ohne diesen Wert driftet die Zeitbasis; ETSI fordert eine gemeinsame Quelle besser als ±0,2 ppm [ETSI §7.7] |
| Korrelator-Schwelle Sprachkanal | 11 | [CODE board_autostart/tetra_cell.conf:21] | 10 → mehr fehlerhafte Rahmen, 12 → Einrasten bricht zusammen; Messkontext in `03_PHY_UL_RX.md` |
| Ressourcenverbrauch des Betriebssystems nach Vorbereitung | 41 MB Arbeitsspeicher, 92 % Leerlauf-CPU | [MESS 2026-05-20] | Ohne E2: 238 MB / 31 % — Dienste konkurrieren mit dem Protokollstapel |

---

## 5. Verifikation

Abnahme dieses Kapitels — mechanisch prüfbar, ohne Funktionstest (Funktion:
Kapitel 14):

| Nr. | Prüfung | Kriterium |
|---|---|---|
| V-15-1 | Zwei Vollbauten aus demselben, unveränderten Quellstand | identische Prüfsumme des Ladeabbilds (R-15-06, R-15-19: keine Uhrzeit im Bitstream) |
| V-15-2 | Absichtlich eine RTL-Datei aus dem Baum in `archive/` verschieben, die instanziiert wird | Bau bricht ab mit Meldung „unaufgelöstes Modul", kein Abbild entsteht (R-15-02) |
| V-15-3 | Eine Randbedingungszeile so verändern, dass sie kein Objekt trifft | Bau bricht ab (R-15-04) |
| V-15-4 | Eine Zeitvorgabe künstlich verschärfen, bis WNS < 0 | Bau endet mit Exit ≠ 0, kein Ladeabbild wird ausgeliefert (R-15-03) |
| V-15-5 | Auslieferung mit absichtlich verfälschtem Ladeabbild | Abbruch bei P1, keine weiteren Schritte (R-15-06) |
| V-15-6 | **Negativtest Einzel-Ladevorgang** — L7…L9 überspringen | dokumentierter Fehlerzustand tritt ein (Board nicht erreichbar). Der Test kostet einen harten Neustart und wird nur bewusst und angekündigt ausgeführt (R-15-07) |
| V-15-7 | **Negativtest Registerzugriff ohne Gatter** — Zugriff, bevor der FPGA-Manager `operating` meldet | Verhalten protokollieren; damit wird die bisher unbelegte Begründung von R-15-09 entweder belegt oder korrigiert |
| V-15-8 | Neuen Dienst hinzufügen, dabei ausschließlich `deploy/services.tsv` ergänzen | Dienst wird ausgeliefert, gestartet, geprüft — ohne weitere Änderung (R-15-11) |
| V-15-9 | Konfigurationsdatei auf dem Zielsystem verändern, Neustart | P8 zeigt den neuen Wert in jedem betroffenen Register (R-15-16, §3.8.3) |
| V-15-10 | Auslieferung auf ein Board mit bereits vorhandener Konfigurationsdatei | Datei unverändert (R-15-16) |
| V-15-11 | Auslieferung ohne Neustart | Prüfliste meldet Abweichung bei P9 (Bau-Kennung), Auslieferung gilt als unvollständig (R-15-08) |
| V-15-12 | Alle Dienste doppelt starten, dann Prüfliste | P4 erkennt und bereinigt (R-15-12) |
| V-15-13 | Quellbaum nach Zahlenwerten als Registeradresse und nach Zieladressen außerhalb von `deploy/targets.conf` durchsuchen | keine Treffer (R-15-13, R-15-14) |
| V-15-14 | Quellbaum nach dem Bauform-Bezeichner durchsuchen | genau eine Definitionsstelle (R-15-15) |
| V-15-15 | Quellbaum und Hochlaufskripte nach Aufrufen des Attribut-Werkzeugs durchsuchen | kein Treffer in vom Dienstestarter ausgeführten Skripten (R-15-10) |

---

## 6. Offene Punkte

**O-15-1 — Ursache des zweistufigen Ladevorgangs.** Die Reihenfolge ist belegt, die
Ursache nicht (`01_PLATFORM.md` §6, O-01-1). Solange sie offen ist, bleibt der
Hochlauf ~4 s langsamer als nötig und der Ablauf schwer erklärbar. *Empfehlung:*
Reihenfolge unverändert übernehmen; die Ursache nur mit einem gezielten Versuch am
Zielsystem klären (Zustand der Transceiver-IP-Register vor und nach der
Transceiver-Konfiguration, bei Einzel-Ladevorgang), nicht durch Nachdenken.

**O-15-2 — Auswahl der Cross-Toolchain.** Zwei Compiler mit demselben Aufrufnamen,
verschiedene Ziel-Tripletts und Hauptversionen (§2.1). *Empfehlung:* die
Distributions-Toolchain festschreiben — sie ist ohne die Entwicklungsumgebung des
FPGA-Herstellers verfügbar und macht den Software-Bau unabhängig von deren
Installation. Vor der Festlegung ist ein Dienst mit beiden Toolchains zu bauen und
auf dem Zielsystem zu betreiben.

**O-15-3 — Neustart in der Pipeline.** R-15-08 fordert den Neustart; V1 stößt ihn
nicht an, er wird von Hand ausgeführt und deshalb vergessen. *Empfehlung:* Neustart
und Warten auf Wiedererreichbarkeit als Schritt U10 verbindlich im
Auslieferungsablauf, mit Zeitgrenze und Abbruch. Ein Abschalten dieses Schritts nur
über eine ausdrückliche Option, die in der Abschlussmeldung erscheint.

**O-15-4 — Berichtsarchiv und Rückgabe eines Abbilds.** Festzulegen ist, wo
Ladeabbild, Berichte, unentfernte Binärdateien und die Bau-Kennung gemeinsam
abgelegt werden und wie man auf ein früheres Abbild zurückgeht, ohne den Quellstand
zu wechseln. *Empfehlung:* ein Verzeichnis je Bau-Kennung, Aufbewahrung der letzten
wenigen Stände; die Rückgabe ist derselbe Ablauf S8…S10 mit einem anderen
Quellverzeichnis.

**O-15-5 — Inkrementelle Implementierung.** Ein Vollbau kostet ~32 min; das begrenzt
die Iterationsrate bei RTL-Arbeit spürbar. Vivado kann gegen einen früheren
Routing-Prüfpunkt inkrementell implementieren. *Empfehlung:* nicht in Stufe 1
aufnehmen — bei WNS = +0,006 ns ist die Vergleichbarkeit der Zeitergebnisse wichtiger
als die Bauzeit. Wenn später eingeführt, dann nur als zusätzlicher Modus, dessen
Ergebnis nicht ausgeliefert werden darf.

**O-15-6 — JTAG-Pfad und Hardware-Export.** V1 hat einen zweiten Weg zum Laden über
JTAG [CODE scripts/program_fpga.tcl] und einen Hardware-Export
[CODE scripts/export_xsa.tcl]. Der JTAG-Pfad trägt eine fest verdrahtete
Gerätebezeichnung [CODE scripts/program_fpga.tcl:29], der Export wird von keinem
Ablauf verbraucht. Zwei Wege zum Laden verstoßen gegen P3. *Empfehlung:* nur den
Weg über den FPGA-Manager beibehalten; JTAG allein für die Wiederbelebung eines
Boards ohne lauffähiges Betriebssystem, dann außerhalb der Auslieferungspipeline und
ausdrücklich als Notfallwerkzeug benannt. Der Hardware-Export entfällt, solange
keine Werkzeugkette ihn verbraucht.

**O-15-7 — Pflege der CDC-Markierungen.** Die Markierungen für die
Transceiver-IP treffen nach IP-Aktualisierungen ihre Zellnamen nicht mehr (§3.2).
R-15-04 macht das zum Baufehler — das erzwingt die Pflege, löst sie aber nicht.
*Empfehlung:* die Markierungen aus der IP-Quelle ableiten statt Namensmuster zu
raten, und die Anzahl der getroffenen Zellen als erwarteten Wert im Bau prüfen.

**O-15-8 — Vorgabe für den Zugang zum Zielsystem.** V1 legt Benutzername und
Passwort im Klartext in jedem Skript ab [CODE scripts/deploy.sh:41–42].
*Empfehlung:* Schlüssel-Anmeldung, Zugangsdaten ausschließlich in
`deploy/targets.conf`, diese Datei nicht versioniert. Für die Laborumgebung
ausreichend; eine weitergehende Absicherung ist nicht Teil von Stufe 1.
