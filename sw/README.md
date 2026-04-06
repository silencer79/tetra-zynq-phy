# TETRA FPGA Software — Zynq PS Applications

This directory contains software that runs on the ARM Processing System (PS) of the Zynq-7020. These applications interface with the TETRA PHY/LMAC hardware in the FPGA Programmable Logic (PL).

---

## Directory Contents

### `tetra_char_dev.c` — Linux Kernel Character Device Driver

**Purpose:** Provides `/dev/tetra` interface for userspace applications to access FPGA registers.

**Features:**
- Read/write access to AXI-Lite register space
- IOCTL interface for common operations (START_RX, STOP_RX, GET_STATUS)
- Memory-mapped I/O to hardware registers
- Concurrent access protection via mutex

**Build:**

```bash
# Cross-compile for ARM
make KERNEL_SRC=/path/to/zynq-kernel ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-

# Output: tetra_char_dev.ko
```

**Usage:**

```bash
# Load kernel module
insmod tetra_char_dev.ko

# Check device node
ls -l /dev/tetra
# Expected: crw-rw---- 1 root root 247, 0 Apr  6 12:00 /dev/tetra

# Read all registers
cat /dev/tetra
# Output:
# 0000: 0x20260406  (VERSION)
# 0004: 0x00000000  (STATUS)
# 0008: 0x00000000  (CTRL)
# ...

# Write register (enable RX)
echo "0x0008 0x00000001" > /dev/tetra

# Use IOCTL (from C program)
# See example below
```

**Device Tree Entry:**

Add to your board's device tree (`.dts`):

```dts
tetra_phy: tetra-phy@40000000 {
    compatible = "midnightblue,tetra-phy";
    reg = <0x40000000 0x10000>;
    status = "okay";
};
```

---

## Register Map

| Offset | Name       | R/W | Description                           |
|--------|------------|-----|---------------------------------------|
| 0x0000 | VERSION    | R   | Hardware version (YYYYMMDD format)    |
| 0x0004 | STATUS     | R   | Status flags (SYNC_LOCKED, etc.)      |
| 0x0008 | CTRL       | R/W | Control register (RX/TX enable)       |
| 0x000C | RX_FREQ    | R/W | RX LO frequency (Hz)                  |
| 0x0010 | TX_FREQ    | R/W | TX LO frequency (Hz)                  |
| 0x0014 | GAIN       | R/W | RX gain (0-73 dB)                     |
| 0x0018 | SYNC       | R   | Sync detection status                 |

**STATUS Register Bits:**
- Bit 0: `SYNC_LOCKED` — Sync sequence detected
- Bit 1: `RX_ACTIVE` — RX chain enabled
- Bit 2: `TX_ACTIVE` — TX chain enabled
- Bit 3: `FRAME_VALID` — Valid frame received

**CTRL Register Bits:**
- Bit 0: `RX_ENABLE` — Enable RX chain
- Bit 1: `TX_ENABLE` — Enable TX chain
- Bit 31: `RESET` — Global reset (active-high)

---

## Userspace Application Example

```c
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>

#define TETRA_IOC_MAGIC          'T'
#define TETRA_IOCTL_GET_STATUS   _IOR(TETRA_IOC_MAGIC, 0x01, uint32_t)
#define TETRA_IOCTL_START_RX     _IO(TETRA_IOC_MAGIC, 0x04)

int main() {
    int fd = open("/dev/tetra", O_RDWR);
    if (fd < 0) {
        perror("open /dev/tetra");
        return 1;
    }

    // Start RX
    if (ioctl(fd, TETRA_IOCTL_START_RX) < 0) {
        perror("ioctl START_RX");
        close(fd);
        return 1;
    }

    printf("RX started\n");

    // Poll status
    uint32_t status;
    while (1) {
        if (ioctl(fd, TETRA_IOCTL_GET_STATUS, &status) < 0) {
            perror("ioctl GET_STATUS");
            break;
        }

        if (status & 0x01) {  // SYNC_LOCKED
            printf("Sync locked! STATUS=0x%08x\n", status);
            break;
        }

        usleep(100000);  // 100 ms
    }

    close(fd);
    return 0;
}
```

Compile for ARM:

```bash
arm-linux-gnueabihf-gcc -o tetra_test tetra_test.c -static
scp tetra_test root@192.168.2.180:/usr/local/bin/
```

---

## Alternative: Direct mmap Access

If you prefer not to use a kernel module, you can access registers directly via `/dev/mem`:

```c
#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>

#define AXI_LITE_BASE 0x40000000
#define REG_SIZE      0x10000

int main() {
    int fd = open("/dev/mem", O_RDWR);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    volatile uint32_t *regs = mmap(NULL, REG_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd, AXI_LITE_BASE);

    if (regs == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    // Read STATUS
    uint32_t status = regs[0x0004 / 4];
    printf("STATUS: 0x%08x\n", status);

    // Enable RX
    regs[0x0008 / 4] = 0x00000001;

    close(fd);
    return 0;
}
```

**Note:** Requires `root` privileges and CONFIG_STRICT_DEVMEM disabled in kernel.

---

## HAL (Hardware Abstraction Layer)

Future work: Create `tetra_hal.{c,h}` providing:

- Type-safe register access functions
- Bit manipulation macros
- DMA buffer management
- Interrupt handling

This will hide low-level details from upper protocol layers (LMAC/MAC).

---

## Build Instructions

### Prerequisites

- ARM cross-compiler toolchain: `arm-linux-gnueabihf-gcc`
- Zynq kernel headers: Download from Xilinx or OpenWiFi repository
- Build essentials: `make`, `gcc`

### Cross-Compilation

```bash
# Set kernel source path
export KERNEL_SRC=/path/to/zynq-linux

# Build
make

# Output: tetra_char_dev.ko
```

### Installation

```bash
# Copy to target
scp tetra_char_dev.ko root@192.168.2.180:/lib/modules/$(uname -r)/extra/

# On target: Load module
ssh root@192.168.2.180
depmod -a
modprobe tetra_char_dev
```

---

## Debugging

### Kernel Module Logs

```bash
# On target
dmesg | grep tetra
# Expected: "TETRA char device registered at /dev/tetra"

# Enable dynamic debug
echo "module tetra_char_dev +p" > /sys/kernel/debug/dynamic_debug/control
```

### Register Dump

```bash
# Using devmem2 (if kernel module not loaded)
devmem2 0x40000000 w
devmem2 0x40000004 w
devmem2 0x40000008 w
```

### Check Device Node

```bash
ls -l /dev/tetra
stat /dev/tetra
```

---

## References

- [Linux Kernel Driver Documentation](https://www.kernel.org/doc/html/latest/driver-api/)
- [Zynq-7000 Technical Reference Manual](https://www.xilinx.com)
- OpenWiFi Character Device Driver (reference implementation)

---

## License

GPL v2 (same as Linux kernel)
