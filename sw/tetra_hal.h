/*
 * tetra_hal.h — TETRA PHY/LMAC Hardware Abstraction Layer
 *
 * Userspace register access via /dev/mem mmap.
 * Channel coding for SYSINFO broadcast (CRC-16, RCPC, interleaver, scrambler).
 *
 * Target: LibreSDR (Zynq-7020), armv7l
 * License: GPL v2
 */

#ifndef TETRA_HAL_H
#define TETRA_HAL_H

#include <stdint.h>
#include <stdbool.h>

/* ========================================================================
 * AXI-Lite Register Map (base = 0x43C0_0000)
 * ======================================================================== */

#define TETRA_AXI_BASE      0x43C00000
#define TETRA_AXI_SIZE      0x1000

/* Control / Status registers */
#define REG_CTRL            0x00
#define REG_STATUS          0x04
#define REG_VERSION         0x08
#define REG_SYNC_THRESH     0x0C
#define REG_COLOUR_CODE     0x10
#define REG_FRAME_NUM       0x14
#define REG_SLOT_NUM        0x18
#define REG_RX_GAIN         0x1C
#define REG_TX_ATT          0x20
#define REG_IRQ_ENABLE      0x24
#define REG_IRQ_STATUS      0x28
#define REG_DMA_BLK_CNT     0x2C
#define REG_CRC_ERR_CNT     0x30
#define REG_SYNC_LST_CNT    0x34
#define REG_TX_TDMA         0x38  /* RO: [12:7] tx_mf, [6:2] tx_frame, [1:0] tx_slot */
#define REG_SCRATCH         0x3C

/* CTRL register bits */
#define CTRL_RX_EN          (1 << 0)
#define CTRL_TX_EN          (1 << 1)
#define CTRL_LOOPBACK       (1 << 2)
#define CTRL_RST_CNTRS      (1 << 3)

/* STATUS register bits */
#define STATUS_SYNC_LOCKED  (1 << 0)
#define STATUS_PLL_LOCKED   (1 << 1)
#define STATUS_FIFO_EMPTY   (1 << 2)
#define STATUS_FIFO_FULL    (1 << 3)

/* SB Payload registers (PS-writable broadcast data for TX chain) */
#define REG_SB_SB1_0       0x40  /* sb1 word 0 (bits [119:88])  */
#define REG_SB_SB1_1       0x44  /* sb1 word 1 (bits [87:56])   */
#define REG_SB_SB1_2       0x48  /* sb1 word 2 (bits [55:24])   */
#define REG_SB_SB1_3       0x4C  /* sb1 word 3 (bits [23:0])    */
/* 0x50–0x5C: unused (freed from old 240-bit bkn1) */
#define REG_SB_BKN2_0      0x60  /* bkn2 word 0 (bits [215:184])*/
#define REG_SB_BKN2_1      0x64  /* bkn2 word 1 (bits [183:152])*/
#define REG_SB_BKN2_2      0x68  /* bkn2 word 2 (bits [151:120])*/
#define REG_SB_BKN2_3      0x6C  /* bkn2 word 3 (bits [119:88]) */
#define REG_SB_BKN2_4      0x70  /* bkn2 word 4 (bits [87:56])  */
#define REG_SB_BKN2_5      0x74  /* bkn2 word 5 (bits [55:24])  */
#define REG_SB_BKN2_6      0x78  /* bkn2 word 6 (bits [23:0])   */
#define REG_SB_BB           0x7C  /* bb word 0   (bits [29:0])   */
#define REG_TX_TEST        0x84  /* [0] PRBS enable              */

/* NDB block1/block2 payload registers (216 bits each, broadcast to all 4 slots).
 * Channel-coded SCH/F filler fills NDB bursts with scrambled modulated content
 * so the spectrum is continuous instead of narrow-CW from an all-zero payload.
 * Scrambled with slot_num=1 (MCCH) — only slot 1 descrambles correctly. */
#define REG_NDB_BLK1_0     0x88  /* block1 word 0 (bits [215:184]) */
#define REG_NDB_BLK1_1     0x8C
#define REG_NDB_BLK1_2     0x90
#define REG_NDB_BLK1_3     0x94
#define REG_NDB_BLK1_4     0x98
#define REG_NDB_BLK1_5     0x9C
#define REG_NDB_BLK1_6     0xA0  /* block1 word 6 (bits [23:0] used) */
#define REG_NDB_BLK2_0     0xA4
#define REG_NDB_BLK2_1     0xA8
#define REG_NDB_BLK2_2     0xAC
#define REG_NDB_BLK2_3     0xB0
#define REG_NDB_BLK2_4     0xB4
#define REG_NDB_BLK2_5     0xB8
#define REG_NDB_BLK2_6     0xBC  /* block2 word 6 (bits [23:0] used) */

/* ========================================================================
 * HAL Context
 * ======================================================================== */

typedef struct {
    volatile uint32_t *regs;   /* mmap'd register pointer */
    int                fd;     /* /dev/mem file descriptor */
} tetra_hal_t;

/* ========================================================================
 * Synchronization Information (60 type-1 bits carried in BSCH sb1)
 *
 * This matches the field order used by real TETRA cells and by
 * `scripts/decode_sb.py --etsi`.
 * ======================================================================== */

