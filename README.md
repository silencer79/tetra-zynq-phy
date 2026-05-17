# tetra-zynq-phy

**TETRA Base Station Stack für LibreSDR (Zynq-7020 + AD9361)** — Verilog-2001 RTL, ARM-SW (Cortex-A9), Python/Shell-Tooling.

Referenz-Standard: **ETSI EN 300 392-2** (TETRA V+D Air Interface).

---

> **AI-Assisted Development — Experimental Project**
>
> RTL, Testbenches, Scripts und Dokumentation entstanden im Zusammenspiel mit
> [Claude](https://www.anthropic.com/claude) via [Claude Code](https://github.com/anthropics/claude-code).
> Forschungs-/Amateurfunk-Kontext. Nicht für Produktions- oder sicherheitskritische Anwendungen.

---

## Milestone-Status (Stand 2026-05-17)

| Meilenstein | Ziel | Status |
|-------------|------|--------|
| **M1** | MS sieht BS, RACH sichtbar | ✅ HW-verifiziert (MTP3550, 41/42 CRC-OK) |
| **M2** | MS bucht sich ein | ✅ HW-verifiziert 2026-04-25 (1:1 Demand→Accept, kein Retry-Loop) |
| **M3** | Gruppenruf mit Voice-Relay | ✅ **HW-verifiziert 2026-05-17** — UL-NUB-Capture (Phase C, `8b0737e`) + SW BS-TCH/S Codec + DL Voice-Filler-Mailbox (Phase 7 G.8); BFI 3-7 % @ NUB_SYNC_THRESH=11, OpenEAR-Audio durchgängig. **SW-resident codec statt RTL voice-relay.** Offen: D-CONNECT-Retransmit-Rate ~30 % (worst 3.6 s setup) |
| **M4** | Einzelrufe + Paging | 🟡 Individual-Call-Routing in `tetra_call_fsm` integriert (group_gssi vs target_issi), on-air noch nicht systematisch verifiziert |

**M2 erreicht (2026-04-25 12:18):** Replik des D-LOCATION-UPDATE-ACCEPT MM-Body hat den Re-Demand-Loop gebrochen. Schlüssel-Fixes (Build `26191b4`):
- 102-bit MM body: `p_ssi=0`, `p_ae=0`, `p_sc=0`, `p_esi=1` (ESI=StayAlive), Type-3 GroupIdentityLocationAccept (id=5, length=58) mit GILA (GSSI=0x2F4D61, attach_lifetime=1, class_of_usage=4)
- `random_access_flag=0` im SCH/F Accept (Pre-Reply behält RA=1)

Counter-Beweis nach Deploy: `0x190 = 0x0001_0001` (1 Demand → 1 Accept, 1:1), `0x198 = 0x0000_0002` (Pre-Reply + Accept on-air), keine Drops, kein erneutes Demand. Vorher: 72 Demands → 53 Accepts → endlose Retries.

Details in `docs/PROTOCOL.md §9` und `docs/references/captures_external_bs_2026-04-25/README.md`.

---

## Plattform

| Komponente | Wert |
|-----------|------|
| FPGA | Xilinx Zynq-7020 (XC7Z020-CLG484) |
| RF | Analog Devices AD9363 (AD9361-kompatibel) |
| Board | LibreSDR Rev.5 (192.168.2.183, OpenWiFi-Kernel) |
| Toolchain | Vivado 2022.2, iverilog + vvp, `arm-linux-gnueabihf-gcc` |
| HF-Band | 400 MHz (Band 4), DL 438.25 MHz / UL 428.25 MHz (10 MHz Duplex) |
| Test-MS | Motorola MTP3550 |

## Architektur-Entscheidung (2026-04-22)

**FPGA-heavy Stack:** MAC/MLE/CMCE-Logik läuft als RTL-FSMs im PL, nicht auf ARM. Response-Latenz deterministisch innerhalb 1 TDMA-Slot (14.17 ms). ARM hält nur Subscriber-/Group-DB + Admin. Details in `docs/ARCHITECTURE.md`.

## Repository-Struktur

```
tetra-zynq-phy/
├── rtl/ # Verilog-2001 RTL
│ ├── infra/ # Clock/Reset, AXI-Lite, DMA
│ ├── rx/ # RX: Frontend, Demod, Sync, Timing, UL-RA-Chain
│ ├── tx/ # TX: Mod, RRC, Burst-Builder, SDB/NDB-Encoder
│ ├── lmac/ # LMAC: Coding, MLE-FSM, MAC-RESOURCE-Builder, Session-Table
│ ├── tetra_ad9361_axis_adapter.v
│ ├── tetra_system_top.v # PS+PL-Integration (Vivado BD)
│ └── tetra_zynq_top.v # PL-Top
├── tb/ # Testbenches (iverilog + Vivado xsim)
│ ├── sim_models/ # Xilinx-Primitive-Sim-Modelle
│ └── vectors/ # Python-generierte Test-Vektoren
├── sw/ # ARM-SW (Cross-Compile)
│ ├── tetra_hal.c/.h # AXI-HAL, SYSINFO, Schedule-Init
│ ├── tetra_sysinfo.c # DL-Daemon (SYSINFO/BNCH/MCCH/NDB-Filler)
│ ├── tetra_ul_mon.c # UL-MAC-ACCESS-Monitor-Daemon
│ └── tetra_db_mgr.c # Subscriber-DB (geplant)
├── scripts/ # Build, Deploy, Decode, Test
│ ├── deploy.sh # Build → Convert → Compile → Upload → [Init]
│ ├── tetra_ctrl.sh # Board-Control (full_init, rf_loopback, monitor)
│ ├── ad9361_init.sh # AD9361-Init (wird von full_init gerufen)
│ ├── decode_dl.py # Voll-DL-Decoder (MAC/LLC/MLE/MM)
│ ├── decode_ul.py # UL-RA-Decoder
│ ├── decode_ul_raw.py # Raw-92-Bit-Parser für tetra_ul_mon.log
│ ├── schedule.py # TX-Schedule-Generator
│ └── run_all_tests.sh # iverilog-TB-Runner
├── constraints/ # Vivado XDC
├── docs/ # Konsolidierte Doku (5 Dateien)
│ ├── ARCHITECTURE.md # RTL/SW-Stack, Modul-Status, Ressourcen, Meilensteine
│ ├── HARDWARE.md # Plattform, AD9361, AXI-Regs, CDC, Timing
│ ├── PROTOCOL.md # TETRA-Protokoll, ETSI, bluestation/osmo/SDRSharp-Analyse
│ └── OPERATIONS.md # Deploy, Test, Debugging, Troubleshooting
├── adi-hdl/ # Analog Devices HDL-Bibliothek (git submodule)
└──.ralph/ # Kevin ↔ Ralph Arbeits-Kanal (separat)
```

## Doku-Navigation

Alle inhaltliche Doku in 4 konsolidierten Dateien unter `docs/`:

| Dokument | Inhalt |
|----------|--------|
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | RTL/SW-Stack, Modulbaum, Meilensteine M1-M4, TDMA-Timebase-Plan, Modul-Status, Ressourcen, Bug-Historie |
| **[docs/HARDWARE.md](docs/HARDWARE.md)** | LibreSDR, AD9361, `axi_ad9361`-IP-Integration, Board-Init, kritische HW-Findings, CDC, Timing, AXI-Register-Map |
| **[docs/PROTOCOL.md](docs/PROTOCOL.md)** | TETRA-Protokoll-Layer, ETSI-Ref, SDRSharp-Plugin-Reverse-Engineering, osmo-tetra, bluestation-Audit, Registration-Blocker-Analyse |
| **[docs/OPERATIONS.md](docs/OPERATIONS.md)** | Deploy-Pipeline (`deploy.sh`), RF-Loopback, Test-Strategie, Live-Debugging, Troubleshooting |

Der Kevin↔Ralph-Arbeits-Kanal liegt separat in `.ralph/` (chat, fix_plan, AGENT-Config) — nicht Teil der öffentlichen Doku.

## Quick Start

### Voraussetzungen

```bash
sudo apt install iverilog sshpass python3 python3-pip
# Vivado 2022.2 + SDK (für Synthese + ARM-Cross-Compile)
source /opt/Xilinx/Vivado/2022.2/settings64.sh
```

### Build + Deploy

```bash
git clone --recurse-submodules https://github.com/silencer79/tetra-zynq-phy.git
cd tetra-zynq-phy

# Voller Deploy (Build + Convert + SW + Upload + Init)
./scripts/deploy.sh --init

# Board-Status
./scripts/tetra_ctrl.sh monitor
```

### Unit-Sims

```bash
./scripts/run_all_tests.sh
```

### DL-Capture dekodieren

```bash
# RTL-SDR-Capture auf DL-LO (438.346625 MHz, offset -96625 Hz)
python3 scripts/decode_dl.py --sr 250000 --offset -96625 <capture.wav> --max-bursts 3000
```

Details: `docs/OPERATIONS.md`.

## Ressourcen-Utilization (Zynq-7020, Stand 2026-04-25)

| Resource | Genutzt | % |
|----------|---------|---|
| LUT | ~12,000 | ~23% |
| FF | ~25,000 | ~24% |
| DSP48E1 | ~10 | ~5% |
| BRAM18k | ~5 | ~2% |

Headroom für M3 (Gruppenruf) + M4 (Paging).

## Architektur-Inspiration + Referenzen

- **tetra-bluestation** (MidnightBlueLabs, Apache-2.0) — Rust-BS-Referenz-Implementierung
- **osmo-tetra** (Harald Welte) — Open-Source Decoder, Gitea
- **SDRSharp.Tetra.dll** — Windows-Plugin (reverse-engineered)
- **ETSI EN 300 392-2** — TETRA V+D Air Interface (Haupt-Spec)
- **Analog Devices HDL-Bibliothek** (BSD-1-Clause) — `adi-hdl/` submodule

## Lizenz

- RTL (`rtl/`), Testbenches (`tb/`), Scripts (`scripts/`), Constraints — MIT License
- `adi-hdl/` submodule — BSD-1-Clause (Analog Devices Inc.)
