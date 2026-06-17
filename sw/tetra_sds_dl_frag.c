/* tetra_sds_dl_frag.c — siehe Header. DL-MAC-Fragmentierung einer langen D-SDS-DATA. */
#include "tetra_sds_dl_frag.h"
#include <string.h>

/* ---- Bit-Helfer: MSB-first in einen Byte-Puffer ---- */
static void pb(uint8_t *dst, int *pos, uint32_t val, int nbits)
{
    int i;
    for (i = nbits - 1; i >= 0; i--) {
        int bit = (int)((val >> i) & 1u);
        int p = (*pos)++;
        if (bit) dst[p >> 3] |= (uint8_t)(0x80u >> (p & 7));
    }
}

/* Kopiert nbits aus src (Bit-Array, 1 Byte je Bit) MSB-first in dst ab *pos. */
static void pb_bits(uint8_t *dst, int *pos, const uint8_t *srcbits, int from, int nbits)
{
    int i;
    for (i = 0; i < nbits; i++) {
        int p = (*pos)++;
        if (srcbits[from + i]) dst[p >> 3] |= (uint8_t)(0x80u >> (p & 7));
    }
}

/* CMCE D-SDS-DATA (ETSI §14.7.1.10) als Bit-Array (1 Byte je Bit). Rückgabe: Bitlänge. */
static int build_cmce_d_sds_data(uint8_t *bits, uint32_t calling_ssi,
                                 const uint8_t *udd, int udd_len)
{
    /* temporär in Byte-Puffer bauen, dann zu Bit-Array entpacken */
    uint8_t tmp[160]; int p = 0; int i;
    memset(tmp, 0, sizeof(tmp));
    pb(tmp, &p, 15u, 5);                       /* pdu_type = D-SDS-DATA */
    pb(tmp, &p, 1u, 2);                        /* CPTI = 1 (SSI) */
    pb(tmp, &p, calling_ssi & 0x00FFFFFFu, 24);/* calling_party_ssi (Absender) */
    pb(tmp, &p, 3u, 2);                        /* SDTI = 3 (UDD-4) */
    pb(tmp, &p, (uint32_t)(udd_len * 8) & 0x7FFu, 11); /* LI in Bit */
    for (i = 0; i < udd_len; i++) pb(tmp, &p, udd[i], 8);
    pb(tmp, &p, 0u, 1);                        /* o-bit = 0 */
    for (i = 0; i < p; i++) bits[i] = (uint8_t)((tmp[i >> 3] >> (7 - (i & 7))) & 1u);
    return p;
}

