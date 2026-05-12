/*
 * test_cmce_parser.c — Phase 7 G.1 UL CMCE parser regression
 *
 * Build & run via `make test_cmce_parser` (host gcc, not cross).
 *
 * Test vectors are constructed by feeding a known bit-string into the
 * MSB-first byte buffer, then calling tetra_cmce_parse() and asserting
 * the recovered fields.  Bit-strings mirror the bluestation `to_bitbuf`
 * round-trip tests where available.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "tetra_cmce_parser.h"

static int g_pass = 0;
static int g_fail = 0;

static void put_bit(uint8_t *buf, int pos, int b)
{
    unsigned byte_idx = (unsigned)pos >> 3;
    unsigned bit_idx  = 7u - ((unsigned)pos & 0x7u);
    if (b) buf[byte_idx] |=  (uint8_t)(1u << bit_idx);
    else   buf[byte_idx] &= ~(uint8_t)(1u << bit_idx);
}

/* Pack a 0/1 ASCII bit-string into a MSB-first byte buffer. */
static int pack_bitstr(const char *s, uint8_t *out)
{
    int n = 0;
    memset(out, 0, 32);
    while (*s) {
        if (*s == '0' || *s == '1') {
            put_bit(out, n, (*s == '1') ? 1 : 0);
            n++;
        }
        s++;
    }
    return n;
}

#define ASSERT_EQ_U(tag, got, exp) do {                                 \
    if ((unsigned long)(got) == (unsigned long)(exp)) {                 \
        printf("  PASS  %-40s got=%lu\n", (tag), (unsigned long)(got)); \
        g_pass++;                                                        \
    } else {                                                            \
        printf("  FAIL  %-40s got=%lu  expected=%lu\n",                 \
               (tag), (unsigned long)(got), (unsigned long)(exp));      \
        g_fail++;                                                        \
    }                                                                   \
} while (0)

