# 13 — Software-Architektur

**Scope:** Aufbau der ARM-Software: Prozess- und Nebenläufigkeitsmodell, Struktur der
Ausführungsstränge und ihre Reaktion auf Ereignisse, Modulschnitt mit
Abhängigkeitsrichtung, Hardware-Abstraktionsschicht als einzige Zugriffsstelle auf die
Register, Konfiguration und Persistenz, Teilnehmer-Datenbank, Bedienoberfläche,
Protokollierung und Diagnose, Fehler- und Neustartverhalten, Rechenlast-Bilanz des
Gesamtsystems.

**Nicht hier:** Protokoll-Semantik → `09_LLC_MLE_MM`, `10_CMCE_CALL`, `11_SDS`,
`12_VOICE`. Kanalcodierung → `05_CHANNEL_CODING`. MAC-Mechanik → `06_MAC`.
Registeradressen, Mailbox-Protokolle, Fristen des Abfragevertrags →
`07_PS_PL_CONTRACT`. Luft-Fristen und Zeitachsen → `08_TIMING`. Übersetzung,
Auslieferung, Board-Hochlauf B1–B12 → `15_BUILD_DEPLOY`.

**Abhängigkeiten:** `00_OVERVIEW` §3/§4, `07_PS_PL_CONTRACT` §3.2–§3.6 und §3.8,
`08_TIMING` §2.3 und §3.7, `05_CHANNEL_CODING` §2.4 und §3.10, `12_VOICE` §2.2 und §3.9.

---

## 1. Anforderungen

| Nr | Anforderung | Prüfbar durch |
|---|---|---|
| **R-13-01** | Genau **ein** Prozess bildet die Registerapertur ab und ist der einzige Schreiber darauf. Kein zweiter Prozess und kein Hilfswerkzeug greift im Betrieb auf die Apertur zu. | Betriebsprüfung: `fuser /dev/mem` nennt genau eine PID; Codereview aller ausgelieferten Programme und CGI-Skripte. |
| **R-13-02** | Der Prozess hat **zwei** Ausführungsstränge mit festem Zuschnitt (§2.2). Jede Mailbox-Seite aus `07 §2.2` hat **genau einen** schreibenden Strang (§2.3). | Codereview + Laufzeitprüfung: jede HAL-Operation prüft im Debug-Bau die aufrufende Strang-Kennung gegen die Eigentümertabelle und bricht bei Verletzung ab. |
| **R-13-03** | Im Slot-Strang (T-RX) liegt **kein** Systemaufruf, der unbeschränkt blockieren kann: keine Dateisystem-Operation, keine dynamische Speicheranforderung, keine Zeichenketten-Formatierung, keine Ausgabe auf einen Datenstrom, kein Warten auf ein Sperrobjekt, das ein anderer Strang länger als eine Registeroperation hält. | Statische Prüfung gegen eine Verbotsliste (`open`, `fopen`, `read`, `write`, `stat`, `rename`, `fsync`, `malloc`, `calloc`, `free`, `printf`, `snprintf`, `syslog`) über die Übersetzungseinheiten von T-RX. |
| **R-13-04** | T-RX hält die Abfragefrist aus `07 §3.8`: `REG_ULMB_STATUS[0]` wird mindestens alle **2 ms** gelesen, und nach jedem `ACK` wird `STATUS[1]` geprüft, bevor der Strang schläft. | Zähler `rx_iter_max_us` ≤ 4000 und `rx_deadline_miss_cnt` = 0 über einen Luft-Lauf von ≥ 10 min mit drei aktiven Sprachkanälen. |
| **R-13-05** | Die Abfragekadenz liegt auf einem **absoluten** Zeitraster (`CLOCK_MONOTONIC`, `TIMER_ABSTIME`), nicht als Wartezeit am Schleifenende. | Codereview; Messung: Standardabweichung des Iterationsabstands ≤ 200 µs. |
| **R-13-06** | Es gibt **keine** Unterbrechungsleitung und keinen Kernel-Treiber. Der Zugriff erfolgt über eine Abbildung von `/dev/mem`. Kein Quelltext eines Kernmoduls liegt im Auslieferungsbaum. | `07 §3.8` R-07-14; Verzeichnisprüfung. |
| **R-13-07** | Die Abstraktionsschicht ist eine **Bibliothek ohne Hauptprogramm**. Keine Übersetzungseinheit enthält sowohl HAL-Funktionen als auch `main()`. | Übersetzungsprüfung: `nm` über das HAL-Objekt zeigt kein `main`. |
| **R-13-08** | **Kein** Modul außerhalb der Abstraktionsschicht führt einen Registerzugriff aus. Die rohen Zugriffsfunktionen sind nicht in dem Kopf sichtbar, den Anwendungsmodule einbinden. Ausnahmen sind **abschließend** `tetra_hal.c`, `tetra_hal_internal.h` und `tetra_bringup.c` (§3.6; das Hochlaufwerkzeug läuft nie gleichzeitig mit dem Dienst und muss vor gültiger `REG_ID` rohe Zugriffe machen können). | Statische Prüfung: `grep` über alle Übersetzungseinheiten außer diesen drei nach `hal->regs`, `tetra_reg_read`, `tetra_reg_write`, `devmem` → keine Treffer. |
| **R-13-09** | Die Abhängigkeiten der Module bilden einen **gerichteten azyklischen Graphen** über die Schichten L0…L5 (§2.4). Kein Aufruf zeigt aufwärts. Sprünge über mehr als eine Schicht sind **ausschließlich** nach L0 erlaubt (Plattformmodule sind für alle Schichten sichtbar); `tetra_hal` darf nur aus L5 aufgerufen werden. Maßgeblich ist die modul-granulare Erlaubnisliste in §2.4, nicht ein Schicht-Abstand. | Erzeugter Aufrufgraph aus den Objektdateien gegen die modul-granulare Erlaubnisliste aus §2.4. |
| **R-13-10** | Jede `.c`-Datei im Auslieferungsbaum ist Quelle **genau eines** Übersetzungsziels. Eine Datei ohne Ziel existiert nicht. | Übersetzungsprüfung: Mengenvergleich Dateiliste ↔ Quellenliste aller Ziele. |
| **R-13-11** | Es existiert **genau ein** Verzeichnis für die Bedienoberfläche. | Verzeichnisprüfung. |
| **R-13-12** | Kein Vorgabewert eines Konfigurationsfelds existiert an mehr als einer Stelle im Baum. Die einzige Quelle ist die Konfigurationsvorlage. | Statische Prüfung: für jeden Schlüssel genau ein Literal-Treffer außerhalb von Testdaten. |
| **R-13-13** | Die Bedienoberfläche führt **keinen** Registerzugriff und **keinen** Zugriff auf Treiber-Attributdateien aus und wertet **keine** Protokolldatei aus. Sie liest ausschließlich die Zustandsdatei und schreibt ausschließlich Konfigurationsdateien. | Codereview aller CGI-Skripte gegen eine Verbotsliste (`devmem`, `/sys/bus/iio`, `grep <logfile>`). |
| **R-13-14** | Genau **eine** Datei auf dem Zielsystem ist die Wahrheit über die Zellkonfiguration. **Kein** Zellparameter wird als Aufrufargument übergeben. | Codereview: der Aufrufzeilen-Parser kennt nur `--config`, `--foreground`, `--log-level`, `--log-category`. |
| **R-13-15** | Die Zuordnung Duplex-Abstands-Kennung → Frequenzversatz ist eine zur Laufzeit über die Bedienoberfläche editierbare Tabelle mit acht Zeilen. Der auf die Luft gehende 3-bit-Wert und der Versatz in Hertz sind **getrennte** Größen. | Konfigurationsprüfung + Luft-Test: Änderung einer Tabellenzeile verschiebt die Empfangsfrequenz, ohne das Broadcast-Feld zu ändern. |
| **R-13-16** | Jeder lesend-ändernd-schreibende Zugriff auf eine persistierte Datei erfolgt unter einer exklusiven Sperre auf einer **eigenen** Sperrdatei; jeder Nur-Lese-Zugriff unter einer geteilten Sperre. Die Zwischendatei liegt im **selben** Verzeichnis wie das Ziel. | Codereview beider Seiten (Daemon und CGI); Nebenläufigkeitstest §5. |
| **R-13-17** | Eine Konfigurationsänderung wirkt **ohne** Prozess-Neustart (Signal `SIGHUP`). Der Prozess-Neustart ist auf der Luft nicht beobachtbar: keine Änderung der Zeitbasis, keine Rückstellung der Hyperframe-Nummer, keine Lücke im Symbolstrom. | Luft-Aufzeichnung über einen Neustart hinweg: Frame-, Multiframe- und Hyperframe-Folge bleibt lückenlos; Endgeräte bleiben angemeldet. |
| **R-13-18** | Die Software schreibt die TDMA-Zeitbasis (`REG_TDMA_LOAD`) **nie**. Das Laden gehört zum Board-Hochlauf (`01 §3.8` B10). | Codereview. |
| **R-13-19** | Beim Start und bei jeder Beendigung führt der Prozess eine **Ruhigstellung** durch: alle Sprach-Halteplätze löschen, alle Zeitschlitz-Infowörter auf das Ruhemuster, alle Rufplätze leeren. | Startprotokoll + Registerrücklesung; Luft-Test: eine unmittelbar nach einem Absturz neu gestartete Zelle sendet kein Fremdmuster auf einem Sprachslot. |
| **R-13-20** | Die Hyperframe-Nummer des Broadcast-Inhalts wird aus dem **Überlauf des PL-Hyperframe-Zählers** fortgeschrieben, nicht aus einem Software-Zeitgeber. | Codereview; Luft-Messung: Abstand zweier Hyperframe-Wechsel = 61,2 s ± 100 ms. |
| **R-13-21** | Die Teilnehmer-Datenbank ist im Speicher über eine Streuwerttabelle mit **offener Adressierung** adressiert: **1024 Plätze je Typ** bei einem Füllgrad ≤ 0,5, also Kapazität **≥ 512 Einträge je Typ** (§3.8). Sie trägt **keinen** Platzindex im Dateiformat. | Einheitentest V-13-11: 512 Einträge je Typ einfügen, Nachschlagezeit unabhängig von der Position; der 513. Eintrag wird mit Fehler abgewiesen. |
| **R-13-22** | Die Richtlinienbits (`accept_unknown_issi`, `accept_unknown_gssi`) stehen in der Konfigurationsdatei, **nicht** in einem PL-Register (`09 §3.6`). | Codereview; `07`-Registerliste enthält kein Richtlinienregister. |
| **R-13-23** | Der Auslieferungszustand der Teilnehmer-Datenbank ist **leer** (= `09` R-09-13). | Dateiprüfung. |
| **R-13-24** | Jeder Verwurf, jede Prüfsummen-Verletzung, jeder Ringüberlauf und jede Fristverletzung der Software hat einen benannten, im Betrieb lesbaren Zähler (P6). Die Liste in §3.10.2 ist verbindlich und vollständig. | Zustandsdatei enthält jeden Zähler der Liste; Negativtest je Zähler in `14_VERIFICATION`. |
| **R-13-25** | Der Betriebszustand wird als **strukturierte** Zustandsdatei ausgegeben (versioniertes Schema, atomar ersetzt, Kadenz 1 s). Kein Diagnosewert wird ausschließlich über eine Protokollzeile verfügbar gemacht. | Schemaprüfung; R-13-13. |
| **R-13-26** | Die Protokollierung ist mengenbegrenzt: fester Ringpuffer im Speicher, Formatierung außerhalb von T-RX, Datei mit Größenobergrenze und zwei Generationen, Wiederholungsdrosselung je Ereigniskennung. | Dauerlauf 1 h mit drei Sprachkanälen: Protokolldatei ≤ Obergrenze, `log_drop_cnt` lesbar. |
| **R-13-27** | Der Aufwand je Zeitschlitz im Slot-Strang wird **auf dem Zielprozessor** gemessen und als Budget geführt (Auftrag aus `08 §3.8.3`). Die Rechnung in §3.12 ist bis dahin als Annahme gekennzeichnet. | Messreihe §5.3; Ergebnis ersetzt die Annahme-Spalte in §3.12. |
| **R-13-28** | T-RX läuft mit Echtzeit-Vorrang und gesperrtem Adressraum (`mlockall`). Der Protokoll-Strang läuft mit Standard-Vorrang. | Laufzeitprüfung `chrt -p`; Codereview. |

---

## 2. Architektur / Aufbau

### 2.1 Ein Prozess, zwei Ausführungsstränge — die Entscheidung

V1 ist ein Prozessverbund aus **drei** Programmen — zwei mit einer Abfrageschleife von 10 ms
(`tetra_attach_daemon`, `tetra_ul_mon`) [CODE sw/tetra_attach_daemon.c:86,
sw/tetra_ul_mon.c:73] und eines mit einer Auffrischschleife von 2 s (`tetra_sysinfo`)
[CODE sw/tetra_hal.c:1882] — und einem
Monolithen von 1229 Zeilen als Protokollteil. V2 bekommt zusätzlich die **vollständige
Kanalcodierung aller Sendekanäle**, die **vollständige Kanaldecodierung des Uplinks ab den
Soft-Bits** und die **Sprachweiterleitung** auf denselben Kern (`00 §3.3`).

Die Rechenlast trägt das (§3.12: ≤ 4 % eines Kerns im ungünstigsten Dauerfall). **Die
Rechenlast ist nicht das Problem.** Das Problem ist, dass V1s Schleife an fünf belegten
Stellen unbeschränkt blockiert, während dieselbe Schleife eine harte 14-ms-Frist hat:

| Blockade in V1 | Dauer | Beleg |
|---|---|---|
| Erzwungenes Sichern der Teilnehmerdatei **mitten im Anmeldepfad** (`react_mm2_locupd` → `tetra_db_alloc` → `save_tsv` → `fsync`) | Schreibvorgang auf die SD-Karte, Größenordnung 10…100 ms [ANNAHME: nicht gemessen; `fsync` auf Flash-Medien liegt in dieser Größenordnung] | [CODE sw/tetra_db.c:197-199, :236, sw/tetra_attach_daemon.c:632-638] |
| Wartespirale auf den Belegt-Spiegel der Antwort-Mailbox vor **jedem** Push | bis 50 ms, in 200-µs-Schritten | [CODE sw/tetra_tx_transport.c:52-64] |
| Fest eingebaute Wartezeit nach **jedem** Push | 200 µs × Anzahl Pushes | [CODE sw/tetra_tx_transport.c:78, :127, :227] |
| Dateiöffnung für den Bediener-Postausgang in **jeder** Iteration | 100 Dateizugriffe/s | [CODE sw/tetra_attach_daemon.c:263-271] |
| Historisch: zwei synchrone Wartezeiten à 113 ms in der Antwortfolge | 226 ms je Ruf-Anforderung; behoben durch einen nicht blockierenden Folgezähler | [CODE sw/tetra_call_fsm.h:78-85], Wirkung gemessen: Median 0,95 s → 0,58 s [MESS 2026-05-17] |

Dazu kommt ein Nebenläufigkeitsfehler, der direkt aus dem Prozessverbund folgt: zwei
Prozesse teilen sich das Statusregister eines Uplink-Fensters, beide löschen dessen
Haftbit, und der Protokoll-Daemon muss das mit einer Zähler-Beobachtung umgehen —
ausgeschrieben im Quelltext: *„We share `REG_UL_PDU_STATUS` with `tetra_ul_mon` (which W1Cs
the sticky for logging). Instead of racing for the sticky bit we track
`ul_pdu_count[31:16]`"* [CODE sw/tetra_attach_daemon.c:1089-1096].

**Entscheidung.**

1. **Ein Prozess** (`tetra_bsd`). Der Prozessverbund hat keinen Nutzen und einen belegten
   Wettlauf. Die Aufgaben der beiden Nebenprozesse — Broadcast-Auffrischung und
   Uplink-Mitschrift — sind ein Zeitgeber und eine Protokollkategorie, kein Programm.
