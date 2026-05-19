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

## Milestone-Status (Stand 2026-05-19)

| Meilenstein | Ziel | Status |
|-------------|------|--------|
| **M1** | MS sieht BS, RACH sichtbar | ✅ HW-verifiziert (MTP3550, 41/42 CRC-OK) |
| **M2** | MS bucht sich ein | ✅ HW-verifiziert 2026-04-25 (1:1 Demand→Accept, kein Retry-Loop) |
| **M3** | Gruppenruf mit Voice-Relay | ✅ **HW-verifiziert** — Phase 7 G.8+ Voice-Pfad live, SW BS-TCH/S Codec, **Phase E2 Soft-Decisions** (2026-05-18, commit `cae5108`): BFI im Median 6 % → 3 % im Air-Test, im 320-Burst Sustained-Sample 7× besser (1 % vs 7 %). MER/SNR-Proxy ~17 dB bei klarem Signal. |
| **M4** | Einzelrufe + Paging | 🟡 Individual-Call-Routing in `tetra_call_fsm` integriert (group_gssi vs target_issi), on-air noch nicht systematisch verifiziert |

**Aktueller Bitstream:** `cae5108` (Phase E2). Slice 98.10 %, WNS +0.114 ns, BFI median ~3 % (Soft-Pfad).

**WebUI** auf `http://192.168.2.90/` mit drei Tabs:
- **Cell Config** — Form mit allen SYSINFO/Cell-Params, editierbare Duplex-Spacing-Tabelle (MS-Codeplug-spezifisch), persistent in `/root/tetra_cell.conf`
- **Live Status** — Auto-Refresh-Dashboard mit RSSI, BFI Soft/Hard, MER-Proxy, NUB-Counter
- **Subscribers** — DB-Management (Sessions / Entities / Policy)

Details: `docs/IST.md` (Stand-Übersicht), `docs/OPERATIONS.md` (Deploy + Test + WebUI), `docs/ARCHITECTURE.md` (Module + Phasen).

---

## Plattform

| Komponente | Wert |
|-----------|------|
| FPGA | Xilinx Zynq-7020 (XC7Z020-CLG484) |
| RF | Analog Devices AD9363 (AD9361-kompatibel) |
| Board | LibreSDR Rev.5 (192.168.2.90, OpenWiFi-Kernel) |
| Toolchain | Vivado 2022.2, iverilog + vvp, `arm-linux-gnueabihf-gcc` |
| HF-Band | 400 MHz (Band 4), DL 438.25 MHz / UL je nach Duplex-Spacing-ID (editierbar in WebUI; Default `0 = -10 MHz` → UL 428.25 MHz) |
| Test-MS | Motorola MTP3550 |

## Architektur-Entscheidung (2026-05-03 — verbindlich)

