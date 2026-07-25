# 07 — Die PS↔PL-Schnittstelle (normative Quelle)

**Scope:** Der vollständige Vertrag zwischen ARM-Software (PS) und FPGA-Logik (PL):
Adressraum und Seiten-Aufteilung, jedes Register mit Adresse, Breite, Zugriffsart,
Rücksetzwert, Bedeutung und Nebenwirkung; **ein** einheitliches Mailbox-Handshake-Muster
und daraus abgeleitet jede Mailbox mit Richtung, Wortbelegung, Bit-Order und
Ablaufprotokoll; die Regeln für Taktbereichsübergänge am Registerinterface; Zähler und
Diagnosewerte; Unterbrechungsbehandlung.

**Dieses Kapitel ist die einzige normative Quelle für Registeradressen, Mailbox-Wortbelegungen
und Rücksetzwerte im gesamten Dokumentensatz.** Andere Kapitel verweisen mit Registernamen
und wiederholen keine Adressen (`CONVENTIONS.md §4`, P2).

**Nicht hier:**
- Algorithmen hinter den Registern → `02_PHY_DL_RX`, `03_PHY_UL_RX`, `04_PHY_TX_TDMA`,
  `05_CHANNEL_CODING`, `06_MAC`.
- Protokoll-Semantik der transportierten PDUs (AACH-Werte je Rufphase, MAC-Felder,
  LLC/MLE/MM/CMCE) → `06_MAC`, `09`–`12`.
- Slot-Deadlines, Antwortfenster, die Auswertung der Air-Lock-Messwerte → `08_TIMING`.
- Takt- und Reset-Architektur, CDC-Grundmuster P1–P5 → `01_PLATFORM §3.1, §3.5`.
- Prozess-/Thread-Modell der Software, HAL-Implementierung → `13_SW_ARCHITECTURE`.

**Abhängigkeiten:** `00_OVERVIEW` (Architektur-Schnitt §3, Prinzipien §4),
`01_PLATFORM` (§3.1 Ein-Domänen-Entscheidung, §3.5 CDC-Muster),
`04_PHY_TX_TDMA` (§3.3 Zeitplan-Eintrag, §3.5 Sende-Warteschlange, §3.11 Bit-Order-Regel R),
`03_PHY_UL_RX` (§3.6.4 Soft-Ablage und Bit-Order der UL-Softwerte).

---

## 1. Anforderungen

| ID | Anforderung | Abnahmekriterium |
|---|---|---|
| **R-07-01** | Der Adressraum ist in **Seiten** von 4 KiB gegliedert. Jede Seite hat einen eigenen Dekoder, der ausschließlich auf `A[15:12]` freigegeben wird; innerhalb einer Seite wird ausschließlich `A[11:2]` ausgewertet. Zwei Fenster teilen **nie** dieselben Dekodierbits. | Netzlisten-Review: kein Vergleich auf einen Wortindex, der nicht mit dem vollen Seitenfeld qualifiziert ist. Testbench: Zugriff auf jede Seite mit identischem `A[11:2]` liefert vier verschiedene Register. |
| **R-07-02** | Jeder Zugriff ist 32 bit breit und wortaligniert. `WSTRB != 4'hF` bei einem Schreibzugriff führt zu **keiner** Registeränderung und inkrementiert `REG_ACCESS_ERR_CNT`. Partielle Byte-Aktualisierung existiert nicht. | Testbench: Schreibzugriff mit `WSTRB = 4'h3` ändert kein Register, Zähler +1, `BRESP = OKAY`. |
| **R-07-03** | Ein Zugriff auf eine nicht belegte Adresse liefert lesend `0x0000_0000`, verwirft schreibend, antwortet mit `BRESP/RRESP = OKAY` und inkrementiert `REG_ACCESS_ERR_CNT`. Der Bus hängt unter keinem Zugriffsmuster. | Testbench: Zugriffe auf alle 16 Seiten, auch die unbelegten; jede Transaktion wird abgeschlossen. |
| **R-07-04** | **Ein Register ohne Verbraucher existiert nicht.** Jedes lesbare Bit hat eine Quelle im PL, jedes schreibbare Bit hat mindestens einen Konsumenten im PL oder in der Software. Kein Statusbit ist konstant verdrahtet. | Build-Gate: Liste aller Registerbits gegen die Netzliste; ein Bit mit konstantem Treiber oder ohne Senke ist ein Build-Fehler (vgl. `01_PLATFORM` R-01-08). |
| **R-07-05** | Es existiert **genau ein** Mailbox-Handshake-Muster (§3.2), instanziiert in zwei Richtungsvarianten. Jede Mailbox besteht aus denselben vier Registern `*_INDEX`, `*_DATA`, `*_TRIGGER`, `*_STATUS` mit identischer Semantik. | Review: jede Mailbox in §3.3–§3.5 ist auf dieses Muster abbildbar; kein Sonderfall im Ablaufprotokoll. |
| **R-07-06** | Jede Mailbox hat einen sättigenden **Verwurfszähler**. Ein verworfener Transfer ist im Betrieb zählbar; stilles Überschreiben ist verboten. | Testbench: PL-Push bei belegten Puffern → Inhalt unverändert, Zähler +1. |
| **R-07-07** | Nach Downlink überträgt die Software **fertig kanalcodierte** PDU-Bits samt Routing- und AACH-Metadaten. Das PL enthält keinen Kanalcodierer für Nutzdaten (`00_OVERVIEW §3.3`, P1). | Netzliste: kein CRC-/RCPC-/Interleaver-/Scrambler-Block im DL-Nutzdatenpfad des PL außer BSCH- und AACH-Encoder (`00 §3.2` Punkt 4). |
| **R-07-08** | Aus dem Uplink überträgt das PL **Soft-Bursts** vor jeder Decodierung. Es exportiert keine geparsten Protokollfelder. | Register-Map enthält kein UL-Feldregister (kein `addr_type`, kein `mm_pdu_type`, kein reassemblierter Body). |
| **R-07-09** | **Zeitstempel-Pflicht (R-00-04):** Jeder Uplink-Burst trägt im **selben** Transfer den TDMA-Zeitstempel des Uplink-Slots, dem er gehört. Die Software rechnet keinen Slot-, Frame- oder Multiframe-Bezug selbst. | Testbench: Für jeden gepushten Burst ist `W1` gegen die Zeitbasis am Sync-Anker prüfbar. Air: die Software führt keine eigene TDMA-Uhr (Codereview). |
| **R-07-10** | Die Uplink-Zuweisung und die Mehrslot-Reservierung werden vollständig im PL erzeugt. Die Software setzt ausschließlich **Musterparameter** (§3.1.6); es existiert **kein** Register, mit dem die Software ein einzelnes Zuweisungsereignis auslöst (R-00-01 … R-00-03). | Register-Map enthält kein Einzelschuss-Grant-Register. Testbench: bei stillstehender Software erteilt das PL nach einem erkannten UL-Burst weiterhin Zuweisungen. |
| **R-07-11** | Die Zuweisungsentscheidung des PL hängt **nicht** vom Inhalt des empfangenen Bursts ab (R-00-02). Zulässige Eingänge: Sync-Ereignis, Position im Zeitraster, Konfigurationsregister. | Netzliste: der Zuweisungsblock hat keinen Eingang aus einem Decoder- oder Parser-Pfad. |
| **R-07-12** | Die Air-Lock-Differenz wird **atomar im PL** beim Uplink-Ereignis berechnet und als fertiger Wert bereitgestellt. Die Software rechnet keine Differenz aus zwei separat gelesenen Zählerständen. | Testbench: bei simulierten Ereignissen ist `REG_AIRLOCK_DELTA_CYC` exakt die Zykluszahl zwischen Anker und UL-Ereignis, unabhängig vom Lesezeitpunkt. |
| **R-07-13** | Die Registerbank liegt in `clk_sys` (100 MHz) und hat **keine** Synchronisierer zu der übrigen `clk_sys`-Logik. Domänenüberschreitungen existieren nur gegen `clk_lvds` und nur über die Muster aus `01_PLATFORM §3.5`. | `grep ASYNC_REG` über die Registerbank liefert 0 Treffer; `report_cdc` weist für die Bank 0 Endpunkte aus. |
| **R-07-14** | Es gibt **keine** Interrupt-Leitung zum PS. Der Vertrag ist ein Abfrage-Vertrag mit spezifizierten Fristen (§3.8). | Block-Design hat keinen `IRQ_F2P`-Anschluss aus unserem PL; §3.8 nennt für jede Mailbox eine Frist und deren Herleitung. |
| **R-07-15** | Jeder Wert breiter als 1 bit, der vom PL zur Software geht, ist **kohärent**: er stammt aus einem einzigen Registerlesevorgang oder aus einem Transfer, dessen Konsistenz durch das Mailbox-Handshake garantiert ist. Zusammensetzen eines logischen Werts aus zwei Registerlesevorgängen ist verboten. | Review der Register-Map: kein logischer Wert über zwei Adressen verteilt, außer den ausdrücklich als unabhängig gekennzeichneten Zählern. |
| **R-07-16** | Alle Zähler sind **sättigend** (kein Überlauf auf 0) und werden ausschließlich über `REG_CTRL.CNT_CLEAR` gemeinsam zurückgesetzt. Ausnahme: die ausdrücklich als **freilaufend** gekennzeichneten Zähler in §3.1.2, §3.1.7 und §3.1.8; sie sind in §3.1.9 abschließend aufgelistet. | Testbench: Zähler bei Maximalwert bleibt stehen; `CNT_CLEAR` setzt alle sättigenden Zähler auf 0 und lässt genau die in §3.1.9 gelisteten unberührt. Die Testtabelle wird aus derselben Quelle erzeugt wie die Dekodierkonstanten (R-07-17). |
| **R-07-17** | Die Registernamen der Software (`sw/tetra_hal.h`) und die Dekodierkonstanten des PL werden aus **einer** maschinenlesbaren Quelle erzeugt. Eine handgepflegte zweite Liste ist verboten. | Build-Gate: der Generator läuft, `git diff` auf den erzeugten Dateien ist leer. |
| **R-07-18** | Kein Zugriff auf die PL-Apertur vor `fpga0/state == operating` (`01_PLATFORM` R-01-17). Die Registerbank ist nach Reset in einem Zustand, in dem das PL **nicht sendet**. | Boot-Log-Reihenfolge; `REG_CTRL` Rücksetzwert = 0. |
| **R-07-19** | Jeder Rücksetzwert in §3 ist so gewählt, dass ein Boot **ohne** Software-Initialisierung keinen luftschädlichen Zustand erzeugt: kein Senden, keine Zuweisung, Schwellwerte im gemessenen Arbeitspunkt. | Testbench: nach Reset ohne jeden AXI-Zugriff ist `tx_en = 0` und `ul_assign_enable = 0`. |
| **R-07-20** | Die Software greift ausschließlich über die HAL-Schicht auf Register zu (`CONVENTIONS.md §4`). Ein `devmem`- oder Zeigerzugriff außerhalb der HAL ist ein Spec-Verstoß. | `grep` über `sw/` nach direkten Apertur-Zugriffen außerhalb der HAL ohne Treffer. |

---

## 2. Architektur / Aufbau

### 2.1 Was über die Schnittstelle fließt

Der Architektur-Schnitt (`00_OVERVIEW §3`) legt fest, dass die Kanalcodierung für
DL-Nutzdaten und die gesamte UL-Auswertung in der Software liegen. Damit trägt die
PS↔PL-Schnittstelle in V2 genau fünf Arten von Verkehr:

| Richtung | Inhalt | Träger |
|---|---|---|
| PS → PL | **Fertig codierte DL-PDUs** (432 oder 216 type-5-Bits) plus Zielslot, AACH-Infowort, Betriebsart, Verzögerung | DL-PDU-Mailbox, Seite 1 |
| PS → PL | **Fertig codierte statische Sendeinhalte** (Broadcast-Begleitblöcke, Leerlauf-PDU, MCCH-Inhalt) | TX-Payload-Bänke, Seite 3 |
| PS → PL | **Quasistatische Konfiguration** (Zellparameter, Schwellwerte, Zuweisungsmuster, Slot-AACH-Muster, Zeitplan) | Seite 0 und Seite 4 |
| PL → PS | **UL-Soft-Bursts mit TDMA-Zeitstempel**, uninterpretiert | UL-Burst-Mailbox, Seite 2 |
| PL → PS | **Status, Zähler, Messwerte** | Seite 0 |

Was **nicht** mehr fließt, verglichen mit V1: keine unkodierten PDU-Bodies nach unten
(P1: wer den Body baut, codiert ihn), keine geparsten UL-Felder nach oben, kein
reassemblierter UL-Body, keine Teilnehmer- oder Profildaten, keine DMA-Blockzähler.

### 2.2 Adressraum (verbindlich)

**Apertur:** Basis `0x43C0_0000`, Länge 64 KiB, zugewiesen im Block-Design
[CODE scripts/create_bd.tcl:559–563]. Dekodiert werden **alle** 16 Adressbits.

```
A[15:12] = Seite        A[11:2] = Wortindex innerhalb der Seite      A[1:0] = 0 (Pflicht)
```

| Seite | Bereich | Inhalt | belegte Byte-Offsets in der Seite |
|---|---|---|---|
| `0x0` | `0x0000`–`0x0FFF` | Steuerung, Status, Konfiguration, Zähler, Messwerte (§3.1) | `0x000`–`0x194` |
| `0x1` | `0x1000`–`0x1FFF` | DL-PDU-Mailbox, PS→PL (§3.3) | `0x000`–`0x00C` |
| `0x2` | `0x2000`–`0x2FFF` | UL-Burst-Mailbox, PL→PS (§3.4) | `0x000`–`0x00C` |
| `0x3` | `0x3000`–`0x3FFF` | TX-Payload-Bänke, PS→PL (§3.5) | `0x000`–`0x00C` |
| `0x4` | `0x4000`–`0x4FFF` | Slot-Zeitplan, 144 Wörter direkt adressiert (§3.6) | `0x000`–`0x23C` |
| `0x5`–`0xF` | `0x5000`–`0xFFFF` | unbelegt — Verhalten nach R-07-03 | — |

**Warum Seiten und nicht ein flacher Bereich.** In V1 dekodieren zwei Registerbänke über
**dieselben** Adressbits `A[8:2]` und werden nur durch die höheren Bits auseinandergehalten:
Bank 0 über `wr_addr[10:9] == 2'b00` [CODE rtl/infra/tetra_axi_lite_regs.v:936], Bank 1 über
`wr_addr[10:8] == 3'b010` [CODE …:945], leseseitig über einen nachgeschalteten
Override-Block `if (rd_addr[10:9] == 2'b01)`, der das Ergebnis des ersten `case` verwirft
[CODE …:1288–1331]. Beide `case`-Statements laufen über `A[8:2]`; jede Konstante existiert
damit doppelt. Konkretes Beispiel aus dem Bestand: `7'h17` ist gleichzeitig
`REG_DBG_SYNC_UL` (Bank 0, `0x5C`, RO) [CODE …:657] und `REG_UL_DEMAND_BODY_ACK`
(Bank 1, `0x25C`, W1S) [CODE …:878]. Die IST-Doku benennt das Risiko selbst
[CODE docs/ist/08_axi_regmap.md:349–353]. Die Seitenstruktur macht diese Klasse von Fehlern
**strukturell unmöglich**: es gibt keinen Dekodierpfad, in dem zwei Fenster um dieselben
Bits konkurrieren, und keinen Override, der ein Ergebnis nachträglich ersetzt.

**Zweiter V1-Befund, den die Seitenstruktur beseitigt:** V1 dekodiert nur `A[10:0]`
[CODE rtl/infra/tetra_axi_lite_regs.v:973, :1052], die Apertur ist aber 64 KiB. Die
gesamte Registerdatei erscheint dadurch 32-fach gespiegelt; `0x43C0_0800` trifft
`REG_CTRL`. In V2 ist jede nicht belegte Adresse ein gezählter Fehlzugriff (R-07-03).

**Dritter V1-Befund:** `sw/tetra_hal.h` definiert `REG_SB_COMMIT` auf `0x5C` mit dem
Kommentar „write any value → atomic shadow→live commit" [CODE sw/tetra_hal.h:68]. Im PL
existiert dieses Register nicht — `0x5C` ist der **lesende** UL-Sync-Diagnosewert
[CODE rtl/infra/tetra_axi_lite_regs.v:657, :1133]. Die Software schreibt es nie (kein
Treffer in `sw/*.c`), der Diagnosewert wird von niemandem gelesen. V2 löst das doppelt:
die Commit-Funktion existiert wirklich (§3.5), und Namen entstehen generiert aus einer
Quelle (R-07-17).

### 2.3 Aus V1 entfallene Fenster (mit Befund)

Jede Zeile ist ein Fenster, das V1 dekodiert, das aber keinen Verbraucher hat oder durch
den V2-Schnitt entfällt. R-07-04 verbietet die Übernahme.

