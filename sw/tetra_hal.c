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
#include "tetra_gold_schedule.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <getopt.h>
#include <signal.h>
#include <time.h>
#include <errno.h>

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
#define SCHF_INFO_BITS   268
#define SCHF_CRC_BITS    (SCHF_INFO_BITS + 16)   /* 284 */
#define SCHF_TAIL_BITS   (SCHF_CRC_BITS + 4)     /* 288 */
#define SCHF_CODED_BITS  432

static int tetra_schf_encode(const uint8_t *info_bits,
                              uint8_t colour_code, uint8_t slot_num,
                              uint16_t mcc, uint16_t mnc,
                              uint8_t *out_432);

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
 * AACH Builder  (EN 300 392-2 §21.5.2, Table 21.77)
 *
 * Access Assignment Channel — 14 type-1 bits → RM(30,14) → 30 coded bits.
 *
 * AACH type-1 (14 bits) — format for Main Carrier (§21.5.2):
 *   Header (2):  00 = downlink and uplink usage markers present
 *   Field1 (6):  DL usage (3 bits) + UL usage (3 bits)
 *   Field2 (6):  Colour Code
 *
 * DL usage marker (3 bits, §21.5.2.1):
 *   000 = Unallocated (slot available for assignment)
 *   001 = Assigned, common control
 *
 * UL usage marker (3 bits, §21.5.2.2):
 *   001 = Assigned for random access (MS may send RACH)
 * ======================================================================== */

static void aach_scramble(uint16_t mcc, uint16_t mnc, uint8_t colour_code,
                          uint8_t *bits, int nbits)
{
    uint32_t lfsr = ((uint32_t)(mcc & 0x3FF) << 22)
                   | ((uint32_t)(mnc & 0x3FFF) << 8)
                   | ((uint32_t)(colour_code & 0x3F) << 2)
                   | 3u;
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;
    for (int i = 0; i < nbits; i++)
        bits[i] = (bits[i] ^ next_lfsr_bit(&lfsr)) & 1;
}

static void build_aach(uint8_t aach_cc, uint8_t dl_usage, uint8_t ul_usage,
                       uint8_t scramb_cc, uint16_t mcc, uint16_t mnc,
                       uint8_t *out30)
{
    uint8_t info[14];
    int pos = 0;

    /* Header: 00 = DL+UL usage markers present */
    pack_bits(info, &pos, 0, 2);
    /* Field1: DL usage marker (3 bits) + UL usage marker (3 bits) */
    pack_bits(info, &pos, dl_usage & 0x07, 3);
    pack_bits(info, &pos, ul_usage & 0x07, 3);
    /* Field2: Colour Code in AACH content (6 bits) */
    pack_bits(info, &pos, aach_cc, 6);

    /* Pack 14 info bits into uint16_t for RM encoder */
    uint16_t in_word = 0;
    for (int i = 0; i < 14; i++)
        in_word |= (uint16_t)(info[i] & 1) << (13 - i);

    /* RM(30,14) encode → 30 bits, use all (continuous downlink burst) */
    uint32_t coded = tetra_rm3014_compute(in_word);
    for (int i = 0; i < 30; i++)
        out30[i] = (coded >> (29 - i)) & 1;

    /* Scrambler always uses cell's real CC, not the AACH content CC */
    aach_scramble(mcc, mnc, scramb_cc, out30, 30);
}

/* ========================================================================
 * build_aach_capaloc — Capacity Allocation AACH for FN=1-17
 *
 * Real TETRA cells use CapAlloc (Header=11) on normal frames.
 * Confirmed from WAV decode: 0x3000 = 11_000000_000000.
 * ======================================================================== */
