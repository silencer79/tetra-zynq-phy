# IST 13 — FPGA/SW-Grenze: Code-Inventur + logische Trennpunkte

**Stand:** 2026-07-02 · Branch `main`
**Methode:** 6 Lese-Agenten über die lokalen Dateien, jede Behauptung `file:line`-belegt,
RTL-Instanziierung per grep in `rtl/tetra_zynq_top.v` verifiziert. Adversarialer Faktencheck:
**13/14 Kernbehauptungen gegen echte Dateien bestätigt**, keine erfundenen Module. Eine
korrigierte Zeilenangabe (s. §6).

> Dieses Kapitel mischt bewusst **IST-Inventar** (§1–§4, reine Fakten) mit einem als solchem
> markierten **Bewertungsteil** (§5 Trennpunkte). Der IST-Teil folgt der `docs/IST.md`-Regel
> „was der Code TUT"; §5 ist explizit Empfehlung.

## 1. Das Trennkriterium: Slot-Deadline

Die Grenze folgt (überwiegend) einem klaren Prinzip: **Was vor dem Emit von Slot N fertig
sein muss, gehört ins FPGA. Was event-getrieben mit >14 ms Spielraum läuft, gehört in SW.**

- **FPGA** (hart-echtzeit): Sample-DSP am ADC/DAC, TDMA-Timing, Burst-Staging, BSCH-SB1 +
  AACH (FN/MN/TN-Lookahead), generische Fragment-Reassembly (per-Frame-T0).
- **SW** (event, >14 ms): MM/CMCE/SDS/Call-Policy, Voice-Transcode, SCH/F-Kanalcodierung für
  Broadcast/SDS/Voice, das Parsen zusammengesetzter Bodies.

Genau **ein** Bereich verletzt dieses Kriterium: die DL-Signalling-Codierung (§5 T1).

## 2. Domänenkarte — was läuft wo

| Seite | Domäne | Einheiten | Beleg (Auswahl) |
|---|---|---|---|
| FPGA | Sample-DSP | rx_frontend (CIC R=64 + RRC, 72 kHz), timing_recovery, pi4dqpsk_demod/mod, sync_detect, ul_sync_os4 ×2, ul/nub_capture, rrc_filter, tx_frontend | `rx_chain.v:244` (CIC R=64), `top:304` (ad9361_adapter) |
| FPGA | TDMA/Timing | tdma_timebase, slot_schedule/content_mux, burst_dispatcher, burst_builder, frame_counter, dl_signal_queue + scheduler | `top:1887`, `top:1191`, `top:2497/2558` |
| FPGA | Codec (berechtigt) | ul_sch_hu/f_decoder + ul_viterbi_r14, crc16; **sb1_encoder (BSCH)**, **aach_encoder** — slot-deadline-gebunden | `top:3983`, `top:4096` |
| FPGA | Reassembly | ul_demand_reassembly (147-bit Body), ul_schf_reassembly (Long-SDS) | `top:746`, `top:830` |
| Grenze | Mailboxen/Regs | voice_nub_read 0x280, ul_demand_body 0x250, voice_filler 0x270, reply 0x220, nwrk_bcast 0x1D0; axi_lite_regs **@0x43C0_0000** | `top:3588/3184/3494/3354`, `hal.h:21` |
| SW | Protokoll | call_fsm (stage_d_*), react_mm2/mm7, mm_demand_parser (walk_mm2/7), cmce_parse, cmce/grpack/sds-body-builder | `tetra_call_fsm.c`, `tetra_attach_daemon.c` |
| SW | Codec | **tetra_codec_schf_encode (live)**, tch_s-Voice-Codec (ACELP + Viterbi), bnch/nwrk-Encode | `channel_codec.c:131`, `tetra_bs_tch_s.c` |
| SW | Daemon | attach_daemon (1 Prozess, 1 Thread, 10 ms Poll), tx_transport (stage_raw_mm), voice_pipe, hal | `attach_daemon.c:992`, `tx_transport.c:165` |

