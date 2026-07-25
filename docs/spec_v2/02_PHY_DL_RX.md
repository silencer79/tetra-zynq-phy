# 02 — Downlink-Empfangs-PHY

**Scope:** Die DL-gerichtete Empfangskette vom AD9361-Sampletakt bis zum
Burst-Feld: CDC, CIC-Dezimation, RRC-Matched-Filter, Symbol-Timing-Rückgewinnung,
differentieller π/4-DQPSK-Demodulator, Korrelator auf die Trainingssequenzen,
Burst-Demultiplexer, TDMA-Zähler, Roh-IQ-Messabgriff.

**Nicht hier:** UL-Empfangskette (→ `03_PHY_UL_RX.md`); Kanaldecodierung ab
Descrambling, Deinterleaving, Viterbi, CRC, RM(30,14) (→ `05_CHANNEL_CODING.md`);
AACH-Semantik und MAC-Feldbedeutung (→ `06_MAC.md`); Sendepfad und TDMA-Zeitbasis
(→ `04_PHY_TX_TDMA.md`); Registeradressen (→ `07_PS_PL_CONTRACT.md`);
Slot-Deadlines und gemessene Latenzen (→ `08_TIMING.md`).

**Abhängigkeiten:** `01_PLATFORM.md` (Takte, Resets, AD9361-Konfiguration,
Ressourcen-Budget). Für die Weiterverarbeitung der Blockdaten `05` und `06`.

---

## 1. Anforderungen

| ID | Anforderung | Prüfkriterium |
|---|---|---|
| R-02-01 | Die Kette dezimiert 4 608 000 Sa/s komplex auf 72 000 Sa/s = 4 Samples/Symbol bei 18 000 Symbol/s [ETSI §4.5.3, §4.7]. | Zähler `fe_sample_cnt` (§3.11, V-02-10 a) steigt um 72 000 ± 1 pro Sekunde. |
| R-02-02 | Der Empfangsfilter ist ein Root-Raised-Cosine mit α = 0,35 [ETSI §5.5, Gl. 5.4]. | Koeffizienten-Vergleich gegen Referenzgenerator, Abweichung ≤ 2 LSB bei Q14. |
| R-02-03 | Der Demodulator bildet die Differenzphase gemäß [ETSI Tabelle 5.1] auf Dibits ab: 00 → +π/4, 01 → +3π/4, 10 → −π/4, 11 → −3π/4. | Testvektor mit allen vier Übergängen, bit-exakt. |
| R-02-04 | Die Symbol-Timing-Rückgewinnung erreicht Lock aus beliebiger Startphase innerhalb von ≤ 1 TDMA-Frame (4 Slots ≙ 4 · 255 = 1020 Symbole) [ETSI §4.5.2] ohne externe Hilfe. | Simulation mit ±1 Sample Startfehler; `timing_locked` innerhalb 1020 Symbolen. |
| R-02-05 | Der Korrelator erkennt Normal Training Sequence 1 und 2, Extended Training Sequence und Synchronisation Training Sequence mit den in §3.6 belegten Bitmustern. | Bit-Vergleich der RTL-Konstanten gegen [ETSI Gl. 9.4/9.5/9.9/9.11]. |
| R-02-06 | Der Burst-Demultiplexer extrahiert für jeden erkannten Burst die Felder gemäß [ETSI Tabelle 9.7] (NCDB) bzw. [ETSI Tabelle 9.9] (SCDB) — nicht nach einem selbst erfundenen Feldraster. | Feldgrenzen-Tabelle in §3.7 gegen ETSI; Gold-Bitvergleich (§5). |
| R-02-07 | Alle Bitfelder verlassen die Kette MSB-first in Sendereihenfolge: Bit `[N−1]` ist das zuerst empfangene Bit. | Testvektor mit asymmetrischem Muster. |
| R-02-08 | Die DL-Empfangskette liefert **keine** operative Zeitbasis für andere Teilsysteme. Frame-Ticks, T0-Timer und Slot-Grants stammen aus der TX-TDMA-Zeitbasis (→ `04`, `08`). | Netzlisten-Prüfung: kein Pfad von `tetra_dl_frame_counter` in UL-Reassembly oder Scheduler. |
| R-02-09 | Die Kette ist zur Build-Zeit abschaltbar (`RX_DL_ENABLE = 0`) und der Rest des Systems bleibt voll funktionsfähig. | Zwei Builds; Air-Test-Parität bei abgeschaltetem DL-RX. |
| R-02-10 | Der Roh-IQ-Abgriff nach RRC ist über AXI auslesbar, ohne den Datenpfad zu verändern. | Capture-Drain 8192/8192 Samples, `wr_ptr` stabil nach Freeze. |
| R-02-11 | Kein einzelner Kombinatorik-Pfad in dieser Kette darf den 100-MHz-Takt (10 ns) über 8 ns Logik+Route belasten. | `report_timing` pro Modul; WNS-Beitrag der RX-Kette ≥ +2 ns. |
| R-02-12 | Sättigung ist an jeder Wortbreitenreduktion explizit implementiert (kein stilles Wrapping) und über einen Zähler beobachtbar. | Simulation mit Vollausschlag-Eingang; Sättigungszähler > 0, kein Vorzeichenwechsel. |

---

## 2. Architektur / Aufbau

### 2.1 Signalkette und Datenraten

```
AD9361 (LVDS)                      clk_lvds = 18,432 MHz
  │  I,Q 16 bit signed, rx_valid @ 4,608 MHz
  ▼
tetra_rx_frontend                                        ← gemeinsam mit Kapitel 03
  ├─ XPM async FIFO      clk_lvds → clk_sys
  ├─ CIC-Dezimator       R=64, N=5, M=1     4,608 MHz → 72 kHz
  └─ RRC-Matched-Filter  33 Taps, α=0,35    72 kHz (4 Sa/Symbol)
  │  i_out_sys/q_out_sys 16 bit, out_valid_sys @ 72 kHz
  ├──────────────────────────────► tetra_rx_iq_capture   (Messabgriff)
  ├──────────────────────────────► UL-Kette              (Kapitel 03)
  ▼
tetra_dl_timing_recovery   Gardner-TED + 32-bit-NCO      72 kHz → 18 kHz
  │  i_out_sys/q_out_sys, sample_valid_out_sys @ 18 kHz (On-Time-Sample)
  ▼
tetra_dl_pi4dqpsk_demod    CORDIC-Vectoring + Differenzphase
  │  dibit_out[1:0], dibit_valid @ 18 kHz
  ├──────────────────────────────┐
  ▼                              ▼
tetra_dl_sync_detect        tetra_dl_burst_demux
  │  sync_found, sync_locked,    │  block1/block2/bb, slot_valid
  │  burst_sym[7:0], ts_kind     ▼
  └──────────────────────────► tetra_dl_frame_counter → TN/FN/MN/HF (Diagnose)
```

**Rate-Kette, exakt:** `clk_lvds` = 18,432 MHz = 4 × 4,608 MHz
[CODE rtl/tx/tetra_tx_frontend.v:13-14]; AD9361-Samplerate 4 608 000 Sa/s
[CODE board_autostart/tetra_cell.conf:8]; 4 608 000 / 64 = 72 000 = 4 × 18 000
[CODE rtl/rx/tetra_rx_frontend.v:74-75]. Symbolrate 18 000 Symbol/s folgt aus
255 Symbolen je Zeitschlitz von 85/6 ms [ETSI §4.5.3] und der Symboldauer
500/9 µs [ETSI §4.5.3].

### 2.2 Taktdomänen

| Domäne | Frequenz | Inhalt | Suffix |
|---|---|---|---|
| `clk_lvds` | 18,432 MHz | AD9361-Fabric-Interface, FIFO-Schreibseite | `_lvds` |
| `clk_sys` | 100 MHz | gesamte Verarbeitung ab FIFO-Leseseite | `_sys` |
| `clk_axi` | 100 MHz (PS FCLK0) | Register, IQ-Capture-Leseseite | `_axi` |

**Verbindlich für V2:** Alle Module dieser Kette laufen in **einer** Domäne
`clk_sys`. Symbol- und Sampletakte sind Valid-Strobes, keine eigenen Takte.
V1 vergab in denselben Modulen die Suffixe `_sample` und `_sys` für **dieselbe**
physische Domäne (`tetra_rx_chain` verdrahtet `.clk_sample(clk_sys)`
[CODE rtl/rx/tetra_rx_chain.v:310, 346, 560, 580]) — daraus entstand die Fehl-
dokumentation eines nicht existierenden CDC `clk_sample → clk_sys` in der
gedrifteten IST-Doku (`docs/HARDWARE.md:260`, dort zusätzlich einem falschen
Modul zugeschrieben). In V2 gilt ausschließlich `_sys`.

Reale CDC in dieser Kette: genau drei Richtungen.
1. `clk_lvds → clk_sys`: XPM-Async-FIFO, 32 bit, Tiefe 16, `READ_MODE="std"`,
   `FIFO_READ_LATENCY=1`, `CDC_SYNC_STAGES=2` [CODE rtl/rx/tetra_rx_frontend.v:223-238].
2. `clk_sys → clk_axi`: Statusbits über 2-FF-Synchronizer; Mehrbit-Zählerstände
   nur mit Gray-Kodierung **oder** über ein Freeze-/Handshake-Protokoll
   (siehe §3.10 und Abschnitt 6, Punkt 6).
3. `clk_axi → clk_sys`: Einzelbit-Steuersignale (`freeze` des IQ-Capture,
   `clear_peak`, Zählerresets) über 2-FF-Synchronizer mit `ASYNC_REG`
   [CODE rtl/rx/tetra_rx_iq_capture.v:51-60]. Mehrbit-Konfigurationswerte dieser
   Kette — die DL-Korrelationsschwellen aus `REG_RX_SYNC_CFG_DL` (`07 §3.1.4`) —
   sind quasi-statisch und werden **nicht** synchronisiert; sie dürfen nur im
   gestoppten Zustand (`RX_DL_ENABLE`-Gate bzw. vor Sync-Aufbau) geschrieben
   werden. Die CIC-Ausgangsverstärkung überquert diese Grenze **nicht**: sie ist
   Syntheseparameter, kein Registerwert (§3.2). Die UL-Schwellen liegen in einem
   eigenen Register und tragen dort ihre eigene, laufzeitfähige Übergabe
   (`03 §3.3`, R-03-03).

