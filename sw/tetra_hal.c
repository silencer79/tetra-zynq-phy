/*
 * tetra_hal.c — TETRA PHY/LMAC Hardware Abstraction Layer
 *
 * Channel coding for SYSINFO broadcast (CRC-16, RCPC, interleaver, scrambler)
 * and AXI-Lite register access via /dev/mem mmap.
 *
 * The PS (ARM) computes fully coded type-5 bits and writes them to the
 * AXI-Lite SB payload registers.  The FPGA burst_builder shifts them out
 * as pi/4-DQPSK symbols — no further coding in hardware.
 *
 * Channel coding chain (EN 300 392-2 §8, continuous downlink burst):
 *   SYSINFO PDU (60 type-1) → CRC-16 (76 type-2) → tail (80 type-3)
 *   → ETSI RCPC rate 2/3 (120 type-4) → BSCH interleave (120)
 *   → scramble (120 type-5)
 *
 * Target: LibreSDR (Zynq-7020), armv7l, gcc cross-compile
 * License: GPL v2
 */

#include "tetra_hal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <getopt.h>

/* ========================================================================
 * HAL Init / Close
 * ======================================================================== */

int tetra_hal_init(tetra_hal_t *hal)
{
    hal->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (hal->fd < 0) {
        perror("tetra_hal: open /dev/mem");
        return -1;
    }
    hal->regs = mmap(NULL, TETRA_AXI_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, hal->fd, TETRA_AXI_BASE);
    if (hal->regs == MAP_FAILED) {
        perror("tetra_hal: mmap");
        close(hal->fd);
        return -1;
    }
    return 0;
}

void tetra_hal_close(tetra_hal_t *hal)
{
    if (hal->regs && hal->regs != MAP_FAILED)
        munmap((void *)hal->regs, TETRA_AXI_SIZE);
    if (hal->fd >= 0)
        close(hal->fd);
}

/* ========================================================================
 * CRC-16-CCITT  (EN 300 392-2 §7.2.1 / §8.2.3, X.25 / ITU-T FCS)
 * Polynomial: x^16 + x^12 + x^5 + 1 (0x1021)
 * Init: 0xFFFF, final FCS is the ONES-COMPLEMENT of the remainder.
 * Residual at the receiver over info+FCS: 0x1D0F (MSB-first) / 0xF0B8
 * (LSB-first reflected, as used by SDRSharp.Tetra.CRC16::Process).
 *
 * The one-bit inversion of every FCS bit is what distinguishes the ETSI
 * FCS from a "raw" CRC-CCITT remainder.  Dropping the inversion causes
 * every ETSI-compliant receiver (osmo-tetra, SDR#-Tetra plugin, …) to
 * reject our bursts even though the polynomial and init are correct.
 *
 * Input/output: arrays of uint8_t, each element is 0 or 1.
 * ======================================================================== */

void tetra_crc16(const uint8_t *bits, int len, uint8_t *out)
{
    uint16_t crc = 0xFFFF;

    memcpy(out, bits, len);

    for (int i = 0; i < len; i++) {
        int feedback = (bits[i] & 1) ^ ((crc >> 15) & 1);
        crc <<= 1;
        if (feedback)
            crc ^= 0x1021;
    }

    /* X.25 final XOR: append ones-complement of the remainder, MSB first */
    crc ^= 0xFFFF;
    for (int i = 0; i < 16; i++)
        out[len + i] = (crc >> (15 - i)) & 1;
}

/* ========================================================================
 * RCPC Encoder  (EN 300 392-2 §8.2.3)
 *
 * K=5 convolutional encoder, mother rate 1/3.
 * Generators (octal): G1=33 G2=31 G3=25
 *   G1 = 11011 = 0x1B
 *   G2 = 11001 = 0x19
 *   G3 = 10101 = 0x15
 *
 * Shift register convention: MSB = newest input bit.
 * Output order per input bit: G1, G2, G3.
 *
 * Puncturing patterns (punct_pattern):
 *   0 = rate 1/3  (no puncturing — BSCH, 80 → 240)
 *   1 = rate 2/3  (period 2, BNCH)
 * ======================================================================== */

static inline int parity5(uint8_t x)
{
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1;
}

int tetra_rcpc_encode(const uint8_t *bits, int len, uint8_t *out,
                      int punct_pattern)
{
    uint8_t sr = 0;   /* 5-bit shift register */
    int idx = 0;

    for (int i = 0; i < len; i++) {
        sr = ((sr << 1) | (bits[i] & 1)) & 0x1F;

        uint8_t g1 = parity5(sr & 0x1B);
        uint8_t g2 = parity5(sr & 0x19);
        uint8_t g3 = parity5(sr & 0x15);

        switch (punct_pattern) {
        case 0: /* rate 1/3 — keep all */
            out[idx++] = g1;
            out[idx++] = g2;
            out[idx++] = g3;
            break;
        case 1: /* rate 2/3 — period 2: keep G1,G2 on even; G1 on odd */
            if (i % 2 == 0) {
                out[idx++] = g1;
                out[idx++] = g2;
            } else {
                out[idx++] = g1;
            }
            break;
        default:
            /* Unknown pattern — output all (safe fallback) */
            out[idx++] = g1;
            out[idx++] = g2;
            out[idx++] = g3;
            break;
        }
    }
    return idx;
}

