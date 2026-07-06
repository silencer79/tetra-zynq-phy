/*
 * tetra_ul_mac_parse.c — siehe tetra_ul_mac_parse.h.
 * Bit-genaue Spiegelung von rtl/lmac/tetra_ul_mac_access_parser.v.
 */
#include "tetra_ul_mac_parse.h"
#include <string.h>

/* MSB-first: info[start] = MSB des n-Bit-Feldes. */
static uint32_t getbits(const uint8_t *b, int start, int n)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++)
        v = (v << 1) | (b[start + i] & 1u);
    return v;
}

void tetra_ul_mac_access_parse(const uint8_t *info92, ul_mac_access_t *o)
{
    memset(o, 0, sizeof(*o));

    o->mac_pdu_type = info92[0] & 1;
    o->addr_type    = (uint8_t)getbits(info92, 3, 2);
    o->issi         = getbits(info92, 5, 24);
    o->opt_flag     = info92[29] & 1;

    if (o->opt_flag) {
        o->length_or_cap = info92[30] & 1;
        if (o->length_or_cap) {
            o->frag_flag       = info92[31] & 1;
            o->reservation_req = (uint8_t)getbits(info92, 32, 4);
        } else {
            o->length_ind      = (uint8_t)getbits(info92, 31, 5);
        }
    }

    o->tl_sdu_start = o->opt_flag ? 36 : 30;
    int t = o->tl_sdu_start;

    o->llc_link_type  = info92[t + 0] & 1;
    o->llc_has_fcs    = info92[t + 1] & 1;
    o->llc_bl_pdu_type = (uint8_t)getbits(info92, t + 2, 2);

    int is_adata = (o->llc_link_type == 0) && (o->llc_bl_pdu_type == 0);
    int is_data  = (o->llc_link_type == 0) && (o->llc_bl_pdu_type == 1);

    o->ns_bit = info92[t + 4] & 1;

    int lps = t + (is_adata ? 6 : (is_data ? 5 : 4));  /* llc_payload_start */
    o->mle_pd       = (uint8_t)getbits(info92, lps + 0, 3);
    o->mm_pdu_type  = (uint8_t)getbits(info92, lps + 3, 4);
    o->loc_upd_type = (uint8_t)getbits(info92, lps + 7, 3);

    uint8_t llc4 = (uint8_t)((o->llc_link_type << 3) | (o->llc_has_fcs << 2) | o->llc_bl_pdu_type);
    o->meta13 = (uint16_t)(((o->mm_pdu_type & 0xF) << 9) |
                           ((o->mle_pd & 0x7) << 6) |
                           ((llc4 & 0xF) << 2) |
                           ((o->ns_bit & 1) << 1) |
                           (o->opt_flag & 1));
}