| V1-Fenster | Adresse V1 | Befund | Beleg |
|---|---|---|---|
| Teilnehmer-Schattenspeicher (`REG_SHADOW_INDEX/DATA_LO/DATA_HI/CTRL`) | `0x180`–`0x18C` | Dekodiert und gelatcht, die Ausgänge enden im Top-Level an keinem Verbraucher und werden von der Synthese entfernt | [CODE rtl/infra/tetra_axi_lite_regs.v:787–790], [CODE rtl/tetra_zynq_top.v:444–453] |
| Profiltabelle (`REG_PROFILE_INDEX/DATA/DATA_RD/CTRL`) | `0x1C0`–`0x1CC` | Wie oben; `REG_PROFILE_DATA_RD` liefert konstant 0, weil der Leseport im Top auf 0 gebunden ist | [CODE rtl/infra/tetra_axi_lite_regs.v:835–845], [CODE rtl/tetra_zynq_top.v:458] |
| Zähler der entfernten Datentransfer-Einheit (`REG_DMA_BLK_CNT`) | `0x2C` | Quelle im Top konstant 0; kein Software-Leser | [CODE rtl/infra/tetra_axi_lite_regs.v:641], [CODE rtl/tetra_zynq_top.v:941] |
| Wirkungsloses Umschaltbit (`REG_REPLY_USE_SW`) | `0x230` | R/W-Bit, Rücksetzwert 1; der zugehörige Multiplexer wurde entfernt, das Bit endet in einer Lint-Senke | [CODE rtl/infra/tetra_axi_lite_regs.v:2633–2639], [CODE rtl/tetra_zynq_top.v:3262–3265] |
| Interrupt-Register (`REG_IRQ_ENABLE`, `REG_IRQ_STATUS`) | `0x24`, `0x28` | Drei der fünf Quellen konstant 0; `irq_enable` nach Reset 0 und von der Software nie geschrieben; die Software fragt ab | [CODE rtl/infra/tetra_axi_lite_regs.v:1612, 2651–2656], [CODE sw/tetra_hal.h:41] |
| Pegelregister ohne Wirkung (`REG_RX_GAIN`, `REG_TX_ATT`) | `0x1C`, `0x20` | Reine Scratch-Register; der HF-Pegel läuft über AD9361-sysfs | [CODE rtl/infra/tetra_axi_lite_regs.v:1596, 1604], `01_PLATFORM §2.2` |
| Geparste UL-Felder (`REG_UL_PDU_STATUS`, `_SSI`, `_RAW_0..2`, `_CTRL`, `_STATUS_2`) | `0x164`–`0x178`, `0x1B4` | Widerspricht R-07-08: das PL parst keine Nutzdaten mehr | [CODE rtl/infra/tetra_axi_lite_regs.v:778–784, 820] |
| UL-Reassembly-Fenster (`REG_REASSEMBLY_T0`, `_STATS`, `REG_UL_DEMAND_BODY_*`, `REG_LSDS_READ_*`) | `0x1DC`, `0x1E0`, `0x250`–`0x25C`, `0x298`–`0x29C` | Fragment-Zusammensetzung liegt in V2 in der Software (`00_OVERVIEW §3.3` Punkt 2) | [CODE rtl/infra/tetra_axi_lite_regs.v:824–825, 875–878, 912–913] |
| UL-Scrambler-Startwert (`REG_UL_SCRAMB_INIT`) | `0x17C` | Descrambling liegt in der Software; das PL braucht den Startwert nicht mehr | [CODE rtl/infra/tetra_axi_lite_regs.v:784] |
| Einzelschuss-Zuweisung (`REG_AACH_GRANT_HINT`) | `0x1F4` | Verstößt gegen R-00-01/R-07-10: die Software löst hier ein einzelnes Zuweisungsereignis aus | [CODE rtl/infra/tetra_axi_lite_regs.v:827], [CODE rtl/tx/tetra_aach_encoder.v:60–70] |
| Von der Software vorcodierte BSCH-/AACH-Bits (`REG_SB_SB1_0..3`, `REG_SB_BB`) | `0x40`–`0x4C`, `0x7C` | BSCH- und AACH-Encoder bleiben im PL (`00 §3.2` Punkt 4), beziehen ihren Inhalt aber nicht mehr vorcodiert aus Registern: BSCH aus `REG_CELL_CFG_*`, AACH aus den Zustandsgrößen in `REG_SLOT_STATE_TSn`/`REG_AACH_ACCESS_CFG` über `tetra_aach_info` (§3.1.5, `06_MAC §3.8.2`) | [CODE rtl/infra/tetra_axi_lite_regs.v:649–652, 667] |
| Bedeutungs-Mehrfachbelegung (`REG_VOICE_ACTIVE_MASK`) | `0x1EC` | Ein Register trägt drei unabhängige Bedeutungen: `[3:0]` aktive Sprachslots, `[7:4]` aktive Füllslots, `[8]` Fragment-Ende-Marker. In V2 sind das Felder der DL-PDU-Metadaten (§3.3) | [CODE rtl/tetra_zynq_top.v:3879, 3892, 3906] |
| Verwurfszähler unter fremdem Namen (`REG_MLE_STATS_A/B/C`) | `0x190`–`0x198` | Der Verwurfszähler der Sende-Warteschlange steckt im oberen Halbwort eines Registers namens `clear_cnt` in `MLE_STATS_C` | [CODE rtl/infra/tetra_axi_lite_regs.v:795–797, 1232], `04_PHY_TX_TDMA §3.5.1` |

Zwei V1-Fenster werden **funktional übernommen**, aber umbenannt und neu platziert: die
vier Zuweisungskanal-Register je Zeitschlitz (§3.1.5) und die vier Air-Lock-Messregister
(§3.1.7). Beide sind in der V1-Registerdokumentation nicht oder falsch geführt — genau der
Doku-Drift, den V2 nicht wiederholt.

**Ein weiteres V1-Fenster geht in der DL-PDU-Mailbox auf** und entfällt deshalb als eigenes
Fenster: die D-NWRK-BROADCAST-Push-Mailbox `REG_NWRK_BCAST_INDEX/DATA/TRIGGER`
`0x1D0`–`0x1D8` (W1S mit Hardware-Löschung, Zähler `0x1E4`, Auslöseperiode `0x1E8`)
[CODE rtl/infra/tetra_axi_lite_regs.v:848–850], von der Software mit 14 Wörtern bedient
[CODE sw/tetra_hal.c:1542–1547] und im Top verdrahtet [CODE rtl/tetra_zynq_top.v:2197–2202].
Sie ist der **einzige** V1-Pfad, der schon heute 432 fertig codierte Bits über ein einziges
Index/Daten-Fenster schiebt, und damit die Vorlage für §3.3: dieselbe Wortzahl, dieselbe
Ausrichtungsregel, nur ohne eigenes Fenster und ohne eigenen Erzeugerpfad im PL. Ein
periodischer Broadcast ist in V2 `mode = PERSIST_SET` auf dem Zielslot (§3.3), kein
Sonderfenster (P3).

### 2.4 AXI4-Lite-Slave-Verhalten

| Eigenschaft | Festlegung |
|---|---|
| Protokoll | AXI4-Lite, 32 bit Daten, 16 bit Adresse |
| `AWPROT` / `ARPROT` | angenommen, ignoriert (keine Schutzstufen) |
| `AWREADY` / `WREADY` | kombinatorisch `!latched`, wie V1 [CODE rtl/infra/tetra_axi_lite_regs.v:920–921] |
| Schreib-Freigabe | ein 1-Takt-Puls, wenn Adresse und Daten gelatcht sind und keine Antwort aussteht [CODE …:927] |
| `BRESP` / `RRESP` | **immer** `OKAY`. Fehlzugriffe werden gezählt, nicht als Busfehler gemeldet — ein `SLVERR` würde auf dem ARM einen Datenabbruch erzeugen und damit die Diagnose eines Adressfehlers schwerer machen als einen Zählerstand. [ANNAHME: bewusste Festlegung; V1 verhält sich gleich, ohne Zähler [CODE …:1015–1022]] |
| Lese-Latenz | **2 `clk_sys`** ab `ar_en`: Zyklus 1 Seiten-Multiplexer, Zyklus 2 Ausgangsregister. Gilt einheitlich für alle Seiten, auch für die BRAM-gestützte Zeitplan-Seite. |
| Warum einheitlich 2 Takte | V1 hat für die Registerbank 1 Takt und für das Zeitplanfenster 2 Takte und braucht dafür einen Sonderpfad mit eigenem Pending-Register, der den `ar_en`-Puls unterdrücken muss [CODE …:1033, 1349–1383]. Zwei Latenzen im selben Slave sind eine Fehlerquelle ohne Gegenwert: 10 ns pro Zugriff sind gegen die Software-Zugriffszeit irrelevant. |
| Schreib-Latenz | Wirkung im Zyklus der Schreib-Freigabe; `BVALID` im Folgetakt. |
| Gleichzeitiger Lese- und Schreibzugriff | zulässig, unabhängige Kanäle, keine Verriegelung. Ein Lesevorgang auf dasselbe Register wie ein gleichzeitiger Schreibvorgang liefert den **alten** Wert. |
| Ausstehende Transaktionen | eine pro Richtung (kein Pipelining). |
| Lesen ist nebenwirkungsfrei | **verbindlich.** Kein Register wird durch Lesen verändert, kein Index automatisch weitergestellt. Begründung in §3.2. |

---

## 3. Detail-Spezifikation

Notation der Tabellen: `RW` = lesen/schreiben, `RO` = nur lesen (Schreibzugriff verworfen,
`REG_ACCESS_ERR_CNT` **nicht** inkrementiert — die Adresse ist belegt), `WO` = nur schreiben
(liest 0), `W1S` = Schreiben einer 1 setzt, Hardware löscht. Alle Adressen sind Byte-Offsets
zur Apertur-Basis. Nicht genannte Bits sind reserviert, lesen als 0 und müssen als 0
geschrieben werden.

### 3.1 Seite 0 — Steuerung, Status, Konfiguration

#### 3.1.1 Identität und Steuerung

| Adresse | Name | Zugriff | Reset | Bedeutung / Nebenwirkung |
|---|---|---|---|---|
| `0x0000` | `REG_ID` | RO | `0x54455432` | Kennung `"TET2"` in ASCII, MSB = `T`. Erster Lesevorgang der Software; weicht der Wert ab, ist der Bitstream nicht der erwartete → Abbruch der Inbetriebnahme (`01_PLATFORM §3.8`). |
| `0x0004` | `REG_VERSION` | RO | Build-abhängig | `[31:24]` Major, `[23:16]` Minor, `[15:0]` Build-Zähler. Die Software prüft Major gegen ihren Erwartungswert und bricht bei Abweichung ab. V1 hat hier eine feste Konstante `0x0001_0000` ohne jeden Abgleich [CODE rtl/infra/tetra_axi_lite_regs.v:1116]. |
| `0x0008` | `REG_CTRL` | RW | `0x0000_0000` | `[0]` `RX_EN`, `[1]` `TX_EN`, `[2]` `LOOPBACK_EN` (digitaler Rückschluss, `01_PLATFORM §3.6`), `[3]` `CNT_CLEAR` — **selbstlöschend**, erzeugt einen 1-Takt-Puls, der alle sättigenden Zähler auf 0 setzt (R-07-16); liest immer 0. `[4]` `TX_TEST_PRBS_EN` (`04_PHY_TX_TDMA §3.12`). **Nebenwirkung:** `TX_EN` wird im PL mit `lvds_in_range` UND-verknüpft; ohne gültige Taktmessung sendet das Board nicht (`01_PLATFORM §3.4`). |
| `0x000C` | `REG_STATUS` | RO | — | `[0]` `DL_SYNC_LOCKED`, `[1]` `LVDS_ALIVE`, `[2]` `LVDS_IN_RANGE`, `[3]` `TX_GATE_OPEN` (= `TX_EN ∧ LVDS_IN_RANGE`), `[4]` `TDMA_RUNNING` (Symboltakt in den letzten 100 ms gezählt), `[5]` `DL_MB_FULL`, `[6]` `UL_MB_VALID`. Jedes Bit hat eine reale Quelle (R-07-04). V1 verdrahtet `PLL_LOCKED` konstant auf 1 [CODE rtl/tetra_zynq_top.v:2040]. |
| `0x0010` | `REG_SCRATCH` | RW | `0x0000_0000` | Freies 32-bit-Register. Einziger Zweck: Bus-Selbsttest bei der Inbetriebnahme (Schreiben/Rücklesen von `0xA5A5_5A5A`). |
| `0x0014` | `REG_ACCESS_ERR_CNT` | RO | `0` | Sättigend 32 bit. Inkrementiert bei Zugriff auf eine unbelegte Adresse (R-07-03) und bei `WSTRB != 4'hF` (R-07-02). Ein von 0 verschiedener Wert im Betrieb bedeutet einen Software-Adressfehler. |

#### 3.1.2 Zeitbasis

| Adresse | Name | Zugriff | Reset | Bedeutung / Nebenwirkung |
|---|---|---|---|---|
| `0x0020` | `REG_TDMA_STATE` | RO | — | Momentanwert der Zeitbasis, kohärent in **einem** Lesevorgang (R-07-15): `[1:0]` `tn` (0…3), `[6:2]` `fn` (0…17), `[12:7]` `mn` (0…59), `[18:13]` `hn` (0…63), `[26:19]` `sym_cnt` (0…254). Alle Felder **0-basiert** (RTL-Zählweise). Umrechnung: `TS(ETSI) = tn+1`, `FN(ETSI) = fn+1`, `MN(ETSI) = mn+1` [ETSI §9.3.4, §9.3.5, §9.3.7]; sie geschieht ausschließlich im zentralen Mapping-Modul (`04_PHY_TX_TDMA §3.2.3`). |
| `0x0024` | `REG_TDMA_LOAD` | WO | — | Gleiche Feldlage wie `REG_TDMA_STATE` für `[18:0]`, zusätzlich `[31]` `STROBE`. **Nebenwirkung:** Ein Schreibzugriff mit `[31] = 1` legt `tn/fn/mn/hn` in ein Schattenregister und setzt die Übernahme auf die nächste Symbolflanke (`04_PHY_TX_TDMA §3.1`); dabei wird `sym_cnt = 0` gesetzt und **kein** Slot-Strobe erzeugt. Werte außerhalb der Bereiche (`fn > 17`, `mn > 59`) werden **verworfen** und inkrementieren `REG_TDMA_LOAD_REJ_CNT` — V1 übernimmt sie und läuft aus dem Wrap-Schema. |
| `0x0028` | `REG_TDMA_LOAD_REJ_CNT` | RO | `0` | Sättigend 16 bit in `[15:0]`. Verworfene Ladeversuche nach obiger Regel. |
| `0x002C` | `REG_SYM_TICK_CNT` | RO | — | `[17:0]` Anzahl Symboltakt-Pulse im letzten abgeschlossenen 100-ms-Fenster. Erwartungswert **1800** (18 000 Hz × 0,1 s). Watchdog gegen stehenden `clk_lvds`, gefordert in `04_PHY_TX_TDMA §3.1`. Freilaufend, von `CNT_CLEAR` unberührt. |
| `0x0030` | `REG_LVDS_FREQ_MEAS` | RO | — | `[23:0]` `clk_lvds`-Zählerstand des letzten 100-ms-Fensters. Erwartungswert **1 843 200 ± 9 216** (±0,5 %) (`01_PLATFORM §3.4`). |
| `0x0034` | `REG_SLOT_CNT` | RO | — | Freilaufender 32-bit-Zähler der Slot-Strobes. Dient der Software als monotone Zeitachse für Protokollierung; wrappt nach 2³² Slots (≈ 704 Tage). Von `CNT_CLEAR` unberührt. |

#### 3.1.3 Zell-Konfiguration

Diese Register speisen die im PL verbleibenden Encoder für Broadcast-Synchronisation und
Zugriffszuweisung (`00_OVERVIEW §3.2` Punkt 4). Sie sind **quasistatisch**: die Software
schreibt sie einmal beim Hochlauf und danach nur bei einer Konfigurationsänderung.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x0040` | `REG_CELL_CFG_0` | RW | `0x0000_0003` | **Kopffelder der SYNC-PDU** [ETSI §21.4.4.2 Tabelle 21.76]: `[3:0]` `system_code`, `[5:4]` `sharing_mode`, `[8:6]` `ts_reserved_frames`, `[9]` `u_plane_dtx`, `[10]` `frame_18_extension`. **Felder des TM-SDU** der SYNC-PDU, also des D-MLE-SYNC [ETSI §18.4.2.1 Tabelle 18.17]: `[12:11]` `neighbour_cell_broadcast`, `[14:13]` `cell_load_ca`, `[15]` `late_entry_support`. Der ETSI-Bezeichner des 2-bit-Felds `[14:13]` ist **„Cell load CA"** und wird nach `CONVENTIONS.md §8` im Original geführt; „cell service level" gehört zu D-MLE-SYSINFO und wäre hier falsch. Reset `system_code = 3` = „EN 300 392-2 V3.x". |
| `0x0044` | `REG_CELL_CFG_1` | RW | `0x0000_0000` | `[9:0]` `mcc`, `[23:10]` `mnc` [ETSI §18.4.2.1 Tabelle 18.17]. Zusammen mit `colour_code` bilden diese beiden Felder den **erweiterten Farbcode** `e(1)…e(30)` und damit den Startwert der Verschleierungsfolge für AACH und alle zellcodierten Kanäle [ETSI §8.2.5.2 i. V. m. Klausel 19]. **Ausgenommen ist die BSCH:** dort sind nach [ETSI §8.2.5.2] alle Bits `e(1)…e(30)` gleich 0, der Startwert ist fest `0x0000_0003` und von MCC/MNC/Farbcode unabhängig (`05_CHANNEL_CODING §3.8.4`; [GOLD `docs/reference_decode/dl_full.md:27` — „SB1 type-4 descrambled (BSCH init=3)" gegen „type-4 descrambled (XOR scramb=`0x4183f207`)" für NDB1, ebd. `:18347`]). Wer diese Register in die BSCH-Verschleierung einspeist, macht die BSCH für jedes Endgerät unlesbar. |
| `0x0048` | `REG_CELL_CFG_2` | RW | `0x0000_0041` | `[5:0]` `colour_code` (Reset 1) [ETSI §21.4.4.2 Tabelle 21.76], `[19:6]` `location_area` (Reset 1). Beide Werte müssen mit dem übereinstimmen, was die Software in die Systeminformation packt; die Prüfung dieser Übereinstimmung ist Abnahmekriterium von `09_LLC_MLE_MM`. |

**Nebenwirkung aller drei Register:** Eine Änderung wirkt auf den **nächsten** Encoderlauf,
nicht auf den bereits laufenden. Da ein BSCH-Encoderlauf ~142 `clk_sys` dauert
(`04_PHY_TX_TDMA §3.2.4`) und ein Slot 1 416 700 `clk_sys`, ist ein Zerreißen praktisch
ausgeschlossen; ein atomarer Übernahmemechanismus ist deshalb nicht vorgesehen. [ANNAHME:
Rechnung aus den Zykluszahlen, nicht gemessen.]

#### 3.1.4 Empfangs-Konfiguration und Pegel

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x0060` | `REG_RX_SYNC_CFG_DL` | RW | `0x0004_0D0A` | `[4:0]` `thresh_nts` (0…11), `[12:8]` `thresh_sts` (0…19), `[18:16]` `seq_enable` (`[0]` NTS1, `[1]` NTS2, `[2]` STS). Reset: NTS 10, STS 13, nur STS freigegeben. Werte und Wirkung: `02_PHY_DL_RX §3.7`. Ein Wert **größer als die Sequenzlänge** wird abgewiesen: das Register behält den alten Wert und `REG_ACCESS_ERR_CNT` inkrementiert (`01_PLATFORM` R-01-23). |
| `0x0064` | `REG_RX_SYNC_CFG_UL` | RW | `0x0000_0B0F` | `[4:0]` `thresh_cb` (0…15, x-Sequenz), `[12:8]` `thresh_nub` (0…11, NTS1). Reset **15** bzw. **11** — die gemessenen Optima (§4). Gleiche Abweisungsregel wie oben. **Getrennt** von der DL-Schwelle: das ist Anforderung R-03-04, weil V1 mit einem geteilten Register das gemessene UL-Optimum 15 nicht einstellen konnte, ohne die DL-Schwelle mitzuverschieben. |
| `0x0068` | `REG_RX_IQ_PEAK` | RO | — | `[15:0]` `max \|I\|`, `[31:16]` `max \|Q\|` über das letzte 100-ms-Fenster, **16 bit unsigned über den vollen Sample-Bereich**. V1 bildet den Betrag nur aus den unteren 13 bit und ist oberhalb 8 191 bedeutungslos (`03_PHY_UL_RX §5.4`). |
| `0x006C` | `REG_RX_IQ_SAT_CNT` | RO | `0` | Sättigend 32 bit: Samples mit `\|fe\| ≥ 32 512` im Fenster. Ohne diesen Wert ist der Arbeitspunkt des Soft-Quantisierers nicht prüfbar (`03_PHY_UL_RX §5.4`). |
| `0x0070` | `REG_RX_SYNC_STAT_DL` | RO | — | `[15:0]` `sync_cnt` sättigend, `[20:16]` `corr_peak`, `[22:21]` `sync_kind` (0 = NTS1, 1 = NTS2, 2 = STS), `[23]` `locked`. |
| `0x0074` | `REG_RX_SYNC_STAT_UL_CB` | RO | — | `[15:0]` `sync_cnt`, `[20:16]` `corr_peak`, `[22:21]` `best_phase`. |
| `0x0078` | `REG_RX_SYNC_STAT_UL_NUB` | RO | — | Gleiche Feldlage wie `…_UL_CB`. |
| `0x007C` | `REG_RX_CAPTURE_CNT` | RO | `0` | `[15:0]` erfasste CB-Bursts, `[31:16]` erfasste NUB-Bursts, je sättigend. Erfüllt R-03-11. |
| `0x0080` | `REG_RX_SYNC_DROP_CNT` | RO | `0` | `[15:0]` verworfene CB-Sync-Ereignisse (Sync während laufender Erfassung), `[31:16]` dasselbe für NUB. |

