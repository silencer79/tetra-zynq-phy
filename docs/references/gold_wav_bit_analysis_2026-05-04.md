# Gold WAV Bit Analysis 2026-05-04

Analyseziel: die Gold-Referenz-WAVs auf PHY-, MAC-, LLC-, MLE/MM- und
CMCE-Ebene so weit zerlegen, dass daraus die nachzubauenden Mechanismen
ableitbar sind.

## Dateien

| WAV | Dauer | SHA-256 |
|---|---:|---|
| `wavs/gold_standard_380-393mhz/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | 103.979008 s | `745f52fd8f9388160bb794142c3dea36c43549b3955797c450fd0442bc6be3ee` |
| `wavs/gold_standard_380-393mhz/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | 109.355008 s | `7895a9bf4216c3d31ee95e8e3f3b2197359ba4bb2a84a59ff15f401f2d1fa7af` |
| `wavs/gold_standard_380-393mhz/UL_Referenz_baseband_382891562Hz_22-43-02_26-04-2026.wav` | 35.727360 s | `13b65533af81d20cf61cc19e284e3d27d1988f5ec287d93ce3130aa676007659` |

Alle drei sind 16-bit stereo IQ-WAVs mit 250000 Hz.

## Cell Lock

DL-Decoder-Lock:

| Feld | Wert |
|---|---|
| MCC/MNC/CC | `262 / 1010 / 1` |
| Scrambler | `0x4183F207` |
| Main carrier | `3719` |
| Band / Duplex | `3 / 0` |
| Location Area | `1` |
| DL | `392.9875 MHz` |
| daraus UL | `382.9875 MHz` |
| MS ISSI | `2633716` = `0x282FF4` |

DL full pass: `7171 decoded, 167 failed, 0 empty`, SB `5171/5171`, NDB
`2000/2167`, MER `1.17 %`. Die NDB-Fehler liegen fast komplett im
Kapazitaets-/Traffic-Abschnitt; die Control-Signalling-PDUs sind konsistent.

## Decoder-Erweiterungen

Fuer diese Analyse wurden zwei kleine Dump-Hooks erweitert:

- `scripts/decode_ul.py --dump-bits` gibt nun alle dekodierten 92-bit
  MAC-ACCESS-PDUs mit `bits92=` aus, nicht nur die ersten zehn.
- `scripts/decode_dl.py --dump-burst` akzeptiert jetzt kommagetrennte
  Burst-IDs, z.B. `--dump-burst 423,775,783`.

Syntaxcheck:

```bash
python3 -m py_compile scripts/decode_dl.py scripts/decode_ul.py
```

## PHY/Channel-Coding

Die Gold-WAV bestaetigt folgende Pipeline:

- DL: STS/NTS-Korrelation -> pi/4-DQPSK soft -> De-Scramble ->
  Deinterleave -> Depuncture -> Viterbi K=5 r=1/4 -> CRC.
- UL: CB/SCH-HU mit x-Sequenz; pro Burst 168 type-5 Bits, K=168, a=13,
  92 info bits.
- DL-SCH/HD: 216 type-5 Bits, K=216, a=101, 124 info bits.
- DL-SCH/F: 432 type-5 Bits, K=432, a=103, 268 info bits.
- AACH: RM(30,14), dynamisch je Slot. MCCH/RA-Slots nutzen u.a.
  `Common/Random` und `Unalloc/Unalloc`; Traffic nutzt CapAlloc-Muster wie
  `0x32CB`.

## UL PDU Classes

Die 35-s-UL-Referenz dekodiert `12/12` SCH/HU CRC OK. Die lange GOLD_UL
dekodiert die ersten relevanten `23/23` Bursts CRC OK, wenn CFO-Korrektur
praktisch aus bleibt (`--cfo 0.001`). Wichtige 92-bit PDUs:

