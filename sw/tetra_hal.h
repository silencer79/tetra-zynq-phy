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

/* Schedule-BRAM window: 144 words (2 × 16-bit entries per word) = 288 slots
 * per hyperframe (MN 0..59 × FN 0..17 × TN 0..3 → 4320 slots across a full
 * hyperframe; schedule repeats every multiframe, so 72 FN×TN entries).
 * Dense index = mn*72 + fn*4 + tn, pairs of entries packed low/high. */
#define REG_SCHEDULE_BASE   0x400
#define TETRA_SCHEDULE_WORDS 144

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
#define REG_SIGNAL_TARGET_TN 0x19C /* R/W [1:0]: on-air TN where DL signalling PDUs (MLE/CMCE/SDS) land */
#define REG_CELL_LA          0x1A0 /* R/W [13:0]: cell Location Area — must match BNCH SYSINFO info.la */

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
#define REG_SB_COMMIT       0x5C  /* write any value → atomic shadow→live commit */
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

/* MCCH (slot 1) dedicated block1/block2 registers — ACCESS-DEFINE PDU */
#define REG_MCCH_BLK1_0    0xC0  /* mcch block1 word 0 (bits [215:184]) */
#define REG_MCCH_BLK1_1    0xC4
#define REG_MCCH_BLK1_2    0xC8
#define REG_MCCH_BLK1_3    0xCC
#define REG_MCCH_BLK1_4    0xD0
#define REG_MCCH_BLK1_5    0xD4
#define REG_MCCH_BLK1_6    0xD8  /* mcch block1 word 6 (bits [23:0] used) */
#define REG_MCCH_BLK2_0    0xDC  /* mcch block2 word 0 (bits [215:184]) */
#define REG_MCCH_BLK2_1    0xE0
#define REG_MCCH_BLK2_2    0xE4
#define REG_MCCH_BLK2_3    0xE8
#define REG_MCCH_BLK2_4    0xEC
#define REG_MCCH_BLK2_5    0xF0
#define REG_MCCH_BLK2_6    0xF4  /* mcch block2 word 6 (bits [23:0] used) */

/* BNCH (frame 18, rotating slot) block1/block2 registers — SCH/HD encoded */
#define REG_BNCH_BLK1_0    0xF8   /* bnch block1 word 0 (bits [215:184]) */
#define REG_BNCH_BLK1_1    0xFC
#define REG_BNCH_BLK1_2    0x100
#define REG_BNCH_BLK1_3    0x104
#define REG_BNCH_BLK1_4    0x108
#define REG_BNCH_BLK1_5    0x10C
#define REG_BNCH_BLK1_6    0x110  /* bnch block1 word 6 (bits [23:0] used) */
#define REG_BNCH_BLK2_0    0x114  /* bnch block2 word 0 (bits [215:184]) */
#define REG_BNCH_BLK2_1    0x118
#define REG_BNCH_BLK2_2    0x11C
#define REG_BNCH_BLK2_3    0x120
#define REG_BNCH_BLK2_4    0x124
#define REG_BNCH_BLK2_5    0x128
#define REG_BNCH_BLK2_6    0x12C  /* bnch block2 word 6 (bits [23:0] used) */

/* Cell-config registers (feed RTL BSCH encoder, Plan Stufe 3.5)
 * CELL_CFG_0 bit layout:
 *   [3:0]   system_code
 *   [5:4]   sharing_mode
 *   [8:6]   ts_reserved_frames
 *   [9]     u_plane
 *   [10]    frame_18_extension
 *   [12:11] neighbour_cell_broadcast
 *   [14:13] cell_service_level
 *   [15]    late_entry_support
 * CELL_CFG_1 bit layout:
 *   [9:0]   mcc
 *   [23:10] mnc */
#define REG_CELL_CFG_0     0x130
#define REG_CELL_CFG_1     0x134

/* TX TDMA timebase LOAD/STATE (Plan Stufe 2)
 * LOAD: [1:0]=TN, [6:2]=FN, [12:7]=MN, [18:13]=HN, [31]=STROBE
 * STATE (RO): same layout + [26:19]=sym_cnt */
#define REG_TX_TDMA_LOAD   0x140
#define REG_TX_TDMA_STATE  0x144
#define TX_TDMA_LOAD_STROBE (1u << 31)

/* NULL PDU pre-coded 216-bit blob — static filler for idle slots
 * (class=NULL_PDU in schedule, Plan Stufe 4). */
#define REG_NULL_PDU_0     0x148
#define REG_NULL_PDU_1     0x14C
#define REG_NULL_PDU_2     0x150
#define REG_NULL_PDU_3     0x154
#define REG_NULL_PDU_4     0x158
#define REG_NULL_PDU_5     0x15C
#define REG_NULL_PDU_6     0x160  /* bits [23:0] used */

/* UL MAC-ACCESS PDU mailbox (Task #36/#37) — parsed MS RA-burst fields.
 * Bit layout per bluestation `mac_access.rs::from_bitbuf`.
 *   STATUS   : [0] valid_sticky, [1] pdu_type, [2] fill_bit, [3] enc_mode,
 *              [5:4] addr_type (0=Ssi, 1=EventLabel, 2=Ussi, 3=Smi),
 *              [6] optional_field_flag, [7] frag_flag,
 *              [11:8] reservation_req, [31:16] pdu_count
 *   SSI      : [23:0] full 24-bit MAC-ACCESS address (issi when addr_type
 *              ∈ {0,2,3}; lower 10 bits hold event_label when addr_type==1)
 *   RAW_0..2 : raw_info_bits[31:0]/[63:32]/[91:64]  (RAW_2 upper 4 bits RAZ)
 *   CTRL     : W1C [0] clears valid_sticky (hw-set-wins)
 *   SCRAMB_INIT : R/W 32-bit cell extended-scrambling seed
 *                 ((MCC<<22)|(MNC<<8)|(CC<<2)|3) — MCU writes once at boot */