**Verbindliche Festlegung zu `clk_sys` vs. `clk_axi`:** In V1 sind beide
dasselbe Netz — `assign clk_sys = i_clk` und `.clk_axi (s_axi_aclk)` aus derselben
PS-FCLK0-Quelle [CODE rtl/tetra_zynq_top.v:190, 207, 24-30], und
`build/reports/impl_timing.rpt` weist **keinen eigenen AXI-Takt** aus: `clk_axi` und `clk_sys`
erscheinen dort beide als `clk_fpga_0`
[BUILD 2026-07-12, build/reports/impl_timing.rpt:152-154, :164-166]. Die weiteren Takte des
Designs — `clk_fpga_1` (200 MHz) und `rx_clk` (250 MHz) — sind in `01 §3.9` mit ihren
WNS-Werten gelistet; sie berühren diese Grenze nicht. V2 behandelt `clk_axi` und `clk_sys`
trotzdem als **getrennte Domänen** und baut die drei CDC-Punkte oben aus. Grund:
FCLK0 und AXI-Takt sind eine Board-/Blockdesign-Entscheidung, keine
RTL-Eigenschaft; eine Änderung dort darf nicht stillschweigend zu einer
metastabilitätsanfälligen Kette führen. Der Preis sind wenige 2-FF-Stufen.

### 2.3 Schnittstelle nach außen

| Signal | Breite | Richtung | Domäne | Bedeutung |
|---|---|---|---|---|
| `rx_i_lvds`, `rx_q_lvds` | 16 signed | in | `_lvds` | ADC-Sample, vom AD9361-IP von 12 auf 16 bit vorzeichenerweitert |
| `rx_valid_lvds` | 1 | in | `_lvds` | 1 Takt pro IQ-Paar, 4,608 MHz |
| `fe_i_sys`, `fe_q_sys`, `fe_valid_sys` | 16 signed, 1 | out | `_sys` | Post-RRC-IQ, 72 kHz — Quelle für DL-Demod, UL-Kette (Kap. 03) und IQ-Capture |
| `block1_sys`, `block2_sys` | 216 | out | `_sys` | Blockfelder eines Bursts, MSB = zuerst empfangen |
| `bb_sys` | 30 | out | `_sys` | Broadcast-Feld (AACH-Träger), MSB = zuerst empfangen |
| `burst_valid_sys` | 1 | out | `_sys` | 1 Takt: Burst vollständig |
| `burst_kind_sys` | 2 | out | `_sys` | 0 = NCDB/NTS1, 1 = NCDB/NTS2, 2 = SCDB/STS |
| `sync_locked_sys`, `sync_found_sys` | 1 | out | `_sys` | Korrelator-Status |
| `burst_sym_sys` | 8 | out | `_sys` | Symbolindex 0…254 im laufenden Burst |

Alle Diagnose- und Zählerausgänge sind in §3.10 zusammengefasst.

---

## 3. Detail-Spezifikation

### 3.1 CDC-FIFO (Teil von `tetra_rx_frontend`)

**Zweck:** LVDS-Domäne von der Verarbeitungsdomäne entkoppeln.

**Verhalten:** I und Q werden zu einem 32-bit-Wort gepackt: `din[31:16] = I`,
`din[15:0] = Q` [CODE rtl/rx/tetra_rx_frontend.v:214]. Schreiben bei
`rx_valid_lvds`. Lesen: `rd_en = ~empty & ~rd_rst_busy`, also so schnell wie
Daten verfügbar sind [CODE rtl/rx/tetra_rx_frontend.v:221]. Bei
`FIFO_READ_LATENCY = 1` wird `rd_en` um einen Takt verzögert und ergibt
`in_valid_sys` synchron zum stabilen `dout`
[CODE rtl/rx/tetra_rx_frontend.v:279-305].

**Dimensionierung:** Mittlere Füllung ≈ 0 (Schreibrate 4,608 MHz, Leserate bis
100 MHz). Tiefe 16 deckt Jitter beider Domänen ab; sie liegt in LUTRAM, nicht
in BRAM [CODE rtl/rx/tetra_rx_frontend.v:224].

**Randfälle — V2-Pflicht:**
- `full` ist in V1 nicht ausgewertet [CODE rtl/rx/tetra_rx_frontend.v:244]. V2
  führt einen sättigenden 16-bit-Overflow-Zähler `fe_ovf_cnt_sys`, lesbar über
  Register. Überlauf bedeutet Sampleverlust und damit einen Sprung der
  Symbolphase — er muss sichtbar sein, nicht stillschweigend passieren (R-02-12).
- Reset: `wr_rst_busy` / `rd_rst_busy` müssen abgewartet werden, bevor
  Zähler und Integratoren freigegeben werden.

### 3.2 CIC-Dezimator

**Struktur:** N = 5 Integratoren bei Eingangsrate, Dezimationszähler R = 64,
danach N = 5 Comb-Stufen bei Ausgangsrate, differentielle Verzögerung M = 1
[CODE rtl/rx/tetra_rx_frontend.v:73-76, 324-498].

**Wortbreiten:**

| Größe | Wert | Herleitung / Beleg |
|---|---|---|
| `CIC_BITS` | 46 | `IQ_WIDTH + N·⌈log2(R·M)⌉ = 16 + 5·6` [CODE rtl/rx/tetra_rx_frontend.v:118] |
| DC-Verstärkung | `R^N = 2^30` | struktureller Wert des CIC |
| `CIC_TRUNC` | 30 | Normierungs-Shift [CODE rtl/rx/tetra_rx_frontend.v:122] |
| `CIC_GAIN_SHF` (**Syntheseparameter**, kein Register) | **4** (= ×16) | [CODE rtl/rx/tetra_rx_frontend.v:135], empirisch, siehe §4 |
| Ausgangs-Slice | `comb5[45:26]`, 20 bit | `CIC_OUT_LOW = 30 − 4 = 26`, `CIC_WIDE_BITS = 20` [CODE rtl/rx/tetra_rx_frontend.v:138-139] |
| Sättigung | auf 16 bit, ±32767 / −32768 | Guard-Bits `[18:15]` müssen Bit `[19]` entsprechen [CODE rtl/rx/tetra_rx_frontend.v:520-533] |

> **Drift-Hinweis:** Die Kommentare in V1 nennen an dieser Stelle 22 bit und
> Slice `[45:24]` [CODE rtl/rx/tetra_rx_frontend.v:138-139, 502, 508]. Das war
> für `CIC_GAIN_SHF = 6` korrekt und ist mit dem heutigen Wert 4 falsch. V2
> berechnet alle Slice-Grenzen aus dem Parameter und schreibt keine absoluten
> Bitindizes in Kommentare.

**Verstärkungs-Bypass:** In V1 schaltet `loopback_en_sys` auf den unverstärkten
Slice `[45:30]` um, weil das digitale Loopback-Signal bereits Vollausschlag hat
[CODE rtl/rx/tetra_rx_frontend.v:513-537]. V2 behält diesen Ein-Bit-Pfad — seine
Steuerung ist das schon vorhandene `REG_CTRL.LOOPBACK_EN` (`07 §3.1.1`,
`01 §3.6`), kein zweiter Schalter.

**Die Verstärkung selbst ist ein Syntheseparameter, kein Laufzeitwert
(verbindlich).** `CIC_GAIN_SHF` (Wertebereich 0…6, 0 = unity) legt über
`CIC_OUT_LOW = CIC_TRUNC − CIC_GAIN_SHF` und
`CIC_WIDE_BITS = IQ_WIDTH + CIC_GAIN_SHF` die **Wortbreiten** des Ausgangs-Slice
und die Lage der Guard-Bits der Sättigungslogik fest
[CODE rtl/rx/tetra_rx_frontend.v:138-139, 520-533]. Ein zur Laufzeit
veränderlicher Wert würde die Breite des Datenpfads verändern; er ist deshalb
**kein** Registerwert. Daraus folgt: es gibt für diese Größe **kein** Register in
`07`, kein Konfigurationsschlüssel in `cell.conf` (`13 §3.7`) und keine Wirkung
über `SIGHUP` — eine Änderung des Arbeitspunkts ist ein Neubau des Bitstreams
(`15_BUILD_DEPLOY`). Alle Slice-Grenzen werden aus dem Parameter berechnet, keine
absoluten Bitindizes im Code oder im Kommentar.

**Frequenzantwort (nachgerechnet, [ANNAHME]):** |H(f)| = (sin(πfRM/f_s) /
(R·sin(πf/f_s)))^5. Daraus: −0,50 dB bei 6 kHz, −1,12 dB bei 9 kHz,
−2,05 dB an der Nutzbandkante ±12,15 kHz (= (1+α)/2T), und ≥ 71 dB Dämpfung im
ersten Aliasband um 59,85 kHz. Aliasing ist damit unkritisch, die Passband-Droop
von 2 dB dagegen messbar.

**V2-Festlegung:** Die Droop wird in die RRC-Koeffizienten hineingerechnet
(`H_RRC_neu(f) = H_RRC(f)/H_CIC(f)` über ±13,5 kHz, danach erneut
energienormiert) — kein Gatter mehr, nur andere Konstanten. Abnahme: §6, Punkt 5.

**Timing — kritisch:** Die fünf Comb-Stufen sind in V1 rein kombinatorisch
verkettet und werden erst am Ausgang registriert
[CODE rtl/rx/tetra_rx_frontend.v:420-554]. Der Pfad
`i_comb4_z1_sys_reg[0] → i_cic_out_sys_reg[14]` ist im Realbuild der
**viertschlechteste** Pfad des gesamten Designs (nach +0,006 ns
`u_ul_sch_hu/vit_soft1 → u_viterbi/pm_flat`, +0,008 ns und +0,010 ns jeweils
`u_dl_signal_queue → u_burst_dispatcher/build_block1|2`, alle Path Group
`clk_fpga_0` / Setup [MESS 2026-07-12,
build/reports/impl_timing.rpt:207, 284, 353]): Slack **+0,015 ns**, Datenpfad
9,857 ns (Logik 4,222 ns / Route 5,635 ns) bei 10 ns Periode, 20 Logikebenen
davon 12 CARRY4 [BUILD 2026-07-12, build/reports/impl_timing.rpt:424-433].
Design-WNS derselben
Implementierung: **+0,006 ns** [MESS 2026-07-12,
build/reports/impl_timing.rpt:139]. Die Rangzahl ist nicht der Punkt: 0,015 ns
Reserve auf 9,857 ns Datenpfad liegt in derselben Größenordnung wie das WNS —
der Pfad schließt zufällig, nicht mit Marge.

> **V2-Pflicht:** Die Comb-Kette wird in **je eine Pipelinestufe pro Comb**
> aufgeteilt (5 Register statt 1). Bei 72 kHz Ausgangsrate stehen ~1388
> `clk_sys`-Takte pro Sample zur Verfügung; die zusätzliche Latenz ist
> irrelevant, der Timing-Gewinn ist der Unterschied zwischen „closed by luck"
> und Reserve. Ebenso wird die Sättigungslogik in eine eigene Stufe gelegt.
> Dokumentierte Stufenzahl: CIC = 1 (Integratoren, kombinatorisch fortgeschaltet)
> + 5 (Combs) + 1 (Sättigung/Ausgang) = 7 Stufen.