/* ========================================================================
 * ETSI BSCH RCPC Encoder  (EN 300 392-2 §8.2.3.1.1 / §8.2.3.1.3)
 *
 * Real TETRA BSCH uses a K=5 mother rate-1/4 code with generators:
 *   G1 = 0x13, G2 = 0x1D, G3 = 0x17, G4 = 0x1B
 * and puncturing P_2/3 over two input bits:
 *   keep {g1(a), g2(a), g1(b)}  => 3 output bits / 2 input bits
 * ======================================================================== */

static int tetra_etsi_conv_encode_r14(const uint8_t *bits, int len, uint8_t *out)
{
    uint8_t sr = 0;
    int idx = 0;

    for (int i = 0; i < len; i++) {
        sr = ((sr << 1) | (bits[i] & 1)) & 0x1F;
        out[idx++] = parity5(sr & 0x13);
        out[idx++] = parity5(sr & 0x1D);
        out[idx++] = parity5(sr & 0x17);
        out[idx++] = parity5(sr & 0x1B);
    }
    return idx;
}

static int tetra_etsi_puncture_r23(const uint8_t *bits_r14, int len, uint8_t *out)
{
    int idx = 0;

    if ((len % 8) != 0)
        return -1;

    for (int i = 0; i < len; i += 8) {
        out[idx++] = bits_r14[i + 0];  /* g1(a) */
        out[idx++] = bits_r14[i + 1];  /* g2(a) */
        out[idx++] = bits_r14[i + 4];  /* g1(b) */
    }
    return idx;
}

/* Multiplicative (permutation) interleaver — ETSI EN 300 392-2 §8.2.4.1
 *   out[k-1] = in[j-1] where j = 1 + (a*k) mod N, k=1..N
 * Parameters per Table 8.19:
 *   BSCH sb1:  N=120, a=11
 *   BNCH / SCH/HD / SCH/HU / STCH: N=216, a=101
 *   SCH/F / TCH/2.4:               N=432, a=103
 */
static void tetra_interleave_perm(const uint8_t *in, int N, int a, uint8_t *out)
{
    for (int k = 1; k <= N; k++) {
        int j = 1 + ((a * k) % N);
        out[j - 1] = in[k - 1];
    }
}

static void tetra_interleave_bsch_etsi(const uint8_t *in, uint8_t *out)
{
    tetra_interleave_perm(in, 120, 11, out);
}

/* ========================================================================
 * Block Interleaver  (EN 300 392-2 §8.2.4)
 *
 * Column-write, row-read.
 * Matrix dimensions depend on block length:
 *   240 → 16 rows × 15 columns  (BSCH)
 *   216 → 24 rows ×  9 columns  (BNCH)
 *   162 → 18 rows ×  9 columns  (SB bkn2)
 *    28 →  4 rows ×  7 columns  (AACH)
 * ======================================================================== */

void tetra_interleave(const uint8_t *bits, int len, uint8_t *out)
{
    int R, C;
    switch (len) {
    case 240: R = 16; C = 15; break;
    case 216: R = 24; C =  9; break;
    case 162: R = 18; C =  9; break;
    case 120: R =  8; C = 15; break;  /* BSCH continuous downlink */
    case  28: R =  4; C =  7; break;
    default:  /* No interleaving — pass through */
        memcpy(out, bits, len);
        return;
    }

    /*
     * Write column-by-column: input bit k → row (k%R), col (k/R)
     * Read row-by-row:        output position = row*C + col
     */
    for (int k = 0; k < len; k++) {
        int row = k % R;
        int col = k / R;
        out[row * C + col] = bits[k];
    }
}

/* ========================================================================
 * Scrambler  (EN 300 392-2 §8.2.5)
 *
 * 32-bit Fibonacci LFSR, shift-right, output = feedback bit.
 * Taps: 32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1
 * (same polynomial as CRC-32 / IEEE 802.3)
 *
 * IMPORTANT: Must be Fibonacci form — Galois form produces a different
 * sequence (confirmed by osmo-tetra: Galois "does not produce the
 * desired result").
 *
 * Initialization (§8.2.5.2):
 *   For SCH/F, SCH/HD, STCH, TCH:
 *     init = (colour | (mnc << 6) | (mcc << 20)) << 2 | TN
 *   For BSCH (Synchronization Burst bkn1):
 *     init = SCRAMB_INIT = 3 (fixed, before cell identity is known)
 * ======================================================================== */

#define SCRAMB_INIT  3u

#define ST(x, y) ((x) >> (32-(y)))

