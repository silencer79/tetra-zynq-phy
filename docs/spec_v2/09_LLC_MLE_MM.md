# 09 — LLC, MLE-Vermittlung und Mobilitätsverwaltung

**Scope:** Die drei Schichten über der MAC-Schicht bis einschließlich Anmeldung:
LLC-PDUs beider Richtungen mit Kopffeldern, Sequenznummern und Prüfsumme; die
MLE-Vermittlung über den Protokoll-Diskriminator; die Mobilitätsverwaltung (MM)
mit Anmeldung, Gruppen-Zuordnung, Gruppenwechsel, Gruppen-Report und Abmeldung —
je als vollständiger PDU-Ablauf; die Teilnehmer-Richtlinie bei unbekannter
Teilnehmer- oder Gruppenadresse.

**Nicht hier:** MAC-Kopffelder, Längenangabe, Füllbits, Zuweisungselemente,
AACH → `06_MAC`. Rufsteuerung → `10_CMCE_CALL`. Kurznachrichten → `11_SDS`.
Kanalcodierung → `05_CHANNEL_CODING`. Registeradressen → `07_PS_PL_CONTRACT`
(hier nur Registernamen). Zeitbudgets und Antwortfenster → `08_TIMING`.
Prozessmodell, Persistenz und Bedienoberfläche der Teilnehmer-Datenbank →
`13_SW_ARCHITECTURE`.

**Abhängigkeiten:** `00_OVERVIEW` (§3.3: diese drei Schichten liegen vollständig
in Software), `06_MAC` (§3.4 MAC-RESOURCE, §3.7 Längenangabe/Füllbits),
`07_PS_PL_CONTRACT` (§3.3 DL-PDU-Mailbox, §3.4 UL-Burst-Mailbox), `08_TIMING`
(§3.4 Antwortfenster, §3.5 Fragment-Fenster).

---

## 1. Anforderungen

| Nr. | Anforderung | Prüfkriterium |
|---|---|---|
| **R-09-01** | LLC, MLE und MM liegen vollständig in Software. Kein RTL-Modul erzeugt oder parst eine LLC-, MLE- oder MM-PDU. | Kein Verilog-Modul im Baum referenziert einen MM-PDU-Typ oder einen LLC-Kopf. |
| **R-09-02** | Der LLC-Kopf jeder Basic-Link-PDU wird nach §3.1.2 gebaut: Feldreihenfolge `{link type, FCS flag, BL-PDU-Typ, [N(R)], [N(S)]}`, MSB-first, **N(R) vor N(S)**. | Testvektor gegen [GOLD] Burst #783 und #4811, bitweise. |
| **R-09-03** | `N(R)` einer gesendeten BL-ACK oder BL-ADATA ist **gleich** dem `N(S)` der letzten korrekt empfangenen BL-DATA/BL-ADATA derselben Verbindung. Keine Inkrementierung, keine Alternierung. | Simulation über die sechs Gold-Antwortfälle (§3.1.3); Air-Test: MS wiederholt seine Anforderung nicht. |
| **R-09-04** | `N(S)` einer gesendeten BL-DATA/BL-ADATA ist der Wert `V(S)` der Verbindung; `V(S)` wird nach jeder vollständig gesendeten BL-DATA/BL-ADATA umgeschaltet, unabhängig vom PDU-Typ. Eine Wiederholung derselben TL-SDU trägt dasselbe `N(S)`. [ANNAHME: bewusste Abweichung von [ETSI §22.3.2.3 g)–j)], wo `V(S)` erst bei Quittung der Gegenstelle oder endgültigem Fehlschlag inkrementiert wird — unsere MAC-Schicht liefert keine Übertragungsbestätigung je PDU; Begründung und Prüfweg in §6 Punkt 1] | Vier aufeinanderfolgende Antworten an dieselbe MS zeigen `N(S) = 1,0,1,0`. |
| **R-09-05** | Die Länge des LLC-Kopfes hängt **ausschließlich** vom 2-bit-BL-PDU-Subtyp ab, **nie** vom FCS-Flag. | Tabellentest über alle 8 Basic-Link-Codepunkte (§3.1.5). |
| **R-09-06** | Die Prüfsumme (FCS) ist 32 bit, deckt genau die TL-SDU (nicht MAC-Kopf, nicht LLC-Kopf), steht unmittelbar hinter der TL-SDU und wird nach Anhang C berechnet — einschließlich der Sonderregel für Nutzlängen unter 32 bit. | Testvektoren für Längen 8, 24, 31, 32, 33 und 320 bit. |
| **R-09-07** | Beim Empfang werden bei gesetztem FCS-Flag die letzten 32 bit der LLC-PDU als FCS behandelt und **vor** der Weitergabe an MLE entfernt. Schlägt die Prüfung fehl, wird die PDU behandelt, als wäre sie nicht empfangen worden: kein Weitergeben nach oben, **keine neue** Quittung, `V(R)` unverändert. Eine bereits aus einer früheren PDU ausstehende Quittung wird davon nicht berührt. | Simulation mit verfälschtem Bit; Zähler `llc_fcs_err` inkrementiert, kein DL-Ausgang und `V(R)` unverändert; mit vorher ausstehender Quittung: diese geht weiterhin heraus. |
| **R-09-08** | Stufe 1 baut und parst genau die vier Basic-Link-PDUs. Advanced-Link- und Layer-2-Signalisierungs-PDUs (LLC-Typ ≥ `1000₂`) werden erkannt, gezählt und verworfen. | Zähler `llc_unsupported_type`; kein Absturz, kein Fehlparse. |
| **R-09-09** | Die MLE-Schicht setzt beim Senden genau den 3-bit-Protokoll-Diskriminator vor die SDU und entfernt ihn beim Empfangen. | Bitvergleich gegen [GOLD] #783 (`001`) und #5887 (`010`). |
| **R-09-10** | Die Vermittlung einer empfangenen SDU an MM, CMCE oder SNDCP erfolgt **ausschließlich** über den Protokoll-Diskriminator — nie über den Weg, über den die SDU eingetroffen ist (Einzelburst oder Zusammensetzung mehrerer Fragmente). | Codeprüfung: es existiert genau eine Vermittlungsfunktion; Test: mehrfragmentige MM-PDU landet ohne Sonderfall in MM. |
| **R-09-11** | Der quittierte Anmeldetyp (`location update accept type`) wird aus dem `location update type` der Anforderung des Endgeräts übernommen. Er ist **nicht** fest verdrahtet. | Zwei Air-Tests: Anforderung `011₂` → Antwort `011₂`; Anforderung `000₂` → Antwort `000₂`. |
| **R-09-12** | Die in der Anmeldebestätigung zugewiesene Gruppenadresse stammt aus dem Wunsch des Endgeräts (sofern konfigurationsseitig zulässig) oder aus der konfigurierten Standardgruppe des Teilnehmerprofils. Ein im Programmcode fest eingetragener Vorgabewert ist unzulässig; existiert keine zulässige Gruppe, entfällt das Gruppen-Element vollständig. | Grep: keine GSSI-Konstante in Quelldateien. Test: leere Konfiguration → 28-bit-MM-Body ohne Gruppen-Element. |
| **R-09-13** | Der Auslieferungszustand der Konfiguration enthält **keine** Teilnehmer- und **keine** Gruppeneinträge. | Prüfung der ausgelieferten Konfigurationsdatei. |
| **R-09-14** | Jede empfangene MM-PDU wird mit dem Annex-E-Feldwanderer geparst: Typ-1-Felder fest, Typ-2 über P-Bits, Typ-3/4 über M-Bit + 4-bit-Kennung + 11-bit-Länge. Unbekannte Typ-3/4-Elemente werden über ihre Länge übersprungen, nicht als Fehler behandelt. | Test mit eingefügtem unbekannten Element `1110₂`: Parse bleibt erfolgreich, Folgefelder korrekt. |
| **R-09-15** | Ein Strukturfehler beim Parsen (Länge über Bodyende, Pflichtfeld fehlt) führt zum Verwurf mit Zähler, nie zu einer teilweise ausgewerteten Reaktion. | Fuzz-Test über 10⁵ Zufallsbodies: kein Zugriff außerhalb des Puffers, keine DL-PDU. |
| **R-09-16** | Der Anmeldeablauf wird in den in §3.5.1 festgelegten fünf Schritten bedient; jeder Schritt hat ein definiertes Verhalten bei Ausfall des vorigen. | Air-Test-Protokoll §5.4. |
| **R-09-17** | Eine Gruppen-Anhänge-Anforderung wird **immer** beantwortet — mit Annahme, mit Teilablehnung oder mit einer Quittung ohne Gruppen-Element. Stillschweigendes Verwerfen ist unzulässig. | Test: Anforderung mit unbekannter Gruppe und Richtlinie „nicht annehmen" → Quittung mit Ablehnungsgrund. |
| **R-09-18** | Eine Gruppen-Report-Anforderung wird mit `D-ATTACH/DETACH GROUP IDENTITY` beantwortet, nicht mit der Quittungs-PDU. Hat die Basisstation keine Gruppen für dieses Endgerät, enthält die Antwort das Element „Gruppenreport vollständig" und kein Gruppen-Element. | Bitvergleich gegen §3.4.6; Air-Test: MS startet danach ein echtes Gruppen-Anhängen. |
| **R-09-19** | Bei unbekannter Teilnehmeradresse entscheidet die Richtlinie aus der Konfiguration: automatische Eintragung oder Ablehnung. Bei Ablehnung wird ein Ablehnungsgrund aus der Zellklasse (`00110₂`) verwendet, kein Grund aus der Systemklasse — sonst verlässt das Endgerät nach `N351` Versuchen das Netz bis zum Neustart. | Codeprüfung + Air-Test: fünf Ablehnungen hintereinander, Endgerät versucht weiter. |
| **R-09-20** | Alle Zell-Kenngrößen der MM-Antworten (Aufenthaltsbereich, Landeskennung, Netzkennung, Farbcode) stammen aus **derselben** Konfigurationsquelle, aus der die Software auch `REG_CELL_CFG_1`/`REG_CELL_CFG_2` speist. | Abnahmekriterium aus `07 §3.1.3`: Registerinhalt und MM-Body-Feld stimmen überein (§5.2). |
| **R-09-21** | Der Verbindungszustand (`V(S)`, `V(R)`, letzter Zeitstempel) wird je Teilnehmeradresse geführt, mit fester Obergrenze und definierter Verdrängungsregel; eine Verdrängung ist gezählt. | Test mit `N+1` Teilnehmern: ältester Eintrag fällt heraus, Zähler `llc_link_evict` +1. |
| **R-09-22** | Jeder Verwurf, jede Prüfsummen-Verletzung, jede Ablehnung und jede automatische Eintragung hat einen im Betrieb lesbaren Zähler (P6). | Zählerliste §3.8 vollständig über die Diagnoseschnittstelle abfragbar. |
| **R-09-23** | Alle Zeitbezüge dieser Schichten werden aus dem TDMA-Zeitstempel der UL-Burst-Mailbox abgeleitet (R-00-04). Die Software hält keine eigene Uhr für Protokollfristen. | Codeprüfung: keine `clock_gettime`-Nutzung in Protokollfristen. |
| **R-09-24** | Die Bezeichnung einer MM-PDU im Code und in Logausgaben ist der ETSI-PDU-Typwert der jeweiligen Richtung. Interne Klassennummern, die davon abweichen, sind unzulässig. | Grep: kein Bezeichner `mm=1`/`mm=4` für Anmeldebestätigung/-ablehnung (V1-Drift, §3.4.2). |
| **R-09-25** | Alle Bitfolgen an den Schnittstellen dieses Kapitels sind **ein Bit je Byte**, Index 0 = zuerst gesendetes Bit. Es gibt in `09`, `10` und `11` **keine** zweite Darstellung. | Codeprüfung: keine Pack-/Entpackfunktion zwischen LLC, MLE, MM, CMCE und SDS. |

---

## 2. Architektur / Aufbau

### 2.1 Lage im Gesamtsystem

Alle drei Schichten sind reine Software (`00_OVERVIEW §3.3`, Punkt 3). Die
Hardware liefert Uplink-Bursts als Soft-Werte mit Zeitstempel und nimmt fertig
codierte Downlink-PDUs an. Zwischen beidem liegt ausschließlich C-Code:

```
        UL-Burst-Mailbox (07 §3.4)                     DL-PDU-Mailbox (07 §3.3)
                 │ Soft-Werte + Zeitstempel                        ▲ type-5-Bits + W14/W15
                 ▼                                                 │
        05  Kanaldecodierung (Descramble/Deinterleave/Viterbi/CRC) 05  Kanalcodierung
                 │ info-Bits (92 bzw. 268)                         │ info-Bits (124/268)
                 ▼                                                 │
        06  MAC-Parse + Fragment-Zusammensetzung           06  MAC-RESOURCE-Aufbau
                 │ TM-SDU (Bitstrom) + opt-Offset                  │ TM-SDU
                 ▼                                                 │
     ┌───────────────────────┐                        ┌────────────────────────┐
     │ 09  tetra_llc  (RX)   │                        │ 09  tetra_llc  (TX)    │
     │  Kopf, N(S)/N(R), FCS │                        │  Kopf, N(S)/N(R), FCS  │
     └───────────┬───────────┘                        └───────────▲────────────┘
                 │ TL-SDU                                         │ TL-SDU
     ┌───────────▼───────────┐                        ┌───────────┴────────────┐
     │ 09  tetra_mle  (RX)   │  PD entfernen          │ 09  tetra_mle  (TX)    │  PD setzen
     └──┬─────────┬──────────┘                        └──▲─────────▲───────────┘
        │ PD=001  │ PD=010 / 100                         │         │
        ▼         ▼                                      │         │
   09 tetra_mm   10 CMCE / 11 SDS ─────────────────────────────────┘
        │
        ▼
   tetra_subscriber_db  (Richtlinie, Profile; Persistenz in 13)
```

**Ein Weg pro Richtung** (P3). Es gibt genau eine Funktion, die eine TL-SDU in
eine LLC-PDU verpackt, und genau eine, die aus einer TM-SDU eine TL-SDU
gewinnt. Alle Erzeuger — MM, CMCE, SDS — benutzen dieselbe.

