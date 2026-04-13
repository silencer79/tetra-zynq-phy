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
#define REG_SB_BKN1_0      0x40  /* bkn1 word 0 (bits [31:0])   */
#define REG_SB_BKN1_1      0x44  /* bkn1 word 1 (bits [63:32])  */
#define REG_SB_BKN1_2      0x48  /* bkn1 word 2 (bits [95:64])  */
#define REG_SB_BKN1_3      0x4C  /* bkn1 word 3 (bits [127:96]) */
#define REG_SB_BKN1_4      0x50  /* bkn1 word 4 (bits [159:128])*/
#define REG_SB_BKN1_5      0x54  /* bkn1 word 5 (bits [191:160])*/
#define REG_SB_BKN1_6      0x58  /* bkn1 word 6 (bits [223:192])*/
#define REG_SB_BKN1_7      0x5C  /* bkn1 word 7 (bits [239:224])*/
#define REG_SB_BKN2_0      0x60  /* bkn2 word 0 (bits [31:0])   */
#define REG_SB_BKN2_1      0x64  /* bkn2 word 1 (bits [63:32])  */
#define REG_SB_BKN2_2      0x68  /* bkn2 word 2 (bits [95:64])  */
#define REG_SB_BKN2_3      0x6C  /* bkn2 word 3 (bits [127:96]) */
#define REG_SB_BKN2_4      0x70  /* bkn2 word 4 (bits [159:128])*/
#define REG_SB_BKN2_5      0x74  /* bkn2 word 5 (bits [191:160])*/
#define REG_SB_BKN2_6      0x78  /* bkn2 word 6 (bits [215:192])*/
#define REG_SB_BB           0x7C  /* bb word 0   (bits [27:0])   */
#define REG_NCO_PHASE_INC  0x80  /* NCO phase increment [31:0]  */

/* ========================================================================
 * HAL Context
 * ======================================================================== */

typedef struct {
    volatile uint32_t *regs;   /* mmap'd register pointer */
    int                fd;     /* /dev/mem file descriptor */
} tetra_hal_t;

/* ========================================================================
 * SYSINFO PDU (EN 300 392-2 section 15.3.8)
 * ======================================================================== */

typedef struct {
    uint16_t mcc;              /* Mobile Country Code (0-1023, 10 bits) */
    uint16_t mnc;              /* Mobile Network Code (0-16383, 14 bits) */
    uint16_t la;               /* Location Area (0-16383, 14 bits) */
    uint8_t  colour_code;      /* Colour Code (0-63, 6 bits) */
    uint8_t  timeslot_assigned;/* Number of common ctrl timeslots (2 bits) */
    uint8_t  u_plane;          /* U-plane DTX (1 bit) */
    uint8_t  frame_countdown;  /* Frame 18 countdown (2 bits) */
    uint8_t  access_code;      /* Subscriber class (4 bits) */
    uint8_t  dl_usage;         /* DL usage marker (6 bits) */
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

/* Set TX NCO frequency offset in Hz (shifts signal away from LO leakage).
 * AD9361 TX LO should be set freq_hz lower than desired TX frequency. */
void tetra_set_nco_offset(tetra_hal_t *hal, int32_t freq_hz);

/* Enable TX+RX (CTRL = 0x03), optionally set SYNC_THRESH */
void tetra_enable(tetra_hal_t *hal, uint8_t sync_thresh);

/* Print status registers to stdout */
void tetra_print_status(tetra_hal_t *hal);

#endif /* TETRA_HAL_H */
