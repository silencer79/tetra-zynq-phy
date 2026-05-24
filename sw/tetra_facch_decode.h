/*
 * tetra_facch_decode.h — UL NTS2 FACCH-Stealing SCH/HD Soft-Decode
 *
 * Phase A (2026-05-23): Liest 432 signed 4-bit soft-values aus
 * REG_FACCH_NUB_READ_* Mailbox (FPGA-Capture von NTS2-Bursts auf
 * UL-Voice-Slot), dekodiert nur BKN1 als SCH/HD (124 info bits),
 * dispatched die resultierende CMCE-PDU an tetra_call_fsm_handle().
 *
 * Architektur-Parallele zu tetra_voice_pipe_tick (Voice-Pfad):
 *   voice_pipe_tick  reads voice_nub_mailbox → ACELP → DL filler
 *   facch_decode_tick reads facch_nub_mailbox → SCH/HD → CMCE → call_fsm
 *
 * License: GPL v2
 */
#ifndef TETRA_FACCH_DECODE_H
#define TETRA_FACCH_DECODE_H

#include <stdint.h>
#include "tetra_hal.h"

/* Poll REG_FACCH_NUB_READ_STATUS. If a burst is pending:
 *   1. Read 54 words (432 × 4-bit signed soft-values)
 *   2. Convert soft → hard (sign bit)
 *   3. Decode BKN1 = SCH/HD (216 type-5 → 124 info)
 *      - descramble (cell-init: MCC/MNC/CC/slot_num=1)
 *      - deinterleave (N=216, a=101)
 *      - depuncture P_2/3 → 576 mother bits
 *      - Viterbi R=1/4 (K=5) → 144 bits
 *      - strip 4 tail + CRC-16 check → 124 info
 *   4. If CRC OK + LLC + MLE-disc=CMCE: parse CMCE-PDU →
 *      tetra_call_fsm_handle(hal, ssi, &cmce_pdu)
 *   5. Pulse REG_FACCH_NUB_READ_ACK to arm next burst
 *
 * Returns:
 *   1  burst was decoded + dispatched (regardless of CRC)
 *   0  no burst pending
 *  -1  HAL error
 */
int tetra_facch_decode_tick(tetra_hal_t *hal);

#endif /* TETRA_FACCH_DECODE_H */
