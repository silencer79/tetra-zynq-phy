# 11 — Kurznachrichtendienst

**Scope:** Der Kurznachrichtendienst (SDS) in beiden Richtungen: Textnachrichten,
Statusnachrichten, lange Nachrichten mit MAC-Fragmentierung über mehrere Bursts, das
Zusammensetzen empfangener Fragmentketten in Software, die Quittierung auf
Sicherungsschicht-Ebene, die Transportschicht SDS-TL und die Reservierungs-Abhängigkeit
langer Nachrichten in Empfangsrichtung.

**Nicht hier:** Rufsteuerung → `10_CMCE_CALL`. Zuweisungs- und Reservierungs-**Mechanik**
(AACH-Halten, Grant-Magazin, Wiederholungen) → `06_MAC §3.9`, Registerseite
→ `07_PS_PL_CONTRACT §3.1.6`. Kanalcodierung → `05_CHANNEL_CODING`. LLC-PDU-Definitionen,
N(S)/N(R)-Zustandshaltung und FCS → `09_LLC_MLE_MM`. MAC-PDU-Kopflayouts
→ `06_MAC §3.4/§3.5`. Verteilung einer gruppenadressierten Kurznachricht an mehrere
Empfänger → `18_ROADMAP` (das Verwurf-Verhalten in Stufe 1 steht in §3.8).

**Abhängigkeiten:** `00_OVERVIEW` (§3.3 vollständige UL-Auswertung in Software, §3.5
Zeitstempel-Pflicht), `05_CHANNEL_CODING` (`tetra_cc_*`), `06_MAC` (§3.4, §3.5, §3.7, §3.9,
§3.10, §3.11), `07_PS_PL_CONTRACT` (§3.3 DL-Mailbox, §3.4 UL-Mailbox), `09_LLC_MLE_MM`.

---

## 1. Anforderungen

**Nachrichtenarten und Codierung**

- **R-11-01** Der Dienst beherrscht vier Vorgänge, jeden in beiden Richtungen:
  Textnachricht in einem MAC-Block, Textnachricht als Fragmentkette, Statusnachricht,
  Transportschicht-Bericht (SDS-TL). Kein weiterer Pfad.
- **R-11-02** Die CMCE-Körper von `D-SDS-DATA`, `U-SDS-DATA`, `D-STATUS`, `U-STATUS` folgen
  §3.1. Jedes Feld ist mit Bitposition und Breite festgelegt; ein Encoder oder Parser mit
  abweichender Feldreihenfolge ist ein Spec-Verstoß.
- **R-11-03** Nutzdaten vom Typ „User defined data-4" (SDTI = 3) tragen im ersten Oktett
  einen Protokollkenner; die Länge steht als 11-bit-Angabe **in Bit** unmittelbar davor
  [ETSI §14.8.24 Tab. 14.63, §14.8.52 Tab. 14.90].
- **R-11-04** Eine Kurznachricht im Downlink wird über die **quittierte** Sicherungsschicht
  gesendet (`BL-DATA`), nicht über die unquittierte (`BL-UDATA`) — in beiden Fällen, einzelner
  Block wie Kette. Nur so erfährt die Basisstation aus der Gegenquittung, dass die Nachricht
  die Schicht 2 des Ziels erreicht hat.

**Quittierung**

- **R-11-05** Eine empfangene Kurznachricht wird auf Sicherungsschicht-Ebene mit `BL-ACK`
  quittiert, wobei `N(R)` **gleich** dem empfangenen `N(S)` ist — kein Inkrement
  [ETSI §22.2.1.1]. Definition und Zustandshaltung: `09_LLC_MLE_MM`.
- **R-11-06** Bei einer Fragmentkette wird **erst nach vollständiger Zusammensetzung**
  quittiert, nie auf das Startfragment. Eine Quittung auf das Startfragment beendet die
  Kette beim Endgerät.
- **R-11-07** Die Quittung wird unabhängig davon gesendet, ob die Nachricht inhaltlich
  auswertbar oder weiterleitbar war. Sie bestätigt den Empfang der TM-SDU, nicht den Dienst.

**Fragmentierung in Senderichtung**

- **R-11-08** Die Fragmentkette im Downlink ist `MAC-RESOURCE(Längenangabe = 111111₂)` +
  `n × MAC-FRAG` + `MAC-END`, `n ≥ 0` [ETSI §23.4.2.1.1].
- **R-11-09** Der Kopf des `MAC-END` im Downlink hat bei π/4-DQPSK **13 bit** ohne
  Kapazitätszusage und **21 bit** mit Kapazitätszusage. Ein 4-bit-Kopf (`MAC-FRAG`-Form)
  ist verboten. Die Feldaufteilung steht in §3.5.2 und darf nicht aus dem `MAC-FRAG`-Kopf
  abgeleitet werden.
- **R-11-10** Passt der Rest der TM-SDU in ein `MAC-FRAG`, aber nicht in ein `MAC-END`, so
  trägt das `MAC-FRAG` den Rest mit Füllbits und es folgt ein **leeres** `MAC-END`
  [ETSI §23.4.2.1.1].
- **R-11-11** Alle Blöcke einer Kette gehen über den **einen** DL-Weg
  (`07_PS_PL_CONTRACT §3.3`, `prio = SDS`) in der Reihenfolge ihrer Erzeugung. Ein
  Seitenkanal über die Halteplätze der Sprachfüllung ist verboten.
- **R-11-12** Frame 18 trägt kein Fragment. Die Unterbrechung ist zulässig
  [ETSI §23.4.2.1.1]; die entstehende Lücke von einem Slot bleibt unter der Verwurfsgrenze
  `N.203 ≥ 4` Slots [ETSI §23.4.3.1.1 Kriterium iii, §B.2]. Der ausgelassene Slot zählt
  gegen `N.203` — die Grenze wird nur deshalb nicht erreicht, weil es ein einzelner Slot ist.

**Zusammensetzen in Empfangsrichtung**

- **R-11-13** Das Zusammensetzen liegt vollständig in Software und ist **generisch**: es
  wertet ausschließlich MAC-Felder aus und stellt keine Anforderung an den Inhalt der
  TM-SDU. Insbesondere wird kein Nachrichtentyp aus einer Position geraten, die von der
  Länge des LLC-Kopfes abhängt.
- **R-11-14** Jede Frist des Zusammensetzens wird aus den TDMA-Zeitstempeln der Bursts
  berechnet (R-00-04), nicht aus einer Software-Uhr und nicht aus dem Frame-Takt der
  Downlink-Empfangskette.
- **R-11-15** Füllbits werden nach [ETSI §23.4.3.2] entfernt, **bevor** die TM-SDU an die
  Sicherungsschicht geht. Damit ist die TM-SDU-Länge exakt und ein vorhandenes
  Prüffeld (FCS) auffindbar und prüfbar.
- **R-11-16** Genau ein Zusammensetzvorgang mit Vollschlitz-Fortsetzung darf je
  Kontrollkanal-Zeitschlitz gleichzeitig offen sein. Begründung und Beleg: §3.7.2.
- **R-11-17** Jeder Abbruchgrund (Zeitgeber, Neustart, fehlgeschlagene Blockdecodierung im
  reservierten Slot, Überlänge, Längenwiderspruch, herrenloses Fortsetzungsfragment) hat
  einen eigenen Zähler (P6).

**Lange Nachrichten in Empfangsrichtung**

- **R-11-18** Eine lange Nachricht im Uplink ist ohne Mehrschlitz-Reservierung nicht
  empfangbar: das Endgerät sendet die Fortsetzungs-Bursts nicht. Die Reservierung ist
  Grundfunktion (`00_OVERVIEW §3.4`), kein Zusatz. Mechanismus: `06_MAC §3.9.5`,
  Registerseite `07_PS_PL_CONTRACT §3.1.6`.
- **R-11-19** Die längste im Uplink unterstützte Nachricht folgt aus der eingestellten
  Kapazitätszusage. Die Grenze steht in §3.9 als Zahl und ist nicht implizit.

**Statusnachrichten**

- **R-11-20** Eine Statusnachricht ist **nie** fragmentiert: sie passt bei
  SSI-Adressierung ohne Prüffeld in einen Unterschlitz (§3.3).
- **R-11-21** Ein Statuswert im Bereich 31 744…32 767 (`0x7C00`…`0x7FFF`) ist **kein**
  Benutzerstatus, sondern ein Kurzbericht der Transportschicht [ETSI §14.8.34 Tab. 14.72].
  Er wird als solcher behandelt, nicht als Status weitergeleitet.

**Weiterleitung**

- **R-11-22** Die Basisstation leitet eine Nachricht nur an ein lokal angemeldetes
  **Einzel**ziel weiter. Ist die Zieladresse eine Gruppenadresse (GSSI), wird die Nachricht
  in Stufe 1 nicht verteilt, sondern mit eigenem Zähler verworfen (§3.8). Jede nicht
  weitergeleitete Nachricht ist mit Grund gezählt und protokolliert.
- **R-11-23** Ob eine Nachricht als einzelner Block oder als Kette zugestellt wird, folgt
  **ausschließlich** aus der Nutzlänge gegen die Blockkapazität (§3.9). Ein fester
  Oktett-Schwellwert im Code ist verboten.

---

## 2. Architektur / Aufbau

### 2.1 Schichtung

```
   Anwendung / Weiterleitungs-Richtlinie      tetra_sds.c            (dieses Kapitel)
   SDS-TL   (Transfer / Report / Kurzbericht) tetra_sds_tl.c         (§3.2)
   CMCE     (D/U-SDS-DATA, D/U-STATUS)        tetra_sds.c            (§3.1)
   MLE      (Protokolldiskriminator, 3 bit)   tetra_mle.c            (09)
   LLC      (BL-DATA / BL-ACK, N(S)/N(R), FCS) tetra_llc.c           (09)
   MAC      (Blockaufbau, Fragmentierung,      tetra_mac_dl.c /       (06 §3.4/§3.5,
             Zusammensetzen, Füllbits)         tetra_mac_reass.c       §3.7, §3.11)
   Codierung                                  tetra_channel_coding   (05)
   Mailbox                                    HAL                    (07 §3.3/§3.4)
```

Die SDS-spezifischen Module sind `tetra_sds.c/.h` (Dienst, CMCE-Körper, Richtlinie) und
`tetra_sds_tl.c/.h` (Transportschicht). Fragmentierung und Zusammensetzen sind **keine**
SDS-Funktionen — sie sind MAC-Funktionen, die für jede lange TM-SDU gelten, auch für eine
mehrfragmentige Mobilitäts-PDU. Dieses Kapitel legt nur ihre SDS-spezifische Parametrierung
und die Randfälle fest; die Mechanik steht in `06_MAC §3.11`.

**Warum diese Trennung normativ ist.** In V1 entscheidet das Zusammensetzen den
Nachrichtentyp mit: der Uplink-Parser liest vier Bit unmittelbar hinter dem
MLE-Diskriminator als „MM-PDU-Typ" [CODE rtl/lmac/tetra_ul_mac_access_parser.v:233-236].
Für eine CMCE-PDU sind das die oberen vier des 5-bit-CMCE-Typs; `U-SDS-DATA` = 15 = `01111₂`
wird als MM-Typ `0111₂` = 7 etikettiert, und die Software muss das rückwärts raten
[CODE sw/tetra_attach_daemon.c:319-321, :933-937]. In V2 trägt die Zusammensetz-Schicht
keinen Typ und rät keinen Offset.