2. **Zwei Ausführungsstränge**, getrennt genau an der Grenze „harte Slot-Frist" gegen
   „ereignisgesteuert mit Frame-Spielraum". Eine erweiterte Einzelschleife wäre
   rechnerisch ausreichend (§3.12), würde aber die fünf Blockaden oben nur verschieben:
   jede Dateioperation und jede Wartespirale läge weiterhin auf dem Pfad, der die
   14-ms-Frist hält. Der Schnitt kostet zwei Übergaberinge und **keinen** Sperrvorgang auf
   dem Registerpfad (§2.3, §3.4).
3. **Keine weiteren Stränge.** Protokollierung wird vom Protokoll-Strang entleert, die
   Bedienoberfläche läuft als eigener Prozess des Web-Servers und berührt die Hardware
   nicht (R-13-13).

### 2.2 Der Trennschnitt zwischen den Strängen

```
        PL                                     PS: tetra_bsd
 ┌───────────────┐
 │ UL-Burst-     │ Seite 2                ┌──────────────────────────────────────┐
 │ Mailbox       │◀──── pull + ACK ───────│ T-RX   „Slot-Strang"                 │
 └───────────────┘   (2 ms, SCHED_FIFO)   │  Frist: 1 Zeitschlitz = 14,167 ms    │
                                          │  · UL-Burst holen (07 §3.4)          │
                                          │  · tetra_cc_decode_soft (05)         │
                                          │  · Sprache: TCH/S decode → BFI →     │
                                          │    encode → DL-Halteplatz            │
 ┌───────────────┐                        │  · DL-Ring entleeren → Push          │
 │ DL-PDU-       │ Seite 1                │  · Gesundheitszähler                 │
 │ Mailbox       │◀──── push ─────────────│                                      │
 └───────────────┘                        └───────┬──────────────────────▲───────┘
                                       ul_ring    │                      │ dl_ring
                                    (SPSC, 64)    ▼                      │ (SPSC, 16)
                                          ┌──────────────────────────────┴───────┐
 ┌───────────────┐ Seite 0/3/4            │ T-CTL  „Protokoll-Strang"            │
 │ Konfiguration │◀──── write ────────────│  Frist: 1…2 TDMA-Frames              │
 │ TX-Payload    │                        │  · MAC → LLC → MLE → MM/CMCE/SDS     │
 │ Zeitplan      │                        │  · Zeitgeber (10 ms)                 │
 │ Zähler        │───── read ────────────▶│  · tetra_dl_emit: bauen + codieren   │
 └───────────────┘                        │  · Konfiguration, DB, Zustandsdatei, │
                                          │    Protokollentleerung (1 s)         │
                                          └──────────────────────────────────────┘
```

**Die Schnittregel in einem Satz:** *Alles, dessen Kosten mit der Burst-Rate skalieren,
liegt in T-RX; alles, dessen Kosten mit der Ereignis-Rate skalieren, liegt in T-CTL.*

Daraus folgt: **die Kanaldecodierung liegt in T-RX**, obwohl ihre Frist großzügig wäre.
Grund: nur so ist die Laufzeit von T-CTL **unabhängig von der Burst-Rate**, und eine
langsame Iteration in T-CTL (Konfigurationsneulesen, Zustandsdatei, Sichern der
Teilnehmerdatei) kann keinen Burst verzögern. Nebeneffekt: der Übergabering trägt
dekodierte Informationsbits (12 bzw. 34 Byte) statt 432 Soft-Werte, und die
Prüffeld-Entscheidung fällt vor der Ringgrenze — T-CTL sieht nie einen fehlerhaften Block.
Die Sprachkette bleibt **vollständig** in T-RX: sie besteht ausschließlich aus
burst-proportionaler Arbeit und ihr Ergebnis muss im gleichen Zeitraster zurück (`12 §3.4`).

### 2.3 Register-Eigentum

Nebenläufiger Registerzugriff ist unkritisch, solange zwei Stränge nie dasselbe
Index/Daten-Fenster benutzen: die Folge `INDEX = w; DATA = x` ist nicht unteilbar. Deshalb
gilt eine Eigentümertabelle, im Debug-Bau durch eine Zusicherung in der HAL erzwungen
(R-13-02):

| Seite / Fenster (`07 §2.2`) | Eigentümer (schreibend) | Lesend |
|---|---|---|
| Seite 1 — `REG_DLMB_*` (DL-PDU-Mailbox) | **T-RX** | T-RX |
| Seite 2 — `REG_ULMB_*` (UL-Burst-Mailbox) | **T-RX** | T-RX |
| Seite 3 — `REG_TXPAY_*` (TX-Payload-Bänke) | **T-CTL** | T-CTL |
| Seite 4 — `REG_SCHEDULE[k]` (Zeitplan) | **T-CTL** | T-CTL |
| Seite 0 — Konfiguration (`REG_CELL_CFG_*`, `REG_SLOT_STATE_TSn`, `REG_AACH_ACCESS_CFG`, `REG_UL_ASSIGN_CFG`, `REG_GRANT_MAG_*`, `REG_CTRL`) | **T-CTL** | beide |
| Seite 0 — Zähler und Status (RO) | — | beide |

Dass T-RX die **DL**-Mailbox besitzt, ist eine Folge von `07 §3.3`: in V2 gehen
Signalisierung **und** Sprachinhalt über dasselbe Fenster (P3). Sprache muss aus T-RX
kommen; also muss auch die Signalisierung durch T-RX gehen. T-CTL baut und **codiert** die
PDU und legt die 16 fertigen Wörter in `dl_ring` ab; T-RX schiebt sie hinaus. Der Push
kostet 34 Registerzugriffe und blockiert nicht: `go_pending` steht höchstens einen
`clk_sys`-Takt an [07 §3.2], und ein voller Warteschlangenplatz ist an `STATUS[1]` vorab
erkennbar.

Lesen ist in `07 §2.4` als nebenwirkungsfrei festgeschrieben — deshalb dürfen beide
Stränge Zähler lesen, ohne sich abzustimmen. Genau diese Eigenschaft fehlte V1 und erzeugte
den Haftbit-Wettlauf zweier Prozesse.

### 2.4 Modulschnitt und erlaubte Abhängigkeitsrichtung

```
 L5 Betrieb      tetra_bsd (main)  tetra_status  tetra_log        │ darf L4…L0
 L4 Protokoll    tetra_mm  tetra_cmce_call  tetra_sds  tetra_sds_tl │ darf L3…L0
 L3 Vermittlung  tetra_mle  tetra_llc  tetra_mm_ie      (09 §2.2)  │ darf L2…L0
 L2 MAC          tetra_mac_dl  tetra_mac_ul  tetra_mac_reass      │ darf L1, L0
 L1 Codierung    tetra_channel_coding                  (05 §2.4)  │ darf nur tetra_bits
 L0 Plattform    tetra_hal (nur aus L5 aufrufbar)  tetra_ts_map
                 tetra_bits  tetra_cfg  tetra_subscriber_db
                 tetra_ring  tetra_rf                            │ —
```

**Regeln (R-13-09):**

1. Kein Aufruf zeigt aufwärts. Ein Modul meldet ein Ergebnis über seinen Rückgabewert oder
   über eine Rückrufschnittstelle, die der **Aufrufer** setzt — nie durch Einbinden eines
   höheren Kopfes.
2. Schichtsprünge sind nur nach **L0** erlaubt — die Erlaubnisspalte oben ist wörtlich zu
   nehmen: L0-Plattformmodule sind für jede Schicht sichtbar, L1…L4 dürfen jeweils nur die
   unmittelbar darunter liegende Protokollschicht und L0 sehen. **Ausnahme innerhalb von
   L0:** `tetra_hal` darf **nur** aus L5 aufgerufen werden; **kein** Modul aus L1…L4 ruft
   die HAL auf. Der einzige Sendeweg ist `tetra_dl_emit()` in L2 (`tetra_mac_dl`),
   der einzige Empfangsweg der Ring in L0 (`tetra_ring`).
3. `tetra_ts_map` ist **reine Arithmetik** (ETSI-1-basiert ↔ RTL-0-basiert,
   Zeitschlitz-Bitmuster, Frame-Index) und kennt **keine** Registeradresse. V1s Fassung
   bindet `tetra_hal.h` ein und liefert Registeradressen aus
   [CODE sw/tetra_ts_map.h:20, :66-76] — damit hängt das zentrale Umrechnungsmodul an der
   Registerkarte und ist ohne Hardware nicht testbar.
4. `tetra_hal` hat **kein** `main()` (R-13-07). V1s `tetra_hal.c` trägt eines
   [CODE sw/tetra_hal.c:1578], weshalb zwei andere Programme die Abbildungsfunktionen
   **kopieren** — mit ausgeschriebener Begründung: *„tetra_hal.c carries main() and can't be
   linked in without pulling in the sysinfo app"* [CODE sw/tetra_attach_daemon.c:49-51,
   sw/tetra_ul_mon.c:26-28]. Drei Kopien derselben Abbildungsfolge.
5. Anwendungsmodule binden `tetra_hal.h` ein — darin stehen **nur** die getypten
   Operationen aus `07 §3.11`. Die rohen Zugriffsfunktionen liegen in
   `tetra_hal_internal.h`, das ausschließlich `tetra_hal.c` und das Hochlauf-Werkzeug
   einbinden dürfen (R-13-08). In V1 sind sie `static inline` im öffentlichen Kopf
   [CODE sw/tetra_hal.h:501-507] und werden aus **sechs** Modulen außerhalb der HAL an
   79 Stellen aufgerufen (`tetra_attach_daemon.c` 33, `tetra_voice_filler.c` 18,
   `tetra_ul_mon.c` 11, `tetra_voice_pipe.c` 8, `tetra_tx_transport.c` 6,
   `tetra_call_fsm.c` 3).

`tetra_mm_ie` liegt in L3, nicht in L4: dieselbe Annex-E-Elementmechanik gilt für MM, CMCE
und Kurznachrichten (`09 §2.2`), also darf kein L4-Modul sie besitzen.

**Übersetzungsziele.** Genau zwei: `tetra_bsd` (der Dienst) und `tetra_bringup` (das
Hochlauf- und Diagnosewerkzeug, das die B-Schritte aus `01 §3.8` ausführt und **nicht**
gleichzeitig mit dem Dienst läuft). Dazu die Einheitentests gegen die Host-Übersetzung
(`14_VERIFICATION`).

### 2.5 Was V2 aus V1 nicht erbt

| V1-Bestand | Befund | V2-Regel |
|---|---|---|
| Zwei Verzeichnisse für die Bedienoberfläche: `sw/web/` (ausgeliefert) und `sw/www/` (verwaist — das Auslieferungsskript berührt es nicht [CODE scripts/deploy.sh:261-280]) | Beide enthalten `index.html` und einen Anwendungsendpunkt mit **unterschiedlicher** Duplex-Zuordnung und **unterschiedlichem** Persistenzort: `sw/web/apply.cgi` schreibt `/root/tetra_cell.conf` mit editierbarer Achtzeilen-Tabelle [CODE sw/web/apply.cgi:16, :64-71]; `sw/www/cgi-bin/apply.cgi` schreibt `/tmp/tetra_cell.conf` (flüchtig) mit fest verdrahteten, **abweichenden** Werten (0→−10 MHz, 1→−7 MHz, 3→−8 MHz, 4→−5 MHz, 5→−9,5 MHz) [CODE sw/www/cgi-bin/apply.cgi:34, :63-68] | **R-13-11:** genau ein Verzeichnis. Eine verwaiste Zweitfassung mit abweichenden Zahlen ist gefährlicher als keine: sie sieht wie die Wahrheit aus. |
| Nicht genutztes Kernmodul `sw/tetra_char_dev.c` (508 Zeilen), in kein Startskript eingebunden, mit einem **still falsch definierten** Makro: `#define TETRA_STATUS_FRAME-valid (1 << 3)` — der Präprozessor nimmt `TETRA_STATUS_FRAME` als Makronamen und `-valid (1 << 3)` als Rumpf; gcc meldet dazu „ISO C99 requires whitespace after the macro name", und weil das Modul mit `ccflags-y := -Wall -Werror` gebaut würde [CODE sw/Makefile:25], ist die Datei mit ihren **eigenen** Bauflaggen nicht übersetzbar. Auffallen kann das nicht: das Modulziel hängt nicht an `all` [CODE sw/Makefile:22, :32], wird also nie gebaut | Führt außerdem einen **eigenen**, von `tetra_hal.h` abweichenden Registersatz (`TETRA_REG_CTRL = 0x0008` gegen `REG_CTRL = 0x00`) | **R-13-06 + R-13-10:** kein Kernmodul, und keine Datei ohne Übersetzungsziel. Eine Datei, die nie übersetzt wird, ist keine Reserve — sie ist eine falsche Landkarte. Beleg: [CODE sw/tetra_char_dev.c:59, :47-53] |
| Vorgabewerte an sieben Stellen: `MCC = 901` steht in `sw/tetra_hal.c:1583` und `:1319`, `sw/web/apply.cgi:44`, `sw/web/cgi-bin/config.cgi:18`, `sw/web/index.html:101`, `sw/www/index.html:57`, `sw/www/cgi-bin/apply.cgi:16`, `board_autostart/tetra_autostart.sh:211` — und **nicht** in der ausgelieferten Konfigurationsdatei [CODE board_autostart/tetra_cell.conf], deren Pflichtprüfung die Zellidentität nicht abdeckt [CODE board_autostart/tetra_autostart.sh:37-44] | Die Zellidentität kommt im Auslieferungszustand aus einer Rückfallkonstante im Startskript | **R-13-12 + R-13-14:** ein Ort. Die Konfigurationsvorlage. |
| Bedienoberfläche greift auf Register und Protokolldateien zu: `busybox devmem` [CODE sw/web/cgi-bin/policy.cgi:34, :109, sw/web/cgi-bin/sessions.cgi:18], Treiber-Attributdateien [CODE sw/web/apply.cgi:167-169], und `metrics.cgi` gewinnt Fehlerrate, Bit-Differenz und Soft-Betrag durch **Regex-Suche in der Standardfehlerausgabe des Daemons** [CODE sw/web/cgi-bin/metrics.cgi:37-52] | Das Protokollformat ist damit eine Schnittstelle: eine geänderte Protokollzeile bricht die Anzeige stumm. `sessions.cgi:39-40` liest zusätzlich `0x43C00200` — ein Fenster, das es seit dem Umbau vom 2026-05-20 nicht mehr gibt [CODE sw/tetra_hal.h:250-252], also stumm 0 — und `0x43C00230` (= `REG_REPLY_USE_SW`, existiert weiterhin [CODE sw/tetra_hal.h:272], liefert einen echten Wert) | **R-13-13 + R-13-25:** strukturierte Zustandsdatei, keine Regex-Diagnose, kein Registerzugriff aus der Oberfläche. |
| Zellparameter zweimal: in der Datei **und** als 17 Aufrufargumente [CODE sw/web/apply.cgi:171-193, board_autostart/tetra_autostart.sh:209-228] | Eine Änderung beendet den Prozess und startet ihn neu [CODE sw/web/apply.cgi:164, :171]; dabei springt die Hyperframe-Nummer auf ihren Anfangswert zurück [CODE sw/tetra_hal.c:1619] und die Zeitbasis wird neu geladen [CODE sw/tetra_hal.c:1777] | **R-13-14, R-13-17, R-13-18, R-13-20** |
| Hyperframe-Fortschreibung aus einem Software-Zeitgeber: alle 2 s auffrischen, jede 30. Auffrischung erhöhen = 60 s, bei einem Luft-Hyperframe von 61,2 s [CODE sw/tetra_hal.c:1882, :1907-1910] | Systematischer Versatz von 1,2 s je Hyperframe | **R-13-20:** aus dem Überlauf des PL-Zählers. |

---

## 3. Detail-Spezifikation

### 3.1 Prozess `tetra_bsd` — Hochlauf, Betrieb, Beendigung

**Aufrufzeile (abschließend, R-13-14):**

```
tetra_bsd [--config PATH] [--foreground] [--log-level L] [--log-category MASK]
```

Vorgabe für `--config`: `/etc/tetra/cell.conf`. **Kein** Zellparameter ist ein Argument.

**Hochlauf (in dieser Reihenfolge; jeder Fehlschlag beendet mit einer Meldung, die die
Ursache benennt):**

