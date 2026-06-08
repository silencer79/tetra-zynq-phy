/*
 * tetra_attach_daemon.c — Phase X.3 SW-pulled D-LOC-UPDATE-ACCEPT builder
 *
 * Polls the AXI Demand-Push mailbox (Phase X.1, 0x200..0x20C) for a fresh
 * UL-Demand snapshot; when one lands, looks the demanding ISSI up in the
 * SW-resident entity DB (sw/tetra_db.[ch]), applies REG_DB_POLICY auto-
 * enroll bits, picks a Profile, and stages the resulting D-LOC-UPDATE-
 * ACCEPT body in the AXI Reply-Pull mailbox (Phase X.2, 0x220..0x230).
 * Then ACKs the demand snapshot to release the HW slot for the next push.
 *
 * Phase X.3 changes vs. X.2:
 * - Replaces the fixed M2 replica with DB lookup (tetra_db_lookup +
 * tetra_db_profile).
 * - Honors REG_DB_POLICY bit 0 (accept_unknown_issi) and bit 1
 * (accept_unknown_gssi) for auto-enroll.
 * - Reads up to 3 GSSI-wishes from Demand W3..W5 and mirrors the first
 * accepted one into GILA (otherwise falls back to profile-default GSSI
 * = MTP3550 baseline 0x2F4D61).
 * - Re-loads /root/db.tsv whenever its mtime changes (Web-UI live edits).
 *
 * M2 bit-identity guarantee: with the default db.tsv (slot 0 = MTP3550
 * ISSI, slot 1 = Default-Group GSSI 0x2F4D61, profile 0 = 0x0000_088F)
 * the staged body is byte-for-byte identical to the X.2 fixed replica.
 *
 * Target: LibreSDR (Zynq-7020), armv7l, gcc cross-compile
 * License: GPL v2
 */

#include "tetra_hal.h"
#include "tetra_db.h"
#include "tetra_tx_transport.h"
#include "tetra_ul_long_sds.h"
#include "tetra_cmce_parser.h"
#include "tetra_call_fsm.h"
#include "tetra_mm_demand_parser.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <fcntl.h>
#include <sys/mman.h>

/* Local copies of HAL init/close so this tool is self-contained (tetra_hal.c
 * carries main() and can't be linked in without pulling in the sysinfo app).
 * Names match the extern declarations in tetra_hal.h. */
int tetra_hal_init(tetra_hal_t *hal)
{
 hal->fd = open("/dev/mem", O_RDWR | O_SYNC);
 if (hal->fd < 0) { perror("open /dev/mem"); return -1; }
 hal->regs = mmap(NULL, TETRA_AXI_SIZE, PROT_READ | PROT_WRITE,
 MAP_SHARED, hal->fd, TETRA_AXI_BASE);
 if (hal->regs == MAP_FAILED) { perror("mmap"); close(hal->fd); return -1; }
 return 0;
}

void tetra_hal_close(tetra_hal_t *hal)
{
 if (hal->regs && hal->regs != MAP_FAILED)
 munmap((void *)hal->regs, TETRA_AXI_SIZE);
 if (hal->fd >= 0) close(hal->fd);
}

/* Hard-coded ref defaults (M2 bit-identity guard). These match what
 * the existing FPGA MLE-FSM produces for the Profile-0 + GSSI=0x2F4D61
 * baseline; SW just mirrors them so flipping use_sw_body in a live test
 * does NOT change the on-air ACCEPT bytes.
 *
 * GILA_GSSI is the *fallback* used only when:
 * - the demanding MS sent zero GSSI-wishes, AND
 * - the matched ISSI's profile has no default-GSSI association in db.tsv. */
#define M2_DEFAULT_LA 0x0042u
#define M2_DEFAULT_ADDR_TYPE 0x1u /* ETSI Ssi+EventLabel */
#define M2_DEFAULT_RESULT_OK 0x0u /* accept */
#define M2_DEFAULT_RESULT_TEMP 0x1u /* reject-temp (ITSI not allowed) */
#define M2_FALLBACK_GILA_GSSI 0x2F4D61u
#define M2_DEFAULT_GILA_PRESENT 0x1u
#define M2_DEFAULT_ENCRYPTION 0x0u
#define M2_DEFAULT_AUTH_RESULT 0x1u

#define POLL_INTERVAL_MS 10 /* polling loop pacing */
#define DB_RELOAD_INTERVAL_MS 5000 /* mtime check cadence */

static volatile int keep_running = 1;

static void on_sigint(int sig)
{
 (void)sig;
 keep_running = 0;
}

/* Phase 1A — raw-body Mailbox (parallel zum RTL-Parser). */
static uint32_t uldbod_read(tetra_hal_t *hal, uint32_t idx)
{
 tetra_reg_write(hal, REG_UL_DEMAND_BODY_INDEX, idx);
 return tetra_reg_read(hal, REG_UL_DEMAND_BODY_DATA);
}

/* Unpack the Phase-G.x 0x250 mailbox layout: W0=meta[12:0], W1=ssi,
 * W2..W6=body[146:0] (147-bit TM-SDU, MSB-first, on-air position 0 = the
 * first LLC-header bit = block-bit 30). W2=[146:115] W3=[114:83] W4=[82:51]
 * W5=[50:19] W6[18:0]=[18:0]; on-air position p = body[146-p]. */
static void uldbod_unpack(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3,
 uint32_t w4, uint32_t w5, uint32_t w6,
 uint8_t body[19], uint16_t *meta, uint32_t *ssi)
{
 int p;
 *meta = (uint16_t)(w0 & 0x1FFFu);
 *ssi = w1 & 0x00FFFFFFu;
 memset(body, 0, 19);
 for (p = 0; p < 147; p++) {
 uint32_t w; int bi;
 if (p < 32) { w = w2; bi = 31 - p; }
 else if (p < 64) { w = w3; bi = 63 - p; }
 else if (p < 96) { w = w4; bi = 95 - p; }
 else if (p < 128) { w = w5; bi = 127 - p; }
 else { w = w6; bi = 146 - p; } /* 18..0 */
 if ((w >> bi) & 1u) body[p >> 3] |= (uint8_t)(0x80u >> (p & 7));
 }
}

/* Phase 1E-A — service-counter shared between react_mm2_locupd() (called
 * from service_uldbod()) and the legacy main-loop demand branch (drain-
 * only after Phase 1E-A). */
static uint32_t serviced_g = 0;

/* Tiny LLC stop-and-wait NR/NS hash (open-addressing on 24-bit SSI).
 * 64 slots is sufficient — typical cell sees < 10 simultaneously-attaching
 * MS, and slot eviction on collision just resets the alternation (next
 * round NR/NS happen to flip back, MS will retry). Each slot stores
 * {ssi, ns, nr} as a single uint32: [31:8]=ssi, [1]=ns, [0]=nr. */
