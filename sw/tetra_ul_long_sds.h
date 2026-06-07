/* tetra_ul_long_sds.h — UL lange-SDS-Reassembly (Multi-Fragment, SCH/F).
 *
 * Eine lange SDS (> ~18 Zeichen) läuft als Fragment-Kette:
 *   MAC-ACCESS(frag=1) auf SCH/HU  → TM-SDU-Anfang
 *   N × MAC-FRAG       auf SCH/F    → Fortsetzungen (je 264 bit)
 *   MAC-END            auf SCH/F    → Abschluss (length_ind octets)
 * Reassembliert ergibt sich die komplette TM-SDU (LLC BL-DATA+FCS → MLE/CMCE
 * → SDS-TL → 8-bit-Text). Verifiziert gegen scripts/decode_ul.py (Ref-WAV 21:37).
 *
 * Die SCH/F-Bursts kommen als NUB-Soft-Werte aus der FPGA-Capture; der
 * Kanaldecode (432→268) macht tetra_codec_schf_decode().
 */
#ifndef TETRA_UL_LONG_SDS_H
#define TETRA_UL_LONG_SDS_H

#include <stdint.h>

#define LSDS_MAX_TMSDU_BITS 2400   /* > 1000 Z. * 8 + Header, großzügig */

typedef struct {
    int      active;                       /* Kette offen? */
    uint32_t ssi;                          /* Absender (vom MAC-ACCESS-Start) */
    int      nbits;                        /* akkumulierte TM-SDU-Bits */
    int      nfrag;                        /* Anzahl SCH/F-Fragmente */
    uint8_t  tm[LSDS_MAX_TMSDU_BITS];      /* TM-SDU-Bits (MSB-first) */
} lsds_chain_t;

/* Kette starten: TM-SDU-Anfang aus der MAC-ACCESS(frag=1)-PDU.
 * tm_start = Zeiger auf TM-SDU-Bits ab payload_start, n = Länge. */
void tetra_lsds_start(lsds_chain_t *c, uint32_t ssi,
                      const uint8_t *tm_start, int n);

/* Ein SCH/F-NUB einspeisen (432 hard type-5 bits, bereits aus Soft demoduliert).
 * Kanaldecodiert + parst MAC-FRAG/MAC-END und hängt das Fragment an.
 * Returns: 0 = kein gültiger SCH/F-Frame / CRC-Fail,
 *          1 = MAC-FRAG angehängt (Kette läuft weiter),
 *          2 = MAC-END angehängt (Kette komplett → c->tm/nbits gültig). */
int tetra_lsds_feed_schf(lsds_chain_t *c, const uint8_t *type5_432,
                         uint8_t cc, uint8_t slot, uint16_t mcc, uint16_t mnc);

#endif /* TETRA_UL_LONG_SDS_H */
