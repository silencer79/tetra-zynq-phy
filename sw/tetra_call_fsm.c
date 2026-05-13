/*
 * tetra_call_fsm.c — Phase 7 G.5 Group-Call State Machine.
 *
 * Per-SSI call slots (max CALL_FSM_MAX_CALLS in flight).  Dispatches UL
 * CMCE PDUs to DL responses via tetra_tx_submit() with the new TX_D_*
 * classes from G.4.
 *
 * MVP simplifications (will revisit):
 *   - CallId allocation is a monotonic counter, modulo 14 bits.  No
 *     reuse / collision check vs MS-side allocations.
 *   - D-CALL-PROCEEDING is skipped — BS jumps straight to D-CONNECT.
 *   - No timer-based release; explicit U-RELEASE only.
 *   - 1 talker at a time per call.  Multi-priority queue is post-MVP.
 *
 * License: GPL v2
 */

#include "tetra_call_fsm.h"
#include "tetra_tx_transport.h"
#include "tetra_cmce_body.h"

#include <stdio.h>
#include <string.h>

static call_slot_t g_slots[CALL_FSM_MAX_CALLS];
static uint16_t    g_next_call_id = 1u;

static call_slot_t *find_slot(uint32_t ssi)
{
    for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
        if (g_slots[i].ssi == ssi && ssi != 0u) return &g_slots[i];
    }
    return NULL;
}

static call_slot_t *alloc_slot(uint32_t ssi)
{
    for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
        if (g_slots[i].ssi == 0u) {
            memset(&g_slots[i], 0, sizeof(g_slots[i]));
            g_slots[i].ssi     = ssi;
            g_slots[i].call_id = g_next_call_id++;
            if ((g_next_call_id & 0x3FFFu) == 0u) g_next_call_id = 1u;
            g_slots[i].state   = CALL_STATE_IDLE;
            /* BS-side LLC stop-and-wait init nach MS NS=0:
             *   BS NS = 0 (eigenes erstes Daten-Frame)
             *   BS NR = 1 (next expected MS NS) */
            g_slots[i].ns = 0u;
            g_slots[i].nr = 1u;
            return &g_slots[i];
        }
    }
    return NULL;
}

static void free_slot(call_slot_t *s)
{
    memset(s, 0, sizeof(*s));
}

/* BS-side NS alterniert pro emittiertem BL-ADATA-Frame.  NR bleibt
 * unverändert solange MS keine neue NS-Sequenz signalisiert (MS sendet
 * BL-DATA = nur NS, kein NR; ein Wechsel von MS-NS würde NR togglen). */
static void nsnr_step_bs(call_slot_t *s)
{
    s->ns ^= 1u;
}

/* D-CALL-PROCEEDING — erste BS→MS-Antwort nach U-SETUP.  Per bluestation
 * `cc_bs.rs::rx_u_setup` Z. 478: bestätigt U-SETUP, hält MS-Setup-Timer am
 * Leben, MUSS vor D-CONNECT kommen. */
static int stage_d_call_proceeding(tetra_hal_t *hal, call_slot_t *s)
{
    tx_pdu_meta_t m;
    memset(&m, 0, sizeof(m));
    m.target_ssi              = s->ssi;
    m.ns                      = s->ns;
    m.nr                      = s->nr;
    m.cmce.call_identifier    = s->call_id & 0x3FFFu;
    return tetra_tx_submit(hal, TX_D_CALL_PROCEEDING, &m);
}

/* D-SETUP wird an die Group-GSSI gebroadcastet (bluestation Z. 532-561) —
 * tells other group members "someone has the floor".  transmission_grant =
 * GrantedToOtherUser (=3, NICHT Granted=0), BSI echoed aus U-SETUP. */
static int stage_d_setup(tetra_hal_t *hal, call_slot_t *s)
{
    tx_pdu_meta_t m;
    memset(&m, 0, sizeof(m));
    m.target_ssi              = s->group_gssi ? s->group_gssi : s->ssi;
    m.ns                      = s->ns;
    m.nr                      = s->nr;
    m.cmce.call_identifier    = s->call_id & 0x3FFFu;
    m.cmce.call_time_out      = 0;
    m.cmce.transmission_grant = 3;                     /* GrantedToOtherUser */
    m.cmce.transmission_request_permission = 0;        /* allowed to request */
    m.cmce.call_priority      = 4;
    m.cmce.calling_party_ssi  = s->ssi;
    /* BSI echoed from U-SETUP: TchS speech */
    m.cmce.bsi_circuit_mode_type  = 0;
    m.cmce.bsi_encryption_flag    = 0;
    m.cmce.bsi_communication_type = 1;
    m.cmce.bsi_speech_service     = 0;
    return tetra_tx_submit(hal, TX_D_SETUP, &m);
}

static int stage_d_connect(tetra_hal_t *hal, call_slot_t *s)
{
    tx_pdu_meta_t m;
    memset(&m, 0, sizeof(m));
    m.target_ssi              = s->ssi;
    m.ns                      = s->ns;
    m.nr                      = s->nr;
    m.cmce.call_identifier    = s->call_id & 0x3FFFu;
    m.cmce.call_time_out      = 0;                     /* infinite — call holds until release */
    m.cmce.transmission_grant = CMCE_TG_GRANTED;       /* 0 = Initiator-talker granted */
    m.cmce.transmission_request_permission = 1;        /* further demands allowed  */
    m.cmce.call_ownership     = 1;                     /* MS owns the call         */
    /* BSI present per Gold #5887 — MS muss wissen dass Speech-Service
     * confirmiert ist, sonst startet sie keinen TCH/S TX. */
    m.cmce.bsi_circuit_mode_type  = 0;                 /* TchS */
    m.cmce.bsi_encryption_flag    = 0;
    m.cmce.bsi_communication_type = 1;
    m.cmce.bsi_speech_service     = 0;
    return tetra_tx_submit(hal, TX_D_CONNECT, &m);
}

