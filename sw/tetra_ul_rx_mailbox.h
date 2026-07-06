/*
 * tetra_ul_rx_mailbox.h — Kontrakt der EINEN UL-RX-Soft-Burst-Mailbox (Option B)
 *
 * Ersetzt die drei fragmentierten UL-Fenster (REG_UL_PDU 0x164, STATUS_2 0x1B4,
 * UL_DEMAND_BODY 0x250) durch EIN Fenster, das JEDEN UL-Burst roh (Soft, vor
 * Decode) plus die on-air Slot-Kennung an SW liefert. RTL demoduliert nur und
 * latcht die TN aus frame_counter; SW dekodiert/reassembliert/parst.
 *
 * Wire-Format (Index-adressiert, wie die NUB-Read-Mailbox):
 *   W0 (Header):
 *     [1:0]  slot_tn    on-air Timeslot 0..3  (= ETSI TS1..4)  ← SLOT-KENNUNG
 *     [3:2]  burst_type 0=SCH/HU 1=SCH/F 2=TCH/S
 *     [15:4] n_soft     Anzahl 4-bit Soft-Werte (168 SCH/HU · 432 SCH/F/NUB)
 *     [31]   valid
 *   W1..WN (Daten): n_soft × 4-bit-signed Soft, 8 Nibbles/Wort LSB-first
 *     (Nibble i in Wort-Bits [i*4 +: 4]); Konvention positiv='1'/negativ='0'.
 *
 * AXI-Offsets sind PROVISORISCH (RTL-Schritt #6 finalisiert sie; supersedet
 * 0x250-Block). Der Wert dieses Headers ist das WORT-FORMAT, nicht die Offsets.
 *
 * License: GPL v2
 */
#ifndef TETRA_UL_RX_MAILBOX_H
#define TETRA_UL_RX_MAILBOX_H

#include <stdint.h>

/* Burst-Typen im Header-Feld [3:2]. */
#define UL_RX_BT_SCHHU  0   /* Control: RA / MAC-ACCESS / MAC-END-HU (168 soft) */
#define UL_RX_BT_SCHF   1   /* SCH/F (432 soft) */
#define UL_RX_BT_TCHS   2   /* TCH/S Voice-NUB (432 soft) */

#define UL_RX_MAX_SOFT  432
#define UL_RX_MAX_WORDS (1 + (UL_RX_MAX_SOFT + 7) / 8)  /* Header + Daten */

/* Provisorische AXI-Offsets (RTL #6 finalisiert). */
#define REG_UL_RX_STATUS 0x250  /* RO  [0]=pending */
#define REG_UL_RX_INDEX  0x254  /* R/W [8:0] Wort-Selektor */
#define REG_UL_RX_DATA   0x258  /* RO  [31:0] indirect via INDEX */
#define REG_UL_RX_ACK    0x25C  /* W1S [0] clear + arm next */

typedef struct {
    uint8_t slot_tn;    /* 0..3 */
    uint8_t burst_type; /* UL_RX_BT_* */
    int     n_soft;     /* Anzahl Soft-Werte */
    int     soft[UL_RX_MAX_SOFT]; /* sign-extended 4-bit, decode-ready */
} ul_rx_burst_t;

/* Packt einen Burst ins Wire-Format (Header + 4-bit-Nibbles, sat. auf [-8,7]).
 * Nützlich für Tests + RTL-Testbench-Vektorerzeugung. Rückgabe: Anzahl Worte. */
int tetra_ul_rx_pack(uint8_t slot_tn, uint8_t burst_type,
                     const int *soft, int n_soft, uint32_t *words_out);

/* SW-Leser: entpackt Header + Soft-Nibbles aus dem Wort-Array in b.
 * Rückgabe: 0 ok, -1 ungültig (valid=0 oder n_soft > MAX). */
int tetra_ul_rx_unpack(const uint32_t *words, ul_rx_burst_t *b);

#endif /* TETRA_UL_RX_MAILBOX_H */