## 3. Tote / nicht-instanziierte Einheiten (Slice-neutral — NICHT bei ~98 % entfernen)

- **`tetra_lmac`-Baum** (9 Module: viterbi_decoder, reed_muller, scrambler, interleaver,
  deinterleaver, rcpc_encoder, depuncture_r23, steal_detect): 0 Instanzen in `tetra_zynq_top.v`
  (nur Modul-Def `rtl/lmac/tetra_lmac.v:31`, Top-Zeilen 14/35 sind Kommentare).
- **`tetra_axi_dma_bridge`**: 0 Instanzen, `m_axis` tie-off `top:935` (alter DL-Decode→DMA-Pfad
  entfernt `b92f47e`). Ggf. noch als IP in der Block-Design.
- **SW**: `tetra_codec_schf_decode` (`channel_codec.c:311`, kein Aufrufer), `tetra_etsi_tch_s.c`
  (komplett), diverse Legacy-AACH-in-SW-Helfer.

## 4. Die vier durchgehenden Ketten (mit Grenz-Übergang)

**DL-Signalling** (MM/CMCE — der Fehl-Trennpunkt):
```
[SW]  call_fsm/attach_daemon baut MM/CMCE-Body-Bits (cmce_body.c/grpack_body.c) — NUR Body, kein Header, keine Codierung
[SW]  stage_raw_mm packt raw Body + Meta (tx_transport.c:165)
[AXI] REG_REPLY 0x220/0x224/0x228 → reply_mailbox (clk_axi→clk_sys)
[FPGA] mle_registration_fsm (top:2361) triggert dl_pdu_builder (top:3037)
[FPGA] mac_resource_dl_builder baut MAC-Header + LLC + chan_alloc (carrier 0x5FA @dl_pdu_builder.v:188)
[FPGA] sch_f_encoder: CRC16+RCPC+Interleave a=103+Scramble → 432 type-5 (dl_pdu_builder.v:222)  ← identisch zu C-Encoder
[FPGA] dl_signal_queue → scheduler → burst_dispatcher → tx_chain → Antenne
```
→ Grenze liegt **unterhalb** der Kanalcodierung: SW liefert nur Body, RTL macht Header+SCH/F.

**UL-Empfang:**
```
[FPGA] AD9361 → rx_frontend → ul_sync_os4#1 → ul_burst_capture → ul_demod → ul_sch_hu_decoder+viterbi → 92 info+CRC
[FPGA] ul_mac_access_parser (rx_chain.v:506): frag1_pulse+mm_type als Trigger LIVE; volle Felder → AXI ul_mon (0x1B4) weitgehend TOT
[FPGA] ul_demand_reassembly → 147-bit Body + 13-bit Meta (top:746)
[AXI]  ul_demand_body_mailbox REG_UL_DEMAND_BODY 0x250 (FPGA→SW, raw)
[SW]   service_uldbod → uldbod_unpack → mm_demand_parser walk_mm2/7 → react_mm2/mm7 (RE-PARST den rohen Body)
```
→ RTL exportiert parsed Felder UND raw parallel; SW parst raw → RTL-Feld-Export ist Duplikat.

**Voice-Relay** (sauberes Referenz-Muster):
```
[FPGA] rx_frontend → ul_sync_os4#2 (NTS1) → ul_nub_capture → 432×4-bit soft (1728 bit)
[AXI]  voice_nub_read_mailbox 0x280 (FPGA→SW, reine Soft-Bit-Pipe)
[SW]   voice_pipe_tick → tetra_bs_tch_s_decode_softi8 (Descramble→Deint→Viterbi→CRC→ACELP) → re-encode → 432 type-5
[AXI]  voice_filler_mailbox 0x270 (SW→FPGA, fertiges type-5)
[FPGA] burst_dispatcher (per-TS Voice-Bank) → tx_chain → Antenne
```
→ Gesamte Kanalcodierung in SW, RTL reine Bit-Pipe. **Vorbild für einen sauberen Codec-Trennpunkt.**

