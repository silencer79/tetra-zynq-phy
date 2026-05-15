# Bugs-Liste: Local-Cell vs Reference

Stand: bit-exakter Vergleich aller dekodierten PDU-Klassen,
Tools: `scripts/decode_pdu.py`, `scripts/parse_reference_decode.py`,
Daten: `docs/reference_decode/` ↔ `docs/local_cell_decode/`.

Severity-Skala:
- 🔴 **Critical** — Standard-Konformität verletzt, MS könnte Call/Anmeldung ablehnen
- 🟠 **Major** — Funktional, aber Konfigurations- oder Verhaltens-Anomalie
- 🟡 **Minor** — Strukturell beides möglich, Local weicht von Reference-Stil ab
- ⚪ **Tooling** — Bug in unserem Decode/Display-Code, nicht in BS-Firmware
- 🟢 **OK** — Bestätigt identisch / kein Bug

---

## 🔴 BUG-001 — D-LOC-UPD-ACCEPT location_update_accept_type = Roaming

**Befund:**
Lokale BS antwortet mit `location_update_accept_type=0=RoamingLocationUpdating`. Reference antwortet korrekt mit `location_update_accept_type=3=ItsiAttach`.

**Bit-exakte Belege:**
- Local UL #0+#1 reassembled → U-LOC-UPD-DEMAND mit `location_update_type=3=ItsiAttach`
- Local DL D-LOC-UPD-ACCEPT mit `location_update_accept_type=0=RoamingLocationUpdating` ⚠️

**Stand:** Source-Code (`tetra-entities/src/mm/mm_bs.rs:274`) ist korrekt:

```rust
let pdu_response = DLocationUpdateAccept {
    location_update_accept_type: pdu.location_update_type,  // ← korrekt übernommen
    ...
};
```

→ Der aktuelle Source-Code kopiert `pdu.location_update_type` direkt in die Antwort. Wenn die MS-Demand ItsiAttach=3 enthält und mein UL-Parser das korrekt liefert, müsste die Antwort auch ItsiAttach sein.

**Mögliche Ursachen (zu prüfen):**
1. **Deployed Firmware älter als Source-Code** — die Firmware auf der Bluestation könnte vor dem Fix sein
2. **`ULocationUpdateDemand::from_bitbuf` liefert falschen Wert** — d.h. Parser-Bug in der Library, der `location_update_type` falsch decodiert
3. **Anderer Code-Pfad** — vielleicht gibt es eine Fallback-Route, wenn `is_new=true` oder spezifische MS-Zustände erkannt werden

**Nächster Schritt:**
- Bluestation-Version auf dem Board feststellen (`cargo metadata` oder commit hash der Firmware)
- Wenn Firmware aktuell: BS-Logs während Anmeldung auswerten um zu sehen, was `pdu.location_update_type` der Parser tatsächlich liefert
- Falls Parser-Bug: in `tetra-pdus/src/mm/pdus/u_location_update_demand.rs::from_bitbuf` debuggen

**Verifikation:** Nach Fix muss eine neue WAV-Aufnahme zeigen: `location_update_accept_type=ItsiAttach (3)` für Local D-LOC-UPD-ACCEPT.

---

## 🔴 BUG-002 — GSSI = 1 → **MS-Codeplug, NICHT BS-Code**

**Stand: KEIN BlueStation-Code-Bug. Die lokale MS-Codeplug ist mit GSSI=1 konfiguriert.**

**Bit-exakter Beleg (per UL Multi-Burst-Reassembly,
`scripts/reassemble_ul_demand.py`):**

UL #0 (MAC-ACCESS) + UL #1 (MAC-END-HU continuation) reassembliert zu einem U-LOCATION-UPDATE-DEMAND mit Type3-Element GroupIdentityLocationDemand:

```
Reference MS sendet:
  GroupIdentityUplink: attach_type=attach class_of_usage=4 GSSI = 0x2F4D63 = 3100003

Local MS sendet:
  GroupIdentityUplink: attach_type=attach class_of_usage=4 GSSI = 0x000001 = 1
```