**FPGA Thin-Signaling:** Sample-rate-Pfad + TDMA-Timing + Voice-Bit-Pipe in
RTL; Call-Control, Subscriber-Management, CMCE-PDU-Building, Voice-Codec
SW-resident im ARM (`tetra_attach_daemon`, `tetra_sysinfo`, `tetra_ul_mon`,
`tetra_call_fsm`, `tetra_voice_pipe`, `tetra_bs_tch_s` etc.). Ursprünglich
geplanter FPGA-heavy-Stack (2026-04-22) wurde aufgrund Slice-Pressure (>97 %)
wieder revidiert — siehe `docs/ARCHITECTURE.md §2.5`.

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
│ ├── tetra_attach_daemon.c # Subscriber-Registration + Call-Control
│ ├── tetra_call_fsm.c # CMCE Call-State-Machine (D-SETUP / D-CONNECT / ...)
│ ├── tetra_voice_pipe.c # UL-NUB → SW-TCH/S-Codec → DL-Voice-Filler
│ ├── tetra_bs_tch_s.c # SW BS TCH/S Channel-Codec (BlueStation-Port)
│ ├── etsi_codec/ # ETSI ACELP-Codec-Sources
│ ├── web/ # WebUI Frontend (HTML + CGIs)
│ └── tetra_db_mgr.c # Subscriber-DB CLI
├── board_autostart/ # systemd-Autostart: tetra_autostart.sh + tetra_cell.conf
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
├── docs/ # Konsolidierte Doku
│ ├── IST.md # Code-Stand zum aktuellen Datum (Source-of-Truth)
│ ├── ARCHITECTURE.md # RTL/SW-Stack, Modul-Status, Ressourcen, Meilensteine
│ ├── HARDWARE.md # Plattform, AD9361, AXI-Regs, CDC, Timing
│ ├── PROTOCOL.md # TETRA-Protokoll, ETSI, bluestation/osmo/SDRSharp-Analyse
│ ├── OPERATIONS.md # Deploy, Test, Debugging, WebUI, Troubleshooting
│ ├── PLAN_voice_channel.md # Phase C + E2 Soft-Decision Plan + Status
│ └── ist/ # Kapitel-Details (RX/TX/LMAC/Mailboxen/AXI-Map/SW-Stack)
├── adi-hdl/, tetra-bluestation/, tetra-kit/ # Externe Submodule (BSD/Apache-Lizenzen)
└──.ralph/ # Kevin ↔ Ralph Arbeits-Kanal (separat)
```

## Doku-Navigation

Inhaltliche Doku in `docs/`:

| Dokument | Inhalt |
|----------|--------|
| **[docs/IST.md](docs/IST.md)** | **Stand-Übersicht zum aktuellen Datum** — Commits-Tabelle, Vivado-Bilanz, Kapitel-Index. Erster Anlaufpunkt für "wo stehen wir gerade?" |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | RTL/SW-Stack, Modulbaum, Meilensteine M1-M4, Architektur-Entscheidung Thin-Signaling, Modul-Status, Ressourcen, Bug-Historie |
| **[docs/HARDWARE.md](docs/HARDWARE.md)** | LibreSDR, AD9361, `axi_ad9361`-IP-Integration, Board-Init, kritische HW-Findings, CDC, Timing |
| **[docs/PROTOCOL.md](docs/PROTOCOL.md)** | TETRA-Protokoll-Layer, ETSI-Ref, SDRSharp-Plugin-Reverse-Engineering, osmo-tetra, bluestation-Audit, Registration-Blocker-Analyse |
| **[docs/OPERATIONS.md](docs/OPERATIONS.md)** | Deploy-Pipeline (`deploy.sh`), WebUI, RF-Loopback, Test-Strategie, Live-Debugging, Troubleshooting |
| **[docs/PLAN_voice_channel.md](docs/PLAN_voice_channel.md)** | Voice-Pfad Plan (Phase C) + Phase E2 Soft-Decisions — Plan-vs-Realität |
| **[docs/ist/](docs/ist/)** | Per-Kapitel-Tiefe: 03 RX-Datapath, 05 TX, 06 LMAC-FSMs, 07 Mailboxen, 08 AXI-Reg-Map, 09 SW-Stack, 10 Scripts, 11 Build, 12 Operational State |

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

## Ressourcen-Utilization (Zynq-7020, Stand 2026-05-19 nach Phase E2)

| Resource | Genutzt | % |
|----------|---------|---|
| LUT | 38,098 | 71.6 % |
| FF | 46,401 | 43.6 % |
| **Slice** | **13,047** | **98.10 %** (sehr eng — siehe `docs/IST.md`) |
| DSP48E1 | 38 | ~17 % |
| BRAM18k+36k | 9 | ~6 % |

**WNS Setup:** +0.114 ns (positiv, knapp) — Phase E2 hat das Soft-Decision-Pipeline-FF-Volumen
(+2940 FF) gegen Slice-Pressure eingetauscht. Weitere RTL-Erweiterungen erfordern
Slice-Cleanup zuerst (siehe Memory `project_fpga_slice_bottleneck`).

## Architektur-Inspiration + Referenzen

- **tetra-bluestation** (MidnightBlueLabs, Apache-2.0) — Rust-BS-Referenz-Implementierung
- **osmo-tetra** (Harald Welte) — Open-Source Decoder, Gitea
- **SDRSharp.Tetra.dll** — Windows-Plugin (reverse-engineered)
- **ETSI EN 300 392-2** — TETRA V+D Air Interface (Haupt-Spec)
- **Analog Devices HDL-Bibliothek** (BSD-1-Clause) — `adi-hdl/` submodule

## Lizenz

- RTL (`rtl/`), Testbenches (`tb/`), Scripts (`scripts/`), Constraints — MIT License
- `adi-hdl/` submodule — BSD-1-Clause (Analog Devices Inc.)
