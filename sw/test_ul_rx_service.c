/* test_ul_rx_service.c — End-to-End der SW-UL-RX-Kette (Option B, Capstone).
 * 3 Szenarien: Einzelburst / Demand-2-Burst / Long-SDS. Host-gcc, board-frei. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_ul_rx_service.h"
#include "tetra_ul_rx_mailbox.h"
#include "tetra_channel_codec.h"

static uint32_t rng=0xF00Du; static uint32_t xr(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static int checks=0,fails=0;
#define CK(c,m) do{checks++; if(!(c)){fails++; printf("  FAIL: %s\n",m);} }while(0)
static void pb(uint8_t *b,int *pos,uint32_t v,int n){ for(int i=n-1;i>=0;i--) b[(*pos)++]=(v>>i)&1; }

static const uint8_t CC=0x2A, SCR=0; static const uint16_t MCC=262, MNC=100;

/* SCH/HU-Encode + Soft-Pack in Mailbox-Wire-Format (slot, BT_SCHHU). */
static void mk_schhu(const uint8_t *info92, uint8_t slot, uint32_t *words){
    uint8_t t2[108],t3[112],mo[448],t4[168],t4i[168],t5[168]; int soft[168];
    tetra_codec_crc16(info92,92,t2); memcpy(t3,t2,108); memset(t3+108,0,4);
    tetra_codec_conv_r14(t3,112,mo); tetra_codec_puncture_r23(mo,448,t4);
    tetra_codec_interleave_perm(t4,168,13,t4i);
    tetra_codec_descramble(t4i,168,CC,SCR,MCC,MNC,t5);
    for(int i=0;i<168;i++) soft[i]=t5[i]?6:-6;
    tetra_ul_rx_pack(slot, UL_RX_BT_SCHHU, soft, 168, words);
}
/* SCH/F-Encode + Soft-Pack (slot, BT_SCHF). */
static void mk_schf(const uint8_t *info268, uint8_t slot, uint32_t *words){
    uint8_t t5[432]; int soft[432];
    tetra_codec_schf_encode(info268,CC,SCR,MCC,MNC,t5);
    for(int i=0;i<432;i++) soft[i]=t5[i]?6:-6;
    tetra_ul_rx_pack(slot, UL_RX_BT_SCHF, soft, 432, words);
}

int main(void){
    ul_rx_ctx_t ctx; ul_rx_result_t r; uint32_t w[UL_RX_MAX_WORDS];
    uint8_t info[92], f2[268], f3[268]; int pos;

    /* ===== Szenario A: nicht-fragmentierte MAC-ACCESS → sofort Body ===== */
    tetra_ul_rx_init(&ctx,CC,SCR,MCC,MNC);
    memset(info,0,92); pos=0;
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,0,1); /* mac=0/fill/enc */
    pb(info,&pos,0,2);              /* addr_type=0 */
    pb(info,&pos,0x0ABCDE,24);      /* issi */
    pb(info,&pos,1,1);              /* opt=1 */
    pb(info,&pos,1,1);              /* length_or_cap=1 */
    pb(info,&pos,0,1);              /* frag_flag=0 → NICHT fragmentiert */
    pb(info,&pos,0,4);              /* reservation */
    for(int i=36;i<92;i++) info[i]=xr()&1;   /* TL-SDU-Pattern */
    mk_schhu(info,1,w);
    CK(tetra_ul_rx_service(&ctx,w,1000,&r)==1, "A: service ok");
    CK(r.crc_ok && r.have_body && r.source==UL_RX_SRC_SINGLE, "A: single-burst Body");
    CK(r.body_len==56 && r.ssi==0x0ABCDE, "A: len=56, ssi");
    { int ok=1;
      for(int i=0;i<56;i++) { if(r.body[i]!=(info[36+i]&1)) ok=0; }
      CK(ok,"A: body=info[36..91]"); }

    /* ===== Szenario B: Demand 2-Burst (frag1 + MAC-END-HU, gleicher Slot) ===== */
    tetra_ul_rx_init(&ctx,CC,SCR,MCC,MNC);
    memset(info,0,92); pos=0;
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,0,1);
    pb(info,&pos,0,2); pb(info,&pos,0x111111,24);
    pb(info,&pos,1,1); pb(info,&pos,1,1); pb(info,&pos,1,1); /* opt/cap/frag=1 */
    pb(info,&pos,0,4);
    for(int i=30;i<92;i++) info[i]=xr()&1;   /* frag1-Bereich */
    mk_schhu(info,2,w);
    CK(tetra_ul_rx_service(&ctx,w,2000,&r)==1 && !r.have_body, "B: frag1 kein Body");
    uint8_t end[92]; memset(end,0,92); end[0]=1; for(int i=7;i<92;i++) end[i]=xr()&1; /* MAC-END-HU */
    mk_schhu(end,2,w);   /* selber Slot 2 */
    CK(tetra_ul_rx_service(&ctx,w,2050,&r)==1, "B: end service");
    CK(r.have_body && r.source==UL_RX_SRC_DEMAND && r.body_len==147, "B: Demand-Body 147");
    CK(r.ssi==0x111111, "B: ssi aus Slot-Kennung");
    { int ok=1;
      for(int i=0;i<62;i++) { if(r.body[i]!=(info[30+i]&1)) ok=0; }
      for(int i=0;i<85;i++) { if(r.body[62+i]!=(end[7+i]&1)) ok=0; }
      CK(ok,"B: body=frag1++end"); }

    /* ===== Szenario C: Long-SDS (frag1[SCH/HU] + FRAG + END [SCH/F]) ===== */
    tetra_ul_rx_init(&ctx,CC,SCR,MCC,MNC);
    memset(info,0,92); pos=0;
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,0,1);
    pb(info,&pos,0,2); pb(info,&pos,0x222222,24);
    pb(info,&pos,1,1); pb(info,&pos,1,1); pb(info,&pos,1,1); pb(info,&pos,0,4);
    for(int i=30;i<92;i++) info[i]=xr()&1;
    mk_schhu(info,3,w); tetra_ul_rx_service(&ctx,w,3000,&r);
    CK(!r.have_body, "C: frag1 kein Body");
    memset(f2,0,268); f2[0]=0; f2[1]=1; f2[2]=0; for(int i=4;i<268;i++) f2[i]=xr()&1; /* MAC-FRAG */
    mk_schf(f2,3,w); tetra_ul_rx_service(&ctx,w,3050,&r);
    CK(!r.have_body, "C: FRAG kein Body");
    memset(f3,0,268); f3[0]=0; f3[1]=1; f3[2]=1; for(int i=10;i<268;i++) f3[i]=xr()&1; /* MAC-END */
    mk_schf(f3,3,w); CK(tetra_ul_rx_service(&ctx,w,3100,&r)==1, "C: end service");
    CK(r.have_body && r.source==UL_RX_SRC_LONGSDS, "C: Long-SDS-Body");
    CK(r.body_len==62+264+258, "C: len=62+264+258");
    { int ok=1;
      for(int i=0;i<62;i++)  { if(r.body[i]        !=(info[30+i]&1)) ok=0; }
      for(int i=0;i<264;i++) { if(r.body[62+i]     !=(f2[4+i]&1))    ok=0; }
      for(int i=0;i<258;i++) { if(r.body[62+264+i] !=(f3[10+i]&1))   ok=0; }
      CK(ok,"C: body=frag1++FRAG++END"); }

    printf("SW UL-RX-Service (End-to-End): %d/%d checks PASS\n", checks-fails, checks);
    return fails?1:0;
}