Bluestation-Code (`tetra-entities/src/mm/mm_bs.rs:589`):

```rust
let gssi = giu.gssi.unwrap();  // ← aus MS-Demand übernommen
let gid = GroupIdentityDownlink {
    gssi: Some(gssi),  // ← direkter Echo
    ...
};
```

→ Der Code echoed direkt was die MS demand'ed. Wenn MS=1 sendet, antwortet BS=1. Korrektes Verhalten.

**Fix:** **NICHT** in BlueStation. **Im MS-Codeplug**:
- Wahrscheinlich `tetra-radioprogramming` oder das MS-Setup-Tool
- GSSI in der Default-Group-Liste der Test-MS von `1` auf eine sinnvolle produktive Group-Identity ändern (z.B. eine im Bluestation-Cell-Config registrierte Test-GSSI)
- Alternativ: BlueStation Cell-Config so erweitern dass GSSI=1 ein "Test-Catch-All" ist, der für Test-Setups akzeptabel ist

**Verifikation:** Nach Codeplug-Update muss eine neue WAV-Aufnahme zeigen:
- UL U-LOC-UPD-DEMAND GroupIdentityUplink GSSI ≠ 1
- DL D-LOC-UPD-ACCEPT GroupIdentityDownlink GSSI = (neue MS-Codeplug-GSSI)
- UL U-SETUP called_party_ssi = (neue GSSI)

---

## 🟠 BUG-003 — Keine D-SETUP für Group-Call-Page

**Befund:**
Reference-BS sendet auf U-SETUP **erst D-SETUP an die Gruppe** (broadcast/multipoint Page an alle MS in der Gruppe), **dann D-CONNECT an die calling MS**. Unsere BS sendet nur D-CONNECT direkt — kein D-SETUP.

**Konsequenz:** Andere MS in der Gruppe werden nicht gepaged. Bei echtem Group-Call würde nur die initiierende MS Audio empfangen können, alle anderen "verpassen" den Call.

**Bit-exakte Belege:**
- Reference DL #6943 (kommt später im Capture) → D-SETUP addr=SSI+Usage ID=3100004 LI=17 channel_allocation: ts=4 carrier=3719
- Local: 0× D-SETUP im gesamten Capture

**Fix:** BlueStation CMCE-Subentity beim Empfang von U-SETUP: erst D-SETUP mit Multipoint-Adresse an die GSSI broadcasten, dann D-CONNECT für die calling MS.

**Verifikation:** Nach Fix muss `docs/local_cell_decode/burst_inventory.md` einen D-SETUP-Eintrag in der signaling-PDU-Liste zeigen.

---

## 🟠 BUG-004 — Latenz UL→DL-Reaktion 3-4× zu lang

**Befund:**
Lokale BS antwortet auf UL-Demand mit signifikanter Verzögerung:
- ITSI-Attach: 1.2 s (= 1.2 Multiframes)
- U-SETUP → D-CONNECT: 1.9 s (= 1.9 Multiframes)

Reference antwortet in <1 Multiframe (= <1 s nach Capture-Offset bereinigt). Typical TETRA-Spec ist 1 Multiframe.

**Belege (aus `action_reaction.md`):**
- Local UL #0 at t=11.13s → DL #873 D-LOC-UPD-ACCEPT at t=12.35s → Δt = +1.22s
- Local UL #3 at t=15.72s → DL #1245 D-CONNECT at t=17.62s → Δt = +1.90s
- Reference UL #0 → DL #783 (nach Capture-Offset-Bereinigung): Δt ≈ 0.06s (<1 Multiframe)

**Ursache (Hypothese):** Scheduling-Lag im BlueStation-Code. Möglicherweise wird die Antwort-PDU nicht in den nächsten freien Slot eingeplant, sondern erst nach mehreren Multiframes durch Polling-Schleife / Event-Queue verarbeitet.

**Code-Stelle:** MAC/RLC-Scheduler in BlueStation. Pfad `U-DEMAND → MM-Handler → D-RESPONSE-Queue → MAC-Scheduler`.

**Verifikation:** Nach Fix soll Δt < 100ms sein.

---

