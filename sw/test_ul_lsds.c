/* test_ul_lsds.c — Long-SDS Multi-Fragment-Reassembly (SCH/F) vs RTL-Layout. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_ul_reassembly.h"
static uint32_t rng=0x7AB1E5u; static uint32_t xr(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void fill(uint8_t*b,int n){for(int i=0;i<n;i++)b[i]=xr()&1;}
static int checks=0,fails=0;
#define CK(c,m) do{checks++; if(!(c)){fails++; printf("  FAIL: %s\n",m);} }while(0)

int main(void){
    ul_lsds_t r; uint8_t f1[92], fr[268], en[268], body[UL_LSDS_MAX_BITS];
    int len; uint32_t ssi; uint8_t opt;

    /* Kette: frag1 + 1 FRAG + END. Body = f1[30..91](62) ++ fr[4..267](264) ++ en[10..267](258). */
    ul_lsds_init(&r, 0);
    fill(f1,92); fill(fr,268); fill(en,268);
    ul_lsds_start(&r, 0x2468AC, f1, 1 /*opt*/, 1000);
    CK(ul_lsds_frag(&r, fr, 0 /*FRAG*/, 1050, body,&len,&ssi,&opt)==0, "FRAG haengt an, nicht komplett");
    CK(ul_lsds_frag(&r, en, 1 /*END*/, 1100, body,&len,&ssi,&opt)==1, "END komplettiert");
    CK(len == 62+264+258, "len = 62+264+258 = 584");
    int ok=1;
    for(int b=0;b<62;b++)  if(body[b]        != (f1[30+b]&1)) ok=0;
    for(int b=0;b<264;b++) if(body[62+b]     != (fr[4+b]&1))  ok=0;
    for(int b=0;b<258;b++) if(body[62+264+b] != (en[10+b]&1)) ok=0;
    CK(ok, "body = frag1[30..91] ++ FRAG[4..267] ++ END[10..267]");
    CK(ssi==0x2468AC && opt==1, "ssi+opt durchgereicht");
    CK(r.reass_cnt==1 && r.drop_cnt==0, "counters");

    /* Mehrere FRAGs. */
    ul_lsds_init(&r,0); fill(f1,92);
    ul_lsds_start(&r,0x111,f1,0,0);
    for(int k=0;k<3;k++){ fill(fr,268); ul_lsds_frag(&r,fr,0,0,body,&len,&ssi,&opt); }
    fill(en,268); ul_lsds_frag(&r,en,1,0,body,&len,&ssi,&opt);
    CK(len==62+3*264+258, "3 FRAGs + END len");

    /* Orphan-Fragment ohne Kette. */
    ul_lsds_init(&r,0);
    CK(ul_lsds_frag(&r,fr,1,0,body,&len,&ssi,&opt)==0, "orphan END ohne start -> 0");

    /* T0-Ablauf. */
    ul_lsds_init(&r,100); ul_lsds_start(&r,0x9,f1,0,5000);
    ul_lsds_tick(&r,5099); CK(r.active && r.drop_cnt==0, "vor Deadline aktiv");
    ul_lsds_tick(&r,5100); CK(!r.active && r.drop_cnt==1, "T0 -> Drop");

    printf("SW Long-SDS-Reassembly: %d/%d checks PASS\n", checks-fails, checks);
    return fails?1:0;
}
