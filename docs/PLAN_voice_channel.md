# PLAN — Voice-Channel Phase C + E2

**Stand:** 2026-05-14 (Plan), umgesetzt zwischen 2026-05-14 und 2026-05-19.
**Quellen:** docs/IST.md, docs/ist/04_ul_rx.md, docs/ist/05_tx_datapath.md, Phase B Forensik aus `scripts/forensic_ul_nub.py` auf `wavs/reference/UL_Gruppenruf_*.wav`.

> **STATUS 2026-05-19 — Phase C + Phase E2 live + verifiziert.**
>
> Phase C: voller TCH/S Channel-Decode + Re-Encode in SW (statt
> ursprünglich geplantem bit-transparenten Pass-Through). Source:
> `sw/etsi_codec/` + Wrapper `sw/tetra_bs_tch_s.{c,h}` +
> `sw/tetra_voice_pipe.c`. Vorteil: UL-Bitfehler werden via FEC bereinigt
> bevor sie in den DL gehen. Nachteil: ARM-CPU-Last (akzeptabel, ~16 frames/s).
>
> **Phase E2 (commit `cae5108` vom 2026-05-18):** Soft-Decisions @ NUB-Capture.
> `tetra_ul_nub_capture.v` exportiert jetzt 432 × 4-bit signed Softs statt
> 1-bit hard. SW-Pfad nutzt soft-aware Viterbi (`tetra_bs_tch_s_decode_softi8`).
> BFI im 4-Run-Air-Test: Soft ~3 % vs Hard ~6 % (Median). Im 320-Burst
> Sustained-Sample: Soft 1 % vs Hard 7 % (7× Reduktion). Vivado-Kosten:
> +1.13 pp Slice (96.97 % → 98.10 %), WNS +0.114 ns (positiv).
>
> Komponenten der finalen Implementierung:
> - **UL:** `rtl/rx/tetra_ul_nub_capture.v` (in `rx_chain` + zweite
>   `ul_sync_detect_os4` mit NTS1-Pattern). Sample-Offsets gefixt in `8b0737e`.
> - **PS↔PL:** `tetra_voice_nub_read_mailbox` (UL) + `tetra_voice_filler_mailbox`
>   (DL).
> - **SW:** `sw/tetra_voice_pipe.c::tetra_voice_pipe_tick` — UL→ACELP→DL
>   roundtrip pro Burst. BFI 3-7 % cumulative.
> - **DL:** `tetra_burst_dispatcher` voice-Gate (`mask & vfill_valid`)
>   überschreibt Scheduler/Static im voice-slot.
> - **Call-FSM:** `sw/tetra_call_fsm.c` mit voice_pipe_tick im tick-Loop +
>   Watchdog (VOICE_QUIET_MS=300, CALL_STALE_MS=5000).
>
> Hardware-verifiziert: OpenEAR Audio durchgängig, 10-PTT-Test 2026-05-17.
> Offene Baustelle: D-CONNECT-Retransmit-Rate ~30 % beim Call-Setup
> (worst 3.6 s) — gehört in den AACH/D-CONNECT-Scheduling-Pfad, nicht in
> den Voice-Pfad selbst.
>
> Die untenstehende ursprüngliche Plan-Doku bleibt als historische
> Nachvollziehbarkeit erhalten — Decisions D1-D3 sind im Wesentlichen
> umgesetzt, D4 "bit-transparent" ist durch "SW decode+encode" ersetzt
> worden (Verbesserung).

## Ziel

Group-Call Voice-Audio-Relay zwischen zwei MS in derselben Gruppe:
1. MS-A drückt PTT → BS bestätigt (D-CONNECT, läuft schon)
2. MS-A sendet UL-Voice-Burst auf voice-slot (TCH/S NUB)
3. **BS empfängt UL-NUB, extrahiert 432 type-5 bits**
4. **BS emittiert DL-NDB1 auf voice-slot mit identischen 432 type-5 bits** (bit-transparent, cell-scrambler ESN=0 ist UL+DL identisch in TMO)
5. MS-B (andere im Gruppen-Call) empfängt DL-NDB1 → spielt Audio ab
6. 1-Frame-Latenz (~56 ms) zwischen UL-RX und DL-Emit ist akzeptabel