| PDU | Hex | Bedeutung |
|---:|---|---|
| 0 | `01 41 7F A7 01 12 66 34 20 C1 22 60` | MAC-ACCESS, ISSI `0x282FF4`, frag=1, LLC `BL-DATA NS=0`, MLE/MM `U-LOC-UPD-DEMAND`, `ITSI-Attach`, class `0x1A1060`, ESM=1 |
| 1 | `D4 1C 3C 02 40 50 2F 4D 63 20 00 00` | continuation / MAC top-nibble `3` |
| 2 | `41 41 7F A4 63 40...` or `...63 C0...` | MAC-ACCESS, LI=6, LLC `BL-ACK`, `NR=0/1` |
| 3 | `01 41 7F A7 01 97 38 08 21 20 5E 90` | MAC-ACCESS, LLC `BL-DATA NS=1`, MLE/MM `U-ATTACH-DETACH-GRP-ID` |
| 4 | `8D 59 30 5E 9A C6...` / `8D 59 70...` | continuation / MAC top-nibble `2` |
| 11 | `41 41 7F A4 71 91 40 01 41 7F A4 00` | MAC-ACCESS, LI=7, LLC `BL-DATA NS=1`, MLE/MM `U-ITSI-DETACH` |
| 22 | `41 41 7F A0 48 E0 02 00 4B D3 59 10` | MAC-ACCESS, LLC `BL-DATA NS=0`, MLE `CMCE`; uplink call-control trigger |

Key bitstring for first attach demand:

```text
bits92=00000001010000010111111110100111000000010001001001100110001101000010000011000001001000100110
```

## DL Key Bursts

Selected DL bit dumps were generated with:

```bash
python3 -u scripts/decode_dl.py \
  wavs/gold_standard_380-393mhz/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav \
  --max-bursts 7120 \
  --dump-burst 423,775,783,4811,5887,6344,6943,7104
```

The full selected on-air type-5 and info-bit dump is in
`/tmp/gold_dl_bitdump.log` for this run.

| Burst | Channel | Info hex | Meaning |
|---:|---|---|---|
| 423 | SCH/F | `0x2081ffffff0552b2a98fcefc8423ffc400108000000000000000000000000000000` | Periodic `D-NWRK-BROADCAST`, addressed to `0xFFFFFF`, LLC `BL-UDATA` |
| 775 | SCH/HD BKN1 | bits `0010001000111001001010000010111111110100010000000001000000000000000100001000000000000000000000000000000000000000000000000000` | Attach pre-reply, addr SSI `0x282FF4`, LI=7 |
| 783 | SCH/F | `0x20a9282ff440009571000150746e0981302f4d63200010800000000000000000000` | `D-LOC-UPD-ACCEPT`, LI=21, LLC `BL-ADATA`, ESI=0, Type-3 id=5 len=58 |
| 4811 | SCH/F | `0x2081282ff440011b3704c09817a6b22000108000000000000000000000000000000` | `D-ATTACH-DETACH-GRP-ID-ACK`, LI=16, accept_reject=0 |
| 5887 | SCH/F | `0x007e282ff42c89dd0ec9080080031021fe2f4d642c12380100026194a0bfd100000` | CMCE `D-CONNECT`, addr SSI+Usage, channel allocation carrier 3719 |
| 6344 | SCH/F | `0x0031282ff4062051282ff4049600401000692f4d64049600462a505fe8001080000` | Standalone DL `BL-ACK NR=0` / associated call-control ACK |
| 6943 | SCH/F | `0x208e2f4d642c899d0ec91c00800130e008001080000000000000000000000000000` | CMCE `D-SETUP`, addr `0x2F4D64`, channel allocation carrier 3719 |
| 7104 | SCH/F | `0x0031282ff40720492f4d64049200410010800000000000000000000000000000000` | Standalone DL `BL-ACK NR=1` |

## Ablaufmechanik

1. Dauerbetrieb der Zelle:
   - SYSINFO/BNCH/BSCH liefert MCC/MNC/CC, LA, carrier, hyperframe.
   - MCCH/Random-Access bleibt auf TN1 sichtbar.
   - `D-NWRK-BROADCAST` wird periodisch auf SCH/F gesendet, ca. alle 10 s.

