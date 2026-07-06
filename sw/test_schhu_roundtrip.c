#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_channel_codec.h"

static uint32_t rng=0xC0FFEEu;
static uint32_t xr(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}

/* SCH/HU-Encode nur aus exposed Primitiven (descramble == scramble, XOR-symmetrisch). */
static void schhu_encode(const uint8_t *info92,uint8_t cc,uint8_t slot,uint16_t mcc,uint16_t mnc,uint8_t *out168){
    uint8_t type2[108], type3[112], mother[448], type4[168], type4i[168];
    tetra_codec_crc16(info92,92,type2);
    memcpy(type3,type2,108); memset(type3+108,0,4);
    tetra_codec_conv_r14(type3,112,mother);
    tetra_codec_puncture_r23(mother,448,type4);
    tetra_codec_interleave_perm(type4,168,13,type4i);
    tetra_codec_descramble(type4i,168,cc,slot,mcc,mnc,out168); /* scramble via XOR-Symmetrie */
}

int main(void){
    const int T=500; uint8_t info[92], t5[168], out[92];
    const uint8_t cc=0x2A,slot=0; const uint16_t mcc=262,mnc=16383;
    int pass=0,ff=-1,frc=0;
    for(int t=0;t<T;t++){
        for(int i=0;i<92;i++) info[i]=xr()&1;
        schhu_encode(info,cc,slot,mcc,mnc,t5);
        int rc=tetra_codec_schhu_decode(t5,cc,slot,mcc,mnc,out);
        if(rc==0 && memcmp(info,out,92)==0) pass++;
        else if(ff<0){ff=t;frc=rc;}
    }
    printf("SCH/HU round-trip (clean, a=13/N=168): %d/%d PASS",pass,T);
    if(ff>=0) printf("  (Fail @%d rc=%d)",ff,frc);
    printf("\n");
    return pass==T?0:1;
}