## Decision-Lock (aus B3, 2026-05-14)

### D1 — UL-TCH/S-Sync-Korrelator (Re-Lock 2026-05-14)

**`tetra_ul_sync_detect_os4.v` parametrisieren + zweimal instantiieren.** Erste Lock-Version war "eigenes Modul parallel"; Re-Lock auf "refactor existing → param + 2× inst" weil:
- Eine Codebase, isolierte Instanzen (kein Race, kein Shared-State-Risk)
- Future-Mods am Korrelator (z.B. CORR_WIDTH-Bugfix, neue Phase-Strategie) gelten automatisch für beide Konsumenten
- LUT-Kosten identisch zur "eigenes Modul"-Variante (zwei Instanzen)
- TB testet das Modul-Template, nicht zwei separate Implementierungen

**Implementation:** Parameter `SYNC_PATTERN [29:0]` + `SYNC_LEN_SYM` (default = ETS_REF / 15 = bisheriges Verhalten). corr_count() von 15-fixed-term-Adder auf for-loop über SYNC_LEN_SYM. Zwei Instanzen: `u_ul_sync_ra` (x-seq, 15 sym) + `u_ul_sync_nub` (NTS1, 11 sym).

### D2 — UL Slot-Alignment

**DL-FN + 2-TS-Offset als Anker, NTS1-Sync verfeinert.** Kein separater UL-FN-Counter. Voice-Slot-Erwartungsfenster aus `tx_tdma_state_fn_sys` + Voice-Slot-Mask, exakte Burst-Position kommt aus NTS1-Korrelator.

### D3 — DL-Voice-Inject

**Direkt im `tetra_burst_dispatcher.v` über neuen voice-override-Mux-Pfad.** NICHT über `tetra_dl_signal_queue` (Voice ist kein Signaling, Queue-Misuse macht Code semantisch unklar). Dispatcher selektiert pro TN:
1. **voice_override** (wenn `voice_active_mask[tn]==1` UND `voice_relay_valid[tn]==1`)
2. **sched_signalling** (wenn `sched_active_sys[k]||bus_is_signal()`)
3. **static_schedule** (default)

### D4 — Slice-Budget

**+ ~1 % Slice akzeptiert** (~550 LUT total: `ul_nub_sync` 150 + `ul_nub_capture` 250 + `voice_relay` 100 + dispatcher-mux 50).
Aktuell 96.45 % → erwartet ~97.5 %. Falls Timing-Issues nach Phase C: `dl_pdu_builder.usage_marker` hardcoded `11` → SW-Register (Phase D2) für Reserve.

## NUB-Burst-Layout (verbindlich)

Aus `rtl/tx/tetra_burst_builder.v` NTS1_REF + ETSI §9.4.4.3.4. 253 Symbole = 14.06 ms @ 18 kHz.

| Feld | Symbole | Bits | Position (Sym 0 = TAIL1) |
|------|---------|------|--------------------------|
| TAIL1 | 6 | 12 | 0..5 |
| BKN1 | 108 | 216 | 6..113 |
| BB1 | 7 | 14 | 114..120 |
| **NTS1** (Sync) | **11** | **22** | **121..131** |
| BB2 | 8 | 16 | 132..139 |
| BKN2 | 108 | 216 | 140..247 |
| TAIL2 | 5 | 10 | 248..252 |

**NTS1 Dibit-Pattern** (MSB-first, identisch UL+DL NDB1):
```
11 01 00 00 11 10 10 01 11 01 00
```

**432 type-5 Voice-Bits** = BKN1 (216 bits) + BKN2 (216 bits) **als ein Stück**, ohne BB1/NTS1/BB2/Tails. Cell-Scrambler ESN=0 in TMO → UL-coded-bits sind direkt DL-coded-bits (bit-transparent).

