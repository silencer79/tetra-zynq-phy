# Burst Inventory — Reference Capture

## DL Statistics

- **Bursts decoded:** 1876
- **Types:** NDB1=48, NDB2=455, SB=1373
- **SB carrying BNCH (`[... BNCH]` suffix):** 26
- **NDB1 with non-NULL MAC-RESOURCE addr (signaling):** 7
  - of these non-broadcast (real addressed): 4

### AACH-Pattern Distribution

| Count | Kind | Raw |
|---|---|---|
| 463 | DL/UL-Assign | n/a |
| 18 | CapAlloc | 0x32CB |
| 14 | Reserved | 0x22C9 |
| 6 | Reserved | 0x2049 |
| 2 | Reserved | 0x2249 |

### Addressed Bursts (non-NULL MAC-RESOURCE addr)

| Count | Addr |
|---|---|
| 4 | `SSI` |
| 3 | `SSI+Usage` |

## UL Statistics

- **Bursts detected/parsed:** 29
- **CRC OK (SCH/HU signaling):** 10
- **CRC FAIL (mostly TCH/S voice payload):** 19
- **SKIP (weak x-correlation):** 0
