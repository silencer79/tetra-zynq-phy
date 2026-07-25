# 10 — Rufsteuerung: Gruppenruf, Einzelruf, Mehrfachbetrieb

**Scope:** Die Rufsteuerung (CMCE-CC) vollständig — alle Ruf-PDUs in beiden Richtungen mit
Bitlagen, die Zustandsmaschine je Ruf, Gruppenruf- und Einzelruf-Ablauf, paralleler Betrieb
mehrerer Gruppen auf mehreren Zeitschlitzen, nachträglicher Rufeintritt, alle Zeitgeber und
Aufräummechanismen.

**Nicht hier:** Sprachkanal-Verarbeitung und Sprach-Weiterleitung (`12_VOICE.md`).
Kurznachrichten und Status-PDUs (`11_SDS.md`) — auch dann, wenn sie dieselben CMCE-PDU-Typ-Codes
benutzen. MAC-Zuweisung, Reservierung, Kanalstehlen auf MAC-Ebene, AACH-Ableitung
(`06_MAC.md`). Registeradressen und Mailbox-Wortbelegung (`07_PS_PL_CONTRACT.md`).
LLC-Folgenummern, MLE-Protokolldiskriminator, Anmeldung und Gruppenzuordnung
(`09_LLC_MLE_MM.md`).

**Abhängigkeiten:** `00_OVERVIEW` (Schnitt, P1–P7), `06_MAC` (§3.3 Stehlen, §3.4 MAC-PDUs,
§3.6 Adressierung, §3.8 AACH, §3.12 Steuergrößen), `07_PS_PL_CONTRACT` (§3.3 DL-PDU-Mailbox,
§3.1.5 Slot-Muster), `08_TIMING` (§3.4 Antwortfenster, §3.6 Ruf-Zeitgeber),
`05_CHANNEL_CODING` (SCH/F- und SCH/HD-Codierung), `09_LLC_MLE_MM` (Ein- und Ausgang).

**Begriffe:** CMCE = Circuit Mode Control Entity, die Rufsteuerungsschicht über MLE
[ETSI §14.2]. CC = deren Ruf-Untereinheit. SwMI = Netzseite, hier die Basisstation.
Sprechrecht (englisch *floor*) = die Erlaubnis genau eines Endgeräts, in einem Ruf zu senden.

---

## 1. Anforderungen

| ID | Anforderung |
|---|---|
| **R-10-01** | Die Rufsteuerung erzeugt den CMCE-Körper und gibt ihn mit Zieladresse, Zielkanal und Wiederholungszahl an die Software-Sendekette (LLC/MLE `09` → MAC `06` → Kanalcodierung `05`). Der einzige Ausgang in die Hardware ist die DL-PDU-Mailbox mit fertig codierten Bits (`07 §3.3`). Die Rufsteuerung schreibt kein AACH-Infowort und kein Zuweisungs-Ereignis (P1, R-00-01). |
| **R-10-02** | Die Rufsteuerung verarbeitet ausschließlich **vollständige** CMCE-Körper. Ein noch nicht zusammengesetztes Fragment erreicht sie nicht (`06 §3.11`). |
| **R-10-03** | Jeder Ruf hat genau einen Ruf-Platz. Es gibt keine zweite Ablage für Rufzustand — kein Zustand in Registern, keine parallelen Tabellen (P2). |
| **R-10-04** | Es sind gleichzeitig bis zu `CALL_MAX = 8` Ruf-Plätze und bis zu drei belegte Sprech-Zeitschlitze (TS2…TS4) möglich. |
| **R-10-05** | Ein Sprechwunsch für eine Gruppe, auf der bereits ein Ruf läuft, führt **nie** zu einem zweiten Ruf-Platz und **nie** zu einem zweiten Zeitschlitz für dieselbe Gruppe. |
| **R-10-06** | Die Rufsteuerung behandelt einen Sprechwunsch sowohl als `U-TX DEMAND` als auch als `U-SETUP` auf eine laufende Gruppe. Beide Wege führen auf dieselbe Zustandsänderung (§3.5.4). |
| **R-10-07** | Beim Wechsel des Sprechrechts bleiben Ruf-Kennung, Nutzungsmarkierung (UMt) und Sprech-Zeitschlitz **unverändert**. Nur die Identität des Sprechenden wechselt [ETSI §23.5.5: *„one traffic usage marker generally applies for the complete call and the same usage marker should be assigned for all participants in that call on that assigned channel"*]. |
| **R-10-08** | Jede Sprechrecht-Erteilung erzeugt **zwei** PDUs: eine individuelle an den neuen Sprechenden mit `transmission grant = 00₂` und eine an die Gruppenadresse mit `11₂` und der Adresse des Sprechenden [ETSI §14.5.2.2.1 b)]. Die individuelle wird zuerst gesendet. Bei einem Sprechwunsch per `U-TX DEMAND` sind beide `D-TX GRANTED`; kam der Sprechwunsch als `U-SETUP`, ersetzt `D-CONNECT` mit Sendeerlaubnis `00₂` die individuelle `D-TX GRANTED`, weil nur diese den Zeitgeber T303 des Endgeräts beendet (§3.5.4). |
| **R-10-09** | Ruf-PDUs, die während eines laufenden Rufs an Teilnehmer im Verkehrsschlitz gehen, werden als gestohlener Halbschlitz **auf dem Verkehrsschlitz** gesendet, nicht auf dem Kontrollkanal (§2.4). Ein solcher Mailbox-Eintrag (`target_ts = voice_ts`, `pdu_class = 01₂`) verdrängt für diesen einen Slot den Halteplatz-Pfad (Rang 1) aus `04 §3.4`, gezählt in `steal_override_cnt` (`07 §3.1.8 REG_STEAL_OVERRIDE_CNT`); ohne diese Verdrängung ist die Anforderung nicht erfüllbar (§2.4, §3.10). |
| **R-10-10** | Wiederholungen einer Ruf-PDU haben einen Abstand von **2 TDMA-Frames auf demselben Zeitschlitz**. Der Abstand wird über das Verzögerungsfeld der Mailbox erzeugt, nicht über einen Software-Zeitgeber (§3.4.3). |
| **R-10-11** | Ruf-Kennungen werden aus dem Bereich 1…16383 vergeben; 0 ist verboten [ETSI §14.8.3]. Eine Kennung, die einem lebenden Ruf-Platz gehört, wird nicht erneut vergeben. |
| **R-10-12** | Nutzungsmarkierungen werden aus dem Bereich 4…63 vergeben; 0…3 sind als UMx/UMa/UMc/UMr vorbelegt und dürfen nicht als Verkehrsmarkierung vergeben werden [ETSI §21.4.7.2]. Zwei gleichzeitig aktive Rufe haben nie dieselbe Markierung. |
| **R-10-13** | Bleiben die Uplink-Sprachbursts eines Rufs länger als `T_QUIET` aus, wird der Sprechweg dieses **einen** Zeitschlitzes stillgelegt; der Ruf bleibt bestehen. Andere Zeitschlitze bleiben unberührt. |
| **R-10-14** | Bleiben sie länger als `T_STALE` aus, wird der Ruf-Platz freigegeben, der Zeitschlitz zurückgegeben und die Nutzungsmarkierung gelöscht. |
| **R-10-15** | Ein klingelnder Einzelruf wird nicht vom Sprach-Zeitgeber freigegeben, sondern von `T_ALERT`. |
| **R-10-16** | `T_QUIET` ist der Sprechpausen-Zeitgeber aus `12` R-12-11 (dort normativ definiert, mit Messkontext in `12 §3.6.3`). Dieses Kapitel legt nur seine **Wirkung auf den Rufzustand** fest (§3.9.1) und wiederholt den Wert nicht (P2). |
| **R-10-17** | Tritt ein Endgerät einer Gruppe bei, auf der ein Ruf läuft, sendet die Basisstation ihm die Rufaufbau-PDU nach, mit Meldungsanzeiger „Späteinstieg-Rundspruch" (§3.8). |
| **R-10-18** | Jede empfangene Ruf-PDU wird mit ihrem TDMA-Zeitstempel verarbeitet; die Rufsteuerung hält keine eigene Luft-Uhr (R-00-04). Ereignis-Zeitgeber laufen auf der monotonen Systemuhr (`08 §3.6`). |
| **R-10-19** | Eine Ruf-PDU mit unbekannter Ruf-Kennung wird verworfen und gezählt; sie erzeugt keine DL-PDU. |
| **R-10-20** | Ein Rufaufbau auf eine Adresse, die weder als Gruppen- noch als Teilnehmeradresse bekannt ist, wird mit `D-RELEASE`, Abbruchursache „Unbekannte TETRA-Identität" (`10000₂`) beantwortet [ETSI §14.8.18]. |
| **R-10-21** | Alle Abbruchursachen entsprechen [ETSI Tab. 14.55]. Eine selbst vergebene Ursache wird nicht als `00000₂` gesendet (§3.11.4). |
| **R-10-22** | Alle Zählwerte aus §3.13 sind im Betrieb über AXI lesbar (P6). |
| **R-10-23** | `SLOT_UMT[n]` und die `SLOT_UL_STATE[n]`-Werte „Verkehr" (`01`) und „unbelegt" (`00`) schreibt **ausschließlich** die Rufsteuerung (§3.10). Die Werte „assigned-Zugriff" (`10`) und „reserviert" (`11`) schreibt ausschließlich die Uplink-Zuweisung/Reservierung aus `06 §3.9`; ohne diesen zweiten Schreiber sind die Zeilen 11 und 12 der Infowort-Tabelle in `06 §3.8.2` unerreichbar. Ein dritter Schreiber existiert nicht. |
| **R-10-24** | Die Rufsteuerung ist nach einem Neustart ohne Kenntnis vorheriger Zustände betriebsbereit: alle Plätze leer, alle Sprech-Zeitschlitze frei, alle Nutzungsmarkierungen 0. |
| **R-10-25** | Für jeden Ruf ist die Zuordnung `Ruf-Kennung → Sprech-Zeitschlitz → Nutzungsmarkierung → Gruppenadresse` jederzeit über eine Diagnoseausgabe abfragbar. |

---

## 2. Architektur / Aufbau

### 2.1 Einordnung

```
 UL-Burst ─▶ 03 ─▶ 05 ─▶ 06 ─▶ 09 ─┐        ┌──────────────────────────────┐
 (Soft-Bits) PHY  Decode MAC   LLC/ └──────▶ │  10  tetra_cmce_call         │
                         Reass. MLE          │   Ruf-Platz-Tabelle          │
                                             │   Zustandsmaschine je Ruf    │
 DL-Burst ◀─ 04 ◀─ 07 ◀─ 05 ◀─ 06 ◀───────── │   PDU-Aufbauer (Körper)      │
 (type-5)   TDMA  Mail-  Code  MAC           │   Sprechrecht-Verwaltung     │
                  box                        │   Zeitschlitz-Verwaltung     │
                                             └──────────────────────────────┘
 SLOT_UMT[n], SLOT_UL_STATE[n] ◀───────────────┘   ▲
 (nach 06/07)                                      └── UL-Sprachburst je
                                                       Zeitschlitz (aus 12)
```

Die Rufsteuerung ist ein **reines Software-Modul** ohne Hardware-Anteil. Das folgt unmittelbar
aus dem Schnitt (`00 §3.3` Punkt 3): sie läuft ereignisgesteuert mit weit mehr als einer
Slot-Dauer Spielraum.

### 2.2 Der Ruf-Platz ist die einzige Zustandsablage

V1 verteilt Rufzustand auf drei Orte: die Platz-Tabelle in der Software, das
Sprach-Aktivmaskenregister und die vier Zuweisungskanal-Register je Zeitschlitz, die die
Rufsteuerung direkt beschreibt [CODE sw/tetra_call_fsm.c:132-138, :184-185, :47]. Damit gibt es
drei Wahrheiten über „ist auf TS3 ein Ruf". V2 hat **eine**: die Platz-Tabelle. Aus ihr werden
`SLOT_UMT[n]` und `SLOT_UL_STATE[n]` bei jeder Änderung **abgeleitet** neu geschrieben (§3.10);
das Infowort des Zuweisungskanals entsteht daraus in der Hardware (`06 §3.8.2`).

### 2.3 Schnittstelle nach außen

```c
/* --- Eingang von 09_LLC_MLE_MM ------------------------------------------ */
typedef struct {
    uint32_t      src_ssi;    /* 24 bit, Absenderadresse aus dem MAC-Kopf     */
    const uint8_t *body;      /* ein Bit je Byte, Index 0 = zuerst gesendet     */
    uint16_t      n_bits;     /* gültige Bits im Körper                        */
    tetra_ts_t    ts;         /* TDMA-Zeitstempel des UL-Slots (R-00-04)       */
} cmce_rx_t;

/* Rückgabe: 0 = behandelt, -1 = kein Ruf-Platz / unbekannte Kennung,
 *           -2 = PDU-Typ gehört nicht zur Rufsteuerung.                       */
int  tetra_cmce_call_rx(const cmce_rx_t *in);

/* --- Zyklischer Aufruf aus der Hauptschleife, Kadenz 10 ms --------------- */
void tetra_cmce_call_tick(uint32_t now_ms);

/* --- Meldung aus dem Sprachpfad (12_VOICE) ------------------------------- */
/* etsi_ts 1..4; aus dem Zeitstempel des UL-Bursts, nicht geschätzt.          */
void tetra_cmce_call_ul_voice(uint8_t etsi_ts, uint32_t now_ms);

/* --- Meldung aus der Mobilitätsverwaltung (09) --------------------------- */
/* Ein Endgerät hat sich auf gssi angehängt oder neu registriert.
 * Rückgabe: Anzahl laufender Rufe auf dieser Gruppe, für die nachbenachrichtigt
 * wurde.                                                                     */
int  tetra_cmce_call_group_joined(uint32_t gssi, uint32_t issi);

/* --- Diagnose (R-10-25) -------------------------------------------------- */
void tetra_cmce_call_dump(FILE *out);
```

`tetra_cmce_call_rx` behandelt genau die PDU-Typen aus §3.2. `U-SDS-DATA` und `U-STATUS`
tragen dieselben Typ-Codes im CMCE-Raum, gehören aber nach `11_SDS.md`; der Verteiler in `09`
trennt sie **vor** dem Aufruf. V1 trennt sie erst im Rufsteuerungs-Aufruf und braucht dafür
eine Sonderbehandlung für Fragmentanfänge [CODE sw/tetra_attach_daemon.c:1185-1190] — die in
V2 entfällt (§3.11.1).

### 2.4 Wohin eine Ruf-PDU gesendet wird

Das ist die eine Architekturentscheidung dieses Kapitels, weil sich Referenznetz und V1 hier
unterscheiden.

