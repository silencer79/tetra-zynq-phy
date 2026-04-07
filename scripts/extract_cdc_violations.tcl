# =============================================================================
# Script: extract_cdc_violations.tcl
# Project: tetra-zynq-phy
#
# Description:
# Extracts detailed CDC violation information from implemented design
# Generates categorized list of unsafe CDC crossings for fix implementation
#
# Usage:
# vivado -mode batch -source scripts/extract_cdc_violations.tcl
#
# Output:
# - reports/cdc_violations_detailed.rpt: Full CDC report with details
# - reports/cdc_unsafe_crossings.txt: List of unsafe signals (categorized)
# - reports/cdc_signal_categories.csv: CSV for spreadsheet analysis
# =============================================================================

# Open project and implemented design
set project_dir "build"
set project_name "tetra_zynq_phy"

puts "INFO: Opening project $project_name..."
open_project ${project_dir}/${project_name}.xpr

puts "INFO: Opening implemented design..."
open_run impl_1

# Create reports directory if it doesn't exist
file mkdir reports

# =============================================================================
# Step 1: Generate full CDC report with details
# =============================================================================
puts "INFO: Generating detailed CDC report..."
report_cdc -details -file reports/cdc_violations_detailed.rpt

# =============================================================================
# Step 2: Extract CDC violation objects
# =============================================================================
puts "INFO: Extracting CDC violations..."

# Get all CDC violations
set cdc_violations [get_cdc_violations -quiet]

# Initialize counters and lists
set unsafe_count 0
set safe_count 0
set unknown_count 0

# Lists for categorization
set data_buses      [list]
set control_signals [list]
set counters        [list]
set pulse_signals   [list]

# =============================================================================
# Step 3: Categorize violations
# =============================================================================
puts "INFO: Categorizing CDC violations..."

foreach violation $cdc_violations {
    # Get violation properties
    set violation_type [get_property VIOLATION_TYPE $violation]
    set from_clock     [get_property FROM_CLOCK $violation]
    set to_clock       [get_property TO_CLOCK $violation]
    set from_pin       [get_property FROM_PIN $violation]
    set to_pin         [get_property TO_PIN $violation]
    set bit_width      [get_property BIT_WIDTH $violation]

    # Count by type
    switch $violation_type {
        "Unsafe" {
            incr unsafe_count

            # Categorize by bit width and signal type
            if {$bit_width > 16} {
                # Multi-bit bus (>16 bits) → XPM async FIFO
                lappend data_buses [list $from_pin $to_pin $bit_width $from_clock $to_clock]
            } elseif {$bit_width > 1} {
                # Multi-bit signal (2-16 bits) → Gray-code or FIFO
                if {[string match "*cnt*" $to_pin] || [string match "*counter*" $to_pin] || [string match "*num*" $to_pin]} {
                    lappend counters [list $from_pin $to_pin $bit_width $from_clock $to_clock]
                } else {
                    lappend data_buses [list $from_pin $to_pin $bit_width $from_clock $to_clock]
                }
            } else {
                # Single-bit signal → 2-FF synchronizer or toggle-sync
                if {[string match "*pulse*" $to_pin] || [string match "*valid*" $to_pin] || [string match "*req*" $to_pin]} {
                    lappend pulse_signals [list $from_pin $to_pin $from_clock $to_clock]
                } else {
                    lappend control_signals [list $from_pin $to_pin $from_clock $to_clock]
                }
            }
        }
        "Safe" {
            incr safe_count
        }
        "Unknown" {
            incr unknown_count
        }
    }
}

# =============================================================================
# Step 4: Generate categorized report
# =============================================================================
puts "INFO: Generating categorized report..."

set report_file [open reports/cdc_unsafe_crossings.txt w]

puts $report_file "# CDC Unsafe Crossing Report — tetra-zynq-phy"
puts $report_file "# Generated: [clock format [clock seconds]]"
puts $report_file "#"
puts $report_file "# Summary:"
puts $report_file "#   Safe:    $safe_count crossings"
puts $report_file "#   Unsafe:  $unsafe_count crossings"
puts $report_file "#   Unknown: $unknown_count crossings"
puts $report_file "#"
puts $report_file "# ============================================================================="
puts $report_file ""

