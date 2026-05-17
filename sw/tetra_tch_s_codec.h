/*
 * tetra_tch_s_codec.h — TCH/S 7.2 Voice Channel Codec
 *
 * ETSI EN 300 395-2 §8.5 / EN 300 392-2 §8.5 — TCH/S full-slot voice burst
 * channel coding (separate from SCH/F signaling channel coding).
 *
 * Port der tetra-kit/codec/sub_cc.c + sub_cd.c + const.tab + arrays.tab
 * ETSI-Reference-Implementation (4567 b/s ACELP + RCPC + block-interleave +
 * cell-scrambler).
 *
 * Frame structure:
 *   137 bits = 1 ACELP-Frame @ 30 ms (codec output)
 *   274 bits = 2 ACELP-Frames per burst (= 60 ms = 1 TETRA frame)
 *   432 bits = channel-coded burst (RCPC + CRC + tail)
 *
 * Coding chain (encode side):
 *   274 ACELP info bits
 *   → Build_Sensitivity_Classes (sort by class index tables TAB0/TAB1/TAB2)
 *      Class 0:  N0_2=102 unprotected bits
 *      Class 1:  N1_2=112 moderate-protected bits
 *      Class 2:  N2_2=60  highly-protected bits
 *   → Build_Crc (8-bit CRC over Class 2)
 *   → Append 4 tail zeros (encoder reset)
 *   → Rcpc_Coding (rate-1/3 mother conv + class-specific puncturing)
 *      Class 0 → 102 bits (direct, no encode)
 *      Class 1 → 168 bits (rate 8/12, A1 puncturing)
 *      Class 2 + CRC + tail → 162 bits (rate 8/18, A2 puncturing)
 *      Total = 102 + 168 + 162 = 432 bits
 *   → Interleaving_Speech (block matrix 24 × 18)
 *   → Cell scrambler (same LFSR as SCH/F)
 *
 * Decoding chain is the inverse.
 *
 * License: GPL v2 (port from osmo-tetra/tetra-kit which is GPL)
 */
#ifndef TETRA_TCH_S_CODEC_H
#define TETRA_TCH_S_CODEC_H

#include <stdint.h>

/* Constants per ETSI EN 300 395-2 const.tab */
#define TCH_S_FRAME_BITS       137  /* ACELP frame, 30 ms */
#define TCH_S_2_FRAMES_BITS    274  /* 2 ACELP frames per burst */
#define TCH_S_BURST_BITS       432  /* channel-coded burst, 60 ms */
#define TCH_S_N0               51   /* Class 0 size per frame */
#define TCH_S_N1               56   /* Class 1 size per frame */
#define TCH_S_N2               30   /* Class 2 size per frame */
#define TCH_S_N0_2             102  /* Class 0 size per burst */
#define TCH_S_N1_2             112  /* Class 1 size per burst */
#define TCH_S_N2_2             60   /* Class 2 size per burst */
#define TCH_S_N1_2_CODED       168  /* Class 1 after rate 8/12 RCPC */
#define TCH_S_N2_2_CODED       162  /* Class 2 + CRC + tail after rate 8/18 RCPC */
#define TCH_S_CRC_BITS         8
#define TCH_S_TAIL_BITS        4    /* K-1 zeros after CRC */
#define TCH_S_K                5    /* conv code constraint length */
#define TCH_S_PERIOD_PCT       8    /* puncturing period */
#define TCH_S_INTL_LINES       24
#define TCH_S_INTL_COLUMNS     18

/* Block-interleaver 24 × 18 (per ETSI §8.5.3.2):
 *   out[lines*COLS + cols] = in[cols*LINES + lines]
 * Inverse: out[cols*LINES + lines] = in[lines*COLS + cols] */
void tetra_tch_s_interleave_speech(const uint8_t in_432[432],
                                   uint8_t out_432[432]);
void tetra_tch_s_deinterleave_speech(const uint8_t in_432[432],
                                     uint8_t out_432[432]);

/* Cell scrambler — same LFSR as SCH/F (cell-derived init).
 * In-place XOR with LFSR sequence.
 * init = (MCC << 22) | (MNC << 8) | (CC << 2) | 3, or 0xFFFFFFFF if zero. */
void tetra_tch_s_scramble(uint8_t bits[432], uint32_t lfsr_init);

/* Full TCH/S burst encoder: 274 ACELP bits → 432 scrambled type-5 bits.
 * Returns 0 on success, negative on error. */
int tetra_tch_s_encode(const uint8_t acelp_274[274],
                       uint32_t scramb_init,
                       uint8_t type5_out_432[432]);

/* Full TCH/S burst decoder: 432 scrambled type-5 bits → 274 ACELP bits.
 * Returns 0 on success (CRC OK), negative on CRC mismatch. ACELP bits are
 * populated regardless (best-effort) so caller can inspect. */
int tetra_tch_s_decode(const uint8_t type5_432[432],
                       uint32_t scramb_init,
                       uint8_t acelp_out_274[274]);

#endif /* TETRA_TCH_S_CODEC_H */
