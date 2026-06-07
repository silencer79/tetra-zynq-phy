/* tetra_ul_long_sds.c — UL lange-SDS-Reassembly (Multi-Fragment, SCH/F).
 * Siehe Header. Kanaldecode via tetra_codec_schf_decode (verifiziert gegen
 * scripts/decode_ul.py, Ref-WAV 21:37, info_diff=0/268). */
#include "tetra_ul_long_sds.h"
#include "tetra_channel_codec.h"
#include <string.h>

#define LSDS_SCHF_INFO_BITS 268

static void append_bits(lsds_chain_t *c, const uint8_t *bits, int n)
{
    if (n <= 0) return;
    if (c->nbits + n > LSDS_MAX_TMSDU_BITS)
        n = LSDS_MAX_TMSDU_BITS - c->nbits;
    if (n <= 0) return;
    memcpy(c->tm + c->nbits, bits, (size_t)n);
    c->nbits += n;
}

void tetra_lsds_start(lsds_chain_t *c, uint32_t ssi,
                      const uint8_t *tm_start, int n)
{
    memset(c, 0, sizeof(*c));
    c->active = 1;
    c->ssi = ssi;
    append_bits(c, tm_start, n);
}

int tetra_lsds_feed_schf(lsds_chain_t *c, const uint8_t *type5_432,
                         uint8_t cc, uint8_t slot, uint16_t mcc, uint16_t mnc)
{
    uint8_t info[LSDS_SCHF_INFO_BITS];

    if (!c->active)
        return 0;
    if (tetra_codec_schf_decode(type5_432, cc, slot, mcc, mnc, info) != 0)
        return 0;                       /* CRC-Fail → kein gültiger SCH/F */

    /* MAC-FRAG-UL / MAC-END-UL: mac_pdu_type=01, pdu_subtype 0=FRAG / 1=END. */
    int pdu_type = (info[0] << 1) | info[1];
    if (pdu_type != 1)
        return 0;                       /* kein FRAG/END */
    int subtype = info[2];
    /* info[3] = fill_bits (hier ignoriert; Padding stört die SDS-TL nicht) */

    if (subtype == 0) {                 /* MAC-FRAG: 4-bit Header, Rest TM-SDU */
        append_bits(c, info + 4, LSDS_SCHF_INFO_BITS - 4);
        c->nfrag++;
        return 1;
    }
    /* MAC-END: 4-bit Header + 6-bit length_ind, Rest TM-SDU. */
    append_bits(c, info + 10, LSDS_SCHF_INFO_BITS - 10);
    c->nfrag++;
    c->active = 0;                      /* Kette komplett */
    return 2;
}
