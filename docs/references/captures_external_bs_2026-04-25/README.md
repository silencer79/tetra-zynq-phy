# Reference: External TETRA BS Attach Sequence (Captured 2026-04-25)

Gold-Referenz für ITSI-Attach gegen eine echte, funktionierende TETRA-BS — captured
während sich eine MS (ISSI=2 633 716) erfolgreich einbucht.

## Cell parameters

| Field | Value |
|-------|-------|
| MCC | 262 |
| MNC | 1010 |
| CC | 1 |
| DL Frequency | 392.9875 MHz (Band 3, Carrier 3719) |
| UL Frequency | 382.9875 MHz (DL − 10 MHz duplex) |
| Location Area | 1 |
| Scrambling code | 0x4183F207 |
| MS ISSI | 2 633 716 |

## Files

| File | Content | SHA-256 |
|------|---------|---------|
| `baseband_393084625Hz_00-11-52_25-04-2026.wav` | DL capture @ 393.0846 MHz (97 kHz off), sr=250 kHz, 18.1 s, 4528128 samples | `8e172afe0f569e91a861089fd9775ef85c606501854aba5c64d7ce0aaa6a76a1` |
| `baseband_382468718Hz_00-11-50_25-04-2026.wav` | UL capture @ 382.4687 MHz (519 kHz off), sr=1.536 MHz, 17.7 s | `9280baeef0e7fd201660e2ac0044490357a208ba368840d1964c50a2199b167f` |
| `decode_dl_full.log` | Full decode_dl.py output (1278 burst slots, all valid) |  |
| `decode_ul.log` | Partial UL decode (3 bursts found, parser stumbles on external-MS format) |  |
| `attach_sequence_bursts.txt` | Attach-relevant DL bursts extracted with -v bit dumps |  |

## Gold reference: DL attach sequence

**Burst #727** (SCH/HD — short RA-Ack?):
```
TN=1 FN=13 MN=50  AACH [DL/UL-Assign] DL=Unalloc UL=Unalloc f1=0 f2=9
BKN1 SCH/HD  MAC-RESOURCE  addr=SSI ID=2633716  LI=7 (7 octets)
bits: 00100010 00111001 00101000 00101111 11110100 01000000 00010000
      00000000 00010000 10000000 00000000 00000000 00000000 00000000 00000000 0
```

**Burst #735** (SCH/F — full D-LOC-UPD-ACCEPT, 8 bursts / ~2 frames later):
```
TN=1 FN=15 MN=50  AACH [DL/UL-Assign] DL=Unalloc UL=Unalloc f1=0 f2=9
SCH/F  MAC-RESOURCE  addr=SSI ID=2633716  LI=21 (21 octets)
  LLC  BL-ADATA NR=0 NS=0        ← combined ack+data, ETSI 22.3.2.3 case d
  MLE  disc=MM → D-LOC-UPD-ACCEPT
  MLE    LocUpdAccept: ITSI-Attach
bits: 00100000 10101001 00101000 00101111 11110100 01000000 00000000 00010101
      01110001 00000000 00000001 01010000 01110100 01101110 00001001 10000...
```

## Key deltas vs our current Accept

| Field | External BS (gold) | Our BS (post-L2SigPdu deploy) |
|-------|--------------------|-------------------------------|
| LLC wrapper | **BL-ADATA** (type 0, ns+nr) | L2SigPdu (type 14) |
| LI | **21 octets** (168 bits) | 11 octets (88 bits) |
| AACH on addressed slot | DL=Unalloc UL=Unalloc (`0x0049` area) | DL=Common UL=Random (`0x0249`) |
| MM PDU body | long — contains multiple optional Type-2 fields | minimal — only SSI present |
| Preceding short ACK (SCH/HD) | yes — LI=7 from same SSI, 2 frames before | no (we don't send a separate RA-ack) |

## Implication for our stack

1. **Switch LLC wrapper to BL-ADATA** (not BL-DATA, not L2SigPdu)
2. **Fill MM body with address_extension (MNI), subscriber_class, energy_saving_information, possibly authentication_downlink** to match the ~21-octet size
3. **Change AACH for sig_override slots to `DL=Unalloc UL=Unalloc`** (not `Common/Random`)
4. **Emit short SCH/HD pre-ack** addressed to MS-SSI, 2 frames before the full Accept

## Reproduction

```bash
python3 scripts/decode_dl.py docs/references/captures_external_bs_2026-04-25/baseband_393084625Hz_00-11-52_25-04-2026.wav --sr 250000 --max-bursts 50000 -v
```
