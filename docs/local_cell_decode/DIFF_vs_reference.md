# Diff: Local Cell vs Reference

Vergleich der beiden Captures auf PDU- und Signalisierungs-Ebene.

## Cell-Identität

| | Reference | Local |
|---|---|---|
| MCC | 262 | **901** |
| MNC | 1010 | **9998** |
| CC | 1 | **49** |
| Scrambler | `0x4183F207` | **`0xE1670EC7`** |
| DL freq | 392.9875 MHz | **438.34375 MHz** |
| UL freq | 382.9875 MHz | **428.15625 MHz** |
| Duplex | 10 MHz | **10.1875 MHz** |
| Carrier | 3719 | (lokal, MS-Band 425-440) |
| MS ISSI | `0x282FF4` = 2633716 | **`0x282F91` = 2633617** |

(Erwartete Unterschiede — verschiedene Netze.)

## Aufnahmedauer + Burst-Anzahl

| | Reference | Local |
|---|---|---|
| DL-Dauer | 103.98 s | **26.59 s** |
| UL-Dauer | 109.36 s | **23.73 s** |
| DL-Bursts | 7338 | **1876** |
| UL-Bursts | 192 | **29** |
| UL CRC OK | 27 | **10** |
| UL CRC FAIL (voice) | 161 | **19** |
| UL SKIP | 4 | 0 |

Local-Capture ist 4× kürzer — eine einzelne Use-Case-Sequenz statt mehrere.

## DL-Signalisierungs-Inventar

| MLE/MM/CMCE PDU | Reference | Local |
|---|---|---|
| D-NWRK-BROADCAST (broadcast SSI=16777215) | 11 | 3 |
| D-LOC-UPD-ACCEPT | 3 | **1** |
| D-ATTACH-DETACH-GRP-ID-ACK | 4 | 0 |
| D-CONNECT | 3 | **3** |
| D-SETUP | 1 | 0 |
| D-OTAR | 3 | 0 |