### 2.2 Datenfluss Empfangsrichtung

```
UL-Burst-Mailbox (07 §3.4)   Soft-Werte + (tn,fn,mn,ssn,burst_type,was_reserved)
   ├─ tetra_cc_decode_soft(SCH/HU | SCH/F)                        (05)
   │     └─ Prüffeld verletzt im reservierten Slot → laufende Kette
   │        verwerfen  [ETSI §23.4.3.1.2 Fall ii]
   ├─ MAC-Kopf: PDU-Typ, Fragmentflag, Kapazitätswunsch           (06 §3.5)
   ├─ tetra_mac_reass  Start → Kette anlegen · Fortsetzung → anhängen ·
   │                   Ende → Füllbits entfernen, TM-SDU fertig   (§3.7)
   ├─ tetra_llc_rx     LLC-Typ, N(S), FCS prüfen; BL-ACK N(R)=N(S) (09, R-11-05)
   ├─ tetra_mle_rx     Diskriminator: MM → 09, CMCE → hier         (09)
   └─ tetra_sds        CMCE-Typ 15 → Textnachricht, 8 → Status     (§3.1)
         └─ tetra_sds_tl  Kenner, Nachrichtentyp, Bericht          (§3.2)
               └─ Richtlinie: weiterleiten / Bericht / verwerfen   (§3.8)
```

Der Eintritt in dieses Kapitel ist **eine** Funktion, die eine fertige TM-SDU bekommt —
gleichgültig, ob sie aus einem Block oder aus fünf Fragmenten stammt. Der einfragmentige
und der mehrfragmentige Fall unterscheiden sich in der SDS-Schicht in **nichts**. In V1
existieren dafür zwei getrennte Auswertungszweige mit eigenem Offset-Raten
[CODE sw/tetra_attach_daemon.c:322-379 und :873-990]; genau daraus entstand die Regression,
dass mehrfragmentige Mobilitäts-PDUs im SDS-Zweig landeten und verworfen wurden
[CODE sw/tetra_attach_daemon.c:933-937].

### 2.3 Datenfluss Senderichtung

```
tetra_sds  Nachricht (Ziel, Absender, UDD-4)
   │
   ├─ CMCE-Körper bauen (§3.1)
   ├─ MLE-Diskriminator + LLC BL-DATA mit N(S)        (09)          → TM-SDU
   ├─ tetra_mac_dl: TM-SDU gegen Blockkapazität       (§3.5)
   │     ein Block   → 1 × MAC-RESOURCE
   │     Kette       → MAC-RESOURCE(LI=111111₂) + n × MAC-FRAG + MAC-END
   ├─ tetra_cc_encode(SCH/F) je Block                 (05)
   └─ DL-Mailbox je Block, prio = SDS, letzter Block mit `last_fragment = 1`
                                                      (07 §3.3 W14)
```

---

## 3. Detail-Spezifikation

Bit-Order durchgängig **MSB-first**: Bit 0 ist das zuerst gesendete Bit der jeweiligen
Einheit [ETSI §21.4.0]. ETSI zählt Felder ab 1; die Positionsangaben hier sind 0-basierte
Offsets ab dem Beginn der jeweiligen PDU bzw. des jeweiligen Oktetts.

### 3.1 CMCE-PDUs des Dienstes

#### 3.1.1 `U-SDS-DATA` / `D-SDS-DATA`, CMCE-Typ 15

Beide PDUs haben dieselbe Feldfolge. Zwei Unterschiede, beide normativ: die
Aufwärtsrichtung trägt hinter dem PDU-Typ eine 4-bit-**Gebietsauswahl**, die
Abwärtsrichtung nicht; und die Adresse ist aufwärts die des **Ziels**, abwärts die des
**Absenders**.

| Offset UL | Offset DL | Breite | Feld | Regel |
|---:|---:|---:|---|---|
| 0 | 0 | 5 | PDU-Typ | `01111₂` = 15 |
| 5 | — | 4 | Gebietsauswahl | **nur** Aufwärtsrichtung; wird durchgereicht, nicht ausgewertet |
| 9 | 5 | 2 | Adressart (CPTI) | `00` = Kurznummer (nur UL), `01` = SSI, `10` = SSI + Erweiterung |
| 11 | 7 | 8 / 24 / 48 | Adresse | 8 bei CPTI `00`, 24 bei `01`, 24 + 24 bei `10` |
| … | … | 2 | Nutzdatenart (SDTI) | `00`=16 bit, `01`=32 bit, `10`=64 bit, `11`= Längenangabe + UDD-4 |
| … | … | 11 | Längenangabe | **nur** bei SDTI = `11`; Länge der UDD-4 **in Bit**, 0…2047 |
| … | … | var | Nutzdaten | Breite nach SDTI |
| … | … | 1 | o-Bit | `0` = keine Typ-2/3-Elemente |

[ETSI §14.7.2.8 Tab. 14.28 (UL), §14.7.1.10 Tab. 14.13 (DL); Längenangabe §14.8.24
Tab. 14.63; UDD-4 §14.8.52 Tab. 14.90]. V1 parst und baut genau diese Reihenfolge
[CODE sw/tetra_cmce_parser.c:150-199, CODE sw/tetra_cmce_body.c:283-299,
CODE sw/tetra_sds_dl_frag.c:27-42].

**Kopflänge bei SSI-Adressierung und SDTI = 11:** aufwärts 5+4+2+24+2+11 = **48 bit**,
abwärts **44 bit**, jeweils plus 1 o-Bit hinter den Nutzdaten. Der Wert ist gegen ETSI
nachrechenbar: EN 300 392-2 gibt die längste empfohlene UDD-4 auf dem Basic-Link mit
Prüffeld als 1 017 bit an, „durch Subtraktion von 89 bit von der längsten empfohlenen
TM-SDU" (1 106 bit) [ETSI §14.7.2.8 Tab. 14.28 NOTE 5, §23.4.2.1.0 Tab. 23.7].
89 = 37 (`BL-DATA` mit 32-bit-Prüffeld) + 3 (MLE) + 48 (`U-SDS-DATA`-Kopf) + 1 (o-Bit).

#### 3.1.2 `U-STATUS` / `D-STATUS`, CMCE-Typ 8

| Offset UL | Offset DL | Breite | Feld |
|---:|---:|---:|---|
| 0 | 0 | 5 | PDU-Typ `01000₂` = 8 |
| 5 | — | 4 | Gebietsauswahl (**nur** Aufwärtsrichtung) |
| 9 | 5 | 2 | Adressart (CPTI) |
| 11 | 7 | 8/24/48 | Adresse (aufwärts Ziel, abwärts Absender) |
| … | … | 16 | Statuswert |
| … | … | 1 | o-Bit |

[ETSI §14.7.2.7 Tab. 14.27, §14.7.1.11 Tab. 14.14]. Die fehlende Gebietsauswahl in der
Abwärtsrichtung ist der häufigste Fehler bei dieser PDU; V1 setzt beide Varianten richtig
[CODE sw/tetra_cmce_parser.c:201-228, CODE sw/tetra_cmce_body.c:305-316].

### 3.2 SDS-TL — die Transportschicht in der UDD-4

Die UDD-4 beginnt **immer** mit einem 8-bit-Protokollkenner [ETSI §14.8.52 Tab. 14.90].
Er entscheidet, ob die Transportschicht SDS-TL benutzt wird:

| Kenner | Bedeutung | SDS-TL |
|---|---|---|
| `0x02` | Einfache Textnachricht | **nein** |
| `0x03` | Einfaches Ortungsprotokoll | nein |
| `0x09` | Einfache Sofort-Textnachricht | nein |
| `0x0A` | Ortungsinformations-Protokoll | nein |
| `0x82` | Textnachricht | **ja** |
| `0x83` | Ortungssystem | ja |
| `0x89` | Sofort-Textnachricht | ja |
| `0x8A` | Nachricht mit Benutzerdaten-Kopf | ja |

[ETSI §29.4.3.9 Tab. 29.21]. Kenner mit gesetztem höchstem Bit benutzen SDS-TL
(NOTE 5 der Tabelle), Kenner darunter nicht (NOTE 2). V1 lässt genau
`{2, 3, 9, 10, 130, 131, 137, 138}` durch [CODE sw/tetra_attach_daemon.c:234-235] — dieselbe
Menge, aber als Zahlenliste ohne die Regel dahinter.

#### 3.2.1 `SDS-TRANSFER` (Kenner mit SDS-TL)

Aufbau ab Oktett 1 der UDD-4 (Oktett 0 = Kenner):

| Oktett | Bits | Feld | Regel |
|---:|---|---|---|
| 1 | 7…4 | Nachrichtentyp | `0000₂` = `SDS-TRANSFER`, `0001₂` = `SDS-REPORT`, `0010₂` = `SDS-ACK` |
| 1 | 3…2 | Zustellberichts-Wunsch | 2 bit |
| 1 | 1 | Dienstauswahl / Kurzberichtsform | aufwärts: `0` = nur Einzelzustellung, `1` = Gruppen- oder Einzelzustellung erlaubt; abwärts: Kurzberichtsform [ETSI §29.4.3.10 Tab. 29.22]. Auswertung: §3.8 |
| 1 | 0 | Speicher-/Weiterleitungssteuerung | 1 = Gültigkeitsdauer + Weiterleitungsadresse folgen |
| 2 | 7…0 | Nachrichtenreferenz | vom Erzeuger gesetzt, im Bericht zurückgespiegelt |
| 3… | | Gültigkeitsdauer / Weiterleitungsadresse | **nur** wenn Oktett 1 Bit 0 = 1 |
| … | | Benutzerdaten | siehe §3.2.2 |

[ETSI §29.4.2.4 Tab. 29.14; Nachrichtentyp §29.4.3.8 Tab. 29.20;
Speicher-/Weiterleitungssteuerung §29.4.3.12 Tab. 29.24].

#### 3.2.2 Benutzerdaten bei Textnachricht (Kenner `0x82` / `0x89`)

| Oktett | Bits | Feld |
|---:|---|---|
| 0 | 7 | Zeitstempel vorhanden |
| 0 | 6…0 | Textcodierung: `0000000₂` = 7-bit-Alphabet, `0000001₂` = ISO 8859-1, … |
| 1…3 | | Zeitstempel (24 bit), **nur** wenn Bit 7 = 1 |
| … | | Text |

[ETSI §29.5.3.3 Tab. 29.28, Textcodierung §29.5.4.1 Tab. 29.29].

**Normativer V2-Fix.** V1 baut den Sende-Kopf als feste Folge `82 04 04 <n>` und erhöht
`<n>` je Nachricht [CODE sw/tetra_attach_daemon.c:291-296]. Nach Tab. 29.14 + 29.28 ist das
vierte Oktett aber „Zeitstempel vorhanden + Textcodierung" und das **dritte** die
Nachrichtenreferenz. V1 erhöht damit die Textcodierung: die erste Nachricht ist ISO 8859-1
(Wert 1) — richtig —, die zweite ISO 8859-2, die dritte ISO 8859-3, und ab Wert 28
(`0011100₂`) verlässt das Feld den definierten Bereich: 28…31 sind reserviert, 32…126 sind
anwendungsdefiniert [ETSI §29.5.4.1 Tab. 29.29]. V2 setzt: Oktett 2 = laufende Nachrichtenreferenz,
Oktett 3 = `0x01` (kein Zeitstempel, ISO 8859-1) konstant. Dass ISO 8859-1 der richtige
Wert ist, ist an echten Endgeräte-Nachrichten belegt [MESS 2026-06-07, Text der
reassemblierten UL-Ketten ist 8-bit/Latin-1, nicht 7-bit-GSM].

