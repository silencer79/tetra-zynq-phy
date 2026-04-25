# OPERATIONS — Deploy, Test, Troubleshooting

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Zuletzt aktualisiert:** 2026-04-25 (M2 erreicht)

Ersetzt: `deployment_guide.md`, `deploy_workflow.md`, `test_results.md`,
`sim_results.txt`, `test_results_raw.txt`.

---

## 1. Quick Reference — Alltags-Kommandos

```bash
# Vollständiger Deploy (Build + Convert + Cross-Compile + Upload)
./scripts/deploy.sh

# Nur Vivado-Build (Bitstream rausfallen lassen, kein Upload)
./scripts/deploy.sh --build-only

# Re-Deploy bestehender .bit (Skip Vivado, SW neu bauen + upload)
./scripts/deploy.sh --no-build

# Full-Deploy + Board-Init + Daemons starten (empfohlen nach jedem RTL-Change)
./scripts/deploy.sh --no-build --init

# Board-Zustand prüfen
./scripts/tetra_ctrl.sh monitor
./scripts/tetra_ctrl.sh read 0x00       # CTRL
./scripts/tetra_ctrl.sh read 0x04       # STATUS
./scripts/tetra_ctrl.sh read 0x190      # MLE-Counter (accept | ul_req)

# Tail der Board-Logs
sshpass -p openwifi ssh root@192.168.2.180 'tail -20 /tmp/tetra_sysinfo.log'
sshpass -p openwifi ssh root@192.168.2.180 'tail -20 /tmp/tetra_ul_mon.log'
```

---

## 2. Deploy-Pipeline (scripts/deploy.sh)

```
Vivado Build → bootgen (.bit → .bit.bin) → Cross-Compile SW → SCP Upload → [optional: full_init + Daemons]
```

### Flags

| Flag | Wirkung | Zum Überspringen |
|------|---------|------------------|
| `(default)` | Alle 4 Schritte (Build+Convert+Compile+Upload) | — |
| `--build-only` | Nur Vivado (Schritt 1) | Convert/Compile/Upload |
| `--no-build` | Nutzt existierenden `build/tetra_zynq_phy.bit` | Vivado-Neubau |
| `--no-sw` | SW nicht neu bauen/hochladen | Schritt 3+4 SW-Teil |
| `--init` | Nach Upload: `full_init` + `tetra_sysinfo` + `tetra_ul_mon` starten | — |

### Was der Board-Init macht (`full_init`)

1. **Erster Bitstream-Load** via FPGA Manager
2. **AD9361-Init** (Sample-Rate 4.608 MSPS, LO, AGC slow_attack, FDD)
3. **Zweiter Bitstream-Load** (MMCM sieht jetzt stabilen DATA_CLK)
4. **AD9361 Re-Init** (stellt Register wieder her die Step 3 zurücksetzt)
5. **DAC-Core-Init** (RSTN + fabric data mode)
6. **ADC-Core-Init** (CH0/CH1 = 0x51 = enable + sign-extend + r1_mode=0)

**Warum 2× Bitstream:** Beim Kaltstart liefert der AD9361 noch kein DATA_CLK. Erster Load bringt Fabric hoch, zweiter konfiguriert die MMCM mit stabilem Clock-Input.

### MD5-Verify nach Upload

`deploy.sh` berechnet MD5 lokal, vergleicht gegen Board-Seite — bricht ab bei Mismatch. Debug: `md5sum build/tetra_zynq_phy.bit.bin` + `sshpass ... 'md5sum /lib/firmware/tetra_zynq_phy.bit.bin'`.

---

## 3. Board-Zugang

| Parameter | Wert |
|-----------|------|
| IP | `192.168.2.180` |
| User | `root` |
| Passwort | `openwifi` |
| SSH | `sshpass -p openwifi ssh root@192.168.2.180` |
| AXI-Base | `0x43C00000` (TETRA-PL), `0x79020000` (ADC), `0x79024000` (DAC) |

### Wichtige Pfade auf dem Board