#define GRP_NSNR_SLOTS 64u
static uint32_t grp_nsnr_table[GRP_NSNR_SLOTS];

static unsigned grp_nsnr_hash(uint32_t ssi)
{
 return ((ssi * 0x9E3779B1u) >> 24) & (GRP_NSNR_SLOTS - 1u);
}

static void grp_nsnr_step(uint32_t ssi, unsigned *out_ns, unsigned *out_nr)
{
 unsigned h = grp_nsnr_hash(ssi);
 unsigned probe;
 for (probe = 0; probe < GRP_NSNR_SLOTS; probe++) {
 unsigned slot = (h + probe) & (GRP_NSNR_SLOTS - 1u);
 uint32_t v = grp_nsnr_table[slot];
 if (v == 0u) {
 /* Fresh slot — first ACK sends NS=0 NR=1 per -Ref
 * `removed-memory` (GS#1 NR=1 NS=0
 * mit alterning Pattern). Vorher war Initial-State NS=1 NR=0
 * → entspricht -GS#2-Pattern statt -GS#1. */
 grp_nsnr_table[slot] = (ssi << 8) | 0x1u; /* ns=0 nr=1 */
 *out_ns = 0u;
 *out_nr = 1u;
 return;
 }
 if ((v >> 8) == ssi) {
 unsigned ns = (v >> 1) & 0x1u;
 unsigned nr = (v >> 0) & 0x1u;
 *out_ns = ns;
 *out_nr = nr;
 /* alternate for next round */
 grp_nsnr_table[slot] = (ssi << 8) | (((~ns) & 0x1u) << 1)
 | (((~nr) & 0x1u) << 0);
 return;
 }
 }
 /* table full — fall back to fixed NS=1 NR=0 */
 *out_ns = 1u;
 *out_nr = 0u;
}

/* Forward declarations for Walker-driven reaction (Phase 1E-A). */
static void react_mm2_locupd(tetra_hal_t *hal,
                              const tetra_mm_demand_parsed_t *p);
static void react_mm7_grpid(tetra_hal_t *hal,
                             const tetra_mm_demand_parsed_t *p);

/* Phase 1C — service one raw-body demand snapshot. Liest die 8 Words aus
 * REG_UL_DEMAND_BODY_*, unpackt zu 17-byte MSB-first Body, walked via
 * tetra_mm_demand_parser (SW-Port von tetra_ul_demand_ie_parser.v),
 * loggt das Ergebnis und ACKt die Snapshot.
 *
 * Parallel-Modus: läuft NEBEN dem existing RTL-Parser-Pfad (service_demand
 * + service_grp_demand). Output dient als A/B-Vergleich gegen die RTL-
 * Parser-Ausgabe via die parsed-Snapshot-Mailboxen. Bei Bit-Equivalenz
 * (= alle Felder identisch über ≥10 PTT-Cycles + Group-Attaches) wird
 * Phase 1E den RTL-Parser entfernen. */
/* ---- Stage 2 — decode a reassembled CMCE U-SDS-DATA from the 0x250 body ----
 * The body now starts at the LLC header (block-bit 30 = tl_sdu_start) and the
 * 0x250 mailbox carries a 13-bit meta bundle. We derive the CMCE PDU offset
 * (cmce_start = (opt?6:0) + llc_hdr_len + MLE-PD(3)) from meta and parse the
 * exact U-SDS-DATA layout (pdu_type=15, area_selection(4), cpti, addr, sdti,
 * li, udd) per bluestation u_sds_data.rs — no fixed-offset guessing. */
static int sds_gbit(const uint8_t *b, int p) { return (b[p>>3] >> (7-(p&7))) & 1; }
static uint32_t sds_gbits(const uint8_t *b, int pos, int n)
{
 uint32_t v = 0; int i;
 for (i = 0; i < n; i++) v = (v << 1) | (uint32_t)sds_gbit(b, pos + i);
 return v;
}
static int decode_sds_reassembled(const uint8_t *body, int nbits, uint16_t meta,
 uint32_t *dest_ssi, uint8_t *proto, uint16_t *li, char *text, int tcap,
 uint8_t *raw_udd, int raw_udd_cap, int *raw_udd_len)
{
 /* meta[12:0]: [12:9]mm_type [8:6]mle_disc [5:2]llc_pdu_type [1]ns [0]opt. */
 uint8_t mle_disc = (uint8_t)((meta >> 6) & 0x7);
 uint8_t llc_pt = (uint8_t)((meta >> 2) & 0xF);
 uint8_t opt = (uint8_t)(meta & 0x1);
 if (mle_disc != 2u) return 0; /* only CMCE (MLE-PD=2) carries SDS */
 /* LLC header length: BL-ADATA(0)=6, BL-DATA(1)=5, BL-UDATA(2)=4 bits. */
 int llc_hdr = (llc_pt == 0) ? 6 : (llc_pt == 1) ? 5 : (llc_pt == 2) ? 4 : 5;
 int pos = (opt ? 6 : 0) + llc_hdr + 3; /* LLC + MLE-PD(3) → CMCE PDU start */
 if (pos + 9 > nbits) return 0;
 if (sds_gbits(body, pos, 5) != 15u) return 0; /* CMCE pdu_type = U-SDS-DATA */
 pos += 5 + 4; /* pdu_type(5) + area_selection(4) */
 uint8_t cpti = (uint8_t)sds_gbits(body, pos, 2); pos += 2;
 if (cpti == 1 || cpti == 2) { *dest_ssi = sds_gbits(body, pos, 24); pos += 24; }
 else if (cpti == 0) { *dest_ssi = sds_gbits(body, pos, 8); pos += 8; }
 else return 0;
 if (cpti == 2) pos += 24; /* TSI extension */
 uint8_t sdti = (uint8_t)sds_gbits(body, pos, 2); pos += 2;
 if (sdti != 3) return 0; /* only SDTI=3 (UDD-4 / text) for now */
 *li = (uint16_t)sds_gbits(body, pos, 11); pos += 11;
 if (*li < 8 || *li > 2047) return 0;
 if (pos + 8 > nbits) return 0;
 *proto = (uint8_t)sds_gbits(body, pos, 8);
 /* gate on a known SDS protocol id so a real MM body isn't mis-read as SDS */
 if (!(*proto==2 || *proto==3 || *proto==9 || *proto==10 ||
 *proto==130 || *proto==131 || *proto==137 || *proto==138)) return 0;
 /* raw UDD-4 octets (PID + SDS-TL header + text) for 1:1 relay forwarding */
 if (raw_udd != NULL && raw_udd_len != NULL) {
 int u_oct = (int)(*li) / 8, ri = 0, j;
 for (j = 0; j < u_oct && ri < raw_udd_cap && (pos + j*8 + 8) <= nbits; j++)
 raw_udd[ri++] = (uint8_t)sds_gbits(body, pos + j*8, 8);
 *raw_udd_len = ri;
 }
 /* extract printable 8-bit text from the UDD, trimming leading/trailing
  * non-printable SDS-TL header octets. */
 int tstart = pos + 8, n_oct = (*li - 8) / 8, ti = 0, started = 0, k;
 for (k = 0; k < n_oct && ti < tcap-1 && (tstart + k*8 + 8) <= nbits; k++) {
 int c = (int)sds_gbits(body, tstart + k*8, 8);
 int pr = (c >= 32 && c < 127);
 if (!started && !pr) continue;
 started = 1;
 text[ti++] = pr ? (char)c : '.';
 }
 while (ti > 0 && text[ti-1] == '.') ti--;
 text[ti] = 0;
 return 1;
}

