/*
 * tetra_grpack_body.c — Phase Y.2 SW-side D-ATTACH-DETACH-GRP-ID-ACK builder
 *
 * See tetra_grpack_body.h for the full bit-layout reference.
 *
 * The implementation packs bits MSB-first into the output byte buffer using
 * a small helper that tracks the current bit offset.  No malloc, no globals.
 *
 * License: GPL v2
 */

#include "tetra_grpack_body.h"

#include <string.h>

/* MSB-first bit-packer.  Writes the low `nbits` bits of `value` into `dst`
 * starting at bit offset `*pos` (bit 0 = MSB of byte 0).  Advances `*pos`. */
static void put_bits(uint8_t *dst, int *pos, uint32_t value, int nbits)
{
    int i;
    for (i = nbits - 1; i >= 0; i--) {
        unsigned bit = (unsigned)((value >> i) & 0x1u);
        unsigned p   = (unsigned)(*pos);
        unsigned byte_idx = p >> 3;
        unsigned bit_idx  = 7u - (p & 0x7u);
        if (bit) {
            dst[byte_idx] |= (uint8_t)(1u << bit_idx);
        } else {
            dst[byte_idx] &= (uint8_t)~(1u << bit_idx);
        }
        (*pos)++;
    }
}

int tetra_grpack_build(const grpack_meta_t *meta, uint8_t *out_bits)
{
    if (meta == NULL || out_bits == NULL) return 0;
    if (meta->num_records > TETRA_GRPACK_MAX_RECORDS) return 0;

    /* Zero the entire buffer first — trailing tail-bits stay at 0. */
    memset(out_bits, 0, TETRA_GRPACK_MAX_BYTES);

    int pos = 0;

    /* mm_pdu_type = 11 (4 bits, MSB-first = 0b1011). */
    put_bits(out_bits, &pos, 0xBu, 4);

    /* accept_reject (1 bit). */
    put_bits(out_bits, &pos, (meta->accept_reject & 0x1u), 1);

    /* reserved (1 bit) = 0. */
    put_bits(out_bits, &pos, 0u, 1);

    if (meta->num_records == 0u) {
        /* No IEs, no GID block: body ends with o-bit=0 + trailing m=0. */
        put_bits(out_bits, &pos, 0u, 1);   /* o-bit = 0 */
        put_bits(out_bits, &pos, 0u, 1);   /* trailing m */
        return pos;                         /* = 8 bits */
    }

    /* o-bit = 1 (IEs follow). */
    put_bits(out_bits, &pos, 1u, 1);

    /* m_Proprietary = 0 (not present). */
    put_bits(out_bits, &pos, 0u, 1);

    /* m_GroupIdentityDownlink = 1 (present). */
    put_bits(out_bits, &pos, 1u, 1);

    /* elem_id = 7 (4 bits, 0b0111). */
    put_bits(out_bits, &pos, 0x7u, 4);

    /* length-of-records-in-bits (11 bits) = num_elems(6) + 32*num_records.
     * Gold-Ref 1-record encodes length=38; 2-record=70; 3-record=102. */
    uint32_t length = 6u + 32u * (uint32_t)meta->num_records;
    put_bits(out_bits, &pos, length, 11);

    /* num_elems (6 bits). */
    put_bits(out_bits, &pos, (uint32_t)meta->num_records, 6);

    /* Records — 32 bits each, in declared order. */
    unsigned i;
    for (i = 0; i < meta->num_records; i++) {
        put_bits(out_bits, &pos,
                 (uint32_t)(meta->records[i].atd            & 0x1u),  1);
        put_bits(out_bits, &pos,
                 (uint32_t)(meta->records[i].lifetime       & 0x3u),  2);
        put_bits(out_bits, &pos,
                 (uint32_t)(meta->records[i].class_of_usage & 0x7u),  3);
        put_bits(out_bits, &pos,
                 (uint32_t)(meta->records[i].addr_type      & 0x3u),  2);
        put_bits(out_bits, &pos,
                 (uint32_t)(meta->records[i].gssi & 0x00FFFFFFu),    24);
    }

    /* m_GroupIdentitySecurityRelatedInformation = 0 (not present). */
    put_bits(out_bits, &pos, 0u, 1);

    /* trailing m-bit = 0. */
    put_bits(out_bits, &pos, 0u, 1);

    return pos;
}