static uint8_t next_lfsr_bit(uint32_t *lf)
{
    uint32_t lfsr = *lf;
    uint32_t bit;

    /* taps: 32 26 23 22 16 12 11 10 8 7 5 4 2 1 */
    bit = (ST(lfsr, 32) ^ ST(lfsr, 26) ^ ST(lfsr, 23) ^ ST(lfsr, 22) ^
           ST(lfsr, 16) ^ ST(lfsr, 12) ^ ST(lfsr, 11) ^ ST(lfsr, 10) ^
           ST(lfsr,  8) ^ ST(lfsr,  7) ^ ST(lfsr,  5) ^ ST(lfsr,  4) ^
           ST(lfsr,  2) ^ ST(lfsr,  1)) & 1;
    lfsr = (lfsr >> 1) | (bit << 31);

    *lf = lfsr;
    return bit & 0xff;
}

static uint32_t scrambler_init(uint8_t colour_code, uint8_t slot_num,
                               uint16_t mcc, uint16_t mnc)
{
    uint32_t init;

    init = (colour_code & 0x3F) | ((uint32_t)(mnc & 0x3FFF) << 6)
           | ((uint32_t)(mcc & 0x3FF) << 20);
    init = (init << 2) | (slot_num & 0x03);
    return init;
}

void tetra_scramble(const uint8_t *bits, int len, uint8_t *out,
                    uint8_t colour_code, uint8_t slot_num)
{
    uint32_t lfsr = scrambler_init(colour_code, slot_num, 0, 0);
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;

    for (int i = 0; i < len; i++)
        out[i] = (bits[i] ^ next_lfsr_bit(&lfsr)) & 1;
}

static void tetra_scramble_bsch(const uint8_t *bits, int len, uint8_t *out)
{
    uint32_t lfsr = SCRAMB_INIT;

    for (int i = 0; i < len; i++)
        out[i] = (bits[i] ^ next_lfsr_bit(&lfsr)) & 1;
}

/* ========================================================================
 * Synchronization Information Builder (60 type-1 bits)
 *
 * Field order matches the ETSI sync-info layout used by real cells and by the
 * decoder's `parse_sysinfo()` helper:
 *   SystemCode(4), ColorCode(6), TimeSlot(2), Frame(5), MultiFrame(6),
 *   SharingMode(2), TSReservedFrames(3), UPlaneDTX(1), Frame18Extension(1),
 *   Reserved(1), MCC(10), MNC(14), NeighbourCellBroadcast(2),
 *   CellServiceLevel(2), LateEntryInfo(1)
 * ======================================================================== */

#define SYSINFO_BITS      60
#define SYSINFO_CRC_BITS  (SYSINFO_BITS + 16)   /* 76 */
#define SYSINFO_TAIL_BITS (SYSINFO_CRC_BITS + 4) /* 80 */
#define BSCH_CODED_BITS   120  /* RCPC 2/3 for continuous downlink burst */
#define BNCH_INFO_BITS    124
#define BNCH_CRC_BITS     (BNCH_INFO_BITS + 16)  /* 140 */
#define BNCH_TAIL_BITS    (BNCH_CRC_BITS + 4)    /* 144 */
#define BNCH_CODED_BITS   216
#define AACH_BITS         30   /* RM(30,14) full output for continuous burst */
#define BKN2_CODED_BITS   216

static void pack_bits(uint8_t *out, int *pos, uint32_t value, int nbits)
{
    for (int i = nbits - 1; i >= 0; i--)
        out[(*pos)++] = (value >> i) & 1;
}

static void build_sysinfo_pdu(const tetra_sysinfo_t *info, uint8_t *bits)
{
    int pos = 0;
    pack_bits(bits, &pos, info->system_code,               4);
    pack_bits(bits, &pos, info->colour_code,               6);
    pack_bits(bits, &pos, info->timeslot_assigned,         2);
    pack_bits(bits, &pos, info->frame,                     5);
    pack_bits(bits, &pos, info->multiframe,                6);
    pack_bits(bits, &pos, info->sharing_mode,              2);
    pack_bits(bits, &pos, info->ts_reserved_frames,        3);
    pack_bits(bits, &pos, info->u_plane,                   1);
    pack_bits(bits, &pos, info->frame_18_extension,        1);
    pack_bits(bits, &pos, 0,                               1);
    pack_bits(bits, &pos, info->mcc,                      10);
    pack_bits(bits, &pos, info->mnc,                      14);
    pack_bits(bits, &pos, info->neighbour_cell_broadcast,  2);
    pack_bits(bits, &pos, info->cell_service_level,        2);
    pack_bits(bits, &pos, info->late_entry_info,           1);
}

/* ========================================================================
 * RM(30,14) Reed-Muller Code  (EN 300 392-2 §8.2.3.2)
 *
 * Systematic (30,14) code: upper 14 bits = info, lower 16 bits = parity.
 * Generator matrix from Table 8.11 of the standard.
 * ======================================================================== */