/* Operator-getriggertes DL-SDS: pollt /tmp/sds_out (eine Zeile
 * "<dest_ssi> <from_ssi> <text>"; SSI dezimal oder 0xhex), baut eine
 * D-SDS-DATA (SDS-TL Text, PID 0x82) und sendet sie an die Ziel-MS. Datei
 * wird nach dem Lesen entfernt. Trigger z.B.:
 *   ssh root@board "echo '0x282F91 0x282FF4 Hallo' > /tmp/sds_out" */
static void service_sds_outbox(tetra_hal_t *hal)
{
 static uint8_t sds_ref = 1;
 FILE *f = fopen("/tmp/sds_out", "r");
 if (f == NULL) return;
 char line[256];
 char *got = fgets(line, sizeof(line), f);
 fclose(f);
 remove("/tmp/sds_out");
 if (got == NULL) return;
 long dest = 0, from = 0; int adv = 0;
 if (sscanf(line, "%li %li %n", &dest, &from, &adv) < 2 || adv == 0) {
 fprintf(stderr, "tetra_attach_daemon: SDS-OUT parse error\n");
 return;
 }
 char *text = line + adv;
 size_t tl = strlen(text);
 while (tl > 0 && (text[tl-1] == '\n' || text[tl-1] == '\r')) text[--tl] = 0;
 if (tl == 0 || tl > 20) {
 fprintf(stderr, "tetra_attach_daemon: SDS-OUT bad text len %zu (1..20)\n", tl);
 return;
 }
 tx_pdu_meta_t meta;
 memset(&meta, 0, sizeof(meta));
 meta.target_ssi = (uint32_t)dest;
 meta.cmce.calling_party_ssi = (uint32_t)from;
 /* UDD-4: PID 0x82 (SDS-TL text) + SDS-TL header (msg-type/flags + ref,
  * spiegelt das beobachtete MS-Format) + 8-bit Text. */
 meta.cmce.sds_udd[0] = 0x82;
 meta.cmce.sds_udd[1] = 0x04;
 meta.cmce.sds_udd[2] = 0x04;
 meta.cmce.sds_udd[3] = sds_ref++;
 memcpy(&meta.cmce.sds_udd[4], text, tl);
 meta.cmce.sds_udd_len = (uint16_t)(4 + tl);
 int rc = tetra_tx_submit(hal, TX_D_SDS_DATA, &meta);
 printf("SDS-OUT: to=0x%06lX from=0x%06lX rc=%d text=\"%s\"\n",
 (unsigned long)dest, (unsigned long)from, rc, text);
 fflush(stdout);
}

