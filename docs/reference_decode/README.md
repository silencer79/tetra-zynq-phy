# Reference Capture — Full Decompose

Bit-genaue Decompose der beiden Reference-WAVs.

> ## ⚠️ Quelldateien nicht mehr vorhanden — diese Auswertung ist nicht reproduzierbar
>
> Die unten genannten WAV-Dateien liegen **nicht mehr im Repository** (geprüft
> 2026-07-26). Vorhanden sind zehn andere Aufnahmepaare derselben Zelle unter
> `wavs/` — identische Netzkennung, Farbcode, Trägernummer und
> Scrambler-Startwert, aber kürzer (8…56 s statt 104 s) und **inhaltlich ärmer**.
>
> Ein Screening aller zehn Aufnahmen ergab: **keine** enthält eine Anmeldung
> (`D-LOCATION UPDATE ACCEPT`), einen Gruppenwechsel
> (`D-ATTACH/DETACH GROUP IDENTITY ACK`) oder ein `D-SETUP`. Diese Auswertung ist
> damit die **einzige** Dokumentation dieser Sequenzen und darf nicht
> überschrieben werden — die Spec-Kapitel `09_LLC_MLE_MM` und `10_CMCE_CALL`
> belegen damit.
>
> **Was das für ihre Verwendung heißt:** Die enthaltenen Daten sind echt und
> weiter gültig. Nicht möglich ist ein Neulauf mit geändertem Werkzeug — auch
> nicht der, der die unten beschriebene Werkzeuglücke schließen würde. Wer die
> geschlossene Lücke mit Zahlen belegt sehen will, nutzt
> `docs/reference_decode_2026-06-21/` (dieselbe Zelle, gefixtes Werkzeug, aber
> ohne die Anmelde- und Gruppenwechsel-Sequenzen).
>
> **Abdeckungsstand vor jeder Nutzung prüfen:**
> `python3 scripts/gold_coverage.py docs/reference_decode` — meldet, in welchen
> Zellen der Matrix ein Nullbefund **kein** Befund ist, weil das erzeugende
> Werkzeug diesen Bursttyp nicht durch die oberen Schichten geführt hat.

## Sources

| WAV | Dauer | Bursts detected | Bursts decoded |
|---|---|---|---|
| `wavs/reference/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` (fehlt) | 103.98 s | — | 7338 |
| `wavs/reference/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` (fehlt) | 109.36 s | — | 192 |

**Cell-Lock (TMO):** MCC=262 MNC=1010 CC=1 · Carrier=3719 · DL=392.9875 MHz · UL=382.9875 MHz · Scrambler=`0x4183F207` · MS ISSI=`0x282FF4` (2633716)

## Decoder Pipeline

```
WAV → wav_to_dibits → π/4-DQPSK soft → STS/NTS/x-seq sync → cell lock
     → per-burst phase correct → descramble → deinterleave → Viterbi → CRC
     → MAC layer → LLC layer → MLE/MM/CMCE/SDS layer
```

| Burst | Channel | K | a | info | Sync | Use |
|---|---|---|---|---|---|---|
| SB    | SB1     | 120 | 11  |  60 | STS 38-sym  | SYSINFO BNCH |
| NDB1  | SCH/F   | 432 | 103 | 268 | NTS1 11-sym | Signaling MAC-RESOURCE |
| NDB2  | SCH/HD  | 216 | 101 | 124 | NTS2 11-sym | Signaling/NULL or Voice TCH/S |
| NUB   | SCH/HU  | 168 | 13  |  92 | x-seq 15-sym| UL Signaling MAC-ACCESS |

## Files

| File | Inhalt |
|---|---|
| [burst_inventory.md](./burst_inventory.md) | Statistik DL+UL Burst-Typen, AACH-Verteilung |
| [dl_full.md](./dl_full.md) | Jeder DL-Burst, alle Layer (type-5 onair → type-4 desc → type-3 deint → info → MAC/LLC/MLE) |
| [ul_full.md](./ul_full.md) | Jeder UL-Burst, alle Layer + MAC-ACCESS Decode |
| [action_reaction.md](./action_reaction.md) | UL-Action ↔ DL-Reaction Zeit-korreliert (Slot-Time) |
| `dl_events.jsonl` / `ul_events.jsonl` | machine-readable JSONL pro Burst |

## Reproduce

```bash
python3 scripts/decode_dl.py wavs/reference/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav \
  --sr 250000 --max-bursts 10000 --dump-burst -3 > /tmp/dl_full_decode.log

python3 scripts/decode_ul.py wavs/reference/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav \
  --cc 1 --mcc 262 --mnc 1010 --max-bursts 500 --dump-bits --cfo 0.001 > /tmp/ul_full_decode.log

python3 scripts/parse_reference_decode.py
```

## Decompose Summary

- DL bursts decoded: **7338**, DL-time span 0..103.929 s
- UL bursts decoded: **192** (27 OK, 161 FAIL, 4 SKIP)