**Beobachtung:** Local Zelle macht **keine Group-Attach-Sequenz** (kein D-ATTACH-DETACH-GRP-ID-ACK), kein D-OTAR (Authentication / Key-Update). Reference hat Group-Attach (UL #11-13/14-18/19-21 → 3× D-ATTACH-DETACH-GRP-ID-ACK).

## UL-Sequenz Side-by-Side (Use-Case-Phasen)

| Phase | Reference (Zeit, Bursts) | Local (Zeit, Bursts) |
|---|---|---|
| **Anmeldung #1** | t=12.5s: UL #0/1/2 ITSI-Attach `01 41 7F A7 01 12` / `D4 1C 3C` / `41 41 7F A4 63 C0` → DL #783 D-LOC-UPD-ACCEPT | t=11.13s: UL #0/1/2 `01 41 7C 8F 01 12` / `D4 1C 3C` / `41 41 7C 8C 63 40` → DL #873 D-LOC-UPD-ACCEPT |
| Anmeldung #2 / #3 | 37s, 60s — drei Wiederholungs-Anmeldungen | — |
| **Gruppenwechsel** | UL #11-21: 3× ATTACH-DETACH-GRP-ID, jedes mit DL-ACK | — (fehlt komplett) |
| **Gruppenruf** | UL #22 U-SETUP `41 41 7F A0 48 E0` → DL D-CONNECT 3× | UL #3/4 U-SETUP `41 41 7C 88 68 E0` (1× + Retransmit) → DL D-CONNECT 3× |
| Voice TCH/S | UL #23-191 (~ 169 Voice-Bursts) | UL #5-28 (~ 24 Voice-Bursts) |

## D-CONNECT Bit-Diff (bit-exakt per BlueStation Spec)

Bit-für-Bit Dekodiert mit `scripts/decode_d_connect.py` (folgt
`tetra-bluestation/.../cmce/pdus/d_connect.rs`, ETSI EN 300 392-2 §14.7.1.4).

| Feld | Reference | Local | Verdict |
|---|---|---|---|
| **MAC-RESOURCE-Header** |||| 
| pdu_type | 0 = MAC-RESOURCE | 0 | ✓ |
| fill_bit | 0 | 0 | ✓ |
| position_of_grant | 0 | 0 | ✓ |
| encryption_mode | 0 (unverschlüsselt) | 0 | ✓ |
| random_access_flag | 0 | 0 | ✓ |
| length_indicator | 15 (120 bit payload) | 15 | ✓ |
| address_type | 6 = SSI+Usage | 6 | ✓ |
| **ssi** | **2633716** | **2633617** | erwartete MS-Differenz |
| usage_marker | 11 | 11 | ✓ |
| power_control_flag | 0 | 0 | ✓ |
| slot_granting_flag | 0 | 0 | ✓ |
| channel_allocation_flag | 1 | 1 | ✓ |
| **Channel Allocation Element** ||||
| allocation_type | 0 = Replace | 0 | ✓ |
| timeslot_assigned | 4 | 4 | ✓ |
| uplink_downlink_assigned | 3 = Reserved¹ | 3 | ✓ |
| clch_permission | 1 | 1 | ✓ |
| cell_change_flag | 0 | 0 | ✓ |
| **carrier_number** | **3719** | **1530** | erwartete Carrier-Differenz |
| extended_carrier_flag | 0 | 0 | ✓ |
| monitoring_pattern | 3 | 3 | ✓ |
| **LLC** ||||
| llc_type | 2 = BL-UDATA | 2 | ✓ |
| **MLE** ||||
| discriminator | 2 = CMCE | 2 | ✓ |
| **CMCE D-CONNECT Body** ||||
| pdu_type | 2 = DConnect | 2 | ✓ |
| **call_identifier** | **8** | **1** | dyn. Counter, erwartet |
| call_time_out | 0 = Infinite | 0 = Infinite | ✓ |
| hook_method_selection | 0 | 0 | ✓ |
| simplex_duplex_selection | 0 = simplex | 0 = simplex | ✓ |
| transmission_grant | 0 = **Granted** | 0 = **Granted** | ✓ |
| transmission_request_permission | 0 | 0 | ✓ |
| call_ownership | 0 | 0 | ✓ |
| obit | 1 | 1 | ✓ |
| call_priority_pbit + value | 1, p=1 | 1, p=1 | ✓ |
| basic_service_information_pbit | 0 (absent) | 0 (absent) | ✓ |
| temporary_address_pbit | 0 (absent) | 0 (absent) | ✓ |
| notification_indicator_pbit | 0 (absent) | 0 (absent) | ✓ |
| facility | absent | absent | ✓ |
| proprietary | absent | absent | ✓ |
| trailing_mbit | 0 | 0 | ✓ |

¹ `uplink_downlink_assigned=3` ist laut Spec `Reserved`. Beide Cells emittieren den selben Wert — entweder beide implementieren denselben De-facto-Code oder es ist ein bekannter Eintrag, der im BlueStation-Enum als "Reserved" gelabelt wird.

**Schlussfolgerung:** Die D-CONNECT-PDU selbst ist **bit-exakt identisch** zwischen Reference und Local Cell, abgesehen von erwarteten Cell-/MS-spezifischen Werten (SSI, carrier_number, call_identifier). Der vorherige Eindruck "Local zu mager" war ein Padding-Sortier-Artefakt — beide Captures haben die selbe minimale D-CONNECT-Struktur (nur `call_priority`, keine optionalen Felder).

**Was eigentlich noch zu prüfen wäre:**

| Aspekt | Ref | Local | Bedeutung |
|---|---|---|---|
| D-CONNECT-Retransmit-Anzahl | 3× | 3× | identisch ✓ |
| Slot-Position des 1. D-CONNECT | TN1 FN02 MN60 | TN1 FN12 MN35 | unterschiedlich |
| Abstand zwischen Retransmits | 2 frames (FN02→04→06) | 1 frame (FN12→13→14) | **local hat enges Spacing** |
| Gesamt-TX-Dauer der 3 D-CONNECTs | 283 ms | 170 ms | local schneller |
| Identische info_hex pro Retransmit | ja | ja | ✓ keine Differenz im Body |

Mögliche Hypothesen zum engeren Retransmit-Spacing:
- BlueStation hält FN-Gap nicht ein (Standard fordert evtl. 2-frame-Abstand für D-CONNECT)
- Oder beides ist zulässig und die echte BS macht's nur konservativer
- Ohne ETSI 14.7.1.4 daneben nicht entscheidbar — aber strukturell ist beides möglich

## D-LOC-UPD-ACCEPT Bit-Diff (bit-exakt per BlueStation Spec)

Bit-für-Bit dekodiert mit `scripts/decode_pdu.py --pdu d-loc-upd-accept`
(folgt `tetra-bluestation/.../mm/pdus/d_location_update_accept.rs`,
ETSI EN 300 392-2 §16.9.2.7).

| Feld | Reference | Local | Verdict |
|---|---|---|---|
| **MAC-RESOURCE-Header** ||||
| length_indicator | 21 | 21 | ✓ |
| address_type | 1 = SSI (24 bit) | 1 | ✓ |
| ssi | 2633716 | 2633617 | erwartete MS-Differenz |
| power_control_flag | 0 | 0 | ✓ |
| slot_granting_flag | 1, slot_granting=0 | 1, slot_granting=0 | ✓ |
| channel_allocation_flag | 0 | 0 | ✓ |
| **LLC** ||||
| llc_type | 0 = BL-ADATA | 0 = BL-ADATA | ✓ |
| nr | 0 | 0 | ✓ |
| ns | 1 (= 2. retransmit) | 0 (= 1. transmit) | dyn., erwartet |
| **MLE** ||||
| discriminator | 1 = MM | 1 = MM | ✓ |
| **MM D-LOC-UPD-ACCEPT Body** ||||
| pdu_type | 5 = DLocationUpdateAccept | 5 | ✓ |
| **location_update_accept_type** | **3 = ItsiAttach** | **0 = RoamingLocationUpdating** | ⚠️ **POTENTIAL BUG** |
| obit | 1 | 1 | ✓ |
| ssi_pbit | 0 (absent) | 0 (absent) | ✓ |
| address_extension_pbit | 0 (absent) | 0 (absent) | ✓ |
| subscriber_class_pbit | 0 (absent) | 0 (absent) | ✓ |
| energy_saving_information_pbit | 1 (present) | 1 (present) | ✓ |
| energy_saving_mode | 0 = StayAlive | 0 = StayAlive | ✓ |
| esi.frame_number | 0 | 0 | ✓ |
| esi.multiframe_number | 0 | 0 | ✓ |
| scch_info_pbit | 0 (absent) | 0 (absent) | ✓ |
| **group_identity_location_accept** | present (id=5 len=58) | present (id=5 len=58) | ✓ |
| GILA.accept_reject | 0 = accept | 0 = accept | ✓ |
| GILA.reserved | 0 | 0 | ✓ |
| GILA.obit | 1 | 1 | ✓ |
| **GILA.group_identity_downlink (1 elem, 32 bit)** ||||
| ↳ attach_detach_type | 0 = attach | 0 = attach | ✓ |
| ↳ GroupIdentityAttachment.lifetime | 1 = AttachForNextItsiAttach | 1 | ✓ |
| ↳ GroupIdentityAttachment.class_of_usage | 4 | 4 | ✓ |
| ↳ address_type | 0 = GSSI only | 0 | ✓ |
| ↳ **gssi** | **`0x2F4D63` = 3100003** | **`0x000001` = 1** | ⚠️ **DEFAULT-TEST-WERT** |
| GILA.trailing_mbit | 0 | 0 | ✓ |
| trailing_mbit | 0 | 0 | ✓ |

**Zwei echte semantische Findings:**

### 1. `location_update_accept_type` falsch (RoamingLocationUpdating statt ItsiAttach)

ETSI EN 300 392-2 §16.9.2.7 zufolge soll die BS in der LOC-UPD-ACCEPT denselben Type quittieren, mit dem die MS den LOC-UPD-DEMAND gesendet hat. Unsere BS antwortet generisch mit `RoamingLocationUpdating (0)`, unabhängig vom MS-Demand. Reference antwortet hier mit `ItsiAttach (3)` weil die MS einen ITSI-Attach-Demand gesendet hat.

**Auswirkung:** Eine konforme MS könnte die Anmeldung als "anderer Vorgang als beantragt" interpretieren und entweder erneut versuchen oder fehlerhaft Werte cachen.

**Code-Stelle:** `tetra-bluestation/.../mm/.../d_location_update_accept.rs::location_update_accept_type` wird beim Bauen der Antwort vermutlich hardcoded auf 0 statt aus dem UL-Demand kopiert.

### 2. GSSI = `0x000001` statt produktiver Group-ID

Unsere BS weist die MS einer Gruppe mit GSSI `1` zu — das ist ein Default-Test-Wert. Reference vergibt `0x2F4D63 = 3100003`, eine konkrete GSSI die auch in der Group-Call-D-SETUP / D-CONNECT der Reference auftaucht.

**Auswirkung:** Wenn die MS einen Group-Call auf einer "echten" GSSI macht (z.B. eine in der Codeplug konfigurierte Gruppe), erkennt unsere BS die GSSI nicht aus dem Attach-Pfad. Das könnte Group-Call-Routing/Filtering brechen.

**Code-Stelle:** BlueStation-Config oder Codeplug-Bestand — die GSSI für `group_identity_downlink` sollte aus der MS-Codeplug oder einem konfigurierten Cell-Default kommen, nicht `1`.

### Was ist IDENTISCH (zur Beruhigung)

Alle Strukturfelder, alle Bit-Layouts, alle obit/pbit/mbit-Sequenzen, EnergySavingMode, GILA-Struktur, attach-detach-flag, class_of_usage — die D-LOC-UPD-ACCEPT-PDU ist **strukturell korrekt aufgebaut**. Nur die zwei semantischen Werte stimmen nicht.

## AACH-Pattern-Diff (Capture-skaliert)

| Pattern | Ref pro Sekunde | Local pro Sekunde |
|---|---|---|
| DL/UL-Assign | 1808/103.98 = **17.4** | 463/26.59 = **17.4** ✓ |
| CapAlloc 0x32CB | 180/103.98 = **1.73** | 18/26.59 = **0.68** |
| CapAlloc 0x304B | 0.02 | 0 |
| Reserved 0x2049 | 1.45 | 0.23 |
| Reserved 0x2249 | 0.14 | 0.075 |
| Reserved 0x22C9 | 0.10 | **0.53** ← mehr |

**Differenzen:**
- CapAlloc 0x32CB-Rate ist im local 2.5× niedriger als Reference
- Reserved 0x22C9 ist im local 5× häufiger als Reference
- DL/UL-Assign-Rate ist exakt gleich → BS-Grundrhythmus stimmt

## Timing UL-Action → DL-Reaction

| | Reference | Local |
|---|---|---|
| ITSI-Attach UL → LOC-UPD-ACCEPT DL | UL #0=12.5s, DL #783=11.08s · DL ~50ms vor UL¹ | UL #0=11.13s, DL #873=12.35s · **DL +1.2s nach UL** |
| U-SETUP UL → D-CONNECT DL | UL #22=84.86s, DL #5887=83.39s · DL ~1.4s früher¹ | UL #3=15.72s, DL #1245=17.62s · **DL +1.9s nach UL** |

¹ Reference: WAV-Start-Offset zwischen UL/DL-WAV ist 1.466s → Action-Reaction-Reihenfolge stimmt nach Offset.

Local: BS-Antwort auf U-SETUP **1.9 Sekunden nach Demand**. Das ist 3 Multiframes Verzögerung — wahrscheinlich zu lang. Reference reagiert in <1 Multiframe.

## Was vermutlich "schief" ist (Hypothesen — Stand nach bit-exakter Analyse)

**~~D-CONNECT-Payload zu mager~~** — **verworfen.** Bit-exakter Decode zeigt: beide D-CONNECTs sind strukturell identisch.

### Bestätigte Bugs (bit-exakt nachgewiesen)

**🔴 BUG A — D-LOC-UPD-ACCEPT location_update_accept_type:**
Local antwortet immer mit `RoamingLocationUpdating (0)` statt mit dem Type den die MS demanded hat.

**UL-Seite per bit-exaktem Decode bestätigt (`scripts/decode_pdu.py --pdu u-loc-upd-demand`):**
Beide MS (Reference + Local) demanden bit-identisch `U-LOCATION-UPDATE-DEMAND` mit `location_update_type=3=ItsiAttach`. Strukturell jeder weitere Feldwert (class_of_ms, energy_saving_mode=Eg1, request_to_append_la=0, cipher_control=0, ssi_pbit=0, address_extension_pbit=0) identisch.

- Reference-BS antwortet korrekt: D-LOC-UPD-ACCEPT type=`ItsiAttach (3)` ✓
- Local-BS antwortet falsch: D-LOC-UPD-ACCEPT type=`RoamingLocationUpdating (0)` ⚠️
- Stelle: BlueStation MM `d_location_update_accept.rs` (Wert wird beim Bauen der Antwort gesetzt)
- Fix: kopiere `location_update_type` aus dem `U-LOCATION-UPDATE-DEMAND` der MS in die Antwort

**🔴 BUG B — D-LOC-UPD-ACCEPT group_identity_downlink GSSI:**
Local vergibt GSSI=`1` (Test-Default) statt einer produktiv konfigurierten GSSI. Reference vergibt `0x2F4D63 = 3100003`.

**Auswirkung in der ganzen Call-Sequence per U-SETUP-Decode bestätigt** (`scripts/decode_pdu.py --pdu u-setup`):
- Local MS sendet U-SETUP mit `called_party_ssi=1` (Group-Call-Ziel = Default-Test-GSSI=1)
- Reference MS sendet U-SETUP mit `called_party_ssi=3100004 = 0x2F4D64` (= echte produktive GSSI)
- Alle anderen U-SETUP-Felder (circuit_mode=TchS, communication_type=point-to-multipoint, call_priority=0, …) bit-identisch
- Folge: MS akzeptiert die zugewiesene Default-GSSI und macht den Call auf der Test-Gruppe. Funktioniert technisch, aber kein produktiver Group-Call.

- Stelle: BlueStation Cell-Config (Codeplug / cell_state) — die GSSI muss vor dem Senden der LOC-UPD-ACCEPT korrekt gesetzt werden
- Fix: aus der MS-Codeplug oder Cell-Config-Datei laden statt hardcoded 1

### Offene Hypothesen (noch zu prüfen)

1. **D-CONNECT Retransmit-Spacing**: Local FN12→13→14 (1-frame-Abstand), Reference FN02→04→06 (2-frame-Abstand). Strukturell beide möglich.

2. **Keine D-ATTACH-DETACH-GRP-ID-ACK in Local**: Reference quittiert Group-Attach 3× explizit. Local Cell hat keinen Group-Attach-Sequenz. **Wahrscheinlich Folge von Bug B**: Da die GSSI in der LOC-UPD-ACCEPT bereits=1 ist und die MS direkt zum U-SETUP übergeht, gibt es keine separate Group-Attach-Sequenz. Reference's MS macht die Group-Attach für AndereGruppen weil sie zu mehr als einer Gruppe konfiguriert ist.

3. **Reference Attach-GSSI ≠ Call-GSSI** (0x2F4D63 = 3100003 attach, 0x2F4D64 = 3100004 call): Diff von 1 — entweder zwei verschiedene Gruppen, oder off-by-one im Decoder. Need to verify against second Reference D-LOC-UPD-ACCEPT iteration. Reine Forensik-Frage, kein Local-Cell-Bug.

3. **Latenz UL→DL-Reaktion**: 1.2-1.9s ist 3-4 Multiframes. Reference reagiert in <1 Multiframe (nach Capture-Offset bereinigt). → Hinweis auf Scheduling-Lag im BlueStation-Code.

4. **AACH-Pattern-Verteilung**: DL/UL-Assign-Rate stimmt 1:1, aber CapAlloc 0x32CB 2.5× seltener und Reserved 0x22C9 5× häufiger im local. → AACH-Scheduler hat anderen Output-Mix als die echte BS.
