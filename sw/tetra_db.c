/*
 * tetra_db.c — Phase X.3 SW-resident entity DB (see tetra_db.h)
 *
 * Implementation notes:
 *   - All state is file-static.  Single-threaded use only.
 *   - Linear-scan lookup.  256 entries × pointer-comparison is well under
 *     1 microsecond on the Zynq PS, even in the worst case — and the
 *     attach-daemon poll cadence is 10 ms, so this is non-critical.
 *   - tetra_db_alloc() persists immediately (write to <path>.tmp + rename),
 *     so a daemon crash never leaves a half-written TSV on disk.
 *   - The default TSV is auto-created if missing (with the M2 bit-identity
 *     baseline: MTP3550 ISSI in slot 0 + Default-Group GSSI in slot 1).
 *
 * License: GPL v2
 */

#include "tetra_db.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>

#define DB_PATH_MAX  256

/* M2 bit-identity guard: Profile 0 reset record (mirrors RTL).  Slots 1..5
 * default to 0 (valid=0) — they become operator-editable in Phase X.5 once
 * the WebUI is wired through. */
#define DB_PROFILE0_BITS   0x0000088Fu

static struct {
    tetra_db_entry_t   entries[TETRA_DB_MAX_ENTRIES];
    uint8_t            slot_used[TETRA_DB_MAX_ENTRIES];
    tetra_db_profile_t profiles[TETRA_DB_MAX_PROFILES];
    char               path[DB_PATH_MAX];
    time_t             mtime;
    uint16_t           num_entries;   /* count of slot_used==1 */
} g_db;

/* Decode a 32-bit ProfileTable record into the convenience-fields. */
static void profile_decode(uint32_t bits, tetra_db_profile_t *out)
{
    out->bits          =  bits;
    out->gila_class    = (bits >> 9) & 0x7u;
    out->gila_lifetime = (bits >> 7) & 0x3u;
    out->permit_voice  = (bits >> 3) & 0x1u;
    out->permit_data   = (bits >> 2) & 0x1u;
    out->permit_reg    = (bits >> 1) & 0x1u;
    out->valid         =  bits       & 0x1u;
}

static void profiles_reset(void)
{
    profile_decode(DB_PROFILE0_BITS, &g_db.profiles[0]);
    for (int i = 1; i < TETRA_DB_MAX_PROFILES; i++)
        profile_decode(0u, &g_db.profiles[i]);
}

static void entries_reset(void)
{
    memset(g_db.entries,   0, sizeof(g_db.entries));
    memset(g_db.slot_used, 0, sizeof(g_db.slot_used));
    g_db.num_entries = 0;
}

/* Parse one logical line from db.tsv.  Returns 1 on a row that yielded an
 * entry, 0 on comment/empty, -1 on a malformed row (caller logs + skips). */
static int parse_line(char *line)
{
    /* Strip trailing comment (after first '#' that is preceded by whitespace
     * or sits at column 0). */
    char *hash = strchr(line, '#');
    if (hash) *hash = '\0';

    /* Skip leading whitespace. */
    char *p = line;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == '\0') return 0;

    unsigned slot, eid, etype, pid;
    int n = sscanf(p, "%u %u %u %u", &slot, &eid, &etype, &pid);
    if (n != 4) return -1;
    if (slot  >= TETRA_DB_MAX_ENTRIES)  return -1;
    if (etype >  1)                     return -1;
    if (pid   >= TETRA_DB_MAX_PROFILES) return -1;

    g_db.entries[slot].entity_id   = eid & 0x00FFFFFFu;
    g_db.entries[slot].entity_type = (uint8_t)etype;
    g_db.entries[slot].profile_id  = (uint8_t)pid;
    g_db.entries[slot].slot        = (uint8_t)slot;
    if (!g_db.slot_used[slot]) g_db.num_entries++;
    g_db.slot_used[slot] = 1;
    return 1;
}

static int read_file(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    char buf[256];
    int line_no = 0;
    while (fgets(buf, sizeof(buf), f)) {
        line_no++;
        int rv = parse_line(buf);
        if (rv < 0)
            fprintf(stderr, "tetra_db: %s:%d malformed, skipped\n",
                    path, line_no);
    }
    fclose(f);
    return 0;
}

static int stat_mtime(const char *path, time_t *out)
{
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    *out = st.st_mtime;
    return 0;
}