**Randfälle:** Integratoren laufen absichtlich über (Zweierkomplement-Wraparound
ist beim CIC korrekt, solange `CIC_BITS` ≥ Eingangsbreite + N·log2(R·M)). Sie
dürfen deshalb **nicht** sättigen. Nur der Ausgangs-Slice sättigt.

### 3.3 RRC-Matched-Filter

**Parameter:** 33 Taps, symmetrisch, α = 0,35 [ETSI §5.5 Gl. 5.4], 4 Samples pro
Symbol, Koeffizienten Q14 signed, energienormiert
[CODE rtl/rx/tetra_rx_frontend.v:164-196].

**Koeffizienten (Q14, h[0]…h[32]):**

```
    17    109     78    -78   -209   -121    210    535    468   -181
 -1108  -1545   -694   1696   4979   7844   8978   7844   4979   1696
  -694  -1545  -1108   -181    468    535    210   -121   -209    -78
    78    109     17
```

**Verifikation:** Nachgerechnet mit der Prototyp-Formel des Referenzdecoders
[CODE scripts/decode_dl.py:249-265] für `ntaps=33, alpha=0.35, sps=4`, Energie-
normierung `h /= sqrt(Σh²)`, Skalierung ×2^14: **maximale Abweichung 2 LSB**
(reine Rundung). Σh = 32 978 → Gleichanteilsverstärkung 2,013 nach `>>14`
([ANNAHME], nachgerechnet aus [CODE rtl/rx/tetra_rx_frontend.v:164-196]).

> **Hinweis zum Referenzgenerator:** `rrc_filter()` in
> [CODE scripts/decode_dl.py:250] verwendet `np.arange(-ntaps // 2, ntaps // 2 + 1)`.
> Wegen Python-Floor-Division ergibt das für ungerade `ntaps` **34** statt 33
> Taps. Der V2-Generator schreibt `-(ntaps//2)`; sonst ist der Vergleich um
> einen Tap verschoben.

**Implementierung:** Sequentielle MAC, ein Multiplizierer, 33 Takte pro
Ausgangssample; Schieberegister als flacher 528-bit-Bus (33 × 16 bit)
[CODE rtl/rx/tetra_rx_frontend.v:150, 585-600]. FSM `S_IDLE`/`S_MAC`, Start bei
`cic_valid_sys`, Ende bei `mac_cnt == 32`
[CODE rtl/rx/tetra_rx_frontend.v:609-634]. Akkumulator 38 bit, Ausgang
`acc >>> 14` mit Sättigung auf 16 bit
[CODE rtl/rx/tetra_rx_frontend.v:147, 749-766].

33 ≪ 1388 verfügbare Takte je Sample → keine Rückstauung.

**Tap-Zuordnung — in V1 unklar, in V2 verbindlich:** `tap_k =
shift[k·16 +: 16]`, `k = mac_cnt` [CODE rtl/rx/tetra_rx_frontend.v:689-690].
Da neu eingeschobene Samples an `[15:0]` landen, ist `tap_0` das **neueste**
Sample. Der Kommentarblock darüber behauptet an einer Stelle „tap 0 = oldest",
zwei Zeilen später „tap 0 = newest"
[CODE rtl/rx/tetra_rx_frontend.v:571-585]. Weil h symmetrisch ist, ist das
Ergebnis identisch — deshalb blieb der Widerspruch stehen. **V2 legt fest:**
`tap_0` = neuestes Sample, `h[0]` gehört zu `tap_0`, und der Testvektor enthält
einen **asymmetrischen** Koeffizientensatz, damit ein Vertauschen auffällt.

**Latenz:** FIFO 2 + CIC 2 (V1) / 7 (V2 nach Pipelining) + MAC 33 + Ausgang 1
Takte. **Zählweise (verbindlich, gleich wie §3.2):** Die Integratorenstufe wird
mitgezählt; V1 = 1 (Integratoren) + 0 (Comb-Kette rein kombinatorisch,
`*_z1`-Register sind Verzögerungsglieder, keine Pipelinestufen)
+ 1 (Sättigung/Ausgang, [CODE rtl/rx/tetra_rx_frontend.v:324-391, 540-554])
= 2; V2 = 1 + 5 + 1 = 7. Gruppenlaufzeit des Filters: (33−1)/2 = 16 Ausgangssamples = 222,2 µs
= 4 Symbole [ANNAHME, nachgerechnet].

**Ressourcen (V1-Header-Schätzung, [CODE rtl/rx/tetra_rx_frontend.v:56-60]):**
~120 LUT, ~280 FF, 1 DSP48, 0 BRAM. Der reale Anteil ist nicht separat
ausgewiesen; `tetra_rx_chain` als Ganzes (inklusive vollständiger UL-Kette)
liegt bei 8451 LUT / 11219 FF / 4 RAMB18 / 20 DSP
[BUILD 2026-05-18, build/reports/impl_hier_util.rpt:87].

### 3.4 Symbol-Timing-Rückgewinnung (`tetra_dl_timing_recovery`)

**Zweck:** Aus 4 Samples/Symbol das On-Time-Sample auswählen.

**Schnittstelle:**

| Port | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `clk_sys`, `rst_n_sys` | 1 | in | 100 MHz, Reset active-low |
| `i_in_sys`, `q_in_sys` | 16 signed | in | Post-RRC-IQ |
| `valid_in_sys` | 1 | in | 1 Takt je Sample, 72 kHz |
| `i_out_sys`, `q_out_sys` | 16 signed | out | On-Time-Sample |
| `valid_out_sys` | 1 | out | 1 Takt je Symbol, 18 kHz |
| `locked_sys` | 1 | out | Timing-Lock |
| `ted_sys` | 16 signed | out | skalierter TED-Wert (Diagnose) |

**Gardner-TED** [CODE rtl/rx/tetra_timing_recovery.v:166-192]:

```
e = i_s1 · (i_in − i_s3) + q_s1 · (q_in − q_s3)
```

mit `i_in = S[n]` (aktuell), `i_s1 = S[n−2]` (Mittelpunkt), `i_s3 = S[n−4]`
(vorheriges On-Time-Sample). Differenzen 17 bit, Produkte 33 bit, Summe 34 bit,
Skalierung `>>> 18` auf 16 bit
[CODE rtl/rx/tetra_timing_recovery.v:112-115, 192].

**NCO:** 32 bit, Nominalschritt `0x4000_0000` = 2^30; vier Schritte ergeben
exakt 2^32 → Überlauf alle 4 Eingangssamples
[CODE rtl/rx/tetra_timing_recovery.v:108, 153-154].

**PI-Filter** [CODE rtl/rx/tetra_timing_recovery.v:80-81, 204-217]:

```
kp_term  = TED >>> KP_SHIFT        KP_SHIFT = 4   (Kp = 1/16)
integ   += TED >>> KI_SHIFT        KI_SHIFT = 8   (Ki = 1/256)
step     = 0x4000_0000 + kp_term + integ
```

Vorzeichen: positives `e` → größerer Schritt → früherer Überlauf.

**Lock:** `|TED| < LOCK_THRESH = 256` für `LOCK_COUNT = 144` aufeinander
folgende Symbole; sofortiges Deassert bei einem großen Fehler
[CODE rtl/rx/tetra_timing_recovery.v:82-83, 370-397]. Der Zähler ist 8 bit und
sättigt bei 255.

**Strukturelle Grenze:** Es gibt keinen Interpolator. Das Modul latcht bei
NCO-Überlauf das gerade anliegende Sample
[CODE rtl/rx/tetra_timing_recovery.v:333-349]. Die Zeitauflösung ist damit ein
Eingangssample = 1/4 Symbol; der stationäre Timing-Restfehler beträgt bis zu
±1/8 Symbol ([ANNAHME], nachgerechnet). Bei α = 0,35 kostet das SNR.

> **V2-Festlegung:** Zwischen Schieberegister und Ausgang kommt ein
> **Farrow-Interpolator 2. Ordnung** (3 Taps, Bruchteil µ = `nco_acc[29:22]`,
> 8 bit), gebaut als Parameter `TR_INTERP_EN`. Kosten: 2 DSP48, ~60 FF.
> Entscheidung und Abnahme: §6, Punkt 4.

**Randfälle:**
- Startphase: Der NCO läuft nach Reset ab 0; die erste Überlaufposition ist
  willkürlich. Der Lock-Vorgang muss ohne externe Hilfe konvergieren (R-02-04).
- Bei `valid_in_sys = 0` friert der NCO ein (`if (valid_in)`); die Schleife läuft
  bei Signalausfall nicht weg.
- `locked_sys` und `ted_sys` waren in V1 an OPEN verdrahtet
  [CODE rtl/rx/tetra_rx_chain.v:335-336] — der Timing-Lock war also nie
  beobachtbar. In V2 gehen beide in das Statusregister (§3.10). Ein
  Loop-Zustand, den niemand lesen kann, ist nicht diagnostizierbar.

**Ressourcen (Header-Schätzung, [CODE rtl/rx/tetra_timing_recovery.v:56-60]):**
~120 LUT, ~200 FF, 2 DSP48.

### 3.5 π/4-DQPSK-Demodulator (`tetra_dl_pi4dqpsk_demod`)

**Zweck:** Absolutphase pro Symbol über CORDIC-Vectoring, daraus Differenzphase
und Dibit.

**Zahlenformat:** Phase in Q1.15 mit Vollausschlag = π. Also
+π/2 ≙ 16384, +π/4 ≙ 8192, +3π/4 ≙ 24576
[CODE rtl/rx/tetra_pi4dqpsk_demod.v:80-89]. Der Wertebereich
[−32768, +32767] entspricht [−π, +π); die Subtraktion zweier Phasen wrappt
modular und liefert damit automatisch die korrekte Differenzphase.

**CORDIC:** Vectoring-Modus, 16 Iterationen, interne Breite 18 bit (2 Guard-Bits
für den CORDIC-Gain ≈ 1,647) [CODE rtl/rx/tetra_pi4dqpsk_demod.v:71].

Quadrantenvorkorrektur, damit x > 0 gilt
[CODE rtl/rx/tetra_pi4dqpsk_demod.v:171-178]:

| Eingang | (x, y, z)-Init |
|---|---|
| I ≥ 0 | (I, Q, 0) |
| I < 0, Q ≥ 0 | (Q, −I, +16384) |
| I < 0, Q < 0 | (−Q, I, −16384) |

Iteration [CODE rtl/rx/tetra_pi4dqpsk_demod.v:190-214]: `d = ~y[MSB]`;
`x ± (y >>> i)`, `y ∓ (x >>> i)`, `z ± atan_i`.

**ATAN-Tabelle** (Q1.15, `round(atan(2^-i)·32768/π)`)
[CODE rtl/rx/tetra_pi4dqpsk_demod.v:114-133]:

```
i:    0     1     2     3    4    5    6   7   8   9  10  11  12  13  14  15
   8192  4836  2556  1297  651  326  163  81  41  20  10   5   3   1   1   0
```