| Schritt | Aktion | Fehlerverhalten |
|---|---|---|
| S1 | Konfiguration lesen und prüfen (§3.7) | fehlender Pflichtschlüssel → Abbruch mit Nennung des Schlüssels; Wert außerhalb des Bereichs → Abbruch mit Schlüssel, Wert und Bereich |
| S2 | `tetra_hal_open()`: Apertur abbilden, `REG_ID` und `REG_VERSION.major` prüfen (`07 §3.11`) | Abweichung → Abbruch. **Kein** weiterer Zugriff, insbesondere kein Schreibzugriff — der Bitstrom ist unbekannt |
| S3 | `mlockall(MCL_CURRENT \| MCL_FUTURE)`; alle Ringe, Trellis-Ablagen und Puffer sind statisch und damit bereits eingelagert | Fehlschlag → Warnung, Fortsetzung ohne Echtzeit-Vorrang, `rt_degraded = 1` in der Zustandsdatei |
| S4 | **Ruhigstellung** (R-13-19): für alle vier Zeitschlitze `mode = PERSIST_CLEAR` auf der DL-Mailbox, `REG_SLOT_STATE_TSn` = 0 (unbelegt, Ruhemuster entsteht daraus im PL), Rufplatztabelle leeren, `GRANT_EN` = 0 und alle vier Magazin-Einträge `valid` = 0 (`07 §3.1.6`) — der Rücksetzzustand des Zuweisungsblocks wird aktiv hergestellt, damit ein Eintrag einer abgestürzten Vorinstanz nicht weiterverteilt wird | — |
| S5 | Zellkonfigurationsregister, Zeitplan (Seite 4), TX-Payload-Bänke (Seite 3: Füllblöcke, Broadcast, Leerlauf-PDU) schreiben | Rücklesefehler → Abbruch |
| S6 | Teilnehmer-Datenbank laden (geteilte Sperre, §3.8) | fehlende Datei = leere Datenbank (zulässiger Erstzustand); Syntaxfehler in einer Zeile → Zeile überspringen, `db_parse_err_cnt` +1 |
| S7 | Signalbehandlung einrichten: `SIGTERM`/`SIGINT` → Beendigung, `SIGHUP` → Konfiguration neu lesen, `SIGUSR1` → Zustandsabbild in das Protokoll | — |
| S8 | T-RX starten (`SCHED_FIFO`, Vorrang 20), danach T-CTL (`SCHED_OTHER`) | — |
| S9 | **Uplink-Zuweisung freigeben:** `GRANT_EN` = 1 in `REG_UL_ASSIGN_CFG` schreiben und zurücklesen (`07 §3.1.6`) | Rücklesefehler → Abbruch |

**Warum S9 ein eigener und der letzte Schritt ist.** Der Rücksetzwert von `GRANT_EN` ist
**0** (`07 §3.1.6`, R-07-19): ohne diesen Schreibvorgang erteilt das PL nie eine Zuweisung,
und keine Anmeldung kommt zustande. Der Schritt gehört **nach** S8, weil das Magazin nur
von T-CTL gefüllt wird (`06 §3.9.3`); vorher freigegeben, laufen die ersten Auslöser in
`GRANT_ARM_TIMEOUT` und zählen `grant_starved_cnt` (`06 §3.13`). Ein leeres Magazin ist
dabei zulässig und kein Fehler — für ein erstmals gesehenes Endgerät ist es der Normalfall
(`06` O-06-1). Beim Beenden wird die Freigabe mit S4 wieder zurückgenommen.

Die Reihenfolge S4 vor S5 ist bindend: ein aus einer abgestürzten Vorinstanz stehender
Sprach-Halteplatz sendet sonst weiter Fremdinhalt auf einem Sprachslot. V1 löst dasselbe
Problem an derselben Stelle und nennt die gemessene Folge: *„Mit aktivem mask sendet der
Voice-Relay-Pfad in idle-FN Garbage auf der voice-slot TN → SDR# zeigt 8-12% MER"*
[CODE sw/tetra_attach_daemon.c:1031-1036].

**Beendigung** (Signal, Frist 200 ms): T-RX und T-CTL setzen ihr Laufbit zurück und
verlassen ihre Schleife an der Iterationsgrenze → Ruhigstellung wie S4 → Teilnehmer-
Datenbank sichern, falls verändert → Protokollring entleeren → `tetra_hal_close()`.
Wird die Frist überschritten, endet der Prozess trotzdem; die Ruhigstellung ist der
**erste** Schritt und damit immer erledigt.

**Betriebsart im Verbund.** Genau eine Diensteinheit hält `tetra_bsd`, mit
Wiederanlauf bei Fehlschlag. Die Hochlaufschritte B1–B12 aus `01 §3.8` gehören einer
**anderen**, einmalig laufenden Einheit; `tetra_bsd` ist B13. Details der Einheiten:
`15_BUILD_DEPLOY`.

### 3.2 T-RX — der Slot-Strang

**Frist:** ein Zeitschlitz, 14,167 ms [ETSI §9.3.3]. **Kadenz:** 2 ms auf absolutem
Raster (R-13-05). **Vorrang:** `SCHED_FIFO` 20 (R-13-28).

```c
/* Iteration. Jede Schleife hat eine Obergrenze — kein unbeschränktes while. */
for (;;) {
    t0 = mono_us();
    for (n = 0; n < 4; n++) {                      /* 1. UL-Mailbox leeren  */
        if (!hal_ulmb_valid()) break;
        hal_ulmb_pull(&burst);        /* W0..W(2+N), dann ACK    (07 §3.4)  */
        rx_handle_burst(&burst);
        if (!hal_ulmb_more()) break;  /* STATUS[1]               (R-13-04)  */
    }
    for (n = 0; n < 4; n++) {                      /* 2. DL-Ring entleeren  */
        if (!ring_pop(&dl_ring, &pdu)) break;
        if (hal_dlmb_busy_or_full()) { dl_push_defer_cnt++; ring_unpop(&dl_ring); break; }
        hal_dlmb_push(&pdu);          /* 16 Wörter + GO          (07 §3.3)  */
    }
    voice_sync_holds();               /* 3. Halteplätze gegen Freigabetabelle */
    dt = mono_us() - t0;              /* 4. Gesundheit                       */
    if (dt > rx_iter_max_us) rx_iter_max_us = dt;
    if (dt > 4000) rx_deadline_miss_cnt++;
    next += 2 ms;  clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
}
```

**`rx_handle_burst` — Verzweigung nach `W0.burst_type` (`07 §3.4`):**

| `burst_type` | Kette | Ergebnis |
|---|---|---|
| `00` Control Uplink Burst | `tetra_cc_decode_soft(TETRA_CC_SCH_HU, …)` | 92 Informationsbits + Prüffeld-Verdikt + Zeitstempel `W1` + `W2`-Diagnose → `ul_ring` |
| `01` Normal Uplink Burst, Zeitschlitz **reservierungsaktiv** | `tetra_cc_decode_soft(TETRA_CC_SCH_F, …)`. Prüffeld gültig → Fortsetzung einer Fragmentkette → `ul_ring`. Verletzt → verwerfen, `cc_crc_fail` +1 | Signalisierung |
| `01` Normal Uplink Burst, Zeitschlitz **nicht reservierungsaktiv** | `tetra_cc_decode_soft(TETRA_CC_TCH_S, …)` → BFI → Neucodierung → DL-Halteplatz auf `target_ts = tetra_ts_etsi_from_tn(W1.tn_ul)` (= `tn_ul + 1`, ETSI-1-basiert; die Umrechnung liegt ausschließlich in `tetra_ts_map`) | Sprache |
| `10`/`11` reserviert (`07 §3.4`) | **keine** — Burst wird ohne Decodierversuch verworfen, `ACK` trotzdem gesetzt, `ul_burst_type_unsupported_cnt` +1 | Verwurf (`18` R-18-07) |

Die Tabelle deckt alle vier Werte des 2-bit-Feldes ab; einen stillen Durchfall gibt es
nicht. `burst_type` benennt nur den Erfassungszweig der PL (`07 §3.4`), **nicht** den
logischen Kanal — die Kanalzuordnung entsteht erst hier.

**Die Unterscheidung kommt aus dem Zustand, nicht aus einem Decodierversuch.** Ein
Normal-Uplink-Burst trägt entweder Sprache oder eine Fragmentkette. Welches von beidem, ist
**software-lokal bekannt**: eine Mehrslot-Reservierung existiert nur, weil T-CTL sie erteilt
hat (`06 §3.9`, `11 §3.7`), und der Sprach-Zeitschlitz wird vom Rufplatz-Verwalter zugeteilt
(`10 §3.10`). T-CTL setzt deshalb je Zeitschlitz ein Bit in `resv_active[0..3]`
(`_Atomic uint8_t`, gesetzt mit dem Erteilen der Reservierung, gelöscht mit Kettenende oder
Fensterablauf), und T-RX verzweigt danach. **Indexbasis, ausgeschrieben:** Index =
`tn` (RTL, 0-basiert) = `TS`(ETSI) − 1, also `resv_active[W1.tn_ul]` unmittelbar aus dem
Zeitstempel; dieselbe Basis gilt für `voice_hold[0..3]` und `call_quiet_cnt[0..3]` (§3.4).
Die Umrechnung nach ETSI geschieht ausschließlich in `tetra_ts_map` und nur dort, wo eine
ETSI-Nummer nach außen geht (HAL-Grenze, Protokoll, Zustandsdatei, Bedienoberfläche);
Ad-hoc-`±1` ist verboten. Zähler: `rx_schf_attempt_cnt`, `rx_schf_skipped_cnt`.

**Warum nicht „erst SCH/F versuchen, dann Sprache".** Diese Selbstfilterung ist in V1
richtig, weil der SCH/F-Decoder dort in der Hardware liegt und je Burst nichts kostet
(`03 §3.7`). In V2 kostet sie **53,8 µs Host je Sprachburst** (§3.12.1) und wäre damit der
**größte einzelne Lastposten der gesamten Software**: bei drei Sprachkanälen 1,78 ms/Frame
auf dem A9 gegen 0,96 ms für alles andere zusammen — eine Verdreifachung der Last für eine
Unterscheidung, die kostenlos vorliegt. Eine Eigenschaft der Hardware ist keine Eigenschaft
der Software.

> **Randfall:** Ist `resv_active[tn]` fälschlich gesetzt, wird ein Sprachburst als Fragment
> gedeutet. `tetra_mac_reass` verwirft ihn, weil PDU-Typ und Fragmentflag nicht passen
> (`06 §3.11`), zählt `reass_bogus_cnt` — und der Sprachrahmen fehlt. Deshalb ist das Bit
> **nur** von T-CTL beschreibbar, wird beim Erteilen der Reservierung gesetzt (also vor dem
> ersten Uplink-Slot, in dem das Endgerät senden darf) und beim Kettenende gelöscht. Zeigt
> `reass_bogus_cnt` im Betrieb Zuwachs, ist der Rückfall auf den unbedingten
> SCH/F-Versuch die Gegenmaßnahme (§6, O-13-4).

**Zielschlitz der Sprachweiterleitung** kommt aus `W1.tn_ul` (R-00-04), nicht aus einer
Stoppuhr. V1 liest `REG_TS1_STOPWATCH_DELTA` und muss dafür eine Lesereihenfolge gegen die
Burst-Erkennung einhalten, im Quelltext als Bedingung ausgeschrieben
[CODE sw/tetra_voice_pipe.c:93-96] — eine Wettlauf-Konstruktion, die mit dem Zeitstempel
entfällt (`12 §2.3`).

**Selbstprüfung des Zeitstempels (R-08-10, `08 §3.7` Regel 3):** T-RX rechnet aus
`W1.sym_anchor` (`W1[26:19]`, Symbolindex des Sync-Ankers im Slot, `07 §3.4`) und
`REG_AIRLOCK_DELTA_CYC` den Uplink-Zeitschlitz nach und vergleicht ihn mit `W1.tn_ul`
(`W1[1:0]`, RTL-0-basiert). Beide Aussagen entstehen unabhängig — `tn_ul` aus der
TDMA-Zählerkette, `sym_anchor` mit der Stoppuhr —, deshalb prüft der Zeitstempel sich
selbst. `W2` trägt kein Zeitfeld und geht in diese Rechnung nicht ein; `W2.corr_peak` und
`W2.sym_norm` sind Erfassungs-Diagnose. Abweichung → `ul_ts_mismatch_cnt` +1. Der Burst
wird **trotzdem** verarbeitet: der Zähler ist ein Frühwarnsignal, kein Filter.

**Verbotsliste (R-13-03).** T-RX enthält keine der Funktionen `open`, `fopen`, `read`,
`write`, `stat`, `rename`, `fsync`, `malloc`, `calloc`, `free`, `printf`, `snprintf`,
`syslog`. Die Viterbi-Trellis-Ablage ist statisch (`12` R-12-17; V1 holt sie je Aufruf vom
Haufen [CODE sw/tetra_bs_tch_s.c:269, :313]). Protokollierung geschieht ausschließlich
durch Ablegen eines Binär-Ereignissatzes im Ring (§3.10.1).

### 3.3 T-CTL — der Protokoll-Strang

**Frist:** ein bis zwei TDMA-Frames (`08 §2.3`). **Kadenz:** 10 ms auf absolutem Raster.
**Vorrang:** Standard.

```c
for (;;) {
    /* 1. Empfangsring VOLLSTÄNDIG entleeren — kein Limit: Rückstau ist schlechter
     *    als eine lange Iteration, und T-RX ist davon unabhängig. */
    while (ring_pop(&ul_ring, &blk))
        tetra_mac_ul_rx(&blk);        /* 06 §3.5 → LLC → MLE → MM/CMCE/SDS  */

    /* 2. Zeitgeber. now_slot aus dem letzten gesehenen Zeitstempel (08 §3.7
     *    Regel 2), now_ms aus CLOCK_MONOTONIC nur für Ruf-Überwachung mit
     *    Toleranz >= 100 ms (R-08-13). */
    tetra_mac_reass_tick(now_slot);   tetra_llc_tick(now_slot);
    tetra_cmce_call_tick(now_ms);     tetra_sds_tick(now_ms);

    /* 3. Haushalt, 1-s-Raster */
    if (due_1s()) {
        cfg_check_and_reload();  status_snapshot_write();  log_ring_drain();
        pl_counters_sample();    subscriber_db_flush();    /* §3.7, §3.8, §3.10 */
    }
    sleep_until_next_10ms();
}
```

**Sendeweg.** Jede Downlink-PDU entsteht über **eine** Funktion (P3):

```c
/* tetra_mac_dl.c — der einzige Sendeweg der Signalisierung. */
typedef struct {
    const uint8_t *tm_sdu;      /* ein Bit je Byte, Index 0 = zuerst gesendet   */
    uint16_t       n_bits;
    uint8_t        target_ts;   /* ETSI 1..4                                    */
    uint8_t        prio;        /* 07 §3.3 W14[6:5]                             */
    uint8_t        delay_slots; /* 07 §3.3 W14[26:21]; nur Staffelung identischer
                                * Wiederholungen (10 §3.4.3). Kein Antwortabstand
                                * — der ist ereignisgetriggert (08 R-08-11).     */
} tetra_dl_req_t;

/* Baut MAC-Kopf, fragmentiert falls nötig (06 §3.11), codiert je Burst über
 * tetra_cc_encode (05) und legt jeden fertigen Burst in dl_ring ab.
 * Rückgabe: Anzahl eingestellter Bursts, oder < 0 wenn dl_ring voll
 * (dl_ring_full_cnt +1). Es wird ENTWEDER die ganze Kette eingestellt ODER
 * keine — eine halbe Fragmentkette auf der Luft ist schlimmer als keine. */
int tetra_dl_emit(const tetra_dl_req_t *req);
```

Broadcast (Systeminformation, Netz-Broadcast) benutzt einen zweiten, **anderen**
Mechanismus — die TX-Payload-Bänke auf Seite 3 bzw. `mode = PERSIST_SET` — und ist damit
kein zweiter Pfad für dieselbe Sache, sondern ein anderer Vorgang: langlebiger Inhalt statt
Einzelaussendung (`07 §2.3`, §3.5).