| Pfad | Inhalt |
|------|--------|
| `/lib/firmware/tetra_zynq_phy.bit.bin` | FPGA Bitstream (persistent) |
| `/root/tetra_sysinfo` | SYSINFO/TX-Daemon (ARM binary) |
| `/root/tetra_ul_mon` | UL-MAC-ACCESS-Monitor-Daemon |
| `/root/tetra_db_mgr` | Subscriber-DB ↔ Shadow-BRAM CLI |
| `/var/lib/tetra/db.tsv` | Subscriber-DB (TSV, persistent) |
| `/www/index.html` + `/www/cgi-bin/*.cgi` | WebUI (busybox httpd) |
| `/tmp/tetra_sysinfo.log` | Sysinfo Log |
| `/tmp/tetra_ul_mon.log` | UL-mon Log (MS-RA-Decodes) |
| `/sys/bus/iio/devices/iio:device1/` | AD9361 IIO Sysfs |

### Kanonisches Control-Tool

`./scripts/tetra_ctrl.sh` (auf HOST) ist kanonisch — `/root/tetra_ctrl.sh` am Board ist broken (kein `sshpass`). Alle Board-Kommandos via Host-Script.

---

## 4. RF Loopback (Digital + Air-Gap)

```bash
./scripts/tetra_ctrl.sh rf_loopback [RX_Hz] [TX_Hz] [SYNC_THRESH] [TX_ATT_dB]
```

| Parameter | Default | Empfohlen | Beschreibung |
|-----------|---------|-----------|--------------|
| RX_Hz | 430000000 | 430000000 | RX LO Frequenz |
| TX_Hz | 430000000 | 430000000 | TX LO (MUSS = RX_Hz für Loopback) |
| SYNC_THRESH | 15 | 15 | Korrelator-Schwelle (max 19) |
| TX_ATT_dB | -50 | **-10** | TX-Dämpfung (0 bis -89 dB) |

### TX_ATT-Sweep (2026-04-17, 10 cm Luft-Loopback)

| TX_ATT | AGC | RSSI | Lock |
|--------|-----|------|------|
| -10 dB | 49 dB | 71 dB | ✅ stabil (10/10) |
| -30 dB | 56 dB | 76 dB | ⚠️ instabil |
| -50 dB | 73 dB | 98 dB | ❌ zu schwach |

### Sync-Lock-FSM-Parameter (`rtl/rx/tetra_sync_detect.v`)

| Parameter | Wert | Beschreibung |
|-----------|------|--------------|
| LOCK_TOL | 30 | ± Symbole Toleranz für Spacing-Check |
| LOCK_TIMEOUT | 3060 | Symbole ohne `sync_fire` → Unlock (3 Frames) |
| LOCK_COUNT | 4 | Konsekutive Hits für Lock-Akquisition |
| HOLDOFF | 220 | Symbole Sperrzeit nach `sync_fire` |

`spacing_ok` akzeptiert Frame-Vielfache: 1020 ± 30, 2040 ± 30, 3060 ± 30.

---

## 5. Testbench-Strategie

### 5.1 Unit-TBs — `iverilog` + `vvp`

**Runner:** `./run_all_tests.sh` kompiliert und simuliert alle TBs in `tb/` sequentiell.

Für einzelne Module:
```bash
iverilog -g2012 -o sim_out/<module> <RTL-Deps> tb/tb_<module>.v
vvp sim_out/<module>
```

### 5.2 Signalling/Session-TBs (manuell)

Neuere Module (MLE-FSM, MAC-RESOURCE-Builder, D-LOC-UPDATE-Encoder, DL-Signal-Queue/Scheduler) sind **nicht** in `run_all_tests.sh` — explizit aufrufen:

```bash
iverilog -g2012 -o sim_out/mac_res rtl/lmac/tetra_mac_resource_dl_builder.v tb/tb_mac_resource_dl_builder.v && vvp sim_out/mac_res

iverilog -g2012 -o sim_out/mle \
  rtl/lmac/tetra_mle_registration_fsm.v \
  rtl/lmac/tetra_active_session_table.v \
  rtl/lmac/tetra_mac_resource_dl_builder.v \
  rtl/lmac/tetra_d_location_update_encoder.v \
  rtl/lmac/tetra_sch_f_encoder.v \
  rtl/lmac/tetra_crc16.v \
  rtl/lmac/tetra_rcpc_encoder.v \
  rtl/lmac/tetra_scrambler.v \
  rtl/lmac/tetra_interleaver.v \
  tb/tb_mle_registration_fsm.v && vvp sim_out/mle
```

### 5.3 Vivado Behavioral Simulation (alt)

`scripts/vivado_sim.tcl` — PHY-Unit-TBs via Vivado xsim. Veraltet; iverilog ist aktuell der primäre Runner.

```bash
vivado -mode batch -source scripts/vivado_sim.tcl -tclargs <module_name>
```

---

## 6. Test-Status (Stand 2026-04-25)

### Letzte volle Regression

| Suite | Pass / Total | Datum |
|-------|--------------|-------|
| PHY-Unit-TBs (iverilog, 22 Module) | **22/22** | 2026-04-13 |
| Digitaler Loopback (CTRL[2]=1, 30 s) | **30/30 SYNC_LOCKED** | 2026-04-13 |
| RF Air-Loopback (10 cm, TX_ATT=-10dB) | **27/30 SYNC_LOCKED** | 2026-04-13 |
| LMAC-Signalling-TBs (manuell) | tb_mac_resource_dl_builder 6/6, tb_d_location_update_encoder 16/16, tb_dl_signal_queue + scheduler + slot_content_mux je PASS | 2026-04-23 |
| UL RX Chain (tb_ul_demod_sch_hu, tb_ul_wav_chain) | 4/4 + 5/5 | 2026-04-22 |
| **24-bit ISSI Pfad** (tb_ul_mac_access_parser inkl. ext-BS + MTP3550 on-air vectors) | **31/31** | 2026-04-25 |
| **MLE-FSM ISSI Round-Trip + Permit-Check** (tb_mle_registration_fsm — 6 M2 + 4 Phase-A Cases) | **10/10** | 2026-04-25 |
| **AXI-Reg 24-bit Mask** (tb_tetra_axi_lite_regs) | **10/10** | 2026-04-25 |
| **UL BL-ACK Pfad** (tb_ul_mac_access_parser_bl_ack) | **15/15** | 2026-04-25 |
| **D-LOC-UPDATE-ACCEPT Encoder** (102-bit MM body bit-exakt) | **34/34** | 2026-04-25 |
| **D-LOC-UPDATE-REJECT Encoder** (Phase A, 8-bit body) | **8/8** | 2026-04-25 |
| **MLE-FSM Phase B** (Detach known/unknown) — Erweiterung tb_mle_registration_fsm | **12/12** (10 Phase A + 2 Phase B) | 2026-04-25 |
| **AST Phase C TTL-Sweep** (3 Eviction-Cases + table-full alloc/query) | **16/16** | 2026-04-25 |

### Bekannte Caveats

- **`tetra_viterbi_decoder.v`** (DL path, bit-reversed state conv): TIMEOUT-`$error`-Meldungen im Log — **cosmetic**, alle 7 TCs bestehen. Existiert ein ETSI-konformes UL-Pendant in `rtl/rx/tetra_ul_viterbi_r14.v`.
- **RF-Loopback 3/30 Drops** korrelieren mit AGC slow_attack Gain-Sprüngen — nicht kritisch für Protokoll-Tests.

### Raw-Dumps

Historische Sim-Läufe liegen archiviert in:
- `docs/sim_results.txt` (Summary)
- `docs/test_results_raw.txt` (Detail-Ausgabe pro Modul)

Beide nicht mehr aktiv gepflegt (`run_all_tests.sh` schreibt selbst neue Logs).

---

## 7. Live-Debugging — Board-seitig

