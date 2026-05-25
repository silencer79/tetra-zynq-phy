/*
 * tetra_voice_filler.h — Voice-Slot Filler (Phase A static-MAC-RESOURCE)
 *
 * Builds and installs a SCH/F MAC-RESOURCE NULL-PDU addressed to the
 * active group GSSI into REG_VOICE_FILLER_* (Bank-1 0x270..0x27C). The
 * burst_dispatcher emits these 432 type-5 bits on the voice-slot during
 * an active group-call so the MS sees a valid signalling burst (CRC-OK,
 * addressed to its group) on the slot AACH 0x32CB advertises as voice.
 *
 * Phase A purpose: MS-acceptance of PTT setup. Audio relay (Phase B)
 * replaces the NULL-PDU with UL-NUB bits decoded + addr-patched + re-
 * encoded in SW.
 *
 * License: GPL v2
 */
#ifndef TETRA_VOICE_FILLER_H
#define TETRA_VOICE_FILLER_H

#include <stdint.h>
#include "tetra_hal.h"

/* Build SCH/F MAC-RESOURCE NULL-PDU with GSSI address, encode to 432
 * type-5 bits, pack LSB-first into 14 × 32-bit words, write into the
 * Voice-Filler-Mailbox via AXI, and set W14[0]=1 + GO pulse.
 *
 * Cell parameters (MCC/MNC/CC) read from REG_COLOUR_CODE + REG_CELL_CFG_1
 * — must be programmed before this call (typically by tetra_sysinfo).
 *
 * Returns 0 on success, -1 on encoder error.
 */
int tetra_voice_filler_install(tetra_hal_t *hal, uint32_t group_gssi);

/* Clear ALL 4 TS-Banks (Multi-Group 2026-05-25 — clear-all-banks ist die
 * Default-Semantik für Boot / globalen Reset). */
void tetra_voice_filler_clear(tetra_hal_t *hal);

/* Multi-Group 2026-05-25 — per-TS-Bank Operationen. target_ts ∈ {1..4}. */
int  tetra_voice_filler_write_ts(tetra_hal_t *hal,
 const uint8_t *type5_432,
 unsigned target_ts);
void tetra_voice_filler_clear_ts(tetra_hal_t *hal, unsigned target_ts);

#endif /* TETRA_VOICE_FILLER_H */
