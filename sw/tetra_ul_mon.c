/*
 * tetra_ul_mon.c — UL MAC-ACCESS PDU mailbox monitor (Task #37 bring-up)
 *
 * Programs the cell extended-scrambling seed into REG_UL_SCRAMB_INIT and
 * polls REG_UL_PDU_STATUS for parsed MS RA-burst fields.  Each CRC-OK PDU
 * is printed as one line; the sticky valid is W1C'd via REG_UL_PDU_CTRL.
 *
 * Seed formula (EN 300 392-2 §8.2.5.2, TMO cell-identity):
 *   init = (MCC<<22) | (MNC<<8) | (CC<<2) | 3
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
#include <signal.h>
#include <getopt.h>
#include <time.h>
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

static volatile int g_stop = 0;
static void on_sigint(int sig) { (void)sig; g_stop = 1; }

static uint32_t cell_scramb_seed(uint16_t mcc, uint16_t mnc, uint8_t cc)
{
    return ((uint32_t)(mcc & 0x3FF) << 22)
         | ((uint32_t)(mnc & 0x3FFF) << 8)
         | ((uint32_t)(cc  & 0x3F)   << 2)
         | 3u;
}

static void usage(const char *a0)
{
    fprintf(stderr,
        "Usage: %s [--mcc N] [--mnc N] [--cc N] [--poll-ms N] [--seed HEX]\n"
        "  Defaults: mcc=901 mnc=9998 cc=49 poll-ms=10\n"
        "  --seed overrides the computed SCRAMB_INIT (32-bit hex)\n",
        a0);
}

int main(int argc, char *argv[])
{
    uint16_t mcc     = 901;
    uint16_t mnc     = 9998;
    uint8_t  cc      = 49;
    uint32_t seed    = 0;
    int      seed_override = 0;
    int      poll_ms = 10;

    enum { OPT_POLL = 256, OPT_SEED };
    static struct option lo[] = {
        {"mcc",     required_argument, NULL, 'm'},
        {"mnc",     required_argument, NULL, 'n'},
        {"cc",      required_argument, NULL, 'c'},
        {"poll-ms", required_argument, NULL, OPT_POLL},
        {"seed",    required_argument, NULL, OPT_SEED},
        {"help",    no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "m:n:c:h", lo, NULL)) != -1) {
        switch (opt) {
        case 'm': mcc = (uint16_t)strtoul(optarg, NULL, 0); break;
        case 'n': mnc = (uint16_t)strtoul(optarg, NULL, 0); break;
        case 'c': cc  = (uint8_t) strtoul(optarg, NULL, 0); break;
        case OPT_POLL: poll_ms = atoi(optarg); if (poll_ms < 1) poll_ms = 1; break;
        case OPT_SEED: seed = (uint32_t)strtoul(optarg, NULL, 16); seed_override = 1; break;
        case 'h': default: usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }

    if (!seed_override) seed = cell_scramb_seed(mcc, mnc, cc);

    tetra_hal_t hal = {0};
    if (tetra_hal_init(&hal) < 0) return 1;

    printf("tetra_ul_mon: MCC=%u MNC=%u CC=%u  scramb_init=0x%08X  poll=%dms\n",
           mcc, mnc, cc, seed, poll_ms);

    /* Program cell scrambler seed (clk_axi→clk_sys CDC, 2-FF synced) */
    tetra_reg_write(&hal, REG_UL_SCRAMB_INIT, seed);
    uint32_t seed_rb = tetra_reg_read(&hal, REG_UL_SCRAMB_INIT);
    if (seed_rb != seed) {
        fprintf(stderr, "WARN: SCRAMB_INIT readback 0x%08X != 0x%08X\n",
                seed_rb, seed);
    }

    /* Clear any pre-existing sticky from earlier runs */
    tetra_reg_write(&hal, REG_UL_PDU_CTRL, 1u);

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);

    struct timespec ts = { .tv_sec = 0, .tv_nsec = poll_ms * 1000000L };
    uint16_t last_count = 0;
    int first = 1;
    unsigned long loops = 0;

    while (!g_stop) {
        uint32_t status = tetra_reg_read(&hal, REG_UL_PDU_STATUS);
        if (UL_STATUS_VALID(status)) {
            /* REG_UL_PDU_SSI now holds the full 24-bit MAC-ACCESS address
             * (bluestation `mac_access.rs::from_bitbuf`).  Mask 0xFFFFFF —
             * the legacy 0x3FF mask aliased every Motorola 0x282xxx ISSI
             * onto ssi=523 and made D-LOC-UPDATE-ACCEPT replies unaddressable.
             */
            uint32_t ssi    = tetra_reg_read(&hal, REG_UL_PDU_SSI) & 0xFFFFFFu;
            uint32_t raw0   = tetra_reg_read(&hal, REG_UL_PDU_RAW_0);
            uint32_t raw1   = tetra_reg_read(&hal, REG_UL_PDU_RAW_1);
            uint32_t raw2   = tetra_reg_read(&hal, REG_UL_PDU_RAW_2) & 0x0FFFFFFFu;

            uint8_t  pdu_type = UL_STATUS_PDU_TYPE(status);
            uint8_t  fill     = UL_STATUS_FILL_BIT(status);
            uint8_t  enc      = UL_STATUS_ENC_MODE(status);
            uint8_t  at       = UL_STATUS_ADDR_TYPE(status);
            uint8_t  optf     = UL_STATUS_OPT_FLAG(status);
            uint8_t  frag     = UL_STATUS_FRAG_FLAG(status);
            uint8_t  resreq   = UL_STATUS_RES_REQ(status);
            uint16_t count    = UL_STATUS_PDU_COUNT(status);

            time_t now = time(NULL);
            struct tm *tm = localtime(&now);
            char tbuf[32];
            strftime(tbuf, sizeof(tbuf), "%H:%M:%S", tm);

            printf("[%s] #%u pdu=%u fill=%u enc=%u at=%u ssi=%u (0x%06X) "
                   "opt=%u frag=%u resreq=%u raw=%07X%08X%08X",
                   tbuf, count, pdu_type, fill, enc, at, ssi, ssi,
                   optf, frag, resreq,
                   raw2, raw1, raw0);
            if (!first && count != (uint16_t)(last_count + 1))
                printf("  [gap last=%u]", last_count);
            printf("\n");

            /* Phase 7 F.3 — second pretty-print line: decoded LLC/MLE/MM
             * type triple + current reassembly counters.  These are
             * snapshotted by the AXI-Lite mailbox on the same ul_pdu_valid
             * pulse so the values correspond to the PDU printed above. */
            uint32_t status2 = tetra_reg_read(&hal, REG_UL_PDU_STATUS_2);
            uint32_t rstats  = tetra_reg_read(&hal, REG_REASSEMBLY_STATS);
            uint32_t llc_t   = UL_STATUS2_LLC_TYPE(status2);
            uint32_t mle_d   = UL_STATUS2_MLE_DISC(status2);
            uint32_t mm_pt   = UL_STATUS2_MM_PDU_TYPE(status2);
            uint32_t r_ok    = REASSEMBLY_STATS_REASS(rstats);
            uint32_t r_drop  = REASSEMBLY_STATS_DROP(rstats);
            const char *llc_s = (llc_t == 0x0) ? "BL-ADATA" :
                                (llc_t == 0x1) ? "BL-DATA"  :
                                (llc_t == 0x2) ? "BL-UDATA" :
                                (llc_t == 0x3) ? "BL-ACK"   : "?";
            const char *mle_s = (mle_d == 1) ? "MM"  :
                                (mle_d == 2) ? "CMCE":
                                (mle_d == 4) ? "SNDCP/Pad" : "?";
            printf("        llc=%u(%s) mle_disc=%u(%s) mm_pdu_type=%u  "
                   "reass_ok=%u drop=%u\n",
                   llc_t, llc_s, mle_d, mle_s, mm_pt, r_ok, r_drop);
            fflush(stdout);

            last_count = count;
            first = 0;

            /* W1C clear sticky — hw-set-wins, so if another PDU arrives
             * same cycle we won't lose it. */
            tetra_reg_write(&hal, REG_UL_PDU_CTRL, 1u);
        }

        /* Heartbeat every ~5 s so operator sees the tool is alive */
        loops++;
        if ((loops % (5000 / poll_ms)) == 0) {
            printf(".");
            fflush(stdout);
        }

        nanosleep(&ts, NULL);
    }

    printf("\ntetra_ul_mon: stopped (last pdu_count=%u)\n", last_count);
    tetra_hal_close(&hal);
    return 0;
}
