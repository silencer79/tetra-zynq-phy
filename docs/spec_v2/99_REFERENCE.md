# 99 — Verzeichnisse (Index, keine Definitionen)

**Scope:** Zwei Verzeichnisse zum Nachschlagen: die im Satz benutzten
ETSI-Fundstellen mit Thema und nutzenden Kapiteln, und die Kennungen der
Kapitel in Zahlen.

**Was dieser Anhang NICHT ist — und nicht werden darf.** Er ist **kein**
Nachschlagewerk für Werte. Konstanten, Bit-Layouts, Schwellwerte, Registeradressen
und Gold-Messwerte stehen ausschließlich in dem Fachkapitel, das sie normativ
festlegt (`CONVENTIONS.md` §2, Prinzip P2 — eine Wahrheit, ein Ort). Eine
handgepflegte zweite Sammlung derselben Werte würde driften und wäre genau der
Defekt, gegen den dieser Dokumentensatz geschrieben ist.

Was hier steht, sind deshalb ausschließlich **Metadaten über den Satz**: welche
Norm-Fundstelle wo benutzt wird, und wie viele Kennungen ein Kapitel führt. Beides
normiert nichts und kann inhaltlich nicht widersprechen.

**Erzeugung.** Beide Verzeichnisse sind aus den Kapiteln erhoben und bei jeder
Änderung neu zu erheben — die Zählungen mit `grep -ohE "\bR-[0-9]{2}-[0-9]+"` und
Entsprechendem für `V-` und `O-`. Ein von Hand fortgeschriebener Index ist ein
Spec-Fehler.

---

## 1. ETSI-Fundstellenverzeichnis

Alle Fundstellen aus EN 300 392-2 v3.8.1 (`en_30039202v030801p.pdf`), die im Satz benutzt
werden, mit Thema und nutzenden Kapiteln. Erhoben per `grep` über alle
`ETSI`-Marker in `docs/spec_v2/*.md` [SIM 2026-07-25].

**Titelprüfung:** Die Klauseltitel in §4, §5, §8, §9.3, §9.4, §9.5, §14, §16, §21, §22,
§23, §29 und die Annex-Titel wurden gegen das Inhaltsverzeichnis des Normtextes gelesen
[SIM 2026-07-25, `pdftotext -layout`]. Wo eine Zeile eine Klauselgruppe zusammenfasst,
steht das Thema, nicht der Originaltitel.

### 1.1 Klausel 4–7 — Rahmen, Modulation, HF, Synchronisation

| Klausel | Thema | Kapitel |
|---|---|---|
| §4.3 | Reference configuration (Übersicht der Funktionsblöcke) | — (keine Unterklauseln; die Modulationswerte stehen normativ in §5.2/§5.3) |
| §4.5.2 | Hyperframes, multiframes and frames (Übersicht) | 00, 02, 06, 12, 14 |
| §4.5.3 | Timeslots and bursts (Übersicht) | 00, 02, 06 |
| §4.7 | Modulation (Übersicht: π/4-DQPSK, 36 kbit/s) | — (korrekte Übersichtsstelle für `00 §2.1`) |
| §5.2 / §5.3 | Modulation type / Modulation rate | 01, 03, 08 |
| §5.4, Tab. 5.1, Gl. 5.1 | Modulation symbol definition, π/4-DQPSK-Phasenübergänge | 02, 03, 04 |
| §5.5, Gl. 5.4 | Modulated signal definition, RRC-Filter, **α = 0,35** | 01, 02, 03, 04 |
| §5.6 | Modulation filter definition | 04 |
| §6.4.2.2.2, §6.4.5, §6.4.5.1 | Sendereigenschaften, Linearisierung | 06, 15 |
| §6.6.2.2.0 | Obergrenze unentdeckt falscher Nachrichten (< 10⁻⁵ / < 10⁻⁴) | 14 |
| Tab. 6.28 | BER ungeschützte Bits: 0,01 % statisch, 0,4 % TU50 @ −85 dBm | 03, 14, 18 |
| Tab. 6.31 | Nachrichten-Ausfallrate **BS-Empfänger** (SCH/HU 8 %, SCH/F 8 %, Klasse B TU50) | 14 |
| §7.7 | BS requirements for synchronization (±0,2 ppm) | 01, 03, 15 |
| §7.8 a) / b) | MS requirements for synchronization (±100 Hz) | 03, 18 |