**Eine Bitdarstellung (R-09-25).** Über alle Schnittstellen der Kapitel `09`,
`10` und `11` gilt: **ein Bit je Byte**, Wert 0 oder 1, Index 0 = zuerst
gesendetes Bit. Die Umsetzung in die gepackten type-5-Bits geschieht
ausschließlich in `05_CHANNEL_CODING`, die Umsetzung aus den Mailbox-Wörtern
ausschließlich in der HAL-Schicht (`07 §3.11`). Das ist die Auflösung eines
konkreten V1-Fehlers: dort liegen beide Darstellungen nebeneinander im selben
Modul — der Zusammensetzungs-Pfad liefert ein Bit je Byte, der Auswerter
erwartet gepackte Bytes, und die nachträglich eingefügte Umpackung ist als
Fehlerbehebung kommentiert [CODE sw/tetra_attach_daemon.c:925-932: *„sonst
scheitert der Parse trotz korrekter Reassembly+ACK"*].

### 2.2 Module und Verantwortlichkeit

| Modul | Aufgabe | Zustand |
|---|---|---|
| `tetra_bits.h` | Bit-Cursor: `bits_get(buf,pos,n)`, `bits_put(buf,&pos,val,n)`, MSB-first innerhalb eines Feldes, mit Bereichsprüfung gegen eine mitgeführte Bitlänge | zustandslos |
| `tetra_llc.c/.h` | Basic-Link-Kopf bauen/parsen, FCS, `V(S)`/`V(R)`-Verwaltung je Verbindung | Verbindungstabelle |
| `tetra_mle.c/.h` | Protokoll-Diskriminator setzen/entfernen, Vermittlung an MM/CMCE/SNDCP | zustandslos |
| `tetra_mm_ie.c/.h` | Annex-E-Elementmechanik: O-Bit, P-Bit, M-Bit, Typ-3/4-Kennung und -Länge, Elementkennungstabellen für Up- und Downlink | zustandslos |
| `tetra_mm.c/.h` | Wanderer für die vier Uplink-MM-PDUs, Erzeuger für die vier Downlink-MM-PDUs, Ablaufsteuerung Anmeldung / Gruppen / Abmeldung | Anmelde-Zustand je Teilnehmer |
| `tetra_subscriber_db.c/.h` | Nachschlagen und Eintragen von Teilnehmer- und Gruppenadressen, Profile, Richtlinienbits | Datenbank (Persistenz in `13`) |

`tetra_mm_ie` ist bewusst getrennt: dieselbe Elementmechanik gilt für CMCE
(`10`) und die Kurznachrichten (`11`) [ETSI §E.1.1 gilt für „CMCE, MM and
SNDCP PDUs"]. In V1 existiert diese Mechanik dreimal — im RTL-Wanderer, im
C-Wanderer [CODE sw/tetra_mm_demand_parser.c:43-321] und ad hoc im
CMCE-Parser — und dreimal mit anderer Fehlerbehandlung.

### 2.3 Verbindungszustand (`tetra_llc_link_t`)

```c
typedef struct {
    uint32_t ssi;            /* 24 bit Teilnehmeradresse, 0 = Platz frei      */
    uint8_t  vs;             /* 1 bit  V(S): nächstes zu sendendes N(S)       */
    uint8_t  vr;             /* 1 bit  V(R): letztes empfangenes N(S)         */
    uint8_t  vr_valid;       /* 1 = seit Anlage der Verbindung etwas empfangen*/
    uint8_t  ack_pending;    /* 1 = Quittung steht aus (Wert in vr)           */
    uint32_t last_slot_idx;  /* Slotindex aus dem TDMA-Zeitstempel, R-09-23   */
} tetra_llc_link_t;
```

`TETRA_LLC_LINKS = 64` Plätze [ANNAHME: in einer Zelle sind höchstens einige
zehn Endgeräte gleichzeitig in einem Anmelde- oder Rufvorgang; V1 nutzt
dieselbe Größe für seine Sequenznummern-Tabelle [CODE
sw/tetra_attach_daemon.c:137]]. Verdrängung: der Platz mit dem ältesten
`last_slot_idx` (R-09-21), Zähler `llc_link_evict`. Nach Verdrängung beginnt die
Verbindung mit `vs = 0`, `vr_valid = 0` — das ist derselbe Zustand wie beim
ersten Kontakt [ETSI §22.3.2.1: *„shall start TL-SDU numbering from '0' by
setting local variable V(S) = 0"*].

V1 verwendet stattdessen eine offene Hashtabelle mit 64 Plätzen: es sondiert
linear über alle 64 Slots und gibt einen Eintrag **nie** frei; ist die Tabelle
voll, fällt es still auf feste `NS=1`/`NR=0` zurück — ohne Zähler [CODE
sw/tetra_attach_daemon.c:149-175] — ein Verlust, der im Betrieb nicht sichtbar
ist. Der Modulkommentar behauptet stattdessen „slot eviction on collision"
[CODE sw/tetra_attach_daemon.c:134]; er beschreibt den Code falsch, und nach
`CONVENTIONS.md §3` gilt der Code. Lineare Tabelle mit 64 Einträgen und
O(N)-Suche genügt: bei einer
Abfrageperiode von 10 ms ist die Suchzeit auf dem ARM-Kern
bedeutungslos [CODE sw/tetra_db.c:4-8 dokumentiert dieselbe Abwägung].

---

## 3. Detail-Spezifikation

### 3.1 LLC — Logical Link Control

Verwendet werden ausschließlich die **Basic-Link**-PDUs. Der Basic Link ist
für MM- und rufbezogene Signalisierung normativ vorgeschrieben
[ETSI §18.3.5.3.1: *„The basic link shall be used for all MM signalling and CMCE
call related signalling. The FCS flag may be set to indicate the use of the
optional FCS for basic link transfer."*]. Ein expliziter Verbindungsaufbau
existiert nicht [ETSI §22.3.2.1].

#### 3.1.1 LLC-PDU-Typen

4-bit-Feld, erstes Feld jeder LLC-PDU [ETSI §21.2.1 Tabelle 21.1]:

| Wert | PDU | in Stufe 1 |
|---|---|---|
| `0000₂` | BL-ADATA ohne FCS | senden + empfangen |
| `0001₂` | BL-DATA ohne FCS | senden + empfangen |
| `0010₂` | BL-UDATA ohne FCS | senden + empfangen |
| `0011₂` | BL-ACK ohne FCS | senden + empfangen |
| `0100₂` | BL-ADATA mit FCS | empfangen |
| `0101₂` | BL-DATA mit FCS | empfangen |
| `0110₂` | BL-UDATA mit FCS | empfangen |
| `0111₂` | BL-ACK mit FCS | empfangen |
| `1000₂`…`1111₂` | AL-*, Supplementary, L2-Signalisierung | zählen + verwerfen (R-09-08) |

Das Bit `[2]` des Feldes ist das **FCS-Flag**, die Bits `[1:0]` sind der
BL-PDU-Subtyp, Bit `[3]` unterscheidet Basic Link (`0`) von Advanced Link (`1`).
Diese Zerlegung ist die einzige zulässige Lesart des Feldes; die
Kopflängen-Tabelle in §3.1.5 hängt genau an `[1:0]` (R-09-05).

**Korrektur einer Fehllesart der Aufzeichnung.** Die Vor-Antwort der
Referenz-Basisstation (Burst #775, Längenangabe 7 Oktette) enthält **keine
LLC-PDU**. Nachrechnung: MAC-Kopf mit Adressart SSI und gesetztem
Zuweisungsflag = 51 bit (`06 §3.4.1`), Längenangabe 7 → 56 bit, verbleiben
5 bit; deren Inhalt ist `10000₂` [GOLD docs/reference_decode/dl_full.md:18150 ff.,
`BKN1 info` = `0x2239282FF4401000108000000000000`]. Das ist genau die Füllfolge
nach `06 §3.7` F4 (erstes Füllbit `1`, dann Nullen) bei gesetztem Füllbit-Anzeiger
(Bit 2 des Kopfes = 1). Die Lesart „LLC-Typ `1000₂` = AL-SETUP" ist ausgeschlossen,
weil die AL-SETUP-PDU nach [ETSI §21.2.3.5 Tabelle 21.23] weit mehr als 5 bit
belegt (allein die Pflichtfelder hinter dem Typfeld sind > 15 bit). **Folge für
V2:** Die Vor-Antwort ist eine reine MAC-RESOURCE ohne TM-SDU (`06 §3.9`); die
LLC-Schicht ist an ihr nicht beteiligt.

**Verbindlich ist die Fassung dieses Abschnitts.** Die Fehllesart stand an drei
Stellen in `08_TIMING` (§3.4.2 Tabellenzeile FN02 der Anmeldesequenz, §3.4.3 R-2,
§5.2 Gold-Vergleichstabelle) und ist dort auf „ohne TM-SDU, kein LLC-Anteil"
korrigiert; `08` verweist für die Nachrechnung hierher. Die verallgemeinerte
Vermeidungsregel — **Bitbilanz „Längenangabe minus MAC-Kopfbreite" vor jeder
LLC-Interpretation** — ist Teil der Prüfung von `17` V-17-5.

Die Vor-Antwort im Gruppenruf-Ablauf ist dagegen eine echte BL-ACK: 43 bit
MAC-Kopf (Adressart SSI, alle drei Flags `0`) + 5 bit LLC = 48 bit = 6 Oktette,
Füllbit-Anzeige `0`, die fünf Bits hinter dem Kopf sind `00110₂` = BL-ACK mit
`N(R) = 0` [GOLD docs/reference_decode/dl_full.md:137676 ff., Burst #5883
(TN1 FN01 MN60), `BKN1 info` = `0x0031282FF4060010800000000000000`,
Längenangabe 6]; Querverweis auf die Frame-Lage: `08_TIMING §3.4.2`.

#### 3.1.2 Kopf-Layouts (MSB-first, Bit 0 = erstes gesendetes Bit der LLC-PDU)

| BL-ACK [ETSI §21.2.2.1 Tab. 21.4] | Bit | Breite |
|---|---:|---:|
| LLC-PDU-Typ = `0011₂` | 0 | 4 |
| `N(R)` | 4 | 1 |
| TL-SDU (optional) | 5 | var |

| BL-ADATA [ETSI §21.2.2.2 Tab. 21.6] | Bit | Breite |
|---|---:|---:|
| LLC-PDU-Typ = `0000₂` | 0 | 4 |
| `N(R)` | 4 | 1 |
| `N(S)` | 5 | 1 |
| TL-SDU | 6 | var |

| BL-DATA [ETSI §21.2.2.3 Tab. 21.8] | Bit | Breite |
|---|---:|---:|
| LLC-PDU-Typ = `0001₂` | 0 | 4 |
| `N(S)` | 4 | 1 |
| TL-SDU | 5 | var |

| BL-UDATA [ETSI §21.2.2.4 Tab. 21.10] | Bit | Breite |
|---|---:|---:|
| LLC-PDU-Typ = `0010₂` | 0 | 4 |
| TL-SDU | 4 | var |

Bei gesetztem FCS-Flag folgen der TL-SDU 32 bit FCS; der Kopf ändert sich
nicht.

**`N(R)` steht vor `N(S)`.** Das ist die Reihenfolge der ETSI-Tabellen und
bit-exakt in der Gold-Aufzeichnung belegt: in Burst #783 sind die sechs
BL-ADATA-Kopfbits `0 0 00 0 1` mit `N(R) = 0`, `N(S) = 1`, gefolgt vom
Protokoll-Diskriminator `001` [GOLD `info_hex` =
`0x20a9282ff440009571000150746e0981302f4d63200010800000…`, Bitpositionen 51…59].
V1 packt in derselben Reihenfolge [CODE
rtl/lmac/tetra_mac_resource_dl_builder.v:606-615].

#### 3.1.3 Sequenznummern — normativ

**Zwei Variablen je Verbindung** [ETSI §22.3.2.0]:

- `V(S)` — die als nächstes zu sendende TL-SDU-Nummer,
- `V(R)` — die letzte empfangene TL-SDU-Nummer.

**Regel 1 (Quittung).** `N(R) := V(R)`, und `V(R) := N(S)` der empfangenen
BL-DATA/BL-ADATA [ETSI §22.3.2.3, Fall k) ii): *„memorize a waiting
acknowledgement with number V(R) = N(S)"*; Fall d): *„issue a BL-ACK PDU with an
acknowledgement number N(R) = V(R)"*]. Es wird also **die empfangene Nummer
zurückgespiegelt**, nicht die nächste erwartete — ETSI weist ausdrücklich auf
den Unterschied zu HDLC hin [ETSI §22.2.1.1 NOTE].

**Regel 2 (eigene Nummer).** `N(S) := V(S)` [ETSI §22.3.2.3, Fall d) i)]. Eine
Wiederholung derselben TL-SDU trägt dasselbe `N(S)`. ETSI inkrementiert `V(S)`
**nicht** nach der Übertragung, sondern erst bei Quittung durch die Gegenstelle
oder endgültigem Fehlschlag [ETSI §22.3.2.3, Fälle g), h), i) und j) — Fall f)
startet nur `T.251` und meldet die erste vollständige Übertragung nach oben, er
ändert `V(S)` nicht]. Der Umschaltzeitpunkt in V2 weicht davon bewusst ab, weil
unsere MAC-Schicht keine Per-PDU-Übertragungsbestätigung liefert; die
Festlegung und ihre Begründung stehen in R-09-04 und §6 Punkt 1.

**Regel 3 (Startwert).** `V(S) = 0` beim ersten Kontakt [ETSI §22.3.2.1].
`V(R)` ist vor dem ersten Empfang undefiniert; solange `vr_valid = 0` darf keine
BL-ACK und keine BL-ADATA gesendet werden.

**Gold-Beleg, alle sechs Antwortfälle derselben Verbindung** (Teilnehmer
`0x282FF4`, [GOLD docs/reference_decode/]):

| Nr. | DL-PDU | DL `N(R)` | DL `N(S)` | auslösendes UL `N(S)` | MS-Quittung `N(R)` |
|---|---|---:|---:|---:|---:|
| 1 | D-LOC-UPD-ACCEPT #783 | 0 | 1 | UL #0 = 0 | UL #2 = 1 |
| 2 | D-LOC-UPD-ACCEPT #2523 | 0 | 0 | UL #4 = 0 | — |
| 3 | D-LOC-UPD-ACCEPT #4115 | 0 | 1 | UL #8 = 0 | UL #10 = 1 |
| 4 | D-ATTACH-DETACH-GRP-ID-ACK #4811 | 1 | 0 | UL #11 = 1 | UL #13 = 0 |
| 5 | D-ATTACH-DETACH-GRP-ID-ACK #5343 | 0 | 1 | UL #14/#16 = 0 | UL #18 = 1 |
| 6 | D-ATTACH-DETACH-GRP-ID-ACK #5655 | 1 | 0 | UL #19 = 1 | UL #21 = 0 |

