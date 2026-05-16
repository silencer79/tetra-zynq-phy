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
#include "tetra_cmce_parser.h"
#include "tetra_call_fsm.h"

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

/* Indirect-read helpers for the Demand mailbox windows. Reply staging is
 * delegated to tetra_tx_transport (Phase Z.1). */
static uint32_t demand_read(tetra_hal_t *hal, uint32_t idx)
{
 tetra_reg_write(hal, REG_DEMAND_INDEX, idx);
 return tetra_reg_read(hal, REG_DEMAND_DATA);
}

static uint32_t grp_demand_read(tetra_hal_t *hal, uint32_t idx)
{
 tetra_reg_write(hal, REG_GRP_DEMAND_INDEX, idx);
 return tetra_reg_read(hal, REG_GRP_DEMAND_DATA);
}

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

/* Phase Y.1.e — service one Group-Attach (mm=7) demand: read MS-SSI +
 * gid_count + GSSI list, look each GSSI up in DB (auto-enroll if policy
 * allows), build the D-ATTACH-DETACH-GRP-ID-ACK reply, stage it into the
 * Group-Reply mailbox, pulse GO, and ACK the demand snapshot. */
static void service_grp_demand(tetra_hal_t *hal)
{
 uint32_t w0 = grp_demand_read(hal, 0);
 uint32_t w1 = grp_demand_read(hal, 1);
 uint32_t w2 = grp_demand_read(hal, 2);
 uint32_t w3 = grp_demand_read(hal, 3);
 uint32_t w4 = grp_demand_read(hal, 4);
 uint32_t w5 = grp_demand_read(hal, 5);
 uint32_t cnt = (w0 >> 19) & 0x3u;
 uint32_t atd = (w0 >> 18) & 0x1u;
 uint32_t rep = (w0 >> 17) & 0x1u;
 uint32_t ssi = w1 & 0x00FFFFFFu;
 uint32_t gssi[3] = { w2 & 0x00FFFFFFu,
 w3 & 0x00FFFFFFu,
 w4 & 0x00FFFFFFu };
 uint32_t at_arr = (w5 >> 12) & 0x3Fu; /* 3 × 2-bit */
 uint32_t adi_arr = (w5 >> 9) & 0x07u; /* 3 × 1-bit */
 uint32_t cls_arr = w5 & 0x1FFu; /* 3 × 3-bit */

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
 if (((adi_arr >> i) & 0x01u) != 0u) continue;
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
 unsigned cls_in = (cls_arr >> (i * 3u)) & 0x07u;
 unsigned adi_in = (adi_arr >> i) & 0x01u;
 unsigned at_in = (at_arr >> (i * 2u)) & 0x03u;
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
 tetra_reg_write(hal, REG_GRP_DEMAND_ACK, 0x1u);
 fprintf(stderr,
 "tetra_attach_daemon: GRP status-query (ssi=0x%06X) → "
 "skip (spec-conformant)\n", ssi);
 return;
 }

 /* Wenn keine GSSI passt: kein ACK senden — Demand stillschweigend
 * verwerfen. Encoder ist Fixed-1-Record-only (spec-konform), variable
 * Längen sind nicht zulässig. */
 if (reply_count == 0u) {
 tetra_reg_write(hal, REG_GRP_DEMAND_ACK, 0x1u);
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

 /* Release the demand snapshot. */
 tetra_reg_write(hal, REG_GRP_DEMAND_ACK, 0x1u);

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

static void usage(const char *a0)
{
 fprintf(stderr,
 "Usage: %s [--db-path PATH]\n"
 " Default DB path: %s\n",
 a0, TETRA_DB_DEFAULT_PATH);
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
  * 48/s bei 8/11, 0/s bei 10/11 — gemessen 2026-05-16). Erst dadurch
  * wird REG_VOICE_NUB_RX_CNT ein zuverlässiger PTT-Aktivitäts-
  * Indikator für den Call-FSM-Watchdog. */
 tetra_reg_write(&hal, REG_VOICE_NUB_SYNC_THRESH, 10u);

 fprintf(stderr,
 "tetra_attach_daemon: started — USE_SW=1, polling REG_DEMAND_STATUS, "
 "policy=0x%08X, VOICE_ACTIVE_MASK=0, NUB_SYNC_THRESH=10\n",
 tetra_reg_read(&hal, REG_DB_POLICY));

 uint32_t serviced = 0;
 uint32_t since_reload_ms = 0;
 uint16_t last_ul_count = 0xFFFFu; /* sentinel: first PDU always triggers */

 while (keep_running) {
 /* MER-Fix: Watchdog für hängende VOICE_ACTIVE_MASK. Wenn kein Slot
 * gerade TALKER ist, mask = 0. Wenn ein TALKER über N ms still ist
 * (RF-Drop, MS-Crash), force-fallback nach CONNECTED + mask=0.
 * Wenn ein Slot über N ms gar nichts mehr macht (kein U-RELEASE
 * trotz Power-Cycle), Slot freigeben. */
 tetra_call_fsm_tick(&hal);

 /* Phase Y.1.e — service Group-Attach (mm=7) demand mailbox first.
 * It's a separate AXI window, independent of mm=2 ITSI Attach. */
 uint32_t grp_status = tetra_reg_read(&hal, REG_GRP_DEMAND_STATUS);
 if (grp_status & 0x1u) {
 service_grp_demand(&hal);
 }

 /* Phase 7 G.2 — CMCE-Dispatch. We share REG_UL_PDU_STATUS with
 * tetra_ul_mon (which W1Cs the sticky for logging). Instead of
 * racing for the sticky bit we track ul_pdu_count[31:16]: each
 * CRC-OK PDU bumps it, so a count change = unseen PDU. We only
 * act on mle_disc==2 (CMCE); mle_disc==1 (MM) is already handled
 * by the reassembly path below. */
 uint32_t ul_status = tetra_reg_read(&hal, REG_UL_PDU_STATUS);
 if (UL_STATUS_VALID(ul_status)) {
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
 if (rc == 0) {
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

 uint32_t status = tetra_reg_read(&hal, REG_DEMAND_STATUS);
 uint32_t pending = status & 0x1u;

 if (pending) {
 uint32_t w0 = demand_read(&hal, 0);
 uint32_t w1 = demand_read(&hal, 1);
 uint32_t w2 = demand_read(&hal, 2);
 uint32_t w3 = demand_read(&hal, 3);
 uint32_t w4 = demand_read(&hal, 4);
 uint32_t w5 = demand_read(&hal, 5);
 uint32_t ssi = w1 & 0x00FFFFFFu;
 (void)w2; /* MS-LA in W2 is informational; we answer with REG_CELL_LA */
 uint32_t la = tetra_reg_read(&hal, REG_CELL_LA) & 0x3FFFu;
 uint32_t lut = (w0 >> 15) & 0x7u;
 uint32_t cnt = (w0 >> 18) & 0x7u;
 uint32_t gssi[3] = { w3 & 0x00FFFFFFu,
 w4 & 0x00FFFFFFu,
 w5 & 0x00FFFFFFu };

 uint32_t policy = tetra_reg_read(&hal, REG_DB_POLICY);
 int allow_issi = (policy & DB_POLICY_ACCEPT_UNKNOWN_ISSI) != 0;
 int allow_gssi = (policy & DB_POLICY_ACCEPT_UNKNOWN_GSSI) != 0;

 /* ---- ISSI lookup ----------------------------------------- */
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
 /* DB full or save error — fall back to reject-temp. */
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

 const tetra_db_profile_t *p = tetra_db_profile(profile_id);
 uint32_t gila_class = p ? p->gila_class: 4u;
 uint32_t gila_lifetime = p ? p->gila_lifetime: 1u;
 uint32_t gila_present = M2_DEFAULT_GILA_PRESENT;

 /* ---- GSSI-wish loop -------------------------------------- *
 * Walk demand_count GSSI slots, pick the FIRST hit (or the
 * first auto-enrolled one if accept_unknown_gssi=1). If the
 * MS sent count=0 OR none of its wishes can be honoured, fall
 * back to M2 default GSSI (0x2F4D61) — preserves M2 bit-id. */
 uint32_t effective_gila_gssi = M2_FALLBACK_GILA_GSSI;
 uint32_t actual_count = (cnt > 3u) ? 3u: cnt;
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
 /* save failure → keep looping; final fallback below. */
 }
 }

 /* If reject-temp, suppress GILA. */
 if (result != M2_DEFAULT_RESULT_OK) {
 gila_present = 0;
 effective_gila_gssi = 0;
 gila_class = 0;
 gila_lifetime = 0;
 }

 /* Bug-001 fix — pass MS-demand location_update_type (lut, already
  * extracted from Demand-Mailbox W0[17:15]) so the D-LOC-UPD-ACCEPT
  * mirrors the MS request per ETSI §16.10.35a. Pre-fix this was
  * hardcoded to 0=RoamingLocationUpdating in RTL. */
 stage_accept_body(&hal, ssi, la, result, lut,
 effective_gila_gssi,
 gila_class, gila_lifetime, gila_present);

 /* Release the demand snapshot. */
 tetra_reg_write(&hal, REG_DEMAND_ACK, 0x1u);

 serviced++;
 fprintf(stderr,
 "tetra_attach_daemon: serviced #%u — ssi=0x%06X la=0x%04X "
 "lut=%u cnt=%u policy=0x%X result=%u gila_gssi=0x%06X "
 "(profile=%u, %s%s%s)\n",
 serviced, ssi, la, lut, cnt, policy, result,
 effective_gila_gssi, profile_id,
 issi_hit ? "issi=hit":
 (issi_enrolled ? "issi=auto": "issi=reject"),
 gssi_resolved ? ", gssi=ok": "",
 (cnt && !gssi_resolved) ? ", gssi=fallback": "");
 } else {
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
 }

 tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x0u);
 fprintf(stderr,
 "tetra_attach_daemon: exiting — USE_SW=0 (MLE-FSM fallback) "
 "(serviced=%u)\n", serviced);
 tetra_hal_close(&hal);
 return 0;
}