#### 3.2.3 Berichte

Zwei Formen, beide von der Gegenstelle erzeugt:

**`SDS-REPORT`** — getragen in der UDD-4 einer `D/U-SDS-DATA`:
Kenner(8) + Nachrichtentyp(4)=`0001₂` + Quittungsanforderung(1) + reserviert(2)=`00₂` +
Speicher-/Weiterleitungssteuerung(1) + Zustellstatus(8) + Nachrichtenreferenz(8)
[ETSI §29.4.2.2 Tab. 29.12]. Zustellstatus `0x00` = „Empfang durch Ziel bestätigt",
`0x02` = „durch Ziel konsumiert" [ETSI §29.4.3.2 Tab. 29.16].
Belegt im Betrieb: das Ziel-Endgerät antwortete mit `82 10 00` = Kenner `0x82`,
Nachrichtentyp `0001₂`, Quittung nicht gefordert, Zustellstatus `0x00`
[MESS 2026-06-02].

**`SDS-SHORT REPORT`** — getragen im 16-bit-Statuswert einer `D/U-STATUS`:

| Bits | Breite | Feld | Wert |
|---|---:|---|---|
| 15…10 | 6 | SDS-TL-Kennung | `011111₂` |
| 9…8 | 2 | Kurzberichtsart | `00` Protokoll nicht unterstützt, `01` Speicher voll, `10` empfangen, `11` konsumiert |
| 7…0 | 8 | Nachrichtenreferenz | wie in der Anforderung |

[ETSI §29.4.2.3 Tab. 29.13, Kurzberichtsart §29.4.3.11 Tab. 29.23]. Daraus folgt R-11-21:
der Wertebereich `0x7C00`…`0x7FFF` (= 31 744…32 767) ist der Transportschicht vorbehalten
[ETSI §14.8.34 Tab. 14.72]; `0x0000` ist „Notfall", `0x0001`…`0x7BFF` sind reserviert,
`0x8000`…`0xFFFF` sind netz- und benutzerdefiniert.

**V2-Regel für die Weiterleitung:** Ein Statuswert im Transportschicht-Bereich wird als
Bericht der Transportschicht behandelt — Zuordnung über die Nachrichtenreferenz zu einer
offenen Zustellung, dann Weiterleitung an den ursprünglichen Absender. Ein Wert außerhalb
dieses Bereichs wird unverändert als Statusnachricht weitergeleitet. V1 leitet jeden Wert
gleich weiter [CODE sw/tetra_attach_daemon.c:1159-1174]; das ist im beobachteten Fall
richtig, weil das Endgerät den Bericht selbst an den Absender adressiert, aber es ist keine
Regel, sondern ein Zufall.

### 3.3 Statusnachrichten — der einfache Fall

Eine `U-STATUS` mit SSI-Adressierung ergibt die TM-SDU

```
LLC BL-DATA ohne Prüffeld (4 + 1)  +  MLE-Diskriminator (3)
  +  U-STATUS (5 + 4 + 2 + 24 + 16 + 1)   =  8 + 52  =  60 bit
```

60 bit passen in die maximal 62 bit TM-SDU eines `MAC-ACCESS` ohne Optionalfeld
[ETSI §21.4.2.1 Tab. 21.43]. Eine Statusnachricht ist deshalb **immer** ein einzelner
Uplink-Unterschlitz und wird nie fragmentiert (R-11-20). Mit 32-bit-Prüffeld wären es
92 bit — dann greift die Zweifragment-Kette aus §3.7.1; dieser Fall ist zu behandeln, ist
aber nicht beobachtet.

Die `D-STATUS` ergibt `8 + (5 + 2 + 24 + 16 + 1)` = **56 bit** TM-SDU und passt damit in
einen `SCH/HD`-Block (Kapazität 124 − 43 = 81 bit bei SSI-Adressierung, `06_MAC §3.4.1`).
Statusnachrichten werden deshalb auf `SCH/HD` gesendet, nicht auf `SCH/F`.

**Verifikationsstand, ehrlich:** Die Statusnachricht ist in V1 vollständig vorhanden —
Parser [CODE sw/tetra_cmce_parser.c:201-228], Körperbau [CODE sw/tetra_cmce_body.c:305-316],
Weiterleitung [CODE sw/tetra_attach_daemon.c:1159-1174] —, aber **nicht
luftverifiziert**. Es liegt kein Air-Test-Protokoll vor, und in beiden Referenz-Aufzeichnungen
kommt keine Statusnachricht vor [GOLD `docs/reference_decode/` — keine SDS- oder
Status-PDU in 7 338 DL- und 192 UL-Bursts]. Der Wertebereich aus R-11-21 ist damit
ausschließlich ETSI-belegt, nicht messbelegt.

### 3.4 Kurze Nachrichten und die Quittung

#### 3.4.1 Empfangsrichtung, ein oder zwei Unterschlitze

Der Ablauf, mit dem eine kurze Textnachricht ankommt und quittiert wird:

```
UL  SCH/HU  MAC-ACCESS, Fragmentflag = 1, Kapazitätswunsch = 1 Unterschlitz
DL  SCH/HD  Kapazitätszusage (Vorantwort)  — Mechanik 06 §3.9
UL  SCH/HU  MAC-END-HU im zugesagten Unterschlitz
DL  SCH/HD  MAC-RESOURCE + LLC BL-ACK, N(R) = empfangenes N(S)
DL  SCH/F   MAC-RESOURCE + LLC BL-DATA + D-SDS-DATA an das Ziel (Weiterleitung)
```

Die Quittung geht **vor** der Weiterleitung; sie hängt nicht davon ab, ob das Ziel erreichbar
ist (R-11-07). V1 macht das so [CODE sw/tetra_attach_daemon.c:345-374] und die
Wirkung ist gemessen: mit Quittung verschwindet die Fehlermeldung am Sende-Endgerät und die
Wiederholungen hören auf [MESS 2026-06-02, `SDS-BL-ACK rc=0 nr=1`, Relay `rc=0`,
Bestätigung durch den Benutzer].

`N(R) = N(S)` ist keine Design-Entscheidung, sondern normativ: „The peer entity acknowledges
the successful reception of this BL-DATA PDU by sending the **same** TL-SDU number N(R) in
the acknowledgement BL-ACK PDU", mit der ausdrücklichen Anmerkung, dass dies im Gegensatz zu
den meisten HDLC-Protokollen steht [ETSI §22.2.1.1 mit NOTE]. `BL-ACK` ohne Prüffeld ist
4 bit LLC-Typ (`0011₂`) + 1 bit `N(R)` [ETSI §21.2.2.1 Tab. 21.4, Typtabelle §21.2.1
Tab. 21.1]. Die vollständige Definition und die Zustandshaltung stehen in
`09_LLC_MLE_MM`; hier gilt nur die Anwendung.

#### 3.4.2 Senderichtung, ein Block

Eine `D-SDS-DATA` geht in einem `SCH/F`-Block, solange die TM-SDU in die Blockkapazität
passt. Der Block trägt die Kapazitätszusage für den Zustellbericht des Empfängers, also
`slot granting flag = 1` mit 8-bit-Zusageelement: `MAC-RESOURCE`-Kopf = 43 + 8 = **51 bit**
(`06_MAC §3.4.1`), Kapazität 268 − 51 = **217 bit** TM-SDU. Mit
`TM-SDU = 53 + 8·L` (L = UDD-4 in Oktetten, `BL-DATA` ohne Prüffeld) folgt
**L ≤ 20 Oktette** für den Einzelblock.

Zwei V1-Befunde, die V2 durch R-11-23 auflöst:

1. Der Körperbauer erlaubt `L ≤ 24` [CODE sw/tetra_cmce_body.c:286], die Transportfunktion
   dahinter aber nur 128 Körperbits [CODE sw/tetra_tx_transport.c:176], also
   `45 + 8·L ≤ 128` → **L ≤ 10**. Für 11…24 Oktette liefert `tetra_tx_submit` still `-1`,
   und die Weiterleitungszweige [CODE sw/tetra_attach_daemon.c:360, :967] prüfen nur
   `L ≤ 24` und greifen deshalb nicht zur Fragmentierung. Das Band 11…24 Oktette fällt
   in V1 durch.
2. Der Einzelblock-Pfad benutzt die **unquittierte** Sicherungsschicht `BL-UDATA`
   [CODE rtl/include/tetra_pdu_class.vh:137, ausgewählt in
   rtl/lmac/tetra_mle_registration_fsm.v:338-341], der Kettenpfad die quittierte `BL-DATA`
   [CODE sw/tetra_sds_dl_frag.c:59]. Damit erhält die Basisstation für kurze Nachrichten
   keine Gegenquittung und kann keinen Zustellbericht erzeugen. R-11-04 vereinheitlicht das
   auf `BL-DATA`.

### 3.5 Lange Nachrichten in Senderichtung

#### 3.5.1 Kettenaufbau und Kapazitäten

| Block | MAC-PDU | Kopflänge | TM-SDU-Kapazität auf `SCH/F` | Beleg |
|---|---|---:|---:|---|
| erster | `MAC-RESOURCE`, Längenangabe = `111111₂` | 43 bit (SSI, 3 Präsenzflags, keine Elemente) | **225** | [ETSI §21.4.3.1 Tab. 21.55], `06_MAC §3.4.1` |
| Fortsetzung | `MAC-FRAG` | 4 bit | **264** | [ETSI §21.4.3.2 Tab. 21.57/21.58] |
| letzter | `MAC-END`, ohne Kapazitätszusage | 13 bit | **255** | [ETSI §21.4.3.3 Tab. 21.59/21.60] |
| letzter | `MAC-END`, mit Kapazitätszusage | 21 bit | **247** | dito |

`111111₂` = 63 ist normativ „Start of fragmentation" [ETSI §21.4.3.1 Tab. 21.55]; V1 setzt
den Wert so [CODE sw/tetra_sds_dl_frag.c:110].

Erzeugungsalgorithmus, verbindlich (identisch zu [ETSI §23.4.2.1.1]):

```
T = TM-SDU-Bitlänge
Block 0:  MAC-RESOURCE(LI = 111111₂, keine Zusage) + min(T, 225) bit
R = T - min(T, 225)
solange R > END_CAP:                      /* END_CAP = 247, Zusage im MAC-END */
    MAC-FRAG + min(R, 264) bit;  R -= min(R, 264)
MAC-END + R bit                            /* R darf 0 sein: leeres MAC-END */
```

Der Zweig „R = 0 → leeres `MAC-END`" ist der Fall aus R-11-10. Er tritt in zwei Lagen ein:
wenn `END_CAP < R ≤ 264` gilt (das vorangehende `MAC-FRAG` nimmt den Rest auf), und wenn
`T ≤ 225` gilt, die TM-SDU also vollständig in den ersten Block passt, dieser aber wegen der
fehlenden Zusage keinen Einzelblock bilden kann (§3.4.2, `L = 21`). V1 implementiert den
Zweig [CODE sw/tetra_sds_dl_frag.c:155-165].

#### 3.5.2 Der `MAC-END`-Kopf im Downlink — vollständig, damit er nicht falsch wird

