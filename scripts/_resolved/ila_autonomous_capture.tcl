# =============================================================================
# ila_autonomous_capture.tcl — Autonomer ILA-Capture für TETRA PHY
# =============================================================================
# Philip: Hardware bereits auf FPGA, LTX laden + triggern
#
# Usage:
#   vivado -mode batch -source scripts/ila_autonomous_capture.tcl
#
# Output:
#   build/ila_data_*.csv — Captured ILA data
# =============================================================================

set PROJ_DIR [file dirname [file dirname [info script]]]
set BUILD_DIR "$PROJ_DIR/build"
set LTX_FILE "$BUILD_DIR/tetra_zynq_phy.ltx"

puts "==================================================================="
puts " ILA Autonomous Capture — TETRA PHY"
puts "==================================================================="
puts " LTX: $LTX_FILE"

# =============================================================================
# 1. Hardware Manager öffnen
# =============================================================================
puts "\n=== Step 1: Open Hardware Manager ==="

open_hw_manager

# =============================================================================
# 2. Hardware Target connecten (Server bereits läuft laut pgrep)
# =============================================================================
puts "\n=== Step 2: Connect to Hardware Server ==="

# Hardware Server sollte auf localhost:3121 laufen
connect_hw_server -url localhost:3121

# Targets auflisten
set targets [get_hw_targets]
puts "Available targets: $targets"

# Erstes Target auswählen
if {[llength $targets] == 0} {
    error "ERROR: No hardware targets found!"
}

set target [lindex $targets 0]
puts "Using target: $target"

# Target öffnen
open_hw_target $target

# =============================================================================
# 3. LTX-File laden
# =============================================================================
puts "\n=== Step 3: Load LTX File ==="

if {![file exists $LTX_FILE]} {
    error "ERROR: LTX file not found: $LTX_FILE"
}

# Geräte auflisten (sollte das FPGA-Device sein)
set devices [get_hw_devices]
puts "Available devices: $devices"

if {[llength $devices] == 0} {
    error "ERROR: No hardware devices found!"
}

# Wähle xc7z020 Device (nicht arm_dap)
set device ""
foreach d $devices {
    if {[string match "*xc7z020*" $d]} {
        set device $d
        break
    }
}

# Fallback: letztes Device wenn kein xc7z020 gefunden
if {$device eq ""} {
    set device [lindex $devices end]
}

puts "Using device: $device"

# LTX laden
current_hw_device $device
refresh_hw_device -update_hw_probes false $device

# Debug Probes laden
set hw_debug_core [get_hw_debug_cores $device]
puts "Debug cores found: $hw_debug_core"

if {[llength $hw_debug_core] == 0} {
    puts "WARNING: No debug cores found! Design may not have ILA."
    puts "Checking if LTX was loaded correctly..."

    # Versuch LTX explizit zu laden
    set_property PROBE_FILE $LTX_FILE [get_hw_devices $device]
    refresh_hw_device $device

    set hw_debug_core [get_hw_debug_cores $device]
    if {[llength $hw_debug_core] == 0} {
        error "ERROR: Still no debug cores. Check if design has ILA instantiated."
    }
}

set ila_core [lindex $hw_debug_core 0]
puts "ILA core: $ila_core"

# =============================================================================
# 4. Trigger konfigurieren: sync_found_sample Rising Edge
# =============================================================================
puts "\n=== Step 4: Configure Trigger ==="

# Trigger-Position setzen (capture some data before trigger)
set_property TRIGGER_COMPARE_VALUE eq1_rising [get_hw_probes "$ila_core/sync_found_sample"]

# Capture-Tiefe: 1024 Samples
set_property CAPTURE_DEPTH 1024 $ila_core

#告诉他 trigger position (capture一些 pre-trigger data)
set_property TRIGGER_POSITION 256 $ila_core

puts "Trigger configured: sync_found_sample = RISING EDGE"
puts "Capture depth: 1024 samples"
puts "Trigger position: 256 (pre-trigger samples)"

# =============================================================================
# 5. ILA arm
# =============================================================================
puts "\n=== Step 5: Arm ILA ==="

# Run des ILA triggern
run_hw_ila $ila_core

puts "ILA armed and waiting for trigger..."
puts "Timeout: 60 seconds"

# =============================================================================
# 6. Warten auf Trigger (mit Timeout)
# =============================================================================
puts "\n=== Step 6: Wait for Trigger ==="

set timeout_seconds 60
set start_time [clock seconds]
set triggered false

while {[clock seconds] - $start_time < $timeout_seconds} {
    # Status prüfen
    set status [get_property STATUS $ila_core]

    if {$status eq "TRIGGERED"} {
        set triggered true
        puts "ILA TRIGGERED!"
        break
    }

    # 1 Sekunde warten
    after 1000
    puts -nonewline "."
    flush stdout
}

puts ""

if {!$triggered} {
    puts "WARNING: ILA did not trigger within timeout!"
    puts "This could mean:"
    puts "  - No TETRA signal present at RF input"
    puts "  - RX chain not properly configured"
    puts "  - sync_detect module is not locking"
    puts ""
    puts "Uploading captured data anyway (may contain post-trigger data)..."
}

# =============================================================================
# 7. Daten upload
# =============================================================================
puts "\n=== Step 7: Upload and Save Data ==="

# ILA-Daten upload
upload_hw_ila $ila_core

# CSV export
set timestamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set csv_file "$BUILD_DIR/ila_capture_${timestamp}.csv"

# Windows-Format CSV (für Vivado)
write_hw_ila_data $ila_core $csv_file -write_into_file -force

puts "Data saved to: $csv_file"

# =============================================================================
# 8. Cleanup
# =============================================================================
puts "\n=== Step 8: Cleanup ==="

disconnect_hw_server
close_hw_manager

puts ""
puts "==================================================================="
puts " ILA Capture Completed"
puts "==================================================================="
puts " CSV: $csv_file"
puts "Timestamp: $timestamp"
puts ""
puts "Next step: Analyze CSV with Python script"
puts "==================================================================="

exit 0
