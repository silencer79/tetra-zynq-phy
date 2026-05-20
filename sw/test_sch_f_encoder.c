/*
 * test_sch_f_encoder.c — Selbsttest gegen gen_sch_f_tv.py
 *
 * Run: gcc -O2 sw/test_sch_f_encoder.c sw/tetra_sch_f_encoder.c \
 *           -o /tmp/test_schf && /tmp/test_schf
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "tetra_sch_f_encoder.h"

/* Convert hex string (no prefix) to bit-array MSB-first. */
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

struct tv {
    const char *tag;
    const char *info_hex;   /* 67 hex chars = 268 bits */
    uint32_t    scramble_init;
    const char *coded_hex;  /* 108 hex chars = 432 bits */
};

static const struct tv vectors[] = {
    {"zeros_init_zero",
     "0000000000000000000000000000000000000000000000000000000000000000000",
     0x00000000u,
     "000048000000000800000000000000100000000010000000001000000000120000000000000000000200000000000000000000000004"},
    {"zeros_init_three",
     "0000000000000000000000000000000000000000000000000000000000000000000",
     0x00000003u,
     "bff4b99ac047a2a6a3a2f02fbf4ab91d9595652939325694aeb6da5faa9c8bc3305922ac737ed0ca4578ca23366e3e612715ca75d11a"},
    {"ones_cell",
     "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
     0xe1670ec7u,
     "06db617362627e3563c8aaf577d151263af86f0747974d5bec9c4642af74bd74917a9401cb10e126420dbc24cc647c22c66de86cd470"},
    {"a5_rep_cell",
     "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5",
     0xe1670ec7u,
     "dac6a8af7fa3a228a214a734a2cc907a2738b31a864b51ba3083879eb2b57369508689c0170d24fa5fcc60190db861e31e7029b0c9b5"},
};

int main(void)
{
    int failures = 0;

    for (size_t i = 0; i < sizeof(vectors)/sizeof(vectors[0]); i++) {
        const struct tv *t = &vectors[i];
        uint8_t info[268];
        uint8_t coded[432];
        uint8_t gold[432];
        char got_hex[109];

        hex_to_bits(t->info_hex,  info,  268);
        hex_to_bits(t->coded_hex, gold,  432);

        tetra_sch_f_encode(info, t->scramble_init, coded);

        if (memcmp(coded, gold, 432) != 0) {
            bits_to_hex(coded, 432, got_hex);
            printf("FAIL  %s\n", t->tag);
            printf("  got  = %s\n", got_hex);
            printf("  want = %s\n", t->coded_hex);
            failures++;
        } else {
            printf("OK    %s\n", t->tag);
        }
    }

    printf("\n=== %d / %zu PASS ===\n",
           (int)(sizeof(vectors)/sizeof(vectors[0])) - failures,
           sizeof(vectors)/sizeof(vectors[0]));
    return failures > 0 ? 1 : 0;
}
