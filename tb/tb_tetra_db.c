/*
 * tb_tetra_db.c — Host-side unit-TB for sw/tetra_db.[ch] (Phase X.3)
 *
 * Build (gcc, host):
 *   gcc -Wall -Wextra -o /tmp/tb_db tb/tb_tetra_db.c sw/tetra_db.c -I sw/
 *   /tmp/tb_db
 *
 * Each TC writes a fresh fixture to /tmp/tetra_db_tb_<n>.tsv so tests are
 * isolated and deterministic.  Counts PASS/FAIL and exits non-zero on any
 * failure for CI integration.
 */

#include "tetra_db.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <utime.h>
#include <time.h>

static int g_pass = 0;
static int g_fail = 0;

#define EXPECT_EQ(actual, expected, msg) do {                              \
    if ((actual) == (expected)) {                                          \
        g_pass++;                                                          \
        printf("  PASS: %-50s (%ld == %ld)\n",                             \
               (msg), (long)(actual), (long)(expected));                   \
    } else {                                                               \
        g_fail++;                                                          \
        printf("  FAIL: %-50s (%ld != %ld)\n",                             \
               (msg), (long)(actual), (long)(expected));                   \
    }                                                                      \
} while (0)

#define EXPECT_TRUE(cond, msg) do {                                        \
    if (cond) {                                                            \
        g_pass++;                                                          \
        printf("  PASS: %s\n", (msg));                                     \
    } else {                                                               \
        g_fail++;                                                          \
        printf("  FAIL: %s\n", (msg));                                     \
    }                                                                      \
} while (0)

static const char *DEFAULT_TSV =
    "# tetra entity DB test fixture\n"
    "# slot  entity_id  entity_type  profile_id\n"
    "0\t2633617\t0\t0\n"
    "1\t3100001\t1\t0\n";

static void write_fixture(const char *path, const char *content)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    fputs(content, f);
    fclose(f);
}

/* TC1 + TC2: Load default db.tsv, lookup MTP3550 ISSI / unknown ISSI */
static void tc1_tc2_basic_lookup(void)
{
    printf("\n[TC1+TC2] basic load + lookup\n");
    const char *path = "/tmp/tetra_db_tb_1.tsv";
    write_fixture(path, DEFAULT_TSV);

    EXPECT_EQ(tetra_db_load(path), 0, "tetra_db_load returns 0");
    EXPECT_EQ(tetra_db_count(0), 1, "ISSI count == 1");
    EXPECT_EQ(tetra_db_count(1), 1, "GSSI count == 1");

    tetra_db_entry_t e;
    int hit = tetra_db_lookup(0x282F91, 0, &e);
    EXPECT_EQ(hit, 1, "lookup MTP3550 ISSI 0x282F91 → hit");
    EXPECT_EQ(e.profile_id, 0, "MTP3550 profile_id == 0");
    EXPECT_EQ(e.slot, 0, "MTP3550 slot == 0");
    EXPECT_EQ(e.entity_type, 0, "MTP3550 entity_type == 0 (ISSI)");

    int miss = tetra_db_lookup(0x123456, 0, NULL);
    EXPECT_EQ(miss, 0, "lookup unknown ISSI 0x123456 → miss");

    int gssi_hit = tetra_db_lookup(0x2F4D61, 1, &e);
    EXPECT_EQ(gssi_hit, 1, "lookup default GSSI 0x2F4D61 → hit");
    EXPECT_EQ(e.entity_type, 1, "default GSSI entity_type == 1");
}

/* TC3: alloc(unknown ISSI) → hit + readback file */
static void tc3_alloc_persists(void)
{
    printf("\n[TC3] alloc + persist\n");
    const char *path = "/tmp/tetra_db_tb_3.tsv";
    write_fixture(path, DEFAULT_TSV);
    EXPECT_EQ(tetra_db_load(path), 0, "load fixture");

    int slot = tetra_db_alloc(0xCAFE42, 0, 0);
    EXPECT_TRUE(slot >= 0, "alloc 0xCAFE42 returns valid slot");

    tetra_db_entry_t e;
    EXPECT_EQ(tetra_db_lookup(0xCAFE42, 0, &e), 1, "lookup 0xCAFE42 → hit");
    EXPECT_EQ(e.profile_id, 0, "0xCAFE42 profile == 0");

    /* Read back from disk (re-load fresh into the singleton). */
    EXPECT_EQ(tetra_db_load(path), 0, "re-load TSV from disk");
    EXPECT_EQ(tetra_db_lookup(0xCAFE42, 0, NULL), 1,
              "0xCAFE42 persisted in TSV");
    EXPECT_EQ(tetra_db_count(0), 2, "ISSI count after alloc == 2");
}