Dies ist die Stelle, an der V1 einen luftwirksamen Fehler hatte: der Kopf wurde mit den
4 bit des `MAC-FRAG` gebaut. Das Ziel-Endgerät liest den Block nach Tabelle 21.59, findet in
den TM-SDU-Bits eine Längenangabe von 39 Oktetten = 312 bit > Blockgröße, verwirft die
Zusammensetzung und stellt die Nachricht nicht zu. Kurze Nachrichten waren nicht betroffen,
weil sie kein `MAC-END` haben [MESS 2026-06-19; CODE sw/tetra_sds_dl_frag.c:132-146].

**Vollständige Feldaufteilung** [ETSI §21.4.3.3 Tab. 21.59]:

| Offset | Breite | Feld | Anwesenheit | Wert in der SDS-Kette |
|---:|---:|---|---|---|
| 0 | 2 | MAC-PDU-Typ | immer | `01₂` |
| 2 | 1 | MAC-PDU-Untertyp | immer | `1` = `MAC-END` |
| 3 | 1 | Füllbit-Anzeige | immer | nach `06_MAC §3.7` F4 |
| 4 | 1 | Position der Zusage | immer | `0` = Zusage gilt auf diesem Kanal |
| 5 | 6 | Längenangabe | immer | Oktette der **gesamten** `MAC-END`-PDU |
| — | 1 | Sofort-Ruhe-Erlaubnis | **nur** π/8-D8PSK und QAM | **entfällt** bei π/4-DQPSK |
| 11 | 1 | Zusage-Flag | immer | `1` wenn eine Kapazitätszusage folgt |
| — | 1 | Mehrschlitz-Zusage-Flag | **nur** QAM **und** Zusage-Flag = 1 | **entfällt** |
| 12 | 8 | Basis-Zusageelement | nur wenn Zusage-Flag = 1 | `[7:4]` Kapazität, `[3:0]` Verzögerung |
| 20 | 1 | Kanalzuweisungs-Flag | immer | `0` |
| — | var | Kanalzuweisungselement | nur wenn Flag = 1 | entfällt |
| 21 | var | TM-SDU | — | letztes Fragment |

Die beiden mit „entfällt" markierten Felder sind der eigentliche Fallstrick: sie stehen in
der ETSI-Tabelle zwischen den anderen, sind aber bei π/4-DQPSK **nicht vorhanden**
(NOTE 2 und NOTE 3 der Tabelle). Daraus folgen genau zwei mögliche Kopflängen:

- **13 bit** ohne Kapazitätszusage: 2+1+1+1+6+1+1. ETSI nennt diesen Wert direkt
  („The minimum header length of a MAC-END PDU shall be equal to 13 bits when sent using
  π/4-DQPSK modulation") und bestätigt ihn über die maximale TM-SDU auf `SCH/F` von
  255 bit = 268 − 13 [Tab. 21.60].
- **21 bit** mit Kapazitätszusage: 13 + 8. Kapazität 247 bit = 268 − 21.

**Längenangabe:** Sie zählt die gesamte `MAC-END`-PDU (Kopf + TM-SDU) in Oktetten; für
π/4-DQPSK gilt `Y2 = Z2 = 1`, der Wert ist also direkt die Oktettzahl
[ETSI §21.6 Tab. 21.98]. Also `LI = ceil((Kopfbits + TM-SDU-Bits) / 8)`. V1 rechnet genau so
[CODE sw/tetra_sds_dl_frag.c:137]. Der Wert `000000₂` ist reserviert; wird das leere
`MAC-END` gesendet, ist `LI = 3` (21 bit → 3 Oktette).

**Füllbits:** nach `06_MAC §3.7` F4 — ein Bit `1` unmittelbar hinter dem letzten Nutzbit,
dann `0` bis `LI·8`; Füllbit-Anzeige = 1 genau dann, wenn Füllbits vorhanden sind
[ETSI §23.4.2.2].

**Kapazitätszusage in der Kette:** ETSI erlaubt die Zusage im ersten **oder** im letzten
Block, nicht in den Fortsetzungen [ETSI §23.4.2.1.1]. V2 legt sie in das `MAC-END`
(Zusage-Flag = 1, Zusageelement `0x00` = erster Unterschlitz, keine Verzögerung
[ETSI §21.5.6 Tab. 21.96]) — dort weist sie dem Empfänger den Unterschlitz für seinen
Zustellbericht zu, und nur dort ist zum Sendezeitpunkt bekannt, dass die Kette vollständig
ist. Ein Kanalzuweisungselement darf ausschließlich im `MAC-END` stehen, nie im
`MAC-RESOURCE` [ETSI §23.4.2.1.1] — in Stufe 1 wird es nicht benutzt.

V1 setzt die Zusage im `MAC-END` ebenfalls (Flag 1, Element `0x00`)
[CODE sw/tetra_sds_dl_frag.c:143-144] und sendet **zusätzlich** hinterher einen eigenen
`SCH/HD`-Block mit `AL-SETUP` und derselben Zusage
[CODE sw/tetra_sds_dl_frag.c:170-190, ausgelöst in sw/tetra_attach_daemon.c:854]. Das ist der
zweite Pfad für dieselbe Funktion, den P3 verbietet: V2 sendet die Zusage **nur** im
`MAC-END`. Abnahmekriterium dafür ist §5.4 Punkt 3 — der Zustellbericht des Empfängers muss
den ursprünglichen Absender erreichen.

#### 3.5.3 Assoziation im ersten Block

Der erste Block **darf** vor dem Fragmentstart eine weitere, vollständige MAC-PDU tragen;
das Fragment muss die **letzte** PDU des Blocks sein [ETSI §23.4.2.1.1]. V1 nutzt das und
legt die `BL-ACK` an den Absender (Längenangabe 6 Oktette = 48 bit) vor den Fragmentstart
[CODE sw/tetra_sds_dl_frag.c:86-118]; die Kapazität von Block 0 sinkt dadurch von 225 auf
177 bit.

**V2:** Die Assoziation ist erlaubt und wird generisch in `tetra_mac_dl.c` implementiert
(`06_MAC §6`, Punkt 5), ist aber **kein Sonderfall des SDS-Pfades**. Standard ist ein
eigener Block je Adresse, weil die Quittung an einen anderen Teilnehmer geht als die Kette
und die Ersparnis genau ein Kontrollkanal-Slot ist. Wird assoziiert, ist die Kapazität von
Block 0 `268 − 43 − (Bits der vorangestellten PDU)`; der Erzeuger muss diesen Wert
mitrechnen, ein konstantes 177 ist verboten.

#### 3.5.4 Zeitliche Abgabe der Kette

- **Ein Block je TDMA-Frame** auf dem Kontrollkanal-Zeitschlitz. Die Grenze ist die
  Lückenregel des Empfängers: er verwirft, wenn er in `N.203` aufeinanderfolgenden Slots
  dieses Kontrollkanals kein Fragment sieht, Standardwert `N.203 ≥ 4`
  [ETSI §23.4.3.1.1 Kriterium iii, §B.2].
- **Frame 18 trägt kein Fragment** (R-11-12). Die Unterbrechung für eine
  Rundspruch-Nachricht ist ausdrücklich zulässig [ETSI §23.4.2.1.1]; die entstehende Lücke
  von einem Slot liegt weit unter `N.203`. V1 löst dasselbe Problem anders: es verschiebt
  den Kettenstart so, dass die ganze Kette vor Frame 18 liegt
  [CODE sw/tetra_attach_daemon.c:820-831], weil in V1 der Sendeweg der Kette in Frame 18
  unterdrückt wird [CODE rtl/tx/tetra_burst_dispatcher.v:226-227 — `tx_fn_sys <= 5'd16`].
  Mit dem einheitlichen DL-Weg aus R-11-11 entfällt dieses Startfenster.
- **Kein weiterer Fragmentstart dazwischen.** Der Empfänger verwirft seine
  Teilzusammensetzung, sobald er auf diesem Kontrollkanal **irgendeine** `MAC-RESOURCE` mit
  Längenangabe `111111₂` sieht — auch an eine fremde Adresse
  [ETSI §23.4.3.1.1 Kriterium i]. Es darf also nie mehr als eine Kette gleichzeitig auf
  einem Kontrollkanal laufen. Das ist eine Sende-Seriengrenze, kein Empfangsproblem.
- **AACH des letzten Blocks.** Das Infowort folgt aus der Inhaltsklasse desselben Slots
  (R-06-04); der letzte Block wird über `last_fragment = 1` in der DL-Mailbox markiert
  [07 §3.3 W14 Bit 27]. V1 erreicht dasselbe über ein verstecktes Bit in einem
  Sprachregister [CODE sw/tetra_attach_daemon.c:840-844,
  rtl/tetra_zynq_top.v:3899-3910] — in V2 ist es ein benanntes Feld des einen DL-Wegs.

### 3.6 Lange Nachrichten in Empfangsrichtung — die Reservierung

Ohne Mehrschlitz-Reservierung sendet das Endgerät die Fortsetzungs-Bursts nicht. Das ist
gemessen und war die Ursache, warum lange Nachrichten im Uplink zunächst nicht
funktionierten:

> Das Endgerät sendete Startfragment + **1** Fortsetzungs-Burst, dann endlos Wiederholungen
> des Startfragments. Drei Hypothesen wurden falsifiziert (verfrühte Quittung, falsches
> Zusageelement, eine begleitende zweite PDU). Die Ursache war das Zugriffszuweisungs-Feld:
> nach einer Zusage über N Slots muss die Basisstation den Uplink auf dem betreffenden
> Zeitschlitz für N aufeinanderfolgende Frames **reserviert halten**. Die Referenz hält drei
> Frames, V1 öffnete den Zugriff bereits im Folgeframe wieder. Nach der Korrektur:
> Startfragment + 3 Fortsetzungs-Bursts, 6 vollständige Ketten à 842 bit, bit-identisch zu
> den Referenz-Fragmenten. [MESS 2026-06-10 / 2026-06-12]

**Der Mechanismus steht nicht hier.** Zusage, Wiederholung, Halten des Infoworts und die
Frame-18-Ausnahme sind in `06_MAC §3.9` spezifiziert (R-06-14, R-06-15), die
Registerseite in `07_PS_PL_CONTRACT §3.1.6` (`REG_UL_ASSIGN_CFG` mit `GRANT_REPEAT`,
`GRANT_GAP`, `GRANT_HOLD_MAX`, `GRANT_ARM_TIMEOUT`; Zusagewert und Haltedauer über
`cap_alloc` des Magazin-Eintrags in `REG_GRANT_MAG_CTRL`). Dieses Kapitel liefert dazu nur die
**Bedarfszahlen** (§3.9) und diese Abhängigkeit:

- Die Zusage ist in V2 **inhaltsunabhängig** (R-00-02). Damit entfällt die V1-Konstruktion,
  bei der der Zusagewert vom decodierten Nachrichtentyp abhing: `0x00` (ein Unterschlitz)
  für die Anmeldung, `0x30` (drei Slots) für die lange Kurznachricht
  [CODE rtl/lmac/tetra_pre_reply_slotgrant.v:135, :269]. Diese Unterscheidung
  funktionierte nur, weil die CMCE-SDS-PDU als MM-Typ 7 fehletikettiert wurde (§2.1) — ein
  Parser-Fehler, auf dem eine Funktion aufsetzte. Beim Versuch, den Wert universell auf
  `0x30` zu setzen, brach die Anmeldung [MESS 2026-06-10].
- Die Zusagegröße begrenzt damit die längste empfangbare Nachricht (R-11-19, §3.9).

### 3.7 Zusammensetzen in Software

Mechanik und Speicherlayout: `06_MAC §3.11`. Hier stehen die SDS-relevanten Regeln, die
dort offen bleiben: Zuordnung, Fenster, Randfälle, Aufräumen.

#### 3.7.1 Zwei Kettenformen

| Form | Bursts | Kanäle | TM-SDU-Anteile | Beleg |
|---|---|---|---|---|
| A — zwei Unterschlitze | `MAC-ACCESS`(Fragmentflag = 1) + `MAC-END-HU` | `SCH/HU`, `SCH/HU` | 56 + 85 = **141 bit** | [ETSI §23.4.2.1.2, Tab. 21.42/21.43/21.45] |
| B — reservierte Vollschlitze | `MAC-ACCESS`(Fragmentflag = 1) + n × `MAC-FRAG` + `MAC-END` | `SCH/HU`, dann `SCH/F` | 56 + n·264 + ≤258 | [ETSI §23.4.2.1.2 Tab. 23.8] |

Die Zahlen sind ETSI-Parameter für π/4-DQPSK: `B_ACCESS` = 62, erstes Fragment mit
Kapazitätswunsch = **56**, `B_END-HU` = **85**, `B_FRAG` = **264**, `B_END` = **258**,
`n_max` = 9 [ETSI §23.4.2.1.2 Tab. 23.8]. Sie entsprechen genau den Kopflängen: 36 bit
`MAC-ACCESS` mit Optionalfeld, 7 bit `MAC-END-HU`, 4 bit `MAC-FRAG`, 10 bit `MAC-END`
[ETSI Tab. 21.42, §21.4.2.2, §21.4.2.4, §21.4.2.5]. V1 benutzt dieselben Offsets
[CODE sw/tetra_ul_reassembly.c:97 — `is_end ? 10 : 4`;
CODE rtl/rx/tetra_ul_schf_reassembly.v:252].

**Wichtig:** Das erste Fragment ist bei Fragmentierung **immer** 56 bit, nicht 62 — der
Kapazitätswunsch (Fragmentflag + Reservierungsbedarf) ist Pflicht und belegt 6 bit
[ETSI §23.4.2.1.2]. Die Kette trägt zudem laut ETSI keine Füllbits im ersten Fragment
(„setting the fill bit indication to indicate that no fill bits are present"), die Länge
ist also fest. V1 speichert stattdessen immer 62 bit ab Blockbit 30 und lässt die Software
6 bit überspringen [CODE rtl/rx/tetra_ul_demand_reassembly.v:17-21,
sw/tetra_ul_reassembly.c:41-43] — dadurch existiert der Offset an drei Stellen. **V2
schneidet beim Startfragment sofort bei `tl_sdu_start` und speichert nur TM-SDU-Bits**
(`06_MAC §3.11`).

#### 3.7.2 Zuordnung eines Fragments zu einer Kette

| Fragment | trägt Adresse? | Zuordnung in V2 |
|---|---|---|
| `MAC-ACCESS`(Fragmentflag = 1) | ja, 24-bit-SSI | eröffnet die Kette; Schlüssel = (SSI, Kontrollkanal-`tn`) |
| `MAC-END-HU` | **nein** [ETSI §21.4.2.2] | über den zugesagten Unterschlitz: `was_reserved = 1` **und** `(tn, fn, mn, ssn)` liegen im Zusagefenster der offenen Kette |
| `MAC-FRAG` / `MAC-END` (`SCH/F`) | **nein** | über den zugesagten Vollschlitz: `was_reserved = 1` und `tn` gleich; die Reihenfolge ist die Ankunftsreihenfolge, Fragmente sind unnummeriert [ETSI §23.4.2.1.0] |

Weil Fortsetzungsfragmente keine Adresse tragen, ist die Reservierung die
**Zuordnungsgrundlage** — nicht Komfort. Zwei Konsequenzen:

1. **R-11-16 ist beweisbar erfüllbar.** Der Zuweisungsblock in Hardware hat genau ein
   aktives Fenster je Kontrollkanal (`06_MAC §3.9`, ein Zuweisungspfad, `GRANT_REPEAT` /
   `GRANT_GAP`). Solange das gilt, gehören alle Bursts mit `was_reserved = 1` auf diesem
   `tn` eindeutig zur Kette, die das Fenster ausgelöst hat. Die Software muss keine
   Adresse aus dem Fragment raten.
2. **`was_reserved` und `ssn` sind Pflichtfelder der UL-Mailbox.** `06_MAC §3.10` führt
   beide; die Mailbox-Beschreibung in `07_PS_PL_CONTRACT §3.4` enthält `subslot`, aber
   kein `was_reserved`. Diese Lücke ist zu schließen — siehe §6, Punkt 1.

V1 ordnet Form A allein über die zuletzt gelatchte SSI zu
[CODE rtl/rx/tetra_ul_demand_reassembly.v:130-133] und Form B über „SCH/F trägt keine SSI,
der reservierte Slot ordnet implizit zu" mit **einer** globalen Kette
[CODE rtl/rx/tetra_ul_schf_reassembly.v:12-13, CODE sw/tetra_ul_reassembly.h:64-65]. Die
V2-Regel ist dieselbe Annahme, aber ausgeschrieben und an ein Mailbox-Feld gebunden.

#### 3.7.3 Zeitfenster und Zeitgeber

Alle Fristen in **Frames**, gezählt aus den Zeitstempeln (R-11-14). Gerechnet wird direkt
mit den Feldern der UL-Burst-Mailbox `fn_ul` und `mn_ul` (`07_PS_PL_CONTRACT §3.4`, `W1`
Bits `[6:2]` und `[12:7]`), die **0-basiert** sind: `fn_ul ∈ 0…17`, `mn_ul ∈ 0…59`.
Umrechnung in die ETSI-Zählung: ETSI-Frame = `fn_ul + 1`, ETSI-Multiframe = `mn_ul + 1` —
sie wird für die Fristen **nicht** gebraucht und darf nicht ad hoc eingestreut werden:

```
abs(fn_ul, mn_ul) = mn_ul * 18 + fn_ul               /* 0 … 1079 */
delta(a, b) = (abs(a) - abs(b) + 1080) mod 1080      /* Frames seit b */
```

| Größe | Wert | Herkunft |
|---|---|---|
| `T0` — Frist bis zum nächsten Fragment | **9 Frames, fest** (Wert normativ in `08 §3.5.2`; kein Register und kein Konfigurationsschlüssel, `13 §3.7`) | `T.202` Fragmentierungs-Zeitüberschreitung, Standardwert 9 Downlink-Signalisierungs-Frames [ETSI §B.1] |
| Zusagefenster | `capacity_allocation` **aufeinanderfolgende** Slots auf demselben `tn`; übersprungen werden ausschließlich Frame-18-Slots mit vordefinierter Linearisierungsgelegenheit ((MN + TN) mod 4 = 3 auf π/4-DQPSK). Ein Frame-18-Slot **ohne** Linearisierungsgelegenheit ist ein normaler belegter Slot der Zusage | [ETSI §23.5.2.2.2], `06_MAC §3.9.5` (R-06-14) |
| Höchstlänge einer TM-SDU | **2 632 bit** = 329 Oktette | `N.202` [ETSI §B.2] |

`T0` wird nach **jedem** akzeptierten Fragment neu gesetzt. V1 arbeitet mit deutlich
kürzeren Werten: Modul-Vorgaben 2 Frames (Form A) und 4 Frames (Form B)
[CODE rtl/rx/tetra_ul_demand_reassembly.v:67, CODE rtl/rx/tetra_ul_schf_reassembly.v:38,
Spiegel CODE sw/tetra_ul_reassembly.h:23, :68], und für Form A zur Laufzeit sogar auf
**1 Frame** gesetzt, weil 2 Frames mit dem Antwortzeitpunkt der Anmeldung kollidierten
[CODE sw/tetra_hal.c:1794-1809, siehe `06_MAC §3.11`]. Beide Werte sind air-verifiziert und
funktionieren, weil der Abstand zwischen zwei Fragmenten in der Praxis ein bis zwei Frames
beträgt [MESS 2026-06-12].

**V2 nimmt den ETSI-Wert 9 Frames** — festgelegt in `08 §3.5.2`, hier nur die Begründung von
der SDS-Seite: ein längeres `T0` hält nur einen Zusammensetz-Kontext länger
(in Software ein Puffer, keine Fläche). Ein *kürzerer* Wert kostet ganze
Nachrichten, sobald die Basisstation die Zusage über mehrere Grant-Nachrichten verteilt, was
ETSI ausdrücklich erlaubt [ETSI §23.4.2.1.2 NOTE 9]. Die V1-Kopplung an den
Antwortzeitpunkt entfällt, weil das Zusammensetzen in V2 nicht mehr im Zeitpfad einer
Antwort liegt (`00_OVERVIEW §3.4`, R-00-01). Voraussetzung dafür ist die Ereignis-Regel aus
`08 §3.5.2` — die Antwort wird durch „Kette vollständig **oder** Fenster abgelaufen"
ausgelöst, nicht durch einen festen Warteschritt. Ohne sie wäre ein `T0` von 9 Frames
schädlich, weil die Antwort auf einen Standardpfad zurückfällt (`08 §3.5.1`).

#### 3.7.4 Randfälle — abschließende Liste

| Fall | Erkennung | Reaktion | Zähler | Beleg |
|---|---|---|---|---|
| Fehlendes Fragment | ein Slot des Zusagefensters liefert keinen Block mit gültigem Prüffeld | **ganze Kette verwerfen**; weitere `MAC-FRAG`/`MAC-END` dieser Adresse verwerfen, bis ein neues Startfragment kommt | `reass_gap_cnt` | [ETSI §23.4.3.1.2 Fall ii] |
| Neues Startfragment bei offener Kette | `MAC-ACCESS`/`MAC-DATA` mit derselben Adresse | alte Kette verwerfen, neue eröffnen — **kein** Fehler, legitimer Wiederholversuch | `reass_restart_cnt` | [ETSI §23.4.3.1.2 a] |
| Herrenloses Fortsetzungsfragment | `MAC-FRAG`/`MAC-END`/`MAC-END-HU` ohne offene Kette dieser Adresse | PDU verwerfen, **keine** Kette anfassen | `reass_orphan_cnt` | [ETSI §23.4.3.1.2, letzter Absatz] |
| Doppeltes Fragment | nicht erkennbar — Fragmente sind unnummeriert | wird über den Längenvergleich unten oder über das Prüffeld erkannt | — | [ETSI §23.4.2.1.0] |
| Überlänge | akkumulierte Bits > `N.202` = 2 632 | Kette verwerfen, nicht weiter akkumulieren | `reass_overlen_cnt` | [ETSI §B.2] |
| Zeitgeber abgelaufen | `delta(jetzt, letztes Fragment) ≥ T0` | Kette verwerfen | `reass_t0_cnt` | [ETSI §B.1] |
| Längenwiderspruch | UDD-4-Längenangabe (in Bit) ≠ tatsächliche UDD-4-Bits nach Füllbit-Entfernung | TM-SDU verwerfen, **Quittung trotzdem senden** (R-11-07) | `sds_len_mismatch_cnt` | §3.1.1 |
| Prüffeld verletzt | LLC-`FCS` vorhanden und falsch | TM-SDU verwerfen, Quittung senden | `sds_fcs_err_cnt` | `09_LLC_MLE_MM` |
| Unbekannter Protokollkenner | Kenner nicht in §3.2 | nicht weiterleiten, Rohoktette protokollieren | `sds_pid_unknown_cnt` | [ETSI §29.4.3.9] |

Die Spalte „Zähler" **zitiert** nur: alle `reass_*`-Zähler sind abschließend in `13 §3.10.2`
definiert (Ereignis, Kettenindex, Sollwert), weil die Zusammensetzung in Software läuft. Für
die Randfälle dieser Tabelle ist die Kettenform beides — A wie B —, der Index ist also der
der jeweils betroffenen Kette. Die `sds_*`-Zähler stehen in §3.10.

**Aufräumen eines hängenden Vorgangs:** Der Zusammensetz-Zustand wird bei **jedem**
eintreffenden Uplink-Burst geprüft, nicht in einem eigenen Zeitgeber-Thread. Kommt kein
Burst, läuft auch keine Frist ab — das ist unschädlich, weil der Kontext erst dann Platz
kostet, wenn ein neuer gebraucht wird. Zusätzlich gilt eine harte Obergrenze für offene
Ketten (§3.11); wird sie überschritten, verfällt die **älteste** Kette (Zähler
`reass_evict_cnt`). Damit kann kein Endgerät durch abgebrochene Ketten Speicher binden.

#### 3.7.5 Füllbit-Entfernung — normativ

Nach dem letzten Fragment, **vor** der Übergabe an die Sicherungsschicht (R-11-15):

```
Ist die Füllbit-Anzeige der letzten PDU = 0:  TM-SDU endet an der PDU-Grenze.
Ist sie = 1:
    letztes Bit der PDU == 1   → dieses Bit entfernen, fertig
    letztes Bit der PDU == 0   → alle Nullen von hinten entfernen bis zur ersten 1,
                                 diese 1 ebenfalls entfernen, fertig
```

[ETSI §23.4.3.2]. Die PDU-Grenze ist:

- bei `MAC-END` **mit** Längenangabe: `LI·8` Bit ab PDU-Beginn;
- bei `MAC-END` im Uplink **ohne** Längenangabe (das 6-bit-Feld trägt dann einen
  Reservierungsbedarf, erkennbar an den führenden Bits `11`, `06_MAC §3.5.3`
  [ETSI §21.4.2.5]): das Blockende;
- bei `MAC-END-HU`: `LI·Z1·8` bzw. das Blockende, je nach Feldwahl
  [ETSI §21.4.2.2 Tab. 21.44]. `Z1 = 1` für π/4-DQPSK [ETSI §21.6 Tab. 21.98].

V1 entfernt **keine** Füllbits: es hängt alle Bits ab dem Kopfende an
[CODE sw/tetra_ul_reassembly.c:98-99] und verlässt sich darauf, dass die
UDD-4-Längenangabe den Text abschneidet [CODE sw/tetra_attach_daemon.c:237-241]. Solange
kein Prüffeld benutzt wird, fällt das nicht auf. Mit Prüffeld — im Betrieb beobachtet, der
LLC-Typ war `BL-DATA` **mit** Prüffeld [MESS 2026-06-10] — liegt das Prüffeld in den
letzten 32 Bit der TM-SDU und ist ohne exakte Länge nicht auffindbar. V1 prüft es deshalb
nie.

### 3.8 Weiterleitungs-Richtlinie

Nach dem Zusammensetzen und dem Quittieren:

```
Ziel eine Gruppenadresse?     ja    → nicht verteilen, sds_group_skip_cnt, protokollieren
Ziel lokal angemeldet?        nein  → nicht weiterleiten, sds_relay_skip_cnt, protokollieren
Statuswert im SDS-TL-Bereich? ja    → Bericht: Nachrichtenreferenz einer offenen
                                       Zustellung zuordnen, dann an den Absender
Kenner ohne SDS-TL?           ja    → UDD-4 unverändert weiterleiten
sonst                               → SDS-TL: Nachrichtentyp auswerten,
                                       UDD-4 unverändert weiterleiten,
                                       Zustellberichts-Wunsch mitführen
```

Die Nutzlast wird **oktettweise unverändert** übernommen (Kenner + SDS-TL-Kopf + Text). Nur
Adressfelder der CMCE-Schicht werden neu gesetzt: die Zieladresse der `U-SDS-DATA` wird zur
Zieladresse des Blocks, die Absenderadresse der `U-SDS-DATA`-Quelle wird zur
Absenderadresse der `D-SDS-DATA`. V1 arbeitet so
[CODE sw/tetra_attach_daemon.c:356-370]. Ob die Nachricht als Einzelblock oder als Kette
zugestellt wird, folgt aus §3.9 (R-11-23).

**Gruppenadressierte Kurznachricht — Verhalten in Stufe 1.** Die Adressart (CPTI, §3.1.1)
unterscheidet Gruppen- und Einzeladresse **nicht**: beide erscheinen als 24-bit-SSI. Die
Basisstation entscheidet deshalb über die Teilnehmerdatenbank — ist die Zieladresse dort mit
Entitätstyp „Gruppe" geführt (`13_SW_ARCHITECTURE`; in V1 `entity_type = 1`
[CODE sw/tetra_db.h:54, :84-85]), ist die Nachricht gruppenadressiert. Sie wird in Stufe 1
**nicht verteilt**: verworfen, `sds_group_skip_cnt` +1, Kenner und Rohoktette protokolliert.
Die Sicherungsschicht-Quittung an den Absender geht trotzdem raus (R-11-07). Zwei Gründe,
beide normativ:

- Eine Zustellung an eine Gruppenadresse muss auf der **unquittierten** Sicherungsschicht
  laufen — „Normal information transfer addressed to a group of MSs shall use unacknowledged
  transfer on the downlink" [ETSI §20.3.1, Tab. 20.8/20.9]. Das widerspricht R-11-04 (`BL-DATA`
  in beiden Fällen) und lässt den Zustellbericht-Fluss aus §3.2.3 ohne Gegenquittung.
