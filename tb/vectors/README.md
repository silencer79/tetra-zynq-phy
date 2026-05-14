# Testbench Vectors
# Project: tetra-zynq-phy

This directory contains Python scripts that generate test vectors for each
module's self-checking testbench.

## Format

Each generator script produces `.hex` files loaded via `$readmemh`:
```verilog
$readmemh("../tb/vectors/<module>_stimulus.hex", stimulus_mem);
```

---

## Script Status

| Script | Module | Generiert | Dateien vorhanden |
|---------------------------------|---------------------------|-----------------|-------------------------------------------------------------|
| `gen_reset_vectors.py` | `tetra_clk_reset` | ❓ nicht genlaufen | — |
| `gen_ad9361_vectors.py` | `tetra_ad9361_interface` | ✅ generiert | `ad9361_iq_vectors.hex` |
| `gen_pi4dqpsk_vectors.py` | `tetra_pi4dqpsk_demod` | ✅ generiert | `pi4dqpsk_iq_in.hex`, `pi4dqpsk_dibit_out.hex` |
| `gen_timing_recovery_vectors.py`| `tetra_timing_recovery` | ❌ fehlen | `timing_tc{0,1,2}_iq_in.hex`, `timing_tc{0,1,2}_ted.hex` fehlen |
| `gen_rx_frontend_vectors.py` | `tetra_rx_frontend` | ❌ fehlen | `rx_frontend_stimulus.hex`, `rx_frontend_expected.hex` fehlen |
| `gen_sync_detect_vectors.py` | `tetra_sync_detect` | ❓ nicht genlaufen | TB nutzt inline-Stimuli, kein readmemh |
| `gen_burst_vectors.py` | `tetra_burst_demux` | ❓ nicht genlaufen | TB nutzt inline-Stimuli, kein readmemh |
| `gen_scrambler_vectors.py` | `tetra_scrambler` | ❓ nicht genlaufen | TB nutzt inline-Stimuli, kein readmemh |
| `gen_interleaver_vectors.py` | `tetra_interleaver` | ❓ nicht genlaufen | TB nutzt inline-Stimuli, kein readmemh |
| `gen_viterbi_vectors.py` | `tetra_viterbi_decoder` | ❓ nicht genlaufen | TB nutzt inline-Stimuli, kein readmemh |
| `gen_reed_muller_vectors.py` | `tetra_reed_muller` | ✅ generiert | `rm_encode_in.hex`, `rm_encode_out.hex`, `rm_decode_*.hex` |
| `gen_crc16_vectors.py` | `tetra_crc16` | ❓ nicht genlaufen | TB nutzt inline ref_crc16(), kein readmemh |

---

## Alle Vektoren generieren

```bash
cd /home/kevin/claude-ralph/tetra
for f in tb/vectors/gen_*.py; do
 echo "Running $f..."
 python3 "$f"
done
```

Requires Python 3.8+ with numpy installed.

---

## Hinweise zu inline-Testbenches

Folgende Testbenches haben **keine** `$readmemh`-Abhängigkeit — sie generieren
Stimuli direkt im Verilog-Code und vergleichen mit einem internen Referenzmodell:
- `tb_tetra_scrambler.v` — LFSR-Referenz inline
- `tb_tetra_interleaver.v` — Referenz-Permutation inline
- `tb_tetra_viterbi_decoder.v` — Bekannte Encoder-Sequenzen inline
- `tb_tetra_reed_muller.v` — Referenz-Encoder-Funktion inline
- `tb_tetra_crc16.v` — `ref_crc16()` Task inline
- `tb_tetra_sync_detect.v` — Training-Sequence-Stimuli inline
- `tb_tetra_burst_demux.v` — Burst-Stimuli inline
- `tb_tetra_frame_counter.v` — Slot-Pulse-Stimuli inline
- `tb_tetra_axi_lite_regs.v` — AXI-Tasks inline
- `tb_tetra_axi_dma_bridge.v` — DMA-Stimuli inline

Diese sind daher **sofort simulierbar** ohne Vektorgenerierung.

---

## References

- ETSI EN 300 392-2: TETRA V+D Air Interface (main standard)
- EN 300 392-2 §8.2: Channel coding (Viterbi, Reed-Muller, CRC)
- EN 300 392-2 §9.3: π/4-DQPSK modulation
- EN 300 392-2 §9.4: Burst structures + training sequences