## Modul-Spec für Phase C

### C1 — `rtl/rx/tetra_ul_sync_detect_os4.v` (REFACTOR — parametrisieren)

**Patch:** Add Parameter `SYNC_PATTERN [29:0]` (default = bisheriger ETS_REF x-seq) und `SYNC_LEN_SYM` (default = 15). `corr_count()` von 15-Term-Adder auf for-loop über SYNC_LEN_SYM (Verilog-2001 Part-Select `xr[2*i +: 2]`). HOLDOFF bleibt Parameter wie bisher.

**Instances in `rtl/rx/tetra_rx_chain.v`** (oder zynq_top, je nach existing):
```verilog
tetra_ul_sync_detect_os4 #(
.SYNC_PATTERN(ETS_REF), // default
.SYNC_LEN_SYM(15),
.HOLDOFF(50)
) u_ul_sync_ra (... );

tetra_ul_sync_detect_os4 #(
.SYNC_PATTERN({8'b0, NTS1_REF_22bit}), // NTS1 in [21:0], top 8 zero
.SYNC_LEN_SYM(11),
.HOLDOFF(250) // 1 Voice-Frame ≈ 250 samples @ 72 kHz post-RRC
) u_ul_sync_nub (... );
```

**LUT-Schätzung:** ~300 für beide Instanzen zusammen (vs. ~300 für nur RA bisher — wir gewinnen Sync-Funktionalität ohne Slice-Kosten zu verdoppeln, weil for-loop bei kleinerem LEN auch kleinerer Adder).

### C2 — `rtl/rx/tetra_ul_nub_capture.v` (NEU)

**Ports:**
```verilog
module tetra_ul_nub_capture (
 input wire clk_sys,
 input wire rst_n_sys,
 input wire signed [15:0] i_in_sys,
 input wire signed [15:0] q_in_sys,
 input wire valid_in_sys,
 input wire sync_found_sys,
 input wire [1:0] best_phase_sys,

 output reg [431:0] coded_bits_sys, // BKN1+BKN2 = 432 type-5 bits
 output reg coded_valid_sys, // 1-cycle pulse on completion
 output reg [15:0] bursts_captured_sys
);
```

**Funktion (analog `tetra_ul_burst_capture.v`):**
- Ringbuffer 512×16 für I+Q (parallel zu existing capture, oder shared mit Mux)
- Bei `sync_found_sys`: Anchor = NTS1-Position, dann
 - back: 121 symbols × 4 sps = 484 samples zurück → BKN1-Start
 - forward: 108 sym BKN1, skip 7 sym BB1 + 11 sym NTS1 + 8 sym BB2 = 26 sym, 108 sym BKN2
- Phase-aligned demod (best_phase_sys) → 432 hard dibits MSB-first in `coded_bits_sys`
- Pulse `coded_valid_sys` 1 Zyklus bei Last-Dibit-In

**LUT-Schätzung:** ~250

### C3 — `rtl/lmac/tetra_voice_relay.v` (NEU)

**Ports:**
```verilog
module tetra_voice_relay (
 input wire clk_sys,
 input wire rst_n_sys,
 input wire [3:0] voice_active_mask_sys,
 input wire [1:0] voice_slot_tn_sys, // = lowest set bit in mask
 input wire [431:0] ul_coded_bits_sys,
 input wire ul_coded_valid_sys,
 input wire dl_slot_pulse_sys,
 input wire [1:0] dl_tn_sys,

 output reg [431:0] relay_blk_sys, // BKN1+BKN2 für dispatcher
 output reg relay_valid_sys, // = 1 wenn relay_blk frisch
 output reg [15:0] relay_cnt_sys
);
```

**Funktion:**
- 1-Frame-Buffer: latch `ul_coded_bits` bei `ul_coded_valid` Pulse
- Aktiviere `relay_valid_sys` für genau 1 DL-Frame auf dem voice_slot_tn
- Bei nächstem `ul_coded_valid` → neuer Buffer überschreibt → frische Frame
- Wenn 56 ms ohne `ul_coded_valid`: relay_valid_sys → 0 (no-fresh-data, dispatcher fällt zurück auf static-schedule)
- Counter inkrementiert pro emittiertem DL-Voice-Burst