static const uint8_t rm_30_14_gen[14][16] = {
    { 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0 },
    { 0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
    { 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 },
    { 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0 },
    { 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 0 },
    { 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0 },
    { 0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0 },
    { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1 },
    { 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1 },
    { 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1 },
    { 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1 },
    { 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1 },
    { 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1 },
    { 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1 }
};

static uint32_t rm_30_14_rows[14];

static void tetra_rm3014_init(void)
{
    for (int i = 0; i < 14; i++) {
        uint32_t val = (1u << (16 + 13 - i));  /* upper 14 bits: identity */
        for (int j = 0; j < 16; j++)            /* lower 16 bits: generator */
            val |= (uint32_t)rm_30_14_gen[i][j] << (15 - j);
        rm_30_14_rows[i] = val;
    }
}

static uint32_t tetra_rm3014_compute(uint16_t in)
{
    uint32_t val = 0;
    for (int i = 0; i < 14; i++) {
        if ((in >> (13 - i)) & 1)
            val ^= rm_30_14_rows[i];
    }
    return val;
}

/* ========================================================================
 * AACH Builder  (EN 300 392-2 §8.2.3.3)
 *
 * Access Assignment Channel — carries Colour Code in bb field.
 * 14 type-1 bits → RM(30,14) → 30 coded bits → take upper 28 for BB.
 *
 * AACH type-1 (14 bits):
 *   [0..5]  Header (fixed 0b000000 for DL main carrier)
 *   [6..11] Colour Code (6 bits)
 *   [12..13] Timeslot assignment (2 bits)
 * ======================================================================== */

static void build_aach(uint8_t colour_code, uint8_t ts_assign,
                       uint8_t *out30)
{
    uint8_t info[14];
    int pos = 0;

    /* Header: field1 = 0b0000 (downlink), field2 = 0b00 (main carrier) */
    pack_bits(info, &pos, 0x00, 6);
    pack_bits(info, &pos, colour_code, 6);
    pack_bits(info, &pos, ts_assign, 2);

    /* Pack 14 info bits into uint16_t for RM encoder */
    uint16_t in_word = 0;
    for (int i = 0; i < 14; i++)
        in_word |= (uint16_t)(info[i] & 1) << (13 - i);

    /* RM(30,14) encode → 30 bits, use all (continuous downlink burst) */
    uint32_t coded = tetra_rm3014_compute(in_word);
    for (int i = 0; i < 30; i++)
        out30[i] = (coded >> (29 - i)) & 1;
}

/* ========================================================================
 * Pack bit array into 32-bit AXI register words (MSB-first)
 *
 * bits[0] → MSB of word 0, bits[31] → LSB of word 0,
 * bits[32] → MSB of word 1, etc.
 * ======================================================================== */

static void bits_to_words(const uint8_t *bits, int nbits,
                          uint32_t *words, int nwords)
{
    memset(words, 0, nwords * sizeof(uint32_t));
    for (int i = 0; i < nbits; i++) {
        int w = i / 32;
        int b = 31 - (i % 32);
        if (bits[i])
            words[w] |= (1u << b);
    }
}

/* ========================================================================
 * BNCH Encoder — 124 type-1 bits → 216 type-5 bits (EN 300 392-2 §8.2.3.1)
 *
 *   info (124) → CRC-16 → type-2 (140) → +4 tail → type-3 (144)
 *   → ETSI rate-1/4 mother (576) → P_2/3 puncture (216 type-4)
 *   → multiplicative interleave K=216, a=101 (Table 8.19)
 *   → scramble (slot-specific init) → type-5 (216)
 *
 * Used for the SDB bkn2 field (slot 0 BNCH on continuous downlink).  The
 * scrambler uses the regular (cc, slot, mcc, mnc) init — not the BSCH-fixed
 * init=3 — because the receiver already knows cell identity once it has
 * decoded sb1.
 * ======================================================================== */

static int tetra_bnch_encode(const uint8_t *info_bits,
                              uint8_t colour_code, uint8_t slot_num,
                              uint16_t mcc, uint16_t mnc,
                              uint8_t *out_216)
{
    uint8_t type2[BNCH_CRC_BITS];
    uint8_t type3[BNCH_TAIL_BITS];
    uint8_t mother[BNCH_TAIL_BITS * 4];
    uint8_t type4[BNCH_CODED_BITS];
    uint8_t type4i[BNCH_CODED_BITS];

    tetra_crc16(info_bits, BNCH_INFO_BITS, type2);
    memcpy(type3, type2, BNCH_CRC_BITS);
    memset(type3 + BNCH_CRC_BITS, 0, 4);

    int m = tetra_etsi_conv_encode_r14(type3, BNCH_TAIL_BITS, mother);
    int c = tetra_etsi_puncture_r23(mother, m, type4);
    if (m != BNCH_TAIL_BITS * 4 || c != BNCH_CODED_BITS)
        return -1;

    /* Multiplicative interleaver, K=216, a=101 (ETSI §8.2.4.1 Table 8.19) */
    tetra_interleave_perm(type4, BNCH_CODED_BITS, 101, type4i);

    uint32_t lfsr = scrambler_init(colour_code, slot_num, mcc, mnc);
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;
    for (int i = 0; i < BNCH_CODED_BITS; i++)
        out_216[i] = (type4i[i] ^ next_lfsr_bit(&lfsr)) & 1;
    return 0;
}

/* ========================================================================
 * tetra_write_sysinfo — Full channel coding + register write
 *
 * BSCH (sb1, 120 type-5, continuous downlink §9.4.4.2.6):
 *   60 type-1 → CRC-16 → 76 type-2 → +4 tail → 80 type-3
 *   → ETSI rate-1/4 mother code + P_2/3 puncture → 120 type-4
 *   → multiplicative BSCH interleave (K=120, a=11) → scramble(init=3)
 *   → 120 type-5
 *
 * BNCH (bkn2, 216 type-5):
 *   124 pseudo-random type-1 (PN-filler) → full BNCH coding chain →
 *   216 scrambled type-5.  Ensures slot 0 carries broadband modulated
 *   content instead of a narrow-CW residue from an all-zero payload.
 *
 * AACH (bb, 30 type-5):
 *   14 info → RM(30,14) → 30 coded bits (full output, no truncation).
 * ======================================================================== */

int tetra_write_sysinfo(tetra_hal_t *hal, const tetra_sysinfo_t *info)
{
    /* --- BSCH: SYSINFO PDU → 120 coded bits (RCPC 2/3, continuous DL) --- */
    uint8_t type1[SYSINFO_BITS];
    uint8_t type2[SYSINFO_CRC_BITS];
    uint8_t type3[SYSINFO_TAIL_BITS];
    uint8_t type4_mother[SYSINFO_TAIL_BITS * 4];
    uint8_t type4[BSCH_CODED_BITS];
    uint8_t type4i[BSCH_CODED_BITS];
    uint8_t type5_sb1[BSCH_CODED_BITS];

    /* Step 1: Build PDU (60 type-1 bits) */
    build_sysinfo_pdu(info, type1);

    /* Step 2: CRC-16 (60 → 76 type-2 bits) */
    tetra_crc16(type1, SYSINFO_BITS, type2);

    /* Step 3: Append 4 tail bits (zeros) to flush encoder */
    memcpy(type3, type2, SYSINFO_CRC_BITS);
    memset(type3 + SYSINFO_CRC_BITS, 0, 4);

    /* Step 4: ETSI BSCH coding:
     *   80 input bits -> 320 mother bits (rate 1/4) -> puncture P_2/3 -> 120 */
    int mother = tetra_etsi_conv_encode_r14(type3, SYSINFO_TAIL_BITS, type4_mother);
    int coded = tetra_etsi_puncture_r23(type4_mother, mother, type4);
    if (mother != (SYSINFO_TAIL_BITS * 4) || coded != BSCH_CODED_BITS) {
        fprintf(stderr,
                "tetra_hal: BSCH ETSI coding mother=%d coded=%d expected=%d\n",
                mother, coded, BSCH_CODED_BITS);
        return -1;
    }

    /* Step 5: ETSI BSCH interleave (K=120, a=11) */
    tetra_interleave_bsch_etsi(type4, type4i);

    /* Step 6: Scramble (120 → 120 type-5 bits)
     * BSCH uses fixed scrambler init = SCRAMB_INIT = 3 (§8.2.5.2).
     * The cell identity (MCC/MNC/CC) is INSIDE the BSCH, so the receiver
     * can't derive the scrambler seed yet — hence the fixed init. */
    tetra_scramble_bsch(type4i, BSCH_CODED_BITS, type5_sb1);

    /* --- BNCH: pseudo-random filler → full channel coding (slot 0) ---
     * 124 info bits seeded from a 15-bit LFSR (x^15+x^14+1, seed 0x5A5A —
     * distinct from the NDB-filler seed 0x7FFF so bkn2 ≠ NDB content).
     * The full BNCH chain (CRC + tail + RCPC 2/3 + 24×9 interleave +
     * slot-0 scramble) guarantees the 216 type-5 bits are broadband,
     * eliminating the narrow-CW residue of an all-zero payload. */
    uint8_t bnch_info[BNCH_INFO_BITS];
    {
        uint16_t bnch_lfsr = 0x5A5Au;
        for (int i = 0; i < BNCH_INFO_BITS; i++) {
            uint16_t fb = ((bnch_lfsr >> 14) ^ (bnch_lfsr >> 13)) & 1u;
            bnch_lfsr = ((uint16_t)(bnch_lfsr << 1) | fb) & 0x7FFFu;
            bnch_info[i] = (bnch_lfsr >> 14) & 1u;
        }
    }

    uint8_t type5_bkn2[BKN2_CODED_BITS];
    if (tetra_bnch_encode(bnch_info, info->colour_code, 0,
                           info->mcc, info->mnc, type5_bkn2) != 0) {
        fprintf(stderr, "tetra_hal: BNCH filler encoding failed\n");
        return -1;
    }

    /* --- AACH: Colour Code broadcast --- */
    uint8_t type5_bb[AACH_BITS];
    build_aach(info->colour_code, info->timeslot_assigned, type5_bb);

    /* --- Pack into 32-bit words and write to AXI-Lite registers --- */
    uint32_t sb1_words[4];
    uint32_t bkn2_words[7];
    uint32_t bb_word;

    bits_to_words(type5_sb1, 120, sb1_words, 4);
    sb1_words[3] >>= 8;    /* align 24 remaining bits into [23:0] for FPGA w3 */
    bits_to_words(type5_bkn2, 216, bkn2_words, 7);
    bkn2_words[6] >>= 8;   /* align 24 remaining bits into [23:0] for FPGA w6 */
    bits_to_words(type5_bb, 30, &bb_word, 1);
    bb_word >>= 2;          /* align 30 remaining bits into [29:0] for FPGA */

    /* Write sb1 (4 registers: 0x40–0x4C) */
    for (int i = 0; i < 4; i++)
        tetra_reg_write(hal, REG_SB_SB1_0 + i * 4, sb1_words[i]);

    /* Write bkn2 (7 registers: 0x60–0x78) */
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_SB_BKN2_0 + i * 4, bkn2_words[i]);

    /* Write bb (1 register: 0x7C) */
    tetra_reg_write(hal, REG_SB_BB, bb_word);

    printf("SYSINFO written: SC=%u CC=%u TN=%u FN=%u MF=%u MCC=%u MNC=%u\n",
           info->system_code, info->colour_code, info->timeslot_assigned,
           info->frame, info->multiframe, info->mcc, info->mnc);

    return 0;
}

