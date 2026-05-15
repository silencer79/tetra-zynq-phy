# Reference Capture — Full Decompose

Bit-genaue Decompose der beiden Reference-WAVs.

## Sources

| WAV | Dauer | Bursts detected | Bursts decoded |
|---|---|---|---|
| `wavs/reference/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | 26.59 s | — | 1876 |
| `wavs/reference/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | 23.73 s | — | 29 |

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

- DL bursts decoded: **1876**, DL-time span 0..26.549 s
- UL bursts decoded: **29** (10 OK, 19 FAIL, 0 SKIP)