## 🟡 BUG-005 — D-CONNECT Retransmit-Spacing zu eng

**Befund:**
- Reference: 3× D-CONNECT auf TN1 FN02, FN04, FN06 von MN60 (= **2-frame-Abstand**, 283ms Gesamt-TX)
- Local: 3× D-CONNECT auf TN1 FN12, FN13, FN14 von MN35 (= **1-frame-Abstand**, 170ms Gesamt-TX)

**Konsequenz:** ETSI EN 300 392-2 §14.7.1.4 sagt nicht zwingend "2-frame-Abstand", aber konformen MS könnten zwischen den Frames andere Kanäle erwarten. Engeres Spacing könnte MS-Receiver "überrollen".

**Fix:** D-CONNECT-Retransmits im BlueStation-Scheduler mit 2-frame-Pause planen statt konsekutiv.

---

## 🟡 BUG-006 — AACH-Pattern-Mix abweichend

**Befund (per `aach_info_14b` raw-bits aus 7338/1876 Bursts):**

| 14-bit AACH | REF % | LOC % | Bedeutung |
|---|---|---|---|
| `11000000000000` (0x3000) | 66.1% | 36.8% | "DL=Unalloc UL=Unalloc CC=9 f1=0 f2=9" (FN18 broadcast slots) |
| `00001001001001` (0x0249) | 24.5% | 24.5% | DL/UL-Assign Common |
| `10000001001001` (0x2049) | 2.1% | **15.9%** | Reserved |
| `11001011001011` (0x32CB) | 2.5% | **12.5%** | CapAlloc |
| `10001011001001` (0x22C9) | 0.1% | **5.5%** | Reserved |
| `10001001001001` (0x2249) | 0.2% | 3.0% | Reserved |

**Konsequenz:** AACH-Scheduler im BlueStation hat andere Output-Mix als die echte BS. Nicht zwingend ein Bug, aber wenn produktive MS auf bestimmte AACH-Patterns reagieren (z.B. mehr Reserved-Codes bedeuten "BS busy" oder "Capability advertised"), könnte das Verhalten anders sein.

**Fix:** AACH-Scheduler tuning — möglich dass die Verteilung mit der MS-Population skaliert (mehr MS = mehr CapAlloc).

---

## 🟡 BUG-007 — Keine D-ATTACH-DETACH-GRP-ID-ACK in lokaler Capture

**Befund:** Reference hat 3× D-ATTACH-DETACH-GRP-ID-ACK (MS Group-Attach explicit acked). Local hat 0×.

**Konsequenz:** Vermutlich **Folge von Bug-002**: weil GSSI = 1 in der LOC-UPD-ACCEPT direkt mitgegeben wird, sendet die MS keinen separaten U-ATTACH-DETACH-GRP-ID, sondern geht direkt zum U-SETUP über. Reference-MS macht Group-Attach explizit, weil sie zu mehreren Gruppen konfiguriert ist.

**Fix:** Wenn Bug-002 gefixt ist (GSSI ist echte Gruppe), wird das Verhalten ggf. anders. Aktuell kein eigener Bug.

---

## ⚪ BUG-008 — UL-MD-Display zeigte DirectMM-Fallback als Haupt-MM (Tooling)

**Befund:** `parse_reference_decode.py::write_ul_full` zeigte fälschlich die `decoded_mode='direct_mm'`-Fallback-Spur. Beispiel: U-LOCATION-UPDATE-DEMAND wurde als "U-ITSI-DETACH" angezeigt (gleiches 4-bit-Pattern, anderer Offset).

**Status:** ✅ **Gefixt** in dieser Session. MD zeigt jetzt `MLE: disc=MM / MM type=U-LOC-UPD-DEMAND / ITSI-Attach`.

---

## 🟢 IDENTISCH — D-CONNECT-PDU-Body bit-exakt korrekt

**Bit-exakter Vergleich (`scripts/decode_pdu.py --pdu d-connect`):**

