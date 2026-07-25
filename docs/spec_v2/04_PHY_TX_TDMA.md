# 04 — Sende-PHY und TDMA-Zeitbasis

**Scope:** Der komplette Downlink-Sendepfad ab „codierter Block liegt vor" —
kanonische TDMA-Zeitbasis, Slot-Zeitplan-Tabelle, Slot-Inhalts-Auswahl,
Sende-Warteschlange für Signalisierung, Burst-Aufbau (255 Symbole),
π/4-DQPSK-Modulator, RRC-Sendefilter, Interpolation auf den AD9361-Takt.

**Nicht hier:** Kanalcodierung der Nutzdaten (CRC, RCPC, Interleaving,
Scrambling, RM(30,14)) → `05_CHANNEL_CODING.md`. Semantik der MAC-PDUs, LI,
Stealing, AACH-Inhalte → `06_MAC.md`. Register-Adressen und Mailbox-Protokolle
→ `07_PS_PL_CONTRACT.md`. Slot-Deadlines, Reply-Fenster, DL→UL-Air-Lock
→ `08_TIMING.md`.

**Abhängigkeiten:** `01_PLATFORM.md` (Clock-/Reset-Architektur, AD9361-Takte,
Ressourcen-Budget). Für die Block-Inhalte: `05`. Für die Registernamen: `07`.

---

## 1. Anforderungen

Zeitbasis und Nummerierung

- **R-04-01** Es existiert **genau ein** TDMA-Zähler im Design. Alle Verbraucher
  (Slot-Zeitplan-Lookup, BSCH-Encoder, AACH-Encoder, Burst-Verteiler,
  AXI-Statusregister) lesen aus dieser einen Quelle. Prüfbar: Grep über das
  synthetisierte RTL findet keinen zweiten Zähler, der `sym_en` auf
  Slot/Frame/Multiframe hochzählt.
- **R-04-02** Der Zähler führt `sym_cnt` (0..254), `tn` (0..3), `fn` (0..17),
  `mn` (0..59), `hn` (0..63), alle 0-basiert im RTL. Die Umrechnung in die
  ETSI-1-basierte Darstellung erfolgt **ausschließlich** in einem zentralen
  Mapping-Modul (R-04-04).
- **R-04-03** Der Zähler ist von Software auf einen (tn, fn, mn, hn)-Wert
  ladbar; der Ladevorgang ist symbolgrid-synchron (Commit auf der nächsten
  `sym_en`-Flanke) und setzt `sym_cnt` auf 0. Prüfbar per Testbench: Load
  während laufendem Slot → beim nächsten `sym_en` stehen die geladenen Werte
  und `sym_cnt == 0`.
- **R-04-04** Ein zentrales Mapping-Modul (`tetra_ts_map`, RTL-Header +
  SW-Header aus **einer** Quelle) liefert alle Konversionen
  RTL-0-basiert ↔ ETSI-1-basiert ↔ SYNC-PDU-Feldcodierung ↔
  `ts_assigned`-Bitmap. Ad-hoc-`±1` im übrigen Code ist verboten. Prüfbar:
  Grep nach `+ 5'd1` / `+ 6'd1` / `- 1` auf TDMA-Signalen liefert nur Treffer
  im Mapping-Modul.
- **R-04-05** Die AXI-lesbare TDMA-Statusanzeige zeigt **den luftsynchronen
  Zähler**, nicht einen zweiten freilaufenden. Prüfbar: nach `TX_TDMA_LOAD`
  ändert sich der Statuswert entsprechend.

Slot-Zeitplan

- **R-04-06** Der Slot-Zeitplan liegt in einem Dual-Port-BRAM mit 288 Einträgen
  à 16 bit, adressiert über `dense_idx = (mn mod 4)*72 + fn*4 + tn`. Der
  PS-Port schreibt/liest 144 32-bit-Worte (zwei Einträge pro Wort).
- **R-04-07** Das Eintragsformat ist verbindlich festgelegt (§3.3.2), inklusive
  einer **eindeutigen** Klassen-Enumeration. Kein numerischer Klassenwert darf
  in Generator und RTL unterschiedliche Namen tragen.
- **R-04-08** Die BSCH-Platzierung auf dem Kontrollframe erfüllt
  `FN = 18 ∧ (MN + TN) mod 4 = 3` [ETSI §9.5.2 Gl. 9.17]. Der Zeitplan-Generator
  leitet den Eintrag aus dieser Gleichung her; die Testbench prüft **gegen die
  Gleichung**, nicht gegen eine Kopie der Implementierung.
- **R-04-09** Der Zeitplan wird beim Bring-up vollständig geschrieben, bevor der
  Sender freigegeben wird. Ein Eintrag darf nicht innerhalb von 2 TDMA-Frames
  vor dem Slot geändert werden, der ihn liest.

Sende-Warteschlange

- **R-04-10** Die Signalisierungs-Warteschlange hat Tiefe 4, strikte
  Prioritätsordnung MLE (0) > CMCE (1) > SDS (2) > reserviert (3), und
  Überlauf-Strategie **drop-newest**.
- **R-04-11** Jeder Verwurf ist an einem AXI-lesbaren Zähler sichtbar:
  ein Aggregat-Zähler (≥16 bit, sättigend) **und** ein Zähler pro
  Produzenten-Port (≥16 bit, sättigend). Zusätzlich sind Füllstand
  (`depth_count`) und Belegungsmaske AXI-lesbar. Prüfbar: 5. Eintrag bei
  voller Queue → Aggregat- und Produzenten-Zähler je +1.
- **R-04-12** Der Nutzdaten-Bus der Warteschlange ist **MSB-ausgerichtet**
  (§3.11). Jeder Produzent liefert Halbblöcke im obersten Feld. Prüfbar per
  Testbench pro Produzent: nach Push liefert `head_coded[431:216]` die
  codierten Bits, nicht Nullen.

Burst-Aufbau und Modulation

- **R-04-13** Jeder Slot sendet einen Burst mit exakt 255 Symbolen
  (510 Modulationsbits), Burst-Delay d = 0, ohne Guard-Periode
  [ETSI §9.4.4.1 Tabelle 9.2]. Der Symbolstrom ist über Slot-Grenzen hinweg
  lückenlos (Continuous Downlink).
- **R-04-14** Die Bitallokation entspricht bitgenau Tabelle 9.7 (NDB) bzw.
  Tabelle 9.9 (SB) [ETSI §9.4.4.2.5 / §9.4.4.2.6]. Trainingssequenzen,
  Frequenzkorrekturfeld und Synchronisationssequenz sind aus den normativen
  Gleichungen (9.4)–(9.6), (9.1)–(9.3), (9.11) erzeugt.
- **R-04-15** Die Phasenanpassungs-Bits (`ha/hb` bzw. `hc/hd`) werden je Burst
  **aus dem Burst-Inhalt berechnet** nach [ETSI §9.4.4.3.6 Gl. 9.14 +
  Tabelle 9.15]. Ein statischer Wert ist nicht zulässig. Prüfbar: Testbench
  rechnet die Phasensumme über den in Tabelle 9.15 genannten Symbolbereich und
  erwartet 0 mod 2π nach dem Anpassungssymbol.
- **R-04-16** Die Dibit→Phasenübergang-Zuordnung des Modulators entspricht
  [ETSI §5.4 Tabelle 5.1] (vollständige Tabelle in §3.7.2). Prüfbar per
  Testvektor über alle 4 Dibits × 8 Startphasen = 32 Fälle.
- **R-04-17** Das RRC-Sendefilter hat Roll-off α = 0,35 [ETSI §5.5 Gl. 5.4] und
  interpoliert 18 000 Sym/s → 72 kHz.
- **R-04-18** Die Interpolationskette auf die AD9361-Abtastrate ist im
  Durchlassbereich ±12,15 kHz auf ≤ 0,5 dB Welligkeit kompensiert (§3.9.3).
- **R-04-19** Über- und Unterlauf der Takt-Domänen-Überquerung sind je an einem
  AXI-lesbaren sättigenden Zähler sichtbar; das Unterlauf-Verhalten ist
  spezifiziert (Halten des letzten Abtastwerts, §3.9.2).
- **R-04-20** Ein Diagnose-Modus ersetzt den Dibit-Strom durch eine PRBS
  (Spektrumsmessung ohne Protokoll). Er ist per Register abschaltbar und im
  Reset aus.
- **R-04-21** Zwischen zwei verschiedenen PDUs eines Handshakes — namentlich
  zwischen Vorantwort und Anmeldebestätigung — existiert **kein**
  Abstandsmechanismus: kein Wartezustand, kein Registerfeld, das den Abstand
  vorgibt, und kein Selbstzählen von Slot-Pulsen im Erzeuger. Der Zeitpunkt der
  Antwort entsteht allein aus dem Ereignis, das sie erzeugt („Zusammensetzung
  vollständig **oder** Fenster abgelaufen", normativ `08 §3.5.2`,
  frame-granular nach `08` R-08-11). Ein fester Abstand als Ersatz für dieses
  Ereignis ist verboten. Nicht betroffen ist `delay_slots` der DL-PDU-Mailbox
  (`07 §3.3`): es staffelt identische Wiederholungen **derselben** PDU
  (`10 §3.4.3`, Abstand normativ `08 §3.4.3` R-4) und darf für einen
  Antwortabstand nicht verwendet werden. Ausführlich mit Begründung und
  Prüfkriterien in §3.5.3.

---

## 2. Architektur / Aufbau

### 2.1 Kette und Datenraten

```
 sym_en, TX_TDMA_LOAD ─▶ tetra_tdma_timebase ─▶ sym_cnt,tn,fn,mn,hn + tdma_tick,slot_pulse
                                    │
   (mn,fn) ─▶ tetra_slot_prefetch ──┴─▶ tetra_slot_schedule (BRAM 288×16) ─▶ 4× entry[15:0]
                                                                                  │
 MLE/CMCE/SDS ─▶ tetra_dl_signal_queue (Tiefe 4, prio) ─▶ tetra_dl_signal_scheduler
                                                            4× (blk1,blk2,ndb2,active)
                                                                                  │
 SW-Payload-Bänke (NDB/MCCH/BNCH/SB) ─┐  Halteplätze 4× (07 §3.3) ─┐             │
        tetra_ul_grant (06 §3.9) ─────────┤  PERSIST_SET/CLEAR        │             │
                                          └──────────┬───────────────┴─────────────┘
                       slot_pulse ─▶ tetra_burst_dispatcher (Auswahl + 1 Latch-Stufe)
                                          │ build_req + blk1/blk2/bb/sb1 + content_sys
                       sym_en ────▶ tetra_burst_builder (510-bit SR)  ─▶ Dibit @ 18 kHz
                                    tetra_pi4dqpsk_mod (1 Zyklus)     ─▶ IQ    @ 18 kHz
                                    tetra_rrc_filter  (L=4, 36 Zykl.) ─▶ IQ    @ 72 kHz
                                    tetra_tx_frontend (CDC + CIC R=64)─▶ IQ @ 4,608 MHz
                                                                          → AD9361
```

Alle Raten sind exakt und ganzzahlig verkoppelt [CODE rtl/tetra_zynq_top.v:952-955]:

| Punkt | Rate | Herleitung |
|---|---|---|
| AD9361 DATA_CLK (`clk_lvds`) | 18,432 MHz | Plattform, siehe `01` |
| Symboltakt `sym_en` | 18 000,000 Hz | 18,432 MHz ÷ 1024 |
| RRC-Ausgang | 72 kHz | 4 × Symbolrate |
| CIC-Ausgang / DAC | 4,608 MHz | 18,432 MHz ÷ 4 = 64 × 72 kHz |
| Slotdauer | 255 × 1/18 ms = 14,1667 ms | [ETSI §9.4.3.2] |
| Frame / Multiframe / Hyperframe | 56,67 ms / 1,02 s / 61,2 s | [ETSI §9.3.1 Bild 9.1] |

### 2.2 Clock-Domains

| Domain | Suffix | Takt | Inhalt |
|---|---|---|---|
| System | `_sys` | 100 MHz | Zeitbasis, Zeitplan-Port-B, Queue, Dispatcher, Builder, Modulator, RRC, FIFO-Schreibseite |
| AXI | `_axi` | 100 MHz — **derselbe** Takt wie `_sys` (siehe V2-Festlegung unten) | Zeitplan-Port-A, Registerbank |
| LVDS | `_lvds` | 18,432 MHz | FIFO-Leseseite, CIC, DAC-Interface |

Im **Symbol- und IQ-Datenpfad** existieren genau zwei Übergänge:
`clk_lvds → clk_sys` für den Symboltakt (Toggle + 2-FF-Synchronizer +
Flankendetektor) und `clk_sys → clk_lvds` für die IQ-Abtastwerte
(asynchrones FIFO). Details in §3.10 / §3.9.

Der dritte Berührungspunkt ist der **Konfigurations-/Statuspfad**
`clk_axi ↔ clk_sys`: der Zeitplan-BRAM wird auf Port A mit `clk_axi`
geschrieben und gelesen, auf Port B mit `clk_sys` gelesen
[CODE rtl/tx/tetra_slot_schedule.v:145-158 gegen :177-190], und die
Registerbank resynchronisiert Status- und Konfigurationswörter mit
2-FF-Ketten (`ASYNC_REG`) in beide Richtungen
[CODE rtl/tetra_zynq_top.v:1619-1622, 2643-2672].

**V2-Festlegung:** `clk_axi` und `clk_sys` sind **derselbe** Takt aus derselben
PS-Quelle (`FCLK_CLK0`) und werden als **eine** Timing-Domäne constrained —
phasengleich, kein CDC. Damit ist der Zeitplan-BRAM kein Takt-Domänen-Übergang,
sondern ein reines Lese-Schreib-Race auf derselben Adresse, und die
2-FF-Ketten auf Konfigurations- und Statuswörtern entfallen als CDC-Maßnahme.
Diese Festlegung ist die Voraussetzung dafür, dass R-04-09 überhaupt prüfbar
ist: „Eintrag nicht innerhalb von 2 TDMA-Frames vor dem lesenden Slot ändern"
ist eine Aussage im Slot-Zeitraster und gilt nur, wenn Schreib- und Leseseite
dieselbe Zeitbasis haben.