2. ITSI Attach:
   - MS sendet UL `MAC-ACCESS` mit voller 24-bit ISSI `0x282FF4`.
   - LLC ist `BL-DATA NS=0`, Nutzlast ist MLE/MM `U-LOC-UPD-DEMAND`.
   - Darauf folgt eine continuation-PDU.
   - BS sendet SCH/HD-Pre-Reply LI=7 an dieselbe ISSI.
   - BS sendet zwei Frames spaeter SCH/F `D-LOC-UPD-ACCEPT` LI=21.
   - Accept ist LLC `BL-ADATA`, also ACK und neue Daten in einem PDU.
   - MS bestaetigt mit UL `BL-ACK NR=0/1`.

3. Group Identity Attach:
   - MS sendet `U-ATTACH-DETACH-GRP-ID` ueber `BL-DATA`, mit continuation.
   - BS antwortet mit SCH/F `D-ATTACH-DETACH-GRP-ID-ACK` LI=16.
   - LLC bleibt stop-and-wait: `NS/NR` alternieren und muessen pro MS/Sitzung
     verfolgt werden.

4. CMCE / Gruppenruf:
   - Nach Registration/Group-Attach erscheinen CMCE-PDUs.
   - DL `D-CONNECT` adressiert die MS mit SSI+Usage und enthaelt eine Channel
     Allocation auf carrier 3719.
   - DL `D-SETUP` adressiert den Gruppen-/Usage-Kontext `0x2F4D64`.
   - AACH wechselt auf Capacity Allocation; viele NDB1 CRC-Fails in diesem
     Bereich sind erwartbare Traffic/Voice-Inhalte, nicht fehlende Control-PDUs.
   - DL sendet weitere standalone `BL-ACK` PDUs, NR alterniert.

## Slot-Zuweisung — bit-genau (verifiziert 2026-05-06)

Slot-Grants wandern **NICHT in der AACH**, sondern im 8-bit `slot_granting_element`
des MAC-RESOURCE-Headers (ETSI EN 300 392-2 §21.5.6, RTL `tetra_basic_slotgrant_encoder.v`).

### slot_granting_element-Bit-Layout (8 bit)

```
bit [7:4]  capacity_allocation   (Tab. 21.88)
            0  = FirstSubslotGranted   ← Gold immer 0
            1  = grant 1 slot
            ...
            15 = SecondSubslotGranted
bit [3:0]  granting_delay        (Tab. 21.89, raw 4-bit)
            0  = next available subslot
            1  = 1 frame later
            ...
```

### MAC-Header-Flag-Position relativ zur SSI

```
bit [40]    power_control_flag         (in Gold immer 0)
bit [41]    slot_granting_flag         (1 = sg_element folgt)
bit [42:50] slot_granting_element      (8 bit, nur wenn flag=1)
bit [50/51] channel_allocation_flag    (verschoben je nach sg_flag)
```

Header-Laenge ist somit **43 bit** wenn alle drei Flags=0, **51 bit** wenn nur
sg_flag=1 (= Standard-Reply mit slot_grant), bis zu 75+ bit mit chan_alloc.

### Verifizierte sg_element-Werte (Gold-Capture)

| Burst | PDU | LI | sg_flag | sg_element | Bedeutung |
|---|---|---|---|---|---|
| #775  | AL-SETUP Pre-Reply ITSI-Attach     | 7  | 1 | **0x00** | grant Frag-2 next subslot, delay=0 |
| #783  | D-LOC-UPD-ACCEPT ITSI-Attach        | 21 | 1 | **0x00** | grant BL-ACK Frag-3, delay=0 |
| #4803 | AL-SETUP Pre-Reply mm=7             | 7  | 1 | **0x00** | grant Frag-2 |
| #4811 | D-ATTACH-DETACH-GRP-ID-ACK GS#1     | 16 | 1 | **0x00** | grant BL-ACK |
| #5343 | D-ATTACH-DETACH-GRP-ID-ACK GS#2     | 16 | 1 | **0x00** | grant BL-ACK |
| #1359 | DETACH AL-SETUP                     | 6  | **0** | — | kein UL-Grant noetig |
| #1363 | DETACH BL-ACK                       | 6  | **0** | — | kein UL-Grant noetig |