typedef struct {
    uint8_t  system_code;              /* 4 bits */
    uint8_t  colour_code;              /* 6 bits */
    uint8_t  timeslot_assigned;        /* 2 bits */
    uint8_t  frame;                    /* 5 bits */
    uint8_t  multiframe;               /* 6 bits */
    uint8_t  sharing_mode;             /* 2 bits */
    uint8_t  ts_reserved_frames;       /* 3 bits */
    uint8_t  u_plane;                  /* U-plane DTX, 1 bit */
    uint8_t  frame_18_extension;       /* 1 bit */
    uint16_t mcc;                      /* 10 bits */
    uint16_t mnc;                      /* 14 bits */
    uint8_t  neighbour_cell_broadcast; /* 2 bits */
    uint8_t  cell_service_level;       /* 2 bits */
    uint8_t  late_entry_info;          /* 1 bit */

    /* BNCH SYSINFO fields (EN 300 392-2 §18.4.2.1, MAC-BROADCAST type 00) */
    uint32_t dl_freq_hz;               /* DL frequency in Hz (auto → band + carrier) */
    uint16_t la;                       /* Location Area, 14 bits */
    uint16_t hyperframe;               /* Hyperframe number, 16 bits (0–65535, wraps) */
    uint8_t  duplex_spacing;           /* 3 bits */
    uint8_t  ms_txpwr_max_cell;        /* 3 bits */
    uint8_t  rxlevel_access_min;       /* 4 bits */
    uint8_t  access_parameter;         /* 4 bits */
    uint8_t  radio_dl_timeout;         /* 4 bits */
    uint32_t optional_field_value;     /* 20 bits */
    uint8_t  priority_cell;            /* 1 bit */
    uint8_t  migration_supported;      /* 1 bit */

    /* Deprecated project-internal fields kept for source compatibility. */
    uint8_t  frame_countdown;
    uint8_t  access_code;
    uint8_t  dl_usage;
} tetra_sysinfo_t;

/* ========================================================================
 * HAL Functions
 * ======================================================================== */

/* Initialize HAL: mmap /dev/mem, returns 0 on success */
int tetra_hal_init(tetra_hal_t *hal);

/* Cleanup HAL: munmap, close fd */
void tetra_hal_close(tetra_hal_t *hal);

/* Register access */
static inline uint32_t tetra_reg_read(tetra_hal_t *hal, uint32_t offset) {
    return hal->regs[offset / 4];
}

static inline void tetra_reg_write(tetra_hal_t *hal, uint32_t offset, uint32_t value) {
    hal->regs[offset / 4] = value;
}

/* ========================================================================
 * Channel Coding Functions (EN 300 392-2 section 8)
 * ======================================================================== */

/* CRC-16-CCITT: polynomial x^16 + x^12 + x^5 + 1 (0x1021)
 * Returns 16-bit CRC appended to data.
 * bits: array of uint8_t, each element is 0 or 1
 * len: number of bits
 * out: output array (len + 16 elements), caller must allocate */
void tetra_crc16(const uint8_t *bits, int len, uint8_t *out);

/* RCPC Encoder: K=5, mother rate 1/3, G1=0x1B G2=0x19 G3=0x15
 * Puncturing pattern selects output rate.
 * bits: input bits (after CRC)
 * len: input length
 * out: output coded bits, caller must allocate (up to 3× input)
 * Returns number of output bits. */
int tetra_rcpc_encode(const uint8_t *bits, int len, uint8_t *out, int punct_pattern);

/* Block Interleaver: column-write, row-read
 * bits: input coded bits
 * len: block length (must match coding output)
 * out: interleaved bits, caller must allocate */
void tetra_interleave(const uint8_t *bits, int len, uint8_t *out);

/* Scrambler: LFSR-based XOR sequence
 * bits: input interleaved bits
 * len: number of bits
 * colour_code: 6-bit CC
 * slot_num: 2-bit timeslot number
 * out: scrambled bits, caller must allocate */
void tetra_scramble(const uint8_t *bits, int len, uint8_t *out,
                    uint8_t colour_code, uint8_t slot_num);

/* ========================================================================
 * High-Level Functions
 * ======================================================================== */

/* Build SYSINFO PDU, channel-code it, write to SB payload registers.
 * Returns 0 on success. */
int tetra_write_sysinfo(tetra_hal_t *hal, const tetra_sysinfo_t *info);

/* Build a SCH/F channel-coded filler payload (268 type-1 pseudo-random bits
 * -> CRC-16 -> tail -> RCPC 2/3 -> interleave N=432 a=103 -> scramble) and
 * write the two 216-bit halves to the NDB_BLK1 and NDB_BLK2 register banks.
 * The same 216+216 filler is broadcast to all 4 NDB slots by the FPGA.
 * Returns 0 on success. */
int tetra_write_ndb_filler(tetra_hal_t *hal, uint8_t colour_code,
                            uint16_t mcc, uint16_t mnc);

/* Enable TX+RX (CTRL = 0x03), optionally set SYNC_THRESH */
void tetra_enable(tetra_hal_t *hal, uint8_t sync_thresh);

/* Print status registers to stdout */
void tetra_print_status(tetra_hal_t *hal);

#endif /* TETRA_HAL_H */
