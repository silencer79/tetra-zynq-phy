/*
 * tetra_tx_transport.c — TETRA TX Transport Layer
 *
 * Phase Move-3+4 (2026-05-21): komplett umgebaut. SW baut jetzt die volle
 * 432-bit type-5 SCH/F-PDU (MAC-Resource + LLC + MLE-PD + MM + SCH/F-Encode)
 * in C und pusht sie via REG_DL_RAW_PDU_* in die DL-Signal-Queue. Ersetzt
 * die alte Reply-Pull-Mailbox + u_mle_registration_fsm + u_dl_pdu_builder
 * Pipeline (~5000 LUT).
 *
 * License: GPL v2
 */

#include "tetra_tx_transport.h"
#include "tetra_grpack_body.h"
#include "tetra_cmce_body.h"
#include "tetra_dl_pdu.h"
#include "tetra_mac_resource_dl_builder.h"

#include <stddef.h>
#include <string.h>

/* AACH-Pattern per PDU-Klasse (aus rtl/include/tetra_pdu_class.vh, original
 * vom MLE-FSM via accept_build_aach_pattern). 14-bit aach_pattern. */
#define AACH_SIGNALLING_ACTIVE 0x0009u  /* PDUC_FINAL_LU_ACCEPT_AACH */
#define AACH_IDLE_CMCE         0x0249u  /* PDUC_CMCE_D_CONNECT_AACH (BL-UDATA) */

/* CMCE addressing: SsiAndUsageMarker (6) — 24-bit SSI + 6-bit usage marker.
 *  burst #5887 D-CONNECT zeigt UsageMarker=11 (=0x0B). Hardcoded bis
 * Multi-Call Phase Y.5+. */
#define CMCE_USAGE_MARKER 11u

static uint32_t get_dl_scramble_init(tetra_hal_t *hal)
{
    uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
    uint32_t mcc  = cfg1 & 0x3FFu;
    uint32_t mnc  = (cfg1 >> 10) & 0x3FFFu;
    uint32_t cc   = tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3Fu;
    return (mcc << 22) | (mnc << 8) | (cc << 2) | 3u;
}

static uint8_t get_target_tn(tetra_hal_t *hal)
{
    return (uint8_t)(tetra_reg_read(hal, REG_SIGNAL_TARGET_TN) & 0x3u);
}

/* mm=1 / mm=4 — D-LOC-UPDATE-ACCEPT / -REJECT.
 *
 * ACCEPT: 102-bit MM body via tetra_build_d_loc_update_accept_mm.
 * REJECT: 8-bit MM body via tetra_build_d_loc_update_reject_mm. Beachte
 *         dass REJECT historisch SCH/HD blk1 nutzte (124-bit info). Phase
 *         Move-3+4 vereinfacht: REJECT geht auch über SCH/F (268-bit info,
 *         432-bit type-5) mit L2SigPdu LLC. MS akzeptiert beides — der
 *         entscheidende Match ist PDU-Type=0111 im MM body.
 */
static int submit_lu(tetra_hal_t *hal, const tx_pdu_meta_t *m, uint32_t result)
{
    uint32_t gila_gssi     = (result == 0u) ? (m->gila_gssi    & 0xFFFFFFu) : 0u;
    uint8_t  gila_class    = (result == 0u) ? (m->gila_class   & 0x7u)      : 0u;
    uint8_t  gila_lifetime = (result == 0u) ? (m->gila_lifetime & 0x3u)     : 0u;
    uint8_t  gila_present  = (result == 0u) ? (m->gila_present & 0x1u)      : 0u;

    uint8_t mm_bits[128];
    int     mm_len;

    if (result == 0u) {
        mm_len = tetra_build_d_loc_update_accept_mm(m->loc_acc_type,
                                                     gila_gssi, gila_class,
                                                     gila_lifetime, gila_present,
                                                     0x0000u /* StayAlive */,
                                                     mm_bits);
    } else {
        /* Reject cause mapping (ETSI Tab 16.43):
         *   1 (reject-temp) → 2 "no resources available"
         *   2 (reject-perm) → 1 "illegal MS"
         */
        uint8_t cause = (result == 1u) ? 2u : 1u;
        mm_len = tetra_build_d_loc_update_reject_mm(cause, mm_bits);
    }
    if (mm_len <= 0) return -1;

    tetra_mac_res_meta_t meta = {0};
    meta.ssi                = m->target_ssi;
    meta.addr_type          = MAC_ADDR_TYPE_SSI;
    meta.llc_pdu_type       = (result == 0u) ? MAC_LLC_BL_ADATA : MAC_LLC_L2SIG;
    meta.mle_pd             = MAC_MLE_PD_MM;
    meta.random_access_flag = 1u;  /* ACCEPT/REJECT ist RA-Response */

    return tetra_dl_pdu_build_and_push(hal, &meta, mm_bits, mm_len,
                                        get_dl_scramble_init(hal),
                                        0 /* SCH/F */,
                                        get_target_tn(hal),
                                        AACH_SIGNALLING_ACTIVE,
                                        0, 0);
}