**Dibit-Entscheidung** — [ETSI Tabelle 5.1] verlangt:

| Bits (B(2k−1), B(2k)) | Dibit | Dφ |
|---|---|---|
| 0,0 | `00` | +π/4 |
| 0,1 | `01` | +3π/4 |
| 1,0 | `10` | −π/4 |
| 1,1 | `11` | −3π/4 |

Dabei ist `dibit[1] = B(2k−1)` das **zuerst gesendete** Bit.

Umsetzung [CODE rtl/rx/tetra_pi4dqpsk_demod.v:238-249]:

| Δφ (Q1.15) | Dibit |
|---|---|
| `[+16384, +32767]` | `01` |
| `[0, +16383]` | `00` |
| `[−16384, −1]` | `10` |
| `[−32768, −16385]` | `11` |

> **Randwert-Festlegung (V2):** Δφ = 0 → `00`, Δφ = +16384 → `01`,
> Δφ = −16384 → `10`. Das RTL macht es so; der Python-Referenzdecoder ordnet
> Δφ = 0 dagegen `10` zu [CODE scripts/decode_dl.py:168-169]. Für Realsignale
> irrelevant, für bit-exakte Testvektoren nicht. V2 nimmt die RTL-Konvention und
> passt den Referenzdecoder an.

**Phasenfehler:** `phase_err = Δφ − ideal(dibit)`
[CODE rtl/rx/tetra_pi4dqpsk_demod.v:275]. Ein Konstant-Offset in `phase_err`
zeigt einen Trägerfrequenz-Offset an, die Streuung die Phasengüte.

**FSM und Latenz** [CODE rtl/rx/tetra_pi4dqpsk_demod.v:283-291]:
`S_IDLE → S_INIT (1) → S_ITER (16) → S_DECIDE (1) → S_IDLE`, also 18
`clk_sys`-Takte pro Symbol bei ~5556 verfügbaren Takten. Das erste Symbol nach
Reset erzeugt kein `dibit_valid`, weil noch keine Referenzphase existiert
(`phase_locked`) [CODE rtl/rx/tetra_pi4dqpsk_demod.v:395-425].

**Nicht genutzt in V1:** Der CORDIC hält am Ende in `x` die Vektormagnitude; V1
verwirft sie. V2 sieht `mag_sys[15:0]` und daraus — analog zur UL-Kette —
amplituden-normierte Soft-Werte `soft0 = sat(cos(Δφ)·k)`,
`soft1 = sat(sin(Δφ)·k)` vor. Entscheidung: §6, Punkt 3.

**Ressourcen (Header-Schätzung, [CODE rtl/rx/tetra_pi4dqpsk_demod.v:37-38]):**
~300 LUT, ~150 FF, 0 DSP.

### 3.6 Trainingssequenzen

Alle Muster normativ, in Sendereihenfolge (Bit 1 zuerst); Dibits als
`(B(2k−1), B(2k))`-Paare, wie der Korrelator sie sieht.

```
NTS1  n1..n22 = 1,1 0,1 0,0 0,0 1,1 1,0 1,0 0,1 1,1 0,1 0,0        [ETSI §9.4.4.3.2 Gl. 9.4]
      Dibits  =  11  01  00  00  11  10  10  01  11  01  00        (11 Symbole)

NTS2  p1..p22 = 0,1 1,1 1,0 1,0 0,1 0,0 0,0 1,1 0,1 1,1 1,0        [ETSI §9.4.4.3.2 Gl. 9.5]
      Dibits  =  01  11  10  10  01  00  00  11  01  11  10        (11 Symbole)

NTS3  q1..q22 = 1,0 1,1 0,1 1,1 0,0 0,0 0,1 1,0 1,0 1,1 0,1        [ETSI §9.4.4.3.2 Gl. 9.6]
      Dibits  =  10  11  01  11  00  00  01  10  10  11  01        (11 Symbole)

ETS   x1..x30 = 1,0 0,1 1,1 0,1 0,0 0,0 1,1 1,0 1,0 0,1 1,1 0,1 0,0 0,0 1,1
      Dibits  =  10  01  11  01  00  00  11  10  10  01  11  01  00  00  11
                                                    (15 Symbole, [ETSI §9.4.4.3.3 Gl. 9.9])

STS   y1..y38 = 1,1 0,0 0,0 0,1 1,0 0,1 1,1 0,0 1,1 1,0 1,0 0,1 1,1 0,0 0,0 0,1 1,0 0,1 1,1
      Dibits  =  11  00  00  01  10  01  11  00  11  10  10  01  11  00  00  01  10  01  11
                                                    (19 Symbole, [ETSI §9.4.4.3.4 Gl. 9.11])

Tail  t1..t4  = 1,1,0,0                                            [ETSI §9.4.4.3.5 Gl. 9.12]
```

| Sequenz | Verwendung | V1-Abgleich |
|---|---|---|
| NTS1 | NDB mit **einem** logischen Kanal auf Block 1+2 (TCH, SCH/F) [ETSI Tabelle 9.13] | `NTS_REF` [CODE rtl/rx/tetra_sync_detect.v:114-117] und `NTS1_REF` [CODE rtl/tx/tetra_burst_builder.v:115-118] — bit-identisch |
| NTS2 | NDB mit **zwei** logischen Kanälen (STCH+TCH, STCH+STCH, SCH/HD+SCH/HD, SCH/HD+BNCH) [ETSI Tabelle 9.13]. Die Sequenzwahl **ist** die Kanalanzeige. | `NTS2_REF` [CODE rtl/tx/tetra_burst_builder.v:124-127] korrekt (Kommentar zitiert falsch §9.4.4.3.3). **Im Korrelator fehlt NTS2 ganz** — `seq_select` kennt nur NTS1/ETS/STS [CODE rtl/rx/tetra_sync_detect.v:90, 267-274] |
| NTS3 | über zwei DL-Bursts verteilt: `q11..q22` = Symbole 0–5, `q1..q10` = Symbole 250–254 [ETSI Tabellen 9.7, 9.9]. Kein Sync-Anker (kurz, an der Burstkante), aber Plausibilitätsprüfung: Symbole 0–5 müssen `0,1,2,2,3,1` sein. | im RX nicht vorhanden |
| ETS | **Uplink**-Control-Burst — gehört zu Kapitel 03, hier nur zur Abgrenzung | `ETS_REF` [CODE rtl/rx/tetra_sync_detect.v:125-130] bit-identisch |
| STS | Synchronisations-DL-Burst (SCDB/SDDB) | `STS_REF` [CODE rtl/rx/tetra_sync_detect.v:135-139] bit-identisch |
| Tail | nur UL- und diskontinuierliche Bursts | — |

**Wichtig für den Korrelator:** Die **Phase-Adjustment-Bits** (`ha`, `hb`, `hc`,
`hd`, …) sind datenabhängig [ETSI §9.4.4.3.6] und dürfen niemals Teil eines
Korrelationsfensters sein. In den Bursts liegen sie unmittelbar vor bzw. nach den
`q`-Feldern — deshalb sind die `q`-Felder nur als Zusatzprüfung, nicht als
Sync-Anker verwendbar.

### 3.7 Sync-Korrelator (`tetra_dl_sync_detect`)

**Schnittstelle:**

| Port | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `clk_sys`, `rst_n_sys` | 1 | in | |
| `dibit_in` | 2 | in | Symbol vom Demod |
| `dibit_valid` | 1 | in | 1 Takt je Symbol, 18 kHz |
| `corr_thresh_nts` | 5 | in | Schwelle für NTS1/NTS2 (0…11) |
| `corr_thresh_sts` | 5 | in | Schwelle für STS (0…19) |
| `seq_enable` | 3 | in | Bitmaske: [0] NTS1, [1] NTS2, [2] STS |
| `sync_found` | 1 | out | 1 Takt bei Treffer (registriert) |
| `sync_kind` | 2 | out | 0 = NTS1, 1 = NTS2, 2 = STS |
| `sync_locked` | 1 | out | Lock erreicht |
| `burst_sym` | 8 | out | Symbolindex 0…254 im Burst |
| `corr_peak` | 5 | out | Spitzenwert seit letztem Clear |
| `clear_peak` | 1 | in | Peak zurücksetzen |

**Algorithmus:** Flaches Schieberegister, neuestes Dibit an `[1:0]`, ältestes am
oberen Ende [CODE rtl/rx/tetra_sync_detect.v:146-154]. Für die Korrelation wird
die **kombinatorische Vorschau** `sreg_shifted = {sreg[73:0], dibit_in}`
verwendet, damit der Treffer auf demselben `dibit_valid` fällt, der das Fenster
schließt, und nicht ein Symbol später
[CODE rtl/rx/tetra_sync_detect.v:166]. Pro Sequenz: XOR gegen die Referenz,
`~|xor[2k+1:2k]` je Symbol, Addierbaum über die Symbol-Treffer
[CODE rtl/rx/tetra_sync_detect.v:169-263]. Es ist ein **Hard-Dibit-Zähler**,
keine Amplitudenkorrelation.

**Bit-Order der Referenzkonstanten:** MSB = erstes gesendetes Symbol = ältestes
im Fenster; damit ist `sreg_shifted[2N−1:0]` direkt gegen `REF` vergleichbar
[CODE rtl/rx/tetra_sync_detect.v:103-113].

**Fenstergröße:** V1 nutzt `reg [75:0] sreg_sample` = 76 bit = 38 Symbole
[CODE rtl/rx/tetra_sync_detect.v:146] — das **Doppelte** der STS-Länge, denn die
STS ist 38 **bit** = 19 Symbole (`localparam [37:0] STS_REF`
[CODE rtl/rx/tetra_sync_detect.v:135], [ETSI §9.4.4.3.4 Gl. 9.11]). Korreliert
wird ohnehin nur `sreg_shifted[37:0]` [CODE rtl/rx/tetra_sync_detect.v:205]; die
oberen 38 bit sind unbenutzt. **V2:** Fenster = längste aktivierte Sequenz, also
38 bit für STS bzw. 22 bit für NTS — jede Überlänge muss begründet dastehen,
sonst wird sie gestrichen. (Diese Stelle war in der V1-Doku selbst die Quelle
einer bit/Symbol-Verwechslung, siehe §3.8.)

**Trigger:** `sync_fire = (corr ≥ thresh) & ~holdoff & dibit_valid`
[CODE rtl/rx/tetra_sync_detect.v:288]. `sync_found` ist die um einen Takt
registrierte Version; **alle** internen Steuerregister benutzen `sync_fire`,
nicht `sync_found` — sonst entsteht ein Ein-Takt-Versatz
[CODE rtl/rx/tetra_sync_detect.v:31-35, 306-311].

