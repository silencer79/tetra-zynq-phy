#!/usr/bin/env python3
"""
gen_code_map.py — interaktive 2D-DATENFLUSS-Karte aus dem ECHTEN Code.

Gestaffeltes Layout (links->rechts): Antenne-RX -> Decode -> FPGA/SW-Grenze
(Mailboxen) -> SW-Daemon -> Mailboxen -> DL-Build -> Antenne-TX.

Quellen (real):
  - build/reports/cur_hier_deep.rpt  → ECHTER LUT pro RTL-Modul (Knotengröße)
  - rtl/**/*.v                       → Modul→Datei (Klick→Code)
  - sw/*.c                           → SW-Knoten (Größe=LOC) + Datei
  - Fluss-Topologie kuratiert aus docs/ist/00 + Boundary-Analyse (verifiziert).

Ausgabe: code_map.html (vis-network via CDN). Neu: python3 scripts/gen_code_map.py
"""
import os, re, json, math, subprocess
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "code_map.html")
def sh(*a): return subprocess.check_output(a, cwd=ROOT, text=True)

# ---- Modul → Datei ----------------------------------------------------------
mod2file={}
for f in sh("git","ls-files","rtl").split():
    if f.endswith(".v"):
        for m in re.finditer(r'^\s*module\s+([A-Za-z0-9_]+)', open(os.path.join(ROOT,f),errors="replace").read(), re.M):
            mod2file[m.group(1)]=f

# ---- Report → Modul → eigener LUT (total - Kinder) --------------------------
RPT=os.path.join(ROOT,"build/reports/cur_hier_deep.rpt")
rows=[];
for line in open(RPT,errors="replace") if os.path.exists(RPT) else []:
    if not line.startswith("|"): continue
    c=[x.strip() for x in line.split("|")]
    if len(c)<11 or c[1] in("Instance","") or c[1].startswith("(") or not c[3].lstrip("-").isdigit(): continue
    raw=line.split("|")[1]; depth=(len(raw)-len(raw.lstrip()))//2
    rows.append((depth,c[1],c[2],int(c[3])))
own={}   # module -> own_lut (max über instanzen)
for i,(d,inst,mod,lut) in enumerate(rows):
    csum=0
    for d2,_,_,lut2 in rows[i+1:]:
        if d2<=d: break
        if d2==d+1: csum+=lut2
    o=max(0,lut-csum)
    own[mod]=max(own.get(mod,0),o)