static void build_aach_capaloc(uint8_t colour_code,
                               uint16_t mcc, uint16_t mnc, uint8_t *out30)
{
    /* 14-bit info: Header(2)=11, Field1(6)=0, Field2(6)=0 → 0x3000 */
    uint16_t in_word = 0x3000;

    uint32_t coded = tetra_rm3014_compute(in_word);
    for (int i = 0; i < 30; i++)
        out30[i] = (coded >> (29 - i)) & 1;

    aach_scramble(mcc, mnc, colour_code, out30, 30);
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
 *   → scramble (init=3, fixed) → type-5 (216)
 *
 * Used for the SDB bkn2 field (slot 0 BNCH on continuous downlink).
 *
 * Scrambler init: cell-identity based (cc | mnc<<6 | mcc<<20) << 2 | TN
 * Verified from SDRSharp.Tetra.dll: TMO path uses ExtractLogicChannelFromBKN
 * which unscrambles with _scramblerSquence (cell-identity), NOT init=3.
 * (Only the DMO path ExtractLogicChannelFromBKN2 uses init=3.)
 * ======================================================================== */

static int tetra_bnch_encode(const uint8_t *info_bits,
                              uint8_t colour_code, uint32_t scramb_init,
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

    /* Scramble init:
     *   scramb_init != 0 → use directly (BSCH BKN2: fixed init=3)
     *   scramb_init == 0 → compute cell-identity code (BNCH NDB2 blocks) */
    uint32_t lfsr;
    if (scramb_init != 0) {
        lfsr = scramb_init;
    } else {
        lfsr = ((uint32_t)(mcc & 0x3FF) << 22)
             | ((uint32_t)(mnc & 0x3FFF) << 8)
             | ((uint32_t)(colour_code & 0x3F) << 2)
             | 3u;
    }
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;
    for (int i = 0; i < BNCH_CODED_BITS; i++)
        out_216[i] = (type4i[i] ^ next_lfsr_bit(&lfsr)) & 1;
    return 0;
}

/* ========================================================================
 * Frequency ↔ Carrier conversion (EN 300 392-2 §4.4, SDR# Tetra plugin)
 *
 * Formula from SDRSharp.Tetra.dll FrequencyCalc/CarrierCalc:
 *   DL_freq = band × 100_000_000 + carrier × 25_000
 *   carrier = round((DL_freq - band × 100_000_000) / 25_000)
 *
 * Band is the 4-bit frequency_band field (0-15).
 * Carrier is the 12-bit main_carrier field (0-4095).
 *
 * For 410-450 MHz:  band=4, carrier = (freq - 400 MHz) / 25 kHz
 *   410 MHz → carrier=400, 420 MHz → 800, 430 MHz → 1200, 440 MHz → 1600
 * ======================================================================== */

static void tetra_freq_to_carrier(uint32_t dl_freq_hz,
                                   uint8_t *band, uint16_t *carrier)
{
    *band = (uint8_t)(dl_freq_hz / 100000000);
    uint32_t remainder = dl_freq_hz - (uint32_t)(*band) * 100000000;
    *carrier = (uint16_t)((remainder + 12500) / 25000);  /* round */
}

static uint32_t tetra_carrier_to_freq(uint8_t band, uint16_t carrier)
{
    return (uint32_t)band * 100000000 + (uint32_t)carrier * 25000;
}

/* ========================================================================
 * Build BNCH SYSINFO PDU — 124 type-1 bits (MAC-BROADCAST type 00)
 *
 * This is the broadcast SYSINFO carried on the BNCH (bkn2), NOT the
 * BSCH sync-info.  It tells the MS the main carrier frequency, duplex
 * spacing, location area, subscriber class, and service capabilities.
 *
 * Field order from SDRSharp.Tetra.dll _sysInfoRules (§18.4.2.1):
 *   Main_Carrier(12), Frequency_Band(4), Offset(2), Duplex_Spacing(3),
 *   Reverse_Operation(1), NumberOfCommon_SC(2), MS_TXPwr_Max_Cell(3),
 *   RXLevel_Access_Min(4), Access_Parameter(4), Radio_DL_Timeout(4),
 *   HF_or_CK_flag(2), [conditional], Optional_field_flag(1),
 *   [conditional], Location_Area(14), Subscriber_Class(16),
 *   Registration_required(1), De_registration_required(1),
 *   Priority_cell(1), Cell_never_uses_minimum_mode(1),
 *   Migration_supported(1), System_wide_services(1),
 *   TETRA_voice_service(1), Circuit_mode_data_service(1),
 *   Reserved(1), SNDCP_Service(1), Air_interface_encryption(1),
 *   Advanced_link_supported(1)
 * ======================================================================== */

static void build_bnch_sysinfo(const tetra_sysinfo_t *info, uint8_t *bits)
{
    uint8_t band;
    uint16_t carrier;
    tetra_freq_to_carrier(info->dl_freq_hz, &band, &carrier);

    int bp = 0;
    memset(bits, 0, BNCH_INFO_BITS);

    /* MAC PDU type (2 bits): 10 = Broadcast (Table 21.73) */
    pack_bits(bits, &bp, 2, 2);
    /* MAC-BROADCAST sub-type (2 bits): 00 = SYSINFO */
    pack_bits(bits, &bp, 0, 2);

    /* Main Carrier (12 bits) */
    pack_bits(bits, &bp, carrier, 12);
    /* Frequency Band (4 bits) */
    pack_bits(bits, &bp, band, 4);
    /* Offset (2 bits): 0 = no offset (our freq is on 25 kHz grid) */
    pack_bits(bits, &bp, 0, 2);
    /* Duplex spacing (3 bits) */
    pack_bits(bits, &bp, info->duplex_spacing, 3);
    /* Reverse operation (1 bit): 0 = normal (UL below DL) */
    pack_bits(bits, &bp, 0, 1);
    /* Number of common secondary ctrl channels (2 bits): 00 = none */
    pack_bits(bits, &bp, 0, 2);
    /* MS TX power max cell (3 bits) */
    pack_bits(bits, &bp, info->ms_txpwr_max_cell, 3);
    /* RX level access minimum (4 bits) */
    pack_bits(bits, &bp, info->rxlevel_access_min, 4);
    /* Access parameter (4 bits) */
    pack_bits(bits, &bp, info->access_parameter, 4);
    /* Radio downlink timeout (4 bits) */
    pack_bits(bits, &bp, info->radio_dl_timeout, 4);
    /* Hyperframe/cipher key flag (1 bit): 0 = hyperframe number follows */
    pack_bits(bits, &bp, 0, 1);
    /* Hyperframe number (16 bits): running counter */
    pack_bits(bits, &bp, info->hyperframe, 16);
    /* Optional field flag (2 bits): 10 = default freq + ext services */
    pack_bits(bits, &bp, 2, 2);
    /* Optional field value (20 bits) */
    pack_bits(bits, &bp, info->optional_field_value, 20);

    /* Location Area (14 bits) */
    pack_bits(bits, &bp, info->la, 14);
    /* Subscriber Class (16 bits): 0xFFFF = all classes allowed */
    pack_bits(bits, &bp, 0xFFFF, 16);
    /* Registration required (1): 1 = yes */
    pack_bits(bits, &bp, 1, 1);
    /* De-registration required (1): 1 (real cell) */
    pack_bits(bits, &bp, 1, 1);
    /* Priority cell (1) */
    pack_bits(bits, &bp, info->priority_cell, 1);
    /* Cell never uses minimum mode (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* Migration supported (1) */
    pack_bits(bits, &bp, info->migration_supported, 1);
    /* System wide services (1): 1 (real cell) */
    pack_bits(bits, &bp, 1, 1);
    /* TETRA voice service (1): 1 = supported */
    pack_bits(bits, &bp, 1, 1);
    /* Circuit mode data service (1): 1 (real cell) */
    pack_bits(bits, &bp, 1, 1);
    /* Reserved (1): 0 */
    pack_bits(bits, &bp, 0, 1);
    /* SNDCP service (1): 1 (real cell) */
    pack_bits(bits, &bp, 1, 1);
    /* Air interface encryption (1): 0 = not supported */
    pack_bits(bits, &bp, 0, 1);
    /* Advanced link supported (1): 1 (real cell) */
    pack_bits(bits, &bp, 1, 1);
}

/* ========================================================================
 * build_schf_sysinfo — Build a 268-bit (SCH/F) MAC-BROADCAST SYSINFO PDU
 *
 * Same content as build_bnch_sysinfo (124-bit BNCH version) but packed
 * into the longer SCH/F format (268 info bits).
 * Used on MCCH (slot 1) so the receiver can decode SYSINFO from NDB bursts
 * using the SCH/F channel coding path.
 * ======================================================================== */

static void build_schf_sysinfo(const tetra_sysinfo_t *info, uint8_t *bits)
{
    uint8_t band;
    uint16_t carrier;
    tetra_freq_to_carrier(info->dl_freq_hz, &band, &carrier);

    int bp = 0;
    memset(bits, 0, SCHF_INFO_BITS);

    /* Use same bit layout as BNCH (no fill-bit-indication / encryption-mode)
     * so SDR# plugin can find SYSINFO fields at the same bit offsets after
     * SCH/F channel decoding.  Padded to 268 bits with trailing zeros. */
    /* MAC PDU type (2 bits): 10 = Broadcast (Table 21.73) */
    pack_bits(bits, &bp, 2, 2);
    /* MAC-BROADCAST sub-type (2 bits): 00 = SYSINFO */
    pack_bits(bits, &bp, 0, 2);

    /* Main Carrier (12 bits) */
    pack_bits(bits, &bp, carrier, 12);
    /* Frequency Band (4 bits) */
    pack_bits(bits, &bp, band, 4);
    /* Offset (2 bits): 0 = no offset */
    pack_bits(bits, &bp, 0, 2);
    /* Duplex spacing (3 bits) */
    pack_bits(bits, &bp, info->duplex_spacing, 3);
    /* Reverse operation (1 bit): 0 = normal */
    pack_bits(bits, &bp, 0, 1);
    /* Number of common secondary ctrl channels (2 bits): 00 = none */
    pack_bits(bits, &bp, 0, 2);
    /* MS TX power max cell (3 bits) */
    pack_bits(bits, &bp, info->ms_txpwr_max_cell, 3);
    /* RX level access minimum (4 bits) */
    pack_bits(bits, &bp, info->rxlevel_access_min, 4);
    /* Access parameter (4 bits) */
    pack_bits(bits, &bp, info->access_parameter, 4);
    /* Radio downlink timeout (4 bits) */
    pack_bits(bits, &bp, info->radio_dl_timeout, 4);
    /* Hyperframe/cipher key flag (1 bit): 0 = hyperframe number follows */
    pack_bits(bits, &bp, 0, 1);
    /* Hyperframe number (16 bits) */
    pack_bits(bits, &bp, info->hyperframe, 16);
    /* Optional field flag (2 bits): 10 = default freq + ext services */
    pack_bits(bits, &bp, 2, 2);
    /* Optional field value (20 bits) */
    pack_bits(bits, &bp, info->optional_field_value, 20);

    /* Location Area (14 bits) */
    pack_bits(bits, &bp, info->la, 14);
    /* Subscriber Class (16 bits): 0xFFFF = all classes allowed */
    pack_bits(bits, &bp, 0xFFFF, 16);
    /* Registration required (1): 1 = yes */
    pack_bits(bits, &bp, 1, 1);
    /* De-registration required (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* Priority cell (1) */
    pack_bits(bits, &bp, info->priority_cell, 1);
    /* Cell never uses minimum mode (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* Migration supported (1) */
    pack_bits(bits, &bp, info->migration_supported, 1);
    /* System wide services (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* TETRA voice service (1): 1 = supported */
    pack_bits(bits, &bp, 1, 1);
    /* Circuit mode data service (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* Reserved (1): 0 */
    pack_bits(bits, &bp, 0, 1);
    /* SNDCP service (1): 1 */
    pack_bits(bits, &bp, 1, 1);
    /* Air interface encryption (1): 0 = not supported */
    pack_bits(bits, &bp, 0, 1);
    /* Advanced link supported (1): 1 */
    pack_bits(bits, &bp, 1, 1);

    /* --- ACCESS-DEFINE follows SYSINFO in SCH/F PDU (§21.4.7.2) ---
     * On the MCCH, the DLL expects SYSINFO + ACCESS-DEFINE in the same
     * 268-bit Broadcast PDU.  Without this, 144 trailing zeros are parsed
     * as ACCESS-DEFINE with garbage values. */

    /* Fill bit indication: 0 = no fill bits */
    pack_bits(bits, &bp, 0, 1);
    /* Encryption mode: 00 = clear mode */
    pack_bits(bits, &bp, 0, 2);
    /* Random access flag: 1 = access parms follow */
    pack_bits(bits, &bp, 1, 1);
    /* Access code: 0000 = AC0 (all subscriber classes) */
    pack_bits(bits, &bp, 0, 4);
    /* Immediate: 1 = immediate access allowed */
    pack_bits(bits, &bp, 1, 1);
    /* Waiting time: 2 (short) */
    pack_bits(bits, &bp, 2, 4);
    /* Number of random access transmissions: 3 */
    pack_bits(bits, &bp, 3, 4);
    /* Frame length factor: 0 = 1 frame */
    pack_bits(bits, &bp, 0, 1);
    /* Timeslot pointer: 0001 = slot 1 */
    pack_bits(bits, &bp, 1, 4);
    /* Minimum PDU priority: 000 = no minimum */
    pack_bits(bits, &bp, 0, 3);
    /* Random access flag: 0 = no more access definitions */
    pack_bits(bits, &bp, 0, 1);

    /* Remaining bits (268 - bp) are zero fill */
}

/* ========================================================================
 * Build BNCH ACCESS_DEFINE PDU — 124 type-1 bits (MAC-BROADCAST type 01)
 * ======================================================================== */

static void build_bnch_access_define(uint8_t *bits)
{
    int bp = 0;
    memset(bits, 0, BNCH_INFO_BITS);

    /* MAC PDU type (2 bits): 10 = Broadcast (Table 21.73) */
    pack_bits(bits, &bp, 2, 2);
    /* MAC-BROADCAST sub-type (2 bits): 01 = ACCESS-DEFINE */
    pack_bits(bits, &bp, 1, 2);
    /* Fill bit indication: 0 = no fill bits */
    pack_bits(bits, &bp, 0, 1);
    /* Encryption mode: 00 = clear mode */
    pack_bits(bits, &bp, 0, 2);
    /* Random access flag: 1 = access parms follow */
    pack_bits(bits, &bp, 1, 1);
    /* Access code: 0000 = AC0 (all subscriber classes) */
    pack_bits(bits, &bp, 0, 4);
    /* Immediate: 1 = immediate access allowed */
    pack_bits(bits, &bp, 1, 1);
    /* Waiting time: 2 (short) */
    pack_bits(bits, &bp, 2, 4);
    /* Number of random access transmissions: 3 */
    pack_bits(bits, &bp, 3, 4);
    /* Frame length factor: 0 = 1 frame */
    pack_bits(bits, &bp, 0, 1);
    /* Timeslot pointer: 0001 = slot 1 */
    pack_bits(bits, &bp, 1, 4);
    /* Minimum PDU priority: 000 = no minimum */
    pack_bits(bits, &bp, 0, 3);
    /* Random access flag: 0 = no more access definitions */
    pack_bits(bits, &bp, 0, 1);
    /* Remaining bits stay zero (fill) */
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

    /* --- BNCH: Always SYSINFO (type 00) ---
     *
     * Real TETRA BSes send SYSINFO on every BNCH (bkn2 of SDB).
     * Confirmed: WAV decode of HamTetra cell = 125/125 SYSINFO.
     * ACCESS_DEFINE is delivered via MCCH (NDB slot 1, SCH/F). */
    uint8_t bnch_info[BNCH_INFO_BITS];
    build_bnch_sysinfo(info, bnch_info);

    uint8_t type5_bkn2[BKN2_CODED_BITS];
    /* BSCH BKN2 uses scrambCode in TMO (DLL has already parsed SB1 and
     * computed scrambCode by the time it decodes BKN2).
     * "BKN2 standalone init=3" in the DLL table is for DMO only. */
    if (tetra_bnch_encode(bnch_info, info->colour_code, 0,
                          info->mcc, info->mnc, type5_bkn2) != 0) {
        fprintf(stderr, "tetra_hal: BNCH encoding failed\n");
        return -1;
    }

    /* --- AACH: Access Assignment ---
     * FN=18: DL/UL-Assign (Header=00) DL=Unalloc(0) UL=Random(1) CC=0
     *        Confirmed from real cell WAV decode (dist=0).
     *        AACH content CC=0, but scrambler uses cell CC.
     * FN=1-17: CapAlloc (Header=11) field1=0 field2=0
     *          Confirmed from real cell WAV decode (0x3000, dist=2-3). */
    uint8_t type5_bb[AACH_BITS];
    if (info->frame == 18)
        build_aach(0, 0, 1, info->colour_code, info->mcc, info->mnc, type5_bb);
    else
        build_aach_capaloc(info->colour_code, info->mcc, info->mnc, type5_bb);

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
 * All 4 NDB slots receive the same 432 bits.  slot_num is set to 1
 * (MCCH slot) so the MS can correctly descramble the main control channel.
 * Slots 2-3 use the same data and are therefore scrambled "wrong" but
 * only carry filler — the MS doesn't expect signaling on them.
 * ======================================================================== */

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

    /* Scramble (§8.2.5.2) — cell-identity scrambler init:
     * e(0)..e(31) = MCC(10) | MNC(14) | CC(6) | slot_num(2)
     * Lower 2 bits fixed to 3 (matches SDR# and osmo-tetra convention
     * for downlink non-BSCH channels). */
    uint32_t lfsr = ((uint32_t)(mcc & 0x3FF) << 22)
                   | ((uint32_t)(mnc & 0x3FFF) << 8)
                   | ((uint32_t)(colour_code & 0x3F) << 2)
                   | 3u;
    if (lfsr == 0)
        lfsr = 0xFFFFFFFF;
    for (int i = 0; i < SCHF_CODED_BITS; i++)
        out_432[i] = (type4i[i] ^ next_lfsr_bit(&lfsr)) & 1;
    return 0;
}

/* ========================================================================
 * build_mcch_access_define — Build a 268-bit (SCH/F) MAC-BROADCAST PDU
 * containing ACCESS-DEFINE for the MCCH (NDB slot 1).
 *
 * This is the full-slot version of build_bnch_access_define (which builds
 * 124-bit SCH/HD for bkn2).  The MS locates the MCCH on slot 1 and decodes
 * SCH/F signalling here.  Without a valid MAC PDU the MS sees CRC failures
 * and won't register.
 *
 * PDU format: MAC-BROADCAST (type 10, sub-type 01 = ACCESS_DEFINE)
 * per EN 300 392-2 §21.4.7.2.  Remaining bits are fill (zero).
 * ======================================================================== */

static void build_mcch_access_define(uint8_t *bits)
{
    int bp = 0;
    memset(bits, 0, SCHF_INFO_BITS);

    /* MAC PDU type (2 bits): 10 = Broadcast (Table 21.73) */
    pack_bits(bits, &bp, 2, 2);
    /* MAC-BROADCAST sub-type (2 bits): 01 = ACCESS-DEFINE */
    pack_bits(bits, &bp, 1, 2);
    /* Fill bit indication (1 bit): 1 = fill bits present */
    pack_bits(bits, &bp, 1, 1);
    /* Encryption mode (2 bits): 00 = clear mode */
    pack_bits(bits, &bp, 0, 2);

    /* --- ACCESS-DEFINE element (§21.5.2) --- */
    /* Random access flag (1 bit): 1 = access parms follow */
    pack_bits(bits, &bp, 1, 1);
    /* Access code (4 bits): 0000 = AC0 (all subscriber classes) */
    pack_bits(bits, &bp, 0, 4);
    /* Immediate (1 bit): 1 = immediate access allowed */
    pack_bits(bits, &bp, 1, 1);
    /* Waiting time (4 bits): 2 (short) */
    pack_bits(bits, &bp, 2, 4);
    /* Number of random access transmissions on up-link (4 bits): 3 */
    pack_bits(bits, &bp, 3, 4);
    /* Frame length factor (1 bit): 0 = 1 frame */
    pack_bits(bits, &bp, 0, 1);
    /* Timeslot pointer (4 bits): 0001 = slot 1 */
    pack_bits(bits, &bp, 1, 4);
    /* Minimum PDU priority (3 bits): 000 = no minimum */
    pack_bits(bits, &bp, 0, 3);

    /* Random access flag (1 bit): 0 = no more access definitions */
    pack_bits(bits, &bp, 0, 1);

    /* Remaining bits (268 - bp) are zero fill */
}

/* ========================================================================
 * tetra_write_bnch — Write BNCH block1/block2 registers (SCH/F)
 *
 * On frame 18, the BNCH slot uses NDB2 burst type (NTS2 training sequence).
 * ETSI says BNCH should use SCH/HD, but the SDR# DLL uses the AACH
 * (DL usage = Common) to select combined (full-slot) decode for ALL NDB
 * bursts regardless of NDB1/NDB2 burst type.  So we must encode as SCH/F
 * for the DLL to decode correctly.
 *
 * 268 type-1 bits → CRC-16 → tail → RCPC 2/3 → interleave K=432 a=103
 * → scramble → 432 coded bits → split block1[0..215] + block2[216..431].
 * ======================================================================== */

int tetra_write_bnch(tetra_hal_t *hal, const tetra_sysinfo_t *info,
                     uint8_t colour_code)
{
    /* Encode SYSINFO+ACCESS-DEFINE as SCH/F (268 type-1 → 432 type-5 bits).
     * The DLL uses AACH-based channel allocation (Common → combined decode)
     * regardless of burst type.  Must match the MCCH encoding format. */
    uint8_t schf_info[SCHF_INFO_BITS];
    build_schf_sysinfo(info, schf_info);

    uint8_t type5[SCHF_CODED_BITS];
    if (tetra_schf_encode(schf_info, colour_code, 1,
                          info->mcc, info->mnc, type5) != 0) {
        fprintf(stderr, "tetra_hal: BNCH SCH/F encoding failed\n");
        return -1;
    }

    uint32_t blk1_words[7], blk2_words[7];
    bits_to_words(&type5[0],   216, blk1_words, 7);
    blk1_words[6] >>= 8;
    bits_to_words(&type5[216], 216, blk2_words, 7);
    blk2_words[6] >>= 8;

    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_BNCH_BLK1_0 + i * 4, blk1_words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_BNCH_BLK2_0 + i * 4, blk2_words[i]);

    printf("BNCH written: SYSINFO SCH/F (268 type-1) -> 432 type-5 bits split 2×216 "
           "(CC=%u MCC=%u MNC=%u)\n", colour_code, info->mcc, info->mnc);
    return 0;
}

