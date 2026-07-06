/*
 * tetra_ul_rx_mailbox.c — Pack/Unpack für den UL-RX-Soft-Burst-Mailbox-Kontrakt.
 * Siehe tetra_ul_rx_mailbox.h.
 */
#include "tetra_ul_rx_mailbox.h"

static inline int sat4(int v)          /* saturiere auf signed 4-bit [-8,7] */
{
    if (v >  7) return  7;
    if (v < -8) return -8;
    return v;
}

int tetra_ul_rx_pack(uint8_t slot_tn, uint8_t burst_type,
                     const int *soft, int n_soft, uint32_t *words_out)
{
    if (n_soft < 0 || n_soft > UL_RX_MAX_SOFT) return -1;

    words_out[0] = ((uint32_t)(slot_tn & 0x3))
                 | ((uint32_t)(burst_type & 0x3) << 2)
                 | ((uint32_t)(n_soft & 0xFFF) << 4)
                 | (1u << 31);                       /* valid */

    int n_words = 1 + (n_soft + 7) / 8;
    for (int w = 1; w < n_words; w++) words_out[w] = 0;

    for (int i = 0; i < n_soft; i++) {
        uint32_t nib = (uint32_t)(sat4(soft[i]) & 0xF); /* 4-bit zweierkomplement */
        int word = 1 + (i >> 3);
        int shift = (i & 7) * 4;
        words_out[word] |= nib << shift;
    }
    return n_words;
}

int tetra_ul_rx_unpack(const uint32_t *words, ul_rx_burst_t *b)
{
    uint32_t hdr = words[0];
    if (!(hdr & (1u << 31))) return -1;              /* valid? */

    b->slot_tn    = (uint8_t)(hdr & 0x3);
    b->burst_type = (uint8_t)((hdr >> 2) & 0x3);
    b->n_soft     = (int)((hdr >> 4) & 0xFFF);
    if (b->n_soft > UL_RX_MAX_SOFT) return -1;

    for (int i = 0; i < b->n_soft; i++) {
        int word = 1 + (i >> 3);
        int shift = (i & 7) * 4;
        int nib = (int)((words[word] >> shift) & 0xF);
        if (nib & 0x8) nib -= 16;                    /* sign-extend 4-bit */
        b->soft[i] = nib;
    }
    return 0;
}