**Warum drei Sync-Statusregister statt eines gepackten Worts:** V1 packt
`{best_phase, corr_peak, sync_cnt}` in ein Wort, legt dieses Wort aber auf eine Adresse, die
in der Software-HAL einen anderen Namen trägt, und liest es nie (§2.2). Die
UL-Sync-Diagnose war damit praktisch nicht vorhanden, und die Schwellwert-Optima mussten
über Luftversuche gefunden werden (`03_PHY_UL_RX §5.6`).

#### 3.1.5 Zustandsgrößen des Zuweisungskanals je Zeitschlitz

V1 hat hier vier Register mit dem **fertigen 14-bit-Infowort** je Zeitschlitz
(`0x2A0`–`0x2AC` [CODE sw/tetra_hal.h:343–346], PL-Seite
[CODE rtl/infra/tetra_axi_lite_regs.v:892–895]; in der V1-Registerdokumentation fehlen sie —
die Doku-Drift, die `CONVENTIONS.md §3` als Nachweis führt). **V2 übernimmt diese Register
nicht.** `06_MAC` R-06-04/R-06-05 verbieten sie ausdrücklich: das Infowort wird aus der
Inhaltsentscheidung **desselben** Slots berechnet (`tetra_aach_info`, `06_MAC §3.8.2`), und
die Software liefert nur *Zustandsgrößen*. Ein slotübergreifend haltbares Software-Muster war
in V1 die Ursache dafür, dass der AACH-Inhalt nicht zum gesendeten Burst passte
(`06_MAC §3.8`). Diese Adressen tragen deshalb in V2 die Zustandsgrößen aus
`06_MAC §3.12`.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x00A0` | `REG_SLOT_STATE_TS1` | RW | `0x0000_0000` | Zustand des Verkehrsschlitzes **ETSI TS1** (= RTL-Slotindex `tn = 0`): `[5:0]` `SLOT_UMT` — Nutzungsmarkierung, 0 = unbelegt; `[7:6]` `SLOT_UL_STATE` — `00` unbelegt, `01` Verkehr, `10` assigned-Zugriff, `11` reserviert. `[31:8]` reserviert, 0. |
| `0x00A4` | `REG_SLOT_STATE_TS2` | RW | `0x0000_0000` | dito für ETSI TS2 (`tn = 1`) |
| `0x00A8` | `REG_SLOT_STATE_TS3` | RW | `0x0000_0000` | dito für ETSI TS3 (`tn = 2`) |
| `0x00AC` | `REG_SLOT_STATE_TS4` | RW | `0x0000_0000` | dito für ETSI TS4 (`tn = 3`) |
| `0x00B0` | `REG_SIGNAL_TARGET_TS` | RW | `0x0000_0001` | `[2:0]` ETSI-Zeitschlitz 1…4, auf dem Signalisierungs-PDUs ohne eigenes Ziel landen. Wert 0 oder > 4 wird abgewiesen (`REG_ACCESS_ERR_CNT` +1). Reset 1 = TS1. |
| `0x00B8` | `REG_AACH_ACCESS_CFG` | RW | `0x0000_00C9` | Zugriffsparameter des Kontrollkanals, ebenfalls reine Zustandsgrößen: `[5:0]` `ACCESS_FIELD` — Zugriffsfeld für Zufallszugriff, Reset `001001₂` = Code A, 8 Unterschlitze [GOLD, `06_MAC §4`]; `[6]` `F18_CLCH_ALL` — Reset 1, CLCH in allen Frame-18-Nicht-Kontrollkanal-Slots anbieten [GOLD]; `[9:7]` `MCCH_TN` — Kontrollkanal-Zeitschlitz in **ETSI-Zählung 1…4**, Reset 1 = TS1, Umrechnung nach `tn` ausschließlich im zentralen Mapping-Modul (`04_PHY_TX_TDMA §3.2.3`). Wert 0 oder > 4 wird abgewiesen (`REG_ACCESS_ERR_CNT` +1). `[31:10]` reserviert, 0. |

**`0x00B4` bleibt unbelegt — es gibt kein Abstandsregister.** Die Adresse zwischen
`REG_SIGNAL_TARGET_TS` und `REG_AACH_ACCESS_CFG` ist **absichtlich nicht** belegt; ein
Zugriff darauf ist ein gezählter Fehlzugriff nach R-07-03. Ein Register für einen festen
Abstand zwischen Vorantwort und Anmeldebestätigung existiert **nicht** und darf nicht
ergänzt werden: die substanzielle Antwort ist ereignisgetriggert und frame-granular
(`08` R-08-11, `08 §3.5.2`, `04_PHY_TX_TDMA` R-04-21), und ein fester Slot- oder
Frame-Abstand als Ersatz für dieses Ereignis ist dort ausdrücklich verboten. Ein solches
Register hätte damit **keinen Verbraucher** und wäre nach R-07-04 unzulässig. Die Lücke im
Adressraum bleibt bewusst stehen — die folgenden Adressen sind **nicht** nachgezogen, damit
keine Adresse dieses Kapitels zwei Bedeutungen trägt.

**Wo das Infowort steht.** Das 14-bit-Infowort selbst ist in diesem Kapitel **nicht**
festgelegt: Bit-Layout und Header-Bedeutung stehen in `06_MAC §3.8.1`
[ETSI §21.4.7.2 Tabelle 21.82], die abschließende Ableitungstabelle
Zustandsgrößen + Inhaltsklasse → Infowort in `06_MAC §3.8.2`, die Liste der erzeugbaren
Muster in `06_MAC §3.8.3` (R-06-06). Es gibt keine Vorrangordnung mehr, die hier zu
beschreiben wäre: es existiert genau **eine** Quelle des Infoworts, und das ist
`tetra_aach_info`. Die 14 bit sind type-1-Bits; das PL codiert sie mit dem verkürzten
RM(30,14)-Code zu 30 type-2-Bits und verschleiert sie zu `bb(1…30)`
[ETSI §8.3.1.1, Gl. 8.43/8.44] — das ist neben BSCH der einzige Kanalcodierer in Hardware
(`05_CHANNEL_CODING` R-05-02).

#### 3.1.6 Uplink-Zuweisung und Reservierung

Dies ist die Registerseite der wichtigsten Einzelentscheidung der Spezifikation
(`00_OVERVIEW §3.4`). Die Regeln R-00-01 bis R-00-03 werden hier so umgesetzt, dass ein
Verstoß nicht möglich ist, weil **kein Register existiert, mit dem die Software ein
einzelnes Zuweisungsereignis auslösen könnte**.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x00C0` | `REG_UL_ASSIGN_CFG` | RW | `0x0008_2044` | Steuergrößen des Zuweisungsblocks, Bedeutung und Vorgabewerte in `06_MAC §3.12`: `[0]` `GRANT_EN` — Gesamtfreigabe, Reset **0**: ohne Software-Initialisierung erteilt das PL keine Zuweisung (R-07-19). `[3:1]` `GRANT_REPEAT` — maximale Aussendungen je Auslösung, 1…7, Reset 2. `[9:4]` `GRANT_GAP` — Sperrzeit in TDMA-Frames nach Fensterende, Reset 4. `[16:10]` `GRANT_HOLD_MAX` — Deckel der Reservierungsdauer in Slots, Reset 8. `[20:17]` `GRANT_ARM_TIMEOUT` — Slots, die auf einen Magazin-Eintrag gewartet wird, Reset 4. `[31:21]` reserviert, 0. Der Rücksetzwert `0x0008_2044` ist genau die Feldkombination `GRANT_EN=0, GRANT_REPEAT=2, GRANT_GAP=4, GRANT_HOLD_MAX=8, GRANT_ARM_TIMEOUT=4` und wird nach R-07-17 aus derselben Quelle erzeugt wie die Dekodierkonstanten. Der Kontrollkanal-Zeitschlitz steht **nicht** hier, sondern einmalig als `MCCH_TN` in `REG_AACH_ACCESS_CFG` (§3.1.5, P2). |
| `0x00C4` | `REG_GRANT_MAG_INDEX` | RW | `0` | Magazin-Schreibport, Adressteil: `[2:0]` Wortselektor 0…6 (7 × 32 bit = 224 bit Fenster für den 216-bit-Block), `[4:3]` Zieleintrag 0…3 (`MAG_ENTRIES = 4`, `06_MAC §3.9.3`). Nebenwirkungsfrei, jederzeit lesbar (§3.2). |
| `0x00C8` | `REG_GRANT_MAG_DATA` | RW | `0` | Datenwort an `REG_GRANT_MAG_INDEX`. Kein automatischer Indexvorschub (§3.2). Bit-Abbildung wie bei den TX-Payload-Bänken (§3.5): der 216-bit-Block liegt **MSB-ausgerichtet**, `W0[31]` = erstes On-Air-Bit, `W6[15:0]` unbenutzt und 0. |
| `0x00CC` | `REG_GRANT_MAG_CTRL` | RW | `0` | `[3:0]` `cap_alloc` — Kopie des Feldes `capacity_allocation` aus der codierten PDU (R-06-10: die Hardware braucht die Haltedauer, darf den Block aber nicht parsen). `[4]` `valid` — 1 = Eintrag gültig setzen, 0 = Eintrag löschen. `[31:5]` reserviert, 0. |
| `0x00D0` | `REG_GRANT_MAG_GO` | W1S | `0` | `[0]` Übernahme des gestageten Eintrags in den von `REG_GRANT_MAG_INDEX[4:3]` bezeichneten Magazin-Platz, einschließlich `cap_alloc` und `valid`. Das PL löscht das Bit nach der Übernahme; die Kopie ist atomar in einem `clk_sys`. |
| `0x00D4` | `REG_UL_ASSIGN_STATE` | RO | — | `[2:0]` Zustand der Zuweisungs-Zustandsmaschine (`06_MAC §3.9.3`: 0 = `S_IDLE`, 1 = `S_ARMED`, 2 = `S_WINDOW`, 3 = `S_COOL`). `[9:3]` `hold_left` — verbleibende Halteslots. `[12:10]` `emit_left`. `[13]` Reservierung aktiv (`resv_active`). `[15:14]` `resv_pattern`. `[17:16]` `tn` des Slots, auf dem die aktive Zuweisung gilt. `[21:18]` Belegungsmaske der vier Magazin-Plätze. |

**Kein Register erzeugt eine Zuweisungs-PDU.** Der 216-bit-Block kommt **fertig codiert** aus
der Software (`05_CHANNEL_CODING`, R-06-10) und wird über das Magazin-Fenster hinterlegt; das
PL wählt, platziert und wiederholt ihn, es codiert nicht und parst nicht. Damit bleibt
`05_CHANNEL_CODING` R-05-02 („die einzigen Kanalcodierer in Hardware sind BSCH und AACH —
keine weiteren") unverletzt. Die Felder `capacity_allocation`, `granting_delay`,
`resv_frames`, `assign_ts`, `subslot_mode` und `repeat_count`, die eine frühere Fassung dieses
Abschnitts als PL-Parameter führte, existieren **nicht**: `capacity_allocation` steckt im
codierten Block und redundant in `REG_GRANT_MAG_CTRL[3:0]`, `granting_delay` ist nach R-06-11
festgeschrieben auf `0000₂` und damit kein Parameter, und Haltedauer, Sendeslot und
Wiederholung folgen aus `cap_alloc`, `MCCH_TN` und der Zustandsmaschine.

**Verbindliche Eingangsbeschränkung (R-07-11).** Der Zuweisungsblock im PL hat genau vier
Klassen von Eingängen: das Sync-Ereignis des Uplink-Steuerkanals samt `tn`/`ssn`
(`03_PHY_UL_RX §3.4.2`), die Position im Zeitraster (`tn`, `fn`, `mn`), diese
Konfigurationsregister und den Magazin-Inhalt. Er hat **keinen** Eingang aus einem Decoder-,
Parser- oder Prüfsummenpfad.

**Warum das so scharf formuliert ist.** V1 macht die Zuweisung von einem decodierten
Feld abhängig: die Vorantwort-Zuweisungs-FSM filtert auf `mm_pdu_type ∈ {2,7}`
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:57–63] und wird von einem Puls des
MAC-ACCESS-Parsers getriggert. Verlagert man die Decodierung in die Software — wie es der
V2-Schnitt tut —, wandert diese Abhängigkeit mit, und die Zuweisung ist nicht mehr
sendezeitpunkt-fest. Genau daran ist ein V1-Umbau gemessen gescheitert
[MESS 2026-07-11, `00_OVERVIEW §3.4`]. Zusätzlich existiert in V1 ein
Einzelschuss-Register, mit dem die Software eine Zuweisung auslöst
[CODE rtl/infra/tetra_axi_lite_regs.v:827] — der direkte Software-Umlauf im Antwortzeitpfad.
Beide Konstruktionen sind in V2 nicht vorhanden.

**Mehrslot-Reservierung.** Die Haltedauer folgt aus `cap_alloc` des ausgesendeten
Magazin-Eintrags, gedeckelt durch `GRANT_HOLD_MAX`; das Reservierungsmuster im AACH entsteht
im PL aus `resv_active`/`resv_pattern` des Zuweisungsblocks (`06_MAC §3.9.5`) und braucht
kein Musterregister. Das ersetzt den V1-Mechanismus, bei dem ein RTL-Puls mit einer
Rahmenzahl das Infowort für mehrere Frames auf einen Haltewert zog
[CODE rtl/tx/tetra_aach_encoder.v:80–81]; die Rahmenzahl entstand dort aus dem oberen Nibble
des Zuweisungselements [CODE rtl/lmac/tetra_pre_reply_slotgrant.v:304–308]. Ohne diese
Haltezeit sendet das Endgerät die Fortsetzungs-Bursts einer langen Kurznachricht nicht
(`00_OVERVIEW §3.4`, Nebenbedingung). Die Reservierung ist deshalb Teil der Grundfunktion,
kein Zusatz.

**Was V2 hier bewusst aufgibt.** V1 wählt den Wert des Zuweisungselements im **RTL** nach dem
dort decodierten Nachrichtentyp: `0x00` (erster Unterschlitz, keine Haltezeit) für die
Anmeldung, `0x30` (`capacity_allocation = 3` = 3 Slots) für die lange Kurznachricht
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:146, 185]. Diese Unterscheidung **im PL** ist unter
R-00-02 nicht mehr möglich. Sie verschwindet damit aber nicht: die Software wählt den Wert,
wenn sie den Magazin-Eintrag codiert, und sie darf das, weil sie ihn beliebig lange vorher
bereitstellen kann — kein Software-Anteil liegt im Zeitpfad (R-06-10). Offen ist nur, mit
welchem Vorgabewert das Magazin für einen erstmals gesehenen Teilnehmer gefüllt wird:
O-07-1 und `06_MAC` O-06-1.

#### 3.1.7 Air-Lock-Messregister (erhaltenswerte Infrastruktur)

