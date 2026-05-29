/* Host-side test for tetra_bs_tch_s_{encode,decode} — bit-exact diff vs BlueStation Rust. */
#include "tetra_bs_tch_s.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void print_hex(const uint8_t *bits, int n)
{
 for (int i = 0; i < n; i += 8) {
 uint8_t byte = 0;
 for (int b = 0; b < 8 && i + b < n; b++)
 byte |= (bits[i + b] & 1) << (7 - b);
 printf("%02X", byte);
 }
 printf("\n");
}

int main(int argc, char **argv)
{
 if (argc < 2) {
 fprintf(stderr, "usage: %s (encode|decode) [scramb_hex] [bits_hex_or_zero]\n", argv[0]);
 return 1;
 }
 uint32_t scramb_init = 0xE1670EC7;
 if (argc >= 3) scramb_init = (uint32_t)strtoul(argv[2], NULL, 16);

 if (strcmp(argv[1], "encode") == 0) {
 uint8_t acelp[274] = {0};
 if (argc >= 4 && strcmp(argv[3], "zero") != 0) {
 // parse hex
 const char *hex = argv[3];
 int n = strlen(hex);
 for (int i = 0; i < n / 2; i++) {
 uint8_t byte;
 sscanf(hex + i*2, "%2hhx", &byte);
 for (int b = 0; b < 8; b++) {
 int idx = i * 8 + b;
 if (idx < 274) acelp[idx] = (byte >> (7 - b)) & 1;
 }
 }
 }
 uint8_t type5[432];
 tetra_bs_tch_s_encode(acelp, scramb_init, type5);
 printf("ENCODE_OUT_432_HEX: ");
 print_hex(type5, 432);
 } else if (strcmp(argv[1], "decode") == 0) {
 uint8_t type5[432] = {0};
 if (argc >= 4) {
 const char *hex = argv[3];
 int n = strlen(hex);
 for (int i = 0; i < n / 2; i++) {
 uint8_t byte;
 sscanf(hex + i*2, "%2hhx", &byte);
 for (int b = 0; b < 8; b++) {
 int idx = i * 8 + b;
 if (idx < 432) type5[idx] = (byte >> (7 - b)) & 1;
 }
 }
 }
 uint8_t acelp[274];
 int bfi = tetra_bs_tch_s_decode(type5, scramb_init, acelp);
 printf("DECODE_BFI: %s\n", bfi == 0 ? "OK" : "FAIL");
 printf("DECODE_OUT_274_HEX: ");
 print_hex(acelp, 274);
 }
 return 0;
}
