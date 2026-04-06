# Deployment Workflow — TETRA PHY on LibreSDR

This document describes the step-by-step process for deploying the TETRA PHY/LMAC bitstream to LibreSDR using FPGA Manager (dynamic loading without reboot).

---

## Overview

The deployment uses **Option B: FPGA Manager Dynamic Loading** (chosen by Kevin).

**Workflow:**

```
Vivado Build → Bitstream Conversion → Transfer → FPGA Manager Load → AD9361 Config → Test
```

---

## Prerequisites

Before starting, ensure:

1. ✅ LibreSDR is powered on and network-accessible (see [hw_setup.md](./hw_setup.md))
2. ✅ Build successful: `build/tetra_zynq_phy.bit` exists
3. ✅ SSH access to LibreSDR works: `ssh root@192.168.2.180`
4. ✅ FPGA Manager kernel support enabled (OpenWiFi image)

---

## Phase 1: Build Verification

### Step 1.1: Verify Bitstream

```bash
# On Host
ls -lh build/tetra_zynq_phy.bit
# Expected: ~4 MB file

# Check build timestamp
stat build/tetra_zynq_phy.bit
```

### Step 1.2: Verify Probes (ILA Debug)

```bash
ls -lh build/tetra_zynq_phy.ltx
# Expected: ~7 KB file
```

---

## Phase 2: Bitstream Conversion

Convert Vivado `.bit` format to Linux FPGA Manager `.bit.bin` format.

**Prerequisites:**
- ✅ Bitstream: `build/tetra_zynq_phy.bit` (from Phase 1)
- ✅ XSA File: `build/tetra_zynq_phy.xsa` (hardware definition)

### Step 2.1: Generate XSA (if missing)

If the XSA file doesn't exist, export it from the implemented design checkpoint:

```bash
# Check if XSA exists
ls -l build/tetra_zynq_phy.xsa

# If missing, export from checkpoint
source /opt/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source scripts/export_xsa.tcl

# Output: build/tetra_zynq_phy.xsa
```

**What happens:**
- Opens post-implementation checkpoint (`build/post_route.dcp`)
- Exports hardware platform including bitstream
- No re-synthesis required

### Step 2.2: Run Conversion Script

```bash
./scripts/convert_bitstream.sh

# Output: build/tetra_zynq_phy.bit.bin
```

**What happens:**
- Uses Xilinx `bootgen` tool
- Reads XSA file for hardware metadata
- Adds Linux-specific headers for FPGA Manager
- Creates BIN-formatted bitstream

### Step 2.2: Verify Converted Bitstream

```bash
file build/tetra_zynq_phy.bit.bin
# Expected: "data" (binary file)

# Size comparison
ls -lh build/tetra_zynq_phy.bit*
# .bit and .bit.bin should be similar size
```

---

## Phase 3: Transfer to Target

### Step 3.1: Create Firmware Directory

On LibreSDR:

```bash
ssh root@192.168.2.180 "mkdir -p /lib/firmware/tetra"
```

### Step 3.2: Transfer Bitstream

```bash
# Using scp
scp build/tetra_zynq_phy.bit.bin root@192.168.2.180:/lib/firmware/tetra/

# Using rsync (preferred for large files)
rsync -av build/tetra_zynq_phy.bit.bin root@192.168.2.180:/lib/firmware/tetra/
```

### Step 3.3: Transfer ILA Probes (for Debug)

```bash
scp build/tetra_zynq_phy.ltx root@192.168.2.180:/lib/firmware/tetra/
```

---

## Phase 4: FPGA Manager Loading

### Step 4.1: Unload Existing FPGA Configuration

If a bitstream is already loaded:

```bash
ssh root@192.168.2.180 << 'EOF'
# Check current FPGA state
cat /sys/class/fpga_manager/fpga0/state

# If "operating", unload it
echo 0 > /sys/class/fpga_manager/fpga0/flags
EOF
```

### Step 4.2: Load New Bitstream

```bash
ssh root@192.168.2.180 << 'EOF'
# Set firmware name
echo tetra/tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware

# Trigger FPGA configuration
echo 1 > /sys/class/fpga_manager/fpga0/flags

# Wait for configuration
sleep 2

# Verify state
cat /sys/class/fpga_manager/fpga0/state
# Expected: "operating"
EOF
```

### Step 4.3: Verify FPGA Status

```bash
ssh root@192.168.2.180 << 'EOF'
# Check FPGA status
dmesg | tail -20 | grep -i fpga

# Expected: "fpga_manager fpga0: writing tetra_zynq_phy.bit.bin"
EOF
```

---

## Phase 5: AD9361 RF Configuration

The FPGA is now configured, but AD9361 must be initialized for TETRA operation.

### Step 5.1: Configure AD9361

```bash
# Run libiio-based configuration script
ssh root@192.168.2.180 << 'EOF'
cd /lib/firmware/tetra
./ad9361_init.sh --freq 430000000

# Or if script is on host:
# scp scripts/ad9361_init.sh root@192.168.2.180:/tmp/
# ssh root@192.168.2.180 "/tmp/ad9361_init.sh --freq 430000000"
EOF
```

