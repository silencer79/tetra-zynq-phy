# Burst Inventory — Reference Capture

## DL Statistics

- **Bursts decoded:** 7338
- **Types:** NDB1=198, NDB2=1969, SB=5171
- **SB carrying BNCH (`[... BNCH]` suffix):** 102
- **NDB1 with non-NULL MAC-RESOURCE addr (signaling):** 24
  - of these non-broadcast (real addressed): 13

### AACH-Pattern Distribution

| Count | Kind | Raw |
|---|---|---|
| 1808 | DL/UL-Assign | n/a |
| 180 | CapAlloc | 0x32CB |
| 151 | Reserved | 0x2049 |
| 15 | Reserved | 0x2249 |
| 11 | Reserved | 0x22C9 |
| 2 | CapAlloc | 0x304B |

### Addressed Bursts (non-NULL MAC-RESOURCE addr)

| Count | Addr |
|---|---|
| 20 | `SSI` |
| 4 | `SSI+Usage` |

## UL Statistics

- **Bursts detected/parsed:** 192
- **CRC OK (SCH/HU signaling):** 27
- **CRC FAIL (mostly TCH/S voice payload):** 161
- **SKIP (weak x-correlation):** 4
