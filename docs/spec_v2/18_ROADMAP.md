# 18 — Spezifizierte, aber nicht in Stufe 1 gebaute Funktionen

**Scope:** Funktionen, die V2 in Stufe 1 nicht enthält, aber so weit festgelegt sind, dass
Stufe 1 sie nicht verbaut: fehlende Grundfunktionen des Standards, Verbesserungen der
Empfangsgüte, Erweiterungen des Sprachpfads, ein Arbeitsmittel zur Fehlersuche und die
Posten, die einen Plattformwechsel brauchen. Je Eintrag: Anforderung, Abhängigkeit zu
Stufe 1, Ressourcenbedarf, **und die Vorsorge, die Stufe 1 leisten muss**.

**Nicht hier:** Die Fachspezifikation der Stufe-1-Funktionen — die steht in `01`…`15`.
Keine Zeitpläne, keine Aufwandsschätzungen. Ressourcen-Budget und Gerätekapazität:
`01_PLATFORM §3.9` (einzige normative Quelle). Registeradressen und Mailbox-Formate:
`07_PS_PL_CONTRACT` (einzige normative Quelle). Ursachenanalysen von V1-Fehlern:
`17_LESSONS_LEARNED`.

**Ausdrücklich außerhalb des Scopes dieser Roadmap** (also nicht „später", sondern
„nicht"): TEDS-Kanäle mit π/8-D8PSK- oder QAM-Modulation. Sie sind eine eigene
Sende-/Empfangs-PHY, kein zusätzlicher Decodierpfad; die Zelle ist eine π/4-DQPSK-V+D-Zelle.

**Abhängigkeiten:** `00_OVERVIEW` (§3 Schnitt, §4 Prinzipien P1–P7, §5.2). Je Eintrag die
dort genannten Fachkapitel.

---

## 1. Anforderungen

Die Anforderungen dieses Kapitels richten sich **an Stufe 1**. Sie sind der eigentliche
Inhalt: nicht die Wunschliste, sondern die Vorsorge, die eine spätere Nachrüstung ohne
Umbau der Grundstruktur möglich hält.

| Nr. | Anforderung | Abnahme |
|---|---|---|
| **R-18-01** | Kein Eintrag dieses Kapitels darf zu seiner Umsetzung den Schnitt aus `00 §3` verändern. Jeder Eintrag in §3 benennt seine Vorsorge; keine davon verschiebt eine in `00 §3.2` aufgezählte Hardware-Funktion in die Software oder umgekehrt. | Review gegen die Liste `00 §3.2`; ein Eintrag, dessen Vorsorge eine Schnittverschiebung verlangt, ist zurückzuweisen oder `00` ist zu ändern — nicht stillschweigend beides. |
| **R-18-02** | Die in §2.3 aufgeführten reservierten Bitfelder bleiben in Stufe 1 unbenutzt und werden von der empfangenden Seite auf 0 geprüft. Eine Belegung mit anderer Bedeutung ist ein Spec-Verstoß. | Nach Richtung getrennt, weil das Datenfenster der UL-Burst-Mailbox nur lesbar ist (`REG_ULMB_DATA` RO, `07 §3.4`). **(a) PS→PL** (`W14[20:7]`, `W14[29]`, `W14[31:30]`, `W15` `pdu_class` `10₂`/`11₂`, `REG_UL_ASSIGN_CFG[31:21]`, Zeitplan-Eintrag `[1:0]`): in jedes reservierte Bit eine 1 schreiben; Rücklesewert 0 **oder** Eintrag verworfen mit zugehörigem Fehlerzähler. **(b) PL→PS** (`W0[30:23]`, `W1[31:28]`, `W2[31:24]`): Die Software ist nicht Erzeuger und kann dort nicht schreiben — Nachweis daher zweiteilig: Testbench zeigt, dass das PL diese Bits über alle Burst-Typen und Randfälle **konstant 0** treibt, und die Software prüft sie beim Lesen jedes Kopfworts auf 0 und zählt eine Abweichung (`ulmb_resv_nonzero_cnt`, **(neu)** → `13 §3.10`), ohne den Burst zu verwerfen. |
| **R-18-03** | Jede Roadmap-Funktion, deren Bedarf sich auf der Luft zeigt, hat in Stufe 1 **einen Zähler**, der den Bedarf messbar macht (P6). Die Zählerliste steht in §2.4. | Für jeden Zähler der Liste ein Leseweg über `07` und ein Eintrag im Betriebsstatus (`13`). |
| **R-18-04** | Stufe 1 beantwortet einen Vollduplex-Wunsch mit **Simplex**. Das Simplex/Duplex-Bit wird in `D-SETUP`, `D-CALL PROCEEDING`, `D-ALERT` und `D-CONNECT` **nicht gespiegelt**, sondern auf `0` gesetzt, und die Herabsetzung wird gezählt. | Air-Test mit einem Endgerät, das `simplex/duplex = 1` im `U-SETUP` sendet: alle vier Downlink-PDUs tragen `0`, `duplex_downgrade_cnt` = 1, Ruf läuft halbduplex durch. |
| **R-18-05** | Stufe 1 beantwortet einen Energiespar-Wunsch mit „Stay alive", **speichert aber den gewünschten Modus im Teilnehmerdatensatz**. | Anmeldung mit gesetztem Energiespar-Element: Bestätigung trägt 14 bit `0`; der Datensatz zeigt den angeforderten Wert; `energy_saving_req_cnt` = 1. |
| **R-18-06** | Stufe 1 stiehlt einen Verkehrsschlitz nur vollständig (beide Halbblöcke Signalisierung). Das Metadatenbit für die spätere Halb-Stehl-Betriebsart ist reserviert, nicht belegt. | `12` R-12-18 gilt; §2.3 Zeile „`W14[29]`" ist in Stufe 1 auf 0 geprüft. |
| **R-18-07** | Der Codepunkt `10₂` von `burst_type` in der Uplink-Burst-Mailbox bleibt für den STCH-tragenden Uplink-Burst reserviert. Stufe 1 erzeugt ihn nicht, aber die Software verwirft ihn definiert und zählt ihn. | Einspeisetest in der Simulation über den benannten, simulationsexklusiven Einspeisepfad `ulmb_inject` (`07 §5.2`), der auch das **Kopfwort** setzt (`burst_type = 10₂`); ein Schreibweg über die Registerseite existiert bewusst nicht (`REG_ULMB_DATA` RO), `REG_SCRATCH` (`07 §3.1.1`) deckt nur den Bus-Selbsttest. Erwartung: Software verwirft ohne Decodierversuch (`13 §3.2`), `ul_burst_type_unsupported_cnt` = 1, kein Absturz, kein Fehlparse. |
| **R-18-08** | **Änderungsforderung an `05` — heute nicht erfüllt.** Die Kanalcodierung soll datengetrieben werden: Punktierungsrate `t`, Punktierungsmuster `P[]`, `i`-Abbildung, Interleaver-Parameter `(K, a)` und Prüffeld-Variante sind Einträge **einer** Kanaltabelle; ein zusätzlicher Kanal ist dann eine Tabellenzeile. Der Stand in `05` ist das Gegenteil: `05 §2.4` exportiert ein festes `enum tetra_cc_chan_t` mit sechs Konstanten („logischer Kanal — bestimmt alle Parameter"), und `05 §3.3` legt ausdrücklich fest „Parameter je Kanal — direkt aus den Kanalabschnitten, **nicht** aus einer Tabelle". Solange das so bleibt, ist ein zusätzlicher Kanal zwingend eine Codeänderung. | Zwei Stufen: (a) `05` ist geändert — Kanaltabelle eingeführt, der Satz „nicht aus einer Tabelle" in `05 §3.3` gestrichen (O-18-8); (b) danach Unit-Test: ein zusätzlicher Tabelleneintrag mit den Parametern von TCH/4,8 (`§3.1.9`) erzeugt ohne Codeänderung Bit-für-Bit die erwartete Ausgabe des Testvektors. Ohne (a) gilt die Anforderung als offen, nicht als erfüllt. |
| **R-18-09** | Die Burst-Geometrie ist in **einer** Feldtabelle je Burstformat abgelegt — im RTL, im Referenzdecoder und in der Testbench dieselbe Quelle. Ein zusätzliches Burstformat ist eine zweite Tabelle, keine Logikänderung. | `02` O-02-9-Konsistenzprüfung; Nachweis über einen Generator, der alle drei Verbraucher aus einer Quelle speist (`14`). |
| **R-18-10** | Der Sprachpfad legt die 274 Parameter-Bits je Burst an einer dokumentierten Modulschnittstelle offen (`12 §3.2.3`). Ein späterer Analyse-/Synthese-Codec, eine Aufzeichnung oder eine Mischung hängt sich dort ein, ohne die Weiterleitungskette zu ändern. | Unit-Test: ein zweiter Verbraucher liest dieselben Parameter-Bits, die Weiterleitung bleibt bit-identisch. |
| **R-18-11** | Kein Analyse-/Synthese-Codec und keine darauf aufbauende Funktion (§3.3) wird gebaut, bevor die Rechenlast **auf dem Zielprozessor** gemessen ist — Perzentile 50/99 über mindestens 60 s Sprechzeit. | Messprotokoll als `[MESS]` in `08_TIMING`; ohne dieses Protokoll gilt der Eintrag als nicht begonnen. |
| **R-18-12** | Stufe 1 baut die Roh-Empfangsdaten-Aufzeichnung (§3.4) einschließlich Abzweigpunkt, Registerfenster und Auslese-Werkzeug. Sie ist Arbeitsmittel, keine Nachrüstung. | `03`/`02`-Abnahme läuft über einen mit diesem Werkzeug gezogenen Mitschnitt; ohne das Werkzeug ist die Abnahme nicht durchführbar. |
| **R-18-13** | Kein Eintrag dieses Kapitels wird begonnen, bevor eine Messung den Bedarf belegt. Die Messgröße ist je Eintrag in §3 benannt. Theorie ist kein Bedarfsnachweis. | Review: zu jedem begonnenen Eintrag existiert ein `[MESS]`- oder `[GOLD]`-Beleg für die Bedarfsfrage. |
| **R-18-14** | Ressourcenbewertung eines Eintrags erfolgt ausschließlich über LUT, FF, BRAM, DSP und WNS gegen das Budget in `01 §3.9`. Slice-Auslastung ist kein Kriterium. | Jede Ressourcenaussage in §3 trägt `[BUILD]`, `[ANNAHME]` oder einen Verweis auf `01 §3.9`. |

---

## 2. Architektur / Aufbau

### 2.1 Wie dieses Kapitel gelesen wird

Jeder Eintrag in §3 hat dieselben fünf Punkte: **was fehlt** (funktional, nicht als
Modulliste), **normative Grundlage** (die ETSI-Stelle), **betroffene Kapitel** (wo die
Fachspezifikation entstehen würde), **Ressourcenbedarf** (LUT/FF/BRAM/DSP oder Rechenlast,
mit Evidenzmarker) und **Vorsorge in Stufe 1** — was Stufe 1 tun oder lassen muss. Ein
Eintrag ohne den letzten Punkt gehört nicht in dieses Kapitel.

### 2.2 Die vier Gruppen

| Gruppe | Inhalt | Gemeinsames Merkmal |
|---|---|---|
| **A** — Fehlende Grundfunktionen | Rufsucher-Betrieb, Vollduplex-Einzelruf, Halbschlitz-Stehlen im laufenden Ruf, bestätigter Gruppenruf und Rundruf, Sprechwunsch-Warteschlange, Adressvergabe, Gruppenverteilung von Kurznachrichten, Zustellberichte, leitungsvermittelte Datenkanäle, nicht-kontinuierliche Burstformate | Alle in ETSI normativ definiert, alle in Software oder als Tabellenzeile umsetzbar. **Kein** Eintrag dieser Gruppe braucht einen neuen großen RTL-Block. |
| **B** — Empfangsgüte | Phasenverfolgende Demodulation, kohärente Demodulation mit Kanalschätzung, Bruchteil-Symboltiming im Uplink, Zusammenführung mehrerer Empfangszweige | Alle im RTL, alle im Empfangspfad, alle nur nach vorheriger Messung an eigenen Mitschnitten. Der letzte Eintrag ist an einen Plattformwechsel gebunden. |
| **C** — Sprachpfad | Sprachaufzeichnung, Ansagen, Konferenzmischung, Verbindung zu einem leitungsvermittelten Netz | **Alle vier** hängen an einem Analyse-/Synthese-Codec, den `12` R-12-02 bewusst ausschließt. Gemeinsame Vorbedingung: Rechenlastmessung (R-18-11). |
| **D** — Arbeitsmittel und Skalierung | Roh-Empfangsdaten-Aufzeichnung, Teilnehmerzahl über 1024 je Typ (`13 §4`), Massendatenpfad ins Hauptspeicher | Kein Produktmerkmal, aber Voraussetzung für Gruppe B bzw. Grenze des Stufe-1-Entwurfs. |

### 2.3 Vorsorge-Inventar: reservierte Felder (Erfüllung von R-18-02)

Dies ist die vollständige Liste der Bits und Codepunkte, die Stufe 1 **freihalten** muss.
Adressen und Wortbelegungen stehen normativ in `07_PS_PL_CONTRACT`; hier stehen nur die
Reservierungen und ihr Zweck.

| Ort | Feld | Reserviert für | Eintrag |
|---|---|---|---|
| DL-PDU-Mailbox `W14` | `[20:7]` | Frei geworden mit dem Entfall des mitreisenden AACH-Infoworts (`07 §3.3`; das Infowort entsteht nach `06` R-06-04 im PL). Keine geplante Nachnutzung — die Bits bleiben 0 und sind der Nachweis, dass niemand das V1-Feld wiederbelebt | §2.3 |
| DL-PDU-Mailbox `W14` | `[29]` (aus `[31:29]`) | `bkn2_from_persist` — BKN2 aus dem Halteinhalt des Zeitschlitzes statt aus der Mailbox: die Halb-Stehl-Betriebsart | §3.1.3 |
| DL-PDU-Mailbox `W14` | `[31:30]` | Halbschlitz-Sprachcodierung: Kennzeichnung „BKN2 trägt einen Halbschlitz-Sprachblock" | §3.1.3 |
| DL-PDU-Mailbox `W15` | `[10:9]` `pdu_class` Codepunkte `10₂`/`11₂` | Halbschlitz-Sprachblock bzw. Blocklängen der leitungsvermittelten Datenkanäle | §3.1.3, §3.1.9 |
| UL-Burst-Mailbox `W0` | `[1:0]` `burst_type` Codepunkt `10₂` | STCH-tragender Normal-Uplink-Burst (NTS2 erkannt) | §3.1.3 |
| UL-Burst-Mailbox `W0` | `[30:23]` | Erkennungs-Metadaten des NTS2-Zweigs (welche Halbschlitz-Kombination nach [ETSI Tabelle 9.13]) | §3.1.3 |
| UL-Burst-Mailbox `W1` | `[31:28]` | `was_reserved` und weitere Zusage-Metadaten (`11` O-11-1) | §3.1.3, §3.1.8 |
| UL-Burst-Mailbox `W2` | `[31:24]` | Zweigkennung und Zweig-Pegel bei mehreren Empfangszweigen | §3.2.5 |
| `REG_UL_ASSIGN_CFG` | `[31:21]` | Fensterverlängerung für Uplink-Ketten über die feste Zusagegröße hinaus (`11` O-11-2) | §3.1.8 |
| Zeitplan-Eintrag | `[1:0]` (`04` O-04-5) | „Slot ist Verkehr, Signalisierung fasst ihn nicht an" — Voraussetzung für die Slotpaar-Vergabe des Vollduplex-Rufs | §3.1.2 |
| Anmeldebestätigung | Energiespar-Element, 14 bit | Energiesparmodus + Startpunkt statt `0` = Stay alive | §3.1.1 |

**Richtung beachten.** Die drei Zeilen `W0[30:23]`, `W1[31:28]` und `W2[31:24]` liegen in der
UL-Burst-Mailbox (PL → PS); deren Datenfenster ist nur lesbar (`REG_ULMB_DATA` RO, `07 §3.4`).
Sie sind darum **nicht** über einen Schreib-/Rücklesetest prüfbar, sondern nach R-18-02 Teil (b).
`07 §3.4` deklariert heute nur `W2[31:24]` ausdrücklich als „reserviert | 0"; `W0[30:23]` und
`W1[31:28]` sind dort schlicht unbelegt und nachzutragen (O-18-10).

**Warum das eine Liste und keine Prosa ist.** V1 hat mehrfach benannte, aber nie gelesene
Bits geführt; `04` O-04-5 beschreibt, was das anrichtet. Ein reserviertes Bit ohne Zweck und
ohne Prüfung wird beim nächsten Umbau als „frei" belegt. Ein reserviertes Bit **mit**
benanntem Zweck und einer Prüfung auf 0 überlebt.

### 2.4 Vorsorge-Inventar: Bedarfszähler (Erfüllung von R-18-03)

Diese Zähler existieren in Stufe 1, obwohl die zugehörige Funktion nicht existiert. Sie sind
der einzige zulässige Bedarfsnachweis nach R-18-13. Spalte „Herkunft": das Fachkapitel, das
den Zähler bereits führt — **(neu)** heißt, dieses Kapitel führt ihn hier ein und das genannte
Fachkapitel hat ihn aufzunehmen.

| Zähler | Beantwortet die Frage | Herkunft | Eintrag |
|---|---|---|---|
| `energy_saving_req_cnt` | Fragt überhaupt ein Endgerät Energiesparbetrieb an? | **(neu)** → `09` | §3.1.1 |
| `duplex_downgrade_cnt` | Fragt überhaupt ein Endgerät einen Vollduplex-Ruf an? | **(neu)** → `10` | §3.1.2 |
| `ul_burst_type_unsupported_cnt` | Erreicht ein nicht unterstützter Burst-Typ die Software? | `13 §3.10.2` (Verzweigung `13 §3.2`) | §3.1.3 |
| `ul_nts2_detect_cnt` | Stiehlt überhaupt ein Endgerät im Uplink? | `06 §3.3.2` | §3.1.3 |
| `steal_override_cnt` | Wie oft stiehlt die Basisstation selbst einen Verkehrsschlitz? | `04 §3.4` (gefordert in `10 §2.4` / R-10-09), Register `07 §3.1.8` | §3.1.3 |
| `tx_demand_preempt_cnt`, `floor_grant_cnt` | Drängeln sich Sprecher, braucht es eine Warteschlange? | `10` O-10-5 | §3.1.5 |
| `reass_t0_cnt`, `reass_gap_cnt` | Brechen Uplink-Ketten an der Zusagegrenze ab? | `11` O-11-2 | §3.1.8 |
| `sds_group_skip_cnt` | Kommen gruppenadressierte Kurznachrichten vor? | `11 §3.8` | §3.1.7 |
| `llc_link_evict` | Reicht die Verbindungstabelle? | `09` O-09-2 | §3.5 |
| `reass_evict_cnt` | Reichen die Zusammensetz-Kontexte? | `11` O-11-3 | §3.5 |
| `db_full_cnt` | Reicht die Teilnehmertabelle? | **(neu)** → `13` | §3.5 |
| `voice_bfi_cnt` | Ist die Empfangsgüte der begrenzende Faktor? | `12 §3.5.4` | §3.2 |
| `W2.sym_norm`, `W2.corr_peak` (Verteilung je Burst) | Stimmt der Arbeitspunkt des Empfängers? | `07 §3.4` | §3.2 |

---

## 3. Detail-Spezifikation

### 3.1 Gruppe A — fehlende Grundfunktionen des Standards

#### 3.1.1 Rufsucher-Betrieb (Energiesparbetrieb mit Aussendung im Wachfenster)

**Was fehlt.** Ein Endgerät kann mit der Basisstation aushandeln, dass es den Steuerkanal
nur noch periodisch abhört: es schläft N TDMA-Frames und empfängt dann genau einen
Downlink-Zeitschlitz [ETSI §19.4.5]. Solange es schläft, ist es nicht erreichbar. Die
Basisstation muss deshalb jede an dieses Endgerät gerichtete Downlink-Signalisierung — die
Rufankündigung eingeschlossen — **in dessen Wachframe** aussenden. V2 Stufe 1 kann das
nicht: sie antwortet auf jeden Energiespar-Wunsch mit „Stay alive"
[GOLD Burst #783; `09 §3.4` Bit 12, 14 bit `0`] und hält keine Wachfenster-Rechnung.

**Normative Grundlage.**

| Größe | Wert | Beleg |
|---|---|---|
| Aushandlung | über MM-Statusnachrichten oder im Anmeldevorgang | [ETSI §16.7.1] |
| Element in der Bestätigung | 14 bit = Energiesparmodus (3) + Framenummer (5) + Multiframenummer (6) | [ETSI §16.10.10 Tab. 16.40] |
| Schlafdauer je Gruppe | EG1…EG7 = 1 / 2 / 5 / 8 / 17 / 71 / 359 TDMA-Frames | [ETSI §23.7.6 Tab. 23.9] |
| Rückkehr in den Schlafzyklus | `T.210` = 18 TDMA-Frames nach der letzten Aktivität | [ETSI Anhang B.1] |
| Aufwachgründe | Kanalzuweisung, Ruf, eigene Signalisierung, **empfangene Signalisierung an eine eigene Adresse** | [ETSI §23.7.6] |

Bemerkenswert an der letzten Zeile: das Endgerät verlässt den Schlafzyklus, sobald es **eine**
Nachricht an eine eigene Adresse empfangen hat. Die Basisstation muss also nur das **erste**
Element einer Nachrichtenfolge im Wachfenster platzieren; danach hört das Endgerät für
`T.210` durchgehend zu. Das reduziert die Funktion auf eine Sendezeitpunkt-Regel für den
jeweils ersten Downlink-Eintrag je Endgerät.

**Betroffene Kapitel.** `09_LLC_MLE_MM` (Aushandlung, Element in der Bestätigung,
MM-Statusnachrichten), `13_SW_ARCHITECTURE` (Wachfenster-Rechnung, Halten der
Downlink-Einträge), `10_CMCE_CALL` (Rufankündigung an ein schlafendes Endgerät).
**Kein** RTL-Anteil.

**Ressourcenbedarf.** Software: je Teilnehmerdatensatz 3 bit Modus + 11 bit Startpunkt
(Frame- und Multiframenummer) und eine Modulo-Rechnung gegen `REG_TDMA_STATE`. Speicher und
Rechenlast sind gegenüber der bestehenden Teilnehmerverwaltung nicht messbar [ANNAHME —
14 bit je Datensatz bei 1024 Datensätzen je Typ (`13 §4`) = 1,75 kByte je Typ; keine Messung
nötig, weil die Größenordnung gegenüber `09 §2.3` verschwindet].

**Vorsorge in Stufe 1 (R-18-05):**

1. **Das Element wird gesendet, nicht weggelassen.** Die Anmeldebestätigung trägt das
   Energiespar-Element mit dem Anwesenheitsbit `1` und dem Inhalt `0`
   (= Stay alive, Frame 0, Multiframe 0) — genau wie die Referenzzelle
   [GOLD #783], [ETSI §16.10.10 NOTE 1/2]. Damit ändert die Nachrüstung nur einen
   **Wert**, nicht die PDU-Struktur und nicht die Länge.
2. **Der Wunsch wird gespeichert.** Der Wanderer über die Anmeldeanforderung liest das
   Typ-2-Element „Energy saving mode" (`09 §3.4.1` Feld 7) und legt den Wert im
   Teilnehmerdatensatz ab, auch wenn Stufe 1 ihn nicht verwendet. Ohne diese Ablage weiß
   niemand, ob im eigenen Netz überhaupt Endgeräte Energiesparbetrieb anfragen.
3. **`energy_saving_req_cnt`** zählt Anfragen. Bleibt der Zähler über einen Betriebstag 0,
   ist der Eintrag nach R-18-13 nicht zu beginnen.
4. **Die absolute Zeitposition ist der Software jederzeit lesbar.** `REG_TDMA_STATE` liefert
   `tn/fn/mn/hn` kohärent in einem Lesevorgang (`07 §3.1`). Damit ist die
   Wachfenster-Rechnung reine Software; es braucht **kein** neues Register.
5. **Was Stufe 1 lassen muss:** kein Verzögerungsmechanismus im Zeitraster für diesen Zweck.
   Das Feld `delay_slots` der DL-Mailbox fasst 63 Slots ≈ 16 Frames (`07 §3.3`) und deckt
   damit nicht einmal EG5 ab, geschweige denn EG7 mit 359 Frames. Wer versucht, das
   Wachfenster über `delay_slots` zu erreichen, verbreitert das Feld und bricht damit die
   Wortbelegung. Das Halten des Eintrags gehört in die Software.

**Nicht enthalten und nicht vorzusehen:** „Napping" auf einem zugewiesenen Kanal
[ETSI §19.4.5] und der Doppelwach-Betrieb. Beide setzen den Energiesparbetrieb voraus und
sind erst danach sinnvoll zu spezifizieren.

**Bedarfslage.** Aus der Gold-Aufzeichnung ist **keine** Aussage über Energiespar-Aushandlung
ableitbar: der Referenzdekodierer benennt MM-Informationselemente nicht namentlich, sondern
endet bei „MLE: disc=MM → D-LOC-UPD-ACCEPT" plus Rohbits
(`docs/reference_decode/dl_full.md:18355-18359`). Ein Nullbefund beim Suchen nach „energy" ist
darum ein Werkzeug-Artefakt und kein Beleg — dieselbe Suche findet auch „subscriber class" oder
„location update accept type" nicht, obwohl beide Elemente in derselben PDU liegen. Belegt ist
nur: die Referenzzelle sendet in #783 das Element mit 14 bit `0` = „Stay alive", also dasselbe
wie wir [GOLD #783, `09 §4`]. Die Bedarfsfrage „fragt überhaupt ein Endgerät
Energiesparbetrieb an?" beantwortet damit ausschließlich `energy_saving_req_cnt` im eigenen
Netz (R-18-13). Der Eintrag ist funktional vollständig aus ETSI belegt und praktisch unbelegt
— ein Musterfall für R-18-13.

#### 3.1.2 Vollduplex-Einzelruf

**Was fehlt.** Stufe 1 führt den Einzelruf halbduplex: ein Sprachzeitschlitz, ein Sprecher,
Sprechrecht über `D-TX GRANTED` (`10 §3.6`). Beim Vollduplex-Ruf sprechen beide Seiten
gleichzeitig, es gibt kein Sprechrecht und keinen Sprecherwechsel.

**Normative Grundlage — und die entscheidende Folge.**

Die U-Plane-Betriebsarten sind abschließend aufgezählt; Vollduplex ist genau eine davon:
„Switch U-plane = On, Tx grant = true, simplex/duplex = duplex: MS is authorized to transmit
**and** receive traffic" [ETSI §14.5.1.4.0, Kombination 3]. Stufe 1 erzeugt diese Kombination
nie.

Wichtiger als die Betriebsart ist die **Kapazitätsfolge**. Das Kanalzuweisungs-Element trägt
**ein** Feld „Timeslot assigned" und ein Feld „Up/downlink assigned" mit den Werten
„Downlink only", „Uplink only", „Both uplink and downlink"
[ETSI §21.5.2 Tab. 21.87]. Ein Endgerät bekommt also für Uplink und Downlink **dieselbe**
Zeitschlitznummer. Zwei Endgeräte desselben Rufs können deshalb nicht denselben
Zeitschlitz benutzen — sie würden im Uplink kollidieren. Ein Vollduplex-Einzelruf zwischen
zwei Endgeräten derselben Zelle belegt daher **zwei** Verkehrszeitschlitze, einen je
Teilnehmer [abgeleitet aus ETSI Tab. 21.87 + §23.1.3.1.1]. Auch die Umgehung über zwei
Zuweisungen je Teilnehmer („Downlink only" auf dem einen, „Uplink only" auf dem anderen
Zeitschlitz, [ETSI §23.3.4]) spart nichts: es bleiben zwei Zeitschlitze.

Bei drei nutzbaren Verkehrszeitschlitzen (TS2…TS4; TS1 trägt den Steuerkanal, `12` O-12-6)
heißt das: **ein** Vollduplex-Einzelruf und **ein** weiterer Ruf pro Träger, nicht mehr.

Was **nicht** der Blocker ist: die Geräteklasse. Ein frequenz-halbduplexfähiges Endgerät kann
einen einschlitzigen Duplexdienst im Zeitduplex führen — „If both the uplink and downlink slot
in figure 23.2 are used by a single MS, time division duplex operation can be realized allowing
a frequency half duplex MS to support single-slot duplex call services" [ETSI §23.1.3.1.1].
Der Ruf scheitert also nicht an den Endgeräten, sondern an der Slotpaar-Vergabe und der
Rufsteuerung in der Basisstation.

**Betroffene Kapitel.** `10_CMCE_CALL` (Zustandsmaschine ohne Sprechrecht, Slotpaar-Vergabe,
`D-CONNECT`/`D-CONNECT ACKNOWLEDGE` mit Duplexbit, Abbau beider Zeitschlitze), `12_VOICE`
(zwei gleichzeitige Weiterleitungen, Wegfall der Ruhe-Erkennung als Sprecherwechsel-Ersatz),
`06_MAC` (Zugriffszuweisungs-Muster für zwei gleichzeitig belegte Verkehrsschlitze),
`08_TIMING` (kein neuer Zeitpfad — beide Richtungen sind bestehende Ein-Burst-Weiterleitungen).

**Ressourcenbedarf.** RTL: keiner. Der Sendepfad hat vier Halteplätze, einen je Zeitschlitz
(`07 §3.3`); zwei gleichzeitig belegte Sprachschlitze sind der bereits gebaute Mehrschlitz-Fall
des Gruppenrufs. Software: eine zweite Weiterleitungskette, Rechenlast ≈ 129 µs je Burst und
Kanal, also ≈ 2,2 ms/s [ANNAHME — Bilanz aus `12 §3.9`: gemessen sind 9,32 µs je Rahmen auf
dem Entwicklungsrechner [SIM 2026-07-25], hochgerechnet mit dem dort angenommenen
Skalierungsfaktor 10–12 auf den Cortex-A9 und 100 ns je AXI-Zugriff, beides selbst
[ANNAHME]] — im Rahmen der dort bilanzierten drei Kanäle, kein zusätzliches Budget.

**Vorsorge in Stufe 1:**

1. **Das Duplexbit wird ausgewertet und gespeichert, aber nicht gespiegelt (R-18-04).** Der
   Ruf-Platz führt `simplex_duplex` bereits (`10 §3.3`). Stufe 1 setzt es in den
   Downlink-PDUs jedoch **hart auf 0** und zählt `duplex_downgrade_cnt`. Das ist eine
   Korrektur gegenüber der heutigen Festlegung „Spiegel" in `10 §3.1.2`, §3.1.3 und §3.1.1:
   ein gespiegeltes Duplexbit verspricht dem Endgerät Kombination 3 aus [ETSI §14.5.1.4.0],
   die Stufe 1 nicht liefert. Diese Zeile gehört als Änderung nach `10`.
2. **Der Ruf-Platz trägt zwei Verkehrsschlitze, nicht einen.** `voice_ts` ist in Stufe 1 ein
   Feld (`10 §3.3`). Die Vorsorge ist **nicht**, ein zweites Feld einzuführen, sondern die
   Zuordnung Ruf → Zeitschlitz **nicht** als „ein Zeitschlitz je Ruf" in die Datenstruktur zu
   verdrahten: alle Stellen, die von `voice_ts` auf den Ruf zurückschließen, benutzen die
   zentrale Suchfunktion, nicht eine Umkehrabbildung mit einem Eintrag je Ruf.
3. **Die Ruhe-Erkennung ist an den Zeitschlitz gebunden, nicht an den Ruf.** Die
   Sprechpausen-Erkennung wirkt in Stufe 1 bereits **nur auf den Zeitschlitz** des jeweiligen
   Rufs (`12 §3.6.1`, Aktivbit und Ablage je Zeitschlitz); damit funktioniert sie unverändert,
   wenn ein Ruf zwei Zeitschlitze hat.
4. **Reserve im Zeitplan-Eintrag** (`04` O-04-5, Bits `[1:0]`) bleibt frei. Die Bedeutung
   „dieser Slot trägt Verkehr, Signalisierung fasst ihn nicht an" ist genau die, die eine
   Slotpaar-Vergabe braucht, damit eine Signalisierungs-PDU nicht eine der beiden
   Sprachrichtungen verdrängt.
5. **Was Stufe 1 lassen muss:** keine Annahme „höchstens ein aktiver Sprecher je Ruf" in der
   Weiterleitungskette. `12 §3.4` arbeitet je Zeitschlitz und erfüllt das schon; die
   Rufsteuerung darf die Annahme nicht nachträglich einziehen.

#### 3.1.3 Stehlen von Halbschlitzen im laufenden Ruf

Dieser Eintrag hat **drei** getrennte Teile mit unterschiedlichem Stand. Sie werden hier
zusammen geführt, weil sie dasselbe Bündel von Schnittstellen berühren.

**Teil 1 — Halb-Stehlen im Downlink mit lebender Sprachhälfte.**

*Was fehlt:* Stufe 1 stiehlt einen Verkehrsburst **vollständig** — beide Halbblöcke tragen
Signalisierung (`10 §2.4`, Inhaltsklasse 3) — und verliert damit **60 ms** Sprache je
gestohlenem Burst, beide ACELP-Rahmen dieses Bursts (`12 §3.1.2`). Die Referenzzelle sendet
`D-TX CEASED` mit BKN1 = Signalisierung und BKN2 = lebender Sprachhälfte und verliert nur
**30 ms** [GOLD 2. Referenzaufnahme, `10 §2.4`]. Genau diese Variante fordert die Norm:
Der Sprachkanal verwirft die Typ-1-Bits des Rahmens A und codiert Rahmen B in
Halbschlitz-Betriebsart [ETSI §8.3.1.3.6 NOTE].

*Normative Grundlage der Halbschlitz-Sprachcodierung* [ETSI §8.3.1.3.7]:

| Größe | Vollschlitz | Halbschlitz |
|---|---:|---:|
| Sprachrahmen je Burst | 2 (274 bit) | 1 (137 bit) |
| type-3-Bits | 432 | 216 |
| Prüffeld über Klasse 2 | 8 bit | 4 bit [CODE sw/etsi_codec/const.tab:44-45] |
| Punktierung Klasse 2 | 8/18 | 8/17 [CODE sw/etsi_codec/arrays.tab:60-65] |
| Interleaver | 24 × 18 (432) | **(216, 101)** [ETSI §8.3.1.3.7] |
| belegter Block | BKN1 + BKN2 | **nur BKN2** [ETSI §8.3.1.3.7 Gl. 8.60 + NOTE] |

*Ressourcenbedarf:* Software. Ein zweiter Parametersatz an derselben Modulschnittstelle
(`12 §3.2.3`); die Struktur ist in den Referenzquellen vorhanden, aber nicht aufgerufen
[CODE sw/etsi_codec/ccod_tet.c:60-95, CODE sw/etsi_codec/cdec_tet.c:55-73]. Rechenlast etwa
die Hälfte der Vollschlitz-Kette, also ≈ 5 µs je Burst auf dem Host [ANNAHME — halbe
Blocklänge bei gleicher Struktur; die Vollschlitz-Kette ist mit 9,32 µs gemessen,
SIM 2026-07-25]. **Kein** RTL.

*Vorsorge in Stufe 1:* `W14[29]` der DL-Mailbox bleibt frei und heißt später
`bkn2_from_persist` (§2.3): „BKN2 nicht aus der Mailbox, sondern aus dem Halteinhalt dieses
Zeitschlitzes nehmen". Der Halteinhalt existiert in Stufe 1 (`07 §3.3`,
`mode = PERSIST_SET`) und der Sendepfad kann NTS2 wählen (`04 §3.6`).
Das Verdrängungsereignis kennt der Burst-Verteiler **ebenfalls**: `04 §3.4` führt die
Umkehrung für `head_target_tn = tn ∧ head_pdu_class = 01₂ ∧ persist_valid[tn]` als Ausnahme
zwischen Rang 1 und Rang 2 und den Zähler `steal_override_cnt`
(`07 §3.1.8 REG_STEAL_OVERRIDE_CNT`) als Nachweis — die Forderung aus `10 §2.4` / R-10-09 ist
damit in Stufe 1 eingelöst; V1 hat sie nicht
[CODE rtl/tx/tetra_burst_dispatcher.v:222-311]. Die
Nachrüstung ist damit ein Bit und ein Multiplexer-Eingang — **kein** neues PDU-Format und
**kein** zweiter Sendepfad. `W14[31:30]` bleibt für die Kennzeichnung „BKN2 trägt einen
Halbschlitz-Sprachblock" frei, `W15` `pdu_class` behält die Codepunkte `10₂`/`11₂`.

*Bedarfsmessung vor Umsetzung:* ist der Sprachverlust von 60 ms überhaupt hörbar? Hörvergleich
bei gleicher Stehlrate, `steal_override_cnt` als Bezugsgröße. Ohne diese Messung nicht bauen
(R-18-13).

**Teil 2 — Auswertung gestohlener Uplink-Bursts (STCH im Uplink).**

*Was fehlt:* Ein Endgerät stiehlt im Uplink, um dringende Signalisierung während seiner
eigenen Sprachaussendung zu senden. Die Norm schreibt für `U-TX CEASED` und
`U-DISCONNECT` „steal immediately" vor [ETSI §14.5.6.2.0 Tab. 14.2], mit
Wiederholungsmechanismus `N.214` = 4 aufeinanderfolgende Verkehrsframes
[ETSI §23.8.4.1.3, Anhang B.2]; für Antworten während eigener Sprachaussendung gilt „steal
within time `T.214`" mit `T.214` = 6 Uplink-Gelegenheiten [ETSI §23.8.4.1.2 b), Anhang B.1].
Ein gestohlener Uplink-Burst trägt NTS2 statt NTS1 [ETSI Tabelle 9.13]. Stufe 1 **erkennt**
ihn (zweiter Korrelatorzweig mit `ul_nts2_detect_cnt`, `06 §3.3.2`), wertet ihn aber nicht
aus. Funktionale Folge: das Freigeben des Sprechrechts läuft über den langsameren Weg
(reservierter Unterschlitz oder Zufallszugriff in Frame 18) statt über den von der Norm
vorgesehenen sofortigen Diebstahl.

*Normative Erfassungsgeometrie:* NTS2 hat dieselbe Länge und dieselbe Position im Burst wie
NTS1 [ETSI Tabelle 9.5: „n1 to n22 **or** p1 to p22"]. Die Erfassung ist also identisch; nur
die Kanalinterpretation unterscheidet sich.

*Betroffene Kapitel:* `06_MAC` (Halbschlitz-Zerlegung, Kanalzuordnung nach [ETSI Tabelle 9.13]),
`05_CHANNEL_CODING` (**keine neuen Parameter**: STCH steht schon als Zeile in der
Kanaltabelle `05 §3.8` mit `K1 = 124`, Blockcode (140,124), Rate 2/3, Interleaver (216,101),
Zell-Startwert — für Downlink **und** Uplink identisch; es fehlt nur der Aufruf im
Empfangspfad), `10_CMCE_CALL` (schnellere Sprechrecht-Freigabe).

*Ressourcenbedarf:* **RTL: keiner.** Der NTS2-Korrelatorzweig samt Trefferzähler
`ul_nts2_detect_cnt` steht in **Stufe 1** (`06 §3.3.2`); seine LUT, FF und DSP gehören damit
ins Budget `01 §3.9` und nicht in diesen Roadmap-Eintrag. Zur Größenordnung des dort
bilanzierten Zweigs: ≈ 145–185 LUT und ≈ 229–265 FF nach den Nachbarinstanzen
[BUILD 2026-06-20 build/reports/cur_hier_deep.rpt:173-174: `u_ul_sync_detect` 183 LUT/265 FF/4 DSP,
`u_ul_sync_nub` 145 LUT/229 FF/4 DSP]; die 4 DSP48 entfallen, wenn die gemeinsame
Differenzdibit-Quelle aus `03` O-03-3 gebaut ist — dann speist **eine** 4-DSP-Rechnung alle
Korrelatoren, sonst kommen 4 DSP48 hinzu (von 220 [Datenblatt-Konstante], 38 belegt
[BUILD 2026-07-12 build/reports/impl_utilization.rpt §4]). Der Aufwand **dieses** Eintrags
reduziert sich damit auf die Halbschlitz-Zerlegung und die Protokollauswertung, beide in
Software. Zu korrigieren ist die gegenläufige Zeile „Umsetzung nach Stufe 1 (Kapitel 18)" in
`03` O-03-6 — sie widerspricht `06 §3.3.2` und macht `ul_nts2_detect_cnt` in Stufe 1
unzählbar (O-18-9).

*Vorsorge in Stufe 1 (R-18-07):*
- `burst_type`-Codepunkt `10₂` der UL-Mailbox bleibt für den STCH-tragenden Burst reserviert;
  die Software verwirft ihn definiert und zählt (`ul_burst_type_unsupported_cnt`).
- `W0[30:23]` bleibt für die Angabe frei, **welche** Halbschlitz-Kombination erkannt wurde
  (STCH+TCH, STCH+STCH, SCH/HD+SCH/HD, SCH/HD+BNCH [ETSI Tabelle 9.13]).
- Die gemeinsame Differenzdibit-Quelle (`03` O-03-3) wird in Stufe 1 gebaut. Sie ist dort
  aus Ressourcengründen empfohlen und ist gleichzeitig die Vorsorge für den NTS2-Zweig: mit
  ihr ist er DSP-neutral, ohne sie nicht.
- `ul_nts2_detect_cnt` ist die Bedarfsmessung. Bleibt er 0, tritt der Fall im eigenen Netz
  nicht auf; V1 hätte ihn niemals gesehen und kann darum nichts dazu beitragen.

**Teil 3 — Halbschlitz-Sprachcodierung als eigenständige Betriebsart.**

Teil 1 braucht sie im Sendepfad, Teil 2 im Empfangspfad (ein gestohlener Uplink-Burst
enthält in BKN2 einen Halbschlitz-Sprachblock, wenn die Kombination STCH+TCH ist). Sie ist
darum **einmal** zu bauen und von beiden Richtungen zu benutzen — nicht zweimal. Die
Parameter stehen in der Tabelle unter Teil 1; die Modulschnittstelle ist `12 §3.2.3`.
Verbindlich bleibt bis dahin `12` R-12-18: **ohne** diese Betriebsart darf kein
Sprachzeitschlitz halb gestohlen werden.

#### 3.1.4 Bestätigter Gruppenruf und Rundruf

**Was fehlt.** Die Kommunikationsarten `10₂` (bestätigter Gruppenruf) und `11₂` (Rundruf)
werden von Stufe 1 wie ein normaler Gruppenruf behandelt (`10` O-10-4). Der bestätigte
Gruppenruf verlangt die Abfrage der Mitglieder [ETSI §14.5.2.6]; der Rundruf verlangt, dass
Sendeanforderungen der Empfänger unterdrückt werden [ETSI §14.5.2.1.0 c)].

**Ressourcenbedarf.** Rundruf: ein Bit. Das Feld „Sendeanforderung erlaubt" existiert in
`D-SETUP` (Bit 35) und `D-CONNECT` (Bit 27) und wird in Stufe 1 auf „erlaubt" gesetzt
(`10 §3.1.2`, §3.1.3). Bestätigter Gruppenruf: Zustandshaltung je Mitglied in Software,
kein RTL.

**Vorsorge in Stufe 1.** Die Kommunikationsart wird aus `U-SETUP` gelesen und im Ruf-Platz
als `comm_type` geführt (`10 §3.3`) — auch für `10₂` und `11₂`, obwohl sie gleich behandelt
werden. Die Rufsteuerung entscheidet anhand dieses Feldes, nicht anhand eines abgeleiteten
Booleans „ist Gruppenruf". Damit ist die Unterscheidung später eine Verzweigung, keine
Nachrüstung eines Feldes durch alle PDU-Bauer.

#### 3.1.5 Warteschlange für Sprechwünsche

**Was fehlt.** Stufe 1 erteilt das Sprechrecht sofort und kennt in `D-TX GRANTED` weder
„in Warteschlange" (`10₂`) noch „nicht erteilt" (`01₂`) [ETSI Tab. 14.80]; bei mehr als zwei
drängelnden Sprechern entscheidet das zuletzt eingetroffene `U-TX DEMAND` (`10` O-10-5).
Die Sendewunsch-Priorität `10₂`/`11₂` (vorrangberechtigt, [ETSI Tab. 14.85]) wird gelesen,
aber nicht ausgewertet.

**Ressourcenbedarf.** Software: eine kurze Liste je Ruf. Kein RTL.

**Vorsorge in Stufe 1.** `tx_demand_preempt_cnt` und `floor_grant_cnt` zählen über den
Betrieb; die Priorität wird beim Parsen bereits extrahiert (`10 §3.2.2`) und verworfen —
nicht ignoriert, sondern extrahiert, gezählt und dann verworfen. Ohne belegten Bedarf nicht
bauen.

#### 3.1.6 Adressvergabe (ASSI) und die Verwaltung vergebener Adressen

**Was fehlt.** Stufe 1 arbeitet durchgehend mit der ISSI; die Anmeldebestätigung sendet kein
SSI-Element (Anwesenheitsbit auf Bitposition 8 = `0`, wie [GOLD #783], `09` O-09-6). Eine
Adressvergabe zieht `D-LOCATION UPDATE PROCEEDING` [ETSI §16.9.2.10] und eine Verwaltung
vergebener Adressen nach sich.

**Vorsorge in Stufe 1.** Das Anwesenheitsbit existiert an seiner Bitposition und ist `0`; die
Nachrüstung schiebt kein Feld. Die Adresse, mit der die Software einen Teilnehmer
adressiert, kommt aus **einer** Stelle im Teilnehmerdatensatz — nicht direkt aus dem
empfangenen ISSI-Feld an mehreren Stellen. Nur so kann später eine andere Adresse dort
stehen.

#### 3.1.7 Verteilung einer gruppenadressierten Kurznachricht an mehrere Empfänger

**Was fehlt.** Stufe 1 weist eine an eine Gruppenadresse gerichtete Kurznachricht ab, sendet
aber die Sicherungsschicht-Quittung an den Absender (`11 §3.8`). Die Verteilung an die
angemeldeten Mitglieder braucht zwei Dinge, die Stufe 1 nicht hat: einen **unquittierten**
Downlink-Weg an die Gruppenadresse — „Normal information transfer addressed to a group of
MSs shall use unacknowledged transfer on the downlink" [ETSI §20.3.1, Tab. 20.8/20.9] — und
eine Festlegung, wie Zustellberichte mehrerer Empfänger auf **eine** Nachrichtenreferenz
abgebildet werden.

**Vorsorge in Stufe 1.** Die Abweisung ist normativ zulässig, **sofern** die Dienstauswahl
`0₂` = „individual service" anzeigt: „If the value of this information element is set to
'individual service' when the destination address is a group address, the SwMI may reject the
message" [ETSI §29.4.3.10 Tab. 29.22]. Für `1₂` = „Group or individual service" deckt die
Norm die Abweisung **nicht**; dort ist sie eine bewusste Stufe-1-Festlegung [ANNAHME — Stufe 1
hat keinen unquittierten Gruppen-Downlink, siehe oben], konsistent mit `11 §3.8`. Gezählt wird
in beiden Fällen (`sds_group_skip_cnt`). Wichtiger: die LLC-Schicht der Stufe 1 muss den
unquittierten Betrieb **strukturell** kennen, auch wenn sie ihn nicht benutzt — der
PDU-Typ-Raum und die Zustandshaltung dürfen nicht so gebaut sein, dass jeder
Downlink-Transfer zwingend eine Verbindung mit `V(S)`/`V(R)` anlegt (`09 §2.3`). Sonst ist
die Nachrüstung ein zweiter Sendepfad, und P3 verbietet den.

#### 3.1.8 Uplink-Ketten über die feste Zusagegröße hinaus

**Was fehlt.** Mit inhaltsunabhängiger Zusage (R-00-02) ist die längste empfangbare
Uplink-Nachricht durch `capacity_allocation` begrenzt: bei `C = 3` sind das 98 Oktette
Nutzdaten (`11 §3.9`). Real beobachtet ist eine Kette mit 1 370 bit Transportschicht-Einheit,
die nach der ETSI-Formel **5** Slots braucht [MESS 2026-06-07, `11` O-11-2]. ETSI erlaubt
ausdrücklich mehrere Zusagen für eine Kette [ETSI §23.4.2.1.2 NOTE 9].

**Der Mechanismus ist bereits entworfen und verstößt nicht gegen den Schnitt.** Wird im
**letzten** reservierten Slot eines Fensters wieder ein Vollschlitz-Burst erkannt, verlängert
die Hardware das Fenster um `C` Slots. Das ist hardware-lokal — Burst-Erkennung und Position
im Zeitraster, kein Burst-Inhalt — und damit mit R-00-02 vereinbar.

**Ressourcenbedarf.** RTL: ein Zähler und eine Vergleichsbedingung im Zuweisungsblock,
Größenordnung 20 LUT / 10 FF [ANNAHME — Struktur: Vergleich „verbleibende Halteframes == 1"
gegen das bestehende Sync-Ereignis].

**Vorsorge in Stufe 1.** `REG_UL_ASSIGN_CFG[31:21]` bleibt frei (§2.3) und nimmt später das
Freigabebit und die Höchstzahl der Verlängerungen auf. `reass_t0_cnt` und `reass_gap_cnt`
sind die Bedarfsmessung. Der Zuweisungsblock behält seine harte Eingangsbeschränkung
(`07 §3.1.6` R-07-11): drei Eingangsklassen, kein Decoderpfad. Die Verlängerung darf diese
Beschränkung nicht aufweichen — sonst entsteht genau die Kopplung, an der der V1-Umbau
gescheitert ist [MESS 2026-07-11, `00 §3.4`].

#### 3.1.9 Leitungsvermittelte Datenkanäle und Interleaving über mehrere Blöcke

**Was fehlt.** TCH/4,8 und TCH/2,4 mit ihren Punktierungsraten und das Interleaving über
N Blöcke:

| Kanal | Rate | `t` | Punktierungsmuster `P` | `i`-Abbildung | Beleg |
|---|---|---:|---|---|---|
| TCH/4,8 | 292/432 | 3 | `{1,2,5}` | `i = j + (j−1) div 65` | [ETSI §8.2.3.1.5] |
| TCH/2,4 | 148/432 | 6 | `{1,2,3,5,6,7}` | `i = j + (j−1) div 35` | [ETSI §8.2.3.1.6] |

Interleaving über N Blöcke: [ETSI §8.2.4.2]. Wichtig für die Aufwandsbewertung: alle
π/4-DQPSK-Kanäle benutzen **denselben** Faltungscode — 16-Zustands-Muttercode Rate 1/4 mit
kanalspezifischer Punktierung [ETSI §8.2.3.1]. Ein neuer Kanal braucht also **keinen** neuen
Viterbi-Decoder.

**Vorsorge in Stufe 1 (R-18-08) — als Änderung an `05` einzutragen, nicht als dortiger
Stand.** Die Punktierungsfunktion **soll** `t`, `P[]` und die `i`-Abbildung als
Kanaltabellen-Eintrag nehmen, der Interleaver seine Parameter `(K, a)` ebenso; dann sind beide
Raten Tabellenzeilen. `05` legt das heute anders fest: `05 §3.2.3` führt die Raten nur als
Dokumentationstabelle und schreibt für Rate 2/3 die behaltenen Positionen `{0, 1, 4}` als
„verbindliche Formulierung" fest, `05 §3.3` nennt die Interleaver-Parameter ausdrücklich
„**nicht** aus einer Tabelle", und `05 §2.4` bietet nur ein festes Kanal-`enum`. Die
Umstellung ist damit Teil der Vorsorge und gehört als Änderung nach `05` (O-18-8) — sie ist
dort nicht bereits vorhanden. Ebenso bleibt die Decodierung des
Zugriffszuweisungskanals hinter der Schnittstelle aus `05 §2.4` austauschbar, falls je ein
Betriebsfall entsteht, der sie im Empfangspfad braucht. Der Abnahmetest für diese Vorsorge
ist konkret: eine zusätzliche Tabellenzeile mit den TCH/4,8-Parametern muss ohne
Codeänderung den Testvektor erfüllen.

#### 3.1.10 Nicht-kontinuierliche Burstformate

**Was fehlt.** Die diskontinuierlichen Downlink-Bursts (492 bit = 246 Symbole plus
Schutzzeit, [ETSI Tabelle 9.10] normal, [ETSI Tabelle 9.12] Synchronisation) sind in Stufe 1
nicht gebaut (`02 §3.8`).

**Vorsorge in Stufe 1 (R-18-09).** Der Feldextraktor und der Burst-Aufbau leiten ihre
Symbolpositionen aus **einer** Feldtabelle je Format ab; das zweite Format ist eine zweite
Tabelle. Damit kostet die Nachrüstung keine Logikänderung. Diese Vorsorge hat einen
zusätzlichen Nutzen, der in V1 fehlte: der Referenzdecoder in `scripts/` und die Testbench
lesen dieselbe Tabelle wie das RTL. In V1 weichen die Offsets des diskontinuierlichen
Synchronisations-Layouts im Python-Decoder von der Norm ab (`02` O-02-9), und niemand hat es
bemerkt, weil die Gold-Zelle das kontinuierliche Format sendet.

### 3.2 Gruppe B — Verbesserung der Empfangsgüte

#### 3.2.1 Ausgangslage und was daran gemessen ist

**Der Grundpegel.** Der Roh-Bitfehleranteil im Sprachburst-Pfad liegt bei 1,4–1,8 %,
tagesabhängig bis 3,5 %, und ist **nicht** randkonzentriert: 330 von 432 Bitpositionen (76 %)
waren über mehrere Läufe mindestens einmal gekippt, BKN1 und BKN2 quasi gleichverteilt
(51/49) [MESS 2026-05-17]. Zum Vergleich fordert ETSI für die ungeschützten Bits 0,01 %
(statischer Kanal) bzw. 0,4 % (TU50) bei −85 dBm [ETSI Tabelle 6.28] — ein bis zwei
Größenordnungen unter dem Ist-Wert.

**Das Muster.** Das Fehlerhistogramm über acht Eimer von je 27 Bits zeigt in **beiden**
Blöcken den Anfang deutlich fehlerärmer als Mitte und Ende [MESS 2026-05-17]:

```
BKN1:  125  129  161  210  200  246  226  212
BKN2:  139  130  183  219  205  233  192  155
```

Das ist das Bild akkumulierter Phasendrift: jedes Symbol erbt das Phasenrauschen seines
Vorgängers, weil die Referenz bei differentieller Detektion das Nachbarsymbol ist. Ein
Basis-Sample-Offset ist ausgeschlossen, weil die Messung überhaupt nur bei erfolgreichem
Decode entsteht (`03 §3.6.2`); Blockspezifik ist durch die Gleichverteilung ausgeschlossen.

**Was schon geholfen hat, als Maßstab für alles Weitere.** Zwei Eingriffe sind gemessen und
in Stufe 1 enthalten:

| Eingriff | Ergebnis | Beleg |
|---|---|---|
| Weiche Entscheidungen im Sprachburst-Pfad statt harter Bits | Fehlerhaft-Rahmen-Anteil Median 6 % → 3 %, in **jedem** von 4 Läufen besser, im 320-Burst-Dauerlauf 7 % → 1 % | [MESS 2026-05-18] |
| Verstärkung der Dezimationskette ×64 → ×16, Uplink-Zugriffsschwelle 15 | Prüfsummen-Erfolg im Uplink 27 % → 93 % | [MESS 2026-05-22] |
| Amplituden-Normierung der weichen Werte im Steuerburst-Pfad | Amplituden-Cliff beseitigt; pegelunabhängig über den Sweep | [SIM 2026-05-30], an der Luft 3/3 Sprechtasten sauber [MESS 2026-05-30] |

Der Vergleich ist der eigentliche Inhalt dieses Abschnitts: der größte gemessene Gewinn kam
**nicht** aus einem neuen Algorithmus, sondern aus dem Arbeitspunkt der bestehenden Kette.
Wer eine Empfangsverbesserung beginnt, ohne den Arbeitspunkt geprüft zu haben, arbeitet am
falschen Ende.

#### 3.2.2 Die Stufen mit ihrer Bewertung

| # | Stufe | Erwarteter Gewinn | Ressourcen | Auf dem heutigen Baustein? | Evidenz |
|---|---|---|---|---|---|
| 1 | Amplituden-Normierung auch im Sprachburst-Pfad | nicht vorhergesagt; beseitigt Pegelabhängigkeit | Normierer existiert; ≈ 0 zusätzlich | **ja, Stufe 1** (`03` R-03-06) | [SIM 2026-05-30]; `12` O-12-4 |
| 2 | Magnitude-gewichtete Korrelation im Sprachburst-Zweig | gibt einen Einstellbereich zurück, rettet Bursts mit einem gekippten Dibit | ≈ 100 LUT [ANNAHME] | **ja, Stufe 1 empfohlen** (`03` O-03-5) | `03 §4`: Schwelle 11 von 11 = nur exakte Übereinstimmung |
| 3 | Bruchteil-Symboltiming im Uplink | 0,3–0,5 dB [ANNAHME — Herleitung, keine Messung] | ≈ 500–1 000 LUT, 1–2 DSP [ANNAHME] | ja | Restfehler heute ¼ Symbol = Sample-Raster bei 72 kHz (`03 §2.1` Punkt 3, `03 §3.3`) |
| 4 | Phasenverfolgende Demodulation | ≈ 1 dB [ANNAHME — adressiert genau das gemessene Eimer-Muster] | ≈ 1 000–2 000 LUT, 1–2 DSP [ANNAHME] | ja | §3.2.3 |
| 5 | Kohärente Demodulation mit Kanalschätzung | ≈ 1,5–2 dB und nur oberhalb ≈ 7 dB Signal-Rausch-Abstand; darunter gleich oder schlechter [SIM 2026-06-18 — Offline-Monte-Carlo auf echtem Mitschnitt `build/rx_iq_x16.csv`, Auswerteskript nicht erhalten] | ≈ 3 000–5 000 LUT, 2–4 DSP [ANNAHME] | ja, aber Nutzen fraglich | §3.2.4 |
| 6 | Zusammenführung mehrerer Empfangszweige | bis 3 dB in schwundbehafteten Kanälen [ANNAHME] | 2 576 LUT / 2 206 FF / 2 DSP je Frontend [BUILD 2026-06-20 cur_hier_deep.rpt:165 — Kosten der **bestehenden** Instanz `u_rx_frontend`; die Übertragung auf eine zweite Instanz ist [ANNAHME]], plus Zusammenführung | **nein — Plattformwechsel** | §3.2.5 |
| 7 | Weiche Werte mit 8 statt 4 bit | 0,2 dB [ANNAHME] | ≈ 0 im RTL; 108 statt 54 Registerlesungen je Burst | **ja, Stufe 1** (`03 §3.7`, 8 bit ist gesetzt) | `07 §3.4` |

**Reihenfolge-Regel.** Die Stufen 1, 2 und 7 sind in Stufe 1 enthalten oder empfohlen. Damit
gilt: **das Eimer-Histogramm aus §3.2.1 ist als Ausgangsmessung nicht mehr gültig**, sobald
Stufe 1 gebaut ist. Vor Stufe 3, 4 oder 5 wird es auf dem dann laufenden Soft-Pfad neu
gemessen [MESS 2026-05-18 als Ausgangswert, ausdrücklich als überholt markiert].

#### 3.2.3 Phasenverfolgende Demodulation

**Was sie tut.** Sie schätzt eine Rest-Rotation pro Symbol und rechnet sie auf die
Differenzphase zurück. Sie adressiert damit genau das gemessene Eimer-Muster und nicht ein
vermutetes Problem.

**Warum sie nicht die kohärente Variante ist.** Sie behält die differentielle Detektion und
damit die Toleranz gegen Frequenzfehler: bei den von der Norm erlaubten ±100 Hz
[ETSI §7.8 a)] beträgt die zusätzliche Drehung zwischen zwei Symbolen 34,9 mrad = 2,00 °
gegenüber einer Entscheidungsgrenze von π/4 = 785 mrad, also 4,4 % [ANNAHME: Rechnung,
`03 §3.3.5`]. Ein kohärenter Empfänger dagegen sammelt über einen Sprachburst von
231 Symbolen 8,06 rad absoluten Phasenfehler und braucht zwingend eine
Frequenzfehler-Schätzung.

**Betroffene Kapitel.** `03_PHY_UL_RX` (der Zweig), `01_PLATFORM §3.9` (Budget).

**Vorsorge in Stufe 1.** Der Sprachburst-Erfassungspfad gibt die weichen Werte mit ihrer
Amplitudennormierung und einem je Burst lesbaren Arbeitspunkt aus (`07 §3.4`, `W2.sym_norm`,
8.8-Festkomma). Das ist die Messgröße, an der die Wirkung eines Phasenverfolgers sichtbar
wird, und sie muss vorhanden sein, **bevor** man ihn baut. Zusätzlich: die
Symbolphase des gewinnenden Korrelationsergebnisses steht als `W2.best_phase` je Burst
bereit — ohne sie ist keine Aussage darüber möglich, ob die Drift symbol- oder
phasengebunden ist.

#### 3.2.4 Kohärente Demodulation mit Kanalschätzung

**Der Stand ist eine Auswertung auf echten Daten, nicht eine Erwartung — aber auch keine
Hardware-Messung.** Der Mitschnitt ist echt (`build/rx_iq_x16.csv`, 8 192 Abtastwerte aus der
eigenen Empfangskette, Sprachburst bei Symbol 985, Frequenzfehler −5 Hz); die Bewertung ist
Simulation: Rauschen synthetisch aufgeprägt, Signal-Rausch-Abstand 15,5 dB, Monte-Carlo,
kohärenter Detektor nur im Auswerteskript, nie auf der Zielhardware gelaufen. Ergebnis: die
entscheidungsgeführte kohärente Detektion liegt gegenüber der differentiellen bei
**≈ 1,5–2 dB**, und nur oberhalb von etwa 7 dB Signal-Rausch-Abstand. Unterhalb — also in
genau den tiefen Einbrüchen, die die fehlerhaften Rahmen verursachen — war sie gleich gut oder
schlechter [SIM 2026-06-18 — Offline-Monte-Carlo auf echtem Mitschnitt `build/rx_iq_x16.csv`,
Auswerteskript nicht erhalten].

**Der wichtigere Teil derselben Messung — ein negatives Ergebnis, das Aufwand spart.** Ein
naiver Pilot-Korrelator auf der Trainingsfolge **scheitert** am langen Burst: der
Steigungsfehler der Frequenzschätzung aus 11 Trainingssymbolen, über ±110 Symbole
extrapoliert, erzeugt einen Fehlerboden von etwa 5 %. Es braucht ein
**entscheidungsgeführtes Phasen-Regelkreis-Verfahren mit Rückkopplung je Symbol**, nicht eine
einfache Derotation aus der Korrelation [SIM 2026-06-18 — derselbe Offline-Lauf].

**Konsequenz für V2.** Die kohärente Stufe ist **nicht** die naheliegende nächste Stufe. Sie
kostet drei- bis fünfmal so viel Logik wie der Phasenverfolger, bringt nach der Auswertung
von 2026-06-18 [SIM] weniger als
die Hälfte des früher erwarteten Gewinns und wirkt nicht dort, wo die fehlerhaften Rahmen
entstehen. Reihenfolge deshalb: erst Stufe 1–4 aus §3.2.2, dann eine neue Messung, dann
Entscheidung.

**Vorsorge in Stufe 1.** Nur eine, und sie steht bereits als R-18-12 im Kapitel: die
Roh-Empfangsdaten-Aufzeichnung (§3.4). Ohne sie ist die obige Messung nicht wiederholbar,
und ohne Wiederholung auf einem **schwachen** Mitschnitt ist die Frage „rettet kohärente
Detektion fehlerhafte Rahmen?" nicht beantwortbar. Das ist die offene Frage dieses Eintrags
(§6).

#### 3.2.5 Zusammenführung mehrerer Empfangszweige — plattformgebunden

**Was sie wäre.** Ein zweiter Empfangszweig auf einer zweiten Antenne, zusammengeführt
entweder durch Auswahl des besseren Zweigs oder durch gewichtete Summe der weichen Werte
nach Zweigbetrag. In schwundbehafteten Kanälen ist Diversität zweiter Ordnung der größte
Einzelhebel — die beobachtete Schwankung des Fehlerhaft-Rahmen-Anteils zwischen 3 % und
15–16 % über Läufe [MESS 2026-05-20] ist genau die Signatur, gegen die Diversität wirkt.

**Warum sie an einen Plattformwechsel gebunden ist.** `01 §3.10` entscheidet das für V2:
„MRC/Diversity braucht eine andere Plattform-Klasse". Die Begründung in Zahlen:

| Posten | Wert | Beleg |
|---|---:|---|
| Ein zusätzliches Empfangs-Frontend (Dezimation + Empfangsfilter) | 2 576 LUT, 2 206 FF, 2 DSP | [BUILD 2026-06-20 build/reports/cur_hier_deep.rpt:165 — Kosten der **bestehenden** Instanz `u_rx_frontend` in einem Bau **ohne** zweiten Zweig; die Übertragung auf eine zweite Instanz ist [ANNAHME]. Der Bau mit zweitem Frontend von 2026-05-29 liefert nur Gesamtwerte, keinen instanzbezogenen Zuwachs] |
| Zusammenführungsstufe und zweiter Korrelatorsatz | ≈ 5 000–10 000 LUT | [ANNAHME — V1-Bewertung, nicht gebaut] |
| V1-Gesamtbelegung | 37 567 LUT von 53 200 | [BUILD 2026-07-12 build/reports/impl_utilization.rpt §1] |
| V2-Budget | ≤ 42 000 LUT, WNS ≥ +0,250 ns | `01 §3.9` |
| WNS des V1-Baus mit zweitem Frontend | +0,008 ns | [BUILD 2026-05-29 — Vivado-Lauf zum später verworfenen Zweig-2-Bau; Reportdatei nicht im Repository erhalten] |

Die Deutung ist wichtiger als die Summe: das **zweite Frontend allein** hat in V1 geroutet und
das Timing nicht verschlechtert. Was nicht passt, ist die Zusammenführungsstufe **zusätzlich
zu** den Stufen 3–5 aus §3.2.2, bei gleichzeitigem Einhalten der WNS-Reserve aus `01 §3.9`.
Wer daraus „das zweite Frontend geht nicht" macht, hat die Messung falsch gelesen.

**Was V1 dazu beitragen kann: nichts über den Gewinn.** Der Zweig-2-Bau lief, aber es kamen
keine Abtastwerte in der Logik an: die Netze des zweiten Wandlerkanals waren im Block-Design
**unverbunden**, weil das Werkzeug aus den neuen Ports eine Schnittstellenverbindung
inferierte und die einzeln gesetzten Netze verwarf — mit einer ausdrücklichen Warnung, die
als harmlos abgetan wurde [MESS 2026-05-29]. Der Zweig wurde daraufhin gestrichen und alle
zugehörigen Änderungen zurückgenommen. **Es existiert deshalb keine Messung des
Diversitätsgewinns auf dieser Plattform.** Das ist der Grund, warum dieser Eintrag mit einer
Messpflicht beginnt und nicht mit einem Entwurf.

**Vorsorge in Stufe 1.**

1. **`W2[31:24]` der UL-Burst-Mailbox bleibt frei** (§2.3) und nimmt später Zweigkennung und
   Zweigpegel auf. Ohne dieses Feld ist eine Zusammenführung nicht diagnostizierbar.
2. **Der Abzweigpunkt der Roh-Aufzeichnung (§3.4) liegt am Ausgang des Empfangs-Frontends**,
   nicht weiter hinten. Ein zweiter Zweig bekommt einen zweiten Abzweig an derselben Stelle;
   damit ist die Messung „Auswahl gegen gewichtete Summe" offline auf beiden Zweigen
   durchführbar, bevor eine Zusammenführungslogik existiert.
3. **Was Stufe 1 lassen muss:** kein Bau einer Zusammenführungslogik, kein zweiter
   Korrelatorsatz und keine Verdrahtung eines zweiten Wandlerkanals „auf Vorrat". Der
   Vorratsbau kostet in der Größenordnung der bestehenden Frontend-Instanz — 2 576 LUT und
   2 206 FF [BUILD 2026-06-20 cur_hier_deep.rpt:165, Übertragung auf eine zweite Instanz
   [ANNAHME]] —, verbraucht die WNS-Reserve und liefert ohne Zusammenführung keinen Nutzen.
4. **Für den Fall des Plattformwechsels:** der Eingangsvertrag der Uplink-PHY
   (`fe_i_sys`/`fe_q_sys`/`fe_valid_sys`, je 16 bit signed bzw. 1 bit Strobe bei 72 kHz,
   `03 §3.1`) ist die einzige Stelle, an der ein zweiter Zweig andockt. Sie bleibt frei von Annahmen über
   „genau eine Instanz" — insbesondere führt kein Modul einen eigenen Phasenzähler, der nur
   deshalb zum Frontend passt, weil beide denselben Reset sehen (`03` O-03-8 verlangt das
   ohnehin).

### 3.3 Gruppe C — Sprachpfad-Erweiterungen, die einen echten Codec brauchen

#### 3.3.1 Die gemeinsame Vorbedingung

`12` R-12-02 entscheidet, dass die Basisstation **keinen** Analyse-/Synthese-Sprachcodec
enthält: sie arbeitet auf den 274 Parameter-Bits je Burst und leitet sie weiter, ohne sie in
Abtastwerte zu wandeln. Für eine Vermittlung zwischen Endgeräten desselben Netzes ist das
vollständig — jede Wandlung wäre zusätzliche Verzerrung, Laufzeit und Rechenlast ohne
Funktionsgewinn. **Vier Funktionen brauchen ihn trotzdem.** Sie stehen gemeinsam hier, weil
sie **dieselbe** Vorbedingung haben und ein einmal gebauter Codec allen vier dient.

| Funktion | Warum ohne Codec unmöglich |
|---|---|
| **Sprachaufzeichnung** | Eine Aufzeichnung der Parameter-Bits ist ohne Synthese nicht abspielbar und nicht in ein gängiges Audioformat überführbar. Eine Aufzeichnung, die niemand abspielen kann, ist keine. |
| **Ansagen** | Eine von der Basisstation erzeugte Sprachaussendung entsteht aus Abtastwerten und braucht die **Analyse**-Richtung, um Parameter-Bits zu erzeugen. Vorberechnete Parameter-Bits sind eine Teillösung für feste Texte, aber keine für konfigurierbare Ansagen. |
| **Konferenzmischung** | Mischen ist eine Addition von Abtastwerten. Parameter-Bits zweier Sprecher lassen sich nicht addieren. Es braucht Synthese beider Quellen, Mischung, erneute Analyse. |
| **Verbindung zu einem leitungsvermittelten Netz** | Das Gegennetz spricht Abtastwerte (bzw. eine andere Codierung). Die Umsetzung ist beidseitig: Synthese in Richtung Gegennetz, Analyse in Richtung Funkschnittstelle. |

#### 3.3.2 Ressourcenbedarf und die Messpflicht (R-18-11)

**Was gemessen ist.** Die Kanalcodierkette des Sprachkanals — Descrambling,
Deinterleaving, Depunktierung, Viterbi über 184 Stufen, Prüffeld, Rückordnung, dann
Rückcodierung — kostet auf einem Entwicklungsrechner 9,32 µs je weitergeleitetem Rahmen
[SIM 2026-07-25, `12 §3.9`]. Auf dem Zielprozessor bilanziert `12 §3.9` daraus ≈ 129 µs je
Burst und Kanal und ≈ 0,7 % eines Kerns bei drei Sprachkanälen — mit einem angenommenen
Skalierungsfaktor 10–12 [ANNAHME].

**Was nicht gemessen ist — und die Größenordnung ist eine andere.** Ein
Analyse-/Synthese-Codec ist der einzige Sprachpfad-Baustein, dessen Rechenlast auf dem
Zielprozessor kritisch werden kann; `12 §3.2.4` sagt das ausdrücklich. Es gibt in V1 **keine**
Messung dazu, weil V1 den Codec nie enthielt: `sw/etsi_codec/source.h` deklariert die
Quellcodier-Funktionen, aber keine ist implementiert und keine wird aufgerufen
[CODE sw/etsi_codec/source.h:91-116], [CODE sw/Makefile:39-41]. V1 ist bereits
transcoderfrei — als Zufall, den V2 zur Entscheidung macht.

**Deshalb R-18-11, als harte Vorbedingung:** vor dem Bau einer der vier Funktionen wird die
Rechenlast der Analyse- **und** der Synthese-Richtung auf dem Zielprozessor gemessen,
Perzentile 50 und 99 über mindestens 60 s Sprechzeit, je Sprachkanal. Erst diese Messung
entscheidet, wie viele gleichzeitige Kanäle eine Funktion tragen kann. Eine Rechnung mit
Skalierungsfaktor ist dafür nicht zulässig — sie ist [ANNAHME], und `08` O-08-7 weist die
vorhandene indirekte Evidenz ausdrücklich als schwächer aus als früher angenommen: die
91,7 % Prozessor-Leerlauf sind **ohne** dokumentierten aktiven Sprachruf gemessen
[MESS 2026-05-20].

#### 3.3.3 Vorsorge in Stufe 1 für alle vier Funktionen

1. **Die Parameter-Bits sind an einer Schnittstelle greifbar (R-18-10).** Der Sprachpfad
   legt die 274 Parameter-Bits je Burst an der Modulschnittstelle aus `12 §3.2.3` offen. Alle
   vier Funktionen hängen sich dort ein — die Aufzeichnung als zweiter Verbraucher, die
   Ansage als zweiter Erzeuger, die Mischung als beides. Ohne diese Schnittstelle wäre jede
   der vier ein Eingriff in die Weiterleitungskette, und die Kette ist der einzige
   air-verifizierte Teil.
2. **Die Weiterleitung bleibt bit-transparent auf der Parameterebene.** Stufe 1 decodiert und
   codiert die **Kanal**codierung neu (damit Uplink-Bitfehler nicht in den Downlink
   wandern), verändert aber die Parameter-Bits nicht. Damit ist ein späterer Codec eine
   Erweiterung, keine Ersetzung.
3. **Die Diagnose-Doppeldecodierung bleibt hinter einem Schalter.** V1 decodiert jeden Burst
   zweimal, hart und weich, für einen Dauervergleich [CODE sw/tetra_voice_pipe.c:170-174] —
   das verdoppelt den teuersten Posten. `12 §3.9` verlegt das hinter einen Schalter. Das ist
   auch Roadmap-Vorsorge: die Reserve, die ein Codec braucht, ist genau die Reserve, die eine
   Dauerdiagnose verbraucht.
4. **Was Stufe 1 lassen muss:** keine Abtastwert-Schnittstelle „auf Vorrat", keine
   Zwischenpuffer für Audio, keine Abhängigkeit der Rufsteuerung von einer Audioquelle. Eine
   halb gebaute Audioseite ohne Codec ist toter Code, und `00 §1.1` benennt, was toter Code
   in V1 angerichtet hat.
5. **Ansagen als Teillösung sind erlaubt, aber nicht als Vorgriff.** Vorberechnete
   Parameter-Bit-Folgen für feste Texte brauchen keinen Codec zur Laufzeit und passen in die
   Erzeugerseite aus Punkt 1. Sie sind eine eigenständige, kleine Funktion — sie dürfen aber
   nicht als „Ansagen erledigt" verbucht werden, weil konfigurierbare Ansagen die
   Analyse-Richtung brauchen.

### 3.4 Arbeitsmittel — Aufzeichnung von Roh-Empfangsdaten aus dem laufenden System

**Was es ist und warum es hierher gehört.** Ein Ringpuffer, der den Ausgang der **eigenen**
Empfangskette mitschneidet und über das Registerfenster auslesbar macht. Es ist kein
Produktmerkmal, sondern die einzige gültige Grundlage, um die eigene Empfangskette zu
bewerten. Ein Mitschnitt mit einem fremden Empfänger sagt nichts über **diese** Kette aus —
das ist die Begründung, mit der V1 den Puffer eingeführt hat
[CODE rtl/rx/tetra_rx_iq_capture.v:6-9], und sie gilt unverändert.

Es steht in diesem Kapitel, weil **jeder Eintrag der Gruppe B** davon abhängt: die Messung
aus §3.2.4 ist auf einem so gezogenen Mitschnitt entstanden (`build/rx_iq_x16.csv`), und
R-18-13 verlangt für jeden Eintrag eine Messung.

**Aufbau in V1, als Vorlage.**

| Eigenschaft | Wert | Beleg |
|---|---|---|
| Abzweigpunkt | Ausgang des Empfangs-Frontends, nach Dezimation und Empfangsfilter, 72 kHz | [CODE rtl/tetra_zynq_top.v:663-669], [CODE rtl/rx/tetra_rx_chain.v:218-220] |
| Wortbreite | 32 bit = `{I[15:0], Q[15:0]}` | [CODE rtl/rx/tetra_rx_iq_capture.v:83] |
| Tiefe | 8 192 Abtastwerte = 113,8 ms ≈ 8 Zeitschlitze | [CODE rtl/tetra_zynq_top.v:663] |
| Betriebsart | freilaufender Ringpuffer; Software friert ein, liest den Schreibzeiger, entleert, gibt frei | [CODE rtl/rx/tetra_rx_iq_capture.v:11-14] |
| Taktbereichs-Übergang | Zweitor-Blockspeicher trägt die Daten; Einfrier-Signal über 2-FF, Schreibzeiger nur im eingefrorenen Zustand gültig | [CODE rtl/rx/tetra_rx_iq_capture.v:16-19, 91-93] |
| Ressourcen | 25 LUT, 41 FF, 8 RAMB36 | [BUILD 2026-06-20 build/reports/cur_hier_deep.rpt:175] |
| Auslese-Werkzeug | ein Skript, das die Entleerung **auf dem Board** in einer Sitzung ausführt und chronologisch ab dem Schreibzeiger ausgibt | [CODE scripts/capture_rx_iq.sh] |

**Was Stufe 1 vorsehen muss (R-18-12):**

1. **Der Puffer ist Teil des Stufe-1-Baus, nicht optional.** 8 RAMB36 von 140 Tiles
   [Datenblatt-Konstante], gegen ein V2-Budget von ≤ 40 Tiles (`01 §3.9`) — der Platz ist
   vorhanden. 25 LUT sind gegenüber jeder Alternative vernachlässigbar.
2. **Der Abzweig liegt am Frontend-Ausgang, nicht am Demodulator.** Alles, was hinter dem
   Frontend liegt — Synchronisation, Erfassung, weiche Werte — ist Gegenstand der
   Verbesserungen aus Gruppe B. Ein Abzweig dahinter kann sie nicht bewerten.
3. **Die Tiefe deckt mindestens zwei Uplink-Zeitschlitze desselben Zeitschlitzindex ab.**
   8 192 Abtastwerte = 8,03 Zeitschlitze [ANNAHME: Rechnung, 8 192/72 000 s gegen 85/6 ms]
   erfüllen das mit Reserve und fassen zwei aufeinanderfolgende Bursts desselben Sprechers.
4. **Der Auslese-Weg läuft in einer Sitzung auf dem Board.** Ein Registerzugriff je Wort über
   das Netz ist für 8 192 Wörter unbrauchbar; V1 löst das durch eine Schleife auf dem Board
   [CODE scripts/capture_rx_iq.sh]. Diese Eigenschaft gehört in die Spezifikation, nicht in
   den Zufall eines Skripts.
5. **Ein zweiter Abzweigpunkt ist strukturell vorgesehen** (§3.2.5 Punkt 2), aber in Stufe 1
   nicht instanziiert.
6. **Der Puffer ist keine Debug-Instrumentierung im verbotenen Sinn.** `CONVENTIONS §6`
   Punkt 3 verbietet Logic-Analyzer-Cores im FPGA als Verifikationsmethode und lässt
   „Simulation, AXI-Zähler, Logs und Luft-Captures" zu — der Ringpuffer liefert genau ein
   Luft-Capture über AXI und fällt damit unter die zugelassenen Mittel. Die weitergehende
   Abgrenzung „Registerfenster mit Blockspeicher im Produktionsbau ≠ zur Übersetzungszeit
   eingefügter Logikanalysator" ist eine Festlegung **dieses** Kapitels [ANNAHME — kein
   Zitat aus `CONVENTIONS`], damit der Puffer nicht irrtümlich als verbotenes Mittel
   gestrichen wird.

**Grenze dieses Arbeitsmittels.** 113,8 ms reichen für Burst-Auswertungen, nicht für
Mitschnitte über mehrere Sekunden und nicht für zwei Zweige gleichzeitig (Voraussetzung für
§3.2.5). Dafür bräuchte es einen Massendatenpfad in den Hauptspeicher, den V2 bewusst
entfernt (`01 §2.2`, `01 §3.10`). Behandlung: O-18-7.

### 3.5 Kapazitäts- und Skalierungsgrenzen der Stufe 1

Diese Posten sind keine fehlenden Funktionen, sondern bewusst gesetzte Größen. Sie stehen
hier, weil ihre Überschreitung eine Strukturänderung wäre und Stufe 1 die Messgröße dafür
mitbringen muss.

| Größe | Stufe-1-Wert | Struktur | Messgröße | Was bei Überschreitung nötig wird |
|---|---:|---|---|---|
| Teilnehmer und Gruppen | 1024 je Typ | linearer Durchlauf, `O(N)`; V2-Wert festgelegt in `13 §4` (V1: 256, Erbe der entfallenen PL-Tabelle, `13 §3.8`) | `db_full_cnt` | eine Nachschlagestruktur mit Streuwerten; rein Software |
| Berechtigungsprofile | 6 | Feld [ANNAHME — kein V2-Kapitel legt die Zahl fest; übernommen aus V1 `TETRA_DB_MAX_PROFILES` [CODE sw/tetra_db.h:30]; Profilinhalt in `09 §3.6`, Konfigurationsschlüssel `PROFILE_n_*` in `13 §3.7`] | — | Feldgröße |
| Sicherungsschicht-Verbindungen | 64 Plätze | `09 §2.3` | `llc_link_evict` | Größe erhöhen; `09` O-09-2 |
| Zusammensetz-Kontexte | 4 | `11 §3.11` | `reass_evict_cnt` | Größe erhöhen; `11` O-11-3 |
| Gleichzeitige Sprachkanäle | 3 (TS2…TS4) | physikalische Grenze eines Trägers | — | ein zweiter Träger — anderer Entwurf, nicht diese Roadmap |
| Gruppen-Datensätze je Anforderung | 8 | `09` O-09-3 | Ablehnungszähler | Fragmentierung der Quittung |

**Vorsorge in Stufe 1.** Alle sechs Größen sind benannte Konstanten an genau einer Stelle,
und jede hat ihren Zähler aus §2.4. Keine davon darf implizit in einer Schleifengrenze oder
einer Feldbreite auftauchen.

---

## 4. Empirische Werte

Alle Werte dieses Kapitels, die eine Roadmap-Entscheidung tragen. Werte, die zu einer
Stufe-1-Funktion gehören, stehen in deren Kapitel und werden hier nicht wiederholt.

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| Roh-Bitfehleranteil Sprachburst | 1,4–1,8 %, tagesabhängig bis 3,5 % | [MESS 2026-05-17] | Bezugswert für Gruppe B. Wer ihn nicht neu misst, bewertet Verbesserungen gegen eine überholte Basis |
| Verteilung der Bitfehler | 76 % der 432 Positionen mindestens einmal gekippt; BKN1/BKN2 51/49 | [MESS 2026-05-17] | Schließt Sample-Offset und Blockspezifik als Ursache aus. Wer sie erneut vermutet, sucht am falschen Ort |
| Eimer-Histogramm (8 × 27 bit) | s. §3.2.1 | [MESS 2026-05-17] | Begründet den Phasenverfolger. **Nach dem Bau von Stufe 1 ungültig** |
| ETSI-Sollwert ungeschützte Bits | 0,01 % statisch / 0,4 % TU50 bei −85 dBm | [ETSI Tabelle 6.28] | Zielgröße, heute um 1–2 Größenordnungen verfehlt |
| Gewinn weiche Entscheidungen | Fehlerhaft-Rahmen 6 % → 3 % (Median 4 Läufe); 7 % → 1 % im 320-Burst-Dauerlauf | [MESS 2026-05-18] | In Stufe 1 enthalten; Maßstab für jede weitere Stufe |
| Gewinn Arbeitspunkt Dezimationskette | Prüfsummen-Erfolg 27 % → 93 % | [MESS 2026-05-22] | Größter gemessener Einzelgewinn. Vor jedem Algorithmus den Arbeitspunkt prüfen |
| Gewinn kohärente Detektion | ≈ 1,5–2 dB, **nur** oberhalb ≈ 7 dB Signal-Rausch-Abstand | [SIM 2026-06-18 — Offline-Monte-Carlo auf echtem Mitschnitt `build/rx_iq_x16.csv`, Auswerteskript nicht erhalten] | Frühere Erwartung 3–4 dB war zu optimistisch. Reihenfolge in §3.2.2 folgt dieser Auswertung; eine Hardware-Messung fehlt (O-18-2) |
| Fehlerboden naiver Pilot-Korrelator | ≈ 5 % | [SIM 2026-06-18 — derselbe Offline-Lauf] | Ein einfacher Korrelator-Derotator ist kein gangbarer Weg; es braucht Rückkopplung je Symbol |
| Schwankung Fehlerhaft-Rahmen über Läufe | 3 % … 15–16 % | [MESS 2026-05-20] | Signatur von Schwund; begründet den Diversitäts-Eintrag |
| Zusätzliches Empfangs-Frontend | 2 576 LUT, 2 206 FF, 2 DSP | [BUILD 2026-06-20 cur_hier_deep.rpt:165] | Härtester Ressourcenwert der Gruppe B |
| Zusätzlicher Korrelationszweig (NTS2-Zweig — **Stufe 1** nach `06 §3.3.2`, Budget `01 §3.9`) | 145–185 LUT, 229–265 FF, 4 DSP (0 DSP mit gemeinsamer Dibit-Quelle) | [BUILD 2026-06-20 cur_hier_deep.rpt:173-174] | Kostet nur mit `03` O-03-3 keine DSP |
| Roh-Aufzeichnungspuffer | 25 LUT, 41 FF, 8 RAMB36; 8 192 Werte = 113,8 ms | [BUILD 2026-06-20 cur_hier_deep.rpt:175], [CODE rtl/tetra_zynq_top.v:663] | Preis des Arbeitsmittels — im BRAM-Budget von 40 Tiles enthalten |
| WNS mit zweitem Frontend (V1) | +0,008 ns | [BUILD 2026-05-29, Report nicht erhalten] | Zweites Frontend allein degradiert das Timing nicht; die Zusammenführung ist der Engpass |
| Sprachverlust je voll gestohlenem Burst | 60 ms (2 × 30 ms) | `12 §3.1.2`; Referenzzelle verliert 30 ms [GOLD 2. Referenzaufnahme] | Preis der Stufe-1-Variante; Bedarfsmessung ist der Hörvergleich |
| Schlafdauer Energiespargruppen | 1 / 2 / 5 / 8 / 17 / 71 / 359 TDMA-Frames | [ETSI §23.7.6 Tab. 23.9] | EG7 = 359 Frames ≈ 20,3 s; erklärt, warum `delay_slots` dafür untauglich ist |
| `T.210` Rückkehr in den Schlafzyklus | 18 TDMA-Frames | [ETSI Anhang B.1] | Nach dem ersten Downlink-Element hört das Endgerät so lange durchgehend |
| `N.214` / `T.214` Stehl-Wiederholungen | 4 Aussendungen / 6 Uplink-Gelegenheiten | [ETSI Anhang B.2 / B.1] | Bestimmt, wie viele NTS2-Bursts eine einzige Freigabe erzeugt |
| Verkehrszeitschlitze für einen Vollduplex-Einzelruf | 2 | abgeleitet aus [ETSI Tab. 21.87] + [ETSI §23.1.3.1.1] | Höchstens ein Vollduplex-Ruf je Träger |
| Halbschlitz-Sprachcodierung | 137 bit → 216 type-3; Prüffeld 4 bit; Punktierung 8/17; Interleaver (216, 101); nur BKN2 | [ETSI §8.3.1.3.7], [CODE sw/etsi_codec/const.tab:44-45], [CODE sw/etsi_codec/arrays.tab:60-65] | Ohne diese Betriebsart kein Halb-Stehlen (`12` R-12-18) |
| Rechenlast Sprach-Kanalcodierkette | 9,32 µs je Rahmen (Entwicklungsrechner) | [SIM 2026-07-25] | Bezugsgröße; ein Analyse-/Synthese-Codec liegt Größenordnungen darüber und ist **nicht** gemessen |

---

## 5. Verifikation

Dieses Kapitel wird nicht durch gebaute Funktionen abgenommen, sondern dadurch, dass die
Vorsorge in Stufe 1 nachweisbar vorhanden ist. Alle Prüfungen laufen **in der
Stufe-1-Abnahme** mit.

### 5.1 Prüfung der reservierten Felder (R-18-02)

Ein Registertest je Zeile aus §2.3:

1. **a) Felder, die die Software erzeugt (PS → PL):** in jedes reservierte Bit eine 1
   schreiben, zurücklesen. Erwartung: 0, **oder** der Mailbox-Eintrag wird verworfen und der
   zugehörige Fehlerzähler steht auf 1. Betroffen: `W14[29]`, `W14[31:30]`, `W15` `pdu_class`,
   `REG_UL_ASSIGN_CFG[31:21]`, `W14[20:7]`, Zeitplan-Eintrag `[1:0]`.
   **b) Felder, die das PL erzeugt (PL → PS):** `W0[30:23]`, `W1[31:28]`, `W2[31:24]` liegen im
   nur lesbaren Datenfenster der UL-Burst-Mailbox (`REG_ULMB_DATA` RO, `07 §3.4`) — ein
   Schreibtest ist dort nicht möglich und ein „verworfener Eintrag" existiert nicht. Nachweis
   stattdessen: (i) Testbench über alle Burst-Typen, beide Bänke, beide Erzeuger und den
   Verwurf-Randfall (`after_drop`) — die drei Bereiche sind in **jedem** ausgelesenen Kopfwort
   0; (ii) die Software prüft sie beim Lesen und zählt eine Abweichung in
   `ulmb_resv_nonzero_cnt` (**(neu)** → `13 §3.10`), ohne den Burst zu verwerfen, damit eine
   spätere Belegung sichtbar wird statt Bursts zu kosten.
2. Für die Codepunkte (`burst_type = 10₂`, `pdu_class = 10₂/11₂`): Einspeisung eines
   synthetischen Uplink-Bursts in der Simulation über den benannten, simulationsexklusiven
   Einspeisepfad `ulmb_inject` (`07 §5.2`), der auch das Mailbox-**Kopfwort** setzt.
   Erwartung: definierter Verwurf mit Zähler, kein Fehlparse, kein Absturz, und **keine**
   Aussendung.
3. Der Test ist Teil des Registertest-Satzes und läuft in Simulation; er braucht keine
   Hardware.

**Abnahmekriterium:** alle Zeilen aus §2.3 erfüllt. Eine belegte Reservierung ohne
Spec-Änderung ist ein Fehlschlag, auch wenn die Belegung funktioniert.

### 5.2 Prüfung der Bedarfszähler (R-18-03)

Für jeden Zähler aus §2.4: er existiert, ist über `07` lesbar, erscheint im Betriebsstatus
(`13`) und zählt im Test einmal hoch. Der letzte Punkt ist der eigentliche: ein Zähler, der
nie hochgezählt wurde, ist nicht verifiziert. Je Zähler ein gezielter Stimulus —
`duplex_downgrade_cnt` über ein `U-SETUP` mit gesetztem Duplexbit,
`ul_burst_type_unsupported_cnt` über die Einspeisung aus §5.1 Punkt 2,
`energy_saving_req_cnt` über eine Anmeldung mit Energiespar-Element.

### 5.3 Prüfung der Tabellengetriebenheit (R-18-08, R-18-09)

Zwei konkrete Tests, die ohne die Roadmap-Funktion auskommen:

1. **Kanaltabelle:** Vorbedingung ist die Änderung an `05` aus R-18-08 / O-18-8 — solange
   `05 §2.4` ein festes Kanal-`enum` exportiert und `05 §3.3` die Parameter ausdrücklich
   „**nicht** aus einer Tabelle" bezieht, ist dieser Test nicht durchführbar und die Prüfung
   fällt auf „R-18-08 offen". Danach: eine zusätzliche Zeile mit den TCH/4,8-Parametern aus
   §3.1.9 (`t = 3`, `P = {1,2,5}`, `i = j + (j−1) div 65`, Rate 292/432) erzeugt **ohne
   Codeänderung** die Ausgabe des zugehörigen Testvektors. Der Testvektor wird aus der
   ETSI-Gleichung erzeugt, nicht aus der Implementierung.
2. **Burst-Geometrie:** RTL, Referenzdecoder und Testbench beziehen ihre Symbolpositionen
   aus einer gemeinsamen Quelle. Prüfung durch einen Generatorlauf und einen Vergleich aller
   drei Verbraucher; abweichende Offsets sind ein Fehlschlag. Dieser Test hätte in V1 die
   Abweichung des diskontinuierlichen Synchronisations-Layouts im Python-Decoder gefunden
   (`02` O-02-9).

### 5.4 Prüfung der Sprachpfad-Schnittstelle (R-18-10)

Ein zweiter Verbraucher liest die 274 Parameter-Bits je Burst an der Schnittstelle aus
`12 §3.2.3` mit; die Weiterleitung bleibt dabei **bit-identisch** zum Lauf ohne diesen
Verbraucher. Vergleich über einen aufgezeichneten Burst-Strom. Damit ist belegt, dass
Aufzeichnung, Ansage und Mischung später andocken können, ohne die air-verifizierte Kette zu
verändern.

### 5.5 Prüfung des Arbeitsmittels (R-18-12)

1. Das Werkzeug zieht 8 192 Abtastwerte aus dem laufenden System; die Ausgabe enthält
   Werte ungleich null, chronologisch ab dem Schreibzeiger geordnet.
2. Auf demselben Mitschnitt läuft der Referenzdecoder und findet dieselben Bursts, die die
   Logik erfasst hat — Abgleich über den Zeitstempel aus `07 §3.4` `W1`. Erst dieser Abgleich
   macht den Mitschnitt zur Messgrundlage; ein Mitschnitt, der nicht mit den erfassten
   Bursts zusammenpasst, taugt für keine Bewertung aus Gruppe B.
3. Der Einfrier-/Freigabe-Vorgang stört den laufenden Betrieb nicht: während und nach der
   Entleerung bleiben Fehlerhaft-Rahmen-Anteil und Prüfsummen-Erfolg unverändert.

### 5.6 Prüfung der Schnittwahrung (R-18-01)

Ein Review-Schritt, kein Test: für jeden Eintrag in §3 wird geprüft, dass seine Vorsorge
keine der in `00 §3.2` aufgezählten Hardware-Funktionen verschiebt. Der Eintrag §3.1.8
(Fensterverlängerung) ist der Grenzfall und darum ausdrücklich geprüft: er bleibt
hardware-lokal, weil er nur Burst-Erkennung und Position im Zeitraster benutzt — kein
Decoder-, Parser- oder Prüfsummenpfad, wie `07 §3.1.6` R-07-11 verlangt.

---

## 6. Offene Punkte

**O-18-1 — Das Duplexbit ist heute als Spiegel spezifiziert und muss auf 0 festgelegt
werden.** `10 §3.1.1`, §3.1.2 und §3.1.3 tragen „Simplex/Duplex — Spiegel". Bei einem
Endgerät, das Vollduplex anfragt, verspricht das Kombination 3 aus [ETSI §14.5.1.4.0], die
Stufe 1 nicht liefert. *Empfehlung:* R-18-04 in `10` als Festlegung nachziehen (hart `0`,
`duplex_downgrade_cnt`) und die Zeile in `10 §6` mit dem Verweis hierher versehen. Die
Änderung gehört zu `10`, nicht hierher; dieses Kapitel benennt nur den Anlass.

**O-18-2 — Rettet kohärente Detektion fehlerhafte Rahmen?** Die Offline-Auswertung aus §3.2.4
[SIM 2026-06-18] lief auf einem Mitschnitt mit 15,5 dB Signal-Rausch-Abstand und mit harten
Entscheidungen; eine Hardware-Messung des kohärenten Detektors existiert nicht. Die
entscheidende Frage — Verhalten auf einem **schwachen** Mitschnitt und im weichen Pfad — ist
offen. *Empfehlung:* Mit dem Arbeitsmittel aus §3.4 einen Mitschnitt an der Empfangsgrenze
ziehen (Fehlerhaft-Rahmen-Anteil im zweistelligen Bereich), dieselbe Auswertung wiederholen,
und zwar auf dem weichen Pfad. Fällt der Gewinn dort ebenfalls unter 7 dB weg, ist die
kohärente Stufe für dieses System kein Hebel und wird aus der Roadmap **gestrichen** — nicht
unbefristet mitgeführt. Das Auswerteskript des Laufs von 2026-06-18 ist nicht erhalten und
muss neu geschrieben werden; es gehört dann ins Verifikations-Werkzeug (`14`), nicht in ein
temporäres Verzeichnis.

**O-18-3 — Diversitätsgewinn auf dieser Plattform ist unbekannt.** Der V1-Versuch lieferte
keine Abtastwerte, weil die Netze des zweiten Wandlerkanals im Block-Design unverbunden
blieben [MESS 2026-05-29]. Es gibt daher keinen Messwert, gegen den die
Plattform-Entscheidung aus `01 §3.10` geprüft werden könnte. *Empfehlung:* Die
Entscheidung „Plattformwechsel" **stehen lassen** — sie ist gegen das Budget aus `01 §3.9`
begründet, nicht gegen die fehlende Messung. Vor einem Plattformwechsel jedoch zuerst die
Messung nachholen: zwei Zweige roh mitschneiden (braucht den Massendatenpfad aus §3.4,
letzter Absatz), Auswahl gegen gewichtete Summe offline quantifizieren. Ohne diese Zahl ist
ein Plattformwechsel eine Wette.

**O-18-4 — Ist die Halb-Stehl-Variante hörbar besser?** Der Unterschied ist 30 ms gegen 60 ms
Sprachverlust je gestohlenem Burst, bei einer Stehlrate, die `steal_override_cnt` erst
zeigen wird. *Empfehlung:* Hörvergleich im Air-Test, beide Varianten im selben Ruf,
`steal_override_cnt` als Bezugsgröße. Ist der Unterschied nicht hörbar, entfällt der Eintrag
und mit ihm die Halbschlitz-Sprachcodierung im Sendepfad — im Empfangspfad wird sie für
§3.1.3 Teil 2 dennoch gebraucht, sobald `ul_nts2_detect_cnt` anspricht.

**O-18-5 — Verschlüsselung und Authentisierung der Funkschnittstelle sind nicht
spezifiziert.** Stufe 1 lässt alle Felder mit Sicherheitsbezug leer und überspringt die
entsprechenden Elemente des Endgeräts über ihre Länge (`09` O-09-7, R-09-14). ETSI stellt die
Unterstützung frei und zeigt sie in den Geräteklassen-Angaben an [ETSI §19.4.7].
*Empfehlung:* Der Umfang wird hier **nicht** festgelegt. Er ist kein Roadmap-Eintrag im Sinne
dieses Kapitels, weil er nicht durch reservierte Bits vorbereitbar ist, sondern eine eigene
Fachspezifikation braucht. Die Vorsorge der Stufe 1 beschränkt sich darauf, dass der Wanderer
über die empfangenen Elemente unbekannte Elemente über ihre Länge überspringt statt
abzubrechen — genau das fordert R-09-14 schon.

**O-18-6 — Reihenfolge innerhalb der Gruppe B ist an eine Messung gebunden, die noch nicht
existiert.** §3.2.2 ordnet die Stufen, aber die Ordnung beruht auf dem Eimer-Histogramm von
2026-05-17, das nach dem Bau der Stufe-1-Verbesserungen ungültig ist. *Empfehlung:* Direkt
nach der Stufe-1-Abnahme das Histogramm auf dem dann laufenden weichen Pfad neu messen und
§3.2.2 danach einmal überarbeiten. Bleibt das Muster, ist der Phasenverfolger die nächste
Stufe; verschwindet es, ist es keine — und dann ist auch O-18-2 hinfällig.

**O-18-7 — Bleibt das Massendaten-Problem des Zwei-Zweig-Mitschnitts ungelöst, ist O-18-3
nicht beantwortbar.** Ein Zwei-Zweig-Mitschnitt über mehrere Sekunden passt nicht in einen
Blockspeicher-Ring, und der DMA-Pfad entfällt in V2 (`01 §2.2`). *Empfehlung:* Nicht
vorsorglich bauen. Wenn O-18-3 beauftragt wird, den Pfad neu spezifizieren — mit der in
`01` O-01-6 benannten Vorbedingung, dass die physische Speicherbestückung geklärt ist, bevor
die Logik den Hauptspeicher benutzt.

**O-18-8 — Die Kanalcodierung ist heute nicht tabellengetrieben, R-18-08 ist damit offen.**
`05 §2.4` exportiert ein festes `enum tetra_cc_chan_t` mit sechs Konstanten („logischer Kanal
— bestimmt alle Parameter"), und `05 §3.3` legt fest „Parameter je Kanal — direkt aus den
Kanalabschnitten, **nicht** aus einer Tabelle". Ein zusätzlicher Kanal (TCH/4,8, TCH/2,4 aus
§3.1.9; der Halbschlitz-Sprachblock aus §3.1.3) kostet damit eine Codeänderung, und der
Abnahmetest aus §5.3 Punkt 1 ist nicht durchführbar. *Empfehlung:* In `05` eine Kanaltabelle
mit `t`, `P[]`, `i`-Abbildung, Interleaver-Parametern `(K, a)` und Prüffeld-Variante
einführen, das `enum` auf einen Tabellenindex zurückführen und den Satz „nicht aus einer
Tabelle" in `05 §3.3` streichen. Die Änderung gehört zu `05`, nicht hierher; dieses Kapitel
benennt nur den Anlass und den Abnahmetest. Bis dahin gilt R-18-08 als **offen**, nicht als
bestehende Vorsorge.

**O-18-9 — `03` O-03-6 und `06 §3.3.2` widersprechen sich in der Stufenzuordnung des
NTS2-Zweigs.** `06 §3.3.2` fordert den zweiten Korrelatorzweig auf NTS2 samt eigenem
Trefferzähler `ul_nts2_detect_cnt` für **Stufe 1** („Uplink-Stehlen: Erkennung gebaut,
Auswertung Roadmap"); `03` O-03-6 schreibt für denselben Zweig „Umsetzung nach Stufe 1
(Kapitel 18)". Beides zugleich kann nicht gelten: ohne den Zweig in Stufe 1 kann der Zähler
aus §2.4 nichts zählen, und R-18-03 ist für §3.1.3 Teil 2 unerfüllbar. *Empfehlung:* Der
Zuordnung aus `06 §3.3.2` folgen — Zweig und Zähler sind Stufe 1, ihre LUT/FF/DSP gehören ins
Budget `01 §3.9` und **nicht** in den Ressourcenposten von §3.1.3 Teil 2. Die Zeile „Umsetzung
nach Stufe 1 (Kapitel 18)" in `03` O-03-6 ist entsprechend zu korrigieren; die Änderung gehört
zu `03`.

**O-18-10 — `07 §3.4` deklariert `W0[30:23]` und `W1[31:28]` nicht als reserviert.** Beide
Bitbereiche sind dort schlicht unbelegt — das Kopfwort endet bei `[22] after_drop` und
`[31] valid`, der Zeitstempel bei `[27] subslot` —, während `W2[31:24]` in derselben Tabelle
ausdrücklich „reserviert | 0" trägt. Ein unbelegtes Bit ohne Deklaration ist genau der Fall,
den §2.3 verhindern soll. *Empfehlung:* In `07 §3.4` beide Bereiche als „reserviert | 0" mit
Verweis auf §2.3 dieses Kapitels eintragen. Die Änderung gehört zu `07`; die zugehörige
Abnahme steht in R-18-02 Teil (b) und §5.1 Punkt 1b.