/* TC4: alloc 5x distinct entries */
static void tc4_alloc_many(void)
{
    printf("\n[TC4] alloc 5 entries\n");
    const char *path = "/tmp/tetra_db_tb_4.tsv";
    write_fixture(path, DEFAULT_TSV);
    EXPECT_EQ(tetra_db_load(path), 0, "load fixture");

    uint32_t ids[5] = { 0x111111, 0x222222, 0x333333, 0x444444, 0x555555 };
    for (int i = 0; i < 5; i++) {
        int slot = tetra_db_alloc(ids[i], 0, 0);
        EXPECT_TRUE(slot >= 0, "alloc returned valid slot");
    }
    for (int i = 0; i < 5; i++) {
        EXPECT_EQ(tetra_db_lookup(ids[i], 0, NULL), 1, "lookup id hits");
    }
    EXPECT_EQ(tetra_db_count(0), 1 + 5, "total ISSI count == 6");
}

/* TC5: external edit + reload */
static void tc5_reload_on_mtime(void)
{
    printf("\n[TC5] reload on mtime change\n");
    const char *path = "/tmp/tetra_db_tb_5.tsv";
    write_fixture(path, DEFAULT_TSV);
    EXPECT_EQ(tetra_db_load(path), 0, "initial load");

    /* No change → reload is a no-op. */
    int rv0 = tetra_db_reload();
    EXPECT_EQ(rv0, 0, "reload(unchanged) returns 0");

    /* External edit: rewrite TSV with one extra row, then bump mtime. */
    const char *extended =
        "0\t2633617\t0\t0\n"
        "1\t3100001\t1\t0\n"
        "2\t9999999\t0\t0\n";
    write_fixture(path, extended);
    /* Force mtime to "now+5" so reload definitely sees a change even on
     * filesystems with 1-s mtime granularity. */
    struct stat st;
    stat(path, &st);
    struct utimbuf ut;
    ut.actime  = st.st_atime + 5;
    ut.modtime = st.st_mtime + 5;
    utime(path, &ut);

    int rv1 = tetra_db_reload();
    EXPECT_EQ(rv1, 1, "reload(changed) returns 1");
    EXPECT_EQ(tetra_db_lookup(9999999, 0, NULL), 1,
              "new entry visible after reload");
}

/* TC6: profile 0 decode */
static void tc6_profile0(void)
{
    printf("\n[TC6] profile 0 fields\n");
    const tetra_db_profile_t *p = tetra_db_profile(0);
    EXPECT_TRUE(p != NULL, "profile 0 pointer non-NULL");
    EXPECT_EQ(p->bits,          0x0000088Fu, "profile 0 raw bits == 0x088F");
    EXPECT_EQ(p->gila_class,    4,           "profile 0 gila_class == 4");
    EXPECT_EQ(p->gila_lifetime, 1,           "profile 0 gila_lifetime == 1");
    EXPECT_EQ(p->permit_voice,  1,           "profile 0 permit_voice == 1");
    EXPECT_EQ(p->permit_data,   1,           "profile 0 permit_data == 1");
    EXPECT_EQ(p->permit_reg,    1,           "profile 0 permit_reg == 1");
    EXPECT_EQ(p->valid,         1,           "profile 0 valid == 1");

    /* Profiles 1..5 reset to invalid. */
    for (int i = 1; i < TETRA_DB_MAX_PROFILES; i++) {
        const tetra_db_profile_t *q = tetra_db_profile(i);
        EXPECT_TRUE(q != NULL, "profile i pointer non-NULL");
        EXPECT_EQ(q->valid, 0, "profile i valid == 0");
    }

    /* Out-of-range → NULL. */
    EXPECT_TRUE(tetra_db_profile(TETRA_DB_MAX_PROFILES) == NULL,
                "profile out-of-range → NULL");
}

/* TC7: M2 bit-identity guard — produce the same fields the X.2 fixed replica
 * would have written for the MTP3550 + Default-Group baseline. */
static void tc7_m2_bit_identity(void)
{
    printf("\n[TC7] M2 bit-identity guard\n");
    const char *path = "/tmp/tetra_db_tb_7.tsv";
    write_fixture(path, DEFAULT_TSV);
    EXPECT_EQ(tetra_db_load(path), 0, "load M2 baseline");

    tetra_db_entry_t issi;
    EXPECT_EQ(tetra_db_lookup(0x282F91, 0, &issi), 1, "MTP3550 ISSI hit");
    const tetra_db_profile_t *p = tetra_db_profile(issi.profile_id);
    EXPECT_TRUE(p != NULL, "profile pointer ok");

    tetra_db_entry_t gssi;
    EXPECT_EQ(tetra_db_lookup(0x2F4D61, 1, &gssi), 1, "default GSSI hit");

    /* Reproduce the X.2 stage_accept_body() field set. */
    EXPECT_EQ(p->gila_class,    4, "M2: gila_class    == 4");
    EXPECT_EQ(p->gila_lifetime, 1, "M2: gila_lifetime == 1");
    EXPECT_EQ(gssi.entity_id,   0x2F4D61u, "M2: GILA_GSSI    == 0x2F4D61");
}

int main(void)
{
    printf("tb_tetra_db — Phase X.3 unit tests\n");
    printf("==================================\n");

    tc1_tc2_basic_lookup();
    tc3_alloc_persists();
    tc4_alloc_many();
    tc5_reload_on_mtime();
    tc6_profile0();
    tc7_m2_bit_identity();

    printf("\n==================================\n");
    printf("Result: %d PASS, %d FAIL\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
