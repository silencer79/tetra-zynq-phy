/* tetra_sds_dl_frag.h — DL MAC-Fragmentierung einer langen D-SDS-DATA an das Ziel-MS.
 *
 * Eine lange SDS (UDD > 24 Oktette) passt nicht in einen einzelnen DL-SCH/F-Burst.
 * Dieses Modul baut die TM-SDU (LLC BL-ADATA + MLE-PD(CMCE) + CMCE D-SDS-DATA mit der
 * vollen UDD) und fragmentiert sie auf MAC-Ebene in eine Burst-Kette:
 *
 *   Burst 0  MAC-RESOURCE (addr=Ziel-SSI, length_ind=62=Fragmentierung) + 1. TM-SDU-Teil
 *   Burst 1..N-2  MAC-FRAG  (mac_pdu_type=01, sub=0) + TM-SDU-Fortsetzung
 *   Burst N-1     MAC-END   (mac_pdu_type=01, sub=1, 6-bit Längenfeld) + letzter Teil
 *
 * Format bit-exakt gegen das 392-MHz-Gold (dl_ref.log: MAC-RESOURCE→MAC-FRAG→MAC-END)
 * und spiegelbildlich zur eigenen UL-Reassembly (tetra_ul_schf_reassembly: FRAG-Payload
 * ab Bit 4, END-Payload ab Bit 10). Jeder Burst ist ein 268-bit SCH/F-Info-Block, der
 * danach via tetra_codec_schf_encode → 432-bit type-5 codiert + pro Frame gepusht wird.
 */
#ifndef TETRA_SDS_DL_FRAG_H
#define TETRA_SDS_DL_FRAG_H

#include <stdint.h>

#define SDS_DL_FRAG_MAX     8     /* max Fragmente (≈ 8×33 oct >> jede SDS) */
#define SCHF_INFO_BITS      268   /* SCH/F Info-Bits je Burst */
#define SCHF_INFO_BYTES     34    /* ceil(268/8) */

typedef struct {
    /* je Fragment: 268-bit SCH/F-Info, MSB-first gepackt (info[0] bit7 = on-air bit 0) */
    uint8_t info[SDS_DL_FRAG_MAX][SCHF_INFO_BYTES];
    int     n;                    /* Anzahl Fragmente (0 = Fehler/zu lang) */
} sds_dl_frag_t;

/* Baut die Fragment-Kette für eine lange D-SDS-DATA.
 *   dest_ssi    Ziel-MS (Empfänger)
 *   calling_ssi ursprünglicher Absender (calling_party_ssi)
 *   ns, nr      LLC BL-ADATA Sequenznummern (DL-Link zum Ziel-MS)
 *   udd         UDD-4 Payload (PID + SDS-TL-Header + 8-bit Text)
 *   udd_len     UDD-Länge in Oktetten (typ. 25..~120)
 *   out         Ergebnis-Kette
 * Rückgabe: Anzahl Fragmente (>0) oder 0 bei Fehler. */
int tetra_sds_dl_build_fragments(uint32_t dest_ssi, uint32_t calling_ssi,
                                 uint8_t ns, uint8_t nr,
                                 const uint8_t *udd, int udd_len,
                                 sds_dl_frag_t *out);

/* Baut die AL-SETUP + Slot-Grant MAC-RESOURCE an dest_ssi (Empfänger) als 268-bit
 * SCH/F-Info-Block (MSB-first gepackt). Weist dem Empfänger nach der Zustellung einen
 * UL-Subslot zu, damit er seinen SDS-TL-Delivery-Report senden kann. Bit-exakt zum
 * Gold dl_ref.log #822: slot_granting_flag=1, sg_element=0x00, LLC AL-SETUP, LI=7.
 * blk muss SCHF_INFO_BYTES (34) groß sein. */
void tetra_sds_dl_build_slotgrant(uint32_t dest_ssi, uint8_t *blk);

#endif /* TETRA_SDS_DL_FRAG_H */