Alle Type1-Felder + obit/pbit/mbit-Struktur identisch zwischen Local und Reference:
- pdu_type=DConnect
- call_time_out=Infinite
- hook_method_selection=0
- simplex_duplex_selection=0
- **transmission_grant=Granted** (kritisch — beide gleich)
- transmission_request_permission=0
- call_ownership=0
- obit=1, call_priority=1 (alle anderen optionalen Felder absent)
- trailing_mbit=0

Erwartete cell-/MS-spezifische Diffs: MAC.ssi, channel_allocation.carrier_number, call_identifier.

---

## 🟢 IDENTISCH — U-LOCATION-UPDATE-DEMAND-Body bit-exakt

Beide MS demanden bit-identisch ITSI-Attach mit gleichen Type1 + Type2-Feldern (`class_of_ms`, `energy_saving_mode=Eg1`). Einziger Unterschied: MS-ISSI (erwartet).

---

## 🟢 IDENTISCH — U-SETUP-Body strukturell

Beide MS senden U-SETUP mit:
- circuit_mode_type=TchS (Speech 7.2)
- encryption_flag=0
- communication_type=point-to-multipoint (= Group-Call)
- call_priority=0
- called_party_type_identifier=SSI

Diff: `called_party_ssi` (3100004 ref vs 1 loc) — ist Konsequenz von Bug-002.

---

## 🟢 IDENTISCH — MAC-RESOURCE, MAC-ACCESS, LLC, MLE Layer

Alle Bit-Layouts der untergeordneten Layer (MAC-Header, LLC-Type, MLE-Discriminator, Type2/3/4 element handling, pbit/obit/mbit Sequenzierung) zwischen Local und Reference bit-exakt korrekt.

---

## 🟢 IDENTISCH — SB SYSINFO Struktur

SB1 60-bit Info: gleiche 60-bit Layout. Inhalt naturgemäß cell-spezifisch:
- Carrier=3719 (Ref) vs 1530 (Loc)
- Band=3 (Ref) vs 4 (Loc)
- HF=10119 (Ref) vs 1026 (Loc)
- DL=392.9875 MHz (Ref) vs 438.2500 MHz (Loc)

Encoder funktioniert bit-genau korrekt.

---

## 🟢 IDENTISCH — D-NWRK-BROADCAST Struktur

Beide haben:
- MAC: SSI=16777215 (broadcast addr), LI=16, no channel_allocation
- LLC: BL-UDATA
- MLE: disc=MLE
- 14 octets D-NWRK-BROADCAST content (cell-specific FN/MN snapshot)

---

## Bug-Prioritäten Aktionsplan (aktualisiert)

1. **Bug-002 (GSSI=1)**: **MS-Codeplug-Fix**, nicht BS. Höchste Priorität — größter Hebel. Test-MS umkonfigurieren.
2. **Bug-001 (location_update_accept_type)**: Erst Firmware-Stand der deployed BlueStation prüfen. Wenn Source aktuell ist, dann mit Logs/Debug nachprüfen ob Parser oder Code-Pfad wo der Wert verfälscht wird.
3. **Bug-003 (D-SETUP für Group-Call)**: BS-Funktionalität fehlt komplett. Implementieren nachdem Bug-002 gefixt — sonst auf falscher GSSI = sinnloser Test.
4. **Bug-004 (Latenz)**: Performance-Bug, kein Funktional-Bug. MS toleriert wahrscheinlich.
5. **Bug-005, Bug-006**: kosmetische Tuning-Aufgaben.

## Reproduktion

```bash
# Bit-exakter PDU-Vergleich
python3 scripts/decode_pdu.py --pdu d-loc-upd-accept   # zeigt Bug 001, 002
python3 scripts/decode_pdu.py --pdu u-setup            # zeigt Konsequenz Bug 002
python3 scripts/decode_pdu.py --pdu d-connect          # zeigt PDU ist OK
python3 scripts/decode_pdu.py --pdu u-loc-upd-demand   # zeigt MS-Demand ist korrekt

# Vollständige Pipeline
python3 scripts/parse_reference_decode.py --dl-log /tmp/dl_local_decode.log \
  --ul-log /tmp/ul_local_decode.log --out docs/local_cell_decode \
  --dl-dur 26.587 --ul-dur 23.725
```
