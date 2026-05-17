/*
 * tetra_voice_pipe.h — Phase B: UL→DL Voice-Bit-Pipe with MAC-addr-Patch
 *
 * Polls the UL-NUB-Read-Mailbox, runs descramble + Viterbi + CRC check on
 * each captured 432-bit burst. If the burst decodes to a valid MAC-RESOURCE
 * PDU (pdu_type=00, CRC OK) the SSI in the header is patched to the active
 * call target (GSSI for group, ISSI for individual) and the bits are
 * re-encoded into the DL Voice-Filler-Mailbox. Otherwise the bits are
 * passed through 1:1 (TCH/S ACELP voice bursts have no MAC-header).
 *
 * Called from tetra_call_fsm_tick() once per daemon poll iteration.
 *
 * License: GPL v2
 */
#ifndef TETRA_VOICE_PIPE_H
#define TETRA_VOICE_PIPE_H

#include <stdint.h>
#include "tetra_hal.h"

/* Read one pending UL-NUB burst (if valid), decode, addr-patch, re-encode,
 * and write to the DL filler mailbox. Idempotent — no-op if no burst is
 * pending. target_ssi is the 24-bit MAC-address to substitute (GSSI for
 * group calls, ISSI for individual). If 0, the pipe runs in pass-through
 * (1:1) without patching.
 *
 * Returns:
 *    1 — burst processed (MAC patch + re-encode)
 *    0 — no burst pending, or burst was passed 1:1 (CRC fail / TCH/S)
 *   -1 — error (NULL hal etc.)
 */
int tetra_voice_pipe_tick(tetra_hal_t *hal, uint32_t target_ssi);

#endif /* TETRA_VOICE_PIPE_H */
