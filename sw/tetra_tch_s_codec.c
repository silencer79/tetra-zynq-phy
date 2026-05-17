/*
 * tetra_tch_s_codec.c — TCH/S 7.2 Voice Channel Codec (ETSI EN 300 395-2 §8.5)
 *
 * Port der tetra-kit/codec/{sub_cc,sub_cd}.c + const.tab + arrays.tab
 * ETSI-Reference-Implementation.
 *
 * Phase 1 (this file): Outer layer only —
 *   - Block-interleave 24×18 (Interleaving_Speech / Desinterleaving_Speech)
 *   - Cell scrambler (same as SCH/F, identical init from MCC/MNC/CC)
 *
 * Phase 2 (TODO): Inner RCPC layer —
 *   - Build_Sensitivity_Classes / inverse class-reorder via TAB0/TAB1/TAB2
 *   - CRC-8 build + check
 *   - RCPC encode/decode (rate 8/12 class 1, rate 8/18 class 2 + CRC + tail)
 *
 * License: GPL v2 (port from osmo-tetra/tetra-kit which is GPL)
 */

#include "tetra_tch_s_codec.h"
#include <string.h>

/* ========================================================================
 * Phase 1: Block-Interleaver 24 × 18 (ETSI §8.5.3.2)
 * Forward: Interleaving_Speech
 *   out[col*LINES + line] = in[line*COLS + col]
 *
 * Equivalent to "write row-by-row, read column-by-column" of a 24×18 matrix
 * (with LINES=24, COLUMNS=18).
 *
 * Inverse: Desinterleaving_Speech
 *   out[line*COLS + col] = in[col*LINES + line]
 * ======================================================================== */

void tetra_tch_s_interleave_speech(const uint8_t in_432[432], uint8_t out_432[432])
{
 for (int col = 0; col < TCH_S_INTL_COLUMNS; col++) {
 for (int line = 0; line < TCH_S_INTL_LINES; line++) {
 out_432[col * TCH_S_INTL_LINES + line] =
 in_432[line * TCH_S_INTL_COLUMNS + col];
 }
 }
}

void tetra_tch_s_deinterleave_speech(const uint8_t in_432[432], uint8_t out_432[432])
{
 for (int col = 0; col < TCH_S_INTL_COLUMNS; col++) {
 for (int line = 0; line < TCH_S_INTL_LINES; line++) {
 out_432[line * TCH_S_INTL_COLUMNS + col] =
 in_432[col * TCH_S_INTL_LINES + line];
 }
 }
}

/* ========================================================================
 * Phase 1: Cell scrambler — Fibonacci LFSR, init from MCC/MNC/CC pack.
 * Identical to SCH/F scrambler (cell scrambling code shared across all
 * non-BSCH channels per ETSI §8.2.5.2). In-place XOR with LFSR sequence.
 * ======================================================================== */

static uint8_t next_lfsr_bit(uint32_t *lfsr)
{
 uint32_t fb = ((*lfsr >> 0) ^ (*lfsr >> 6) ^ (*lfsr >> 9) ^
 (*lfsr >> 10) ^ (*lfsr >> 16) ^ (*lfsr >> 20) ^
 (*lfsr >> 21) ^ (*lfsr >> 22) ^ (*lfsr >> 24) ^
 (*lfsr >> 25) ^ (*lfsr >> 27) ^ (*lfsr >> 28) ^
 (*lfsr >> 30) ^ (*lfsr >> 31)) & 1u;
 *lfsr = (fb << 31) | (*lfsr >> 1);
 return (uint8_t)fb;
}

void tetra_tch_s_scramble(uint8_t bits[432], uint32_t lfsr_init)
{
 uint32_t lfsr = lfsr_init ? lfsr_init: 0xFFFFFFFFu;
 for (int i = 0; i < TCH_S_BURST_BITS; i++)
 bits[i] ^= next_lfsr_bit(&lfsr);
}

/* ========================================================================
 * Phase 2: Class-Index Tables — port from tetra-kit/codec/arrays.tab
 * Ranks of bits in ACELP-frame (1..137) protected by each class.
 * Class 0 (N0=51): unprotected, least sensitive
 * Class 1 (N1=56): rate 8/12 RCPC-protected
 * Class 2 (N2=30): rate 8/18 RCPC-protected
 * ======================================================================== */

static const uint16_t TAB0[TCH_S_N0] = {
 35,36,37,38,39,40,41,42,43, 47,48,
 56, 61,62,63,64,65,66,67,68,69,70,
 74,75, 83, 88,89,90,91,92,93,94,95,
 96,97, 101,102, 110,115,116,117,118,
 119,120,121,122,123,124, 128,129,
 137
};