`N(R)` ist in allen sechs Fällen gleich dem empfangenen `N(S)` (Regel 1). `N(S)`
alterniert über die gesamte Aufzeichnung `1,0,1,0,1,0` — **über PDU-Typen
hinweg**, also aus einer einzigen Verbindungsvariablen (Regel 2). Die
MS-Quittung spiegelt jeweils das `N(S)` der Basisstation zurück, was Regel 1 auf
der Gegenseite bestätigt. Fall 5 ist der Beweis, dass `N(R)` nicht alternieren
darf: das Endgerät sendet `N(S) = 0` **zweimal** (UL #14 und die Wiederholung
UL #16), die Basisstation antwortet mit `N(R) = 0`.

> **Was V1 hier falsch macht — zwei getrennte Fehler.**
> **(a)** Für die Anmeldebestätigung sind `N(S)` und `N(R)` **fest auf 0**
> verdrahtet [CODE rtl/lmac/tetra_mle_registration_fsm.v:356-359]. `N(R) = 0`
> stimmt bei einer Erstanmeldung zufällig, weil das Endgerät dort mit
> `V(S) = 0` beginnt; bei jeder weiteren Aufenthaltsaktualisierung derselben
> Verbindung ist es falsch. `N(S) = 0` weicht in zwei von drei Gold-Fällen ab.
> **(b)** Für die Gruppen-Quittung führt V1 eine Tabelle, die `N(S)` **und**
> `N(R)` alterniert [CODE sw/tetra_attach_daemon.c:145-176, Startwert
> `ns=0, nr=1` in :157]. Das trifft die Gold-Werte, solange das Endgerät
> ordnungsgemäß alterniert, und ist bei der ersten Wiederholung falsch — genau
> Fall 5. Nur der BL-ACK-Pfad ist korrekt: dort wird `N(R)` aus dem empfangenen
> `N(S)` genommen [CODE sw/tetra_attach_daemon.c:352, :915].

#### 3.1.4 Prüfsumme (FCS)

| Eigenschaft | Festlegung | Beleg |
|---|---|---|
| Breite | 32 bit | [ETSI §21.1.2.3, §21.3.1] |
| Lage | unmittelbar hinter der TL-SDU, vor den MAC-Füllbits | [ETSI §21.1.2.3, Bild 21.1] |
| **Abdeckungsbereich** | **genau die TL-SDU** — nicht der LLC-Kopf, nicht der MAC-Kopf | [ETSI §22.3.2.3 a) ii): *„calculate FCS … and append it to TL-SDU"* — die Prüfsumme entsteht auf der TL-SDU, **bevor** der LLC-Kopf existiert; gleichlautend für den Advanced Link [ETSI §21.1.4.2: *„This FCS shall be calculated over the entire TL-SDU"*]. Für den Basic Link nennt die Norm die Abdeckung nicht in einem eigenen Satz; die Ableitung aus §22.3.2.3 ist eindeutig |
| Generator | `G(x) = 1 + x + x² + x⁴ + x⁵ + x⁷ + x⁸ + x¹⁰ + x¹¹ + x¹² + x¹⁶ + x²² + x²³ + x²⁶ + x³²` | [ETSI Anhang C, (C.1)] |
| Bitabbildung | Koeffizient von `x³¹` = MSB, `x⁰` = LSB, absteigend gesendet | [ETSI §21.3.1] |
| Verwendung im Basic Link | optional, über das FCS-Flag angezeigt | [ETSI §21.1.2.3, §20.2.4.25] |

**Berechnungsvorschrift, in der vorgeschriebenen Reihenfolge**
[ETSI Anhang C]:

1. Die **ersten 32 bit** der TL-SDU werden komplementiert. **Ist die TL-SDU
   kürzer als 32 bit, werden genau diese Bits komplementiert** — und keine
   weiteren. Diese Abweichung von ISO/IEC 13239 ist in der Norm eigens
   vermerkt [ETSI Anhang C NOTE].
2. Die `n` Bits werden als Koeffizienten von `M(x)` (Grad `n−1`) gelesen.
3. `M(x)·x³²` wird durch `G(x)` geteilt, Rest `R(x)`.
4. Die 32 Koeffizienten von `R(x)` werden komplementiert; das Ergebnis ist die
   FCS.

**Verhalten bei kurzen Nutzlängen — unmissverständlich:**

- `n = 0` (BL-ACK ohne TL-SDU): die FCS-Variante ist **nicht** verwendbar. Die
  FCS-tragende BL-ACK ist normativ nur bei vorhandener TL-SDU zulässig
  [ETSI §21.2.2.1: *„This PDU shall be used only if a TL-SDU is present"*].
  Eine BL-ACK ohne Nutzdaten wird immer als Typ `0011₂` gesendet.
- `1 ≤ n < 32`: Schritt 1 komplementiert nur die vorhandenen `n` Bits. Eine
  Implementierung, die den Initialwert des Schieberegisters auf `0xFFFF_FFFF`
  setzt und dann `n` Bits einschiebt, ist genau dann korrekt, wenn sie nach
  `n < 32` Bits **nicht** weiter komplementiert. Der Testvektorsatz für
  `n = 8, 24, 31` (§5.1) ist Pflicht, weil dieser Fall der einzige ist, in dem
  sich die verbreitete CRC-32-Variante von der TETRA-FCS unterscheidet.
- `n ≥ 32`: Standardfall.

**Empfangsseite (R-09-07):** Ist das FCS-Flag gesetzt, ist die TL-SDU die
LLC-PDU **ohne** Kopf und **ohne** die letzten 32 bit. Die Prüfung erfolgt über
dieselbe Funktion; bei Fehlschlag verhält sich die Schicht, als wäre die PDU
nicht angekommen: `llc_fcs_err` inkrementiert, `V(R)` bleibt unverändert, keine
neue Quittung [ETSI §22.3.2.3 k) ii), zweiter Fall: *„then no acknowledgement is
sent, i.e. LLC action against the received BL-DATA with incorrect FCS is as that
PDU was not received"*]. Die Norm knüpft das an die Bedingung, dass keine
**frühere** noch unquittierte PDU vorliegt; eine bereits ausstehende Quittung
wird also weiterhin gesendet. Genau in dieser Auflösung liegt der scheinbare
Widerspruch zu `11_SDS §Fehlerbehandlung`, wo bei verletztem Prüffeld eine
Quittung genannt ist: gemeint ist die ausstehende Quittung der vorigen PDU,
nicht eine Quittung der fehlerhaften.

> **Was V1 hier falsch macht.** (a) Die Sendeseite kann keine FCS erzeugen: das
> Flag ist im Kopfaufbau fest auf 0 [CODE
> rtl/lmac/tetra_mac_resource_dl_builder.v:212 `LLC_HAS_FCS_OFF = 1'b0`, benutzt
> in :609, :621, :630, :637]. Das ist zulässig (die FCS
> ist optional), aber es gibt auch keine Stelle, an der sie nachrüstbar wäre.
> (b) Die Empfangsseite behandelt das FCS-Flag an einer Stelle korrekt als
> längenneutral [CODE sw/tetra_attach_daemon.c:1118-1128 — Maskierung auf
> `llc_t & 0x3`]; an derselben Stelle ist jedoch die BL-ACK-Kopflänge mit
> **4 statt 5 bit** angesetzt [CODE sw/tetra_attach_daemon.c:1126
> `case 0x3: llc_hdr_bits = 4;`], obwohl der BL-ACK-Kopf 4 bit Typ + `N(R)` =
> 5 bit ist [ETSI §21.2.2.1 Tab. 21.4, §3.1.2/§3.1.5]. Sobald eine BL-ACK **mit**
> Nutzdaten eintrifft, verschiebt auch dieser „korrekte" Pfad den
> TL-SDU-Offset um 1 bit. An einer zweiten Stelle wird die Kopflänge aus dem
> vollen 4-bit-Feld abgeleitet, sodass BL-ADATA+FCS (`0100₂`) mit 5 statt 6 bit
> und BL-UDATA+FCS (`0110₂`) mit 5 statt 4 bit angesetzt wird [CODE
> sw/tetra_attach_daemon.c:217]. (c) Die 32 FCS-Bits werden nirgends von der
> Nutzlast abgezogen. Alle drei Punkte fallen mit R-09-05 bis R-09-07 weg.

#### 3.1.5 Kopflänge — die eine Tabelle

```c
/* Rückgabe: Kopflänge in Bit, oder -1 wenn nicht Basic Link (R-09-08). */
int tetra_llc_hdr_bits(uint8_t llc_pdu_type)
{
    if (llc_pdu_type & 0x8u) return -1;          /* AL-*/L2-Signalisierung   */
    switch (llc_pdu_type & 0x3u) {               /* FCS-Bit [2] ignorieren   */
    case 0x0: return 6;                          /* BL-ADATA: Typ+N(R)+N(S)  */
    case 0x1: return 5;                          /* BL-DATA:  Typ+N(S)       */
    case 0x2: return 4;                          /* BL-UDATA: Typ            */
    default:  return 5;                          /* BL-ACK:   Typ+N(R)       */
    }
}
```

Die Maskierung auf `[1:0]` ist die Umsetzung von R-09-05 und darf nicht durch
eine Fallunterscheidung über alle 16 Werte ersetzt werden — genau dabei sind in
V1 zwei Codepunkte verlorengegangen (§3.1.4).

#### 3.1.6 Schnittstelle

Alle Bitpuffer: ein Bit je Byte, Index 0 = zuerst gesendet (R-09-25).

```c
/* --- Senden ------------------------------------------------------------- */
/* Baut die LLC-PDU (Kopf + TL-SDU [+ FCS]) nach out.
 * link:    Verbindungszustand; V(S)/V(R) werden gelesen und fortgeschrieben.
 * type:    0=BL-ADATA, 1=BL-DATA, 2=BL-UDATA, 3=BL-ACK  (Subtyp, ohne FCS-Bit)
 * use_fcs: 1 = FCS anhängen und FCS-Bit im Typfeld setzen.
 * out_cap: Kapazität von out in Bit.
 * Rückgabe: Länge der LLC-PDU in Bit, <0 bei Parameterfehler.            */
int tetra_llc_build(tetra_llc_link_t *link, uint8_t type, uint8_t use_fcs,
                    const uint8_t *tl_sdu, int tl_sdu_bits,
                    uint8_t *out, int out_cap);

/* --- Empfangen ---------------------------------------------------------- */
typedef struct {
    uint8_t  pdu_type;      /* 4 bit, wie empfangen                        */
    uint8_t  has_ns, ns;
    uint8_t  has_nr, nr;
    int      tl_sdu_off;    /* Bitindex der TL-SDU im Eingabepuffer        */
    int      tl_sdu_bits;   /* ohne FCS                                    */
    uint8_t  fcs_present;
    uint8_t  fcs_ok;        /* nur gültig wenn fcs_present = 1             */
} tetra_llc_rx_t;

/* buf/bits = TM-SDU aus 06 §3.11. Rückgabe 0 = ok, -1 = nicht Basic Link,
 * -2 = Länge unplausibel, -3 = FCS falsch.                              */
int tetra_llc_parse(const uint8_t *buf, int bits, tetra_llc_rx_t *out);

/* Verbindungszustand fortschreiben; nach erfolgreichem Parse aufzurufen.
 * Setzt vr/vr_valid/ack_pending und last_slot_idx. slot_idx ist der aus dem
 * Zeitstempel (07 §3.4, W1) gebildete monotone Slotindex (R-09-23).      */
void tetra_llc_rx_commit(tetra_llc_link_t *link, const tetra_llc_rx_t *rx,
                         uint32_t slot_idx);

/* Verbindung nachschlagen oder anlegen (Verdrängung nach §2.3).          */
tetra_llc_link_t *tetra_llc_link_get(uint32_t ssi, uint32_t slot_idx);
```

#### 3.1.7 Fehler- und Randfallverhalten

| Fall | Verhalten | Zähler |
|---|---|---|
| LLC-Typ `≥ 1000₂` | verwerfen | `llc_unsupported_type` |
| TM-SDU kürzer als der Kopf | verwerfen | `llc_short_pdu` |
| FCS-Flag gesetzt, TM-SDU < Kopf + 32 bit | verwerfen | `llc_short_pdu` |
| FCS falsch | verwerfen, `V(R)` unverändert, **keine neue** Quittung (§3.1.4) | `llc_fcs_err` |
| BL-DATA/BL-ADATA empfangen, während für dieselbe Verbindung noch eine Quittung aussteht | die alte Quittung entfällt, die neue gilt — unabhängig von `N(S)` [ETSI §22.3.2.3 NOTE 2] | `llc_ack_superseded` |
| BL-ACK empfangen mit `N(R) ≠ V(S)` | die eigene TL-SDU gilt als **nicht** quittiert; enthaltene Nutzdaten werden dennoch nach oben gegeben [ETSI §22.3.2.3 j)] | `llc_ack_mismatch` |
| Quittung steht aus, aber es folgt eine eigene TL-SDU an dieselbe Verbindung | beides in **einer** BL-ADATA senden [ETSI §22.3.2.3 d)] — das ist der Normalfall für Anmeldebestätigung und Gruppen-Quittung | — |
| Quittung steht aus und die eigene TL-SDU passt nicht mehr in den Block | erst BL-ACK ohne Nutzdaten, TL-SDU danach als BL-DATA [ETSI §22.3.2.3 d)] | `llc_ack_split` |

**Wiederholungen sind Sache des Endgeräts.** Die Wiederholzeitgeber
`T.251` (Vorgabe 4 Signalisierungsframes) und `T.252` (9 Signalisierungsframes)
sowie die Zahl der Wiederholungen `N.252` sind MS-seitig
[ETSI Anhang A.1, A.2]. Die Basisstation braucht keinen eigenen
Wiederholmechanismus auf LLC-Ebene; sie muss nur schnell genug quittieren
(`08_TIMING §3.4`). Die maximale TL-SDU-Länge im Basic Link ist `N.251` =
2 595 bit [ETSI Anhang A.2]; die in Stufe 1 gebauten TL-SDUs liegen bei
≤ 105 bit (§3.4) und damit weit darunter.

### 3.2 MLE — Vermittlung

#### 3.2.1 Protokoll-Diskriminator