# Section 1: Data Buses (>16 bits) — XPM FIFO required
puts $report_file "# SECTION 1: DATA BUSES (requires XPM async FIFO)"
puts $report_file "# Format: FROM_PIN → TO_PIN [WIDTH bits] (FROM_CLOCK → TO_CLOCK)"
puts $report_file "#"
foreach entry $data_buses {
    lassign $entry from_pin to_pin bit_width from_clock to_clock
    puts $report_file "$from_pin → $to_pin   \[$bit_width bits\] ($from_clock → $to_clock)"
}
puts $report_file ""

# Section 2: Counters → Gray-code synchronizer
puts $report_file "# SECTION 2: COUNTERS (requires Gray-code + 2-FF sync)"
puts $report_file "# Format: FROM_PIN → TO_PIN [WIDTH bits] (FROM_CLOCK → TO_CLOCK)"
puts $report_file "#"
foreach entry $counters {
    lassign $entry from_pin to_pin bit_width from_clock to_clock
    puts $report_file "$from_pin → $to_pin   \[$bit_width bits\] ($from_clock → $to_clock)"
}
puts $report_file ""

# Section 3: Control Signals → 2-FF synchronizer
puts $report_file "# SECTION 3: CONTROL SIGNALS (requires 2-FF synchronizer)"
puts $report_file "# Format: FROM_PIN → TO_PIN (FROM_CLOCK → TO_CLOCK)"
puts $report_file "#"
foreach entry $control_signals {
    lassign $entry from_pin to_pin from_clock to_clock
    puts $report_file "$from_pin → $to_pin   ($from_clock → $to_clock)"
}
puts $report_file ""

# Section 4: Pulse Signals → Toggle synchronizer
puts $report_file "# SECTION 4: PULSE SIGNALS (requires toggle synchronizer)"
puts $report_file "# Format: FROM_PIN → TO_PIN (FROM_CLOCK → TO_CLOCK)"
puts $report_file "#"
foreach entry $pulse_signals {
    lassign $entry from_pin to_pin from_clock to_clock
    puts $report_file "$from_pin → $to_pin   ($from_clock → $to_clock)"
}
puts $report_file ""

close $report_file

# =============================================================================
# Step 5: Generate CSV for spreadsheet analysis
# =============================================================================
puts "INFO: Generating CSV report..."

set csv_file [open reports/cdc_signal_categories.csv w]

puts $csv_file "Category,From_Pin,To_Pin,Bit_Width,From_Clock,To_Clock,Fix_Strategy"

foreach entry $data_buses {
    lassign $entry from_pin to_pin bit_width from_clock to_clock
    puts $csv_file "Data_Bus,$from_pin,$to_pin,$bit_width,$from_clock,$to_clock,XPM_FIFO_Async"
}

foreach entry $counters {
    lassign $entry from_pin to_pin bit_width from_clock to_clock
    puts $csv_file "Counter,$from_pin,$to_pin,$bit_width,$from_clock,$to_clock,Gray_Code_2FF"
}

foreach entry $control_signals {
    lassign $entry from_pin to_pin from_clock to_clock
    puts $csv_file "Control_Signal,$from_pin,$to_pin,1,$from_clock,$to_clock,2FF_Synchronizer"
}

foreach entry $pulse_signals {
    lassassign $entry from_pin to_pin from_clock to_clock
    puts $csv_file "Pulse_Signal,$from_pin,$to_pin,1,$from_clock,$to_clock,Toggle_Sync"
}

close $csv_file

# =============================================================================
# Summary
# =============================================================================
puts "=========================================================================="
puts "CDC Extraction Complete"
puts "=========================================================================="
puts "Total Unsafe Crossings: $unsafe_count"
puts ""
puts "Breakdown by Category:"
puts "  Data Buses (>16 bit):      [llength $data_buses]"
puts "  Counter Signals:           [llength $counters]"
puts "  Control Signals (1 bit):   [llength $control_signals]"
puts "  Pulse Signals (1 bit):     [llength $pulse_signals]"
puts ""
puts "Reports Generated:"
puts "  - reports/cdc_violations_detailed.rpt"
puts "  - reports/cdc_unsafe_crossings.txt"
puts "  - reports/cdc_signal_categories.csv"
puts "=========================================================================="

# Exit Vivado
exit 0