static const uint16_t TAB1[TCH_S_N1] = {
 58,85,112, 54,81,108,135, 50,77,
 104,131, 45,72,99,126, 55,82,109,
 136, 5,13,34, 8,16,17, 22,23,24,
 25,26, 6,14,7,15, 60,87,114, 46,
 73,100,127, 44,71,98,125, 33,49,
 76,103,130, 59,86,113, 57,84,111
};

static const uint16_t TAB2[TCH_S_N2] = {
 18,19,20,21,   /* LSF3 */
 31,32,         /* Pitch0 */
 53,80,107,134, /* Energie 3 */
 1,2,3,4,       /* LSF1 */
 9,10,11,12,    /* LSF2 */
 27,28,29,30,   /* Pitch0 */
 52,79,106,133, /* Energie 4 */
 51,78,105,132  /* Energie 5 */
};

/* ========================================================================
 * Build_Sensitivity_Classes — encode side: re-order ACELP bits by class.
 * Input:  Input_Frame[274] = 2 × 137 ACELP bits (frame 1 in [0..136], frame 2 in [137..273])
 * Output: Output_Frame[N0_2 + N1_2 + N2_2] = 102 + 112 + 60 = 274 bits, class-ordered
 *
 * For each of the 2 frames, copy bits TAB_x[i]-1 → class-ordered position.
 * Output layout:
 *   [0..101]    = Class 0 (frame1 50 + frame2 51, interleaved per ETSI)
 *   [102..213]  = Class 1 (frame1 56 + frame2 56, interleaved)
 *   [214..273]  = Class 2 (frame1 30 + frame2 30, interleaved)
 *
 * The "interleaved" layout per tetra-kit is actually frame-by-frame:
 *   class-bits-of-frame1 followed by class-bits-of-frame2 within each class.
 * Verified against sub_cc.c::Build_Sensitivity_Classes loops.
 * ======================================================================== */

static void build_sensitivity_classes(const uint8_t in_274[274], uint8_t out_274[274])
{
 int pos = 0;
 /* Class 0 (N0_2 = 102 bits = 51 from each frame) */
 for (int i = 0; i < TCH_S_N0; i++) out_274[pos++] = in_274[TAB0[i] - 1];
 for (int i = 0; i < TCH_S_N0; i++) out_274[pos++] = in_274[137 + TAB0[i] - 1];
 /* Class 1 (N1_2 = 112 bits = 56 from each frame) */
 for (int i = 0; i < TCH_S_N1; i++) out_274[pos++] = in_274[TAB1[i] - 1];
 for (int i = 0; i < TCH_S_N1; i++) out_274[pos++] = in_274[137 + TAB1[i] - 1];
 /* Class 2 (N2_2 = 60 bits = 30 from each frame) */
 for (int i = 0; i < TCH_S_N2; i++) out_274[pos++] = in_274[TAB2[i] - 1];
 for (int i = 0; i < TCH_S_N2; i++) out_274[pos++] = in_274[137 + TAB2[i] - 1];
}

/* Inverse: take class-ordered 274 → 274 ACELP bits */
static void unbuild_sensitivity_classes(const uint8_t in_274[274], uint8_t out_274[274])
{
 int pos = 0;
 for (int i = 0; i < TCH_S_N0; i++) out_274[TAB0[i] - 1] = in_274[pos++];
 for (int i = 0; i < TCH_S_N0; i++) out_274[137 + TAB0[i] - 1] = in_274[pos++];
 for (int i = 0; i < TCH_S_N1; i++) out_274[TAB1[i] - 1] = in_274[pos++];
 for (int i = 0; i < TCH_S_N1; i++) out_274[137 + TAB1[i] - 1] = in_274[pos++];
 for (int i = 0; i < TCH_S_N2; i++) out_274[TAB2[i] - 1] = in_274[pos++];
 for (int i = 0; i < TCH_S_N2; i++) out_274[137 + TAB2[i] - 1] = in_274[pos++];
}

/* Mark these as unused for now to silence warnings until Phase 2 hooks them */
__attribute__((unused)) static void use_class_reorder(void)
{
 uint8_t a[274] = {0}, b[274] = {0};
 build_sensitivity_classes(a, b);
 unbuild_sensitivity_classes(b, a);
}

int tetra_tch_s_encode(const uint8_t acelp_274[274],
 uint32_t scramb_init,
 uint8_t type5_out_432[432])
{
 (void)acelp_274;
 (void)scramb_init;
 (void)type5_out_432;
 return -1; /* TODO: Phase 2 — CRC + RCPC encode */
}

int tetra_tch_s_decode(const uint8_t type5_432[432],
 uint32_t scramb_init,
 uint8_t acelp_out_274[274])
{
 (void)type5_432;
 (void)scramb_init;
 (void)acelp_out_274;
 return -1; /* TODO: Phase 2 — CRC + RCPC decode (Viterbi) */
}