**Pattern:** Gold-BS emittiert sg_flag=1 mit sg_element=0x00 nur fuer ATTACH-Replies
(Pre-Reply UND Final-ACCEPT). DETACH-Replies haben sg_flag=0 — keine slot_grant_element-
Bytes im Header.

### AACH-Pattern auf MCCH (decoder-TN=1)

| Phase | AACH raw | header | DL-Usage | UL-Usage |
|---|---|---|---|---|
| Idle / D-NWRK-BCAST / DETACH-ACK | 0x0249 | 00 | 1=Common | 1=Random |
| ATTACH Pre-Reply Slot (LI=7) | 0x0009 | 00 | 0=Unalloc | 0=Unalloc |
| ATTACH ACCEPT Slot (LI=21/16) | 0x0009 | 00 | 0=Unalloc | 0=Unalloc |
| Filler zwischen LI=7 und LI=21 | 0x0249 | 00 | 1=Common | 1=Random |
| Traffic Slots (TN=2..4) idle | 0x3000 | 11 (CapAlloc) | — | — |
| Traffic Slots aktiv | 0x32CB / 0x22C9 | 11 / 10 | — | — |

Die AACH wechselt nur fuer die **2 Reply-Slots** auf 0x0009 und kehrt sofort
zurueck auf 0x0249. DETACH-ACK haelt AACH **immer** auf 0x0249 (wichtiger
Unterschied zu ATTACH).

### RTL-Drift gegen Gold

`rtl/lmac/tetra_dl_pdu_builder.v:100-108` instantiiert den slotgrant-encoder mit
`granting_delay=4'd1` → emittiert **sg_element=0x01** statt Gold's 0x00.
`rtl/lmac/tetra_pre_reply_slotgrant.v:130` ist korrekt (`8'h00`).

Funktionaler Effekt: MS-Timer auf BL-ACK ist tolerant gegen delay-Wert; M2
laeuft trotzdem. Bit-genau gegen Gold ist Builder zu korrigieren auf `4'd0`.

## Mechanismen, die wir abbilden muessen

1. Bitgenaue PHY-Pipeline fuer DL und UL:
   STS/NTS/x-Korrelation, pi/4-DQPSK soft, Scrambler, Deinterleave,
   Depuncture, Viterbi, CRC, AACH RM(30,14).

2. Vollstaendige UL-MAC-ACCESS-Auswertung:
   24-bit ISSI, optional field flag, LI vs frag/reservation, SCH/HU
   Reassembly und Weitergabe der 92-bit Roh-PDU.

3. LLC Stop-and-Wait pro ISSI:
   `BL-DATA`, `BL-ADATA`, `BL-ACK`, `NS`, `NR`, piggyback ACKs,
   Empfang von UL-BL-ACK, offene-DL-PDU-Zustand und Retransmit-Timer.

4. MM Registration:
   `U-LOC-UPD-DEMAND` inklusive optionaler Class/ESM-Felder parsen,
   `D-LOC-UPD-ACCEPT` LI=21 mit ESI und Type-3/GILA-Feld erzeugen.

5. Group Identity Attach:
   Fragmentierte `U-ATTACH-DETACH-GRP-ID` zusammensetzen,
   Gruppenwunsch/GSSI auswerten, `D-ATTACH-DETACH-GRP-ID-ACK` LI=16
   mit accept_reject=0 und Downlink-Gruppenliste erzeugen.

6. CMCE Gruppenruf:
   UL CMCE-Trigger erkennen, `D-CONNECT`/`D-SETUP` und spaeter
   TX-Grant/Release abbilden, Channel Allocation und AACH-CapAlloc
   synchron setzen, Traffic-Slot/Voice-Pass-Through einplanen.

7. Scheduler:
   MCCH/Random-Access auf TN1 erhalten, Frame-18 BSCH/BNCH-Regeln beachten,
   Pre-Reply/Accept zwei Frames versetzt setzen, periodisches
   `D-NWRK-BROADCAST` beibehalten, Traffic-Capacity-Phasen vom Control-Pfad
   trennen.

