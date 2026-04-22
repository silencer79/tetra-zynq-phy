/*
 * tetra_db_mgr.c — Subscriber database manager (Phase 6 M2.3)
 *
 * ARM-side maintenance tool for the subscriber-shadow BRAM (256 × 64 bit).
 * The FPGA MLE registration FSM reads the BRAM at air-interface rate; this
 * tool is the write path: it pushes records via the AXI-Lite indirect
 * window (REG_SHADOW_INDEX / DATA_LO / DATA_HI / CTRL).
 *
 * Record layout (must match rtl/lmac/tetra_subscriber_shadow.v):
 *   [63:40] issi            24 bit — TETRA short subscriber identity
 *   [39:26] la              14 bit — location area
 *   [25:8]  reserved        18 bit — 0 for now
 *   [7]     permit_voice    1 bit
 *   [6]     permit_data     1 bit
 *   [5]     permit_reg      1 bit
 *   [4:1]   priority        4 bit
 *   [0]     valid           1 bit
 *
 * The ARM-local "authoritative" database lives in /var/lib/tetra/db.tsv
 * (TSV, one record per line).  Every commit re-pushes the full table so
 * the BRAM is always a mirror; slots not mentioned in the file are
 * invalidated (valid=0).
 *
 * Target: LibreSDR (Zynq-7020), armv7l
 * License: GPL v2
 */
#include "tetra_hal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define DB_DEPTH        256
#define DB_DEFAULT_PATH "/var/lib/tetra/db.tsv"

/* Local copies of HAL init/close — tetra_hal.c has main() so we can't link it. */
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

typedef struct {
    uint32_t issi;          /* 24 bit */
    uint16_t la;            /* 14 bit */
    uint8_t  permit_voice;
    uint8_t  permit_data;
    uint8_t  permit_reg;
    uint8_t  priority;      /*  4 bit */
    uint8_t  valid;
} subs_rec_t;

static subs_rec_t g_db[DB_DEPTH];

static uint64_t pack_record(const subs_rec_t *r)
{
    uint64_t w = 0;
    w |= ((uint64_t)(r->issi         & 0xFFFFFFu)) << 40;
    w |= ((uint64_t)(r->la           & 0x3FFFu))   << 26;
    /* [25:8] reserved = 0 */
    w |= ((uint64_t)(r->permit_voice & 0x1u))      << 7;
    w |= ((uint64_t)(r->permit_data  & 0x1u))      << 6;
    w |= ((uint64_t)(r->permit_reg   & 0x1u))      << 5;
    w |= ((uint64_t)(r->priority     & 0xFu))      << 1;
    w |= ((uint64_t)(r->valid        & 0x1u));
    return w;
}

static void push_slot(tetra_hal_t *hal, uint8_t idx, uint64_t rec)
{
    tetra_reg_write(hal, REG_SHADOW_INDEX,   idx);
    tetra_reg_write(hal, REG_SHADOW_DATA_LO, (uint32_t)(rec & 0xFFFFFFFFu));
    tetra_reg_write(hal, REG_SHADOW_DATA_HI, (uint32_t)(rec >> 32));
    tetra_reg_write(hal, REG_SHADOW_CTRL,    SHADOW_CTRL_COMMIT);
}

/* ------------------------------------------------------------------------
 * File I/O — TSV with header comments (# prefix)
 *   slot<TAB>issi<TAB>la<TAB>pv<TAB>pd<TAB>pr<TAB>prio
 * ------------------------------------------------------------------------ */
static int db_load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) return 0; /* empty DB is fine */
        perror(path);
        return -1;
    }
    char line[256];
    int lineno = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '#' || *s == '\n' || *s == '\0') continue;

        unsigned slot, issi, la, pv, pd, pr, prio;
        int n = sscanf(s, "%u %u %u %u %u %u %u",
                       &slot, &issi, &la, &pv, &pd, &pr, &prio);
        if (n != 7 || slot >= DB_DEPTH) {
            fprintf(stderr, "%s:%d: parse error\n", path, lineno);
            fclose(f);
            return -1;
        }
        g_db[slot].issi         = issi & 0xFFFFFFu;
        g_db[slot].la           = (uint16_t)(la & 0x3FFFu);
        g_db[slot].permit_voice = pv ? 1 : 0;
        g_db[slot].permit_data  = pd ? 1 : 0;
        g_db[slot].permit_reg   = pr ? 1 : 0;
        g_db[slot].priority     = (uint8_t)(prio & 0xFu);
        g_db[slot].valid        = 1;
    }
    fclose(f);
    return 0;
}

static int db_save(const char *path)
{
    /* mkdir -p on parent (best-effort) */
    char dir[256];
    strncpy(dir, path, sizeof dir - 1);
    dir[sizeof dir - 1] = '\0';
    char *slash = strrchr(dir, '/');
    if (slash && slash != dir) {
        *slash = '\0';
        mkdir(dir, 0755);
    }

    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return -1; }
    fprintf(f, "# tetra subscriber DB — slot issi la permit_voice permit_data permit_reg priority\n");
    for (int i = 0; i < DB_DEPTH; i++) {
        if (!g_db[i].valid) continue;
        fprintf(f, "%d\t%u\t%u\t%u\t%u\t%u\t%u\n",
                i, g_db[i].issi, g_db[i].la,
                g_db[i].permit_voice, g_db[i].permit_data,
                g_db[i].permit_reg,   g_db[i].priority);
    }
    fclose(f);
    return 0;
}

