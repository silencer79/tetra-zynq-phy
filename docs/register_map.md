# AXI-Lite Register Map
# Project: tetra-zynq-phy
# Module: tetra_axi_lite_regs.v
# Base Address: 0x43C0_0000

## Overview

The AXI-Lite register interface provides ARM PS software (via tetra_hal.c)
with control and status access to the FPGA PHY/LMAC.

Address space: 256 bytes (0x00 – 0xFF), 32-bit word-aligned accesses only.

---

## Register Summary

| Offset | Name               | Access | Reset      | Description                          |
|--------|-------------------|--------|------------|--------------------------------------|
| 0x00   | CTRL              | R/W    | 0x0000_0000| Global control                       |
| 0x04   | STATUS            | RO     | 0x0000_0000| Global status                        |
| 0x08   | VERSION           | RO     | 0x0001_0000| Firmware version (major.minor)       |
| 0x0C   | SYNC_THRESH       | R/W    | 0x0000_0014| Sync correlator threshold (default=20) |
| 0x10   | COLOUR_CODE       | R/W    | 0x0000_0001| TETRA Colour Code (1–63)             |
| 0x14   | FRAME_NUM         | RO     | 0x0000_0000| Current TDMA frame number            |
| 0x18   | SLOT_NUM          | RO     | 0x0000_0000| Current timeslot (0–3)               |
| 0x1C   | RX_GAIN           | R/W    | 0x0000_0020| AD9361 RX gain (0–76 dB)            |
| 0x20   | TX_ATT            | R/W    | 0x0000_0028| AD9361 TX attenuation (0–89.75 dB)  |
| 0x24   | IRQ_ENABLE        | R/W    | 0x0000_0000| Interrupt enable mask                |
| 0x28   | IRQ_STATUS        | R/W1C  | 0x0000_0000| Interrupt status (write 1 to clear)  |
| 0x2C   | DMA_BLOCK_COUNT   | RO     | 0x0000_0000| Received MAC blocks since last clear |
| 0x30   | CRC_ERROR_COUNT   | RO     | 0x0000_0000| CRC errors since last clear          |
| 0x34   | SYNC_LOST_COUNT   | RO     | 0x0000_0000| Sync loss events since last clear    |
| 0x38   | RESERVED          | —      | —          | Reserved for future use              |
| 0x3C   | SCRATCH           | R/W    | 0x0000_0000| Scratch register (SW test)           |
| 0x40   | SB_SB1_0          | R/W    | 0x0000_0000| SDB sb1 word 0 (bits [119:88])       |
| 0x44   | SB_SB1_1          | R/W    | 0x0000_0000| SDB sb1 word 1 (bits [87:56])        |
| 0x48   | SB_SB1_2          | R/W    | 0x0000_0000| SDB sb1 word 2 (bits [55:24])        |
| 0x4C   | SB_SB1_3          | R/W    | 0x0000_0000| SDB sb1 word 3 (bits [23:0])         |
| 0x50–0x5C | RESERVED       | —      | —          | Freed from old 240-bit bkn1 layout   |
| 0x60   | SB_BKN2_0         | R/W    | 0x0000_0000| SDB bkn2 word 0 (bits [215:184])     |
| 0x64   | SB_BKN2_1         | R/W    | 0x0000_0000| SDB bkn2 word 1 (bits [183:152])     |
| 0x68   | SB_BKN2_2         | R/W    | 0x0000_0000| SDB bkn2 word 2 (bits [151:120])     |
| 0x6C   | SB_BKN2_3         | R/W    | 0x0000_0000| SDB bkn2 word 3 (bits [119:88])      |
| 0x70   | SB_BKN2_4         | R/W    | 0x0000_0000| SDB bkn2 word 4 (bits [87:56])       |
| 0x74   | SB_BKN2_5         | R/W    | 0x0000_0000| SDB bkn2 word 5 (bits [55:24])       |
| 0x78   | SB_BKN2_6         | R/W    | 0x0000_0000| SDB bkn2 word 6 (bits [23:0])        |
| 0x7C   | SB_BB             | R/W    | 0x0000_0000| AACH bb (bits [29:0])                |
| 0x80   | NCO_PHASE_INC     | R/W    | 0x0000_0000| TX NCO phase increment [31:0]        |
| 0x84   | TX_TEST           | R/W    | 0x0000_0000| Diagnostic: bit[0] = PRBS enable     |
| 0x88   | NDB_BLK1_0        | R/W    | 0x0000_0000| NDB block1 word 0 (bits [215:184])   |
| 0x8C   | NDB_BLK1_1        | R/W    | 0x0000_0000| NDB block1 word 1 (bits [183:152])   |
| 0x90   | NDB_BLK1_2        | R/W    | 0x0000_0000| NDB block1 word 2 (bits [151:120])   |
| 0x94   | NDB_BLK1_3        | R/W    | 0x0000_0000| NDB block1 word 3 (bits [119:88])    |
| 0x98   | NDB_BLK1_4        | R/W    | 0x0000_0000| NDB block1 word 4 (bits [87:56])     |
| 0x9C   | NDB_BLK1_5        | R/W    | 0x0000_0000| NDB block1 word 5 (bits [55:24])     |
| 0xA0   | NDB_BLK1_6        | R/W    | 0x0000_0000| NDB block1 word 6 (bits [23:0])      |
| 0xA4   | NDB_BLK2_0        | R/W    | 0x0000_0000| NDB block2 word 0 (bits [215:184])   |
| 0xA8   | NDB_BLK2_1        | R/W    | 0x0000_0000| NDB block2 word 1 (bits [183:152])   |
| 0xAC   | NDB_BLK2_2        | R/W    | 0x0000_0000| NDB block2 word 2 (bits [151:120])   |
| 0xB0   | NDB_BLK2_3        | R/W    | 0x0000_0000| NDB block2 word 3 (bits [119:88])    |
| 0xB4   | NDB_BLK2_4        | R/W    | 0x0000_0000| NDB block2 word 4 (bits [87:56])     |
| 0xB8   | NDB_BLK2_5        | R/W    | 0x0000_0000| NDB block2 word 5 (bits [55:24])     |
| 0xBC   | NDB_BLK2_6        | R/W    | 0x0000_0000| NDB block2 word 6 (bits [23:0])      |

