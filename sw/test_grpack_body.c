/*
 * test_grpack_body.c — Host-side regression for tetra_grpack_build()
 *
 * Build & run:
 *   gcc -Wall -Werror sw/test_grpack_body.c sw/tetra_grpack_body.c \
 *       -o /tmp/test_grpack && /tmp/test_grpack
 *
 * Verifies bit-genau output for the Gold-Ref 1-record case (GS#1) plus
 * 2-record and 3-record envelope lengths.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "tetra_grpack_body.h"

static int g_pass = 0;
static int g_fail = 0;

static void check_eq_int(const char *tag, int got, int expect)
{
    if (got == expect) {
        printf("  PASS  %s  got=%d\n", tag, got);
        g_pass++;
    } else {
        printf("  FAIL  %s  got=%d  expected=%d\n", tag, got, expect);
        g_fail++;
    }
}

static void check_bytes(const char *tag,
                        const uint8_t *got, const uint8_t *exp, int n)
{
    int i;
    int ok = 1;
    for (i = 0; i < n; i++) {
        if (got[i] != exp[i]) { ok = 0; break; }
    }
    if (ok) {
        printf("  PASS  %s  first_%d_bytes match  ", tag, n);
        for (i = 0; i < n; i++) printf("%02X ", got[i]);
        printf("\n");
        g_pass++;
    } else {
        printf("  FAIL  %s\n    got:      ", tag);
        for (i = 0; i < n; i++) printf("%02X ", got[i]);
        printf("\n    expected: ");
        for (i = 0; i < n; i++) printf("%02X ", exp[i]);
        printf("\n");
        g_fail++;
    }
}

int main(void)
{
    uint8_t buf[TETRA_GRPACK_MAX_BYTES];
    int len;

    printf("=========================================================\n");
    printf("  test_grpack_body — Phase Y.2 grpack-builder regression\n");
    printf("=========================================================\n\n");

    /* ----------------------------------------------------------------
     * TC1 — Gold-Ref GS#1 1-record: GSSI=0x2F4D64, class=4, lifetime=1,
     *       atd=0 (attach), addr_type=0, accept.
     *
     * Per memory `reference_gold_group_switch_burst_timeline.md` F1
     * (60-bit MM body, prepended with mm_pdu_type=11 → 64 bits total):
     *   1011 0 0 1 0 1 0111 00000100110 000001 0 01 100 00
     *   <GSSI=0x2F4D64=24bit> 0 0
     *
     * Byte-packed MSB-first:
     *   B0 = 1011 0010 = 0xB2
     *   B1 = 1011 1000 = 0xB8
     *   B2 = 0010 0110 = 0x26
     *   B3 = 0000 0100 = 0x04
     *   B4 = 1100 0000 + GSSI[0..1] = 0xC0 + ...
     * ---------------------------------------------------------------- */
    {
        grpack_meta_t m;
        memset(&m, 0, sizeof(m));
        m.accept_reject  = 0;
        m.num_records    = 1;
        m.records[0].atd            = 0;
        m.records[0].lifetime       = 1;
        m.records[0].class_of_usage = 4;
        m.records[0].addr_type      = 0;
        m.records[0].gssi           = 0x2F4D64u;

        len = tetra_grpack_build(&m, buf);
        printf("TC1 — Gold-Ref GS#1 1-record (GSSI=0x2F4D64)\n");
        check_eq_int("TC1.bitlen", len, 64);

        const uint8_t exp[5] = { 0xB2, 0xB8, 0x26, 0x04, 0xC0 };
        check_bytes("TC1.first_5_bytes", buf, exp, 5);
    }

    /* ----------------------------------------------------------------
     * TC2 — Live-cell example, 1-record GSSI=0x000002.
     *
     * Body bits (with class=4, lifetime=1, atd=0, addr_type=0):
     *   1011 0 0 1 0 1 0111 00000100110 000001 0 01 100 00
     *   <GSSI=0x000002=24bit MSB-first = 0000_0000_0000_0000_0000_0010>
     *   0 0
     *
     * Byte-packed MSB-first:
     *   B0..B3 = 0xB2 0xB8 0x26 0x04 (header is GSSI-independent)
     *   B4 = 1100 0000 = 0xC0
     *   B5..B6 = 0x00 0x00 (24-bit GSSI is mostly zero)
     *   B7 = 1000 0000 (GSSI low byte = 0x02 → bit pattern then 0+0 trailer)
     *
     * Walk through B7 manually:
     *   GSSI low byte 0x02 = 0000_0010, bits 16..23 of GSSI.
     *   Body bit positions 30..38 (post-num_elems) are atd+lifetime+class+
     *   addr_type = 0_01_100_00 → byte 4 stays 0xC0.
     *   Bits 38..61 hold GSSI[23:0]. Bit 38..61: 24 bits MSB-first.
     *   The pre-GSSI fragment (bits 30..37) takes 8 bits.
     *
     *   Byte 4 [bits 32..39]: 1 1 0 0 0 0 0 0  = 0xC0
     *     bit 32 = lifetime[1]=1
     *     bit 33 = class[2]=1 (class=4=100)
     *     bit 34 = class[1]=0
     *     bit 35 = class[0]=0
     *     bit 36 = at[1]=0
     *     bit 37 = at[0]=0
     *     bit 38 = GSSI[23] = 0
     *     bit 39 = GSSI[22] = 0
     *
     *   Byte 5 [bits 40..47]: GSSI[21..14] = 8 zero bits = 0x00
     *   Byte 6 [bits 48..55]: GSSI[13..6]  = 8 zero bits = 0x00
     *   Byte 7 [bits 56..63]: GSSI[5..0] + m_grp_sec(0) + trailing(0)
     *     GSSI[5..0] = 000010
     *     B7 bits = 0000_1000 = 0x08
     * ---------------------------------------------------------------- */
    {
        grpack_meta_t m;
        memset(&m, 0, sizeof(m));
        m.accept_reject  = 0;
        m.num_records    = 1;
        m.records[0].atd            = 0;
        m.records[0].lifetime       = 1;
        m.records[0].class_of_usage = 4;
        m.records[0].addr_type      = 0;
        m.records[0].gssi           = 0x000002u;

        len = tetra_grpack_build(&m, buf);
        printf("\nTC2 — 1-record GSSI=0x000002 (low-value)\n");
        check_eq_int("TC2.bitlen", len, 64);

        const uint8_t exp_first5[5] = { 0xB2, 0xB8, 0x26, 0x04, 0xC0 };
        check_bytes("TC2.first_5_bytes", buf, exp_first5, 5);

        const uint8_t exp_b5_b7[3] = { 0x00, 0x00, 0x08 };
        check_bytes("TC2.bytes_5_to_7", buf + 5, exp_b5_b7, 3);
    }

    /* ----------------------------------------------------------------
     * TC3 — 2-record envelope length (1 attach 0x2F4D64 + 1 detach 0x2F4D63).
     *
     * Length field = 6 + 32*2 = 70 bits = 0b00001000110.
     * num_elems = 2 = 0b000010.
     *
     * Total bits = 64 + 32 = 96.
     * ---------------------------------------------------------------- */
    {
        grpack_meta_t m;
        memset(&m, 0, sizeof(m));
        m.accept_reject  = 0;
        m.num_records    = 2;
        /* Record 0 — attach, GSSI=0x2F4D64 */
        m.records[0].atd            = 0;
        m.records[0].lifetime       = 1;
        m.records[0].class_of_usage = 4;
        m.records[0].addr_type      = 0;
        m.records[0].gssi           = 0x2F4D64u;
        /* Record 1 — detach, GSSI=0x2F4D63 */
        m.records[1].atd            = 1;
        m.records[1].lifetime       = 1;
        m.records[1].class_of_usage = 4;
        m.records[1].addr_type      = 0;
        m.records[1].gssi           = 0x2F4D63u;

        len = tetra_grpack_build(&m, buf);
        printf("\nTC3 — 2-record (1 attach + 1 detach)\n");
        check_eq_int("TC3.bitlen", len, 96);

        /* Header bytes 0..2 stay constant.  Length=70 changes byte 1..3.
         * 4-bit mm_pdu_type=1011, accept=0, reserved=0, o=1, mProp=0, mGID=1,
         * elem_id=0111, length=00001000110 → bits stream:
         *   1011 0 0 1 0 1 0111 00001000110 000010 ...
         *   B0 = 1011 0010 = 0xB2
         *   B1 = 1011 1000 = 0xB8 (bits 8..15)
         *     bit8=1(mGID), bit9..12=0111(elem_id), bit13=0(len[10]),
         *     bit14=0(len[9]), bit15=0(len[8])  → 1011 1000 = 0xB8
         *   B2 = 1000 1100 = 0x8C (bits 16..23 = len[7..0])
         *     len=70=0b1000110 → len[10..0]=0000_1000_110
         *     bit16..23 = bits len[7..0] = 0_1000_110(?) wait recheck
         *
         * Recompute: length is 11-bit = 70 = 00001000110
         * Already wrote bit13 = len[10] = 0
         *               bit14 = len[9]  = 0
         *               bit15 = len[8]  = 0
         *               bit16 = len[7]  = 0
         *               bit17 = len[6]  = 1
         *               bit18 = len[5]  = 0
         *               bit19 = len[4]  = 0
         *               bit20 = len[3]  = 0
         *               bit21 = len[2]  = 1
         *               bit22 = len[1]  = 1
         *               bit23 = len[0]  = 0
         *   B2 = 0100_0110 = 0x46
         *   B3 (bits 24..31) = num_elems[5..0] || atd || lifetime[1]
         *     num_elems = 2 = 000010 → bits 24..29 = 0,0,0,0,1,0
         *     bit 30 = atd = 0
         *     bit 31 = lifetime[1] = 0 (lifetime=01 → lifetime[1]=0)
         *   B3 = 0000_1000 = 0x08
         */
        const uint8_t exp_first4[4] = { 0xB2, 0xB8, 0x46, 0x08 };
        check_bytes("TC3.first_4_bytes", buf, exp_first4, 4);
    }

    /* ----------------------------------------------------------------
     * TC4 — 3-record envelope length.
     *
     * Length field = 6 + 32*3 = 102 bits = 0b00001100110.
     * num_elems = 3 = 0b000011.
     *
     * Total bits = 64 + 64 = 128.
     * ---------------------------------------------------------------- */
    {
        grpack_meta_t m;
        memset(&m, 0, sizeof(m));
        m.accept_reject  = 0;
        m.num_records    = 3;
        m.records[0].atd            = 0;
        m.records[0].lifetime       = 1;
        m.records[0].class_of_usage = 4;
        m.records[0].addr_type      = 0;
        m.records[0].gssi           = 0x111111u;
        m.records[1].atd            = 0;
        m.records[1].lifetime       = 1;
        m.records[1].class_of_usage = 4;
        m.records[1].addr_type      = 0;
        m.records[1].gssi           = 0x222222u;
        m.records[2].atd            = 0;
        m.records[2].lifetime       = 1;
        m.records[2].class_of_usage = 4;
        m.records[2].addr_type      = 0;
        m.records[2].gssi           = 0x333333u;

        len = tetra_grpack_build(&m, buf);
        printf("\nTC4 — 3-record envelope\n");
        check_eq_int("TC4.bitlen", len, 128);

        /* length = 102 = 0b00001100110 */
        /* B2 (bits 16..23) = len[7..0] = 0110_0110 = 0x66 */
        /* Wait: bit13=len[10]=0, bit14=len[9]=0, bit15=len[8]=0
         *       bit16=len[7]=0, bit17=len[6]=1, bit18=len[5]=1,
         *       bit19=len[4]=0, bit20=len[3]=0, bit21=len[2]=1,
         *       bit22=len[1]=1, bit23=len[0]=0
         *  B2 = 0110_0110 = 0x66
         *  B1 = 1011_1000 = 0xB8 (mGID=1, elem_id=0111, len[10..8]=000)
         */
        const uint8_t exp_first3[3] = { 0xB2, 0xB8, 0x66 };
        check_bytes("TC4.first_3_bytes", buf, exp_first3, 3);
    }

    /* ----------------------------------------------------------------
     * TC5 — 0-record body (status-query reject / no-op accept).
     *
     * Body: 1011 0 0 0 0 = 8 bits.
     *   B0 = 1011 0000 = 0xB0
     * ---------------------------------------------------------------- */
    {
        grpack_meta_t m;
        memset(&m, 0, sizeof(m));
        m.accept_reject  = 0;
        m.num_records    = 0;

        len = tetra_grpack_build(&m, buf);
        printf("\nTC5 — 0-record (no-IE body)\n");
        check_eq_int("TC5.bitlen", len, 8);

        const uint8_t exp[1] = { 0xB0 };
        check_bytes("TC5.first_byte", buf, exp, 1);
    }

    printf("\n=========================================================\n");
    printf("  SUMMARY  pass=%d  fail=%d\n", g_pass, g_fail);
    printf("=========================================================\n");
    if (g_fail == 0) {
        printf("  RESULT: PASS\n");
        return 0;
    }
    printf("  RESULT: FAIL\n");
    return 1;
}
