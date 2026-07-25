# 17 — Fehlerkatalog aus V1 mit Vermeidungsregeln

**Scope:** Die systematische Auswertung dessen, was in V1 schiefgegangen ist —
technische Fehler mit Ursache und Wirkung, gescheiterte Umbauten mit dem Grund
ihres Scheiterns, Dokumentations- und Werkzeugfehler. Zu jeder Fehlerklasse
genau eine verbindliche Regel, deren Einhaltung prüfbar ist.
**Nicht hier:** Fachspezifikation. Jede Regel benennt das Kapitel, das sie
umsetzt; die Sachverhalte stehen dort, nicht hier.
**Abhängigkeiten:** `00_OVERVIEW.md` (Prinzipien P1–P7, Architektur-Schnitt),
`CONVENTIONS.md` (Evidenz-Marker, Namenskonventionen).

Dies ist das einzige Kapitel, in dem Historie der Inhalt ist. Es benennt
Sachverhalte, keine Verursacher — weder Personen noch Werkzeuge noch Hardware.

---

## 1. Anforderungen

- **R-17-01:** Jeder Eintrag dieses Katalogs trägt genau eine Vermeidungsregel
  (`V-17-xx`). Eine Regel ohne benanntes Prüfverfahren gilt als nicht erfüllt.
- **R-17-02:** Jede Regel ist genau einem Fachkapitel zugeordnet, das sie
  umsetzt. Das Register in §5.4 ist die Zuordnungstabelle; sie ist vollständig
  (jede Regel hat ein Kapitel) und eindeutig (jede Regel hat genau eines).
- **R-17-03:** Eine Änderung, die eine der in §5.4 genannten Eigenschaften
  berührt (Bit-Order, Feldbreite, Zählweise, empirischer Schwellwert,
  Registerlayout, Ausrichtungskonvention), wird nur zusammen mit dem Nachweis
  übernommen, den die zugehörige Regel fordert. Ohne Nachweis wird sie
  abgelehnt, nicht „später nachgezogen".
- **R-17-04:** Ein Befund, der sich auf **Abwesenheit** stützt („die PDU kommt
  nicht vor", „das Register wird nicht gelesen", „der Pfad ist tot"), ist ohne
  Positivkontrolle des verwendeten Werkzeugs kein Befund (§3.10).
- **R-17-05:** Widersprüche zwischen Dokumentation und Code werden als Zeile in
  diesem Kapitel geführt, bis die Dokumentation nachgezogen ist. Der Code
  gewinnt (`CONVENTIONS §3`).
- **R-17-06:** Dieser Katalog wird nicht bei Projektende geschrieben. Jeder
  Fehler, der in V2 mehr als einen Anlauf braucht, kommt als Eintrag hinzu —
  mit Ursache, Wirkung, Beleg und Regel.

---

## 2. Aufbau des Katalogs

Gliederung nach Fehlerklasse, nicht chronologisch: die Chronologie zeigt
151 Einzelfälle, die Klasse zeigt zehn wiederkehrende Muster. Nur das Muster
ist übertragbar.

| Klasse | Inhalt | § | Regel |
|---|---|---|---|
| F1 | Gescheiterte Umbauten (die drei teuersten Fälle) | 3.1 | V-17-1…3 |
| F2 | Bit-Reihenfolge und Ausrichtung | 3.2 | V-17-4 |
| F3 | Feldbreiten, Einheiten und Längenangaben | 3.3 | V-17-5 |
| F4 | Verwechslung von Zählweisen (nullbasiert / einsbasiert) | 3.4 | V-17-6 |
| F5 | Doppelte Implementierungen und ihr Auseinanderdriften | 3.5 | V-17-7 |
| F6 | Halb durchgezogene Umbauten | 3.6 | V-17-8 |
| F7 | Zeit- und Reihenfolgefehler | 3.7 | V-17-9 |
| F8 | Empirische Werte, ohne Messung geändert | 3.8 | V-17-10 |
| F9 | Dokumentation, die vom Code abgewichen ist | 3.9 | V-17-11…13 |
| F10 | Werkzeuge, die falsche Befunde erzeugt haben | 3.10 | V-17-14, 15 |

Eintragsschema: **Titel** — Ursache · Wirkung · Beleg. Belege tragen die Marker
aus `CONVENTIONS §3`; Zeilennummern beziehen sich auf den geprüften
Repository-Stand.

Sieben der zehn Klassen haben denselben Kern: **eine Vereinbarung, die nur
implizit bestand** — Bit-Order, Ausrichtung, Einheit, Zählweise,
Registerlayout, Messkontext eines Schwellwerts. Jedes Mal kannte ein Autor die
Vereinbarung und ein zweiter musste sie erraten. V2 löst das nicht durch mehr
Sorgfalt, sondern indem die Vereinbarung an einer Stelle steht und die
Gegenprobe existiert, die ihre Verletzung sichtbar macht.

---

## 3. Die Fehlerklassen

### 3.1 F1 — Gescheiterte Umbauten

Drei Umbauten sind gescheitert. Sie sind die wertvollsten Einträge dieses
Katalogs, weil jeder Fehlversuch zwischen einem und mehreren Arbeitstagen
gekostet hat und in zwei von drei Fällen air-verifizierte Funktion vernichtet
hat.

#### F1.1 — Verlagerung der Uplink-Auswertung in die Software

**Ursache.** Die komplette UL-Signalisierungs-Auswertung (Descramble,
Deinterleave, Viterbi, Prüfsumme, Zusammensetzung, Parsen) wurde aus der
Hardware in die Software verlagert; die Hardware lieferte nur noch Soft-Bursts
über eine neue Mailbox. Mit der Auswertung wanderte auch die **Entscheidung
über die Uplink-Zuweisung** in die Software: die Zuweisung wurde erst nach dem
Software-Decode erteilt und lief über eine asynchrone Mailbox zurück.

**Wirkung.** Die Auswertung selbst funktionierte: Einbuchen zweier Endgeräte,
Gruppenruf und kurze Kurznachrichten waren luftverifiziert; Zeitbudget und
Ressourcen hielten (WNS +0,007 ns). Gescheitert ist die **Sendezeitpunkt-
Festigkeit der Zuweisung**. Endgeräte ohne rechtzeitige Zuweisung wiederholten
ihre Anforderung; jede Wiederholung erzeugte eine weitere Zuweisung; die
Zuweisungen fluteten die Signalisierungs-Warteschlange; die Anmeldebestätigung
erreichte das Gerät nicht mehr; das Gerät meldete sich erneut an. Eine
Ratenbegrenzung milderte die Symptome und behob die Ursache nicht. Der Umbau
wurde vollständig zurückgenommen — beide Richtungen, RTL und Software.

**Wie erkannt.** Nicht am Zähler, sondern an der Gesamtdegradation des
Downlinks auf der Luft: die Zuweisungen verdrängten die eigentliche
Signalisierung. V1 hatte **keinen** Zähler für eine zu spät bereitgestellte
Zuweisung — der Fehler war nur an seinen Folgen sichtbar
[MESS 2026-07-11, 00 §3.4].

**Beleg.** Umbau [CODE-Historie: Umbau-Commit `91cc5a2`, 10 Dateien,
+489/−520 Zeilen], Rücknahme ohne inhaltliche Begründung im Commit-Text
[`6a27d6e`]; Bewertung und Konsequenz [00 §3.4, R-00-01 bis R-00-03].

**Lehre.** Der Fehler war nicht die Verlagerung der Auswertung — die ist in V2
verbindlich (00 §3.3). Der Fehler war, eine **deadline-gebundene Entscheidung**
mit der Auswertung mitzuverlagern, weil sie im gleichen Modul saß. Zuständigkeit
und Zeitbindung sind zwei unabhängige Achsen.

#### F1.2 — Verlagerung der Sende-Codierung in die Software

**Ursache.** Die DL-Codierkette wurde aus dem RTL in die Software verlagert:
acht RTL-Module entfielen, die Software baute die vollständige sendefertige
432-bit-PDU und schob sie über eine dünne Roh-PDU-Mailbox in die Sende-
Warteschlange. Der Umbau war erfolgreich und luftverifiziert. Drei Tage später
wurde der Arbeitsbaum **pauschal** auf einen älteren Stand zurückgesetzt, weil
ein **anderer**, später hinzugekommener Teil (Kanalstehlen mit einem zweiten
Korrelator auf derselben IQ-Quelle) die UL-Erfassungsrate von ~150/s auf ~3/s
einbrechen ließ. Die Rücksetzung nahm alles mit, was zwischen dem Zielstand und
dem Kopf lag.

**Wirkung.** Vernichtet wurden:
- die Verlagerung der Sende-Codierung selbst — Ressourcengewinn −3 841 LUT,
  −4 197 FF, Slice 97,64 % → 92,56 %, WNS +0,006 ns (Zeitvorgabe erfüllt), im
  Luft-Test 22 Anmeldungen und 4 Rufaufbauten, Sprachburst-Latenz (NUB)
  131–143 ms, keine Abbrüche [CODE-Historie `7c8614e`, 2026-05-21];
- die Empfangs-Verstärkungsanpassung, deren Wirkung mit Prüfsummen-Erfolg
  27 % → 93 % gemessen war, samt getrenntem UL-Schwellwertregister
  [CODE-Historie `f2af067`, 2026-05-23].

Die Verstärkungsanpassung wurde später als **festverdrahtete Konstante**
wiederhergestellt [CODE rtl/rx/tetra_rx_frontend.v:135], der zugehörige
Modulkopf nennt bis heute den alten Wert
[CODE rtl/rx/tetra_rx_frontend.v:21] (→ F9.4). Das getrennte
UL-Schwellwertregister fehlt bis heute; DL- und UL-Korrelator teilen wieder
**ein** Register [CODE rtl/infra/tetra_axi_lite_regs.v:1418,
rtl/tetra_zynq_top.v:567] — genau der Zustand, dessen Nachteil zuvor gemessen
und dokumentiert worden war (→ F8.1). Die Sende-Codierung in Software existiert
heute nicht mehr; das RTL-Modul ist zurück
[CODE rtl/lmac/tetra_dl_pdu_builder.v].

**Wie erkannt.** Erst bei der Bestandsaufnahme für diese Spezifikation, durch
Vergleich der Commit-Historie mit dem Dateibestand am Kopf.

**Beleg.** Rücksetz-Commit mit Begründung, die ausschließlich den
Kanalstehlen-Teil betrifft [CODE-Historie `acbd29c`, 2026-05-24]; Zielstand
[`998bdb3`, 2026-05-20]; die verlorenen Commits liegen dazwischen
[`469bb10`, `7c8614e`, `f2af067`].

**Lehre.** Dies ist eine Lehre über Arbeitsweise, nicht über Technik. Eine
Rücknahme muss so **schmal** sein wie die Ursache. Ein Rücksetzen des gesamten
Arbeitsbaums ist keine Rücknahme, sondern ein Datenverlust mit unbekanntem
Umfang — und er bleibt unbemerkt, weil das Symptom, das zur Rücksetzung führte,
danach tatsächlich verschwunden ist.

#### F1.3 — Entfernen scheinbar toten Logik-Codes bei hoher Auslastung

**Ursache.** Bei ~97 % Slice-Auslastung wurden zwei Aufräumschritte
durchgeführt: ein toter Sendepfad in einem Lower-MAC-Modul und zwei
Register-Schreibfenster ohne Verbraucher in der PL. Beide Schritte waren
sauber begründet — kein Verbraucher, keine Instanziierung, keine Testbench —
und beide erwarteten ausdrücklich **null** Flächengewinn, weil die Synthese
diese Logik ohnehin entfernt.

**Wirkung.** Kein Flächengewinn (wie erwartet), aber Verschlechterung des
Zeitverhaltens. Beide Schritte wurden am selben Tag zurückgenommen. Der Fall
war eine **Wiederholung**: dieselbe Entfernung der Register-Schreibfenster war
einen Monat früher schon einmal gemessen worden — WNS +0,026 ns → −0,260 ns bei
196 verletzten Endpunkten — und diese Messung stand im Commit-Text des
Wiederholungsversuchs, als Warnung, die nicht zur Unterlassung führte
[CODE-Historie `aaf72cd`, `94ae63e`, Rücknahmen `853e289`, `386c945`,
alle 2026-06-20].

Derselbe Mechanismus in einem dritten Fall: das Entfernen der asynchronen
Rücksetzsignale von Survivor-Registern des Viterbi-Decoders brachte −74 Slices
(−0,55 Prozentpunkte) und kostete Setup-Reserve von +0,144 ns auf −0,135 ns.
Netto keine Verbesserung, zurückgenommen [CODE-Historie `3298a28`, 2026-05-02].

**Der Gegenfall — worin der Unterschied liegt.** Das Entfernen eines toten
DL-Decode-Pfads samt zugehörigem Speicherzugriffspfad brachte messbar
−1 011 LUT, −1 507 FF, Slice 99,67 % → 98,66 %, WNS +0,014 → +0,006 ns
(Zeitvorgabe weiter erfüllt) [CODE-Historie `b92f47e`, 2026-06-20]. Der
Unterschied ist nicht „vorsichtiger", sondern **strukturell**: hier entfiel eine
zusammenhängende Datenpfad-Hierarchie mit Registern und Speicher, dort nur
Streulogik, die die Synthese schon entfernt hatte, deren Wegfall aber die
Control-Sets und damit das Packing verändert.

**Lehre.** „Tot" ist keine Rechtfertigung; „belegt totes zusammenhängendes
Datenpfad-Volumen" ist eine. Und: Slice-Prozent ist ein Packing-Artefakt und
keine Grenze — auf dieser Zahl wurden mehrfach Arbeiten begonnen, die nichts
brachten (`CONVENTIONS §6.4`, 00 §2.3).

> **V-17-1** — Eine Verlagerung über die HW/SW-Grenze wird nur zusammen mit der
> Frage übernommen, welche Entscheidungen im verlagerten Modul eine
> Slot-Deadline haben. Deadline-gebundene Entscheidungen bleiben, wo die
> Deadline gilt. Prüfung: Für jeden verlagerten Block ist die Liste der von ihm
> getroffenen Entscheidungen mit „deadline-gebunden ja/nein" nachzuweisen; jede
> Zuweisungsentscheidung braucht zusätzlich einen Zähler für versäumte Fristen
> (08 §3.3.4).
>
> **V-17-2** — Eine Rücknahme betrifft genau die Änderung, die das Symptom
> erzeugt hat. Pauschales Zurücksetzen des Arbeitsbaums auf einen älteren Stand
> ist verboten. Prüfung: Jede Rücknahme benennt im Text die Änderung, die sie
> rückgängig macht, und listet auf, was zwischen dem Zielstand und dem Kopf
> liegt und **nicht** betroffen ist.
>
> **V-17-3** — Entfernen von Logik ohne Verbraucher ist bei WNS < +0,05 ns kein
> Aufräumschritt, sondern eine Zeitverhaltens-Änderung. Prüfung: A/B-Build mit
> WNS, LUT, FF, BRAM vor und nach dem Eingriff; ohne belegten Gewinn in
> mindestens einer dieser Größen wird der Eingriff nicht übernommen. Eine
> bereits einmal gemessene Verschlechterung schließt den Wiederholungsversuch
> aus.

---

### 3.2 F2 — Bit-Reihenfolge und Ausrichtung

#### F2.1 — Gegenläufige Ausrichtungskonvention auf demselben Bus

**Ursache.** Der 432-bit-Bus der DL-Signalisierungs-Warteschlange trägt
entweder einen Vollblock (SCH/F, 432 bit) oder einen Halbblock (SCH/HD,
216 bit). Für den Halbblock war nicht festgelegt, in welcher Hälfte er liegt.
Der Verbraucher liest den ersten Block aus `[431:216]`, also **MSB-ausgerichtet**
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:165]. Zwei Erzeuger schrieben
LSB-ausgerichtet.

