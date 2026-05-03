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
 *   - Replaces the fixed M2 replica with DB lookup (tetra_db_lookup +
 *     tetra_db_profile).
 *   - Honors REG_DB_POLICY bit 0 (accept_unknown_issi) and bit 1
 *     (accept_unknown_gssi) for auto-enroll.
 *   - Reads up to 3 GSSI-wishes from Demand W3..W5 and mirrors the first
 *     accepted one into GILA (otherwise falls back to profile-default GSSI
 *     = MTP3550 baseline 0x2F4D61).
 *   - Re-loads /root/db.tsv whenever its mtime changes (Web-UI live edits).
 *
 * M2 bit-identity guarantee:  with the default db.tsv (slot 0 = MTP3550
 * ISSI, slot 1 = Default-Group GSSI 0x2F4D61, profile 0 = 0x0000_088F)
 * the staged body is byte-for-byte identical to the X.2 fixed replica.
 *
 * Target: LibreSDR (Zynq-7020), armv7l, gcc cross-compile
 * License: GPL v2
 */

#include "tetra_hal.h"
#include "tetra_db.h"

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

/* Hard-coded gold-ref defaults (M2 bit-identity guard).  These match what
 * the existing FPGA MLE-FSM produces for the Profile-0 + GSSI=0x2F4D61
 * baseline; SW just mirrors them so flipping use_sw_body in a live test
 * does NOT change the on-air ACCEPT bytes.
 *
 * GILA_GSSI is the *fallback* used only when:
 *   - the demanding MS sent zero GSSI-wishes, AND
 *   - the matched ISSI's profile has no default-GSSI association in db.tsv. */
#define M2_DEFAULT_LA           0x0042u
#define M2_DEFAULT_ADDR_TYPE    0x1u    /* ETSI Ssi+EventLabel             */
#define M2_DEFAULT_RESULT_OK    0x0u    /* accept                          */
#define M2_DEFAULT_RESULT_TEMP  0x1u    /* reject-temp (ITSI not allowed)  */
#define M2_FALLBACK_GILA_GSSI   0x2F4D61u
#define M2_DEFAULT_GILA_PRESENT 0x1u
#define M2_DEFAULT_ENCRYPTION   0x0u
#define M2_DEFAULT_AUTH_RESULT  0x1u

#define POLL_INTERVAL_MS        10      /* polling loop pacing             */
#define DB_RELOAD_INTERVAL_MS   5000    /* mtime check cadence             */

static volatile int keep_running = 1;

static void on_sigint(int sig)
{
    (void)sig;
    keep_running = 0;
}

/* Indirect-write helper for the Reply mailbox window.  Sequence is
 * INDEX → DATA so the FPGA latches `data` at word `idx`. */
static void reply_write(tetra_hal_t *hal, uint32_t idx, uint32_t data)
{
    tetra_reg_write(hal, REG_REPLY_INDEX, idx);
    tetra_reg_write(hal, REG_REPLY_DATA,  data);
}

/* Indirect-read helper for the Demand mailbox window. */
static uint32_t demand_read(tetra_hal_t *hal, uint32_t idx)
{
    tetra_reg_write(hal, REG_DEMAND_INDEX, idx);
    return tetra_reg_read(hal, REG_DEMAND_DATA);
}

/* Stage one body in the Reply mailbox and pulse GO. */
static void stage_accept_body(tetra_hal_t *hal,
                              uint32_t ssi,
                              uint32_t la,
                              uint32_t result,
                              uint32_t gila_gssi,
                              uint32_t gila_class,
                              uint32_t gila_lifetime,
                              uint32_t gila_present)
{
    reply_write(hal, 0, ssi & 0x00FFFFFFu);                 /* W0 ssi      */
    reply_write(hal, 1, la  & 0x3FFFu);                      /* W1 la       */
    reply_write(hal, 2, M2_DEFAULT_ADDR_TYPE);               /* W2 addrtype */
    reply_write(hal, 3, result & 0x3u);                      /* W3 result   */
    reply_write(hal, 4, gila_gssi & 0x00FFFFFFu);            /* W4 gssi     */
    reply_write(hal, 5, ((gila_class    & 0x7u) << 2)
                       | (gila_lifetime & 0x3u));            /* W5 class/life */
    reply_write(hal, 6, gila_present & 0x1u);                /* W6 gilaPres */
    reply_write(hal, 7, M2_DEFAULT_ENCRYPTION);              /* W7 enc      */
    reply_write(hal, 8, M2_DEFAULT_AUTH_RESULT);             /* W8 auth     */

    /* GO pulse — HW-clears after consume */
    tetra_reg_write(hal, REG_REPLY_GO, 0x1u);
}

