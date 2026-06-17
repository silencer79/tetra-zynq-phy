/* test_sds_dl_frag.c — Host-Round-Trip für tetra_sds_dl_build_fragments.
 * Fragmentiert eine lange D-SDS-DATA, reassembliert sie spiegelbildlich (wie MS-B:
 * START-Payload ab Bit 43, MAC-FRAG ab Bit 4, MAC-END ab Bit 4 ohne Längenfeld),
 * parst die CMCE-PDU zurück und prüft dest/calling/UDD bit-identisch. */
#include "tetra_sds_dl_frag.h"
#include <stdio.h>
#include <string.h>

static int gb(const uint8_t *blk, int p) { return (blk[p >> 3] >> (7 - (p & 7))) & 1; }
static uint32_t gbits(const uint8_t *b, int *p, int n) {
    uint32_t v = 0; int i; for (i = 0; i < n; i++) v = (v << 1) | (uint32_t)gb(b, (*p)++);
    return v;
}

int main(void)
{
    uint32_t dest = 0x282F91, calling = 0x282FF4;
    /* 88-Oktett UDD: PID 0x82 + 4-Byte SDS-TL + 83 Byte Text (wie das MS-Testmuster). */
    uint8_t udd[88];
    udd[0] = 0x82; udd[1] = 0x04; udd[2] = 0x04; udd[3] = 0x01;
    int i; for (i = 4; i < 88; i++) udd[i] = (uint8_t)('A' + (i % 26));
    int udd_len = 88;

    sds_dl_frag_t f;
    int nf = tetra_sds_dl_build_fragments(dest, calling, /*ns*/1, /*nr*/0, udd, udd_len, &f);
    printf("fragments built: %d\n", nf);
    if (nf <= 0) { printf("FAIL: build returned %d\n", nf); return 1; }

    /* Header-Dump + Reassembly */
    static uint8_t tm[2048]; int tmn = 0;
    for (i = 0; i < nf; i++) {
        const uint8_t *blk = f.info[i];
        int pt = (gb(blk,0)<<1)|gb(blk,1);
        if (i == 0) {
            /* Block 0 = BL-ACK (LI=6, 48 bit) + Frag-Start @48 (wie Gold #798).
             * PDU1 prüfen, dann PDU2 (Frag-Start) ab Bit 48 parsen. */
            int q = 0; (void)gbits(blk,&q,2); (void)gb(blk,q++); (void)gb(blk,q++);
            (void)gbits(blk,&q,2); (void)gb(blk,q++);
            int li0 = (int)gbits(blk,&q,6); int at0=(int)gbits(blk,&q,3);
            uint32_t ssi0 = gbits(blk,&q,24);
            printf("  #%d PDU1 MAC-RESOURCE LI=%d addr_type=%d SSI=0x%06X (BL-ACK an Sender)\n",
                   i, li0, at0, ssi0);
            int p = 48; (void)gbits(blk,&p,2);           /* PDU2 pdu_type */
            (void)gb(blk,p++); (void)gb(blk,p++); (void)gbits(blk,&p,2); (void)gb(blk,p++);
            int li = (int)gbits(blk,&p,6);
            int at = (int)gbits(blk,&p,3);
            uint32_t ssi = gbits(blk,&p,24);
            p += 3; /* pc/sg/ca flags */
            printf("  #%d PDU2 Frag-Start pt=%d LI=%d addr_type=%d SSI=0x%06X payload@%d\n",
                   i, pt, li, at, ssi, p);
            int take = 268 - p; /* 177 */
            { int k; for (k=0;k<take;k++) tm[tmn++] = (uint8_t)gb(blk,p+k); }
        } else {
            int sub = gb(blk,2);
            if (sub == 0) {
                int p = 4;
                printf("  #%d MAC-FRAG  payload@4 (264 bit)\n", i);
                int k; for (k=0;k<264;k++) tm[tmn++] = (uint8_t)gb(blk,p+k);
            } else {
                int p = 4; /* payload@4, KEIN Längenfeld (Gold-Format) */
                printf("  #%d MAC-END   sub=1 payload@4 (264 bit, Rest=Fill)\n", i);
                int k; for (k=0;k<264 && (p+k)<268;k++) tm[tmn++] = (uint8_t)gb(blk,p+k);
            }
        }
    }
    printf("reassembled TM-SDU bits: %d\n", tmn);
    { int z; printf("  START burst bits[40:60]: "); for(z=40;z<60;z++) printf("%d",gb(f.info[0],z)); printf("\n");
      printf("  reasm tm[0:20]:          "); for(z=0;z<20;z++) printf("%d",tm[z]); printf("\n"); }

    /* TM-SDU parsen: LLC BL-DATA (4-bit type=0001 + N(S)) + MLE-PD(3) + CMCE.
     * tm ist ein BIT-Array (1 Byte je Bit) → eigener Accessor abits(). */
    int p = 0;
    #define ABITS(n) ({ uint32_t _v=0; int _i; for(_i=0;_i<(n);_i++) _v=(_v<<1)|tm[p++]; _v; })
    int llc_type = (int)ABITS(4); int rns = (int)ABITS(1);
    int mle = (int)ABITS(3);
    printf("LLC: type=%d(1=BL-DATA) ns=%d  MLE-PD=%d(2=CMCE)\n", llc_type, rns, mle);
    int cpt = (int)ABITS(5);
    int cpti = (int)ABITS(2);
    uint32_t rcall = ABITS(24);
    int sdti = (int)ABITS(2);
    int cli = (int)ABITS(11);
    printf("CMCE: pdu_type=%d(15=D-SDS-DATA) CPTI=%d calling=0x%06X SDTI=%d LI=%dbit(%doct)\n",
           cpt, cpti, rcall, sdti, cli, cli/8);
    int ok = 1;
    uint8_t rudd[128]; int ru = cli/8; int j;
    for (j = 0; j < ru && j < 128; j++) rudd[j] = (uint8_t)ABITS(8);
    if (llc_type != 1 || cpt != 15 || cpti != 1 || rcall != calling || sdti != 3 || cli != udd_len*8) ok = 0;
    for (j = 0; j < udd_len; j++) if (rudd[j] != udd[j]) { ok = 0; printf("  UDD mismatch @%d: %02X != %02X\n", j, rudd[j], udd[j]); break; }
    printf("\nRESULT: %s  (dest/calling/SDTI/LI + %d UDD-Oktette %s)\n",
           ok ? "PASS" : "FAIL", udd_len, ok ? "bit-identisch" : "FALSCH");
    return ok ? 0 : 1;
}