**Wirkung.** Der Verbraucher las 216 Nullen als ersten Block; die Prüfsumme
schlug beim Endgerät fehl, die Vorab-Antwort wurde verworfen, das Endgerät
sandte das Folgefragment nicht, die Zusammensetzung lief nie an, die Mailbox
blieb leer. Sichtbar war nur das letzte Glied: „Gruppenwechsel funktioniert
nicht". Die Ursache lag vier Stufen davor. Der Weg mit Vollblock war
unauffällig, weil dort keine Ausrichtungsfrage entsteht — deshalb funktionierte
das Einbuchen, während Gruppenwechsel und Ablehnung defekt waren
[CODE-Historie `912f7ca`].

**Beleg.** Verbraucher MSB [CODE rtl/lmac/tetra_dl_signal_scheduler.v:165];
korrigierter Erzeuger MSB
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:334]; **bis heute** nicht
korrigierter zweiter Erzeuger LSB
[CODE rtl/lmac/tetra_pre_reply_blck.v:209] (→ F6.1).

#### F2.2 — Modulkopf dokumentiert die falsche Konvention

**Ursache.** Der Modulkopf der Warteschlange beschreibt das Eintragsformat als
„SCH/F full 432b or SCH/HD **LSB-aligned in [215:0]**"
[CODE rtl/lmac/tetra_dl_signal_queue.v:17]. Der Verbraucher liest MSB. Der
Erzeuger, der LSB schreibt, beruft sich in seinem Kommentar ausdrücklich auf
diese Kopfzeile [CODE rtl/lmac/tetra_pre_reply_blck.v:204-205].

**Wirkung.** Ein Autor, der die Konvention korrekt aus der Dokumentation
übernahm, baute einen Fehler ein. Die falsche Zeile steht am Kopf,
die richtige Aussage nur im Ausdruck des Verbrauchers.

#### F2.3 — Ausrichtung eines eingebetteten Elements

Ein 25-bit-Kanalzuweisungs-Element wird rechtsausgerichtet in ein 32-bit-Wort
gelegt; ein festverdrahteter Ersatzwert war linksausgerichtet geschrieben. Alle
Felder des Elements dadurch um sieben Bit verschoben — das Endgerät las
Zeitschlitz und Trägernummer falsch, im eigenen Decode sichtbar als „Keep TS=2
Reserved Carrier=3328" [CODE-Historie `9ba3441`].

#### F2.4 — Verschiebung beim Auffüllen eines Schieberegisters

MSB-first-Schieben mit Nullauffüllung: das Auffüllen wurde **angehängt** statt
**vorangestellt**. Die gesendeten Symbole waren um die Auffülllänge verschoben,
also Rauschen [CODE-Historie `5b011f9`].

#### F2.5 — Bit-Reihenfolge zwischen Hardware-Mailbox und Software-Codec

Die Hardware legt das erste Bit des Sprachblocks auf den höchsten Index des
Wortfelds, der Software-Codec erwartet es auf Index 0; die Umkehrung war nicht
vereinbart und fehlte. Der Viterbi-Decoder der Software konnte nicht
synchronisieren; zusammen mit falschen Abtastversätzen (→ F3.6) ergab das 98 %
Rahmenfehlerrate und unbrauchbares Audio bei **fehlerfreier**
Modulationsanzeige — eine Kombination, die die Fehlersuche in den Sendepfad
statt in die Mailbox-Vereinbarung lenkte
[MESS 2026-05-17, CODE-Historie `8b0737e`].

#### F2.6 — Halbwort-Versatz beim Zusammenpacken einer Mailbox

Die Software packte die ersten 16 Bit einer 432-bit-Nutzlast in das untere
Halbwort von Wort 0; die Hardware erwartete Wort 0 als vollen 32-bit-Ausschnitt
und das letzte Halbwort im **oberen** Halbwort von Wort 13. Prüfsummenfehler in
10 von 10 Bursts auf der Luft, nach der Korrektur 9 von 9 fehlerfrei
[MESS 2026-05-02, CODE-Historie `4bb41eb`].

> **V-17-4** — Für jeden Bus, jedes Mailbox-Wort und jedes eingebettete
> Element ist die Ausrichtung normativ festgelegt: MSB- oder LSB-ausgerichtet,
> mit Bitpositionen, an **einer** Stelle (`07_PS_PL_CONTRACT`). Ein
> Nutzinhalt, der kürzer ist als der Bus, hat eine festgelegte Position und
> einen festgelegten Füllwert. Prüfung: (a) Jeder Erzeuger und jeder
> Verbraucher nennt die Konvention im Modulkopf mit Verweis auf `07`; (b) für
> jeden solchen Bus existiert ein Testvektor, der unter der **gegenteiligen**
> Konvention fehlschlägt — ein Test, der beide Konventionen passiert, ist kein
> Test.

---

### 3.3 F3 — Feldbreiten, Einheiten und Längenangaben

#### F3.1 — Bitzahl als Symbolzahl gelesen

**Ursache.** Die Norm gibt Trainingsfolgen in **Bit** an: die
Synchronisations-Trainingsfolge hat 38 Bit = 19 Symbole
[ETSI §9.4.4.3.4, Gl. 9.11], die normale Trainingsfolge 22 Bit = 11 Symbole
[ETSI §9.4.4.3.2, Gl. 9.4]. Die 38 wurde als Symbolzahl übernommen und die
Referenz auf 76 Bit verlängert.

**Wirkung.** Der Korrelator suchte ein Muster doppelter Länge; die Verriegelung
kam nie zustande. Erst zwei Iterationen später wurde die Referenz auf 19 Symbole
korrigiert [CODE-Historie `bcf807a` (Einbau), `9991c9e`, `8183b67`
(Korrektur)]. Zwischenzeitlich war zusätzlich ein Schwellwert von 200 auf einen
Korrelator mit maximal 38 Treffern gesetzt — unerreichbar, also dauerhaft
`sync_found = 0` [CODE-Historie `e130673`].

#### F3.2 — Bedingte Kopf-Bits: einmal zu wenig, einmal zu viel

**Ursache.** Drei Anwesenheitsbits im MAC-Kopf wurden zunächst unbedingt
gesetzt (Kopf 43 Bit), dann als bedingt interpretiert und entfernt (Kopf
40 Bit), dann wieder als unbedingt erkannt (Kopf 43 Bit).

**Wirkung.** In der 40-bit-Variante verschob sich der Beginn des LLC-Felds um
drei Bit; das Endgerät las an der Stelle des Verbindungstyps das falsche Bit,
verwarf die PDU stillschweigend und blieb in der Zugriffs-Wiederholung. Die
Diagnose kostete drei Anläufe, weil zwei sachlich richtige Korrekturen
(Adressierung, Rumpfaufbau) das Symptom nicht beseitigen konnten
[CODE-Historie `5ee530a` → `8d7143d`].

#### F3.3 — Kopf eines Fortsetzungs-Abschlusses um 17 Bit zu kurz

**Ursache.** Der Abschluss-Kopf einer fragmentierten DL-Nachricht trug 4 statt
21 Bit; Position der Zusage, Längenangabe, Zusage-Anwesenheitsbit und
Zusage-Element fehlten. Eine frühere Korrektur hatte das Längenfeld auf die
Annahme eines Versatzes hin **entfernt** — genau verkehrt.

**Wirkung.** Das empfangende Endgerät las Nutzbits als Kopf, errechnete eine
Länge von 39 Oktetten, die Zusammensetzung war korrupt, die Nachricht wurde
verworfen. Einzelburst-Nachrichten funktionierten, weil sie keinen
Abschluss-Kopf haben — was die Fehlersuche auf die Fragmentierung statt auf den
Kopf lenkte [MESS 2026-06-19, CODE-Historie `cf1eb2b`].

#### F3.4 — Länge aus dem falschen Teilfeld abgeleitet

