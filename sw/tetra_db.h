/*
 * tetra_db.h — TETRA Subscriber/Group entity-DB (SW-resident, Phase X.3)
 *
 * Replaces the FPGA EntityTable/ProfileTable for SW-pulled D-LOC-UPDATE-ACCEPT
 * lookup.  In Phase X the DB lives entirely in the daemon process: it is
 * loaded from /root/db.tsv at start-up and re-loaded on mtime changes so an
 * operator can edit the file (or the WebUI in X.5) without restarting the
 * daemon.
 *
 * Storage layout:
 *   - 256-slot linear array of entries (matches the historical EntityTable
 *     depth; lookup is O(N) with a tiny N, no hash needed).
 *   - 6-slot ProfileTable mirroring the RTL §9.2 32-bit record layout.
 *     Slot 0 is hard-coded to 0x0000_088F (M2 bit-identity guard:
 *     gila_class=4, gila_lifetime=1, all permits + valid).  Slots 1..5
 *     reset to 0 (= invalid) — they become the WebUI extension point.
 *
 * The DB is **process-local**.  No locking is required: tetra_attach_daemon
 * is single-threaded.  Reload is also called from the same poll loop.
 *
 * License: GPL v2
 */
#ifndef TETRA_DB_H
#define TETRA_DB_H

#include <stdint.h>
#include <sys/types.h>  /* time_t (used by impl, kept here for portability) */

#define TETRA_DB_MAX_ENTRIES   256
#define TETRA_DB_MAX_PROFILES    6
#define TETRA_DB_DEFAULT_PATH "/root/db.tsv"

/* ProfileTable record (mirrors rtl/lmac/tetra_profile_table.v §9.2 layout):
 *   [11: 9]  gila_class
 *   [ 8: 7]  gila_lifetime
 *   [ 3]     permit_voice
 *   [ 2]     permit_data
 *   [ 1]     permit_reg
 *   [ 0]     valid
 */
typedef struct {
    uint32_t bits;          /* raw 32-bit profile record */
    uint8_t  gila_class;    /* 3-bit, M2 = 4 */
    uint8_t  gila_lifetime; /* 2-bit, M2 = 1 */
    uint8_t  permit_voice;  /* 1-bit */
    uint8_t  permit_data;   /* 1-bit */
    uint8_t  permit_reg;    /* 1-bit */
    uint8_t  valid;         /* 1-bit (0 → slot empty/invalid) */
} tetra_db_profile_t;

/* Entity record — one row of db.tsv (slot, entity_id, type, profile_id). */
typedef struct {
    uint32_t entity_id;     /* 24-bit ISSI / GSSI */
    uint8_t  entity_type;   /* 0 = ISSI, 1 = GSSI */
    uint8_t  profile_id;    /* 0..5, index into ProfileTable */
    uint8_t  slot;          /* 0..255, slot index in DB */
} tetra_db_entry_t;

/* Load a TSV file into the in-memory DB.  Path is also remembered for
 * tetra_db_reload() and the atomic save in tetra_db_alloc().  Replaces any
 * previously loaded entries.  Returns 0 on success, -1 on I/O error.
 * Empty/missing file is treated as "DB has zero entries" (returns 0). */
int tetra_db_load(const char *path);

/* If the loaded file's mtime has changed since last load, re-read it.
 * Returns 1 if re-loaded, 0 if unchanged, -1 on error. */
int tetra_db_reload(void);

/* O(N) linear scan.  Fills *out and returns 1 if found, 0 if not.
 * out may be NULL (pure existence check). */
int tetra_db_lookup(uint32_t entity_id, uint8_t entity_type,
                    tetra_db_entry_t *out);

/* Append a new entry to the first free slot, atomically rewrite the TSV
 * (write tmp + rename).  Returns slot on success, -1 on full/I-O error. */
int tetra_db_alloc(uint32_t entity_id, uint8_t entity_type,
                   uint8_t profile_id);

/* Pointer to the in-memory profile record (NULL if id >= MAX_PROFILES).
 * The pointer is stable for the lifetime of the process. */
const tetra_db_profile_t *tetra_db_profile(uint8_t profile_id);

/* Number of entries with the given type currently in the DB.  Used by the
 * daemon for stats / log output.  type==0 → ISSI count, type==1 → GSSI. */
uint16_t tetra_db_count(uint8_t entity_type);

/* Iterate over entries with matching entity_type.  Caller initialises *cursor
 * to 0 before the first call; the function advances it past the returned slot.
 * Returns 1 if an entry was found (filled into *out), 0 if iteration is
 * exhausted.  Out may NOT be NULL. */
int tetra_db_iterate_type(uint16_t *cursor, uint8_t entity_type,
                          tetra_db_entry_t *out);

#endif /* TETRA_DB_H */
