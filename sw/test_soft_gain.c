#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "tetra_channel_codec.h"
static uint32_t rng=0xBEEF01u; static uint32_t xr(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static double urand(void){ return (xr()>>8)/16777216.0; }
static double nrand(void){ double u1=urand()+1e-9,u2=urand(); return sqrt(-2*log(u1))*cos(6.28318530718*u2); }
static void schhu_encode(const uint8_t*info92,uint8_t cc,uint8_t slot,uint16_t mcc,uint16_t mnc,uint8_t*out168){
    uint8_t t2[108],t3[112],mo[448],t4[168],t4i[168];
    tetra_codec_crc16(info92,92,t2); memcpy(t3,t2,108); memset(t3+108,0,4);
    tetra_codec_conv_r14(t3,112,mo); tetra_codec_puncture_r23(mo,448,t4);
    tetra_codec_interleave_perm(t4,168,13,t4i);
    tetra_codec_descramble(t4i,168,cc,slot,mcc,mnc,out168);
}
int main(void){
    const int T=4000; const double AMP=8.0; const double SIGMA=6.0; /* moderat verrauscht */
    const uint8_t cc=0x2A,slot=0; const uint16_t mcc=262,mnc=16383;
    uint8_t info[92],t5[168],outh[92],outs[92]; int softbuf[168]; uint8_t hardbuf[168];
    int hard_ok=0, soft_ok=0;
    for(int t=0;t<T;t++){
        for(int i=0;i<92;i++) info[i]=xr()&1;
        schhu_encode(info,cc,slot,mcc,mnc,t5);
        for(int i=0;i<168;i++){ double s=(t5[i]?AMP:-AMP)+SIGMA*nrand();
            softbuf[i]=(int)lround(s); hardbuf[i]=(s>0)?1:0; }
        if(tetra_codec_schhu_decode(hardbuf,cc,slot,mcc,mnc,outh)==0 && memcmp(info,outh,92)==0) hard_ok++;
        if(tetra_codec_schhu_decode_soft(softbuf,cc,slot,mcc,mnc,outs)==0 && memcmp(info,outs,92)==0) soft_ok++;
    }
    printf("Rausch-Test (AMP=%.0f SIGMA=%.0f, %d Bursts):\n",AMP,SIGMA,T);
    printf("  HARD-Decode CRC+korrekt: %d/%d (%.1f%%)\n",hard_ok,T,100.0*hard_ok/T);
    printf("  SOFT-Decode CRC+korrekt: %d/%d (%.1f%%)\n",soft_ok,T,100.0*soft_ok/T);
    printf("  Soft-Gewinn: +%.1f pp\n",100.0*(soft_ok-hard_ok)/T);
    return (soft_ok>=hard_ok)?0:1;
}