/* ========================================================================
 * tetra_refresh_sysinfo — rebuild+rewrite every SYSINFO-bearing register
 *
 * BNCH SCH/F (BNCH_BLK1/2), and the three SCH/HD SYSINFO payloads
 * (SB_BKN2, NDB_BLK1/2, MCCH_BLK1/2) all carry the 16-bit hyperframe field
 * inside the SYSINFO PDU.  Call this once at boot, and again after every
 * hyperframe edge in daemon mode to advance HN on-air.
 *
 * Register writes are not atomic across the 7 words of a 216-bit payload
 * — but each 32-bit AXI write is, and the whole sequence runs in a few
 * microseconds vs. the 14 ms slot period, so mid-burst tearing is
 * vanishingly rare (and transient: the MS resyncs the next multiframe).
 * ======================================================================== */

int tetra_refresh_sysinfo(tetra_hal_t *hal, const tetra_sysinfo_t *info)
{
    /* BNCH SCH/F (268 → 432 bits, split into BNCH_BLK1 + BNCH_BLK2). */
    if (tetra_write_bnch(hal, info, info->colour_code) != 0)
        return -1;

    /* SCH/HD BNCH SYSINFO (124 → 216 bits, cell-identity scrambler). */
    uint8_t bnch_info[BNCH_INFO_BITS];
    build_bnch_sysinfo(info, bnch_info);
    uint8_t bnch_type5[BNCH_CODED_BITS];
    if (tetra_bnch_encode(bnch_info, info->colour_code, 0,
                          info->mcc, info->mnc, bnch_type5) != 0) {
        fprintf(stderr, "tetra_hal: SCH/HD BNCH SYSINFO encoding failed\n");
        return -1;
    }

    uint32_t words[7];
    bits_to_words(bnch_type5, BNCH_CODED_BITS, words, 7);
    words[6] >>= 8;

    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_SB_BKN2_0 + i * 4, words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_NDB_BLK1_0 + i * 4, words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_NDB_BLK2_0 + i * 4, words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_MCCH_BLK1_0 + i * 4, words[i]);
    for (int i = 0; i < 7; i++)
        tetra_reg_write(hal, REG_MCCH_BLK2_0 + i * 4, words[i]);

    return 0;
}