Diese Gruppe wird aus V1 **normativ übernommen**, weil sie die einzige Möglichkeit ist, den
zeitlichen Bezug zwischen gesendetem Downlink-Slot und empfangenem Uplink-Burst auf der
echten Hardware zu messen. Die Auswertung steht in `08_TIMING`; hier steht die Definition.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x00E0` | `REG_AIRLOCK_CFG` | RW | `0x0000_0003` | `[2:0]` `anchor_ts` — ETSI-Zeitschlitz, dessen **erstes Dibit** den Anker setzt. Reset 3 (ETSI TS3). |
| `0x00E4` | `REG_AIRLOCK_ANCHOR_CNT` | RO | `0` | Zählerstand des freilaufenden `clk_sys`-Zählers beim letzten Ankerpuls. |
| `0x00E8` | `REG_AIRLOCK_UL_CNT` | RO | `0` | Zählerstand beim letzten Uplink-Sync-Ereignis. |
| `0x00EC` | `REG_AIRLOCK_EVT_CNT` | RO | `0` | Anzahl Uplink-Ereignisse, 32 bit, **freilaufend** (nicht sättigend, nicht von `CNT_CLEAR` betroffen). Die Software erkennt an einer Änderung dieses Werts, dass ein neuer Messwert vorliegt. |
| `0x00F0` | `REG_AIRLOCK_DELTA_CYC` | RO | `0` | **Atomar im PL** berechnete Differenz `Zählerstand(UL-Ereignis) − Zählerstand(letzter Anker)`, modulo 2³². |

**Der Kernpunkt, der übernommen werden muss.** Die Differenz wird **im PL im selben Takt
wie das Uplink-Ereignis** gebildet, nicht von der Software aus zwei Registerlesevorgängen
nachgerechnet [CODE rtl/tetra_zynq_top.v:1344–1355]. Rechnet die Software nach, entsteht ein
Abfrage-Wettlauf: zwischen dem Lesen von `ANCHOR_CNT` und `UL_CNT` kann ein neuer Ankerpuls
liegen, und die Differenz wird um eine Slotdauer falsch. Der Wettlauf ist in V1 aufgetreten
und wurde genau so behoben; der Codekommentar benennt ihn als „Race-Fix"
[CODE rtl/tetra_zynq_top.v:1340–1343]. R-07-12 hält das fest.

**Umbenennung gegenüber V1** — damit alte Protokolle lesbar bleiben:

| V1-Name | V1-Adresse | V2-Name | V2-Adresse |
|---|---|---|---|
| `REG_TS1_STOPWATCH_TS1` | `0x2B0` | `REG_AIRLOCK_ANCHOR_CNT` | `0x00E4` |
| `REG_TS1_STOPWATCH_UL` | `0x2B4` | `REG_AIRLOCK_UL_CNT` | `0x00E8` |
| `REG_TS1_STOPWATCH_EVT` | `0x2B8` | `REG_AIRLOCK_EVT_CNT` | `0x00EC` |
| `REG_TS1_STOPWATCH_DELTA` | `0x2BC` | `REG_AIRLOCK_DELTA_CYC` | `0x00F0` |

Der V1-Name trägt den Bestandteil `TS1`, obwohl der Anker seit einer Änderung auf **DL TS3**
liegt [CODE rtl/tetra_zynq_top.v:1305–1309, 1321]. Grund für die Ankerverschiebung: mit
TS1-Anker fällt der Messwert für UL TS3/TS4 über die Frameperiode und wickelt um; mit
TS3-Anker liegen alle vier Uplink-Ankunftszeiten monoton in `[8,34 … 50,84] ms`. Der
V2-Name benennt die Funktion, und die Ankerwahl ist ein Register statt einer festen
Verdrahtung.

**Zählerbreite und Wrap:** Der freilaufende Zähler ist 32 bit bei 100 MHz und wrappt nach
42,95 s. Die Differenzbildung modulo 2³² ist deshalb für jede Messgröße unter 42,9 s korrekt,
auch über einen Wrap hinweg. Absolutwerte (`ANCHOR_CNT`, `UL_CNT`) dürfen nur zur Plausibilisierung
verwendet werden.

#### 3.1.8 Zähler und Diagnosewerte

Jeder Zähler hat seinen **eigenen Namen und seine eigene Adresse**. Das ist eine direkte
Reaktion auf den V1-Zustand, in dem der Verwurfszähler der Sende-Warteschlange als
`clear_cnt` im oberen Halbwort eines `MLE_STATS`-Registers steckt (§2.3) — ein Zähler, der
bei der nächsten Fehlersuche nicht gefunden wird.

| Adresse | Name | Zugriff | Bedeutung |
|---|---|---|---|
| `0x0100` | `REG_DLQ_STATUS` | RO | `[2:0]` Belegung der Sende-Warteschlange 0…4, `[7:4]` Belegungsmaske je Platz, `[8]` voll. Erfüllt die Forderung aus `04_PHY_TX_TDMA §3.5.1`, dass Belegung und Maske lesbar sind (in V1 verdrahtet, aber an kein Register geführt). |
| `0x0104` | `REG_DLQ_DROP_TOTAL` | RO | Sättigend 16 bit: jeder nicht gespeicherte Eintrag (voll **oder** Arbitrierungsverlust). |
| `0x0108` | `REG_DLQ_DROP_MM` | RO | Sättigend **16 bit** je Erzeuger. V1 hat hier 8 bit und sättigt bei 255 — ein Verwurfsproblem mit 5000 Ereignissen ist von einem mit 256 nicht unterscheidbar [CODE rtl/lmac/tetra_dl_signal_queue.v:138–140]. |
| `0x010C` | `REG_DLQ_DROP_CMCE` | RO | dito |
| `0x0110` | `REG_DLQ_DROP_SDS` | RO | dito |
| `0x0114` | `REG_DLQ_POP_CNT` | RO | Sättigend 16 bit: an die Sendekette übergebene PDUs. |
| `0x0118` | `REG_DLQ_LEN_MISMATCH_CNT` | RO | Sättigend 16 bit: Eintrag, dessen `coded_len` nicht zur `pdu_class` passt (`04_PHY_TX_TDMA §3.11`, Punkt 2). |
| `0x011C` | `REG_DLQ_ROUTE_ERR_CNT` | RO | Sättigend 16 bit: Eintrag mit `target_ts = 0` oder `> 4`. |
| `0x0120` | `REG_MB_DL_DROP_CNT` | RO | Sättigend 16 bit: Auslöse-Puls der DL-PDU-Mailbox bei nicht übernommenem Vorgänger (§3.3). |
| `0x0124` | `REG_MB_DL_STALL_CNT` | RO | Sättigend 16 bit: Datenschreibzugriff auf die DL-Mailbox während `go_pending` (verworfen). |
| `0x0128` | `REG_MB_UL_DROP_CNT` | RO | Zwei sättigende 16-bit-Zähler in **einem** Wort, getrennt nach Erzeuger: `[15:0]` verworfene Steuerkanal-Bursts (CB-Zweig), `[31:16]` verworfene Normal-Uplink-Bursts (NUB-Zweig). Verworfen wird, wenn beide Bänke **desselben** Erzeugers ungelesen waren (§3.4). Die Trennung ist nötig, weil sonst ein Fehlalarm-Dauerstrom auf dem CB-Zweig nicht von einem echten Sprachburst-Verlust zu unterscheiden ist. |
| `0x012C` | `REG_MB_UL_PUSH_CNT` | RO | Freilaufend 32 bit: insgesamt übergebene Uplink-Bursts. Zusammen mit der Folgenummer im Kopfwort erlaubt das der Software, Lücken zu erkennen. |
| `0x0130` | `REG_MB_TXPAY_COMMIT_CNT` | RO | Sättigend 16 bit: ausgeführte Payload-Übernahmen (§3.5). |
| `0x0140` | `REG_TX_FIFO_OVF_CNT` | RO | Sättigend 16 bit: Überlauf der Takt-Domänen-Überquerung im Sendepfad (`04_PHY_TX_TDMA` R-04-19). |
| `0x0144` | `REG_TX_FIFO_UNF_CNT` | RO | Sättigend 16 bit: Unterlauf, ebd. Das Unterlauf-Verhalten (Halten des letzten Abtastwerts) steht in `04_PHY_TX_TDMA §3.9.2`. |
| `0x0148` | `REG_TX_BURST_CNT` | RO | Freilaufend 32 bit: gesendete Bursts. |
| `0x014C` | `REG_TX_RRC_SAT_CNT` | RO | Sättigend 16 bit: Sättigungsereignisse im Sende-RRC, gefordert in `04_PHY_TX_TDMA §3.9`. Erwartungswert 0. |
| `0x0150` | `REG_TX_PADJ_UNBAL_CNT` | RO | Sättigend 16 bit: unbalancierte Phasenanpassungs-Bits (`04_PHY_TX_TDMA §3.6.5`). Erwartungswert 0 — ein Zählerstand > 0 heißt, dass die Anpassung nicht aus dem Burst-Inhalt gerechnet wurde. |
| `0x0154` | `REG_TX_BUILD_REQ_MISS_CNT` | RO | Sättigend 16 bit: Slot ohne `build_req` (`04_PHY_TX_TDMA §3.6.6`). Jeder Zählschritt ist ein Leerlauf-Burst statt eines Trägerabrisses. |
| `0x0158` | `REG_TX_SYM_EN_CNT` | RO | **Freilaufend 32 bit**: Symbol-Enable-Pulse der Sendekette (`04_PHY_TX_TDMA §3.1`). Erwartungswert 18 000/s. Nicht mit `REG_SYM_TICK_CNT` zu verwechseln: das ist ein 100-ms-Fenstermesswert der Taktüberwachung, dieser Zähler ist der freilaufende Gesamtstand, gegen den `04_PHY_TX_TDMA §5` Punkt 3 (180 000 in 10 s) prüft. |

**Zähler des Zuweisungsblocks.** `06_MAC §3.13` führt sie als abschließende Liste mit der
Auflage „AXI-lesbar unter eigenem Namen"; §3.1.8 löst diese Auflage hier ein. Ein gepacktes
Sammelregister wäre der V1-Zustand, den dieser Abschnitt gerade abschafft. Alle sättigend
16 bit, außer wo anders angegeben.

| Adresse | Name | Zugriff | Bedeutung (`06_MAC §3.13`) |
|---|---|---|---|
| `0x0160` | `REG_GRANT_TRIGGER_CNT` | RO | gültiger Auslöser in `S_IDLE` |
| `0x0164` | `REG_GRANT_EMIT_CNT` | RO | Aussendung einer Zuweisung. Bezugsgröße der Aufschaukelungs-Sperre `grant_emit_cnt ≤ GRANT_REPEAT × grant_trigger_cnt` (`06_MAC §5.1`, `14_VERIFICATION §3.9`) |
| `0x0168` | `REG_GRANT_REGRANT_CNT` | RO | Wiederholung, weil im reservierten Unterschlitz nichts empfangen wurde |
| `0x016C` | `REG_GRANT_USED_CNT` | RO | Uplink-Burst im reservierten Unterschlitz erkannt |
| `0x0170` | `REG_GRANT_SUPPRESSED_CNT` | RO | Auslöser verworfen, weil Zustand ≠ `S_IDLE` |
| `0x0174` | `REG_GRANT_STARVED_CNT` | RO | `GRANT_ARM_TIMEOUT` abgelaufen, Magazin war leer |
| `0x0178` | `REG_GRANT_MAG_OVERWRITE_CNT` | RO | Magazin-Überlauf, ältester Eintrag überschrieben |
| `0x017C` | `REG_GRANT_PREEMPT_CNT` | RO | Signalisierungs-Warteschlange für eine Zuweisung verdrängt |
| `0x0180` | `REG_GRANT_LATE_CNT` | RO | Zuweisungsbits lagen nicht vor dem `slot_pulse` des Zielslots vor. Erwartungswert **0**; Abnahmekriterium R-08-03 und `08_TIMING §3.3.4` |
| `0x0184` | `REG_RESV_SLOT_CNT` | RO | Kontrollkanal-Slot mit Reservierungsmuster gesendet |
| `0x0188` | `REG_MCCH_SLOT_CNT` | RO | Kontrollkanal-Slots gesendet — Bezugsgröße für `REG_RESV_SLOT_CNT` (Reservierungsanteil, `06_MAC §3.9.6`) |
| `0x018C` | `REG_AACH_F18_CLCH_CNT` | RO | Frame-18-Slot mit CLCH-Muster gesendet |
| `0x0190` | `REG_UL_NTS2_DETECT_CNT` | RO | Uplink-Burst mit NTS2 erkannt (`06_MAC §3.3.2`) |
| `0x0194` | `REG_STEAL_OVERRIDE_CNT` | RO | Queue-Eintrag hat den Halteinhalt eines Verkehrsschlitzes verdrängt (`04_PHY_TX_TDMA §3.4`, gefordert von `10_CMCE_CALL` R-10-09) |

#### 3.1.9 Freilaufende Zähler — abschließende Liste

`CNT_CLEAR` (`REG_CTRL[3]`) setzt **alle** Zähler dieses Kapitels auf 0, mit genau diesen
Ausnahmen. Die Liste ist abschließend; ein Zähler, der nicht hier steht, ist sättigend und
löschbar (R-07-16). Sie ist gleichzeitig die Eingangstabelle für den `CNT_CLEAR`-Teil von
`tb_axi_reset_values` (§5.1).

| Register | Abschnitt | Warum freilaufend |
|---|---|---|
| `REG_SYM_TICK_CNT` | §3.1.2 | Fenstermesswert der Taktüberwachung; ein Löschen würde einen stehenden `clk_lvds` verschleiern |
| `REG_SLOT_CNT` | §3.1.2 | monotone Zeitachse für die Protokollierung — nur als Differenz zweier Lesevorgänge auswertbar |
| `REG_AIRLOCK_EVT_CNT` | §3.1.7 | Änderungsanzeige für einen neuen Messwert; ein Löschen erzeugt eine Scheinänderung |
| `REG_MB_UL_PUSH_CNT` | §3.1.8 | Lückenerkennung gegen `seq_num` im Kopfwort; nur als Differenz auswertbar |
| `REG_TX_BURST_CNT` | §3.1.8 | monotone Sendebilanz gegen `REG_SLOT_CNT` |
| `REG_TX_SYM_EN_CNT` | §3.1.8 | Ratenmaß der Sendekette; nur als Differenz über ein Zeitfenster auswertbar (`04_PHY_TX_TDMA §5`, Punkt 3) |

`REG_AIRLOCK_ANCHOR_CNT`, `REG_AIRLOCK_UL_CNT` und `REG_AIRLOCK_DELTA_CYC` sind **keine
Zähler**, sondern Momentanwerte eines freilaufenden Zeitzählers bzw. eine Differenz; sie
werden von `CNT_CLEAR` ebenfalls nicht verändert.

### 3.2 Das einheitliche Mailbox-Muster

V1 hat **sechs** live benutzte indirekte Index/Daten-Fenster (Vorantwort-Pull `0x220`–`0x230`,
UL-Demand-Body `0x250`–`0x25C`, Sprach-Füllmailbox `0x270`–`0x27C`, NUB-Lesemailbox
`0x280`–`0x28C`, Langnachrichten-Lesefenster `0x298`–`0x29C`, D-NWRK-BROADCAST-Push
`0x1D0`–`0x1D8` [CODE rtl/infra/tetra_axi_lite_regs.v:848–850, :902–913]) plus das indirekte
IQ-Capture-Lesefenster (`REG_IQCAP_CTRL[28:16]` als Adresse, `REG_IQCAP_DATA` als Datenport
[CODE …:886–887]) — bei **drei** verschiedenen Handshake-Varianten:
Index/Daten/GO mit Belegt-Spiegel und Wartespirale in der Software
[CODE rtl/lmac/tetra_reply_mailbox.v:57–70, sw/tetra_tx_transport.c:53–64 — 50-ms-Wartelauf],
Status/Index/Daten/Quittung [CODE rtl/lmac/tetra_ul_demand_body_mailbox.v:29–32], und ein
Fenster **ohne** Quittung, bei dem die Software eine Änderung eines Zählers an einem
Sonderindex beobachten muss [CODE sw/tetra_hal.h:393–404; die PL-Instanz ist mit
`ack_pulse_sys = 1'b0` verdrahtet, CODE rtl/tetra_zynq_top.v:851]. Das ist eine der
Hauptquellen fragiler Verträge: jede Variante hat ihre eigene Verlust- und Wettlauf-Logik,
und keine ist vollständig spezifiziert.

**V2 hat genau ein Muster.** Jede Mailbox besteht aus vier Registern an festen Offsets
innerhalb ihrer Seite:

| Offset | Name | Zugriff | Bedeutung |
|---|---|---|---|
| `+0x0` | `*_INDEX` | RW | Wortselektor. Breite je Mailbox. Nebenwirkungsfrei, jederzeit lesbar. |
| `+0x4` | `*_DATA` | RW / RO | Datenwort an Position `INDEX`. RW bei PS→PL, RO bei PL→PS. |
| `+0x8` | `*_TRIGGER` | W1S | PS→PL: `GO`. PL→PS: `ACK`. Schreiben einer 1 in Bit 0 setzt das Bit; die **Hardware** löscht es, wenn sie den Auslöser verarbeitet hat. Rücklesen liefert den Auslösezustand. |
| `+0xC` | `*_STATUS` | RO | `[0]` Bereitschaftsbit, `[1]` Belegtbit des Ziels bzw. des zweiten Puffers — beide richtungsabhängig, siehe unten; `[1]` existiert nur, wo es eine Quelle hat (R-07-04). `[15:8]` Folgenummer modulo 256: PL→PS die Nummer des bereitstehenden Transfers, PS→PL die Zahl der **übernommenen** Auslöser, an der die Software die Annahme ihres Pushs erkennt. `[16]` `index_range_err` (letzter Datenzugriff lag außerhalb des gültigen Indexbereichs; löscht mit `CNT_CLEAR`). |