# ---- Kuratierter Datenfluss (jeder Knoten: id, modul-für-LUT, level, domain, label)
N=lambda i,m,l,dom,lab:(i,m,l,dom,lab)
NODES=[
 N("ant_rx",None,0,"io","ANTENNE RX\\n(AD9361)"),
 N("rx_frontend","tetra_rx_frontend",1,"rx","rx_frontend\\nCIC+RRC"),
 N("timing","tetra_timing_recovery",2,"rx","timing_recovery"),
 N("demod","tetra_pi4dqpsk_demod",2,"rx","pi4dqpsk_demod (DL)"),
 N("ul_sync","tetra_ul_sync_detect_os4",2,"rx","ul_sync_detect_os4"),
 N("sync","tetra_sync_detect",3,"rx","sync_detect (DL)"),
 N("ul_burst","tetra_ul_burst_capture",3,"rx","ul_burst_capture (RA)"),
 N("ul_nub","tetra_ul_nub_capture",3,"rx","ul_nub_capture (Voice)"),
 N("ul_demod","tetra_ul_pi4dqpsk_demod",3,"rx","ul_pi4dqpsk_demod"),
 N("burst_demux","tetra_burst_demux",4,"rx","burst_demux (DL)"),
 N("schhu","tetra_ul_sch_hu_decoder",4,"rx","ul_sch_hu_decoder\\n+Viterbi"),
 N("nub2schf","tetra_ul_nub_to_schf",4,"rx","ul_nub_to_schf"),
 N("schf_dec","tetra_ul_sch_f_decoder",5,"rx","ul_sch_f_decoder\\n+Viterbi (lange SDS)"),
 N("macparse","tetra_ul_mac_access_parser",5,"lmac","ul_mac_access_parser"),
 N("reass","tetra_ul_demand_reassembly",6,"rx","ul_demand_reassembly"),
 N("schf_reass","tetra_ul_schf_reassembly",6,"rx","ul_schf_reassembly"),
 N("mb_demand","tetra_ul_demand_body_mailbox",7,"mbox","Mailbox 0x250\\nul_demand_body"),
 N("mb_nub","tetra_voice_nub_read_mailbox",7,"mbox","Mailbox 0x280\\nvoice_nub_read"),
 N("sw_attach","SW:tetra_attach_daemon",8,"sw","attach_daemon\\n(Mainloop/Poll)"),
 N("sw_voice","SW:tetra_voice_pipe",8,"sw","voice_pipe\\n(UL→DL Relay)"),
 N("sw_mm","SW:tetra_mm_demand_parser",9,"sw","mm_demand_parser"),
 N("sw_cmcep","SW:tetra_cmce_parser",9,"sw","cmce_parser"),
 N("sw_db","SW:tetra_db",9,"sw","db (db.tsv)"),
 N("sw_callfsm","SW:tetra_call_fsm",10,"sw","call_fsm\\n(Group/Indiv/LateEntry)"),
 N("sw_cmceb","SW:tetra_cmce_body",11,"sw","cmce_body"),
 N("sw_grpack","SW:tetra_grpack_body",11,"sw","grpack_body"),
 N("sw_sds","SW:tetra_sds_dl_frag",11,"sw","sds_dl_frag"),
 N("sw_tx","SW:tetra_tx_transport",11,"sw","tx_transport"),
 N("mb_reply","tetra_reply_mailbox",12,"mbox","Mailbox 0x220\\nreply"),
 N("mb_vfill","tetra_voice_filler_mailbox",12,"mbox","Mailbox 0x270\\nvoice_filler"),
 N("nwrk","tetra_dl_nwrk_broadcast",12,"mbox","dl_nwrk_broadcast"),
 N("mle","tetra_mle_registration_fsm",13,"lmac","mle_fsm + dl_pdu_builder\\n(ACCEPT-Encode)"),
 N("prereply","tetra_pre_reply_slotgrant",13,"lmac","pre_reply (Slot-Grant/BL-ACK)"),
 N("queue","tetra_dl_signal_queue",14,"lmac","dl_signal_queue"),
 N("sched","tetra_dl_signal_scheduler",15,"lmac","dl_signal_scheduler"),
 N("tdma","tetra_tdma_timebase",15,"tdma","tdma_timebase"),
 N("slotmux","tetra_slot_content_mux",15,"tdma","slot_content_mux"),
 N("aach","tetra_aach_encoder",15,"tdma","aach_encoder"),
 N("sb1","tetra_sb1_encoder",15,"tdma","sb1_encoder (BSCH)"),
 N("dispatch","tetra_burst_dispatcher",16,"tx","burst_dispatcher"),
 N("txchain","tetra_burst_builder",17,"tx","burst_builder"),
 N("mod","tetra_pi4dqpsk_mod",18,"tx","pi4dqpsk_mod"),
 N("rrc","tetra_rrc_filter",18,"tx","rrc_filter"),
 N("tx_frontend","tetra_tx_frontend",19,"tx","tx_frontend CIC"),
 N("ant_tx",None,20,"io","ANTENNE TX\\n(AD9361)"),
]
FLOW=[  # (from,to, boundary?)
 ("ant_rx","rx_frontend",0),("rx_frontend","timing",0),("rx_frontend","ul_sync",0),
 ("timing","demod",0),("demod","sync",0),("sync","burst_demux",0),
 ("ul_sync","ul_burst",0),("ul_sync","ul_nub",0),
 ("ul_burst","ul_demod",0),("ul_demod","schhu",0),("schhu","macparse",0),("macparse","reass",0),("reass","mb_demand",1),
 ("ul_nub","nub2schf",0),("nub2schf","schf_dec",0),("schf_dec","schf_reass",0),("schf_reass","mb_demand",1),
 ("ul_nub","mb_nub",1),
 ("mb_demand","sw_attach",1),("mb_nub","sw_voice",1),
 ("sw_attach","sw_mm",0),("sw_attach","sw_cmcep",0),("sw_attach","sw_db",0),("sw_attach","sw_callfsm",0),
 ("sw_mm","sw_callfsm",0),("sw_cmcep","sw_callfsm",0),
 ("sw_callfsm","sw_cmceb",0),("sw_callfsm","sw_sds",0),("sw_callfsm","sw_tx",0),("sw_attach","sw_grpack",0),
 ("sw_cmceb","sw_tx",0),("sw_grpack","sw_tx",0),("sw_sds","sw_tx",0),
 ("sw_tx","mb_reply",1),("sw_voice","mb_vfill",1),("sw_attach","nwrk",1),
 ("mb_reply","mle",1),("mle","queue",0),("prereply","queue",0),("nwrk","queue",0),
 ("mb_vfill","dispatch",1),
 ("queue","sched",0),("sched","dispatch",0),
 ("tdma","sched",0),("tdma","dispatch",0),("tdma","aach",0),("tdma","sb1",0),("slotmux","dispatch",0),
 ("aach","dispatch",0),("sb1","dispatch",0),
 ("dispatch","txchain",0),("txchain","mod",0),("mod","rrc",0),("rrc","tx_frontend",0),("tx_frontend","ant_tx",0),
]
DCOL={"io":"#777","rx":"#4f9dff","lmac":"#ff9f40","mbox":"#ffd24a","sw":"#e05f8a","tx":"#46c46a","tdma":"#9b8cff"}
DSHAPE={"io":"star","mbox":"diamond","sw":"box"}

