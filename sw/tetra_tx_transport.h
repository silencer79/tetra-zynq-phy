/*
 * tetra_tx_transport.h — TETRA TX Transport Layer (Phase Z.1)
 *
 * Single-submit API for all DL signalling PDUs.  Hides AXI mailbox layout
 * details and (in Phase Z.2) slot-class / AACH-pattern selection.
 *
 * Today (Z.1): each tx_pdu_class_t maps to one of the existing mailbox
 * windows (Reply 0x220 for mm=1/4, Group-Reply 0x250 for mm=11).  No
 * on-air behaviour change vs. the previous inline staging.
 *
 * Z.2 will add `slot_class` and `aach_pattern` to the meta struct (already
 * present below as future-fields, default 0 = legacy behaviour) and route
 * them to a unified DL-Signal-Queue submit-mailbox.
 *
 * License: GPL v2
 */
#ifndef TETRA_TX_TRANSPORT_H
#define TETRA_TX_TRANSPORT_H

#include <stdint.h>
#include "tetra_hal.h"

typedef enum {
    TX_LU_ACCEPT       = 0,   /* mm=1, LI=21, SCH/F   → mcch              */
    TX_LU_REJECT       = 1,   /* mm=4, LI=7,  SCH/HD blk1 → mcch (Z.5)    */
    TX_GRP_ATTACH_ACK  = 2,   /* mm=11, LI=16, SCH/F  → mcch              */
    /* Future:
     * TX_BL_ACK_LI7, TX_NWRK_BCAST, TX_CALL_PROCEEDING, TX_TX_GRANTED,
     * TX_DETACH_ACK
     */
} tx_pdu_class_t;

/* Slot-class hint (Z.2+).  0 = legacy (RTL chooses default per existing
 * behaviour: Reply→NDB1 path inside MLE-FSM, Group-Reply→whatever the
 * scheduler latches).  Active selection lands in Z.2. */
typedef enum {
    TX_SLOT_DEFAULT    = 0,
    TX_SLOT_NDB1_SCHF  = 1,
    TX_SLOT_NDB2_BLK1  = 2,
    TX_SLOT_NDB2_BLK2  = 3,
    TX_SLOT_SCHHU      = 4,
    TX_SLOT_SB         = 5,
} tx_slot_class_t;

/* AACH override pattern (Z.2+).  0 = legacy (no override, RTL chooses
 * idle 0x0249 / signalling 0x0009 / etc per existing rules). */
typedef struct {
    /* ---- Common ---- */
    uint32_t target_ssi;        /* 24-bit MS-ISSI                          */

    /* ---- mm=1 / mm=4 (LU ACCEPT / REJECT) ---- */
    uint16_t la;                /* 14-bit cell LA                          */
    uint8_t  result;            /* 0=accept, 1=reject-temp, 2=reject-perm  */
    uint32_t gila_gssi;         /* 24-bit                                  */
    uint8_t  gila_class;        /* 3-bit                                   */
    uint8_t  gila_lifetime;     /* 2-bit                                   */
    uint8_t  gila_present;      /* 1-bit                                   */
    uint8_t  encryption;        /* 2-bit, reserved                         */
    uint8_t  auth_result;       /* 2-bit, reserved                         */

    /* ---- mm=11 (Group-Attach-ACK) ---- */
    uint8_t  reply_count;       /* 0..3                                    */
    uint32_t gssi[3];           /* 24-bit each                             */
    uint8_t  at[3];             /* 2-bit each: address-type per record     */
    uint8_t  lifetime[3];       /* 2-bit each                              */
    uint8_t  adi[3];            /* 1-bit each: attach=0/detach=1           */
    uint8_t  cls[3];            /* 3-bit each: class_of_usage              */
    uint8_t  ns, nr;            /* LLC stop-and-wait                       */
    uint8_t  accept_reject;     /* 0=accept, 1=reject (W1 of GRP reply)    */

    /* ---- Z.2 future-fields ---- */
    tx_slot_class_t slot_class; /* 0 = legacy                              */
    uint16_t        aach_pattern; /* 0 = no override                       */
} tx_pdu_meta_t;

/* Stage the PDU in the appropriate AXI reply mailbox and pulse GO.
 * Returns 0 on success, -1 if `cls` is unknown.  Does NOT ACK the demand
 * snapshot — caller is responsible for REG_*_DEMAND_ACK after the call.
 *
 * Hard requirement (Z.1): the on-air output for a given (cls, meta) must be
 * byte-for-byte identical to the previous inline staging logic in
 * tetra_attach_daemon.c.  Z.2 changes the slot-class/AACH path, not the
 * PDU bytes. */
int tetra_tx_submit(tetra_hal_t *hal, tx_pdu_class_t cls,
                    const tx_pdu_meta_t *meta);

#endif /* TETRA_TX_TRANSPORT_H */
