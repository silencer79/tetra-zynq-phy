/* test_ul_mac_parse.c — MAC-ACCESS-Header-Parser vs RTL-Bit-Layout. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_ul_mac_parse.h"
static int checks=0,fails=0;
#define CK(c,m) do{checks++; if(!(c)){fails++; printf("  FAIL: %s\n",m);} }while(0)
static void pb(uint8_t *b, int *pos, uint32_t v, int n){ for(int i=n-1;i>=0;i--) b[(*pos)++]=(v>>i)&1; }

int main(void){
    uint8_t info[92]; ul_mac_access_t o; int pos;

    /* Fall 1: MAC-ACCESS, ISSI, opt=1/cap=1/frag=1, BL-ADATA, MM loc-update. */
    memset(info,0,92); pos=0;
    pb(info,&pos,0,1);          /* mac_pdu_type=0 */
    pb(info,&pos,0,1);          /* fill */
    pb(info,&pos,0,1);          /* enc */
    pb(info,&pos,0,2);          /* addr_type=0 (ISSI) */
    pb(info,&pos,0x123456,24);  /* issi */
    pb(info,&pos,1,1);          /* opt=1 */
    pb(info,&pos,1,1);          /* length_or_cap=1 */
    pb(info,&pos,1,1);          /* frag_flag=1 */
    pb(info,&pos,5,4);          /* reservation_req=5 */
    /* tl_sdu_start=36 */
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,0,2); /* LLC BL-ADATA (link0,fcs0,bl00) */
    pb(info,&pos,1,1);          /* ns_bit=1 (tl+4=40) */
    pb(info,&pos,0,1);          /* nr (tl+5=41) */
    /* llc_payload_start=42 */
    pb(info,&pos,1,3);          /* mle_pd=001 (MM) */
    pb(info,&pos,2,4);          /* mm_pdu_type=2 */
    pb(info,&pos,1,3);          /* loc_upd_type=1 */

    tetra_ul_mac_access_parse(info,&o);
    CK(o.mac_pdu_type==0, "mac_pdu_type=0 (MAC-ACCESS)");
    CK(o.addr_type==0, "addr_type=0");
    CK(o.issi==0x123456, "issi=0x123456");
    CK(o.opt_flag==1 && o.length_or_cap==1 && o.frag_flag==1, "opt/cap/frag");
    CK(o.reservation_req==5, "reservation_req=5");
    CK(o.tl_sdu_start==36, "tl_sdu_start=36 (opt=1)");
    CK(o.llc_link_type==0 && o.llc_bl_pdu_type==0, "LLC BL-ADATA");
    CK(o.ns_bit==1, "ns_bit=1");
    CK(o.mle_pd==1, "mle_pd=001 (MM)");
    CK(o.mm_pdu_type==2, "mm_pdu_type=2");
    CK(o.loc_upd_type==1, "loc_upd_type=1");
    /* meta13 = (2<<9)|(1<<6)|(llc4=0<<2)|(ns=1<<1)|opt=1 = 0x443 */
    CK(o.meta13==0x443, "meta13=0x443");

    /* Fall 2: opt=0 -> tl_sdu_start=30, BL-DATA (llc_payload=tl+5). */
    memset(info,0,92); pos=0;
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,0,1);
    pb(info,&pos,0,2);           /* addr_type=0 */
    pb(info,&pos,0x0000FF,24);   /* issi */
    pb(info,&pos,0,1);           /* opt=0 -> tl_sdu_start=30 */
    /* pos jetzt 30 */
    pb(info,&pos,0,1); pb(info,&pos,0,1); pb(info,&pos,1,2); /* LLC BL-DATA (bl=01) */
    pb(info,&pos,1,1);           /* ns (tl+4=34) */
    /* llc_payload_start = 30+5 = 35 */
    pb(info,&pos,1,3);           /* mle_pd=001 */
    pb(info,&pos,7,4);           /* mm_pdu_type=7 */
    tetra_ul_mac_access_parse(info,&o);
    CK(o.opt_flag==0 && o.tl_sdu_start==30, "opt=0 -> tl_sdu_start=30");
    CK(o.llc_bl_pdu_type==1, "BL-DATA");
    CK(o.mle_pd==1 && o.mm_pdu_type==7, "mle=MM, mm_pdu_type=7 (BL-DATA payload@tl+5)");

    /* SCH/F classify */
    uint8_t f[268]; memset(f,0,268); f[0]=0; f[1]=1; f[2]=1; int ie=0;
    CK(tetra_ul_schf_is_frag(f,&ie)==1 && ie==1, "SCH/F 01 sub=1 -> MAC-END");
    f[2]=0; tetra_ul_schf_is_frag(f,&ie); CK(ie==0, "SCH/F sub=0 -> MAC-FRAG");

    printf("SW MAC-ACCESS-Parser: %d/%d checks PASS\n", checks-fails, checks);
    return fails?1:0;
}
