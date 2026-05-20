/*
 * tetra_sch_f_encoder.h — SCH/F channel coder (268-bit info → 432-bit type-5).
 *
 * Bit-identisch zur RTL-Implementierung tetra_sch_f_encoder.v und
 * scripts/gen_sch_f_tv.py.
 *
 * Pipeline:
 *   info(268) → CRC-16-CCITT (+4-bit tail zeros) → type-3 (288)
 *   → rate-1/4 mother conv encoder (G1=0x13, G2=0x1D, G3=0x17, G4=0x1B)
 *   → rate-2/3 puncture (keep G1, G2 of even input, G1 of odd input)
 *   → multiplicative interleave (N=432, a=103, ETSI Table 8.13)
 *   → cell scramble (32-bit Fibonacci LFSR, same taps as BSCH/AACH/SCH-HD)
 *
 * License: GPL v2
 */
#ifndef TETRA_SCH_F_ENCODER_H
#define TETRA_SCH_F_ENCODER_H

#include <stdint.h>

/* Full SCH/F encoder: 268 bits info → 432 bits type-5.
 * Mirrors scripts/gen_sch_f_tv.py::encode_sch_f.
 * info_268[i] und out_432[i] sind beide MSB-first (bit 0 = erstes On-Air-Bit).
 */
void tetra_sch_f_encode(const uint8_t *info_268, uint32_t scramb_init,
                         uint8_t *out_432);

#endif /* TETRA_SCH_F_ENCODER_H */
