/* test_ul_reass.c — SW-2-Burst-Reassembly vs. RTL-Join-Layout. Host-gcc. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_ul_reassembly.h"

static uint32_t rng = 0x51EEDu;
static uint32_t xr(void){ rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
static void fill(uint8_t *b, int n){ for(int i=0;i<n;i++) b[i]=xr()&1; }

static int checks=0, fails=0;
#define CK(c,msg) do{ checks++; if(!(c)){ fails++; printf("  FAIL: %s\n", msg);} }while(0)

int main(void)
{
    ul_reass_t r;
    uint8_t f1[92], en[92], body[147];
    uint16_t meta; uint32_t ssi;

    /* 1) Basis-Join: body = f1[30..91] ++ en[7..91], SSI/Meta korrekt. */
    ul_reass_init(&r, 0);
    fill(f1,92); fill(en,92);
    CK(ul_reass_frag1(&r, 0xABCDEF, f1, 0x1ABC, 1000) == 0, "frag1 -> slot0");
    CK(ul_reass_end(&r, 0xABCDEF, en, body, &meta, &ssi) == 1, "end match -> reass");
    int join_ok = 1;
    for(int b=0;b<62;b++) if(body[b]      != (f1[30+b]&1)) join_ok=0;
    for(int b=0;b<85;b++) if(body[62+b]   != (en[7+b]&1))  join_ok=0;
    CK(join_ok, "body = f1[30..91] ++ en[7..91]");
    CK(meta==0x1ABC && ssi==0xABCDEF, "meta+ssi durchgereicht");
    CK(r.reass_cnt==1 && r.drop_cnt==0, "counters nach Join");

    /* 2) T0-Ablauf: frag1, kein END, tick über Deadline -> Drop; END danach orphan. */
    ul_reass_init(&r, 100);
    ul_reass_frag1(&r, 0x111111, f1, 0, 5000);
    ul_reass_tick(&r, 5099);              /* < deadline (5100) */
    CK(r.drop_cnt==0 && r.slot[0].occupied, "vor Deadline noch belegt");
    ul_reass_tick(&r, 5100);              /* == deadline -> drop */
    CK(r.drop_cnt==1 && !r.slot[0].occupied, "Deadline -> Drop");
    CK(ul_reass_end(&r, 0x111111, en, body, &meta, &ssi) == 0, "orphan END nach Timeout");

    /* 3) Beide Slots belegt -> 3. frag1 (neue SSI) verworfen. */
    ul_reass_init(&r, 0);
    CK(ul_reass_frag1(&r, 0x1, f1, 0, 0) == 0, "slot0");
    CK(ul_reass_frag1(&r, 0x2, f1, 0, 0) == 1, "slot1");
    CK(ul_reass_frag1(&r, 0x3, f1, 0, 0) == -1, "beide voll -> drop");
    CK(r.drop_cnt==1, "drop_cnt nach both-full");

    /* 4) Replace-on-same-SSI: gleiche SSI erneut -> selber Slot, kein Drop. */
    ul_reass_init(&r, 0);
    ul_reass_frag1(&r, 0x9, f1, 0, 0);
    uint8_t f1b[92]; fill(f1b,92);
    CK(ul_reass_frag1(&r, 0x9, f1b, 0, 10) == 0, "replace same-ssi -> slot0");
    CK(r.drop_cnt==0, "replace -> kein Drop");
    ul_reass_end(&r, 0x9, en, body, &meta, &ssi);
    int repl_ok=1; for(int b=0;b<62;b++) if(body[b]!=(f1b[30+b]&1)) repl_ok=0;
    CK(repl_ok, "replace nutzt neuen frag1");

    printf("SW UL-Reassembly: %d/%d checks PASS\n", checks-fails, checks);
    return fails ? 1 : 0;
}
