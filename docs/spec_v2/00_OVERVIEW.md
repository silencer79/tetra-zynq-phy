# 00 — Überblick, Zielbild und Architektur-Schnitt

**Scope:** Zielbild von V2, verbindlicher FPGA↔SW-Schnitt, Architektur-Prinzipien,
Funktionsumfang, Leseführung, Glossar.
**Nicht hier:** Jedes Detail. Dieses Kapitel legt die Regeln fest, denen alle
anderen Kapitel folgen.
**Abhängigkeiten:** keine. Dies ist der Einstieg.

---

## 1. Zielbild

V2 ist ein vollständiger Neuaufbau des TETRA-Basisstations-Stacks für
LibreSDR / Zynq-7020 + AD9361-Klasse-Transceiver — RTL, ARM-Software und
Tooling.

**Funktionsziel:** mindestens der Funktionsumfang, der in V1 auf echter Luft mit
kommerziellen Endgeräten verifiziert ist (§5).

**Qualitätsziel:** V2 muss von einer Person oder einem Agenten aus dieser
Spezifikation heraus gebaut werden können, ohne V1 zu kennen — und ohne dabei
die Fehler zu wiederholen, die in V1 mehrfach gemacht wurden.

### 1.1 Warum überhaupt neu bauen

V1 funktioniert. Der Grund für den Neuaufbau ist nicht Funktion, sondern
Struktur: V1 ist über viele Iterationen und durch mehrere unterschiedliche
Autoren gewachsen. Das hat vier konkrete, benennbare Lasten hinterlassen —
keine Geschmacksfragen, sondern Wartbarkeits-Defekte:

| Last | Konkret | Folge |
|---|---|---|
| **Doppelte Implementierung** | Die SCH/F-Kanalcodierung existiert bit-gleich zweimal und **beide Kopien laufen live**: einmal in RTL, einmal in C [CODE sw/tetra_channel_codec.c:131] | Jede Änderung muss an zwei Orten bit-identisch nachgezogen werden. Bit-Drift ist eine Frage der Zeit, nicht des Ob. |
| **Mehrere Wege für dieselbe Sache** | Drei verschiedene Pfade, auf denen eine DL-PDU auf die Luft gelangt (über die Signalisierungs-Warteschlange, über die Voice-Filler-Mailbox unter Umgehung der Warteschlange, über den Broadcast-Pfad) | Kein Ort, an dem man „was geht raus" vollständig sieht. Fehlersuche muss drei Pfade prüfen. |
| **Halb durchgezogene Verschiebungen** | Der FPGA↔SW-Schnitt wurde mehrfach verschoben; einzelne Bewegungen blieben auf halbem Weg stehen. Beim Haupt-Signalisierungspfad baut Software den Body, aber RTL codiert ihn | Bit-genaue, nur im Kommentar dokumentierte Verträge zwischen C und Verilog. Ändert man eine Seite, bricht die andere still. |
| **Redundanter Datenexport** | RTL exportiert UL-PDU-Felder geparst **und** roh; die Software nutzt fast nur die rohen und parst selbst neu | Toter RTL-Code, der Fläche kostet und beim Lesen in die Irre führt. |