**Ruf-Steuerung schreibt keine Register.** `tetra_cmce_call` verwaltet die Rufplatztabelle
und **leitet** daraus die Zeitschlitz-Größen ab; das Schreiben von `REG_SLOT_STATE_TSn`
(`SLOT_UMT`/`SLOT_UL_STATE`) besorgt die HAL-Operation, die T-CTL aufruft (`10 §2.2`). Ein
fertiges AACH-Infowort schreibt die Software überhaupt nicht (`06` R-06-05). V1 schreibt das
Infowort-Register direkt aus der Rufsteuerung [CODE sw/tetra_call_fsm.c:130-138] und
verletzt damit R-13-08 und die Ein-Wahrheit-Regel aus `10 §2.2`.

### 3.4 Datenübergabe zwischen den Strängen

**Kein Sperrobjekt auf dem Registerpfad.** Fünf Übergabemittel, alle mit fester Größe:

| Name | Art | Tiefe × Satzgröße | Richtung | Überlaufverhalten |
|---|---|---|---|---|
| `ul_ring` | Einzelerzeuger/Einzelverbraucher, sperrfrei (`_Atomic` Schreib-/Leseindex, Freigabe-/Erwerbs-Ordnung) | 64 × 64 Byte | T-RX → T-CTL | **neuen** Satz verwerfen, `ul_ring_drop_cnt` +1 (gleiche Regel wie die PL-Mailbox, `07 §3.2`) |
| `dl_ring` | Einzelerzeuger/Einzelverbraucher, sperrfrei | 16 × 68 Byte (16 Wörter + Kopf) | T-CTL → T-RX | Einstellen schlägt fehl, `dl_ring_full_cnt` +1, Aufrufer entscheidet |
| `voice_hold[0..3]` | Feld aus vier `_Atomic uint32_t`: `[0]` Freigabe, `[15:8]` Generationszähler. Index = `tn` (RTL, 0-basiert) = `TS`(ETSI) − 1 | 4 Wörter | T-CTL → T-RX | keiner: letzter Schreibwert gewinnt |
| `resv_active[0..3]` | vier `_Atomic uint8_t`: Zeitschlitz trägt eine reservierte Fragmentkette (§3.2). Index = `tn` (RTL, 0-basiert) = `TS`(ETSI) − 1 | 4 Byte | T-CTL → T-RX | keiner |
| `log_ring` | Mehrerzeuger/Einzelverbraucher, sperrfrei über Index-Vergleich-und-Tausch | 512 × 32 Byte | beide → T-CTL | Satz verwerfen, `log_drop_cnt` +1 |

**Warum `dl_ring` klein und `ul_ring` groß ist.** `ul_ring` deckt mit 64 Plätzen ≈ 16
TDMA-Frames Rückstau ab [ANNAHME: höchstens 4 Bursts je Frame]; Rückstau in der
Empfangsrichtung kostet Latenz und wird vom Endgerät durch Wiederholung ausgeglichen.
`dl_ring` deckt mit 16 Plätzen 4 Frames Vorlauf ab — mehr wäre **schädlich**: Rückstau in
der Senderichtung erzeugt veraltete Aussendungen, genau das Muster der Zuweisungs-Spirale
aus `00 §3.4` [MESS 2026-07-11]. In der Senderichtung ist Verwerfen mit Zähler richtig,
Puffern falsch.

**Sprach-Halteplätze.** T-CTL setzt `voice_hold[tn].enable` beim Rufaufbau und löscht es
bei Ruhe-Erkennung, Freigabe oder Wachhund-Auslösung (`10 §3.10`, `12 §3.6`). Der Index ist
`tn` (RTL, 0-basiert) = `TS`(ETSI) − 1; die HAL-Operation nimmt dagegen `target_ts` in
ETSI-Zählung (§3.6) — die eine Umrechnung dazwischen liegt in `tetra_ts_map`. T-RX führt
das aus: `enable = 0` und Halteplatz aktiv → `mode = PERSIST_CLEAR` auf `target_ts`.
Damit besitzt weiterhin **nur** T-RX die DL-Mailbox (§2.3), und die von `12 §3.4`
geforderte Unteilbarkeit von Schreiben und Übernahme einer Bank ist trivial erfüllt, weil
nur ein Strang sie ausführt.

### 3.5 Abfrage statt Unterbrechung — Entscheidung und Latenzfolgen

**Entscheidung: Abfrage** (R-13-06, gleichlautend `07` R-07-14).

| | Abfrage, 2-ms-Raster | Unterbrechung |
|---|---|---|
| Weckverzögerung bis zur Bearbeitung | Mittel 1 ms, ungünstigster Fall 2 ms | Größenordnung 10…100 µs [ANNAHME: übliche Weckverzögerung eines Anwendungs-Handlers unter Linux 5.10 auf Cortex-A9; nicht gemessen] |
| Frist, gegen die das zählt | 14,167 ms (`07 §3.8`, ein Uplink-Slot mit bis zu zwei Einträgen: 28 ms) | dieselbe |
| Anteil der Frist, den die Verzögerung verbraucht | ungünstigster Fall **14 %** | ≈ 0,7 % |
| Kosten in der Hardware | keine | Unterbrechungsregisterpaar, Leitung zum PS, Verdrahtung im Blockdesign |
| Kosten in der Software | 2 Registerlesevorgänge je Iteration = 1000 Lesevorgänge/s ≈ **0,1 ms/s** Buslast | Kernel-Treiber oder Gerätedatei-Anbindung, zweiter Wartemechanismus, Behandlung verlorener Flanken |
| Bestand in V1 | Abfrage, funktioniert | Vollständig verdrahtet und **wirkungslos**: drei von fünf Quellen konstant 0, `irq_enable` nach Rücksetzen 0, und die Software schreibt `REG_IRQ_ENABLE` nie [CODE sw/tetra_hal.h:41 — nur `#define`, keine Verwendung in `sw/*.c`]; das mitgelieferte Kernmodul hängt an keinem gebauten Ziel und ist mit seinen eigenen Bauflaggen (`-Werror`) nicht übersetzbar [CODE sw/Makefile:22, :25, :32 gegen sw/tetra_char_dev.c:59] |

Die Unterbrechung gewinnt 1 bis 2 ms gegen eine Frist von 14 ms, bei einer Bearbeitungszeit
von 0,62 ms im ungünstigsten Fall (§3.12.3). Das ist kein Gegenwert für einen Kernel-Treiber.

**Was bei Verletzung der Frist zu tun ist — und was nicht.** Wird `rx_deadline_miss_cnt`
> 0 oder `REG_MB_UL_DROP_CNT` > 0 gemessen, ist die Reihenfolge der Maßnahmen: (1)
Kadenz auf 1 ms verkürzen (Buslast verdoppelt sich auf 0,2 ms/s — irrelevant), (2) die
Bearbeitung je Iteration profilieren, (3) einen dritten Puffer im PL für den betroffenen
Erzeuger vorsehen (`07 §3.8` benennt die Kosten: 3456 bit Blockspeicher für eine dritte
Sprachbank). **Eine Unterbrechung löst keinen dieser drei Fälle** — sie verkürzt die
Weckverzögerung, nicht die Bearbeitungsdauer.

### 3.6 Hardware-Abstraktionsschicht

**Vertrag:** `07 §3.11` legt die Operationen fest. Dieses Kapitel legt die Bauform fest.

| Eigenschaft | Festlegung |
|---|---|
| Bauform | Statische Bibliothek `libtetrahal.a`, **kein** `main()` (R-13-07) |
| Öffentlicher Kopf | `tetra_hal.h` — ausschließlich getypte Operationen; **keine** rohen Zugriffsfunktionen, **keine** Registeradressen (R-13-08) |
| Interner Kopf | `tetra_hal_internal.h` — rohe Zugriffe und Adressen; Einbindung nur in `tetra_hal.c` und `tetra_bringup.c` |
| Adressen und Bitfelder | **erzeugt** aus der Einzelquelle des PS↔PL-Vertrags (`07` R-07-17). Die erzeugte Datei ist nicht editierbar und trägt die Vertragsversion |
| Versionsprüfung | `tetra_hal_open()` liest `REG_ID` und `REG_VERSION`. Abweichende Kennung oder abweichende Hauptversion → Rückgabe < 0, **kein** Schreibzugriff erfolgt |
| Eigentümerprüfung | Jede schreibende Operation prüft im Debug-Bau die Strang-Kennung gegen die Tabelle aus §2.3 und bricht bei Verletzung ab (R-13-02). Im Auslieferungsbau entfällt die Prüfung |
| Zugriffsart | 32-bit-Zugriffe auf eine `MAP_SHARED`-Abbildung von `/dev/mem`, `volatile`; Speicherbarriere vor `GO`/`ACK`/`COMMIT` und nach dem Lesen von `STATUS`, damit der Übersetzer die Reihenfolge nicht verschiebt |
| Zeitschlitz-Umrechnung | ausschließlich über `tetra_ts_*` (`00 §2.2`); die HAL nimmt und liefert **ETSI-1-basierte** Zeitschlitznummern und rechnet an ihrer Grenze um |
| HF-Pfad | `tetra_rf.c` — Treiber-Attributdateien (Sende-/Empfangsfrequenz, Dämpfung, Verstärkungsmodus). **Nicht** Teil der Registerapertur, aber Teil von L0 und damit einziger Zugriffsort. Nach B13 ist `tetra_bsd` der einzige Schreiber (§3.7) |

**Bit-Konventionen an der HAL-Grenze** (P4, ausgeschrieben, nicht verwiesen): getypte
Operationen nehmen und liefern **ein Bit je Byte, Index 0 = zuerst gesendet** (`05` R-05-14,
`09 §2.1`). Die Umpackung in die Wortordnung der Mailbox geschieht **ausschließlich** in
`tetra_hal.c` nach den Formeln aus `07 §3.3` (codierte Bits, MSB-first, wortweise
absteigend) und `07 §3.4` (Soft-Werte, LSB-first, Index aufsteigend). Damit existiert die
Umkehr genau einmal. V1 hat sie an drei Orten mit drei Schreibweisen
[CODE sw/tetra_voice_filler.c:87-102, sw/tetra_hal.c:1526-1541,
sw/tetra_attach_daemon.c:108-125] und dazu eine als Fehlerbehebung kommentierte
Nachrüstung, weil zwei Darstellungen im selben Modul nebeneinander lagen
[CODE sw/tetra_attach_daemon.c:925-932].

### 3.7 Konfiguration

**Ort und Format.** Genau eine Datei ist die Wahrheit (R-13-14): `/etc/tetra/cell.conf`.
Zeilenformat `SCHLÜSSEL=WERT`, ein Paar je Zeile, `#` beginnt einen Kommentar, keine
Anführungszeichen, keine Ersetzungen, keine Fortsetzungszeilen. Damit ist das Format
**gleichzeitig** von einer Shell einlesbar (`source`) und von einem zeilenweisen Parser in
C — das ist der Grund für die Einschränkungen: das Hochlaufskript liest dieselbe Datei
(`01 §3.8`), und ein Format, das nur eine Seite versteht, erzeugt sofort eine zweite
Wahrheit. V1 nutzt diese Eigenschaft [CODE board_autostart/tetra_autostart.sh:34,
sw/web/cgi-bin/config.cgi:11] — und hebt sie durch 17 Aufrufargumente wieder auf (§2.5).

**Schlüsselgruppen.** Jeder Schlüssel hat genau einen Ort, Bereich und Verbraucher:

| Gruppe | Beispielschlüssel | Verbraucher | Wirkt bei `SIGHUP` |
|---|---|---|---|
| HF-Grundeinstellung | `TX_FREQ_HZ`, `SAMPLERATE_HZ`, `RF_BW_HZ`, `GAIN_MODE`, `TX_ATT_INIT_DB`, `TX_ATT_OP_DB`, `VCXO_DAC_VAL`, `XO_CORRECTION_HZ` | Hochlaufskript (B2–B9) **und** `tetra_rf` | Sendefrequenz, Empfangsfrequenz, Dämpfung: ja. Abtastrate, Bandbreite, VCXO: **nein** (Neustart des Hochlaufs nötig) |
| Duplex-Abstand | `DUPLEX_SPACING`, `DUPLEX_OFFSET_HZ_0` … `_7` | `tetra_rf` (Versatz) + Broadcast-Inhalt (3-bit-Kennung) | ja |
| Zellidentität | `MCC`, `MNC`, `LA`, `COLOUR_CODE`, `SYSTEM_CODE` | `REG_CELL_CFG_*`, Broadcast-Inhalt | ja — mit dem Hinweis, dass angemeldete Endgeräte sich neu anmelden |
| Broadcast-Parameter | `MS_TXPWR_MAX`, `RXLEVEL_ACCESS_MIN`, `ACCESS_PARAMETER`, `RADIO_DL_TIMEOUT`, `PRIORITY_CELL`, `MIGRATION`, `OPT_FIELD_*` | Broadcast-Inhalt: die von der Software erzeugte BNCH-Nutzlast, eingestellt über die TX-Nutzlastbänke (§3.3, `07 §3.5`) — **kein** Register mit Einzelfeldern | ja |
| Felder der SYNC-PDU | `NCB`, `CELL_LOAD_CA`, `LATE_ENTRY_SUPPORT` | `REG_CELL_CFG_0` (`07 §3.1.3`: `neighbour_cell_broadcast`, `cell_load_ca`, `late_entry_support`) | ja |
| Zuweisungsmuster | `GRANT_REPEAT`, `GRANT_GAP`, `GRANT_HOLD_MAX`, `GRANT_ARM_TIMEOUT` (Bedeutung `06 §3.12`) | `REG_UL_ASSIGN_CFG` (R-00-03) | ja |
| Empfangs-Arbeitspunkte | `NUB_SYNC_THRESH` | `REG_RX_SYNC_CFG_UL.thresh_nub` (`07 §3.1.4`; Wert und Messkontext `03 §4`) | ja (`03` R-03-03: die UL-Schwellen sind zur Laufzeit einstellbar) |
| Richtlinie | `ACCEPT_UNKNOWN_ISSI`, `ACCEPT_UNKNOWN_GSSI` | `tetra_mm` (R-13-22, `09 §3.6`) | ja |
| Profile | `PROFILE_n_GILA_CLASS`, `_GILA_LIFETIME`, `_PERMIT_VOICE`, `_PERMIT_DATA`, `_PERMIT_REG`, `_DEFAULT_GSSI` | `tetra_subscriber_db` | ja |
| Diagnose | `LOG_LEVEL`, `LOG_CATEGORY`, `LOG_MAX_BYTES`, `DIAG_DOUBLE_DECODE` (zweiter Decodierlauf, `12 §2.3`), `DIAG_FEC_DIFF` (XOR-Vergleich empfangen ↔ neucodiert, `12 §3.4.5`), `DIAG_SCHF_UNCONDITIONAL` (§6 O-13-4) | `tetra_log`, T-RX | ja |

**Zwei Empfangs-Arbeitspunkte, die bewusst *keinen* Schlüssel haben.** Die Gruppe
„Empfangs-Arbeitspunkte" trägt genau **einen** Schlüssel, und das ist eine Festlegung, keine
Auslassung:

1. **CIC-Ausgangsverstärkung (`CIC_GAIN_SHF`; Wert und Messkontext `02 §3.2` und `02 §4`).**
   Sie ist **Syntheseparameter**
   des RX-Frontends, weil sie über `CIC_OUT_LOW`/`CIC_WIDE_BITS` die Wortbreiten
   des Ausgangs-Slice und die Lage der Sättigungs-Guard-Bits festlegt. Ein Syntheseparameter
   ist nicht per Signal umschaltbar: es gibt für ihn **kein** Register in `07`, **keinen**
   Schlüssel in `cell.conf` und **keine** `SIGHUP`-Wirkung. Ein anderer Arbeitspunkt ist ein
   neuer Bitstream (`15_BUILD_DEPLOY`), keine Konfigurationsänderung.