**Kein automatischer Indexvorschub.** `INDEX` wird ausschließlich durch einen Schreibzugriff
auf `INDEX` verändert. Damit ist ein Lesevorgang nebenwirkungsfrei (§2.4) und ein
Diagnosewerkzeug kann jedes Wort beliebig oft lesen. Die Kosten sind der zweite Zugriff pro
Wort: der größte Transfer sind 111 Wörter (§3.4), also 222 statt 111 AXI-Zugriffe pro
Uplink-Burst; bei höchstens 70,6 Uplink-Slots/s sind das rund 15 700 Zugriffe/s. Bei rund
100 ns pro Zugriff über die GP0-Brücke entspricht das ~1,6 ms/s Buslast. [ANNAHME: Rechnung
aus Wortzahl und Slotrate; die Zugriffszeit von 100 ns ist nicht gemessen und in
`13_SW_ARCHITECTURE` zu prüfen.] Ein nebenwirkungsfreier Lesevorgang ist diese Buslast wert.

**Ablauf PS → PL (Push).** `STATUS[0]` heißt hier `go_pending`.

```
1.  STATUS lesen.  STATUS[0] = 1  → das PL hat den vorigen Auslöser noch nicht
    übernommen; warten (Frist §3.8). Datenschreibzugriffe werden in diesem Zustand
    VERWORFEN und in REG_MB_*_STALL_CNT gezählt.
    STATUS[1] = 1  → das Ziel ist belegt; ein Push würde verworfen. Wer hier nicht
    prüft, erzeugt einen gezählten Verwurf statt eines Fehlers.
2.  Für jedes Wort w:  INDEX = w   dann   DATA = Wert.
3.  TRIGGER = 1.
4.  Das PL kopiert den vollständigen Stufenpuffer in EINEM Takt in sein Ziel und
    löscht go_pending. Fenster, in dem Schritt 2 verboten ist: 1 clk_sys = 10 ns.
```

Ist der Zielpuffer im PL belegt (Warteschlange voll), wird der Auslöser verworfen, der
Stufenpuffer bleibt unverändert, `REG_MB_*_DROP_CNT` inkrementiert und `go_pending` wird
gelöscht. **Es gibt kein stilles Überschreiben** (R-07-06).

**Ablauf PL → PS (Pull).** `STATUS[0]` heißt hier `valid`.

```
1.  STATUS[0] pollen, bis 1.
2.  Für jedes Wort w:  INDEX = w   dann   Wert = DATA.
    Der Inhalt ist während des ganzen Lesevorgangs stabil: der PL-Puffer ist gegen
    Überschreiben verriegelt, solange valid gesetzt ist.
3.  TRIGGER = 1  → PL löscht valid und gibt den Puffer frei.
```

**Doppelpufferung (Ping-Pong).** Jede PL→PS-Mailbox hat **zwei** Puffer **je Erzeuger** —
schreibt mehr als ein Erzeuger auf dasselbe Fenster, gilt zusätzlich die Bindungs- und
Vorrangregel aus §3.4. Während die Software Puffer A liest, kann das PL Puffer B füllen;
`STATUS[1]` zeigt an, dass noch mindestens ein weiterer Burst aussteht. Trifft ein dritter
Burst desselben Erzeugers ein, während beide seiner Puffer ungelesen sind, wird der **neue**
verworfen und `REG_MB_UL_DROP_CNT` inkrementiert — der ältere ungelesene bleibt gültig. V1 macht das
Gegenteil: dort gewinnt die Erfassung, der ungelesene Burst wird überschrieben, und es gibt
keinen Zähler dafür [CODE rtl/lmac/tetra_voice_nub_read_mailbox.v:80–84]. Datenverlust ohne
Zähler ist auf der Luft nicht diagnostizierbar (P6).

**Indexbereich.** Ein Datenzugriff mit `INDEX` außerhalb des gültigen Bereichs liefert
lesend 0, verwirft schreibend und setzt `STATUS[16]`. Der Index wird **nicht** maskiert und
wickelt **nicht** um — eine Umwicklung auf Wort 0 würde einen Software-Zählfehler in eine
stille Datenverfälschung verwandeln.

**Bit-Order in allen Mailbox-Wörtern.** Zwei Konventionen, je nach Inhalt, und jede ist an
ihrer Stelle ausgeschrieben:

- **Kanalcodierte Bits (PS→PL): MSB-first, wortweise absteigend.** Es gilt Regel R aus
  `04_PHY_TX_TDMA §3.11`: das zuerst gesendete Bit liegt im MSB.
- **Soft-Werte (PL→PS): LSB-first, Index aufsteigend mit der On-Air-Zeit.** Es gilt
  `03_PHY_UL_RX §3.6.4`.

Die beiden Konventionen sind unterschiedlich, weil ihre Inhalte unterschiedlich sind: ein
codierter Block ist ein Bitvektor mit Sendereihenfolge, ein Soft-Vektor ist ein Feld von
Zahlen mit Index. „Analog zum Nachbarfenster" ist keine Angabe (P4) — deshalb steht bei
jeder Mailbox unten die vollständige Formel.

### 3.3 Seite 1 — DL-PDU-Mailbox (PS → PL)

**Zweck.** Der **einzige** Weg, auf dem eine Downlink-PDU in die Sendekette gelangt. Das
löst die V1-Last „drei DL-Emissionspfade" auf (`00_OVERVIEW §1.1`, §3.6): Signalisierung,
Sprach-Füllinhalt und Broadcast-Push benutzen dasselbe Fenster und unterscheiden sich nur
durch ein Metadatenfeld (P3: Sonderfälle sind Parameter, nicht Pfade).

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x1000` | `REG_DLMB_INDEX` | RW | `0` | `[3:0]` Wortselektor 0…15. |
| `0x1004` | `REG_DLMB_DATA` | RW | `0` | Datenwort an `INDEX`. Rücklesbar. |
| `0x1008` | `REG_DLMB_GO` | W1S | `0` | `[0]` Übernahme auslösen. |
| `0x100C` | `REG_DLMB_STATUS` | RO | — | `[0]` `go_pending`, `[1]` Warteschlange voll, `[4:2]` Belegung, `[15:8]` Folgenummer, `[16]` `index_range_err`. |

**Wortbelegung (16 Wörter).**

| Wort | Inhalt |
|---|---|
| `W0`…`W13` | `coded_msb_aligned[431:0]` — die kanalcodierten type-5-Bits |
| `W14` | Routing- und AACH-Metadaten |
| `W15` | Länge und Klasse |

**Abbildung der codierten Bits (verbindlich).** Für Wort `w ∈ [0,13]` und Bitposition
`b ∈ [31,0]`:

```
W[w] bit b  trägt  coded[431 − (32·w + (31 − b))]
```

Damit gilt: `W0[31] = coded[431]` = **erstes On-Air-Bit**; `W0[0] = coded[400]`;
`W13[31] = coded[15]`; `W13[16] = coded[0]` = letztes On-Air-Bit; `W13[15:0]` ist unbenutzt
und muss 0 sein. Ein 216-bit-Block (SCH/HD) ist **MSB-ausgerichtet**: er belegt
`W0`…`W6[31:8]`, `W6[7:0]` und `W7`…`W13` müssen 0 sein.

Diese Ausrichtung ist genau die Stelle, an der V1 zwei gegensätzliche Konventionen hat: ein
Erzeuger schreibt `{lat_coded_schhd, 216'd0}` (MSB, richtig)
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:334], der andere `{216'd0, lat_coded_blk1}` (LSB)
[CODE rtl/lmac/tetra_pre_reply_blck.v:209]. Der zweite liefert dem Zeitplaner in `BKN1`
garantiert 216 Nullbits, weil dieser den Halbblock aus `head_coded[431:216]` liest
[CODE rtl/lmac/tetra_dl_signal_scheduler.v:165] — der echte Inhalt in `[215:0]` geht bei
SCH/HD nie auf die Luft. Dass es nicht auffiel, liegt daran, dass die Attach-Antwort
inzwischen vollständig aus der Software kommt (`react_mm2_locupd` / `react_mm7_grpid`
[CODE sw/tetra_attach_daemon.c:426–428], BL-ACK über `TX_BL_ACK`
[CODE sw/tetra_attach_daemon.c:353, :916]) und dieser RTL-Pfad damit ein **stiller
Nullsender ohne Zähler** ist. Analyse in `04_PHY_TX_TDMA §3.11`.

**`W14` — Routing und AACH:**

| Bits | Feld | Bedeutung |
|---|---|---|
| `[2:0]` | `target_ts` | ETSI-Zeitschlitz 1…4. 0 oder > 4 → Eintrag verworfen, `REG_DLQ_ROUTE_ERR_CNT` +1. |
| `[4:3]` | `mode` | `00` = `SINGLE` (einmal senden, dann Platz freigeben), `01` = `PERSIST_SET` (Inhalt für `target_ts` halten und in jedem passenden Slot senden, bis ersetzt oder gelöscht), `10` = `PERSIST_CLEAR` (Halteinhalt für `target_ts` löschen; Nutzdaten `W0`…`W13` werden ignoriert), `11` reserviert. |
| `[6:5]` | `prio` | `00` = MM/MLE, `01` = CMCE, `10` = SDS, `11` reserviert. Wirkt auf die Pop-Arbitrierung der Warteschlange (`04_PHY_TX_TDMA §3.5.1`). Nur für `mode = SINGLE` relevant. |
| `[20:7]` | reserviert | 0. Hier trug V1 ein fertiges 14-bit-AACH-Infowort mit der PDU mit. Das ist nach `06_MAC` R-06-04 unzulässig: das Infowort entsteht im PL aus der Inhaltsentscheidung **desselben** Slots (`06_MAC §3.8.2`) und reist nicht mit der PDU. Die Bits bleiben reserviert und sind auf 0 zu prüfen (`18_ROADMAP §2.3`). |
| `[26:21]` | `delay_slots` | Freigabe erst nach so vielen Slot-Strobes; `0` = sofort. Wird **immer** ausgewertet — es gibt keinen zweiten, gemeinsamen Abstandswert und kein Bit, das auf einen solchen umschaltet. Einziger spezifizierter Verbraucher ist die Staffelung identischer Wiederholungen einer Ruf-PDU (`10 §3.4.3`, Abstand normativ `08 §3.4.3` R-4). Das Feld ist **kein** Antwortabstand: der Zeitpunkt einer substanziellen Antwort ist ereignisgetriggert (`08` R-08-11, `08 §3.5.2`, `04` R-04-21). |
| `[27]` | `last_fragment` | Markiert das letzte Fragment einer Fragmentkette. Ersetzt das in V1 in `REG_VOICE_ACTIVE_MASK[8]` versteckte Bit. Wirkung auf das Infowort: `06_MAC`. |
| `[31:28]` | reserviert | 0, auf 0 zu prüfen. Hier liegt **kein** Umschaltbit auf einen gemeinsamen Abstandswert: es gibt kein solches Register (§3.1.5, Absatz zu `0x00B4`), weil der Antwortzeitpunkt ereignisgetriggert ist (`08` R-08-11, `08 §3.5.2`) und ein Bit dafür keinen Verbraucher hätte (R-07-04). |

**`W15` — Länge und Klasse:**

| Bits | Feld | Bedeutung |
|---|---|---|
| `[8:0]` | `coded_len` | Anzahl gültiger codierter Bits: 216 oder 432. |
| `[10:9]` | `pdu_class` | `00` = SCH/F (432 bit), `01` = SCH/HD (216 bit), `10`/`11` reserviert. |
| `[31:11]` | reserviert | 0 |

`coded_len` und `pdu_class` sind **absichtlich redundant**. Das PL prüft beide gegeneinander
und inkrementiert bei Widerspruch `REG_DLQ_LEN_MISMATCH_CNT`, statt einen halben Block zu
senden (`04_PHY_TX_TDMA §3.11`, Punkt 2).

**Warum `delay_slots` im PL und nicht in der Software.** Das Feld staffelt **identische
Wiederholungen derselben PDU**: eine Ruf-PDU wird als `N` gleiche Einträge übergeben,
Eintrag `k` mit `delay_slots = 8·k` (`10 §3.4.3`); der Zielabstand von 2 TDMA-Frames je
Schritt ist normativ in `08 §3.4.3` R-4. Im Zeitraster des PL ist dieser Abstand
deterministisch; über die Ereigniszeit der Software trägt er die Granularität der
Abfrageschleife als Fehler und blockiert bei synchroner Umsetzung die Hauptschleife
[MESS 2026-05-17, `08 §3.4.3`]. **Nicht** dafür gedacht ist der Abstand zwischen Vorantwort
und substanzieller Antwort: der ist ereignisgetriggert und darf nach `08 §3.5.2` nicht
durch einen festen Abstand ersetzt werden — deshalb gibt es hier auch kein gemeinsames
Abstandsregister mehr (§3.1.5).

**Betriebsart `PERSIST_SET` — wofür.** Der Sprachpfad braucht in jedem Frame einen neuen
Burst auf dem Sprachslot. Ein einmal gesetzter Halteinhalt wird weiter gesendet, wenn die
Software einmal zu spät ist, statt eine Lücke zu erzeugen. Die Software ersetzt ihn im
nächsten Zyklus. Es gibt einen Halteplatz je Zeitschlitz, also vier insgesamt; das entspricht
V1s vier Bänken der Sprach-Füllmailbox [CODE rtl/lmac/tetra_voice_filler_mailbox.v:89–109],
nur über dasselbe Fenster wie alles andere.

**Ressourcen:** Stufenpuffer 16 × 32 bit = 512 FF, Halteplätze 4 × 432 bit = 1728 FF,
Adressdekodierung und Prüfungen ~120 LUT. [ANNAHME: aus der Struktur; V1s generischer
Schreibbaustein mit 16 expliziten Wortlatches [CODE rtl/lmac/tetra_indirect_mailbox_wr.v:49–146]
stützt die Größenordnung.]

### 3.4 Seite 2 — UL-Burst-Mailbox (PL → PS)

