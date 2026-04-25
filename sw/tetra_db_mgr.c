/*
 * tetra_db_mgr.c — EntityTable database manager (Phase 6 D-rev)
 *
 * ARM-side maintenance tool for the EntityTable BRAM (256 × 64 bit).
 * The FPGA MLE registration FSM reads the BRAM at air-interface rate; this
 * tool is the write path: it pushes records via the AXI-Lite indirect
 * window (REG_SHADOW_INDEX / DATA_LO / DATA_HI / CTRL — same window, new
 * record interpretation per docs/ARCHITECTURE.md §9.2).
 *
 * Record layout (must match rtl/lmac/tetra_entity_table.v):
 *   [63:40] entity_id     24 bit — ISSI ODER GSSI
 *   [39]    entity_type    1 bit — 0=ISSI, 1=GSSI
 *   [38:35] profile_id     4 bit — index into ProfileTable
 *   [34: 1] reserved      34 bit — 0
 *   [ 0]    valid          1 bit
 *
 * Permits, LA, priority etc. live in the ProfileTable now (see
 * sw/tetra_profile_mgr or the WebUI profiles.cgi).  This tool only manages
 * the persistent identity → profile binding.
 *
 * The ARM-local "authoritative" database lives in /var/lib/tetra/db.tsv
 * (TSV, one record per line).  Format (4 columns, tab-separated):
 *   slot<TAB>entity_id<TAB>entity_type<TAB>profile_id
 *
 * Old 7-column format (slot issi la pv pd pr prio) is detected and
 * rejected with a hard error so legacy DB files cannot accidentally
 * roll back the schema.
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
    uint32_t entity_id;     /* 24 bit (ISSI or GSSI) */
    uint8_t  entity_type;   /*  1 bit (0=ISSI, 1=GSSI) */
    uint8_t  profile_id;    /*  4 bit (0..5) */
    uint8_t  valid;
} ent_rec_t;

static ent_rec_t g_db[DB_DEPTH];

static uint64_t pack_record(const ent_rec_t *r)
{
    uint64_t w = 0;
    w |= ((uint64_t)(r->entity_id   & 0xFFFFFFu)) << 40;
    w |= ((uint64_t)(r->entity_type & 0x1u))      << 39;
    w |= ((uint64_t)(r->profile_id  & 0xFu))      << 35;
    /* [34: 1] reserved = 0 */
    w |= ((uint64_t)(r->valid       & 0x1u));
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
 * File I/O — TSV with header comments (# prefix).  4 columns:
 *   slot<TAB>entity_id<TAB>entity_type<TAB>profile_id
 *
 * Old 7-column format ("slot issi la pv pd pr prio") is rejected with
 * a hard error pointing the operator at the migration path.
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

        unsigned slot, entity_id, entity_type, profile_id;
        unsigned extra[3];
        int n = sscanf(s, "%u %u %u %u %u %u %u",
                       &slot, &entity_id, &entity_type, &profile_id,
                       &extra[0], &extra[1], &extra[2]);
        if (n == 7) {
            /* Legacy 7-column TSV — reject hard. */
            fprintf(stderr,
                "%s:%d: legacy 7-column TSV format detected.\n"
                "  Phase 6 D-rev EntityTable uses 4 columns:\n"
                "    slot<TAB>entity_id<TAB>entity_type<TAB>profile_id\n"
                "  Permits/LA/priority moved to ProfileTable.\n"
                "  Regenerate db.tsv from sw/db.tsv.default or via WebUI.\n",
                path, lineno);
            fclose(f);
            return -1;
        }
        if (n != 4 || slot >= DB_DEPTH ||
            entity_id > 0xFFFFFFu || entity_type > 1u || profile_id > 5u) {
            fprintf(stderr, "%s:%d: parse error (need 4 cols)\n",
                    path, lineno);
            fclose(f);
            return -1;
        }
        g_db[slot].entity_id   = entity_id & 0xFFFFFFu;
        g_db[slot].entity_type = (uint8_t)(entity_type & 0x1u);
        g_db[slot].profile_id  = (uint8_t)(profile_id  & 0xFu);
        g_db[slot].valid       = 1;
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
    fprintf(f, "# tetra entity DB (Phase 6 D-rev §9.2) — slot entity_id entity_type profile_id\n");
    fprintf(f, "# entity_type: 0=ISSI, 1=GSSI\n");
    for (int i = 0; i < DB_DEPTH; i++) {
        if (!g_db[i].valid) continue;
        fprintf(f, "%d\t%u\t%u\t%u\n",
                i, g_db[i].entity_id, g_db[i].entity_type, g_db[i].profile_id);
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
    printf("slot  entity_id  type profile\n");
    for (int i = 0; i < DB_DEPTH; i++) {
        if (!g_db[i].valid) continue;
        printf("%3d %9u    %u %4u\n",
               i, g_db[i].entity_id, g_db[i].entity_type, g_db[i].profile_id);
        n++;
    }
    printf("-- %d record(s)\n", n);
}

static int cmd_add(int slot, uint32_t entity_id, uint8_t entity_type,
                   uint8_t profile_id)
{
    if (slot < 0 || slot >= DB_DEPTH) {
        fprintf(stderr, "slot out of range (0..%d)\n", DB_DEPTH - 1);
        return -1;
    }
    if (entity_type > 1) {
        fprintf(stderr, "entity_type must be 0 (ISSI) or 1 (GSSI)\n");
        return -1;
    }
    if (profile_id > 5) {
        fprintf(stderr, "profile_id must be in 0..5 (Phase 6 D ProfileTable depth)\n");
        return -1;
    }
    g_db[slot].entity_id   = entity_id & 0xFFFFFFu;
    g_db[slot].entity_type = entity_type & 0x1u;
    g_db[slot].profile_id  = profile_id & 0xFu;
    g_db[slot].valid       = 1;
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

/* Push the entire 256-entry table into EntityTable BRAM.  Empty slots go
 * in as all-zero (valid=0) so nothing stale lingers from a prior session. */
static void cmd_sync(tetra_hal_t *hal)
{
    int n = 0;
    for (int i = 0; i < DB_DEPTH; i++) {
        uint64_t rec = pack_record(&g_db[i]);
        push_slot(hal, (uint8_t)i, rec);
        if (g_db[i].valid) n++;
    }
    printf("tetra_db_mgr: pushed 256 slots (%d valid) → EntityTable BRAM\n", n);
}

static void usage(const char *a0)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s [--file PATH] list\n"
        "  %s [--file PATH] add SLOT ENTITY_ID ENTITY_TYPE PROFILE_ID\n"
        "  %s [--file PATH] del SLOT\n"
        "  %s [--file PATH] sync            # push DB to FPGA\n"
        "\n"
        "  ENTITY_TYPE: 0 = ISSI, 1 = GSSI\n"
        "  PROFILE_ID:  0..5 (index into ProfileTable, see profiles.cgi)\n"
        "  Default file: %s\n",
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
        if (argc - optind < 4) { usage(argv[0]); return 1; }
        int      slot        = atoi(argv[optind++]);
        uint32_t entity_id   = (uint32_t)strtoul(argv[optind++], NULL, 0);
        uint8_t  entity_type = (uint8_t)atoi(argv[optind++]);
        uint8_t  profile_id  = (uint8_t)atoi(argv[optind++]);
        if (cmd_add(slot, entity_id, entity_type, profile_id) < 0) return 1;
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