**Der Sachverhalt.** Ein Endgerät im Ruf hört nicht mehr durchgehend auf den Kontrollkanal.
Ein *sendendes* Endgerät empfängt in den Frames 1…17 nur die Slots seines
Beobachtungsmusters, und zwar auf dem **zugewiesenen** Kanal
[ETSI §23.3.1.3: *„An MS transmitting in traffic mode shall attempt to receive and decode
downlink slots in frames 1 to 17 when required by the assigned monitoring pattern(s) … This
allows the BS to send signalling, for example using the STCH, to a transmitting MS"*]. Ein
*empfangendes* Endgerät hört den Verkehrsschlitz ohnehin, weil dort die Sprache liegt.

**Die zwei Wege.**

| | Referenznetz | V1 |
|---|---|---|
| Weg | Gestohlener Halbschlitz im Verkehrsschlitz: NDB2, BKN1 = SCH/HD mit der Ruf-PDU, BKN2 = Sprachhälfte bzw. Rundspruch | Vollschlitz SCH/F auf dem Kontrollkanal TS1 |
| Beleg | `D-TX CEASED` 1× (MN35/FN10) und `D-RELEASE` 6× (MN40/FN06…11) auf dem Verkehrsschlitz [GOLD 2. Referenzaufnahme — Kasten unten] | [MESS 2026-05-23: `D-TX CEASED` 2× (MN18/FN06, MN19/FN01) auf TS1 als NDB1 SCH/F, `D-RELEASE` 0× — dieselbe Auswertung] |
| Beobachtete Folge | — | Das Endgerät hörte die Antwort nicht und wiederholte `U-TX CEASED` bis 15× bzw. `U-DISCONNECT` 7× [MESS 2026-05-23 Log `ssi=1316858 cause=UserRequested`, dokumentiert in CODE sw/tetra_call_fsm.c:661-667] |

> **Was „2. Referenzaufnahme" in diesem Kapitel bezeichnet.** Eine **zweite** DL-Aufnahme
> derselben fremden Zelle (MCC 262, MNC 1010, CC 1, Träger 3719) vom 2026-05-23, Dauer
> 21,26 s, 1499 Bursts, mit einem Gruppenruf von MS-B (`SSI = 3100001`, `call_id = 12`) —
> **nicht** die 104-s-Aufnahme in `docs/reference_decode/`. Deren Auszählung enthält 0×
> `D-TX CEASED` und 0× `D-RELEASE`, und zwar aus einem Werkzeuggrund: sie wurde am
> 2026-05-15 erzeugt, der NDB2-SCH/HD-Zweig des Dekodierers rief damals die LLC-/MLE-/CMCE-Stufe
> nicht auf und ließ jede gestohlene Ruf-PDU auf der MAC-Ebene hängen — dieselben Bits ergaben
> nach dem Werkzeug-Fix 2× `D-TX CEASED` und 12× `D-RELEASE` [Commit `1a21801`, 2026-05-23].
> Aus dieser Aufnahme lässt sich also **kein** Nullbefund lesen; die untenstehenden Zahlen
> stammen aus der zweiten Aufnahme, die mit dem korrigierten Dekodierer ausgewertet wurde.
> Gemessen auf dem Verkehrsschlitz TS2: `D-TX CEASED` **1×** in MN35/FN10 als NDB2,
> BKN1 = SCH/HD, BKN2 = Sprachhälfte, Infowort `0x23C9`; `D-RELEASE` **6×** in MN40/FN06…11
> als NDB2, BKN1 = SCH/HD, BKN2 = SCH/HD-Rundspruch (SYSINFO), Infowort `0x2049`, sechs
> bit-identische Kopien. Die zugrunde liegende WAV-Datei liegt **nicht mehr im Repo**, und die
> hier genannten Werte sind der **vollständige** Auszug daraus — Infoworte, Multiframe-/
> Frame-Lagen und Zählungen stehen in den drei Sätzen oben, es gibt keine weitere Zahl.
> Nach `14` O-14-3 ist die Aufnahme als Referenzdecode nachzuliefern; bis dahin sind diese
> Zahlen `[MESS 2026-05-23]` und **nicht** `[GOLD]`. Jeder Verweis „2. Referenzaufnahme" in
> diesem Kapitel meint diese Zahlen.

**Bewertung.** Das Stehlen ist der von ETSI vorgesehene Weg im laufenden Ruf; der
Kontrollkanal-Weg funktioniert nur, solange das Endgerät zufällig noch mithört. Er kostet
außerdem Kontrollkanal-Kapazität in genau dem Moment, in dem ein zweites Endgerät sich
anmelden will — das ist derselbe Mechanismus, der in `00 §3.4` zur Aufschaukelung führte. Das
Voll-Stehlen kostet dagegen **beide** Sprachrahmen des betroffenen Bursts, also **60 ms**
Sprache (ein Burst trägt 2 × 137 bit ACELP à 30 ms, `12 §3.1.2`) in einem Ruf, der ohnehin
gerade endet oder das Sprechrecht wechselt. Die 30 ms gelten nur für die Halb-Stehl-Variante
aus §6 Punkt 1, bei der BKN2 die lebende Sprachhälfte weiterträgt.

**Entscheidung für V2 (normativ).**

| PDU | Adressierung | Zielkanal | Begründung |
|---|---|---|---|
| `D-CALL PROCEEDING` | Rufer-ISSI | Kontrollkanal, SCH/F | vor Kanalzuweisung; Endgerät ist auf dem Kontrollkanal |
| `D-ALERT` | Rufer-ISSI | Kontrollkanal, SCH/F | dito |
| `D-SETUP` | GSSI bzw. Gerufener-ISSI | Kontrollkanal, SCH/F | Empfänger ist noch nicht im Ruf [GOLD #6943: TS1, NDB1 SCH/F] |
| `D-CONNECT` | Rufer-ISSI + UMt | Kontrollkanal, SCH/F | [GOLD #5887/#5895/#5903: TS1, NDB1 SCH/F] |
| `D-CONNECT ACKNOWLEDGE` | Gerufener-ISSI + UMt | Kontrollkanal, SCH/F | Gerufener wechselt erst mit dieser PDU auf den Verkehrskanal |
| `D-TX GRANTED` individuell | neuer Sprecher-ISSI + UMt | **Verkehrsschlitz, SCH/HD gestohlen** | Empfänger ist im Ruf |
| `D-TX GRANTED` Gruppe | GSSI + UMt | **Verkehrsschlitz, SCH/HD gestohlen** | dito |
| `D-TX CEASED` | GSSI bzw. ISSI + UMt | **Verkehrsschlitz, SCH/HD gestohlen** | dito, [GOLD 2. Referenzaufnahme MN35/FN10] |
| `D-RELEASE` | GSSI bzw. ISSI + UMt | **Verkehrsschlitz, SCH/HD gestohlen** | dito, [GOLD 2. Referenzaufnahme MN40/FN06…11] |

Der Mechanismus liegt vollständig in `06 §3.3.2` (Downlink-Stehlen, Inhaltsklasse 3) und
`07 §3.3` (`target_ts` = Sprech-Zeitschlitz, `pdu_class = 01₂` SCH/HD). Die Rufsteuerung setzt
in der Mailbox **nur** das Zielschlitz-Feld anders — es gibt keinen zweiten Sendepfad (P3).
Das Infowort des Zuweisungskanals entsteht daraus in der Hardware: Inhaltsklasse 3 mit
Uplink-Verkehr ergibt Kopf `11₂`, Feld 1 = UMa, Feld 2 = UMt (`06 §3.8.2` Zeile 10), was
genau die ETSI-Forderung für einen Downlink-FACCH ist [ETSI §23.3.1.3: *„In the case of a
downlink FACCH … 'field 1' shall be equal to UMa (000001₂)"*].

**Stehl-Vorrang im Burst-Verteiler (normativ, ohne diese Regel ist R-10-09 nicht
implementierbar).** Ein anderes Zielschlitz-Feld allein genügt **nicht**. Die
Auswahl-Priorität des Burst-Verteilers in `04 §3.4` gibt dem Halteplatz-Pfad
(`persist_valid[tn] ∧ (fn ≤ 16)`, Rang 1) den Vorrang vor dem Queue-Pfad; in V1 ist es der
Filler-Override [CODE rtl/tx/tetra_burst_dispatcher.v:222-311]. Genau in dem Zustand, in dem
gestohlen werden soll — auf `voice_ts` fließt Sprache —, käme ein Mailbox-Eintrag mit
`target_ts = voice_ts` also **nie** auf die Luft. Deshalb gilt zusätzlich verbindlich:

- Ein Warteschlangen-Eintrag mit `target_ts = voice_ts` **und** `pdu_class = 01₂` (SCH/HD)
  verdrängt den Halteplatz-Pfad in `04 §3.4` für **diesen einen Slot** — die Priorität kehrt
  sich um: Queue vor Filler, sobald das Stehl-Ziel gesetzt ist. Für alle anderen Slots und
  Frames bleibt die Reihenfolge aus `04 §3.4` unverändert, einschließlich der Ausnahme
  `fn ≤ 16` (Frame 18 wird nicht gestohlen).
- Die Verdrängung wird gezählt: `steal_override_cnt`, geführt im Burst-Verteiler (`04 §3.4`),
  nicht in der Rufsteuerung — sie ist ein Ereignis des Sendepfads. Bleibt der Zähler bei einem
  Abbau 0, obwohl die Rufsteuerung eine In-Ruf-PDU auf `voice_ts` gestaget hat, ist die
  Verdrängungsregel nicht implementiert.
- `06 §3.3.2` (Halbblock-Lieferung, NTS2-Wahl) und `04 §3.5.2` (`head_target_tn`) reichen
  dafür nicht aus: sie können den Slot adressieren, werden aber vom Verteiler überstimmt.

**Verhältnis zu `12` R-12-18 / O-12-5.** `12` R-12-18 verbietet das Stehlen eines
Sprachschlitzes, solange die Halbschlitz-Sprachcodierung nach [ETSI §8.3.1.3.7] fehlt, und
O-12-5 überlässt die Bedarfsfrage diesem Kapitel. Die Entscheidung hier lautet „Bedarf ja",
und sie ist mit R-12-18 vereinbar: V2 Stufe 1 stiehlt nach **Inhaltsklasse 3** — beide
Halbblöcke sind SCH/HD, in dem Burst liegt **keine** Sprache mehr, und damit ist keine
Halbschlitz-Sprachcodierung zu erzeugen. R-12-18 greift ausschließlich für die
Halb-Stehl-Variante (Inhaltsklasse 5, BKN2 = lebende Sprachhälfte), die nach §6 Punkt 1
Roadmap bleibt. Der Preis der hier gewählten Variante steht oben: 60 ms Sprache je
gestohlenem Burst.

**Was Roadmap bleibt:** die Halb-Stehl-Variante, bei der BKN2 die **lebende** Sprachhälfte
weiterträgt (§6 Punkt 1). V2 Stufe 1 stiehlt **beide** Hälften: BKN1 trägt die Ruf-PDU, BKN2 den
Rundspruch-Begleiter, den der Signalisierungs-Verteiler ohnehin liefert (`04 §3.5.2`) — das
Voll-Stehl-Muster, mit dem das Referenznetz `D-RELEASE` sendet.

---

## 3. Detail-Spezifikation

### 3.1 Downlink-PDU-Katalog

Alle Körper liegen als **ein Bit je Byte** vor, Index 0 = zuerst gesendetes Bit — die eine
Darstellung an allen Schnittstellen der Kapitel `09`, `10` und `11` (`09` R-09-25; `11 §3.9`
und `13 §3.4` halten sie ein). Die **On-Air-Reihenfolge** ist MSB-first im Sinne von
[ETSI §E.1.1: *„the most significant bit of that binary value shall be transmitted first"*];
die Packung in type-5-Bits geschieht ausschließlich in `05`. `[a:b]` bezeichnet im Folgenden
Indizes im Ein-Bit-je-Byte-Puffer, nicht Bitpositionen innerhalb eines Oktetts. Der Körper wird von `09` mit MLE-Protokolldiskriminator und
LLC-Kopf versehen und von `06` in die MAC-PDU eingebettet. Die PDU-Typ-Codes sind 5 bit
[ETSI §14.8.28 Tab. 14.66].

Kodierregel für Typ-2- und Typ-3-Elemente, einheitlich für alle CMCE-PDUs
[ETSI §E.1.1 Tab. E.1]: nach dem letzten Typ-1-Element folgt **ein** O-Bit. Ist es 0, endet die
PDU dort — keine Anwesenheitsbits, keine Typ-2-Elemente, **kein** abschließendes M-Bit. Ist es
1, folgt für **jedes** in der PDU definierte Typ-2-Element ein Anwesenheitsbit (1 = Element
folgt) und danach genau ein M-Bit, das Typ-3-Elemente ankündigt; das letzte M-Bit einer PDU ist
0. Die Reihenfolge der Typ-2-Elemente ist die Reihenfolge der ETSI-PDU-Tabelle.

#### 3.1.1 Die fünf kurzen PDUs ohne Typ-2-Elemente

Schreibweise `[a:b]` = Bitpositionen im Körper, `a` = zuerst gesendet.

| PDU | Typ-Code | Bitlage | Länge | Beleg |
|---|---|---|---:|---|
| `D-ALERT` | `00000₂` = 0 | `[0:4]`=Typ, `[5:18]`=Ruf-Kennung, `[19:21]`=Rufzeitgrenze Aufbauphase `000₂`, `[22]`=Reserviert **`1`**, `[23]`=Simplex/Duplex (Spiegel), `[24]`=Ruf in Warteschlange `0`, `[25]`=O-Bit `0` | 26 | [ETSI Tab. 14.4 Note 1: *„its value shall be set to '1'"*]; [CODE sw/tetra_cmce_body.c:262-276] |
| `D-CALL PROCEEDING` | `00001₂` = 1 | `[0:4]`=Typ, `[5:18]`=Ruf-Kennung, `[19:21]`=Rufzeitgrenze Aufbauphase `000₂`, `[22]`=Hakenverfahren (Spiegel), `[23]`=Simplex/Duplex (Spiegel), `[24]`=O-Bit `0` | 25 | [ETSI Tab. 14.5] |
| `D-CONNECT ACKNOWLEDGE` | `00011₂` = 3 | `[0:4]`=Typ, `[5:18]`=Ruf-Kennung, `[19:22]`=Rufzeitgrenze `0000₂`, `[23:24]`=Sendeerlaubnis `00₂`, `[25]`=Sendeanforderung erlaubt `0`, `[26]`=O-Bit `0` | 27 | [ETSI Tab. 14.8] |
| `D-RELEASE` | `00110₂` = 6 | `[0:4]`=Typ, `[5:18]`=Ruf-Kennung, `[19:23]`=Abbruchursache (§3.11.4), `[24]`=O-Bit `0` | 25 | [ETSI Tab. 14.12] |
| `D-TX CEASED` | `01001₂` = 9 | `[0:4]`=Typ, `[5:18]`=Ruf-Kennung, `[19]`=Sendeanforderung erlaubt `0`, `[20]`=O-Bit `0` | 21 | [ETSI Tab. 14.16] |

`000₂` in der Rufzeitgrenze der Aufbauphase heißt „vordefinierten Wert benutzen"
[ETSI Tab. 14.51]. `0` in „Sendeanforderung erlaubt" heißt **erlaubt**, `1` heißt verboten
[ETSI Tab. 14.81] — die Polarität ist invers zur Lesart des Feldnamens und in V1 mehrfach
Anlass für Kommentare gewesen.

Die gespiegelten Bits Hakenverfahren und Simplex/Duplex sind nicht kosmetisch: bleibt
`hook_method` 0, obwohl das Endgerät einen Haken-Ruf angefordert hat, behandelt es den Ruf als
Direktruf und legt beim Loslassen der Sprechtaste auf
[CODE sw/tetra_call_fsm.c:229-233 mit Begründung aus dem Feldversuch].

`D-CONNECT ACKNOWLEDGE` geht an das **gerufene** Endgerät als Durchschalt-Befehl
[ETSI §14.7.1.5]. `D-TX CEASED` geht an **alle** Teilnehmer des Rufs
[ETSI §14.7.1.13: *„from the SwMI to all MS within a call"*], also an die Gruppenadresse.

#### 3.1.2 `D-CONNECT` — PDU-Typ `00010₂` = 2

| Bit | Breite | Feld | V2-Wert | Beleg |
|---:|---:|---|---|---|
| 0 | 5 | PDU-Typ | `00010₂` | |
| 5 | 14 | Ruf-Kennung | vergeben | |
| 19 | 4 | Rufzeitgrenze | `0000₂` = unbegrenzt | [GOLD #5887] |
| 23 | 1 | Hakenverfahren | Spiegel | [GOLD: 0] |
| 24 | 1 | Simplex/Duplex | Spiegel | [GOLD: 0 = Simplex] |
| 25 | 2 | Sendeerlaubnis | `00₂` = erteilt | [GOLD] |
| 27 | 1 | Sendeanforderung erlaubt | `0` = erlaubt | [ETSI Tab. 14.81] |
| 28 | 1 | Rufeigentum | `0` | [GOLD] |
| 29 | 1 | O-Bit | `1` | [GOLD] |
| 30 | 1 | Rufpriorität anwesend | `1` | [GOLD] |
| 31 | 4 | Rufpriorität | `0001₂` = Priorität 1 | [GOLD] |
| 35 | 1 | Dienstangabe anwesend | `0` | [GOLD] |
| 36 | 1 | Temporäradresse anwesend | `0` | [GOLD] |
| 37 | 1 | Meldungsanzeiger anwesend | `0` | [GOLD] |
| 38 | 1 | M-Bit | `0` | [GOLD] |

Länge **39 bit**. Feld für Feld gegen die Referenzaufnahme geprüft, Burst #5887/#5895/#5903
sind untereinander bit-identisch [GOLD `docs/reference_decode/dl_events.jsonl`, eigene
Nachdekodierung des Feldes `info_268b`; Feldvergleich auch in
`docs/local_cell_decode/DIFF_vs_reference.md:91-107`]. V1 baut denselben Körper
[CODE sw/tetra_cmce_body.c:156-179].

Achtung bei der Lesart von `transmission grant = 00₂` = „erteilt": das Endgerät überspringt
damit `U-TX DEMAND` und beginnt sofort mit Uplink-Sprache. Der Sprech-Zeitschlitz muss also
schon beim Senden dieser PDU als Verkehr markiert sein (§3.10).

#### 3.1.3 `D-SETUP` — PDU-Typ `00111₂` = 7

| Bit | Breite | Feld | V2-Wert | Beleg |
|---:|---:|---|---|---|
| 0 | 5 | PDU-Typ | `00111₂` | |
| 5 | 14 | Ruf-Kennung | vergeben | |
| 19 | 4 | Rufzeitgrenze | `0000₂` = unbegrenzt | [GOLD #6943] |
| 23 | 1 | Hakenverfahren | Spiegel | |
| 24 | 1 | Simplex/Duplex | Spiegel | |
| 25 | 3 | Betriebsart Verkehrskanal | `000₂` = TCH/S Sprache | [GOLD] |
| 28 | 1 | Verschlüsselungsanzeige | `0` | [GOLD] |
| 29 | 2 | Kommunikationsart | `01₂` Gruppe / `00₂` Einzel | [ETSI Tab. 14.54], [GOLD: 01₂] |
| 31 | 2 | Sprachdienst | `00₂` | [GOLD] |
| 33 | 2 | Sendeerlaubnis | `11₂` = an anderen erteilt | [GOLD] |
| 35 | 1 | Sendeanforderung erlaubt | `0` = erlaubt | [GOLD] |
| 36 | 4 | Rufpriorität | `0001₂` | [GOLD] |
| 40 | 1 | O-Bit | `1` | [GOLD] |
| 41 | 1 | Meldungsanzeiger anwesend | `1` nur beim Späteinstieg, sonst `0` | [GOLD: `1`] |
| — | 6 | Meldungsanzeiger | `000000₂` = Späteinstieg-Rundspruch | [ETSI EN 300 392-9 §7.2.2 Tab. 3], [GOLD] |
| — | 1 | Temporäradresse anwesend | `0` | [GOLD] |
| — | 1 | Rufer-Adressart anwesend | `1` (V2) / `0` [GOLD] | Anmerkung unten |
| — | 2 | Rufer-Adressart | `01₂` = SSI | [ETSI Tab. 14.43] |
| — | 24 | Rufer-SSI | ISSI des Sprechenden | |
| — | 1 | M-Bit | `0` | |

Ab Bit 42 hängt die Bitlage von den Anwesenheitsbits ab; die Reihenfolge der Typ-2-Elemente
ist die der ETSI-Tabelle [ETSI Tab. 14.15]. Daraus die drei vorkommenden Längen:

| Form | Meldungsanzeiger | Rufer-Adresse | Länge |
|---|---|---|---:|
| Referenzaufnahme | ja | nein | 51 bit |
| V2 Rufaufbau | nein | ja | 71 bit |
| V2 Späteinstieg | ja | ja | 77 bit |

Die 51-bit-Form ist nachgerechnet: Kopflänge 81 bit (MAC-RESOURCE mit 30-bit-Adresse und
25-bit-Kanalzuweisung, LLC 4 bit, MLE 3 bit) plus 51 bit ergibt 132 bit, die Längenangabe
17 Oktette = 136 bit, also 4 Füllbits `1000₂` — genau das Füllmuster aus `06 §3.7`
[GOLD `docs/reference_decode/dl_events.jsonl` #6943, eigene Nachdekodierung].

**Drei Festlegungen, die von V1 abweichen:**

1. **Meldungsanzeiger `000000₂` = „LE broadcast"** beim Späteinstiegs-Nachsenden (§3.8). Das
   ist die maschinenlesbare Kennzeichnung, dass diese `D-SETUP` keinen neuen Ruf ankündigt
   [ETSI EN 300 392-9 §7.2.2 Tab. 3]; die Aufbau-`D-SETUP` lässt das Element weg. Das
   Referenznetz sendet in der Aufnahme nur die Späteinstiegs-Form, und zwar genau so; V1 kennt
   das Element überhaupt nicht [CODE sw/tetra_cmce_body.c:96-107].
2. **Rufzeitgrenze `0000₂`** statt V1s `0111₂` = 5 min [CODE sw/tetra_call_fsm.c:260] und
   **Rufpriorität `0001₂`** statt V1s `0100₂` [CODE …:263] — beide auf die Referenzwerte
   gezogen. V1s `D-CONNECT` trägt schon die Referenzwerte; dass dieselben Felder in `D-SETUP`
   andere Werte trugen, ist eine Drift innerhalb V1s.
3. **Rufer-Adresse:** Die Referenzaufnahme lässt sie weg, V1 sendet sie
   [CODE sw/tetra_cmce_body.c:96-103] — mit dem gemessenen Grund, dass das gerufene Endgerät
   sonst „Einzelruf unbekannt" anzeigt und ablehnt. ETSI führt sie als optionales
   Typ-2-Element [ETSI Tab. 14.15]. **V2 sendet sie** beim Einzelruf und beim Gruppenruf, weil
   die Gruppenmitglieder daraus den Sprechenden anzeigen können.

#### 3.1.4 `D-TX GRANTED` — PDU-Typ `01011₂` = 11

| Bit | Breite | Feld | individuell | gruppenadressiert |
|---:|---:|---|---|---|
| 0 | 5 | PDU-Typ | `01011₂` | `01011₂` |
| 5 | 14 | Ruf-Kennung | des Rufs | des Rufs |
| 19 | 2 | Sendeerlaubnis | `00₂` = erteilt | `11₂` = an anderen erteilt |
| 21 | 1 | Sendeanforderung erlaubt | `0` | `0` |
| 22 | 1 | Verschlüsselungssteuerung | `0` | `0` |
| 23 | 1 | Reserviert | `0` | `0` |
| 24 | 1 | O-Bit | `0` | `1` |
| 25 | 1 | Meldungsanzeiger anwesend | — | `0` |
| 26 | 1 | Sender-Adressart anwesend | — | `1` |
| 27 | 2 | Sender-Adressart | — | `01₂` = SSI |
| 29 | 24 | Sender-SSI | — | ISSI des neuen Sprechenden |
| 53 | 1 | M-Bit | — | `0` |

Längen: 25 bit individuell, 54 bit gruppenadressiert. Reserviert-Bit muss 0 sein
[ETSI Tab. 14.18 Note 1].

Die **gruppenadressierte** Variante fehlt in V1 vollständig
[CODE sw/tetra_call_fsm.c:322-335 — nur `m.target_ssi = s->ssi`]. ETSI fordert beide
[ETSI §14.5.2.2.1 b)] und nennt ausdrücklich die Reihenfolge: erst individuell, oder die
Sender-Adresse in der gruppenadressierten mitgeben, sonst schaltet das gerade zu berechtigende
Endgerät auf Empfang um [ETSI §14.5.2.2.1 b) NOTE 1]. V2 erfüllt beide Bedingungen: individuell
zuerst **und** Sender-Adresse in der Gruppen-PDU (R-10-08).

### 3.2 Uplink-PDU-Katalog

Der Auswerter liest den Körper strikt nach diesen Tabellen und bricht mit `-1` ab, sobald ein
Pflichtfeld nicht mehr im Puffer liegt.

#### 3.2.1 `U-SETUP` — PDU-Typ `00111₂` = 7

```
[0:4]   PDU-Typ = 00111₂            [15:16] Kommunikationsart  00₂ Punkt-zu-Punkt
[5:8]   Gebietsauswahl                                         01₂ Gruppe
[9]     Hakenverfahren  → gespiegelt                           10₂ bestätigte Gruppe
[10]    Simplex/Duplex  → gespiegelt                           11₂ Rundruf
[11:13] Betriebsart Verkehrskanal    [17:18] Sprachdienst (bei 000₂) bzw. Slots je Frame
        000₂ = TCH/S Sprache         [19]    Sendeanforderung 0 = will selbst senden
[14]    Verschlüsselungsanzeige                               1 = andere dürfen senden
                                     [20:23] Rufpriorität
[24:25] CLIR-Steuerung               [26:27] Gerufene-Adressart 00₂ SNA / 01₂ SSI / 10₂ TSI
[28:…]  Gerufene Adresse  8 bit (SNA) / 24 bit (SSI) / 48 bit (TSI)
[…]     O-Bit — wird nicht weiter ausgewertet
```

Bei Adressart SSI: 53 bit [ETSI Tab. 14.30]. Bit-exakt gegen die Referenzaufnahme geprüft: Kommunikationsart
`01₂`, Gerufene-SSI `3100004`, Sendeanforderung `0`, Rufpriorität `0000₂`, Haken- und
Duplexbit 0 [GOLD `docs/reference_decode/ul_events.jsonl` UL #22, eigene Nachdekodierung des
Feldes `bits92` ab Bit 38].

**Auswertungsregeln:**

- Die Unterscheidung Gruppe/Einzel ergibt sich aus der **Kommunikationsart**. Zusätzlich wird
  die gerufene Adresse gegen die Teilnehmerverwaltung geprüft: behauptet die PDU „Gruppe", ist
  die Adresse aber keine bekannte Gruppenadresse, gilt sie als Einzeladresse
  [CODE sw/tetra_call_fsm.c:405-416 — dieselbe Doppelprüfung, air-verifiziert].
- Ist die Adresse **weder** als Gruppen- **noch** als Teilnehmeradresse bekannt: `D-RELEASE`
  mit Ursache `10000₂` (R-10-20). V1 versucht in diesem Fall, eine nicht existierende
  Gegenstelle anzurufen, und läuft in die Klingeldauer-Abschaltung.
- Adressart `11₂` ist reserviert [ETSI Tab. 14.39] und wird verworfen (`ul_addr_type_rej_cnt`
  in `06 §3.13`).

#### 3.2.2 Die übrigen Uplink-PDUs

| PDU | Typ-Code | Bitlage nach dem 5-bit-Typ | Länge |
|---|---|---|---:|
| `U-ALERT` | `00000₂` = 0 | Ruf-Kennung 14, Reserviert 1 (muss `1` sein [ETSI Tab. 14.21]), Simplex/Duplex 1, O-Bit 1 | 22 |
| `U-CONNECT` | `00010₂` = 2 | Ruf-Kennung 14, Hakenverfahren 1, Simplex/Duplex 1, O-Bit 1 | 22 |
| `U-DISCONNECT` | `00100₂` = 4 | Ruf-Kennung 14, Abbruchursache 5, O-Bit 1 | 25 |
| `U-RELEASE` | `00110₂` = 6 | Ruf-Kennung 14, Abbruchursache 5, O-Bit 1 | 25 |
| `U-TX CEASED` | `01001₂` = 9 | Ruf-Kennung 14, O-Bit 1 | 20 |
| `U-TX DEMAND` | `01010₂` = 10 | Ruf-Kennung 14, Sendewunsch-Priorität 2, Verschlüsselungssteuerung 1, Reserviert 1, O-Bit 1 | 24 |

[ETSI Tab. 14.21, 14.23, 14.24, 14.29, 14.31, 14.32.] `U-TX DEMAND` bit-exakt gegen die
Referenzaufnahme: Ruf-Kennung 8 (dieselbe wie im `D-CONNECT` desselben Rufs),
Sendewunsch-Priorität `10₂` = vorrangberechtigt [GOLD UL #79 und UL #144, eigene
Nachdekodierung].

**V1-Lücke, die V2 schließt:** V1s Auswerter liest bei `U-CONNECT` und `U-ALERT` nur die
Ruf-Kennung und fällt für den Rest in einen Sammelzweig
[CODE sw/tetra_cmce_parser.c:230-241]. Haken- und Duplexbit des Gerufenen gehen dabei
verloren, obwohl sie in `D-CONNECT ACKNOWLEDGE` und in der Statuslogik gebraucht werden. V2
wertet alle Pflichtfelder aus.

**Sendewunsch-Priorität** `10₂`/`11₂` sind vorrangberechtigte Anforderungen
[ETSI Tab. 14.85]. V2 erteilt das Sprechrecht in Stufe 1 unabhängig von der Priorität sofort,
erfüllt Vorrang damit trivial und zählt `tx_demand_preempt_cnt`, damit ein späterer
Warteschlangen-Betrieb messbare Ausgangsdaten hat.

### 3.3 Der Ruf-Platz

```c
typedef enum {                    /* Zustände, §3.4                          */
    CALL_IDLE = 0, CALL_SETUP = 1, CALL_ACTIVE = 2,
    CALL_TALKER = 3, CALL_RELEASING = 4
} call_state_t;

typedef struct {
    uint32_t     talker_ssi;      /* 24 bit, aktueller Sprecher; 0 = Platz frei */
    uint32_t     group_gssi;      /* 24 bit, 0 bei Einzelruf                    */
    uint32_t     peer_issi;       /* 24 bit, Gerufener beim Einzelruf, sonst 0  */
    uint32_t     owner_ssi;       /* 24 bit, Rufeigentümer = erster Rufer       */
    uint16_t     call_id;         /* 14 bit, 1..16383                           */
    uint8_t      umt;             /* 6 bit, 4..63; 0 = nicht vergeben           */
    uint8_t      voice_ts;        /* ETSI 1..4; 2..4 zulässig, 0 = nicht vergeben */
    call_state_t state;
    uint8_t      hook_method;     /* 1 bit, Spiegel aus U-SETUP                 */
    uint8_t      simplex_duplex;  /* 1 bit, Spiegel aus U-SETUP                 */
    uint8_t      comm_type;       /* 2 bit, Spiegel aus U-SETUP                 */
    uint32_t     t_last_ul_ms;    /* letzter UL-Sprachburst auf voice_ts;
                                   * beim Belegen des Platzes auf now_ms
                                   * gesetzt, NICHT auf 0 (§3.5.1)             */
    uint32_t     t_setup_ms;      /* Empfang des U-SETUP                        */
    uint32_t     t_cease_ms;      /* erstes U-TX CEASED; 0 = noch keines        */
} call_slot_t;

static call_slot_t g_calls[CALL_MAX];   /* CALL_MAX = 8 */
```

Größe je Platz 40 byte bei 4-byte-Ausrichtung, Tabelle 320 byte [ANNAHME — aus den Feldbreiten
gerechnet]. Kein dynamischer Speicher, keine Zeiger zwischen Plätzen (R-10-24).

**Anlegeregel für `t_last_ul_ms` (normativ).** Beim Belegen eines Platzes wird
`t_last_ul_ms = now_ms` gesetzt, ebenso bei **jeder** Sprechrecht-Erteilung und bei **jedem**
empfangenen `U-TX CEASED`. Der Nullwert aus R-10-24 darf einen belegten Platz nie erreichen:
`now_ms − 0` ist sofort größer als `T_STALE = 5 s`, und der erste `tetra_cmce_call_tick`
(Kadenz 10 ms) gäbe damit jeden gerade aufgebauten Ruf wieder frei, bevor der erste
UL-Sprachburst eintreffen kann. V1 setzt den Wert an genau diesen vier Stellen
[CODE sw/tetra_call_fsm.c:485 Gruppenzweig, :510 Einzelrufzweig, :546 `U-TX DEMAND`,
:573 `U-TX CEASED`].

Gegenüber V1 entfallen vier Felder: die beiden LLC-Folgenummern (gehören nach `09`, dort auch
für Nicht-Ruf-Verkehr gebraucht) und die beiden Felder der Antwortsequenz `setup_stage` /
`setup_next_ms` [CODE sw/tetra_call_fsm.h:84-85]. Letztere existieren nur, weil V1 den
Wiederholungsabstand mit einem Software-Zeitgeber erzeugt; in V2 macht das die Mailbox
(§3.4.3).

**Nachschlagefunktionen.** Drei, mehr nicht:

| Funktion | Schlüssel | Wofür |
|---|---|---|
| `find_by_talker(ssi)` | aktueller Sprecher | `U-TX CEASED`, `U-RELEASE`, `U-DISCONNECT` des Sprechenden |
| `find_by_call_id(id)` | Ruf-Kennung | jede PDU eines Teilnehmers, der nicht der Sprechende ist |
| `find_by_gssi(gssi)` | Gruppenadresse | Sprechwunsch per `U-SETUP` (§3.5.4), Späteinstieg (§3.8) |

Die Reihenfolge ist verbindlich: zuerst `find_by_talker`, dann — falls die PDU eine
Ruf-Kennung trägt — `find_by_call_id`, dann bei `U-SETUP` auf eine Gruppe `find_by_gssi`. Ohne
`find_by_gssi` legt ein zweites Gruppenmitglied einen zweiten Ruf-Platz mit eigener
Nutzungsmarkierung auf demselben Zeitschlitz an; das Infowort des Zuweisungskanals wird
überschrieben, die Markierung auf der Luft kollidiert und die Endgeräte verwerfen den Ruf
[MESS 2026-05-25, dokumentiert in CODE sw/tetra_call_fsm.c:417-421].

### 3.4 Zustandsmaschine

#### 3.4.1 Zustände

```
                   U-SETUP (Einzel)              U-SETUP (Gruppe, neu)
                   D-CALL-PROC + D-ALERT         D-CONNECT ×3 + D-SETUP
                   + D-SETUP(B)                            │
        ┌──────┐───────────────────▶┌───────┐              │
   ┌───▶│ IDLE │                    │ SETUP │              │
   │    └──────┘◀── T_ALERT ────────│klingelt│             ▼
   │       ▲   D-RELEASE Urs. 13    └───────┘        ┌──────────┐
   │       │                            │  U-CONNECT │  ACTIVE  │
   │       │  T_STALE                   └───────────▶│ Ruf steht│
   │       │  (Platz frei)               D-CONNECT + │ niemand  │
   │       │                             D-CONN-ACK  │ spricht  │
   │       │                                         └──────────┘
   │  ┌─────────────┐                                 │       ▲
   │  │  RELEASING  │◀── U-RELEASE / U-DISCONNECT ────┤       │ U-TX CEASED
   │  │ D-RELEASE ×3│◀───────────────────────┐        │       │ D-TX-CEASED ×3
   │  └─────────────┘                        │        ▼       │
   └────── letzte Wiederholung gesendet      │   ┌──────────┐ │
                                             └───│  TALKER  │─┘
              U-TX DEMAND ───────────────────────▶│Sprechrecht│
              → D-TX-GRANTED individuell + Gruppe └──────────┘
              U-SETUP(Gruppe) → D-CONNECT ×3 + D-TX-GRANTED Gruppe (§3.5.4)
```

`RELEASING` besteht nur, solange die `D-RELEASE`-Wiederholungen in der Mailbox stehen; darin
werden Ruf-PDUs derselben Kennung verworfen (§3.11.3). Danach wird der Platz geleert.

#### 3.4.2 Übergangstabelle (normativ)

| # | Zustand | Ereignis | Bedingung | Gesendete PDU (Ziel · Kanal · Wiederholungen) | Folgezustand |
|---:|---|---|---|---|---|
| 1 | IDLE | `U-SETUP` | Gruppe bekannt, kein Ruf auf der GSSI, Platz und Zeitschlitz frei | `D-CONNECT` (Rufer · MCCH SCH/F · 3×) + `D-SETUP` (GSSI · MCCH SCH/F · 1×) | ACTIVE |
| 2 | IDLE | `U-SETUP` | Einzeladresse bekannt | Kapazitätszusage (Rufer · MCCH SCH/HD · 1×) + `D-CALL PROCEEDING` (Rufer) + `D-ALERT` (Rufer) + `D-SETUP` (Gerufener · 2×) | SETUP |
| 3 | IDLE | `U-SETUP` | kein Platz **oder** kein freier Zeitschlitz | `D-RELEASE` cause `01100₂` (kein freies CC-Objekt) | IDLE |
| 4 | IDLE | `U-SETUP` | Adresse unbekannt | `D-RELEASE` cause `10000₂` | IDLE |
| 5 | ACTIVE / TALKER | `U-SETUP` | Gruppe hat schon einen Ruf (`find_by_gssi`) | Sprechrecht-Wechsel, §3.5.4: `D-CONNECT` grant `00₂`, unveränderte Ruf-Kennung/UMt/`voice_ts` (neuer Sprechender · MCCH SCH/F · 3×) **dann** `D-TX GRANTED` grant `11₂` mit Sender-Adresse (GSSI · Verkehrsschlitz SCH/HD · 1×). **Nicht** wie Zeile 9 — `D-TX GRANTED` beendet T303 nicht | TALKER |
| 6 | SETUP | `U-ALERT` | Kennung passt | — (ETSI: keine Antwort erwartet) | SETUP |
| 7 | SETUP | `U-CONNECT` | Kennung passt | `D-CONNECT` (Rufer · MCCH · 1×) + `D-CONNECT ACKNOWLEDGE` (Gerufener · MCCH · 1×) | ACTIVE |
| 8 | SETUP | `T_ALERT` abgelaufen | — | `D-RELEASE` cause `01101₂` (Zeitgeberablauf) an Rufer **und** Gerufenen (**MCCH SCH/F** · je 1×) | IDLE |
| 9 | ACTIVE / TALKER | `U-TX DEMAND` | Kennung passt | `D-TX GRANTED` grant `00₂` (neuer Sprecher · Verkehrsschlitz SCH/HD · 1×) **dann** `D-TX GRANTED` grant `11₂` mit Sender-Adresse (GSSI · Verkehrsschlitz SCH/HD · 1×) | TALKER |
| 10 | TALKER | `U-TX CEASED` | Kennung passt, erstes | `D-TX CEASED` (GSSI · Verkehrsschlitz SCH/HD · 3×) | ACTIVE |
| 11 | ACTIVE | `U-TX CEASED` | Wiederholung des Endgeräts | `D-TX CEASED` (GSSI · Verkehrsschlitz SCH/HD · 1×) | ACTIVE |
| 12 | ACTIVE / TALKER | `U-RELEASE` bzw. `U-DISCONNECT` | Kennung passt | `D-RELEASE` mit Ursache aus der UL-PDU (Ziel wie §2.4 · Verkehrsschlitz SCH/HD · 3×) | RELEASING |
| 13 | ACTIVE / TALKER | `now_ms − t_last_ul_ms > T_QUIET` | — | — (nur Sprechweg stilllegen) | unverändert |
| 14 | ACTIVE / TALKER | `now_ms − t_last_ul_ms > T_STALE`; `t_last_ul_ms` ist bei Platzbelegung, Sprechrecht-Erteilung und `U-TX CEASED` auf `now_ms` gesetzt (§3.3) | — | — (Platz freigeben, Zeitschlitz zurück) | IDLE |
| 15 | ACTIVE / TALKER | Gruppenbeitritt auf der GSSI | Ruf läuft | `D-SETUP` (GSSI · MCCH SCH/F · 1×) | unverändert |
| 16 | RELEASING | jede Ruf-PDU mit dieser Kennung | — | — (verworfen, `call_pdu_late_cnt`) | RELEASING |
| 17 | * | Ruf-PDU mit unbekannter Kennung | — | — (verworfen, `call_pdu_unknown_cnt`) | unverändert |

**Zielkanal-Regel, die §2.4 präzisiert:** Ein `D-RELEASE` geht auf den Verkehrsschlitz nur,
wenn dieser Ruf dort tatsächlich `SLOT_UL_STATE = Verkehr` hat (Zustand `ACTIVE`/`TALKER`).
Bricht ein Ruf in `SETUP` ab (Zeile 8) oder ist der Sprechweg bereits nach `T_QUIET`
stillgelegt, geht das `D-RELEASE` auf den **Kontrollkanal** — dort hört das Endgerät dann.

Zeile 2 sendet zuerst eine **Kapazitätszusage** an den Rufer — die kurze SCH/HD-MAC-RESOURCE
mit gesetztem Slot-Zusage-Flag und Zusage-Element `0x00` aus `06 §3.4.5`. Ohne sie bricht der
Rufer beim Loslassen der Sprechtaste mit `U-DISCONNECT` ab
[CODE sw/tetra_call_fsm.c:500-503 mit Begründung aus dem Feldversuch]. In V1 erzeugt eine
eigene RTL-Zustandsmaschine diese PDU; in V2 ist es ein gewöhnlicher Mailbox-Eintrag der
Klasse „Vorantwort/Kapazitätszusage" (`06 §3.4.5`, `07 §3.3`).

#### 3.4.3 Wiederholungen und ihr Abstand

**Regel.** Eine Ruf-PDU wird als `N` identische Mailbox-Einträge übergeben. Eintrag `k`
(0-basiert) trägt `delay_slots = 8·k`, also 8 Slot-Strobes = **2 TDMA-Frames** je Schritt
[`07 §3.3` Wort `W14[26:21]`; Abstand normativ `08 §3.4.3` R-4]. Das PL wertet
`delay_slots` je Eintrag **immer** aus; es gibt kein gemeinsames Abstandsregister und kein
Umschaltbit darauf (`07 §3.1.5`, `07 §3.3`), die Staffelung `0, 8, 16` steht damit
vollständig im jeweiligen Eintrag. `last_fragment = 0` [`07 §3.3` Wort `W14[27]`]: eine
Ruf-PDU ist nie Teil einer Fragmentkette. Der Bit-Inhalt aller `N` Einträge ist identisch.

**Warum 2 Frames und nicht 1.** Die Referenzaufnahme sendet die drei `D-CONNECT` auf demselben
Zeitschlitz in FN02, FN04, FN06 desselben Multiframe — Abstand 113 ms und 114 ms, nominal
2 × 56,67 ms = 113,3 ms [GOLD `docs/reference_decode/action_reaction.md:283-285`, DL-Zeiten
83,387 s / 83,500 s / 83,614 s]. Eine ältere V1-Aufnahme sendet dieselben drei PDUs in FN12,
FN13, FN14, also 1 Frame Abstand
[MESS 2026-05-15 `docs/local_cell_decode/dl_events.jsonl` #1245/#1249/#1253]. Ein
Zwischenstand von V1 hat den Abstand ganz entfernt; das Ergebnis war ein Endgerät, das den
Rufaufbau **hart ablehnte** [MESS 2026-05-17, Wiederholungsreihe ohne Frame-Abstand: bei 3 aufeinander
folgenden `D-CONNECT` im Ein-Frame-Takt **1 harte Ablehnung** des Rufaufbaus]. Der **Abstand** ist damit die
sicherheitsrelevante Größe, nicht die Anzahl — er ist verbindlich 2 Frames.

**Wiederholungszahlen** (Konfigurationswerte, Bereich 1…6, hier die Vorbelegungen):

| PDU | `N` | Beleg |
|---|---:|---|
| `D-CONNECT` (Rufaufbau) | 3 | [GOLD #5887/#5895/#5903 — drei bit-identische Kopien] |
| `D-SETUP` (Gruppenruf-Aufbau) | 1 | [GOLD: eine Kopie in der Aufnahme] |
| `D-SETUP` (Einzelruf, Klingeln) | 2 | [CODE sw/tetra_call_fsm.c:506, :764-770] |
| `D-SETUP` (Späteinstieg) | 1 | [CODE sw/tetra_call_fsm.c:292] |
| `D-CALL PROCEEDING`, `D-ALERT`, `D-CONNECT ACKNOWLEDGE` | 1 | keine Wiederholung beobachtet |
| `D-TX GRANTED` | 1 individuell + 1 gruppenadressiert | [ETSI §14.5.2.2.1 b)] |
| `D-TX CEASED` erstes | 3 | [CODE sw/tetra_call_fsm.c:588-597] |
| `D-TX CEASED` auf Endgerät-Wiederholung | 1 | dito |
| `D-RELEASE` | 3 | [ANNAHME — Referenznetz sendet 6× [GOLD 2. Referenzaufnahme MN40/FN06…11, §2.4], V1 sendet 1×; 3 ist der Kompromiss, die Wiederholungen kosten nur Halbschlitze eines endenden Rufs] |

Zur `D-CONNECT`-Zahl: ein V1-Kommentar behauptet, eine andere Referenzaufnahme habe nur zwei
Kopien gezeigt [CODE sw/tetra_call_fsm.c:739-742]; diese Aufnahme liegt nicht mehr vor und ist
nicht nachprüfbar. Die vorliegende, bit-exakt nachgerechnete Aufnahme zeigt drei. V2 nimmt 3.

**Was dadurch entfällt:** V1 baut den Abstand mit einem Software-Zeitgeber
(`setup_stage`, `setup_next_ms`, 113-ms-Schritte [CODE sw/tetra_call_fsm.c:478-479, :736-771]);
die Vorversion schlief dafür blockierend und erreichte eine Wiederholungsrate der Endgeräte
von 30 % bei Spitzenlatenzen von 3,6 s [MESS 2026-05-17]. Beide Varianten entfallen: die
Rufsteuerung schiebt die `N` Einträge in einem Durchlauf in die Mailbox und ist fertig.

### 3.5 Gruppenruf

#### 3.5.1 Aufbau

```
t     Richtung   PDU / Aktion
────  ─────────  ─────────────────────────────────────────────────────────────
 0    A → BS     U-SETUP (GSSI, Kommunikationsart 01₂, Sendeanforderung 0)
 0    BS         Platz belegen: call_id, UMt, voice_ts wählen;
                 t_last_ul_ms = now_ms (§3.3 — sonst greift T_STALE sofort);
                 SLOT_UMT[voice_ts] und SLOT_UL_STATE[voice_ts] setzen
FN+0  BS → A     D-CONNECT, Sendeerlaubnis 00₂ = erteilt      (MCCH, SCH/F)
FN+2  BS → A     D-CONNECT, bit-identisch                     (MCCH, SCH/F)
FN+4  BS → A     D-CONNECT, bit-identisch                     (MCCH, SCH/F)
FN+6  BS → GSSI  D-SETUP, Sendeerlaubnis 11₂ = an anderen      (MCCH, SCH/F)
 …    A → BS     UL-Sprache auf voice_ts
 …    BS → GSSI  DL-Sprache auf voice_ts
```

**Der Rufer bekommt das Sprechrecht sofort**, ohne `U-TX DEMAND`: `D-CONNECT` trägt
Sendeerlaubnis `00₂`. Das entspricht ETSI [§14.5.2.2.1 a): *„The SwMI normally gives the first
permission to transmit to the calling MS when a new call has been set-up"*] und der
Referenzaufnahme. Die Ausnahme ist ein `U-SETUP` mit Sendeanforderung `1` = „andere dürfen
senden" [ETSI Tab. 14.74]; dann trägt `D-CONNECT` Sendeerlaubnis `11₂` und der Platz geht nach
`ACTIVE` statt `TALKER`. Die Referenzaufnahme zeigt Wert `0` [GOLD UL #22]; V1 wertet das Feld
nicht aus, obwohl der Auswerter es einliest [CODE sw/tetra_cmce_parser.c:91]. V2 wertet es aus.

**Reihenfolge ist verbindlich:** `SLOT_UMT[voice_ts]` und `SLOT_UL_STATE[voice_ts]` werden
gesetzt, **bevor** der erste `D-CONNECT` in die Mailbox geht — ETSI verlangt genau das
[ETSI §23.5.5: *„The BS shall assign a traffic usage marker before any traffic transmission
takes place on an assigned channel"*]. Sonst sieht das Endgerät auf dem zugewiesenen
Zeitschlitz ein Ruhe-Infowort, obwohl `D-CONNECT` ihm Sendeerlaubnis erteilt hat, und meldet
die Sprechtaste als abgewiesen [CODE sw/tetra_call_fsm.c:480-487 mit derselben Begründung].

#### 3.5.2 Warum `D-SETUP` an die Gruppe nicht wegoptimiert werden darf

Die Referenzaufnahme ist die Sicht **eines** Endgeräts — und zwar des Rufers. Dass man in ihr
keine Wirkung der `D-SETUP` sieht, heißt nicht, dass sie wirkungslos ist: sie ist die
**einzige** PDU, mit der die anderen Gruppenmitglieder von dem Ruf und von der Kanalzuweisung
erfahren. ETSI führt sie im Gruppenruf-Aufbau als Pflicht-PDU an die gerufene Seite
[ETSI §14.5.2.1.0 Fig. 14.16; §14.5.2.1.1: *„Notification of the arrival of an incoming call to
the CC sub-entity shall be made by the reception of a D-SETUP PDU"*]. Eine V1-Fehlerliste hat
ihr Fehlen zuerst als Bug gemeldet, diesen Bug dann als Fehldiagnose **verworfen** und die
Referenz-`D-SETUP` als „Incoming-Call-Paging" umgedeutet — mit dem Schluss „Verbleibende
Feature-Aufgabe (kein Bug) … Aktuell nicht needed"
[`docs/local_cell_decode/BUGS_LIST.md:110-132`]. Die Umdeutung ist widerlegt: die
Nachdekodierung von #6943 zeigt `call_id = 8`, `UMt = 11`, Kommunikationsart `01₂` (Gruppe)
und Kanalzuweisung „Timeslot assigned" `0100₂` (TS2), Träger 3719 — also genau den Ruf, der
mit #5887 aufgebaut wurde (`call_id = 8`, `UMt = 11`, `0100₂`, Träger 3719). Ein eingehender
Einzelruf hätte eine neue Ruf-Kennung und nicht die Nutzungsmarkierung des laufenden Rufs
[GOLD `docs/reference_decode/dl_events.jsonl` #5887 und #6943, eigene Nachdekodierung des
Feldes `info_268b`]. **Die `D-SETUP` an die Gruppe ist Pflicht.**

Die einzige `D-SETUP` der Referenzaufnahme liegt 15 s nach dem Rufaufbau und trägt
Meldungsanzeiger `000000₂` — sie ist ein Späteinstiegs-Hinweis, nicht die
Aufbau-Benachrichtigung [GOLD #6943; Zeitbezug `action_reaction.md:1760`, DL-Zeit 98,347 s
gegen 83,387 s]. Dass die Aufbau-Benachrichtigung in der Aufnahme fehlt, ist ein Befund über
**dieses** Netz, kein Freibrief.

#### 3.5.3 Sprechrecht-Wechsel über `U-TX DEMAND`

Der ETSI-konforme Weg. Das Mitglied kennt die Ruf-Kennung aus der `D-SETUP` und schickt
`U-TX DEMAND` mit dieser Kennung. Der Platz wird über `find_by_call_id` gefunden;
`talker_ssi` wird auf den Absender gesetzt, `call_id`, `umt`, `voice_ts` und `group_gssi`
bleiben unverändert (R-10-07). Dann Zeile 9 der Übergangstabelle. Dass die Ressourcen den
Wechsel überdauern, ist auch die Referenzbeobachtung: die Nutzungsmarkierung ist über den
ganzen Gruppenruf konstant [GOLD #5887 und #6943 — beide `UMt = 11`, 15 s auseinander,
derselbe Ruf `call_id = 8`].

#### 3.5.4 Sprechrecht-Wechsel über `U-SETUP` — Verhalten echter Endgeräte

**Das getestete Endgerät sendet für einen Sprechwunsch in einem laufenden Gruppenruf kein
`U-TX DEMAND`, sondern ein vollständiges `U-SETUP`** mit eigener ISSI und der Gruppenadresse
als gerufener Adresse [MESS 2026-05-25, beobachtet im Betriebsprotokoll der Rufsteuerung;
Befund im Repo festgehalten in CODE sw/tetra_call_fsm.c:100-103]. Die Referenzaufnahme zeigt für dasselbe
Ereignis den ETSI-Weg `U-TX DEMAND` [GOLD UL #79, UL #144]. **Beide Wege kommen auf der Luft
vor; V2 muss beide behandeln (R-10-06).**

**Normative Regel.** Trifft ein `U-SETUP` mit Kommunikationsart Gruppe ein, wird **vor** jeder
Platzbelegung `find_by_gssi(gerufene_adresse)` ausgeführt:

```
U-SETUP, comm_type ∈ {01,10,11}
  ├─ find_by_talker(src_ssi) trifft  → derselbe Sprecher wiederholt sein U-SETUP:
  │                                    Antwortfolge Zeile 1 erneut, kein neuer Platz
  ├─ find_by_gssi(gssi) trifft       → Sprechrecht-Wechsel:
  │                                    talker_ssi = src_ssi
  │                                    t_last_ul_ms = now_ms
  │                                    call_id / umt / voice_ts / group_gssi UNVERÄNDERT
  │                                    → Übergangstabelle Zeile 5
  └─ nichts trifft                   → neuer Ruf, Übergangstabelle Zeile 1
```

Fehlt der `find_by_gssi`-Zweig, belegt das zweite Mitglied einen zweiten Platz mit eigener
Nutzungsmarkierung. Weil `alloc_voice_ts` einen **anderen** freien Zeitschlitz liefert, laufen
danach zwei Rufe derselben Gruppe auf zwei Zeitschlitzen; die Gruppenmitglieder hören nur
einen davon (R-10-05).

**Die Antwort-PDU-Folge ist bewusst nicht dieselbe wie in §3.5.3.** Die Zustandsänderung ist
identisch (P3, R-10-06) — dieselben Platzinhalte, dieselbe Sprechrecht-Buchhaltung —, die
gesendeten PDUs unterscheiden sich, weil das Endgerät hier `U-SETUP` gesendet hat und damit
auf seinem Zeitgeber T303 läuft. T303 wird nur durch `D-CALL PROCEEDING`, `D-ALERT`,
`D-CONNECT`, `D-RELEASE` oder eine Fehlermeldung beendet — `D-TX GRANTED` steht **nicht** in
dieser Liste [ETSI §14.6 Tab. 14.3, T303: *„On the sending of U-SETUP"* / *„On receipt of
D-CALL PROCEEDING, D-ALERT, D-CONNECT, D-RELEASE, Report (failed) ind"*]; nach 60 s baut das
Gerät ab. Deshalb sendet V2 in diesem Zweig:

1. `D-CONNECT` an den neuen Sprechenden, Sendeerlaubnis `00₂`, mit **unveränderter**
   Ruf-Kennung, unveränderter Nutzungsmarkierung und unverändertem `voice_ts` (R-10-07) —
   Kontrollkanal, SCH/F, 3× im 2-Frame-Abstand wie beim Rufaufbau (§3.4.3). Diese PDU
   ersetzt die individuelle `D-TX GRANTED` (R-10-08).
2. `D-TX GRANTED` gruppenadressiert, Sendeerlaubnis `11₂`, mit der Sender-Adresse des neuen
   Sprechenden — Verkehrsschlitz, SCH/HD gestohlen (§2.4), 1×. Damit erfahren die übrigen
   Mitglieder den Sprecherwechsel.

Eine zweite `D-SETUP` an die Gruppe entfällt: der Ruf und seine Kanalzuweisung sind dort
bekannt, neu ist nur der Sprechende. V1 antwortet auf genau dieses Ereignis ebenfalls mit
`D-CONNECT` — der `find_slot_by_gssi`-Zweig fällt in den Gruppen-Zweig mit `stage_d_connect`
[CODE sw/tetra_call_fsm.c:422-436, :471-472] — und dieser Weg ist air-verifiziert
[MESS 2026-05-25; Befund im Repo CODE sw/tetra_call_fsm.c:100-103].

#### 3.5.5 Sprechende beendet

`U-TX CEASED` → Zeile 10. `D-TX CEASED` geht an die **Gruppenadresse**, weil alle Mitglieder
erfahren müssen, dass der Kanal frei ist [ETSI §14.7.1.13]. Der Platz bleibt in `ACTIVE`: die
Reservierung besteht weiter, damit ein erneutes Drücken der Sprechtaste ohne kompletten
Rufaufbau auskommt. Nur der Sprechweg wird nach `T_QUIET` stillgelegt (§3.9).

Dreifache Wiederholung beim **ersten** `U-TX CEASED`, einfache bei jeder weiteren: das
Endgerät wiederholt sein `U-TX CEASED` nach dem Stop-and-Wait-Verfahren, solange es keine
Antwort hört; hört es die erste Antwort, kommt keine Wiederholung
[CODE sw/tetra_call_fsm.c:588-597, air-verifiziert].

#### 3.5.6 Abbau

`U-RELEASE` oder `U-DISCONNECT` → Zeile 12. Die Abbruchursache der Uplink-PDU wird
**gespiegelt**, nicht neu erfunden. Danach:

1. `D-RELEASE` × 3 in die Mailbox (Verkehrsschlitz, SCH/HD).
2. `SLOT_UL_STATE[voice_ts] = unbelegt`, `SLOT_UMT[voice_ts] = 0`.
3. Sprech-Füllinhalt des Zeitschlitzes löschen (`07 §3.3`, `mode = PERSIST_CLEAR`).
4. Zustand `RELEASING`, bis die letzte Wiederholung gesendet ist; dann Platz leeren.

Wichtig: Punkt 2 und 3 erfolgen **nach** dem Einstellen der `D-RELEASE`. Würde man den
Zeitschlitz zuerst freigeben, verlöre die `D-RELEASE` ihren Trägerslot.

### 3.6 Einzelruf

Halbduplex, wie in V1 air-verifiziert. Vollduplex ist Roadmap (`00 §5.2`).

```
t     Richtung   PDU / Aktion
────  ─────────  ─────────────────────────────────────────────────────────────
 0    A  → BS    U-SETUP (ISSI von B, Kommunikationsart 00₂)
FN+0  BS → A     Kapazitätszusage                            (MCCH, SCH/HD)
FN+0  BS → A     D-CALL PROCEEDING                           (MCCH, SCH/F)
FN+0  BS → A     D-ALERT                                     (MCCH, SCH/F)
FN+0  BS → B     D-SETUP, Sendeerlaubnis 11₂, OHNE Kanal     (MCCH, SCH/F)
FN+2  BS → B     D-SETUP, Wiederholung                       (MCCH, SCH/F)
 …    B  → BS    U-ALERT (klingelt) — keine Antwort
 …    B  → BS    U-CONNECT (angenommen)
 …    BS → A     D-CONNECT, Sendeerlaubnis 00₂, MIT Kanal    (MCCH, SCH/F)
 …    BS → B     D-CONNECT ACKNOWLEDGE, MIT Kanal            (MCCH, SCH/F)
 …               Sprache in eine Richtung, Sprechrecht bei A
```

**Unterschied zum Gruppenruf, verbindlich:** Solange es klingelt, trägt weder `D-SETUP` noch
`D-ALERT` eine Kanalzuweisung und keine Nutzungsmarkierung — die Adressierung ist die reine
Teilnehmeradresse. Der Verkehrskanal wird erst mit `D-CONNECT` / `D-CONNECT ACKNOWLEDGE` nach
der Annahme zugewiesen [CODE sw/tetra_call_fsm.c:252-258, :366-367]. Der Sprech-Zeitschlitz
wird beim Belegen des Platzes **reserviert** (er darf nicht an einen anderen Ruf gehen), aber
`SLOT_UL_STATE` bleibt bis zur Annahme auf „unbelegt", damit auf einem klingelnden Kanal keine
Verkehrs-Zuweisung angezeigt wird.

`U-ALERT` erzeugt keine Downlink-Antwort [ETSI §14.7.2.1: *„Response expected: -"*].

**`D-ALERT` sofort statt nach `U-ALERT`.** ETSI ordnet `D-ALERT` semantisch nach dem
Klingeln beim Gerufenen ein [ETSI §14.7.1.1]. V2 sendet es dennoch unmittelbar nach
`D-CALL PROCEEDING`, wie V1: `D-ALERT` erwartet keine Antwort, es startet beim Rufer nur den
Aufbau-Zeitgeber und den Rufton, und ein Endgerät, das kein `U-ALERT` sendet, bekäme sonst
niemals einen Rufton. Die ETSI-strenge Reihenfolge steht als offener Punkt in §6.

### 3.7 Mehrfachbetrieb

#### 3.7.1 Zeitschlitz-Verwaltung

TS1 ist der Kontrollkanal; Sprech-Zeitschlitze sind **TS2, TS3, TS4** (ETSI-Zählung, 1-basiert;
im RTL `tn = 1,2,3`). Damit sind maximal drei gleichzeitige Rufe mit Sprache möglich, obwohl
es acht Ruf-Plätze gibt — die zusätzlichen Plätze deckt der Einzelruf-Aufbau ab, der vor der
Annahme noch keinen Verkehr trägt.

```c
/* Immer der niedrigste freie Sprech-Zeitschlitz. Kein Umlauf-Zustand:
 * deterministisch und nach einem Neustart reproduzierbar.               */
static uint8_t alloc_voice_ts(void)
{
    for (uint8_t ts = VOICE_TS_MIN /*2*/; ts <= VOICE_TS_MAX /*4*/; ts++) {
        int used = 0;
        for (unsigned i = 0; i < CALL_MAX; i++)
            if (g_calls[i].talker_ssi && g_calls[i].voice_ts == ts) { used = 1; break; }
        if (!used) return ts;
    }
    return 0;   /* alle belegt → Übergangstabelle Zeile 3 */
}
```

[CODE sw/tetra_call_fsm.c:144-156 — gleiche Regel, air-verifiziert für zwei parallele
Gruppenrufe auf TS2 und TS3, MESS 2026-05-25.] Die Determiniertheit ist beabsichtigt: bei
einem Umlaufzähler landet derselbe Testfall nach einem Neustart auf einem anderen Zeitschlitz,
und die Fehlersuche in den Luft-Aufzeichnungen wird unnötig schwer.

#### 3.7.2 Zeitschlitz-Zuordnung nach außen

Der zugewiesene Zeitschlitz erscheint an drei Stellen; alle drei folgen aus `voice_ts` und
müssen konsistent sein:

| Ziel | Ableitung | Beleg |
|---|---|---|
| Kanalzuweisungselement der MAC-RESOURCE, Feld „Timeslot assigned" (4 bit) | Bitmuster MSB-first `[TS1,TS2,TS3,TS4]`, also `1 << (4 − voice_ts)`: TS2 → `0100₂` | [ETSI §21.5.2 Tab. 21.87 — `0001₂` = „Timeslot number 4", `1111₂` = „All four timeslots", dazwischen Bitmuster]; [GOLD #5887: `0100₂` = TS2] |
| `SLOT_UMT[voice_ts]`, `SLOT_UL_STATE[voice_ts]` | direkt (`06 §3.12`) | |
| Halteplatz / Zielschlitz der DL-Mailbox | `target_ts = voice_ts`, `mode = PERSIST_SET` (`07 §3.3`) | |

Die Umrechnung liegt in **einem** Modul (`04 §3.2.3`, `00 §2.2`); verstreute `±1` sind ein
Spec-Verstoß. V1 hat dafür bereits eine zentrale Kopfdatei
[CODE sw/tetra_ts_map.h:50-95].

Eine Anmerkung zur Fehlinterpretation in der V1-Dokumentation: das Feld „Up/downlink
assigned" mit Wert `11₂` ist **nicht** reserviert, sondern „Both uplink and downlink"
[ETSI Tab. 21.87]. Die Bewertung „`uplink_downlink_assigned=3` ist laut Spec Reserved" in
`docs/local_cell_decode/DIFF_vs_reference.md:81,:109` stammt aus einer
Aufzählungstyp-Beschriftung der Rust-Referenz, nicht aus ETSI.

#### 3.7.3 Wiederfinden und Freigeben

| Frage | Antwort |
|---|---|
| Wie findet ein späterer Sprechwunsch den bestehenden Ruf? | über `find_by_call_id` bei `U-TX DEMAND`, über `find_by_gssi` bei `U-SETUP` (§3.3, §3.5.4) |
| Wann wird ein Zeitschlitz frei? | bei `U-RELEASE`/`U-DISCONNECT` (§3.5.6), nach `T_STALE` (§3.9), nach `T_ALERT` im Einzelruf |
| Was passiert bei Sprechpause? | Nur der Sprechweg wird stillgelegt. Zeitschlitz, Nutzungsmarkierung und Ruf-Kennung bleiben (§3.9) |
| Beeinflussen sich parallele Rufe? | Nein. Alle Zeitgeber, Aktivmasken und Füllbänke arbeiten **je Zeitschlitz** |

#### 3.7.4 Zuordnung eines Uplink-Sprachbursts zu seinem Ruf

Der Sprachpfad (`12_VOICE`) meldet jeden decodierten Uplink-Sprachburst mit dem
**ETSI-Zeitschlitz aus dem Zeitstempel des Bursts** (R-00-04, `08 §3.7`). Die Rufsteuerung
sucht den Platz mit `voice_ts == etsi_ts` und setzt dessen `t_last_ul_ms`. Es gibt keine
globale Sprachaktivität mehr — V1 hatte eine, und bei zwei Endgeräten auf verschiedenen
Gruppen blieben beide Sprechwege aktiv, wenn nur eines die Sprechtaste losließ
[MESS 2026-05-25, zwei Endgeräte auf verschiedenen Gruppen und verschiedenen Zeitschlitzen:
nach dem Loslassen an einem Gerät blieben **beide** Sprechwege aktiv; behoben durch die
Per-Zeitschlitz-Ruheerkennung dieses Abschnitts].

Der Vergleich `t_last_ul_ms` gegen `now_ms` wird **sättigend** gerechnet: die Meldung aus dem
Sprachpfad kann einen minimal in der Zukunft liegenden Zeitstempel tragen, wenn sie zwischen
zwei Ablesungen der Systemuhr entsteht. Ein vorzeichenloser Unterlauf würde daraus ein
gewaltiges Alter machen und den Ruf sofort freigeben
[CODE sw/tetra_call_fsm.c:66-69, :779-781 — derselbe Schutz].

### 3.8 Nachträglicher Rufeintritt

**Auslöser (ereignisgesteuert, kein periodischer Rundspruch):** die Mobilitätsverwaltung
meldet über `tetra_cmce_call_group_joined(gssi, issi)`, dass ein Endgerät sich einer Gruppe
angehängt oder neu registriert hat. Beide Wege existieren in V1
[CODE sw/tetra_attach_daemon.c:557-564 für den Gruppen-Anhänge-Pfad,
CODE sw/tetra_attach_daemon.c:705-713 für die Registrierung].

**Wirkung:** Für jeden Ruf-Platz mit `group_gssi == gssi` und Zustand `ACTIVE` oder `TALKER`
wird die `D-SETUP` erneut gesendet, mit derselben Ruf-Kennung, derselben Nutzungsmarkierung
und derselben Kanalzuweisung. Damit erfährt das Endgerät den Verkehrs-Zeitschlitz und tritt
bei. Rückgabewert ist die Anzahl der so benachrichtigten Rufe.

**Empfänger und Meldungsanzeiger:** Die PDU geht an die **Gruppenadresse**, nicht an die
einzelne ISSI, und trägt Meldungsanzeiger `000000₂` = Späteinstieg-Rundspruch
[ETSI EN 300 392-9 §7.2.2 Tab. 3]. Genau so macht es das Referenznetz [GOLD #6943]. Der
Gruppen-Adressierung ist der Vorzug zu geben, weil eine ISSI-adressierte Kopie eine zweite
Adressierungsvariante derselben PDU nötig machen würde (P3) und die anderen Mitglieder eine
Wiederholung ohnehin verwerfen.

**Voraussetzung in der Zellaussendung:** Das Bit „Späteinstieg unterstützt" im Zellrundspruch
muss gesetzt sein [ETSI §18.5.8 Tab. 18.50], sonst versucht ein Endgerät den Späteinstieg
nicht. Das Feld liegt in der Zell-Konfiguration (`07 §3.1.3`, `REG_CELL_CFG_0[15]`).

**Verifikationsstand aus V1:** Der Gruppen-Anhänge-Pfad ist air-verifiziert — sechs
Auslösungen, alle erfolgreich, das später hinzugekommene Endgerät trat dem laufenden Ruf bei
[MESS 2026-06-19, Gruppen-Anhänge-Pfad: **6** Auslösungen, **6×** trat das später hinzugekommene Endgerät dem laufenden Ruf bei]. Der Registrierungs-Pfad
(Einschalten während eines laufenden Rufs) ist implementiert, aber nie beim Auslösen
beobachtet worden — er steht als Abnahmefall in §5.

**Zur Häufigkeit:** ETR 300-1 beschreibt den Späteinstieg als *regelmäßig* ausgesendete Meldung
[ETR 300-1 S. 43: *„for the duration of the group call a late entry message would be regularly
transmitted on the site"*]. V2 bleibt bei der ereignisgesteuerten Variante — sie funktioniert
belegt und verbraucht keine Kontrollkanal-Kapazität für Endgeräte, die schon im Ruf sind. Ein
periodischer Takt ist als Konfigurationswert `late_entry_period_frames` vorgesehen,
Vorbelegung 0 = aus (§6 Punkt 6).

### 3.9 Zeitgeber

#### 3.9.1 Zeitgeber der Basisstation

Diese drei Zeitgeber laufen auf der **monotonen Systemuhr**, nicht auf der Luftzeit; ihre
Toleranz ist ≥ 100 ms (`08 §3.6`, R-08-13).

| Name | Wert | Zurückgesetzt durch | Wirkung beim Ablauf | Zustand danach |
|---|---:|---|---|---|
| `T_QUIET` | 300 ms (normativ `12` R-12-11) | jeden UL-Sprachburst auf `voice_ts` | Halteplatz dieses Zeitschlitzes löschen (`07 §3.3`, `mode = PERSIST_CLEAR`), `SLOT_UL_STATE[voice_ts]` von „Verkehr" auf „unbelegt" | unverändert (`ACTIVE`/`TALKER`) |
| `T_STALE` | 5 s **vorläufig** (§6 O-10-8) | jeden UL-Sprachburst auf `voice_ts` | Ruf-Platz freigeben, Zeitschlitz zurück, `SLOT_UMT = 0` | `IDLE` |
| `T_ALERT` | **20 s** | — (läuft ab `t_setup_ms`) | `D-RELEASE` cause `01101₂`, Platz freigeben | `IDLE` |

**Der Unterschied zwischen `T_QUIET` und `T_STALE`** ist die Kernaussage dieses Abschnitts und
in V1 nur aus Kommentaren erschließbar:

- `T_QUIET` schaltet den **Sprechweg** ab. Der Ruf bleibt bestehen, die Ruf-Kennung gilt
  weiter, der Zeitschlitz bleibt diesem Ruf zugeordnet. Ein erneutes Drücken der Sprechtaste
  braucht nur `U-TX DEMAND`/`U-SETUP` und ein `D-TX GRANTED` — keinen Rufaufbau. Der Grund für
  einen kurzen Wert: das Infowort des Zuweisungskanals darf nicht länger „belegt" anzeigen, als
  wirklich Sprache fließt, sonst hält die Endgeräte-Firmware den Kanal für besetzt und
  reagiert träge auf die nächste Sprechtaste.
- `T_STALE` gibt die **Reservierung** frei. Er ist der Aufräummechanismus für ein Endgerät, das
  ohne Abbau-PDU verschwunden ist (Ausschalten, Funkabbruch). Er muss deutlich länger sein als
  `T_QUIET`, damit eine normale Sprechpause die Reservierung nicht kostet.

**Messkontext von `T_QUIET`:** vollständig in `12 §3.6.3` (Nachbarwerte 203 ms und 1000 ms,
Evidenzklassen, Warnung gegen Ändern ohne neue Messreihe). Er wird hier **nicht** wiederholt —
P2, und `12` R-12-11 ist die normative Definition. Für dieses Kapitel zählt nur: wird
„Aussetzer mitten im Ruf" gemeldet, ist die Ursache die Uplink-Empfangsqualität und nicht
dieser Zeitgeber.

**Zur Frame-Zählvariante aus `08 §3.6`.** `08 §3.6` schlägt vor, den Ruhe-Zeitgeber auf die
Burst-Zeitstempel umzustellen — „5 aufeinanderfolgende Frames ohne UL-Burst auf diesem
Zeitschlitz" — und verlangt dafür ausdrücklich eine Gegenmessung gegen die 300 ms. Bis diese
Gegenmessung vorliegt, gilt **hier** der 300-ms-Wert auf der monotonen Systemuhr; die
Frame-Variante wird erst nach der Gegenmessung übernommen und ersetzt dann `12` R-12-11
zusammen mit `08 §3.6`. Zwei unterschiedliche Festlegungen derselben Größe gleichzeitig sind
ein Verstoß gegen P2 — normativ ist `12` R-12-11.

`T_STALE = 5 s` ist eine bewusste Verkürzung gegenüber einem früheren Wert von 30 s: weil
`T_QUIET` das Audio schon nach 300 ms abschaltet, kostet ein langer `T_STALE` nur
Zeitschlitz-Kapazität im Mehrfachbetrieb. Kommt die Abbau-PDU später als 5 s nach dem
Sprachende, wiederholt das Endgerät sie — dass das **folgenlos** sei, ist bislang nur aus
einem Codekommentar behauptet und **nicht gemessen**
[CODE sw/tetra_call_fsm.h:44-48; Befund `17 §3.8` F8.4]. Der Wert ist damit **vorläufig**:
`17` V-17-10 verlangt eine eigene Messreihe, und die Abnahme braucht den Zähler „Abbauwunsch
traf auf freigegebenen Slot" (§3.10).

`T_ALERT = 20 s` liegt bewusst **unter** den Aufbau-Zeitgebern des **rufenden** Endgeräts:
T303 = 60 s ab dem Senden von `U-SETUP` und T302 = max. 60 s ab `D-CALL PROCEEDING`/`D-ALERT`
[ETSI §14.6 Tab. 14.3]. Die Basisstation baut also ab, bevor der Rufer von sich aus abbricht,
und behält damit die Kontrolle über die Ruf-Kennung [CODE sw/tetra_call_fsm.h:50]. T301 ist
hier **nicht** die maßgebliche Grenze: er startet erst mit dem Senden von `U-CONNECT`
[ETSI Tab. 14.3], läuft also erst **nach** der Annahme und nie während des Klingelns —
genau dem Zustand, in dem `T_ALERT` abläuft (§3.9.2).

#### 3.9.2 Zeitgeber der Endgeräte, die die Basisstation bedienen muss

Diese Werte laufen **im Endgerät** [ETSI §14.6 Tab. 14.3]. Sie sind hier aufgeführt, weil sie
die Fristen der Basisstation setzen:

| Zeitgeber | Wert | Läuft im Endgerät ab, wenn … | Konsequenz für die Basisstation |
|---|---|---|---|
| T303 | 60 s | nach `U-SETUP` kein `D-CALL PROCEEDING`, `D-ALERT`, `D-CONNECT`, `D-RELEASE` | großzügig; die Aufbau-Antwort ist unkritisch |
| T302 | max. 60 s | nach `D-CALL PROCEEDING`/`D-ALERT` kein `D-CONNECT`/`D-SETUP`/`D-RELEASE` | begrenzt die Klingeldauer; `T_ALERT` = 20 s liegt weit darunter |
| T301 | max. 30 s | nach dem Senden von `U-CONNECT` kein `D-CONNECT ACKNOWLEDGE` (läuft erst **nach** der Annahme, nicht während des Klingelns) | `D-CONNECT ACKNOWLEDGE` muss kommen, sonst baut das gerufene Gerät ab. Dies ist die **einzige** Stelle, an der T301 die Basisstation bindet (§3.9.1) |
| T308 | max. 10 s | nach `U-DISCONNECT` kein `D-RELEASE` | `D-RELEASE` ist Pflicht; ohne sie wiederholt das Gerät `U-DISCONNECT` |
| T310 | min. 30 s, kein Maximum | Rufzeitgrenze aus `D-CONNECT`/`D-SETUP` abgelaufen | V2 sendet Rufzeitgrenze `0000₂` = unbegrenzt [GOLD]; **damit baut das Endgerät nie von selbst ab** und die Basisstation trägt die gesamte Aufsicht — das ist die Rolle von `T_STALE` |
| T311 | max. 300 s | Sprechrecht länger gehalten als 300 s | nach 300 s sendet das Gerät von selbst `U-TX CEASED`; kein Handlungsbedarf |

### 3.10 Steuergrößen gegenüber `06` und `07`

Die Rufsteuerung schreibt genau vier Dinge nach außen:

| Größe | Wann | Wert |
|---|---|---|
| DL-PDU-Mailbox-Eintrag (`07 §3.3`) | je gesendeter Ruf-PDU, `N`-fach | `W0…W13` codierte Bits, `W14.target_ts` = MCCH-Zeitschlitz oder `voice_ts`, `W14.mode = SINGLE`, `W14.prio = 01₂` (CMCE), `W14.delay_slots = 8·k` (je Eintrag ausgewertet, `07 §3.3`), **`W14.last_fragment = 0`** (Ruf-PDUs sind nie Teil einer Fragmentkette), `W15.pdu_class` = SCH/F oder SCH/HD. Ist `target_ts = voice_ts` und `pdu_class = 01₂`, gilt zusätzlich der Stehl-Vorrang aus §2.4 (Queue vor Halteplatz-Pfad in `04 §3.4`, `steal_override_cnt`) |
| `SLOT_UMT[n]` (`06 §3.12`) | bei jeder Änderung eines Platzes | `umt` des Rufs auf `voice_ts = n`, sonst 0 |
| `SLOT_UL_STATE[n]` (`06 §3.12`) | dito | „Verkehr" während `ACTIVE`/`TALKER` mit frischem Uplink, sonst „unbelegt" |
| Sprech-Füllinhalt (`07 §3.3`, `mode = PERSIST_CLEAR`) | bei `T_QUIET`, bei Abbau | löscht den Halteinhalt des Zeitschlitzes |

**Der Mailbox-Eintrag trägt kein Infowort.** Die Rufsteuerung **berechnet kein Infowort**,
und `W14` hat kein Feld dafür (`07 §3.3`: `W14[20:7]` ist reserviert). Es entsteht in
der Hardware aus Inhaltsklasse, Uplink-Zustand und Nutzungsmarkierung (`06 §3.8.2`). V1
schreibt es direkt [CODE sw/tetra_call_fsm.c:132-138] und hat dafür eine Konstante aus einer
fremden Referenzimplementierung übernommen; die daraus entstandene Verwirrung
(„Wert `0x32CB` kommt im Referenznetz nicht vor") war eine Fehldeutung: das Muster ist
`{11₂, UMt, UMt}` und ergibt `0x32CB` bei UMt = 11 — genau das sendet das Referenznetz auf dem
Verkehrsschlitz [GOLD `docs/reference_decode/dl_events.jsonl`, eigene Auszählung: von den
TS2-Bursts mit Infowort tragen 180 den Wert `0x32CB` mit `f1 = f2 = 11`, 2 den Wert `0x304B`].
Wer die Markierung vergibt, darf das Infowort nicht auch noch selbst bauen (P2).

### 3.11 Fehler- und Randfallverhalten

#### 3.11.1 Fragmentierte Uplink-PDU

**In V2 kann dieser Fall nicht auftreten.** Die Fragment-Zusammensetzung liegt vor der
Rufsteuerung (`06 §3.11`); sie bekommt nur vollständige Körper (R-10-02).

V1 hat hier eine Sonderbehandlung, deren Ursache verschwindet: dort liest die Software den
Rufsteuerungs-Körper aus einem Rohbit-Fenster mit selbst gerechnetem Startoffset
[CODE sw/tetra_attach_daemon.c:1115-1138]. Ein Fragmentanfang einer langen Kurznachricht landete
damit als angeblich vollständiges `U-SETUP` in der Rufsteuerung, die daraufhin einen Sprachkanal
aufbaute; das Endgerät antwortete mit `U-DISCONNECT`, Ursache 10. Der Notbehelf ist eine
Fragment-Sperre vor dem Rufsteuerungs-Aufruf [CODE sw/tetra_attach_daemon.c:1185-1188]. Mit ihr
entfällt auch die Offsetrechnung selbst, deren Sonderfall („BL-DATA mit Prüfsumme fällt in den
Standardzweig, Offset um ein Bit zu früh") dort als Kommentar dokumentiert ist
[CODE …:1118-1128].

#### 3.11.2 Unbekannte Ruf-Kennung

Verworfen, `call_pdu_unknown_cnt` erhöht, **keine** Downlink-PDU (R-10-19). ETSI regelt diesen
Fall nur für die **Endgeräteseite**: ein Endgerät, das eine individuell adressierte
Downlink-PDU mit unbekannter Ruf-Kennung erhält, antwortet mit `U-DISCONNECT`, Ursache
„Invalid call identifier" [ETSI §14.5.6.5.2]. Für eine Uplink-PDU mit unbekannter Kennung
schreibt ETSI der Netzseite **nichts** vor. V2 antwortet bewusst nicht
[ANNAHME — nicht belegte Festlegung: die häufigste Ursache ist eine veraltete Kennung nach
einem Abbau, und eine Antwort darauf löst nur weitere Wiederholungen aus].

#### 3.11.3 Doppelte und verspätete PDUs

| Fall | Verhalten |
|---|---|
| `U-SETUP` desselben Sprechenden wiederholt | Antwortfolge erneut senden, **kein** neuer Platz, dieselbe Ruf-Kennung |
| `U-TX CEASED` wiederholt | einfaches `D-TX CEASED` (§3.5.5) |
| `U-DISCONNECT` wiederholt, Platz schon frei | verworfen, `call_pdu_late_cnt` — kein `D-RELEASE` ohne Platz, weil dessen Ruf-Kennung nicht mehr existiert |
| Ruf-PDU während `RELEASING` | verworfen, `call_pdu_late_cnt` |

#### 3.11.4 Abbruchursachen

Alle Werte nach [ETSI §14.8.18 Tab. 14.55], 5 bit:

| Anlass | Ursache | Wert |
|---|---|---|
| Abbau-PDU des Endgeräts | gespiegelt aus der Uplink-PDU | — |
| kein Ruf-Platz / kein Zeitschlitz frei | „No idle CC entity" | `01100₂` = 12 |
| `T_ALERT` abgelaufen | „Expiry of timer" | `01101₂` = 13 |
| Adresse unbekannt | „Unknown TETRA identity" | `10000₂` = 16 |
| Abbau durch den Betreiber | „SwMI requested disconnection" | `01110₂` = 14 |

> **V1-Befund, der hier korrigiert wird.** Die fünf Ursachen-Konstanten in V1 stimmen
> alle **nicht** mit Tabelle 14.55 überein: `NORMAL_USER_REQ = 0` (Tabelle: 0 = „Ursache
> unbekannt", 1 = „Nutzer hat abgebaut"), `PRE_EMPTIVE_USE = 1` (Tabelle: 9),
> `NETWORK_UNAVAILABLE = 9` (Tabelle: 9 = Vorrangnutzung), `EXPIRY_OF_TIMER = 11`
> (Tabelle: 13; 11 = „vom Gerufenen abgelehnt"), `RESOURCES_UNAVAILABLE = 12`
> (Tabelle: 12 = kein freies CC-Objekt) [CODE sw/tetra_cmce_body.h:40-44]. Wirksam wurde
> das nur an einer Stelle — die Klingeldauer-Abschaltung sendet `0`, also „Ursache
> unbekannt" statt „Zeitgeberablauf" [CODE sw/tetra_call_fsm.c:788] —, weil alle anderen
> Pfade die Ursache aus der Uplink-PDU spiegeln. **V2 leitet die Konstanten aus Tabelle 14.55
> ab und hat für sie einen Unit-Test (§5.1).**

Ein zweiter Befund derselben Art: die Kommentare der Sendeklassen-Aufzählung in V1 nennen
falsche PDU-Typ-Codes — `D-SETUP` als 1, `D-CALL PROCEEDING` als 3, `D-TX GRANTED` als 21,
`D-RELEASE` als 10 [CODE sw/tetra_tx_transport.h:31-35]; die tatsächlich verwendeten Codes im
Aufbauer sind 7, 1, 11, 6 [CODE sw/tetra_cmce_body.c:29-38] und decken sich mit
[ETSI Tab. 14.66]. Wirkungslos, aber irreführend. **V2 hat für PDU-Typ-Codes genau eine
Definition** (P2), und §3.1 ist ihre Belegstelle.

#### 3.11.5 Ressourcen-Erschöpfung

| Fall | Verhalten |
|---|---|
| alle acht Plätze belegt | Zeile 3, `call_slot_full_cnt` |
| alle drei Sprech-Zeitschlitze belegt | Zeile 3, `voice_ts_full_cnt` |
| DL-Mailbox voll bei einer Wiederholung | Wiederholung entfällt, `call_tx_drop_cnt`; die Zustandsänderung findet dennoch statt — eine halb gesendete Antwortfolge ist besser als ein Platz, dessen Zustand nicht zu den gesendeten PDUs passt |
| Nutzungsmarkierungen ausgeschöpft | kann nicht auftreten: 60 Werte gegen 8 Plätze |

### 3.12 Ressourcen-Erwartung

Reine Software. Platz-Tabelle 320 byte, PDU-Zwischenpuffer 32 byte, Zählwerke 15 × 4 byte.
Rechenlast: je Ruf-PDU ein Bit-Packvorgang über maximal 77 bit plus die Kanalcodierung in
`05` — beides fern jeder Frist, weil die Ruf-Signalisierung mit einigen PDUs je Sekunde
arbeitet. `tetra_cmce_call_tick` läuft alle 10 ms über acht Plätze: acht Zeitvergleiche, kein
Registerzugriff, wenn sich nichts ändert. Der Registerzugriff wird **zwischengespeichert**
und nur bei echter Wertänderung ausgeführt [CODE sw/tetra_call_fsm.c:44-49 — gleiche
Vorgehensweise].

### 3.13 Zählwerke (P6, R-10-22)

Alle 16 bit, sättigend, unter eigenem Namen über AXI lesbar. Zurückgesetzt nur durch den
gemeinsamen Zähler-Löschpuls (`07 §3.1.1`).

| Zählwerk | Erhöht bei |
|---|---|
| `call_setup_cnt` | neuem Ruf-Platz |
| `call_release_cnt` | Freigabe durch Abbau-PDU |
| `call_stale_cnt` | Freigabe durch `T_STALE` |
| `call_alert_timeout_cnt` | Freigabe durch `T_ALERT` |
| `call_slot_full_cnt` | `U-SETUP` ohne freien Platz |
| `voice_ts_full_cnt` | `U-SETUP` ohne freien Sprech-Zeitschlitz |
| `floor_grant_cnt` | erteiltem Sprechrecht |
| `floor_via_setup_cnt` | Sprechrecht-Wechsel, der über `U-SETUP` kam (§3.5.4) |
| `floor_via_demand_cnt` | Sprechrecht-Wechsel, der über `U-TX DEMAND` kam |
| `tx_demand_preempt_cnt` | `U-TX DEMAND` mit Priorität `10₂`/`11₂` |
| `quiet_mute_cnt` | Stilllegung eines Sprechwegs durch `T_QUIET` |
| `late_entry_cnt` | nachgesendeter `D-SETUP` (§3.8) |
| `call_pdu_unknown_cnt` | Ruf-PDU mit unbekannter Kennung |
| `call_pdu_late_cnt` | Ruf-PDU im Zustand `RELEASING` oder für einen freien Platz |
| `call_tx_drop_cnt` | Ruf-PDU nicht gestaget, weil die Mailbox voll war |
| `duplex_downgrade_cnt` | `U-SETUP` mit Simplex/Duplex-Wahl **Duplex**, die Stufe 1 als Halbduplex-Ruf fortführt (das Feld wird gespiegelt, nicht erfüllt — §3.2.1) |

`floor_via_setup_cnt` und `floor_via_demand_cnt` sind getrennt, damit man ohne Luft-Aufzeichnung
sieht, welchen der beiden Wege aus §3.5.4 die angeschlossenen Endgeräte benutzen.

`duplex_downgrade_cnt` zählt eine Funktion, die Stufe 1 **nicht** hat: Er ist der
Bedarfsnachweis nach `18` R-18-13 für den Vollduplex-Einzelruf (`18 §3.1.2`). Sollwert im
Testfeld 0; jeder Wert > 0 belegt, dass ein reales Endgerät Vollduplex anfragt, und ist damit
das einzige zulässige Argument, die Funktion aus der Roadmap zu holen.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| `T_QUIET` | 300 ms — **normativ `12` R-12-11**, Messkontext `12 §3.6.3` | siehe `12 §4` | siehe `12 §4`; hier nur die Wirkung auf den Rufzustand (§3.9.1) |
| `T_STALE` | 5 s **vorläufig** | [CODE sw/tetra_call_fsm.h:48]; **keine** Messreihe für die Kehrseite, siehe `17 §3.8` F8.4 und V-17-10 | größer: Zeitschlitz bleibt im Mehrfachbetrieb unnötig belegt. Kleiner: normale Sprechpause kostet die Reservierung. Beide Richtungen sind unquantifiziert — vor der Abnahme neu zu messen (§6 O-10-8) |
| `T_ALERT` | 20 s | [CODE sw/tetra_call_fsm.h:50] | ≥ 60 s: das **rufende** Endgerät bricht über T303 (60 s ab `U-SETUP`) bzw. T302 (max. 60 s) vor der Basisstation ab [ETSI Tab. 14.3]; T301 ist unbeteiligt, er läuft erst ab `U-CONNECT` |
| Wiederholungsabstand Ruf-PDU | 2 TDMA-Frames = 8 Slot-Strobes ≈ 113,3 ms | [GOLD #5887/#5895/#5903: 113 ms / 114 ms] | 0 Frames: gemessene harte Ablehnung des Rufaufbaus [MESS 2026-05-17]. 1 Frame: von V1 gesendet, keine Ablehnung beobachtet, aber ohne Rückhalt in der Referenz |
| `D-CONNECT`-Wiederholungen | 3 | [GOLD, drei bit-identische Kopien] | weniger: geringere Fehlertoleranz auf der Luft. Mehr: Kontrollkanal-Kapazität |
| `D-CONNECT` Rufzeitgrenze | `0000₂` = unbegrenzt | [GOLD #5887] | jeder Wert ≠ 0 lässt das Endgerät nach dieser Zeit selbst abbauen |
| `D-CONNECT` Rufpriorität | `0001₂` | [GOLD #5887] | keine beobachtete Wirkung; Referenzwert beibehalten |
| `D-SETUP` Meldungsanzeiger | `000000₂` = Späteinstieg-Rundspruch | [ETSI EN 300 392-9 §7.2.2 Tab. 3] + [GOLD #6943] | fehlt: das Endgerät kann Späteinstieg nicht von einem neuen Ruf unterscheiden |
| Nutzungsmarkierung-Bereich | 4…63, umlaufend ab 4 | [ETSI §21.4.7.2] + [CODE sw/tetra_call_fsm.c:120-128] | 0…3 sind vorbelegt (UMx/UMa/UMc/UMr) und werden vom Endgerät anders gedeutet |
| Sprech-Zeitschlitze | TS2, TS3, TS4 | [CODE sw/tetra_ts_map.h:28-29] + [MESS 2026-05-25, zwei parallele Gruppenrufe auf TS2 und TS3] | TS1 mitzubenutzen kostet den Kontrollkanal |
| Beobachtungsmuster in der Kanalzuweisung | `11₂` = drei Muster | [GOLD #5887] + [ETSI §9.6 Tab. 9.38] | mit weniger Mustern hört ein sendendes Endgerät nur in einem Teil der Frames — ein gestohlener Halbschlitz (§2.4) kann es dann nicht erreichen |
| Nutzungsmarkierung über den Ruf | konstant | [GOLD #5887 und #6943, beide UMt = 11, 15 s auseinander] | Wechsel beim Sprechrecht-Wechsel: das Endgerät verwirft den Ruf [MESS 2026-05-25] |

---

## 5. Verifikation

### 5.1 Unit-Tests (selbstprüfend, Pflicht)

| Test | Prüft | Kriterium |
|---|---|---|
| `t_cmce_build_all` | Jeden Aufbauer aus §3.1 | Länge und Bitmuster gegen die Tabellen in §3.1; `D-CONNECT` bit-identisch gegen den Referenzkörper aus [GOLD #5887] |
| `t_cmce_build_dsetup_gold` | `D-SETUP` in der 51-bit-Form | bit-identisch gegen [GOLD #6943] einschließlich Meldungsanzeiger |
| `t_cmce_parse_all` | Jede Uplink-PDU aus §3.2 | Feldwerte gegen die Tabellen; `U-SETUP` gegen [GOLD UL #22], `U-TX DEMAND` gegen [GOLD UL #79] |
| `t_cmce_parse_short` | zu kurzer Puffer für jedes Pflichtfeld jeder PDU | Rückgabe `-1`, kein Lesezugriff über `n_bits` hinaus (mit Speicherprüfer) |
| `t_cmce_cause_table` | Abbruchursachen aus §3.11.4 | jeder Wert stimmt mit Tabelle 14.55 überein — dieser Test ist der Grund, warum der V1-Fehler nicht wiederkommt |
| `t_call_fsm_table` | Jede Zeile der Übergangstabelle §3.4.2 | erwartete PDU-Folge, erwarteter Folgezustand, erwartete Zielschlitze |
| `t_call_floor_both_paths` | §3.5.4 | `U-TX DEMAND` und `U-SETUP` desselben Mitglieds führen auf **identische Platzinhalte** (`talker_ssi`, `call_id`, `umt`, `voice_ts`, `group_gssi`, Zustand) — und bewusst **nicht** auf dieselbe PDU-Folge: `U-TX DEMAND` → `D-TX GRANTED` `00₂` + `D-TX GRANTED` `11₂`; `U-SETUP` → `D-CONNECT` `00₂` 3× + `D-TX GRANTED` `11₂`. Der Test prüft beide Folgen explizit (T303-Grund, §3.5.4) |
| `t_call_multi_ts` | §3.7 | drei Gruppen belegen TS2/TS3/TS4; die vierte bekommt `D-RELEASE` cause 12; Freigabe der mittleren gibt TS3 wieder frei |
| `t_call_timers` | §3.9 | `T_QUIET` legt nur einen Zeitschlitz still, `T_STALE` gibt frei, `T_ALERT` gilt nur im Zustand `SETUP` |
| `t_call_fresh_slot_survives_tick` | §3.3, §3.4.2 Zeile 14 | ein gerade belegter Platz übersteht den **ersten** `tetra_cmce_call_tick` und alle Ticks der folgenden 5 s − ε ohne UL-Sprachburst, weil `t_last_ul_ms` beim Belegen auf `now_ms` steht; mit `t_last_ul_ms = 0` muss der Test **fehlschlagen** |
| `t_call_timer_saturate` | §3.7.4 | ein Zeitstempel 5 ms in der Zukunft führt **nicht** zur Freigabe |
| `t_call_id_pool` | R-10-11 | 16383 Vergaben, kein Wert 0, keine Kollision mit einem lebenden Platz |

### 5.2 Gold-Vergleich (strukturell)

Nach `CONVENTIONS.md §3` wird Bit-Identität nur für **strukturelle** Felder gefordert;
Ruf-Kennung, SSI, GSSI, Träger und Nutzungsmarkierung dürfen abweichen.

| Prüfung | Erwartung |
|---|---|
| `D-CONNECT`-Körper Feld für Feld | alle Felder außer Ruf-Kennung identisch zu [GOLD #5887] |
| `D-SETUP`-Körper Feld für Feld | alle Felder außer Ruf-Kennung und Rufer-SSI identisch zu [GOLD #6943]; die Rufer-Adresse darf zusätzlich vorhanden sein (§3.1.3) |
| Wiederholungsabstand `D-CONNECT` | 2 Frames, gleicher Zeitschlitz, gleiche Multiframe — messbar aus der eigenen Aufzeichnung |
| Trägerkanal der In-Ruf-PDUs | `D-TX GRANTED`, `D-TX CEASED`, `D-RELEASE` liegen im **Verkehrsschlitz** als NDB2 mit SCH/HD in BKN1 |
| Infowort auf dem Verkehrsschlitz | `{11₂, UMt, UMt}` während Sprache, Kopf `11₂` mit Feld 1 = UMa während eines gestohlenen Halbschlitzes (`06 §3.8.2` Zeilen 9 und 10) |

### 5.3 Luft-Abnahme

Jeder Fall mindestens **drei** Durchläufe; ein einzelner erfolgreicher Durchlauf gilt nicht.

| # | Fall | Kriterium |
|---:|---|---|
| A1 | Gruppenruf, ein Endgerät | Sprechtaste → Sprache beim Mithörer; `floor_grant_cnt` +1; keine `U-SETUP`-Wiederholung in mehr als einem von drei Durchläufen |
| A2 | Sprechrecht-Wechsel, zwei Endgeräte derselben Gruppe | zweites Gerät bekommt das Sprechrecht; `call_setup_cnt` **unverändert**; Nutzungsmarkierung und Sprech-Zeitschlitz unverändert; `floor_via_setup_cnt` oder `floor_via_demand_cnt` +1 |
| A3 | Zwei Gruppen parallel | zwei Zeitschlitze belegt; Loslassen bei Gruppe 1 legt nur deren Sprechweg still, Gruppe 2 hörbar unbeeinflusst |
| A4 | Abbau durch das Endgerät | genau ein `U-DISCONNECT` je Durchlauf (keine Wiederholungen); `D-RELEASE` in der Aufzeichnung im Verkehrsschlitz; Zeitschlitz danach frei |
| A5 | Endgerät verschwindet ohne Abbau | Freigabe nach `T_STALE`; `call_stale_cnt` +1; Zeitschlitz wieder vergebbar |
| A6 | Einzelruf, Annahme | Klingeln beim Gerufenen, Annahme, Sprache in eine Richtung; `D-CONNECT ACKNOWLEDGE` in der Aufzeichnung |
| A7 | Einzelruf, keine Annahme | Abbau nach `T_ALERT` mit Ursache `01101₂`; `call_alert_timeout_cnt` +1 |
| A8 | Späteinstieg über Gruppen-Anhängen | zweites Gerät wechselt während eines laufenden Rufs die Gruppe und hört Sprache; `late_entry_cnt` +1 |
| A9 | Späteinstieg über Registrierung | zweites Gerät wird während eines laufenden Rufs eingeschaltet und hört Sprache; `late_entry_cnt` +1 — **in V1 nie beim Auslösen beobachtet**, deshalb Pflicht-Abnahmefall |
| A10 | Wiederholungen im Betrieb | über einen zehnminütigen Betrieb mit zwei Endgeräten: `call_pdu_late_cnt` und `call_tx_drop_cnt` bleiben 0; `call_pdu_unknown_cnt` steigt höchstens beim Abbau |

### 5.4 Abnahmekriterium gegen die Aufschaukelung

Die Rufsteuerung darf die in `00 §3.4` beschriebene Spirale nicht auslösen können. Prüfbar:
über einen Durchlauf mit drei Endgeräten und ununterbrochenem Sprechtasten-Wechsel bleibt die
Anzahl der von der Rufsteuerung gestageten DL-PDUs je Sekunde unter **10**. Rechnung: der
teuerste Vorgang ist ein Rufaufbau mit 3 × `D-CONNECT` + 1 × `D-SETUP` = 4 PDUs, ein
Sprechrecht-Wechsel kostet 2, ein Abbau 3. [ANNAHME — Grenzwert aus dieser Rechnung mit
Reserve, nicht gemessen; zu bestätigen im Abnahmelauf A10.]

---

## 6. Offene Punkte

1. **O-10-1 — Halb-Stehlen mit lebender Sprachhälfte.** V2 Stufe 1 stiehlt beide Hälften eines
   Verkehrsbursts (§2.4) und verliert dabei **60 ms** Sprache je gestohlenem Burst — beide
   ACELP-Rahmen à 30 ms dieses Bursts (`12 §3.1.2`, `12 §3.7.2`). Das
   Referenznetz überträgt `D-TX CEASED` mit BKN1 = Signalisierung und BKN2 = lebender
   Sprachhälfte und verliert damit nur 30 ms [GOLD 2. Referenzaufnahme, §2.4]. **Empfehlung:** ein Metadatenbit in der
   DL-Mailbox („BKN2 aus dem Halteinhalt des Zeitschlitzes nehmen") ergänzen und das
   Freigeben von `ndb2 = 1` im Füller-Pfad umsetzen (`06 §3.3.2`, `04 §3.4`). Kostet kein
   neues PDU-Format und keinen zweiten Sendepfad. Vor der Umsetzung messen, ob der
   Sprachverlust überhaupt hörbar ist.
2. **O-10-2 — Kopfblockierung durch das Verzögerungsfeld.** §3.4.3 erzeugt den
   Wiederholungsabstand über `delay_slots` in der DL-Mailbox. Ist die Warteschlange
   FIFO mit kombinatorischem Kopf-Ausgang (`04 §3.5.2`), blockiert ein Eintrag mit
   `delay_slots = 16` die Einträge hinter ihm für zwei Frames. In der beobachteten Last ist
   das folgenlos — das Referenznetz lässt die Slots zwischen den `D-CONNECT`-Kopien
   ebenfalls leer [GOLD, TS1 FN03 und FN05 tragen Leerlauf-NDB2]. **Zu klären in
   Simulation:** ob die Vorrang-Arbitrierung aus `07 §3.3` (`W14.prio`) eine
   Anmeldebestätigung an einer verzögerten Ruf-PDU vorbeilässt. Falls nicht, muss die
   Warteschlange die Verzögerung je Eintrag getrennt prüfen statt nur am Kopf.
3. **O-10-3 — `D-ALERT`-Reihenfolge.** V2 sendet `D-ALERT` sofort nach `D-CALL PROCEEDING` (§3.6),
   ETSI ordnet es nach dem Klingeln beim Gerufenen ein [ETSI §14.7.1.1]. **Empfehlung:**
   umstellen auf „bei `U-ALERT`, ersatzweise nach 500 ms ohne `U-ALERT`", sobald ein
   Endgerät verfügbar ist, das `U-ALERT` nachweislich sendet. In der vorliegenden
   Referenzaufnahme kommt kein `U-ALERT` vor, deshalb ist die Umstellung heute nicht
   abnehmbar.
4. **O-10-4 — Bestätigter Gruppenruf und Rundruf.** Kommunikationsart `10₂` und `11₂` werden von
   V2 Stufe 1 wie ein normaler Gruppenruf behandelt. Der bestätigte Gruppenruf braucht die
   Abfrage der Mitglieder [ETSI §14.5.2.6], der Rundruf muss Sendeanforderungen der
   Empfänger unterdrücken [ETSI §14.5.2.1.0 c)]. **Empfehlung:** Rundruf zuerst — er kostet
   nur ein Bit in „Sendeanforderung erlaubt"; die bestätigte Gruppe nach `18_ROADMAP.md`.
5. **O-10-5 — Warteschlange für Sendewünsche.** V2 erteilt das Sprechrecht sofort und kennt weder
   „in Warteschlange" (`10₂`) noch „nicht erteilt" (`01₂`) in `D-TX GRANTED`
   [ETSI Tab. 14.80]; bei mehr als zwei drängelnden Sprechern entscheidet das zuletzt
   eingetroffene `U-TX DEMAND`. **Empfehlung:** erst `tx_demand_preempt_cnt` und
   `floor_grant_cnt` über einen Betriebstag auswerten; ohne belegten Bedarf nicht bauen.
6. **O-10-6 — Periodischer Späteinstieg.** ETR 300-1 beschreibt ihn als regelmäßige Aussendung
   (§3.8); V2 hat dafür `late_entry_period_frames`, Vorbelegung 0 = aus. **Empfehlung:** aus
   lassen, bis ein Endgerät auftritt, das den ereignisgesteuerten Weg nicht bedient.
7. **O-10-7 — Rufeigentum.** `call_ownership = 0` = „kein Rufeigentümer" [GOLD #5887] wird
   unverändert weitergegeben; damit darf formal jedes Mitglied den Ruf abbauen, und die
   Basisstation prüft die Berechtigung nicht — ETSI stellt die Prüfung ausdrücklich frei
   [ETSI §14.5.2.3.1 NOTE 2]. **Empfehlung:** so lassen, aber `owner_ssi` mitführen (§3.3),
   damit eine spätere Richtlinie ohne Formatänderung greifen kann.
8. **O-10-8 — `T_STALE` ist neu zu messen.** Der Wert 5 s ist aus V1 übernommen, aber für
   **keine** der beiden Richtungen liegt eine Messreihe vor: 30 s → 5 s wurde am 2026-05-25
   ohne Messung umgeschrieben, und die Behauptung „die verspätete Abbau-PDU zu wiederholen ist
   folgenlos" steht nur in einem Codekommentar
   [CODE sw/tetra_call_fsm.h:44-48; Aufarbeitung in `17 §3.8` F8.4, Auflage `17` V-17-10].
   **Empfehlung:** vor der Abnahme eine Messreihe mit 5 / 15 / 30 s und dem Zähler
   „Abbauwunsch traf auf freigegebenen Slot" als Zielgröße; bis dahin bleibt 5 s der
   vorläufige Betriebswert (§3.9.1, §4).