# SW LOC
swloc={}
for f in sh("git","ls-files","sw").split():
    if f.endswith(".c"): swloc[os.path.basename(f)[:-2]]=sum(1 for _ in open(os.path.join(ROOT,f),errors="replace"))

vnodes=[]; idset=set()
for nid,mod,lvl,dom,lab in NODES:
    idset.add(nid)
    if dom=="sw":
        base=mod[3:]; loc=swloc.get(base,0); file="sw/"+base+".c"; metric=f"SW {loc} LOC"; val=loc; size=min(46,10+math.sqrt(loc)*0.9)
    elif mod:
        lut=own.get(mod,0); file=mod2file.get(mod,""); metric=f"LUT {lut} (eigen)"; val=lut; size=min(46,10+math.sqrt(lut)*1.0)
    else:
        file=""; metric=""; val=1; size=22
    vnodes.append({"id":nid,"label":lab,"level":lvl,"color":DCOL[dom],"shape":DSHAPE.get(dom,"dot"),
                   "size":size,"file":file,"metric":metric,"dom":dom,"mod":mod or ""})
vedges=[]
for a,b,bd in FLOW:
    if a not in idset or b not in idset: continue
    e={"from":a,"to":b,"arrows":"to"}
    if bd: e.update({"color":{"color":"#ffd24a"},"dashes":True,"width":3,"label":""})
    else:  e.update({"color":{"color":"#566"},"width":1.5})
    vedges.append(e)

HTML="""<!doctype html><html><head><meta charset="utf-8"><title>TETRA Datenfluss</title>
<script src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
<style>body{margin:0;font-family:system-ui,sans-serif;background:#15181c;color:#ddd}
#net{position:absolute;top:0;left:0;right:300px;bottom:0}
#side{position:absolute;top:0;right:0;width:300px;bottom:0;background:#1d2127;border-left:1px solid #333;padding:14px;box-sizing:border-box;overflow:auto;font-size:13px}
h2{font-size:15px;margin:0 0 6px}.k{color:#8aa}.leg{margin:3px 0}.sw{display:inline-block;width:12px;height:12px;margin-right:6px;vertical-align:middle;border-radius:2px}
code{background:#0d0f12;padding:1px 4px;border-radius:3px;color:#9cf;word-break:break-all}.hint{color:#777;font-size:12px;margin-top:8px}</style></head><body>
<div id="net"></div><div id="side"><h2>TETRA Datenfluss</h2>
<div class="hint">Fluss links→rechts: Antenne-RX → Decode → <b>FPGA/SW-Grenze</b> → SW-Daemon → Mailbox → DL-Build → Antenne-TX. Pfeile=Datenrichtung. Gelb gestrichelt=Mailbox-Grenze. Knotengröße=LUT (RTL) / LOC (SW).</div>
<div style="margin:10px 0">__LEG__</div><div id="info" style="margin-top:10px"><i>Knoten anklicken…</i></div></div>
<script>
const nodes=new vis.DataSet(__N__),edges=new vis.DataSet(__E__);
const net=new vis.Network(document.getElementById('net'),{nodes,edges},{
 layout:{hierarchical:{enabled:true,direction:'LR',sortMethod:'directed',levelSeparation:200,nodeSpacing:75,treeSpacing:90}},
 physics:false,interaction:{hover:true,dragNodes:true},
 nodes:{font:{color:'#eee',size:12,multi:true},borderWidth:1},edges:{smooth:{type:'cubicBezier',forceDirection:'horizontal'}}});
net.on('click',p=>{const i=document.getElementById('info');if(!p.nodes.length){i.innerHTML='<i>Knoten anklicken…</i>';return;}
 const n=nodes.get(p.nodes[0]);i.innerHTML='<h2>'+n.label.replace(/\\\\n/g,' ')+'</h2><div class="k">Domäne:</div> '+n.dom+'<br><div class="k">Modul:</div> '+n.mod+'<br><div class="k">'+n.metric+'</div><br><div class="k">Datei:</div> '+(n.file?'<code>'+n.file+'</code>':'—')+'<div class="hint">Sag mir den Knoten-Namen → ich öffne den Code mit dir.</div>';});
</script></body></html>"""
leg={"io":"Antenne/IO","rx":"RX-PHY + UL-Decode","lmac":"LMAC/Coding/Build","mbox":"FPGA↔SW Mailbox","sw":"SW-Daemon","tx":"TX-PHY","tdma":"TDMA/AACH/BSCH"}
legend="".join(f'<div class="leg"><span class="sw" style="background:{DCOL[k]}"></span>{v}</div>' for k,v in leg.items())
open(OUT,"w").write(HTML.replace("__LEG__",legend).replace("__N__",json.dumps(vnodes)).replace("__E__",json.dumps(vedges)))
print(f"OK Datenfluss: {len(vnodes)} Knoten, {len(vedges)} Fluss-Kanten -> {OUT}")