/* ========================================================================
 * Control Functions
 * ======================================================================== */

void tetra_enable(tetra_hal_t *hal, uint8_t sync_thresh)
{
    if (sync_thresh > 0)
        tetra_reg_write(hal, REG_SYNC_THRESH, sync_thresh);

    /* Enable TX + RX */
    tetra_reg_write(hal, REG_CTRL, CTRL_TX_EN | CTRL_RX_EN);
    printf("TETRA PHY enabled (TX+RX)\n");
}

/* ========================================================================
 * Stufe 3.5 / Stufe 4 / Stufe 6 boot-init helpers
 * ======================================================================== */

void tetra_write_cell_config(tetra_hal_t *hal, const tetra_sysinfo_t *info)
{
    uint32_t cfg0 = ((uint32_t)(info->system_code              & 0x0F) << 0)
                  | ((uint32_t)(info->sharing_mode             & 0x03) << 4)
                  | ((uint32_t)(info->ts_reserved_frames       & 0x07) << 6)
                  | ((uint32_t)(info->u_plane                  & 0x01) << 9)
                  | ((uint32_t)(info->frame_18_extension       & 0x01) << 10)
                  | ((uint32_t)(info->neighbour_cell_broadcast & 0x03) << 11)
                  | ((uint32_t)(info->cell_service_level       & 0x03) << 13)
                  | ((uint32_t)(info->late_entry_info          & 0x01) << 15);
    uint32_t cfg1 = ((uint32_t)(info->mcc & 0x3FF)   << 0)
                  | ((uint32_t)(info->mnc & 0x3FFF)  << 10);
    tetra_reg_write(hal, REG_CELL_CFG_0, cfg0);
    tetra_reg_write(hal, REG_CELL_CFG_1, cfg1);
    printf("CELL_CFG: cfg0=0x%04X cfg1=0x%06X (SC=%u CC=%u MCC=%u MNC=%u F18ext=%u)\n",
           cfg0, cfg1, info->system_code, info->colour_code,
           info->mcc, info->mnc, info->frame_18_extension);
}

