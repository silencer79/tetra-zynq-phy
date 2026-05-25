# =============================================================================
# ila_debug_setup.tcl — ILA Debug Cores via MARK_DEBUG property
# =============================================================================
# Philip: Automatische ILA-Erstellung ohne RTL-Änderung
#
# Usage:
# Vor Synthese in vivado_build.tcl sourcen:
# source scripts/ila_debug_setup.tcl
#
# Methode: Vivado MARK_DEBUG property auf Signalen setzen → ILA auto-generated
# =============================================================================

namespace eval _ila_debug {}

set PROJ_DIR [file dirname [file dirname [info script]]]

puts "==================================================================="
puts " ILA Debug Setup — MARK_DEBUG property"
puts "===================================================================""

# =============================================================================
# 1. Aktuelles Design öffnen falls nicht bereits offen
# =============================================================================

if {[catch {current_fileset}]} {
 puts "ERROR: Kein Fileset geöffnet. Script muss innerhalb eines Vivado-Projekts laufen."
 return
}

# =============================================================================
# 2. RTL-Source laden falls nötig
# =============================================================================

set rtl_files [glob -nocomplain $PROJ_DIR/rtl/*.v $PROJ_DIR/rtl/*/*.v]

if {[llength $rtl_files] == 0} {
 puts "WARNING: Keine RTL-Dateien gefunden, fahre fort..."
} else {
 puts "Gefundene RTL-Dateien: [llength $rtl_files] Dateien"
}

# =============================================================================
# 3. MARK_DEBUG auf critical Signals setzen
# =============================================================================
# Achtung: Diese Signale müssen im Top-Level oder Submodulen existieren
# Wir nutzen hierarchische Pfade durch tetra_system_wrapper → tetra_zynq_top
# =============================================================================

puts "\n=== Setting MARK_DEBUG properties ==="

# Clock Domain sys (100 MHz) — TETRA Sync + Processing
set debug_signals_sys {
 "sync_found_sample"
 "sync_locked_sample"
 "i_data_sys"
 "q_data_sys"
 "symbol_valid_sample"
 "dibit_valid_sample"
 "slot_valid_sample"
 "rcpc_enable_sys"
}

# Clock Domain lvds (AD9361 samples)
set debug_signals_lvds {
 "i_sample_lvds"
 "q_sample_lvds"
 "sample_valid_lvds"
}

foreach sig $debug_signals_sys {
 set hier_path "i_tetra_system_wrapper/i_design_1.tetra_zynq_top_0.inst.tetra_zynq_top_i.${sig}"

 # Try to find the signal
 if {[catch {set nets [get_nets -hierarchical -filter "NAME =~ *${sig}*"]}]]} {
 puts "WARNING: Signal '${sig}' nicht gefunden, überspringe..."
 continue
 }

 if {[llength $nets] > 0} {
 set first_net [lindex $nets 0]
 puts " MARK_DEBUG: ${sig} -> ${first_net}"
 set_property MARK_DEBUG true $first_net
 } else {
 puts "WARNING: Kein Netz für Signal '${sig}' gefunden"
 }
}

foreach sig $debug_signals_lvds {
 set hier_path "i_tetra_system_wrapper/i_design_1.tetra_zynq_top_0.inst.tetra_zynq_top_i.${sig}"

 if {[catch {set nets [get_nets -hierarchical -filter "NAME =~ *${sig}*"]}]]} {
 puts "WARNING: Signal '${sig}' nicht gefunden, überspringe..."
 continue
 }

 if {[llength $nets] > 0} {
 set first_net [lindex $nets 0]
 puts " MARK_DEBUG: ${sig} -> ${first_net}"
 set_property MARK_DEBUG true $first_net
 } else {
 puts "WARNING: Kein Netz für Signal '${sig}' gefunden"
 }
}

# =============================================================================
# 4. Debug Core erstellen
# =============================================================================

puts "\n=== Creating Debug Cores ==="

# Diese werden automatisch von Vivado erstellt wenn MARK_DEBUG = true
# während der Synthese. Keine manuelle Instantiierung nötig.

puts "INFO: MARK_DEBUG properties gesetzt."
puts "INFO: Vivado wird ILA-Cores während Synthese automatisch erstellen."
puts "INFO: Trigger-Setup erfolgt später via Hardware Manager."

# =============================================================================
# 5. Abschluss
# =============================================================================

puts "\n==================================================================="
puts " ILA Debug Setup ABGESCHLOSSEN"
puts "==================================================================="
puts "Nächster Schritt: Synthese starten (ila_debug_setup.tcl wurde gesourcet)"
puts "==================================================================="

return
