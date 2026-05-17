/*
 * tetra_etsi_tch_s.c — Wrapper for ETSI EN 300 395-2 TCH/S Channel Codec
 *
 * Hooks tetra-kit's Channel_Encoding / Channel_Decoding (ETSI reference C
 * code in sw/etsi_codec/) with the outer layer (cell-scrambler + block-
 * interleave 24×18) which is MAC/PHY-layer wrapping.
 *
 * Bit ordering convention:
 *   type5_in/out[i] = i-th bit on UL/DL air (i=0 first BKN1 air sym).
 *
 * Channel_Decoding expects 432 bits of "soft" Word16 values where 0→+127 and
 * 1→-127 (per tetra-kit's Rcpc_Decoding line 497). For hard 0/1 bits, we
 * just pass them through — the Rcpc_Decoding does the negate/shl mapping
 * internally.
 *
 * License: GPL v2.
 */

#include "tetra_etsi_tch_s.h"
#include "tetra_tch_s_codec.h"  /* outer layer: scramble + block-interleave */

#include "etsi_codec/channel.h"  /* Channel_Encoding / Channel_Decoding prototypes */

#include <string.h>

/* Persistent first-pass flags for the codec — tetra-kit's Channel_*ing
 * use these to call Init_Rcpc_Coding/Decoding once on first invocation. */
static int s_decode_first_pass = 1;
static int s_encode_first_pass = 1;

int tetra_etsi_tch_s_decode_burst(const uint8_t type5_in_432[432],
 uint32_t scramb_init,
 uint8_t acelp_out_274[274])
{
 /* 1. Descramble (in-place on a working copy) */
 uint8_t descrambled[432];
 memcpy(descrambled, type5_in_432, 432);
 tetra_tch_s_scramble(descrambled, scramb_init);

 /* 2. Block-deinterleave 24×18 */
 uint8_t deinterleaved[432];
 tetra_tch_s_deinterleave_speech(descrambled, deinterleaved);

 /* 3. Channel_Decoding (RCPC depuncture + Viterbi + CRC + class-reorder).
  *   Decoder erwartet ±127: 0 → +127, 1 → -127 (matches encoder output).
  *   Encoder schreibt Class 0 direct via Transform_Class_0 (= ±127)
  *   und RCPC-coded Class 1/2 als ±127 (sub_cc.c lines 532/540/547). */
 Word16 input_432[432];
 Word16 output_274[274];
 for (int i = 0; i < 432; i++)
 input_432[i] = deinterleaved[i] ? -127 : 127;

 Word16 bfi = Channel_Decoding((short)s_decode_first_pass, 0 /*FS=0*/,
 input_432, output_274);
 s_decode_first_pass = 0;

 for (int i = 0; i < 274; i++)
 acelp_out_274[i] = (uint8_t)(output_274[i] & 1);

 return bfi ? -1 : 0;
}

int tetra_etsi_tch_s_encode_burst(const uint8_t acelp_in_274[274],
 uint32_t scramb_init,
 uint8_t type5_out_432[432])
{
 /* 1. Channel_Encoding (class-reorder + CRC + RCPC + puncture) */
 Word16 input_274[274];
 Word16 output_432[432];
 for (int i = 0; i < 274; i++)
 input_274[i] = (Word16)(acelp_in_274[i] & 1);

 Channel_Encoding((short)s_encode_first_pass, 0 /*FS=0*/,
 input_274, output_432);
 s_encode_first_pass = 0;

 /* tetra-kit's Channel_Encoding writes Transform_Class_0 outputs as +127/-127
  *   for class 0 bits, and similar for protected classes. Convert to 0/1. */
 uint8_t channel_coded[432];
 for (int i = 0; i < 432; i++) {
 /* Tetra-kit convention: 0 → +127 → "0", 1 → -127 → "1".
  *   So negative Word16 = bit 1, non-negative = bit 0. */
 channel_coded[i] = (output_432[i] < 0) ? 1 : 0;
 }

 /* 2. Block-interleave 24×18 */
 uint8_t interleaved[432];
 tetra_tch_s_interleave_speech(channel_coded, interleaved);

 /* 3. Scramble */
 memcpy(type5_out_432, interleaved, 432);
 tetra_tch_s_scramble(type5_out_432, scramb_init);

 return 0;
}
