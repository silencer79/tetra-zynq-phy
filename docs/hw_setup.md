# Hardware Setup — LibreSDR + TETRA PHY

This document describes the hardware requirements and setup procedure for deploying the TETRA PHY/LMAC baseband engine on LibreSDR.

---

## Hardware Requirements

### LibreSDR Board

- **Platform:** LibreSDR with Zynq-7020 (XC7Z020-CLG484)
- **RF Transceiver:** AD9361 (already onboard)
- **Power Supply:** 12V DC, 2A minimum
- **Cooling:** Passive heatsink recommended for continuous operation

### Host Computer (Development Machine)

- **OS:** Linux (Ubuntu 20.04+ recommended)
- **Toolchain:** Xilinx Vivado 2022.2
- **Memory:** 16 GB RAM minimum
- **Storage:** 50 GB free disk space (Vivado project + build artifacts)

### Networking

- **Ethernet:** Gigabit Ethernet connection
- **IP Configuration:**
  - LibreSDR Default: `192.168.2.180` (configurable)
  - Host: Same subnet (e.g., `192.168.2.100`)
- **SSH Access:** Required for deployment

### Optional: JTAG Programmer

For development/debugging (not required for production deployment):

- **Model:** Digilent JTAG-HS3 or compatible
- **Connection:** USB 2.0
- **Alternative:** OpenOCD-compatible programmer

---

## LibreSDR Initial Setup

### Step 1: Verify Board Power-On

```bash
# Connect Ethernet cable
# Connect 12V power supply
# Verify status LEDs:
#   - DONE LED (FPGA configuration status)
#   - Power LEDs (3.3V, 1.8V rails)
```

### Step 2: Network Connectivity

```bash
# Configure host network interface (example for 192.168.2.100)
sudo ip addr add 192.168.2.100/24 dev eth0
sudo ip link set eth0 up

# Test connectivity
ping 192.168.2.180

# SSH access (default password: openwifi)
ssh root@192.168.2.180
# Expected: OpenWiFi Linux shell
```

### Step 3: Verify AD9361 Presence

On the LibreSDR:

```bash
# Check IIO devices
ls /sys/bus/iio/devices/
# Expected: iio:device0 (ad9361-phy)

# Verify libiio
iio_attr -s
# Expected output: ad9361-phy device
```

---

## Software Dependencies (Host)

### Required Packages

```bash
# Ubuntu packages
sudo apt update
sudo apt install -y \
  sshpass \
  openssh-client \
  python3 \
  python3-pip

# Python packages (for ILA analysis)
pip3 install numpy matplotlib
```

### Vivado 2022.2 Installation

Follow Xilinx installation guide. Ensure:

- Vivado Design Suite (WebPACK or full license)
- SDK (for ARM cross-compilation)
- Cable drivers (for JTAG, optional)

**Environment Setup:**

```bash
# Add to ~/.bashrc
export XILINX_VIVADO=/opt/Xilinx/Vivado/2022.2
source $XILINX_VIVADO/settings64.sh
```

---

## FPGA Manager Kernel Support

LibreSDR must boot with FPGA Manager support enabled. The OpenWiFi Linux image includes this by default.

### Verify FPGA Manager

On LibreSDR:

```bash
# Check FPGA Manager
ls /sys/class/fpga_manager/
# Expected: fpga0

# Check firmware loading path
cat /sys/class/fpga_manager/fpga0/firmware
# Expected: path to current bitstream
```

---

## Clock Configuration

### AD9361 Reference Clock

- **Default:** 40 MHz external oscillator (onboard)
- **TETRA Requirement:** 100 MHz baseband clock (internal PLL)

### Zynq PL Clocks

From PS (Processing System):

| Clock | Frequency | Purpose |
|-------|-----------|---------|
| FCLK_CLK0 | 100 MHz | System clock (processing pipeline) |
| FCLK_CLK1 | 200 MHz | AXI Interconnect |
| FCLK_CLK2 | 100 MHz | AXI Lite (register interface) |

**Note:** Clock configuration is handled in Vivado Block Design. No manual setup required.

---

## Power Budget

Estimated power consumption for TETRA PHY design:

| Component | Est. Power |
|-----------|------------|
| Zynq PL (logic) | ~2.5 W |
| Zynq PS (ARM) | ~1.5 W |
| AD9361 (TX+RX) | ~1.0 W |
| Onboard peripherals | ~0.5 W |
| **Total** | **~5.5 W** |

**Cooling:** Adequate for passive heatsink at room temperature.

---

## Troubleshooting

### Network Connectivity Issues

```bash
# Check cable link
ethtool eth0 | grep "Link detected"

# Check IP assignment
ip addr show eth0

# Firewall issues (Ubuntu UFW)
sudo ufw allow from 192.168.2.0/24
```

### FPGA Manager Not Found

If `/sys/class/fpga_manager/` is empty:

1. Kernel was built without FPGA Manager support
2. Reboot with OpenWiFi kernel image
3. Device tree must enable `fpga-full` node

### AD9361 Not Detected

```bash
# Check SPI connection
dmesg | grep ad9361
# Expected: ad9361 probe messages

# Manual driver load (if needed)
modprobe ad9361
```

---

## Next Steps

1. Follow [deploy_workflow.md](./deploy_workflow.md) for bitstream deployment
2. Use [../scripts/ad9361_init.sh](../scripts/ad9361_init.sh) to configure RF settings
3. Run hardware tests via ILA capture

---

## References

- LibreSDR Hardware Manual: [Link]
- AD9361 Data Sheet: [Analog Devices]
- Zynq-7020 Technical Reference Manual: [Xilinx]