/* ========================================================================
 * SCH/F Encoder: 268 type-1 bits → 432 type-5 bits
 *
 *   info (268) → CRC-16 → type-2 (284) → +4 tail → type-3 (288)
 *   → ETSI rate-1/4 mother (1152) → P_2/3 puncture → type-4 (432)
 *   → multiplicative interleave K=432, a=103 → type-4' (432)
 *   → scramble → type-5 (432)
 *
 * Scrambler init: (cc | mnc<<6 | mcc<<20) << 2 | slot_num  (§8.2.5.2)
 * All 4 NDB slots receive the same 432 bits, so slot_num is fixed to 0
 * (scrambling is only "correct" for slot 0; slots 1-3 are modulated but
 * semantically invalid).
 * ======================================================================== */

#define SCHF_INFO_BITS   268
#define SCHF_CRC_BITS    (SCHF_INFO_BITS + 16)   /* 284 */
#define SCHF_TAIL_BITS   (SCHF_CRC_BITS + 4)     /* 288 */
#define SCHF_CODED_BITS  432

static int tetra_schf_encode(const uint8_t *info_bits,
                              uint8_t colour_code, uint8_t slot_num,
                              uint16_t mcc, uint16_t mnc,
                              uint8_t *out_432)
{
    uint8_t type2[SCHF_CRC_BITS];
    uint8_t type3[SCHF_TAIL_BITS];
    uint8_t mother[SCHF_TAIL_BITS * 4];
    uint8_t type4[SCHF_CODED_BITS];
    uint8_t type4i[SCHF_CODED_BITS];

    /* CRC-16 (ETSI X.25 FCS, complement applied inside tetra_crc16) */
    tetra_crc16(info_bits, SCHF_INFO_BITS, type2);
    /* Append 4 tail bits (zeros) */
    memcpy(type3, type2, SCHF_CRC_BITS);
    memset(type3 + SCHF_CRC_BITS, 0, 4);

    /* ETSI rate-1/4 mother code + P_2/3 puncture: 288 → 1152 → 432 */
    int m = tetra_etsi_conv_encode_r14(type3, SCHF_TAIL_BITS, mother);
    int c = tetra_etsi_puncture_r23(mother, m, type4);
    if (m != SCHF_TAIL_BITS * 4 || c != SCHF_CODED_BITS)
        return -1;

    /* Multiplicative interleaver, K=432, a=103 (ETSI §8.2.4.1 Table 8.19) */
    tetra_interleave_perm(type4, SCHF_CODED_BITS, 103, type4i);

    /* Scramble (§8.2.5) */
    uint32_t lfsr = scrambler_init(colour_code, slot_num, mcc, mnc);
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;
    for (int i = 0; i < SCHF_CODED_BITS; i++)
        out_432[i] = (type4i[i] ^ next_lfsr_bit(&lfsr)) & 1;
    return 0;
}