### 1.2 Klausel 8 — Kanalcodierung und Verschleierung

| Klausel | Thema | Kapitel |
|---|---|---|
| §8.1, Bilder 8.5/8.6 | Fehlerschutz-Struktur, Notation type-1…type-5 | 05 |
| §8.2.3.1.0–.1.2, Gl. 8.1–8.7 | 16-Zustands-Muttercode `r = 1/4`, Punktierung | 05 |
| §8.2.3.1.3, Gl. 8.8 | Punktierungsschema `r = 2/3` — Positionen `{0,1,4}` | 05 |
| §8.2.3.1.4 | Punktierungsschema `r = 1/3` (Sprachkanal) | 05 |
| §8.2.3.1.5 / .1.6 | Punktierung `r = 292/432` und `148/432` (TCH/4,8, TCH/2,4) | 05, 18 |
| §8.2.3.2, Gl. 8.12–8.13 | Verkürzter (30,14)-Reed-Muller-Code, `G = [I₁₄ \| P]` | 05, 17 |
| §8.2.3.3, Gl. 8.14–8.18 | Prüffeld-Blockcode `(K1+16, K1)` | 05 |
| §8.2.4.1, Gl. 8.34 | Block interleaving for phase modulation — `k = 1 + ((a·i) mod K)` | 05 |
| §8.2.4.2 | Interleaving over N blocks — nicht Stufe 1 | 05, 18 |
| §8.2.4.3 | Block interleaving for QAM (nur zur Abgrenzung: Tab. 8.2–8.6, 8.11, 8.13 sind QAM) | 05 |
| §8.2.5.1, Gl. 8.38 | Scrambling method — `b5 = b4 ⊕ p`, selbstinvers | 05 |
| §8.2.5.2, Gl. 8.39–8.42 | Scrambling sequence, Polynom, Initialisierung, Startwort | 05, 07, 12, 17 |
| §8.3.1.0 | Übersicht der Fehlerschutz-Schemata Phasenmodulation | 05 |
| §8.3.1.1, Gl. 8.43/8.44 | AACH — RM(30,14), kein Interleaving | 05, 07 |
| §8.3.1.2, Gl. 8.45 | BSCH — `(120, 11)`, `K1 = 60`, Startwert `0x3`, 4 Tailbits `0` | 05 |
| §8.3.1.3.1 | Frame stealing and multi-slot transmission | 05, 12 |
| §8.3.1.3.6, Gl. 8.58/8.59 | **TCH/S full slot** — Verweis auf EN 300 395-2, ab type-4 nur Scrambling | 05, 12, 18 |
| §8.3.1.3.7, Gl. 8.60 + NOTE | **TCH/S half slot** — `(216, 101)`, nur BKN2 | 05, 10, 12, 18 |
| §8.3.1.4.1, Gl. 8.61-8.62 | SCH/HD und BNCH — `(216, 101)`, `K1 = 124` | 05 |
| §8.3.1.4.3, Gl. 8.65 | SCH/HU — `(168, 13)`, `K1 = 92` | 05 |
| §8.3.1.4.5, Gl. 8.67-8.68 | SCH/F — `(432, 103)`, `K1 = 268` | 05 |

### 1.3 Klausel 9 — Physikalische Kanäle, Bursts, Abbildung