2. **Korrelationsschwelle des Steuerkanal-Bursts (x-Sequenz, 15 Symbole).** Der gemessene
   Optimalwert **15** ist bereits der Rücksetzwert des Registerfelds
   `REG_RX_SYNC_CFG_UL.thresh_cb` (`07 §3.1.4`; Wert und Messkontext normativ in `03 §4`).
   Wer die Messreihe wiederholt, schreibt dieses Feld über die HAL (`03` R-03-03) — ein
   Konfigurationsschlüssel würde eine zweite Wahrheit für denselben Wert schaffen (P2).
   Ein Schlüssel `UL_RA_THRESH` existiert **nicht**; der Name bezeichnet keine Größe dieses
   Systems, und die zugehörige Messung gehört zur CB-Schwelle (`01 §4`).

**Das Zusammensetz-Fenster hat bewusst keinen Schlüssel.** Der Zeitgeber `T0` der
Fragment-Zusammensetzung (`08 §3.5.2`, `11 §3.7.3`) ist mit **9 Frames fest** und weder über
`cell.conf` noch über ein Register einstellbar. Begründung: der Wert ist keine
Zell-Eigenschaft, sondern die Spiegelung der ETSI-Endgerätekonstante `T.202` = 9
Downlink-Signalisierungs-Frames [ETSI Annex B.1]. Ein **kleinerer** Wert lässt die
Basisstation vor dem Endgerät aufgeben — genau der V1-Fehler, den `08 §3.5.2` als Befund
führt. Ein **größerer** Wert bringt nichts, weil das Endgerät die Kette nach `T.202` selbst
verworfen hat; er hält nur einen Kontext länger belegt, und gegen Vollstand wirkt die
Ältesten-Regel (`08 §3.5.3`), nicht ein kürzeres Fenster. Es gibt damit keinen
Feldbedarf, wohl aber ein Regressionsrisiko: ein einstellbarer Wert wäre die Einladung, im
Feld wieder auf 1 Frame zu gehen. Der Einstellbereich 1…15 Frames war ein 4-bit-Registerfeld
in V1; in V2 existiert dieses Register nicht (die Zusammensetzung liegt in Software), und ein
Konfigurationsschlüssel tritt **nicht** an seine Stelle.

**Zur Schreibweise `CELL_LOAD_CA`.** V1 nennt das 2-bit-Feld der SYNC-PDU „Cell Service
Level" und führt den Schlüssel als `CSL` [CODE sw/tetra_hal.c:1333, :1201]. Der ETSI-Bezeichner
dieses Felds ist **„Cell load CA"**; „cell service level" gehört zu einer anderen PDU
(`07 §3.1.3`). Der Schlüssel trägt in V2 den richtigen Namen, damit Konfigurationsdatei,
Registerfeld und Norm dieselbe Größe gleich benennen. `LATE_ENTRY_SUPPORT` braucht einen
Schlüssel, weil der Rücksetzwert dieses Bits 0 ist und ein Endgerät den Späteinstieg ohne
gesetztes Bit nicht versucht (`10 §3.8`). Die übrigen Felder desselben Registers
(`sharing_mode`, `ts_reserved_frames`, `u_plane_dtx`, `frame_18_extension`) haben in Stufe 1
**keinen** Schlüssel und bleiben auf ihrem Rücksetzwert.

**Duplex-Tabelle (R-13-15) — harte Anforderung, ausgeschrieben.** Zwei getrennte Größen:

```
DUPLEX_SPACING=0             # 3-bit-Kennung, geht als Broadcast-Feld auf die Luft
DUPLEX_OFFSET_HZ_0=-10000000 # Empfangs-LO − Sende-LO in Hz, je Kennung eine Zeile
DUPLEX_OFFSET_HZ_1=-45000000 #   _2=0  _3=-10000000  _4=-10000000
DUPLEX_OFFSET_HZ_7=-7600000  #   _5=-10000000  _6=-10000000
UL_FREQ_HZ=                  # leer = aus der Tabelle; gesetzt = übersteuert sie
```

`RX_FREQ_HZ = UL_FREQ_HZ`, falls gesetzt, sonst
`TX_FREQ_HZ + DUPLEX_OFFSET_HZ_<DUPLEX_SPACING>`.

**Warum eine Tabelle und keine Konstante:** die Zuordnung Kennung → Versatz ist eine
Eigenschaft des **Endgeräte-Codeplugs**, nicht der Zelle. Sie muss ohne Neuübersetzung
änderbar sein. Die Werte oben sind der V1-Auslieferungsstand
[CODE sw/web/apply.cgi:64-71], nicht ETSI-Konstanten. V1 hat dieselbe Größe an **drei**
Orten mit **drei** Werten: die editierbare Tabelle in `sw/web/apply.cgi:64-71`, eine fest
verdrahtete abweichende Tabelle in `sw/www/cgi-bin/apply.cgi:63-68`, und eine unbedingte
Textausgabe „duplex=10 MHz" im Hauptprogramm [CODE sw/tetra_hal.c:1709-1712].

**Zugriffsregeln.**

| Regel | Festlegung |
|---|---|
| Schreiber | **genau einer**: die Bedienoberfläche. `tetra_bsd` schreibt `cell.conf` nie |
| Leser | Hochlaufskript (einmal), `tetra_bsd` (bei S1 und bei jedem `SIGHUP` sowie bei Änderung der Änderungszeit, Prüfkadenz 1 s) |
| Änderung wirksam machen | Datei schreiben, dann `SIGHUP` an `tetra_bsd`. **Kein** Prozess-Neustart (R-13-17) |
| Unteilbarkeit | Schreiber: exklusive Sperre auf `cell.conf.lock`, Zwischendatei `cell.conf.tmp` **im selben Verzeichnis**, dann `rename` (R-13-16). Leser: geteilte Sperre |
| Gleichzeitiges Schreiben | Durch die exklusive Sperre serialisiert. Der zweite Schreiber liest nach Erhalt der Sperre **neu** und legt seine Änderung darauf — „letzter gewinnt" gilt je Feld, nicht je Datei |
| Ungültige Datei | Der geladene Zustand bleibt unverändert, `cfg_parse_err_cnt` +1, Protokolleintrag mit Zeilennummer und Schlüssel. Eine kaputte Datei darf eine laufende Zelle **nicht** abschalten |
| Änderungsverfolgung | `cfg_generation` zählt erfolgreiche Ladevorgänge und steht in der Zustandsdatei. Damit ist „hat mein Apply gewirkt?" ohne Protokolldatei beantwortbar |

Die Sperre liegt auf einer **eigenen** Datei, nicht auf der Datendatei: `rename` ersetzt
den Verzeichniseintrag, eine Sperre auf dem alten Dateiknoten wäre danach wirkungslos. Die
Zwischendatei liegt im **Zielverzeichnis**, weil `rename` über Dateisystemgrenzen nicht
unteilbar ist. V1 verletzt genau das: `TMP=/tmp/db.tsv.NEW`, `DB=/root/db.tsv`, dann `mv`
[CODE sw/web/cgi-bin/entities.cgi:17-18, :104-105] — bei `/tmp` als Speicher-Dateisystem
ist das ein Kopieren mit anschließendem Löschen. [ANNAHME: `/tmp` ist ein
Speicher-Dateisystem; die Regel gilt unabhängig davon.]

### 3.8 Teilnehmer-Datenbank

**Zweck und Semantik:** `09 §3.6` (Richtlinie, Selbsteintragung, Profilinhalt). Hier
Aufbau, Format, Persistenz und Nebenläufigkeit.

**Speicher.** Offene Streuwerttabelle über die 24-bit-Adresse, getrennte Tabellen für
Teilnehmer- und Gruppenadressen, je **1024 Plätze** bei einem Füllgrad ≤ 0,5 — also
**Kapazität 512 Einträge je Typ** (R-13-21); ein Einfügeversuch über diesen Füllgrad hinaus
wird mit Fehler abgewiesen und zählt `db_full_cnt`. Eintrag:

```c
typedef struct {
    uint32_t id;            /* 24 bit ISSI oder GSSI; 0 = Platz frei              */
    uint8_t  profile;       /* Index in die Profiltabelle                          */
    uint8_t  flags;         /* bit0 selbst eingetragen, bit1 gesperrt              */
    uint32_t first_seen;    /* Frame-Index (08 §3.7 Regel 2), 0 = aus der Datei    */
    char     name[24];      /* Freitext für die Bedienoberfläche, 0-terminiert     */
} tetra_subscriber_t;
```

V1 nutzt ein linear durchsuchtes Feld mit 256 Plätzen und durchläuft bei jedem
Nachschlagen **alle** 256, auch die leeren [CODE sw/tetra_db.c:167-175]; die Obergrenze 256
ist ein Erbe der entfallenen PL-Tabelle. Der Platzindex ist deshalb dort sogar Teil des
**Dateiformats** [CODE sw/tetra_db.c:86] — ein Feld, das nur die Zeilenreihenfolge doppelt.

**Dateiformat** `/etc/tetra/subscribers.tsv`, tabulatorgetrennt, `#` als Kommentar,
vier Pflichtfelder `type` (0 = ISSI, 1 = GSSI), `id` (dezimal, 0…16777215), `profile`,
`name`. **Kein Platzindex** (R-13-21). Zeilen mit fehlenden oder unplausiblen Feldern
werden übersprungen und gezählt.

Der Auslieferungszustand ist **leer** (R-13-23). V1 liefert zwei Zeilen aus — die Adresse
eines konkreten Testgeräts und eine Entwicklungs-Gruppenadresse
[CODE sw/db.tsv.default:11-12] — womit die Zellkonfiguration von einem Testgerät abhängt
(`09` R-09-13).

**Nebenläufigkeit — der belegte V1-Fehler.** Zwei Schreiber, keine Sperre: die
Bedienoberfläche schreibt die vollständige Datei neu
[CODE sw/web/cgi-bin/entities.cgi:104-105] (`grep flock` über alle CGI: kein Treffer), und
der Daemon schreibt bei jeder Selbsteintragung die **ganze** Datei aus seiner
Speicherkopie neu [CODE sw/tetra_db.c:178-208, :236] und aktualisiert dabei seine gemerkte
Änderungszeit, damit der eigene Schreibvorgang kein Neuladen auslöst
[CODE sw/tetra_db.c:207]; geprüft wird die Änderungszeit alle 5 s
[CODE sw/tetra_attach_daemon.c:1212-1220]. **Ergebnis:** eine Bedieneränderung, die in das
Fenster zwischen zwei Prüfungen fällt und vor der nächsten Selbsteintragung liegt, wird
überschrieben. Der Kopf der V1-Datenbank hält ausdrücklich fest, dass keine Sperre nötig sei
— *„The DB is process-local. No locking is required: tetra_attach_daemon is
single-threaded"* [CODE sw/tetra_db.h:18-19]. Das ist richtig **innerhalb** des Prozesses
und falsch für eine Datei, die ein zweiter Prozess schreibt.

**V2-Regel (R-13-16):**

| Vorgang | Ablauf |
|---|---|
| Lesen (Daemon S6, Bedieneranzeige) | geteilte Sperre auf `subscribers.tsv.lock` → lesen → freigeben |
| Ändern (Selbsteintragung im Daemon, Bedienereingabe) | exklusive Sperre → Datei **neu einlesen** → Änderung anwenden → `subscribers.tsv.tmp` im selben Verzeichnis schreiben, `fsync`, `rename` → freigeben |
| Wer sichert | Beide Seiten dürfen. Das erneute Einlesen unter der Sperre macht „letzter gewinnt" je **Zeile** statt je Datei |
| Wo liegt `fsync` | **In T-CTL**, im 1-s-Haushalt (`subscriber_db_flush`), nie im Anmeldepfad. Eine Selbsteintragung setzt ein Änderungsbit; das Sichern folgt bis zu 1 s später. Verlust bei Stromausfall: höchstens eine Sekunde Selbsteintragungen — gegen die Alternative, den Anmeldepfad um einen Flash-Schreibvorgang zu verlängern (§2.1), ist das der richtige Handel |

### 3.9 Bedienoberfläche

**Aufbau.** Ein Verzeichnis `sw/webui/` (R-13-11), ausgeliefert nach `/www`:

```
/www/index.html                 eine Seite, drei Ansichten: Konfiguration, Live, Teilnehmer
/www/cgi-bin/config             GET  → Konfiguration als JSON (aus der Datei)
                                POST → prüfen, Datei unter Sperre schreiben, SIGHUP
/www/cgi-bin/status             GET  → Inhalt der Zustandsdatei, unverändert durchgereicht
/www/cgi-bin/subscribers        GET  → Teilnehmerliste als JSON
                                POST → op=add|del|edit, Datei unter Sperre ändern
/www/cgi-bin/control            POST → op=start|stop|restart über die Diensteinheit
```

**Regeln (R-13-13).** Kein Endpunkt führt `devmem` aus, schreibt in eine
Treiber-Attributdatei oder liest eine Protokolldatei. `status` ist eine reine
Weiterleitung — es formatiert nichts und rechnet nichts. Ableitungen (Fehlerrate in
Prozent, Roh-Bitfehlerrate, Soft-Betrag in dB) berechnet **der Daemon** und legt sie in die
Zustandsdatei; die Seite stellt sie dar.

Der Grund ist ein belegter V1-Zustand: `metrics.cgi` gewinnt Burst-Zahl, Fehlerrate beider
Decodierwege, mittlere Bit-Differenz, Spitzenwert und Soft-Betrag über sechs Regex-Ausdrücke
aus der Standardfehlerausgabe des Daemons und rechnet daraus eine Modulationsfehlerrate in
`awk` [CODE sw/web/cgi-bin/metrics.cgi:37-79] — damit ist das Protokollformat eine
Schnittstelle. `sessions.cgi` liest zusätzlich zwei Registerfenster unmittelbar über
`devmem` [CODE sw/web/cgi-bin/sessions.cgi:39-40 mit `0x43C00200` und `0x43C00230`], davon
eines — `0x43C00200` — seit dem Umbau vom 2026-05-20 nicht mehr existent
[CODE sw/tetra_hal.h:250-252]: an dieser Stelle stellt die Anzeige stumm Nullen dar.
`0x43C00230` ist dagegen weiterhin belegt (`REG_REPLY_USE_SW`,
[CODE sw/tetra_hal.h:272]) — der Registerzugriff aus der Oberfläche bleibt auch dort ein
Verstoß gegen R-13-13, nur eben mit einem echten Wert.

**Prüfung der Eingaben.** Der Endpunkt prüft jeden Wert gegen dieselbe erzeugte
Bereichstabelle, die der Daemon benutzt (R-13-12), und weist Abweichungen mit Schlüssel,
Wert und Bereich ab. Der Daemon prüft beim Laden **erneut** — er darf einer Datei nicht
vertrauen, nur weil sie über die Oberfläche kam.

**Keine Vorgabewerte in der Oberfläche (R-13-12).** Eingabefelder sind beim Laden leer und
werden aus `GET /cgi-bin/config` gefüllt. In V1 stehen die Vorgabewerte in den
`value`-Attributen der Seite [CODE sw/web/index.html:86, :101, :104, :110] **und** im
Anwendungsendpunkt **und** im Konfigurationsendpunkt **und** im Hauptprogramm **und** im
Hochlaufskript (§2.5).

### 3.10 Protokollierung und Diagnose

#### 3.10.1 Protokollierung

| Eigenschaft | Festlegung |
|---|---|
| Stufen | `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE`; Vorgabe `INFO` |
| Kategorien | Bitmaske: `HAL`, `PHY`, `MAC`, `LLC`, `MLE`, `MM`, `CMCE`, `SDS`, `VOICE`, `CFG`, `SCHED` |
| Erzeugen | Ereignissatz mit fester Größe (32 Byte): Zeitstempel `(mn, fn, tn)` **aus dem TDMA-Zeitstempel, unverändert 0-basiert** (RTL-Zählweise, `07 §3.1.2`/`§3.4`) — am Erzeugungsort wird nicht gerechnet; dazu monotone Millisekunde, Stufe, Kategorie, 16-bit-Ereigniskennung, vier `uint32`-Argumente. **Keine** Zeichenkettenformatierung am Erzeugungsort (R-13-03) |
| Formatieren | Ausschließlich in T-CTL beim Entleeren: die Ereigniskennung wählt eine Formatzeichenkette aus einer erzeugten Tabelle. **Hier** geschieht die Umrechnung in die ETSI-1-Zählung der Protokollzeile (`MN = mn+1`, `FN = fn+1`, `TS = tn+1`), ausschließlich über `tetra_ts_map` — die Protokolldatei zeigt `TS1…TS4`, `FN1…FN18`, `MN1…MN60` |
| Ausgabe | Eine Datei mit Größenobergrenze (Vorgabe 4 MiB) und zwei Generationen; Ort ist Konfiguration, Vorgabe Speicher-Dateisystem |
| Drosselung | Je Ereigniskennung höchstens ein Eintrag je 1000 ms; unterdrückte Wiederholungen werden gezählt und beim nächsten Eintrag mitgeschrieben |
| Verlust | Ring voll → Satz verwerfen, `log_drop_cnt` +1 |