**Ursache.** Die LLC-Kopflänge wurde über den vollen 4-bit-Typcode bestimmt.
Das oberste Bit dieses Codes ist aber das Prüffeld-Anwesenheitsbit, das eine
Prüfsumme **am Ende** anhängt und die Kopflänge nicht verändert.

**Wirkung.** Für eine Nachricht mit Prüffeld war der Kopf um ein Bit zu kurz,
der Nachrichtentyp wurde als 7 statt 15 gelesen und die Kurznachricht als
Ruf-Aufbauwunsch behandelt: das sendende Endgerät bekam einen Sprachruf-Aufbau
auf eine Textnachricht und brach ab [MESS 2026-06-10, CODE-Historie `fe2a236`].

#### F3.5 — Zu schmale Zähler und festverdrahtete Bit-Ausschnitte

Ein Abstandszähler war 9 Bit breit, dazu standen an drei Stellen literale
Ausschnitte `[8:0]`: jede Zeitüberschreitungsschwelle ≥ 512 war unwirksam, ohne
Fehlermeldung. Die Breite musste zweimal erhöht werden, 10 und dann 12 Bit
[CODE-Historie `54a770e`, `8183b67`]. Gleiches Muster bei einem 3-bit-Zähler,
dessen Zielwert 8 nicht darstellbar war [CODE-Historie `1fd63db`], und bei einem
Ringzähler mit 7 statt 8 Bit, der dadurch die Symbolrate verdoppelte
[CODE-Historie `e130673`].

#### F3.6 — Abtastversätze aus dem falschen Burst-Layout übernommen

Der Sprach-Uplink-Burst hat keine Rundfunk-Halbblöcke zwischen Nutzblock und
Trainingsfolge; das Erfassungsmodul hatte die Versätze aus dem Downlink-Layout
übernommen. Folge: erster Nutzblock 7 Symbole zu früh, zweiter 8 Symbole zu
spät abgetastet — 16 verfälschte Randbits in jedem 432-bit-Burst
[MESS 2026-05-17, CODE-Historie `8b0737e`].

#### F3.7 — Maske verwirft die oberen Bits einer Adresse

Eine 24-bit-Teilnehmeradresse wurde mit `0x3FF` maskiert (Altbestand einer
10-bit-Annahme). Jedes Endgerät eines Herstellerbereichs erschien dadurch mit
derselben Adresse; weil das Ergebnis plausibel und konstant war, galt es
zunächst als korrekt (→ F10.3) [CODE-Historie `991ff68`, `f51c89a`].

> **V-17-5** — Jede Feldangabe trägt ihre **Einheit** (Bit, Symbol, Oktett,
> Slot, Frame) und jede Kopf- oder Elementlänge trägt die Bedingungen, unter
> denen ihre Teile anwesend sind, mit Normverweis. Jeder Zähler und jeder
> Bit-Ausschnitt wird aus dem Grenzwert **berechnet**, nicht literal
> geschrieben. Prüfung: (a) jede Bit-Layout-Tabelle trägt an ihrer normativen
> Stelle Einheit und Anwesenheitsbedingung je Feld; (a2) vor jeder Deutung eines
> Restfelds als Protokolltyp wird die **Bitbilanz** „Längenangabe minus
> Kopfbreite" gerechnet — ein 5-bit-Rest kann keine PDU mit > 15 bit
> Pflichtfeldern sein, und genau diese Rechnung hat die Fehllesart „LLC-Typ
> `1000₂` = AL-SETUP" in der Vor-Antwort aufgelöst (`09 §3.1.1`); (b) Testvektor je Anwesenheitsvariante,
> nicht nur für den Standardfall; (c) Syntheseregel: kein literaler
> Bit-Ausschnitt auf einem parametrierten Zähler — die Breite folgt aus dem
> Parameter.

---

### 3.4 F4 — Verwechslung von Zählweisen

Dies ist die häufigste Einzelfehlerquelle in V1 und der Grund, warum die
Konvention in `CONVENTIONS §4` und `00 §2.2` an zwei Stellen normativ steht.

#### F4.1 — Frame- und Multiframe-Nummer nullbasiert gesendet

Die Norm zählt Frames 1…18 [ETSI §9.3.4] und Multiframes 1…60 [ETSI §9.3.7]; die Software
sandte `fn−1` und `mn−1`. Das Endgerät berechnet aus der Multiframe-Nummer den
Zeitschlitz, in dem der Rundfunkkanal liegt: mit falscher Nummer suchte es im
falschen Zeitschlitz, fand die Systeminformation nicht und zeigte eine
flackernde Trägernummer [CODE-Historie `d7423a3`].

#### F4.2 — Einspeisung in den nullbasierten statt den einsbasierten Zeitschlitz

Der Steuerkanal liegt in ETSI-Zählung auf Zeitschlitz 1, im RTL also auf
`tn = 0`; die Einspeisung erfolgte auf `tn = 1`. Dieser Zielschlitz trug einen
Synchronisationsburst, dessen Burst-Multiplexer den ersten Block ignoriert: die
Antwort verschwand spurlos, während alle Zähler korrekte Werte zeigten
(Anfrage = Annahme = Einspeisung = Freigabe = N). Erst der Luft-Mitschnitt
zeigte, dass nichts gesendet wurde [CODE-Historie `d1b70c2`].

#### F4.3 — Rücksetzwert eines Zielschlitz-Registers in der falschen Zählweise

Der Rücksetzwert war `2'd1`, die Zeitplan-Tabelle führt die
Signalisierungsklasse aber nur auf `tn = 0`. Jede Antwort wurde auf einen Slot
geroutet, dessen Inhaltsauswahl sie stillschweigend verwarf: 1 447
aufeinanderfolgende Slots mit 100 % Abdeckung im Luft-Mitschnitt zeigten
ausschließlich den Füllinhalt [CODE-Historie `fc09383`].

#### F4.4 — Zwei Zeitschlitz-Zähler, die um eins auseinanderlaufen

Neben der Zeitbasis existierte ein zweiter Zeitschlitz-Zähler auf oberster
Ebene, der die Ladeoperation der Zeitbasis nicht annahm. Nach dem Hochlauf
drifteten beide um +1 Zeitschlitz: der Burst-Multiplexer las den Zeitplan an
einer Stelle, während der Synchronisations-Encoder die Nummer der anderen
Stelle in die PDU schrieb. Auf der Luft eine Verteilung der Schlitznummern von
{0:51, 1:2, 2:50, 3:50} gegen die Referenzverteilung {0:1, 1:50, 2:51, 3:50}
[GOLD, CODE-Historie `8df58a9`].

#### F4.5 — Der Anker liegt bis heute eine Multiframe daneben

Der Zeitplan-Generator setzt den Synchronisationsburst bei RTL-`mn mod 4 == 2`
[CODE scripts/schedule.py:312], was ETSI `MN mod 4 == 3` entspricht; Norm und
Referenznetz verlangen `MN mod 4 == 2`. Die Testbench prüft **denselben** Wert
[CODE tb/tb_tx_slot_schedule.v:277] und bestätigt damit den Fehler statt ihn zu
finden (→ F10.6). Toleriert, wahrscheinlich weil die übrigen Zeitschlitze in
jedem Frame einen Synchronisationsburst tragen; geführt in `04` O-04-2.

> **V-17-6** — Es gibt genau ein Umrechnungsmodul zwischen ETSI-Zählung
> (1-basiert, in Spec, Software, Protokoll, Bedienoberfläche) und RTL-Zählung
> (0-basiert). Verstreute `±1` sind ein Spec-Verstoß. Jede Konstante, jeder
> Registerrücksetzwert und jeder Tabelleneintrag mit Zeitschlitz-, Frame- oder
> Multiframe-Bezug trägt die Zählweise im Namen oder im unmittelbaren
> Kommentar. Prüfung: (a) Textsuche nach `+ 1`/`- 1` auf Signalen mit `tn`,
> `fn`, `mn` im Namen außerhalb des Umrechnungsmoduls schlägt fehl; (b) für
> jeden Zeitbezug existiert genau ein Zähler — zwei Zähler derselben Größe sind
> ein Befund (`04`, `08`); (c) Zeitplan-Einträge werden aus dem Normausdruck
> **berechnet** und gegen den Generator verglichen, nicht aus ihm kopiert
> (→ V-17-15).

---

### 3.5 F5 — Doppelte Implementierungen und ihr Auseinanderdriften

#### F5.1 — Zwei unterschiedliche Generatormatrizen für denselben Blockcode

**Ursache.** Der (30,14)-Blockcode des Zugriffszuweisungskanals existiert im Baum
in zwei **inhaltlich verschiedenen** Ausprägungen. Der Sendepfad verwendet die Matrix der Norm
[ETSI §8.2.3.2, Gl. 8.12 — systematische Form `[I₁₄ | P]`; verifiziert:
Zeile 1 der Paritätshälfte `1001101101100000` = `0x9B60`, identisch zu
[CODE rtl/tx/tetra_aach_rm_encoder.v:51]]. Der Empfangs-Codec verwendet eine
davon unabhängig konstruierte Matrix in Monom-Basis
[CODE rtl/lmac/tetra_reed_muller.v:80-93].

**Wirkung.** Die von beiden Matrizen erzeugten Codes sind **disjunkt**: die
Schnittmenge der beiden Codewort-Mengen à 16 384 Wörter besteht nur aus dem
Nullwort [ANNAHME: Rechnung — beide Zeilenräume vollständig aufgespannt (je
2¹⁴ Linearkombinationen der 14 zitierten `localparam`-Zeilen) und geschnitten;
aus den beiden Belegstellen nachrechenbar, aber weder simuliert noch gemessen].
Ein Decoder mit der zweiten Matrix hätte kein einziges gesendetes Codewort
korrekt decodiert. Wirkungslos geblieben ist das nur, weil das Modul nicht
instanziiert ist (→ F6.4). Zusätzlich existiert die Sendematrix selbst an **drei
Orten im Betriebscode** — zweimal im RTL
[CODE rtl/tx/tetra_aach_encoder.v:128, rtl/tx/tetra_aach_rm_encoder.v:51] und
einmal live in Software als `rm_30_14_gen[14][16]`
[CODE sw/tetra_hal.c:387], von dort über `tetra_rm3014_init` in Zeilenworte
gewandelt und bei jedem AACH-Wort benutzt
[CODE sw/tetra_hal.c:406-421, :478, :498, Aufruf :1716] — sowie an zwei
weiteren Orten in Werkzeugskripten
[CODE scripts/gen_aach_reference.py:29-30, scripts/decode_dl.py:134]. Alle fünf
Kopien sind bit-gleich (Zeile 1 der Paritätshälfte `0x9B60`), RTL gegen RTL ist
per Testbench geprüft — aber es sind fünf Orte für eine Wahrheit, davon drei im
laufenden Betrieb. Beide RTL-Modulköpfe verweisen dabei auf ein Symbol
`RM_30_14_GEN` in `sw/tetra_hal.c`
[CODE rtl/tx/tetra_aach_encoder.v:126, rtl/tx/tetra_aach_rm_encoder.v:47-48];
unter diesem Namen existiert es dort **nicht** — die Software schreibt
`rm_30_14_gen` klein, `RM_30_14_GEN` steht nur im Skript
[CODE scripts/gen_aach_reference.py:29] (→ F9.4).

**Wie erkannt.** Nicht durch einen Test, sondern durch Nachrechnen beim
Schreiben dieser Spezifikation. Beide Matrizen haben das gleiche
Mindestgewicht 8 (→ F10.5, dort mit dem Rechenbeleg); jede Selbstprüfung auf
„mathematische Eigenschaften" bestätigt beide.

#### F5.2 — Kanalcodierung für Nutzdaten bit-gleich zweimal, beide live

**Ursache.** Die SCH/F-Codierkette existiert einmal in RTL und einmal in C
[CODE sw/tetra_channel_codec.c:131], beide im laufenden Betrieb.