- ETSI erlaubt der Infrastruktur ausdrücklich, eine Nachricht abzuweisen, deren Dienstauswahl
  „individual service" anzeigt (§3.2.1, Oktett 1 Bit 1 = `0`), während die Zieladresse eine
  Gruppenadresse ist [ETSI §29.4.3.10].

Die Verteilung an die angemeldeten Gruppenmitglieder gehört nach `18_ROADMAP`. Sie braucht
einen zweiten DL-Sendepfad (unquittiert, an die GSSI adressiert) und eine Festlegung, wie
ein Zustellbericht mehrerer Empfänger auf **eine** Nachrichtenreferenz abgebildet wird —
beides ist in Stufe 1 nicht entschieden und darf nicht improvisiert werden.

### 3.9 Kapazitätstabelle je Nachrichtenart

Alle Werte für π/4-DQPSK, SSI-Adressierung, `BL-DATA` **ohne** Prüffeld. Mit Prüffeld sind
32 Bit von der Nutzlänge abzuziehen (4 Oktette). `L` = UDD-4 in Oktetten.

**Downlink (Basisstation → Endgerät).** TM-SDU = `53 + 8·L` bit.

| Nachrichtenart | Nutzlänge | TM-SDU | Fragmente | Kanal | Bursts | Reservierung |
|---|---|---:|---|---|---:|---|
| Statusnachricht | 16-bit-Statuswert | 56 bit | — | `SCH/HD` | 1 | 1 Unterschlitz für den Bericht |
| Kurznachricht, ein Block | `L ≤ 20` | ≤ 213 | — (`MAC-RESOURCE`, Zusage im Block) | `SCH/F` | 1 | 1 Unterschlitz für den Bericht |
| Kette, ohne Fortsetzung | `21 ≤ L ≤ 52` | 221…469 | `RESOURCE` + `END` | `SCH/F` | 2 | 1 Unterschlitz für den Bericht |
| Kette, 1 Fortsetzung | `53 ≤ L ≤ 85` | 477…733 | `RESOURCE` + 1×`FRAG` + `END` | `SCH/F` | 3 | dito |
| Kette, 2 Fortsetzungen | `86 ≤ L ≤ 118` | 741…997 | `RESOURCE` + 2×`FRAG` + `END` | `SCH/F` | 4 | dito |
| Kette, 3 Fortsetzungen | `119 ≤ L ≤ 131` | 1005…1101 | `RESOURCE` + 3×`FRAG` + `END` | `SCH/F` | 5 | dito |

`L = 131` ist die ETSI-Empfehlungsgrenze: die längste empfohlene TM-SDU für Fragmentierung
auf π/4-DQPSK ist 1 106 bit [ETSI §23.4.2.1.0 Tab. 23.7]. Die harte Grenze wäre
`N.202` = 2 632 bit, also `L ≤ 322` bei 11 Blöcken; darüber ist ein Advanced Link vorgesehen,
der nicht Teil von Stufe 1 ist. Die Grenzen der Tabelle folgen aus dem Algorithmus in
§3.5.1 mit `END_CAP = 247` (Zusage im `MAC-END`, §3.5.2) [ANNAHME — Rechnung aus den
ETSI-Kapazitäten, nicht gemessen; V1 begrenzt bei `L ≤ 120` und 8 Blöcken
[CODE sw/tetra_sds_dl_frag.c:49, sw/tetra_sds_dl_frag.h:21]].

**Uplink (Endgerät → Basisstation).** TM-SDU = `57 + 8·L` bit; die Anzahl der vom Endgerät
benötigten Vollschlitze folgt normativ aus `R = TM-SDU − 56`:
`N = 1` falls `R ≤ 258`, sonst `N = 2 + (R − 258 − 1) DIV 264` [ETSI §23.4.2.1.2].

| Nachrichtenart | Nutzlänge | TM-SDU | Kette | Kanäle | Bursts | Reservierung (`reservation requirement`) |
|---|---|---:|---|---|---:|---|
| Statusnachricht | 16-bit-Statuswert | 60 bit | keine | `SCH/HU` | 1 | keine |
| Kurznachricht, UDD-1 (16 bit) | 2 Oktette | 62 bit | keine | `SCH/HU` | 1 | keine |
| Kurznachricht, Form A | `L ≤ 10` | ≤ 137 | `ACCESS` + `END-HU` | `SCH/HU`, `SCH/HU` | 2 | `0000₂` = 1 Unterschlitz |
| Lang, 1 Vollschlitz | `11 ≤ L ≤ 32` | 145…313 | `ACCESS` + `END` | `SCH/HU`, `SCH/F` | 2 | `0001₂` = 1 Slot |
| Lang, 2 Vollschlitze | `33 ≤ L ≤ 65` | 321…577 | `ACCESS` + 1×`FRAG` + `END` | `SCH/HU`, 2×`SCH/F` | 3 | `0010₂` = 2 Slots |
| Lang, 3 Vollschlitze | `66 ≤ L ≤ 98` | 585…841 | `ACCESS` + 2×`FRAG` + `END` | `SCH/HU`, 3×`SCH/F` | 4 | `0011₂` = 3 Slots |
| Lang, 4 Vollschlitze | `99 ≤ L ≤ 131` | 849…1105 | `ACCESS` + 3×`FRAG` + `END` | `SCH/HU`, 4×`SCH/F` | 5 | `0100₂` = 4 Slots |

Reservierungsbedarf-Codierung: `0000₂` = 1 Unterschlitz, `0001₂` = 1 Slot, `0010₂` = 2,
`0011₂` = 3, `0100₂` = 4, `0101₂` = 5 [ETSI §21.5.4 Tab. 21.93]; die Zusage benutzt
dieselbe Skala wie `capacity_allocation` [ETSI §21.5.6 Tab. 21.96].