**Holdoff:** Nach jedem Treffer werden `HOLDOFF = 220` Symbole gesperrt
[CODE rtl/rx/tetra_sync_detect.v:77, 291-298]. Zweck: Nebenmaxima innerhalb
desselben Bursts unterdrücken. 220 < 255 → die nächste echte
Sequenz-Position ist nicht blockiert.

**Lock-FSM** [CODE rtl/rx/tetra_sync_detect.v:354-451]:

```
S_HUNT  --sync_fire-->                     S_ACQR
S_ACQR  --consec ≥ LOCK_COUNT(4)-->        S_LOCK
S_ACQR  --spacing_cnt > LOCK_TIMEOUT-->    S_HUNT
S_LOCK  --spacing_cnt > LOCK_TIMEOUT-->    S_HUNT
```

Abstandsprüfung: akzeptiert werden 1020, 2040 und 3060 Symbole ± `LOCK_TOL = 30`
[CODE rtl/rx/tetra_sync_detect.v:366-372]. 1020 = 4 × 255 = ein TDMA-Frame; die
Vielfachen tolerieren **zwei verpasste** Detektionen.
`LOCK_TIMEOUT = 3060` Symbole = 3 Frames = 170 ms
[CODE rtl/rx/tetra_sync_detect.v:81].

> **Wichtig — was bei zu strengen Werten passiert.** Diese vier Werte sind für
> ein reales HF-Signal getunt, nicht aus der Theorie:
> - `LOCK_TOL` zu klein (z. B. 4 statt 30): Jitter der Timing-Recovery
>   verschiebt den Treffer um ±1…2 Symbole; die Abstandsprüfung schlägt fehl,
>   `consec` wird zurückgesetzt, **Lock kommt nie zustande**.
> - `LOCK_TIMEOUT` zu klein (z. B. 1100): eine einzige verpasste Detektion
>   wirft die FSM nach `S_HUNT`; bei jedem Fading-Dip fällt der Lock.
> - Nur `sp1` akzeptieren (ohne 2040/3060): jede verpasste Detektion setzt den
>   Lock-Aufbau zurück.
> - Schwelle zu hoch: der Korrelator verpasst echte Sequenzen. Auf der UL-Seite
>   ist derselbe Effekt hart gemessen — NUB-Schwelle 11 arbeitet, 12 ist blind
>   (0 erkannte Bursts) [MESS 2026-05-17, NUB-Sync-Schwelle 11 gegen 10 und 12 über 10-s-Sprechtasten-Läufe; Wert im Repo CODE board_autostart/tetra_cell.conf:21, CODE sw/tetra_attach_daemon.c:1044].
> - Schwelle zu niedrig: Rauschtreffer. Ebenfalls UL-gemessen: Schwelle 8 → ~48
>   Falschtreffer/s im Leerlauf, 9 → ~9/s, 10 und 11 → 0/s
>   [MESS 2026-05-16, Fehlalarmrate im Leerlauf gegen NUB-Sync-Schwelle 8/9/10/11, gezählt über `nub_rx_cnt`].

**Schwellenwert-Dimensionierung, [GOLD]:** Auf der Referenzaufzeichnung einer
kommerziellen Zelle liegt die normierte Differenzkorrelation aller 7338
dekodierten DL-Bursts bei ≥ 0,988 (STS-Bursts: min 0,988, Median 0,993, n=5171;
NTS-Bursts: min 0,991, Median 0,997, n=1969+198)
[GOLD docs/reference_decode/dl_events.jsonl]. Ein sauberes Signal liefert also
praktisch volle Symbolübereinstimmung; die Schwelle wird nicht vom Nutzsignal
bestimmt, sondern von der zulässigen Falschalarmrate.

**V2-Festlegung — getrennte Schwellen:** V1 speist den DL-Korrelator und den
UL-RA-OS4-Korrelator (`u_ul_sync_detect`, ETS-Muster) aus demselben Register
(`corr_threshold_sys`, Default 13) [CODE rtl/tetra_zynq_top.v:567,
rtl/infra/tetra_axi_lite_regs.v:1418, rtl/rx/tetra_rx_chain.v:375]. Der
NUB-OS4-Korrelator (`u_ul_sync_nub`, NTS1-Muster) hat dagegen bereits eine
**eigene** Schwelle `voice_nub_sync_thresh_sys`
[CODE rtl/rx/tetra_rx_chain.v:105, 446] — und die ist empirisch scharf: 11
arbeitet, 12 ist blind (§4). Diese Trennung darf V2 **nicht** zurückbauen. Da NTS
nur 11 Symbole hat, ist ein Wert > 11 für NTS strukturell unerreichbar, während
STS 19 Symbole hat — eine gemeinsame Schwelle kann für beide nicht richtig sein.
V2 führt je Sequenzklasse eine eigene Schwelle (`corr_thresh_nts`,
`corr_thresh_sts`) und für die UL-Kette nochmals eigene, getrennt für RA und NUB
(Kapitel 03).

**Weitere V2-Korrekturen:**
- V1 aktiviert genau **eine** Sequenz zur Laufzeit (`seq_select`, im Top fest auf
  2 = STS verdrahtet) [CODE rtl/tetra_zynq_top.v:568]. Damit werden NDB-Bursts
  gar nicht erkannt. V2 lässt **alle** aktivierten Sequenzen parallel laufen
  (`seq_enable`-Maske) und gibt über `sync_kind` aus, welche getroffen hat. Die
  drei Addierbäume existieren in V1 bereits parallel — nur der Mux verwirft
  zwei Ergebnisse [CODE rtl/rx/tetra_sync_detect.v:265-274].
- `SEQ_LEN_MAX` ist ein deklarierter, nirgends benutzter Parameter
  [CODE rtl/rx/tetra_sync_detect.v:76]; im Top wird er mit 38 überschrieben
  [CODE rtl/rx/tetra_rx_chain.v:344]. Ersatzlos entfallen.
- `CORR_WIDTH` wird im Top auf 24 gesetzt [CODE rtl/rx/tetra_rx_chain.v:343],
  obwohl der Korrelationswert nie über 19 geht. Der Vergleich
  `corr_sel(6 bit) >= corr_threshold(24 bit)` funktioniert nur, weil die obersten
  18 Bit stets 0 sind. V2: 5 bit, exakt.
- `corr_peak` ist in V1 nur per Reset löschbar
  [CODE rtl/rx/tetra_sync_detect.v:457-462]. V2 bekommt `clear_peak`.
- `slot_number` inkrementiert in V1 nicht, wenn der Treffer bei
  `slot_position == 254` fällt [CODE rtl/rx/tetra_sync_detect.v:334-340]; genau
  deshalb führt `tetra_burst_demux` einen zweiten, eigenen Slotzähler
  [CODE rtl/rx/tetra_burst_demux.v:28-31, 158-165]. In V2 zählt **nur** der
  Frame-Counter Slots; der Korrelator gibt keine Slotnummer aus.

**Ressourcen (Header-Schätzung, [CODE rtl/rx/tetra_sync_detect.v:56]):**
~380 LUT, ~130 FF. Drei parallele Addierbäume dominieren.

### 3.8 Burst-Demultiplexer (`tetra_dl_burst_demux`)

**Burstgeometrie — normativ.** Symbolindex 0-basiert, `sym = ⌊(BN−1)/2⌋`.

*Normal continuous downlink burst* [ETSI Tabelle 9.7]:

| Feld | BN | bit | Symbole | Anz. |
|---|---|---|---|---|
| Normal TS 3 `q11..q22` | 1–12 | 12 | 0–5 | 6 |
| Phase-Adjust `ha1..ha2` | 13–14 | 2 | 6 | 1 |
| Block 1 `bkn1(1..216)` | 15–230 | 216 | 7–114 | 108 |
| Broadcast `bb(1..14)` | 231–244 | 14 | 115–121 | 7 |
| Normal TS `n`/`p` | 245–266 | 22 | 122–132 | 11 |
| Broadcast `bb(15..30)` | 267–282 | 16 | 133–140 | 8 |
| Block 2 `bkn2(1..216)` | 283–498 | 216 | 141–248 | 108 |
| Phase-Adjust `hb1..hb2` | 499–500 | 2 | 249 | 1 |
| Normal TS 3 `q1..q10` | 501–510 | 10 | 250–254 | 5 |

*Synchronization continuous downlink burst* [ETSI Tabelle 9.9]:

| Feld | BN | bit | Symbole | Anz. |
|---|---|---|---|---|
| Normal TS 3 `q11..q22` | 1–12 | 12 | 0–5 | 6 |
| Phase-Adjust `hc1..hc2` | 13–14 | 2 | 6 | 1 |
| Frequenzkorrektur `f1..f80` | 15–94 | 80 | 7–46 | 40 |
| Sync-Block `sb(1..120)` | 95–214 | 120 | 47–106 | 60 |
| Sync-TS `y1..y38` | 215–252 | 38 | 107–125 | 19 |
| Broadcast `bb(1..30)` | 253–282 | 30 | 126–140 | 15 |
| Block 2 `bkn2(1..216)` | 283–498 | 216 | 141–248 | 108 |
| Phase-Adjust `hd1..hd2` | 499–500 | 2 | 249 | 1 |
| Normal TS 3 `q1..q10` | 501–510 | 10 | 250–254 | 5 |

Die diskontinuierlichen Varianten (492 bit = 246 Symbole + Guard,
[ETSI Tabellen 9.10 und 9.12]) sind für V2 spezifiziert, aber nicht in Stufe 1
gebaut (→ `18_ROADMAP.md`); der Feldextraktor muss dafür nur eine zweite
Offset-Tabelle bekommen.

**Frequenzkorrekturfeld:** `f1..f8 = 1`, `f9..f72 = 0`, `f73..f80 = 1`
[ETSI §9.4.4.3.1 Gl. 9.1–9.3] — als Dibits `3,3,3,3` + 32 × `0` + `3,3,3,3`.

