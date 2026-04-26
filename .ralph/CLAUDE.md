# CLAUDE.md — Project: tetra-zynq-phy
## TETRA PHY/LMAC FPGA Baseband Engine for LibreSDR (Zynq-7020 + AD9361)

> Abgeleitet aus der Architektur von [tetra-bluestation](https://github.com/MidnightBlueLabs/tetra-bluestation) (MidnightBlueLabs, Apache-2.0)
> Referenz-Standard: ETSI EN 300 392-2 (TETRA V+D Air Interface)

---

## 1. Projektziel

Implementierung einer **vollständigen TETRA Base Station** auf dem Zynq-7020. Aufgaben sind zwischen PL (FPGA) und PS (ARM Cortex-A9) **gesplittet**:

### FPGA (PL):
- **Physical Layer**: Mod/Demod, Coding, Sync, Burst-Capture
- **Lower MAC**: TDMA-Frame-Timing, Slot-Burst-Mux, AACH, SB1, NULL-PDU, Channel-Coding
- **MAC-Parser RX** (Header inkl. MAC-END-HU)
- **2-Burst-Reassembly** (mm-type-agnostisch)
- **IE-Parser** GroupIdentityLocationDemand-Walker (mm=2)
- **MLE-FSM M2-Pfad**: Registration-Demand → EntityTable+Profile-Lookup → AST-Push → D-LOC-UPDATE-ACCEPT-Build → Detach
- **Subscriber-DB Hot-Cache**: EntityTable + ProfileTable + AST in BRAM
- Aktive Sessions in BRAM (für M2-Anmeldung)

### PS (ARM):
- **Group-Switch (mm=7)**: Reassembly-Output lesen, GroupIdentityUplink-IE parsen, D-ATTACH-DETACH-GRP-ID-ACK bauen, via TX-Mailbox transmittieren
- **CMCE / Group-Call** (Phase G+)
- **Voice-Routing / SDS** (Phase K+)
- **Authentication** (gestubt, später)
- **Admin-UI, Subscriber-DB-Master, Provisioning, Log-Aggregation**
- **DB-Sync** über AXI-Lite Shadow-Window

### PS↔PL-Schnittstelle:
- **TX-PDU-Submit-Mailbox** (BRAM): SW schreibt Reply-PDU-Bytes + Slot-Hint
- **RX-Burst-Stream-FIFO** (BRAM): PL pusht jeden empfangenen Burst (Header + Body + Metadata)
- **AACH-Override-Hint**: SW kann pro Frame AACH-Pattern setzen
- **IRQ**: per-Burst, per-Frame-Boundary, Reassembly-Done

**Architekturentscheidung 2026-04-26 (verbindlich):** FPGA + SW Split — siehe Memory `project_arch_fpga_sw_split.md`. Löst die alte Entscheidung 2026-04-22 ("MAC/MLE/CMCE komplett in RTL", siehe `project_arch_fpga_heavy.md` archiviert) ab.

**Auslöser des Pivots:** FPGA-Slice-Auslastung 97.82%, MLE-FSM allein 10172 LUTs (24% Total), Phase G/Voice/SDS würde +20000 LUTs brauchen — passt nicht.

**Langfristige Vision:** Dual-Protokoll-Baseband-Engine (DMR Tier II + TETRA V+D) mit umschaltbarem Modulations-/Demodulationsmodus über AXI-Lite Register.

---

## 2. Plattform & Hardware

| Komponente         | Spezifikation                                    |
|--------------------|--------------------------------------------------|
| FPGA Board         | LibreSDR (Zynq-7020 XC7Z020-CLG484)             |
| RF Transceiver     | AD9361 (2×2 MIMO, 70 MHz – 6 GHz)               |
| FPGA Ressourcen    | 85k Logic Cells, 220 DSP48E1, 4.9 Mb BRAM       |
| Taktdomänen        | sys_clk 100 MHz, sample_clk 25 kHz (TETRA), axi_clk 100 MHz |
| Interface          | AD9361 ↔ PL via LVDS, PL ↔ PS via AXI-DMA + AXI-Lite |
| Toolchain          | Vivado 2022.2, Verilog-2001 strict               |

---

## 3. TETRA PHY-Parameter (EN 300 392-2)

| Parameter                  | Wert                                    |
|----------------------------|-----------------------------------------|
| Modulation                 | π/4-DQPSK (Differential Quadrature PSK) |
| Symbolrate                 | 18 ksymbol/s                            |
| Bitrate (brutto)           | 36 kbit/s (2 bit/symbol)                |
| Kanalraster                | 25 kHz                                  |
| Pulsformungsfilter         | Root Raised Cosine (RRC), α = 0.35      |
| Frequenzband (Amateurfunk) | 430–440 MHz (70 cm Band, DE)            |
| Duplex-Abstand             | 10 MHz (konfigurierbar)                 |
| TDMA Struktur              | 4 Timeslots/Frame                       |
| Frame-Dauer                | 56.67 ms                                |
| Timeslot-Dauer             | 14.167 ms (255 Symbole)                 |
| Multiframe                 | 18 Frames (1.02 s)                      |
| Hyperframe                 | 60 Multiframes (61.2 s)                 |

---

## 4. Modularchitektur (PL)

### 4.1 Übersicht Signalpfad

```
AD9361 IQ ──► [RX Frontend] ──► [Sync Detect] ──► [Demodulator] ──► [LMAC RX] ──► AXI-DMA ──► PS
                                                                                                │
AD9361 IQ ◄── [TX Frontend] ◄── [Modulator]   ◄── [LMAC TX]    ◄── AXI-DMA ◄── PS            │
                                                                                                ▼
                                                                              AXI-Lite Register Bank
```

### 4.2 Modulbaum

```
tetra_zynq_top.v                     ← Top-Level, Clock-Domänen-Management
├── tetra_ad9361_axis_adapter.v          ← AD9361 LVDS ↔ IQ Samples
│
├── tetra_rx_chain.v                  ← RX-Pfad Container
│   ├── tetra_rx_frontend.v           ← CIC Decimation + RRC Matched Filter
│   ├── tetra_pi4dqpsk_demod.v        ← π/4-DQPSK Differenz-Demodulator
│   ├── tetra_timing_recovery.v       ← Gardner Timing Error Detector + NCO
│   ├── tetra_sync_detect.v           ← Sliding Correlator (Training Sequences)
│   ├── tetra_burst_demux.v           ← TDMA Burst Demultiplexer (4 Slots)
│   └── tetra_frame_counter.v         ← Frame/Multiframe/Hyperframe Zähler
│
├── tetra_tx_chain.v                  ← TX-Pfad Container
│   ├── tetra_pi4dqpsk_mod.v          ← π/4-DQPSK Modulator + Symboltabelle
│   ├── tetra_rrc_filter.v            ← RRC Pulsformung (α=0.35)
│   ├── tetra_burst_mux.v             ← TDMA Burst Multiplexer (4 Slots)
│   ├── tetra_burst_builder.v         ← Burst Assembly (NDB, SB, NUB, CB)
│   ├── tetra_tx_frontend.v           ← CIC Interpolation + DA-Aufbereitung
│   └── tetra_tx_nco.v               ← TX NCO/Mixer für LO-Offset (4.608 MHz, lvds)
│
├── tetra_lmac.v                      ← Lower MAC Container
│   ├── tetra_scrambler.v             ← LFSR Scrambler/Descrambler (p(x) aus ETSI)
│   ├── tetra_interleaver.v           ← Block-Interleaver/Deinterleaver
│   ├── tetra_rcpc_encoder.v          ← Rate-Compatible Punctured Convolutional Encoder (16-state, R=1/3 Mutter)
│   ├── tetra_viterbi_decoder.v       ← 16-State Viterbi Decoder (Soft-Decision)
│   ├── tetra_reed_muller.v           ← (30,14) Reed-Muller Codec für AACH/ACCH
│   ├── tetra_crc16.v                 ← CRC-16-CCITT Generator/Checker
│   └── tetra_steal_detect.v          ← Stealing-Bit Detection (Traffic/Signalling Erkennung)
│
├── tetra_axi_dma_bridge.v            ← PL ↔ PS DMA Interface (MAC-Blöcke ↔ DDR)
├── tetra_axi_lite_regs.v             ← AXI-Lite Register Bank (Steuerung + Status)
└── tetra_clk_reset.v                 ← Reset-Synchronizer, MMCM/PLL Management
```

---

## 5. Detaillierte Modulspezifikationen

### 5.1 tetra_pi4dqpsk_demod.v — π/4-DQPSK Differenz-Demodulator

**Funktion:** Differentielle Demodulation der empfangenen IQ-Samples zu Dibit-Paaren.

**Algorithmus:**
1. Berechne Phase Φ(n) = atan2(Q(n), I(n))
2. Differenzphase ΔΦ(n) = Φ(n) - Φ(n-1)
3. Symbol-Decision basierend auf ΔΦ:
   - ΔΦ ≈ +π/4   → Dibit 00
   - ΔΦ ≈ +3π/4  → Dibit 01
   - ΔΦ ≈ -π/4   → Dibit 10
   - ΔΦ ≈ -3π/4  → Dibit 11

**CORDIC-basierte Implementierung** (kein atan2 LUT):
- CORDIC Vectoring Mode für Phasenberechnung
- 16 Iterationen, 16-bit Phasenauflösung
- Pipeline: 2 Takte Latenz pro Sample

**Ports:**
```verilog
module tetra_pi4dqpsk_demod #(
    parameter IQ_WIDTH     = 16,
    parameter PHASE_WIDTH  = 16,
    parameter CORDIC_ITER  = 16
)(
    input  wire                    clk_sample,    // 18 kHz Symbol-Takt
    input  wire                    rst_n_sample,
    input  wire signed [IQ_WIDTH-1:0] i_in,       // I-Kanal vom RRC Filter
    input  wire signed [IQ_WIDTH-1:0] q_in,       // Q-Kanal vom RRC Filter
    input  wire                    sample_valid,
    output reg  [1:0]              dibit_out,     // Demoduliertes Dibit
    output reg                     dibit_valid,
    output wire signed [PHASE_WIDTH-1:0] phase_error  // Für Timing Recovery
);
```

**Verilog-2001 Konventionen:**
- Ein `always`-Block pro Register
- Explizite Taktdomänen-Suffixe (`_sample`, `_sys`, `_axi`)
- Keine Arrays in Synthese-Code

---

### 5.2 tetra_pi4dqpsk_mod.v — π/4-DQPSK Modulator

**Funktion:** Mapping von Type-5-Bits auf IQ-Symbole mit π/4-Rotation.

**Symboltabelle (ETSI EN 300 392-2, Table 9.1):**
- Gerade Symbole: QPSK-Konstellation (±1, ±1)
- Ungerade Symbole: π/4-rotierte QPSK-Konstellation
- Differentielle Kodierung: Ausgangs-Phase = Eingangs-Phase + Symbol-Phase-Offset

**Implementierung:**
- Phase Accumulator (16 bit)
- Sin/Cos LUT (1024 Einträge × 16 bit, in BRAM)
- Ausgabe: IQ-Samples @ 18 ksymbol/s → Upsampling durch RRC-Filter

**Ports:**
```verilog
module tetra_pi4dqpsk_mod #(
    parameter IQ_WIDTH    = 16,
    parameter PHASE_WIDTH = 16,
    parameter LUT_DEPTH   = 1024
)(
    input  wire                    clk_sample,
    input  wire                    rst_n_sample,
    input  wire [1:0]              dibit_in,      // Type-5 Bits (nach Scrambling)
    input  wire                    dibit_valid,
    output reg signed [IQ_WIDTH-1:0] i_out,       // I-Kanal zum RRC Filter
    output reg signed [IQ_WIDTH-1:0] q_out,       // Q-Kanal zum RRC Filter
    output reg                     sample_valid_out
);
```

---

### 5.3 tetra_sync_detect.v — Synchronisations-Detektor

**Funktion:** Erkennung der TETRA Training Sequences im empfangenen Burst-Strom.

**Training Sequences (ETSI EN 300 392-2, §9.4.4):**
- Normal Training Sequence: 22 Symbole (Mitte NDB)
- Extended Training Sequence: 30 Symbole (Mitte NDB, optional)
- Synchronisation Training Sequence: 38 Symbole (Synchronisation Burst)

**Algorithmus:**
- Sliding Correlator mit gespeicherten Referenz-Sequenzen
- Korrelations-Schwellwert konfigurierbar über AXI-Lite
- Peak-Detection mit Hysterese
- Ausgabe: Slot-Timing-Referenz, Sync-Status

**Ports:**
```verilog
module tetra_sync_detect #(
    parameter CORR_WIDTH   = 24,
    parameter SEQ_LEN_MAX  = 38    // Längste Training Sequence
)(
    input  wire                     clk_sample,
    input  wire                     rst_n_sample,
    input  wire [1:0]               dibit_in,
    input  wire                     dibit_valid,
    // Konfiguration via AXI-Lite
    input  wire [CORR_WIDTH-1:0]    corr_threshold,
    input  wire [1:0]               seq_select,     // 0=Normal, 1=Extended, 2=Sync
    // Ausgänge
    output reg                      sync_found,
    output reg                      sync_locked,     // Stabile Synchronisation
    output reg [7:0]                slot_position,   // Position im Timeslot
    output reg [1:0]                slot_number      // Aktueller Timeslot (0-3)
);
```

---

### 5.4 tetra_viterbi_decoder.v — 16-State Viterbi Decoder

**Funktion:** Soft-Decision Viterbi-Dekodierung des RCPC-kodierten Signalstroms.

**Parameter (ETSI EN 300 392-2, §8.2.3):**
- Mutter-Code: Rate 1/3, Constraint Length K=5 (16 States)
- Generatorpolynome: G1=0x1B, G2=0x19, G3=0x15 (oktal: 33, 31, 25)
- Puncturing-Pattern je nach Kanal (Rate 2/3 für TCH/S, Rate 292/432 für SCH/F)
- Traceback-Tiefe: 5 × (K-1) = 20 (minimum)

**Architektur:**
- Add-Compare-Select (ACS) Unit: 16 parallel Butterfly-Operationen
- Branch Metric Unit: Soft-Decision (3-bit Quantisierung)
- Traceback Memory: Dual-Port BRAM (Ping-Pong)
- Survivor Path Storage: 16 × Traceback-Tiefe

**Ressourcen-Schätzung:**
- ~16 DSP48E1 Slices für ACS
- ~4 BRAM18k für Traceback
- Durchsatz: 1 Trellis-Stufe pro Takt @ 100 MHz

**Ports:**
```verilog
module tetra_viterbi_decoder #(
    parameter STATES       = 16,
    parameter K            = 5,
    parameter SOFT_WIDTH   = 3,
    parameter TRACEBACK    = 20,
    parameter MAX_BLOCK    = 432   // Längster TETRA Block (SCH/F vor Puncturing)
)(
    input  wire                    clk_sys,
    input  wire                    rst_n_sys,
    // Eingang
    input  wire [SOFT_WIDTH-1:0]   soft_bit_0,    // Soft Decision Kanal 0
    input  wire [SOFT_WIDTH-1:0]   soft_bit_1,    // Soft Decision Kanal 1
    input  wire [SOFT_WIDTH-1:0]   soft_bit_2,    // Soft Decision Kanal 2
    input  wire                    input_valid,
    // Puncturing-Konfiguration
    input  wire [2:0]              punct_pattern,  // Wählt Puncturing-Schema
    // Ausgang
    output reg                     decoded_bit,
    output reg                     decoded_valid,
    output reg                     block_done,     // Ende eines MAC-Blocks
    output wire [15:0]             path_metric_min // Für BER-Schätzung
);
```

---

### 5.5 tetra_rcpc_encoder.v — RCPC Convolutional Encoder

**Funktion:** 16-State Faltungskodierer mit konfigurierbarem Puncturing.

**Ports:**
```verilog
module tetra_rcpc_encoder #(
    parameter K = 5
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire        data_in,
    input  wire        data_valid,
    input  wire [2:0]  punct_pattern,    // Puncturing-Schema Auswahl
    input  wire        flush,            // Tail-Bits einfügen
    output reg  [2:0]  coded_bits,       // 3 Kanäle (Mutter-Rate 1/3)
    output reg         coded_valid,
    output reg  [1:0]  punct_out_bits,   // Nach Puncturing: 1 oder 2 Bits gültig
    output reg         punct_valid
);
```

---

### 5.6 tetra_reed_muller.v — (30,14) Reed-Muller Codec

**Funktion:** Kodierung/Dekodierung des AACH/ACCH Broadcast-Blocks (30 Bits im Burst, 14 Informationsbits).

**Referenz:** ETSI EN 300 392-2, §8.2.4.1

**Ports:**
```verilog
module tetra_reed_muller #(
    parameter N = 30,
    parameter K = 14
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    // Encoder
    input  wire [K-1:0] encode_data_in,
    input  wire         encode_valid,
    output reg  [N-1:0] encode_data_out,
    output reg          encode_done,
    // Decoder
    input  wire [N-1:0] decode_data_in,
    input  wire         decode_valid,
    output reg  [K-1:0] decode_data_out,
    output reg          decode_done,
    output reg          decode_error       // Nicht korrigierbar
);
```

---

### 5.7 tetra_burst_demux.v — TDMA Burst Demultiplexer

**Funktion:** Zerlegt den kontinuierlichen Downlink-Strom in einzelne Timeslots und extrahiert die Burst-Felder.

**Normal Downlink Burst (NDB) Struktur (EN 300 392-2, §9.4.4.3.1):**
```
| PA | Freq. Corr. | Block 1 (216 bit) | Training Seq | BB (30 bit) | Block 2 (216 bit) | Guard |
```
- PA: Power Amplifier ramp-up
- Block 1/2: Nutzlast (Type-2 Bits → Kanal-Decodierung → Type-1 MAC Bits)
- Training Sequence: 22 Symbole (Normal) oder 38 Symbole (Sync Burst)
- BB: Broadcast Block (AACH), kodiert mit (30,14) Reed-Muller

**Ports:**
```verilog
module tetra_burst_demux #(
    parameter BLOCK_BITS  = 216,
    parameter BB_BITS     = 30,
    parameter TS_PER_FRAME = 4
)(
    input  wire        clk_sample,
    input  wire        rst_n_sample,
    input  wire [1:0]  dibit_in,
    input  wire        dibit_valid,
    input  wire        sync_locked,
    input  wire [1:0]  slot_number,
    input  wire [7:0]  slot_position,
    // Ausgänge pro Slot
    output reg  [BLOCK_BITS-1:0] block1_data  [0:TS_PER_FRAME-1],
    output reg  [BLOCK_BITS-1:0] block2_data  [0:TS_PER_FRAME-1],
    output reg  [BB_BITS-1:0]    bb_data      [0:TS_PER_FRAME-1],
    output reg  [TS_PER_FRAME-1:0] slot_valid,
    output reg  [1:0]            burst_type    // 0=NDB, 1=SB, 2=NUB
);
```

**Hinweis:** Arrays in Port-Deklaration nur als Platzhalter — in der Synthese-Implementierung werden diese als flache Busse realisiert (4 × 216 = 864 bit etc.), gemäß Verilog-2001-Konvention.

---

### 5.8 tetra_frame_counter.v — Frame/Multiframe/Hyperframe Zähler

**Funktion:** TDMA Frame-Timing gemäß ETSI-Hierarchie.

**Timing:**
- 1 Frame = 4 Timeslots = 56.67 ms
- 1 Multiframe = 18 Frames (Frame 18 = Control Frame)
- 1 Hyperframe = 60 Multiframes

**Ports:**
```verilog
module tetra_frame_counter (
    input  wire        clk_sample,
    input  wire        rst_n_sample,
    input  wire        sync_locked,
    input  wire        frame_pulse,         // 1 Puls pro Frame (von burst_demux)
    output reg [1:0]   timeslot_num,        // 0-3
    output reg [4:0]   frame_num,           // 1-18
    output reg [5:0]   multiframe_num,      // 1-60
    output reg [15:0]  hyperframe_num,
    output reg         is_control_frame,    // frame_num == 18
    output reg         frame_18_slot1       // Timing für BNCH
);
```

---

### 5.9 tetra_scrambler.v — LFSR Scrambler/Descrambler

**Funktion:** Bitweise XOR-Scrambling mit LFSR-generierter Sequenz.

**LFSR-Polynom:** Definiert in ETSI EN 300 392-2, §8.2.5, abhängig von Colour Code und Timeslot-Nummer. Die Initialisierung wird per AXI-Lite konfiguriert.

**Ports:**
```verilog
module tetra_scrambler #(
    parameter LFSR_WIDTH = 32
)(
    input  wire                    clk_sys,
    input  wire                    rst_n_sys,
    input  wire [LFSR_WIDTH-1:0]  lfsr_init,       // Colour Code + Slot-abhängig
    input  wire                    load_init,
    input  wire                    data_in,
    input  wire                    data_valid,
    output reg                     data_out,
    output reg                     data_out_valid
);
```

---

### 5.10 tetra_interleaver.v — Block Interleaver/Deinterleaver

**Funktion:** Block-Interleaving über einen einzelnen Burst-Block (ETSI EN 300 392-2, §8.2.4).

**Architektur:**
- Schreib-Adressgenerator: spaltenweise Schreiben
- Lese-Adressgenerator: zeilenweise Lesen (bzw. umgekehrt für Deinterleaving)
- Dual-Port BRAM als Interleave-Speicher
- Konfigurierbare Block-Größe (216 für NDB, 432 für SCH/F)

**Ports:**
```verilog
module tetra_interleaver #(
    parameter MAX_BLOCK_SIZE = 432
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire        mode,                // 0=Interleave (TX), 1=Deinterleave (RX)
    input  wire [8:0]  block_size,          // Aktuelle Blockgröße
    input  wire        data_in,
    input  wire        data_in_valid,
    output reg         data_out,
    output reg         data_out_valid,
    output reg         block_done
);
```

---

## 6. AXI-Lite Register Map

Basisadresse: 0x43C0_0000 (tetra_axi_lite_regs.v)

| Offset | Name            | R/W  | Beschreibung                                         |
|--------|-----------------|------|------------------------------------------------------|
| 0x00   | CTRL            | RW   | [0] RX_EN [1] TX_EN [2] LOOPBACK [3] RST_CNTRS      |
| 0x04   | STATUS          | RO   | [0] SYNC [1] PLL [2] FIFO_EMPTY [3] FIFO_FULL       |
| 0x08   | VERSION         | RO   | 0x0001_0000 (v1.0)                                   |
| 0x0C   | SYNC_THRESH     | RW   | [7:0] default 20                                     |
| 0x10   | COLOUR_CODE     | RW   | [5:0] Scrambler-Init                                 |
| 0x14   | FRAME_NUM       | RO   | [4:0] Frame Counter                                  |
| 0x18   | SLOT_NUM        | RO   | [1:0] Slot Counter                                   |
| 0x1C   | RX_GAIN         | RW   | [6:0] default 32                                     |
| 0x20   | TX_ATT          | RW   | [7:0] default 40                                     |
| 0x24   | IRQ_ENABLE      | RW   | [4:0] Interrupt-Enable                               |
| 0x28   | IRQ_STATUS      | RW1C | [4:0] Interrupt-Flags                                |
| 0x2C   | DMA_BLK_CNT     | RO   | [15:0] DMA Block Counter                             |
| 0x30   | CRC_ERR_CNT     | RO   | [15:0] CRC Error Counter                             |
| 0x34   | SYNC_LST_CNT    | RO   | [15:0] Sync Lost Counter                             |
| 0x3C   | SCRATCH         | RW   | [31:0] Test-Register                                 |
| 0x40–5C| SB_BKN1[0..7]  | RW   | BSCH Payload (240 bit, 8×32, w7=[15:0])              |
| 0x60–78| SB_BKN2[0..6]  | RW   | BNCH Payload (216 bit, 7×32, w6=[23:0])              |
| 0x7C   | SB_BB           | RW   | AACH Payload (28 bit, [27:0])                        |
| 0x80   | NCO_PHASE_INC   | RW   | [31:0] TX NCO Phase Increment (f×2³²/4608000)       |

---

## 7. AXI-DMA Interface

### 7.1 RX-Pfad (PL → PS)

- **DMA Channel:** S2MM (Stream to Memory-Mapped)
- **Datenformat pro MAC-Block:**
  ```
  [31:30] Slot-Nummer
  [29:28] Burst-Typ (NDB/SB/NUB)
  [27:16] Block-Länge (Bits)
  [15:0]  Frame-Nummer
  [Folgende Words] MAC-Block Daten (Type-1 Bits, Word-aligned)
  ```
- **FIFO-Tiefe:** 2048 Words (8 kB) — puffert ~4 komplette Multiframes
- **Interrupt:** IRQ bei jedem vollständigen MAC-Block

### 7.2 TX-Pfad (PS → PL)

- **DMA Channel:** MM2S (Memory-Mapped to Stream)
- **Datenformat:** Identisch zum RX-Format (Header + Payload)
- **Timing:** PS muss Block spätestens 1 Frame vor Sende-Timeslot bereitstellen
- **Underrun-Handling:** Bei fehlenden TX-Daten wird Idle-Burst gesendet

---

## 8. Entwicklungsphasen

### Phase 1: RX-Only Downlink Monitor (4–6 Wochen)
1. `tetra_ad9361_axis_adapter.v` — ADI IP fabric interface (AXI-Stream adapter)
2. `tetra_rx_frontend.v` — CIC + RRC Filter (wiederverwenden von DMR-Projekt, α anpassen)
3. `tetra_pi4dqpsk_demod.v` — CORDIC-basierter Differenz-Demodulator
4. `tetra_sync_detect.v` — Sliding Correlator für Training Sequences
5. `tetra_burst_demux.v` — Extraktion der Burst-Felder
6. `tetra_frame_counter.v` — TDMA Timing
7. **Testbench:** Empfang eines BlueStation-Downlink-Signals, Vergleich der dekodierten Bits

### Phase 2: LMAC RX — Channel Decoding (3–4 Wochen)
1. `tetra_scrambler.v` — Descrambling
2. `tetra_interleaver.v` — Deinterleaving
3. `tetra_viterbi_decoder.v` — Soft-Decision Viterbi (Hauptaufwand)
4. `tetra_reed_muller.v` — AACH/ACCH Dekodierung
5. `tetra_crc16.v` — FCS-Verifikation
6. `tetra_axi_dma_bridge.v` + `tetra_axi_lite_regs.v` — PS Interface
7. **Testbench:** Ende-zu-Ende RX: IQ → dekodierte MAC-Blöcke über DMA

### Phase 3: TX-Pfad — Downlink-Generierung (3–4 Wochen)
1. `tetra_rcpc_encoder.v` — Faltungskodierer
2. `tetra_interleaver.v` — Interleave-Modus
3. `tetra_scrambler.v` — Scramble-Modus
4. `tetra_burst_builder.v` — Burst Assembly (NDB + Sync Bursts)
5. `tetra_pi4dqpsk_mod.v` — Modulator
6. `tetra_rrc_filter.v` + `tetra_tx_frontend.v` — Pulsformung + CIC Interpolation
7. `tetra_burst_mux.v` — TDMA Multiplexer
8. `tetra_tx_nco.v` — TX NCO/Mixer (LO-Offset gegen DC/LO-Leakage)
9. **Testbench:** Loopback TX→RX, Vergleich mit BlueStation-Referenzsignal

### Phase 4: Integration & Full-Duplex (2–3 Wochen) — ✅ abgeschlossen
1. Full-Duplex Betrieb (gleichzeitig TX + RX auf getrennten Frequenzen)
2. PS Software: Minimal-Stack (SYSINFO Broadcast, Channel Coding) + Diagnose-Tools
3. UL-RA-Burst-Kette komplett in RTL (hardware-verifiziert mit MTP3550, 2026-04-22)
4. Performance-Optimierung (Viterbi-Timing-Fix, WNS 0.000 ns auf clk_fpga_0)

### Phase 5/6: MAC/MLE/Subscriber-DB als RTL-FSMs (2026-04-22 bis 2026-04-26, abgeschlossen)
1. ✅ Subscriber-Shadow-BRAM + ARM `sw/tetra_db_mgr.c` (DB-Pflege + AXI-Writes)
2. ✅ Registration-FSM (M2-Pfad) + EntityTable + ProfileTable + AST
3. ✅ Per-Slot Slot-Content-Mux + WebUI

### Phase 7 ARCH-Pivot (2026-04-26): FPGA + SW Split
**Phase 7 F (Group-Switch in RTL) wurde NICHT live verifiziert** — Air-Test 2026-04-26 NOK, Slice-Druck 97.82%. Der Phase-7-F-Stack wird in Phase H rückgebaut.

### Phase H: FPGA-Refactor + PS↔PL-Schnittstelle (aktuelle Phase)
- **H.0** Slice-Cleanup — F.7-Output-Pfad raus, Group-Code aus MLE-FSM/IE-Parser/Top-Wiring
- **H.1** Bug-1-Diagnose-Counter (3 AXI-Reads für MAC-END-HU-Pfad-Tracing)
- **H.2** Bug-1-Fix (MAC-END-HU klassifiziert nicht — RTL-Bruchstelle nach H.1-Diagnose)
- **H.3** MLE-Trigger korrigieren — Single-Burst-Bypass-Hack ersetzen durch echten Reassembly-Trigger
- **H.4** PS↔PL-Schnittstelle (TX-PDU-Submit-Mailbox + RX-Burst-Stream-FIFO + AACH-Override + IRQ)
- **H.5** Air-Test M2 final mit korrekter MS-Wunsch-GSSI in Accept-Reply

### Phase J: SW-Implementation (nach H.5-PASS, separater Branch)
1. UL-Reassembly-Reader + Group-Switch-Logik (`sw/tetra_mle_groupswitch.c`)
2. D-ATTACH-DETACH-GRP-ID-ACK-PDU-Builder
3. TX-PDU-Submit-Driver
4. RX-Burst-Stream-Driver

### Phase K+: CMCE / Group-Call / Voice / SDS in SW

### Phase 5 (optional): Dual-Protokoll DMR+TETRA
1. Multiplexer-Layer für umschaltbare Modulation (4FSK ↔ π/4-DQPSK)
2. Gemeinsame Blöcke: CIC-Filter, CRC, Timing Recovery
3. Protokollspezifische Blöcke: Symbol-Mapper, Kanalcodierung, Burst-Struktur
4. PROTOCOL_MODE Register zur Laufzeit-Umschaltung

---

## 9. Testbench-Strategie

### 9.1 Unit Tests (pro Modul)
- Vivado Behavioral Simulation
- Referenz-Vektoren: Python-Skripte generieren Testvektoren aus ETSI-Spezifikation
- Self-Checking Testbenches mit `$error`/`$fatal`

### 9.2 Integration Tests
- **BlueStation als Referenz:** BlueStation-Instanz sendet bekanntes Downlink-Signal → IQ-Capture via AD9361 → Vergleich dekodierter MAC-Blöcke
- **Loopback-Test:** TX-Chain → (interner Loopback) → RX-Chain → Bitvergleich

### 9.3 Vivado Automatisierung
```tcl
# Synthese + Implementation automatisieren
source scripts/vivado_build.tcl
# Argumente: PART, TOP_MODULE, CONSTRAINTS_FILE
```

---

## 10. Coding-Konventionen (Verilog-2001 Strict)

1. **Ein `always`-Block pro Register** — keine kombinatorischen Blöcke mit mehreren Registerzuweisungen
2. **Explizite Taktdomänen-Suffixe:** `_sample` (18 kHz), `_sys` (100 MHz), `_axi` (100 MHz)
3. **Reset:** Asynchroner Reset mit Synchronizer (`tetra_clk_reset.v`), Active-Low (`rst_n_*`)
4. **Keine Arrays in Synthese-Code** — flache Busse statt `reg [7:0] memory [0:255]`
5. **Naming:** `snake_case` für Signale, `UPPER_CASE` für Parameter, `tetra_` Prefix für alle Module
6. **Keine `initial`-Blöcke** in Synthese-Code (nur Testbench)
7. **Alle Ports deklariert** — keine impliziten Nets
8. **FSMs:** Separater `always`-Block für State-Register und kombinatorische Next-State-Logik
9. **Pipeline-Dokumentation:** Jede Stufe mit Kommentar `// Pipeline Stage N: <Beschreibung>`

---

## 11. Abhängigkeiten & Referenzen

| Referenz                        | Beschreibung                                           |
|---------------------------------|--------------------------------------------------------|
| ETSI EN 300 392-2 V3.8.1       | TETRA V+D Air Interface (Haupt-Standard)               |
| ETSI TS 100 392-2 V3.9.2       | TETRA V+D TS (neueste Version)                         |
| tetra-bluestation (GitHub)      | Rust-Referenzimplementierung für Protokoll-Verhalten    |
| osmo-tetra / osmo-tetra-sq5bpf | C-Referenz für PHY/LMAC Algorithmen                    |
| LibreSDR Schematic              | AD9361 Pin-Mapping, LVDS Interface                     |
| Xilinx UG585                    | Zynq-7000 Technical Reference Manual                   |
| Xilinx PG021                    | AXI DMA IP Documentation                              |

---

## 12. Offene Fragen / Entscheidungen

- [x] **Soft vs. Hard Decision Viterbi:** Soft-Decision implementiert (5-bit UL, BER/MER 0% in HW).
- [x] **RRC-Filter Taps:** implementiert, validiert on-air gegen MTP3550.
- [x] **MAC/MLE/CMCE Platzierung:** **REVIDIERT 2026-04-26** — FPGA+SW-Split. FPGA = PHY + komplette M2-Anmeldung (Reassembly + IE-Parser GILD + MLE-FSM M2-Pfad + Subscriber-DB-Hot-Cache). SW = Group-Switch (mm=7) + CMCE + Voice + SDS + Phase G+. Auslöser: Slice-Druck 97.82%. Memory `project_arch_fpga_sw_split.md` ist verbindlich; alte Entscheidung 2026-04-22 (`project_arch_fpga_heavy.md`) ist archiviert.
- [x] **DB-Transport ARM ↔ FPGA:** Variante A gewählt — ARM pusht Subscriber/Group-Table per AXI-Lite in Shadow-BRAM (256 Einträge × 64 bit = 1 BRAM36).
- [ ] **ACELP Codec:** Für Voice-Relay *nicht* benötigt (bit-transparentes Pass-Through UL-TCH → DL-TCH). Erst relevant für BS-as-Talker oder Recording-Gateway — dann erneut prüfen.
- [ ] **TEA-Verschlüsselung:** Nicht im initialen Scope. Als separates RTL-Modul ergänzbar.
- [ ] **Amateurfunk-Frequenzen:** 430–440 MHz (aktuell 438.250 MHz DL getestet, HamTETRA-Band).


