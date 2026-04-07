# Hardware Deployment Guide
**Project:** tetra-zynq-phy
**Target:** LibreSDR (Zynq-7020 + AD9361)
**Last Updated:** 2026-04-07

---

## Overview

This guide covers the process of deploying the TETRA PHY/LMAC bitstream to the LibreSDR hardware and performing initial validation tests.

---

## Prerequisites

### Hardware Required

- ✅ LibreSDR board (Zynq-7020 + AD9361)
- ✅ USB cable (JTAG/UART)
- ✅ SD card (≥4 GB)
- ✅ Antenna (430–440 MHz) or 50Ω terminator
- ✅ Host PC (Linux recommended)

### Software Required

- ✅ Vivado 2022.2 (Hardware Server + Lab Edition)
- ✅ Python 3.8+
- ✅ Serial terminal (minicom / screen / picocom)

### Files Required

| File | Location | Purpose |
|------|----------|---------|
| Bitstream | `build/tetra_zynq_top.bit` | FPGA configuration |
| BIF file | `build/tetra.bif` | Boot image descriptor |
| Hardware definition | `build/tetra.hdf` | For SDK (optional) |
| Boot image | `build/BOOT.BIN` | SD card boot binary |

---

## Step 1: Build Bitstream

### 1.1 Vivado Project Setup

```bash
cd /home/kevin/claude-ralph/tetra
vivado -mode batch -source scripts/vivado_build.tcl
```

**Output:** `build/tetra_zynq_top.runs/impl_1/tetra_zynq_top.bit`

### 1.2 Check Timing Closure

```bash
# Open implemented design
vivado build/tetra_zynq_top.xpr &
# Reports → Timing Summary
```

**Requirement:** All timing constraints met (WNS ≥ 0)

---

## Step 2: Generate Boot Image

### 2.1 Create BIF File

**File:** `build/tetra.bif`
```
the_boot_image:
{
  [bootloader]build/zynq_fsbl.elf
  [processor_type=ps7]build/tetra_zynq_top.bit
}
```

> **Note:** FSBL (First Stage Bootloader) must be generated via SDK

### 2.2 Generate BOOT.BIN

```bash
bootgen -image build/tetra.bif -o build/BOOT.BIN -w on
```

**Output:** `build/BOOT.BIN` (SD card bootable image)

---

## Step 3: Prepare SD Card

### 3.1 Format SD Card

```bash
# Replace /dev/sdX with your SD card device
sudo mkfs.vfat -F 32 -n TETRA /dev/sdX1
```

### 3.2 Copy Boot Image

```bash
# Mount SD card
sudo mount /dev/sdX1 /mnt/sd

# Copy BOOT.BIN
sudo cp build/BOOT.BIN /mnt/sd/

# Unmount
sudo umount /mnt/sd
```

---

## Step 4: Hardware Setup

### 4.1 Jumpers/switches

- **Boot Mode:** SD card boot (JP1: SD)
- **JTAG:** Disabled (for SD boot)

### 4.2 Connections

1. **SD Card:** Insert prepared SD card
2. **USB:** Connect to host PC (JTAG + UART)
3. **Power:** Connect 5V power supply
4. **Antenna:** Connect 430–440 MHz antenna (RX port)

### 4.3 Power Up

1. Apply power (LED should illuminate)
2. Wait ~5 seconds for FSBL to load
3. Check UART output (see Step 5)

---

## Step 5: Serial Console

### 5.1 Connect UART

```bash
# Identify UART device
ls /dev/ttyUSB*
# Typically: /dev/ttyUSB0 or /dev/ttyUSB1

# Connect (115200 baud)
screen /dev/ttyUSB0 115200
```

### 5.2 Expected Output

```
FSBL: Zynq-7000 First Stage Boot Loader
FSBL: Release 2022.2
FSBL: Loading bitstream...
FSBL: Bitstream loaded successfully
FSBL: Starting application...
```

---

## Step 6: JTAG Programming (Alternative)

If SD boot fails, use JTAG direct programming:

### 6.1 Connect Hardware Server

```bash
# Start hardware server
vivado -mode batch -source scripts/program_fpga.tcl
```

### 6.2 Manual Programming

```tcl
# In Vivado TCL Console
open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {build/tetra_zynq_top.bit} [current_hw_device]
program_hw_devices [current_hw_device]
```

---

## Step 7: ILA Debug Capture

### 7.1 ILA Probes (if enabled)

| Signal | Purpose |
|--------|---------|
| `sync_locked_sys` | RX synchronization lock |
| `burst_valid_sys` | Burst detection |
| `rx_valid_lvds` | AD9361 data stream |
| `frame_counter` | TDMA timing |

### 7.2 Capture Procedure

```bash
# Run ILA capture script
vivado -mode batch -source scripts/ila_capture.tcl
```

**Output:** `ila_captures/capture_<timestamp>.wcfg`

### 7.3 Analyze Waveform

```bash
# Open in Vivado
vivado ila_captures/capture_*.wcfg
```