int tetra_write_null_pdu(tetra_hal_t *hal, uint8_t colour_code,
                         uint16_t mcc, uint16_t mnc)
{
    /* 124-bit NULL-PDU static pattern — matches Gold-cell WAV observation
     * (97/97 bit-identical on TN=1 NDB2 BKN1).  Bit layout:
     *   bit[11] = 1  (end-of-PDU marker)
     *   bit[16] = 1  (TM-SDU continues in next frame)
     *   rest    = 0
     * Raw: 0x0010_8000_0000_…_0000  (big-endian bit 0 = MSB). */
    uint8_t info[BNCH_INFO_BITS];
    memset(info, 0, BNCH_INFO_BITS);
    info[11] = 1;
    info[16] = 1;

    /* SCH/HD encode with cell-identity scrambler (scramb_init=0 → MCC|MNC|CC|3).
     * Matches Gold: BKN1 decoded cleanly with the same scrambler as BKN2. */
    uint8_t type5[BKN2_CODED_BITS];
    if (tetra_bnch_encode(info, colour_code, 0, mcc, mnc, type5) != 0) {
        fprintf(stderr, "tetra_hal: NULL-PDU SCH/HD encoding failed\n");
        return -1;
    }

    uint32_t words[7];
    bits_to_words(type5, 216, words, 7);
    words[6] >>= 8;   /* align 24 remaining bits into [23:0] */

    tetra_reg_write(hal, REG_NULL_PDU_0, words[0]);
    tetra_reg_write(hal, REG_NULL_PDU_1, words[1]);
    tetra_reg_write(hal, REG_NULL_PDU_2, words[2]);
    tetra_reg_write(hal, REG_NULL_PDU_3, words[3]);
    tetra_reg_write(hal, REG_NULL_PDU_4, words[4]);
    tetra_reg_write(hal, REG_NULL_PDU_5, words[5]);
    tetra_reg_write(hal, REG_NULL_PDU_6, words[6]);
    printf("NULL_PDU: 124-bit pattern → 216 type-5 bits (CC=%u MCC=%u MNC=%u, cell-identity scrambler)\n",
           colour_code, mcc, mnc);
    return 0;
}