| Klausel | Thema | Kapitel |
|---|---|---|
| §9.3.1, Bild 9.1 | Physical resource, Kanalraster | 02, 04 |
| §9.3.3 | **Timeslots** — 85/6 ms = 255 Symbole | 01, 08, 13 |
| §9.3.4 | **TDMA frame** — 4 Slots, 170/3 ms, FN 1…18, FN18 = Kontroll-Frame | 01, 07, 08, 13, 17 |
| §9.3.5 | **Timeslot numbering** — TN 1…4 (Grundlage der 1-basierten Konvention) | 07 |
| §9.3.6 | **Subslot** — 85/12 ms = 127,5 Symbole, SSN 1…2 | 03, 07, 08, 13 |
| §9.3.7 / §9.3.8 | **Multiframe** (18 Frames, 1,02 s, MN 1…60) / **Hyperframe** (60 MF, 61,2 s) | 01, 07, 08, 17 |
| §9.3.9 | **Frame alignment** — UL um genau 2 Zeitschlitze verzögert | 07, 08 |
| §9.4.3.2 / §9.4.3.3 | Symbolnummerierung `SN` / Bitnummerierung `BN` | 01, 04 |
| §9.4.3.4 | **Burst timing** — Symbolzeit `(n + d)` | 04, 08 |
| §9.4.4.1, Tab. 9.2 | Bursttypen-Übersicht, `SNmax`, Verzögerung `d`, Guard | 03, 04, 08 |
| §9.4.4.2.0 | „The normal uplink burst contains two independent blocks" | 03 |
| §9.4.4.2.1, Tab. 9.3 | **Control uplink Burst (CB)** — 103 Symbole | 03, 06 |
| §9.4.4.2.2 | Linearization uplink Burst (LB) | 06 |
| §9.4.4.2.4, Tab. 9.5 | **Normal Uplink Burst (NUB)** — 231 Symbole, `n1..n22` **oder** `p1..p22` | 03, 06, 18 |
| §9.4.4.2.5, Tab. 9.7 | **Normal continuous downlink burst (NDB)** — 255 Symbole | 02, 03, 04, 06, 08 |
| §9.4.4.2.6, Tab. 9.9 | **Synchronization continuous downlink burst (SB)** | 02, 04, 06 |
| Tab. 9.10 / Tab. 9.12 | Diskontinuierliche Downlink-Bursts | 18 (Abgrenzung: 02) |
| §9.4.4.3.1, Gl. 9.1–9.3 | Frequency correction field `f1..f80` | 02 |
| §9.4.4.3.2, Gl. 9.4/9.5/9.6, Tab. 9.13 | **Normal training sequence** NTS1/NTS2/NTS3 + Kanalbelegungs-Bedeutung | 02, 03, 04, 06, 12, 17, 18 |
| §9.4.4.3.3, Gl. 9.9 | **Extended training sequence** `x1..x30` (CB) | 02, 03 |
| §9.4.4.3.4, Gl. 9.11 | **Synchronization training sequence** `y1..y38` | 02, 17 |
| §9.4.4.3.5, Gl. 9.12 | **Tail bits** `t1..t4 = 1,1,0,0` — nur UL/diskontinuierlich | 02, 04 |
| §9.4.4.3.6, Gl. 9.14, Tab. 9.15 | **Phase adjustment bits** — inhaltsabhängig | 02, 04 |
| §9.5.1, Tab. 9.27 | Abbildung logischer Kanäle auf Bursts/Blöcke/FN/TN | 06 |
| §9.5.2, Gl. 9.16–9.18, Tab. 9.33 | Abbildung BCCH und CLCH — Steuerframe-Formeln | 04, 06 |
| §9.5.4 | Abbildung TCH und STCH — **Stehlen wird über die Trainingssequenz angezeigt** | 06, 12 |
| §9.5.5 | Abbildung AACH — in jedem Downlink-Slot | 06 |
| §9.6, Tab. 9.38 | Beobachtungsmuster / Kanalzuweisung | 10 |

