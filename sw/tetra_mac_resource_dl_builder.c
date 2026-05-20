/*
 * tetra_mac_resource_dl_builder.c — SW-Port von tetra_mac_resource_dl_builder.v
 *
 * Bit-identische Reproduktion des RTL-FSMs (8-FSM-States in RTL → linearer
 * C-Code hier, weil wir nicht clock-by-clock simulieren). Layout-Reference:
 * rtl/lmac/tetra_mac_resource_dl_builder.v Zeilen 664-741 (S_MAC_HEAD).
 *
 * Output-Convention: out_268[0] = erstes On-Air-Bit = RTL pdu_bits[267].
 * Eingangs-mm_bits[0] = erstes On-Air-Bit des MM-Body = RTL mm_pdu_bits[mm_len-1]
 * (MSB-first wie überall im Repo).
 *
 * License: GPL v2
 */
#include "tetra_mac_resource_dl_builder.h"
#include <string.h>

/* Write n bits of `val` MSB-first into bit-array out[] starting at position pos.
 * out[pos] = bit (n-1) of val, out[pos+1] = bit (n-2), ... */
static void wbits(uint8_t *out, int pos, uint32_t val, int n)
{
    for (int i = 0; i < n; i++) {
        out[pos + i] = (uint8_t)((val >> (n - 1 - i)) & 1u);
    }
}

/* Copy n bits from src[0..n-1] (each byte is 0/1) into out[pos..pos+n-1]. */
static void wbits_copy(uint8_t *out, int pos, const uint8_t *src, int n)
{
    for (int i = 0; i < n; i++)
        out[pos + i] = src[i] & 1u;
}