### 7.1 Counter lesen (MLE/DL-Signal)

| Register | Bedeutung |
|----------|-----------|
| `0x190` | `{accept_cnt[31:16], ul_req_cnt[15:0]}` — MLE-FSM |
| `0x194` | `{drop_cnt[15:0]} + busy_sticky` |
| `0x198` | `{clear_cnt[31:16], sig_override_cnt[15:0]}` — Scheduler |
| `0x19C` | `REG_SIGNAL_TARGET_TN` (Default 0 = ETSI TN=1) |
| `0x1A0` | `REG_CELL_LA` (14-bit, default 1) |

```bash
./scripts/tetra_ctrl.sh read 0x190
```

### 7.2 UL-mon Live-Output

`tetra_ul_mon` Daemon pollt alle 10 ms die UL-MAC-ACCESS-AXI-Register und loggt jede CRC-OK RA-PDU:

```
[HH:MM:SS] #<count> pdu=0 fill=0 enc=0 ack=0 at=2 ssi=<event_label> raw=<23-hex 92-bit payload>
```

Decode-Tool für das Raw-Feld:
```bash
python3 scripts/decode_ul_raw.py <hex-blob>
# oder direkt vom Board:
python3 scripts/decode_ul_raw.py --board --last 5
```

### 7.3 DL on-air verifizieren

```bash
# Per RTL-SDR oder HackRF 60s-Capture auf DL-LO-Frequenz, dann:
python3 scripts/decode_dl.py --sr 250000 <capture.wav> --max-bursts 3000 [-v]
```

