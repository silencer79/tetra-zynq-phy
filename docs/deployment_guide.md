# Hardware Deployment Guide
**Project:** tetra-zynq-phy
**Target:** LibreSDR (Zynq-7020 + AD9361)
**Last Updated:** 2026-04-17

---

> **Diese Datei ist veraltet.** Die aktuelle Deploy-Dokumentation ist in
> [`deploy_workflow.md`](./deploy_workflow.md).

## Quick Start

```bash
# Build + Deploy (ohne Board-Init)
./scripts/deploy.sh

# Board initialisieren
./scripts/tetra_ctrl.sh full_init

# tetra_sysinfo starten
ssh root@192.168.2.180 'nohup /root/tetra_sysinfo > /tmp/tetra_sysinfo.log 2>&1 &'

# RF Loopback testen
./scripts/tetra_ctrl.sh rf_loopback 430000000 430000000 15 -10
./scripts/tetra_ctrl.sh monitor
```

Für Details siehe [`deploy_workflow.md`](./deploy_workflow.md).

---

## Board-Zugang

| Parameter | Wert |
|-----------|------|
| IP | 192.168.2.180 |
| User | root |
| Passwort | openwifi |
| SSH | `sshpass -p openwifi ssh root@192.168.2.180` |

## Wichtige Pfade auf dem Board

| Pfad | Inhalt |
|------|--------|
| `/lib/firmware/tetra_zynq_phy.bit.bin` | FPGA Bitstream |
| `/root/tetra_sysinfo` | SYSINFO-Writer Binary |
| `/sys/bus/iio/devices/iio:device1/` | AD9361 IIO Sysfs |

## Referenzen

- [`deploy_workflow.md`](./deploy_workflow.md) — Vollständige Deploy-Dokumentation
- [`register_map.md`](./register_map.md) — AXI-Lite Register
- [`hw_setup.md`](./hw_setup.md) — Hardware-Setup