/* ========================================================================
 * tetra_write_ndb_filler — Fill NDB block1/block2 registers with a
 * channel-coded pseudo-random MAC-NULL-like payload.  Ensures all four
 * NDB slots carry modulated content (no narrow-CW from zero payload).
 * ======================================================================== */

int tetra_write_ndb_filler(tetra_hal_t *hal, uint8_t colour_code,
                            uint16_t mcc, uint16_t mnc)
{
    /* 268 type-1 info bits: 4-bit MAC-NULL PDU type (0) + 264 pseudo-random
     * filler from 15-bit LFSR (x^15 + x^14 + 1). */
    uint8_t info[SCHF_INFO_BITS];
    info[0] = 0; info[1] = 0; info[2] = 0; info[3] = 0;
    uint16_t lfsr = 0x7FFFu;
    for (int i = 4; i < SCHF_INFO_BITS; i++) {
        uint16_t fb = ((lfsr >> 14) ^ (lfsr >> 13)) & 1u;
        lfsr = ((uint16_t)(lfsr << 1) | fb) & 0x7FFFu;
        info[i] = (lfsr >> 14) & 1u;
    }

    uint8_t type5[SCHF_CODED_BITS];
    if (tetra_schf_encode(info, colour_code, 0, mcc, mnc, type5) != 0) {
        fprintf(stderr, "tetra_hal: SCH/F encoding failed\n");
        return -1;
    }

    /* Split 432 bits → block1[0..215] + block2[216..431] → 7+7 words */
    uint32_t blk1_words[7];
    uint32_t blk2_words[7];
    bits_to_words(&type5[0],   216, blk1_words, 7);
    blk1_words[6] >>= 8;   /* align 24 remaining bits into [23:0] */
    bits_to_words(&type5[216], 216, blk2_words, 7);
    blk2_words[6] >>= 8;

    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_NDB_BLK1_0 + i * 4, blk1_words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_NDB_BLK2_0 + i * 4, blk2_words[i]);

    printf("NDB filler written: 268-bit info -> 432 type-5 bits "
           "(CC=%u MCC=%u MNC=%u slot=0, broadcast all 4 slots)\n",
           colour_code, mcc, mnc);
    return 0;
}