static void service_uldbod(tetra_hal_t *hal)
{
 uint32_t w0 = uldbod_read(hal, 0);  /* magic + meta[12:0] */
 uint32_t w1 = uldbod_read(hal, 1);  /* ssi */
 uint32_t w2 = uldbod_read(hal, 2);  /* body[146:115] */
 uint32_t w3 = uldbod_read(hal, 3);  /* body[114:83] */
 uint32_t w4 = uldbod_read(hal, 4);  /* body[82:51] */
 uint32_t w5 = uldbod_read(hal, 5);  /* body[50:19] */
 uint32_t w6 = uldbod_read(hal, 6);  /* body[18:0] */

 uint8_t nbody[19];          /* 147-bit TM-SDU, on-air pos 0 = LLC header */
 uint16_t meta;
 uint32_t pdu_ssi;
 uldbod_unpack(w0, w1, w2, w3, w4, w5, w6, nbody, &meta, &pdu_ssi);
 uint8_t mm_type = (uint8_t)((meta >> 9) & 0xF);

 /* Stage 2 — a reassembled CMCE U-SDS-DATA lands here too; the RTL
  * mis-tags it with an MM pdu_type. Decode as SDS first; only fall
  * through to the MM walker when it is not a plausible U-SDS-DATA. */
 {
 uint32_t sds_dest = 0; uint8_t sds_proto = 0; uint16_t sds_li = 0;
 char sds_text[64];
 uint8_t sds_udd[48]; int sds_udd_len = 0;
 if (decode_sds_reassembled(nbody, 147, meta,
 &sds_dest, &sds_proto, &sds_li, sds_text, (int)sizeof(sds_text),
 sds_udd, (int)sizeof(sds_udd), &sds_udd_len)) {
 printf("SDS-TEXT from=0x%06X to=0x%06X proto=%u len=%ubit udd=",
 pdu_ssi, sds_dest, sds_proto, sds_li);
 { int z; for (z = 0; z < sds_udd_len; z++) printf("%02X", sds_udd[z]); }
 printf(" text=\"%s\"\n", sds_text);
 /* LLC-Zustellquittung an den SDS-Absender — Gold DL #425 sendet die
  * BL-ACK VOR dem Relay. NR = empfangene LLC-NS (meta[1]). Ohne diese
  * Schicht-2-Quittung retransmittiert das Sende-MS → Fehlermeldung. */
 {
 tx_pdu_meta_t ack;
 memset(&ack, 0, sizeof(ack));
 ack.target_ssi = pdu_ssi;
 ack.nr = (uint8_t)((meta >> 1) & 1u); /* NR = received NS */
 int ack_rc = tetra_tx_submit(hal, TX_BL_ACK, &ack);
 printf("SDS-BL-ACK: -> 0x%06X nr=%u rc=%d\n", pdu_ssi, ack.nr, ack_rc);
 }
 /* SDS-Relay (BlueStation route_rf_deliver): an die Ziel-MS
  * weiterleiten, wenn lokal als ISSI registriert. UDD (Text bzw.
  * SDS-TL-Report von der Gegenseite) wird 1:1 in eine D-SDS-DATA
  * verpackt → Zustellung + Quittungsfluss laufen über die BS. */
 if (sds_udd_len > 0 && sds_udd_len <= 24 &&
 tetra_db_lookup(sds_dest, 0u, NULL)) {
 tx_pdu_meta_t rm;
 memset(&rm, 0, sizeof(rm));
 rm.target_ssi = sds_dest;
 rm.cmce.calling_party_ssi = pdu_ssi;
 memcpy(rm.cmce.sds_udd, sds_udd, (size_t)sds_udd_len);
 rm.cmce.sds_udd_len = (uint16_t)sds_udd_len;
 int rrc = tetra_tx_submit(hal, TX_D_SDS_DATA, &rm);
 printf("SDS-RELAY: 0x%06X -> 0x%06X (%d oct) rc=%d\n",
 pdu_ssi, sds_dest, sds_udd_len, rrc);
 } else {
 printf("SDS-RELAY: skip dest=0x%06X (registered=%d udd=%d oct)\n",
 sds_dest, tetra_db_lookup(sds_dest, 0u, NULL), sds_udd_len);
 }
 fflush(stdout);
 tetra_reg_write(hal, REG_UL_DEMAND_BODY_ACK, 0x1u);
 return;
 }
 }

 /* MM walker: feed it the old block-bit-48 MM-body start, which now sits at
  * on-air position 18 of the LLC-aligned body — bit-identical to pre-G.x. */
 uint8_t mmbody[TETRA_MM_DEMAND_BODY_BYTES];
 { int i; memset(mmbody, 0, sizeof(mmbody));
 for (i = 0; i < TETRA_MM_DEMAND_BODY_BYTES * 8 && (18 + i) < 147; i++)
 if (sds_gbit(nbody, 18 + i))
 mmbody[i >> 3] |= (uint8_t)(0x80u >> (i & 7));
 }
 tetra_mm_demand_parsed_t p;
 int rc = tetra_mm_demand_parser_parse(mmbody, mm_type, pdu_ssi, &p);

 if (rc == 0 && p.parse_ok && mm_type == 2) {
 fprintf(stderr,
 "tetra_attach_daemon: [SW-WALK mm=2] ssi=0x%06X LUT=%u ra=%u cc=%u "
 "class_valid=%u esm_valid=%u la_valid=%u la=0x%04X ssi_valid=%u "
 "ae_valid=%u gild_valid=%u gild_gssi=0x%06X gild_at=%u\n",
 p.pdu_ssi, p.location_update_type, p.request_to_append_la,
 p.cipher_control, p.class_of_ms_valid, p.energy_saving_mode_valid,
 p.la_information_valid, p.la_information, p.ssi_field_valid,
 p.address_ext_valid, p.gild_valid, p.gild_gssi, p.gild_address_type);
 } else if (rc == 0 && p.parse_ok && mm_type == 7) {
 fprintf(stderr,
 "tetra_attach_daemon: [SW-WALK mm=7] ssi=0x%06X gir=%u atd=%u count=%u",
 p.pdu_ssi, p.gid_group_identity_report,
 p.gid_attach_detach_mode, p.gid_count);
 for (int r = 0; r < p.gid_count && r < 3; r++) {
 fprintf(stderr, " rec%d{adi=%u cou=%u at=%u gssi=0x%06X}", r,
 p.gid_records[r].attach_detach,
 p.gid_records[r].class_of_usage,
 p.gid_records[r].address_type,
 p.gid_records[r].gssi);
 }
 fprintf(stderr, "\n");
 } else {
 fprintf(stderr,
 "tetra_attach_daemon: [SW-WALK FAIL] mm=%u ssi=0x%06X rc=%d parse_ok=%u\n",
 mm_type, pdu_ssi, rc, p.parse_ok);
 }

 /* Phase 1E-A — react aus Walker-Output. Replaced RTL-mailbox-getriebene
  * Reaktion in service_demand / service_grp_demand. Beide RTL-Mailboxen
  * werden im main-loop nur noch ge-drained (ACK ohne Aktion), bis Phase
  * 1E-B den RTL-Parser + die Mailboxen physisch entfernt. */
 if (rc == 0 && p.parse_ok) {
 if (mm_type == 2u) {
 react_mm2_locupd(hal, &p);
 } else if (mm_type == 7u) {
 react_mm7_grpid(hal, &p);
 }
 }

 /* ACK clears pending + arms next */
 tetra_reg_write(hal, REG_UL_DEMAND_BODY_ACK, 0x1u);
}

/* Phase 1E-A — react to a Group-Attach (mm=7) demand parsed by the SW
 * walker. Build the D-ATTACH-DETACH-GRP-ID-ACK reply, stage it into the
 * Group-Reply mailbox. The raw-body mailbox snapshot is ACKed by the
 * caller (service_uldbod). */
