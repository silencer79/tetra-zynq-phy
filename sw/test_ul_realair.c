/* test_ul_realair.c — SW-SCH/HU-Decode von ECHTEN UL-WAV-Bursts vs Referenz.
 * soft = RTL-emulierter Demod (positiv=0 → fuer SW negiert). */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_channel_codec.h"
int main(int argc,char**argv){
    const char*sp=argc>1?argv[1]:"sim_out/ul_wav_soft.hex";
    const char*ep=argc>2?argv[2]:"sim_out/ul_wav_exp.hex";
    FILE*fs=fopen(sp,"r"),*fe=fopen(ep,"r"); if(!fs||!fe){fprintf(stderr,"open fail\n");return 2;}
    static int soft[64*168]; int ns=0; unsigned v;
    while(ns<64*168 && fscanf(fs,"%x",&v)==1) soft[ns++]=(int8_t)v;
    int nb=ns/168;
    const uint8_t cc=49,slot=0; const uint16_t mcc=901,mnc=9998;
    int pass=0,total=0;
    for(int b=0;b<nb;b++){
        unsigned crc_exp; int eb[12];
        if(fscanf(fe,"%x",&crc_exp)!=1) break;
        for(int k=0;k<12;k++){ if(fscanf(fe,"%x",&eb[k])!=1){return 2;} }
        total++;
        int sw[168]; for(int i=0;i<168;i++) sw[i]=-soft[b*168+i];
        uint8_t out[92]; int rc=tetra_codec_schhu_decode_soft(sw,cc,slot,mcc,mnc,out);
        int io=1; for(int i=0;i<92;i++){int w=(eb[i/8]>>(7-(i%8)))&1; if(out[i]!=w) io=0;}
        int ok=(rc==0)&&(crc_exp==1)&&io;
        if(ok) pass++;
        printf("  Burst #%d: SW rc=%d (ref crc=%u)  info==Referenz: %s\n",b,rc,crc_exp,io?"JA":"NEIN");
    }
    printf("Phase-1 ECHT-LUFT: %d/%d Bursts (SW-Decode == Referenz auf realem UL-WAV)\n",pass,total);
    return pass==total?0:1;
}
