/*
 * tetra_tx_transport.c — TETRA TX Transport Layer (Phase Z.1 implementation)
 *
 * Routes each tx_pdu_class_t to the correct AXI reply mailbox.  Today (Z.1)
 * this is a thin wrapper over the existing mailbox writers; Z.2 will route
 * slot_class + aach_pattern through a unified DL-Signal-Queue submit path.
 *
 * Bit-identity guarantee: for the legacy classes (LU_ACCEPT, LU_REJECT,
 * GRP_ATTACH_ACK with default slot_class=0/aach_pattern=0) the byte
 * sequence written to the mailboxes matches the previous inline staging
 * in tetra_attach_daemon.c byte-for-byte.
 *
 * License: GPL v2
 */

#include "tetra_tx_transport.h"

#include <stddef.h>

/* Indirect-write helpers — match the (INDEX → DATA) sequence used in the
 * legacy daemon so the FPGA latches `data` at word `idx`. */
static void reply_write(tetra_hal_t *hal, uint32_t idx, uint32_t data)
{
    tetra_reg_write(hal, REG_REPLY_INDEX, idx);
    tetra_reg_write(hal, REG_REPLY_DATA,  data);
}

static void grp_reply_write(tetra_hal_t *hal, uint32_t idx, uint32_t data)
{
    tetra_reg_write(hal, REG_GRP_REPLY_INDEX, idx);
    tetra_reg_write(hal, REG_GRP_REPLY_DATA,  data);
}

/* mm=1 / mm=4 — D-LOC-UPDATE-ACCEPT / -REJECT body.
 *
 * For REJECT (result != 0) the GILA fields are zeroed — the RTL REJECT
 * encoder (rtl/lmac/tetra_d_location_update_reject_encoder.v) builds an
 * 8-bit MM body (PDU-Type=7 + 3-bit cause + o-bit=0) without GILA, and
 * the MLE-FSM Z.5 dual-branch FSM picks the REJECT branch when W3 != 0.
 * Mirror the suppression here as a safety net. */
static int submit_lu(tetra_hal_t *hal, const tx_pdu_meta_t *m,
                     uint32_t result)
{
    uint32_t gila_gssi     = (result == 0u) ? (m->gila_gssi & 0x00FFFFFFu) : 0u;
    uint32_t gila_class    = (result == 0u) ? (m->gila_class & 0x7u)       : 0u;
    uint32_t gila_lifetime = (result == 0u) ? (m->gila_lifetime & 0x3u)    : 0u;
    uint32_t gila_present  = (result == 0u) ? (m->gila_present & 0x1u)     : 0u;

    reply_write(hal, 0, m->target_ssi & 0x00FFFFFFu);
    reply_write(hal, 1, m->la & 0x3FFFu);
    reply_write(hal, 2, 0x1u);                   /* addr_type = Ssi+EventLabel */
    reply_write(hal, 3, result & 0x3u);          /* W3 selects ACCEPT(=0) vs
                                                  * REJECT(!=0) branch in the
                                                  * MLE-FSM (Z.5 dual-branch). */
    reply_write(hal, 4, gila_gssi);
    reply_write(hal, 5, (gila_class << 2) | gila_lifetime);
    reply_write(hal, 6, gila_present);
    reply_write(hal, 7, m->encryption & 0x3u);
    reply_write(hal, 8, (m->auth_result == 0u) ? 0x1u : (m->auth_result & 0x3u));

    tetra_reg_write(hal, REG_REPLY_GO, 0x1u);
    return 0;
}

/* mm=11 — D-ATTACH-DETACH-GROUP-IDENTITY-ACK body.
 *
 * Mirrors the W0..W8 layout written by service_grp_demand() in the legacy
 * daemon.  W6/W7 pack three records; the encoder stops at reply_count. */
static int submit_grp_ack(tetra_hal_t *hal, const tx_pdu_meta_t *m)
{
    uint8_t cnt = (m->reply_count > 3u) ? 3u : m->reply_count;

    grp_reply_write(hal, 0, m->target_ssi & 0x00FFFFFFu);
    grp_reply_write(hal, 1, m->accept_reject & 0x1u);
    grp_reply_write(hal, 2, cnt);
    grp_reply_write(hal, 3, m->gssi[0] & 0x00FFFFFFu);
    grp_reply_write(hal, 4, m->gssi[1] & 0x00FFFFFFu);
    grp_reply_write(hal, 5, m->gssi[2] & 0x00FFFFFFu);

    /* W6: at[2..0]=2bit each at [20:15], lifetime[2..0]=2bit at [13:9],
     *     adi[2..0]=1bit at [8:6] */
    uint32_t w6 = ((m->at[2]       & 0x3u) << 19)
                | ((m->at[1]       & 0x3u) << 17)
                | ((m->at[0]       & 0x3u) << 15)
                | ((m->lifetime[2] & 0x3u) << 13)
                | ((m->lifetime[1] & 0x3u) << 11)
                | ((m->lifetime[0] & 0x3u) <<  9)
                | ((m->adi[2]      & 0x1u) <<  8)
                | ((m->adi[1]      & 0x1u) <<  7)
                | ((m->adi[0]      & 0x1u) <<  6);
    grp_reply_write(hal, 6, w6);

    /* W7: cls[2..0]=3bit each at [8:0] */
    uint32_t w7 = ((m->cls[2] & 0x7u) << 6)
                | ((m->cls[1] & 0x7u) << 3)
                |  (m->cls[0] & 0x7u);
    grp_reply_write(hal, 7, w7);

    /* W8: ns@[1], nr@[0] */
    grp_reply_write(hal, 8, ((m->ns & 0x1u) << 1) | (m->nr & 0x1u));

    tetra_reg_write(hal, REG_GRP_REPLY_GO, 0x1u);
    return 0;
}

int tetra_tx_submit(tetra_hal_t *hal, tx_pdu_class_t cls,
                    const tx_pdu_meta_t *meta)
{
    if (hal == NULL || meta == NULL) return -1;

    switch (cls) {
    case TX_LU_ACCEPT:
        return submit_lu(hal, meta, 0u);
    case TX_LU_REJECT:
        return submit_lu(hal, meta, (meta->result != 0u) ? meta->result : 1u);
    case TX_GRP_ATTACH_ACK:
        return submit_grp_ack(hal, meta);
    default:
        return -1;
    }
}