int tetra_db_load(const char *path)
{
    if (!path) path = TETRA_DB_DEFAULT_PATH;

    profiles_reset();
    entries_reset();

    strncpy(g_db.path, path, DB_PATH_MAX - 1);
    g_db.path[DB_PATH_MAX - 1] = '\0';
    g_db.mtime = 0;

    if (read_file(path) != 0) {
        /* Missing file = empty DB (legitimate first-boot). */
        if (errno == ENOENT) return 0;
        return -1;
    }

    (void)stat_mtime(path, &g_db.mtime);
    return 0;
}

int tetra_db_reload(void)
{
    if (g_db.path[0] == '\0') return -1;

    time_t mt = 0;
    if (stat_mtime(g_db.path, &mt) != 0) return -1;
    if (mt == g_db.mtime) return 0;

    profiles_reset();
    entries_reset();
    if (read_file(g_db.path) != 0) return -1;
    g_db.mtime = mt;
    return 1;
}

int tetra_db_lookup(uint32_t entity_id, uint8_t entity_type,
                    tetra_db_entry_t *out)
{
    entity_id &= 0x00FFFFFFu;
    for (int i = 0; i < TETRA_DB_MAX_ENTRIES; i++) {
        if (!g_db.slot_used[i]) continue;
        if (g_db.entries[i].entity_type != entity_type) continue;
        if (g_db.entries[i].entity_id   != entity_id)   continue;
        if (out) *out = g_db.entries[i];
        return 1;
    }
    return 0;
}

/* Atomic write: dump all used slots to <path>.tmp and rename(2). */
static int save_tsv(void)
{
    char tmp[DB_PATH_MAX + 8];
    snprintf(tmp, sizeof(tmp), "%s.tmp", g_db.path);

    FILE *f = fopen(tmp, "w");
    if (!f) return -1;

    fprintf(f, "# tetra entity DB (Phase X.3, SW-managed)\n");
    fprintf(f, "# slot\tentity_id\tentity_type\tprofile_id\n");
    fprintf(f, "# entity_type: 0=ISSI, 1=GSSI\n");
    for (int i = 0; i < TETRA_DB_MAX_ENTRIES; i++) {
        if (!g_db.slot_used[i]) continue;
        fprintf(f, "%d\t%u\t%u\t%u\n",
                i,
                g_db.entries[i].entity_id,
                g_db.entries[i].entity_type,
                g_db.entries[i].profile_id);
    }
    fflush(f);
    fsync(fileno(f));
    fclose(f);

    if (rename(tmp, g_db.path) != 0) {
        unlink(tmp);
        return -1;
    }

    /* Refresh remembered mtime so our own save does NOT trigger a reload. */
    (void)stat_mtime(g_db.path, &g_db.mtime);
    return 0;
}

int tetra_db_alloc(uint32_t entity_id, uint8_t entity_type,
                   uint8_t profile_id)
{
    entity_id &= 0x00FFFFFFu;
    if (entity_type > 1)                     return -1;
    if (profile_id  >= TETRA_DB_MAX_PROFILES) return -1;

    /* Already present? — return its slot, do NOT duplicate. */
    tetra_db_entry_t hit;
    if (tetra_db_lookup(entity_id, entity_type, &hit))
        return (int)hit.slot;

    int slot = -1;
    for (int i = 0; i < TETRA_DB_MAX_ENTRIES; i++) {
        if (!g_db.slot_used[i]) { slot = i; break; }
    }
    if (slot < 0) return -1;

    g_db.entries[slot].entity_id   = entity_id;
    g_db.entries[slot].entity_type = entity_type;
    g_db.entries[slot].profile_id  = profile_id;
    g_db.entries[slot].slot        = (uint8_t)slot;
    g_db.slot_used[slot] = 1;
    g_db.num_entries++;

    if (g_db.path[0] != '\0' && save_tsv() != 0) {
        /* Roll back on save failure so RAM stays consistent with disk. */
        g_db.entries[slot] = (tetra_db_entry_t){0};
        g_db.slot_used[slot] = 0;
        g_db.num_entries--;
        return -1;
    }
    return slot;
}

const tetra_db_profile_t *tetra_db_profile(uint8_t profile_id)
{
    if (profile_id >= TETRA_DB_MAX_PROFILES) return NULL;
    return &g_db.profiles[profile_id];
}

uint16_t tetra_db_count(uint8_t entity_type)
{
    uint16_t n = 0;
    for (int i = 0; i < TETRA_DB_MAX_ENTRIES; i++) {
        if (!g_db.slot_used[i]) continue;
        if (g_db.entries[i].entity_type == entity_type) n++;
    }
    return n;
}