**Parameters set:**
- RX Frequency: 430 MHz (70cm Amateur Band)
- Sample Rate: 4.096 MSPS
- RX Bandwidth: 1.5 MHz (TETRA channel)
- Gain: Manual 40 dB (or AGC)
- LVDS Mode: 2R2T (Full Duplex)

### Step 5.2: Verify AD9361 Settings

```bash
ssh root@192.168.2.180 << 'EOF'
# Check AD9361 frequency
iio_attr -d ad9361-phy -c RX_LO frequency

# Check sample rate
iio_attr -d ad9361-phy -c RX_SAMPLING_FREQUENCY

# Check gain
iio_attr -d ad9361-phy -c RX_GAIN
EOF
```

---

## Phase 6: Register Access Test

### Step 6.1: Direct mmap Access

Test AXI-Lite register interface:

```bash
ssh root@192.168.2.180 << 'EOF'
# Create test program (if not exists)
cat > /tmp/test_regs.c << 'CCODE'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>

#define AXI_LITE_BASE 0x40000000
#define REG_SIZE 0x10000

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
        return 1;
    }

    // Read STATUS register (offset 0x0004)
    uint32_t status = regs[0x0004 / 4];
    printf("STATUS: 0x%08x\n", status);
    printf("SYNC_LOCKED: %d\n", (status >> 0) & 0x1);

    // Read VERSION register (offset 0x0000)
    uint32_t version = regs[0x0000 / 4];
    printf("VERSION: 0x%08x\n", version);

    close(fd);
    return 0;
}
CCODE

# Compile
gcc -o /tmp/test_regs /tmp/test_regs.c

# Run
/tmp/test_regs
EOF
```

**Expected output:**
- STATUS register shows SYNC_LOCKED bit
- VERSION register matches expected value

---

## Phase 7: Hardware Test (ILA Capture)

### Step 7.1: Capture ILA Data

If ILA cores are present in design:

```bash
# On Host: Use hw_deploy.sh (if available)
./scripts/hw_deploy.sh --no-flash --timeout 60000

# Or manually via Vivado Hardware Manager
vivado -mode batch -source scripts/ila_capture.tcl \
  -tclargs --timeout_ms 60000 --out_dir build/ila_data
```

### Step 7.2: Analyze ILA Data

```bash
# Python analysis script
python3 scripts/analyze_ila.py \
  --ila_lvds build/ila_data/ila_lvds_data.csv \
  --ila_sys build/ila_data/ila_sys_data.csv \
  --output build/ila_data/analysis_report.txt
```

---

## Troubleshooting

### FPGA Manager Fails to Load

**Symptom:** `cat /sys/class/fpga_manager/fpga0/state` shows "unknown" or error.

**Checks:**

1. Verify `.bit.bin` format:
   ```bash
   file /lib/firmware/tetra/tetra_zynq_phy.bit.bin
   # Should be valid binary, not raw .bit
   ```

2. Check kernel logs:
   ```bash
   dmesg | grep -i fpga
   # Look for "invalid bitstream" or "header not found"
   ```

3. Try manual conversion:
   ```bash
   # Ensure bootgen ran correctly
   bootgen -w on -process_bitstream bin \
     -image build/tetra_zynq_phy.xsa \
     -o build/tetra_zynq_phy.bit.bin
   ```

### AD9361 Configuration Fails

**Symptom:** `iio_attr` returns "Device not found".

**Checks:**

1. Verify kernel driver:
   ```bash
   lsmod | grep ad9361
   # Should show ad9361_drv
   ```

2. Check IIO device:
   ```bash
   ls /sys/bus/iio/devices/
   # Should show iio:device0 (ad9361-phy)
   ```

3. Reboot if driver not loaded:
   ```bash
   reboot
   ```

### Sync Locked Never Asserts

**Symptom:** STATUS register bit 0 stays 0.

**Checks:**

1. AD9361 RX path enabled?
   ```bash
   iio_attr -d ad9361-phy -c RX_EN
   # Should be 1
   ```

2. Antenna connected to RX port?

3. Signal source transmitting TETRA burst?

4. Check RX frequency:
   ```bash
   iio_attr -d ad9361-phy -c RX_LO frequency
   # Should be 430000000 (or expected frequency)
   ```

---

## Next Steps

1. Run RX path test with signal generator
2. Verify symbol detection (sync_locked_sys asserting)
3. Test TX path (if implemented)
4. Develop PS software for full MAC/PHY stack

---

## Alternative: JTAG Deployment

If FPGA Manager is problematic, use JTAG (slower, but reliable):

```bash
# Program FPGA via JTAG
vivado -mode batch -source scripts/program_fpga.tcl

# Note: Requires JTAG programmer and USB connection
```

---

## Reference

- [FPGA Manager Kernel Documentation](https://www.kernel.org/doc/html/latest/driver-api/fpga/fpga-mgr.html)
- [AD9361 Linux Driver](https://wiki.analog.com/resources/tools-software/linux-drivers/iio-transceiver/ad9361)
- [OpenWiFi Deployment Scripts](https://github.com/open-sdr/openwifi)
