# =============================================================================
# ila_capture.tcl — ILA Trigger + Daten-Export
# Project: tetra-zynq-phy
#
# Setzt ILA-Trigger, wartet auf Auslösung und exportiert Daten als CSV.
#
# Usage:
#   vivado -mode batch -source scripts/ila_capture.tcl \
#          -tclargs [--timeout_ms 30000] [--out_dir build]
#
# Ausgabedateien:
#   build/ila_lvds_data.csv   — LVDS-Domain (AD9361 DATA_CLK): ADC-Valid, RX-Valid
#   build/ila_sys_data.csv    — SYS-Domain (100 MHz): Sync-Status, DMA, IRQ
# =============================================================================

# --- Defaults ---
set timeout_ms  30000
set out_dir     "build"
set host_url    "localhost:3121"

# --- Argument-Parsing ---
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        "--timeout_ms" { incr i; set timeout_ms [lindex $argv $i] }
        "--out_dir"    { incr i; set out_dir    [lindex $argv $i] }
        "--host"       { incr i; set host_url   [lindex $argv $i] }
    }
}

set proj_dir [file dirname [file dirname [info script]]]
set bit_file "${proj_dir}/build/tetra_zynq_phy.bit"
set ltx_file "${proj_dir}/build/tetra_zynq_phy.ltx"

puts "=== ILA Capture: tetra-zynq-phy ==="
puts "  hw_server : ${host_url}"
puts "  Timeout   : ${timeout_ms} ms"
puts "  Output    : ${out_dir}/"
puts ""

# --- Hardware Manager öffnen ---
open_hw_manager
if {[catch {connect_hw_server -url ${host_url} -quiet} err]} {
    puts "INFO: hw_server nicht erreichbar, starte neu..."
    exec hw_server &
    after 2000
    connect_hw_server -url ${host_url}
}

open_hw_target [lindex [get_hw_targets] 0]
current_hw_device [lindex [get_hw_devices xc7z020_0] 0]

puts "Hardware verbunden: [get_property PART [current_hw_device]]"

# Probes-Datei laden (für Signalnamen)
if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file [current_hw_device]
    refresh_hw_device [current_hw_device]
    puts "Probes geladen: $ltx_file"
} else {
    puts "WARN: .ltx nicht gefunden — Signalnamen ggf. unbekannt"
}

# --- ILA-Cores ermitteln ---
set all_ilas [get_hw_ilas -of_objects [current_hw_device]]
puts "\nGefundene ILA-Cores: [llength $all_ilas]"
foreach ila $all_ilas {
    puts "  $ila  (Takt: [get_property CONTROL.CLK_FREQ $ila] Hz, Tiefe: [get_property CONTROL.DATA_DEPTH $ila])"
}

# ILA nach Domäne zuordnen
set ila_lvds {}
set ila_sys  {}
foreach ila $all_ilas {
    set name [string tolower $ila]
    if {[string match "*lvds*" $name] || [string match "*u_ila_l*" $name]} {
        set ila_lvds $ila
    } elseif {[string match "*sys*" $name] || [string match "*u_ila_s*" $name]} {
        set ila_sys $ila
    }
}
# Fallback: erste und zweite ILA
if {$ila_lvds eq {} && [llength $all_ilas] >= 1} { set ila_lvds [lindex $all_ilas 0] }
if {$ila_sys  eq {} && [llength $all_ilas] >= 2} { set ila_sys  [lindex $all_ilas 1] }

puts "\nILA LVDS: $ila_lvds"
puts "ILA SYS:  $ila_sys"

# =============================================================================
# Hilfsfunktion: ILA triggern, warten, exportieren
# =============================================================================
proc capture_ila {ila trigger_probe trigger_val csv_file timeout_ms} {
    if {$ila eq {}} {
        puts "WARN: ILA nicht vorhanden, übersprungen."
        return 0
    }

    puts "\n--- Capture: $ila ---"
    puts "  Trigger: ${trigger_probe} = ${trigger_val}"

    # Trigger-Probe suchen
    set probes [get_hw_probes -of_objects $ila]
    set tprobe {}
    foreach p $probes {
        if {[string match "*${trigger_probe}*" $p]} {
            set tprobe $p
            break
        }
    }

    if {$tprobe ne {}} {
        puts "  Trigger-Probe gefunden: $tprobe"
        set_property COMPARE_VALUE        "eq1'b${trigger_val}" $tprobe
        set_property TRIGGER_COMPARE_VALUE "eq1'b${trigger_val}" $tprobe
    } else {
        puts "  WARN: Trigger-Probe '${trigger_probe}' nicht gefunden — Immediate-Trigger"
    }

    # Trigger-Position: 10% vom Puffer (Vorgeschichte sichtbar)
    set depth [get_property CONTROL.DATA_DEPTH $ila]
    set_property CONTROL.TRIGGER_POSITION [expr {$depth / 10}] $ila

    # ILA scharf schalten
    run_hw_ila $ila
    puts "  ILA armed — warte auf Trigger (Timeout: ${timeout_ms} ms) ..."

    # Warten
    if {[catch {wait_on_hw_ila $ila -timeout $timeout_ms} waitres]} {
        puts "  WARN: Timeout oder Fehler: $waitres"
        puts "  Lade trotzdem vorhandene Daten ..."
    } else {
        puts "  Trigger ausgelöst: $waitres"
    }

    # Daten hochladen
    set ila_data [upload_hw_ila_data $ila]

    # CSV exportieren
    set csv_path "${csv_file}"
    write_hw_ila_data -csv_file $csv_path $ila_data
    puts "  Daten exportiert: $csv_path"

    # Kurze Zusammenfassung
    set sample_count [llength [get_hw_ila_datas -of_objects $ila]]
    puts "  Samples: $sample_count"

    return 1
}

# =============================================================================
# Capture 1: LVDS Domain — AD9361 Datenfluß prüfen
# =============================================================================
capture_ila \
    $ila_lvds \
    "dbg_adc_valid_i0" \
    "1" \
    "${proj_dir}/${out_dir}/ila_lvds_data.csv" \
    $timeout_ms

# =============================================================================
# Capture 2: SYS Domain — TETRA-Sync und DMA prüfen
# =============================================================================
capture_ila \
    $ila_sys \
    "dbg_sync_found" \
    "1" \
    "${proj_dir}/${out_dir}/ila_sys_data.csv" \
    $timeout_ms

puts "\n=== ILA Capture abgeschlossen ==="
puts "Dateien:"
foreach f [list "${proj_dir}/${out_dir}/ila_lvds_data.csv" \
               "${proj_dir}/${out_dir}/ila_sys_data.csv"] {
    if {[file exists $f]} {
        puts "  [file size $f] Bytes  $f"
    } else {
        puts "  (nicht vorhanden) $f"
    }
}
puts "\nWeiter mit: python3 scripts/analyze_ila.py"

close_hw_manager