V1 ist hier zweideutig und darum nicht als Vorbild verwendbar: physisch sind
beide Takte dieselbe Quelle [CODE rtl/tetra_zynq_top.v:26, 190, 207 —
`clk_sys = i_clk`, `clk_axi = s_axi_aclk`, „same source as i_clk"], das
Top-Level schreibt „no CDC for single-source clock" [CODE …:566], der
Reset-Generator behandelt `clk_axi` dagegen „as independent domain for safety"
[CODE rtl/infra/tetra_clk_reset.v:18-19]. Beides gleichzeitig ergibt weder
saubere Constraints noch eine belastbare Aussage über den BRAM-Port.

---

## 3. Detail-Spezifikation

### 3.1 `tetra_tdma_timebase` — kanonische Zeitbasis

**Zweck:** Der eine TDMA-Zähler des Designs. Liefert das (tn, fn, mn, hn)-Tupel
des Slots, der gerade gesendet wird, sowie die Slot-Grenzstrobes.

**Schnittstelle**

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `clk_sys` | 1 | in | — | 100 MHz |
| `rst_n_sys` | 1 | in | `_sys` | active-low, synchron deassertiert |
| `sym_en` | 1 | in | `_sys` | 1-Zyklus-Puls, 18 kHz |
| `sync_load_strobe` | 1 | in | `_sys` | 1-Zyklus-Puls (aus `TX_TDMA_LOAD`) |
| `sync_tn_in` | 2 | in | `_sys` | 0..3 |
| `sync_fn_in` | 5 | in | `_sys` | 0..17 |
| `sync_mn_in` | 6 | in | `_sys` | 0..59 |
| `sync_hn_in` | 6 | in | `_sys` | 0..63 |
| `sym_cnt` | 8 | out | `_sys` | 0..254 innerhalb des Slots |
| `tn` / `fn` / `mn` / `hn` | 2/5/6/6 | out | `_sys` | 0-basiert, gültig über den ganzen Slot |
| `slot_pulse` | 1 | out | `_sys` | 1 Zyklus je Slot, **nach** dem Zählerupdate |
| `tdma_tick` | 1 | out | `_sys` | 1 Zyklus, **einen** `clk_sys` vor `slot_pulse` |

**Verhalten** [CODE rtl/tx/tetra_tdma_timebase.v:141-224]

- Wrap-Hierarchie, ausgeführt nur auf `sym_en`:
  `sym_cnt 254→0` ⇒ `tn++`; `tn 3→0` ⇒ `fn++`; `fn 17→0` ⇒ `mn++`;
  `mn 59→0` ⇒ `hn++`; `hn` wrappt frei bei 63→0.
- `tdma_tick` feuert auf derselben `clk_sys`-Flanke wie der Wrap. Zu diesem
  Zeitpunkt stehen an `tn/fn/mn/hn` noch die Werte des **ausgehenden** Slots.
  Verbraucher, die das Tupel des **neuen** Slots brauchen, nutzen `slot_pulse`
  (ein Zyklus später) oder die explizite Lookahead-Funktion aus §3.2.3.
- Sync-Load: `sync_load_strobe` legt die Werte in ein Schattenregister und setzt
  `sync_load_pending`. Der Commit passiert auf der nächsten `sym_en`-Flanke;
  fallen Strobe und `sym_en` auf denselben Zyklus, gewinnt der Load und
  verwendet direkt die Eingänge (das Schattenregister hat noch nicht gelatcht)
  [CODE rtl/tx/tetra_tdma_timebase.v:148-164]. Beim Commit wird `sym_cnt = 0`
  gesetzt und **kein** `tdma_tick` erzeugt — ein Load ist ein geordneter
  Neustart, keine normale Slot-Grenze [CODE …:207-212].
- Mehrfache Loads vor dem Commit: last-writer-wins.

**Ressourcen-Erwartung:** ~30 LUT, ~32 FF, 0 DSP, 0 BRAM — [ANNAHME]:
übernommene Schätzung des V1-Modulkopfs [CODE rtl/tx/tetra_tdma_timebase.v:60],
nicht gemessen. Eine belastbare Einzelmessung existiert nicht, weil der
Hierarchie-Report die Instanz nicht sauber trennt: er weist ihr 1853 LUT / 49 FF zu
[BUILD 2026-05-18 `build/reports/impl_hier_util.rpt:93`] — das ist ein
Cross-Hierarchy-Artefakt (Vivado ordnet absorbierte Logik des Elternmoduls
zu), keine Eigenschaft des Moduls. Verbindlich ist die Gesamtsumme (§4).

**Randfälle**

- `sym_en` bleibt aus (LVDS-Takt weg): Zähler stehen, `slot_pulse` bleibt 0,
  der Builder friert mit gültigem `tx_busy`. **V2-Anforderung:** ein
  Watchdog-Zähler zählt `sym_en`-Pulse pro 100 ms und ist AXI-lesbar, damit ein
  stehender Symboltakt nicht als Protokollfehler fehldiagnostiziert wird.
- Loadwert außerhalb des Bereichs (`fn > 17`, `mn > 59`): der Zähler übernimmt
  ihn und läuft aus dem Wrap-Schema. **V2-Anforderung:** Werte am
  Registerinterface klemmen und einen `TDMA_LOAD_REJECT`-Zähler inkrementieren.

### 3.2 Zeitschlitz-Nummerierung

#### 3.2.1 Die drei Zählweisen

| Kontext | Zählweise | Wertebereich |
|---|---|---|
| Spec-Text, SW, Logs, WebUI | ETSI 1-basiert | `TS1..TS4`, `FN1..FN18`, `MN1..MN60` |
| RTL-Signale | 0-basiert | `tn=0..3`, `fn=0..17`, `mn=0..59` |
| SYNC-PDU-Bitfelder | siehe §3.2.2 | gemischt! |

Beispiel-Notation, die in V2 überall verwendet wird: `TS2 (ETSI) = tn=1 (RTL)`.

#### 3.2.2 Die SYNC-PDU-Codierung ist **nicht** durchgängig 0-basiert

[ETSI §21.4.4.2 Tabelle 21.76]:

| SYNC-PDU-Feld | Breite | Codierung | 0-basiert übernehmbar? |
|---|---|---|---|
| Timeslot number | 2 | `00₂` = Timeslot 1 … `11₂` = Timeslot 4 | **ja** — Feld = `tn` |
| Frame number | 5 | `00000₂` reserviert, `00001₂` = Frame 1 … `10010₂` = Frame 18 | **nein** — Feld = `fn + 1` |
| Multiframe number | 6 | `000000₂` reserviert, `000001₂` = MN1 … `111100₂` = MN60 | **nein** — Feld = `mn + 1` |

Der V1-Modulkopf behauptet, die 0-basierten Zähler ließen sich „straight into
the SYNC PDU bitfields with no conversion" einsetzen
[CODE rtl/tx/tetra_tdma_timebase.v:18-22]. Für `tn` stimmt das, für `fn`/`mn`
nicht — der Code rechnet daher an anderer Stelle `+1`
[CODE rtl/tetra_zynq_top.v:3978-3979]. Die Begründung im Modulkopf ist also
falsch, das Verhalten richtig. In V2 gilt: **die Umrechnung gehört ins
Mapping-Modul, die Begründung in dessen Header.**

#### 3.2.3 Zentrales Mapping-Modul (verbindlich)

Ein Modul-Paar liefert alle Konversionen aus derselben Quelle:
`tetra_ts_map.vh` (RTL-Makros) und `tetra_ts_map.h` (SW, `static inline`).
Pflicht-Funktionen:

| Funktion | Ein | Aus |
|---|---|---|
| `TS_ETSI_TO_TN(ts)` | 1..4 | 0..3 |
| `TS_TN_TO_ETSI(tn)` | 0..3 | 1..4 |
| `TS_FN_TO_SYNC(fn)` | 0..17 | 1..18 |
| `TS_MN_TO_SYNC(mn)` | 0..59 | 1..60 |
| `TS_NEXT_TUPLE(tn,fn,mn)` | aktuelles Tupel | Tupel des Folgeslots inkl. aller Wraps |
| `TS_DENSE_IDX(mn,fn,tn)` | Tupel | 0..287 (Zeitplan-Adresse) |
| `TS_TO_CHAN_ALLOC_BITMAP(ts)` | 1..4 | 4-bit MSB-first `[TS1..TS4]` |
| `TS_TO_VOICE_MASK_BIT(ts)` | 1..4 | Bitposition 0..3 |

V1 hat die SW-Hälfte (`sw/tetra_ts_map.h`) und keine RTL-Hälfte: das
Folgeslot-Tupel ist **zweimal unabhängig** implementiert —
[CODE rtl/tetra_zynq_top.v:3963-3976] (volle 6-bit `mn`-Fortschaltung) und
[CODE rtl/tx/tetra_slot_content_mux.v:99-102] (nur `mn[1:0]`). Beide Rechnungen
stimmen in ihrem jeweiligen Kontext, sind aber duplizierter Code mit
unterschiedlicher Breite. V2 hat genau eine Implementierung.

#### 3.2.4 Lookahead-Pflicht

Encoder mit mehrzyklischer Laufzeit (BSCH/SYSINFO-Encoder, ~142 `clk_sys`
[CODE rtl/tetra_zynq_top.v:3946-3959]) müssen mit dem Tupel des **Folgeslots**
gestartet werden, sonst trägt das gesendete SYNC-PDU die Slot-Nummer des
Vorgängerslots. V1 hat genau diesen Fehler live gehabt (−1 TN-Verschiebung,
beobachtet 2026-04-21, dokumentiert im Codekommentar an derselben Stelle).
**V2-Regel:** Jeder Encoder, dessen Ausgabe eine TDMA-Koordinate enthält,
deklariert in seinem Header, ob er das aktuelle oder das Folge-Tupel erwartet;
der Aufrufer verwendet `TS_NEXT_TUPLE`.

### 3.3 `tetra_slot_schedule` — Slot-Zeitplan-Tabelle

#### 3.3.1 Speicher und Adressierung

**Speicher-Primitiv:** zwei getrennte 144 × 16-bit-Arrays (`mem_lo` für gerade,
`mem_hi` für ungerade `dense_idx`), jedes mit `(* ram_style = "block" *)` und
dem Xilinx-True-Dual-Port-Template (genau ein Schreib- und ein registrierter
Lesezugriff pro `always`-Block und Port). Erwartet: **2 × RAMB18E1**.

Begründung für den Split (nicht kosmetisch): Ein einzelnes 288 × 16-Array mit
zwei Schreib- und zwei Lesezugriffen in einem `always`-Block lehnt Vivado für
Dual-Port-BRAM-Inferenz ab (Synth 8-4767, „RAM dissolved into registers") und
synthetisiert die Tabelle als ~4900 LUT + ~4600 FF verteilte Logik
[CODE rtl/tx/tetra_slot_schedule.v:31-45]. Mit dem Split werden es 31 LUT / 1 FF
/ 2 RAMB18 [BUILD 2026-05-18 `build/reports/impl_hier_util.rpt:92`].

**Adressierung:**

```
dense_idx = (mn mod 4) * 72 + fn * 4 + tn        (0 .. 287)
word_idx  = dense_idx / 2                        (0 .. 143)   ← PS-Sicht
  Wort-Bits [15:0]  = Eintrag bei dense_idx = 2*word_idx      (mem_lo)
  Wort-Bits [31:16] = Eintrag bei dense_idx = 2*word_idx + 1  (mem_hi)
```

Die Tabelle deckt bewusst nur `mn mod 4` ab: alle multiframe-abhängigen
Downlink-Regeln von ETSI (BSCH/BNCH/CLCH-Abbildung auf den Kontrollframe)
haben Periode 4 [ETSI §9.5.2 Tabelle 9.33]. 288 Einträge × 16 bit = 576 Byte.

**Ports**

| Signal | Breite | Richtung | Domain | Bedeutung |
|---|---|---|---|---|
| `axi_we` | 1 | in | `_axi` | 1-Zyklus-Schreibfreigabe |
| `axi_addr` | 8 | in | `_axi` | Wortindex 0..143 |
| `axi_wdata` | 32 | in | `_axi` | `{ungerader Eintrag, gerader Eintrag}` |
| `axi_wstrb` | 4 | in | `_axi` | `\|wstrb[1:0]` schreibt die untere Hälfte, `\|wstrb[3:2]` die obere |
| `axi_re` | 1 | in | `_axi` | Lesefreigabe |
| `axi_rdata` | 32 | out | `_axi` | gültig 1 `clk_axi` nach `axi_re` |
| `sched_b_addr_sys` | 9 | in | `_sys` | `dense_idx`, extern getrieben |
| `schedule_entry_sys` | 16 | out | `_sys` | gültig 1 `clk_sys` nach der Adresse |

**Lese-Latenz Port B:** genau 1 `clk_sys`. Beide Bänke werden parallel gelesen;
`sched_b_addr_sys[0]` wird gleichzeitig pipelinet und wählt kombinatorisch die
Ausgangs-Bank, damit keine zweite Latenzstufe entsteht
[CODE rtl/tx/tetra_slot_schedule.v:172-196].

**Randfälle:** Adressen ≥ 288 liefern den Inhalt der ungenutzten oberen
Bankzeilen. **V2-Vertrag:** der Aufrufer treibt nie ≥ 288; das
Prefetch-Modul (§3.3.3) erzeugt die Adresse aus `TS_DENSE_IDX` und ist damit
per Konstruktion im Bereich. Kein Reset auf den BRAM-Leseregistern (das
Vivado-Template verbietet ihn); der BRAM-Inhalt nach Power-up ist 0, was einem
Eintrag „Klasse 0, idx 0, NDB, kein ndb2, **disabled**" entspricht — also ein
sicherer Zustand (Body = 0).

#### 3.3.2 Eintragsformat (verbindlich)

16 bit, MSB links. Bitnummerierung des Eintrags 15..0, unabhängig von der
Wortposition:

| Bits | Feld | Werte |
|---|---|---|
| `[15:12]` | `payload_class` | `0` = STATIC (Body aus SW-Payload-Bank), `1` = QUEUE (Body aus Signalisierungs-Scheduler, Leerlauf = NULL-PDU), `2..15` reserviert |
| `[11:6]` | `payload_idx` | Bank-Auswahl für `payload_class = 0`, siehe Tabelle unten |
| `[5:4]` | `burst_type` | `00` = NDB, `01` = SB, `10` reserviert, `11` reserviert |
| `[3]` | `ndb2` | `0` = NTS1 (ein logischer Kanal in beiden Blöcken), `1` = NTS2 (zwei Halbblöcke) |
| `[2]` | `enable` | `0` = Body wird auf 0 gezwungen (Burst wird trotzdem gesendet — Continuous Downlink), `1` = Body gültig |
| `[1:0]` | reserviert | muss 0 sein; Leseseite ignoriert, Schreibseite prüft nicht |

`payload_idx` für `payload_class = 0`:

| idx | blk1 | blk2 |
|---|---|---|
| 0 | NDB-Bank 1 | NDB-Bank 2 |
| 1 | MCCH-Bank 1 | MCCH-Bank 2 |
| 2 | BNCH-Bank 1 | BNCH-Bank 2 |
| 3 | (0 — sb1 kommt über den eigenen `sb1`-Port) | SB-BKN2-Bank |
| 4 | NDB-Bank 1 | BNCH-Bank 2 |
| 7 | 0 | 0 (leer) |
| sonst | NDB-Bank 1 | NDB-Bank 2 (Default) |

**Zwei V1-Altlasten, die V2 ausschließt:**

1. *Namenskollision auf Klassenwert 1.* Der Generator nennt `1` =
   `PCLASS_NULL_PDU` [CODE scripts/schedule.py:266], das RTL dekodiert `1` als
   `SIGNALLING` [CODE rtl/tx/tetra_burst_dispatcher.v:154]. Das Verhalten ist
   auf Luft identisch (der Leerlauf-Default des Signalisierungspfads *ist* die
   NULL-PDU), aber der Zeitplan trägt für 71 von 288 Einträgen einen Namen, der
   das Gegenteil des RTL-Namens ist. V2 hat **eine** Enumeration, generiert aus
   **einer** Quelle (der RTL-Header ist normativ, der Python-Generator
   importiert sie).
2. *Totes Bitfeld.* V1 hat `[1]` als `sys_time_inject` benannt und in 217 von
   288 Einträgen auf 1 gesetzt [CODE scripts/schedule.py:308-315]; kein
   RTL-Modul liest das Bit (verifiziert per Grep über `rtl/`). V2: das Bit ist
   reserviert und muss 0 sein, oder es bekommt eine implementierte Bedeutung.

#### 3.3.3 Prefetch der vier Einträge des Folgeframes

Ein Leseport, vier gebrauchte Einträge pro Frame ⇒ eine kleine FSM holt sie im
Voraus.

**Trigger:** `slot_pulse ∧ (tn == 3)` (der Frame-Wrap steht unmittelbar an) —
plus ein Einmal-Trigger nach Reset, der die Einträge des **aktuellen** Frames
lädt [CODE rtl/tx/tetra_slot_content_mux.v:107-110].

**Ablauf (normativ):** Die Adresse für `tn = k` wird **im Zustand vor** `S_RDk`
getrieben; in `S_RDk` steht das BRAM-Datum für `tn = k` am Leseregister und wird
dort gelatcht. Damit ist die Sequenz
`S_IDLE → S_RD0 → S_RD1 → S_RD2 → S_RD3 → S_IDLE` = **5 Zyklen ab Trigger**
(die Adresse für `tn = 0` liegt im Trigger-Zyklus in `S_IDLE` an).

V1 baut die Adresse kombinatorisch aus `next_state` [CODE
rtl/tx/tetra_slot_content_mux.v:179-184] und latcht Eintrag `k` im **selben**
Zustand `S_RDk` [CODE …:193-220, Freigaben in :196, :203, :210, :217]. Der
Zusatzzustand `S_CAP3` latcht deshalb nichts — Eintrag 3 ist bereits in `S_RD3`
übernommen; `S_CAP3` ist ein reiner Leerzustand [CODE …:94, 118-119]. Der
Modulkopf-Kommentar [CODE …:27-33]
beschreibt die andere Variante (Adresse aus `state`, Latch im Folgezustand,
6 Zyklen) und ist gegenüber dem Code gedriftet.

**V2:** eine der beiden Varianten, nicht beide — verbindlich ist die obige
5-Zyklus-Variante (Adresse aus `next_state`, Latch in `S_RDk`, kein `S_CAP3`).
Verglichen mit 1 416 700 `clk_sys` pro Slot [CODE sw/tetra_ts_map.h:37] bzw.
~5556 `clk_sys` pro Symbol ist das Zeitbudget in beiden Varianten unkritisch;
entscheidend ist, dass Kommentar, Code und Testbench dieselbe Zahl nennen.

**Adresse:** `TS_DENSE_IDX(mn', fn', k)` mit `(fn', mn')` = Folgeframe.

**V2-Änderung gegenüber V1:** V1 hat das Modul `tetra_slot_content_mux`
genannt, obwohl es nach dem Umbau nur noch der BRAM-Prefetch ist (der
Inhalts-Mux liegt im Dispatcher) [CODE rtl/tx/tetra_slot_content_mux.v:1-9].
V2 nennt es `tetra_slot_prefetch`. Der unbenutzte Eingang `tdma_tick_sys`
[CODE …:222] entfällt.

### 3.4 `tetra_burst_dispatcher` — Slot-Inhalts-Auswahl

**Zweck:** Wählt für den Slot, der jetzt beginnt, Body, Bursttyp und
Trainingssequenz-Variante und übergibt alles in **einer** Latch-Stufe an den
Builder.

**Auswahl-Priorität** (höchste zuerst), pro `tn`
[V1-Ausgangslage: CODE rtl/tx/tetra_burst_dispatcher.v:222-311; V2 hat einen Pfad mehr und
eine Ausnahme, beide unten begründet]:

0. **Grant-Override**: `grant_valid_sys` aus `tetra_ul_grant` (`06 §3.9`). BKN1 =
   `grant_blk1_sys`, `ndb2 = grant_ndb2_sys` (konstant 1, Halbschlitz-Format),
   BKN2 = Broadcast-Begleiter aus §3.5.2, `burst_type = NDB`, `enable` erzwungen
   auf 1. Der Queue-Kopf wird in diesem Slot **nicht** entnommen (`pop = 0`) und
   das Ereignis an `grant_preempt_cnt` gezählt (`06 §3.13`,
   `07 §3.1.8 REG_GRANT_PREEMPT_CNT`). Dieser Rang ist normativ in `06 §2.2`
   festgelegt: die Uplink-Zuweisung ist die einzige Aussendung mit einer harten
   Slot-Frist (R-00-01, R-08-03) und darf nicht hinter der Warteschlange warten.
1. **Persist-Override** (Halteplatz des DL-PDU-Fensters, `07 §3.3`,
   `mode = PERSIST_SET`): `persist_valid[tn] ∧ (fn ≤ 16)`. Body = 216+216 bit vom
   Halteplatz dieses Zeitschlitzes, `burst_type = NDB`,
   `ndb2 = persist_steal[tn]`, `enable` erzwungen auf 1.
   Die Bedingung `fn ≤ 16` (0-basiert) hält **FN18 (ETSI) = fn=17** frei — dort
   liegt der Kontrollframe mit BSCH/BNCH und darf nicht überschrieben werden.
   `ndb2 = 0` = NTS1 (Vollschlitz-Verkehr), `ndb2 = 1` = NTS2 (eine Hälfte für
   SCH/HD gestohlen). Das Stehl-Bit kommt aus den Metadaten des Halteplatz-Eintrags;
   Semantik und Ableitung in `06 §3.3.2`, Inhaltsklasse 5 in `06 §3.8.2`. V1 erzwingt
   hier `ndb2 = 0` und macht damit die Inhaltsklasse 5 strukturell unerreichbar.
   **Ausnahme zugunsten des Queue-Pfads (`10` R-10-09, §2.4 dort):** Gilt
   `head_valid ∧ (head_target_tn == tn) ∧ (head_pdu_class == 01₂) ∧ persist_valid[tn]
   ∧ (fn ≤ 16)`, so gewinnt der **Queue-Pfad für genau diesen Slot** — die Reihenfolge
   von Rang 1 und Rang 2 kehrt sich um. Nur so erreicht eine In-Ruf-Signalisierungs-PDU
   einen Zeitschlitz, auf dem Sprache fließt. Für alle anderen Slots und Frames bleibt
   die Reihenfolge unverändert. Jede Umkehrung wird an `steal_override_cnt` gezählt
   (16 bit, sättigend, `06 §3.13`, `07 §3.1.8 REG_STEAL_OVERRIDE_CNT`); bleibt der
   Zähler 0, obwohl die Rufsteuerung eine In-Ruf-PDU auf dem Sprachschlitz gestaget
   hat, ist die Regel nicht implementiert.
2. **Queue-Pfad**: `sched_active[tn] ∨ (payload_class == QUEUE)`.
   `blk1/blk2/ndb2` vom Signalisierungs-Scheduler (§3.5.2).
3. **Statischer Pfad**: Body aus der SW-Payload-Bank gemäß `payload_idx`,
   `ndb2` aus Eintragsbit `[3]`.

`burst_type` kommt in **allen** Fällen außer 0 und 1 aus Eintragsbit `[5:4]`:
Signalisierung reitet auf dem Bursttyp, den der Zeitplan für diesen Slot
vorsieht.

**Inhaltsklasse für den AACH.** Der Verteiler gibt zusätzlich `content_sys[2:0]`
aus — die Inhaltsklasse des gestageten Slots, aus der `tetra_aach_info` das
14-bit-Infowort berechnet (`06` R-06-04: das Infowort entsteht aus der
Inhaltsentscheidung **desselben** Slots, nicht aus einem Software-Register). Die
Enumeration ist **normativ in `06 §3.8.2`** und wird hier nicht wiederholt (P2);
hier steht nur, welchen Wert welcher Auswahlpfad treibt:

| Auswahlpfad / Zustand | `content_sys` |
|---|---:|
| `build_burst_type_sys = 1` (SB/BSCH, Eintragsbit `[5:4]` = `01`) — unabhängig vom Pfad | 0 |
| Statischer Pfad ∧ `burst_type = NDB` ∧ `payload_idx ∈ {2, 4}` (Broadcast-Leerlauf) | 1 |
| Grant-Override (Rang 0) oder Queue-Pfad, `build_ndb2_sys = 0` | 2 |
| Grant-Override (Rang 0) oder Queue-Pfad, `build_ndb2_sys = 1` | 3 |
| Persist-Override (Rang 1), `build_ndb2_sys = 0` | 4 |
| Persist-Override (Rang 1), `build_ndb2_sys = 1` | 5 |
| `enable = 0`, oder statischer Pfad mit `payload_idx = 7`, oder kein Pfad aktiv | 6 |

Der Wert `7` ist reserviert und darf nicht getrieben werden. Alle für diese
Ableitung nötigen Größen liegen im Verteiler bereits an; der Ausgang kostet drei
Flipflops in derselben Latch-Stufe wie `build_req_sys`.

**`enable = 0`**: Body und `sb1` werden auf 0 gezwungen, `bb` (AACH) wird
**immer** durchgereicht [CODE …:331-335]. Der Burst wird gesendet — Continuous
Downlink kennt kein Slot-Blanking.

**Schnittstelle (Auszug)**

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `tx_slot_pulse_sys` | 1 | in | Slot-Grenze aus der Zeitbasis |
| `tx_slot_num_sys` | 2 | in | `tn` des beginnenden Slots |
| `tx_fn_sys` | 5 | in | `fn` (0-basiert) für das FN18-Gate |
| `sched_blk1/2_tn{0..3}_sys` | 216 | in | Queue-Fan-out |
| `sched_active_sys` / `sched_ndb2_sys` | 4 | in | Queue-Status pro `tn` |
| `sched_entry_reg_sys{0..3}` | 16 | in | Zeitplan-Einträge des Frames |
| `head_valid_sys` / `head_target_tn_sys` / `head_pdu_class_sys` | 1/2/2 | in | Kopf der Sende-Warteschlange: gültig, Ziel-`tn`, PDU-Klasse aus `W15[10:9]` der DL-PDU-Mailbox (`07 §3.3`). Nur für die Stehl-Ausnahme in Rang 1 nötig |
| `persist_blk1/2_per_ts_sys` | 4×216 | in | Halteplätze des DL-PDU-Fensters (`07 §3.3`, `mode = PERSIST_SET`), Slice `k` = TS(k+1) |
| `persist_valid_per_ts_sys` | 4 | in | Halteplatz gesetzt, je `tn` |
| `persist_steal_per_ts_sys` | 4 | in | Halteplatz-Metadatum: 0 = NTS1 (Vollschlitz), 1 = NTS2 (eine Hälfte gestohlen), Semantik `06 §3.3.2` |
| `grant_valid_sys` | 1 | in | Slot trägt eine Uplink-Zuweisung (`06 §3.9.7`) |
| `grant_blk1_sys` | 216 | in | codierter Zuweisungsblock, MSB = erstes On-Air-Bit |
| `grant_ndb2_sys` | 1 | in | konstant 1 (Halbschlitz-Format) |
| `bb_in_sys` | 30 | in | vorcodierte AACH-Bits, MSB = bb(1) |
| `sb_sb1_in_sys` | 120 | in | vorcodierte BSCH-Bits, MSB = sb(1) |
| `build_block1/2_sys` | 216 | out | Body, gültig mit `build_req` |
| `build_bb_sys` | 30 | out | AACH |
| `build_sb1_sys` | 120 | out | BSCH |
| `build_burst_type_sys` | 1 | out | 0 = NDB, 1 = SB |
| `build_ndb2_sys` | 1 | out | 0 = NTS1, 1 = NTS2 |
| `content_sys` | 3 | out | Inhaltsklasse des gestageten Slots für den AACH-Generator `tetra_aach_info`; Enumeration normativ in `06 §3.8.2`, Ableitung je Pfad in der Tabelle oben |
| `pop_sys` | 1 | out | Entnahme des Queue-Kopfs; bei Rang 0 (Grant-Override) erzwungen 0 |
| `steal_override_cnt_sys` | 16 | out | sättigend: Umkehrungen der Ränge 1/2 nach `10` R-10-09 |
| `build_req_sys` | 1 | out | 1-Zyklus-Puls |

**Timing:** `build_req_sys` pulst genau einen `clk_sys` nach `tx_slot_pulse_sys`
und wird bedingungslos in der Folgeflanke gelöscht — der Builder-Vertrag ist
„1-Zyklus-Puls" [CODE …:318-341].

**Ressourcen:** 193 LUT / 586 FF [BUILD 2026-05-18 `impl_hier_util.rpt:73`].
Die FF-Zahl ist plausibel (4 × 216 + 30 + 120 + Meta ≈ 1000 bit Latches, davon
ein Teil vom Optimizer geteilt); die LUT-Zahl ist der 4:1-Mux über
4 × 216-bit-Busse.

**V2-Änderung:** Der unbenutzte Eingang `tx_busy_sys` entfällt
[CODE …:345]. Der `default`-Zweig über `tx_slot_num_sys` (2 bit, alle 4 Werte
abgedeckt) bleibt als defensive Zuweisung, aber ohne eigene Body-Konstante.

### 3.5 Sende-Warteschlange und Signalisierungs-Scheduler

#### 3.5.1 `tetra_dl_signal_queue`

**Zweck:** Puffert fertig kanalcodierte DL-Signalisierungs-PDUs (SCH/F 432 bit
oder SCH/HD 216 bit) und gibt sie einzeln an den Slot-Consumer. Keine
PHY-Logik, kein Encoder — reiner Transport.

**Speicher:** Registerarray, `DEPTH = 4`. Kein BRAM: 4 × ~470 bit sind billiger
als ein BRAM-Port mit Latenz, und die Pop-Arbitrierung braucht alle Einträge
kombinatorisch [CODE rtl/lmac/tetra_dl_signal_queue.v:146-153].

**Eintrag**

| Feld | Breite | Bedeutung |
|---|---|---|
| `coded` | 432 | codierte Bits, **MSB-ausgerichtet** (§3.11) |
| `pdu_type` | 2 | `00` = SCH/F, `01` = SCH/HD, `10`/`11` reserviert |
| `target_tn` | 2 | 0..3 — auf welchem `tn` die PDU gesendet wird |
| `prio` | 2 | `00` = MLE, `01` = CMCE, `10` = SDS, `11` reserviert |
| `second_pdu_present` | 1 | Telemetrie: der codierte Block trägt eine angehängte zweite MAC-PDU |
| `second_pdu_nr` | 1 | Telemetrie zum obigen |
| `valid` | 1 | Belegung |

**Schreib-Arbitrierung:** drei Ports (MLE / CMCE / SDS). Feuern mehrere im
selben Zyklus, gewinnt der mit der kleineren `prio`-Nummer; die Verlierer gelten
als Verwurf [CODE …:162-184, 361-363]. Freier Slot = kleinster Index mit
`valid = 0`.

**Überlauf: drop-newest.** Bei voller Queue wird der ankommende Eintrag
verworfen, die vier gespeicherten bleiben unangetastet
[CODE …:201, 340]. Begründung, die in V2 gilt: die gespeicherten Einträge sind
älter, ihre Sende-Deadline liegt näher, und die Retransmission liegt beim MS.
Ein drop-oldest würde bereits zugesagte Antworten (z. B. eine LU-ACCEPT) gegen
eine spätere ersetzen und den Attach-Handshake reihum brechen.

**Pop-Arbitrierung:** strikte Priorität über alle gültigen Einträge; bei
Gleichstand innerhalb einer Prioritätsstufe gewinnt der kleinere Slotindex
[CODE …:207-273]. Vollständig kombinatorisch: der Consumer liest `head_*` und
setzt `pop` im selben Zyklus, die Queue löscht den Eintrag in der Folgeflanke.
Pop und Schreiben im selben Zyklus zielen per Konstruktion auf verschiedene
Slots (`head_idx` ist gültig, `free_idx` ist ungültig).

**Verwurfs-Zähler (normativ)**

| Zähler | Breite | Inkrementiert bei |
|---|---|---|
| `drop_cnt` | 16, sättigend | jeder nicht gespeicherte Schreibversuch: Queue voll **oder** Arbitrierungs-Verlust; beides zusammen zählt beides |
| `drop_cnt_mle` | 16, sättigend | `wr_mle_valid` und der akzeptierte Schreibvorgang gehörte nicht MLE |
| `drop_cnt_cmce` | 16, sättigend | analog CMCE |
| `drop_cnt_sds` | 16, sättigend | analog SDS |
| `depth_count` | 3 | Momentanwert 0..4 |
| `depth_valid_mask` | 4 | Momentanwert, ein Bit je Slot |

**Alle sechs sind AXI-lesbar, jedes unter seinem eigenen Namen.** V1 erfüllt das
nur teilweise:

- `drop_cnt` ist 16 bit und **ist** AXI-lesbar, aber als `clear_cnt` im oberen
  Halbwort von `REG_MLE_STATS_C` versteckt — ein Registername, der etwas
  anderes aussagt als der Inhalt [CODE rtl/infra/tetra_axi_lite_regs.v:795-797,
  1232]. Der Pfad ist vollständig: `queue_drop_cnt_w` → `mle_clear_cnt_sys`
  [CODE rtl/tetra_zynq_top.v:2613] → 2-FF-Resync [CODE …:2643-2672] → Port
  `.mle_clear_cnt_axi` [CODE …:2145].
- `depth_count` und `depth_valid_mask` sind im Top-Level verdrahtet, aber an
  kein Register geführt [CODE rtl/tetra_zynq_top.v:514-516, 2544-2546 — kein
  Pfad zu `tetra_axi_lite_regs`].
- Die drei Produzenten-Zähler sind nur 8 bit und sättigen bei 255
  [CODE rtl/lmac/tetra_dl_signal_queue.v:138-140]. Ein Verwurfsproblem, das 255
  Ereignisse überschreitet, ist damit nicht mehr unterscheidbar von einem, das
  5000 überschreitet.

Die V2-Anforderung „eigene, benannte Register" begründet sich also nicht mit
einem fehlenden Register, sondern mit einem irreführenden: ein Verwurfszähler,
der `clear_cnt` in einem `MLE_STATS`-Register heißt, wird bei der nächsten
Fehlersuche nicht gefunden.

#### 3.5.2 `tetra_dl_signal_scheduler`

**Zweck:** Kombinatorischer Fan-out des Queue-Kopfs auf vier `tn`-Bündel plus
das Pop-Strobe. **Kein Latch.**

```
tgt_tn[k] = head_valid ∧ (head_target_tn == k)
blk1[k]   = tgt_tn[k]                    ? head_coded[431:216] : null_pdu_bits
blk2[k]   = tgt_tn[k] ∧ (pdu_type==SCH/F)? head_coded[215:0]   : sig_companion
ndb2[k]   = tgt_tn[k]                    ? (pdu_type==SCH/HD)  : 1
active[k] = tgt_tn[k]
pop       = slot_pulse ∧ head_valid ∧ (head_target_tn == tn)
```
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:143-185]

`null_pdu_bits` (216 bit, SCH/HD-codierte NULL-PDU) und `sig_companion`
(216 bit, SYSINFO/BNCH-Begleithälfte) kommen aus SW-Registern.
Der Leerlauf eines Queue-Slots ist damit ein **gültiger** NDB2:
BKN1 = NULL-PDU, BKN2 = Broadcast-Begleiter, NTS2. Das entspricht dem
Referenznetz: von 1834 Bursts auf TS1 sind 1785 NDB2, davon **1698** genau
dieser Leerlauf-NDB2 (MAC-RESOURCE SCH/HD, `addr = NULL`, LI = 2,
BKN2 = MAC-BROADCAST SYSINFO); 74 tragen dieselbe BKN1 **ohne** dekodierten
BKN2-Begleiter und 13 eine adressierte MAC-RESOURCE (`addr = SSI ID=2633716`,
LI = 7 in 7 Fällen, LI = 6 in 6 Fällen)
[GOLD `docs/reference_decode/dl_events.jsonl`, ausgewertet über alle 7338
Bursts; Beispielburst #727 in `dl_full.md:17024`].

**Warum kein Latch:** Eine Bündel-Latch-Stufe auf `slot_pulse ∧ tn == 3`
kollidierte in V1 mit dem Prefetch, der auf derselben Flanke startet — das
Ergebnis war „AACH greift 1 Frame zu spät" auf Vorantwort-Slots
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:6-24]. Der kombinatorische Fan-out
ist stabil, solange die Queue nicht poppt, und das Pop-Strobe liegt bewusst auf
dem Slot, der die PDU trägt — also **nach** dem Prefetch, der den Body schon
übernommen hat.

**Zähler:** `pop_cnt` (16 bit, sättigend). V1 führt zusätzlich
`override_cnt`, das identisch mit `pop_cnt` ist und nur aus
AXI-Rückwärtskompatibilität existiert [CODE …:196-199]. **V2: entfällt.**

#### 3.5.3 Vorantwort und Antwort im Anmeldeablauf

Beim Attach antwortet die BS **zweimal**: zuerst mit einer kurzen Vorantwort
(SCH/HD, MAC-RESOURCE, `addr = SSI`, LI = 7 — im Referenznetz ohne LLC-/MM-Inhalt
im dekodierten BKN1) [GOLD `docs/reference_decode/dl_full.md:18150ff`,
Burst #775], dann mit der eigentlichen Antwort (SCH/F,
D-LOCATION-UPDATE-ACCEPT). Im Referenznetz liegen zwischen beiden **2
TDMA-Frames auf demselben Zeitschlitz**. Das ist ein **Messwert**, keine
V2-Vorgabe: alle Zeitgrößen des Antwortpfads sind normativ in `08_TIMING.md`
festgelegt (R-08-11, `08 §3.5.2`), dieses Kapitel wiederholt sie nicht.

Die Vorantwort erteilt dem MS ein Slot-Grant; welches Feld der MAC-RESOURCE das
tut, ist hier **nicht** belegt [ANNAHME — die Grant-Semantik ist aus dem
Zeitverlauf erschlossen, nicht aus dem Gold-Decode; die Feldbelegung von
MAC-RESOURCE einschließlich `slot_granting_flag` gehört nach `06_MAC.md`].

Beleg aus dem Referenznetz [GOLD `docs/reference_decode/dl_full.md`]:

| Burst | Zeit | Slot | Inhalt |
|---|---|---|---|
| #775 | 10,965 s | TS1 FN02 MN49 | NDB2 SCH/HD, MAC-RESOURCE `addr = SSI 2633716`, LI = 7 → Vorantwort |
| #783 | 11,079 s | TS1 FN04 MN49 | NDB1 SCH/F, MAC-RESOURCE `addr = SSI 2633716`, LI = 21, MLE → D-LOC-UPD-ACCEPT |

Differenz: 8 Burst-Positionen = 2 TDMA-Frames = 114 ms (nominal
2 × 56,67 ms = 113,3 ms), gleicher Zeitschlitz, gleiche Multiframe.

**Was den Abstand füllt:** Das MS sendet nach der Vorantwort sein zweites
Uplink-Fragment. Die BS muss dieses Fragment empfangen, reassemblieren und die
MM-Felder parsen, **bevor** sie die
ACCEPT baut — nur dann kann sie die vom MS gewünschte Gruppen-Identität in die
ACCEPT übernehmen (LI = 21 mit GILA-Element statt einer kürzeren
Profil-Default-ACCEPT mit LI = 12). Der Abstand ist damit kein Selbstzweck,
sondern der Platz für den UL-Burst des MS (`08 §3.4.3` R-3). Das
Zusammensetz-Fenster **T0 ist keine Wartezeit**, die kürzer als dieser Abstand
sein müsste, sondern eine obere Verwurfsschranke — normativ **9 TDMA-Frames**
(`08 §3.5.2`). Dass 9 Frames **länger** sind als die im Referenznetz beobachteten
2 Frames, ist deshalb kein Widerspruch: die Antwort wartet nicht auf den Ablauf
von T0, sondern auf die Vollständigkeit der Kette; T0 begrenzt nur, wie lange auf
ein fehlendes Fragment gewartet wird.

**V2-Anforderung (R-04-21):** Für den Abstand zwischen Vorantwort und
Anmeldebestätigung existiert **kein** Abstandsmechanismus: kein Wartezustand
zwischen den beiden PDUs, kein Registerfeld, das diesen Abstand vorgibt, und kein
Selbstzählen von Slot-Pulsen im Erzeuger. Ein eingestellter
Warteschlangen-Eintrag geht im nächsten passenden Slot seines `target_ts` hinaus
(§3.5.1, Frame-Quantisierung `08 §3.4.1`); der Zeitpunkt der Antwort entsteht
allein aus dem Ereignis, das sie erzeugt — „Zusammensetzung vollständig **oder**
Fenster abgelaufen", normativ in `08 §3.5.2`, frame-granular nach `08` R-08-11.
Ein fester Abstand als Ersatz für dieses Ereignis ist **verboten**. Das Feld
`delay_slots` der DL-PDU-Mailbox (`07 §3.3`) ist davon **nicht** betroffen: es
staffelt identische Wiederholungen **derselben** PDU (`10 §3.4.3`, Abstand
normativ `08 §3.4.3` R-4) und darf für einen Antwortabstand nicht verwendet
werden. Prüfbar: (a) Codereview — kein Zähler und kein Registerfeld im
Sendepfad, dessen Wert den Abstand zwischen zwei **verschiedenen** PDUs eines
Handshakes festlegt; (b) Simulation mit früher und mit später Fertigmeldung der
Zusammensetzung ergibt zwei **verschiedene** Antwortzeitpunkte, beide auf
`target_ts` und beide im ersten passenden Slot nach der Einstellung.

Verboten ist ebenso der V1-Endzustand, in dem der Abstand nur noch aus der
Latenz der SW-Hauptschleife entsteht — ohne Frameraster und ohne obere Schranke.
Die eigene Aufzeichnung zeigt die Folge: UL#0 bei 11,13 s → D-LOC-UPD-ACCEPT
(DL #873) bei 12,35 s, also **+1,2 s** statt 114 ms
[MESS 2026-05-15 `docs/local_cell_decode/DIFF_vs_reference.md:216` — eigene
Aufzeichnung, Größe: Δt(UL-Attach → DL-ACCEPT); Capture-Stand vor mehreren
späteren Fixes, daher als Größenordnung, nicht als Endwert zu lesen]. Die
V2-Antwort darauf ist nicht ein fester Abstand, sondern die Ereignis-Triggerung
mit gezähltem Fallback (`08 §3.5.2` Punkt 3,
`REASS_INCOMPLETE_AT_REPLY_CNT`).

### 3.6 `tetra_burst_builder` — Burst-Aufbau

#### 3.6.1 Grundgrößen

510 Modulationsbits = 255 Symbole je Burst; Symbolindex 0..254 intern,
ETSI-Symbolnummern SN1..SN255. Burst-Delay d = 0, keine Guard-Periode, weder
Rampe noch Blanking [ETSI §9.4.4.1 Tabelle 9.2: „normal continuous downlink
burst — SNmax 255, d = 0"].

#### 3.6.2 Bitallokation — Normal Continuous Downlink Burst (NDB)

[ETSI §9.4.4.2.5 Tabelle 9.7], BN = Bitnummer 1-basiert, MSB des jeweiligen
Busses zuerst:

| BN | Länge | Feld | Quelle im V2-Design |
|---|---|---|---|
| 1–12 | 12 | normal training sequence 3, `q11..q22` | Konstante `NTS3_HI` |
| 13–14 | 2 | phase adjustment `ha1..ha2` | **berechnet**, §3.6.5 |
| 15–230 | 216 | `bkn1(1..216)` | `build_block1[215:0]`, Bit 215 = `bkn1(1)` |
| 231–244 | 14 | `bb(1..14)` | `build_bb[29:16]` |
| 245–266 | 22 | normal training sequence 1 (`n`) **oder** 2 (`p`) | `ndb2 ? NTS2 : NTS1` |
| 267–282 | 16 | `bb(15..30)` | `build_bb[15:0]` |
| 283–498 | 216 | `bkn2(1..216)` | `build_block2[215:0]` |
| 499–500 | 2 | phase adjustment `hb1..hb2` | **berechnet**, §3.6.5 |
| 501–510 | 10 | normal training sequence 3, `q1..q10` | Konstante `NTS3_LO` |

Die Wahl NTS1 vs. NTS2 ist normativ ein Flag für die Kanalbelegung der beiden
Blöcke [ETSI §9.4.4.3.2 Tabelle 9.13]: NTS1 für TCH oder SCH/F (ein logischer
Kanal über beide Blöcke), NTS2 für STCH+TCH, STCH+STCH, SCH/HD+SCH/HD,
SCH/HD+BNCH.

#### 3.6.3 Bitallokation — Synchronization Continuous Downlink Burst (SB)

[ETSI §9.4.4.2.6 Tabelle 9.9]:

| BN | Länge | Feld | Quelle |
|---|---|---|---|
| 1–12 | 12 | `q11..q22` | `NTS3_HI` |
| 13–14 | 2 | phase adjustment `hc1..hc2` | **berechnet** |
| 15–94 | 80 | frequency correction `f1..f80` | Konstante `FC` |
| 95–214 | 120 | `sb(1..120)` | `build_sb1[119:0]`, Bit 119 = `sb(1)` |
| 215–252 | 38 | synchronization training sequence `y1..y38` | Konstante `STS` |
| 253–282 | 30 | `bb(1..30)` | `build_bb[29:0]` — hier **zusammenhängend** |
| 283–498 | 216 | `bkn2(1..216)` | `build_block2[215:0]` |
| 499–500 | 2 | phase adjustment `hd1..hd2` | **berechnet** |
| 501–510 | 10 | `q1..q10` | `NTS3_LO` |

#### 3.6.4 Konstanten (normativ, verifiziert)

Alle Werte aus ETSI; alle in V1 bitgleich vorhanden [CODE
rtl/tx/tetra_burst_builder.v:91-127] und zusätzlich gegen die
Referenzaufzeichnung geprüft. Bitfolgen MSB-first, Dibits als `(B(2n-1)B(2n))`.

| Konstante | ETSI | Bitfolge | Dibits |
|---|---|---|---|
| `NTS3` (`q1..q22`) | §9.4.4.3.2 Gl. 9.6 | `1,0,1,1,0,1,1,1,0,0,0,0,0,1,1,0,1,0,1,1,0,1` | — |
| `NTS3_HI` = `q11..q22` | ↑ | `0,0,0,1,1,0,1,0,1,1,0,1` | `(00)(01)(10)(10)(11)(01)` |
| `NTS3_LO` = `q1..q10` | ↑ | `1,0,1,1,0,1,1,1,0,0` | `(10)(11)(01)(11)(00)` |
| `NTS1` (`n1..n22`) | §9.4.4.3.2 Gl. 9.4 | `1,1,0,1,0,0,0,0,1,1,1,0,1,0,0,1,1,1,0,1,0,0` | `(11)(01)(00)(00)(11)(10)(10)(01)(11)(01)(00)` |
| `NTS2` (`p1..p22`) | §9.4.4.3.2 Gl. 9.5 | `0,1,1,1,1,0,1,0,0,1,0,0,0,0,1,1,0,1,1,1,1,0` | `(01)(11)(10)(10)(01)(00)(00)(11)(01)(11)(10)` |
| `STS` (`y1..y38`) | §9.4.4.3.4 Gl. 9.11 | `1,1,0,0,0,0,0,1,1,0,0,1,1,1,0,0,1,1,1,0,1,0,0,1,1,1,0,0,0,0,0,1,1,0,0,1,1,1` | `(11)(00)(00)(01)(10)(01)(11)(00)(11)(10)(10)(01)(11)(00)(00)(01)(10)(01)(11)` |
| `FC` (`f1..f80`) | §9.4.4.3.1 Gl. 9.1–9.3 | `f1..f8=1`, `f9..f72=0`, `f73..f80=1` | 4×`(11)`, 32×`(00)`, 4×`(11)` |

Das FC-Feld erzeugt einen unmodulierten Träger 2,25 kHz über der
Nominalfrequenz, davor und danach je 4 Symboldauern 6,75 kHz darunter.

**Gold-Verifikation** [GOLD `docs/reference_decode/dl_events.jsonl`, 5171
SB-Bursts]: `STS` stimmt in 5171/5171 Bursts (Dibit-Index 106..124), `NTS3_LO`
in 5171/5171 (Dibit-Index 249..253, Folge `2,3,1,3,0`).

**Zwei Namens-/Zitat-Korrekturen gegenüber V1:**
`NTS3_HI`/`NTS3_LO` heißen in V1 `TAIL1`/`TAIL2` — ein Fehlname: das
Tail-Bit-Feld `(t1..t4) = 1,1,0,0` [ETSI §9.4.4.3.5 Gl. 9.12] existiert nur in
Uplink- und diskontinuierlichen Bursts. Und der V1-Kommentar zu `NTS2` zitiert
„§9.4.4.3.3" (das ist die *extended* training sequence) statt §9.4.4.3.2 Gl. 9.5.

#### 3.6.5 Phasenanpassungs-Bits — in V1 falsch, in V2 Pflicht

**Normativ** [ETSI §9.4.4.3.6 Gl. 9.14 + Tabelle 9.15]: Das Bitpaar ist so zu
setzen, dass der von ihm erzeugte Phasenübergang gleich

```
Dφ = − Σ(n = n1 … n2) Dφ(n)
```

ist, wobei `Dφ(n)` der Übergang der Symbole in `[n1, n2]` ist. Für π/4-DQPSK:

| Bitpaar | Bursttyp | n1 | n2 |
|---|---|---|---|
| `ha1,ha2` | NDB (continuous) | 8 | 122 |
| `hb1,hb2` | NDB (continuous) | 123 | 249 |
| `hc1,hc2` | SB (continuous) | 8 | 108 |
| `hd1,hd2` | SB (continuous) | 109 | 249 |

Die Summe ist immer ein ungerades Vielfaches von π/4 (jeder Summand ist eines,
und die Anzahl Summanden ist in allen vier Fällen ungerade), also stets durch
**ein** Dibit darstellbar. Der Zweck ist eine bekannte Phasenbeziehung zwischen
den Trainingssequenzen des Bursts, unabhängig vom Blockinhalt — Voraussetzung
für Entzerrer- und kohärente Empfänger.

**V1 setzt beide Paare fest auf `2'b00`** [CODE rtl/tx/tetra_burst_builder.v:96,
verwendet in :201-205]. `00` erzeugt konstant +π/4 und leistet keine Balance.
Das bleibt bei rein differentieller Demodulation unbemerkt, verletzt aber die
Norm.

**Beleg, dass ein echtes Netz die Bits rechnet** [GOLD `dl_events.jsonl`, 5171
SB-Bursts]:

| Bitpaar | Dibit-Index in der Gold-Dibitfolge | beobachtete Werte |
|---|---|---|
| `hc` | 5 | `01` (2718×), `10` (2453×) — **niemals** `00` |
| `hd` | 248 | `01` (3129×), `11` (2042×) — **niemals** `00` |

Der Wert wechselt inhaltsabhängig, wie es Gl. 9.14 verlangt.

**V2-Implementierung:** Der Builder kennt die Dibitfolge des Bursts, bevor er
sendet. Er berechnet die Phasensumme über den Bereich als Modulo-8-Summe der
Phaseninkremente (§3.7.2: 00→+1, 01→+3, 10→+7, 11→+5) und wählt das Dibit,
dessen Inkrement das Negative dieser Summe (mod 8) ist:

```
sum8   = Σ inc(dibit(n))  für n = n1..n2, mod 8
need8  = (8 − sum8) mod 8            // ∈ {1,3,5,7}, da sum8 ungerade
padj   = inc⁻¹(need8)                // 1→00, 3→01, 7→10, 5→11
```

Umsetzung: eine 3-bit-Akkumulator-Pipeline, die während des Schiebens des
vorigen Bursts über die 510 bereits bekannten Bits läuft (der Body liegt zum
`build_req` vollständig an) — Kosten in der Größenordnung 40 LUT / 20 FF, keine
DSP — [ANNAHME]: gerechnet aus 3-bit-Akkumulator + Bereichszähler +
Ausgangs-Dibit; der Block existiert in V1 nicht, eine Messung ist deshalb nicht
möglich.

Randfall: `sum8` gerade ⇒ Widerspruch zur Norm ⇒ das Modul setzt `00` und
inkrementiert einen `REG_TX_PADJ_UNBAL_CNT`-Zähler; das darf nie auftreten und ist
damit ein Assertion-Ersatz im Betrieb.

#### 3.6.6 Schieberegister, Verkettung, Strobes

**Aufbau:** 510-bit-Schieberegister, `burst_sreg[509:508]` ist das gerade
ausgegebene Dibit; MSB = zuerst gesendet. Pro `sym_en` wird um 2 bit geschoben
[CODE rtl/tx/tetra_burst_builder.v:191-222].

**FSM:** `S_IDLE → S_SHIFT → S_DONE`. `sym_cnt` läuft 0..254 in `S_SHIFT`.

**Lückenlose Verkettung:** Trifft ein neues `build_req` ein, während
`tx_busy = 1`, wird der Burst in ein Schattenregister assembliert; bei
`sym_cnt == 254` lädt das Schieberegister aus dem Schatten und `sym_cnt` wrappt
auf 0, ohne `S_DONE` zu durchlaufen — `tx_busy` bleibt durchgehend hoch
[CODE …:162-188, 217-219, 263-274]. Das ist die Bedingung für Continuous
Downlink: der Symbolstrom hat über Slot-Grenzen keine Lücke.

**Strobes**

| Signal | Semantik |
|---|---|
| `tx_dibit_sys[1:0]` | registriert, aktualisiert auf `sym_en ∧ tx_busy` |
| `tx_dibit_valid_sys` | 1 Zyklus, ein `clk_sys` nach `sym_en` in `S_SHIFT` |
| `tx_done_sys` | 1 Zyklus beim letzten Symbol (`sym_cnt == 254`) |
| `tx_busy_sys` | hoch, solange ein Burst läuft (auch über Verkettungen) |
| `first_dibit_sys` | kombinatorisch, `sym_en ∧ S_SHIFT ∧ sym_cnt == 0`; Messanker für die Slot-Stoppuhr (siehe `08`) |

**Randfall Unterlauf:** Kommt kein `build_req`, geht die FSM nach `S_DONE` und
`tx_busy` fällt — der Träger bricht ab. **V2-Anforderung:** Bleibt ein
`build_req` aus, sendet der Builder autonom einen Idle-Burst
(NDB2, BKN1 = NULL-PDU, BKN2 = 0, NTS2) und inkrementiert einen
`REG_TX_BUILD_REQ_MISS_CNT`-Zähler. Ein Träger, der wegen eines SW-Aussetzers abreißt,
kostet allen MS in der Zelle die Synchronisation.

### 3.7 `tetra_pi4dqpsk_mod` — Modulator

#### 3.7.1 Schnittstelle

| Signal | Breite | Richtung | Bedeutung |
|---|---|---|---|
| `clk_sys` / `rst_n_sys` | 1 | in | 100 MHz, active-low |
| `dibit_in` | 2 | in | `dibit_in[1]` = B(2k−1), `dibit_in[0]` = B(2k) |
| `dibit_valid` | 1 | in | 1-Zyklus-Strobe, ~18 kHz |
| `i_out` / `q_out` | 16 signed | out | Q1.15 |
| `sample_valid_out` | 1 | out | 1-Zyklus-Strobe, ein `clk_sys` nach `dibit_valid` |

**Pipeline:** 1 Stufe. Stufe 0 kombinatorisch (Inkrement + IQ-Lookup aus der
*neuen* Phase), Stufe 1 registriert Phase, I, Q, Valid.

#### 3.7.2 Die normative Zuordnungstabelle

**Bitzuordnung** [ETSI §9.4.3.3 + §9.4.3.4]: Die Bits BN(2n−1) und BN(2n)
bilden das Symbol SN(n). BN(2n−1) ist das **zuerst gesendete** Bit des Paares.
In der V2-Signalisierung: `dibit[1]` = BN(2n−1), `dibit[0]` = BN(2n) —
**MSB-first**, konsistent mit allen Bussen dieses Kapitels (§3.11).

**Differentielle Codierung** [ETSI §5.4 Gl. 5.1]:
`S(k) = S(k−1) · exp(j·Dφ(k))`, `S(0) = 1`. S(0) ist das Symbol vor dem ersten
Symbol des ersten Bursts und wird als Phasenreferenz gesendet; sein Symbolzeit­
punkt liegt eine Symboldauer vor SN1 [ETSI §9.4.3.4].

**Phasenübergänge** [ETSI §5.4 Tabelle 5.1] — vollständig:

| B(2k−1) | B(2k) | `dibit_in` | Dφ(k) | Inkrement des 3-bit-Phasenindex |
|---|---|---|---|---|
| 0 | 0 | `2'b00` | **+π/4** | `+1` |
| 0 | 1 | `2'b01` | **+3π/4** | `+3` |
| 1 | 0 | `2'b10` | **−π/4** | `+7` (= −1 mod 8) |
| 1 | 1 | `2'b11` | **−3π/4** | `+5` (= −3 mod 8) |

Diese vier Zeilen sind die normative Tabelle; der V1-Code stimmt heute mit ihr
überein [CODE rtl/tx/tetra_pi4dqpsk_mod.v:96-104].

Die Zeilen `10` und `11` waren in V1 zeitweise vertauscht, und der Fehler blieb
lange unsichtbar, weil der **eigene** Decoder dieselbe Vertauschung trug: die
Loopback-CRC ging durch, während jeder normgerechte Empfänger 10 der 19
STS-Dibits invertiert sah. Drei V2-Regeln schließen diese Fehlerklasse aus:

1. Die Tabelle steht normativ in diesem Abschnitt (§3.7.2, die vier Zeilen
   oben) und **nur** hier; Modulator, Demodulator (`02 §3.5`, `03 §3.2.1`) und
   alle Python-Werkzeuge beziehen sie aus **einer** daraus generierten Datei
   (Generator: `15_BUILD_DEPLOY §3`). Eine zweite Zuordnungstabelle im
   Dokumentensatz ist ein Spec-Fehler.
2. Der Modulator-Testvektor wird **nicht** aus dem Demodulator abgeleitet, sondern
   unabhängig aus Gl. 5.1 + Tabelle 5.1 gerechnet (4 Dibits × 8 Startphasen),
   plus ein Ende-zu-Ende-Vektor gegen die 19 STS-Dibits aus §3.6.4.
3. Zitiert wird `§5.4 Tabelle 5.1`. Die V1-Modulkommentare nennen „§5.5.2.3",
   „§9.3" und „Table 9.1" — keine dieser Stellen enthält in
   EN 300 392-2 v3.8.1 die Zuordnung.

#### 3.7.3 Konstellation

Absolute Phase = `phase_idx × 45°`. Amplituden in Q1.15
[CODE rtl/tx/tetra_pi4dqpsk_mod.v:73-75, 121-133]:

| idx | Phase | I | Q |
|---|---|---|---|
| 0 | 0° | +32767 | 0 |
| 1 | 45° | +23170 | +23170 |
| 2 | 90° | 0 | +32767 |
| 3 | 135° | −23170 | +23170 |
| 4 | 180° | −32767 | 0 |
| 5 | 225° | −23170 | −23170 |
| 6 | 270° | 0 | −32767 |
| 7 | 315° | +23170 | −23170 |

`23170 = round(32767/√2)`. `−32767` statt `−32768`, damit die Betragsbildung
symmetrisch bleibt. Der Index nimmt für gerade `k` nur gerade, für ungerade `k`
nur ungerade Werte an — das ist die π/4-Verschiebung und ergibt sich
automatisch, weil alle Inkremente ungerade sind [ETSI §5.4].

**Ressourcen:** 7 LUT, 14 FF, 0 DSP, 0 BRAM
[BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:184`]. Die reine
Modulrechnung ergäbe ~20 LUT / ~50 FF (3-bit-Phasenregister +
2 × 16-bit-Ausgang + Valid) — [ANNAHME]: gerechnet, nicht gemessen. Der
Reportwert liegt darunter — Ursache nicht nachgewiesen, plausibel ist
Registerverschiebung über die Modulgrenze durch Physopt. Für das Budget gilt in
jedem Fall die Reportzahl.

**V2-Bereinigung:** Die Parameter `PHASE_WIDTH` und `LUT_DEPTH` sind in V1
formal vorhanden und funktional unbenutzt (der Code nutzt fest 3 bit und
8 Einträge) [CODE …:50-52]. Sie entfallen. Portnamen werden
Clock-Domain-konform: `clk_sample`/`rst_n_sample` → `clk_sys`/`rst_n_sys`, denn
das Modul wird mit `clk_sys` instanziiert [CODE rtl/tx/tetra_tx_chain.v:156-157].

### 3.8 `tetra_rrc_filter` — RRC-Sendefilter mit Interpolation L = 4

**Normativ** [ETSI §5.5 Gl. 5.4, §5.6]: Die ideale Symbolform ist die inverse
Fouriertransformierte eines Wurzel-Kosinus-Spektrums mit **α = 0,35**. Das
Modulationsfilter ist linearphasig mit |H(f)| = G(f). Eine zeitbegrenzte,
gefensterte Version von g(t) ist ausdrücklich erlaubt.

**Realisierung:** 33 Koeffizienten, Q14 signed, symmetrisch (`h[k] = h[32−k]`),
Polyphasen-Zerlegung L = 4 mit Teilfilter `p` = `h[p], h[p+4], … ` (Phase 0:
9 Taps, Phasen 1–3: je 8 Taps + eine Null als Auffüllung)
[CODE rtl/tx/tetra_rrc_filter.v:86-121, 201-245]. Mittenkoeffizient
`h[16] = +8978` (= 0,548 in Q14). Die vollständige Koeffizientenliste steht
normativ in `02_PHY_DL_RX §3.3` (33 Taps, Q14 signed) und gilt **unverändert**
für dieses Sendefilter — es sind dieselben Koeffizienten wie im
RX-Matched-Filter, eine Quelle, ein Generator. Identisch sind
die **Koeffizienten**, nicht die Implementierung und nicht die DSP-Kosten
(siehe Hinweis unter der Tabelle).

**Ablauf:** Pro Eingangssymbol werden vier Ausgangswerte sequentiell erzeugt
(Phase 0 zuerst), 4 × 9 = 36 MAC-Zyklen. Das Symbolintervall hat
100 MHz / 18 kHz ≈ 5556 `clk_sys` — Auslastung < 1 %.

| Eigenschaft | Wert |
|---|---|
| Symbolschieberegister | 9 × 16 bit als flacher 144-bit-Bus, `[15:0]` = neuestes |
| Akkumulator | 38 bit signed (`IQ_WIDTH` 16 + `COEFF_WIDTH` 16 + `ceil(log2 9)` = 4 ⇒ 36, plus 2 bit Marge) [CODE rtl/tx/tetra_rrc_filter.v:80-81] |
| Ausgangsskalierung | `>>> 14`, dann Sättigung auf 16 bit |
| Gruppenlaufzeit | `(N−1)/(2L)` = 4 Symbolperioden |
| Latenz bis erster Ausgang | 10 `clk_sys` nach `sample_valid_in` |
| Ausgangsstrobes | 4 pro Symbol, bei 10/18/27/36 `clk_sys` |
| Ressourcen | 173 LUT, 208 FF, **4 DSP48E1**, 0 BRAM [BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:185`] |

**Zur DSP-Zahl (verbindliche Budget-Metrik):** Der V1-Modulkommentar an
der MAC-Stufe behauptet „synthesises to 1 DSP48E1" [CODE
rtl/tx/tetra_rrc_filter.v:258]; das Modul enthält aber **zwei** parallele
16×16-signed-Multiplizierer (I und Q gleichzeitig) [CODE …:260-261], und der
Post-Route-Report weist der Instanz 4 DSP48E1 zu — bestätigt durch den
Elterncontainer `u_tx_chain` mit ebenfalls 4 DSP und ohne weiteren
Multiplizierer [BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:181, 185`].
Die DSP-Zahl ist nicht aus dem RTL herleitbar: das strukturgleiche RX-Frontend
(CIC-Dezimator + Matched-Filter-MAC, ebenfalls zwei parallele Multiplizierer
[CODE rtl/rx/tetra_rx_frontend.v:700-701]) misst insgesamt 2 DSP
[BUILD 2026-06-20 `…cur_hier_deep.rpt:165`]. Für das DSP-Budget in `01` ist
deshalb die Reportzahl verbindlich, nicht die Kommentarschätzung: TX-Filter
4 DSP, RX-Frontend 2 DSP — die Wiederverwendung derselben
**Koeffizienten**-Quelle bedeutet nicht dieselben DSP-Kosten.

**Sättigung:** Überlauf, wenn die oberen `ACC_WIDTH − IQ_WIDTH + 1` Bits des
geschobenen Akkumulators nicht alle dem Vorzeichenbit entsprechen; dann Klemmen
auf `0x8000` bzw. `0x7FFF` [CODE rtl/tx/tetra_rrc_filter.v:315-329].
**V2-Anforderung:** Sättigungsereignisse zählen (`REG_TX_RRC_SAT_CNT`, sättigend,
AXI-lesbar, Adresse `07 §3.1.8`). Stiller Klipp im Sendepfad ist eine Spektralverletzung, die man
nicht am Protokoll sieht.

**Ausgangswert der letzten Tap-Stufe:** Der Ausgang übernimmt bewusst
`acc_next` (kombinatorische Summe inkl. des aktuellen Produkts) und nicht den
registrierten Akkumulator, sonst fehlte Tap 8 [CODE …:301-306]. Dieses Detail
ist in V2 im Modulheader zu dokumentieren, weil ein „Aufräumen" hin zum
registrierten Akkumulator einen 1-Tap-Fehler einführt, den kein CRC bemerkt.

### 3.9 `tetra_tx_frontend` — CDC und Interpolation auf die AD9361-Rate

#### 3.9.1 Aufbau

Zwei Blöcke: asynchrones FIFO (`clk_sys` → `clk_lvds`) und ein
CIC-Interpolator R = 64, N = 5, M = 1 im `clk_lvds`-Bereich.

| Eigenschaft | Wert |
|---|---|
| FIFO | XPM async, Tiefe 16, 32 bit `{i, q}`, `READ_MODE = "std"`, `FIFO_READ_LATENCY = 1`, `CDC_SYNC_STAGES = 2` |
| Zähler | `lvds_cnt[7:0]`, freilaufend 0..255 (256 / 18,432 MHz = 72 kHz) |
| FIFO-Lesepuls | `lvds_cnt == 254` |
| Comb-Update | `lvds_cnt == 255` (alle 5 Stufen gleichzeitig) |
| Integrator-Freigabe | `lvds_cnt[1:0] == 0` → 64 Schritte je Periode |
| Zero-Insertion | Comb-Ausgang wird nur bei `lvds_cnt == 0` eingespeist, sonst 0 |
| Akkumulatorbreite | 48 bit |
| Ausgangsskalierung | `>>> 24` (= R^(N−1) = 64⁴ = 2²⁴), dann Sättigung auf 16 bit |
| Ausgangsrate | 64 × 72 kHz = 4,608 MHz = `clk_lvds` / 4 |
| Ressourcen | 1085 LUT (davon 22 LUTRAM für das FIFO), 1620 FF, 0 DSP, 0 BRAM [BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:186`] |

Der V1-Modulkopf schätzt „LUT ~80 FF ~680" [CODE rtl/tx/tetra_tx_frontend.v:53];
der Report weist 1085 LUT und 1620 FF aus, also Faktor 13 bzw. 2,4. Die
Kopfschätzung ist nicht hergeleitet und wird nicht übernommen: verbindlich ist
die Reportzahl — dieses Modul ist der größte Einzelposten des Sendepfads
(1085 von 1803 LUT der `tetra_tx_chain`
[BUILD 2026-06-20 `…cur_hier_deep.rpt:181`]).

Die Comb-vor-Zero-Stuffing-Struktur (Hogenauer) macht die Combs
eingangsratengetaktet: 5 Differenzierer alle 256 `clk_lvds`, 5 Akkumulatoren
alle 4 `clk_lvds` [CODE rtl/tx/tetra_tx_frontend.v:196-396].

#### 3.9.2 Fluss-Randfälle — in V1 unspezifiziert

**Unterlauf.** Der V1-Kommentar behauptet „Underrun (FIFO empty): pass 0 to
prevent garbage in integrators" [CODE rtl/tx/tetra_tx_frontend.v:176-178], der
Code prüft `empty` aber nur beim Lesepuls [CODE …:170]; das Comb-Eingangs­
register übernimmt bei `lvds_cnt == 255` bedingungslos `fifo_dout`, das bei
unterdrücktem Lesen den **vorigen** Wert hält. Faktisches Verhalten:
Wiederholung des letzten Abtastwerts, nicht Nulleinspeisung.

**V2-Festlegung:** Wiederholung des letzten Abtastwerts ist das **gewollte**
Verhalten — eine Null im Sendepfad erzeugt einen Amplitudensprung und damit
Spektralsplatter, ein gehaltener Wert nur eine kurze Trägerkonstante. Der
Kommentar wird korrigiert, und ein Zähler `REG_TX_FIFO_UNF_CNT` (sättigend,
AXI-lesbar) macht das Ereignis sichtbar.

**Überlauf.** V1 schreibt mit `wr_en = sample_valid_in` ohne `full` auszuwerten
[CODE …:126-128]; ein voller FIFO verwirft still. **V2:** Zähler
`REG_TX_FIFO_OVF_CNT` (sättigend, AXI-lesbar). Bei exakt verkoppelten Raten
(72 kHz Schreiben, 72 kHz Lesen) darf keines der beiden Ereignisse auftreten;
ein Zählerstand ≠ 0 ist damit ein direkter Hinweis auf ein Taktproblem und
nicht auf einen Protokollfehler.

#### 3.9.3 CIC-Droop und dessen Kompensation

Die Übertragungsfunktion des Interpolators ist
`|sin(π·R·f/fs_out) / (R·sin(π·f/fs_out))|^N` mit R = 64, N = 5,
fs_out = 4,608 MHz. Am relevanten Bandrand (TETRA-Nutzbandbreite bei α = 0,35:
`18 kHz · 1,35 / 2 = 12,15 kHz`) ergibt die Rechnung **≈ −2,05 dB**
[ANNAHME — gerechnet, nicht gemessen; Herleitung: `π·f/fs_in = π·0,16875`,
`(0,50573 / 0,530138)⁵ = 0,7899`].

V1 kompensiert das nicht: es gab ein 7-Tap-Inverse-Sinc-Modul, das im
Datenpfad nie instanziiert war und inzwischen aus dem Repository entfernt
wurde (die IST-Doku führt es weiterhin mit 169 Zeilen —
`docs/ist/05_tx_datapath.md`, Abschnitt „tetra_tx_inv_sinc.v" — die Datei
existiert nicht; verifiziert per `find`).

**V2-Festlegung (R-04-18):** Die Kompensation wird **in die 33 RRC-Koeffizienten
eingerechnet** (Pre-Emphase im Generator: Ziel-Frequenzantwort =
Wurzel-Kosinus × inverse CIC-Antwort, anschließend erneut auf Q14 quantisiert).
Kosten: 0 LUT, 0 FF, 0 DSP — es ändern sich nur Konstanten. Randbedingung: die
Q14-Quantisierung nach der Pre-Emphase muss die Restwelligkeit über
±12,15 kHz auf ≤ 0,5 dB halten; der Koeffizienten-Generator prüft das und
schlägt sonst fehl. Ein separates Filtermodul ist **nicht** zulässig — es war
in V1 genau die Art Modul, das gebaut, nie verdrahtet und dann als „vorhanden"
dokumentiert wurde.

### 3.10 Symboltakt-Erzeugung und Takt-Domänen-Überquerung

```
clk_lvds (18,432 MHz)
  └─ 10-bit-Zähler 0..1023 ──▶ Toggle bei 1023
        └─ 2-FF-Synchronizer (ASYNC_REG) in clk_sys
              └─ Flankendetektor ──▶ sym_en_sys  (1 Zyklus, 18 000,000 Hz)
```
[CODE rtl/tetra_zynq_top.v:959-991]

18 432 000 / 1024 = 18 000,000 Hz — exakt, kein Restfehler, kein
Akkumulator-Jitter. `sym_en` ist damit die einzige Zeitreferenz des
Sendepfads; Zeitbasis und Builder hängen an derselben Kante.

**Warum Toggle und nicht Puls:** Ein 1-Zyklus-Puls aus 18,432 MHz wäre in
100 MHz zwar breit genug, aber die Toggle-Variante ist unabhängig vom
Frequenzverhältnis korrekt und übersteht eine spätere Änderung der LVDS-Rate.

**V2-Anforderung:** Ein Zähler `REG_TX_SYM_EN_CNT` (32 bit, freilaufend, AXI-lesbar, `07 §3.1.8`/`§3.1.9`)
erlaubt es, den Symboltakt von der PS-Seite gegen die Systemuhr zu prüfen
(erwartet: 18 000 Inkremente pro Sekunde ± Messfenster). Ohne diesen Zähler ist
ein stehender LVDS-Takt von einem stehenden Protokoll nicht zu unterscheiden.

**Zu entfernen (V1-Duplikat):** V1 hat neben `tetra_tdma_timebase` einen
zweiten, freilaufenden TDMA-Zähler im Top-Level
(`tx_sym_cnt_sys`, `tx_slot_cnt_sys`, `tx_frame_cnt_sys` als ETSI-1-basiert
1..18, `tx_mf_cnt_sys` 1..60) [CODE rtl/tetra_zynq_top.v:1013-1048].
Sein Slot-Puls `tx_slot_pulse_sys_w` wird zugewiesen und **von niemandem
gelesen** [CODE …:1054-1055, verifiziert per Grep]. Seine übrigen Ausgänge
speisen (a) das AXI-Statusregister `REG_TX_TDMA` [CODE …:2046-2048] und (b) den
Multiframe-Puls für den periodischen Broadcast [CODE …:2259-2260]. Das ist der
Zähler mit dem **falschen** Zeitbezug: er akzeptiert kein `TX_TDMA_LOAD` und
läuft damit gegenüber der Luft frei. Die Folge ist im SW-Code dokumentiert —
das Pacing der Fragmentkette musste von `REG_TX_TDMA` auf
`REG_TX_TDMA_STATE` umgestellt werden, weil FN18 über den freilaufenden Zähler
unsichtbar war und ein Fragment dort verloren ging
[CODE sw/tetra_attach_daemon.c:800-804]. **V2: ein Zähler (R-04-01), ein
Statusregister, ein Multiframe-Puls — alle aus `tetra_tdma_timebase`.**

### 3.11 Einheitliche Bit-Order- und Ausrichtungsregel

**Regel R (verbindlich für dieses Kapitel und für `05`/`06`):**

> Auf **jedem** Bus, der Modulations- oder Kanalcodierungs-Bits trägt, liegt das
> **zuerst gesendete Bit im MSB**. Für einen Bus `x[W-1:0]` gilt:
> `x[W-1]` = Bit 1 des ETSI-Feldes, `x[0]` = Bit W.
> Ein Bus, der ein kürzeres Feld trägt, ist **MSB-ausgerichtet**; die unteren,
> ungenutzten Bits sind 0.

Damit gilt einheitlich: `bb[29]` = bb(1); `sb1[119]` = sb(1);
`block1[215]` = bkn1(1); `burst_sreg[509:508]` = das aktuelle Dibit;
`aach_coded[29]` = erstes On-Air-Bit [CODE rtl/tx/tetra_aach_rm_encoder.v:31];
`sb1_coded[119]` = erstes On-Air-Bit [CODE rtl/tx/tetra_sb1_encoder.v:68].

**Der V1-Fall, den diese Regel ausschließt.** Der 432-bit-`coded`-Bus der
Warteschlange wird vom Scheduler MSB-orientiert gelesen —
`blk1 = head_coded[431:216]`, `blk2 = head_coded[215:0]`
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:165-172]. Es gibt zwei Produzenten,
die einen 216-bit-SCH/HD-Block einspeisen, und sie tun es **gegensätzlich**:

| Produzent | Zuweisung | Ausrichtung | Ergebnis in BKN1 |
|---|---|---|---|
| `tetra_pre_reply_slotgrant` | `{lat_coded_schhd, 216'd0}` [CODE …slotgrant.v:334] | MSB | die codierten 216 bit — **korrekt** |
| `tetra_pre_reply_blck` | `{216'd0, lat_coded_blk1}` [CODE …blck.v:209] | LSB | 216 Nullbits — **CRC-Fehler beim MS** |

Zusätzlich behauptet der Header der Warteschlange selbst die LSB-Konvention
(„SCH/HD LSB-aligned in [215:0]")
[CODE rtl/lmac/tetra_dl_signal_queue.v:17] und widerspricht damit dem
Scheduler, der denselben Bus liest. Drei Stellen, zwei Konventionen, eine davon
sendet garantiert Nullen. Der zweite Produzent ist live verdrahtet und feuert
auf jedem abgeschlossenen mm=2/mm=7-Reassembly
[CODE rtl/tetra_zynq_top.v — Instanz `u_pre_reply_blck`, `trigger_valid` an
`reass_valid_sys & …`], der Attach funktioniert trotzdem, weil das MS den
defekten Burst schlicht verwirft.

**V2-Umsetzung der Regel, mechanisch prüfbar:**

1. Der Bus heißt `coded_msb_aligned[431:0]`. Der Name trägt die Konvention.
2. Ein Zusatzfeld `coded_len[8:0]` (Anzahl gültiger Bits, 216 oder 432)
   begleitet jeden Eintrag. Der Consumer prüft `coded_len` gegen `pdu_type`
   und inkrementiert bei Widerspruch `QUEUE_LEN_MISMATCH`.
3. Jeder Produzent hat einen Testbench-Fall, der nach dem Push
   `head_coded[431:216] != 0` verifiziert. Ein Produzent ohne diesen Fall gilt
   als nicht abgenommen.

### 3.12 Diagnose-Sendemodus

Ein Registerbit (`TX_TEST[0]`, Reset 0) ersetzt den Dibit-Strom des Builders
durch eine PRBS aus einem 15-bit-LFSR `x¹⁵ + x¹⁴ + 1`, getaktet mit
`tx_dibit_valid`; Periode 32767 Symbole ≈ 1,82 s
[CODE rtl/tx/tetra_tx_chain.v:132-146]. Zweck: Spektrum-, Leistungs- und
Nachbarkanalmessung ohne Protokoll. Der Bursttyp und die Trainingssequenzen
werden dabei **mit** überschrieben — der Modus ist ausdrücklich nicht
empfangbar und darf im Betrieb nicht gesetzt sein. **V2-Anforderung:** Solange
das Bit gesetzt ist, wird ein Statusbit `TX_TEST_ACTIVE` gespiegelt, damit die
Bedienoberfläche den Zustand anzeigen kann und niemand eine Stunde lang nach
einer verschwundenen Zelle sucht.

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---|---|---|
| `sym_en`-Teiler | 1024 (18,432 MHz → 18 000,000 Hz) | [CODE rtl/tetra_zynq_top.v:952-970] | Jeder andere Teiler ergibt eine nicht-ganzzahlige Symbolrate → Drift gegen das MS-Zeitraster, Slotgrenzen wandern |
| Burst-Länge | 255 Symbole, d = 0, kein Guard | [ETSI §9.4.4.1 Tab. 9.2] | Bei Guard ≠ 0 bricht der Träger zwischen Slots ab → MS verliert Sync |
| RRC-Taps / α | 33 / 0,35, Q14 | [ETSI §5.5 Gl. 5.4] + [CODE rtl/tx/tetra_rrc_filter.v:89-121] | Anderes α verletzt die Nachbarkanaldämpfung |
| `RRC_ACC_SHIFT` | 14 | [CODE …rrc_filter.v:62] | Zu klein → Dauersättigung; zu groß → Aussteuerungsverlust, MER sinkt |
| CIC R / N / Shift | 64 / 5 / 24 | [CODE rtl/tx/tetra_tx_frontend.v:62-65] | Shift ≠ 24 passt nicht zu R^(N−1) = 2²⁴ → Über- oder Unteraussteuerung des DAC |
| CIC-Akkumulator | 48 bit | [CODE …tx_frontend.v:65] | Zu schmal → Wrap im Integrator = harte Spektralstörung |
| CDC-FIFO-Tiefe | 16 | [CODE …tx_frontend.v:109] | Reicht bei exakt verkoppelten Raten; kleiner = Unterlaufrisiko beim Anlauf |
| Queue-Tiefe | 4 | [CODE rtl/lmac/tetra_dl_signal_queue.v:65] | Ausgelegt für 2 parallele MS-Registrierungen + Reserve; kleiner → Verwürfe bei zwei gleichzeitigen Attaches |
| Queue-Priorität | MLE > CMCE > SDS | [CODE …queue.v:163-164] | Andere Reihenfolge lässt Registrierungs-Antworten hinter Broadcasts warten → Attach-Timeout |
| Überlauf-Strategie | drop-newest | [CODE …queue.v:201,340] | drop-oldest verwirft bereits fällige Antworten → Handshake bricht reihum |
| Abstand Vorantwort → Antwort **im Referenznetz** | 8 Burst-Positionen = 2 TDMA-Frames = 113,3 ms | [GOLD `dl_full.md` Burst #775 → #783, Δ = 114 ms, gleicher TS1] | **Messwert, kein V2-Sollwert:** in V2 folgt die Antwort ereignisgetriggert (R-04-21, `08 §3.5.2`). Zu früh gebaut (Zusammensetzung noch nicht fertig) → ACCEPT fällt auf Profil-Default zurück (LI = 12 statt LI = 21); zu spät → MS läuft in seinen Wiederholungs-Timer |
| Reassembly-T0 | **9 TDMA-Frames** | normativ `08 §3.5.2`; `T.202` = 9 DL-Signalisierungsframes [ETSI Annex B.1] | T0 ist eine obere **Verwurfsschranke**, kein Warteschritt — die Antwort hängt nicht an seinem Ablauf (R-04-21). Kürzer: die BS verwirft die Kette, während das MS noch Fortsetzungen sendet (`08 §3.5.3`) |
| BSCH-Platzierung | `FN18 ∧ (MN+TN) mod 4 = 3` | [ETSI §9.5.2 Gl. 9.17] + [GOLD: 26/26 SB-Bursts auf TS1 liegen auf FN18 mit MN mod 4 = 2, d. h. (2+1) mod 4 = 3 ✓] | Falsche Multiframe-Phase: normgerechte MS suchen den BSCH-Anker an der Tabellenposition |
| Zeitplan-Preset TS1 | NDB2 (NULL-PDU + Broadcast-Begleiter) außer auf dem BSCH-Anker | [GOLD: TS1 = 1785 × NDB2, 26 × SB, 23 × NDB1] | Ein SB auf jedem TS1-Slot verschwendet den MCCH |
| Zeitplan-Preset TS2..TS4 | SB | [GOLD: TS3 1836 × SB, TS4 1834 × SB, TS2 1475 × SB + 359 × NDB (Verkehr)] | — |
| Phasenanpassungs-Dibits | inhaltsabhängig, nie `00` | [GOLD: `hc` ∈ {01,10}, `hd` ∈ {01,11} über 5171 SB-Bursts] | Statisch `00` verletzt [ETSI §9.4.4.3.6]; differentielle Empfänger merken es nicht, entzerrende schon |
| Gesamt-Design V1 | LUT 37 567 (70,6 %), FF 50 744 (47,7 %), BRAM 15,5 Tiles (10 × RAMB36 + 11 × RAMB18), DSP 38 | [BUILD 2026-07-12 `build/reports/impl_utilization.rpt`] | Referenzpunkt für das V2-Budget (`01`) |
| WNS V1 auf `clk_sys` | **+0,006 ns** bei 100 MHz | [BUILD 2026-07-12 `build/reports/impl_timing.rpt:139`] | V1 hat 6 ps Reserve. Jede neue kombinatorische Stufe im Sendepfad kippt das Timing — deshalb §3.6.5 (Phasenanpassung) als Pipeline mit eigenem Register, nicht als kombinatorische Summe |
| `tetra_slot_schedule` | 31 LUT, 1 FF, 2 RAMB18 | [BUILD 2026-05-18 `impl_hier_util.rpt:92`] | Ohne Bank-Split: ~4900 LUT + ~4600 FF (Vivado Synth 8-4767) |
| `tetra_burst_dispatcher` | 193 LUT, 586 FF | [BUILD 2026-05-18 `impl_hier_util.rpt:73`] | — |
| `tetra_rrc_filter` | 173 LUT, 208 FF, **4 DSP48E1** | [BUILD 2026-06-20 `cur_hier_deep.rpt:185`] | Der Modulkommentar nennt 1 DSP; wer nach ihm budgetiert, unterschätzt jede Filterinstanz um 3 DSP (§3.8) |
| `tetra_tx_frontend` | 1085 LUT (22 LUTRAM), 1620 FF, 0 DSP | [BUILD 2026-06-20 `cur_hier_deep.rpt:186`] | Größter Einzelposten des Sendepfads; die Kopfschätzung ~80 LUT / ~680 FF ist um Faktor 13 bzw. 2,4 zu klein (§3.9.1) |
| `tetra_pi4dqpsk_mod` | 7 LUT, 14 FF | [BUILD 2026-06-20 `cur_hier_deep.rpt:184`] | Post-Route/Physopt-Wert, liegt unter der Modulrechnung ~20/~50 (§3.7.3) |

**Hinweis zu den Hierarchie-Zahlen:** Vivado ordnet in
`-hierarchical`-Reports absorbierte Logik des Elternmoduls den Kindern zu.
Für `tetra_tdma_timebase` (1853 LUT) und `tetra_slot_content_mux` (3043 LUT)
sind die Werte deshalb **nicht** als Modulkosten lesbar — sichtbar auch daran,
dass der jüngere Report derselben Instanz 346 LUT zuweist
[BUILD 2026-06-20 `cur_hier_deep.rpt:188`]. Verbindlich sind die Gesamtsummen
und, wo der Report plausibel ist (Schedule-BRAM, Dispatcher, RRC, TX-Frontend,
Modulator), die Modulzeile. Jede Zeile trägt ihr Reportdatum, weil die Zahlen
zwischen Builds schwanken: Dispatcher 193 LUT (2026-05-18) gegen 201 LUT
[BUILD 2026-06-20 `cur_hier_deep.rpt:136`], Schedule 31 gegen 25 LUT
[BUILD 2026-06-20 `…:187`]. Für ein Budget ist deshalb die Größenordnung
verbindlich, nicht die letzte Stelle — außer bei BRAM und DSP, die ganzzahlig
und stabil sind.

---

## 5. Verifikation

### 5.1 Unit-Testbenches (Pflicht, self-checking)

| Testbench | Kernprüfungen |
|---|---|
| `tb_tetra_pi4dqpsk_mod` | Alle 4 Dibits × 8 Startphasen aus **unabhängig** gerechneten Vektoren (nicht aus dem Demodulator!); Konstellationswerte; 1-Zyklus-Latenz; Reset |
| `tb_tetra_rrc_filter` | Alle 4 Polyphasen gegen Referenzvektoren; Impulsantwort = Koeffizientenfolge; Sättigungsklemme bei Volllast-Eingang; Strobe-Positionen 10/18/27/36 |
| `tb_tetra_tx_frontend` | Ausgangsrate 64 Pulse je 256 `clk_lvds`; CIC-Gleichanteilsverstärkung nach `>>>24` = 1; Unterlauf (FIFO leer) → letzter Wert gehalten + Zähler; Überlauf → Zähler; Sättigung |
| `tb_tetra_burst_builder` | Bit-für-Bit-Vergleich des 510-bit-Registers gegen die Tabellen 9.7 und 9.9; NTS1/NTS2-Auswahl über `ndb2`; lückenlose Verkettung (kein `tx_busy`-Einbruch über 3 Bursts); **Phasenbalance**: Summe der Phaseninkremente über die Bereiche aus Tabelle 9.15 ist nach dem Anpassungssymbol 0 mod 2π; `first_dibit` genau bei `sym_cnt == 0` |
| `tb_tetra_tdma_timebase` | Reset-Werte; `sym_cnt`-Wrap; alle vier Wrap-Ebenen inkl. `mn 59→0` und `hn 63→0`; Sync-Load im laufenden Slot; Sync-Load koinzident mit `sym_en`; kein `tdma_tick` beim Load; `tdma_tick` führt `slot_pulse` um genau 1 Zyklus |
| `tb_tetra_slot_schedule` | Port-A-Schreiben/Lesen inkl. `wstrb`-Halbwortgranularität; Port-B-Latenz genau 1 Zyklus; Bank-Auswahl über Adress-LSB; **Referenzeintrag aus ETSI Gl. 9.16/9.17 gerechnet**, nicht aus dem Generator kopiert |
| `tb_tetra_slot_prefetch` | Trigger bei `tn == 3`; Einmal-Trigger nach Reset lädt den *aktuellen* Frame; Folgeframe-Wraps `fn 17→0` mit `mn`-Fortschaltung; alle 4 Einträge nach 5 Zyklen ab Trigger gelatcht (§3.3.3), `sched_entry_reg3` bereits in `S_RD3` |
| `tb_tetra_burst_dispatcher` | Alle **vier** Auswahlprioritäten je `tn` einschließlich der Stehl-Ausnahme (Rang 2 vor Rang 1 bei `head_pdu_class = 01₂ ∧ head_target_tn = tn ∧ persist_valid[tn]`, `steal_override_cnt` +1); Grant-Override gewinnt gegen alles und setzt `pop_sys = 0`; `enable = 0` nullt Body, lässt `bb` durch; FN18-Gate blockt den Persist-Override bei `fn == 17`; `content_sys` trifft je Pfad den Wert aus der Tabelle in §3.4 (gegen `06 §3.8.2` geprüft); `build_req` genau 1 Zyklus |
| `tb_tetra_dl_signal_queue` | Reset; Einfügen/Popen; Füllen auf 4 und 5. Einfügung verworfen (drop-newest) mit **Aggregat- und Produzenten-Zähler +1**; Prioritätsreihenfolge über alle 6 Paarungen; Gleichstand → kleinerer Index; Pop und Schreiben im selben Zyklus; Sättigung der Zähler; `depth_count` |
| `tb_tetra_dl_signal_scheduler` | Kombinatorischer Fan-out für alle 4 `target_tn`; Leerlauf → NULL-PDU + Begleiter + `ndb2 = 1`; Pop nur auf dem Zielslot; SCH/F vs. SCH/HD-Routing von `blk2` |
| `tb_tx_alignment` (neu) | Für **jeden** Queue-Produzenten: Push → `head_coded[431:216] != 0`; `coded_len` konsistent mit `pdu_type` |

### 5.2 Ende-zu-Ende-Simulation

Ein Testfall treibt die vollständige Kette
Zeitplan → Dispatcher → Builder → Modulator → RRC → CIC und demoduliert die
IQ-Folge mit dem **unabhängigen** Python-Referenzdemodulator. Akzeptanz:

- Die 19 STS-Dibits eines SB-Bursts werden bitgenau wiedergewonnen.
- Die 11 NTS1- bzw. NTS2-Dibits eines NDB-Bursts werden bitgenau
  wiedergewonnen.
- Die Trainingssequenz-Korrelation liegt ≥ 0,95 (Gold-Referenz erreicht 0,988
  bis 0,999, Median 0,994 [GOLD `docs/reference_decode/dl_events.jsonl`,
  Feld `corr` über alle 7338 Bursts; 189 Bursts liegen unter 0,992, 168 über
  0,998]).
- BER über 4 verkettete Bursts = 0 (rauschfrei).

### 5.3 Gold-Vergleich (strukturell, nicht bit-identisch)

Aus einer eigenen Aufzeichnung wird ein Burst-Inventar erzeugt und gegen die
Referenz verglichen. Verbindliche Kriterien:

| Kriterium | Zielwert | Gold-Referenzwert |
|---|---|---|
| Bursttyp-Verteilung TS1 | überwiegend NDB2 | 1785 NDB2 / 26 SB / 23 NDB1 |
| Bursttyp TS3, TS4 | SB | 1836 / 1834 SB |
| SB-Burst auf TS1 | nur `FN18 ∧ MN mod 4 = 2` | 26/26 erfüllt |
| `q1..q10` am Burstende | Dibits `2,3,1,3,0` | 5171/5171 |
| STS in SB | ETSI-y-Folge | 5171/5171 |
| Phasenanpassungs-Dibits | ≠ `00`, inhaltsabhängig | `hc` ∈ {01,10}, `hd` ∈ {01,11} |
| Vorantwort → Antwort | gleicher Zeitschlitz, Abstand ≥ 1 Frame und ereignisgetriggert — **kein** fester Sollabstand (R-04-21, `08 §3.5.2`) | Burst #775 → #783 = 8 Burst-Positionen / 2 Frames |

Zell- und MS-spezifische Felder (SSI, GSSI, Carrier, MCC/MNC, Colour Code, LA,
Scrambler, Call-Identifier) **dürfen und müssen** abweichen.

### 5.4 Luft-Abnahme

1. Ein normgerechter Fremdempfänger rastet auf die Zelle ein und dekodiert
   SYSINFO mit korrektem MCC/MNC/Colour Code. Das ist der Test, den die
   vertauschte Phasenzuordnung in V1 nicht bestanden hätte, während der eigene
   Decoder grün war.
2. Zwei MS buchen sich ein; `REG_DL_QUEUE_STATS` und der Aggregat-Verwurfszähler
   bleiben 0.
3. `REG_TX_SYM_EN_CNT` steigt über 10 s um 180 000 ± Messfenster.
4. `REG_TX_FIFO_UNF_CNT`, `REG_TX_FIFO_OVF_CNT`, `REG_TX_RRC_SAT_CNT`,
   `REG_TX_PADJ_UNBAL_CNT`, `REG_TX_BUILD_REQ_MISS_CNT` bleiben nach 10 Minuten
   Dauerbetrieb 0. Alle fünf und `REG_TX_SYM_EN_CNT` sind in `07 §3.1.8` mit
   eigener Adresse geführt; die Namen dieses Kapitels sind die aus `07`.
5. Vorantwort- und Antwort-Burst liegen in der eigenen DL-Aufzeichnung auf
   **demselben** Zeitschlitz, die Antwort im ersten passenden Slot nach ihrer
   Einstellung — der Abstand wird in Frames protokolliert, aber **nicht** gegen
   einen Sollwert geprüft (R-04-21). Abnahmekriterium ist stattdessen der Inhalt:
   die ACCEPT trägt LI = 21, und `REASS_INCOMPLETE_AT_REPLY_CNT` (`08 §3.5.2`)
   bleibt 0. Mindestens 3 Wiederholungen des Attach-Vorgangs.

---

## 6. Offene Punkte

1. **O-04-1 — Phasenanpassungs-Bits: Berechnungszeitpunkt.** §3.6.5 fordert die
   Berechnung. Offen ist, ob sie im Builder während des Schiebens des
   Vorgängerbursts läuft (billig, aber sie muss vor dem ersten Symbol fertig
   sein) oder im Dispatcher als Teil der Auswahlstufe (mehr kombinatorische
   Tiefe, bei WNS = +6 ps riskant). **Empfehlung:** im Builder, als
   3-bit-Akkumulator über die 510 bereits gelatchten Bits, mit eigenem
   Ausgangsregister. Entscheidung nach einem Synthese-Probelauf des isolierten
   Blocks gegen die 100-MHz-Vorgabe.

2. **O-04-2 — Multiframe-Phase des BSCH-Ankers.** Das V1-Preset setzt den SB-Eintrag auf
   TS1 bei RTL-`mn mod 4 == 2` [CODE scripts/schedule.py:312], was ETSI
   `MN mod 4 == 3` entspricht, während ETSI Gl. 9.17 und die Referenz
   `MN mod 4 == 2` verlangen — der Anker liegt eine Multiframe daneben. Die
   Testbench spiegelt denselben Wert [CODE tb/tb_tx_slot_schedule.v:277] und
   bestätigt den Fehler statt ihn zu finden. **Empfehlung:** Generator und
   Testbench rechnen unabhängig `(MN + TN) mod 4` aus dem ETSI-Ausdruck; der
   Vergleich der beiden Rechnungen ist der Test. Vor dem Umbau ist per
   Luft-Capture zu prüfen, ob ein MS die V1-Platzierung nur deshalb toleriert,
   weil TS2..TS4 in jedem Frame einen SB senden.

3. **O-04-3 — Ableitung von „hier liegt eine echte PDU" aus dem Inhalt.** V1 bildet das
   Signal, das die AACH-Auswahl steuert, als 216-bit-Vergleich
   `sched_blk1_tn{k} != null_pdu_bits`
   [CODE rtl/tetra_zynq_top.v:2491-2494]. Das sind vier 216-bit-Komparatoren und
   es bricht, sobald eine echte PDU zufällig gleich der NULL-PDU ist.
   **Empfehlung:** ein explizites 4-bit-Flag aus dem Scheduler
   (`sched_content_real[3:0]`), das die Auswahl direkt treibt. Die
   Wechselwirkung mit der AACH-Vorausschau ist in `06` zu spezifizieren; hier
   ist nur festgehalten, dass die Inhaltsvergleich-Variante entfällt.

4. **O-04-4 — Idle-Burst-Erzeugung bei fehlendem `build_req`.** §3.6.6 fordert einen
   autonomen Idle-Burst. Offen: Woher kommt dessen BKN1 — aus dem
   NULL-PDU-Register (SW muss es gesetzt haben) oder aus einer RTL-Konstante
   (funktioniert auch vor dem ersten SW-Schreibzugriff, kostet aber 124 bit
   Konstante plus einen Encoder-Durchlauf)? **Empfehlung:** NULL-PDU-Register
   mit einem Reset-Wert, der einen gültigen SCH/HD-Block ergibt; der Wert wird
   vom Koeffizienten-/Konstanten-Generator erzeugt und als Reset-Wert der
   NULL-PDU-Bank in `07_PS_PL_CONTRACT §3.5` dokumentiert — dort, wo alle
   Reset-Werte stehen.

5. **O-04-5 — Reserve-Bits des Zeitplan-Eintrags.** `[1:0]` sind nach dem Entfall von
   `sys_time_inject` frei. Kandidaten für eine echte Bedeutung: „AACH-Muster
   dieses Slots aus einer Nebentabelle" oder „Slot ist für Verkehr reserviert,
   Signalisierung darf ihn nicht anfassen". **Empfehlung:** vorläufig
   reserviert und auf 0 geprüft lassen; eine Bedeutung erst festlegen, wenn ein
   konkreter Bedarf aus `06`/`10` vorliegt — V1 zeigt, was ein benanntes, aber
   nie gelesenes Bit anrichtet.

6. **O-04-6 — Zeitplan-Tiefe über 4 Multiframes hinaus.** Die 288-Einträge-Tabelle
   deckt `mn mod 4` ab, weil alle heute genutzten ETSI-Downlink-Regeln Periode 4
   haben. Funktionen mit längerer Periode (z. B. Broadcast-Kadenzen über
   10 Multiframes) laufen deshalb an der Tabelle vorbei über SW-Zähler.
   **Empfehlung:** so belassen (eine Tabelle über 60 Multiframes wären
   4320 Einträge = 8,6 kByte und 5 BRAM) und periodische Ereignisse > 4 MF
   ausdrücklich als SW-getriggert spezifizieren, nicht als Zeitplan-Eintrag.

7. **O-04-7 — Zwei Reset-Konventionen im Sendepfad.** Die bestehenden Module verwenden
   asynchron deassertierte Resets (`negedge rst_n`), CONVENTIONS.md fordert
   synchrone Deassertion über einen 2-FF-Synchronizer, und die
   BRAM-Templates dürfen **keinen** Reset auf dem Leseregister haben.
   **Empfehlung:** ein zentraler Reset-Synchronizer je Clock-Domain in `01`;
   im Sendepfad nur noch `posedge clk` + synchrones `if (!rst_n_sync)`, mit
   der BRAM-Ausnahme explizit im Modulheader benannt. Das ist bei
   WNS = +6 ps kein kosmetischer Punkt: die Reset-Struktur bestimmt die
   Control-Set-Zahl und damit das Packing.
