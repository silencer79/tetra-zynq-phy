/*
 * test_mac_resource_dl_builder.c — Selbsttest gegen tb_mac_resource_dl_builder.v
 *
 * Run: gcc -O2 sw/test_mac_resource_dl_builder.c sw/tetra_mac_resource_dl_builder.c \
 *           -o /tmp/test_macres && /tmp/test_macres
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_mac_resource_dl_builder.h"

static void hex_to_bits(const char *hex, uint8_t *bits, int nbits)
{
    for (int i = 0; i < nbits; i++) {
        int nyb = i / 4;
        int b   = i % 4;
        char c  = hex[nyb];
        unsigned v = (c <= '9') ? (unsigned)(c - '0')
                                : (unsigned)((c | 0x20) - 'a' + 10);
        bits[i] = (v >> (3 - b)) & 1u;
    }
}

static void bits_to_hex(const uint8_t *bits, int nbits, char *out)
{
    int n_nyb = (nbits + 3) / 4;
    for (int i = 0; i < n_nyb; i++) {
        unsigned v = 0;
        for (int b = 0; b < 4; b++) {
            int bidx = i * 4 + b;
            if (bidx < nbits) v = (v << 1) | (bits[bidx] & 1u);
            else              v = v << 1;
        }
        out[i] = "0123456789abcdef"[v & 0xF];
    }
    out[n_nyb] = '\0';
}

/* tb_mac_resource_dl_builder.v build_mm_accept(ssi) — 38 valid bits MSB-first. */
static int build_mm_accept_38(uint32_t ssi, uint8_t *mm)
{
    int p = 0;
    mm[p++] = 0; mm[p++] = 1; mm[p++] = 0; mm[p++] = 1;  /* 0101 */
    mm[p++] = 0; mm[p++] = 0; mm[p++] = 0;               /* 000 */
    mm[p++] = 1;                                          /* O-bit */
    mm[p++] = 1;                                          /* p SSI */
    for (int i = 0; i < 24; i++)
        mm[p++] = (ssi >> (23 - i)) & 1u;
    for (int i = 0; i < 5; i++)
        mm[p++] = 0;
    return p;  /* = 38 */
}

static int check_tc(const char *tag, const tetra_mac_res_meta_t *m,
                     const uint8_t *mm, int mm_len, const char *exp_hex)
{
    uint8_t exp[268];
    hex_to_bits(exp_hex, exp, 268);

    uint8_t got[268];
    int rc = tetra_build_mac_resource_pdu(m, mm, mm_len, got);
    if (rc != 0) {
        printf("FAIL %s: rc=%d\n", tag, rc);
        return 1;
    }
    if (memcmp(got, exp, 268) != 0) {
        char got_hex[68], exp_hex_dump[68];
        bits_to_hex(got, 268, got_hex);
        bits_to_hex(exp, 268, exp_hex_dump);
        printf("FAIL %s\n", tag);
        printf("  got = %s\n", got_hex);
        printf("  exp = %s\n", exp_hex_dump);
        return 1;
    }
    printf("OK   %s\n", tag);
    return 0;
}

int main(void)
{
    int failures = 0;
    int total = 0;

    uint8_t mm[128] = {0};
    int mm_len = build_mm_accept_38(523, mm);

    /* TC1: baseline BL-DATA (no flags). EXPECTED_1 from tb. */
    {
        tetra_mac_res_meta_t meta = {0};
        meta.ssi = 523;
        meta.addr_type = MAC_ADDR_TYPE_SSI;
        meta.llc_pdu_type = MAC_LLC_BL_DATA;
        meta.mle_pd = MAC_MLE_PD_MM;
        total++;
        failures += check_tc("TC1 baseline BL-DATA",  &meta, mm, mm_len,
            "206100020b022a300020b0400000000000000000000000000000000000000000000");
    }

    /* TC2: pc_flag=1 element=5 (tb line 421). */
    {
        tetra_mac_res_meta_t meta = {0};
        meta.ssi = 523;
        meta.addr_type = MAC_ADDR_TYPE_SSI;
        meta.llc_pdu_type = MAC_LLC_BL_DATA;
        meta.mle_pd = MAC_MLE_PD_MM;
        meta.pc_flag = 1;
        meta.pc_element = 5;
        total++;
        failures += check_tc("TC2 pc_flag=1 elem=5", &meta, mm, mm_len,
            "206100020ba822a300020b040000000000000000000000000000000000000000000");
    }

    /* TC3: sg_flag=1, element=0x10 (tb line 456). */
    {
        tetra_mac_res_meta_t meta = {0};
        meta.ssi = 523;
        meta.addr_type = MAC_ADDR_TYPE_SSI;
        meta.llc_pdu_type = MAC_LLC_BL_DATA;
        meta.mle_pd = MAC_MLE_PD_MM;
        meta.sg_flag = 1;
        meta.sg_element = 0x10;
        total++;
        failures += check_tc("TC3 sg_flag=1 elem=0x10", &meta, mm, mm_len,
            "206900020b44022a300020b04000000000000000000000000000000000000000000");
    }

    /* TC4: ca_flag=1, ca_element=0x0273E94B, ca_len=25 (tb line 493). */
    {
        tetra_mac_res_meta_t meta = {0};
        meta.ssi = 523;
        meta.addr_type = MAC_ADDR_TYPE_SSI;
        meta.llc_pdu_type = MAC_LLC_BL_DATA;
        meta.mle_pd = MAC_MLE_PD_MM;
        meta.ca_flag = 1;
        meta.ca_element = 0x0273E94B;
        meta.ca_element_len = 25;
        total++;
        failures += check_tc("TC4 ca_flag=1 25-bit", &meta, mm, mm_len,
            "207900020b273e94b11518001058200000000000000000000000000000000000000");
    }

    /* TC5: all three flags (tb line 532). */
    {
        tetra_mac_res_meta_t meta = {0};
        meta.ssi = 523;
        meta.addr_type = MAC_ADDR_TYPE_SSI;
        meta.llc_pdu_type = MAC_LLC_BL_DATA;
        meta.mle_pd = MAC_MLE_PD_MM;
        meta.pc_flag = 1;
        meta.pc_element = 5;
        meta.sg_flag = 1;
        meta.sg_element = 0x10;
        meta.ca_flag = 1;
        meta.ca_element = 0x0273E94B;
        meta.ca_element_len = 25;
        total++;
        failures += check_tc("TC5 all flags", &meta, mm, mm_len,
            "208100020bac4273e94b11518001058200000000000000000000000000000000000");
    }

    printf("\n=== %d / %d PASS ===\n", total - failures, total);
    return failures > 0 ? 1 : 0;
}
