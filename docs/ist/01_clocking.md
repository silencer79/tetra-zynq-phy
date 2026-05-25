# IST 01 — Clocking & Reset

Quelle: `rtl/infra/tetra_clk_reset.v` (199 Zeilen) + Top-Level Verdrahtung in
`rtl/tetra_zynq_top.v`.

## Clock-Domains (im Design real benutzt)

| Domain | Quelle | Frequenz | Verbraucher |
|-------------|-----------------------------------------|----------------------|------------------------------------------------------------------------------------------------------|
| `clk_sys` | `i_clk` (Zynq PS FCLK_CLK0) | 100 MHz | Fast jedes RTL-Modul: LMAC, MLE-FSM, Mailboxes, Scheduler, Burst-Dispatcher, AACH/SB1-Encoder etc. |
| `clk_axi` = `s_axi_aclk` | Zynq PS (selbe PLL-Quelle wie `clk_sys`) | 100 MHz | `tetra_axi_lite_regs`-Slave + AXI-Lite Statemachines + Schedule-BRAM Port A |
| `clk_lvds` = `l_clk` | `axi_ad9361` IP Output | ~61.44 MHz typ. | `tetra_ad9361_axis_adapter` (RX/TX I/Q), `tetra_rx_chain` (Frontend/Demod), `tetra_tx_chain` letzte Stufe |
| `clk_sample`| identisch verbunden mit `clk_sys` | 100 MHz | Im Top-Level (`u_clk_reset.clk_sample(clk_sys)`) tot — kein eigener Konsument, `rst_n_sample` unconnected. |

`rtl/tetra_zynq_top.v:206` setzt `.clk_sample(clk_sys)` und `.rst_n_sample()`.
Die im `tetra_clk_reset` vorgesehene vierte Domain ist im aktuellen Aufbau
faktisch ein Alias auf `clk_sys`.

## Modul tetra_clk_reset.v (199 Zeilen)

**Ports:**
- IN: `arst_n` (1), `clk_sys` (1), `clk_sample` (1), `clk_axi` (1), `clk_lvds` (1)
- OUT: `rst_n_sys` (1), `rst_n_sample` (1), `rst_n_axi` (1), `rst_n_lvds` (1)

**Funktion:** Erzeugt pro Clock-Domain einen synchronisierten active-low Reset.
Assert ist asynchron (fällt sofort bei `arst_n` ↓), Deassert ist synchron mit
2 Stufen FF (`rst_sync0_<dom>` → `rst_sync1_<dom>`).

**State:** Keine FSM. Vier identische 2-FF-Synchronizer-Ketten, je `(* ASYNC_REG = "TRUE" *)` markiert.

**Pipeline-Latenz:** Deassert: 2 Rising-Edges in der Ziel-Domain. Assert: 0 Zyklen (asynchron).

**Nachbarn:**
- ↑ Instanziiert in `tetra_zynq_top.v:203` (`u_clk_reset`).
- ↓ Keine.

**Auffälligkeiten:**
- `rst_n_sample` wird im Top-Level nicht konsumiert (Open-Output).
- Kommentar Z. 41–44 nennt XDC-False-Path-Constraint und `docs/timing_analysis.md`.
- Resource-Estimate im Header: 8 FF, 0 LUT (4 Domains × 2 FF).

## Clock-Verteilung im Top (tetra_zynq_top.v)

**Top-Wires:**
- `wire clk_sys; assign clk_sys = i_clk;` (Zeile 189–190)
- `wire clk_lvds;` (Zeile 193) — getrieben von `tetra_ad9361_axis_adapter.clk_lvds = l_clk`
 (`rtl/tetra_ad9361_axis_adapter.v:140`).
- `wire rst_n_sys, rst_n_lvds, rst_n_axi;` (Z. 199–201)

**Reset-Instanz:** `u_clk_reset` Z. 203–213.

## CDC-Pattern (Auszug)

Welche Brücken werden im Top zwischen den Domains gefahren? Komplette Liste
siehe `00_zynq_top_overview.md`. Hier nur die strukturellen Muster:

- **clk_sys → clk_axi:**
 - Frame/slot-Zähler werden Gray-coded vor 2-FF resynced (Z. 1362–1408).
 - Pulse (irq_mac_block, crc_error) werden toggle-CDC'd (Z. 1412–1432, 1449–1471).
 - 16-bit Counter direkt 2-FF (`dma_blk_cnt_axi_r0/r1` Z. 1496ff.).
- **clk_axi → clk_sys:**
 - Statische Configs (CELL_CFG, COLOUR_CODE, CELL_LA, DB_POLICY, signal_target_tn) per 2-FF (Z. 3425ff.).
 - Strobes (TX_TDMA_LOAD bit[31]) 2-FF + Edge-Detect → 1-Cycle sys-Pulse (Z. 1815–1836).
- **clk_lvds → clk_sys:**
 - `sym_toggle_lvds` (Symbol-Tick) → 2-FF + Edge → `sym_en_sys_w` (Z. 1014–1046).

## Symbol-Tick-Erzeugung

`clk_lvds`-Domain: 10-bit Zähler `sym_div_lvds` zählt 0..1023, toggelt
`sym_toggle_lvds`. Bei `clk_lvds = 18.432 MHz` ergibt `1024 / 18.432e6 ≈ 55.556 µs`,
also `18000 Hz` Symbolrate (Headerkommentar Z. 1008–1010). Toggle wird
2-FF-resynct nach `clk_sys` und auf 1-Cycle-Pulse `sym_en_sys_w` reduziert.
Dieser Puls treibt:
- `tetra_tdma_timebase` (Z. 1844)
- `tetra_tx_chain.sym_en_ext_sys` (Z. 1327)
- Die Free-Running TX-TDMA-Counter `tx_sym_cnt_sys/tx_slot_cnt_sys/tx_frame_cnt_sys/tx_mf_cnt_sys` (Z. 1074–1104).