**Zweck.** Der **einzige** Weg, auf dem ein Uplink-Burst zur Software gelangt: rohe
Soft-Werte vor jeder Decodierung, plus TDMA-Zeitstempel im selben Transfer (R-07-09,
R-00-04).

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x2000` | `REG_ULMB_INDEX` | RW | `0` | `[6:0]` Wortselektor. Gültiger Bereich **je Burst-Typ**: 0…44 beim Steuerkanal-Burst, 0…110 beim Normal-Uplink-Burst. |
| `0x2004` | `REG_ULMB_DATA` | RO | — | Datenwort an `INDEX`. |
| `0x2008` | `REG_ULMB_ACK` | W1S | `0` | `[0]` Puffer freigeben und das Fenster für den nächsten Burst binden. |
| `0x200C` | `REG_ULMB_STATUS` | RO | — | `[0]` `valid`, `[1]` **mindestens ein weiterer Burst steht an** — zweite Bank desselben Erzeugers oder ein Burst des anderen Erzeugers (siehe „Zwei Produzenten, ein Fenster"), `[15:8]` Folgenummer, `[16]` `index_range_err`. |

**Wortbelegung.**

| Wort | Inhalt |
|---|---|
| `W0` | Kopfwort |
| `W1` | TDMA-Zeitstempel des Uplink-Slots (**normativ**) |
| `W2` | Erfassungs-Diagnose |
| `W3`…`W(2+N)` | Soft-Werte, `N = n_soft / 4` |

`N = 42` für einen Steuerkanal-Burst (168 Soft-Werte) und `N = 108` für einen
Normal-Uplink-Burst (432 Soft-Werte). Höchster gültiger Index damit 110.

**`W0` — Kopfwort:**

| Bits | Feld | Bedeutung |
|---|---|---|
| `[1:0]` | `burst_type` | `00` = Control Uplink Burst (168 Soft), `01` = Normal Uplink Burst (432 Soft), `10`/`11` reserviert. Der Wert benennt den **Erfassungszweig** — die getroffene Sync-Sequenz und die daraus folgende Burstlänge —, **nicht** den logischen Kanal. |
| `[13:2]` | `n_soft` | Anzahl gültiger Soft-Werte: 168 oder 432. |
| `[21:14]` | `seq_num` | Laufende Burst-Nummer modulo 256. Eine Lücke zeigt der Software einen Verwurf an, auch wenn sie den Zähler nicht liest. |
| `[22]` | `after_drop` | 1 = unmittelbar vor diesem Burst wurde mindestens einer verworfen. |
| `[31]` | `valid` | Spiegel von `STATUS[0]`, damit das Kopfwort allein selbstprüfend ist. |

**`burst_type` trägt keine Kanal-Semantik (normativ).** Das Feld sagt, welcher
Erfassungszweig den Burst geliefert hat, und damit implizit dessen Länge (`n_soft`). Es sagt
**nicht**, welcher logische Kanal darin steckt: ein Normal-Uplink-Burst kann TCH/S **oder**
SCH/F tragen, und diese Unterscheidung setzt Auswertung des Uplink-Inhalts voraus, die nach
`00` R-00-02 nicht in der Hardware liegt (`03 §3.7` hält ausdrücklich fest, dass die PL den
Inhalt nicht kennt). Die Zuordnung fällt in der Software über den Reservierungszustand des
Zeitschlitzes (`13 §3.2`). Ein Kanalfeld in dieser Mailbox ist ein Spec-Verstoß.
**Namensgleichheit beachten:** das Feld `burst_type` des Slot-Zeitplan-Eintrags (§3.6,
normativ `04_PHY_TX_TDMA §3.3`) ist ein **anderes** Feld mit anderer Belegung
(`00` = NDB, `01` = SB) und betrifft die Senderichtung.

**Reservierte Codepunkte `10₂`/`11₂`.** Die PL erzeugt sie in Stufe 1 nicht; `10₂` ist für den
STCH-tragenden Normal-Uplink-Burst vorgemerkt (`18` R-18-07, `18 §2.3`). Die Software
verwirft einen solchen Burst ohne Decodierversuch, setzt das `ACK` trotzdem und zählt
`ul_burst_type_unsupported_cnt` (`13 §3.2`, `13 §3.10.2`).

Die Slot-Kennung steht **nur** in `W1`, nicht zusätzlich hier. V1 führt sie im Kopfwort
[CODE rtl/rx/tetra_ul_ctrl_softburst_mailbox.v:114] und hat damit die Slot-Zuordnung an einer
Stelle, an der der Frame- und Multiframe-Bezug fehlt — genau die halbe Information, die
R-00-04 vollständig verlangt.

**`W1` — TDMA-Zeitstempel (Erfüllung von R-00-04).** Feldlage **identisch** zu
`REG_TDMA_STATE`, damit Software und Testbench dieselbe Entpackfunktion benutzen:

| Bits | Feld | Bedeutung |
|---|---|---|
| `[1:0]` | `tn_ul` | Zeitschlitz **des Uplink-Slots**, 0-basiert |
| `[6:2]` | `fn_ul` | Frame 0…17 |
| `[12:7]` | `mn_ul` | Multiframe 0…59 |
| `[18:13]` | `hn_ul` | Hyperframe 0…63 |
| `[26:19]` | `sym_anchor` | Symbolindex des Sync-Ankers im Slot, 0…254 |
| `[27]` | `subslot` | 0 = Unterschlitz 1, 1 = Unterschlitz 2 [ETSI §9.3.6] |

**Das PL rechnet, nicht die Software.** Die Zeitbasis des Designs ist die
**Downlink**-Zeitbasis. Am Basisstations-Standort beginnen Hyperframe, Multiframe und Frame
des Uplink um **feste 2 Zeitschlitze** später als die des Downlink [ETSI §9.3.9]. Der
Uplink-Slot, zu dem ein Burst gehört, ist daher:

```
tn_ul = (tn_dl − 2) mod 4
fn_ul = fn_dl − 1  (mit Multiframe-/Hyperframe-Wrap), falls tn_dl < 2
fn_ul = fn_dl                                        , falls tn_dl ≥ 2
```

Weil die Frames exakt um zwei Slotdauern versetzt sind, liest die Zeitbasis während des
**ganzen** Uplink-Slots dieselbe Downlink-Koordinate; die Zuordnung ist also eindeutig.

Diese Umrechnung liegt **genau einmal** im Design, im PL, im zentralen Mapping-Modul
(`04_PHY_TX_TDMA §3.2.3`). Die Software erhält das Ergebnis. Grund: eine ±2-Slot-Korrektur
über eine Frame- und Multiframe-Grenze ist die Art Rechnung, die in V1 mehrfach unabhängig
und mit unterschiedlicher Breite implementiert wurde.

**Der Zeitpunkt des Latchens ist normativ: am Sync-Anker, nicht beim Push.** Das
Erfassungsmodul übernimmt die Zeitbasis in dem Takt, in dem sein Sync-Ereignis feuert, und
führt den Wert mit dem Burst mit. Beim Normal-Uplink-Burst liegen zwischen Sync-Anker und
Verfügbarkeit der Soft-Werte 480 Eingangs-Abtastwerte = **6,667 ms**
(`03_PHY_UL_RX §3.6.5`); ein erst dort abgelesener Zeitstempel kann bereits im Folgeslot
liegen und wäre um eine Slotdauer falsch.

**Warum der Zeitstempel überhaupt Pflicht ist.** In V1 bezieht der Zeitgeber der
UL-Reassembly seinen Frame-Takt aus der **Downlink-Empfangskette**
[CODE rtl/tetra_zynq_top.v:837 — `frame_tick_sys` an `tetra_ul_schf_reassembly`]. Damit hängt
die Uplink-Fragmentzusammensetzung am DL-Empfang, obwohl beide nichts miteinander zu tun
haben. V2 löst die Kopplung über den Zeitstempel: die Software leitet jede Frist aus `W1`
ab und hält keine eigene Uhr. Die V1-Mailbox für Soft-Bursts trägt genau diese Information
**nicht** — ihr Kopfwort enthält nur die Slotnummer
[CODE rtl/rx/tetra_ul_ctrl_softburst_mailbox.v:114, Vertrag in sw/tetra_ul_rx_mailbox.h:11–17].

**`W2` — Erfassungs-Diagnose:**

| Bits | Feld | Bedeutung |
|---|---|---|
| `[4:0]` | `corr_peak` | Korrelationswert des auslösenden Sync-Ereignisses |
| `[6:5]` | `best_phase` | gewinnende Symbolphase 0…3 |
| `[7]` | `bank` | Bank **innerhalb des Erzeugers**, aus der gelesen wird (0/1). Welcher Erzeuger, sagt `W0.burst_type`; beide Angaben zusammen benennen die Quelle eindeutig |
| `[23:8]` | `sym_norm` | Mittelwert von `\|soft\|` über den Burst, 8.8-Festkomma. Macht den Arbeitspunkt des Quantisierers pro Burst prüfbar (`03_PHY_UL_RX §5.4`). |
| `[31:24]` | reserviert | 0 |

**Soft-Werte — Abbildung (verbindlich).** Soft-Breite **8 bit signed**
(`03_PHY_UL_RX §3.7`). Für Datenwort `d = 0 … N−1` (Registerindex `i = 3 + d`) und
`n = 0 … 3`:

```
DATA[8·n +: 8]  =  soft[4·d + n]          (signed, Zweierkomplement)
```

`soft[j]` ist der Soft-Wert des On-Air-type-5-Bits `j`, mit `j = 0` = erstes gesendetes Bit
des Bursts. **Aufsteigender Index = aufsteigende On-Air-Zeit, keine Umkehr.**
Vorzeichenkonvention: `soft > 0 ⇒ Bit '0'`, `soft < 0 ⇒ Bit '1'` (ETSI-ausgerichtet,
`03_PHY_UL_RX` R-03-07). Die einzige zulässige Inversionsstelle im Gesamtsystem liegt in der
Software-Anpassung zum Sprach-Viterbi, **nicht** in dieser Mailbox — V1 invertiert hier
[CODE rtl/rx/tetra_ul_ctrl_softburst_mailbox.v:62–71] und hat damit eine zweite Konvention
in die Schnittstelle gelegt.

**Zwei Produzenten, ein Fenster (normativ).** Auf dieses **eine** Fenster arbeiten **zwei**
Erfassungszweige, die dauerhaft und unabhängig laufen: der CB-Zweig (168 Soft-Werte) und der
NUB-Zweig (432 Soft-Werte); „Beide Zweige laufen dauerhaft und unabhängig. Ein NUB kann
gleichzeitig vom CB-Zweig korreliert werden (und umgekehrt)" (`03_PHY_UL_RX §2.2`). Aus **einem**
Uplink-Slot können damit im schlechtesten Fall **zwei** Einträge entstehen. Damit daraus kein
unspezifizierter Wettlauf wird, gilt:

1. **Der Speicher gehört dem Erzeuger, nicht dem Fenster.** Jeder Zweig hat seine **eigene**
   Ping-Pong-Ablage mit zwei Bänken in seinem eigenen Modul. Kein Zweig schreibt je in die
   Bänke des anderen. Eine Schreib-Arbitrierung existiert deshalb nicht — auch nicht, wenn
   beide Zweige im selben `clk_sys`-Takt fertig werden.
2. **Das Lesefenster ist an genau einen Burst gebunden.** Mit dem Setzen von `STATUS[0]`
   (`valid`) bindet das PL das Fenster an einen bestimmten Burst; Erzeuger und Bank stehen in
   `W0.burst_type` und `W2.bank`. Die Bindung bleibt bis zum `ACK` unverändert — das ist die
   Zusage „Inhalt während des ganzen Lesevorgangs stabil" aus §3.2.
3. **Vorrang bei der Bindung: NUB vor CB.** Haben beide Zweige gleichzeitig einen ungelesenen
   Burst — einschließlich Fertigstellung im selben Takt —, wird der NUB-Burst zuerst gebunden.
   Grund: der Sprachslot ist zeitkritisch, jeder Frame braucht seinen Nachfolger, während ein
   verlorener Steuerkanal-Burst über die Zugriffswiederholung des Endgeräts ersetzt wird. **Der
   CB-Burst geht dabei nicht verloren**: er bleibt in seiner Bank stehen und wird nach dem `ACK`
   gebunden. Eine Kollision im selben Takt kostet also nur Reihenfolge, keine Daten.
   [ANNAHME: Vorrangregel aus der Zeitkritikalität der beiden Kanäle gewählt, nicht gemessen.
   Die Kosten sind über die beiden Hälften von `REG_MB_UL_DROP_CNT` messbar.]
4. **`STATUS[1]` heißt „es steht noch mindestens ein weiterer Burst an"**, gleichgültig ob in
   der zweiten Bank desselben Erzeugers oder beim anderen Erzeuger. Das Bit hat damit in beiden
   Fällen eine Quelle (R-07-04) und sagt der Software immer dasselbe: nach dem `ACK` sofort
   erneut lesen, nicht auf die nächste Abfrageperiode warten.
5. **Verwurf ist erzeugerlokal und erzeugergenau gezählt.** Verworfen wird nur, wenn **beide
   Bänke desselben Erzeugers** ungelesen sind; dann bleibt der ältere Burst gültig und der neue
   entfällt (§3.2, R-07-06). Weil der Speicher erzeugerlokal ist, kann ein Fehlalarm-Dauerstrom
   auf dem CB-Zweig **keinen** NUB verdrängen. `REG_MB_UL_DROP_CNT` ist deshalb halbwortweise
   getrennt — `[15:0]` CB, `[31:16]` NUB (§3.1.8) —, sonst wäre im Betrieb nicht entscheidbar,
   welcher Zweig verliert.
6. **Indexobergrenze je Burst-Typ.** Der gültige Indexbereich folgt aus `W0.n_soft`: 0…44 beim
   Steuerkanal-Burst, 0…110 beim Normal-Uplink-Burst. Ein Zugriff darüber setzt `STATUS[16]`
   (§3.2), auch wenn er innerhalb der Registerbreite `[6:0]` liegt.

**Speicher.** Die Soft-Werte liegen im Blockspeicher des jeweiligen Erfassungsmoduls, nicht in
der Registerbank. Die Registerbank enthält **keine** Nutzdaten; sie reicht Index und Datenwort
durch. Das ist die Regel, die die Registerbank klein hält. Bedarf je Erzeuger: NUB-Zweig
2 Bänke × 432 × 8 bit = **6 912 bit**, passt in ein RAMB18 (`03_PHY_UL_RX §3.6.3`); CB-Zweig
2 Bänke × 168 × 8 bit = **2 688 bit**. Die BRAM-Zuordnung selbst steht in `03 §3.9` (P2).

**Anforderung an den CB-Zweig, die aus diesem Fenster folgt.** `03_PHY_UL_RX` beschreibt den
CB-Zweig heute nur mit einem Strom-Port zum SCH/HU-Decoder (`03 §3.5.1`). Damit ein
Steuerkanal-Burst über dieses Fenster wortweise lesbar ist, braucht der CB-Zweig zusätzlich
dieselbe Ping-Pong-Ablage und denselben Wort-Port wie der NUB-Zweig
(`mb_index_sys` `[5:0]` 0…41, `mb_rdata_sys` 32 bit, `mb_valid_sys`, `mb_ack_sys`, Layout
analog `03 §3.6.4`). Ohne diesen Port ist Punkt 1 nicht baubar.

**Frist.** Bei maximal vier belegten Uplink-Slots pro Frame trifft höchstens jede 14,167 ms
ein Uplink-Slot ein; er kann nach Punkt 1 bis zu **zwei** Einträge erzeugen. Die Software fragt
`STATUS[0]` also unter 14 ms ab und prüft nach **jedem** `ACK` sofort `STATUS[1]`, statt auf die
nächste Abfrageperiode zu warten. Die zweite Bank je Erzeuger gibt dabei einen ganzen Burst
Reserve; die vollständige Verarbeitung beider Transfers muss unter 28 ms bleiben. Herleitung
und Messung: §3.8 und `08_TIMING`.

### 3.5 Seite 3 — TX-Payload-Bänke (PS → PL)

**Zweck.** Fertig codierte, langlebige Sendeinhalte, die der Slot-Zeitplan über seinen
Inhaltsindex auswählt (`04_PHY_TX_TDMA §3.3.2`). Sie ändern sich selten — Systeminformation
beim Hochlauf und bei Konfigurationsänderungen, Leerlauf-PDU einmal.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x3000` | `REG_TXPAY_INDEX` | RW | `0` | `[2:0]` Wortselektor 0…6 innerhalb des Stufenpuffers, `[7:4]` Zielbank 0…8 für die Übernahme. |
| `0x3004` | `REG_TXPAY_DATA` | RW | `0` | Stufenpuffer-Wort an `INDEX[2:0]`. |
| `0x3008` | `REG_TXPAY_COMMIT` | W1S | `0` | `[0]` Stufenpuffer → Bank `INDEX[7:4]` übernehmen. |
| `0x300C` | `REG_TXPAY_STATUS` | RO | — | `[0]` Übernahme ausstehend (`go_pending`), `[15:8]` Folgenummer modulo 256 der **ausgeführten** Übernahmen — deckungsgleich mit `REG_MB_TXPAY_COMMIT_CNT[7:0]`, damit die Software die Annahme ihres Pushs am selben Ort und mit derselben Regel erkennt wie bei den anderen Mailboxen (§3.2, R-07-05), `[16]` `index_range_err`. `[1]` existiert hier **nicht**: es gibt kein zweites Ziel und keinen belegten Zielpuffer, also keine Quelle für das Bit (R-07-04, §3.2). |

**Bänke:**

| Bank | Inhalt | Verweis |
|---|---|---|
| 0 / 1 | Normal-Downlink-Füllblock 1 / 2 | `04_PHY_TX_TDMA §3.3.2`, `payload_idx = 0` |
| 2 / 3 | MCCH-Block 1 / 2 | `payload_idx = 1` |
| 4 / 5 | Broadcast-Block 1 / 2 (Systeminformation) | `payload_idx = 2` |
| 6 | Zweiter Block des Synchronisations-Bursts | `payload_idx = 3` |
| 7 | Leerlauf-PDU (216 bit, SCH/HD-codiert) | Leerlauf des Signalisierungspfads, `04_PHY_TX_TDMA §3.5.2` |
| 8 | Begleitblock für Signalisierungs-Bursts | `sig_companion`, ebd. |

**Bit-Abbildung je Bank (216 bit, 7 Wörter, MSB-first nach Regel R):** Für
`w ∈ [0,6]`, `b ∈ [31,0]`: `W[w] bit b = block[215 − (32·w + (31 − b))]`, also
`W0[31] = block[215]` = erstes On-Air-Bit des Blocks, `W6[8] = block[0]`, `W6[7:0] = 0`.

**Nebenwirkung der Übernahme.** `COMMIT` kopiert die 216 bit in **einem** `clk_sys`-Takt
in die Live-Bank, aber wirksam wird die neue Bank erst am nächsten Slot-Strobe: die
Sendekette hat den Body des laufenden Slots bereits übernommen. Damit kann ein Burst nie aus
einer halb geschriebenen Bank entstehen. V1 hat für genau diese Funktion einen Registernamen
in der Software-HAL, aber keine Implementierung (§2.2) — die Bänke sind dort direkt
beschreibbar, und eine Änderung während eines laufenden Slots ist möglich.

**Ressourcen:** Stufenpuffer 7 × 32 = 224 FF, Live-Bänke 9 × 216 = 1944 FF, Auswahl ~60 LUT.
[ANNAHME: aus der Struktur.]

### 3.6 Seite 4 — Slot-Zeitplan

Direkt adressiertes Fenster, **keine** Mailbox: der Zeitplan ist eine Tabelle, kein
Transfer.

| Adresse | Name | Zugriff | Reset | Bedeutung |
|---|---|---|---|---|
| `0x4000` + 4·`k` | `REG_SCHEDULE[k]`, `k = 0…143` | RW | 0 | Wort `k` des Zeitplans. `[15:0]` = Eintrag bei `dense_idx = 2k`, `[31:16]` = Eintrag bei `dense_idx = 2k+1`. |
| `0x4240`–`0x4FFF` | — | — | — | unbelegt, Verhalten nach R-07-03 |

`dense_idx = (mn mod 4)·72 + fn·4 + tn`, Bereich 0…287. Eintragsformat (16 bit,
`payload_class`, `payload_idx`, `burst_type`, `ndb2`, `enable`) und die Begründung der
`mn mod 4`-Periode stehen normativ in `04_PHY_TX_TDMA §3.3` und werden hier nicht wiederholt
(P2).

**Lese-Latenz** 2 `clk_sys` wie jede andere Seite (§2.4); der Speicher ist ein
Blockspeicher mit registriertem Lesen und kombinatorischer Bank-Auswahl über das
Adress-LSB [CODE rtl/tx/tetra_slot_schedule.v:172–196].

**Schreibregel (Wettlauf).** Ein Eintrag darf nicht innerhalb von 2 TDMA-Frames vor dem
Slot geändert werden, der ihn liest (`04_PHY_TX_TDMA` R-04-09). Der Vertrag ist eine
Software-Regel; das PL erzwingt sie nicht. Er ist überhaupt nur formulierbar, weil Schreib-
und Leseseite dieselbe Zeitbasis haben (`01_PLATFORM §3.1`, Ein-Domänen-Entscheidung).

### 3.7 Taktbereichsübergänge am Registerinterface

**Grundzustand in V2:** Die Registerbank und die gesamte übrige `clk_sys`-Logik liegen in
**einer** 100-MHz-Domäne aus derselben PS-Quelle (`01_PLATFORM §3.1`, R-01-03). Zwischen
Registerbank und Verbraucher gibt es **keine** Synchronisierer. Registerausgänge gehen
direkt an ihre Verbraucher; Pipeline-Register aus Fanout- oder Timing-Gründen sind erlaubt,
müssen aber als Pipeline benannt sein (`_p0`, `_p1`) und nicht als CDC.

Das ist die größte einzelne Einsparung dieses Kapitels: V1 behandelt `i_clk` und
`s_axi_aclk` als unabhängige Domänen, obwohl beide `FCLK_CLK0` sind, und bezahlt dafür
**3 790 FF** reine Synchronisierregister bei null Nutzen
[`01_PLATFORM §3.1`, gezählt über alle `ASYNC_REG`-Deklarationen in `rtl/tetra_zynq_top.v`].

