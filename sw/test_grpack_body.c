/*
 * test_grpack_body.c — Host-side regression for tetra_grpack_build()
 *
 * Build & run:
 * gcc -Wall -Werror sw/test_grpack_body.c sw/tetra_grpack_body.c \
 * -o /tmp/test_grpack && /tmp/test_grpack
 *
 * Verifies bit-genau output for the Ref 1-record case (GS#1) plus
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
 printf(" PASS %s got=%d\n", tag, got);
 g_pass++;
 } else {
 printf(" FAIL %s got=%d expected=%d\n", tag, got, expect);
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
 printf(" PASS %s first_%d_bytes match ", tag, n);
 for (i = 0; i < n; i++) printf("%02X ", got[i]);
 printf("\n");
 g_pass++;
 } else {
 printf(" FAIL %s\n got: ", tag);
 for (i = 0; i < n; i++) printf("%02X ", got[i]);
 printf("\n expected: ");
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
 printf(" test_grpack_body — Phase Y.2 grpack-builder regression\n");
 printf("=========================================================\n\n");

 /* ----------------------------------------------------------------
 * TC1 — Ref GS#1 1-record: GSSI=0x2F4D64, class=4, lifetime=1,
 * atd=0 (attach), addr_type=0, accept.
 *
 * Quelle: removed-doc Burst
 * #4811 info_hex `0x2081282ff440011b 3704c09817a6b220 00108000...`
 * Bits 60..121 (= MM body, 62 bits, MSB-first):
 * 1011 0011 0111 0000 0100 1100 0000 1001
 * 1000 0001 0111 1010 0110 1011 001000
 * Byte-packed: B3 70 4C 09 81 7A 6B 20 (last 6 bits + 2 padding zeros)
 *
 * Layout: [pdu 4][ar 1][rsv 1][obit 1][m=1][elem_id=7 4][length=38 11]
 * [num=1 6][atd 1][lt 2][cls 3][at 2][gssi 24][trail_m 0]
 * Total = 62 bits.
 * ---------------------------------------------------------------- */
 {
 grpack_meta_t m;
 memset(&m, 0, sizeof(m));
 m.accept_reject = 0;
 m.num_records = 1;
 m.records[0].atd = 0;
 m.records[0].lifetime = 1;
 m.records[0].class_of_usage = 4;
 m.records[0].addr_type = 0;
 m.records[0].gssi = 0x2F4D64u;

 len = tetra_grpack_build(&m, buf);
 printf("TC1 — Ref GS#1 1-record (GSSI=0x2F4D64)\n");
 check_eq_int("TC1.bitlen", len, 62);

 const uint8_t exp[8] = { 0xB3, 0x70, 0x4C, 0x09, 0x81, 0x7A, 0x6B, 0x20 };
 check_bytes("TC1.ref_8_bytes", buf, exp, 8);
 }

 /* ----------------------------------------------------------------
 * TC2 — Live-cell example, 1-record GSSI=0x000002.
 * Identisches Layout zu TC1, nur GSSI=0x000002 statt 0x2F4D64.
 * ---------------------------------------------------------------- */
 {
 grpack_meta_t m;
 memset(&m, 0, sizeof(m));
 m.accept_reject = 0;
 m.num_records = 1;
 m.records[0].atd = 0;
 m.records[0].lifetime = 1;
 m.records[0].class_of_usage = 4;
 m.records[0].addr_type = 0;
 m.records[0].gssi = 0x000002u;

 len = tetra_grpack_build(&m, buf);
 printf("\nTC2 — 1-record GSSI=0x000002 (low-value)\n");
 check_eq_int("TC2.bitlen", len, 62);

 /* Header (bits 0..36) ist GSSI-unabhängig: B3 70 4C 09 8x.
 * GSSI=0x000002 = MSB-first 0000 0000 0000 0000 0000 0010
 * → bit 37..60 = 24 bits = mostly zero, ending in 010
 * → bytes from bit 32:
 * bit 32..36 = cls(100) + at(00) = 10000
 * bit 37..44 = gssi[0..7] = 0000 0000
 * bit 45..52 = gssi[8..15] = 0000 0000
 * bit 53..60 = gssi[16..23] = 0000 0010
 * bit 61 = trail = 0
 * → byte 4 [bits 32..39] = 1000 0000 = 0x80
 * → byte 5 [bits 40..47] = 0000 0000 = 0x00
 * → byte 6 [bits 48..55] = 0000 0000 = 0x00
 * → byte 7 [bits 56..63] = 0010 _0_00 = 0x10 (last 2 bits = padding) */
 const uint8_t exp[8] = { 0xB3, 0x70, 0x4C, 0x09, 0x80, 0x00, 0x00, 0x10 };
 check_bytes("TC2.live_8_bytes", buf, exp, 8);
 }

 /* ----------------------------------------------------------------
 * TC3 — 2-record envelope length. spec-konform 62 + 32 = 94 bits.
 * Length field = 6 + 32*2 = 70 bits.
 * num_elems = 2.
 * ---------------------------------------------------------------- */
 {
 grpack_meta_t m;
 memset(&m, 0, sizeof(m));
 m.accept_reject = 0;
 m.num_records = 2;
 /* Record 0 — attach, GSSI=0x2F4D64 */
 m.records[0].atd = 0;
 m.records[0].lifetime = 1;
 m.records[0].class_of_usage = 4;
 m.records[0].addr_type = 0;
 m.records[0].gssi = 0x2F4D64u;
 /* Record 1 — detach, GSSI=0x2F4D63 */
 m.records[1].atd = 1;
 m.records[1].lifetime = 1;
 m.records[1].class_of_usage = 4;
 m.records[1].addr_type = 0;
 m.records[1].gssi = 0x2F4D63u;

 len = tetra_grpack_build(&m, buf);
 printf("\nTC3 — 2-record (1 attach + 1 detach)\n");
 check_eq_int("TC3.bitlen", len, 94);

 /* 62-bit single-record header + 32-bit second record = 94 bits.
 * Layout (MSB-first):
 * pdu(1011) ar(0) rsv(0) obit(1) m(1) elem_id(0111)
 * length=70=0b00001000110 num=2=0b000010
 * record0: atd=0 lt=01 cls=100 at=00 gssi=0x2F4D64
 * record1: atd=1 lt=01 cls=100 at=00 gssi=0x2F4D63
 * trail=0 */
 const uint8_t exp_first4[4] = { 0xB3, 0x70, 0x8C, 0x11 };
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
 m.accept_reject = 0;
 m.num_records = 3;
 m.records[0].atd = 0;
 m.records[0].lifetime = 1;
 m.records[0].class_of_usage = 4;
 m.records[0].addr_type = 0;
 m.records[0].gssi = 0x111111u;
 m.records[1].atd = 0;
 m.records[1].lifetime = 1;
 m.records[1].class_of_usage = 4;
 m.records[1].addr_type = 0;
 m.records[1].gssi = 0x222222u;
 m.records[2].atd = 0;
 m.records[2].lifetime = 1;
 m.records[2].class_of_usage = 4;
 m.records[2].addr_type = 0;
 m.records[2].gssi = 0x333333u;

 len = tetra_grpack_build(&m, buf);
 printf("\nTC4 — 3-record envelope\n");
 check_eq_int("TC4.bitlen", len, 126);

 /* 62 + 64 = 126 bits. length=102=0b00001100110, num=3=0b000011. */
 const uint8_t exp_first3[3] = { 0xB3, 0x70, 0xCC };
 check_bytes("TC4.first_3_bytes", buf, exp_first3, 3);
 }

 /* ----------------------------------------------------------------
 * TC5 — 0-record body (status-query reject / no-op accept).
 *
 * Body: 1011 0 0 0 0 = 8 bits.
 * B0 = 1011 0000 = 0xB0
 * ---------------------------------------------------------------- */
 {
 grpack_meta_t m;
 memset(&m, 0, sizeof(m));
 m.accept_reject = 0;
 m.num_records = 0;

 len = tetra_grpack_build(&m, buf);
 printf("\nTC5 — 0-record (no-IE body)\n");
 check_eq_int("TC5.bitlen", len, 8);

 const uint8_t exp[1] = { 0xB0 };
 check_bytes("TC5.first_byte", buf, exp, 1);
 }

 printf("\n=========================================================\n");
 printf(" SUMMARY pass=%d fail=%d\n", g_pass, g_fail);
 printf("=========================================================\n");
 if (g_fail == 0) {
 printf(" RESULT: PASS\n");
 return 0;
 }
 printf(" RESULT: FAIL\n");
 return 1;
}
