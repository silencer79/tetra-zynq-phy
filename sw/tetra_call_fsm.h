/*
 * tetra_call_fsm.h — Phase 7 G.5 Group-Call State Machine (per-SSI)
 *
 * Drives the BS-side response to MS-initiated CMCE PDUs:
 *   IDLE      ──U-SETUP────────▶  CONNECTING (D-CONNECT staged)
 *   CONNECTING ─(MS-acks)──────▶  CONNECTED
 *   CONNECTED ──U-TX-DEMAND───▶  TALKER  (D-TX-GRANTED staged)
 *   TALKER    ──U-TX-CEASED──▶  CONNECTED
 *   *         ──U-RELEASE────▶  RELEASING (D-RELEASE staged) → IDLE
 *
 * License: GPL v2
 */
#ifndef TETRA_CALL_FSM_H
#define TETRA_CALL_FSM_H

#include <stdint.h>
#include "tetra_hal.h"
#include "tetra_cmce_parser.h"

#define CALL_FSM_MAX_CALLS  8

typedef enum {
    CALL_STATE_IDLE       = 0,
    CALL_STATE_CONNECTING = 1,
    CALL_STATE_CONNECTED  = 2,
    CALL_STATE_TALKER     = 3,
    CALL_STATE_RELEASING  = 4,
} call_state_t;

typedef struct {
    uint32_t     ssi;            /* MS-ISSI initiator (0 = slot empty)      */
    uint32_t     group_gssi;     /* Target group (= U-SETUP called_party)   */
    uint16_t     call_id;        /* 14-bit, allocated by BS                 */
    call_state_t state;
    uint8_t      ns;             /* LLC stop-and-wait per call slot         */
    uint8_t      nr;
    uint32_t     last_activity_poll_cnt;  /* for stale-call eviction        */
} call_slot_t;

/* Dispatch one parsed UL CMCE PDU into the FSM.  Stages the appropriate
 * DL reply (if any) via tetra_tx_submit().  Returns:
 *    0  = handled, reply staged (or no reply needed)
 *   -1  = no free call slot
 *   -2  = unknown/unsupported pdu_type
 */
int tetra_call_fsm_handle(tetra_hal_t *hal, uint32_t ssi,
                          const cmce_pdu_t *p);

/* Diagnostic: print all active slots. */
void tetra_call_fsm_dump(void);

#endif /* TETRA_CALL_FSM_H */
