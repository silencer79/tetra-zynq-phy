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
| 0x40   | SB_BKN1_0         | R/W    | 0x0000_0000| BSCH bkn1 word 0 (bits [239:208])    |
| 0x44   | SB_BKN1_1         | R/W    | 0x0000_0000| BSCH bkn1 word 1 (bits [207:176])    |
| 0x48   | SB_BKN1_2         | R/W    | 0x0000_0000| BSCH bkn1 word 2 (bits [175:144])    |
| 0x4C   | SB_BKN1_3         | R/W    | 0x0000_0000| BSCH bkn1 word 3 (bits [143:112])    |
| 0x50   | SB_BKN1_4         | R/W    | 0x0000_0000| BSCH bkn1 word 4 (bits [111:80])     |
| 0x54   | SB_BKN1_5         | R/W    | 0x0000_0000| BSCH bkn1 word 5 (bits [79:48])      |
| 0x58   | SB_BKN1_6         | R/W    | 0x0000_0000| BSCH bkn1 word 6 (bits [47:16])      |
| 0x5C   | SB_BKN1_7         | R/W    | 0x0000_0000| BSCH bkn1 word 7 (bits [15:0])       |
| 0x60   | SB_BKN2_0         | R/W    | 0x0000_0000| BNCH bkn2 word 0 (bits [215:184])    |
| 0x64   | SB_BKN2_1         | R/W    | 0x0000_0000| BNCH bkn2 word 1 (bits [183:152])    |
| 0x68   | SB_BKN2_2         | R/W    | 0x0000_0000| BNCH bkn2 word 2 (bits [151:120])    |
| 0x6C   | SB_BKN2_3         | R/W    | 0x0000_0000| BNCH bkn2 word 3 (bits [119:88])     |
| 0x70   | SB_BKN2_4         | R/W    | 0x0000_0000| BNCH bkn2 word 4 (bits [87:56])      |
| 0x74   | SB_BKN2_5         | R/W    | 0x0000_0000| BNCH bkn2 word 5 (bits [55:24])      |
| 0x78   | SB_BKN2_6         | R/W    | 0x0000_0000| BNCH bkn2 word 6 (bits [23:0])       |
| 0x7C   | SB_BB             | R/W    | 0x0000_0000| AACH bb (bits [27:0])                |
| 0x80   | NCO_PHASE_INC     | R/W    | 0x0000_0000| TX NCO phase increment [31:0]        |

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

---

## Software Access Example

```c
// From sw/tetra_hal.h:
#define TETRA_BASE_ADDR     0x43C00000UL

#define TETRA_CTRL          (TETRA_BASE_ADDR + 0x00)
#define TETRA_STATUS        (TETRA_BASE_ADDR + 0x04)
#define TETRA_SYNC_THRESH   (TETRA_BASE_ADDR + 0x0C)
#define TETRA_COLOUR_CODE   (TETRA_BASE_ADDR + 0x10)

#define CTRL_RX_ENABLE      (1U << 0)
#define STATUS_SYNC_LOCKED  (1U << 0)

// Enable RX:
*(volatile uint32_t *)TETRA_CTRL = CTRL_RX_ENABLE;

// Poll for sync lock:
while (!(*(volatile uint32_t *)TETRA_STATUS & STATUS_SYNC_LOCKED));
```

---

## SB Payload Registers (0x40–0x7C)

Written by PS software (`tetra_sysinfo`) with fully coded type-5 bits for
Synchronization Burst transmission. The FPGA burst_builder shifts them out
as π/4-DQPSK symbols — no further coding in hardware.

### BKN1 (BSCH — 240 type-5 bits, 8 registers)

Channel coding chain (EN 300 392-2 §8):
SYSINFO PDU (60 type-1) → CRC-16 (76) → tail (80) → RCPC 1/3 (240) → interleave → scramble

Bit ordering: MSB-first. Register word 0 bit 31 = first transmitted bit.
FPGA concatenation: `{w0, w1, w2, w3, w4, w5, w6, w7[15:0]}` → 240-bit bus.

### BKN2 (BNCH — 216 type-5 bits, 7 registers)

Currently all zeros (time broadcast not yet implemented).
SB mode transmits 81 symbols (162 bits) from the 216-bit register.

### BB (AACH — 28 type-5 bits, 1 register)

Access Assignment Channel: 14 info bits → RM(30,14) → 30 coded bits → upper 28.
Packed MSB-first in bits [27:0] of the register.

### NCO_PHASE_INC (0x80)

TX NCO phase accumulator increment. Shifts the TX signal away from LO leakage.

Formula: `phase_inc = f_offset_hz × 2^32 / 4608000`

| Offset (Hz) | phase_inc (hex) | Notes |
|-------------|-----------------|-------|
| 25,000      | 0x0163_8E90     | Too close to LO (~8 dB separation) |
| 100,000     | 0x058E_38E3     | Good (48 dB separation) |
| **106,000** | **0x05E3_8E39** | **Default — signal at 439.100 MHz** |

---

## Notes

- All registers are 32-bit, word-aligned. Byte/halfword access is not supported.
- RO registers: write has no effect (WENA masked in RTL)
- R/W1C (IRQ_STATUS): writing a '1' to a bit clears it; writing '0' has no effect
- VERSION register: bits [31:16] = major, [15:0] = minor. Current: 0x00010000 = v1.0
- SCRATCH register: useful for software self-test of AXI bus connectivity