**Was tatsächlich die Domäne wechselt.** Nur diese vier Übergänge existieren im Gesamtdesign
(`01_PLATFORM §3.5`), und nur zwei berühren Register:

| Register / Wert | Von | Nach | Muster | Anmerkung |
|---|---|---|---|---|
| `REG_CTRL.LOOPBACK_EN`, `TX_GATE_OPEN` | `clk_sys` | `clk_lvds` | **P1** (2-FF-Pegel) | Einzelbit, langsam wechselnd |
| `REG_LVDS_FREQ_MEAS` | `clk_lvds` | `clk_sys` | **P3** (Bus mit Übernahme-Toggle) | Mehrbit-Wert, kohärent |
| `REG_SYM_TICK_CNT` | `clk_lvds` | `clk_sys` | **P4** (Gray) oder **P3** | Zähler; P4 nur zulässig, wenn er ausschließlich um 1 inkrementiert |
| IQ-Ströme | beide Richtungen | — | **P5** (asynchrones FIFO) | kein Registerinhalt |

**Zwei Regeln binden speziell am Registerinterface** (die allgemeine Musterwahl und die
Verbote P1–P5 stehen normativ in `01_PLATFORM §3.5` und werden hier nicht wiederholt):

1. **Kein Registerzugriff darf auf die andere Domäne warten.** Steht `clk_lvds`, muss die
   Registerbank weiterlaufen — sonst hängt eine AXI-Transaktion und mit ihr der ARM-Kern.
   Jeder Lesepfad aus `clk_lvds` ist deshalb zustandslos: die Registerbank liefert den
   letzten übernommenen Wert, nie ein Quittungsergebnis.
2. **Ein Mehrbit-Registerwert wird nie bitweise synchronisiert**, auch nicht, wenn er
   „langsam" ist. Quasistatische Konfiguration über P1 ist nur zulässig, solange jedes Bit
   für sich gilt; sobald mehrere Bits **einen** Wert bilden, ist P3 Pflicht (R-07-15).

**Der V1-Verstoß, den Regel 1 ausschließt.** Das Reassembly-Wortfenster überträgt einen
**32-bit-Datenbus** und einen **9-bit-Index** bitweise über 2-FF-Ketten zwischen `clk_sys`
und `clk_axi` [CODE rtl/tetra_zynq_top.v:814–824 (Index), :855–865 (Daten)]. Jedes Bit kommt
potenziell in einem anderen Takt an; ein gelesenes Wort kann eine Mischung zweier Werte sein.
Dass es funktioniert, liegt nur daran, dass beide Takte physisch derselbe sind — die
Konstruktion ist dennoch falsch, und der gleiche Fehler steht 32-bit-breit auch auf den vier
Air-Lock-Latches [CODE rtl/tetra_zynq_top.v:1967–2008]. In V2 verschwindet die Frage, weil
es die zweite Domäne nicht gibt.

### 3.8 Unterbrechungsbehandlung

**Festlegung: es gibt keine Interrupt-Leitung zum PS** (R-07-14). Der Vertrag ist ein
Abfrage-Vertrag.

**Begründung aus dem Bestand.** V1 hat einen vollständigen Interrupt-Pfad und er ist
wirkungslos: drei der fünf Quellen sind konstant 0
[CODE rtl/tetra_zynq_top.v:940, 943, 1473–1475], `irq_out` ist
`|(irq_status & irq_enable)` mit `irq_enable = 0` nach Reset
[CODE rtl/infra/tetra_axi_lite_regs.v:1612, 2651–2656], und die Software schreibt
`REG_IRQ_ENABLE` nie — das Symbol existiert, es gibt keine Verwendung in `sw/*.c`
[CODE sw/tetra_hal.h:41]. Die Software fragt ab. Ein Interrupt-Pfad, der zwei Register, eine
BD-Verbindung und fünf Eingänge kostet und nie feuert, verstößt gegen R-07-04.

**Abfrage-Vertrag (verbindlich).** Für jede Mailbox und jeden Statuswert steht die Frist und
ihre Herleitung fest:

| Was | Abfrageperiode | Herleitung |
|---|---|---|
| `REG_ULMB_STATUS[0]` | **< 14 ms**, zusätzlich `STATUS[1]` nach jedem `ACK` | Höchstens 4 Uplink-Slots pro Frame ⇒ ein Uplink-Slot je 14,167 ms, der nach §3.4 bis zu **zwei** Einträge erzeugt (CB- und NUB-Zweig). Zwei Bänke je Erzeuger geben einen Burst Reserve; die vollständige Verarbeitung beider Transfers muss unter 28 ms bleiben. |
| `REG_DLMB_STATUS[0]` | nur unmittelbar vor einem Push | `go_pending` steht höchstens 1 `clk_sys` = 10 ns an; eine periodische Abfrage ist unnötig. |
| `REG_STATUS`, Zähler | ≤ 1 s | Betriebsanzeige, keine Frist im Zeitraster. |
| `REG_AIRLOCK_EVT_CNT` | Messbetrieb, ≤ 100 ms | Nur bei aktiver Air-Lock-Messung; der Delta-Wert bleibt bis zum nächsten Ereignis stehen. |

**Was die Fristen einhält, auch wenn die Software sie verletzt.** Jede Fristverletzung ist
zählbar und keine ist stumm: eine verpasste Uplink-Frist erscheint als
`REG_MB_UL_DROP_CNT` und als Lücke in `seq_num`. Damit ist die Frage „hat die Software zu
langsam abgefragt?" im Betrieb entscheidbar — in V1 ist sie es nicht, weil der überschriebene
Burst keinen Zähler hat (§3.2).

**Erweiterungspfad.** Wird in `13_SW_ARCHITECTURE` gemessen, dass die 14-ms-Frist unter Last
nicht gehalten wird, ist die Antwort **nicht** ein Interrupt, sondern zuerst ein dritter
Puffer für den betroffenen Erzeuger (eine dritte NUB-Bank kostet 3 456 bit im Blockspeicher,
eine dritte CB-Bank 1 344 bit). Ein Interrupt löst das Problem der
Verarbeitungsdauer nicht. Siehe §6, O-07-3.

### 3.9 Fehler- und Randfallverhalten (Zusammenfassung)

| Fall | Verhalten |
|---|---|
| Zugriff auf unbelegte Adresse | lesend 0, schreibend verworfen, `OKAY`, `REG_ACCESS_ERR_CNT` +1 |
| `WSTRB != 4'hF` | keine Registeränderung, `OKAY`, `REG_ACCESS_ERR_CNT` +1 |
| Schreibzugriff auf RO-Register | verworfen, `OKAY`, **kein** Zähler (Adresse ist belegt) |
| Lesen eines WO-Registers | liefert 0 |
| Mailbox-Index außerhalb des Bereichs | lesend 0, schreibend verworfen, `STATUS[16]` gesetzt; kein Umwickeln |
| `GO` während `go_pending` | verworfen, `REG_MB_DL_DROP_CNT` +1 |
| Datenschreibzugriff während `go_pending` | verworfen, `REG_MB_DL_STALL_CNT` +1 |
| PL-Push bei zwei belegten Bänken **desselben Erzeugers** | neuer Burst verworfen, älterer bleibt gültig, `REG_MB_UL_DROP_CNT` +1 in der Hälfte dieses Erzeugers (`[15:0]` CB, `[31:16]` NUB), `after_drop` im Folge-Kopfwort desselben Erzeugers |
| CB- und NUB-Zweig werden im selben Takt fertig | **kein Verlust**: der NUB-Burst wird zuerst an das Lesefenster gebunden, der CB-Burst bleibt in seiner Bank und wird nach dem `ACK` gebunden; `STATUS[1]` = 1 (§3.4) |
| Bänke des einen Erzeugers voll, während der andere Erzeuger frei ist | der freie Erzeuger ist **nicht** betroffen — Bänke sind erzeugerlokal, es gibt keinen gemeinsamen Pool (§3.4) |
| `ACK` ohne `valid` | wirkungslos |
| Zeitbasis-Ladewert außerhalb des Bereichs | verworfen, `REG_TDMA_LOAD_REJ_CNT` +1 |
| Schwellwert größer als Sequenzlänge | verworfen, alter Wert bleibt, `REG_ACCESS_ERR_CNT` +1 |
| `target_ts` = 0 oder > 4 in `W14` | Eintrag verworfen, `REG_DLQ_ROUTE_ERR_CNT` +1 |
| `coded_len` widerspricht `pdu_class` | Eintrag verworfen, `REG_DLQ_LEN_MISMATCH_CNT` +1 |
| `clk_lvds` steht | AXI bleibt bedienbar; `REG_STATUS.LVDS_ALIVE` = 0, `TX_GATE_OPEN` = 0, `REG_SYM_TICK_CNT` = 0. Kein Zugriff hängt (§3.7, Regel 1) |
| Reset während laufender Transaktion | Slave verwirft Latches, antwortet auf die nächste Transaktion normal; kein hängender Kanal |

### 3.10 Ressourcen-Erwartung

| Block | LUT | FF | BRAM | Herkunft |
|---|---:|---:|---:|---|
| AXI-Slave-Zustandsmaschine | ~60 | ~110 | 0 | [ANNAHME: Adress-/Datenlatches + Antwortkanäle] |
| Seite 0 (Register + Seiten-Multiplexer) | ~550 | ~700 | 0 | [ANNAHME] |
| Seite 1 DL-Mailbox (Stufenpuffer + Halteplätze) | ~120 | ~2 240 | 0 | §3.3 |
| Seite 2 UL-Mailbox (nur Durchreichung) | ~40 | ~20 | 0 | Nutzdaten im Erfassungsmodul (`03`) |
| Seite 3 TX-Payload (Stufenpuffer + 9 Bänke) | ~60 | ~2 170 | 0 | §3.5 |
| Seite 4 Zeitplan (nur Adressierung) | ~20 | ~10 | 2 RAMB18 | Speicher in `04 §3.3.1` |
| **Summe Schnittstelle** | **~850** | **~5 250** | 2 RAMB18 | |