/* ========================================================================
 * Control Functions
 * ======================================================================== */

/* Set TX NCO phase increment for LO offset.
 * phase_inc = (int32_t)(f_offset_hz * 4294967296.0 / 4608000.0)
 * Example: 25000 Hz → 23301840 (0x01638E90) */
void tetra_set_nco_offset(tetra_hal_t *hal, int32_t freq_hz)
{
    int32_t phase_inc = (int32_t)((double)freq_hz * 4294967296.0 / 4608000.0);
    tetra_reg_write(hal, REG_NCO_PHASE_INC, (uint32_t)phase_inc);
    printf("NCO offset: %d Hz (phase_inc=0x%08X)\n", freq_hz, (uint32_t)phase_inc);
}

void tetra_enable(tetra_hal_t *hal, uint8_t sync_thresh)
{
    if (sync_thresh > 0)
        tetra_reg_write(hal, REG_SYNC_THRESH, sync_thresh);

    /* Enable TX + RX */
    tetra_reg_write(hal, REG_CTRL, CTRL_TX_EN | CTRL_RX_EN);
    printf("TETRA PHY enabled (TX+RX)\n");
}

void tetra_print_status(tetra_hal_t *hal)
{
    uint32_t ver    = tetra_reg_read(hal, REG_VERSION);
    uint32_t status = tetra_reg_read(hal, REG_STATUS);
    uint32_t ctrl   = tetra_reg_read(hal, REG_CTRL);
    uint32_t frame  = tetra_reg_read(hal, REG_FRAME_NUM);
    uint32_t slot   = tetra_reg_read(hal, REG_SLOT_NUM);
    uint32_t crc_e  = tetra_reg_read(hal, REG_CRC_ERR_CNT);
    uint32_t sync_l = tetra_reg_read(hal, REG_SYNC_LST_CNT);

    printf("=== TETRA PHY Status ===\n");
    printf("VERSION:    0x%08X\n", ver);
    printf("CTRL:       0x%08X  [TX=%d RX=%d LB=%d]\n",
           ctrl, !!(ctrl & CTRL_TX_EN), !!(ctrl & CTRL_RX_EN),
           !!(ctrl & CTRL_LOOPBACK));
    printf("STATUS:     0x%08X  [SYNC=%d PLL=%d FIFO_E=%d FIFO_F=%d]\n",
           status,
           !!(status & STATUS_SYNC_LOCKED),
           !!(status & STATUS_PLL_LOCKED),
           !!(status & STATUS_FIFO_EMPTY),
           !!(status & STATUS_FIFO_FULL));
    printf("FRAME/SLOT: %u / %u\n", frame, slot);

    uint32_t tx_tdma = tetra_reg_read(hal, REG_TX_TDMA);
    printf("TX TDMA:    FN=%u MF=%u TN=%u\n",
           (tx_tdma >> 2) & 0x1F, (tx_tdma >> 7) & 0x3F, tx_tdma & 0x3);

    printf("CRC_ERR:    %u\n", crc_e);
    printf("SYNC_LOST:  %u\n", sync_l);
}

/* ========================================================================
 * main() — Standalone SYSINFO broadcaster
 *
 * Usage: tetra_sysinfo [--mcc N] [--mnc N] [--la N] [--cc N]
 *                      [--thresh N] [--status]
 * ======================================================================== */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "Write SYSINFO to TETRA PHY and enable TX+RX.\n"
        "\n"
        "  --mcc N       Mobile Country Code (0-1023, default 901=test)\n"
        "  --mnc N       Mobile Network Code (0-16383, default 1)\n"
        "  --la N        Location Area (0-16383, default 1)\n"
        "  --cc N        Colour Code (0-63, default 1)\n"
        "  --thresh N    Sync threshold (1-255, default 0=unchanged)\n"
        "  --nco N       TX NCO offset in Hz (default 25000)\n"
        "  --status      Print status registers and exit\n"
        "  --no-enable   Write SYSINFO but don't enable TX/RX\n"
        "  -h, --help    Show this help\n",
        prog);
}