### 1.4 Klausel 14, 16, 18–20 — CMCE, MM, MLE, Dienste

| Klausel | Thema | Kapitel |
|---|---|---|
| §14.2, §14.3, §14.4 | CMCE-Übersicht, benötigte Dienste, Protokollzustände | 10 |
| §14.5.1.4.0, §14.5.2.x, §14.5.6.x | CMCE-Prozeduren: Rufaufbau, Sprechrechtsteuerung, Abbau | 10, 18 |
| §14.6, Tab. 14.3 | CMCE-Protokollzeitgeber T301/T302/T303/T310 | 10 |
| §14.7.1.x / §14.7.2.x | PDU-Beschreibungen Downlink / Uplink (`D-*` / `U-*`) | 10, 11 |
| §14.8.x, Tab. 14.8…14.90 | CMCE-Informationselemente | 10, 11 |
| §16.4.2, §16.6.1, §16.7.1 | Anmeldung, Abmeldung, Energieökonomie | 09, 18 |
| §16.8.2 / §16.8.4 | Anhängen/Abhängen von Gruppenkennungen, Gruppenmeldung | 09 |
| §16.9.2.x, Tab. 16.11 ff. | MM-PDU-Strukturen (u. a. `D-LOCATION-UPDATE-ACCEPT`) | 09, 18 |
| §16.10.x, Tab. 16.40 ff. | MM-Informationselemente (u. a. Energy saving, Gruppen-Element) | 09, 18 |
| §16.11.1.1 / .1.3 / .2.1 | MM-Parameter: T351, T353 (je 10 s), N351 (4) | 09 |
| §18.3.5.3.1, §18.4.x, §18.5.x | MLE-Funktionen, PDU-Beschreibungen, Informationselemente | 07, 09, 10 |
| §19.4.5, §19.4.7 | MS-Betriebsarten (Rufsucher-Betrieb) | 18 |
| §20.2.x, §20.3.1, Tab. 20.8/20.9 | Layer-2-Dienstbeschreibung, LLC-Dienste | 09, 11, 18 |

### 1.5 Klausel 21 — Layer-2-PDU-Beschreibung

| Klausel | Thema | Kapitel |
|---|---|---|
| §21.1.2.3, §21.3.1 | LLC FCS | 09 |
| §21.2.1, Tab. 21.1/21.4 | LLC-PDU-Typen | 08, 09, 11 |
| §21.2.2.1–.2.4 | `BL-ACK`, `BL-ADATA`, `BL-DATA`, `BL-UDATA` | 09, 11 |
| §21.2.3.5 | `AL-SETUP` (Advanced Link — nicht Stufe 1) | 09 |
| §21.4.0 | „The information content shall start with the most significant bit" | 06, 11 |
| §21.4.2.1, Tab. 21.41-21.43 | `MAC-ACCESS` (UL) | 06, 11 |
| §21.4.2.2, Tab. 21.44/21.45 | `MAC-END-HU` (UL) | 06, 11 |
| §21.4.2.3–.2.5, Tab. 21.46-21.51 | `MAC-DATA`, `MAC-FRAG` (UL), `MAC-END` (UL) | 06, 11 |
| §21.4.3.1, Tab. 21.55/21.56 | `MAC-RESOURCE` (DL), **Mindest-Kopflänge 29 bit** | 06, 11, 12 |
| §21.4.3.2, Tab. 21.57/21.58 | `MAC-FRAG` (DL) | 06, 11 |
| §21.4.3.3, Tab. 21.59/21.60 | `MAC-END` (DL) — **Kopf 21 bit mit Zusage / 13 bit ohne** | 06, 11 |
| §21.4.3.4, Tab. 21.61 | `MAC-D-BLCK` | 06 |
| §21.4.4.1, Tab. 21.65 | `SYSINFO` | 01 |
| §21.4.4.2, Tab. 21.76 | `SYNC` | 04, 07 |
| §21.4.4.3, Tab. 21.79 | `ACCESS-DEFINE` | 14 |
| §21.4.6 | U-plane-Verkehr (TMD-SAP) | 12 |
| §21.4.7.2, Tab. 21.82/21.83 | **`ACCESS-ASSIGN`** — 14-bit-AACH-Infowort, Nutzungsmarkierung | 06, 07, 10 |
| §21.5.1, Tab. 21.86 | Access field | 06 |
| §21.5.2, Tab. 21.87 | Channel allocation | 10, 18 |
| §21.5.4, Tab. 21.93 | Reservation requirement | 06, 11 |
| §21.5.6, Tab. 21.96 | **Basic slot granting** (Zusageelement) | 06, 07, 11 |
| §21.6, Tab. 21.98 | **Units used in length indication** | 06, 11 |