**Anker aus V1:** die dortige Registerbank allein wiegt **3 132 LUT / 3 358 FF**
[BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:135`], in einem älteren Build
3 016 LUT / 3 057 FF [BUILD 2026-05-18 `build/reports/impl_hier_util.rpt:72`] — ohne die
3 790 FF der sys↔axi-Synchronisierer. Die V2-Zahl liegt bei mehr Nutzdatenspeicher niedriger
in LUT, weil (a) die Soft-Werte der UL-Mailbox nicht mehr in der Bank liegen, (b) der
Lese-Multiplexer je Seite getrennt ist statt ein `case` über rund 160 Quellen, und (c) die
Byte-Strobe-Sonderfälle entfallen (R-07-02).

**Warum der Lese-Multiplexer je Seite getrennt ist:** V1 hat ein `case` über `A[8:2]` mit
**rund 160 Zweigen** (128 im Bank-0-`case` [CODE rtl/infra/tetra_axi_lite_regs.v:1111–1280],
33 im nachgeschalteten Bank-1-Override [CODE …:1289–1329], gezählt über die Zuweisungen an
`rdata_mux_axi`) und einen zweiten Override-Block darüber [CODE …:1110–1331].
Der resultierende 32-bit-Multiplexer ist ein Hauptbeitrag zu den 3 132 LUT und liegt auf
einer Domäne, deren WNS +0,006 ns beträgt [BUILD 2026-07-12 `build/reports/impl_timing.rpt:139`].
Fünf kleine Multiplexer plus eine 5:1-Auswahl plus ein Ausgangsregister sind flacher und
erklären, warum §2.4 zwei Takte Lese-Latenz festlegt.

### 3.11 Software-Seite: HAL-Vertrag

Die Software greift ausschließlich über die HAL zu (R-07-20). Der HAL-Vertrag umfasst:

| Funktion | Zweck | Fehlerverhalten |
|---|---|---|
| `tetra_hal_open()` / `_close()` | Apertur abbilden, `REG_ID` und `REG_VERSION.major` prüfen | Abweichende Kennung oder Major-Version ⇒ Rückgabe < 0, kein weiterer Zugriff |
| `tetra_reg_read(off)` / `_write(off, val)` | einzelner 32-bit-Zugriff | Offset außerhalb der Apertur ⇒ Abbruch mit Meldung (Programmierfehler, nicht Laufzeitfehler) |
| `tetra_dl_push(pdu)` | vollständiger Push-Ablauf aus §3.2 einschließlich Warten auf `go_pending` | Zeitüberschreitung ⇒ Rückgabe < 0; die PDU wird **nicht** teilweise geschrieben |
| `tetra_ul_pull(burst)` | vollständiger Pull-Ablauf einschließlich `ACK` | `valid = 0` ⇒ Rückgabe 0 „nichts da"; `index_range_err` ⇒ Rückgabe < 0 |
| `tetra_txpay_commit(bank, bits)` | 7 Wörter schreiben, `COMMIT` | wie oben |
| `tetra_ts_*` | Umrechnung ETSI ↔ RTL-Zählweise, ausschließlich hier | — |

**Verbindlich:** Die Offsets und Bitfeld-Zugriffsmakros in `sw/tetra_hal.h` werden **erzeugt**
(R-07-17). Der V1-Zustand — eine handgepflegte Liste in `sw/tetra_hal.h` gegen eine zweite
handgepflegte Liste von `localparam`s im PL — hat nachweislich zu einem Symbol geführt, das
auf eine fremde Adresse zeigt und eine Nebenwirkung dokumentiert, die es nicht gibt (§2.2),
und zu vier Registern, die in der Registerdokumentation fehlen (§3.1.5).

---

## 4. Empirische Werte

Nur Werte, die in **diesem** Kapitel als Rücksetzwert oder Auslegungsgröße auftreten. Die
Messkontexte stehen vollständig in den Fachkapiteln; wer einen Wert ändert, muss die dortige
Messreihe wiederholen (P5).

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| `REG_RX_SYNC_CFG_UL.thresh_nub` Reset | **11** | [MESS 2026-05-17], `03_PHY_UL_RX §4` | **10:** Fehl-Locks, Lauf-BFI 6,1 % statt 4,7 %. **12:** Detektor tot, Korrelationsmaximum ist 11 — das Endgerät liest „Sprechwunsch abgewiesen". V1-Rücksetzwert ist 8 [CODE rtl/infra/tetra_axi_lite_regs.v:1557] und damit im Fehlalarm-Bereich (~48 Fehltreffer/s bei 8 [MESS 2026-05-16]); die Software korrigiert ihn beim Hochlauf. V2 setzt den gemessenen Wert als Reset, damit ein Boot ohne Software-Init nicht im falschen Regime läuft (R-07-19). |
| `REG_RX_SYNC_CFG_UL.thresh_cb` Reset | **15** | [MESS 2026-05-22], `03_PHY_UL_RX §4` | 13 → 25,5 % Prüfsummenerfolg, 14 → 36,4 %, **15 → 92,6 % und 94,1 %** in zwei Läufen. 15 bedeutet exakte Übereinstimmung aller 15 Symbole; nach oben gibt es kein Tuning. In V1 ist dieser Wert **nicht einstellbar**, weil ein Register beide Detektoren speist [CODE rtl/tetra_zynq_top.v:567] — das ist der Grund für R-03-04. |
| `REG_RX_SYNC_CFG_DL` Reset (NTS 10 / STS 13) | 10 / 13 | V1-Wert 13, geteilt [CODE rtl/infra/tetra_axi_lite_regs.v:1418]; Falschalarm-Knie bei 10 [MESS 2026-05-16] | [ANNAHME für die NTS-Aufteilung: 13 ist für NTS (11 Symbole) konstruktiv unerreichbar, deshalb getrennter Wert. Der DL-Empfang ist Diagnose, ohne Sendewirkung — eine Fehlwahl kostet keine Luftfunktion.] |
| AACH-Ruhemuster eines unbelegten Slots | `0x3000` (erzeugt von `tetra_aach_info` bei `SLOT_UMT = 0`, `SLOT_UL_STATE = 00`; in V1 der Reset-Wert des entfallenen Registers `REG_SLOT_AACH_TSn`) | [CODE rtl/infra/tetra_axi_lite_regs.v:1572], Musterliste `06_MAC §3.8.3` | Header `11₂` = Feld 1 ist **Downlink-Nutzungsmarker**, Feld 2 ist **Uplink-Nutzungsmarker**; beide `000000₂` = **Unallocated (UMx)** [ETSI Tabelle 21.82]. Der Slot kündigt damit weder eine Downlink-Nutzung noch ein Uplink-Zugriffsrecht an — der neutrale Ruhewert. (Eine „Kapazitätszuweisung" gibt es in der AACH nicht; `capacity allocation` ist ein Element des Basic slot granting [ETSI §21.5.6 Tabelle 21.96] und steckt im codierten Magazin-Eintrag samt seiner Kopie in `REG_GRANT_MAG_CTRL[3:0]`.) Die Referenzaufzeichnung dekodiert das verwandte Muster `0x0009` konsequent als „DL=Unalloc UL=Unalloc" [GOLD `docs/reference_decode/dl_full.md:18152`]. Ein anderer Ruhewert verändert die Zugriffsrechte aller Endgeräte im Leerlauf. |
| `REG_CELL_CFG_2.colour_code` Reset | 1 | [CODE rtl/infra/tetra_axi_lite_regs.v:1428] | Zellspezifisch; muss zur Systeminformation passen, sonst schlägt die Verschleierung fehl und kein Endgerät decodiert. |
| `REG_CELL_CFG_2.location_area` Reset | 1 | [CODE rtl/infra/tetra_axi_lite_regs.v:1453] | dito. |
| `REG_AIRLOCK_CFG.anchor_ts` Reset | **3** | [CODE rtl/tetra_zynq_top.v:1305–1309, 1321] | Mit TS1 als Anker wickelt der Messwert für UL TS3/TS4 über die Frameperiode; mit TS3 liegen alle vier Ankunftszeiten monoton in `[8,34 … 50,84] ms`. |
| Air-Lock-Differenz, **gemessen** | UL TS2 **22,499 ms**, UL TS3 **36,669 ms**, UL TS4 **50,836 ms** (DL-TS3-Anker) | [MESS 2026-05-25, `sw/tetra_ts_map.h:37–42`] | Schrittweite gemessen exakt ein Zeitschlitz (14,167 ms). Eine Abweichung um eine ganze Slotdauer bedeutet einen Fehler in der Slot-Zuordnung, nicht im Funkweg. UL TS1 ist nicht für Sprache allokiert und darum **nicht** gemessen. |
| Air-Lock-Differenz, **gerechnet** | `834 000 + (TS_UL − 1) · 1 416 700` Zyklen (= 8,340 / 22,507 / 36,674 / 50,841 ms) | [ANNAHME: aus Slotdauer 1 416 700 Zyklen und Ankerlage gerechnet; der Basiswert 834 000 für UL TS1 ist in der Quelle ausdrücklich als „theoretisch" bezeichnet [CODE sw/tetra_ts_map.h:43–45] und nicht gemessen] | Die Rechnung liegt um **500…800 Zyklen (5…8 µs)** über den gemessenen Werten — Restlaufzeit im Sende-/Empfangspfad, nicht in der Slot-Zuordnung. Die Formel taugt deshalb als Erwartungswert mit Toleranz (§5.4), **nicht** als Sollwert für einen Exaktvergleich. |
| `REG_SYM_TICK_CNT` Erwartungswert | 1 800 pro 100 ms | 18 000 Hz exakt [CODE rtl/tetra_zynq_top.v:953–954], `01_PLATFORM §3.3` | Abweichung ⇒ `clk_lvds` hat nicht 18,432 MHz, der Teiler 1024 ist falsch, und die Zeitbasis driftet gegen die Endgeräte. |
| `REG_LVDS_FREQ_MEAS` Erwartungswert | 1 843 200 ± 9 216 | `01_PLATFORM §3.4` | Außerhalb ⇒ Sendesperre. |
| UL-Burst-Rate (Auslegung der Frist) | ≤ 70,6 Bursts/s; gemessen ~19/s bei aktivem Sprechwunsch | [MESS 2026-05-17], `03_PHY_UL_RX §3.7` | Die Obergrenze folgt aus 4 Slots je 56,67 ms. Die Frist in §3.8 ist gegen die Obergrenze bemessen, nicht gegen den Messwert. |
| Registerbank V1 (Vergleichsanker) | 3 132 LUT / 3 358 FF | [BUILD 2026-06-20 `build/reports/cur_hier_deep.rpt:135`] | Obergrenze für die V2-Bank. Wird sie überschritten, liegen wieder Nutzdaten in der Bank. |
| WNS der 100-MHz-Domäne in V1 | +0,006 ns | [BUILD 2026-07-12 `build/reports/impl_timing.rpt:139`] | Kein Spielraum. Jede zusätzliche kombinatorische Stufe im Lesepfad kippt das Timing — Begründung für den seitenweisen Lese-Multiplexer mit Ausgangsregister (§3.10). |

---

## 5. Verifikation

### 5.1 Unit-Testbenches (Pflicht, selbstprüfend)

| Testbench | Prüft |
|---|---|
| `tb_axi_slave_protocol` | AXI4-Lite-Konformität: unabhängige Kanäle, `READY`-Verhalten, eine ausstehende Transaktion je Richtung, `BRESP/RRESP = OKAY` in allen Fällen, Lese-Latenz exakt 2 Takte auf **jeder** Seite. |
| `tb_axi_addressmap` | **Aliasing-Nachweis (R-07-01):** derselbe Wortindex `A[11:2]` in allen fünf belegten Seiten liefert fünf verschiedene Register; Schreibzugriff in Seite `n` verändert kein Register in Seite `m ≠ n`. Zusätzlich: alle 16 Seiten werden adressiert, die unbelegten liefern 0 und zählen. |
| `tb_axi_strobe` | `WSTRB != 4'hF` ändert nichts und zählt (R-07-02). |
| `tb_axi_reset_values` | Nach Reset wird **jede** in §3 genannte Adresse gelesen und gegen den Rücksetzwert verglichen. Tabelle wird aus derselben Quelle erzeugt wie die Dekodierkonstanten (R-07-17) — damit kann der Test nicht gegen eine veraltete Liste laufen. |
| `tb_mailbox_pattern` | Für **jede** der drei Mailboxen derselbe Testkörper in der Richtungsvariante der Mailbox: Push/Pull-Ablauf, Indexbereichsfehler, Stabilität des Inhalts während des Lesens, Fortschreiten der Folgenummer `STATUS[15:8]` bei jeder übernommenen bzw. bereitgestellten Übertragung. Richtungsspezifisch: PS→PL zusätzlich Verwurf bei belegtem Ziel mit Zählerstand, PL→PS zusätzlich Doppelpufferung. Bestehen alle drei den gemeinsamen Teil, ist R-07-05 erfüllt. |
| `tb_ul_mailbox_two_producers` | **Zwei Erzeuger, ein Fenster (§3.4):** CB- und NUB-Zweig liefern Bursts unabhängig, überlappend und im **selben** Takt. Geprüft wird: Vorrang NUB vor CB bei gleichzeitiger Fertigstellung, kein Verlust bei Kollision (der CB-Burst wird nach dem `ACK` präsentiert), `W0.burst_type` und `W2.bank` benennen Erzeuger und Bank korrekt, `STATUS[1]` steht, solange irgendein weiterer Burst aussteht, Indexobergrenze 44 bzw. 110 je Burst-Typ, und ein Verwurf zählt in der **richtigen** Hälfte von `REG_MB_UL_DROP_CNT`. Ein CB-Fehlalarm-Dauerstrom darf keinen NUB verdrängen. |
| `tb_dl_mailbox_bitorder` | 432-bit-Vektor mit Einzel-Bit-Wanderung (`one-hot` über alle 432 Positionen): jedes On-Air-Bit landet an der berechneten Wortposition. Zusätzlich der 216-bit-Fall MSB-ausgerichtet mit der Prüfung `coded[431:216] != 0` — der Test, an dem der V1-Fehler aus `04 §3.11` aufgefallen wäre. |
| `tb_ul_mailbox_timestamp` | Für alle 4 × 18 × 60 Kombinationen von `tn_dl/fn/mn`: der berechnete Uplink-Zeitstempel entspricht der Referenzimplementierung des 2-Slot-Versatzes [ETSI §9.3.9], einschließlich Frame-, Multiframe- und Hyperframe-Wrap. |
| `tb_ul_mailbox_softorder` | Soft-Vektor mit Rampe 0…431: jeder Wert liegt an der berechneten Nibble-Position, Vorzeichen unverändert (keine Inversion in der Schnittstelle). |
| `tb_airlock_atomic` | Anker- und UL-Ereignisse in Folge, mit einem Anker **zwischen** zwei Lesevorgängen: `DELTA_CYC` bleibt der Wert des Ereignisses, `EVT_CNT` zeigt die Änderung an. Der Test schlägt fehl, wenn die Differenz software-seitig rekonstruierbar wäre (R-07-12). |
| `tb_ul_assign_content_independence` | Der Zuweisungsblock erhält Sync-Ereignisse ohne jeden Decoder-Eingang und erteilt Zuweisungen; die Testbench treibt die Decoder-Schnittstellen mit Zufallswerten und weist nach, dass die Zuweisung sich nicht ändert (R-07-11). |
| `tb_regbank_no_consumer` | Erzeugter Test: für jedes lesbare Bit existiert ein Treiber ungleich Konstante, für jedes schreibbare Bit eine Senke (R-07-04). |

### 5.2 Integration in Simulation

Ende-zu-Ende: Software-Modell schreibt eine codierte PDU über Seite 1, das PL sendet sie,
die simulierte Empfangskette liest sie zurück, der Vergleich ist bit-identisch. Umgekehrt:
ein synthetischer Uplink-Burst wird eingespeist, die Software liest ihn über Seite 2 und
rekonstruiert die 432 Soft-Werte samt Zeitstempel; der Zeitstempel entspricht dem
eingespeisten Slot.

**Der Einspeisepfad `ulmb_inject` (benannt, simulationsexklusiv).** Die Einspeisung greift
nicht über AXI, sondern über eine im Testbench-Wrapper benannte Schnittstelle
`ulmb_inject(burst_type, n_soft, tdma_stamp, diag, soft[])` an den Bindungseingängen des
UL-Mailbox-Fensters, umschlossen von `` `ifdef SIM `` und damit in der Synthese nicht
vorhanden. Sie kann **auch das Kopfwort** setzen — einschließlich der reservierten
Codepunkte `burst_type = 10₂`/`11₂` und einer nicht zur Länge passenden `n_soft` —, weil
sonst der Verwurfsnachweis nach `18` R-18-07 (`ul_burst_type_unsupported_cnt` = 1, kein
Absturz, kein Fehlparse) nicht führbar ist. Ein Schreibweg über die Registerseite ist
**ausgeschlossen**: `REG_ULMB_DATA` ist RO (§3.4), und ein beschreibbares Datenfenster wäre
eine Hintertür in den Empfangspfad. `REG_SCRATCH` (§3.1.1) deckt nur den Bus-Selbsttest und
ist kein Einspeisepfad.

### 5.3 Gold-Vergleich

Geprüft wird die Wirkung von `delay_slots` (§3.3) an der Größe, für die es zuständig ist:
den **Wiederholungen** einer Ruf-PDU. Die Referenzaufzeichnung sendet drei bit-identische
`D-CONNECT` auf demselben Zeitschlitz im Abstand von je 2 TDMA-Frames
[GOLD `docs/reference_decode/action_reaction.md:283-285`, `10 §3.4.3`]. Kriterium: mit
`delay_slots = 0, 8, 16` reproduziert die eigene Zelle diese Staffelung im Zeitraster, mit
einer Toleranz von einem Slot.

Der Abstand zwischen Vorantwort und Anmeldebestätigung ist **kein** Kriterium dieses
Kapitels und wird hier nicht geprüft: er ist ereignisgetriggert (`08` R-08-11,
`08 §3.5.2`), das Abnahmekriterium ist der Inhalt der Antwort (`04 §5.4` Punkt 5).

Beides ist **kein** Bit-Vergleich — zellspezifische Felder dürfen und müssen
abweichen (`CONVENTIONS.md §3`).

### 5.4 Luft-Abnahme

| Kriterium | Messung |
|---|---|
| Kein Verwurf im Normalbetrieb | `REG_MB_UL_DROP_CNT`, `REG_MB_DL_DROP_CNT`, `REG_DLQ_DROP_*` bleiben über einen 10-minütigen Lauf mit Anmeldung, Gruppenwechsel und Gruppenruf auf 0. |
| Keine Adressfehler | `REG_ACCESS_ERR_CNT` = 0 nach dem Hochlauf und über den ganzen Lauf. |
| Zeitstempel plausibel | Für jeden Uplink-Burst liegt `W1` im erwarteten Slot; die Verteilung über `tn_ul` entspricht den belegten Slots. Ein systematischer Versatz um einen Slot zeigt einen Fehler in der 2-Slot-Rechnung. |
| Air-Lock stabil | `REG_AIRLOCK_DELTA_CYC` liegt über ≥ 3 Sprechwunsch-Läufe innerhalb **± 2 000 Zyklen (± 20 µs)** um den gerechneten Erwartungswert `834 000 + (TS_UL − 1) · 1 416 700` Zyklen (§4). Die Toleranz deckt die 2026-05-25 gemessenen 500…800 Zyklen Restlaufzeit ab und liegt weit unter einer Slotdauer (1 416 700 Zyklen), erkennt also jede Slot-Fehlzuordnung. Für UL TS2/TS3/TS4 gilt zusätzlich: der Messwert reproduziert 22,499 / 36,669 / 50,836 ms ± 20 µs [MESS 2026-05-25 als Referenz]. |
| Keine Fristverletzung | `seq_num` in `W0` ist über den Lauf lückenlos. |
| Abfragelast | Gemessene CPU-Zeit der Abfrageschleife < 5 % eines Kerns. Wird das überschritten, greift §6 O-07-3. |

Sprechwunsch-Tests werden **mindestens dreifach** wiederholt; ein einzelner Lauf ist kein
Nachweis.

---

## 6. Offene Punkte

**O-07-1 — Ein Parametersatz für zwei Bedarfsfälle.**
R-00-02 verlangt, dass die Zuweisung nicht vom Burst-Inhalt abhängt. Damit entfällt die
V1-Unterscheidung zwischen „Anmeldung braucht einen Unterschlitz" (`capacity_allocation = 0`)
und „lange Kurznachricht braucht drei Slots" (`capacity_allocation = 3`, drei Halteframes)
[CODE rtl/lmac/tetra_pre_reply_slotgrant.v:146, 185, 304–308]. V2 muss **einen** Satz wählen.
Die kleine Variante bricht die Fortsetzungskette der langen Kurznachricht; die große Variante
kostet Slot-Kapazität bei jeder Anmeldung — und bei jedem Sync-Fehlalarm, weil auch der eine
Zuweisung auslöst. R-00-02 gibt die Richtung vor („der Entwurf wählt bewusst das erste
Risiko"). Empfehlung deshalb: das Grant-Magazin mit einem Eintrag füllen, dessen
`capacity_allocation = 3` ist (`REG_GRANT_MAG_CTRL.cap_alloc = 3`, `GRANT_REPEAT = 2`,
`GRANT_HOLD_MAX = 8`), und die Kosten **messen**, nicht schätzen. Derselbe offene Punkt aus
Sicht des Mechanismus ist `06_MAC` O-06-1 („Wer füllt das Magazin für einen erstmals
gesehenen Teilnehmer?").
Messgrößen: `REG_GRANT_EMIT_CNT` und `REG_GRANT_TRIGGER_CNT` gegen `REG_RX_CAPTURE_CNT` (wie viele Zuweisungen entstehen
aus Fehlalarmen), `REG_RX_SYNC_DROP_CNT`, und die Zahl abgewiesener Sprechwünsche. Die
Abnahme muss ausdrücklich die Spirale aus `00_OVERVIEW §3.4` ausschließen
(`14_VERIFICATION`). Der Mechanismus selbst gehört nach `06_MAC`; hier ist nur die
Registerseite festgelegt.

**O-07-2 — Ist ein 32-bit-Zähler für die Air-Lock-Messung ausreichend?**
Der freilaufende Zähler wrappt nach 42,95 s. Für die Differenz ist das unkritisch (§3.1.7),
für die Absolutwerte nicht: zwei Lesevorgänge im Abstand von mehr als 42,9 s sind nicht
mehr vergleichbar. Empfehlung: so lassen, weil die Absolutwerte nur zur Plausibilisierung
dienen. Falls `08_TIMING` einen Anwendungsfall für lange Absolutzeiten findet, ist die
Antwort ein zweites Register mit der Wrap-Zahl, nicht ein breiterer Zähler.

**O-07-3 — Genügt Doppelpufferung der UL-Mailbox unter Last?**
Die 14-ms-Frist (§3.8) ist gegen den theoretischen Höchstfall von vier belegten Uplink-Slots
gerechnet; gemessen sind ~19 Bursts/s [MESS 2026-05-17], also gut ein Viertel davon. Ob die
Software die Frist im Vollausbau (vier Sprachslots plus Signalisierung) hält, ist **nicht**
gemessen; hinzu kommt, dass ein Uplink-Slot nach §3.4 zwei Einträge erzeugen kann. Empfehlung:
mit zwei Bänken je Erzeuger bauen, **beide Hälften** von `REG_MB_UL_DROP_CNT` als
Abnahmekriterium führen und erst bei nachgewiesenem Verwurf auf drei Bänke des betroffenen
Erzeugers gehen (Kosten NUB: 3 456 bit
Blockspeicher). Ein Interrupt ist kein Ersatz, weil die Frist von der Verarbeitungsdauer
bestimmt wird, nicht von der Reaktionslatenz.

**O-07-4 — Rücksetzwerte der DL-Sync-Schwellen.**
Die Aufteilung der V1-Schwelle 13 in NTS 10 und STS 13 ist [ANNAHME] (§4). Der DL-Empfang
hat keine Sendewirkung, deshalb ist das Risiko klein; eine Falschalarm-Messreihe über
Schwelle 8…19 auf reinem Rauschen ist in `02_PHY_DL_RX §5` ohnehin gefordert und liefert die
belastbaren Werte. Empfehlung: die Reset-Werte nach dieser Messreihe festschreiben.

**O-07-5 — Erzeugung der Registerdefinitionen: welche Quelle ist normativ?**
R-07-17 verlangt eine Quelle für PL-Dekodierkonstanten, HAL-Definitionen und die
Reset-Wert-Tabelle der Testbench. Offen ist das Format und wer es pflegt. Empfehlung: eine
maschinenlesbare Tabelle im Repository, aus der ein Generator `tetra_regmap.vh`,
`tetra_hal_regs.h` und die Testvektortabelle erzeugt; dieses Kapitel bleibt die
menschenlesbare normative Beschreibung, und ein Build-Gate vergleicht beide. Die Alternative
— dieses Dokument selbst als Quelle zu parsen — ist abzulehnen: eine Prosa-Tabelle als
Build-Eingang ist zu brüchig.

**O-07-6 — Vorrangordnung, wenn ein Slot gleichzeitig einen Halteinhalt und einen
Warteschlangeneintrag hat.** §3.3 definiert die Betriebsarten, aber die Auflösung des
Konflikts (Sprachslot mit Halteinhalt, auf den zusätzlich eine Signalisierungs-PDU geroutet
wird) ist Slot-Inhaltsauswahl und gehört nach `04_PHY_TX_TDMA §3.4`. Dort ist die Priorität
heute „Füll-Override vor Warteschlange" festgelegt. Empfehlung: diese Reihenfolge auch für
V2 übernehmen und in `04` mit einem Verweis auf die Betriebsarten dieses Kapitels
ausschreiben, damit die Festlegung an einer Stelle steht.
