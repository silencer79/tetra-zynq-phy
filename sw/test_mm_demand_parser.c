/*
 * test_mm_demand_parser.c — Quick smoke test des MM-Demand-Parser-Ports.
 *
 * Testet Roundtrip durch Mailbox-Pack-Format + Parse für mm=2 + mm=7
 * mit konstruierten body-streams. Ist kein vollständiger Conformance-Test
 * gegen RTL — der wird mit echten Captures gemacht wenn Daemon integriert.
 *
 * Run: gcc -O2 sw/test_mm_demand_parser.c sw/tetra_mm_demand_parser.c -o /tmp/test_mm_demand && /tmp/test_mm_demand
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "tetra_mm_demand_parser.h"

static int assert_eq_u32(const char *name, uint32_t got, uint32_t expect)
{
    if (got != expect) {
        printf("  FAIL %s: got 0x%X expected 0x%X\n", name, got, expect);
        return 1;
    }
    printf("  ok   %s = 0x%X\n", name, got);
    return 0;
}

static int assert_eq(const char *name, uint32_t got, uint32_t expect)
{
    if (got != expect) {
        printf("  FAIL %s: got %u expected %u\n", name, got, expect);
        return 1;
    }
    return 0;
}

/* Builds a 129-bit body where each bit is set per the given index list.
 * `bits` is an array of pairs (bit_pos_from_msb, value). */
static void build_body(uint8_t body[17], const int *bit_set_msb, int n_bits)
{
    memset(body, 0, 17);
    for (int i = 0; i < n_bits; i++) {
        int p = bit_set_msb[i];
        body[p >> 3] |= (uint8_t)(1u << (7 - (p & 7)));
    }
}

/* Writes N bits of value `v` starting at bit position `pos_msb` (MSB first). */
static void wbits(uint8_t body[17], int pos_msb, uint32_t v, int n)
{
    for (int i = 0; i < n; i++) {
        int p = pos_msb + i;
        uint32_t bit = (v >> (n - 1 - i)) & 1u;
        if (bit) body[p >> 3] |= (uint8_t)(1u << (7 - (p & 7)));
    }
}

