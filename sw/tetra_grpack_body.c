/*
 * tetra_grpack_body.c — Phase Y.2 SW-side D-ATTACH-DETACH-GRP-ID-ACK builder
 *
 * Bit-Layout-Referenz: removed-doc,
 * Burst #4811 (info_hex 0x2081282ff440011b3704c09817a6b22000108...).
 *
 * Body (62 bits für 1-Record):
 * [pdu_type 4][accept_reject 1][reserved 1][o-bit 1]
 * [m=1][elem_id=7 4][length 11][num 6]
 * per record: [atd 1][lifetime 2][class 3][addr_type 2][gssi 24]
 * [trailing_m 0]
 *
 * Pro present-Element: 1 m-bit + 4-bit elem_id + content.
 * Absent Elements (Proprietary, GroupIdentitySecurityRelatedInformation):
 * KEIN m-bit, KEIN elem_id — schreibe NICHTS (Bluestation-Konvention =
 * WAV-Bytes verifiziert).
 *
 * 0 Records → o-bit=0 + trailing_m=0 → 8-bit-Body (kein Element).
 *
 * License: GPL v2
 */

#include "tetra_grpack_body.h"

#include <string.h>

/* MSB-first bit-packer. Writes the low `nbits` bits of `value` into `dst`
 * starting at bit offset `*pos` (bit 0 = MSB of byte 0). Advances `*pos`. */
static void put_bits(uint8_t *dst, int *pos, uint32_t value, int nbits)
{
 int i;
 for (i = nbits - 1; i >= 0; i--) {
 unsigned bit = (unsigned)((value >> i) & 0x1u);
 unsigned p = (unsigned)(*pos);
 unsigned byte_idx = p >> 3;
 unsigned bit_idx = 7u - (p & 0x7u);
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

 memset(out_bits, 0, TETRA_GRPACK_MAX_BYTES);

 int pos = 0;

 /* mm_pdu_type = 11 (4 bits, MSB-first = 0b1011). */
 put_bits(out_bits, &pos, 0xBu, 4);

 /* accept_reject (1 bit). */
 put_bits(out_bits, &pos, (meta->accept_reject & 0x1u), 1);

 /* reserved (1 bit) = 0. */
 put_bits(out_bits, &pos, 0u, 1);

 if (meta->num_records == 0u) {
 /* Kein IE: o-bit=0, trailing_m=0 → 8-bit-Body. */
 put_bits(out_bits, &pos, 0u, 1); /* o-bit = 0 */
 put_bits(out_bits, &pos, 0u, 1); /* trailing m = 0 */
 return pos; /* = 8 bits */
 }

 /* o-bit = 1 (mindestens 1 IE folgt). */
 put_bits(out_bits, &pos, 1u, 1);

 /* GroupIdentityDownlink-IE (Type-4): 1 m-bit + 4 elem_id + 11 length +
 * 6 num_elems + 32-bit-Records. Proprietary (vor GID) und
 * GroupIdentitySecurityRelatedInformation (nach GID) sind absent —
 * für absente Elements wird NICHTS geschrieben (kein m-bit, kein elem_id). */
 put_bits(out_bits, &pos, 1u, 1); /* m=1 */
 put_bits(out_bits, &pos, 0x7u, 4); /* elem_id=GID */

 /* length: 6 bit num_elems + 32 bit pro Record = 6 + 32*n. */
 uint32_t length = 6u + 32u * (uint32_t)meta->num_records;
 put_bits(out_bits, &pos, length, 11);

 /* num_elems (6 bit). */
 put_bits(out_bits, &pos, (uint32_t)meta->num_records, 6);

 /* Records (32 bit each): atd + lifetime + class + addr_type + gssi. */
 unsigned i;
 for (i = 0; i < meta->num_records; i++) {
 put_bits(out_bits, &pos, (uint32_t)(meta->records[i].atd & 0x1u), 1);
 put_bits(out_bits, &pos, (uint32_t)(meta->records[i].lifetime & 0x3u), 2);
 put_bits(out_bits, &pos, (uint32_t)(meta->records[i].class_of_usage & 0x7u), 3);
 put_bits(out_bits, &pos, (uint32_t)(meta->records[i].addr_type & 0x3u), 2);
 put_bits(out_bits, &pos, (uint32_t)(meta->records[i].gssi & 0x00FFFFFFu), 24);
 }

 /* trailing m-bit = 0 (close optional-IE chain). */
 put_bits(out_bits, &pos, 0u, 1);

 return pos; /* 1-Record = 62 bits, 2-Record = 94, 3-Record = 126 */
}