Für auto-offset-Failure (korrelation < 0.9): manuell Offset setzen —
`--offset -96625` (typischer SDR#-Offset für unser LO).

### 7.4 tetra-kit als zweiter Decoder

`scripts/wav_to_tkbits.py` konvertiert unsere WAVs in tetra-kit-kompatibles Input-Format. tetra-kit (externes Tool) lockt unabhängig auf unsere DL (0 Sync-Loss in 35 s, Ref 2026-04-20) und kann als zweiter Decoder dienen wenn `decode_dl.py` zu streng ist.

### 7.5 WebUI — Subscriber-DB + Profiles + Live-Counter (Phase 6 E + D-rev)

`http://192.168.2.180/` → busybox httpd liefert `index.html` + CGI.
Tabs: **Cell Config** (Frequenz/CC/SYSINFO via `apply.cgi`),
**Subscribers** (EntityTable + Sessions) und **Profiles** (ProfileTable
6-Slot-Editor).

| Endpoint | Methode | Zweck |
|----------|---------|-------|
| `/cgi-bin/entities.cgi` | GET | JSON-Liste der EntityTable-Slots aus `db.tsv`. Felder: `slot, entity_id, entity_type (0=ISSI,1=GSSI), profile_id, valid` |
| `/cgi-bin/entities.cgi` | POST `op=add&slot=&entity_id=&entity_type=&profile_id=` | Hinzufügen + sofort `tetra_db_mgr sync` zur BRAM |
| `/cgi-bin/entities.cgi` | POST `op=del&slot=N` | Löschen + sync |
| `/cgi-bin/profiles.cgi` | GET | JSON-Liste aller 6 ProfileTable-Slots (max_call_dur/hangtime/priority/gila_class/gila_lifetime/permits/valid + raw 32-bit hex) |
| `/cgi-bin/profiles.cgi` | POST `op=set&slot=&max=&hangtime=&priority=&gila_class=&gila_lifetime=&permit_voice=&permit_data=&permit_reg=&valid=` | Profile schreiben (AXI 0x1C0..0x1CC + Persistenz `/var/lib/tetra/profiles.tsv`) |
| `/cgi-bin/sessions.cgi` | GET | Live-Counter via `busybox devmem` (0x190/0x194/0x198/0x1A4/0x1A8/0x1AC/0x1B0/0x168) + `tail /tmp/tetra_ul_mon.log` |
| `/cgi-bin/policy.cgi`   | POST `op=set&accept_unknown=0|1` | OPEN ↔ RESTRICTED Toggle (RMW auf REG_DB_POLICY @ 0x1AC) |

Boot-Sync: `deploy.sh --init` legt `/var/lib/tetra/db.tsv` aus
`sw/db.tsv.default` an (falls noch nicht vorhanden) und ruft
`tetra_db_mgr sync` — EntityTable-BRAM ist nach Reboot vorgeladen,
kein manueller `add`-Schritt nötig. Default-TSV (4-Spalten-Format,
slot/entity_id/entity_type/profile_id) enthält:
- Slot 0: ISSI 2633617 (0x282F91, MTP3550), profile_id=0
- Slot 1: GSSI 3100001 (0x2F4D61, Default-Group), profile_id=0

Profile 0 ist hardware-default (Reset-Wert) `0x0000_088F` (gila_class=4,
gila_lifetime=1, permit_voice/data/reg=1, valid=1) — bit-genau zur
M2-Gold-Ref-D-LOC-UPDATE-ACCEPT-GILA. Operator-Edits via Profiles-Tab
verändern on-air-GILA-Bits sofort beim nächsten Attach.

**Migration-Hinweis:** Legacy-DB-TSV (7 Spalten, vor 2026-04-26) wird
von `tetra_db_mgr` als "format obsolete" abgelehnt. Vor Phase-D-rev-
Build alte TSV löschen und aus `sw/db.tsv.default` regenerieren.

### 7.6 UL-Sync-Threshold (Phase B Detach-Diagnose)

`tetra_ul_sync_detect_os4` korreliert über 15 Symbole x-seq (4-bit
saturierend, max 15). Geteilter `REG_SYNC_THRESH @ 0x0C` mit
`tetra_sync_detect`-DL.

| Threshold | Wirkung |
|-----------|---------|
| 0x0F (alt) | nur perfekte Matches → ~3/12 echter Bursts gefangen |
| **0x0D** (neu, Default seit `4bd43e3`) | sweet spot, alle echten Bursts, ~0.2 false-pos/s |
| 0x0C | 1500+ false-pos/s aus Rauschen |

DL-Sync nutzt den selben Reg, ist aber nur RX-Loopback-Diagnose —
TX-Aussendung ist unabhängig. Senken auf 0x0D ist risk-free.

Wenn `0x190` (Demand-Counter) oder `0x1A4` (Detach-Counter) bei
MS-Aktivität nicht zählen: erst `0x5C` (UL-OS4-Sync-Cnt) prüfen —
bleibt der niedrig, ist's der Threshold.

---

## 8. Troubleshooting

### Board crasht bei `full_init`
Physisch resetten. Bitstream bleibt auf `/lib/firmware/` (persistent). Erneut `full_init` versuchen — der zweite Versuch klappt fast immer.

### SYNC_LOCKED=0 trotz `corr_peak=19/19`
- `tetra_sysinfo` läuft? → `pgrep tetra_sysinfo`
- TX_ATT zu hoch? → `-10 dB` testen
- ADC-Core OK? → `dmesg | grep ad9361` (kein "Tuning RX FAILED")

### AD9361 IIO-Device nicht gefunden
- Device ist `iio:device1` (nicht device0, das ist XADC)
- `cat /sys/bus/iio/devices/iio:device1/name` → `ad9361-phy`

### decode_dl.py "Failed to acquire cell"
- Zuerst `--offset <manuell>` versuchen (typisch −96625 Hz für unser SDR#-Setup). Auto-Offset kann bei schwachem Signal schlechte Schätzung wählen.
- Signal-Stärke prüfen: `python3 -c "import wave; w=wave.open('<file>','rb'); ..."` — avg_pwr/peak_pwr im WAV. Peak/avg unter 50× = zu schwach.

### Timing-Violation im Vivado-Build
Bisherige Builds mit WNS bis −0.3 ns hatten on-air keinen Impact. Für Production-Fixes: Vivado-Strategy wechseln (`Performance_Explore`) — ca. +30 min Build-Zeit, oft schließt damit.

---

## 9. Deploy-Historie (Eskalationen)

| Datum | Bitstream-MD5 | Key-Änderung | On-air OK? |
|-------|---------------|--------------|-----------|
| 2026-04-23 21:58 | `ef75722f…` | Bug #7 (MAC-Header 3-bit shift) | ✅ decode_dl zeigt `MLE disc=MM` |
| 2026-04-23 22:15 | `a37e818b…` | Bug #8 (LocAccType echoed) | ✅ decode_dl zeigt `LocAccType=3 ITSI attach` |
| 2026-04-23 22:44 | `c656c9b5…` | Bug #9 (FCS osmo-style TL-SDU-only + pre-shift) | ✅ on-air FCS=0xB0A53869 matched osmo |
| 2026-04-24 | `2c8ad4a` | Two-Phase-Attach (SCH/HD AL-SETUP LI=7 + SCH/F BL-ADATA LI=21) | ✅ matcht Gold-Ref Burst #727+#735 strukturell |
| 2026-04-25 02:34 | `eeabf1f`..`1f1ec3a` | 24-bit ISSI Pfad — Parser + AXI + CDC + MLE-FSM + SW + TBs | ✅ on-air ISSI 0x282F91 sichtbar, kein 523 mehr |
| 2026-04-25 03:17 | `545cc50` | MLE trigger: mm_type=2 (= U-LOC-UPDATE-DEMAND per `MmPduTypeUl`) | ✅ accept_cnt 0→53, Accepts on-air |
| 2026-04-25 05:10 | `b994e5d` | AACH dynamic Unalloc/Unalloc + 1-Frame Pre-Reply→Accept Gap | ✅ AACH SCH/F bit-exakt zur Gold-Ref, 1× BL-ACK NR=0 vom MS |
| 2026-04-25 12:18 | `26191b4` | MM-Body bit-exakte Gold-Ref-Replik (102 bit, GILA GSSI=0x2F4D61) + ra_flag=0 im Accept | ✅ **MTP3550 ITSI-Attach erfolgreich** — 1:1 Demand→Accept, kein Retry-Loop |
| 2026-04-25 16:28 | `9cc6607` | Phase 6 A — Subscriber-Shadow Permit-Check + REJECT-Encoder + REG_DB_POLICY @ 0x1AC | ✅ **on-air verifiziert** — `0x190=0x0001_0001` (1:1 Demand→Accept), `0x1AC=0x1` accept_unknown=1, kein Drop, kein Re-Demand-Loop |
| 2026-04-25 17:11 | (gleicher Build) | Phase A Strict-Mode-Test: `0x1AC=0` + leere DB → REJECT-Loop (18 Demands ungeacked); danach `tetra_db_mgr add 0 2633617 …` + sync → MS attached + BL-ACK | ✅ Beide Pfade (REJECT + ACCEPT-via-Shadow-Hit) on-air bestätigt |
| 2026-04-25 ~18:30 | `cae0ebc` | Phase 6 B — AST 64→128 bit, U-ITSI-DETACH räumt AST-Slot, mf_global_cnt 24-bit, REG_AST_DETACH_CNT @ 0x1A4 | ✅ on-air verifiziert (1:1 Demand→Accept), 0x1A4 bleibt 0 weil UL-RX-NUB-Gap (siehe ARCHITECTURE.md §7.2) |
| 2026-04-25 ~20:00 | `e51cc6c` | Phase 6 C — TTL-Sweep FSM intern in AST, dual-port BRAM, REG_AST_TTL_MULTIFRAMES @ 0x1A8 (default 84706 ≈ 24h), REG_AST_TTL_EVICT_CNT @ 0x1B0 | 🟡 deploy pending |

**Status: M2 + Phase A + B + C implementiert.** TTL-Sweep kompensiert die UL-RX-NUB-Lücke zeitbasiert — alte Sessions verfallen nach 24 h auch wenn der DETACH-PDU verloren geht.

### Gold-Reference-Capture (2026-04-25)

Simultaner DL+UL-Capture einer fremden TETRA-BS während erfolgreichem MS-Attach unter `docs/references/captures_external_bs_2026-04-25/`. Reproduktion:

```bash
python3 scripts/decode_dl.py \
  docs/references/captures_external_bs_2026-04-25/baseband_393084625Hz_00-11-52_25-04-2026.wav \
  --sr 250000 --max-bursts 50000 -v
```

Liefert 1278 valid bursts, inkl. der Burst-Pärchen #727 (SCH/HD AL-SETUP LI=7) + #735 (SCH/F BL-ADATA LI=21 D-LOC-UPD-ACCEPT) für ISSI=2 633 716.

---

## 9.1 Board-Vorbereitung für Phase 6 (Subscriber-DB)

Vor Phase A der Subscriber-DB-Implementierung (siehe `ARCHITECTURE.md §9`)
muss am Board folgendes angelegt sein:

```bash
# Subscriber-DB-Verzeichnis
sshpass -p openwifi ssh root@192.168.2.180 'mkdir -p /var/lib/tetra'

# Initiale entities.tsv anlegen (Format: slot ISSI/GSSI type profile_id valid)
sshpass -p openwifi ssh root@192.168.2.180 \
  'echo -e "0\t2633617\t0\t0\t1" > /var/lib/tetra/entities.tsv'
# (Slot 0, ISSI 0x282F91, type=ISSI, profile=0=minimal-permit, valid)

# tetra_db_mgr beim Boot starten — TODO für deploy.sh --init Phase E
```

Aktueller Status: **`/var/lib/tetra/` existiert nicht**, Subscriber-Shadow
am Board ist leer. `accept_unknown=1` Default macht das egal — jeder ISSI
darf attachen. Vor produktivem Betrieb: TSV initialisieren + tetra_db_mgr
als Daemon nach Phase E.

---

## 10. Script-Inventar

| Script | Zweck |
|--------|-------|
| `scripts/deploy.sh` | Build + Convert + Compile + Upload (+ optional Init) |
| `scripts/tetra_ctrl.sh` | Board-Steuerung (full_init, rf_loopback, monitor, read, write) |
| `scripts/ad9361_init.sh` | AD9361 stand-alone-Init (wird von full_init aufgerufen) |
| `scripts/decode_dl.py` | DL-Capture Decoder (MAC/LLC/MLE/MM-Parser) |
| `scripts/decode_ul.py` | UL-RA-Capture Decoder (41/42 CRC-Pass auf Live-Traces) |
| `scripts/decode_ul_raw.py` | Raw-Hex-Decoder für `tetra_ul_mon.log` Einträge |
| `scripts/wav_to_tkbits.py` | WAV → tetra-kit-Input-Format |
| `scripts/gold_schedule.py` | TX-Schedule-Generator (Gold-Preset-Loader) |
| `scripts/gen_sch_f_tv.py` | SCH/F-Test-Vektor-Generator (Python-Reference für TB-Goldens) |
| `scripts/verify_sb1_encoder.py` | BSCH-Encoder-Referenz (CRC16 + conv_enc + puncture) |
| `scripts/verify_sch_hu_decode.py` | SCH/HU-Decode-Reference (für UL RA) |
| `scripts/run_all_tests.sh` | Alle iverilog-TBs in einem Rutsch |
| `scripts/vivado_sim.tcl` | Vivado-xsim-Runner (alt, selten genutzt) |

---

## 11. Referenzen

- `ARCHITECTURE.md` — RTL/SW-Stack + Modul-Status
- `HARDWARE.md` — Board-Setup, AD9361, AXI-Regs, CDC, Timing
- `PROTOCOL.md` — TETRA-Protokoll, ETSI-Referenz, bluestation-Vergleich
- `.ralph/chat.md` — Kevin ↔ Ralph Arbeits-Kanal (separat)