**LUT-Schätzung:** ~100

### C4 — `rtl/tx/tetra_burst_dispatcher.v` (PATCH)

Per-TN-Case-Block erweitern:
```verilog
case (tx_slot_num_sys)
2'd0: begin
 if (voice_active_mask_sys[0] && relay_valid_sys && voice_slot_tn_sys == 2'd0) begin
 sel_blk1_w = relay_blk_sys[431:216];
 sel_blk2_w = relay_blk_sys[215:0];
 sel_burst_type_w = 1'b0; // NDB1 (SCH/F)
 sel_ndb2_w = 1'b0;
 sel_enable_w = 1'b1;
 end else if (sched_active_sys[0] || bus_is_signal(...)) begin
 // existing scheduler path
 end else begin
 // existing static schedule
 end
end
// analog 2'd1, 2'd2, 2'd3
```

**LUT-Schätzung:** +50

### C5 — AXI-Register (Phase C — neu in `tetra_axi_lite_regs.v`)

| Addr | Name | R/W | Bedeutung |
|------|------|-----|-----------|
| 0x1F0 | REG_VOICE_NUB_RX_CNT | RO | bursts_captured_sys aus `ul_nub_capture` |
| 0x1F4 | REG_VOICE_RELAY_CNT | RO | relay_cnt_sys aus `voice_relay` |
| 0x1F8 | REG_VOICE_NUB_SYNC_THRESH | R/W | corr_threshold für ul_nub_sync (default 8) |

(Hinweis: 0x1F4 ist im Working-Tree-Stand `REG_AACH_GRANT_HINT`. Prüfen vor Umverdrahtung.)

### C6 — `rtl/tetra_zynq_top.v` (PATCH)

Neue Module instanziieren + verkabeln:
- `u_ul_nub_sync` + `u_ul_nub_capture` parallel zum existing `u_ul_sync_detect_os4` / `u_ul_burst_capture` (gemeinsamer Post-RRC IQ aus rx_chain)
- `u_voice_relay` zwischen capture-Output und dispatcher-Voice-Override-Input
- `voice_active_mask_sys_r1[1:0]` Bit-Index aus `voice_active_mask_sys_r1` (lowest set → `voice_slot_tn_sys`)

### C7 — Test-Bench (NEU `tb/tb_ul_nub_e2e.v`)

End-to-End TB: stimuliere IQ-Samples eines synthetic NUB-Bursts (TAIL1 + zufällige BKN1 + BB1 + NTS1 + BB2 + zufällige BKN2 + TAIL2), prüfe:
- `tetra_ul_nub_sync` triggert `sync_found_sys` an erwarteter Position
- `tetra_ul_nub_capture` produziert 432-bit-Output identisch zu BKN1+BKN2 von Stimuli
- `tetra_voice_relay` puffert + pulst auf nächstem DL-Slot
- `tetra_burst_dispatcher` wählt voice_override-Pfad

**Reference-Vector** aus `scripts/forensic_ul_nub.py` Burst-Index 4 der -UL-WAV: 432-bit BKN1+BKN2 als Reference.

## Pipeline-Stages

```
AD9361 → rx_frontend (CIC+RRC) → 72 kHz IQ
 │
 ├─→ ul_sync_detect_os4 (x-seq, RA)
 ├─→ ul_nub_sync (NTS1, NUB) ← NEU C1
 │
 ├─→ ul_burst_capture (RA-format)
 └─→ ul_nub_capture ← NEU C2
 │
 │ coded_bits[431:0] + valid
 ▼
 voice_relay ← NEU C3
 │
 │ relay_blk[431:0] + valid
 ▼
 burst_dispatcher ← PATCH C4
 │
 │ sel_blk1/blk2 (voice-override)
 ▼
 tx_chain → AD9361 DAC
```

