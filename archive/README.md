# archive/ — nicht mehr benötigte Dateien

Hier liegen Dateien, die im aktuellen Design **nicht mehr aktiv** sind, aber zur
Nachvollziehbarkeit aufbewahrt werden (statt sie zu löschen). Git-History bleibt
über `git mv` erhalten — `git log --follow archive/<datei>` zeigt den vollen
Verlauf.

> **Nicht in den Build/Sim ziehen.** Diese Dateien sind aus `scripts/vivado_build.tcl`
> bzw. den Test-Runnern (`run_all_tests.sh`, `run_sims.py`) entfernt. Sie sind
> hier reine Referenz.

## Inhalt (Stand 2026-06-20)

### RTL — funktional durch SW/IP abgelöst, nicht im aktiven Design

| Datei | Warum archiviert | Ersatz |
|-------|------------------|--------|
| `rtl/tetra_voice_relay.v` | DL-bit-transparenter Voice-Relay war RTL; seit `e8efb31` aus dem DL-Pfad raus | SW `sw/tetra_voice_pipe.c` (UL→DL Relay mit SSI-Patch) |
| `rtl/tetra_d_location_update_reject_encoder.v` | D-LOC-UPDATE-REJECT-Encoder; nie instanziiert, war nur in der Build-Filelist | SW `sw/tetra_tx_transport.c` (`TX_LU_REJECT`-Pfad) |
| `rtl/tetra_ad9361_interface.v` | Custom-LVDS-DDR-Interface (IBUFDS/IDDR/ODDR/OBUFDS/BUFG); archiviert 2026-04-06 | ADI-`axi_ad9361`-IP (in der Vivado-BD) + `rtl/tetra_ad9361_axis_adapter.v` |

### Testbenches — testeten ausschließlich obige Module, nicht in den aktiven Runnern

| Datei | Hinweis |
|-------|---------|
| `tb/tb_d_location_update_reject_encoder.v` | DUT war der archivierte Reject-Encoder. |
| `tb/tb_ul_nub_e2e.v` | Um den archivierten `tetra_voice_relay` gebaut (Kommentar: "kept here only for signal-level checks"). **Achtung:** streift auch die LEBENDEN Module `tetra_ul_sync_detect_os4` + `tetra_ul_nub_capture` — wer eine NUB-e2e-Coverage wiederbeleben will, sollte den `voice_relay`-Teil entfernen und gegen das aktuelle `coded_softs`-Interface adaptieren. |
| `tb/tb_tetra_ad9361_interface.v` | DUT war das archivierte Custom-AD9361-Interface. Ersatz: `tb/tb_tetra_ad9361_axis_adapter.v`. |

## Historie

`archive/` ist die konsolidierte Ablage. Das frühere `deprecated/`-Verzeichnis
(enthielt das AD9361-Custom-Interface + TB) wurde 2026-06-20 hierher überführt.