3 bit, **erstes** Feld der MLE-PDU, unmittelbar hinter dem LLC-Kopf
[ETSI §18.4.1.1, §18.5.21 Tabelle 18.87]:

| Wert | Protokoll | Stufe 1 |
|---|---|---|
| `000₂` | reserviert | verwerfen |
| `001₂` | MM | `tetra_mm` (dieses Kapitel) |
| `010₂` | CMCE | `10_CMCE_CALL`, `11_SDS` |
| `011₂` | reserviert | verwerfen |
| `100₂` | SNDCP | verwerfen (zählen) |
| `101₂` | MLE-Protokoll | verwerfen (zählen) — Sendeseite: Broadcast, `04` |
| `110₂` | TETRA-Management-Entität | verwerfen (zählen) |
| `111₂` | für Tests reserviert | verwerfen |

Beim Senden setzt MLE den Diskriminator vor die SDU, beim Empfangen entfernt er
ihn und übergibt den Rest [ETSI §18.4.1.1]. Gold-Beleg: #783 trägt `001`
(Bitpositionen 57…59), die Rufsteuerungs-PDU #5887 trägt `010`
[GOLD, `DIFF_vs_reference.md:90`].

#### 3.2.2 Vermittlungsregel (R-09-10)

> Die Vermittlung entscheidet **allein** anhand des Protokoll-Diskriminators.
> Woher die TL-SDU kommt — aus einem einzelnen Burst oder aus der
> Zusammensetzung mehrerer Fragmente —, ist für die Vermittlung ohne Bedeutung.

```c
typedef enum { MLE_PD_MM = 1, MLE_PD_CMCE = 2, MLE_PD_SNDCP = 4,
               MLE_PD_MLE = 5, MLE_PD_MGMT = 6 } tetra_mle_pd_t;

/* tl_sdu/bits: LLC-Nutzlast (ein Bit je Byte). slot_idx: monotoner Slotindex
 * aus dem Zeitstempel (07 §3.4, W1). Vermittelt nach PD; Rückgabe 0 =
 * zugestellt, -1 = PD in Stufe 1 nicht bedient (gezählt), -2 = zu kurz.  */
int tetra_mle_route_up(uint32_t ssi, const uint8_t *tl_sdu, int bits,
                       uint32_t slot_idx);

/* Setzt den Diskriminator vor die SDU. Rückgabe: Länge in Bit, <0 = Fehler. */
int tetra_mle_wrap_down(tetra_mle_pd_t pd, const uint8_t *sdu, int bits,
                        uint8_t *out, int out_cap);
```

Diese Regel ist die Auflösung eines konkreten V1-Zustands: die
Fragment-Zusammensetzung schreibt dort den Diskriminator **fest** auf CMCE und
ruft den Kurznachrichten-Decoder; erst ein nachträglich eingefügter Zweig liest
den echten Diskriminator aus dem Body und leitet MM-PDUs an den MM-Wanderer um
[CODE sw/tetra_attach_daemon.c:920-959, insbesondere die Umleitung in :942-957].
Solange dieser Zweig fehlte, wurde ein mehrfragmentiger Gruppenwechsel
verworfen und das Endgerät wiederholte endlos [CODE
sw/tetra_attach_daemon.c:933-937]. In V2 gibt es keine Umleitung, weil es keine
herkunftsabhängige Vorentscheidung gibt: der Zusammensetzer liefert eine TM-SDU,
LLC liefert eine TL-SDU, MLE liest den Diskriminator.

Gleichzeitig entfällt der zweite Teil derselben Last: V1 parst dieselbe
Uplink-PDU auf zwei Wegen — einmal aus der Zusammensetzungs-Mailbox über den
MM-Wanderer [CODE sw/tetra_attach_daemon.c:381-434] und einmal aus einem
Rohbit-Fenster über den Rufsteuerungs-Parser [CODE
sw/tetra_attach_daemon.c:1095-1200] — mit zwei getrennten Berechnungen des
LLC-Offsets. In V2 gibt es einen Weg (§2.1).

### 3.3 MM-Kodierregeln (Annex E)

Verbindlich für **alle** MM-PDUs, gleichermaßen für CMCE und SNDCP
[ETSI §E.1.1 Tabelle E.1]:

1. Reihenfolge: PDU-Typ, dann Typ-1-Felder (feste Breite, immer vorhanden),
   dazu jeweils direkt anschließende bedingte Felder.
2. Danach **ein O-Bit**. `0` = die PDU endet hier: keine P-Bits, keine
   Typ-2-Elemente, keine M-Bits.
3. Bei `O = 1`: für **jedes** in der PDU-Beschreibung definierte Typ-2-Element
   genau **ein P-Bit** in Tabellenreihenfolge; `1` = Element folgt.
   Vor einem Feld, das zu einem Typ-2-Element bedingt ist, steht **kein** P-Bit.
4. Danach **M-Bits**: je vorhandenem Typ-3-Element `1` + 4-bit-Kennung +
   11-bit-Länge (in Bit) + Inhalt; je vorhandenem Typ-4-Element `1` +
   4-bit-Kennung + 11-bit-Gesamtlänge + 6-bit-Wiederholungszahl +
   Wiederholungen. **Nicht vorhandene Typ-3/4-Elemente erzeugen kein M-Bit
   und keine Kennung.** Nach dem letzten Element steht ein M-Bit `0` — das ist
   das letzte Bit der PDU.
5. Werden mehrere Typ-3/4-Elemente gesendet, gilt aufsteigende
   Elementkennung. Empfangsseitig ist zusätzlich die Reihenfolge der
   PDU-Tabelle zu akzeptieren [ETSI Tab. 16.11 NOTE].

**Elementkennungen, Downlink** [ETSI §16.10.51 Tab. 16.95]: `0001` Default
group attachment lifetime, `0010` New registered area, `0100` Group report
response, `0101` **Group identity location accept**, `0111` **Group identity
downlink**, `1101` Cell type control, `1111` Proprietary.

**Elementkennungen, Uplink** [ETSI §16.10.51 Tab. 16.95a]: `0011` **Group
identity location demand**, `0100` Group report response, `1000` **Group
identity uplink**, `1011` Extended capabilities, `1111` Proprietary.

Die 11-bit-Länge macht unbekannte Typ-3/4-Elemente überspringbar; das ist der
Grund, aus dem R-09-14 sie **nicht** als Fehler behandelt
[ETSI §E.1.1 NOTE 6].

### 3.4 MM-PDUs

PDU-Typ = 4 bit, in Up- und Downlink **unterschiedlich** belegt
[ETSI §16.10.39 Tab. 16.75]. Die in Stufe 1 verwendeten Werte:

| Wert | Downlink | Uplink |
|---|---|---|
| `0001₂` | — | U-ITSI DETACH |
| `0010₂` | — | U-LOCATION UPDATE DEMAND |
| `0101₂` | **D-LOCATION UPDATE ACCEPT** | — |
| `0111₂` | **D-LOCATION UPDATE REJECT** | U-ATTACH/DETACH GROUP IDENTITY |
| `1000₂` | — (reserviert) | U-ATTACH/DETACH GROUP IDENTITY ACK |
| `1010₂` | **D-ATTACH/DETACH GROUP IDENTITY** | — (reserviert) |
| `1011₂` | **D-ATTACH/DETACH GROUP IDENTITY ACK** | — |

> **Namensdrift in V1 (R-09-24).** V1 bezeichnet die Anmeldebestätigung im Code
> als „mm=1" und die Ablehnung als „mm=4" [CODE sw/tetra_tx_transport.h:25-26,
> sw/tetra_tx_transport.c:82], obwohl die On-Air-Werte `0101₂` = 5 und
> `0111₂` = 7 sind — die RTL-Konstanten sind korrekt [CODE
> rtl/lmac/tetra_d_location_update_encoder.v:89-90]. Zwei Zahlenräume für
> dieselbe Sache; in V2 gilt der ETSI-Wert, überall.

#### 3.4.1 U-LOCATION UPDATE DEMAND (`0010₂`) — Wanderer

Feldreihenfolge [ETSI §16.9.3.4 Tab. 16.18]:

| # | Feld | Breite | Typ | Regel |
|---:|---|---:|---|---|
| 1 | PDU-Typ | 4 | 1 | `0010₂` |
| 2 | Location update type | 3 | 1 | [ETSI §16.10.35 Tab. 16.67]; `011₂` = ITSI attach |
| 3 | Request to append LA | 1 | 1 | [ETSI §16.10.43] |
| 4 | Cipher control | 1 | 1 | [ETSI §16.10.2] |
| 5 | Ciphering parameters | 10 | C | nur wenn Feld 4 = 1 |
| — | O-Bit | 1 | — | 0 → Ende |
| 6 | P + Class of MS | 24 | 2 | |
| 7 | P + Energy saving mode | 3 | 2 | [ETSI §16.10.9] |
| 8 | P + LA information | **15** | 2 | = LA (14) + Zero bit (1) [ETSI §16.10.34 Tab. 16.65] |
| 9 | P + SSI | 24 | 2 | ISSI des Endgeräts |
| 10 | P + Address extension | 24 | 2 | Netzkennung des Endgeräts |
| — | M-Bit-Kette | | 3/4 | `0011₂` Group identity location demand, `0100₂` Group report response, `1011₂` Extended capabilities, `1111₂` Proprietary |

**Group identity location demand** (Typ-3, Kennung `0011₂`)
[ETSI §16.10.24 Tab. 16.56]: Reserved (1), Group identity attach/detach mode
(1), dann O-Bit und die M-Bit-Kette der eigenen Elementebene, darin
**Group identity uplink** als Typ-4-Element (Kennung `1000₂`).

**Group identity uplink**, ein Datensatz [ETSI §16.10.27 Tab. 16.58]:

| Feld | Breite | Bedingung |
|---|---:|---|
| Group identity attach/detach type identifier (GIADTI) | 1 | 0 = Anhängen, 1 = Abhängen [ETSI §16.10.18] |
| Class of usage | 3 | nur GIADTI = 0 [ETSI §16.10.6] |
| Group identity detachment uplink | 2 | nur GIADTI = 1 [ETSI §16.10.21] |
| Group identity address type (GIAT) | 2 | 0 = GSSI, 1 = GTSI, 2 = (V)GSSI [ETSI §16.10.15 Tab. 16.47]; **3 ist nur im Uplink-Datensatz reserviert** [ETSI §16.10.27 Tab. 16.58 NOTE 2] — allgemein steht `11₂` für GTSI+(V)GSSI [Tab. 16.47], und im Downlink-Datensatz für GSSI + Extension + (V)GSSI [ETSI §16.10.22 Tab. 16.54 NOTE 2] |
| GSSI | 24 | GIAT ∈ {0,1} |
| Address extension | 24 | GIAT = 1 |
| (V)GSSI | 24 | GIAT = 2 |

**Die 15 bit des LA-Information-Elements** sind der Punkt, an dem V1 einen
richtigen Wert mit einer falschen Begründung liest: der Code entnimmt 15 bit und
schiebt um 1 nach rechts, begründet aber mit dem Verhalten einer fremden
Implementierung [CODE sw/tetra_mm_demand_parser.c:87-96]. Der Grund ist das
Zero-Bit hinter dem 14-bit-LA [ETSI Tab. 16.65]. In V2 steht die Begründung an
der Struktur, nicht am Vorbild.

**Der Wanderer muss alle Datensätze auswerten, nicht nur den ersten.** V1
extrahiert aus dem Group-identity-location-demand genau **einen** Datensatz und
nur für `GIADTI = 0` und `GIAT ∈ {0,1}` [CODE
sw/tetra_mm_demand_parser.c:129-183]. Für die Anmeldung genügt das, weil die
Aufzeichnung dort einen Datensatz zeigt; für R-09-17 genügt es nicht. V2 wandert
die vollständige Wiederholungszahl (bis 63) und stellt die Datensätze als Feld
bereit, begrenzt durch `TETRA_MM_GID_MAX = 8` [ANNAHME: Reserve, nicht
Blockkapazität. In eine **unfragmentierte** zusammengesetzte Uplink-TM-SDU von
147 bit (`06 §3.11`) passen höchstens **3** Datensätze: 147 − 5 (LLC BL-DATA)
− 3 (MLE-PD) − 30 (PDU-Typ 4 + Report 1 + Mode 1 + O-Bit 1 + M-Bit 1 +
Kennung 4 + Länge 11 + Wiederholungszahl 6 + Abschluss-M-Bit 1) = 109 bit,
ein Anhänge-Datensatz ist 30 bit (§3.4.1). Die 8 sind Reserve für eine künftig
fragmentierte Anforderung (§6 Punkt 3); überzählige Datensätze werden gezählt und
abgelehnt, nicht ignoriert. V1 begrenzt an derselben Stelle hart auf 3 [CODE
sw/tetra_attach_daemon.c:658]].

#### 3.4.2 D-LOCATION UPDATE ACCEPT (`0101₂`)

