/*
 * tetra_sch_hd_encoder.h — SCH/HD channel coder (124-bit info → 216-bit type-5).
 *
 * Bit-identisch zur RTL-Implementierung tetra_sch_hd_encoder.v und
 * scripts/gen_sch_hd_tv.py.
 *
 * Pipeline:
 *   info(124) → CRC-16-CCITT (+4-bit tail zeros) → type-3 (144)
 *   → rate-1/4 mother conv encoder (G1=0x13, G2=0x1D, G3=0x17, G4=0x1B)
 *   → rate-2/3 puncture (same pattern as SCH/F)
 *   → multiplicative interleave (N=216, a=101)
 *   → cell scramble (same 32-bit LFSR as SCH/F/AACH/BSCH)
 *
 * Verwendet von tetra_facch_steal (Phase 3) um D-RELEASE/D-TX-CEASED-
 * Signaling-PDUs als FACCH-Steal-BKN1 zu encodieren.
 *
 * License: GPL v2
 */
#ifndef TETRA_SCH_HD_ENCODER_H
#define TETRA_SCH_HD_ENCODER_H

#include <stdint.h>

/* Full SCH/HD encoder: 124 bits info → 216 bits type-5.
 * Mirrors scripts/gen_sch_hd_tv.py::encode_sch_hd.
 * info_124[i] und out_216[i] sind beide MSB-first (bit 0 = erstes On-Air-Bit).
 */
void tetra_sch_hd_encode(const uint8_t *info_124, uint32_t scramb_init,
                          uint8_t *out_216);

#endif /* TETRA_SCH_HD_ENCODER_H */