**Broadcast/SYSINFO:**
```
[SW]  build_schf_sysinfo + tetra_schf_encode → 432 type-5 (hal.c:990); bnch_encode 124→216 SCH/HD
[AXI] REG_BNCH 0xF8 / SB_BKN2 0x60 / NDB 0x88 / MCCH 0xC0 / NWRK_BCAST 0x1D0 (SW→FPGA, fertiges type-5)
[FPGA] dl_nwrk_broadcast (top:2815) → queue; sb1_encoder (BSCH, top:3983) + aach_encoder (top:4096) SLOT-gekoppelt
[FPGA] burst_dispatcher → tx_chain → Antenne
```
→ SCH/F-Broadcast in SW (clean); BSCH/AACH im RTL (slot-deadline-berechtigt). **Sauber.**

## 5. Logische Trennpunkte (BEWERTUNG — Empfehlung, nicht IST)

| # | Bereich | Status | Heute → Sollte | Slice |
|---|---|---|---|---|
| **T1** | **DL-Encode** | ⚠️ **verschieben** | SW liefert nur Body, RTL baut MAC-Header + SCH/F → **SW baut komplette type-5-PDU** (C-Encoder `channel_codec.c:131` läuft schon live) und pusht sie fertig wie Voice/SDS/BNCH. RTL-Kette `dl_pdu_builder`+`mac_resource_dl_builder`+`sch_f_encoder`+`mle_registration_fsm` entfällt; queue/scheduler/dispatcher bleiben. | **gibt frei** |
| **T2** | **UL-Parse** | ⚠️ verschieben | RTL parst Felder *und* liefert raw; SW re-parst raw → **RTL-Feld-Export (0x1B4, ul_llc_ns/nr, mm_type) streichen**, `ul_mac_access_parser` nur noch als Reassembly-Trigger + CRC-Gate. | gibt frei |
| T3 | Voice-Codec | ✅ sauber | unverändert (Codec in SW, RTL Bit-Pipe) | — |
| T4 | Reassembly | ✅ sauber | unverändert (braucht Frame-T0-Timing → FPGA) | — |
| T5 | Broadcast | ✅ sauber | SCH/F in SW, BSCH/AACH in RTL — nach Slot-Deadline korrekt getrennt | — |
| T6 | TDMA/PHY | ✅ sauber | unverändert; interner Aufräumpunkt (kein Grenz-Thema): DL-RX-als-Timebase-Loopback pensionieren, `frame_tick` aus TX-Timebase speisen | — |

**T1 ist der einzige echte Bruch** und gibt bei ~98,66 % Slice als einziger Trennpunkt Fläche frei.
Phase 1/1b des SW-Moves ist bereits offline gebaut auf Branch `feat/dl-encode-sw-offload`
(SW-Builder für D-LOC-UPDATE-ACCEPT / GRP-ATTACH-ACK / LU-REJECT, `test_lu_accept` 18/18,
`test_reply_pdu` 32/32). Siehe Memory `project_fpga_sw_boundary_audit`.

## 6. Faktencheck-Korrektur

Eine Zeilenangabe der Erst-Inventur war falsch: Carrier `0x5FA` ist real hardcoded, aber in
`rtl/lmac/tetra_dl_pdu_builder.v:188` (`12'h5FA`, Kommentar :174 „UNSERE Zelle"), **nicht** in
`tetra_mac_resource_dl_builder.v` — dort ist `0x5FA` nur als 32-bit-Port `chan_alloc_element`
Input (`:124`). Der Fakt (Carrier + MAC-Header-Bau im RTL) stimmt, die Fundstelle ist korrigiert.

Weiterer belegter Detailpunkt: die AXI-Basis ist real **`0x43C0_0000`** (`hal.h:21` + BD
`create_bd.tcl`); der Top-Kommentar `tetra_zynq_top.v:117` nennt fälschlich `0x4000_0000`
(= GP0-Apertur, nicht die Slave-Basis).
