/*
 * tetra_sch_f_encoder.c — SCH/F channel coder, see header for spec refs.
 * License: GPL v2
 */
#include "tetra_sch_f_encoder.h"

/* CRC-16 CCITT, poly 0x1021, init 0xFFFF, ones-complement final.
 * Schreibt 16-bit CRC MSB-first an bits[nbits..nbits+15]. */
static void crc16_append(uint8_t *bits, int nbits)
{
    uint16_t crc = 0xFFFF;
    for (int i = 0; i < nbits; i++) {
        uint16_t fb = ((bits[i] & 1) << 15) ^ (crc & 0x8000);
        crc = (crc << 1) & 0xFFFF;
        if (fb) crc ^= 0x1021;
    }
    crc = (uint16_t)~crc;
    for (int i = 0; i < 16; i++)
        bits[nbits + i] = (crc >> (15 - i)) & 1;
}

/* Rate-1/4 convolutional mother + P_2/3 puncture (keep G1, G2 of even input,
 * G1 of odd input). 288 input bits → 432 output bits. */
static void conv_punc_r23(const uint8_t *in_bits, int n_in, uint8_t *out_bits)
{
    uint8_t sr = 0;
    int o = 0;
    for (int i = 0; i < n_in; i += 2) {
        uint8_t b0 = in_bits[i] & 1;
        sr = (uint8_t)((sr << 1) | b0) & 0x1F;
        out_bits[o++] = __builtin_parity(sr & 0x13);
        out_bits[o++] = __builtin_parity(sr & 0x1D);
        if (i + 1 < n_in) {
            uint8_t b1 = in_bits[i + 1] & 1;
            sr = (uint8_t)((sr << 1) | b1) & 0x1F;
            out_bits[o++] = __builtin_parity(sr & 0x13);
        }
    }
}

/* Multiplicative interleaver N=432, a=103. */
static void interleave_sch_f(const uint8_t *in_bits, uint8_t *out_bits)
{
    const int N = 432, A = 103;
    for (int k = 1; k <= N; k++) {
        int j = 1 + ((A * k) % N);
        out_bits[j - 1] = in_bits[k - 1];
    }
}

/* Cell scrambler — 32-bit Fibonacci LFSR (taps 0,6,9,10,16,20,21,22,
 * 24,25,27,28,30,31). In-place XOR. */
static void scramble_with_init(uint8_t *bits, int n, uint32_t init)
{
    uint32_t lfsr = init;
    for (int i = 0; i < n; i++) {
        uint32_t fb = ((lfsr >>  0) ^ (lfsr >>  6) ^ (lfsr >>  9) ^
                       (lfsr >> 10) ^ (lfsr >> 16) ^ (lfsr >> 20) ^
                       (lfsr >> 21) ^ (lfsr >> 22) ^ (lfsr >> 24) ^
                       (lfsr >> 25) ^ (lfsr >> 27) ^ (lfsr >> 28) ^
                       (lfsr >> 30) ^ (lfsr >> 31)) & 1u;
        bits[i] ^= (uint8_t)fb;
        lfsr = (fb << 31) | (lfsr >> 1);
    }
}

void tetra_sch_f_encode(const uint8_t *info_268, uint32_t scramb_init,
                         uint8_t *out_432)
{
    uint8_t buf[288];
    for (int i = 0; i < 268; i++) buf[i] = info_268[i] & 1;
    crc16_append(buf, 268);
    buf[284] = buf[285] = buf[286] = buf[287] = 0;

    uint8_t mother_punc[432];
    conv_punc_r23(buf, 288, mother_punc);

    interleave_sch_f(mother_punc, out_432);
    scramble_with_init(out_432, 432, scramb_init);
}