Dazu kommt eine dokumentarische Last: die Ist-Dokumentation ist gegenüber dem
Code gedriftet — nachweisbar, siehe `CONVENTIONS.md §3. V2 löst das nicht durch
mehr Dokumentation, sondern durch **weniger Stellen, an denen dieselbe Wahrheit
stehen muss**.

### 1.2 Was V2 ausdrücklich übernimmt

Der Neuaufbau ist kein Neuanfang beim Wissen. Diese Kategorien werden
unverändert übernommen und sind in den Fachkapiteln mit Messkontext belegt:

- **Empirisch gefundene Zahlenwerte** — Verstärkungs-Shifts, Korrelator-Schwellen,
  Sample-Offsets, Timeouts. Keiner davon ist aus der Theorie herleitbar; jeder
  wurde durch Messreihen gefunden, oft nach langer Fehlersuche.
- **Air-verifizierte Protokollabläufe** — die konkreten PDU-Sequenzen, mit denen
  ein reales Endgerät sich anmeldet, eine Gruppe wechselt, einen Ruf aufbaut.
- **Bekannte Sackgassen** — Wege, die begangen und als untauglich gemessen
  wurden. Sie stehen in `17_LESSONS_LEARNED.md`, damit V2 sie nicht erneut geht.

---

## 2. Unveränderliche Rahmenbedingungen

### 2.1 TETRA-Zeitstruktur

Diese Werte sind normativ und nicht verhandelbar:

| Größe | Wert | Beleg |
|---|---|---|
| Modulation | π/4-DQPSK, 36 kbit/s | [ETSI §5.2 Modulationsart, §5.3 Modulationsrate — beide normativ („shall be"); §4.7 ist nur die Übersicht] |
| Symbolrate | 18 000 Symbole/s, Symboldauer 500/9 µs ≈ 55,56 µs | [ETSI §4.5.3] |
| Zeitschlitz | 85/6 ms ≈ 14,167 ms = 255 Symboldauern | [ETSI §4.5.3] |
| TDMA-Frame | 4 Zeitschlitze, 170/3 ms ≈ 56,67 ms | [ETSI §4.5.2] |
| Multiframe | 18 Frames, 1,02 s; **Frame 18 ist Kontroll-Frame** | [ETSI §4.5.2] |
| Hyperframe | 60 Multiframes, 61,2 s | [ETSI §4.5.2] |
| UL-Unterschlitze | UL-Zeitschlitz teilbar in 2 Unterschlitze à 127,5 Symbole | [ETSI §4.5.3] |

**Der Zeitschlitz von 14,167 ms ist das zentrale Architektur-Maß.** Er trennt
in §3 Hardware von Software.

### 2.2 Zeitschlitz-Nummerierung

Die häufigste Fehlerquelle in V1. Verbindlich für V2:

- **Spezifikation, Software, Logausgaben, Bedienoberfläche:** ETSI-Zählung,
  **1-basiert**, geschrieben `TS1`…`TS4`.
- **RTL-Signale:** **0-basiert**, `tn` mit Wertebereich `0…3`.
- Jede Umrechnung wird an ihrer Stelle ausgeschrieben: `TS2 (ETSI) = tn=1 (RTL)`.
- **Ein** zentrales Umrechnungsmodul ist verpflichtend. Verstreute `±1` im Code
  sind ein Spec-Verstoß.

### 2.3 Plattform

Zynq-7020 (XC7Z020) auf LibreSDR mit AD9361-Klasse-Transceiver. Details,
Taktarchitektur und Ressourcen-Budget: `01_PLATFORM.md`.

**Zur Ressourcen-Bewertung:** Verbindliche Metriken sind **LUT, FF, BRAM, DSP
und WNS**. Die Slice-Auslastung in Prozent ist ein Packing-Artefakt des Platzers
und **keine Grenze** — in V1 wurden auf Basis dieser Zahl mehrfach Arbeiten
begonnen, die nichts brachten oder das Timing verschlechterten.

---

## 3. Architektur-Schnitt (verbindlich)

### 3.1 Das Trennkriterium

> **Was vor dem Senden von Zeitschlitz N fertig sein muss, gehört in die
> Hardware. Was ereignisgesteuert mit mehr als einer Slot-Dauer Spielraum
> läuft, gehört in die Software.**

Ein einziges Kriterium, konsequent angewandt. V1 hatte dasselbe Prinzip, hat es
aber an mehreren Stellen nicht durchgezogen — das ist die Hauptquelle seiner
Strukturlast (§1.1).

### 3.2 Hardware (PL) — abschließende Liste

1. **Sample-Signalverarbeitung**: Dezimation, Empfangs- und Sendefilterung,
   Interpolation, π/4-DQPSK-Modulation und -Demodulation, Symbol-Timing,
   Synchronisations-Korrelation — für Downlink **und** Uplink.
2. **TDMA-Zeitbasis**: Zeitschlitz-, Frame-, Multiframe-, Hyperframe-Zähler als
   einzige Zeitwahrheit des Systems, mit ladbarem Absolutwert.
3. **Slot-Zeitplan und Burst-Staging**: welcher Zeitschlitz welchen Inhalt
   trägt, Burst-Zusammenbau, Verteilung auf die Sendekette.
4. **Slot-gekoppelte Encoder**: Broadcast-Synchronisationskanal und
   Zugriffszuweisungskanal. Beide brauchen Vorausschau auf Frame- und
   Multiframe-Nummer und können nicht auf Software warten.
5. **Uplink-Zuweisung und Reservierung** — siehe §3.4, das ist der kritische
   Punkt.
6. **Mailboxen** in beide Richtungen, mit TDMA-Zeitstempel (§3.5).

### 3.3 Software (PS) — abschließende Liste

1. **Vollständige DL-Erzeugung**: Body, MAC-Header, LLC, MLE **und** die
   Kanalcodierung bis zur sendefertigen PDU. Die Hardware bekommt fertige
   Bits und routet sie nur noch.
2. **Vollständige UL-Auswertung** ab den Soft-Bits: Descrambling,
   Deinterleaving, Viterbi-Decodierung, Prüfsumme, Fragment-Zusammensetzung.
3. **Protokoll-Logik**: Mobilitätsverwaltung, Rufsteuerung, Kurznachrichten,
   Teilnehmerverwaltung, Richtlinien.
4. **Sprach-Transcodierung** einschließlich Sprachcodec.
5. **Konfiguration, Bedienoberfläche, Persistenz.**

### 3.4 Der kritische Punkt: Uplink-Zuweisung

Diese Festlegung ist die wichtigste Einzelentscheidung der Spezifikation, weil
genau hier ein V1-Versuch **gemessen gescheitert** ist.

**Was in V1 passierte:** Die UL-Decodierung wurde nach Software verlagert. Damit
wanderte auch die Zuweisungs-Entscheidung dorthin — sie hing nun am
Software-Decode und kam über eine asynchrone Mailbox zurück. Ergebnis auf der
Luft: Die Zuweisung war nicht mehr sendezeitpunkt-fest. Endgeräte, die keine
rechtzeitige Zuweisung bekamen, wiederholten ihre Anforderung; jede Wiederholung
löste eine weitere Zuweisung aus; die Zuweisungen fluteten die
Signalisierungs-Warteschlange; die Anmeldebestätigung erreichte das Endgerät
nicht mehr; das Gerät meldete sich erneut an. Eine sich selbst verstärkende
Spirale, die den gesamten Downlink degradierte. Eine Ratenbegrenzung milderte
die Symptome, behob die Ursache nicht. Der Umbau wurde zurückgenommen.
[MESS 2026-07-11]

**Verbindliche Konsequenz für V2 — drei Regeln:**

- **R-00-01:** Die Uplink-Zuweisung und die Mehrslot-Reservierung werden
  vollständig in der Hardware erzeugt. Kein Software-Umlauf liegt im
  Antwort-Zeitpfad einer Zuweisung.
- **R-00-02:** Die Zuweisungs-Entscheidung darf **nicht** vom Inhalt des
  empfangenen Bursts abhängen, weil dessen Auswertung in der Software liegt.
  Sie wird aus hardware-lokal verfügbaren Ereignissen gebildet — Burst-Erkennung
  und Position im Zeitraster. Eine zu großzügig erteilte Zuweisung kostet
  Slot-Kapazität; eine zu späte kostet die Anmeldung. Der Entwurf wählt bewusst
  das erste Risiko.
- **R-00-03:** Die Software steuert das Zuweisungs-**Muster** über
  Konfigurationsregister (Anzahl Unterschlitze, Haltedauer über mehrere
  Zeitschlitze, Wiederholung) — aber niemals das einzelne Zuweisungs-Ereignis.

Der konkrete Mechanismus wird in `06_MAC.md` und `07_PS_PL_CONTRACT.md`
spezifiziert und muss ein Abnahmekriterium haben, das die Spirale ausschließt
(`14_VERIFICATION.md`).

**Nebenbedingung, ebenfalls aus V1 gemessen:** Lange Kurznachrichten im Uplink
brauchen eine Reservierung über mehrere Zeitschlitze. Ein Mechanismus, der nur
einen einzelnen Unterschlitz zuweisen kann, lässt das Endgerät die Fortsetzungs-
Bursts nicht senden. Die Mehrslot-Reservierung ist deshalb Teil von R-00-01,
nicht ein späteres Zusatzfeature.

### 3.5 Zeitstempel-Pflicht

Weil die Fragment-Zusammensetzung in der Software liegt, die Zeitwahrheit aber in
der Hardware:

- **R-00-04:** Jeder Uplink-Burst, der an die Software übergeben wird, trägt
  seinen TDMA-Zeitstempel (Zeitschlitz, Frame, Multiframe) im selben
  Mailbox-Transfer. Die Software leitet Zeitbezüge **ausschließlich** daraus ab
  und hält keine eigene Uhr.

Grund: In V1 bezog ein Reassembly-Zeitgeber seinen Frame-Takt aus der
Downlink-Empfangskette. Das koppelt zwei Funktionen, die nichts miteinander zu
tun haben — fällt der DL-Empfang aus, bricht die UL-Zusammensetzung. V2
entkoppelt das über den Zeitstempel.

### 3.6 Was diese Aufteilung erledigt

| V1-Last (§1.1) | Auflösung in V2 |
|---|---|
| Doppelte Kanalcodierung | Existiert genau einmal, in Software. Die Hardware hat keinen Kanalcodierer für Nutzdaten. |
| Drei DL-Emissionspfade | Genau ein Pfad: fertige PDU → Mailbox → Zeitplan → Sendekette. |
| Bit-genaue C↔Verilog-Verträge | Reduziert auf die Mailbox-Formate, die in `07_PS_PL_CONTRACT.md` an **einer** Stelle normativ stehen. |
| Geparst-und-roh-Doppelexport | Die Hardware parst keine Nutzdaten. Es gibt nur den rohen Weg. |

Die Ausnahmen sind vollständig aufgezählt und jede ist über das Slot-Kriterium
begründet: Broadcast-Synchronisation, Zugriffszuweisung, Uplink-Zuweisung. Diese
drei brauchen Vorausschau im Zeitraster und bleiben in Hardware.

---

## 4. Architektur-Prinzipien

Diese Regeln gelten in allen Kapiteln. Sie sind aus konkreten V1-Fehlern
abgeleitet, nicht aus allgemeiner Lehre.

- **P1 — Wer den Body baut, codiert ihn.** Eine Verarbeitungskette wird nicht
  mitten in der Codierung über die Hardware-Software-Grenze geschnitten.
- **P2 — Eine Wahrheit, ein Ort.** Jede Konstante, jede Registeradresse, jedes
  Bit-Layout ist an genau einer Stelle normativ. Andere Stellen verweisen.
- **P3 — Ein Weg pro Funktion.** Kein zweiter Pfad „für den Sonderfall".
  Sonderfälle sind Parameter, nicht Pfade.
- **P4 — Bit-Order ist immer explizit.** Bei jedem Bitfeld, Bus und
  Mailbox-Wort: MSB- oder LSB-first, mit Bit-Positionen. „Analog zum
  Nachbarmodul" ist keine Angabe.
- **P5 — Empirische Werte tragen ihren Messkontext.** Ein Schwellwert ohne die
  Angabe, was bei Nachbarwerten gemessen wurde, wird beim nächsten Umbau
  „optimiert" und bricht das System.
- **P6 — Beobachtbarkeit ist Teil der Schnittstelle.** Jeder Verwurf, jede
  Prüfsummen-Verletzung, jeder Mailbox-Überlauf hat einen im Betrieb lesbaren
  Zähler. Was man nicht zählt, kann man auf der Luft nicht diagnostizieren.
- **P7 — Der Fehler liegt im eigenen Code.** In V1 war die Ursache jedes
  untersuchten Fehlverhaltens im eigenen Entwurf, nie in Transceiver, Treiber
  oder Endgerät. Diagnose beginnt beim eigenen Code.

---

## 5. Funktionsumfang

### 5.1 Stufe 1 — Parität mit dem air-verifizierten V1-Stand

| Funktion | Kapitel |
|---|---|
| Zellaussendung: Synchronisation, Broadcast, Systeminformation, Zugriffszuweisung | 04, 05, 06 |
| Anmeldung eines Endgeräts (Attach) mit Teilnehmerverwaltung | 09, 13 |
| Gruppen-Zuordnung und Gruppenwechsel | 09 |
| Gruppenruf mit Sprachweiterleitung, mehrere Gruppen auf mehreren Zeitschlitzen parallel | 10, 12 |
| Einzelruf-Ablauf | 10 |
| Nachträglicher Rufeintritt (Late Entry) | 10 |
| Kurznachrichten in beide Richtungen, einschließlich Statusnachrichten | 11 |
| Lange Kurznachrichten mit Fragmentierung in beide Richtungen | 11 |
| Bedienoberfläche, Konfiguration, Persistenz | 13 |

### 5.2 Roadmap — spezifiziert, nicht in Stufe 1 gebaut

Rufsucher-Betrieb, Vollduplex-Einzelruf, Kanalstehlen während eines Rufs sowie
die Verbesserungsstufen der Empfangskette. Alle in `18_ROADMAP.md` mit
Anforderungen und Ressourcenbedarf, damit Stufe 1 sie nicht verbaut.

---

## 6. Leseführung

**Wer die Hardware baut:** 01 → 02 → 03 → 04 → 05 → 07 → 08
**Wer die Software baut:** 00 → 07 → 05 → 06 → 09 → 10 → 11 → 12 → 13
**Wer verifiziert:** 14, dann das jeweilige Fachkapitel
**Wer in Betrieb nimmt:** 01 §Bring-up → 15
**Wer wissen will, warum etwas so ist:** 17

`07_PS_PL_CONTRACT.md` ist die einzige normative Quelle für Registeradressen und
Mailbox-Formate. Ein zentrales Nachschlage-Kapitel gibt es **nicht**: jedes
Bit-Layout, jede Konstante und jeder Gold-Messwert steht in dem Fachkapitel, das
ihn normativ festlegt (P2). Wer eine Konstante sucht, geht über die Leseführung,
nicht über eine Sammlung — eine Sammlung wäre die zweite Stelle, an der dieselbe
Wahrheit stehen müsste.

---

## 7. Glossar

| Begriff | Bedeutung |
|---|---|
| **PS / PL** | Processing System (ARM-Kerne) / Programmable Logic (FPGA-Anteil) des Zynq |
| **Zeitschlitz / TS** | TDMA-Zeitschlitz, 14,167 ms. Im Text 1-basiert (TS1…TS4), im RTL 0-basiert (`tn`) |
| **Frame / Multiframe / Hyperframe** | TDMA-Hierarchie: 4 Zeitschlitze / 18 Frames / 60 Multiframes |
| **Burst** | Physikalische Sendeeinheit in einem Zeitschlitz |
| **type-1 … type-5** | ETSI-Bezeichnung der Bit-Ebenen von der Nutzinformation bis zu den gesendeten Bits |
| **Soft-Bit** | Vorzeichenbehafteter Zuverlässigkeitswert je codiertem Bit statt harter Null/Eins |
| **MS** | Mobile Station, Endgerät |
| **ISSI / GSSI** | Individuelle bzw. Gruppen-Kurzadresse eines Teilnehmers |
| **Gold-Aufzeichnung** | Bit-genauer Decode eines Mitschnitts einer echten kommerziellen Basisstation; Referenzverhalten |
| **Mailbox** | Registerfenster zum Austausch strukturierter Daten zwischen PS und PL |

Protokollschicht-Kürzel (MAC, LLC, MLE, MM, CMCE, SDS) werden in den jeweiligen
Fachkapiteln bei erster Verwendung eingeführt.

---

## 8. Verifikation dieses Kapitels

Dieses Kapitel ist erfüllt, wenn:

- die Zeitkonstanten in §2.1 mit ETSI übereinstimmen (nachprüfbar gegen die
  genannten Paragraphen),
- jedes Fachkapitel den Schnitt aus §3 einhält, ohne eine nicht in §3.2
  aufgezählte Funktion in die Hardware zu legen,
- die drei Zuweisungs-Regeln R-00-01 bis R-00-03 in `06_MAC.md` und
  `07_PS_PL_CONTRACT.md` mit einem konkreten Mechanismus unterlegt sind,
- `14_VERIFICATION.md` ein Abnahmekriterium enthält, das die in §3.4
  beschriebene Spirale ausschließt.

## 9. Offene Punkte

1. **O-00-1 — Konkreter Zuweisungs-Mechanismus (§3.4).** Die Regeln stehen, der
   Mechanismus ist in `06_MAC.md` zu entwerfen. Die Frage ist, wie großzügig
   die inhaltsunabhängige Zuweisung sein darf, ohne Slot-Kapazität für
   Sprachkanäle zu verlieren. Zu messen, nicht zu schätzen.
2. **O-00-2 — Sprachcodec-Herkunft.** Der Codec ist Software-resident. Ob V2 die
   ETSI-Referenz-Quellen weiterverwendet oder eine eigene Implementierung
   erhält, ist in `12_VOICE.md` zu entscheiden — mit Blick auf Rechenlast auf
   dem ARM-Kern.
3. **O-00-3 — Bekannte Abweichungen gegenüber der Gold-Referenz.** V1 weicht in
   einzelnen semantischen Feldern von der Referenz-Basisstation ab (unter
   anderem im quittierten Anmeldetyp und in einer als Vorgabewert stehenden
   Gruppenadresse). V2 muss diese Felder aus dem Anmelde-Wunsch des Endgeräts
   bzw. aus der Konfiguration ableiten. Präzise Festlegung in `09_LLC_MLE_MM.md`.
