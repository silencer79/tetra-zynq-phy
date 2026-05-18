/*
 * tetra_bs_tch_s.h — TCH/S Codec ported from BlueStation Rust → C
 *
 * Source: tetra-bluestation/crates/tetra-entities/src/lmac/components/
 *         {viterbi,convenc,tch_reorder,errorcontrol,scrambler,interleaver,crc16}.rs
 *
 * ETSI EN 300 395-2 §5.4/§5.5 (TCH/S Channel Coding) + §8.5 (TCH/S Burst)
 *
 * Key correctness points (= why we needed BlueStation instead of tetra-kit):
 *   - CONTINUOUS Viterbi over Class1 + Class2 (concatenated mother bits)
 *   - Rate-1/3 mother code with speech generators:
 *       G1 = 1+D+D²+D³+D⁴, G2 = 1+D+D³+D⁴, G3 = 1+D²+D⁴
 *   - 8-bit CRC over Class 2 only
 *   - Class-bit-interleaving between two ACELP subframes per class
 *
 * License: GPL v2 (compatible with BlueStation license).
 */
#ifndef TETRA_BS_TCH_S_H
#define TETRA_BS_TCH_S_H

#include <stdint.h>

/* High-level: 432 on-air type-5 bits → 274 ACELP info bits (= 2× 137-bit frames).
 * Returns 0 on CRC OK, -1 on CRC fail (ACELP best-effort populated regardless). */
int tetra_bs_tch_s_decode(const uint8_t type5_432[432],
 uint32_t scramb_init,
 uint8_t acelp_274[274]);

/* High-level: 274 ACELP info bits → 432 on-air type-5 bits. Always returns 0. */
int tetra_bs_tch_s_encode(const uint8_t acelp_274[274],
 uint32_t scramb_init,
 uint8_t type5_out_432[432]);

/* Soft-decision variant: input is 432 signed int8 soft-values per coded bit.
 * Convention: positive = '1', negative = '0', magnitude = confidence.
 * Recommended range: [-7, +7] (= 4-bit signed) to match RTL MSB-slice plan.
 * Larger magnitudes also work — Viterbi metric uses |soft| as weight. */
int tetra_bs_tch_s_decode_softi8(const int8_t softs_432[432],
 uint32_t scramb_init,
 uint8_t acelp_274[274]);

#endif /* TETRA_BS_TCH_S_H */
