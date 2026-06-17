#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_code_analysis_pdf.py — erzeugt docs/CODE_ANALYSIS.pdf

Ausfuehrliche Code-/Protokoll-Analyse der TETRA-BS (Zynq-7020 + AD9361):
 Teil A Architektur · Teil B Physical Layer + Kanalcodierung ·
 Teil C Protokoll-PDUs (MAC/LLC/MM/CMCE, Bit-Layouts) ·
 Teil D Ablaeufe (Fragmentierung/Reassembly, Voice, Sequenzen, SW-Daemon) ·
 Teil E Referenz (Register, Module, Stand).

Alle Bitbreiten/Codier-Parameter/Register sind aus rtl/, sw/, scripts/decode_dl.py
verifiziert. Toolchain: matplotlib (Grafik->PNG) + reportlab (PDF), rein offline.
Reproduzierbar: python3 scripts/gen_code_analysis_pdf.py
"""
import os, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle, Circle
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.utils import ImageReader
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table,
                                TableStyle, Image, PageBreak, KeepTogether)

IMG = "/tmp/tetra_pdf_img"; os.makedirs(IMG, exist_ok=True)
OUT = "/home/kevin/claude-ralph/tetra/docs/CODE_ANALYSIS.pdf"

# Layer-Farbpalette
C = dict(phy="#cfe8ff", mac="#cdeccd", llc="#fff0c2", mle="#ffd9bf",
         cmce="#ecd2f5", mm="#ffd0d8", ctrl="#e2e2e2", hw="#d7d7ff",
         sw="#d9f2ec", hi="#ffe89c", ok="#cdeccd", bad="#ffd0d0",
         pad="#f0f0f0", train="#d0d0f5", tail="#e8e8e8")
EC = "#3a3a3a"; ACC = "#23507a"

def _save(fig, name):
    p = os.path.join(IMG, name)
    fig.savefig(p, dpi=200, bbox_inches="tight", facecolor="white", pad_inches=0.06)
    plt.close(fig); return p

class Canvas:
    def __init__(self, w, h, fs=None):
        self.W, self.H = w, h
        self.fig, self.ax = plt.subplots(figsize=fs or (w/6.0, h/6.0))
        self.ax.set_xlim(0, w); self.ax.set_ylim(0, h)
        self.ax.axis("off"); self.ax.set_aspect("equal"); self.b = {}
    def box(self, name, x, y, w, h, text, color="#eee", fs=9, bold=False, ec=EC, lw=1.1):
        self.ax.add_patch(FancyBboxPatch((x, y), w, h,
            boxstyle="round,pad=0.02,rounding_size=0.10", linewidth=lw,
            edgecolor=ec, facecolor=color))
        self.ax.text(x+w/2, y+h/2, text, ha="center", va="center",
                     fontsize=fs, weight="bold" if bold else "normal")
        self.b[name] = (x, y, w, h); return name
    def label(self, x, y, t, fs=8, ha="center", va="center", color="#222", bold=False, rot=0):
        self.ax.text(x, y, t, ha=ha, va=va, fontsize=fs, color=color,
                     weight="bold" if bold else "normal", rotation=rot)
    def _a(self, n, s):
        x, y, w, h = self.b[n]
        return {"t": (x+w/2, y+h), "b": (x+w/2, y), "l": (x, y+h/2),
                "r": (x+w, y+h/2), "c": (x+w/2, y+h/2)}[s]
    def arrow(self, a, sa, b, sb, color=EC, lw=1.5, rad=0.0, text=None, ls="-", style="-|>"):
        p1 = self._a(a, sa) if isinstance(a, str) else a
        p2 = self._a(b, sb) if isinstance(b, str) else b
        self.ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=13,
            lw=lw, color=color, linestyle=ls, connectionstyle=f"arc3,rad={rad}"))
        if text:
            mx, my = (p1[0]+p2[0])/2, (p1[1]+p2[1])/2
            self.ax.text(mx, my, text, fontsize=7, ha="center", va="center",
                         bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none"))
    def title(self, t): self.label(self.W/2, self.H-0.6, t, fs=12, bold=True)
    def save(self, n): return _save(self.fig, n)

def draw_bitfield(fields, fname, row_units=62.0, u=0.62, minw=6.4, bh=3.0, gap=4.8):
    rows, row, used, off = [], [], 0.0, 0
    for lab, n, ck in fields:
        w = minw if not n else max(minw, min(n, 28)*u)
        if used + w > row_units and row:
            rows.append(row); row, used = [], 0.0
        row.append((lab, n, ck, used, w, off)); used += w; off = (off+n) if n else off
    if row: rows.append(row)
    fig, ax = plt.subplots(figsize=(11.2, 0.5+len(rows)*0.95)); ax.axis("off")
    maxw = max(sum(f[4] for f in r) for r in rows)
    ax.set_xlim(-1, maxw+2); ax.set_ylim(-0.7, len(rows)*gap)
    for ri, r in enumerate(rows):
        y = (len(rows)-1-ri)*gap; x = 0
        for lab, n, ck, _, w, foff in r:
            ax.add_patch(Rectangle((x, y), w, bh, linewidth=1.0, edgecolor=EC, facecolor=C.get(ck, "#eee")))
            ax.text(x+w/2, y+bh*0.64, lab, ha="center", va="center", fontsize=7.0)
            ax.text(x+w/2, y+bh*0.24, (f"{n}b" if n else "var"), ha="center", va="center", fontsize=7.0, weight="bold")
            ax.text(x+0.05, y-0.30, str(foff), ha="left", va="top", fontsize=6.0, color="#555")
            x += w
        end = (r[-1][5]+r[-1][1]) if r[-1][1] else None
        ax.text(x+0.05, y-0.30, str(end) if end is not None else "→", ha="left", va="top", fontsize=6.0, color="#555")
    return _save(fig, fname)

def draw_strip(title, blocks, fname, total=255, unit="Sym"):
    fig, ax = plt.subplots(figsize=(11.2, 1.7)); ax.axis("off")
    ax.set_xlim(0, total); ax.set_ylim(-1.4, 2.6)
    ax.set_title(title, fontsize=10, weight="bold")
    x = 0
    for lab, n, ck in blocks:
        ax.add_patch(Rectangle((x, 0), n, 2.0, linewidth=1.0, edgecolor=EC, facecolor=C.get(ck, "#eee")))
        if n >= 6:
            ax.text(x+n/2, 1.25, lab, ha="center", va="center", fontsize=6.8)
            ax.text(x+n/2, 0.5, f"{n}", ha="center", va="center", fontsize=6.6, weight="bold")
        else:
            ax.text(x+n/2, 2.35, lab, ha="center", va="bottom", fontsize=6.0, rotation=0)
            ax.text(x+n/2, 0.7, f"{n}", ha="center", va="center", fontsize=6.0, weight="bold")
        x += n
    ax.text(0, -0.9, f"0 {unit}", fontsize=6, color="#555")
    ax.text(total, -0.9, f"{total} {unit}", ha="right", fontsize=6, color="#555")
    return _save(fig, fname)

# =====================================================================
# FIGUREN
# =====================================================================
def g_arch():
    c = Canvas(66, 42, fs=(11, 7.2)); c.title("System-Architektur — PS/PL")
    c.box("ps", 1, 25, 31, 14.5, "", "#eef0ff", lw=1.4); c.label(16.5, 38.4, "Zynq PS — ARM / Linux  (sw/)", 9.5, bold=True)
    c.box("si",  2, 31, 14, 4.4, "tetra_sysinfo\nZell-Config · SYSINFO/BNCH", C["sw"], 7.4)
    c.box("ad",  16.7, 31, 14.5, 4.4, "tetra_attach_daemon\nAttach·Call·SDS·Voice", C["sw"], 7.4)
    c.box("um",  2, 26, 14, 3.6, "tetra_ul_mon\nUL-Monitor", C["sw"], 7.4)
    c.box("tt",  16.7, 26, 14.5, 3.6, "tetra_tx_transport\nReply-Mailbox-Staging", C["sw"], 7.4)
    c.box("pl", 34, 18, 31, 21.5, "", "#efefff", lw=1.4); c.label(49.5, 38.4, "Zynq PL — FPGA  (rtl/)", 9.5, bold=True)
    c.box("regs", 35, 33, 29, 3.6, "tetra_axi_lite_regs + Mailboxen  (0x43C00000)", C["ctrl"], 7.6, bold=True)
    c.box("lmac", 35, 28, 29, 3.8, "LMAC: Encoder · Decoder · Parser · FSMs", C["mac"], 8)
    c.box("tx", 35, 22.5, 14, 3.8, "TX-Kette\n(rtl/tx)", C["phy"], 8)
    c.box("rx", 50, 22.5, 14, 3.8, "RX-Kette\n(rtl/rx)", C["phy"], 8)
    c.box("rf", 42, 9.5, 15, 4.8, "AD9361 RF\nDL/TX 438.25 MHz\nUL/RX = DL−Duplex", C["hw"], 8, bold=True)
    c.arrow("ad", "r", (34, 34.8), None, text="AXI"); c.arrow("si", "r", (34.6, 33.6), None, rad=-0.12)
    c.label(33, 16.5, "AXI-Lite: Reply-Mailbox · Voice-Filler · DEMAND-Poll · RX-Mailboxen", 6.6, color="#555")
    c.arrow("regs", "b", "lmac", "t"); c.arrow("lmac", "b", "tx", "t", rad=0.1); c.arrow("lmac", "b", "rx", "t", rad=-0.1)
    c.arrow("tx", "b", "rf", "t", rad=0.12, text="type-5"); c.arrow("rf", "t", "rx", "b", rad=0.12, text="IQ")
    c.arrow((57, 24.4), None, (63.5, 29.5), None, rad=-0.3, color="#1a6", text="RX-Mailboxen → SW")
    return c.save("arch.png")

def g_dataflow():
    c = Canvas(72, 40, fs=(12, 6.7)); c.title("TX/RX-Datenfluss (Modulebene)")
    # TX row
    c.label(4, 37, "TX (DL)", 9, bold=True, color=ACC)
    c.box("mle", 1, 31, 12, 4, "MLE-Reg-FSM\nslotgrant-FSM\ndl_pdu_builder", C["mac"], 6.8)
    c.box("q", 14.5, 31.5, 9, 3, "dl_signal_queue", C["mac"], 7)
    c.box("sch", 25, 31.5, 9, 3, "dl_signal_\nscheduler", C["mac"], 7)
    c.box("disp", 36, 31, 11, 4, "burst_dispatcher\n(static | voice/\nsds-filler-override)", C["mac"], 6.6)
    c.box("enc", 48.5, 31, 10.5, 4, "sch_f / sch_hd /\naach / sb1\nEncoder", C["phy"], 6.8)
    c.box("mod", 60.5, 31.5, 10.5, 3, "π/4-DQPSK →\nRRC → TX-FE", C["phy"], 6.8)
    for a, b in [("mle","q"),("q","sch"),("sch","disp"),("disp","enc"),("enc","mod")]:
        c.arrow(a, "r", b, "l")
    c.box("vf", 36, 25.5, 11, 3.2, "voice_filler /\nsds-fill", C["sw"], 6.8)
    c.arrow("vf", "t", "disp", "b", text="override TN")
    # RX row
    c.label(4, 20, "RX (UL)", 9, bold=True, color=ACC)
    c.box("fe", 1, 14, 11, 4, "rx_frontend\nDC·AGC·Decim·RRC", C["phy"], 6.6)
    c.box("tr", 13.5, 14.5, 8.5, 3, "timing_recovery", C["phy"], 6.8)
    c.box("sy", 23.5, 14.5, 8.5, 3, "sync_detect\n(Korrelation)", C["phy"], 6.6)
    c.box("de", 33.5, 14.5, 8.5, 3, "ul_pi4dqpsk\n_demod (soft)", C["phy"], 6.6)
    c.box("dec", 44, 13.5, 12, 5, "nub_capture\nsch_hu_decoder\nsch_f_decoder\n(Viterbi+CRC)", C["mac"], 6.4)
    c.box("par", 57.5, 15, 7, 3, "mac_access\n_parser", C["mac"], 6.6)
    c.box("re", 57.5, 10.5, 7, 3, "schf_reass-\nembly", C["mac"], 6.6)
    for a, b in [("fe","tr"),("tr","sy"),("sy","de"),("de","dec")]:
        c.arrow(a, "r", b, "l")
    c.arrow("dec", "r", "par", "l", rad=0.1); c.arrow("dec", "r", "re", "l", rad=-0.1)
    c.box("mb", 66, 12.5, 5.5, 4, "AXI-\nMailbox\n→ SW", C["sw"], 6.6, bold=True)
    c.arrow("par", "r", "mb", "l", rad=0.1); c.arrow("re", "r", "mb", "l", rad=-0.1)
    c.box("af", 1, 2.5, 70, 3, "AD9361:  TX (type-5 dibits → IQ)            |            RX (IQ @ 72 kHz Post-RRC)", C["hw"], 7.4, bold=True)
    c.arrow("mod", "b", (66, 5.5), None, rad=0.2, color="#888"); c.arrow((6, 5.5), None, "fe", "b", rad=0.2, color="#888")
    return c.save("dataflow.png")

def g_tdma():
    c = Canvas(66, 28, fs=(11.4, 4.9)); c.title("TDMA-Rahmenhierarchie + Timing (ETSI §9)")
    c.box("hf", 1, 21.5, 64, 3.2, "Hyperframe = 60 Multiframes   ≈ 61.2 s", "#dde7ff", 8.5, bold=True)
    c.box("mf", 1, 16, 64, 3.2, "", "#e9f5e9", 8); c.label(33, 19.6, "Multiframe = 18 Frames ≈ 1.02 s   (FN18 = BNCH/BSCH-Kontrollframe)", 8.2, bold=True)
    fw = 64/18.0
    for i in range(18):
        c.box(f"f{i}", 1+i*fw, 16.1, fw-0.12, 2.9, str(i+1), C["hi"] if i == 17 else "#e9f5e9", 6.4)
    c.box("fr", 1, 10.5, 64, 3.2, "", "#fff0c2", 8); c.label(33, 14.1, "Frame = 4 Slots (TN) ≈ 56.67 ms", 8.2, bold=True)
    sw = 64/4.0; nm = ["TN1 = MCCH (Idle-MS)", "TN2", "TN3", "TN4 (Traffic/SYSINFO)"]
    for i in range(4):
        c.box(f"s{i}", 1+i*sw, 10.6, sw-0.2, 2.9, nm[i], "#fff0c2", 7.2)
    c.box("sl", 1, 5, 64, 3.2, "Slot = 255 Symbole = 510 Bit ≈ 14.167 ms   (Symbolrate 18 ksym/s, 36 kbit/s)", "#cfe8ff", 7.6, bold=True)
    c.arrow("hf", "b", "mf", "t"); c.arrow("f0", "b", "fr", "t"); c.arrow("s0", "b", "sl", "t")
    return c.save("tdma.png")

def g_constellation():
    fig, ax = plt.subplots(figsize=(5.4, 5.4)); ax.set_aspect("equal"); ax.axis("off")
    th = np.linspace(0, 2*np.pi, 300); ax.plot(np.cos(th), np.sin(th), color="#cccccc", lw=1)
    ax.axhline(0, color="#eee", lw=0.8); ax.axvline(0, color="#eee", lw=0.8)
    for idx in range(8):
        a = np.deg2rad(idx*45); x, y = np.cos(a), np.sin(a)
        ax.plot(x, y, "o", color=ACC, ms=11, zorder=3)
        ax.text(x*1.26, y*1.26, f"idx {idx}\n{idx*45}°", ha="center", va="center", fontsize=7.2)
    # Beispiel-Uebergaenge von idx0
    for didx, lbl in [(1, "+π/4"), (3, "+3π/4"), (7, "−π/4"), (5, "−3π/4")]:
        a = np.deg2rad(didx*45)
        ax.add_patch(FancyArrowPatch((1, 0), (np.cos(a), np.sin(a)), arrowstyle="-|>",
                     mutation_scale=10, color="#a33", lw=1.0, connectionstyle="arc3,rad=0.18"))
    ax.set_xlim(-1.55, 1.55); ax.set_ylim(-1.55, 1.55)
    ax.set_title("π/4-DQPSK — 8 Phasenzustände\n(rote Pfeile: ΔΦ ab idx0)", fontsize=9.5, weight="bold")
    return _save(fig, "constell.png")

def g_punct():
    fig, ax = plt.subplots(figsize=(6.4, 2.6)); ax.axis("off")
    ax.set_xlim(-2, 9); ax.set_ylim(-1, 5)
    ax.set_title("RCPC Mother r1/4 → Punktierung r2/3  (Periode 8, behalte {0,1,4})", fontsize=9, weight="bold")
    gens = ["G1=0x13", "G2=0x1D", "G3=0x17", "G4=0x1B"]
    keep = {(0,0),(1,0),(0,1)}  # (gen, inputbit): col index 0,1,4 → bit0/G1,bit0/G2,bit1/G1
    for bi in range(2):       # input bit 0/1
        for gi in range(4):   # G1..G4
            col = (C["phy"] if (gi, bi) in keep else C["pad"])
            x = bi*4.3 + gi; y = 3-gi*0  # lay gens vertically
            ax.add_patch(Rectangle((bi*4.4+0.2, 3-gi*0.9), 0.8, 0.8, edgecolor=EC, lw=0.9,
                         facecolor=(C["phy"] if (gi, bi) in keep else C["pad"])))
            ax.text(bi*4.4+0.6, 3-gi*0.9+0.4, gens[gi][:2], ha="center", va="center", fontsize=6.5)
        ax.text(bi*4.4+0.6, 4.2, f"Eingangsbit {bi}", ha="center", fontsize=7)
    ax.text(2.0, -0.6, "gefüllt = übertragen (G1,G2 für gerade · G1 für ungerade) → 2 in : 3 out",
            ha="center", fontsize=7, color="#444")
    return _save(fig, "punct.png")

def g_pipeline(title, stages, fname, ck="phy"):
    n = len(stages); c = Canvas(8+n*11, 13, fs=(1.0+n*1.55, 2.5)); c.title(title)
    bw, gap, y = 9.0, 2.0, 4.0; prev = None
    for i, (lab, sub) in enumerate(stages):
        x = 2+i*(bw+gap); nm = f"s{i}"; c.box(nm, x, y, bw, 4.0, lab, C[ck], 8.0, bold=True)
        if sub: c.label(x+bw/2, y-0.9, sub, 6.7, color="#444")
        if prev: c.arrow(prev, "r", nm, "l")
        prev = nm
    return c.save(fname)

def g_rxfront():
    return g_pipeline("RX-Frontend + Demod (UL)", [
        ("DC-Offset\nentfernen", "I/Q"), ("AGC", "Pegel"), ("Dezimation", "→ 72 kHz"),
        ("RRC-Matched\nFilter", "√Nyquist"), ("Timing-\nRecovery", "Symboltakt"),
        ("Sync-Detect", "TS-Korrelat."), ("π/4-DQPSK\nSoft-Demod", "→ Soft-Bits")], "rxfront.png", "phy")

def g_dl_frag():
    c = Canvas(66, 41, fs=(11.4, 7.0)); c.title("DL lange SDS — MAC-Fragmentierung (BS → MS-B)")
    c.box("tm", 4, 34, 58, 3.2, "TM-SDU = LLC BL-DATA(NS) + MLE-PD=CMCE + CMCE D-SDS-DATA  (z.B. 757 Bit)", C["llc"], 8, bold=True)
    bw = 14.0
    labs = [("Block 0 (SCH/F)", "MAC-RES BL-ACK→Sender (LI=6,48b)\n+ MAC-RES Frag-Start→B (LI=63,43b)\n+ TM-SDU[0:177]"),
            ("MAC-FRAG (SCH/F)", "Hdr 4b (type01,sub0,fill0)\n+ TM-SDU 264b"),
            ("MAC-FRAG (SCH/F)", "Hdr 4b\n+ TM-SDU 264b"),
            ("MAC-END (SCH/F)", "Hdr 4b (type01,sub1,fill1)\n+ Rest + Fill-Marker '1'")]
    for i in range(4):
        x = 3+i*(bw+2.0)
        c.box(f"b{i}", x, 24, bw, 7.0, "", C["mac"], 8); c.label(x+bw/2, 30.2, labs[i][0], 7.4, bold=True)
        c.label(x+bw/2, 26.8, labs[i][1], 6.2)
        c.arrow("tm", "b", f"b{i}", "t", color="#999", lw=1.0)
        c.box(f"e{i}", x, 19.5, bw, 2.6, "SCH/F-Encode\n268 → 432 type-5", C["phy"], 6.6); c.arrow(f"b{i}", "b", f"e{i}", "t")
        c.box(f"a{i}", x, 15.5, bw, 2.6, "NDB1 Voice-Filler\nTN1, FN ≤ 16", C["ctrl"], 6.4); c.arrow(f"e{i}", "b", f"a{i}", "t")
    c.box("sg", 18, 9, 30, 3.8, "danach: Slot-Grant NDB2/SCH/HD\nAL-SETUP + sg_element=0x00  (= Gold #822)", C["hi"], 7.4, bold=True)
    c.arrow("a3", "b", "sg", "r", rad=-0.2)
    c.label(33, 6.2, "W9[14]=1 → RTL tetra_pre_reply_slotgrant-FSM weist MS-B einen UL-Subslot zu", 7, color="#444")
    c.box("fr", 3, 2, 60, 2.6, "Fill-Removal beim Empfänger (ETSI §23.4.3): letztes '1' + folgende '0' verwerfen → exakte TM-SDU-Grenze", C["bad"], 6.6)
    return c.save("dlfrag.png")

def g_reass_fsm():
    c = Canvas(60, 34, fs=(10.6, 6.0)); c.title("UL-Reassembly-FSM (tetra_ul_schf_reassembly.v)")
    st = {"idle":(3,26,"S_IDLE"),"start":(16,26,"S_START\nschreibe 62b\nfrag1"),
          "wait":(31,26,"S_WAIT\nt0-Timeout\n4 Frames"),"write":(45,26,"S_WRITE\nappend\nPayload"),
          "flush":(45,13,"S_FLUSH\nletztes Wort"),"emit":(24,13,"S_EMIT\nvalid+ssi+len")}
    for k,(x,y,t) in st.items():
        c.box(k, x, y, 12, 5.2 if "\n" in t else 3.2, t, C["mle"], 7.4, bold=True)
    c.arrow("idle","r","start","l",text="frag1_pulse"); c.arrow("start","r","wait","l",text="62b ok")
    c.arrow("wait","r","write","l",text="crc_ok\n&type01"); c.arrow("write","t","wait","t",rad=-0.6,text="sub0 FRAG")
    c.arrow("write","b","flush","t",text="sub1 END"); c.arrow("flush","l","emit","r")
    c.arrow("emit","l","idle","b",rad=0.3,text="→ Mailbox"); c.arrow("wait","b","emit","t",rad=0.3,color="#a00",ls="--",text="t0=0 drop")
    c.box("ch", 2, 3.5, 56, 6, "", "#f7f7f7", 8); c.label(30, 8.8, "On-Air-Kette (lange SDS, UL):", 8, bold=True)
    c.label(30, 6.6, "MAC-ACCESS(frag=1) SCH/HU → Start 62b (on-air 30..91)", 7.2)
    c.label(30, 5.3, "N× MAC-FRAG SCH/F → info[4..267] (264b) · MAC-END → info[10..267] (258b)", 7.2)
    c.label(30, 4.1, "Body 32-bit-wortweise (MSB-first) → AXI-Read-Mailbox → SW", 7.2)
    return c.save("reassfsm.png")

def g_voice():
    c = Canvas(66, 20, fs=(11.4, 3.5)); c.title("Voice-Pfad (Gruppen-/Einzelruf)")
    c.box("ms", 1, 12, 11, 4, "MS (TCH/S)\nNUB-Bursts", C["hw"], 7)
    c.box("nub", 14, 12.5, 11, 3, "ul_nub_capture\n(Soft)", C["phy"], 6.8)
    c.box("dec", 27, 12.5, 11, 3, "TCH/S-Decode\nnub_to_schf", C["mac"], 6.6)
    c.box("cod", 40, 12.5, 12, 3, "tetra_bs_tch_s\nETSI-Codec", C["sw"], 6.6)
    c.box("out", 54, 12.5, 11, 3, "Audio /\nGruppen-Relay", C["sw"], 6.8)
    for a,b in [("ms","nub"),("nub","dec"),("dec","cod"),("cod","out")]: c.arrow(a,"r",b,"l")
    c.box("alloc", 14, 5, 38, 4, "call_fsm: voice_active_mask[TS] → burst_dispatcher Voice-Override (DL)\nPer-TS Quiet-Detection 300 ms · voice_ts-Allocator deterministisch", C["hi"], 6.8)
    c.arrow("cod","b","alloc","t",rad=0.1)
    return c.save("voice.png")

def g_daemon():
    c = Canvas(40, 40, fs=(7.2, 7.2)); c.title("attach_daemon Hauptschleife")
    c.box("poll", 8, 34, 24, 3.4, "Poll RX-Mailboxen (AXI)", C["sw"], 7.4, bold=True)
    c.box("dem", 2, 28, 17, 3.6, "DEMAND?\nmm=2 Attach / mm=7 Group", C["mac"], 6.8)
    c.box("sds", 21, 28, 17, 3.6, "UL-SDS?\nkurz / lang-Reass.", C["cmce"], 6.8)
    c.box("call", 2, 22, 17, 3.6, "U-SETUP/U-TX?\ncall_fsm", C["mle"], 6.8)
    c.box("relay", 21, 22, 17, 3.6, "Relay D-SDS-DATA\n+ BL-ACK", C["cmce"], 6.8)
    c.box("voice", 2, 16, 17, 3.6, "Voice-Pipe-\nService", C["sw"], 6.8)
    c.box("dlf", 21, 16, 17, 3.6, "DL-Frag-Delivery\n(lange SDS)", C["cmce"], 6.8)
    c.box("tx", 8, 10, 24, 3.4, "reply_write / voice_filler → AXI", C["sw"], 7.2, bold=True)
    c.arrow("poll","b","dem","t",rad=0.1); c.arrow("poll","b","sds","t",rad=-0.1)
    for n in ["dem","sds","call","relay","voice","dlf"]:
        c.arrow(n,"b",(20,13.4),None,color="#aaa",lw=0.9)
    c.arrow("tx","l",(2,12),None,rad=0.4,color=ACC); c.arrow((2,12),None,"poll","l",rad=0.4,color=ACC,text="loop")
    return c.save("daemon.png")

def g_stack():
    c = Canvas(46, 30, fs=(8.4, 5.5)); c.title("Protokollstack")
    L = [("PHY — Burst/type-5 (π/4-DQPSK, RRC)","phy",24.5),
         ("MAC — RESOURCE | FRAG/END | BROADCAST | ACCESS(UL)","mac",20.5),
         ("LLC — BL-ADATA/DATA/UDATA/ACK | AL-SETUP (+FCS)","llc",16.5),
         ("MLE — PD: 1=MM 2=CMCE 4=SNDCP 5=MLE","mle",12.5)]
    for i,(t,ck,y) in enumerate(L): c.box(f"L{i}",2,y,42,3.4,t,C[ck],7.6,bold=True)
    c.box("mm",2,8,20,3.4,"MM — Attach / Loc-Update",C["mm"],7.4,bold=True)
    c.box("cmce",24,8,20,3.4,"CMCE — Call / SDS / Status",C["cmce"],7.4,bold=True)
    for a,b in [("L0","L1"),("L1","L2"),("L2","L3")]: c.arrow(a,"b",b,"t")
    c.arrow("L3","b","mm","t",rad=0.1); c.arrow("L3","b","cmce","t",rad=-0.1)
    return c.save("stack.png")

def g_seq(actors, msgs, title, fname, w=58, hper=3.0):
    H = 10+len(msgs)*hper; c = Canvas(w, H, fs=(w/6.0, H/6.0))
    c.label(w/2, H-1.3, title, 11.5, bold=True)
    n = len(actors); xs = [(w/n)*(i+0.5) for i in range(n)]; top = H-5.2; bot = 3
    for i, a in enumerate(actors):
        c.box(f"a{i}", xs[i]-7, top, 14, 2.6, a, C["ctrl"], 8, bold=True)
        c.ax.plot([xs[i], xs[i]], [bot, top], color="#bbb", lw=1.0, zorder=0)
    y = top-2.0
    for m in msgs:
        fi, ti, lab = m[0], m[1], m[2]; dashed = len(m)>3 and m[3]=="dash"; red = len(m)>3 and m[3]=="x"
        if fi == ti:
            c.ax.annotate("", xy=(xs[fi]+0.25, y-1.0), xytext=(xs[fi]+0.25, y), arrowprops=dict(arrowstyle="-|>", color="#555"))
            c.label(xs[fi]+9, y-0.5, lab, 6.9, ha="center")
        else:
            col = "#a00" if red else EC; ls = (0,(4,3)) if dashed else "-"
            c.ax.annotate("", xy=(xs[ti], y), xytext=(xs[fi], y), arrowprops=dict(arrowstyle="-|>", color=col, lw=1.4, linestyle=ls))
            c.label((xs[fi]+xs[ti])/2, y+0.55, lab, 6.9, ha="center", color=col)
            if red: c.label((xs[fi]+xs[ti])/2, y, "✗", 11, color="#a00")
        y -= hper
    return c.save(fname)

print("rendering figures ...")
P_ARCH=g_arch(); P_FLOW=g_dataflow(); P_TDMA=g_tdma(); P_CON=g_constellation(); P_PUNCT=g_punct()
P_SCHF=g_pipeline("SCH/F-Codierkette (Encode, 268 → 432 type-5)", [
    ("PDU\n268","type-1"),("+CRC16\n+Tail4","→288"),("RCPC\nr1/4","Mother 1152"),
    ("Punktur\n2/3","→432 t-4"),("Interleave\na=103","N=432"),("Scramble\nLFSR","→432 t-5")], "schf.png")
P_RXD=g_pipeline("UL-SCH/F-Decode (= Umkehrung)", [
    ("type-5\n432","soft"),("Descr.+\nDeint.","a=103"),("Depunkt.\n2/3→1/4","1152"),
    ("Viterbi\nK=5 r1/4","→288"),("Tail −4","268+16"),("CRC16","Info 268")], "rxd.png")
P_RXF=g_rxfront(); P_STACK=g_stack(); P_DLFRAG=g_dl_frag(); P_REASS=g_reass_fsm()
P_VOICE=g_voice(); P_DAEMON=g_daemon()
NDB=draw_strip("NDB — Normal Downlink Burst (255 Symbole)", [
    ("TAIL1",6,"tail"),("HA",1,"ctrl"),("blk1 (SCH/F bzw. SCH/HD #1)",108,"mac"),("bb1",7,"phy"),
    ("NTS",11,"train"),("bb2",8,"phy"),("blk2",108,"mac"),("HA",1,"ctrl"),("TAIL2",5,"tail")], "ndb.png")
SDB=draw_strip("SDB — Synchronization Downlink Burst (255 Symbole)", [
    ("TAIL1",6,"tail"),("HC",1,"ctrl"),("FC",40,"phy"),("sb1 (BSCH)",60,"mac"),("STS",19,"train"),
    ("bb",15,"phy"),("bkn2 (BNCH)",108,"mac"),("HD",1,"ctrl"),("TAIL2",5,"tail")], "sdb.png")
# Bitfelder
BF_MACRES=draw_bitfield([("type",2,"mac"),("fill",1,"mac"),("pog",1,"mac"),("enc",2,"mac"),("ra",1,"mac"),
    ("LI",6,"mac"),("addr_typ",3,"mac"),("SSI",24,"mac"),("pc",1,"mac"),("sg",1,"mac"),("ca",1,"mac"),
    ("TM-SDU (LLC)",None,"llc")], "bf_macres.png")
BF_FRAG=draw_bitfield([("type=01",2,"mac"),("sub",1,"mac"),("fill",1,"mac"),("TM-SDU-Fortsetzung",None,"llc")], "bf_frag.png")
BF_MACACC=draw_bitfield([("type",1,"mac"),("fill",1,"mac"),("enc",1,"mac"),("addr_typ",2,"mac"),("address",24,"mac"),
    ("opt",1,"mac"),("len/cap",1,"mac"),("len/resv",5,"mac"),("TL-SDU (LLC)",None,"llc")], "bf_macacc.png")
BF_SYS=draw_bitfield([("main_carrier",12,"mac"),("band",4,"mac"),("offset",2,"mac"),("duplex",3,"mac"),
    ("rev",1,"mac"),("sec_cch",2,"mac"),("txpwr",3,"mac"),("rxlev_min",4,"mac"),("access",4,"mac"),
    ("dl_to",4,"mac"),("opt_sel",2,"mac"),("opt_value",20,"mac")], "bf_sys.png")
BF_LLC=draw_bitfield([("pdu_type",4,"llc"),("N(R)?",1,"llc"),("N(S)?",1,"llc"),("Payload (TM-SDU)",None,"mle")], "bf_llc.png")
BF_AACH=draw_bitfield([("Header",2,"ctrl"),("Field-1/DL-usage",6,"ctrl"),("Field-2/UL-usage",6,"ctrl")], "bf_aach.png")
BF_SDS=draw_bitfield([("pdu=15",5,"cmce"),("CPTI=1",2,"cmce"),("calling_ssi",24,"cmce"),("SDTI=3",2,"cmce"),
    ("LI(Bit)",11,"cmce"),("UDD (SDS-TL)",None,"cmce"),("o",1,"cmce")], "bf_sds.png")
BF_DSETUP=draw_bitfield([("pdu=7",5,"cmce"),("call_id",14,"cmce"),("c_timeout",4,"cmce"),("hook",1,"cmce"),
    ("simplex",1,"cmce"),("BSI",8,"cmce"),("tx_grant",2,"cmce"),("trp",1,"cmce"),("priority",4,"cmce"),
    ("o=1",1,"cmce"),("notif",1,"mle"),("tmp",1,"mle"),("CPTIp",1,"mle"),("CPTI",2,"mle"),("calling_ssi",24,"mle"),("m",1,"mle")], "bf_dsetup.png")
BF_DCONN=draw_bitfield([("pdu=2",5,"cmce"),("call_id",14,"cmce"),("c_timeout",4,"cmce"),("hook",1,"cmce"),
    ("simplex",1,"cmce"),("tx_grant",2,"cmce"),("trp",1,"cmce"),("c_own",1,"cmce"),("o=1",1,"cmce"),
    ("p_prio",1,"mle"),("priority",4,"mle"),("p_bsi=0",1,"mle"),("p_tmp=0",1,"mle"),("p_notif=0",1,"mle"),("m",1,"mle")], "bf_dconn.png")
print("figures done.")

# ===================== reportlab =====================
ss = getSampleStyleSheet()
PART = ParagraphStyle("PART", parent=ss["Heading1"], fontSize=17, spaceBefore=4, spaceAfter=10, textColor=colors.white,
                      backColor=colors.HexColor("#13315c"), borderPadding=6, alignment=TA_CENTER)
H1 = ParagraphStyle("H1", parent=ss["Heading1"], fontSize=14, spaceBefore=10, spaceAfter=5, textColor=colors.HexColor("#13315c"))
H2 = ParagraphStyle("H2", parent=ss["Heading2"], fontSize=11, spaceBefore=7, spaceAfter=3, textColor=colors.HexColor("#23507a"))
BODY = ParagraphStyle("BODY", parent=ss["BodyText"], fontSize=8.8, leading=12, spaceAfter=4)
SMALL = ParagraphStyle("SMALL", parent=BODY, fontSize=7.6, leading=10)
CAP = ParagraphStyle("CAP", parent=BODY, fontSize=7.4, textColor=colors.HexColor("#666"), alignment=TA_CENTER, spaceAfter=9)
CELL = ParagraphStyle("CELL", parent=BODY, fontSize=7.4, leading=9.4, spaceAfter=0)
CELLB = ParagraphStyle("CELLB", parent=CELL, fontName="Helvetica-Bold")
CONTENT_W = A4[0]-3.0*cm
story = []
def P(t, s=BODY): story.append(Paragraph(t, s))
def gap(h=4): story.append(Spacer(1, h))
def cap(t):
    para = Paragraph(t, CAP)
    if story and isinstance(story[-1], Image):
        im = story.pop(); story.append(KeepTogether([im, para]))
    else:
        story.append(para)
def img(path, w=CONTENT_W, maxh=22.5*cm, capt=None):
    ir = ImageReader(path); iw, ih = ir.getSize(); asp = ih/float(iw)
    ww = w; hh = ww*asp
    if hh > maxh: hh = maxh; ww = hh/asp
    im = Image(path, width=ww, height=hh, hAlign="CENTER")
    if capt:
        story.append(KeepTogether([im, Paragraph(capt, CAP)]))
    else:
        story.append(im)
def table(data, widths, header=True):
    wr = []
    for ri, row in enumerate(data):
        rr = []
        for cell in row:
            st = CELL
            if header and ri == 0:
                st = ParagraphStyle("hc", parent=CELL, textColor=colors.white, fontName="Helvetica-Bold")
            rr.append(Paragraph(str(cell), st))
        wr.append(rr)
    t = Table(wr, colWidths=widths, repeatRows=1 if header else 0)
    sty = [("GRID",(0,0),(-1,-1),0.5,colors.HexColor("#bbb")),("VALIGN",(0,0),(-1,-1),"MIDDLE"),
           ("TOPPADDING",(0,0),(-1,-1),2.2),("BOTTOMPADDING",(0,0),(-1,-1),2.2),
           ("LEFTPADDING",(0,0),(-1,-1),3),("RIGHTPADDING",(0,0),(-1,-1),3)]
    if header:
        sty += [("BACKGROUND",(0,0),(-1,0),colors.HexColor("#23507a")),
                ("ROWBACKGROUNDS",(0,1),(-1,-1),[colors.white, colors.HexColor("#f1f5fb")])]
    t.setStyle(TableStyle(sty)); story.append(t)
def pdu(title, src, imgpath, rows, widths, note=None):
    P(title, H2); img(imgpath, w=CONTENT_W); P(f"<font color='#777' size=7>Quelle: {src}</font>", SMALL)
    table(rows, widths)
    if note: P(note, SMALL)
    gap(6)

# ---------- Titel ----------
story.append(Spacer(1, 3.2*cm))
P("TETRA-Basisstation auf Zynq-7020 + AD9361", ParagraphStyle("t",parent=H1,fontSize=21,alignment=TA_CENTER,textColor=colors.HexColor("#13315c")))
P("Code-Analyse · Physical Layer · Kanalcodierung · Nachrichtenformate · Reassembly", ParagraphStyle("t2",parent=H2,fontSize=12.5,alignment=TA_CENTER,spaceBefore=2))
gap(16)
P("Was ist wie codiert · was steht an welcher Stelle in den Nachrichten · Fragmentierungs- und Reassembly-Abläufe", ParagraphStyle("t3",parent=BODY,fontSize=10,alignment=TA_CENTER,textColor=colors.HexColor("#555")))
gap(26)
P("Inhalt: A System &amp; Architektur · B Physical Layer + Kanalcodierung · C Protokoll-PDUs (MAC/LLC/MM/CMCE) · D Abläufe (Fragmentierung/Reassembly, Voice, Sequenzen, SW-Daemon) · E Referenz", ParagraphStyle("toc",parent=SMALL,alignment=TA_CENTER))
gap(26)
P("Alle Bitbreiten, Codier-Parameter und Register-Offsets sind aus dem RTL/SW dieses Repos verifiziert (rtl/, sw/, scripts/decode_dl.py). Stand 2026-06-17.", ParagraphStyle("t4",parent=SMALL,alignment=TA_CENTER,textColor=colors.HexColor("#777")))
story.append(PageBreak())

# ======================= TEIL A =======================
P("Teil A — System &amp; Architektur", PART)
P("1  System-Architektur", H1)
P("Die Basisstation teilt sich in <b>PS</b> (ARM/Linux, <font name='Courier'>sw/</font>) und <b>PL</b> (FPGA, <font name='Courier'>rtl/</font>). Zeitkritisches PHY, Burst-Timing und Encode/Decode liegen im FPGA (deterministische TDMA-Grenzen, kein Linux-Jitter); die Protokoll-Logik (Registrierung, Call-State, SDS-Routing) liegt in SW und kommuniziert ausschließlich über AXI-Lite-Register + Mailboxen (Basis <font name='Courier'>0x43C00000</font>).")
img(P_ARCH); cap("Abb. 1 — PS/PL-Schnitt.")
story.append(PageBreak())
img(P_FLOW); cap("Abb. 2 — Datenfluss auf Modulebene: TX-Producer → Queue/Scheduler → Dispatcher → Encoder → Modulator; RX-Frontend → Demod → Decoder → Mailboxen.")
story.append(PageBreak())

# ======================= TEIL B =======================
P("Teil B — Physical Layer + Kanalcodierung", PART)
P("2  TDMA-Rahmen &amp; Timing", H1)
P("TDMA mit 4 Zeitschlitzen (TN) pro Frame, 18 Frames pro Multiframe, 60 Multiframes pro Hyperframe. Symbolrate 18 ksym/s → 36 kbit/s; ein Slot = 255 Symbole = 510 Bit ≈ 14.167 ms. <b>FN18</b> ist der Kontrollframe (BNCH/BSCH) — die lange-SDS-Kette muss ihn meiden. <b>TN1</b> = MCCH.")
img(P_TDMA); cap("Abb. 3 — Rahmenhierarchie mit absoluten Zeiten.")
gap()
P("Burst-Aufbau (255 Symbole)", H2)
P("Ein Burst füllt einen Slot. Der <b>NDB</b> (Normal Downlink Burst) trägt zwei 108-Symbol-Blöcke (zusammen SCH/F bei NDB1, oder 2× SCH/HD bei NDB2), die AACH (bb, 15 Symbole) und eine Normal-Training-Sequenz (NTS). Der <b>SDB</b> (Sync Burst) trägt das BSCH (sb1) + BNCH (bkn2) + Sync-Training (STS).")
img(NDB, w=CONTENT_W); img(SDB, w=CONTENT_W)
cap("Abb. 4/5 — Symbol-Maps NDB und SDB (tetra_burst_builder.v). TAIL=Tailbits, HA/HC/HD=Phase-Adjust, NTS/STS=Training, bb=AACH.")
story.append(PageBreak())

P("3  Modulation — π/4-DQPSK", H1)
P("Die Type-5-Dibits werden differenziell phasencodiert: jedes Dibit erhöht den 3-Bit-Phasenindex (8 Zustände à 45°). Decodiert wird über die Phasendifferenz zweier aufeinanderfolgender Symbole.")
img(P_CON, w=9*cm); cap("Abb. 6 — Konstellation (tetra_pi4dqpsk_mod.v). IQ = cos/sin(idx·45°)·32767.")
table([["Dibit (b1 b0)","ΔΦ","Index-Inkrement"],["00","+π/4","+1"],["01","+3π/4","+3"],["10","−π/4","+7 (≡ −1)"],["11","−3π/4","+5 (≡ −3)"]],
      [4.5*cm,4.5*cm,CONTENT_W-9*cm])
P("Sendeseitig folgt ein <b>RRC-Filter</b> (Root-Raised-Cosine, ETSI §5.4) zur Bandbegrenzung; empfangsseitig dasselbe als Matched-Filter. Symboltakt exakt 18 000 Hz aus AD9361-DATA_CLK (18.432 MHz ÷ 1024).", SMALL)
story.append(PageBreak())

P("4  Kanalcodierung — „Was ist wie codiert“", H1)
P("ETSI-Nomenklatur: <b>type-1</b> = MAC-PDU-Bits → <b>type-2</b> = +CRC+Tail → <b>type-3</b> = nach Faltung → <b>type-4</b> = nach Punktierung → <b>type-5</b> = nach Interleave+Scramble (gesendet). Alle Signalisierungs-Bursts nutzen dieselbe Kette; AACH nutzt statt Faltung einen Reed-Muller-Blockcode.")
img(P_SCHF, w=CONTENT_W); cap("Abb. 7 — SCH/F (268→432). SCH/HD identisch, nur 124→216.")
gap()
table([["Kanal","type-1","+CRC16+Tail → type-3","Mother → Punktur → type-4/5","Interleaver"],
       ["SCH/F","268","288","r1/4 → r2/3 → 432","a=103, N=432"],
       ["SCH/HD","124","144","r1/4 → r2/3 → 216","a=101, N=216"],
       ["AACH","14","— (kein CRC)","RM(30,14) → 30","—"]],
      [1.8*cm,1.3*cm,3.6*cm,4.3*cm,CONTENT_W-11*cm])
gap(5)
P("4.1  CRC-16 (FCS)", H2)
P("CRC-16-CCITT (X.25): <font name='Courier'>G(x)=x¹⁶+x¹²+x⁵+1 = 0x1021</font>, Init <font name='Courier'>0xFFFF</font>, Final-XOR <font name='Courier'>0xFFFF</font>, RX-Residuum <font name='Courier'>0x1D0F</font> (tetra_crc16.v). 16 FCS- + 4 Tail-Bits vor der Faltung.")
P("4.2  Faltungscode (RCPC)", H2)
P("Mother-Code K=5, Polynome <font name='Courier'>G1=0x13 (10011), G2=0x1D (11101), G3=0x17 (10111), G4=0x1B (11011)</font>. Punktierung auf r2/3 behält pro Periode 8 die Positionen {0,1,4} — nur G1/G2 überleben (gerades Bit: G1,G2; ungerades: G1). Decodierung Soft-Viterbi (tetra_ul_viterbi_r14).")
img(P_PUNCT, w=12*cm); cap("Abb. 8 — Punktierungsmuster: 2 Eingangsbits → 8 Mother-Bits → 3 gesendet (r2/3).")
P("4.3  Reed-Muller RM(30,14) — AACH", H2)
P("Aus RM(2,5)=(32,16,8) durch Verkürzung (Zeilen x0/Konstante, Spalten 00000/00001 entfernt). <font name='Courier'>d_min≥8 → t=3</font> korrigierbare Fehler. Encoder <font name='Courier'>c = u·G mod 2</font> (14×30-Matrix); Decoder Minimum-Distance über alle 2¹⁴ Codeworte (tetra_reed_muller.v).")
P("4.4  Interleaver", H2)
P("Multiplikativ (ETSI §8.2.4.1): <font name='Courier'>out[j-1]=in[k-1]</font>, <font name='Courier'>j=1+(a·k) mod N</font>. SCH/F a=103/N=432, SCH/HD a=101/N=216.")
P("4.5  Scrambler", H2)
P("Fibonacci-LFSR, Taps (Bit-0=LSB): <font name='Courier'>0,6,9,10,16,20,21,22,24,25,27,28,30,31</font>. Zellspezifischer 32-Bit-Seed: <font name='Courier'>init=(MCC&amp;0x3FF)&lt;&lt;22 | (MNC&amp;0x3FFF)&lt;&lt;8 | (CC&amp;0x3F)&lt;&lt;2 | 3</font>. Identisch für BSCH/AACH/SCH-HD/SCH-F.")
gap()
P("4.6  RX-Decodierung", H2)
img(P_RXF, w=CONTENT_W); cap("Abb. 9 — RX-Frontend + Demod (tetra_rx_frontend.v, _timing_recovery, _sync_detect, _ul_pi4dqpsk_demod).")
img(P_RXD, w=CONTENT_W); cap("Abb. 10 — SCH/F-Decode = Umkehrung der Encode-Kette. Soft-Puffer in BRAM.")
story.append(PageBreak())

# ======================= TEIL C =======================
P("Teil C — Protokoll-PDUs („Was steht an welcher Stelle“)", PART)
P("Pro PDU: Bitfeld-Grafik (Feldreihenfolge, Bitbreite, fortlaufender Offset) + exakte Positionstabelle. Farbcodes: <font backColor='#cdeccd'>&nbsp;MAC&nbsp;</font> <font backColor='#fff0c2'>&nbsp;LLC&nbsp;</font> <font backColor='#ffd9bf'>&nbsp;MLE/Type-2&nbsp;</font> <font backColor='#ecd2f5'>&nbsp;CMCE&nbsp;</font>.")
img(P_STACK, w=12*cm); cap("Abb. 11 — Schichtung.")
gap()
P("5  MAC-Layer", H1)
pdu("5.1  MAC-RESOURCE (DL)", "tetra_mac_resource_dl_builder.v, decode_dl.py", BF_MACRES, [
    ["Feld","Off","Bits","Codierung / Bedeutung"],
    ["mac_pdu_type","0","2","00 = MAC-RESOURCE"],["fill_bit_indication","2","1","1 → Fill-Bits am Ende"],
    ["position_of_grant","3","1","0"],["encryption_mode","4","2","0 = clear"],
    ["random_access_flag","6","1","1 bei Slot-Grant (Gold #822)"],["length_indication (LI)","7","6","1–62 = Oktette · <b>63 = Frag-Start</b>"],
    ["address_type","13","3","001 = SSI"],["SSI","16","24","Ziel-Kurzadresse"],
    ["pc / sg / ca flags","40","3","power / slot-grant / chan-alloc"],
    ["[slot_granting_element]","—","8","wenn sg=1: [7:4]=cap_alloc (mm2→0x00, mm7→0x30)"],
    ["TM-SDU","≥43","var","LLC-PDU"]], [3.4*cm,0.9*cm,0.9*cm,CONTENT_W-5.2*cm])
pdu("5.2  MAC-FRAG / MAC-END (DL)", "tetra_sds_dl_frag.c", BF_FRAG, [
    ["Feld","Off","Bits","Bedeutung"],["mac_pdu_type","0","2","01 = MAC-FRAG/END"],
    ["sub","2","1","0 = FRAG · 1 = END (letztes)"],["fill_bit_indication","3","1","END: 1 → Fill-Marker folgt"],
    ["Payload","4","var","TM-SDU-Fortsetzung (FRAG &amp; END ab Bit 4)"]], [3.2*cm,1.0*cm,0.9*cm,CONTENT_W-5.1*cm],
    note="UL-Reassembly erwartet abweichend MAC-END-Payload ab Bit 10 (UL ≠ DL, getrennte Decoder).")
pdu("5.3  MAC-ACCESS (UL) + MAC-END-HU", "tetra_ul_mac_access_parser.v", BF_MACACC, [
    ["Feld","Off","Bits","Bedeutung"],["mac_pdu_type","0","1","0 = MAC-ACCESS · 1 = MAC-END-HU"],
    ["fill_bits","1","1",""],["encrypted","2","1",""],["addr_type","3","2","0=SSI/ISSI 1=EventLabel 2=USSI 3=SMI"],
    ["address","5","24","ISSI (24b) bzw. EventLabel [5..14]"],["optional_field_flag","29","1",""],
    ["length_or_cap_req","30","1","wenn opt=1"],["length_ind / [frag,reservation_req]","31","5","len(5) · oder frag(1)+resv(4)"],
    ["TL-SDU","36/30","var","LLC-PDU (BL-ADATA/DATA/ACK)"]], [4.6*cm,0.9*cm,0.9*cm,CONTENT_W-6.4*cm],
    note="MAC-END-HU (pdu=1): fill(1) + length_or_cap(1) + length/reservation(4) + MM-Body-Fragment-2 (85 bit) — Fortsetzung einer fragmentierten MAC-ACCESS.")
pdu("5.4  MAC-BROADCAST — SYSINFO", "tetra_hal.c", BF_SYS, [
    ["Feld","Off","Bits","Bedeutung"],["main_carrier","0","12","Träger-Nummer"],
    ["band / offset / duplex","12","4/2/3","Band, Offset, Duplex-Spacing"],
    ["… rev, sec_cch, txpwr, rxlev_min, access, dl_timeout","","",""],
    ["optional_field_selector","—","2","2=DEF-FOR-ACCESS · 3=EXTENDED-SERVICES"],
    ["optional_field_value","—","20","sel2: 0xF6200 · sel3: 0x40C10 (alterniert, 2 s)"]], [4.8*cm,0.9*cm,1.0*cm,CONTENT_W-6.7*cm])
pdu("5.5  AACH (14 Bit, RM(30,14))", "tetra_aach_encoder.v", BF_AACH, [
    ["Header","Bedeutung","Field-1 / Field-2"],["00","DL/UL-Assign (FN18)","DL-usage / UL-usage"],
    ["11","Capacity-Allocation (FN1–17)","000000 / 000000"]], [1.6*cm,5.2*cm,CONTENT_W-6.8*cm])
story.append(PageBreak())

P("6  LLC-Layer", H1)
pdu("6.1  LLC-Header (4-Bit-Typ + Flusskontrolle)", "decode_dl.py::parse_llc", BF_LLC, [
    ["pdu_type","Name","Folgefelder / Funktion"],["0","BL-ADATA","N(R)+N(S) — quittierte Daten"],
    ["1","BL-DATA","N(S) — sequenziert (lange DL-SDS)"],["2","BL-UDATA","— unquittiert (NWRK-Broadcast)"],
    ["3","BL-ACK","N(R) — Quittung (SDS-Empfang, NR=NS)"],["4–7","BL-*+FCS","wie 0–3 + CRC-32"],
    ["8","AL-SETUP","Advanced Link (Slot-Grant-Träger)"],["9","AL-DATA/FINAL","Advanced-Link-Daten"]],
    [1.5*cm,2.6*cm,CONTENT_W-4.1*cm],
    note="N(S)/N(R) = Sende-/Empfangs-Sequenznummer (Basic-Link-Flusskontrolle). BL-ACK quittiert mit N(R)=N(S) des empfangenen BL-DATA.")
gap()
P("7  MM-Layer (MLE-PD = 1)", H1)
table([["#","MM-PDU","Schlüsselfelder (verifiziert)"],
       ["5","D-LOCATION-UPDATE-ACCEPT","upd_type(3) + o-bit(1) [+ opt: p_ssi+SSI(24), p_addr_ext+ext(24), p_subscr_class+cls(16), p_energy_saving+esi(14), p_frame18_scch+scch(6), more+Type-3]"],
       ["7","D-LOCATION-UPDATE-REJECT","reject_cause(5)"],
       ["9","D-LOCATION-UPDATE-PROCEEDING","location_update_type(3)"],
       ["10","D-ATTACH-DETACH-GROUP-ID","detach_all_flag(1) + …"],
       ["11","D-…-GROUP-ID-ACK","group_identity_accept_reject(1) + o-bit(1)"],
       ["—","U-LOCATION-UPDATE-DEMAND (UL)","im MAC-ACCESS TL-SDU; mm=2 ITSI-Attach"]],
      [0.8*cm,4.6*cm,CONTENT_W-5.4*cm])
P("location_update_accept_type: 0=Roaming · 1=Migrating · 2=Periodic · 3=ITSI-Attach · 4=Call-Restoration.", SMALL)
story.append(PageBreak())

P("8  CMCE-Layer (MLE-PD = 2) — Call Control", H1)
pdu("8.1  D-SETUP (#7)", "tetra_cmce_body.c::tetra_cmce_build_d_setup", BF_DSETUP, [
    ["Feld","Off","Bits","Bedeutung"],["pdu_type","0","5","7 = D-SETUP"],["call_identifier","5","14",""],
    ["call_time_out","19","4",""],["hook_method","23","1",""],["simplex_duplex","24","1",""],
    ["BSI","25","8","circuit_mode(3)+enc(1)+comm(2)+speech/slots(2)"],["transmission_grant","33","2",""],
    ["trp","35","1","transmission_request_permission"],["call_priority","36","4",""],["o-bit","40","1","1 → Type-2 folgt"],
    ["Type-2 calling_party","41","30","notif(1)+tmp(1)+CPTI_pres(1)+CPTI(2)+calling_ssi(24)+m(1)"]],
    [3.5*cm,0.9*cm,0.9*cm,CONTENT_W-5.3*cm],
    note="calling_party_ssi als Type-2 IE, damit MS-B den Caller-Namen aus dem Codeplug auflöst (sonst „Einzelruf unbekannt“ → reject).")
pdu("8.2  D-CONNECT (#2)", "tetra_cmce_body.c::tetra_cmce_build_d_connect (39 bit, gegen reference-DL.wav verifiziert)", BF_DCONN, [
    ["Feld","Off","Bits","Bedeutung"],["pdu_type","0","5","2 = D-CONNECT"],["call_identifier","5","14",""],
    ["call_time_out","19","4","0 = Infinite"],["hook / simplex","23","2",""],["transmission_grant","25","2","0 = Granted"],
    ["trp","27","1",""],["call_ownership","28","1",""],["o-bit","29","1","1"],
    ["p_call_priority + priority","30","5","present(1)+value(4)"],["p_bsi / p_tmp / p_notif","35","3","alle 0 (kein BSI in D-CONNECT)"],
    ["m-bit","38","1","0"]], [3.6*cm,0.9*cm,0.9*cm,CONTENT_W-5.4*cm])
gap(4)
P("8.3  Weitere CMCE-DL-PDUs (Bit-Layout verifiziert)", H2)
table([["PDU (#)","Bit-Layout (nach pdu_type(5) + call_identifier(14))","Σ Bit"],
       ["D-CALL-PROCEEDING (1)","call_time_out_setup_phase(3)+hook(1)+simplex(1)+o(1)","25"],
       ["D-CONNECT-ACK (3)","call_time_out(4)+tx_grant(2)+trp(1)+o(1)","27"],
       ["D-ALERT (0)","call_time_out_setup_phase(3)+reserved(1)=1+simplex(1)+call_queued(1)+o(1)","26"],
       ["D-TX-GRANTED (11)","tx_grant(2)+trp(1)+enc_ctrl(1)+tx_reserved(1)+o(1)","25"],
       ["D-TX-CEASED (9)","trp(1)+o(1)","21"],
       ["D-RELEASE (6)","disconnect_cause(5)+o(1)","25"]], [3.7*cm,CONTENT_W-6.0*cm,1.3*cm])
gap(5)
P("8.4  SDS / Status", H1)
pdu("D-SDS-DATA (#15)", "tetra_cmce_body.c / tetra_sds_dl_frag.c", BF_SDS, [
    ["Feld","Off","Bits","Bedeutung"],["pdu_type","0","5","15 = D-SDS-DATA"],["CPTI","5","2","1 = SSI"],
    ["calling_party_ssi","7","24","Absender (für Quittung)"],["SDTI","31","2","3 = UDD-4 / Text"],
    ["length_indication","33","11","User-Data in <b>Bit</b>"],["UDD","44","LI","SDS-TL: PID 0x82 (Text) + Header + 8-bit-Text"],
    ["o-bit","44+LI","1","0"]], [3.6*cm,0.9*cm,0.9*cm,CONTENT_W-5.4*cm])
P("<b>D-STATUS (#8):</b> pdu_type(5) + CPTI(2)=1 + calling_party_ssi(24) + pre_coded_status(16) + o-bit(1). Kurze 16-bit-Status-PDU (precoded).", SMALL)
gap(4)
P("8.5  UL-CMCE-PDU-Typen", H2)
table([["#","U-PDU","#","U-PDU"],["0","U-ALERT","8","U-STATUS"],["2","U-CONNECT","9","U-TX-CEASED"],
       ["4","U-DISCONNECT","10","U-TX-DEMAND (Floor-Request)"],["5","U-INFO","15","U-SDS-DATA"],
       ["6","U-RELEASE","7","U-SETUP (Ruf-/Floor-Anfrage)"]], [0.8*cm,5.2*cm,0.8*cm,CONTENT_W-6.8*cm])
P("UL-CMCE-PDUs werden im MAC-ACCESS-TL-SDU (SCH/HU) bzw. SCH/F getragen; tetra_cmce_parser.c liest die Type-1-Mandatories.", SMALL)
story.append(PageBreak())

# ======================= TEIL D =======================
P("Teil D — Abläufe", PART)
P("9  Fragmentierung &amp; Reassembly", H1)
P("Eine lange SDS (&gt; 24 Oktette) passt nicht in einen Slot und wird über MAC-Fragmentierung auf mehrere SCH/F-Bursts verteilt: ein <b>Frag-Start</b> (MAC-RESOURCE, LI=63), beliebig viele <b>MAC-FRAG</b> und ein <b>MAC-END</b>. Der Empfänger fügt die TM-SDU zusammen und findet das Ende über die Fill-Bits.")
img(P_DLFRAG, w=CONTENT_W); cap("Abb. 12 — DL-Fragmentierung.")
P("Fill-Bit-Entfernung (ETSI §23.4.3): das <b>erste</b> Fill-Bit ist '1', alle weiteren '0'. Der Empfänger entfernt vom PDU-Ende her das letzte '1' + folgende '0' → exakte TM-SDU-Grenze.", SMALL)
gap()
img(P_REASS, w=CONTENT_W); cap("Abb. 13 — UL-Reassembly-FSM.")
table([["Index","Inhalt"],["0 … NWORDS-1","Body-Wort (32 Bit, MSB-first: body[0]=word0[31])"],
       ["NWORDS","{31'b0, valid}"],["NWORDS+1","{8'b0, ssi[23:0]}"],
       ["NWORDS+2","{opt_flag, len_bits[15:0]}"],["NWORDS+3","reass_cnt (SW erkennt neuen Body)"]], [3.2*cm,CONTENT_W-3.2*cm])
story.append(PageBreak())

P("10  Voice-Pfad", H1)
P("Sprache läuft als TCH/S in NUB-Bursts auf dem zugewiesenen Verkehrsslot. Der <font name='Courier'>call_fsm</font> setzt <font name='Courier'>voice_active_mask[TS]</font>, worauf der burst_dispatcher den Slot mit Voice-Bursts überschreibt (Override). Pro-TS-Quiet-Detection blendet 300 ms still.")
img(P_VOICE, w=CONTENT_W); cap("Abb. 14 — Voice-Pfad (tetra_ul_nub_capture, tetra_bs_tch_s, tetra_call_fsm).")
gap()
P("11  Ablauf-Sequenzen", H1)
SQ_ATTACH=g_seq(["MS","RTL-RX","slotgrant","attach_daemon","MLE-FSM"], [
    (0,1,"U-LOC-UPDATE-DEMAND (SCH/HU)"),(1,2,"frag1_pulse (mm=2)"),(2,0,"AL-SETUP + Slot-Grant (SCH/HD)"),
    (0,1,"Frag-2 (SCH/F)"),(1,3,"Demand-Body (ISSI,GSSI)"),(3,3,"tetra_db_lookup"),
    (3,4,"reply_write + REG_REPLY_GO"),(4,0,"D-LOC-UPDATE-ACCEPT (BL-ADATA, SCH/F)")],
    "11.1  Registrierung / ITSI-Attach (mm=2)", "sq_attach.png")
SQ_CALL=g_seq(["MS-A","call_fsm","MS-B(Gruppe)"], [
    (0,1,"U-SETUP (gssi)"),(1,0,"D-CALL-PROCEEDING"),(1,2,"D-SETUP (gssi, voice_ts=TS2)"),(1,0,"D-CONNECT"),
    (0,1,"NUB-Voice (TCH/S)"),(1,2,"Voice-Relay (DL-Override)"),(0,1,"U-TX-CEASED"),(1,0,"D-TX-CEASED"),
    (1,1,"Watchdog 5 s → free_slot")], "11.2  Gruppen-Sprechruf", "sq_call.png")
img(SQ_ATTACH, w=14.5*cm); cap("Abb. 15 — ITSI-Attach.")
img(SQ_CALL, w=13*cm); cap("Abb. 16 — Gruppen-Sprechruf.")
story.append(PageBreak())
SQ_S=g_seq(["MS-A","attach_daemon","MS-B"], [
    (0,1,"U-SDS-DATA (dest=B)"),(1,0,"BL-ACK (NR=NS)"),(1,1,"decode ≤24 oct"),
    (1,2,"D-SDS-DATA (reguläre Queue)"),(2,2,"zeigt Text ✓")], "11.3  Kurze SDS (funktioniert)", "sq_s.png")
SQ_UL=g_seq(["MS-A","RTL-RX","attach_daemon"], [
    (0,1,"SCH/HU Frag-Start"),(1,2,"SDS-FRAG-START (defer ACK)"),(1,1,"AACH-Hold (Slots resv.)"),
    (0,1,"N× SCH/F MAC-FRAG"),(1,2,"reassembly → Body"),(2,0,"BL-ACK (NR=NS)")], "11.4  Lange SDS UL (gelöst)", "sq_ul.png")
SQ_DL=g_seq(["attach_daemon","Voice-Filler","MS-B"], [
    (0,0,"build_fragments → 4× SCH/F"),(0,1,"voice_filler_write_ts(TS1)×N"),(1,2,"NDB1 SCH/F (FN≤16)"),
    (0,0,"tetra_tx_rx_slotgrant W9[14]"),(1,2,"NDB2/SCH/HD Slot-Grant"),(2,0,"KEIN Delivery-Report","x")],
    "11.5  Lange SDS DL (OFFEN)", "sq_dl.png")
img(SQ_S, w=12.5*cm); cap("Abb. 17 — Kurze SDS.")
img(SQ_UL, w=12.5*cm); cap("Abb. 18 — Lange SDS UL.")
img(SQ_DL, w=12.5*cm); cap("Abb. 19 — Lange SDS DL (MS-B reassembliert nicht).")
story.append(PageBreak())

P("12  SW-Daemon", H1)
P("Der <font name='Courier'>tetra_attach_daemon</font> ist ereignisgetrieben: er pollt zyklisch die RX-Mailboxen (AXI), klassifiziert die Ereignisse und schreibt Antworten über Reply-Mailbox bzw. Voice-Filler zurück.")
img(P_DAEMON, w=11*cm); cap("Abb. 20 — Hauptschleife: Poll → Klassifikation (DEMAND / SDS / Call / Voice) → TX.")
story.append(PageBreak())

# ======================= TEIL E =======================
P("Teil E — Referenz", PART)
P("13  AXI-Register-Map (Basis 0x43C00000)", H1)
table([["Offset","Register","Zweck"],
    ["0x38","REG_TX_TDMA","[12:7] mf · [6:2] frame · [1:0] slot (free-running)"],
    ["0x144","REG_TX_TDMA_STATE","netz-synchroner Air-FN [6:2] (FN18-Pacing!)"],
    ["0x40–0x5C","REG_SB_SB1_* / COMMIT","Sync-Burst SB1 + atomarer Commit"],
    ["0x60–0x7C","REG_SB_BKN2_*","SYSINFO BKN2 (alterniertes Optional-Field)"],
    ["0xF8–0x12C","REG_BNCH_BLK1/2_*","BNCH-Broadcast-Blöcke"],
    ["0x1AC","REG_DB_POLICY","USE_SW + DB-Policy (=0x3)"],
    ["0x1EC","REG_VOICE_ACTIVE_MASK","[3:0]=voice TN · [7:4]→sds_fill_active CDC"],
    ["0x220 / 0x224","REG_REPLY_INDEX / DATA","Wort-Selektor 0..15 · indirekt (W0..W13)"],
    ["0x228","REG_REPLY_GO","Puls → MLE-FSM · W9[14]=Slot-Grant-Request"],
    ["0x22C / 0x230","REG_REPLY_STATUS / USE_SW","busy-mirror / body-field-mux"]], [2.2*cm,4.0*cm,CONTENT_W-6.2*cm])
gap()
P("14  SW-Modul-Referenz", H1)
table([["Datei","Rolle"],
    ["tetra_hal.c/.h","Zell-Config, SYSINFO/BNCH-Bau, AXI-HAL, SYSINFO-Daemon-Loop"],
    ["tetra_attach_daemon.c","Haupt-Daemon: Demand-Walker, SDS-RX/Relay, DL-Frag, Voice-Service"],
    ["tetra_tx_transport.c","Reply-Mailbox-Staging (W0..W13), CMCE-Submit, rx_slotgrant"],
    ["tetra_cmce_body.c / _parser.c","CMCE-PDU-Bau (D-*) / -Parse (U-*)"],
    ["tetra_mm_demand_parser.c","UL-mm=2/7-Demand-IE-Parse"],
    ["tetra_call_fsm.c","Sprechruf-FSM (U-SETUP→D-CONNECT→Voice→Release)"],
    ["tetra_sds_dl_frag.c","DL-MAC-Fragmentierung langer SDS + Slot-Grant-PDU"],
    ["tetra_voice_filler / _pipe / _tch_s_codec","Voice-Filler / Pipeline / TCH/S-Codec"],
    ["tetra_channel_codec.c","SCH/F-Encode (SW-Referenz, bit-exakt zum RTL)"],
    ["tetra_db.c · tetra_ts_map.h","Teilnehmer-DB (ISSI/GSSI) · TS↔Air-Slot-Timing"]], [4.8*cm,CONTENT_W-4.8*cm])
gap()
P("15  Stand: lange SDS DL-Zustellung", H1)
P("Referenz = DAMM-Netz (Gold-WAV, CC=1) liefert eine lange SDS an unser MTP3550 (2633617); unsere Zelle (CC=49) repliziert das <b>bit-identisch</b>, aber MS-B reassembliert die Kette nicht. Fünf Fixes sind gegen Gold verifiziert:")
table([["#","Fix","Datei","verifiziert"],
    ["1","Format BL-DATA / MAC-END@4 / LI=63 / Block0 BL-ACK+Frag-Start","tetra_sds_dl_frag.c","reassembliert bit-identisch"],
    ["2","FN18-Pacing über REG_TX_TDMA_STATE (0x144) + Start-Fenster","tetra_attach_daemon.c","Kette konsekutiv vor FN18"],
    ["3","Slot-Grant NDB2/SCH/HD via W9[14] SW-Trigger","pre_reply_slotgrant.v u.a.","on-air = Gold #822"],
    ["4","SYSINFO EXTENDED-SERVICES-Toggle (sel 2↔3)","tetra_hal.c","BKN2-Reg alterniert"],
    ["5","MAC-END Fill-Marker (ETSI §23.4.3)","tetra_sds_dl_frag.c","volle 757-bit TM-SDU"]],
    [0.7*cm,7.0*cm,4.0*cm,CONTENT_W-11.7*cm])
gap(5)
P("Verbleibende Hypothese — TX-Pfad", H2)
P("Kurze SDS läuft über den regulären RTL-Signalisierungspfad (Reply-Mailbox → MLE-FSM → dl_pdu_builder → DL-Queue → Scheduler). Die lange SDS läuft über den <b>Voice-Filler-Override</b> auf TN1. Bursts dekodieren im Capture identisch (corr 0.99), aber der MCCH-Empfänger von MS-B verarbeitet den Voice-Filler-Override evtl. nicht wie scheduler-getriebene Fragmente. Offene Entscheidung: (a) Isolationstest — kurze SDS über den Voice-Filler; oder (b) Umbau der Frag-Kette auf den regulären DL-Signal-Queue-Pfad.")

print("building PDF ...")
doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=1.5*cm, rightMargin=1.5*cm, topMargin=1.4*cm, bottomMargin=1.3*cm,
                        title="TETRA Code-Analyse (ausführlich)", author="tetra-zynq-phy")
doc.build(story)
print("OK ->", OUT)