static int stage_d_tx_granted(tetra_hal_t *hal, call_slot_t *s)
{
    tx_pdu_meta_t m;
    memset(&m, 0, sizeof(m));
    m.target_ssi              = s->ssi;
    m.ns                      = s->ns;
    m.nr                      = s->nr;
    m.cmce.call_identifier    = s->call_id & 0x3FFFu;
    m.cmce.transmission_grant = CMCE_TG_GRANTED;       /* 0 = Granted */
    m.cmce.encryption_control = 0;
    return tetra_tx_submit(hal, TX_D_TX_GRANTED, &m);
}

static int stage_d_release(tetra_hal_t *hal, call_slot_t *s, uint8_t cause)
{
    tx_pdu_meta_t m;
    memset(&m, 0, sizeof(m));
    m.target_ssi              = s->ssi;
    m.ns                      = s->ns;
    m.nr                      = s->nr;
    m.cmce.call_identifier    = s->call_id & 0x3FFFu;
    m.cmce.disconnect_cause   = cause;
    return tetra_tx_submit(hal, TX_D_RELEASE, &m);
}

int tetra_call_fsm_handle(tetra_hal_t *hal, uint32_t ssi,
                          const cmce_pdu_t *p)
{
    if (p == NULL || ssi == 0u) return -2;

    call_slot_t *s = find_slot(ssi);

    switch (p->pdu_type) {
    case CMCE_U_SETUP: {
        if (s == NULL) {
            s = alloc_slot(ssi);
            if (s == NULL) {
                fprintf(stderr,
                        "tetra_call_fsm: U-SETUP ssi=0x%06X — no free slot\n",
                        ssi);
                return -1;
            }
        }
        /* Group-GSSI aus U-SETUP called_party übernehmen (CPTI=SSI). */
        s->group_gssi = (p->called_party_type_identifier == 1u
                        || p->called_party_type_identifier == 2u)
                       ? (p->called_party_ssi & 0x00FFFFFFu) : 0u;
        s->state = CALL_STATE_CONNECTING;

        /* Bluestation `cc_bs.rs::rx_u_setup` 3-Schritt-Sequenz:
         *   1) D-CALL-PROCEEDING an Caller MS (BS-NS=0)
         *   2) D-CONNECT an Caller MS (BS-NS=1, transmission_grant=Granted)
         *   3) D-SETUP an Group GSSI (broadcast, GrantedToOtherUser, BSI echoed) */
        int rc1 = stage_d_call_proceeding(hal, s);
        fprintf(stderr,
                "tetra_call_fsm: U-SETUP ssi=0x%06X gssi=0x%06X → D-CALL-PROCEEDING "
                "call_id=%u ns=%u nr=%u rc=%d\n",
                ssi, s->group_gssi, s->call_id, s->ns, s->nr, rc1);
        nsnr_step_bs(s);
        int rc2 = stage_d_connect(hal, s);
        fprintf(stderr,
                "tetra_call_fsm: U-SETUP → D-CONNECT call_id=%u ns=%u nr=%u rc=%d\n",
                s->call_id, s->ns, s->nr, rc2);
        nsnr_step_bs(s);
        int rc3 = (s->group_gssi != 0u) ? stage_d_setup(hal, s) : 0;
        if (s->group_gssi != 0u) {
            fprintf(stderr,
                    "tetra_call_fsm: U-SETUP → D-SETUP→GSSI 0x%06X ns=%u nr=%u rc=%d\n",
                    s->group_gssi, s->ns, s->nr, rc3);
            nsnr_step_bs(s);
        }
        s->state = CALL_STATE_CONNECTED;
        (void)rc1; (void)rc3;
        return rc2;
    }

    case CMCE_U_TX_DEMAND: {
        if (s == NULL) {
            /* No active call — silently drop. */
            return -1;
        }
        nsnr_step_bs(s);
        int rc = stage_d_tx_granted(hal, s);
        s->state = CALL_STATE_TALKER;
        fprintf(stderr,
                "tetra_call_fsm: U-TX-DEMAND ssi=0x%06X → D-TX-GRANTED "
                "call_id=%u ns=%u nr=%u rc=%d\n",
                ssi, s->call_id, s->ns, s->nr, rc);
        return rc;
    }

    case CMCE_U_TX_CEASED: {
        if (s == NULL) return -1;
        s->state = CALL_STATE_CONNECTED;
        fprintf(stderr,
                "tetra_call_fsm: U-TX-CEASED ssi=0x%06X (call_id=%u)\n",
                ssi, s->call_id);
        return 0;
    }

    case CMCE_U_RELEASE: {
        if (s == NULL) return -1;
        nsnr_step_bs(s);
        int rc = stage_d_release(hal, s, p->disconnect_cause);
        fprintf(stderr,
                "tetra_call_fsm: U-RELEASE ssi=0x%06X cause=%u → D-RELEASE "
                "call_id=%u rc=%d\n",
                ssi, p->disconnect_cause, s->call_id, rc);
        free_slot(s);
        return rc;
    }

    default:
        return -2;
    }
}

void tetra_call_fsm_dump(void)
{
    fprintf(stderr, "tetra_call_fsm slots:\n");
    for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
        if (g_slots[i].ssi == 0u) continue;
        fprintf(stderr,
                "  [%u] ssi=0x%06X call_id=%u state=%d ns=%u nr=%u\n",
                i, g_slots[i].ssi, g_slots[i].call_id,
                (int)g_slots[i].state, g_slots[i].ns, g_slots[i].nr);
    }
}