## Acceptance-Kriterien Phase C Air-Test

1. **`REG_VOICE_NUB_RX_CNT` inkrementiert** während MS-A PTT (= UL-NUB-Bursts werden empfangen)
2. **`REG_VOICE_RELAY_CNT` inkrementiert** mit ~gleicher Rate (1 zu 1 mit RX-CNT, ggf. -1 Drop bei Sync-Miss)
3. **decode_dl.py auf RTL-SDR-Capture zeigt TN=voice_slot mit non-NULL-Body** auf NDB1-Slots während PTT (statt SB-SYSINFO-Fallback)
4. **Zweite MS in Gruppe spielt Audio von erster MS** ab — der eigentliche User-Acceptance-Test
5. **Y.4.1 AACH-Pattern bleibt unverändert** (0x32CB / 0x22C9 / 0x2049 FN-Rotation per existing logic)

## Risk Register

| Risk | Mitigation |
|------|-----------|
| NTS1-Sync-Score in Real-Cell < 8/11 wegen schwächerem MS-Signal | REG_VOICE_NUB_SYNC_THRESH konfigurierbar, Air-Test sweep 6..10 |
| Voice-Burst-Timing relativ zu DL-FN driftet (MS-Timing-Advance) | Capture nutzt absolute NTS-Sync-Position, kein DL-FN-relativ |
| Slice >97.5 % nach Phase C → Timing-Closure-Fail | usage_marker-Refactor + tx_inv_sinc-Pattern (toter Code längst raus) ggf. mehr Reserve |
| bit-transparent-Relay-Annahme falsch (e.g. ESN != 0) | Live-Test: erste MS-B Reception → wenn nicht decodierbar, scrambler-Bridge in voice_relay einbauen (XOR mit cell-scrambler-Seq) |
| Voice-Slot wechselt während Call (UL- vs DL-TN-Mismatch) | voice_active_mask_sys[3:0] eindeutig: aktuell nur 1 Bit gleichzeitig per SW-Konvention; multi-bit support kommt in Phase D2 |

## Phase-C-Commit-Plan

EIN Commit, EINE Vivado-Rebuild, EIN Air-Test (per `feedback_no_salami_one_shot_fix`).

Files in Commit:
- `rtl/rx/tetra_ul_nub_sync.v` (neu)
- `rtl/rx/tetra_ul_nub_capture.v` (neu)
- `rtl/lmac/tetra_voice_relay.v` (neu)
- `rtl/tx/tetra_burst_dispatcher.v` (patch — voice-override-mux)
- `rtl/rx/tetra_rx_chain.v` (patch — neue Outputs/instances oder Top-level-Verdrahtung)
- `rtl/tetra_zynq_top.v` (patch — Modul-Instanzen + voice_slot_tn-Berechnung)
- `rtl/infra/tetra_axi_lite_regs.v` (patch — 3 neue Register)
- `scripts/vivado_build.tcl` (patch — neue Files in Source-Liste)
- `tb/tb_ul_nub_e2e.v` (neu)
- `sw/tetra_hal.h` (patch — neue REG-Defines)

## Was NICHT in Phase C

- D-TX-CEASED / Hangtime (Phase D1)
- Multi-Call-Support / dynamic UsageMarker (Phase D2)
- ACELP-Decode/Encode (nie — bit-transparent ist Lock)
- UL voice-burst content auswerten / loggen für Debug (Phase D3 falls nötig)

## Forensik-Skript-Output für TB-Reference-Vector

`scripts/forensic_ul_nub.py` Burst-Index 4 der -UL-WAV ist der erste klar lange Burst (20ms, dual-slot). Bessere Reference-Vector: **manuell ein synthetic NUB im TB generieren** (Stimulus aus bekannten TAIL1+random-BKN+NTS1+random-BKN+TAIL2-Bits), und Erwartungswert = die Random-Bits selbst. Damit ist die Capture-Funktion direkt durch Round-Trip prüfbar ohne Real-Hardware-Capture-Drift.