#define REG_UL_PDU_STATUS    0x164
#define REG_UL_PDU_SSI       0x168
#define REG_UL_PDU_RAW_0     0x16C
#define REG_UL_PDU_RAW_1     0x170
#define REG_UL_PDU_RAW_2     0x174
#define REG_UL_PDU_CTRL      0x178
#define REG_UL_SCRAMB_INIT   0x17C

/* Subscriber-Shadow BRAM indirect write window (Phase 6 M2.3)
 *   INDEX    : [7:0] slot index 0..255
 *   DATA_LO  : bits [31:0]  of 64-bit shadow record
 *   DATA_HI  : bits [63:32] of 64-bit entity record
 *   CTRL     : W1S [0] commit pulse (self-clearing)
 * 64-bit record layout (Phase 6 D-rev §9.2, see rtl/lmac/tetra_entity_table.v):
 *   [63:40] entity_id (ISSI ODER GSSI),
 *   [39]    entity_type (0=ISSI, 1=GSSI),
 *   [38:35] profile_id (index into ProfileTable),
 *   [34:1]  reserved=0, [0] valid */
#define REG_SHADOW_INDEX     0x180
#define REG_SHADOW_DATA_LO   0x184
#define REG_SHADOW_DATA_HI   0x188
#define REG_SHADOW_CTRL      0x18C
#define SHADOW_CTRL_COMMIT   (1u << 0)

/* Profile-Table indirect window (Phase 6 D-rev §9.2) — 0x1C0..0x1CC.
 * 6 × 32-bit profile records.  No DATA_HI (record fits in one word).
 * 32-bit layout (see rtl/lmac/tetra_profile_table.v):
 *   [31:24] max_call_duration (sec, 0=unlimited)
 *   [23:16] hangtime          (×100 ms)
 *   [15:12] priority
 *   [11: 9] gila_class        (M2-default = 4)
 *   [ 8: 7] gila_lifetime     (M2-default = 1)
 *   [ 6: 4] reserved
 *   [ 3]    permit_voice
 *   [ 2]    permit_data
 *   [ 1]    permit_reg
 *   [ 0]    valid
 * Slot 0 reset-default = 0x0000_088F (M2 bit-identity guard). */
#define REG_PROFILE_INDEX    0x1C0
#define REG_PROFILE_DATA     0x1C4
#define REG_PROFILE_CTRL     0x1CC
#define PROFILE_CTRL_COMMIT  (1u << 0)

/* UL_PDU_STATUS bitfield helpers (bluestation-aligned bit layout) */
#define UL_STATUS_VALID(s)     (((s) >> 0)  & 0x1u)
#define UL_STATUS_PDU_TYPE(s)  (((s) >> 1)  & 0x1u)
#define UL_STATUS_FILL_BIT(s)  (((s) >> 2)  & 0x1u)
#define UL_STATUS_ENC_MODE(s)  (((s) >> 3)  & 0x1u)
#define UL_STATUS_ADDR_TYPE(s) (((s) >> 4)  & 0x3u)
#define UL_STATUS_OPT_FLAG(s)  (((s) >> 6)  & 0x1u)
#define UL_STATUS_FRAG_FLAG(s) (((s) >> 7)  & 0x1u)
#define UL_STATUS_RES_REQ(s)   (((s) >> 8)  & 0xFu)
#define UL_STATUS_PDU_COUNT(s) (((s) >> 16) & 0xFFFFu)

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

/* Build SYSINFO as SCH/HD (124 info bits per block → CRC-16 → tail →
 * RCPC rate 2/3 → interleave K=216 a=101 → scramble → 216 coded bits)
 * and write the two independent 216-bit blocks to BNCH_BLK1/BLK2 registers.
 * The FPGA selects these on the BNCH slot (frame 18, rotating TN).
 * Returns 0 on success. */
int tetra_write_bnch(tetra_hal_t *hal, const tetra_sysinfo_t *info,
                     uint8_t colour_code);

/* Pack sysinfo cell params into CELL_CFG_0/1 registers (RTL BSCH encoder
 * reads these directly — Plan Stufe 3.5). */
void tetra_write_cell_config(tetra_hal_t *hal, const tetra_sysinfo_t *info);

/* Build the 124-bit static NULL-PDU pattern, SCH/HD-encode with slot_num=1
 * scrambling, and write the 216-bit blob to REG_NULL_PDU_0..6 (Plan Stufe 4).
 * Returns 0 on success. */
int tetra_write_null_pdu(tetra_hal_t *hal, uint8_t colour_code,
                         uint16_t mcc, uint16_t mnc);

/* Copy the Gold-mimic schedule (tetra_gold_schedule[144] from
 * tetra_gold_schedule.h) into the schedule BRAM at REG_SCHEDULE_BASE. */
void tetra_write_gold_schedule(tetra_hal_t *hal);

/* Load initial TDMA timebase counters (TN/FN/MN/HN, all 0-based) with strobe.
 * Typically called once at boot with zeros so RTL starts at a known state. */
void tetra_tx_tdma_load(tetra_hal_t *hal,
                        uint8_t tn, uint8_t fn, uint8_t mn, uint8_t hn);

/* Enable TX+RX (CTRL = 0x03), optionally set SYNC_THRESH */
void tetra_enable(tetra_hal_t *hal, uint8_t sync_thresh);

/* Print status registers to stdout */
void tetra_print_status(tetra_hal_t *hal);

#endif /* TETRA_HAL_H */
