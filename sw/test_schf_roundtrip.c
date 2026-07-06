/* Round-Trip-Validierung der SW-SCH/F-Kette (encode<->decode) — die
 * wiederverwendbare Basis fuer den UL-Soft-Decode (Option B). Host-gcc, kein Board. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_channel_codec.h"

#define INFO 268
#define CODED 432
static uint32_t rng = 0x12345678u;
static uint32_t xr(void){ rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }

int main(void){
    const int T = 500;
    uint8_t info[INFO], type5[CODED], out[INFO];
    const uint8_t cc=0x2A, slot=1; const uint16_t mcc=262, mnc=16383;
    int pass=0, first_fail=-1, fail_rc=0;
    for(int t=0;t<T;t++){
        for(int i=0;i<INFO;i++) info[i]=xr()&1;
        if(tetra_codec_schf_encode(info,cc,slot,mcc,mnc,type5)!=0){printf("encode FAIL @%d\n",t);return 2;}
        int rc=tetra_codec_schf_decode(type5,cc,slot,mcc,mnc,out);
        if(rc==0 && memcmp(info,out,INFO)==0) pass++;
        else if(first_fail<0){first_fail=t; fail_rc=rc;}
    }
    printf("SCH/F round-trip (clean input): %d/%d PASS", pass, T);
    if(first_fail>=0) printf("  (erster Fail @%d rc=%d)", first_fail, fail_rc);
    printf("\n");
    return pass==T?0:1;
}
