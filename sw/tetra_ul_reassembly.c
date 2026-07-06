/*
 * tetra_ul_reassembly.c — siehe tetra_ul_reassembly.h.
 * Bit-genaue SW-Spiegelung von rtl/rx/tetra_ul_demand_reassembly.v.
 */
#include "tetra_ul_reassembly.h"
#include <string.h>

void ul_reass_init(ul_reass_t *r, uint32_t t0_ms)
{
    memset(r, 0, sizeof(*r));
    r->t0_ms = t0_ms ? t0_ms : UL_REASS_T0_MS_DEFAULT;
}

void ul_reass_tick(ul_reass_t *r, uint32_t now_ms)
{
    for (int i = 0; i < 2; i++) {
        if (r->slot[i].occupied &&
            (int32_t)(now_ms - r->slot[i].t0_deadline_ms) >= 0) {
            r->slot[i].occupied = 0;
            r->drop_cnt++;
        }
    }
}

int ul_reass_frag1(ul_reass_t *r, uint32_t ssi, const uint8_t *info92,
                   uint16_t meta13, uint32_t now_ms)
{
    /* Replace-on-same-SSI (legitimer Re-Try) > Alloc erster freier > Drop.
     * Reihenfolge exakt wie im RTL (s0_replace > s1_replace > alloc_s0 >
     * alloc_s1 > drop_new). */
    int target = -1;
    if (r->slot[0].occupied && r->slot[0].ssi == ssi)       target = 0;
    else if (r->slot[1].occupied && r->slot[1].ssi == ssi)  target = 1;
    else if (!r->slot[0].occupied)                          target = 0;
    else if (!r->slot[1].occupied)                          target = 1;
    else { r->drop_cnt++; return -1; }

    ul_reass_slot_t *s = &r->slot[target];
    s->occupied = 1;
    s->ssi = ssi & 0xFFFFFFu;
    for (int b = 0; b < UL_REASS_FRAG1_BITS; b++)
        s->frag1[b] = info92[30 + b] & 1;      /* ul0_info[30..91] */
    s->meta = meta13 & 0x1FFFu;
    s->t0_deadline_ms = now_ms + r->t0_ms;
    return target;
}

int ul_reass_end(ul_reass_t *r, uint32_t ssi, const uint8_t *info92,
                 uint8_t *out_body147, uint16_t *out_meta, uint32_t *out_ssi)
{
    /* Slot 0 gewinnt bei Gleichstand (älter), wie im RTL. */
    int m = -1;
    if (r->slot[0].occupied && r->slot[0].ssi == (ssi & 0xFFFFFFu))      m = 0;
    else if (r->slot[1].occupied && r->slot[1].ssi == (ssi & 0xFFFFFFu)) m = 1;
    if (m < 0) return 0;                        /* orphan END — kein Drop */

    ul_reass_slot_t *s = &r->slot[m];
    /* body[0..61] = frag1 (= ul0_info[30..91]); body[62..146] = ul1_info[7..91]. */
    for (int b = 0; b < UL_REASS_FRAG1_BITS; b++)
        out_body147[b] = s->frag1[b];
    for (int b = 0; b < UL_REASS_END_BITS; b++)
        out_body147[UL_REASS_FRAG1_BITS + b] = info92[7 + b] & 1;

    if (out_meta) *out_meta = s->meta;
    if (out_ssi)  *out_ssi  = s->ssi;
    s->occupied = 0;
    r->reass_cnt++;
    return 1;
}

/* ========================================================================
 * Long-SDS Multi-Fragment (SCH/F) — Spiegel tetra_ul_schf_reassembly.v.
 * ======================================================================== */
void ul_lsds_init(ul_lsds_t *r, uint32_t t0_ms)
{
    memset(r, 0, sizeof(*r));
    r->t0_ms = t0_ms ? t0_ms : UL_LSDS_T0_MS_DEFAULT;
}

void ul_lsds_start(ul_lsds_t *r, uint32_t ssi, const uint8_t *info92,
                   uint8_t opt, uint32_t now_ms)
{
    r->active = 1;
    r->ssi = ssi & 0xFFFFFFu;
    r->opt = opt & 1;
    r->len = 0;
    for (int b = 0; b < 62; b++)            /* frag1 = info92[30..91] */
        r->body[r->len++] = info92[30 + b] & 1;
    r->t0_deadline_ms = now_ms + r->t0_ms;
}

int ul_lsds_frag(ul_lsds_t *r, const uint8_t *info268, int is_end, uint32_t now_ms,
                 uint8_t *out_body, int *out_len, uint32_t *out_ssi, uint8_t *out_opt)
{
    if (!r->active) return 0;               /* orphan fragment (keine Kette) */

    int start = is_end ? 10 : 4;            /* MAC-END info[10..267] / MAC-FRAG info[4..267] */
    for (int i = start; i < 268 && r->len < UL_LSDS_MAX_BITS; i++)
        r->body[r->len++] = info268[i] & 1;

    if (is_end) {
        if (out_body) memcpy(out_body, r->body, (size_t)r->len);
        if (out_len)  *out_len = r->len;
        if (out_ssi)  *out_ssi = r->ssi;
        if (out_opt)  *out_opt = r->opt;
        r->active = 0;
        r->reass_cnt++;
        return 1;
    }
    r->t0_deadline_ms = now_ms + r->t0_ms;  /* T0 pro Fragment neu (wie RTL) */
    return 0;
}

void ul_lsds_tick(ul_lsds_t *r, uint32_t now_ms)
{
    if (r->active && (int32_t)(now_ms - r->t0_deadline_ms) >= 0) {
        r->active = 0;
        r->drop_cnt++;
    }
}