void tetra_write_gold_schedule(tetra_hal_t *hal)
{
    for (unsigned i = 0; i < TETRA_GOLD_SCHEDULE_WORDS; i++)
        tetra_reg_write(hal, REG_SCHEDULE_BASE + i * 4,
                        tetra_gold_schedule[i]);
    printf("Gold schedule: %d words written to 0x%03X..0x%03X\n",
           TETRA_GOLD_SCHEDULE_WORDS,
           REG_SCHEDULE_BASE,
           REG_SCHEDULE_BASE + TETRA_GOLD_SCHEDULE_WORDS * 4 - 4);
}

void tetra_tx_tdma_load(tetra_hal_t *hal,
                        uint8_t tn, uint8_t fn, uint8_t mn, uint8_t hn)
{
    uint32_t load = ((uint32_t)(tn & 0x03)  << 0)
                  | ((uint32_t)(fn & 0x1F)  << 2)
                  | ((uint32_t)(mn & 0x3F)  << 7)
                  | ((uint32_t)(hn & 0x3F)  << 13)
                  | TX_TDMA_LOAD_STROBE;
    tetra_reg_write(hal, REG_TX_TDMA_LOAD, load);
    printf("TX_TDMA_LOAD: TN=%u FN=%u MN=%u HN=%u (strobe)\n", tn, fn, mn, hn);
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
        "  --freq N      DL frequency in Hz (default 438250000)\n"
        "  --mcc N       Mobile Country Code (0-1023, default 901=test)\n"
        "  --mnc N       Mobile Network Code (0-16383, default 9998)\n"
        "  --la N        Location Area (0-16383, default 1)\n"
        "  --cc N        Colour Code (0-63, default 49)\n"
        "  --sc N        System Code (0-15, default 2)\n"
        "  --duplex N    Duplex Spacing (0-7, default 1)\n"
        "  --txpwr N     MS TXPwr Max Cell (0-7, default 6)\n"
        "  --rxmin N     RXLevel Access Min (0-15, default 0)\n"
        "  --access N    Access Parameter (0-15, default 10)\n"
        "  --dltimo N    Radio DL Timeout (0-15, default 5)\n"
        "  --optfield N  Optional field value (0-1048575, default 24448)\n"
        "  --prio N      Priority cell (0-1, default 0)\n"
        "  --migr N      Migration supported (0-1, default 0)\n"
        "  --ncb N       Neighbour Cell Broadcast (0-3, default 3)\n"
        "  --csl N       Cell Service Level (0-3, default 0)\n"
        "  --hf N        Initial hyperframe number (0-65535, default 1)\n"
        "  --daemon      Don't exit — refresh SYSINFO every hyperframe (~61.2s)\n"
        "                to advance HN on-air.  Needed for MS to treat the cell\n"
        "                as synchronised.\n"
        "  --thresh N    Sync threshold (1-255, default 0=unchanged)\n"
        "  --status      Print status registers and exit\n"
        "  --no-enable   Write SYSINFO but don't enable TX/RX\n"
        "  -h, --help    Show this help\n",
        prog);
}

