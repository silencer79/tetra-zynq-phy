/*
 * tetra_attach_daemon.c — Phase X.2 SW-pulled D-LOC-UPDATE-ACCEPT builder
 *
 * Polls the AXI Demand-Push mailbox (Phase X.1, 0x200..0x20C) for a fresh
 * UL-Demand snapshot; when one lands, stages a fixed M2-replica
 * D-LOCATION-UPDATE-ACCEPT body in the AXI Reply-Pull mailbox (Phase X.2,
 * 0x220..0x230) and pulses REG_REPLY_GO.  Then ACKs the demand snapshot to
 * release the HW slot for the next push.
 *
 * In Phase X.2 the use_sw_body toggle is OFF by default — the daemon
 * stages the body but the FPGA continues to use the existing MLE-FSM
 * latches.  Operator can flip REG_REPLY_USE_SW[0] = 1 to switch the FSM
 * to the SW-driven path; bit-identity to the gold reference is preserved
 * because the staged body matches the M2 baseline ({ssi, la=0x0042,
 * addr_type=1, result=0, gila_gssi=0x2F4D61, gila_class=4,
 * gila_lifetime=1, gila_present=1, encryption=0, auth_result=1}).
 *
 * Target: LibreSDR (Zynq-7020), armv7l, gcc cross-compile
 * License: GPL v2
 */

#include "tetra_hal.h"

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
 * does NOT change the on-air ACCEPT bytes. */
#define M2_DEFAULT_LA           0x0042u
#define M2_DEFAULT_ADDR_TYPE    0x1u    /* ETSI Ssi+EventLabel             */
#define M2_DEFAULT_RESULT       0x0u    /* accept                          */
#define M2_DEFAULT_GILA_GSSI    0x2F4D61u
#define M2_DEFAULT_GILA_CLASS   0x4u    /* M2 default                      */
#define M2_DEFAULT_GILA_LIFE    0x1u    /* M2 default                      */
#define M2_DEFAULT_GILA_PRESENT 0x1u
#define M2_DEFAULT_ENCRYPTION   0x0u
#define M2_DEFAULT_AUTH_RESULT  0x1u

#define POLL_INTERVAL_MS        10      /* polling loop pacing             */

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

static void stage_accept_body(tetra_hal_t *hal, uint32_t ssi)
{
    /* Build the 9 valid words; W9..W15 stay zero (reserved Phase X.4). */
    reply_write(hal, 0, ssi & 0x00FFFFFFu);                 /* W0 ssi      */
    reply_write(hal, 1, M2_DEFAULT_LA);                      /* W1 la       */
    reply_write(hal, 2, M2_DEFAULT_ADDR_TYPE);               /* W2 addrtype */
    reply_write(hal, 3, M2_DEFAULT_RESULT);                  /* W3 result   */
    reply_write(hal, 4, M2_DEFAULT_GILA_GSSI);               /* W4 gssi     */
    /* W5: gila_class<<2 | gila_lifetime */
    reply_write(hal, 5, (M2_DEFAULT_GILA_CLASS << 2) |
                         M2_DEFAULT_GILA_LIFE);
    reply_write(hal, 6, M2_DEFAULT_GILA_PRESENT);            /* W6 gilaPres */
    reply_write(hal, 7, M2_DEFAULT_ENCRYPTION);              /* W7 enc      */
    reply_write(hal, 8, M2_DEFAULT_AUTH_RESULT);             /* W8 auth     */

    /* GO pulse — HW-clears after consume */
    tetra_reg_write(hal, REG_REPLY_GO, 0x1u);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    tetra_hal_t hal;
    if (tetra_hal_init(&hal) != 0) {
        fprintf(stderr, "tetra_attach_daemon: HAL init failed\n");
        return 1;
    }

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);

    tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x1u);

    fprintf(stderr, "tetra_attach_daemon: started — USE_SW=1, polling REG_DEMAND_STATUS\n");

    uint32_t serviced = 0;

    while (keep_running) {
        uint32_t status = tetra_reg_read(&hal, REG_DEMAND_STATUS);
        uint32_t pending = status & 0x1u;

        if (pending) {
            /* Read the SSI from W1 (low 24 bits). */
            uint32_t w0 = demand_read(&hal, 0);
            uint32_t w1 = demand_read(&hal, 1);
            uint32_t ssi = w1 & 0x00FFFFFFu;
            uint32_t lut = (w0 >> 15) & 0x7u;
            uint32_t cnt = (w0 >> 18) & 0x7u;

            stage_accept_body(&hal, ssi);

            /* Release the demand snapshot. */
            tetra_reg_write(&hal, REG_DEMAND_ACK, 0x1u);

            serviced++;
            fprintf(stderr,
                    "tetra_attach_daemon: serviced #%u — ssi=0x%06X "
                    "lut=%u count=%u (use_sw=%u)\n",
                    serviced, ssi, lut, cnt,
                    tetra_reg_read(&hal, REG_REPLY_USE_SW) & 0x1u);
        } else {
            struct timespec ts;
            ts.tv_sec  = 0;
            ts.tv_nsec = (long)POLL_INTERVAL_MS * 1000000L;
            nanosleep(&ts, NULL);
        }
    }

    tetra_reg_write(&hal, REG_REPLY_USE_SW, 0x0u);
    fprintf(stderr, "tetra_attach_daemon: exiting — USE_SW=0 (MLE-FSM fallback) (serviced=%u)\n", serviced);
    tetra_hal_close(&hal);
    return 0;
}