int tetra_build_mac_resource_pdu(const tetra_mac_res_meta_t *m,
                                  const uint8_t *mm_bits,
                                  int mm_len,
                                  uint8_t out_268[TETRA_MAC_RES_PDU_BITS])
{
    memset(out_268, 0, TETRA_MAC_RES_PDU_BITS);

    /* ---------- derived lengths ------------------------------------- */
    int llc_hdr_bits;
    int tl_sdu_len;     /* MLE-PD(3) + MM-len, oder L2SigPdu: nur MM-len, AL-SETUP: 0 */
    int mle_pd_bits = 3;

    switch (m->llc_pdu_type) {
    case MAC_LLC_L2SIG:
        llc_hdr_bits = 4;
        tl_sdu_len = mm_len;       /* L2SigPdu: kein MLE-PD */
        mle_pd_bits = 0;
        break;
    case MAC_LLC_AL_SETUP:
        llc_hdr_bits = 4;
        tl_sdu_len = 0;            /* AL-SETUP: kein TL-SDU */
        mle_pd_bits = 0;
        break;
    case MAC_LLC_BL_ADATA:
        llc_hdr_bits = 6;
        tl_sdu_len = mle_pd_bits + mm_len;
        break;
    case MAC_LLC_BL_UDATA:
        llc_hdr_bits = 4;
        tl_sdu_len = mle_pd_bits + mm_len;
        break;
    case MAC_LLC_BL_DATA:
    default:
        llc_hdr_bits = 5;
        tl_sdu_len = mle_pd_bits + mm_len;
        break;
    }

    int llc_cov_len = llc_hdr_bits + tl_sdu_len;

    /* MAC-RESOURCE Header:
     *   base = 40 (SSI) oder 46 (SSI+UsageMarker)
     *   + 3 (mandatory flags pc/sg/ca)
     *   + 4 wenn pc_flag
     *   + 8 wenn sg_flag
     *   + ca_element_len wenn ca_flag
     */
    int base_hdr = (m->addr_type == MAC_ADDR_TYPE_SSI_USAGE) ? 46 : 40;
    int mac_hdr_bits = base_hdr + 3
                     + (m->pc_flag ? 4 : 0)
                     + (m->sg_flag ? 8 : 0)
                     + (m->ca_flag ? m->ca_element_len : 0);

    int mac_total_bits = mac_hdr_bits + llc_cov_len;
    if (mac_total_bits > TETRA_MAC_RES_PDU_BITS) return -1;

    int mac_total_octets = (mac_total_bits + 7) / 8;
    int length_ind = mac_total_octets & 0x3F;   /* 6-bit */
    int fill_bit_ind = (mac_total_bits & 0x7) ? 1 : 0;

    /* ---------- BASE 40-bit MAC-RESOURCE Header (out_268[0..39]) --- */
    int p = 0;
    wbits(out_268, p, 0u, 2);                       p += 2;  /* PDUtype = 00 */
    wbits(out_268, p, (uint32_t)fill_bit_ind, 1);   p += 1;  /* FillBit */
    wbits(out_268, p, 0u, 1);                       p += 1;  /* PosOfGrant = 0 */
    wbits(out_268, p, 0u, 2);                       p += 2;  /* EncryptionMode = 00 */
    wbits(out_268, p, m->random_access_flag, 1);    p += 1;  /* RandAccFlag */
    wbits(out_268, p, (uint32_t)length_ind, 6);     p += 6;  /* LengthInd */
    wbits(out_268, p, m->addr_type & 0x7, 3);       p += 3;  /* AddrType */
    wbits(out_268, p, m->ssi & 0xFFFFFFu, 24);      p += 24; /* SSI */
    /* p = 40 */

    if (m->addr_type == MAC_ADDR_TYPE_SSI_USAGE) {
        wbits(out_268, p, m->usage_marker & 0x3Fu, 6); p += 6;
        /* p = 46 */
    }

    /* Mandatory presence flags + optional elements */
    wbits(out_268, p, m->pc_flag, 1); p += 1;
    if (m->pc_flag) {
        wbits(out_268, p, m->pc_element & 0xFu, 4); p += 4;
    }
    wbits(out_268, p, m->sg_flag, 1); p += 1;
    if (m->sg_flag) {
        wbits(out_268, p, m->sg_element, 8); p += 8;
    }
    wbits(out_268, p, m->ca_flag, 1); p += 1;
    if (m->ca_flag) {
        wbits(out_268, p, m->ca_element, m->ca_element_len); p += m->ca_element_len;
    }

    /* p should now equal mac_hdr_bits */

    /* ---------- LLC-Header + MLE-PD + MM-Body --------------------- */
    switch (m->llc_pdu_type) {
    case MAC_LLC_L2SIG:
        wbits(out_268, p, MAC_LLC_L2SIG, 4); p += 4;
        /* L2SigPdu: direkt MM (kein MLE-PD) */
        if (mm_len > 0) {
            wbits_copy(out_268, p, mm_bits, mm_len);
            p += mm_len;
        }
        break;
    case MAC_LLC_AL_SETUP:
        wbits(out_268, p, MAC_LLC_AL_SETUP, 4); p += 4;
        /* Kein TL-SDU */
        break;
    case MAC_LLC_BL_ADATA:
        /* {link=0, fcs=0, type=00, nr, ns} = 6 bit */
        wbits(out_268, p, 0u, 1); p += 1;          /* link */
        wbits(out_268, p, 0u, 1); p += 1;          /* fcs */
        wbits(out_268, p, 0u, 2); p += 2;          /* type=00 */
        wbits(out_268, p, m->nr, 1); p += 1;
        wbits(out_268, p, m->ns, 1); p += 1;
        wbits(out_268, p, m->mle_pd ? m->mle_pd : MAC_MLE_PD_MM, 3); p += 3;
        if (mm_len > 0) {
            wbits_copy(out_268, p, mm_bits, mm_len);
            p += mm_len;
        }
        break;
    case MAC_LLC_BL_UDATA:
        /* {link=0, fcs=0, type=10} = 4 bit, kein ns/nr */
        wbits(out_268, p, 0u, 1); p += 1;          /* link */
        wbits(out_268, p, 0u, 1); p += 1;          /* fcs */
        wbits(out_268, p, 0x2u, 2); p += 2;        /* type=10 */
        wbits(out_268, p, m->mle_pd ? m->mle_pd : MAC_MLE_PD_MM, 3); p += 3;
        if (mm_len > 0) {
            wbits_copy(out_268, p, mm_bits, mm_len);
            p += mm_len;
        }
        break;
    case MAC_LLC_BL_DATA:
    default:
        /* {link=0, fcs=0, type=01, ns} = 5 bit */
        wbits(out_268, p, 0u, 1); p += 1;
        wbits(out_268, p, 0u, 1); p += 1;
        wbits(out_268, p, 0x1u, 2); p += 2;
        wbits(out_268, p, m->ns, 1); p += 1;
        wbits(out_268, p, m->mle_pd ? m->mle_pd : MAC_MLE_PD_MM, 3); p += 3;
        if (mm_len > 0) {
            wbits_copy(out_268, p, mm_bits, mm_len);
            p += mm_len;
        }
        break;
    }

    /* p should now equal mac_total_bits */

    /* ---------- Fill-Bits ----------------------------------------- */
    /* RTL S_PAD:
     *   wenn fill_bit_ind (=1, mac_total_bits nicht byte-aligned):
     *      out[mac_total_bits] = 1  (= erstes fill bit ist 1)
     *   wenn !fill_bit_ind UND mac_total_bits < 268:
     *      out[mac_total_bits] = 1  (single-PDU first-unused marker)
     * In beiden Fällen wird das Bit an Position mac_total_bits auf 1 gesetzt;
     * der Rest bleibt 0 (memset oben). */
    if (mac_total_bits < TETRA_MAC_RES_PDU_BITS) {
        out_268[mac_total_bits] = 1;
    }

    return 0;
}