/* Signal handler — set by --daemon loop to exit cleanly on SIGINT/SIGTERM. */
static volatile sig_atomic_t g_daemon_running = 1;

static void daemon_signal_handler(int signum)
{
    (void)signum;
    g_daemon_running = 0;
}

int main(int argc, char *argv[])
{
    tetra_sysinfo_t info = {
        .system_code      = 3,     /* V+D mode (real cell uses 3, not 2) */
        .dl_freq_hz       = 438250000, /* 438.250 MHz (HamTetra cell frequency) */
        .mcc              = 901,   /* Test network (ITU-T E.212) */
        .mnc              = 9998,
        .la               = 1,
        .colour_code      = 49,    /* HamTetra cell value */
        .timeslot_assigned = 1,    /* 1 common ctrl timeslot */
        .sharing_mode     = 0,     /* continuous carrier */
        .u_plane          = 0,
        /* Real cell (MCC=262/MNC=106, WAV-Analyse 2026-04-20) sets F18ext=1
         * because BKN2 on frame 18 carries BNCH SYSINFO extension.  Our TX
         * always sends SYSINFO in BKN2 on F18 → must also announce extension. */
        .frame_18_extension = 1,
        .neighbour_cell_broadcast = 3,  /* HamTetra cell value */
        .cell_service_level = 0,   /* HamTetra cell value */
        .late_entry_info  = 1,     /* late entry supported */
        .duplex_spacing   = 1,     /* -7.6 MHz */
        .ms_txpwr_max_cell = 6,
        .rxlevel_access_min = 0,
        .access_parameter = 10,
        .radio_dl_timeout = 5,
        .optional_field_value = 24448,
        .priority_cell    = 0,
        .migration_supported = 0,
        .frame_countdown  = 0,
        .access_code      = 0x0F,  /* All subscriber classes allowed */
        .dl_usage         = 0x3F,  /* All slots available */
        /* Hyperframe starts at 1 (not 0) because some MS stacks treat
         * HN=0 in SYSINFO as "uninitialised" and refuse registration. */
        .hyperframe       = 1,
    };
    int sync_thresh = 0;
    int status_only = 0;
    int no_enable = 0;
    int daemon_mode = 0;

    /* Make stdout line-buffered so nohup'd log shows each refresh immediately. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    enum {
        OPT_SC = 256, OPT_DUPLEX, OPT_TXPWR, OPT_RXMIN,
        OPT_ACCESS, OPT_DLTIMO, OPT_OPTFIELD, OPT_PRIO,
        OPT_MIGR, OPT_NCB, OPT_CSL, OPT_HF, OPT_DAEMON
    };
    static struct option long_opts[] = {
        {"freq",      required_argument, NULL, 'f'},
        {"mcc",       required_argument, NULL, 'm'},
        {"mnc",       required_argument, NULL, 'n'},
        {"la",        required_argument, NULL, 'l'},
        {"cc",        required_argument, NULL, 'c'},
        {"sc",        required_argument, NULL, OPT_SC},
        {"duplex",    required_argument, NULL, OPT_DUPLEX},
        {"txpwr",     required_argument, NULL, OPT_TXPWR},
        {"rxmin",     required_argument, NULL, OPT_RXMIN},
        {"access",    required_argument, NULL, OPT_ACCESS},
        {"dltimo",    required_argument, NULL, OPT_DLTIMO},
        {"optfield",  required_argument, NULL, OPT_OPTFIELD},
        {"prio",      required_argument, NULL, OPT_PRIO},
        {"migr",      required_argument, NULL, OPT_MIGR},
        {"ncb",       required_argument, NULL, OPT_NCB},
        {"csl",       required_argument, NULL, OPT_CSL},
        {"hf",        required_argument, NULL, OPT_HF},
        {"daemon",    no_argument,       NULL, OPT_DAEMON},
        {"thresh",    required_argument, NULL, 't'},
        {"status",    no_argument,       NULL, 's'},
        {"no-enable", no_argument,       NULL, 'x'},
        {"help",      no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "f:m:n:l:c:t:sxh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'f': info.dl_freq_hz  = strtoul(optarg, NULL, 10); break;
        case 'm': info.mcc         = atoi(optarg); break;
        case 'n': info.mnc         = atoi(optarg); break;
        case 'l': info.la          = atoi(optarg); break;
        case 'c': info.colour_code = atoi(optarg); break;
        case OPT_SC:       info.system_code          = atoi(optarg); break;
        case OPT_DUPLEX:   info.duplex_spacing       = atoi(optarg); break;
        case OPT_TXPWR:    info.ms_txpwr_max_cell    = atoi(optarg); break;
        case OPT_RXMIN:    info.rxlevel_access_min   = atoi(optarg); break;
        case OPT_ACCESS:   info.access_parameter     = atoi(optarg); break;
        case OPT_DLTIMO:   info.radio_dl_timeout     = atoi(optarg); break;
        case OPT_OPTFIELD: info.optional_field_value  = strtoul(optarg, NULL, 10); break;
        case OPT_PRIO:     info.priority_cell         = atoi(optarg); break;
        case OPT_MIGR:     info.migration_supported   = atoi(optarg); break;
        case OPT_NCB:      info.neighbour_cell_broadcast = atoi(optarg); break;
        case OPT_CSL:      info.cell_service_level    = atoi(optarg); break;
        case OPT_HF:       info.hyperframe            = (uint16_t)strtoul(optarg, NULL, 10); break;
        case OPT_DAEMON:   daemon_mode                = 1;            break;
        case 't': sync_thresh      = atoi(optarg); break;
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

    /* Validate frequency: must produce valid 12-bit carrier (0-4095) */
    {
        uint8_t band;
        uint16_t carrier;
        tetra_freq_to_carrier(info.dl_freq_hz, &band, &carrier);
        if (band > 15 || carrier > 4095) {
            fprintf(stderr, "Error: frequency %u Hz out of range "
                    "(band=%u carrier=%u)\n",
                    info.dl_freq_hz, band, carrier);
            return 1;
        }
        printf("Frequency: %.3f MHz → band=%u carrier=%u "
               "(UL=%.3f MHz, duplex=10 MHz)\n",
               info.dl_freq_hz / 1e6, band, carrier,
               (info.dl_freq_hz - 10000000) / 1e6);
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

    /* ================================================================
     * Boot-init sequence (Plan Stufe 6).
     *
     * Post-Stufe 3.5/3.7: BSCH (sb1) + AACH (bb) are generated by RTL
     * encoders from cell config + slot role.  SW only writes STATIC
     * payloads: BNCH SCH/HD, NDB-SYSINFO SCH/F, MCCH ACCESS-DEFINE,
     * SDB BKN2 SCH/F, NULL-PDU, and the schedule BRAM.  After enabling
     * TX+RX we exit — the RTL drives the DL carrier autonomously.
     * ================================================================ */

    /* CELL_CFG → RTL BSCH encoder reads system_code/sharing/MCC/MNC etc. */
    tetra_write_cell_config(&hal, &info);

    /* BNCH SCH/F + SB_BKN2 + NDB + MCCH — all SYSINFO-bearing registers.
     * Encoded HN value = info.hyperframe (see daemon loop below). */
    if (tetra_refresh_sysinfo(&hal, &info) != 0) {
        tetra_hal_close(&hal);
        return 1;
    }
    printf("SYSINFO written: BNCH SCH/F + SB_BKN2 + NDB + MCCH (HN=%u)\n",
           info.hyperframe);

    /* NULL PDU static pattern (Plan Stufe 4) */
    if (tetra_write_null_pdu(&hal, info.colour_code,
                             info.mcc, info.mnc) != 0) {
        tetra_hal_close(&hal);
        return 1;
    }

    /* Gold-mimic schedule BRAM (Plan Stufe 3/4) */
    tetra_write_gold_schedule(&hal);

    /* ColourCode (6 bits) — RTL BSCH/AACH/SCH encoders read this as raw CC.
     * NOTE: scrambler_init() packs cc|mnc|mcc|slot<<2, so the old write put
     * (cc<<2)&0x3F into the low 6 bits (CC=49 → on-air CC=4). */
    tetra_reg_write(&hal, REG_COLOUR_CODE, info.colour_code & 0x3F);

    /* Reset TDMA timebase to a known state (TN=FN=MN=HN=0).  RTL already
     * starts at 0 on reset, but a strobe here guarantees alignment if
     * this tool is re-run without a full FPGA reset. */
    tetra_tx_tdma_load(&hal, 0, 0, 0, 0);

    if (!no_enable)
        tetra_enable(&hal, sync_thresh);

    tetra_print_status(&hal);
    printf("Boot-init complete — RTL drives DL carrier autonomously.\n");

    if (!daemon_mode) {
        tetra_hal_close(&hal);
        return 0;
    }

    /* ================================================================
     * Daemon loop — advance hyperframe on-air.
     *
     * One TETRA hyperframe = 60 multiframes × 18 frames × 4 slots ×
     * (510/36 ms) = 61.2 seconds exactly.  Each wake-up rebuilds every
     * SYSINFO-bearing register (BNCH SCH/F, SB_BKN2, NDB_BLK1/2,
     * MCCH_BLK1/2) with info.hyperframe++.
     *
     * Uses clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME) so the cadence
     * is drift-free relative to wall time (though it will slowly drift
     * vs. the RTL TX TDMA counter, since those run on separate clock
     * sources — acceptable for HN which is only read at MS attach).
     * ================================================================ */

    struct sigaction sa = {0};
    sa.sa_handler = daemon_signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    printf("Entering daemon mode — HN will advance every 61.2 s (PID=%d)\n",
           (int)getpid());

    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);

    while (g_daemon_running) {
        next.tv_sec  += 61;
        next.tv_nsec += 200000000L;  /* +200 ms → 61.200 s total */
        if (next.tv_nsec >= 1000000000L) {
            next.tv_sec  += 1;
            next.tv_nsec -= 1000000000L;
        }

        int rc;
        do {
            rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
        } while (rc == EINTR && g_daemon_running);

        if (!g_daemon_running)
            break;

        info.hyperframe = (uint16_t)(info.hyperframe + 1);
        if (tetra_refresh_sysinfo(&hal, &info) != 0) {
            fprintf(stderr, "daemon: SYSINFO refresh failed — continuing\n");
            continue;
        }
        printf("HN advance: hyperframe = %u (SYSINFO refreshed)\n",
               info.hyperframe);
    }

    printf("Daemon exiting on signal — leaving RTL running.\n");
    tetra_hal_close(&hal);
    return 0;
}