int main(void)
{
    uint8_t buf[32];
    int n_bits;
    cmce_pdu_t p;
    int rc;

    printf("=========================================================\n");
    printf("  test_cmce_parser — Phase 7 G.1 UL CMCE parser\n");
    printf("=========================================================\n\n");

    /* ---------------------------------------------------------------
     * TC1 — U-TX-DEMAND: pdu_type=10 (01010), call_id=0x1234, prio=2,
     *       encryption_control=1, reserved=0, o-bit=0.
     * 0x1234 = 4660 = 14-bit binary 01001000110100.
     * Bits: 01010 01001000110100 10 1 0 0
     *     = 5+14+2+1+1+1 = 24 bits
     * --------------------------------------------------------------- */
    printf("TC1 — U-TX-DEMAND call_id=0x1234 prio=2 enc=1\n");
    n_bits = pack_bitstr("01010" "01001000110100" "10" "1" "0" "0", buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",            rc, 0);
    ASSERT_EQ_U("pdu_type",      p.pdu_type, CMCE_U_TX_DEMAND);
    ASSERT_EQ_U("call_id",       p.call_identifier, 0x1234);
    ASSERT_EQ_U("tx_demand_pri", p.tx_demand_priority, 2);
    ASSERT_EQ_U("enc_ctrl",      p.encryption_control, 1);
    ASSERT_EQ_U("reserved",      p.reserved, 0);
    ASSERT_EQ_U("o_bit",         p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC2 — U-RELEASE: pdu_type=6 (00110), call_id=217, cause=11
     *       (ExpiryOfTimer), o-bit=0.
     * Source: bluestation u_release `test_parse_d_release`-equivalent;
     * U-RELEASE shares the layout with D-RELEASE for these fields.
     * Bits: 00110 00000011011001 01011 0
     *     = 5+14+5+1 = 25 bits
     * --------------------------------------------------------------- */
    printf("\nTC2 — U-RELEASE call_id=217 cause=11\n");
    n_bits = pack_bitstr("00110" "00000011011001" "01011" "0", buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",            rc, 0);
    ASSERT_EQ_U("pdu_type",      p.pdu_type, CMCE_U_RELEASE);
    ASSERT_EQ_U("call_id",       p.call_identifier, 217);
    ASSERT_EQ_U("cause",         p.disconnect_cause, 11);
    ASSERT_EQ_U("o_bit",         p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC3 — U-TX-CEASED: pdu_type=9 (01001), call_id=42, o-bit=0.
     * Bits: 01001 00000000101010 0 = 5+14+1 = 20 bits
     * --------------------------------------------------------------- */
    printf("\nTC3 — U-TX-CEASED call_id=42\n");
    n_bits = pack_bitstr("01001" "00000000101010" "0", buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",            rc, 0);
    ASSERT_EQ_U("pdu_type",      p.pdu_type, CMCE_U_TX_CEASED);
    ASSERT_EQ_U("call_id",       p.call_identifier, 42);
    ASSERT_EQ_U("o_bit",         p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC4 — U-SETUP: pdu_type=7 (00111), area=0, hook=0, sd=0,
     *       BSI: cmt=0(TchS) enc=0 commtype=1 speech_serv=0,
     *       request_to_transmit=1, prio=4, clir=0, CPTI=Ssi(1),
     *       ssi=910001, o-bit=0.
     * Bits:
     *   00111 (pdu) | 0000 (area) | 0 (hook) | 0 (sd)
     *   | 000 (cmt=TchS) 0 (enc) 01 (commtype) 00 (speech_serv)
     *   | 1 (request_tx) | 0100 (priority=4) | 00 (clir)
     *   | 01 (cpti=Ssi) | 000011011110001010110001 (ssi=910001)
     *   | 0 (o-bit)
     * Total = 5+4+1+1+8+1+4+2+2+24+1 = 53 bits
     * --------------------------------------------------------------- */
    printf("\nTC4 — U-SETUP ssi=910001 BSI(TchS,p2mp)\n");
    n_bits = pack_bitstr(
        "00111"
        "0000" "0" "0"
        "000" "0" "01" "00"
        "1" "0100" "00"
        "01"
        "000011011110001010110001"
        "0",
        buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",                  rc, 0);
    ASSERT_EQ_U("pdu_type",            p.pdu_type, CMCE_U_SETUP);
    ASSERT_EQ_U("area_selection",      p.area_selection, 0);
    ASSERT_EQ_U("hook",                p.hook_method_selection, 0);
    ASSERT_EQ_U("simplex_duplex",      p.simplex_duplex_selection, 0);
    ASSERT_EQ_U("bsi.cmt",             p.bsi.circuit_mode_type, 0);
    ASSERT_EQ_U("bsi.enc",             p.bsi.encryption_flag, 0);
    ASSERT_EQ_U("bsi.commtype",        p.bsi.communication_type, 1);
    ASSERT_EQ_U("bsi.speech_service",  p.bsi.speech_service, 0);
    ASSERT_EQ_U("request_to_tx",       p.request_to_transmit_send_data, 1);
    ASSERT_EQ_U("call_priority",       p.call_priority, 4);
    ASSERT_EQ_U("clir_control",        p.clir_control, 0);
    ASSERT_EQ_U("cpti",                p.called_party_type_identifier, CMCE_CPTI_SSI);
    ASSERT_EQ_U("ssi",                 p.called_party_ssi, 910001);
    ASSERT_EQ_U("o_bit",               p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC4b — U-SETUP CPTI=SNA(0): called_party_sna = 0x5A.
     * Bits: 5+4+1+1+8+1+4+2+2+8+1 = 37 bits.
     * --------------------------------------------------------------- */
    printf("\nTC4b — U-SETUP cpti=SNA sna=0x5A\n");
    n_bits = pack_bitstr(
        "00111"
        "0000" "0" "0"
        "000" "0" "01" "00"
        "1" "0100" "00"
        "00"
        "01011010"
        "0",
        buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",                  rc, 0);
    ASSERT_EQ_U("pdu_type",            p.pdu_type, CMCE_U_SETUP);
    ASSERT_EQ_U("cpti",                p.called_party_type_identifier, CMCE_CPTI_SNA);
    ASSERT_EQ_U("sna",                 p.called_party_sna, 0x5A);
    ASSERT_EQ_U("o_bit",               p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC4c — U-SETUP CPTI=TSI(2): ssi=0x123456, extension=0xABCDEF.
     * Bits: 5+4+1+1+8+1+4+2+2+24+24+1 = 77 bits.
     * --------------------------------------------------------------- */
    printf("\nTC4c — U-SETUP cpti=TSI ssi=0x123456 ext=0xABCDEF\n");
    n_bits = pack_bitstr(
        "00111"
        "0000" "0" "0"
        "000" "0" "01" "00"
        "1" "0100" "00"
        "10"
        "000100100011010001010110"
        "101010111100110111101111"
        "0",
        buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",                  rc, 0);
    ASSERT_EQ_U("pdu_type",            p.pdu_type, CMCE_U_SETUP);
    ASSERT_EQ_U("cpti",                p.called_party_type_identifier, CMCE_CPTI_TSI);
    ASSERT_EQ_U("ssi",                 p.called_party_ssi, 0x123456u);
    ASSERT_EQ_U("ext",                 p.called_party_extension, 0xABCDEFu);
    ASSERT_EQ_U("o_bit",               p.o_bit, 0);

    /* ---------------------------------------------------------------
     * TC5 — Unsupported pdu_type returns -2.
     * pdu_type = 31 (CmceFunctionNotSupported, 11111).
     * Note: we map this to CMCE_UNSUPPORTED, so rc must be -2.
     * --------------------------------------------------------------- */
    printf("\nTC5 — Unsupported pdu_type=31 yields rc=-2\n");
    n_bits = pack_bitstr("11111" "00000000000000", buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",            (unsigned long)(rc & 0xFF), 0xFEu);  /* -2 = 0xFE LSB */
    ASSERT_EQ_U("pdu_type",      p.pdu_type, CMCE_UNSUPPORTED);

    /* ---------------------------------------------------------------
     * TC6 — Too-short buffer yields rc=-1.
     * Only 3 bits supplied — under the 5-bit pdu_type minimum.
     * --------------------------------------------------------------- */
    printf("\nTC6 — Short buffer yields rc=-1\n");
    n_bits = pack_bitstr("010", buf);
    rc = tetra_cmce_parse(buf, n_bits, &p);
    ASSERT_EQ_U("rc",            (unsigned long)(rc & 0xFF), 0xFFu);  /* -1 = 0xFF LSB */

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