### 1.6 Klausel 22, 23, 29 — LLC-, MAC-Prozeduren, SDS-TL

| Klausel | Thema | Kapitel |
|---|---|---|
| §22.2.1.1, §22.3.2.0-.2.3 | LLC-Prozeduren, `V(S)`/`N(S)`/`N(R)`-Regeln, Startwert `V(S) = 0` | 09, 11 |
| §23.1.3.1.1 | MS-Fähigkeiten (MS capabilities) | 18 |
| §23.2.1, Bild 23.5 | **Erweiterter Farbcode 30 bit = MCC(10) + MNC(14) + CC(6)** | 05, 12 |
| §23.3.1.3, §23.3.4 | Kontrollkanal-Typen, unabhängige UL/DL-Zuweisung | 10, 18 |
| §23.4.2.1.0-.1.2, Tab. 23.7/23.8 | PDU-Komposition Signalisierung, Fragmentierungsregeln | 08, 11, 18 |
| §23.4.2.2 | Füllbits (fill bits) | 06, 11 |
| §23.4.3.1.1/.1.2, §23.4.3.2, §23.4.3.3 | PDU-Dekomposition, Kriterien für Fragmentabbruch | 06, 11, 13 |
| §23.4.5.1, Gl. 23.2 | MS-Linearisierung — CLCH-Slotformel | 06 |
| §23.5.1.4.2 (+ NOTE) | **Zugriffszuweisung gilt für den UL-Slot desselben Frames** | 06, 08 |
| §23.5.1.4.8/.4.9 (+ NOTE 3) | Zufallszugriffs-Parameter, Wiederholverhalten der MS | 14 |
| §23.5.2.2.2 / .2.7 / .3.1 | **Reservierter Zugriff** — Haltedauer, Frame-18-Sonderfall | 06, 08, 11 |
| §23.5.5 | Zuweisung der Nutzungsmarkierung | 10 |
| §23.7.6, Tab. 23.9 | Layer-Management-Kommunikation | 18 |
| §23.8.3.0 a), §23.8.4.1.2/.1.3 | Verkehrsübertragung, Stehl-Wiederholungen `N.214`/`T.214` | 12, 18 |
| §29.4.2.x, Tab. 29.12-29.14 | SDS-TL-Codierung: `SDS-TRANSFER`, `SDS-REPORT`, `SDS-ACK` | 11 |
| §29.4.3.x, Tab. 29.16-29.24 | SDS-TL-Informationselemente (u. a. Kurzberichtsart, Zustellbericht) | 11, 18 |
| §29.5.3.3 / §29.5.4.1, Tab. 29.28/29.29 | Protokollkennungen, **Textcodierungsschema** (`0x01` = ISO 8859-1) | 11 |

### 1.7 Annexe und weitere Teile