static void usage(const char *a0)
{
    fprintf(stderr,
        "Usage: %s [--db-path PATH]\n"
        "  Default DB path: %s\n",
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

    signal(SIGINT,  on_sigint);
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

    fprintf(stderr,
            "tetra_attach_daemon: started — USE_SW=1, polling REG_DEMAND_STATUS, "
            "policy=0x%08X\n",
            tetra_reg_read(&hal, REG_DB_POLICY));

    uint32_t serviced = 0;
    uint32_t since_reload_ms = 0;

    while (keep_running) {
        uint32_t status = tetra_reg_read(&hal, REG_DEMAND_STATUS);
        uint32_t pending = status & 0x1u;

        if (pending) {
            uint32_t w0 = demand_read(&hal, 0);
            uint32_t w1 = demand_read(&hal, 1);
            uint32_t w2 = demand_read(&hal, 2);
            uint32_t w3 = demand_read(&hal, 3);
            uint32_t w4 = demand_read(&hal, 4);
            uint32_t w5 = demand_read(&hal, 5);
            uint32_t ssi   = w1 & 0x00FFFFFFu;
            uint32_t la    = w2 & 0x3FFFu;
            uint32_t lut   = (w0 >> 15) & 0x7u;
            uint32_t cnt   = (w0 >> 18) & 0x7u;
            uint32_t gssi[3] = { w3 & 0x00FFFFFFu,
                                 w4 & 0x00FFFFFFu,
                                 w5 & 0x00FFFFFFu };

            uint32_t policy = tetra_reg_read(&hal, REG_DB_POLICY);
            int allow_issi  = (policy & DB_POLICY_ACCEPT_UNKNOWN_ISSI) != 0;
            int allow_gssi  = (policy & DB_POLICY_ACCEPT_UNKNOWN_GSSI) != 0;

            /* ---- ISSI lookup ----------------------------------------- */
            tetra_db_entry_t entry;
            int issi_hit = tetra_db_lookup(ssi, 0, &entry);
            int issi_enrolled = 0;
            uint32_t result = M2_DEFAULT_RESULT_OK;
            uint8_t  profile_id = 0;

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
            uint32_t gila_class    = p ? p->gila_class    : 4u;
            uint32_t gila_lifetime = p ? p->gila_lifetime : 1u;
            uint32_t gila_present  = M2_DEFAULT_GILA_PRESENT;

            /* ---- GSSI-wish loop -------------------------------------- *
             * Walk demand_count GSSI slots, pick the FIRST hit (or the
             * first auto-enrolled one if accept_unknown_gssi=1).  If the
             * MS sent count=0 OR none of its wishes can be honoured, fall
             * back to M2 default GSSI (0x2F4D61) — preserves M2 bit-id. */
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
                    /* save failure → keep looping; final fallback below. */
                }
            }

            /* If reject-temp, suppress GILA. */
            if (result != M2_DEFAULT_RESULT_OK) {
                gila_present = 0;
                effective_gila_gssi = 0;
                gila_class    = 0;
                gila_lifetime = 0;
            }

            stage_accept_body(&hal, ssi, la, result,
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
                    issi_hit ? "issi=hit" :
                       (issi_enrolled ? "issi=auto" : "issi=reject"),
                    gssi_resolved ? ", gssi=ok" : "",
                    (cnt && !gssi_resolved) ? ", gssi=fallback" : "");
        } else {
            struct timespec ts;
            ts.tv_sec  = 0;
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