**Belegprobe an der Luft.** Die Referenz-Basisstation zusagte `capacity_allocation = 3`
(Zusageelement `0x30`) und das Endgerät sendete daraufhin eine Kette aus Startfragment +
3 `SCH/F`-Bursts mit **842 bit** TM-SDU ≈ 105 Oktetten. Das ist exakt die Zeile „3
Vollschlitze" dieser Tabelle: `56 + 2·264 + 258 = 842`. Eine zweite beobachtete Kette hatte
5 Fortsetzungs-Bursts und **1 370 bit** ≈ 171 Oktette = `56 + 4·264 + 258`
[MESS 2026-06-07 / 2026-06-10]. Die zweite Kette überschreitet die ETSI-Empfehlung von
1 106 bit — reale Endgeräte halten sie nicht ein.

**Konsequenz für R-11-19.** Weil die Zusage inhaltsunabhängig und damit fest ist
(`00_OVERVIEW` R-00-02), gilt: mit `capacity_allocation = C` sind Uplink-Nachrichten
bis zu der Zeile empfangbar, deren Slotzahl `≤ C` ist. Bei `C = 3` sind das **98 Oktette
UDD-4**. Längere Ketten brauchen eine zweite Zusage; siehe §6, Punkt 2.

### 3.10 Zähler (P6, R-11-17)

Alle 16 bit, sättigend, unter eigenem Namen lesbar. Diese Tabelle führt die `sds_*`-Zähler
**dieses** Dienstes; die Zusammensetz-Zähler stehen nicht hier, siehe den Hinweis unter der
Tabelle.

| Zähler | Inkrementiert bei |
|---|---|
| `sds_rx_cnt` | vollständig zusammengesetzte und geparste `U-SDS-DATA` |
| `sds_status_rx_cnt` | geparste `U-STATUS` |
| `sds_tl_report_rx_cnt` | erkannter Bericht (`SDS-REPORT` oder Kurzbericht) |
| `sds_ack_tx_cnt` | gesendete `BL-ACK` auf eine Kurznachricht |
| `sds_tx_cnt` | gesendete `D-SDS-DATA` (Einzelblock **und** Kette, je Nachricht) |
| `sds_frag_tx_cnt` | gesendeter Block einer Kette (je Block) |
| `sds_status_tx_cnt` | gesendete `D-STATUS` |
| `sds_relay_skip_cnt` | Weiterleitung unterlassen, Ziel nicht angemeldet |
| `sds_group_skip_cnt` | Weiterleitung unterlassen, Ziel ist eine Gruppenadresse (§3.8) |
| `sds_len_mismatch_cnt` | UDD-4-Längenangabe ≠ tatsächliche Länge |
| `sds_fcs_err_cnt` | LLC-Prüffeld verletzt |
| `sds_pid_unknown_cnt` | unbekannter Protokollkenner |
| `reass_open_cnt` | Kette eröffnet |
| `reass_ok_cnt` | Kette vollständig |
| `reass_t0_cnt` | Kette wegen `T0` verworfen |
| `reass_gap_cnt` | Kette wegen fehlgeschlagener Blockdecodierung im Zusagefenster verworfen |
| `reass_restart_cnt` | Kette durch neues Startfragment ersetzt |
| `reass_orphan_cnt` | Fortsetzungsfragment ohne offene Kette |
| `reass_overlen_cnt` | Kette wegen `N.202`-Überschreitung verworfen |
| `reass_evict_cnt` | älteste Kette wegen Kontextgrenze verdrängt |

### 3.11 Software-Schnittstelle

```c
/* ---------- tetra_sds.h ------------------------------------------------ */
#define TETRA_SDS_UDD4_MAX_OCT   255        /* 2047 bit, ETSI §14.8.24       */
#define TETRA_SDS_UDD4_REC_OCT   131        /* ETSI §23.4.2.1.0 Tab. 23.7    */
#define TETRA_SDS_TMSDU_MAX_BITS 2632       /* N.202, ETSI §B.2              */
#define TETRA_SDS_REASS_MAX      4          /* offene Ketten, §6 Punkt 3     */

typedef struct {
    uint32_t peer_ssi;                      /* Absender bzw. Ziel, 24 bit    */
    uint8_t  cpti;                          /* 0=Kurznummer 1=SSI 2=SSI+Ext  */
    uint8_t  sdti;                          /* 0..3, 3 = UDD-4               */
    uint16_t udd_bits;                      /* Längenangabe, ETSI: in Bit    */
    uint8_t  udd[TETRA_SDS_UDD4_MAX_OCT];   /* Oktett 0 = Protokollkenner    */
} tetra_sds_msg_t;

typedef struct {
    uint32_t peer_ssi;
    uint8_t  cpti;
    uint16_t status;                        /* 16 bit, ETSI §14.8.34         */
} tetra_sds_status_t;

/* CMCE-Körper. body: ein Bit je Byte, Index 0 = zuerst gesendet.
 * Rückgabe: Bitlänge > 0, oder < 0 bei Parameterfehler. */
int tetra_sds_build_d_sds_data(const tetra_sds_msg_t *m, uint8_t *body);
int tetra_sds_build_d_status  (const tetra_sds_status_t *s, uint8_t *body);
int tetra_sds_parse_u_sds_data(const uint8_t *body, int n_bits,
                               tetra_sds_msg_t *out);
int tetra_sds_parse_u_status  (const uint8_t *body, int n_bits,
                               tetra_sds_status_t *out);

/* Dienst-Eintritt. Wird für JEDE vollständige CMCE-TM-SDU gerufen —
 * einfragmentig wie mehrfragmentig, kein zweiter Weg (R-11-01). */
void tetra_sds_on_cmce(const uint8_t *body, int n_bits, uint32_t from_ssi);

/* Senden. Wählt Einzelblock oder Kette allein aus der Länge (R-11-23). */
int  tetra_sds_send(uint32_t to_ssi, uint32_t from_ssi,
                    const uint8_t *udd, int udd_oct);
int  tetra_sds_send_status(uint32_t to_ssi, uint32_t from_ssi, uint16_t status);

/* ---------- tetra_sds_tl.h -------------------------------------------- */
typedef struct {
    uint8_t  pid;             uint8_t  uses_tl;      /* Kenner, SDS-TL ja/nein */
    uint8_t  msg_type;        uint8_t  delivery_req; /* Tab. 29.20 / 29.14     */
    uint8_t  msg_ref;         uint8_t  delivery_status;
    uint8_t  coding_scheme;   const uint8_t *text;   int text_oct;
} tetra_sds_tl_t;

int      tetra_sds_tl_parse(const uint8_t *udd, int udd_oct, tetra_sds_tl_t *out);
int      tetra_sds_tl_build_transfer(uint8_t *udd, int cap, uint8_t msg_ref,
                                     const char *text, int text_len);
uint16_t tetra_sds_tl_short_report(uint8_t report_type, uint8_t msg_ref);
```

**Fehlerverhalten:** Jede Parse-Funktion prüft jede Feldentnahme gegen `n_bits` und gibt
bei Unterlänge `< 0` zurück, ohne `out` teilweise gefüllt zu lassen. Keine Funktion
schreibt jemals über die übergebene Kapazität. `tetra_sds_send` gibt `< 0` zurück, wenn
`udd_oct > TETRA_SDS_UDD4_REC_OCT` — die harte `N.202`-Grenze gilt nur für die
Empfangsrichtung — und ebenso, wenn `to_ssi` in der Teilnehmerdatenbank als Gruppenadresse
geführt ist: `to_ssi` ist in Stufe 1 immer eine Einzeladresse (§3.8, R-11-22).

**Ressourcen:** Zusammensetz-Kontext `TETRA_SDS_REASS_MAX × (2 632 bit + Kopf)` ≈ 1,4 KiB,
Sendekette bis 11 codierte Blöcke à 432 bit = 594 Byte, alles statisch belegt. Keine
dynamische Speicherverwaltung im Empfangspfad.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| Zusageelement für die UL-Kette | `0x30` = `capacity_allocation` 3, Verzögerung 0 | [MESS 2026-06-10, aus der Referenz-Aufzeichnung dekodiert] | `0x00` (nur erster Unterschlitz): das Endgerät sendet 1 Fortsetzungs-Burst und bricht ab; Kette nie vollständig |
| Halten der Reservierung | `capacity_allocation` aufeinanderfolgende Frames auf demselben `tn`, Infowort `0x0000` | [MESS 2026-06-12, air-verifiziert nach dem Fix] | ein Frame kürzer: Zugriff wird zu früh wieder geöffnet, Kette bricht nach dem ersten Fortsetzungs-Burst ab (der ursprüngliche Fehler) |
| `MAC-END`-Kopf Downlink | 21 bit mit Zusage / 13 bit ohne | [ETSI §21.4.3.3], air-verifiziert [MESS 2026-06-19] | 4 bit: Empfänger liest Nutzbits als Längenangabe (gemessen: 39 Oktette = 312 bit), verwirft die Zusammensetzung, kein Zustellbericht |
| Quittungszeitpunkt bei Ketten | nach dem letzten Fragment | [MESS 2026-06-09] | auf das Startfragment: Endgerät bricht die Kette nach einem Burst ab (gemessen 2 statt 4 Bursts, TM-SDU 33 statt 105 Oktette) |
| `T0` Zusammensetz-Frist | 9 Frames (ETSI `T.202`, normativ `08 §3.5.2`) | [ETSI §B.1] | 2 bzw. 4 Frames (V1-Wert) funktionieren gemessen, brechen aber bei über mehrere Grants verteilter Zusage ab |
| Textcodierung im Sende-Kopf | `0x01` = ISO 8859-1, konstant | [MESS 2026-06-07, empfangener Text ist 8-bit/Latin-1] | mitgezählter Wert (V1): ab der zweiten Nachricht falsches Alphabet, ab Wert 28 (`0011100₂`) reservierter, ab 32 anwendungsdefinierter Bereich [ETSI Tab. 29.29] |
| Blöcke je Frame in der Kette | 1 | [ETSI §B.2 `N.203 ≥ 4`] | > 1 nicht möglich (nur ein Fragment je MAC-Block erlaubt); Lücke > 4 Slots: Empfänger verwirft |

---

## 5. Verifikation

### 5.1 Selbstprüfende Unit-Tests (Pflicht)

| Test | Prüft | Kriterium |
|---|---|---|
| `t_sds_cmce_roundtrip` | §3.1: alle vier CMCE-PDUs bauen und zurückparsen, alle CPTI- und SDTI-Werte | Feld für Feld identisch; Bitlänge gegen die Kopflängen in §3.1.1/§3.1.2 |
| `t_sds_dl_chain` | §3.5.1/§3.5.2: Kette bauen, spiegelbildlich zusammensetzen | UDD-4 bit-identisch für **jedes** `L` von 1 bis 131; Kopflängen 43 / 4 / 21; letzter Block trägt `LI = ceil((21+Rest)/8)` |
| `t_sds_dl_chain_edge` | R-11-10 | für jedes `L`, das auf `247 < R ≤ 264` führt, entsteht ein **leeres** `MAC-END` mit `LI = 3` |
| `t_sds_ul_reass` | §3.7: Form A und Form B, alle Randfälle aus §3.7.4 | jeder Randfall erhöht genau **seinen** Zähler und keinen anderen |
| `t_sds_fill_delete` | §3.7.5 | beide Zweige (letztes Bit 1 / 0) gegen von Hand konstruierte Bitmuster; TM-SDU-Länge exakt |
| `t_sds_tl` | §3.2: Kenner-Klassifikation, `SDS-TRANSFER`, `SDS-REPORT`, Kurzbericht | Kurzbericht-Codierung liegt in `0x7C00`…`0x7FFF`; Kenner < `0x80` ⇒ `uses_tl = 0` |
| `t_sds_status` | §3.3 | `U-STATUS`-TM-SDU = 60 bit, `D-STATUS` = 56 bit; Statuswert im SDS-TL-Bereich wird nicht als Status weitergeleitet |

