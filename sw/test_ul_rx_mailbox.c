/* test_ul_rx_mailbox.c — Mailbox-Kontrakt: Format-Round-Trip + Verbraucher-
 * Kette (pack -> unpack -> schhu_decode_soft). Host-gcc, board-frei. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_ul_rx_mailbox.h"
#include "tetra_channel_codec.h"

static uint32_t rng=0x9A17u; static uint32_t xr(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static int checks=0,fails=0;
#define CK(c,m) do{checks++; if(!(c)){fails++; printf("  FAIL: %s\n",m);} }while(0)
static int sat4(int v){ return v>7?7:(v<-8?-8:v); }

/* SCH/HU-Encode aus exposed Primitiven (descramble==scramble via XOR). */
static void schhu_encode(const uint8_t*i92,uint8_t cc,uint8_t sl,uint16_t mcc,uint16_t mnc,uint8_t*o168){
    uint8_t t2[108],t3[112],mo[448],t4[168],t4i[168];
    tetra_codec_crc16(i92,92,t2); memcpy(t3,t2,108); memset(t3+108,0,4);
    tetra_codec_conv_r14(t3,112,mo); tetra_codec_puncture_r23(mo,448,t4);
    tetra_codec_interleave_perm(t4,168,13,t4i);
    tetra_codec_descramble(t4i,168,cc,sl,mcc,mnc,o168);
}

int main(void){
    uint32_t words[UL_RX_MAX_WORDS]; ul_rx_burst_t b;

    /* 1) Format-Round-Trip mit Slot-Kennung + burst_type + soft. */
    int soft168[168]; for(int i=0;i<168;i++) soft168[i]=(int)(xr()%17)-8; /* [-8,8) */
    int nw = tetra_ul_rx_pack(2 /*slot*/, UL_RX_BT_SCHHU, soft168, 168, words);
    CK(nw == 1 + (168+7)/8, "n_words = 1+ceil(168/8)=22");
    CK(tetra_ul_rx_unpack(words,&b)==0, "unpack ok");
    CK(b.slot_tn==2, "slot_tn round-trip (SLOT-KENNUNG)");
    CK(b.burst_type==UL_RX_BT_SCHHU, "burst_type round-trip");
    CK(b.n_soft==168, "n_soft round-trip");
    int soft_ok=1; for(int i=0;i<168;i++) if(b.soft[i]!=sat4(soft168[i])) soft_ok=0;
    CK(soft_ok, "soft-Werte (4-bit sat) round-trip");

    /* 2) SCH/F-Länge 432 auch tragbar. */
    int soft432[432]; for(int i=0;i<432;i++) soft432[i]=(xr()&1)?5:-5;
    int nw2 = tetra_ul_rx_pack(1, UL_RX_BT_SCHF, soft432, 432, words);
    CK(nw2==1+(432+7)/8, "SCH/F n_words=55");
    CK(tetra_ul_rx_unpack(words,&b)==0 && b.n_soft==432 && b.burst_type==UL_RX_BT_SCHF, "SCH/F unpack");

    /* 3) Verbraucher-Kette: echter SCH/HU-Burst -> Mailbox -> unpack -> soft-decode. */
    const uint8_t cc=0x2A,slot_scr=0; const uint16_t mcc=262,mnc=16383;
    uint8_t info[92],t5[168],out[92];
    for(int i=0;i<92;i++) info[i]=xr()&1;
    schhu_encode(info,cc,slot_scr,mcc,mnc,t5);
    int soft[168]; for(int i=0;i<168;i++) soft[i]=t5[i]?6:-6;   /* clean soft */
    tetra_ul_rx_pack(3 /*on-air TS4*/, UL_RX_BT_SCHHU, soft, 168, words);
    CK(tetra_ul_rx_unpack(words,&b)==0, "chain: unpack");
    CK(b.slot_tn==3 && b.burst_type==UL_RX_BT_SCHHU, "chain: slot+type");
    int rc = tetra_codec_schhu_decode_soft(b.soft, cc, slot_scr, mcc, mnc, out);
    CK(rc==0 && memcmp(info,out,92)==0, "chain: Mailbox-soft -> decode -> info OK");

    printf("UL-RX-Mailbox: %d/%d checks PASS\n", checks-fails, checks);
    return fails?1:0;
}
