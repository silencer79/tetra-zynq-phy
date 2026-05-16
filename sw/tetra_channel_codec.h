/*
 * tetra_channel_codec.h — TETRA channel encoder primitives (SW side)
 *
 * Extracted from tetra_hal.c so the daemon binary can link the encoder
 * pipeline without pulling in tetra_hal.c's main() entry point.
 *
 * All bit arrays use one byte per bit (0 or 1), MSB-first within the
 * caller's logical bit stream. See per-function comments for ETSI refs.
 *
 * License: GPL v2
 */
#ifndef TETRA_CHANNEL_CODEC_H
#define TETRA_CHANNEL_CODEC_H

#include <stdint.h>

/* ETSI X.25 CRC-16 with final XOR (ETSI EN 300 392-2 §8.2.2).
 * Writes len + 16 bytes: input bits copied, then 16 CRC bits MSB-first.
 * out[] must have at least (len + 16) bytes of space.
 */
void tetra_codec_crc16(const uint8_t *bits, int len, uint8_t *out);

/* ETSI rate-1/4 mother convolutional encoder (§8.2.3, K=5, generators
 * G1=0x13, G2=0x1D, G3=0x17, G4=0x1B). out[] writes len*4 bits.
 * Returns number of bits written.
 */
int tetra_codec_conv_r14(const uint8_t *bits, int len, uint8_t *out);

/* P_2/3 puncture pattern over the rate-1/4 mother stream. Keeps
 * {g1(a), g2(a), g1(b)} per pair of input bits, dropping the rest.
 * Input length must be a multiple of 8. out[] writes len*3/8 bits.
 * Returns number of bits written, or -1 on length error.
 */
int tetra_codec_puncture_r23(const uint8_t *in, int len, uint8_t *out);

/* Multiplicative permutation interleaver (§8.2.4.1).
 *   out[k-1] = in[j-1] where j = 1 + (a*k) mod N, k = 1..N.
 * Typical (N, a): (120, 11) BSCH sb1, (216, 101) BNCH/SCH/HD/HU/STCH,
 * (432, 103) SCH/F / TCH/2.4.
 */
void tetra_codec_interleave_perm(const uint8_t *in, int N, int a,
                                 uint8_t *out);

/* High-level SCH/F encoder: 268 info bits → 432 type-5 bits.
 *   info(268) → CRC-16 → type-2(284) → +4 tail → type-3(288)
 *           → rate-1/4 mother(1152) → P_2/3 puncture → type-4(432)
 *           → interleave (K=432,a=103) → scramble → type-5(432)
 * Scrambler init: e(0..31) = MCC(10) | MNC(14) | CC(6) | slot_num(2).
 * Returns 0 on success, -1 on internal length mismatch.
 */
int tetra_codec_schf_encode(const uint8_t *info_268,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *out_432);

#endif /* TETRA_CHANNEL_CODEC_H */