**Warum diese Liste so explizit ist.** Der V1-Baustein mit dem luftwirksamen Fehler hat
**keinen** laufenden Test: `sw/test_sds_dl_frag.c` existiert, ist in keinem Makefile-Ziel
eingetragen [CODE sw/Makefile:134 — `test:` listet ihn nicht] und schlägt gegen den
korrigierten Erzeuger fehl, weil er das `MAC-END` noch mit 4 bit Kopf zurückliest
[CODE sw/test_sds_dl_frag.c:60-62]. Nachgeprüft: der Test läuft, meldet 4 Fragmente und
bricht mit `UDD mismatch @81` ab [SIM 2026-07-25, `gcc` auf `sw/test_sds_dl_frag.c` +
`sw/tetra_sds_dl_frag.c`, Exit 1]. Ein nicht ausgeführter Test mit veralteter Erwartung ist
schlechter als kein Test — in V2 ist jedes Ziel dieser Tabelle Teil des `test`-Ziels, und
ein Fehlschlag bricht den Build.

### 5.2 Testvektoren

- **Kette Downlink:** die 4 Blöcke für `L = 88` (TM-SDU 757 bit) als Hex-Dump, gegen die
  Kopflängen 43 / 4 / 4 / 21 geprüft; der letzte Block trägt 4 Nutzbits, also `LI = 4`
  (= `ceil(25/8)`) und 7 Füllbits `1000000`. Erzeugt aus §3.5.1, nicht aus V1.
- **Kette Uplink:** zwei aufgezeichnete reale Ketten als Soft-Burst-Folge mit Zeitstempeln —
  842 bit (3 reservierte Slots) und 1 370 bit (5 Slots) [MESS 2026-06-07]. Sie prüfen §3.7
  gegen Verhalten, das an der Luft vorkommt, einschließlich `BL-DATA` mit Prüffeld.
- **Statusnachricht:** eine `U-STATUS` mit Benutzerstatus und eine mit Kurzbericht
  (`0x7C00 | (type << 8) | ref`), um R-11-21 zu prüfen.

### 5.3 Gold-Vergleich

Die Referenz-Aufzeichnung in `docs/reference_decode/` enthält **keine** SDS- und keine
Statusnachricht — geprüft über beide Volldecodes und beide Ereignisdateien
[GOLD, kein Treffer für `SDS` in `dl_full.md` (173 675 Zeilen), `ul_full.md`,
`action_reaction.md`]. Der Gold-Vergleich für dieses Kapitel stützt sich deshalb auf die
separaten Aufzeichnungen, aus denen die Messwerte in §4 stammen; diese liegen **nicht** im
Repository. **Verbindlich für V2:** die beiden Aufzeichnungen, aus denen `capacity_allocation
= 0x30`, das Halte-Infowort und der 21-bit-`MAC-END`-Kopf abgeleitet wurden, werden als
Referenzdecode in `docs/reference_decode/` aufgenommen. Solange das nicht geschehen ist,
sind alle Verweise auf „Gold #798 / #810 / #822" in V1-Kommentaren
[CODE sw/tetra_sds_dl_frag.c:56, :87, :110, :132, :174] **nicht nachprüfbar** und in dieser
Spezifikation bewusst als `[MESS …]` und nicht als `[GOLD]` geführt.

Strukturell zu vergleichen sind, sobald die Aufzeichnung vorliegt: Kopflängen und
Längenangaben aller Kettenblöcke, das Infowort des Kettenslots gegen den des letzten Blocks,
`capacity_allocation` gegen die Anzahl der Fortsetzungs-Bursts. Nicht zu vergleichen sind
Adressen, Zellparameter und Nachrichtenreferenzen (`CONVENTIONS.md §3`).

### 5.4 Luft-Abnahme

Jeder Punkt mindestens dreimal, mit gleichzeitigem Uplink- und Downlink-Mitschnitt:

1. **Kurznachricht Endgerät A → Endgerät B, ein Block.** Text kommt an; `sds_ack_tx_cnt`
   +1; **keine** Fehlermeldung am Sende-Endgerät; `reass_ok_cnt` +1.
2. **Lange Nachricht A → B, 3 Fortsetzungs-Bursts im Uplink.** Uplink-Mitschnitt zeigt
   Startfragment + 3 `SCH/F`-Bursts, kein Wiederholen des Startfragments;
   `reass_ok_cnt` +1, `reass_gap_cnt` und `reass_t0_cnt` unverändert.
3. **Lange Nachricht in Empfangsrichtung des Ziels**, also als Kette zugestellt: Text
   vollständig am Ziel; das Ziel sendet einen Zustellbericht; der Bericht erreicht den
   ursprünglichen Absender.
4. **Statusnachricht A → B** (R-11-20): Statuswert am Ziel; `sds_status_tx_cnt` +1. Dieser
   Punkt ist in V1 **offen** — er ist die erste Abnahme, die V2 hier neu erbringt.
5. **Kurzbericht** (R-11-21): das Ziel-Endgerät antwortet mit einer `U-STATUS` im Bereich
   `0x7C00`…`0x7FFF`; `sds_tl_report_rx_cnt` +1, `sds_status_rx_cnt` **nicht**.
6. **Abbruch-Verhalten:** Endgerät während einer Kette abschalten. `reass_t0_cnt` +1 nach
   spätestens 9 Frames; kein hängender Kontext (`reass_open_cnt − reass_ok_cnt −
   reass_t0_cnt − reass_restart_cnt = 0`).
7. **Anmeldung bleibt unbeeinträchtigt.** Nach dem Umstellen der Zusage auf einen einzigen
   inhaltsunabhängigen Parametersatz muss die Anmeldung weiter funktionieren — genau das
   ist in V1 gebrochen, als das Zusageelement universell auf `0x30` gesetzt wurde
   [MESS 2026-06-10]. Kriterium: 10 Anmeldungen hintereinander erfolgreich.

---

## 6. Offene Punkte

1. **O-11-1 — `was_reserved` fehlt in der Mailbox-Beschreibung.** `06_MAC §3.10` führt das Feld als
   Pflichtmetadatum je Uplink-Burst, die normative Registerseite
   `07_PS_PL_CONTRACT §3.4` (`W1`) enthält es nicht. Ohne dieses Bit ist die Zuordnung
   eines adresslosen Fortsetzungsfragments zu seiner Kette (§3.7.2) nicht sauber
   möglich — die Software müsste das Zusagefenster aus `REG_UL_ASSIGN_STATE` nachbilden und
   hätte damit eine zweite Wahrheit. **Empfehlung:** `was_reserved` in `W1` aufnehmen
   (ein freies Bit ist vorhanden) und `07` entsprechend ergänzen. Entscheidung gehört zu
   `07`, nicht hierher.

2. **O-11-2 — Uplink-Ketten über die feste Zusagegröße hinaus.** Mit inhaltsunabhängiger Zusage
   (R-00-02) ist die längste empfangbare Uplink-Nachricht auf die Zeile aus §3.9 begrenzt,
   deren Slotzahl `≤ capacity_allocation` ist — bei `C = 3` sind das 98 Oktette UDD-4
   (TM-SDU 842 bit). Real beobachtet ist eine Kette mit **1 370 bit** TM-SDU, die nach der
   ETSI-Formel **5** Slots braucht [MESS 2026-06-07]. ETSI erlaubt ausdrücklich mehrere
   Zusagen für eine Kette [ETSI §23.4.2.1.2 NOTE 9]. Ein inhaltsunabhängiger Mechanismus
   ist denkbar: wird im **letzten** reservierten Slot eines Fensters wieder ein
   Vollschlitz-Burst erkannt, verlängert die Hardware das Fenster um `C` Slots — das ist
   hardware-lokal und verstößt nicht gegen R-00-02. **Empfehlung:** mit `C = 3` und ohne
   Verlängerung starten, `reass_t0_cnt` und `reass_gap_cnt` in der Luft-Abnahme
   mitprotokollieren, und die Verlängerung erst bauen, wenn sie messbar gebraucht wird.
   Der Mechanismus gehört dann nach `06_MAC §3.9`, gekoppelt an `07` O-07-1.

3. **O-11-3 — Wie viele Zusammensetz-Kontexte?** `TETRA_SDS_REASS_MAX = 4` ist gesetzt, aber nicht
   begründet: Form B kann nach R-11-16 ohnehin nur einmal je Kontrollkanal offen sein,
   Form A braucht mehrere, weil zwei Endgeräte ihre Zweiburst-Kette überlappend abschließen
   können. V1 hat für Form A zwei Plätze und für Form B genau einen
   [CODE rtl/rx/tetra_ul_demand_reassembly.v:23-27, CODE sw/tetra_ul_reassembly.h:33-38].
   **Empfehlung:** vier gemeinsame Kontexte (Speicher ist unkritisch, §3.11) und
   `reass_evict_cnt` als Messgröße; erst bei nachgewiesener Verdrängung erhöhen.

4. **O-11-4 — Statusnachrichten sind nicht luftverifiziert.** Der Pfad ist in V1 vollständig
   vorhanden [CODE sw/tetra_cmce_parser.c:201-228, CODE sw/tetra_cmce_body.c:305-316,
   CODE sw/tetra_attach_daemon.c:1159-1174], ein Air-Test-Protokoll liegt nicht vor, und in
   der Gold-Aufzeichnung kommt keine Statusnachricht vor. Die 16-bit-Bereichsaufteilung aus
   R-11-21 ist damit rein ETSI-belegt. **Empfehlung:** Abnahmepunkt 4 und 5 aus §5.4 vor der
   Freigabe von Stufe 1 durchführen; erst danach gilt §3.3 als bestätigt.

5. **O-11-5 — Zustellberichte werden nicht erzeugt, nur weitergeleitet.** V1 leitet Berichte der
   Gegenstelle durch, erzeugt aber selbst keinen — obwohl der Zustellberichts-Wunsch im
   `SDS-TRANSFER` steht [ETSI §29.4.2.4 Tab. 29.14] und die Basisstation Statuswerte wie
   „unbekanntes Ziel" (`010001012`) oder „Ziel nicht im System registriert" (`010010112`)
   liefern könnte [ETSI §29.4.3.2 Tab. 29.16]. **Empfehlung:** in Stufe 1 nur diese beiden
   Fälle erzeugen — sie brauchen keine Zustandshaltung — und alles weitere nach `18_ROADMAP`.

6. **O-11-6 — 7-bit-Alphabet.** Alle beobachteten Nachrichten benutzen ISO 8859-1
   [MESS 2026-06-07]; das 7-bit-Alphabet (`0000000₂`, identisch zum GSM-Standardalphabet
   [ETSI §29.5.4.1]) ist unbelegt. Da die Nutzlast oktettweise unverändert weitergeleitet
   wird (§3.8), ist die Codierung nur für die Protokollausgabe relevant. **Empfehlung:**
   Entpacken des 7-bit-Alphabets ausschließlich in der Protokollausgabe, nicht im Datenpfad.