**Wirkung.** Jede Änderung muss an zwei Orten bit-identisch nachgezogen werden.
Bit-Drift ist eine Frage der Zeit. V2 löst das im Architektur-Schnitt: die
Codierung existiert genau einmal, in Software (00 §1.1, §3.6).

#### F5.3 — Zwei Varianten der Klassen-Umsortierung im Sprachpfad

**Ursache.** Die live laufende Funktion ordnet die Sprachbits **paarweise**
(Bit aus Rahmen 1, Bit aus Rahmen 2 direkt hintereinander)
[CODE sw/tetra_bs_tch_s.c:47-65]. Eine zweite, nicht aufgerufene Variante
ordnet **rahmenweise** innerhalb jeder Klasse
[CODE sw/tetra_tch_s_codec.c:158-170]; ihr Kommentar widerspricht sich dabei
selbst: „interleaved per ETSI" … „is actually frame-by-frame"
[CODE sw/tetra_tch_s_codec.c:150-156].

**Wirkung.** Bisher keine — die falsche Variante wird nicht aufgerufen. Als
Vorlage für den Nachbau ist sie eine Falle, und ihr Kommentar behauptet
Normkonformität für das Gegenteil dessen, was der Code tut. Geführt in
`05 §6 O-05-4`.

#### F5.4 — Drei Wege, auf denen eine DL-PDU auf die Luft gelangt

Signalisierungs-Warteschlange, Sprach-Füller-Mailbox unter Umgehung der
Warteschlange, Rundfunkpfad. Kein Ort, an dem vollständig sichtbar ist, was
gesendet wird; Fehlersuche muss drei Pfade prüfen (00 §1.1). V2: genau ein Pfad
(00 §3.6).

#### F5.5 — Ein Zellparameter an zwei Orten

Die Standortkennung wurde im Rundfunk als 1 verkündet und in der
Anmeldebestätigung als 36 zurückgegeben; das Endgerät verwarf die Bestätigung.
Die Zähler zeigten dabei korrekte Werte — die Bestätigungen wurden erzeugt, sie
waren nur nicht annehmbar [CODE-Historie `239e225`].

> **V-17-7** — Jede Konstante, jede Codiertabelle, jede Codierkette und jeder
> Zellparameter existiert an **genau einer** Stelle (P2). Wo eine zweite
> Implementierung technisch unvermeidlich ist (Referenzimplementierung für die
> Verifikation), ist sie als solche benannt, sie läuft **nicht** im Betrieb, und
> ein Test vergleicht beide bit-weise. Prüfung: (a) Textsuche nach
> Generatorpolynomen, Matrixzeilen und Schwellwert-Literalen darf jeden Wert
> nur einmal außerhalb der generierten Dateien finden; (b) für jede bewusst
> doppelte Implementierung existiert ein Gleichheitstest über einen
> vollständigen Vektorsatz, und die zweite Kopie ist nicht in die
> Betriebs-Bauliste eingetragen.

---

### 3.6 F6 — Halb durchgezogene Umbauten

#### F6.1 — Eine Korrektur an zwei von drei Stellen

Der Ausrichtungsfehler aus F2.1 wurde an zwei Erzeugern behoben, am dritten
nicht: der schreibt bis heute LSB-ausgerichtet
[CODE rtl/lmac/tetra_pre_reply_blck.v:209] und ist an den Erzeuger-Anschluss der
Warteschlange angeschlossen [CODE rtl/tetra_zynq_top.v:2528-2531]. Ein
Luft-Befund dazu liegt nicht vor [ANNAHME: Auslösebedingung dieses Erzeugers
greift in der Betriebskonfiguration nicht — der Code-Befund ist belegt, die
Wirkung nicht].

#### F6.2 — Grüne Testbenches auf einem nicht verdrahteten Pfad

Ein Umbau meldete „zwei verkettete MAC-PDUs" mit 62 von 62 grünen Testbenches.
Die Telemetriefelder der zweiten PDU waren durch Warteschlange und Planer
geführt, aber nicht bis zum Encoder verdrahtet: auf der Luft erschien nur die
erste PDU. Die Testbenches prüften Steuerpfad-Ausgänge, nicht das Ergebnis; der
Fehler wurde ausschließlich durch Analyse eines Luft-Mitschnitts gefunden
[CODE-Historie `197cfc0`].

#### F6.3 — Ports und Untermodule „für später" stehen gelassen

Wiederholtes Muster: „Port bleibt am Modul-Interface (kein Port-Break in diesem
Commit), Cleanup separat" [CODE-Historie `d35e3ef`, `fc123a3`]; Untermodule
instanziiert mit lauter Nullen an den Eingängen, „damit eine spätere Phase sie
treiben kann" [CODE-Historie `60ad13a`]. Folge: ein Modulname behauptet eine
Funktion, die er nicht hat — die Anmelde-Zustandsmaschine ignoriert **alle**
ihre Uplink-Eingänge, die Entscheidungslogik liegt in Software, der Name ist
historisch [docs/IST.md §Drift 8].

#### F6.4 — Modul in der Bauliste, aber nicht instanziiert

Ein Lower-MAC-Modul wurde aus der obersten Ebene entfernt
[CODE-Historie `b92f47e`], blieb aber in der Synthese-Quellenliste
[CODE scripts/vivado_build.tcl:149]. Es ist der einzige Zugang zu zwei weiteren
Modulen, darunter dem Blockcode-Decoder aus F5.1. Im Top-Modul kommt der Name
nur noch in Kommentaren vor [CODE rtl/tetra_zynq_top.v:14, :35]. Wer die
Quellenliste liest, hält den Teilbaum für aktiv und den Blockcode-Decoder für
den gültigen Decoder.

#### F6.5 — Eingriff in funktionierenden Code ohne Nutzen

In die laufende Anmelde-Zustandsmaschine wurde ein Ablehnungs-Zweig samt vier
Zuständen und lokalem Encoder eingebaut, obwohl der Ablehnungspfad in der
Betriebskonfiguration nie ausgelöst wird. Zweimal zurückgenommen, mit
ausdrücklicher Begründung: an dieser Zustandsmaschine ohne aktuellen Nutzen zu
arbeiten sei unnötiges Risiko [CODE-Historie `37c1c97`, `5132e00`].

#### F6.6 — Bekannte Resteinschränkung als „nächste Phase" vertagt

Eine Sprach-Übersteuerung wurde auf die Frames 1–9 begrenzt, weil sie in den
übrigen Frames nicht zum angekündigten Burst-Typ passte; die verbleibende
Möglichkeit, in Frames 10–17 Fehlanpassungs-Inhalt zu puffern und im nächsten
Multiframe veraltet auszusenden, wurde mit einer Zwei-Frame-Zeitüberschreitung
begrenzt und als „Phase D" vertagt [CODE-Historie `2ceb141`]. Das Vertagte wurde
nicht gebaut; der gesamte Pfad wurde später aus einem anderen Grund entfernt
[CODE-Historie `e8efb31`].

> **V-17-8** — Ein Umbau ist fertig, wenn **alle** Erzeuger und Verbraucher der
> geänderten Vereinbarung nachgezogen sind, kein Port ohne Funktion bleibt und
> kein Modul in der Bauliste steht, das nicht instanziiert ist. „Cleanup
> separat" ist kein zulässiger Abschluss. Prüfung: (a) Abnahme eines Umbaus
> verlangt die Liste aller Erzeuger/Verbraucher der geänderten Vereinbarung mit
> Status je Stelle; (b) Bau-Gate vergleicht Quellenliste gegen die tatsächlich
> instanziierte Hierarchie und schlägt bei Differenz fehl; (c) jede Abnahme
> eines Datenpfads verlangt einen Nachweis **am Ausgang** (Luft-Mitschnitt oder
> Ende-zu-Ende-Simulation), nicht nur an Steuerpfad-Ausgängen.

---

### 3.7 F7 — Zeit- und Reihenfolgefehler

#### F7.1 — Vorausschau fehlt: Encoder braucht länger als das Latch-Fenster

Der Burst-Multiplexer übernimmt Nutzlastregister etwa zwei Takte nach dem
Slot-Puls; die betreffenden Encoder brauchen 142 Takte, und beide wurden mit dem
Tupel des **aktuellen** Zeitschlitzes gestartet. Der Multiplexer bekam die Daten
der vorherigen Codierung: die Schlitznummer in der gesendeten PDU lief der
tatsächlichen Luftlage um einen Zeitschlitz nach. Korrektur: Codierung mit dem
Tupel des **nächsten** Zeitschlitzes starten [CODE-Historie `8c79123`].

#### F7.2 — Übersteuerung eine Frame zu spät sichtbar

Eine registrierte Übersteuerung des Trainingsfolgen-Typs verlor ein
modulübergreifendes Wettrennen: der Verbraucher übernimmt am selben
Taktzeitpunkt, an dem das Anwesenheitssignal steigt, und sah den alten Wert.
Alle 148 Bursts des Mitschnitts trugen den falschen Trainingsfolgen-Typ, obwohl
der Einspeisezähler 19 zählte. Das Endgerät klassifiziert den Blockaufbau **nach
der Trainingsfolge** [ETSI §9.4.4.3.2, Tabelle 9.13] und versuchte deshalb,
einen Vollblock als zwei Halbblöcke zu decodieren — beide Prüfsummen falsch
[CODE-Historie `9cdea64`, `338242d`].

#### F7.3 — Fünf Anläufe an einem Wettrennen zwischen Rumpf und Ankündigung

**Ursache.** Rumpf und Zugriffs-Ankündigung eines Slots kamen über getrennte
Latch-Stufen aus derselben Warteschlange und wurden von den Verbrauchern in
leicht verschiedenen Taktphasen gelesen.

**Wirkung.** Der Rumpf erschien in Frame N, die Ankündigung in Frame N+1. Das
Endgerät sah eine Antwort mit Leerlauf-Ankündigung und nahm sie nicht an. Die
Folge der Anläufe: ein atomares Sammel-Latch; ein paralleler
Umgehungspfad, der das Problem **maskierte** statt es zu beheben und dabei den
vorherigen Übersteuerungspfad brach; ein Vollumbau auf einen linearen Pfad ohne
Latch; eine Pipeline-Stufe gegen die daraus entstandene Zeitverletzung, die die
Vorabholung des Slot-Multiplexers ungültig machte (Zähler stiegen, 0
Signalisierungs-Bursts auf der Luft); Rückrollen auf den linearen Pfad mit
einem einzelnen Register hinter dem Blockcodierer
[CODE-Historie `c7204d9`, `195974f`, `29521db`, `737fa1a`, `ec40f4d`]. Danach
zwei weitere Korrekturen an derselben Stelle: Ankündigungs-Anwesenheit direkt
aus dem Warteschlangenkopf statt aus einem 216-bit-Inhaltsvergleich
[CODE-Historie `c2d59cd`], und Vergleich gegen den **aktuellen** statt den
vorausgeschauten Zeitschlitz, weil der Umgehungs-Codierer kombinatorisch ist
und keine Vorausschau hat [CODE-Historie `def6f79`].

**Lehre.** Fünf Anläufe, weil jeder Anlauf das Symptom adressierte. Die
Ursache war strukturell: **zwei Wege für einen Slot-Inhalt** und keine
festgelegte Übernahmephase.

#### F7.4 — Freilaufende Latches gegen ereignisgetriggerte Übernahme

Elf Ausgangsregister des Slot-Multiplexers übernahmen in **jedem** Takt die
kombinatorische Sicht auf den Warteschlangenkopf. Im selben Taktzeitpunkt, in dem
die Entnahme den Kopf weiterrückte, übernahmen sie schon den neuen (leeren)
Wert — der Rumpf war weg, bevor der Sendepfad ihn abholte. Nur etwa 14 % der
Rümpfe erschienen auf der Luft, bei sauber steigenden Einspeise- und
Entnahmezählern. Korrektur: Übernahme genau einmal pro Frame in einer
definierten Phase [CODE-Historie `7bf2dd5`].

