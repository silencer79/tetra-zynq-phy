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

## Complete attach sequence (UL + DL, time-aligned)

Captures are simultaneous (UL started 2 s before DL). Absolute timestamps:

| Abs time | Side | Event |
|----------|------|-------|
| 00:12:01.36 | UL #0 | MAC-ACCESS addr=Ssi(**ISSI=2 633 716**) frag=1 LLC=BL-DATA NS=0 + direct-MM payload |
| 00:12:01.41 | UL #1 | MAC-U-BLCK (top_nibble=3, voice/signalling capacity use) |
| 00:12:01.53 | UL #2 | MAC-ACCESS addr=Ssi(**ISSI=2 633 716**) LI=6 LLC=BL-ACK NR=0 (acks BS's BL-DATA ns=0) |
| 00:12:02.30 | DL #727 | SCH/HD AL-SETUP addr=SSI=2 633 716 LI=7 — BS vor-reply |
| 00:12:02.40 | DL #735 | SCH/F BL-ADATA NR=0 NS=0, D-LOC-UPD-ACCEPT, LI=21 — BS full Accept |

## Key findings

- **ISSI is embedded in every MAC-ACCESS header** as 24-bit SSI when `addr_type=0`
  (`Ssi(ISSI)` per bluestation `mac_access.rs`: `ssi_type: SsiType::Issi, // Uplink, always ISSI`).
  BS learns the ISSI directly from the RA header — no lookup table needed.
- **Our MTP3550 ISSI = 2 633 617 (0x282F91)**, external MS ISSI = 2 633 716
  (0x282FF4). Same network prefix `0x282xxx` (Motorola SSI range).
- **MS uses BL-DATA (not L2SigPdu) to carry the Demand**, with NS=0. BS must
  respond with BL-ACK NR=0 for the LLC handshake. MS additionally sends her
  own BL-ACK NR=0 to ack the BS's outgoing BL-DATA (full-duplex LLC).
- Registration involves **LLC-layer acknowledged data transfer in both
  directions**, not unacked L2SigPdu as we previously assumed.

## Historical parser bug (now fixed)

The original `scripts/decode_ul.py` read MAC-ACCESS headers with wrong
field widths (addr_type as 3 bits, short_ssi_or_event_label as 10 bits),
producing `short_id=523` for every MS. Real `addr_type` is 2 bits and the
SSI field is 24 bits wide when addr_type=0. Parser now aligned with
bluestation `mac_access.rs::from_bitbuf`:

```
bit[0]:     mac_pdu_type   (1 bit, 0 = MAC-ACCESS)
bit[1]:     fill_bits      (1 bit)
bit[2]:     encrypted      (1 bit)
bits[3..4]: addr_type      (2 bits)
bits[5..28]:address        (24 bits for Ssi/Ussi/Smi, 10 for EventLabel)
bit[29]:    optional_field_flag
...        optional length_ind / frag_flag+reservation_req
bits[36..]: TL-SDU = LLC PDU
```

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

## Key deltas vs our current stack (post-two-phase-commit 2c8ad4a)

| Field | External BS (gold) | Our BS status |
|-------|--------------------|---------------|
| Addressed SSI in DL-Accept | **real ISSI** from MS's MAC-ACCESS RA (e.g. 2 633 716) | **523** (parser-bug artefact — low 10 bits of 24-bit ISSI) |
| UL MS wraps Demand | BL-DATA NS=0 | (same — we saw L2SigPdu earlier due to parser bug; real form is BL-DATA) |
| LLC wrapper for BS-Accept | **BL-ADATA NR=0 NS=0** (combined ack+data) | BL-ADATA ✓ (2c8ad4a) |
| Preceding SCH/HD pre-reply | LI=7 AL-SETUP | AL-SETUP ✓ (2c8ad4a) |
| AACH on addressed slot | DL=Unalloc UL=Unalloc | Unalloc/Unalloc ✓ (2c8ad4a) |
| Accept MM-body LI | 21 octets (with addr_ext, subscr_class, esi) | 11 octets (minimal, SSI only) |
| UL-side reply from MS | BL-ACK NR=0 back to BS | (not yet expected — depends on correct addressing) |

## Implication for our stack

1. **Fix RTL UL-parser** `tetra_ul_mac_access_parser.v`:
   - `addr_type` = 2 bits (not 3)
   - extract full **24-bit ISSI** (not 10-bit short_ssi) when `addr_type=0`
   - pass 24-bit ISSI through AXI mailbox + CDC to MLE-FSM
2. **MLE-FSM** addresses Accept with the real 24-bit ISSI from the UL RA
3. **Expand D-LOC-UPD-ACCEPT MM body** to LI=21 (address_extension=MNI,
   subscriber_class, energy_saving_information=StayAlive)

## Reproduction

```bash
python3 scripts/decode_dl.py docs/references/captures_external_bs_2026-04-25/baseband_393084625Hz_00-11-52_25-04-2026.wav --sr 250000 --max-bursts 50000 -v
```
