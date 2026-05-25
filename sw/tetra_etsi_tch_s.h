/*
 * tetra_etsi_tch_s.h — Wrapper for ETSI EN 300 395-2 TCH/S Channel Codec
 *
 * Thin C-API over tetra-kit/codec/Channel_Encoding + Channel_Decoding which
 * port the ETSI-reference C-code. We add the outer layer (cell-scrambler +
 * block-interleave 24×18) since tetra-kit codec only handles the inner RCPC
 * + CRC + class-reorder layer.
 *
 * Stages (decode side, UL → BS internal):
 *   1. Cell descramble (LFSR XOR over 432 bits)
 *   2. Block-deinterleave 24×18 (Desinterleaving_Speech)
 *   3. Channel_Decoding (RCPC depuncture + Viterbi + class-reorder + CRC)
 *      → 274 ACELP info bits = 2 × 137 ACELP frames @ 30 ms
 *
 * Stages (encode side, BS internal → DL):
 *   1. Channel_Encoding (class-reorder + CRC + RCPC encode + puncture)
 *   2. Block-interleave 24×18 (Interleaving_Speech)
 *   3. Cell scramble (LFSR XOR over 432 bits)
 *
 * Cell-scrambler init: (MCC<<22)|(MNC<<8)|(CC<<2)|3, or 0xFFFFFFFF if zero.
 * Same LFSR as SCH/F (cell scrambling code shared across non-BSCH channels).
 */
#ifndef TETRA_ETSI_TCH_S_H
#define TETRA_ETSI_TCH_S_H

#include <stdint.h>

/* Full UL decode: 432 on-air type-5 bits (= bit i = i-th UL air bit)
 * → 274 ACELP info bits. Returns CRC-OK status:
 *   0 = CRC OK, valid ACELP
 *  -1 = CRC FAIL, ACELP bits are best-effort (Viterbi output) */
int tetra_etsi_tch_s_decode_burst(const uint8_t type5_in_432[432],
 uint32_t scramb_init,
 uint8_t acelp_out_274[274]);

/* Full DL encode: 274 ACELP info bits → 432 on-air type-5 bits.
 * Returns 0 on success. */
int tetra_etsi_tch_s_encode_burst(const uint8_t acelp_in_274[274],
 uint32_t scramb_init,
 uint8_t type5_out_432[432]);

#endif /* TETRA_ETSI_TCH_S_H */