int tetra_sds_dl_build_fragments(uint32_t dest_ssi, uint32_t calling_ssi,
                                 uint8_t ns, uint8_t nr,
                                 const uint8_t *udd, int udd_len,
                                 sds_dl_frag_t *out)
{
    if (out == NULL || udd == NULL || udd_len <= 0 || udd_len > 120) return 0;
    memset(out, 0, sizeof(*out));

    /* ---- 1) TM-SDU = LLC BL-ADATA(6) + MLE-PD(3=CMCE) + CMCE D-SDS-DATA ---- */
    static uint8_t tm[2048];          /* Bit-Array */
    memset(tm, 0, sizeof(tm));
    uint8_t hdr[8]; int hp = 0; memset(hdr, 0, sizeof(hdr));
    /* LLC BL-DATA (Gold-Referenz dl_ref.log #798 Frag-Start an 2633617):
     * 4-bit pdu_type=0001 = BL-DATA, danach N(S)(1). KEIN N(R) — BL-DATA ist
     * sequenziert aber nicht quittiert. (Vorher BL-ADATA(0) → 1-bit-Versatz, MS-B parst Müll.) */
    pb(hdr, &hp, 1u, 4);             /* LLC PDU type = 0001 = BL-DATA */
    pb(hdr, &hp, ns & 1u, 1);        /* N(S) */
    pb(hdr, &hp, 2u, 3);             /* MLE-PD = 010 (CMCE) */
    (void)nr;                        /* BL-DATA hat kein N(R) */
    int tmn = 0; int k;
    for (k = 0; k < hp; k++) tm[tmn++] = (uint8_t)((hdr[k >> 3] >> (7 - (k & 7))) & 1u);
    int cmce_bits = build_cmce_d_sds_data(tm + tmn, calling_ssi, udd, udd_len);
    tmn += cmce_bits;                 /* tmn = gesamte TM-SDU-Bitlänge */

    /* ---- 2) MAC-Fragmentierung ----
     * Burst 0: MAC-RESOURCE-Header (43 bit) + TM-SDU[0 : 225]
     * FRAG  : 4-bit Header (type2+sub1+fill1) + 264 bit TM-SDU
     * END   : 4-bit Header (type2+sub1+fill1) + Rest  (KEIN Längenfeld — Gold #810)
     */
    const int FRAG_HDR    = 4;
    const int END_HDR     = 4;                  /* type(2)+sub(1)+fill(1), kein Längenfeld */
    const int BURST       = SCHF_INFO_BITS;     /* 268 */
    const int FRAG_CAP = BURST - FRAG_HDR;      /* 264 */
    const int END_CAP  = BURST - END_HDR;       /* 264 */

    int consumed = 0; int nf = 0;
    while (consumed < tmn) {
        if (nf >= SDS_DL_FRAG_MAX) return 0;    /* zu lang */
        uint8_t *blk = out->info[nf];
        int pos = 0;
        int remaining = tmn - consumed;

        if (nf == 0) {
            /* Block 0 EXAKT wie Gold dl_ref.log #798: erst eine vollständige BL-ACK
             * an den SENDER (LI=6), DANN der Frag-Start an den Empfänger als ZWEITES
             * MAC-PDU. Der Empfänger überspringt die BL-ACK (fremde Adresse) und
             * startet die Reassembly am Frag-Start. */
            /* --- PDU 1: MAC-RESOURCE BL-ACK an calling_ssi (Sender), LI=6 --- */
            pb(blk, &pos, 0u, 2);               /* MAC pdu_type = 00 (MAC-RESOURCE) */
            pb(blk, &pos, 0u, 1);               /* fill_bit_indication = 0 */
            pb(blk, &pos, 0u, 1);               /* position_of_grant = 0 */
            pb(blk, &pos, 0u, 2);               /* encryption_mode = 0 */
            pb(blk, &pos, 0u, 1);               /* random_access_flag = 0 */
            pb(blk, &pos, 6u, 6);               /* length_indication = 6 (6 Oktett = komplette PDU) */
            pb(blk, &pos, 1u, 3);               /* address_type = 001 (SSI) */
            pb(blk, &pos, calling_ssi & 0x00FFFFFFu, 24);
            pb(blk, &pos, 0u, 1); pb(blk, &pos, 0u, 1); pb(blk, &pos, 0u, 1); /* pc/sg/ca */
            pb(blk, &pos, 3u, 4);               /* LLC BL-ACK (pdu_type=0011) */
            pb(blk, &pos, nr & 1u, 1);          /* N(R) */
            /* pos == 48 (= 6 Oktett) */
            /* --- PDU 2: MAC-RESOURCE Frag-Start an dest_ssi (Empfänger), LI=63 --- */
            pb(blk, &pos, 0u, 2);               /* MAC pdu_type = 00 (MAC-RESOURCE) */
            pb(blk, &pos, 0u, 1);               /* fill_bit_indication = 0 */
            pb(blk, &pos, 0u, 1);               /* position_of_grant = 0 */
            pb(blk, &pos, 0u, 2);               /* encryption_mode = 0 */
            pb(blk, &pos, 0u, 1);               /* random_access_flag = 0 */
            pb(blk, &pos, 63u, 6);              /* length_indication = 63 = FRAG START (Gold #798) */
            pb(blk, &pos, 1u, 3);               /* address_type = 001 (SSI) */
            pb(blk, &pos, dest_ssi & 0x00FFFFFFu, 24);
            pb(blk, &pos, 0u, 1); pb(blk, &pos, 0u, 1); pb(blk, &pos, 0u, 1); /* pc/sg/ca */
            /* pos == 91 → Frag-Start-Payload füllt den Rest des Blocks (177 bit) */
            int cap0 = BURST - pos;             /* 268 - 91 = 177 */
            int take = remaining < cap0 ? remaining : cap0;
            pb_bits(blk, &pos, tm, consumed, take);
            consumed += take;
        } else if (remaining > END_CAP) {
            /* MAC-FRAG (mac_pdu_type=01, sub=0) */
            pb(blk, &pos, 1u, 2);               /* MAC pdu_type = 01 (MAC-FRAG/END) */
            pb(blk, &pos, 0u, 1);               /* sub = 0 (FRAG) */
            pb(blk, &pos, 0u, 1);               /* fill_bit_indication = 0 */
            pb_bits(blk, &pos, tm, consumed, FRAG_CAP);
            consumed += FRAG_CAP;
        } else {
            /* MAC-END (mac_pdu_type=01, sub=1): 4-bit Header, KEIN Längenfeld.
             * Gold dl_ref.log #810: payload@4, fill_bit=1; Gesamtlänge steht in CMCE-LI.
             * (Vorher 6-bit Längenfeld → 6-bit-Versatz im letzten Fragment.) */
            pb(blk, &pos, 1u, 2);               /* MAC pdu_type = 01 */
            pb(blk, &pos, 1u, 1);               /* sub = 1 (END) */
            pb(blk, &pos, 1u, 1);               /* fill_bit_indication = 1 (Rest = Fill) */
            pb_bits(blk, &pos, tm, consumed, remaining);
            consumed += remaining;
            /* FILL-MARKER (ETSI §23.4.3): erstes Fill-Bit = '1', Rest '0'. Ohne dieses
             * '1' nimmt der MS-Empfänger das letzte CONTENT-'1' als Fill-Marker und
             * trunkiert die reassemblierte TM-SDU → UDD unvollständig → SDS verworfen.
             * (Gold dl_ref.log #810: Fill-Marker direkt nach der TM-SDU; danach Nullen.) */
            if (pos < BURST)
                pb(blk, &pos, 1u, 1);
        }
        nf++;
    }
    out->n = nf;
    return nf;
}