| Fundstelle | Thema | Kapitel |
|---|---|---|
| Annex A.1 / A.2 (normativ) | **LLC-Zeitgeber und Konstanten** — `T.251` ≈ 227 ms, `N.251` = 2595 bit | 09 |
| Annex B.1 (normativ) | **MAC-Zeitgeber** — `T.202` = 9 DL-Frames, `T.206` = 18, `T.210` = 18, `T.214` = 6 | 06, 08, 14, 18 |
| Annex B.2 (normativ) | **MAC-Konstanten** — `N.203 ≥ 4`, `N.214` = 4 | 08, 11, 14, 18 |
| Annex C (normativ) | **FCS** — Generator `G(x)`, Sonderregel für Nutzlängen < 32 bit | 09 |
| Annex E (normativ) | **PDU-Codierungsregeln** — O-/P-/M-Bit-Semantik | 09 |
| Annex F (normativ) | Frequenzbänder, Duplexabstände, Kanalnummerierung | 01 |
| EN 300 392-9 §7.2.2 Tab. 3 | Meldungsanzeiger (`D-SETUP` Späteinstieg) | 10 |
| EN 300 395-2 §5.4.3.1, §5.5.1, §5.5.3, §5.6.3 | **ACELP-Sprachcodec und TCH/S-Kanalcodierung** — Normtext lag beim Schreiben **nicht** vor, deshalb `[CODE]`-belegt, nicht `[ETSI]`-verifiziert (`05` O-05-3, `12` O-12-1) | 05, 12 |

---


---

## 2. Kennungsverzeichnis

Wegweiser, kein Volltext. Die Kennung selbst steht mit ihrem Inhalt im jeweiligen
Kapitel: Anforderungen `R-NN-n` in Abschnitt 1, Verifikationspunkte `V-NN-n` in
Abschnitt 5, offene Punkte `O-NN-n` in Abschnitt 6.

Stand: nach dem Konsistenz- und Reparaturdurchgang, frisch erhoben.

| Kapitel | Anforderungen `R` | Verifikationspunkte `V` | Offene Punkte `O` |
|---|---:|---:|---:|
| `00_OVERVIEW` | 4 | 0 | 3 |
| `01_PLATFORM` | 23 | 9 | 7 |
| `02_PHY_DL_RX` | 13 | 10 | 10 |
| `03_PHY_UL_RX` | 17 | 6 | 9 |
| `04_PHY_TX_TDMA` | 26 | 0 | 7 |
| `05_CHANNEL_CODING` | 20 | 0 | 5 |
| `06_MAC` | 33 | 8 | 5 |
| `07_PS_PL_CONTRACT` | 44 | 0 | 7 |
| `08_TIMING` | 20 | 0 | 12 |
| `09_LLC_MLE_MM` | 31 | 1 | 8 |
| `10_CMCE_CALL` | 32 | 1 | 10 |
| `11_SDS` | 29 | 0 | 7 |
| `12_VOICE` | 31 | 0 | 13 |
| `13_SW_ARCHITECTURE` | 45 | 21 | 12 |
| `14_VERIFICATION` | 26 | 15 | 13 |
| `15_BUILD_DEPLOY` | 20 | 15 | 9 |
| `17_LESSONS_LEARNED` | 14 | 15 | 11 |
| `18_ROADMAP` | 22 | 0 | 29 |
| **Summe** | **324** | **84** | **126** |

**Lesehinweise zu den Zahlen.** Kapitel ohne eigene `V`-Kennungen führen ihre
Verifikation in benannten Tabellen statt in nummerierten Punkten; die Abnahme-Matrix
in `14_VERIFICATION.md` zitiert diese Kapitel deshalb über Abschnitt statt über
Kennung. Die hohe Zahl offener Punkte in `18_ROADMAP.md` ist beabsichtigt: das
Kapitel sammelt die offenen Punkte der übrigen Kapitel ein, statt sie dort liegen
zu lassen.

**Kapitel 16 existiert nicht.** Die Nummer ist übersprungen; der Satz ist mit den
18 Kapiteln `00`–`15`, `17`, `18` vollständig.
