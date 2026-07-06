/*
 * tetra_ul_reassembly.h — SW-seitige 2-Burst-SCH/HU-Reassembly (Option B)
 *
 * Spiegelt rtl/rx/tetra_ul_demand_reassembly.v bit-genau: fügt die zwei
 * SCH/HU-Bursts eines fragmentierten UL-PDU (MAC-ACCESS frag=1 + MAC-END-HU)
 * zum 147-bit TM-SDU-Body zusammen, den tetra_mm_demand_parser erwartet.
 *
 *   body[0..146] (MSB-first) = ul0_info[30..91] (62) ++ ul1_info[7..91] (85)
 *
 * 2 In-Flight-Slots, SSI-Key, Replace-on-same-SSI, Drop wenn beide belegt.
 * T0-Timeout hier als Wall-Clock (statt frame_tick) — Default ~113 ms.
 *
 * License: GPL v2
 */
#ifndef TETRA_UL_REASSEMBLY_H
#define TETRA_UL_REASSEMBLY_H

#include <stdint.h>

#define UL_REASS_BODY_BITS   147
#define UL_REASS_FRAG1_BITS   62   /* ul0_info[30..91] */
#define UL_REASS_END_BITS     85   /* ul1_info[7..91]  */
#define UL_REASS_T0_MS_DEFAULT 113 /* ETSI ~2 TDMA-frames */

typedef struct {
    int      occupied;
    uint32_t ssi;                       /* 24-bit */
    uint8_t  frag1[UL_REASS_FRAG1_BITS]; /* byte-per-bit, ul0_info[30..91] */
    uint16_t meta;                      /* 13-bit: [12:9]mm [8:6]mle [5:2]llc [1]ns [0]opt */
    uint32_t t0_deadline_ms;
} ul_reass_slot_t;

typedef struct {
    ul_reass_slot_t slot[2];
    uint32_t reass_cnt;
    uint32_t drop_cnt;
    uint32_t t0_ms;
} ul_reass_t;

/* t0_ms = 0 → UL_REASS_T0_MS_DEFAULT. */
void ul_reass_init(ul_reass_t *r, uint32_t t0_ms);

/* MAC-ACCESS frag=1: info92 = 92 dekodierte Info-Bits (byte-per-bit, MSB-first).
 * Latcht frag1 = info92[30..91] + meta in einen SSI-Slot (Replace > Alloc > Drop).
 * Rückgabe: Slot-Index 0/1, oder -1 wenn verworfen (beide belegt). */
int ul_reass_frag1(ul_reass_t *r, uint32_t ssi, const uint8_t *info92,
                   uint16_t meta13, uint32_t now_ms);

/* MAC-END-HU: info92 = 92 Info-Bits. Wenn ssi einen Slot matcht, splice
 * out_body[147] = frag1 ++ info92[7..91], liefert meta+ssi, gibt 1 zurück
 * (reass_cnt++). Sonst 0 (orphan END, kein Drop-Count). */
int ul_reass_end(ul_reass_t *r, uint32_t ssi, const uint8_t *info92,
                 uint8_t *out_body147, uint16_t *out_meta, uint32_t *out_ssi);

/* Wall-Clock-Tick: belegte Slots deren Deadline überschritten ist freigeben
 * (drop_cnt++). now_ms monoton. */
void ul_reass_tick(ul_reass_t *r, uint32_t now_ms);

#endif /* TETRA_UL_REASSEMBLY_H */