**Expected behavior:**
- `sync_locked_sys` goes HIGH after ~100ms
- `burst_valid_sys` pulses at 14.167 ms intervals (TDMA frame)
- `rx_valid_lvds` continuous during RX

---

## Step 8: AD9361 Initialization

### 8.1 PS Software (C)

**File:** `sw/tetra_ad9361_init.c`

```c
// Enable AD9361 via GPIO
XGpio_Initialize(&gpio, XPAR_AXI_GPIO_0_DEVICE_ID);
XGpio_SetDataDirection(&gpio, 1, 0x0); // Output
XGpio_DiscreteWrite(&gpio, 1, 0x1); // Enable=1

// Wait for PLL lock
while (!(XGpio_DiscreteRead(&gpio, 2) & 0x01));
xil_printf("AD9361 PLL locked\n");
```

### 8.2 Expected Behavior

- AD9361 LED indicates PLL lock
- SPI communication logged via UART
- RX gain settled after ~10ms

---

## Step 9: Validation Tests

### 9.1 RX Path Smoke Test

**Objective:** Verify RX chain works end-to-end

**Procedure:**
1. Connect antenna to RX port
2. Transmit TETRA signal (from known BS or SDR)
3. Observe `sync_locked_sys` assertion
4. Capture ILA trace
5. Check `burst_valid_sys` pulses

**Success Criteria:**
- `sync_locked_sys` goes HIGH within 500ms
- Frame counter increments at correct rate
- No timing violations in ILA

### 9.2 TX Path Loopback Test

**Objective:** Verify TX→RX loopback

**Procedure:**
1. Connect TX output to RX input (via attenuator!)
2. Enable TX via AXI-Lite register
3. Transmit test burst
4. Capture in RX path
5. Compare transmitted vs. received data

**Success Criteria:**
- TX data appears in RX path
- Bit error rate < 10^-3 (before Viterbi)
- Latency measurement within spec

### 9.3 Full-Duplex Test

**Procedure:**
1. Configure separate TX/RX frequencies (10 MHz duplex)
2. Simultaneous TX + RX operation
3. Monitor timing closure
4. Check no interference

---

## Troubleshooting

### Bitstream Won't Load

| Symptom | Cause | Solution |
|---------|-------|----------|
| FSBL hangs | Invalid bitstream | Rebuild in Vivado |
| No UART output | Wrong baud rate | Check 115200 8N1 |
| BOOT.BIN not found | Wrong partition | Format as FAT32 |

### AD9361 Not Responding

| Symptom | Cause | Solution |
|---------|-------|----------|
| PLL unlock LED | Clock issue | Check reference clock |
| No SPI response | GPIO not set | Enable AD9361 via software |
| No RX data | AXI AD9361 not configured | Check Block Design |

### Sync Not Locking

| Symptom | Cause | Solution |
|---------|-------|----------|
| `sync_locked` always 0 | No signal | Check antenna connection |
| Correlation too low | Threshold too high | Adjust `corr_threshold` register |
| No timing reference | NCO not running | Check timing recovery module |

---

## Performance Metrics

### Timing Budget

| Path | Constraint | Actual | Slack |
|------|------------|--------|-------|
| clk_sys → clk_sys | 10 ns (100 MHz) | ~7 ns | +3 ns |
| l_clk → l_clk | 217 ns (4.6 MHz) | ~150 ns | +67 ns |
| CDC (sys ↔ lvds) | Async FIFO | 3 cycles | — |

### Resource Utilization

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | ~5,205 | 53,200 | ~10% |
| FF | ~12,298 | 106,400 | ~12% |
| DSP48 | 4 | 220 | ~2% |
| BRAM18k | ~2 | 280 | ~1% |

---

## Next Steps after Deployment

1. **Field Testing**
   - On-air validation with TETRA MS
   - BER measurement
   - Range testing

2. **Performance Optimization**
   - Power analysis
   - Timing margin improvement
   - Resource optimization

3. **PS Software Development**
   - Full TETRA stack
   - Network management
   - Web interface

---

## Emergency Recovery

### Corrupted Bitstream

If FPGA enters invalid state:

```bash
# Force JTAG reload
vivado -mode batch -source scripts/program_fpga.tcl
```

### Backup Boot Image

**Recommendation:** Keep known-good `BOOT.BIN` backup on SD card

```
BOOT.BIN      # Current image
BOOT.BAK      # Backup image
```

To revert:
```bash
# Rename files on SD card
mv BOOT.BIN BOOT.BAD
mv BOOT.BAK BOOT.BIN
# Reboot board
```

---

## References

- Xilinx UG585: Zynq-7000 TRM
- AD9361 Reference Manual UG-570
- LibreSDR Hardware Documentation
- `scripts/vivado_build.tcl`
- `scripts/program_fpga.tcl`

---

**Last Updated:** 2026-04-07
**Maintained by:** Ralph (autonomous FPGA agent)
**Contact:** Kevin (via `.ralph/chat.md`)