---

## Register Bit Fields

### 0x00 — CTRL

| Bits  | Name           | Access | Description                                    |
|-------|----------------|--------|------------------------------------------------|
| 0     | RX_ENABLE      | R/W    | 1 = Enable RX chain                            |
| 1     | TX_ENABLE      | R/W    | 1 = Enable TX chain (Phase 3)                  |
| 2     | LOOPBACK_EN    | R/W    | 1 = TX→RX digital loopback (test mode)         |
| 3     | RESET_COUNTERS | R/W    | 1 = Clear DMA_BLOCK_COUNT, CRC/SYNC error ctrs |
| 7:4   | RESERVED       | —      | Write 0                                        |
| 31:8  | RESERVED       | —      | Write 0                                        |

### 0x04 — STATUS

| Bits  | Name           | Access | Description                                    |
|-------|----------------|--------|------------------------------------------------|
| 0     | SYNC_LOCKED    | RO     | 1 = Burst sync acquired                        |
| 1     | PLL_LOCKED     | RO     | 1 = AD9361 PLL locked                          |
| 2     | RX_FIFO_EMPTY  | RO     | 1 = RX FIFO empty (no data waiting)            |
| 3     | RX_FIFO_FULL   | RO     | 1 = RX FIFO full (data loss possible!)         |
| 7:4   | SLOT_STATUS    | RO     | Bitmap: which timeslots have valid data        |
| 31:8  | RESERVED       | —      |                                                |

### 0x24 — IRQ_ENABLE / 0x28 — IRQ_STATUS

| Bit | Name                | Description                              |
|-----|---------------------|------------------------------------------|
| 0   | IRQ_MAC_BLOCK_RDY   | MAC block available in DMA buffer        |
| 1   | IRQ_SYNC_ACQUIRED   | Sync lock achieved                       |
| 2   | IRQ_SYNC_LOST       | Sync lock lost                           |
| 3   | IRQ_CRC_ERROR       | CRC error on received block              |
| 4   | IRQ_RX_FIFO_FULL    | RX FIFO overflow                         |
| 31:5| RESERVED            |                                          |

### 0x84 — TX_TEST (Diagnostic)

| Bits | Name          | Access | Description                                     |
|------|---------------|--------|-------------------------------------------------|
| 0    | PRBS_EN       | R/W    | 1 = Replace burst-builder dibit with 15-bit LFSR PRBS (x^15+x^14+1, seed 0x7FFF) — verifies spectrum shape is RRC-spread not narrow CW |
| 31:1 | RESERVED      | —      |                                                 |

---

## SB Payload Registers (0x40–0x7C) — Continuous Downlink SB §9.4.4.2.6

Written by PS software (`tetra_sysinfo`) with fully coded type-5 bits for the
Synchronization Continuous Downlink Burst. The FPGA `burst_builder` shifts
them out as π/4-DQPSK symbols — no further coding in hardware.