Inhalt [ETSI §16.9.2.7 Tab. 16.11]. Stufe 1 sendet die folgende Ausprägung —
bit-exakt gegen [GOLD Burst #783] verifiziert:

| Bit | Breite | Feld | Wert |
|---:|---:|---|---|
| 0 | 4 | PDU-Typ | `0101₂` |
| 4 | 3 | **Location update accept type** | **Echo des `location update type` der Anforderung** (R-09-11) [ETSI §16.10.35a Tab. 16.68] |
| 7 | 1 | O-Bit | `1` |
| 8 | 1 | P: SSI | `0` (keine ASSI-Vergabe in Stufe 1) |
| 9 | 1 | P: Address extension | `0` |
| 10 | 1 | P: Subscriber class | `0` |
| 11 | 1 | P: Energy saving information | `1` |
| 12 | 14 | Energy saving information | `0` = Stay Alive + FN 0 + MN 0 [ETSI §16.10.10 Tab. 16.40] |
| 26 | 1 | P: SCCH info and distribution on 18th frame | `0` |
| 27 | 1 | M-Bit | `1` wenn Gruppen-Element folgt, sonst `0` |
| 28 | 4 | Typ-3-Kennung | `0101₂` = Group identity location accept |
| 32 | 11 | Länge | `58` |
| 43 | 58 | Group identity location accept | siehe unten |
| 101 | 1 | Abschließendes M-Bit | `0` |

**Gesamtlänge 102 bit** mit Gruppen-Element [GOLD Burst #783,
docs/reference_decode/dl_full.md:18355, MM-Body absolute Bitpositionen 60…161].
**Ohne Gruppen-Element ist Bit 27 selbst das abschließende M-Bit `0`** — es gibt
kein zweites (§3.3 Regel 4: für jedes vorhandene Typ-3/4-Element ein M-Bit `1`,
nach dem letzten Element genau **ein** M-Bit `0` als letztes Bit der PDU
[ETSI Anhang E]). Der Body endet damit bei Bit 27: **28 bit**
[ETSI §16.9.2.7 Tab. 16.11 + Anhang E].

V1 deklariert für diesen Fall `8'd36` [CODE
rtl/lmac/tetra_d_location_update_encoder.v:213], baut aber nur 29 Inhaltsbits
[CODE rtl/lmac/tetra_d_location_update_encoder.v:197-210] — 4+3+1+1+1+1+1+14+1
+1 (M-Bit) +1 (zweites M-Bit) = 29, Rest Padding. Zwei Fehler in einem: das
zweite M-Bit ist überzählig, und die deklarierte Länge liegt 7 bit über der
gebauten. Weder 36 noch 29 ist der Sollwert; verbindlich ist 28. Die Diskrepanz
gehört als Zeile nach `17_LESSONS_LEARNED`.

**Group identity location accept, 58 bit** [ETSI §16.10.23 Tab. 16.55 in
Verbindung mit §16.10.22 Tab. 16.54]:

| Bit (rel.) | Breite | Feld | Wert |
|---:|---:|---|---|
| 0 | 1 | Group identity accept/reject | `0` = accept [ETSI §16.10.12] |
| 1 | 1 | Reserved | `0` |
| 2 | 1 | O-Bit | `1` |
| 3 | 1 | M-Bit | `1` |
| 4 | 4 | Typ-4-Kennung | `0111₂` = Group identity downlink |
| 8 | 11 | Gesamtlänge | `38` = 6 + 32·1 |
| 19 | 6 | Wiederholungszahl | `1` |
| 25 | 1 | GIADTI | `0` = Anhängen |
| 26 | 2 | Group identity attachment lifetime | aus dem Profil; Gold `01₂` = „Attachment for next ITSI attach required" [ETSI §16.10.16 Tab. 16.48] |
| 28 | 3 | Class of usage | aus dem Profil; Gold `100₂` = 4 |
| 31 | 2 | GIAT | `00₂` = GSSI |
| 33 | 24 | GSSI | **nach R-09-12** |
| 57 | 1 | Abschließendes M-Bit | `0` |

**Einbettung und Kanal.** TM-SDU = LLC BL-ADATA (6 bit) + MLE-PD (3 bit) +
MM-Body (102 bit) = 111 bit. Mit dem MAC-RESOURCE-Kopf (Adressart SSI,
Zuweisungsflag = 1, Zuweisungselement `0x00`) = 51 bit ergibt das 162 bit →
Längenangabe 21 Oktette → **SCH/F** (`06 §3.4.1`, §3.7). Gold #783 hat
Längenangabe 21, Füllbitanzeige 1, danach `1` + fünf `0`, eine 16-bit-Null-PDU
und ein abschließendes `1` mit Nullen — also genau die Abschlussfolge aus
`06 §3.7` F4 [GOLD, Bitpositionen 162…191 des Infoworts]. Das AACH-Infowort des
Trägerslots ist `0x0009` (Unterschlitz 1 reserviert), weil dieselbe PDU dem
Endgerät über das Zuweisungselement einen Unterschlitz für seine LLC-Quittung
zusagt [GOLD #783 AACH-Info `0x0009`; Musterliste `06 §3.8.3`]. Die Software
setzt dieses Infowort **nicht** und trägt es auch nicht mit der PDU mit: es
entsteht im PL aus `resv_active`/`resv_pattern` des Zuweisungsblocks im selben
Staging-Zyklus wie die Aussendung (`06 §3.8.2`, `06 §3.9.5`, R-06-04). Der Wert
`0x0009` ist damit ein **Prüfkriterium** der Abnahme, keine Software-Ausgabe.

#### 3.4.3 D-LOCATION UPDATE REJECT (`0111₂`)

Inhalt [ETSI §16.9.2.9 Tab. 16.13]:

| Bit | Breite | Feld | Wert |
|---:|---:|---|---|
| 0 | 4 | PDU-Typ | `0111₂` |
| 4 | 3 | **Location update type** | Echo der Anforderung (dasselbe Prinzip wie R-09-11) |
| 7 | 5 | **Reject cause** | [ETSI §16.10.42 Tab. 16.81] |
| 12 | 1 | Cipher control | `0` |
| 13 | 1 | O-Bit | `0` |

**14 bit.** TM-SDU = 6 + 3 + 14 = 23 bit, mit MAC-Kopf 43 bit (ohne
Zuweisungselement) = 66 bit → Längenangabe 9 Oktette → passt in **SCH/HD**
(`06 §3.4`). LLC-Typ BL-ADATA, damit die Ablehnung die Quittung der Anforderung
mitträgt. [ANNAHME: In der Gold-Aufzeichnung kommt keine Ablehnung vor; die
Wahl von BL-ADATA folgt derselben Regel wie bei der Bestätigung — es liegt eine
zu quittierende TL-SDU vor.]

**Verwendete Ablehnungsgründe (normativ, R-09-19):**

| Situation | Reject cause | Klasse |
|---|---|---|
| Teilnehmer unbekannt, Richtlinie „nicht annehmen" | `00110₂` Congestion | Zelle |
| Datenbank voll | `00110₂` Congestion | Zelle |
| Teilnehmer ausdrücklich gesperrt | `00010₂` Illegal MS | System |
| Pflichtfeld in der Anforderung fehlt | `01001₂` Mandatory element error | System |

**Warum nicht „ITSI/ATSI unknown".** Gründe der Klasse *system rejection*
zählen beim Endgerät gegen `N351` (Vorgabe 4); danach verlässt es das Netz und
versucht keine Anmeldung mehr bis zum Aus- und Einschalten
[ETSI §16.11.2.1]. Für einen konfigurationsabhängigen Zustand — „dieser
Teilnehmer steht noch nicht in der Datenbank" — ist das die falsche Folge; ein
Zell-Ablehnungsgrund lässt das Endgerät es später erneut versuchen. Ein
System-Ablehnungsgrund ist nur zulässig, wenn die Ablehnung dauerhaft gemeint
ist.

> **Was V1 hier falsch macht.** Der archivierte Ablehnungs-Encoder erzeugte
> einen **8 bit** langen MM-Body aus PDU-Typ (4), einem **3-bit** Cause und
> einem O-Bit [CODE sw/tetra_tx_transport.c:84-88]. Damit fehlen das
> Location-update-type-Feld und das Cipher-control-Bit, und der Cause ist
> 2 bit zu kurz — die PDU ist strukturell nicht dekodierbar. Die
> Cause-Zuordnung im Kommentar (`1 → „no resources available"`,
> `2 → „illegal MS"` [CODE sw/tetra_attach_daemon.c:600-602]) verweist auf eine
> 3-bit-Tabelle, die es in [ETSI Tab. 16.81] nicht gibt.

#### 3.4.4 U-ATTACH/DETACH GROUP IDENTITY (`0111₂`) — Wanderer

Inhalt [ETSI §16.9.3.1 Tab. 16.15]:

| # | Feld | Breite | Typ |
|---:|---|---:|---|
| 1 | PDU-Typ | 4 | 1 |
| 2 | Group identity report | 1 | 1 (`1` = Report angefordert [ETSI §16.10.26]) |
| 3 | Group identity attach/detach mode | 1 | 1 (`0` = Ergänzung, `1` = alle abhängen und die genannten anhängen [ETSI §16.10.17 Tab. 16.49]) |
| — | O-Bit | 1 | — |
| 4 | M + `0100₂` Group report response | var | 3 |
| 5 | M + `1000₂` Group identity uplink | var | 4 |
| 6 | M + `1111₂` Proprietary | var | 3 |
| — | Abschluss-M-Bit `0` | 1 | — |

Reihenfolge Feld 2 **vor** Feld 3 — V1 wandert in derselben Reihenfolge
[CODE sw/tetra_mm_demand_parser.c:203-204]. Der Datensatzaufbau von
*Group identity uplink* ist identisch zu §3.4.1.

Die Erkennung des optionalen Group-report-response-Elements über ein Vorausschauen
auf die Elementkennung — V1 liest M-Bit und die folgenden 4 bit, ohne den Cursor
zu bewegen [CODE sw/tetra_mm_demand_parser.c:215-240] — ist in V2 nicht nötig
und nicht zulässig: nach §3.3 Regel 4 folgt hinter einem M-Bit `1` **immer** eine
Elementkennung, und der Wanderer entscheidet nach dieser Kennung, ob er den
Inhalt auswertet oder über die Länge überspringt. Das Vorausschauen ist ein
Symptom davon, dass V1 die Elementkette als feste Feldfolge behandelt.

#### 3.4.5 D-ATTACH/DETACH GROUP IDENTITY ACK (`1011₂`)

Inhalt [ETSI §16.9.2.2 Tab. 16.2]:

| Bit | Breite | Feld | Wert |
|---:|---:|---|---|
| 0 | 4 | PDU-Typ | `1011₂` |
| 4 | 1 | Group identity accept/reject | `0` = accept |
| 5 | 1 | Reserved | `0` |
| 6 | 1 | O-Bit | `1` wenn Datensätze folgen, sonst `0` |
| 7 | 1 | M-Bit | `1` |
| 8 | 4 | Typ-4-Kennung | `0111₂` = Group identity downlink |
| 12 | 11 | Gesamtlänge | `6 + Σ Datensatzlängen` (bei reinen Anhänge-Datensätzen `6 + 32·n`) |
| 23 | 6 | Wiederholungszahl | `n` |
| 29 | Σ | Datensätze | Anhängen: GIADTI (1) + Lifetime (2) + Class of usage (3) + GIAT (2) + GSSI (24) = **32 bit**; Ablehnen: GIADTI (1) + Detachment downlink (2) + GIAT (2) + GSSI (24) = **29 bit** (siehe unten) |
| 29+Σ | 1 | Abschluss-M-Bit | `0` |

**Längen: `n=1` → 62 bit, `n=2` → 94 bit, `n=3` → 126 bit.** Ohne Datensätze
(`O = 0`) → **7 bit**: PDU-Typ (4) + accept/reject (1) + Reserved (1) + O-Bit (1).
Bei `O = 0` folgt **kein** M-Bit — weder ein Abschluss-M-Bit noch sonst etwas
(§3.3 Regel 2, [ETSI Anhang E]: *„In case O-bit has value '0', the PDU contains
no more elements; no P-bits …, no M-bits nor type 3 or type 4 elements"*). V1 gibt
für diesen Fall 8 bit an [CODE sw/tetra_grpack_body.h:57]; das ist Drift und
gehört als Zeile nach `17_LESSONS_LEARNED`.

Bei einem **abgelehnten** Anhängen trägt der Datensatz `GIADTI = 1` und an der
Stelle der Anhänge-Parameter das 2-bit-Feld *Group identity detachment downlink*
[ETSI §16.10.22 Tab. 16.54, §16.10.20 Tab. 16.52]: `00₂` = unbekannte
Gruppenkennung, `01₂`/`10₂` = temporär, `11₂` = dauerhaft. Bei GIADTI = 0 steht
dort das Element *Group identity attachment* mit **5 bit** (Lifetime 2 + Class of
usage 3) [ETSI Tab. 16.54, §16.10.19 Tab. 16.51], bei GIADTI = 1 das
Detachment-Feld mit **2 bit**. Ein Ablehnungs-Datensatz ist damit
1 + 2 + 2 + 24 = **29 bit** lang, drei Bit kürzer als der 32-bit-Anhänge-Datensatz
— die Gesamtlänge und die Wiederholungszahl müssen aus den tatsächlich gebauten
Datensätzen gerechnet werden, nicht aus `32·n` (ein Ablehnungs-Datensatz ergibt
Gesamtlänge `6 + 29 = 35` und Body 59 bit).

**Ein akzeptiertes Abhängen erzeugt keinen Datensatz.** Die Norm verlangt in der
Quittung die Angabe der **nicht** akzeptierten Gruppenkennungen mit Grund und
erlaubt zusätzlich akzeptierte; ein abgelehntes Abhängen wird dadurch angezeigt,
dass die Quittung das Anhängen wieder enthält [ETSI §16.8.2]. Die
Referenz-Basisstation verhält sich genau so: die Anforderung enthält zwei
Datensätze (Abhängen der alten, Anhängen der neuen Gruppe), die Quittung
**einen** [GOLD #4811, Wiederholungszahl = 1].

**Bit-exakte Gold-Verifikation** [GOLD Burst #4811, `info_hex` =
`0x2081282ff440011b3704c09817a6b22000108000…`, Längenangabe 16, LLC BL-ADATA
`N(R)=1 N(S)=0`, MLE-PD `001`]: MM-Body ab Bitposition 60 =
`1011 0 0 1 1 0111 00000100110 000001 0 01 100 00 0x2F4D64 0` — **62 bit**,
Wiederholungszahl 1, Lifetime `01₂`, Class of usage `100₂` = 4, GIAT `00₂`,
GSSI `0x2F4D64`. Danach 6 Füllbits `100000` bis zur Oktettgrenze 128 bit
(= Längenangabe 16). TM-SDU 6 + 3 + 62 = 71 bit, mit MAC-Kopf 51 bit = 122 bit
→ Längenangabe 16 ✓.

> **Doku-gegen-Code-Widerspruch in V1, durch Gold entschieden.** Der
> Modulkopf des Erzeugers gibt für einen Datensatz **64 bit** an und nennt als
> verifizierte erste Bytes `0xB2 0xB8 …` [CODE sw/tetra_grpack_body.h:34-40];
> der Code erzeugt **62 bit** [CODE sw/tetra_grpack_body.c:101] und damit
> `0xB3 …`. Die 64-bit-Variante schreibt M-Bits für die **nicht vorhandenen**
> Elemente Proprietary und *Group Identity Security Related Information* — was
> §3.3 Regel 4 widerspricht. Gold #4811 hat an den betroffenen Positionen
> `O = 1` unmittelbar gefolgt von `M = 1` und der Kennung `0111₂`; die
> 64-bit-Lesart würde dort die Kennung `1110₂` ergeben. Der **Code** ist
> richtig, der Kommentar falsch. Für V2 ist damit auch entschieden, dass
> abwesende Typ-3/4-Elemente **nichts** in den Bitstrom schreiben.

#### 3.4.6 D-ATTACH/DETACH GROUP IDENTITY (`1010₂`)

Antwort auf eine Gruppen-Report-Anforderung (R-09-18). Feldreihenfolge
[ETSI §16.9.2.1 Tab. 16.1] — **abweichend von der Uplink-PDU steht die
Quittungs-Anforderung vor dem Modus**:

| Bit | Breite | Feld |
|---:|---:|---|
| 0 | 4 | PDU-Typ `1010₂` |
| 4 | 1 | Group identity report |
| 5 | 1 | Group identity acknowledgement request [ETSI §16.10.13] |
| 6 | 1 | Group identity attach/detach mode |
| 7 | 1 | O-Bit |
| 8 | var | M-Bit-Kette: `0100₂` Group report response, `0111₂` Group identity downlink, `1111₂` Proprietary (aufsteigende Kennung, §3.3 Regel 5) |

Verbindliche Feldwerte für die Report-Antwort [ETSI §16.8.4]:

| Feld | Wert | Grund |
|---|---|---|
| Group identity report | `0` | keine erneute Report-Anforderung |
| Group identity attach/detach mode | `1` | „alle abhängen und die genannten anhängen" — ETSI schreibt diesen Wert für die Report-Antwort vor |
| Group identity acknowledgement request | `0` | Stufe 1 fordert keine Quittung an (dann entfällt die U-ATTACH/DETACH GROUP IDENTITY ACK) |
| Group report response | vorhanden, `0` = „Gruppenreport vollständig" | alle Gruppen passen in eine PDU |
| Group identity downlink | die für dieses Endgerät angehängten Gruppen; **entfällt**, wenn keine vorhanden | [ETSI §16.8.4: fehlendes Element + „vollständig" = die Basisstation hat keine Gruppen zu berichten] |

> **Was V1 hier tut und warum es zu ersetzen ist.** V1 erkennt die
> Report-Anforderung (kein Datensatz, Report-Bit gesetzt) und **antwortet
> überhaupt nicht** [CODE sw/tetra_attach_daemon.c:512-517]. Der Kommentar nennt
> das „spec-konform"; das ist es nicht — §16.8.4 verlangt eine Antwort. Der
> messbare Auslöser dieser Entscheidung war jedoch echt: als V1 auf die
> Report-Anforderung mit der **Quittungs-PDU** (`1011₂`) und drei Gruppen aus der
> Konfigurationsdatei antwortete, schloss das Endgerät „ich bin bereits in
> Gruppen" und startete kein echtes Gruppen-Anhängen mehr [MESS 2026-05-04,
> dokumentiert in CODE sw/tetra_attach_daemon.c:495-511]. Beide Fehler stecken
> in derselben Antwort: falscher PDU-Typ **und** eine Gruppenliste, die nicht
> den Anhänge-Zustand der Basisstation wiedergab, sondern die statische
> Konfiguration. V2 antwortet mit `1010₂` und berichtet **den tatsächlich
> geführten Anhänge-Zustand** dieses Endgeräts; ist er leer, ist die Antwort die
> kurze Form ohne Gruppen-Element — funktional dasselbe Ergebnis wie V1s
> Schweigen, aber normkonform und für das Endgerät als Aussage erkennbar.

#### 3.4.7 U-ITSI DETACH (`0001₂`)

Inhalt [ETSI §16.9.3.3 Tab. 16.17]: PDU-Typ (4), O-Bit, P + Address extension
(24, Netzkennung des Endgeräts), M-Bit-Kette mit optionalem Proprietary.

Es gibt **keine** MM-Antwort [ETSI Tab. 16.17: *„Response expected: -/D-MM
STATUS"*, und §16.6.1 zeigt nur `TL-DATA req` → `TL-DATA con`]. Die PDU wird als
BL-DATA gesendet und ist damit auf **LLC-Ebene** zu quittieren: BL-ACK mit
`N(R)` = empfangenes `N(S)` (§3.1.3). Die Referenz-Basisstation quittiert die
Abmeldung **nicht** — auf UL #3 folgt im Suchfenster von ±3,0 s keine
DL-Signalisierungsreaktion, und das Endgerät wiederholt auch nicht: die nächste
U-ITSI DETACH ist UL #7 bei `t = 44,626 s`, also 23,8 s später und nach einer
erneuten Anmeldung (UL #4–#6) [GOLD docs/reference_decode/action_reaction.md,
UL #3; docs/reference_decode/ul_full.md #3 und #7]. Dass DL-BL-ACKs vom Werkzeug
erfasst und angezeigt werden, zeigt dieselbe Aufzeichnung an anderer Stelle
[GOLD docs/reference_decode/dl_full.md:137676 ff., Burst #5883, §3.1.1]. Das
Ausbleiben ist also eine Eigenschaft der Referenzzelle, kein Werkzeugartefakt.
**V2 quittiert dennoch**, weil
[ETSI §22.3.2.3 d)] für eine empfangene BL-DATA eine BL-ACK vorschreibt.

Wirkung in der Basisstation: der Teilnehmer wird als abgemeldet vermerkt, seine
Gruppen-Zuordnungen und sein Verbindungszustand werden freigegeben. Der
Datenbank-Eintrag selbst bleibt bestehen — Abmeldung ist keine Löschung.
Gold-Beleg für das Vorkommen: UL #3 `41 41 7F A4 71 91`, MAC-ACCESS,
LLC BL-DATA `N(S) = 1`, MLE MM, `U-ITSI-DETACH`; keine DL-Signalisierungsreaktion
im Fenster [GOLD docs/reference_decode/ul_full.md #3,
docs/reference_decode/action_reaction.md, UL #3].

### 3.5 Abläufe

#### 3.5.1 Anmeldung (ITSI attach) — fünf Schritte

Air-verifiziert in V1 und bit-exakt in der Gold-Aufzeichnung belegt. Zeitbezüge
und Fristen: `08_TIMING §3.4` (Antwortfenster) und `08_TIMING §3.5`
(Zusammensetzungsfenster). Kanalzuordnung: `06_MAC §3.5`.

| # | Richtung | PDU | Kanal | Zeitbezug | Verhalten bei Ausfall |
|---:|---|---|---|---|---|
| 1 | MS→BS | MAC-ACCESS, Fragmentierungsflag = 1, LLC BL-DATA `N(S)`, MLE MM, erstes Fragment der U-LOCATION UPDATE DEMAND | SCH/HU, ein Unterschlitz | UL-Frame N | keine Reaktion; das Endgerät wiederholt über seinen Zugriffsmechanismus (`06 §3.9`) |
| 2 | BS→MS | MAC-RESOURCE, adressiert, **ohne TM-SDU**, Zuweisungsflag = 1, Zuweisungselement `0x00` — die Zusage des Unterschlitzes für Fragment 2 | SCH/HD, DL-Frame N+1 | fest im Zeitraster: von der Software **codiert** und vorab ins Grant-Magazin gelegt, von der PL ausgewählt, platziert und wiederholt (`06 §3.9.3`, R-00-01/R-00-02, R-06-10 — die PL codiert nicht und parst nicht). Bei erstmals gesehener Adresse wartet der Block bis zu `GRANT_ARM_TIMEOUT` Slots auf den Eintrag (`06` O-06-1) | ohne Zusage sendet das Endgerät Fragment 2 nicht; Fragment 1 verfällt nach dem Zusammensetzungsfenster (`08 §3.5`), Zähler `mm_reass_timeout` |
| 3 | MS→BS | MAC-END-HU, zweites Fragment (85 bit) | SCH/HU, im zugesagten Unterschlitz | UL-Frame N+1 | Fragment 1 verfällt nach Ablauf des Fensters; das Endgerät beginnt neu bei Schritt 1 |
| 4 | BS→MS | **Anmeldebestätigung** D-LOCATION UPDATE ACCEPT (§3.4.2), LLC BL-ADATA mit `N(R)` = `N(S)` aus Schritt 1 und eigenem `N(S)` = `V(S)` | SCH/F, DL-Frame N+2 | Software; Budget ein Frame (`08 §3.4.3` R-5) | ohne Bestätigung läuft `T351` (10 s) beim Endgerät ab [ETSI §16.11.1.1] und es beginnt neu bei Schritt 1 |
| 5 | MS→BS | LLC BL-ACK mit `N(R)` = `N(S)` aus Schritt 4 — reine Schicht-2-Quittung, kein MM-Inhalt | SCH/HU im über das Zuweisungselement zugesagten Unterschlitz | UL-Frame N+3 | keine BS-Reaktion nötig; bleibt sie aus, wiederholt die Basisstation die Bestätigung **nicht** (die Wiederholung ist MS-Sache, §3.1.7) |

**Gold-Beleg für die Schritte 1, 3 und 5** [GOLD docs/reference_decode/ul_full.md
#0/#1/#2]: `01 41 7F A7 01 12` (MAC-ACCESS, BL-DATA `N(S)=0`, MM,
U-LOC-UPD-DEMAND, ITSI-Attach) — `D4 1C 3C 02 40 50` (MAC-END-HU, im
zusammengesetzten Body die GSSI `0x2F4D63`) — `41 41 7F A4 63 C0` (MAC-ACCESS,
LLC BL-ACK `N(R)=1`). Der Decoder weist bei UL #2 einen MLE-Diskriminator aus;
das ist ein Anzeigefehler des Werkzeugs, denn eine BL-ACK ohne Nutzdaten enthält
keinen Diskriminator (§3.1.2).

**Dasselbe Muster in der eigenen Zelle** [docs/local_cell_decode/ul_full.md
#0/#1/#2]: `01 41 7C 8F 01 12` / `D4 1C 3C 02 40 50` / `41 41 7C 8C 63 40` mit
`N(R) = 0` in der MS-Quittung — passend zum `N(S) = 0` der eigenen Bestätigung.
Der Ablauf ist also in beiden Netzen strukturidentisch; die Abweichungen liegen
in zwei Feldwerten (§3.7).

**Zusätzliche LLC-Quittung nach Schritt 3 — nicht senden.** V1 erzeugt nach
abgeschlossener Zusammensetzung eine eigene BL-ACK-PDU [CODE
rtl/lmac/tetra_pre_reply_blck.v:6-21]. In der Gold-Aufzeichnung existiert diese
PDU nicht; der Frame zwischen Zusage und Bestätigung trägt dort einen Füller.
Die Quittung reist im `N(R)`-Feld der Bestätigung mit. Verbindliche Fassung
dieser Regel: `08_TIMING §3.4.3` R-3.

#### 3.5.2 Gruppen-Anhängen und Gruppenwechsel

| # | Richtung | PDU | Kanal |
|---:|---|---|---|
| 1 | MS→BS | MAC-ACCESS, Fragmentierungsflag = 1, LLC BL-DATA, MLE MM, erstes Fragment der U-ATTACH/DETACH GROUP IDENTITY (§3.4.4) | SCH/HU |
| 2 | BS→MS | Unterschlitz-Zusage wie Schritt 2 in §3.5.1 | SCH/HD |
| 3 | MS→BS | MAC-END-HU, zweites Fragment | SCH/HU |
| 4 | BS→MS | D-ATTACH/DETACH GROUP IDENTITY ACK (§3.4.5), LLC BL-ADATA | SCH/F |
| 5 | MS→BS | LLC BL-ACK | SCH/HU |

Ablauf und Fristen sind identisch zur Anmeldung; beim Endgerät läuft `T353`
(10 s) statt `T351` [ETSI §16.11.1.3]. Ein **Gruppenwechsel** ist derselbe
Ablauf mit zwei Datensätzen in Schritt 1: Abhängen der alten und Anhängen der
neuen Gruppe — bzw. mit `Group identity attach/detach mode = 1`, das alle
bisherigen Zuordnungen verwirft. Gold zeigt drei solche Vorgänge, jeder mit
Quittung [GOLD UL #11-13, #14-18, #19-21 → DL #4811, #5343, #5655].

**Verarbeitung in der Basisstation, verbindliche Reihenfolge:**

1. Wanderer nach §3.4.4; bei Strukturfehler verwerfen und zählen (R-09-15).
2. `Group identity attach/detach mode = 1` → alle geführten Zuordnungen dieses
   Teilnehmers verwerfen, bevor die Datensätze verarbeitet werden.
3. Je Datensatz: Abhängen → Zuordnung entfernen, kein Quittungs-Datensatz.
   Anhängen → Gruppe in der Datenbank nachschlagen; Treffer oder erfolgreiche
   automatische Eintragung (§3.6) → Zuordnung anlegen und Quittungs-Datensatz
   mit `GIADTI = 0`, Lifetime und Class of usage aus dem Profil (Class of usage
   aus der Anforderung, wenn das Profil keinen Wert vorgibt). Kein Treffer und
   keine automatische Eintragung → Quittungs-Datensatz mit `GIADTI = 1` und
   Grund `00₂` (unbekannte Gruppenkennung).
4. Quittung senden — **immer** (R-09-17), auch mit null Datensätzen
   (7-bit-Body, `O = 0`, §3.4.5).
5. Nach erfolgreichem Anhängen prüfen, ob auf einer der neu angehängten Gruppen
   ein Ruf läuft; wenn ja, den nachträglichen Rufeintritt auslösen
   (`10_CMCE_CALL`).

Schritt 4 ist die Auflösung eines V1-Defekts: dort wird die Anforderung
stillschweigend verworfen, wenn keine Gruppe passt [CODE
sw/tetra_attach_daemon.c:519-527]. Das Endgerät wartet dann `T353` ab und
wiederholt — die Ursache ist für den Betreiber nicht sichtbar. Schritt 3
(Abhängen) ist die Auflösung des zweiten: V1 filtert Abhänge-Datensätze **vor**
der Verarbeitung heraus [CODE sw/tetra_attach_daemon.c:466-471], damit die
Quittung nur einen Datensatz enthält. Das Ergebnis auf der Luft ist richtig
(Gold #4811 hat einen Datensatz), der Weg dorthin aber nicht: die Basisstation
verarbeitet das Abhängen gar nicht und führt danach eine Zuordnung, die das
Endgerät bereits gelöst hat.

#### 3.5.3 Gruppen-Report-Anforderung

Erkennung: `Group identity report = 1` **und** kein Group-identity-uplink-Element
[ETSI §16.8.4]. Antwort: `D-ATTACH/DETACH GROUP IDENTITY` nach §3.4.6, ein
Frame nach der Anforderung, LLC BL-ADATA. Bei
`Group identity acknowledgement request = 0` endet der Ablauf hier.

#### 3.5.4 Abmeldung

`U-ITSI DETACH` (§3.4.7) → BL-ACK. Kein MM-Ausgang. Der Teilnehmer gilt danach
als abgemeldet; eine erneute Anmeldung läuft vollständig nach §3.5.1, mit
`V(S) = 0` und `vr_valid = 0` auf der neu angelegten Verbindung.

### 3.6 Teilnehmer-Richtlinie

Die Datenbank führt zwei Arten von Einträgen — Teilnehmeradressen (ISSI) und
Gruppenadressen (GSSI) — mit je einem Profilverweis. Aufbau, Persistenz und
Bedienoberfläche: `13_SW_ARCHITECTURE`. Für dieses Kapitel zählen die
Richtlinienentscheidungen:

| Richtlinie | Werte | Wirkung bei unbekannter Adresse |
|---|---|---|
| `accept_unknown_issi` | 0 / 1 | 0 → Anmeldung ablehnen mit Grund `00110₂` (§3.4.3), Zähler `mm_issi_reject`. 1 → Eintrag mit dem Standardprofil anlegen, Zähler `mm_issi_autoenroll`, Anmeldung bestätigen |
| `accept_unknown_gssi` | 0 / 1 | 0 → Anhänge-Datensatz mit `GIADTI = 1`, Grund `00₂` ablehnen, Zähler `mm_gssi_reject`. 1 → Gruppe anlegen, Zähler `mm_gssi_autoenroll`, Datensatz annehmen |

**Die Richtlinie ist Konfiguration, kein Register.** V1 liest sie über
`REG_DB_POLICY` aus dem PL [CODE sw/tetra_hal.h:302-308,
sw/tetra_attach_daemon.c:451, :619-621], obwohl kein RTL-Modul sie auswertet:
ein reiner Software-Wert, der über einen AXI-Umweg gelesen wird und damit im PL
Fläche belegt und in `07` einen Platz beansprucht, den er nicht braucht. In V2
steht die Richtlinie in der Konfigurationsdatei und wird zur Laufzeit neu
gelesen, wenn die Datei sich ändert (`13`).

**Profilinhalt, soweit dieses Kapitel ihn braucht:** Gruppen-Lifetime (2 bit),
Class of usage (3 bit), Standardgruppe (24 bit, optional), Erlaubnisbits für
Anmeldung / Sprache / Daten. V1 kodiert dasselbe in einem 32-bit-Wort mit einem
festen Vorgabewert `0x0000_088F` = Lifetime 1, Class of usage 4, alle
Erlaubnisse [CODE sw/tetra_db.c:34, sw/tetra_db.h:33-40]. Diese Feldbelegung
wird übernommen (die Werte sind gegen [GOLD #783] verifiziert: Lifetime `01₂`,
Class of usage `100₂`), das **Bitmuster als Zahl** dagegen nicht: in V2 ist das
Profil eine Struktur mit benannten Feldern in der Konfiguration.

**Auslieferungszustand (R-09-13):** keine Teilnehmer- und keine Gruppeneinträge.
V1 liefert eine Datei mit zwei fest eingetragenen Adressen aus — der ISSI eines
konkreten Testgeräts und einer Gruppenadresse aus der Entwicklung
[CODE sw/db.tsv.default]. Ein solcher Auslieferungszustand macht die
Zellkonfiguration von einem Testgerät abhängig.

### 3.7 Ein belegter Fehler und eine belegte Fehlzuordnung

Beide Bitunterschiede sind bit-genau in
`docs/local_cell_decode/DIFF_vs_reference.md:128-194` nachgewiesen. Nur der
**erste** ist ein Fehler des eigenen Systems und wird über R-09-11 abgestellt.
Der **zweite** ist keine Abweichung im Verhalten der Basisstation, sondern ein
korrektes Echo eines abweichend programmierten Testgeräts — der Defekt liegt
daneben, in der Rückfall-Konstante und im Auslieferungszustand (R-09-12,
R-09-13).

**Der Fehler — der quittierte Anmeldetyp.** Beide Endgeräte fordern
bit-identisch `location update type = 011₂` (ITSI attach). Die
Referenz-Basisstation quittiert `location update accept type = 011₂`, die eigene
Zelle quittiert `000₂` (Aufenthaltsaktualisierung)
[GOLD docs/reference_decode/dl_full.md:18358, Burst #783, Bitpositionen 64…66 =
`011`; eigene Zelle docs/local_cell_decode/dl_full.md:20436, `info_hex` =
`0x20a9282f9140001511000150746e098130000001200000…`, dieselben Bitpositionen =
`000`]. **Normativ:** der quittierte Typ wird aus der Anforderung übernommen
[ETSI §16.10.35a: *„The location update accept type information element shall
indicate the type of registration in the D-LOCATION UPDATE ACCEPT PDU"* — die
Registrierungsart ist die vom Endgerät angeforderte: nach §16.4.2 b) („new
ITSI") gilt *„The location update type information element in the PDU shall be
set to ‚ITSI attach'"*, und §16.9.2.7 nennt die Bestätigung ausdrücklich
*„Response to: U-LOCATION UPDATE DEMAND"*].

**Wirkort in V1 — nicht dort, wo die Analyse ihn vermutet.** Die Analyse
benennt Rust-Dateien einer fremden Referenz-Implementierung als Fehlerort
[DIFF_vs_reference.md:182, :237]; unsere Basisstation ist in C und Verilog
geschrieben. Der Wert läuft in V1 über vier Stellen:
Wanderer-Ausgabe `location_update_type` [CODE
sw/tetra_mm_demand_parser.c:50] → `meta.loc_acc_type` [CODE
sw/tetra_attach_daemon.c:582-585, Aufruf :685] → Mailbox-Wort `W3[4:2]`
[CODE sw/tetra_tx_transport.c:107-111] → `mb_loc_acc_type` [CODE
rtl/lmac/tetra_reply_mailbox.v:167-169] → Bitfeld `[123:121]` des Encoders
[CODE rtl/lmac/tetra_d_location_update_encoder.v:56-57, :181]. Vor der Korrektur
war der Encoder-Eingang **fest auf `000₂`** verdrahtet [CODE
rtl/lmac/tetra_mle_registration_fsm.v:117-120, Kommentar]. Die Korrektur ist in
V1 wirksam [MESS 2026-05-15, `location_update_accept_type=3` in der neuen
Aufnahme, dokumentiert in docs/local_cell_decode/BUGS_LIST.md, BUG-001]. In V2
verschwindet die Kette: der Wert wandert innerhalb **eines** Moduls von der
Wanderer-Struktur in den Erzeuger.

**Die Fehlzuordnung — die zugewiesene Gruppenadresse.** Die eigene Zelle weist
`GSSI = 0x000001` zu, die Referenz `0x2F4D63` [GOLD #783,
docs/reference_decode/dl_full.md:18355, Bitpositionen 136…159; eigene Zelle
dieselbe Position = `0x000001`]. Dieser Unterschied ist **kein Defekt**: das
Testgerät ist absichtlich mit `GSSI = 1` programmiert und hat genau diesen Wert
angefordert, das Echo der Basisstation ist korrekt
[docs/local_cell_decode/BUGS_LIST.md:64-66, BUG-002 „NICHT-BUG, by design",
bestätigt 2026-05-15]. Nach `CONVENTIONS.md §3`, letzte Regel, ist die GSSI
ausdrücklich ein zulässig abweichendes Feld. R-09-12 Punkt 1 erzeugt für dieses
Gerät folgerichtig wieder `GSSI = 1`.

**Der Defekt daneben** ist die Herkunft des Wertes, wenn die Datenbank keinen
Treffer hat: eine fest eingetragene fremde Gruppenadresse `0x2F4D61` als
Rückfall [CODE sw/tetra_attach_daemon.c:81 `M2_FALLBACK_GILA_GSSI`, benutzt in
:657] zusammen mit demselben Wert als Gruppeneintrag im Auslieferungszustand
[CODE sw/db.tsv.default:12 `1 3100001 1 0` = `0x2F4D61`]. **Normativ
(R-09-12):**

1. Die Basisstation nimmt die im *Group identity location demand* der
   Anforderung gewünschte Gruppenadresse, **wenn** sie in der Konfiguration
   steht oder die Richtlinie `accept_unknown_gssi` ihre Aufnahme erlaubt.
2. Sonst die Standardgruppe des Teilnehmerprofils aus der Konfiguration.
3. Sonst **kein Gruppen-Element**: das M-Bit auf Bitposition 27 wird `0` und ist
   damit das abschließende M-Bit; der MM-Body ist 28 bit lang (§3.4.2).
4. Ein im Programmcode eingetragener Vorgabewert ist unzulässig, ebenso ein
   Gruppeneintrag im Auslieferungszustand (R-09-13).

**Wirkort in V1:** die Herkunftskette ist bereits richtig — der Wunsch des
Endgeräts wird aus dem Wanderer übernommen und in der Datenbank geprüft [CODE
sw/tetra_attach_daemon.c:616-617, :658-676]; der aufgezeichnete Wert `1` ist
genau dieser Weg und damit korrekt. Zu beheben sind nur die beiden Stellen
daneben: die Rückfall-Konstante, weil sie eine fremde Gruppenadresse in unser
System einträgt, sobald die Datenbank keinen Treffer hat, und der
Auslieferungszustand nach R-09-13.

**Was ausdrücklich keine Abweichung ist.** Unterschiede in Landeskennung,
Netzkennung, Farbcode, Aufenthaltsbereich, Trägernummer, Verschleierungs-Startwert
und Teilnehmeradressen zwischen Referenz und eigener Zelle sind erwartete
zellspezifische Werte [DIFF_vs_reference.md:5-19] und kein Defekt — siehe
`CONVENTIONS.md §3`, letzte Regel. Ebenso ist der Rufkennungs-Zähler
zellspezifisch.

### 3.8 Zähler (P6, R-09-22)

Alle Zähler sind sättigende 16-bit-Werte in der Software und über die
Diagnoseschnittstelle (`13`) lesbar. Sie liegen **nicht** in der PL-Registerbank
— diese Schichten sind Software.

| Zähler | Inkrement |
|---|---|
| `llc_rx_ok`, `llc_tx_ok` | erfolgreich geparste / gebaute LLC-PDU |
| `llc_unsupported_type` | LLC-Typ ≥ `1000₂` |
| `llc_short_pdu` | TM-SDU kürzer als Kopf (+ FCS) |
| `llc_fcs_err` | FCS-Prüfung fehlgeschlagen |
| `llc_ack_mismatch` | BL-ACK mit `N(R) ≠ V(S)` |
| `llc_ack_superseded` | ausstehende Quittung durch neue TL-SDU ersetzt |
| `llc_ack_split` | Quittung musste getrennt gesendet werden |
| `llc_link_evict` | Verbindungsplatz verdrängt |
| `mle_pd_unsupported` | Diskriminator in Stufe 1 nicht bedient |
| `mm_parse_err` | Strukturfehler im Wanderer |
| `mm_reass_timeout` | Fragment 1 ohne Fragment 2 verfallen (Wert kommt aus `06 §3.11`) |
| `mm_lu_accept`, `mm_lu_reject` | gesendete Anmeldebestätigungen / -ablehnungen |
| `mm_grp_ack_accept`, `mm_grp_ack_reject` | Gruppen-Quittungen mit / ohne abgelehnte Datensätze |
| `mm_grp_report` | gesendete Report-Antworten |
| `energy_saving_req_cnt` | Anmeldeanforderung mit einem Energiespar-Modus ungleich „dauerhaft empfangsbereit". Stufe 1 bedient den Rufsucher-Betrieb nicht und antwortet unverändert (§3.4.1); der Zähler ist der **Bedarfsnachweis** nach `18` R-18-13 für den Rufsucher-Betrieb (`18 §3.1.1`). Sollwert im Testfeld: 0 — jeder Wert > 0 bedeutet, dass ein reales Endgerät die Funktion anfragt |
| `mm_detach` | verarbeitete Abmeldungen |
| `mm_issi_autoenroll`, `mm_issi_reject` | Richtlinienentscheidungen Teilnehmer |
| `mm_gssi_autoenroll`, `mm_gssi_reject` | Richtlinienentscheidungen Gruppe |

### 3.9 Ressourcen-Erwartung

| Größe | Erwartung | Herkunft |
|---|---|---|
| Programmcode `tetra_llc` + `tetra_mle` + `tetra_mm_ie` + `tetra_mm` | 2 000…2 500 Zeilen C | [ANNAHME: V1 hat für den Teilumfang ohne FCS, ohne Ablehnung und ohne Report-Antwort 393 + 102 Zeilen in den beiden reinen Protokollmodulen [CODE sw/tetra_mm_demand_parser.c, sw/tetra_grpack_body.c] plus verstreute Anteile im Daemon] |
| Verbindungstabelle | 64 × 12 byte = 768 byte | §2.3 |
| Teilnehmer-Datenbank | 256 Einträge × 8 byte = 2 kbyte | [CODE sw/tetra_db.h:29] |
| Rechenzeit FCS | 32-bit-CRC über ≤ 400 bit, tabellengetrieben ≤ 2 µs auf dem ARM-Kern | [ANNAHME: Byteweise Tabelle, 50 Byte je PDU] |
| Rechenzeit Wanderer | ≤ 20 µs je PDU | [ANNAHME: 147 Bit-Zugriffe, kein Speicherzugriff außerhalb des Puffers] |
| Fläche im PL | **0** | R-09-01 |

Die einzige harte Frist dieser Schichten ist das Antwortfenster von einem Frame
(`08_TIMING §3.4.3` R-5, ≈ 56,7 ms). Die Verarbeitung liegt drei
Größenordnungen darunter; sie darf die Hauptschleife trotzdem nicht blockieren
(`08_TIMING §3.4.3`, R-5, erste Regel).

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Bei Abweichung |
|---|---|---|---|
| `N(R)` der Antwort | = empfangenes `N(S)` | [ETSI §22.3.2.3] + [GOLD] 6/6 Fälle (§3.1.3) | Endgerät hält seine TL-SDU für unquittiert, wiederholt bis `N.252`; bei Anmeldung Endlosschleife |
| `N(S)` der Antwort | `V(S)`, umschaltend je gesendeter BL-DATA/BL-ADATA | [GOLD] Folge `1,0,1,0,1,0` über sechs PDUs zweier Typen | Endgerät kann Wiederholung nicht von neuer Nachricht unterscheiden |
| Startwert `V(S)` | 0 | [ETSI §22.3.2.1] | — |
| MM-Body Anmeldebestätigung mit Gruppen-Element | 102 bit | [GOLD #783, dl_full.md:18355, Bitpositionen 60…161] | Längenangabe stimmt nicht, Endgerät verwirft |
| MM-Body Anmeldebestätigung ohne Gruppen-Element | **28 bit** | [ETSI §16.9.2.7 Tab. 16.11 + Anhang E] (§3.4.2); V1 deklariert 36 und baut 29 [CODE rtl/lmac/tetra_d_location_update_encoder.v:197-213] — beides falsch | Längenangabe stimmt nicht, Endgerät verwirft |
| MM-Body Gruppen-Quittung, 1 Datensatz | **62 bit** | [GOLD #4811] + [CODE sw/tetra_grpack_body.c:101] | 64 bit (V1-Doku) verschiebt die Elementkennung um 2 bit → Endgerät liest Kennung `1110₂` |
| Längenangabe Anmeldebestätigung | 21 Oktette | [GOLD #783] | — |
| Längenangabe Gruppen-Quittung | 16 Oktette | [GOLD #4811] | — |
| Längenangabe Unterschlitz-Zusage | 7 Oktette, **ohne** TM-SDU | [GOLD #775], §3.1.1 | — |
| Längenangabe BL-ACK ohne Nutzdaten | 6 Oktette (43 + 5 bit) | [GOLD dl_full.md:137676, Burst #5883] + [CODE rtl/lmac/tetra_mac_resource_bl_ack_builder.v:31] | — |
| Gruppen-Lifetime im Gruppen-Element | `01₂` = „Attachment for next ITSI attach required" | [GOLD #783, #4811] | Endgerät hängt die Gruppe beim nächsten Anmelden nicht wieder an |
| Class of usage im Gruppen-Element | `100₂` = 4 | [GOLD #783, #4811] | Vorrang der Gruppe im Ruf ändert sich |
| Energy saving information | 14 bit `0` (Stay Alive) | [GOLD #783] + [ETSI §16.10.10 NOTE 1/2] | Endgerät geht in einen Sparmodus und ist nicht erreichbar |
| AACH-Infowort des Bestätigungs-Slots | `0x0009` | [GOLD #783, #4811] | Endgerät sendet seine Quittung nicht im zugesagten Unterschlitz |
| `T351` Anmeldeantwort (MS-seitig) | 10 s | [ETSI §16.11.1.1] | — |
| `T353` Gruppenantwort (MS-seitig) | 10 s | [ETSI §16.11.1.3] | — |
| `T.251` Wiederholzeitgeber (MS-seitig) | 4 Signalisierungsframes ≈ 227 ms | [ETSI Anhang A.1] | Untergrenze für unsere Antwortlatenz |
| `N351` Höchstzahl System-Ablehnungen | 4 (Vorgabe) | [ETSI §16.11.2.1] | Grund für R-09-19 |
| `N.251` maximale TL-SDU im Basic Link | 2 595 bit | [ETSI Anhang A.2] | — |

---

## 5. Verifikation

### 5.1 Unit-Tests (selbstprüfend, Pflicht)

| Test | Prüft | Erfolgskriterium |
|---|---|---|
| `test_llc_hdr` | §3.1.5 über alle 16 Codepunkte | Basic-Link-Längen 6/5/4/5 unabhängig vom FCS-Bit; `≥ 1000₂` → −1. Pflicht-Regressionsvektoren gegen die V1-Fehler (§3.1.4): `0011₂` → **5** (V1: 4), `0111₂` → 5, `0100₂` → 6 (V1: 5), `0110₂` → 4 (V1: 5) |
| `test_llc_roundtrip` | Bauen und Parsen für alle vier Typen, mit und ohne FCS | Bit-Identität; `N(R)`/`N(S)` an den Positionen aus §3.1.2 |
| `test_llc_fcs` | Anhang C, Längen 8, 24, 31, 32, 33, 320 bit | Referenzwerte; die Kurzlängen unterscheiden sich nachweisbar von einer Standard-CRC-32-Implementierung |
| `test_llc_seq` | R-09-03, R-09-04 an der Gold-Folge aus §3.1.3 | alle sechs `N(R)`/`N(S)`-Paare, inklusive der Wiederholung mit gleichem `N(S)` |
| `test_mm_ie` | Annex-E-Mechanik: O/P/M-Bits, unbekanntes Typ-3-Element mittendrin | Folgefelder korrekt; kein Fehler |
| `test_mm_walk_lu_demand` | §3.4.1 gegen die zusammengesetzten Gold-Bodies von UL #0+#1 | `location_update_type = 3`, `GSSI = 0x2F4D63`, Class of usage 4 |
| `test_mm_walk_grp` | §3.4.4 gegen UL #11+#12, #14+#15, #19+#20 | Datensatzzahl und -inhalte je Vorgang |
| `test_mm_build_lu_accept` | §3.4.2 | 102-bit- und **28-bit**-Form (letztere mit genau **einem** M-Bit `0` als letztem Bit); die 102-bit-Form bit-identisch zu [GOLD #783] außer Zell-/MS-Feldern |
| `test_mm_build_grp_ack` | §3.4.5 | 62/94/126/**7** bit; 1-Datensatz-Form bit-identisch zu [GOLD #4811] außer GSSI; zusätzlich ein **29-bit-Ablehnungs-Datensatz** (`GIADTI = 1`, Grund `00₂`) → Body 59 bit, Gesamtlänge 35, Wiederholungszahl 1 |
| `test_mm_build_lu_reject` | §3.4.3 | 14 bit; Cause-Zuordnung nach §3.4.3 |
| `test_mm_build_grp_report` | §3.4.6 | Kurzform ohne Gruppen-Element; „Report vollständig" gesetzt |
| `test_mm_fuzz` | R-09-15 | 10⁵ Zufallsbodies: kein Zugriff außerhalb des Puffers (unter Adress-Sanitizer), keine DL-PDU bei `parse_err` |
| `test_mm_policy` | §3.6, alle vier Richtlinienkombinationen | erwartete PDU und erwarteter Zählerstand |

### 5.2 Konfigurations-Kohärenz (Abnahmekriterium aus `07 §3.1.3`)

Ein Integrationstest liest nach dem Hochlauf `REG_CELL_CFG_1` und
`REG_CELL_CFG_2` zurück und vergleicht Landeskennung, Netzkennung, Farbcode und
Aufenthaltsbereich mit den Werten, die der MM-Erzeuger in seine PDUs schreibt
(R-09-20). Abweichung = Fehlschlag. V1 hat hier zwei Quellen: das Register
`REG_CELL_LA` [CODE sw/tetra_hal.h:49] wird zur Laufzeit gelesen, um den
Aufenthaltsbereich in die Anmeldebestätigung zu schreiben [CODE
sw/tetra_attach_daemon.c:614] — obwohl derselbe Wert aus der Konfiguration
stammt, aus der die Software das Register beschrieben hat.

### 5.3 Gold-Vergleich (strukturell, nicht bit-identisch)

Nach `CONVENTIONS.md §3` dürfen zell- und gerätespezifische Felder abweichen.
Verglichen wird gegen `docs/reference_decode/`:

| Prüfung | Erwartung |
|---|---|
| Anmeldebestätigung, alle Strukturfelder | identisch zu #783: PDU-Typ, O-/P-/M-Bit-Folge, Energy saving information, Elementkennung 5, Länge 58, Gruppen-Element-Aufbau, beide Abschluss-M-Bits |
| Anmeldebestätigung, `location update accept type` | gleich dem `location update type` der eigenen Anforderung — **das ist die Prüfung von R-09-11** |
| Gruppen-Quittung, alle Strukturfelder | identisch zu #4811, Body-Länge 62 bit, Wiederholungszahl 1 |
| LLC-Kopf beider PDUs | BL-ADATA, `N(R)` = empfangenes `N(S)`, `N(S)` alternierend |
| Zulässig abweichend | SSI, GSSI, Landes-/Netzkennung, Farbcode, Aufenthaltsbereich, Trägernummer, Verschleierungs-Startwert |
| Nicht vorhanden sein darf | eine eigene BL-ACK-PDU zwischen Fragment 2 und Bestätigung (§3.5.1) |

### 5.4 Luft-Abnahme

Mindestens **drei** Durchläufe je Punkt, mit einem kommerziellen Endgerät:

1. **Erstanmeldung.** Endgerät aus- und einschalten. Erwartet: die fünf Schritte
   aus §3.5.1 in der Aufzeichnung, Bestätigung mit `location update accept type`
   = `011₂`, MS-Quittung mit passendem `N(R)`, danach keine Wiederholung der
   Anforderung. Zähler `mm_lu_accept` +1, `mm_reass_timeout` unverändert.
2. **Zweite Aufenthaltsaktualisierung derselben Verbindung.** Erwartet:
   `N(S)` der zweiten Bestätigung ist gegenüber der ersten umgeschaltet
   (R-09-04) — der Fall, den V1 nicht abdeckt.
3. **Anmeldung mit anderem Anforderungstyp.** Endgerät zu einer
   Aufenthaltsaktualisierung veranlassen (Zellwechsel oder periodisch).
   Erwartet: quittierter Typ gleich dem angeforderten, **nicht** `011₂`.
4. **Gruppenwechsel.** Gruppe am Endgerät umschalten. Erwartet: Quittung mit
   einem Anhänge-Datensatz auf die neue Gruppe, `mm_grp_ack_accept` +1, danach
   ein Ruf auf der neuen Gruppe erfolgreich.
5. **Unbekannte Gruppe mit `accept_unknown_gssi = 0`.** Erwartet: Quittung mit
   `GIADTI = 1` und Grund `00₂`, `mm_gssi_reject` +1, Endgerät wiederholt nicht
   endlos (R-09-17).
6. **Unbekannter Teilnehmer mit `accept_unknown_issi = 0`.** Fünf
   Anmeldeversuche. Erwartet: fünf Ablehnungen mit Grund `00110₂`, das Endgerät
   versucht auch nach dem vierten weiter (R-09-19).
7. **Auslieferungszustand.** Leere Konfiguration, `accept_unknown_issi = 1`,
   `accept_unknown_gssi = 0`. Erwartet: Bestätigung mit **28-bit**-MM-Body ohne
   Gruppen-Element, Längenangabe **11** Oktette und Füllbit-Anzeige **0**
   (51 + 6 + 3 + 28 = 88 bit, oktett-ausgerichtet — der Fall, in dem nach
   `06 §3.7` F4 **keine** Füllbits, sondern unmittelbar die Null-PDU folgt),
   Endgerät bleibt angemeldet (R-09-12 Punkt 3).
8. **Abmeldung.** Endgerät abmelden. Erwartet: BL-ACK mit passendem `N(R)`,
   keine MM-Antwort, `mm_detach` +1.

---

## 6. Offene Punkte

1. **O-09-1 — Zeitpunkt des `V(S)`-Umschaltens bei ausbleibender Quittung.** ETSI
   schaltet `V(S)` erst um, wenn die Gegenstelle quittiert hat oder der Versuch
   endgültig gescheitert ist [ETSI §22.3.2.3 g), h), i), j)]. Unsere MAC-Schicht liefert keine
   Übertragungsbestätigung je PDU. **Empfehlung:** `V(S)` mit dem Einstellen in
   die DL-PDU-Mailbox umschalten und eine Wiederholung derselben TL-SDU
   ausdrücklich mit dem alten `N(S)` erzeugen (das Antwortverhalten der
   Wiederholungen liegt ohnehin in der jeweiligen Ablaufsteuerung). Zu prüfen
   an Punkt 2 der Luft-Abnahme.
2. **O-09-2 — Sinnvolle Größe der Verbindungstabelle.** 64 Plätze sind übernommen, nicht
   gemessen. **Empfehlung:** `llc_link_evict` im Betrieb beobachten; solange er
   0 bleibt, ist die Größe ausreichend.
3. **O-09-3 — Obergrenze der Gruppen-Datensätze je Anforderung.** `TETRA_MM_GID_MAX = 8`
   ist Reserve, nicht gemessen und **nicht** aus der Blockkapazität abgeleitet:
   eine unfragmentierte Uplink-TM-SDU von 147 bit trägt höchstens 3 Datensätze
   (§3.4.1). Bei mehr Datensätzen müsste die Anforderung über mehr als zwei
   Fragmente kommen und die Quittung fragmentiert werden
   (`11_SDS §Fragmentierung`).
   **Empfehlung:** überzählige Datensätze mit Grund `01₂` (temporär) ablehnen
   und zählen; Fragmentierung der Quittung erst, wenn der Zähler anspricht.
4. **O-09-4 — Gruppen-Report-Antwort ist nicht air-verifiziert.** §3.4.6 ist vollständig
   aus [ETSI §16.8.4] und Tabelle 16.1 abgeleitet; in der Gold-Aufzeichnung
   kommt keine Report-Anforderung vor, und V1 hat nie eine korrekte Antwort
   gesendet. **Empfehlung:** früh im Air-Test-Programm mitführen, weil das
   Endgerät die Anforderung nach jedem Netzwechsel stellen kann.
5. **O-09-5 — FCS wird in Stufe 1 nur empfangsseitig gebraucht.** Kein beobachtetes
   Endgerät sendet mit FCS, und die Basisstation braucht sie für kurze
   Signalisierung nicht. **Empfehlung:** Erzeugung dennoch implementieren und
   testen (der Testvektorsatz ist ohnehin nötig, R-09-06), aber im Betrieb
   ausgeschaltet lassen, bis ein Endgerät sie verlangt.
6. **O-09-6 — ASSI-Vergabe entfällt in Stufe 1.** Die Anmeldebestätigung sendet kein
   SSI-Element (P-Bit auf Bitposition 8 = `0`, wie [GOLD #783]). Damit
   arbeitet das System durchgehend mit der ISSI. **Empfehlung:** so
   beibehalten; eine Adressvergabe zieht `D-LOCATION UPDATE PROCEEDING`
   [ETSI §16.9.2.10] und die Adressverwaltung nach sich — `18_ROADMAP`.
7. **O-09-7 — Verschlüsselung.** Alle Felder mit Sicherheitsbezug bleiben leer:
   `cipher control` = 0 in der Ablehnung, kein Security-downlink-Element, kein
   Authentication-downlink-Element. Die Anforderung des Endgeräts kann diese
   Felder enthalten; der Wanderer überspringt sie über ihre Länge (R-09-14).
   **Empfehlung:** so belassen und in `18_ROADMAP` führen.
