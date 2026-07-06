/*
 * tetra_ul_rx_service.c — siehe tetra_ul_rx_service.h.
 */
#include "tetra_ul_rx_service.h"
#include "tetra_ul_rx_mailbox.h"
#include "tetra_ul_mac_parse.h"
#include "tetra_channel_codec.h"
#include <string.h>

void tetra_ul_rx_init(ul_rx_ctx_t *c, uint8_t cc, uint8_t scr_slot,
                      uint16_t mcc, uint16_t mnc)
{
    memset(c, 0, sizeof(*c));
    c->cc = cc; c->scr_slot = scr_slot; c->mcc = mcc; c->mnc = mnc;
    ul_reass_init(&c->demand, 0);
    ul_lsds_init(&c->lsds, 0);
}

void tetra_ul_rx_tick(ul_rx_ctx_t *c, uint32_t now_ms)
{
    ul_reass_tick(&c->demand, now_ms);
    ul_lsds_tick(&c->lsds, now_ms);
}

int tetra_ul_rx_service(ul_rx_ctx_t *c, const uint32_t *words,
                        uint32_t now_ms, ul_rx_result_t *out)
{
    ul_rx_burst_t b;
    memset(out, 0, sizeof(*out));
    if (tetra_ul_rx_unpack(words, &b) != 0)
        return 0;                                  /* ungültiger Burst */

    int slot = b.slot_tn & 3;

    /* ---------------- SCH/HU (Control: RA / MAC-ACCESS / MAC-END-HU) ------- */
    if (b.burst_type == UL_RX_BT_SCHHU) {
        uint8_t info[92];
        int rc = tetra_codec_schhu_decode_soft(b.soft, c->cc, c->scr_slot,
                                               c->mcc, c->mnc, info);
        out->crc_ok = (rc == 0);
        if (rc != 0) return 1;                     /* CRC-Fail → verwerfen */

        if (tetra_ul_is_mac_end_hu(info)) {
            /* 2. Burst des Demand-Handshakes — SSI aus dem reservierten Slot. */
            uint32_t ssi = c->slot_ssi[slot];
            if (ul_reass_end(&c->demand, ssi, info, out->body, &out->meta, &out->ssi)) {
                out->have_body = 1;
                out->body_len  = UL_REASS_BODY_BITS;   /* 147 */
                out->source    = UL_RX_SRC_DEMAND;
            }
            return 1;
        }

        /* MAC-ACCESS */
        ul_mac_access_t p;
        tetra_ul_mac_access_parse(info, &p);

        if (p.frag_flag) {
            /* Fragmentierter Start: der Slot gehört ab jetzt dieser SSI; BEIDE
             * Akkumulatoren starten (Continuation kommt als SCH/HU-END → Demand,
             * oder als SCH/F-Fragmente → Long-SDS; der passende gewinnt). */
            c->slot_ssi[slot] = p.issi;
            ul_reass_frag1(&c->demand, p.issi, info, p.meta13, now_ms);
            ul_lsds_start(&c->lsds, p.issi, info, p.opt_flag, now_ms);
            return 1;                              /* noch kein Body */
        }

        /* Nicht-fragmentiert: komplette PDU in diesem Burst (TL-SDU..91). */
        int start = p.tl_sdu_start;
        out->body_len = 92 - start;
        for (int i = 0; i < out->body_len; i++)
            out->body[i] = info[start + i] & 1;
        out->ssi      = p.issi;
        out->meta     = p.meta13;
        out->have_body = 1;
        out->source   = UL_RX_SRC_SINGLE;
        return 1;
    }

    /* ---------------- SCH/F (Long-SDS Continuation) ------------------------ */
    if (b.burst_type == UL_RX_BT_SCHF) {
        uint8_t info[268];
        int rc = tetra_codec_schf_decode_soft(b.soft, c->cc, c->scr_slot,
                                              c->mcc, c->mnc, info);
        out->crc_ok = (rc == 0);
        if (rc != 0) return 1;

        int is_end;
        if (tetra_ul_schf_is_frag(info, &is_end)) {
            if (ul_lsds_frag(&c->lsds, info, is_end, now_ms,
                             out->body, &out->body_len, &out->ssi, NULL)) {
                out->have_body = 1;
                out->source    = UL_RX_SRC_LONGSDS;
            }
        }
        return 1;
    }

    /* TCH/S Voice läuft über den bestehenden Voice-Pfad, nicht hier. */
    return 1;
}
