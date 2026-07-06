/* test_ul_rtl_parity.c — SW-SCH/HU-Soft-Decode gegen dieselben Vektoren, die
 * die RTL-Testbench tb_ul_sch_hu_decoder.v dekodiert. Belegt SW==RTL (#5).
 * argv: <soft.hex> <exp.hex>. soft-Konvention der TB: bit0=+127/bit1=-127
 * (positiv=0) → fuer die SW (positiv=1) negiert. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_channel_codec.h"

int main(int argc, char **argv)
{
    const char *sp = argc>1?argv[1]:"sim_out/ul_sch_hu_soft.hex";
    const char *ep = argc>2?argv[2]:"sim_out/ul_sch_hu_exp.hex";
    FILE *fs=fopen(sp,"r"), *fe=fopen(ep,"r");
    if(!fs||!fe){ fprintf(stderr,"open fail\n"); return 2; }

    /* scramb_init 0xe1670ec7 = make_scramb_code(mcc=901,mnc=9998,cc=49). */
    const uint8_t cc=49, slot=0; const uint16_t mcc=901, mnc=9998;

    int soft[4*168];
    for(int i=0;i<4*168;i++){ unsigned v; if(fscanf(fs,"%x",&v)!=1){fprintf(stderr,"soft@%d\n",i);return 2;} soft[i]=(int8_t)v; }

    int pass=0;
    for(int b=0;b<4;b++){
        unsigned crc_exp; int eb[12];
        if(fscanf(fe,"%x",&crc_exp)!=1) return 2;
        for(int k=0;k<12;k++) if(fscanf(fe,"%x",&eb[k])!=1) return 2;

        int sw_soft[168];
        for(int i=0;i<168;i++) sw_soft[i] = -soft[b*168+i];   /* Konvention angleichen */

        uint8_t out[92];
        int rc = tetra_codec_schhu_decode_soft(sw_soft, cc, slot, mcc, mnc, out);

        int info_ok=1;
        for(int i=0;i<92;i++){ int want=(eb[i/8]>>(7-(i%8)))&1; if(out[i]!=want) info_ok=0; }
        int crc_ok = ((rc==0) == (crc_exp==1));
        int ok = info_ok && crc_ok && rc==0 && crc_exp==1;
        if(ok) pass++;
        printf("  burst #%d: SW rc=%d (exp crc=%u)  info==RTL-exp: %s\n",
               b, rc, crc_exp, info_ok?"JA":"NEIN");
    }
    printf("RTL-Paritaet SCH/HU: %d/4 Bursts (SW-Decode == RTL-TB-expected)\n", pass);
    return pass==4?0:1;
}
