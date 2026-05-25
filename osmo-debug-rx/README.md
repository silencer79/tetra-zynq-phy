# Osmo-TETRA Testempfaenger

Dieses Unterverzeichnis ist absichtlich getrennt vom vorhandenen Python-Decoder.
Hier steckt ein einfacher HF-Debug-Workflow auf Basis von `rtl_sdr` plus
`osmo-tetra`.

## Ziel

Schnell pruefen:

- sieht der RTL-SDR dein TETRA-Downlink-Signal
- laesst sich ein Capture reproduzierbar ziehen
- verarbeitet `osmo-tetra` das Capture bis `tetra-rx`

Der Ablauf ist bewusst **offline**:

1. `rtl_sdr` schreibt Roh-I/Q (`uint8`, interleaved I/Q)
2. `osmo-tetra` demoduliert das Capture in Float-Symbole
3. `float_to_bits` erzeugt 1 Bit pro Byte
4. `tetra-rx` dekodiert den Bitstrom

Das ist fuer HF-Debug robuster als ein komplett live verdrahteter Pipe-Stack.

## Voraussetzungen

Lokal vorhanden:

- `rtl_sdr`
- `rtl_test`

Zusätzlich benoetigt:

- eine lokale `osmo-tetra`-Checkout/Build-Umgebung
- `float_to_bits`
- `tetra-rx`
- ein Python-Demodulator aus `osmo-tetra`, standardmaessig `src/demod/python/simdemod2.py`

Aktueller Stand (eingerichtet via `setup_osmo_rx.sh`):

- `rtl_sdr` / `rtl_test`: System-Tools, vorhanden
- `vendor/osmo-tetra`: lokaler Checkout (Upstream Osmocom)
- `vendor/osmo-tetra/src/tetra-rx`: gebaut (`make` in `src/`)
- `vendor/osmo-tetra/src/float_to_bits`: gebaut (nicht mehr im Pipeline-Pfad noetig)
- `py3-osmo-demod/simdemod3.py`: GR-3.10-nativer Demod, gepatcht fuer File-I/O + rtl_sdr-u8 + Resampling

## Build

```bash
sudo apt-get install -y libosmocore-dev autoconf automake libtool 2to3 python3-lib2to3
./setup_osmo_rx.sh                       # einmalig: Clone + 2to3 + Patch
cd vendor/osmo-tetra/src && make         # baut tetra-rx + float_to_bits
```

## Pfade

Standard (alles selbst-enthaltend, keine ENV noetig):

```text
$SCRIPT_DIR/vendor/osmo-tetra/src/tetra-rx
$SCRIPT_DIR/py3-osmo-demod/simdemod3.py
```

Override per ENV:

```bash
export OSMO_TETRA_ROOT=/path/to/osmo-tetra      # andere Build-Tree
export OSMO_TETRA_RX=/usr/local/bin/tetra-rx
export OSMO_TETRA_DEMOD=/path/to/simdemod3.py
```

## Hinweise zum Demod-Stack

- `simdemod2.py` und `cqpsk.py` sind in GR 3.10 **kaputt** (`digital.mpsk_receiver_cc` entfernt). Nicht verwenden.
- `simdemod3.py` ist die offizielle GR-3.10-Ersatz-Implementierung von Jacek Lipkowski. Output: 1 Bit pro Byte direkt — `float_to_bits` faellt im Pipeline weg.
- Lokaler Patch ergaenzt `-i FILE`, `-o FILE`, `-s SAMPLE_RATE`, `-t TUNE_OFFSET` plus
  rtl_sdr u8 → gr_complex Konvertierung + `freq_xlating_fir_filter_ccf` Tuning + `mmse_resampler_cc` auf 36 ksps.

## Schnellstart

Gerätetest:

```bash
./osmo_tetra_rx.sh probe
```

Ein Capture ziehen:

```bash
./osmo_tetra_rx.sh capture \
  --channel-freq 425487000 \
  --gain 38.6 \
  --duration 8
```

Capture + Osmo-Dekodierung:

```bash
./osmo_tetra_rx.sh decode \
  --channel-freq 425487000 \
  --gain 38.6 \
  --duration 10
```

Vorhandenes Capture dekodieren:

```bash
./osmo_tetra_rx.sh decode --input /tmp/tetra-osmo-debug/capture_425487000Hz.cfile
```

## Wichtige Parameter

- `--channel-freq`: eigentliche TETRA-Kanalfrequenz
- `--tune-offset`: Abstimmversatz gegen DC-Spike, Default `100000`
- `--sample-rate`: Default `1000000`
- `--gain`: RTL-SDR-Tuner-Gain
- `--ppm`: PPM-Korrektur des Sticks
- `--device`: RTL-SDR-Index

Die reale Abstimmfrequenz ist:

```text
tune_freq = channel_freq + tune_offset
```

Wenn du exakt auf Kanalmitte abstimmen willst:

```bash
./osmo_tetra_rx.sh decode --channel-freq 425487000 --tune-offset 0
```

## Ausgaben

Per Default landen die Dateien in:

```text
/tmp/tetra-osmo-debug/
```

Typische Artefakte:

- `capture_*.cfile` — rtl_sdr u8 IQ
- `bits_*.bin` — demodulierte Bits (1 Bit/Byte) aus simdemod3
- `tetra-rx_*.log` — tetra-rx Decode-Output

## Grenzen

- Das Skript installiert `osmo-tetra` nicht automatisch.
- Ohne lokale `osmo-tetra`-Buildprodukte laeuft nur `probe` und `capture`.
- Fuer echte Live-Analyse mit GUI/Spektrum waere ein separater GNU-Radio- oder
  `gr-osmosdr`-Flow sinnvoll; dieses Verzeichnis ist fuer reproduzierbaren
  HF-Debug und Capture-first ausgelegt.