/* ------------------------------------------------------------------------
 * Commands
 * ------------------------------------------------------------------------ */
static void cmd_list(void)
{
    int n = 0;
    printf("slot  issi    la  v d r prio\n");
    for (int i = 0; i < DB_DEPTH; i++) {
        if (!g_db[i].valid) continue;
        printf("%3d %6u %4u  %u %u %u %4u\n",
               i, g_db[i].issi, g_db[i].la,
               g_db[i].permit_voice, g_db[i].permit_data,
               g_db[i].permit_reg,   g_db[i].priority);
        n++;
    }
    printf("-- %d record(s)\n", n);
}

static int cmd_add(int slot, uint32_t issi, uint16_t la,
                   uint8_t pv, uint8_t pd, uint8_t pr, uint8_t prio)
{
    if (slot < 0 || slot >= DB_DEPTH) {
        fprintf(stderr, "slot out of range (0..%d)\n", DB_DEPTH - 1);
        return -1;
    }
    g_db[slot].issi         = issi & 0xFFFFFFu;
    g_db[slot].la           = la   & 0x3FFFu;
    g_db[slot].permit_voice = pv ? 1 : 0;
    g_db[slot].permit_data  = pd ? 1 : 0;
    g_db[slot].permit_reg   = pr ? 1 : 0;
    g_db[slot].priority     = prio & 0xFu;
    g_db[slot].valid        = 1;
    return 0;
}

static int cmd_del(int slot)
{
    if (slot < 0 || slot >= DB_DEPTH) {
        fprintf(stderr, "slot out of range (0..%d)\n", DB_DEPTH - 1);
        return -1;
    }
    memset(&g_db[slot], 0, sizeof g_db[slot]);
    return 0;
}

/* Push the entire 256-entry table into shadow BRAM.  Empty slots go in
 * as all-zero (valid=0) so nothing stale lingers from a prior session. */
static void cmd_sync(tetra_hal_t *hal)
{
    int n = 0;
    for (int i = 0; i < DB_DEPTH; i++) {
        uint64_t rec = pack_record(&g_db[i]);
        push_slot(hal, (uint8_t)i, rec);
        if (g_db[i].valid) n++;
    }
    printf("tetra_db_mgr: pushed 256 slots (%d valid) → shadow BRAM\n", n);
}

static void usage(const char *a0)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s [--file PATH] list\n"
        "  %s [--file PATH] add SLOT ISSI LA [PV] [PD] [PR] [PRIO]\n"
        "  %s [--file PATH] del SLOT\n"
        "  %s [--file PATH] sync            # push DB to FPGA\n"
        "Defaults: PV=PD=PR=1 PRIO=0, file=%s\n",
        a0, a0, a0, a0, DB_DEFAULT_PATH);
}

int main(int argc, char *argv[])
{
    const char *path = DB_DEFAULT_PATH;

    static struct option lo[] = {
        {"file", required_argument, NULL, 'f'},
        {"help", no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "f:h", lo, NULL)) != -1) {
        switch (opt) {
        case 'f': path = optarg; break;
        case 'h': default: usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }
    if (optind >= argc) { usage(argv[0]); return 1; }
    const char *cmd = argv[optind++];

    memset(g_db, 0, sizeof g_db);
    if (db_load(path) < 0) return 1;

    if (!strcmp(cmd, "list")) {
        cmd_list();
        return 0;
    }
    if (!strcmp(cmd, "add")) {
        if (argc - optind < 3) { usage(argv[0]); return 1; }
        int      slot = atoi(argv[optind++]);
        uint32_t issi = (uint32_t)strtoul(argv[optind++], NULL, 0);
        uint16_t la   = (uint16_t)strtoul(argv[optind++], NULL, 0);
        uint8_t  pv   = (argc > optind) ? (uint8_t)atoi(argv[optind++]) : 1;
        uint8_t  pd   = (argc > optind) ? (uint8_t)atoi(argv[optind++]) : 1;
        uint8_t  pr   = (argc > optind) ? (uint8_t)atoi(argv[optind++]) : 1;
        uint8_t  prio = (argc > optind) ? (uint8_t)atoi(argv[optind++]) : 0;
        if (cmd_add(slot, issi, la, pv, pd, pr, prio) < 0) return 1;
        return db_save(path) < 0 ? 1 : 0;
    }
    if (!strcmp(cmd, "del")) {
        if (argc - optind < 1) { usage(argv[0]); return 1; }
        int slot = atoi(argv[optind++]);
        if (cmd_del(slot) < 0) return 1;
        return db_save(path) < 0 ? 1 : 0;
    }
    if (!strcmp(cmd, "sync")) {
        tetra_hal_t hal = {0};
        if (tetra_hal_init(&hal) < 0) return 1;
        cmd_sync(&hal);
        tetra_hal_close(&hal);
        return 0;
    }

    fprintf(stderr, "unknown command: %s\n", cmd);
    usage(argv[0]);
    return 1;
}
