/*
 * tetra_ts_map.h — Zentrale TS-Index ↔ HW-Resource Mapping (Multi-Group)
 *
 * Single source of truth für alle Konvertierungen zwischen
 *   - ETSI Timeslot 1..4 (1-based, kein TS0; TS1 = mcch, TS2..4 = Voice)
 *   - chan_alloc ts_assigned Bitmap MSB-first [TS1,TS2,TS3,TS4]
 *   - REG_VOICE_ACTIVE_MASK Bit-Position
 *   - REG_SLOT_AACH_TSn AXI-Register-Adresse
 *   - Erwarteter UL-DELTA-Counter-Wert (FPGA TS1-Stopuhr mit DL-TS3-Anker)
 *
 * 2026-05-25 — alle Werte aus kontrollierten Air-Tests validiert
 * (siehe project_ul_air_ts_mapping_validated.md).
 *
 * License: GPL v2
 */
#ifndef TETRA_TS_MAP_H
#define TETRA_TS_MAP_H

#include <stdint.h>
#include "tetra_hal.h"

/* ETSI TDMA-Timeslot-Index 1..4 (ETSI EN 300 392-2 §9.3, kein TS0). */
#define TETRA_ETSI_TS_MIN   1u
#define TETRA_ETSI_TS_MAX   4u

/* Voice-Slot-Bereich für BS-Allokation: TS1 ist mcch (Control),
 * TS2..TS4 sind Voice-Traffic-Slots. */
#define TETRA_VOICE_TS_MIN  2u
#define TETRA_VOICE_TS_MAX  4u

/* Clock-Domain @ 100 MHz. 1 ms = 100,000 cycles. */
#define TETRA_CLK_SYS_HZ            100000000u

/* TETRA Bit-Rate 36 kbit/s, 2 bits/Symbol → 18,000 Symbole/s.
 * 510 Bits = 255 Symbole pro Burst = 1 Timeslot.
 * 14.167 ms = 1,416,700 cycles @ 100 MHz. */
#define TETRA_CYCLES_PER_TS         1416700u

/* TS1-Stopuhr (REG_TS1_STOPWATCH_*) mit DL-TS3-Anker — gemessen 2026-05-25:
 *   voice_ts=TS2 → DELTA 22.499 ms (Vorhersage 22.502, ✓)
 *   voice_ts=TS3 → DELTA 36.669 ms (Vorhersage 36.674, ✓)
 *   voice_ts=TS4 → DELTA 50.836 ms (Vorhersage 50.841, ✓)
 * Schrittweite genau 1 TS = 14.167 ms. UL TS1 (mcch UL) ist nicht für Voice
 * allokiert, theoretisch DELTA = 8.34 ms. */
#define TETRA_TS1_UL_DELTA_CYC      834000u   /* 8.340 ms */

/* ETSI ts_assigned Bitmap (chan_alloc_element, 4 bits MSB-first [TS1..TS4]).
 *   TS1 → 0b1000   TS2 → 0b0100   TS3 → 0b0010   TS4 → 0b0001
 * 0 = nicht alloziert (RTL fällt auf Default TS2 zurück). */
static inline uint8_t tetra_ts_to_chan_alloc_bitmap(uint8_t etsi_ts)
{
 if (etsi_ts < TETRA_ETSI_TS_MIN || etsi_ts > TETRA_ETSI_TS_MAX) return 0u;
 return (uint8_t)(1u << (TETRA_ETSI_TS_MAX - etsi_ts));
}

/* REG_VOICE_ACTIVE_MASK Bit-Position (0-based wie RTL-Slot-Index).
 *   TS1 → bit 0 (0x01)   TS2 → bit 1 (0x02)   TS3 → bit 2 (0x04)   TS4 → bit 3 (0x08)
 * Mehrere aktive Calls: OR aller bits. */
static inline uint32_t tetra_ts_to_voice_mask_bit(uint8_t etsi_ts)
{
 if (etsi_ts < TETRA_ETSI_TS_MIN || etsi_ts > TETRA_ETSI_TS_MAX) return 0u;
 return (uint32_t)(1u << (etsi_ts - 1u));
}

/* AXI-Adresse von REG_SLOT_AACH_TSn (untere 14 bit = AACH-info). */
static inline uint32_t tetra_ts_to_aach_reg(uint8_t etsi_ts)
{
 switch (etsi_ts) {
 case 1u: return REG_SLOT_AACH_TS1;
 case 2u: return REG_SLOT_AACH_TS2;
 case 3u: return REG_SLOT_AACH_TS3;
 case 4u: return REG_SLOT_AACH_TS4;
 default: return 0u;
 }
}

/* Erwarteter DELTA-Counter-Wert (cycles) wenn UL-Burst auf etsi_ts ankommt.
 * Gegen REG_TS1_STOPWATCH_DELTA matchen (mit ±0.5 TS Toleranz). */
static inline uint32_t tetra_ts_to_expected_ul_delta(uint8_t etsi_ts)
{
 if (etsi_ts < TETRA_ETSI_TS_MIN || etsi_ts > TETRA_ETSI_TS_MAX) return 0u;
 return TETRA_TS1_UL_DELTA_CYC + (uint32_t)(etsi_ts - 1u) * TETRA_CYCLES_PER_TS;
}

/* Inverse von tetra_ts_to_expected_ul_delta: gemessenes DELTA → ETSI TS-Index.
 * Nearest-Center-Match mit ±0.5 TS Toleranz. Bei Frame-Wrap (DELTA klein
 * weil außerhalb [TS1, TS4] Bereich) reicht modulo-Frame-Rechnung. */
static inline uint8_t tetra_delta_to_etsi_ts(uint32_t delta_cyc)
{
 const uint32_t frame = (uint32_t)TETRA_ETSI_TS_MAX * TETRA_CYCLES_PER_TS;
 uint32_t rel = (delta_cyc + frame - (TETRA_TS1_UL_DELTA_CYC % frame)) % frame;
 uint32_t ts_idx = (rel + TETRA_CYCLES_PER_TS / 2u) / TETRA_CYCLES_PER_TS;
 if (ts_idx >= TETRA_ETSI_TS_MAX) ts_idx = 0u;
 return (uint8_t)(ts_idx + 1u);
}

#endif /* TETRA_TS_MAP_H */
