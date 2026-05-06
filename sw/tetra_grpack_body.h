/*
 * tetra_grpack_body.h — Phase Y.2 SW-side D-ATTACH-DETACH-GRP-ID-ACK builder
 *
 * Builds the MM body of a D-ATTACH-DETACH-GROUP-IDENTITY-ACKNOWLEDGEMENT
 * (mm_pdu_type=11) bit-for-bit per ETSI EN 300 392-2 §16.10.31 + the
 * gold-reference layout captured in
 * `memory/reference_gold_group_switch_burst_timeline.md` (1-record case
 * verified bit-genau against Gold-Capture cycle GS#1).
 *
 * Bit layout (MSB-first, packed as byte stream):
 *
 *   [0..3]    mm_pdu_type   = 11 = 0b1011
 *   [4]       accept_reject (0=accept, 1=reject)
 *   [5]       reserved      = 0
 *   [6]       o-bit         (1 if any IE follows; 0 = body ends here)
 *   if o-bit == 1:
 *     [7]     m_Proprietary (Type-3 elem_id=15) — fixed 0 here
 *     [8]     m_GroupIdentityDownlink (1 = GID block follows)
 *     if m_GroupIdentityDownlink == 1:
 *       [9..12]   elem_id   = 0b0111 = 7
 *       [13..23]  length    11-bit length-of-records-in-bits
 *                            = 6 (num_elems) + 32*num_records
 *       [24..29]  num_elems 6-bit (=num_records)
 *       per record (32 bits each):
 *         atd       (1)   0=attach, 1=detach
 *         lifetime  (2)
 *         class     (3)   class_of_usage
 *         addr_type (2)   0=SSI/GSSI (only addr_type=0 used in gold)
 *         GSSI      (24)  MSB-first
 *     [.]     m_GroupIdentitySecurityRelatedInformation (Type-4 elem_id=12)
 *             — fixed 0 here (not present)
 *   trailing m-bit = 0
 *
 * Total length:
 *   1 record: 4+1+1+1+1+1+4+11+6+32+1+1            = 64 bits
 *   2 records: 64 + 32                              = 96 bits
 *   3 records: 64 + 64                              = 128 bits
 *
 * Gold-Ref 1-record case (GS#1, GSSI=0x2F4D64, class=4, lifetime=1, atd=0):
 *   First 5 bytes = 0xB2 0xB8 0x26 0x04 0xC0  (verified bit-exact)
 *
 * The build function returns the total number of bits written.  Output
 * buffer must be at least 16 bytes (128 bits) — unused trailing bits are
 * left at zero (caller may pad/byte-align as needed).
 */

#ifndef TETRA_GRPACK_BODY_H
#define TETRA_GRPACK_BODY_H

#include <stdint.h>

#define TETRA_GRPACK_MAX_RECORDS  3
#define TETRA_GRPACK_MAX_BYTES    16

typedef struct {
    uint8_t  accept_reject;       /* 0=accept, 1=reject                     */
    uint8_t  num_records;         /* 0..3 (0 ⇒ no GID IE, body 8 bits)      */
    struct {
        uint8_t  atd;             /* 0=attach, 1=detach                     */
        uint8_t  lifetime;        /* 2-bit                                  */
        uint8_t  class_of_usage;  /* 3-bit                                  */
        uint8_t  addr_type;       /* 2-bit, 0=SSI/GSSI                      */
        uint32_t gssi;            /* 24-bit                                 */
    } records[TETRA_GRPACK_MAX_RECORDS];
} grpack_meta_t;

/* Build the MM body into `out_bits` (byte buffer, MSB-first).
 * Returns the total bit length written, or 0 on parameter error.
 *
 * Buffer requirement: out_bits must point to >= TETRA_GRPACK_MAX_BYTES
 * bytes; unused tail bytes are zeroed. */
int tetra_grpack_build(const grpack_meta_t *meta, uint8_t *out_bits);

#endif /* TETRA_GRPACK_BODY_H */
