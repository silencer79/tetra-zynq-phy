# TETRA Cell Web-UI

Minimaler Web-Frontend für Cell-Konfiguration und sysinfo-Daemon-Steuerung.
Läuft am Board auf busybox httpd (Port 80, doc-root `/www`).

## Datei-Layout am Board

| Repo-Pfad | Board-Pfad |
|-----------|-----------|
| `sw/web/index.html` | `/www/index.html` (statisch) |
| `sw/web/apply.cgi` | `/www/cgi-bin/apply.cgi` (CGI ausführbar) |
| `sw/web/status.cgi` | `/www/cgi-bin/status.cgi` (CGI ausführbar) |
| `sw/web/stop.cgi` | `/www/cgi-bin/stop.cgi` (CGI ausführbar) |

**Wichtig:** busybox httpd führt nur Files unter `/cgi-bin/` als CGI aus.
Files mit `.cgi`-Endung im Doc-Root (z.B. `/www/apply.cgi`) werden als
plain-text geliefert. Das Form-`fetch()` in `index.html` zeigt deshalb
auf `/cgi-bin/apply.cgi`, nicht `/apply.cgi`.

## Endpoints

- `GET /` → `index.html` mit Form (Frequenz, MCC/MNC/LA/CC, TX-Atten, …)
- `GET /cgi-bin/apply.cgi?freq=…&mcc=…&...` → konfiguriert AD9361
  TX/RX_LO + restartet `tetra_sysinfo` mit neuen CLI-Args
- `GET /cgi-bin/status.cgi[?brief=1]` → Daemon + Frequenz + Counter dump
- `GET /cgi-bin/stop.cgi` → kill tetra_sysinfo

## Aktueller Funktionsumfang

`apply.cgi` setzt:
- `out_altvoltage1_TX_LO_frequency` (DL)
- `out_altvoltage0_RX_LO_frequency` (UL, abhängig von duplex_spacing)
- `out_voltage0_hardwaregain` (TX-Atten)
- startet `tetra_sysinfo --daemon` mit allen Cell-Parametern

`duplex_spacing` Mapping (DL → UL Offset):
- 1 → −7.6 MHz
- 3 → −10 MHz (TETRA Band 4 default)
- 4 → +10 MHz
- 7 → 0 MHz (DMO)

Persistierung: `/tmp/tetra_cell.conf` (volatil, geht beim Reboot verloren).
Phase-E-Roadmap (Subscriber-DB-WebUI) wird das durch die echte
HTTP-API mit `/var/lib/tetra/` Persistierung ersetzen.

## Deploy-Pfad

Aktuell sind die Files **direkt auf dem Board** angelegt
(`/www/index.html`, `/www/cgi-bin/*.cgi`). Sie sind NICHT in
`scripts/deploy.sh` integriert. Nach manuellen Änderungen am Board:

```bash
sshpass -p openwifi scp root@192.168.2.180:/www/cgi-bin/apply.cgi sw/web/apply.cgi
git add sw/web/apply.cgi && git commit
```

Umgekehrt (lokal → Board):
```bash
sshpass -p openwifi scp sw/web/apply.cgi root@192.168.2.180:/www/cgi-bin/apply.cgi
sshpass -p openwifi ssh root@192.168.2.180 'chmod +x /www/cgi-bin/apply.cgi'
```

Auto-Sync ist Phase E (siehe `docs/ARCHITECTURE.md §9.7`).
