/*
 * tetra_channel_codec.c — TETRA channel encoder primitives (SW side)
 *
 * Verbatim extract from tetra_hal.c (ETSI EN 300 392-2 §8.2.x), so the
 * tetra_attach_daemon can link these without pulling tetra_hal.c's
 * main(). When tetra_hal.c is refactored to share this codec module
 * the duplicates there can be removed.
 *
 * License: GPL v2
 */

#include "tetra_channel_codec.h"

#include <string.h>

/* ========================================================================
 * CRC-16-CCITT (X.25) with final XOR — ETSI EN 300 392-2 §8.2.2
 * ======================================================================== */
void tetra_codec_crc16(const uint8_t *bits, int len, uint8_t *out)
{
 uint16_t crc = 0xFFFF;

 memcpy(out, bits, len);

 for (int i = 0; i < len; i++) {
 int feedback = (bits[i] & 1) ^ ((crc >> 15) & 1);
 crc <<= 1;
 if (feedback)
 crc ^= 0x1021;
 }

 crc ^= 0xFFFF;
 for (int i = 0; i < 16; i++)
 out[len + i] = (crc >> (15 - i)) & 1;
}

/* ========================================================================
 * Parity helper (used by conv encoder).
 * ======================================================================== */
static inline int parity5(uint8_t x)
{
 x ^= x >> 4;
 x ^= x >> 2;
 x ^= x >> 1;
 return x & 1;
}

/* ========================================================================
 * ETSI rate-1/4 mother conv encoder (K=5, G1=0x13, G2=0x1D, G3=0x17,
 * G4=0x1B). MSB of shift register = newest input bit.
 * ======================================================================== */
int tetra_codec_conv_r14(const uint8_t *bits, int len, uint8_t *out)
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

/* ========================================================================
 * P_2/3 puncture: keep {g1(a), g2(a), g1(b)} per pair of input bits.
 * ======================================================================== */
int tetra_codec_puncture_r23(const uint8_t *bits_r14, int len, uint8_t *out)
{
 int idx = 0;

 if ((len % 8) != 0)
 return -1;

 for (int i = 0; i < len; i += 8) {
 out[idx++] = bits_r14[i + 0]; /* g1(a) */
 out[idx++] = bits_r14[i + 1]; /* g2(a) */
 out[idx++] = bits_r14[i + 4]; /* g1(b) */
 }
 return idx;
}

/* ========================================================================
 * Multiplicative permutation interleaver — §8.2.4.1
 * ======================================================================== */
void tetra_codec_interleave_perm(const uint8_t *in, int N, int a,
                                 uint8_t *out)
{
 for (int k = 1; k <= N; k++) {
 int j = 1 + ((a * k) % N);
 out[j - 1] = in[k - 1];
 }
}

/* ========================================================================
 * Cell-identity scrambler LFSR — §8.2.5.2
 * Polynomial / taps: 32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1.
 * ======================================================================== */
#define ST(x, y) ((x) >> (32 - (y)))

static uint8_t next_lfsr_bit(uint32_t *lf)
{
 uint32_t lfsr = *lf;
 uint32_t bit;

 bit = (ST(lfsr, 32) ^ ST(lfsr, 26) ^ ST(lfsr, 23) ^ ST(lfsr, 22) ^
 ST(lfsr, 16) ^ ST(lfsr, 12) ^ ST(lfsr, 11) ^ ST(lfsr, 10) ^
 ST(lfsr,  8) ^ ST(lfsr,  7) ^ ST(lfsr,  5) ^ ST(lfsr,  4) ^
 ST(lfsr,  2) ^ ST(lfsr,  1)) & 1;
 lfsr = (lfsr >> 1) | (bit << 31);

 *lf = lfsr;
 return bit & 0xff;
}

/* ========================================================================
 * SCH/F channel coding: 268 info → 432 type-5
 *   info(268) → CRC-16 → type-2(284) → +4 tail → type-3(288)
 *            → rate-1/4 mother(1152) → P_2/3 puncture → type-4(432)
 *            → interleave K=432,a=103 → scramble → type-5(432)
 * Scrambler init (lower-2 = slot_num):
 *   e(0..31) = MCC(10) | MNC(14) | CC(6) | slot_num(2)
 * ======================================================================== */
#define SCHF_INFO_BITS 268
#define SCHF_CRC_BITS  (SCHF_INFO_BITS + 16) /* 284 */
#define SCHF_TAIL_BITS (SCHF_CRC_BITS + 4)   /* 288 */
#define SCHF_CODED_BITS 432

int tetra_codec_schf_encode(const uint8_t *info_268,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *out_432)
{
 uint8_t type2[SCHF_CRC_BITS];
 uint8_t type3[SCHF_TAIL_BITS];
 uint8_t mother[SCHF_TAIL_BITS * 4];
 uint8_t type4[SCHF_CODED_BITS];
 uint8_t type4i[SCHF_CODED_BITS];

 tetra_codec_crc16(info_268, SCHF_INFO_BITS, type2);
 memcpy(type3, type2, SCHF_CRC_BITS);
 memset(type3 + SCHF_CRC_BITS, 0, 4);

 int m = tetra_codec_conv_r14(type3, SCHF_TAIL_BITS, mother);
 int c = tetra_codec_puncture_r23(mother, m, type4);
 if (m != SCHF_TAIL_BITS * 4 || c != SCHF_CODED_BITS)
 return -1;

 tetra_codec_interleave_perm(type4, SCHF_CODED_BITS, 103, type4i);

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