**SDB frame layout (255 symbols = 510 bits):**
```
Tail1(6) + HC(1) + FreqCor(40) + sb1(60) + STS(19) + bb(15) + bkn2(108) + HD(1) + Tail2(5)
```

### SB1 (BSCH — 120 type-5 bits, 4 registers 0x40–0x4C)

Channel coding (EN 300 392-2 §8.2.3):
SYSINFO PDU (60 type-1) → CRC-16 (76) → +4 tail (80) → RCPC rate **2/3** (120)
→ interleave (8×15) → scramble (init=3, fixed for BSCH per §8.2.5.2) → 120 type-5.

Bit ordering: MSB-first. Register word 0 bit 31 = first transmitted bit.
FPGA concatenation: `{w0, w1, w2, w3[23:0]}` → 120-bit bus. Word 3 holds
the 24 trailing bits in `[23:0]` with `[31:24]` unused.

### BKN2 (BNCH — 216 type-5 bits, 7 registers 0x60–0x78)

BNCH payload for slot 0. SDB uses 108 symbols = 216 bits from this bank.

Channel coding (EN 300 392-2 §8.2.3.1):
124 type-1 PN bits (15-bit LFSR, seed 0x5A5A) → CRC-16 (140) → +4 tail (144)
→ RCPC rate 2/3 (216) → interleave (24×9) → scramble (cc/slot=0/mcc/mnc)
→ 216 type-5.  Implemented in `tetra_bnch_encode()` (sw/tetra_hal.c).
The PN seed is intentionally different from the NDB filler seed (0x7FFF) so
the slot-0 BNCH content differs from the slots-1..3 NDB filler.

### BB (AACH — 30 type-5 bits, 1 register 0x7C)

Access Assignment Channel: 14 info bits → RM(30,14) → 30 coded bits.
Packed MSB-first in bits [29:0]; `[31:30]` unused.

---

## NDB Payload Registers (0x88–0xBC) — Normal DL Burst Filler

Written by `tetra_write_ndb_filler()`. **The same 216 + 216 bits are broadcast
to all four NDB timeslots** via `{4{ndb_block1_data_sys}}` replication in
`tetra_zynq_top.v`, so slot 0 SDB coexists with slots 1–3 NDB carrying
identical channel-coded SCH/F filler.

Channel coding (EN 300 392-2 §8.2.3.1.1):
268 type-1 (4-bit MAC-NULL PDU + 264 LFSR bits) → CRC-16 (284) → +4 tail (288)
→ RCPC rate 2/3 (432) → interleave (N=432, a=103) → scramble (cc/mcc/mnc/slot=0)
→ 432 type-5 = two 216-bit halves.

### NDB_BLK1 (216 type-5 bits, 7 registers 0x88–0xA0)

First half of SCH/F output. MSB-first. Concat: `{w0..w5, w6[23:0]}` → 216 bits.

### NDB_BLK2 (216 type-5 bits, 7 registers 0xA4–0xBC)

Second half of SCH/F output. Same layout as NDB_BLK1.

---

## NCO_PHASE_INC (0x80)

TX NCO phase accumulator increment. Shifts the TX signal away from LO leakage.

Formula: `phase_inc = f_offset_hz × 2^32 / 4608000`

| Offset (Hz) | phase_inc (hex) | Notes |
|-------------|-----------------|-------|
| 25,000      | 0x0163_8E90     | Too close to LO (~8 dB separation) |
| 100,000     | 0x058E_38E3     | Good (48 dB separation) |
| **106,000** | **0x05E3_8E39** | **Default — signal at 440.106 MHz when TX_LO=440 MHz** |

---

## Software Access Example

```c
// From sw/tetra_hal.h:
#define TETRA_AXI_BASE      0x43C00000

// Enable RX+TX (CTRL = 0x03):
tetra_reg_write(&hal, REG_CTRL, CTRL_RX_EN | CTRL_TX_EN);

// Enable PRBS test mode (spectrum verification):
tetra_reg_write(&hal, REG_TX_TEST, 1);

// Poll for PLL lock:
while (!(tetra_reg_read(&hal, REG_STATUS) & STATUS_PLL_LOCKED));
```

---

## Notes

- All registers are 32-bit, word-aligned. Byte/halfword access is not supported.
- RO registers: write has no effect (WENA masked in RTL)
- R/W1C (IRQ_STATUS): writing a '1' to a bit clears it; writing '0' has no effect
- VERSION register: bits [31:16] = major, [15:0] = minor. Current: 0x00010000 = v1.0
- SCRATCH register: useful for software self-test of AXI bus connectivity
- TX_TEST PRBS overrides FC/STS/NTS fixed patterns too — spectrum-level test only, not decodable.