static void react_mm7_grpid(tetra_hal_t *hal,
                            const tetra_mm_demand_parsed_t *p)
{
 uint32_t cnt = p->gid_count;
 uint32_t atd = p->gid_attach_detach_mode;
 uint32_t rep = p->gid_group_identity_report;
 uint32_t ssi = p->pdu_ssi;
 uint32_t gssi[3] = { p->gid_records[0].gssi,
                      p->gid_records[1].gssi,
                      p->gid_records[2].gssi };

 uint32_t policy = tetra_reg_read(hal, REG_DB_POLICY);
 int allow_gssi = (policy & DB_POLICY_ACCEPT_UNKNOWN_GSSI) != 0;

 /* Build per-record reply: at=0 GSSI-only, lifetime=1 (default), class
 * carried through from MS request when known, otherwise default 4. */
 uint32_t reply_gssi[3] = {0, 0, 0};
 uint32_t reply_at[3] = {0, 0, 0};
 uint32_t reply_lt[3] = {0, 0, 0};
 uint32_t reply_adi[3] = {0, 0, 0};
 uint32_t reply_cls[3] = {0, 0, 0};
 uint32_t reply_count = 0;

 uint32_t actual_count = (cnt > 3u) ? 3u: cnt;
 for (uint32_t i = 0; i < actual_count; i++) {
 if (gssi[i] == 0u) continue;
 /* Pattern: BS echoed nur ATTACH-Records (adi=0). Memory
 * `removed-memory` F4: "BS akzeptiert
 * Attach <gssi>. Der Detach-Record aus dem Demand wird stillschweigend
 * übergangen." Filter DETACH-Records hier raus, sonst landet ein
 * 95-bit-2-Record-Body on-air statt 64-bit-1-Record. */
 if (p->gid_records[i].attach_detach != 0u) continue;
 int hit = tetra_db_lookup(gssi[i], 1, NULL);
 if (!hit && allow_gssi) {
 int slot = tetra_db_alloc(gssi[i], 1, 0);
 if (slot >= 0) {
 fprintf(stderr,
 "tetra_attach_daemon: GRP autoenroll gssi=0x%06X "
 "slot=%d\n", gssi[i], slot);
 hit = 1;
 }
 }
 if (hit) {
 unsigned cls_in = p->gid_records[i].class_of_usage;
 unsigned adi_in = p->gid_records[i].attach_detach;
 unsigned at_in  = p->gid_records[i].address_type;
 reply_gssi[reply_count] = gssi[i];
 reply_at [reply_count] = at_in;
 reply_lt [reply_count] = 1u; /* default lifetime */
 reply_adi [reply_count] = adi_in;
 reply_cls [reply_count] = cls_in ? cls_in: 4u;
 reply_count++;
 }
 }

 /* Sprint B (2026-05-04): status-query branch is a COMPLETE SKIP.
 *
 * When MS sends cnt=0 + rep=1 + atd=0 (= group_identity_report=1 with no
 * GIU records), it is asking the BS which groups it is currently
 * registered to. Memory `removed-memory`
 * F7 documents that **-MS NEVER sends status-query in the reference
 * capture** — all real demands carry cnt=2 (detach old + attach new).
 *
 * Empirical: when our daemon answered status-queries with 3 GSSIs from
 * db.tsv, MTP3550 concluded "I am already in groups → no switch needed"
 * and stopped initiating real Group-Switch.
 *
 * Cure: ACK the demand snapshot (release the HW slot) but do NOT stage a
 * reply and do NOT pulse GO. MS sees no DL response, falls back to
 * "I'm in no groups", and triggers a real Group-Attach. This is also
 * the spec-conformant behaviour — simply never produces a reply
 * because -MS never sends the request. */
 if (cnt == 0u && rep == 1u && atd == 0u) {
 fprintf(stderr,
 "tetra_attach_daemon: GRP status-query (ssi=0x%06X) → "
 "skip (spec-conformant)\n", ssi);
 return;
 }

 /* Wenn keine GSSI passt: stillschweigend verwerfen. Encoder ist
  * Fixed-1-Record-only (spec-konform), variable Längen sind nicht
  * zulässig. */
 if (reply_count == 0u) {
 fprintf(stderr,
 "tetra_attach_daemon: GRP no-match ssi=0x%06X cnt=%u atd=%u "
 "rep=%u → skip (no GSSI-hit)\n", ssi, cnt, atd, rep);
 return;
 }

 unsigned ns = 0u, nr = 0u;
 grp_nsnr_step(ssi, &ns, &nr);

 tx_pdu_meta_t meta = {0};
 meta.target_ssi = ssi;
 meta.accept_reject = 0u;
 meta.reply_count = (uint8_t)reply_count;
 meta.ns = (uint8_t)ns;
 meta.nr = (uint8_t)nr;
 for (unsigned i = 0; i < 3; i++) {
 meta.gssi[i] = reply_gssi[i];
 meta.at[i] = (uint8_t)reply_at[i];
 meta.lifetime[i] = (uint8_t)reply_lt[i];
 meta.adi[i] = (uint8_t)reply_adi[i];
 meta.cls[i] = (uint8_t)reply_cls[i];
 }
 tetra_tx_submit(hal, TX_GRP_ATTACH_ACK, &meta);

 fprintf(stderr,
 "tetra_attach_daemon: GRP serviced ssi=0x%06X cnt=%u atd=%u "
 "rep=%u → reply_cnt=%u ns=%u nr=%u policy=0x%X\n",
 ssi, cnt, atd, rep, reply_count, ns, nr, policy);
}

/* Stage one body in the Reply mailbox via tetra_tx_transport. */
static void stage_accept_body(tetra_hal_t *hal,
 uint32_t ssi,
 uint32_t la,
 uint32_t result,
 uint32_t loc_acc_type,
 uint32_t gila_gssi,
 uint32_t gila_class,
 uint32_t gila_lifetime,
 uint32_t gila_present)
{
 tx_pdu_meta_t meta = {0};
 meta.target_ssi = ssi;
 meta.la = (uint16_t)la;
 meta.result = (uint8_t)result;
 /* Bug-001 fix — echo MS demand location_update_type (ETSI §16.10.35a). */
 meta.loc_acc_type = (uint8_t)(loc_acc_type & 0x7u);
 meta.gila_gssi = gila_gssi;
 meta.gila_class = (uint8_t)gila_class;
 meta.gila_lifetime = (uint8_t)gila_lifetime;
 meta.gila_present = (uint8_t)gila_present;
 meta.encryption = M2_DEFAULT_ENCRYPTION;
 meta.auth_result = M2_DEFAULT_AUTH_RESULT;

 tx_pdu_class_t cls = (result == M2_DEFAULT_RESULT_OK) ? TX_LU_ACCEPT
: TX_LU_REJECT;
 tetra_tx_submit(hal, cls, &meta);

 /* Phase Z.5 — TX_LU_REJECT now drives the dedicated mm=4 D-LOC-UPDATE-
 * REJECT path inside the MLE-FSM (8-bit MM body, SCH/HD blk1 per
 * PDUC_FINAL_LU_REJECT_FMT). The mailbox W3 result bit selects the
 * ACCEPT vs REJECT branch; W4..W6 (GILA) are ignored for REJECT.
 *
 * mb_result -> ETSI Table 16.43 reject_cause mapping (RTL-side):
 * 1 (reject-temp) -> 3'd2 "no resources available"
 * 2 (reject-perm) -> 3'd1 "illegal MS"
 */
}

/* Phase 1E-A — react to a U-LOCATION-UPDATE-DEMAND (mm=2) parsed by the
 * SW walker. Performs DB lookup / auto-enroll, builds the LU-ACCEPT /
 * LU-REJECT body via stage_accept_body(). The raw-body mailbox snapshot
 * is ACKed by the caller (service_uldbod). */
