/*
 * tetra_facch_steal.h — DL FACCH-Stealing API (Phase 3)
 *
 * Stages a Gold-konformes Voice-Slot-Routing:
 *   - SCH/HD-encoded signaling als BKN1 (D-RELEASE / D-TX-CEASED PDU)
 *   - SCH/HD-encoded SYSINFO als BKN2 (FULL_STEAL_SIG / FULL_STEAL_FILLER)
 *     ODER TCH-Voice-Half als BKN2 (HALF_STEAL_SIG, vfill_blk2 wird genutzt)
 *   - REG_SLOT_MODE[tn] auf den passenden Mode setzen
 *
 * Workflow pro PTT-End-Sequenz (Gold-Pattern):
 *   1. MS U-DISCONNECT empfangen via facch_decode → call_fsm stage_d_release
 *   2. stage_d_release → tetra_facch_steal_stage_d_release() 6× pro Frame
 *      (mit selben Bits — Gold sendet D-RELEASE 6× identisch)
 *   3. Nach 6 Frames: tetra_facch_steal_stage_filler() bis nächster U-SETUP
 *
 * License: GPL v2
 */
#ifndef TETRA_FACCH_STEAL_H
#define TETRA_FACCH_STEAL_H

#include <stdint.h>
#include "tetra_hal.h"

/* Stage einen FACCH-Stealing-Frame auf voice-slot voice_tn:
 *   - bkn1_info_124: 124 MSB-first-bits der signaling-PDU
 *                    (MAC-RESOURCE + LLC + MLE-disc + CMCE)
 *   - bkn2_info_124: 124 MSB-first-bits für BKN2 (SCH/HD-encoded SYSINFO);
 *                    NULL → use vfill_blk2 als BKN2 (HALF_STEAL_SIG-Modus)
 *   - mode: SLOT_MODE_HALF_STEAL_SIG (2) | FULL_STEAL_SIG (3) | FULL_STEAL_FILLER (4)
 *
 * Macht intern:
 *   1. tetra_sch_hd_encode(bkn1_info_124) → 216 type-5 → REG_FACCH_STEAL_BKN1_*
 *   2. wenn bkn2_info_124!=NULL: tetra_sch_hd_encode(bkn2_info_124) → BKN2
 *   3. REG_SLOT_MODE[tn]=mode setzen
 *
 * Returns 0 on success, -1 on HAL error / invalid mode.
 */
int tetra_facch_steal_stage(tetra_hal_t *hal, unsigned voice_tn,
 uint8_t mode,
 const uint8_t *bkn1_info_124,
 const uint8_t *bkn2_info_124);

/* Convenience: clear slot_mode[tn] → fallback auf voice_active_mask-Pfad. */
void tetra_facch_steal_clear(tetra_hal_t *hal, unsigned voice_tn);

/* High-level: D-RELEASE via FACCH-Stealing on voice_tn. Builds 124-bit
 * MAC-RESOURCE + LLC-BL-UDATA + CMCE D-RELEASE PDU for BKN1, plus
 * 124-bit MAC-BROADCAST SYSINFO for BKN2 (gold-konformes 0x2049 NDB2
 * mit BKN2=SYSINFO-broadcast). slot_mode wird auf FULL_STEAL_SIG (3) gesetzt.
 *
 * Wenn als steady-state ohne D-RELEASE-Bits gewünscht (= Gold-Pattern nach
 * Call-Ende), nutze mode_after_release = SLOT_MODE_FULL_STEAL_FILLER mit
 * NULL-bits in BKN1.
 *
 * Returns 0 on success, -1 on error. */
int tetra_facch_steal_d_release(tetra_hal_t *hal, unsigned voice_tn,
 uint16_t call_id, uint32_t ssi, uint8_t cause);

/* High-level: nach D-RELEASE auf FULL_STEAL_FILLER wechseln (BKN1=NULL,
 * BKN2=SYSINFO). Gold sendet das dauerhaft nach Call-Ende. */
int tetra_facch_steal_filler(tetra_hal_t *hal, unsigned voice_tn);

/* Phase 3.3 (2026-05-23) — D-TX-CEASED via HALF_STEAL_SIG-mode.
 * Gold-konformes Routing: AACH=0x23C9 NDB2, BKN1=SCH/HD(MAC-RES SSI +
 * LLC + MLE + CMCE D-TX-CEASED), BKN2=TCH-Voice-Half (von vfill).
 * burst_dispatcher entscheidet bei slot_mode=2 + vfill_valid → BKN2 =
 * vfill_blk2 statt facch_bkn2.
 *
 * Returns 0 on success, -1 on error. */
int tetra_facch_steal_d_tx_ceased(tetra_hal_t *hal, unsigned voice_tn,
 uint16_t call_id, uint32_t ssi);

#endif /* TETRA_FACCH_STEAL_H */