/* mm=11 — D-ATTACH-DETACH-GROUP-IDENTITY-ACK. */
static int submit_grp_ack(tetra_hal_t *hal, const tx_pdu_meta_t *m)
{
    uint8_t cnt = (m->reply_count > TETRA_GRPACK_MAX_RECORDS)
                  ? TETRA_GRPACK_MAX_RECORDS : m->reply_count;

    grpack_meta_t gm;
    memset(&gm, 0, sizeof(gm));
    gm.accept_reject = m->accept_reject & 0x1u;
    gm.num_records   = cnt;
    for (unsigned i = 0; i < cnt; i++) {
        gm.records[i].atd            = m->adi[i] & 0x1u;
        gm.records[i].lifetime       = m->lifetime[i] & 0x3u;
        gm.records[i].class_of_usage = m->cls[i] & 0x7u;
        gm.records[i].addr_type      = m->at[i] & 0x3u;
        gm.records[i].gssi           = m->gssi[i] & 0xFFFFFFu;
    }

    uint8_t mm_bytes[TETRA_GRPACK_MAX_BYTES];
    int mm_byte_len = tetra_grpack_build(&gm, mm_bytes);
    if (mm_byte_len <= 0) return -1;

    /* tetra_grpack_build returnt Bit-Anzahl. Konvertiere zu Bit-Array. */
    int mm_len = mm_byte_len;
    uint8_t mm_bits[128];
    memset(mm_bits, 0, sizeof(mm_bits));
    for (int i = 0; i < mm_len; i++) {
        unsigned src_byte = (unsigned)(i >> 3);
        unsigned src_bit  = 7u - ((unsigned)i & 0x7u);
        mm_bits[i] = (uint8_t)((mm_bytes[src_byte] >> src_bit) & 0x1u);
    }

    tetra_mac_res_meta_t meta = {0};
    meta.ssi          = m->target_ssi;
    meta.addr_type    = MAC_ADDR_TYPE_SSI;
    meta.llc_pdu_type = MAC_LLC_BL_ADATA;
    meta.mle_pd       = MAC_MLE_PD_MM;
    meta.ns           = m->ns & 0x1u;
    meta.nr           = m->nr & 0x1u;

    return tetra_dl_pdu_build_and_push(hal, &meta, mm_bits, mm_len,
                                        get_dl_scramble_init(hal),
                                        0 /* SCH/F */,
                                        get_target_tn(hal),
                                        AACH_SIGNALLING_ACTIVE,
                                        0, 0);
}

/* CMCE submit helpers — D-SETUP / D-CONNECT / D-CALL-PROCEEDING /
 * D-TX-GRANTED / D-RELEASE / D-TX-CEASED. Body wird via tetra_cmce_build_*()
 * gebaut, dann MAC-RESOURCE/LLC-BL-UDATA wrap mit AddrType=SSI+Usage. */
static int submit_cmce_pdu(tetra_hal_t *hal,
                            const tx_pdu_meta_t *m,
                            int (*builder)(const cmce_meta_t *, uint8_t *))
{
    uint8_t mm_bytes[32];
    int mm_byte_len = builder(&m->cmce, mm_bytes);
    if (mm_byte_len <= 0) return -1;

    int mm_len = mm_byte_len;
    uint8_t mm_bits[128];
    memset(mm_bits, 0, sizeof(mm_bits));
    for (int i = 0; i < mm_len; i++) {
        unsigned src_byte = (unsigned)(i >> 3);
        unsigned src_bit  = 7u - ((unsigned)i & 0x7u);
        mm_bits[i] = (uint8_t)((mm_bytes[src_byte] >> src_bit) & 0x1u);
    }

    /* CMCE uses SsiAndUsageMarker + BL-UDATA + ChanAlloc element
     * (= 25-bit ChanAlloc-Replace pattern aus dem alten dl_pdu_builder). */
    tetra_mac_res_meta_t meta = {0};
    meta.ssi             = m->target_ssi;
    meta.addr_type       = MAC_ADDR_TYPE_SSI_USAGE;
    meta.usage_marker    = CMCE_USAGE_MARKER;
    meta.llc_pdu_type    = MAC_LLC_BL_UDATA;
    meta.mle_pd          = MAC_MLE_PD_CMCE;
    meta.ca_flag         = 1;
    meta.ca_element      = 0x00272FD3u;  /* identisch zur RTL Konstante */
    meta.ca_element_len  = 25;

    return tetra_dl_pdu_build_and_push(hal, &meta, mm_bits, mm_len,
                                        get_dl_scramble_init(hal),
                                        0 /* SCH/F */,
                                        get_target_tn(hal),
                                        AACH_IDLE_CMCE,
                                        0, 0);
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
    case TX_D_SETUP:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_setup);
    case TX_D_CALL_PROCEEDING:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_call_proceeding);
    case TX_D_CONNECT:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_connect);
    case TX_D_TX_GRANTED:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_tx_granted);
    case TX_D_TX_CEASED:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_tx_ceased);
    case TX_D_RELEASE:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_release);
    default:
        return -1;
    }
}