Drosselung und Obergrenze sind nicht Kosmetik: V1 schreibt je acht Sprachbursts eine
Zusammenfassung und je 64 Bursts drei weitere Zeilen, davon eine mit zwanzig
Positions-Zählern und eine mit sechzehn Behälter-Summen
[CODE sw/tetra_voice_pipe.c:233-298] — ohne Obergrenze, ohne Rotation, in eine Datei im
Speicher-Dateisystem [CODE board_autostart/tetra_autostart.sh:232]. Bei drei Sprechern
(≈ 51 Bursts/s) sind das rund 1 kB/s ≈ 86 MB je Tag [ANNAHME: aus Protokollkadenz und
Zeilenlänge gerechnet].

#### 3.10.2 Zähler (R-13-24, verbindlich und vollständig)

**Slot-Strang T-RX**

| Zähler | Bedeutung / Sollwert |
|---|---|
| `rx_iter_cnt`, `rx_iter_max_us`, `rx_iter_avg_us` | Iterationen und deren Dauer. `max` ist die Kenngröße von R-13-04 |
| `rx_deadline_miss_cnt` | Iterationen über 4 ms. **Soll 0** |
| `ulmb_pull_cnt`, `ulmb_multi_cnt` | geholte Bursts; davon solche, bei denen `STATUS[1]` einen zweiten Eintrag anzeigte |
| `ul_ts_mismatch_cnt` | Zeitstempel-Selbstprüfung (`08 §3.7` Regel 3). **Soll 0** |
| `ul_seq_gap_cnt` | Lücken in `W0.seq_num` — Verluste im PL, die die Software sonst nicht sieht |
| `ulmb_resv_nonzero_cnt` | reserviertes Bit eines Kopfworts der UL-Burst-Mailbox (`W0[30:23]`, `W1[31:28]`, `W2[31:24]`, `07 §3.4`) beim Lesen von 0 verschieden. Der Burst wird **trotzdem** verarbeitet — der Zähler ist der Nachweisteil (b) von `18` R-18-02, kein Filter. **Soll 0**; ≠ 0 heißt, das PL belegt ein Bit, das die Software nicht kennt |
| `ul_burst_type_unsupported_cnt` | Bursts mit `W0.burst_type` = `10₂`/`11₂` (reserviert, `07 §3.4`): definiert verworfen statt fehlgedeutet (Verzweigung §3.2, gefordert von `18` R-18-07/R-18-03). **Soll 0** in Stufe 1 |
| `dl_push_cnt`, `dl_push_defer_cnt`, `dl_push_drop_cnt` | Pushes; davon auf die nächste Iteration verschoben, weil die Warteschlange voll war; und solche, die nach `DL_PUSH_MAX_DEFER` Iterationen verworfen wurden (§3.11). **Soll 0** |
| `cc_attempt[6]`, `cc_crc_fail[6]`, `cc_erasure[6]`, `cc_metric_min[6]` | je logischem Kanal, aus `tetra_cc_stats_t` (`05 §2.4`) |
| `rx_schf_attempt_cnt`, `rx_schf_skipped_cnt` | Normal-Uplink-Bursts mit bzw. ohne SCH/F-Decodierung (Zustandsverzweigung §3.2). Die Summe muss `ulmb_pull_cnt` der Normal-Bursts ergeben |
| `voice_fetch_cnt`, `voice_bfi_cnt`, `voice_soft_mag_avg`, `voice_no_call_cnt`, `voice_mb_torn_cnt` | Sprachkette im Dauerbetrieb, Definitionen in `12 §3.10` |
| `voice_fec_diff_sum`, `voice_fec_diff_max` | Sprachkette, **nur bei gesetztem `DIAG_FEC_DIFF`** befüllt — `12 §3.4.5` stellt den XOR-Vergleich empfangen ↔ neucodiert ausdrücklich hinter einen Schalter und nicht in den Dauerbetrieb. Ist der Schalter aus, stehen beide Zähler auf 0 und die Zustandsdatei markiert das Feld als nicht erhoben |
| `ul_ring_drop_cnt` | Empfangsring voll — T-CTL hängt |

**Protokoll-Strang T-CTL**

| Zähler | Bedeutung |
|---|---|
| `ctl_iter_max_us` | längste Iteration; zeigt Dateisystem-Ausreißer |
| `reass_*` | Fragment-Zusammensetzung (`06 §3.11`) — abschließende Liste in der eigenen Tabelle unten, weil dieser Abschnitt der einzige normative Ort dieser Zähler ist |
| `llc_ack_tx_cnt`, `llc_ns_mismatch_cnt`, `llc_fcs_fail_cnt` | Basic Link (`09`) |
| `mm_attach_ok_cnt`, `mm_issi_reject`, `mm_issi_autoenroll`, `mm_gssi_reject`, `mm_gssi_autoenroll` | Mobilitätsverwaltung (`09 §3.6`) |
| `call_setup_cnt`, `call_reject_no_slot_cnt`, `call_watchdog_cnt`, `call_quiet_cnt[0..3]` | Rufsteuerung (`10`); Index von `call_quiet_cnt` = `tn` (RTL, 0-basiert) = `TS`(ETSI) − 1, in der Zustandsdatei nach ETSI umgesetzt (§3.10.3) |
| `sds_rx_cnt`, `sds_relay_cnt`, `sds_drop_no_dest_cnt`, `sds_frag_rx_cnt` | Kurznachrichten (`11`) |
| `dl_emit_cnt`, `dl_ring_full_cnt`, `dl_frag_chain_cnt` | Sendeweg |
| `cfg_generation`, `cfg_reload_cnt`, `cfg_parse_err_cnt` | Konfiguration |
| `db_entry_cnt[2]`, `db_autoenroll_cnt`, `db_full_cnt`, `db_save_cnt`, `db_save_err_cnt`, `db_parse_err_cnt` | Teilnehmer-Datenbank; `db_full_cnt` = abgewiesene Einfügeversuche über Füllgrad 0,5 (§3.8) |
| `log_drop_cnt`, `log_bytes_written` | Protokollierung |

**Fragment-Zusammensetzung (T-CTL) — der einzige normative Ort dieser Zähler**

Die Zusammensetzung läuft vollständig in Software (`00 §3.3`), deshalb liegt die Definition
**hier** und nirgends sonst. `06 §3.13`, `08 §3.5`, `09 §3.8` und `11 §3.10` nennen nur
Namen und verweisen hierher (P2). Schreibweise durchgängig klein mit Präfix `reass_`;
Großschreibung ist im Satz Registern und Konfigurationsschlüsseln vorbehalten.

**Index:** `[2]`, Index 0 = **Kette A** (zwei Unterschlitze, `MAC-ACCESS` + `MAC-END-HU`:
Anmeldung und kurze Kurznachricht), Index 1 = **Kette B** (reservierte Vollschlitze, lange
Kurznachricht) — Kettenformen `06 §3.11`, `11 §3.7.1`. Wird ein Name in einem anderen
Kapitel **ohne** Index zitiert, ist die Summe über beide Ketten gemeint. Die
Kettenauflösung ist Pflicht, weil ein Abbruch in Kette A eine gescheiterte **Anmeldung**
ist und einer in Kette B eine verlorene **Kurznachricht** — zwei verschiedene Befunde.

| Zähler | Erhöht bei | Sollwert / Auswertung |
|---|---|---|
| `reass_open_cnt[2]` | Startfragment mit Fragmentflag = 1 angenommen, Kontext eröffnet | Bezugsgröße der übrigen Zeilen |
| `reass_ok_cnt[2]` | Kette vollständig, Füllbits entfernt, TM-SDU an die Sicherungsschicht übergeben (`11 §3.7.5`) | Bezugsgröße |
| `reass_t0_cnt[2]` | Kette verworfen, weil seit dem letzten angenommenen Fragment mehr als `T0` Frames vergingen (Wert normativ `08 §3.5.2`) | klein gegen `reass_ok_cnt`; anhaltender Zuwachs auf Kette B = Zusage zu knapp (`11` O-11-2) |
| `reass_gap_cnt[2]` | Kette verworfen, weil ein zugesagter Slot keinen Block mit gültigem Prüffeld lieferte (`11 §3.7.4`) | wie oben; trennt „Zusage zu kurz" von „Empfang zu schlecht" |
| `reass_restart_cnt[2]` | offene Kette durch ein neues Startfragment **derselben** Adresse ersetzt — legitimer Wiederholversuch, **kein** Verwurf (`08 §3.5.3`) | — |
| `reass_orphan_cnt[2]` | Fortsetzungsfragment ohne offene Kette dieser Adresse, verworfen (`11 §3.7.4`) | **Soll 0** im ungestörten Betrieb; > 0 heißt Fenster zu kurz oder Zusage verloren |
| `reass_overlen_cnt[2]` | akkumulierte Bits > `N.202` = 2 632 (`11 §3.7.4`) | **Soll 0** |
| `reass_evict_cnt[2]` | ältester Kontext verdrängt, weil alle Plätze belegt waren (Ältesten-Regel `08 §3.5.3`) | **Soll 0**; > 0 → Zahl der Kontexte erhöhen, **nicht** das Fenster verkürzen (`11` O-11-3, `08` O-08-6) |
| `reass_incomplete_at_reply_cnt` | substanzielle Antwort gebaut, während die zugehörige Kette unvollständig war → Rückfall auf den Profil-Standardinhalt (`08 §3.5.2` Punkt 3). Ohne Kettenindex, weil nur Kette A im Antwortpfad liegt | **Soll 0** — ein von 0 verschiedener Wert ist ein Befund, keine Toleranz (`04` R-04-21) |
| `reass_bogus_cnt` | Burst an die Zusammensetzung übergeben, dessen PDU-Typ/Fragmentflag nicht zu einem Fragment passt — Fehlstand von `resv_active[tn]` (§3.2) | **Soll 0**; Zuwachs → Rückfall auf den unbedingten SCH/F-Versuch (§6 O-13-4) |

Die Bilanz `Σ reass_open_cnt = Σ (reass_ok_cnt + reass_t0_cnt + reass_gap_cnt +
reass_restart_cnt + reass_overlen_cnt + reass_evict_cnt) + offene Kontexte` muss zu jedem
Zeitpunkt aufgehen; sie ist als Abnahmekriterium in `11 §5.4` Punkt 6 geführt.

**Aus dem PL gespiegelt** (1-s-Kadenz, Namen und Semantik in `07`):
`REG_MB_UL_PUSH_CNT`, `REG_MB_UL_DROP_CNT`, `REG_MB_DL_DROP_CNT`,
`REG_MB_DL_STALL_CNT`, `REG_DLQ_POP_CNT`, `REG_DLQ_DROP_*`,
`REG_DLQ_ROUTE_ERR_CNT`, `REG_DLQ_LEN_MISMATCH_CNT`, `REG_ACCESS_ERR_CNT`,
`REG_TX_FIFO_UNF_CNT`, `REG_TX_FIFO_OVF_CNT`, `REG_RX_SYNC_DROP_CNT`,
`REG_RX_IQ_SAT_CNT`, die Zuweisungs-Zähler `REG_GRANT_*_CNT`/`REG_RESV_SLOT_CNT`/`REG_MCCH_SLOT_CNT` (`07 §3.1.8`), `REG_TDMA_LOAD_REJ_CNT`,
`REG_AIRLOCK_EVT_CNT`, `REG_AIRLOCK_DELTA_CYC`. Dazu, mit Name und Semantik in
`12 §3.10` statt in `07` (dort nur das Zählerformat): `voice_dl_emit_cnt[0..3]`,
Index = `tn` (RTL, 0-basiert) = `TS`(ETSI) − 1.

Alle Zähler sind sättigend und werden **nicht** durch Lesen zurückgesetzt. Die
Zustandsdatei enthält Absolutwert **und** Differenz zum vorigen Abtastzeitpunkt, damit eine
Rate ohne zwei Abrufe ablesbar ist.

#### 3.10.3 Zustandsdatei (R-13-25)

`/run/tetra/status.json`, alle 1000 ms vollständig neu geschrieben (Zwischendatei im selben
Verzeichnis, dann `rename`). Schema versioniert. Gliederung:

| Abschnitt | Inhalt |
|---|---|
| `meta` | `schema`, `version` des Programms, `pl_id`, `pl_version`, `uptime_s`, `cfg_generation`, `rt_degraded` |
| `time` | `ts`, `fn`, `mn`, `hn` in **ETSI-1-Zählung** (`TS = tn+1`, `FN = fn+1`, `MN = mn+1`, `HN = hn+1`); Quelle ist `REG_TDMA_STATE`, das 0-basiert liest (`07 §3.1.2`), die Umrechnung geschieht ausschließlich in `tetra_ts_map`. Dazu `sym_tick_rate`; `airlock_delta_cyc` und daraus abgeleitet der zugeordnete Uplink-Zeitschlitz (ebenfalls ETSI-1). Felder mit Zeitschlitz-Index (`call_quiet_cnt`, `voice_dl_emit_cnt`) erscheinen in der Datei als Objekt mit den Schlüsseln `TS1`…`TS4`, nicht als 0-basiertes Feld |
| `rf` | Sende- und Empfangsfrequenz, Duplex-Kennung und wirksamer Versatz, Dämpfung, Empfangspegel, Sättigungszähler |
| `health` | `SYNC_LOCKED`, `LVDS_ALIVE`, `TX_GATE_OPEN`, `rx_iter_max_us`, `rx_deadline_miss_cnt`, `ctl_iter_max_us`, `ul_ring_drop_cnt`, `dl_ring_full_cnt`, `log_drop_cnt` |
| `counters` | die vollständige Liste aus §3.10.2, je Eintrag Absolutwert und Differenz |
| `calls` | Rufplatztabelle: Zustand, Zeitschlitz, Gruppen-/Teilnehmeradresse, Nutzungsmarkierung, Ruf-Kennung, Alter, Fehlerrate der Sprachrahmen dieses Zeitschlitzes |
| `links` | Basic-Link-Zustand je Teilnehmer: `V(S)`, `V(R)`, ausstehende Quittung, letzter Slotindex |
| `db` | Anzahl Teilnehmer- und Gruppeneinträge, Selbsteintragungen, Zeitpunkt des letzten Sicherns |
| `derived` | vom Daemon berechnete Größen: Rahmenfehlerrate in Prozent (`voice_bfi_cnt / voice_fetch_cnt`, immer vorhanden), Soft-Betrag und daraus abgeleitete Güte; `raw_ber` aus `voice_fec_diff_sum / (432 · voice_fetch_cnt)` **nur bei gesetztem `DIAG_FEC_DIFF`**, sonst `null` (§3.10.2, `12 §3.4.5`) |

**Was die Anzeige mindestens braucht**, damit ohne zusätzliche Messtechnik diagnostiziert
werden kann (P6): der Zustand der Zeitbasis und der Synchronisation (läuft die Zelle
überhaupt?), die Empfangspegel und der Sättigungszähler (steht der Arbeitspunkt der
Empfangskette?), die **Rahmenfehlerrate** der Sprachrahmen und der mittlere Soft-Betrag
(ist die Uplink-Qualität die Ursache? — `08 §3.8.3` weist die Uplink-Qualität als Erklärung
der Latenzstreuung nach; die feinere Roh-Bitfehlerrate ist die **zuschaltbare** Vertiefung
dazu, `DIAG_FEC_DIFF`, und darf nicht zur Mindestdiagnose gehören, weil `12 §3.4.5` sie
nicht im Dauerbetrieb führt), die Verwurfszähler aller Mailboxen und Ringe (verliert jemand
Daten?), die Fristzähler beider Stränge (hält die Software ihre Frist?), und die
Rufplatztabelle (was glaubt die Basisstation gerade zu tun?).

