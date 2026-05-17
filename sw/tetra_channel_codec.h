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

/* Descramble (XOR with cell-identity LFSR). Cell-init identisch zu
 * scrambler in tetra_codec_schf_encode. type5 → type4. */
void tetra_codec_descramble(const uint8_t *type5_in, int len,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *type4_out);

/* Inverse multiplicative permutation. Wenn interleave_perm
 *   out[j-1] = in[k-1] mit j = 1 + (a*k) mod N
 * setzt, dann ist die Inverse:
 *   inv_out[k-1] = in[j-1] mit gleicher j-Formel.
 * I.e. dieselbe Permutationsformel, nur Rollen vertauscht. */
void tetra_codec_deinterleave_perm(const uint8_t *in, int N, int a,
                                   uint8_t *out);

/* P_2/3 depuncture (Inverse zu tetra_codec_puncture_r23). 3 punctured
 * bits pro 8 mother bits werden in {0,1,4} eingesetzt; Erasures (=2)
 * auf {2,3,5,6,7}. in_len muss vielfaches von 3 sein. Output-Länge =
 * (in_len/3) × 8. */
void tetra_codec_depuncture_r23(const uint8_t *in_punct, int in_len,
                                uint8_t *out_mother);

/* K=5 rate-1/4 Viterbi mother-decoder. coded_in (Länge n_input × 4)
 * enthält Werte 0/1/2 (2 = Erasure, beiträgt 0 zur Hamming-Metrik).
 * Initial-State = 0 (Encoder startet mit shift-register=0). Output:
 * n_input dekodierte Bits. */
void tetra_codec_viterbi_r14(const uint8_t *coded_in, int n_input,
                             uint8_t *decoded_out);

/* High-level SCH/F decoder: 432 type-5 bits → 268 info bits.
 * type5 → descramble → deinterleave (K=432,a=103) → depuncture P_2/3 →
 *      → Viterbi(288) → strip 4 tail bits + CRC-16-check → info(268)
 * Returns 0 on success (CRC OK), -1 on CRC mismatch. info_268_out
 * is populated regardless (best-effort) so caller can inspect. */
int tetra_codec_schf_decode(const uint8_t *type5_in,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *info_268_out);

#endif /* TETRA_CHANNEL_CODEC_H */