void tetra_sds_dl_build_slotgrant(uint32_t dest_ssi, uint8_t *blk)
{
    int pos = 0;
    memset(blk, 0, SCHF_INFO_BYTES);
    /* AL-SETUP + Slot-Grant MAC-RESOURCE, bit-exakt wie Gold dl_ref.log #822:
     * weist dem Empfänger einen UL-Subslot zu (für den Delivery-Report). */
    pb(blk, &pos, 0u, 2);               /* MAC pdu_type = 00 (MAC-RESOURCE) */
    pb(blk, &pos, 1u, 1);               /* fill_bit_indication = 1 */
    pb(blk, &pos, 0u, 1);               /* position_of_grant = 0 */
    pb(blk, &pos, 0u, 2);               /* encryption_mode = 0 */
    pb(blk, &pos, 1u, 1);               /* random_access_flag = 1 (Gold #822) */
    pb(blk, &pos, 7u, 6);               /* length_indication = 7 (7 Oktett) */
    pb(blk, &pos, 1u, 3);               /* address_type = 001 (SSI) */
    pb(blk, &pos, dest_ssi & 0x00FFFFFFu, 24);
    pb(blk, &pos, 0u, 1);               /* power_control_flag = 0 */
    pb(blk, &pos, 1u, 1);               /* slot_granting_flag = 1 */
    pb(blk, &pos, 0u, 8);               /* slot_granting_element = 0x00 (FirstSubslotGranted) */
    pb(blk, &pos, 0u, 1);               /* chan_alloc_flag = 0 */
    pb(blk, &pos, 8u, 4);               /* LLC AL-SETUP (pdu_type = 1000) */
    /* Rest des 268-bit-Blocks bleibt 0 (Fill). */
}
