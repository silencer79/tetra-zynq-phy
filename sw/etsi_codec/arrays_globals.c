/*
 * arrays_globals.c — Non-const globals for tetra-kit codec.
 *
 * Originally these lived in arrays.tab and were included by both sub_cc.c
 * and sub_cd.c. tetra-kit builds ccoder + cdecoder as SEPARATE binaries so
 * single-definition was fine. For our BS we link both encoder + decoder
 * together — globals must be defined once, declared extern elsewhere.
 *
 * arrays.tab keeps the const tables (TAB0/TAB1/TAB2, A1/A2, TAB_CRC*, etc.)
 * — `const` arrays at file scope are duplicate-safe in C.
 */
#include "channel.h"
#include "const.tab"

Word16 Previous[(1 << (K - 1))][2];
Word16 Best_previous[(1 << (K - 1))][Decoding_delay];
Word16 T1[(1 << (K - 1))][2], T2[(1 << (K - 1))][2], T3[(1 << (K - 1))][2];
Word16 Score[(1 << (K - 1))];
Word16 Ex_score[(1 << (K - 1))];
Word16 Received[3];

Word16 Initialization;
Word16 Nber_Info_Bits;
Word16 Msb_bit;
Word16 M_1;
Word16 Min_value_allowed;
Word16 Max_value_allowed;
