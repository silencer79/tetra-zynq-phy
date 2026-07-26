# Burst Inventory — Reference Capture

## DL Statistics

- **Bursts decoded:** 2987
- **Types:** NDB1=56, NDB2=946, SB=1985
- **SB carrying BNCH (`[... BNCH]` suffix):** 42
- **NDB1 with non-NULL MAC-RESOURCE addr (signaling):** 18
  - of these non-broadcast (real addressed): 14

### AACH-Pattern Distribution

| Count | Kind | Raw |
|---|---|---|
| 1860 | CapAlloc | 0x3000 |
| 859 | DL/UL-Assign | n/a |
| 194 | Reserved | 0x2049 |
| 48 | CapAlloc | 0x31C7 |
| 12 | Reserved | 0x21C9 |
| 11 | Reserved | 0x2249 |
| 3 | CapAlloc | 0x3047 |

### Addressed Bursts (non-NULL MAC-RESOURCE addr)

| Count | Addr |
|---|---|
| 16 | `SSI` |
| 2 | `SSI+Usage` |

## UL Statistics

- **Bursts detected/parsed:** 52
- **CRC OK (SCH/HU signaling):** 7
- **CRC FAIL (mostly TCH/S voice payload):** 45
- **SKIP (weak x-correlation):** 0