### 3.11 Fehler- und Neustartverhalten

| Fall | Verhalten |
|---|---|
| Kennung oder Hauptversion des PL passt nicht | Abbruch bei S2, **kein** Schreibzugriff. Grund: ein unbekannter Bitstrom hat eine unbekannte Registerkarte |
| Pflichtschlüssel fehlt | Abbruch bei S1 mit Nennung des Schlüssels (V1-Muster übernommen: [CODE board_autostart/tetra_autostart.sh:36-44]) |
| Konfigurationsdatei zur Laufzeit ungültig | Alter Zustand bleibt, `cfg_parse_err_cnt` +1. Eine laufende Zelle wird nicht abgeschaltet |
| `ul_ring` voll | Neuen Satz verwerfen, zählen. T-RX arbeitet weiter — die Frist der Empfangskette bleibt gehalten |
| `dl_ring` voll | `tetra_dl_emit` liefert < 0, zählen. Der Aufrufer entscheidet: Signalisierung verwerfen (das Endgerät wiederholt), Fragmentkette **gar nicht** beginnen |
| Push wird abgewiesen (Warteschlange voll) | Auf die nächste Iteration verschieben, `dl_push_defer_cnt` +1. Höchstens `DL_PUSH_MAX_DEFER = 8` Iterationen (16 ms), danach verwerfen und `dl_push_drop_cnt` +1. **Keine** Wartespirale (V1: bis 50 ms, [CODE sw/tetra_tx_transport.c:52-64]) |
| Prüffeld eines Uplink-Bursts verletzt | Kein Ringeintrag, `cc_crc_fail[ch]` +1. Liegt der Burst in einem reservierten Zeitschlitz mit laufender Fragmentkette, verwirft T-CTL die Kette [ETSI §23.4.3.1.2] |
| Sicherung der Teilnehmerdatei schlägt fehl | Speicherzustand bleibt gültig, `db_save_err_cnt` +1, erneuter Versuch im nächsten 1-s-Haushalt. Der Betrieb hängt **nicht** von einem gelungenen Schreibvorgang ab |
| T-RX bleibt aus (Absturz eines Strangs) | T-CTL erkennt einen stehenden `rx_iter_cnt` (> 100 ms unverändert), stellt ruhig und beendet den Prozess mit Fehlerkennung → die Diensteinheit startet neu |
| Absturz des Prozesses | Diensteinheit mit Wiederanlauf nach 1 s. Die Ruhigstellung bei S4 räumt auf, was der Absturz stehen ließ (R-13-19) |
| Neustart im Betrieb | **Auf der Luft nicht beobachtbar** (R-13-17): die Zeitbasis läuft im PL weiter, die Software schreibt sie nie (R-13-18), Broadcast-Bänke behalten ihren Inhalt bis S5 sie identisch neu schreibt, Sprach-Halteplätze werden geleert. Angemeldete Endgeräte bleiben angemeldet, weil der Anmeldezustand aus der Teilnehmerdatei wiederkommt |
| Was ein Neustart **verliert** | Basic-Link-Zählstände `V(S)`/`V(R)`, Rufplätze, laufende Fragmentketten. Folge: laufende Rufe brechen ab, das nächste Endgerät-Frame erzeugt eine Quittung mit falschem `N(R)` und wird wiederholt. Das ist hinnehmbar und wird **nicht** durch Persistieren von Verbindungszustand behoben — persistierter Protokollzustand, der nicht zum Gegenüber passt, ist schlimmer als kein Zustand |
| Beendigungsfrist überschritten | Prozess endet trotzdem; die Ruhigstellung ist der erste Schritt (§3.1) |

### 3.12 Rechenlast-Bilanz des Gesamtsystems

#### 3.12.1 Kosten je Vorgang

**Rechenzeit, Host-Messung** (x86-64, 3,7 GHz, gcc `-O2`, 20 000 bis 200 000
Wiederholungen je Fall, Quellen aus `sw/tetra_channel_codec.c`, `sw/tetra_bs_tch_s.c`,
`sw/tetra_mm_demand_parser.c`, `sw/tetra_cmce_parser.c`, `sw/tetra_cmce_body.c`,
`sw/tetra_grpack_body.c`) [SIM 2026-07-25]:

| Vorgang | µs / Aufruf (Host) |
|---|---:|
| SCH/F codieren (268 → 432) | 3,45 |
| SCH/F soft decodieren | 53,8 |
| SCH/HU soft decodieren | 22,4 |
| TCH/S soft decodieren | 7,25 |
| TCH/S codieren | 2,50 |
| **Mobilitäts-Wanderer, Anmeldung** | **0,035** |
| **Mobilitäts-Wanderer, Gruppen** | **0,004** |
| **Rufsteuerungs-PDU auswerten** | **0,022** |
| **Rufsteuerungs-PDU bauen** | **0,036** |
| **Gruppenquittung bauen** | **0,082** |

Die vier Codierwerte reproduzieren `05 §3.10` innerhalb von 9 % (dort 3,4 / 59,0 / 22,4 /
6,94 / 2,38 µs) — dieselben Quellen, derselbe Host, unabhängig gemessen.

> **Das wichtigste Ergebnis dieser Tabelle ist der Größenabstand.** Die **gesamte**
> Protokollverarbeitung — Wandern der Uplink-PDU, Auswerten, Antwort bauen — kostet
> zusammen **unter 0,2 µs**; die Kanalcodierung eines einzigen Bursts das 100- bis
> 250-fache. Die Lastbilanz ist damit **ausschließlich** eine Kanalcodierungs-Bilanz; MAC,
> LLC, MLE, MM, CMCE und SDS erscheinen darin nicht. Das rechtfertigt die ganze
> Protokolllogik in **einem** Strang mit 10-ms-Kadenz (§3.3) und begründet, warum die
> Trennlinie zwischen den Strängen genau an der Kanalcodierung liegt (§2.2).

**Umrechnung auf den Zielprozessor.** Cortex-A9 bei 667 MHz (Datenblattgrenze
XC7Z020-1): Taktfaktor 5,5, zuzüglich eines IPC-Faktors von etwa 2 für skalaren
Integer-Code mit Tabellenzugriffen. **Angenommener Gesamtfaktor 11** [ANNAHME — identisch
zu `05 §3.10` und `12 §3.9`, damit alle drei Kapitel dieselbe Skala benutzen; **nicht** auf
dem Board gemessen, siehe R-13-27].

**Buszeit.** AXI-Zugriffe sind Wandzeit auf dem Ziel und werden **nicht** mit dem
Prozessorfaktor skaliert — eine Unterscheidung, die in einer gemeinsamen Bilanz sonst
still verloren geht:

| Transfer | Zugriffe | µs bei 100 ns |
|---|---:|---:|
| Uplink holen, Control-Burst (45 Wörter) | 2 + 90 = 92 | 9,2 |
| Uplink holen, Normal-Burst (111 Wörter) | 2 + 222 = 224 | 22,4 |
| Downlink schieben (16 Wörter) | 32 + 2 = 34 | 3,4 |
| TX-Payload-Bank übernehmen (7 Wörter) | 14 + 2 = 16 | 1,6 |
| Abfrage-Iteration T-RX (zwei Statuswörter) | 2 | 0,2 |

[ANNAHME: 100 ns je ungepuffertem 32-bit-Zugriff über den Universalport — dieselbe Annahme
wie `07 §3.2` und `12 §3.9`; von `07 §3.2` ausdrücklich zur Prüfung in diesem Kapitel
gestellt, siehe R-13-27.] Die Wortzahlen sind `07 §3.3`/`§3.4` entnommen; der Faktor 2 je
Wort folgt aus dem fehlenden automatischen Indexvorschub (`07 §3.2`).

#### 3.12.2 Bilanz je TDMA-Frame in koexistierenden Szenarien

Ein TDMA-Frame hat vier Zeitschlitze und dauert 170/3 ms [ETSI §9.3.4]. Je Frame kann jeder
Zeitschlitz **entweder** Steuerverkehr (bis zwei Unterschlitze [ETSI §9.3.6]) **oder**
Sprache **oder** einen Fortsetzungsburst einer langen Nachricht tragen. Die Szenarien sind
deshalb **nicht** additiv — das ist der Unterschied zur Einhüllenden-Summe in `05 §3.10`,
die 141 Steuer-Unterschlitze/s **und** drei Sprachkanäle gleichzeitig ansetzt und damit
einen Zustand summiert, den es nicht gibt — `05 §3.10` weist die Zeilen deshalb ausdrücklich
als nicht-additive Einhüllende aus und verweist für die szenarienweise Bilanz hierher.

| Szenario | Belegung der vier Uplink-Slots | Rechenzeit Host µs/Frame | A9 (× 11) µs | Buszeit µs | Summe µs/Frame | Anteil |
|---|---|---:|---:|---:|---:|---:|
| **S1** Leerlauf | — | ≈ 0 | ≈ 0 | 5,6 | **6** | **0,01 %** |
| **S2** eine Anmeldung | TS1: 2 Steuer-Unterschlitze; 2 Antwort-PDUs | 51,7 | 569 | 30,8 | **600** | **1,1 %** |
| **S3** drei Gruppenrufe | TS1: 2 Steuer-Unterschlitze; TS2–TS4: Sprache; 1 Signalisierungs-PDU | 77,5 | 853 | 104,8 | **958** | **1,7 %** |
| **S4** zwei Rufe + lange Nachricht | TS1: 2 Steuer-Unterschlitze; TS2/TS3: Sprache; TS4: SCH/F-Fortsetzung | 121,6 | 1337 | 101,4 | **1438** | **2,5 %** |
| **S5** Zugriffsspitze | alle vier Slots mit je 2 Steuer-Unterschlitzen; 4 Signalisierungs-PDUs | 193,0 | 2123 | 92,8 | **2216** | **3,9 %** |

Der Anteil bezieht sich auf **einen** Kern und ein Frame von 56 667 µs. Auf dem
Zweikern-Prozessor liegt die Bilanz von T-CTL (Protokoll, Dateien, Zustandsdatei) auf dem
zweiten Kern; T-RX trägt in S5 rund 3,7 der 3,9 Prozentpunkte.

Die Zahlen setzen die Zustandsverzweigung aus §3.2 voraus. Mit dem unbedingten
SCH/F-Versuch je Sprachburst stiege S3 auf **2733 µs = 4,8 %** und wäre damit der
schlechteste Fall der Tabelle — die Verzweigung senkt den Spitzenwert um Faktor 2,9.

#### 3.12.3 Deadline-Prüfung je Zeitschlitz (R-13-04)

Die Frist ist nicht der Frame, sondern der **Zeitschlitz**: 14 167 µs (`07 §3.8`).
Ungünstigster einzelner Zeitschlitz:

| Fall | Rechenzeit A9 | Buszeit | Summe | Anteil eines Zeitschlitzes |
|---|---:|---:|---:|---:|
| Slot mit SCH/F-Fortsetzungsburst + 1 Push | 592 µs | 25,8 µs | **618 µs** | **4,4 %** |
| Steuerslot, zwei Unterschlitze belegt + 1 Push | 531 µs | 21,8 µs | **553 µs** | **3,9 %** |
| Sprachslot, ein Burst (TCH/S decodieren + neu codieren) + 1 Push | 107 µs | 25,8 µs | **133 µs** | **0,9 %** |

Der Fortsetzungsslot ist der teuerste: eine SCH/F-Soft-Decodierung ist die längste
unteilbare Arbeitseinheit der Software. Mit der Abfrageverzögerung von höchstens 2 ms
(§3.5) bleibt der ungünstigste Fall bei **2,62 ms von 14,167 ms**; die Reserve gegen die
Frist ist **Faktor 5**, gegen die Frist der Doppelpufferung (28 ms) **Faktor 10**.

**Die Aussage in einem Satz:** Das Nebenläufigkeitsmodell trägt die Last mit Faktor 5
Reserve auf der engsten Frist und rund 4 % eines Kerns im Dauerbetrieb — **unter der
Bedingung**, dass keine der fünf V1-Blockaden aus §2.1 in T-RX liegt. Die Reserve ist eine
Reserve gegen Blockaden, nicht gegen Rechenzeit.

#### 3.12.4 Was gerechnet und was gemessen ist

| Größe | Herkunft |
|---|---|
| Kosten je Vorgang, Rechenzeit | **gemessen**, auf dem Host [SIM 2026-07-25] |
| Faktor 11 Host → Cortex-A9 | **[ANNAHME]** aus Taktverhältnis und Pipeline-Unterschied |
| 100 ns je AXI-Zugriff | **[ANNAHME]**, von `07 §3.2` zur Prüfung hierher gestellt |
| Wortzahlen der Transfers | **festgelegt** in `07 §3.3`/`§3.4` |
| Slot- und Frame-Dauern, Unterschlitz-Teilung | **normativ** [ETSI §9.3.3, §9.3.4, §9.3.6] |
| Alle Werte in §3.12.2 und §3.12.3 | **gerechnet** aus den fünf Zeilen darüber — **keine** Messung auf dem Ziel |
| V1-Ruhelast 8,3 % eines Kerns | **gemessen**, aber **ohne** dokumentierten Sprachruf und mit drei Prozessen (zwei zu 10 ms, einer zu 2 s Kadenz, §2.1) [MESS 2026-05-20] — kein Vergleichswert |

**R-13-27 ist die einzige offene Größe dieses Abschnitts.** `08 §3.8.3` stellt fest, dass
eine V1-Messung unter Ruflast nicht existiert und die Folgerung „nicht rechenzeitkritisch"
bis dahin eine Annahme bleibt. Verfahren in §5.3; das Ergebnis ersetzt die Spalte
„A9 (× 11)".

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Abfragekadenz T-RX | **2 ms** | [ANNAHME] aus der 14-ms-Frist (`07 §3.8`) mit Faktor 7 Reserve | Größer: die Verzögerung frisst die Frist; ab 14 ms gehen Uplink-Bursts verloren (`REG_MB_UL_DROP_CNT`). Kleiner: nur Buslast, 0,1 ms/s je 2-ms-Schritt |
| Abfragekadenz T-CTL | **10 ms** | V1-Wert, air-verifiziert [CODE sw/tetra_attach_daemon.c:86] | Größer als 56 ms verletzt die Frist der substanziellen Antwort (`08 §2.3`) |
| Iterationsobergrenze T-RX | **4 ms** (Zählschwelle) | [ANNAHME] = 2 × Kadenz | Zu klein: Fehlalarme; zu groß: eine echte Fristverletzung bleibt unentdeckt |
| Tiefe `ul_ring` | **64** | [ANNAHME] = 16 Frames Rückstau | Kleiner: `ul_ring_drop_cnt` bei Ausreißern in T-CTL |
| Tiefe `dl_ring` | **16** | [ANNAHME] = 4 Frames Vorlauf | Größer: veraltete Aussendungen — das Muster der Zuweisungs-Spirale [MESS 2026-07-11] |
| `DL_PUSH_MAX_DEFER` | **8 Iterationen** = 16 ms | [ANNAHME] ≈ 1 Zeitschlitz Nachlauf | Größer: eine PDU verpasst ihr Antwortfenster und wird trotzdem gesendet |
| Kadenz Änderungszeit-Prüfung Konfiguration | **1 s** | V1: 5 s [CODE sw/tetra_attach_daemon.c:87] — verkürzt, weil ein `stat` je Sekunde kostenlos ist und die Bedienerrückmeldung dadurch spürbar schneller wird | Größer: „Apply hat nicht gewirkt"-Eindruck an der Oberfläche |
| Kadenz Zustandsdatei | **1 s** | [ANNAHME] aus der Auffrischrate der Anzeige | Kleiner: unnötige Schreibvorgänge im Speicher-Dateisystem |
| Obergrenze Protokolldatei | **4 MiB**, 2 Generationen | [ANNAHME] gegen die gerechneten ≈ 1 kB/s aus §3.10.1 | Ohne Obergrenze: rund 86 MB/Tag im Speicher-Dateisystem |
| Drosselung je Ereigniskennung | **1 / 1000 ms** | [ANNAHME] | Ohne Drosselung dominiert die Sprachdiagnose das Protokoll |
| Plätze Teilnehmer-Datenbank | **1024 Plätze je Typ**, Füllgrad ≤ 0,5 → **Kapazität 512 Einträge je Typ** | [ANNAHME]; V1: 256 Plätze, Erbe der entfallenen PL-Tabelle [CODE sw/tetra_db.h:29] | 256 ist für eine Zelle mit Selbsteintragung knapp; über Füllgrad 0,5 hinaus steigt die Sondierungslänge der offenen Adressierung überproportional |
| Beendigungsfrist | **200 ms** | [ANNAHME] | Größer: die Diensteinheit greift zum harten Beenden, bevor die Ruhigstellung fertig ist — deshalb ist sie Schritt 1 |
| Vorrang T-RX | `SCHED_FIFO` **20** | [ANNAHME] — über allem, was auf dem Board sonst läuft, unter den Kernel-Strängen | Ohne Echtzeit-Vorrang hängt die Frist an der Systemlast; V1s Ruhelast wurde erst nach Abschalten von Anzeige-, Druck- und Aktualisierungsdiensten von 69 % auf 8,3 % gebracht [MESS 2026-05-20] |
| Sprech-Ruhe-Schwelle | **300 ms** | gemessen, `12 §4` — hier nur als Zeitgeber in T-CTL geführt | 1000 ms war schlechter [MESS 2026-05-25] |