#### F7.5 — Zwei Verbraucher eines zerstörend gelesenen Statusbits

Ein Überwachungsdienst löschte ein Sticky-Bit nach jeder Protokollzeile, ein
zweiter Dienst benutzte dasselbe Bit als Gültigkeitstor. Der zweite sah
`valid = 0`, obwohl der Zähler weiterlief: jede zweite Ruf-PDU wurde
verschluckt, das Endgerät meldete „Sprechwunsch abgewiesen". Korrektur:
Gültigkeitstor entfernt, Auswertung allein über den Zähler
[CODE-Historie `9829605`, `acbd29c`].

#### F7.6 — Antwort eine Frame zu früh

Der Abstand zwischen Vorab-Antwort und Bestätigung war mit 4 Slot-Pulsen
(1 Frame) angesetzt; die Referenz zeigt in drei unabhängigen Paaren 8 Slot-Pulse
(2 Frames). Die Bestätigung kam eine Frame zu früh, der MAC-Zustand des
Endgeräts war inkonsistent [GOLD, CODE-Historie `1fd63db`]. Die Lehre ist
**nicht** der Wert 8: ein abgezählter Abstand ist immer die Wette, dass die
Zusammensetzung bis dahin fertig ist. V2 löst die Klasse, nicht den Wert — die
Bestätigung wird durch „Kette vollständig oder Fenster abgelaufen" ausgelöst und
kennt keinen Abstandszähler (`08 §3.5.2`, `08` R-08-11, `04` R-04-21).

#### F7.7 — Späte Einspeisung im laufenden Frame verworfen

Der Freigabe-Puls feuerte bedingungslos am Zeitschlitz-Puls des
Nachfolgeschlitzes. Eine Einspeisung, die **nach** dem Puls des Zielschlitzes
eintraf — der Normalfall, wenn die Codierung in diesem Fenster fertig wird —
setzte die Anwesenheit zu spät: die Freigabe warf die Nutzlast weg, bevor sie je
übernommen wurde. Verlorene Antworten ohne Fehleranzeige. Korrektur: zweistufige
Anwesenheit, späte Einspeisungen überleben in den nächsten Frame
[CODE-Historie `fac838b`].

#### F7.8 — Zeitgeber der UL-Zusammensetzung am Empfangs-Lock des Downlinks

Der Frame-Takt für die Zeitüberschreitungen der Uplink-Zusammensetzung wird aus
Wertwechseln des Frame-Zählers der **Downlink-Empfangskette** gebildet, und
dieser Zähler zählt nur bei Korrelator-Verriegelung. Ohne Verriegelung steht der
Frame-Takt, die Zeitüberschreitung läuft nie ab, Zusammensetzungs-Einträge
verfallen nie — im Air-Test unauffällig, bis zwei Fragmente derselben Adresse
kollidieren. Ausführlich in `02` O-02-2; V2 entkoppelt über den Zeitstempel
(R-00-04) und die Sende-Zeitbasis (R-02-08).

> **V-17-9** — Für jeden Wert, den ein Slot-gebundener Verbraucher liest, ist
> die **Übernahmephase** normativ festgelegt (welcher Puls, welcher Takt
> danach) und alle Werte eines Slots werden in derselben Phase übernommen.
> Keine freilaufenden Ausgangsregister auf Warteschlangen-Sichten. Ein
> Statusbit hat genau einen Verbraucher, oder das Löschen ist vom Lesen
> getrennt. Kein Zeitgeber wird aus einem Empfangs-Verriegelungszustand
> gespeist. Prüfung: (a) `08_TIMING` führt je Verbraucher Puls und
> Taktversatz; (b) Simulation mit Einspeisung in jeder Taktphase des
> Zeitschlitzes — kein Inhalt darf verloren gehen; (c) `07` führt je
> Statusregister die Spalte „Verbraucher" und „Löschverantwortung".

---

### 3.8 F8 — Empirische Werte, ohne Messung geändert

#### F8.1 — Ein Register für zwei Korrelatoren

Downlink- und Uplink-Korrelator teilten einen Schwellwert. Die Obergrenze, gegen
die dieser Schwellwert wirkt, ist die **Länge des Suchmusters**: der
Steuerburst-Korrelator läuft mit der Vorbelegung `SYNC_LEN_SYM = 15` (x-Folge)
[CODE rtl/rx/tetra_ul_sync_detect_os4.v:54, Instanz ohne Übersteuerung
rtl/rx/tetra_rx_chain.v:363-366], sein Zählerausgang erreicht also höchstens 15.
Der gemeinsame Vorbelegungswert 15 sättigt diesen Vergleich damit vollständig,
sodass nur exakte Übereinstimmungen auslösen: ~75 % der echten Bursts verworfen,
3 von 12 gefunden, wo der Offline-Decoder 12 von 12 fand. Zum Messzeitpunkt war
der Zählerausgang zusätzlich auf 4 Bit abgeschnitten und der Vergleich lief über
`corr_threshold_sys[3:0]` [Stand 2026-04-25: CODE-Historie `5675cd6`, Z.161,
:203, :205]; heute ist der Zähler 5 Bit breit, der Vergleich läuft über
`corr_threshold_sys[4:0]` und Werte > 31 sperren das Auslösen ganz
[CODE rtl/rx/tetra_ul_sync_detect_os4.v:167, :209-211]. An der Sättigung bei 15
ändert das nichts — sie folgt aus der Musterlänge, nicht aus der Feldbreite. Die
getrennten Register wurden eingeführt, gingen mit F1.2 wieder verloren und
fehlen heute; DL- und UL-Steuerkorrelator hängen weiterhin an einem Register
[CODE rtl/tetra_zynq_top.v:567] [MESS 2026-04-25, CODE-Historie `5675cd6`,
`f2af067`].

#### F8.2 — Ein Hilfetext als Wertequelle

Ein Skript nannte in seiner Hilfezeile einen veralteten Vorbelegungswert 20 für
denselben Schwellwert; Aufrufe übernahmen ihn. 20 liegt über der Musterlänge 15,
der Vergleich kann nie erfüllt werden: null Erkennungen — zum damaligen Stand
(4-bit-Vergleich) über das Sperrtor `corr_threshold_sys[CORR_WIDTH-1:4]`, heute
(5 Bit) über den Zählerausgang selbst; in beiden Fällen null. Der
Vorbelegungswert des FPGA war zu diesem Zeitpunkt bereits korrekt 13
[CODE-Historie `db28878`].

#### F8.3 — Zeitüberschreitung ohne Messkontext verkürzt

Eine Sprach-Stille-Zeitüberschreitung wurde in drei Schritten verändert
(15 s → 500 ms → 200 ms), jeweils mit sachlicher Einzelbegründung. Bei 200 ms
griff die Überwachung **mitten** in aktivem Sprechen, weil vereinzelte Lücken bei
~203 ms lagen: das Endgerät sah „Sprechwunsch abgewiesen". Der Wert steht heute
auf 300 ms; 1 000 ms wurde gemessen und war schlechter
[MESS 2026-05-17, CODE-Historie `00228e7`, `cccf4a9`, `326439d`].

#### F8.4 — Zwei Zeitüberschreitungen für zwei Zwecke, als eine behandelt

„Kanal schließen" und „Reservierung freigeben" hingen zunächst an einem Wert.
Die 5-s-Freigabe war zu kurz — das Endgerät sendet seinen Abbauwunsch oft 2–7 s
nach Sprechende, der Slot war dann bereits freigegeben und der Handler griff
still nicht (7 Wiederholungen des Abbauwunsches). Getrennt: Kanal 300 ms,
Reservierung 30 s [CODE-Historie `cccf4a9`, `acbd29c`, 2026-05-24].

Die 30 s hielten einen Tag. Mit der Per-Slot-Stille-Erkennung wurde die
Reservierung wieder auf **5 s** gesetzt — zuerst als „temporär für Messtests,
danach zurück auf 30 s" [CODE-Historie `942e31d`, 2026-05-25], dann ohne neue
Messreihe zum Dauerzustand umgeschrieben, mit der Begründung, ein verspäteter
Abbauwunsch werde vom Endgerät wiederholt und richte im Multi-Gruppen-Betrieb
keinen Schaden an [CODE-Historie `f6db8d3`; heutiger Stand
CODE sw/tetra_call_fsm.h:44-48]. Das ist der eigentliche Fall dieser Klasse: die
Ankündigung „temporär" wurde nicht durch eine Messung eingelöst, sondern durch
eine umgeschriebene Kommentarzeile. Beide Werte haben einen belegten Nachteil —
30 s kostet definitionsgemäß 30 s bis zur Neuzuweisung, 5 s erzeugt wiederholte
Abbauwünsche — und für keinen der beiden liegt eine Messreihe vor, die die
jeweilige Kehrseite quantifiziert. Für V2 ist dieser Wert damit **nicht**
übernehmbar, sondern neu zu messen (V-17-10); der Abbauwunsch braucht zusätzlich
einen Zähler für „traf auf freigegebenen Slot", damit die Kehrseite überhaupt
sichtbar wird (P6).

#### F8.5 — Verstärkungsanpassung als Konstante ohne Messkontext

Der CIC-Verstärkungs-Shift war 6 (×64), weil das für den **digitalen
Schleifentest** der richtige Arbeitspunkt war; für das Luft-Signal sättigt er
die Bursts bei Regelungs-Einschwingvorgängen. Prüfsummen-Erfolg 27 % gegen 93 %
bei Shift 4. Der Wert steht heute als festverdrahtete Konstante ohne Register
[CODE rtl/rx/tetra_rx_frontend.v:135], und der Modulkopf nennt weiterhin 6
[CODE rtl/rx/tetra_rx_frontend.v:21] [MESS 2026-05-23, CODE-Historie `f2af067`].

> **V-17-10** — Ein empirisch gefundener Wert wird nur mit seinem
> **Messkontext** übernommen: Wert, Messgröße, Messdatum, und das gemessene
> Verhalten bei den Nachbarwerten. Ein Wert ohne diese Begleitung darf nicht
> geändert werden. Zwei Verbraucher mit unterschiedlichem Arbeitspunkt bekommen
> zwei Register — nie eines. Kein Hilfetext, kein Kommentar und keine
> Beispielzeile ist eine Wertequelle. Prüfung: (a) jeder Wert aus §4 steht mit
> allen vier Angaben in genau einem Kapitel; (b) ein Änderungsvorschlag ohne
> neue Messreihe wird abgelehnt; (c) Textsuche nach Schwellwert-Literalen in
> Skripten und Hilfetexten schlägt fehl — Skripte lesen den Wert aus der
> Konfiguration.

---

### 3.9 F9 — Dokumentation, die vom Code abgewichen ist

Diese Klasse wurde bei der Arbeit an dieser Spezifikation **mehrfach neu**
gefunden. Sie ist deshalb kein Randthema.

#### F9.1 — Registerbeschreibung kennt vorhandene Register nicht

Vier Register für die Zugriffs-Ankündigung je Zeitschlitz sind in RTL
[CODE rtl/infra/tetra_axi_lite_regs.v:892-895] und in der HAL
[CODE sw/tetra_hal.h:343-346] auf 0x2A0…0x2AC definiert. Die Registerkarte in
der Ist-Dokumentation endet bei 0x28C und kennt sie nicht
[docs/ist/08_axi_regmap.md, kein Treffer auf `0x2A0` oder `SLOT_AACH`]. Wer sie
als Adressquelle nimmt, hält den Adressbereich für frei.

#### F9.2 — Zwei Dateien im selben Verzeichnis, die sich widersprechen

