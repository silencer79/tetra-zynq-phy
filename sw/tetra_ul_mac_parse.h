/*
 * tetra_ul_mac_parse.h — SW MAC-ACCESS-Header-Parser (Option B)
 *
 * Bit-genaue Spiegelung der Feld-Extraktion aus rtl/lmac/tetra_ul_mac_access_
 * parser.v (ETSI §21.4.3.3, Autorität bluestation mac_access.rs::from_bitbuf).
 * Klassifiziert einen dekodierten SCH/HU-Burst und liefert die Felder, die das
 * Reassembly-Routing + der Demand-Walker brauchen — inkl. des 13-bit-Meta-
 * Bündels im Format der Demand-Body-Mailbox.
 *
 * License: GPL v2
 */
#ifndef TETRA_UL_MAC_PARSE_H
#define TETRA_UL_MAC_PARSE_H

#include <stdint.h>

typedef struct {
    uint8_t  mac_pdu_type;    /* info[0]: 0=MAC-ACCESS, 1=MAC-END-HU */
    uint8_t  addr_type;       /* info[3..4] */
    uint32_t issi;            /* info[5..28] (24 bit) */
    uint8_t  opt_flag;        /* info[29] */
    uint8_t  length_or_cap;   /* info[30] (valid iff opt) */
    uint8_t  frag_flag;       /* info[31] (valid iff opt & length_or_cap) */
    uint8_t  reservation_req; /* info[32..35] (valid iff opt & length_or_cap) */
    uint8_t  length_ind;      /* info[31..35] (valid iff opt & ~length_or_cap) */
    int      tl_sdu_start;    /* 30 (opt=0) oder 36 (opt=1) */
    /* LLC/MLE/MM (aus TL-SDU) */
    uint8_t  llc_link_type;
    uint8_t  llc_has_fcs;
    uint8_t  llc_bl_pdu_type; /* 2 bit */
    uint8_t  ns_bit;
    uint8_t  mle_pd;          /* 3 bit MLE-Diskriminator (001 = MM) */
    uint8_t  mm_pdu_type;     /* 4 bit */
    uint8_t  loc_upd_type;    /* 3 bit */
    uint16_t meta13;          /* [12:9]mm [8:6]mle [5:2]llc4 [1]ns [0]opt (Demand-Mailbox-Format) */
} ul_mac_access_t;

/* Parst die 92 dekodierten Info-Bits eines MAC-ACCESS-Bursts (info[0]==0). */
void tetra_ul_mac_access_parse(const uint8_t *info92, ul_mac_access_t *o);

/* SCH/HU-Klassifikation: mac_pdu_type = info[0] (0=MAC-ACCESS,1=MAC-END-HU). */
static inline int tetra_ul_is_mac_end_hu(const uint8_t *info92) { return (info92[0] & 1) == 1; }

/* SCH/F-Klassifikation: mac_pdu_type = {info[0],info[1]}. 01 → MAC-FRAG/END,
 * sub = info[2] (0=FRAG, 1=END). Rückgabe 1 wenn MAC-FRAG/END. */
static inline int tetra_ul_schf_is_frag(const uint8_t *info268, int *is_end)
{
    int is01 = ((info268[0] & 1) == 0) && ((info268[1] & 1) == 1);
    if (is_end) *is_end = info268[2] & 1;
    return is01;
}

#endif /* TETRA_UL_MAC_PARSE_H */