---

## 5. Verifikation

### 5.1 Statische Prüfungen (Teil der Übersetzung, brechen den Bau)

| Prüfung | Kriterium | Deckt ab |
|---|---|---|
| V-13-1 | `grep -nE 'hal->regs\|tetra_reg_(read\|write)\|devmem'` über alle `.c`/`.h` außer `tetra_hal.c`, `tetra_hal_internal.h` und `tetra_bringup.c` → 0 Treffer. Die Ausnahmeliste ist abschließend und steht **nur** hier und in R-13-08/§3.6 | R-13-08 |
| V-13-2 | `nm` über `libtetrahal.a` → kein `main` | R-13-07 |
| V-13-3 | Mengenvergleich `ls **/*.c` gegen die Quellenlisten aller Ziele → leere Differenz | R-13-10 |
| V-13-4 | Aufrufgraph aus den Objektdateien gegen die modul-granulare Erlaubnisliste aus §2.4 → keine aufwärts gerichtete Kante; keine Kante nach L1…L4, die mehr als eine Schicht überspringt; kein Aufruf von `tetra_hal` aus L1…L4 (Kanten nach L0 sind aus jeder Schicht erlaubt) | R-13-09 |
| V-13-5 | Verbotsliste über die Übersetzungseinheiten von T-RX (`open`, `fopen`, `read`, `write`, `stat`, `rename`, `fsync`, `malloc`, `calloc`, `free`, `printf`, `snprintf`, `syslog`) → 0 Treffer | R-13-03 |
| V-13-6 | genau ein Verzeichnis für die Bedienoberfläche; Verbotsliste über alle CGI (`devmem`, `/sys/bus/iio`, `grep .*\.log`) → 0 Treffer | R-13-11, R-13-13 |
| V-13-7 | für jeden Konfigurationsschlüssel genau ein Literal-Vorkommen außerhalb von Testdaten | R-13-12 |
| V-13-8 | Aufrufzeilen-Parser kennt nur `--config`, `--foreground`, `--log-level`, `--log-category` | R-13-14 |
| V-13-9 | `grep -n 'REG_TDMA_LOAD'` in `tetra_bsd`-Quellen → 0 Treffer | R-13-18 |
| V-13-9a | Betriebsprüfung auf dem Board: `fuser /dev/mem` nennt genau eine PID; kein ausgeliefertes CGI und kein Hilfswerkzeug bildet die Apertur ab | R-13-01 |

### 5.2 Einheiten- und Nebenläufigkeitstests (Host, ohne Hardware)

| Test | Verfahren | Kriterium |
|---|---|---|
| V-13-10 | Ringe gegen einen Modellprüfer für Erzeuger/Verbraucher: 10⁷ Sätze, zufällige Verzögerungen | keine verlorene, keine doppelte, keine zerrissene Übergabe; Verwurf nur mit Zählerinkrement |
| V-13-11 | Streuwerttabelle (offene Adressierung, 1024 Plätze je Typ, R-13-21): 512 Einträge je Typ einfügen, darunter gezielt Adressen, die auf denselben Startplatz fallen, damit die Sondierungsfolge durchlaufen wird; anschließend jede Adresse nachschlagen und wieder löschen | Nachschlagezeit unabhängig von der Position; jede eingefügte Adresse wird gefunden, jede nicht eingefügte nicht; der 513. Eintrag (Füllgrad > 0,5) wird mit Fehler abgewiesen statt zu überschreiben; nach dem Löschen bleibt die Sondierungsfolge intakt (kein durch eine Lücke unerreichbarer Eintrag) |
| V-13-12 | Konfigurationsparser gegen einen Satz aus 30 gültigen und 30 fehlerhaften Dateien | jeder Fehler nennt Zeile, Schlüssel und erwarteten Bereich; gültiger Vorzustand bleibt bei Fehler erhalten |
| V-13-13 | **Nebenläufiges Schreiben** (R-13-16): 200 Bedieneränderungen gegen 200 Selbsteintragungen auf derselben Datei, beide über die echten Sperrpfade | keine verlorene Änderung; die Datei ist nach jedem Schritt syntaktisch gültig; kein Zustand mit einer Zwischendatei außerhalb des Zielverzeichnisses |
| V-13-14 | HAL gegen ein Registermodell (Attrappe der Apertur): jede Mailbox-Folge aus `07 §3.2` | jede Bit-Abbildung gegen die Formeln aus `07 §3.3`/`§3.4`; Eigentümerprüfung löst bei Aufruf aus dem falschen Strang aus |
| V-13-15 | Zustandsdatei gegen das Schema, über 1000 Abtastungen mit zufälligen Zählerständen | schemagültig; jeder Zähler aus §3.10.2 vorhanden; Differenzfeld konsistent mit dem Absolutwert |

### 5.3 Messung auf dem Ziel (R-13-27 — der offene Punkt aus `08 §3.8.3`)

**Verfahren.** `tetra_bsd` erhält einen Messmodus, der je Bearbeitungsschritt in T-RX den
Zyklenzähler des Prozessors liest und ein Histogramm in die Zustandsdatei legt. Gemessen
wird über ≥ 10 min je Szenario:

| Lauf | Szenario | Zu erhebende Größen | Abnahmekriterium |
|---|---|---|---|
| M1 | S1 Leerlauf | `rx_iter_max_us`, Ruhelast des Systems | `rx_deadline_miss_cnt` = 0 |
| M2 | S2 Anmeldung, 5 Endgeräte in Folge | Zeit je SCH/HU-Decodierung, Zeit je Push | Zeit je SCH/HU-Decodierung ≤ 400 µs (= Faktor 18 gegen den Host; die Rechnung sagt 246 µs) |
| M3 | S3 drei Gruppenrufe | Zeit je Sprachburst gesamt, `voice_bfi_cnt`, `rx_iter_max_us` | `rx_iter_max_us` ≤ 4000 µs; `REG_MB_UL_DROP_CNT` = 0 |
| M4 | S4 zwei Rufe + lange Kurznachricht, beide Varianten aus §6 O-13-4 | Zeit je SCH/F-Decodierung, `reass_bogus_cnt`, `rx_schf_skipped_cnt` | ≤ 1000 µs; `reass_bogus_cnt` = 0 mit Verzweigung |
| M5 | Buszeit | 10⁶ Registerlesevorgänge in einer engen Schleife, Zeit je Zugriff | Wert ersetzt die 100-ns-Annahme in `07 §3.2`, `12 §3.9` und §3.12 |
| M6 | Blockade-Nachweis | während M3 eine Bedieneränderung, eine Selbsteintragung und ein Protokollwechsel auslösen | `rx_iter_max_us` steigt **nicht** — der Beweis, dass der Strangschnitt aus §2.2 wirkt |

M6 ist der eigentliche Abnahmetest dieses Kapitels: er prüft nicht die Rechenzeit, sondern
die Entkopplung, um derer willen der Schnitt gemacht wurde.

### 5.4 Luft-Abnahme

| Test | Verfahren | Kriterium |
|---|---|---|
| V-13-16 | Konfigurationsänderung (Zellidentität) über die Oberfläche, dann Aufzeichnung | `cfg_generation` erhöht; Broadcast trägt die neuen Werte innerhalb 3 s; **kein** Prozess-Neustart, **kein** Rücksprung der Hyperframe-Nummer (R-13-17) |
| V-13-17 | Änderung einer Zeile der Duplex-Tabelle | Empfangsfrequenz verschiebt sich um den neuen Versatz; das Broadcast-Feld bleibt unverändert (R-13-15) |
| V-13-18 | `SIGKILL` auf `tetra_bsd` während eines Gruppenrufs, Wiederanlauf durch die Diensteinheit | Aufzeichnung über den Neustart: Frame-, Multiframe- und Hyperframe-Folge lückenlos; kein Fremdmuster auf einem Sprachslot; angemeldete Endgeräte bleiben angemeldet (R-13-17, R-13-19) |
| V-13-19 | Hyperframe-Fortschreibung über 5 Wechsel | Abstand 61,2 s ± 100 ms (R-13-20); V1 zeigt an dieser Stelle 60 s [CODE sw/tetra_hal.c:1882, :1907-1910] |
| V-13-20 | Diagnose ohne Messtechnik: ein Prüfer mit ausschließlich der Zustandsdatei soll drei künstlich eingebrachte Störungen benennen (Empfangspegel zu niedrig, ein Sprachslot ohne Aussendung, Uplink-Bursts verloren) | alle drei aus §3.10.3 benennbar (P6) |
| V-13-21 | Dauerlauf 1 h mit drei Sprachkanälen bei `LOG_LEVEL = DEBUG` | Protokolldatei ≤ `LOG_MAX_BYTES`, höchstens 2 Generationen, `log_drop_cnt` und `log_bytes_written` lesbar (R-13-26) |

---

## 6. Offene Punkte

1. **O-13-1 — Zeit je Vorgang auf dem Zielprozessor (R-13-27).** Der Faktor 11 zwischen
   Host und Cortex-A9 ist eine Annahme; alle Zahlen in §3.12.2 und §3.12.3 hängen daran.
   Bei einem echten Faktor von 25 statt 11 stünde der teuerste Zeitschlitz bei 11 % statt
   5 %, bei 50 bei 22 % — immer noch tragbar, aber die Reserve gegen Blockaden schrumpft.
   **Empfehlung:** M1–M5 aus §5.3 vor der ersten Luft-Abnahme fahren und die Spalte
   „A9 (× 11)" durch Messwerte ersetzen. Bis dahin gilt R-13-04 als Wächter: der Zähler
   `rx_deadline_miss_cnt` misst das Ergebnis unabhängig von jeder Umrechnung.

2. **O-13-2 — Zwei Kerne, aber keine Bindung festgelegt.** Der Zynq-7020 hat zwei
   Cortex-A9. Der Entwurf setzt nur Vorrang, nicht Kernbindung. Eine Bindung von T-RX auf
   den zweiten Kern (weil Geräteunterbrechungen üblicherweise auf dem ersten landen) wäre
   naheliegend, ist aber ohne Messung geraten. **Empfehlung:** ohne Bindung starten, in M3
   und M6 mit und ohne Bindung messen, und die Bindung nur festschreiben, wenn
   `rx_iter_max_us` messbar sinkt.

3. **O-13-3 — Soft-Breite am Wortport (offener Punkt O-03-4 aus `03`).** Bei 8 bit sind je
   Sprachburst 224 statt 116 AXI-Zugriffe nötig, also 22,4 statt 11,6 µs Buszeit. S3 trägt
   drei Sprachbursts (TS2–TS4, §3.12.2), Mehrkosten je Burst 10,8 µs — in der
   Bilanz S3 sind das **32,4 µs von 958 µs** je Frame, also **3,4 %**. Nach dieser Rechnung ist 8 bit
   unkritisch. **Empfehlung:** 8 bit bleibt; nur neu bewerten, wenn M5 eine Zugriffszeit
   deutlich über 100 ns liefert.

4. **O-13-4 — Die Zustandsverzweigung statt der Selbstfilterung ist die riskanteste
   Einzelentscheidung dieses Kapitels.** §3.2 ersetzt V1s unbedingten SCH/F-Versuch je
   Normal-Uplink-Burst durch eine Verzweigung an `resv_active[tn]`. Der Gewinn ist groß und
   gerechnet (Spitzenlast S3 von 4,8 % auf 1,7 %, §3.12.2), das Risiko ist ein falsch
   gesetztes Bit, das einen Sprachrahmen kostet. Die Alternative — unbedingt beides
   versuchen — ist unempfindlich, aber verdreifacht die Last des Sprachbetriebs.
   **Empfehlung:** die Verzweigung bauen, `reass_bogus_cnt` und `rx_schf_skipped_cnt` in
   M3 und M4 mitmessen, und beide Varianten hinter **einem** Konfigurationsschalter
   (`DIAG_SCHF_UNCONDITIONAL`) halten, bis eine Luft-Messreihe die Verzweigung bestätigt.
   Ein Schalter, kein zweiter Pfad (P3): dieselbe Kette, ein Prädikat.

5. **O-13-5 — Verlust von Verbindungszustand über einen Neustart.** §3.11 entscheidet
   bewusst gegen das Persistieren von `V(S)`/`V(R)` und Rufplätzen; laufende Rufe brechen
   ab und das erste Endgerät-Frame danach wird wiederholt. Ob das auffällt, ist ungemessen.
   **Empfehlung:** V-13-18 zählt die Wiederholungen. Erst über einer Wiederholung je
   angemeldetem Endgerät über Wiederaufnahme nachdenken — und dann nur mit
   Gültigkeitsprüfung gegen das Gegenüber, nie blind.

6. **O-13-6 — Ort der persistenten Dateien.** §3.7 legt `/etc/tetra/` fest, V1 benutzt
   `/root/`. Ob das Wurzeldateisystem des Abbilds beschreibbar und dauerhaft ist, ist eine
   Eigenschaft des Abbilds. **Empfehlung:** in `15_BUILD_DEPLOY` genau ein Verzeichnis
   benennen, dessen Beschreibbarkeit im Hochlauf durch eine Schreibprobe geprüft wird
   (Abbruch mit klarer Meldung); der Pfad ist dann Konfiguration und keine über den Baum
   verteilte Konstante.

7. **O-13-7 — Die Broadcast-Parameter haben einen Verbraucher, aber keine normative
   Feldbelegung.** Die Gruppe „Broadcast-Parameter" (§3.7) geht in die von der Software
   erzeugte BNCH-Nutzlast (§3.3, `07 §3.5`) — dieser Weg ist festgelegt. **Nicht** festgelegt
   ist, welches Bit welcher PDU jeder einzelne Schlüssel speist: die Rundspruch-PDU mit den
   Zugriffs- und Pegelparametern hat in `06 §3.4` keinen Eintrag und in `09` keinen
   Abschnitt; `06 §3.4` führt MAC-RESOURCE, Null-PDU, MAC-FRAG und MAC-END. Solange das
   fehlt, ist die Wertebereichsprüfung dieser Schlüssel nicht spezifizierbar und der
   Fremdempfänger-Abnahmefall `14` L1 prüft nur, dass *irgendeine* gültige Systeminformation
   entsteht. **Empfehlung:** die Feldbelegung dort ergänzen, wo die PDU strukturell hingehört
   — als weiterer Unterabschnitt in `06 §3.4` mit ETSI-Belegstellen —, und die
   Schlüsselnamen dieses Kapitels anschließend eins-zu-eins auf diese Felder abbilden. Bis
   dahin gilt: die Schlüssel sind Durchleitwerte ohne Prüfung, und eine Falscheingabe ist nur
   an der Luft sichtbar.