static void react_mm2_locupd(tetra_hal_t *hal,
                              const tetra_mm_demand_parsed_t *p)
{
 uint32_t ssi = p->pdu_ssi;
 uint32_t la  = tetra_reg_read(hal, REG_CELL_LA) & 0x3FFFu;
 uint32_t lut = p->location_update_type;
 uint32_t cnt = p->gild_valid ? 1u : 0u;
 uint32_t gssi[3] = { p->gild_gssi, 0u, 0u };

 uint32_t policy = tetra_reg_read(hal, REG_DB_POLICY);
 int allow_issi = (policy & DB_POLICY_ACCEPT_UNKNOWN_ISSI) != 0;
 int allow_gssi = (policy & DB_POLICY_ACCEPT_UNKNOWN_GSSI) != 0;

 tetra_db_entry_t entry;
 int issi_hit = tetra_db_lookup(ssi, 0, &entry);
 int issi_enrolled = 0;
 uint32_t result = M2_DEFAULT_RESULT_OK;
 uint8_t profile_id = 0;

 if (issi_hit) {
 profile_id = entry.profile_id;
 } else if (allow_issi) {
 int slot = tetra_db_alloc(ssi, 0, 0);
 if (slot >= 0) {
 profile_id = 0;
 issi_enrolled = 1;
 fprintf(stderr,
 "tetra_attach_daemon: AUTOENROLL issi=0x%06X "
 "slot=%d profile=0\n", ssi, slot);
 } else {
 result = M2_DEFAULT_RESULT_TEMP;
 fprintf(stderr,
 "tetra_attach_daemon: AUTOENROLL FAILED ssi=0x%06X "
 "(DB full?) — reject-temp\n", ssi);
 }
 } else {
 result = M2_DEFAULT_RESULT_TEMP;
 fprintf(stderr,
 "tetra_attach_daemon: ISSI 0x%06X miss + accept_unknown_issi=0 "
 "— reject-temp\n", ssi);
 }

 const tetra_db_profile_t *pp = tetra_db_profile(profile_id);
 uint32_t gila_class    = pp ? pp->gila_class    : 4u;
 uint32_t gila_lifetime = pp ? pp->gila_lifetime : 1u;
 uint32_t gila_present  = M2_DEFAULT_GILA_PRESENT;

 uint32_t effective_gila_gssi = M2_FALLBACK_GILA_GSSI;
 uint32_t actual_count = (cnt > 3u) ? 3u : cnt;
 int gssi_resolved = 0;

 for (uint32_t i = 0; i < actual_count && !gssi_resolved; i++) {
 if (gssi[i] == 0u) continue;
 if (tetra_db_lookup(gssi[i], 1, NULL)) {
 effective_gila_gssi = gssi[i];
 gssi_resolved = 1;
 } else if (allow_gssi) {
 int slot = tetra_db_alloc(gssi[i], 1, 0);
 if (slot >= 0) {
 effective_gila_gssi = gssi[i];
 gssi_resolved = 1;
 fprintf(stderr,
 "tetra_attach_daemon: AUTOENROLL gssi=0x%06X "
 "slot=%d profile=0\n", gssi[i], slot);
 }
 }
 }

 if (result != M2_DEFAULT_RESULT_OK) {
 gila_present = 0;
 effective_gila_gssi = 0;
 gila_class = 0;
 gila_lifetime = 0;
 }

 stage_accept_body(hal, ssi, la, result, lut,
                   effective_gila_gssi,
                   gila_class, gila_lifetime, gila_present);

 serviced_g++;
 fprintf(stderr,
 "tetra_attach_daemon: serviced #%u — ssi=0x%06X la=0x%04X "
 "lut=%u cnt=%u policy=0x%X result=%u gila_gssi=0x%06X "
 "(profile=%u, %s%s%s)\n",
 serviced_g, ssi, la, lut, cnt, policy, result,
 effective_gila_gssi, profile_id,
 issi_hit ? "issi=hit":
 (issi_enrolled ? "issi=auto": "issi=reject"),
 (gssi_resolved && cnt > 0u) ? ", gssi=hit":
 ((cnt > 0u) ? ", gssi=fallback": ", gssi=none"),
 "");
}

static void usage(const char *a0)
{
 fprintf(stderr,
 "Usage: %s [--db-path PATH]\n"
 " Default DB path: %s\n",
 a0, TETRA_DB_DEFAULT_PATH);
}

/* ---- Lange SDS (Multi-Fragment, SCH/F) — komplementär zum Voice-Pfad ----
 * (a) MAC-ACCESS(frag=1) auf 0x164 startet eine Kette (TM-SDU-Anfang).
 * (b) SCH/F-NUBs (nur wenn kein aktiver Voice-Call → kein Mailbox-Konflikt)
 *     werden kanaldecodiert + angehängt; bei MAC-END → reassembliert + Relay.
 * NUB-Soft-Konvention ist im FPGA invers zu ETSI → beide Vorzeichen probieren. */
static lsds_chain_t g_lsds;

static void service_long_sds(tetra_hal_t *hal)
{
 uint32_t st = tetra_reg_read(hal, REG_UL_PDU_STATUS);
 if (UL_STATUS_VALID(st) && UL_STATUS_PDU_TYPE(st) == 0u && UL_STATUS_FRAG_FLAG(st)) {
 uint32_t r0 = tetra_reg_read(hal, REG_UL_PDU_RAW_0);
 uint32_t r1 = tetra_reg_read(hal, REG_UL_PDU_RAW_1);
 uint32_t r2 = tetra_reg_read(hal, REG_UL_PDU_RAW_2);
 uint8_t raw[92]; int i;
 for (i = 0; i < 32; i++) raw[i] = (uint8_t)((r0 >> (31 - i)) & 1u);
 for (i = 0; i < 32; i++) raw[32 + i] = (uint8_t)((r1 >> (31 - i)) & 1u);
 for (i = 0; i < 28; i++) raw[64 + i] = (uint8_t)((r2 >> (31 - i)) & 1u);
 uint32_t ssi = tetra_reg_read(hal, REG_UL_PDU_SSI) & 0xFFFFFFu;
 /* payload_start (parse_mac_access): 5 + ssi24 + opt1 + lindcap1 + frag1 + resreq4 = 36 */
 tetra_lsds_start(&g_lsds, ssi, raw + 36, 92 - 36);
 tetra_reg_write(hal, REG_UL_PDU_CTRL, 1u); /* clear valid sticky */
 fprintf(stderr, "LONG-SDS: chain start ssi=0x%06X res_req=%u\n",
 ssi, UL_STATUS_RES_REQ(st));
 }

 if (tetra_reg_read(hal, REG_VOICE_ACTIVE_MASK) != 0u) return; /* Voice-Call: NUB gehört voice_pipe */
 if ((tetra_reg_read(hal, REG_VOICE_NUB_READ_STATUS) & 0x1u) == 0u) return;

 int8_t softs[432]; uint8_t hard[432]; int w, n, i, rc;
 for (w = 0; w < 54; w++) {
 tetra_reg_write(hal, REG_VOICE_NUB_READ_INDEX, (uint32_t)w);
 uint32_t word = tetra_reg_read(hal, REG_VOICE_NUB_READ_DATA);
 for (n = 0; n < 8; n++) {
 uint32_t nib = (word >> (n * 4)) & 0xFu;
 int8_t s = (int8_t)((nib & 0x8) ? (int8_t)(nib | 0xF0) : (int8_t)nib);
 int ci = w * 8 + n;
 if (ci < 432) softs[431 - ci] = s;
 }
 }
 tetra_reg_write(hal, REG_VOICE_NUB_READ_ACK, 1u); /* ack + arm next */

 uint8_t cc = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3Fu);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint16_t mcc = (uint16_t)(cfg1 & 0x3FFu);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFFu);

 for (i = 0; i < 432; i++) hard[i] = (softs[i] > 0) ? 1u : 0u; /* FPGA-Konvention */
 rc = tetra_lsds_feed_schf(&g_lsds, hard, cc, 3, mcc, mnc);
 if (rc == 0) { /* CRC-Fail → inverse Vorzeichen-Konvention (ETSI) */
 for (i = 0; i < 432; i++) hard[i] = (softs[i] < 0) ? 1u : 0u;
 rc = tetra_lsds_feed_schf(&g_lsds, hard, cc, 3, mcc, mnc);
 }
 if (rc == 2) { /* Kette komplett → SDS reassembliert */
 uint16_t meta = (uint16_t)((2u << 6) | (1u << 2)); /* mle_disc=CMCE, llc_pt=BL-DATA */
 uint32_t dest = 0; uint8_t proto = 0; uint16_t li = 0;
 char text[256]; uint8_t udd[200]; int udd_len = 0;
 if (decode_sds_reassembled(g_lsds.tm, g_lsds.nbits, meta,
 &dest, &proto, &li, text, (int)sizeof(text),
 udd, (int)sizeof(udd), &udd_len)) {
 printf("LONG-SDS from=0x%06X to=0x%06X proto=%u %dbit/%dfrag text=\"%s\"\n",
 g_lsds.ssi, dest, proto, g_lsds.nbits, g_lsds.nfrag, text);
 } else {
 fprintf(stderr, "LONG-SDS: %dfrag %dbit reassembliert, SDS-Decode meta=0x%X fehlgeschlagen\n",
 g_lsds.nfrag, g_lsds.nbits, meta);
 }
 }
}