> **[GOLD]-Bestätigung der Geometrie.** Im Referenz-Decode ist Burst #0 ein SB;
> der ausgegebene Dibit-Strom (254 Dibits, Index = Symbolindex − 1, weil die
> Differenzdemodulation ein Symbol als Referenz verbraucht) beginnt mit
> `1,2,2,3,1` — das ist genau das Ende von `q11..q22` — gefolgt von einem
> Phase-Adjust-Dibit und dann `3,3,3,3`, 32 × `0`, `3,3,3,3`
> [GOLD docs/reference_decode/dl_full.md, Burst #0, Feld „SB dibits (254)"].
> Damit sind die Offsets FC = Symbol 7…46 und `sb(1)` = Symbol 47 aus
> Tabelle 9.9 an echten Luftdaten verifiziert, nicht nur aus der Norm gelesen.

**Positionsbezug — V2-Verfahren.** Der Korrelator meldet den Treffer auf dem
Symbol, das die Trainingssequenz **abschließt**. Aus der Sequenzart folgt der
absolute Symbolindex dieses Moments direkt aus der Tabelle:

| `sync_kind` | letztes TS-Symbol | `burst_sym` beim Treffer |
|---|---|---|
| STS (SCDB) | 125 | 125 |
| NTS1/NTS2 (NCDB) | 132 | 132 |

Der Demux lädt bei `sync_found` den Zähler `burst_sym` mit diesem Wert und
inkrementiert danach modulo 255. **Alle** Feldfenster werden anschließend als
absolute Symbolintervalle aus der ETSI-Tabelle geprüft. Damit gibt es keine
abgeleiteten Magic-Numbers mehr.

**Warum das nicht kosmetisch ist.** V1 arbeitet mit `slot_position`, das bei
jedem Treffer auf 0 gesetzt wird, und mit vier hartkodierten Fenstern
[CODE rtl/rx/tetra_burst_demux.v:80-86]: BB = 0…14, Block2 = 15…122,
Emit = 123, Block1 = 125…232. Der zugehörige Kommentarblock beschreibt eine
Burststruktur mit „Training Seq (22 symbols)" und „FreqCorr (2 symbols)"
[CODE rtl/rx/tetra_burst_demux.v:8-13] — dort sind 22 **bit** als 22 **Symbole**
gelesen worden. Konsequenz, gegen die ETSI-Tabellen gerechnet:

- Mit STS-Trigger sind BB (Symbole 126–140) und Block 2 (141–248) **richtig** —
  sie fallen exakt auf Tabelle 9.9.
- Das Block-1-Fenster (`slot_position` 125…232 ≙ Symbole 251…358, also
  Folgeburst-Symbole −4…103) liegt **11 Symbole zu früh**; `bkn1` des
  Folgebursts läge bei Symbol 7…114. `block1_data` enthält also verschobene
  Daten.
- Der Fehler ist in V1 nie aufgefallen, weil `block1_out_sys`, `block2_out_sys`,
  `bb_out_sys` und `slot_valid_sys` im Top-Level nur deklariert und angeschlossen,
  aber **von keinem Verbraucher gelesen** werden
  [CODE rtl/tetra_zynq_top.v:361-364, 570-573]. Der Synthesizer entfernt sie.

Das ist der Musterfall, den V2 verhindern soll: ein selbst erfundenes Feldraster
statt der Normtabelle, plus ein Ausgang ohne Verbraucher, der niemanden warnt.

**Bit-Order:** Schieberegister nach links, neues Dibit an `[1:0]`
[CODE rtl/rx/tetra_burst_demux.v:171-199]. Nach vollständiger Aufnahme gilt
`block[215:214]` = erstes empfangenes Dibit, `bb[29:28]` = `bb(1),bb(2)`. Das
erfüllt R-02-07 und bleibt so.

**Ausgabezeitpunkt:** V2 gibt `burst_valid_sys` einen Takt nach dem letzten
Symbol des Bursts (Symbol 254) aus, mit allen drei Feldern desselben Bursts.
V1 emittiert bei `slot_position == 123` und braucht deshalb einen Latch-Umweg
über zwei Sync-Ereignisse (`block1_lat`, `block1_ready`
[CODE rtl/rx/tetra_burst_demux.v:220-251]), weil sein Block-1-Fenster zum
Folgeburst gehört. Mit dem absoluten Symbolzähler entfällt diese Konstruktion
komplett — Block 1 (Symbole 7–114) und Block 2 (141–248) liegen im **selben**
Burst.

**Randfälle:**
- `sync_locked = 0`: keine Aufnahme, kein `burst_valid`.
- Sync-Verlust mitten im Burst: laufender Burst wird verworfen, kein
  Teilergebnis ausgegeben.
- Fehlt eine Detektion (Fading), läuft `burst_sym` frei weiter (Modulo 255) und
  die Feldfenster bleiben gültig, solange die Timing-Recovery hält. Ein
  Zählerfehler wird beim nächsten Treffer korrigiert, weil `burst_sym` neu
  geladen wird. V2 zählt Ladevorgänge mit Abweichung > `LOCK_TOL` in
  `burst_sym_slip_cnt` — das ist die eigentliche Messgröße für Grid-Stabilität.

**Ressourcen (Header-Schätzung, [CODE rtl/rx/tetra_burst_demux.v:35]):**
~120 LUT, ~580 FF (drei Schieberegister à 216/216/30 bit dominieren).

### 3.9 TDMA-Zähler (`tetra_dl_frame_counter`)

**Hierarchie** [ETSI §4.5.2, §9.3.1, Figure 9.1]:

| Ebene | Bereich | Dauer |
|---|---|---|
| Zeitschlitz | TS1…TS4 (ETSI) = `tn` 0…3 (RTL) | 85/6 ms ≈ 14,167 ms, 255 Symbole |
| Frame | 1…18 | 170/3 ms ≈ 56,67 ms |
| Multiframe | 1…60 | 1,02 s; Frame 18 ist normativ Control Frame [ETSI §4.5.2] |
| Hyperframe | frei laufend, 16 bit | 61,2 s |

**Schnittstelle:** `slot_pulse` (= `burst_valid_sys`), `sync_locked` →
`tn[1:0]`, `frame_num[4:0]`, `multiframe_num[5:0]`, `hyperframe_num[15:0]`,
`is_control_frame`, `frame18_ts2` [CODE rtl/rx/tetra_frame_counter.v:51-70].

**Semantik (V1, in V2 zu präzisieren):** `tn` enthält beim Eintreffen von
`slot_pulse` den **Wert vor** der Aktualisierung, identifiziert also den gerade
abgeschlossenen Zeitschlitz [CODE rtl/rx/tetra_frame_counter.v:16-21]. Diese
Pre-Update-Konvention ist eine häufige Fehlerquelle. **V2 legt fest:** Es gibt
zwei Ausgänge — `tn_done` (gerade abgeschlossen) und `tn_next` (als nächstes
erwartet) — und beide sind so benannt.

**Reset:** `!rst_n_sys` **oder** `!sync_locked` setzt alles auf TS-Index 0,
Frame 1, Multiframe 1, Hyperframe 0
[CODE rtl/rx/tetra_frame_counter.v:95-152]. Der Zähler hat also keinen
Freilauf ohne Sync — das ist die Wurzel der Kopplung in Abschnitt 6, Punkt 2.

**Zeitschlitz-Benennung:** Im RTL 0-basiert (`tn` 0…3), in Spec-Text, SW, Logs
und WebUI 1-basiert (TS1…TS4). Umrechnung: `TS2 (ETSI) = tn=1 (RTL)`. Sie
erfolgt ausschließlich im zentralen Mapping-Modul (→ `13_SW_ARCHITECTURE.md`).
V1 nennt seinen Puls `frame_18_slot1` und meint `timeslot_num == 1`
[CODE rtl/rx/tetra_frame_counter.v:170-181], also ETSI-TS2 — der Name suggeriert
TS1. V2 nennt ihn `frame18_ts2`.

**Ressourcen:** ~25 LUT, ~36 FF [CODE rtl/rx/tetra_frame_counter.v:42].

### 3.10 Roh-IQ-Capture und Diagnose

**`tetra_rx_iq_capture`** — der einzige gültige Messpunkt zur Bewertung des
**eigenen** Empfängers. Externe Aufzeichnungen (RTL-SDR o. ä.) messen einen
anderen Empfänger und sagen über diese Kette nichts aus
[MESS 2026-05-30, Roh-IQ-Mitschnitt aus der eigenen Empfangskette; Werkzeug im Repo CODE scripts/capture_rx_iq.sh].

| Eigenschaft | Wert | Beleg |
|---|---|---|
| Abgriff | `fe_i_sys`/`fe_q_sys`, post-RRC, 72 kSa/s | [CODE rtl/tetra_zynq_top.v:663-675] |
| Tiefe | 8192 Samples à 32 bit `{I[31:16], Q[15:0]}` | [CODE rtl/rx/tetra_rx_iq_capture.v:29, 83] |
| Ressourcen | 256 kbit ≈ 8 × BRAM36 | [CODE rtl/rx/tetra_rx_iq_capture.v:21-22] |
| Betrieb | freilaufender Ringpuffer; `freeze` stoppt, dann `wr_ptr` lesen und über `rd_addr`/`rd_data` drainen | [CODE rtl/rx/tetra_rx_iq_capture.v:64-104] |
| CDC | `freeze` axi→sys 2-FF; `wr_ptr` sys→axi 2-FF, nur im Freeze-Zustand gültig | [CODE rtl/rx/tetra_rx_iq_capture.v:51-60, 94-104] |
| Reset | **synchron** (BRAM-benachbart, Vivado REQP-1839) | [CODE rtl/rx/tetra_rx_iq_capture.v:52, 68] |

Der Mehrbit-`wr_ptr` überquert die Domänengrenze ohne Gray-Code. Das ist
zulässig, weil er nach `freeze` statisch ist — und **nur** so wird er benutzt.
V2 behält das Verfahren, dokumentiert die Bedingung aber im Register-Vertrag
(→ `07`).

**IQ-Pegelmonitor.** V1 verfolgt max |I| und max |Q| über ein
Gleitfenster von 7200 Samples (= 100 ms bei 72 kSa/s) und latcht das Ergebnis
[CODE rtl/rx/tetra_rx_chain.v:271-300]. **Fehler:** der Absolutwert wird nur aus
`fe_i_sys[12:0]` gebildet [CODE rtl/rx/tetra_rx_chain.v:276-277], das Vorzeichen
kommt aus Bit 15. Werte über 8191 aliasen dadurch auf kleine Zahlen — genau im
Bereich, in dem man Übersteuerung erkennen will. Der Kommentar spricht
außerdem von „12-bit (0..2047)", das Register ist 13 bit
[CODE rtl/rx/tetra_rx_chain.v:114-116, 271-274].
**V2:** volle 16-bit-Betragsbildung, 16-bit-Peak, plus einen separaten
Sättigungszähler pro Stufe (R-02-12).

**Diagnose-Ausgänge, die V2 verbindlich führt** (Adressen → `07`):

| Größe | Breite | Zweck |
|---|---|---|
| `fe_sample_cnt` | 32 | Sollwert 72 000/s — prüft die gesamte Vorstufe in einem Zähler |
| `fe_ovf_cnt` | 16 | FIFO-Überlauf (V1: nicht vorhanden) |
| `cic_sat_cnt`, `rrc_sat_cnt` | je 16 | Sättigungsereignisse (V1: nicht vorhanden) |
| `dibit_cnt` | 32 | Sollwert 18 000/s |
| `sync_found_cnt` | 24 | Trefferrate — Falschalarme sichtbar |
| `corr_peak` | 5 | Spitzenkorrelation, per `clear_peak` rücksetzbar |
| `sync_lost_cnt` | 16 | Lock-Verluste |
| `timing_locked`, `ted` | 1 + 16 | Timing-Loop-Zustand (V1: an OPEN) |
| `phase_err` | 16 signed | Trägerfrequenz-/Phasengüte |
| `burst_sym_slip_cnt` | 16 | Grid-Stabilität |
| `rx_peak_i`, `rx_peak_q` | je 16 | Pegel über 100 ms |

V1 hat davon `fe_cnt`, `demod_cnt` und ein gepacktes Wort
`{corr_peak[7:0], sync_cnt[23:0]}` [CODE rtl/tetra_zynq_top.v:4248-4275];
`sync_locked` liegt in `REG_STATUS` Bit 0
[CODE sw/tetra_hal.h:33, 58]. Alles andere fehlt.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Wirkung bei Abweichung |
|---|---|---|---|
| `CIC_GAIN_SHF` | **4** (= ×16) | [MESS 2026-05-22, Air-Messreihe `CIC_GAIN_SHF` 6/5/4/3 gegen UL-Prüffeld-Rate]; [CODE rtl/rx/tetra_rx_frontend.v:135] | Air-Messreihe: `6` (×64) → UL-CRC 16,3 %; `5` → 5,9 %; **`4` → 25,5 % bei Schwelle 13, mit Schwelle 15 dann 92,6 % und 94,1 % in zwei Läufen**; `3` (×8) verworfen (Sync bricht ein: 34 Syncs, 0 CRC). Ursache: ×64 drückt Bursts bei AGC-Transienten in die Sättigung, der differentielle Demod sieht dann verfälschte Magnituden. |
| DL-Korrelationsschwelle | 13 | [CODE rtl/infra/tetra_axi_lite_regs.v:1418] | Für STS (19 Symbole) locker, für NTS (11 Symbole) grenzwertig hoch. In V1 dieselbe Zahl für DL und UL — V2 trennt (§3.7). |
| UL-NUB-Schwelle (Analogie für Schwellen-Tuning) | 11 von 11 | [MESS 2026-05-17, NUB-Sync-Schwellen-Survey 10/11/12 über 10-s-Sprechtasten-Läufe; Wert im Repo CODE board_autostart/tetra_cell.conf:21] | 10 → BFI 6,1 % (viele wacklige Locks); **11 → BFI 4,7 %**; 12 → Detektor blind, 0 Bursts. Zeigt die Breite des brauchbaren Fensters: **ein** Zählschritt. |
| Falschalarmrate vs. Schwelle | 8 → ~48/s, 9 → ~9/s, 10 → 0/s, 11 → 0/s (Leerlauf) | [MESS 2026-05-16, Fehlalarmzählung im Leerlauf über `nub_rx_cnt`] | Unterhalb der Kante flutet der Decoder mit Rauschtreffern. |
| `HOLDOFF` | 220 Symbole | [CODE rtl/rx/tetra_sync_detect.v:77] | Zu klein → Mehrfachtreffer je Burst; ≥ 255 → echte Folgesequenz blockiert. |
| `LOCK_COUNT` (Sync) | 4 | [CODE rtl/rx/tetra_sync_detect.v:78] | Kleiner → Lock auf Zufallstreffer; größer → Lock-Aufbau > 4 Frames. |
| `LOCK_TOL` | ±30 Symbole | [CODE rtl/rx/tetra_sync_detect.v:80] | „wider for RF path jitter" — enger und der Lock kommt am realen Signal nicht zustande. |
| `LOCK_TIMEOUT` | 3060 Symbole (3 Frames, 170 ms) | [CODE rtl/rx/tetra_sync_detect.v:81] | Übersteht 2 verpasste Detektionen; kleiner → Lock fällt bei jedem Fading-Dip. Muss < 4095 bleiben (12-bit-Zähler). |
| `LOCK_THRESH` (Timing) | 256 (TED-Einheiten ≈ Q14) | [CODE rtl/rx/tetra_timing_recovery.v:82] | Nur Statusanzeige — hat in V1 keinen Regelungseinfluss, weil `timing_locked` unverdrahtet ist. |
| `LOCK_COUNT` (Timing) | 144 Symbole | [CODE rtl/rx/tetra_timing_recovery.v:83] | 8-bit-Zähler, sättigt bei 255. |
| `KP_SHIFT` / `KI_SHIFT` | 4 / 8 | [CODE rtl/rx/tetra_timing_recovery.v:80-81] | Schleifenbandbreite. Kp zu groß → Jitter, der über `LOCK_TOL` hinaus wandert; Ki zu groß → Loop läuft weg. Nur zusammen mit `CIC_GAIN_SHF` gültig, weil die TED-Verstärkung ∝ Amplitude² geht. |
| Gold-Korrelation, saubere Zelle | ≥ 0,988 (n = 7338) | [GOLD docs/reference_decode/dl_events.jsonl] | Referenzwert für „Signal in Ordnung". Deutlich niedriger ⇒ Problem in der eigenen Kette, nicht am Sender. |
| WNS Gesamtdesign | +0,006 ns | [BUILD 2026-07-12, build/reports/impl_timing.rpt:139] | Kein Spielraum. |
| Viertschlechtester Pfad (nach +0,006 / +0,008 / +0,010 ns) | +0,015 ns, in `u_rx_frontend` CIC-Comb → Ausgangsregister, 9,857 ns Datenpfad | [BUILD 2026-07-12, build/reports/impl_timing.rpt:424-433]; Ränge 1–3 ebd. :207, 284, 353 | Begründet die Pipelining-Pflicht in §3.2: 0,015 ns Reserve auf 9,857 ns Datenpfad ist WNS-Größenordnung. |
| Auslastung Gesamtdesign | LUT 37 567 (70,6 %), FF 50 744 (47,7 %) | [BUILD 2026-07-12, build/reports/impl_utilization.rpt] | Maßgeblich sind LUT/FF/BRAM/DSP/WNS, nicht Slice-Prozent. |

---

## 5. Verifikation

**V-02-1 — Frontend gegen Fixpunkt-Referenzmodell.** Ein Generator erzeugt
Stimulus und Erwartungswerte mit **Integer**-Arithmetik, die dem RTL exakt
entspricht: 5 Integratoren pro Eingangssample, Dezimation als `y5[R-1::R]`
(nicht `y5[::R]` — sonst 63 Samples Versatz), 5 Comb-Stufen,
`>> CIC_TRUNC`, Slice, Sättigung, dann RRC-MAC mit `>> 14` und Sättigung. Das
Muster existiert in V1 [CODE tb/vectors/gen_rx_frontend_vectors.py:1-40] und wird
übernommen. Testfälle: Reset, DC, Einzelton innerhalb ±12,15 kHz,
π/4-DQPSK-Sequenz mit TX-RRC, Dezimationsverhältnis. Kriterium: bit-exakt.

**V-02-2 — RRC-Koeffizienten.** Vergleich der Q14-Konstanten gegen den
Prototypen (α = 0,35, 33 Taps, sps = 4, energienormiert). Kriterium: ≤ 2 LSB
Abweichung (R-02-02). Zusätzlich ein Lauf mit absichtlich **asymmetrischen**
Koeffizienten, der die Tap-Reihenfolge nachweist (§3.3).

**V-02-3 — Demodulator, alle vier Symbole.** IQ-Vektoren, die alle vier
Übergänge und die Randwinkel abdecken; Prüfung von `dibit_out`,
`dibit_valid`-Timing (18 Takte) und der Unterdrückung des ersten Symbols. V1-TB
deckt das ab [CODE tb/tb_tetra_pi4dqpsk_demod.v:1-22] und wird um die in §3.5
festgelegten Randwerte erweitert.

**V-02-4 — Timing-Recovery gegen Python-Referenz.** TC0 perfektes Timing
(TED ≈ 0), TC1 +1 Sample (TED > 0, Schritt steigt), TC2 −1 Sample; dazu
Strobe-Verhältnis genau 1:4 und Reset mitten im Strom
[CODE tb/tb_tetra_timing_recovery.v:1-27]. Neu für V2: Konvergenzzeit aus jeder
der 4 Startphasen (R-02-04) und A/B des Farrow-Interpolators.

**V-02-5 — Korrelator.** Einzelburst in Rauschen, STS-Fall, vier
aufeinanderfolgende Bursts (Lock), reines Rauschen bei hoher Schwelle (keine
Treffer), Burst mit 3 verfälschten TS-Symbolen (Treffer bei niedriger Schwelle),
Reset mitten im Betrieb [CODE tb/tb_tetra_sync_detect.v:1-24]. Neu: NTS2-Pfad;
gleichzeitige Aktivierung mehrerer Sequenzen mit korrektem `sync_kind`;
Falschalarm-Messreihe über die Schwelle 8…19 auf 10^6 Rauschsymbolen — sie
ersetzt das Raten eines Defaults.

**V-02-6 — Burst-Demux gegen ETSI-Tabellen.** Synthetischer Burst, in dem jedes
Feld ein eigenes Bitmuster trägt. Kriterium: `block1`, `block2`, `bb` enthalten
genau die Symbole aus den Tabellen in §3.8, MSB = zuerst empfangen. Dieser Test
hätte den Block-1-Versatz von V1 gefunden; der V1-TB hat ihn nicht gefunden,
weil er dasselbe falsche Feldraster als Sollwert benutzt
[CODE tb/tb_tetra_burst_demux.v:6-17]. **Regel: die Sollwerte kommen aus der
Normtabelle, nicht aus dem Prüfling.**

**V-02-7 — Frame-Counter.** TS-, Frame-, Multiframe-, Hyperframe-Wrap;
`is_control_frame` nur in Frame 18; `frame18_ts2` genau auf ETSI-TS2;
Counter-Reset bei Sync-Verlust; sauberer Neuaufbau
[CODE tb/tb_tetra_frame_counter.v:1-17].

**V-02-8 — Kette gegen Python-Referenzdecoder auf echten Luftdaten.** Ein
IQ-Capture (§3.10) wird (a) durch die RTL-Simulation und (b) durch
`scripts/decode_dl.py` geschickt. Kriterium: identischer Dibit-Strom über
mindestens 4 aufeinanderfolgende Bursts, gleiche Sync-Positionen. Das Verfahren
existiert: `wav_to_dibits.py` erzeugt aus einer Aufzeichnung eine
`$readmemh`-Datei für die Simulation [CODE scripts/wav_to_dibits.py:1-13].

**V-02-9 — Gold-Vergleich.** Aus der Referenzaufzeichnung wird ein SB-Burst
gezogen und gegen die **Dibit-Liste** geprüft (254 Einträge; Listenindex =
Symbolindex − 1, weil Symbol 0 als Differenzreferenz verbraucht wird und im Strom
nicht auftaucht — §3.8): Listenindizes 0…4 sind `1,2,2,3,1` (= Symbole 1…5, Ende
von `q11..q22`), Index 5 ist das Phase-Adjust-Dibit (Symbol 6), Listenindizes
6…45 tragen das Frequenzkorrekturmuster `3,3,3,3` + 32 × `0` + `3,3,3,3`
(= Symbole 7…46), `sb(1)` beginnt bei Listenindex 46 (= Symbol 47)
[GOLD docs/reference_decode/dl_full.md:23, Burst #0, Feld „SB dibits (254)";
gleiche Werte in docs/reference_decode/dl_events.jsonl, idx 0, Feld `sb_dibits`].
Ein Testkriterium, das Symbol 0 in der Liste erwartet, schlägt auf korrekten
Daten fehl. Zell- und MS-spezifische
Felder (MCC/MNC/CC, SSI, Carrier, Scrambler) dürfen und müssen abweichen — nur
die Struktur wird bit-verglichen.

**V-02-10 — Air-Kriterien.** (a) `fe_sample_cnt` = 72 000 ± 1 pro Sekunde;
(b) `dibit_cnt` = 18 000 ± 1 pro Sekunde; (c) `fe_ovf_cnt` = 0 über 60 s;
(d) `cic_sat_cnt` / `rrc_sat_cnt` = 0 im AGC-Normalbetrieb;
(e) `rx_peak_i/q` in einem Fenster, das weder < 10 % noch > 90 % des
Vollausschlags berührt; (f) bei aktiver DL-Quelle `sync_locked` = 1 und
`burst_sym_slip_cnt` = 0 über 60 s. Jeder Air-Test läuft mindestens **dreimal**
— ein einzelner Lauf ist bei dieser Kette statistisch nicht belastbar
(die Pack-B-Messreihe in §4 zeigt, wie stark einzelne Läufe streuen).

**Nicht als Verifikationsmethode zugelassen:** In-Circuit-Debug-Cores. Nachweis
läuft über Simulation, AXI-Zähler, Logs und IQ-Captures.

---

## 6. Offene Punkte

**O-02-1 — Braucht V2 überhaupt eine DL-Empfangskette?**
Fakten: Die Zelle ist Basisstation. Der RX-LO steht auf der Uplink-Frequenz
(428,25 MHz, TX 438,25 MHz) [CODE board_autostart/tetra_cell.conf:6-7], die
Nutzbandbreite des AD9361-Filters auf 200 kHz
[CODE board_autostart/tetra_cell.conf:9]. Die DL-Kette hat also
nominell kein Eingangssignal. Ihre Blockdaten-Ausgänge sind im V1-Top ohne
Verbraucher (§3.8). Genutzt werden `frame_num` (→ Punkt 2), `timeslot_num`
(gray-kodiert für die AXI-Leseseite [CODE rtl/tetra_zynq_top.v:1409-1410],
vgl. Punkt 6), `sync_locked`, `sync_found` und `corr_peak[7:0]` als
Statusanzeige [CODE rtl/tetra_zynq_top.v:1369, 4205-4208, 4267-4275].
Tatsächlich verbraucherlos — nur deklariert und angeschlossen, sonst nirgends
referenziert — sind `block1_out`, `block2_out`, `bb_out`, `slot_valid`
[CODE rtl/tetra_zynq_top.v:361-364, 570-573], `slot_num_out`, `burst_type_out`
[CODE rtl/tetra_zynq_top.v:365-366, 574-575], `multiframe_num`, `hyperframe_num`,
`is_control_frame`, `frame_18_slot1` [CODE rtl/tetra_zynq_top.v:370-373, 578-581]
sowie `slot_position` und `phase_error`
[CODE rtl/tetra_zynq_top.v:377-378, 584-585].
**Empfehlung:** DL-RX als **build-zeit-optionaler Diagnoseblock**
(`RX_DL_ENABLE`, Default 0 für den Produktionsbuild) spezifizieren und bauen
(R-02-09). Nutzen bleibt real: Selbsttest über internen TX-Monitor-Pfad, der in
V1 nur **sporadisch** ansprang (`TX_MONITOR1_2` erzeugte sporadisch
`SYNC_LOCKED=1` [MESS 2026-04-12, docs/HARDWARE.md:244]). Ein sporadischer Lock
ist kein Abnahmekriterium: Soll der Selbsttest V2-Abnahmeweg werden, gilt
**3 Läufe à 30 s mit `sync_locked` = 1 durchgehend und
`burst_sym_slip_cnt` = 0**; wird das nicht erreicht, ist der TX-Monitor-Pfad kein
Nachweis und die Abnahme läuft ausschließlich über V-02-8 auf einem IQ-Capture.
Dazu Zweitnutzung derselben Bausteine als
Referenzimplementierung für die Verifikation. Wird der Block gebaut, muss er
korrekt sein — halb richtige Blöcke haben in V1 elf Symbole Versatz überlebt.

**O-02-2 — Frame-Tick-Kopplung DL-RX → UL-Reassembly (der Architekturpunkt).**
Fakten: `frame_tick_sys` wird aus Wertwechseln von `frame_num_sys` gebildet
[CODE rtl/tetra_zynq_top.v:687-696] und speist die T0-Timeout-Timer von
`tetra_ul_demand_reassembly` [CODE rtl/tetra_zynq_top.v:752] und
`tetra_ul_schf_reassembly` [CODE rtl/tetra_zynq_top.v:837]. `frame_num_sys`
kommt aus `tetra_frame_counter`, der nur zählt, solange `sync_locked` gesetzt ist
[CODE rtl/rx/tetra_frame_counter.v:98-119] — und `sync_locked` kommt aus dem
DL-Korrelator. Damit hängt ein **operativer** Timer der UL-Protokollkette am
Lock-Zustand einer Empfangskette, die auf einer anderen Frequenz hört.
Offen und **nicht** aus dem Repo belegbar: ob und wie zuverlässig dieser Lock im
Feld tatsächlich zustande kommt. Es gibt im Repo keine Messung von
`sync_locked` im Betrieb. Ohne Lock steht `frame_tick` still, T0 läuft nie ab,
Reassembly-Einträge verfallen nie — ein Verhalten, das im Air-Test unauffällig
bleibt, bis zwei Fragmente derselben ISSI kollidieren.
**Empfehlung (V2, verbindlich):** `frame_tick` wird ausschließlich aus der
TX-TDMA-Zeitbasis erzeugt (→ `04`, `08`); sie läuft unabhängig und ist die
einzige Zeitquelle des Systems (R-02-08). Die DL-Kette bekommt **keinen**
Ausgang, der eine Zeitbasis darstellen könnte. Zusätzlich: jeder Timer, der aus
einem Empfangs-Lock gespeist wird, ist ein Fehler — diese Regel gehört in
`17_LESSONS_LEARNED.md`.

**O-02-3 — Soft-Decisions im DL-Pfad.** Der CORDIC berechnet die Magnitude bereits;
V1 verwirft sie. Auf der UL-Seite hat die amplituden-normierte Soft-Ausgabe den
Decoder-Cliff beseitigt [MESS 2026-05-30]. **Empfehlung:** Schnittstelle
(`soft0`, `soft1`, `mag`) spezifizieren und die Stufe nur bauen, wenn Punkt 1
zugunsten eines echten DL-Decoders entschieden wird.

**O-02-4 — Timing-Interpolator.** Ohne Interpolator ist der Restfehler ±1/8 Symbol
(§3.4). **Empfehlung:** Farrow-Stufe als Parameter bauen und auf einem
IQ-Capture gegen den direkten Pfad messen. Nicht ungemessen einbauen — und nicht
ungemessen weglassen.

**O-02-5 — CIC-Droop-Kompensation.** −2,05 dB an der Bandkante (§3.2), unkompensiert.
**Empfehlung:** in die RRC-Koeffizienten einrechnen; Kosten null, Nachweis über
V-02-8 auf demselben Capture.

**O-02-6 — Mehrbit-CDC nach `clk_axi`.** V1 gray-kodiert `frame_num[4:0]` vor dem
2-FF-Synchronizer [CODE rtl/tetra_zynq_top.v:1376-1398]. Gray garantiert
Ein-Bit-Wechsel nur für **fortlaufende** Zähler. `frame_num` springt von 18 auf
1; `gray(18) = 11011`, `gray(1) = 00001` unterscheiden sich in drei Bit. An
dieser Kante kann die AXI-Seite einmal pro Multiframe einen Fantasiewert lesen.
Für `tn` (0…3, Modulo 4) ist die Kodierung korrekt.
**Empfehlung:** Mehrbit-Zählerstände über ein Snapshot-Register mit
Toggle-Handshake übertragen (Wert wird sys-seitig eingefroren, dann übernommen),
nicht über Gray-Code. Gilt für alle Zähler in `07`.

**O-02-7 — Zwei Slotzähler.** V1 hat einen im Korrelator und einen im Demux, weil der
erste eine Zähllücke hat (§3.7). **Empfehlung:** genau ein Zähler, im
Frame-Counter; Korrelator und Demux liefern nur Symbolpositionen.

**O-02-8 — Nicht-kontinuierliche Burstformate.** Tabellen 9.10 und 9.12 sind
spezifiziert, in Stufe 1 nicht gebaut. **Empfehlung:** die Offset-Tabelle des
Demux als Parametersatz ausführen, damit das Nachziehen keine Logikänderung
erfordert. Nach `18_ROADMAP.md` verweisen.

**O-02-9 — Referenzdecoder-Konsistenz.** Zwei Abweichungen in
`scripts/decode_dl.py`, das in §5 Prüfmaßstab ist: die RRC-Tap-Anzahl
(off-by-one, §3.3) und die Offsets des nicht-kontinuierlichen SB-Layouts
(`NSB_OFF_SB1 = 25`, `NSB_OFF_STS = 85` [CODE scripts/decode_dl.py:102-105]
gegen Tabelle 9.12, die `sb(1)` bei Symbol 42 und die STS bei Symbol 102
verlangt). Beim kontinuierlichen Layout — dem der Gold-Zelle — stimmt der
Decoder. **Empfehlung:** Der V2-Referenzdecoder leitet **beide** Layouts aus
**einer** Feldtabelle ab, die exakt §3.8 entspricht, und diese Tabelle ist
zwischen RTL, Python-Decoder und Testbench dieselbe Quelle.

**O-02-10 — Deklarierte, unbenutzte Parameter und Ports.** `SEQ_LEN_MAX`
[CODE rtl/rx/tetra_sync_detect.v:76], `TS_PER_FRAME`
[CODE rtl/rx/tetra_burst_demux.v:49], der Eingang `slot_number` des Demux
[CODE rtl/rx/tetra_burst_demux.v:62], `CORDIC_ITER`
[CODE rtl/rx/tetra_pi4dqpsk_demod.v:55]. Außerdem verwendet
`tetra_rx_frontend` das Signal `mac_next_sys` 15 Zeilen vor seiner Deklaration
[CODE rtl/rx/tetra_rx_frontend.v:611 vs. 626]. **Empfehlung:** V2 verbietet
unbenutzte Ports/Parameter und Verwendung vor Deklaration; beides wird im
Lint-Gate des Builds (→ `15`) geprüft, nicht per Review.