int main(void)
{
    int failures = 0;

    /* ============================================================
     * Test 1: mm=2 minimal — header only, obit=0 → parse_ok=1,
     * keine Type-2-Felder gesetzt. */
    {
        printf("Test 1: mm=2 minimal (LUT=0x5, ra=1, cc=0, obit=0)\n");
        uint8_t body[17] = {0};
        wbits(body, 0, 0x5, 3);   /* location_update_type */
        wbits(body, 3, 1,  1);    /* request_to_append_la */
        wbits(body, 4, 0,  1);    /* cipher_control */
        wbits(body, 5, 0,  1);    /* obit */
        /* rest = 0 */

        tetra_mm_demand_parsed_t p;
        int rc = tetra_mm_demand_parser_parse(body, 2, 0x123456, &p);
        failures += assert_eq("rc",       (uint32_t)rc, 0);
        failures += assert_eq("parse_ok", p.parse_ok, 1);
        failures += assert_eq("mm_type",  p.mm_pdu_type, 2);
        failures += assert_eq_u32("pdu_ssi",  p.pdu_ssi, 0x123456);
        failures += assert_eq("LUT",      p.location_update_type, 5);
        failures += assert_eq("ra",       p.request_to_append_la, 1);
        failures += assert_eq("cc",       p.cipher_control, 0);
        failures += assert_eq("class_of_ms_valid",       p.class_of_ms_valid, 0);
        failures += assert_eq("energy_saving_mode_valid",p.energy_saving_mode_valid, 0);
    }

    /* ============================================================
     * Test 2: mm=2 mit LA-Feld (obit=1, p_class=0, p_esm=0, p_la=1, p_ssi=0, p_ae=0) */
    {
        printf("\nTest 2: mm=2 mit LA=0x1234 (p_la=1)\n");
        uint8_t body[17] = {0};
        int p = 0;
        wbits(body, p, 0x2, 3); p += 3;  /* LUT */
        wbits(body, p, 0,  1); p += 1;   /* ra */
        wbits(body, p, 0,  1); p += 1;   /* cc */
        wbits(body, p, 1,  1); p += 1;   /* obit */
        wbits(body, p, 0,  1); p += 1;   /* p_class */
        wbits(body, p, 0,  1); p += 1;   /* p_esm */
        wbits(body, p, 1,  1); p += 1;   /* p_la */
        /* la_information ist 15 bit, bluestation shiftet zum 14-bit LA. Schreibe 0x1234 << 1 = 0x2468 */
        wbits(body, p, 0x2468, 15); p += 15;
        wbits(body, p, 0,  1); p += 1;   /* p_ssi */
        wbits(body, p, 0,  1); p += 1;   /* p_ae */
        wbits(body, p, 0,  1); p += 1;   /* m-bit terminator */

        tetra_mm_demand_parsed_t pp;
        int rc = tetra_mm_demand_parser_parse(body, 2, 0xAABBCC, &pp);
        failures += assert_eq("rc",       (uint32_t)rc, 0);
        failures += assert_eq("parse_ok", pp.parse_ok, 1);
        failures += assert_eq("LUT",      pp.location_update_type, 2);
        failures += assert_eq("la_valid", pp.la_information_valid, 1);
        failures += assert_eq_u32("la_information", pp.la_information, 0x1234);
    }

    /* ============================================================
     * Test 3: mm=7 minimal (kein GIU) */
    {
        printf("\nTest 3: mm=7 minimal (obit=0)\n");
        uint8_t body[17] = {0};
        int p = 0;
        wbits(body, p, 1, 1); p += 1;  /* gir */
        wbits(body, p, 0, 1); p += 1;  /* atd_mode */
        wbits(body, p, 0, 1); p += 1;  /* obit */

        tetra_mm_demand_parsed_t pp;
        int rc = tetra_mm_demand_parser_parse(body, 7, 0x282F91, &pp);
        failures += assert_eq("rc",       (uint32_t)rc, 0);
        failures += assert_eq("parse_ok", pp.parse_ok, 1);
        failures += assert_eq("gir",      pp.gid_group_identity_report, 1);
        failures += assert_eq("atd_mode", pp.gid_attach_detach_mode, 0);
        failures += assert_eq("gid_count",pp.gid_count, 0);
    }

    /* ============================================================
     * Test 4: mm=7 mit 1× GIU attach at=0 gssi=0x000001 */
    {
        printf("\nTest 4: mm=7 mit 1× GIU attach gssi=0x000001\n");
        uint8_t body[17] = {0};
        int p = 0;
        wbits(body, p, 0, 1); p += 1;  /* gir */
        wbits(body, p, 0, 1); p += 1;  /* atd_mode */
        wbits(body, p, 1, 1); p += 1;  /* obit */
        /* m_rep peek: m=0 (= GRR not present) */
        wbits(body, p, 0, 1); p += 1;  /* m_rep = 0 */
        /* m_giu = 1, elem_id=8, length=N (= 6 + 1 GIU = 6 + 30 = 36 bits) */
        wbits(body, p, 1, 1); p += 1;
        wbits(body, p, 8, 4); p += 4;   /* elem_id=8 */
        wbits(body, p, 36, 11); p += 11; /* length=36 */
        /* GIU payload */
        wbits(body, p, 1, 6); p += 6;   /* num_elem=1 */
        wbits(body, p, 0, 1); p += 1;   /* adi=0 (attach) */
        wbits(body, p, 4, 3); p += 3;   /* cou=4 */
        wbits(body, p, 0, 2); p += 2;   /* at=0 */
        wbits(body, p, 0x000001, 24); p += 24;  /* gssi */

        tetra_mm_demand_parsed_t pp;
        int rc = tetra_mm_demand_parser_parse(body, 7, 0x282F91, &pp);
        failures += assert_eq("rc",       (uint32_t)rc, 0);
        failures += assert_eq("parse_ok", pp.parse_ok, 1);
        failures += assert_eq("gid_count",pp.gid_count, 1);
        failures += assert_eq("rec0.adi", pp.gid_records[0].attach_detach, 0);
        failures += assert_eq("rec0.cou", pp.gid_records[0].class_of_usage, 4);
        failures += assert_eq("rec0.at",  pp.gid_records[0].address_type, 0);
        failures += assert_eq_u32("rec0.gssi", pp.gid_records[0].gssi, 0x000001);
    }

    /* ============================================================
     * Test 5: Mailbox-Unpack: roundtrip W0/W1/W2..W5 → body */
    {
        printf("\nTest 5: mailbox unpack — body[128]=1, body[127:96]=0xAAAA5555\n");
        uint8_t body[17];
        uint8_t mm_type;
        uint32_t ssi;
        tetra_mm_demand_parser_unpack_mailbox(
            0xA5000021u,  /* W0: magic + mm_type=2 + body[128]=1 */
            0x00282F91u,  /* W1: ssi */
            0xAAAA5555u,  /* W2: body[127:96] */
            0,            /* W3 */
            0,            /* W4 */
            0,            /* W5 */
            body, &mm_type, &ssi);

        failures += assert_eq("mm_type", mm_type, 2);
        failures += assert_eq_u32("ssi", ssi, 0x282F91);
        failures += assert_eq("body[0] bit 7 (body[128])", (body[0] >> 7) & 1, 1);
        /* body[127:96] = 0xAAAA5555 → MSB-first into bits 1..32 (= byte[0] bits 6..0, byte[1] all, byte[2] all, byte[3] all, byte[4] bit 7) */
        failures += assert_eq("body[0]", body[0], 0x80 | ((0xAAAA5555u >> 25) & 0x7F));  /* 0x80 + top 7 bits */
    }

    printf("\n=== Summary: %d failures ===\n", failures);
    return failures > 0 ? 1 : 0;
}