int main(int argc, char **argv)
{
 const char *db_path = TETRA_DB_DEFAULT_PATH;

 for (int i = 1; i < argc; i++) {
 if (!strcmp(argv[i], "--db-path") && i + 1 < argc) {
 db_path = argv[++i];
 } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
 usage(argv[0]);
 return 0;
 } else {
 fprintf(stderr, "tetra_attach_daemon: unknown arg '%s'\n", argv[i]);
 usage(argv[0]);
 return 1;
 }
 }

 tetra_hal_t hal;
 if (tetra_hal_init(&hal) != 0) {
 fprintf(stderr, "tetra_attach_daemon: HAL init failed\n");
 return 1;
 }

 signal(SIGINT, on_sigint);
 signal(SIGTERM, on_sigint);

 if (tetra_db_load(db_path) != 0) {
 fprintf(stderr, "tetra_attach_daemon: db_load(%s) failed (%d entries) — "
 "continuing with empty DB\n",
 db_path, tetra_db_count(0) + tetra_db_count(1));
 } else {
 fprintf(stderr, "tetra_attach_daemon: DB loaded from %s — "
 "%u ISSI / %u GSSI entries\n",
 db_path,
 tetra_db_count(0), tetra_db_count(1));
 }

 tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x1u);

 /* MER-Fix: VOICE_ACTIVE_MASK kann von einem vorherigen Call hängen
  * bleiben wenn die MS keinen U-RELEASE sendet (power-cycle, sync-loss,
  * timeout). Mit aktivem mask sendet der Voice-Relay-Pfad in idle-FN
  * Garbage auf der voice-slot TN → SDR# zeigt 8-12% MER. Beim Daemon-
  * Start IMMER auf 0 zurücksetzen damit Idle-Zelle sauberes Signal hat. */
 tetra_reg_write(&hal, REG_VOICE_ACTIVE_MASK, 0x00u);

 /* MER-Fix: UL-NUB-Sync-Schwelle hochsetzen (Default 8/11) so dass
  * Idle-Bursts keine NTS1-False-Positives mehr triggern (FP-Rate ≈
  * 48/s bei 8/11, 0/s bei 10/11 — gemessen 2026-05-16).
  * 2026-05-17 Survey: thresh=11 senkt BFI auf 4.7 % vs 6.1 % bei 10
  * (~22 % rel. Verbesserung, Burst-Rate näher an ETSI 16-18/s);
  * thresh=12 dagegen tot — NUB-Detector lockt nicht mehr. */
 tetra_reg_write(&hal, REG_VOICE_NUB_SYNC_THRESH, 11u);

 fprintf(stderr,
 "tetra_attach_daemon: started — USE_SW=1, polling REG_DEMAND_STATUS, "
 "policy=0x%08X, VOICE_ACTIVE_MASK=0, NUB_SYNC_THRESH=11\n",
 tetra_reg_read(&hal, REG_DB_POLICY));
 fprintf(stderr, "tetra_attach_daemon: W1C-RACE-FIX v2 ACTIVE (build 2026-05-24)\n");

 uint32_t since_reload_ms = 0;
 uint16_t last_ul_count = 0xFFFFu; /* sentinel: first PDU always triggers */

 while (keep_running) {
 /* MER-Fix: Watchdog für hängende VOICE_ACTIVE_MASK. Wenn kein Slot
 * gerade TALKER ist, mask = 0. Wenn ein TALKER über N ms still ist
 * (RF-Drop, MS-Crash), force-fallback nach CONNECTED + mask=0.
 * Wenn ein Slot über N ms gar nichts mehr macht (kein U-RELEASE
 * trotz Power-Cycle), Slot freigeben. */
 tetra_call_fsm_tick(&hal);

 /* Phase 1C — service raw-body Mailbox parallel zu RTL-Parser-Pfaden.
  * Logs SW-Walker-Output für A/B-Vergleich. Wird vor dem
  * RTL-parsed-demand-poll geprüft damit die Reihenfolge im Log
  * konsistent ist (raw → parsed). */
 uint32_t uldbod_status = tetra_reg_read(&hal, REG_UL_DEMAND_BODY_STATUS);
 if (uldbod_status & 0x1u) {
 service_uldbod(&hal);
 }

 /* Lange SDS (Multi-Fragment, SCH/F) — MAC-ACCESS-Start + NUB-Fragmente. */
 service_long_sds(&hal);

 /* Operator-getriggertes DL-SDS aus /tmp/sds_out */
 service_sds_outbox(&hal);

 /* Phase 1E-B (2026-05-20) — RTL-parsed group-demand Mailbox entfernt.
  * Reaktion auf mm=7 läuft komplett aus dem SW-Walker-Pfad
  * (service_uldbod → react_mm7_grpid). */

 /* Phase 7 G.2 — CMCE-Dispatch. We share REG_UL_PDU_STATUS with
 * tetra_ul_mon (which W1Cs the sticky for logging). Instead of
 * racing for the sticky bit we track ul_pdu_count[31:16]: each
 * CRC-OK PDU bumps it, so a count change = unseen PDU. We only
 * act on mle_disc==2 (CMCE); mle_disc==1 (MM) is already handled
 * by the reassembly path below. */
 uint32_t ul_status = tetra_reg_read(&hal, REG_UL_PDU_STATUS);
 /* 2026-05-24 — UL_STATUS_VALID-Gate ENTFERNT (W1C-race-fix v2 ACTIVE). */
 {
 uint16_t ul_count = (uint16_t)UL_STATUS_PDU_COUNT(ul_status);
 if (ul_count != last_ul_count) {
 last_ul_count = ul_count;
 uint32_t s2 = tetra_reg_read(&hal, REG_UL_PDU_STATUS_2);
 if (UL_STATUS2_MLE_DISC(s2) == 2u) {
 uint32_t cmce_ssi = tetra_reg_read(&hal, REG_UL_PDU_SSI)
 & 0x00FFFFFFu;
 uint32_t raw0 = tetra_reg_read(&hal, REG_UL_PDU_RAW_0);
 uint32_t raw1 = tetra_reg_read(&hal, REG_UL_PDU_RAW_1);
 uint32_t raw2 = tetra_reg_read(&hal, REG_UL_PDU_RAW_2)
 & 0x0FFFFFFFu; /* 28 bits valid */
 uint32_t raws[3] = { raw0, raw1, raw2 };

 /* raw_info_bits[91:0] = on-air bit stream stored LSB-first
 * within each 32-bit word. Bit N on-air = raws[N/32] bit
 * (N%32). CMCE PDU starts after MAC-header + LLC-header
 * + 3-bit MLE-PD; offset depends on opt-flag + LLC type. */
 int tl_sdu_start = UL_STATUS_OPT_FLAG(ul_status) ? 36: 30;
 int llc_t = (int)UL_STATUS2_LLC_TYPE(s2);
 int llc_hdr_bits;
 switch (llc_t) {
 case 0x0: llc_hdr_bits = 6; break; /* BL-ADATA */
 case 0x1: llc_hdr_bits = 5; break; /* BL-DATA */
 case 0x3: llc_hdr_bits = 4; break; /* BL-ACK */
 default: llc_hdr_bits = 4; break; /* BL-UDATA */
 }
 int cmce_start = tl_sdu_start + llc_hdr_bits + 3; /* +MLE-PD */
 int cmce_bits = 92 - cmce_start;
 if (cmce_bits > 0) {
 uint8_t body[16];
 memset(body, 0, sizeof(body));
 for (int i = 0; i < cmce_bits; i++) {
 int n = cmce_start + i;
 int b = (int)((raws[n >> 5] >> (n & 31)) & 1u);
 if (b) body[i >> 3] |= (uint8_t)(0x80u >> (i & 7));
 }
 cmce_pdu_t p;
 memset(&p, 0, sizeof(p));
 int rc = tetra_cmce_parse(body, cmce_bits, &p);
 if (rc == 0 && p.pdu_type == CMCE_U_SDS_DATA) {
 /* SDS — surface it; do NOT feed the call-control FSM. When
 * sds_truncated=1 the user data spills into further MAC
 * fragments; full text decode lands with the reassembled-body
 * path (Stage 2). */
 printf("SDS: U-SDS-DATA from=0x%06X area=%u cpti=%u dest=0x%06X "
 "SDTI=%u", cmce_ssi, p.area_selection,
 p.called_party_type_identifier, p.called_party_ssi,
 p.short_data_type_identifier);
 if (p.short_data_type_identifier == 3)
 printf(" len=%ubit proto=%u", p.sds_length_indicator,
 p.sds_protocol_id);
 else if (p.sds_user_data_bits)
 printf(" udd=0x%X(%ubit)", p.sds_user_data,
 p.sds_user_data_bits);
 printf("%s\n", p.sds_truncated ? " [truncated/fragmented]" : "");
 fflush(stdout);
 } else if (rc == 0 && p.pdu_type == CMCE_U_STATUS) {
 /* Status-Message (precoded status) — wie SDS an die adressierte MS
 * als D-STATUS relayen, wenn lokal als ISSI registriert. */
 printf("STATUS: U-STATUS from=0x%06X cpti=%u dest=0x%06X status=0x%04X\n",
 cmce_ssi, p.called_party_type_identifier, p.called_party_ssi,
 p.pre_coded_status);
 if (tetra_db_lookup(p.called_party_ssi, 0u, NULL)) {
 tx_pdu_meta_t sm;
 memset(&sm, 0, sizeof(sm));
 sm.target_ssi = p.called_party_ssi;
 sm.cmce.calling_party_ssi = cmce_ssi;
 sm.cmce.pre_coded_status = p.pre_coded_status;
 int src = tetra_tx_submit(&hal, TX_D_STATUS, &sm);
 printf("STATUS-RELAY: 0x%06X -> 0x%06X status=0x%04X rc=%d\n",
 cmce_ssi, p.called_party_ssi, p.pre_coded_status, src);
 }
 fflush(stdout);
 } else if (rc == 0) {
 (void)tetra_call_fsm_handle(&hal, cmce_ssi, &p);
 } else {
 fprintf(stderr,
 "tetra_call_fsm: parse rc=%d ssi=0x%06X "
 "start=%d bits=%d body=%02X%02X%02X%02X\n",
 rc, cmce_ssi, cmce_start, cmce_bits,
 body[0], body[1], body[2], body[3]);
 }
 }
 }
 }
 }

 /* Phase 1E-B (2026-05-20) — RTL-parsed demand Mailbox entfernt.
  * Reaktion auf mm=2 / mm=7 läuft vollständig im SW-Walker-Pfad
  * (service_uldbod → react_mm2_locupd / react_mm7_grpid). */

 struct timespec ts;
 ts.tv_sec = 0;
 ts.tv_nsec = (long)POLL_INTERVAL_MS * 1000000L;
 nanosleep(&ts, NULL);
 since_reload_ms += POLL_INTERVAL_MS;
 if (since_reload_ms >= DB_RELOAD_INTERVAL_MS) {
 since_reload_ms = 0;
 int rv = tetra_db_reload();
 if (rv == 1) {
 fprintf(stderr,
 "tetra_attach_daemon: DB reloaded — %u ISSI / %u GSSI\n",
 tetra_db_count(0), tetra_db_count(1));
 }
 }
 }

 tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x0u);
 fprintf(stderr,
 "tetra_attach_daemon: exiting — USE_SW=0 (MLE-FSM fallback) "
 "(serviced=%u)\n", serviced_g);
 tetra_hal_close(&hal);
 return 0;
}