int main(int argc, char *argv[])
{
    tetra_sysinfo_t info = {
        .mcc              = 901,   /* Test network (ITU-T E.212) */
        .mnc              = 1,
        .la               = 1,
        .colour_code      = 1,
        .timeslot_assigned = 1,    /* 1 common ctrl timeslot */
        .u_plane          = 0,
        .frame_countdown  = 0,
        .access_code      = 0x0F,  /* All subscriber classes allowed */
        .dl_usage         = 0x3F,  /* All slots available */
    };
    int sync_thresh = 0;
    int nco_offset_hz = 106000;
    int status_only = 0;
    int no_enable = 0;

    static struct option long_opts[] = {
        {"mcc",       required_argument, NULL, 'm'},
        {"mnc",       required_argument, NULL, 'n'},
        {"la",        required_argument, NULL, 'l'},
        {"cc",        required_argument, NULL, 'c'},
        {"thresh",    required_argument, NULL, 't'},
        {"nco",       required_argument, NULL, 'o'},
        {"status",    no_argument,       NULL, 's'},
        {"no-enable", no_argument,       NULL, 'x'},
        {"help",      no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "m:n:l:c:t:o:sxh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'm': info.mcc         = atoi(optarg); break;
        case 'n': info.mnc         = atoi(optarg); break;
        case 'l': info.la          = atoi(optarg); break;
        case 'c': info.colour_code = atoi(optarg); break;
        case 't': sync_thresh      = atoi(optarg); break;
        case 'o': nco_offset_hz    = atoi(optarg); break;
        case 's': status_only      = 1;            break;
        case 'x': no_enable        = 1;            break;
        case 'h': /* fall through */
        default:  usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }

    /* Validate ranges */
    if (info.mcc > 1023 || info.mnc > 16383 || info.la > 16383 ||
        info.colour_code > 63) {
        fprintf(stderr, "Error: parameter out of range\n");
        return 1;
    }

    /* Init RM(30,14) lookup table */
    tetra_rm3014_init();

    /* Init HAL */
    tetra_hal_t hal;
    if (tetra_hal_init(&hal) != 0)
        return 1;

    /* Check VERSION register sanity */
    uint32_t ver = tetra_reg_read(&hal, REG_VERSION);
    if (ver == 0x00000000 || ver == 0xFFFFFFFF) {
        fprintf(stderr, "Error: VERSION=0x%08X — FPGA not loaded or wrong base?\n", ver);
        tetra_hal_close(&hal);
        return 1;
    }

    if (status_only) {
        tetra_print_status(&hal);
        tetra_hal_close(&hal);
        return 0;
    }

    /* Initial SYSINFO write (frame=0, multiframe=0 — updated in loop) */
    if (tetra_write_sysinfo(&hal, &info) != 0) {
        tetra_hal_close(&hal);
        return 1;
    }

    /* Fill NDB block1/block2 with channel-coded SCH/F payload so slots 1-3
     * (and the NDB half of every even multiframe) carry modulated content
     * instead of narrow-CW from an all-zero payload. */
    if (tetra_write_ndb_filler(&hal, info.colour_code,
                                info.mcc, info.mnc) != 0) {
        tetra_hal_close(&hal);
        return 1;
    }

    /* Also write colour_code to the register for RX scrambler init */
    tetra_reg_write(&hal, REG_COLOUR_CODE,
                    scrambler_init(info.colour_code, 0,
                                   info.mcc, info.mnc));

    /* Set TX NCO offset to shift signal away from LO leakage.
     * AD9361 TX LO must be set nco_offset_hz lower to compensate. */
    tetra_set_nco_offset(&hal, nco_offset_hz);

    if (!no_enable)
        tetra_enable(&hal, sync_thresh);

    tetra_print_status(&hal);

    /* ================================================================
     * Main loop: poll TX TDMA counter, re-encode SYSINFO each frame
     * so the frame/multiframe fields stay current.
     *
     * The TX frame is ~56.67 ms (4 slots × 14.17 ms).  We poll every
     * ~10 ms and re-encode when the frame number changes.  Encoding
     * + register writes take <1 ms on Zynq ARM, so we always finish
     * well before the next slot 0.
     * ================================================================ */
    uint32_t last_tdma = 0;
    printf("Running SYSINFO loop (Ctrl-C to stop)...\n");

    for (;;) {
        uint32_t tdma = tetra_reg_read(&hal, REG_TX_TDMA);
        uint32_t fn = (tdma >> 2) & 0x1F;
        uint32_t mf = (tdma >> 7) & 0x3F;

        /* Re-encode only when frame or multiframe changed */
        if (tdma != last_tdma) {
            info.frame      = (uint8_t)fn;
            info.multiframe = (uint8_t)mf;
            tetra_write_sysinfo(&hal, &info);
            last_tdma = tdma;
        }

        usleep(10000);  /* 10 ms */
    }

    /* not reached */
    tetra_hal_close(&hal);
    return 0;
}