`docs/local_cell_decode/` enthält zwei Auswertungen desselben Vergleichs. Die
eine führt Status nach: ein Befund gefixt und bit-exakt verifiziert, ein zweiter
auf Nutzerbestätigung als **Nicht-Fehler** („die Gruppenadresse ist absichtlich
so konfiguriert"), ein dritter als Fehldiagnose verworfen
[docs/local_cell_decode/BUGS_LIST.md:16-28, 64-66, 111-131]. Die andere führt
**zwei** der drei weiterhin unter der Überschrift „Bestätigte Bugs (bit-exakt
nachgewiesen)" mit rotem Schweregrad — darunter genau den auf Nutzerbestätigung
als Nicht-Fehler abgeschlossenen Gruppenadress-Befund
[docs/local_cell_decode/DIFF_vs_reference.md:227, :229, :240]. Der dritte Befund
ist in derselben Datei korrekt nachgeführt: durchgestrichen und ausdrücklich als
verworfen markiert [docs/local_cell_decode/DIFF_vs_reference.md:225]. Das
Nachführen war also möglich und ist an einer Stelle geschehen — nur nicht am
roten Eintrag. Ein Leser, der die zweite Datei zuerst liest, arbeitet an einem
Nicht-Fehler. Genau davor warnt `CONVENTIONS §7`.

#### F9.3 — Analyse sucht den Fehlerort in fremdem Code

Dieselbe Auswertung benennt für Defekte **unserer** Station Dateien einer
externen Referenz-Implementierung als Fixort — für die Anmeldebestätigung, für
die Gruppenadresse und für die Antwortlatenz
[docs/local_cell_decode/DIFF_vs_reference.md:182, :190, :249-250; für die
Anmeldebestätigung und die Antwortlatenz zusätzlich in BUGS_LIST.md:39-58,
:151]. Für die Gruppenadresse führt `BUGS_LIST.md` dagegen vor, wie es richtig
geht: der fremde Code wird nur als Vergleich zitiert und ausdrücklich als korrekt
eingeordnet [BUGS_LIST.md:87-96, „Korrektes Verhalten."], und der Fixort liegt
außerhalb jedes Codes [BUGS_LIST.md:99: „**NICHT** in BlueStation. **Im
MS-Codeplug**"]. Dieselbe Untersuchung verortet denselben Befund also in einer
Datei richtig und in der anderen falsch — genau deshalb fordert V-17-13 **eine**
Befund-Datei je Untersuchung. Der Anmeldebefund war tatsächlich in
**unserem** RTL festverdrahtet und wurde dort behoben
[CODE-Historie `d5b3589`]. Der Latenzbefund wurde durch Umbau **unseres**
Antwortpfads von blockierend auf nicht-blockierend behoben
(Median 0,95 s → 0,58 s, Wiederholungen 30 % → 11 %)
[MESS 2026-05-17, CODE-Historie `3c7c320`]. Beide Male zeigte die Analyse in die
falsche Richtung; die Zeit ging beim Suchen verloren. Dies ist P7 als
Dokumentationsfehler: „Der Fehler liegt im eigenen Code" gilt auch für die
Fehlerbeschreibung.

#### F9.4 — Modulkommentare mit anderen Zahlen als der Code darunter

Fünf belegte Fälle:

| Ort | Kommentar sagt | Code sagt |
|---|---|---|
| Sprachburst-Erfassung | Sync-Anker auf Burst-Symbol **132** [CODE rtl/rx/tetra_ul_nub_capture.v:6-8] | eigenes Layout im selben Kopf: Trainingsfolge auf Modul-Bit 220…241 (0-basiert, Kopf zählt ab „bits 0..3") = ETSI BN 221…242 (1-basiert) = Symbol 111…121 (1-basiert) [CODE rtl/rx/tetra_ul_nub_capture.v:16], ETSI-Geometrie ergibt ebenfalls 121 [`08` O-08-1] |
| Empfangs-Frontend | Verstärkung **×64** (Shift 6) [CODE rtl/rx/tetra_rx_frontend.v:21] | Shift **4** = ×16 [CODE rtl/rx/tetra_rx_frontend.v:135] |
| HAL, UL-Rumpf-Mailbox | **129**-bit-Rumpf in W2…W5, Typfeld in W0[7:4] [CODE sw/tetra_hal.h:279-296] | **147**-bit-Rumpf in W2…W6, 13-bit-Metabündel in W0[12:0] [CODE rtl/lmac/tetra_ul_demand_body_mailbox.v:5,17-26], und der Software-Leser folgt dem Modul [CODE sw/tetra_attach_daemon.c:103-124] |
| MAC-Kopf-Aufbau | Summe „= 42" | derselbe Ausdruck ergibt 43; bei der Berechnung eines Prüfvektors wurde das zur Falle [CODE-Historie `fc123a3`] |
| AACH-Encoder, Generatormatrix | Kopf nennt als Quelle `RM_30_14_GEN` in `sw/tetra_hal.c` [CODE rtl/tx/tetra_aach_encoder.v:126, rtl/tx/tetra_aach_rm_encoder.v:47-48] | dort heißt das Array `rm_30_14_gen`, klein [CODE sw/tetra_hal.c:387]; `RM_30_14_GEN` existiert nur im Skript [CODE scripts/gen_aach_reference.py:29] — der Kopf verweist auf eine Quelle, die es unter diesem Namen nicht gibt (→ F5.1) |

Der dritte Fall hat eine Zusatzpointe: die korrigierende Ist-Dokumentation warnt
korrekt vor der veralteten HAL-Angabe [docs/ist/07_mailboxes.md:254-256], nennt
aber 14 Zeilen darüber selbst wieder die veraltete Zahl
[docs/ist/07_mailboxes.md:240].

#### F9.5 — Dokumentierter Widerspruch, der nicht mehr existiert

Die Ist-Dokumentation führt eine Bausteinvariante-Diskrepanz zwischen
Simulations- und Bau-Skript als Auffälligkeit [docs/IST.md:243]; beide Skripte
verwenden denselben Baustein [CODE scripts/vivado_sim.tcl:163,
scripts/vivado_build.tcl:38]. Ein behaupteter Fehler, der Prüfzeit kostet und
keinen Gegenstand hat. Dasselbe Muster umgekehrt: eine Fehlertabelle führt eine
Korrektur, die „später als Fehler identifiziert" wurde, ohne den heutigen Zustand
zu nennen [docs/ARCHITECTURE.md:513].

#### F9.6 — Ein Adressfenster in zwei Größen

Der Prozessorblock ist auf 512 MiB Arbeitsspeicher konfiguriert, die
Adressfenster der Speicherzugriffs-Einheit weisen je 1 GB zu
[01 §6, O-01-6 mit Belegen]. Mit Entfall dieses Pfads in V2 wirkungslos, als
Widerspruch aber ein Beispiel dafür, dass zwei Werkzeugquellen (Blockdesign und
Erzeugungsskript) dieselbe Größe unterschiedlich behaupten können, ohne dass ein
Bau fehlschlägt.

> **V-17-11** — Registeradressen und Mailbox-Layouts stehen an **einer**
> normativen Stelle (`07`), Bit-Layouts an ihrem Fachkapitel, und werden aus einer
> maschinenlesbaren Quelle in HDL-Header, HAL-Header und Testvektortabelle
> **erzeugt**. Prosa wird nicht als Quelle geparst. Prüfung: Bau-Gate
> vergleicht Erzeugnis gegen die normative Tabelle und schlägt bei Differenz
> fehl (`07` O-07-5).
>
> **V-17-12** — Ein Modulkopf, der Zahlen nennt, nennt genau die Zahlen des
> Codes darunter. Prüfung: Werte, die im Kopf erklärt werden, stehen als
> Parameter oder `localparam` im Modul und werden im Kopf **per Namen**
> zitiert, nicht als Literal wiederholt.
>
> **V-17-13** — Eine Befund-Datei hat einen Status je Eintrag (offen / behoben /
> als Nicht-Fehler verworfen / Fehldiagnose) und es gibt je Untersuchung genau
> **eine** solche Datei. Ein Befund benennt als Fehlerort ausschließlich Code
> des eigenen Systems; Referenz-Implementierungen werden als Vergleich zitiert,
> nie als Fixort (P7). Prüfung: Review-Gate — ein Befund ohne Status oder mit
> einem Fixort außerhalb von `rtl/`, `sw/`, `scripts/` wird abgelehnt.

---

### 3.10 F10 — Werkzeuge, die falsche Befunde erzeugt haben

#### F10.1 — Der Referenz-Decoder führt einen Bursttyp nicht durch die oberen Schichten

**Ursache.** Der Decoder, mit dem die Referenz-Aufzeichnung erzeugt wurde,
rief für den Halbblock-Bursttyp nur den MAC-Parser auf, nicht die
LLC-/MLE-/Anwendungsschicht — anders als für den Vollblock-Typ.

**Wirkung.** In der Aufzeichnung liegen **27 adressierte** Halbblock-PDUs, die
den MAC-Parser durchlaufen haben und deren obere Schichten leer sind: 1 969
Bursts dieses Typs haben MAC-Einträge, **keiner** hat einen LLC-Eintrag,
während alle 28 Vollblock-Bursts mit MAC auch LLC tragen und 24 davon eine
Anwendungs-PDU [GOLD docs/reference_decode/dl_events.jsonl, Auszählung über
alle 7 338 Bursts]. Die Bestandsaufnahme dieser Aufzeichnung enthält deshalb
für Rufabbau- und Sprechrecht-PDUs **keine Zeile** — nicht weil sie fehlten,
sondern weil sie nie ausgewertet wurden
[docs/local_cell_decode/DIFF_vs_reference.md:37-43].

**Der Beweis, dass es ein Werkzeugfehler war.** Derselbe Mitschnitt, mit dem
korrigierten Decoder neu ausgewertet: Sprechrecht-Ende 0 → 2, Rufabbau 0 → 12
[CODE-Historie `1a21801`]. Die PDUs waren auf der Luft. Der Nullbefund war ein
Werkzeugartefakt, und er wurde als Abwesenheit gelesen — bis zu der Feststellung,
dass das Referenznetz diese PDUs über Kanalstehlen auf dem Halbblock-Typ
überträgt, während die eigene Station sie auf dem Vollblock-Typ sandte.

#### F10.2 — Fehlendes Suchmuster im Uplink-Decoder

Der Uplink-Decoder korrelierte nur gegen die erste Trainingsfolge; Bursts mit
der zweiten — genau die, die Kanalstehlen anzeigen
[ETSI §9.4.4.3.2, Tabelle 9.13] — wurden nicht gesucht. Alle gestohlenen
Uplink-Bursts wurden als Sprache klassifiziert: 0 gefundene
Signalisierungs-PDUs. Nach Ergänzung des zweiten Suchmusters und des richtigen
Parser-Pfads: 3 PDUs in 15 s, darunter zwei Rufabbau-Wünsche
[CODE-Historie `212bc38`].

#### F10.3 — Falsch ausgerichteter Parser erzeugt einen plausiblen Wert

Der Uplink-Kopf-Parser las das Adresstyp-Feld mit 3 statt 2 Bit und danach ein
10-bit-Kurzfeld statt der 24-bit-Adresse. Die unteren 10 Bit jeder Adresse eines
Herstellerbereichs ergeben denselben Wert: jedes Endgerät erschien mit derselben
Adresse — konstant, plausibel, und deshalb lange nicht als Fehler erkannt. Die
Antwort wurde an diese Phantomadresse adressiert und erreichte niemanden
[CODE-Historie `f51c89a`, `9accf94`, `991ff68`].

#### F10.4 — Namenstabelle aus der falschen Richtung

Die Namenstabelle für Uplink-Nachrichtentypen war mit der Downlink-Reihenfolge
gefüllt: jede Uplink-Nachricht war falsch benannt, echte Abmeldungen erschienen
als Authentisierungs-Verkehr und wurden bei der Mitschnitt-Auswertung als
Rauschen abgetan [CODE-Historie `f011258`]. Verwandt: eine Anzeigelogik zeigte
eine Ersatz-Interpretation als Hauptbefund, wodurch ein Anmeldewunsch als
Abmeldung protokolliert wurde [docs/local_cell_decode/BUGS_LIST.md:198-203]; und
ein fehlendes optionales Modul führte dazu, dass Ruf-PDU-Namen leer blieben und
der Rohdatenausdruck eine alternative Deutung derselben Bytes zeigte
[CODE-Historie `82ba4de`].

#### F10.5 — Selbstprüfung, die den Fehler nicht sehen kann

Der Generator der Prüfvektoren für den Blockcode aus F5.1 konstruiert die Matrix
selbst und prüft anschließend die **mathematischen Eigenschaften** des
Ergebnisses. Der Dateikopf enthält die ausdrückliche Warnung: „Verify G matrix
against ETSI … before use. Replace G_ROWS with ETSI values if different. d_min
check below verifies the mathematical properties but not ETSI bit-ordering"
[CODE tb/vectors/gen_reed_muller_vectors.py:18-22]. Die Warnung wurde nicht
umgesetzt. Beide Matrizen — die der Norm und die konstruierte — haben dasselbe
Mindestgewicht 8, die Selbstprüfung besteht also in beiden Fällen
[ANNAHME: Rechnung — minimales Hamming-Gewicht über alle 16 383 Codewörter ≠ 0
je Zeilenraum; dieselbe Rechnung wie in F5.1, nicht simuliert]. Die Vektoren
wurden erzeugt, die Testbench war grün, der Code
war nicht normkonform. Der Dateikopf zitiert zusätzlich zweimal den falschen
Normabschnitt (den zum Interleaving statt den zum Blockcode)
[CODE tb/vectors/gen_reed_muller_vectors.py:4,18; korrekt ist ETSI §8.2.3.2].

#### F10.6 — Verifikation, die den Fehler des Prüflings spiegelt

Drei Fälle desselben Musters:

- Die Phasenabbildung zweier Dibits war im Modulator vertauscht — und im
  eigenen Offline-Decoder ebenso. Der Schleifentest war grün, die Prüfsumme
  stimmte, jedes normkonforme Empfangsgerät sah die Dibits vertauscht
  (Bitfehlerrate ~15 %). Die anschließende Korrektur ging in die **falsche**
  Richtung und musste zurückgenommen werden [CODE-Historie `3c51241`,
  `9991c9e`].
- Die Rückkopplungsstellen des Scramblers waren falsch — und im
  Verifikationsskript identisch falsch. Die Simulationsprüfung war grün. Auf
  der Luft: Korrelation 0,990 (Übertragung einwandfrei) bei Bitfehlerrate
  ~15 % und keiner decodierbaren PDU. Eingegrenzt wurde es erst über den
  **Widerspruch** zweier Messungen: 18 von 120 Bitfehlern gegen die Referenz
  nach dem Scrambler, 59 von 120 gegen die Referenz davor
  [CODE-Historie `723a566`]. Der normative Wert steht in
  [ETSI §8.2.5.2, Gl. 8.40] als Polynom `c(x) = 1 + X + X² + X⁴ + X⁵ + X⁷ +
  X⁸ + X¹⁰ + X¹¹ + X¹² + X¹⁶ + X²² + X²³ + X²⁶ + X³²`.
- Die Testbench des Zeitplans spiegelt den Ausdruck des Generators statt ihn
  unabhängig zu berechnen; der Ankerfehler aus F4.5 überlebt beides
  [CODE scripts/schedule.py:312, tb/tb_tx_slot_schedule.v:277].

#### F10.7 — Testbench mit nicht angeschlossenem Eingang

Ein Eingang des Prüflings war in der Testbench nicht verbunden, die
Zustandsmaschine verzweigte in den Standardfall: der Test schlug fehl aus einem
Grund, der nichts mit dem Prüfgegenstand zu tun hatte, und kostete Diagnosezeit
im richtigen Modul [CODE-Historie `8b8cb41`].

#### F10.8 — Werkzeugketten mit unterschiedlicher Strenge

Die Zeichenfolge, die eine Übersetzungs-Anweisung einleitet, stand zusätzlich in
einem normalen Kommentar; der Simulator ignorierte das, der Synthese-Parser
erkannte darin eine Anweisung und lief auf ein nicht geschlossenes Paar. Der
Prüflauf mit dem Simulator war grün, der Bau schlug in einer Stufe fehl, deren
Meldung nicht auf die Ursache zeigte („Modul nicht gefunden")
[CODE-Historie `a76b710`]. Gleiche Klasse: eine Analyse-Auswertung meldete
„inaktiv" für ein Signal, dessen erwartete Aktivität sie mit einer für dieses
System falschen Schwelle verglich [CODE-Historie `7b133f6`].

> **V-17-14** — Kein Befund, der sich auf **Abwesenheit** stützt, ohne
> Positivkontrolle des Werkzeugs. Für jeden Bursttyp, jeden Kanal und jede
> PDU-Klasse, die ein Auswertungswerkzeug abdeckt, weist es an einem
> selbst erzeugten Rundlauf-Vektor nach, dass es die Klasse durch **alle**
> Schichten führt; Klassen ohne diesen Nachweis werden im Kopf jedes Berichts
> als „nicht abgedeckt" ausgewiesen, und ein Nullbefund für sie ist kein
> Befund. Prüfung: Abdeckungszeile je Bericht (Bursttyp × Schicht) mit
> Rundlauf-Status.
>
> **V-17-15** — Verifikation gegen ein Orakel, das dieselbe Annahme enthält wie
> der Prüfling, ist keine Verifikation. Prüfläufe messen gegen den Normtext,
> gegen einen Luft-Mitschnitt eines fremden Netzes oder gegen eine **unabhängig
> abgeleitete** Rechnung. Prüfung: (a) Für jede Codiertabelle nennt der Test die
> Normstelle, aus der die erwarteten Werte stammen, und der Wert wird nicht aus
> dem Prüfling kopiert; (b) Testbench und Erzeugungsskript einer Tabelle rechnen
> unabhängig, und der Vergleich der beiden Rechnungen ist der Test; (c) jede
> Testbench meldet ihre unverbundenen Eingänge; (d) eine Änderung ist grün, wenn
> **beide** Werkzeugketten (Simulation und Synthese-Parser) sie annehmen.

---

## 4. Empirische Werte — Tabelle mit Messkontext

Diese Werte sind nicht aus der Theorie herleitbar. Jeder wurde durch Messreihen
gefunden, mehrere nach langer Fehlersuche. Die Spalte „bei Abweichung" ist der
Grund, warum sie hier stehen: ohne sie wird der Wert beim nächsten Umbau
„optimiert" (P5, `CONVENTIONS §3`).

| Parameter | Wert | Herkunft | Was bei Abweichung passierte |
|---|---|---|---|
| Korrelator-Schwelle Steuerburst UL | **15** (normativ `03 §4`, Reset-Wert `07 §3.1.4` `REG_RX_SYNC_CFG_UL`); 13 war der Stand **vor** der Amplitudenkorrektur | [MESS 2026-04-25 → überholt durch MESS 2026-05-22] | Mit `CIC_GAIN_SHF = 6` erkannte die Schwelle 15 nur 3/12 Bursts und 14 verpasste Abmeldungen — daher damals 13. Mit `CIC_GAIN_SHF = 4` liefert **15** die höchste Prüffeld-Rate (92,6 % / 94,1 % in zwei Läufen) gegen 25,5 % bei 13 und 1,5 % bei 11 [MESS 2026-05-22, Air-Tabelle `03 §4`]. 12: ~1 500 Fehlalarme/s im Leerlauf |
| Korrelator-Schwelle Sprachburst | 11 | [MESS 2026-05-17] | 8: ~48 Fehl-Bursts/s · 10: Rate ~28/s statt ~19/s, Rahmenfehler 6,1 % · 12: Verriegelung ganz weg |
| CIC-Verstärkungs-Shift | 4 (×16) | [MESS 2026-05-23] | 6 (×64): Sättigung bei Regelungs-Einschwingen, Prüfsummen-Erfolg 27 % statt 93 % |
| UL-Zugriffsburst-Schwelle | 15 — **derselbe** Detektor wie die Zeile oben (x-Sequenz des Steuerbursts); kein zweiter Wert | [MESS 2026-05-23] | Die Lehre dieser Zeile ist nicht der Wert, sondern das geteilte Register: solange DL- und UL-Schwelle in **einem** Register stehen, ist 15 nicht einstellbar, ohne die DL-Schwelle mitzuverschieben, und Rausch-Synchronisationen kommen durch. V2 trennt sie (`01` R-01-23, `03` R-03-04) |
| Empfänger-Regelungsart | fast_attack | [MESS 2026-05-13, 2026-05-17] | slow_attack: Prüfsumme 13,2 %, Rahmenfehler 46 % · manuell 60 dB: 58 % · manuell 40 dB: 53 % |
| HF-Bandbreite | 200 kHz | [MESS 2026-04-17] | 5,76 MHz: 28× mehr Rauschen, messbare Bitfehler |
| Abtastrate Transceiver | 4 608 000 Hz | [CODE-Historie `304b9d2`] | 4 096 000: Sendepuffer leert in 15,94 ms > Slot 14,167 ms → Überlauf |
| ADC-Datenformat-Register | 0x51 | [MESS 2026-04-13] | 0x01: Nullerweiterung statt Vorzeichenerweiterung → Signal gleichgerichtet, alle Phaseninformation zerstört, HF-Verriegelung unmöglich |
| Abtastversätze Sprachburst | 476 / 0 | [MESS 2026-05-17] | 504 / 32: 16 verfälschte Randbits je Burst, 98 % Rahmenfehler |
| Sprach-Stille-Zeitüberschreitung | 300 ms | [MESS 2026-05-17] | 200 ms: Abbruch mitten im Sprechen bei ~203-ms-Lücken · 500 ms: bis 500 ms veralteter Füllinhalt nach Loslassen · 1 000 ms: gemessen schlechter |
| Reservierungs-Zeitüberschreitung | 5 s (heutiger Stand) | [CODE sw/tetra_call_fsm.h:48; gesetzt `942e31d` 2026-05-25, begründet `f6db8d3`] | 5 s → 30 s am 2026-05-24, weil der Abbauwunsch (2–7 s nach Sprechende) auf einen freigegebenen Slot traf und still verworfen wurde, 7 Wiederholungen [MESS 2026-05-24, CODE-Historie `acbd29c`]; 30 s → 5 s am 2026-05-25 zugunsten schneller Neuzuweisung, seitdem wiederholt das Endgerät den verspäteten Abbauwunsch — laut Begleitkommentar ohne Schaden, ohne neue Messreihe [CODE sw/tetra_call_fsm.h:44-47] · **für V2 offen**, siehe §3.8 F8.4 |
| Zusammensetzungs-Fenster | **V1-Betriebswert** 1 Frame; **V2: 9 Frames**, normativ `08 §3.5.2` | [MESS 2026-05-02]; V2-Wert `T.202` [ETSI Annex B.1] | 2 Frames **in V1**: Zusammensetzung erst nach Baubeginn der Bestätigung fertig → kürzere Bestätigung ohne Gruppenangabe. Genau diese Kopplung entfällt in V2: das Fenster ist eine Verwurfsschranke, die Bestätigung ist ereignisgetriggert (`08 §3.5.2`), erst dadurch sind 9 Frames unschädlich |
| Abstand Vorab-Antwort → Bestätigung | **V1-Wert** 8 Slot-Pulse (2 Frames); **V2: kein fester Abstand** (`08` R-08-11, `04` R-04-21) | [GOLD, 3 Paare] | 4 Slot-Pulse **in V1**: Bestätigung eine Frame zu früh, MAC-Zustand inkonsistent. In V2 gibt es keinen Abstandswert, der falsch stehen könnte — die Bestätigung wartet auf den Vollständigkeits-Status statt auf Slot-Pulse |
| Wiederholungen der Ruf-Verbindungs-PDU | 2 | [GOLD, MESS 2026-05-24] | 3 zu schnell hintereinander: ein harter Abweisungsfall |
| Abstand der Wiederholungen | 113 ms | [GOLD] | blockierende Umsetzung hielt den Abstand, blockierte aber die Hauptschleife 226 ms je Ruf → Wiederholungsrate 30 % statt 11 % |

Die Zeitreihe der Korrelator-Schwelle ist selbst eine Lehre: 200 → 30 → 20 →
15 → 13 → **15**, wobei 200 für einen Vergleich mit maximal 38 Treffern von
Anfang an unerreichbar war. Der Rückweg von 13 auf 15 ist der eigentliche
Befund: **eine Schwelle ist nur zusammen mit dem Amplituden-Arbeitspunkt zu
bewerten.** Bei `CIC_GAIN_SHF = 6` war 15 unbrauchbar, bei `CIC_GAIN_SHF = 4`
ist 15 das Optimum — dieselbe Zahl, entgegengesetztes Urteil, weil zwischendurch
die Sättigung der Amplitudenkette behoben wurde. Wer nur die Schwelle
protokolliert und nicht den Arbeitspunkt, zieht aus der Reihe den falschen
Schluss. Die Obergrenze 15 ist dabei die **Länge des Suchmusters**
(`SYNC_LEN_SYM`), nicht die Breite eines Zählerfelds: 15 für die x-Folge des
Steuerbursts [CODE rtl/rx/tetra_ul_sync_detect_os4.v:54], 11 für die
NTS1-Folge des Sprachbursts [CODE rtl/rx/tetra_rx_chain.v:438-439]. Deshalb ist
die 12 in Zeile 2 nicht knapp, sondern unerreichbar — und deshalb braucht ein
Schwellwert neben seinem Wert immer die Obergrenze des Vergleichs, gegen den er
wirkt.

---

## 5. Verifikation

### 5.1 Review-Gate (vor Übernahme einer Änderung)

Berührt eine Änderung Bit-Feld/Bus/Mailbox-Wort, Feld- oder Kopflänge, einen
Zeitschlitz-/Frame-/Multiframe-Bezug, einen empirischen Wert, eine
Registeradresse, das Entfernen von Logik oder eine Verlagerung über die
HW/SW-Grenze, so gilt der Nachweis aus der Spalte „Wie geprüft" in §5.4 als
Aufnahmebedingung. Ohne Nachweis wird die Änderung abgelehnt (R-17-03).

### 5.2 Bau-Gate (automatisch)

1. Erzeugte Registerkonstanten (HDL, HAL, Testvektortabelle) gegen die
   normative Tabelle — Differenz bricht den Bau (V-17-11).
2. Quellenliste gegen die instanziierte Hierarchie — ein Modul in der Liste
   ohne Instanz bricht den Bau (V-17-8).
3. Textsuche: Schwellwert-Literale in Skripten und Hilfetexten, `±1` auf
   Zeitbezugssignalen außerhalb des Umrechnungsmoduls, mehrfach vorkommende
   Codiertabellen-Werte (V-17-6, V-17-7, V-17-10).
4. Beide Werkzeugketten (Simulator und Synthese-Parser) müssen dieselbe Quelle
   annehmen (V-17-15 d).

### 5.3 Werkzeug-Gate

Jedes Auswertungswerkzeug führt im Kopf jedes Berichts eine Abdeckungszeile
Bursttyp × Schicht mit Rundlauf-Status. Ein Nullbefund in einer Zelle ohne
Rundlauf-Nachweis ist kein Befund (V-17-14). Dieses Gate ist in
`14_VERIFICATION.md` zu verankern, weil die Gold-Aufzeichnung als
Abnahmemaßstab dient und ihr Abdeckungsstand deshalb Teil des Maßstabs ist.

### 5.4 Regel-Register — Regel, zuständiges Kapitel, Prüfung

| Regel | Inhalt in einem Satz | Kapitel | Wie geprüft |
|---|---|---|---|
| V-17-1 | Deadline-gebundene Entscheidungen wandern nicht mit ihrem Modul über die HW/SW-Grenze | `00 §3`, `06`, `07`, `08` | Deadline-Liste je verlagerter Entscheidung; Zähler für versäumte Zuweisungsfristen (`08 §3.3.4`) |
| V-17-2 | Rücknahme so schmal wie die Ursache; kein pauschales Zurücksetzen | `15_BUILD_DEPLOY` | Rücknahmetext benennt die eine Änderung und listet das nicht Betroffene auf |
| V-17-3 | Entfernen von Logik ist bei knappem WNS eine Zeitverhaltens-Änderung | `01 §Ressourcen`, `15` | A/B-Build: LUT, FF, BRAM, WNS vor/nach; einmal gemessene Verschlechterung sperrt den Wiederholungsversuch |
| V-17-4 | Ausrichtung jedes Busses und Mailbox-Worts ist normativ und explizit | `07` | Konvention im Modulkopf; Vektor, der unter der Gegenkonvention fehlschlägt |
| V-17-5 | Einheit und Anwesenheitsbedingung je Feld; Bitbilanz vor jeder Typdeutung eines Restfelds; Breiten werden berechnet | `05`, `06`, `07` | Layout-Tabelle mit Einheit; Vektor je Anwesenheitsvariante; keine literalen Bit-Ausschnitte |
| V-17-6 | Genau ein Umrechnungsmodul zwischen ETSI- und RTL-Zählung | `04`, `08` | Textsuche auf `±1`; genau ein Zähler je Zeitbezug; Zeitplan wird berechnet, nicht kopiert |
| V-17-7 | Eine Wahrheit, ein Ort — auch für Codiertabellen und Zellparameter | `05`, `07`, `13` | Textsuche auf Mehrfachvorkommen; Gleichheitstest über vollen Vektorsatz bei bewusster Doppelung |
| V-17-8 | Ein Umbau ist fertig, wenn alle Erzeuger und Verbraucher nachgezogen sind | `14`, `15` | Erzeuger/Verbraucher-Liste mit Status; Bauliste gegen Hierarchie; Nachweis am Ausgang |
| V-17-9 | Definierte Übernahmephase je Slot-Verbraucher; ein Verbraucher je Statusbit | `08`, `07`, `04` | Puls/Taktversatz-Tabelle; Simulation mit Einspeisung in jeder Taktphase; Spalte „Verbraucher" je Statusregister |
| V-17-10 | Empirischer Wert nur mit Messkontext; getrennte Register für getrennte Arbeitspunkte | `03`, `07`, `12` | Vier Angaben je Wert; Änderung ohne neue Messreihe wird abgelehnt; keine Literale in Skripten |
| V-17-11 | Registeradressen und Layouts aus einer maschinenlesbaren Quelle erzeugt | `07` | Bau-Gate vergleicht Erzeugnis gegen normative Tabelle |
| V-17-12 | Modulkopf nennt genau die Zahlen des Codes, per Parametername | alle RTL-Kapitel | Review: erklärte Werte existieren als Parameter und werden per Namen zitiert |
| V-17-13 | Eine Befund-Datei je Untersuchung, Status je Eintrag, Fixort im eigenen Code | `14` | Review-Gate: Befund ohne Status oder mit externem Fixort wird abgelehnt |
| V-17-14 | Kein Abwesenheits-Befund ohne Positivkontrolle des Werkzeugs | `14` | Abdeckungszeile Bursttyp × Schicht mit Rundlauf-Status im Berichtskopf |
| V-17-15 | Verifikation nie gegen ein Orakel mit derselben Annahme | `14`, `05` | Normstelle je Erwartungswert; unabhängige Zweitrechnung; Meldung unverbundener Testbench-Eingänge; beide Werkzeugketten grün |

---

## 6. Offene Punkte

1. **O-17-1 — Drei Befunde aus V1 sind bis heute im Code und nicht abschließend
   bewertet.** (a) Die gegenläufige Ausrichtung im dritten Erzeuger
   [CODE rtl/lmac/tetra_pre_reply_blck.v:209] — Code-Befund belegt,
   Luft-Wirkung nicht; (b) der Anker eine Multiframe daneben
   [CODE scripts/schedule.py:312, `04` O-04-2]; (c) das getrennte
   UL-Schwellwertregister, dessen Nutzen gemessen war und das durch F1.2
   verloren ging. *Empfehlung:* alle drei in V2 nicht „mitnehmen", sondern aus
   der Norm neu ableiten; (c) ist in `07` als eigenes Register zu führen.

2. **O-17-2 — Wirkung von F5.1 nicht abschließend ausgeschlossen.** Belegt ist, dass die
   beiden Generatormatrizen disjunkte Codes aufspannen und dass das Modul mit
   der abweichenden Matrix nicht instanziiert ist. Nicht geprüft ist, ob eine
   frühere Bauversion es instanziiert hatte und ob damalige Empfangs-Befunde
   dadurch verfälscht wurden. *Empfehlung:* nicht rückwärts aufklären — in V2
   existiert die Matrix genau einmal (V-17-7), damit ist die Frage
   gegenstandslos.

3. **O-17-3 — Abdeckungsstand der Gold-Aufzeichnung.** F10.1 ist quantifiziert für den
   Downlink. Für den Uplink ist die Auszählung nicht gemacht: die Aufzeichnung
   nennt 192 Bursts — 27 mit gültiger Prüfsumme, 161 mit Prüfsummen-Fehlschlag,
   4 übersprungen [GOLD docs/reference_decode/README.md:54; nachgezählt in
   docs/reference_decode/ul_events.jsonl, 192 Zeilen, Feld `crc`: 27 × `OK`,
   161 × `-`, 4 × `SKIP`]. Eine Sprach-Klassifikation nimmt keine der beiden
   Dateien vor; kein Feld der JSONL trägt diese Aussage. Wie viele der 161 in
   Wahrheit gestohlene Signalisierungs-Bursts sind, ist offen — F10.2 belegt an
   einem **anderen** Mitschnitt, dass ein Uplink-Decoder ohne zweites Suchmuster
   genau solche Bursts als Sprache abtut, dass es also mindestens einige sind.
   *Empfehlung:* Vor der Abnahme von
   `10_CMCE_CALL` und `11_SDS` gegen die Gold-Aufzeichnung eine
   Neu-Auswertung beider Mitschnitte mit vollständigem Suchmuster- und
   Schichtsatz, und die Abdeckungszeile in die Aufzeichnungs-Beschreibung
   aufnehmen. Bis dahin gilt jede Aussage der Form „das Referenznetz sendet
   das nicht" als unbelegt.

4. **O-17-4 — Zwei Klassen sind in V1 nicht systematisch untersucht worden und fehlen
   deshalb hier.** (a) Ressourcen- und Zeitverhaltens-Regressionen ohne
   Funktionsfehler — es gibt keine fortlaufende Aufzeichnung von LUT, FF, BRAM
   und WNS je Bau, deshalb ist unbekannt, wie oft eine Änderung Reserve
   gekostet hat, ohne aufzufallen; (b) stille Verwürfe — mehrere Fehler dieses
   Katalogs (F4.3, F7.4, F7.7) waren nur deshalb schwer zu finden, weil ein
   Verwurf keinen Zähler hatte. *Empfehlung:* (a) Bau-Metriken je Bau
   protokollieren und als Zeitreihe führen (`15`); (b) P6 ausnahmslos
   anwenden — jeder Verwurf, jede Prüfsummenverletzung, jeder Mailbox-Überlauf
   hat einen im Betrieb lesbaren Zähler (`07`).

5. **O-17-5 — Kein Verfahren für den Fall „Dokumentation behauptet einen Fehler, der
   keiner ist".** F9.2 und F9.5 sind beide von dieser Art, und beide haben
   Prüfzeit gekostet. V-17-13 fordert einen Status je Eintrag, sagt aber nicht,
   wer ihn nachzieht. *Empfehlung:* Der Status wird von derjenigen Änderung
   nachgezogen, die den Befund behebt oder widerlegt — kein separater
   Dokumentationsdurchgang, weil genau diese Durchgänge in V1 die
   Widersprüche erzeugt haben.
